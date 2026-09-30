//! Synchronous installation orchestration. Run outside the UI thread.
const std = @import("std");
const dl = @import("../downloader.zig");
const m = @import("metadata/root.zig");
const planner = @import("install_plan.zig");
const native = @import("native_extract.zig");
const A = std.mem.Allocator;
pub const Progress = struct { completed: usize, total: usize, downloaded: usize, reused: usize };
pub const Config = struct {
    version_id: []const u8,
    root: []const u8 = ".minecraft",
    manifest_url: []const u8 = m.version_manifest_url,
    environment: m.rules.Environment,
    native_arch: ?planner.NativeArch = null,
    proxy: ?[]const u8 = null,
    ca_bundle: ?[]const u8 = null,
    window: usize = 16,
    cancel: ?*const std.atomic.Value(bool) = null,
    progress: ?*const fn (Progress) void = null,
};
pub const Installed = struct {
    version: m.Owned(m.version.Version),
    plan: m.Owned(planner.Plan),
    downloaded: usize,
    reused: usize,
    pub fn deinit(self: *Installed) void {
        self.plan.deinit();
        self.version.deinit();
        self.* = undefined;
    }
};
/// Caller owns service/curl lifetime. Only one installer may mutate a given root.
/// Returned metadata and plan own their data independently of download handles.
pub fn run(a: A, io: std.Io, service: *dl.Service, config: Config) !Installed {
    if (config.window == 0 or config.window > 128) return error.InvalidWindow;
    try component(config.version_id);
    try canceled(config.cancel);
    const manifest_bytes = try fetch(a, io, service, config, config.manifest_url, null, null);
    defer a.free(manifest_bytes);
    var manifest = try m.manifest.parseSlice(a, manifest_bytes);
    defer manifest.deinit();
    const entry = manifest.value.find(config.version_id) orelse return error.VersionNotFound;
    const version_bytes = try fetch(a, io, service, config, entry.url, entry.sha1, null);
    defer a.free(version_bytes);
    var version = try m.version.parseSlice(a, version_bytes);
    errdefer version.deinit();
    if (!std.mem.eql(u8, version.value.id, config.version_id)) return error.VersionIdMismatch;
    const index = version.value.asset_index orelse return error.MissingAssetIndex;
    try component(index.id);
    const assets_bytes = try fetch(a, io, service, config, index.url, index.sha1, index.size);
    defer a.free(assets_bytes);
    var assets = try m.asset_index.parseSlice(a, assets_bytes);
    defer assets.deinit();
    var plan = try planner.build(a, version.value, assets.value, config.environment, .{ .root = config.root, .native_arch = config.native_arch });
    errdefer plan.deinit();
    const version_path = try std.fmt.allocPrint(a, "{s}/versions/{s}/{s}.json", .{ config.root, config.version_id, config.version_id });
    defer a.free(version_path);
    try writeAtomic(a, io, version_path, version_bytes);
    for (plan.value.files) |file| if (file.kind == .asset_index) {
        try writeAtomic(a, io, file.path, assets_bytes);
    };
    var downloaded: usize = 0;
    var reused: usize = 0;
    var tasks: std.ArrayList(*dl.Task) = .empty;
    defer tasks.deinit(a);
    // Every task handle is terminal before release, including all failure paths.
    defer drain(io, tasks.items);
    try tasks.ensureTotalCapacity(a, config.window);
    var cursor: usize = 0;
    while (cursor < plan.value.files.len or tasks.items.len != 0) {
        try canceled(config.cancel);
        while (cursor < plan.value.files.len and tasks.items.len < config.window) {
            const file = plan.value.files[cursor];
            try canceled(config.cancel);
            try ensureParents(io, file.path);
            if (file.kind == .asset_index or try verified(io, file, config.cancel)) {
                reused += 1;
                if (config.progress) |report| report(.{ .completed = reused + downloaded, .total = plan.value.files.len, .downloaded = downloaded, .reused = reused });
                cursor += 1;
                continue;
            }
            const task = service.submit(.{ .url = file.url, .output = .{ .file = file.path }, .expected_sha1 = file.sha1, .expected_size = file.size, .proxy = config.proxy, .ca_bundle = config.ca_bundle }) catch |err| {
                if (err == error.QueueFull and tasks.items.len != 0) break;
                return err;
            };
            tasks.appendAssumeCapacity(task);
            cursor += 1;
        }
        var i: usize = 0;
        while (i < tasks.items.len) {
            const task = tasks.items[i];
            const snapshot = task.snapshot();
            if (!dl.terminal(snapshot.progress.phase)) {
                i += 1;
                continue;
            }
            _ = tasks.swapRemove(i);
            try task.release();
            if (snapshot.failure) |err| return err;
            if (snapshot.progress.phase != .complete) return error.DownloadFailed;
            downloaded += 1;
            if (config.progress) |report| report(.{ .completed = reused + downloaded, .total = plan.value.files.len, .downloaded = downloaded, .reused = reused });
        }
        if (tasks.items.len != 0) try io.sleep(.fromMilliseconds(10), .awake);
    }
    try canceled(config.cancel);
    try native.extract(a, io, plan.value.native_extractions, config.cancel);
    return .{ .version = version, .plan = plan, .downloaded = downloaded, .reused = reused };
}
fn canceled(cancel: ?*const std.atomic.Value(bool)) !void {
    if (cancel) |flag| if (flag.load(.acquire)) return error.Canceled;
}
fn drain(io: std.Io, tasks: []const *dl.Task) void {
    for (tasks) |task| task.cancel();
    for (tasks) |task| {
        while (!dl.terminal(task.snapshot().progress.phase)) io.sleep(.fromMilliseconds(10), .awake) catch {};
        task.release() catch unreachable;
    }
}
fn fetch(a: A, io: std.Io, service: *dl.Service, config: Config, url: []const u8, sha1: ?m.Sha1, size: ?u64) ![]u8 {
    try canceled(config.cancel);
    const task = try service.submit(.{ .url = url, .output = .bytes, .expected_sha1 = sha1, .expected_size = size, .max_bytes = 64 * 1024 * 1024, .proxy = config.proxy, .ca_bundle = config.ca_bundle });
    defer drain(io, &.{task});
    while (true) {
        try canceled(config.cancel);
        const state = task.snapshot();
        if (dl.terminal(state.progress.phase)) {
            if (state.failure) |err| return err;
            if (state.progress.phase != .complete) return error.DownloadFailed;
            return a.dupe(u8, state.result.?.bytes);
        }
        try io.sleep(.fromMilliseconds(10), .awake);
    }
}
fn component(name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.UnsafePath;
    for (name) |c| if (c == '/' or c == 92 or c == ':' or c == 0) return error.UnsafePath;
}
/// Reject existing symlink parents, including inside the configured root.
/// Caller must exclude concurrent hostile filesystem mutations.
fn ensureParents(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    var dir = try std.Io.Dir.cwd().openDir(io, if (std.fs.path.isAbsolute(parent)) "/" else ".", .{ .follow_symlinks = false });
    defer dir.close(io);
    var parts = std.mem.tokenizeAny(u8, parent, &.{ '/', 92 });
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        try dir.createDirPath(io, part);
        const next = try dir.openDir(io, part, .{ .follow_symlinks = false });
        dir.close(io);
        dir = next;
    }
}
fn verified(io: std.Io, file: planner.File, cancel: ?*const std.atomic.Value(bool)) !bool {
    const expected = file.sha1 orelse return false;
    const f = std.Io.Dir.cwd().openFile(io, file.path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer f.close(io);
    const stat = try f.stat(io);
    if (stat.kind != .file) return error.NotRegularFile;
    if (file.size) |size| if (stat.size != size) return false;
    var hash = std.crypto.hash.Sha1.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        try canceled(cancel);
        const n = try f.readPositional(io, &.{&buffer}, offset);
        if (n == 0) break;
        hash.update(buffer[0..n]);
        offset += n;
    }
    var digest: m.Sha1 = undefined;
    hash.final(&digest);
    return std.mem.eql(u8, &digest, &expected);
}
fn writeAtomic(a: A, io: std.Io, path: []const u8, data: []const u8) !void {
    try ensureParents(io, path);
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const hex = std.fmt.bytesToHex(nonce, .lower);
    const temporary = try std.fmt.allocPrint(a, "{s}.install-{s}", .{ path, hex });
    defer a.free(temporary);
    const file = try std.Io.Dir.cwd().createFile(io, temporary, .{ .exclusive = true });
    var closed = false;
    defer if (!closed) file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
    try file.writeStreamingAll(io, data);
    file.close(io);
    closed = true;
    try std.Io.Dir.cwd().rename(temporary, .cwd(), path, io);
}

test "existing files require streamed checksum and size verification" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const path = try std.fmt.allocPrint(a, "{s}/nested/object", .{buf[0..n]});
    defer a.free(path);
    const body = "verified game bytes";
    try writeAtomic(a, io, path, body);
    var sha: m.Sha1 = undefined;
    std.crypto.hash.Sha1.hash(body, &sha, .{});
    var file: planner.File = .{ .kind = .asset, .path = path, .url = "unused", .size = body.len, .sha1 = sha };
    try std.testing.expect(try verified(io, file, null));
    file.size = body.len + 1;
    try std.testing.expect(!try verified(io, file, null));
    file.size = body.len;
    try writeAtomic(a, io, path, "corrupted game byte");
    try std.testing.expect(!try verified(io, file, null));
    file.sha1 = null;
    try std.testing.expect(!try verified(io, file, null));
    var cancel = std.atomic.Value(bool).init(true);
    file.sha1 = sha;
    file.size = null;
    try std.testing.expectError(error.Canceled, verified(io, file, &cancel));
}

test "installation metadata IDs cannot escape their directory" {
    for ([_][]const u8{ "../evil", "/abs", "a/b", "C:bad", "..", "" }) |id|
        try std.testing.expectError(error.UnsafePath, component(id));
    try std.testing.expectError(error.UnsafePath, component(&.{ 'a', 92, 'b' }));
    try component("1.21.1");
}

test {
    _ = native;
}

//! Synchronous installation orchestration. Run outside the UI thread.
const std = @import("std");
const dl = @import("../downloader.zig");
const m = @import("metadata/root.zig");
const planner = @import("install_plan.zig");
const native = @import("native_extract.zig");
const loader = @import("metadata_loader.zig");
const loader_install = @import("loader_install.zig");
const loaders = @import("loaders.zig");
const instances = @import("../instances.zig");
const namespace = @import("../instance_namespace.zig");
const fs = @import("safe_fs.zig");
const builtin = @import("builtin");
const A = std.mem.Allocator;
pub const Progress = struct { completed: usize, total: usize, downloaded: usize, reused: usize };
pub const Config = struct {
    version_id: []const u8,
    root: []const u8 = ".minecraft",
    instance_name: ?[]const u8 = null,
    game_directory: ?[]const u8 = null,
    /// Stage extracted natives separately while root retains shared artifacts.
    natives_directory: ?[]const u8 = null,
    /// False prepares artifacts/aliases only; caller owns descriptor publication.
    publish_metadata: bool = true,
    /// Protects namespace name/reference scans only; it does not exclude launch.
    /// Managed callers must independently hold the stable-ID instance lease.
    /// Borrowed reservations remain owned by the caller through all cleanup.
    namespace_token: ?namespace.Token = null,
    /// Worker admission may wait for the short namespace stamp gate.
    worker_checks: bool = false,
    cpu_arch: ?[]const u8 = null,
    metadata_path: ?[]const u8 = null,
    metadata_limits: m.version.inheritance.Limits = .{},
    manifest_url: []const u8 = m.version_manifest_url,
    /// Metadata cache directory, owned by the caller and not shared by active services.
    http_cache: ?[]const u8 = null,
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
    try validateConfig(config);
    const token = try reserveNamespace(io, config.namespace_token, config.worker_checks);
    defer if (config.namespace_token == null) token.release();
    var reserved_config = config;
    reserved_config.namespace_token = token;
    const manifest_bytes = try fetch(a, io, service, config, config.manifest_url, null, null);
    defer a.free(manifest_bytes);
    var manifest = try m.manifest.parseSlice(a, manifest_bytes);
    defer manifest.deinit();
    var fetch_context: FetchContext = .{ .service = service, .config = config };
    const loaded = try loader.load(a, io, .{ .root = config.root, .version_id = config.version_id, .manifest = manifest.value, .metadata_path = config.metadata_path, .cancel = config.cancel, .limits = config.metadata_limits }, .{ .context = &fetch_context, .fetch = fetchMetadata });
    return installLoaded(a, io, service, reserved_config, loaded, null);
}

/// Replays an independently owned base without refetching version/loader metadata.
/// The caller retains prepared through subsequent loader installation and join.
pub fn runPrepared(a: A, io: std.Io, service: *dl.Service, config: Config, prepared: *const loader_install.PreparedMetadata, target: loader_install.MetadataTarget, control: loaders.Control) !Installed {
    try validateConfig(config);
    const token = try reserveNamespace(io, config.namespace_token, config.worker_checks);
    defer if (config.namespace_token == null) token.release();
    var reserved_config = config;
    reserved_config.namespace_token = token;
    try control.check();
    if (!std.mem.eql(u8, config.version_id, target.selection.base_id)) return error.PreparedMetadataMismatch;
    var expected_paths = try instances.Paths.init(a, io, target.root);
    defer expected_paths.deinit();
    var actual_paths = try instances.Paths.init(a, io, config.root);
    defer actual_paths.deinit();
    if (!std.mem.eql(u8, actual_paths.root, expected_paths.minecraft)) return error.PreparedMetadataMismatch;
    // Validate the real planner environment, not a stale caller target snapshot.
    var bound_target = target;
    bound_target.environment = config.environment;
    const loaded = try prepared.replayBase(a, io, bound_target, control);
    return installLoaded(a, io, service, reserved_config, loaded, control);
}

/// Replays a sealed vanilla base without manifest or version metadata refetch.
pub fn runVanillaPrepared(a: A, io: std.Io, service: *dl.Service, config: Config, prepared: *const loader.PreparedVanilla, target: loader.VanillaTarget) !Installed {
    try validateConfig(config);
    const token = try reserveNamespace(io, config.namespace_token, config.worker_checks);
    defer if (config.namespace_token == null) token.release();
    var reserved_config = config;
    reserved_config.namespace_token = token;
    if (!std.mem.eql(u8, config.version_id, target.version_id)) return error.PreparedMetadataMismatch;
    var expected_paths = try instances.Paths.init(a, io, target.root);
    defer expected_paths.deinit();
    var actual_paths = try instances.Paths.init(a, io, config.root);
    defer actual_paths.deinit();
    if (!std.mem.eql(u8, actual_paths.root, expected_paths.minecraft)) return error.PreparedMetadataMismatch;
    var bound_target = target;
    bound_target.environment = config.environment;
    const loaded = try prepared.replayBase(a, io, bound_target, config.cancel);
    return installLoaded(a, io, service, reserved_config, loaded, null);
}

fn reserveNamespace(io: std.Io, borrowed: ?namespace.Token, worker: bool) !namespace.Token {
    if (borrowed) |token| {
        if (worker) try token.recheckWaiting() else try token.recheck();
        return token;
    }
    return if (worker) namespace.acquireWaiting(io) else namespace.acquire(io);
}

fn validateConfig(config: Config) !void {
    if (config.window == 0 or config.window > 128) return error.InvalidWindow;
    try m.version.validateId(config.version_id);
    if (config.instance_name) |name| try m.version.validateId(name);
    try canceled(config.cancel);
}

// Consumes both loaded owners: sources always release; version moves on success.
fn installLoaded(a: A, io: std.Io, service: *dl.Service, config: Config, owned_loaded: loader.Loaded, loader_control: ?loaders.Control) !Installed {
    const token = reserveNamespace(io, config.namespace_token, config.worker_checks) catch |err| {
        var failed_loaded = owned_loaded;
        failed_loaded.deinit();
        return err;
    };
    // Registered first so task drain, native cleanup and every close finish first.
    defer if (config.namespace_token == null) token.release();
    var loaded = owned_loaded;
    defer loaded.sources.deinit();
    var version = loaded.version;
    errdefer version.deinit();
    const control: InstallControl = .{ .cancel = config.cancel, .loader = loader_control };
    try control.check();
    const index = version.value.asset_index orelse return error.MissingAssetIndex;
    try component(index.id);
    const assets_bytes = try fetchBoundedControlled(a, io, service, config, index.url, index.sha1, index.size, 64 * 1024 * 1024, control);
    defer a.free(assets_bytes);
    var assets = try m.asset_index.parseSlice(a, assets_bytes);
    defer assets.deinit();
    try control.check();
    const cpu_arch = config.cpu_arch orelse @tagName(builtin.cpu.arch);
    var plan = try planner.build(a, version.value, assets.value, config.environment, .{ .root = config.root, .natives = config.natives_directory, .native_arch = config.native_arch, .cpu_arch = cpu_arch, .instance_name = config.instance_name, .game_directory = config.game_directory });
    errdefer plan.deinit();
    try control.check();
    var publication_config = config;
    publication_config.namespace_token = token;
    publication_config.version_id = version.value.id;
    publication_config.instance_name = config.instance_name orelse config.version_id;
    const descriptor: ?Publication = if (config.publish_metadata) try preparePublicationControlled(a, io, publication_config, loaded.sources.value, control) else null;
    defer if (descriptor) |value| {
        a.free(value.bytes);
        a.free(value.path);
    };
    for (plan.value.files) |file| if (file.kind == .asset_index) {
        try control.check();
        try fs.writeAtomic(a, io, file.path, assets_bytes, config.cancel);
        try control.check();
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
        try control.check();
        while (cursor < plan.value.files.len and tasks.items.len < config.window) {
            const file = plan.value.files[cursor];
            try control.check();
            try ensureParents(io, file.path);
            try control.check();
            if (file.kind == .asset_index or try verifiedControlled(io, file, control)) {
                reused += 1;
                if (config.progress) |report| report(.{ .completed = reused + downloaded, .total = plan.value.files.len, .downloaded = downloaded, .reused = reused });
                try control.check();
                cursor += 1;
                continue;
            }
            try control.check();
            const task = service.submit(.{ .url = file.url, .output = .{ .file = file.path }, .expected_sha1 = file.sha1, .expected_size = file.size, .proxy = config.proxy, .ca_bundle = config.ca_bundle }) catch |err| {
                try control.check();
                if (err == error.QueueFull and tasks.items.len != 0) break;
                return err;
            };
            tasks.appendAssumeCapacity(task);
            try control.check();
            cursor += 1;
        }
        var i: usize = 0;
        while (i < tasks.items.len) {
            try control.check();
            const task = tasks.items[i];
            const snapshot = task.snapshot();
            if (!dl.terminal(snapshot.progress.phase)) {
                i += 1;
                continue;
            }
            _ = tasks.swapRemove(i);
            try task.release();
            try control.check();
            if (snapshot.failure) |err| return err;
            if (snapshot.progress.phase != .complete) return error.DownloadFailed;
            downloaded += 1;
            if (config.progress) |report| report(.{ .completed = reused + downloaded, .total = plan.value.files.len, .downloaded = downloaded, .reused = reused });
            try control.check();
        }
        if (tasks.items.len != 0) {
            try control.check();
            try io.sleep(.fromMilliseconds(10), .awake);
            try control.check();
        }
    }
    for (plan.value.native_checks) |check| {
        try control.check();
        try native.inspect(a, io, check.archive_path, cpu_arch, config.cancel);
        try control.check();
    }
    // Shared destinations must remain one native merge transaction.
    try control.check();
    try native.extractChecked(a, io, plan.value.native_extractions, cpu_arch, config.cancel);
    try control.check();
    for (plan.value.asset_materializations) |alias| {
        try control.check();
        try materializeControlled(a, io, alias, control);
        try control.check();
    }
    if (descriptor) |value| try publishMetadataControlled(a, io, publication_config, loaded.sources.value, value, control) else try control.check();
    return .{ .version = version, .plan = plan, .downloaded = downloaded, .reused = reused };
}
const InstallControl = struct {
    cancel: fs.Cancel = null,
    loader: ?loaders.Control = null,
    fn check(self: InstallControl) !void {
        try canceled(self.cancel);
        if (self.loader) |control| try control.check();
    }
};
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
const FetchContext = struct { service: *dl.Service, config: Config };
fn fetchMetadata(context: ?*anyopaque, a: A, io: std.Io, request: loader.Request) anyerror![]u8 {
    const state: *FetchContext = @ptrCast(@alignCast(context orelse return error.MissingVersionMetadata));
    return fetchBounded(a, io, state.service, state.config, request.url, request.sha1, request.size, request.max_bytes);
}
fn fetch(a: A, io: std.Io, service: *dl.Service, config: Config, url: []const u8, sha1: ?m.Sha1, size: ?u64) ![]u8 {
    return fetchBounded(a, io, service, config, url, sha1, size, 64 * 1024 * 1024);
}
fn fetchBounded(a: A, io: std.Io, service: *dl.Service, config: Config, url: []const u8, sha1: ?m.Sha1, size: ?u64, max_bytes: usize) ![]u8 {
    return fetchBoundedControlled(a, io, service, config, url, sha1, size, max_bytes, .{ .cancel = config.cancel });
}
fn fetchBoundedControlled(a: A, io: std.Io, service: *dl.Service, config: Config, url: []const u8, sha1: ?m.Sha1, size: ?u64, max_bytes: usize, control: InstallControl) ![]u8 {
    try control.check();
    const cache_path = if (config.http_cache) |directory| blk: {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        const filename = try std.fmt.allocPrint(a, "{s}.json", .{hex});
        defer a.free(filename);
        const path = try std.fs.path.join(a, &.{ directory, filename });
        errdefer a.free(path);
        try control.check();
        try ensureParents(io, path);
        try control.check();
        break :blk path;
    } else null;
    defer if (cache_path) |path| a.free(path);
    try control.check();
    const task = try service.submit(.{ .url = url, .output = .bytes, .expected_sha1 = sha1, .expected_size = size, .max_bytes = max_bytes, .proxy = config.proxy, .ca_bundle = config.ca_bundle, .cache_path = cache_path });
    defer drain(io, &.{task});
    try control.check();
    while (true) {
        try control.check();
        const state = task.snapshot();
        if (dl.terminal(state.progress.phase)) {
            if (state.failure) |err| return err;
            if (state.progress.phase != .complete) return error.DownloadFailed;
            const bytes = try a.dupe(u8, state.result.?.bytes);
            errdefer a.free(bytes);
            try control.check();
            return bytes;
        }
        try control.check();
        try io.sleep(.fromMilliseconds(10), .awake);
        try control.check();
    }
}
fn component(name: []const u8) !void {
    try fs.component(name);
}
/// Reject existing symlink parents, including inside the configured root.
/// Caller must exclude concurrent hostile filesystem mutations.
fn ensureParents(io: std.Io, path: []const u8) !void {
    var parent = try fs.openParent(io, path, true);
    parent.close(io);
}
fn verified(io: std.Io, file: planner.File, cancel: ?*const std.atomic.Value(bool)) !bool {
    return verifiedControlled(io, file, .{ .cancel = cancel });
}
fn verifiedControlled(io: std.Io, file: planner.File, control: InstallControl) !bool {
    try control.check();
    const expected = file.sha1 orelse return false;
    const f = fs.openFile(io, file.path) catch |err| {
        try control.check();
        switch (err) {
            error.FileNotFound => return false,
            else => return err,
        }
    };
    defer f.close(io);
    try control.check();
    const stat = try f.stat(io);
    try control.check();
    if (stat.kind != .file) return error.NotRegularFile;
    if (file.size) |size| if (stat.size != size) return false;
    var hash = std.crypto.hash.Sha1.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        try control.check();
        const n = try f.readPositional(io, &.{&buffer}, offset);
        try control.check();
        if (n == 0) break;
        hash.update(buffer[0..n]);
        offset += n;
    }
    var digest: m.Sha1 = undefined;
    hash.final(&digest);
    return std.mem.eql(u8, &digest, &expected);
}
fn writeAtomic(a: A, io: std.Io, path: []const u8, data: []const u8) !void {
    try fs.writeAtomic(a, io, path, data, null);
}

const Publication = struct { path: []const u8, bytes: []const u8 };
fn existingMatches(a: A, io: std.Io, path: []const u8, bytes: []const u8, cancel: fs.Cancel) !bool {
    return existingMatchesControlled(a, io, path, bytes, .{ .cancel = cancel });
}
fn existingMatchesControlled(a: A, io: std.Io, path: []const u8, bytes: []const u8, control: InstallControl) !bool {
    try control.check();
    const existing = fs.read(a, io, path, m.version.max_document_bytes, control.cancel) catch |err| {
        try control.check();
        switch (err) {
            error.FileNotFound => return false,
            else => return err,
        }
    };
    defer a.free(existing);
    try control.check();
    if (!std.mem.eql(u8, bytes, existing)) return error.InstanceMetadataCollision;
    return true;
}
fn preparePublication(a: A, io: std.Io, config: Config, sources: []const loader.Source) !Publication {
    return preparePublicationControlled(a, io, config, sources, .{ .cancel = config.cancel });
}
fn preparePublicationControlled(a: A, io: std.Io, config: Config, sources: []const loader.Source, control: InstallControl) !Publication {
    const token = try reserveNamespace(io, config.namespace_token, config.worker_checks);
    defer if (config.namespace_token == null) token.release();
    try control.check();
    const name = config.instance_name orelse config.version_id;
    try m.version.validateId(name);
    const path = try loader.docPath(a, config.root, name);
    errdefer a.free(path);
    var leaf: ?[]const u8 = null;
    for (sources, 0..) |source, i| {
        try control.check();
        for (sources[0..i]) |prior| if (std.ascii.eqlIgnoreCase(prior.id, source.id)) return error.InstanceMetadataCollision;
        if (std.mem.eql(u8, source.id, config.version_id)) leaf = source.bytes;
        if (std.ascii.eqlIgnoreCase(source.id, name) and (!std.mem.eql(u8, source.id, name) or !std.mem.eql(u8, source.id, config.version_id))) return error.InstanceMetadataCollision;
        const source_path = try loader.docPath(a, config.root, source.id);
        defer a.free(source_path);
        _ = try existingMatchesControlled(a, io, source_path, source.bytes, control);
    }
    const bytes = if (std.mem.eql(u8, name, config.version_id)) try a.dupe(u8, leaf orelse return error.MissingVersionMetadata) else try std.json.Stringify.valueAlloc(a, .{ .id = name, .inheritsFrom = config.version_id }, .{});
    errdefer a.free(bytes);
    _ = try existingMatchesControlled(a, io, path, bytes, control);
    try control.check();
    return .{ .path = path, .bytes = bytes };
}
fn publishMetadata(a: A, io: std.Io, config: Config, sources: []const loader.Source, descriptor: Publication) !void {
    return publishMetadataControlled(a, io, config, sources, descriptor, .{ .cancel = config.cancel });
}
fn publishMetadataControlled(a: A, io: std.Io, config: Config, sources: []const loader.Source, descriptor: Publication, control: InstallControl) !void {
    const token = try reserveNamespace(io, config.namespace_token, config.worker_checks);
    defer if (config.namespace_token == null) token.release();
    try control.check();
    _ = try existingMatchesControlled(a, io, descriptor.path, descriptor.bytes, control);
    for (sources) |source| {
        try control.check();
        const path = try loader.docPath(a, config.root, source.id);
        defer a.free(path);
        if (std.mem.eql(u8, path, descriptor.path)) continue;
        if (!try existingMatchesControlled(a, io, path, source.bytes, control)) {
            try control.check();
            try fs.writeAtomic(a, io, path, source.bytes, control.cancel);
            try control.check();
        }
    }
    // The final rename is the success boundary; never check cancellation afterward.
    _ = try existingMatchesControlled(a, io, descriptor.path, descriptor.bytes, control);
    try control.check();
    try fs.writeAtomic(a, io, descriptor.path, descriptor.bytes, control.cancel);
}
fn materialize(a: A, io: std.Io, alias: planner.AssetMaterialization, cancel: fs.Cancel) !void {
    return materializeControlled(a, io, alias, .{ .cancel = cancel });
}
fn materializeControlled(a: A, io: std.Io, alias: planner.AssetMaterialization, control: InstallControl) !void {
    const file: planner.File = .{ .kind = .asset, .url = "unused", .path = alias.destination, .sha1 = alias.sha1, .size = alias.size };
    if (try verifiedControlled(io, file, control)) return;
    try control.check();
    const source = try fs.openFile(io, alias.source_path);
    defer source.close(io);
    try control.check();
    const stat = try source.stat(io);
    try control.check();
    if (stat.size != alias.size) return error.AssetSizeMismatch;
    var parent = try fs.openParent(io, alias.destination, true);
    defer parent.close(io);
    try control.check();
    const name = std.fs.path.basename(alias.destination);
    const old = parent.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    try control.check();
    if (old) |info| if (info.kind != .file) return error.UnsafeDestination;
    var random: [16]u8 = undefined;
    io.random(&random);
    const temp = try std.fmt.allocPrint(a, ".asset-{s}", .{std.fmt.bytesToHex(random, .lower)});
    defer a.free(temp);
    try control.check();
    const output = try parent.createFile(io, temp, .{ .exclusive = true });
    var closed = false;
    defer if (!closed) output.close(io);
    defer parent.deleteFile(io, temp) catch {};
    try control.check();
    var hash = std.crypto.hash.Sha1.init(.{});
    var buffer: [65536]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        try control.check();
        const n = try source.readPositional(io, &.{&buffer}, offset);
        try control.check();
        if (n == 0) break;
        offset = std.math.add(u64, offset, n) catch return error.AssetSizeMismatch;
        if (offset > alias.size) return error.AssetSizeMismatch;
        hash.update(buffer[0..n]);
        try control.check();
        try output.writeStreamingAll(io, buffer[0..n]);
        try control.check();
    }
    var digest: m.Sha1 = undefined;
    hash.final(&digest);
    if (offset != alias.size) return error.AssetSizeMismatch;
    if (!std.mem.eql(u8, &digest, &alias.sha1)) return error.AssetChecksumMismatch;
    try control.check();
    try output.sync(io);
    try control.check();
    output.close(io);
    closed = true;
    try control.check();
    try parent.rename(temp, parent, name, io);
    try control.check();
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
    _ = loader;
    _ = fs;
}

test "executor invalid window fails before metadata IO" {
    var service: dl.Service = undefined;
    try std.testing.expectError(error.InvalidWindow, run(std.testing.allocator, std.testing.io, &service, .{ .version_id = "fixture", .environment = .{ .os_name = "linux", .arch = "x86_64" }, .window = 0 }));
}

test "version publication retains sources and rejects metadata collisions" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    const root = buffer[0..n];
    const sources = [_]loader.Source{ .{ .id = "base", .bytes = "{\"id\":\"base\"}" }, .{ .id = "forge", .bytes = "{\"id\":\"forge\",\"inheritsFrom\":\"base\"}" } };
    var config: Config = .{ .version_id = "forge", .instance_name = "My Forge", .root = root, .environment = .{ .os_name = "linux", .arch = "x86_64" } };
    const descriptor = try preparePublication(a, io, config, &sources);
    defer a.free(descriptor.path);
    defer a.free(descriptor.bytes);
    try std.testing.expectError(error.FileNotFound, fs.read(a, io, descriptor.path, 1024, null));
    var cancel = std.atomic.Value(bool).init(true);
    config.cancel = &cancel;
    try std.testing.expectError(error.Canceled, publishMetadata(a, io, config, &sources, descriptor));
    try std.testing.expectError(error.FileNotFound, fs.read(a, io, descriptor.path, 1024, null));
    cancel.store(false, .release);
    try publishMetadata(a, io, config, &sources, descriptor);
    const bytes = try fs.read(a, io, descriptor.path, 1024, null);
    defer a.free(bytes);
    var document = try m.version.parseSlice(a, bytes);
    defer document.deinit();
    try std.testing.expectEqualStrings("My Forge", document.value.id);
    try std.testing.expectEqualStrings("forge", document.value.inherits_from.?);
    const base_path = try loader.docPath(a, root, "base");
    defer a.free(base_path);
    const base_bytes = try fs.read(a, io, base_path, 1024, null);
    defer a.free(base_bytes);
    try std.testing.expectEqualStrings(sources[0].bytes, base_bytes);
    const repeated = try preparePublication(a, io, config, &sources);
    defer a.free(repeated.path);
    defer a.free(repeated.bytes);
    config.instance_name = "base";
    try std.testing.expectError(error.InstanceMetadataCollision, preparePublication(a, io, config, &sources));
    config.instance_name = "FORGE";
    try std.testing.expectError(error.InstanceMetadataCollision, preparePublication(a, io, config, &sources));
    config.instance_name = "My Forge";
    var changed = sources;
    changed[1].bytes = "{\"id\":\"forge\",\"mainClass\":\"Other\"}";
    try std.testing.expectError(error.InstanceMetadataCollision, preparePublication(a, io, config, &changed));
    try std.testing.expect(try existingMatches(a, io, descriptor.path, descriptor.bytes, null));
    try writeAtomic(a, io, descriptor.path, "unrelated user descriptor");
    try std.testing.expectError(error.InstanceMetadataCollision, publishMetadata(a, io, config, &sources, descriptor));
    const retained = try fs.read(a, io, descriptor.path, 1024, null);
    defer a.free(retained);
    try std.testing.expectEqualStrings("unrelated user descriptor", retained);
}

test "asset materialization verifies repairs and preserves prior bytes on failure" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    const source = try std.fmt.allocPrint(a, "{s}/objects/source", .{buffer[0..n]});
    defer a.free(source);
    const destination = try std.fmt.allocPrint(a, "{s}/resources/sound.ogg", .{buffer[0..n]});
    defer a.free(destination);
    const body = "asset fixture bytes";
    var hash: m.Sha1 = undefined;
    std.crypto.hash.Sha1.hash(body, &hash, .{});
    const alias: planner.AssetMaterialization = .{ .source_path = source, .destination = destination, .sha1 = hash, .size = body.len };
    try writeAtomic(a, io, source, body);
    try materialize(a, io, alias, null);
    const good = try fs.read(a, io, destination, 1024, null);
    defer a.free(good);
    try std.testing.expectEqualStrings(body, good);
    try materialize(a, io, alias, null);
    try writeAtomic(a, io, destination, "prior bytes");
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Canceled, materialize(a, io, alias, &cancel));
    try writeAtomic(a, io, source, "wrong fixture bytes");
    try std.testing.expectError(error.AssetChecksumMismatch, materialize(a, io, alias, null));
    const preserved = try fs.read(a, io, destination, 1024, null);
    defer a.free(preserved);
    try std.testing.expectEqualStrings("prior bytes", preserved);
    try writeAtomic(a, io, source, body);
    try materialize(a, io, alias, null);
    const repaired = try fs.read(a, io, destination, 1024, null);
    defer a.free(repaired);
    try std.testing.expectEqualStrings(body, repaired);
}

fn preparedRunNow(_: ?*anyopaque) u64 {
    return 0;
}
const prepared_run_control: loaders.Control = .{ .deadline_ms = 1, .now_ms = preparedRunNow };
// Missing assetIndex deliberately stops the shared executor before service/files IO.
const prepared_run_base =
    \\{"id":"1.20.1","mainClass":"vanilla.Main","libraries":[],"javaVersion":{"component":"java-runtime-gamma","majorVersion":17},"downloads":{"client":{"url":"https://piston-data.mojang.com/client.jar","sha1":"0000000000000000000000000000000000000000","size":8}}}
;
const prepared_run_profile =
    \\{"id":"fabric-fixture","inheritsFrom":"1.20.1","mainClass":"net.fabricmc.loader.impl.launch.knot.KnotClient","libraries":[{"name":"net.fabricmc:fabric-loader:0.16.0","url":"https://maven.fabricmc.net/"}]}
;
const PreparedRunFixture = struct {
    entries: [1]m.manifest.Entry = undefined,
    vanilla_calls: usize = 0,
    loader_calls: usize = 0,

    fn prepare(self: *PreparedRunFixture, a: A, io: std.Io, root: []const u8) !loader_install.PreparedMetadata {
        var checksum: m.Sha1 = undefined;
        std.crypto.hash.Sha1.hash(prepared_run_base, &checksum, .{});
        self.entries = .{.{ .id = "1.20.1", .kind = "release", .url = "https://piston-meta.mojang.com/v1/packages/fixture/1.20.1.json", .time = "", .release_time = "", .sha1 = checksum, .compliance_level = null }};
        const metadata_root = try std.fs.path.join(a, &.{ root, ".minecraft" });
        defer a.free(metadata_root);
        return loader_install.prepareMetadata(a, io, .{
            .root = root,
            .instance_id = "pack-fixture",
            .instance_name = "Final Pack",
            .generation = 7,
            .selection = .{ .kind = .fabric, .base_id = "1.20.1", .loader_id = "0.16.0" },
            .environment = .{ .os_name = "linux", .arch = "x86_64" },
            .vanilla = .{ .root = metadata_root, .version_id = "1.20.1", .manifest = .{ .latest = .{ .release = "1.20.1", .snapshot = "1.20.1" }, .versions = &self.entries } },
            .fetcher = .{ .context = self, .fetch = vanilla },
            .transport = .{ .context = self, .get = get },
        }, prepared_run_control);
    }
    fn vanilla(raw: ?*anyopaque, a: A, _: std.Io, request: loader.Request) ![]u8 {
        const self: *PreparedRunFixture = @ptrCast(@alignCast(raw.?));
        self.vanilla_calls += 1;
        try std.testing.expect(request.sha1 != null);
        return a.dupe(u8, prepared_run_base);
    }
    fn get(raw: ?*anyopaque, a: A, url: []const u8, _: usize, control: loaders.Control) !loaders.Response {
        try control.check();
        const self: *PreparedRunFixture = @ptrCast(@alignCast(raw.?));
        self.loader_calls += 1;
        const body = if (std.mem.endsWith(u8, url, "/v2/versions/loader/1.20.1"))
            try a.dupe(u8, "[{\"loader\":{\"version\":\"0.16.0\",\"stable\":true}}]")
        else if (std.mem.endsWith(u8, url, "/profile/json"))
            try a.dupe(u8, prepared_run_profile)
        else
            return error.UnexpectedFixtureRequest;
        errdefer a.free(body);
        return .{ .bytes = body, .final_url = try a.dupe(u8, url), .status = 200 };
    }
};
fn preparedRunTarget(prepared: *const loader_install.PreparedMetadata) loader_install.MetadataTarget {
    return .{ .root = prepared.root, .instance_id = prepared.instance_id, .instance_name = prepared.instance_name, .generation = prepared.generation, .selection = prepared.selection, .environment = prepared.environment };
}
fn preparedRunConfig(minecraft: []const u8) Config {
    return .{ .version_id = "1.20.1", .root = minecraft, .instance_name = "private-stage", .environment = .{ .os_name = "linux", .arch = "x86_64" }, .manifest_url = "https://example.invalid/not-replay", .metadata_path = "missing-prepared-version.json" };
}

test "prepared executor binds final target and actual planner environment before artifact IO" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const minecraft = try std.fs.path.join(a, &.{ root, ".minecraft" });
    defer a.free(minecraft);
    var fixture: PreparedRunFixture = .{};
    var prepared = try fixture.prepare(a, io, root);
    defer prepared.deinit();
    const target = preparedRunTarget(&prepared);
    const config = preparedRunConfig(minecraft);
    var service: dl.Service = undefined;
    // Private stage name must not be compared with the final prepared name.
    try std.testing.expectError(error.MissingAssetIndex, runPrepared(a, io, &service, config, &prepared, target, prepared_run_control));
    var wrong_target = target;
    wrong_target.generation = 8;
    try std.testing.expectError(error.PreparedMetadataGenerationMismatch, runPrepared(a, io, &service, config, &prepared, wrong_target, prepared_run_control));
    wrong_target = target;
    wrong_target.generation = 0;
    try std.testing.expectError(error.PreparedMetadataGenerationMismatch, runPrepared(a, io, &service, config, &prepared, wrong_target, prepared_run_control));
    wrong_target = target;
    wrong_target.instance_id = "different-instance";
    try std.testing.expectError(error.PreparedMetadataMismatch, runPrepared(a, io, &service, config, &prepared, wrong_target, prepared_run_control));
    wrong_target = target;
    wrong_target.instance_name = "different-final-name";
    try std.testing.expectError(error.PreparedMetadataMismatch, runPrepared(a, io, &service, config, &prepared, wrong_target, prepared_run_control));
    wrong_target = target;
    wrong_target.selection.loader_id = "changed-loader";
    try std.testing.expectError(error.PreparedMetadataMismatch, runPrepared(a, io, &service, config, &prepared, wrong_target, prepared_run_control));
    var wrong_config = config;
    wrong_config.version_id = "1.20.2";
    try std.testing.expectError(error.PreparedMetadataMismatch, runPrepared(a, io, &service, wrong_config, &prepared, target, prepared_run_control));
    wrong_config = config;
    wrong_config.root = root;
    try std.testing.expectError(error.PreparedMetadataMismatch, runPrepared(a, io, &service, wrong_config, &prepared, target, prepared_run_control));
    wrong_config = config;
    wrong_config.environment.arch = "aarch64";
    try std.testing.expectError(error.PreparedMetadataMismatch, runPrepared(a, io, &service, wrong_config, &prepared, target, prepared_run_control));
    wrong_config = config;
    wrong_config.environment.os_version = "changed-os";
    try std.testing.expectError(error.PreparedMetadataMismatch, runPrepared(a, io, &service, wrong_config, &prepared, target, prepared_run_control));
    wrong_config = config;
    wrong_config.environment.features = &.{.{ .name = "demo", .enabled = true }};
    try std.testing.expectError(error.PreparedMetadataMismatch, runPrepared(a, io, &service, wrong_config, &prepared, target, prepared_run_control));
    try std.testing.expectEqual(@as(usize, 1), fixture.vanilla_calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.loader_calls);
    const stage_descriptor = try std.fs.path.join(a, &.{ minecraft, "versions", "private-stage", "private-stage.json" });
    defer a.free(stage_descriptor);
    try std.testing.expectError(error.FileNotFound, fs.read(a, io, stage_descriptor, 1024, null));
}

test "prepared executor validates window IDs cancellation and deadline without touching owners" {
    const prepared: loader_install.PreparedMetadata = undefined;
    const target: loader_install.MetadataTarget = .{ .root = ".", .instance_id = "pack-fixture", .instance_name = "Final Pack", .generation = 7, .selection = .{ .kind = .fabric, .base_id = "1.20.1", .loader_id = "0.16.0" }, .environment = .{ .os_name = "linux", .arch = "x86_64" } };
    var service: dl.Service = undefined;
    var config = preparedRunConfig(".minecraft");
    config.window = 0;
    try std.testing.expectError(error.InvalidWindow, runPrepared(std.testing.allocator, std.testing.io, &service, config, &prepared, target, prepared_run_control));
    config.window = 129;
    try std.testing.expectError(error.InvalidWindow, runPrepared(std.testing.allocator, std.testing.io, &service, config, &prepared, target, prepared_run_control));
    config.window = 16;
    config.version_id = "../escape";
    try std.testing.expectError(error.UnsafeVersionId, runPrepared(std.testing.allocator, std.testing.io, &service, config, &prepared, target, prepared_run_control));
    config.version_id = "1.20.1";
    config.instance_name = "../escape";
    try std.testing.expectError(error.UnsafeVersionId, runPrepared(std.testing.allocator, std.testing.io, &service, config, &prepared, target, prepared_run_control));
    config.instance_name = "private-stage";
    var cancel = std.atomic.Value(bool).init(true);
    config.cancel = &cancel;
    try std.testing.expectError(error.Canceled, runPrepared(std.testing.allocator, std.testing.io, &service, config, &prepared, target, prepared_run_control));
    config.cancel = null;
    var control = prepared_run_control;
    control.cancel = &cancel;
    try std.testing.expectError(error.Canceled, runPrepared(std.testing.allocator, std.testing.io, &service, config, &prepared, target, control));
    control.cancel = null;
    control.deadline_ms = 0;
    try std.testing.expectError(error.DeadlineExceeded, runPrepared(std.testing.allocator, std.testing.io, &service, config, &prepared, target, control));
}

test "prepared executor preserves frozen owners across shared-executor errors and rejects mutation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const minecraft = try std.fs.path.join(a, &.{ root, ".minecraft" });
    defer a.free(minecraft);
    var fixture: PreparedRunFixture = .{};
    var prepared = try fixture.prepare(a, io, root);
    defer prepared.deinit();
    const target = preparedRunTarget(&prepared);
    const config = preparedRunConfig(minecraft);
    var service: dl.Service = undefined;
    const original_class = prepared.base.value.main_class;
    prepared.base.value.main_class = "changed.Main";
    try std.testing.expectError(error.PreparedMetadataChanged, runPrepared(a, io, &service, config, &prepared, target, prepared_run_control));
    prepared.base.value.main_class = original_class;
    const original_profile = prepared.bundle.profile;
    prepared.bundle.profile = "{}";
    try std.testing.expectError(error.PreparedMetadataChanged, runPrepared(a, io, &service, config, &prepared, target, prepared_run_control));
    prepared.bundle.profile = original_profile;
    for (0..2) |_| try std.testing.expectError(error.MissingAssetIndex, runPrepared(a, io, &service, config, &prepared, target, prepared_run_control));
    try prepared.validateBinding(a, io, target);
    try std.testing.expectEqualStrings("vanilla.Main", prepared.base.value.main_class.?);
    try std.testing.expectEqualStrings(prepared_run_base, prepared.vanilla_sources[0].bytes);
    try std.testing.expectEqual(@as(usize, 1), fixture.vanilla_calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.loader_calls);
}

fn preparedRunAllocationFailure(a: A, config: Config, prepared: *const loader_install.PreparedMetadata, target: loader_install.MetadataTarget) !void {
    var service: dl.Service = undefined;
    var installed = runPrepared(a, std.testing.io, &service, config, prepared, target, prepared_run_control) catch |err| switch (err) {
        error.MissingAssetIndex => return,
        else => return err,
    };
    installed.deinit();
    return error.UnexpectedFixtureInstallSuccess;
}
test "prepared replay and consuming executor release independent owners on every allocation failure" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const minecraft = try std.fs.path.join(a, &.{ root, ".minecraft" });
    defer a.free(minecraft);
    var fixture: PreparedRunFixture = .{};
    var prepared = try fixture.prepare(a, io, root);
    defer prepared.deinit();
    const target = preparedRunTarget(&prepared);
    try std.testing.checkAllAllocationFailures(a, preparedRunAllocationFailure, .{ preparedRunConfig(minecraft), &prepared, target });
    try prepared.validateBinding(a, io, target);
    try std.testing.expectEqual(@as(usize, 1), fixture.vanilla_calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.loader_calls);
}

test "vanilla prepared executor validates config binding and cancellation before reading owner" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const prepared: loader.PreparedVanilla = undefined;
    const target: loader.VanillaTarget = .{ .root = ".", .instance_id = "vanilla-fixture", .instance_name = "Final Vanilla", .version_id = "1.20.1", .generation = 7, .environment = .{ .os_name = "linux", .arch = "x86_64" } };
    var service: dl.Service = undefined;
    var config = preparedRunConfig(".minecraft");
    config.window = 0;
    try std.testing.expectError(error.InvalidWindow, runVanillaPrepared(a, io, &service, config, &prepared, target));
    config.window = 129;
    try std.testing.expectError(error.InvalidWindow, runVanillaPrepared(a, io, &service, config, &prepared, target));
    config.window = 16;
    config.version_id = "../escape";
    try std.testing.expectError(error.UnsafeVersionId, runVanillaPrepared(a, io, &service, config, &prepared, target));
    config.version_id = "1.20.1";
    config.instance_name = "../escape";
    try std.testing.expectError(error.UnsafeVersionId, runVanillaPrepared(a, io, &service, config, &prepared, target));
    config.instance_name = "private-stage";
    var cancel = std.atomic.Value(bool).init(true);
    config.cancel = &cancel;
    try std.testing.expectError(error.Canceled, runVanillaPrepared(a, io, &service, config, &prepared, target));
    config.cancel = null;
    config.version_id = "1.20.2";
    try std.testing.expectError(error.PreparedMetadataMismatch, runVanillaPrepared(a, io, &service, config, &prepared, target));
    config.version_id = "1.20.1";
    config.root = "different-vanilla-root";
    try std.testing.expectError(error.PreparedMetadataMismatch, runVanillaPrepared(a, io, &service, config, &prepared, target));
}

fn vanillaRunTarget(root: []const u8) loader.VanillaTarget {
    return .{ .root = root, .instance_id = "vanilla-fixture", .instance_name = "Final Vanilla", .version_id = "1.20.1", .generation = 7, .environment = .{ .os_name = "linux", .arch = "x86_64" } };
}
fn vanillaRunAllocationFailure(a: A, config: Config, prepared: *const loader.PreparedVanilla, target: loader.VanillaTarget) !void {
    var service: dl.Service = undefined;
    var installed = runVanillaPrepared(a, std.testing.io, &service, config, prepared, target) catch |err| switch (err) {
        error.MissingAssetIndex => return,
        else => return err,
    };
    installed.deinit();
    return error.UnexpectedFixtureInstallSuccess;
}

const VanillaRunFixture = struct {
    entries: [1]m.manifest.Entry = undefined,
    calls: usize = 0,

    fn prepare(self: *VanillaRunFixture, a: A, io: std.Io, root: []const u8) !loader.PreparedVanilla {
        var paths = try instances.Paths.init(a, io, root);
        defer paths.deinit();
        var checksum: m.Sha1 = undefined;
        std.crypto.hash.Sha1.hash(prepared_run_base, &checksum, .{});
        self.entries = .{.{ .id = "1.20.1", .kind = "release", .url = "https://piston-meta.mojang.com/v1/packages/fixture/1.20.1.json", .time = "", .release_time = "", .sha1 = checksum, .compliance_level = null }};
        return loader.prepareVanilla(a, io, .{
            .target = vanillaRunTarget(root),
            .vanilla = .{ .root = paths.minecraft, .version_id = "1.20.1", .manifest = .{ .latest = .{ .release = "1.20.1", .snapshot = "1.20.1" }, .versions = &self.entries } },
            .fetcher = .{ .context = self, .fetch = VanillaRunFixture.fetch },
        });
    }
    fn fetch(raw: ?*anyopaque, a: A, _: std.Io, request: loader.Request) ![]u8 {
        const self: *VanillaRunFixture = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        try std.testing.expectEqualStrings("1.20.1", request.id);
        try std.testing.expect(request.sha1 != null);
        return a.dupe(u8, prepared_run_base);
    }
};
// Both the metadata owner and executor must reject before artifact IO.
fn expectVanillaBindingError(expected: anyerror, a: A, io: std.Io, service: *dl.Service, config: Config, prepared: *const loader.PreparedVanilla, target: loader.VanillaTarget) !void {
    var bound_target = target;
    bound_target.environment = config.environment;
    try std.testing.expectError(expected, prepared.validateBinding(a, io, bound_target));
    try std.testing.expectError(expected, runVanillaPrepared(a, io, service, config, prepared, target));
}

test "vanilla prepared executor binds sealed target and real environment without metadata refetch" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const minecraft = try std.fs.path.join(a, &.{ root, ".minecraft" });
    defer a.free(minecraft);
    var fixture: VanillaRunFixture = .{};
    var prepared = try fixture.prepare(a, io, root);
    defer prepared.deinit();
    const target = vanillaRunTarget(root);
    const config = preparedRunConfig(minecraft);
    var service: dl.Service = undefined;
    // The private stage name is intentionally distinct from Final Vanilla.
    try std.testing.expectError(error.MissingAssetIndex, runVanillaPrepared(a, io, &service, config, &prepared, target));
    var wrong = target;
    wrong.generation = 0;
    try expectVanillaBindingError(error.PreparedMetadataGenerationMismatch, a, io, &service, config, &prepared, wrong);
    wrong = target;
    wrong.generation = 8;
    try expectVanillaBindingError(error.PreparedMetadataGenerationMismatch, a, io, &service, config, &prepared, wrong);
    wrong = target;
    wrong.instance_id = "different-instance";
    try expectVanillaBindingError(error.PreparedMetadataMismatch, a, io, &service, config, &prepared, wrong);
    wrong = target;
    wrong.instance_name = "different-final-name";
    try expectVanillaBindingError(error.PreparedMetadataMismatch, a, io, &service, config, &prepared, wrong);
    var wrong_config = config;
    wrong_config.version_id = "1.20.2";
    try std.testing.expectError(error.PreparedMetadataMismatch, runVanillaPrepared(a, io, &service, wrong_config, &prepared, target));
    wrong = target;
    wrong.version_id = "1.20.2";
    try expectVanillaBindingError(error.PreparedMetadataMismatch, a, io, &service, wrong_config, &prepared, wrong);
    wrong_config = config;
    wrong_config.root = root;
    try std.testing.expectError(error.PreparedMetadataMismatch, runVanillaPrepared(a, io, &service, wrong_config, &prepared, target));
    wrong = target;
    wrong.root = "different-vanilla-root";
    try std.testing.expectError(error.PreparedMetadataMismatch, runVanillaPrepared(a, io, &service, config, &prepared, wrong));
    wrong_config = config;
    wrong_config.environment.arch = "aarch64";
    try expectVanillaBindingError(error.PreparedMetadataMismatch, a, io, &service, wrong_config, &prepared, target);
    wrong_config = config;
    wrong_config.environment.os_version = "changed-os";
    try expectVanillaBindingError(error.PreparedMetadataMismatch, a, io, &service, wrong_config, &prepared, target);
    wrong_config = config;
    wrong_config.environment.features = &.{.{ .name = "demo", .enabled = true }};
    try expectVanillaBindingError(error.PreparedMetadataMismatch, a, io, &service, wrong_config, &prepared, target);
    var cancel = std.atomic.Value(bool).init(true);
    wrong_config = config;
    wrong_config.cancel = &cancel;
    try std.testing.expectError(error.Canceled, runVanillaPrepared(a, io, &service, wrong_config, &prepared, target));
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    const stage_descriptor = try std.fs.path.join(a, &.{ minecraft, "versions", "private-stage", "private-stage.json" });
    defer a.free(stage_descriptor);
    try std.testing.expectError(error.FileNotFound, fs.read(a, io, stage_descriptor, 1024, null));
}

test "vanilla prepared executor rejects sealed base mutation and retains independently owned sources" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const minecraft = try std.fs.path.join(a, &.{ root, ".minecraft" });
    defer a.free(minecraft);
    var fixture: VanillaRunFixture = .{};
    var prepared = try fixture.prepare(a, io, root);
    defer prepared.deinit();
    const target = vanillaRunTarget(root);
    const config = preparedRunConfig(minecraft);
    var service: dl.Service = undefined;
    const original_class = prepared.base.value.main_class;
    prepared.base.value.main_class = "changed.Main";
    try expectVanillaBindingError(error.PreparedMetadataChanged, a, io, &service, config, &prepared, target);
    prepared.base.value.main_class = original_class;
    for (0..2) |_| try std.testing.expectError(error.MissingAssetIndex, runVanillaPrepared(a, io, &service, config, &prepared, target));
    try prepared.validateBinding(a, io, target);
    try std.testing.expectEqual(@as(u64, 17), prepared.runtime_major);
    try std.testing.expectEqualStrings("vanilla.Main", prepared.base.value.main_class.?);
    try std.testing.expectEqualStrings(prepared_run_base, prepared.sources[0].bytes);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "vanilla prepared replay and consuming executor release owners on every allocation failure" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const minecraft = try std.fs.path.join(a, &.{ root, ".minecraft" });
    defer a.free(minecraft);
    var fixture: VanillaRunFixture = .{};
    var prepared = try fixture.prepare(a, io, root);
    defer prepared.deinit();
    const target = vanillaRunTarget(root);
    try std.testing.checkAllAllocationFailures(a, vanillaRunAllocationFailure, .{ preparedRunConfig(minecraft), &prepared, target });
    try prepared.validateBinding(a, io, target);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

const PostReplayClock = struct {
    calls: usize = 0,
    deadline_after: ?usize = null,
    cancel_at: ?usize = null,
    cancel_target: ?*std.atomic.Value(bool) = null,
    fn now(raw: ?*anyopaque) u64 {
        const self: *PostReplayClock = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.cancel_at) |n| {
            if (self.calls == n) {
                if (self.cancel_target) |flag| flag.store(true, .release);
            }
        }
        if (self.deadline_after) |n| if (self.calls > n) return 1;
        return 0;
    }
};

test "prepared executor retains deadline and distinct cancellation flags after replay" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const minecraft = try std.fs.path.join(a, &.{ root, ".minecraft" });
    defer a.free(minecraft);
    var fixture: PreparedRunFixture = .{};
    var prepared = try fixture.prepare(a, io, root);
    defer prepared.deinit();
    const target = preparedRunTarget(&prepared);
    var config_cancel: std.atomic.Value(bool) = .init(false);
    var loader_cancel: std.atomic.Value(bool) = .init(false);
    var config = preparedRunConfig(minecraft);
    config.cancel = &config_cancel;
    var clock: PostReplayClock = .{};
    const control: loaders.Control = .{ .cancel = &loader_cancel, .deadline_ms = 1, .context = &clock, .now_ms = PostReplayClock.now };
    var replay = try prepared.replayBase(a, io, target, control);
    // Calibrate replay's checks; runPrepared adds one entry check before replay.
    const last_replay_check = clock.calls + 1;
    replay.deinit();
    try std.testing.expect(prepared.base.value.asset_index == null);
    const vanilla_calls = fixture.vanilla_calls;
    const loader_calls = fixture.loader_calls;
    var service: dl.Service = undefined;
    clock.calls = 0;
    clock.deadline_after = last_replay_check;
    try std.testing.expectError(error.DeadlineExceeded, runPrepared(a, io, &service, config, &prepared, target, control));
    try std.testing.expectEqual(last_replay_check + 1, clock.calls);
    clock.deadline_after = null;
    const flags = [_]*std.atomic.Value(bool){ &config_cancel, &loader_cancel };
    for (flags) |flag| {
        config_cancel.store(false, .release);
        loader_cancel.store(false, .release);
        clock.calls = 0;
        clock.cancel_at = last_replay_check;
        clock.cancel_target = flag;
        try std.testing.expectError(error.Canceled, runPrepared(a, io, &service, config, &prepared, target, control));
        try std.testing.expectEqual(last_replay_check, clock.calls);
        try std.testing.expect(flag.load(.acquire));
        const other = if (flag == &config_cancel) &loader_cancel else &config_cancel;
        try std.testing.expect(!other.load(.acquire));
    }
    try prepared.validateBinding(a, io, target);
    try std.testing.expectEqual(vanilla_calls, fixture.vanilla_calls);
    try std.testing.expectEqual(loader_calls, fixture.loader_calls);
}

test "installer namespace blocker rejects artifacts-only runs before any IO" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const token = try namespace.acquire(io);
    defer token.release();
    var service: dl.Service = undefined;
    const config: Config = .{ .version_id = "1.20.1", .root = root, .publish_metadata = false, .environment = .{ .os_name = "linux", .arch = "x86_64" } };
    try std.testing.expectError(error.InstanceNamespaceBusy, run(std.testing.allocator, io, &service, config));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "versions", .{ .follow_symlinks = false }));
    try token.recheck();
}

test "installer prepared entry validates namespace stamps and never releases a borrower" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var service: dl.Service = undefined;
    var prepared: loader.PreparedVanilla = undefined;
    var config: Config = .{ .version_id = "1.20.1", .publish_metadata = false, .environment = .{ .os_name = "linux", .arch = "x86_64" } };
    const target: loader.VanillaTarget = .{ .root = ".", .instance_id = "fixture", .instance_name = "Pack", .version_id = "other", .generation = 1, .environment = config.environment };
    try std.testing.expectError(error.PreparedMetadataMismatch, runVanillaPrepared(a, io, &service, config, &prepared, target));
    const token = try namespace.acquire(io);
    defer token.release();
    config.namespace_token = token;
    try std.testing.expectError(error.PreparedMetadataMismatch, runVanillaPrepared(a, io, &service, config, &prepared, target));
    try token.recheck();
    try std.testing.expectError(error.InstanceNamespaceBusy, namespace.acquire(io));
    token.release();
    const current = try namespace.acquire(io);
    defer current.release();
    try std.testing.expectError(error.InstanceNamespaceLeaseLost, runVanillaPrepared(a, io, &service, config, &prepared, target));
    try current.recheck();
}

test "artifacts-only consuming executor releases direct namespace and retains borrowed namespace on error" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var fixture: PreparedRunFixture = .{};
    var prepared = try fixture.prepare(a, io, root);
    defer prepared.deinit();
    const minecraft = try std.fs.path.join(a, &.{ root, ".minecraft" });
    defer a.free(minecraft);
    var config = preparedRunConfig(minecraft);
    config.publish_metadata = false;
    const target = preparedRunTarget(&prepared);
    var service: dl.Service = undefined;
    try std.testing.expectError(error.MissingAssetIndex, runPrepared(a, io, &service, config, &prepared, target, prepared_run_control));
    const token = try namespace.acquire(io);
    defer token.release();
    config.namespace_token = token;
    try std.testing.expectError(error.MissingAssetIndex, runPrepared(a, io, &service, config, &prepared, target, prepared_run_control));
    try token.recheck();
    try std.testing.expectError(error.InstanceNamespaceBusy, namespace.acquire(io));
    try std.testing.expectEqual(@as(usize, 1), fixture.vanilla_calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.loader_calls);
}

test "worker installer admission preserves active namespace busy and stale borrowed stamp errors before IO" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var service: dl.Service = undefined;
    var config: Config = .{ .version_id = "1.20.1", .root = root, .publish_metadata = false, .worker_checks = true, .environment = .{ .os_name = "linux", .arch = "x86_64" } };
    const old = try namespace.acquire(io);
    defer old.release();
    try std.testing.expectError(error.InstanceNamespaceBusy, run(a, io, &service, config));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "versions", .{ .follow_symlinks = false }));
    old.release();
    const current = try namespace.acquire(io);
    defer current.release();
    config.namespace_token = old;
    try std.testing.expectError(error.InstanceNamespaceLeaseLost, run(a, io, &service, config));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "versions", .{ .follow_symlinks = false }));
    try current.recheck();
}

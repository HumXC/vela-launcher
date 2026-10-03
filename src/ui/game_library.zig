//! UI-thread controller; workers own unpublished arenas until tick joins them.
const std = @import("std");
const builtin = @import("builtin");
const curl = @import("curl");
const dl = @import("../core/downloader.zig");
const metadata = @import("../core/minecraft/metadata/root.zig");
const install = @import("../core/minecraft/install.zig");
const native = @import("../core/minecraft/native_extract.zig");
const tasks = @import("../core/tasks.zig");

pub const InstalledEntry = struct { id: []const u8, java_major: u32 = 8 };
pub const CatalogEntry = struct { id: []const u8, kind: []const u8 };
pub const Phase = enum { idle, loading, installing, complete, failed };
pub const Snapshot = struct {
    installed: []const InstalledEntry,
    installed_generation: u64 = 0,
    available: []const CatalogEntry,
    phase: Phase,
    failure: ?anyerror,
    completed: usize,
    total: usize,
    installing_version: ?[]const u8,
};
pub const Options = struct {
    root: []const u8 = ".minecraft",
    manifest_url: []const u8 = metadata.version_manifest_url,
    task_registry: ?*tasks.Registry = null,
    cache_root: ?[]const u8 = null,
    download_connections: u16 = 8,
};

const worker_allocator = std.heap.page_allocator;
const Operation = enum { catalogue, install_version, refresh_installed };
const Job = struct {
    arena: std.heap.ArenaAllocator = .init(worker_allocator),
    io: std.Io,
    operation: Operation,
    root: []const u8,
    manifest_url: []const u8,
    version_id: ?[]const u8,
    cache_root: ?[]const u8 = null,
    download_connections: u16 = 8,
    task: ?*tasks.Task = null,
    thread: ?std.Thread = null,
    canceled: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    completed: std.atomic.Value(usize) = .init(0),
    total: std.atomic.Value(usize) = .init(0),
    installed: []const InstalledEntry = &.{},
    installed_refreshed: bool = false,
    available: []const CatalogEntry = &.{},
    failure: ?anyerror = null,

    fn destroy(self: *Job) void {
        self.arena.deinit();
        worker_allocator.destroy(self);
    }
    fn cancelFlag(self: *Job) *const std.atomic.Value(bool) {
        return if (self.task) |task| &task.cancellation else &self.canceled;
    }
    fn checkCancel(self: *Job) !void {
        if (self.cancelFlag().load(.acquire)) return error.Canceled;
    }
};

// The install API's callback has no context parameter. Each installer runs on
// its own OS thread, so this pointer is never shared between controllers.
threadlocal var reporting_job: ?*Job = null;
fn report(progress: install.Progress) void {
    const job = reporting_job orelse return;
    job.total.store(progress.total, .release);
    job.completed.store(progress.completed, .release);
    if (job.task) |task| task.report(.downloading, @intCast(progress.completed), @intCast(progress.total));
}

/// Methods, except the worker's atomics, belong exclusively to the UI thread.
/// Returned strings/arrays remain valid until the next tick/start/deinit.
/// The supplied Io must support concurrent OS threads (as App.main_init.io does).
/// A supplied task registry must outlive the controller; tick/deinit join before
/// finishing tasks, and published jobs release task pointers before pruning.
pub const Controller = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    manifest_url: []const u8,
    task_registry: ?*tasks.Registry = null,
    cache_root: ?[]const u8 = null,
    download_connections: u16 = 8,
    active: ?*Job = null,
    published: ?*Job = null,
    phase: Phase = .idle,
    failure: ?anyerror = null,
    installed_generation: u64 = 0,

    pub fn init(a: std.mem.Allocator, io: std.Io) !Controller {
        return initWithOptions(a, io, .{});
    }
    pub fn initWithOptions(a: std.mem.Allocator, io: std.Io, options: Options) !Controller {
        if (options.root.len == 0 or std.mem.indexOfScalar(u8, options.root, 0) != null) return error.UnsafePath;
        if (options.download_connections == 0 or options.download_connections > 64) return error.InvalidDownloadConnections;
        const cwd = try std.process.currentPathAlloc(io, a);
        defer a.free(cwd);
        const root = try std.fs.path.resolve(a, &.{ cwd, options.root });
        errdefer a.free(root);
        const manifest_url = try a.dupe(u8, options.manifest_url);
        errdefer a.free(manifest_url);
        const cache_root = if (options.cache_root) |path| blk: {
            if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.UnsafePath;
            break :blk try a.dupe(u8, path);
        } else null;
        errdefer if (cache_root) |path| a.free(path);
        try curl.globalInit();
        return .{ .allocator = a, .io = io, .root = root, .manifest_url = manifest_url, .task_registry = options.task_registry, .cache_root = cache_root, .download_connections = options.download_connections };
    }
    pub fn deinit(self: *Controller) void {
        self.cancel();
        if (self.active) |job| {
            job.thread.?.join();
            job.thread = null;
            self.finishTask(job);
            job.destroy();
        }
        if (self.published) |job| job.destroy();
        self.allocator.free(self.root);
        self.allocator.free(self.manifest_url);
        if (self.cache_root) |path| self.allocator.free(path);
        curl.globalDeinit();
        self.* = undefined;
    }
    pub fn tick(self: *Controller) void {
        const job = self.active orelse return;
        if (!job.done.load(.acquire)) return;
        job.thread.?.join();
        job.thread = null;
        self.finishTask(job);
        if (self.published) |old| old.destroy();
        self.published = job;
        self.active = null;
        self.failure = job.failure;
        if (job.installed_refreshed) self.installed_generation +|= 1;
        self.phase = if (job.failure != null) .failed else .complete;
    }
    pub fn snapshot(self: *const Controller) Snapshot {
        const data = self.published;
        const progress = self.active orelse data;
        return .{
            .installed = if (data) |job| job.installed else &.{},
            .installed_generation = self.installed_generation,
            .available = if (data) |job| job.available else &.{},
            .phase = self.phase,
            .failure = self.failure,
            .completed = if (progress) |job| job.completed.load(.acquire) else 0,
            .total = if (progress) |job| job.total.load(.acquire) else 0,
            .installing_version = if (progress) |job| job.version_id else null,
        };
    }
    pub fn refreshInstalled(self: *Controller) !void {
        try self.start(.refresh_installed, null);
    }
    pub fn loadCatalogue(self: *Controller) !void {
        try self.start(.catalogue, null);
    }
    pub fn setDownloadConnections(self: *Controller, connections: u16) !void {
        if (connections == 0 or connections > 64) return error.InvalidDownloadConnections;
        self.download_connections = connections;
    }

    pub fn installVersion(self: *Controller, id: []const u8) !void {
        if (self.active != null) return error.Busy;
        component(id) catch |err| {
            self.failure = err;
            self.phase = .failed;
            return err;
        };
        try self.start(.install_version, id);
    }
    pub fn cancel(self: *Controller) void {
        if (self.active) |job| {
            if (job.task) |task| _ = self.task_registry.?.cancel(task.id);
            job.canceled.store(true, .release);
        }
    }
    fn start(self: *Controller, operation: Operation, id: ?[]const u8) !void {
        if (self.active != null) return error.Busy;
        self.startJob(operation, id) catch |err| {
            self.failure = err;
            self.phase = .failed;
            return err;
        };
        self.failure = null;
        self.phase = if (operation == .install_version) .installing else .loading;
    }
    fn startJob(self: *Controller, operation: Operation, id: ?[]const u8) !void {
        const job = try worker_allocator.create(Job);
        job.* = .{ .io = self.io, .operation = operation, .root = undefined, .manifest_url = undefined, .version_id = null, .download_connections = self.download_connections };
        errdefer job.destroy();
        const a = job.arena.allocator();
        job.root = try a.dupe(u8, self.root);
        job.manifest_url = try a.dupe(u8, self.manifest_url);
        if (id) |value| job.version_id = try a.dupe(u8, value);
        if (self.cache_root) |path| job.cache_root = try a.dupe(u8, path);
        if (self.published) |data| {
            const installed = try a.alloc(InstalledEntry, data.installed.len);
            for (installed, data.installed) |*target, source| target.* = .{ .id = try a.dupe(u8, source.id), .java_major = source.java_major };
            job.installed = installed;
            const available = try a.alloc(CatalogEntry, data.available.len);
            for (available, data.available) |*target, source| target.* = .{ .id = try a.dupe(u8, source.id), .kind = try a.dupe(u8, source.kind) };
            job.available = available;
        }
        errdefer |err| {
            if (job.task) |task| self.task_registry.?.finish(task, .{ .failed = err });
        }
        if (operation == .install_version) {
            if (self.task_registry) |registry| {
                const title = try std.fmt.allocPrint(a, "Install Minecraft {s}", .{job.version_id.?});
                job.task = try registry.create(.game_install, title);
                try registry.start(job.task.?);
            }
        }
        job.thread = try std.Thread.spawn(.{}, work, .{job});
        self.active = job;
    }
    fn finishTask(self: *Controller, job: *Job) void {
        std.debug.assert(job.thread == null);
        const task = job.task orelse return;
        const outcome: tasks.Outcome = if (job.failure) |err|
            (if (err == error.Canceled) .canceled else .{ .failed = err })
        else
            .succeeded;
        self.task_registry.?.finish(task, outcome);
        // Published data must not retain a pointer the registry may prune.
        job.task = null;
    }
};

fn work(job: *Job) void {
    perform(job) catch |err| {
        job.failure = err;
    };
    job.done.store(true, .release);
}
fn perform(job: *Job) !void {
    try job.checkCancel();
    if (job.task) |task| task.report(.scanning, 0, null);
    job.installed = try scanInstalled(job.arena.allocator(), job.io, job.root, job.cancelFlag());
    try job.checkCancel();
    job.installed_refreshed = true;
    if (job.operation == .refresh_installed) return;
    const service = try dl.Service.init(worker_allocator, job.io, job.download_connections);
    defer service.deinit();
    switch (job.operation) {
        .refresh_installed => unreachable,
        .catalogue => {
            const bytes = try fetchManifest(job, service);
            defer worker_allocator.free(bytes);
            job.available = try parseCatalogue(job.arena.allocator(), bytes);
            try job.checkCancel();
        },
        .install_version => {
            if (job.task) |task| task.report(.metadata, 0, null);
            reporting_job = job;
            defer reporting_job = null;
            const http_cache = try httpCacheRoot(job);
            defer if (http_cache) |path| worker_allocator.free(path);
            var installed = try install.run(worker_allocator, job.io, service, .{
                .version_id = job.version_id.?,
                .root = job.root,
                .http_cache = http_cache,
                .manifest_url = job.manifest_url,
                .environment = try hostEnvironment(),
                .native_arch = if (@sizeOf(usize) == 8) .bits64 else .bits32,
                .cancel = job.cancelFlag(),
                .progress = report,
            });
            defer installed.deinit();
            if (job.task) |task| task.report(.verifying, 0, null);
            // run() committed the complete install. Validate/publish it even if
            // cancellation arrived after commit; the token alone is not outcome.
            var committed: std.atomic.Value(bool) = .init(false);
            job.installed = try scanInstalled(job.arena.allocator(), job.io, job.root, &committed);
            var found = false;
            for (job.installed) |entry| {
                if (std.mem.eql(u8, entry.id, job.version_id.?)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.IncompleteInstall;
            if (job.task) |task| task.report(.finalizing, 1, 1);
        },
    }
}
pub fn hostEnvironment() !metadata.rules.Environment {
    return .{
        .os_name = switch (builtin.os.tag) {
            .linux => "linux",
            .windows => "windows",
            .macos => "osx",
            else => return error.UnsupportedOperatingSystem,
        },
        .arch = switch (builtin.cpu.arch) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            .x86 => "x86",
            else => return error.UnsupportedArchitecture,
        },
    };
}
fn httpCacheRoot(job: *Job) !?[]u8 {
    const root = job.cache_root orelse return null;
    const directory = try std.fs.path.join(worker_allocator, &.{ root, "http" });
    errdefer worker_allocator.free(directory);
    try std.Io.Dir.cwd().createDirPath(job.io, directory);
    return directory;
}
fn manifestCachePath(job: *Job) !?[]u8 {
    const directory = (try httpCacheRoot(job)) orelse return null;
    defer worker_allocator.free(directory);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(job.manifest_url, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const filename = try std.fmt.allocPrint(worker_allocator, "{s}.json", .{hex});
    defer worker_allocator.free(filename);
    return try std.fs.path.join(worker_allocator, &.{ directory, filename });
}
fn fetchManifest(job: *Job, service: *dl.Service) ![]u8 {
    const cache_path = try manifestCachePath(job);
    defer if (cache_path) |path| worker_allocator.free(path);
    const task = try service.submit(.{ .url = job.manifest_url, .max_bytes = 64 * 1024 * 1024, .cache_path = cache_path });
    defer {
        task.cancel();
        while (!dl.terminal(task.snapshot().progress.phase)) job.io.sleep(.fromMilliseconds(10), .awake) catch {};
        task.release() catch unreachable;
    }
    while (true) {
        try job.checkCancel();
        const state = task.snapshot();
        if (dl.terminal(state.progress.phase)) {
            if (state.failure) |err| return err;
            if (state.progress.phase != .complete) return error.DownloadFailed;
            return worker_allocator.dupe(u8, state.result.?.bytes);
        }
        try job.io.sleep(.fromMilliseconds(10), .awake);
    }
}
pub fn validateVersionId(id: []const u8) !void {
    try component(id);
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_') return error.UnsafePath;
}

/// Local-only validation shared by catalogue scanning and launch preparation.
pub fn loadInstalled(a: std.mem.Allocator, io: std.Io, root: []const u8, id: []const u8, canceled: *const std.atomic.Value(bool)) !metadata.Owned(metadata.version.Version) {
    try validateVersionId(id);
    const root_dir = try std.Io.Dir.cwd().openDir(io, root, .{ .follow_symlinks = false });
    defer root_dir.close(io);
    const versions = try root_dir.openDir(io, "versions", .{ .follow_symlinks = false });
    defer versions.close(io);
    const dir = try versions.openDir(io, id, .{ .follow_symlinks = false });
    defer dir.close(io);
    var major: u32 = 8;
    if (!try usableVersion(io, root_dir, root, dir, id, canceled, &major)) return error.IncompleteInstall;
    const name = try std.fmt.allocPrint(a, "{s}.json", .{id});
    defer a.free(name);
    const bytes = try readRegular(dir, io, name, 16 * 1024 * 1024);
    defer worker_allocator.free(bytes);
    return metadata.version.parseSlice(a, bytes);
}

pub fn loadAssets(a: std.mem.Allocator, io: std.Io, root: []const u8, id: []const u8) !metadata.Owned(metadata.asset_index.AssetIndex) {
    try component(id);
    const root_dir = try std.Io.Dir.cwd().openDir(io, root, .{ .follow_symlinks = false });
    defer root_dir.close(io);
    const path = try std.fmt.allocPrint(a, "assets/indexes/{s}.json", .{id});
    defer a.free(path);
    const bytes = try readRegular(root_dir, io, path, 64 * 1024 * 1024);
    defer worker_allocator.free(bytes);
    return metadata.asset_index.parseSlice(a, bytes);
}

fn component(id: []const u8) !void {
    if (id.len == 0 or std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return error.UnsafePath;
    for (id) |c| if (c == '/' or c == 92 or c == ':' or c == 0) return error.UnsafePath;
}
fn parseCatalogue(a: std.mem.Allocator, bytes: []const u8) ![]const CatalogEntry {
    var parsed = try metadata.manifest.parseSlice(worker_allocator, bytes);
    defer parsed.deinit();
    var result: std.ArrayList(CatalogEntry) = .empty;
    for (parsed.value.versions) |entry| {
        try component(entry.id);
        for (result.items) |existing| if (std.mem.eql(u8, existing.id, entry.id)) return error.DuplicateVersion;
        try result.append(a, .{ .id = try a.dupe(u8, entry.id), .kind = try a.dupe(u8, entry.kind) });
    }
    return result.toOwnedSlice(a);
}
fn scanInstalled(a: std.mem.Allocator, io: std.Io, root: []const u8, cancel_flag: *const std.atomic.Value(bool)) ![]const InstalledEntry {
    const root_dir = std.Io.Dir.cwd().openDir(io, root, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer root_dir.close(io);
    const versions = root_dir.openDir(io, "versions", .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer versions.close(io);
    var result: std.ArrayList(InstalledEntry) = .empty;
    var iterator = versions.iterate();
    while (try iterator.next(io)) |entry| {
        if (cancel_flag.load(.acquire)) return error.Canceled;
        if (entry.kind != .directory) continue;
        component(entry.name) catch continue;
        const dir = versions.openDir(io, entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.SymLinkLoop => continue,
            else => return err,
        };
        defer dir.close(io);
        var java_major: u32 = 8;
        if (try usableVersion(io, root_dir, root, dir, entry.name, cancel_flag, &java_major)) try result.append(a, .{ .id = try a.dupe(u8, entry.name), .java_major = java_major });
    }
    std.mem.sort(InstalledEntry, result.items, {}, struct {
        fn less(_: void, lhs: InstalledEntry, rhs: InstalledEntry) bool {
            return std.mem.lessThan(u8, lhs.id, rhs.id);
        }
    }.less);
    return result.toOwnedSlice(a);
}
fn usableVersion(io: std.Io, root_dir: std.Io.Dir, root: []const u8, dir: std.Io.Dir, id: []const u8, cancel_flag: *const std.atomic.Value(bool), java_major: *u32) !bool {
    const json_name = try std.fmt.allocPrint(worker_allocator, "{s}.json", .{id});
    defer worker_allocator.free(json_name);
    const json_stat = dir.statFile(io, json_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (json_stat.kind != .file or json_stat.size > 16 * 1024 * 1024) return false;
    const bytes = readRegular(dir, io, json_name, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong, error.NotRegularFile, error.SymLinkLoop => return false,
        else => return err,
    };
    defer worker_allocator.free(bytes);
    var parsed = metadata.version.parseSlice(worker_allocator, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer parsed.deinit();
    const version = parsed.value;
    if (!std.mem.eql(u8, version.id, id) or version.inherits_from != null or version.jar != null) return false;
    const major = if (version.java_version) |java| java.major_version else 8;
    if (major == 0 or major > std.math.maxInt(u32)) return false;
    const main_class = version.main_class orelse return false;
    if (main_class.len == 0 or main_class[0] == '-' or main_class[0] == '@') return false;
    if (version.asset_index == null or version.libraries == null) return false;
    if (version.arguments) |arguments| {
        if (arguments.game == null or arguments.jvm == null) return false;
    } else if (version.minecraft_arguments == null) return false;
    var client: ?metadata.version.Download = null;
    for (version.downloads) |entry| if (std.mem.eql(u8, entry.name, "client")) {
        client = entry.download;
        break;
    };
    const expected = client orelse return false;
    const jar_name = try std.fmt.allocPrint(worker_allocator, "{s}.jar", .{id});
    defer worker_allocator.free(jar_name);
    const jar_stat = dir.statFile(io, jar_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (jar_stat.kind != .file or jar_stat.size == 0) return false;
    if (expected.size) |size| if (size != jar_stat.size) return false;
    const jar = dir.openFile(io, jar_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer jar.close(io);
    if ((try jar.stat(io)).kind != .file) return false;
    var hash = std.crypto.hash.Sha1.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        if (cancel_flag.load(.acquire)) return error.Canceled;
        const n = try jar.readPositionalAll(io, &buffer, offset);
        if (n == 0) break;
        if (offset == 0 and (n < 4 or !std.mem.eql(u8, buffer[0..4], "PK\x03\x04"))) return false;
        hash.update(buffer[0..n]);
        offset += n;
    }
    if (offset != jar_stat.size) return false;
    if (expected.sha1) |sha1| {
        var actual: [20]u8 = undefined;
        hash.final(&actual);
        if (!std.mem.eql(u8, &actual, &sha1)) return false;
    }
    if (!try completePlan(io, root_dir, root, version, cancel_flag)) return false;
    java_major.* = @intCast(major);
    return true;
}

fn openBelow(root: std.Io.Dir, io: std.Io, path: []const u8) !std.Io.File {
    var directory = root;
    var owned = false;
    defer if (owned) directory.close(io);
    var parts = std.mem.splitScalar(u8, path, '/');
    var part = parts.next() orelse return error.UnsafePath;
    while (parts.next()) |next| {
        try component(part);
        const child = try directory.openDir(io, part, .{ .follow_symlinks = false });
        if (owned) directory.close(io);
        directory = child;
        owned = true;
        part = next;
    }
    try component(part);
    return directory.openFile(io, part, .{ .follow_symlinks = false });
}
fn readRegular(root: std.Io.Dir, io: std.Io, path: []const u8, max: usize) ![]u8 {
    const file = try openBelow(root, io, path);
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.NotRegularFile;
    if (stat.size > max) return error.StreamTooLong;
    const bytes = try worker_allocator.alloc(u8, @intCast(stat.size));
    errdefer worker_allocator.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.UnexpectedEndOfFile;
    return bytes;
}
fn relativePath(root: []const u8, absolute: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, absolute, root)) return error.UnsafePath;
    const rest = absolute[root.len..];
    if (rest.len < 2 or rest[0] != '/') return error.UnsafePath;
    return rest[1..];
}
fn completePlan(io: std.Io, root_dir: std.Io.Dir, root: []const u8, version: metadata.version.Version, cancel_flag: *const std.atomic.Value(bool)) !bool {
    const index = version.asset_index orelse return false;
    component(index.id) catch return false;
    const index_path = try std.fmt.allocPrint(worker_allocator, "assets/indexes/{s}.json", .{index.id});
    defer worker_allocator.free(index_path);
    const bytes = readRegular(root_dir, io, index_path, 64 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.SymLinkLoop, error.NotRegularFile, error.StreamTooLong, error.UnexpectedEndOfFile => return false,
        else => return err,
    };
    defer worker_allocator.free(bytes);
    if (index.size) |size| if (size != bytes.len) return false;
    if (index.sha1) |expected| {
        var actual: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(bytes, &actual, .{});
        if (!std.mem.eql(u8, &actual, &expected)) return false;
    }
    var assets = metadata.asset_index.parseSlice(worker_allocator, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer assets.deinit();
    const planner = @import("../core/minecraft/install_plan.zig");
    var plan = planner.build(worker_allocator, version, assets.value, try hostEnvironment(), .{ .root = root, .native_arch = if (@sizeOf(usize) == 8) .bits64 else .bits32, .cpu_arch = @tagName(builtin.cpu.arch) }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer plan.deinit();
    // Metadata and client are cryptographically checked. Other planned files
    // must exist with their declared sizes, so a jar-first partial install is
    // not promoted to the installed list without its libraries and assets.
    for (plan.value.files) |artifact| {
        if (cancel_flag.load(.acquire)) return error.Canceled;
        const path = try relativePath(root, artifact.path);
        const file = openBelow(root_dir, io, path) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.SymLinkLoop => return false,
            else => return err,
        };
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file) return false;
        if (artifact.size) |size| if (stat.size != size) return false;
    }
    // Launch rebuilds extracted outputs from these checked source archives.
    for (plan.value.native_checks) |check| {
        const path = try relativePath(root, check.archive_path);
        const file = openBelow(root_dir, io, path) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.SymLinkLoop => return false,
            else => return err,
        };
        defer file.close(io);
        native.inspectFile(worker_allocator, io, file, @tagName(builtin.cpu.arch), cancel_flag) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            else => return false,
        };
    }
    return true;
}

test "catalogue preserves real manifest entries and rejects unsafe IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entries = try parseCatalogue(arena.allocator(),
        \\{"latest":{"release":"1.0","snapshot":"s"},"versions":[{"id":"1.0","type":"release","url":"http://fixture/v","time":"t","releaseTime":"t"},{"id":"s","type":"snapshot","url":"http://fixture/s","time":"t","releaseTime":"t"}]}
    );
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("1.0", entries[0].id);
    try std.testing.expectEqualStrings("snapshot", entries[1].kind);
    try std.testing.expectError(error.UnsafePath, parseCatalogue(arena.allocator(),
        \\{"latest":{"release":"x","snapshot":"x"},"versions":[{"id":"../x","type":"release","url":"http://fixture/v","time":"t","releaseTime":"t"}]}
    ));
    try std.testing.expectError(error.UnexpectedEndOfInput, parseCatalogue(arena.allocator(), "{"));
}

test "local legacy native sources remain installed without extracted outputs" {
    if (builtin.os.tag != .linux or (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64)) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets/indexes");
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/indexes/fixture.json", .data = "{\"objects\":{}}" });
    try writeVersionFixtureWithJava(tmp.dir, "Legacy Native", "Legacy Native", true, null);
    const zip = try legacyNativeFixtureZip(a);
    defer a.free(zip);
    try tmp.dir.writeFile(io, .{ .sub_path = "libraries/fixture/native.jar", .data = zip });
    const original = try readRegular(tmp.dir, io, "versions/Legacy Native/Legacy Native.json", 4096);
    defer worker_allocator.free(original);
    var document = try std.json.parseFromSlice(std.json.Value, a, original, .{});
    defer document.deinit();
    _ = document.value.object.swapRemove("arguments");
    try document.value.object.put(a, "minecraftArguments", .{ .string = "--version fixture" });
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(zip, &digest, .{});
    const sha1 = std.fmt.bytesToHex(digest, .lower);
    const library_bytes = try std.json.Stringify.valueAlloc(a, .{
        .name = "fixture:native:1",
        .natives = .{ .linux = "natives-linux" },
        .extract = .{ .exclude = [_][]const u8{"META-INF/"} },
        .downloads = .{ .classifiers = .{ .@"natives-linux" = .{ .path = "fixture/native.jar", .url = "http://fixture/native", .sha1 = &sha1, .size = zip.len } } },
    }, .{});
    defer a.free(library_bytes);
    var library = try std.json.parseFromSlice(std.json.Value, a, library_bytes, .{});
    defer library.deinit();
    try document.value.object.getPtr("libraries").?.array.append(library.value);
    const bytes = try std.json.Stringify.valueAlloc(a, document.value, .{});
    defer a.free(bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "versions/Legacy Native/Legacy Native.json", .data = bytes });
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "versions/Legacy Native/natives", .{}));
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var controller = try Controller.initWithOptions(a, io, .{ .root = root, .manifest_url = "invalid://no-http", .task_registry = &registry });
    defer controller.deinit();
    try controller.refreshInstalled();
    try waitForTest(&controller);
    try std.testing.expectEqual(Phase.complete, controller.snapshot().phase);
    try std.testing.expectEqual(@as(usize, 1), controller.snapshot().installed.len);
    try std.testing.expectEqualStrings("Legacy Native", controller.snapshot().installed[0].id);
    try std.testing.expectEqual(@as(u32, 8), controller.snapshot().installed[0].java_major);
    try controller.refreshInstalled();
    try std.testing.expectEqual(@as(u32, 8), controller.snapshot().installed[0].java_major);
    try waitForTest(&controller);
    try std.testing.expectEqual(@as(u64, 2), controller.snapshot().installed_generation);
    try std.testing.expectEqual(@as(u32, 8), controller.snapshot().installed[0].java_major);
    try tmp.dir.deleteFile(io, "libraries/fixture/native.jar");
    try controller.refreshInstalled();
    try waitForTest(&controller);
    try std.testing.expectEqual(Phase.complete, controller.snapshot().phase);
    try std.testing.expectEqual(@as(usize, 0), controller.snapshot().installed.len);
    try std.testing.expectEqual(@as(usize, 0), registry.tasks().len);
    try std.testing.expect(!registry.hasActive());
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "versions/Legacy Native/natives", .{}));
}

fn legacyNativeFixtureZip(a: std.mem.Allocator) ![]u8 {
    var payload: [64]u8 = @splat(0);
    @memcpy(payload[0..4], "\x7fELF");
    payload[4] = 2;
    payload[5] = 1;
    payload[6] = 1;
    std.mem.writeInt(u16, payload[16..18], 3, .little);
    std.mem.writeInt(u16, payload[18..20], if (builtin.cpu.arch == .aarch64) 183 else 62, .little);
    std.mem.writeInt(u32, payload[20..24], 1, .little);
    std.mem.writeInt(u16, payload[52..54], 64, .little);
    const name = "native.so";
    var storage: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    var local = std.mem.zeroes(std.zip.LocalFileHeader);
    local.signature = std.zip.local_file_header_sig;
    local.version_needed_to_extract = 20;
    local.compression_method = .store;
    local.crc32 = std.hash.Crc32.hash(&payload);
    local.compressed_size = payload.len;
    local.uncompressed_size = payload.len;
    local.filename_len = name.len;
    try writer.writeStruct(local, .little);
    try writer.writeAll(name);
    try writer.writeAll(&payload);
    const offset = writer.end;
    var central = std.mem.zeroes(std.zip.CentralDirectoryFileHeader);
    central.signature = std.zip.central_file_header_sig;
    central.version_made_by = 0x0314;
    central.version_needed_to_extract = 20;
    central.compression_method = .store;
    central.crc32 = local.crc32;
    central.compressed_size = payload.len;
    central.uncompressed_size = payload.len;
    central.filename_len = name.len;
    central.external_file_attributes = 0x81a40000;
    try writer.writeStruct(central, .little);
    try writer.writeAll(name);
    var end = std.mem.zeroes(std.zip.EndRecord);
    end.signature = std.zip.end_record_sig;
    end.record_count_disk = 1;
    end.record_count_total = 1;
    end.central_directory_offset = @intCast(offset);
    end.central_directory_size = @intCast(writer.end - offset);
    try writer.writeStruct(end, .little);
    return a.dupe(u8, writer.buffered());
}

test "local installed refresh observes flattened custom folders and retains catalogue" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets/indexes");
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/indexes/fixture.json", .data = "{\"objects\":{}}" });
    try writeVersionFixtureWithJava(tmp.dir, "My World", "My World", true, 21);
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path);
    var registry = tasks.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var controller = try Controller.initWithOptions(std.testing.allocator, io, .{ .root = path[0..len], .manifest_url = "invalid://local-only", .task_registry = &registry });
    defer controller.deinit();
    const previous = try worker_allocator.create(Job);
    previous.* = .{ .io = io, .operation = .catalogue, .root = controller.root, .manifest_url = controller.manifest_url, .version_id = null };
    controller.published = previous;
    const a = previous.arena.allocator();
    const catalogue = try a.alloc(CatalogEntry, 1);
    catalogue[0] = .{ .id = try a.dupe(u8, "1.21.5"), .kind = try a.dupe(u8, "release") };
    previous.available = catalogue;
    try controller.refreshInstalled();
    try std.testing.expectError(error.Busy, controller.refreshInstalled());
    try std.testing.expectError(error.Busy, controller.loadCatalogue());
    try std.testing.expectEqual(Phase.loading, controller.snapshot().phase);
    try std.testing.expectEqual(@as(usize, 0), controller.snapshot().installed.len);
    try std.testing.expectEqual(@as(u64, 0), controller.snapshot().installed_generation);
    try std.testing.expectEqualStrings("1.21.5", controller.snapshot().available[0].id);
    try waitForTest(&controller);
    const initial = controller.snapshot();
    try std.testing.expectEqual(Phase.complete, initial.phase);
    try std.testing.expect(initial.failure == null);
    try std.testing.expectEqual(@as(u64, 1), initial.installed_generation);
    try std.testing.expectEqual(@as(usize, 1), initial.installed.len);
    try std.testing.expectEqualStrings("My World", initial.installed[0].id);
    try std.testing.expectEqual(@as(u32, 21), initial.installed[0].java_major);
    try std.testing.expectEqualStrings("1.21.5", initial.available[0].id);
    // Model a committed rename: metadata and private client bind the new name.
    try tmp.dir.deleteTree(io, "versions/My World");
    try writeVersionFixtureWithJava(tmp.dir, "Renamed World", "Renamed World", true, 21);
    try writeVersionFixture(tmp.dir, "Imported Legacy", "Imported Legacy", true);
    try controller.refreshInstalled();
    try std.testing.expectEqualStrings("My World", controller.snapshot().installed[0].id);
    try std.testing.expectEqual(@as(u32, 21), controller.snapshot().installed[0].java_major);
    try waitForTest(&controller);
    const renamed = controller.snapshot();
    try std.testing.expectEqual(Phase.complete, renamed.phase);
    try std.testing.expectEqual(@as(u64, 2), renamed.installed_generation);
    try std.testing.expectEqual(@as(usize, 2), renamed.installed.len);
    try std.testing.expectEqualStrings("Imported Legacy", renamed.installed[0].id);
    try std.testing.expectEqual(@as(u32, 8), renamed.installed[0].java_major);
    try std.testing.expectEqualStrings("Renamed World", renamed.installed[1].id);
    try std.testing.expectEqual(@as(u32, 21), renamed.installed[1].java_major);
    try std.testing.expectEqualStrings("release", renamed.available[0].kind);
    try tmp.dir.deleteTree(io, "versions/Imported Legacy");
    try tmp.dir.deleteTree(io, "versions/Renamed World");
    try controller.refreshInstalled();
    try waitForTest(&controller);
    try std.testing.expectEqual(Phase.complete, controller.snapshot().phase);
    try std.testing.expectEqual(@as(usize, 0), controller.snapshot().installed.len);
    try std.testing.expectEqual(@as(u64, 3), controller.snapshot().installed_generation);
    try std.testing.expectEqualStrings("1.21.5", controller.snapshot().available[0].id);
    try std.testing.expectEqual(@as(usize, 0), registry.tasks().len);
    try std.testing.expect(!registry.hasActive());
}

test "canceled local refresh preserves owned Java requirements and generation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    var controller = try Controller.initWithOptions(std.testing.allocator, std.testing.io, .{ .root = path[0..len], .manifest_url = "invalid://local-only" });
    defer controller.deinit();
    const job = try worker_allocator.create(Job);
    job.* = .{ .io = std.testing.io, .operation = .refresh_installed, .root = controller.root, .manifest_url = controller.manifest_url, .version_id = null, .canceled = .init(true) };
    controller.active = job;
    controller.phase = .loading;
    const a = job.arena.allocator();
    const installed = try a.alloc(InstalledEntry, 1);
    installed[0] = .{ .id = try a.dupe(u8, "My World"), .java_major = 21 };
    job.installed = installed;
    job.thread = try std.Thread.spawn(.{}, work, .{job});
    try waitForTest(&controller);
    const snapshot = controller.snapshot();
    try std.testing.expectEqual(Phase.failed, snapshot.phase);
    try std.testing.expectEqual(error.Canceled, snapshot.failure.?);
    try std.testing.expectEqual(@as(u64, 0), snapshot.installed_generation);
    try std.testing.expectEqualStrings("My World", snapshot.installed[0].id);
    try std.testing.expectEqual(@as(u32, 21), snapshot.installed[0].java_major);
}

test "controller busy cancellation joined shutdown and retry without network" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    var controller = try Controller.initWithOptions(std.testing.allocator, std.testing.io, .{ .root = path_buffer[0..len], .manifest_url = "invalid://fixture" });
    defer controller.deinit();
    try std.testing.expectEqual(Phase.idle, controller.snapshot().phase);
    try controller.loadCatalogue();
    try std.testing.expectError(error.Busy, controller.loadCatalogue());
    try std.testing.expectError(error.Busy, controller.installVersion("1.0"));
    controller.cancel();
    try waitForTest(&controller);
    try std.testing.expectEqual(Phase.failed, controller.snapshot().phase);
    try std.testing.expect(controller.snapshot().failure != null);
    try controller.loadCatalogue();
    try waitForTest(&controller);
    try std.testing.expectEqual(error.InvalidUrl, controller.snapshot().failure.?);
    try std.testing.expectError(error.UnsafePath, controller.installVersion("../outside"));
    try controller.loadCatalogue();
    controller.cancel();
    // Deferred deinit must join even when tick has not published the last job.
}
test "installed scan excludes partial corrupt malformed and mismatched local versions" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets/indexes");
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/indexes/fixture.json", .data = "{\"objects\":{}}" });
    try writeVersionFixture(tmp.dir, "good", "good", true);
    try writeVersionFixture(tmp.dir, "missing", "missing", true);
    try tmp.dir.deleteFile(io, "versions/missing/missing.jar");
    try writeVersionFixture(tmp.dir, "corrupt", "corrupt", true);
    try tmp.dir.writeFile(io, .{ .sub_path = "versions/corrupt/corrupt.jar", .data = "bad-client!" });
    try writeVersionFixture(tmp.dir, "wrong", "different", true);
    try writeVersionFixture(tmp.dir, "partial", "partial", false);
    try tmp.dir.createDirPath(io, "versions/malformed");
    try tmp.dir.writeFile(io, .{ .sub_path = "versions/malformed/malformed.json", .data = "{" });
    try tmp.dir.createDirPath(io, "versions/empty");
    var path_buffer: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buffer);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cancel_flag: std.atomic.Value(bool) = .init(false);
    const installed = try scanInstalled(arena.allocator(), io, path_buffer[0..len], &cancel_flag);
    try std.testing.expectEqual(@as(usize, 1), installed.len);
    try std.testing.expectEqualStrings("good", installed[0].id);
    cancel_flag.store(true, .release);
    try std.testing.expectError(error.Canceled, scanInstalled(arena.allocator(), io, path_buffer[0..len], &cancel_flag));
    try std.testing.expectError(error.UnsafePath, openBelow(tmp.dir, io, "../outside"));
    try std.testing.expectError(error.UnsafePath, relativePath("/safe", "/safe-other/file"));
}
fn writeVersionFixture(root: std.Io.Dir, folder: []const u8, document_id: []const u8, dependencies: bool) !void {
    return writeVersionFixtureWithJava(root, folder, document_id, dependencies, null);
}
fn writeVersionFixtureWithJava(root: std.Io.Dir, folder: []const u8, document_id: []const u8, dependencies: bool, java_major: ?u32) !void {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const jar = "PK\x03\x04fixture";
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(jar, &digest, .{});
    const sha1 = std.fmt.bytesToHex(digest, .lower);
    const library_path = try std.fmt.allocPrint(a, "fixture/{s}.jar", .{folder});
    defer a.free(library_path);
    const declared: ?struct { component: []const u8, majorVersion: u32 } = if (java_major) |major| .{ .component = "java-runtime", .majorVersion = major } else null;
    const bytes = try std.json.Stringify.valueAlloc(a, .{
        .id = document_id,
        .javaVersion = declared,
        .mainClass = "net.minecraft.client.main.Main",
        .arguments = .{ .game = [0][]const u8{}, .jvm = [0][]const u8{} },
        .assetIndex = .{ .id = "fixture", .url = "http://fixture/assets" },
        .downloads = .{ .client = .{ .url = "http://fixture/client", .size = jar.len, .sha1 = &sha1 } },
        .libraries = .{.{ .name = "fixture:client:1", .downloads = .{ .artifact = .{ .url = "http://fixture/library", .path = library_path, .size = 3 } } }},
    }, .{ .emit_null_optional_fields = false });
    defer a.free(bytes);
    const dir_path = try std.fmt.allocPrint(a, "versions/{s}", .{folder});
    defer a.free(dir_path);
    try root.createDirPath(io, dir_path);
    const json_path = try std.fmt.allocPrint(a, "versions/{s}/{s}.json", .{ folder, folder });
    defer a.free(json_path);
    const jar_path = try std.fmt.allocPrint(a, "versions/{s}/{s}.jar", .{ folder, folder });
    defer a.free(jar_path);
    try root.writeFile(io, .{ .sub_path = json_path, .data = bytes });
    try root.writeFile(io, .{ .sub_path = jar_path, .data = jar });
    if (dependencies) {
        try root.createDirPath(io, "libraries/fixture");
        const path = try std.fmt.allocPrint(a, "libraries/{s}", .{library_path});
        defer a.free(path);
        try root.writeFile(io, .{ .sub_path = path, .data = "lib" });
    }
}

test "failed install retains its terminal version and permits safe retry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    var controller = try Controller.initWithOptions(std.testing.allocator, std.testing.io, .{ .root = path_buffer[0..len], .manifest_url = "invalid://fixture" });
    defer controller.deinit();
    var id = [_]u8{ '1', '.', '2', '1', '.', '1' };
    try controller.installVersion(&id);
    id[0] = 'x';
    try std.testing.expectEqualStrings("1.21.1", controller.snapshot().installing_version.?);
    try std.testing.expectError(error.Busy, controller.installVersion("1.21.2"));
    try std.testing.expectError(error.Busy, controller.loadCatalogue());
    try waitForTest(&controller);
    try std.testing.expectEqual(Phase.failed, controller.snapshot().phase);
    try std.testing.expectEqual(error.InvalidUrl, controller.snapshot().failure.?);
    try std.testing.expectEqualStrings("1.21.1", controller.snapshot().installing_version.?);
    try controller.installVersion("1.21.2");
    controller.cancel();
    try waitForTest(&controller);
    try std.testing.expect(controller.snapshot().failure != null);
    try std.testing.expectEqualStrings("1.21.2", controller.snapshot().installing_version.?);
}

test "loopback catalogue results publish only after tick joins the worker" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fixture: CatalogueFixture = .{ .server = try address.listen(io, .{}), .io = io };
    defer fixture.server.deinit(io);
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/manifest", .{fixture.server.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    var path_buffer: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buffer);
    var controller = try Controller.initWithOptions(std.testing.allocator, io, .{ .root = path_buffer[0..len], .manifest_url = url });
    defer controller.deinit();
    const thread = try std.Thread.spawn(.{}, CatalogueFixture.serve, .{&fixture});
    defer {
        const listener: std.Io.net.Stream = .{ .socket = fixture.server.socket };
        listener.shutdown(io, .both) catch {};
        thread.join();
    }
    try controller.loadCatalogue();
    const job = controller.active.?;
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    while (!job.done.load(.acquire)) {
        if (std.Io.Clock.awake.now(io).nanoseconds - start > 10_000_000_000) return error.TestTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(usize, 0), controller.snapshot().available.len);
    try std.testing.expectEqual(Phase.loading, controller.snapshot().phase);
    controller.tick();
    try std.testing.expectEqual(Phase.complete, controller.snapshot().phase);
    try std.testing.expectEqual(@as(usize, 1), controller.snapshot().available.len);
    try std.testing.expectEqualStrings("fixture", controller.snapshot().available[0].id);
    const previous = controller.snapshot().available;
    try controller.loadCatalogue();
    try std.testing.expectEqualStrings("fixture", previous[0].id);
    controller.cancel();
    try waitForTest(&controller);
    try std.testing.expectEqualStrings("fixture", controller.snapshot().available[0].id);
}
const CatalogueFixture = struct {
    server: std.Io.net.Server,
    io: std.Io,
    fn serve(self: *CatalogueFixture) void {
        self.respond() catch {};
    }
    fn respond(self: *CatalogueFixture) !void {
        const stream = try self.server.accept(self.io);
        defer stream.close(self.io);
        var buffer: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &buffer);
        while (true) {
            const line = try reader.interface.takeDelimiterInclusive(10);
            if (std.mem.eql(u8, line, "\r\n")) break;
        }
        const body = "{\"latest\":{\"release\":\"fixture\",\"snapshot\":\"fixture\"},\"versions\":[{\"id\":\"fixture\",\"type\":\"release\",\"url\":\"http://fixture/version\",\"time\":\"t\",\"releaseTime\":\"t\"}]}";
        var writer = stream.writer(self.io, &.{});
        try writer.interface.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body });
        try writer.interface.flush();
    }
};

fn waitForTest(controller: *Controller) !void {
    const start = std.Io.Clock.awake.now(controller.io).nanoseconds;
    while (controller.active != null) {
        controller.tick();
        if (std.Io.Clock.awake.now(controller.io).nanoseconds - start > 10_000_000_000) return error.TestTimeout;
        try controller.io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "installed entries derive Java major only from validated local metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "assets/indexes");
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/indexes/fixture.json", .data = "{\"objects\":{}}" });
    try writeVersionFixtureWithJava(tmp.dir, "modern", "modern", true, 21);
    try writeVersionFixture(tmp.dir, "baseline", "baseline", true);
    try writeVersionFixtureWithJava(tmp.dir, "partial", "partial", false, 17);
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var canceled: std.atomic.Value(bool) = .init(false);
    const entries = try scanInstalled(arena.allocator(), io, path[0..len], &canceled);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("baseline", entries[0].id);
    try std.testing.expectEqual(@as(u32, 8), entries[0].java_major);
    try std.testing.expectEqualStrings("modern", entries[1].id);
    try std.testing.expectEqual(@as(u32, 21), entries[1].java_major);
}

test "registry installation owns title, fails after join, and catalogue stays unregistered" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path);
    var registry = tasks.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const cache = try std.testing.allocator.dupe(u8, path[0..len]);
    defer std.testing.allocator.free(cache);
    var controller = try Controller.initWithOptions(std.testing.allocator, io, .{
        .root = path[0..len],
        .manifest_url = "invalid://fixture",
        .task_registry = &registry,
        .cache_root = cache,
    });
    defer controller.deinit();
    cache[0] = 'x';
    try std.testing.expectEqualStrings(path[0..len], controller.cache_root.?);
    try controller.loadCatalogue();
    try waitForTest(&controller);
    try std.testing.expectEqual(@as(usize, 0), registry.tasks().len);
    var id = [_]u8{ '1', '.', '2', '1' };
    try controller.installVersion(&id);
    id[0] = 'x';
    const task = registry.tasks()[0];
    try std.testing.expectEqual(tasks.Kind.game_install, task.kind);
    try std.testing.expectEqualStrings("Install Minecraft 1.21", task.title);
    try std.testing.expectEqual(tasks.State.running, task.state);
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    while (!controller.active.?.done.load(.acquire)) {
        if (std.Io.Clock.awake.now(io).nanoseconds - start > 10_000_000_000) return error.TestTimeout;
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    // Worker completion alone cannot publish a terminal registry state.
    try std.testing.expectEqual(tasks.State.running, task.state);
    controller.tick();
    try std.testing.expectEqual(tasks.State.failed, task.state);
    try std.testing.expectEqual(error.InvalidUrl, task.failure.?);
    try std.testing.expect(task.progress().stage != .finalizing);
    try std.testing.expect(!registry.hasActive());
    try std.testing.expect(controller.published.?.task == null);
    registry.pruneFinished(0);
    try std.testing.expectEqualStrings("1.21", controller.snapshot().installing_version.?);
}

// Test-only workers make cancellation/join races deterministic without network.
fn startWaitingTestJob(controller: *Controller) !*tasks.Task {
    const job = try worker_allocator.create(Job);
    job.* = .{ .io = controller.io, .operation = .install_version, .root = controller.root, .manifest_url = controller.manifest_url, .version_id = "fixture" };
    errdefer job.destroy();
    const registry = controller.task_registry.?;
    const task = try registry.create(.game_install, "Install fixture");
    errdefer |err| registry.finish(task, .{ .failed = err });
    job.task = task;
    try registry.start(task);
    const Worker = struct {
        fn run(current: *Job) void {
            while (!current.cancelFlag().load(.acquire)) std.atomic.spinLoopHint();
            current.failure = error.Canceled;
            current.done.store(true, .release);
        }
    };
    job.thread = try std.Thread.spawn(.{}, Worker.run, .{job});
    controller.active = job;
    controller.phase = .installing;
    return task;
}

test "registry and controller cancellation share worker token and finish after join" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    var registry = tasks.Registry.init(std.testing.allocator);
    defer registry.deinit();
    for ([_]bool{ false, true }) |via_controller| {
        var controller = try Controller.initWithOptions(std.testing.allocator, std.testing.io, .{ .root = path[0..len], .task_registry = &registry });
        defer controller.deinit();
        const task = try startWaitingTestJob(&controller);
        if (via_controller) controller.cancel() else try std.testing.expect(registry.cancel(task.id));
        try std.testing.expectEqual(tasks.State.canceling, task.state);
        try std.testing.expect(task.canceled());
        try std.testing.expectEqual(via_controller, controller.active.?.canceled.load(.acquire));
        try waitForTest(&controller);
        try std.testing.expectEqual(tasks.State.canceled, task.state);
        try std.testing.expectEqual(@as(?anyerror, null), task.failure);
        try std.testing.expectEqual(error.Canceled, controller.snapshot().failure.?);
        try std.testing.expect(controller.published.?.task == null);
        registry.pruneFinished(0);
        try std.testing.expectEqualStrings("fixture", controller.snapshot().installing_version.?);
    }
}

test "deinit joins cancellation workers before finishing registry task" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    var registry = tasks.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var controller = try Controller.initWithOptions(std.testing.allocator, std.testing.io, .{ .root = path[0..len], .task_registry = &registry });
    const task = startWaitingTestJob(&controller) catch |err| {
        controller.deinit();
        return err;
    };
    controller.deinit();
    try std.testing.expectEqual(tasks.State.canceled, task.state);
    try std.testing.expect(!registry.hasActive());
    registry.pruneFinished(0);
}

test "joined committed result remains succeeded after late cancellation" {
    var registry = tasks.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const task = try registry.create(.game_install, "Committed");
    try registry.start(task);
    var controller: Controller = .{ .allocator = std.testing.allocator, .io = std.testing.io, .root = "unused", .manifest_url = "unused", .task_registry = &registry };
    var job: Job = .{ .io = std.testing.io, .operation = .install_version, .root = "unused", .manifest_url = "unused", .version_id = "fixture", .task = task };
    // No worker remains: finishTask is called only after join in tick/deinit.
    try std.testing.expect(registry.cancel(task.id));
    controller.finishTask(&job);
    try std.testing.expectEqual(tasks.State.succeeded, task.state);
    try std.testing.expect(task.canceled());
    try std.testing.expect(job.task == null);
}

test "installer progress reports a coherent registry snapshot" {
    var registry = tasks.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const task = try registry.create(.game_install, "Progress");
    var job: Job = .{ .io = std.testing.io, .operation = .install_version, .root = "unused", .manifest_url = "unused", .version_id = "fixture", .task = task };
    reporting_job = &job;
    defer reporting_job = null;
    report(.{ .completed = 3, .total = 5, .downloaded = 2, .reused = 1 });
    try std.testing.expectEqualDeep(tasks.Progress{ .stage = .downloading, .completed = 3, .total = 5 }, task.progress());
    try std.testing.expectEqual(@as(usize, 3), job.completed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 5), job.total.load(.acquire));
}

test "manifest cache paths are contained and keyed by URL" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path);
    var job: Job = .{ .io = io, .operation = .catalogue, .root = path[0..len], .manifest_url = "http://fixture/manifest?one", .version_id = null, .cache_root = path[0..len] };
    const first = (try manifestCachePath(&job)).?;
    defer worker_allocator.free(first);
    job.manifest_url = "http://fixture/manifest?two";
    const second = (try manifestCachePath(&job)).?;
    defer worker_allocator.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expect(std.mem.startsWith(u8, first, path[0..len]));
    try std.testing.expect(std.mem.endsWith(u8, first, ".json"));
    const dir = try tmp.dir.openDir(io, "http", .{});
    dir.close(io);
    job.cache_root = null;
    try std.testing.expectEqual(@as(?[]u8, null), try manifestCachePath(&job));
}

test "download limits validate and leave an active job unchanged" {
    var controller: Controller = .{ .allocator = std.testing.allocator, .io = std.testing.io, .root = "", .manifest_url = "" };
    try std.testing.expectError(error.InvalidDownloadConnections, controller.setDownloadConnections(0));
    try std.testing.expectError(error.InvalidDownloadConnections, controller.setDownloadConnections(65));
    try std.testing.expectEqual(@as(u16, 8), controller.download_connections);
    var job: Job = .{ .io = std.testing.io, .operation = .catalogue, .root = "", .manifest_url = "", .version_id = null, .download_connections = 3 };
    controller.active = &job;
    try controller.setDownloadConnections(64);
    try std.testing.expectEqual(@as(u16, 64), controller.download_connections);
    try std.testing.expectEqual(@as(u16, 3), job.download_connections);
    controller.active = null;
    try controller.setDownloadConnections(1);
    try std.testing.expectEqual(@as(u16, 1), controller.download_connections);
}

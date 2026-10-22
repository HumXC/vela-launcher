//! Local-only launch supervision. Pipe workers are joined before releasing a job.
const std = @import("std");
const library = @import("game_library.zig");
const java = @import("java_manager.zig");
const planner = @import("../core/minecraft/install_plan.zig");
const launch = @import("../core/minecraft/launch.zig");
const metadata = @import("../core/minecraft/metadata/root.zig");
const loader = @import("../core/minecraft/metadata_loader.zig");
const logs = @import("../core/logs.zig");
const capture = @import("../core/game_log_capture.zig");
const servers = @import("../core/servers.zig");
const config = @import("../core/config.zig");
const instances = @import("../core/instances.zig");
const content_install = @import("../core/content_install.zig");
const content_fs = @import("../core/content_fs.zig");
const native_extract = @import("../core/minecraft/native_extract.zig");
pub const Phase = enum { idle, preparing, running, exited, failed };
pub const EndReason = union(enum) { exited: u8, stopped, failed: anyerror, terminated };
pub const EndEvent = struct { id: u64, attempt_id: u64, reason: EndReason };
pub const Snapshot = struct {
    phase: Phase,
    failure: ?anyerror,
    exit_code: ?u8,
    version: ?[]const u8,
    version_id: ?[]const u8,
    debug: bool,
    attempt_id: u64,
};
pub const Request = struct { version: []const u8, java_path: []const u8, java_major: u32, username: []const u8, min_memory_mb: ?u32 = null, max_memory_mb: u32 = 2048 };
pub const ServerEndpoint = struct { address: []const u8, port: u16 = 25565 };
pub const LaunchOptions = struct {
    /// Stable configuration ID and explicit launcher base opt into guarded recovery checks.
    instance_id: ?[]const u8 = null,
    launcher_root: ?[]const u8 = null,
    instance_directory: ?[]const u8 = null,
    metadata_path: ?[]const u8 = null,
    /// Resolve the required Java version in the worker from installed metadata.
    resolve_java_from_metadata: bool = false,
    java_candidates: []const java.Runtime = &.{},
    debug: bool = false,
    identity: ?launch.Identity = null,
    server: ?ServerEndpoint = null,
    extra_jvm: []const []const u8 = &.{},
    extra_game: []const []const u8 = &.{},
    resolution_width: ?u32 = null,
    resolution_height: ?u32 = null,
    secrets: []const []const u8 = &.{},
};
pub const LaunchGuard = struct {
    context: ?*anyopaque = null,
    /// Nonblocking main-thread reservation. ID is borrowed for this call only.
    acquire: *const fn (?*anyopaque, []const u8) anyerror!void,
    /// Main-thread release after failure or all process/capture work has joined.
    release: *const fn (?*anyopaque) void,
};
pub const ControllerOptions = struct {
    /// Actual final directory, normally DataPaths.logs (launcher/.vela/logs).
    log_directory: ?[]const u8 = null,
    log_limits: logs.Limits = .{},
    capture_limits: capture.Limits = .{},
    launch_guard: ?LaunchGuard = null,
};
pub const LogStatus = struct {
    dropped_packets: u64 = 0,
    disk_failure: ?anyerror = null,
    capture_failure: ?anyerror = null,
    view_failure: ?anyerror = null,
};
const worker_allocator = std.heap.page_allocator;
const Job = struct {
    arena: std.heap.ArenaAllocator = .init(worker_allocator),
    io: std.Io,
    root: []const u8,
    log_directory: []const u8,
    request: Request,
    options: LaunchOptions,
    attempt_id: u64,
    log_nonce: [16]u8,
    capture: ?*capture.Capture = null,
    future: ?std.Io.Future(void) = null,
    canceled: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    running: std.atomic.Value(bool) = .init(false),
    reason: ?EndReason = null,

    fn destroy(self: *Job) void {
        if (self.capture) |collector| collector.deinit(self.io);
        for (self.options.secrets) |secret| std.crypto.secureZero(u8, @constCast(secret));
        for (self.options.extra_jvm) |arg| std.crypto.secureZero(u8, @constCast(arg));
        for (self.options.extra_game) |arg| std.crypto.secureZero(u8, @constCast(arg));
        if (self.options.identity) |identity| std.crypto.secureZero(u8, @constCast(identity.access_token));
        self.arena.deinit();
        worker_allocator.destroy(self);
    }
    fn checkCancel(self: *const Job) !void {
        if (self.canceled.load(.acquire)) return error.Canceled;
        try self.io.checkCancel();
    }
};
pub const Controller = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    log_directory: []const u8,
    log_nonce: [16]u8,
    capture_limits: capture.Limits,
    launch_guard: ?LaunchGuard,
    guard_held: bool = false,
    launch_allowed: bool = true,
    buffer: logs.Buffer,
    view_failure: ?anyerror = null,
    job: ?*Job = null,
    phase: Phase = .idle,
    failure: ?anyerror = null,
    exit_code: ?u8 = null,
    attempt_id: u64 = 0,
    debug: bool = false,
    end_event: ?EndEvent = null,

    pub fn init(a: std.mem.Allocator, io: std.Io, root: []const u8) !Controller {
        return initWithOptions(a, io, root, .{});
    }
    pub fn initWithOptions(a: std.mem.Allocator, io: std.Io, root: []const u8, options: ControllerOptions) !Controller {
        try validPath(root);
        const cwd = try std.process.currentPathAlloc(io, a);
        defer a.free(cwd);
        const absolute_root = try std.fs.path.resolve(a, &.{ cwd, root });
        errdefer a.free(absolute_root);
        if (options.log_directory) |directory| try validPath(directory);
        const launcher_root = if (std.mem.eql(u8, std.fs.path.basename(absolute_root), ".minecraft")) std.fs.path.dirname(absolute_root).? else absolute_root;
        const log_directory = if (options.log_directory) |directory| try std.fs.path.resolve(a, &.{ cwd, directory }) else try std.fs.path.join(a, &.{ launcher_root, ".vela", "logs" });
        errdefer a.free(log_directory);
        var buffer = try logs.Buffer.init(a, options.log_limits, &.{});
        errdefer buffer.deinit();
        if (options.capture_limits.max_packets == 0 or options.capture_limits.max_packets > 4096) return error.InvalidCaptureLimits;
        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        return .{ .allocator = a, .io = io, .root = absolute_root, .log_directory = log_directory, .log_nonce = nonce, .capture_limits = options.capture_limits, .launch_guard = options.launch_guard, .buffer = buffer };
    }
    /// Hiding a window must not call this. Explicit shutdown stops/reaps the child.
    pub fn deinit(self: *Controller) void {
        if (self.job) |job| {
            job.canceled.store(true, .release);
            if (job.future) |*future| future.cancel(self.io);
            self.releaseGuard();
            job.destroy();
        }
        self.buffer.deinit();
        self.allocator.free(self.log_directory);
        self.allocator.free(self.root);
        self.* = undefined;
    }
    fn releaseGuard(self: *Controller) void {
        if (self.guard_held) {
            self.launch_guard.?.release(self.launch_guard.?.context);
            self.guard_held = false;
        }
    }
    pub fn setLaunchAllowed(self: *Controller, allowed: bool) void {
        self.launch_allowed = allowed;
    }
    pub fn stop(self: *Controller) void {
        if (self.job) |job| {
            if (job.future != null and !job.done.load(.acquire)) job.canceled.store(true, .release);
        }
    }
    pub fn tick(self: *Controller) void {
        const job = self.job orelse return;
        if (self.view_failure == null) {
            if (job.capture) |collector| collector.drain(&self.buffer) catch |err| {
                self.view_failure = err;
            };
        }
        if (job.future == null) return;
        if (!job.done.load(.acquire)) {
            if (job.running.load(.acquire)) self.phase = .running;
            return;
        }
        job.future.?.await(self.io);
        job.future = null;
        self.releaseGuard();
        if (self.view_failure == null) {
            if (job.capture) |collector| collector.drain(&self.buffer) catch |err| {
                self.view_failure = err;
            };
            self.buffer.finish(.stdout) catch |err| {
                self.view_failure = err;
            };
            if (self.view_failure == null) self.buffer.finish(.stderr) catch |err| {
                self.view_failure = err;
            };
        }
        self.publish(job.reason orelse .{ .failed = error.MissingTerminalReason });
    }
    fn publish(self: *Controller, reason: EndReason) void {
        self.failure = switch (reason) {
            .failed => |err| err,
            .terminated => error.GameProcessTerminated,
            .exited => |code| if (code == 0) null else error.GameProcessFailed,
            .stopped => null,
        };
        self.exit_code = switch (reason) {
            .exited => |code| code,
            else => null,
        };
        self.phase = if (self.failure != null) .failed else .exited;
        self.end_event = .{ .id = self.attempt_id, .attempt_id = self.attempt_id, .reason = reason };
    }
    pub fn takeEndEvent(self: *Controller) ?EndEvent {
        const event = self.end_event;
        self.end_event = null;
        return event;
    }
    pub fn snapshot(self: *const Controller) Snapshot {
        const id = if (self.job) |job| job.request.version else null;
        return .{ .phase = self.phase, .failure = self.failure, .exit_code = self.exit_code, .version = id, .version_id = id, .debug = self.debug, .attempt_id = self.attempt_id };
    }
    /// Immutable main-thread view; invalidated by tick/start/clearLogs/deinit.
    pub fn logBuffer(self: *const Controller) *const logs.Buffer {
        return &self.buffer;
    }
    pub fn clearLogs(self: *Controller) void {
        self.buffer.clear();
    }
    pub fn logStatus(self: *const Controller) LogStatus {
        const status = if (self.job) |job| if (job.capture) |collector| collector.status() else capture.Status{} else capture.Status{};
        return .{ .dropped_packets = status.dropped_packets, .disk_failure = status.disk_failure, .capture_failure = status.capture_failure, .view_failure = self.view_failure };
    }
    pub fn start(self: *Controller, request: Request) !void {
        return self.startWithOptions(request, .{});
    }
    pub fn startWithOptions(self: *Controller, request: Request, options: LaunchOptions) !void {
        if (!self.launch_allowed) return error.LaunchBlocked;
        if (self.job) |job| if (job.future != null) return error.Busy;
        if (self.launch_guard) |guard| {
            try guard.acquire(guard.context, request.version);
            self.guard_held = true;
        }
        self.attempt_id = std.math.add(u64, self.attempt_id, 1) catch {
            self.releaseGuard();
            return error.AttemptIdExhausted;
        };
        self.end_event = null;
        if (self.job) |previous| previous.destroy();
        self.job = null;
        self.debug = options.debug;
        self.buffer.clear();
        self.view_failure = null;
        self.startInner(request, options) catch |err| {
            self.releaseGuard();
            self.publish(.{ .failed = err });
            return err;
        };
    }
    fn startInner(self: *Controller, request: Request, options: LaunchOptions) !void {
        try metadata.version.validateId(request.version);
        if (!(options.resolve_java_from_metadata and request.java_path.len == 0) and
            (!std.fs.path.isAbsolute(request.java_path) or std.mem.indexOfScalar(u8, request.java_path, 0) != null)) return error.AbsoluteJavaPathRequired;
        if (request.java_major == 0 and !options.resolve_java_from_metadata) return error.InvalidJavaVersion;
        if (request.max_memory_mb == 0) return error.InvalidMemory;
        if (request.min_memory_mb) |minimum| {
            if (minimum == 0 or minimum > request.max_memory_mb) return error.InvalidMemory;
        }
        if (request.username.len == 0 or request.username.len > 16) return error.InvalidUsername;
        for (request.username) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return error.InvalidUsername;
        if ((options.instance_id == null) != (options.launcher_root == null)) return error.IncompleteInstanceContext;
        if (options.instance_id) |id| {
            if (!config.validId(id)) return error.UnsafeInstanceId;
            const root = options.launcher_root.?;
            if (root.len > 4096) return error.UnsafeDataRoot;
            try absolutePath(root);
            if (self.launch_guard == null or !self.guard_held) return error.MissingLaunchGuard;
        }
        if (options.instance_directory) |path| try absolutePath(path);
        if (options.metadata_path) |path| try absolutePath(path);
        if ((options.resolution_width == null) != (options.resolution_height == null)) return error.IncompleteResolution;
        if (options.resolution_width) |width| if (width == 0 or options.resolution_height.? == 0) return error.InvalidResolution;
        if (options.server) |server| _ = try serverHost(server);
        const job = try worker_allocator.create(Job);
        job.* = .{ .io = self.io, .root = undefined, .log_directory = undefined, .request = request, .options = .{}, .attempt_id = self.attempt_id, .log_nonce = self.log_nonce };
        errdefer job.destroy();
        const a = job.arena.allocator();
        job.root = try a.dupe(u8, self.root);
        job.log_directory = try a.dupe(u8, self.log_directory);
        job.request.version = try a.dupe(u8, request.version);
        job.request.java_path = if (request.java_path.len == 0) "" else try std.fs.path.resolve(a, &.{request.java_path});
        job.request.username = try a.dupe(u8, request.username);
        job.options = try cloneOptions(a, options);
        var secrets: std.ArrayList([]const u8) = .empty;
        try secrets.appendSlice(a, job.options.secrets);
        if (job.options.identity) |identity| {
            if (identity.access_token.len > 0 and !std.mem.eql(u8, identity.access_token, "0")) try secrets.append(a, identity.access_token);
        }
        job.capture = try capture.Capture.init(worker_allocator, self.capture_limits, secrets.items);
        job.future = try std.Io.concurrent(self.io, work, .{job});
        self.job = job;
        self.phase = .preparing;
        self.failure = null;
        self.exit_code = null;
    }
};

fn validPath(path: []const u8) !void {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.UnsafePath;
}
fn absolutePath(path: []const u8) !void {
    try validPath(path);
    if (!std.fs.path.isAbsolute(path)) return error.AbsolutePathRequired;
}
fn cloneStrings(a: std.mem.Allocator, strings: []const []const u8) ![]const []const u8 {
    const result = try a.alloc([]const u8, strings.len);
    for (strings, result) |source, *dest| dest.* = try a.dupe(u8, source);
    return result;
}
fn cloneOptions(a: std.mem.Allocator, options: LaunchOptions) !LaunchOptions {
    var result = options;
    result.secrets = try cloneStrings(a, options.secrets);
    result.extra_jvm = try cloneStrings(a, options.extra_jvm);
    result.extra_game = try cloneStrings(a, options.extra_game);
    const candidates = try a.alloc(java.Runtime, options.java_candidates.len);
    for (options.java_candidates, candidates) |source, *dest| dest.* = .{
        .path = try a.dupe(u8, source.path),
        .major = source.major,
        .architecture = source.architecture,
        .vendor = try a.dupe(u8, source.vendor),
    };
    result.java_candidates = candidates;
    if (options.instance_id) |id| result.instance_id = try a.dupe(u8, id);
    if (options.launcher_root) |root| result.launcher_root = try a.dupe(u8, root);
    if (options.instance_directory) |path| result.instance_directory = try a.dupe(u8, path);
    if (options.metadata_path) |path| result.metadata_path = try a.dupe(u8, path);
    if (options.server) |server| result.server = .{ .address = try a.dupe(u8, server.address), .port = server.port };
    if (options.identity) |identity| result.identity = .{
        .name = try a.dupe(u8, identity.name),
        .uuid = try a.dupe(u8, identity.uuid),
        .access_token = try a.dupe(u8, identity.access_token),
        .user_type = try a.dupe(u8, identity.user_type),
        .client_id = try a.dupe(u8, identity.client_id),
        .xuid = try a.dupe(u8, identity.xuid),
        .user_properties = try a.dupe(u8, identity.user_properties),
    };
    return result;
}
fn work(job: *Job) void {
    job.reason = perform(job) catch |err| if (job.canceled.load(.acquire) or err == error.Canceled) .stopped else .{ .failed = err };
    job.done.store(true, .release);
}
fn serverHost(server: ServerEndpoint) ![]const u8 {
    if (std.mem.indexOfScalar(u8, server.address, ':') != null and !std.mem.startsWith(u8, server.address, "[")) {
        if (server.port == 0) return error.InvalidPort;
        _ = std.Io.net.IpAddress.parseIp6(server.address, server.port) catch return error.InvalidAddress;
        return server.address;
    }
    return (try servers.validateAddress(server.address, server.port)).host;
}
fn hasQuickPlay(version: metadata.version.Version) bool {
    const arguments = version.arguments orelse return false;
    for (arguments.game orelse return false) |argument| switch (argument) {
        .literal => |text| if (std.mem.indexOf(u8, text, "$" ++ "{quickPlayMultiplayer}") != null) return true,
        .conditional => |conditional| for (conditional.values) |text| {
            if (std.mem.indexOf(u8, text, "$" ++ "{quickPlayMultiplayer}") != null) return true;
        },
    };
    return false;
}
fn perform(job: *Job) !EndReason {
    const a = job.arena.allocator();
    try job.checkCancel();
    // The caller already holds the instance reservation; this gate is read-only.
    if (job.options.instance_id) |id| {
        var paths = try instances.Paths.init(a, job.io, job.options.launcher_root.?);
        defer paths.deinit();
        try content_install.requireRecoveryClear(a, job.io, &paths, id, job.request.version);
        try job.checkCancel();
    }
    var loaded = try loader.loadInstalled(a, job.io, .{ .root = job.root, .version_id = job.request.version, .metadata_path = job.options.metadata_path, .cancel = &job.canceled });
    defer loaded.deinit();
    const version = loaded.version.value;
    const required = metadata.version.requiredJavaMajor(version);
    if (job.options.resolve_java_from_metadata) {
        try job.checkCancel();
        const required_major = std.math.cast(u32, required) orelse return error.InvalidJavaVersion;
        const java_path = if (job.request.java_path.len != 0) job.request.java_path else blk: {
            for (job.options.java_candidates) |candidate| {
                if (java.compatible(candidate.major, required_major) and candidate.architecture == @import("../core/java_runtime.zig").host()) break :blk candidate.path;
            }
            return error.NoCompatibleJava;
        };
        if (!std.fs.path.isAbsolute(java_path) or std.mem.indexOfScalar(u8, java_path, 0) != null) return error.AbsoluteJavaPathRequired;
        job.request.java_path = try std.fs.path.resolve(a, &.{java_path});
        job.request.java_major = required_major;
    }
    if (required != job.request.java_major) return error.JavaMajorMismatch;
    const runtime = try java.probe(a, job.io, job.request.java_path, &job.canceled);
    defer java.freeRuntime(a, runtime);
    if (runtime.major != required) return error.JavaMajorMismatch;
    try runtime.architecture.requireHost();
    var assets = try library.loadAssets(a, job.io, job.root, (version.asset_index orelse return error.MissingAssetIndex).id);
    defer assets.deinit();
    var env = try library.hostEnvironment();
    env.arch = runtime.architecture.cpuName();
    const cpu_arch = env.arch;
    const client_relative_path = try @import("../core/minecraft/layout.zig").installedClient(a, version);
    defer a.free(client_relative_path);
    var plan = try planner.buildInstalled(a, version, assets.value, env, .{ .root = job.root, .client_relative_path = client_relative_path, .instance_name = job.request.version, .game_directory = job.options.instance_directory });
    defer plan.deinit();
    try validateLocalPlan(job, plan.value);
    try prepareNatives(job, plan.value, cpu_arch);
    const uuid = offlineUuid(job.request.username);
    var game_args: std.ArrayList([]const u8) = .empty;
    try game_args.appendSlice(a, job.options.extra_game);
    var quick_play: ?[]const u8 = null;
    var quick_path: ?[]const u8 = null;
    if (job.options.server) |server| {
        const host = try serverHost(server);
        const port = try std.fmt.allocPrint(a, "{d}", .{server.port});
        if (hasQuickPlay(version)) {
            quick_play = if (std.mem.indexOfScalar(u8, host, ':') != null) try std.fmt.allocPrint(a, "[{s}]:{s}", .{ host, port }) else try std.fmt.allocPrint(a, "{s}:{s}", .{ host, port });
            quick_path = try std.fs.path.join(a, &.{ job.options.instance_directory orelse job.root, "quick-play.json" });
            env.features = &.{ .{ .name = "is_quick_play_multiplayer", .enabled = true }, .{ .name = "has_quick_plays_support", .enabled = true } };
        } else try game_args.appendSlice(a, &.{ "--server", host, "--port", port });
    }
    if (job.options.resolution_width != null) {
        const features = try a.alloc(metadata.rules.Feature, env.features.len + 1);
        @memcpy(features[0..env.features.len], env.features);
        features[env.features.len] = .{ .name = "has_custom_resolution", .enabled = true };
        env.features = features;
    }
    var command = try launch.build(a, version, plan.value, env, .{ .root = job.root, .java_executable = job.request.java_path, .identity = job.options.identity orelse .{ .name = job.request.username, .uuid = &uuid }, .game_directory = job.options.instance_directory, .min_memory_mb = job.request.min_memory_mb, .max_memory_mb = job.request.max_memory_mb, .extra_jvm = job.options.extra_jvm, .extra_game = game_args.items, .resolution_width = job.options.resolution_width, .resolution_height = job.options.resolution_height, .quick_play_path = quick_path, .quick_play_multiplayer = quick_play });
    defer command.deinit();
    // Command arguments contain credentials; never send argv to diagnostics.
    defer for (command.value.argv) |arg| std.crypto.secureZero(u8, @constCast(arg));
    try job.checkCancel();
    var disk: [2]?std.Io.File = .{ null, null };
    defer for (disk) |file| if (file) |value| value.close(job.io);
    openLogFiles(job, &disk) catch |err| job.capture.?.noteDiskFailure(err);
    const old_protection = job.io.swapCancelProtection(.blocked);
    var child = std.process.spawn(job.io, .{ .argv = command.value.argv, .cwd = .{ .path = command.value.cwd }, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe }) catch |err| {
        _ = job.io.swapCancelProtection(old_protection);
        return err;
    };
    _ = job.io.swapCancelProtection(old_protection);
    // LIFO kills/reaps first, then joins readers, then closes disk files.
    defer job.capture.?.drainAndJoin(job.io);
    defer forceStop(&child, job.io);
    try job.capture.?.start(job.io, &child, disk);
    job.running.store(true, .release);
    return switch (try waitGame(job, &child)) {
        .exited => |code| .{ .exited = code },
        else => .terminated,
    };
}
fn openLogFiles(job: *Job, disk: *[2]?std.Io.File) !void {
    try std.Io.Dir.cwd().createDirPath(job.io, job.log_directory);
    const directory = try std.Io.Dir.cwd().openDir(job.io, job.log_directory, .{ .follow_symlinks = false });
    defer directory.close(job.io);
    for (disk, [_][]const u8{ "stdout", "stderr" }) |*file, source| {
        const name = try std.fmt.allocPrint(job.arena.allocator(), "{s}-{s}-{d}.{s}.log", .{ job.request.version, std.fmt.bytesToHex(&job.log_nonce, .lower), job.attempt_id, source });
        file.* = try directory.createFile(job.io, name, .{ .exclusive = true, .permissions = content_fs.privatePermissions(false) });
    }
}
fn openLocalFile(job: *Job, root: std.Io.Dir, path: []const u8) !std.Io.File {
    const prefix = std.mem.trimEnd(u8, job.root, "/\\");
    if (!std.fs.path.isAbsolute(path) or path.len <= prefix.len or
        !std.mem.startsWith(u8, path, prefix) or path[prefix.len] != std.fs.path.sep)
        return error.UnsafePath;
    const relative = path[prefix.len + 1 ..];
    const portable = if (@import("builtin").os.tag == .windows) blk: {
        const copy = try job.arena.allocator().dupe(u8, relative);
        std.mem.replaceScalar(u8, copy, '\\', '/');
        break :blk copy;
    } else relative;
    const parent = try content_fs.parent(root, job.io, portable, false);
    defer parent.deinit(job.io);
    return content_fs.openRegular(parent.dir, job.io, parent.name);
}
fn validateOpenFile(job: *Job, file: std.Io.File, expected: planner.File) ![20]u8 {
    const stat = try file.stat(job.io);
    if (stat.kind != .file or stat.nlink != 1) return error.IncompleteInstall;
    if (expected.kind == .native and stat.size > (native_extract.Limits{}).max_archive_bytes)
        return error.NativeArchiveTooLarge;
    if (expected.size) |size| if (size != stat.size) return error.IncompleteInstall;
    var hash = std.crypto.hash.Sha1.init(.{});
    var bytes: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < stat.size) {
        try job.checkCancel();
        const want: usize = @intCast(@min(bytes.len, stat.size - offset));
        const n = try file.readPositionalAll(job.io, bytes[0..want], offset);
        if (n != want) return error.IncompleteInstall;
        hash.update(bytes[0..n]);
        offset += n;
    }
    const after = try file.stat(job.io);
    if (!sameLocalFile(stat, after)) return error.IncompleteInstall;
    var actual: [20]u8 = undefined;
    hash.final(&actual);
    if (expected.sha1) |wanted| if (!std.mem.eql(u8, &actual, &wanted)) return error.IncompleteInstall;
    return actual;
}
fn sameLocalFile(before: std.Io.File.Stat, after: std.Io.File.Stat) bool {
    return after.kind == before.kind and after.inode == before.inode and
        after.size == before.size and after.nlink == before.nlink and
        after.mtime.nanoseconds == before.mtime.nanoseconds and
        after.ctime.nanoseconds == before.ctime.nanoseconds;
}
fn prepareNatives(job: *Job, plan: planner.Plan, cpu_arch: []const u8) !void {
    if (plan.native_checks.len == 0 and plan.native_extractions.len == 0) return;
    const a = job.arena.allocator();
    const root = try content_fs.openAbsolute(job.io, job.root);
    defer root.close(job.io);
    const files = try a.alloc(std.Io.File, plan.native_checks.len);
    const hashes = try a.alloc([20]u8, plan.native_checks.len);
    const stats = try a.alloc(std.Io.File.Stat, plan.native_checks.len);
    var opened: usize = 0;
    defer for (files[0..opened]) |file| file.close(job.io);
    for (plan.native_checks, 0..) |check, i| {
        try job.checkCancel();
        const expected = try nativePlanFile(plan, check.archive_path);
        files[i] = try openLocalFile(job, root, expected.path);
        opened += 1;
        stats[i] = try files[i].stat(job.io);
        if (stats[i].size > (native_extract.Limits{}).max_archive_bytes)
            return error.NativeArchiveTooLarge;
        hashes[i] = try validateOpenFile(job, files[i], expected);
        if (!sameLocalFile(stats[i], try files[i].stat(job.io))) return error.IncompleteInstall;
        try native_extract.inspectFileWithFamily(a, job.io, files[i], cpu_arch, &job.canceled, check.classic_family);
        const after = try validateOpenFile(job, files[i], expected);
        if (!std.mem.eql(u8, &hashes[i], &after) or
            !sameLocalFile(stats[i], try files[i].stat(job.io))) return error.IncompleteInstall;
    }
    if (plan.native_extractions.len != 0) {
        for (files, stats) |file, stat| {
            if (!sameLocalFile(stat, try file.stat(job.io))) return error.IncompleteInstall;
        }
        const sources = try a.alloc(std.Io.File, plan.native_extractions.len);
        const original_stats = try a.alloc(std.Io.File.Stat, plan.native_extractions.len);
        for (plan.native_extractions, 0..) |task, i| {
            sources[i] = blk: {
                for (plan.native_checks, 0..) |check, j| {
                    if (std.mem.eql(u8, task.archive_path, check.archive_path)) {
                        original_stats[i] = stats[j];
                        break :blk files[j];
                    }
                }
                return error.InvalidNativeSources;
            };
        }
        // Legacy outputs are always rebuilt together; modern classpath natives stay untouched.
        try native_extract.extractCheckedFilesWithStats(a, job.io, plan.native_extractions, sources, original_stats, cpu_arch, &job.canceled);
    }
    for (plan.native_checks, 0..) |check, i| {
        const expected = try nativePlanFile(plan, check.archive_path);
        const after = try validateOpenFile(job, files[i], expected);
        if (!std.mem.eql(u8, &hashes[i], &after) or
            !sameLocalFile(stats[i], try files[i].stat(job.io))) return error.IncompleteInstall;
    }
    try job.checkCancel();
}
test "launch file stability includes native phase timestamps" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "native-source", .{});
    defer file.close(io);
    const before = try file.stat(io);
    try std.testing.expect(sameLocalFile(before, before));
    var after = before;
    after.mtime.nanoseconds += 1;
    try std.testing.expect(!sameLocalFile(before, after));
    after = before;
    after.ctime.nanoseconds += 1;
    try std.testing.expect(!sameLocalFile(before, after));
}
fn nativePlanFile(plan: planner.Plan, path: []const u8) !planner.File {
    for (plan.files) |expected| if (std.mem.eql(u8, expected.path, path)) return expected;
    return error.InvalidNativeSources;
}
fn validateLocalPlan(job: *Job, plan: planner.Plan) !void {
    const root = try content_fs.openAbsolute(job.io, job.root);
    defer root.close(job.io);
    for (plan.files) |expected| {
        try job.checkCancel();
        const file = openLocalFile(job, root, expected.path) catch return error.IncompleteInstall;
        defer file.close(job.io);
        _ = try validateOpenFile(job, file, expected);
    }
}
fn forceStop(child: *std.process.Child, io: std.Io) void {
    const id = child.id orelse return;
    const old_protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(old_protection);
    if (@import("builtin").os.tag == .windows) {
        _ = std.os.windows.ntdll.NtTerminateProcess(id, @fromBackingInt(@intCast(1)));
    } else {
        std.posix.kill(id, .KILL) catch {};
    }
    _ = child.wait(io) catch {};
}
// Never cancel child.wait: Zig 0.16 clears the child ID on a canceled POSIX wait.
fn waitGame(job: *Job, child: *std.process.Child) !std.process.Child.Term {
    const builtin = @import("builtin");
    while (true) {
        try job.checkCancel();
        if (builtin.os.tag == .windows) {
            const timeout: std.os.windows.LARGE_INTEGER = 0;
            switch (std.os.windows.ntdll.NtWaitForSingleObject(child.id.?, .FALSE, &timeout)) {
                .SUCCESS => {
                    const old_protection = job.io.swapCancelProtection(.blocked);
                    defer _ = job.io.swapCancelProtection(old_protection);
                    return child.wait(job.io);
                },
                .TIMEOUT => {},
                else => return error.ProcessStatusFailed,
            }
        } else {
            var status: if (builtin.link_libc) c_int else u32 = undefined;
            const result = std.posix.system.waitpid(child.id.?, &status, std.posix.W.NOHANG);
            switch (std.posix.errno(result)) {
                .SUCCESS => if (result != 0) {
                    child.id = null;
                    return std.Io.Threaded.statusToTerm(@bitCast(status));
                },
                .INTR => continue,
                else => return error.ProcessStatusFailed,
            }
        }
        try std.Io.sleep(job.io, .fromMilliseconds(20), .awake);
    }
}

fn offlineUuid(name: []const u8) [32]u8 {
    var hash = std.crypto.hash.Md5.init(.{});
    hash.update("OfflinePlayer:");
    hash.update(name);
    var bytes: [16]u8 = undefined;
    hash.final(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x30;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return std.fmt.bytesToHex(bytes, .lower);
}

test "controller rejects unsafe launch input and joins missing installation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    var controller = try Controller.init(std.testing.allocator, std.testing.io, path[0..len]);
    defer controller.deinit();
    const request: Request = .{ .version = "fixture", .java_path = "/not/a/real/java", .java_major = 8, .username = "Player" };
    var unsafe = request;
    unsafe.version = "../fixture";
    try std.testing.expectError(error.UnsafeVersionId, controller.start(unsafe));
    unsafe = request;
    unsafe.java_path = "java";
    try std.testing.expectError(error.AbsoluteJavaPathRequired, controller.start(unsafe));
    unsafe = request;
    unsafe.java_path = "";
    try std.testing.expectError(error.AbsoluteJavaPathRequired, controller.start(unsafe));
    unsafe = request;
    unsafe.java_major = 0;
    try std.testing.expectError(error.InvalidJavaVersion, controller.start(unsafe));
    unsafe.java_path = "java";
    try std.testing.expectError(error.AbsoluteJavaPathRequired, controller.startWithOptions(unsafe, .{ .resolve_java_from_metadata = true }));
    unsafe.java_path = "/java\x00hidden";
    try std.testing.expectError(error.AbsoluteJavaPathRequired, controller.startWithOptions(unsafe, .{ .resolve_java_from_metadata = true }));
    unsafe = request;
    unsafe.min_memory_mb = 0;
    try std.testing.expectError(error.InvalidMemory, controller.start(unsafe));
    unsafe.min_memory_mb = request.max_memory_mb + 1;
    try std.testing.expectError(error.InvalidMemory, controller.start(unsafe));
    try controller.start(request);
    try std.testing.expectError(error.Busy, controller.start(request));
    try waitForTest(&controller);
    try std.testing.expectEqual(Phase.failed, controller.snapshot().phase);
    try std.testing.expectEqual(error.MissingVersionMetadata, controller.snapshot().failure.?);
    try controller.start(request);
}

fn waitForTest(controller: *Controller) !void {
    for (0..1000) |_| {
        controller.tick();
        if (controller.phase == .exited or controller.phase == .failed) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    }
    return error.TestTimeout;
}

test "fresh native preparation repairs missing and damaged legacy outputs before Java" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]bool{ true, false }) |missing| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFixture(tmp.dir, 21);
        if (missing) try tmp.dir.deleteTree(io, "versions/fixture/natives") else try tmp.dir.writeFile(io, .{ .sub_path = "versions/fixture/natives/stale", .data = "stale" });
        try writeFakeJavaImpl(tmp.dir, 21, "test -f versions/fixture/natives/libfixture.so && test ! -e versions/fixture/natives/stale && test ! -e versions/fixture/natives/META-INF/fixture.txt || exit 89", true, @import("../core/java_runtime.zig").host());
        var path: [4096]u8 = undefined;
        const len = try tmp.dir.realPath(io, &path);
        const java_path = try std.fs.path.join(a, &.{ path[0..len], "fake-java" });
        defer a.free(java_path);
        var guard: TestGuard = .{};
        var controller = try Controller.initWithOptions(a, io, path[0..len], .{ .launch_guard = guard.callbacks() });
        defer controller.deinit();
        try controller.start(.{ .version = "fixture", .java_path = java_path, .java_major = 21, .username = "Player" });
        try waitForTest(&controller);
        try std.testing.expectEqual(Phase.exited, controller.snapshot().phase);
        try std.testing.expectEqual(@as(?u8, 0), controller.snapshot().exit_code);
        const output = try tmp.dir.readFileAlloc(io, "versions/fixture/natives/libfixture.so", a, .limited(128));
        defer a.free(output);
        const payload = nativePayload(try hostNativeMachine());
        try std.testing.expectEqualSlices(u8, &payload, output);
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "versions/fixture/natives/META-INF/fixture.txt", .{}));
        try std.testing.expect(!guard.held and guard.released == 1);
        try expectNoNativeStages(tmp.dir);
    }
}
test "transient native archive mutation preserves old output and prevents game execution" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Hook = struct {
        var source: std.Io.File = undefined;
        var original: std.Io.File.Stat = undefined;
        var before: []const u8 = undefined;
        var replacement: []const u8 = undefined;
        var guard: *TestGuard = undefined;
        var mutations: usize = 0;
        var held_during_mutation: bool = false;
        var delegate: @TypeOf(io.vtable.dirRenamePreserve) = undefined;

        fn rename(userdata: ?*anyopaque, old_dir: std.Io.Dir, old_name: []const u8, new_dir: std.Io.Dir, new_name: []const u8) std.Io.Dir.RenamePreserveError!void {
            try delegate(userdata, old_dir, old_name, new_dir, new_name);
            if (mutations == 0 and std.mem.eql(u8, new_name, "old")) {
                // Restore approved bytes and mtime after backup; original ctime must still reject publication.
                tryChange() catch return error.Unexpected;
            }
        }
        fn tryChange() !void {
            try source.writePositionalAll(io, replacement, 0);
            try source.writePositionalAll(io, before, 0);
            try source.setTimestamps(io, .{ .modify_timestamp = .{ .new = original.mtime } });
            held_during_mutation = guard.held and guard.released == 0;
            mutations += 1;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, 21);
    try writeFakeJavaImpl(tmp.dir, 21, "exit 0", true, @import("../core/java_runtime.zig").host());
    const before = try tmp.dir.readFileAlloc(io, "libraries/fixture/native.jar", a, .limited(1024));
    defer a.free(before);
    const replacement = try nativeFixtureZip(a, .{ .payload_tag = 1 });
    defer a.free(replacement);
    try std.testing.expectEqual(before.len, replacement.len);
    try std.testing.expect(!std.mem.eql(u8, before, replacement));
    try tmp.dir.writeFile(io, .{ .sub_path = "replacement-native.jar", .data = replacement });
    const replacement_file = try tmp.dir.openFile(io, "replacement-native.jar", .{ .follow_symlinks = false });
    defer replacement_file.close(io);
    try native_extract.inspectFile(a, io, replacement_file, @tagName(@import("builtin").cpu.arch), null);
    const source = try tmp.dir.openFile(io, "libraries/fixture/native.jar", .{ .mode = .read_write, .follow_symlinks = false });
    defer source.close(io);
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path);
    const java_path = try std.fs.path.join(a, &.{ path[0..len], "fake-java" });
    defer a.free(java_path);
    var guard: TestGuard = .{};
    Hook.source = source;
    Hook.original = try source.stat(io);
    Hook.before = before;
    Hook.replacement = replacement;
    Hook.guard = &guard;
    Hook.mutations = 0;
    Hook.held_during_mutation = false;
    Hook.delegate = io.vtable.dirRenamePreserve;
    var vtable = io.vtable.*;
    vtable.dirRenamePreserve = Hook.rename;
    const hooked_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var controller = try Controller.initWithOptions(a, hooked_io, path[0..len], .{ .launch_guard = guard.callbacks() });
    defer controller.deinit();
    try controller.start(.{ .version = "fixture", .java_path = java_path, .java_major = 21, .username = "Player" });
    try waitForTest(&controller);
    try std.testing.expectEqual(@as(usize, 1), Hook.mutations);
    try std.testing.expect(Hook.held_during_mutation);
    try std.testing.expectEqual(Phase.failed, controller.snapshot().phase);
    try std.testing.expectEqual(@as(anyerror, error.NativeSourceChanged), controller.snapshot().failure.?);
    try expectJavaProbeOnly(tmp.dir);
    const prior = try tmp.dir.readFileAlloc(io, "versions/fixture/natives/libfixture.so", a, .limited(128));
    defer a.free(prior);
    try std.testing.expectEqualStrings("damaged prior output", prior);
    const restored = try tmp.dir.readFileAlloc(io, "libraries/fixture/native.jar", a, .limited(1024));
    defer a.free(restored);
    try std.testing.expectEqualSlices(u8, before, restored);
    const after = try source.stat(io);
    try std.testing.expectEqual(Hook.original.mtime.nanoseconds, after.mtime.nanoseconds);
    try std.testing.expect(Hook.original.ctime.nanoseconds != after.ctime.nanoseconds);
    try std.testing.expect(!guard.held and guard.released == 1);
    try expectNoNativeStages(tmp.dir);
}
test "matching archive hashes do not authorize corrupt CRC or wrong CPU before game execution" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    const wrong: u16 = if (try hostNativeMachine() == 62) 183 else 62;
    for ([_]NativeFixture{ .{ .bad_crc = true }, .{ .machine = wrong } }) |options| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeNativeFixture(tmp.dir, 21, options);
        try writeFakeJavaImpl(tmp.dir, 21, "exit 0", true, @import("../core/java_runtime.zig").host());
        var path: [4096]u8 = undefined;
        const len = try tmp.dir.realPath(io, &path);
        const java_path = try std.fs.path.join(a, &.{ path[0..len], "fake-java" });
        defer a.free(java_path);
        var guard: TestGuard = .{};
        var controller = try Controller.initWithOptions(a, io, path[0..len], .{ .launch_guard = guard.callbacks() });
        defer controller.deinit();
        try controller.start(.{ .version = "fixture", .java_path = java_path, .java_major = 21, .username = "Player" });
        try waitForTest(&controller);
        try std.testing.expectEqual(Phase.failed, controller.snapshot().phase);
        try std.testing.expect(controller.snapshot().failure != null);
        try expectJavaProbeOnly(tmp.dir);
        const prior = try tmp.dir.readFileAlloc(io, "versions/fixture/natives/libfixture.so", a, .limited(128));
        defer a.free(prior);
        try std.testing.expectEqualStrings("damaged prior output", prior);
        try std.testing.expect(!guard.held and guard.released == 1);
        try expectNoNativeStages(tmp.dir);
    }
}
test "native archive symlink ancestors fail closed before game execution" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, 21);
    try tmp.dir.rename("libraries/fixture", tmp.dir, "outside-library", io);
    try tmp.dir.symLink(io, "../outside-library", "libraries/fixture", .{ .is_directory = true });
    try writeFakeJavaImpl(tmp.dir, 21, "exit 0", true, @import("../core/java_runtime.zig").host());
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path);
    const java_path = try std.fs.path.join(a, &.{ path[0..len], "fake-java" });
    defer a.free(java_path);
    var guard: TestGuard = .{};
    var controller = try Controller.initWithOptions(a, io, path[0..len], .{ .launch_guard = guard.callbacks() });
    defer controller.deinit();
    try controller.start(.{ .version = "fixture", .java_path = java_path, .java_major = 21, .username = "Player" });
    try waitForTest(&controller);
    try std.testing.expectEqual(Phase.failed, controller.snapshot().phase);
    try expectJavaProbeOnly(tmp.dir);
    try std.testing.expect(!guard.held and guard.released == 1);
    try expectNoNativeStages(tmp.dir);
}
test "modern classpath native archives are inspected but never legacy extracted" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeNativeFixture(tmp.dir, 21, .{ .modern = true });
    try tmp.dir.deleteTree(io, "versions/fixture/natives");
    try writeFakeJavaImpl(tmp.dir, 21, "exit 0", true, @import("../core/java_runtime.zig").host());
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path);
    const java_path = try std.fs.path.join(a, &.{ path[0..len], "fake-java" });
    defer a.free(java_path);
    var guard: TestGuard = .{};
    var controller = try Controller.initWithOptions(a, io, path[0..len], .{ .launch_guard = guard.callbacks() });
    defer controller.deinit();
    try controller.start(.{ .version = "fixture", .java_path = java_path, .java_major = 21, .username = "Player" });
    try waitForTest(&controller);
    try std.testing.expectEqual(Phase.exited, controller.snapshot().phase);
    try std.testing.expectEqual(@as(?u8, 0), controller.snapshot().exit_code);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "versions/fixture/natives", .{}));
    try std.testing.expect(!guard.held and guard.released == 1);
    try expectNoNativeStages(tmp.dir);
}
test "canceled native preparation runs no Java and keeps reservation until worker join" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, 21);
    try writeFakeJavaImpl(tmp.dir, 21, "exit 0", true, @import("../core/java_runtime.zig").host());
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path);
    const java_path = try std.fs.path.join(a, &.{ path[0..len], "fake-java" });
    defer a.free(java_path);
    var gate: NativeWorkerGate = .{};
    native_worker_gate = &gate;
    defer native_worker_gate = null;
    var vtable = io.vtable.*;
    vtable.concurrent = NativeWorkerGate.concurrent;
    const controlled_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var guard: TestGuard = .{};
    var controller = try Controller.initWithOptions(a, controlled_io, path[0..len], .{ .launch_guard = guard.callbacks() });
    defer controller.deinit();
    defer gate.release();
    try controller.start(.{ .version = "fixture", .java_path = java_path, .java_major = 21, .username = "Player" });
    gate.waitEntered();
    controller.stop();
    try std.testing.expect(guard.held and guard.released == 0);
    try std.testing.expect(!controller.job.?.done.load(.acquire));
    gate.release();
    try waitForTest(&controller);
    try std.testing.expect(controller.takeEndEvent().?.reason == .stopped);
    try std.testing.expect(!guard.held and guard.released == 1);
    try std.testing.expect(controller.job.?.future == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "java-invocations", .{}));
    try expectNoNativeStages(tmp.dir);
}
threadlocal var native_worker_gate: ?*NativeWorkerGate = null;
const NativeWorkerGate = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    entered: bool = false,
    released: bool = false,
    const Context = struct {
        gate: *NativeWorkerGate,
        start: *const fn (*const anyopaque, *anyopaque) void,
        original: [128]u8 align(64),
    };
    fn concurrent(userdata: ?*anyopaque, result_len: usize, result_alignment: std.mem.Alignment, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (*const anyopaque, *anyopaque) void) std.Io.ConcurrentError!*std.Io.AnyFuture {
        const io = std.testing.io;
        const gate = native_worker_gate orelse return io.vtable.concurrent(userdata, result_len, result_alignment, context, context_alignment, start);
        if (context.len > 128 or context_alignment.toByteUnits() > 64) return error.ConcurrencyUnavailable;
        var wrapped: Context = .{ .gate = gate, .start = start, .original = undefined };
        @memcpy(wrapped.original[0..context.len], context);
        return io.vtable.concurrent(userdata, result_len, result_alignment, std.mem.asBytes(&wrapped), .of(Context), run);
    }
    fn run(raw: *const anyopaque, result: *anyopaque) void {
        const context: *const Context = @ptrCast(@alignCast(raw));
        const self = context.gate;
        self.mutex.lockUncancelable(std.testing.io);
        self.entered = true;
        self.condition.broadcast(std.testing.io);
        while (!self.released) self.condition.waitUncancelable(std.testing.io, &self.mutex);
        self.mutex.unlock(std.testing.io);
        context.start(@ptrCast(&context.original), result);
    }
    fn waitEntered(self: *NativeWorkerGate) void {
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        while (!self.entered) self.condition.waitUncancelable(std.testing.io, &self.mutex);
    }
    fn release(self: *NativeWorkerGate) void {
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.released = true;
        self.condition.broadcast(std.testing.io);
    }
};
fn expectNoNativeStages(root: std.Io.Dir) !void {
    const dir = try root.openDir(std.testing.io, "versions/fixture", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    while (try iterator.next(std.testing.io)) |entry|
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".native-stage-"));
}
const NativeFixture = struct { machine: ?u16 = null, bad_crc: bool = false, modern: bool = false, payload_tag: u8 = 0 };
fn hostNativeMachine() !u16 {
    return switch (@import("builtin").cpu.arch) {
        .x86_64 => 62,
        .x86 => 3,
        .aarch64 => 183,
        .arm, .thumb => 40,
        else => error.SkipZigTest,
    };
}
fn nativePayload(machine: u16) [64]u8 {
    var bytes: [64]u8 = @splat(0);
    @memcpy(bytes[0..4], "\x7fELF");
    const wide = machine == 62 or machine == 183;
    bytes[4] = if (wide) 2 else 1;
    bytes[5] = 1;
    bytes[6] = 1;
    std.mem.writeInt(u16, bytes[16..18], 3, .little);
    std.mem.writeInt(u16, bytes[18..20], machine, .little);
    std.mem.writeInt(u32, bytes[20..24], 1, .little);
    std.mem.writeInt(u16, bytes[if (wide) 52 else 40..][0..2], if (wide) 64 else 52, .little);
    return bytes;
}
fn nativeFixtureZip(a: std.mem.Allocator, options: NativeFixture) ![]u8 {
    var data = nativePayload(options.machine orelse try hostNativeMachine());
    data[63] = options.payload_tag;
    const entries = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "libfixture.so", .bytes = &data },
        .{ .name = "META-INF/fixture.txt", .bytes = "excluded" },
    };
    var storage: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    var offsets: [entries.len]u32 = undefined;
    for (entries, 0..) |entry, i| {
        offsets[i] = @intCast(writer.end);
        var header = std.mem.zeroes(std.zip.LocalFileHeader);
        header.signature = std.zip.local_file_header_sig;
        header.version_needed_to_extract = 20;
        header.compression_method = .store;
        header.crc32 = std.hash.Crc32.hash(entry.bytes) ^ @as(u32, if (options.bad_crc and i == 0) 1 else 0);
        header.compressed_size = @intCast(entry.bytes.len);
        header.uncompressed_size = @intCast(entry.bytes.len);
        header.filename_len = @intCast(entry.name.len);
        try writer.writeStruct(header, .little);
        try writer.writeAll(entry.name);
        try writer.writeAll(entry.bytes);
    }
    const central_start = writer.end;
    for (entries, 0..) |entry, i| {
        var header = std.mem.zeroes(std.zip.CentralDirectoryFileHeader);
        header.signature = std.zip.central_file_header_sig;
        header.version_made_by = 0x0314;
        header.version_needed_to_extract = 20;
        header.compression_method = .store;
        header.crc32 = std.hash.Crc32.hash(entry.bytes) ^ @as(u32, if (options.bad_crc and i == 0) 1 else 0);
        header.compressed_size = @intCast(entry.bytes.len);
        header.uncompressed_size = @intCast(entry.bytes.len);
        header.filename_len = @intCast(entry.name.len);
        header.local_file_header_offset = offsets[i];
        try writer.writeStruct(header, .little);
        try writer.writeAll(entry.name);
    }
    var end = std.mem.zeroes(std.zip.EndRecord);
    end.signature = std.zip.end_record_sig;
    end.record_count_disk = entries.len;
    end.record_count_total = entries.len;
    end.central_directory_offset = @intCast(central_start);
    end.central_directory_size = @intCast(writer.end - central_start);
    try writer.writeStruct(end, .little);
    return a.dupe(u8, writer.buffered());
}
fn writeFixture(root: std.Io.Dir, major: ?u32) !void {
    return writeNativeFixture(root, major, .{});
}
fn writeNativeFixture(root: std.Io.Dir, major: ?u32, options: NativeFixture) !void {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const jar = "PK\x03\x04fixture";
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(jar, &digest, .{});
    const sha1 = std.fmt.bytesToHex(digest, .lower);
    const native_zip = try nativeFixtureZip(a, options);
    defer a.free(native_zip);
    std.crypto.hash.Sha1.hash(native_zip, &digest, .{});
    const native_sha1 = std.fmt.bytesToHex(digest, .lower);
    const Download = struct { url: []const u8, path: []const u8, size: usize, sha1: ?[]const u8 = null };
    const native: Download = .{ .url = "https://fixture.invalid/native", .path = "fixture/native.jar", .size = native_zip.len, .sha1 = &native_sha1 };
    const artifact: Download = if (options.modern) native else .{ .url = "https://fixture.invalid/library", .path = "fixture/base.jar", .size = 3 };
    const classifiers: ?struct { native: Download } = if (options.modern) null else .{ .native = native };
    const names: ?struct { linux: []const u8 } = if (options.modern) null else .{ .linux = "native" };
    const declared: ?struct { component: []const u8, majorVersion: u32 } = if (major) |value| .{ .component = "java-runtime", .majorVersion = value } else null;
    const bytes = try std.json.Stringify.valueAlloc(a, .{
        .id = "fixture",
        .mainClass = "net.minecraft.client.main.Main",
        .javaVersion = declared,
        .arguments = .{ .jvm = [_][]const u8{ "-Djava.library.path=${natives_directory}", "-cp", "${classpath}" }, .game = [_][]const u8{ "--username", "${auth_player_name}", "--uuid", "${auth_uuid}", "--gameDir", "${game_directory}", "--assetsDir", "${assets_root}", "--accessToken", "${auth_access_token}" } },
        .assetIndex = .{ .id = "fixture", .url = "https://fixture.invalid/assets" },
        .downloads = .{ .client = .{ .url = "https://fixture.invalid/client", .size = jar.len, .sha1 = &sha1 } },
        .libraries = .{.{ .name = if (options.modern) "fixture:client:1:natives-linux" else "fixture:client:1", .downloads = .{ .artifact = artifact, .classifiers = classifiers }, .natives = names, .extract = .{ .exclude = [_][]const u8{"META-INF/"} } }},
    }, .{ .emit_null_optional_fields = false });
    defer a.free(bytes);
    try root.createDirPath(io, "versions/fixture/natives");
    try root.createDirPath(io, "libraries/fixture");
    try root.createDirPath(io, "assets/indexes");
    try root.writeFile(io, .{ .sub_path = "versions/fixture/fixture.json", .data = bytes });
    try root.writeFile(io, .{ .sub_path = "versions/fixture/fixture.jar", .data = jar });
    try root.writeFile(io, .{ .sub_path = "libraries/fixture/base.jar", .data = "lib" });
    try root.writeFile(io, .{ .sub_path = "libraries/fixture/native.jar", .data = native_zip });
    try root.writeFile(io, .{ .sub_path = "versions/fixture/natives/libfixture.so", .data = "damaged prior output" });
    try root.writeFile(io, .{ .sub_path = "assets/indexes/fixture.json", .data = "{\"objects\":{}}" });
}

test "launch rejects a foreign JVM before native publication or game execution" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, 21);
    const architecture = @import("../core/java_runtime.zig");
    const foreign: architecture.Architecture = if (architecture.host() == .aarch64) .x86_64 else .aarch64;
    try writeFakeJavaImpl(tmp.dir, 21, "touch \"${0%/*}/game-started\"", true, foreign);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const java_path = try std.fs.path.join(a, &.{ root, "fake-java" });
    defer a.free(java_path);
    var controller = try Controller.init(a, io, root);
    defer controller.deinit();
    try controller.start(.{ .version = "fixture", .java_path = java_path, .java_major = 21, .username = "Player" });
    try waitForTest(&controller);
    try std.testing.expectEqual(Phase.failed, controller.snapshot().phase);
    try std.testing.expectEqual(error.JavaArchitectureMismatch, controller.snapshot().failure.?);
    const invocations = try tmp.dir.readFileAlloc(io, "java-invocations", a, .limited(1024));
    defer a.free(invocations);
    try std.testing.expectEqualStrings("called\n", invocations);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "game-started", .{}));
    try expectNoNativeStages(tmp.dir);
}

fn expectJavaProbeOnly(directory: std.Io.Dir) !void {
    const bytes = try directory.readFileAlloc(std.testing.io, "java-invocations", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("called\n", bytes);
}

fn writeFakeJava(root: std.Io.Dir, major: u32, body: []const u8) !void {
    return writeFakeJavaImpl(root, major, body, false, @import("../core/java_runtime.zig").host());
}
fn writeFakeJavaImpl(root: std.Io.Dir, major: u32, body: []const u8, record: bool, architecture: @import("../core/java_runtime.zig").Architecture) !void {
    const marker = if (record) "printf 'called\n' >> \"${0%/*}/java-invocations\"\n" else "";
    const data = try std.fmt.allocPrint(std.testing.allocator, "#!/bin/sh\n{s}case \"$1\" in -version|-XshowSettings:properties) printf 'java.version = {d}.0.1\\njava.vendor = Fixture\\nos.arch = {s}\\nopenjdk version \"{d}.0.1\"\\n' >&2; exit 0;; esac\n{s}\n", .{ marker, major, architecture.cpuName(), major, body });
    defer std.testing.allocator.free(data);
    try root.writeFile(std.testing.io, .{ .sub_path = "fake-java", .data = data });
    const file = try root.openFile(std.testing.io, "fake-java", .{});
    defer file.close(std.testing.io);
    try file.setPermissions(std.testing.io, .fromMode(0o755));
}

test "fake Java receives real argv absolute cwd identity classpath and natives" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, 21);
    try writeFakeJava(tmp.dir, 21, "printf '%s\\n' \"$PWD\" \"$@\"");
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    const java_path = try std.fs.path.join(std.testing.allocator, &.{ path[0..len], "fake-java" });
    defer std.testing.allocator.free(java_path);
    var controller = try Controller.init(std.testing.allocator, std.testing.io, path[0..len]);
    defer controller.deinit();
    var username = [_]u8{ 'P', 'l', 'a', 'y', 'e', 'r' };
    try controller.start(.{ .version = "fixture", .java_path = java_path, .java_major = 21, .username = &username, .min_memory_mb = 1024, .max_memory_mb = 3072 });
    username[0] = 'X';
    try waitForTest(&controller);
    try std.testing.expectEqual(Phase.exited, controller.snapshot().phase);
    try std.testing.expectEqual(@as(?u8, 0), controller.snapshot().exit_code);
    const log_name = try std.fmt.allocPrint(std.testing.allocator, ".vela/logs/fixture-{s}-1.stdout.log", .{std.fmt.bytesToHex(&controller.log_nonce, .lower)});
    defer std.testing.allocator.free(log_name);
    const output = try tmp.dir.readFileAlloc(std.testing.io, log_name, std.testing.allocator, .limited(16 * 1024));
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.startsWith(u8, output, path[0..len]));
    try std.testing.expect(std.mem.indexOf(u8, output, "-Xms1024M") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-Xmx3072M") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Player") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Xlayer") == null);
    const uuid = offlineUuid("Player");
    try std.testing.expect(std.mem.indexOf(u8, output, &uuid) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "libraries/fixture/base.jar") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "versions/fixture/fixture.jar") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "versions/fixture/natives") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "net.minecraft.client.main.Main") != null);
}

test "deferred Java cancellation keeps reservation until worker join" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path);
    var gate: NativeWorkerGate = .{};
    native_worker_gate = &gate;
    defer native_worker_gate = null;
    var vtable = io.vtable.*;
    vtable.concurrent = NativeWorkerGate.concurrent;
    const controlled_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var guard: TestGuard = .{};
    var controller = try Controller.initWithOptions(a, controlled_io, path[0..len], .{ .launch_guard = guard.callbacks() });
    defer controller.deinit();
    defer gate.release();
    try controller.startWithOptions(.{ .version = "fixture", .java_path = "", .java_major = 0, .username = "Player" }, .{ .resolve_java_from_metadata = true });
    gate.waitEntered();
    controller.stop();
    try std.testing.expect(guard.held and guard.released == 0);
    gate.release();
    try waitForTest(&controller);
    try std.testing.expect(controller.takeEndEvent().?.reason == .stopped);
    try std.testing.expect(!guard.held and guard.released == 1);
    try std.testing.expect(controller.job.?.future == null);
}

test "deferred Java launch reads worker metadata without a published catalogue and owns candidates" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path);
    const java_path = try std.fs.path.join(a, &.{ path[0..len], "fake-java" });
    defer a.free(java_path);
    var vendor = [_]u8{ 'F', 'i', 'x', 't', 'u', 'r', 'e' };
    var candidates = [_]java.Runtime{
        .{ .path = "/not/java8", .major = 8, .architecture = @import("../core/java_runtime.zig").host(), .vendor = "Old" },
        .{ .path = java_path, .major = 21, .architecture = @import("../core/java_runtime.zig").host(), .vendor = &vendor },
        .{ .path = "/not/second/java21", .major = 21, .architecture = @import("../core/java_runtime.zig").host(), .vendor = "Later" },
    };
    var gate: NativeWorkerGate = .{};
    native_worker_gate = &gate;
    defer native_worker_gate = null;
    var vtable = io.vtable.*;
    vtable.concurrent = NativeWorkerGate.concurrent;
    const controlled_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var controller = try Controller.init(a, controlled_io, path[0..len]);
    defer controller.deinit();
    defer gate.release();
    // Admission needs neither version metadata nor a catalogue snapshot.
    try controller.startWithOptions(.{ .version = "fixture", .java_path = "", .java_major = 0, .username = "Player" }, .{ .resolve_java_from_metadata = true, .java_candidates = &candidates });
    gate.waitEntered();
    try std.testing.expectEqual(Phase.preparing, controller.snapshot().phase);
    try std.testing.expectEqualStrings("", controller.job.?.request.java_path);
    try std.testing.expectEqual(@as(u32, 0), controller.job.?.request.java_major);
    try writeFixture(tmp.dir, 21);
    try writeFakeJava(tmp.dir, 21, "printf launched > launched");
    // Caller storage can change while the worker is waiting to load metadata.
    java_path[java_path.len - 1] = 'X';
    vendor[0] = 'X';
    candidates[1].major = 8;
    candidates[1].path = "/not/replacement/java";
    try std.testing.expectEqualStrings("Fixture", controller.job.?.options.java_candidates[1].vendor);
    gate.release();
    try waitForTest(&controller);
    try std.testing.expectEqual(Phase.exited, controller.snapshot().phase);
    try std.testing.expectEqual(@as(u32, 21), controller.job.?.request.java_major);
    const selected = try std.fs.path.join(a, &.{ path[0..len], "fake-java" });
    defer a.free(selected);
    try std.testing.expectEqualStrings(selected, controller.job.?.request.java_path);
    _ = try tmp.dir.statFile(io, "launched", .{});
}

test "deferred Java keeps explicit binding and validates the real executable" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, 21);
    try writeFakeJava(tmp.dir, 8, "printf launched > launched");
    var candidate_tmp = std.testing.tmpDir(.{});
    defer candidate_tmp.cleanup();
    try writeFakeJava(candidate_tmp.dir, 21, "printf launched > launched");
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path);
    var candidate_path: [4096]u8 = undefined;
    const candidate_len = try candidate_tmp.dir.realPath(io, &candidate_path);
    const bound_java = try std.fs.path.join(a, &.{ path[0..len], "fake-java" });
    defer a.free(bound_java);
    const compatible_java = try std.fs.path.join(a, &.{ candidate_path[0..candidate_len], "fake-java" });
    defer a.free(compatible_java);
    var controller = try Controller.init(a, io, path[0..len]);
    defer controller.deinit();
    var request: Request = .{ .version = "fixture", .java_path = bound_java, .java_major = 0, .username = "Player" };
    const candidates = [_]java.Runtime{.{ .path = compatible_java, .major = 21, .architecture = @import("../core/java_runtime.zig").host(), .vendor = "Fixture" }};
    try controller.startWithOptions(request, .{ .resolve_java_from_metadata = true, .java_candidates = &candidates });
    try waitForTest(&controller);
    try std.testing.expectEqual(error.JavaMajorMismatch, controller.snapshot().failure.?);
    try std.testing.expectEqualStrings(bound_java, controller.job.?.request.java_path);
    try std.testing.expectEqual(@as(u32, 21), controller.job.?.request.java_major);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "launched", .{}));
    try writeFakeJava(tmp.dir, 21, "printf launched > launched");
    // An explicit binding works even when the candidate list is empty.
    try controller.startWithOptions(request, .{ .resolve_java_from_metadata = true });
    try waitForTest(&controller);
    try std.testing.expectEqual(Phase.exited, controller.snapshot().phase);
    try tmp.dir.deleteFile(io, "launched");
    // Candidate registry metadata cannot authorize a mismatched executable.
    try writeFakeJava(candidate_tmp.dir, 8, "printf launched > launched");
    request.java_path = "";
    try controller.startWithOptions(request, .{ .resolve_java_from_metadata = true, .java_candidates = &candidates });
    try waitForTest(&controller);
    try std.testing.expectEqual(error.JavaMajorMismatch, controller.snapshot().failure.?);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "launched", .{}));
}

test "deferred Java reports no compatible candidate and uses legacy metadata default" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, 21);
    try writeFakeJava(tmp.dir, 8, "exit 0");
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path);
    const java_path = try std.fs.path.join(a, &.{ path[0..len], "fake-java" });
    defer a.free(java_path);
    var controller = try Controller.init(a, io, path[0..len]);
    defer controller.deinit();
    const request: Request = .{ .version = "fixture", .java_path = "", .java_major = 0, .username = "Player" };
    const candidates = [_]java.Runtime{.{ .path = java_path, .major = 8, .architecture = @import("../core/java_runtime.zig").host(), .vendor = "Fixture" }};
    try controller.startWithOptions(request, .{ .resolve_java_from_metadata = true });
    try waitForTest(&controller);
    try std.testing.expectEqual(error.NoCompatibleJava, controller.snapshot().failure.?);
    try controller.startWithOptions(request, .{ .resolve_java_from_metadata = true, .java_candidates = &candidates });
    try waitForTest(&controller);
    try std.testing.expectEqual(error.NoCompatibleJava, controller.snapshot().failure.?);
    try writeFixture(tmp.dir, null);
    try controller.startWithOptions(request, .{ .resolve_java_from_metadata = true, .java_candidates = &candidates });
    try waitForTest(&controller);
    try std.testing.expectEqual(Phase.exited, controller.snapshot().phase);
    try std.testing.expectEqual(@as(u32, 8), controller.job.?.request.java_major);
}

test "metadata and actual Java must both match exactly and partial data never launches" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, 21);
    try writeFakeJava(tmp.dir, 22, "printf launched > launched");
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    const java_path = try std.fs.path.join(std.testing.allocator, &.{ path[0..len], "fake-java" });
    defer std.testing.allocator.free(java_path);
    var controller = try Controller.init(std.testing.allocator, std.testing.io, path[0..len]);
    defer controller.deinit();
    var request: Request = .{ .version = "fixture", .java_path = java_path, .java_major = 22, .username = "Player" };
    try controller.start(request);
    try waitForTest(&controller);
    try std.testing.expectEqual(error.JavaMajorMismatch, controller.snapshot().failure.?);
    request.java_major = 21;
    try controller.start(request);
    try waitForTest(&controller);
    try std.testing.expectEqual(error.JavaMajorMismatch, controller.snapshot().failure.?);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "launched", .{}));
    try writeFixture(tmp.dir, null);
    try controller.start(request);
    try waitForTest(&controller);
    try std.testing.expectEqual(error.JavaMajorMismatch, controller.snapshot().failure.?);
    request.java_major = 8;
    try writeFakeJava(tmp.dir, 8, "exit 7");
    try controller.start(request);
    try waitForTest(&controller);
    try std.testing.expectEqual(error.GameProcessFailed, controller.snapshot().failure.?);
    try std.testing.expectEqual(@as(?u8, 7), controller.snapshot().exit_code);
    try tmp.dir.deleteFile(std.testing.io, "libraries/fixture/base.jar");
    try controller.start(request);
    try waitForTest(&controller);
    try std.testing.expectEqual(error.IncompleteInstall, controller.snapshot().failure.?);
}

test "running child prevents duplicate launch and shutdown cancels wait and reaps" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, 21);
    try writeFakeJava(tmp.dir, 21, "trap '' TERM; printf '%s' \"$$\" > game.pid; while :; do :; done");
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    const java_path = try std.fs.path.join(std.testing.allocator, &.{ path[0..len], "fake-java" });
    defer std.testing.allocator.free(java_path);
    var controller = try Controller.init(std.testing.allocator, std.testing.io, path[0..len]);
    var alive = true;
    defer if (alive) controller.deinit();
    const request: Request = .{ .version = "fixture", .java_path = java_path, .java_major = 21, .username = "Player" };
    try controller.start(request);
    for (0..1000) |_| {
        controller.tick();
        if (controller.phase == .running) break;
        if (controller.phase == .failed) return controller.failure.?;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expectEqual(Phase.running, controller.snapshot().phase);
    try std.testing.expectError(error.Busy, controller.start(request));
    // Await a marker written by the actual process, not merely spawn publication.
    for (0..1000) |_| {
        if (tmp.dir.statFile(std.testing.io, "game.pid", .{})) |_| break else |err| {
            if (err != error.FileNotFound) return err;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
        }
    }
    const pid_text = try tmp.dir.readFileAlloc(std.testing.io, "game.pid", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(pid_text);
    const pid = try std.fmt.parseInt(i32, pid_text, 10);
    controller.deinit();
    alive = false;
    try std.testing.expectEqual(std.os.linux.E.SRCH, std.os.linux.errno(std.os.linux.kill(pid, @fromBackingInt(@intCast(0)))));
}

const TestGuard = struct {
    held: bool = false,
    reject: bool = false,
    acquired: usize = 0,
    released: usize = 0,
    fn acquire(context: ?*anyopaque, _: []const u8) !void {
        const self: *TestGuard = @ptrCast(@alignCast(context.?));
        if (self.reject or self.held) return error.InstanceBusy;
        self.held = true;
        self.acquired += 1;
    }
    fn release(context: ?*anyopaque) void {
        const self: *TestGuard = @ptrCast(@alignCast(context.?));
        std.debug.assert(self.held);
        self.held = false;
        self.released += 1;
    }
    fn callbacks(self: *TestGuard) LaunchGuard {
        return .{ .context = self, .acquire = acquire, .release = release };
    }
};
fn readTestLog(controller: *const Controller, source: []const u8) ![]u8 {
    const name = try std.fmt.allocPrint(std.testing.allocator, "{s}/fixture-{s}-{d}.{s}.log", .{ controller.log_directory, std.fmt.bytesToHex(&controller.log_nonce, .lower), controller.attempt_id, source });
    defer std.testing.allocator.free(name);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, name, std.testing.allocator, .limited(512 * 1024));
}

test "guards and blocked launches preserve attempts while immediate failures emit once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    var guard: TestGuard = .{};
    var controller = try Controller.initWithOptions(std.testing.allocator, std.testing.io, path[0..len], .{ .launch_guard = guard.callbacks() });
    defer controller.deinit();
    const request: Request = .{ .version = "fixture", .java_path = "/unused", .java_major = 21, .username = "bad name" };
    guard.reject = true;
    try std.testing.expectError(error.InstanceBusy, controller.start(request));
    try std.testing.expectEqual(@as(u64, 0), controller.snapshot().attempt_id);
    try std.testing.expect(controller.takeEndEvent() == null);
    guard.reject = false;
    controller.setLaunchAllowed(false);
    try std.testing.expectError(error.LaunchBlocked, controller.start(request));
    try std.testing.expectEqual(@as(usize, 0), guard.acquired);
    controller.setLaunchAllowed(true);
    try std.testing.expectError(error.InvalidUsername, controller.startWithOptions(request, .{ .debug = true }));
    const event = controller.takeEndEvent().?;
    try std.testing.expectEqual(@as(u64, 1), event.id);
    try std.testing.expectEqual(@as(u64, 1), event.attempt_id);
    try std.testing.expectEqual(error.InvalidUsername, event.reason.failed);
    try std.testing.expect(controller.snapshot().debug);
    try std.testing.expectEqual(@as(usize, 1), guard.released);
    try std.testing.expect(!guard.held);
    controller.tick();
    try std.testing.expect(controller.takeEndEvent() == null);
    try std.testing.expectError(error.InvalidUsername, controller.start(request));
    try std.testing.expectEqual(@as(u64, 2), controller.takeEndEvent().?.id);
    try std.testing.expectEqual(error.InvalidUsername, event.reason.failed);
}

test "quick exit preserves code and sanitizes owned options before UI and both disk streams" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, 21);
    try tmp.dir.createDirPath(std.testing.io, "instances/custom");
    try writeFakeJava(tmp.dir, 21, "pwd; printf '%s\\n' \"$@\"; printf fake-; printf 'token-123\\n'; printf '[ERROR] fake-token-123\\n' >&2; exit 7");
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    const java_path = try std.fs.path.join(std.testing.allocator, &.{ path[0..len], "fake-java" });
    defer std.testing.allocator.free(java_path);
    const game_path = try std.fs.path.join(std.testing.allocator, &.{ path[0..len], "instances/custom" });
    defer std.testing.allocator.free(game_path);
    var guard: TestGuard = .{};
    var controller = try Controller.initWithOptions(std.testing.allocator, std.testing.io, path[0..len], .{ .launch_guard = guard.callbacks() });
    defer controller.deinit();
    var token = "fake-token-123".*;
    var name = "Alice".*;
    var host = "localhost".*;
    const request: Request = .{ .version = "fixture", .java_path = java_path, .java_major = 21, .username = "Player" };
    try controller.startWithOptions(request, .{ .debug = true, .instance_directory = game_path, .identity = .{ .name = &name, .uuid = "11111111111111111111111111111111", .access_token = &token }, .server = .{ .address = &host, .port = 24444 }, .extra_jvm = &.{"-Dfake=test"}, .extra_game = &.{"--fixture"}, .resolution_width = 960, .resolution_height = 540 });
    token[0] = 'X';
    name[0] = 'X';
    host[0] = 'X';
    try std.testing.expectError(error.Busy, controller.start(request));
    try std.testing.expectEqual(@as(u64, 1), controller.snapshot().attempt_id);
    try std.testing.expect(controller.takeEndEvent() == null);
    // Do not tick until the child exits: the main frame never observed running.
    for (0..1000) |_| {
        if (controller.job.?.done.load(.acquire)) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expect(controller.job.?.done.load(.acquire));
    try std.testing.expectEqual(Phase.preparing, controller.snapshot().phase);
    try std.testing.expect(guard.held);
    controller.tick();
    try std.testing.expectEqual(Phase.failed, controller.snapshot().phase);
    const event = controller.takeEndEvent().?;
    try std.testing.expectEqual(@as(u8, 7), event.reason.exited);
    try std.testing.expectEqual(@as(?u8, 7), controller.snapshot().exit_code);
    try std.testing.expect(!guard.held);
    try std.testing.expect(controller.takeEndEvent() == null);
    const out = try readTestLog(&controller, "stdout");
    defer std.testing.allocator.free(out);
    const err = try readTestLog(&controller, "stderr");
    defer std.testing.allocator.free(err);
    try std.testing.expect(std.mem.startsWith(u8, out, game_path));
    for ([_][]const u8{ "Alice", "--server\nlocalhost\n--port\n24444", "-Dfake=test", "--fixture", "[REDACTED]" }) |expected| try std.testing.expect(std.mem.indexOf(u8, out, expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, err, "[ERROR] [REDACTED]") != null);
    for ([_][]const u8{ out, err }) |text| try std.testing.expect(std.mem.indexOf(u8, text, "fake-token-123") == null);
    for (controller.logBuffer().lines()) |line| try std.testing.expect(std.mem.indexOf(u8, line.text, "fake-token-123") == null);
    try std.testing.expect(controller.logStatus().disk_failure == null);
    try std.testing.expect(controller.logStatus().capture_failure == null);
    controller.clearLogs();
    try std.testing.expectEqual(@as(usize, 0), controller.logBuffer().lineCount());
    const after_clear = try readTestLog(&controller, "stdout");
    defer std.testing.allocator.free(after_clear);
    try std.testing.expectEqualStrings(out, after_clear);
}

test "disk failure and bounded handoff never block a high-volume game" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, 21);
    try writeFakeJava(tmp.dir, 21, "i=0; while [ \"$i\" -lt 10000 ]; do printf '[INFO] fake-token-123 %s\\n' \"$i\"; printf '[ERROR] err %s\\n' \"$i\" >&2; i=$((i+1)); done; exit 0");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "not-a-directory", .data = "occupied" });
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    const java_path = try std.fs.path.join(std.testing.allocator, &.{ path[0..len], "fake-java" });
    defer std.testing.allocator.free(java_path);
    const bad_logs = try std.fs.path.join(std.testing.allocator, &.{ path[0..len], "not-a-directory", "logs" });
    defer std.testing.allocator.free(bad_logs);
    var controller = try Controller.initWithOptions(std.testing.allocator, std.testing.io, path[0..len], .{ .log_directory = bad_logs, .capture_limits = .{ .max_packets = 4 }, .log_limits = .{ .max_lines = 100, .max_bytes = 4096, .max_line_bytes = 256 } });
    defer controller.deinit();
    try controller.startWithOptions(.{ .version = "fixture", .java_path = java_path, .java_major = 21, .username = "Player" }, .{ .secrets = &.{"fake-token-123"} });
    for (0..2000) |_| {
        if (controller.job.?.done.load(.acquire)) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expect(controller.job.?.done.load(.acquire));
    controller.tick();
    try std.testing.expectEqual(@as(u8, 0), controller.takeEndEvent().?.reason.exited);
    try std.testing.expect(controller.logStatus().disk_failure != null);
    try std.testing.expect(controller.logStatus().capture_failure == null);
    try std.testing.expect(controller.logStatus().dropped_packets > 0);
    try std.testing.expect(controller.logBuffer().lineCount() <= 100);
    try std.testing.expect(controller.logBuffer().byteCount() <= 4096);
    for (controller.logBuffer().lines()) |line| try std.testing.expect(std.mem.indexOf(u8, line.text, "fake-token-123") == null);
}

test "explicit stop reaps the child and releases reservation before terminal event" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, 21);
    try writeFakeJava(tmp.dir, 21, "printf '%s' \"$$\" > game.pid; printf '[INFO] ready\\n'; while :; do :; done");
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    const java_path = try std.fs.path.join(std.testing.allocator, &.{ path[0..len], "fake-java" });
    defer std.testing.allocator.free(java_path);
    var guard: TestGuard = .{};
    var controller = try Controller.initWithOptions(std.testing.allocator, std.testing.io, path[0..len], .{ .launch_guard = guard.callbacks() });
    defer controller.deinit();
    try controller.start(.{ .version = "fixture", .java_path = java_path, .java_major = 21, .username = "Player" });
    for (0..1000) |_| {
        controller.tick();
        if (tmp.dir.statFile(std.testing.io, "game.pid", .{})) |_| break else |err| if (err != error.FileNotFound) return err;
        if (controller.failure) |err| return err;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expect(guard.held);
    const pid_text = try tmp.dir.readFileAlloc(std.testing.io, "game.pid", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(pid_text);
    const pid = try std.fmt.parseInt(i32, pid_text, 10);
    controller.stop();
    try waitForTest(&controller);
    try std.testing.expectEqual(EndReason.stopped, controller.takeEndEvent().?.reason);
    try std.testing.expectEqual(Phase.exited, controller.snapshot().phase);
    try std.testing.expect(controller.snapshot().failure == null);
    try std.testing.expect(!guard.held);
    try std.testing.expectEqual(@as(usize, 1), guard.released);
    try std.testing.expectEqual(std.os.linux.E.SRCH, std.os.linux.errno(std.os.linux.kill(pid, @fromBackingInt(@intCast(0)))));
}

test "instance launch context is paired bounded absolute and requires a reservation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    const root = path[0..len];
    const request: Request = .{ .version = "fixture", .java_path = "/unused", .java_major = 21, .username = "Player" };
    var unguarded = try Controller.init(std.testing.allocator, std.testing.io, root);
    defer unguarded.deinit();
    try std.testing.expectError(error.IncompleteInstanceContext, unguarded.startWithOptions(request, .{ .instance_id = "instance" }));
    try std.testing.expectError(error.IncompleteInstanceContext, unguarded.startWithOptions(request, .{ .launcher_root = root }));
    try std.testing.expectError(error.MissingLaunchGuard, unguarded.startWithOptions(request, .{ .instance_id = "instance", .launcher_root = root }));
    var guard: TestGuard = .{};
    var controller = try Controller.initWithOptions(std.testing.allocator, std.testing.io, root, .{ .launch_guard = guard.callbacks() });
    defer controller.deinit();
    try std.testing.expectError(error.UnsafeInstanceId, controller.startWithOptions(request, .{ .instance_id = "../instance", .launcher_root = root }));
    try std.testing.expectError(error.UnsafeInstanceId, controller.startWithOptions(request, .{ .instance_id = &(comptime @as([201]u8, @splat('x'))), .launcher_root = root }));
    try std.testing.expectError(error.AbsolutePathRequired, controller.startWithOptions(request, .{ .instance_id = "instance", .launcher_root = "relative" }));
    try std.testing.expectError(error.UnsafePath, controller.startWithOptions(request, .{ .instance_id = "instance", .launcher_root = "/tmp\x00root" }));
    try std.testing.expectError(error.UnsafeDataRoot, controller.startWithOptions(request, .{ .instance_id = "instance", .launcher_root = "/" ++ @as([4096]u8, @splat('x')) }));
    try std.testing.expectEqual(guard.acquired, guard.released);
    try std.testing.expect(!guard.held);
}

test "launch clones stable instance identity and launcher root" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var id = "instance".*;
    var root = "/tmp/launcher".*;
    const options = try cloneOptions(arena.allocator(), .{ .instance_id = &id, .launcher_root = &root });
    @memset(&id, 'x');
    @memset(&root, 'y');
    try std.testing.expectEqualStrings("instance", options.instance_id.?);
    try std.testing.expectEqualStrings("/tmp/launcher", options.launcher_root.?);
}

test "guarded launch blocks pending and malformed journals before probing but accepts valid terminal state" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    const fs = @import("../core/content_fs.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, ".minecraft", .fromMode(0o700));
    var minecraft = try tmp.dir.openDir(io, ".minecraft", .{});
    defer minecraft.close(io);
    try writeFixture(minecraft, 21);
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path);
    const launcher_root = path[0..len];
    const game_root = try std.fs.path.join(a, &.{ launcher_root, ".minecraft" });
    defer a.free(game_root);
    const java_path = try std.fs.path.join(a, &.{ launcher_root, "fake-java" });
    defer a.free(java_path);
    const marker_path = try std.fs.path.join(a, &.{ launcher_root, "java-invocations" });
    defer a.free(marker_path);
    const script = try std.fmt.allocPrint(a, "#!/bin/sh\ncase \"$1\" in -version|-XshowSettings:properties)\n" ++
        "printf 'probe\\n' >> '{s}'; printf 'java.version = 21.0.1\\njava.vendor = Fixture\\nos.arch = {s}\\nopenjdk version \"21.0.1\"\\n' >&2; exit 0;; esac\n" ++
        "printf 'game\\n' >> '{s}'; printf '[INFO] fixture game exited\\n'; exit 0\n", .{ marker_path, @tagName(@import("builtin").cpu.arch), marker_path });
    defer a.free(script);
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-java", .data = script });
    const java_file = try tmp.dir.openFile(io, "fake-java", .{});
    defer java_file.close(io);
    try java_file.setPermissions(io, .fromMode(0o755));

    const txn_id = "txn-" ++ @as([32]u8, @splat('1'));
    const txn_path = "versions/fixture/.vela-content/" ++ txn_id;
    _ = try minecraft.createDirPathStatus(io, txn_path, .fromMode(0o700));
    const txn = try minecraft.openDir(io, txn_path, .{ .iterate = true });
    defer txn.close(io);
    const manifest = @import("../core/content_manifest.zig");
    const manifest_after = try manifest.serialize(a, .{ .instance_id = "instance", .pack_version = "fixture" });
    defer a.free(manifest_after);
    try fs.write(txn, io, "manifest-after", manifest_after);
    const manifest_fingerprint = (try fs.fingerprint(txn, io, "manifest-after", null, null)).?;
    const journal = try std.json.Stringify.valueAlloc(a, .{
        .schema_version = @as(u32, 2),
        .instance_id = "instance",
        .instance_name = "fixture",
        .transaction_id = txn_id,
        .fully_applied = true,
        .kept_local = @as(usize, 0),
        .entries = @as([]const struct {}, &.{}),
        .manifest_before = @as(?fs.Fingerprint, null),
        .manifest_after = manifest_fingerprint,
        .manifest_temp = ".content-" ++ txn_id ++ ".next",
    }, .{});
    defer a.free(journal);
    try txn.writeFile(io, .{ .sub_path = "journal.json", .data = journal });
    var guard: TestGuard = .{};
    var controller = try Controller.initWithOptions(a, io, game_root, .{ .launch_guard = guard.callbacks() });
    defer controller.deinit();
    const request: Request = .{ .version = "fixture", .java_path = java_path, .java_major = 21, .username = "Player" };
    const options: LaunchOptions = .{ .instance_id = "instance", .launcher_root = launcher_root };

    try controller.startWithOptions(request, options);
    try std.testing.expect(guard.held);
    try waitForTest(&controller);
    try std.testing.expectEqual(error.RecoveryRequired, controller.snapshot().failure.?);
    try std.testing.expectEqual(EndReason{ .failed = error.RecoveryRequired }, controller.takeEndEvent().?.reason);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "java-invocations", .{}));
    try std.testing.expectEqual(@as(usize, 1), guard.acquired);
    try std.testing.expectEqual(@as(usize, 1), guard.released);
    try std.testing.expect(!guard.held);
    const still_pending = try txn.readFileAlloc(io, "journal.json", a, .limited(16 * 1024));
    defer a.free(still_pending);
    try std.testing.expectEqualStrings(journal, still_pending);

    try txn.writeFile(io, .{ .sub_path = "committed", .data = "1\n" });
    try controller.startWithOptions(request, options);
    try waitForTest(&controller);
    if (controller.snapshot().failure) |err| std.debug.print("terminal journal launch failed: {s}\n", .{@errorName(err)});
    try std.testing.expectEqual(Phase.exited, controller.snapshot().phase);
    try std.testing.expectEqual(EndReason{ .exited = 0 }, controller.takeEndEvent().?.reason);
    const invocations = try tmp.dir.readFileAlloc(io, "java-invocations", a, .limited(4096));
    defer a.free(invocations);
    try std.testing.expectEqualStrings("probe\ngame\n", invocations);
    try tmp.dir.deleteFile(io, "java-invocations");

    try txn.writeFile(io, .{ .sub_path = "journal.json", .data = "{" });
    try controller.startWithOptions(request, options);
    try waitForTest(&controller);
    try std.testing.expectEqual(error.RecoveryRequired, controller.snapshot().failure.?);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "java-invocations", .{}));
    try std.testing.expect(!guard.held);

    try txn.writeFile(io, .{ .sub_path = "journal.json", .data = journal });
    var wrong_identity = options;
    wrong_identity.instance_id = "different-instance";
    try controller.startWithOptions(request, wrong_identity);
    try waitForTest(&controller);
    try std.testing.expectEqual(error.RecoveryRequired, controller.snapshot().failure.?);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "java-invocations", .{}));
    try std.testing.expectEqual(@as(usize, 4), guard.acquired);
    try std.testing.expectEqual(guard.acquired, guard.released);
    try std.testing.expect(!guard.held);
}

test "path contract Unicode instance launches with fresh legacy natives" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, 21);
    const original = try tmp.dir.readFileAlloc(io, "versions/fixture/fixture.json", a, .limited(64 * 1024));
    defer a.free(original);
    var document = try std.json.parseFromSlice(std.json.Value, a, original, .{});
    defer document.deinit();
    document.value.object.getPtr("id").?.* = .{ .string = "中文实例" };
    const bytes = try std.json.Stringify.valueAlloc(a, document.value, .{});
    defer a.free(bytes);
    try tmp.dir.rename("versions/fixture", tmp.dir, "versions/中文实例", io);
    try tmp.dir.rename("versions/中文实例/fixture.jar", tmp.dir, "versions/中文实例/中文实例.jar", io);
    try tmp.dir.deleteFile(io, "versions/中文实例/fixture.json");
    try tmp.dir.writeFile(io, .{ .sub_path = "versions/中文实例/中文实例.json", .data = bytes });
    try tmp.dir.deleteTree(io, "versions/中文实例/natives");
    try writeFakeJava(tmp.dir, 21, "test -f versions/中文实例/natives/libfixture.so || exit 89");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const java_path = try std.fs.path.join(a, &.{ root, "fake-java" });
    defer a.free(java_path);
    // Exercise the same readiness gate used by installed-list consumers first.
    var canceled: std.atomic.Value(bool) = .init(false);
    var installed = try library.loadInstalled(a, io, root, "中文实例", &canceled);
    defer installed.deinit();
    var controller = try Controller.init(a, io, root);
    defer controller.deinit();
    try controller.start(.{ .version = "中文实例", .java_path = java_path, .java_major = 21, .username = "Player" });
    try waitForTest(&controller);
    try std.testing.expectEqual(Phase.exited, controller.snapshot().phase);
    try std.testing.expectEqual(@as(?u8, 0), controller.snapshot().exit_code);
    const output = try tmp.dir.readFileAlloc(io, "versions/中文实例/natives/libfixture.so", a, .limited(128));
    defer a.free(output);
    const payload = nativePayload(try hostNativeMachine());
    try std.testing.expectEqualSlices(u8, &payload, output);
}

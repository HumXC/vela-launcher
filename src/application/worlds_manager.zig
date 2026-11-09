//! Main-thread owner. Selection/refresh only queue and cancel; tick joins done work.
//! Paths, Registry and WorldScope context outlive deinit, which joins before releasing.
const std = @import("std");
const config = @import("../core/config.zig");
const instances = @import("../core/instances.zig");
const worlds = @import("../core/worlds.zig");
const instance_leases = @import("../core/instance_leases.zig");
const tree = @import("../core/worlds_tree.zig");
const tasks = @import("../core/tasks.zig");
const A = std.mem.Allocator;
const Io = std.Io;

/// File-manager URLs encode raw UTF-8 bytes, never shell arguments.
pub fn fileUri(a: A, absolute_path: []const u8, comptime path_type: std.fs.path.PathType) ![]u8 {
    if (absolute_path.len == 0 or absolute_path.len > std.fs.max_path_bytes or
        std.mem.indexOfScalar(u8, absolute_path, 0) != null or !std.unicode.utf8ValidateSlice(absolute_path)) return error.UnsafePath;
    var host: []const u8 = "";
    const path = try a.dupe(u8, absolute_path);
    defer a.free(path);
    var uri_path: []const u8 = path;
    var drive_path: ?[]u8 = null;
    defer if (drive_path) |v| a.free(v);
    if (path_type == .windows) {
        const parsed = std.fs.path.parsePathWindows(u8, path);
        for (path) |*byte| {
            if (byte.* == '\\') byte.* = '/';
        }
        switch (parsed.kind) {
            .drive_absolute => {
                drive_path = try std.mem.concat(a, u8, &.{ "/", path });
                uri_path = drive_path.?;
            },
            .unc_absolute => {
                const end = 2 + (std.mem.indexOfScalar(u8, path[2..], '/') orelse return error.UnsafePath);
                host = path[2..end];
                if (host.len == 0 or std.mem.eql(u8, host, ".") or std.mem.eql(u8, host, "..")) return error.UnsafePath;
                uri_path = path[end..];
            },
            else => return error.UnsafePath,
        }
    } else if (!std.fs.path.isAbsolutePosix(path)) return error.UnsafePath;
    var parts = std.mem.tokenizeScalar(u8, uri_path, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.UnsafePath;
    const uri: std.Uri = .{ .scheme = "file", .host = .{ .raw = host }, .path = .{ .raw = uri_path } };
    return std.fmt.allocPrint(a, "{f}", .{uri});
}

pub const Preview = struct { folder: []const u8, png: []const u8 };
pub const Snapshot = struct {
    instance: ?config.Instance = null,
    worlds: []const worlds.World = &.{},
    backups: []const worlds.Backup = &.{},
    previews: []const Preview = &.{},
    worker_active: bool = false,
    loading: bool = false,
    failure: ?anyerror = null,
    outcome: ?*const worlds.Outcome = null,
};
const NameChange = struct { folder: []const u8, name: []const u8, confirmed: bool = false };
pub const Request = union(enum) {
    backup: []const u8,
    copy: struct { folder: []const u8, target: config.Instance, target_folder: []const u8, confirmed: bool = false },
    rename_display: NameChange,
    rename_folder: NameChange,
    restore: struct { backup_id: []const u8, part: @FieldType(worlds.BackupRef, "part") = .original, target_folder: []const u8, confirmed: bool = false },
    delete: struct { folder: []const u8, confirmed: bool = false },
};

/// Injectable worker output owns its allocations and is released only after join.
pub const Result = struct {
    world_list: ?worlds.WorldList = null,
    backup_list: ?worlds.BackupList = null,
    previews: []Preview = &.{},
    preview_allocator: ?A = null,
    outcome: ?worlds.Outcome = null,
    pub fn deinit(self: *Result) void {
        if (self.world_list) |*list| list.deinit();
        if (self.backup_list) |*list| list.deinit();
        if (self.preview_allocator) |a| {
            for (self.previews) |preview| {
                a.free(preview.folder);
                a.free(preview.png);
            }
            a.free(self.previews);
        }
        if (self.outcome) |*outcome| outcome.deinit();
        self.* = .{};
    }
};
pub const Worker = *const fn (A, Io, *const instances.Paths, config.Instance, ?Request, worlds.Options) anyerror!Result;
pub const Options = struct {
    guard: worlds.Guard = .{},
    scope: ?worlds.WorldScope = null,
    /// Used exclusively by requestless listing jobs, never by world operations.
    scan_scope: ?worlds.WorldScope = null,
    limits: worlds.Limits = .{},
    worker: Worker = runBackend,
};

fn cloneInstance(a: A, input: config.Instance) !config.Instance {
    var copy = input;
    copy.id = try a.dupe(u8, input.id);
    copy.name = try a.dupe(u8, input.name);
    copy.minecraft_version = try a.dupe(u8, input.minecraft_version);
    if (input.loader_version) |s| copy.loader_version = try a.dupe(u8, s);
    if (input.java_path) |s| copy.java_path = try a.dupe(u8, s);
    if (input.origin) |origin| {
        var owned = origin;
        owned.project_id = try a.dupe(u8, origin.project_id);
        owned.version_id = try a.dupe(u8, origin.version_id);
        copy.origin = owned;
    }
    return copy;
}
fn cloneGuard(a: A, guard: worlds.Guard) !worlds.Guard {
    var copy = guard;
    const ids = try a.alloc([]const u8, guard.running_ids.len);
    for (guard.running_ids, 0..) |id, i| ids[i] = try a.dupe(u8, id);
    copy.running_ids = ids;
    return copy;
}
fn running(guard: worlds.Guard, id: []const u8) bool {
    for (guard.running_ids) |active| if (std.mem.eql(u8, active, id)) return true;
    return false;
}
fn cloneRequest(a: A, request: Request) !Request {
    return switch (request) {
        .backup => |s| .{ .backup = try a.dupe(u8, s) },
        .copy => |v| .{ .copy = .{ .folder = try a.dupe(u8, v.folder), .target = try cloneInstance(a, v.target), .target_folder = try a.dupe(u8, v.target_folder), .confirmed = v.confirmed } },
        .rename_display, .rename_folder => |v| blk: {
            const copy: NameChange = .{ .folder = try a.dupe(u8, v.folder), .name = try a.dupe(u8, v.name), .confirmed = v.confirmed };
            break :blk if (request == .rename_display) .{ .rename_display = copy } else .{ .rename_folder = copy };
        },
        .restore => |v| .{ .restore = .{ .backup_id = try a.dupe(u8, v.backup_id), .part = v.part, .target_folder = try a.dupe(u8, v.target_folder), .confirmed = v.confirmed } },
        .delete => |v| .{ .delete = .{ .folder = try a.dupe(u8, v.folder), .confirmed = v.confirmed } },
    };
}
fn requestFolder(request: Request) []const u8 {
    return switch (request) {
        .backup => |s| s,
        .copy => |v| v.folder,
        .rename_display, .rename_folder => |v| v.folder,
        .restore => |v| v.target_folder,
        .delete => |v| v.folder,
    };
}
fn stage(request: Request) tasks.Stage {
    return switch (request) {
        .copy => .copying,
        .restore => .restoring,
        else => .backing_up,
    };
}
fn taskKind(request: Request) tasks.Kind {
    return switch (request) {
        .copy => .save_copy,
        .restore => .save_restore,
        else => .save_backup,
    };
}
fn title(request: Request) []const u8 {
    return switch (request) {
        .backup => "备份存档",
        .copy => "复制存档",
        .rename_display => "修改存档名称",
        .rename_folder => "重命名存档目录",
        .restore => "恢复存档",
        .delete => "备份并删除存档",
    };
}
fn validate(instance: config.Instance, request: Request) !void {
    if (!config.validId(instance.id) or !config.validId(instance.name)) return error.UnsafeInstance;
    if (!worlds.validFolder(requestFolder(request))) return error.UnsafeWorldName;
    switch (request) {
        .backup => {},
        .copy => |v| {
            if (!config.validId(v.target.id) or !config.validId(v.target.name)) return error.UnsafeInstance;
            if (!worlds.validFolder(v.target_folder)) return error.UnsafeWorldName;
        },
        .rename_display => |v| {
            if (!v.confirmed) return error.ConfirmationRequired;
            if (v.name.len == 0 or v.name.len > 256 or !std.unicode.utf8ValidateSlice(v.name)) return error.InvalidDisplayName;
            var it = std.unicode.Utf8View.initUnchecked(v.name).iterator();
            while (it.nextCodepoint()) |cp| if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return error.InvalidDisplayName;
        },
        .rename_folder => |v| {
            if (!worlds.validFolder(v.name)) return error.UnsafeWorldName;
        },
        .restore => |v| {
            if (!worlds.validRecoveryId(v.backup_id)) return error.UnsafeRecoveryId;
        },
        .delete => |v| if (!v.confirmed) return error.ConfirmationRequired,
    }
}

const Selection = struct {
    allocator: A,
    arena: std.heap.ArenaAllocator,
    instance: config.Instance,
    fn create(a: A, instance: config.Instance) !*Selection {
        const self = try a.create(Selection);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .arena = .init(a), .instance = undefined };
        errdefer self.arena.deinit();
        self.instance = try cloneInstance(self.arena.allocator(), instance);
        return self;
    }
    fn destroy(self: *Selection) void {
        const a = self.allocator;
        self.arena.deinit();
        a.destroy(self);
    }
};
const Job = struct {
    allocator: A,
    arena: std.heap.ArenaAllocator,
    io: Io,
    paths: *const instances.Paths,
    instance: config.Instance,
    request: ?Request,
    options: worlds.Options,
    worker: Worker,
    task: ?*tasks.Task = null,
    cancellation: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    future: ?Io.Future(void) = null,
    result: Result = .{},
    failure: ?anyerror = null,
    fn create(a: A, io: Io, paths: *const instances.Paths, instance: config.Instance, request: ?Request, options: Options) !*Job {
        const self = try a.create(Job);
        errdefer a.destroy(self);
        const scope = if (request == null and options.scan_scope != null) options.scan_scope else options.scope;
        self.* = .{ .allocator = a, .arena = .init(a), .io = io, .paths = paths, .instance = undefined, .request = null, .options = .{ .limits = options.limits, .scope = scope }, .worker = options.worker };
        errdefer self.arena.deinit();
        const owned = self.arena.allocator();
        self.instance = try cloneInstance(owned, instance);
        self.options.guard = try cloneGuard(owned, options.guard);
        if (request) |v| self.request = try cloneRequest(owned, v);
        self.options.hooks = .{ .context = self, .canceled = canceled, .progress = progress };
        return self;
    }
    fn scopeIds(self: *const Job) worlds.ScopeIds {
        const target: ?[]const u8 = if (self.request) |request| switch (request) {
            .copy => |copy| copy.target.id,
            else => null,
        } else null;
        return .{ .source = self.instance.id, .target = target };
    }
    fn acquireScope(self: *Job) !void {
        const entry = if (self.request == null)
            try worlds.enterReadScope(self.options, self.scopeIds())
        else
            try worlds.enterScope(self.options, self.scopeIds());
        self.options.held_scope = entry.held;
        self.options.scope = null;
    }
    fn releaseScope(self: *Job) void {
        if (self.options.held_scope) |held| {
            held.release();
            self.options.held_scope = null;
        }
    }
    fn canceled(context: ?*anyopaque) bool {
        const self: *Job = @ptrCast(@alignCast(context.?));
        return if (self.task) |task| task.canceled() else self.cancellation.load(.acquire);
    }
    fn progress(context: ?*anyopaque, _: usize, bytes: u64) void {
        const self: *Job = @ptrCast(@alignCast(context.?));
        if (self.task) |task| task.report(stage(self.request.?), bytes, null);
    }
    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        // No worker allocation uses the UI allocator or touches main-thread fields.
        self.result = self.worker(std.heap.page_allocator, self.io, self.paths, self.instance, self.request, self.options) catch |err| {
            self.failure = err;
            return;
        };
    }
    fn destroy(self: *Job) void {
        std.debug.assert(self.options.held_scope == null);
        const a = self.allocator;
        self.result.deinit();
        self.arena.deinit();
        a.destroy(self);
    }
};

pub const Manager = struct {
    allocator: A,
    io: Io,
    paths: *const instances.Paths,
    registry: *tasks.Registry,
    options: Options,
    guard_arena: std.heap.ArenaAllocator,
    selected: ?*Selection = null,
    pending: ?*Job = null,
    active: ?*Job = null,
    active_current: bool = false,
    shutting_down: bool = false,
    published: ?*Job = null,
    last_operation: ?*Job = null,
    list_failure: ?anyerror = null,
    operation_failure: ?anyerror = null,

    pub fn init(a: A, io: Io, paths: *const instances.Paths, registry: *tasks.Registry, scope: worlds.WorldScope) !Manager {
        return initOptions(a, io, paths, registry, .{ .scope = scope });
    }
    pub fn initOptions(a: A, io: Io, paths: *const instances.Paths, registry: *tasks.Registry, initial_options: Options) !Manager {
        if (initial_options.guard.is_running != null) return error.UnsupportedWorldGuard;
        if (initial_options.scope == null) return error.MissingWorldScope;
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        var options = initial_options;
        options.guard = try cloneGuard(arena.allocator(), options.guard);
        return .{ .allocator = a, .io = io, .paths = paths, .registry = registry, .options = options, .guard_arena = arena };
    }
    /// Read-only intent: independent of mutation workers and the running-game guard.
    pub fn worldDirectoryUri(self: *Manager, source: config.Instance, folder: []const u8) ![]u8 {
        const selected = self.selected orelse return error.SelectionChanged;
        if (!std.mem.eql(u8, source.id, selected.instance.id) or !std.mem.eql(u8, source.name, selected.instance.name)) return error.SelectionChanged;
        const directory = try worlds.worldDirectory(self.allocator, self.paths, .{ .instance = source, .folder = folder });
        defer self.allocator.free(directory);
        const dir = try tree.openAbsolute(self.io, directory);
        defer dir.close(self.io);
        return fileUri(self.allocator, directory, if (@import("builtin").os.tag == .windows) .windows else .posix);
    }

    /// Shutdown only: cancel and join before task completion or freeing any refs.
    pub fn deinit(self: *Manager) void {
        self.cancelActive();
        if (self.pending) |job| {
            self.cancelTask(job);
            job.destroy();
        }
        if (self.active) |job| {
            if (job.future) |*future| future.await(self.io);
            job.releaseScope();
            self.finishTask(job);
            job.destroy();
        }
        if (self.published) |job| job.destroy();
        if (self.last_operation) |job| job.destroy();
        if (self.selected) |selection| selection.destroy();
        self.guard_arena.deinit();
        self.* = undefined;
    }
    pub fn isRunning(self: *const Manager, instance_id: []const u8) bool {
        if (running(self.options.guard, instance_id)) return true;
        const scope = self.options.scope orelse return false;
        const state = scope.probe(scope.context, .{ .source = instance_id }) catch return false;
        return state == .running;
    }
    pub fn snapshot(self: *const Manager) Snapshot {
        var result: Snapshot = .{
            .instance = if (self.selected) |s| s.instance else null,
            .worker_active = self.active != null or self.pending != null,
            .loading = (self.active != null and self.active.?.request == null) or (self.pending != null and self.pending.?.request == null),
            .failure = self.operation_failure orelse self.list_failure,
        };
        if (self.published) |job| {
            if (job.result.world_list) |list| result.worlds = list.items;
            if (job.result.backup_list) |list| result.backups = list.items;
            result.previews = job.result.previews;
        }
        if (self.last_operation) |job| if (job.result.outcome) |*outcome| {
            result.outcome = outcome;
        };
        return result;
    }
    /// Clone first. Allocation failure leaves prior selection and workers intact.
    pub fn select(self: *Manager, instance: ?config.Instance) !void {
        const next = if (instance) |v| try Selection.create(self.allocator, v) else null;
        errdefer if (next) |s| s.destroy();
        const pending = if (next) |s| try Job.create(self.allocator, self.io, self.paths, s.instance, null, self.options) else null;
        self.cancelActive();
        if (self.pending) |job| {
            self.cancelTask(job);
            job.destroy();
        }
        if (self.selected) |s| s.destroy();
        if (self.published) |job| job.destroy();
        self.selected = next;
        self.pending = pending;
        self.published = null;
        self.active_current = false;
        self.list_failure = null;
    }
    pub fn refresh(self: *Manager) !void {
        const selected = self.selected orelse return error.NoSelectedInstance;
        const pending = try Job.create(self.allocator, self.io, self.paths, selected.instance, null, self.options);
        self.cancelActive();
        if (self.pending) |job| {
            self.cancelTask(job);
            job.destroy();
        }
        self.pending = pending;
        self.active_current = false;
        self.list_failure = null;
    }
    pub fn shutdownOperation(self: *const Manager) ?@import("../core/shutdown.zig").Operation {
        const job = self.active orelse self.pending orelse return null;
        const request = job.request orelse return null;
        return switch (request) {
            .backup => .save_backup,
            .copy => .save_copy,
            .restore => .save_restore,
            else => null,
        };
    }

    pub fn beginShutdown(self: *Manager) void {
        self.shutting_down = true;
        if (self.active) |job| {
            if (job.request == null or self.shutdownOperation() != null) self.cancelTask(job);
        }
        if (self.pending) |job| {
            const cancellable = if (job.request) |request| switch (request) {
                .backup, .copy, .restore => true,
                else => false,
            } else true;
            if (cancellable) {
                self.cancelTask(job);
                job.failure = error.Canceled;
                self.finishTask(job);
                job.destroy();
                self.pending = null;
            }
        }
    }

    pub fn cancel(self: *Manager) void {
        self.cancelActive();
        if (self.pending) |job| {
            self.cancelTask(job);
            job.destroy();
            self.pending = null;
        }
    }
    fn cancelTask(self: *Manager, job: *Job) void {
        if (job.task) |task| {
            _ = self.registry.cancel(task.id);
        }
        job.cancellation.store(true, .release);
    }
    fn cancelActive(self: *Manager) void {
        if (self.active) |job| self.cancelTask(job);
    }
    pub fn perform(self: *Manager, request: Request) !void {
        const selected = self.selected orelse return error.NoSelectedInstance;
        if (self.active != null or self.pending != null) return error.WorldWorkerBusy;
        try validate(selected.instance, request);
        if (self.isRunning(selected.instance.id)) return error.InstanceRunning;
        if (request == .copy and self.isRunning(request.copy.target.id)) return error.InstanceRunning;
        const job = try Job.create(self.allocator, self.io, self.paths, selected.instance, request, self.options);
        errdefer job.destroy();
        const label = try std.fmt.allocPrint(job.arena.allocator(), "{s}: {s}", .{ title(request), requestFolder(request) });
        job.task = try self.registry.create(taskKind(request), label);
        self.pending = job;
        self.operation_failure = null;
    }
    fn finishTask(self: *Manager, job: *Job) void {
        const task = job.task orelse return;
        const outcome: tasks.Outcome = if (job.result.outcome) |result| switch (result.state) {
            .committed => .succeeded,
            .rolled_back => if (result.cause != null and result.cause.? == error.Canceled) .canceled else .{ .failed = result.cause orelse error.WorldOperationRolledBack },
            .uncertain => .{ .failed = result.cause orelse error.WorldOperationUncertain },
        } else if (job.failure != null and job.failure.? == error.Canceled) .canceled else .{ .failed = job.failure orelse error.MissingWorldOutcome };
        self.registry.finish(task, outcome);
    }
    fn sameSelection(self: *const Manager, job: *const Job) bool {
        const selected = self.selected orelse return false;
        return std.mem.eql(u8, selected.instance.id, job.instance.id) and std.mem.eql(u8, selected.instance.name, job.instance.name);
    }
    fn publish(self: *Manager, job: *Job) void {
        self.finishTask(job);
        if (job.request != null) {
            // A late result remains visible even if its source instance was deselected.
            if (self.last_operation) |old| old.destroy();
            self.last_operation = job;
            self.operation_failure = job.failure orelse error.MissingWorldOutcome;
            if (job.result.outcome) |outcome| self.operation_failure = switch (outcome.state) {
                .committed => null,
                .rolled_back => outcome.cause orelse error.WorldOperationRolledBack,
                .uncertain => outcome.cause orelse error.WorldOperationUncertain,
            };
            // Refresh once, never repeat or automatically retry the mutation itself.
            if (!self.shutting_down and self.pending == null and self.sameSelection(job)) self.refresh() catch |err| {
                self.list_failure = err;
            };
        } else if (self.active_current and self.sameSelection(job)) {
            if (self.published) |old| old.destroy();
            self.published = job;
            self.list_failure = job.failure;
        } else job.destroy();
    }
    pub fn tick(self: *Manager) void {
        if (self.active) |job| {
            if (!job.done.load(.acquire)) return;
            if (job.future) |*future| future.await(self.io);
            job.releaseScope();
            self.active = null;
            self.publish(job);
        }
        const job = self.pending orelse return;
        self.active_current = true;
        if (Job.canceled(job)) {
            self.pending = null;
            job.failure = error.Canceled;
            self.publish(job);
            return;
        }
        job.acquireScope() catch |err| {
            // Retry only unread list work. A mutation is never replayed.
            if (job.request == null and err == error.InstanceBusy) return;
            self.pending = null;
            job.failure = err;
            self.publish(job);
            return;
        };
        self.pending = null;
        if (job.task) |task| {
            self.registry.start(task) catch |err| {
                job.releaseScope();
                job.failure = err;
                self.publish(job);
                return;
            };
            task.report(stage(job.request.?), 0, null);
        }
        job.future = self.io.concurrent(Job.run, .{job}) catch |err| {
            job.releaseScope();
            job.failure = err;
            self.publish(job);
            return;
        };
        self.active = job;
    }
};

fn runBackend(a: A, io: Io, paths: *const instances.Paths, instance: config.Instance, request: ?Request, initial_options: worlds.Options) !Result {
    try initial_options.hooks.check(io);
    var options = initial_options;
    if (request) |value| {
        const outcome = switch (value) {
            .backup => |folder| try worlds.backup(a, io, paths, .{ .instance = instance, .folder = folder }, options),
            .copy => |v| blk: {
                options.confirmed_destructive = v.confirmed;
                break :blk try worlds.copy(a, io, paths, .{ .instance = instance, .folder = v.folder }, .{ .instance = v.target, .folder = v.target_folder }, options);
            },
            .rename_display => |v| blk: {
                options.confirmed_destructive = v.confirmed;
                break :blk try worlds.renameDisplayName(a, io, paths, .{ .instance = instance, .folder = v.folder }, v.name, options);
            },
            .rename_folder => |v| blk: {
                options.confirmed_destructive = v.confirmed;
                break :blk try worlds.rename(a, io, paths, .{ .instance = instance, .folder = v.folder }, v.name, options);
            },
            .restore => |v| blk: {
                options.confirmed_destructive = v.confirmed;
                break :blk try worlds.restore(a, io, paths, .{ .instance = instance, .id = v.backup_id, .part = v.part }, .{ .instance = instance, .folder = v.target_folder }, options);
            },
            .delete => |v| blk: {
                options.confirmed_destructive = v.confirmed;
                break :blk try worlds.delete(a, io, paths, .{ .instance = instance, .folder = v.folder }, options);
            },
        };
        return .{ .outcome = outcome };
    }
    const held = options.held_scope orelse return error.MissingWorldScope;
    try held.recheck();
    var result: Result = .{};
    errdefer result.deinit();
    result.world_list = try worlds.list(a, io, paths, instance, null, options);
    result.backup_list = try worlds.listBackups(a, io, paths, instance, options);
    var previews: std.ArrayList(Preview) = .empty;
    errdefer {
        for (previews.items) |p| {
            a.free(p.folder);
            a.free(p.png);
        }
        previews.deinit(a);
    }
    var remaining: usize = 16 * 1024 * 1024;
    for (result.world_list.?.items) |world| {
        try options.hooks.check(io);
        if (world.icon_path == null or previews.items.len >= 64 or remaining == 0) continue;
        var dir = tree.openAbsolute(io, world.directory) catch |err| switch (err) {
            error.Canceled => return err,
            else => continue,
        };
        defer dir.close(io);
        const bytes = tree.readBounded(a, io, dir, "icon.png", @min(remaining, 4 * 1024 * 1024)) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => continue,
        };
        errdefer a.free(bytes);
        const folder = try a.dupe(u8, world.folder);
        errdefer a.free(folder);
        try previews.append(a, .{ .folder = folder, .png = bytes });
        remaining -= bytes.len;
    }
    result.previews = try previews.toOwnedSlice(a);
    result.preview_allocator = a;
    return result;
}

const Fixture = struct {
    entered: std.atomic.Value(bool) = .init(false),
    started: std.atomic.Value(u32) = .init(0),
    exited: std.atomic.Value(u32) = .init(0),
    state: @FieldType(worlds.Outcome, "state") = .committed,
    block_copy: bool = false,
    teardown_coordinator: ?*instance_leases.Coordinator = null,
    teardown_source_blocked: std.atomic.Value(bool) = .init(false),
    teardown_target_blocked: std.atomic.Value(bool) = .init(false),

    fn launchBlocked(coordinator: *instance_leases.Coordinator, id: []const u8) bool {
        coordinator.reserveLaunch(id) catch |err| return err == error.InstanceBusy;
        coordinator.releaseLaunch();
        return false;
    }
    fn work(a: A, io: Io, _: *const instances.Paths, instance: config.Instance, request: ?Request, options: worlds.Options) anyerror!Result {
        const self: *Fixture = @ptrCast(@alignCast(options.guard.context.?));
        _ = self.started.fetchAdd(1, .release);
        const value = request orelse return .{};
        defer {
            if (self.teardown_coordinator) |coordinator| {
                const held = options.held_scope.?;
                self.teardown_source_blocked.store(launchBlocked(coordinator, held.ids.source), .release);
                if (held.ids.target) |target| self.teardown_target_blocked.store(launchBlocked(coordinator, target), .release);
            }
            _ = self.exited.fetchAdd(1, .release);
        }
        try options.hooks.check(io);
        if (!std.mem.eql(u8, instance.id, "source-id") or !std.mem.eql(u8, instance.name, "Source")) return error.BorrowedSelection;
        if ((value == .backup and std.mem.eql(u8, value.backup, "Block")) or (value == .copy and self.block_copy)) {
            self.entered.store(true, .release);
            while (true) {
                try options.hooks.check(io);
                try io.sleep(.fromMilliseconds(1), .awake);
            }
        }
        if (value == .copy and (!std.mem.eql(u8, value.copy.target.id, "destination-id") or !std.mem.eql(u8, value.copy.target.name, "Destination") or !std.mem.eql(u8, value.copy.folder, "World") or !std.mem.eql(u8, value.copy.target_folder, "Copied"))) return error.BorrowedRequest;
        if (options.hooks.progress) |callback| callback(options.hooks.context, 1, 123);
        const id = try a.dupe(u8, "fixture");
        errdefer a.free(id);
        const directory = try a.dupe(u8, "/tmp/fixture-recovery");
        errdefer a.free(directory);
        return .{ .outcome = .{
            .allocator = a,
            .state = self.state,
            .cause = switch (self.state) {
                .committed => null,
                .rolled_back => error.DiskFull,
                .uncertain => error.AccessDenied,
            },
            .recovery_id = id,
            .recovery_directory = directory,
            .staging_directory = if (self.state == .uncertain) try a.dupe(u8, "/tmp/fixture-staging") else null,
        } };
    }
};
const CountingScope = struct {
    inner: worlds.WorldScope,
    acquire_calls: usize = 0,
    acquired: usize = 0,
    releases: usize = 0,

    fn scope(self: *CountingScope) worlds.WorldScope {
        return .{ .context = self, .read_only = self.inner.read_only, .probe = probe, .acquire = acquire, .recheck = recheck, .release = release };
    }
    fn probe(context: ?*anyopaque, ids: worlds.ScopeIds) anyerror!worlds.ScopeState {
        const self: *CountingScope = @ptrCast(@alignCast(context.?));
        return self.inner.probe(self.inner.context, ids);
    }
    fn acquire(context: ?*anyopaque, ids: worlds.ScopeIds) anyerror!worlds.ScopeStamp {
        const self: *CountingScope = @ptrCast(@alignCast(context.?));
        self.acquire_calls += 1;
        const stamp = try self.inner.acquire(self.inner.context, ids);
        self.acquired += 1;
        return stamp;
    }
    fn recheck(context: ?*anyopaque, ids: worlds.ScopeIds, stamp: worlds.ScopeStamp) anyerror!void {
        const self: *CountingScope = @ptrCast(@alignCast(context.?));
        return self.inner.recheck(self.inner.context, ids, stamp);
    }
    fn release(context: ?*anyopaque, ids: worlds.ScopeIds, stamp: worlds.ScopeStamp) void {
        const self: *CountingScope = @ptrCast(@alignCast(context.?));
        self.releases += 1;
        self.inner.release(self.inner.context, ids, stamp);
    }
};
const test_instance: config.Instance = .{ .id = "source-id", .name = "Source", .minecraft_version = "1.21" };
const test_target: config.Instance = .{ .id = "destination-id", .name = "Destination", .minecraft_version = "1.21" };
fn settle(manager: *Manager) !void {
    for (0..5000) |_| {
        manager.tick();
        if (!manager.snapshot().worker_active) return;
        try manager.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.TestWorkerTimedOut;
}
fn waitWorker(manager: *Manager, entered: ?*std.atomic.Value(bool)) !void {
    for (0..5000) |_| {
        if (entered) |value| {
            if (value.load(.acquire)) return;
        } else if (manager.active.?.done.load(.acquire)) return;
        try manager.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.TestWorkerTimedOut;
}

test "queued workers own cloned instance and copy request strings" {
    const a = std.testing.allocator;
    var paths = try instances.Paths.init(a, std.testing.io, ".");
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var coordinator = instance_leases.Coordinator.init(std.testing.io);
    var manager = try Manager.initOptions(a, std.testing.io, &paths, &registry, .{ .scope = coordinator.worldScope(3), .guard = .{ .context = &fixture }, .worker = Fixture.work });
    defer manager.deinit();
    var id = "source-id".*;
    var name = "Source".*;
    var version = "1.21".*;
    var source = test_instance;
    source.id = &id;
    source.name = &name;
    source.minecraft_version = &version;
    try manager.select(source);
    @memset(&id, 'x');
    @memset(&name, 'x');
    @memset(&version, 'x');
    try std.testing.expectEqualStrings("source-id", manager.snapshot().instance.?.id);
    try std.testing.expectEqualStrings("Source", manager.snapshot().instance.?.name);
    try std.testing.expectEqualStrings("1.21", manager.snapshot().instance.?.minecraft_version);
    try settle(&manager);
    var target_id = "destination-id".*;
    var target_name = "Destination".*;
    var folder = "World".*;
    var target_folder = "Copied".*;
    try manager.perform(.{ .copy = .{ .folder = &folder, .target = .{ .id = &target_id, .name = &target_name, .minecraft_version = "1.21" }, .target_folder = &target_folder } });
    const task = registry.tasks()[0];
    try std.testing.expectEqual(tasks.State.queued, task.state);
    @memset(&target_id, 'x');
    @memset(&target_name, 'x');
    @memset(&folder, 'x');
    @memset(&target_folder, 'x');
    try settle(&manager);
    try std.testing.expectEqual(tasks.State.succeeded, task.state);
    try std.testing.expectEqual(@as(u64, 123), task.progress().completed);
    try std.testing.expectEqual(tasks.Stage.copying, task.progress().stage);
}

test "selection refresh and tick never join a live worker and token acknowledges cancellation" {
    const a = std.testing.allocator;
    var paths = try instances.Paths.init(a, std.testing.io, ".");
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var coordinator = instance_leases.Coordinator.init(std.testing.io);
    var manager = try Manager.initOptions(a, std.testing.io, &paths, &registry, .{ .scope = coordinator.worldScope(3), .guard = .{ .context = &fixture }, .worker = Fixture.work });
    var alive = true;
    defer if (alive) manager.deinit();
    try manager.select(test_instance);
    try settle(&manager);
    try manager.perform(.{ .backup = "Block" });
    manager.tick();
    try waitWorker(&manager, &fixture.entered);
    const active = manager.active.?;
    manager.tick();
    try std.testing.expect(manager.active.? == active);
    try manager.refresh();
    try std.testing.expect(manager.active.? == active);
    try std.testing.expect(manager.pending != null);
    try std.testing.expectEqual(tasks.State.canceling, active.task.?.state);
    try std.testing.expect(active.task.?.canceled());
    try manager.select(.{ .id = "next-id", .name = "Next", .minecraft_version = "1.20" });
    try std.testing.expect(manager.active.? == active);
    try settle(&manager);
    try std.testing.expectEqual(tasks.State.canceled, registry.tasks()[0].state);
    try std.testing.expectEqualStrings("next-id", manager.snapshot().instance.?.id);
    try std.testing.expect(manager.snapshot().outcome == null);
    try manager.select(test_instance);
    try settle(&manager);
    fixture.entered.store(false, .release);
    try manager.perform(.{ .backup = "Block" });
    manager.tick();
    try waitWorker(&manager, &fixture.entered);
    const task = registry.tasks()[1];
    try std.testing.expect(registry.cancel(task.id));
    manager.deinit();
    alive = false;
    try std.testing.expectEqual(tasks.State.canceled, task.state);
    try std.testing.expectEqual(@as(u32, 2), fixture.exited.load(.acquire));
    registry.pruneFinished(0);
    try std.testing.expectEqual(@as(usize, 0), registry.tasks().len);
}

test "commit wins late cancellation and rollback uncertainty retain recovery and staging" {
    const a = std.testing.allocator;
    var paths = try instances.Paths.init(a, std.testing.io, ".");
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var coordinator = instance_leases.Coordinator.init(std.testing.io);
    var manager = try Manager.initOptions(a, std.testing.io, &paths, &registry, .{ .scope = coordinator.worldScope(3), .guard = .{ .context = &fixture }, .worker = Fixture.work });
    defer manager.deinit();
    try manager.select(test_instance);
    try settle(&manager);
    try manager.perform(.{ .backup = "World" });
    manager.tick();
    try waitWorker(&manager, null);
    const committed = registry.tasks()[0];
    try std.testing.expect(registry.cancel(committed.id));
    try settle(&manager);
    try std.testing.expectEqual(tasks.State.succeeded, committed.state);
    fixture.state = .rolled_back;
    try manager.perform(.{ .backup = "World" });
    try settle(&manager);
    try std.testing.expectEqual(tasks.State.failed, registry.tasks()[1].state);
    try std.testing.expectEqual(error.DiskFull, registry.tasks()[1].failure.?);
    try std.testing.expectEqual(@FieldType(worlds.Outcome, "state").rolled_back, manager.snapshot().outcome.?.state);
    fixture.state = .uncertain;
    try manager.perform(.{ .backup = "World" });
    try settle(&manager);
    try std.testing.expectEqual(error.AccessDenied, manager.snapshot().failure.?);
    try std.testing.expectEqualStrings("/tmp/fixture-recovery", manager.snapshot().outcome.?.recovery_directory);
    try std.testing.expectEqualStrings("/tmp/fixture-staging", manager.snapshot().outcome.?.staging_directory.?);
    try manager.refresh();
    try settle(&manager);
    try std.testing.expectEqual(@FieldType(worlds.Outcome, "state").uncertain, manager.snapshot().outcome.?.state);
    try manager.select(.{ .id = "other", .name = "Other", .minecraft_version = "1.21", .loader = .vanilla });
    try settle(&manager);
    try std.testing.expectEqualStrings("/tmp/fixture-staging", manager.snapshot().outcome.?.staging_directory.?);
    try std.testing.expectEqual(error.AccessDenied, manager.snapshot().failure.?);
    try manager.select(test_instance);
    try settle(&manager);
    try manager.perform(.{ .backup = "World" });
    manager.tick();
    try waitWorker(&manager, null);
    try manager.select(null);
    try settle(&manager);
    try std.testing.expect(manager.snapshot().instance == null);
    try std.testing.expectEqual(@FieldType(worlds.Outcome, "state").uncertain, manager.snapshot().outcome.?.state);
    try std.testing.expectEqualStrings("/tmp/fixture-recovery", manager.snapshot().outcome.?.recovery_directory);
    try std.testing.expectEqualStrings("/tmp/fixture-staging", manager.snapshot().outcome.?.staging_directory.?);
    try std.testing.expectEqual(@as(u32, 4), fixture.exited.load(.acquire));
}

test "consent queued cancellation and running guard use exact owned config IDs" {
    const a = std.testing.allocator;
    var paths = try instances.Paths.init(a, std.testing.io, ".");
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var blocked = "destination-id".*;
    var coordinator = instance_leases.Coordinator.init(std.testing.io);
    var manager = try Manager.initOptions(a, std.testing.io, &paths, &registry, .{ .scope = coordinator.worldScope(3), .guard = .{ .context = &fixture, .running_ids = &.{&blocked} }, .worker = Fixture.work });
    defer manager.deinit();
    @memset(&blocked, 'x');
    try std.testing.expect(manager.isRunning("destination-id"));
    try std.testing.expect(!manager.isRunning("Destination"));
    try std.testing.expectError(error.NoSelectedInstance, manager.perform(.{ .backup = "World" }));
    try manager.select(test_instance);
    try std.testing.expectError(error.WorldWorkerBusy, manager.perform(.{ .backup = "World" }));
    try settle(&manager);
    try std.testing.expectError(error.ConfirmationRequired, manager.perform(.{ .delete = .{ .folder = "World" } }));
    try std.testing.expectError(error.ConfirmationRequired, manager.perform(.{ .rename_display = .{ .folder = "World", .name = "New" } }));
    try std.testing.expectError(error.UnsafeWorldName, manager.perform(.{ .backup = "../escape" }));
    const target: config.Instance = .{ .id = "destination-id", .name = "Destination", .minecraft_version = "1.21" };
    try std.testing.expectError(error.InstanceRunning, manager.perform(.{ .copy = .{ .folder = "World", .target = target, .target_folder = "Copied" } }));
    try manager.perform(.{ .backup = "World" });
    const task = registry.tasks()[0];
    try std.testing.expect(registry.cancel(task.id));
    try settle(&manager);
    try std.testing.expectEqual(tasks.State.canceled, task.state);
    try std.testing.expectEqual(@as(u32, 0), fixture.exited.load(.acquire));
}
fn allocationScenario(a: A) !void {
    var paths = try instances.Paths.init(a, std.testing.io, ".");
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var coordinator = instance_leases.Coordinator.init(std.testing.io);
    var manager = try Manager.initOptions(a, std.testing.io, &paths, &registry, .{ .scope = coordinator.worldScope(3), .guard = .{ .context = &fixture, .running_ids = &.{"another-id"} }, .worker = Fixture.work });
    defer manager.deinit();
    try manager.select(test_instance);
    manager.select(.{ .id = "next-id", .name = "Next", .minecraft_version = "1.20" }) catch |err| {
        try std.testing.expectEqualStrings("source-id", manager.snapshot().instance.?.id);
        try std.testing.expect(manager.pending != null);
        return err;
    };
    manager.cancel();
    try manager.perform(.{ .backup = "World" });
}
test "selection request and title allocation failure rolls back owned resources" {
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}
test "actual temporary world backup refreshes real recovery listing" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    var paths = try instances.Paths.init(a, io, buf[0..len]);
    defer paths.deinit();
    try tmp.dir.createDirPath(io, ".minecraft/versions/Source/saves/World/region");
    const file = try tmp.dir.createFile(io, ".minecraft/versions/Source/saves/World/region/data", .{});
    try file.writePositionalAll(io, "temporary world payload", 0);
    file.close(io);
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var coordinator = instance_leases.Coordinator.init(io);
    var manager = try Manager.init(a, io, &paths, &registry, coordinator.worldScope(3));
    defer manager.deinit();
    try manager.select(test_instance);
    try settle(&manager);
    try std.testing.expectEqual(@as(usize, 1), manager.snapshot().worlds.len);
    try manager.perform(.{ .backup = "World" });
    try settle(&manager);
    const outcome = manager.snapshot().outcome orelse return error.MissingWorldOutcome;
    if (@import("builtin").os.tag == .linux) try std.testing.expectEqual(@FieldType(worlds.Outcome, "state").committed, outcome.state);
    try std.testing.expect(outcome.recovery_directory.len > 0);
    try std.testing.expectEqual(@as(usize, 1), manager.snapshot().backups.len);
    try std.testing.expectEqualStrings(outcome.recovery_id, manager.snapshot().backups[0].id);
    try std.testing.expectEqual(@as(usize, 1), manager.snapshot().worlds.len);
}
test "world directory file URIs preserve portable path bytes" {
    const Case = struct { path: []const u8, expected: []const u8 };
    const posix = [_]Case{
        .{ .path = "/tmp/World name/#100%?.zip", .expected = "file:///tmp/World%20name/%23100%25%3F.zip" },
        .{ .path = "/tmp/世界", .expected = "file:///tmp/%E4%B8%96%E7%95%8C" },
        .{ .path = "/tmp/back\\slash", .expected = "file:///tmp/back%5Cslash" },
    };
    for (posix) |case| {
        const uri = try fileUri(std.testing.allocator, case.path, .posix);
        defer std.testing.allocator.free(uri);
        try std.testing.expectEqualStrings(case.expected, uri);
    }
    const windows = [_]Case{
        .{ .path = "C:\\Users\\World name\\世界", .expected = "file:///C:/Users/World%20name/%E4%B8%96%E7%95%8C" },
        .{ .path = "D:/Games/100%#?", .expected = "file:///D:/Games/100%25%23%3F" },
        .{ .path = "\\\\server\\share\\World name", .expected = "file://server/share/World%20name" },
        .{ .path = "//server/share/世界", .expected = "file://server/share/%E4%B8%96%E7%95%8C" },
    };
    for (windows) |case| {
        const uri = try fileUri(std.testing.allocator, case.path, .windows);
        defer std.testing.allocator.free(uri);
        try std.testing.expectEqualStrings(case.expected, uri);
    }
    for ([_][]const u8{ "", "relative", "/tmp/../escape", "/tmp/./world", "/tmp/\x00world", "/tmp/\xff" }) |path|
        try std.testing.expectError(error.UnsafePath, fileUri(std.testing.allocator, path, .posix));
    for ([_][]const u8{ "C:relative", "\\rooted", "\\\\?\\C:\\world", "\\\\.\\device" }) |path|
        try std.testing.expectError(error.UnsafePath, fileUri(std.testing.allocator, path, .windows));
}

test "world directory validation is read only and rejects stale selection and symlinks" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".minecraft/versions/One/saves/World name");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    var paths = try instances.Paths.init(a, io, buf[0..len]);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    const source: config.Instance = .{ .id = "one", .name = "One", .minecraft_version = "1.21" };
    var coordinator = instance_leases.Coordinator.init(io);
    var manager = try Manager.initOptions(a, io, &paths, &registry, .{ .scope = coordinator.worldScope(3), .guard = .{ .running_ids = &.{"one"} } });
    defer manager.deinit();
    try manager.select(source);
    try std.testing.expect(manager.isRunning(source.id));
    const uri = try manager.worldDirectoryUri(source, "World name");
    defer a.free(uri);
    try std.testing.expect(std.mem.endsWith(u8, uri, "/.minecraft/versions/One/saves/World%20name"));
    try std.testing.expectEqual(@as(usize, 0), registry.tasks().len);
    try std.testing.expectError(error.UnsafeWorldName, manager.worldDirectoryUri(source, "../escape"));
    try std.testing.expectError(error.FileNotFound, manager.worldDirectoryUri(source, "missing"));
    var renamed = source;
    renamed.name = "Other";
    try std.testing.expectError(error.SelectionChanged, manager.worldDirectoryUri(renamed, "World name"));
    var unsafe = source;
    unsafe.id = "../unsafe";
    try manager.select(unsafe);
    try std.testing.expectError(error.UnsafeInstance, manager.worldDirectoryUri(unsafe, "World name"));
    try manager.select(null);
    try std.testing.expectError(error.SelectionChanged, manager.worldDirectoryUri(source, "World name"));
    try manager.select(source);
    if (@import("builtin").os.tag != .windows) {
        try tmp.dir.symLink(io, "World name", ".minecraft/versions/One/saves/link", .{});
        if (manager.worldDirectoryUri(source, "link")) |opened| {
            a.free(opened);
            return error.SymlinkAccepted;
        } else |_| {}
        try tmp.dir.symLink(io, "One", ".minecraft/versions/Alias", .{});
        var alias = source;
        alias.name = "Alias";
        try manager.select(alias);
        if (manager.worldDirectoryUri(alias, "World name")) |opened| {
            a.free(opened);
            return error.SymlinkAccepted;
        } else |_| {}
    }
}

test "manager uses read-only scope for scans and mutation scope for operations" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".minecraft/versions/One/saves/World");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    var paths = try instances.Paths.init(a, io, buf[0..len]);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var coordinator = instance_leases.Coordinator.init(io);
    var mutation: CountingScope = .{ .inner = coordinator.worldScope(3) };
    var read: CountingScope = .{ .inner = coordinator.worldReadScope(3) };
    var manager = try Manager.initOptions(a, io, &paths, &registry, .{ .scope = mutation.scope(), .scan_scope = read.scope(), .guard = .{ .running_ids = &.{"one"} } });
    defer manager.deinit();
    const source: config.Instance = .{ .id = "one", .name = "One", .minecraft_version = "1.21" };
    try coordinator.reserveLaunch(source.id);
    try manager.select(source);
    try settle(&manager);
    try std.testing.expectEqual(@as(?anyerror, null), manager.snapshot().failure);
    try std.testing.expectEqual(@as(usize, 1), manager.snapshot().worlds.len);
    try std.testing.expectEqual(worlds.WorldAccess.available, manager.snapshot().worlds[0].access);
    try std.testing.expectEqual(@as(usize, 1), read.acquired);
    try std.testing.expectEqual(@as(usize, 1), read.releases);
    try std.testing.expectEqual(@as(usize, 0), mutation.acquired);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".minecraft/versions/One/saves/World/session.lock", .{}));
    try std.testing.expect(manager.isRunning(source.id));
    try std.testing.expectError(error.InstanceRunning, manager.perform(.{ .backup = "World" }));
    coordinator.releaseLaunch();
    manager.options.guard.running_ids = &.{};
    try manager.perform(.{ .backup = "World" });
    try settle(&manager);
    try std.testing.expect(manager.snapshot().outcome.?.state == .committed);
    try std.testing.expectEqual(@as(usize, 1), mutation.acquired);
    try std.testing.expectEqual(@as(usize, 1), mutation.releases);
    try std.testing.expectEqual(@as(usize, 2), read.acquired);
    try std.testing.expectEqual(@as(usize, 2), read.releases);
}

test "manager requires scope and rejects dynamic guards before allocation" {
    const a = std.testing.allocator;
    var paths = try instances.Paths.init(a, std.testing.io, ".");
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var coordinator = instance_leases.Coordinator.init(std.testing.io);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.MissingWorldScope, Manager.initOptions(failing.allocator(), std.testing.io, &paths, &registry, .{ .guard = .{ .context = &fixture }, .worker = Fixture.work }));
    const DynamicGuard = struct {
        fn running(_: ?*anyopaque, _: []const u8) bool {
            return false;
        }
    };
    try std.testing.expectError(error.UnsupportedWorldGuard, Manager.initOptions(failing.allocator(), std.testing.io, &paths, &registry, .{ .scope = coordinator.worldScope(3), .guard = .{ .context = &fixture, .is_running = DynamicGuard.running }, .worker = Fixture.work }));
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
}

test "shutdown cancels queued backups but completes submitted world renames without refresh" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |backup| {
        var paths = try instances.Paths.init(a, std.testing.io, ".");
        defer paths.deinit();
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var fixture: Fixture = .{};
        var coordinator = instance_leases.Coordinator.init(std.testing.io);
        var manager = try Manager.initOptions(a, std.testing.io, &paths, &registry, .{ .scope = coordinator.worldScope(3), .guard = .{ .context = &fixture }, .worker = Fixture.work });
        defer manager.deinit();
        try manager.select(test_instance);
        try settle(&manager);
        try manager.perform(if (backup) .{ .backup = "World" } else .{ .rename_display = .{ .folder = "World", .name = "New name", .confirmed = true } });
        try std.testing.expectEqual(backup, manager.shutdownOperation() != null);
        manager.beginShutdown();
        manager.beginShutdown();
        try settle(&manager);
        try std.testing.expect(!registry.hasActive());
        try std.testing.expect(!manager.snapshot().worker_active);
        try std.testing.expectEqual(@as(u32, if (backup) 1 else 2), fixture.started.load(.acquire));
        try std.testing.expectEqual(if (backup) tasks.State.canceled else tasks.State.succeeded, registry.tasks()[0].state);
    }
}

test "busy world list waits for content mutation release then succeeds" {
    const a = std.testing.allocator;
    var paths = try instances.Paths.init(a, std.testing.io, ".");
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var coordinator = instance_leases.Coordinator.init(std.testing.io);
    const content = coordinator.mutation(1);
    try content.acquire(test_instance.id);
    defer content.release(test_instance.id);
    var manager = try Manager.initOptions(a, std.testing.io, &paths, &registry, .{ .scope = coordinator.worldScope(3), .guard = .{ .context = &fixture }, .worker = Fixture.work });
    defer manager.deinit();
    try manager.select(test_instance);
    const pending = manager.pending.?;
    for (0..4) |_| {
        manager.tick();
        try std.testing.expect(manager.pending.? == pending);
        try std.testing.expect(manager.active == null);
        try std.testing.expect(manager.snapshot().loading);
        try std.testing.expect(manager.snapshot().failure == null);
        try std.testing.expectEqual(@as(u32, 0), fixture.started.load(.acquire));
    }
    content.release(test_instance.id);
    coordinator.tick();
    try settle(&manager);
    try std.testing.expect(!manager.snapshot().loading);
    try std.testing.expect(manager.snapshot().failure == null);
    try std.testing.expectEqual(@as(u32, 1), fixture.started.load(.acquire));
}

test "matching launch makes world list terminal until explicit refresh" {
    const a = std.testing.allocator;
    var paths = try instances.Paths.init(a, std.testing.io, ".");
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var coordinator = instance_leases.Coordinator.init(std.testing.io);
    try coordinator.reserveLaunch(test_instance.id);
    defer coordinator.releaseLaunch();
    var manager = try Manager.initOptions(a, std.testing.io, &paths, &registry, .{ .scope = coordinator.worldScope(3), .guard = .{ .context = &fixture }, .worker = Fixture.work });
    defer manager.deinit();
    try manager.select(test_instance);
    manager.tick();
    try std.testing.expect(manager.pending == null);
    try std.testing.expect(manager.active == null);
    try std.testing.expect(!manager.snapshot().loading);
    try std.testing.expectEqual(error.InstanceRunning, manager.snapshot().failure.?);
    try std.testing.expectEqual(@as(u32, 0), fixture.started.load(.acquire));
    coordinator.releaseLaunch();
    coordinator.tick();
    for (0..4) |_| manager.tick();
    try std.testing.expect(manager.pending == null);
    try std.testing.expectEqual(error.InstanceRunning, manager.snapshot().failure.?);
    try std.testing.expectEqual(@as(u32, 0), fixture.started.load(.acquire));
    try manager.refresh();
    try settle(&manager);
    try std.testing.expect(manager.snapshot().failure == null);
    try std.testing.expectEqual(@as(u32, 1), fixture.started.load(.acquire));
}

test "busy source or target mutation is terminal without spawn or replay" {
    const a = std.testing.allocator;
    for ([_][]const u8{ test_instance.id, test_target.id }) |blocked_id| {
        var paths = try instances.Paths.init(a, std.testing.io, ".");
        defer paths.deinit();
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var fixture: Fixture = .{};
        var coordinator = instance_leases.Coordinator.init(std.testing.io);
        var manager = try Manager.initOptions(a, std.testing.io, &paths, &registry, .{ .scope = coordinator.worldScope(3), .guard = .{ .context = &fixture }, .worker = Fixture.work });
        defer manager.deinit();
        try manager.select(test_instance);
        try settle(&manager);
        const content = coordinator.mutation(1);
        try content.acquire(blocked_id);
        defer content.release(blocked_id);
        try manager.perform(.{ .copy = .{ .folder = "World", .target = test_target, .target_folder = "Copied" } });
        const task = registry.tasks()[0];
        manager.tick();
        try std.testing.expect(manager.active == null);
        try std.testing.expectEqual(tasks.State.failed, task.state);
        try std.testing.expectEqual(error.InstanceBusy, task.failure.?);
        try std.testing.expectEqual(error.InstanceBusy, manager.snapshot().failure.?);
        try std.testing.expectEqual(@as(u32, 1), fixture.started.load(.acquire));
        try std.testing.expectEqual(@as(u32, 0), fixture.exited.load(.acquire));
        // Only the read-only refresh may remain queued after terminal failure.
        try std.testing.expect(manager.pending.?.request == null);
        for (0..4) |_| manager.tick();
        try std.testing.expectEqual(@as(u32, 0), fixture.exited.load(.acquire));
        try std.testing.expectEqual(@as(usize, 1), registry.tasks().len);
        content.release(blocked_id);
        coordinator.tick();
        try settle(&manager);
        for (0..4) |_| manager.tick();
        try std.testing.expect(manager.pending == null);
        try std.testing.expect(manager.active == null);
        try std.testing.expectEqual(@as(u32, 2), fixture.started.load(.acquire));
        try std.testing.expectEqual(@as(u32, 0), fixture.exited.load(.acquire));
        try std.testing.expectEqual(@as(usize, 1), registry.tasks().len);
        try std.testing.expectEqual(tasks.State.failed, task.state);
        try std.testing.expectEqual(error.InstanceBusy, task.failure.?);
    }
}

test "cancellation retains source and target scope through worker teardown and join" {
    const a = std.testing.allocator;
    var paths = try instances.Paths.init(a, std.testing.io, ".");
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var coordinator = instance_leases.Coordinator.init(std.testing.io);
    var counted: CountingScope = .{ .inner = coordinator.worldScope(3) };
    var fixture: Fixture = .{ .block_copy = true, .teardown_coordinator = &coordinator };
    var manager = try Manager.initOptions(a, std.testing.io, &paths, &registry, .{ .scope = counted.scope(), .guard = .{ .context = &fixture }, .worker = Fixture.work });
    defer manager.deinit();
    try manager.select(test_instance);
    try settle(&manager);
    try std.testing.expectEqual(@as(usize, 1), counted.acquired);
    try std.testing.expectEqual(@as(usize, 1), counted.releases);
    try manager.perform(.{ .copy = .{ .folder = "World", .target = test_target, .target_folder = "Copied" } });
    manager.tick();
    try waitWorker(&manager, &fixture.entered);
    const task = registry.tasks()[0];
    try std.testing.expectEqual(@as(usize, 2), counted.acquired);
    try std.testing.expectEqual(@as(usize, 1), counted.releases);
    try std.testing.expectError(error.InstanceBusy, coordinator.reserveLaunch(test_instance.id));
    try std.testing.expectError(error.InstanceBusy, coordinator.reserveLaunch(test_target.id));
    // Deselecting cancels the copy and avoids starting a list after its join.
    try manager.select(null);
    try waitWorker(&manager, null);
    try std.testing.expect(fixture.teardown_source_blocked.load(.acquire));
    try std.testing.expect(fixture.teardown_target_blocked.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), fixture.exited.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), counted.releases);
    try std.testing.expect(manager.active.?.options.held_scope != null);
    try std.testing.expectEqual(tasks.State.canceling, task.state);
    try std.testing.expectError(error.InstanceBusy, coordinator.reserveLaunch(test_instance.id));
    try std.testing.expectError(error.InstanceBusy, coordinator.reserveLaunch(test_target.id));
    manager.tick();
    try std.testing.expect(manager.active == null);
    try std.testing.expect(manager.pending == null);
    try std.testing.expectEqual(tasks.State.canceled, task.state);
    try std.testing.expectEqual(@as(usize, 2), counted.releases);
    coordinator.tick();
    try coordinator.reserveLaunch(test_instance.id);
    coordinator.releaseLaunch();
    coordinator.tick();
    try coordinator.reserveLaunch(test_target.id);
    coordinator.releaseLaunch();
    coordinator.tick();
    for (0..4) |_| manager.tick();
    try std.testing.expectEqual(@as(usize, 2), counted.releases);
}

test "concurrent spawn failure starts no worker and releases scope exactly once" {
    const FailConcurrent = struct {
        fn concurrent(_: ?*anyopaque, _: usize, _: std.mem.Alignment, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque, *anyopaque) void) Io.ConcurrentError!*Io.AnyFuture {
            return error.ConcurrencyUnavailable;
        }
    };
    const a = std.testing.allocator;
    var vtable = std.testing.io.vtable.*;
    vtable.concurrent = FailConcurrent.concurrent;
    const io: Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    var paths = try instances.Paths.init(a, io, ".");
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var coordinator = instance_leases.Coordinator.init(io);
    var counted: CountingScope = .{ .inner = coordinator.worldScope(3) };
    var manager = try Manager.initOptions(a, io, &paths, &registry, .{ .scope = counted.scope(), .guard = .{ .context = &fixture }, .worker = Fixture.work });
    var alive = true;
    defer if (alive) manager.deinit();
    try manager.select(test_instance);
    manager.cancel();
    try manager.perform(.{ .copy = .{ .folder = "World", .target = test_target, .target_folder = "Copied" } });
    const task = registry.tasks()[0];
    manager.tick();
    try std.testing.expect(manager.active == null);
    try std.testing.expectEqual(tasks.State.failed, task.state);
    try std.testing.expectEqual(error.ConcurrencyUnavailable, task.failure.?);
    try std.testing.expectEqual(error.ConcurrencyUnavailable, manager.snapshot().failure.?);
    try std.testing.expectEqual(@as(u32, 0), fixture.started.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), fixture.exited.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), counted.acquire_calls);
    try std.testing.expectEqual(@as(usize, 1), counted.acquired);
    try std.testing.expectEqual(@as(usize, 1), counted.releases);
    // Discard the failed operation's list refresh before checking replay.
    manager.cancel();
    for (0..4) |_| manager.tick();
    coordinator.tick();
    try coordinator.reserveLaunch(test_instance.id);
    coordinator.releaseLaunch();
    coordinator.tick();
    try coordinator.reserveLaunch(test_target.id);
    coordinator.releaseLaunch();
    coordinator.tick();
    manager.deinit();
    alive = false;
    try std.testing.expectEqual(@as(usize, 1), counted.acquire_calls);
    try std.testing.expectEqual(@as(usize, 1), counted.releases);
    try std.testing.expectEqual(@as(u32, 0), fixture.started.load(.acquire));
}

test {
    std.testing.refAllDecls(@This());
}

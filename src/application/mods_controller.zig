//! UI-thread inventory owner; local mod toggles publish one renamed entry.
const std = @import("std");
const local = @import("../core/local_content.zig");
const config = @import("../core/config.zig");
const paths_module = @import("../core/instances.zig");
const content = @import("content_manager.zig");
const presentation = @import("mods_snapshot.zig");
const logicalPath = @import("mods_logical_path.zig").logicalPath;
const A = std.mem.Allocator;
const Io = std.Io;
const worker_allocator = std.heap.page_allocator;

const Job = struct {
    io: Io,
    directory: []u8,
    kind: local.Kind,
    generation: u64,
    thread: ?std.Thread = null,
    canceled: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    result: ?local.Snapshot = null,
    failure: ?anyerror = null,
    fn run(self: *Job) void {
        self.result = local.scan(worker_allocator, self.io, self.directory, .{ .kind = self.kind, .cancel = &self.canceled }) catch |err| result: {
            self.failure = err;
            break :result null;
        };
        self.done.store(true, .release);
    }
    fn destroy(self: *Job) void {
        if (self.thread) |thread| thread.join();
        if (self.result) |*result| result.deinit();
        worker_allocator.free(self.directory);
        worker_allocator.destroy(self);
    }
};

pub const Controller = struct {
    allocator: A,
    io: Io,
    paths: *const paths_module.Paths,
    instance_id: ?[]u8 = null,
    instance_name: ?[]u8 = null,
    directory: ?[]u8 = null,
    kind: local.Kind = .mod,
    generation: u64 = 0,
    inventory_revision: u64 = 0,
    active: ?*Job = null,
    published: ?local.Snapshot = null,
    view_rows: []presentation.Row = &.{},
    view_key: ?ViewKey = null,
    needs_scan: bool = false,
    failure: ?anyerror = null,
    mutation: enum { idle, toggling } = .idle,
    pending_toggle: ?struct { index: usize, enabled: bool, path: []const u8, physical_path: []const u8 } = null,

    const ViewKey = struct { inventory: u64, installed: u64, backend: usize, same: bool };

    pub fn init(a: A, io: Io, paths: *const paths_module.Paths) Controller {
        return .{ .allocator = a, .io = io, .paths = paths };
    }
    pub fn deinit(self: *Controller) void {
        if (self.active) |job| {
            job.canceled.store(true, .release);
            job.destroy();
        }
        self.clearPublished();
        if (self.instance_id) |value| self.allocator.free(value);
        if (self.instance_name) |value| self.allocator.free(value);
        if (self.directory) |value| self.allocator.free(value);
        self.* = undefined;
    }
    fn clearPublished(self: *Controller) void {
        self.allocator.free(self.view_rows);
        self.view_rows = &.{};
        self.view_key = null;
        if (self.published) |*snapshot| snapshot.deinit();
        self.published = null;
        self.inventory_revision +%= 1;
    }
    pub fn matches(self: *const Controller, instance: config.Instance, kind: local.Kind) bool {
        return self.instance_id != null and self.instance_name != null and self.kind == kind and
            std.mem.eql(u8, self.instance_id.?, instance.id) and std.mem.eql(u8, self.instance_name.?, instance.name);
    }
    /// Selection owns all identifiers. A stale worker is canceled and joined only
    /// after done, so instance switching never waits on archive parsing.
    pub fn select(self: *Controller, instance: config.Instance, kind: local.Kind, backend: *content.Manager) !void {
        if (self.matches(instance, kind)) return;
        if (self.mutation != .idle) return error.ContentWorkerBusy;
        const id = try self.allocator.dupe(u8, instance.id);
        errdefer self.allocator.free(id);
        const name = try self.allocator.dupe(u8, instance.name);
        errdefer self.allocator.free(name);
        const directory = try self.paths.instanceDirectory(instance.name);
        defer self.paths.allocator.free(directory);
        const owned_directory = try self.allocator.dupe(u8, directory);
        errdefer self.allocator.free(owned_directory);
        try backend.select(instance);
        if (self.active) |job| job.canceled.store(true, .release);
        self.clearPublished();
        if (self.instance_id) |value| self.allocator.free(value);
        if (self.instance_name) |value| self.allocator.free(value);
        if (self.directory) |value| self.allocator.free(value);
        self.instance_id = id;
        self.instance_name = name;
        self.directory = owned_directory;
        self.kind = kind;
        self.generation +%= 1;
        self.failure = null;
        self.needs_scan = true;
        self.startPending();
    }
    pub fn refresh(self: *Controller) void {
        self.generation +%= 1;
        self.failure = null;
        self.needs_scan = self.directory != null;
        if (self.active) |job| job.canceled.store(true, .release);
        self.startPending();
    }
    fn startPending(self: *Controller) void {
        if (!self.needs_scan or self.active != null or self.directory == null) return;
        self.needs_scan = false;
        const job = worker_allocator.create(Job) catch |err| {
            self.failure = err;
            return;
        };
        const directory = worker_allocator.dupe(u8, self.directory.?) catch |err| {
            worker_allocator.destroy(job);
            self.failure = err;
            return;
        };
        job.* = .{ .io = self.io, .directory = directory, .kind = self.kind, .generation = self.generation };
        job.thread = std.Thread.spawn(.{}, Job.run, .{job}) catch |err| {
            worker_allocator.free(directory);
            worker_allocator.destroy(job);
            self.failure = err;
            return;
        };
        self.active = job;
    }
    pub fn tick(self: *Controller, backend: *content.Manager) void {
        if (self.active) |job| if (job.done.load(.acquire)) {
            if (job.thread) |thread| thread.join();
            job.thread = null;
            self.active = null;
            if (job.generation == self.generation) {
                self.failure = job.failure;
                if (job.result) |result| {
                    self.clearPublished();
                    self.published = result;
                    job.result = null;
                }
            }
            job.destroy();
        };
        self.startPending();
        if (self.mutation == .idle or backend.isBusy()) return;
        const snapshot = backend.snapshot();
        if (snapshot.failure) |err| {
            self.failure = err;
            self.mutation = .idle;
            return;
        }
        defer {
            self.mutation = .idle;
            self.pending_toggle = null;
        }
        if (self.published) |*published| if (self.pending_toggle) |pending| {
            const entry = &@constCast(published.entries)[pending.index];
            entry.enabled = pending.enabled;
            entry.path = pending.path;
            entry.physical_path = pending.physical_path;
            self.inventory_revision +%= 1;
        };
    }
    /// Stop scans without blocking; tick retains ownership until the worker joins.
    pub fn cancel(self: *Controller) void {
        self.needs_scan = false;
        self.generation +%= 1;
        if (self.active) |job| job.canceled.store(true, .release);
    }
    pub fn busy(self: *const Controller) bool {
        return self.active != null or self.needs_scan or self.mutation != .idle;
    }
    /// Borrowed until the next controller mutation or snapshot rebuild. Never free rows.
    pub fn viewSnapshot(self: *Controller, backend: *content.Manager, allow_mutations: bool) !presentation.Snapshot {
        const snapshot = backend.snapshot();
        const same = if (snapshot.instance) |instance| self.instance_id != null and std.mem.eql(u8, self.instance_id.?, instance.id) else false;
        const entries = if (self.published) |published| published.entries else &.{};
        const key: ViewKey = .{ .inventory = self.inventory_revision, .installed = snapshot.installed_revision, .backend = @intFromPtr(backend), .same = same };
        if (self.view_key == null or !std.meta.eql(self.view_key.?, key)) {
            self.view_key = null;
            self.allocator.free(self.view_rows);
            self.view_rows = &.{};
            const rows = try self.allocator.alloc(presentation.Row, entries.len);
            errdefer self.allocator.free(rows);
            // Borrowed manifest keys exist only during this rebuild.
            var managed: std.StringHashMapUnmanaged(u2) = .empty;
            defer managed.deinit(self.allocator);
            if (same and entries.len != 0) for (snapshot.installed) |file| {
                const slot = try managed.getOrPut(self.allocator, file.path);
                if (!slot.found_existing) slot.value_ptr.* = 0;
                slot.value_ptr.* |= if (file.enabled) @as(u2, 2) else 1;
            };
            for (entries, rows) |*entry, *row| {
                const states = managed.get(logicalPath(entry)) orelse 0;
                row.* = .{ .entry = entry, .managed = states & (if (entry.enabled) @as(u2, 2) else 1) != 0 };
            }
            self.view_rows = rows;
            self.view_key = key;
        }
        return .{
            .rows = self.view_rows,
            .inventory = .{ .source = @intFromPtr(self), .revision = self.inventory_revision },
            .busy = self.busy() or snapshot.busy,
            .failure = self.failure orelse if (same) snapshot.failure else null,
            .can_mutate = allow_mutations and same and !self.busy() and !snapshot.busy and !snapshot.recovery_required,
            .recovery_required = same and snapshot.recovery_required,
            .truncated = if (self.published) |published| published.truncated else false,
        };
    }
    pub fn toggle(self: *Controller, backend: *content.Manager, path: []const u8, enabled: bool) !void {
        if (self.busy() or backend.isBusy()) return error.ContentWorkerBusy;
        const snapshot = backend.snapshot();
        const selected = snapshot.instance orelse return error.NoSelectedInstance;
        if (self.instance_id == null or !std.mem.eql(u8, self.instance_id.?, selected.id)) return error.StaleContentSelection;
        if (self.kind != .mod) return error.UnsupportedEnabledState;
        var matched: ?*const local.Entry = null;
        if (self.published) |published| for (published.entries) |*entry| if (std.mem.eql(u8, entry.path, path)) {
            matched = entry;
            break;
        };
        const entry = matched orelse return error.StaleContentSelection;
        const published = &self.published.?;
        const a = published.arena.allocator();
        const logical = logicalPath(entry);
        const next_path = if (enabled) try a.dupe(u8, logical) else try std.fmt.allocPrint(a, "{s}.disabled", .{logical});
        const physical = if (entry.enabled) entry.physical_path else entry.physical_path[0 .. entry.physical_path.len - ".disabled".len];
        const next_physical = if (enabled) try a.dupe(u8, physical) else try std.fmt.allocPrint(a, "{s}.disabled", .{physical});
        const index = for (published.entries, 0..) |*candidate, i| {
            if (candidate == entry) break i;
        } else return error.StaleContentSelection;
        try backend.toggleEnabled(entry.path, enabled);
        self.pending_toggle = .{ .index = index, .enabled = enabled, .path = next_path, .physical_path = next_physical };
        self.failure = null;
        self.mutation = .toggling;
    }
};

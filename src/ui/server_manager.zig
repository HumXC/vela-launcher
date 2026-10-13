//! UI-thread owner. Selection callbacks never join running network work.
//! tick joins only done workers; shutdown deinit is the sole blocking join.
const std = @import("std");
const config = @import("../core/config.zig");
const servers = @import("../core/servers.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Snapshot = struct {
    state: servers.State = .idle,
    /// Borrowed only until next manager mutation; strings are manager-owned.
    server: ?config.Server = null,
    status: ?*const servers.OwnedStatus = null,
    failure: ?anyerror = null,
    /// Includes superseded work unwinding even when public state is idle.
    worker_active: bool = false,
};

pub const Query = *const fn (Allocator, Io, config.Server, servers.Options) anyerror!servers.OwnedStatus;

const Job = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    io: Io,
    server: config.Server,
    query: Query,
    options: servers.Options,
    cancellation: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    future: ?Io.Future(void) = null,
    status: ?servers.OwnedStatus = null,
    failure: ?anyerror = null,

    fn create(a: Allocator, io: Io, server: config.Server, query: Query, options: servers.Options) !*Job {
        _ = try servers.validateAddress(server.address, server.port);
        return createOwned(a, io, server, query, options);
    }
    fn createOwned(a: Allocator, io: Io, server: config.Server, query: Query, options: servers.Options) !*Job {
        const job = try a.create(Job);
        errdefer a.destroy(job);
        job.* = .{ .allocator = a, .arena = .init(a), .io = io, .server = server, .query = query, .options = options };
        errdefer job.arena.deinit();
        const owned = job.arena.allocator();
        job.server.id = try owned.dupe(u8, server.id);
        job.server.name = try owned.dupe(u8, server.name);
        job.server.address = try owned.dupe(u8, server.address);
        job.server.instance_id = try owned.dupe(u8, server.instance_id);
        return job;
    }
    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        var options = self.options;
        options.cancellation = &self.cancellation;
        // Invalid picker addresses fail only this card, never its peers or the UI frame.
        _ = servers.validateAddress(self.server.address, self.server.port) catch |err| {
            self.failure = err;
            return;
        };
        // Worker allocations never touch the UI allocator or config store.
        self.status = self.query(std.heap.page_allocator, self.io, self.server, options) catch |err| {
            self.failure = err;
            return;
        };
    }
    fn destroy(self: *Job) void {
        if (self.status) |*status| status.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

pub const Manager = struct {
    allocator: Allocator,
    io: Io,
    options: servers.Options = .{},
    query: Query = servers.query,
    active: ?*Job = null,
    active_current: bool = false,
    pending: ?*Job = null,
    published: ?*Job = null,
    picker: ?*Picker = null,
    picker_poll_interval_ms: u32 = 10_000,
    selected_poll_interval_ms: u32 = 10_000,
    selected_next_poll_ms: i64 = 0,

    pub fn init(a: Allocator, io: Io) Manager {
        return .{ .allocator = a, .io = io };
    }
    /// Injectable for deterministic fixtures; production uses servers.query.
    pub fn initWithQuery(a: Allocator, io: Io, query: Query) Manager {
        return .{ .allocator = a, .io = io, .query = query };
    }
    pub fn deinit(self: *Manager) void {
        if (self.picker) |picker| {
            picker.deinit(self.allocator);
            self.allocator.destroy(picker);
            self.picker = null;
        }
        self.clear();
        if (self.active) |job| {
            job.cancellation.store(true, .release);
            if (job.future) |*future| future.cancel(self.io);
            job.destroy();
        }
        self.* = undefined;
    }
    /// Queue latest selection. Clone failure leaves prior state untouched.
    /// Cancellation normally takes ~10ms; OS resolver responsiveness depends on
    /// the std.Io backend. Neither this call nor clear waits for that resolver.
    pub fn refreshConfigured(self: *Manager, server: config.Server) !void {
        const next = try Job.create(self.allocator, self.io, server, self.query, self.options);
        errdefer next.destroy();
        const current = self.snapshot().server;
        const same_target = if (current) |value| sameQueryTarget(value, server) else false;
        if (!same_target and !self.adoptCached(server)) try self.preserveSelection(server);
        self.replaceJob(next);
    }
    fn refreshPicker(self: *Manager, server: config.Server) !void {
        const next = try Job.createOwned(self.allocator, self.io, server, self.query, self.options);
        self.replaceJob(next);
    }
    fn replaceJob(self: *Manager, next: *Job) void {
        if (self.pending) |job| job.destroy();
        if (self.published) |job| {
            if (!sameQueryTarget(job.server, next.server)) {
                job.destroy();
                self.published = null;
            }
        }
        self.pending = next;
        self.selected_next_poll_ms = nowMilliseconds(self.io) + self.selected_poll_interval_ms;
        if (self.active) |job| job.cancellation.store(true, .release);
        self.active_current = false;
        self.tick();
    }
    /// Immediately hides stale status; old work unwinds in the background.
    pub fn clear(self: *Manager) void {
        if (self.pending) |job| job.destroy();
        if (self.published) |job| job.destroy();
        self.pending = null;
        self.published = null;
        if (self.active) |job| job.cancellation.store(true, .release);
        self.active_current = false;
    }
    pub fn cancel(self: *Manager) void {
        if (self.picker) |picker| picker.leave();
        self.cancelSelected();
    }
    /// Cancel the selected query without discarding unrelated card queries.
    pub fn cancelSelected(self: *Manager) void {
        if (self.pending) |job| {
            job.failure = error.Canceled;
            job.done.store(true, .release);
            if (self.published) |old| old.destroy();
            self.published = job;
            self.pending = null;
        }
        if (self.active) |job| job.cancellation.store(true, .release);
    }
    pub fn tick(self: *Manager) void {
        if (self.picker) |picker| picker.tick(self.allocator);
        if (self.active) |job| {
            if (!job.done.load(.acquire)) return;
            if (job.future) |*future| future.await(self.io);
            self.active = null;
            if (self.active_current) {
                if (self.published) |old| old.destroy();
                self.published = job;
            } else job.destroy();
            self.active_current = false;
        }
        if (self.pending) |job| {
            self.pending = null;
            job.future = self.io.concurrent(Job.run, .{job}) catch |err| {
                job.failure = err;
                job.done.store(true, .release);
                if (self.published) |old| old.destroy();
                self.published = job;
                return;
            };
            self.active = job;
            self.active_current = true;
        }
    }
    pub fn isBusy(self: *const Manager) bool {
        return self.active != null or self.pending != null or if (self.picker) |picker| picker.isBusy() else false;
    }
    /// Select a launch target without restarting an existing query. Picker jobs,
    /// published status and their polling deadline move together between owners.
    pub fn selectConfigured(self: *Manager, server: config.Server) !void {
        const current = self.snapshot().server;
        if (current) |value| if (sameQueryTarget(value, server)) return;
        if (self.adoptCached(server)) return;
        const next = try Job.createOwned(self.allocator, self.io, server, self.query, self.options);
        errdefer next.destroy();
        try self.preserveSelection(server);
        self.replaceJob(next);
    }
    fn adoptCached(self: *Manager, server: config.Server) bool {
        if (self.picker) |picker| {
            for (picker.entries.items) |entry| {
                const cached = entry.snapshot().server orelse continue;
                if (!sameQueryTarget(cached, server)) continue;
                self.swapQueryState(entry);
                return true;
            }
        }
        return false;
    }
    fn preserveSelection(self: *Manager, server: config.Server) !void {
        // Keep the old selected card available when selecting a target that has
        // not been queried yet. Endpoint edits replace only that target's work.
        const current = self.snapshot().server;
        if (self.picker) |picker| if (picker.open) {
            if (current) |value| if (!std.mem.eql(u8, value.id, server.id)) {
                try picker.entries.ensureUnusedCapacity(self.allocator, 1);
                const entry = try self.allocator.create(Manager);
                entry.* = Manager.initWithQuery(self.allocator, self.io, self.query);
                entry.options = self.options;
                self.swapQueryState(entry);
                picker.entries.appendAssumeCapacity(entry);
            };
        };
    }
    fn swapQueryState(self: *Manager, other: *Manager) void {
        std.mem.swap(?*Job, &self.active, &other.active);
        std.mem.swap(bool, &self.active_current, &other.active_current);
        std.mem.swap(?*Job, &self.pending, &other.pending);
        std.mem.swap(?*Job, &self.published, &other.published);
        std.mem.swap(i64, &self.selected_next_poll_ms, &other.selected_next_poll_ms);
    }

    /// Keep the selected launch target fresh independently of page navigation.
    pub fn updateSelected(self: *Manager, document: *const config.Document, enabled: bool) !void {
        if (!enabled) return;
        const id = document.selected_server orelse {
            self.clear();
            return;
        };
        for (document.servers) |server| {
            if (!std.mem.eql(u8, server.id, id)) continue;
            const now = nowMilliseconds(self.io);
            const current = self.snapshot();
            const same_target = if (current.server) |queried| sameQueryTarget(queried, server) else false;
            if (!same_target) {
                try self.selectConfigured(server);
                return;
            }
            if (now < self.selected_next_poll_ms) return;
            // A slow query keeps running; navigation and timers never restart it.
            if (self.active != null or self.pending != null) {
                self.selected_next_poll_ms = now + self.selected_poll_interval_ms;
                return;
            }
            try self.refreshPicker(server);
            return;
        }
        self.clear();
    }
    pub fn selectedRefreshDelay(self: *const Manager) u32 {
        if (self.snapshot().server == null) return self.selected_poll_interval_ms;
        const remaining = @max(0, self.selected_next_poll_ms - nowMilliseconds(self.io));
        return @intCast(@min(remaining, std.math.maxInt(u32)));
    }

    /// Unselected card queries share ownership with the selected launch target.
    pub fn updatePicker(self: *Manager, configured: []const config.Server, visible: bool) !void {
        if (!visible) {
            if (self.picker) |picker| picker.leave();
            return;
        }
        if (self.picker == null) {
            const picker = try self.allocator.create(Picker);
            picker.* = .{};
            self.picker = picker;
        }
        try self.picker.?.update(self, configured);
    }
    pub fn pickerSnapshot(self: *const Manager, id: []const u8) Snapshot {
        const selected = self.snapshot();
        if (selected.server) |server| if (std.mem.eql(u8, server.id, id)) return selected;
        if (self.picker) |picker| for (picker.entries.items) |entry| {
            const value = entry.snapshot();
            if (value.server) |server| if (std.mem.eql(u8, server.id, id)) return value;
        };
        return .{};
    }
    pub fn pickerRefreshDelay(self: *const Manager) u32 {
        const picker = self.picker orelse return self.picker_poll_interval_ms;
        const remaining = @max(0, picker.next_poll_ms - nowMilliseconds(self.io));
        return @intCast(@min(remaining, std.math.maxInt(u32)));
    }
    pub fn snapshot(self: *const Manager) Snapshot {
        // Published data belongs to this same target; keep it visible while a
        // refresh runs and replace it only after the worker has finished.
        if (self.published) |job| return .{
            .state = if (job.status != null) .online else if (job.failure != null and job.failure.? == error.Canceled) .canceled else .offline,
            .server = job.server,
            .status = if (job.status) |*status| status else null,
            .failure = job.failure,
            .worker_active = self.active != null or self.pending != null,
        };
        if (self.pending) |job| return .{ .state = .querying, .server = job.server, .worker_active = true };
        if (self.active_current) {
            if (self.active) |job| return .{ .state = .querying, .server = job.server, .worker_active = true };
        }
        return .{ .worker_active = self.active != null or self.pending != null };
    }
};

fn sameQueryTarget(left: config.Server, right: config.Server) bool {
    return left.port == right.port and
        std.mem.eql(u8, left.id, right.id) and
        std.mem.eql(u8, left.name, right.name) and
        std.mem.eql(u8, left.address, right.address) and
        std.mem.eql(u8, left.instance_id, right.instance_id);
}

fn nowMilliseconds(io: Io) i64 {
    return @intCast(Io.Clock.awake.now(io).toMilliseconds());
}

/// Retired queries unwind without blocking navigation or borrowing config arenas.
const Picker = struct {
    entries: std.ArrayList(*Manager) = .empty,
    retired: std.ArrayList(*Manager) = .empty,
    open: bool = false,
    fingerprint: u64 = 0,
    next_poll_ms: i64 = 0,

    fn configurationFingerprint(configured: []const config.Server, selected: ?config.Server) u64 {
        var hash = std.hash.Wyhash.init(0);
        for (configured) |server| {
            if (selected) |value| if (sameQueryTarget(value, server)) continue;
            for ([_][]const u8{ server.id, server.name, server.address, server.instance_id }) |value| {
                hash.update(std.mem.asBytes(&value.len));
                hash.update(value);
            }
            hash.update(std.mem.asBytes(&server.port));
        }
        return hash.final();
    }
    fn destroyEntry(a: Allocator, entry: *Manager) void {
        entry.deinit();
        a.destroy(entry);
    }
    fn deinit(self: *Picker, a: Allocator) void {
        for (self.entries.items) |entry| destroyEntry(a, entry);
        for (self.retired.items) |entry| destroyEntry(a, entry);
        self.entries.deinit(a);
        self.retired.deinit(a);
    }
    fn update(self: *Picker, owner: *Manager, configured: []const config.Server) !void {
        const now = nowMilliseconds(owner.io);
        const selected = owner.snapshot().server;
        const fingerprint = configurationFingerprint(configured, selected);
        if (!self.open or fingerprint != self.fingerprint) {
            var next: std.ArrayList(*Manager) = .empty;
            errdefer {
                for (next.items) |entry| if (!containsEntry(self.entries.items, entry)) destroyEntry(owner.allocator, entry);
                next.deinit(owner.allocator);
            }
            // Reuse unchanged owners, including the former selected card. Prepare
            // new jobs before mutating the live list so failures preserve its work.
            for (configured) |server| {
                if (selected) |value| if (sameQueryTarget(value, server)) continue;
                var reused: ?*Manager = null;
                for (self.entries.items) |entry| {
                    const queried = entry.snapshot().server orelse continue;
                    if (sameQueryTarget(queried, server)) {
                        reused = entry;
                        break;
                    }
                }
                if (reused) |entry| {
                    try next.append(owner.allocator, entry);
                    continue;
                }
                try next.ensureUnusedCapacity(owner.allocator, 1);
                const entry = try owner.allocator.create(Manager);
                errdefer owner.allocator.destroy(entry);
                entry.* = Manager.initWithQuery(owner.allocator, owner.io, owner.query);
                entry.options = owner.options;
                entry.selected_poll_interval_ms = owner.picker_poll_interval_ms;
                entry.selected_next_poll_ms = now + owner.picker_poll_interval_ms;
                entry.pending = try Job.createOwned(owner.allocator, owner.io, server, owner.query, owner.options);
                next.appendAssumeCapacity(entry);
            }
            try self.retired.ensureUnusedCapacity(owner.allocator, self.entries.items.len);
            for (self.entries.items) |entry| {
                if (containsEntry(next.items, entry)) continue;
                entry.clear();
                self.retired.appendAssumeCapacity(entry);
            }
            self.entries.deinit(owner.allocator);
            self.entries = next;
            self.open = true;
            self.fingerprint = fingerprint;
            self.schedulePoll(now, owner.picker_poll_interval_ms);
            self.tick(owner.allocator);
            return;
        }
        if (now < self.next_poll_ms) return;
        for (self.entries.items) |entry| {
            if (now < entry.selected_next_poll_ms) continue;
            if (entry.isBusy()) {
                entry.selected_next_poll_ms = now + owner.picker_poll_interval_ms;
                continue;
            }
            entry.selected_poll_interval_ms = owner.picker_poll_interval_ms;
            if (entry.snapshot().server) |server| try entry.refreshPicker(server);
        }
        self.schedulePoll(now, owner.picker_poll_interval_ms);
    }
    fn containsEntry(entries: []const *Manager, target: *Manager) bool {
        for (entries) |entry| if (entry == target) return true;
        return false;
    }
    fn schedulePoll(self: *Picker, now: i64, interval_ms: u32) void {
        self.next_poll_ms = now + interval_ms;
        for (self.entries.items) |entry| self.next_poll_ms = @min(self.next_poll_ms, entry.selected_next_poll_ms);
    }
    fn leave(self: *Picker) void {
        if (!self.open) return;
        self.open = false;
        for (self.entries.items) |entry| entry.clear();
    }
    fn tick(self: *Picker, a: Allocator) void {
        for (self.entries.items) |entry| entry.tick();
        var index: usize = 0;
        while (index < self.retired.items.len) {
            const entry = self.retired.items[index];
            entry.tick();
            if (entry.isBusy()) {
                index += 1;
            } else {
                destroyEntry(a, self.retired.swapRemove(index));
            }
        }
    }
    fn isBusy(self: *const Picker) bool {
        for (self.entries.items) |entry| if (entry.isBusy()) return true;
        for (self.retired.items) |entry| if (entry.isBusy()) return true;
        return false;
    }
};

fn fixtureQuery(a: Allocator, io: Io, server: config.Server, options: servers.Options) anyerror!servers.OwnedStatus {
    if (std.mem.eql(u8, server.id, "wait")) {
        while (!options.cancellation.?.load(.acquire)) try io.sleep(.fromMilliseconds(1), .awake);
        return error.Canceled;
    }
    if (std.mem.eql(u8, server.id, "offline")) return error.ConnectionRefused;
    if (!std.mem.eql(u8, server.name, "Original") or !std.mem.eql(u8, server.instance_id, "instance")) return error.BorrowedConfig;
    return servers.parseStatus(a, "{\"version\":{\"name\":\"fixture\",\"protocol\":1},\"description\":\"Owned\"}");
}
fn awaitSettled(manager: *Manager) !void {
    const start = Io.Clock.now(.awake, manager.io);
    while (manager.active != null or manager.pending != null) {
        manager.tick();
        if (start.durationTo(Io.Clock.now(.awake, manager.io)).toMilliseconds() > 2000) return error.FixtureTimeout;
        try manager.io.sleep(.fromMilliseconds(1), .awake);
    }
}
fn fixtureServer(id: []const u8) config.Server {
    return .{ .id = id, .name = "Original", .address = "127.0.0.1", .instance_id = "instance" };
}
test "manager worker clones every config string and owns published status" {
    var manager = Manager.initWithQuery(std.testing.allocator, std.testing.io, fixtureQuery);
    defer manager.deinit();
    var id = [_]u8{ 'o', 'w', 'n', 'e', 'd' };
    var name = [_]u8{ 'O', 'r', 'i', 'g', 'i', 'n', 'a', 'l' };
    var address = [_]u8{ '1', '2', '7', '.', '0', '.', '0', '.', '1' };
    var instance = [_]u8{ 'i', 'n', 's', 't', 'a', 'n', 'c', 'e' };
    try manager.refreshConfigured(.{ .id = &id, .name = &name, .address = &address, .instance_id = &instance });
    @memset(&id, 'x');
    @memset(&name, 'x');
    @memset(&address, 'x');
    @memset(&instance, 'x');
    try awaitSettled(&manager);
    const snapshot = manager.snapshot();
    try std.testing.expectEqual(servers.State.online, snapshot.state);
    try std.testing.expectEqualStrings("owned", snapshot.server.?.id);
    try std.testing.expectEqualStrings("Original", snapshot.server.?.name);
    try std.testing.expectEqualStrings("127.0.0.1", snapshot.server.?.address);
    try std.testing.expectEqualStrings("instance", snapshot.server.?.instance_id);
    try std.testing.expectEqualStrings("Owned", snapshot.status.?.motd);
}
test "manager selection queues latest cancels old and clear exposes idle without join" {
    var manager = Manager.initWithQuery(std.testing.allocator, std.testing.io, fixtureQuery);
    defer manager.deinit();
    try manager.refreshConfigured(fixtureServer("wait"));
    try manager.refreshConfigured(fixtureServer("superseded"));
    try manager.refreshConfigured(fixtureServer("latest"));
    try std.testing.expectEqualStrings("latest", manager.snapshot().server.?.id);
    try std.testing.expectEqual(@as(?*const servers.OwnedStatus, null), manager.snapshot().status);
    try awaitSettled(&manager);
    try std.testing.expectEqualStrings("latest", manager.snapshot().server.?.id);
    try manager.refreshConfigured(fixtureServer("wait"));
    manager.clear();
    try std.testing.expectEqual(servers.State.idle, manager.snapshot().state);
    try std.testing.expectEqual(@as(?config.Server, null), manager.snapshot().server);
    try awaitSettled(&manager);
}
test "manager cancel offline and allocation failure preserve truthful owned state" {
    var manager = Manager.initWithQuery(std.testing.allocator, std.testing.io, fixtureQuery);
    defer manager.deinit();
    try manager.refreshConfigured(fixtureServer("wait"));
    manager.cancel();
    try awaitSettled(&manager);
    try std.testing.expectEqual(servers.State.canceled, manager.snapshot().state);
    try manager.refreshConfigured(fixtureServer("offline"));
    try awaitSettled(&manager);
    try std.testing.expectEqual(error.ConnectionRefused, manager.snapshot().failure.?);
    try std.testing.expectEqual(servers.State.offline, manager.snapshot().state);
    try std.testing.expectError(error.InvalidAddress, manager.refreshConfigured(.{ .id = "bad", .name = "Bad", .address = "http://bad", .instance_id = "instance" }));
    try std.testing.expectEqualStrings("offline", manager.snapshot().server.?.id);
}
fn oomClone(a: Allocator) !void {
    var manager = Manager.initWithQuery(a, std.testing.io, fixtureQuery);
    defer manager.deinit();
    try manager.refreshConfigured(fixtureServer("owned"));
    try awaitSettled(&manager);
}
test "manager allocation failure sweeps and active shutdown join" {
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, oomClone, .{});
    var manager = Manager.initWithQuery(std.testing.allocator, std.testing.io, fixtureQuery);
    try manager.refreshConfigured(fixtureServer("wait"));
    manager.deinit();
}

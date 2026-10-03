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

    pub fn init(a: Allocator, io: Io) Manager {
        return .{ .allocator = a, .io = io };
    }
    /// Injectable for deterministic fixtures; production uses servers.query.
    pub fn initWithQuery(a: Allocator, io: Io, query: Query) Manager {
        return .{ .allocator = a, .io = io, .query = query };
    }
    pub fn deinit(self: *Manager) void {
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
        if (self.pending) |job| job.destroy();
        if (self.published) |job| job.destroy();
        self.published = null;
        self.pending = next;
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
                self.published = job;
                return;
            };
            self.active = job;
            self.active_current = true;
        }
    }
    pub fn isBusy(self: *const Manager) bool {
        return self.active != null or self.pending != null;
    }
    pub fn snapshot(self: *const Manager) Snapshot {
        if (self.pending) |job| return .{ .state = .querying, .server = job.server, .worker_active = true };
        if (self.active_current) {
            if (self.active) |job| return .{ .state = .querying, .server = job.server, .worker_active = true };
        }
        if (self.published) |job| return .{
            .state = if (job.status != null) .online else if (job.failure != null and job.failure.? == error.Canceled) .canceled else .offline,
            .server = job.server,
            .status = if (job.status) |*status| status else null,
            .failure = job.failure,
            .worker_active = self.isBusy(),
        };
        return .{ .worker_active = self.isBusy() };
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
    try std.testing.checkAllAllocationFailures(std.testing.allocator, oomClone, .{});
    var manager = Manager.initWithQuery(std.testing.allocator, std.testing.io, fixtureQuery);
    try manager.refreshConfigured(fixtureServer("wait"));
    manager.deinit();
}

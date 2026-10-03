//! Heapless cross-feature leases. Keep Coordinator at its final address for the
//! lifetime of every controller/worker. Bind mutation contexts on the main thread
//! before publishing them; join a worker before reusing its mutation slot.
//! The gate protects reservation state only, never downloads, games or world APIs.
const std = @import("std");
const config = @import("config.zig");
const worlds = @import("worlds.zig");
const Atomic = std.atomic.Value;
const max_id_bytes = 200;
pub const mutation_slots = 4;

const Reservation = struct {
    id: [max_id_bytes]u8 = undefined,
    len: usize = 0,
    generation: u64 = 0,
    epoch: Atomic(u64) = .init(0),
    pending_release: Atomic(u64) = .init(0),
    published_len: Atomic(usize) = .init(0),
    published_id: [max_id_bytes]Atomic(u8) = @splat(.init(0)),

    fn matches(self: *const Reservation, id: []const u8) bool {
        return self.len != 0 and std.mem.eql(u8, self.id[0..self.len], id);
    }
    fn reserve(self: *Reservation, id: []const u8) !void {
        if (self.generation == std.math.maxInt(u64)) return error.LeaseGenerationExhausted;
        self.generation += 1;
        @memcpy(self.id[0..id.len], id);
        self.len = id.len;
        for (id, 0..) |byte, index| self.published_id[index].store(byte, .release);
        self.published_len.store(id.len, .release);
        self.epoch.store(self.generation, .release);
    }
    fn release(self: *Reservation, id: ?[]const u8) void {
        const epoch = self.epoch.load(.acquire);
        if (epoch == 0) return;
        if (id) |value| {
            if (value.len != self.published_len.load(.acquire)) return;
            for (value, 0..) |byte, index| if (byte != self.published_id[index].load(.acquire)) return;
        }
        if (self.epoch.load(.acquire) != epoch) return;
        // A delayed old release must not overwrite a newer generation's request.
        _ = self.pending_release.fetchMax(epoch, .release);
    }
    fn applyRelease(self: *Reservation) void {
        const epoch = self.epoch.load(.acquire);
        if (epoch == 0 or self.pending_release.load(.acquire) != epoch) return;
        self.epoch.store(0, .release);
        self.len = 0;
    }
};

pub const Coordinator = struct {
    io: std.Io,
    launch: Reservation = .{},
    mutations: [mutation_slots]Mutation = @splat(.{}),
    contexts_bound: bool = false,

    pub fn init(io: std.Io) Coordinator {
        return .{ .io = io };
    }
    /// Call only after this Coordinator has its final address, before workers run.
    pub fn mutation(self: *Coordinator, slot: usize) *Mutation {
        std.debug.assert(slot < mutation_slots);
        if (!self.contexts_bound) {
            for (&self.mutations) |*item| item.owner = self;
            self.contexts_bound = true;
        }
        std.debug.assert(self.mutations[slot].owner == self);
        return &self.mutations[slot];
    }
    pub fn reserveLaunch(self: *Coordinator, id: []const u8) !void {
        if (!config.validId(id)) return error.InvalidInstanceId;
        if (!worlds.transaction_gate.tryLock()) return error.InstanceBusy;
        defer worlds.transaction_gate.unlock(self.io);
        self.drainReleasesLocked();
        if (self.launch.matches(id)) return error.InstanceRunning;
        if (self.launch.len != 0 or self.busy(id, null)) return error.InstanceBusy;
        try self.launch.reserve(id);
    }
    /// Publish only after the launch worker/process has joined. Admission or tick clears it.
    pub fn releaseLaunch(self: *Coordinator) void {
        self.launch.release(null);
    }
    pub fn tick(self: *Coordinator) void {
        if (!worlds.transaction_gate.tryLock()) return;
        defer worlds.transaction_gate.unlock(self.io);
        self.drainReleasesLocked();
    }
    /// Caller must hold worlds.transaction_gate; only matching release epochs clear.
    fn drainReleasesLocked(self: *Coordinator) void {
        self.launch.applyRelease();
        for (&self.mutations) |*item| item.reservation.applyRelease();
    }
    /// Predicate requires the caller to already hold worlds.transaction_gate.
    pub fn guard(self: *Coordinator, excluding: ?*Mutation) worlds.Guard {
        if (excluding) |item| {
            std.debug.assert(item.owner == self);
            return .{ .context = item, .is_running = Mutation.guardCallback };
        }
        return .{ .context = self, .is_running = guardCallback };
    }
    fn busy(self: *Coordinator, id: []const u8, excluding: ?*Mutation) bool {
        if (self.launch.matches(id)) return true;
        for (&self.mutations) |*item| {
            if (item == excluding) continue;
            if (item.reservation.matches(id)) return true;
        }
        return false;
    }
    fn guardCallback(context: ?*anyopaque, id: []const u8) bool {
        const self: *Coordinator = @ptrCast(@alignCast(context.?));
        return self.busy(id, null);
    }
};

pub const Mutation = struct {
    owner: ?*Coordinator = null,
    reservation: Reservation = .{},

    pub fn acquire(self: *Mutation, id: []const u8) !void {
        if (!config.validId(id)) return error.InvalidInstanceId;
        const owner = self.owner.?;
        if (!worlds.transaction_gate.tryLock()) return error.InstanceBusy;
        defer worlds.transaction_gate.unlock(owner.io);
        owner.drainReleasesLocked();
        if (owner.launch.matches(id)) return error.InstanceRunning;
        if (self.reservation.len != 0 or owner.busy(id, self)) return error.InstanceBusy;
        try self.reservation.reserve(id);
    }
    pub fn recheck(self: *Mutation, id: []const u8) !void {
        if (!config.validId(id)) return error.InvalidInstanceId;
        const owner = self.owner.?;
        if (!worlds.transaction_gate.tryLock()) return error.InstanceBusy;
        defer worlds.transaction_gate.unlock(owner.io);
        if (!self.reservation.matches(id) or self.reservation.pending_release.load(.acquire) == self.reservation.epoch.load(.acquire)) return error.LeaseNotHeld;
        if (owner.launch.matches(id)) return error.InstanceRunning;
        if (owner.busy(id, self)) return error.InstanceBusy;
    }
    pub fn release(self: *Mutation, id: []const u8) void {
        self.reservation.release(id);
    }
    pub fn acquireCallback(context: ?*anyopaque, id: []const u8) anyerror!void {
        const self: *Mutation = @ptrCast(@alignCast(context.?));
        return self.acquire(id);
    }
    pub fn recheckCallback(context: ?*anyopaque, id: []const u8) anyerror!void {
        const self: *Mutation = @ptrCast(@alignCast(context.?));
        return self.recheck(id);
    }
    pub fn releaseCallback(context: ?*anyopaque, id: []const u8) void {
        const self: *Mutation = @ptrCast(@alignCast(context.?));
        self.release(id);
    }
    fn guardCallback(context: ?*anyopaque, id: []const u8) bool {
        const self: *Mutation = @ptrCast(@alignCast(context.?));
        return self.owner.?.busy(id, self);
    }
};

const test_io = std.testing.io;
fn guardBusy(guard: worlds.Guard, id: []const u8) bool {
    return guard.is_running.?(guard.context, id);
}

test "instance lease same-ID collisions and distinct IDs coexist" {
    var coordinator = Coordinator.init(test_io);
    const first = coordinator.mutation(0);
    const second = coordinator.mutation(1);
    for (&coordinator.mutations) |*item| try std.testing.expect(item.owner == &coordinator);
    try first.acquire("alpha");
    try std.testing.expectError(error.InstanceBusy, first.acquire("alpha"));
    try std.testing.expectError(error.InstanceBusy, second.acquire("alpha"));
    try std.testing.expectError(error.InstanceBusy, coordinator.reserveLaunch("alpha"));
    try coordinator.reserveLaunch("beta");
    try std.testing.expectError(error.InstanceRunning, second.acquire("beta"));
    try std.testing.expectError(error.InstanceRunning, coordinator.reserveLaunch("beta"));
    try std.testing.expectError(error.InstanceBusy, coordinator.reserveLaunch("delta"));
    try second.acquire("gamma");
    try first.recheck("alpha");
    try second.recheck("gamma");
    coordinator.releaseLaunch();
    first.release("alpha");
    second.release("gamma");
    coordinator.tick();
    try coordinator.reserveLaunch("alpha");
    coordinator.releaseLaunch();
    coordinator.tick();
}

test "instance lease own world guard excludes only the owning mutation" {
    var coordinator = Coordinator.init(test_io);
    const first = coordinator.mutation(0);
    const second = coordinator.mutation(1);
    try first.acquire("alpha");
    try second.acquire("beta");
    try coordinator.reserveLaunch("gamma");
    try std.testing.expect(worlds.transaction_gate.tryLock());
    {
        defer worlds.transaction_gate.unlock(test_io);
        const complete = coordinator.guard(null);
        const own = coordinator.guard(first);
        try std.testing.expect(guardBusy(complete, "alpha"));
        try std.testing.expect(guardBusy(complete, "beta"));
        try std.testing.expect(guardBusy(complete, "gamma"));
        try std.testing.expect(!guardBusy(own, "alpha"));
        try std.testing.expect(guardBusy(own, "beta"));
        try std.testing.expect(guardBusy(own, "gamma"));
        try std.testing.expect(!guardBusy(own, "delta"));
    }
    first.release("alpha");
    second.release("beta");
    coordinator.releaseLaunch();
    coordinator.tick();
}

test "instance lease gate-busy paths never block and release is deferred" {
    var coordinator = Coordinator.init(test_io);
    const first = coordinator.mutation(0);
    const second = coordinator.mutation(1);
    try first.acquire("alpha");
    try coordinator.reserveLaunch("beta");
    try std.testing.expect(worlds.transaction_gate.tryLock());
    {
        defer worlds.transaction_gate.unlock(test_io);
        try std.testing.expectError(error.InstanceBusy, first.recheck("alpha"));
        try std.testing.expectError(error.InstanceBusy, second.acquire("gamma"));
        try std.testing.expectError(error.InstanceBusy, coordinator.reserveLaunch("delta"));
        first.release("alpha");
        coordinator.releaseLaunch();
        coordinator.tick();
        try std.testing.expect(guardBusy(coordinator.guard(null), "alpha"));
        try std.testing.expect(guardBusy(coordinator.guard(null), "beta"));
    }
    coordinator.tick();
    try std.testing.expectError(error.LeaseNotHeld, first.recheck("alpha"));
    try coordinator.reserveLaunch("beta");
    coordinator.releaseLaunch();
    coordinator.tick();
}

test "instance lease release admits another mutation on the same ID without a tick" {
    var coordinator = Coordinator.init(test_io);
    const first = coordinator.mutation(0);
    const second = coordinator.mutation(1);
    try first.acquire("alpha");
    const previous = first.reservation.epoch.load(.acquire);
    first.release("beta");
    try std.testing.expectError(error.InstanceBusy, second.acquire("alpha"));
    try first.recheck("alpha");
    first.release("alpha");
    try std.testing.expectError(error.LeaseNotHeld, first.recheck("alpha"));
    try second.acquire("alpha");
    try second.recheck("alpha");
    try first.acquire("beta");
    _ = first.reservation.pending_release.fetchMax(previous, .release);
    first.release("alpha");
    try first.recheck("beta");
    try std.testing.expectError(error.InstanceBusy, coordinator.reserveLaunch("beta"));
    try first.recheck("beta");
    first.release("beta");
    second.release("alpha");
    coordinator.tick();
}

test "instance lease matching releases transfer between launch and mutation without a tick" {
    var coordinator = Coordinator.init(test_io);
    const lease = coordinator.mutation(0);
    try coordinator.reserveLaunch("alpha");
    try std.testing.expectError(error.InstanceRunning, lease.acquire("alpha"));
    coordinator.releaseLaunch();
    try lease.acquire("alpha");
    try lease.recheck("alpha");
    try std.testing.expectError(error.InstanceBusy, coordinator.reserveLaunch("alpha"));
    lease.release("alpha");
    try coordinator.reserveLaunch("alpha");
    try std.testing.expectError(error.InstanceRunning, lease.acquire("alpha"));
    coordinator.releaseLaunch();
    coordinator.tick();
}

test "instance lease pending release remains reserved while the transaction gate is held" {
    var coordinator = Coordinator.init(test_io);
    const first = coordinator.mutation(0);
    const second = coordinator.mutation(1);
    try first.acquire("alpha");
    try std.testing.expect(worlds.transaction_gate.tryLock());
    {
        defer worlds.transaction_gate.unlock(test_io);
        first.release("alpha");
        try std.testing.expectError(error.InstanceBusy, second.acquire("alpha"));
        try std.testing.expectError(error.InstanceBusy, coordinator.reserveLaunch("alpha"));
        try std.testing.expect(guardBusy(coordinator.guard(null), "alpha"));
    }
    try second.acquire("alpha");
    try second.recheck("alpha");
    second.release("alpha");
    coordinator.tick();
}

test "instance lease wrong ID and delayed old generation cannot release a new lease" {
    var coordinator = Coordinator.init(test_io);
    const lease = coordinator.mutation(0);
    try lease.acquire("alpha");
    const previous = lease.reservation.epoch.load(.acquire);
    lease.release("beta");
    coordinator.tick();
    try lease.recheck("alpha");
    try std.testing.expectError(error.LeaseNotHeld, lease.recheck("beta"));
    lease.release("alpha");
    try std.testing.expectError(error.LeaseNotHeld, lease.recheck("alpha"));
    coordinator.tick();
    try lease.acquire("beta");
    _ = lease.reservation.pending_release.fetchMax(previous, .release);
    lease.release("alpha");
    coordinator.tick();
    try lease.recheck("beta");
    try std.testing.expectError(error.InstanceBusy, coordinator.reserveLaunch("beta"));
    lease.release("beta");
    coordinator.tick();
}

test "instance lease portable bounded owned IDs and exact callback signatures" {
    var coordinator = Coordinator.init(test_io);
    const lease = coordinator.mutation(3);
    const acquire: *const fn (?*anyopaque, []const u8) anyerror!void = Mutation.acquireCallback;
    const recheck: *const fn (?*anyopaque, []const u8) anyerror!void = Mutation.recheckCallback;
    const release: *const fn (?*anyopaque, []const u8) void = Mutation.releaseCallback;
    for ([_][]const u8{ "", "../escape", "nul", "trailing.", "slash/x" }) |id| {
        try std.testing.expectError(error.InvalidInstanceId, coordinator.reserveLaunch(id));
        try std.testing.expectError(error.InvalidInstanceId, acquire(lease, id));
        try std.testing.expectError(error.InvalidInstanceId, recheck(lease, id));
    }
    const oversized = [_]u8{'a'} ** 201;
    try std.testing.expectError(error.InvalidInstanceId, acquire(lease, &oversized));
    try acquire(lease, oversized[0..200]);
    try recheck(lease, oversized[0..200]);
    release(lease, oversized[0..200]);
    coordinator.tick();
    var borrowed = [_]u8{ 'i', 'd', '1' };
    try acquire(lease, &borrowed);
    @memcpy(&borrowed, "xx1");
    try recheck(lease, "id1");
    release(lease, "id1");
    coordinator.tick();
}

const ReleaseWorker = struct {
    fn run(lease: *Mutation, id: []const u8) void {
        for (0..4096) |_| lease.release(id);
    }
    fn launch(coordinator: *Coordinator) void {
        for (0..4096) |_| coordinator.releaseLaunch();
    }
};
test "instance lease bounded concurrent release tick and different-ID slot reuse" {
    var coordinator = Coordinator.init(test_io);
    const lease = coordinator.mutation(0);
    try lease.acquire("alpha");
    var beta_acquired = false;
    {
        const releasing = try std.Thread.spawn(.{}, ReleaseWorker.run, .{ lease, "alpha" });
        defer releasing.join();
        const wrong_id = try std.Thread.spawn(.{}, ReleaseWorker.run, .{ lease, "gamma" });
        defer wrong_id.join();
        for (0..1024) |_| {
            coordinator.tick();
            if (!beta_acquired) {
                lease.acquire("beta") catch |err| {
                    if (err != error.InstanceBusy) return err;
                    continue;
                };
                beta_acquired = true;
            }
            try lease.recheck("beta");
        }
    }
    coordinator.tick();
    if (!beta_acquired) try lease.acquire("beta");
    try lease.recheck("beta");
    lease.release("beta");
    coordinator.tick();
    try coordinator.reserveLaunch("alpha");
    {
        const releasing = try std.Thread.spawn(.{}, ReleaseWorker.launch, .{&coordinator});
        defer releasing.join();
        for (0..1024) |_| coordinator.tick();
    }
    coordinator.tick();
    try coordinator.reserveLaunch("beta");
    coordinator.releaseLaunch();
    coordinator.tick();
}

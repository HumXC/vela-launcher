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
    pub fn worldScope(self: *Coordinator, slot: usize) worlds.WorldScope {
        return self.mutation(slot).worldScope();
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
        for (&self.mutations) |*item| item.applyRelease();
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
            if (item.reservation.matches(id) or item.secondary.matches(id)) return true;
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
    secondary: Reservation = .{},
    pair_active: bool = false,
    pair_release: Atomic(u64) = .init(0),

    pub fn acquire(self: *Mutation, id: []const u8) !void {
        if (!config.validId(id)) return error.InvalidInstanceId;
        const owner = self.owner.?;
        if (!worlds.transaction_gate.tryLock()) return error.InstanceBusy;
        defer worlds.transaction_gate.unlock(owner.io);
        owner.drainReleasesLocked();
        if (owner.launch.matches(id)) return error.InstanceRunning;
        if (self.pair_active or self.reservation.len != 0 or self.secondary.len != 0 or owner.busy(id, self)) return error.InstanceBusy;
        try self.reservation.reserve(id);
    }
    pub fn recheck(self: *Mutation, id: []const u8) !void {
        if (!config.validId(id)) return error.InvalidInstanceId;
        const owner = self.owner.?;
        if (!worlds.transaction_gate.tryLock()) return error.InstanceBusy;
        defer worlds.transaction_gate.unlock(owner.io);
        try self.recheckLocked(id);
    }
    /// Worker-only check. Mutex admission precedes bounded lease-state checks.
    /// The owner joins the worker before releasing or reusing this mutation slot.
    pub fn workerRecheck(self: *Mutation, id: []const u8) !void {
        if (!config.validId(id)) return error.InvalidInstanceId;
        const owner = self.owner.?;
        try worlds.transaction_gate.lock(owner.io);
        defer worlds.transaction_gate.unlock(owner.io);
        try self.recheckLocked(id);
    }
    fn recheckLocked(self: *Mutation, id: []const u8) !void {
        const owner = self.owner.?;
        if (self.pair_active or !self.reservation.matches(id) or self.reservation.pending_release.load(.acquire) == self.reservation.epoch.load(.acquire)) return error.LeaseNotHeld;
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
    /// Explicit worker counterpart; owner publication and recovery keep recheckCallback.
    pub fn workerRecheckCallback(context: ?*anyopaque, id: []const u8) anyerror!void {
        const self: *Mutation = @ptrCast(@alignCast(context.?));
        return self.workerRecheck(id);
    }
    pub fn releaseCallback(context: ?*anyopaque, id: []const u8) void {
        const self: *Mutation = @ptrCast(@alignCast(context.?));
        self.release(id);
    }
    fn applyRelease(self: *Mutation) void {
        if (self.pair_active) {
            const epoch = self.reservation.epoch.load(.acquire);
            if (epoch == 0 or self.pair_release.load(.acquire) != epoch) return;
            // One stamped atomic publication releases both IDs under the gate.
            self.reservation.epoch.store(0, .release);
            self.reservation.len = 0;
            self.secondary.epoch.store(0, .release);
            self.secondary.len = 0;
            self.pair_active = false;
            return;
        }
        self.reservation.applyRelease();
        self.secondary.applyRelease();
    }
    fn validateWorldIds(requested: worlds.ScopeIds) !worlds.ScopeIds {
        const ids = requested.normalized();
        if (!config.validId(ids.source)) return error.InvalidInstanceId;
        if (ids.target) |target| if (!config.validId(target)) return error.InvalidInstanceId;
        return ids;
    }
    fn worldStateLocked(self: *Mutation, ids: worlds.ScopeIds, excluding: ?*Mutation) worlds.ScopeState {
        const owner = self.owner.?;
        if (owner.launch.matches(ids.source)) return .running;
        if (ids.target) |target| if (owner.launch.matches(target)) return .running;
        if (owner.busy(ids.source, excluding)) return .busy;
        if (ids.target) |target| if (owner.busy(target, excluding)) return .busy;
        return .available;
    }
    pub fn worldScope(self: *Mutation) worlds.WorldScope {
        std.debug.assert(self.owner != null);
        return .{ .context = self, .probe = worldProbe, .acquire = worldAcquire, .recheck = worldRecheck, .release = worldRelease };
    }
    fn worldProbe(context: ?*anyopaque, requested: worlds.ScopeIds) anyerror!worlds.ScopeState {
        const self: *Mutation = @ptrCast(@alignCast(context.?));
        const ids = try validateWorldIds(requested);
        const owner = self.owner.?;
        if (!worlds.transaction_gate.tryLock()) return .busy;
        defer worlds.transaction_gate.unlock(owner.io);
        owner.drainReleasesLocked();
        return self.worldStateLocked(ids, null);
    }
    fn worldAcquire(context: ?*anyopaque, requested: worlds.ScopeIds) anyerror!worlds.ScopeStamp {
        const self: *Mutation = @ptrCast(@alignCast(context.?));
        const ids = try validateWorldIds(requested);
        const owner = self.owner.?;
        if (!worlds.transaction_gate.tryLock()) return error.InstanceBusy;
        defer worlds.transaction_gate.unlock(owner.io);
        owner.drainReleasesLocked();
        switch (self.worldStateLocked(ids, null)) {
            .running => return error.InstanceRunning,
            .busy => return error.InstanceBusy,
            .available => {},
        }
        if (self.pair_active or self.reservation.len != 0 or self.secondary.len != 0) return error.InstanceBusy;
        // Preflight every fallible condition before changing either reservation.
        if (self.reservation.generation == std.math.maxInt(u64)) return error.LeaseGenerationExhausted;
        if (ids.target != null and self.secondary.generation == std.math.maxInt(u64)) return error.LeaseGenerationExhausted;
        self.reservation.reserve(ids.source) catch unreachable;
        if (ids.target) |target| self.secondary.reserve(target) catch unreachable;
        self.pair_active = true;
        return .{ .source_generation = self.reservation.generation, .target_generation = if (ids.target != null) self.secondary.generation else null };
    }
    fn worldRecheck(context: ?*anyopaque, requested: worlds.ScopeIds, stamp: worlds.ScopeStamp) anyerror!void {
        const self: *Mutation = @ptrCast(@alignCast(context.?));
        const ids = try validateWorldIds(requested);
        const owner = self.owner.?;
        // Workers may wait for a short state section; this gate never covers I/O.
        try worlds.transaction_gate.lock(owner.io);
        defer worlds.transaction_gate.unlock(owner.io);
        if (!self.pair_active or !self.reservation.matches(ids.source) or self.reservation.epoch.load(.acquire) != stamp.source_generation or self.pair_release.load(.acquire) == stamp.source_generation) return error.LeaseNotHeld;
        if (ids.target) |target| {
            const generation = stamp.target_generation orelse return error.LeaseNotHeld;
            if (!self.secondary.matches(target) or self.secondary.epoch.load(.acquire) != generation) return error.LeaseNotHeld;
        } else if (stamp.target_generation != null or self.secondary.len != 0) return error.LeaseNotHeld;
        switch (self.worldStateLocked(ids, self)) {
            .running => return error.InstanceRunning,
            .busy => return error.InstanceBusy,
            .available => {},
        }
    }
    fn worldRelease(context: ?*anyopaque, _: worlds.ScopeIds, stamp: worlds.ScopeStamp) void {
        const self: *Mutation = @ptrCast(@alignCast(context.?));
        // Never read mutable IDs or epochs here. Old releases cannot replace newer ones.
        _ = self.pair_release.fetchMax(stamp.source_generation, .release);
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

test "world scope atomically reserves normalized source and target IDs" {
    var coordinator = Coordinator.init(test_io);
    const scope = coordinator.worldScope(3);
    const content = coordinator.mutation(1);
    try content.acquire("beta");
    try std.testing.expectError(error.InstanceBusy, scope.hold(.{ .source = "alpha", .target = "beta" }));
    try coordinator.reserveLaunch("alpha"); // Failed pair admission reserved nothing.
    coordinator.releaseLaunch();
    content.release("beta");
    coordinator.tick();
    const held = try scope.hold(.{ .source = "alpha", .target = "beta" });
    try held.recheck();
    var wrong_target_stamp = held;
    wrong_target_stamp.stamp.target_generation = held.stamp.target_generation.? - 1;
    try std.testing.expectError(error.LeaseNotHeld, wrong_target_stamp.recheck());
    try std.testing.expect(held.covers(.{ .source = "beta", .target = "alpha" }));
    try std.testing.expect(!held.covers(.{ .source = "gamma" }));
    try std.testing.expectError(error.InstanceBusy, coordinator.reserveLaunch("alpha"));
    try std.testing.expectError(error.InstanceBusy, coordinator.reserveLaunch("beta"));
    try std.testing.expectError(error.InstanceBusy, content.acquire("beta"));
    try content.acquire("gamma");
    try held.recheck();
    try worlds.transaction_gate.lock(test_io);
    {
        defer worlds.transaction_gate.unlock(test_io);
        try std.testing.expect(guardBusy(coordinator.guard(null), "alpha"));
        try std.testing.expect(guardBusy(coordinator.guard(null), "beta"));
        const own = coordinator.guard(coordinator.mutation(3));
        try std.testing.expect(!guardBusy(own, "alpha"));
        try std.testing.expect(!guardBusy(own, "beta"));
        try std.testing.expect(guardBusy(own, "gamma"));
    }
    held.release();
    content.release("gamma");
    coordinator.tick();
    try coordinator.reserveLaunch("beta");
    coordinator.releaseLaunch();
    coordinator.tick();
    const normalized = try scope.hold(.{ .source = "alpha", .target = "alpha" });
    try std.testing.expect(normalized.ids.target == null);
    try std.testing.expect(normalized.stamp.target_generation == null);
    try normalized.recheck();
    normalized.release();
    coordinator.tick();
}

test "world scope preflights invalid IDs and both generation limits" {
    var coordinator = Coordinator.init(test_io);
    const scope = coordinator.worldScope(3);
    const slot = coordinator.mutation(3);
    try std.testing.expectError(error.InvalidInstanceId, scope.hold(.{ .source = "alpha", .target = "bad/id" }));
    try std.testing.expectEqual(@as(u64, 0), slot.reservation.generation);
    slot.secondary.generation = std.math.maxInt(u64);
    try std.testing.expectError(error.LeaseGenerationExhausted, scope.hold(.{ .source = "alpha", .target = "beta" }));
    try std.testing.expectEqual(@as(u64, 0), slot.reservation.generation);
    try coordinator.reserveLaunch("alpha");
    coordinator.releaseLaunch();
    coordinator.tick();
    const one = try scope.hold(.{ .source = "alpha", .target = "alpha" });
    one.release();
    coordinator.tick();
    slot.reservation.generation = std.math.maxInt(u64);
    slot.secondary.generation = 0;
    try std.testing.expectError(error.LeaseGenerationExhausted, scope.hold(.{ .source = "alpha", .target = "beta" }));
    try std.testing.expectEqual(@as(u64, 0), slot.secondary.generation);
    try std.testing.expectEqual(@as(usize, 0), slot.reservation.len);
    try std.testing.expectEqual(@as(usize, 0), slot.secondary.len);
}

test "world scope stamped old release cannot clear new hold or overwrite pending pair release" {
    var coordinator = Coordinator.init(test_io);
    const scope = coordinator.worldScope(3);
    const ids: worlds.ScopeIds = .{ .source = "alpha", .target = "beta" };
    const old = try scope.hold(ids);
    old.release();
    coordinator.tick();
    const current = try scope.hold(ids);
    old.release();
    coordinator.tick();
    try current.recheck();
    try std.testing.expectError(error.LeaseNotHeld, old.recheck());
    try std.testing.expectError(error.InstanceBusy, coordinator.reserveLaunch("alpha"));
    try std.testing.expectError(error.InstanceBusy, coordinator.reserveLaunch("beta"));
    current.release();
    old.release(); // Must not replace the valid newer pending release.
    try std.testing.expectError(error.LeaseNotHeld, current.recheck());
    coordinator.tick();
    try coordinator.reserveLaunch("alpha");
    coordinator.releaseLaunch();
    coordinator.tick();
    try coordinator.reserveLaunch("beta");
    coordinator.releaseLaunch();
    coordinator.tick();
    const renewed = try scope.hold(ids);
    try renewed.recheck();
    renewed.release();
    coordinator.tick();
}

test "world scope probe distinguishes matching launch busy gate and distinct IDs" {
    var coordinator = Coordinator.init(test_io);
    const scope = coordinator.worldScope(3);
    try coordinator.reserveLaunch("alpha");
    try std.testing.expectEqual(worlds.ScopeState.running, try scope.probe(scope.context, .{ .source = "alpha" }));
    try std.testing.expectEqual(worlds.ScopeState.running, try scope.probe(scope.context, .{ .source = "beta", .target = "alpha" }));
    try std.testing.expectEqual(worlds.ScopeState.available, try scope.probe(scope.context, .{ .source = "beta" }));
    try std.testing.expectError(error.InstanceRunning, scope.hold(.{ .source = "beta", .target = "alpha" }));
    const held = try scope.hold(.{ .source = "beta" });
    try held.recheck();
    held.release();
    coordinator.releaseLaunch();
    coordinator.tick();
    try coordinator.mutation(1).acquire("alpha");
    try std.testing.expectEqual(worlds.ScopeState.busy, try scope.probe(scope.context, .{ .source = "alpha" }));
    try worlds.transaction_gate.lock(test_io);
    {
        defer worlds.transaction_gate.unlock(test_io);
        try std.testing.expectEqual(worlds.ScopeState.busy, try scope.probe(scope.context, .{ .source = "beta" }));
        try std.testing.expectError(error.InstanceBusy, scope.hold(.{ .source = "beta" }));
    }
    coordinator.mutation(1).release("alpha");
    coordinator.tick();
}

const WorldReleaseWorker = struct {
    fn run(held: worlds.HeldWorldScope) void {
        for (0..4096) |_| held.release();
    }
};

test "world scope concurrent old same-ID release preserves renewed pair" {
    var coordinator = Coordinator.init(test_io);
    const scope = coordinator.worldScope(3);
    const ids: worlds.ScopeIds = .{ .source = "alpha", .target = "beta" };
    const old = try scope.hold(ids);
    old.release();
    coordinator.tick();
    const current = try scope.hold(ids);
    {
        const releasing = try std.Thread.spawn(.{}, WorldReleaseWorker.run, .{old});
        defer releasing.join();
        for (0..1024) |_| {
            coordinator.tick();
            try current.recheck();
            try std.testing.expectError(error.InstanceBusy, coordinator.reserveLaunch("alpha"));
            try std.testing.expectError(error.InstanceBusy, coordinator.reserveLaunch("beta"));
        }
        current.release();
    }
    coordinator.tick();
    try coordinator.reserveLaunch("alpha");
    coordinator.releaseLaunch();
    coordinator.tick();
    try coordinator.reserveLaunch("beta");
    coordinator.releaseLaunch();
    coordinator.tick();
}

const WorkerGateProbe = struct {
    delegate: std.Io,
    vtable: std.Io.VTable,
    coordinator: ?*Coordinator = null,
    entered: std.Io.Event = .unset,
    waits: Atomic(usize) = .init(0),
    stats: Atomic(usize) = .init(0),
    violation: Atomic(bool) = .init(false),
    var current: ?*WorkerGateProbe = null;

    fn init(delegate_io: std.Io) WorkerGateProbe {
        var vtable = delegate_io.vtable.*;
        vtable.futexWait = futexWait;
        vtable.fileStat = fileStat;
        return .{ .delegate = delegate_io, .vtable = vtable };
    }
    fn io(self: *WorkerGateProbe) std.Io {
        // Unmodified callbacks still receive their original backend userdata.
        return .{ .userdata = self.delegate.userdata, .vtable = &self.vtable };
    }
    fn futexWait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        const self = current.?;
        std.debug.assert(userdata == self.delegate.userdata);
        _ = self.waits.fetchAdd(1, .monotonic);
        self.entered.set(self.delegate);
        return self.delegate.vtable.futexWait(userdata, ptr, expected, timeout);
    }
    fn fileStat(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.StatError!std.Io.File.Stat {
        const self = current.?;
        std.debug.assert(userdata == self.delegate.userdata);
        _ = self.stats.fetchAdd(1, .monotonic);
        if (worlds.transaction_gate.tryLock()) {
            worlds.transaction_gate.unlock(self.delegate);
            const ns = @import("instance_namespace.zig");
            const admitted: ?ns.Token = ns.acquire(self.delegate) catch |err| blk: {
                if (err != error.InstanceNamespaceBusy) self.violation.store(true, .release);
                break :blk null;
            };
            if (admitted) |token| {
                token.release();
                self.violation.store(true, .release);
            }
            const owner = self.coordinator.?;
            var same_denied = false;
            owner.reserveLaunch("alpha") catch |err| {
                same_denied = err == error.InstanceBusy;
            };
            if (!same_denied) {
                owner.releaseLaunch();
                self.violation.store(true, .release);
            }
            owner.reserveLaunch("beta") catch {
                self.violation.store(true, .release);
                return self.delegate.vtable.fileStat(userdata, file);
            };
            owner.releaseLaunch();
            owner.tick();
        } else self.violation.store(true, .release);
        return self.delegate.vtable.fileStat(userdata, file);
    }
};

const WaitingWorker = struct {
    const ns = @import("instance_namespace.zig");
    const Operation = enum { instance, namespace_check, namespace_admission };
    io: std.Io,
    mutation: *Mutation,
    token: ?ns.Token,
    operation: Operation,
    directory: std.Io.Dir,
    acquired: ?ns.Token = null,
    failure: ?anyerror = null,

    fn run(self: *WaitingWorker) void {
        self.checkAndStat() catch |err| {
            self.failure = err;
        };
    }
    fn checkAndStat(self: *WaitingWorker) !void {
        switch (self.operation) {
            .instance => try Mutation.workerRecheckCallback(self.mutation, "alpha"),
            .namespace_check => try self.token.?.recheckWaiting(),
            .namespace_admission => self.acquired = try ns.acquireWaiting(self.io),
        }
        var file = try self.directory.openFile(self.io, "probe", .{});
        defer file.close(self.io);
        _ = try file.stat(self.io);
    }
};

test "worker checks observe a real gate wait and keep leases through actual I/O" {
    const ns = @import("instance_namespace.zig");
    const real_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(real_io, .{ .sub_path = "probe", .data = "real stat" });
    for (std.enums.values(WaitingWorker.Operation)) |operation| {
        for ([_]bool{ false, true }) |reject| {
            var probe = WorkerGateProbe.init(real_io);
            std.debug.assert(WorkerGateProbe.current == null);
            WorkerGateProbe.current = &probe;
            defer WorkerGateProbe.current = null;
            const io = probe.io();
            var coordinator = Coordinator.init(io);
            probe.coordinator = &coordinator;
            const mutation = coordinator.mutation(0);
            try mutation.acquire("alpha");
            defer {
                mutation.release("alpha");
                coordinator.tick();
            }
            const held: ?ns.Token = if (operation != .namespace_admission or reject) try ns.acquire(io) else null;
            defer if (held) |token| token.release();
            var worker: WaitingWorker = .{ .io = io, .mutation = mutation, .token = held, .operation = operation, .directory = tmp.dir };
            defer if (worker.acquired) |token| token.release();
            try std.testing.expect(worlds.transaction_gate.tryLock());
            var gate_held = true;
            defer if (gate_held) worlds.transaction_gate.unlock(io);
            try std.testing.expectError(error.InstanceBusy, Mutation.recheckCallback(mutation, "alpha"));
            try std.testing.expectError(error.InstanceNamespaceBusy, ns.acquire(io));
            if (held) |token| try std.testing.expectError(error.InstanceNamespaceBusy, token.recheck());
            const thread = try std.Thread.spawn(.{}, WaitingWorker.run, .{&worker});
            var joined = false;
            defer if (!joined) thread.join();
            // This is signaled only by the real mutex futex-wait path, not worker entry.
            const waited = probe.entered.waitTimeout(real_io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
            if (reject) switch (operation) {
                .instance => mutation.release("alpha"),
                .namespace_check => held.?.release(),
                .namespace_admission => {}, // A genuine namespace owner stays active.
            };
            worlds.transaction_gate.unlock(io);
            gate_held = false;
            thread.join();
            joined = true;
            try waited;
            try std.testing.expect(probe.waits.load(.acquire) > 0);
            if (reject) {
                const expected: anyerror = switch (operation) {
                    .instance => error.LeaseNotHeld,
                    .namespace_check => error.InstanceNamespaceLeaseLost,
                    .namespace_admission => error.InstanceNamespaceBusy,
                };
                try std.testing.expectEqual(expected, worker.failure.?);
                try std.testing.expectEqual(@as(usize, 0), probe.stats.load(.acquire));
            } else {
                try std.testing.expect(worker.failure == null);
                try std.testing.expect(probe.stats.load(.acquire) > 0);
                try std.testing.expect(!probe.violation.load(.acquire));
            }
        }
    }
}

const OwnerTickWorker = struct {
    fn run(owner: *Coordinator) void {
        for (0..4096) |_| owner.tick();
    }
};

test "worker lease and namespace checks coexist with concurrent owner ticks" {
    const ns = @import("instance_namespace.zig");
    var coordinator = Coordinator.init(test_io);
    const mutation = coordinator.mutation(0);
    try mutation.acquire("alpha");
    defer {
        mutation.release("alpha");
        coordinator.tick();
    }
    const token = try ns.acquire(test_io);
    defer token.release();
    {
        const owner = try std.Thread.spawn(.{}, OwnerTickWorker.run, .{&coordinator});
        defer owner.join();
        for (0..512) |_| {
            try Mutation.workerRecheckCallback(mutation, "alpha");
            try token.recheckWaiting();
        }
    }
    try std.testing.expectError(error.InstanceBusy, coordinator.reserveLaunch("alpha"));
    try coordinator.reserveLaunch("beta");
    coordinator.releaseLaunch();
    coordinator.tick();
    try std.testing.expectError(error.InstanceNamespaceBusy, ns.acquireWaiting(test_io));
    try std.testing.expectError(error.InvalidInstanceId, mutation.workerRecheck("../bad"));
}

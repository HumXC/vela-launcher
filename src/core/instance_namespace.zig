//! Process-wide versions/metadata reservation. The world gate protects only stamps.
//! Owners retain a token through all I/O, cleanup and publication; borrowers never release.
const std = @import("std");
const worlds = @import("worlds.zig");
const Io = std.Io;

var generation: u64 = 0;
var active: u64 = 0;
var pending_release: std.atomic.Value(u64) = .init(0);

fn drainLocked() void {
    if (active != 0 and pending_release.load(.acquire) >= active) active = 0;
}

pub const Token = struct {
    io: Io,
    generation: u64,

    /// Validate the recorded stamp, including an asynchronously queued release.
    pub fn recheck(self: Token) !void {
        if (!worlds.transaction_gate.tryLock()) return error.InstanceNamespaceBusy;
        defer worlds.transaction_gate.unlock(self.io);
        try self.recheckLocked();
    }

    /// Worker-only stamp check; mutex admission precedes bounded state checks.
    pub fn recheckWaiting(self: Token) !void {
        try worlds.transaction_gate.lock(self.io);
        defer worlds.transaction_gate.unlock(self.io);
        try self.recheckLocked();
    }

    fn recheckLocked(self: Token) !void {
        drainLocked();
        if (self.generation == 0 or active != self.generation) return error.InstanceNamespaceLeaseLost;
    }

    /// Immutable stamped release; safe even while the gate is unavailable.
    /// Only the acquiring owner calls this, after its last cleanup/close.
    pub fn release(self: Token) void {
        _ = pending_release.fetchMax(self.generation, .release);
    }
};

pub fn acquire(io: Io) !Token {
    if (!worlds.transaction_gate.tryLock()) return error.InstanceNamespaceBusy;
    defer worlds.transaction_gate.unlock(io);
    return acquireLocked(io);
}

/// Worker-only admission. An active namespace owner still returns busy after
/// mutex admission; only contention for the short gate section is waited out.
pub fn acquireWaiting(io: Io) !Token {
    try worlds.transaction_gate.lock(io);
    defer worlds.transaction_gate.unlock(io);
    return acquireLocked(io);
}

fn acquireLocked(io: Io) !Token {
    drainLocked();
    if (active != 0) return error.InstanceNamespaceBusy;
    if (generation == std.math.maxInt(u64)) return error.InstanceNamespaceGenerationExhausted;
    generation += 1;
    active = generation;
    return .{ .io = io, .generation = generation };
}

test "namespace stamped releases cannot free a newer owner" {
    const io = std.testing.io;
    const old = try acquire(io);
    old.release();
    const current = try acquire(io);
    defer current.release();
    try std.testing.expect(current.generation > old.generation);
    old.release();
    try current.recheck();
    try std.testing.expectError(error.InstanceNamespaceBusy, acquire(io));
    current.release();
    old.release();
    const next = try acquire(io);
    defer next.release();
    try std.testing.expect(next.generation > current.generation);
    try std.testing.expectError(error.InstanceNamespaceLeaseLost, current.recheck());
    try next.recheck();
}

test "namespace admission never waits for the world gate" {
    const io = std.testing.io;
    try std.testing.expect(worlds.transaction_gate.tryLock());
    defer worlds.transaction_gate.unlock(io);
    try std.testing.expectError(error.InstanceNamespaceBusy, acquire(io));
}

test "waiting namespace checks reject stale generations without freeing newer owners" {
    const first = try acquireWaiting(std.testing.io);
    defer first.release();
    first.release();
    const second = try acquireWaiting(std.testing.io);
    defer second.release();
    try std.testing.expectError(error.InstanceNamespaceLeaseLost, first.recheckWaiting());
    first.release();
    try second.recheckWaiting();
    try std.testing.expectError(error.InstanceNamespaceBusy, acquireWaiting(std.testing.io));
    second.release();
    try std.testing.expectError(error.InstanceNamespaceLeaseLost, second.recheckWaiting());
    const third = try acquireWaiting(std.testing.io);
    defer third.release();
    first.release();
    second.release();
    try third.recheckWaiting();
}

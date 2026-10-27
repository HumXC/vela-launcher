//! Explicit application-owned admission budget. Keep at a stable address until all
//! borrowing Services have joined. A permit covers curl network work only.
const std = @import("std");

pub const Budget = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    limit: usize,
    active: usize = 0,

    pub fn init(io: std.Io, limit: usize) !Budget {
        if (limit == 0 or limit > 256) return error.InvalidConcurrency;
        return .{ .io = io, .limit = limit };
    }

    /// Call only after every borrowing service has joined.
    pub fn deinit(self: *Budget) void {
        std.debug.assert(self.active == 0);
        self.* = undefined;
    }

    /// Lowering the limit never revokes permits. New work waits for natural drain.
    pub fn setLimit(self: *Budget, limit: usize) !void {
        if (limit == 0 or limit > 256) return error.InvalidConcurrency;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.limit = limit;
    }

    /// Nonblocking so a network loop can still cancel and finish its own tasks.
    /// Services retry admission on their bounded curl poll (at most 50ms).
    pub fn tryAcquire(self: *Budget) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.active >= self.limit) return false;
        self.active += 1;
        return true;
    }

    pub fn release(self: *Budget) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.active > 0);
        self.active -= 1;
    }

    pub fn snapshot(self: *Budget) struct { limit: usize, active: usize } {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .limit = self.limit, .active = self.active };
    }
};

test "budget lowering drains outstanding permits without revocation" {
    var budget = try Budget.init(std.testing.io, 3);
    defer budget.deinit();
    for (0..3) |_| try std.testing.expect(budget.tryAcquire());
    try budget.setLimit(1);
    try std.testing.expectEqual(@as(usize, 3), budget.snapshot().active);
    try std.testing.expect(!budget.tryAcquire());
    budget.release();
    budget.release();
    try std.testing.expect(!budget.tryAcquire());
    budget.release();
    try std.testing.expect(budget.tryAcquire());
    try budget.setLimit(2);
    try std.testing.expect(budget.tryAcquire());
    try std.testing.expect(!budget.tryAcquire());
    budget.release();
    budget.release();
    try std.testing.expectError(error.InvalidConcurrency, budget.setLimit(0));
    try std.testing.expectEqual(@as(usize, 2), budget.snapshot().limit);
}

test "concurrent owners never exceed the shared budget" {
    var budget = try Budget.init(std.testing.io, 2);
    defer budget.deinit();
    const Worker = struct {
        fn run(shared: *Budget) void {
            for (0..2000) |_| {
                if (!shared.tryAcquire()) continue;
                std.debug.assert(shared.snapshot().active <= 2);
                shared.release();
            }
        }
    };
    var threads: [8]std.Thread = undefined;
    var started: usize = 0;
    defer for (threads[0..started]) |thread| thread.join();
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{&budget});
        started += 1;
    }
}

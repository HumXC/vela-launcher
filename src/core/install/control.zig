//! Shared cancellation, absolute deadline and task ownership for installation.
const std = @import("std");
pub const Control = struct {
    cancel: ?*const std.atomic.Value(bool) = null,
    /// Absolute monotonic milliseconds in the callback clock's domain.
    deadline_ms: u64,
    context: ?*anyopaque = null,
    now_ms: *const fn (?*anyopaque) u64,
    /// Borrowed until the synchronous loader operation returns.
    task: ?*@import("../tasks.zig").Task = null,
    pub fn check(self: Control) !void {
        if (self.cancel) |flag| if (flag.load(.acquire)) return error.Canceled;
        if (self.now_ms(self.context) >= self.deadline_ms) return error.DeadlineExceeded;
    }
};

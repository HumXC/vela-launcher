//! Shared admission for direct and borrowed installation namespace reservations.
const std = @import("std");
const namespace = @import("../instance_namespace.zig");

pub fn reserve(io: std.Io, borrowed: ?namespace.Token, worker: bool) !namespace.Token {
    if (borrowed) |token| {
        if (worker) try token.recheckWaiting() else try token.recheck();
        return token;
    }
    return if (worker) namespace.acquireWaiting(io) else namespace.acquire(io);
}

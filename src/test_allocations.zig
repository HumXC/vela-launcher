//! Deterministic exhaustive OOM injection with the normal leak-checking allocator.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// SafeAllocator can grow a bucket in place depending on previous allocations.
/// A baseline and its replays can therefore make different rawAlloc calls.
/// Force growth to allocate/copy/free so every allocation failure is replayable.
/// Keep the standard helper's failure propagation and leak assertions unchanged.
pub fn checkAllAllocationFailures(backing: Allocator, comptime test_fn: anytype, args: anytype) !void {
    var vtable = backing.vtable.*;
    vtable.resize = Allocator.noResize;
    vtable.remap = Allocator.noRemap;
    const deterministic: Allocator = .{ .ptr = backing.ptr, .vtable = &vtable };
    try std.testing.checkAllAllocationFailures(deterministic, test_fn, args);
}

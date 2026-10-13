const std = @import("std");
const Allocator = std.mem.Allocator;
const checkAllAllocationFailures = @import("test_allocations.zig").checkAllAllocationFailures;

fn grow(allocator: Allocator) !void {
    var bytes = try allocator.alloc(u8, 1000);
    defer allocator.free(bytes);
    bytes = try allocator.realloc(bytes, 2000);
}

test "exhaustive OOM checks remain deterministic after allocator bucket reuse" {
    for (0..40) |_| try checkAllAllocationFailures(std.testing.allocator, grow, .{});
}

fn swallowed(allocator: Allocator) !void {
    const bytes = allocator.alloc(u8, 8) catch return;
    allocator.free(bytes);
}

test "exhaustive OOM checks reject swallowed allocation failures" {
    try std.testing.expectError(error.SwallowedOutOfMemoryError, checkAllAllocationFailures(std.testing.allocator, swallowed, .{}));
}

const LeakFixture = struct {
    leaked: ?[]u8 = null,
    fn run(allocator: Allocator, fixture: *LeakFixture) !void {
        const first = try allocator.alloc(u8, 8);
        const second = allocator.alloc(u8, 16) catch |err| {
            fixture.leaked = first;
            return err;
        };
        allocator.free(second);
        allocator.free(first);
    }
};

test "exhaustive OOM checks still detect failure-path leaks" {
    var fixture: LeakFixture = .{};
    defer if (fixture.leaked) |bytes| std.testing.allocator.free(bytes);
    try std.testing.expectError(error.MemoryLeakDetected, checkAllAllocationFailures(std.testing.allocator, LeakFixture.run, .{&fixture}));
}

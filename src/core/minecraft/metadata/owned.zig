const std = @import("std");
pub fn Owned(comptime T: type) type {
    return struct {
        value: T,
        arena: *std.heap.ArenaAllocator,
        backing: std.mem.Allocator,
        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.backing.destroy(self.arena);
            self.* = undefined;
        }
    };
}
pub fn fromValue(comptime T: type, allocator: std.mem.Allocator, value: std.json.Value, comptime decode: anytype) !Owned(T) {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    return .{ .value = try decode(arena.allocator(), value), .arena = arena, .backing = allocator };
}
pub fn fromSlice(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8, comptime decode: anytype) !Owned(T) {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always, .parse_numbers = false });
    defer parsed.deinit();
    return fromValue(T, allocator, parsed.value, decode);
}

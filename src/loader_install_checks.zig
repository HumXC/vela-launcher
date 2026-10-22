const std = @import("std");
const install = @import("core/loaders/install.zig");
const loaders = @import("core/loaders/root.zig");
fn now(_: ?*anyopaque) u64 {
    return 0;
}
fn acquire(_: ?*anyopaque, _: []const u8) !void {}
fn release(_: ?*anyopaque, _: []const u8) void {}
test "production adapter requires a verified installed base" {
    try std.testing.expectError(error.BaseNotInstalled, install.install(std.testing.allocator, std.testing.io, .{ .root = "/not-written", .base_directory = "/not-written/base", .instance_id = "fixture", .instance_name = "fixture", .selection = .{ .kind = .fabric, .base_id = "1.20.1", .loader_id = "0.15.0" }, .environment = .{ .os_name = "linux", .arch = "x86_64" }, .lease = .{ .acquire = acquire, .recheck = acquire, .release = release } }, loaders.Control{ .now_ms = now, .deadline_ms = std.math.maxInt(u64) }));
}

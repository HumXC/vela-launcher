const std = @import("std");
const adapter = @import("loaders_archive.zig");
const archive = @import("safe_archive");
const c = @import("loaders_common.zig");
fn now(_: ?*anyopaque) u64 {
    return 0;
}
test "shared archive concrete adapter cancellation before filesystem access" {
    var flag = std.atomic.Value(bool).init(true);
    const control: c.Control = .{ .cancel = &flag, .deadline_ms = 100, .now_ms = now };
    try std.testing.expectError(error.Canceled, adapter.extractInstaller(archive, std.testing.allocator, std.testing.io, "never-opened.zip", .cwd(), .{}, control));
}

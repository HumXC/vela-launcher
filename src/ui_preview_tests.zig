const std = @import("std");
const preview = @import("ui/component_preview.zig");

test "component preview registry exposes actual renderable component scenes" {
    try std.testing.expect(preview.supports(.@"account-add", .empty));
    try std.testing.expect(preview.supports(.@"instance-delete", .@"long-text"));
    try std.testing.expect(preview.supports(.controls, .disabled));
}

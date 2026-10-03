const std = @import("std");
const process = @import("core/minecraft/loaders_java_process.zig");
fn now(_: ?*anyopaque) u64 {
    return 0;
}
test "cross target direct Java APIs analyze fully" {
    var flag: std.atomic.Value(bool) = .init(true);
    const control = @import("core/minecraft/loaders_common.zig").Control{ .cancel = &flag, .deadline_ms = 1, .now_ms = now };
    _ = process.probe(std.testing.allocator, std.testing.io, "synthetic-never-spawned", control) catch {};
    _ = process.run(std.testing.allocator, std.testing.io, .{ .java = "synthetic-never-spawned", .main_class = "Main", .classpath = &.{"library.jar"}, .args = &.{}, .working_directory = ".", .control = control }) catch {};
}

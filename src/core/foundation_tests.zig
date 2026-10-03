const std = @import("std");

test {
    std.testing.refAllDecls(@import("config.zig"));
    std.testing.refAllDecls(@import("instances.zig"));
    std.testing.refAllDecls(@import("tasks.zig"));
    std.testing.refAllDecls(@import("logs.zig"));
    std.testing.refAllDecls(@import("lifecycle.zig"));
}

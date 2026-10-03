const std = @import("std");
test {
    std.testing.refAllDecls(@import("ui/java_download_controller.zig"));
    std.testing.refAllDecls(@import("ui/java_download_view.zig"));
}
comptime {
    const view = @import("ui/java_download_view.zig");
    _ = &view.draw;
    _ = &view.finish;
}

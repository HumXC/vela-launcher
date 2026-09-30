const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 800.0, .h = 600.0 },
            .min_size = .{ .w = 250.0, .h = 350.0 },
            .title = "DVUI App Example",
            .window_init_options = .{
                .keybinds_zoom = true,
            },
        },
    },
    .frameFn = frame,
    .initFn = init,
    .deinitFn = deinit,
};
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

pub fn init(win: *dvui.Window) !void {
    _ = win;
}

pub fn deinit(win: *dvui.Window) void {
    _ = win;
}

pub fn frame() !dvui.App.Result {
    return .ok;
}

test {
    _ = @import("core/root.zig");
}

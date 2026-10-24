//! Render-command regressions for the shared surface pipeline, exercised through real controls.
const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme.zig");
const surface = @import("surface.zig");
const components = @import("components.zig");
const background = @import("background_image.zig");

const Frame = struct {
    var radius: f32 = 20;
    var opacity: u8 = 80;
    var blur: u8 = 16;
    var focus_only = false;
    var pixel: [1]dvui.Color.PMA = .{.{ .r = 120, .g = 180, .b = 210, .a = 255 }};
    var empty: [0]u8 = .{};
    var image: background.Image = .{ .bytes = &empty, .path = &empty, .width = 1, .height = 1, .pixels = @splat(&pixel), .digest = @splat(0), .extension = "png" };
    var fills: usize = 0;
    var rounded_images: usize = 0;
    var visible_strokes: usize = 0;

    fn draw() !dvui.App.Result {
        const win = dvui.currentWindow();
        theme.install(win);
        const settings: @import("../core/appearance.zig").Settings = .{ .background_mode = .image, .corner_radius = @intFromFloat(radius), .panel_opacity = opacity, .panel_blur = blur, .image_dimming = 20 };
        theme.applyAppearance(settings);
        defer theme.applyAppearance(.{});
        theme.setPanelBackdrop(&image, settings, dvui.windowRectScale());
        defer theme.setPanelBackdrop(null, .{}, .{ .r = .{}, .s = 1 });
        var commands: std.ArrayList(dvui.RenderCommand) = .empty;
        defer commands.deinit(win.arena());
        const previous_commands = win.defer_render_cmds;
        const previous_after = win.defer_render_cmds_after;
        const previous_rendering = win.render_target.rendering;
        win.defer_render_cmds = &commands;
        win.defer_render_cmds_after = &commands;
        win.render_target.rendering = false;
        defer {
            win.defer_render_cmds = previous_commands;
            win.defer_render_cmds_after = previous_after;
            win.render_target.rendering = previous_rendering;
        }
        {
            const root = dvui.box(@src(), .{}, .{ .expand = .both, .padding = .all(16), .background = false });
            defer root.deinit();
            if (focus_only) {
                var button: dvui.ButtonWidget = undefined;
                button.init(@src(), .{}, .{ .rect = .{ .w = 160, .h = 64 }, .border = .all(1), .corners = .all(12), .background = true });
                defer button.deinit();
                dvui.focusWidget(button.data().id, null, null);
                surface.buttonBackground(&button);
            } else {
                const panel = components.bentoPanel(@src(), .{ .min_size_content = .height(60) });
                panel.deinit();
                const section = components.modalSection(@src(), .{ .min_height = 60 });
                section.deinit();
                _ = components.button(@src(), "Action", .{});
                _ = components.sidebarAction(@src(), "surface-nav", "Navigation", .{});
                _ = components.selectionCard(@src(), "surface-card", "Selection", .{ .width = 240, .height = 64, .selected = true });
                _ = surface.image(@src(), .{ .source = image.source(0) }, .{ .min_size_content = .all(32), .corners = .all(12), .padding = .all(0) });
            }
        }
        fills = 0;
        rounded_images = 0;
        visible_strokes = 0;
        for (commands.items) |command| switch (command.cmd) {
            .pathFillConvex => |fill| {
                fills += 1;
                if (fill.path.points.len > 4) {
                    try std.testing.expectEqual(@as(f32, 1), fill.opts.fade);
                } else {
                    try std.testing.expect(fill.opts.fade == 0 or fill.opts.fade == 1);
                }
            },
            .texture => |texture| {
                if (texture.opts.corners.tl.radius() > 0) {
                    rounded_images += 1;
                    try std.testing.expectEqual(@as(f32, 1), texture.opts.fade);
                    try std.testing.expectEqual(dvui.Corner.Physical.Style.round, texture.opts.corners.tl.kind);
                }
            },
            .pathStroke => |stroke| {
                if (stroke.opts.color.toColor().a > 0) {
                    visible_strokes += 1;
                    if (focus_only) {
                        try std.testing.expectApproxEqAbs(2 * dvui.windowNaturalScale(), stroke.opts.thickness, 0.01);
                        try std.testing.expect(stroke.path.points.len > 4);
                    }
                }
            },
            else => {},
        };
        return .ok;
    }
};

test "UI layout surface panels controls and images keep antialiased edges across materials and scales" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    Frame.focus_only = false;
    for ([_]f32{ 1, 2 }) |scale| {
        var window = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 900 } });
        defer window.deinit();
        window.backend.size_pixels = .{ .w = 600 * scale, .h = 900 * scale };
        for ([_]f32{ 0, 12, 28 }) |radius| {
            Frame.radius = radius;
            for ([_]u8{ 60, 100 }) |opacity| {
                Frame.opacity = opacity;
                for ([_]u8{ 0, 16 }) |blur| {
                    Frame.blur = blur;
                    try dvui.testing.settle(Frame.draw);
                    try std.testing.expect(Frame.fills >= 6);
                    try std.testing.expect(Frame.rounded_images >= 1);
                }
            }
        }
    }
}

test "UI layout surface keyboard focus draws one rounded contour instead of border plus focus ring" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    var window = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 400 } });
    defer window.deinit();
    Frame.focus_only = true;
    defer Frame.focus_only = false;
    try dvui.testing.settle(Frame.draw);
    try std.testing.expectEqual(@as(usize, 1), Frame.visible_strokes);
}

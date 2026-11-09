//! Native SDL pixel regression; the lightweight testing backend does not rasterize.
const std = @import("std");
const dvui = @import("dvui");
const theme = @import("ui/theme.zig");
const surface = @import("ui/surface.zig");
const background = @import("ui/background_image.zig");

pub const dvui_app: dvui.App = .{ .config = .{ .startFn = start }, .initFn = @import("ui/fonts.zig").install, .frameFn = frame };
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };
var pixel: [1]dvui.Color.PMA = .{.{ .r = 200, .g = 210, .b = 220, .a = 255 }};
var empty: [0]u8 = .{};
var image: background.Image = .{ .bytes = &empty, .path = &empty, .width = 1, .height = 1, .pixels = @splat(&pixel), .digest = @splat(0), .extension = "png" };

fn checkControlFills() !void {
    const win = dvui.currentWindow();
    for ([_]u8{ 60, 80, 100 }) |opacity| {
        theme.applyAppearance(.{ .panel_opacity = opacity });
        theme.setPanelBackdrop(null, .{}, dvui.windowRectScale());
        var picture = dvui.Picture.start(.{ .w = 768, .h = 320 }) orelse return error.MissingTextureTarget;
        defer picture.texture.destroyLater();
        surface.fill(.{ .r = picture.r, .s = 1 }, .{}, .{ .color = dvui.Color.white });
        const options = theme.controlOptions(20).override(.{
            .id_extra = opacity,
            .rect = .{ .x = 20, .y = 20, .w = 200, .h = 48 },
            .margin = .all(0),
            .tab_index = 0,
        });
        var buffer: [16]u8 = @splat(0);
        var entry: dvui.TextEntryWidget = undefined;
        entry.init(@src(), .{ .text = .{ .buffer = &buffer } }, options);
        entry.draw();
        entry.deinit();
        var button: dvui.ButtonWidget = undefined;
        button.init(@src(), .{ .draw_focus = false }, options.override(.{ .rect = .{ .x = 20, .y = 100, .w = 200, .h = 48 } }));
        theme.buttonBackground(&button, .{});
        button.deinit();
        var choice: usize = 0;
        _ = dvui.dropdown(@src(), &.{""}, .{ .choice = &choice }, .{}, options.override(.{ .rect = .{ .x = 20, .y = 180, .w = 200, .h = 48 } }));
        picture.stop();
        const pixels = try dvui.textureReadTarget(win.lifo(), picture.texture);
        defer win.lifo().free(pixels);
        const width: usize = picture.texture.width;
        const reference = pixels[44 * width + 100];
        for ([_]usize{ 124, 204 }) |y| {
            const actual = pixels[y * width + 100];
            inline for (.{ "r", "g", "b", "a" }) |channel| {
                if (@abs(@as(i32, @field(reference, channel)) - @as(i32, @field(actual, channel))) > 1) {
                    std.log.err("control fill mismatch opacity={} y={}: entry={} actual={}", .{ opacity, y, reference, actual });
                    return error.ControlFillMismatch;
                }
            }
        }
    }
    std.debug.print("control fills: input, button and dropdown match at 60/80/100 percent opacity\n", .{});
}

fn start() dvui.App.StartOptions {
    return .{ .size = .{ .w = 768, .h = 320 }, .min_size = .{ .w = 768, .h = 320 }, .title = "Vela surface pixel regression", .vsync = false, .persist_window_geometry = false };
}

fn frame() !dvui.App.Result {
    const win = dvui.currentWindow();
    theme.install(win);
    const previous_scale = win.natural_scale;
    defer win.natural_scale = previous_scale;
    defer theme.applyAppearance(.{});
    defer theme.setPanelBackdrop(null, .{}, .{ .r = .{}, .s = 1 });
    try checkControlFills();
    var cases: usize = 0;
    var edge_samples: usize = 0;
    var maximum_error: f32 = 0;
    for ([_]f32{ 1, 2 }) |scale| {
        win.natural_scale = scale;
        for ([_]f32{ 12, 28 }) |radius| {
            for ([_]u8{ 60, 80, 100 }) |opacity| {
                for ([_]u8{ 0, 16 }) |blur| {
                    const settings: @import("core/appearance.zig").Settings = .{ .preset = .mist, .background_mode = .image, .corner_radius = @intFromFloat(radius), .panel_opacity = opacity, .panel_blur = blur, .image_dimming = 20 };
                    theme.applyAppearance(settings);
                    theme.setPanelBackdrop(&image, settings, dvui.windowRectScale());
                    for ([_]f32{ 0, 0.25, 0.5, 0.75 }) |phase| {
                        for ([_]f32{ 1, 0.65 }) |alpha| {
                            for ([_]u2{ 0, 1, 2 }) |kind| {
                                const button_case = kind == 1;
                                const image_case = kind == 2;
                                if (image_case and (opacity != 60 or blur != 16)) continue;
                                var picture = dvui.Picture.start(.{ .w = 768, .h = 320 }) orelse return error.MissingTextureTarget;
                                defer picture.texture.destroyLater();
                                surface.fill(.{ .r = picture.r, .s = 1 }, .{}, .{ .color = dvui.Color.white });
                                const options: dvui.Options = .{ .id_extra = cases, .rect = .{ .x = 16 + phase / scale, .y = 16 + phase / scale, .w = 128, .h = 128 }, .border = .all(0), .padding = .all(0), .margin = .all(0), .corners = .all(radius), .background = true, .color_fill = .{ .color = theme.panelColor(theme.colors.surface) }, .tab_index = 0 };
                                const previous_alpha = dvui.alpha(alpha);
                                var region: dvui.RectScale = undefined;
                                if (image_case) {
                                    region = .{ .r = options.rect.?.scale(scale, dvui.Rect.Physical), .s = scale };
                                    try surface.renderImage(image.source(0), region, .{ .corners = .all(radius) });
                                } else if (button_case) {
                                    var button: dvui.ButtonWidget = undefined;
                                    button.init(@src(), .{ .draw_focus = false }, options);
                                    region = button.data().backgroundRectScale();
                                    theme.buttonBackground(&button, .{ .material = true });
                                    button.deinit();
                                } else {
                                    const panel = theme.panel(@src(), .{}, options);
                                    region = panel.data().backgroundRectScale();
                                    panel.deinit();
                                }
                                dvui.alphaSet(previous_alpha);
                                if (@abs(region.s - scale) > 0.001) return error.InvalidProbeScale;
                                var reference = region;
                                reference.r.x += 192 * scale;
                                surface.fill(reference, .all(radius), .{ .color = dvui.Color.black });
                                picture.stop();
                                const pixels = try dvui.textureReadTarget(win.lifo(), picture.texture);
                                defer win.lifo().free(pixels);
                                const width: usize = picture.texture.width;
                                const center_x: usize = @intFromFloat(region.r.x + region.r.w / 2);
                                const center_y: usize = @intFromFloat(region.r.y + region.r.h / 2);
                                const center = pixels[center_y * width + center_x];
                                const shift: usize = @intFromFloat(192 * scale);
                                const xmax: usize = @intFromFloat(176 * scale);
                                const ymax: usize = @intFromFloat(160 * scale);
                                var samples: usize = 0;
                                for (0..ymax) |y| {
                                    for (0..xmax) |x| {
                                        const ref = pixels[y * width + x + shift];
                                        if (ref.r == 0 or ref.r == 255) continue;
                                        const coverage = 1 - @as(f32, @floatFromInt(ref.r)) / 255;
                                        const actual = pixels[y * width + x];
                                        if (actual.a != 255) {
                                            std.log.err("surface replaced opaque background alpha at {},{}: actual={}", .{ x, y, actual });
                                            return error.SurfaceAlphaMismatch;
                                        }
                                        inline for (.{ "r", "g", "b" }) |channel| {
                                            const expected = 255 * (1 - coverage) + @as(f32, @floatFromInt(@field(center, channel))) * coverage;
                                            const error_amount = @abs(@as(f32, @floatFromInt(@field(actual, channel))) - expected);
                                            maximum_error = @max(maximum_error, error_amount);
                                            if (error_amount > 3) {
                                                std.log.err("surface pixel mismatch button={} scale={d} radius={d} opacity={} blur={} phase={d} alpha={d} at {},{}: actual={} center={} reference={} error={d}", .{ button_case, scale, radius, opacity, blur, phase, alpha, x, y, actual, center, ref, error_amount });
                                                return error.SurfaceCoverageMismatch;
                                            }
                                        }
                                        samples += 1;
                                    }
                                }
                                if (samples < 16) return error.MissingEdgeSamples;
                                edge_samples += samples;
                                cases += 1;
                            }
                        }
                    }
                }
            }
        }
    }
    std.debug.print("surface pixels: {} cases, {} edge samples, maximum channel error {d:.2}/255\n", .{ cases, edge_samples, maximum_error });
    return .close;
}

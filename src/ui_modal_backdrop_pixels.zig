//! Native regression of production modal ordering, configuration, and lower-window capture.
const std = @import("std");
const dvui = @import("dvui");
const theme = @import("ui/theme.zig");
const components = @import("ui/components.zig");
const surface = @import("ui/surface.zig");
const appearance = @import("core/appearance.zig");
pub const dvui_app: dvui.App = .{ .config = .{ .startFn = start }, .initFn = @import("ui/fonts.zig").install, .frameFn = frame };
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };
var tick: usize = 0;
var baseline: f32 = 0;
var previous_mean: f32 = 0;
fn start() dvui.App.StartOptions {
    return .{ .size = .{ .w = 768, .h = 500 }, .min_size = .{ .w = 768, .h = 500 }, .title = "Vela modal backdrop pixels", .vsync = false, .persist_window_geometry = false };
}
fn stripes(rect: dvui.Rect.Physical, blue: bool, changed: bool) void {
    var x = rect.x;
    while (x < rect.x + rect.w) : (x += 4) {
        const light = @mod(@as(i32, @intFromFloat(x - rect.x)), 8) == 0;
        const value: u8 = if (light) 255 else 0;
        const col: dvui.Color = if (blue) .{ .r = 0, .g = 0, .b = value, .a = 255 } else if (changed) .{ .r = value, .g = 0, .b = 0, .a = 255 } else .{ .r = value, .g = value, .b = value, .a = 255 };
        surface.fill(.{ .r = .{ .x = x, .y = rect.y, .w = @min(4, rect.x + rect.w - x), .h = rect.h }, .s = 1 }, .{}, .{ .color = col });
    }
}
fn frame() !dvui.App.Result {
    const win = dvui.currentWindow();
    theme.install(win);
    const scenario = tick / 3;
    // Whole-app scale exercises the same physical/logical mapping as 2x DPI;
    // begin() picks this up next frame. Keep the native pixel target unchanged.
    if (scenario >= 8) win.content_scale = 2;
    const changing = if (scenario >= 8) tick % 2 == 1 else scenario == 7;
    const strength: u8 = switch (scenario) {
        0 => 0,
        1 => 4,
        2 => 8,
        else => 16,
    };
    const settings: appearance.Settings = .{ .panel_opacity = if (scenario == 5) 100 else 60, .panel_blur = strength, .background_mode = if (scenario == 4) .image else .solid, .corner_radius = 20 };
    theme.applyAppearance(settings);
    theme.setPanelBackdrop(null, settings, dvui.windowRectScale());
    const nested = scenario == 6;
    var lower: ?*dvui.FloatingWindowWidget = null;
    if (nested) {
        lower = components.modalPanel(@src(), "Lower", 400, null);
        stripes(lower.?.data().rectScale().r, true, false);
    }
    const modal = components.modalPanel(@src(), "Probe", 280, null);
    const region = modal.data().rectScale().r;
    const region_scale = modal.data().rectScale().s;
    const expected_x = (dvui.windowRectPixels().w - region.w) / 2;
    if (@abs(region.x - expected_x) > 1) return error.ModalNotCentered;
    if (!modal.drag_area.empty()) return error.ModalDraggable;
    // This foreground must remain perfectly sharp and must not be captured by itself.
    const marker: dvui.Rect.Physical = .{ .x = region.x + region.w / 2 - 8, .y = region.y + 40, .w = 16, .h = 16 };
    surface.fill(.{ .r = marker, .s = 1 }, .{}, .{ .color = .{ .r = 255, .g = 0, .b = 0 } });
    modal.deinit();
    if (lower) |parent| parent.deinit();
    // Deliberately late build: this is still underneath both deferred subwindows.
    stripes(dvui.windowRectPixels(), false, changing);
    win.endRendering(.{ .show_toasts = false });
    const width: usize = @intFromFloat(dvui.windowRectPixels().w);
    const height: usize = @intFromFloat(dvui.windowRectPixels().h);
    const bytes = try win.gpa.alloc(u8, width * height * 4);
    defer win.gpa.free(bytes);
    try win.backend.readPixels(dvui.windowRectPixels(), bytes.ptr);
    if (tick % 3 == 2 or scenario >= 9) {
        const scan_y: usize = @intFromFloat(region.y + region.h / 2);
        const scan_x: usize = @intFromFloat(region.x + 64);
        var lo: u8 = 255;
        var hi: u8 = 0;
        var red: u32 = 0;
        var blue: u32 = 0;
        for (scan_x..scan_x + 128) |x| {
            const i = (scan_y * width + x) * 4;
            lo = @min(lo, bytes[i]);
            hi = @max(hi, bytes[i]);
            red += bytes[i];
            blue += bytes[i + 2];
        }
        const contrast: f32 = @floatFromInt(hi - lo);
        const mean_blue = @as(f32, @floatFromInt(blue)) / 128;
        if (scenario == 0) {
            baseline = contrast;
            if (baseline < 30) return error.MissingSharpBackground;
        } else if (contrast > baseline * 0.2) {
            std.log.err("scenario {} contrast {d} baseline {d}", .{ scenario, contrast, baseline });
            return error.BackdropDidNotBlurLateContent;
        }
        if (scenario == 6 and blue <= red + 1000) {
            std.log.err("nested red={} blue={} region={}", .{ red, blue, region });
            return error.NestedBackdropMissedLowerWindow;
        }
        if (scenario == 7 and mean_blue >= previous_mean - 5) return error.BackdropReusedStalePixels;
        if (scenario == 4) previous_mean = mean_blue;
        const marker_i = (@as(usize, @intFromFloat(marker.y + 8)) * width + @as(usize, @intFromFloat(marker.x + 8))) * 4;
        if (bytes[marker_i] < 250 or bytes[marker_i + 1] > 3) return error.ModalForegroundBlurred;
        const stats = &win.deferred_backdrop;
        if (stats.blur_pixels > stats.used * 512 * 512) return error.UnboundedBackdropResolution;
        if (scenario != 0 and scenario != 5) {
            if (stats.used == 0 or stats.blur_pixels == 0) return error.BackdropNotRendered;
            if (stats.read_pixels < stats.blur_pixels * 3) return error.BackdropNotDownsampled;
            if (tick % 3 == 2 and stats.texture_creates != 0) return error.BackdropTextureNotReused;
        }
        if (scenario >= 9) {
            if (region_scale < 1.9) return error.HighDpiScenarioNotScaled;
            if (changing and mean_blue >= previous_mean - 5) return error.DynamicBackdropFrozen;
            if (!changing and mean_blue <= previous_mean + 5) return error.DynamicBackdropFrozen;
        }
        if (scenario >= 8) previous_mean = mean_blue;
        std.debug.print("modal backdrop scenario {}: contrast={d:.1}, mean blue={d:.1}, read={} blur={} tex-create={}\n", .{ scenario, contrast, mean_blue, stats.read_pixels, stats.blur_pixels, stats.texture_creates });
    }
    tick += 1;
    if (tick == 36) return .close;
    dvui.refresh(null, @src(), null);
    return .ok;
}

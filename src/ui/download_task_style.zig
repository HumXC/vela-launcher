//! Shared presentation for resource and modpack download tasks.
const std = @import("std");
const dvui = @import("dvui");
const components = @import("components.zig");
const theme = @import("theme.zig");
pub const modal_height: f32 = 560;
pub const Layout = struct {
    width: f32,
    footer_y: f32,
    compact: bool,
    body_y: f32,
    hint_y: f32,
    pub fn current() Layout {
        const rect = dvui.parentGet().data().contentRect();
        const footer_y = @max(0, rect.h - 48);
        const compact = rect.h < 440;
        return .{ .width = rect.w, .footer_y = footer_y, .compact = compact, .body_y = if (compact) 124 else 152, .hint_y = if (compact) footer_y else @max(152, footer_y - 72) };
    }
};
pub fn text(src: std.builtin.SourceLocation, value: []const u8, font: dvui.Font, rect: dvui.Rect, color: dvui.Color) void {
    dvui.labelNoFmt(src, components.ellipsize(value, font, @max(0, rect.w)), .{}, .{ .rect = rect, .font = font, .padding = .all(0), .margin = .all(0), .background = false, .color_text = .{ .color = color } });
}
pub fn fileCard(index: usize, title: []const u8, subtitle: []const u8, status: []const u8, percent: f32, color: dvui.Color, tag: []const u8) void {
    const row = components.bentoPanel(@src(), .{ .id_extra = index, .expand = .horizontal, .min_size_content = .height(72), .max_size_content = .width(0), .padding = .all(15), .margin = .{ .y = if (index == 0) 0 else 12 }, .corners = .all(theme.cardRadius()), .color_fill = .{ .color = theme.style.colors.inset }, .color_border = .{ .color = theme.colors.outline } });
    defer row.deinit();
    const width = row.data().contentRect().w;
    const badge_width = @min(148, width * 0.4);
    text(@src(), title, theme.headingFont(), .{ .w = @max(0, width - badge_width - 16), .h = 28 }, theme.colors.foreground);
    text(@src(), subtitle, theme.fontSized(14), .{ .y = 32, .w = width, .h = 24 }, theme.colors.muted);
    {
        const badge = dvui.box(@src(), .{}, .{ .rect = .{ .x = width - badge_width, .y = -4, .w = badge_width, .h = 32 }, .padding = .{ .x = 7, .w = 7, .y = 4, .h = 4 }, .margin = .all(0), .border = .all(1), .corners = .all(theme.controlRadius()), .background = true, .color_fill = .{ .color = theme.style.colors.inset }, .color_border = .{ .color = theme.colors.outline } });
        defer badge.deinit();
        dvui.labelNoFmt(@src(), status, .{}, .{ .font = theme.fontSized(14), .padding = .all(0), .margin = .all(0), .gravity_x = 0.5, .gravity_y = 0.5, .color_text = .{ .color = color } });
    }
    dvui.progress(@src(), .{ .percent = percent, .color = color }, .{ .rect = .{ .y = 64, .w = width, .h = 8 }, .min_size_content = .height(8), .padding = .all(0), .margin = .all(0), .corners = .all(4), .tag = tag });
}

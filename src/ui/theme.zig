const dvui = @import("dvui");
const fonts = @import("fonts.zig");
/// Compatibility facade for existing callers; style.zig is the single token source.
pub const style = @import("style.zig");
pub const background = style.colors.background;
pub const surface = style.colors.surface;
pub const sidebar = style.colors.sidebar;
pub const selected_surface = style.colors.selected_surface;
pub const outline = style.colors.outline;
pub const control_outline = style.colors.control_outline;
pub const foreground = style.colors.foreground;
pub const muted = style.colors.muted;
pub const accent = style.colors.accent;
pub const selected_text = style.colors.selected_text;
pub const danger = style.colors.danger;
pub const warning = style.colors.warning;
pub const typography = style.typography;
pub const spacing = style.spacing;
pub const sizing = style.sizing;

pub fn bodyFont() dvui.Font {
    return dvui.themeGet().font_body;
}

pub fn headingFont() dvui.Font {
    return dvui.themeGet().font_heading;
}

pub fn titleFont() dvui.Font {
    return dvui.themeGet().font_title;
}

/// Design sizes are EM pixels; DVUI stores the rendered capital-M height.
/// Convert through the active face, independently of its line spacing or CJK ascent.
fn fontForPixels(base: dvui.Font, pixels: f32) dvui.Font {
    const reference = base.withSize(100);
    const entry = dvui.fontCacheGet(reference) catch return base.withSize(pixels);
    const m_per_em: f32 = if (dvui.useFreeType)
        entry.em_height / @as(f32, @floatFromInt(@max(1, entry.face.*.size.*.metrics.y_ppem)))
    else
        entry.em_height / entry.scaleFactor * dvui.c.stbtt_ScaleForMappingEmToPixels(&entry.face, 1);
    return reference.withSize(pixels * m_per_em);
}

pub fn fontSized(pixels: f32) dvui.Font {
    return fontForPixels(bodyFont(), pixels);
}

pub fn captionFont() dvui.Font {
    return fontSized(typography.caption);
}

pub fn monoFont() dvui.Font {
    return fontForPixels(dvui.Font.theme(.mono), typography.mono).withLineHeight(typography.mono_line_height);
}

/// Called inside a frame, after DVUI establishes the active font cache.
pub fn applyTypography() void {
    var value = dvui.themeGet();
    value.font_body = fontForPixels(value.font_body, typography.body);
    value.font_heading = fontForPixels(value.font_heading, typography.heading);
    value.font_title = fontForPixels(value.font_title, typography.title);
    dvui.currentWindow().themeSet(value);
}

pub const ControlGeometry = struct {
    content: dvui.Size,
    padding: dvui.Rect,
};

/// Outer dimensions include borders, but exclude margins. Text remains full size;
/// only the vertical inset contracts when fallback fonts have taller line metrics.
pub fn controlGeometry(line_height: f32, outer_height: f32, outer_width: f32, horizontal_padding: f32, border: f32) ControlGeometry {
    const inset_y = @min(sizing.control_padding_y, @max(0, (outer_height - 2 * border - line_height) / 2));
    return .{
        .content = .{ .w = @max(0, outer_width - 2 * (horizontal_padding + border)), .h = @max(0, outer_height - 2 * (inset_y + border)) },
        .padding = .{ .x = horizontal_padding, .w = horizontal_padding, .y = inset_y, .h = inset_y },
    };
}

/// TextEntry expands its TextLayout, so center the actual glyph and caret
/// with padding instead of reserving the line leading used by wrapping text.
pub fn textEntryGeometry(text_height: f32, outer_width: f32) ControlGeometry {
    const inset_y = @max(0, (sizing.control_height - 2 * sizing.control_border - text_height) / 2);
    return .{
        .content = .{ .w = @max(0, outer_width - 2 * (sizing.control_padding_x + sizing.control_border)), .h = @max(0, sizing.control_height - 2 * (inset_y + sizing.control_border)) },
        .padding = .{ .x = sizing.control_padding_x, .w = sizing.control_padding_x, .y = inset_y, .h = inset_y },
    };
}

pub fn controlOptions(line_height: f32) dvui.Options {
    const geometry = controlGeometry(line_height, sizing.control_height, 0, sizing.control_padding_x, sizing.control_border);
    return .{
        .font = bodyFont(),
        .min_size_content = geometry.content,
        .padding = geometry.padding,
        .border = .all(sizing.control_border),
        .corners = .all(sizing.control_radius),
    };
}

/// Both footer actions use this width, including in narrow panes.
pub fn footerButtonWidth(available_width: f32) f32 {
    return @min(sizing.footer_width, @max(0, (available_width - sizing.group_gap) / 2));
}

/// Long loader labels borrow horizontal inset rather than wrapping or shrinking.
pub fn footerButtonOptions(label: []const u8, outer_width: f32) dvui.Options {
    const font = bodyFont();
    const text_size = font.textSize(label);
    const inset_x = @min(sizing.control_padding_x, @max(0, (outer_width - 2 * sizing.control_border - text_size.w) / 2));
    const geometry = controlGeometry(@max(font.lineHeight(), text_size.h), sizing.control_height, outer_width, inset_x, sizing.control_border);
    return controlOptions(@max(font.lineHeight(), text_size.h)).override(.{
        .min_size_content = geometry.content,
        .padding = geometry.padding,
        .margin = .all(0),
    });
}

/// Filters have no generic button minimum width. Reduce only horizontal inset
/// and the inter-item gap so the measured labels fit the available track.
pub const FilterGeometry = struct { padding_x: f32, gap: f32 };

pub fn filterGeometry(available_width: f32, labels: []const []const u8) FilterGeometry {
    const count: f32 = @floatFromInt(labels.len);
    if (count == 0) return .{ .padding_x = 0, .gap = 0 };
    var text_width: f32 = 0;
    for (labels) |label| text_width += bodyFont().textSize(label).w;
    const spare = @max(0, available_width - text_width - 2 * sizing.control_border * count);
    const gap = @min(sizing.row_gap, spare / (3 * count));
    return .{ .gap = gap, .padding_x = @min(sizing.control_padding_x, @max(0, (spare - gap * count) / (2 * count))) };
}

pub fn install(win: *dvui.Window) void {
    // Hover and unhover colors switch immediately without DVUI interpolation.
    dvui.hover_fade_secs = 0;
    var value = dvui.Theme.builtin.adwaita_dark;
    value.name = "Vela";
    value.fill = background;
    value.text = foreground;
    value.border = control_outline;
    value.focus = selected_text;
    value.window = .{ .fill = surface };
    value.control = .{ .fill = surface, .fill_hover = selected_surface, .fill_press = style.colors.pressed_surface };
    value.highlight = .{ .fill = accent, .text = style.colors.on_accent };
    value.font_body = .find(.{ .family = fonts.family, .size = typography.body, .line_height_factor = typography.body_line_height });
    value.font_heading = value.font_body.withSize(typography.heading);
    value.font_title = value.font_body.withSize(typography.title);
    win.themeSet(value);
}

const dvui = @import("dvui");
const fonts = @import("fonts.zig");
const appearance = @import("../core/appearance.zig");
const background = @import("background_image.zig");
pub const surface = @import("surface.zig");
pub const style = @import("style.zig");
pub const colors = &style.colors;
pub const typography = style.typography;
pub const spacing = style.spacing;
pub const sizing = style.sizing;

var backdrop_image: ?*background.Image = null;
var backdrop_settings: appearance.Settings = .{};
var backdrop_screen: dvui.RectScale = .{ .r = .{}, .s = 1 };

/// Frame-borrowed image; the editor retains its pixels until rendering finishes.
pub fn setPanelBackdrop(image: ?*background.Image, settings: appearance.Settings, screen: dvui.RectScale) void {
    backdrop_image = image;
    backdrop_settings = settings;
    backdrop_screen = screen;
}

/// Install a panel before painting its background, so material coverage is applied once.
pub fn panel(src: @import("std").builtin.SourceLocation, init_options: dvui.BoxWidget.InitOptions, options: dvui.Options) *dvui.BoxWidget {
    const widget = dvui.widgetAlloc(dvui.BoxWidget);
    widget.init(src, init_options, options);
    panelBackground(widget.data(), .{});
    return widget;
}

fn hasBackdrop(data: *dvui.WidgetData) bool {
    return backdrop_image != null and backdrop_settings.panel_blur > 0 and backdrop_settings.panel_opacity < 100 and backdrop_settings.background_mode == .image and data.visible() and (data.options.background orelse false);
}

/// Material fill only; the owner paints its border/focus exactly once.
pub fn panelFill(data: *dvui.WidgetData, state: dvui.Options) void {
    if (!data.visible()) return;
    const region = data.backgroundRectScale();
    const corners = data.options.cornersGet();
    const color = state.color_fill orelse data.options.color(.fill);
    if (!hasBackdrop(data)) {
        surface.fill(region, corners, color);
        return;
    }
    var material = surface.Material.start(region, corners) orelse {
        surface.fill(region, corners, color);
        return;
    };
    defer material.finish();
    var settings = backdrop_settings;
    settings.image_blur = @max(settings.image_blur, settings.panel_blur);
    background.drawRegion(backdrop_image.?, settings, backdrop_screen, material.bounds(), .{});
    surface.fill(material.bounds(), .{}, color);
}

pub fn panelBackground(data: *dvui.WidgetData, state: dvui.Options) void {
    if (!hasBackdrop(data)) {
        data.borderAndBackground(.{ .fill_color = state.color_fill });
        return;
    }
    data.borderAndBackground(.{ .fill_color = .{ .color = dvui.Color.transparent } });
    panelFill(data, state);
}

pub fn buttonBackground(button: *dvui.ButtonWidget, options: struct { material: bool = false }) void {
    const data = button.data();
    if (!options.material or !hasBackdrop(data)) {
        surface.buttonBackground(button);
        return;
    }
    const original_border = data.options.color_border;
    data.options.color_border = .{ .color = dvui.Color.transparent };
    data.borderAndBackground(.{ .fill_color = .{ .color = dvui.Color.transparent } });
    data.options.color_border = original_border;
    panelFill(data, button.style());
    surface.buttonOutline(button);
}

/// Draw a single resolved contour for uniform-radius cards; focus shares selection emphasis.
pub fn drawCardOutline(data: *dvui.WidgetData, active: bool) void {
    surface.outline(data, if (active) 2 else data.options.borderGet().x, .{ .color = if (active) colors.accent else colors.outline });
}

/// Foreground content inherits font and text state, never the parent's fill.
/// TextLayout renders explicit color_fill behind each run even with background=false.
pub fn foregroundOptions(base: dvui.Options) dvui.Options {
    var result = base;
    result.background = false;
    result.color_fill = null;
    result.color_fill_hover = null;
    result.color_fill_press = null;
    return result;
}

test "foreground style clears run backgrounds while preserving text state" {
    const testing = @import("std").testing;
    const base: dvui.Options = .{
        .background = true,
        .style = .highlight,
        .color_fill = .{ .color = dvui.Color.white },
        .color_fill_hover = .{ .color = dvui.Color.black },
        .color_fill_press = .{ .color = dvui.Color.white },
        .color_text = .{ .color = dvui.Color.black },
    };
    const actual = foregroundOptions(base);
    try testing.expectEqual(false, actual.background.?);
    try testing.expect(actual.color_fill == null);
    try testing.expect(actual.color_fill_hover == null);
    try testing.expect(actual.color_fill_press == null);
    try testing.expectEqual(base.color_text, actual.color_text);
    try testing.expectEqual(base.style, actual.style);
    try testing.expect(base.color_fill != null);
}

/// Independent solid-palette buttons use panel strength; active accents stay solid.
pub fn panelButtonOptions(base: dvui.Options, preserve_accent: bool) dvui.Options {
    if (preserve_accent) return base;
    return base.override(.{
        .color_fill = .{ .color = panelColor(base.color(.fill).toColor()) },
        .color_fill_hover = .{ .color = panelColor(base.color(.fill_hover).toColor()) },
        .color_fill_press = .{ .color = panelColor(base.color(.fill_press).toColor()) },
    });
}

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
        .style = .control,
        .font = bodyFont(),
        .min_size_content = geometry.content,
        .padding = geometry.padding,
        .border = .all(sizing.control_border),
        .corners = .all(controlRadius()),
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

var current_radius: f32 = 12;
var current_panel_opacity: u8 = 100;

pub fn controlRadius() f32 {
    return current_radius;
}
pub fn cardRadius() f32 {
    return if (current_radius == 0) 0 else current_radius + 4;
}
pub fn panelRadius() f32 {
    return if (current_radius == 0) 0 else current_radius + 8;
}
pub fn sidebarRadius() f32 {
    return if (current_radius == 0) 0 else current_radius + 12;
}
pub fn modalRadius() f32 {
    return sidebarRadius();
}

pub fn panelColor(base: dvui.Color) dvui.Color {
    var result = base;
    // Palette surfaces already carry inner-control alpha. An outer panel uses
    // the original swatch at its own opacity, rather than multiplying it again.
    result.a = 255;
    return style.materialColor(result, current_panel_opacity, .panel);
}

fn applyColors(value: *dvui.Theme) void {
    value.fill = colors.background;
    value.text = colors.foreground;
    value.border = colors.control_outline;
    value.focus = colors.selected_text;
    value.window = .{ .fill = panelColor(colors.background) };
    value.control = .{ .fill = colors.surface, .fill_hover = colors.selected_surface, .fill_press = colors.pressed_surface };
    value.highlight = .{ .fill = colors.accent, .text = colors.on_accent };
}

pub fn applyAppearance(settings: appearance.Settings) void {
    backdrop_image = null;
    style.colors = style.Palette.fromSettings(settings);
    current_radius = @floatFromInt(settings.corner_radius);
    current_panel_opacity = settings.panel_opacity;
    var value = dvui.themeGet();
    value.dark = settings.preset != .frost;
    applyColors(&value);
    dvui.currentWindow().themeSet(value);
}

pub fn install(win: *dvui.Window) void {
    style.colors = style.Palette.fromSettings(.{});
    current_radius = 12;
    current_panel_opacity = 100;
    dvui.hover_fade_secs = 0;
    var value = dvui.Theme.builtin.adwaita_dark;
    value.name = "Vela";
    applyColors(&value);
    value.font_body = .find(.{ .family = fonts.family, .size = typography.body, .line_height_factor = typography.body_line_height });
    value.font_heading = value.font_body.withSize(typography.heading);
    value.font_title = value.font_body.withSize(typography.title);
    win.themeSet(value);
}

//! Launcher appearance values; independent of the renderer and game configuration.
const std = @import("std");

pub const Preset = enum { moss, mist, graphite, sunset, violet, frost };
pub const BackgroundMode = enum { solid, image };
pub const ImageLayout = enum { fill, fit, stretch };
pub const presets = [_]Preset{ .moss, .mist, .graphite, .sunset, .violet, .frost };

pub const Settings = struct {
    preset: Preset = .moss,
    background_mode: BackgroundMode = .solid,
    background_color: u32 = 0x191F1D,
    image_path: ?[]const u8 = null,
    image_layout: ImageLayout = .fill,
    image_blur: u8 = 0,
    image_dimming: u8 = 50,
    corner_radius: u8 = 12,
    panel_opacity: u8 = 100,
    panel_blur: u8 = 0,
};

pub const Palette = struct {
    background: u32 = 0x191F1D,
    surface: u32 = 0x252D29,
    inset: u32 = 0x202823,
    sidebar: u32 = 0x202823,
    selected_surface: u32 = 0x2B362F,
    pressed_surface: u32 = 0x38483C,
    outline: u32 = 0x36453B,
    control_outline: u32 = 0x73877A,
    foreground: u32 = 0xEDF1EA,
    muted: u32 = 0xB3BFB4,
    accent: u32 = 0xA8C49C,
    accent_border: u32 = 0x87A77B,
    on_accent: u32 = 0x182318,
    selected_text: u32 = 0xC0D9B5,
    danger: u32 = 0xE7A29B,
    warning: u32 = 0xD9BD86,
    signal_inactive: u32 = 0x455149,
    log_match: u32 = 0x323D35,
    log_fatal: u32 = 0xFF7E89,
};

pub fn presetName(preset: Preset) []const u8 {
    return switch (preset) {
        .moss => "苔绿",
        .mist => "雾蓝",
        .graphite => "岩灰",
        .sunset => "落日",
        .violet => "藤紫",
        .frost => "霜白",
    };
}

pub fn palette(preset: Preset) Palette {
    return switch (preset) {
        .moss => .{},
        .mist => .{ .background = 0x192129, .surface = 0x26323D, .inset = 0x202A34, .sidebar = 0x202A34, .selected_surface = 0x2E404D, .pressed_surface = 0x384F60, .outline = 0x3C5060, .control_outline = 0x7E96A7, .foreground = 0xEDF3F7, .muted = 0xB6C4CF, .accent = 0xA5C6DA, .accent_border = 0x7EA9C5, .on_accent = 0x16232C, .selected_text = 0xC8E2F0, .signal_inactive = 0x435667, .log_match = 0x2F424F },
        .graphite => .{ .background = 0x202124, .surface = 0x2C2E32, .inset = 0x252629, .sidebar = 0x252629, .selected_surface = 0x383B41, .pressed_surface = 0x454952, .outline = 0x474C54, .control_outline = 0x8C949D, .foreground = 0xF0F1F3, .muted = 0xBDC2C8, .accent = 0xC3C8CE, .accent_border = 0x979FA8, .on_accent = 0x22252A, .selected_text = 0xE1E5EA, .signal_inactive = 0x4B5057, .log_match = 0x3D4249 },
        .sunset => .{ .background = 0x28201D, .surface = 0x382C26, .inset = 0x30251F, .sidebar = 0x30251F, .selected_surface = 0x463429, .pressed_surface = 0x594236, .outline = 0x5B4437, .control_outline = 0xAD8B76, .foreground = 0xF7EFE9, .muted = 0xCDBAAF, .accent = 0xDDB18C, .accent_border = 0xBF8D66, .on_accent = 0x302117, .selected_text = 0xF1D0B4, .signal_inactive = 0x655044, .log_match = 0x47372B },
        .violet => .{ .background = 0x24202A, .surface = 0x322C3A, .inset = 0x2B2532, .sidebar = 0x2B2532, .selected_surface = 0x41364B, .pressed_surface = 0x50435D, .outline = 0x55465F, .control_outline = 0x9C88AE, .foreground = 0xF2EDF7, .muted = 0xC8BACF, .accent = 0xC6B5DA, .accent_border = 0xA08AB7, .on_accent = 0x281F31, .selected_text = 0xE3D1F4, .signal_inactive = 0x594A65, .log_match = 0x403649 },
        .frost => .{ .background = 0xE9EFEC, .surface = 0xF7FAF8, .inset = 0xE0E9E4, .sidebar = 0xE0E9E4, .selected_surface = 0xD3E2D7, .pressed_surface = 0xC5D8CB, .outline = 0xBCCBC1, .control_outline = 0x718B79, .foreground = 0x22392B, .muted = 0x536B5B, .accent = 0x54755D, .accent_border = 0x3E5E46, .on_accent = 0xFFFFFF, .selected_text = 0x284D33, .danger = 0xAC3E39, .warning = 0x835800, .signal_inactive = 0xA2B6A8, .log_match = 0xD4E4D8, .log_fatal = 0x9B202D },
    };
}

pub fn parseHex(text: []const u8) !u32 {
    if (text.len != 7 or text[0] != '#') return error.InvalidBackgroundColor;
    for (text[1..]) |digit| switch (digit) {
        '0'...'9', 'a'...'f', 'A'...'F' => {},
        else => return error.InvalidBackgroundColor,
    };
    return std.fmt.parseInt(u32, text[1..], 16) catch error.InvalidBackgroundColor;
}

pub fn validate(settings: Settings) !void {
    if (settings.background_color > 0xFFFFFF) return error.InvalidBackgroundColor;
    if (settings.image_blur != 0 and settings.image_blur != 4 and settings.image_blur != 8 and settings.image_blur != 16) return error.InvalidBackgroundBlur;
    if (settings.panel_blur != 0 and settings.panel_blur != 4 and settings.panel_blur != 8 and settings.panel_blur != 16) return error.InvalidPanelBlur;
    if (settings.image_dimming > 100) return error.InvalidBackgroundDimming;
    if (settings.corner_radius != 0 and settings.corner_radius != 8 and settings.corner_radius != 12 and settings.corner_radius != 20) return error.InvalidCornerRadius;
    if (settings.panel_opacity < 60 or settings.panel_opacity > 100) return error.InvalidPanelOpacity;
    if (settings.image_path) |path| {
        if (path.len == 0 or path.len > 32768 or !std.unicode.utf8ValidateSlice(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidBackgroundPath;
    }
}

test "appearance accepts RGB only and validates rendering limits" {
    try validate(.{});
    try validate(.{ .panel_blur = 16 });
    try std.testing.expectError(error.InvalidPanelBlur, validate(.{ .panel_blur = 3 }));
    try std.testing.expectEqual(@as(u32, 0xA5C6DA), try parseHex("#a5C6dA"));
    try std.testing.expectError(error.InvalidBackgroundColor, parseHex("#12GG34"));
    try std.testing.expectError(error.InvalidBackgroundColor, parseHex("A5C6DA"));
    try std.testing.expectError(error.InvalidBackgroundColor, parseHex("#+12345"));
    try std.testing.expectError(error.InvalidBackgroundColor, parseHex("#12_345"));
    try std.testing.expectError(error.InvalidBackgroundColor, validate(.{ .background_color = 0xFF000000 }));
    try std.testing.expectError(error.InvalidBackgroundBlur, validate(.{ .image_blur = 255 }));
    try std.testing.expectError(error.InvalidPanelOpacity, validate(.{ .panel_opacity = 0 }));
    try std.testing.expectError(error.InvalidCornerRadius, validate(.{ .corner_radius = 255 }));
}

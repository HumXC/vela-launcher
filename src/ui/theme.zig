const dvui = @import("dvui");
const fonts = @import("fonts.zig");
pub const background = dvui.Color.fromHex("191F1D");
pub const surface = dvui.Color.fromHex("252D29");
pub const muted = dvui.Color.fromHex("B3BFB4");
pub const accent = dvui.Color.fromHex("A8C49C");

pub fn install(win: *dvui.Window) void {
    var value = dvui.Theme.builtin.adwaita_dark;
    value.name = "Vela";
    value.fill = background;
    value.text = .fromHex("EDF1EA");
    value.border = .fromHex("6F8175");
    value.focus = .fromHex("C0D9B5");
    value.window = .{ .fill = surface };
    value.control = .{ .fill = surface, .fill_hover = .fromHex("2B362F"), .fill_press = .fromHex("38483C") };
    value.highlight = .{ .fill = accent, .text = .fromHex("182318") };
    value.font_body = .find(.{ .family = fonts.family, .size = 16 });
    value.font_heading = value.font_body.withSize(18);
    value.font_title = value.font_body.withSize(24);
    win.themeSet(value);
}

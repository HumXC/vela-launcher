const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme.zig");
const style = @import("style.zig");
const R = dvui.Rect;

pub const ItemOptions = struct {
    icon: ?[]const u8 = null,
    selected: bool = false,
    enabled: bool = true,
    indent: f32 = 0,
    subtitle: ?[]const u8 = null,
    gap_after: f32 = theme.spacing.sidebar_action_gap,
};

/// Bordered sidebar rows keep navigation distinct from the surrounding shell.
pub fn sidebarItem(src: std.builtin.SourceLocation, key: []const u8, name: []const u8, options: ItemOptions) bool {
    const font = theme.bodyFont();
    const name_height = @max(font.lineHeight(), font.textSize(name).h);
    const subtitle_font = theme.captionFont();
    const subtitle_height = if (options.subtitle) |subtitle| @max(subtitle_font.lineHeight(), subtitle_font.textSize(subtitle).h) else 0;
    const height = name_height + if (options.subtitle != null) subtitle_height + theme.spacing.detail_gap else @as(f32, 0);
    const geometry = theme.controlGeometry(height, @max(theme.sizing.control_height, height + 2 * theme.sizing.control_border), 0, theme.sizing.control_padding_x, theme.sizing.control_border);
    var control: dvui.ButtonWidget = undefined;
    control.init(src, .{ .draw_focus = options.enabled }, .{
        .id_extra = @as(usize, @truncate(std.hash.Wyhash.hash(0, key))),
        .label = .{ .text = name },
        .expand = .horizontal,
        .max_size_content = .width(0),
        .font = font,
        .min_size_content = geometry.content,
        .padding = geometry.padding,
        .margin = .{ .x = options.indent, .h = options.gap_after },
        .corners = .all(theme.controlRadius()),
        .border = R.all(theme.sizing.control_border),
        .color_border = .{ .color = if (options.selected) theme.colors.accent else theme.colors.outline },
        .color_fill = .{ .color = if (options.selected) theme.colors.selected_surface else theme.colors.sidebar },
        .color_fill_hover = .{ .color = theme.colors.selected_surface },
        .color_fill_press = .{ .color = theme.panelColor(theme.colors.outline) },
        .color_text = if (!options.enabled) .{ .color = theme.colors.muted } else if (options.selected) .{ .color = theme.colors.selected_text } else null,
        .tab_index = if (options.enabled) null else 0,
    });
    defer control.deinit();
    buttonState(&control, options.enabled, false);
    const row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = geometry.content.h },
        .gravity_y = 0.5,
        .padding = R.all(0),
        .margin = R.all(0),
    });
    {
        defer row.deinit();
        if (options.icon) |asset| dvui.icon(@src(), name, asset, .{}, control.style().override(.{
            .min_size_content = dvui.Size.all(theme.sizing.sidebar_icon),
            .max_size_content = .size(dvui.Size.all(theme.sizing.sidebar_icon)),
            .gravity_y = 0.5,
            .padding = R.all(0),
            .margin = .{ .w = theme.spacing.row_gap },
            .role = .none,
        }));
        const lines = dvui.box(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .gravity_y = 0.5, .padding = R.all(0), .margin = R.all(0) });
        defer lines.deinit();
        dvui.labelNoFmt(@src(), name, .{}, control.style().override(.{
            .expand = .horizontal,
            .gravity_y = if (options.subtitle == null) 0.5 else 0,
            .max_size_content = .width(0),
            .background = false,
            .padding = R.all(0),
            .margin = R.all(0),
            .role = .none,
            .tab_index = 0,
        }));
        if (options.subtitle) |subtitle| {
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = theme.spacing.detail_gap } });
            const detail = dvui.textLayout(@src(), .{ .break_lines = false }, theme.foregroundOptions(control.style()).override(.{
                .expand = .horizontal,
                .min_size_content = .{ .h = subtitle_height },
                .max_size_content = .width(0),
                .font = subtitle_font,
                .color_text = .{ .color = theme.colors.muted },
                .background = false,
                .padding = R.all(0),
                .margin = R.all(0),
            }));
            detail.addText(subtitle, .{});
            detail.deinit();
        }
    }
    const tooltip_text = if (options.subtitle) |subtitle| std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}\n{s}", .{ name, subtitle }) catch name else name;
    tooltip(src, control.data().id, control.data().borderRectScale().r, tooltip_text);
    return options.enabled and control.clicked();
}

/// A single-line sidebar action with the same geometry on every management page.
pub fn sidebarAction(src: std.builtin.SourceLocation, key: []const u8, name: []const u8, options: ItemOptions) bool {
    const font = theme.bodyFont();
    const geometry = theme.controlGeometry(@max(font.lineHeight(), font.textSize(name).h), theme.sizing.control_height, 0, theme.spacing.control_padding_x, theme.sizing.control_border);
    var control: dvui.ButtonWidget = undefined;
    control.init(src, .{ .grayed = !options.enabled, .draw_focus = options.enabled }, .{
        .id_extra = @as(usize, @truncate(std.hash.Wyhash.hash(0, key))),
        .tag = key,
        .label = .{ .text = name },
        .font = font,
        .expand = .horizontal,
        .max_size_content = .width(0),
        .min_size_content = .{ .h = geometry.content.h },
        .padding = geometry.padding,
        .margin = .{ .h = options.gap_after },
        .border = R.all(theme.sizing.control_border),
        .corners = .all(theme.controlRadius()),
        .color_border = .{ .color = if (options.selected) theme.colors.accent else theme.colors.control_outline },
        .color_fill = .{ .color = if (options.selected) theme.colors.selected_surface else theme.colors.sidebar },
        .color_fill_hover = .{ .color = if (options.enabled) theme.colors.selected_surface else theme.colors.sidebar },
        .color_fill_press = .{ .color = if (options.enabled) theme.panelColor(theme.colors.outline) else theme.colors.sidebar },
        .color_text = if (options.selected) .{ .color = theme.colors.selected_text } else null,
        .tab_index = if (options.enabled) null else 0,
    });
    defer control.deinit();
    if (control.data().accesskit_node()) |node| {
        dvui.AccessKit.nodeSetSelected(node, options.selected);
        if (!options.enabled) {
            dvui.AccessKit.nodeSetDisabled(node);
            dvui.AccessKit.nodeRemoveAction(node, .click);
            dvui.AccessKit.nodeRemoveAction(node, .focus);
        }
    }
    if (options.enabled) control.processEvents() else control.processHover();
    theme.surface.buttonBackground(&control);
    {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .max_size_content = .width(0), .min_size_content = .{ .h = geometry.content.h }, .padding = R.all(0), .margin = R.all(0), .background = false });
        defer row.deinit();
        if (options.icon) |asset| dvui.icon(@src(), name, asset, .{}, control.style().override(.{ .min_size_content = dvui.Size.all(theme.sizing.sidebar_icon), .max_size_content = .size(dvui.Size.all(theme.sizing.sidebar_icon)), .gravity_y = 0.5, .padding = R.all(0), .margin = .{ .w = theme.spacing.control_padding_x }, .role = .none }));
        dvui.labelNoFmt(@src(), name, .{}, control.style().override(.{ .font = font, .expand = .horizontal, .max_size_content = .width(0), .gravity_y = 0.5, .padding = R.all(0), .margin = R.all(0), .background = false, .role = .none, .tab_index = 0 }));
    }
    tooltip(src, control.data().id, control.data().borderRectScale().r, name);
    return options.enabled and control.clicked();
}

pub const Signal = enum { unknown, good, fair, poor, offline };

pub const SelectionCardOptions = struct {
    /// Minimum outer height; taller fallback glyphs can still grow naturally.
    height: f32 = 0,
    compact: bool = false,
    selected: bool = false,
    enabled: bool = true,
    /// Requested outer width, including padding and border; clamps to the parent.
    width: f32 = 220,
    description: []const u8 = "",
    /// Optional decorative initial; the caller supplies the account card width.
    avatar_text: ?[]const u8 = null,
    avatar_source: ?dvui.ImageSource = null,
    avatar_size: f32 = 48,
    avatar_radius: f32 = 0,
    avatar_tag: ?[]const u8 = null,
    /// Reports clipping visibility so callers can defer offscreen work.
    visible: ?*bool = null,
    status: ?[]const u8 = null,
    status_color: ?dvui.Color = null,
    status_gap: f32 = 12,
    signal: ?Signal = null,
    /// Fill a grid cell, including its shared row height.
    stretch: bool = false,
    /// Keep each explicit text line within the card instead of growing from wrapping.
    bounded_text: bool = false,
    /// Allow callers to suppress automatic title tooltips in dense lists.
    auto_tooltip: bool = true,
    /// Optional full-width caption below the main card contents.
    footer_text: ?[]const u8 = null,
    tooltip: ?[]const u8 = null,
    tag: ?[]const u8 = null,
};

/// One selectable button with decorative children. Keep key stable across frames.
/// The caller owns selection and the grid's spacing; height grows with wrapped text.
pub fn selectionCard(src: std.builtin.SourceLocation, key: []const u8, name: []const u8, options: SelectionCardOptions) bool {
    const available = dvui.parentGet().data().contentRect().w;
    const padding = style.spacing.panel_compact_padding - style.sizing.control_border;
    const content_width = @max(0, @min(options.width, available) - 2 * (padding + theme.sizing.control_border));
    var control: dvui.ButtonWidget = undefined;
    control.init(src, .{ .draw_focus = false }, .{
        .id_extra = @as(usize, @truncate(std.hash.Wyhash.hash(0, key))),
        .tag = options.tag,
        .label = .{ .text = name },
        .expand = if (options.stretch) .both else .none,
        .min_size_content = .{ .w = content_width, .h = @max(0, options.height - 2 * (padding + theme.sizing.control_border)) },
        .max_size_content = .width(content_width),
        .padding = R.all(padding),
        .margin = R.all(0),
        .corners = .all(theme.cardRadius()),
        .border = R.all(theme.sizing.control_border),
        .color_border = .{ .color = dvui.Color.transparent },
        .color_fill = .{ .color = theme.panelColor(if (options.selected) theme.colors.selected_surface else theme.colors.surface) },
        .color_fill_hover = .{ .color = theme.panelColor(if (options.enabled) theme.colors.selected_surface else theme.colors.surface) },
        .color_fill_press = .{ .color = theme.panelColor(if (options.enabled) theme.colors.outline else theme.colors.surface) },
        .color_text = if (options.enabled) null else .{ .color = theme.colors.muted },
        .tab_index = if (options.enabled) null else 0,
    });
    defer control.deinit();
    buttonEvents(&control, options.enabled);
    theme.panelFill(control.data(), control.style());
    if (options.visible) |visible| visible.* = control.data().visible();
    if (control.data().accesskit_node()) |node| {
        dvui.AccessKit.nodeSetSelected(node, options.selected);
        const arena = dvui.currentWindow().arena();
        const description = std.fmt.allocPrint(arena, "{s}\n{s}\n{s}", .{
            options.tooltip orelse options.description,
            options.status orelse "",
            if (options.signal) |signal| signalDescription(signal) else "",
        }) catch options.description;
        dvui.AccessKit.nodeSetDescription(node, arena.dupeSentinel(u8, description, 0) catch "");
    }
    {
        const body = dvui.box(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .min_size_content = .{ .h = @max(0, options.height - 2 * (padding + theme.sizing.control_border)) }, .padding = R.all(0), .margin = R.all(0), .background = false, .role = .none });
        defer body.deinit();
        {
            const contents = dvui.box(@src(), .{ .dir = if (options.avatar_text != null or options.avatar_source != null) .horizontal else .vertical }, .{
                .expand = if (options.stretch and options.signal != null or options.avatar_text != null or options.avatar_source != null) .both else .horizontal,
                .max_size_content = .width(0),
                .padding = R.all(0),
                .margin = R.all(0),
                .background = false,
                .role = .none,
            });
            defer contents.deinit();
            if (options.avatar_text != null or options.avatar_source != null) {
                // Reserve both fixed edges before laying out the expanding text block.
                selectionCardCheck(options, true);
                {
                    const avatar = dvui.box(@src(), .{}, .{
                        .min_size_content = dvui.Size.all(options.avatar_size),
                        .max_size_content = .size(dvui.Size.all(options.avatar_size)),
                        .gravity_y = 0.5,
                        .padding = R.all(0),
                        .margin = .{ .w = theme.spacing.card_gap },
                        .border = R.all(0),
                        .corners = .all(options.avatar_radius),
                        .background = options.avatar_source == null,
                        .color_fill = .{ .color = theme.colors.accent },
                        .role = .none,
                    });
                    defer avatar.deinit();
                    if (options.avatar_source) |image| {
                        _ = @import("surface.zig").image(@src(), .{ .source = image }, .{
                            .tag = options.avatar_tag,
                            .min_size_content = dvui.Size.all(options.avatar_size),
                            .max_size_content = .size(dvui.Size.all(options.avatar_size)),
                            .corners = .all(options.avatar_radius),
                            .padding = R.all(0),
                            .margin = R.all(0),
                            .tab_index = 0,
                            .role = .none,
                        });
                    } else {
                        dvui.labelNoFmt(@src(), options.avatar_text orelse "", .{ .align_x = 0.5, .align_y = 0.5 }, .{
                            .gravity_x = 0.5,
                            .gravity_y = 0.5,
                            .font = theme.fontSized(theme.typography.avatar),
                            .color_text = .{ .color = theme.colors.background },
                            .background = false,
                            .padding = R.all(0),
                            .margin = R.all(0),
                            .tab_index = 0,
                            .role = .none,
                        });
                    }
                }
                const details = dvui.box(@src(), .{}, .{
                    .expand = .horizontal,
                    .max_size_content = .width(0),
                    .gravity_y = 0.5,
                    .padding = R.all(0),
                    .margin = R.all(0),
                    .background = false,
                    .role = .none,
                });
                defer details.deinit();
                const font = theme.headingFont();
                const title_width = @max(0, content_width - options.avatar_size - 40);
                const title_text = if (options.bounded_text) ellipsize(name, font, title_width) else avatarCardTitle(name, font, title_width);
                controlText(@src(), title_text, control.style().override(.{ .font = font }));
                selectionCardDetails(&control, options);
            } else {
                {
                    const heading = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .expand = .horizontal,
                        .max_size_content = .width(0),
                        .padding = R.all(0),
                        .margin = R.all(0),
                        .background = false,
                        .role = .none,
                    });
                    defer heading.deinit();
                    // Reserve the right edge before laying out the expanding title.
                    selectionCardCheck(options, false);
                    const font = theme.headingFont();
                    const title_width = @max(0, heading.data().contentRect().w - theme.sizing.selection_diameter - theme.sizing.row_gap);
                    const title_text = if (options.bounded_text) ellipsize(name, font, title_width) else cardTitle(name, font, title_width);
                    controlText(@src(), title_text, control.style().override(.{ .font = font }));
                }
                selectionCardDetails(&control, options);
            }
        }
        if (options.footer_text) |caption| controlText(@src(), caption, control.style().override(.{
            .font = theme.captionFont(),
            .margin = .{ .y = 2 },
            .color_text = .{ .color = theme.colors.muted },
        }));
    }
    theme.drawCardOutline(control.data(), options.selected or (options.enabled and control.focused()));
    if ((options.bounded_text and options.auto_tooltip) or options.tooltip != null) {
        const full_text = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}\n{s}\n{s}", .{ name, options.tooltip orelse options.description, options.status orelse "" }) catch name;
        tooltip(src, control.data().id, control.data().borderRectScale().r, full_text);
    }
    return options.enabled and control.clicked();
}

pub const SelectionCheckOptions = struct {
    selected: bool = false,
    enabled: bool = true,
    diameter: f32 = theme.sizing.selection_diameter,
    icon_size: f32 = theme.sizing.selection_icon,
    gap: f32 = theme.sizing.row_gap,
    gravity_x: f32 = 1,
    gravity_y: ?f32 = null,
    slot_tag: ?[]const u8 = null,
    badge_tag: ?[]const u8 = null,
    icon_tag: ?[]const u8 = null,
};

/// Decorative selection slot; its circle and check never own input or focus.
pub fn selectionCheck(src: std.builtin.SourceLocation, options: SelectionCheckOptions) void {
    const slot = dvui.box(src, .{}, .{
        .tag = options.slot_tag,
        .gravity_x = options.gravity_x,
        .gravity_y = options.gravity_y,
        .min_size_content = .{ .w = options.diameter, .h = options.diameter },
        .max_size_content = .{ .w = options.diameter, .h = options.diameter },
        .padding = R.all(0),
        .margin = .{ .x = options.gap },
        .border = R.all(0),
        .background = false,
        .role = .none,
        .tab_index = 0,
    });
    defer slot.deinit();
    if (options.selected) {
        const indicator = dvui.box(@src(), .{}, .{
            .tag = options.badge_tag,
            .min_size_content = .{ .w = options.icon_size, .h = options.icon_size },
            .max_size_content = .{ .w = options.icon_size, .h = options.icon_size },
            .padding = R.all((options.diameter - options.icon_size) / 2),
            .margin = R.all(0),
            .border = R.all(0),
            .corners = .all(options.diameter / 2),
            .background = true,
            .color_fill = .{ .color = if (options.enabled) theme.colors.accent else theme.colors.muted },
            .role = .none,
            .tab_index = 0,
        });
        defer indicator.deinit();
        // Use a centered vector check without the asset's asymmetric bearings.
        const icon = dvui.box(@src(), .{}, .{
            .tag = options.icon_tag,
            .min_size_content = dvui.Size.all(options.icon_size),
            .max_size_content = .size(dvui.Size.all(options.icon_size)),
            .padding = R.all(0),
            .margin = R.all(0),
            .background = false,
            .role = .none,
            .tab_index = 0,
        });
        defer icon.deinit();
        const rs = icon.data().contentRectScale();
        const points = [_]dvui.Point.Physical{
            .{ .x = rs.r.x + rs.r.w * 0.15, .y = rs.r.y + rs.r.h * 0.5 },
            .{ .x = rs.r.x + rs.r.w * 0.4, .y = rs.r.y + rs.r.h * 0.75 },
            .{ .x = rs.r.x + rs.r.w * 0.85, .y = rs.r.y + rs.r.h * 0.25 },
        };
        (dvui.Path{ .points = &points }).stroke(.{ .thickness = rs.s * 2, .color = .{ .color = theme.colors.background }, .endcap_style = .square });
    }
}

fn selectionCardCheck(options: SelectionCardOptions, centered: bool) void {
    const arena = dvui.currentWindow().arena();
    selectionCheck(@src(), .{
        .selected = options.selected,
        .enabled = options.enabled,
        .gravity_y = if (centered) 0.5 else null,
        .slot_tag = if (options.tag) |tag| std.fmt.allocPrint(arena, "{s}-check-slot", .{tag}) catch null else null,
        .badge_tag = if (options.tag) |tag| std.fmt.allocPrint(arena, "{s}-selected", .{tag}) catch null else null,
        .icon_tag = if (options.tag) |tag| std.fmt.allocPrint(arena, "{s}-check-icon", .{tag}) catch null else null,
    });
}

fn selectionCardDetails(control: *dvui.ButtonWidget, options: SelectionCardOptions) void {
    if (options.description.len > 0) {
        const font = theme.captionFont();
        const description = if (options.bounded_text) boundedLines(options.description, font, dvui.parentGet().data().contentRect().w) else options.description;
        controlText(@src(), description, control.style().override(.{
            .font = theme.captionFont(),
            .color_text = .{ .color = theme.colors.muted },
            .margin = .{ .y = style.spacing.detail_gap },
        }));
    }
    if (options.status != null or options.signal != null) {
        const status_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .max_size_content = .width(0),
            .padding = R.all(0),
            .margin = .{ .y = style.spacing.detail_gap },
            .background = false,
            .role = .none,
        });
        defer status_row.deinit();
        if (options.signal) |signal| signalBars(@src(), signal, options.enabled);
        if (options.status) |status| {
            const font = theme.captionFont();
            const width = @max(0, status_row.data().contentRect().w - if (options.signal != null) @as(f32, 33) else 0);
            controlText(@src(), if (options.bounded_text) ellipsize(status, font, width) else status, control.style().override(.{
                .font = font,
                .color_text = .{ .color = options.status_color orelse theme.colors.muted },
            }));
        }
    }
}

/// Account titles wrap at words, but an unbroken name fits on one line.
fn avatarCardTitle(name: []const u8, font: dvui.Font, width: f32) []const u8 {
    if (std.mem.indexOfScalar(u8, name, ' ') != null) return cardTitle(name, font, width);
    return ellipsize(name, font, width);
}

/// One readable line; truncation uses font-measured UTF-8 character boundaries.
pub fn ellipsize(value: []const u8, font: dvui.Font, width: f32) []const u8 {
    const line = if (std.mem.indexOfScalar(u8, value, '\n')) |end| value[0..end] else value;
    if (line.len == value.len and font.textSize(line).w <= width) return line;
    const ellipsis = "…";
    const ellipsis_width = font.textSize(ellipsis).w;
    if (width < ellipsis_width) return "";
    var end: usize = 0;
    _ = font.textSizeEx(line, .{ .max_width = width - ellipsis_width, .end_idx = &end });
    return std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}{s}", .{ line[0..end], ellipsis }) catch line[0..end];
}

fn boundedLines(value: []const u8, font: dvui.Font, width: f32) []const u8 {
    const arena = dvui.currentWindow().arena();
    var result: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, value, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) result.append(arena, '\n') catch return value;
        result.appendSlice(arena, ellipsize(line, font, width)) catch return value;
        first = false;
    }
    return result.items;
}

/// The group surface owns both its heading and expanded content.
pub fn disclosurePanel(src: std.builtin.SourceLocation, key: []const u8, name: []const u8, expanded: *bool, options: dvui.Options) *dvui.BoxWidget {
    const panel = bentoPanel(src, (dvui.Options{
        .padding = .{ .x = style.spacing.panel_compact_padding - style.sizing.control_border, .y = style.cards.disclosure_top - style.sizing.control_border, .w = style.spacing.panel_compact_padding - style.sizing.control_border, .h = if (expanded.*) style.spacing.panel_compact_padding - style.sizing.control_border else style.cards.disclosure_top - style.sizing.control_border },
        .margin = .{ .h = style.spacing.group_gap },
    }).override(options));
    disclosureHeader(src, key, name, expanded, style.cards.disclosure_gap, true);
    return panel;
}

/// A full-width section header. Toggles only the caller's expansion state.
pub fn disclosure(src: std.builtin.SourceLocation, key: []const u8, name: []const u8, expanded: *bool, content_gap: f32) void {
    disclosureHeader(src, key, name, expanded, content_gap, false);
}

fn disclosureHeader(src: std.builtin.SourceLocation, key: []const u8, name: []const u8, expanded: *bool, content_gap: f32, embedded: bool) void {
    var control: dvui.ButtonWidget = undefined;
    const font = if (embedded) theme.headingFont() else theme.bodyFont();
    const height = if (embedded) style.cards.disclosure_height else style.sizing.control_height;
    const geometry = theme.controlGeometry(@max(height, @max(font.lineHeight(), font.textSize(name).h)), height, 0, if (embedded) 0 else style.sizing.control_padding_x, 0);
    control.init(src, .{ .draw_focus = false }, .{
        .id_extra = @as(usize, @truncate(std.hash.Wyhash.hash(0, key))),
        .tag = if (embedded) key else null,
        .label = .{ .text = name },
        .expand = .horizontal,
        .max_size_content = .width(0),
        .font = font,
        .min_size_content = geometry.content,
        .padding = geometry.padding,
        .margin = .{ .h = if (expanded.*) content_gap else 0 },
        .corners = .all(theme.controlRadius()),
        .border = R.all(0),
        .background = !embedded,
        .color_fill = .{ .color = style.colors.transparent },
        .color_fill_hover = .{ .color = style.colors.selected_surface },
        .color_fill_press = .{ .color = style.colors.pressed_surface },
    });
    defer control.deinit();
    buttonState(&control, true, false);
    if (control.clicked()) expanded.* = !expanded.*;
    if (control.data().accesskit_node()) |node| dvui.AccessKit.nodeSetExpanded(node, expanded.*);
    {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .gravity_y = 0.5,
            .max_size_content = .width(0),
            .padding = R.all(0),
            .margin = R.all(0),
            .background = false,
            .role = .none,
        });
        defer row.deinit();
        {
            const glyph = dvui.box(@src(), .{}, .{
                .min_size_content = dvui.Size.all(style.sizing.icon),
                .max_size_content = .size(dvui.Size.all(style.sizing.icon)),
                .gravity_x = 1,
                .gravity_y = 0.5,
                .padding = R.all(0),
                .margin = .{ .x = style.spacing.row_gap },
                .border = R.all(0),
                .background = false,
                .role = .none,
            });
            defer glyph.deinit();
            dvui.icon(@src(), "disclosure-chevron", if (expanded.*) dvui.entypo.chevron_down else dvui.entypo.chevron_right, .{}, control.style().override(.{
                .min_size_content = dvui.Size.all(style.sizing.icon),
                .max_size_content = .size(dvui.Size.all(style.sizing.icon)),
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .color_text = .{ .color = if (control.hover or control.focused()) style.colors.accent else style.colors.muted },
                .padding = R.all(0),
                .margin = R.all(0),
                .role = .none,
            }));
        }
        dvui.labelNoFmt(@src(), name, .{ .align_y = 0.5 }, control.style().override(.{ .tag = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}-label", .{key}) catch null, .expand = .horizontal, .gravity_y = 0.5, .max_size_content = .width(0), .padding = R.all(0), .margin = R.all(0), .background = false, .role = .none, .tab_index = 0 }));
    }
}

/// Keep word boundaries in narrow cards; DVUI only does this at wider measures.
fn cardTitle(name: []const u8, font: dvui.Font, width: f32) []const u8 {
    if (width <= 0 or font.textSize(name).w <= width or std.mem.indexOfScalar(u8, name, ' ') == null) return name;
    const arena = dvui.currentWindow().arena();
    var result: std.ArrayList(u8) = .empty;
    var words = std.mem.tokenizeScalar(u8, name, ' ');
    var line_start: usize = 0;
    while (words.next()) |word| {
        if (result.items.len > line_start) {
            const candidate = std.fmt.allocPrint(arena, "{s} {s}", .{ result.items[line_start..], word }) catch return name;
            if (font.textSize(candidate).w > width) {
                result.append(arena, '\n') catch return name;
                line_start = result.items.len;
            } else {
                result.append(arena, ' ') catch return name;
            }
        }
        result.appendSlice(arena, word) catch return name;
    }
    return result.items;
}

/// Wrapped, noninteractive text: constrain width only, never its measured height.
fn controlText(src: std.builtin.SourceLocation, value: []const u8, options: dvui.Options) void {
    const layout = dvui.textLayout(src, .{
        .break_lines = true,
        .process_events_in_deinit = false,
        .focused = false,
        .show_touch_draggables = false,
    }, theme.foregroundOptions(options).override(.{
        .expand = .horizontal,
        .min_size_content = .{ .h = options.fontGet().textHeight() },
        .max_size_content = .width(0),
        .background = false,
        .padding = R.all(0),
        .margin = options.margin orelse R.all(0),
        .tab_index = 0,
        .role = .none,
    }));
    layout.addText(value, .{});
    layout.deinit();
}

fn signalDescription(signal: Signal) []const u8 {
    return switch (signal) {
        .unknown => "信号未知",
        .good => "信号良好",
        .fair => "信号一般",
        .poor => "信号较弱",
        .offline => "离线",
    };
}

fn signalBars(src: std.builtin.SourceLocation, signal: Signal, enabled: bool) void {
    const lit: usize = switch (signal) {
        .good => 4,
        .fair => 3,
        .poor => 1,
        .unknown, .offline => 0,
    };
    const active = switch (signal) {
        .fair => style.colors.warning,
        .poor => style.colors.danger,
        else => theme.colors.accent,
    };
    const bars = dvui.box(src, .{ .dir = .horizontal }, .{
        .gravity_x = 1,
        .min_size_content = .{ .w = 25, .h = 16 },
        .max_size_content = .{ .w = 25, .h = 16 },
        .padding = R.all(0),
        .margin = .{ .x = theme.spacing.row_gap },
        .background = false,
        .role = .none,
    });
    defer bars.deinit();
    for (0..4) |index| {
        const height: f32 = @floatFromInt((index + 1) * 4);
        const bar = dvui.box(@src(), .{}, .{
            .id_extra = index,
            .min_size_content = .{ .w = 4, .h = height },
            .max_size_content = .{ .w = 4, .h = height },
            .gravity_y = 1,
            .padding = R.all(0),
            .margin = .{ .w = if (index < 3) 3 else 0 },
            .border = R.all(0),
            .corners = .all(1),
            .background = true,
            .color_fill = .{ .color = if (!enabled or signal == .offline or signal == .unknown) style.colors.signal_inactive else if (index < lit) active else style.colors.signal_inactive },
            .role = .none,
        });
        bar.deinit();
    }
}

pub const tooltip_hover_delay_us = style.feedback.tooltip_delay_us;
pub const tooltip_gap_px = style.feedback.tooltip_gap;

/// Pass the triggering widget id, not its changing label or loop position.
/// The hover rect stays exact; only placement includes the physical-pixel gap.
/// Call every frame the control exists, including while it is disabled.
pub fn tooltip(src: std.builtin.SourceLocation, control_id: dvui.Id, active_rect: dvui.Rect.Physical, value: []const u8) void {
    const screen = dvui.windowRect();
    const gap = tooltip_gap_px / dvui.windowNaturalScale();
    const trigger = active_rect.toNatural();
    const placement_rect: dvui.Rect.Natural = .{ .x = trigger.x - gap, .y = trigger.y - gap, .w = trigger.w + 2 * gap, .h = trigger.h + 2 * gap };
    const side_width = @max(placement_rect.x - screen.x, screen.x + screen.w - placement_rect.x - placement_rect.w);
    const horizontal = side_width >= @min(@as(f32, 160), screen.w / 2);
    const available_width = if (horizontal) side_width else screen.w;
    const content_width = @max(1, @min(@as(f32, 360), available_width - 2 * (theme.spacing.tooltip_padding + theme.sizing.control_border)));
    const available_height = if (horizontal) screen.h else @max(placement_rect.y - screen.y, screen.y + screen.h - placement_rect.y - placement_rect.h);
    const content_height = @max(1, available_height - 2 * (theme.spacing.tooltip_padding + theme.sizing.control_border));
    var floating: dvui.FloatingTooltipWidget = undefined;
    floating.init(src, .{
        .active_rect = active_rect,
        .position = .absolute,
        .interactive = false,
        .scale = 1,
    }, .{
        .id_extra = @as(usize, @truncate(@backingInt(control_id))),
        .role = .tooltip,
        .label = .{ .text = value },
        .tab_index = 0,
        .padding = R.all(theme.spacing.tooltip_padding),
        .margin = R.all(0),
        .max_size_content = .size(.{ .w = content_width, .h = content_height }),
    });
    var hovered = false;
    for (dvui.events()) |*event| {
        if (dvui.eventMatch(event, .{ .id = floating.data().id, .r = active_rect }) and
            event.evt == .mouse and event.evt.mouse.action == .position) hovered = true;
    }
    const started = dvui.dataGetPtrDefault(null, floating.data().id, "_vela_hover_started", ?i128, null);
    const now = dvui.currentWindow().frame_time_ns;
    if (!hovered) {
        started.* = null;
    } else if (started.* == null) {
        started.* = now;
        dvui.timer(floating.data().id, tooltip_hover_delay_us);
    }
    const ready = if (started.*) |start| now - start >= @as(i128, tooltip_hover_delay_us) * std.time.ns_per_us else false;
    // DVUI keeps only timers accessed this frame in its idle wakeup schedule.
    if (hovered and !ready) _ = dvui.timerGet(floating.data().id);
    // Measure at zero opacity during the delay, then show immediately without a fade.
    const previous_alpha = dvui.alpha(if (ready) 1 else 0);
    defer dvui.alphaSet(previous_alpha);
    defer floating.deinit();
    const start = dvui.Rect.Natural.fromPoint(placement_rect.topLeft()).toSize(.cast(floating.data().rect.size()));
    floating.data().rect = .cast(dvui.placeOnScreen(screen, placement_rect, if (horizontal) .horizontal else .vertical, start));
    if (floating.shown()) {
        const label = dvui.textLayout(@src(), .{ .break_lines = true, .process_events_in_deinit = false }, .{
            .max_size_content = .size(.{ .w = content_width, .h = content_height }),
            .background = false,
            .padding = R.all(0),
            .margin = R.all(0),
            .tab_index = 0,
        });
        label.addText(value, .{});
        label.deinit();
        if (floating.data().accesskit_node()) |node| dvui.AccessKit.nodeSetLabel(node, dvui.currentWindow().arena().dupeSentinel(u8, value, 0) catch "");
    }
}

pub fn section(src: std.builtin.SourceLocation, name: []const u8) void {
    dvui.labelNoFmt(src, name, .{}, .{
        .expand = .horizontal,
        .max_size_content = .width(0),
        .font = theme.headingFont(),
        .color_text = .{ .color = theme.colors.muted },
        .background = false,
        .padding = R.all(0),
        .margin = .{ .y = theme.spacing.section_gap, .h = theme.spacing.section_label_gap },
    });
}

/// Informational text never owns a panel fill; its containing control does.
pub fn text(src: std.builtin.SourceLocation, value: []const u8, color: dvui.Color) void {
    const layout = dvui.textLayout(src, .{}, .{
        .expand = .horizontal,
        .max_size_content = .width(0),
        .color_text = .{ .color = color },
        .background = false,
        .padding = R.all(0),
        .margin = R.all(0),
    });
    layout.addText(value, .{});
    layout.deinit();
}

pub fn emptyState(src: std.builtin.SourceLocation, value: []const u8) void {
    text(src, value, theme.colors.muted);
}

/// Standard inline action; use button options for primary actions or icons.
pub fn action(src: std.builtin.SourceLocation, name: []const u8, enabled: bool) bool {
    return button(src, name, .{ .enabled = enabled });
}

pub const FormAction = enum { none, save, cancel };
pub const FormOptions = struct {
    save_enabled: bool = true,
    cancel_enabled: bool = true,
    save_label: []const u8 = "保存",
    cancel_label: []const u8 = "取消",
};

/// Dialog actions have their own dimensions; page footers keep their existing size.
pub const ModalActions = struct {
    box: *dvui.BoxWidget,
    count: usize,

    pub fn width(self: ModalActions) f32 {
        const requested = if (self.count == 3) style.dialogs.three_action_width else if (self.count == 1) style.dialogs.task_action_width else style.dialogs.action_width;
        return @min(requested, @max(0, (self.box.data().contentRect().w - style.dialogs.action_gap * @as(f32, @floatFromInt(self.count - 1))) / @as(f32, @floatFromInt(self.count))));
    }

    pub fn action(self: ModalActions, src: std.builtin.SourceLocation, index: usize, name: []const u8, options: ButtonOptions) bool {
        const width_value = self.width();
        const available = self.box.data().contentRect().w;
        var value = options;
        value.placement = .footer;
        value.min_width = width_value;
        value.rect = .{ .x = if (index + 1 == self.count) @max(0, available - width_value) else @as(f32, @floatFromInt(index)) * (width_value + style.dialogs.action_gap), .y = 0, .w = width_value, .h = theme.sizing.control_height };
        return button(src, name, value);
    }

    pub fn deinit(self: ModalActions) void {
        self.box.deinit();
    }
};

pub fn modalActions(src: std.builtin.SourceLocation, count: usize) ModalActions {
    std.debug.assert(count >= 1 and count <= 3);
    return .{ .count = count, .box = dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_y = 1, .min_size_content = .height(theme.sizing.control_height), .padding = R.all(0), .margin = .{ .y = style.dialogs.footer_gap }, .background = false }) };
}

pub fn modalFormActions(src: std.builtin.SourceLocation, options: FormOptions) FormAction {
    const actions = modalActions(src, 2);
    defer actions.deinit();
    const cancel = actions.action(@src(), 0, options.cancel_label, .{ .enabled = options.cancel_enabled });
    const save = actions.action(@src(), 1, options.save_label, .{ .enabled = options.save_enabled, .primary = true });
    return if (cancel) .cancel else if (save) .save else .none;
}

pub const ModalSectionOptions = struct {
    tag: ?[]const u8 = null,
    min_height: f32 = 0,
    gap_after: f32 = style.spacing.card_gap,
    expand: bool = false,
};

pub fn modalSection(src: std.builtin.SourceLocation, options: ModalSectionOptions) *dvui.BoxWidget {
    return theme.panel(src, .{}, .{ .tag = options.tag, .expand = if (options.expand) .both else .horizontal, .max_size_content = .width(0), .min_size_content = .height(@max(0, options.min_height - 2 * style.spacing.panel_compact_padding)), .padding = R.all(style.spacing.panel_compact_padding - style.sizing.control_border), .margin = .{ .h = options.gap_after }, .border = R.all(style.sizing.control_border), .corners = .all(theme.cardRadius()), .background = true, .color_fill = .{ .color = theme.panelColor(theme.colors.surface) }, .color_border = .{ .color = theme.colors.outline } });
}

pub fn alert(src: std.builtin.SourceLocation, heading: []const u8, message: []const u8) void {
    dvui.dialog(src, .{}, .{ .title = heading, .message = message, .ok_label = "确认", .displayFn = alertDisplay });
}

fn alertDisplay(id: dvui.Id) !void {
    const heading = dvui.dataGetSlice(null, id, "_title", []u8) orelse {
        dvui.dialogRemove(id);
        return;
    };
    const message = dvui.dataGetSlice(null, id, "_message", []u8) orelse {
        dvui.dialogRemove(id);
        return;
    };
    var open = true;
    const window = fixedModalPanel(@src(), heading, 280, &open, id.asUsize());
    defer window.deinit();
    modalTitle(@src(), heading, null);
    if (!open) {
        dvui.dialogRemove(id);
        return;
    }
    {
        const footer = modalActions(@src(), 1);
        defer footer.deinit();
        if (footer.action(@src(), 0, "确认", .{ .tag = "alert-confirm", .primary = true })) {
            dvui.dialogRemove(id);
            return;
        }
        if (dvui.firstFrame(window.data().id)) {
            if (dvui.tagGet("alert-confirm")) |confirm| dvui.focusWidget(confirm.id, null, null);
        }
    }
    const scroll = scrollBody(@src());
    defer scroll.deinit();
    const information = modalSection(@src(), .{ .gap_after = 0 });
    defer information.deinit();
    text(@src(), message, theme.colors.foreground);
}

/// Reserve this footer before drawing an expanding editor body. Callers queue
/// its result and save or discard only after all widgets have closed.
pub fn formActions(src: std.builtin.SourceLocation, options: FormOptions) FormAction {
    const footer = dvui.box(src, .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .gravity_y = 1,
        .min_size_content = .{ .h = theme.sizing.control_height },
        .padding = R.all(0),
        .margin = .{ .y = theme.spacing.footer_gap },
        .background = false,
    });
    defer footer.deinit();
    const width = theme.footerButtonWidth(footer.data().contentRect().w);
    const cancel = formButton(@src(), options.cancel_label, options.cancel_enabled, false, false, width);
    const save = formButton(@src(), options.save_label, options.save_enabled, true, true, width);
    return if (cancel) .cancel else if (save) .save else .none;
}

fn formButton(src: std.builtin.SourceLocation, name: []const u8, enabled: bool, primary: bool, right: bool, width: f32) bool {
    return button(src, name, .{ .enabled = enabled, .primary = primary, .gravity_x = if (right) 1 else 0, .placement = .footer, .standalone = true, .min_width = width });
}

pub fn title(src: std.builtin.SourceLocation, name: []const u8) void {
    const layout = dvui.textLayout(src, .{}, .{ .font = theme.titleFont(), .expand = .horizontal, .max_size_content = .width(0), .background = false, .padding = R.all(0), .margin = R.all(0) });
    layout.addText(name, .{});
    layout.deinit();
}

pub fn hint(src: std.builtin.SourceLocation, value: []const u8) void {
    const layout = dvui.textLayout(src, .{}, .{ .font = theme.captionFont(), .color_text = .{ .color = theme.colors.muted }, .expand = .horizontal, .max_size_content = .width(0), .background = false, .padding = R.all(0), .margin = R.all(0) });
    layout.addText(value, .{});
    layout.deinit();
}

pub fn fieldLabel(src: std.builtin.SourceLocation, name: []const u8) void {
    fieldLabelStyled(src, name, false);
}

fn fieldLabelStyled(src: std.builtin.SourceLocation, name: []const u8, prominent: bool) void {
    const layout = dvui.textLayout(src, .{}, .{ .font = if (prominent) theme.headingFont() else null, .expand = .horizontal, .max_size_content = .width(0), .background = false, .padding = R.all(0), .margin = .{ .h = theme.spacing.field_label_gap } });
    layout.addText(name, .{});
    layout.deinit();
}

pub const ButtonOptions = struct {
    enabled: bool = true,
    primary: bool = false,
    destructive: bool = false,
    icon: ?[]const u8 = null,
    gravity_x: f32 = 0,
    tag: ?[]const u8 = null,
    placement: enum { inline_action, footer } = .inline_action,
    expand: bool = false,
    /// Use panel-strength fills when the control sits directly on the wallpaper.
    standalone: bool = false,
    rect_out: ?*?dvui.Rect.Physical = null,
    min_width: f32 = theme.sizing.button_min_width,
    tooltip: ?[]const u8 = null,
    rect: ?dvui.Rect = null,
    label_alignment: f32 = 0.5,
};

fn buttonState(control: *dvui.ButtonWidget, enabled: bool, material: bool) void {
    buttonEvents(control, enabled);
    theme.buttonBackground(control, .{ .material = material });
}

fn buttonEvents(control: *dvui.ButtonWidget, enabled: bool) void {
    if (control.data().accesskit_node()) |node| {
        if (!enabled) {
            dvui.AccessKit.nodeSetDisabled(node);
            dvui.AccessKit.nodeRemoveAction(node, .click);
            dvui.AccessKit.nodeRemoveAction(node, .focus);
        }
    }
    if (enabled) control.processEvents() else control.processHover();
}

pub fn button(src: std.builtin.SourceLocation, name: []const u8, options: ButtonOptions) bool {
    var control: dvui.ButtonWidget = undefined;
    const font = theme.bodyFont();
    const line_height = @max(font.lineHeight(), font.textSize(name).h);
    const geometry = theme.controlGeometry(line_height, theme.sizing.control_height, options.min_width, theme.sizing.control_padding_x, theme.sizing.control_border);
    control.init(src, .{ .grayed = !options.enabled, .draw_focus = options.enabled }, theme.controlOptions(line_height).override(.{
        .tag = options.tag,
        .rect = options.rect,
        .label = .{ .text = options.tooltip orelse name },
        .gravity_x = options.gravity_x,
        .expand = if (options.expand) .horizontal else .none,
        .min_size_content = geometry.content,
        .padding = geometry.padding,
        .margin = if (options.placement == .footer) R.all(0) else .{ .w = theme.spacing.action_gap, .h = theme.spacing.action_gap },
        .corners = .all(theme.controlRadius()),
        .style = if (options.primary and options.enabled) .highlight else .control,
        .color_border = if (options.destructive) .{ .color = style.colors.danger } else null,
        .color_fill = if (options.standalone and !(options.primary and options.enabled)) .{ .color = theme.panelColor(theme.colors.surface) } else if (!options.enabled) .{ .color = theme.colors.surface } else null,
        .color_fill_hover = if (options.standalone and !(options.primary and options.enabled)) .{ .color = theme.panelColor(if (options.enabled) theme.colors.selected_surface else theme.colors.surface) } else if (!options.enabled) .{ .color = theme.colors.surface } else null,
        .color_fill_press = if (options.standalone and !(options.primary and options.enabled)) .{ .color = theme.panelColor(if (options.enabled) theme.colors.pressed_surface else theme.colors.surface) } else if (!options.enabled) .{ .color = theme.colors.surface } else null,
        .tab_index = if (options.enabled) null else 0,
    }));
    defer control.deinit();
    buttonState(&control, options.enabled, options.standalone and !(options.primary and options.enabled));
    {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = options.label_alignment, .gravity_y = 0.5, .padding = R.all(0), .margin = R.all(0), .background = false });
        defer row.deinit();
        if (options.icon) |asset| dvui.icon(@src(), name, asset, .{}, control.style().override(.{ .min_size_content = dvui.Size.all(theme.sizing.icon), .max_size_content = .{ .w = theme.sizing.icon, .h = theme.sizing.icon }, .gravity_y = 0.5, .padding = R.all(0), .margin = .{ .w = theme.spacing.row_gap }, .role = .none }));
        dvui.labelNoFmt(@src(), name, .{ .align_y = 0.5 }, control.style().override(.{ .color_text = if (!options.enabled) .{ .color = theme.colors.muted } else null, .background = false, .padding = R.all(0), .margin = R.all(0), .gravity_y = 0.5 }));
    }
    if (options.rect_out) |out| out.* = control.data().borderRectScale().r;
    if (options.tooltip) |value| tooltip(src, control.data().id, control.data().borderRectScale().r, value);
    return options.enabled and control.clicked();
}

pub const IconOptions = struct {
    enabled: bool = true,
    selected: bool = false,
    standalone: bool = false,
    tag: ?[]const u8 = null,
    /// Explicit outer size for compact task actions; a supplied rect takes precedence.
    size: f32 = theme.sizing.icon_button,
    rect: ?dvui.Rect = null,
};

pub fn iconButton(src: std.builtin.SourceLocation, name: []const u8, asset: []const u8, options: IconOptions) bool {
    var control: dvui.ButtonWidget = undefined;
    const side = if (options.rect) |rect| @min(rect.w, rect.h) else options.size;
    const geometry = theme.controlGeometry(theme.sizing.icon, side, side, @max(0, (side - 2 * theme.sizing.control_border - theme.sizing.icon) / 2), theme.sizing.control_border);
    control.init(src, .{ .grayed = !options.enabled, .draw_focus = options.enabled }, theme.controlOptions(theme.sizing.icon).override(.{
        .tag = options.tag,
        .label = .{ .text = name },
        .rect = options.rect,
        .min_size_content = geometry.content,
        .padding = geometry.padding,
        .margin = if (options.rect != null) R.all(0) else .{ .w = theme.sizing.sidebar_action_gap },
        .corners = .all(theme.controlRadius()),
        .color_fill = if (options.standalone) .{ .color = theme.panelColor(theme.colors.surface) } else null,
        .color_fill_hover = if (options.standalone) .{ .color = theme.panelColor(if (options.enabled) theme.colors.selected_surface else theme.colors.surface) } else if (!options.enabled) .{ .color = theme.colors.surface } else null,
        .color_fill_press = if (options.standalone) .{ .color = theme.panelColor(if (options.enabled) theme.colors.pressed_surface else theme.colors.surface) } else if (!options.enabled) .{ .color = theme.colors.surface } else null,
        .color_text = if (!options.enabled) .{ .color = theme.colors.muted } else if (options.selected) .{ .color = theme.colors.accent } else null,
        .tab_index = if (options.enabled) null else 0,
    }));
    buttonState(&control, options.enabled, options.standalone);
    dvui.icon(@src(), name, asset, .{}, control.style().override(.{ .min_size_content = dvui.Size.all(theme.sizing.icon), .max_size_content = .size(dvui.Size.all(theme.sizing.icon)), .gravity_x = 0.5, .gravity_y = 0.5, .padding = R.all(0), .margin = R.all(0), .role = .none }));
    const clicked = options.enabled and control.clicked();
    const id = control.data().id;
    const rect = control.data().borderRectScale().r;
    control.deinit();
    tooltip(src, id, rect, name);
    return clicked;
}

pub const EntryOptions = struct {
    kind: enum { full, number } = .full,
    tag: ?[]const u8 = null,
    prominent_label: bool = false,
    /// A form container owns the gap; its final field uses zero.
    gap_after: f32 = style.spacing.field_gap,
    enabled: bool = true,
    digits_only: bool = false,
};

/// Custom editors (including credentials) share these options without exposing secrets.
pub fn entryOptions(name: []const u8, options: EntryOptions) dvui.Options {
    const font = theme.bodyFont();
    const text_height = @max(font.textHeight(), font.textSize(name).h);
    const geometry = theme.textEntryGeometry(text_height, @min(theme.sizing.numeric_entry_width, dvui.parentGet().data().contentRect().w));
    return theme.controlOptions(text_height).override(.{
        .tag = options.tag,
        .label = .{ .text = name },
        .expand = if (options.kind == .full) .horizontal else .none,
        .min_size_content = .{ .w = if (options.kind == .number) geometry.content.w else 0, .h = geometry.content.h },
        .max_size_content = .width(if (options.kind == .number) geometry.content.w else 0),
        .padding = geometry.padding,
        .margin = .{ .h = options.gap_after },
    });
}

pub fn entry(src: std.builtin.SourceLocation, name: []const u8, buffer: []u8, options: EntryOptions) bool {
    var control: dvui.TextEntryWidget = undefined;
    control.init(src, .{ .text = .{ .buffer = buffer } }, entryOptions(name, options).override(.{
        .tab_index = if (options.enabled) null else 0,
        .color_text = if (options.enabled) null else .{ .color = style.colors.muted },
    }));
    if (options.enabled) {
        control.processEvents();
        if (options.digits_only) control.filterIn("0123456789");
    } else if (control.data().accesskit_node()) |node| dvui.AccessKit.nodeSetDisabled(node);
    control.draw();
    if (@import("builtin").is_test) {
        if (options.tag) |name_tag| {
            const arena = dvui.currentWindow().arena();
            const border_tag = std.fmt.allocPrint(arena, "{s}-border", .{name_tag}) catch name_tag;
            dvui.tag(border_tag, .{ .id = control.data().id, .rect = control.data().borderRectScale().r, .visible = control.data().visible() });
            const caret_tag = std.fmt.allocPrint(arena, "{s}-caret", .{name_tag}) catch name_tag;
            dvui.tag(caret_tag, .{ .id = control.textLayout.data().id, .rect = control.textLayout.screenRectScale(control.textLayout.cursor_rect).r, .visible = control.data().visible() });
        }
    }
    const changed = options.enabled and control.text_changed;
    control.deinit();
    return changed;
}

pub fn field(src: std.builtin.SourceLocation, name: []const u8, buffer: []u8, options: EntryOptions) bool {
    const group = dvui.box(src, .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .background = false, .padding = R.all(0), .margin = R.all(0) });
    defer group.deinit();
    fieldLabelStyled(@src(), name, options.prominent_label);
    return entry(@src(), name, buffer, options);
}

fn dropdownOptions(name: []const u8, entries: []const []const u8) dvui.Options {
    const font = theme.bodyFont();
    var line_height = @max(font.lineHeight(), font.textSize(name).h);
    for (entries) |label| line_height = @max(line_height, font.textSize(label).h);
    // DVUI puts borders and padding on the inner menu item; the wrapper needs
    // the full outer minimum so expanding the item really allocates 48.
    return theme.controlOptions(line_height).override(.{
        .label = .{ .text = name },
        .expand = .horizontal,
        .min_size_content = .{ .h = theme.sizing.control_height },
        .max_size_content = .width(0),
        .margin = .{ .h = theme.spacing.field_gap },
    });
}

/// Shared control geometry with explicit per-form tags and layout overrides.
pub fn dropdown(src: std.builtin.SourceLocation, name: []const u8, entries: []const []const u8, choice: dvui.DropdownChoice(usize), init_opts: dvui.DropdownInitOptions, options: dvui.Options) bool {
    return dvui.dropdown(src, entries, choice, init_opts, dropdownOptions(name, entries).override(options));
}

pub const CheckboxOptions = struct {
    tag: ?[]const u8 = null,
    id_extra: usize = 0,
    label_color: ?dvui.Color = null,
};

/// Semantic options keep indicator geometry and colors independent of the label.
pub fn checkboxOptions(name: []const u8, options: CheckboxOptions) dvui.Options {
    return dvui.checkbox_defaults.override(.{ .tag = options.tag, .id_extra = options.id_extra, .label = .{ .text = name }, .font = theme.bodyFont(), .padding = R.all(0), .margin = .{ .h = theme.spacing.field_gap } });
}

/// Match DVUI checkbox interaction and indicator painting, with label-only color.
pub fn checkboxStyled(src: std.builtin.SourceLocation, value: *bool, name: []const u8, options: CheckboxOptions) bool {
    const opts = checkboxOptions(name, options);
    const row = dvui.box(src, .{ .dir = .horizontal }, opts);
    defer row.deinit();
    dvui.tabIndexSet(row.data().id, row.data().options.tab_index, row.data().rectScale().r);
    var hovered = false;
    const changed = dvui.clicked(row.data(), .{ .hovered = &hovered });
    if (changed) value.* = !value.*;
    if (row.data().accesskit_node()) |node| {
        dvui.AccessKit.nodeAddAction(node, dvui.AccessKit.Action.focus);
        dvui.AccessKit.nodeAddAction(node, dvui.AccessKit.Action.click);
        dvui.AccessKit.nodeSetToggled(node, if (value.*) .ak_true else .ak_false);
    }
    const mark = dvui.spacer(@src(), .{ .min_size_content = dvui.Size.all(opts.fontGet().textHeight()), .gravity_y = 0.5 });
    if (row.data().visible()) {
        dvui.checkmark(value.*, row.data().id == dvui.focusedWidgetId(), mark.borderRectScale(), dvui.captured(row.data().id), dvui.hoverFade(row.data().id, hovered), opts);
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .width(dvui.checkbox_defaults.paddingGet().w) });
    dvui.labelNoFmt(@src(), name, .{}, opts.strip().override(.{ .gravity_y = 0.5, .color_text = if (options.label_color) |color| .{ .color = color } else null }));
    return changed;
}

pub fn checkbox(src: std.builtin.SourceLocation, value: *bool, name: []const u8, enabled: bool) bool {
    const opts = checkboxOptions(name, .{});
    if (enabled) return dvui.checkbox(src, value, name, opts);
    const row = dvui.box(src, .{ .dir = .horizontal }, opts.override(.{ .expand = .horizontal, .max_size_content = .width(0), .color_text = .{ .color = theme.colors.muted }, .tab_index = 0 }));
    defer row.deinit();
    if (row.data().accesskit_node()) |node| {
        dvui.AccessKit.nodeSetDisabled(node);
        dvui.AccessKit.nodeSetToggled(node, if (value.*) .ak_true else .ak_false);
    }
    const mark = dvui.spacer(@src(), .{ .min_size_content = dvui.Size.all(opts.fontGet().textHeight()), .gravity_y = 0.5 });
    dvui.checkmark(value.*, false, mark.borderRectScale(), false, 0, opts);
    dvui.labelNoFmt(@src(), name, .{}, .{ .color_text = .{ .color = theme.colors.muted }, .gravity_y = 0.5, .padding = .{ .x = 6 }, .margin = R.all(0) });
    return false;
}

pub fn toggle(src: std.builtin.SourceLocation, value: *bool, name: []const u8, enabled: bool) bool {
    const row = dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = R.all(0), .margin = .{ .h = theme.spacing.field_gap }, .background = false });
    defer row.deinit();
    dvui.labelNoFmt(@src(), name, .{}, .{ .gravity_y = 0.5, .padding = R.all(0), .margin = R.all(0), .color_text = if (enabled) null else .{ .color = theme.colors.muted } });
    var control: dvui.ButtonWidget = undefined;
    control.init(@src(), .{ .grayed = !enabled, .draw_focus = enabled }, .{ .label = .{ .text = name }, .role = .ak_switch, .gravity_x = 1, .min_size_content = .{ .w = style.sizing.switch_width, .h = style.sizing.switch_height }, .max_size_content = .{ .w = style.sizing.switch_width, .h = style.sizing.switch_height }, .padding = R.all(0), .corners = .all(style.sizing.switch_height / 2), .border = R.all(0), .color_fill = .{ .color = if (value.*) style.colors.accent else style.colors.muted }, .tab_index = if (enabled) null else 0 });
    defer control.deinit();
    buttonState(&control, enabled, false);
    const changed = enabled and control.clicked();
    if (changed) value.* = !value.*;
    if (control.data().accesskit_node()) |node| dvui.AccessKit.nodeSetToggled(node, if (value.*) .ak_true else .ak_false);
    const knob = dvui.box(@src(), .{}, .{ .rect = .{ .x = if (value.*) style.sizing.switch_width - style.sizing.switch_inset - style.sizing.switch_knob else style.sizing.switch_inset, .y = style.sizing.switch_inset, .w = style.sizing.switch_knob, .h = style.sizing.switch_knob }, .padding = R.all(0), .margin = R.all(0), .background = true, .border = R.all(0), .corners = .all(style.sizing.switch_knob / 2), .color_fill = .{ .color = style.colors.foreground } });
    knob.deinit();
    return changed;
}

pub fn sidebarTitle(src: std.builtin.SourceLocation, name: []const u8, compact: bool) void {
    _ = compact;
    title(src, name);
}

pub fn sidebarPanel(src: std.builtin.SourceLocation) *dvui.BoxWidget {
    return theme.panel(src, .{}, .{ .expand = .both, .padding = R.all(theme.spacing.sidebar_padding), .margin = .{ .x = theme.spacing.page_margin, .y = theme.spacing.page_margin, .h = theme.spacing.page_margin }, .corners = .all(theme.sidebarRadius()), .background = true, .color_fill = .{ .color = theme.panelColor(theme.colors.surface) }, .border = R.all(1), .color_border = .{ .color = theme.colors.outline } });
}

/// Reserve the navigation footer before the expanding sidebar list.
pub fn sidebarNavigationButton(src: std.builtin.SourceLocation, key: []const u8, name: []const u8, enabled: bool) bool {
    const font = theme.fontSized(theme.typography.body);
    const geometry = theme.controlGeometry(@max(font.lineHeight(), font.textSize(name).h), theme.sizing.control_height, 0, theme.sizing.control_padding_x, theme.sizing.control_border);
    const transparent = theme.style.colors.transparent;
    var control: dvui.ButtonWidget = undefined;
    control.init(src, .{ .grayed = !enabled, .draw_focus = enabled }, .{
        .tag = key,
        .label = .{ .text = name },
        .font = font,
        .expand = .horizontal,
        .max_size_content = .width(0),
        .min_size_content = geometry.content,
        .padding = geometry.padding,
        .margin = R.all(0),
        .border = R.all(theme.sizing.control_border),
        .corners = .all(theme.controlRadius()),
        .background = true,
        .color_border = .{ .color = theme.colors.outline },
        .color_fill = .{ .color = theme.colors.sidebar },
        .color_fill_hover = .{ .color = theme.colors.selected_surface },
        .color_fill_press = .{ .color = style.colors.pressed_surface },
        .tab_index = if (enabled) null else 0,
    });
    defer control.deinit();
    buttonState(&control, enabled, false);
    dvui.labelNoFmt(@src(), name, .{ .ellipsize = true, .align_y = 0.5 }, control.style().override(.{ .font = font, .expand = .horizontal, .max_size_content = .width(0), .gravity_y = 0.5, .padding = R.all(0), .margin = R.all(0), .background = false, .color_fill = .{ .color = transparent }, .color_text = if (!enabled) .{ .color = theme.colors.muted } else null }));
    return enabled and control.clicked();
}

pub fn sidebarFooter(src: std.builtin.SourceLocation, name: []const u8, enabled: bool) bool {
    const row = dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_y = 1, .min_size_content = .{ .h = theme.sizing.control_height }, .padding = R.all(0), .margin = .{ .y = theme.spacing.sidebar_footer_gap }, .background = false });
    defer row.deinit();
    return sidebarNavigationButton(@src(), "home", name, enabled);
}

pub fn scrollBody(src: std.builtin.SourceLocation) *dvui.ScrollAreaWidget {
    return dvui.scrollArea(src, .{ .horizontal = .none }, .{ .expand = .both, .background = false, .padding = R.all(0), .margin = R.all(0), .border = R.all(0) });
}

/// Content-bearing Bento panels share one surface, inset, and spacing rhythm.
pub fn bentoPanel(src: std.builtin.SourceLocation, options: dvui.Options) *dvui.BoxWidget {
    return theme.panel(src, .{}, (dvui.Options{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(style.spacing.panel_padding - style.sizing.control_border), .margin = .{ .h = style.spacing.group_gap }, .border = R.all(style.sizing.control_border), .corners = .all(theme.panelRadius()), .background = true, .color_fill = .{ .color = theme.panelColor(style.colors.surface) }, .color_border = .{ .color = style.colors.outline } }).override(options));
}

/// Form panels own all four visible insets, including the final field's bottom.
pub const FormPanelOptions = struct {
    tag: ?[]const u8 = null,
    compact: bool = false,
    options: dvui.Options = .{},
};

pub fn formPanel(src: std.builtin.SourceLocation, options: FormPanelOptions) *dvui.BoxWidget {
    const inset = if (options.compact) style.spacing.panel_compact_padding else style.spacing.panel_padding;
    return bentoPanel(src, (dvui.Options{ .tag = options.tag, .padding = R.all(inset - style.sizing.control_border) }).override(options.options));
}

/// Two equal fields wrap as one column without changing their font or control size.
pub const FormRow = struct {
    box: *dvui.BoxWidget,
    wide: bool,
    cell_width: f32,

    pub fn cell(self: FormRow, src: std.builtin.SourceLocation, index: usize) *dvui.BoxWidget {
        return dvui.box(src, .{}, .{
            .id_extra = index,
            .expand = if (self.wide) .none else .horizontal,
            .min_size_content = .width(if (self.wide) self.cell_width else 0),
            .max_size_content = .width(if (self.wide) self.cell_width else 0),
            .padding = R.all(0),
            .margin = if (self.wide) .{ .w = if (index == 0) style.spacing.field_gap else 0 } else .{ .h = if (index == 0) style.spacing.field_gap else 0 },
            .background = false,
        });
    }

    pub fn deinit(self: FormRow) void {
        self.box.deinit();
    }
};

pub fn formRow(src: std.builtin.SourceLocation) FormRow {
    const width = dvui.parentGet().data().contentRect().w;
    const wide = width >= style.layout.form_columns_breakpoint;
    return .{
        .box = dvui.box(src, .{ .dir = if (wide) .horizontal else .vertical }, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = R.all(0), .background = false }),
        .wide = wide,
        .cell_width = @max(0, (width - style.spacing.field_gap) / 2),
    };
}

/// Center the actual dialog panel; constrain only to the viewport, never scale text.
pub fn modal(src: std.builtin.SourceLocation, name: []const u8, requested_height: f32) *dvui.FloatingWindowWidget {
    return modalWithClose(src, name, requested_height, null);
}

pub fn modalWithClose(src: std.builtin.SourceLocation, name: []const u8, requested_height: f32, open_flag: ?*bool) *dvui.FloatingWindowWidget {
    const window = modalPanel(src, name, requested_height, open_flag);
    modalTitle(@src(), name, null);
    return window;
}

/// A left aligned 24 px title replaces the platform window header and separator.
pub fn modalTitle(src: std.builtin.SourceLocation, name: []const u8, tag: ?[]const u8) void {
    const label = dvui.textLayout(src, .{}, .{ .tag = tag, .label = .{ .text = name }, .role = .label, .tab_index = 0, .font = theme.titleFont(), .color_text = .{ .color = theme.colors.foreground }, .expand = .horizontal, .min_size_content = .height(style.dialogs.title_height), .max_size_content = .width(0), .padding = R.all(0), .margin = .{ .h = style.dialogs.title_gap }, .background = false });
    label.addText(name, .{});
    label.deinit();
}

/// Shared panel geometry for dialogs with custom task or focus headers.
pub fn modalPanel(src: std.builtin.SourceLocation, name: []const u8, requested_height: f32, open_flag: ?*bool) *dvui.FloatingWindowWidget {
    return fixedModalPanel(src, name, requested_height, open_flag, 0);
}

fn fixedModalPanel(src: std.builtin.SourceLocation, name: []const u8, requested_height: f32, open_flag: ?*bool, id_extra: usize) *dvui.FloatingWindowWidget {
    const viewport = dvui.windowRect();
    const margin = style.spacing.page_margin;
    const width = @max(0, @min(style.layout.modal_width, viewport.w - 2 * margin));
    const height = @max(0, @min(requested_height, viewport.h - 2 * margin));
    const inset = if (viewport.h < style.layout.compact_height) style.layout.compact_modal_padding else style.spacing.modal_padding;
    // InitOptions.rect is read every frame; Options.rect is only read on open.
    // Allocate in the frame arena because deinit writes back to this pointer.
    const rect = dvui.widgetAlloc(R);
    rect.* = .{ .x = viewport.x + (viewport.w - width) / 2, .y = viewport.y + (viewport.h - height) / 2, .w = width, .h = height };
    const window = dvui.floatingWindow(src, .{ .rect = rect, .modal = true, .modal_alpha = 120, .open_flag = open_flag, .resize = .none, .window_avoid = .none }, .{
        .id_extra = id_extra,
        .min_size_content = .{ .w = @max(0, width - 2 * inset), .h = @max(0, height - 2 * inset) },
        .max_size_content = .{ .w = @max(0, width - 2 * inset), .h = @max(0, height - 2 * inset) },
        .padding = R.all(@max(0, inset - 1)),
        .margin = R.all(0),
        .border = R.all(1),
        .corners = .all(theme.modalRadius()),
        .color_fill = .{ .color = theme.panelColor(theme.colors.surface) },
        .color_text = .{ .color = dvui.Color.black },
        .color_border = .{ .color = theme.colors.control_outline },
        .label = .{ .text = name },
    });
    // FloatingWindow defaults to dragging on all unused panel space.
    window.dragAreaSet(.{});
    if (open_flag) |flag| {
        for (dvui.events()) |*event| {
            if (!dvui.eventMatch(event, .{ .id = window.data().id, .focus_id = dvui.focusedWidgetIdInCurrentSubwindow(), .r = window.data().rectScale().r })) continue;
            if (event.evt == .key and event.evt.key.action == .down and event.evt.key.code == .escape) {
                event.handle(@src(), window.data());
                flag.* = false;
            }
        }
    }
    return window;
}

pub fn toolbar(src: std.builtin.SourceLocation) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = R.all(0), .margin = .{ .y = theme.spacing.row_gap, .h = theme.spacing.row_gap }, .background = false });
}

/// Only the More > Game overview uses these navigation cards.
pub fn managementCard(src: std.builtin.SourceLocation, name: []const u8, asset: []const u8) bool {
    var card: dvui.ButtonWidget = undefined;
    card.init(src, .{}, .{ .expand = .both, .min_size_content = .{ .h = style.cards.management_content_height }, .max_size_content = .width(0), .padding = R.all(style.spacing.panel_padding - style.sizing.control_border), .margin = R.all(0), .corners = .all(theme.panelRadius()), .border = R.all(style.sizing.control_border), .color_fill = .{ .color = theme.panelColor(style.colors.surface) }, .color_fill_hover = .{ .color = theme.panelColor(style.colors.selected_surface) }, .color_fill_press = .{ .color = theme.panelColor(style.colors.pressed_surface) }, .color_border = .{ .color = style.colors.outline }, .label = .{ .text = name } });
    defer card.deinit();
    buttonState(&card, true, true);
    {
        const contents = dvui.box(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .gravity_y = 0.5 });
        defer contents.deinit();
        dvui.icon(@src(), name, asset, .{}, card.style().override(.{ .min_size_content = dvui.Size.all(style.cards.management_icon), .color_text = .{ .color = style.colors.accent }, .role = .none, .padding = R.all(0), .margin = .{ .h = style.cards.management_icon_gap } }));
        controlText(@src(), name, card.style().override(.{ .font = theme.headingFont(), .padding = R.all(0), .margin = R.all(0) }));
    }
    return card.clicked();
}

pub const NavigationAction = enum { none, back, home };

/// Reserve the shared parent-page return before the expanding sidebar list.
pub fn navigationFooter(src: std.builtin.SourceLocation, parent_label: []const u8, with_back: bool) NavigationAction {
    const clicked = sidebarFooter(src, parent_label, true);
    return if (clicked) (if (with_back) .back else .home) else .none;
}

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme.zig");
const R = dvui.Rect;

pub const ItemOptions = struct {
    icon: ?[]const u8 = null,
    selected: bool = false,
    enabled: bool = true,
    indent: f32 = 0,
    subtitle: ?[]const u8 = null,
};

/// Flat sidebar actions, navigation and disclosure rows share states and identity.
pub fn sidebarItem(src: std.builtin.SourceLocation, key: []const u8, name: []const u8, options: ItemOptions) bool {
    const name_height = @max(24, dvui.themeGet().font_body.textSize(name).h);
    const subtitle_font = dvui.themeGet().font_body.withSize(14);
    const subtitle_height = if (options.subtitle) |subtitle| subtitle_font.textSize(subtitle).h else 0;
    const height = name_height + if (options.subtitle != null) subtitle_height + 4 else @as(f32, 0);
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{ .draw_focus = options.enabled }, .{
        .id_extra = @as(usize, @truncate(std.hash.Wyhash.hash(0, key))),
        .label = .{ .text = name },
        .expand = .horizontal,
        .max_size_content = .width(0),
        .min_size_content = .{ .h = height },
        .padding = R.all(6),
        .margin = .{ .x = options.indent, .h = 4 },
        .corners = .all(4),
        .border = R.all(1),
        .color_border = .{ .color = if (options.selected) theme.accent else dvui.Color.fromHex("00000000") },
        .color_fill = .{ .color = dvui.Color.fromHex("00000000") },
        .color_fill_hover = .{ .color = dvui.Color.fromHex("2B362F") },
        .color_fill_press = .{ .color = dvui.Color.fromHex("38483C") },
        .color_text = if (!options.enabled) .{ .color = theme.muted } else if (options.selected) .{ .color = theme.accent } else null,
        .tab_index = if (options.enabled) null else 0,
    });
    defer button.deinit();
    if (options.enabled) button.processEvents() else button.processHover();
    button.drawBackground();
    const row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = height },
        .padding = R.all(0),
        .margin = R.all(0),
    });
    {
        defer row.deinit();
        if (options.icon) |asset| dvui.icon(@src(), name, asset, .{}, button.style().override(.{
            .min_size_content = .{ .w = 20, .h = 20 },
            .max_size_content = .{ .w = 20, .h = 20 },
            .gravity_y = 0.5,
            .padding = R.all(0),
            .margin = .{ .w = 8 },
            .role = .none,
        }));
        const lines = dvui.box(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = R.all(0) });
        defer lines.deinit();
        const label = dvui.textLayout(@src(), .{ .break_lines = false }, button.style().override(.{
            .expand = .horizontal,
            .min_size_content = .{ .h = name_height },
            .max_size_content = .{ .w = 0, .h = name_height },
            .background = false,
            .padding = R.all(0),
            .margin = R.all(0),
        }));
        label.addText(name, .{});
        label.deinit();
        if (options.subtitle) |subtitle| {
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 4 } });
            const detail = dvui.textLayout(@src(), .{ .break_lines = false }, button.style().override(.{
                .expand = .horizontal,
                .min_size_content = .{ .h = subtitle_height },
                .max_size_content = .{ .w = 0, .h = subtitle_height },
                .font = subtitle_font,
                .color_text = .{ .color = theme.muted },
                .background = false,
                .padding = R.all(0),
                .margin = R.all(0),
            }));
            detail.addText(subtitle, .{});
            detail.deinit();
        }
    }
    if (options.enabled) button.drawFocus();
    const hint = if (options.subtitle) |subtitle| std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}\n{s}", .{ name, subtitle }) catch name else name;
    tooltip(src, button.data().id, button.data().borderRectScale().r, hint);
    return options.enabled and button.clicked();
}

pub const tooltip_hover_delay_us: i32 = 600_000;
pub const tooltip_gap_px: f32 = 8;

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
    const content_width = @max(1, @min(@as(f32, 360), available_width - 14));
    const available_height = if (horizontal) screen.h else @max(placement_rect.y - screen.y, screen.y + screen.h - placement_rect.y - placement_rect.h);
    const content_height = @max(1, available_height - 14);
    var floating: dvui.FloatingTooltipWidget = undefined;
    floating.init(src, .{
        .active_rect = active_rect,
        .position = .absolute,
        .interactive = false,
        .scale = 1,
    }, .{
        .id_extra = @as(usize, @truncate(@intFromEnum(control_id))),
        .role = .tooltip,
        .label = .{ .text = value },
        .tab_index = 0,
        .padding = R.all(6),
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
        if (floating.data().accesskit_node()) |node| dvui.AccessKit.nodeSetLabel(node, dvui.currentWindow().arena().dupeZ(u8, value) catch "");
    }
}

pub fn section(src: std.builtin.SourceLocation, name: []const u8) void {
    dvui.labelNoFmt(src, name, .{}, .{
        .expand = .horizontal,
        .max_size_content = .width(0),
        .font = dvui.themeGet().font_body.withSize(14),
        .color_text = .{ .color = theme.muted },
        .background = false,
        .padding = R.all(0),
        .margin = .{ .y = 12, .h = 4 },
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
    text(src, value, theme.muted);
}

pub fn action(src: std.builtin.SourceLocation, name: []const u8, enabled: bool) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{ .grayed = !enabled, .draw_focus = enabled }, .{
        .label = .{ .text = name },
        .padding = R.all(8),
        .margin = .{ .w = 8, .h = 8 },
        .corners = .all(4),
        .tab_index = if (enabled) null else 0,
    });
    defer button.deinit();
    if (enabled) button.processEvents();
    button.drawBackground();
    dvui.labelNoFmt(@src(), name, .{ .align_y = 0.5 }, button.style().override(.{
        .background = false,
        .padding = R.all(0),
        .margin = R.all(0),
    }));
    if (enabled) button.drawFocus();
    return enabled and button.clicked();
}

pub const FormAction = enum { none, save, cancel };
pub const FormOptions = struct {
    save_enabled: bool = true,
    cancel_enabled: bool = true,
    save_label: []const u8 = "保存",
    cancel_label: []const u8 = "取消",
};

/// Reserve this footer before drawing an expanding editor body. Callers queue
/// its result and save or discard only after all widgets have closed.
pub fn formActions(src: std.builtin.SourceLocation, options: FormOptions) FormAction {
    const footer = dvui.box(src, .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .gravity_y = 1,
        .min_size_content = .{ .h = 48 },
        .padding = R.all(0),
        .margin = .{ .y = 12 },
        .background = false,
    });
    defer footer.deinit();
    const cancel = formButton(@src(), options.cancel_label, options.cancel_enabled, false, false);
    const save = formButton(@src(), options.save_label, options.save_enabled, true, true);
    return if (cancel) .cancel else if (save) .save else .none;
}

fn formButton(src: std.builtin.SourceLocation, name: []const u8, enabled: bool, primary: bool, right: bool) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{ .grayed = !enabled, .draw_focus = enabled }, .{
        .label = .{ .text = name },
        .gravity_x = if (right) 1 else 0,
        .padding = R.all(10),
        .margin = R.all(0),
        .corners = .all(4),
        .style = if (primary) .highlight else .control,
        .tab_index = if (enabled) null else 0,
    });
    defer button.deinit();
    if (enabled) button.processEvents();
    button.drawBackground();
    dvui.labelNoFmt(@src(), name, .{ .align_y = 0.5 }, button.style().override(.{ .padding = R.all(0), .margin = R.all(0), .background = false }));
    if (enabled) button.drawFocus();
    return enabled and button.clicked();
}

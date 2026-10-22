//! Resource type selector. Native floating subwindow, outside sidebar layout/clipping.
const std = @import("std");
const dvui = @import("dvui");
const local = @import("../core/local_content.zig");
const theme = @import("theme.zig");
const R = dvui.Rect;
const delay_ns = 200 * std.time.ns_per_ms;
const kinds = [_]local.Kind{ .mod, .resourcepack, .shader };
const titles = [_][]const u8{ "模组", "资源包", "光影" };
const tags = [_][]const u8{ "resource-type-mod", "resource-type-resourcepack", "resource-type-shader" };

pub const Mode = enum { closed, hover, pinned };

/// Retained interaction state; owns no allocations or borrowed frame pointers.
pub const State = struct {
    mode: Mode = .closed,
    hover_started_ns: ?i128 = null,
    leave_started_ns: ?i128 = null,
    suppress_hover: bool = false,
    focused_index: usize = 0,
    focus_pending: bool = false,
    trigger_id: ?dvui.Id = null,
    trigger_window: ?dvui.Id = null,
    menu_id: ?dvui.Id = null,
    item_ids: [3]?dvui.Id = @splat(null),

    /// Also used when the owning page/route becomes inactive or locked.
    pub fn close(self: *State) void {
        self.mode = .closed;
        self.hover_started_ns = null;
        self.leave_started_ns = null;
        self.focus_pending = false;
        self.suppress_hover = true;
    }

    fn trigger(self: *State) void {
        if (self.mode == .pinned) self.close() else {
            self.mode = .pinned;
            self.hover_started_ns = null;
            self.leave_started_ns = null;
        }
    }

    fn keyboardOpen(self: *State, current: local.Kind) void {
        self.mode = .pinned;
        self.hover_started_ns = null;
        self.leave_started_ns = null;
        self.focused_index = indexOf(current);
        self.focus_pending = true;
    }

    /// Trigger and safe-region membership are separate: dismissal suppression is
    /// released only by actually leaving the trigger, not by a timer expiring.
    fn pointer(self: *State, now: i128, on_trigger: bool, in_safe_region: bool) void {
        if (!on_trigger) self.suppress_hover = false;
        switch (self.mode) {
            .closed => {
                self.leave_started_ns = null;
                if (!on_trigger or self.suppress_hover) {
                    self.hover_started_ns = null;
                } else {
                    if (self.hover_started_ns == null) self.hover_started_ns = now;
                    if (now - self.hover_started_ns.? >= delay_ns) {
                        self.mode = .hover;
                        self.hover_started_ns = null;
                    }
                }
            },
            .hover => {
                if (in_safe_region) {
                    self.leave_started_ns = null;
                } else {
                    if (self.leave_started_ns == null) self.leave_started_ns = now;
                    if (now - self.leave_started_ns.? >= delay_ns) {
                        self.mode = .closed;
                        self.leave_started_ns = null;
                    }
                }
            },
            .pinned => {},
        }
    }

    fn deadline(self: *const State) ?i128 {
        const start = self.hover_started_ns orelse self.leave_started_ns orelse return null;
        return start + delay_ns;
    }
};

fn indexOf(kind: local.Kind) usize {
    for (kinds, 0..) |value, i| if (kind == value) return i;
    unreachable;
}

/// All geometry is in window-natural coordinates, never physical mouse pixels.
/// Scale is the trigger's parent scale relative to the window's natural scale.
pub fn menuRect(trigger: R, window: R, scale: f32) R {
    const inset = 8 * scale;
    const left = window.x + inset;
    const top = window.y + inset;
    const right = @max(left, window.x + window.w - inset);
    const bottom = @max(top, window.y + window.h - inset);
    const width = @min(200 * scale, right - left);
    const height = @min(162 * scale, bottom - top);
    var x = trigger.x + trigger.w + inset;
    if (x + width > right) x = trigger.x - inset - width;
    return .{
        .x = std.math.clamp(x, left, @max(left, right - width)),
        .y = std.math.clamp(trigger.y, top, @max(top, bottom - height)),
        .w = width,
        .h = height,
    };
}

/// Only bridge the horizontal gap, including when bottom clamping shifts the
/// menu upward. The surrounding page is not part of the hover-safe region.
fn corridor(trigger: R, menu: R) R {
    const top = @min(trigger.y, menu.y);
    const bottom = @max(trigger.y + trigger.h, menu.y + menu.h);
    if (menu.x >= trigger.x + trigger.w) return .{ .x = trigger.x + trigger.w, .y = top, .w = menu.x - trigger.x - trigger.w, .h = bottom - top };
    if (menu.x + menu.w <= trigger.x) return .{ .x = menu.x + menu.w, .y = top, .w = trigger.x - menu.x - menu.w, .h = bottom - top };
    return .{};
}

fn restoreTrigger(state: *const State, event_num: ?u16) void {
    dvui.focusSubwindow(state.trigger_window, event_num);
    dvui.focusWidget(state.trigger_id, state.trigger_window, event_num);
}

fn menuFocused(state: *const State) bool {
    return if (state.menu_id) |id| id == dvui.focusedSubwindowId() else false;
}

fn itemTarget(state: *const State, target: ?dvui.Id) bool {
    const id = target orelse return false;
    for (state.item_ids) |item| if (item == id) return true;
    return false;
}

fn focusItem(state: *State, event_num: ?u16) void {
    if (state.item_ids[state.focused_index]) |id| {
        dvui.focusSubwindow(state.menu_id, event_num);
        dvui.focusWidget(id, state.menu_id, event_num);
    } else state.focus_pending = true;
}

fn text(src: std.builtin.SourceLocation, value: []const u8, rect: R, font: dvui.Font, color: dvui.Color) void {
    dvui.labelNoFmt(src, value, .{ .align_y = 0.5 }, .{
        .rect = rect,
        .font = font,
        .color_text = .{ .color = color },
        .padding = .all(0),
        .margin = .all(0),
        .background = false,
        .role = .none,
    });
}

fn icon(src: std.builtin.SourceLocation, name: []const u8, asset: []const u8, rect: R, color: dvui.Color) void {
    dvui.icon(src, name, asset, .{}, .{
        .rect = rect,
        .min_size_content = .{ .w = rect.w, .h = rect.h },
        .color_text = .{ .color = color },
        .padding = .all(0),
        .margin = .all(0),
        .background = false,
        .role = .none,
    });
}

/// Draw one fixed 48px full-width trigger and, when open, a native floating
/// layer. Returns only a changed kind; choosing the current kind just dismisses.
/// Hover never changes focus. Keyboard opening focuses the current menu item.
pub fn draw(src: std.builtin.SourceLocation, state: *State, current: local.Kind, enabled: bool) ?local.Kind {
    var result: ?local.Kind = null;
    var control: dvui.ButtonWidget = undefined;
    control.init(src, .{ .draw_focus = enabled, .grayed = !enabled }, .{
        .tag = "resource-type-button",
        .label = .{ .text = "资源类型" },
        .expand = .horizontal,
        .min_size_content = .height(46),
        .max_size_content = .width(0),
        .padding = .all(0),
        .margin = .all(0),
        .border = .all(1),
        .corners = .all(12),
        .color_border = .{ .color = if (state.mode == .pinned and enabled) theme.selected_text else theme.control_outline },
        .color_fill = .{ .color = if (state.mode != .closed and enabled) theme.selected_surface else theme.sidebar },
        .color_fill_hover = .{ .color = theme.selected_surface },
        .tab_index = if (enabled) null else 0,
    });
    state.trigger_id = control.data().id;
    state.trigger_window = dvui.subwindowCurrentId();
    const window_scale = dvui.windowRectScale();
    const trigger_rect = window_scale.rectFromPhysical(control.data().borderRectScale().r);
    const scale = control.data().rectScale().s / dvui.windowNaturalScale();
    const menu_rect = menuRect(trigger_rect, .cast(dvui.windowRect()), scale);
    const bridge = corridor(trigger_rect, menu_rect);
    const now = dvui.frameTimeNS();
    var on_trigger = false;
    var safe = false;
    for (dvui.events()) |event| {
        if (event.evt == .mouse and event.evt.mouse.action == .position) {
            const point = window_scale.pointFromPhysical(event.evt.mouse.p);
            // A modal/other subwindow covering the trigger must not open it.
            on_trigger = trigger_rect.contains(point) and event.evt.mouse.floating_win == state.trigger_window.?;
            safe = on_trigger or menu_rect.contains(point) or bridge.contains(point);
        }
    }
    var keyboard_opened = false;
    var focus_event_num: ?u16 = null;
    if (!enabled) {
        if (menuFocused(state)) restoreTrigger(state, null);
        state.close();
    } else {
        state.pointer(now, on_trigger, safe);
        // Match the native button's focus event before routing keys. Backends can
        // queue a click and keys in one frame; addEventKey initially targets the
        // old focus, and focusWidget(event.num) retargets only subsequent events.
        for (dvui.events()) |*event| {
            if (event.evt == .mouse and event.evt.mouse.action == .focus and control.matchEvent(event)) {
                dvui.focusWidget(state.trigger_id, state.trigger_window, event.num);
            }
        }
        // Observe outside clicks even if an earlier sidebar control handled them.
        // Let the original event continue to the intended page control.
        for (dvui.events()) |*event| {
            if (state.mode != .closed and event.evt == .mouse and (event.evt.mouse.action == .focus or event.evt.mouse.action == .press)) {
                const point = window_scale.pointFromPhysical(event.evt.mouse.p);
                if (!trigger_rect.contains(point) and !menu_rect.contains(point)) {
                    if (menuFocused(state)) dvui.focusSubwindow(state.trigger_window, event.num);
                    state.close();
                }
            }
            if (event.handled or event.evt != .key or event.evt.key.action == .up) continue;
            const key = event.evt.key;
            const trigger_target = event.target_widgetId == state.trigger_id;
            // Before the first row is registered, keyboard opening owns later
            // trigger-targeted keys too. Transfer native focus after drawing it.
            const menu_target = itemTarget(state, event.target_widgetId) or (state.focus_pending and trigger_target);
            // Keys belong to their native focus target. A foreign floating modal
            // is drawn later and must receive its Escape/Tab without focus theft.
            const focused_window = dvui.focusedSubwindowId();
            const local_focus = focused_window == state.trigger_window or menuFocused(state);
            if (!trigger_target and !menu_target and !(local_focus and event.target_widgetId == dvui.focusedWidgetId())) continue;
            if (state.mode != .closed and key.code == .escape) {
                event.handle(@src(), control.data());
                state.close();
                restoreTrigger(state, event.num);
            } else if (state.mode != .closed and key.code == .tab) {
                const had_menu_focus = menuFocused(state);
                state.close();
                if (had_menu_focus) {
                    restoreTrigger(state, event.num);
                    // Traverse the parent window's normal tab order, once.
                    if (key.matchBind("prev_widget")) dvui.tabIndexPrev(event.num) else dvui.tabIndexNext(event.num);
                    event.handle(@src(), control.data());
                }
            } else if (trigger_target and !menu_target and (key.code == .enter or key.code == .space or key.code == .right)) {
                event.handle(@src(), control.data());
                state.keyboardOpen(current);
                keyboard_opened = true;
                focus_event_num = event.num;
            } else if (state.mode != .closed and menu_target) {
                if (key.code == .up or key.code == .down) {
                    event.handle(@src(), control.data());
                    state.focused_index = if (key.code == .down) (state.focused_index + 1) % 3 else (state.focused_index + 2) % 3;
                    if (state.focus_pending) focus_event_num = event.num else focusItem(state, event.num);
                } else if (key.action == .down and (key.code == .enter or key.code == .space)) {
                    event.handle(@src(), control.data());
                    const next = kinds[state.focused_index];
                    if (next != current) result = next;
                    state.close();
                    restoreTrigger(state, event.num);
                }
            }
        }
    }
    if (enabled) {
        control.processEvents();
        // A same-frame pointer click must not toggle closed after keyboardOpen.
        if (control.clicked() and !keyboard_opened) state.trigger();
    } else {
        control.processHover();
    }
    if (control.data().accesskit_node()) |node| {
        dvui.AccessKit.nodeSetExpanded(node, state.mode != .closed);
        if (!enabled) {
            dvui.AccessKit.nodeSetDisabled(node);
            dvui.AccessKit.nodeRemoveAction(node, .click);
            dvui.AccessKit.nodeRemoveAction(node, .focus);
        }
    }
    control.data().options.color_fill = .{ .color = if (state.mode != .closed and enabled) theme.selected_surface else theme.sidebar };
    control.data().options.color_border = .{ .color = if (state.mode == .pinned and enabled) theme.selected_text else theme.control_outline };
    control.drawBackground();
    const width = control.data().contentRect().w;
    const height = control.data().contentRect().h;
    text(@src(), "资源类型", .{ .x = 15, .w = 72, .h = height }, theme.bodyFont(), if (enabled) theme.foreground else theme.muted);
    const title = titles[indexOf(current)];
    const title_width = theme.captionFont().textSize(title).w;
    text(@src(), title, .{ .x = @max(87, width - 47 - title_width), .w = title_width, .h = height }, theme.captionFont(), theme.muted);
    icon(@src(), "展开资源类型", dvui.entypo.chevron_small_right, .{ .x = width - 31, .y = (height - 16) / 2, .w = 16, .h = 16 }, if (enabled) theme.foreground else theme.muted);
    if (enabled) control.drawFocus();
    const trigger_id = control.data().id;
    control.deinit();

    if (state.deadline()) |due| {
        const micros = std.math.clamp(@divTrunc(due - now, std.time.ns_per_us), 1, std.math.maxInt(i32));
        dvui.timer(trigger_id.update("resource-menu-delay"), @intCast(micros));
    }
    if (state.mode == .closed) return result;

    // FloatingMenuWidget intentionally takes focus on its second frame. This
    // native layer leaves content focus alone until an explicit keyboard action.
    var floating: dvui.FloatingWidget = undefined;
    floating.init(@src(), .{}, .{
        .rect = menu_rect,
        .tag = "resource-type-menu",
        .role = .menu,
        .label = .{ .text = "资源类型" },
        .border = .all(scale),
        .corners = .all(12 * scale),
        .padding = .all(8 * scale),
        .margin = .all(0),
        .background = true,
        .color_fill = .{ .color = theme.surface },
        .color_border = .{ .color = theme.control_outline },
    });
    defer floating.deinit();
    state.menu_id = floating.data().id;
    const content_width = floating.data().contentRect().w / scale;
    for (kinds, 0..) |kind, i| {
        var item: dvui.ButtonWidget = undefined;
        item.init(@src(), .{}, .{
            .id_extra = i,
            .tag = tags[i],
            .role = .menu_item_radio,
            .label = .{ .text = titles[i] },
            .rect = .{ .x = 0, .y = @as(f32, @floatFromInt(i)) * 48, .w = content_width, .h = 48 },
            .padding = .all(0),
            .margin = .all(0),
            .border = .all(0),
            .corners = .all(8),
            .color_fill = .{ .color = if (kind == current) theme.selected_surface else theme.surface },
            .color_fill_hover = .{ .color = theme.style.colors.pressed_surface },
        });
        state.item_ids[i] = item.data().id;
        if (state.focus_pending and state.focused_index == i) {
            focusItem(state, focus_event_num);
            state.focus_pending = false;
        }
        // Native buttons focus their widget, but FloatingWidget deliberately
        // does not focus the subwindow. Only an actual click may do that here.
        for (dvui.events()) |*event| {
            if (event.evt == .mouse and event.evt.mouse.action == .focus and item.matchEvent(event)) {
                dvui.focusSubwindow(state.menu_id, event.num);
                state.focused_index = i;
            }
        }
        item.processEvents();
        if (item.data().accesskit_node()) |node| dvui.AccessKit.nodeSetSelected(node, kind == current);
        item.drawBackground();
        text(@src(), titles[i], .{ .x = 16, .w = @max(0, content_width - 56), .h = 48 }, theme.bodyFont(), if (kind == current) theme.selected_text else theme.foreground);
        if (kind == current) icon(@src(), "当前类型", dvui.entypo.check, .{ .x = content_width - 32, .y = 16, .w = 16, .h = 16 }, theme.accent);
        item.drawFocus();
        const chosen = item.clicked();
        item.deinit();
        if (chosen) {
            if (kind != current) result = kind;
            state.close();
            restoreTrigger(state, null);
        }
    }
    return result;
}

test "resource menu hover delays, corridor grace, and pinned dismissal" {
    var state: State = .{};
    state.pointer(0, true, true);
    state.pointer(delay_ns - 1, true, true);
    try std.testing.expectEqual(Mode.closed, state.mode);
    state.pointer(delay_ns, true, true);
    try std.testing.expectEqual(Mode.hover, state.mode);
    // Crossing the gap and entering the menu keep a hover menu alive.
    state.pointer(2 * delay_ns, false, true);
    state.pointer(3 * delay_ns, false, false);
    state.pointer(4 * delay_ns - 1, false, false);
    try std.testing.expectEqual(Mode.hover, state.mode);
    state.pointer(4 * delay_ns, false, true);
    try std.testing.expect(state.leave_started_ns == null);
    state.trigger();
    state.pointer(10 * delay_ns, false, false);
    try std.testing.expectEqual(Mode.pinned, state.mode);
    state.trigger();
    try std.testing.expectEqual(Mode.closed, state.mode);
    state.pointer(11 * delay_ns, true, true);
    state.pointer(20 * delay_ns, true, true);
    try std.testing.expectEqual(Mode.closed, state.mode);
    state.pointer(21 * delay_ns, false, false);
    state.pointer(22 * delay_ns, true, true);
    state.pointer(23 * delay_ns, true, true);
    try std.testing.expectEqual(Mode.hover, state.mode);
    state.pointer(24 * delay_ns, false, false);
    state.pointer(25 * delay_ns, false, false);
    try std.testing.expectEqual(Mode.closed, state.mode);
}

test "resource menu keyboard opening and dismissal require a fresh pointer entry" {
    var state: State = .{};
    state.keyboardOpen(.shader);
    try std.testing.expectEqual(@as(usize, 2), state.focused_index);
    try std.testing.expect(state.focus_pending and state.mode == .pinned);
    state.close();
    state.pointer(0, true, true);
    state.pointer(10 * delay_ns, true, true);
    try std.testing.expectEqual(Mode.closed, state.mode);
    // Explicit input remains available while automatic hover is suppressed.
    state.trigger();
    try std.testing.expectEqual(Mode.pinned, state.mode);
}

test "resource menu bounds and safe corridor in both directions and scaled windows" {
    const window: R = .{ .w = 800, .h = 600 };
    const trigger: R = .{ .x = 24, .y = 520, .w = 220, .h = 48 };
    const menu = menuRect(trigger, window, 1);
    try std.testing.expectEqual(@as(f32, 252), menu.x);
    try std.testing.expectEqual(@as(f32, 430), menu.y);
    try std.testing.expect(corridor(trigger, menu).contains(.{ .x = 248, .y = 540 }));
    try std.testing.expect(!corridor(trigger, menu).contains(.{ .x = 300, .y = 400 }));
    const right_trigger: R = .{ .x = 650, .y = 30, .w = 120, .h = 48 };
    const opposite = menuRect(right_trigger, window, 1);
    try std.testing.expectEqual(@as(f32, 442), opposite.x);
    try std.testing.expect(corridor(right_trigger, opposite).contains(.{ .x = 646, .y = 50 }));
    const small = menuRect(trigger, .{ .w = 180, .h = 140 }, 1);
    try std.testing.expect(small.x >= 8 and small.y >= 8 and small.x + small.w <= 172 and small.y + small.h <= 132);
    const scaled = menuRect(.{ .x = 48, .y = 100, .w = 440, .h = 96 }, .{ .w = 1600, .h = 1200 }, 2);
    try std.testing.expectEqual(@as(f32, 504), scaled.x);
    try std.testing.expectEqual(@as(f32, 400), scaled.w);
}

test "resource menu focus routes click and keyboard events in one frame" {
    const Fixture = struct {
        var state: State = .{};
        var chosen: ?local.Kind = null;
        var current: local.Kind = .mod;
        var enabled: bool = true;
        var back_clicked: bool = false;
        var foreign_open: bool = false;
        var foreign_focus_pending: bool = false;
        var foreign_id: ?dvui.Id = null;
        var foreign_escape: bool = false;
        var foreign_tab: bool = false;

        fn frame() !dvui.App.Result {
            // Keep this focus test usable with SDL's cursorless dummy driver.
            dvui.cursorSet(.arrow);
            back_clicked = dvui.button(@src(), "Back", .{}, .{ .rect = .{ .x = 20, .y = 300, .w = 220, .h = 48 }, .tag = "resource-menu-test-back" });
            const box = dvui.box(@src(), .{}, .{ .rect = .{ .x = 20, .y = 200, .w = 220, .h = 48 }, .padding = .all(0), .margin = .all(0) });
            chosen = draw(@src(), &state, current, enabled);
            box.deinit();
            _ = dvui.button(@src(), "After", .{}, .{ .rect = .{ .x = 300, .y = 300, .w = 220, .h = 48 }, .tag = "resource-menu-test-after" });
            // Draw after the underlying selector, just like the shutdown dialog.
            if (foreign_open) {
                const modal = dvui.floatingWindow(@src(), .{ .modal = true, .resize = .none }, .{ .rect = .{ .x = 260, .y = 20, .w = 280, .h = 150 }, .tag = "resource-menu-test-modal" });
                defer modal.deinit();
                foreign_id = modal.data().id;
                var button: dvui.ButtonWidget = undefined;
                button.init(@src(), .{}, .{ .tag = "resource-menu-test-modal-button", .rect = .{ .w = 160, .h = 48 } });
                defer button.deinit();
                if (foreign_focus_pending) {
                    dvui.focusSubwindow(foreign_id, null);
                    dvui.focusWidget(button.data().id, foreign_id, null);
                    foreign_focus_pending = false;
                }
                for (dvui.events()) |*event| {
                    if (!dvui.eventMatch(event, .{ .id = modal.data().id, .focus_id = dvui.focusedWidgetIdInCurrentSubwindow(), .r = modal.data().rectScale().r })) continue;
                    if (event.evt == .key and event.evt.key.action == .down) {
                        if (event.evt.key.code == .escape) {
                            foreign_escape = true;
                            event.handle(@src(), modal.data());
                        } else if (event.evt.key.code == .tab) foreign_tab = true;
                    }
                }
                button.processEvents();
                button.drawBackground();
            }
            return .ok;
        }
    };
    Fixture.state = .{};
    Fixture.chosen = null;
    Fixture.current = .mod;
    Fixture.enabled = true;
    Fixture.back_clicked = false;
    Fixture.foreign_open = false;
    Fixture.foreign_focus_pending = false;
    Fixture.foreign_id = null;
    Fixture.foreign_escape = false;
    Fixture.foreign_tab = false;
    var test_ui = try dvui.testing.init(.{});
    defer test_ui.deinit();
    try dvui.testing.settle(Fixture.frame);
    try dvui.testing.moveTo("resource-type-button");
    try dvui.testing.click(.left);
    // Backends may enqueue the click and the first key before the next draw.
    try dvui.testing.pressKey(.right, .none);
    _ = try dvui.testing.step(Fixture.frame);
    try std.testing.expect(menuFocused(&Fixture.state));
    try dvui.testing.expectFocused("resource-type-mod");
    try dvui.testing.pressKey(.down, .none);
    _ = try dvui.testing.step(Fixture.frame);
    try dvui.testing.expectFocused("resource-type-resourcepack");
    try dvui.testing.pressKey(.enter, .none);
    _ = try dvui.testing.step(Fixture.frame);
    try std.testing.expectEqual(local.Kind.resourcepack, Fixture.chosen.?);
    try std.testing.expectEqual(Mode.closed, Fixture.state.mode);
    try dvui.testing.expectFocused("resource-type-button");
    try std.testing.expect(!Fixture.back_clicked);
    for ([_]dvui.enums.Key{ .enter, .space, .right }) |key| {
        try dvui.testing.pressKey(key, .none);
        _ = try dvui.testing.step(Fixture.frame);
        try dvui.testing.expectFocused("resource-type-mod");
        try dvui.testing.pressKey(.escape, .none);
        _ = try dvui.testing.step(Fixture.frame);
        try dvui.testing.expectFocused("resource-type-button");
        try std.testing.expectEqual(Mode.closed, Fixture.state.mode);
    }
    // Exercise the entire quick sequence in one native event batch as well.
    try dvui.testing.click(.left);
    try dvui.testing.pressKey(.right, .none);
    try dvui.testing.pressKey(.down, .none);
    try dvui.testing.pressKey(.space, .none);
    _ = try dvui.testing.step(Fixture.frame);
    try std.testing.expectEqual(local.Kind.resourcepack, Fixture.chosen.?);
    try std.testing.expect(!Fixture.back_clicked);
    try dvui.testing.pressKey(.right, .none);
    _ = try dvui.testing.step(Fixture.frame);
    try dvui.testing.pressKey(.tab, .none);
    _ = try dvui.testing.step(Fixture.frame);
    try std.testing.expectEqual(Mode.closed, Fixture.state.mode);
    try dvui.testing.expectFocused("resource-menu-test-after");
    dvui.focusWidget(Fixture.state.trigger_id, Fixture.state.trigger_window, null);
    try dvui.testing.pressKey(.right, .none);
    _ = try dvui.testing.step(Fixture.frame);
    try dvui.testing.pressKey(.tab, .lshift);
    _ = try dvui.testing.step(Fixture.frame);
    try dvui.testing.expectFocused("resource-menu-test-back");
    Fixture.current = .shader;
    dvui.focusWidget(Fixture.state.trigger_id, Fixture.state.trigger_window, null);
    try dvui.testing.pressKey(.right, .none);
    _ = try dvui.testing.step(Fixture.frame);
    try dvui.testing.expectFocused("resource-type-shader");
    try dvui.testing.pressKey(.up, .none);
    _ = try dvui.testing.step(Fixture.frame);
    try dvui.testing.expectFocused("resource-type-resourcepack");
    try dvui.testing.pressKey(.space, .none);
    _ = try dvui.testing.step(Fixture.frame);
    try std.testing.expectEqual(local.Kind.resourcepack, Fixture.chosen.?);
    Fixture.current = .resourcepack;
    try dvui.testing.pressKey(.enter, .none);
    _ = try dvui.testing.step(Fixture.frame);
    try dvui.testing.expectFocused("resource-type-resourcepack");
    try dvui.testing.pressKey(.enter, .none);
    _ = try dvui.testing.step(Fixture.frame);
    try std.testing.expect(Fixture.chosen == null);
    try std.testing.expectEqual(Mode.closed, Fixture.state.mode);
    try dvui.testing.pressKey(.right, .none);
    _ = try dvui.testing.step(Fixture.frame);
    try std.testing.expectEqual(Mode.pinned, Fixture.state.mode);
    Fixture.foreign_open = true;
    Fixture.foreign_focus_pending = true;
    _ = try dvui.testing.step(Fixture.frame);
    try dvui.testing.expectFocused("resource-menu-test-modal-button");
    try dvui.testing.pressKey(.escape, .none);
    _ = try dvui.testing.step(Fixture.frame);
    try std.testing.expect(Fixture.foreign_escape);
    try std.testing.expectEqual(Mode.pinned, Fixture.state.mode);
    try std.testing.expectEqual(Fixture.foreign_id.?, dvui.focusedSubwindowId());
    try dvui.testing.pressKey(.tab, .none);
    _ = try dvui.testing.step(Fixture.frame);
    try std.testing.expect(Fixture.foreign_tab);
    try std.testing.expectEqual(Mode.pinned, Fixture.state.mode);
    Fixture.enabled = false;
    _ = try dvui.testing.step(Fixture.frame);
    try std.testing.expectEqual(Mode.closed, Fixture.state.mode);
    try std.testing.expectEqual(Fixture.foreign_id.?, dvui.focusedSubwindowId());
    try std.testing.expect(Fixture.chosen == null);
}

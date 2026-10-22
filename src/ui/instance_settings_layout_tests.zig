//! Real DVUI renderer regressions for installed-instance settings and deferred entry pages.
const std = @import("std");
const dvui = @import("dvui");
const config = @import("../core/config.zig");
const instances = @import("../core/instances.zig");
const tasks = @import("../core/tasks.zig");
const view = @import("instances_view.zig");
const manager_module = @import("instances_manager.zig");
const java = @import("java_manager.zig");
const theme = @import("theme.zig");

const saved: config.Instance = .{ .id = "settings-renderer-instance", .name = "Saved Fixture", .minecraft_version = "1.21.1", .min_memory_mb = 512, .max_memory_mb = 4096 };
const runtime: java.Runtime = .{ .path = "/fixture/registered-settings-jdk/bin/java", .major = 21, .architecture = @import("../core/java_runtime.zig").host(), .vendor = "Renderer Fixture" };

fn contains(outer: dvui.Rect.Physical, inner: dvui.Rect.Physical, tolerance: f32) bool {
    return inner.x >= outer.x - tolerance and inner.y >= outer.y - tolerance and inner.x + inner.w <= outer.x + outer.w + tolerance and inner.y + inner.h <= outer.y + outer.h + tolerance;
}

fn expectInside(outer: dvui.Rect.Physical, inner: dvui.Rect.Physical) !void {
    errdefer std.debug.print("settings containment: outer={any}, inner={any}\n", .{ outer, inner });
    try std.testing.expect(contains(outer, inner, 0.1));
}

fn expectRect(expected: dvui.Rect.Physical, actual: dvui.Rect.Physical) !void {
    try std.testing.expectApproxEqAbs(expected.x, actual.x, 0.1);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, 0.1);
    try std.testing.expectApproxEqAbs(expected.w, actual.w, 0.1);
    try std.testing.expectApproxEqAbs(expected.h, actual.h, 0.1);
}

const Frame = struct {
    const Geometry = struct { border: dvui.Rect.Physical, content: dvui.Rect.Physical };
    const Text = struct { value: []const u8, rect: dvui.Rect.Physical, clip: dvui.Rect.Physical, font: dvui.Font, color: dvui.Color };
    const Shape = struct { rect: dvui.Rect.Physical, clip: dvui.Rect.Physical };
    const Footer = struct { cancel: dvui.Rect.Physical, save: dvui.Rect.Physical, title: dvui.Rect.Physical };
    var store: *config.Store = undefined;
    var manager: *manager_module.Manager = undefined;
    var ui: *view.Ui = undefined;
    var java_registry: *java.Manager = undefined;
    var registry: *tasks.Registry = undefined;
    var enabled = true;
    var service_calls: usize = 0;
    var arena: ?std.heap.ArenaAllocator = null;
    var texts: []const Text = &.{};
    var shapes: []const Shape = &.{};

    fn clear() void {
        texts = &.{};
        shapes = &.{};
        if (arena) |*previous| previous.deinit();
        arena = null;
    }

    fn rejectLease(_: ?*anyopaque, _: []const u8) !void {
        service_calls += 1;
        return error.UnexpectedSettingsBackendActivation;
    }

    fn releaseLease(_: ?*anyopaque, _: []const u8) void {
        service_calls += 1;
    }

    fn rejectInstaller(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: manager_module.CreateRequest, _: manager_module.Control) !manager_module.Installed {
        service_calls += 1;
        return error.UnexpectedSettingsBackendActivation;
    }

    fn bounds(points: []const dvui.Point.Physical) ?dvui.Rect.Physical {
        if (points.len == 0) return null;
        var left = points[0].x;
        var top = points[0].y;
        var right = left;
        var bottom = top;
        for (points[1..]) |point| {
            left = @min(left, point.x);
            top = @min(top, point.y);
            right = @max(right, point.x);
            bottom = @max(bottom, point.y);
        }
        return .{ .x = left, .y = top, .w = right - left, .h = bottom - top };
    }

    fn retain(commands: []const dvui.RenderCommand) !void {
        clear();
        arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const a = arena.?.allocator();
        var retained_text: std.ArrayList(Text) = .empty;
        var retained_shapes: std.ArrayList(Shape) = .empty;
        for (commands) |command| {
            switch (command.cmd) {
                .text => |text_command| try retained_text.append(a, .{ .value = try a.dupe(u8, text_command.text), .rect = text_command.rs.r, .clip = command.clip, .font = text_command.font, .color = text_command.color }),
                else => {},
            }
            const rect = switch (command.cmd) {
                .pathStroke => |stroke| bounds(stroke.path.points),
                .pathFillConvex => |fill| bounds(fill.path.points),
                .triangles => |mesh| mesh.tri.bounds,
                else => null,
            } orelse continue;
            try retained_shapes.append(a, .{ .rect = rect, .clip = command.clip });
        }
        texts = retained_text.items;
        shapes = retained_shapes.items;
    }

    fn draw() !dvui.App.Result {
        const win = dvui.currentWindow();
        dvui.debug.captureScopeBegin(win.gpa);
        defer dvui.debug.captureScopeEnd();
        var commands: std.ArrayList(dvui.RenderCommand) = .empty;
        const previous_commands = win.defer_render_cmds;
        const previous_commands_after = win.defer_render_cmds_after;
        const previous_rendering = win.render_target.rendering;
        win.defer_render_cmds = &commands;
        win.defer_render_cmds_after = &commands;
        win.render_target.rendering = false;
        defer {
            win.defer_render_cmds = previous_commands;
            win.defer_render_cmds_after = previous_commands_after;
            win.render_target.rendering = previous_rendering;
            commands.deinit(win.arena());
        }
        {
            // Match the production two-pane geometry, including its eight-pixel handle.
            var split = @as(f32, 280) / @max(1, dvui.windowRect().w - 8);
            const panes = dvui.paned(@src(), .{ .direction = .horizontal, .collapsed_size = 0, .split_ratio = &split, .handle_size = 8 }, .{ .expand = .both, .padding = dvui.Rect.all(0), .margin = dvui.Rect.all(0) });
            defer panes.deinit();
            if (panes.showFirst()) {
                const side = view.sidebarPanel(@src());
                defer side.deinit();
                view.sidebarHeading(@src());
                _ = view.sidebarFooter(@src(), "返回主页");
                view.drawSidebar(ui, store, manager, enabled);
            }
            if (panes.showSecond()) {
                const compact = dvui.windowRect().w < 900 or dvui.windowRect().h < 540;
                const body = dvui.box(@src(), .{}, .{ .expand = .both, .padding = dvui.Rect.all(if (compact) 24 else 32), .tag = "settings-test-page" });
                defer body.deinit();
                const previous_clip = dvui.clip(body.data().contentRectScale().r);
                defer dvui.clipSet(previous_clip);
                view.drawWithEnabled(ui, store, manager, .{ .installed = &.{}, .available = &.{}, .phase = .idle, .failure = null }, java_registry.entries(), enabled);
            }
        }
        view.drawModal(ui, enabled);
        // Floating menus and modals reset deferred capture into their own subwindows.
        // Retain their actual normal and after commands before Window.end flushes them.
        for (win.subwindows.stack.items) |*subwindow| {
            try commands.appendSlice(win.arena(), subwindow.render_cmds.items);
            try commands.appendSlice(win.arena(), subwindow.render_cmds_after.items);
        }
        try retain(commands.items);
        view.finish(ui, store, manager);
        return .ok;
    }

    fn captured(key: []const u8) !Geometry {
        const target = try dvui.testing.tagGet(key);
        const capture = dvui.debug.lastCapture() orelse return error.SettingsWidgetCaptureMissing;
        for (capture.widgets.items) |widget| if (widget.id == target.id) return .{ .border = widget.rect_border, .content = widget.rect_content };
        return error.SettingsCapturedWidgetMissing;
    }

    fn scrollViewport() !dvui.Rect.Physical {
        const target = try dvui.testing.tagGet("instance-settings-body");
        const capture = dvui.debug.lastCapture() orelse return error.SettingsWidgetCaptureMissing;
        var viewport: ?dvui.Rect.Physical = null;
        var nearest_depth: usize = std.math.maxInt(usize);
        for (capture.widgets.items) |widget| {
            const name = widget.name orelse continue;
            if (!std.mem.eql(u8, name, "ScrollContainer")) continue;
            var ancestor = widget.parent_id;
            for (0..capture.widgets.items.len) |depth| {
                if (ancestor == target.id) {
                    // Ignore nested native text-entry scroll containers.
                    if (depth < nearest_depth) {
                        nearest_depth = depth;
                        viewport = widget.rect_content;
                    }
                    break;
                }
                var next: ?dvui.Id = null;
                for (capture.widgets.items) |parent| {
                    if (parent.id != ancestor) continue;
                    if (parent.parent_id != ancestor) next = parent.parent_id;
                    break;
                }
                ancestor = next orelse break;
            }
        }
        return viewport orelse error.SettingsScrollViewportMissing;
    }

    fn absent(key: []const u8) !void {
        if (dvui.testing.tagGet(key)) |_| return error.UnexpectedSettingsWidget else |_| {}
    }

    fn nativeControl(key: []const u8, active: bool) !dvui.TagData {
        const target = try dvui.testing.tagGet(key);
        try std.testing.expect(target.visible);
        var matches: usize = 0;
        for (dvui.currentWindow().tab_index_prev.items) |entry| if (entry.widgetId == target.id) {
            matches += 1;
            try expectInside(entry.rect orelse return error.SettingsControlRectangleMissing, (try captured(key)).border);
        };
        try std.testing.expectEqual(@as(usize, if (active) 1 else 0), matches);
        return target;
    }

    fn text(key: []const u8, expected: []const u8, size: f32, expected_color: ?dvui.Color) !Text {
        const target = try dvui.testing.tagGet(key);
        for (texts) |sample| {
            if (!std.mem.eql(u8, sample.value, expected) or !contains(target.rect, sample.rect, 0.1)) continue;
            try expectInside(sample.clip, sample.rect);
            try std.testing.expectApproxEqAbs(size, sample.font.size, 0.01);
            if (expected_color) |color| try std.testing.expectEqualDeep(color, sample.color);
            return sample;
        }
        std.debug.print("settings rendered text missing: tag={s}, text={s}\n", .{ key, expected });
        return error.SettingsTextNotRendered;
    }

    fn painted(key: []const u8) !void {
        const target = (try dvui.testing.tagGet(key)).rect;
        for (shapes) |shape| {
            if (!contains(target, shape.rect, 1.1) or !contains(shape.clip, shape.rect, 1.1)) continue;
            if (shape.rect.w > 0 and shape.rect.h > 0) return;
        }
        return error.SettingsNativeGraphicMissing;
    }

    fn footers(active: bool) !Footer {
        const page = (try captured("settings-test-page")).content;
        const body = (try captured("instance-settings-body")).border;
        const footer = (try captured("instance-settings-footer")).border;
        const title = (try captured("instance-settings-title")).border;
        const cancel = (try captured("instance-settings-cancel")).border;
        const save = (try captured("instance-settings-save")).border;
        _ = try nativeControl("instance-settings-cancel", active);
        _ = try nativeControl("instance-settings-save", active);
        _ = try text("instance-settings-cancel", "取消", 16, null);
        _ = try text("instance-settings-save", "保存", 16, null);
        for ([_]dvui.Rect.Physical{ cancel, save }) |button| {
            try std.testing.expectApproxEqAbs(@as(f32, 144), button.w, 0.1);
            try std.testing.expectApproxEqAbs(@as(f32, 48), button.h, 0.1);
            try expectInside(page, button);
            try expectInside(footer, button);
        }
        try std.testing.expectApproxEqAbs(page.x, cancel.x, 0.1);
        try std.testing.expectApproxEqAbs(page.x + page.w, save.x + save.w, 0.1);
        try std.testing.expect(cancel.x + cancel.w <= save.x);
        try std.testing.expectApproxEqAbs(cancel.y, save.y, 0.1);
        try std.testing.expect(body.y + body.h <= footer.y + 0.1);
        try std.testing.expect(title.y + title.h <= body.y + 0.1);
        return .{ .cancel = cancel, .save = save, .title = title };
    }

    fn fixed(expected: Footer) !void {
        const current = try footers(enabled);
        try expectRect(expected.cancel, current.cancel);
        try expectRect(expected.save, current.save);
        try expectRect(expected.title, current.title);
    }

    fn wheel(amount: f32) !void {
        try dvui.testing.moveTo("instance-settings-body");
        _ = try dvui.currentWindow().addEventMouseWheel(amount, .vertical, null);
        try dvui.testing.settle(draw);
    }

    fn reveal(key: []const u8) !void {
        for (0..32) |_| {
            const viewport = (try captured("instance-settings-body")).content;
            const target = (try captured(key)).border;
            if (contains(viewport, target, 0.1)) return;
            try wheel(if (target.y < viewport.y) 48 else -48);
        }
        return error.SettingsControlNotReachableByScroll;
    }

    fn click(key: []const u8) !void {
        const target = try dvui.testing.tagGet(key);
        try std.testing.expect(target.visible);
        _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = target.rect.center() });
        try dvui.testing.click(.left);
        try dvui.testing.settle(draw);
    }

    fn replace(key: []const u8, value: []const u8) !void {
        try reveal(key);
        try click(key);
        try std.testing.expectEqual((try dvui.testing.tagGet(key)).id, dvui.focusedWidgetId().?);
        try dvui.testing.pressKey(.a, .lcontrol);
        try dvui.testing.pressKey(.backspace, .none);
        try dvui.testing.writeText(value);
        try dvui.testing.settle(draw);
        try std.testing.expectEqual((try dvui.testing.tagGet(key)).id, dvui.focusedWidgetId().?);
    }

    fn clickRendered(value: []const u8) !void {
        for (texts) |sample| {
            if (!std.mem.eql(u8, sample.value, value) or !contains(sample.clip, sample.rect, 0.1)) continue;
            _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = sample.rect.center() });
            try dvui.testing.click(.left);
            try dvui.testing.settle(draw);
            return;
        }
        return error.SettingsJavaChoiceNotRendered;
    }

    fn savedUnchanged() !void {
        const document = store.snapshot();
        try std.testing.expectEqual(@as(usize, 1), document.instances.len);
        try std.testing.expectEqualStrings(saved.id, document.selected_instance.?);
        try std.testing.expectEqualDeep(saved, document.instances[0]);
        try std.testing.expectEqual(@as(usize, 0), service_calls);
        try std.testing.expect(!manager.isBusy());
    }
};

fn atBothSizes(comptime scenario: fn () anyerror!void) !void {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    const a = std.testing.allocator;
    for ([_]dvui.Size{ .{ .w = 640, .h = 400 }, .{ .w = 1280, .h = 720 } }) |size| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        defer a.free(root);
        var store = try config.Store.init(a, std.testing.io, root);
        defer store.deinit();
        try store.update(.{ .instances = &.{saved}, .selected_instance = saved.id, .settings = .{ .default_memory_mb = 2048 } });
        const fixture = try std.json.Stringify.valueAlloc(a, .{ .version = @as(u32, 1), .runtimes = &[_]java.Runtime{runtime} }, .{});
        defer a.free(fixture);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".vela/java.json", .data = fixture });
        var java_registry = try java.Manager.init(a, std.testing.io, root);
        defer java_registry.deinit();
        try std.testing.expectEqual(@as(usize, 1), java_registry.entries().len);
        var paths = try instances.Paths.init(a, std.testing.io, root);
        defer paths.deinit();
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var manager = try manager_module.Manager.init(a, std.testing.io, &paths, &registry, .{}, .{ .context = null, .acquire = Frame.rejectLease, .recheck = Frame.rejectLease, .release = Frame.releaseLease });
        defer manager.deinit();
        manager.setInstaller(.{ .run = Frame.rejectInstaller });
        var ui = view.Ui.init(a);
        defer ui.deinit();
        ui.queue(.edit, saved.id);
        view.finish(&ui, &store, &manager);
        try std.testing.expectEqual(view.Mode.options, ui.mode);
        Frame.store = &store;
        Frame.manager = &manager;
        Frame.ui = &ui;
        Frame.java_registry = &java_registry;
        Frame.registry = &registry;
        Frame.enabled = true;
        Frame.service_calls = 0;
        defer Frame.clear();
        var window = try dvui.testing.init(.{ .window_size = size });
        defer window.deinit();
        window.backend.size_pixels = .{ .w = size.w, .h = size.h };
        // Match the existing renderer fixtures: each fresh window owns its built-in font.
        var settings_theme = dvui.Theme.builtin.adwaita_dark;
        settings_theme.font_body = settings_theme.font_body.withSize(16);
        settings_theme.font_heading = settings_theme.font_body.withSize(18);
        settings_theme.font_title = settings_theme.font_body.withSize(24);
        window.window.themeSet(settings_theme);
        try dvui.testing.settle(Frame.draw);
        try scenario();
        try Frame.savedUnchanged();
    }
}

fn field(label_key: []const u8, control_key: []const u8, control_width: f32) !Frame.Geometry {
    const label = try Frame.captured(label_key);
    const control = try Frame.captured(control_key);
    const label_gap = if (dvui.windowRect().h < 480) theme.spacing.compact_label_gap else theme.spacing.field_label_gap;
    try std.testing.expectApproxEqAbs(label.border.y + label.border.h + label_gap, control.border.y, 0.1);
    try std.testing.expectApproxEqAbs(label.border.x, control.border.x, 0.1);
    try std.testing.expectApproxEqAbs(control_width, control.border.w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 48), control.border.h, 0.1);
    return control;
}

fn settingsGeometry() !void {
    const page = (try Frame.captured("settings-test-page")).content;
    const body = (try Frame.captured("instance-settings-body")).content;
    const viewport = try Frame.scrollViewport();
    try expectInside(body, viewport);
    const footer = try Frame.footers(true);
    const title = try Frame.text("instance-settings-title", saved.name, 24, dvui.themeGet().text);
    try std.testing.expectEqualDeep(theme.titleFont(), title.font);
    try std.testing.expectApproxEqAbs(page.w, body.w, 0.1);
    if (dvui.windowRect().w == 1280) try std.testing.expect(page.w > 800);
    const labels = [_][]const u8{ "名称", "Java", "最小内存（MiB）", "最大内存（MiB）" };
    const label_tags = [_][]const u8{ "instance-settings-name-label", "instance-settings-java-label", "instance-settings-min-memory-label", "instance-settings-max-memory-label" };
    const controls = [_][]const u8{ "instance-settings-name", "instance-settings-java-control", "instance-settings-min-memory", "instance-settings-max-memory" };
    const side_by_side = viewport.w >= 700;
    const memory = (try Frame.captured("instance-resources")).border;
    const identity = (try Frame.captured("instance-identity")).border;
    const manage = (try Frame.captured("instance-manage-mods")).border;
    try std.testing.expectApproxEqAbs(identity.x, manage.x, 0.1);
    try std.testing.expectApproxEqAbs(identity.x + identity.w, manage.x + manage.w, 0.1);
    try std.testing.expectApproxEqAbs(identity.y + identity.h + theme.spacing.group_gap, manage.y, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 48), manage.h, 0.1);
    try std.testing.expectApproxEqAbs(manage.y + manage.h + theme.spacing.group_gap, memory.y, 0.1);
    const debug_panel = (try Frame.captured("instance-debug")).border;
    if (side_by_side) {
        try std.testing.expectApproxEqAbs(memory.y, debug_panel.y, 0.1);
        try std.testing.expectApproxEqAbs(memory.h, debug_panel.h, 0.1);
        try std.testing.expectApproxEqAbs(memory.x + memory.w + theme.spacing.card_gap, debug_panel.x, 0.1);
        try std.testing.expectApproxEqAbs(viewport.x + viewport.w, debug_panel.x + debug_panel.w, 0.1);
    } else try std.testing.expect(debug_panel.y >= memory.y + memory.h + theme.spacing.group_gap - 0.1);
    var previous_bottom: ?f32 = null;
    for (label_tags, controls, 0..) |label_tag, control_tag, index| {
        const width = if (side_by_side and index >= 2) (memory.w - 2 * theme.spacing.panel_padding) / 2 - theme.spacing.row_gap else viewport.w - 2 * theme.spacing.panel_padding;
        const geometry = try field(label_tag, control_tag, width);
        if (previous_bottom) |bottom| {
            if (side_by_side and index == 3) {
                const minimum = (try Frame.captured(controls[2])).border;
                try std.testing.expectApproxEqAbs(minimum.y, geometry.border.y, 0.1);
                try std.testing.expectApproxEqAbs(minimum.x + minimum.w + theme.spacing.card_gap, geometry.border.x, 0.1);
            } else try std.testing.expect((try Frame.captured(label_tag)).border.y >= bottom + theme.spacing.field_label_gap - 0.1);
        }
        previous_bottom = geometry.border.y + geometry.border.h;
    }
    const debug = (try Frame.captured("instance-settings-debug")).border;
    const delete = (try Frame.captured("instance-settings-delete")).border;
    try expectInside(debug_panel, debug);
    try std.testing.expectApproxEqAbs(debug_panel.center().y, debug.center().y, 0.1);
    try std.testing.expect(delete.y >= @max(memory.y + memory.h, debug_panel.y + debug_panel.h) + theme.spacing.group_gap - 0.1);
    try std.testing.expectApproxEqAbs(viewport.x, delete.x, 0.1);
    try std.testing.expectApproxEqAbs(viewport.w, delete.w, 0.1);
    for ([_]dvui.Rect.Physical{ debug, delete }) |control| try std.testing.expectApproxEqAbs(@as(f32, 48), control.h, 0.1);
    for (label_tags, labels, controls) |label_tag, label, control| {
        try Frame.reveal(control);
        _ = try Frame.nativeControl(control, true);
        _ = try Frame.text(label_tag, label, 16, null);
        try Frame.fixed(footer);
    }
    try Frame.reveal("instance-settings-debug");
    _ = try Frame.nativeControl("instance-settings-debug", true);
    const rendered_label = try Frame.text("instance-settings-debug-label", "调试启动", 16, null);
    const track = (try dvui.testing.tagGet("instance-settings-debug-switch")).rect;
    const knob = (try dvui.testing.tagGet("instance-settings-debug-knob")).rect;
    const label = (try Frame.captured("instance-settings-debug-label")).border;
    const live_debug = (try Frame.captured("instance-settings-debug")).border;
    try std.testing.expectApproxEqAbs(@as(f32, 42), track.w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 24), track.h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 18), knob.w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 18), knob.h, 0.1);
    try std.testing.expectApproxEqAbs(live_debug.x + live_debug.w, track.x + track.w, 0.1);
    try std.testing.expectApproxEqAbs(live_debug.center().y, track.center().y, 0.1);
    try std.testing.expectApproxEqAbs(track.center().y, rendered_label.rect.center().y, 0.1);
    try std.testing.expect(label.x + label.w < track.x);
    try expectInside(track, knob);
    try Frame.painted("instance-settings-debug-switch");
    try Frame.painted("instance-settings-debug-knob");
    try Frame.wheel(-100000);
    _ = try Frame.nativeControl("instance-settings-delete", true);
    _ = try Frame.text("instance-settings-delete", "删除", 16, null);
    try expectInside((try Frame.captured("instance-settings-body")).content, (try Frame.captured("instance-settings-delete")).border);
    try Frame.fixed(footer);
    try Frame.wheel(100000);
    try expectInside((try Frame.captured("instance-settings-body")).content, (try Frame.captured("instance-settings-name")).border);
    _ = try Frame.text("instance-settings-name-label", "名称", 16, null);
    _ = try Frame.text("instance-settings-java-control", "自动选择", 16, null);
    try Frame.fixed(footer);
    const forbidden = [_][]const u8{ "启动选项", "重命名", "Minecraft 1.21.1" };
    for (Frame.texts) |sample| for (forbidden) |value| if (std.mem.eql(u8, sample.value, value)) return error.LegacySettingsSectionRendered;
}

fn editAndCancel() !void {
    const footer = try Frame.footers(true);
    try Frame.replace("instance-settings-name", "Edited Fixture");
    try Frame.replace("instance-settings-min-memory", "1x024");
    try Frame.replace("instance-settings-max-memory", "6x144");
    try std.testing.expectEqualStrings("Edited Fixture", std.mem.sliceTo(&Frame.ui.draft.name, 0));
    try std.testing.expectEqualStrings("1024", std.mem.sliceTo(&Frame.ui.draft.min_memory, 0));
    try std.testing.expectEqualStrings("6144", std.mem.sliceTo(&Frame.ui.draft.memory, 0));
    try Frame.reveal("instance-settings-debug");
    try Frame.click("instance-settings-debug");
    try std.testing.expect(Frame.ui.draft.debug_launch);
    try Frame.click("instance-settings-debug");
    try std.testing.expect(!Frame.ui.draft.debug_launch);
    try Frame.click("instance-settings-debug");
    try Frame.fixed(footer);
    _ = try Frame.text("instance-settings-title", saved.name, 24, null);
    try Frame.savedUnchanged();
    try Frame.click("instance-settings-cancel");
    Frame.ui.queue(.edit, saved.id);
    view.finish(Frame.ui, Frame.store, Frame.manager);
    try dvui.testing.settle(Frame.draw);
    try std.testing.expectEqualStrings(saved.name, std.mem.sliceTo(&Frame.ui.draft.name, 0));
    try std.testing.expectEqualStrings("512", std.mem.sliceTo(&Frame.ui.draft.min_memory, 0));
    try std.testing.expectEqualStrings("4096", std.mem.sliceTo(&Frame.ui.draft.memory, 0));
    try std.testing.expectEqualStrings("", std.mem.sliceTo(&Frame.ui.draft.java_path, 0));
    try std.testing.expect(!Frame.ui.draft.debug_launch);
    try std.testing.expect(Frame.ui.pending == null);
    try std.testing.expectEqual(@as(usize, 0), Frame.registry.tasks().len);
}

fn registeredJavaOwnership() !void {
    try Frame.reveal("instance-settings-java-control");
    try Frame.click("instance-settings-java-control");
    try Frame.clickRendered("Java 21 · Renderer Fixture");
    try std.testing.expectEqualStrings(runtime.path, std.mem.sliceTo(&Frame.ui.draft.java_path, 0));
    const borrowed = Frame.java_registry.entries()[0].path;
    const owned = std.mem.sliceTo(&Frame.ui.draft.java_path, 0);
    try std.testing.expect(@intFromPtr(borrowed.ptr) != @intFromPtr(owned.ptr));
    try Frame.java_registry.hide(runtime.path);
    try std.testing.expectEqual(@as(usize, 0), Frame.java_registry.entries().len);
    try dvui.testing.settle(Frame.draw);
    try std.testing.expectEqualStrings(runtime.path, std.mem.sliceTo(&Frame.ui.draft.java_path, 0));
    try Frame.reveal("instance-settings-java-control");
    try Frame.click("instance-settings-java-control");
    try Frame.clickRendered("自动选择");
    try std.testing.expectEqualStrings("", std.mem.sliceTo(&Frame.ui.draft.java_path, 0));
    try Frame.savedUnchanged();
}

const DeleteBackground = struct {
    const controls = [_][]const u8{ "instance-settings-name", "instance-settings-java-control", "instance-settings-min-memory", "instance-settings-max-memory", "instance-settings-debug", "instance-settings-delete" };
    page: Frame.Geometry,
    body: Frame.Geometry,
    viewport: dvui.Rect.Physical,
    footer: Frame.Footer,
    fields: [controls.len]Frame.Geometry,

    fn capture() !DeleteBackground {
        var result: DeleteBackground = .{
            .page = try Frame.captured("settings-test-page"),
            .body = try Frame.captured("instance-settings-body"),
            .viewport = try Frame.scrollViewport(),
            .footer = try Frame.footers(true),
            .fields = undefined,
        };
        for (controls, 0..) |key, index| result.fields[index] = try Frame.captured(key);
        return result;
    }

    fn unchanged(self: DeleteBackground, active: bool) !void {
        const page = try Frame.captured("settings-test-page");
        const body = try Frame.captured("instance-settings-body");
        try expectRect(self.page.border, page.border);
        try expectRect(self.page.content, page.content);
        try expectRect(self.body.border, body.border);
        try expectRect(self.body.content, body.content);
        try expectRect(self.viewport, try Frame.scrollViewport());
        const footer = try Frame.footers(active);
        try expectRect(self.footer.cancel, footer.cancel);
        try expectRect(self.footer.save, footer.save);
        try expectRect(self.footer.title, footer.title);
        for (controls, self.fields) |key, expected| {
            const current = try Frame.captured(key);
            // Absolute field positions also prove the scroll offset survived the popup.
            try expectRect(expected.border, current.border);
            try expectRect(expected.content, current.content);
            const target = try dvui.testing.tagGet(key);
            if (target.visible) _ = try Frame.nativeControl(key, active);
            if (!active) for (dvui.currentWindow().tab_index_prev.items) |entry| {
                try std.testing.expect(entry.widgetId != target.id);
            };
        }
    }
};

fn deleteParagraph(key: []const u8, expected_parts: []const []const u8, modal: dvui.Rect.Physical) !void {
    const paragraph = (try Frame.captured(key)).border;
    try expectInside(modal, paragraph);
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(std.testing.allocator);
    for (Frame.texts) |sample| {
        if (!contains(paragraph, sample.rect, 0.1)) continue;
        try expectInside(modal, sample.rect);
        try expectInside(sample.clip, sample.rect);
        try std.testing.expectApproxEqAbs(@as(f32, 16), sample.font.size, 0.01);
        try rendered.appendSlice(std.testing.allocator, sample.value);
    }
    for (expected_parts) |part| {
        errdefer std.debug.print("delete paragraph: tag={s}, missing={s}, rendered={s}, rect={any}\n", .{ key, part, rendered.items, paragraph });
        try std.testing.expect(std.mem.indexOf(u8, rendered.items, part) != null);
    }
}

fn deleteModalGeometry() !void {
    const modal = (try Frame.captured("instance-delete-confirm-modal")).border;
    const window: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = dvui.windowRect().w, .h = dvui.windowRect().h };
    try expectInside(.{ .x = 12, .y = 12, .w = window.w - 24, .h = window.h - 24 }, modal);
    const margin: f32 = if (window.h < 480) 16 else theme.spacing.page_margin;
    try std.testing.expectApproxEqAbs(@min(@as(f32, 620), window.w - 2 * margin), modal.w, 0.1);
    try std.testing.expectApproxEqAbs(@min(@as(f32, 400), window.h - 2 * margin), modal.h, 0.1);
    try std.testing.expectApproxEqAbs(window.w / 2, modal.center().x, 0.1);
    try std.testing.expectApproxEqAbs(window.h / 2, modal.center().y, 0.1);
    const heading = try Frame.text("instance-delete-confirm-title", "永久删除实例", 18, theme.accent);
    try std.testing.expectEqualDeep(theme.headingFont(), heading.font);
    try expectInside(modal, heading.rect);
    try deleteParagraph("instance-delete-confirm-warning", &.{ "实例「", saved.name, "目录内的存档", "Mod", "配置将永久删除", "无法恢复" }, modal);
    try deleteParagraph("instance-delete-confirm-servers", &.{ "绑定服务器将保留", "仅解除与此实例的绑定", "共享 Minecraft 资源", "其他实例", "外部服务器文件不受影响" }, modal);
    const cancel = (try Frame.nativeControl("instance-delete-confirm-cancel", true)).rect;
    const submit = (try Frame.nativeControl("instance-delete-confirm-submit", true)).rect;
    _ = try Frame.text("instance-delete-confirm-cancel", "取消删除", 16, null);
    _ = try Frame.text("instance-delete-confirm-submit", "永久删除", 16, null);
    for ([_]dvui.Rect.Physical{ cancel, submit }) |button| {
        try expectInside(modal, button);
        try std.testing.expectApproxEqAbs(@as(f32, 144), button.w, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 48), button.h, 0.1);
    }
    try std.testing.expect(cancel.x + cancel.w <= submit.x);
    try std.testing.expectApproxEqAbs(cancel.y, submit.y, 0.1);
}

fn deleteDraftUnchanged(draft: view.Draft, navigation_serial: u64) !void {
    try std.testing.expectEqualDeep(draft, Frame.ui.draft);
    try std.testing.expect(Frame.ui.draft.dirty());
    try std.testing.expect(Frame.ui.pending == null);
    try std.testing.expect(Frame.ui.navigation == null);
    try std.testing.expect(!Frame.ui.navigation_prompt);
    try std.testing.expectEqual(navigation_serial, Frame.ui.navigation_serial);
    try std.testing.expect(!Frame.ui.submitted);
    try Frame.savedUnchanged();
    try std.testing.expectEqual(@as(usize, 0), Frame.registry.tasks().len);
}

fn deleteConfirmation() !void {
    try Frame.replace("instance-settings-name", "Delete Draft");
    try Frame.replace("instance-settings-min-memory", "1024");
    try Frame.replace("instance-settings-max-memory", "6144");
    try Frame.reveal("instance-settings-java-control");
    try Frame.click("instance-settings-java-control");
    try Frame.clickRendered("Java 21 · Renderer Fixture");
    try Frame.reveal("instance-settings-debug");
    try Frame.click("instance-settings-debug");
    try std.testing.expect(Frame.ui.draft.debug_launch);
    try std.testing.expectEqualStrings(runtime.path, std.mem.sliceTo(&Frame.ui.draft.java_path, 0));
    // Reproduce an offscreen focused TextEntry before the real Delete trigger.
    try Frame.reveal("instance-settings-name");
    try Frame.click("instance-settings-name");
    const name_focus = (try dvui.testing.tagGet("instance-settings-name")).id;
    try std.testing.expectEqual(name_focus, dvui.focusedWidgetId().?);
    try Frame.wheel(-100000);
    const background = try DeleteBackground.capture();
    const draft = Frame.ui.draft;
    const navigation_serial = Frame.ui.navigation_serial;
    try std.testing.expectEqual(@backingInt(name_focus), Frame.ui.form_focus.?);
    const delete_trigger = (try dvui.testing.tagGet("instance-settings-delete")).id;
    const form_focus: u64 = @backingInt(delete_trigger);
    const form_subwindow: u64 = @backingInt(dvui.focusedSubwindowId());
    if (dvui.windowRect().w == 640) {
        try std.testing.expect(!contains(background.viewport, (try Frame.captured("instance-settings-name")).border, 0.1));
    }
    try Frame.click("instance-settings-delete");
    try std.testing.expectEqual(view.Mode.delete_confirm, Frame.ui.mode);
    try background.unchanged(false);
    try deleteModalGeometry();
    try deleteDraftUnchanged(draft, navigation_serial);
    try std.testing.expectEqual((try dvui.testing.tagGet("instance-delete-confirm-cancel")).id, dvui.focusedWidgetId().?);

    // Send real pointer/text/wheel events while the native modal owns input.
    for ([_][]const u8{ "instance-settings-name", "instance-settings-java-control", "instance-settings-debug", "instance-settings-delete", "instance-settings-save", "instance-settings-cancel" }) |key| {
        const target = try dvui.testing.tagGet(key);
        if (!target.visible) continue;
        _ = try Frame.nativeControl(key, false);
        // Pick an exposed corner of the background control; points on the
        // modal actions would correctly trigger the modal rather than the background.
        const cancel_rect = (try dvui.testing.tagGet("instance-delete-confirm-cancel")).rect;
        const submit_rect = (try dvui.testing.tagGet("instance-delete-confirm-submit")).rect;
        var safe_point: ?dvui.Point.Physical = null;
        for ([_]dvui.Point.Physical{
            .{ .x = target.rect.x + 2, .y = target.rect.y + 2 },
            .{ .x = target.rect.x + target.rect.w - 2, .y = target.rect.y + 2 },
            .{ .x = target.rect.x + 2, .y = target.rect.y + target.rect.h - 2 },
            .{ .x = target.rect.x + target.rect.w - 2, .y = target.rect.y + target.rect.h - 2 },
        }) |candidate| {
            const point_rect: dvui.Rect.Physical = .{ .x = candidate.x, .y = candidate.y, .w = 0, .h = 0 };
            if (!contains(cancel_rect, point_rect, 0) and !contains(submit_rect, point_rect, 0)) {
                safe_point = candidate;
                break;
            }
        }
        const point = safe_point orelse continue;
        _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = point });
        try dvui.testing.click(.left);
        try dvui.testing.settle(Frame.draw);
        if (std.mem.eql(u8, key, "instance-settings-name")) {
            try dvui.testing.writeText("Blocked background edit");
            try dvui.testing.settle(Frame.draw);
        }
        try std.testing.expectEqual(view.Mode.delete_confirm, Frame.ui.mode);
        try deleteDraftUnchanged(draft, navigation_serial);
        try background.unchanged(false);
    }
    try Frame.wheel(-48);
    try background.unchanged(false);
    try deleteDraftUnchanged(draft, navigation_serial);

    try Frame.click("instance-delete-confirm-cancel");
    try std.testing.expectEqual(view.Mode.options, Frame.ui.mode);
    try Frame.absent("instance-delete-confirm-modal");
    try background.unchanged(true);
    try deleteDraftUnchanged(draft, navigation_serial);
    try std.testing.expectEqual(form_focus, Frame.ui.form_focus.?);
    try std.testing.expectEqual(form_subwindow, Frame.ui.form_subwindow.?);
    try std.testing.expectEqual(delete_trigger, dvui.focusedWidgetId().?);
    try std.testing.expectEqual(form_subwindow, @backingInt(dvui.focusedSubwindowId()));

    // Repeat the offscreen Name focus setup so Escape exercises the same case.
    try Frame.reveal("instance-settings-name");
    try Frame.click("instance-settings-name");
    try std.testing.expectEqual(name_focus, dvui.focusedWidgetId().?);
    try Frame.wheel(-100000);
    try std.testing.expectEqual(@backingInt(name_focus), Frame.ui.form_focus.?);
    try background.unchanged(true);
    try deleteDraftUnchanged(draft, navigation_serial);
    try Frame.click("instance-settings-delete");
    try std.testing.expectEqual(view.Mode.delete_confirm, Frame.ui.mode);
    try background.unchanged(false);
    try deleteModalGeometry();
    try dvui.testing.pressKey(.escape, .none);
    try dvui.testing.settle(Frame.draw);
    try std.testing.expectEqual(view.Mode.options, Frame.ui.mode);
    try Frame.absent("instance-delete-confirm-modal");
    try background.unchanged(true);
    try deleteDraftUnchanged(draft, navigation_serial);
    try std.testing.expectEqual(form_focus, Frame.ui.form_focus.?);
    try std.testing.expectEqual(form_subwindow, Frame.ui.form_subwindow.?);
    try std.testing.expectEqual(delete_trigger, dvui.focusedWidgetId().?);
    try std.testing.expectEqual(form_subwindow, @backingInt(dvui.focusedSubwindowId()));
}

fn renderedMemoryError() !void {
    const page = (try Frame.captured("settings-test-page")).content;
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(std.testing.allocator);
    errdefer {
        std.debug.print("settings memory error capture: joined={s}, failure_scroll_pending={any}\n", .{ message.items, Frame.ui.settings_failure_scroll_pending });
        for (Frame.texts) |sample| {
            const relevant = std.mem.indexOf(u8, sample.value, "操作失败") != null or std.mem.indexOf(u8, sample.value, "内存") != null or
                (sample.color.r > sample.color.g and sample.color.r > sample.color.b);
            if (!relevant) continue;
            std.debug.print("settings error sample: value={s}, rect={any}, clip={any}, color={any}, page_visible={any}, clip_visible={any}\n", .{ sample.value, sample.rect, sample.clip, sample.color, contains(page, sample.rect, 1.1), contains(sample.clip, sample.rect, 1.1) });
        }
    }
    for (Frame.texts) |sample| {
        if (!contains(page, sample.rect, 1.1) or !contains(sample.clip, sample.rect, 1.1)) continue;
        try message.appendSlice(std.testing.allocator, sample.value);
        if (std.mem.indexOf(u8, sample.value, "内存") != null) try std.testing.expectApproxEqAbs(@as(f32, 16), sample.font.size, 0.01);
    }
    try std.testing.expect(std.mem.indexOf(u8, message.items, "内存必须为 256–1048576 MiB") != null);
    try std.testing.expect(std.mem.indexOf(u8, message.items, "最小内存不能大于最大内存") != null);
}

fn invalidMemoryRetainsDraft() !void {
    try Frame.replace("instance-settings-min-memory", "6144");
    try Frame.replace("instance-settings-max-memory", "");
    try Frame.click("instance-settings-save");
    try std.testing.expectEqual(error.InvalidMemory, Frame.ui.failure.?);
    try renderedMemoryError();
    try std.testing.expectEqualStrings("6144", std.mem.sliceTo(&Frame.ui.draft.min_memory, 0));
    try std.testing.expectEqualStrings("", std.mem.sliceTo(&Frame.ui.draft.memory, 0));
    try std.testing.expectEqual(@as(u32, 2048), Frame.store.snapshot().settings.default_memory_mb);
    try Frame.savedUnchanged();
    try Frame.replace("instance-settings-min-memory", "512");
    try Frame.replace("instance-settings-max-memory", "256");
    try Frame.click("instance-settings-save");
    try std.testing.expectEqual(error.InvalidMemory, Frame.ui.failure.?);
    try renderedMemoryError();
    try std.testing.expectEqualStrings("512", std.mem.sliceTo(&Frame.ui.draft.min_memory, 0));
    try std.testing.expectEqualStrings("256", std.mem.sliceTo(&Frame.ui.draft.memory, 0));
    _ = try Frame.footers(true);
    try std.testing.expectEqual(@as(usize, 0), Frame.registry.tasks().len);
}

fn lockedSettings() !void {
    Frame.enabled = false;
    try dvui.testing.settle(Frame.draw);
    _ = try Frame.footers(false);
    for ([_][]const u8{ "instance-settings-name", "instance-settings-java-control", "instance-settings-min-memory", "instance-settings-max-memory", "instance-settings-debug", "instance-settings-delete" }) |key| {
        try Frame.reveal(key);
        _ = try Frame.nativeControl(key, false);
    }
    const save = try dvui.testing.tagGet("instance-settings-save");
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = save.rect.center() });
    try dvui.testing.click(.left);
    try dvui.testing.settle(Frame.draw);
    try std.testing.expect(Frame.ui.pending == null);
    try Frame.savedUnchanged();
    Frame.enabled = true;
    try dvui.testing.settle(Frame.draw);
    _ = try Frame.footers(true);
}

test "UI layout installed settings fill compact and wide pages with native controls and fixed footer" {
    try atBothSizes(settingsGeometry);
}

test "UI layout installed settings real edits and debug toggle cancel back to saved values" {
    try atBothSizes(editAndCancel);
}

test "UI layout installed settings registered Java chooser owns selected paths and returns to automatic" {
    try atBothSizes(registeredJavaOwnership);
}

test "UI layout installed settings delete requires confirmation and cancel retains the draft" {
    try atBothSizes(deleteConfirmation);
}

test "UI layout installed settings invalid minimum retains draft against effective global or explicit maximum" {
    try atBothSizes(invalidMemoryRetainsDraft);
}

test "UI layout installed settings locked controls do not submit from real pointer input" {
    try atBothSizes(lockedSettings);
}

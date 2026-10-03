const std = @import("std");
const dvui = @import("dvui");
const tasks = @import("core/tasks.zig");
const task_view = @import("ui/tasks_view.zig");
const settings_view = @import("ui/settings_view.zig");
const view = @import("ui/view.zig");
const model = @import("ui/model.zig");
const config = @import("core/config.zig");
const java = @import("ui/java_manager.zig");
const servers_view = @import("ui/servers_view.zig");
const instances_view = @import("ui/instances_view.zig");
const java_view = @import("ui/java_view.zig");
const instances_manager = @import("ui/instances_manager.zig");
const server_manager = @import("ui/server_manager.zig");
const instances = @import("core/instances.zig");
const servers = @import("core/servers.zig");

test {
    _ = @import("ui/curseforge_key_editor.zig");
    _ = settings_view;
}

const Frame = struct {
    var registry: *tasks.Registry = undefined;
    var settings: *settings_view.Ui = undefined;
    var rows: u8 = 1;
    var show_settings = false;

    fn draw() !dvui.App.Result {
        const root = dvui.box(@src(), .{}, .{ .expand = .both, .padding = dvui.Rect.all(16) });
        defer root.deinit();
        if (show_settings) {
            try settings_view.draw(settings);
        } else {
            try task_view.drawWithOptions(registry, .{ .max_visible_rows = rows });
        }
        return .ok;
    }
};

fn expectInside(outer: dvui.Rect.Physical, inner: dvui.Rect.Physical) !void {
    errdefer std.debug.print("Layout containment failed: outer={any}, inner={any}\n", .{ outer, inner });
    try std.testing.expect(inner.x >= outer.x - 0.1);
    try std.testing.expect(inner.y >= outer.y - 0.1);
    try std.testing.expect(inner.x + inner.w <= outer.x + outer.w + 0.1);
    try std.testing.expect(inner.y + inner.h <= outer.y + outer.h + 0.1);
}

const HomeFrame = struct {
    var state: model.Model = .{};
    var manager: *java.Manager = undefined;
    var services: view.Services = undefined;
    var pending: ?model.Msg = null;

    fn draw() !dvui.App.Result {
        const root = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .padding = dvui.Rect.all(0), .margin = dvui.Rect.all(0) });
        defer root.deinit();
        // Match the real sidebar's 260px width plus its 16px left margin.
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 276 } });
        const pane = dvui.box(@src(), .{}, .{ .expand = .both, .padding = dvui.Rect.all(if (dvui.windowRect().h < 520) 12 else 32) });
        defer pane.deinit();
        try view.drawHome(&state, .{ .installed = &.{}, .available = &.{}, .phase = .idle, .failure = null, .completed = 0, .total = 0, .installing_version = null }, manager, .{ .phase = .idle, .failure = null, .exit_code = null, .version = null, .version_id = null, .debug = false, .attempt_id = 0 }, &pending, services);
        return .ok;
    }
};

test "UI layout complete Home selected server and 23 tasks retains rows and Start footer" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_length = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const root = path_buffer[0..path_length];
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    try store.update(.{ .instances = &.{.{ .id = "fixture-game", .name = "fixture-game", .minecraft_version = "1.21" }}, .servers = &.{.{ .id = "fixture-server", .name = "Fixture Survival", .address = "survival.fixture.invalid", .instance_id = "fixture-game", .show_on_home = true }}, .selected_instance = "fixture-game", .selected_server = "fixture-server" });
    var manager = try java.Manager.init(a, std.testing.io, root);
    defer manager.deinit();
    var server_ui = servers_view.Ui.init(a);
    defer server_ui.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    for (0..23) |_| {
        const task = try registry.create(.java_scan, "Fixture Java runtime scan with a long wrapped task title");
        try registry.start(task);
        task.report(.scanning, 42, 100);
    }
    HomeFrame.state = .{};
    try std.testing.expect(HomeFrame.state.active_game.set("fixture-game"));
    HomeFrame.manager = &manager;
    // Only dependencies used by the complete Home renderer are supplied; no workers run.
    HomeFrame.services = undefined;
    HomeFrame.services.configuration = &store;
    HomeFrame.services.tasks = &registry;
    HomeFrame.services.servers_ui = &server_ui;
    HomeFrame.services.accounts = null;
    for ([_]dvui.Size{ .{ .w = 640, .h = 400 }, .{ .w = 1280, .h = 720 } }) |size| {
        var window = try dvui.testing.init(.{ .window_size = size });
        defer window.deinit();
        // testing.init defaults to 2x pixels; exercise the requested physical window sizes.
        window.backend.size_pixels = .{ .w = size.w, .h = size.h };
        var theme = dvui.Theme.builtin.adwaita_dark;
        theme.font_body = theme.font_body.withSize(16);
        theme.font_heading = theme.font_body.withSize(18);
        theme.font_title = theme.font_body.withSize(24);
        window.window.themeSet(theme);
        HomeFrame.services.task_viewport_height = size.h;
        HomeFrame.pending = null;
        try dvui.testing.settle(HomeFrame.draw);
        const home = try dvui.testing.tagGet("home-layout");
        const header = try dvui.testing.tagGet("home-header");
        const viewport = try dvui.testing.tagGet("task-viewport");
        const footer = try dvui.testing.tagGet("home-footer");
        const start = try dvui.testing.tagGet("home-start");
        const row = try dvui.testing.tagGet("task-23-row");
        try expectInside(.{ .x = 0, .y = 0, .w = size.w, .h = size.h }, home.rect);
        for ([_]dvui.TagData{ header, viewport, footer, start }) |part| {
            try std.testing.expect(part.visible);
            try expectInside(home.rect, part.rect);
        }
        for ([_][]const u8{ "home-server-target", "home-server-address", "home-server-instance" }) |tag| {
            const part = try dvui.testing.tagGet(tag);
            try std.testing.expect(part.visible);
            try expectInside(header.rect, part.rect);
        }
        try std.testing.expect(header.rect.y + header.rect.h <= viewport.rect.y);
        try std.testing.expect(viewport.rect.y + viewport.rect.h <= footer.rect.y);
        try expectInside(footer.rect, start.rect);
        try std.testing.expectApproxEqAbs(@as(f32, 48), start.rect.h, 0.1);
        try expectInside(viewport.rect, row.rect);
        for ([_][]const u8{ "task-23-title", "task-23-status", "task-23-progress", "task-23-cancel" }) |tag| {
            const part = try dvui.testing.tagGet(tag);
            try std.testing.expect(part.visible);
            try expectInside(row.rect, part.rect);
        }
        if (size.h >= 520) try expectInside(viewport.rect, (try dvui.testing.tagGet("task-22-row")).rect);
        try std.testing.expectApproxEqAbs(row.rect.h * (if (size.h < 520) @as(f32, 1) else 2), viewport.rect.h, 0.1);
        try dvui.testing.moveTo("home-start");
        try dvui.testing.click(.left);
        try dvui.testing.settle(HomeFrame.draw);
        try std.testing.expect(HomeFrame.pending == null);
        try dvui.testing.expectNotFocused("home-start");
        for (window.window.tab_index_prev.items) |entry| try std.testing.expect(entry.widgetId != start.id);
        dvui.focusWidget(start.id, null, null);
        _ = try window.window.addEventKey(.{ .code = .enter, .action = .down, .mod = .none });
        _ = try window.window.addEventKey(.{ .code = .enter, .action = .up, .mod = .none });
        try dvui.testing.settle(HomeFrame.draw);
        try std.testing.expect(HomeFrame.pending == null);
        dvui.focusWidget(null, null, null);
        if (size.h >= 520) {
            try dvui.testing.moveTo("task-23-cancel");
            try dvui.testing.click(.left);
            try dvui.testing.settle(HomeFrame.draw);
            try std.testing.expect(registry.tasks()[22].canceled());
        }
        try dvui.testing.moveTo("task-viewport");
        _ = try window.window.addEventMouseWheel(-100000, .vertical, null);
        try dvui.testing.settle(HomeFrame.draw);
        const oldest = try dvui.testing.tagGet("task-1-row");
        try std.testing.expect(oldest.visible);
        try expectInside(viewport.rect, oldest.rect);
        try std.testing.expectEqual(@as(usize, 23), registry.tasks().len);
        try std.testing.expectEqualStrings("fixture-server", store.snapshot().selected_server.?);
        try std.testing.expectEqual(start.rect, (try dvui.testing.tagGet("home-start")).rect);
        try std.testing.expectEqual(viewport.rect, (try dvui.testing.tagGet("task-viewport")).rect);
        std.debug.print("Home {d}x{d}: header={d:.1}..{d:.1}, tasks={d:.1}..{d:.1}, footer={d:.1}..{d:.1}, Start={d:.1}x{d:.1}, registry=23\n", .{ size.w, size.h, header.rect.y, header.rect.y + header.rect.h, viewport.rect.y, viewport.rect.y + viewport.rect.h, footer.rect.y, footer.rect.y + footer.rect.h, start.rect.w, start.rect.h });
    }
}

test "UI layout actual task rows retain status progress and working cancellation" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    for ([_]dvui.Size{ .{ .w = 300, .h = 240 }, .{ .w = 940, .h = 500 } }) |size| {
        var window = try dvui.testing.init(.{ .window_size = size });
        defer window.deinit();
        var theme = dvui.Theme.builtin.adwaita_dark;
        theme.font_body = theme.font_body.withSize(24);
        window.window.themeSet(theme);
        var registry = tasks.Registry.init(std.testing.allocator);
        defer registry.deinit();
        const first = try registry.create(.game_install, "First fixture install");
        try registry.start(first);
        const second = try registry.create(.java_scan, "Fixture Java runtime 20 with a long wrapped title and more words than can fit on two lines");
        try registry.start(second);
        second.report(.scanning, 20, null);
        Frame.registry = &registry;
        Frame.show_settings = false;
        Frame.rows = if (size.h < 400) 1 else 2;
        try dvui.testing.settle(Frame.draw);
        const viewport = try dvui.testing.tagGet("task-viewport");
        const row = try dvui.testing.tagGet("task-2-row");
        const title = try dvui.testing.tagGet("task-2-title");
        const status = try dvui.testing.tagGet("task-2-status");
        const progress = try dvui.testing.tagGet("task-2-progress");
        const cancel = try dvui.testing.tagGet("task-2-cancel");
        try expectInside(viewport.rect, row.rect);
        for ([_]dvui.TagData{ title, status, progress, cancel }) |part| {
            try std.testing.expect(part.visible);
            try expectInside(row.rect, part.rect);
        }
        try std.testing.expect(title.rect.y + title.rect.h <= status.rect.y);
        try std.testing.expect(status.rect.y + status.rect.h <= progress.rect.y);
        try std.testing.expect(title.rect.x + title.rect.w <= cancel.rect.x);
        if (Frame.rows == 2) {
            const other = try dvui.testing.tagGet("task-1-row");
            try std.testing.expect(other.visible);
            try expectInside(viewport.rect, other.rect);
            try std.testing.expect(row.rect.y + row.rect.h <= other.rect.y + 0.1);
        }
        second.report(.downloading, std.math.maxInt(u64), std.math.maxInt(u64));
        try dvui.testing.settle(Frame.draw);
        try std.testing.expectEqual(row.rect, (try dvui.testing.tagGet("task-2-row")).rect);
        try std.testing.expectEqual(viewport.rect, (try dvui.testing.tagGet("task-viewport")).rect);
        try dvui.testing.moveTo("task-2-cancel");
        try dvui.testing.click(.left);
        try dvui.testing.settle(Frame.draw);
        try std.testing.expectEqual(tasks.State.canceling, second.state);
        try std.testing.expect(second.canceled());
        try std.testing.expectEqual(tasks.State.running, first.state);
        try std.testing.expectEqual(@as(usize, 2), registry.tasks().len);
    }
}

test "UI layout settings numeric entries contain complete font metrics and accept edits" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    var window = try dvui.testing.init(.{ .window_size = .{ .w = 340, .h = 400 } });
    defer window.deinit();
    var theme = dvui.Theme.builtin.adwaita_dark;
    theme.font_body = theme.font_body.withSize(24);
    window.window.themeSet(theme);
    var ui = try settings_view.Ui.init(std.testing.allocator, .{ .default_memory_mb = 4096, .download_connections = 8 });
    defer ui.deinit();
    Frame.settings = &ui;
    Frame.show_settings = true;
    try dvui.testing.settle(Frame.draw);
    const memory = try dvui.testing.tagGet("默认游戏内存-border");
    const connections = try dvui.testing.tagGet("下载连接数-border");
    try std.testing.expect(memory.visible and connections.visible);
    const glyph_height = dvui.themeGet().font_body.textHeight() * window.window.natural_scale;
    try std.testing.expect(memory.rect.h >= glyph_height + 16 * window.window.natural_scale);
    try std.testing.expect(connections.rect.h >= glyph_height + 16 * window.window.natural_scale);
    try std.testing.expect(memory.rect.y + memory.rect.h <= connections.rect.y);
    const memory_caret = try dvui.testing.tagGet("默认游戏内存-caret");
    const connections_caret = try dvui.testing.tagGet("下载连接数-caret");
    for ([_]dvui.TagData{ memory_caret, connections_caret }, [_]dvui.TagData{ memory, connections }) |caret, entry| {
        try std.testing.expect(caret.rect.h > 0);
        try expectInside(entry.rect, caret.rect);
        const entry_center = entry.rect.y + entry.rect.h / 2;
        const caret_center = caret.rect.y + caret.rect.h / 2;
        try std.testing.expectApproxEqAbs(entry_center, caret_center, window.window.natural_scale);
    }
    try dvui.testing.moveTo("默认游戏内存");
    try dvui.testing.click(.left);
    try dvui.testing.settle(Frame.draw);
    try dvui.testing.pressKey(.home, .none);
    try dvui.testing.settle(Frame.draw);
    try dvui.testing.writeText("1");
    try dvui.testing.settle(Frame.draw);
    try std.testing.expectEqualStrings("14096", std.mem.sliceTo(&ui.memory_buffer, 0));
    try std.testing.expect(ui.pending == null);
}

const EditorsFrame = struct {
    var server_ui: *servers_view.Ui = undefined;
    var instance_ui: *instances_view.Ui = undefined;
    var store: *config.Store = undefined;
    var server_service: *server_manager.Manager = undefined;
    var instance_service: *instances_manager.Manager = undefined;
    var service_calls: usize = 0;

    fn draw() !dvui.App.Result {
        const root = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .padding = dvui.Rect.all(12), .tag = "editors-layout" });
        defer root.deinit();
        const server_pane = dvui.box(@src(), .{}, .{ .expand = .both, .padding = dvui.Rect.all(12) });
        servers_view.draw(server_ui, store, server_service);
        server_pane.deinit();
        const instance_pane = dvui.box(@src(), .{}, .{ .expand = .both, .padding = dvui.Rect.all(12) });
        instances_view.draw(instance_ui, store, instance_service, .{ .installed = &.{}, .available = &.{}, .phase = .idle, .failure = null, .completed = 0, .total = 0, .installing_version = null });
        instance_pane.deinit();
        return .ok;
    }

    fn rejectQuery(_: std.mem.Allocator, _: std.Io, _: config.Server, _: servers.Options) !servers.OwnedStatus {
        service_calls += 1;
        return error.UnexpectedLayoutServiceCall;
    }

    fn rejectLease(_: ?*anyopaque, _: []const u8) !void {
        service_calls += 1;
        return error.UnexpectedLayoutServiceCall;
    }

    fn releaseLease(_: ?*anyopaque, _: []const u8) void {
        service_calls += 1;
    }
};

test "UI layout server and instance editor widget IDs keep independent focus and buffers" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, std.testing.io, root);
    defer paths.deinit();
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var server_service = server_manager.Manager.initWithQuery(a, std.testing.io, EditorsFrame.rejectQuery);
    defer server_service.deinit();
    var instance_service = try instances_manager.Manager.init(a, std.testing.io, &paths, &registry, .{}, .{ .context = null, .acquire = EditorsFrame.rejectLease, .recheck = EditorsFrame.rejectLease, .release = EditorsFrame.releaseLease });
    defer instance_service.deinit();
    var server_ui = servers_view.Ui.init(a);
    defer server_ui.deinit();
    server_ui.editor_open = true;
    @memset(&server_ui.draft.port, 0);
    var instance_ui = instances_view.Ui.init(a);
    defer instance_ui.deinit();
    instance_ui.mode = .import_folder;
    EditorsFrame.server_ui = &server_ui;
    EditorsFrame.instance_ui = &instance_ui;
    EditorsFrame.store = &store;
    EditorsFrame.server_service = &server_service;
    EditorsFrame.instance_service = &instance_service;
    EditorsFrame.service_calls = 0;

    const size: dvui.Size = .{ .w = 1280, .h = 720 };
    var window = try dvui.testing.init(.{ .window_size = size });
    defer window.deinit();
    window.backend.size_pixels = .{ .w = size.w, .h = size.h };
    try dvui.testing.settle(EditorsFrame.draw);

    const Input = struct { id: dvui.Id, rect: dvui.Rect.Physical };
    var inputs: [6]Input = undefined;
    var count: usize = 0;
    // TextEntryWidget stores this state on its actual registered, focusable ID.
    for (window.window.tab_index_prev.items) |entry| {
        if (dvui.dataGet(null, entry.widgetId, "_edited_outside", bool) == null) continue;
        try std.testing.expect(count < inputs.len);
        inputs[count] = .{ .id = entry.widgetId, .rect = entry.rect orelse return error.InputRectangleMissing };
        try expectInside((try dvui.testing.tagGet("editors-layout")).rect, inputs[count].rect);
        for (inputs[0..count]) |other| try std.testing.expect(other.id != entry.widgetId);
        count += 1;
    }
    try std.testing.expectEqual(inputs.len, count);
    const buffers = [_][]u8{ &server_ui.draft.name, &server_ui.draft.address, &server_ui.draft.port, &instance_ui.draft.name, &instance_ui.draft.java_path, &instance_ui.draft.memory };
    const typed = [_][]const u8{ "Server Draft", "fixture.invalid", "25a566", "Instance Draft", "/fixture/jre/bin/java", "4x096" };
    const expected = [_][]const u8{ "Server Draft", "fixture.invalid", "25566", "Instance Draft", "/fixture/jre/bin/java", "4096" };
    for (inputs, 0..) |input, index| {
        _ = try window.window.addEventMouseMotion(.{ .pt = input.rect.center() });
        try dvui.testing.click(.left);
        try dvui.testing.settle(EditorsFrame.draw);
        try std.testing.expectEqual(input.id, dvui.focusedWidgetId().?);
        try dvui.testing.writeText(typed[index]);
        try dvui.testing.settle(EditorsFrame.draw);
        try std.testing.expectEqual(input.id, dvui.focusedWidgetId().?);
        for (buffers, 0..) |buffer, buffer_index| {
            try std.testing.expectEqualStrings(if (buffer_index <= index) expected[buffer_index] else "", std.mem.sliceTo(buffer, 0));
        }
    }
    try expectRealIconTooltips(EditorsFrame.draw, 7);
    for (buffers, expected) |buffer, value| try std.testing.expectEqualStrings(value, std.mem.sliceTo(buffer, 0));
    try std.testing.expect(server_ui.pending == null);
    try std.testing.expect(instance_ui.pending == null);
    try std.testing.expectEqual(@as(usize, 0), EditorsFrame.service_calls);
    try std.testing.expectEqual(@as(usize, 0), registry.tasks().len);
    try std.testing.expect(!server_service.isBusy());
    try std.testing.expect(!instance_service.isBusy());
    try std.testing.expectEqual(@as(usize, 0), store.snapshot().servers.len);
    try std.testing.expectEqual(@as(usize, 0), store.snapshot().instances.len);
}

fn expectRealIconTooltips(frame: dvui.App.frameFunction, expected_count: usize) !void {
    const window = dvui.currentWindow();
    const focus = dvui.focusedWidgetId();
    const Icon = struct { id: dvui.Id, rect: dvui.Rect.Physical };
    var icons: [8]Icon = undefined;
    var count: usize = 0;
    for (window.tab_index_prev.items) |entry| {
        const rect = entry.rect orelse continue;
        if (rect.w > 44 or rect.h > 44) continue;
        if (dvui.dataGet(null, entry.widgetId, "_edited_outside", bool) != null) continue;
        try std.testing.expect(count < icons.len);
        icons[count] = .{ .id = entry.widgetId, .rect = rect };
        count += 1;
    }
    errdefer std.debug.print("Tooltip regression: expected {d} real icons, found {d}\n", .{ expected_count, count });
    try std.testing.expectEqual(expected_count, count);
    var tooltip_ids: [8]dvui.Id = undefined;
    for (icons[0..count], 0..) |icon, index| {
        _ = try window.addEventMouseMotion(.{ .pt = icon.rect.center() });
        try dvui.testing.settle(frame);
        _ = try dvui.testing.step(frame);
        try std.testing.expectEqual(@as(usize, 2), window.subwindows.stack.items.len);
        const tooltip = window.subwindows.stack.items[1];
        try std.testing.expect(dvui.dataGet(null, tooltip.id, "_showing", bool) orelse false);
        try std.testing.expect(tooltip.rect_pixels.w > 0 and tooltip.rect_pixels.h > 0);
        try std.testing.expect(tooltip.focused_widget_id == null);
        try std.testing.expectEqual(focus, dvui.focusedWidgetId());
        for (icons[0..count]) |other| try std.testing.expect(other.id != tooltip.id);
        for (tooltip_ids[0..index]) |previous| try std.testing.expect(previous != tooltip.id);
        tooltip_ids[index] = tooltip.id;
        _ = try window.addEventMouseMotion(.{ .pt = .{ .x = 1, .y = 1 } });
        try dvui.testing.settle(frame);
        _ = try dvui.testing.step(frame);
        try std.testing.expectEqual(@as(usize, 1), window.subwindows.stack.items.len);
        try std.testing.expectEqual(focus, dvui.focusedWidgetId());
    }
}

const JavaTooltipFrame = struct {
    var ui: *java_view.Ui = undefined;
    var manager: *java.Manager = undefined;

    fn draw() !dvui.App.Result {
        const root = dvui.box(@src(), .{}, .{ .expand = .both, .padding = dvui.Rect.all(24) });
        defer root.deinit();
        java_view.drawPage(ui, manager);
        return .ok;
    }
};

test "UI layout real Java revealed action tooltips have independent IDs without stealing focus" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var manager = try java.Manager.init(a, std.testing.io, root);
    defer manager.deinit();
    var ui = java_view.Ui.init(a);
    defer ui.deinit();
    JavaTooltipFrame.ui = &ui;
    JavaTooltipFrame.manager = &manager;
    const size: dvui.Size = .{ .w = 640, .h = 400 };
    var window = try dvui.testing.init(.{ .window_size = size });
    defer window.deinit();
    window.backend.size_pixels = .{ .w = size.w, .h = size.h };
    try dvui.testing.settle(JavaTooltipFrame.draw);
    try expectRealIconTooltips(JavaTooltipFrame.draw, 2);
    try std.testing.expectEqual(@as(usize, 0), ui.commands.items.len);
    try std.testing.expect(!ui.download_requested);
    try std.testing.expect(!ui.modal_open);
    try std.testing.expect(!ui.search_queued);
    try std.testing.expectEqual(@as(usize, 0), manager.entries().len);
}

const EditorTextFrame = struct {
    const TextBounds = struct {
        rect: dvui.Rect.Physical,
        clip: dvui.Rect.Physical,
        font_height: f32,
    };
    var server = true;
    var samples: [3][]const u8 = undefined;
    var bounds: [3]?TextBounds = @splat(null);

    fn draw() !dvui.App.Result {
        const win = dvui.currentWindow();
        var commands: std.ArrayList(dvui.RenderCommand) = .empty;
        defer commands.deinit(win.arena());
        const previous_commands = win.defer_render_cmds;
        const previous_rendering = win.render_target.rendering;
        win.defer_render_cmds = &commands;
        win.render_target.rendering = false;
        defer {
            win.defer_render_cmds = previous_commands;
            win.render_target.rendering = previous_rendering;
        }
        bounds = @splat(null);
        {
            const root = dvui.box(@src(), .{}, .{ .expand = .both, .padding = dvui.Rect.all(12) });
            defer root.deinit();
            if (server) {
                servers_view.draw(EditorsFrame.server_ui, EditorsFrame.store, EditorsFrame.server_service);
            } else {
                instances_view.draw(EditorsFrame.instance_ui, EditorsFrame.store, EditorsFrame.instance_service, .{ .installed = &.{}, .available = &.{}, .phase = .idle, .failure = null, .completed = 0, .total = 0, .installing_version = null });
            }
        }
        // Observe real text-layout render commands and their effective scissor,
        // rather than reconstructing field geometry or testing an outer box.
        for (commands.items) |command| switch (command.cmd) {
            .text => |text| {
                for (samples, 0..) |sample, index| if (std.mem.eql(u8, text.text, sample)) {
                    bounds[index] = .{ .rect = text.rs.r, .clip = command.clip, .font_height = text.font.textHeight() * text.rs.s };
                };
            },
            else => {},
        };
        return .ok;
    }
};

test "UI layout real server and instance editor font lines are not clipped at compact and wide sizes" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, std.testing.io, root);
    defer paths.deinit();
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var server_service = server_manager.Manager.initWithQuery(a, std.testing.io, EditorsFrame.rejectQuery);
    defer server_service.deinit();
    var instance_service = try instances_manager.Manager.init(a, std.testing.io, &paths, &registry, .{}, .{ .context = null, .acquire = EditorsFrame.rejectLease, .recheck = EditorsFrame.rejectLease, .release = EditorsFrame.releaseLease });
    defer instance_service.deinit();
    var server_ui = servers_view.Ui.init(a);
    defer server_ui.deinit();
    server_ui.editor_open = true;
    var instance_ui = instances_view.Ui.init(a);
    defer instance_ui.deinit();
    instance_ui.mode = .import_folder;
    const samples = [_][]const u8{ "Server gypQ", "gypQ.invalid", "25565", "Instance gypQ", "/tmp/gypQ", "4096" };
    const buffers = [_][]u8{ &server_ui.draft.name, &server_ui.draft.address, &server_ui.draft.port, &instance_ui.draft.name, &instance_ui.draft.java_path, &instance_ui.draft.memory };
    for (buffers, samples) |buffer, sample| {
        @memset(buffer, 0);
        @memcpy(buffer[0..sample.len], sample);
    }
    EditorsFrame.server_ui = &server_ui;
    EditorsFrame.instance_ui = &instance_ui;
    EditorsFrame.store = &store;
    EditorsFrame.server_service = &server_service;
    EditorsFrame.instance_service = &instance_service;
    EditorsFrame.service_calls = 0;
    for ([_]dvui.Size{ .{ .w = 640, .h = 400 }, .{ .w = 1280, .h = 720 } }) |size| {
        for ([_]f32{ 16, 24 }) |font_size| {
            for ([_]bool{ true, false }) |server| {
                var window = try dvui.testing.init(.{ .window_size = size });
                defer window.deinit();
                window.backend.size_pixels = .{ .w = size.w, .h = size.h };
                var theme = dvui.themeGet();
                theme.font_body = theme.font_body.withSize(font_size);
                theme.font_heading = theme.font_body.withSize(18);
                theme.font_title = theme.font_body.withSize(24);
                window.window.themeSet(theme);
                EditorTextFrame.server = server;
                const offset: usize = if (server) 0 else 3;
                @memcpy(&EditorTextFrame.samples, samples[offset..][0..3]);
                try dvui.testing.settle(EditorTextFrame.draw);
                var inputs: [3]dvui.Id = undefined;
                var widths: [3]f32 = undefined;
                var count: usize = 0;
                for (window.window.tab_index_prev.items) |entry| {
                    if (dvui.dataGet(null, entry.widgetId, "_edited_outside", bool) == null) continue;
                    try std.testing.expect(count < inputs.len);
                    inputs[count] = entry.widgetId;
                    widths[count] = (entry.rect orelse return error.InputRectangleMissing).w;
                    try std.testing.expect(widths[count] >= size.w - 64);
                    count += 1;
                }
                try std.testing.expectEqual(inputs.len, count);
                for (inputs, 0..) |id, index| {
                    dvui.focusWidget(id, null, null);
                    try dvui.testing.settle(EditorTextFrame.draw);
                    var focused_width: ?f32 = null;
                    for (window.window.tab_index_prev.items) |entry| if (entry.widgetId == id) {
                        focused_width = (entry.rect orelse return error.InputRectangleMissing).w;
                    };
                    try std.testing.expectApproxEqAbs(widths[index], focused_width orelse return error.FocusedInputMissing, 0.01);
                    const text = EditorTextFrame.bounds[index] orelse return error.InputTextNotRendered;
                    errdefer std.debug.print("Editor text clipped: server={any}, size={any}, font={d}, input={s}, bounds={any}\n", .{ server, size, font_size, EditorTextFrame.samples[index], text });
                    try std.testing.expect(text.rect.h >= text.font_height - 0.01);
                    try expectInside(text.clip, text.rect);
                    if (font_size == 24) try std.testing.expect(text.font_height > 20);
                }
                for (buffers, samples) |buffer, sample| try std.testing.expectEqualStrings(sample, std.mem.sliceTo(buffer, 0));
                try std.testing.expect(server_ui.pending == null);
                try std.testing.expect(instance_ui.pending == null);
                try std.testing.expectEqual(@as(usize, 0), EditorsFrame.service_calls);
                try std.testing.expectEqual(@as(usize, 0), registry.entries.items.len);
                try std.testing.expectEqual(@as(usize, 0), store.snapshot().instances.len);
                try std.testing.expectEqual(@as(usize, 0), store.snapshot().servers.len);
            }
        }
    }
}

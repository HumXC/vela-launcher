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
const java_download_view = @import("ui/java_download_view.zig");
const java_download_controller = @import("ui/java_download_controller.zig");
const instances_manager = @import("ui/instances_manager.zig");
const server_manager = @import("ui/server_manager.zig");
const instances = @import("core/instances.zig");
const worlds = @import("core/worlds.zig");
const instance_leases = @import("core/instance_leases.zig");
const worlds_manager = @import("ui/worlds_manager.zig");
const worlds_view = @import("ui/worlds_view.zig");
const servers = @import("core/servers.zig");
const components = @import("ui/components.zig");
const games = @import("ui/game_library.zig");
const launch = @import("ui/game_launch.zig");
const logs_view = @import("ui/logs_view.zig");
const shutdown_view = @import("ui/shutdown_view.zig");
const lifecycle = @import("core/lifecycle.zig");
const accounts_view = @import("ui/accounts_view.zig");
const accounts_manager = @import("ui/accounts_manager.zig");

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
    var java_download = try java_download_controller.Controller.initWithOptions(a, std.testing.io, .{ .root = root, .task_registry = &registry });
    defer java_download.deinit();
    for (0..23) |_| {
        const task = try registry.create(.java_scan, "Fixture Java runtime scan with a long wrapped task title");
        try registry.start(task);
        task.report(.scanning, 42, 100);
    }
    HomeFrame.state = .{};
    try std.testing.expect(HomeFrame.state.active_game.set("fixture-game"));
    HomeFrame.manager = &manager;
    // Home reads the real idle Java controller; services outside Home stay inert.
    HomeFrame.services = .{
        .configuration = &store,
        .tasks = &registry,
        .servers_ui = &server_ui,
        .settings = undefined,
        .java_download = &java_download,
        .java_download_ui = undefined,
        .servers = undefined,
        .logs = undefined,
        .worlds = undefined,
        .worlds_ui = undefined,
    };
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

const FormFrame = struct {
    const labels = [_][]const u8{ "取消", "保存" };
    const Observation = struct { id: dvui.Id, rect: dvui.Rect.Physical, text: dvui.Rect.Physical, clip: dvui.Rect.Physical, primary: bool };
    var options: components.FormOptions = .{};
    var draft: [128]u8 = @splat(0);
    var observations: [labels.len]?Observation = @splat(null);
    var saves: usize = 0;
    var cancels: usize = 0;

    fn draw() !dvui.App.Result {
        const win = dvui.currentWindow();
        var commands: std.ArrayList(dvui.RenderCommand) = .empty;
        defer commands.deinit(win.arena());
        const previous_commands = win.defer_render_cmds;
        const previous_rendering = win.render_target.rendering;
        win.defer_render_cmds = &commands;
        win.render_target.rendering = false;
        dvui.debug.captureScopeBegin(win.gpa);
        defer {
            dvui.debug.captureScopeEnd();
            win.defer_render_cmds = previous_commands;
            win.render_target.rendering = previous_rendering;
        }
        observations = @splat(null);
        {
            const root = dvui.box(@src(), .{}, .{ .tag = "form-layout", .expand = .both, .padding = dvui.Rect.all(16) });
            defer root.deinit();
            switch (components.formActions(@src(), options)) {
                .save => saves += 1,
                .cancel => cancels += 1,
                .none => {},
            }
            const body = dvui.scrollArea(@src(), .{}, .{ .tag = "form-body", .expand = .both, .padding = dvui.Rect.all(0), .margin = dvui.Rect.all(0) });
            defer body.deinit();
            const input = dvui.textEntry(@src(), .{ .text = .{ .buffer = &draft } }, .{ .tag = "form-draft", .expand = .horizontal, .padding = dvui.Rect.all(8) });
            input.deinit();
            for (0..40) |index| dvui.label(@src(), "Scrollable form information {d}", .{index}, .{ .id_extra = index });
        }
        const capture = dvui.debug.lastCapture() orelse return error.FormCaptureMissing;
        for (commands.items) |command| switch (command.cmd) {
            .text => |text| {
                for (labels, 0..) |label, index| if (std.mem.eql(u8, text.text, label)) {
                    for (capture.widgets.items) |widget| {
                        if (!std.mem.eql(u8, widget.name orelse continue, "Button") or !JavaFrame.contains(widget.rect_border, text.rs.r.center())) continue;
                        try std.testing.expect(observations[index] == null);
                        observations[index] = .{ .id = widget.id, .rect = widget.rect_border, .text = text.rs.r, .clip = command.clip, .primary = widget.style == .highlight };
                    }
                };
            },
            else => {},
        };
        return .ok;
    }

    fn visible(index: usize, enabled: bool) !Observation {
        const control = observations[index] orelse return error.FormLabelNotRendered;
        try expectInside(dvui.windowRectPixels(), control.rect);
        try expectInside(control.rect, control.text);
        try expectInside(control.clip, control.text);
        try std.testing.expect(JavaFrame.contains(control.clip, control.rect.center()));
        var registered: usize = 0;
        for (dvui.currentWindow().tab_index_prev.items) |entry| if (entry.widgetId == control.id) {
            registered += 1;
        };
        try std.testing.expectEqual(@as(usize, if (enabled) 1 else 0), registered);
        return control;
    }

    fn click(index: usize, enabled: bool) !void {
        const control = try visible(index, enabled);
        _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = control.rect.center() });
        try dvui.testing.click(.left);
        try dvui.testing.settle(draw);
    }
};

test "UI layout shared form footer stays visible and native actions preserve the edited draft" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    for ([_]dvui.Size{ .{ .w = 640, .h = 400 }, .{ .w = 1280, .h = 720 } }) |size| {
        var window = try dvui.testing.init(.{ .window_size = size });
        defer window.deinit();
        window.backend.size_pixels = .{ .w = size.w, .h = size.h };
        var theme = dvui.Theme.builtin.adwaita_dark;
        theme.font_body = theme.font_body.withSize(16);
        window.window.themeSet(theme);
        FormFrame.options = .{};
        FormFrame.draft = @splat(0);
        FormFrame.saves = 0;
        FormFrame.cancels = 0;
        try dvui.testing.settle(FormFrame.draw);
        const cancel = try FormFrame.visible(0, true);
        const save = try FormFrame.visible(1, true);
        try std.testing.expect(cancel.id != save.id);
        try std.testing.expect(!cancel.primary and save.primary);
        try std.testing.expect(cancel.rect.x + cancel.rect.w < save.rect.x);
        try std.testing.expectApproxEqAbs(cancel.rect.y, save.rect.y, 0.1);
        const body = (try dvui.testing.tagGet("form-body")).rect;
        try std.testing.expect(body.y + body.h <= cancel.rect.y + 0.1);
        try dvui.testing.moveTo("form-draft");
        try dvui.testing.click(.left);
        try dvui.testing.settle(FormFrame.draw);
        try dvui.testing.writeText("Unsaved native draft");
        try dvui.testing.settle(FormFrame.draw);
        const draft_id = (try dvui.testing.tagGet("form-draft")).id;
        try std.testing.expectEqual(draft_id, dvui.focusedWidgetId().?);
        try std.testing.expectEqualStrings("Unsaved native draft", std.mem.sliceTo(&FormFrame.draft, 0));
        var visited: [2]bool = @splat(false);
        const steps = window.window.tab_index_prev.items.len + 1;
        for (0..steps) |_| {
            try dvui.testing.pressKey(.tab, .none);
            try dvui.testing.settle(FormFrame.draw);
            const focus = dvui.focusedWidgetId();
            if (focus == cancel.id) visited[0] = true;
            if (focus == save.id) visited[1] = true;
            try std.testing.expectEqual(cancel.id, (try FormFrame.visible(0, true)).id);
            try std.testing.expectEqual(save.id, (try FormFrame.visible(1, true)).id);
        }
        try std.testing.expect(visited[0] and visited[1]);
        try std.testing.expectEqual(@as(usize, 0), FormFrame.saves + FormFrame.cancels);
        try dvui.testing.moveTo("form-body");
        _ = try window.window.addEventMouseWheel(-100000, .vertical, null);
        try dvui.testing.settle(FormFrame.draw);
        try std.testing.expectEqual(cancel.rect, (try FormFrame.visible(0, true)).rect);
        try std.testing.expectEqual(save.rect, (try FormFrame.visible(1, true)).rect);
        FormFrame.options = .{ .save_enabled = false, .cancel_enabled = false };
        try dvui.testing.settle(FormFrame.draw);
        try std.testing.expectEqual(cancel.id, (try FormFrame.visible(0, false)).id);
        try std.testing.expectEqual(save.id, (try FormFrame.visible(1, false)).id);
        try FormFrame.click(0, false);
        try FormFrame.click(1, false);
        window.window.focusWidget(save.id, null, null);
        try dvui.testing.pressKey(.enter, .none);
        try dvui.testing.settle(FormFrame.draw);
        try std.testing.expectEqual(@as(usize, 0), FormFrame.saves + FormFrame.cancels);
        FormFrame.options = .{};
        window.window.focusWidget(null, null, null);
        try dvui.testing.settle(FormFrame.draw);
        try FormFrame.click(0, true);
        try std.testing.expectEqual(@as(usize, 1), FormFrame.cancels);
        try std.testing.expectEqual(@as(usize, 0), FormFrame.saves);
        try FormFrame.click(1, true);
        try std.testing.expectEqual(@as(usize, 1), FormFrame.saves);
        try std.testing.expectEqual(@as(usize, 1), FormFrame.cancels);
        try std.testing.expectEqualStrings("Unsaved native draft", std.mem.sliceTo(&FormFrame.draft, 0));
    }
}

const RootHomeFrame = struct {
    const Layout = struct { id: dvui.Id, left: dvui.Rect.Physical, right: dvui.Rect.Physical };
    var state: model.Model = .{};
    var library: *games.Controller = undefined;
    var manager: *java.Manager = undefined;
    var java_ui: *java_view.Ui = undefined;
    var launcher: *launch.Controller = undefined;
    var services: view.Services = undefined;
    var layout: ?Layout = null;

    fn draw() !dvui.App.Result {
        const win = dvui.currentWindow();
        dvui.debug.captureScopeBegin(win.gpa);
        defer dvui.debug.captureScopeEnd();
        try view.draw(&state, library, manager, java_ui, launcher, services);
        const capture = dvui.debug.lastCapture() orelse return error.RootCaptureMissing;
        layout = null;
        for (capture.widgets.items) |widget| {
            if (!std.mem.eql(u8, widget.name orelse "", "Paned") or !std.mem.eql(u8, widget.src_fn, "draw")) continue;
            var children: [2]dvui.Rect.Physical = undefined;
            var count: usize = 0;
            for (capture.widgets.items) |child| if (child.parent_id == widget.id) {
                try std.testing.expect(count < children.len);
                children[count] = child.rect_border;
                count += 1;
            };
            try std.testing.expectEqual(children.len, count);
            try std.testing.expect(layout == null);
            layout = .{ .id = widget.id, .left = children[0], .right = children[1] };
        }
        return .ok;
    }

    fn dragTo(x: f32) !void {
        const win = dvui.currentWindow();
        const panes = layout orelse return error.RootPanedMissing;
        // The divider lies in the observed gap between its actual registered children.
        const handle: dvui.Point.Physical = .{ .x = (panes.left.x + panes.left.w + panes.right.x) / 2, .y = panes.left.center().y };
        _ = try win.addEventMouseMotion(.{ .pt = handle });
        _ = try win.addEventMouseButton(.left, .press);
        try dvui.testing.settle(draw);
        try std.testing.expectEqual(panes.id, (win.capture orelse return error.RootDragDidNotCapture).id);
        _ = try win.addEventMouseMotion(.{ .pt = .{ .x = x, .y = handle.y } });
        try dvui.testing.settle(draw);
        _ = try win.addEventMouseButton(.left, .release);
        try dvui.testing.settle(draw);
        try std.testing.expect(win.capture == null);
        try std.testing.expectEqual(panes.id, layout.?.id);
    }
};

test "UI layout real Home root native sidebar drag clamps and survives panel changes" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var manager = try java.Manager.init(a, std.testing.io, root);
    defer manager.deinit();
    var library = try games.Controller.initWithOptions(a, std.testing.io, .{ .root = root, .task_registry = &registry });
    defer library.deinit();
    var launcher = try launch.Controller.init(a, std.testing.io, root);
    defer launcher.deinit();
    var java_ui = java_view.Ui.init(a);
    defer java_ui.deinit();
    var download = try java_download_controller.Controller.initWithOptions(a, std.testing.io, .{ .root = root, .task_registry = &registry });
    defer download.deinit();
    var download_ui = java_download_view.Ui.init(a);
    defer download_ui.deinit();
    var settings = try settings_view.Ui.init(a, store.snapshot().settings);
    defer settings.deinit();
    var server_ui = servers_view.Ui.init(a);
    defer server_ui.deinit();
    @memcpy(server_ui.draft.name[0..12], "Server Draft");
    const original_draft = server_ui.draft;
    var logs: logs_view.View = .{};
    RootHomeFrame.library = &library;
    RootHomeFrame.manager = &manager;
    RootHomeFrame.java_ui = &java_ui;
    RootHomeFrame.launcher = &launcher;
    RootHomeFrame.services = .{ .configuration = &store, .tasks = &registry, .settings = &settings, .java_download = &download, .java_download_ui = &download_ui, .servers_ui = &server_ui, .servers = undefined, .logs = &logs, .worlds = undefined, .worlds_ui = undefined, .allow_mutations = false };
    for ([_]dvui.Size{ .{ .w = 640, .h = 400 }, .{ .w = 1280, .h = 720 } }) |size| {
        var window = try dvui.testing.init(.{ .window_size = size });
        defer window.deinit();
        window.backend.size_pixels = .{ .w = size.w, .h = size.h };
        var theme = dvui.Theme.builtin.adwaita_dark;
        theme.font_body = theme.font_body.withSize(16);
        theme.font_heading = theme.font_body.withSize(18);
        theme.font_title = theme.font_body.withSize(24);
        window.window.themeSet(theme);
        RootHomeFrame.state = .{};
        try dvui.testing.settle(RootHomeFrame.draw);
        const initial = RootHomeFrame.layout orelse return error.RootPanedMissing;
        const initial_home = (try dvui.testing.tagGet("home-layout")).rect;
        try expectInside(initial.right, initial_home);
        try RootHomeFrame.dragTo(initial.right.x + 48);
        const expanded = RootHomeFrame.layout.?;
        const expanded_home = (try dvui.testing.tagGet("home-layout")).rect;
        try std.testing.expect(expanded.left.w > initial.left.w + 20);
        try std.testing.expect(expanded.right.w < initial.right.w - 20);
        try std.testing.expect(expanded_home.x > initial_home.x + 20);
        try std.testing.expect(expanded_home.w < initial_home.w - 20);
        const saved_width = RootHomeFrame.state.sidebar_width;
        model.transition(&RootHomeFrame.state, .open_more);
        try dvui.testing.settle(RootHomeFrame.draw);
        try std.testing.expectApproxEqAbs(saved_width, RootHomeFrame.state.sidebar_width, 0.1);
        try std.testing.expectEqual(expanded.left, RootHomeFrame.layout.?.left);
        try std.testing.expectEqual(expanded.right, RootHomeFrame.layout.?.right);
        model.transition(&RootHomeFrame.state, .back);
        try dvui.testing.settle(RootHomeFrame.draw);
        try std.testing.expectEqual(expanded_home, (try dvui.testing.tagGet("home-layout")).rect);
        try RootHomeFrame.dragTo(1);
        const minimum = RootHomeFrame.layout.?;
        try std.testing.expectApproxEqAbs(@as(f32, 260), RootHomeFrame.state.sidebar_width, 0.1);
        try std.testing.expect(minimum.left.w < expanded.left.w - 20);
        try std.testing.expect(minimum.right.w > expanded.right.w + 20);
        try RootHomeFrame.dragTo(1);
        try std.testing.expectEqual(minimum, RootHomeFrame.layout.?);
        try RootHomeFrame.dragTo(size.w - 1);
        const maximum = RootHomeFrame.layout.?;
        // Independent acceptance bounds for these two real window sizes.
        try std.testing.expectApproxEqAbs(if (size.w == 640) @as(f32, 352) else 500, RootHomeFrame.state.sidebar_width, 0.1);
        try std.testing.expect(maximum.left.w > minimum.left.w + 20);
        try std.testing.expect(maximum.right.w >= 280 - 0.1);
        try RootHomeFrame.dragTo(size.w - 1);
        try std.testing.expectEqual(maximum, RootHomeFrame.layout.?);
        try expectInside(maximum.right, (try dvui.testing.tagGet("home-layout")).rect);
        try std.testing.expectEqual(original_draft, server_ui.draft);
        try std.testing.expect(server_ui.pending == null and settings.pending == null and download_ui.pending == null);
        try std.testing.expectEqual(@as(usize, 0), java_ui.commands.items.len);
        try std.testing.expect(library.active == null and launcher.job == null);
        try std.testing.expectEqual(@as(usize, 0), registry.tasks().len);
        try std.testing.expectEqual(@as(usize, 0), store.snapshot().servers.len);
        try std.testing.expectEqual(@as(usize, 0), store.snapshot().instances.len);
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
    const Footer = struct { id: dvui.Id, rect: dvui.Rect.Physical, text: dvui.Rect.Physical, clip: dvui.Rect.Physical };
    var footers: [4]?Footer = @splat(null);

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
        footers = @splat(null);
        const root = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .padding = dvui.Rect.all(12), .tag = "editors-layout" });
        defer root.deinit();
        const server_pane = dvui.box(@src(), .{}, .{ .expand = .both, .padding = dvui.Rect.all(12) });
        const server_rect = server_pane.data().contentRectScale().r;
        servers_view.draw(server_ui, store, server_service);
        server_pane.deinit();
        const instance_pane = dvui.box(@src(), .{}, .{ .expand = .both, .padding = dvui.Rect.all(12) });
        const instance_rect = instance_pane.data().contentRectScale().r;
        instances_view.draw(instance_ui, store, instance_service, .{ .installed = &.{}, .available = &.{}, .phase = .idle, .failure = null, .completed = 0, .total = 0, .installing_version = null }, &.{});
        instance_pane.deinit();
        for (commands.items) |command| switch (command.cmd) {
            .text => |text| {
                for (FormFrame.labels, 0..) |label, index| if (std.mem.eql(u8, text.text, label)) {
                    const pane: usize = if (JavaFrame.contains(server_rect, text.rs.r.center())) 0 else if (JavaFrame.contains(instance_rect, text.rs.r.center())) 1 else continue;
                    for (win.tab_index.items) |entry| {
                        const rect = entry.rect orelse continue;
                        if (!JavaFrame.contains(rect, text.rs.r.center())) continue;
                        const slot = pane * 2 + index;
                        try std.testing.expect(footers[slot] == null);
                        footers[slot] = .{ .id = entry.widgetId, .rect = rect, .text = text.rs.r, .clip = command.clip };
                    }
                };
            },
            else => {},
        };
        return .ok;
    }

    fn visibleFooters() ![4]Footer {
        var result: [4]Footer = undefined;
        for (footers, 0..) |sample, index| {
            const footer = sample orelse return error.EditorFooterLabelMissing;
            try expectInside(dvui.windowRectPixels(), footer.rect);
            try expectInside(footer.rect, footer.text);
            try expectInside(footer.clip, footer.text);
            try std.testing.expect(JavaFrame.contains(footer.clip, footer.rect.center()));
            for (result[0..index]) |previous| try std.testing.expect(previous.id != footer.id);
            var registered: usize = 0;
            for (dvui.currentWindow().tab_index_prev.items) |entry| if (entry.widgetId == footer.id) {
                registered += 1;
            };
            try std.testing.expectEqual(@as(usize, 1), registered);
            result[index] = footer;
        }
        for ([_]usize{ 0, 2 }) |index| try std.testing.expect(result[index].rect.x + result[index].rect.w < result[index + 1].rect.x);
        return result;
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
    instance_ui.draft = try instances_view.Draft.fromInstance(a, .{ .id = "fixture-instance", .name = "Fixture", .minecraft_version = "1.21" });
    @memset(&instance_ui.draft.name, 0);
    instance_ui.mode = .options;
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
    var inputs: [5]Input = undefined;
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
    const buffers = [_][]u8{ &server_ui.draft.name, &server_ui.draft.address, &server_ui.draft.port, &instance_ui.draft.name, &instance_ui.draft.memory };
    const typed = [_][]const u8{ "Server Draft", "fixture.invalid", "25a566", "Instance Draft", "4x096" };
    const expected = [_][]const u8{ "Server Draft", "fixture.invalid", "25566", "Instance Draft", "4096" };
    for (inputs, 0..) |input, index| {
        // Edits can change either pane's minimum width; use this frame's real input rectangle.
        var live_rect: ?dvui.Rect.Physical = null;
        for (window.window.tab_index_prev.items) |entry| if (entry.widgetId == input.id) {
            try std.testing.expect(live_rect == null);
            live_rect = entry.rect orelse return error.InputRectangleMissing;
        };
        const rect = live_rect orelse return error.InputNotRegistered;
        try expectInside((try dvui.testing.tagGet("editors-layout")).rect, rect);
        _ = try window.window.addEventMouseMotion(.{ .pt = rect.center() });
        try dvui.testing.click(.left);
        try dvui.testing.settle(EditorsFrame.draw);
        if (dvui.focusedWidgetId() != input.id) std.debug.print("Editor input {d}: expected {any}, focused {any}, live rect {any}\n", .{ index, input.id, dvui.focusedWidgetId(), rect });
        try std.testing.expectEqual(input.id, dvui.focusedWidgetId().?);
        try dvui.testing.writeText(typed[index]);
        try dvui.testing.settle(EditorsFrame.draw);
        try std.testing.expectEqual(input.id, dvui.focusedWidgetId().?);
        for (buffers, 0..) |buffer, buffer_index| {
            try std.testing.expectEqualStrings(if (buffer_index <= index) expected[buffer_index] else "", std.mem.sliceTo(buffer, 0));
        }
    }
    // Both real editors now expose text footers, independent of their inputs.
    const footers = try EditorsFrame.visibleFooters();
    var visited: [4]bool = @splat(false);
    const tab_steps = window.window.tab_index_prev.items.len + 1;
    for (0..tab_steps) |_| {
        try dvui.testing.pressKey(.tab, .none);
        try dvui.testing.settle(EditorsFrame.draw);
        const current = try EditorsFrame.visibleFooters();
        const focused = dvui.focusedWidgetId();
        for (footers, current, 0..) |previous, control, index| {
            try std.testing.expectEqual(previous.id, control.id);
            if (focused == control.id) visited[index] = true;
        }
        for (buffers, expected) |buffer, value| try std.testing.expectEqualStrings(value, std.mem.sliceTo(buffer, 0));
    }
    for (visited) |seen| try std.testing.expect(seen);
    window.window.focusWidget(inputs[inputs.len - 1].id, null, null);
    try dvui.testing.settle(EditorsFrame.draw);
    const focus = dvui.focusedWidgetId();
    const controls = try a.dupe(dvui.TabIndex, window.window.tab_index_prev.items);
    defer a.free(controls);
    var action_count: usize = 0;
    for (controls, 0..) |control, index| {
        for (controls[0..index]) |previous| try std.testing.expect(previous.widgetId != control.widgetId);
        if (dvui.dataGet(null, control.widgetId, "_edited_outside", bool) != null) continue;
        const rect = control.rect orelse continue;
        action_count += 1;
        _ = try window.window.addEventMouseMotion(.{ .pt = rect.center() });
        try dvui.testing.settle(EditorsFrame.draw);
        try std.testing.expectEqual(focus, dvui.focusedWidgetId());
    }
    try std.testing.expect(action_count >= footers.len);
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

const JavaFrame = struct {
    const Control = struct { id: dvui.Id, rect: dvui.Rect.Physical };
    const Text = enum { empty, visible, disclosure, hidden, hidden_status, acquire, download, search, visible_path, hidden_path, acquisition_heading, details_nav, restore, add };
    var labels = [_][]const u8{ "暂无 Java", "Fixture Visible · Java 21", "已隐藏 (1)", "Fixture Hidden · Java 17", "已隐藏 · 不参与游戏启动", "获取 Java", "下载 Java", "搜索本机 Java", "", "", "获取 Java", "查看所选 Java", "恢复显示", "添加 Java" };
    const Observation = struct { rect: dvui.Rect.Physical, clip: dvui.Rect.Physical, control: ?Control, fill: ?dvui.Color, border: ?dvui.Color, focused: bool, background: bool };
    var observations: [labels.len]?Observation = @splat(null);
    var ui: *java_view.Ui = undefined;
    var manager: *java.Manager = undefined;
    var download_ui: *java_download_view.Ui = undefined;
    var controller: *java_download_controller.Controller = undefined;
    var interactive = true;

    fn draw() !dvui.App.Result {
        const win = dvui.currentWindow();
        var commands: std.ArrayList(dvui.RenderCommand) = .empty;
        defer commands.deinit(win.arena());
        const previous_commands = win.defer_render_cmds;
        const previous_rendering = win.render_target.rendering;
        win.defer_render_cmds = &commands;
        win.render_target.rendering = false;
        dvui.debug.captureScopeBegin(win.gpa);
        defer {
            dvui.debug.captureScopeEnd();
            win.defer_render_cmds = previous_commands;
            win.render_target.rendering = previous_rendering;
        }
        observations = @splat(null);
        java_download_view.beginFrame(download_ui);
        {
            const root = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .padding = dvui.Rect.all(8), .tag = "java-layout" });
            defer root.deinit();
            {
                const sidebar = dvui.box(@src(), .{}, .{ .expand = .vertical, .min_size_content = .{ .w = if (dvui.windowRect().w < 800) 212 else 260 }, .padding = dvui.Rect.all(8), .tag = "java-sidebar" });
                defer sidebar.deinit();
                java_view.drawSidebar(ui, manager, interactive);
            }
            {
                const page = dvui.box(@src(), .{}, .{ .expand = .both, .padding = dvui.Rect.all(12), .tag = "java-page" });
                defer page.deinit();
                java_view.drawPage(ui, manager, download_ui, controller);
            }
        }
        // Match actual Button hitboxes, including disabled widgets absent from tab order.
        const capture = dvui.debug.lastCapture() orelse return error.JavaCaptureMissing;
        const sidebar_rect = (try dvui.testing.tagGet("java-sidebar")).rect;
        for (commands.items) |command| switch (command.cmd) {
            .text => |text| {
                for (labels, 0..) |_, index| if (matchesLabel(index, text.text)) {
                    const kind: Text = @enumFromInt(index);
                    const visible_rect = text.rs.r.intersect(command.clip);
                    if (visible_rect.w <= 0 or visible_rect.h <= 0) continue;
                    const in_sidebar = contains(sidebar_rect, visible_rect.center());
                    switch (kind) {
                        .visible, .hidden, .visible_path, .hidden_path, .acquire => if (!in_sidebar) continue,
                        .acquisition_heading, .details_nav => if (in_sidebar) continue,
                        else => {},
                    }
                    var sample: Observation = .{ .rect = text.rs.r, .clip = command.clip, .control = null, .fill = null, .border = null, .focused = false, .background = false };
                    for (capture.widgets.items) |widget| {
                        if (!std.mem.eql(u8, widget.name orelse continue, "Button") or !contains(widget.rect_border, visible_rect.center())) continue;
                        try std.testing.expect(sample.control == null);
                        sample.control = .{ .id = widget.id, .rect = widget.rect_border };
                        sample.fill = widget.color_fill;
                        sample.border = widget.color_border;
                        sample.focused = widget.focused;
                        sample.background = widget.background;
                    }
                    if (observations[index]) |previous| if (previous.control != null and sample.control == null) continue;
                    observations[index] = sample;
                };
            },
            else => {},
        };
        return .ok;
    }

    fn matchesLabel(index: usize, rendered: []const u8) bool {
        const label = labels[index];
        if (label.len == 0 or rendered.len == 0) return false;
        if (std.mem.eql(u8, label, rendered)) return true;
        // One-line TextLayout clipping emits only the visible prefix for long labels.
        return switch (@as(Text, @enumFromInt(index))) {
            .visible, .hidden, .visible_path, .hidden_path => std.mem.startsWith(u8, label, rendered),
            else => false,
        };
    }

    fn contains(rect: dvui.Rect.Physical, point: dvui.Point.Physical) bool {
        return point.x >= rect.x and point.x <= rect.x + rect.w and point.y >= rect.y and point.y <= rect.y + rect.h;
    }

    fn observed(text: Text) !Observation {
        return observations[@intFromEnum(text)] orelse error.JavaTextNotRendered;
    }

    fn control(text: Text) !Control {
        return (try observed(text)).control orelse error.JavaControlNotRegistered;
    }

    fn expectVisible(text: Text, pane: []const u8) !void {
        const sample = try observed(text);
        try expectInside((try dvui.testing.tagGet(pane)).rect, sample.rect);
        try expectInside(sample.clip, sample.rect);
    }

    fn click(text: Text) !void {
        const target = try control(text);
        const sample = try observed(text);
        try std.testing.expect(contains(sample.clip, target.rect.center()));
        _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = target.rect.center() });
        try dvui.testing.click(.left);
        try dvui.testing.settle(draw);
    }

    fn clickText(text: Text) !void {
        const sample = try observed(text);
        const target = sample.rect.intersect(sample.clip);
        try std.testing.expect(target.w > 0 and target.h > 0);
        _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = target.center() });
        try dvui.testing.click(.left);
        try dvui.testing.settle(draw);
    }

    fn expectTabRegistration(target: Control, enabled: bool) !void {
        var count: usize = 0;
        for (dvui.currentWindow().tab_index_prev.items) |entry| if (entry.widgetId == target.id) {
            count += 1;
        };
        try std.testing.expectEqual(@as(usize, if (enabled) 1 else 0), count);
    }

    fn expectWholeRow(name: Text, path: Text, enabled: bool) !Control {
        const title = try observed(name);
        const subtitle = try observed(path);
        const target = try control(name);
        const path_target = try control(path);
        try std.testing.expectEqual(target.id, path_target.id);
        try std.testing.expectEqual(target.rect, path_target.rect);
        try std.testing.expectEqual(title.fill.?, subtitle.fill.?);
        try std.testing.expectEqual(title.focused, subtitle.focused);
        try std.testing.expect(title.background and subtitle.background);
        try expectInside((try dvui.testing.tagGet("java-sidebar")).rect, target.rect);
        try expectInside(target.rect, title.rect.intersect(title.clip));
        try expectInside(target.rect, subtitle.rect.intersect(subtitle.clip));
        try std.testing.expect(title.rect.y + title.rect.h <= subtitle.rect.y + 0.1);
        try expectTabRegistration(target, enabled);
        return target;
    }

    fn scrollPage(amount: f32) !void {
        try dvui.testing.moveTo("java-page");
        _ = try dvui.currentWindow().addEventMouseWheel(amount, .vertical, null);
        try dvui.testing.settle(draw);
    }

    fn expectNoCommands() !void {
        try std.testing.expectEqual(@as(usize, 0), ui.commands.items.len);
        try std.testing.expect(!ui.download_requested and !ui.search_queued);
        try std.testing.expect(!java_view.hasModal(ui));
        try std.testing.expect(download_ui.pending == null);
        try std.testing.expect(!manager.isSearching());
        try std.testing.expectEqual(java_download_controller.Phase.idle, controller.snapshot().phase);
        try std.testing.expectEqual(@as(usize, 0), controller.registry.tasks().len);
    }
};

fn expectJavaSidebarTooltips(controls: []const JavaFrame.Control) !void {
    const window = dvui.currentWindow();
    const focus = dvui.focusedWidgetId();
    var tooltip_ids: [3]dvui.Id = undefined;
    for (controls, 0..) |control, index| {
        for (controls[0..index]) |previous| try std.testing.expect(previous.id != control.id);
        _ = try window.addEventMouseMotion(.{ .pt = control.rect.center() });
        // Each testing step advances 100 ms: the first hover frame stays hidden.
        _ = try dvui.testing.step(JavaFrame.draw);
        // A zero-alpha tooltip may already have a layout subwindow.
        for (0..10) |_| _ = try dvui.testing.step(JavaFrame.draw);
        try std.testing.expectEqual(@as(usize, 2), window.subwindows.stack.items.len);
        const tooltip = window.subwindows.stack.items[1];
        try std.testing.expect(dvui.dataGet(null, tooltip.id, "_showing", bool) orelse false);
        try std.testing.expect(tooltip.rect_pixels.w > 0 and tooltip.rect_pixels.h > 0);
        const tip = tooltip.rect_pixels;
        const trigger = control.rect;
        const gap = @max(@max(trigger.x - tip.x - tip.w, tip.x - trigger.x - trigger.w), @max(trigger.y - tip.y - tip.h, tip.y - trigger.y - trigger.h));
        try std.testing.expect(gap >= components.tooltip_gap_px - 0.5);
        try std.testing.expect(tooltip.focused_widget_id == null);
        try std.testing.expectEqual(focus, dvui.focusedWidgetId());
        for (controls) |other| try std.testing.expect(other.id != tooltip.id);
        for (tooltip_ids[0..index]) |previous| try std.testing.expect(previous != tooltip.id);
        tooltip_ids[index] = tooltip.id;
        try JavaFrame.expectNoCommands();
        _ = try window.addEventMouseMotion(.{ .pt = .{ .x = 1, .y = 1 } });
        try dvui.testing.settle(JavaFrame.draw);
        _ = try dvui.testing.step(JavaFrame.draw);
        try std.testing.expectEqual(@as(usize, 1), window.subwindows.stack.items.len);
        try std.testing.expectEqual(focus, dvui.focusedWidgetId());
    }
}

const TooltipTimingFrame = struct {
    var control: dvui.Rect.Physical = .{};
    var text_alpha: f32 = 0;

    fn draw() !dvui.App.Result {
        const win = dvui.currentWindow();
        var commands: std.ArrayList(dvui.RenderCommand) = .empty;
        defer commands.deinit(win.arena());
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
        }
        {
            var button: dvui.ButtonWidget = undefined;
            button.init(@src(), .{ .draw_focus = false }, .{ .rect = .{ .x = 8, .y = 8, .w = 180, .h = 48 }, .tab_index = 0 });
            defer button.deinit();
            button.processHover();
            button.drawBackground();
            control = button.data().borderRectScale().r;
            components.tooltip(@src(), button.data().id, control, "Delayed tooltip label");
        }
        text_alpha = 0;
        for (win.subwindows.stack.items) |*subwindow| {
            // FloatingTooltip resets deferred queues and records in its own subwindow.
            for (subwindow.render_cmds.items) |command| switch (command.cmd) {
                .text => text_alpha = @max(text_alpha, command.alpha),
                else => {},
            };
            for (subwindow.render_cmds_after.items) |command| switch (command.cmd) {
                .text => text_alpha = @max(text_alpha, command.alpha),
                else => {},
            };
        }
        return .ok;
    }
};

test "UI layout shared tooltip keeps an idle wakeup through its initial hover delay" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    var window = try dvui.testing.init(.{ .window_size = .{ .w = 640, .h = 400 } });
    defer window.deinit();
    try dvui.testing.settle(TooltipTimingFrame.draw);
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = TooltipTimingFrame.control.center() });
    // No ordinary labels are drawn, so these are the actual tooltip text commands.
    // Native idle loops use Window.end() to schedule the next frame; forced
    // testing.step() frames alone would hide a lost timer after the first frame.
    var pending_wait: ?u32 = null;
    for (0..5) |_| {
        pending_wait = try dvui.testing.step(TooltipTimingFrame.draw);
        try std.testing.expect(pending_wait != null);
        try std.testing.expect(TooltipTimingFrame.text_alpha <= 0.001);
    }
    try std.testing.expect(pending_wait.? > 0 and pending_wait.? <= 600_000);
    for (0..6) |_| _ = try dvui.testing.step(TooltipTimingFrame.draw);
    try std.testing.expect(TooltipTimingFrame.text_alpha > 0.99);
    try std.testing.expect(dvui.focusedWidgetId() == null);
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = .{ .x = 1, .y = 1 } });
    for (0..2) |_| _ = try dvui.testing.step(TooltipTimingFrame.draw);
    try std.testing.expectEqual(@as(f32, 0), TooltipTimingFrame.text_alpha);
}

test "UI layout Java left-top acquisition and registered hidden paths share whole-row Button selection" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const visible_path = "/fixture/registered-runtime-with-a-long-directory-name/another-long-directory/bin/java";
    const hidden_path = "/fixture/hidden-runtime-with-a-long-directory-name/another-long-directory/bin/java";
    const visible: java.Runtime = .{ .path = visible_path, .major = 21, .vendor = "Fixture Visible" };
    const hidden: java.Runtime = .{ .path = hidden_path, .major = 17, .vendor = "Fixture Hidden" };
    const fixture = try std.json.Stringify.valueAlloc(a, .{ .version = @as(u32, 1), .runtimes = &[_]java.Runtime{ visible, hidden }, .hidden = &[_]java.Runtime{hidden} }, .{});
    defer a.free(fixture);
    try tmp.dir.createDirPath(std.testing.io, ".vela");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".vela/java.json", .data = fixture });
    var manager = try java.Manager.init(a, std.testing.io, root);
    defer manager.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var controller = try java_download_controller.Controller.initWithOptions(a, std.testing.io, .{ .root = root, .task_registry = &registry });
    defer controller.deinit();
    JavaFrame.controller = &controller;
    JavaFrame.manager = &manager;
    JavaFrame.labels[@intFromEnum(JavaFrame.Text.visible_path)] = visible_path;
    JavaFrame.labels[@intFromEnum(JavaFrame.Text.hidden_path)] = hidden_path;
    defer JavaFrame.interactive = true;
    for ([_]dvui.Size{ .{ .w = 640, .h = 400 }, .{ .w = 1280, .h = 720 } }) |size| {
        var ui = java_view.Ui.init(a);
        defer ui.deinit();
        var download_ui = java_download_view.Ui.init(a);
        defer download_ui.deinit();
        JavaFrame.ui = &ui;
        JavaFrame.download_ui = &download_ui;
        JavaFrame.interactive = true;
        var window = try dvui.testing.init(.{ .window_size = size });
        defer window.deinit();
        window.backend.size_pixels = .{ .w = size.w, .h = size.h };
        try dvui.testing.settle(JavaFrame.draw);
        try JavaFrame.expectVisible(.acquire, "java-sidebar");
        const acquisition = try JavaFrame.control(.acquire);
        const visible_row = try JavaFrame.expectWholeRow(.visible, .visible_path, true);
        try std.testing.expect(acquisition.rect.y + acquisition.rect.h <= visible_row.rect.y);
        try std.testing.expect(acquisition.id != visible_row.id);
        try JavaFrame.expectTabRegistration(acquisition, true);
        try std.testing.expect((try JavaFrame.observed(.acquisition_heading)).control == null);
        try std.testing.expect(JavaFrame.observations[@intFromEnum(JavaFrame.Text.details_nav)] == null);
        try std.testing.expect(JavaFrame.observations[@intFromEnum(JavaFrame.Text.hidden_path)] == null);
        const unselected_fill = (try JavaFrame.observed(.visible)).fill.?;
        const unselected_border = (try JavaFrame.observed(.visible)).border.?;
        const acquisition_fill = (try JavaFrame.observed(.acquire)).fill.?;
        const acquisition_border = (try JavaFrame.observed(.acquire)).border.?;
        try std.testing.expectEqual(@as(u8, 0), unselected_fill.a);
        try std.testing.expectEqual(@as(u8, 0), acquisition_fill.a);

        // A click in the second line must focus and select the same whole Button.
        try JavaFrame.clickText(.visible_path);
        try std.testing.expectEqualStrings(visible_path, ui.selected_path.?);
        try std.testing.expect(!ui.acquisition_open);
        const selected_row = try JavaFrame.expectWholeRow(.visible, .visible_path, true);
        try std.testing.expectEqual(visible_row.id, selected_row.id);
        try std.testing.expectEqual(selected_row.id, dvui.focusedWidgetId().?);
        try std.testing.expect((try JavaFrame.observed(.visible)).focused);
        try std.testing.expect(!std.meta.eql(unselected_border, (try JavaFrame.observed(.visible)).border.?));
        try std.testing.expect(!std.meta.eql(acquisition_border, (try JavaFrame.observed(.acquire)).border.?));
        try std.testing.expect(JavaFrame.observations[@intFromEnum(JavaFrame.Text.acquisition_heading)] == null);
        try std.testing.expect(JavaFrame.observations[@intFromEnum(JavaFrame.Text.details_nav)] == null);
        try JavaFrame.expectNoCommands();

        try JavaFrame.clickText(.acquire);
        try std.testing.expect(ui.acquisition_open);
        try std.testing.expectEqualStrings(visible_path, ui.selected_path.?);
        try std.testing.expectEqual(unselected_fill, (try JavaFrame.observed(.visible)).fill.?);
        try std.testing.expectEqual(acquisition_fill, (try JavaFrame.observed(.acquire)).fill.?);
        try JavaFrame.expectVisible(.acquisition_heading, "java-page");
        try JavaFrame.clickText(.visible);
        try std.testing.expect(!ui.acquisition_open);
        try std.testing.expectEqualStrings(visible_path, ui.selected_path.?);
        try std.testing.expectEqual(visible_row.id, dvui.focusedWidgetId().?);
        _ = try JavaFrame.expectWholeRow(.visible, .visible_path, true);

        try JavaFrame.click(.disclosure);
        try std.testing.expect(ui.show_hidden);
        const hidden_row = try JavaFrame.expectWholeRow(.hidden, .hidden_path, true);
        try std.testing.expect(hidden_row.id != visible_row.id and hidden_row.id != acquisition.id);
        try std.testing.expect(hidden_row.rect.x > visible_row.rect.x);
        const hidden_unselected_border = (try JavaFrame.observed(.hidden)).border.?;
        try JavaFrame.clickText(.hidden_path);
        try std.testing.expectEqualStrings(hidden_path, ui.selected_path.?);
        try std.testing.expect(!ui.acquisition_open);
        try std.testing.expectEqual(hidden_row.id, dvui.focusedWidgetId().?);
        _ = try JavaFrame.expectWholeRow(.hidden, .hidden_path, true);
        try std.testing.expect((try JavaFrame.observed(.hidden_path)).focused);
        try std.testing.expect(!std.meta.eql(hidden_unselected_border, (try JavaFrame.observed(.hidden_path)).border.?));
        try JavaFrame.expectVisible(.hidden_status, "java-page");
        try JavaFrame.expectNoCommands();
        try JavaFrame.clickText(.acquire);
        try JavaFrame.clickText(.hidden);
        try std.testing.expectEqualStrings(hidden_path, ui.selected_path.?);
        try std.testing.expect(!ui.acquisition_open);
        try std.testing.expectEqual(hidden_row.id, dvui.focusedWidgetId().?);

        // Existing busy and modal gates cover both lines and the acquisition action.
        for ([_]bool{ false, true }) |modal| {
            JavaFrame.interactive = modal;
            if (modal) ui.delete_confirmation = try a.dupe(u8, hidden_path);
            try dvui.testing.settle(JavaFrame.draw);
            _ = try JavaFrame.expectWholeRow(.visible, .visible_path, false);
            _ = try JavaFrame.expectWholeRow(.hidden, .hidden_path, false);
            try JavaFrame.expectTabRegistration(try JavaFrame.control(.acquire), false);
            for ([_]JavaFrame.Text{ .visible_path, .visible, .acquire, .hidden_path, .hidden }) |target| {
                try JavaFrame.clickText(target);
                try std.testing.expectEqualStrings(hidden_path, ui.selected_path.?);
                try std.testing.expect(!ui.acquisition_open);
                try std.testing.expectEqual(@as(usize, 0), ui.commands.items.len);
                try std.testing.expect(!ui.search_queued and !ui.download_requested);
                try std.testing.expect(download_ui.pending == null);
            }
            if (ui.delete_confirmation) |confirmation| {
                a.free(confirmation);
                ui.delete_confirmation = null;
            }
        }
        JavaFrame.interactive = true;
        try dvui.testing.settle(JavaFrame.draw);
        try JavaFrame.expectNoCommands();
        // Hidden metadata survives forgetting; restoring it must not re-register Java.
        try manager.forget(hidden_path);
        try dvui.testing.settle(JavaFrame.draw);
        try JavaFrame.clickText(.hidden_path);
        try JavaFrame.expectVisible(.restore, "java-page");
        try std.testing.expect(JavaFrame.observations[@intFromEnum(JavaFrame.Text.add)] == null);
        try JavaFrame.click(.restore);
        try std.testing.expectEqual(@as(usize, 1), ui.commands.items.len);
        try std.testing.expectEqualStrings(hidden_path, ui.commands.items[0].unhide);
        java_view.finish(&ui, &manager);
        try std.testing.expectEqual(@as(usize, 0), manager.hiddenEntries().len);
        for (manager.allEntries()) |entry| try std.testing.expect(!std.mem.eql(u8, entry.path, hidden_path));
        try JavaFrame.expectNoCommands();
        // Reset the registry so the second viewport checks the same registered/hidden fixture.
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".vela/java.json", .data = fixture });
        const reloaded = try java.Manager.init(a, std.testing.io, root);
        manager.deinit();
        manager = reloaded;
    }
}

test "UI layout real Java acquisition empty and hidden sidebar keep independent focus and commands" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var empty_manager = try java.Manager.init(a, std.testing.io, root);
    defer empty_manager.deinit();
    const visible_path = try std.fs.path.join(a, &.{ root, "visible", "bin", "java" });
    defer a.free(visible_path);
    const hidden_path = try std.fs.path.join(a, &.{ root, "hidden", "bin", "java" });
    defer a.free(hidden_path);
    const visible: java.Runtime = .{ .path = visible_path, .major = 21, .vendor = "Fixture Visible" };
    const hidden: java.Runtime = .{ .path = hidden_path, .major = 17, .vendor = "Fixture Hidden" };
    const fixture = try std.json.Stringify.valueAlloc(a, .{ .version = @as(u32, 1), .runtimes = &[_]java.Runtime{ visible, hidden }, .hidden = &[_]java.Runtime{hidden} }, .{});
    defer a.free(fixture);
    try tmp.dir.createDirPath(std.testing.io, ".vela");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".vela/java.json", .data = fixture });
    var manager = try java.Manager.init(a, std.testing.io, root);
    defer manager.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var controller = try java_download_controller.Controller.initWithOptions(a, std.testing.io, .{ .root = root, .task_registry = &registry });
    defer controller.deinit();
    JavaFrame.controller = &controller;
    JavaFrame.labels[@intFromEnum(JavaFrame.Text.visible_path)] = visible_path;
    JavaFrame.labels[@intFromEnum(JavaFrame.Text.hidden_path)] = hidden_path;
    JavaFrame.interactive = true;
    for ([_]dvui.Size{ .{ .w = 640, .h = 400 }, .{ .w = 1280, .h = 720 } }) |size| {
        var ui = java_view.Ui.init(a);
        defer ui.deinit();
        var download_ui = java_download_view.Ui.init(a);
        defer download_ui.deinit();
        JavaFrame.ui = &ui;
        JavaFrame.download_ui = &download_ui;
        JavaFrame.manager = &empty_manager;
        var window = try dvui.testing.init(.{ .window_size = size });
        defer window.deinit();
        window.backend.size_pixels = .{ .w = size.w, .h = size.h };
        try dvui.testing.settle(JavaFrame.draw);
        try JavaFrame.expectVisible(.empty, "java-sidebar");
        try JavaFrame.expectVisible(.acquire, "java-sidebar");
        try JavaFrame.expectVisible(.acquisition_heading, "java-page");
        const acquisition = try JavaFrame.control(.acquire);
        try expectInside((try dvui.testing.tagGet("java-sidebar")).rect, acquisition.rect);
        try std.testing.expect(acquisition.rect.y + acquisition.rect.h <= (try JavaFrame.observed(.empty)).rect.y);
        try std.testing.expect((try JavaFrame.observed(.acquisition_heading)).control == null);
        try std.testing.expect(JavaFrame.observations[@intFromEnum(JavaFrame.Text.details_nav)] == null);
        try std.testing.expect(JavaFrame.observations[@intFromEnum(JavaFrame.Text.disclosure)] == null);
        try JavaFrame.expectNoCommands();
        try JavaFrame.scrollPage(-100000);
        try JavaFrame.expectVisible(.search, "java-page");
        var input: ?JavaFrame.Control = null;
        for (window.window.tab_index_prev.items) |entry| {
            if (dvui.dataGet(null, entry.widgetId, "_edited_outside", bool) == null) continue;
            try std.testing.expect(input == null);
            input = .{ .id = entry.widgetId, .rect = entry.rect orelse return error.InputRectangleMissing };
        }
        const path_input = input orelse return error.JavaSearchInputMissing;
        try expectInside((try dvui.testing.tagGet("java-page")).rect, path_input.rect);
        _ = try window.window.addEventMouseMotion(.{ .pt = path_input.rect.center() });
        try dvui.testing.click(.left);
        try dvui.testing.settle(JavaFrame.draw);
        try std.testing.expectEqual(path_input.id, dvui.focusedWidgetId().?);
        try dvui.testing.writeText("/fixture/search-only");
        try dvui.testing.settle(JavaFrame.draw);
        try std.testing.expectEqualStrings("/fixture/search-only", std.mem.sliceTo(&ui.path_buffer, 0));
        try JavaFrame.expectNoCommands();

        JavaFrame.manager = &manager;
        try dvui.testing.settle(JavaFrame.draw);
        try JavaFrame.expectVisible(.visible, "java-sidebar");
        try JavaFrame.expectVisible(.disclosure, "java-sidebar");
        try std.testing.expect(JavaFrame.observations[@intFromEnum(JavaFrame.Text.hidden)] == null);
        const visible_control = try JavaFrame.control(.visible);
        const disclosure = try JavaFrame.control(.disclosure);
        try std.testing.expect(visible_control.id != path_input.id and disclosure.id != path_input.id);
        try expectJavaSidebarTooltips(&.{ visible_control, disclosure });
        try JavaFrame.click(.disclosure);
        try std.testing.expect(ui.show_hidden);
        try JavaFrame.expectVisible(.hidden, "java-sidebar");
        const hidden_control = try JavaFrame.control(.hidden);
        try std.testing.expect(hidden_control.id != path_input.id);
        dvui.focusWidget(path_input.id, null, null);
        try expectJavaSidebarTooltips(&.{ visible_control, disclosure, hidden_control });
        // Name and path now share a two-line Button; click the visible name text.
        try JavaFrame.clickText(.hidden);
        try std.testing.expect(!ui.acquisition_open);
        try std.testing.expectEqualStrings(hidden_path, ui.selected_path.?);
        try JavaFrame.expectVisible(.hidden_status, "java-page");
        try std.testing.expect(!download_ui.start_admitted);
        try JavaFrame.expectNoCommands();
        try JavaFrame.scrollPage(100000);
        try JavaFrame.click(.acquire);
        try std.testing.expect(ui.acquisition_open);
        try JavaFrame.scrollPage(-100000);
        try JavaFrame.expectVisible(.search, "java-page");
        var found_input = false;
        for (window.window.tab_index_prev.items) |entry| if (entry.widgetId == path_input.id) {
            found_input = true;
        };
        try std.testing.expect(found_input);
        try std.testing.expectEqualStrings("/fixture/search-only", std.mem.sliceTo(&ui.path_buffer, 0));
        try JavaFrame.expectNoCommands();
        if (size.h >= 520) {
            // Real action clicks only queue requests; no finish/tick or worker runs.
            try JavaFrame.expectVisible(.download, "java-page");
            const download_control = try JavaFrame.control(.download);
            const search_control = try JavaFrame.control(.search);
            try std.testing.expect(download_control.id != search_control.id);
            try std.testing.expect(download_control.id != path_input.id and search_control.id != path_input.id);
            try JavaFrame.click(.download);
            try std.testing.expect(download_ui.pending != null and download_ui.pending.? == .start);
            try std.testing.expectEqual(download_ui.vendor, download_ui.pending.?.start.vendor);
            try std.testing.expectEqual(download_ui.major, download_ui.pending.?.start.major);
            try std.testing.expectEqual(@as(usize, 0), ui.commands.items.len);
            download_ui.pending = null;
            try dvui.testing.settle(JavaFrame.draw);
            try JavaFrame.click(.search);
            try std.testing.expectEqual(@as(usize, 1), ui.commands.items.len);
            try std.testing.expect(ui.commands.items[0] == .search);
            try std.testing.expectEqualStrings("/fixture/search-only", ui.commands.items[0].search);
            try std.testing.expect(ui.search_queued and ui.search_started);
            try std.testing.expect(download_ui.pending == null);
            java_view.discardCommands(&ui);
        }
        try JavaFrame.expectNoCommands();
        try std.testing.expectEqual(@as(usize, 1), manager.entries().len);
        try std.testing.expectEqual(@as(usize, 1), manager.hiddenEntries().len);
    }
}

const ShutdownFrame = struct {
    const labels = [_][]const u8{ "等待完成", "取消任务并退出", "保持打开" };
    const choices = [_]lifecycle.CloseChoice{ .wait, .cancel_and_quit, .keep_open };
    const Control = struct { id: dvui.Id, window_id: dvui.Id, rect: dvui.Rect.Physical, primary: bool };
    const Observation = struct { text: dvui.Rect.Physical, clip: dvui.Rect.Physical, control: Control };
    var active_background: usize = 1;
    var background_clips: [labels.len]?dvui.Rect.Physical = @splat(null);
    var selected: ?lifecycle.CloseChoice = null;
    var layout: shutdown_view.Layout = .{};
    var native_viewport: dvui.Rect.Physical = .{};
    var observations: [labels.len]?Observation = @splat(null);

    fn draw() !dvui.App.Result {
        const win = dvui.currentWindow();
        var commands: std.ArrayList(dvui.RenderCommand) = .empty;
        defer commands.deinit(win.arena());
        const previous_commands = win.defer_render_cmds;
        const previous_rendering = win.render_target.rendering;
        win.defer_render_cmds = &commands;
        win.render_target.rendering = false;
        dvui.debug.captureScopeBegin(win.gpa);
        defer {
            dvui.debug.captureScopeEnd();
            win.defer_render_cmds = previous_commands;
            win.render_target.rendering = previous_rendering;
        }
        observations = @splat(null);
        layout = .{};
        if (selected != null) return .ok;
        const parent_id = dvui.parentGet().data().id;
        const subwindow_id = dvui.subwindowCurrentId();
        background_clips = @splat(null);
        const result = shutdown_view.drawWithLayout(active_background, &layout);
        // The caller can apply policy only after every modal widget has deinitialized.
        try std.testing.expectEqual(parent_id, dvui.parentGet().data().id);
        try std.testing.expectEqual(subwindow_id, dvui.subwindowCurrentId());
        if (result) |choice| selected = choice;
        try observe(commands.items);
        // FloatingWindowWidget owns the actual queues rendered by Window.end.
        for (win.subwindows.stack.items) |subwindow| {
            try observe(subwindow.render_cmds.items);
            try observe(subwindow.render_cmds_after.items);
        }
        return .ok;
    }

    fn observe(commands: []const dvui.RenderCommand) !void {
        const win = dvui.currentWindow();
        const capture = dvui.debug.lastCapture() orelse return error.ShutdownCaptureMissing;
        for (commands) |command| switch (command.cmd) {
            .text => |text| {
                for (labels, 0..) |label, index| if (std.mem.eql(u8, text.text, label)) {
                    var control: ?Control = null;
                    for (capture.widgets.items) |widget| {
                        if (!std.mem.eql(u8, widget.name orelse continue, "Button") or !JavaFrame.contains(widget.rect_border, text.rs.r.center())) continue;
                        for (win.tab_index.items) |entry| {
                            if (entry.widgetId != widget.id) continue;
                            try std.testing.expect(control == null);
                            control = .{ .id = widget.id, .window_id = entry.windowId, .rect = widget.rect_border, .primary = widget.style == .highlight };
                        }
                    }
                    try std.testing.expect(observations[index] == null);
                    observations[index] = .{ .text = text.rs.r, .clip = command.clip, .control = control orelse return error.ShutdownControlNotRegistered };
                    // The label scissor is narrow; check the independently rendered Button fill.
                    const border = control.?.rect;
                    for (commands) |background_command| switch (background_command.cmd) {
                        .pathFillConvex => |fill| {
                            if (fill.path.points.len == 0) continue;
                            var left = std.math.inf(f32);
                            var top = std.math.inf(f32);
                            var right = -std.math.inf(f32);
                            var bottom = -std.math.inf(f32);
                            for (fill.path.points) |point| {
                                left = @min(left, point.x);
                                top = @min(top, point.y);
                                right = @max(right, point.x);
                                bottom = @max(bottom, point.y);
                            }
                            if (@abs(left - border.x) > 1.1 or @abs(top - border.y) > 1.1 or
                                @abs(right - (border.x + border.w)) > 1.1 or
                                @abs(bottom - (border.y + border.h)) > 1.1) continue;
                            try expectInside(background_command.clip, border);
                            background_clips[index] = background_command.clip;
                        },
                        else => {},
                    };
                };
            },
            else => {},
        };
    }

    fn visibleControl(index: usize) !Control {
        const sample = observations[index] orelse return error.ShutdownLabelNotRendered;
        const control = sample.control;
        const reported = switch (choices[index]) {
            .wait => layout.wait,
            .cancel_and_quit => layout.cancel_and_quit,
            .keep_open => layout.keep_open,
        } orelse return error.ShutdownRectangleNotReported;
        const modal = dvui.currentWindow().subwindows.get(control.window_id) orelse return error.ShutdownModalMissing;
        try std.testing.expect(sample.text.w > 0 and sample.text.h > 0);
        try std.testing.expect(control.rect.w > 0 and control.rect.h > 0);
        try std.testing.expectEqual(control.rect, reported);
        try std.testing.expectEqual(index == 2, control.primary);
        try expectInside(native_viewport, control.rect);
        try expectInside(dvui.windowRectPixels(), control.rect);
        try expectInside(layout.viewport orelse return error.ShutdownViewportMissing, control.rect);
        try expectInside(layout.modal orelse return error.ShutdownModalRectangleMissing, control.rect);
        try expectInside(modal.rect_pixels, control.rect);
        // Check the entire button against its own background clip and the footer clip.
        try expectInside(background_clips[index] orelse return error.ShutdownBackgroundNotRendered, control.rect);
        try expectInside(layout.clip orelse return error.ShutdownClipMissing, control.rect);
        try expectInside(control.rect, sample.text);
        try expectInside(sample.clip, sample.text);
        return control;
    }

    fn expectStable(controls: [labels.len]Control) !void {
        const win = dvui.currentWindow();
        for (controls, 0..) |previous, index| {
            const current = try visibleControl(index);
            try std.testing.expectEqual(previous, current);
            var registered: usize = 0;
            for (win.tab_index_prev.items) |entry| {
                if (entry.widgetId != current.id or entry.windowId != current.window_id) continue;
                registered += 1;
                try expectInside(entry.rect orelse return error.ShutdownTabRectangleMissing, current.rect);
            }
            try std.testing.expectEqual(@as(usize, 1), registered);
        }
        try std.testing.expect(selected == null);
    }
};

test "UI layout real shutdown modal keeps every choice fully visible and reachable in native viewports" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    const Viewport = struct { native: dvui.Size, ui: dvui.Size };
    const viewports = [_]Viewport{
        .{ .native = .{ .w = 640, .h = 400 }, .ui = .{ .w = 640, .h = 363 } },
        .{ .native = .{ .w = 1280, .h = 720 }, .ui = .{ .w = 1280, .h = 683 } },
    };
    for (viewports) |viewport| {
        for ([_]usize{ 1, std.math.maxInt(usize) }) |count| {
            for (ShutdownFrame.choices, 0..) |choice, index| {
                for ([_]bool{ false, true }) |keyboard| {
                    var window = try dvui.testing.init(.{ .window_size = viewport.ui });
                    defer window.deinit();
                    window.backend.size_pixels = .{ .w = viewport.ui.w, .h = viewport.ui.h };
                    var theme = dvui.Theme.builtin.adwaita_dark;
                    theme.font_body = theme.font_body.withSize(16);
                    theme.font_heading = theme.font_body.withSize(18);
                    window.window.themeSet(theme);
                    ShutdownFrame.active_background = count;
                    ShutdownFrame.selected = null;
                    ShutdownFrame.native_viewport = .{ .w = viewport.native.w, .h = viewport.native.h };
                    try dvui.testing.settle(ShutdownFrame.draw);
                    try std.testing.expectApproxEqAbs(viewport.ui.h, ShutdownFrame.layout.viewport.?.h, 0.1);
                    try expectInside(dvui.windowRectPixels(), ShutdownFrame.layout.modal.?);
                    var controls: [ShutdownFrame.labels.len]ShutdownFrame.Control = undefined;
                    for (&controls, 0..) |*control, slot| {
                        control.* = try ShutdownFrame.visibleControl(slot);
                        for (controls[0..slot]) |previous| try std.testing.expect(previous.id != control.id);
                        if (slot > 0) try std.testing.expect(controls[slot - 1].rect.y + controls[slot - 1].rect.h <= control.rect.y);
                    }
                    try ShutdownFrame.expectStable(controls);
                    const information = (try dvui.testing.tagGet("shutdown-information")).rect;
                    try std.testing.expect(information.y + information.h <= controls[0].rect.y + 0.1);
                    // Scrolling overflowing text must never move or clip an action.
                    try dvui.testing.moveTo("shutdown-information");
                    _ = try window.window.addEventMouseWheel(-100000, .vertical, null);
                    try dvui.testing.settle(ShutdownFrame.draw);
                    try ShutdownFrame.expectStable(controls);
                    window.window.focusSubwindow(controls[0].window_id, null);
                    window.window.focusWidget(controls[0].id, controls[0].window_id, null);
                    try dvui.testing.settle(ShutdownFrame.draw);
                    try std.testing.expectEqual(controls[0].id, dvui.focusedWidgetId().?);
                    var visited: [ShutdownFrame.labels.len]bool = @splat(false);
                    visited[0] = true;
                    const tab_steps = window.window.tab_index_prev.items.len + 1;
                    for (0..tab_steps) |_| {
                        try dvui.testing.pressKey(.tab, .none);
                        try dvui.testing.settle(ShutdownFrame.draw);
                        const focused = dvui.focusedWidgetId();
                        for (controls, 0..) |control, slot| if (focused == control.id) {
                            visited[slot] = true;
                        };
                        try ShutdownFrame.expectStable(controls);
                    }
                    for (visited) |seen| try std.testing.expect(seen);
                    // Activate every real choice with both native input paths.
                    const target = try ShutdownFrame.visibleControl(index);
                    if (keyboard) {
                        window.window.focusWidget(target.id, target.window_id, null);
                        try dvui.testing.settle(ShutdownFrame.draw);
                        try std.testing.expectEqual(target.id, dvui.focusedWidgetId().?);
                        try dvui.testing.pressKey(.enter, .none);
                    } else {
                        _ = try window.window.addEventMouseMotion(.{ .pt = target.rect.center() });
                        try dvui.testing.click(.left);
                    }
                    try dvui.testing.settle(ShutdownFrame.draw);
                    try std.testing.expectEqual(choice, ShutdownFrame.selected.?);
                }
            }
        }
    }
}

const JavaDeleteFrame = struct {
    const Action = enum { forget, delete_files, cancel };
    const labels = [_][]const u8{ "仅移除条目", "删除 Java 文件", "取消" };
    const Control = struct { id: dvui.Id, window_id: dvui.Id, rect: dvui.Rect.Physical };
    const Observation = struct { rect: dvui.Rect.Physical, clip: dvui.Rect.Physical, control: ?Control };
    var ui: *java_view.Ui = undefined;
    var observations: [labels.len]?Observation = @splat(null);

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
        observations = @splat(null);
        // Exercise the public floating-modal entry point without a Manager or worker.
        java_view.drawModal(ui);
        try observe(commands.items);
        // FloatingWindowWidget.initReset bypasses the outer deferred queue.
        // Inspect the actual subwindow queues that Window.end will render.
        for (win.subwindows.stack.items) |subwindow| {
            try observe(subwindow.render_cmds.items);
            try observe(subwindow.render_cmds_after.items);
        }
        return .ok;
    }

    fn observe(commands: []const dvui.RenderCommand) !void {
        const win = dvui.currentWindow();
        for (commands) |command| switch (command.cmd) {
            .text => |text| {
                for (labels, 0..) |label, index| if (std.mem.eql(u8, text.text, label)) {
                    var control: ?Control = null;
                    for (win.tab_index.items) |entry| {
                        const rect = entry.rect orelse continue;
                        if (JavaFrame.contains(rect, text.rs.r.center())) {
                            try std.testing.expect(control == null);
                            control = .{ .id = entry.widgetId, .window_id = entry.windowId, .rect = rect };
                        }
                    }
                    try std.testing.expect(observations[index] == null);
                    observations[index] = .{ .rect = text.rs.r, .clip = command.clip, .control = control };
                };
            },
            else => {},
        };
    }

    fn visibleControl(action: Action) !Control {
        const sample = observations[@intFromEnum(action)] orelse return error.JavaDeleteLabelNotRendered;
        const control = sample.control orelse return error.JavaDeleteControlNotRegistered;
        const win = dvui.currentWindow();
        const modal = win.subwindows.get(control.window_id) orelse return error.JavaDeleteModalMissing;
        try std.testing.expect(sample.rect.w > 0 and sample.rect.h > 0);
        try std.testing.expect(control.rect.w > 0 and control.rect.h > 0);
        try expectInside(dvui.windowRectPixels(), sample.rect);
        try expectInside(sample.clip, sample.rect);
        try expectInside(modal.rect_pixels, sample.rect);
        try expectInside(modal.rect_pixels, control.rect);
        try std.testing.expect(JavaFrame.contains(sample.clip, control.rect.center()));
        return control;
    }

    fn expectStable(controls: [labels.len]Control) !void {
        const win = dvui.currentWindow();
        for (controls, 0..) |previous, index| {
            const current = try visibleControl(@enumFromInt(index));
            try std.testing.expectEqual(previous.id, current.id);
            try std.testing.expectEqual(previous.window_id, current.window_id);
            var registered: usize = 0;
            for (win.tab_index_prev.items) |entry| {
                if (entry.widgetId == current.id and entry.windowId == current.window_id) registered += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), registered);
        }
        try std.testing.expect(java_view.hasModal(ui));
        try std.testing.expectEqual(@as(usize, 0), ui.commands.items.len);
    }

    fn click(action: Action) !void {
        // Check actual rendered visibility immediately before even the dangerous click.
        const control = try visibleControl(action);
        _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = control.rect.center() });
        try dvui.testing.click(.left);
        try dvui.testing.settle(draw);
    }
};

test "UI layout real Java deletion modal keeps all actions visible focusable and queues owned paths" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    const a = std.testing.allocator;
    const paths = [_][]const u8{
        "/fixture/managed-java/bin/java",
        "/fixture/managed-java/" ++ ("nested-runtime-directory-with-a-long-name/" ** 16) ++ "bin/java",
    };
    for ([_]dvui.Size{ .{ .w = 640, .h = 400 }, .{ .w = 1280, .h = 720 } }) |size| {
        for (paths) |path| {
            for ([_]JavaDeleteFrame.Action{ .cancel, .forget, .delete_files }) |action| {
                var ui = java_view.Ui.init(a);
                defer ui.deinit();
                JavaDeleteFrame.ui = &ui;
                // The UI owns its confirmation copy independently of the caller's buffer.
                const source = try a.dupe(u8, path);
                defer a.free(source);
                ui.delete_confirmation = try a.dupe(u8, source);
                @memset(source, '?');
                const confirmation_address = @intFromPtr(ui.delete_confirmation.?.ptr);
                var window = try dvui.testing.init(.{ .window_size = size });
                defer window.deinit();
                window.backend.size_pixels = .{ .w = size.w, .h = size.h };
                var theme = dvui.Theme.builtin.adwaita_dark;
                theme.font_body = theme.font_body.withSize(16);
                window.window.themeSet(theme);
                try dvui.testing.settle(JavaDeleteFrame.draw);
                var controls: [JavaDeleteFrame.labels.len]JavaDeleteFrame.Control = undefined;
                for (&controls, 0..) |*control, index| {
                    control.* = try JavaDeleteFrame.visibleControl(@enumFromInt(index));
                    for (controls[0..index]) |previous| try std.testing.expect(previous.id != control.id);
                }
                try JavaDeleteFrame.expectStable(controls);
                try std.testing.expectEqualStrings(path, ui.delete_confirmation.?);
                // Native Tab must visit each actual action ID without triggering an action.
                window.window.focusSubwindow(controls[0].window_id, null);
                window.window.focusWidget(controls[0].id, controls[0].window_id, null);
                try dvui.testing.settle(JavaDeleteFrame.draw);
                try std.testing.expectEqual(controls[0].id, dvui.focusedWidgetId().?);
                var visited: [JavaDeleteFrame.labels.len]bool = @splat(false);
                visited[0] = true;
                const tab_steps = window.window.tab_index_prev.items.len + 1;
                for (0..tab_steps) |_| {
                    try dvui.testing.pressKey(.tab, .none);
                    try dvui.testing.settle(JavaDeleteFrame.draw);
                    // DVUI intentionally visits null focus between the last and first tab stop.
                    const focused = dvui.focusedWidgetId();
                    for (controls, 0..) |control, index| {
                        if (focused == control.id) visited[index] = true;
                    }
                    try JavaDeleteFrame.expectStable(controls);
                    try std.testing.expectEqualStrings(path, ui.delete_confirmation.?);
                }
                for (visited) |seen| try std.testing.expect(seen);
                try JavaDeleteFrame.click(action);
                try std.testing.expect(!java_view.hasModal(&ui));
                try std.testing.expect(ui.delete_confirmation == null and ui.failure == null);
                for (JavaDeleteFrame.observations) |sample| try std.testing.expect(sample == null);
                if (action == .cancel) {
                    try std.testing.expectEqual(@as(usize, 0), ui.commands.items.len);
                } else {
                    try std.testing.expectEqual(@as(usize, 1), ui.commands.items.len);
                    const queued = ui.commands.items[0];
                    const owned_path = switch (action) {
                        .forget => blk: {
                            try std.testing.expect(queued == .forget);
                            break :blk queued.forget;
                        },
                        .delete_files => blk: {
                            try std.testing.expect(queued == .delete_files);
                            break :blk queued.delete_files;
                        },
                        .cancel => unreachable,
                    };
                    try std.testing.expectEqualStrings(path, owned_path);
                    try std.testing.expect(@intFromPtr(owned_path.ptr) != confirmation_address);
                    try std.testing.expect(owned_path.ptr != source.ptr);
                    // Another real frame must preserve the owned queued path after closure.
                    try dvui.testing.settle(JavaDeleteFrame.draw);
                    try std.testing.expectEqual(@as(usize, 1), ui.commands.items.len);
                    try std.testing.expectEqualStrings(path, owned_path);
                }
                // Ui.deinit releases queued commands; never finish/tick or touch Java files.
            }
        }
    }
}

const RenderedTextBounds = struct {
    rect: dvui.Rect.Physical,
    clip: dvui.Rect.Physical,
    font_height: f32,
};

fn observeTextBounds(commands: []const dvui.RenderCommand, samples: []const []const u8, bounds: []?RenderedTextBounds) void {
    @memset(bounds, null);
    // Copy numerical bounds while commands and their borrowed text are alive.
    for (commands) |command| switch (command.cmd) {
        .text => |text| {
            for (samples, 0..) |sample, index| if (std.mem.eql(u8, text.text, sample)) {
                bounds[index] = .{ .rect = text.rs.r, .clip = command.clip, .font_height = text.font.textHeight() * text.rs.s };
            };
        },
        else => {},
    };
}

const EditorTextFrame = struct {
    var server = true;
    var samples: [3][]const u8 = undefined;
    var bounds: [3]?RenderedTextBounds = @splat(null);

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
                instances_view.draw(EditorsFrame.instance_ui, EditorsFrame.store, EditorsFrame.instance_service, .{ .installed = &.{}, .available = &.{}, .phase = .idle, .failure = null, .completed = 0, .total = 0, .installing_version = null }, &.{});
            }
        }
        // Observe real text-layout render commands and their effective scissor,
        // rather than reconstructing field geometry or testing an outer box.
        observeTextBounds(commands.items, &samples, &bounds);
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
    instance_ui.draft = try instances_view.Draft.fromInstance(a, .{ .id = "fixture-font-instance", .name = "Fixture", .minecraft_version = "1.21" });
    instance_ui.mode = .options;
    const samples = [_][]const u8{ "Server gypQ", "gypQ.invalid", "25565", "Instance gypQ", "4096" };
    const buffers = [_][]u8{ &server_ui.draft.name, &server_ui.draft.address, &server_ui.draft.port, &instance_ui.draft.name, &instance_ui.draft.memory };
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
                const field_count: usize = if (server) 3 else 2;
                EditorTextFrame.samples = @splat("");
                @memcpy(EditorTextFrame.samples[0..field_count], samples[offset..][0..field_count]);
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
                try std.testing.expectEqual(field_count, count);
                for (inputs[0..count], 0..) |id, index| {
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

const WorldsTextFrame = struct {
    const source: config.Instance = .{ .id = "fixture-world-font", .name = "Fixture", .minecraft_version = "1.21.4" };
    const recovery_id = "0123456789abcdef0123456789abcdef";
    const samples = [_][]const u8{
        "World gypQ",
        "文件夹：world-gypQ",
        "版本：1.21.4 gypQ",
        "最后游玩：2025-01-01 00:00 UTC",
        "recovery-gypQ · 原始数据",
        recovery_id ++ " · 2025-01-02 00:00 UTC",
        "世界备份",
    };
    var ui: *worlds_view.Ui = undefined;
    var manager: *worlds_manager.Manager = undefined;
    var document: *const config.Document = undefined;
    const TextFragments = struct {
        bytes: [128]u8 = undefined,
        length: usize = 0,
        fragments: [128]RenderedTextBounds = undefined,
        count: usize = 0,
    };
    var observed: [samples.len]TextFragments = @splat(.{});

    fn observeFragments(commands: []const dvui.RenderCommand) !void {
        observed = @splat(.{});
        var active: ?usize = null;
        for (commands) |command| switch (command.cmd) {
            .text => |text| {
                if (text.text.len == 0) continue;
                var matched: ?usize = null;
                if (active) |index| {
                    const remaining = samples[index][observed[index].length..];
                    if (std.mem.startsWith(u8, remaining, text.text)) matched = index else active = null;
                }
                if (matched == null) {
                    for (samples, 0..) |sample, index| {
                        if (observed[index].length == 0 and std.mem.startsWith(u8, sample, text.text)) {
                            matched = index;
                            break;
                        }
                    }
                }
                if (matched) |index| {
                    const capture = &observed[index];
                    if (capture.length + text.text.len > capture.bytes.len or capture.count == capture.fragments.len) return error.WorldTextCaptureOverflow;
                    // DVUI wraps at si + 1 and renders txt[0..end], retaining
                    // the wrap-point space. Preserve every byte, including the
                    // separator and leading/trailing spaces; never normalize it.
                    @memcpy(capture.bytes[capture.length..][0..text.text.len], text.text);
                    capture.length += text.text.len;
                    capture.fragments[capture.count] = .{ .rect = text.rs.r, .clip = command.clip, .font_height = text.font.textHeight() * text.rs.s };
                    capture.count += 1;
                    active = if (capture.length == samples[index].len) null else index;
                }
            },
            else => {},
        };
    }

    fn ownedWorld(a: std.mem.Allocator, folder: []const u8, name: []const u8) !worlds.World {
        const owned_folder = try a.dupe(u8, folder);
        errdefer a.free(owned_folder);
        const directory = try a.dupe(u8, "/unused/world-renderer-fixture");
        errdefer a.free(directory);
        const level_name = try a.dupe(u8, name);
        errdefer a.free(level_name);
        const version = try a.dupe(u8, "1.21.4 gypQ");
        return .{
            .folder = owned_folder,
            .directory = directory,
            .metadata = .{ .level_name = level_name, .version_name = version },
            .metadata_status = .valid,
            .modified_ms = 0,
        };
    }

    fn ownedBackup(a: std.mem.Allocator) !worlds.Backup {
        const id = try a.dupe(u8, recovery_id);
        errdefer a.free(id);
        const directory = try a.dupe(u8, "/unused/recovery-renderer-fixture");
        errdefer a.free(directory);
        const folder = try a.dupe(u8, "recovery-gypQ");
        return .{ .id = id, .part = .original, .directory = directory, .source_folder = folder, .operation = .backup, .created_ms = 1735776000000 };
    }

    fn work(a: std.mem.Allocator, io: std.Io, _: *const instances.Paths, instance: config.Instance, request: ?worlds_manager.Request, options: worlds.Options) anyerror!worlds_manager.Result {
        if (request != null or !std.mem.eql(u8, instance.id, source.id)) return error.UnexpectedWorldRendererRequest;
        try options.hooks.check(io);
        const held = options.held_scope orelse return error.MissingWorldScope;
        try held.recheck();
        const items = try a.alloc(worlds.World, 2);
        errdefer a.free(items);
        items[0] = try ownedWorld(a, "world-gypQ", "World gypQ");
        errdefer items[0].deinit(a);
        items[0].metadata.last_played_ms = 1735689600000;
        // Another real row makes recovery require scrolling at the compact size.
        items[1] = try ownedWorld(a, "filler", "Filler");
        errdefer items[1].deinit(a);
        // Keep every observed label unique, including version and timestamp.
        a.free(items[1].metadata.version_name.?);
        items[1].metadata.version_name = null;
        const backups = try a.alloc(worlds.Backup, 1);
        errdefer a.free(backups);
        backups[0] = try ownedBackup(a);
        return .{
            .world_list = .{ .allocator = a, .items = items },
            .backup_list = .{ .allocator = a, .items = backups },
        };
    }

    fn publish(service: *worlds_manager.Manager) !void {
        try service.select(source);
        for (0..5000) |_| {
            service.tick();
            if (!service.snapshot().worker_active) return;
            try service.io.sleep(.fromMilliseconds(1), .awake);
        }
        return error.WorldRendererWorkerTimedOut;
    }

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
        {
            const root = dvui.box(@src(), .{}, .{ .tag = "world-font-page", .expand = .both, .padding = dvui.Rect.all(12) });
            defer root.deinit();
            // Publication stays immutable through rendering; no finish/tick here.
            try worlds_view.drawWithEnabled(ui, document, manager, true);
        }
        try observeFragments(commands.items);
        return .ok;
    }

    fn scrollPage(amount: f32) !void {
        const page = try dvui.testing.tagGet("world-font-page");
        // The lower center lies in the production scroll area, below its header.
        _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = .{ .x = page.rect.center().x, .y = page.rect.y + page.rect.h - 24 } });
        _ = try dvui.currentWindow().addEventMouseWheel(amount, .vertical, null);
        try dvui.testing.settle(draw);
    }

    fn expectLines(start: usize, end: usize, size: dvui.Size, font_size: f32) !void {
        for (start..end) |index| {
            const capture = &observed[index];
            errdefer std.debug.print("World/recovery text incomplete: size={any}, font={d}, label={s}, rendered={s}, fragments={d}\n", .{ size, font_size, samples[index], capture.bytes[0..capture.length], capture.count });
            // Exact concatenation in command order requires every chunk. A
            // missing, reordered or altered chunk (including spaces) fails.
            try std.testing.expect(capture.count > 0);
            try std.testing.expectEqualStrings(samples[index], capture.bytes[0..capture.length]);
            for (capture.fragments[0..capture.count], 0..) |text, fragment| {
                errdefer std.debug.print("World/recovery fragment clipped: label={s}, fragment={d}, bounds={any}\n", .{ samples[index], fragment, text });
                try std.testing.expect(text.rect.w > 0 and text.rect.h > 0);
                try std.testing.expect(text.rect.h >= text.font_height - 0.01);
                try expectInside(text.clip, text.rect);
                try expectInside(.{ .x = 0, .y = 0, .w = size.w, .h = size.h }, text.rect);
                if (font_size == 24) try std.testing.expect(text.font_height > 20);
                if (fragment > 0) {
                    const previous = capture.fragments[fragment - 1].rect;
                    try std.testing.expect(text.rect.y >= previous.y + previous.h - 0.1);
                }
            }
        }
    }
};

test "UI layout real World and recovery metadata font lines are not clipped at compact and wide sizes" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, std.testing.io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var coordinator = instance_leases.Coordinator.init(std.testing.io);
    var manager = try worlds_manager.Manager.initOptions(a, std.testing.io, &paths, &registry, .{ .scope = coordinator.worldScope(3), .worker = WorldsTextFrame.work });
    defer manager.deinit();
    var ui = try worlds_view.Ui.init(a);
    defer ui.deinit();
    const document: config.Document = .{ .instances = &.{WorldsTextFrame.source}, .selected_instance = WorldsTextFrame.source.id };
    WorldsTextFrame.ui = &ui;
    WorldsTextFrame.manager = &manager;
    WorldsTextFrame.document = &document;
    // Exercise real worker JOIN/publication before any frame borrows list strings.
    try WorldsTextFrame.publish(&manager);
    const snapshot = manager.snapshot();
    try std.testing.expect(snapshot.failure == null and !snapshot.loading and !snapshot.worker_active);
    try std.testing.expectEqual(@as(usize, 2), snapshot.worlds.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.backups.len);
    for ([_]dvui.Size{ .{ .w = 640, .h = 400 }, .{ .w = 1280, .h = 720 } }) |size| {
        for ([_]f32{ 16, 24 }) |font_size| {
            var window = try dvui.testing.init(.{ .window_size = size });
            defer window.deinit();
            window.backend.size_pixels = .{ .w = size.w, .h = size.h };
            var theme = dvui.themeGet();
            theme.font_body = theme.font_body.withSize(font_size);
            theme.font_heading = theme.font_body.withSize(18);
            theme.font_title = theme.font_body.withSize(24);
            window.window.themeSet(theme);
            try dvui.testing.settle(WorldsTextFrame.draw);
            try WorldsTextFrame.scrollPage(100000);
            try WorldsTextFrame.expectLines(0, 4, size, font_size);
            const top_y = WorldsTextFrame.observed[0].fragments[0].rect.y;
            try WorldsTextFrame.scrollPage(-100000);
            try WorldsTextFrame.expectLines(4, WorldsTextFrame.samples.len, size, font_size);
            if (size.h == 400 and font_size == 24) {
                // The full recovery ID plus date must exercise actual wrapping.
                try std.testing.expect(WorldsTextFrame.observed[5].count > 1);
            }
            if (size.h == 400) {
                // The title must move up or be culled after leaving the viewport.
                const first = &WorldsTextFrame.observed[0];
                try std.testing.expect(first.count == 0 or first.fragments[0].rect.y < top_y - 1);
            }
            try WorldsTextFrame.scrollPage(100000);
            try WorldsTextFrame.expectLines(0, 4, size, font_size);
            try std.testing.expect(ui.failure == null and ui.draft == null);
            try std.testing.expect(ui.requests.items.len == 0 and ui.directory_open == null);
            try std.testing.expect(!ui.refresh_queued and !ui.cancel_queued and !ui.select_queued);
            try std.testing.expect(!manager.snapshot().worker_active);
            try std.testing.expectEqual(@as(usize, 0), registry.entries.items.len);
        }
    }
}

const AccountEditorFrame = struct {
    const validation_text = "名称须为 3–16 位字母、数字或下划线";
    const Footer = struct { id: dvui.Id, parent_id: dvui.Id, window_id: dvui.Id, label_id: dvui.Id, rect: dvui.Rect.Physical, text: dvui.Rect.Physical, clip: dvui.Rect.Physical };
    var ui: *accounts_view.Ui = undefined;
    var store: *config.Store = undefined;
    var manager: *accounts_manager.Manager = undefined;
    var footers: [2]?Footer = @splat(null);
    var validation_bytes: [128]u8 = undefined;
    var validation_length: usize = 0;
    var validation_fragments: [16]RenderedTextBounds = undefined;
    var validation_count: usize = 0;

    fn draw() !dvui.App.Result {
        const win = dvui.currentWindow();
        var commands: std.ArrayList(dvui.RenderCommand) = .empty;
        defer commands.deinit(win.arena());
        const previous_commands = win.defer_render_cmds;
        const previous_rendering = win.render_target.rendering;
        win.defer_render_cmds = &commands;
        win.render_target.rendering = false;
        dvui.debug.captureScopeBegin(win.gpa);
        defer {
            dvui.debug.captureScopeEnd();
            win.defer_render_cmds = previous_commands;
            win.render_target.rendering = previous_rendering;
        }
        footers = @splat(null);
        validation_length = 0;
        validation_count = 0;
        {
            const root = dvui.box(@src(), .{}, .{ .expand = .both, .padding = dvui.Rect.all(12) });
            defer root.deinit();
            accounts_view.draw(ui, store, manager);
        }
        const capture = dvui.debug.lastCapture() orelse return error.AccountEditorCaptureMissing;
        var floating: ?dvui.Debug.CapturedWidget = null;
        for (capture.widgets.items) |widget| {
            if (!std.mem.eql(u8, widget.name orelse continue, "FloatingWindow") or
                !std.mem.eql(u8, widget.src_fn, "drawEditor") or
                !std.mem.endsWith(u8, widget.src_file, "accounts_view.zig")) continue;
            try uniqueWidget(&floating, widget);
        }
        const modal_id = (floating orelse return error.AccountEditorModalMissing).id;
        const modal = win.subwindows.get(modal_id) orelse return error.AccountEditorModalMissing;
        try std.testing.expect(modal.modal and modal.used);
        var footer: ?dvui.Debug.CapturedWidget = null;
        for (capture.widgets.items) |widget| {
            if (widget.subwindow_id != modal_id or
                !std.mem.eql(u8, widget.name orelse continue, "Box") or
                !std.mem.eql(u8, widget.src_fn, "drawEditor") or
                !std.mem.endsWith(u8, widget.src_file, "accounts_view.zig")) continue;
            try uniqueWidget(&footer, widget);
        }
        const footer_id = (footer orelse return error.AccountEditorFooterContainerMissing).id;
        var buttons: [2]?dvui.Debug.CapturedWidget = @splat(null);
        for (capture.widgets.items) |widget| {
            if (widget.subwindow_id != modal_id or widget.parent_id != footer_id or
                !std.mem.eql(u8, widget.name orelse continue, "Button") or
                !std.mem.eql(u8, widget.src_fn, "formActions") or
                !std.mem.endsWith(u8, widget.src_file, "components.zig")) continue;
            const index: usize = switch (widget.style) {
                .control => 0,
                .highlight => 1,
                else => return error.AccountEditorFooterStyleUnexpected,
            };
            try uniqueWidget(&buttons[index], widget);
        }
        const controls: [2]dvui.Debug.CapturedWidget = .{
            buttons[0] orelse return error.AccountEditorCancelMissing,
            buttons[1] orelse return error.AccountEditorSaveMissing,
        };
        // Inspect only the identified account modal, never overlapping base widgets.
        try observe(modal.render_cmds.items, modal_id, controls);
        try observe(modal.render_cmds_after.items, modal_id, controls);
        return .ok;
    }

    fn uniqueWidget(found: *?dvui.Debug.CapturedWidget, widget: dvui.Debug.CapturedWidget) !void {
        if (found.*) |previous| {
            // Repeated capture is valid only for the same widget and geometry.
            try std.testing.expectEqual(previous.id, widget.id);
            try std.testing.expectEqual(previous.parent_id, widget.parent_id);
            try std.testing.expectEqual(previous.subwindow_id, widget.subwindow_id);
            try std.testing.expectEqual(previous.rect_border, widget.rect_border);
            try std.testing.expectEqual(previous.rect_content, widget.rect_content);
        } else found.* = widget;
    }

    fn observe(commands: []const dvui.RenderCommand, modal_id: dvui.Id, controls: [2]dvui.Debug.CapturedWidget) !void {
        const capture = dvui.debug.lastCapture() orelse return error.AccountEditorCaptureMissing;
        for (commands) |command| switch (command.cmd) {
            .text => |text| {
                if (text.text.len == 0) continue;
                const remaining = validation_text[validation_length..];
                if (std.mem.startsWith(u8, remaining, text.text)) {
                    if (validation_count == validation_fragments.len) return error.AccountValidationCaptureOverflow;
                    @memcpy(validation_bytes[validation_length..][0..text.text.len], text.text);
                    validation_length += text.text.len;
                    validation_fragments[validation_count] = .{ .rect = text.rs.r, .clip = command.clip, .font_height = text.font.textHeight() * text.rs.s };
                    validation_count += 1;
                }
                for (FormFrame.labels, 0..) |label, index| if (std.mem.eql(u8, text.text, label)) {
                    const widget = controls[index];
                    var owned_label: ?dvui.Debug.CapturedWidget = null;
                    for (capture.widgets.items) |child| {
                        if (child.subwindow_id != modal_id or child.parent_id != widget.id or
                            !std.mem.eql(u8, child.name orelse continue, "Label") or
                            !std.mem.eql(u8, child.src_fn, "formButton") or
                            !std.mem.endsWith(u8, child.src_file, "components.zig") or
                            !JavaFrame.contains(child.rect_content, text.rs.r.center())) continue;
                        try uniqueWidget(&owned_label, child);
                    }
                    const label_widget = owned_label orelse return error.AccountEditorFooterLabelOwnershipMissing;
                    const observed: Footer = .{ .id = widget.id, .parent_id = widget.parent_id, .window_id = modal_id, .label_id = label_widget.id, .rect = widget.rect_border, .text = text.rs.r, .clip = command.clip };
                    if (footers[index]) |previous| {
                        // Do not hide a different button, label, bounds or scissor.
                        try std.testing.expectEqual(previous, observed);
                    } else footers[index] = observed;
                };
            },
            else => {},
        };
    }

    fn visibleFooter(index: usize) !Footer {
        const footer = footers[index] orelse return error.AccountEditorFooterMissing;
        const modal = dvui.currentWindow().subwindows.get(footer.window_id) orelse return error.AccountEditorModalMissing;
        // endFrame resets used; draw already verified live modal ownership.
        try std.testing.expect(modal.modal);
        try expectInside(modal.rect_pixels, footer.rect);
        try expectInside(dvui.windowRectPixels(), footer.rect);
        try expectInside(footer.rect, footer.text);
        try expectInside(footer.clip, footer.text);
        var registered: usize = 0;
        for (dvui.currentWindow().tab_index_prev.items) |entry| if (entry.widgetId == footer.id and entry.windowId == footer.window_id) {
            registered += 1;
        };
        // Invalid names retain a reachable Cancel and a disabled Save.
        try std.testing.expectEqual(@as(usize, if (index == 0) 1 else 0), registered);
        return footer;
    }

    fn expectValidation() !void {
        try std.testing.expect(validation_count > 0);
        try std.testing.expectEqualStrings(validation_text, validation_bytes[0..validation_length]);
        for (validation_fragments[0..validation_count]) |fragment| {
            try std.testing.expect(fragment.rect.h >= fragment.font_height - 0.01);
            try expectInside(fragment.clip, fragment.rect);
            try expectInside(dvui.windowRectPixels(), fragment.rect);
        }
    }

    fn click(index: usize) !void {
        const footer = try visibleFooter(index);
        _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = footer.rect.center() });
        try dvui.testing.click(.left);
        try dvui.testing.settle(draw);
    }
};

test "UI layout real account editor keeps full validation and footer visible with native draft cancellation" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    var manager = try accounts_manager.Manager.init(a, std.testing.io, root);
    defer manager.deinit();
    var ui = try accounts_view.Ui.init(a);
    defer ui.deinit();
    AccountEditorFrame.ui = &ui;
    AccountEditorFrame.store = &store;
    AccountEditorFrame.manager = &manager;
    const invalid_name = "WorldDraftAlpha42";
    for ([_]dvui.Size{ .{ .w = 1280, .h = 720 }, .{ .w = 640, .h = 400 }, .{ .w = 640, .h = 260 } }) |size| {
        for ([_]f32{ 16, 24 }) |font_size| {
            var window = try dvui.testing.init(.{ .window_size = size });
            defer window.deinit();
            window.backend.size_pixels = .{ .w = size.w, .h = size.h };
            var theme = dvui.themeGet();
            theme.font_body = theme.font_body.withSize(font_size);
            theme.font_heading = theme.font_body.withSize(18);
            theme.font_title = theme.font_body.withSize(24);
            window.window.themeSet(theme);
            ui.editor_open = true;
            @memset(&ui.draft.name, 0);
            @memcpy(ui.draft.name[0..invalid_name.len], invalid_name);
            try dvui.testing.settle(AccountEditorFrame.draw);
            const cancel = try AccountEditorFrame.visibleFooter(0);
            const save = try AccountEditorFrame.visibleFooter(1);
            if (size.h >= 400) try AccountEditorFrame.expectValidation();
            _ = try window.window.addEventMouseMotion(.{ .pt = .{ .x = size.w / 2, .y = size.h / 2 } });
            _ = try window.window.addEventMouseWheel(-100000, .vertical, null);
            try dvui.testing.settle(AccountEditorFrame.draw);
            try AccountEditorFrame.expectValidation();
            try std.testing.expectEqual(cancel.rect, (try AccountEditorFrame.visibleFooter(0)).rect);
            try std.testing.expectEqual(save.rect, (try AccountEditorFrame.visibleFooter(1)).rect);
            try AccountEditorFrame.click(1);
            try std.testing.expect(ui.pending == null and ui.editor_open);
            try AccountEditorFrame.click(0);
            try std.testing.expect(ui.pending != null and ui.editor_open);
            accounts_view.finish(&ui, &store, &manager);
            try std.testing.expect(ui.pending == null and !ui.editor_open and ui.failure == null);
            try std.testing.expectEqual(@as(usize, 0), store.snapshot().accounts.len);
            try std.testing.expect(store.snapshot().selected_account == null);
            try std.testing.expect(!manager.snapshot().busy);
        }
    }
}

test "UI layout first Content visit preserves the real pack review handoff" {
    if (comptime dvui.Backend.kind != .testing) return error.SkipZigTest;
    try @import("gui_acceptance.zig").testFirstContentReviewHandoff();
}

test "UI layout pack content hold allows first navigation and normal cancellation" {
    if (comptime dvui.Backend.kind != .testing) return error.SkipZigTest;
    try @import("gui_acceptance.zig").testPackContentHoldFirstNavigation();
}

const ContentManualFrame = struct {
    const content = @import("ui/content_manager.zig");
    const modal_view = @import("ui/content_view.zig");
    const labels = [_][]const u8{
        "Included archive file · source verified",
        "Included archive file · source needs verification",
        "Local source verified",
        "missing_url",
        "distribution_disabled",
        "Official download page",
        "/tmp/source.jar",
    };
    var ui: *modal_view.Ui = undefined;
    var service: *content.Manager = undefined;
    var document: *const config.Document = undefined;
    var seen: [labels.len]bool = @splat(false);

    fn rejectPicker(_: ?*anyopaque, _: std.mem.Allocator, _: modal_view.PickerKind) anyerror!?[:0]const u8 {
        return error.UnexpectedPicker;
    }
    fn rejectLease(_: ?*anyopaque, _: []const u8) anyerror!void {
        return error.UnexpectedLease;
    }
    fn releaseLease(_: ?*anyopaque, _: []const u8) void {
        unreachable;
    }
    fn observe(commands: []const dvui.RenderCommand) void {
        for (commands) |command| switch (command.cmd) {
            .text => |text| {
                for (labels, 0..) |label, index| {
                    if (std.mem.indexOf(u8, text.text, label) != null) seen[index] = true;
                }
            },
            else => {},
        };
    }
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
        seen = @splat(false);
        try modal_view.drawModal(ui, document, service);
        observe(commands.items);
        for (win.subwindows.stack.items) |subwindow| {
            observe(subwindow.render_cmds.items);
            observe(subwindow.render_cmds_after.items);
        }
        return .ok;
    }
};

test "UI layout content manual rows render archive and checked sources without remote fallback" {
    if (comptime dvui.Backend.kind != .testing) return error.SkipZigTest;
    const content = @import("ui/content_manager.zig");
    const modal_view = @import("ui/content_view.zig");
    const manifest = @import("core/content_manifest.zig");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var service = try content.Manager.init(a, io, &paths, &registry, .{ .context = null, .acquire = ContentManualFrame.rejectLease, .recheck = ContentManualFrame.rejectLease, .release = ContentManualFrame.releaseLease });
    defer service.deinit();
    const source: config.Instance = .{ .id = "fixture-content", .name = "Fixture", .minecraft_version = "1.21" };
    const document: config.Document = .{ .instances = &.{source}, .selected_instance = source.id };
    // Set an owned selection without starting the manager's local snapshot worker.
    const Selection = @typeInfo(@typeInfo(@TypeOf(service.selected)).optional.child).pointer.child;
    service.selected = try a.create(Selection);
    service.selected.?.* = .{ .arena = .init(a), .instance = source };
    ContentManualFrame.service = &service;
    ContentManualFrame.document = &document;
    for (0..10) |scenario| {
        const archive = scenario < 2;
        const checked = scenario == 0 or scenario == 4 or scenario == 8 or scenario == 9;
        var file: manifest.InstallFile = .{ .record = .{ .path = if (archive) "config/fixture-pack.cfg" else "mods/manual.jar", .provider = if (archive) .modrinth else .curseforge, .project_id = "12", .version_id = "34", .hashes = .{}, .identity_provenance = if (archive) .pack_override else .official_file, .role = if (archive or scenario == 7) .override else .content }, .download = .{ .manual_required = .{ .official_page = if (archive or scenario == 6 or scenario == 7) "" else "https://www.curseforge.com/minecraft/mc-mods/example/files/34", .reason = if (scenario == 3) .distribution_disabled else .missing_url } } };
        if (scenario == 5) {
            file.required = false;
            file.selected = true;
        }
        const status: content.ManualSourceStatus = .{ .path = file.record.path, .source_absolute_path = "/tmp/source.jar", .verified = true };
        const proposal: content.Proposal = .{ .files = &.{file}, .plan = .{ .actions = &.{}, .conflicts = &.{}, .next_manifest = .{ .instance_id = source.id, .pack_version = "v1" }, .ready = checked, .fully_applied = checked }, .manual_source_status = if (checked) &.{status} else &.{} };
        var ui = try modal_view.Ui.initOptions(a, .{ .picker_runner = .{ .pick = ContentManualFrame.rejectPicker } });
        defer ui.deinit();
        ui.draft = .{ .arena = .init(a), .source = source, .proposal = proposal, .candidates = &.{}, .issues = &.{}, .manual = &.{} };
        const aa = ui.draft.?.arena.allocator();
        const Manual = @typeInfo(@TypeOf(ui.draft.?.manual)).pointer.child;
        ui.draft.?.manual = try aa.alloc(Manual, 1);
        ui.draft.?.manual[0] = .{ .path = file.record.path, .source_dirty = scenario == 8 };
        const source_path = "/tmp/source.jar";
        @memcpy(ui.draft.?.manual[0].absolute[0..source_path.len], source_path);
        ui.draft.?.dirty = scenario == 9;
        if (scenario == 5) try ui.draft.?.optional.append(aa, .{ .path = file.record.path, .include = false });
        ContentManualFrame.ui = &ui;
        var window = try dvui.testing.init(.{ .window_size = .{ .w = 1200, .h = 1000 } });
        defer window.deinit();
        window.backend.size_pixels = .{ .w = 1200, .h = 1000 };
        try dvui.testing.settle(ContentManualFrame.draw);
        const seen = ContentManualFrame.seen;
        std.debug.print("manual scenario {d}: labels={any}\n", .{ scenario, seen });
        const external_required = !archive and scenario != 4 and scenario != 5 and scenario != 9;
        try std.testing.expectEqual(scenario == 0, seen[0]);
        try std.testing.expectEqual(scenario == 1, seen[1]);
        try std.testing.expectEqual(scenario == 4 or scenario == 9, seen[2]);
        try std.testing.expectEqual(external_required and scenario != 3, seen[3]);
        try std.testing.expectEqual(scenario == 3, seen[4]);
        try std.testing.expectEqual(external_required and scenario != 6 and scenario != 7, seen[5]);
        try std.testing.expectEqual(external_required, seen[6]);
        var local_inputs: usize = 0;
        for (window.window.tab_index_prev.items) |entry| {
            if (dvui.dataGet(null, entry.widgetId, "_edited_outside", bool) != null) local_inputs += 1;
        }
        try std.testing.expectEqual(@as(usize, if (external_required) 1 else 0), local_inputs);
        try std.testing.expect(ui.picker == null and ui.pending == null);
        try std.testing.expectEqual(@as(usize, 0), registry.tasks().len);
    }
}

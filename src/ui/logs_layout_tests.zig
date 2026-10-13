const std = @import("std");
const dvui = @import("dvui");
const logs_view = @import("logs_view.zig");
const game_launch = @import("game_launch.zig");
const tools = @import("tools_view.zig");
const model = @import("model.zig");
const theme = @import("theme.zig");

const Text = struct { value: []const u8, rect: dvui.Rect.Physical, clip: dvui.Rect.Physical };
const Icon = struct { tag: []const u8, name: []const u8 };
const icons = [_]Icon{
    .{ .tag = "logs-search-prev", .name = "上一个匹配" },
    .{ .tag = "logs-search-next", .name = "下一个匹配" },
    .{ .tag = "logs-jump-latest", .name = "跳转到最新日志" },
    .{ .tag = "logs-copy-line", .name = "复制选中日志" },
    .{ .tag = "logs-copy-output", .name = "复制保留日志" },
    .{ .tag = "logs-clear-output", .name = "清空保留日志" },
    .{ .tag = "logs-stop-game", .name = "停止游戏" },
};

fn inside(outer: dvui.Rect.Physical, inner: dvui.Rect.Physical) bool {
    return inner.x >= outer.x - 0.5 and inner.y >= outer.y - 0.5 and inner.x + inner.w <= outer.x + outer.w + 0.5 and inner.y + inner.h <= outer.y + outer.h + 0.5;
}

fn overlaps(a: dvui.Rect.Physical, b: dvui.Rect.Physical) bool {
    return @min(a.x + a.w, b.x + b.w) > @max(a.x, b.x) + 0.5 and @min(a.y + a.h, b.y + b.h) > @max(a.y, b.y) + 0.5;
}

// A real DVUI frame with production pane spacing. Only the launch controller is
// synthetic: it owns an in-memory buffer and never starts a child or reads a game.
const Frame = struct {
    var controller: *game_launch.Controller = undefined;
    var view: logs_view.View = .{};
    var more = false;
    var sidebar_width: f32 = 276;
    var returned_home = false;
    var arena: ?std.heap.ArenaAllocator = null;
    var texts: []const Text = &.{};
    var meshes: []const dvui.Rect.Physical = &.{};
    var accessible_name: ?[]const u8 = null;

    fn resetCapture() void {
        if (arena) |*previous| previous.deinit();
        arena = null;
        texts = &.{};
        meshes = &.{};
    }

    fn draw() !dvui.App.Result {
        resetCapture();
        returned_home = false;
        const win = dvui.currentWindow();
        dvui.debug.captureScopeBegin(win.gpa);
        defer dvui.debug.captureScopeEnd();
        var commands: std.ArrayList(dvui.RenderCommand) = .empty;
        const previous_commands = win.defer_render_cmds;
        const previous_after = win.defer_render_cmds_after;
        const previous_rendering = win.render_target.rendering;
        win.defer_render_cmds = &commands;
        win.defer_render_cmds_after = &commands;
        win.render_target.rendering = false;
        defer {
            win.defer_render_cmds = previous_commands;
            win.defer_render_cmds_after = previous_after;
            win.render_target.rendering = previous_rendering;
            commands.deinit(win.arena());
        }
        {
            const available = @max(1, dvui.windowRect().w - 8);
            var split = @import("view.zig").boundedLogsSidebarWidth(sidebar_width, available) / available;
            const panes = dvui.paned(@src(), .{ .direction = .horizontal, .collapsed_size = 0, .split_ratio = &split, .handle_size = 8 }, .{ .expand = .both, .padding = .all(0), .margin = .all(0) });
            defer panes.deinit();
            if (panes.showFirst()) {
                const side = tools.beginUtilityMenu(if (more) "更多" else "游戏日志");
                defer side.deinit();
                dvui.tag("logs-test-sidebar", .{ .id = side.data().id, .rect = side.data().contentRectScale().r, .visible = true });
                if (!more) {
                    returned_home = view.drawNavigationFooter(controller);
                    try view.drawSidebar(controller);
                }
            }
            if (panes.showSecond()) {
                const pane = dvui.box(@src(), .{}, .{ .tag = "logs-test-main", .expand = .both, .padding = .all(theme.spacing.page_padding), .margin = .all(0) });
                defer pane.deinit();
                const clip = dvui.clip(pane.data().contentRectScale().r);
                defer dvui.clipSet(clip);
                if (more) {
                    const state: model.Model = .{ .panel = .more, .category = .game };
                    var pending: ?model.Msg = null;
                    tools.moreContent(&state, &pending);
                } else try view.draw(controller);
            }
        }
        // Tooltips draw into floating subwindows, not the root command list.
        for (win.subwindows.stack.items) |subwindow| {
            try commands.appendSlice(win.arena(), subwindow.render_cmds.items);
            try commands.appendSlice(win.arena(), subwindow.render_cmds_after.items);
        }
        arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const a = arena.?.allocator();
        var retained_text: std.ArrayList(Text) = .empty;
        var retained_mesh: std.ArrayList(dvui.Rect.Physical) = .empty;
        for (commands.items) |command| switch (command.cmd) {
            .text => |text| try retained_text.append(a, .{ .value = try a.dupe(u8, text.text), .rect = text.rs.r, .clip = command.clip }),
            .triangles => |mesh| try retained_mesh.append(a, mesh.tri.bounds),
            .pathFillConvex => |fill| {
                if (fill.path.points.len == 0) continue;
                var top_left = fill.path.points[0];
                var bottom_right = top_left;
                for (fill.path.points[1..]) |point| {
                    top_left.x = @min(top_left.x, point.x);
                    top_left.y = @min(top_left.y, point.y);
                    bottom_right.x = @max(bottom_right.x, point.x);
                    bottom_right.y = @max(bottom_right.y, point.y);
                }
                try retained_mesh.append(a, .{ .x = top_left.x, .y = top_left.y, .w = bottom_right.x - top_left.x, .h = bottom_right.y - top_left.y });
            },
            else => {},
        };
        texts = retained_text.items;
        meshes = retained_mesh.items;
        accessible_name = null;
        if (dvui.debug.target_wd) |wd| if (wd.options.label) |label| switch (label) {
            .text => |text| {
                accessible_name = try a.dupe(u8, text);
            },
            else => {},
        };
        return .ok;
    }

    fn geometry(tag: []const u8) !dvui.Debug.CapturedWidget {
        const target = dvui.tagGet(tag) orelse {
            std.debug.print("logs widget tag missing: {s}\n", .{tag});
            return error.LogWidgetMissing;
        };
        const capture = dvui.debug.lastCapture() orelse return error.LogCaptureMissing;
        for (capture.widgets.items) |widget| if (widget.id == target.id) return widget;
        return error.LogWidgetNotCaptured;
    }

    fn click(tag: []const u8) !void {
        try dvui.testing.moveTo(tag);
        try dvui.testing.click(.left);
    }

    fn clickText(value: []const u8) !void {
        const viewport = (try geometry("logs-viewport")).rect_content;
        for (texts) |text| {
            if (!std.mem.eql(u8, text.value, value) or !inside(viewport, text.rect) or !inside(text.clip, text.rect)) continue;
            _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = text.rect.center() });
            try dvui.testing.click(.left);
            return;
        }
        std.debug.print("visible log text missing: {s}\n", .{value});
        return error.LogTextMissing;
    }

    fn hasText(value: []const u8) bool {
        for (texts) |text| if (std.mem.eql(u8, text.value, value)) return true;
        return false;
    }

    fn seed(count: usize) !void {
        for (0..count) |i| {
            var line: [128]u8 = undefined;
            const value = try std.fmt.bufPrint(&line, "[INFO] fixture line {d}{s}\n", .{ i, if (i == 10 or i == 45) " needle" else "" });
            try controller.buffer.feed(.stdout, value);
        }
    }

    fn run(size: dvui.Size, font_size: f32, check: *const fn (*dvui.testing) anyerror!void) !void {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        var launch = try game_launch.Controller.init(std.testing.allocator, std.testing.io, root);
        defer launch.deinit();
        launch.attempt_id = 7;
        launch.phase = .running;
        controller = &launch;
        view = .{};
        more = false;
        sidebar_width = 276;
        defer resetCapture();
        var window = try dvui.testing.init(.{ .window_size = size });
        defer window.deinit();
        window.backend.size_pixels = .{ .w = size.w, .h = size.h };
        var value = dvui.Theme.builtin.adwaita_dark;
        value.font_body = value.font_body.withSize(font_size);
        value.font_heading = value.font_body.withSize(18);
        value.font_title = value.font_body.withSize(24);
        window.window.themeSet(value);
        try seed(80);
        try dvui.testing.settle(draw);
        try check(&window);
    }
};

fn checkLayout(_: *dvui.testing) !void {
    const main = (try Frame.geometry("logs-test-main")).rect_content;
    const column = (try Frame.geometry("logs-layout")).rect_content;
    const search = (try Frame.geometry("logs-search-toolbar")).rect_border;
    const output = (try Frame.geometry("logs-output-toolbar")).rect_border;
    const body = (try Frame.geometry("logs-body")).rect_border;
    const sidebar = (dvui.tagGet("logs-test-sidebar") orelse return error.SidebarMissing).rect;
    try std.testing.expect(inside(main, column));
    for ([_]dvui.Rect.Physical{ search, body, output }) |rect| {
        try std.testing.expect(rect.w > 0 and rect.h > 0);
        try std.testing.expect(inside(column, rect));
        try std.testing.expect(!overlaps(sidebar, rect));
    }
    try std.testing.expect(search.y + search.h <= body.y + 0.5);
    try std.testing.expect(body.y + body.h <= output.y + 0.5);
    try std.testing.expect(output.y > column.y + column.h / 2);
    const viewport = (try Frame.geometry("logs-viewport")).rect_content;
    try std.testing.expect(viewport.h >= 24);
    try std.testing.expect(inside(body, viewport));
    const entry = (try Frame.geometry("logs-search-entry")).rect_border;
    try std.testing.expect(entry.w >= 80);
    try std.testing.expect(inside(search, entry));
    for (icons, 0..) |icon, index| {
        const button = (try Frame.geometry(icon.tag)).rect_border;
        try std.testing.expect((dvui.tagGet(icon.tag) orelse return error.LogWidgetMissing).visible);
        try std.testing.expect(inside(if (index < 2) search else output, button));
        try std.testing.expect(!overlaps(body, button));
        if (index < 2) {
            try std.testing.expect(!overlaps(entry, button));
            try std.testing.expectApproxEqAbs(entry.y, button.y, 0.5);
            try std.testing.expectApproxEqAbs(entry.y + entry.h, button.y + button.h, 0.5);
        }
        for (icons[0..index]) |other| try std.testing.expect(!overlaps(button, (try Frame.geometry(other.tag)).rect_border));
        // Icon-only means real geometry is drawn, with no glyph text in its hit target.
        var has_icon = false;
        for (Frame.meshes) |mesh| if (mesh.w > 0 and mesh.h > 0 and mesh.w <= 24 and mesh.h <= 24 and inside(button, mesh)) {
            has_icon = true;
        };
        try std.testing.expect(has_icon);
        for (Frame.texts) |text| try std.testing.expect(!overlaps(button, text.rect));
    }
    var sources_drawn = false;
    var severity_drawn = false;
    for (Frame.texts) |text| {
        if (!inside(sidebar, text.rect)) continue;
        if (std.mem.eql(u8, text.value, "Sources")) sources_drawn = true;
        if (std.mem.eql(u8, text.value, "Severity")) severity_drawn = true;
        for ([_][]const u8{ "Search", "Output", "Jump to latest", "Copy selected line", "Copy retained output", "Clear retained output", "Stop game" }) |old| try std.testing.expect(!std.mem.eql(u8, text.value, old));
    }
    try std.testing.expect(sources_drawn);
    if (main.h >= 600) try std.testing.expect(severity_drawn);
    const diagnostics = (try Frame.geometry("logs-status")).rect_border;
    var diagnostic_text_drawn = false;
    for (Frame.texts) |text| {
        if (!overlaps(diagnostics, text.rect)) continue;
        diagnostic_text_drawn = true;
        // Status is vertically scrollable; wrapping must keep visible fragments
        // inside the main pane even at its minimum width and in terminal phases.
        try std.testing.expect(text.rect.x >= main.x - 0.5);
        try std.testing.expect(text.rect.x + text.rect.w <= main.x + main.w + 0.5);
    }
    try std.testing.expect(diagnostic_text_drawn);
}

const filter_tags = [_][]const u8{
    "logs-filter-follow",  "logs-filter-stdout", "logs-filter-stderr",
    "logs-filter-trace",   "logs-filter-debug",  "logs-filter-info",
    "logs-filter-warning", "logs-filter-error",  "logs-filter-fatal",
};

fn checkboxIndicator(tag: []const u8) !dvui.Debug.CapturedWidget {
    const control = try Frame.geometry(tag);
    const capture = dvui.debug.lastCapture() orelse return error.LogCaptureMissing;
    for (capture.widgets.items) |widget| {
        if (widget.parent_id != control.id or !std.mem.eql(u8, widget.name orelse "", "Spacer")) continue;
        const rect = widget.rect_border;
        // Select the visible square, excluding the spacer between box and label.
        if (rect.w > 0 and rect.h > 0 and @abs(rect.w - rect.h) < 0.5) return widget;
    }
    return error.CheckboxIndicatorMissing;
}

fn checkUniformFilters(_: *dvui.testing) !void {
    const reference = (try checkboxIndicator(filter_tags[0])).rect_border;
    var painted: [filter_tags.len]bool = @splat(false);
    for (0..6) |_| {
        const sidebar = (dvui.tagGet("logs-test-sidebar") orelse return error.SidebarMissing).rect;
        for (filter_tags, 0..) |tag, index| {
            const indicator = try checkboxIndicator(tag);
            const rect = indicator.rect_border;
            try std.testing.expectApproxEqAbs(reference.w, rect.w, 0.5);
            try std.testing.expectApproxEqAbs(reference.h, rect.h, 0.5);
            if (!indicator.visible or !inside(sidebar, rect)) continue;
            for (Frame.meshes) |mesh| {
                if (@abs(mesh.x - rect.x) <= 0.5 and @abs(mesh.y - rect.y) <= 0.5 and
                    @abs(mesh.w - rect.w) <= 0.5 and @abs(mesh.h - rect.h) <= 0.5) painted[index] = true;
            }
        }
        try dvui.testing.moveTo("logs-test-sidebar");
        _ = try dvui.currentWindow().addEventMouseWheel(-160, .vertical, null);
        try dvui.testing.settle(Frame.draw);
    }
    for (painted) |visible| try std.testing.expect(visible);

    // The severity label remains part of the checkbox hit target; keyboard
    // activation must reach that same control after its custom label styling.
    const control = try Frame.geometry("logs-filter-error");
    const indicator = (try checkboxIndicator("logs-filter-error")).rect_border;
    var label_rect: ?dvui.Rect.Physical = null;
    for (Frame.texts) |text| {
        if (std.mem.eql(u8, text.value, "Error") and inside(control.rect_border, text.rect) and
            inside(text.clip, text.rect) and text.rect.x >= indicator.x + indicator.w) label_rect = text.rect;
    }
    const label = label_rect orelse return error.SeverityLabelMissing;
    const error_index = @backingInt(@import("../core/logs.zig").Severity.@"error");
    try std.testing.expect(Frame.view.filters.severities[error_index]);
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = label.center() });
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(Frame.draw);
    try std.testing.expect(!Frame.view.filters.severities[error_index]);
    try dvui.testing.expectFocused("logs-filter-error");
    try dvui.testing.pressKey(.space, .none);
    _ = try dvui.testing.step(Frame.draw);
    try std.testing.expect(Frame.view.filters.severities[error_index]);
}

test "UI layout logs sidebar checkbox squares remain uniform and reachable" {
    for ([_]dvui.Size{ .{ .w = 640, .h = 400 }, .{ .w = 1280, .h = 720 } }) |size| for ([_]f32{ 16, 24 }) |font_size| try Frame.run(size, font_size, checkUniformFilters);
}

test "UI layout logs toolbars bound the viewport at small and large sizes and fonts" {
    for ([_]dvui.Size{ .{ .w = 640, .h = 400 }, .{ .w = 1280, .h = 720 } }) |size| for ([_]f32{ 16, 24 }) |font_size| try Frame.run(size, font_size, checkLayout);
}

fn checkIconNames(_: *dvui.testing) !void {
    Frame.view.selected = Frame.controller.buffer.lines()[10].id;
    @memcpy(Frame.view.query[0..6], "needle");
    try dvui.testing.settle(Frame.draw);
    for (icons) |icon| {
        const target = dvui.tagGet(icon.tag) orelse return error.LogWidgetMissing;
        dvui.debug.widget_id = target.id;
        defer dvui.debug.widget_id = .zero;
        _ = try dvui.testing.step(Frame.draw);
        try std.testing.expectEqualStrings(icon.name, Frame.accessible_name orelse return error.LogAccessibleNameMissing);
        dvui.debug.widget_id = .zero;
        try dvui.testing.moveTo(icon.tag);
        _ = try dvui.testing.step(Frame.draw);
        try std.testing.expect(!Frame.hasText(icon.name));
        for (0..8) |_| _ = try dvui.testing.step(Frame.draw);
        try std.testing.expect(Frame.hasText(icon.name));
        // Leaving the button dismisses the tooltip before inspecting the next one.
        _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = .{ .x = 1, .y = 1 } });
        _ = try dvui.testing.step(Frame.draw);
    }
}

test "UI layout logs icon controls keep accessible names and delayed hover tooltips" {
    try Frame.run(.{ .w = 1280, .h = 720 }, 16, checkIconNames);
}

fn checkSearch(_: *dvui.testing) !void {
    try Frame.click("logs-search-entry");
    try dvui.testing.writeText("needle");
    _ = try dvui.testing.step(Frame.draw);
    const lines = Frame.controller.buffer.lines();
    try std.testing.expectEqualStrings("needle", std.mem.sliceTo(&Frame.view.query, 0));
    try std.testing.expectEqual(@as(?u64, lines[10].id), Frame.view.selected);
    try std.testing.expect(!Frame.view.follow_tail);
    try dvui.testing.settle(Frame.draw);
    try std.testing.expect(Frame.hasText(lines[10].text));
    try Frame.click("logs-search-next");
    _ = try dvui.testing.step(Frame.draw);
    try std.testing.expectEqual(@as(?u64, lines[45].id), Frame.view.selected);
    try Frame.click("logs-search-prev");
    _ = try dvui.testing.step(Frame.draw);
    try std.testing.expectEqual(@as(?u64, lines[10].id), Frame.view.selected);
    try Frame.click("logs-search-entry");
    try dvui.testing.pressKey(.a, .lcontrol);
    try dvui.testing.pressKey(.backspace, .none);
    try dvui.testing.writeText("does-not-exist");
    _ = try dvui.testing.step(Frame.draw);
    try std.testing.expectEqualStrings("does-not-exist", std.mem.sliceTo(&Frame.view.query, 0));
    try std.testing.expect(Frame.view.cursor == null);
    try std.testing.expectEqual(.no_match, Frame.view.search_status);
}

test "UI layout logs typed search finds matching rows and previous next navigate" {
    try Frame.run(.{ .w = 640, .h = 400 }, 24, checkSearch);
}

fn checkTailAndCopy(window: *dvui.testing) !void {
    try dvui.testing.moveTo("logs-viewport");
    _ = try dvui.currentWindow().addEventMouseWheel(100000, .vertical, null);
    try dvui.testing.settle(Frame.draw);
    try std.testing.expect(!Frame.view.follow_tail);
    try std.testing.expect(Frame.view.scroll.viewport.y < Frame.view.scroll.scrollMax(.vertical));
    // Seed a previous selection, then send a row click and copy in one frame.
    Frame.view.selected = Frame.controller.buffer.lines()[0].id;
    try Frame.clickText(Frame.controller.buffer.lines()[2].text);
    try Frame.click("logs-copy-line");
    _ = try dvui.testing.step(Frame.draw);
    try std.testing.expectEqual(@as(?u64, Frame.controller.buffer.lines()[2].id), Frame.view.selected);
    try std.testing.expectEqualStrings(Frame.controller.buffer.lines()[2].text, window.backend.clipboard orelse return error.ClipboardMissing);
    // The wheel arrives in the same event batch as Jump. Jump must win and the
    // following frame must continue following newly appended output.
    try dvui.testing.moveTo("logs-viewport");
    _ = try dvui.currentWindow().addEventMouseWheel(48, .vertical, null);
    try Frame.click("logs-jump-latest");
    _ = try dvui.testing.step(Frame.draw);
    try std.testing.expect(Frame.view.follow_tail);
    try std.testing.expectApproxEqAbs(Frame.view.scroll.scrollMax(.vertical), Frame.view.scroll.viewport.y, 0.5);
    try Frame.controller.buffer.feed(.stdout, "[INFO] appended tail\n");
    try dvui.testing.settle(Frame.draw);
    try std.testing.expect(Frame.view.follow_tail);
    try std.testing.expectApproxEqAbs(Frame.view.scroll.scrollMax(.vertical), Frame.view.scroll.viewport.y, 0.5);
    try std.testing.expect(Frame.hasText("[INFO] appended tail"));
    // Finish the prior tooltip frames before clicking an adjacent toolbar icon.
    _ = try window.window.addEventMouseMotion(.{ .pt = .{ .x = 0, .y = 0 } });
    try dvui.testing.settle(Frame.draw);
    try Frame.click("logs-copy-output");
    _ = try dvui.testing.step(Frame.draw);
    const clipboard = window.backend.clipboard orelse return error.ClipboardMissing;
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(std.testing.allocator);
    for (Frame.controller.buffer.lines()) |line| {
        try expected.appendSlice(std.testing.allocator, line.text);
        try expected.append(std.testing.allocator, '\n');
    }
    try std.testing.expectEqualStrings(expected.items, clipboard);
}

test "UI layout logs wheel pause jump latest and same frame row copy work" {
    try Frame.run(.{ .w = 1280, .h = 720 }, 16, checkTailAndCopy);
}

fn checkDeferred(_: *dvui.testing) !void {
    const count = Frame.controller.buffer.lineCount();
    try Frame.click("logs-clear-output");
    _ = try dvui.testing.step(Frame.draw);
    try std.testing.expect(Frame.view.pending_clear);
    try std.testing.expectEqual(count, Frame.controller.buffer.lineCount());
    Frame.view.finish(Frame.controller);
    try std.testing.expectEqual(@as(usize, 0), Frame.controller.buffer.lineCount());
    try std.testing.expect(!Frame.view.pending_clear);
    try Frame.seed(4);
    try dvui.testing.settle(Frame.draw);
    try Frame.click("logs-clear-output");
    _ = try dvui.testing.step(Frame.draw);
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = .{ .x = 0, .y = 0 } });
    try dvui.testing.settle(Frame.draw);
    try Frame.click("logs-stop-game");
    _ = try dvui.testing.step(Frame.draw);
    try std.testing.expect(Frame.view.pending_clear and Frame.view.pending_stop);
    try std.testing.expectEqual(@as(?u64, 7), Frame.view.pending_attempt);
    // A completed frame cannot target the next launch attempt. No real Job is
    // injected, so stop cancellation itself is intentionally outside this test.
    Frame.controller.attempt_id = 8;
    Frame.view.finish(Frame.controller);
    try std.testing.expectEqual(@as(usize, 4), Frame.controller.buffer.lineCount());
    try std.testing.expect(!Frame.view.pending_clear and !Frame.view.pending_stop);
}

test "UI layout logs clear and stop defer until finish and reject stale attempts" {
    try Frame.run(.{ .w = 640, .h = 400 }, 16, checkDeferred);
}

fn checkNavigation(_: *dvui.testing) !void {
    for ([_]game_launch.Phase{ .idle, .preparing, .running, .exited, .failed }) |phase| {
        Frame.controller.phase = phase;
        try dvui.testing.settle(Frame.draw);
        const terminal = phase == .exited or phase == .failed;
        try std.testing.expectEqual(terminal, dvui.tagGet("home") != null);
        try std.testing.expectEqual(terminal, Frame.hasText("返回主页"));
        try std.testing.expect(!Frame.returned_home);
        if (terminal) {
            const sidebar = (dvui.tagGet("logs-test-sidebar") orelse return error.SidebarMissing).rect;
            const home = (try Frame.geometry("home")).rect_border;
            try std.testing.expect(inside(sidebar, home));
            try std.testing.expectApproxEqAbs(sidebar.y + sidebar.h, home.y + home.h, 0.5);
            try Frame.click("home");
            _ = try dvui.testing.step(Frame.draw);
            try std.testing.expect(Frame.returned_home);
            var state: model.Model = .{ .panel = .logs };
            model.transition(&state, .back);
            try std.testing.expectEqual(model.Panel.home, state.panel);
        }
    }
}

test "UI layout logs return home appears at sidebar bottom only after exit or failure" {
    try Frame.run(.{ .w = 640, .h = 400 }, 24, checkNavigation);
    try Frame.run(.{ .w = 1280, .h = 720 }, 16, checkNavigation);
}

fn checkMore(_: *dvui.testing) !void {
    Frame.more = true;
    try dvui.testing.settle(Frame.draw);
    const capture = dvui.debug.lastCapture() orelse return error.LogCaptureMissing;
    var cards: usize = 0;
    for (capture.widgets.items) |widget| if (std.mem.eql(u8, widget.name orelse "", "Button") and std.mem.eql(u8, widget.src_fn, "moreContent")) {
        cards += 1;
    };
    try std.testing.expectEqual(@as(usize, 4), cards);
    try std.testing.expect(!Frame.hasText("游戏日志"));
    for ([_][]const u8{ "实例管理", "存档管理", "Java 管理", "服务器" }) |label| try std.testing.expect(Frame.hasText(label));
}

test "UI layout logs More game cards omit the logs entry" {
    try Frame.run(.{ .w = 1280, .h = 720 }, 16, checkMore);
}

fn checkResize(window: *dvui.testing) !void {
    try std.testing.expect(Frame.view.follow_tail);
    const before = Frame.view.scroll.viewport.h;
    window.backend.size.h += 240;
    window.backend.size_pixels.h += 240;
    // step ends the already-open old-size frame; the following frame sees resize.
    _ = try dvui.testing.step(Frame.draw);
    try dvui.testing.settle(Frame.draw);
    try std.testing.expect(Frame.view.scroll.viewport.h > before + 100);
    try std.testing.expect(Frame.view.follow_tail);
    try std.testing.expectApproxEqAbs(Frame.view.scroll.scrollMax(.vertical), Frame.view.scroll.viewport.y, 0.5);
    try Frame.controller.buffer.feed(.stdout, "[INFO] tail after resize\n");
    try dvui.testing.settle(Frame.draw);
    try std.testing.expect(Frame.view.follow_tail);
    try std.testing.expect(Frame.hasText("[INFO] tail after resize"));
    try dvui.testing.moveTo("logs-viewport");
    _ = try dvui.currentWindow().addEventMouseWheel(48, .vertical, null);
    try dvui.testing.settle(Frame.draw);
    try std.testing.expect(!Frame.view.follow_tail);
    try std.testing.expect(Frame.view.scroll.viewport.y < Frame.view.scroll.scrollMax(.vertical));
}

test "UI layout logs growing viewport keeps following tail and wheel still pauses" {
    try Frame.run(.{ .w = 640, .h = 400 }, 16, checkResize);
}

test "UI layout logs resized sidebar reserves five icon targets" {
    const bound = @import("view.zig").boundedLogsSidebarWidth;
    try std.testing.expectEqual(@as(f32, 328), bound(500, 632));
    try std.testing.expectEqual(@as(f32, 240), 632 - bound(500, 632) - 2 * theme.spacing.page_padding);
    for ([_]f32{ -100, 0, 276, 500, std.math.nan(f32), std.math.inf(f32) }) |requested| {
        const width = bound(requested, 632);
        try std.testing.expect(std.math.isFinite(width));
        try std.testing.expect(width >= 260 and width <= 328);
    }
}

fn checkCompactStates(window: *dvui.testing) !void {
    Frame.sidebar_width = 500;
    for (0..20) |_| try Frame.controller.buffer.feed(.stderr, "[ERROR] compact fixture\n");
    try dvui.testing.settle(Frame.draw);
    const main = (try Frame.geometry("logs-test-main")).rect_content;
    try std.testing.expectApproxEqAbs(@as(f32, 240), main.w, 0.5);
    var follow: ?dvui.Rect.Physical = null;
    var errors: ?dvui.Rect.Physical = null;
    for (Frame.texts) |text| {
        if (std.mem.eql(u8, text.value, "Following latest")) follow = text.rect;
        // DVUI may ellipsize the suffix; the numeric count and meaning must show.
        if (std.mem.startsWith(u8, text.value, "20 err")) errors = text.rect;
    }
    try std.testing.expect(follow != null and errors != null);
    try std.testing.expect(inside(main, follow.?) and inside(main, errors.?));
    try std.testing.expect(!overlaps(follow.?, errors.?));
    try checkLayout(window);
    Frame.view.copy_status = .copied;
    try dvui.testing.settle(Frame.draw);
    try checkLayout(window);
    Frame.controller.phase = .exited;
    Frame.controller.exit_code = 17;
    try dvui.testing.settle(Frame.draw);
    try checkLayout(window);
    Frame.controller.phase = .failed;
    Frame.controller.failure = error.SyntheticLaunchFailure;
    try dvui.testing.settle(Frame.draw);
    try checkLayout(window);
}

test "UI layout logs compact sidebar resize leaves usable output with copied and terminal status" {
    try Frame.run(.{ .w = 640, .h = 400 }, 24, checkCompactStates);
}

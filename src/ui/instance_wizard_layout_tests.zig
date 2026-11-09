const std = @import("std");
const dvui = @import("dvui");
const config = @import("../core/config.zig");
const instances = @import("../core/instances.zig");
const tasks = @import("../core/tasks.zig");
const manager_module = @import("../application/instances_manager.zig");
const wizard = @import("instances_view.zig");
const library = @import("../application/game_library.zig");
const components = @import("components.zig");
const bento_theme = @import("theme.zig");

const catalogue_entries = [_]library.CatalogEntry{
    .{ .id = "1.21.1", .url = "https://piston-meta.mojang.com/v1/packages/fixture/1.21.1.json", .kind = "release", .release_time = "2024-08-08T12:24:45+00:00" },
    .{ .id = "1.20.1", .url = "https://piston-meta.mojang.com/v1/packages/fixture/1.20.1.json", .kind = "release" },
    .{ .id = "24w14a", .url = "https://piston-meta.mojang.com/v1/packages/fixture/24w14a.json", .kind = "snapshot" },
    .{ .id = "1.7.10", .url = "https://piston-meta.mojang.com/v1/packages/fixture/1.7.10.json", .kind = "release" },
    .{ .id = "1.6.4", .url = "https://piston-meta.mojang.com/v1/packages/fixture/1.6.4.json", .kind = "release" },
};
const existing = [_]config.Instance{
    .{ .id = "one", .name = "1.21.1", .minecraft_version = "1.21.1" },
    .{ .id = "two", .name = "1.21.1-2", .minecraft_version = "1.21.1" },
    .{ .id = "three", .name = "1.21.1-Fabric", .minecraft_version = "1.21.1" },
    .{ .id = "four", .name = "1.21.1-Fabric-2", .minecraft_version = "1.21.1" },
    .{ .id = "taken", .name = "Taken", .minecraft_version = "1.20.1" },
};

fn expectInside(outer: dvui.Rect.Physical, inner: dvui.Rect.Physical) !void {
    errdefer std.debug.print("expectInside failed: outer={any}, inner={any}\n", .{ outer, inner });
    try std.testing.expect(inner.w > 0 and inner.h > 0);
    try std.testing.expect(inner.x >= outer.x - 0.1 and inner.y >= outer.y - 0.1);
    try std.testing.expect(inner.x + inner.w <= outer.x + outer.w + 0.1);
    try std.testing.expect(inner.y + inner.h <= outer.y + outer.h + 0.1);
}

const Frame = struct {
    const Footer = struct { id: dvui.Id, rect: dvui.Rect.Physical, text: dvui.Rect.Physical, clip: dvui.Rect.Physical };
    const Text = struct { rect: dvui.Rect.Physical, clip: dvui.Rect.Physical, font: dvui.Font };
    const Geometry = struct { border: dvui.Rect.Physical, content: dvui.Rect.Physical };
    var render_commands: []const dvui.RenderCommand = &.{};
    var render_arena: ?std.heap.ArenaAllocator = null;

    fn clearRenderCommands() void {
        render_commands = &.{};
        if (render_arena) |*arena| arena.deinit();
        render_arena = null;
    }

    fn retainRenderCommands(source: []const dvui.RenderCommand) !void {
        // testing.settle ends the frame and begins the next one. Its Window
        // arena no longer owns valid evidence when the assertions run.
        clearRenderCommands();
        render_arena = .init(std.testing.allocator);
        errdefer clearRenderCommands();
        const allocator = render_arena.?.allocator();
        var retained: std.ArrayList(dvui.RenderCommand) = .empty;
        for (source) |original| {
            var command = original;
            switch (command.cmd) {
                .text => |*text| {
                    text.text = try allocator.dupe(u8, text.text);
                    if (text.kern_in) |kern| text.kern_in = try allocator.dupe(u32, kern);
                    if (text.gradient) |gradient| text.gradient = try gradient.dupe(allocator);
                    // Accessibility work is not replayed by these assertions.
                    text.ak_opts = null;
                },
                .pathFillConvex => |*fill| {
                    fill.path = try fill.path.dupe(allocator);
                    fill.opts.color = try fill.opts.color.dupe(allocator);
                },
                .pathStroke => |*stroke| {
                    stroke.path = try stroke.path.dupe(allocator);
                    stroke.opts.color = try stroke.opts.color.dupe(allocator);
                },
                .triangles => |*mesh| mesh.tri = try mesh.tri.dupe(allocator),
                else => continue,
            }
            try retained.append(allocator, command);
        }
        render_commands = retained.items;
    }
    var store: *config.Store = undefined;
    var manager: *manager_module.Manager = undefined;
    var ui: *wizard.Ui = undefined;
    var home: ?Footer = null;
    var home_clicked = false;
    var java21 = false;
    var java17 = false;
    var minecraft1211 = false;
    var fabric016 = false;
    var version_name: ?Text = null;
    var version_date: ?Text = null;
    var loader_name: ?Text = null;
    var loader_date: ?Text = null;
    var forbidden_calls: std.atomic.Value(usize) = .init(0);
    var catalogue_calls: std.atomic.Value(usize) = .init(0);
    var catalogue: library.Snapshot = .{ .installed = &.{}, .available = &catalogue_entries, .phase = .complete, .failure = null };
    var loader_render_phase: ?manager_module.Phase = null;
    var fetch_outcome: enum { populated, empty, failed, non_public_address } = .populated;
    var expected_retry: enum { none, version, loader } = .none;
    var retry_count: usize = 0;

    fn textInCard(comptime key: []const u8, rect: dvui.Rect.Physical) bool {
        const card = dvui.tagGet(key) orelse return false;
        const center = rect.center();
        return center.x >= card.rect.x and center.x <= card.rect.x + card.rect.w and
            center.y >= card.rect.y and center.y <= card.rect.y + card.rect.h;
    }

    fn rejectLease(_: ?*anyopaque, _: []const u8) !void {
        _ = forbidden_calls.fetchAdd(1, .monotonic);
        return error.UnexpectedWizardLease;
    }
    fn releaseLease(_: ?*anyopaque, _: []const u8) void {
        _ = forbidden_calls.fetchAdd(1, .monotonic);
    }
    fn rejectInstaller(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: manager_module.CreateRequest, _: manager_module.Control) !manager_module.Installed {
        _ = forbidden_calls.fetchAdd(1, .monotonic);
        return error.UnexpectedWizardInstaller;
    }
    fn fetch(_: ?*anyopaque, a: std.mem.Allocator, _: std.Io, base: []const u8, kind: config.Loader, _: manager_module.Control) !manager_module.LoaderCatalogue {
        _ = catalogue_calls.fetchAdd(1, .monotonic);
        if (fetch_outcome == .failed) return error.TestLoaderCatalogueUnavailable;
        if (fetch_outcome == .non_public_address) return error.NonPublicAddress;
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const entries = try owned.alloc(manager_module.LoaderEntry, if (fetch_outcome == .empty) 0 else 2);
        if (entries.len != 0) {
            entries[0] = .{ .id = try owned.dupe(u8, "0.16.0"), .release_time = try owned.dupe(u8, "2024-07-24T10:00:00Z") };
            entries[1] = .{ .id = try owned.dupe(u8, "0.15.0") };
        }
        return .{ .arena = arena, .base = try owned.dupe(u8, base), .kind = kind, .entries = entries };
    }

    fn draw() !dvui.App.Result {
        // Only this deterministic in-memory catalogue worker may be joined here.
        // No network or production installer is reachable through this fixture.
        if (manager.active) |job| if (job.future) |*future| future.await(std.testing.io);
        manager.tick();
        const previous_loader_phase = manager.loader_phase;
        if (loader_render_phase) |phase| manager.loader_phase = phase;
        defer manager.loader_phase = previous_loader_phase;
        const win = dvui.currentWindow();
        dvui.debug.captureScopeBegin(win.gpa);
        defer dvui.debug.captureScopeEnd();
        var commands: std.ArrayList(dvui.RenderCommand) = .empty;
        const previous_commands = win.defer_render_cmds;
        const previous_rendering = win.render_target.rendering;
        win.defer_render_cmds = &commands;
        win.render_target.rendering = false;
        defer {
            win.defer_render_cmds = previous_commands;
            win.render_target.rendering = previous_rendering;
        }
        home = null;
        java21 = false;
        java17 = false;
        minecraft1211 = false;
        fabric016 = false;
        version_name = null;
        version_date = null;
        loader_name = null;
        loader_date = null;
        {
            // Match the production two-pane geometry, including its eight-pixel handle.
            var split = @as(f32, 280) / @max(1, dvui.windowRect().w - 8);
            const panes = dvui.paned(@src(), .{ .direction = .horizontal, .collapsed_size = 0, .split_ratio = &split, .handle_size = 8 }, .{ .expand = .both, .padding = dvui.Rect.all(0), .margin = dvui.Rect.all(0) });
            defer panes.deinit();
            if (panes.showFirst()) {
                const side = wizard.sidebarPanel(@src());
                defer side.deinit();
                dvui.tag("wizard-test-sidebar", .{ .id = side.data().id, .rect = side.data().borderRectScale().r, .visible = true });
                wizard.sidebarHeading(@src());
                if (wizard.sidebarFooter(@src(), "返回主页")) home_clicked = true;
                wizard.drawSidebar(ui, store, manager, true);
            }
            if (panes.showSecond()) {
                const window_rect = dvui.windowRect();
                const body_padding: f32 = if (window_rect.w < 900 or window_rect.h < 540) 24 else 32;
                const body = dvui.box(@src(), .{}, .{ .expand = .both, .padding = dvui.Rect.all(body_padding) });
                defer body.deinit();
                dvui.tag("wizard-test-body", .{ .id = body.data().id, .rect = body.data().contentRectScale().r, .visible = true });
                const previous_clip = dvui.clip(body.data().contentRectScale().r);
                defer dvui.clipSet(previous_clip);
                wizard.drawWithEnabled(ui, store, manager, catalogue, &.{}, true);
            }
        }
        var summary_fabric = false;
        var summary_loader016 = false;
        for (commands.items) |command| switch (command.cmd) {
            .text => |text| {
                const has_java = std.mem.indexOf(u8, text.text, "Java") != null;
                java21 = java21 or (has_java and std.mem.indexOf(u8, text.text, "21") != null);
                java17 = java17 or (has_java and std.mem.indexOf(u8, text.text, "17") != null);
                minecraft1211 = minecraft1211 or (std.mem.indexOf(u8, text.text, "Minecraft") != null and std.mem.indexOf(u8, text.text, "1.21.1") != null);
                // TextLayout can wrap the loader name and version into separate commands.
                // Both tokens must render inside this summary field in the current frame.
                if (dvui.tagGet("instance-wizard-summary-loader")) |field| {
                    const rect = text.rs.r;
                    if (rect.x >= field.rect.x - 0.1 and rect.y >= field.rect.y - 0.1 and
                        rect.x + rect.w <= field.rect.x + field.rect.w + 0.1 and
                        rect.y + rect.h <= field.rect.y + field.rect.h + 0.1)
                    {
                        summary_fabric = summary_fabric or std.mem.indexOf(u8, text.text, "Fabric") != null;
                        summary_loader016 = summary_loader016 or std.mem.indexOf(u8, text.text, "0.16.0") != null;
                    }
                }
                const rendered: Text = .{ .rect = text.rs.r, .clip = command.clip, .font = text.font };
                if (std.mem.eql(u8, text.text, "1.21.1") and textInCard("instance-version-1.21.1", text.rs.r)) version_name = rendered;
                if (std.mem.eql(u8, text.text, "2024/08/08") and textInCard("instance-version-1.21.1", text.rs.r)) version_date = rendered;
                if (std.mem.eql(u8, text.text, "0.16.0") and textInCard("instance-loader-fabric-0.16.0", text.rs.r)) loader_name = rendered;
                if (std.mem.eql(u8, text.text, "2024/07/24") and textInCard("instance-loader-fabric-0.16.0", text.rs.r)) loader_date = rendered;
                if (std.mem.eql(u8, text.text, "返回主页")) {
                    for (win.tab_index.items) |entry| {
                        const rect = entry.rect orelse continue;
                        if (text.rs.r.center().x >= rect.x and text.rs.r.center().x <= rect.x + rect.w and text.rs.r.center().y >= rect.y and text.rs.r.center().y <= rect.y + rect.h) {
                            home = .{ .id = entry.widgetId, .rect = rect, .text = text.rs.r, .clip = command.clip };
                            break;
                        }
                    }
                }
            },
            else => {},
        };
        try retainRenderCommands(commands.items);
        fabric016 = summary_fabric and summary_loader016;
        // Fail before a submit can call any installation or preparation service.
        if (ui.pending) |pending| if (pending.action == .submit) return error.UnexpectedWizardSubmit;
        if (ui.catalogue_requested) {
            if (expected_retry != .version) return error.UnexpectedWizardNetworkRefresh;
            retry_count += 1;
            ui.catalogue_requested = false;
        }
        if (expected_retry == .loader) if (ui.pending) |pending| if (pending.action == .load_loaders) {
            try std.testing.expect(pending.force_refresh);
            try std.testing.expect(pending.text == null);
            retry_count += 1;
            ui.pending = null;
        };
        wizard.finish(ui, store, manager);
        try std.testing.expect(ui.failure == null);
        return .ok;
    }

    fn captured(name: []const u8) !Geometry {
        const target = try dvui.testing.tagGet(name);
        const capture = dvui.debug.lastCapture() orelse return error.WizardWidgetCaptureMissing;
        for (capture.widgets.items) |widget| {
            if (widget.id == target.id) return .{ .border = widget.rect_border, .content = widget.rect_content };
        }
        return error.WizardCapturedWidgetMissing;
    }

    fn tagged(name: []const u8, enabled: bool) !dvui.TagData {
        const target = try dvui.testing.tagGet(name);
        try expectInside(dvui.windowRectPixels(), target.rect);
        try expectInside((try dvui.testing.tagGet("wizard-test-body")).rect, target.rect);
        try std.testing.expect(target.visible);
        var count: usize = 0;
        for (dvui.currentWindow().tab_index_prev.items) |entry| if (entry.widgetId == target.id) {
            count += 1;
        };
        try std.testing.expectEqual(@as(usize, if (enabled) 1 else 0), count);
        return target;
    }
    fn boundedFrames() !?u32 {
        // Native spinners keep requesting frames; settling them cannot finish.
        var next_frame: ?u32 = null;
        for (0..3) |_| next_frame = try dvui.testing.step(draw);
        return next_frame;
    }

    fn click(name: []const u8) !void {
        const target = try tagged(name, true);
        _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = target.rect.center() });
        try dvui.testing.click(.left);
        if (catalogue.phase == .loading or loader_render_phase == .working) {
            _ = try boundedFrames();
            const still_animated = ui.mode == .create and switch (ui.create_step) {
                .version => catalogue.phase == .loading,
                .loader => loader_render_phase == .working,
                .confirm => false,
            };
            if (!still_animated) try dvui.testing.settle(draw);
        } else try dvui.testing.settle(draw);
    }
    fn replace(name: []const u8, value: []const u8) !void {
        try click(name);
        try dvui.testing.pressKey(.a, .lcontrol);
        try dvui.testing.pressKey(.backspace, .none);
        try dvui.testing.writeText(value);
        try dvui.testing.settle(draw);
    }
    var sidebar_border_width: ?f32 = null;

    fn footers(primary: []const u8, enabled: bool) !void {
        const navigation = home orelse return error.WizardHomeFooterMissing;
        try expectInside((try dvui.testing.tagGet("wizard-test-sidebar")).rect, navigation.rect);
        try expectInside(navigation.rect, navigation.text);
        try expectInside(navigation.clip, navigation.text);
        const left = try tagged(if (ui.create_step == .version) "instance-wizard-cancel" else "instance-wizard-previous", true);
        const right = try tagged(primary, enabled);
        const body = (try dvui.testing.tagGet("wizard-test-body")).rect;
        const side = (try dvui.testing.tagGet("wizard-test-sidebar")).rect;
        try std.testing.expect(side.x + side.w < body.x);
        try expectInside(dvui.windowRectPixels(), side);
        try std.testing.expectApproxEqAbs(@as(f32, 280), side.x + side.w, 1);
        for ([_][]const u8{"new-instance"}) |key| {
            const action = try dvui.testing.tagGet(key);
            try std.testing.expect(action.visible);
            try expectInside(side, action.rect);
            try std.testing.expectApproxEqAbs(@as(f32, 48), (try renderedControlBounds(key)).h, 0.1);
            try std.testing.expect(action.rect.y + action.rect.h <= navigation.rect.y + 1);
            try renderedFont(key, 16);
        }
        if (sidebar_border_width) |width| {
            try std.testing.expectApproxEqAbs(width, side.w, 1);
        } else sidebar_border_width = side.w;
        try std.testing.expect(left.rect.x + left.rect.w + 16 <= right.rect.x + 0.1);
        const left_key = if (ui.create_step == .version) "instance-wizard-cancel" else "instance-wizard-previous";
        const left_border = try renderedControlBounds(left_key);
        const right_border = try renderedControlBounds(primary);
        const available = (try dvui.testing.tagGet("instance-wizard-footer")).rect.w;
        const expected_width = @min(@as(f32, 144), @max(0, (available - 16) / 2));
        try std.testing.expectApproxEqAbs(@as(f32, 48), left_border.h, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 48), right_border.h, 0.1);
        try std.testing.expectApproxEqAbs(expected_width, left_border.w, 0.1);
        try std.testing.expectApproxEqAbs(expected_width, right_border.w, 0.1);
        try std.testing.expectApproxEqAbs(left_border.w, right_border.w, 0.1);
        try std.testing.expectApproxEqAbs(left_border.y, right_border.y, 0.1);
        const left_label = if (ui.create_step == .version) "instance-wizard-cancel-label" else "instance-wizard-previous-label";
        try renderedFont(left_label, 16);
        try expectInside(left_border, try renderedTextBounds(left_label));
        var primary_label_buffer: [96]u8 = undefined;
        const primary_label = try std.fmt.bufPrint(&primary_label_buffer, "{s}-label", .{primary});
        try renderedAppearance(primary_label, 16, if (enabled) null else @import("theme.zig").colors.muted);
        try expectInside(right_border, try renderedTextBounds(primary_label));
        try renderedSingleLine(primary_label);
        try std.testing.expect(left.rect.center().x < body.x + body.w * 0.25);
        try std.testing.expect(right.rect.center().x > body.x + body.w * 0.75);
        const footer = (try dvui.testing.tagGet("instance-wizard-footer")).rect;
        try expectInside(footer, left.rect);
        try expectInside(footer, right.rect);
        try std.testing.expect(footer.center().y > body.y + body.h * 0.75);
        try std.testing.expect(navigation.rect.center().y > side.y + side.h * 0.75);
    }
};

fn clippedControl(comptime key: []const u8, viewport: dvui.Rect.Physical) !void {
    const control = try renderedControlBounds(key);
    const visible = control.intersect(viewport);
    try expectInside(viewport, visible);
    var border_found = false;
    var text_found = false;
    for (Frame.render_commands) |command| switch (command.cmd) {
        .pathStroke => |stroke| {
            const path = pathBounds(stroke.path.points) orelse continue;
            const half = stroke.opts.thickness / 2;
            const border: dvui.Rect.Physical = .{ .x = path.x - half, .y = path.y - half, .w = path.w + 2 * half, .h = path.h + 2 * half };
            if (@abs(border.x - control.x) > 0.1 or @abs(border.y - control.y) > 0.1 or @abs(border.w - control.w) > 0.1 or @abs(border.h - control.h) > 0.1) continue;
            // The command retains the full border; its native clip controls visibility.
            try expectInside(viewport, command.clip);
            try expectInside(command.clip, visible);
            border_found = true;
        },
        .text => |text| {
            if (text.text.len == 0 or !Frame.textInCard(key, text.rs.r)) continue;
            try expectInside(viewport, text.rs.r);
            try expectInside(command.clip, text.rs.r);
            try expectInside(viewport, command.clip);
            text_found = true;
        },
        else => {},
    };
    try std.testing.expect(border_found and text_found);
}

fn sidebarFirstFrame() !void {
    const theme = @import("theme.zig");
    const side = (try dvui.testing.tagGet("wizard-test-sidebar")).rect;
    const navigation = Frame.home orelse return error.WizardHomeFooterMissing;
    const first_instance = try dvui.testing.tagGet("one");
    const first_instance_control = try renderedControlBounds("one");
    const list = (try dvui.testing.tagGet("instance-sidebar-list")).rect;
    try std.testing.expect(first_instance.visible);
    try expectInside(side, first_instance_control);
    try std.testing.expectApproxEqAbs(@as(f32, 48), first_instance_control.h, 0.1);
    try clippedControl("one", list);
    try expectInside(side, navigation.rect);
    try expectInside(navigation.rect, navigation.text);
    try expectInside(navigation.clip, navigation.text);
    try renderedFont("instance-sidebar-title", theme.typography.title);
    try renderedFont("instance-sidebar-footer", 16);
    try renderedFont("one", 16);
    const title = try renderedTextBounds("instance-sidebar-title");
    const actions = try renderedControlBounds("new-instance");
    try std.testing.expectApproxEqAbs(side.x + theme.spacing.sidebar_padding, title.x, 0.1);
    try std.testing.expect(title.y + title.h + theme.spacing.sidebar_header_gap <= actions.y + 0.1);
    try std.testing.expect(list.y + list.h + theme.spacing.sidebar_footer_gap <= navigation.rect.y + 0.1);
    if (list.h < first_instance.rect.h) {
        // A compact viewport can clip the 48px border while showing every glyph.
        // Real wheel input must move the row without moving or obscuring navigation.
        try dvui.testing.moveTo("instance-sidebar-list");
        _ = try dvui.currentWindow().addEventMouseWheel(-theme.spacing.detail_gap, .vertical, null);
        try dvui.testing.settle(Frame.draw);
        try std.testing.expect((try renderedControlBounds("one")).y < first_instance_control.y - 0.1);
        try clippedControl("one", list);
        const after = Frame.home orelse return error.WizardHomeFooterMissing;
        try std.testing.expectEqual(navigation.rect, after.rect);
        try expectInside(after.rect, after.text);
        try expectInside(after.clip, after.text);
        _ = try dvui.currentWindow().addEventMouseWheel(100000, .vertical, null);
        try dvui.testing.settle(Frame.draw);
        try std.testing.expectEqual(first_instance_control, try renderedControlBounds("one"));
        try std.testing.expectEqual(navigation.rect, Frame.home.?.rect);
    } else try expectInside(list, first_instance_control);
}

fn reachableRetry(comptime list_key: []const u8) !void {
    const viewport = (try dvui.testing.tagGet(list_key)).rect;
    const footer = try renderedControlBounds("instance-wizard-next");
    for (0..64) |_| {
        if (try renderedMessage("重试")) break;
        try std.testing.expect((try dvui.testing.tagGet(list_key)).visible);
        try dvui.testing.moveTo(list_key);
        _ = try dvui.currentWindow().addEventMouseWheel(-@import("theme.zig").spacing.row_gap, .vertical, null);
        try dvui.testing.settle(Frame.draw);
        try std.testing.expectEqual(footer, try renderedControlBounds("instance-wizard-next"));
    }
    try std.testing.expect(try renderedMessage("重试"));
    var retry_id: ?dvui.Id = null;
    for (Frame.render_commands) |command| switch (command.cmd) {
        .text => |text| {
            if (!std.mem.eql(u8, text.text, "重试")) continue;
            try expectInside(viewport, text.rs.r);
            try expectInside(command.clip, text.rs.r);
            const center = text.rs.r.center();
            for (dvui.currentWindow().tab_index_prev.items) |entry| {
                const rect = entry.rect orelse continue;
                if (center.x >= rect.x and center.x <= rect.x + rect.w and center.y >= rect.y and center.y <= rect.y + rect.h) retry_id = entry.widgetId;
            }
        },
        else => {},
    };
    const target = retry_id orelse return error.WizardRetryNotKeyboardAccessible;
    for (0..64) |_| {
        if (dvui.focusedWidgetId() == target) break;
        try dvui.testing.pressKey(.tab, .none);
        try dvui.testing.settle(Frame.draw);
    }
    try std.testing.expectEqual(target, dvui.focusedWidgetId().?);
    try std.testing.expect(try renderedMessage("重试"));
    try std.testing.expectEqual(footer, try renderedControlBounds("instance-wizard-next"));
    var glyph: ?dvui.Rect.Physical = null;
    for (Frame.render_commands) |command| switch (command.cmd) {
        .text => |text| if (std.mem.eql(u8, text.text, "重试")) {
            try expectInside(viewport, text.rs.r);
            try expectInside(command.clip, text.rs.r);
            glyph = text.rs.r;
        },
        else => {},
    };
    const retry_glyph = glyph orelse return error.WizardRetryGlyphMissing;
    Frame.retry_count = 0;
    Frame.expected_retry = if (std.mem.eql(u8, list_key, "instance-wizard-version-list")) .version else .loader;
    defer Frame.expected_retry = .none;
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = retry_glyph.center() });
    try dvui.testing.click(.left);
    try dvui.testing.settle(Frame.draw);
    try std.testing.expectEqual(@as(usize, 1), Frame.retry_count);
    Frame.expected_retry = .none;
    try dvui.testing.moveTo(list_key);
    _ = try dvui.currentWindow().addEventMouseWheel(100000, .vertical, null);
    try dvui.testing.settle(Frame.draw);
    try std.testing.expectEqual(footer, try renderedControlBounds("instance-wizard-next"));
}

fn atBothSizes(comptime scenario: fn () anyerror!void) !void {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    const a = std.testing.allocator;
    Frame.sidebar_border_width = null;
    for ([_]dvui.Size{ .{ .w = 640, .h = 400 }, .{ .w = 1280, .h = 720 } }) |size| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        defer a.free(root);
        var store = try config.Store.init(a, std.testing.io, root);
        defer store.deinit();
        try store.update(.{ .instances = &existing });
        var paths = try instances.Paths.init(a, std.testing.io, root);
        defer paths.deinit();
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        Frame.forbidden_calls.store(0, .monotonic);
        Frame.catalogue_calls.store(0, .monotonic);
        Frame.catalogue = .{ .installed = &.{}, .available = &catalogue_entries, .phase = .complete, .failure = null };
        Frame.loader_render_phase = null;
        Frame.fetch_outcome = .populated;
        Frame.home_clicked = false;
        var manager = try manager_module.Manager.init(a, std.testing.io, &paths, &registry, .{}, .{ .context = null, .acquire = Frame.rejectLease, .recheck = Frame.rejectLease, .release = Frame.releaseLease });
        defer manager.deinit();
        manager.setInstaller(.{ .run = Frame.rejectInstaller });
        manager.setLoaderCatalogue(.{ .fetch = Frame.fetch });
        var ui = wizard.Ui.init(a);
        defer ui.deinit();
        ui.mode = .create;
        ui.java_preview = .{ .version = "1.21.1", .java_major = 21, .phase = .complete };
        Frame.store = &store;
        Frame.manager = &manager;
        Frame.ui = &ui;
        var window = try dvui.testing.init(.{ .window_size = size });
        defer window.deinit();
        Frame.clearRenderCommands();
        defer Frame.clearRenderCommands();
        window.backend.size_pixels = .{ .w = size.w, .h = size.h };
        // Production colours and type sizes; native captures cover discovered CJK fonts.
        @import("theme.zig").install(window.window);
        // The fixture bypasses view.draw, which resolves EM sizes against the active face.
        bento_theme.applyTypography();
        try dvui.testing.settle(Frame.draw);
        // Initial viewport must show the first instance before focus traversal can scroll it.
        try sidebarFirstFrame();
        try scenario();
        try std.testing.expectEqual(@as(usize, 0), Frame.forbidden_calls.load(.monotonic));
        try std.testing.expect(!ui.submitted);
        try std.testing.expectEqual(@as(usize, existing.len), store.snapshot().instances.len);
    }
}

fn layoutElement(name: []const u8) !dvui.Rect.Physical {
    const tag = try dvui.testing.tagGet(name);
    try std.testing.expect(tag.visible);
    try expectInside(dvui.windowRectPixels(), tag.rect);
    try expectInside((try dvui.testing.tagGet("wizard-test-body")).rect, tag.rect);
    return tag.rect;
}

fn renderedTextBounds(key: []const u8) !dvui.Rect.Physical {
    const target = try dvui.testing.tagGet(key);
    var bounds: ?dvui.Rect.Physical = null;
    for (Frame.render_commands) |command| switch (command.cmd) {
        .text => |text| {
            if (text.text.len == 0) continue;
            const rect = text.rs.r;
            const center = rect.center();
            if (center.x < target.rect.x or center.x > target.rect.x + target.rect.w or
                center.y < target.rect.y or center.y > target.rect.y + target.rect.h) continue;
            try expectInside(command.clip, rect);
            if (bounds) |previous| {
                const x = @min(previous.x, rect.x);
                const y = @min(previous.y, rect.y);
                bounds = .{ .x = x, .y = y, .w = @max(previous.x + previous.w, rect.x + rect.w) - x, .h = @max(previous.y + previous.h, rect.y + rect.h) - y };
            } else bounds = rect;
        },
        else => {},
    };
    return bounds orelse error.WizardTextNotRendered;
}

fn renderedControlBounds(key: []const u8) !dvui.Rect.Physical {
    const target = try dvui.testing.tagGet(key);
    var bounds: ?dvui.Rect.Physical = null;
    // Native tags and tab entries contain the outer margin. The actual
    // stroked border supplies the visible control's position and dimensions.
    for (Frame.render_commands) |command| switch (command.cmd) {
        .pathStroke => |stroke| {
            if (stroke.path.points.len < 4) continue;
            var min_x: f32 = std.math.inf(f32);
            var min_y: f32 = std.math.inf(f32);
            var max_x: f32 = -std.math.inf(f32);
            var max_y: f32 = -std.math.inf(f32);
            for (stroke.path.points) |point| {
                min_x = @min(min_x, point.x);
                min_y = @min(min_y, point.y);
                max_x = @max(max_x, point.x);
                max_y = @max(max_y, point.y);
            }
            const half = stroke.opts.thickness / 2;
            const rect: dvui.Rect.Physical = .{ .x = min_x - half, .y = min_y - half, .w = max_x - min_x + 2 * half, .h = max_y - min_y + 2 * half };
            if (rect.x < target.rect.x - 0.1 or rect.y < target.rect.y - 0.1 or
                rect.x + rect.w > target.rect.x + target.rect.w + 0.1 or
                rect.y + rect.h > target.rect.y + target.rect.h + 0.1) continue;
            if (bounds == null or rect.w * rect.h > bounds.?.w * bounds.?.h) bounds = rect;
        },
        else => {},
    };
    return bounds orelse error.WizardControlBorderNotRendered;
}

fn renderedFont(key: []const u8, size: f32) !void {
    try renderedAppearance(key, size, null);
}

fn renderedAppearance(key: []const u8, size: f32, expected_color: ?dvui.Color) !void {
    const target = try dvui.testing.tagGet(key);
    var found = false;
    for (Frame.render_commands) |command| switch (command.cmd) {
        .text => |text| {
            if (text.text.len == 0) continue;
            const center = text.rs.r.center();
            if (center.x < target.rect.x or center.x > target.rect.x + target.rect.w or
                center.y < target.rect.y or center.y > target.rect.y + target.rect.h) continue;
            // Design sizes are EM pixels; Font.size is the capital-M height.
            const expected_height = bento_theme.fontSized(size).textHeight();
            const actual_height = text.font.textHeight();
            errdefer std.debug.print("renderedAppearance: tag={s} text={s} design-pixels={d} expected-height={d} actual-height={d} scale={d} rect={any} color={any} tvg={any}\n", .{ key, text.text, size, expected_height, actual_height, text.rs.s, text.rs.r, text.color, dvui.useTvg });
            try std.testing.expectApproxEqAbs(expected_height, actual_height, 0.01);
            if (expected_color) |color| try std.testing.expectEqual(color, text.color);
            try expectInside(command.clip, text.rs.r);
            found = true;
        },
        else => {},
    };
    try std.testing.expect(found);
}

fn renderedCheck(comptime key: []const u8, diameter: f32, icon_size: f32) !void {
    // Inspect the actual circle and stroke, not just the decorative widget boxes.
    const badge = try dvui.testing.tagGet(key ++ "-selected");
    const icon = try dvui.testing.tagGet(key ++ "-check-icon");
    try std.testing.expectApproxEqAbs(diameter, badge.rect.w, 0.1);
    try std.testing.expectApproxEqAbs(diameter, badge.rect.h, 0.1);
    try std.testing.expectApproxEqAbs(icon_size, icon.rect.w, 0.1);
    try std.testing.expectApproxEqAbs(icon_size, icon.rect.h, 0.1);
    try expectInside(badge.rect, icon.rect);
    try std.testing.expectApproxEqAbs(badge.rect.center().x, icon.rect.center().x, 0.1);
    try std.testing.expectApproxEqAbs(badge.rect.center().y, icon.rect.center().y, 0.1);
    for (dvui.currentWindow().tab_index_prev.items) |entry| {
        try std.testing.expect(entry.widgetId != badge.id and entry.widgetId != icon.id);
    }
    var circle_rendered = false;
    var icon_rendered = false;
    errdefer std.debug.print("renderedCheck: tag={s} circle={any} icon={any} badge={any} icon-rect={any} commands={d}\n", .{ key, circle_rendered, icon_rendered, badge.rect, icon.rect, Frame.render_commands.len });
    for (Frame.render_commands) |command| switch (command.cmd) {
        .pathFillConvex => |fill| {
            if (fill.path.points.len < 8 or !std.meta.eql(fill.opts.color.toColor(), @import("theme.zig").colors.accent)) continue;
            var min_x: f32 = std.math.inf(f32);
            var min_y: f32 = std.math.inf(f32);
            var max_x: f32 = -std.math.inf(f32);
            var max_y: f32 = -std.math.inf(f32);
            for (fill.path.points) |point| {
                min_x = @min(min_x, point.x);
                min_y = @min(min_y, point.y);
                max_x = @max(max_x, point.x);
                max_y = @max(max_y, point.y);
            }
            if (@abs(min_x - badge.rect.x) > 0.5 or @abs(min_y - badge.rect.y) > 0.5 or
                @abs(max_x - badge.rect.x - diameter) > 0.5 or @abs(max_y - badge.rect.y - diameter) > 0.5) continue;
            // A square/rounded rectangle cannot satisfy the common-radius geometry.
            const center = badge.rect.center();
            for (fill.path.points) |point| {
                const dx = point.x - center.x;
                const dy = point.y - center.y;
                try std.testing.expectApproxEqAbs(diameter / 2, @sqrt(dx * dx + dy * dy), 0.6);
            }
            try expectInside(command.clip, badge.rect);
            circle_rendered = true;
        },
        .pathStroke => |stroke| {
            if (!std.meta.eql(stroke.opts.color.toColor(), @import("theme.zig").colors.background) or stroke.path.points.len != 3) continue;
            var min_x: f32 = std.math.inf(f32);
            var min_y: f32 = std.math.inf(f32);
            var max_x: f32 = -std.math.inf(f32);
            var max_y: f32 = -std.math.inf(f32);
            for (stroke.path.points) |point| {
                min_x = @min(min_x, point.x);
                min_y = @min(min_y, point.y);
                max_x = @max(max_x, point.x);
                max_y = @max(max_y, point.y);
            }
            const bounds: dvui.Rect.Physical = .{ .x = min_x, .y = min_y, .w = max_x - min_x, .h = max_y - min_y };
            if (!Frame.textInCard(key, bounds)) continue;
            try expectInside(icon.rect, bounds);
            try std.testing.expectApproxEqAbs(icon.rect.center().x, bounds.center().x, 0.1);
            try std.testing.expectApproxEqAbs(icon.rect.center().y, bounds.center().y, 0.1);
            try std.testing.expect(bounds.w >= icon_size * 0.5 and bounds.h >= icon_size * 0.5 - 0.1);
            try expectInside(command.clip, icon.rect);
            icon_rendered = true;
        },
        else => {},
    };
    try std.testing.expect(circle_rendered and icon_rendered);
}

fn renderedSingleLine(key: []const u8) !void {
    const target = try dvui.testing.tagGet(key);
    var line_y: ?f32 = null;
    for (Frame.render_commands) |command| switch (command.cmd) {
        .text => |text| {
            if (text.text.len == 0) continue;
            const center = text.rs.r.center();
            if (center.x < target.rect.x or center.x > target.rect.x + target.rect.w or
                center.y < target.rect.y or center.y > target.rect.y + target.rect.h) continue;
            if (line_y) |y| {
                try std.testing.expectApproxEqAbs(y, text.rs.r.y, 0.1);
            } else line_y = text.rs.r.y;
            try expectInside(command.clip, text.rs.r);
        },
        else => {},
    };
    try std.testing.expect(line_y != null);
}

fn renderedTextEquals(key: []const u8, expected: []const u8) !void {
    const target = try dvui.testing.tagGet(key);
    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(std.testing.allocator);
    for (Frame.render_commands) |command| switch (command.cmd) {
        .text => |text| {
            if (text.text.len == 0) continue;
            const center = text.rs.r.center();
            if (center.x < target.rect.x or center.x > target.rect.x + target.rect.w or
                center.y < target.rect.y or center.y > target.rect.y + target.rect.h) continue;
            try expectInside(command.clip, text.rs.r);
            try actual.appendSlice(std.testing.allocator, text.text);
        },
        else => {},
    };
    try std.testing.expectEqualStrings(expected, actual.items);
}

fn wizardHeading(title_text: []const u8, prefix_text: []const u8) !dvui.Rect.Physical {
    _ = try Frame.tagged("instance-wizard-title", false);
    _ = try Frame.tagged("instance-wizard-prefix", false);
    try renderedTextEquals("instance-wizard-title", title_text);
    try renderedTextEquals("instance-wizard-prefix", prefix_text);
    try renderedAppearance("instance-wizard-title", 24, dvui.themeGet().text);
    try renderedAppearance("instance-wizard-prefix", 24, @import("theme.zig").colors.muted);
    // The prefix and title share the title font; only their colors differ.
    for ([_][]const u8{ "instance-wizard-title", "instance-wizard-prefix" }) |key| {
        const target = try dvui.testing.tagGet(key);
        var rendered = false;
        for (Frame.render_commands) |command| switch (command.cmd) {
            .text => |text| {
                const center = text.rs.r.center();
                if (center.x < target.rect.x or center.x > target.rect.x + target.rect.w or center.y < target.rect.y or center.y > target.rect.y + target.rect.h) continue;
                try std.testing.expectEqualDeep(@import("theme.zig").titleFont(), text.font);
                rendered = true;
            },
            else => {},
        };
        try std.testing.expect(rendered);
    }
    const title = try renderedTextBounds("instance-wizard-title");
    const prefix = try renderedTextBounds("instance-wizard-prefix");
    const gap = title.x - prefix.x - prefix.w;
    try std.testing.expect(gap >= 4 - 0.1 and gap <= 12 + 0.1);
    try std.testing.expect(prefix.center().y >= title.y - 0.1 and prefix.center().y <= title.y + title.h + 0.1);
    return title;
}

fn wizardColumn() !dvui.Rect.Physical {
    const body = (try dvui.testing.tagGet("wizard-test-body")).rect;
    const column = try layoutElement("instance-wizard-column");
    try std.testing.expectApproxEqAbs(body.w, column.w, 0.1);
    try std.testing.expectApproxEqAbs(body.x, column.x, 0.1);
    if (dvui.windowRectPixels().w >= 1280) try std.testing.expect(column.w > 800);
    return column;
}

fn catalogueCard(comptime key: []const u8, rendered_name: ?Frame.Text, rendered_date: ?Frame.Text, selected: bool) !void {
    const card = (try Frame.tagged(key, true)).rect;
    const name = rendered_name orelse return error.WizardCatalogueNameNotRendered;
    const date = rendered_date orelse return error.WizardCatalogueDateNotRendered;
    const name_label = try layoutElement(key ++ "-name");
    const date_label = try layoutElement(key ++ "-date");
    const slot = try layoutElement(key ++ "-check-slot");
    try std.testing.expect(card.h >= @import("style.zig").cards.version_height);
    try expectInside(card, name.rect);
    try expectInside(card, date.rect);
    try expectInside(name_label, name.rect);
    try expectInside(date_label, date.rect);
    try expectInside(name.clip, name.rect);
    try expectInside(date.clip, date.rect);
    try std.testing.expectApproxEqAbs(bento_theme.headingFont().textHeight(), name.font.textHeight(), 0.01);
    try std.testing.expectApproxEqAbs(bento_theme.captionFont().textHeight(), date.font.textHeight(), 0.01);
    // The current row reserves the date and check at the right of the title.
    try std.testing.expect(name.rect.x + name.rect.w <= date_label.x + 0.1);
    try std.testing.expect(name_label.x + name_label.w <= date_label.x + 0.1);
    try std.testing.expectApproxEqAbs(name_label.center().y, date_label.center().y, 0.1);
    try std.testing.expectApproxEqAbs(date_label.x + date_label.w, slot.x, 0.1);
    try expectInside(card, slot);
    // The native outer tag includes the Bento card leading gap.
    try std.testing.expectApproxEqAbs(bento_theme.sizing.selection_diameter + bento_theme.style.cards.version_gap, slot.w, 0.1);
    try std.testing.expectApproxEqAbs(bento_theme.sizing.selection_diameter, slot.h, 0.1);
    try std.testing.expect(slot.center().x > card.x + card.w * 0.75);
    try std.testing.expectApproxEqAbs(card.center().y, slot.center().y, 0.1);
    try std.testing.expect(name_label.x + name_label.w <= slot.x + 0.1);
    if (selected) {
        const check = try layoutElement(key ++ "-selected");
        try expectInside(slot, check);
        try std.testing.expectApproxEqAbs(slot.x + bento_theme.style.cards.version_gap, check.x, 0.1);
        try std.testing.expect(name_label.x + name_label.w + bento_theme.style.cards.version_gap <= check.x + 0.1);
        try renderedCheck(key, bento_theme.sizing.selection_diameter, bento_theme.sizing.selection_icon);
    } else {
        try std.testing.expect(dvui.tagGet(key ++ "-selected") == null);
        try std.testing.expect(dvui.tagGet(key ++ "-check-icon") == null);
    }
}

fn catalogueGeometry(loader: bool) !void {
    errdefer {
        std.debug.print("catalogueGeometry failed: loader={any}, window={any}\n", .{ loader, dvui.windowRectPixels() });
        const diagnostic_tags: []const []const u8 = if (loader)
            &.{ "wizard-test-body", "instance-wizard-title", "instance-loader-search", "instance-wizard-loader-list", "instance-loader-fabric-0.16.0", "instance-wizard-footer", "instance-loader-kind-fabric", "instance-loader-kind-forge", "instance-loader-kind-neoforge", "instance-loader-kind-quilt" }
        else
            &.{ "wizard-test-body", "instance-wizard-title", "instance-version-search", "instance-wizard-version-list", "instance-version-1.21.1", "instance-wizard-footer", "instance-version-filter-release", "instance-version-filter-snapshot", "instance-version-filter-old" };
        for (diagnostic_tags) |key| {
            if (dvui.tagGet(key)) |tag| {
                std.debug.print("  {s}: rect={any}, visible={any}\n", .{ key, tag.rect, tag.visible });
            } else std.debug.print("  {s}: missing\n", .{key});
        }
    }
    const title = try wizardHeading(if (loader) "选择 Mod 加载器" else "选择 Minecraft 版本", if (loader) "2/3" else "1/3");
    const column = try wizardColumn();
    const compact = dvui.windowRectPixels().h < 480;
    const section_gap: f32 = if (compact) 8 else 16;
    if (loader) {
        _ = try loadingFeedback(true, false);
    } else _ = try loadingFeedback(false, false);
    const search = try renderedControlBounds(if (loader) "instance-loader-search" else "instance-version-search");
    var row = (try Frame.tagged(if (loader) "instance-loader-fabric-0.16.0" else "instance-version-1.21.1", true)).rect;
    const tabs: []const []const u8 = if (loader) &.{ "instance-loader-kind-fabric", "instance-loader-kind-forge", "instance-loader-kind-neoforge", "instance-loader-kind-quilt" } else &.{ "instance-version-filter-release", "instance-version-filter-snapshot", "instance-version-filter-old" };
    var tabs_bottom: f32 = title.y + title.h;
    for (tabs) |name| {
        _ = try Frame.tagged(name, true);
        const tab = try renderedControlBounds(name);
        try std.testing.expectApproxEqAbs(@as(f32, 48), tab.h, 0.1);
        try renderedFont(name, 16);
        try std.testing.expect(tab.y >= title.y + title.h + section_gap - 0.1);
        tabs_bottom = @max(tabs_bottom, tab.y + tab.h);
    }
    const group = try layoutElement(if (loader) "instance-loader-kinds" else "instance-version-filters");
    // Search follows the full flexbox, including every wrapped filter row.
    try std.testing.expect(tabs_bottom <= group.y + group.h + 0.1);
    try std.testing.expect(group.y + group.h <= search.y + 0.1);
    // Wrapped rows and the loading slot must clear the search control.
    try std.testing.expect(tabs_bottom + (if (compact) @as(f32, 4) else 12) <= search.y + 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 48), search.h, 0.1);
    try renderedFont(if (loader) "instance-loader-search" else "instance-version-search", 16);
    try std.testing.expect(search.y + search.h + section_gap <= row.y + 0.1);
    try std.testing.expect(row.w >= column.w * 0.85);
    const list = try layoutElement(if (loader) "instance-wizard-loader-list" else "instance-wizard-version-list");
    const footer = try renderedControlBounds("instance-wizard-next");
    try expectInside(list, row.intersect(list));
    try std.testing.expect(list.y + list.h + @import("theme.zig").spacing.footer_gap <= footer.y + 0.1);
    if (list.h < row.h) {
        try dvui.testing.moveTo(if (loader) "instance-wizard-loader-list" else "instance-wizard-version-list");
        _ = try dvui.currentWindow().addEventMouseWheel(-@import("theme.zig").spacing.detail_gap, .vertical, null);
        try dvui.testing.settle(Frame.draw);
        try std.testing.expectEqual(footer, try renderedControlBounds("instance-wizard-next"));
        const moved = (try dvui.testing.tagGet(if (loader) "instance-loader-fabric-0.16.0" else "instance-version-1.21.1")).rect;
        try std.testing.expect(moved.y < row.y - 0.1);
        row = moved;
    }
    if (loader) try clippedControl("instance-loader-fabric-0.16.0", list) else try clippedControl("instance-version-1.21.1", list);
    if (loader) {
        try catalogueCard("instance-loader-fabric-0.16.0", Frame.loader_name, Frame.loader_date, false);
        const undated = try dvui.testing.tagGet("instance-loader-fabric-0.15.0");
        try std.testing.expect(undated.rect.h >= bento_theme.style.cards.version_height);
        try std.testing.expectApproxEqAbs(row.h, undated.rect.h, 0.1);
        try std.testing.expectApproxEqAbs(row.y + row.h + bento_theme.style.cards.version_gap, undated.rect.y, 0.1);
        try std.testing.expect(dvui.tagGet("instance-loader-fabric-0.15.0-date") == null);
    } else {
        try catalogueCard("instance-version-1.21.1", Frame.version_name, Frame.version_date, false);
        const undated = try dvui.testing.tagGet("instance-version-1.20.1");
        try std.testing.expect(undated.rect.h >= bento_theme.style.cards.version_height);
        try std.testing.expectApproxEqAbs(row.h, undated.rect.h, 0.1);
        try std.testing.expectApproxEqAbs(row.y + row.h + bento_theme.style.cards.version_gap, undated.rect.y, 0.1);
        try std.testing.expect(dvui.tagGet("instance-version-1.20.1-date") == null);
    }
}

fn confirmGeometry() !void {
    const title = try wizardHeading("创建实例", "3/3");
    const column = try wizardColumn();
    const name_row = try layoutElement("instance-wizard-name-row");
    const label = try renderedTextBounds("instance-wizard-name-label");
    _ = try Frame.tagged("instance-wizard-name", true);
    const name = try renderedControlBounds("instance-wizard-name");
    const viewport = try layoutElement("instance-wizard-confirm-body");
    var card = (try dvui.testing.tagGet("instance-wizard-summary-card")).rect;
    const footer = try renderedControlBounds("instance-wizard-install");
    errdefer std.debug.print("confirmation: title={any} name={any} card={any} footer={any}", .{ title, name_row, card, footer });
    try renderedTextEquals("instance-wizard-name-label", "名称:");
    const spacing = @import("theme.zig").spacing;
    const compact = dvui.windowRectPixels().h < 480;
    const section_gap: f32 = if (compact) spacing.compact_field_gap else spacing.field_gap;
    const label_gap: f32 = if (compact) spacing.compact_label_gap else spacing.field_label_gap;
    try std.testing.expect(title.y + title.h + section_gap <= name_row.y + 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 48), name.h, 0.1);
    try renderedFont("instance-wizard-name-label", 16);
    try renderedFont("instance-wizard-name", 16);
    try expectInside(name_row, label);
    try expectInside(name_row, name);
    // Debug capture exposes the actual border before native tag margins.
    const label_border = (try Frame.captured("instance-wizard-name-label")).border;
    const name_border = (try Frame.captured("instance-wizard-name")).border;
    try expectInside(label_border, label);
    try std.testing.expectApproxEqAbs(label_border.y + label_border.h + label_gap, name_border.y, 0.1);
    try std.testing.expect(label.y + label.h + label_gap <= name.y + 0.1);
    try std.testing.expectApproxEqAbs(name_row.x, name.x, 0.1);
    try std.testing.expectApproxEqAbs(name_row.w, name.w, 0.1);
    try std.testing.expect(name.w <= column.w + 0.1);
    try std.testing.expectApproxEqAbs(label.x, name.x, 0.1);
    try std.testing.expect(name.y + name.h + section_gap <= card.y + 0.1);
    try expectInside(viewport, name_row);
    try std.testing.expect(viewport.y + viewport.h + spacing.footer_gap <= footer.y + 0.1);
    // The vertical form can require scrolling at 640×400. Reveal its summary
    // through real input and prove the footer remains fixed while it moves.
    try dvui.testing.moveTo("instance-wizard-confirm-body");
    _ = try dvui.currentWindow().addEventMouseWheel(-100000, .vertical, null);
    try dvui.testing.settle(Frame.draw);
    try std.testing.expectEqual(footer, try renderedControlBounds("instance-wizard-install"));
    card = (try dvui.testing.tagGet("instance-wizard-summary-card")).rect;
    const minecraft = try renderedTextBounds("instance-wizard-summary-minecraft");
    const mod_loader = try renderedTextBounds("instance-wizard-summary-loader");
    const java = try renderedTextBounds("instance-wizard-summary-java");
    try expectInside(card, minecraft);
    try expectInside(card, mod_loader);
    try expectInside(card, java);
    try expectInside(viewport, minecraft);
    try expectInside(viewport, mod_loader);
    try expectInside(viewport, java);
    try std.testing.expect(minecraft.y + minecraft.h + 8 <= mod_loader.y + 0.1);
    try std.testing.expect(mod_loader.y + mod_loader.h + 16 <= java.y + 0.1);
    try renderedFont("instance-wizard-summary-minecraft", 16);
    try renderedFont("instance-wizard-summary-loader", 16);
    try renderedFont("instance-wizard-summary-java", 16);
    const java_id = (try dvui.testing.tagGet("instance-wizard-summary-java")).id;
    for (dvui.currentWindow().tab_index_prev.items) |entry| try std.testing.expect(entry.widgetId != java_id);
    try dvui.testing.moveTo("instance-wizard-confirm-body");
    _ = try dvui.currentWindow().addEventMouseWheel(100000, .vertical, null);
    try dvui.testing.settle(Frame.draw);
    try std.testing.expectEqual(footer, try renderedControlBounds("instance-wizard-install"));
}

fn versionFlow() !void {
    try Frame.footers("instance-wizard-next", false);
    try catalogueGeometry(false);
    inline for (.{ "release", "snapshot", "old" }) |filter| _ = try Frame.tagged("instance-version-filter-" ++ filter, true);
    _ = try Frame.tagged("instance-version-search", true);
    try Frame.click("instance-version-filter-snapshot");
    _ = try Frame.tagged("instance-version-24w14a", true);
    try std.testing.expect(dvui.tagGet("instance-version-1.21.1") == null);
    try Frame.click("instance-version-filter-old");
    try std.testing.expect(dvui.tagGet("instance-version-1.21.1") == null);
    try std.testing.expect(dvui.tagGet("instance-version-1.6.4") == null);
    try Frame.click("instance-version-filter-release");
    try Frame.replace("instance-version-search", "1.21.1");
    try std.testing.expect(dvui.tagGet("instance-version-1.20.1") == null);
    const unselected_name = try layoutElement("instance-version-1.21.1-name");
    const unselected_slot = try layoutElement("instance-version-1.21.1-check-slot");
    try Frame.click("instance-version-1.21.1");
    try std.testing.expectApproxEqAbs(unselected_name.w, (try layoutElement("instance-version-1.21.1-name")).w, 0.1);
    try std.testing.expectApproxEqAbs(unselected_name.x, (try layoutElement("instance-version-1.21.1-name")).x, 0.1);
    try std.testing.expectApproxEqAbs(unselected_slot.w, (try layoutElement("instance-version-1.21.1-check-slot")).w, 0.1);
    try catalogueCard("instance-version-1.21.1", Frame.version_name, Frame.version_date, true);
    try std.testing.expectEqualStrings("1.21.1", Frame.ui.draft.base.?);
    try std.testing.expect(Frame.ui.draft.base.?.ptr != catalogue_entries[0].id.ptr);
    try std.testing.expectEqualStrings("1.21.1-3", std.mem.sliceTo(&Frame.ui.draft.name, 0));
    try Frame.click("instance-wizard-next");
    try std.testing.expectEqual(wizard.CreateStep.loader, Frame.ui.create_step);
    try Frame.footers("instance-wizard-next", true);
    // With no loader selected the real footer action skips directly to vanilla confirmation.
    try Frame.click("instance-wizard-next");
    try std.testing.expectEqual(wizard.CreateStep.confirm, Frame.ui.create_step);
    try std.testing.expectEqual(config.Loader.vanilla, Frame.ui.draft.loader);
    try Frame.footers("instance-wizard-install", true);
    try confirmGeometry();
    const name = try Frame.tagged("instance-wizard-name", true);
    try std.testing.expectEqual(name.id, dvui.focusedWidgetId().?);
    // No click, clear, or synthetic selection: entering confirm must select the default.
    try dvui.testing.writeText("Personal world");
    try dvui.testing.settle(Frame.draw);
    try std.testing.expectEqualStrings("Personal world", std.mem.sliceTo(&Frame.ui.draft.name, 0));
    try std.testing.expect(Frame.ui.name_custom);
    try Frame.click("instance-wizard-previous");
    try Frame.click("instance-wizard-next");
    try std.testing.expectEqualStrings("Personal world", std.mem.sliceTo(&Frame.ui.draft.name, 0));
    try std.testing.expect(dvui.focusedWidgetId() != (try dvui.testing.tagGet("instance-wizard-name")).id);
    try Frame.click("instance-wizard-name");
    try dvui.testing.pressKey(.end, .none);
    // End defers its cursor move until text layout; process it before the text event.
    try dvui.testing.settle(Frame.draw);
    try dvui.testing.writeText("!");
    try dvui.testing.settle(Frame.draw);
    try std.testing.expectEqualStrings("Personal world!", std.mem.sliceTo(&Frame.ui.draft.name, 0));
    try dvui.testing.moveTo("instance-wizard-confirm-body");
    _ = try dvui.currentWindow().addEventMouseWheel(-100000, .vertical, null);
    try dvui.testing.settle(Frame.draw);
    try std.testing.expect(Frame.java21 and Frame.minecraft1211);
    try std.testing.expectEqual(@as(usize, 1), Frame.catalogue_calls.load(.monotonic));
}

fn selectedLoaderFlow() !void {
    try wizard.chooseBase(Frame.ui, Frame.store.snapshot(), "1.21.1");
    try wizard.advanceCreateStep(Frame.ui);
    try Frame.manager.loadLoaders("1.21.1", .fabric);
    try dvui.testing.settle(Frame.draw);
    inline for (.{ "fabric", "forge", "neoforge", "quilt" }) |kind| _ = try Frame.tagged("instance-loader-kind-" ++ kind, true);
    _ = try Frame.tagged("instance-loader-search", true);
    try catalogueGeometry(true);
    try Frame.replace("instance-loader-search", "0.16");
    try std.testing.expect(dvui.tagGet("instance-loader-fabric-0.15.0") == null);
    const unselected_name = try layoutElement("instance-loader-fabric-0.16.0-name");
    const unselected_slot = try layoutElement("instance-loader-fabric-0.16.0-check-slot");
    try Frame.click("instance-loader-fabric-0.16.0");
    try std.testing.expectApproxEqAbs(unselected_name.w, (try layoutElement("instance-loader-fabric-0.16.0-name")).w, 0.1);
    try std.testing.expectApproxEqAbs(unselected_name.x, (try layoutElement("instance-loader-fabric-0.16.0-name")).x, 0.1);
    try std.testing.expectApproxEqAbs(unselected_slot.w, (try layoutElement("instance-loader-fabric-0.16.0-check-slot")).w, 0.1);
    try catalogueCard("instance-loader-fabric-0.16.0", Frame.loader_name, Frame.loader_date, true);
    try std.testing.expectEqualStrings("0.16.0", Frame.ui.draft.loader_version.?);
    try std.testing.expectEqualStrings("1.21.1-Fabric-3", std.mem.sliceTo(&Frame.ui.draft.name, 0));
    try Frame.click("instance-wizard-next");
    try Frame.footers("instance-wizard-install", true);
    try confirmGeometry();
    try dvui.testing.moveTo("instance-wizard-confirm-body");
    _ = try dvui.currentWindow().addEventMouseWheel(-100000, .vertical, null);
    try dvui.testing.settle(Frame.draw);
    try std.testing.expect(Frame.minecraft1211 and Frame.fabric016 and Frame.java21);
    // A completed preview for a different base must never advertise its Java major.
    Frame.ui.java_preview = .{ .version = "1.20.1", .java_major = 17, .phase = .complete };
    try dvui.testing.settle(Frame.draw);
    try std.testing.expect(!Frame.java17 and !Frame.java21);
    try std.testing.expect(Frame.fabric016 and Frame.minecraft1211);
    const java_summary = try dvui.testing.tagGet("instance-wizard-summary-java");
    try expectInside((try dvui.testing.tagGet("wizard-test-body")).rect, java_summary.rect);
    for (dvui.currentWindow().tab_index_prev.items) |entry| try std.testing.expect(entry.widgetId != java_summary.id);
    try std.testing.expectEqual(@as(usize, 1), Frame.catalogue_calls.load(.monotonic));
    // Exercise the longest loader footer through the real catalogue and row actions.
    try Frame.click("instance-wizard-previous");
    try Frame.click("instance-loader-kind-neoforge");
    try Frame.click("instance-loader-neoforge-0.16.0");
    try Frame.footers("instance-wizard-next", true);
    const label = try dvui.testing.tagGet("instance-wizard-next-label");
    var neoforge_visible = false;
    for (Frame.render_commands) |command| switch (command.cmd) {
        .text => |text| {
            if (std.mem.indexOf(u8, text.text, "NeoForge") == null) continue;
            const center = text.rs.r.center();
            if (center.x < label.rect.x or center.x > label.rect.x + label.rect.w or
                center.y < label.rect.y or center.y > label.rect.y + label.rect.h) continue;
            try expectInside(label.rect, text.rs.r);
            try expectInside(command.clip, text.rs.r);
            neoforge_visible = true;
        },
        else => {},
    };
    try std.testing.expect(neoforge_visible);
}

fn disabledInstallFlow() !void {
    try wizard.chooseBase(Frame.ui, Frame.store.snapshot(), "1.21.1");
    try wizard.advanceCreateStep(Frame.ui);
    try wizard.advanceCreateStep(Frame.ui);
    try dvui.testing.settle(Frame.draw);
    for ([_][]const u8{ "Taken", "bad/name", "" }) |invalid| {
        try Frame.replace("instance-wizard-name", invalid);
        try Frame.footers("instance-wizard-install", false);
        const install = try Frame.tagged("instance-wizard-install", false);
        _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = install.rect.center() });
        try dvui.testing.click(.left);
        try dvui.testing.settle(Frame.draw);
        try std.testing.expect(Frame.ui.pending == null and !Frame.ui.submitted);
        // Keyboard traversal must also omit the disabled installation action.
        const count = dvui.currentWindow().tab_index_prev.items.len;
        for (0..count + 1) |_| {
            try dvui.testing.pressKey(.tab, .none);
            try dvui.testing.settle(Frame.draw);
            try std.testing.expect(dvui.focusedWidgetId() != install.id);
        }
    }
    try Frame.replace("instance-wizard-name", "Valid custom");
    try Frame.footers("instance-wizard-install", true);
    try Frame.click("instance-wizard-previous");
    try Frame.click("instance-wizard-previous");
    // Search makes the second catalogue entry visible before the real mouse click.
    try Frame.replace("instance-version-search", "1.20.1");
    try Frame.click("instance-version-1.20.1");
    try std.testing.expectEqualStrings("Valid custom", std.mem.sliceTo(&Frame.ui.draft.name, 0));
    try Frame.click("instance-wizard-next");
    try Frame.click("instance-wizard-next");
    try std.testing.expectEqualStrings("Valid custom", std.mem.sliceTo(&Frame.ui.draft.name, 0));
    try std.testing.expect(!Frame.java21);
    const home = Frame.home orelse return error.WizardHomeFooterMissing;
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = home.rect.center() });
    try dvui.testing.click(.left);
    try dvui.testing.settle(Frame.draw);
    try std.testing.expect(Frame.home_clicked);
}

fn renderedMessage(message: []const u8) !bool {
    // A wrapped message can span several render commands. Only collect text
    // whose glyph bounds are fully visible in the retained frame.
    var visible: std.ArrayList(u8) = .empty;
    defer visible.deinit(std.testing.allocator);
    for (Frame.render_commands) |command| switch (command.cmd) {
        .text => |text| {
            const rect = text.rs.r;
            if (rect.x < command.clip.x - 0.1 or rect.y < command.clip.y - 0.1 or
                rect.x + rect.w > command.clip.x + command.clip.w + 0.1 or
                rect.y + rect.h > command.clip.y + command.clip.h + 0.1) continue;
            try visible.appendSlice(std.testing.allocator, text.text);
        },
        else => {},
    };
    return std.mem.indexOf(u8, visible.items, message) != null;
}

fn pathBounds(points: []const dvui.Point.Physical) ?dvui.Rect.Physical {
    if (points.len < 2) return null;
    var min_x: f32 = std.math.inf(f32);
    var min_y: f32 = std.math.inf(f32);
    var max_x: f32 = -std.math.inf(f32);
    var max_y: f32 = -std.math.inf(f32);
    for (points) |point| {
        min_x = @min(min_x, point.x);
        min_y = @min(min_y, point.y);
        max_x = @max(max_x, point.x);
        max_y = @max(max_y, point.y);
    }
    return .{ .x = min_x, .y = min_y, .w = max_x - min_x, .h = max_y - min_y };
}

fn loadingGraphicCount(slot: dvui.Rect.Physical) usize {
    var count: usize = 0;
    for (Frame.render_commands) |command| {
        const bounds: ?dvui.Rect.Physical = switch (command.cmd) {
            .pathStroke => |stroke| pathBounds(stroke.path.points),
            .pathFillConvex => |fill| pathBounds(fill.path.points),
            .triangles => |mesh| mesh.tri.bounds,
            else => null,
        };
        const rect = bounds orelse continue;
        if (rect.w < 1 or rect.h < 1) continue;
        if (rect.x < slot.x - 0.5 or rect.y < slot.y - 0.5 or
            rect.x + rect.w > slot.x + slot.w + 0.5 or
            rect.y + rect.h > slot.y + slot.h + 0.5) continue;
        if (rect.x < command.clip.x - 0.5 or rect.y < command.clip.y - 0.5 or
            rect.x + rect.w > command.clip.x + command.clip.w + 0.5 or
            rect.y + rect.h > command.clip.y + command.clip.h + 0.5) continue;
        count += 1;
    }
    return count;
}

fn loadingFeedback(comptime loader: bool, loading: bool) !dvui.Rect.Physical {
    const active_key = if (loader) "instance-loader-loading" else "instance-version-loading";
    const slot_key = active_key ++ "-slot";
    _ = try Frame.tagged(slot_key, false);
    const slot = (try Frame.captured(slot_key)).content;
    try std.testing.expectApproxEqAbs(@as(f32, 20), slot.w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 48), slot.h, 0.1);
    const group = try layoutElement(if (loader) "instance-loader-kinds" else "instance-version-filters");
    const last = try renderedControlBounds(if (loader) "instance-loader-kind-quilt" else "instance-version-filter-old");
    const search = try renderedControlBounds(if (loader) "instance-loader-search" else "instance-version-search");
    try expectInside(group, slot);
    try std.testing.expect(slot.y + slot.h <= search.y + 0.1);
    // Native control tags include margins. Overlapping vertical intervals
    // identify a shared flex row without equating unequal outer centers.
    const overlap = @min(slot.y + slot.h, last.y + last.h) - @max(slot.y, last.y);
    if (overlap > 0.1) {
        try std.testing.expect(last.x + last.w <= slot.x + 0.1);
    } else try std.testing.expect(last.y + last.h <= slot.y + 0.1);
    if (loading) {
        _ = try Frame.tagged(active_key, false);
        const spinner = (try Frame.captured(active_key)).border;
        try expectInside(slot, spinner);
        try std.testing.expectApproxEqAbs(@as(f32, 20), spinner.w, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 20), spinner.h, 0.1);
        try std.testing.expectApproxEqAbs(slot.center().y, spinner.center().y, 0.1);
        if (overlap > 0.1) try std.testing.expectApproxEqAbs(last.center().y, spinner.center().y, 0.1);
        try std.testing.expect(loadingGraphicCount(spinner) > 0);
    } else {
        try std.testing.expect(dvui.tagGet(active_key) == null);
        try std.testing.expectEqual(@as(usize, 0), loadingGraphicCount(slot));
    }
    try std.testing.expect(!try renderedMessage("正在获取"));
    return slot;
}

fn versionMetadataStates() !void {
    const idle_slot = try loadingFeedback(false, false);
    const idle_filters = try layoutElement("instance-version-filters");
    const idle_search = try renderedControlBounds("instance-version-search");
    Frame.catalogue.available = &.{};
    Frame.catalogue.phase = .loading;
    try std.testing.expect(try Frame.boundedFrames() != null);
    try std.testing.expectEqual(idle_slot, try loadingFeedback(false, true));
    try std.testing.expectEqual(idle_filters, try layoutElement("instance-version-filters"));
    try std.testing.expectEqual(idle_search, try renderedControlBounds("instance-version-search"));
    try Frame.footers("instance-wizard-next", false);
    try std.testing.expect(dvui.tagGet("instance-version-1.21.1") == null);
    try std.testing.expect(!try renderedMessage("暂无版本，请刷新列表"));
    Frame.catalogue.phase = .complete;
    try dvui.testing.settle(Frame.draw);
    _ = try loadingFeedback(false, false);
    try std.testing.expect(try renderedMessage("暂无版本，请刷新列表"));
    try Frame.footers("instance-wizard-next", false);
    Frame.catalogue.phase = .failed;
    Frame.catalogue.failure = error.TestVersionCatalogueUnavailable;
    try dvui.testing.settle(Frame.draw);
    _ = try loadingFeedback(false, false);
    try std.testing.expect(try renderedMessage("TestVersionCatalogueUnavailable"));
    try reachableRetry("instance-wizard-version-list");
    try Frame.footers("instance-wizard-next", false);
    Frame.catalogue.phase = .idle;
    Frame.catalogue.failure = null;
    try dvui.testing.settle(Frame.draw);
    _ = try loadingFeedback(false, false);
    Frame.catalogue.phase = .complete;
    Frame.catalogue.available = &catalogue_entries;
    try dvui.testing.settle(Frame.draw);
    _ = try loadingFeedback(false, false);
    Frame.catalogue.available = &.{};
    Frame.catalogue.phase = .loading;
    try std.testing.expect(try Frame.boundedFrames() != null);
    _ = try loadingFeedback(false, true);
    try Frame.click("instance-wizard-cancel");
    try std.testing.expect(Frame.ui.mode != .create);
    try std.testing.expect(dvui.tagGet("instance-version-loading") == null);
}

fn loaderMetadataStates() !void {
    try wizard.chooseBase(Frame.ui, Frame.store.snapshot(), "1.21.1");
    try wizard.advanceCreateStep(Frame.ui);
    try Frame.manager.loadLoaders("1.21.1", .fabric);
    try dvui.testing.settle(Frame.draw);
    const idle_slot = try loadingFeedback(true, false);
    const idle_filters = try layoutElement("instance-loader-kinds");
    const idle_search = try renderedControlBounds("instance-loader-search");
    Frame.loader_render_phase = .working;
    try std.testing.expect(try Frame.boundedFrames() != null);
    try std.testing.expectEqual(idle_slot, try loadingFeedback(true, true));
    try std.testing.expectEqual(idle_filters, try layoutElement("instance-loader-kinds"));
    try std.testing.expectEqual(idle_search, try renderedControlBounds("instance-loader-search"));
    try Frame.footers("instance-wizard-next", true);
    try std.testing.expect(dvui.tagGet("instance-loader-fabric-0.16.0") == null);
    try std.testing.expect(!try renderedMessage("此 Minecraft 版本暂无可用加载器版本，可继续使用原版。"));
    Frame.loader_render_phase = .canceled;
    try dvui.testing.settle(Frame.draw);
    _ = try loadingFeedback(true, false);
    Frame.loader_render_phase = null;
    Frame.fetch_outcome = .empty;
    Frame.ui.browse_loader = .quilt;
    try Frame.manager.loadLoaders("1.21.1", .quilt);
    try dvui.testing.settle(Frame.draw);
    _ = try loadingFeedback(true, false);
    try std.testing.expect(try renderedMessage("此 Minecraft 版本暂无可用加载器版本，可继续使用原版。"));
    try Frame.footers("instance-wizard-next", true);
    Frame.fetch_outcome = .non_public_address;
    Frame.ui.browse_loader = .neoforge;
    try Frame.manager.loadLoaders("1.21.1", .neoforge);
    try dvui.testing.settle(Frame.draw);
    _ = try loadingFeedback(true, false);
    try std.testing.expectEqual(error.NonPublicAddress, Frame.manager.loaderSnapshot().failure.?);
    try std.testing.expect(try renderedMessage("此 Minecraft 版本暂无可用加载器版本，可继续使用原版。"));
    try std.testing.expect(!try renderedMessage("加载器目录：NonPublicAddress"));
    try std.testing.expect(!try renderedMessage("NonPublicAddress"));
    try std.testing.expect(!try renderedMessage("重试"));
    try Frame.footers("instance-wizard-next", true);
    Frame.fetch_outcome = .failed;
    Frame.ui.browse_loader = .forge;
    try Frame.manager.loadLoaders("1.21.1", .forge);
    try dvui.testing.settle(Frame.draw);
    _ = try loadingFeedback(true, false);
    try std.testing.expect(try renderedMessage("加载器目录：TestLoaderCatalogueUnavailable"));
    try reachableRetry("instance-wizard-loader-list");
    try Frame.footers("instance-wizard-next", true);
    Frame.loader_render_phase = .idle;
    try dvui.testing.settle(Frame.draw);
    _ = try loadingFeedback(true, false);
    Frame.loader_render_phase = .working;
    try std.testing.expect(try Frame.boundedFrames() != null);
    _ = try loadingFeedback(true, true);
    try Frame.click("instance-wizard-previous");
    Frame.loader_render_phase = null;
    try std.testing.expectEqual(wizard.CreateStep.version, Frame.ui.create_step);
    try std.testing.expect(dvui.tagGet("instance-loader-loading") == null);
}

test "UI layout instance wizard version filters rows skip and default selection use real events" {
    try atBothSizes(versionFlow);
}

test "UI layout instance wizard loader search rows naming and Java summary guard" {
    try atBothSizes(selectedLoaderFlow);
}

test "UI layout instance wizard invalid names disable mouse and tab submission while custom names persist" {
    try atBothSizes(disabledInstallFlow);
}

test "UI layout instance wizard version metadata loading empty error and cancellation render honestly" {
    try atBothSizes(versionMetadataStates);
}

test "UI layout instance wizard loader metadata spinner states preserve filters and vanilla navigation" {
    try atBothSizes(loaderMetadataStates);
}

const ServerCheckFrame = struct {
    var name: [64]u8 = @splat(0);
    fn draw() !dvui.App.Result {
        const win = dvui.currentWindow();
        var commands: std.ArrayList(dvui.RenderCommand) = .empty;
        const previous_commands = win.defer_render_cmds;
        const previous_rendering = win.render_target.rendering;
        win.defer_render_cmds = &commands;
        win.render_target.rendering = false;
        defer {
            win.defer_render_cmds = previous_commands;
            win.render_target.rendering = previous_rendering;
        }
        {
            const body = dvui.box(@src(), .{}, .{ .expand = .both, .padding = dvui.Rect.all(24) });
            defer body.deinit();
            {
                const brand = dvui.box(@src(), .{}, .{ .tag = "shared-home-brand", .expand = .horizontal, .padding = dvui.Rect.all(0), .margin = dvui.Rect.all(0) });
                defer brand.deinit();
                components.sidebarTitle(@src(), "Vela Launcher", dvui.windowRect().w < 900);
            }
            _ = components.selectionCard(@src(), "server-check-regression", "Local server", .{ .selected = true, .tag = "server-check-regression", .description = "localhost:25565" });
            _ = components.button(@src(), "Default button", .{ .tag = "shared-default-button" });
            _ = components.field(@src(), "Name", &name, .{ .tag = "shared-default-field" });
            {
                const icons = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = dvui.Rect.all(0), .margin = dvui.Rect.all(0) });
                defer icons.deinit();
                _ = components.iconButton(@src(), "Default icon", dvui.entypo.cross, .{ .tag = "shared-default-icon" });
                // Explicit task semantics retain a compact square beside the default icon.
                _ = components.iconButton(@src(), "Cancel task", dvui.entypo.cross, .{ .tag = "shared-task-icon", .size = @import("theme.zig").sizing.task_icon_button });
            }
        }
        try Frame.retainRenderCommands(commands.items);
        return .ok;
    }
};

const DisclosureAlignmentFrame = struct {
    fn draw() !dvui.App.Result {
        const win = dvui.currentWindow();
        var commands: std.ArrayList(dvui.RenderCommand) = .empty;
        const previous_commands = win.defer_render_cmds;
        const previous_rendering = win.render_target.rendering;
        win.defer_render_cmds = &commands;
        win.render_target.rendering = false;
        defer {
            win.defer_render_cmds = previous_commands;
            win.render_target.rendering = previous_rendering;
        }
        {
            const body = dvui.box(@src(), .{}, .{ .expand = .both, .padding = dvui.Rect.all(24) });
            defer body.deinit();
            var collapsed = false;
            {
                const group = components.disclosurePanel(@src(), "alignment-group", "Game instances", &collapsed, .{ .tag = "alignment-surface" });
                group.deinit();
            }
            {
                const backups = components.bentoPanel(@src(), .{});
                defer backups.deinit();
                components.disclosure(@src(), "alignment-backups", "Backups", &collapsed, 0);
            }
        }
        try Frame.retainRenderCommands(commands.items);
        return .ok;
    }
};

test "UI layout disclosure headings center actual glyphs at different font sizes" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    for ([_]f32{ 16, 24 }) |font_size| {
        var window = try dvui.testing.init(.{ .window_size = .{ .w = 640, .h = 400 } });
        defer window.deinit();
        Frame.clearRenderCommands();
        defer Frame.clearRenderCommands();
        var theme = dvui.Theme.builtin.adwaita_dark;
        theme.font_body = theme.font_body.withSize(font_size);
        theme.font_heading = theme.font_heading.withSize(font_size);
        window.window.themeSet(theme);
        try dvui.testing.settle(DisclosureAlignmentFrame.draw);
        const header = try dvui.testing.tagGet("alignment-group");
        for ([_][]const u8{ "Game instances", "Backups" }) |text_value| {
            var found = false;
            for (Frame.render_commands) |command| switch (command.cmd) {
                .text => |text| {
                    if (!std.mem.eql(u8, text.text, text_value)) continue;
                    const label = try dvui.testing.tagGet(if (std.mem.eql(u8, text_value, "Backups")) "alignment-backups-label" else "alignment-group-label");
                    try std.testing.expectApproxEqAbs(label.rect.center().y, text.rs.r.center().y, 0.1);
                    if (std.mem.eql(u8, text_value, "Game instances")) try std.testing.expectApproxEqAbs(header.rect.center().y, text.rs.r.center().y, 0.1);
                    try expectInside(command.clip, text.rs.r);
                    found = true;
                },
                else => {},
            };
            try std.testing.expect(found);
        }
    }
}

test "UI layout shared controls and home brand keep fixed geometry and server check colors" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    for ([_]dvui.Size{ .{ .w = 640, .h = 400 }, .{ .w = 1280, .h = 720 } }) |size| {
        var window = try dvui.testing.init(.{ .window_size = size });
        defer window.deinit();
        Frame.clearRenderCommands();
        defer Frame.clearRenderCommands();
        window.backend.size_pixels = .{ .w = size.w, .h = size.h };
        @import("theme.zig").install(window.window);
        bento_theme.applyTypography();
        ServerCheckFrame.name = @splat(0);
        @memcpy(ServerCheckFrame.name[0..5], "World");
        try dvui.testing.settle(ServerCheckFrame.draw);
        try renderedFont("shared-home-brand", 24);
        for ([_][]const u8{ "shared-default-button", "shared-default-field", "shared-default-icon" }) |key| {
            const border = try renderedControlBounds(key);
            try expectInside(dvui.windowRectPixels(), border);
            try std.testing.expectApproxEqAbs(@as(f32, 48), border.h, 0.1);
        }
        try std.testing.expectApproxEqAbs(@as(f32, 48), (try renderedControlBounds("shared-default-icon")).w, 0.1);
        const task_icon = try renderedControlBounds("shared-task-icon");
        try expectInside(dvui.windowRectPixels(), task_icon);
        try std.testing.expectApproxEqAbs(@as(f32, 32), task_icon.w, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 32), task_icon.h, 0.1);
        try renderedFont("shared-default-button", 16);
        try renderedFont("shared-default-field", 16);
        try renderedCheck("server-check-regression", 20, 14);
        const card = (try dvui.testing.tagGet("server-check-regression")).rect;
        const check = (try dvui.testing.tagGet("server-check-regression-selected")).rect;
        try expectInside(card, check);
        try std.testing.expect(check.center().x > card.x + card.w * 0.75);
        try std.testing.expectApproxEqAbs(card.y + @import("theme.zig").spacing.panel_compact_padding, check.y, 0.1);
    }
}

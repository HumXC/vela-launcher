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
const vela_theme = @import("ui/theme.zig");
const games = @import("ui/game_library.zig");
const launch = @import("ui/game_launch.zig");
const logs_view = @import("ui/logs_view.zig");
const shutdown_view = @import("ui/shutdown_view.zig");
const lifecycle = @import("core/lifecycle.zig");

comptime {
    _ = @import("ui/avatar_manager.zig");
    _ = @import("ui/avatar_image.zig");
    _ = @import("ui/avatar_layout_tests.zig");
    _ = @import("ui/game_library.zig");
    _ = @import("ui/instances_view.zig");
    _ = @import("ui/instance_wizard_layout_tests.zig");
    _ = @import("ui/instance_settings_layout_tests.zig");
    _ = @import("ui/card_grid_layout_tests.zig");
    _ = @import("ui/logs_layout_tests.zig");
}
const accounts_view = @import("ui/accounts_view.zig");
const accounts_manager = @import("ui/accounts_manager.zig");

test {
    _ = @import("ui/curseforge_key_editor.zig");
    _ = @import("game_selection_tests.zig");
    _ = @import("instances_view_tests.zig");
    _ = @import("server_picker_tests.zig");
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
    var library_phase: games.Phase = .loading;
    var process_phase: launch.Phase = .idle;
    var page: enum { home, games, accounts } = .home;
    var rendered_texts: usize = 0;
    var start_labels: usize = 0;

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
        const root = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .padding = dvui.Rect.all(0), .margin = dvui.Rect.all(0) });
        defer root.deinit();
        // Match the real sidebar's 260px width plus its 16px left margin.
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 276 } });
        const pane = dvui.box(@src(), .{}, .{ .expand = .both, .padding = dvui.Rect.all(if (dvui.windowRect().h < 520) 12 else 32) });
        defer pane.deinit();
        const library: games.Snapshot = .{ .installed = &.{}, .available = &.{}, .phase = library_phase, .failure = null, .completed = 0, .total = 0, .installing_version = null };
        const process: launch.Snapshot = .{ .phase = process_phase, .failure = null, .exit_code = null, .version = null, .version_id = null, .debug = false, .attempt_id = 0 };
        switch (page) {
            .home => try view.drawHome(&state, library, manager, process, &pending, services),
            .games => view.drawGameSelection(&state, library, process, &pending, services),
            .accounts => {
                view.drawAccountSelection(&state, library, process, &pending, services);
                @import("ui/accounts_view.zig").finish(services.accounts_ui.?, services.configuration, services.accounts.?);
            },
        }
        rendered_texts = 0;
        start_labels = 0;
        for (commands.items) |command| switch (command.cmd) {
            .text => |text| {
                rendered_texts += 1;
                if (std.mem.eql(u8, if (process_phase == .preparing) "正在启动" else state.labels.start, text.text)) start_labels += 1;
            },
            else => {},
        };
        return .ok;
    }
};

test "UI layout Home Choose Game and Choose Account reserve Start and preserve native activation gates" {
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
    var account_service = try @import("ui/accounts_manager.zig").Manager.init(a, std.testing.io, root);
    defer account_service.deinit();
    var account_ui = try @import("ui/accounts_view.zig").Ui.init(a);
    defer account_ui.deinit();
    var server_service = server_manager.Manager.initWithQuery(a, std.testing.io, EditorsFrame.rejectQuery);
    defer server_service.deinit();
    var ordinary_creation = try @import("ui/instance_creation_controller.zig").Controller.init(a, std.testing.io, root, .{});
    defer ordinary_creation.deinit(undefined);
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
        .servers = &server_service,
        .ordinary_creation = &ordinary_creation,
        .accounts = &account_service,
        .accounts_ui = &account_ui,
        .logs = undefined,
        .worlds = undefined,
        .worlds_ui = undefined,
    };
    for ([_]struct { size: dvui.Size, page: @TypeOf(HomeFrame.page), account_kind: config.AccountKind = .offline }{
        .{ .size = .{ .w = 640, .h = 400 }, .page = .home },
        .{ .size = .{ .w = 1280, .h = 720 }, .page = .home },
        .{ .size = .{ .w = 640, .h = 400 }, .page = .games },
        .{ .size = .{ .w = 1280, .h = 720 }, .page = .games },
        .{ .size = .{ .w = 640, .h = 400 }, .page = .accounts },
        .{ .size = .{ .w = 1280, .h = 720 }, .page = .accounts },
        .{ .size = .{ .w = 640, .h = 400 }, .page = .accounts, .account_kind = .microsoft },
        .{ .size = .{ .w = 1280, .h = 720 }, .page = .accounts, .account_kind = .microsoft },
    }) |fixture| {
        const size = fixture.size;
        HomeFrame.page = fixture.page;
        if (fixture.page == .accounts) {
            var document = store.snapshot().*;
            document.accounts = &.{.{ .id = "fixture-account", .name = "Player_A", .uuid = "00000000000000000000000000000000", .kind = fixture.account_kind }};
            document.selected_account = "fixture-account";
            try store.update(document);
        }
        HomeFrame.services.allow_mutations = true;
        const start_tag = switch (fixture.page) {
            .home => "home-start",
            .games => "game-selection-start",
            .accounts => "account-selection-start",
        };
        const layout_tag = switch (fixture.page) {
            .home => "home-layout",
            .games => "game-selection-layout",
            .accounts => "account-selection-layout",
        };
        const footer_tag = switch (fixture.page) {
            .home => "home-footer",
            .games => "game-selection-footer",
            .accounts => "account-selection-footer",
        };
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
        HomeFrame.library_phase = .loading;
        HomeFrame.process_phase = .idle;
        HomeFrame.pending = null;
        try std.testing.expectEqual(@as(usize, if (fixture.page == .accounts) 1 else 0), store.snapshot().accounts.len);
        try std.testing.expectEqual(@as(usize, 0), manager.entries().len);
        try dvui.testing.settle(HomeFrame.draw);
        if (fixture.page == .home) try std.testing.expectEqual(@as(usize, 1), HomeFrame.rendered_texts);
        try std.testing.expectEqual(@as(usize, 1), HomeFrame.start_labels);
        const home = try dvui.testing.tagGet(layout_tag);
        const footer = try dvui.testing.tagGet(footer_tag);
        const start = try dvui.testing.tagGet(start_tag);
        try expectInside(.{ .x = 0, .y = 0, .w = size.w, .h = size.h }, home.rect);
        for ([_]dvui.TagData{ footer, start }) |part| {
            try std.testing.expect(part.visible);
            try expectInside(home.rect, part.rect);
        }
        try expectInside(footer.rect, start.rect);
        try std.testing.expectApproxEqAbs(@as(f32, 48), start.rect.h, 0.1);
        try std.testing.expectApproxEqAbs(home.rect.x + home.rect.w, start.rect.x + start.rect.w, 0.1);
        try std.testing.expectApproxEqAbs(home.rect.y + home.rect.h, start.rect.y + start.rect.h, 0.1);
        if (fixture.page != .home) {
            const body = try dvui.testing.tagGet(if (fixture.page == .games) "game-selection-body" else "account-selection-body");
            try std.testing.expect(body.visible);
            try expectInside(home.rect, body.rect);
            try std.testing.expect(body.rect.y + body.rect.h <= footer.rect.y + 0.1);
        }
        if (fixture.page == .games and size.w == 1280) {
            const group = try dvui.testing.tagGet("game-instances-panel");
            const header = try dvui.testing.tagGet("game-instances");
            const servers_before = try dvui.testing.tagGet("game-servers-panel");
            // Tag bounds include the bottom margin separating expanded cards.
            try std.testing.expectApproxEqAbs(@as(f32, 44), header.rect.h - 30, 0.1);
            try std.testing.expectApproxEqAbs(group.rect.x + 24, header.rect.x, 0.1);
            try std.testing.expectApproxEqAbs(group.rect.y + 14, header.rect.y, 0.1);
            try std.testing.expectApproxEqAbs(group.rect.w - 48, header.rect.w, 0.1);
            try dvui.testing.moveTo("game-instances");
            try dvui.testing.settle(HomeFrame.draw);
            try dvui.testing.click(.left);
            try dvui.testing.settle(HomeFrame.draw);
            const collapsed = try dvui.testing.tagGet("game-instances-panel");
            try std.testing.expectApproxEqAbs(@as(f32, 72), collapsed.rect.h - vela_theme.spacing.panel_padding, 0.1);
            try std.testing.expect(dvui.tagGet("game-instance-fixture-game") == null);
            try std.testing.expect((try dvui.testing.tagGet("game-servers-panel")).rect.y < servers_before.rect.y);
            try dvui.testing.expectFocused("game-instances");
            try dvui.testing.pressKey(.enter, .none);
            try dvui.testing.settle(HomeFrame.draw);
            try std.testing.expect(dvui.tagGet("game-instance-fixture-game") != null);
            try std.testing.expectApproxEqAbs(group.rect.h, (try dvui.testing.tagGet("game-instances-panel")).rect.h, 0.1);
            try dvui.testing.moveTo("game-servers");
            try dvui.testing.settle(HomeFrame.draw);
            try dvui.testing.click(.left);
            try dvui.testing.settle(HomeFrame.draw);
            try std.testing.expectApproxEqAbs(@as(f32, 72), (try dvui.testing.tagGet("game-servers-panel")).rect.h - vela_theme.spacing.panel_padding, 0.1);
            try std.testing.expect(dvui.tagGet("game-server-fixture-server") == null);
            try dvui.testing.pressKey(.enter, .none);
            try dvui.testing.settle(HomeFrame.draw);
            try std.testing.expect(dvui.tagGet("game-server-fixture-server") != null);
            try std.testing.expectEqualStrings("fixture-server", store.snapshot().selected_server.?);
            try std.testing.expectEqualStrings("fixture-game", store.snapshot().selected_instance.?);
        }
        for ([_][]const u8{ "home-header", "home-server-target", "home-server-address", "home-server-instance", "task-viewport" }) |tag| {
            try std.testing.expect(dvui.tagGet(tag) == null);
        }
        var tag_buffer: [64]u8 = undefined;
        for (registry.tasks()) |task| {
            for ([_][]const u8{ "row", "title", "status", "progress", "cancel" }) |part| {
                const tag = try std.fmt.bufPrint(&tag_buffer, "task-{d}-{s}", .{ task.id, part });
                try std.testing.expect(dvui.tagGet(tag) == null);
            }
        }
        var start_tabstops: usize = 0;
        for (window.window.tab_index_prev.items) |entry| if (entry.widgetId == start.id) {
            start_tabstops += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), start_tabstops);
        try dvui.testing.moveTo(start_tag);
        try dvui.testing.click(.left);
        try dvui.testing.settle(HomeFrame.draw);
        try std.testing.expect(HomeFrame.pending != null and std.meta.activeTag(HomeFrame.pending.?) == .start);
        try dvui.testing.expectFocused(start_tag);
        HomeFrame.pending = null;
        try dvui.testing.pressKey(.enter, .none);
        try dvui.testing.settle(HomeFrame.draw);
        try std.testing.expect(HomeFrame.pending != null and std.meta.activeTag(HomeFrame.pending.?) == .start);
        if (fixture.page == .accounts) {
            const body = try dvui.testing.tagGet("account-selection-body");
            const edit = try dvui.testing.tagGet("account-edit");
            const add = try dvui.testing.tagGet("account-add");
            const card = try dvui.testing.tagGet("account-card-fixture-account");
            for ([_]dvui.TagData{ edit, add, card }) |part| {
                try std.testing.expect(part.visible);
                try expectInside(body.rect, part.rect);
            }
            try std.testing.expect(edit.rect.x + edit.rect.w <= add.rect.x + 0.1);
            try std.testing.expectApproxEqAbs(edit.rect.y, add.rect.y, 0.1);
            try std.testing.expect(edit.rect.y + edit.rect.h <= card.rect.y + 0.1);
            try std.testing.expect(dvui.tagGet("account-delete") == null);
            try std.testing.expect(dvui.tagGet("account-sign-out") == null);
            try dvui.testing.moveTo("account-edit");
            try dvui.testing.click(.left);
            try dvui.testing.settle(HomeFrame.draw);
            try std.testing.expect(account_ui.editor_open and account_ui.confirmation == null);
            const delete = try dvui.testing.tagGet("account-delete");
            const cancel = try dvui.testing.tagGet("account-cancel");
            try std.testing.expect(delete.visible and cancel.visible);
            var modal_count: usize = 0;
            for (window.window.subwindows.stack.items) |subwindow| if (subwindow.modal) {
                modal_count += 1;
                try expectInside(subwindow.rect_pixels, delete.rect);
                try expectInside(subwindow.rect_pixels, cancel.rect);
            };
            try std.testing.expectEqual(@as(usize, 1), modal_count);
            try expectInside(.{ .x = 0, .y = 0, .w = size.w, .h = size.h }, delete.rect);
            try dvui.testing.moveTo("account-cancel");
            try dvui.testing.click(.left);
            try dvui.testing.settle(HomeFrame.draw);
            try std.testing.expect(!account_ui.editor_open and account_ui.confirmation == null);
            try std.testing.expect(dvui.tagGet("account-delete") == null);
            try dvui.testing.moveTo("account-add");
            try dvui.testing.click(.left);
            try dvui.testing.settle(HomeFrame.draw);
            try std.testing.expect(account_ui.editor_open and account_ui.draft.id == null);
            try std.testing.expect(dvui.tagGet("account-delete") == null);
            try dvui.testing.moveTo("account-cancel");
            try dvui.testing.click(.left);
            try dvui.testing.settle(HomeFrame.draw);
            try std.testing.expect(!account_ui.editor_open and account_ui.failure == null);
            try std.testing.expectEqualStrings("fixture-account", store.snapshot().selected_account.?);
            try std.testing.expectEqualStrings("Player_A", store.snapshot().accounts[0].name);
            try std.testing.expectEqual(start.rect, (try dvui.testing.tagGet(start_tag)).rect);
        }
        for ([_]struct { library: games.Phase, process: launch.Phase, allow_mutations: bool = true, creation_phase: @import("ui/instance_creation_controller.zig").Phase = .idle }{
            .{ .library = .loading, .process = .preparing },
            .{ .library = .loading, .process = .running },
            .{ .library = .installing, .process = .idle },
            .{ .library = .loading, .process = .idle, .allow_mutations = false },
            .{ .library = .loading, .process = .idle, .creation_phase = .preparing },
            .{ .library = .loading, .process = .idle, .creation_phase = .awaiting_publication },
        }) |busy| {
            HomeFrame.library_phase = busy.library;
            HomeFrame.process_phase = busy.process;
            HomeFrame.services.allow_mutations = busy.allow_mutations;
            // Model task snapshots without starting workers, native Java, or network requests.
            ordinary_creation.core.phase = busy.creation_phase;
            HomeFrame.pending = null;
            dvui.focusWidget(null, null, null);
            try dvui.testing.settle(HomeFrame.draw);
            for (window.window.tab_index_prev.items) |entry| try std.testing.expect(entry.widgetId != start.id);
            try dvui.testing.moveTo(start_tag);
            try dvui.testing.click(.left);
            try dvui.testing.settle(HomeFrame.draw);
            try std.testing.expect(HomeFrame.pending == null);
            try dvui.testing.expectNotFocused(start_tag);
            dvui.focusWidget(start.id, null, null);
            try dvui.testing.pressKey(.enter, .none);
            try dvui.testing.settle(HomeFrame.draw);
            try std.testing.expect(HomeFrame.pending == null);
            try std.testing.expectEqual(start.rect, (try dvui.testing.tagGet(start_tag)).rect);
        }
        ordinary_creation.core.phase = .idle;
        dvui.focusWidget(null, null, null);
        try std.testing.expectEqual(@as(usize, 23), registry.tasks().len);
        try std.testing.expectEqualStrings("fixture-server", store.snapshot().selected_server.?);
        try std.testing.expectEqual(start.rect, (try dvui.testing.tagGet(start_tag)).rect);
        for (registry.tasks()) |task| {
            try std.testing.expectEqual(tasks.State.running, task.state);
            try std.testing.expect(!task.canceled());
            const progress = task.progress();
            try std.testing.expectEqual(tasks.Stage.scanning, progress.stage);
            try std.testing.expectEqual(@as(u64, 42), progress.completed);
            try std.testing.expectEqual(@as(?u64, 100), progress.total);
        }
    }
}

const ServerCardFrame = struct {
    var status: *const servers.OwnedStatus = undefined;
    var rendered_instance = false;
    var rendered_motd = false;
    var rendered_counts = false;
    var rendered_people_label = false;

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
        const root = dvui.box(@src(), .{}, .{ .expand = .both, .padding = dvui.Rect.all(16) });
        defer root.deinit();
        const server: config.Server = .{ .id = "card-server", .name = "Fixture server", .address = "fixture.invalid", .instance_id = "card-instance" };
        const document: config.Document = .{ .instances = &.{.{ .id = "card-instance", .name = "Fixture instance", .minecraft_version = "1.21" }} };
        _ = @import("ui/game_selection_view.zig").serverCard(@src(), server, &document, .{ .state = .online, .server = server, .status = status }, false, true, 280, "server-card");
        _ = components.selectionCard(@src(), "bounded-instance", "Fixture game", .{ .width = 280, .bounded_text = true, .description = "Minecraft 1.21", .tag = "instance-card" });
        rendered_instance = false;
        rendered_motd = false;
        rendered_counts = false;
        rendered_people_label = false;
        const card = (try dvui.testing.tagGet("server-card")).rect;
        for (commands.items) |command| switch (command.cmd) {
            .text => |text| {
                const content = std.mem.trim(u8, text.text, " \n\r");
                if (std.mem.eql(u8, content, "Fixture instance")) {
                    try expectInside(card, text.rs.r);
                    try expectInside(command.clip, text.rs.r);
                    rendered_instance = true;
                }
                if (std.mem.indexOf(u8, content, "Welcome") != null or std.mem.indexOf(u8, content, "Survival") != null) rendered_motd = true;
                if (std.mem.indexOf(u8, content, "3/20") != null) rendered_counts = true;
                if (std.mem.indexOf(u8, content, "人在线") != null) rendered_people_label = true;
            },
            else => {},
        };
        return .ok;
    }
};

test "UI layout server cards show bound instance without MOTD or redundant tooltips" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    var status = try servers.parseStatus(std.testing.allocator,
        \\{ "version": { "name": "Fixture", "protocol": 767 }, "players": { "online": 3, "max": 20 }, "description": { "text": "Welcome\n", "color": "red", "bold": true, "extra": [{ "text": "Survival", "color": "green" }] } }
    );
    defer status.deinit();
    try std.testing.expectEqualStrings("Welcome\nSurvival", status.motd);
    ServerCardFrame.status = &status;
    for ([_]dvui.Size{ .{ .w = 640, .h = 400 }, .{ .w = 1280, .h = 720 } }) |size| {
        var window = try dvui.testing.init(.{ .window_size = size });
        defer window.deinit();
        window.backend.size_pixels = .{ .w = size.w, .h = size.h };
        try dvui.testing.settle(ServerCardFrame.draw);
        try std.testing.expect(ServerCardFrame.rendered_instance);
        try std.testing.expect(!ServerCardFrame.rendered_motd);
        try std.testing.expect(ServerCardFrame.rendered_counts);
        try std.testing.expect(!ServerCardFrame.rendered_people_label);
        const server = try dvui.testing.tagGet("server-card");
        try std.testing.expect(server.visible);
        try expectInside(dvui.windowRectPixels(), server.rect);
        try dvui.testing.moveTo("server-card");
        for (0..12) |_| _ = try dvui.testing.step(ServerCardFrame.draw);
        try std.testing.expectEqual(@as(usize, 1), window.window.subwindows.stack.items.len);
        try std.testing.expect(ServerCardFrame.rendered_instance);
        try std.testing.expect(!ServerCardFrame.rendered_motd);
        try std.testing.expect(ServerCardFrame.rendered_counts);
        try std.testing.expect(!ServerCardFrame.rendered_people_label);
        // Ordinary bounded game cards retain their shared delayed tooltip.
        try dvui.testing.moveTo("instance-card");
        for (0..12) |_| _ = try dvui.testing.step(ServerCardFrame.draw);
        try std.testing.expectEqual(@as(usize, 2), window.window.subwindows.stack.items.len);
        const tooltip = window.window.subwindows.stack.items[1];
        try std.testing.expect(dvui.dataGet(null, tooltip.id, "_showing", bool) orelse false);
        _ = try window.window.addEventMouseMotion(.{ .pt = .{ .x = 1, .y = 1 } });
        try dvui.testing.settle(ServerCardFrame.draw);
        try std.testing.expectEqual(@as(usize, 1), window.window.subwindows.stack.items.len);
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
    try store.update(.{ .instances = &.{.{ .id = "saved-game", .name = "Saved Fixture", .minecraft_version = "1.21" }}, .selected_instance = "saved-game", .accounts = &.{.{ .id = "offline-avatar", .name = "Player", .uuid = "a01e3843e5213998958af459800e4d11" }}, .selected_account = "offline-avatar" });
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
    var server_service = server_manager.Manager.initWithQuery(a, std.testing.io, EditorsFrame.rejectQuery);
    defer server_service.deinit();
    @memcpy(server_ui.draft.name[0..12], "Server Draft");
    const original_draft = server_ui.draft;
    var logs: logs_view.View = .{};
    RootHomeFrame.library = &library;
    RootHomeFrame.manager = &manager;
    RootHomeFrame.java_ui = &java_ui;
    RootHomeFrame.launcher = &launcher;
    RootHomeFrame.services = .{ .configuration = &store, .tasks = &registry, .settings = &settings, .java_download = &download, .java_download_ui = &download_ui, .servers_ui = &server_ui, .servers = &server_service, .logs = &logs, .worlds = undefined, .worlds_ui = undefined, .allow_mutations = false };
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
        try std.testing.expect(RootHomeFrame.state.active_game.set("Saved Fixture"));
        for ([_]games.Phase{ .idle, .loading }) |phase| {
            library.phase = phase;
            try std.testing.expectEqual(@as(usize, 0), library.snapshot().installed.len);
            try std.testing.expectEqual(phase, library.snapshot().phase);
            try dvui.testing.settle(RootHomeFrame.draw);
            try std.testing.expectEqualStrings("Saved Fixture", RootHomeFrame.state.active_game.get());
            try std.testing.expectEqualStrings("saved-game", store.snapshot().selected_instance.?);
        }
        const player_card = try dvui.testing.tagGet("sidebar-player");
        const player_avatar = try dvui.testing.tagGet("player-avatar");
        try expectInside(player_card.rect, player_avatar.rect);
        try std.testing.expect(player_avatar.rect.x >= player_card.rect.x + 4);
        try std.testing.expectApproxEqAbs(@as(f32, 48), player_avatar.rect.w, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 48), player_avatar.rect.h, 0.1);
        try std.testing.expectEqualStrings("a01e3843e5213998958af459800e4d11", store.snapshot().accounts[0].uuid);
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
        try std.testing.expectEqual(@as(usize, 1), store.snapshot().instances.len);
        try std.testing.expectEqualStrings("Saved Fixture", RootHomeFrame.state.active_game.get());
        try std.testing.expectEqualStrings("saved-game", store.snapshot().selected_instance.?);
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

const SettingsTextFrame = struct {
    const Text = struct { rect: dvui.Rect.Physical, clip: dvui.Rect.Physical, font_size: f32, font_height: f32 };
    var bounds: [2]?Text = @splat(null);

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
        const result = try Frame.draw();
        const samples = [_][]const u8{ std.mem.sliceTo(&Frame.settings.memory_buffer, 0), std.mem.sliceTo(&Frame.settings.connections_buffer, 0) };
        for (commands.items) |command| switch (command.cmd) {
            .text => |text| {
                for (samples, 0..) |sample, index| if (std.mem.eql(u8, sample, text.text)) {
                    bounds[index] = .{ .rect = text.rs.r, .clip = command.clip, .font_size = text.font.size, .font_height = text.font.textHeight() * text.rs.s };
                };
            },
            else => {},
        };
        return result;
    }
};

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
    try dvui.testing.settle(SettingsTextFrame.draw);
    const memory = try dvui.testing.tagGet("默认游戏内存-border");
    const connections = try dvui.testing.tagGet("下载连接数-border");
    try std.testing.expect(memory.visible and connections.visible);
    for ([_]dvui.TagData{ memory, connections }, SettingsTextFrame.bounds) |entry, captured| {
        try std.testing.expectApproxEqAbs(@as(f32, 48) * window.window.natural_scale, entry.rect.h, 0.1);
        const text = captured orelse return error.SettingsNumberNotRendered;
        try std.testing.expectApproxEqAbs(@as(f32, 24), text.font_size, 0.01);
        try std.testing.expect(text.rect.h >= text.font_height - 0.01);
        try expectInside(entry.rect, text.rect);
        try expectInside(text.clip, text.rect);
        try std.testing.expectApproxEqAbs(entry.rect.y + entry.rect.h / 2, text.rect.y + text.rect.h / 2, window.window.natural_scale);
    }
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
    try dvui.testing.settle(SettingsTextFrame.draw);
    try dvui.testing.pressKey(.home, .none);
    try dvui.testing.settle(SettingsTextFrame.draw);
    try dvui.testing.writeText("1");
    try dvui.testing.settle(SettingsTextFrame.draw);
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
                for (FormFrame.labels, 0..) |label, index| if (std.mem.eql(u8, text.text, label) or (index == 1 and std.mem.eql(u8, text.text, "完成"))) {
                    const pane: usize = if (JavaFrame.contains(server_rect, text.rs.r.center())) 0 else if (JavaFrame.contains(instance_rect, text.rs.r.center())) 1 else continue;
                    for (win.tab_index.items) |entry| {
                        const rect = entry.rect orelse continue;
                        if (!JavaFrame.contains(rect, text.rs.r.center())) continue;
                        const slot = pane * 2 + index;
                        if (footers[slot]) |existing| {
                            if (existing.id == entry.widgetId) continue;
                            if (existing.rect.w * existing.rect.h <= rect.w * rect.h) continue;
                        }
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
    try store.update(.{ .instances = &.{.{ .id = "fixture-instance", .name = "Fixture", .minecraft_version = "1.21" }}, .selected_instance = "fixture-instance" });
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var server_service = server_manager.Manager.initWithQuery(a, std.testing.io, EditorsFrame.rejectQuery);
    defer server_service.deinit();
    var instance_service = try instances_manager.Manager.init(a, std.testing.io, &paths, &registry, .{}, .{ .context = null, .acquire = EditorsFrame.rejectLease, .recheck = EditorsFrame.rejectLease, .release = EditorsFrame.releaseLease });
    defer instance_service.deinit();
    var server_ui = servers_view.Ui.init(a);
    defer server_ui.deinit();
    server_ui.editor_open = true;
    server_ui.adding = true;
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
    const buffers = [_][]u8{ &server_ui.draft.name, &server_ui.draft.address, &server_ui.draft.port, &instance_ui.draft.name, &instance_ui.draft.min_memory, &instance_ui.draft.memory };
    const typed = [_][]const u8{ "Server Draft", "fixture.invalid", "25a566", "Instance Draft", "1x024", "4x096" };
    // The port keeps raw text for validation; both installed memory entries filter digits.
    const expected = [_][]const u8{ "Server Draft", "fixture.invalid", "25a566", "Instance Draft", "1024", "4096" };
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
    try std.testing.expectEqual(@as(usize, 1), store.snapshot().instances.len);
}

const ServerLayoutFrame = struct {
    const Mode = enum { servers, java, instances };
    const Control = struct { id: dvui.Id, rect: dvui.Rect.Physical, text: dvui.Rect.Physical, clip: dvui.Rect.Physical, border: dvui.Color, color: dvui.Color };
    const labels = [_][]const u8{ "添加服务器", "获取 Java", "新建实例", "刷新状态", "编辑", "删除", "取消", "完成", "确认删除" };
    var controls: [labels.len]?Control = @splat(null);
    var card_text: [3]bool = @splat(false);
    var mode: Mode = .servers;
    var server_ui: *servers_view.Ui = undefined;
    var store: *config.Store = undefined;
    var server_service: *server_manager.Manager = undefined;
    var java_ui: *java_view.Ui = undefined;
    var java_service: *java.Manager = undefined;
    var instance_ui: *instances_view.Ui = undefined;
    var instance_service: *instances_manager.Manager = undefined;

    fn observe(commands: []const dvui.RenderCommand) !void {
        controls = @splat(null);
        const capture = dvui.debug.lastCapture() orelse return error.ServerLayoutCaptureMissing;
        for (commands) |command| switch (command.cmd) {
            .text => |text| {
                const clipped = text.rs.r.intersect(command.clip);
                if (clipped.w <= 0 or clipped.h <= 0) continue;
                for (labels, 0..) |label, index| {
                    if (!std.mem.eql(u8, text.text, label) and !(index == 7 and std.mem.eql(u8, text.text, "保存"))) continue;
                    for (capture.widgets.items) |widget| {
                        if (!std.mem.eql(u8, widget.name orelse "", "Button") or !JavaFrame.contains(widget.rect_border, clipped.center()) or !JavaFrame.insideScrollClips(capture.widgets.items, widget.parent_id, clipped.center())) continue;
                        if (controls[index]) |previous| {
                            // Floating dialogs may cover an underlying button. Keep the
                            // smallest actual button containing the rendered label.
                            if (previous.rect.w * previous.rect.h <= widget.rect_border.w * widget.rect_border.h) continue;
                        }
                        controls[index] = .{ .id = widget.id, .rect = widget.rect_border, .text = text.rs.r, .clip = command.clip, .border = widget.color_border, .color = widget.color_text };
                    }
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
        dvui.debug.captureScopeBegin(win.gpa);
        defer {
            dvui.debug.captureScopeEnd();
            win.defer_render_cmds = previous_commands;
            win.render_target.rendering = previous_rendering;
        }
        {
            const root = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .padding = dvui.Rect.all(8) });
            defer root.deinit();
            {
                const sidebar = dvui.box(@src(), .{}, .{ .tag = "server-layout-sidebar", .expand = .vertical, .min_size_content = .{ .w = if (dvui.windowRect().w < 800) 212 else 260 }, .padding = dvui.Rect.all(8) });
                defer sidebar.deinit();
                switch (mode) {
                    .servers => servers_view.drawSidebar(server_ui, store, server_service),
                    .java => java_view.drawSidebar(java_ui, java_service, true),
                    .instances => instances_view.drawSidebar(instance_ui, store, instance_service, true),
                }
            }
            {
                const page = dvui.box(@src(), .{}, .{ .tag = "server-layout-page", .expand = .both, .padding = dvui.Rect.all(12) });
                defer page.deinit();
                if (mode == .servers) servers_view.draw(server_ui, store, server_service);
            }
        }
        if (mode == .servers) servers_view.drawModal(server_ui, store.snapshot());
        for (win.subwindows.stack.items) |*subwindow| {
            try commands.appendSlice(win.arena(), subwindow.render_cmds.items);
            try commands.appendSlice(win.arena(), subwindow.render_cmds_after.items);
        }
        try observe(commands.items);
        card_text = @splat(false);
        if (mode == .servers) {
            const card = (try dvui.testing.tagGet("server-option-legacy")).rect;
            for (commands.items) |command| switch (command.cmd) {
                .text => |text| {
                    if (!JavaFrame.contains(card, text.rs.r.center())) continue;
                    for ([_][]const u8{ "Legacy", "Fixture", "尚未查询" }, 0..) |label, index| if (std.mem.eql(u8, text.text, label)) {
                        try expectInside(card, text.rs.r);
                        try expectInside(command.clip, text.rs.r);
                        card_text[index] = true;
                    };
                },
                else => {},
            };
        }
        return .ok;
    }

    fn visible(index: usize) !Control {
        const control = controls[index] orelse return error.ServerLayoutControlMissing;
        try expectInside(dvui.windowRectPixels(), control.rect);
        try expectInside(control.rect, control.text);
        try expectInside(control.clip, control.text);
        var registered: usize = 0;
        for (dvui.currentWindow().tab_index_prev.items) |entry| if (entry.widgetId == control.id) {
            registered += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), registered);
        return control;
    }

    fn click(index: usize) !void {
        if (index == 5 and server_ui.editor_open) {
            for (0..8) |_| {
                const candidate = controls[index] orelse return error.ServerLayoutControlMissing;
                const viewport = candidate.clip.intersect(dvui.windowRectPixels());
                if (candidate.rect.y >= viewport.y and candidate.rect.y + candidate.rect.h <= viewport.y + viewport.h + 0.1) break;
                _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = viewport.center() });
                _ = try dvui.currentWindow().addEventMouseWheel(-160, .vertical, null);
                try dvui.testing.settle(draw);
            }
        }
        const control = try visible(index);
        _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = control.rect.center() });
        try dvui.testing.click(.left);
        try dvui.testing.settle(draw);
    }

    fn scrollPage(amount: f32) !void {
        _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = (try dvui.testing.tagGet("server-layout-page")).rect.center() });
        _ = try dvui.currentWindow().addEventMouseWheel(amount, .vertical, null);
        try dvui.testing.settle(draw);
    }

    fn clearPending() void {
        if (server_ui.pending) |pending| if (pending.id) |id| server_ui.allocator.free(id);
        server_ui.pending = null;
    }

    fn taggedButton(key: []const u8) !dvui.Debug.CapturedWidget {
        const tagged = try dvui.testing.tagGet(key);
        const capture = dvui.debug.lastCapture() orelse return error.ServerLayoutCaptureMissing;
        for (capture.widgets.items) |widget| if (widget.id == tagged.id) {
            try std.testing.expectEqualStrings("Button", widget.name orelse "");
            try expectInside((try dvui.testing.tagGet("server-layout-sidebar")).rect, widget.rect_border);
            var registered: usize = 0;
            for (dvui.currentWindow().tab_index_prev.items) |entry| if (entry.widgetId == widget.id) {
                registered += 1;
            };
            try std.testing.expectEqual(@as(usize, 1), registered);
            return widget;
        };
        return error.ServerCardButtonMissing;
    }

    fn noCheckbox() !void {
        const capture = dvui.debug.lastCapture() orelse return error.ServerLayoutCaptureMissing;
        for (capture.widgets.items) |widget| try std.testing.expect(!std.mem.eql(u8, widget.name orelse "", "Checkbox"));
    }
};

test "UI layout Servers cards keep legacy targets available and shared sidebar actions aligned" {
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
    try store.update(.{ .instances = &.{.{ .id = "fixture-instance", .name = "Fixture", .minecraft_version = "1.21" }}, .servers = &.{.{ .id = "legacy", .name = "Legacy", .address = "localhost:25565", .instance_id = "fixture-instance", .show_on_home = false }}, .selected_instance = "fixture-instance" });
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var server_service = server_manager.Manager.initWithQuery(a, std.testing.io, EditorsFrame.rejectQuery);
    defer server_service.deinit();
    var instance_service = try instances_manager.Manager.init(a, std.testing.io, &paths, &registry, .{}, .{ .context = null, .acquire = EditorsFrame.rejectLease, .recheck = EditorsFrame.rejectLease, .release = EditorsFrame.releaseLease });
    defer instance_service.deinit();
    var java_service = try java.Manager.init(a, std.testing.io, root);
    defer java_service.deinit();
    ServerLayoutFrame.store = &store;
    ServerLayoutFrame.server_service = &server_service;
    ServerLayoutFrame.instance_service = &instance_service;
    ServerLayoutFrame.java_service = &java_service;
    EditorsFrame.service_calls = 0;
    for ([_]dvui.Size{ .{ .w = 640, .h = 400 }, .{ .w = 1280, .h = 720 } }) |size| {
        for ([_]f32{ 16, 24 }) |font_size| {
            errdefer std.debug.print("Servers layout: size={any}, font={d}\n", .{ size, font_size });
            var document = store.snapshot().*;
            document.selected_server = null;
            try store.update(document);
            try std.testing.expectError(error.InvalidAddress, servers_view.selectLaunchTarget(&store, &server_service, "legacy"));
            try std.testing.expect(store.snapshot().selected_server == null);
            var server_ui = servers_view.Ui.init(a);
            defer server_ui.deinit();
            var instance_ui = instances_view.Ui.init(a);
            defer instance_ui.deinit();
            var java_ui = java_view.Ui.init(a);
            defer java_ui.deinit();
            ServerLayoutFrame.server_ui = &server_ui;
            ServerLayoutFrame.instance_ui = &instance_ui;
            ServerLayoutFrame.java_ui = &java_ui;
            ServerLayoutFrame.mode = .servers;
            var window = try dvui.testing.init(.{ .window_size = size });
            defer window.deinit();
            window.backend.size_pixels = .{ .w = size.w, .h = size.h };
            var theme = dvui.themeGet();
            theme.font_body = theme.font_body.withSize(font_size);
            theme.font_heading = theme.font_body.withSize(18);
            theme.font_title = theme.font_body.withSize(24);
            window.window.themeSet(theme);
            try dvui.testing.settle(ServerLayoutFrame.draw);
            const card = try ServerLayoutFrame.taggedButton("server-option-legacy");
            for (ServerLayoutFrame.card_text) |rendered| try std.testing.expect(rendered);
            _ = try window.window.addEventMouseMotion(.{ .pt = .{ .x = card.rect_border.x + card.rect_border.w - 4, .y = card.rect_border.y + card.rect_border.h - 4 } });
            try dvui.testing.click(.left);
            try dvui.testing.settle(ServerLayoutFrame.draw);
            try std.testing.expectEqual(.select_sidebar, server_ui.pending.?.action);
            try std.testing.expectEqualStrings("legacy", server_ui.pending.?.id.?);
            servers_view.finish(&server_ui, &store, &server_service);
            try std.testing.expectEqual(error.InvalidAddress, server_ui.failure.?);
            try std.testing.expectEqualStrings("legacy", store.snapshot().selected_server.?);
            try dvui.testing.settle(ServerLayoutFrame.draw);
            const accent = @import("ui/theme.zig").accent;
            try std.testing.expectEqual(accent, (try ServerLayoutFrame.taggedButton("server-option-legacy")).color_border);
            try std.testing.expect(server_ui.editor_open);
            try std.testing.expect(ServerLayoutFrame.controls[3] == null and ServerLayoutFrame.controls[4] == null);
            try std.testing.expect(ServerLayoutFrame.controls[6] == null and ServerLayoutFrame.controls[7] == null);
            try ServerLayoutFrame.scrollPage(-100000);
            try expectInside((try dvui.testing.tagGet("server-layout-page")).rect, (try ServerLayoutFrame.visible(5)).rect);
            try dvui.testing.settle(ServerLayoutFrame.draw);
            try std.testing.expect(server_ui.editor_open and !server_ui.draft.show_on_home);
            try std.testing.expectEqualStrings("localhost:25565", std.mem.sliceTo(&server_ui.draft.address, 0));
            const original_draft = server_ui.draft;
            // A queued sidebar target can disappear while this editor is open.
            const editor_card = try ServerLayoutFrame.taggedButton("server-option-legacy");
            _ = try window.window.addEventMouseMotion(.{ .pt = editor_card.rect_border.center() });
            try dvui.testing.click(.left);
            try dvui.testing.settle(ServerLayoutFrame.draw);
            try std.testing.expectEqual(.select_sidebar, server_ui.pending.?.action);
            const missing_target = try a.dupe(u8, "missing-target");
            a.free(server_ui.pending.?.id.?);
            server_ui.pending.?.id = missing_target;
            servers_view.finish(&server_ui, &store, &server_service);
            try std.testing.expectEqual(error.ServerNotFound, server_ui.failure.?);
            try std.testing.expect(server_ui.editor_open);
            try std.testing.expectEqual(original_draft, server_ui.draft);
            try std.testing.expectEqualStrings("legacy", store.snapshot().selected_server.?);
            try dvui.testing.settle(ServerLayoutFrame.draw);
            try ServerLayoutFrame.noCheckbox();
            try std.testing.expect(ServerLayoutFrame.controls[6] == null and ServerLayoutFrame.controls[7] == null);
            try ServerLayoutFrame.click(5);
            try std.testing.expectEqual(.ask_delete, server_ui.pending.?.action);
            servers_view.finish(&server_ui, &store, &server_service);
            try dvui.testing.settle(ServerLayoutFrame.draw);
            _ = try ServerLayoutFrame.visible(8);
            try ServerLayoutFrame.click(6);
            try std.testing.expectEqual(.cancel_delete, server_ui.pending.?.action);
            servers_view.finish(&server_ui, &store, &server_service);
            try std.testing.expect(server_ui.deleting_id == null);
            try dvui.testing.settle(ServerLayoutFrame.draw);

            // Compare selected first actions with identical actual sidebar wrappers.
            try ServerLayoutFrame.click(0);
            servers_view.finish(&server_ui, &store, &server_service);
            try dvui.testing.settle(ServerLayoutFrame.draw);
            const server_action = try ServerLayoutFrame.visible(0);
            instance_ui.mode = .create;
            ServerLayoutFrame.mode = .instances;
            try dvui.testing.settle(ServerLayoutFrame.draw);
            const instance_action = try ServerLayoutFrame.visible(2);
            ServerLayoutFrame.mode = .java;
            try dvui.testing.settle(ServerLayoutFrame.draw);
            const java_action = try ServerLayoutFrame.visible(1);
            for ([_]ServerLayoutFrame.Control{ server_action, java_action }) |action| {
                try std.testing.expectApproxEqAbs(instance_action.rect.x, action.rect.x, 0.1);
                try std.testing.expectApproxEqAbs(instance_action.rect.y, action.rect.y, 0.1);
                try std.testing.expectApproxEqAbs(instance_action.rect.w, action.rect.w, 0.1);
                try std.testing.expectApproxEqAbs(instance_action.rect.h, action.rect.h, 0.1);
                try std.testing.expectApproxEqAbs(instance_action.text.x - instance_action.rect.x, action.text.x - action.rect.x, 0.1);
                try std.testing.expectApproxEqAbs(instance_action.text.center().y, action.text.center().y, 0.1);
                try std.testing.expectEqual(accent, action.border);
                try std.testing.expectEqual(vela_theme.selected_text, action.color);
            }
            try std.testing.expectEqual(accent, instance_action.border);
            try std.testing.expectEqual(vela_theme.selected_text, instance_action.color);
            try std.testing.expect(server_ui.pending == null and instance_ui.pending == null and java_ui.commands.items.len == 0);
            try std.testing.expectEqual(@as(usize, 0), EditorsFrame.service_calls);
            try std.testing.expectEqual(@as(usize, 0), registry.tasks().len);
            try std.testing.expectEqual(@as(usize, 1), store.snapshot().servers.len);
            try std.testing.expect(!store.snapshot().servers[0].show_on_home);
            try std.testing.expectEqualStrings("legacy", store.snapshot().selected_server.?);
        }
    }
}

const JavaFrame = struct {
    const Control = struct { id: dvui.Id, rect: dvui.Rect.Physical };
    const Text = enum { empty, visible, disclosure, hidden, hidden_status, acquire, download, search, visible_path, hidden_path, acquisition_heading, details_nav, restore, add, vendor, major, search_path };
    const default_labels = [_][]const u8{ "暂无 Java", "Fixture Visible · Java 21", "已隐藏 (1)", "Fixture Hidden · Java 17", "已隐藏 · 不参与游戏启动", "获取 Java", "下载 Java", "搜索本机 Java", "", "", "获取 Java", "查看所选 Java", "恢复显示", "添加 Java", "发行商", "版本", "搜索路径" };
    var labels = default_labels;
    const Observation = struct { rect: dvui.Rect.Physical, clip: dvui.Rect.Physical, control: ?Control, fill: ?dvui.Color, border: ?dvui.Color, focused: bool, background: bool };
    var observations: [labels.len]?Observation = @splat(null);
    var ui: *java_view.Ui = undefined;
    var manager: *java.Manager = undefined;
    var download_ui: *java_download_view.Ui = undefined;
    var controller: *java_download_controller.Controller = undefined;
    var interactive = true;

    fn reset() void {
        labels = default_labels;
        observations = @splat(null);
        ui = undefined;
        manager = undefined;
        download_ui = undefined;
        controller = undefined;
        interactive = true;
    }

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
                    const kind: Text = @fromBackingInt(@intCast(index));
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
                        if (!std.mem.eql(u8, widget.name orelse continue, "Button") or !contains(widget.rect_border, visible_rect.center()) or !insideScrollClips(capture.widgets.items, widget.parent_id, visible_rect.center())) continue;
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
        // A wrapped runtime name is complete only when every ordered fragment
        // belongs to the same real sidebar Button, including its final Java version.
        for ([_]Text{ .visible, .hidden }) |kind| {
            const index = @backingInt(kind);
            observations[index] = null;
            for (capture.widgets.items) |widget| {
                if (!std.mem.eql(u8, widget.name orelse continue, "Button") or !contains(sidebar_rect, widget.rect_border.center())) continue;
                if (completeName(commands.items, widget, labels[index])) |sample| {
                    try std.testing.expect(observations[index] == null);
                    observations[index] = sample;
                }
            }
        }
        return .ok;
    }

    fn completeName(commands: []const dvui.RenderCommand, widget: dvui.Debug.CapturedWidget, name: []const u8) ?Observation {
        var consumed: usize = 0;
        var sample: ?Observation = null;
        for (commands) |command| switch (command.cmd) {
            .text => |text| {
                const visible = text.rs.r.intersect(command.clip);
                if (visible.w <= 0 or visible.h <= 0 or !contains(widget.rect_border, visible.center())) continue;
                const fragment = std.mem.trim(u8, text.text, " ");
                const remaining = std.mem.trimStart(u8, name[consumed..], " ");
                if (fragment.len == 0 or !std.mem.startsWith(u8, remaining, fragment)) continue;
                consumed = name.len - remaining.len + fragment.len;
                // Wrapped lines include a trailing blank in the render rectangle.
                // Check the nonblank title advance, retaining strict glyph containment.
                var content_rect = text.rs.r;
                const content = std.mem.trimEnd(u8, text.text, " ");
                if (content.len != text.text.len) content_rect.w = text.font.textSizeEx(content, .{ .kerning = text.kerning orelse command.kerning, .kern_in = text.kern_in }).w * text.rs.s;
                if (sample) |*previous| {
                    const x = @min(previous.rect.x, content_rect.x);
                    const y = @min(previous.rect.y, content_rect.y);
                    const right = @max(previous.rect.x + previous.rect.w, content_rect.x + content_rect.w);
                    const bottom = @max(previous.rect.y + previous.rect.h, content_rect.y + content_rect.h);
                    previous.rect = .{ .x = x, .y = y, .w = right - x, .h = bottom - y };
                    previous.clip = previous.clip.intersect(command.clip);
                } else {
                    sample = .{ .rect = content_rect, .clip = command.clip, .control = .{ .id = widget.id, .rect = widget.rect_border }, .fill = widget.color_fill, .border = widget.color_border, .focused = widget.focused, .background = widget.background };
                }
                if (consumed == name.len) return sample;
            },
            else => {},
        };
        return null;
    }

    fn matchesLabel(index: usize, rendered: []const u8) bool {
        const label = labels[index];
        if (label.len == 0 or rendered.len == 0) return false;
        if (std.mem.eql(u8, label, rendered)) return true;
        // One-line TextLayout clipping emits only the visible prefix for long labels.
        return switch (@as(Text, @fromBackingInt(@intCast(index)))) {
            .visible, .hidden, .visible_path, .hidden_path => std.mem.startsWith(u8, label, rendered),
            .search => std.mem.eql(u8, rendered, "搜索"),
            else => false,
        };
    }

    fn contains(rect: dvui.Rect.Physical, point: dvui.Point.Physical) bool {
        return point.x >= rect.x and point.x <= rect.x + rect.w and point.y >= rect.y and point.y <= rect.y + rect.h;
    }

    fn insideScrollClips(widgets: []const dvui.Debug.CapturedWidget, parent_id: dvui.Id, point: dvui.Point.Physical) bool {
        var current = parent_id;
        for (0..widgets.len) |_| {
            // The window root predates this scoped capture.
            const parent = for (widgets) |widget| {
                if (widget.id == current) break widget;
            } else return true;
            if (std.mem.eql(u8, parent.name orelse "", "ScrollContainer") and !contains(parent.rect_content, point)) return false;
            if (parent.parent_id == parent.id) return true;
            current = parent.parent_id;
        }
        return false;
    }

    fn observed(text: Text) !Observation {
        return observations[@backingInt(text)] orelse error.JavaTextNotRendered;
    }

    fn control(text: Text) !Control {
        return (try observed(text)).control orelse error.JavaControlNotRegistered;
    }

    fn dropdownControl(key: []const u8) !Control {
        const tagged = try dvui.testing.tagGet(key);
        const capture = dvui.debug.lastCapture() orelse return error.JavaCaptureMissing;
        var found: ?Control = null;
        for (capture.widgets.items) |widget| {
            if (!std.mem.eql(u8, widget.name orelse continue, "Menu Item") or !contains(widget.rect_border, tagged.rect.center())) continue;
            try std.testing.expect(found == null);
            found = .{ .id = widget.id, .rect = widget.rect_border };
        }
        return found orelse error.JavaDropdownNotRegistered;
    }

    fn searchCheckboxControl() !Control {
        const capture = dvui.debug.lastCapture() orelse return error.JavaCaptureMissing;
        var found: ?Control = null;
        for (capture.widgets.items) |widget| {
            if (!std.mem.eql(u8, widget.name orelse continue, "Checkbox")) continue;
            try std.testing.expect(found == null);
            try std.testing.expect(insideScrollClips(capture.widgets.items, widget.parent_id, widget.rect_border.center()));
            try expectInside((try dvui.testing.tagGet("java-page")).rect, widget.rect_border);
            found = .{ .id = widget.id, .rect = widget.rect_border };
        }
        return found orelse error.JavaCheckboxNotRegistered;
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

    fn clickTag(key: []const u8) !Control {
        const tagged = try dvui.testing.tagGet(key);
        const target: Control = .{ .id = tagged.id, .rect = tagged.rect };
        try expectInside((try dvui.testing.tagGet("java-page")).rect, target.rect);
        _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = target.rect.center() });
        try dvui.testing.click(.left);
        try dvui.testing.settle(draw);
        return target;
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

    fn scrollSidebar(amount: f32) !void {
        try dvui.testing.moveTo("java-sidebar");
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
        errdefer std.debug.print("Java tooltip gap: viewport={any}, trigger={any}, tooltip={any}, gap={d}\n", .{ dvui.windowRect(), trigger, tip, gap });
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
    JavaFrame.labels[@backingInt(JavaFrame.Text.visible_path)] = visible_path;
    JavaFrame.labels[@backingInt(JavaFrame.Text.hidden_path)] = hidden_path;
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
        const download_method = try dvui.testing.tagGet("java-acquire-download");
        try JavaFrame.expectTabRegistration(.{ .id = download_method.id, .rect = download_method.rect }, true);
        try std.testing.expect(JavaFrame.observations[@backingInt(JavaFrame.Text.details_nav)] == null);
        try std.testing.expect(JavaFrame.observations[@backingInt(JavaFrame.Text.hidden_path)] == null);
        const unselected_fill = (try JavaFrame.observed(.visible)).fill.?;
        const unselected_border = (try JavaFrame.observed(.visible)).border.?;
        const acquisition_fill = (try JavaFrame.observed(.acquire)).fill.?;
        const acquisition_border = (try JavaFrame.observed(.acquire)).border.?;
        try std.testing.expectEqual(vela_theme.sidebar, unselected_fill);
        try std.testing.expectEqual(vela_theme.selected_surface, acquisition_fill);

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
        try std.testing.expect(JavaFrame.observations[@backingInt(JavaFrame.Text.details_nav)] == null);
        try JavaFrame.expectNoCommands();

        try JavaFrame.clickText(.acquire);
        try std.testing.expect(ui.acquisition_open);
        try std.testing.expectEqualStrings(visible_path, ui.selected_path.?);
        try std.testing.expectEqual(unselected_fill, (try JavaFrame.observed(.visible)).fill.?);
        try std.testing.expectEqual(acquisition_fill, (try JavaFrame.observed(.acquire)).fill.?);
        try expectInside((try dvui.testing.tagGet("java-page")).rect, (try dvui.testing.tagGet("java-acquire-download")).rect);
        try JavaFrame.clickText(.visible);
        try std.testing.expect(!ui.acquisition_open);
        try std.testing.expectEqualStrings(visible_path, ui.selected_path.?);
        try std.testing.expectEqual(visible_row.id, dvui.focusedWidgetId().?);
        _ = try JavaFrame.expectWholeRow(.visible, .visible_path, true);

        try JavaFrame.click(.disclosure);
        try std.testing.expect(ui.show_hidden);
        const hidden_row = try JavaFrame.expectWholeRow(.hidden, .hidden_path, true);
        try std.testing.expect(hidden_row.id != visible_row.id and hidden_row.id != acquisition.id);
        try std.testing.expectApproxEqAbs(visible_row.rect.x, hidden_row.rect.x, 0.1);
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
        try std.testing.expect(JavaFrame.observations[@backingInt(JavaFrame.Text.add)] == null);
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
    JavaFrame.labels[@backingInt(JavaFrame.Text.visible_path)] = visible_path;
    JavaFrame.labels[@backingInt(JavaFrame.Text.hidden_path)] = hidden_path;
    JavaFrame.interactive = true;
    const Viewport = struct { size: dvui.Size, font_size: f32 };
    for ([_]Viewport{
        .{ .size = .{ .w = 640, .h = 400 }, .font_size = 16 },
        .{ .size = .{ .w = 1280, .h = 720 }, .font_size = 16 },
        .{ .size = .{ .w = 640, .h = 400 }, .font_size = 24 },
        .{ .size = .{ .w = 1280, .h = 720 }, .font_size = 24 },
    }) |viewport| {
        const size = viewport.size;
        errdefer std.debug.print("Java acquisition viewport={any}, font={d}\n", .{ size, viewport.font_size });
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
        var test_theme = dvui.themeGet();
        test_theme.font_body = test_theme.font_body.withSize(viewport.font_size);
        test_theme.font_heading = test_theme.font_body.withSize(18);
        test_theme.font_title = test_theme.font_body.withSize(24);
        window.window.themeSet(test_theme);
        try dvui.testing.settle(JavaFrame.draw);
        try JavaFrame.expectVisible(.empty, "java-sidebar");
        try JavaFrame.expectVisible(.acquire, "java-sidebar");
        const acquisition = try JavaFrame.control(.acquire);
        try expectInside((try dvui.testing.tagGet("java-sidebar")).rect, acquisition.rect);
        try std.testing.expect(acquisition.rect.y + acquisition.rect.h <= (try JavaFrame.observed(.empty)).rect.y);
        try std.testing.expect(JavaFrame.observations[@backingInt(JavaFrame.Text.details_nav)] == null);
        try std.testing.expect(JavaFrame.observations[@backingInt(JavaFrame.Text.disclosure)] == null);
        try JavaFrame.expectNoCommands();
        const download_method = try JavaFrame.clickTag("java-acquire-download");
        try JavaFrame.expectTabRegistration(download_method, true);
        try std.testing.expect(download_ui.start_admitted);
        try std.testing.expect(JavaFrame.observations[@backingInt(JavaFrame.Text.search)] == null);
        const local_method = try JavaFrame.clickTag("java-acquire-local");
        try JavaFrame.expectTabRegistration(local_method, true);
        try std.testing.expect(download_method.id != local_method.id);
        try std.testing.expect(!download_ui.start_admitted);
        try JavaFrame.expectNoCommands();
        try JavaFrame.scrollPage(-100000);
        try JavaFrame.expectVisible(.search, "java-page");
        try JavaFrame.expectVisible(.search_path, "java-page");
        const input_tag = try dvui.testing.tagGet("java-search-path");
        const path_input: JavaFrame.Control = .{ .id = input_tag.id, .rect = input_tag.rect };
        try JavaFrame.expectTabRegistration(path_input, true);
        try expectInside((try dvui.testing.tagGet("java-page")).rect, path_input.rect);
        _ = try window.window.addEventMouseMotion(.{ .pt = path_input.rect.center() });
        try dvui.testing.click(.left);
        try dvui.testing.settle(JavaFrame.draw);
        try std.testing.expectEqual(path_input.id, dvui.focusedWidgetId().?);
        try dvui.testing.writeText("/fixture/search-only");
        try dvui.testing.settle(JavaFrame.draw);
        try std.testing.expectEqualStrings("/fixture/search-only", std.mem.sliceTo(&ui.path_buffer, 0));
        try JavaFrame.expectNoCommands();
        JavaFrame.interactive = false;
        defer JavaFrame.interactive = true;
        try dvui.testing.settle(JavaFrame.draw);
        try JavaFrame.expectTabRegistration(local_method, false);
        _ = try JavaFrame.clickTag("java-acquire-download");
        try std.testing.expect(!download_ui.start_admitted);
        try JavaFrame.expectVisible(.search, "java-page");
        try JavaFrame.expectTabRegistration(try JavaFrame.control(.search), false);
        try JavaFrame.click(.search);
        try JavaFrame.expectNoCommands();
        JavaFrame.interactive = true;
        try dvui.testing.settle(JavaFrame.draw);

        JavaFrame.manager = &manager;
        try dvui.testing.settle(JavaFrame.draw);
        try JavaFrame.expectVisible(.visible, "java-sidebar");
        try JavaFrame.expectVisible(.disclosure, "java-sidebar");
        try std.testing.expect(JavaFrame.observations[@backingInt(JavaFrame.Text.hidden)] == null);
        const visible_control = try JavaFrame.control(.visible);
        const disclosure = try JavaFrame.control(.disclosure);
        try std.testing.expect(visible_control.id != path_input.id and disclosure.id != path_input.id);
        try expectJavaSidebarTooltips(&.{ visible_control, disclosure });
        try JavaFrame.click(.disclosure);
        try std.testing.expect(ui.show_hidden);
        try JavaFrame.scrollSidebar(-100000);
        try JavaFrame.expectVisible(.hidden, "java-sidebar");
        const hidden_control = try JavaFrame.control(.hidden);
        try std.testing.expect(hidden_control.id != path_input.id);
        dvui.focusWidget(path_input.id, null, null);
        // Check each hover using settled hitboxes at the current sidebar scroll.
        try expectJavaSidebarTooltips(&.{hidden_control});
        try JavaFrame.scrollSidebar(100000);
        try expectJavaSidebarTooltips(&.{ try JavaFrame.control(.visible), try JavaFrame.control(.disclosure) });
        try JavaFrame.scrollSidebar(-100000);
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
        // Method navigation preserves the draft and only the visible method admits work.
        try JavaFrame.scrollPage(100000);
        const download_method_again = try JavaFrame.clickTag("java-acquire-download");
        try std.testing.expectEqual(download_method.id, download_method_again.id);
        try std.testing.expect(download_ui.start_admitted);
        try std.testing.expect(JavaFrame.observations[@backingInt(JavaFrame.Text.search)] == null);
        try JavaFrame.scrollPage(100000);
        try JavaFrame.expectVisible(.vendor, "java-page");
        const vendor = try JavaFrame.dropdownControl("java-download-vendor");
        try expectInside((try dvui.testing.tagGet("java-page")).rect, vendor.rect);
        try JavaFrame.expectTabRegistration(.{ .id = vendor.id, .rect = vendor.rect }, true);
        try JavaFrame.scrollPage(-100000);
        try JavaFrame.expectVisible(.major, "java-page");
        const major = try JavaFrame.dropdownControl("java-download-major");
        try expectInside((try dvui.testing.tagGet("java-page")).rect, major.rect);
        try JavaFrame.expectTabRegistration(.{ .id = major.id, .rect = major.rect }, true);
        try std.testing.expect(vendor.id != major.id);
        try JavaFrame.expectVisible(.download, "java-page");
        const download_control = try JavaFrame.control(.download);
        try std.testing.expect(download_control.id != path_input.id);
        try JavaFrame.click(.download);
        try std.testing.expect(download_ui.pending != null and download_ui.pending.? == .start);
        try std.testing.expectEqual(download_ui.vendor, download_ui.pending.?.start.vendor);
        try std.testing.expectEqual(download_ui.major, download_ui.pending.?.start.major);
        try std.testing.expectEqual(@as(usize, 0), ui.commands.items.len);
        download_ui.pending = null;
        try dvui.testing.settle(JavaFrame.draw);
        try JavaFrame.scrollPage(100000);
        const local_method_again = try JavaFrame.clickTag("java-acquire-local");
        try std.testing.expectEqual(local_method.id, local_method_again.id);
        try std.testing.expect(!download_ui.start_admitted);
        try JavaFrame.scrollPage(-100000);
        try JavaFrame.expectVisible(.search, "java-page");
        const search_control = try JavaFrame.control(.search);
        try std.testing.expect(download_control.id != search_control.id);
        try std.testing.expect(search_control.id != path_input.id);
        try std.testing.expectEqualStrings("/fixture/search-only", std.mem.sliceTo(&ui.path_buffer, 0));
        // Text edits and Search are delivered in one event batch.
        dvui.focusWidget((try dvui.testing.tagGet("java-search-path")).id, null, null);
        try dvui.testing.pressKey(.a, .lcontrol);
        try dvui.testing.pressKey(.backspace, .none);
        try dvui.testing.writeText("/fixture/search-latest");
        try JavaFrame.click(.search);
        try std.testing.expectEqual(@as(usize, 1), ui.commands.items.len);
        try std.testing.expect(ui.commands.items[0] == .search);
        try std.testing.expectEqualStrings("/fixture/search-latest", std.mem.sliceTo(&ui.path_buffer, 0));
        try std.testing.expectEqualStrings("/fixture/search-latest", ui.commands.items[0].search);
        ui.path_buffer[0] = 'x';
        try std.testing.expectEqualStrings("/fixture/search-latest", ui.commands.items[0].search);
        try std.testing.expect(ui.search_queued and ui.search_started);
        try std.testing.expect(download_ui.pending == null);
        java_view.discardCommands(&ui);
        try JavaFrame.expectNoCommands();
        try std.testing.expectEqual(@as(usize, 1), manager.entries().len);
        try std.testing.expectEqual(@as(usize, 1), manager.hiddenEntries().len);

        // A refreshed result of the same length must invalidate the old selection
        // before the fixed footer handles an already-visible Add button click.
        manager.state.search_visible.clearRetainingCapacity();
        try manager.state.search_visible.append(manager.state.arena.allocator(), .{ .path = "/fixture/search-previous", .vendor = "Fixture Search", .major = 21 });
        try dvui.testing.settle(JavaFrame.draw);
        try std.testing.expectEqual(@as(usize, 1), ui.search_selection.len);
        ui.search_selection[0] = true;
        try dvui.testing.settle(JavaFrame.draw);
        const add = try dvui.testing.tagGet("java-search-add");
        try JavaFrame.expectTabRegistration(.{ .id = add.id, .rect = add.rect }, true);
        manager.state.search_visible.items[0].path = "/fixture/search-replaced";
        _ = try JavaFrame.clickTag("java-search-add");
        try std.testing.expect(!ui.search_selection[0]);
        try JavaFrame.expectNoCommands();

        ui.search_selection[0] = true;
        try JavaFrame.scrollPage(-100000);
        const checkbox = try JavaFrame.searchCheckboxControl();
        const add_selected = try dvui.testing.tagGet("java-search-add");
        try JavaFrame.expectTabRegistration(.{ .id = add_selected.id, .rect = add_selected.rect }, true);
        // Deselect and Add are delivered together; the footer must see no selection.
        _ = try window.window.addEventMouseMotion(.{ .pt = checkbox.rect.center() });
        try dvui.testing.click(.left);
        _ = try window.window.addEventMouseMotion(.{ .pt = add_selected.rect.center() });
        try dvui.testing.click(.left);
        try dvui.testing.settle(JavaFrame.draw);
        try std.testing.expect(!ui.search_selection[0]);
        try JavaFrame.expectNoCommands();
    }
}

test "UI layout Java removing all registered runtimes keeps a new scan in local acquisition" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    JavaFrame.reset();
    defer JavaFrame.reset();
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var manager = try java.Manager.init(a, std.testing.io, root);
    defer manager.deinit();
    const runtime: java.Runtime = .{ .path = "/fixture/rescanned/bin/java", .vendor = "Rescanned Java", .major = 21 };
    try manager.addDownloaded(runtime);
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var controller = try java_download_controller.Controller.initWithOptions(a, std.testing.io, .{ .root = root, .task_registry = &registry });
    defer controller.deinit();
    var download_ui = java_download_view.Ui.init(a);
    defer download_ui.deinit();
    var ui = java_view.Ui.init(a);
    defer ui.deinit();
    JavaFrame.ui = &ui;
    JavaFrame.download_ui = &download_ui;
    JavaFrame.controller = &controller;
    JavaFrame.manager = &manager;
    JavaFrame.interactive = true;
    ui.selected_path = try a.dupe(u8, runtime.path);
    ui.acquisition_open = false;
    ui.acquisition_mode = .local;
    var window = try dvui.testing.init(.{ .window_size = .{ .w = 640, .h = 400 } });
    defer window.deinit();
    window.backend.size_pixels = .{ .w = 640, .h = 400 };
    try dvui.testing.settle(JavaFrame.draw);
    _ = try JavaFrame.clickTag("java-remove");
    java_view.finish(&ui, &manager);
    try std.testing.expect(ui.failure == null);
    try std.testing.expectEqual(@as(usize, 0), manager.allEntries().len);
    try dvui.testing.settle(JavaFrame.draw);
    try std.testing.expect(ui.acquisition_open);
    try JavaFrame.expectVisible(.search, "java-page");
    // Inject the refreshed scanner snapshot with the previously selected path.
    try manager.state.search_visible.append(manager.state.arena.allocator(), runtime);
    ui.search_started = true;
    // Even a retained old selection cannot open a search-only management detail.
    ui.acquisition_open = false;
    try dvui.testing.settle(JavaFrame.draw);
    try std.testing.expect(ui.acquisition_open);
    try std.testing.expect(JavaFrame.observations[@backingInt(JavaFrame.Text.add)] == null);
    try JavaFrame.expectVisible(.search, "java-page");
    try JavaFrame.scrollPage(-100000);
    const checkbox = try JavaFrame.searchCheckboxControl();
    _ = try window.window.addEventMouseMotion(.{ .pt = checkbox.rect.center() });
    try dvui.testing.click(.left);
    try dvui.testing.settle(JavaFrame.draw);
    try std.testing.expect(ui.search_selection[0]);
    const add = try dvui.testing.tagGet("java-search-add");
    const search = try dvui.testing.tagGet("java-search-start");
    try std.testing.expect(add.rect.x + add.rect.w <= search.rect.x);
    _ = try JavaFrame.clickTag("java-search-add");
    try std.testing.expectEqual(@as(usize, 1), ui.commands.items.len);
    try std.testing.expectEqualStrings(runtime.path, ui.commands.items[0].add[0]);
}

test "UI layout Java folder browse queues after draft edits and blocks stale completion" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    JavaFrame.reset();
    defer JavaFrame.reset();
    const picker = @import("ui/file_picker.zig");
    const Driver = struct {
        fn start(_: ?*anyopaque, pending: *picker.Pending) void {
            pending.complete(.{ .path = "/picked/java" });
        }
    };
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var manager = try java.Manager.init(a, std.testing.io, root);
    defer manager.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var controller = try java_download_controller.Controller.initWithOptions(a, std.testing.io, .{ .root = root, .task_registry = &registry });
    defer controller.deinit();
    var download_ui = java_download_view.Ui.init(a);
    defer download_ui.deinit();
    var service = picker.Service.init(a);
    defer service.deinit();
    var ui = java_view.Ui.init(a);
    defer ui.deinit();
    ui.picker_service = &service;
    ui.acquisition_mode = .local;
    JavaFrame.ui = &ui;
    JavaFrame.download_ui = &download_ui;
    JavaFrame.controller = &controller;
    JavaFrame.manager = &manager;
    JavaFrame.interactive = true;
    var window = try dvui.testing.init(.{ .window_size = .{ .w = 640, .h = 400 } });
    defer window.deinit();
    window.backend.size_pixels = .{ .w = 640, .h = 400 };
    try dvui.testing.settle(JavaFrame.draw);
    const browse = try dvui.testing.tagGet("java-search-browse");
    try expectInside((try dvui.testing.tagGet("java-page")).rect, browse.rect);
    try JavaFrame.expectTabRegistration(.{ .id = browse.id, .rect = browse.rect }, true);
    const field = try dvui.testing.tagGet("java-search-path");
    dvui.focusWidget(field.id, null, null);
    try dvui.testing.writeText("/draft/latest");
    _ = try JavaFrame.clickTag("java-search-browse");
    try std.testing.expectEqual(@as(usize, 1), ui.commands.items.len);
    try std.testing.expect(!service.isBusy());
    java_view.finish(&ui, &manager);
    try std.testing.expectEqualStrings("/draft/latest", service.pending.?.default_path);
    try dvui.testing.settle(JavaFrame.draw);
    const disabled_browse = try dvui.testing.tagGet("java-search-browse");
    try JavaFrame.expectTabRegistration(.{ .id = disabled_browse.id, .rect = disabled_browse.rect }, false);
    // An edit and undo still invalidates the pending receipt.
    dvui.focusWidget(field.id, null, null);
    try dvui.testing.pressKey(.a, .lcontrol);
    try dvui.testing.pressKey(.backspace, .none);
    try dvui.testing.writeText("/edited/java");
    try dvui.testing.settle(JavaFrame.draw);
    try std.testing.expect(ui.picker_path_changed);
    @memset(&ui.path_buffer, 0);
    @memcpy(ui.path_buffer[0.."/draft/latest".len], "/draft/latest");
    service.startPending(.{ .start = Driver.start });
    java_view.syncPicker(&ui);
    try std.testing.expectEqualStrings("/draft/latest", std.mem.sliceTo(&ui.path_buffer, 0));
    try std.testing.expect(!service.isBusy());
    try dvui.testing.settle(JavaFrame.draw);
    // A completed picker and Search compete in the same frame. Search owns the
    // current draft and discards the picker before the app synchronizes receipts.
    _ = try JavaFrame.clickTag("java-search-browse");
    java_view.finish(&ui, &manager);
    service.startPending(.{ .start = Driver.start });
    try std.testing.expect(ui.picker_ticket != null);
    try std.testing.expect(service.isBusy());
    _ = try JavaFrame.clickTag("java-search-start");
    try std.testing.expect(ui.picker_ticket == null);
    try std.testing.expect(!service.isBusy());
    try std.testing.expectEqual(@as(usize, 1), ui.commands.items.len);
    try std.testing.expectEqualStrings("/draft/latest", ui.commands.items[0].search);
    java_view.syncPicker(&ui);
    try std.testing.expectEqualStrings("/draft/latest", std.mem.sliceTo(&ui.path_buffer, 0));
    java_view.discardCommands(&ui);
    try dvui.testing.settle(JavaFrame.draw);
    _ = try JavaFrame.clickTag("java-search-browse");
    java_view.finish(&ui, &manager);
    _ = try JavaFrame.clickTag("java-acquire-download");
    try std.testing.expect(ui.picker_ticket == null);
    try std.testing.expect(!service.isBusy());
    _ = try JavaFrame.clickTag("java-acquire-local");
    try manager.state.search_visible.append(manager.state.arena.allocator(), .{ .path = "/fixture/previous/java", .vendor = "Previous", .major = 21 });
    try dvui.testing.settle(JavaFrame.draw);
    ui.search_selection[0] = true;
    _ = try JavaFrame.clickTag("java-search-browse");
    java_view.finish(&ui, &manager);
    service.startPending(.{ .start = Driver.start });
    // A scan started independently also invalidates the picker before sync,
    // while checkbox choices stay untouched until scanner results change.
    try manager.search("/fixture/old-search-root");
    try std.testing.expect(manager.isSearching());
    try dvui.testing.settle(JavaFrame.draw);
    java_view.syncPicker(&ui);
    try std.testing.expect(ui.picker_ticket == null);
    try std.testing.expect(!service.isBusy());
    try std.testing.expectEqualStrings("/draft/latest", std.mem.sliceTo(&ui.path_buffer, 0));
    try std.testing.expect(ui.search_selection[0]);
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
        const sample = observations[@backingInt(action)] orelse return error.JavaDeleteLabelNotRendered;
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
            const current = try visibleControl(@fromBackingInt(@intCast(index)));
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
        "/fixture/managed-java/" ++ (comptime blk: {
            const segment = "nested-runtime-directory-with-a-long-name/";
            var repeated: [segment.len * 16]u8 = undefined;
            for (0..16) |i| @memcpy(repeated[i * segment.len ..][0..segment.len], segment);
            break :blk repeated;
        }) ++ "bin/java",
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
                    control.* = try JavaDeleteFrame.visibleControl(@fromBackingInt(@intCast(index)));
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
        dvui.debug.captureScopeBegin(win.gpa);
        defer {
            dvui.debug.captureScopeEnd();
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
        try ServerLayoutFrame.observe(commands.items);
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
    try store.update(.{ .instances = &.{.{ .id = "fixture-font-instance", .name = "Fixture", .minecraft_version = "1.21" }}, .selected_instance = "fixture-font-instance" });
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var server_service = server_manager.Manager.initWithQuery(a, std.testing.io, EditorsFrame.rejectQuery);
    defer server_service.deinit();
    var instance_service = try instances_manager.Manager.init(a, std.testing.io, &paths, &registry, .{}, .{ .context = null, .acquire = EditorsFrame.rejectLease, .recheck = EditorsFrame.rejectLease, .release = EditorsFrame.releaseLease });
    defer instance_service.deinit();
    var server_ui = servers_view.Ui.init(a);
    defer server_ui.deinit();
    server_ui.editor_open = true;
    server_ui.draft.id = try a.dupe(u8, "fixture-font-server");
    var instance_ui = instances_view.Ui.init(a);
    defer instance_ui.deinit();
    instance_ui.draft = try instances_view.Draft.fromInstance(a, .{ .id = "fixture-font-instance", .name = "Fixture", .minecraft_version = "1.21" });
    instance_ui.mode = .options;
    const samples = [_][]const u8{ "Server gypQ", "gypQ.invalid", "25565", "Instance gypQ", "1024", "4096" };
    const buffers = [_][]u8{ &server_ui.draft.name, &server_ui.draft.address, &server_ui.draft.port, &instance_ui.draft.name, &instance_ui.draft.min_memory, &instance_ui.draft.memory };
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
                const field_count: usize = 3;
                EditorTextFrame.samples = @splat("");
                @memcpy(EditorTextFrame.samples[0..field_count], samples[offset..][0..field_count]);
                try dvui.testing.settle(EditorTextFrame.draw);
                const cancel_before = if (!server) try ServerLayoutFrame.visible(6) else null;
                const save_before = if (!server) try ServerLayoutFrame.visible(7) else null;
                if (server) {
                    try std.testing.expect(ServerLayoutFrame.controls[6] == null and ServerLayoutFrame.controls[7] == null);
                    _ = try dvui.testing.tagGet("server-delete");
                } else {
                    const cancel = try ServerLayoutFrame.visible(6);
                    const save_control = try ServerLayoutFrame.visible(7);
                    try std.testing.expect(cancel.id != save_control.id);
                }
                if (server) try ServerLayoutFrame.noCheckbox();
                var inputs: [3]dvui.Id = undefined;
                var widths: [3]f32 = undefined;
                var count: usize = 0;
                for (window.window.tab_index_prev.items) |entry| {
                    if (dvui.dataGet(null, entry.widgetId, "_edited_outside", bool) == null) continue;
                    try std.testing.expect(count < inputs.len);
                    inputs[count] = entry.widgetId;
                    widths[count] = (entry.rect orelse return error.InputRectangleMissing).w;
                    if (server and count == 2) {
                        // The server port keeps its native 240px numeric entry.
                        try std.testing.expectApproxEqAbs(@as(f32, 240), widths[count], 0.01);
                    } else {
                        // Entries fill the Bento panel within the page margins.
                        if (!server and count > 0 and size.w >= 1280) {
                            try std.testing.expect(widths[count] >= vela_theme.bodyFont().textSize("最大内存（MiB）").w);
                            try std.testing.expect(widths[count] < size.w - 112);
                        } else try std.testing.expect(widths[count] >= size.w - 112);
                    }
                    count += 1;
                }
                try std.testing.expectEqual(field_count, count);
                for (inputs[0..count], 0..) |id, index| {
                    dvui.focusWidget(id, null, null);
                    try dvui.testing.settle(EditorTextFrame.draw);
                    if (!server) {
                        const current_cancel = try ServerLayoutFrame.visible(6);
                        const current_save = try ServerLayoutFrame.visible(7);
                        try std.testing.expectEqual(cancel_before.?.id, current_cancel.id);
                        try std.testing.expectEqual(save_before.?.id, current_save.id);
                        try std.testing.expectApproxEqAbs(cancel_before.?.rect.y, current_cancel.rect.y, 0.1);
                        try std.testing.expectApproxEqAbs(save_before.?.rect.y, current_save.rect.y, 0.1);
                    }
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
                try std.testing.expectEqual(@as(usize, 1), store.snapshot().instances.len);
                try std.testing.expectEqual(@as(usize, 0), store.snapshot().servers.len);
            }
        }
    }
}

const WorldsTextFrame = struct {
    const source: config.Instance = .{ .id = "fixture-world-font", .name = "Fixture", .minecraft_version = "1.21.4" };
    const recovery_id = "0123456789abcdef0123456789abcdef";
    var samples = [_][]const u8{
        "World gypQ",
        // The card description retains its explicit line separator in commands.
        "文件夹：world-gypQ · 生存模式\n",
        "最后游玩：",
        "世界备份",
        "",
        "备份 · 6",
        "正在游玩",
        "世界备份 · 被替换数据",
    };
    var ui: *worlds_view.Ui = undefined;
    var manager: *worlds_manager.Manager = undefined;
    var document: *const config.Document = undefined;
    var controls_enabled = true;
    var native_geometry = false;
    const TextFragments = struct {
        bytes: [128]u8 = undefined,
        length: usize = 0,
        fragments: [128]RenderedTextBounds = undefined,
        count: usize = 0,
    };
    var observed: [samples.len]TextFragments = @splat(.{});
    var preview_corners: ?dvui.CornerRect = null;
    var playing_card_has_date = false;
    var playing_status_accent = false;
    var card_has_version = false;
    var card_text: [512]u8 = undefined;
    var card_text_length: usize = 0;

    fn observeFragments(commands: []const dvui.RenderCommand) !void {
        observed = @splat(.{});
        preview_corners = null;
        playing_card_has_date = false;
        playing_status_accent = false;
        card_has_version = false;
        card_text_length = 0;
        const first_card = dvui.tagGet("world-card-world-gypQ");
        const preview = dvui.tagGet("world-preview-world-gypQ");
        var active: ?usize = null;
        for (commands) |command| switch (command.cmd) {
            .text => |text| {
                if (first_card) |card| if (card.rect.contains(text.rs.r.center())) {
                    if (card_text_length + text.text.len > card_text.len) return error.WorldCardTextCaptureOverflow;
                    @memcpy(card_text[card_text_length..][0..text.text.len], text.text);
                    card_text_length += text.text.len;
                    const date = if (std.mem.startsWith(u8, samples[2], "最后游玩：")) samples[2]["最后游玩：".len..] else samples[2];
                    const local_date = date[0..10];
                    if (std.mem.indexOf(u8, text.text, "版本：") != null or std.mem.indexOf(u8, text.text, "1.21.4 gypQ") != null) card_has_version = true;
                    if (std.mem.indexOf(u8, text.text, "最后游玩") != null or std.mem.indexOf(u8, text.text, local_date) != null) playing_card_has_date = true;
                    if (std.mem.eql(u8, text.text, "正在游玩")) playing_status_accent = std.meta.eql(text.color, @import("ui/theme.zig").accent);
                };
                if (text.text.len == 0) continue;
                var matched: ?usize = null;
                if (active) |index| {
                    const remaining = samples[index][observed[index].length..];
                    if (std.mem.startsWith(u8, remaining, text.text)) matched = index else {
                        // A short action label such as 备份 can also prefix the
                        // recovery title. Discard that incomplete candidate.
                        observed[index] = .{};
                        active = null;
                    }
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
            .texture => |texture| {
                if (preview) |image| if (std.meta.eql(texture.rs.r, image.rect)) {
                    preview_corners = texture.opts.corners;
                };
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

    fn ownedBackup(a: std.mem.Allocator, recovery: []const u8, source_id: ?[]const u8, source_folder: []const u8) !worlds.Backup {
        const id = try a.dupe(u8, recovery);
        errdefer a.free(id);
        const directory = try a.dupe(u8, "/unused/recovery-renderer-fixture");
        errdefer a.free(directory);
        const folder = try a.dupe(u8, source_folder);
        errdefer a.free(folder);
        const instance = if (source_id) |value| try a.dupe(u8, value) else null;
        return .{ .id = id, .part = .original, .directory = directory, .source_instance = instance, .source_folder = folder, .operation = .backup, .created_ms = 1735776000000 };
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
        items[0].metadata.game_type = 0;
        // A second card exercises responsive wrapping and selection changes.
        items[1] = try ownedWorld(a, "filler", "Filler");
        errdefer items[1].deinit(a);
        // Keep every observed label unique, including version and timestamp.
        a.free(items[1].metadata.version_name.?);
        items[1].metadata.version_name = null;
        const backups = try a.alloc(worlds.Backup, 6);
        errdefer a.free(backups);
        backups[0] = try ownedBackup(a, recovery_id, source.id, "world-gypQ");
        errdefer backups[0].deinit(a);
        backups[1] = try ownedBackup(a, "11111111111111111111111111111111", source.id, "world-gypQ");
        errdefer backups[1].deinit(a);
        backups[1].created_ms += 60000;
        backups[2] = try ownedBackup(a, "22222222222222222222222222222222", source.id, "world-gypQ");
        errdefer backups[2].deinit(a);
        backups[2].created_ms += 120000;
        backups[2].part = .overwritten;
        // Keep records for other instances, old folders and unknown provenance
        // visible in the instance repository; invalid manifests cannot restore.
        backups[3] = try ownedBackup(a, "33333333333333333333333333333333", "other-instance", "world-gypQ");
        errdefer backups[3].deinit(a);
        backups[4] = try ownedBackup(a, "44444444444444444444444444444444", source.id, "other-world");
        errdefer backups[4].deinit(a);
        backups[5] = try ownedBackup(a, "55555555555555555555555555555555", null, "world-gypQ");
        errdefer backups[5].deinit(a);
        const previews = try a.alloc(worlds_manager.Preview, 1);
        errdefer a.free(previews);
        previews[0].folder = try a.dupe(u8, items[0].folder);
        errdefer a.free(previews[0].folder);
        previews[0].png = try a.dupe(u8, @embedFile("assets/default_skins/alex.png"));
        return .{
            .world_list = .{ .allocator = a, .items = items },
            .backup_list = .{ .allocator = a, .items = backups },
            .previews = previews,
            .preview_allocator = a,
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
        dvui.debug.captureScopeBegin(win.gpa);
        defer dvui.debug.captureScopeEnd();
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
            const root = dvui.box(@src(), .{ .dir = .horizontal }, .{ .tag = "world-font-page", .expand = .both, .padding = dvui.Rect.all(if (native_geometry) 32 else 12) });
            defer root.deinit();
            {
                const sidebar_width: f32 = if (native_geometry) 260 else 240;
                const sidebar = dvui.box(@src(), .{}, .{ .expand = .vertical, .min_size_content = .{ .w = sidebar_width }, .max_size_content = .width(sidebar_width), .margin = .{ .w = if (native_geometry) 24 else 0 } });
                defer sidebar.deinit();
                worlds_view.drawSidebar(ui, document, manager, controls_enabled);
            }
            // Publication stays immutable through rendering; no finish/tick here.
            try worlds_view.drawWithEnabled(ui, document, manager, controls_enabled);
        }
        try observeFragments(commands.items);
        return .ok;
    }

    fn bodyViewport() !dvui.Rect.Physical {
        const page = try dvui.testing.tagGet("worlds-page");
        const capture = dvui.debug.lastCapture() orelse return error.WorldBodyCaptureMissing;
        var body: ?dvui.Debug.CapturedWidget = null;
        for (capture.widgets.items) |widget| {
            if (widget.parent_id != page.id or !std.mem.eql(u8, widget.name orelse continue, "ScrollAreaWidget")) continue;
            if (body != null) return error.WorldBodyViewportDuplicate;
            body = widget;
        }
        return (body orelse return error.WorldBodyViewportMissing).rect_content;
    }

    fn recoveryViewport() !dvui.Rect.Physical {
        const list = try dvui.testing.tagGet("world-recovery-list");
        const capture = dvui.debug.lastCapture() orelse return error.WorldBodyCaptureMissing;
        for (capture.widgets.items) |widget| {
            if (widget.id == list.id) return widget.rect_content;
        }
        return error.WorldRecoveryViewportMissing;
    }

    fn scrollRecovery(amount: f32) !void {
        const viewport = try recoveryViewport();
        _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = viewport.center() });
        _ = try dvui.currentWindow().addEventMouseWheel(amount, .vertical, null);
        try dvui.testing.settle(draw);
    }

    fn scrollPage(amount: f32) !void {
        const viewport = try bodyViewport();
        // Wheel over the captured viewport; the fixed footer never scrolls.
        _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = viewport.center() });
        _ = try dvui.currentWindow().addEventMouseWheel(amount, .vertical, null);
        try dvui.testing.settle(draw);
    }

    fn expectTabStop(tag: []const u8, enabled: bool) !void {
        const widget = try dvui.testing.tagGet(tag);
        var count: usize = 0;
        for (dvui.currentWindow().tab_index_prev.items) |entry| if (entry.widgetId == widget.id) {
            count += 1;
        };
        try std.testing.expectEqual(@as(usize, if (enabled) 1 else 0), count);
    }

    fn reveal(tag: []const u8) !void {
        for (0..6) |_| {
            const widget = try dvui.testing.tagGet(tag);
            const recovery = std.mem.startsWith(u8, tag, "world-backup-item-") or std.mem.startsWith(u8, tag, "world-restore-");
            const viewport = if (recovery) try recoveryViewport() else try bodyViewport();
            const footer = dvui.tagGet("world-selected-actions");
            if (footer) |actions| {
                if (widget.visible and widget.rect.y >= actions.rect.y - 0.1 and widget.rect.y + widget.rect.h <= actions.rect.y + actions.rect.h + 0.1) return;
            }
            if (std.mem.eql(u8, tag, "world-backups-toggle")) {
                const dock = try dvui.testing.tagGet("world-backups");
                try expectInside((try dvui.testing.tagGet("worlds-page")).rect, dock.rect);
                try expectInside(dock.rect, widget.rect);
                try std.testing.expect(widget.visible);
                return;
            }
            // Oversized cards and recovery rows remain accessible when only outer padding is clipped.
            if ((std.mem.startsWith(u8, tag, "world-card-") or std.mem.startsWith(u8, tag, "world-backup-item-")) and widget.rect.h > viewport.h and widget.visible and viewport.contains(widget.rect.center())) return;
            if (widget.visible and widget.rect.y >= viewport.y - 0.1 and widget.rect.y + widget.rect.h <= viewport.y + viewport.h + 0.1) return;
            if (recovery) try scrollRecovery(viewport.center().y - widget.rect.center().y) else try scrollPage(viewport.center().y - widget.rect.center().y);
        }
        const widget = try dvui.testing.tagGet(tag);
        const page = try dvui.testing.tagGet("worlds-page");
        const footer = dvui.tagGet("world-selected-actions");
        std.debug.print("world reveal failed {s}: widget={any}, visible={}, page={any}, footer={any}, viewport={any}\n", .{ tag, widget.rect, widget.visible, page.rect, if (footer) |actions| actions.rect else null, try bodyViewport() });
        return error.WorldWidgetNotFullyVisible;
    }

    fn toggleBackups() !void {
        const previous = ui.backups_expanded;
        try reveal("world-backups-toggle");
        try dvui.testing.moveTo("world-backups-toggle");
        try dvui.testing.settle(draw);
        try dvui.testing.click(.left);
        try dvui.testing.settle(draw);
        if (ui.backups_expanded == previous) {
            const toggle = try dvui.testing.tagGet("world-backups-toggle");
            std.debug.print("backup toggle failed: window={any} font={any} toggle={any} expanded={}\n", .{ dvui.windowRect(), @import("ui/theme.zig").bodyFont().size, toggle.rect, previous });
        }
        try std.testing.expectEqual(!previous, ui.backups_expanded);
    }

    fn expectFooter() !dvui.Rect.Physical {
        const page = try dvui.testing.tagGet("worlds-page");
        const footer = try dvui.testing.tagGet("world-selected-actions");
        try expectInside(page.rect, footer.rect);
        try std.testing.expectApproxEqAbs(page.rect.y + page.rect.h, footer.rect.y + footer.rect.h, 0.1);
        try std.testing.expect(footer.rect.y > page.rect.y + 50);
        for (mutation_tags ++ [_][]const u8{"world-open"}) |tag| {
            const button = try dvui.testing.tagGet(tag);
            try std.testing.expect(button.visible);
            try expectInside(footer.rect, button.rect);
        }
        return footer.rect;
    }

    fn clickTag(tag: []const u8, enabled: bool) !void {
        // Dismiss floating metadata from the previous card before pointer selection.
        try dvui.testing.moveTo("world-refresh");
        try dvui.testing.settle(draw);
        try reveal(tag);
        try expectTabStop(tag, enabled);
        try dvui.testing.moveTo(tag);
        try dvui.testing.click(.left);
        try dvui.testing.settle(draw);
    }

    const mutation_tags = [_][]const u8{ "world-backup", "world-copy", "world-rename", "world-rename-folder", "world-delete" };

    fn expectMutationControls(enabled: bool) !void {
        for (mutation_tags) |tag| try expectTabStop(tag, enabled);
    }

    fn expectNoIntents() !void {
        try std.testing.expect(ui.failure == null and ui.draft == null);
        try std.testing.expect(ui.requests.items.len == 0 and ui.directory_open == null);
        try std.testing.expect(!ui.refresh_queued and !ui.cancel_queued and !ui.select_queued);
    }

    fn expectLines(start: usize, end: usize, size: dvui.Size, font_size: f32) !void {
        for (start..end) |index| {
            const capture = &observed[index];
            errdefer std.debug.print("World/recovery text incomplete: size={any}, font={d}, label={s}, rendered={s}, fragments={d}, card text={s}\n", .{ size, font_size, samples[index], capture.bytes[0..capture.length], capture.count, card_text[0..card_text_length] });
            errdefer std.debug.print("World/recovery allocation: viewport={any}, footer={any}, dock={any}, first row={any}\n", .{ recoveryViewport() catch dvui.Rect.Physical{}, dvui.tagGet("world-selected-actions"), dvui.tagGet("world-backups"), dvui.tagGet("world-backup-item-" ++ recovery_id ++ "-original") });
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
                // Card headings/captions keep their semantic font sizes;
                // Backup dates follow the selected body font.
                if (font_size == 24 and index == 4) try std.testing.expect(text.font_height > 20);
                if (fragment > 0) {
                    const previous = capture.fragments[fragment - 1].rect;
                    try std.testing.expect(text.rect.y >= previous.y + previous.h - 0.1);
                }
            }
        }
    }
};

test "UI layout world cards, selected actions and recovery remain responsive and safe" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    const a = std.testing.allocator;
    // Labels borrow these test-scope buffers across every rendered frame.
    var world_time_buffer: [16]u8 = undefined;
    var backup_time_buffer: [16]u8 = undefined;
    var world_date_label: [64]u8 = undefined;
    const world_time = @import("ui/local_time.zig").format(&world_time_buffer, 1735689600000) orelse return error.WorldLocalTimestampUnavailable;
    const backup_time = @import("ui/local_time.zig").format(&backup_time_buffer, 1735776000000) orelse return error.BackupLocalTimestampUnavailable;
    WorldsTextFrame.samples[2] = try std.fmt.bufPrint(&world_date_label, "最后游玩：{s}", .{world_time});
    WorldsTextFrame.samples[4] = backup_time;
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
    const target: config.Instance = .{ .id = "fixture-world-target", .name = "Target", .minecraft_version = "1.21.4" };
    const document: config.Document = .{ .instances = &.{ WorldsTextFrame.source, target }, .selected_instance = WorldsTextFrame.source.id };
    WorldsTextFrame.ui = &ui;
    WorldsTextFrame.manager = &manager;
    WorldsTextFrame.document = &document;
    // Exercise real worker JOIN/publication before any frame borrows list strings.
    try WorldsTextFrame.publish(&manager);
    const snapshot = manager.snapshot();
    try std.testing.expect(snapshot.failure == null and !snapshot.loading and !snapshot.worker_active);
    try std.testing.expectEqual(@as(usize, 2), snapshot.worlds.len);
    try std.testing.expectEqual(@as(usize, 6), snapshot.backups.len);
    const Layout = struct { size: dvui.Size, native_geometry: bool = false };
    for ([_]Layout{
        .{ .size = .{ .w = 640, .h = 400 } },
        .{ .size = .{ .w = 640, .h = 400 }, .native_geometry = true },
        .{ .size = .{ .w = 1280, .h = 720 } },
    }) |layout| {
        const size = layout.size;
        WorldsTextFrame.native_geometry = layout.native_geometry;
        // Compact cards show each metadata field on its own bounded line.
        WorldsTextFrame.samples[0] = "World gypQ";
        WorldsTextFrame.samples[1] = if (layout.native_geometry) "world-gypQ\n生存模式" else if (size.w == 640) "world-gypQ\n生存模式\n" else "文件夹：world-gypQ · 生存模式\n";
        WorldsTextFrame.samples[2] = if (size.w == 640) world_time else world_date_label[0 .. "最后游玩：".len + world_time.len];
        WorldsTextFrame.samples[7] = if (size.w == 640) "世界备份 · 已替换" else "世界备份 · 被替换数据";
        for ([_]f32{ 16, 24 }) |font_size| {
            var window = try dvui.testing.init(.{ .window_size = size });
            defer window.deinit();
            window.backend.size_pixels = .{ .w = size.w, .h = size.h };
            var theme = dvui.themeGet();
            theme.font_body = theme.font_body.withSize(font_size);
            theme.font_heading = theme.font_body.withSize(18);
            theme.font_title = theme.font_body.withSize(24);
            window.window.themeSet(theme);
            if (ui.selected_world) |old| a.free(old);
            ui.selected_world = null;
            ui.backups_expanded = false;
            WorldsTextFrame.controls_enabled = true;
            try dvui.testing.settle(WorldsTextFrame.draw);
            try WorldsTextFrame.scrollPage(100000);
            try WorldsTextFrame.expectLines(0, 1, size, font_size);
            try WorldsTextFrame.expectLines(1, 3, size, font_size);
            try std.testing.expect(!WorldsTextFrame.card_has_version);
            try std.testing.expect(dvui.tagGet("world-selected-details") == null);
            try std.testing.expect(dvui.tagGet("world-selected-actions") == null);
            try std.testing.expect(dvui.tagGet("world-backups") != null);
            try std.testing.expect(dvui.tagGet("world-backups-toggle") != null);
            try std.testing.expect(dvui.tagGet("world-recovery-list") == null);
            for (WorldsTextFrame.mutation_tags) |tag| try std.testing.expect(dvui.tagGet(tag) == null);
            const card = try dvui.testing.tagGet("world-card-world-gypQ");
            const second = try dvui.testing.tagGet("world-card-filler");
            const preview = try dvui.testing.tagGet("world-preview-world-gypQ");
            try std.testing.expectApproxEqAbs(@as(f32, 64), preview.rect.w, 0.1);
            try std.testing.expectApproxEqAbs(@as(f32, 64), preview.rect.h, 0.1);
            try expectInside(card.rect, preview.rect);
            if (layout.native_geometry) {
                const date = &WorldsTextFrame.observed[2];
                for (date.fragments[0..date.count]) |fragment| {
                    try expectInside(card.rect, fragment.rect);
                    try std.testing.expect(fragment.rect.y >= preview.rect.y + preview.rect.h or fragment.rect.x >= preview.rect.x + preview.rect.w);
                }
            }
            try std.testing.expectEqualDeep(dvui.CornerRect.round(10), WorldsTextFrame.preview_corners orelse return error.WorldPreviewRenderMissing);
            try WorldsTextFrame.expectTabStop("world-preview-world-gypQ", false);
            try WorldsTextFrame.expectTabStop("world-refresh", true);
            if (size.w == 640) {
                try std.testing.expectApproxEqAbs(card.rect.x, second.rect.x, 0.1);
                try std.testing.expect(second.rect.y >= card.rect.y + card.rect.h);
            } else {
                try std.testing.expectApproxEqAbs(card.rect.y, second.rect.y, 0.1);
                try std.testing.expect(second.rect.x > card.rect.x + card.rect.w);
            }
            const top_y = WorldsTextFrame.observed[0].fragments[0].rect.y;
            try WorldsTextFrame.clickTag("world-card-world-gypQ", true);
            try std.testing.expectEqualStrings("world-gypQ", ui.selected_world.?);
            const selected_check = try dvui.testing.tagGet("world-card-world-gypQ-selected");
            const selected_preview = try dvui.testing.tagGet("world-preview-world-gypQ");
            try std.testing.expectApproxEqAbs(selected_preview.rect.center().y, selected_check.rect.center().y, 0.1);
            const footer = try WorldsTextFrame.expectFooter();
            try WorldsTextFrame.expectMutationControls(true);
            try std.testing.expect(dvui.tagGet("world-selected-details") == null);
            if (layout.native_geometry) {
                const page = try dvui.testing.tagGet("worlds-page");
                try std.testing.expectApproxEqAbs(@as(f32, 292), page.rect.w, 0.1);
                try std.testing.expectApproxEqAbs(@as(f32, 336), page.rect.h, 0.1);
                if (font_size == 16) {
                    const viewport = try WorldsTextFrame.bodyViewport();
                    const selected_card = try dvui.testing.tagGet("world-card-world-gypQ");
                    const visible_card = selected_card.rect.intersect(viewport);
                    try std.testing.expect(visible_card.w > 0 and visible_card.h > 0);
                    try std.testing.expect(viewport.y + viewport.h <= footer.y + 0.1);
                    for (WorldsTextFrame.observed[0..3]) |text| for (text.fragments[0..text.count]) |fragment| {
                        const visible_text = fragment.rect.intersect(fragment.clip);
                        if (visible_text.w > 0 and visible_text.h > 0) try expectInside(viewport, visible_text);
                    };
                    // The compact body can be shorter than its selected card.
                    // Real wheel input reveals the complete bottom caption and preview.
                    try WorldsTextFrame.scrollPage(@min(@as(f32, 0), viewport.y + viewport.h - selected_card.rect.y - selected_card.rect.h) - 1);
                    const scrolled_card = try dvui.testing.tagGet("world-card-world-gypQ");
                    try std.testing.expect(scrolled_card.rect.y < selected_card.rect.y);
                    try std.testing.expect(scrolled_card.rect.y + scrolled_card.rect.h <= viewport.y + viewport.h + 0.1);
                    try expectInside(viewport, (try dvui.testing.tagGet("world-preview-world-gypQ")).rect);
                    try WorldsTextFrame.expectLines(2, 3, size, font_size);
                    try std.testing.expectEqualDeep(footer, try WorldsTextFrame.expectFooter());
                    try WorldsTextFrame.scrollPage(100000);
                }
            }
            try std.testing.expect(!ui.backups_expanded);
            try std.testing.expect(dvui.tagGet("world-recovery-list") == null);
            const restore_tag = "world-restore-" ++ WorldsTextFrame.recovery_id ++ "-original";
            try std.testing.expect(dvui.tagGet(restore_tag) == null);
            try WorldsTextFrame.reveal("world-backups-toggle");
            try WorldsTextFrame.expectLines(5, 6, size, font_size);
            const backup_section = try dvui.testing.tagGet("world-backups");
            try std.testing.expect(backup_section.rect.y + backup_section.rect.h <= footer.y + 0.1);

            try WorldsTextFrame.toggleBackups();
            try std.testing.expect(dvui.tagGet("world-recovery-list") != null);
            const first_row_tag = "world-backup-item-" ++ WorldsTextFrame.recovery_id ++ "-original";
            try std.testing.expect(dvui.tagGet(first_row_tag) != null);
            try std.testing.expect(dvui.tagGet("world-backup-item-11111111111111111111111111111111-original") != null);
            try std.testing.expect(dvui.tagGet("world-backup-item-22222222222222222222222222222222-overwritten") != null);
            for ([_][]const u8{
                "world-backup-item-33333333333333333333333333333333-original",
                "world-backup-item-44444444444444444444444444444444-original",
                "world-backup-item-55555555555555555555555555555555-original",
            }) |tag| try std.testing.expect(dvui.tagGet(tag) != null);
            try WorldsTextFrame.expectTabStop("world-restore-55555555555555555555555555555555-original", false);
            try WorldsTextFrame.reveal(first_row_tag);
            try WorldsTextFrame.expectLines(3, 5, size, font_size);
            const first_row = try dvui.testing.tagGet(first_row_tag);
            const viewport = try WorldsTextFrame.recoveryViewport();
            const visible_first_row = first_row.rect.intersect(viewport);
            try std.testing.expect(visible_first_row.w > 0 and visible_first_row.h > 0);
            const first_restore = try dvui.testing.tagGet(restore_tag);
            try expectInside(first_row.rect, first_restore.rect);
            try expectInside(viewport, first_restore.rect);
            const date = WorldsTextFrame.observed[4].fragments[0];
            const caption = WorldsTextFrame.observed[3].fragments[0];
            try expectInside(first_row.rect, date.rect);
            try expectInside(first_row.rect, caption.rect);
            try expectInside(viewport, date.rect);
            try expectInside(viewport, caption.rect);
            try std.testing.expect(caption.rect.y >= date.rect.y + date.rect.h - 0.1);
            try std.testing.expect(first_restore.rect.x >= date.rect.x + date.rect.w - 0.1);
            try WorldsTextFrame.expectTabStop(restore_tag, true);
            try std.testing.expectEqualDeep(footer, try WorldsTextFrame.expectFooter());
            try WorldsTextFrame.scrollRecovery(-100000);
            try WorldsTextFrame.reveal("world-backup-item-22222222222222222222222222222222-overwritten");
            try WorldsTextFrame.expectLines(7, 8, size, font_size);
            const last_row = try dvui.testing.tagGet("world-backup-item-22222222222222222222222222222222-overwritten");
            const last_viewport = try WorldsTextFrame.recoveryViewport();
            const visible_last_row = last_row.rect.intersect(last_viewport);
            try std.testing.expect(visible_last_row.w > 0 and visible_last_row.h > 0);
            try expectInside(last_viewport, (try dvui.testing.tagGet("world-restore-22222222222222222222222222222222-overwritten")).rect);
            try WorldsTextFrame.expectTabStop("world-restore-22222222222222222222222222222222-overwritten", true);
            try std.testing.expectEqualDeep(footer, try WorldsTextFrame.expectFooter());
            if (size.h == 400) {
                const first = &WorldsTextFrame.observed[0];
                try std.testing.expect(first.count == 0 or @abs(first.fragments[0].rect.y - top_y) < 1);
            }
            // A retained failure occupies the body without displacing the actions.
            ui.failure = error.PermissionDenied;
            try dvui.testing.settle(WorldsTextFrame.draw);
            try std.testing.expectEqualDeep(footer, try WorldsTextFrame.expectFooter());
            ui.failure = null;
            try dvui.testing.settle(WorldsTextFrame.draw);
            try WorldsTextFrame.toggleBackups();
            try std.testing.expect(dvui.tagGet("world-recovery-list") == null);
            try std.testing.expect(dvui.tagGet(restore_tag) == null);
            try std.testing.expectEqualDeep(footer, try WorldsTextFrame.expectFooter());

            try WorldsTextFrame.toggleBackups();
            // The instance backup repository stays visible when the live world changes.
            try WorldsTextFrame.clickTag("world-card-world-gypQ", true);
            try std.testing.expect(ui.backups_expanded);
            try WorldsTextFrame.clickTag("world-card-filler", true);
            try std.testing.expectEqualStrings("filler", ui.selected_world.?);
            try std.testing.expect(ui.backups_expanded);
            try std.testing.expect(dvui.tagGet("world-backups-toggle") != null);
            try std.testing.expect(dvui.tagGet("world-recovery-list") != null);
            try std.testing.expect(dvui.tagGet(restore_tag) != null);
            _ = try WorldsTextFrame.expectFooter();
            try WorldsTextFrame.clickTag("world-card-world-gypQ", true);
            try std.testing.expect(ui.backups_expanded);
            try std.testing.expect(dvui.tagGet("world-backups-toggle") != null);
            try std.testing.expect(dvui.tagGet("world-recovery-list") != null);
            try WorldsTextFrame.toggleBackups();
            try WorldsTextFrame.expectNoIntents();

            // A running instance keeps inspection available and blocks every mutation.
            if (size.w == 1280) {
                try WorldsTextFrame.toggleBackups();
                try coordinator.reserveLaunch(WorldsTextFrame.source.id);
                try dvui.testing.settle(WorldsTextFrame.draw);
                try WorldsTextFrame.expectMutationControls(false);
                try WorldsTextFrame.expectTabStop("world-open", true);
                try WorldsTextFrame.expectTabStop(restore_tag, false);
                for (WorldsTextFrame.mutation_tags) |tag| try WorldsTextFrame.clickTag(tag, false);
                try WorldsTextFrame.clickTag(restore_tag, false);
                try WorldsTextFrame.expectNoIntents();
                coordinator.releaseLaunch();
                coordinator.tick();

                // The world lock is separate from the instance running guard.
                manager.published.?.result.world_list.?.items[0].access = .in_use;
                try dvui.testing.settle(WorldsTextFrame.draw);
                try WorldsTextFrame.scrollPage(100000);
                try WorldsTextFrame.expectLines(6, 7, size, font_size);
                try std.testing.expect(!WorldsTextFrame.playing_card_has_date);
                try std.testing.expect(WorldsTextFrame.playing_status_accent);
                try WorldsTextFrame.expectMutationControls(false);
                try WorldsTextFrame.expectTabStop("world-open", true);
                for (WorldsTextFrame.mutation_tags) |tag| try WorldsTextFrame.clickTag(tag, false);
                try WorldsTextFrame.expectTabStop(restore_tag, false);
                try WorldsTextFrame.clickTag(restore_tag, false);
                try WorldsTextFrame.expectNoIntents();
                manager.published.?.result.world_list.?.items[0].access = .available;

                // A pending scan retains selectable cards but disables modifications.
                try manager.refresh();
                try dvui.testing.settle(WorldsTextFrame.draw);
                try WorldsTextFrame.expectMutationControls(false);
                try WorldsTextFrame.expectTabStop("world-open", true);
                for (WorldsTextFrame.mutation_tags) |tag| try WorldsTextFrame.clickTag(tag, false);
                try WorldsTextFrame.clickTag("world-card-filler", true);
                try std.testing.expectEqualStrings("filler", ui.selected_world.?);
                try WorldsTextFrame.clickTag("world-card-world-gypQ", true);
                try std.testing.expect(ui.backups_expanded);
                try WorldsTextFrame.clickTag(restore_tag, false);
                try WorldsTextFrame.expectNoIntents();
                manager.cancel();

                WorldsTextFrame.controls_enabled = false;
                try dvui.testing.settle(WorldsTextFrame.draw);
                try WorldsTextFrame.expectMutationControls(false);
                try WorldsTextFrame.clickTag("world-card-filler", false);
                try WorldsTextFrame.clickTag("world-open", false);
                try WorldsTextFrame.clickTag(restore_tag, false);
                try std.testing.expectEqualStrings("world-gypQ", ui.selected_world.?);
                try WorldsTextFrame.expectNoIntents();
                WorldsTextFrame.controls_enabled = true;
            }
            try std.testing.expect(!manager.snapshot().worker_active);
            try std.testing.expectEqual(@as(usize, 0), registry.entries.items.len);
        }
    }
}

const AccountEditorFrame = struct {
    const validation_text = "用户名须为 3–16 位字母、数字或下划线";
    const labels = [_][]const u8{ "取消", "离线登录", "微软登录" };
    const tags = [_][]const u8{ "account-cancel", "account-offline-login", "account-microsoft-login" };
    const Footer = struct { id: dvui.Id, parent_id: dvui.Id, window_id: dvui.Id, label_id: dvui.Id, rect: dvui.Rect.Physical, text: dvui.Rect.Physical, clip: dvui.Rect.Physical };
    var ui: *accounts_view.Ui = undefined;
    var store: *config.Store = undefined;
    var manager: *accounts_manager.Manager = undefined;
    var footers: [labels.len]?Footer = @splat(null);
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
            accounts_view.draw(ui, store, manager, null);
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
        var controls: [tags.len]dvui.Debug.CapturedWidget = undefined;
        for (tags, 0..) |tag_name, index| {
            const tag = try dvui.testing.tagGet(tag_name);
            var button: ?dvui.Debug.CapturedWidget = null;
            for (capture.widgets.items) |widget| {
                if (widget.id != tag.id) continue;
                try std.testing.expectEqual(modal_id, widget.subwindow_id);
                try std.testing.expectEqualStrings("Button", widget.name orelse "");
                try std.testing.expectEqualStrings("drawEditor", widget.src_fn);
                try std.testing.expect(std.mem.endsWith(u8, widget.src_file, "accounts_view.zig"));
                try uniqueWidget(&button, widget);
            }
            controls[index] = button orelse return error.AccountEditorFooterMissing;
            try std.testing.expectEqual(tag.rect, controls[index].rect_border);
        }
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

    fn observe(commands: []const dvui.RenderCommand, modal_id: dvui.Id, controls: [labels.len]dvui.Debug.CapturedWidget) !void {
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
                for (labels, 0..) |label, index| if (std.mem.eql(u8, text.text, label)) {
                    const widget = controls[index];
                    var row: ?dvui.Debug.CapturedWidget = null;
                    for (capture.widgets.items) |child| {
                        if (child.subwindow_id != modal_id or child.parent_id != widget.id or
                            !std.mem.eql(u8, child.name orelse continue, "Box") or
                            !std.mem.eql(u8, child.src_fn, "button") or
                            !std.mem.endsWith(u8, child.src_file, "components.zig")) continue;
                        try uniqueWidget(&row, child);
                    }
                    const row_id = (row orelse return error.AccountEditorFooterRowMissing).id;
                    var owned_label: ?dvui.Debug.CapturedWidget = null;
                    for (capture.widgets.items) |child| {
                        if (child.subwindow_id != modal_id or child.parent_id != row_id or
                            !std.mem.eql(u8, child.name orelse continue, "Label") or
                            !std.mem.eql(u8, child.src_fn, "button") or
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
        const tag = try dvui.testing.tagGet(tags[index]);
        try std.testing.expect(tag.visible);
        try std.testing.expectEqual(footer.id, tag.id);
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
        // Name validation happens on submission; all three actions stay reachable.
        try std.testing.expectEqual(@as(usize, 1), registered);
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

test "UI layout real account editor keeps submission errors and three footer actions visible with native cancellation" {
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
            var controls: [AccountEditorFrame.labels.len]AccountEditorFrame.Footer = undefined;
            for (&controls, 0..) |*control, index| control.* = try AccountEditorFrame.visibleFooter(index);
            try std.testing.expect(ui.failure == null and ui.pending == null);
            try std.testing.expectEqual(@as(usize, 0), AccountEditorFrame.validation_count);
            try std.testing.expectEqual(@as(usize, 0), AccountEditorFrame.validation_length);
            _ = try window.window.addEventMouseMotion(.{ .pt = .{ .x = size.w / 2, .y = size.h / 2 } });
            _ = try window.window.addEventMouseWheel(-100000, .vertical, null);
            try dvui.testing.settle(AccountEditorFrame.draw);
            try std.testing.expectEqual(@as(usize, 0), AccountEditorFrame.validation_count);
            for (controls, 0..) |control, index| try std.testing.expectEqual(control.rect, (try AccountEditorFrame.visibleFooter(index)).rect);
            // An invalid name remains editable and is validated by the real submit action.
            try AccountEditorFrame.click(1);
            try std.testing.expect(ui.pending != null and ui.pending.?.action == .save and ui.editor_open);
            try std.testing.expectEqualStrings(invalid_name, ui.pending.?.text.?);
            accounts_view.finish(&ui, &store, &manager);
            try std.testing.expect(ui.pending == null and ui.editor_open);
            try std.testing.expectEqual(error.InvalidAccountName, ui.failure.?);
            try std.testing.expectEqualStrings(invalid_name, std.mem.sliceTo(&ui.draft.name, 0));
            try dvui.testing.settle(AccountEditorFrame.draw);
            if (size.h >= 400) try AccountEditorFrame.expectValidation();
            _ = try window.window.addEventMouseMotion(.{ .pt = .{ .x = size.w / 2, .y = size.h / 2 } });
            _ = try window.window.addEventMouseWheel(-100000, .vertical, null);
            try dvui.testing.settle(AccountEditorFrame.draw);
            try AccountEditorFrame.expectValidation();
            for (controls, 0..) |control, index| try std.testing.expectEqual(control.rect, (try AccountEditorFrame.visibleFooter(index)).rect);
            // Tab reaches every action, including offline submission despite the invalid draft.
            var visited: [AccountEditorFrame.labels.len]bool = @splat(false);
            const tab_steps = window.window.tab_index_prev.items.len + 1;
            for (0..tab_steps) |_| {
                try dvui.testing.pressKey(.tab, .none);
                try dvui.testing.settle(AccountEditorFrame.draw);
                for (controls, 0..) |control, index| if (dvui.focusedWidgetId() == control.id) {
                    visited[index] = true;
                };
                try std.testing.expect(ui.pending == null and ui.editor_open);
            }
            for (visited) |seen| try std.testing.expect(seen);
            for (0..tab_steps) |_| {
                if (dvui.focusedWidgetId() == controls[1].id) break;
                try dvui.testing.pressKey(.tab, .none);
                try dvui.testing.settle(AccountEditorFrame.draw);
            }
            try std.testing.expectEqual(controls[1].id, dvui.focusedWidgetId().?);
            try dvui.testing.pressKey(.enter, .none);
            try dvui.testing.settle(AccountEditorFrame.draw);
            try std.testing.expect(ui.pending != null and ui.pending.?.action == .save);
            accounts_view.finish(&ui, &store, &manager);
            try std.testing.expectEqual(error.InvalidAccountName, ui.failure.?);
            try std.testing.expectEqualStrings(invalid_name, std.mem.sliceTo(&ui.draft.name, 0));
            if (font_size == 16) {
                try AccountEditorFrame.click(0);
            } else {
                for (0..tab_steps) |_| {
                    if (dvui.focusedWidgetId() == controls[0].id) break;
                    try dvui.testing.pressKey(.tab, .none);
                    try dvui.testing.settle(AccountEditorFrame.draw);
                }
                try std.testing.expectEqual(controls[0].id, dvui.focusedWidgetId().?);
                try dvui.testing.pressKey(.enter, .none);
                try dvui.testing.settle(AccountEditorFrame.draw);
            }
            try std.testing.expect(ui.pending != null and ui.pending.?.action == .close_editor and ui.editor_open);
            accounts_view.finish(&ui, &store, &manager);
            try std.testing.expect(ui.pending == null and !ui.editor_open and ui.failure == null);
            try std.testing.expectEqualStrings("", std.mem.sliceTo(&ui.draft.name, 0));
            try std.testing.expectEqual(@as(usize, 0), store.snapshot().accounts.len);
            try std.testing.expect(store.snapshot().selected_account == null);
            try std.testing.expect(!manager.snapshot().busy);
        }
    }
}

const FixedModalFrame = struct {
    var custom_header = false;
    var open = true;
    var clicks: usize = 0;
    var rect: dvui.Rect = .{};
    var id: dvui.Id = undefined;

    fn draw() !dvui.App.Result {
        const modal = if (custom_header)
            components.modalPanel(@src(), "固定弹窗", 560, &open)
        else
            components.modalWithClose(@src(), "固定弹窗", 280, &open);
        defer modal.deinit();
        rect = modal.data().rect;
        id = modal.data().id;
        if (custom_header) components.title(@src(), "自定义标题");
        const body = dvui.box(@src(), .{}, .{ .expand = .both });
        body.deinit();
        if (components.button(@src(), "关闭", .{ .tag = "fixed-modal-close" })) clicks += 1;
        return .ok;
    }

    fn expectCentered(size: dvui.Size) !void {
        try std.testing.expectApproxEqAbs(size.w / 2, rect.x + rect.w / 2, 0.1);
        try std.testing.expectApproxEqAbs(size.h / 2, rect.y + rect.h / 2, 0.1);
        try std.testing.expect(rect.x >= 16 and rect.y >= 16);
        try std.testing.expect(rect.x + rect.w <= size.w - 16 + 0.1);
        try std.testing.expect(rect.y + rect.h <= size.h - 16 + 0.1);
    }
};

test "UI layout fixed modals stay centered through resize and ignore mouse dragging" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    for ([_]bool{ false, true }) |custom_header| {
        for ([_]f32{ 1, 2 }) |scale| {
            FixedModalFrame.custom_header = custom_header;
            FixedModalFrame.open = true;
            FixedModalFrame.clicks = 0;
            var window = try dvui.testing.init(.{ .window_size = .{ .w = 1280, .h = 720 } });
            defer window.deinit();
            for ([_]dvui.Size{ .{ .w = 1280, .h = 720 }, .{ .w = 640, .h = 400 }, .{ .w = 420, .h = 300 }, .{ .w = 1560, .h = 900 } }) |size| {
                window.backend.size = .cast(size);
                window.backend.size_pixels = size.scale(scale, dvui.Size.Physical);
                _ = try dvui.testing.step(FixedModalFrame.draw);
                try dvui.testing.settle(FixedModalFrame.draw);
                try FixedModalFrame.expectCentered(size);
                const before = FixedModalFrame.rect;
                // Exercise both the header and unused body: DVUI normally drags either.
                for ([_]f32{ 30, before.h / 2 }) |offset| {
                    const start: dvui.Point.Physical = .{ .x = (before.x + 100) * scale, .y = (before.y + offset) * scale };
                    _ = try window.window.addEventMouseMotion(.{ .pt = start });
                    try dvui.testing.settle(FixedModalFrame.draw);
                    _ = try window.window.addEventMouseButton(.left, .press);
                    try dvui.testing.settle(FixedModalFrame.draw);
                    try std.testing.expect(!dvui.captured(FixedModalFrame.id));
                    _ = try window.window.addEventMouseMotion(.{ .pt = .{ .x = start.x + 50 * scale, .y = start.y + 30 * scale } });
                    try dvui.testing.settle(FixedModalFrame.draw);
                    _ = try window.window.addEventMouseButton(.left, .release);
                    try dvui.testing.settle(FixedModalFrame.draw);
                    try std.testing.expectEqual(before, FixedModalFrame.rect);
                    try FixedModalFrame.expectCentered(size);
                }
                try dvui.testing.moveTo("fixed-modal-close");
                try dvui.testing.settle(FixedModalFrame.draw);
                try dvui.testing.click(.left);
                try dvui.testing.settle(FixedModalFrame.draw);
            }
            try std.testing.expect(FixedModalFrame.open);
            try std.testing.expectEqual(@as(usize, 4), FixedModalFrame.clicks);
        }
    }
}

const FixedAlertFrame = struct {
    var pending = true;

    fn draw() !dvui.App.Result {
        if (pending) {
            pending = false;
            components.alert(@src(), "无法启动游戏", "请选择可用的游戏实例，然后重新启动游戏。");
        }
        return .ok;
    }
};

test "UI layout fixed modals include queued launch alerts and preserve confirmation" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    for ([_]bool{ false, true }) |keyboard| {
        FixedAlertFrame.pending = true;
        var window = try dvui.testing.init(.{ .window_size = .{ .w = 1280, .h = 720 } });
        defer window.deinit();
        try dvui.testing.settle(FixedAlertFrame.draw);
        try std.testing.expectEqual(@as(usize, 1), window.window.dialogs.stack.items.len);
        const modal_id = window.window.subwindows.focused().?.id;
        for ([_]dvui.Size{ .{ .w = 1280, .h = 720 }, .{ .w = 640, .h = 400 }, .{ .w = 420, .h = 300 }, .{ .w = 1560, .h = 900 } }) |size| {
            window.backend.size = .cast(size);
            window.backend.size_pixels = .cast(size);
            _ = try dvui.testing.step(FixedAlertFrame.draw);
            try dvui.testing.settle(FixedAlertFrame.draw);
            const before = window.window.subwindows.get(modal_id).?.rect;
            FixedModalFrame.rect = before;
            try FixedModalFrame.expectCentered(size);
            for ([_]f32{ 30, before.h / 2 }) |offset| {
                const start: dvui.Point.Physical = .{ .x = before.x + 100, .y = before.y + offset };
                _ = try window.window.addEventMouseMotion(.{ .pt = start });
                try dvui.testing.settle(FixedAlertFrame.draw);
                _ = try window.window.addEventMouseButton(.left, .press);
                try dvui.testing.settle(FixedAlertFrame.draw);
                try std.testing.expect(!dvui.captured(modal_id));
                _ = try window.window.addEventMouseMotion(.{ .pt = .{ .x = start.x + 50, .y = start.y + 30 } });
                try dvui.testing.settle(FixedAlertFrame.draw);
                _ = try window.window.addEventMouseButton(.left, .release);
                try dvui.testing.settle(FixedAlertFrame.draw);
                try std.testing.expectEqual(before, window.window.subwindows.get(modal_id).?.rect);
            }
            try std.testing.expect(dvui.tagGet("alert-confirm").?.visible);
        }
        try dvui.testing.moveTo("alert-confirm");
        try dvui.testing.settle(FixedAlertFrame.draw);
        if (keyboard) {
            dvui.focusWidget(dvui.tagGet("alert-confirm").?.id, modal_id, null);
            try dvui.testing.pressKey(.enter, .none);
        } else {
            try dvui.testing.click(.left);
        }
        try dvui.testing.settle(FixedAlertFrame.draw);
        try std.testing.expectEqual(@as(usize, 0), window.window.dialogs.stack.items.len);
    }
}

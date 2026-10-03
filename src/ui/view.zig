const std = @import("std");
const dvui = @import("dvui");
const state = @import("model.zig");
const theme = @import("theme.zig");
const games = @import("game_library.zig");
const tools = @import("tools_view.zig");
const java = @import("java_manager.zig");
const java_view = @import("java_view.zig");
const launch = @import("game_launch.zig");
const config = @import("../core/config.zig");
const instances = @import("../core/instances.zig");
const task_registry = @import("../core/tasks.zig");
const tasks_view = @import("tasks_view.zig");
const settings_view = @import("settings_view.zig");
const cf_credentials_controller = @import("curseforge_credentials_controller.zig");
const java_download_controller = @import("java_download_controller.zig");
const java_download_view = @import("java_download_view.zig");
const server_manager = @import("server_manager.zig");
const servers_view = @import("servers_view.zig");
const logs_view = @import("logs_view.zig");
const worlds_manager = @import("worlds_manager.zig");
const worlds_view = @import("worlds_view.zig");
const accounts_manager = @import("accounts_manager.zig");
const accounts_view = @import("accounts_view.zig");
const instances_manager = @import("instances_manager.zig");
const instances_view = @import("instances_view.zig");
const content_manager = @import("content_manager.zig");
const content_view = @import("content_view.zig");
const pack_import_controller = @import("pack_import_controller.zig");
const pack_import_view = @import("pack_import_view.zig");

pub const Services = struct {
    configuration: *config.Store,
    tasks: *task_registry.Registry,
    settings: *settings_view.Ui,
    cf_credentials: ?*cf_credentials_controller.Controller = null,
    cf_credentials_failure: ?anyerror = null,
    java_download: *java_download_controller.Controller,
    java_download_ui: *java_download_view.Ui,
    servers: *server_manager.Manager,
    servers_ui: *servers_view.Ui,
    logs: *logs_view.View,
    worlds: *worlds_manager.Manager,
    worlds_ui: *worlds_view.Ui,
    accounts: ?*accounts_manager.Manager = null,
    accounts_ui: ?*accounts_view.Ui = null,
    task_viewport_height: ?f32 = null,
    instances: ?*instances_manager.Manager = null,
    instances_ui: ?*instances_view.Ui = null,
    content: ?*content_manager.Manager = null,
    content_ui: ?*content_view.Ui = null,
    pack_import: ?*pack_import_controller.Controller = null,
    pack_import_ui: ?*pack_import_view.Ui = null,
    allow_mutations: bool = true,
};
var launch_error: ?anyerror = null;
const R = dvui.Rect;

fn phasePinned(phase: ?pack_import_controller.Phase) bool {
    return switch (phase orelse return false) {
        .idle, .review_required, .failed, .canceled => false,
        else => true,
    };
}

pub fn packWorkflowPinned(controller: ?*const pack_import_controller.Controller) bool {
    return phasePinned(if (controller) |value| value.snapshot().phase else null);
}

const DispatchGates = struct { java: bool, instances: bool, content: bool, worlds: bool };

fn dispatchGates(phase: ?pack_import_controller.Phase, owns_instances: bool, owns_java: bool, allow_mutations: bool) DispatchGates {
    const pinned = phasePinned(phase) or !allow_mutations;
    return .{ .java = pinned or owns_java, .instances = pinned or owns_instances, .content = pinned, .worlds = pinned };
}

fn serviceGates(services: Services) DispatchGates {
    const controller = services.pack_import;
    return dispatchGates(if (controller) |value| value.snapshot().phase else null, if (controller) |value| value.ownsInstancesPublication() else false, if (controller) |value| value.ownsJavaDiscovery() or value.ownsJavaDownload() else false, services.allow_mutations);
}

const ManualIntents = struct {
    content: bool = false,
    instances: bool = false,
    java: bool = false,
    worlds: bool = false,
    credentials: bool = false,
    uncertain: bool = false,
    stopping: bool = false,
};

fn admissionBlocked(intents: ManualIntents) bool {
    return intents.content or intents.instances or intents.java or intents.worlds or intents.credentials or intents.uncertain or intents.stopping;
}

fn javaIntents(ui: *const java_view.Ui, download_ui: *const java_download_view.Ui) bool {
    return ui.commands.items.len != 0 or ui.search_queued or ui.modal_open or ui.download_requested or
        download_ui.pending != null or download_ui.modal_open or download_ui.cancel_requested;
}

fn discardJavaIntents(ui: *java_view.Ui, download_ui: *java_download_view.Ui) void {
    // Commands own paths and choices; suppression must release them, not defer them.
    for (ui.commands.items) |command| switch (command) {
        .search, .remove => |path| ui.allocator.free(path),
        .cancel => {},
        .add => |paths| {
            for (paths) |path| ui.allocator.free(path);
            ui.allocator.free(paths);
        },
        .choose => |selected_choice| {
            ui.allocator.free(selected_choice.game);
            ui.allocator.free(selected_choice.path);
        },
    };
    ui.commands.clearRetainingCapacity();
    ui.search_queued = false;
    ui.modal_open = false;
    ui.download_requested = false;
    download_ui.pending = null;
    download_ui.modal_open = false;
    download_ui.was_open = false;
    download_ui.cancel_requested = false;
}

fn packBlocked(services: Services, manager: *const java.Manager, java_ui: *const java_view.Ui) bool {
    var intents: ManualIntents = .{
        .java = manager.isSearching() or services.java_download.snapshot().phase == .running or javaIntents(java_ui, services.java_download_ui),
        .worlds = services.worlds.snapshot().worker_active or services.worlds_ui.draft != null or services.worlds_ui.select_queued or
            services.worlds_ui.pending_select != null or services.worlds_ui.requests.items.len != 0 or services.worlds_ui.directory_open != null or
            services.worlds_ui.refresh_queued or services.worlds_ui.cancel_queued,
        .credentials = services.settings.pending != null or services.settings.key_pending != null,
        .uncertain = services.configuration.publicationUncertain(),
        .stopping = !services.allow_mutations,
    };
    if (services.cf_credentials) |controller| intents.credentials = intents.credentials or controller.isBusy() or controller.lease();
    if (services.instances) |instance_manager| {
        const snapshot = instance_manager.snapshot();
        intents.instances = instance_manager.isBusy() or snapshot.phase == .awaiting_publication or snapshot.durability_uncertain or (snapshot.failure != null and snapshot.failure.? == error.RecoveryRequired);
    }
    if (services.instances_ui) |ui| intents.instances = intents.instances or ui.mode != .none or ui.pending != null;
    if (services.content) |content_manager_| {
        const snapshot = content_manager_.snapshot();
        intents.content = content_manager_.isBusy() or snapshot.recovery_required or snapshot.proposal != null;
    }
    if (services.content_ui) |ui| intents.content = intents.content or ui.picker != null or ui.picker_queued or ui.picker_manual != null or
        ui.draft != null or ui.review_requested or ui.review_refresh or ui.pending != null or ui.update_selection != null or ui.select_queued or
        ui.pending_select != null or ui.cancel_queued;
    return admissionBlocked(intents);
}

fn packServices(services: Services, manager: *java.Manager) ?pack_import_controller.Services {
    return .{ .store = services.configuration, .java = manager, .java_download = services.java_download, .instances = services.instances orelse return null, .content = services.content orelse return null };
}

fn consumePackRequest(services: Services, manager: *const java.Manager, java_ui: *const java_view.Ui) void {
    const instance_ui = services.instances_ui orelse return;
    if (!instance_ui.pack_requested) return;
    instance_ui.pack_requested = false;
    if (services.pack_import == null or services.pack_import_ui == null or services.instances == null or services.content == null) {
        instance_ui.failure = error.PackImportUnavailable;
        return;
    }
    if (packBlocked(services, manager, java_ui)) {
        instance_ui.failure = error.Busy;
        return;
    }
    pack_import_view.open(services.pack_import_ui.?);
}

pub fn draw(model: *state.Model, library: *games.Controller, manager: *java.Manager, java_ui: *java_view.Ui, launcher: *launch.Controller, services: Services) !void {
    const snapshot = library.snapshot();
    const gates = serviceGates(services);
    if (gates.java) discardJavaIntents(java_ui, services.java_download_ui);
    if (model.active_game.len != 0 and !tools.hasInstalled(snapshot, model.active_game.get())) model.active_game.len = 0;
    var pending: ?state.Msg = null;
    var command: ?tools.Command = null;
    {
        const root = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .background = true, .color_fill = .{ .color = theme.background }, .margin = R.all(0), .padding = R.all(0) });
        defer root.deinit();
        switch (model.panel) {
            .more => tools.moreMenu(model, &pending),
            .library => tools.libraryMenu(model, snapshot, &pending),
            .java => tools.javaMenu(model, &pending),
            .servers => tools.utilityMenu(model, &pending, "服务器"),
            .logs => tools.utilityMenu(model, &pending, "游戏日志"),
            .instances => {
                const side = tools.beginUtilityMenu("实例管理");
                defer side.deinit();
                tools.utilityMenuFooter(model, &pending);
                if (services.instances) |instance_manager| if (services.instances_ui) |ui| instances_view.drawSidebar(ui, services.configuration, instance_manager, !gates.instances);
            },
            .worlds => {
                const side = tools.beginUtilityMenu("存档");
                defer side.deinit();
                tools.utilityMenuFooter(model, &pending);
                worlds_view.drawSidebar(services.worlds_ui, services.configuration.snapshot(), services.worlds, !gates.worlds);
            },
            .content => tools.utilityMenu(model, &pending, "模组与整合包"),
            else => sidebar(model, &pending, services.configuration.snapshot()),
        }
        try content(model, snapshot, &pending, &command, manager, java_ui, launcher, services);
    }
    consumePackRequest(services, manager, java_ui);
    if (!gates.java) {
        java_view.drawSearchModal(java_ui, manager);
        if (java_ui.download_requested) {
            java_ui.download_requested = false;
            services.java_download_ui.modal_open = true;
        }
        java_download_view.draw(services.java_download_ui, services.java_download);
    } else discardJavaIntents(java_ui, services.java_download_ui);
    if (!gates.worlds) try worlds_view.drawModal(services.worlds_ui, services.configuration.snapshot(), services.worlds);
    if (!gates.content) {
        if (services.content) |manager_| if (services.content_ui) |ui| try content_view.drawModal(ui, services.configuration.snapshot(), manager_);
    }
    if (services.pack_import) |controller| if (services.pack_import_ui) |ui| try pack_import_view.drawModal(ui, services.configuration, controller, packBlocked(services, manager, java_ui));
    if (pending) |msg| {
        const selection_allowed = !gates.instances and (model.panel == .library or model.panel == .versions);
        const transition_allowed = switch (msg) {
            .use_game => selection_allowed,
            .start => !gates.instances and !gates.content,
            else => true,
        };
        if (transition_allowed) state.transition(model, msg);
        switch (msg) {
            .open_library, .get_game => if (!gates.content and model.getting_game and snapshot.available.len == 0 and snapshot.phase != .loading and snapshot.phase != .installing) {
                command = .load;
            },
            .start => if (!gates.instances and !gates.content) startGame(model, snapshot, manager, launcher, services),
            .use_game => |name| if (selection_allowed) {
                const current = services.configuration.snapshot();
                if (instances.findByName(current, name)) |instance| {
                    var document = current.*;
                    document.selected_instance = instance.id;
                    document.selected_server = null;
                    services.configuration.update(document) catch |err| {
                        launch_error = err;
                    };
                } else {
                    launch_error = error.InstanceNotConfigured;
                    model.panel = .instances;
                }
            },
            else => {},
        }
    }
    if (!gates.content) {
        if (command) |cmd| {
            model.library_error = null;
            switch (cmd) {
                .load => library.loadCatalogue() catch |err| {
                    model.library_error = err;
                },
                .install => |id| library.installVersion(id.get()) catch |err| {
                    model.library_error = err;
                },
                .cancel => library.cancel(),
            }
        }
    }
    if (!gates.java) java_view.finish(java_ui, manager) else discardJavaIntents(java_ui, services.java_download_ui);
    if (model.panel != .more or model.category != .settings) services.settings.clearKey();
    if (services.allow_mutations) {
        if (services.cf_credentials) |controller| {
            settings_view.finishWithCredentials(services.settings, services.configuration, controller, gates.content or if (services.content) |content_service| content_service.isBusy() else false);
        } else if (services.cf_credentials_failure != null) {
            settings_view.finishUnavailable(services.settings, services.configuration);
        } else if (!gates.content) settings_view.finish(services.settings, services.configuration) else {
            services.settings.pending = null;
            services.settings.clearKey();
        }
    }
    if (!gates.content) {
        if (services.content) |content_service| {
            const credential_lease = if (services.cf_credentials) |controller| controller.lease() else services.cf_credentials_failure != null;
            if (credential_lease and !content_service.isBusy() and !content_service.snapshot().recovery_required) try content_service.setCurseForgePolicy(.{});
        }
    }
    if (!gates.java) java_download_view.finish(services.java_download_ui, services.java_download);
    if (!gates.instances) servers_view.finish(services.servers_ui, services.configuration, services.servers);
    services.logs.finish(launcher);
    if (!gates.worlds) worlds_view.finish(services.worlds_ui, services.configuration, services.worlds);
    if (!gates.instances) {
        if (services.accounts) |accounts| if (services.accounts_ui) |ui| accounts_view.finish(ui, services.configuration, accounts);
    }
    if (!gates.instances) {
        if (services.instances) |manager_| {
            if (services.instances_ui) |ui| {
                if (manager_.setDefaultJava(defaultInstallerJava(manager.entries()))) |_| {
                    instances_view.finish(ui, services.configuration, manager_);
                } else |err| {
                    ui.failure = err;
                }
            }
        }
    }
    if (!gates.content) {
        if (services.content) |manager_| if (services.content_ui) |ui| content_view.finish(ui, services.configuration, manager_);
    }
    // Generic finishes may have admitted work; recheck before pack admission.
    if (services.pack_import) |controller| {
        if (services.pack_import_ui) |ui| {
            if (packServices(services, manager)) |bound| {
                pack_import_view.finish(ui, services.configuration, controller, bound, packBlocked(services, manager, java_ui));
            }
        }
    }
}

fn defaultInstallerJava(runtimes: []const java.Runtime) ?[]const u8 {
    var best: ?java.Runtime = null;
    for (runtimes) |runtime| {
        if (runtime.major < 8) continue;
        if (best == null or runtime.major > best.?.major) best = runtime;
    }
    return if (best) |runtime| runtime.path else null;
}

fn requiredJava(snapshot: games.Snapshot, id: []const u8) ?u32 {
    for (snapshot.installed) |entry| if (std.mem.eql(u8, entry.id, id)) return entry.java_major;
    return null;
}

fn startGame(model: *const state.Model, snapshot: games.Snapshot, manager: *java.Manager, launcher: *launch.Controller, services: Services) void {
    const document = services.configuration.snapshot();
    launch_error = null;
    if (snapshot.phase == .installing) {
        launch_error = error.InstallInProgress;
        return;
    }
    const required = requiredJava(snapshot, model.active_game.get()) orelse {
        launch_error = error.VersionNotInstalled;
        return;
    };
    const instance = instances.findByName(document, model.active_game.get()) orelse {
        launch_error = error.InstanceNotConfigured;
        return;
    };
    if (document.selected_instance == null or !std.mem.eql(u8, document.selected_instance.?, instance.id)) {
        launch_error = error.InstanceNotSelected;
        return;
    }
    const runtime = manager.resolve(model.active_game.get(), required);
    const java_path = instance.java_path orelse if (runtime) |value| value.path else {
        launch_error = error.NoCompatibleJava;
        return;
    };
    const accounts = services.accounts orelse {
        launch_error = error.NoAccountSelected;
        return;
    };
    const main_init = dvui.App.main_init orelse return;
    const now_ms: u64 = @intCast(@max(0, std.Io.Clock.awake.now(main_init.io).toMilliseconds()));
    var session = accounts.cloneLaunchSession(main_init.gpa, now_ms) catch |err| {
        launch_error = err;
        return;
    };
    defer session.deinit();
    const game_directory = std.fs.path.join(main_init.gpa, &.{ launcher.root, "versions", instance.name }) catch |err| {
        launch_error = err;
        return;
    };
    defer main_init.gpa.free(game_directory);
    var endpoint: ?launch.ServerEndpoint = null;
    if (document.selected_server) |server_id| {
        for (document.servers) |server| if (std.mem.eql(u8, server.id, server_id)) {
            if (!std.mem.eql(u8, server.instance_id, instance.id)) {
                launch_error = error.ServerInstanceMismatch;
                return;
            }
            endpoint = .{ .address = server.address, .port = server.port };
            break;
        };
    }
    launcher.startWithOptions(.{
        .version = model.active_game.get(),
        .java_path = java_path,
        .java_major = required,
        .username = session.username,
        .max_memory_mb = instance.max_memory_mb orelse document.settings.default_memory_mb,
    }, .{
        .debug = instance.debug_launch,
        .instance_directory = game_directory,
        .instance_id = instance.id,
        .launcher_root = std.fs.path.dirname(launcher.root),
        .identity = .{ .name = session.username, .uuid = session.uuid, .access_token = if (session.token) |token| token.bytes else "0", .user_type = if (session.kind == .microsoft) "msa" else "legacy" },
        .server = endpoint,
    }) catch |err| {
        launch_error = err;
    };
}

fn title(src: std.builtin.SourceLocation, text: []const u8) void {
    dvui.labelNoFmt(src, text, .{}, .{ .font = dvui.themeGet().font_title, .margin = R.all(0), .padding = R.all(0) });
}

fn muted(src: std.builtin.SourceLocation, text: []const u8) void {
    dvui.labelNoFmt(src, text, .{}, .{ .color_text = .{ .color = theme.muted }, .font = dvui.themeGet().font_body.withSize(14), .margin = R.all(0), .padding = R.all(0) });
}

fn gap(src: std.builtin.SourceLocation, height: f32) void {
    _ = dvui.spacer(src, .{ .min_size_content = .{ .h = height } });
}

fn action(src: std.builtin.SourceLocation, text: []const u8, opts: dvui.Options) bool {
    return dvui.button(src, text, .{}, (dvui.Options{ .margin = R.all(0), .padding = R.all(10), .min_size_content = .{ .h = 20 }, .border = R.all(1) }).override(opts));
}

fn sidebar(model: *const state.Model, pending: *?state.Msg, document: *const config.Document) void {
    const account = selectedAccount(document);
    const name = if (account) |value| value.name else model.labels.choosePlayer;
    const kind = if (account) |value| (if (value.kind == .microsoft) "Microsoft" else "离线玩家") else "未选择账号";
    const side = dvui.box(@src(), .{}, .{ .expand = .vertical, .min_size_content = .{ .w = 212 }, .max_size_content = .width(212), .padding = R.all(24), .margin = .{ .x = 16, .y = 16, .h = 16 }, .corners = .all(8), .background = true, .color_fill = .{ .color = theme.surface } });
    defer side.deinit();
    title(@src(), "Vela Launcher");
    gap(@src(), 24);
    {
        const name_font = dvui.themeGet().font_body;
        const kind_font = name_font.withSize(14);
        const text_height = name_font.textSize(name).h + 4 + kind_font.textSize(kind).h;
        const row_height = @max(48, text_height);
        var player: dvui.ButtonWidget = undefined;
        player.init(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .h = row_height }, .padding = R.all(0), .margin = R.all(0), .border = R.all(0), .color_fill = .{ .color = theme.surface }, .label = .{ .text = model.labels.choosePlayer } });
        defer player.deinit();
        player.processEvents();
        player.drawBackground();
        {
            const identity = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .min_size_content = .{ .h = row_height }, .padding = R.all(0), .margin = R.all(0) });
            defer identity.deinit();
            {
                const avatar = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 48, .h = 48 }, .max_size_content = .{ .w = 48, .h = 48 }, .gravity_y = 0.5, .padding = R.all(0), .margin = R.all(0), .border = R.all(0), .background = true, .color_fill = .{ .color = theme.accent } });
                defer avatar.deinit();
                dvui.labelNoFmt(@src(), accountInitial(account), .{ .align_x = 0.5, .align_y = 0.5 }, .{ .gravity_x = 0.5, .gravity_y = 0.5, .font = dvui.themeGet().font_body.withSize(20), .color_text = .{ .color = .fromHex("182318") }, .padding = R.all(0), .margin = R.all(0) });
            }
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12 } });
            const details = dvui.box(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .h = text_height }, .gravity_y = 0.5, .padding = R.all(0), .margin = R.all(0) });
            defer details.deinit();
            dvui.labelNoFmt(@src(), name, .{}, .{ .padding = R.all(0), .margin = R.all(0) });
            gap(@src(), 4);
            muted(@src(), kind);
        }
        player.drawFocus();
        if (player.clicked()) pending.* = .open_players;
    }
    gap(@src(), 24);
    _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = R.all(0) });
    gap(@src(), 24);
    muted(@src(), model.labels.gameVersion);
    gap(@src(), 12);
    if (action(@src(), model.versionName(), .{ .expand = .horizontal, .style = .control, .color_border = if (model.panel == .instances) .{ .color = theme.accent } else null, .label = .{ .text = model.labels.chooseVersion } })) pending.* = .open_instances;
    _ = dvui.spacer(@src(), .{ .expand = .vertical });
    if (action(@src(), model.labels.more, .{ .expand = .horizontal, .corners = .all(8), .border = R.all(0) })) pending.* = .open_more;
}

fn selectedAccount(document: *const config.Document) ?config.Account {
    const id = document.selected_account orelse return null;
    for (document.accounts) |account| if (std.mem.eql(u8, account.id, id)) return account;
    return null;
}

fn accountInitial(account: ?config.Account) []const u8 {
    const name = if (account) |value| value.name else return "?";
    if (name.len == 0) return "?";
    const length = std.unicode.utf8ByteSequenceLength(name[0]) catch return "?";
    return name[0..@min(length, name.len)];
}

fn content(model: *state.Model, snapshot: games.Snapshot, pending: *?state.Msg, command: *?tools.Command, manager: *java.Manager, java_ui: *java_view.Ui, launcher: *launch.Controller, services: Services) !void {
    const gates = serviceGates(services);
    const parent_id = dvui.parentGet().data().id;
    var key: u64 = @intFromEnum(model.panel);
    key = key * 16 + @intFromEnum(model.category);
    key = key * 2 + @intFromBool(model.getting_game);
    if (model.panel == .library and !model.getting_game) key = std.hash.Wyhash.hash(key, model.library_game.get());
    const previous = dvui.dataGet(null, parent_id, "content_panel", u64);
    if (previous == null or previous.? != key) {
        dvui.animation(parent_id, "content_enter", .{ .end_time = 180_000, .easing = dvui.easing.outCubic });
    }
    dvui.dataSet(null, parent_id, "content_panel", key);
    const progress = if (dvui.animationGet(parent_id, "content_enter")) |a| a.value() else 1;
    const offset = 8 * (1 - progress);
    const compact_home = model.panel == .home and (services.task_viewport_height orelse dvui.windowRect().h) < 520;
    const padding: f32 = if (compact_home) 12 else 32;
    const pane = dvui.box(@src(), .{}, .{ .id_extra = @intFromEnum(model.panel), .expand = .both, .padding = .{ .x = padding + offset, .w = padding - offset, .y = padding, .h = padding } });
    defer pane.deinit();
    const previous_clip = dvui.clip(pane.data().contentRectScale().r);
    defer dvui.clipSet(previous_clip);
    const previous_alpha = dvui.alpha(progress);
    defer dvui.alphaSet(previous_alpha);
    switch (model.panel) {
        .home => try drawHome(model, snapshot, manager, launcher.snapshot(), pending, services),
        .players => if (services.accounts) |accounts| {
            if (action(@src(), model.labels.back, .{ .margin = .{ .h = 12 } })) pending.* = .back;
            if (services.accounts_ui) |ui| accounts_view.draw(ui, services.configuration, accounts);
        } else players(model, pending),
        .versions => versions(model, snapshot, pending),
        .more => switch (model.category) {
            .settings => if (services.cf_credentials) |controller|
                try settings_view.drawWithCredentials(services.settings, controller, services.configuration.snapshot().settings, gates.content or if (services.content) |content_service| content_service.isBusy() else false, services.configuration.publicationUncertain())
            else if (services.cf_credentials_failure) |failure|
                try settings_view.drawUnavailable(services.settings, services.configuration.snapshot().settings, failure)
            else
                try settings_view.draw(services.settings),
            .game => tools.moreContent(model, pending),
        },
        .library => if (!gates.java and !gates.content) tools.libraryContent(model, snapshot, pending, command, java_ui, manager),
        .java => if (!gates.java) java_view.drawPage(java_ui, manager),
        .servers => servers_view.draw(services.servers_ui, services.configuration, services.servers),
        .worlds => try worlds_view.drawWithEnabled(services.worlds_ui, services.configuration.snapshot(), services.worlds, !gates.worlds),
        .logs => try services.logs.draw(launcher),
        .instances => if (services.instances) |manager_| {
            if (services.instances_ui) |ui| instances_view.drawWithEnabled(ui, services.configuration, manager_, snapshot, !gates.instances);
        },
        .content => if (!gates.content) {
            if (services.content) |manager_| {
                if (services.content_ui) |ui| try content_view.draw(ui, services.configuration.snapshot(), manager_);
            }
        },
    }
}

pub fn drawHome(model: *const state.Model, snapshot: games.Snapshot, manager: *java.Manager, process: launch.Snapshot, pending: *?state.Msg, services: Services) !void {
    const compact = (services.task_viewport_height orelse dvui.windowRect().h) < 520;
    const body = dvui.themeGet().font_body;
    const font = if (compact) body.withSize(14) else body;
    const required = requiredJava(snapshot, model.active_game.get());
    const runtime = if (required) |major| manager.resolve(model.active_game.get(), major) else null;
    const configured_instance = instances.findByName(services.configuration.snapshot(), model.active_game.get());
    const override_path = if (configured_instance) |instance| instance.java_path else null;
    const failure: ?anyerror = if (launch_error != null) launch_error else process.failure;
    const running = process.phase == .preparing or process.phase == .running;
    const now_ms: u64 = if (dvui.App.main_init) |main_init| @intCast(@max(0, std.Io.Clock.awake.now(main_init.io).toMilliseconds())) else 0;
    const account_ready = if (services.accounts) |accounts| accounts.canLaunch(now_ms) else false;
    const configured = configured_instance != null;
    const gates = serviceGates(services);
    const disabled = gates.instances or gates.content or !account_ready or !configured or required == null or (runtime == null and override_path == null) or running or snapshot.phase == .installing;
    const selection_required = !account_ready or !configured or required == null;
    const status = if (failure) |err| try std.fmt.allocPrint(dvui.currentWindow().arena(), "启动失败：{s}", .{@errorName(err)}) else switch (process.phase) {
        .preparing => "正在准备启动",
        .running => "游戏正在运行",
        .exited => try std.fmt.allocPrint(dvui.currentWindow().arena(), "游戏已退出（{d}）", .{process.exit_code orelse 0}),
        else => null,
    };
    const options: tasks_view.Options = .{ .max_visible_rows = if (compact) 1 else 2, .compact = compact };
    const task_height = tasks_view.sectionHeight(services.tasks, options);
    const notice_font = body.withSize(14);
    const footer_height = 48 + (if (status != null) notice_font.textHeight() else 0) + (if (selection_required) notice_font.textHeight() else 0) + (if (snapshot.phase == .installing) notice_font.textHeight() else 0);
    const frame = dvui.box(@src(), .{}, .{ .tag = "home-layout", .expand = .both, .padding = R.all(0), .margin = R.all(0) });
    defer frame.deinit();
    const bounds = frame.data().contentRect();
    // Header overflow is isolated; task rows and the launch footer retain their own space.
    const header_budget = @max(0, bounds.h - task_height - footer_height);
    {
        const header = dvui.scrollArea(@src(), .{}, .{ .tag = "home-header", .expand = .horizontal, .max_size_content = .height(header_budget), .background = false, .padding = R.all(0), .margin = R.all(0), .border = R.all(0) });
        defer header.deinit();
        dvui.labelNoFmt(@src(), model.labels.ready, .{}, .{ .font = if (compact) body.withSize(18) else dvui.themeGet().font_title, .padding = R.all(0), .margin = R.all(0) });
        gap(@src(), if (compact) 4 else 12);
        dvui.label(@src(), "{s}{s}", .{ model.labels.currentVersion, model.versionName() }, .{ .font = font, .padding = R.all(0), .margin = R.all(0), .expand = .horizontal, .max_size_content = .width(0) });
        gap(@src(), if (compact) 4 else 12);
        if (override_path != null and required != null) {
            dvui.label(@src(), "Java {d}", .{required.?}, .{ .font = font, .padding = R.all(0), .margin = R.all(0), .expand = .horizontal });
        } else if (runtime) |selected| {
            dvui.label(@src(), "Java {d} · {s}", .{ selected.major, selected.vendor }, .{ .font = font, .padding = R.all(0), .margin = R.all(0), .expand = .horizontal, .max_size_content = .width(0) });
        } else if (required) |major| {
            dvui.label(@src(), "此版本需要 Java {d}", .{major}, .{ .font = font, .padding = R.all(0), .margin = .{ .h = if (compact) 4 else 12 }, .expand = .horizontal });
            if (dvui.button(@src(), "Java 管理", .{}, .{ .font = font, .padding = R.all(if (compact) 8 else 10), .margin = R.all(0), .corners = .all(8) })) pending.* = .open_java;
        }
        servers_view.drawHomeWithOptions(services.servers_ui, services.configuration.snapshot(), compact);
    }
    try tasks_view.drawWithOptions(services.tasks, options);
    {
        const footer = dvui.box(@src(), .{}, .{ .tag = "home-footer", .rect = .{ .x = 0, .y = @max(0, bounds.h - footer_height), .w = bounds.w, .h = footer_height }, .padding = R.all(0), .margin = R.all(0) });
        defer footer.deinit();
        if (status) |text| dvui.labelNoFmt(@src(), text, .{}, .{ .font = notice_font, .color_text = .{ .color = if (failure != null) theme.accent else theme.muted }, .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = R.all(0) });
        if (selection_required) muted(@src(), model.labels.selectionRequired);
        if (snapshot.phase == .installing) muted(@src(), "正在安装游戏");
        var start: dvui.ButtonWidget = undefined;
        start.init(@src(), .{ .grayed = disabled }, .{ .tag = "home-start", .font = font, .rect = .{ .x = @max(0, bounds.w - 176), .y = footer_height - 48, .w = 176, .h = 48 }, .style = .highlight, .color_fill = if (disabled) .{ .color = theme.surface } else null, .min_size_content = .{ .w = 152, .h = 24 }, .padding = R.all(12), .margin = R.all(0), .corners = .all(8), .tab_index = if (disabled) 0 else null });
        defer start.deinit();
        if (disabled) {
            if (start.data().accesskit_node()) |node| {
                dvui.AccessKit.nodeSetDisabled(node);
                dvui.AccessKit.nodeRemoveAction(node, .focus);
                dvui.AccessKit.nodeRemoveAction(node, .click);
            }
        }
        if (!disabled) start.processEvents();
        start.drawBackground();
        // Keep the disabled label legible instead of using ButtonWidget's averaged text color.
        dvui.labelNoFmt(@src(), if (running) "启动中" else model.labels.start, .{ .align_x = 0.5, .align_y = 0.5 }, start.style().override(.{ .color_text = if (disabled) .{ .color = theme.muted } else null, .gravity_x = 0.5, .gravity_y = 0.5, .padding = R.all(0), .margin = R.all(0) }));
        if (!disabled) start.drawFocus();
        if (!disabled and start.clicked()) pending.* = .start;
    }
}

fn pickerHeader(src: std.builtin.SourceLocation, name: []const u8, back: []const u8, pending: *?state.Msg) void {
    const header_height = @max(40, dvui.themeGet().font_title.textSize(name).h);
    const row = dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal, .min_size_content = .{ .h = header_height } });
    defer row.deinit();
    if (action(@src(), back, .{ .gravity_x = 1, .gravity_y = 0.5 })) pending.* = .back;
    title(@src(), name);
}

fn choice(src: std.builtin.SourceLocation, id: u32, name: []const u8, detail: []const u8, current: bool, current_label: []const u8) bool {
    var item: dvui.ButtonWidget = undefined;
    const item_height = dvui.themeGet().font_body.textSize(name).h + dvui.themeGet().font_body.withSize(14).textSize(detail).h + 4;
    item.init(src, .{}, .{ .id_extra = id, .expand = .horizontal, .min_size_content = .{ .h = item_height }, .padding = R.all(16), .margin = .{ .h = 12 }, .border = R.all(1), .style = .control, .color_border = if (current) .{ .color = theme.accent } else null, .label = .{ .text = name } });
    defer item.deinit();
    item.processEvents();
    item.drawBackground();
    {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .min_size_content = .{ .h = item_height } });
        defer row.deinit();
        if (current) dvui.labelNoFmt(@src(), current_label, .{}, .{ .gravity_x = 1, .gravity_y = 0.5, .color_text = .{ .color = theme.accent }, .padding = R.all(0), .margin = .{ .x = 12 }, .background = false });
        {
            const text = dvui.box(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .h = item_height } });
            defer text.deinit();
            dvui.labelNoFmt(@src(), name, .{}, item.style().override(.{ .padding = R.all(0), .margin = R.all(0), .background = false }));
            gap(@src(), 4);
            dvui.labelNoFmt(@src(), detail, .{}, item.style().override(.{ .font = dvui.themeGet().font_body.withSize(14), .padding = R.all(0), .margin = R.all(0), .background = false }));
        }
    }
    item.drawFocus();
    return item.clicked();
}

fn players(model: *const state.Model, pending: *?state.Msg) void {
    pickerHeader(@src(), model.labels.choosePlayer, model.labels.back, pending);
    gap(@src(), 24);
    const scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false, .padding = R.all(0), .border = R.all(0), .label = .{ .text = model.labels.playerList } });
    defer scroll.deinit();
    if (!model.hasPlayers()) muted(@src(), model.labels.noPlayers);
    for (model.players) |p| {
        if (choice(@src(), p.id, p.name, p.kind, p.id == model.selected_player, model.labels.current)) pending.* = .{ .select_player = p.id };
    }
}

fn versions(model: *const state.Model, snapshot: games.Snapshot, pending: *?state.Msg) void {
    pickerHeader(@src(), model.labels.chooseVersion, model.labels.back, pending);
    gap(@src(), 24);
    if (action(@src(), "获取游戏", .{ .expand = .horizontal, .corners = .all(8), .margin = .{ .h = 16 } })) pending.* = .open_library;
    const scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false, .padding = R.all(0), .border = R.all(0), .label = .{ .text = model.labels.versionList } });
    defer scroll.deinit();
    if (snapshot.installed.len == 0) muted(@src(), model.labels.noVersions);
    for (snapshot.installed, 0..) |v, i| {
        if (choice(@src(), @intCast(i), v.id, "原版 · 已安装", std.mem.eql(u8, model.active_game.get(), v.id), model.labels.current)) pending.* = .{ .use_game = v.id };
    }
}

const DispatchProbe = struct {
    publications: usize = 0,
    policies: usize = 0,
    selections: usize = 0,
    java_commands: usize = 0,
    pack_finishes: usize = 0,
    pack_blocked: bool = false,

    fn finish(self: *DispatchProbe, gates: DispatchGates, blocked: bool) void {
        if (!gates.instances) self.publications += 1;
        if (!gates.content) self.policies += 1;
        if (!gates.worlds) self.selections += 1;
        if (!gates.java) self.java_commands += 1;
        self.pack_finishes += 1;
        self.pack_blocked = blocked;
    }
};

test "whole pack phase pins generic publication policy selection and Java dispatch" {
    try std.testing.expect(!packWorkflowPinned(null));
    for ([_]pack_import_controller.Phase{ .preparing, .discovering_java, .probing_java, .downloading_java, .creating, .awaiting_publication, .awaiting_reconciliation, .selecting_content, .awaiting_adoption, .reviewing_content, .cleaning }) |phase| {
        const gates = dispatchGates(phase, false, false, true);
        var probe: DispatchProbe = .{};
        probe.finish(gates, false);
        try std.testing.expect(gates.java and gates.instances and gates.content and gates.worlds);
        try std.testing.expectEqual(@as(usize, 0), probe.publications + probe.policies + probe.selections + probe.java_commands);
        try std.testing.expectEqual(@as(usize, 1), probe.pack_finishes);
    }
}

test "review releases whole pin while residual dependency ownership remains gated" {
    for ([_]pack_import_controller.Phase{ .idle, .review_required, .failed, .canceled }) |phase| {
        try std.testing.expect(!phasePinned(phase));
        const released = dispatchGates(phase, false, false, true);
        try std.testing.expect(!released.java and !released.instances and !released.content and !released.worlds);
        const retained = dispatchGates(phase, true, true, true);
        try std.testing.expect(retained.java and retained.instances);
        try std.testing.expect(!retained.content and !retained.worlds);
    }
    try std.testing.expect(admissionBlocked(.{ .content = true }));
}

test "queued foreign Java commands and cancellation are discarded without replay" {
    const a = std.testing.allocator;
    var ui = java_view.Ui.init(a);
    defer ui.deinit();
    var download_ui = java_download_view.Ui.init(a);
    defer download_ui.deinit();
    try ui.commands.append(a, .{ .search = try a.dupe(u8, "/java/search") });
    try ui.commands.append(a, .{ .remove = try a.dupe(u8, "/java/remove") });
    const paths = try a.alloc([]const u8, 2);
    paths[0] = try a.dupe(u8, "/java/first");
    paths[1] = try a.dupe(u8, "/java/second");
    try ui.commands.append(a, .{ .add = paths });
    try ui.commands.append(a, .{ .choose = .{ .game = try a.dupe(u8, "1.21"), .path = try a.dupe(u8, "/java/choice"), .required = 21 } });
    try ui.commands.append(a, .cancel);
    ui.search_queued = true;
    ui.modal_open = true;
    ui.download_requested = true;
    download_ui.pending = .cancel;
    download_ui.modal_open = true;
    download_ui.was_open = true;
    download_ui.cancel_requested = true;
    try std.testing.expect(javaIntents(&ui, &download_ui));
    try std.testing.expect(admissionBlocked(.{ .java = javaIntents(&ui, &download_ui) }));
    discardJavaIntents(&ui, &download_ui);
    discardJavaIntents(&ui, &download_ui);
    try std.testing.expect(!javaIntents(&ui, &download_ui));
    try std.testing.expect(!download_ui.was_open);
    const released = dispatchGates(.review_required, false, false, true);
    try std.testing.expect(!released.java and ui.commands.items.len == 0 and download_ui.pending == null);
}

test "each manual admission barrier blocks new pack work but shutdown still dispatches owned finish" {
    try std.testing.expect(!admissionBlocked(.{}));
    inline for (std.meta.fields(ManualIntents)) |field| {
        var intents: ManualIntents = .{};
        @field(intents, field.name) = true;
        try std.testing.expect(admissionBlocked(intents));
    }
    const gates = dispatchGates(.awaiting_adoption, true, true, false);
    const blocked = admissionBlocked(.{ .stopping = true, .uncertain = true });
    var probe: DispatchProbe = .{};
    probe.finish(gates, blocked);
    try std.testing.expectEqual(@as(usize, 0), probe.publications + probe.policies + probe.selections + probe.java_commands);
    try std.testing.expectEqual(@as(usize, 1), probe.pack_finishes);
    try std.testing.expect(probe.pack_blocked);
}

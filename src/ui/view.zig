const std = @import("std");
const dvui = @import("dvui");
const state = @import("model.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const games = @import("game_library.zig");
const game_selection_view = @import("game_selection_view.zig");
const tools = @import("tools_view.zig");
const java = @import("java_manager.zig");
const java_view = @import("java_view.zig");
const launch = @import("game_launch.zig");
const config = @import("../core/config.zig");
const instances = @import("../core/instances.zig");
const task_registry = @import("../core/tasks.zig");
const settings_view = @import("settings_view.zig");
const appearance_view = @import("appearance_view.zig");
const cf_credentials_controller = @import("curseforge_credentials_controller.zig");
const java_download_controller = @import("java_download_controller.zig");
const java_download_view = @import("java_download_view.zig");
const avatar_manager = @import("avatar_manager.zig");
const avatar_image = @import("avatar_image.zig");
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
const instance_creation_controller = @import("instance_creation_controller.zig");
const mods_controller = @import("mods_controller.zig");
const mods_view = @import("mods_view.zig");
const mods_page = @import("mods_page.zig");

pub fn boundedSidebarWidth(requested: f32, available: f32) f32 {
    const upper = @max(1, @min(500, available - 280));
    const lower = @min(260, upper);
    return std.math.clamp(if (std.math.isFinite(requested)) requested else 276, lower, upper);
}

/// Keep the five standard log actions inside the main pane's content padding.
pub fn boundedLogsSidebarWidth(requested: f32, available: f32) f32 {
    const minimum_main = 2 * theme.spacing.page_padding + 5 * theme.sizing.icon_button;
    const upper = @max(1, @min(500, available - minimum_main));
    const lower = @min(260, upper);
    return std.math.clamp(if (std.math.isFinite(requested)) requested else 276, lower, upper);
}

pub fn boundedInstanceSidebarWidth(requested: f32, available: f32) f32 {
    const upper = @max(1, @min(400, available - 280));
    const lower = @min(260, upper);
    return std.math.clamp(if (std.math.isFinite(requested)) requested else 280, lower, upper);
}

fn guardInstanceLeave(model: *state.Model, ui: *instances_view.Ui, pending: *?state.Msg) void {
    var consumed_leave = false;
    if (model.instance_leave) |destination| {
        if (ui.exit_requested) {
            ui.exit_requested = false;
            model.instance_leave = null;
            pending.* = destination;
            consumed_leave = true;
        } else if (ui.navigation == null and ui.pending == null and !ui.submitted) {
            model.instance_leave = null;
        }
    }
    if (pending.*) |destination| {
        const leaving = model.panel == .instances and switch (destination) {
            .back, .utility_back, .instances_back, .open_mods => true,
            else => false,
        };
        if (leaving and !consumed_leave) {
            if (model.instance_leave == null) {
                ui.queue(.leave, null);
                model.instance_leave = destination;
            }
            pending.* = null;
        }
    }
}

test "instance exits remain deferred during save and failed publication and consume only once" {
    var model: state.Model = .{ .panel = .instances, .instance_parent = .home };
    var ui = instances_view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var pending: ?state.Msg = .back;
    guardInstanceLeave(&model, &ui, &pending);
    try std.testing.expect(pending == null);
    try std.testing.expectEqual(state.Msg.back, model.instance_leave.?);
    try std.testing.expectEqual(instances_view.Action.leave, ui.pending.?.action);

    // The instance finish seam moves the owned leave intent into its dirty prompt.
    ui.pending = null;
    ui.navigation = .{ .action = .leave, .text = null };
    ui.navigation_prompt = true;
    pending = .utility_back;
    guardInstanceLeave(&model, &ui, &pending);
    try std.testing.expect(pending == null and ui.pending == null);
    try std.testing.expectEqual(state.Msg.back, model.instance_leave.?);

    // Save-and-continue hides the prompt while the rename/JOIN/publication runs.
    ui.navigation_prompt = false;
    ui.saving_navigation = true;
    ui.submitted = true;
    pending = .utility_back;
    guardInstanceLeave(&model, &ui, &pending);
    try std.testing.expect(pending == null and ui.pending == null);
    try std.testing.expectEqual(state.Msg.back, model.instance_leave.?);
    ui.failure = error.PublicationUncertain;
    pending = .back;
    guardInstanceLeave(&model, &ui, &pending);
    try std.testing.expect(pending == null and ui.pending == null);
    try std.testing.expectEqual(state.Msg.back, model.instance_leave.?);

    // Only accepted navigation emits the original destination; it cannot requeue.
    ui.navigation = null;
    ui.saving_navigation = false;
    ui.submitted = false;
    ui.exit_requested = true;
    guardInstanceLeave(&model, &ui, &pending);
    try std.testing.expectEqual(state.Msg.back, pending.?);
    try std.testing.expect(model.instance_leave == null and !ui.exit_requested and ui.pending == null);
    pending = null;
    guardInstanceLeave(&model, &ui, &pending);
    try std.testing.expect(pending == null);

    // Cancel clears the parent route; a subsequent exit starts a fresh intent.
    model.instance_leave = .back;
    guardInstanceLeave(&model, &ui, &pending);
    try std.testing.expect(model.instance_leave == null);
    pending = .utility_back;
    guardInstanceLeave(&model, &ui, &pending);
    try std.testing.expect(pending == null);
    try std.testing.expectEqual(state.Msg.utility_back, model.instance_leave.?);
    try std.testing.expectEqual(instances_view.Action.leave, ui.pending.?.action);
    ui.pending = null;
    ui.exit_requested = true;
    guardInstanceLeave(&model, &ui, &pending);
    state.transition(&model, pending.?);
    try std.testing.expectEqual(state.Panel.home, model.panel);
}

test "instances back defers dirty instance exit until navigation acknowledges the destination" {
    var model: state.Model = .{ .panel = .home };
    state.transition(&model, .open_instances);
    try std.testing.expectEqual(state.Panel.instances, model.panel);
    try std.testing.expectEqual(state.Panel.home, model.parentPanel());
    var ui = instances_view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var pending: ?state.Msg = model.parentMessage();
    guardInstanceLeave(&model, &ui, &pending);
    try std.testing.expect(pending == null);
    try std.testing.expectEqual(state.Msg.instances_back, model.instance_leave.?);
    try std.testing.expectEqual(instances_view.Action.leave, ui.pending.?.action);
    ui.pending = null;
    ui.navigation = .{ .action = .leave, .text = null };
    ui.navigation_prompt = true;
    guardInstanceLeave(&model, &ui, &pending);
    try std.testing.expectEqual(state.Panel.instances, model.panel);
    try std.testing.expect(model.instance_leave != null and pending == null);
    ui.navigation = null;
    ui.navigation_prompt = false;
    ui.exit_requested = true;
    guardInstanceLeave(&model, &ui, &pending);
    try std.testing.expectEqual(state.Msg.instances_back, pending.?);
    try std.testing.expect(model.instance_leave == null and !ui.exit_requested);
    state.transition(&model, pending.?);
    try std.testing.expectEqual(state.Panel.home, model.panel);
}

pub const Services = struct {
    configuration: *config.Store,
    tasks: *task_registry.Registry,
    settings: *settings_view.Ui,
    appearance: *appearance_view.Ui,
    cf_credentials: ?*cf_credentials_controller.Controller = null,
    cf_credentials_failure: ?anyerror = null,
    java_download: *java_download_controller.Controller,
    java_download_ui: *java_download_view.Ui,
    servers: *server_manager.Manager,
    servers_ui: *servers_view.Ui,
    logs: *logs_view.View,
    worlds: *worlds_manager.Manager,
    worlds_ui: *worlds_view.Ui,
    avatars: ?*avatar_manager.Manager = null,
    accounts: ?*accounts_manager.Manager = null,
    accounts_ui: ?*accounts_view.Ui = null,
    task_viewport_height: ?f32 = null,
    instances: ?*instances_manager.Manager = null,
    instances_ui: ?*instances_view.Ui = null,
    content: ?*content_manager.Manager = null,
    mods: ?*mods_controller.Controller = null,
    mods_ui: ?*mods_view.Ui = null,
    ordinary_creation: ?*instance_creation_controller.Controller = null,
    allow_mutations: bool = true,
};
var launch_error: ?anyerror = null;
const R = dvui.Rect;

fn phasePinned(phase: ?instance_creation_controller.Phase) bool {
    return switch (phase orelse return false) {
        .idle, .complete, .failed, .canceled => false,
        else => true,
    };
}

pub fn ordinaryCreationPinned(controller: ?*const instance_creation_controller.Controller) bool {
    return phasePinned(if (controller) |value| value.snapshot().phase else null);
}

const DispatchGates = struct { java: bool, instances: bool, content: bool, worlds: bool };

fn dispatchGates(phase: ?instance_creation_controller.Phase, owns_instances: bool, owns_java: bool, allow_mutations: bool) DispatchGates {
    const pinned = phasePinned(phase) or !allow_mutations;
    return .{ .java = pinned or owns_java, .instances = pinned or owns_instances, .content = pinned, .worlds = pinned };
}

fn serviceGates(services: Services) DispatchGates {
    const controller = services.ordinary_creation;
    return dispatchGates(if (controller) |value| value.snapshot().phase else null, if (controller) |value| value.ownsInstancesPublication() else false, if (controller) |value| value.ownsJavaDiscovery() or value.ownsJavaDownload() else false, services.allow_mutations);
}

fn gatedTaskActionAllowed(action: ?instances_view.Action, allow_mutations: bool) bool {
    if (!allow_mutations) return false;
    return switch (action orelse return false) {
        .cancel, .close_task => true,
        else => false,
    };
}

fn launchPinsJava(phase: launch.Phase) bool {
    return phase == .preparing or phase == .running;
}

fn javaIntents(ui: *const java_view.Ui, download_ui: *const java_download_view.Ui) bool {
    return ui.commands.items.len != 0 or ui.search_queued or ui.delete_confirmation != null or ui.download_requested or
        download_ui.pending != null;
}

fn discardJavaIntents(ui: *java_view.Ui, download_ui: *java_download_view.Ui) void {
    java_view.discardPicker(ui);
    java_view.discardCommands(ui);
    ui.download_requested = false;
    download_ui.pending = null;
    download_ui.start_admitted = false;
    download_ui.cancel_requested = false;
}

fn creationServices(services: Services, manager: *java.Manager) ?instance_creation_controller.Services {
    return .{ .store = services.configuration, .java = manager, .java_download = services.java_download, .instances = services.instances orelse return null };
}

fn discardInactivePickers(model: *const state.Model, java_ui: *java_view.Ui, services: Services) void {
    if (model.panel != .java or !services.allow_mutations) java_view.discardPicker(java_ui);
}

pub fn draw(model: *state.Model, library: *games.Controller, manager: *java.Manager, java_ui: *java_view.Ui, launcher: *launch.Controller, services: Services) !void {
    services.appearance.allow_mutations = services.allow_mutations;
    appearance_view.beginFrame(services.appearance, services.configuration);
    theme.applyAppearance(appearance_view.visibleSettings(services.appearance, services.configuration));
    theme.applyTypography();
    const canvas_bounds = dvui.parentGet().data().contentRect();
    appearance_view.drawBackground(services.appearance, services.configuration, canvas_bounds);
    if (services.mods) |controller| if (services.content) |backend| controller.tick(backend);
    discardInactivePickers(model, java_ui, services);
    if (services.allow_mutations) services.worlds_ui.setPageActive(model.panel == .worlds);
    const snapshot = library.snapshot();
    if (services.instances_ui) |ui| {
        ui.java_preview = library.previewSnapshot();
        if (ui.java_preview.phase == .loading) dvui.timer(dvui.parentGet().data().id.update("instance-java-preview-poll"), 100_000);
    }
    if (services.avatars) |avatars| {
        avatars.beginPicker(model.panel == .players);
        const delay_ms = avatars.retryDelayMilliseconds();
        if (delay_ms != std.math.maxInt(u32)) dvui.timer(dvui.parentGet().data().id.update("player-avatar-poll"), @intCast(@min(@as(u64, delay_ms) * 1000, std.math.maxInt(i32))));
    }
    try services.servers.updateSelected(services.configuration.snapshot(), services.allow_mutations);
    const server_cards_open = model.panel == .versions or model.panel == .servers;
    try services.servers.updatePicker(services.configuration.snapshot().servers, server_cards_open and services.allow_mutations);
    if (services.allow_mutations and services.configuration.snapshot().selected_server != null) {
        const delay_ms = services.servers.selectedRefreshDelay();
        dvui.timer(dvui.parentGet().data().id.update("selected-server-poll"), @intCast(@min(@as(u64, delay_ms) * 1000, std.math.maxInt(i32))));
    }
    if (server_cards_open and services.allow_mutations) {
        const delay_ms = services.servers.pickerRefreshDelay();
        dvui.timer(dvui.parentGet().data().id.update("server-picker-poll"), @intCast(@min(@as(u64, delay_ms) * 1000, std.math.maxInt(i32))));
    }
    var gates = serviceGates(services);
    gates.java = gates.java or launchPinsJava(launcher.snapshot().phase) or if (services.instances) |instance_manager| instance_manager.isBusy() else false;
    java_view.setDownloadController(java_ui, services.java_download);
    java_download_view.beginFrame(services.java_download_ui);
    if (gates.java) discardJavaIntents(java_ui, services.java_download_ui);
    var pending: ?state.Msg = null;
    var command: ?tools.Command = null;
    {
        const available = @max(1, dvui.windowRect().w - 8);
        const instance_panel = model.panel == .instances;
        const sidebar_width = if (instance_panel) &model.instance_sidebar_width else &model.sidebar_width;
        const initial_width = if (instance_panel) boundedInstanceSidebarWidth(sidebar_width.*, available) else if (model.panel == .logs) boundedLogsSidebarWidth(sidebar_width.*, available) else boundedSidebarWidth(sidebar_width.*, available);
        var split = initial_width / available;
        const root = dvui.paned(@src(), .{ .direction = .horizontal, .collapsed_size = 0, .split_ratio = &split, .handle_size = 8 }, .{ .expand = .both, .background = false, .margin = R.all(0), .padding = R.all(0), .label = .{ .text = "调整侧栏宽度" } });
        defer root.deinit();
        const resized_width = if (instance_panel) boundedInstanceSidebarWidth(split * available, available) else if (model.panel == .logs) boundedLogsSidebarWidth(split * available, available) else boundedSidebarWidth(split * available, available);
        split = resized_width / available;
        if (@abs(resized_width - initial_width) > 0.1) sidebar_width.* = resized_width;
        if (root.showFirst()) {
            switch (model.panel) {
                .more => tools.moreMenu(model, &pending),
                .java => {
                    const side = tools.beginUtilityMenu("Java 管理");
                    defer side.deinit();
                    tools.utilityMenuFooter(model, &pending);
                    java_view.drawSidebar(java_ui, manager, !gates.java);
                },
                .servers => {
                    const side = tools.beginUtilityMenu("服务器");
                    defer side.deinit();
                    tools.utilityMenuFooter(model, &pending);
                    if (!gates.instances) servers_view.drawSidebar(services.servers_ui, services.configuration, services.servers);
                },
                .logs => {
                    const side = tools.beginUtilityMenu("游戏日志");
                    defer side.deinit();
                    if (services.logs.drawNavigationFooter(launcher)) pending = .back;
                    try services.logs.drawSidebar(launcher);
                },
                .instances => {
                    const side = instances_view.sidebarPanel(@src());
                    defer side.deinit();
                    instances_view.sidebarHeading(@src());
                    if (instances_view.sidebarFooter(@src(), model.parentLabel())) pending = model.parentMessage();
                    if (services.instances) |instance_manager| if (services.instances_ui) |ui| instances_view.drawSidebar(ui, services.configuration, instance_manager, !gates.instances);
                },
                .mods => if (services.mods) |controller| {
                    if (services.mods_ui) |ui| mods_page.sidebar(model, &pending, services.configuration.snapshot(), controller, ui, !gates.content);
                },
                .worlds => {
                    const side = tools.beginUtilityMenu("存档");
                    defer side.deinit();
                    tools.utilityMenuFooter(model, &pending);
                    worlds_view.drawSidebar(services.worlds_ui, services.configuration.snapshot(), services.worlds, !gates.worlds);
                },
                else => sidebar(model, &pending, services.configuration.snapshot(), services.servers, services.avatars),
            }
        }
        if (services.instances_ui) |ui| if (services.instances) |manager_| {
            ui.creation_presented = if (services.ordinary_creation) |controller| controller.presentsCreation(manager_) else false;
        };
        if (root.showSecond()) try content(model, snapshot, &pending, &command, manager, java_ui, launcher, services);
    }
    if (model.panel == .mods) if (services.mods) |controller| if (services.mods_ui) |ui| if (services.content) |backend| try mods_page.dialogs(model, services.configuration.snapshot(), controller, ui, backend, !gates.content);
    if (services.instances_ui) |ui| if (ui.manage_requested) {
        ui.manage_requested = false;
        if (ui.draft.id) |id| {
            if (model.mods_instance.set(id)) pending = .open_mods;
        }
    };
    if (!gates.instances) servers_view.drawModal(services.servers_ui, services.configuration.snapshot());
    if (services.instances_ui) |ui| {
        if (services.instances) |manager_| {
            ui.creation_presented = if (services.ordinary_creation) |controller| controller.presentsCreation(manager_) else false;
            instances_view.syncTaskSnapshot(ui, if (ui.creation_presented) services.ordinary_creation.?.creationSnapshot() else manager_.snapshot());
        }
        instances_view.drawModal(ui, !gates.instances);
    }
    if (!gates.java) {
        java_view.drawModal(java_ui);
        if (java_ui.download_requested) {
            java_ui.download_requested = false;
            java_ui.acquisition_open = true;
            java_ui.acquisition_mode = .download;
            if (services.java_download.snapshot().phase != .running) java_download_view.suggestMajor(services.java_download_ui, java_ui.requested_major);
            pending = .open_java;
        }
    } else discardJavaIntents(java_ui, services.java_download_ui);
    if (!gates.worlds) try worlds_view.drawModal(services.worlds_ui, services.configuration.snapshot(), services.worlds);
    if (services.instances_ui) |ui| guardInstanceLeave(model, ui, &pending);
    appearance_view.guardNavigation(services.appearance, &pending, services.configuration);
    try appearance_view.dialogs(services.appearance, services.configuration);
    if (pending) |msg| {
        const selection_allowed = !gates.instances and model.panel == .versions;
        const transition_allowed = switch (msg) {
            .use_game, .select_instance, .select_server => selection_allowed,
            .start => !gates.instances and !gates.content and !services.java_download.isDeleting(),
            else => true,
        };
        if (transition_allowed) {
            state.transition(model, msg);
            dvui.refresh(null, @src(), null);
        }
        switch (msg) {
            .start => if (!gates.instances and !gates.content and !services.java_download.isDeleting()) {
                startGame(manager, launcher, services);
                if (launch_error) |err| components.alert(@src(), "无法启动游戏", launchFailureMessage(err));
            },
            .select_instance => |id| if (selection_allowed) {
                launch_error = null;
                game_selection_view.selectInstance(services.configuration, services.servers, id) catch |err| {
                    launch_error = err;
                };
                syncSelectedGame(model, services.configuration.snapshot());
            },
            .select_server => |id| if (selection_allowed) {
                launch_error = null;
                game_selection_view.selectServer(services.configuration, services.servers, id) catch |err| {
                    launch_error = err;
                };
                syncSelectedGame(model, services.configuration.snapshot());
            },
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
    if (services.instances_ui) |ui| {
        if (ui.catalogue_requested and !gates.content and !gates.instances and snapshot.phase != .loading) {
            ui.catalogue_requested = false;
            command = .load;
        }
    }
    if (!gates.content) {
        if (command) |cmd| {
            model.library_error = null;
            switch (cmd) {
                .load => library.loadCatalogue() catch |err| {
                    model.library_error = err;
                    if (services.instances_ui) |ui| ui.failure = err;
                },

                .cancel => library.cancel(),
            }
        }
    }
    // Navigation invalidates picker receipts before any consumer can apply them.
    discardInactivePickers(model, java_ui, services);
    if (model.panel == .java and !gates.java) java_view.syncPicker(java_ui);
    // A start intent above can acquire the launch lease in this same frame.
    const java_blocked = gates.java or launchPinsJava(launcher.snapshot().phase) or if (services.instances) |instance_manager| instance_manager.isBusy() else false;
    if (!java_blocked) java_view.finish(java_ui, manager) else discardJavaIntents(java_ui, services.java_download_ui);
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
    if (!java_blocked) java_download_view.finish(services.java_download_ui, services.java_download);
    if (services.mods) |controller| if (services.mods_ui) |ui| if (services.content) |backend| mods_page.finish(model, services.configuration, controller, ui, backend, !gates.content);
    if (!gates.instances) {
        servers_view.finish(services.servers_ui, services.configuration, services.servers);
        if (services.servers_ui.binding_navigation_ready) {
            services.servers_ui.binding_navigation_ready = false;
            state.transition(model, .open_servers);
        }
    }
    services.logs.finish(launcher);
    if (services.allow_mutations) services.worlds_ui.setPageActive(model.panel == .worlds);
    if (!gates.worlds) worlds_view.finish(services.worlds_ui, services.configuration, services.worlds);
    if (!gates.instances) {
        if (services.accounts) |accounts| if (services.accounts_ui) |ui| accounts_view.finish(ui, services.configuration, accounts);
    }
    if (!gates.instances) {
        if (services.instances) |manager_| {
            if (services.instances_ui) |ui| {
                if (manager_.setDefaultJava(defaultInstallerJava(manager.entries()))) |_| {
                    const before_submitted = ui.submitted;
                    if (services.ordinary_creation) |controller| {
                        if (creationServices(services, manager)) |bound| {
                            instances_view.finishWithPreflight(ui, services.configuration, manager_, controller, bound, services.allow_mutations);
                        } else instances_view.finish(ui, services.configuration, manager_);
                    } else instances_view.finish(ui, services.configuration, manager_);
                    if (ui.submitted != before_submitted) dvui.refresh(null, @src(), null);
                } else |err| {
                    ui.failure = err;
                }
            }
        }
    } else if (services.instances) |manager_| {
        if (services.instances_ui) |ui| {
            if (ui.creation_active and services.ordinary_creation != null) {
                if (creationServices(services, manager)) |bound| instances_view.finishWithPreflight(ui, services.configuration, manager_, services.ordinary_creation.?, bound, services.allow_mutations);
            } else if (gatedTaskActionAllowed(if (ui.pending) |action| action.action else null, services.allow_mutations)) {
                instances_view.finish(ui, services.configuration, manager_);
            }
        }
    }
    appearance_view.finish(services.appearance, services.configuration);
}

fn defaultInstallerJava(runtimes: []const java.Runtime) ?[]const u8 {
    var best: ?java.Runtime = null;
    for (runtimes) |runtime| {
        if (runtime.major < 8) continue;
        if (best == null or runtime.major > best.?.major) best = runtime;
    }
    return if (best) |runtime| runtime.path else null;
}

fn launchFailureMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InstanceNotSelected, error.InstanceNotConfigured => "请先选择一个游戏实例。",
        error.NoAccountSelected => "请先选择一个账户。",
        error.LoginRequired, error.AuthorizationExpired => "账户需要重新登录，请在账户页面完成登录后再试。",
        error.JavaDeleteBusy => "Java 正在删除，请稍后重试。",
        error.InstallInProgress => "游戏正在安装，请等待安装完成后再启动。",
        error.Busy => "所选账户或游戏正在处理其他操作，请稍后重试。",
        error.ServerInstanceMismatch => "所选服务器与游戏实例不匹配，请重新选择。",
        else => std.fmt.allocPrint(dvui.currentWindow().arena(), "无法启动游戏：{s}", .{@errorName(err)}) catch "无法启动游戏，请重试。",
    };
}

fn startGame(manager: *java.Manager, launcher: *launch.Controller, services: Services) void {
    const document = services.configuration.snapshot();
    launch_error = null;
    if (services.java_download.isDeleting()) {
        launch_error = error.JavaDeleteBusy;
        return;
    }
    if (servers_view.requestLaunchBinding(services.servers_ui, document) catch |err| {
        launch_error = err;
        return;
    }) {
        dvui.refresh(null, @src(), null);
        return;
    }
    const selected_id = document.selected_instance orelse {
        launch_error = error.InstanceNotSelected;
        return;
    };
    const instance = instances.findById(document, selected_id) orelse {
        launch_error = error.InstanceNotConfigured;
        return;
    };
    const java_path = instance.java_path orelse manager.selectedPath(instance.name) orelse "";
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
            if (server.instance_id == null or !std.mem.eql(u8, server.instance_id.?, instance.id)) {
                launch_error = error.ServerInstanceMismatch;
                return;
            }
            endpoint = .{ .address = server.address, .port = server.port };
            break;
        };
    }
    launcher.startWithOptions(.{
        .version = instance.name,
        .java_path = java_path,
        .java_major = 0,
        .username = session.username,
        .min_memory_mb = instance.min_memory_mb,
        .max_memory_mb = instance.max_memory_mb orelse document.settings.default_memory_mb,
    }, .{
        .resolve_java_from_metadata = true,
        .java_candidates = manager.entries(),
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

fn gap(src: std.builtin.SourceLocation, height: f32) void {
    _ = dvui.spacer(src, .{ .min_size_content = .{ .h = height } });
}

fn sidebar(model: *const state.Model, pending: *?state.Msg, document: *const config.Document, manager: *server_manager.Manager, avatars: ?*avatar_manager.Manager) void {
    const account = selectedAccount(document);
    const name = if (account) |value| value.name else model.labels.choosePlayer;
    const kind = if (account) |value| (if (value.kind == .microsoft) "Microsoft" else "离线账户") else "未选择账号";
    const side = components.sidebarPanel(@src());
    defer side.deinit();
    if (model.panel == .players or model.panel == .versions) {
        if (components.sidebarFooter(@src(), model.parentLabel(), true)) pending.* = model.parentMessage();
    } else {
        if (components.sidebarFooter(@src(), model.labels.more, true)) pending.* = .open_more;
    }
    const compact = side.data().contentRect().h < 440;
    const spacing: f32 = if (compact) theme.spacing.card_gap else 32;
    components.sidebarTitle(@src(), "Vela Launcher", compact);
    gap(@src(), spacing);
    {
        const name_font = theme.headingFont();
        const kind_font = theme.captionFont();
        const text_height = name_font.textSize(name).h + theme.style.cards.sidebar_account_text_gap + kind_font.textSize(kind).h;
        const row_height = @max(theme.style.cards.sidebar_account_height - 2 * theme.style.cards.sidebar_account_padding_y, text_height);
        var player: dvui.ButtonWidget = undefined;
        player.init(@src(), .{ .draw_focus = false }, .{ .tag = "sidebar-player", .expand = .horizontal, .min_size_content = .{ .h = row_height }, .max_size_content = .width(0), .padding = .{ .x = theme.style.cards.sidebar_account_padding_x - 1, .w = theme.style.cards.sidebar_account_padding_x - 1, .y = theme.style.cards.sidebar_account_padding_y - 1, .h = theme.style.cards.sidebar_account_padding_y - 1 }, .margin = R.all(0), .border = R.all(1), .corners = .all(theme.cardRadius()), .color_fill = .{ .color = theme.colors.sidebar }, .color_border = .{ .color = dvui.Color.transparent }, .label = .{ .text = model.labels.choosePlayer } });
        defer player.deinit();
        player.processEvents();
        theme.surface.buttonBackground(&player);
        {
            const identity = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .min_size_content = .{ .h = row_height }, .padding = R.all(0), .margin = R.all(0) });
            defer identity.deinit();
            {
                const avatar = dvui.box(@src(), .{}, .{ .min_size_content = dvui.Size.all(theme.style.cards.avatar), .max_size_content = .size(dvui.Size.all(theme.style.cards.avatar)), .gravity_y = 0.5, .padding = R.all(0), .margin = R.all(0), .border = R.all(0), .background = false });
                defer avatar.deinit();
                drawAccountAvatar(account, avatars);
            }
            _ = dvui.spacer(@src(), .{ .min_size_content = .width(theme.style.cards.sidebar_account_gap) });
            const details = dvui.box(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .min_size_content = .{ .h = text_height }, .padding = R.all(0), .margin = R.all(0) });
            defer details.deinit();
            dvui.labelNoFmt(@src(), name, .{ .ellipsize = true }, .{ .font = name_font, .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = R.all(0) });
            gap(@src(), theme.spacing.detail_gap);
            components.hint(@src(), kind);
        }
        theme.drawCardOutline(player.data(), player.focused());
        if (player.clicked()) pending.* = if (model.panel == .players) .back else .open_players;
    }
    gap(@src(), theme.style.cards.sidebar_identity_gap);
    const body = components.scrollBody(@src());
    defer body.deinit();
    const width = dvui.parentGet().data().contentRect().w;
    const game_action: state.Msg = if (model.panel == .versions) .back else .open_versions;
    if (document.selected_server) |id| {
        for (document.servers) |server| {
            if (!std.mem.eql(u8, server.id, id)) continue;
            const query = if (model.panel == .versions) manager.pickerSnapshot(id) else manager.snapshot();
            if (game_selection_view.serverCard(@src(), server, document, query, false, true, width, "sidebar-game-target")) pending.* = game_action;
            return;
        }
    }
    if (document.selected_instance) |id| {
        if (instances.findById(document, id)) |instance| {
            if (components.selectionCard(@src(), instance.id, instance.name, .{ .width = width, .description = game_selection_view.instanceDescription(instance), .tag = "sidebar-game-target" })) pending.* = game_action;
            return;
        }
    }
    if (components.selectionCard(@src(), "choose-game", configuredGameName(model, document), .{ .width = width, .tag = "sidebar-game-target" })) pending.* = game_action;
}

fn selectedAccount(document: *const config.Document) ?config.Account {
    const id = document.selected_account orelse return null;
    for (document.accounts) |account| if (std.mem.eql(u8, account.id, id)) return account;
    return null;
}

fn drawAccountAvatar(account: ?config.Account, avatars: ?*avatar_manager.Manager) void {
    if (account) |value| {
        if (avatars) |manager| {
            avatar_image.draw(@src(), manager.face(value));
            return;
        }
        if (avatar_image.defaultFace(dvui.currentWindow().arena(), value.uuid)) |default| {
            var face = default;
            avatar_image.draw(@src(), &face);
            return;
        } else |_| {}
    }
    dvui.labelNoFmt(@src(), accountInitial(account), .{ .align_x = 0.5, .align_y = 0.5 }, .{ .gravity_x = 0.5, .gravity_y = 0.5, .font = theme.fontSized(theme.typography.avatar), .color_text = .{ .color = theme.style.colors.on_accent }, .padding = R.all(0), .margin = R.all(0) });
}

fn accountInitial(account: ?config.Account) []const u8 {
    const name = if (account) |value| value.name else return "?";
    if (name.len == 0) return "?";
    const length = std.unicode.utf8ByteSequenceLength(name[0]) catch return "?";
    return name[0..@min(length, name.len)];
}

fn content(model: *state.Model, snapshot: games.Snapshot, pending: *?state.Msg, command: *?tools.Command, manager: *java.Manager, java_ui: *java_view.Ui, launcher: *launch.Controller, services: Services) !void {
    _ = command;
    var gates = serviceGates(services);
    gates.java = gates.java or launchPinsJava(launcher.snapshot().phase);
    const parent_id = dvui.parentGet().data().id;
    var key: u64 = @backingInt(model.panel);
    key = key * 16 + @backingInt(model.category);

    const previous = dvui.dataGet(null, parent_id, "content_panel", u64);
    if (previous == null or previous.? != key) {
        dvui.animation(parent_id, "content_enter", .{ .end_time = 180_000, .easing = dvui.easing.outCubic });
    }
    dvui.dataSet(null, parent_id, "content_panel", key);
    const progress = if (dvui.animationGet(parent_id, "content_enter")) |a| a.value() else 1;
    const offset = 8 * (1 - progress);
    const compact_home = model.panel == .home and (services.task_viewport_height orelse dvui.windowRect().h) < 520;
    const compact_instances = model.panel == .instances and (dvui.windowRect().w < theme.style.layout.compact_page_width or dvui.windowRect().h < theme.style.layout.compact_page_height);
    const padding: f32 = if (compact_home) theme.spacing.panel_compact_padding else if (compact_instances) theme.spacing.sidebar_padding else theme.spacing.page_padding;
    const pane = dvui.box(@src(), .{}, .{ .id_extra = @backingInt(model.panel), .expand = .both, .padding = .{ .x = padding + offset, .w = padding - offset, .y = padding, .h = padding } });
    defer pane.deinit();
    const previous_clip = dvui.clip(pane.data().contentRectScale().r);
    defer dvui.clipSet(previous_clip);
    const previous_alpha = dvui.alpha(progress);
    defer dvui.alphaSet(previous_alpha);
    switch (model.panel) {
        .home => try drawHome(model, launcher.snapshot(), pending, services),
        .players => drawAccountSelection(model, launcher.snapshot(), pending, services),
        .versions => drawGameSelection(model, launcher.snapshot(), pending, services),
        .more => switch (model.category) {
            .settings => if (services.cf_credentials) |controller|
                try settings_view.drawWithCredentials(services.settings, controller, services.configuration.snapshot().settings, gates.content or if (services.content) |content_service| content_service.isBusy() else false, services.configuration.publicationUncertain())
            else if (services.cf_credentials_failure) |failure|
                try settings_view.drawUnavailable(services.settings, services.configuration.snapshot().settings, failure)
            else
                try settings_view.draw(services.settings),
            .game => tools.moreContent(model, pending),
            .theme => try appearance_view.draw(services.appearance, services.configuration),
        },

        .java => if (!gates.java) java_view.drawPage(java_ui, manager, services.java_download_ui, services.java_download) else components.hint(@src(), "游戏或实例创建任务进行中，Java 配置暂不可更改"),
        .servers => servers_view.draw(services.servers_ui, services.configuration, services.servers),
        .mods => if (services.mods) |controller| {
            if (services.mods_ui) |ui| if (services.content) |backend| try mods_page.draw(model, services.configuration.snapshot(), controller, ui, backend, !gates.content);
        },
        .worlds => try worlds_view.drawWithEnabled(services.worlds_ui, services.configuration.snapshot(), services.worlds, !gates.worlds),
        .logs => try services.logs.draw(launcher),
        .instances => if (services.instances) |manager_| {
            if (services.instances_ui) |ui| instances_view.drawWithEnabled(ui, services.configuration, manager_, snapshot, manager.entries(), !gates.instances);
        },
    }
}

pub fn drawHome(model: *const state.Model, process: launch.Snapshot, pending: *?state.Msg, services: Services) !void {
    const frame = dvui.box(@src(), .{}, .{ .tag = "home-layout", .expand = .both, .padding = R.all(0), .margin = R.all(0) });
    defer frame.deinit();
    drawStartFooter(model, process, pending, services, frame.data().contentRect(), "home-footer", "home-start");
}

pub fn drawGameSelection(model: *state.Model, process: launch.Snapshot, pending: *?state.Msg, services: Services) void {
    drawLaunchSelection(model, process, pending, services, .game);
}

pub fn drawAccountSelection(model: *state.Model, process: launch.Snapshot, pending: *?state.Msg, services: Services) void {
    drawLaunchSelection(model, process, pending, services, .account);
}

fn drawLaunchSelection(model: *state.Model, process: launch.Snapshot, pending: *?state.Msg, services: Services, page: enum { game, account }) void {
    const game_page = page == .game;
    const frame = dvui.box(@src(), .{}, .{ .tag = if (game_page) "game-selection-layout" else "account-selection-layout", .id_extra = @backingInt(page), .expand = .both, .padding = R.all(0), .margin = R.all(0) });
    defer frame.deinit();
    const bounds = frame.data().contentRect();
    drawStartFooter(model, process, pending, services, bounds, if (game_page) "game-selection-footer" else "account-selection-footer", if (game_page) "game-selection-start" else "account-selection-start");
    const body = dvui.box(@src(), .{}, .{ .tag = if (game_page) "game-selection-body" else "account-selection-body", .rect = .{ .x = 0, .y = 0, .w = bounds.w, .h = @max(0, bounds.h - theme.sizing.control_height - theme.spacing.footer_gap) }, .padding = R.all(0), .margin = R.all(0) });
    defer body.deinit();
    if (game_page) {
        game_selection_view.draw(model, pending, services.configuration.snapshot(), services.servers, !serviceGates(services).instances, launch_error);
    } else if (services.accounts) |accounts| {
        if (services.accounts_ui) |ui| accounts_view.draw(ui, services.configuration, accounts, services.avatars);
    } else players(model, pending);
}

fn drawStartFooter(model: *const state.Model, process: launch.Snapshot, pending: *?state.Msg, services: Services, bounds: R, footer_tag: []const u8, start_tag: []const u8) void {
    const font = theme.bodyFont();
    const running = process.phase == .preparing or process.phase == .running;
    const start_label = if (process.phase == .preparing) "正在启动" else model.labels.start;
    const gates = serviceGates(services);
    // Readiness is checked for the selected instance only after a launch intent.
    const disabled = gates.instances or gates.content or services.java_download.isDeleting() or running;
    const footer_height = theme.sizing.control_height;
    const footer = dvui.box(@src(), .{}, .{ .tag = footer_tag, .rect = .{ .x = 0, .y = @max(0, bounds.h - footer_height), .w = bounds.w, .h = footer_height }, .padding = R.all(0), .margin = R.all(0) });
    defer footer.deinit();
    var start: dvui.ButtonWidget = undefined;
    const launch_width = @min(theme.sizing.home_launch_width, bounds.w);
    const geometry = theme.controlGeometry(@max(font.lineHeight(), font.textSize(start_label).h), footer_height, launch_width, theme.sizing.control_padding_x, theme.sizing.control_border);
    start.init(@src(), .{ .grayed = disabled }, theme.controlOptions(@max(font.lineHeight(), font.textSize(start_label).h)).override(.{ .tag = start_tag, .label = .{ .text = start_label }, .font = font, .rect = .{ .x = @max(0, bounds.w - launch_width), .y = 0, .w = launch_width, .h = footer_height }, .style = .highlight, .color_fill = if (disabled) .{ .color = theme.panelColor(theme.colors.surface) } else null, .min_size_content = geometry.content, .padding = geometry.padding, .margin = R.all(0), .tab_index = if (disabled) 0 else null }));
    defer start.deinit();
    if (disabled) {
        if (start.data().accesskit_node()) |node| {
            dvui.AccessKit.nodeSetDisabled(node);
            dvui.AccessKit.nodeRemoveAction(node, .focus);
            dvui.AccessKit.nodeRemoveAction(node, .click);
        }
    }
    if (!disabled) start.processEvents();
    theme.buttonBackground(&start, .{ .material = disabled });
    // Keep the disabled label legible instead of using ButtonWidget's averaged text color.
    dvui.labelNoFmt(@src(), start_label, .{ .align_x = 0.5, .align_y = 0.5 }, start.style().override(.{ .color_text = if (disabled) .{ .color = theme.colors.muted } else null, .gravity_x = 0.5, .gravity_y = 0.5, .padding = R.all(0), .margin = R.all(0) }));
    if (!disabled and start.clicked()) pending.* = .start;
}

fn pickerHeader(src: std.builtin.SourceLocation, name: []const u8, back: []const u8, pending: *?state.Msg) void {
    _ = back;
    _ = pending;
    components.title(src, name);
}

fn choice(src: std.builtin.SourceLocation, id: u32, name: []const u8, detail: []const u8, current: bool, current_label: []const u8) bool {
    var item: dvui.ButtonWidget = undefined;
    const item_height = dvui.themeGet().font_body.textSize(name).h + theme.captionFont().textSize(detail).h + theme.spacing.detail_gap;
    item.init(src, .{}, theme.panelButtonOptions(.{ .id_extra = id, .expand = .horizontal, .min_size_content = .{ .h = item_height }, .padding = R.all(theme.spacing.panel_padding), .margin = .{ .h = theme.spacing.card_gap }, .border = R.all(1), .style = .control, .color_border = if (current) .{ .color = theme.colors.accent } else null, .label = .{ .text = name } }, false));
    defer item.deinit();
    item.processEvents();
    theme.buttonBackground(&item, .{ .material = true });
    {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .min_size_content = .{ .h = item_height } });
        defer row.deinit();
        if (current) dvui.labelNoFmt(@src(), current_label, .{}, .{ .gravity_x = 1, .gravity_y = 0.5, .color_text = .{ .color = theme.colors.accent }, .padding = R.all(0), .margin = .{ .x = theme.spacing.card_gap }, .background = false });
        {
            const text = dvui.box(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .h = item_height } });
            defer text.deinit();
            dvui.labelNoFmt(@src(), name, .{}, item.style().override(.{ .padding = R.all(0), .margin = R.all(0), .background = false }));
            gap(@src(), theme.spacing.detail_gap);
            dvui.labelNoFmt(@src(), detail, .{}, item.style().override(.{ .font = theme.captionFont(), .padding = R.all(0), .margin = R.all(0), .background = false }));
        }
    }
    return item.clicked();
}

fn players(model: *const state.Model, pending: *?state.Msg) void {
    pickerHeader(@src(), model.labels.choosePlayer, model.labels.back, pending);
    gap(@src(), theme.spacing.page_title_gap);
    const scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false, .padding = R.all(0), .border = R.all(0), .label = .{ .text = model.labels.playerList } });
    defer scroll.deinit();
    if (!model.hasPlayers()) components.emptyState(@src(), model.labels.noPlayers);
    for (model.players) |p| {
        if (choice(@src(), p.id, p.name, p.kind, p.id == model.selected_player, model.labels.current)) pending.* = .{ .select_player = p.id };
    }
}

fn configuredGameName(model: *const state.Model, document: *const config.Document) []const u8 {
    if (document.selected_instance) |id| {
        if (instances.findById(document, id)) |instance| return instance.name;
    }
    return model.versionName();
}

fn syncSelectedGame(model: *state.Model, document: *const config.Document) void {
    const id = document.selected_instance orelse return;
    const instance = instances.findById(document, id) orelse return;
    _ = model.active_game.set(instance.name);
}

test "foreground task cancellation and acknowledgement bypass only page gates" {
    inline for (@typeInfo(instances_view.Action).@"enum".field_values) |value| {
        const action: instances_view.Action = @fromBackingInt(@intCast(value));
        try std.testing.expectEqual(action == .cancel or action == .close_task, gatedTaskActionAllowed(action, true));
        try std.testing.expect(!gatedTaskActionAllowed(action, false));
    }
    try std.testing.expect(!gatedTaskActionAllowed(null, true));
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
    ui.acquisition_open = true;
    ui.search_started = true;
    ui.download_requested = true;
    download_ui.pending = .cancel;
    download_ui.start_admitted = true;
    download_ui.cancel_requested = true;
    try std.testing.expect(javaIntents(&ui, &download_ui));
    discardJavaIntents(&ui, &download_ui);
    discardJavaIntents(&ui, &download_ui);
    try std.testing.expect(!javaIntents(&ui, &download_ui));
    try std.testing.expect(!download_ui.start_admitted);
    try std.testing.expect(ui.acquisition_open and ui.search_started);
    const released = dispatchGates(.idle, false, false, true);
    try std.testing.expect(!released.java and ui.commands.items.len == 0 and download_ui.pending == null);
}

test "Java mutation admission is pinned for preparation and the running process" {
    try std.testing.expect(launchPinsJava(.preparing));
    try std.testing.expect(launchPinsJava(.running));
    try std.testing.expect(!launchPinsJava(.idle));
    try std.testing.expect(!launchPinsJava(.exited));
    try std.testing.expect(!launchPinsJava(.failed));
}

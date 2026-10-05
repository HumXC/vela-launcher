const std = @import("std");
const dvui = @import("dvui");
const state = @import("ui/model.zig");
const view = @import("ui/view.zig");
const theme = @import("ui/theme.zig");
const fonts = @import("ui/fonts.zig");
const game_library = @import("ui/game_library.zig");
const java_manager = @import("ui/java_manager.zig");
const java_view = @import("ui/java_view.zig");
const game_launch = @import("ui/game_launch.zig");
const config = @import("core/config.zig");
const instance_paths = @import("core/instances.zig");
const task_registry = @import("core/tasks.zig");
const window_control = @import("ui/window_control.zig");
const lifecycle = @import("core/lifecycle.zig");
const shutdown_view = @import("ui/shutdown_view.zig");
const settings_view = @import("ui/settings_view.zig");
const java_download_controller = @import("ui/java_download_controller.zig");
const java_download_view = @import("ui/java_download_view.zig");
const server_manager = @import("ui/server_manager.zig");
const servers_view = @import("ui/servers_view.zig");
const logs_view = @import("ui/logs_view.zig");
const worlds = @import("core/worlds.zig");
const instance_leases = @import("core/instance_leases.zig");
const accounts_manager = @import("ui/accounts_manager.zig");
const accounts_view = @import("ui/accounts_view.zig");
const instances_manager = @import("ui/instances_manager.zig");
const instances_view = @import("ui/instances_view.zig");
const content_manager = @import("ui/content_manager.zig");
const content_view = @import("ui/content_view.zig");
const pack_import_controller = @import("ui/pack_import_controller.zig");
const pack_import_view = @import("ui/pack_import_view.zig");
const cf_credentials_controller = @import("ui/curseforge_credentials_controller.zig");
const worlds_manager = @import("ui/worlds_manager.zig");
const worlds_view = @import("ui/worlds_view.zig");
// The normal root has no acceptance capability and retains its production services.
const acceptance_enabled = @hasDecl(@import("root"), "vela_lifecycle_acceptance");
const acceptance = if (acceptance_enabled) @import("root").vela_lifecycle_acceptance else struct {};

pub const dvui_app: dvui.App = .{
    .config = .{ .startFn = start },
    .initFn = init,
    .deinitFn = deinit,
    .frameFn = frame,
};
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

var native_backend_configuration_error: ?anyerror = null;

fn start() dvui.App.StartOptions {
    native_backend_configuration_error = null;
    window_control.configureNativeBackend() catch |err| {
        native_backend_configuration_error = err;
    };
    return .{
        .size = .{ .w = 1000, .h = 640 },
        .min_size = .{ .w = 640, .h = 400 },
        .title = "Vela Launcher",
        .window_init_options = .{ .keybinds_zoom = true },
    };
}

var model: state.Model = .{};
var library: game_library.Controller = undefined;
var library_initialized = false;
var java: java_manager.Manager = undefined;
var java_ui: java_view.Ui = undefined;
var launcher: game_launch.Controller = undefined;
var paths: instance_paths.Paths = undefined;
var configuration: config.Store = undefined;
var settings_ui: settings_view.Ui = undefined;
var java_download: java_download_controller.Controller = undefined;
var java_download_ui: java_download_view.Ui = undefined;
var servers: server_manager.Manager = undefined;
var servers_ui: servers_view.Ui = undefined;
var logs_ui: logs_view.View = .{};
var world_manager: worlds_manager.Manager = undefined;
var worlds_ui: worlds_view.Ui = undefined;
var observed_attempt: u64 = 0;
var leases: instance_leases.Coordinator = undefined;
var accounts: accounts_manager.Manager = undefined;
var accounts_ui: accounts_view.Ui = undefined;
var instance_manager: instances_manager.Manager = undefined;
var instances_ui: instances_view.Ui = undefined;
var content: content_manager.Manager = undefined;
var content_ui: content_view.Ui = undefined;
var pack_import: pack_import_controller.Controller = undefined;
var pack_import_ui: pack_import_view.Ui = undefined;
var cf_credentials: ?cf_credentials_controller.Controller = null;
var cf_credentials_failure: ?anyerror = null;
var tasks: task_registry.Registry = undefined;
var window: window_control.Control = .{};
var policy: lifecycle.Policy = .{};
var observed_instances: u64 = 0;

fn packServices() pack_import_controller.Services {
    return .{ .store = &configuration, .java = &java, .java_download = &java_download, .instances = &instance_manager, .content = &content };
}

fn cfCredentialsLease() bool {
    return if (cf_credentials) |*controller| controller.lease() else true;
}

fn cfCredentialsBusy() bool {
    return if (cf_credentials) |*controller| controller.isBusy() else false;
}

fn instanceFingerprint(document: *const config.Document) u64 {
    var hash = std.hash.Wyhash.init(0);
    for (document.instances) |instance| {
        hash.update(instance.id);
        hash.update(&[_]u8{0});
        hash.update(instance.name);
        hash.update(&[_]u8{0});
    }
    return hash.final();
}

pub fn init(win: *dvui.Window) !void {
    if (native_backend_configuration_error) |err| return err;
    win.backend.impl.log_events = false;
    model = .{ .versions = &.{}, .selected_version = 0 };
    policy = .{};
    logs_ui = .{};
    observed_attempt = 0;
    const main_init = dvui.App.main_init orelse return error.MissingAppInit;
    if (acceptance_enabled) try acceptance.validate(main_init.gpa, main_init.io, main_init.environ_map);
    errdefer if (acceptance_enabled) acceptance.destroy();
    leases = instance_leases.Coordinator.init(main_init.io);
    _ = leases.mutation(0);
    const base = if (main_init.environ_map.get("VELA_DATA_DIR")) |override|
        try main_init.gpa.dupe(u8, override)
    else
        try std.process.executableDirPathAlloc(main_init.io, main_init.gpa);
    defer main_init.gpa.free(base);
    paths = try instance_paths.Paths.init(main_init.gpa, main_init.io, base);
    errdefer paths.deinit();
    configuration = try config.Store.init(main_init.gpa, main_init.io, paths.root);
    errdefer configuration.deinit();
    if (acceptance_enabled) try acceptance.validateProfile(configuration.snapshot());
    if (@import("builtin").os.tag == .windows) try configuration.prepareStorage();
    observed_instances = instanceFingerprint(configuration.snapshot());
    settings_ui = try settings_view.Ui.init(main_init.gpa, configuration.snapshot().settings);
    errdefer settings_ui.deinit();
    tasks = task_registry.Registry.init(main_init.gpa);
    errdefer tasks.deinit();
    cf_credentials = null;
    cf_credentials_failure = null;
    if (!acceptance_enabled) {
        if (cf_credentials_controller.Controller.init(main_init.gpa, main_init.io, paths.root, .{ .registry = &tasks })) |controller| {
            cf_credentials = controller;
        } else |err| {
            cf_credentials_failure = err;
        }
    }
    errdefer if (cf_credentials) |*controller| controller.deinit();
    servers = if (acceptance_enabled) server_manager.Manager.initWithQuery(main_init.gpa, main_init.io, acceptance.denyServer) else server_manager.Manager.init(main_init.gpa, main_init.io);
    errdefer servers.deinit();
    servers_ui = servers_view.Ui.init(main_init.gpa);
    errdefer servers_ui.deinit();
    if (configuration.snapshot().selected_instance) |id| {
        if (instance_paths.findById(configuration.snapshot(), id)) |instance| {
            _ = model.active_game.set(instance.name);
        }
    }
    var library_options: game_library.Options = .{
        .root = paths.minecraft,
        .task_registry = &tasks,
        .cache_root = paths.cache,
    };
    if (acceptance_enabled) {
        library_options.manifest_url = "invalid://no-http";
    } else if (main_init.environ_map.get("VELA_MANIFEST_URL")) |url| library_options.manifest_url = url;
    library = try game_library.Controller.initWithOptions(main_init.gpa, main_init.io, library_options);
    errdefer library.deinit();
    java = try java_manager.Manager.init(main_init.gpa, main_init.io, paths.root);
    errdefer java.deinit();
    java_ui = java_view.Ui.init(main_init.gpa);
    errdefer java_ui.deinit();
    var java_options: java_download_controller.Options = if (acceptance_enabled) acceptance.javaOptions(paths.root, &tasks) else .{ .root = paths.root, .task_registry = &tasks };
    java_options.owned_delete_admission = .{ .check = checkOwnedJavaDeletion };
    java_download = try java_download_controller.Controller.initWithOptions(main_init.gpa, main_init.io, java_options);
    errdefer java_download.deinit();
    java_download_ui = java_download_view.Ui.init(main_init.gpa);
    errdefer java_download_ui.deinit();
    launcher = try game_launch.Controller.initWithOptions(main_init.gpa, main_init.io, library.root, .{
        .log_directory = paths.logs,
        .launch_guard = .{ .context = null, .acquire = reserveLaunch, .release = releaseLaunch },
    });
    errdefer launcher.deinit();
    world_manager = if (acceptance_enabled) try worlds_manager.Manager.initOptions(main_init.gpa, main_init.io, &paths, &tasks, .{ .scope = leases.worldScope(3), .worker = acceptance.worldWorker }) else try worlds_manager.Manager.init(main_init.gpa, main_init.io, &paths, &tasks, leases.worldScope(3));
    errdefer world_manager.deinit();
    worlds_ui = try worlds_view.Ui.init(main_init.gpa);
    errdefer worlds_ui.deinit();
    accounts = if (acceptance_enabled) try accounts_manager.Manager.initWithOptions(main_init.gpa, main_init.io, acceptance.accountOptions(paths.root)) else try accounts_manager.Manager.init(main_init.gpa, main_init.io, paths.root);
    errdefer accounts.deinit();
    accounts_ui = try accounts_view.Ui.init(main_init.gpa);
    errdefer accounts_ui.deinit();
    accounts.tick(&configuration);
    const instance_mutation = leases.mutation(2);
    instance_manager = try instances_manager.Manager.init(main_init.gpa, main_init.io, &paths, &tasks, leases.guard(instance_mutation), .{ .context = instance_mutation, .acquire = instance_leases.Mutation.acquireCallback, .recheck = instance_leases.Mutation.recheckCallback, .release = instance_leases.Mutation.releaseCallback });
    errdefer instance_manager.deinit();
    instance_manager.setWorkerRecheck(instance_leases.Mutation.workerRecheckCallback);
    instance_manager.setCreationAdmission(.{ .check = checkJavaForCreation });
    instance_manager.setInstaller(instances_manager.productionInstaller());
    instance_manager.setLoaderCatalogue(instances_manager.productionLoaderCatalogue());
    instances_ui = instances_view.Ui.init(main_init.gpa);
    errdefer instances_ui.deinit();
    const content_mutation = leases.mutation(1);
    const content_options: content_manager.Options = .{
        .lease = .{ .context = content_mutation, .acquire = instance_leases.Mutation.acquireCallback, .recheck = instance_leases.Mutation.recheckCallback, .release = instance_leases.Mutation.releaseCallback },
        .worker_recheck = instance_leases.Mutation.workerRecheckCallback,
        .transport_options = .{ .allow_curseforge = true },
        .allow_manifest_v2 = true,
        .allow_curseforge_remote = true,
    };
    content = try content_manager.Manager.initOptions(main_init.gpa, main_init.io, &paths, &tasks, if (acceptance_enabled) acceptance.contentOptions(content_options) else content_options);
    errdefer content.deinit();
    content_ui = try content_view.Ui.init(main_init.gpa);
    errdefer content_ui.deinit();
    pack_import_ui = try pack_import_view.Ui.init(main_init.gpa, main_init.io, paths.root);
    errdefer pack_import_ui.deinit();
    pack_import = try pack_import_controller.Controller.init(main_init.gpa, main_init.io, paths.root, .{});
    errdefer pack_import.deinit(packServices());
    try window.init(win);
    errdefer window.deinit();
    try fonts.install(win);
    theme.install(win);
    library_initialized = true;
    // A start failure is retained in the controller snapshot for the game view.
    if (acceptance_enabled) {
        library.refreshInstalled() catch |err| {
            model.library_error = err;
        };
    } else library.loadCatalogue() catch {};
}

pub fn deinit(win: *dvui.Window) void {
    _ = win;
    if (library_initialized) {
        if (acceptance_enabled) acceptance.beforeDestroy();
        pack_import.deinit(packServices());
        pack_import_ui.deinit();
        window.deinit();
        launcher.deinit();
        content_ui.deinit();
        content.deinit();
        instances_ui.deinit();
        instance_manager.deinit();
        world_manager.deinit();
        if (acceptance_enabled) acceptance.worldJoined();
        worlds_ui.deinit();
        java_download.deinit();
        java_download_ui.deinit();
        servers.deinit();
        servers_ui.deinit();
        accounts_ui.deinit();
        accounts.deinit();
        if (acceptance_enabled) acceptance.accountsJoined();
        if (cf_credentials) |*controller| controller.deinit();
        cf_credentials = null;
        settings_ui.deinit();
        java_ui.deinit();
        java.deinit();
        library.deinit();
        tasks.deinit();
        configuration.deinit();
        paths.deinit();
        library_initialized = false;
        if (acceptance_enabled) acceptance.destroy();
    }
}

pub fn frame() !dvui.App.Result {
    try window.checkNativeDisplay();
    dvui.currentWindow().backend.impl.log_events = false;
    if (acceptance_enabled) try acceptance.beforeFrame(&launcher, &world_manager, &configuration, &paths);
    library.tick();
    if (!pack_import.ownsJavaDiscovery()) java.tick();
    launcher.tick();
    leases.tick();
    if (!pack_import.ownsJavaDownload()) java_download.tick(&java);
    servers.tick();
    world_manager.tick();
    accounts.tick(&configuration);
    if (!pack_import.ownsInstancesPublication()) instance_manager.tick();
    pack_import.tick(packServices());
    pack_import_ui.tick(&pack_import);
    content.tick();
    if (cf_credentials) |*controller| controller.tick(&configuration);
    const fingerprint = instanceFingerprint(configuration.snapshot());
    const library_phase = library.snapshot().phase;
    if (fingerprint != observed_instances and library_phase != .loading and library_phase != .installing) {
        if (library.refreshInstalled()) |_| {
            observed_instances = fingerprint;
        } else |err| {
            model.library_error = err;
        }
    }
    model.active_game = .{};
    if (configuration.snapshot().selected_instance) |id| {
        if (instance_paths.findById(configuration.snapshot(), id)) |instance| _ = model.active_game.set(instance.name);
    }
    try library.setDownloadConnections(configuration.snapshot().settings.download_connections);
    if (!view.packWorkflowPinned(&pack_import)) {
        try java_download.setDownloadConnections(configuration.snapshot().settings.download_connections);
        instance_manager.setDownloadConnections(configuration.snapshot().settings.download_connections);
        try content.setDownloadConnections(configuration.snapshot().settings.download_connections);
    }
    if (!view.packWorkflowPinned(&pack_import) and !content.isBusy() and !content.snapshot().recovery_required) {
        const settings = configuration.snapshot().settings;
        var cf_policy: content_manager.CurseForgePolicy = .{
            .enabled = settings.curseforge_enabled and !configuration.publicationUncertain() and cf_credentials != null and !cfCredentialsLease(),
            .terms_approved = settings.curseforge_terms_approved,
        };
        if (settings.curseforge_credential_ref) |reference| cf_policy.credential_ref = reference[0..32].*;
        try content.setCurseForgePolicy(cf_policy);
    }
    if (try synchronizeGameLifecycle()) {
        try window.checkNativeDisplay();
        return .close;
    }
    launcher.setLaunchAllowed(policy.canLaunch());
    if (pack_import_ui.takeReviewRequest()) {
        model.panel = .content;
        content_ui.requestReview(content.snapshot());
    }
    try view.draw(&model, &library, &java, &java_ui, &launcher, .{
        .pack_import = &pack_import,
        .pack_import_ui = &pack_import_ui,
        .allow_mutations = policy.shutdown == .none,
        .configuration = &configuration,
        .tasks = &tasks,
        .settings = &settings_ui,
        .cf_credentials = if (cf_credentials) |*controller| controller else null,
        .cf_credentials_failure = cf_credentials_failure,
        .java_download = &java_download,
        .java_download_ui = &java_download_ui,
        .servers = &servers,
        .servers_ui = &servers_ui,
        .logs = &logs_ui,
        .worlds = &world_manager,
        .worlds_ui = &worlds_ui,
        .accounts = &accounts,
        .accounts_ui = &accounts_ui,
        .instances = &instance_manager,
        .instances_ui = &instances_ui,
        .content = &content,
        .content_ui = &content_ui,
    });
    const phase = library.snapshot().phase;
    const launch_phase = launcher.snapshot().phase;
    if (try synchronizeGameLifecycle()) {
        try window.checkNativeDisplay();
        return .close;
    }
    const active = activeBackgroundCount();
    if (window.takeCloseRequested()) {
        if (try applyWindowActions(policy.closeRequested(active))) {
            try window.checkNativeDisplay();
            return .close;
        }
    }
    var shutdown_layout: shutdown_view.Layout = .{};
    if (policy.shutdown == .prompt) {
        if (shutdown_view.drawWithLayout(active, &shutdown_layout)) |choice| {
            if (acceptance_enabled) acceptance.observeChoice(choice);
            if (try applyWindowActions(policy.chooseClose(choice, active))) {
                try window.checkNativeDisplay();
                return .close;
            }
        }
    }
    if (policy.shutdown == .canceling and active == 0) {
        if (try applyWindowActions(policy.backgroundJoined())) {
            try window.checkNativeDisplay();
            return .close;
        }
    }
    if (try applyWindowActions(policy.backgroundChanged(active))) {
        try window.checkNativeDisplay();
        return .close;
    }
    dvui.currentWindow().backend.impl.log_events = false;
    if (phase == .loading or phase == .installing or java.isSearching() or java_download.isBusy() or servers.isBusy() or world_manager.snapshot().worker_active or accounts.snapshot().busy or instance_manager.isBusy() or content.isBusy() or cfCredentialsBusy() or view.packWorkflowPinned(&pack_import) or pack_import_ui.isBusy() or launch_phase == .preparing or launch_phase == .running or policy.shutdown != .none) dvui.refresh(null, @src(), null);
    if (acceptance_enabled and !tasks.hasActive()) tasks.pruneFinished(0);
    if (acceptance_enabled) try acceptance.afterFrame(.{
        .startup_idle = model.panel == .home and active == 0 and tasks.tasks().len == 0 and phase == .complete and !java.isSearching() and !java_download.isBusy() and !servers.isBusy() and !world_manager.snapshot().worker_active and world_manager.snapshot().instance != null and world_manager.snapshot().failure == null and !accounts.snapshot().busy and !instance_manager.isBusy() and !content.isBusy() and content.selected != null and content.snapshot().failure == null and !cfCredentialsBusy() and !view.packWorkflowPinned(&pack_import) and !pack_import_ui.isBusy(),
        .game = launcher.snapshot(),
        .world = world_manager.snapshot(),
        .accounts = accounts.snapshot(),
        .task_count = tasks.tasks().len,
        .active_background = active,
        .policy = &policy,
        .window = &window,
        .panel = @tagName(model.panel),
        .shutdown_layout = shutdown_layout,
    });
    try window.checkNativeDisplay();
    return .ok;
}

fn checkJavaForCreation(_: ?*anyopaque) !void {
    if (java_download.isDeleting()) return error.JavaDeleteBusy;
}

fn checkOwnedJavaDeletion(_: ?*anyopaque) !void {
    const phase = launcher.snapshot().phase;
    if (phase == .preparing or phase == .running or instance_manager.isBusy() or view.packWorkflowPinned(&pack_import)) return error.JavaInUse;
}

fn reserveLaunch(_: ?*anyopaque, instance_name: []const u8) !void {
    try checkJavaForCreation(null);
    leases.tick();
    const instance = instance_paths.findByName(configuration.snapshot(), instance_name) orelse return error.InstanceNotConfigured;
    try leases.reserveLaunch(instance.id);
}

fn releaseLaunch(_: ?*anyopaque) void {
    leases.releaseLaunch();
}

fn synchronizeGameLifecycle() !bool {
    const snapshot = launcher.snapshot();
    if (snapshot.attempt_id != 0 and snapshot.attempt_id != observed_attempt) {
        observed_attempt = snapshot.attempt_id;
        const options: lifecycle.Options = .{
            .debug_launch = snapshot.debug,
            .after_game = switch (configuration.snapshot().settings.game_exit_behavior) {
                .restore_launcher => .restore_launcher,
                .exit_launcher => .exit_launcher,
            },
        };
        if (try applyWindowActions(policy.launchStarted(options))) return true;
    }
    if (launcher.takeEndEvent()) |event| {
        const reason: lifecycle.EndReason = switch (event.reason) {
            .exited => |code| .{ .exited = code },
            .stopped => .stopped,
            .failed => .failed,
            .terminated => .terminated,
        };
        return applyWindowActions(policy.gameEnded(reason, activeBackgroundCount()));
    }
    if (snapshot.phase == .running) return applyWindowActions(policy.gameRunning());
    return false;
}

fn activeBackgroundCount() usize {
    var count: usize = 0;
    for (tasks.tasks()) |task| {
        switch (task.state) {
            .queued, .running, .canceling => count += 1,
            else => {},
        }
    }
    if (library.snapshot().phase == .loading) count += 1;
    if (java.isSearching()) count += 1;
    // Owned deletion has no registry task and remains owned until tick joins it.
    if (java_download.isDeleting()) count += 1;
    if (servers.isBusy()) count += 1;
    if (world_manager.snapshot().worker_active and world_manager.snapshot().loading) count += 1;
    if (accounts.snapshot().busy) count += 1;
    if (view.packWorkflowPinned(&pack_import)) count += 1;
    if (pack_import_ui.isBusy()) count += 1;
    return count;
}

fn applyWindowActions(actions: lifecycle.Actions) !bool {
    if (acceptance_enabled) acceptance.observeActions(actions);
    if (actions.hide) window.hide() catch |err| {
        std.log.warn("Cannot hide launcher window: {s}", .{@errorName(err)});
    };
    if (actions.restore) window.restoreAndFocus() catch |err| {
        std.log.warn("Cannot restore launcher window: {s}", .{@errorName(err)});
    };
    if (actions.show_logs) model.panel = .logs;
    if (actions.cancel_background) {
        pack_import.cancel(packServices());
        pack_import_ui.cancel();
        for (tasks.tasks()) |task| _ = tasks.cancel(task.id);
        library.cancel();
        java.cancelSearch();
        java_download.cancel();
        servers.cancel();
        world_manager.cancel();
        accounts.cancel();
        instance_manager.cancel();
        content.cancel();
        if (cf_credentials) |*controller| controller.cancel();
    }
    return actions.quit;
}

test {
    _ = @import("core/root.zig");
    _ = state;
    _ = game_library;
    _ = @import("ui/tools_view.zig");
    _ = java_manager;
    _ = java_view;
    _ = game_launch;
    _ = config;
    _ = instance_paths;
    _ = task_registry;
    _ = window_control;
    _ = lifecycle;
    _ = shutdown_view;
    _ = @import("core/java_download.zig");
    _ = @import("core/java_download_tests.zig");
    _ = @import("core/java_download_service_tests.zig");
    _ = @import("ui/tasks_view.zig");
    _ = @import("ui/settings_view.zig");
    _ = java_download_controller;
    _ = java_download_view;
    _ = server_manager;
    _ = servers_view;
    _ = logs_view;
    _ = instance_leases;
    _ = accounts_manager;
    _ = accounts_view;
    _ = instances_manager;
    _ = instances_view;
    _ = content_manager;
    _ = content_view;
    _ = pack_import_controller;
    _ = pack_import_view;
    _ = worlds;
    _ = worlds_manager;
    _ = worlds_view;
}

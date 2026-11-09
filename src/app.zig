const std = @import("std");
const dvui = @import("dvui");
const state = @import("ui/model.zig");
const view = @import("ui/view.zig");
const theme = @import("ui/theme.zig");
const fonts = @import("ui/fonts.zig");
const game_library = @import("application/game_library.zig");
const java_manager = @import("application/java_manager.zig");
const java_view = @import("ui/java_view.zig");
const file_picker = @import("ui/file_picker.zig");
const file_picker_sdl = @import("ui/file_picker_sdl.zig");
const components = @import("ui/components.zig");
const game_launch = @import("application/game_launch.zig");
const config = @import("core/config.zig");
const instance_paths = @import("core/instances.zig");
const task_registry = @import("core/tasks.zig");
const window_control = @import("ui/window_control.zig");
const lifecycle = @import("core/lifecycle.zig");
const shutdown_view = @import("ui/shutdown_view.zig");
const settings_view = @import("ui/settings_view.zig");
const appearance_view = @import("ui/appearance_view.zig");
const java_download_controller = @import("application/java_download_controller.zig");
const java_download_view = @import("ui/java_download_view.zig");
const server_manager = @import("application/server_manager.zig");
const servers_view = @import("ui/servers_view.zig");
const logs_view = @import("ui/logs_view.zig");
const worlds = @import("core/worlds.zig");
const instance_leases = @import("core/instance_leases.zig");
const avatar_manager = @import("ui/avatar_manager.zig");
const accounts_manager = @import("application/accounts_manager.zig");
const accounts_view = @import("ui/accounts_view.zig");
const instances_manager = @import("application/instances_manager.zig");
const instances_view = @import("ui/instances_view.zig");
const content_manager = @import("application/content_manager.zig");
const mods_controller = @import("application/mods_controller.zig");
const mods_view = @import("ui/mods_view.zig");
const instance_creation_controller = @import("application/instance_creation_controller.zig");
const cf_credentials_controller = @import("application/curseforge_credentials_controller.zig");
const worlds_manager = @import("application/worlds_manager.zig");
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
const diagnostic_log = @import("core/diagnostic_log.zig");
pub const std_options: std.Options = .{ .logFn = logFn, .log_level = .info };

fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    diagnostic_log.write(level, scope, format, args);
    dvui.App.logFn(level, scope, format, args);
}

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
var download_budget: @import("core/downloader.zig").Budget = undefined;
var library_initialized = false;
var java: java_manager.Manager = undefined;
var java_ui: java_view.Ui = undefined;
var picker: file_picker.Service = undefined;
var picker_quit_requested = false;
var launcher: game_launch.Controller = undefined;
var paths: instance_paths.Paths = undefined;
var configuration: config.Store = undefined;
var settings_ui: settings_view.Ui = undefined;
var proxy_settings: @import("application/proxy_settings_controller.zig").Controller = undefined;
var appearance_ui: appearance_view.Ui = undefined;
var java_download: java_download_controller.Controller = undefined;
var java_download_ui: java_download_view.Ui = undefined;
var servers: server_manager.Manager = undefined;
var servers_ui: servers_view.Ui = undefined;
var logs_ui: logs_view.View = .{};
var world_manager: worlds_manager.Manager = undefined;
var worlds_ui: worlds_view.Ui = undefined;
var observed_attempt: u64 = 0;
var leases: instance_leases.Coordinator = undefined;
var avatars: avatar_manager.Manager = undefined;
var accounts: accounts_manager.Manager = undefined;
var accounts_ui: accounts_view.Ui = undefined;
var instance_manager: instances_manager.Manager = undefined;
var instances_ui: instances_view.Ui = undefined;
var content: content_manager.Manager = undefined;
var mods: mods_controller.Controller = undefined;
var mods_ui: mods_view.Ui = undefined;
var ordinary_creation: instance_creation_controller.Controller = undefined;
var packs: @import("ui/pack_page.zig").Page = undefined;
var fatal_frame_error: ?anyerror = null;
var cf_credentials: ?cf_credentials_controller.Controller = null;
var cf_credentials_failure: ?anyerror = null;
var tasks: task_registry.Registry = undefined;
var window: window_control.Control = .{};
var policy: lifecycle.Policy = .{};
var shutdown_summary: @import("core/shutdown.zig").Summary = .{};
var shutdown_waiting_picker: bool = false;
var observed_instances: u64 = 0;

fn creationServices() instance_creation_controller.Services {
    return .{ .store = &configuration, .java = &java, .java_download = &java_download, .instances = &instance_manager };
}

fn runtime() @import("application/runtime.zig").Runtime {
    return .{
        .store = &configuration,
        .tasks = &tasks,
        .library = &library,
        .java = &java,
        .java_download = &java_download,
        .launcher = &launcher,
        .leases = &leases,
        .servers = &servers,
        .worlds = &world_manager,
        .accounts = &accounts,
        .instances = &instance_manager,
        .content = &content,
        .mods = &mods,
        .credentials = if (cf_credentials) |*controller| controller else null,
        .proxy_settings = &proxy_settings,
        .ordinary_creation = &ordinary_creation,
        .pack_creation = &packs.installer,
        .pack_catalog = &packs.browser,
    };
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

fn launcherDataRoot(args: []const [:0]const u8, environment_root: ?[]const u8) !?[]const u8 {
    var explicit_root: ?[]const u8 = null;
    var default_root: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) break;
        const destination: *?[]const u8 = if (std.mem.eql(u8, arg, "--data-dir"))
            &explicit_root
        else if (std.mem.eql(u8, arg, "--default-data-dir"))
            &default_root
        else
            continue;
        index += 1;
        if (index == args.len or args[index].len == 0) return error.MissingLauncherDataDirectory;
        destination.* = args[index];
    }
    return explicit_root orelse environment_root orelse default_root;
}

test "launcher data root follows current runtime environment" {
    const args = &.{ "vela", "--default-data-dir", "." };
    try std.testing.expectEqualStrings("environment-a", (try launcherDataRoot(args, "environment-a")).?);
    try std.testing.expectEqualStrings("environment-b", (try launcherDataRoot(args, "environment-b")).?);
    try std.testing.expectEqualStrings(".", (try launcherDataRoot(args, null)).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try launcherDataRoot(&.{"vela"}, null));
}

test "launcher data root explicit argument overrides environment and development default" {
    const args = &.{ "vela", "--default-data-dir", ".", "--data-dir", "实例 directory" };
    try std.testing.expectEqualStrings("实例 directory", (try launcherDataRoot(args, "environment-root")).?);
    try std.testing.expectEqualStrings("environment-root", (try launcherDataRoot(&.{ "vela", "--", "--data-dir", "ignored" }, "environment-root")).?);
}

test "launcher data root rejects missing and empty directory arguments" {
    try std.testing.expectError(error.MissingLauncherDataDirectory, launcherDataRoot(&.{ "vela", "--data-dir" }, null));
    try std.testing.expectError(error.MissingLauncherDataDirectory, launcherDataRoot(&.{ "vela", "--default-data-dir", "" }, null));
}

fn prepareRootStore(a: std.mem.Allocator, io: std.Io, root: []const u8) !config.Store {
    try std.Io.Dir.cwd().createDirPath(io, root);
    return config.Store.init(a, io, root);
}

test "fresh launcher root is created before acquiring its configuration writer" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const parent = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(parent);
    const root = try std.fs.path.join(a, &.{ parent, "fresh-launcher-root" });
    defer a.free(root);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, root, .{}));
    var store = try prepareRootStore(a, io, root);
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, 0), store.snapshot().instances.len);
    try std.testing.expectError(error.LauncherRootInUse, prepareRootStore(a, io, root));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "fresh-launcher-root/.vela/config.json", .{}));
}

pub fn init(win: *dvui.Window) !void {
    if (native_backend_configuration_error) |err| return err;
    win.backend.impl.log_events = false;
    model = .{ .versions = &.{}, .selected_version = 0 };
    policy = .{};
    logs_ui = .{};
    observed_attempt = 0;
    const main_init = dvui.App.main_init orelse return error.MissingAppInit;
    picker = file_picker.Service.init(main_init.gpa);
    picker_quit_requested = false;
    fatal_frame_error = null;
    errdefer picker.deinit();
    if (acceptance_enabled) try acceptance.validate(main_init.gpa, main_init.io, main_init.environ_map);
    errdefer if (acceptance_enabled) acceptance.destroy();
    leases = instance_leases.Coordinator.init(main_init.io);
    _ = leases.mutation(0);
    const startup_args = try main_init.minimal.args.toSlice(main_init.arena.allocator());
    const base = if (try launcherDataRoot(startup_args, main_init.environ_map.get("VELA_DATA_DIR"))) |override|
        try main_init.gpa.dupe(u8, override)
    else
        try std.process.executableDirPathAlloc(main_init.io, main_init.gpa);
    defer main_init.gpa.free(base);
    paths = try instance_paths.Paths.init(main_init.gpa, main_init.io, base);
    errdefer paths.deinit();
    configuration = prepareRootStore(main_init.gpa, main_init.io, paths.root) catch |err| {
        if (err == error.LauncherRootInUse) std.log.err("此启动器目录正被另一进程使用", .{});
        return err;
    };
    errdefer configuration.deinit();
    diagnostic_log.start(main_init.io, paths.root) catch |err| {
        std.log.warn("Cannot initialize launcher diagnostic log: {s}", .{@errorName(err)});
    };
    errdefer {
        diagnostic_log.write(.err, .launcher, "initialization failed", .{});
        diagnostic_log.stop();
    }
    diagnostic_log.write(.info, .launcher, "startup platform={s}/{s} mode={s}", .{ @tagName(@import("builtin").os.tag), @tagName(@import("builtin").cpu.arch), @tagName(@import("builtin").mode) });
    try @import("core/proxy_policy.zig").setDefault(main_init.io, configuration.snapshot().settings.proxy, main_init.environ_map);
    errdefer @import("core/proxy_policy.zig").clearDefault(main_init.io);
    download_budget = try @import("core/downloader.zig").Budget.init(main_init.io, configuration.snapshot().settings.download_connections);
    errdefer download_budget.deinit();
    if (acceptance_enabled) try acceptance.validateProfile(configuration.snapshot());
    if (@import("builtin").os.tag == .windows) try configuration.prepareStorage();
    observed_instances = instanceFingerprint(configuration.snapshot());
    settings_ui = try settings_view.Ui.init(main_init.gpa, configuration.snapshot().settings);
    errdefer settings_ui.deinit();
    proxy_settings = try @import("application/proxy_settings_controller.zig").Controller.init(main_init.gpa, main_init.io, .{ .environ = main_init.environ_map });
    errdefer proxy_settings.deinit();
    settings_ui.proxy_controller = &proxy_settings;
    appearance_ui = try appearance_view.Ui.init(main_init.gpa, main_init.io, configuration.snapshot().appearance);
    errdefer appearance_ui.deinit();
    appearance_ui.picker = &picker;
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
    avatars = try avatar_manager.Manager.init(main_init.gpa, main_init.io, paths.cache, .{}, !acceptance_enabled);
    errdefer avatars.deinit();
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
        .download_budget = &download_budget,
        .root = paths.minecraft,
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
    java_ui.picker_service = &picker;
    errdefer java_ui.deinit();
    var java_options: java_download_controller.Options = if (acceptance_enabled) acceptance.javaOptions(paths.root, &tasks, &download_budget) else .{ .root = paths.root, .task_registry = &tasks, .download_budget = &download_budget };
    java_options.download_budget = &download_budget;
    java_options.cache_root = if (acceptance_enabled) null else paths.cache;
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
    world_manager = if (acceptance_enabled) try worlds_manager.Manager.initOptions(main_init.gpa, main_init.io, &paths, &tasks, .{ .scope = leases.worldScope(3), .scan_scope = leases.worldReadScope(3), .worker = acceptance.worldWorker }) else try worlds_manager.Manager.initOptions(main_init.gpa, main_init.io, &paths, &tasks, .{ .scope = leases.worldScope(3), .scan_scope = leases.worldReadScope(3) });
    errdefer world_manager.deinit();
    worlds_ui = try worlds_view.Ui.init(main_init.gpa);
    errdefer worlds_ui.deinit();
    accounts = if (acceptance_enabled) try accounts_manager.Manager.initWithOptions(main_init.gpa, main_init.io, acceptance.accountOptions(paths.root)) else try accounts_manager.Manager.init(main_init.gpa, main_init.io, paths.root);
    errdefer accounts.deinit();
    accounts_ui = try accounts_view.Ui.init(main_init.gpa);
    errdefer accounts_ui.deinit();
    accounts.tick(&configuration);
    const instance_mutation = leases.mutation(2);
    instance_manager = try instances_manager.Manager.initWithOptions(main_init.gpa, main_init.io, &paths, &tasks, leases.guard(instance_mutation), .{ .context = instance_mutation, .acquire = instance_leases.Mutation.acquireCallback, .recheck = instance_leases.Mutation.recheckCallback, .release = instance_leases.Mutation.releaseCallback }, .{ .cache_root = paths.cache, .download_budget = &download_budget });
    errdefer instance_manager.deinit();
    try instance_manager.recoverRenames(&configuration);
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
        .transport_options = .{ .allow_curseforge = true, .download_budget = &download_budget, .cache_root = paths.cache },
        .allow_curseforge_remote = true,
    };
    content = try content_manager.Manager.initOptions(main_init.gpa, main_init.io, &paths, &tasks, if (acceptance_enabled) acceptance.contentOptions(content_options) else content_options);
    errdefer content.deinit();
    mods = mods_controller.Controller.init(main_init.gpa, main_init.io, &paths);
    errdefer mods.deinit();
    mods_ui = try mods_view.Ui.init(main_init.gpa);
    errdefer mods_ui.deinit();
    mods_ui.acquisition.picker = &picker;
    ordinary_creation = try instance_creation_controller.Controller.init(main_init.gpa, main_init.io, paths.root, .{ .task_registry = &tasks });
    errdefer ordinary_creation.deinit(creationServices());
    packs = try @import("ui/pack_page.zig").Page.init(main_init.gpa, main_init.io, &paths, &tasks, &download_budget);
    errdefer packs.deinit(creationServices());
    packs.ui.picker_service = &picker;
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
        packs.deinit(creationServices());
        ordinary_creation.deinit(creationServices());
        window.deinit();
        launcher.deinit();
        mods.deinit();
        mods_ui.deinit();
        content.deinit();
        instances_ui.deinit();
        instance_manager.deinit();
        world_manager.deinit();
        if (acceptance_enabled) acceptance.worldJoined();
        worlds_ui.deinit();
        java_download.deinit();
        java_download_ui.deinit();
        avatars.deinit();
        servers.deinit();
        servers_ui.deinit();
        accounts_ui.deinit();
        accounts.deinit();
        if (acceptance_enabled) acceptance.accountsJoined();
        if (cf_credentials) |*controller| controller.deinit();
        cf_credentials = null;
        appearance_ui.deinit();
        proxy_settings.deinit();
        settings_ui.deinit();
        java_ui.deinit();
        picker.deinit();
        java.deinit();
        library.deinit();
        download_budget.deinit();
        tasks.deinit();
        @import("core/proxy_policy.zig").clearDefault((dvui.App.main_init orelse unreachable).io);
        diagnostic_log.write(.info, .launcher, "shutdown workers_joined=true", .{});
        diagnostic_log.stop();
        configuration.deinit();
        paths.deinit();
        library_initialized = false;
        if (acceptance_enabled) acceptance.destroy();
    }
}

fn drainFrameFailure(service: *file_picker.Service, failure: *?anyerror, err: anyerror) !dvui.App.Result {
    if (failure.* == null) failure.* = err;
    service.beginShutdown();
    if (service.isDrained()) return failure.*.?;
    return .ok;
}

pub fn frame() !dvui.App.Result {
    if (fatal_frame_error) |err| {
        const result = try drainFrameFailure(&picker, &fatal_frame_error, err);
        file_picker_sdl.pump(&picker, dvui.currentWindow());
        return result;
    }
    return frameActive() catch |err| {
        diagnostic_log.write(.err, .launcher, "frame failed error={s}", .{@errorName(err)});
        _ = applyWindowActions(.{ .cancel_background = true }) catch {};
        const result = try drainFrameFailure(&picker, &fatal_frame_error, err);
        file_picker_sdl.pump(&picker, dvui.currentWindow());
        return result;
    };
}

test "fatal frame failure waits for native picker callback then returns original error" {
    const HeldDriver = struct {
        pending: ?*file_picker.Pending = null,
        fn start(context: ?*anyopaque, pending: *file_picker.Pending) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.pending = pending;
        }
    };
    var service = file_picker.Service.init(std.testing.allocator);
    defer service.deinit();
    var failure: ?anyerror = null;
    const ticket = try service.request(.{ .kind = .file });
    var driver: HeldDriver = .{};
    service.startPending(.{ .context = &driver, .start = HeldDriver.start });
    try std.testing.expectEqual(dvui.App.Result.ok, try drainFrameFailure(&service, &failure, error.NativeDisplayFailed));
    try std.testing.expectError(error.ShuttingDown, service.request(.{ .kind = .folder }));
    try std.testing.expectEqual(dvui.App.Result.ok, try drainFrameFailure(&service, &failure, error.LaterFailure));
    driver.pending.?.complete(.{ .path = "/late/result" });
    try std.testing.expectError(error.NativeDisplayFailed, drainFrameFailure(&service, &failure, error.LaterFailure));
    try std.testing.expect(service.isDrained() and service.take(ticket) == null);
}

fn frameActive() !dvui.App.Result {
    try window.checkNativeDisplay();
    dvui.currentWindow().backend.impl.log_events = false;
    file_picker_sdl.pump(&picker, dvui.currentWindow());
    if (picker_quit_requested) {
        if (picker.isDrained()) return .close;
        components.title(@src(), "正在退出启动器");
        components.hint(@src(), "请先关闭系统文件选择窗口，启动器将在随后退出。");
        dvui.timer(dvui.parentGet().data().id.update("file-picker-exit-poll"), 50_000);
        return .ok;
    }
    if (acceptance_enabled) try acceptance.beforeFrame(&launcher, &world_manager, &configuration, &paths);
    if (policy.shutdown == .none) packs.syncActive(model.panel == .instances and instances_ui.mode == .packs, creationServices());
    const main_init = dvui.App.main_init orelse return error.MissingAppInit;
    runtime().tick(policy.shutdown != .canceling);
    if (policy.shutdown == .prompt) runtime().finishAccepted();
    try @import("core/proxy_policy.zig").setDefault(main_init.io, configuration.snapshot().settings.proxy, main_init.environ_map);
    avatars.tick();
    if (policy.shutdown == .canceling) {
        finishSettingsForExit();
        runtime().finishShutdown();
        packs.tickPresentation(creationServices(), false);
        if (shutdown_waiting_picker) {
            if (picker.isDrained()) {
                shutdown_waiting_picker = false;
                try window.hide();
            } else {
                try window.showForPrompt();
                components.title(@src(), "正在退出启动器");
                components.hint(@src(), "请先关闭系统文件选择窗口，其他任务正在安全收尾。");
            }
        }
        const remaining = activeBackgroundCount();
        if (acceptance_enabled) try observeLifecycleFrame(remaining, .{});
        if (remaining == 0 and try applyWindowActions(policy.backgroundJoined())) return .close;
        // Keep pumping completions while hidden, without rebuilding pages or dispatching intents.
        dvui.timer(dvui.parentGet().data().id.update("shutdown-drain"), 50_000);
        return .ok;
    }
    if (policy.shutdown == .none) {
        if (!acceptance_enabled and model.panel == .instances and instances_ui.mode == .create and !instances_ui.submitted) {
            if (instances_ui.draft.base) |base| {
                library.previewVersion(base) catch |err| {
                    instances_ui.failure = err;
                };
            } else library.cancelPreview();
        } else library.cancelPreview();
    }
    packs.tickPresentation(creationServices(), policy.shutdown == .none);
    const fingerprint = instanceFingerprint(configuration.snapshot());
    const library_phase = library.snapshot().phase;
    if (policy.shutdown == .none and fingerprint != observed_instances and library_phase != .loading) {
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
    try download_budget.setLimit(configuration.snapshot().settings.download_connections);
    try library.setDownloadConnections(configuration.snapshot().settings.download_connections);
    if (!ordinary_creation.ownership().merge(packs.installer.ownership()).pinned) {
        try java_download.setDownloadConnections(configuration.snapshot().settings.download_connections);
        instance_manager.setDownloadConnections(configuration.snapshot().settings.download_connections);
        try content.setDownloadConnections(configuration.snapshot().settings.download_connections);
    }
    if (!ordinary_creation.ownership().merge(packs.installer.ownership()).pinned and !content.isBusy() and !content.snapshot().recovery_required) {
        const settings = configuration.snapshot().settings;
        var cf_policy: content_manager.CurseForgePolicy = .{
            .enabled = settings.curseforge_enabled and !configuration.publicationUncertain() and cf_credentials != null and !cfCredentialsLease(),
            .terms_approved = settings.curseforge_terms_approved,
        };
        if (settings.curseforge_credential_ref) |reference| cf_policy.credential_ref = reference[0..32].*;
        try content.setCurseForgePolicy(cf_policy);
        try packs.configure(.{ .enabled = cf_policy.enabled, .terms_approved = cf_policy.terms_approved, .credential_ref = cf_policy.credential_ref }, settings.download_connections);
    }
    const closing_operations = runtime().shutdownSummary();
    policy.confirm_operations = closing_operations.any();
    if (policy.shutdown != .prompt) shutdown_summary = closing_operations;
    if (try synchronizeGameLifecycle()) {
        try window.checkNativeDisplay();
        return .close;
    }
    launcher.setLaunchAllowed(policy.canLaunch());
    avatars.sync(configuration.snapshot(), policy.shutdown == .none) catch {};
    try view.draw(&model, &library, &java, &java_ui, &launcher, .{
        .ordinary_creation = &ordinary_creation,
        .packs = &packs,
        .allow_mutations = policy.shutdown == .none,
        .configuration = &configuration,
        .tasks = &tasks,
        .settings = &settings_ui,
        .appearance = &appearance_ui,
        .cf_credentials = if (cf_credentials) |*controller| controller else null,
        .cf_credentials_failure = cf_credentials_failure,
        .java_download = &java_download,
        .java_download_ui = &java_download_ui,
        .servers = &servers,
        .servers_ui = &servers_ui,
        .logs = &logs_ui,
        .worlds = &world_manager,
        .worlds_ui = &worlds_ui,
        .avatars = &avatars,
        .accounts = &accounts,
        .accounts_ui = &accounts_ui,
        .instances = &instance_manager,
        .instances_ui = &instances_ui,
        .content = &content,
        .mods = &mods,
        .mods_ui = &mods_ui,
    });
    const launch_phase = launcher.snapshot().phase;
    if (try synchronizeGameLifecycle()) {
        try window.checkNativeDisplay();
        return .close;
    }
    const active = activeBackgroundCount();
    if (policy.shutdown == .none) {
        shutdown_summary = runtime().shutdownSummary();
        policy.confirm_operations = shutdown_summary.any();
    }
    var close_ready = appearance_view.takeClose(&appearance_ui);
    if (window.takeCloseRequested()) close_ready = appearance_view.guardClose(&appearance_ui);
    if (close_ready) {
        if (try applyWindowActions(policy.closeRequested(active))) {
            try window.checkNativeDisplay();
            return .close;
        }
    }
    var shutdown_layout: shutdown_view.Layout = .{};
    if (policy.shutdown == .prompt) {
        if (shutdown_view.drawWithLayout(shutdown_summary, &shutdown_layout)) |choice| {
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
    dvui.currentWindow().backend.impl.log_events = false;
    if (activeBackgroundCount() != 0 or launch_phase == .preparing or launch_phase == .running or policy.shutdown != .none) dvui.refresh(null, @src(), null);
    if (acceptance_enabled and !tasks.hasActive()) tasks.pruneFinished(0);
    if (acceptance_enabled) try observeLifecycleFrame(active, shutdown_layout);
    try window.checkNativeDisplay();
    return .ok;
}

fn observeLifecycleFrame(active: usize, shutdown_layout: shutdown_view.Layout) !void {
    try acceptance.afterFrame(.{
        .startup_idle = model.panel == .home and active == 0 and tasks.tasks().len == 0 and library.snapshot().phase == .complete and !java.isSearching() and !java_download.isBusy() and !servers.isBusy() and !world_manager.snapshot().worker_active and world_manager.snapshot().failure == null and !accounts.snapshot().busy and !instance_manager.isBusy() and !content.isBusy() and content.snapshot().failure == null and !cfCredentialsBusy() and !ordinary_creation.ownership().pinned,
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
}

fn checkJavaForCreation(_: ?*anyopaque) !void {
    if (java_download.isDeleting()) return error.JavaDeleteBusy;
}

fn checkOwnedJavaDeletion(_: ?*anyopaque) !void {
    const phase = launcher.snapshot().phase;
    if (phase == .preparing or phase == .running or instance_manager.isBusy() or ordinary_creation.ownership().merge(packs.installer.ownership()).pinned) return error.JavaInUse;
}

fn reserveLaunch(_: ?*anyopaque, instance_name: []const u8) !void {
    try checkJavaForCreation(null);
    if (ordinary_creation.ownership().merge(packs.installer.ownership()).pinned) return error.InstanceBusy;
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
    var count = runtime().activeCount();
    if (packs.presentationBusy()) count += 1;
    if (avatars.isBusy()) count += 1;
    if (picker.isBusy()) count += 1;
    return count;
}

fn finishSettingsForExit() void {
    settings_ui.flush();
    if (cf_credentials) |*controller| {
        settings_view.finishWithCredentials(&settings_ui, &configuration, controller, content.isBusy());
    } else settings_view.finishUnavailable(&settings_ui, &configuration);
    settings_ui.clearSecrets();
}

fn applyWindowActions(actions: lifecycle.Actions) !bool {
    if (actions.hide or actions.quit or actions.cancel_background) {
        finishSettingsForExit();
        // A flushed proxy edit may have started a worker after the close decision.
        if (actions.quit and activeBackgroundCount() != 0) return applyWindowActions(policy.closeRequested(activeBackgroundCount()));
    }
    if (acceptance_enabled) acceptance.observeActions(actions);
    if (actions.show_home) model.panel = .home;
    if (actions.show_logs) model.panel = .logs;
    if (actions.cancel_background) shutdown_waiting_picker = picker.isBusy();
    if (actions.hide and !shutdown_waiting_picker) window.hide() catch |err| {
        std.log.warn("Cannot hide launcher window: {s}", .{@errorName(err)});
    };
    if (actions.restore) window.restoreAndFocus() catch |err| {
        std.log.warn("Cannot restore launcher window: {s}", .{@errorName(err)});
    };
    if (actions.prompt_background) window.showForPrompt() catch |err| {
        std.log.warn("Cannot show shutdown confirmation: {s}", .{@errorName(err)});
    };
    if (actions.cancel_background) {
        java_view.discardPicker(&java_ui);
        picker.beginShutdown();
        runtime().beginShutdown();
        packs.cancelPresentation();
        avatars.cancel();
    }
    if (actions.quit) {
        picker_quit_requested = true;
        picker.beginShutdown();
        return picker.isDrained();
    }
    return false;
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
    _ = appearance_view;
    _ = @import("ui/background_image.zig");
    _ = @import("core/appearance.zig");
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
    _ = instance_creation_controller;
    _ = worlds;
    _ = worlds_manager;
    _ = worlds_view;
}

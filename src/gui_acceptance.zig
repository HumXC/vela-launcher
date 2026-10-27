//! Isolated acceptance entry. Production App never imports this module.
const std = @import("std");
const dvui = @import("dvui");
const state = @import("ui/model.zig");
const view = @import("ui/view.zig");
const theme = @import("ui/theme.zig");
const fonts = @import("ui/fonts.zig");
const window_control = @import("ui/window_control.zig");
const file_picker = @import("ui/file_picker.zig");
const file_picker_sdl = @import("ui/file_picker_sdl.zig");
const config = @import("core/config.zig");
const instances = @import("core/instances.zig");
const tasks = @import("core/tasks.zig");
const servers_core = @import("core/servers.zig");
const java_backend = @import("core/java_download.zig");
const nbt = @import("nbt");
const compression = @import("nbt_compression");
const games = @import("ui/game_library.zig");
const logs = @import("core/logs.zig");
const java = @import("ui/java_manager.zig");
const java_view = @import("ui/java_view.zig");
const game_launch = @import("ui/game_launch.zig");
const settings_view = @import("ui/settings_view.zig");
const appearance_view = @import("ui/appearance_view.zig");
const java_download = @import("ui/java_download_controller.zig");
const java_download_view = @import("ui/java_download_view.zig");
const server_manager = @import("ui/server_manager.zig");
const servers_view = @import("ui/servers_view.zig");
const logs_view = @import("ui/logs_view.zig");
const worlds_manager = @import("ui/worlds_manager.zig");
const worlds_view = @import("ui/worlds_view.zig");
const instances_manager = @import("ui/instances_manager.zig");
const instances_view = @import("ui/instances_view.zig");
const content_manager = @import("ui/content_manager.zig");
const mods_controller = @import("ui/mods_controller.zig");
const mods_view = @import("ui/mods_view.zig");
const resource_fixture = @import("ui/resource_download_fixture.zig");
const resource_navigation = @import("ui/resource_navigation_fixture.zig");
const accounts_manager = @import("ui/accounts_manager.zig");
const accounts_view = @import("ui/accounts_view.zig");
const instance_leases = @import("core/instance_leases.zig");
const instance_tx = @import("core/instance_transactions.zig");
const content_install = @import("core/content_install.zig");
const http = @import("core/http_transport.zig");
const auth = @import("core/auth.zig");
const credentials = @import("core/credentials.zig");
const shutdown_view = @import("ui/shutdown_view.zig");
const creation_controller = @import("ui/instance_creation_controller.zig");
const instance_fixture = @import("gui_instance_fixture.zig");
fn javaProgressDetails(stage: tasks.Stage, known_total: bool) tasks.Details {
    const received = 10 * 1024 * 1024;
    const total: ?u64 = if (known_total) 100 * 1024 * 1024 else null;
    return .{ .stage = stage, .completed = received, .total = total, .received = received, .total_bytes = total, .bytes_per_second = 1.5 * 1024 * 1024 };
}

const TickCounts = struct {
    java: usize = 0,
    java_download: usize = 0,
    instances: usize = 0,
    creation_core: usize = 0,
    content: usize = 0,
};

pub const dvui_app: dvui.App = .{
    .config = .{ .startFn = fixtureStart },
    .initFn = init,
    .frameFn = frame,
    .deinitFn = deinit,
};
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

const Panel = enum { home, versions, more, settings, theme, java, servers, logs, worlds, instances, mods, @"mods-download", @"mods-download-scroll", @"mods-detail-slow", @"mods-detail", @"mods-detail-optional", @"mods-detail-loading", @"mods-confirm", @"mods-task", @"mods-task-complete", @"mods-task-failed", player, @"account-add", shutdown };
fn isResourcePreview(panel: Panel) bool {
    return switch (panel) {
        .@"mods-download", .@"mods-download-scroll", .@"mods-detail-slow", .@"mods-detail", .@"mods-detail-optional", .@"mods-detail-loading", .@"mods-confirm", .@"mods-task", .@"mods-task-complete", .@"mods-task-failed" => true,
        else => false,
    };
}
var fixture: ?*Fixture = null;

var native_backend_configuration_error: ?anyerror = null;

fn fixtureStart() dvui.App.StartOptions {
    native_backend_configuration_error = null;
    window_control.configureNativeBackend() catch |err| {
        native_backend_configuration_error = err;
    };
    return .{
        .size = .{ .w = 1280, .h = 720 },
        .min_size = .{ .w = 640, .h = 400 },
        .title = "Vela Acceptance Fixture",
        .vsync = false,
        .window_init_options = .{ .keybinds_zoom = true },
    };
}

// Share production decoration policy without installing its lifecycle controller.
fn configureFixtureFramePacing(win: *dvui.Window) !void {
    if (comptime @import("builtin").os.tag != .linux) return;
    const c = dvui.backend.c;
    const driver = c.SDL_GetCurrentVideoDriver();
    if (driver == null) return error.NativeVideoDriverUnavailable;
    if (!std.mem.eql(u8, std.mem.span(driver), "wayland")) return;
    const renderer = win.backend.impl.renderer;
    if (!c.SDL_SetRenderVSync(renderer, 0)) return error.NativeFramePacingConfigurationFailed;
    var render_vsync: c_int = -1;
    if (!c.SDL_GetRenderVSync(renderer, &render_vsync)) return error.NativeFramePacingQueryUnavailable;
    if (render_vsync != 0) return error.NativeFramePacingNotDisabled;
    const name = c.SDL_GetRendererName(renderer);
    if (name == null) return error.NativeRendererNameUnavailable;
    const renderer_name = std.mem.span(name);
    if (std.mem.eql(u8, renderer_name, "opengl") or
        std.mem.eql(u8, renderer_name, "opengles") or
        std.mem.eql(u8, renderer_name, "opengles2"))
    {
        var swap_interval: c_int = -1;
        if (!c.SDL_GL_GetSwapInterval(&swap_interval)) return error.NativeSwapIntervalQueryUnavailable;
        if (swap_interval != 0) return error.NativeSwapIntervalNotDisabled;
    }
    win.max_fps = win.max_fps orelse 60;
}

pub fn init(win: *dvui.Window) !void {
    if (native_backend_configuration_error) |err| return err;
    try configureFixtureFramePacing(win);
    const app = dvui.App.main_init orelse return error.MissingAppInit;
    const root = app.environ_map.get("VELA_FIXTURE_ROOT") orelse return error.MissingFixtureRoot;
    if (!std.fs.path.isAbsolute(root) or std.mem.indexOfScalar(u8, root, 0) != null)
        return error.InvalidFixtureRoot;
    var dir = try std.Io.Dir.cwd().openDir(app.io, root, .{});
    dir.close(app.io);
    const panel = std.meta.stringToEnum(Panel, app.environ_map.get("VELA_FIXTURE_PANEL") orelse "home") orelse
        return error.InvalidFixturePanel;
    const viewport = try parseViewport(app.environ_map.get("VELA_FIXTURE_VIEWPORT") orelse "1280x720");
    win.backend.impl.log_events = false;
    try fonts.install(win);
    theme.install(win);
    const scene = std.meta.stringToEnum(instance_fixture.Scene, app.environ_map.get("VELA_FIXTURE_SCENE") orelse "layout") orelse return error.InvalidFixtureScene;
    const hold = std.meta.stringToEnum(instance_fixture.Hold, app.environ_map.get("VELA_FIXTURE_INSTANCE_HOLD") orelse "none") orelse return error.InvalidFixtureHold;
    const owned = try Fixture.createScene(app.gpa, app.io, root, panel, viewport, scene);
    errdefer owned.destroy();
    const native_pickers = app.environ_map.get("VELA_FIXTURE_NATIVE_PICKERS") orelse "0";
    if (std.mem.eql(u8, native_pickers, "1")) {
        try owned.enableNativePickers(win);
    } else if (!std.mem.eql(u8, native_pickers, "0")) return error.InvalidFixtureNativePickers;
    try owned.armInstanceScene(hold);
    const logs_control = app.environ_map.get("VELA_FIXTURE_LOGS_CONTROL") orelse "0";
    if (std.mem.eql(u8, logs_control, "1")) {
        if (panel != .logs or scene != .layout) return error.InvalidFixtureLogsProfile;
        owned.logs_control = true;
        owned.launcher.attempt_id = 1;
    } else if (!std.mem.eql(u8, logs_control, "0")) return error.InvalidFixtureLogsControl;
    const java_progress = app.environ_map.get("VELA_FIXTURE_JAVA_PROGRESS") orelse "0";
    if (std.mem.eql(u8, java_progress, "1")) {
        if (panel != .java or scene != .layout or owned.native_pickers) return error.InvalidFixtureJavaProgressProfile;
        try owned.seedJavaProgress();
    } else if (!std.mem.eql(u8, java_progress, "0")) return error.InvalidFixtureJavaProgressProfile;
    fixture = owned;
}

pub fn deinit(_: *dvui.Window) void {
    if (fixture) |f| f.destroy();
    fixture = null;
}

pub fn frame() !dvui.App.Result {
    const f = fixture orelse return error.MissingFixture;
    const win = dvui.currentWindow();
    win.backend.impl.log_events = false;
    try f.pollLogsActions();
    try f.pollJavaProgressActions();
    if (f.native_pickers) {
        file_picker_sdl.pump(&f.picker, win);
        try f.pollNativePickerActions();
        const native_close = if (comptime dvui.backend.kind == .sdl3) f.native_window.takeCloseRequested() else false;
        if ((native_close or fixtureCloseRequested(dvui.events())) and appearance_view.guardClose(&f.appearance)) f.requestNativeClose();
        if (f.native_quit_requested) {
            if (f.picker.isDrained()) return .close;
            // Keep SDL/portal events pumping until the outstanding callback ends.
            win.timer(win.data().id.update("fixture.native-picker-exit"), 50_000);
            return .ok;
        }
    }
    try f.tickServices();
    if (!f.native_pickers and fixtureCloseRequested(dvui.events()) and appearance_view.guardClose(&f.appearance)) return .close;
    // Constrain window bounds without an open wrapper around deferred publication.
    const old_rect = win.data().rect;
    const old_pixels = win.rect_pixels;
    win.data().rect = .{ .x = 0, .y = 0, .w = f.viewport.w, .h = f.viewport.h };
    win.rect_pixels = .{ .x = 0, .y = 0, .w = f.viewport.w * win.natural_scale, .h = f.viewport.h * win.natural_scale };
    defer {
        win.data().rect = old_rect;
        win.rect_pixels = old_pixels;
    }
    const old_clip = dvui.clip(win.rect_pixels);
    defer dvui.clipSet(old_clip);
    try view.draw(&f.model, &f.library, &f.java_manager, &f.java_ui, &f.launcher, .{
        .ordinary_creation = &f.creation_core,
        .configuration = &f.configuration,
        .tasks = &f.registry,
        .task_viewport_height = f.viewport.h,
        .settings = &f.settings,
        .appearance = &f.appearance,
        .cf_credentials = &f.cf_credentials,
        .java_download = &f.java_download_controller,
        .java_download_ui = &f.java_download_ui,
        .servers = &f.servers,
        .servers_ui = &f.servers_ui,
        .logs = &f.logs_ui,
        .worlds = &f.worlds,
        .worlds_ui = &f.worlds_ui,
        .accounts = &f.accounts,
        .accounts_ui = &f.accounts_ui,
        .instances = &f.instance_manager,
        .instances_ui = &f.instances_ui,
        .content = &f.content,
        .mods = &f.mods,
        .mods_ui = &f.mods_ui,
    });
    if (appearance_view.takeClose(&f.appearance)) {
        if (f.native_pickers) f.requestNativeClose() else return .close;
    }
    try f.writeLogsReceipt();
    try f.writeResourceReceipt();
    if (f.shutdown_prompt) {
        if (shutdown_view.draw(activeFixtureTasks(&f.registry))) |choice| switch (choice) {
            .keep_open => f.shutdown_prompt = false,
            .wait => {
                if (!f.registry.hasActive()) f.shutdown_prompt = false;
            },
            .cancel_and_quit => {
                for (f.registry.tasks()) |task| if (task.id <= f.fixture_task_last_id) {
                    _ = f.registry.cancel(task.id);
                };
                f.cf_credentials.cancel();
                f.shutdown_prompt = false;
            },
        };
    }
    dvui.currentWindow().backend.impl.log_events = false;
    if (f.library.snapshot().phase == .loading or f.java_manager.isSearching() or f.java_download_controller.isBusy() or f.servers.isBusy() or f.worlds.snapshot().worker_active or f.accounts.snapshot().busy or f.instance_manager.isBusy() or f.content.isBusy() or f.creation_core.ownership().pinned or f.cf_credentials.isBusy() or f.shutdown_prompt)
        dvui.refresh(null, @src(), null);
    return .ok;
}

const cf_credentials_controller = @import("ui/curseforge_credentials_controller.zig");

const FixtureVault = struct {
    const Slot = struct {
        reference: ?credentials.Reference = null,
        bytes: [512]u8 = @splat(0),
        len: usize = 0,

        fn clear(slot: *Slot) void {
            std.crypto.secureZero(u8, &slot.bytes);
            slot.reference = null;
            slot.len = 0;
        }
    };

    slots: [4]Slot = @splat(.{}),

    fn store(vault: *FixtureVault) credentials.Store {
        return .{ .ctx = vault, .vtable = &.{ .put = put, .get = get, .delete = delete } };
    }

    fn deinit(vault: *FixtureVault) void {
        for (&vault.slots) |*slot| slot.clear();
    }

    fn find(vault: *FixtureVault, reference: []const u8) ?*Slot {
        for (&vault.slots) |*slot| if (slot.reference) |id| {
            if (std.mem.eql(u8, &id, reference)) return slot;
        };
        return null;
    }

    fn put(ctx: *anyopaque, reference: []const u8, bytes: []const u8) credentials.Error!void {
        const vault: *FixtureVault = @ptrCast(@alignCast(ctx));
        if (!credentials.validateReference(reference)) return error.InvalidReference;
        if (bytes.len == 0 or bytes.len > 512) return error.InvalidSecret;
        var target = vault.find(reference);
        if (target == null) for (&vault.slots) |*slot| {
            if (slot.reference == null) {
                target = slot;
                break;
            }
        };
        const slot = target orelse return error.StorageFailure;
        slot.clear();
        slot.reference = reference[0..32].*;
        @memcpy(slot.bytes[0..bytes.len], bytes);
        slot.len = bytes.len;
    }

    fn get(ctx: *anyopaque, a: std.mem.Allocator, reference: []const u8) credentials.Error!credentials.Secret {
        const vault: *FixtureVault = @ptrCast(@alignCast(ctx));
        if (!credentials.validateReference(reference)) return error.InvalidReference;
        const slot = vault.find(reference) orelse return error.NotFound;
        return .{ .allocator = a, .bytes = try a.dupe(u8, slot.bytes[0..slot.len]) };
    }

    fn delete(ctx: *anyopaque, reference: []const u8) credentials.Error!void {
        const vault: *FixtureVault = @ptrCast(@alignCast(ctx));
        if (!credentials.validateReference(reference)) return error.InvalidReference;
        const slot = vault.find(reference) orelse return error.NotFound;
        slot.clear();
    }
};

const Fixture = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    download_budget: @import("core/downloader.zig").Budget,
    viewport: dvui.Size,
    model: state.Model,
    paths: instances.Paths,
    configuration: config.Store,
    registry: tasks.Registry,
    library: games.Controller,
    java_manager: java.Manager,
    java_ui: java_view.Ui,
    launcher: game_launch.Controller,
    settings: settings_view.Ui,
    appearance: appearance_view.Ui,
    cf_vault: FixtureVault,
    cf_credentials: cf_credentials_controller.Controller,
    java_download_controller: java_download.Controller,
    java_download_ui: java_download_view.Ui,
    servers: server_manager.Manager,
    servers_ui: servers_view.Ui,
    logs_ui: logs_view.View,
    worlds: worlds_manager.Manager,
    worlds_ui: worlds_view.Ui,
    coordinator: instance_leases.Coordinator,
    instance_manager: instances_manager.Manager,
    instances_ui: instances_view.Ui,
    content: content_manager.Manager,
    mods: mods_controller.Controller,
    mods_ui: mods_view.Ui,
    resource_preview: Panel,
    resource_preview_step: u8 = 0,
    resource_http_scenario: resource_fixture.Scenario,
    resource_http_navigation: resource_navigation.Context,
    resource_metadata_gate: resource_navigation.Gate,
    scene: instance_fixture.Scene,
    instance_data: instance_fixture.Context,
    creation_core: creation_controller.Controller,
    ticks: TickCounts = .{},
    accounts: accounts_manager.Manager,
    accounts_ui: accounts_view.Ui,
    instance_fingerprint: u64,
    catalogue_seeded: bool = false,
    shutdown_prompt: bool,
    fixture_task_last_id: u64,
    native_pickers: bool,
    native_quit_requested: bool,
    native_window: if (dvui.backend.kind == .sdl3) window_control.Control else struct {},
    picker: file_picker.Service,
    logs_control: bool = false,
    logs_appends: u32 = 0,
    java_progress: bool = false,

    /// Actual Task/Job state feeding production snapshot and Java UI. No network
    /// request or archive installation occurs; this worker only permits real JOIN.
    fn seedJavaProgress(f: *Fixture) !void {
        const controller = &f.java_download_controller;
        if (controller.active != null or controller.published != null) return error.Busy;
        const job = try std.heap.page_allocator.create(@TypeOf(controller.active.?.*));
        errdefer std.heap.page_allocator.destroy(job);
        const task = try f.registry.create(.java_download, "Synthetic Java 21 transfer (no network)");
        errdefer f.registry.finish(task, .canceled);
        try f.registry.start(task);
        job.* = .{
            .io = f.io,
            .root = controller.root,
            .request = .{ .vendor = .azul, .major = 21 },
            .platform = try controller.hostPlatform(),
            .download_connections = controller.download_connections,
            .task = task,
            .service_adapter = .{ .service = controller.service },
            .transport = controller.fixture_transport.?,
            .extractor = controller.fixture_extractor,
            .probe = controller.probe,
        };
        task.reportDetails(javaProgressDetails(.downloading, true));
        // Publish before spawning: the fixture worker borrows this stable owner.
        controller.active = job;
        errdefer controller.active = null;
        job.thread = try std.Thread.spawn(.{}, javaProgressWorker, .{f});
        controller.phase = .running;
        f.java_progress = true;
    }

    fn javaProgressWorker(f: *Fixture) void {
        const job = f.java_download_controller.active.?;
        while (!job.task.?.canceled()) {
            std.Io.sleep(f.io, .fromMilliseconds(10), .awake) catch {};
        }
        job.failure = error.Canceled;
        job.done.store(true, .release);
    }

    fn pollJavaProgressActions(f: *Fixture) !void {
        if (!f.java_progress) return;
        dvui.currentWindow().timer(dvui.currentWindow().data().id.update("fixture.java-progress"), 50_000);
        const path = try std.fs.path.join(f.allocator, &.{ f.paths.vela, "java-progress-action" });
        defer f.allocator.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(f.io, path, f.allocator, .limited(64)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer f.allocator.free(bytes);
        try std.Io.Dir.cwd().deleteFile(f.io, path);
        const action = std.mem.trim(u8, bytes, " \t\r\n");
        const controller = &f.java_download_controller;
        if (std.mem.eql(u8, action, "cancel")) {
            controller.cancel();
        } else {
            const job = controller.active orelse return error.FixtureJavaProgressAlreadyTerminal;
            if (std.mem.eql(u8, action, "known")) {
                job.task.?.reportDetails(javaProgressDetails(.downloading, true));
            } else if (std.mem.eql(u8, action, "unknown")) {
                job.task.?.reportDetails(javaProgressDetails(.downloading, false));
            } else if (std.mem.eql(u8, action, "verifying")) {
                // Deliberately retain a seeded rate: snapshot/UI must suppress it.
                job.task.?.reportDetails(javaProgressDetails(.verifying, true));
            } else return error.InvalidFixtureJavaProgressAction;
        }
    }

    // Opt-in acceptance only: finite RAM logs and phases, never a game Job.
    fn pollLogsActions(f: *Fixture) !void {
        if (!f.logs_control) return;
        if (f.launcher.job != null or f.launcher.launch_allowed) return error.UnsafeFixtureLogsController;
        dvui.currentWindow().timer(dvui.currentWindow().data().id.update("fixture.logs-control"), 50_000);
        const path = try std.fs.path.join(f.allocator, &.{ f.paths.vela, "logs-action" });
        defer f.allocator.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(f.io, path, f.allocator, .limited(128)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer f.allocator.free(bytes);
        try std.Io.Dir.cwd().deleteFile(f.io, path);
        const action = std.mem.trim(u8, bytes, " \t\r\n");
        if (std.meta.stringToEnum(game_launch.Phase, action)) |phase| {
            f.launcher.phase = phase;
            f.launcher.failure = if (phase == .failed) error.FixtureSyntheticFailure else null;
            f.launcher.exit_code = if (phase == .exited) 0 else null;
        } else if (std.mem.eql(u8, action, "append")) {
            if (f.logs_appends >= 4) return error.FixtureLogsAppendLimit;
            f.logs_appends += 1;
            var row: [160]u8 = undefined;
            for (0..64) |index| {
                const text = try std.fmt.bufPrint(&row, "[INFO] Synthetic append {d} row {d:0>2}; ACCEPTANCE_LATEST_{d:0>3}\n", .{ f.logs_appends, index, f.logs_appends });
                try f.launcher.buffer.feed(.stdout, text);
            }
        } else if (std.mem.eql(u8, action, "logs")) {
            f.model.panel = .logs;
        } else if (std.mem.eql(u8, action, "tools")) {
            f.model.panel = .more;
        } else return error.InvalidFixtureLogsAction;
    }

    fn writeResourceReceipt(f: *Fixture) !void {
        if (f.model.panel != .mods) return;
        const Tag = struct { name: []const u8, data: ?dvui.TagData };
        const names = [_][]const u8{ "resource-type-button", "resource-type-menu", "resource-type-mod", "resource-type-resourcepack", "resource-type-shader" };
        var tags: [names.len]Tag = undefined;
        for (names, 0..) |name, i| tags[i] = .{ .name = name, .data = dvui.tagGet(name) };
        const bytes = try std.json.Stringify.valueAlloc(f.allocator, .{
            .kind = @tagName(f.mods_ui.kind),
            .route = @tagName(f.mods_ui.acquisition.route),
            .job = @tagName(f.mods_ui.acquisition.job),
            .menu_mode = @tagName(f.mods_ui.resource_menu.mode),
            .focused_widget = dvui.focusedWidgetId(),
            .menu_focused = f.mods_ui.resource_menu.menu_id != null and f.mods_ui.resource_menu.menu_id == dvui.focusedSubwindowId(),
            .metadata_started = f.resource_metadata_gate.started.load(.acquire),
            .metadata_cancel_seen = f.resource_metadata_gate.cancel_seen.load(.acquire),
            .tags = tags,
        }, .{});
        defer f.allocator.free(bytes);
        var dir = try std.Io.Dir.cwd().openDir(f.io, f.paths.vela, .{});
        defer dir.close(f.io);
        const file = try dir.createFile(f.io, "resource-state.tmp", .{});
        defer file.close(f.io);
        try file.writeStreamingAll(f.io, bytes);
        try dir.rename("resource-state.tmp", dir, "resource-state.json", f.io);
    }

    fn writeLogsReceipt(f: *Fixture) !void {
        if (!f.logs_control) return;
        const Tag = struct { name: []const u8, data: ?dvui.TagData };
        const names = [_][]const u8{ "logs-search-toolbar", "logs-output-toolbar", "logs-jump-latest", "logs-copy-line", "logs-copy-output", "logs-clear-output", "logs-stop-game", "logs-search-entry", "logs-search-prev", "logs-search-next", "logs-viewport" };
        var tags: [names.len]Tag = undefined;
        for (names, 0..) |name, i| tags[i] = .{ .name = name, .data = dvui.tagGet(name) };
        const bytes = try std.json.Stringify.valueAlloc(f.allocator, .{
            .phase = @tagName(f.launcher.phase),
            .panel = @tagName(f.model.panel),
            .attempt = f.launcher.attempt_id,
            .job_absent = f.launcher.job == null,
            .launch_allowed = f.launcher.launch_allowed,
            .retained = f.launcher.buffer.lineCount(),
            .query = std.mem.sliceTo(&f.logs_ui.query, 0),
            .cursor = f.logs_ui.cursor,
            .selected = f.logs_ui.selected,
            .sources = f.logs_ui.filters.sources,
            .severities = f.logs_ui.filters.severities,
            .follow = f.logs_ui.follow_tail,
            .scroll_y = f.logs_ui.scroll.viewport.y,
            .scroll_max = f.logs_ui.scroll.scrollMax(.vertical),
            .search_status = @tagName(f.logs_ui.search_status),
            .copy_status = @tagName(f.logs_ui.copy_status),
            .pending_clear = f.logs_ui.pending_clear,
            .pending_stop = f.logs_ui.pending_stop,
            .tags = tags,
        }, .{});
        defer f.allocator.free(bytes);
        var dir = try std.Io.Dir.cwd().openDir(f.io, f.paths.vela, .{});
        defer dir.close(f.io);
        const file = try dir.createFile(f.io, "logs-state.tmp", .{});
        defer file.close(f.io);
        try file.writeStreamingAll(f.io, bytes);
        try dir.rename("logs-state.tmp", dir, "logs-state.json", f.io);
    }

    fn enableNativePickers(f: *Fixture, win: *dvui.Window) !void {
        if (comptime dvui.backend.kind == .sdl3) {
            try f.native_window.init(win);
        } else return error.NativeDialogUnavailable;
        f.native_pickers = true;
        f.java_ui.picker_service = &f.picker;
    }

    fn discardNativePickers(f: *Fixture) void {
        java_view.discardPicker(&f.java_ui);
        if (f.appearance.ticket) |ticket| f.picker.discard(ticket);
        f.appearance.ticket = null;
    }

    fn requestNativeClose(f: *Fixture) void {
        f.native_quit_requested = true;
        f.discardNativePickers();
        f.picker.beginShutdown();
    }

    /// Acceptance-only control, enabled solely by VELA_FIXTURE_NATIVE_PICKERS=1.
    /// A helper atomically writes ROOT/.vela/native-picker-action with one line
    /// "close" or "navigate". The UI thread consumes and unlinks the request.
    fn pollNativePickerActions(f: *Fixture) !void {
        const path = try std.fs.path.join(f.allocator, &.{ f.paths.vela, "native-picker-action" });
        defer f.allocator.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(f.io, path, f.allocator, .limited(128)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer f.allocator.free(bytes);
        try std.Io.Dir.cwd().deleteFile(f.io, path);
        const action = std.mem.trim(u8, bytes, " \t\r\n");
        if (std.mem.eql(u8, action, "close")) {
            f.requestNativeClose();
        } else if (std.mem.eql(u8, action, "navigate")) {
            f.discardNativePickers();
            f.model.panel = .home;
        } else return error.InvalidFixtureNativePickerAction;
    }

    fn creationServices(f: *Fixture) creation_controller.Services {
        return .{ .store = &f.configuration, .java = &f.java_manager, .java_download = &f.java_download_controller, .instances = &f.instance_manager };
    }
    fn armInstanceScene(f: *Fixture, hold: instance_fixture.Hold) !void {
        if (f.scene == .layout and hold != .none) return error.FixtureControlRequiresPreparedScene;
        f.instance_data.hold_installer.store(hold == .installer, .release);
    }
    fn creationPinned(f: *const Fixture) bool {
        return f.creation_core.ownership().pinned;
    }

    // Same ownership and JOIN order as App; no global content selection here.
    fn tickServices(f: *Fixture) !void {
        // Content.cancel marks its actual task before its held worker can JOIN.
        if (f.content.active) |job| if (job.task) |task| {
            if (task.canceled()) f.instance_data.releaseHolds();
        };
        if (f.creation_core.snapshot().phase == .cleaning) f.instance_data.releaseHolds();
        f.coordinator.tick();
        f.library.tick();
        try seedFixtureCatalogue(f);
        const creation_owners = f.creation_core.ownership();
        if (creation_owners.tickJava(&f.java_manager)) f.ticks.java += 1;
        f.launcher.tick();
        if (creation_owners.tickJavaDownload(&f.java_download_controller, &f.java_manager)) f.ticks.java_download += 1;
        f.servers.tick();
        f.worlds.tick();
        f.accounts.tick(&f.configuration);
        if (creation_owners.tickInstances(&f.instance_manager)) f.ticks.instances += 1;
        f.creation_core.tick(f.creationServices());
        f.ticks.creation_core += 1;
        f.content.tick();
        f.ticks.content += 1;
        f.cf_credentials.tick(&f.configuration);
        try f.download_budget.setLimit(f.configuration.snapshot().settings.download_connections);
        const snapshot = f.content.snapshot();
        if (!f.creationPinned() and !f.configuration.publicationUncertain()) {
            f.instance_manager.setDownloadConnections(f.configuration.snapshot().settings.download_connections);
            if (!f.content.isBusy() and !snapshot.recovery_required) {
                try f.content.setDownloadConnections(f.configuration.snapshot().settings.download_connections);
                // Preserve the policy while an injected credential job holds its lease.
                if (!f.cf_credentials.lease()) {
                    const settings = f.configuration.snapshot().settings;
                    var policy: content_manager.CurseForgePolicy = .{
                        .enabled = settings.curseforge_enabled,
                        .terms_approved = settings.curseforge_terms_approved,
                    };
                    if (settings.curseforge_credential_ref) |reference| policy.credential_ref = reference[0..32].*;
                    try f.content.setCurseForgePolicy(policy);
                }
            }
        }
        const fingerprint = instanceFingerprint(f.configuration.snapshot());
        if (fingerprint != f.instance_fingerprint) {
            var refresh_started = true;
            f.library.refreshInstalled() catch {
                refresh_started = false;
            };
            if (refresh_started) f.instance_fingerprint = fingerprint;
        }
        for (f.registry.tasks()) |task| {
            if (task.id <= f.fixture_task_last_id and task.canceled()) f.registry.finish(task, .canceled);
        }
        f.advanceResourcePreview();
    }

    fn advanceResourcePreview(f: *Fixture) void {
        if (!isResourcePreview(f.resource_preview)) return;
        const ui = &f.mods_ui.acquisition;
        if (f.resource_preview == .@"mods-detail-loading" and f.resource_preview_step == 2 and ui.route == .detail and !f.content.isBusy()) {
            // Freeze presentation metadata only; no worker or transport is held.
            const detail = ui.frame() orelse return;
            detail.candidates = &.{};
            detail.issues = &.{};
            ui.proposal_current = false;
            ui.needs_prepare = false;
            return;
        }
        if (f.content.isBusy() or ui.job != .idle or ui.pending != null or f.model.panel != .mods) return;
        if (f.resource_preview_step == 0 and ui.route == .catalog and ui.failure != null and std.mem.indexOf(u8, @errorName(ui.failure.?), "Busy") != null) {
            ui.queue(.search);
            return;
        }
        if (f.resource_preview == .@"mods-download" or f.resource_preview == .@"mods-download-scroll") return;
        if (f.resource_preview_step == 0 and ui.route == .catalog and ui.searched and ui.catalog.len > 0) {
            ui.queue(.{ .project = ui.catalog[0] });
            f.resource_preview_step = 1;
        } else if (f.resource_preview_step == 1 and ui.route == .detail and ui.currentProposal(f.content.snapshot())) {
            if (f.resource_preview != .@"mods-detail" and f.resource_preview != .@"mods-detail-optional" and f.resource_preview != .@"mods-detail-loading") {
                const detail = ui.frame().?;
                const root = detail.version().?;
                for (root.dependencies, 0..) |dependency, index| {
                    if (dependency.kind != .required or detail.choice(index) != null) continue;
                    for (detail.candidates) |candidate| {
                        if (@import("ui/resource_download_state.zig").matchesDependency(candidate, root, dependency)) {
                            ui.queue(.{ .choice = .{ .dependency_index = index, .version_id = candidate.id, .include = true } });
                            return;
                        }
                    }
                }
                ui.queue(.confirm);
            }
            f.resource_preview_step = 2;
        } else if (f.resource_preview_step == 2 and ui.confirm_open and (f.resource_preview == .@"mods-task-complete" or f.resource_preview == .@"mods-task-failed")) {
            // Presentation fixtures never commit a real or simulated installation.
            const succeeded = f.resource_preview == .@"mods-task-complete";
            ui.confirm_open = false;
            ui.task_state = if (succeeded) .succeeded else .failed;
            if (!succeeded) {
                ui.failure = error.ConnectionResetByPeer;
            }
            var reports: @import("core/tasks.zig").Details = .{};
            const detail = ui.frame().?;
            for (f.content.snapshot().proposal.?.files) |file| {
                if (file.selected == false or reports.file_count == reports.files.len) continue;
                const primary = file.record.provider == detail.project.provider and std.mem.eql(u8, file.record.project_id, detail.project.id);
                const complete = succeeded or primary;
                reports.files[reports.file_count] = @import("core/tasks.zig").File.init(file.record.path, if (complete) 100 else 42, 100, 0, if (complete) .complete else .failed, if (complete) null else error.ConnectionResetByPeer);
                reports.file_count += 1;
            }
            ui.task_details = reports;
            f.resource_preview_step = 3;
        } else if (f.resource_preview_step == 2 and ui.confirm_open and f.resource_preview == .@"mods-task") {
            const proposal = f.content.snapshot().proposal.?;
            if (!proposal.ready) {
                for (proposal.plan.conflicts) |conflict| {
                    var decided = false;
                    for (ui.decisions.items) |decision| if (std.mem.eql(u8, decision.path, conflict.path)) {
                        decided = true;
                        break;
                    };
                    if (!decided) {
                        ui.queue(.{ .conflict = .{ .path = conflict.path, .choice = .replace } });
                        return;
                    }
                }
                return;
            }
            ui.queue(.commit);
            f.resource_preview_step = 3;
        }
    }
    fn create(a: std.mem.Allocator, io: std.Io, root: []const u8, panel: Panel, viewport: dvui.Size) !*Fixture {
        return createScene(a, io, root, panel, viewport, .layout);
    }

    fn createScene(a: std.mem.Allocator, io: std.Io, root: []const u8, panel: Panel, viewport: dvui.Size, scene: instance_fixture.Scene) !*Fixture {
        const f = try a.create(Fixture);
        errdefer a.destroy(f);
        f.allocator = a;
        f.io = io;
        f.native_pickers = false;
        f.logs_control = false;
        f.logs_appends = 0;
        f.java_progress = false;
        f.native_quit_requested = false;
        f.native_window = .{};
        f.picker = file_picker.Service.init(a);
        errdefer f.picker.deinit();
        f.viewport = viewport;
        f.scene = scene;
        f.ticks = .{};
        f.catalogue_seeded = false;
        f.shutdown_prompt = panel == .shutdown;
        f.resource_preview = panel;
        f.resource_preview_step = 0;
        f.resource_http_scenario = .{
            .pause_downloads = panel == .@"mods-task",
            .preview_optional_dependency = panel == .@"mods-detail-optional" or panel == .@"mods-detail-loading",
        };
        f.paths = try instances.Paths.init(a, io, root);
        errdefer f.paths.deinit();
        f.instance_data = instance_fixture.Context.init(a);
        errdefer f.instance_data.deinit();
        if (scene == .@"instance-prepared") try instance_fixture.initPrepared(&f.instance_data, a, io, root);
        f.configuration = try config.Store.init(a, io, root);
        errdefer f.configuration.deinit();
        f.download_budget = try @import("core/downloader.zig").Budget.init(io, f.configuration.snapshot().settings.download_connections);
        errdefer f.download_budget.deinit();
        const initial_document = f.configuration.snapshot();
        const fresh_configuration = initial_document.instances.len == 0 and initial_document.accounts.len == 0 and initial_document.servers.len == 0;
        try seedConfiguration(&f.configuration);
        if (isResourcePreview(panel)) {
            var document = f.configuration.snapshot().*;
            const items = try a.dupe(config.Instance, document.instances);
            defer a.free(items);
            for (items) |*item| if (std.mem.eql(u8, item.id, "fixture-primary")) {
                item.loader = .fabric;
                item.loader_version = "0.16.14";
            };
            document.instances = items;
            try f.configuration.update(document);
        }
        f.registry = tasks.Registry.init(a);
        errdefer f.registry.deinit();
        f.cf_vault = .{};
        errdefer f.cf_vault.deinit();
        f.cf_credentials = try cf_credentials_controller.Controller.init(a, io, root, .{ .registry = &f.registry, .injected_store = f.cf_vault.store() });
        errdefer f.cf_credentials.deinit();
        try seedTasks(a, &f.registry);
        const entries = f.registry.tasks();
        f.fixture_task_last_id = entries[entries.len - 1].id;
        f.coordinator = instance_leases.Coordinator.init(io);
        const content_mutation = f.coordinator.mutation(1);
        const instance_mutation = f.coordinator.mutation(2);
        try seedGames(f);
        f.library = try games.Controller.initWithOptions(a, io, .{
            .download_budget = &f.download_budget,
            .root = f.paths.minecraft,
            .manifest_url = "fixture-disabled://catalogue",
            .cache_root = f.paths.cache,
        });
        errdefer f.library.deinit();
        f.java_manager = try java.Manager.init(a, io, root);
        errdefer f.java_manager.deinit();
        if (scene == .@"instance-prepared") try instance_fixture.registerMarkers(&f.instance_data, &f.java_manager);
        if (scene == .layout) try seedOwnedJava(f);
        f.java_ui = java_view.Ui.init(a);
        errdefer f.java_ui.deinit();
        f.launcher = try game_launch.Controller.initWithOptions(a, io, f.paths.minecraft, .{
            .log_directory = f.paths.logs,
            .launch_guard = .{ .context = f, .acquire = disabledLaunchAcquire, .release = disabledLaunchRelease },
        });
        errdefer f.launcher.deinit();
        f.launcher.setLaunchAllowed(false);
        if (scene == .layout) try seedFixtureLogs(&f.launcher.buffer);
        f.settings = try settings_view.Ui.init(a, f.configuration.snapshot().settings);
        errdefer f.settings.deinit();
        f.appearance = try appearance_view.Ui.init(a, io, f.configuration.snapshot().appearance);
        errdefer f.appearance.deinit();
        f.appearance.picker = &f.picker;
        f.java_download_controller = try java_download.Controller.initWithOptions(a, io, .{
            .download_budget = &f.download_budget,
            .root = root,
            .task_registry = &f.registry,
            .transport = .{ .context = f, .get = disabledJavaGet, .download = disabledJavaDownload },
        });
        errdefer f.java_download_controller.deinit();
        f.java_download_ui = java_download_view.Ui.init(a);
        errdefer f.java_download_ui.deinit();
        f.servers = server_manager.Manager.initWithQuery(a, io, if (scene == .layout) layoutServerQuery else disabledServerQuery);
        errdefer f.servers.deinit();
        f.servers_ui = servers_view.Ui.init(a);
        errdefer f.servers_ui.deinit();
        f.logs_ui = .{};
        f.worlds = try worlds_manager.Manager.initOptions(a, io, &f.paths, &f.registry, .{ .scope = f.coordinator.worldScope(3), .scan_scope = f.coordinator.worldReadScope(3) });
        errdefer f.worlds.deinit();
        f.worlds_ui = try worlds_view.Ui.init(a);
        errdefer f.worlds_ui.deinit();
        f.accounts = try accounts_manager.Manager.initWithOptions(a, io, .{ .root = root, .fixture = .{
            .transport = .{ .ctx = f, .kind = .fixture, .supports_post = true, .request = disabledAuthRequest },
            .store = .{ .ctx = f, .vtable = &disabled_vault },
            .entropy = .{ .ctx = f, .fill = fixtureEntropy },
            .journal = .{ .ctx = f, .stage = disabledJournalChange, .remove = disabledJournalChange, .references = emptyJournalReferences },
        } });
        errdefer f.accounts.deinit();
        f.accounts_ui = try accounts_view.Ui.init(a);
        errdefer f.accounts_ui.deinit();
        try seedOfflineAccount(&f.accounts, &f.configuration);
        f.accounts.tick(&f.configuration);
        f.instance_manager = try instances_manager.Manager.initWithOptions(a, io, &f.paths, &f.registry, f.coordinator.guard(instance_mutation), .{
            .context = instance_mutation,
            .acquire = instance_leases.Mutation.acquireCallback,
            .recheck = instance_leases.Mutation.recheckCallback,
            .release = instance_leases.Mutation.releaseCallback,
        }, .{ .download_budget = &f.download_budget });
        errdefer f.instance_manager.deinit();
        f.instance_manager.setWorkerRecheck(instance_leases.Mutation.workerRecheckCallback);
        f.instance_manager.setInstaller(if (scene == .@"instance-prepared" or std.c.getenv("VELA_FIXTURE_INSTANCE_TASK") != null) instance_fixture.preparedInstaller(&f.instance_data) else .{ .context = f, .run = disabledInstanceInstall });
        f.instance_manager.setLoaderCatalogue(.{ .context = f, .fetch = fixtureLoaderCatalogue });
        f.instances_ui = instances_view.Ui.init(a);
        errdefer f.instances_ui.deinit();
        f.resource_metadata_gate = .{ .match = "/project/iris/version" };
        f.resource_http_navigation = .{ .scenario = &f.resource_http_scenario, .gate = if (panel == .@"mods-detail-slow") &f.resource_metadata_gate else null, .long_catalog = panel == .@"mods-download-scroll" };
        f.content = try content_manager.Manager.initOptions(a, io, &f.paths, &f.registry, .{
            .lease = f.instance_data.contentLease(.{ .context = content_mutation, .acquire = instance_leases.Mutation.acquireCallback, .recheck = instance_leases.Mutation.recheckCallback, .release = instance_leases.Mutation.releaseCallback }, instance_leases.Mutation.workerRecheckCallback),
            .worker_recheck = instance_fixture.Context.workerRecheck,
            .transport_options = if (isResourcePreview(panel)) .{ .download_budget = &f.download_budget, .fixture_http = resource_navigation.execute, .fixture_context = &f.resource_http_navigation, .approved_download_hosts = &.{"cdn.modrinth.com"} } else .{ .download_budget = &f.download_budget, .fixture_http = instance_fixture.Context.denyHttp, .fixture_context = &f.instance_data, .allow_curseforge = false, .approved_download_hosts = &.{} },
            .fixture_credential_store = f.cf_vault.store(),
            .fixture_fault = .{ .context = f, .boundary = disabledContentMutation },
        });
        errdefer f.content.deinit();
        f.mods = mods_controller.Controller.init(a, io, &f.paths);
        errdefer f.mods.deinit();
        f.mods_ui = try mods_view.Ui.init(a);
        f.mods_ui.acquisition.icons = @import("ui/resource_icons.zig").Manager.init(a, io);
        errdefer f.mods_ui.deinit();
        f.mods_ui.acquisition.picker = &f.picker;
        f.creation_core = try creation_controller.Controller.init(a, io, root, .{ .task_registry = &f.registry, .runner = f.instance_data.runner() });
        errdefer f.creation_core.deinit(f.creationServices());
        f.model = .{
            .players = &.{.{ .id = 1, .name = "FixturePlayer", .initials = "FP", .kind = "Offline" }},
            .versions = &.{.{ .id = 1, .name = "fixture-game", .description = "Minecraft 1.21.4" }},
        };
        switch (panel) {
            .home, .shutdown => {},
            .mods, .@"mods-download", .@"mods-download-scroll", .@"mods-detail-slow", .@"mods-detail", .@"mods-detail-optional", .@"mods-detail-loading", .@"mods-confirm", .@"mods-task", .@"mods-task-complete", .@"mods-task-failed" => {
                f.model.panel = .mods;
                const instance = instances.findById(f.configuration.snapshot(), "fixture-primary").?.*;
                _ = f.model.mods_instance.set(instance.id);
                if (isResourcePreview(panel)) {
                    try f.mods.select(instance, .mod, &f.content);
                    try f.mods_ui.acquisition.bind(instance, .mod);
                    f.mods_ui.acquisition.open();
                }
            },
            .versions => f.model.panel = .versions,
            .more => f.model.panel = .more,
            .settings => {
                f.model.panel = .more;
                f.model.category = .settings;
            },
            .theme => {
                f.model.panel = .more;
                f.model.category = .theme;
            },
            .java => {
                f.model.panel = .java;
                f.java_ui.search_started = true;
                f.java_ui.acquisition_open = true;
            },
            .servers => f.model.panel = .servers,
            .logs => f.model.panel = .logs,
            .worlds => {
                f.model.panel = .worlds;
                f.model.category = .game;
            },
            .instances => f.model.panel = .instances,
            .player, .@"account-add" => {
                f.model.panel = .players;
                try seedAccountPreview(a, &f.configuration);
                f.accounts_ui.editor_open = panel == .@"account-add";
            },
        }
        const path_len = @min(root.len, f.java_ui.path_buffer.len - 1);
        @memcpy(f.java_ui.path_buffer[0..path_len], root[0..path_len]);
        try seedWorlds(f, fresh_configuration);
        f.instance_fingerprint = instanceFingerprint(f.configuration.snapshot());
        try f.library.refreshInstalled();
        return f;
    }

    fn destroy(f: *Fixture) void {
        const a = f.allocator;
        if (comptime dvui.backend.kind == .sdl3) f.native_window.deinit();
        // frame only returns close after native callback storage has drained.
        f.discardNativePickers();
        f.picker.beginShutdown();
        std.debug.assert(f.picker.isDrained());
        f.content.cancel();
        f.instance_data.releaseHolds();
        f.creation_core.deinit(f.creationServices());
        f.launcher.deinit();
        f.mods.deinit();
        f.mods_ui.deinit();
        f.content.cancelAndJoin();
        if (isResourcePreview(f.resource_preview)) std.debug.print("resource fixture closed: content_busy={} lease_released={}\n", .{ f.content.isBusy(), f.instance_data.content_released.load(.acquire) });
        f.content.deinit();
        f.instance_manager.deinit();
        f.instances_ui.deinit();
        f.accounts.deinit();
        f.accounts_ui.deinit();
        f.worlds.deinit();
        f.worlds_ui.deinit();
        f.servers.deinit();
        f.servers_ui.deinit();
        f.java_download_controller.deinit();
        f.java_download_ui.deinit();
        f.java_manager.deinit();
        f.java_ui.deinit();
        f.appearance.deinit();
        f.picker.deinit();
        f.library.deinit();
        f.download_budget.deinit();
        f.cf_credentials.deinit();
        f.cf_vault.deinit();
        f.settings.deinit();
        for (f.registry.tasks()) |task| f.registry.finish(task, .canceled);
        f.registry.deinit();
        f.configuration.deinit();
        f.instance_data.deinit();
        f.paths.deinit();
        a.destroy(f);
    }
};

fn parseViewport(value: []const u8) !dvui.Size {
    if (std.mem.eql(u8, value, "640x400")) return .{ .w = 640, .h = 400 };
    if (std.mem.eql(u8, value, "960x720")) return .{ .w = 960, .h = 720 };
    if (std.mem.eql(u8, value, "1280x720")) return .{ .w = 1280, .h = 720 };
    return error.InvalidFixtureViewport;
}

fn seedConfiguration(store: *config.Store) !void {
    const current = store.snapshot();
    for (current.instances) |item| if (!std.mem.startsWith(u8, item.id, "fixture-")) return error.NotFixtureConfiguration;
    const offline_uuid = try accounts_manager.offlineUuid("FixturePlayer");
    for (current.accounts) |item| if (!std.mem.startsWith(u8, item.id, "fixture-") and !(item.kind == .offline and std.mem.eql(u8, item.name, "FixturePlayer") and std.mem.eql(u8, item.uuid, &offline_uuid))) return error.NotFixtureConfiguration;
    for (current.servers) |item| if (!std.mem.startsWith(u8, item.id, "fixture-")) return error.NotFixtureConfiguration;
    if (current.instances.len != 0 or current.accounts.len != 0 or current.servers.len != 0) return;
    try store.update(.{
        .settings = .{ .default_memory_mb = 4096, .download_connections = 8 },
        .instances = &.{
            .{ .id = "fixture-primary", .name = "fixture-game", .minecraft_version = "1.21.4" },
            .{ .id = "fixture-copy", .name = "fixture-copy", .minecraft_version = "1.21.4" },
        },
        .servers = &.{
            .{ .id = "fixture-server-one", .name = "Fixture Survival", .address = "survival.fixture.invalid", .instance_id = "fixture-primary", .show_on_home = true },
            .{ .id = "fixture-server-two", .name = "Fixture Creative", .address = "creative.fixture.invalid", .instance_id = "fixture-primary" },
            .{ .id = "fixture-server-three", .name = "Fixture Minigames", .address = "minigames.fixture.invalid", .port = 25566, .instance_id = "fixture-copy" },
        },
        .selected_instance = "fixture-primary",
        .selected_server = "fixture-server-one",
    });
}

fn seedOfflineAccount(manager: *accounts_manager.Manager, store: *config.Store) !void {
    if (accounts_manager.findAccount(store.snapshot(), "fixture-player")) |legacy| {
        if (legacy.kind != .offline or !std.mem.eql(u8, legacy.name, "FixturePlayer")) return error.NotFixtureConfiguration;
        try manager.removeOffline(store, legacy.id);
    }
    const uuid = try accounts_manager.offlineUuid("FixturePlayer");
    for (store.snapshot().accounts) |account| if (account.kind == .offline and std.mem.eql(u8, account.uuid, &uuid)) {
        try manager.select(store, account.id);
        return;
    };
    try manager.addOffline(store, "FixturePlayer");
    for (store.snapshot().accounts) |account| if (account.kind == .offline and std.mem.eql(u8, account.uuid, &uuid)) {
        try manager.select(store, account.id);
        return;
    };
    return error.FixtureAccountMissing;
}

// The account scene includes a Microsoft-shaped card without an auth session,
// client credentials or network access; production configuration is never seeded.
fn seedAccountPreview(a: std.mem.Allocator, store: *config.Store) !void {
    if (accounts_manager.findAccount(store.snapshot(), "fixture-microsoft-preview") != null) return;
    var document = store.snapshot().*;
    const accounts = try a.alloc(config.Account, document.accounts.len + 1);
    defer a.free(accounts);
    @memcpy(accounts[0..document.accounts.len], document.accounts);
    accounts[accounts.len - 1] = .{ .id = "fixture-microsoft-preview", .name = "FixtureMicrosoft", .uuid = "00112233445566778899aabbccddeeff", .kind = .microsoft };
    document.accounts = accounts;
    try store.update(document);
}

const fixture_client = [_]u8{ 'P', 'K', 5, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
fn seedGames(f: *Fixture) !void {
    const a = f.allocator;
    const index_bytes = "{\"objects\":{}}";
    var client_sha1: [20]u8 = undefined;
    var client_sha256: [32]u8 = undefined;
    var index_sha1: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(&fixture_client, &client_sha1, .{});
    std.crypto.hash.sha2.Sha256.hash(&fixture_client, &client_sha256, .{});
    std.crypto.hash.Sha1.hash(index_bytes, &index_sha1, .{});
    const client_hash = std.fmt.bytesToHex(&client_sha1, .lower);
    const client_binding = std.fmt.bytesToHex(&client_sha256, .lower);
    const index_hash = std.fmt.bytesToHex(&index_sha1, .lower);
    const index_path = try std.fs.path.join(a, &.{ f.paths.minecraft, "assets", "indexes" });
    defer a.free(index_path);
    var indexes = try std.Io.Dir.cwd().createDirPathOpen(f.io, index_path, .{});
    defer indexes.close(f.io);
    try writeFixtureFile(indexes, f.io, "fixture-assets.json", index_bytes);
    const empty: []const std.json.Value = &.{};
    for (f.configuration.snapshot().instances) |instance| {
        const fixture_fabric_instance = instance.loader == .fabric and std.mem.eql(u8, instance.id, "fixture-primary") and std.mem.eql(u8, instance.minecraft_version, "1.21.4") and std.mem.eql(u8, instance.loader_version orelse "", "0.16.14");
        if (instance.loader != .vanilla and !fixture_fabric_instance) return error.NotFixtureConfiguration;
        const game_path = try f.paths.instanceDirectory(instance.name);
        defer a.free(game_path);
        var dir = try std.Io.Dir.cwd().createDirPathOpen(f.io, game_path, .{});
        defer dir.close(f.io);
        const jar_name = try std.fmt.allocPrint(a, "{s}.jar", .{instance.name});
        defer a.free(jar_name);
        const document_name = try std.fmt.allocPrint(a, "{s}.json", .{instance.name});
        defer a.free(document_name);
        const document = try std.json.Stringify.valueAlloc(a, .{
            .id = instance.name,
            .type = "release",
            .mainClass = if (fixture_fabric_instance) "net.fabricmc.loader.impl.launch.knot.KnotClient" else "net.minecraft.client.main.Main",
            .javaVersion = .{ .component = "java-runtime-delta", .majorVersion = @as(u32, 21) },
            .downloads = .{ .client = .{ .url = "https://fixture.invalid/client.jar", .sha1 = &client_hash, .size = fixture_client.len } },
            .assetIndex = .{ .id = "fixture-assets", .url = "https://fixture.invalid/assets.json", .sha1 = &index_hash, .size = index_bytes.len, .totalSize = @as(u64, 0) },
            .assets = "fixture-assets",
            .libraries = empty,
            .arguments = .{ .game = empty, .jvm = empty },
        }, .{});
        defer a.free(document);
        var document_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(document, &document_hash, .{});
        const metadata_binding = std.fmt.bytesToHex(&document_hash, .lower);
        const receipt = try std.json.Stringify.valueAlloc(a, .{
            .schema_version = @as(u32, 1),
            .instance_id = instance.id,
            .instance_name = instance.name,
            .minecraft_version = instance.minecraft_version,
            .loader = @tagName(instance.loader),
            .loader_version = instance.loader_version,
            .metadata_sha256 = &metadata_binding,
            .client_sha256 = &client_binding,
            .client_size = @as(u64, fixture_client.len),
        }, .{});
        defer a.free(receipt);
        try writeFixtureFile(dir, f.io, jar_name, &fixture_client);
        try writeFixtureFile(dir, f.io, document_name, document);
        try writeFixtureFile(dir, f.io, ".vela-instance.json", receipt);
    }
}

fn instanceFingerprint(doc: *const config.Document) u64 {
    var hash = std.hash.Wyhash.init(0);
    for (doc.instances) |instance| {
        for ([_][]const u8{ instance.id, instance.name, instance.minecraft_version, instance.loader_version orelse "" }) |part| {
            hash.update(part);
            hash.update(&.{0});
        }
        const kind: u8 = @backingInt(instance.loader);
        hash.update(std.mem.asBytes(&kind));
    }
    return hash.final();
}

fn activeFixtureTasks(registry: *const tasks.Registry) usize {
    var count: usize = 0;
    for (registry.tasks()) |task| switch (task.state) {
        .queued, .running, .canceling => count += 1,
        .canceled, .succeeded, .failed => {},
    };
    return count;
}

fn seedTasks(a: std.mem.Allocator, registry: *tasks.Registry) !void {
    for (0..23) |i| {
        const title = try std.fmt.allocPrint(a, "Fixture {s} {d:0>2}", .{ if (i % 2 == 0) "Minecraft 1.21.4" else "Java 21 runtime", i + 1 });
        defer a.free(title);
        const task = try registry.create(if (i % 2 == 0) .game_install else .java_download, title);
        try registry.start(task);
        task.report(if (i % 3 == 0) .verifying else .downloading, 16_777_216 + i * 1_048_576, 67_108_864);
        if (i >= 20) registry.finish(task, switch (i) {
            20 => .succeeded,
            21 => .{ .failed = error.FixtureDownloadFailed },
            else => .canceled,
        });
    }
}

fn disabledInstanceInstall(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: instances_manager.CreateRequest, control: instances_manager.Control) !instances_manager.Installed {
    try control.check();
    return error.FixtureInstallationDisabled;
}
fn disabledLoaderCatalogue(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: []const u8, _: config.Loader, control: instances_manager.Control) !instances_manager.LoaderCatalogue {
    try control.check();
    return error.FixtureNetworkDisabled;
}
fn disabledContentHttp(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: http.Request) !http.Response {
    return error.FixtureNetworkDisabled;
}
fn disabledContentMutation(_: ?*anyopaque, _: content_install.FaultPoint, _: usize) !void {
    return error.FixtureInstallationDisabled;
}
fn disabledLaunchAcquire(_: ?*anyopaque, _: []const u8) !void {
    return error.FixtureLaunchDisabled;
}
fn disabledLaunchRelease(_: ?*anyopaque) void {}
fn disabledAuthRequest(_: *anyopaque, _: std.mem.Allocator, _: auth.Request) auth.TransportError!auth.Response {
    return error.TransportFailure;
}
fn fixtureEntropy(context: *anyopaque, bytes: []u8) error{EntropyUnavailable}!void {
    const f: *Fixture = @ptrCast(@alignCast(context));
    f.io.randomSecure(bytes) catch return error.EntropyUnavailable;
}
const disabled_vault: credentials.Store.VTable = .{ .put = disabledVaultPut, .get = disabledVaultGet, .delete = disabledVaultDelete };
fn disabledVaultPut(_: *anyopaque, _: []const u8, _: []const u8) credentials.Error!void {
    return error.Unavailable;
}
fn disabledVaultGet(_: *anyopaque, _: std.mem.Allocator, _: []const u8) credentials.Error!credentials.Secret {
    return error.Unavailable;
}
fn disabledVaultDelete(_: *anyopaque, _: []const u8) credentials.Error!void {
    return error.Unavailable;
}
fn disabledJournalChange(_: *anyopaque, _: credentials.Reference) !void {
    return error.FixtureVaultDisabled;
}
fn emptyJournalReferences(_: *anyopaque) []const credentials.Reference {
    return &.{};
}

/// Deterministic display data; the layout fixture never contacts a server.
fn layoutServerQuery(a: std.mem.Allocator, _: std.Io, server: config.Server, _: servers_core.Options) !servers_core.OwnedStatus {
    if (!std.mem.eql(u8, server.id, "fixture-server-one")) return error.ConnectionRefused;
    var status = try servers_core.parseStatus(a, "{\"description\":\"Synthetic layout server\",\"players\":{\"online\":0,\"max\":20},\"version\":{\"name\":\"1.21.4\",\"protocol\":769}}");
    status.latency_ms = 42;
    return status;
}

fn disabledServerQuery(_: std.mem.Allocator, _: std.Io, _: config.Server, _: servers_core.Options) !servers_core.OwnedStatus {
    return error.FixtureNetworkDisabled;
}

fn disabledJavaGet(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: usize, hooks: java_backend.Hooks) ![]u8 {
    try hooks.check();
    return error.FixtureNetworkDisabled;
}

fn disabledJavaDownload(_: *anyopaque, _: std.Io, _: *const java_backend.RuntimeRelease, _: []const u8, hooks: java_backend.Hooks) !void {
    try hooks.check();
    return error.FixtureNetworkDisabled;
}

const fixture_catalogue = [_]games.CatalogEntry{
    .{ .id = "1.21.4", .url = "https://piston-meta.mojang.com/v1/packages/fixture/1.21.4.json", .kind = "release", .release_time = "2024-12-03T10:12:57+00:00" },
    .{ .id = "1.20.1", .url = "https://piston-meta.mojang.com/v1/packages/fixture/1.20.1.json", .kind = "release", .release_time = "2023-06-12T13:25:51+00:00" },
    .{ .id = "fixture-snapshot", .url = "https://piston-meta.mojang.com/v1/packages/fixture/fixture-snapshot.json", .kind = "snapshot" },
};
const prepared_fixture_catalogue = [_]games.CatalogEntry{
    .{ .id = instance_fixture.base_id, .url = "https://piston-meta.mojang.com/v1/packages/fixture/" ++ instance_fixture.base_id ++ ".json", .kind = "release", .release_time = "2014-06-26T00:00:00Z" },
};

test "offline fixture loader catalogue is bounded owns strings and honors cancellation" {
    const a = std.testing.allocator;
    var cancel = std.atomic.Value(bool).init(false);
    const control: instances_manager.Control = .{ .cancel = &cancel };
    inline for (.{ config.Loader.fabric, config.Loader.forge, config.Loader.neoforge, config.Loader.quilt }) |kind| {
        var catalogue = try fixtureLoaderCatalogue(null, a, std.testing.io, "1.21.4", kind, control);
        defer catalogue.deinit();
        try std.testing.expectEqual(kind, catalogue.kind);
        try std.testing.expectEqualStrings("1.21.4", catalogue.base);
        try std.testing.expectEqual(@as(usize, 2), catalogue.entries.len);
        try std.testing.expect(catalogue.entries[0].stable and !catalogue.entries[1].stable);
        try std.testing.expect(std.mem.startsWith(u8, catalogue.entries[0].id, "fixture-"));
        try std.testing.expectEqualStrings("2025-01-16T12:00:00Z", catalogue.entries[0].release_time);
        try std.testing.expectEqualStrings("", catalogue.entries[1].release_time);
    }
    try std.testing.expectError(error.UnknownFixtureMinecraftVersion, fixtureLoaderCatalogue(null, a, std.testing.io, "unknown", .fabric, control));
    try std.testing.expectError(error.InvalidLoader, fixtureLoaderCatalogue(null, a, std.testing.io, "1.21.4", .vanilla, control));
    cancel.store(true, .release);
    try std.testing.expectError(error.Canceled, fixtureLoaderCatalogue(null, a, std.testing.io, "1.21.4", .fabric, control));
}

test "finite fixture log feed supplies both sources all severities and clear stays empty" {
    var buffer = try logs.Buffer.init(std.testing.allocator, .{}, &.{});
    defer buffer.deinit();
    try seedFixtureLogs(&buffer);
    try std.testing.expectEqual(@as(usize, 52), buffer.lineCount());
    var severity_seen: [6]bool = @splat(false);
    var stdout_seen = false;
    var stderr_seen = false;
    for (buffer.lines()) |line| {
        severity_seen[@backingInt(line.severity)] = true;
        stdout_seen = stdout_seen or line.source == .stdout;
        stderr_seen = stderr_seen or line.source == .stderr;
    }
    for (severity_seen) |seen| try std.testing.expect(seen);
    try std.testing.expect(stdout_seen and stderr_seen and buffer.errorIds().len > 0);
    buffer.clear();
    try std.testing.expectEqual(@as(usize, 0), buffer.lineCount());
}

test "fixture Alt-F4 requests ordinary close only on modified key down" {
    var events = [_]dvui.Event{.{ .evt = .{ .key = .{ .code = .f4, .action = .down, .mod = .none } } }};
    try std.testing.expect(!fixtureCloseRequested(&events));
    events[0].evt.key.mod = .lalt;
    try std.testing.expect(fixtureCloseRequested(&events));
    events[0].evt.key.action = .up;
    try std.testing.expect(!fixtureCloseRequested(&events));
    events[0].evt.key.action = .down;
    events[0].evt.key.code = .escape;
    try std.testing.expect(!fixtureCloseRequested(&events));
}

test "synthetic owned Java passes actual storage gate and is never reseeded after hide forget or delete" {
    const owned_storage = @import("ui/java_owned_storage.zig");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var f: Fixture = undefined;
    f.allocator = a;
    f.io = io;
    f.paths = try instances.Paths.init(a, io, root);
    defer f.paths.deinit();
    f.java_manager = try java.Manager.init(a, io, root);
    defer f.java_manager.deinit();
    try seedOwnedJava(&f);
    try std.testing.expectEqual(@as(usize, 1), f.java_manager.entries().len);
    const java_path = try a.dupe(u8, f.java_manager.entries()[0].path);
    defer a.free(java_path);
    try owned_storage.check(a, io, f.paths.jdks, java_path);
    try f.java_manager.hide(java_path);
    try seedOwnedJava(&f);
    try std.testing.expectEqual(@as(usize, 0), f.java_manager.entries().len);
    try std.testing.expectEqual(@as(usize, 1), f.java_manager.hiddenEntries().len);
    try f.java_manager.unhide(java_path);
    try f.java_manager.forget(java_path);
    try seedOwnedJava(&f);
    try std.testing.expectEqual(@as(usize, 0), f.java_manager.entries().len);
    try owned_storage.check(a, io, f.paths.jdks, java_path);
    var cancel = std.atomic.Value(bool).init(false);
    try owned_storage.delete(a, io, f.paths.jdks, java_path, &cancel);
    try seedOwnedJava(&f);
    try std.testing.expectEqual(@as(usize, 0), f.java_manager.entries().len);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, java_path, .{ .follow_symlinks = false }));
}

test "world initialization marker preserves a deleted seeded folder and adopts existing configuration" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var f: Fixture = undefined;
    f.allocator = a;
    f.io = io;
    f.paths = try instances.Paths.init(a, io, root);
    defer f.paths.deinit();
    f.configuration = try config.Store.init(a, io, root);
    defer f.configuration.deinit();
    try seedConfiguration(&f.configuration);
    // Migration of an existing fixture config must not invent missing worlds.
    try seedWorlds(&f, false);
    const world_path = try f.paths.instancePath(f.configuration.snapshot().instances[0], "saves/fixture-survival");
    defer a.free(world_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, world_path, .{}));
    var seed_dir = try std.Io.Dir.cwd().openDir(io, f.paths.vela, .{});
    defer seed_dir.close(io);
    try seed_dir.deleteFile(io, fixture_world_seed);
    try seedWorlds(&f, true);
    try std.Io.Dir.cwd().deleteTree(io, world_path);
    try seedWorlds(&f, true);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, world_path, .{}));
}

/// Populate only a JOINed job, using its own arena. This is fixture data,
/// not evidence that the production network catalogue was fetched or parsed.
fn seedFixtureCatalogue(f: *Fixture) !void {
    if (f.library.active != null) return;
    const job = f.library.published orelse return;
    if (job.thread != null) return;
    if (f.library.phase == .failed and job.operation == .catalogue and (if (job.failure) |failure| failure == error.InvalidUrl else false)) {
        // The intentionally disabled fixture transport has now JOINed. Replace
        // its catalogue result only; cancellation/install failures stay visible.
        job.failure = null;
        f.library.failure = null;
        f.library.phase = .complete;
    }
    if (f.library.phase != .complete) return;
    const catalogue: []const games.CatalogEntry = if (f.scene == .@"instance-prepared") &prepared_fixture_catalogue else &fixture_catalogue;
    if (job.available.len == catalogue.len) {
        var matching = true;
        for (catalogue, job.available) |entry, owned| {
            if (!std.mem.eql(u8, entry.id, owned.id) or !std.mem.eql(u8, entry.kind, owned.kind) or !std.mem.eql(u8, entry.release_time, owned.release_time)) matching = false;
        }
        if (matching) return;
    }
    const a = job.arena.allocator();
    const available = try a.alloc(games.CatalogEntry, catalogue.len);
    for (catalogue, available) |entry, *owned| {
        owned.* = .{ .id = try a.dupe(u8, entry.id), .kind = try a.dupe(u8, entry.kind), .release_time = try a.dupe(u8, entry.release_time), .url = try a.dupe(u8, entry.url), .sha1 = entry.sha1 };
    }
    job.available = available;
    f.catalogue_seeded = true;
}

fn fixtureLoaderCatalogue(raw: ?*anyopaque, a: std.mem.Allocator, _: std.Io, base: []const u8, kind: config.Loader, control: instances_manager.Control) !instances_manager.LoaderCatalogue {
    try control.check();
    if (raw) |pointer| {
        const f: *const Fixture = @ptrCast(@alignCast(pointer));
        if (f.scene == .@"instance-prepared") {
            if (!std.mem.eql(u8, base, instance_fixture.base_id) or kind != .forge) return error.FixtureMetadataUnavailable;
            var arena = std.heap.ArenaAllocator.init(a);
            errdefer arena.deinit();
            const owned = arena.allocator();
            const entries = try owned.alloc(instances_manager.LoaderEntry, 1);
            entries[0] = .{ .id = try owned.dupe(u8, instance_fixture.forge_id), .stable = true };
            return .{ .arena = arena, .base = try owned.dupe(u8, base), .kind = kind, .entries = entries };
        }
    }
    if (kind == .vanilla) return error.InvalidLoader;
    var known = false;
    for (fixture_catalogue) |entry| if (std.mem.eql(u8, base, entry.id)) {
        known = true;
        break;
    };
    if (!known) return error.UnknownFixtureMinecraftVersion;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const entries = try owned.alloc(instances_manager.LoaderEntry, 2);
    // One dated synthetic release and one undated release exercise both layouts.
    entries[0] = .{ .id = try std.fmt.allocPrint(owned, "fixture-{s}-stable", .{@tagName(kind)}), .stable = true, .release_time = try owned.dupe(u8, "2025-01-16T12:00:00Z") };
    entries[1] = .{ .id = try std.fmt.allocPrint(owned, "fixture-{s}-preview", .{@tagName(kind)}), .stable = false };
    const owned_base = try owned.dupe(u8, base);
    try control.check();
    return .{ .arena = arena, .base = owned_base, .kind = kind, .entries = entries };
}

fn fixtureSeedExists(dir: std.Io.Dir, io: std.Io, name: []const u8) !bool {
    const stat = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (stat.kind != .file or stat.size != 1) return error.InvalidFixtureSeedMarker;
    return true;
}

const fixture_java_hash: [64]u8 = @splat('0');
const fixture_java_directory = "microsoft-21-linux-x64-" ++ fixture_java_hash;
const fixture_java_seed = "gui-acceptance-owned-java-v1.seeded";
const fixture_world_seed = "gui-acceptance-worlds-v1.seeded";

/// A non-executable marker with a structurally valid ownership receipt. It is
/// deliberately synthetic: no genuine JDK, archive hash or download is claimed.
fn seedOwnedJava(f: *Fixture) !void {
    var seed_dir = try std.Io.Dir.cwd().createDirPathOpen(f.io, f.paths.vela, .{});
    defer seed_dir.close(f.io);
    if (try fixtureSeedExists(seed_dir, f.io, fixture_java_seed)) return;
    const path = try std.fs.path.join(f.allocator, &.{ f.paths.jdks, fixture_java_directory });
    defer f.allocator.free(path);
    var directory = try std.Io.Dir.cwd().createDirPathOpen(f.io, path, .{});
    defer directory.close(f.io);
    try directory.createDirPath(f.io, "bin");
    try writeFixtureFile(directory, f.io, "bin/java", "Synthetic GUI ownership marker; not an executable JDK.\n");
    const receipt = "{\"schema\":1,\"vendor\":\"microsoft\",\"major\":21,\"version\":\"fixture-21\",\"os\":\"linux\",\"arch\":\"x64\",\"url\":\"https://aka.ms/download-jdk/fixture.zip\",\"sha256\":\"" ++ fixture_java_hash ++ "\",\"java\":\"bin/java\"}\n";
    try writeFixtureFile(directory, f.io, ".vela-runtime.json", receipt);
    const java_path = try std.fs.path.join(f.allocator, &.{ path, "bin", "java" });
    defer f.allocator.free(java_path);
    try f.java_manager.addDownloaded(.{ .path = java_path, .major = 21, .architecture = @import("core/java_runtime.zig").host(), .vendor = "Synthetic Fixture Owned Java" });
    // Registration is persistent; this independent marker preserves hide/forget/
    // file-delete outcomes even when no corresponding runtime remains registered.
    try writeFixtureFile(seed_dir, f.io, fixture_java_seed, "1");
}

fn seedFixtureLogs(buffer: *logs.Buffer) !void {
    const severities = [_][]const u8{ "TRACE", "DEBUG", "INFO", "WARN", "ERROR", "FATAL" };
    var row: [192]u8 = undefined;
    for (0..48) |index| {
        const text = try std.fmt.bufPrint(&row, "[12:00:{d:0>2}] [Fixture thread/{s}]: Fixture checkpoint {d:0>2}; offline synthetic log message.\n", .{ index, severities[index % severities.len], index });
        try buffer.feed(if (index % 2 == 0) .stdout else .stderr, text);
    }
    try buffer.feed(.stderr, "[ERROR] Fixture exception context\njava.lang.IllegalStateException: synthetic fixture failure\n    at fixture.Main.run(Main.java:42)\nCaused by: java.io.IOException: offline fixture cause\n");
    try buffer.finish(.stdout);
    try buffer.finish(.stderr);
}

fn fixtureCloseRequested(events: []const dvui.Event) bool {
    for (events) |event| switch (event.evt) {
        .key => |key| if (key.action == .down and key.code == .f4 and key.mod.alt()) return true,
        else => {},
    };
    return false;
}

test "resource GUI preview prepares offline files and joins its held installation on cancel" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const f = Fixture.create(a, io, root, .@"mods-task", .{ .w = 1280, .h = 720 }) catch |err| {
        std.debug.print("resource fixture create: {s}\n", .{@errorName(err)});
        return err;
    };
    defer f.destroy();
    errdefer std.debug.print("resource preview step={d} route={s} task={s} busy={} ready={} blocker={s} failure={s}\n", .{ f.resource_preview_step, @tagName(f.mods_ui.acquisition.route), @tagName(f.mods_ui.acquisition.task_state), f.content.isBusy(), if (f.content.snapshot().proposal) |p| p.ready else false, if (f.content.snapshot().proposal) |p| if (p.blocker) |e| @errorName(e) else "none" else "none", if (f.mods_ui.acquisition.failure) |e| @errorName(e) else "none" });
    var entered = false;
    for (0..5000) |_| {
        try f.tickServices();
        f.mods.tick(&f.content);
        f.mods_ui.acquisition.tick(&f.content, true);
        if (!f.content.isBusy()) f.mods_ui.acquisition.finish(&f.content, true, true);
        if (f.mods_ui.acquisition.failure) |err| return err;
        if (f.mods_ui.acquisition.task_state == .running and f.instance_data.content_entered.load(.acquire) and (if (f.mods_ui.acquisition.task_details) |details| details.file_count > 0 else false)) {
            entered = true;
            break;
        }
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(entered and f.content.isBusy());
    try std.testing.expectEqual(config.Loader.fabric, f.mods_ui.acquisition.instance.?.loader);
    f.content.cancel();
    f.instance_data.releaseHolds();
    f.content.cancelAndJoin();
    try std.testing.expect(!f.content.isBusy());
    try std.testing.expect(f.instance_data.content_released.load(.acquire));
}

test "resource GUI detail previews keep optional and loading metadata isolated from installation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]Panel{ .@"mods-detail-optional", .@"mods-detail-loading" }) |panel| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        const f = try Fixture.create(a, io, root, panel, .{ .w = 1280, .h = 720 });
        defer f.destroy();
        for (0..5000) |_| {
            try f.tickServices();
            f.mods.tick(&f.content);
            f.mods_ui.acquisition.tick(&f.content, true);
            if (!f.content.isBusy()) f.mods_ui.acquisition.finish(&f.content, true, true);
            if (f.mods_ui.acquisition.failure) |err| return err;
            if (f.resource_preview_step == 2) break;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
        try std.testing.expectEqual(@as(u8, 2), f.resource_preview_step);
        // Advance again to apply the fixed loading presentation, then ensure
        // the ordinary page tick cannot turn it into a ready proposal.
        try f.tickServices();
        f.mods_ui.acquisition.tick(&f.content, true);
        const ui = &f.mods_ui.acquisition;
        const detail = ui.frame().?;
        try std.testing.expectEqual(@import("ui/resource_download_state.zig").Route.detail, ui.route);
        try std.testing.expect(!f.content.isBusy() and !ui.confirm_open and ui.pending == null);
        try std.testing.expectEqual(@import("ui/resource_download_state.zig").TaskState.none, ui.task_state);
        // Preparing metadata legitimately acquires the instance lease; no
        // installation report exists and that lease must already be released.
        try std.testing.expect(f.instance_data.content_released.load(.acquire));
        try std.testing.expect(f.content.snapshot().report == null);
        if (panel == .@"mods-detail-optional") {
            const dependencies = detail.version().?.dependencies;
            try std.testing.expectEqual(@as(usize, 2), dependencies.len);
            try std.testing.expectEqual(@import("core/content_providers.zig").DependencyKind.required, dependencies[0].kind);
            try std.testing.expectEqual(@import("core/content_providers.zig").DependencyKind.optional, dependencies[1].kind);
            try std.testing.expect(!detail.choice(1).?.include);
            const found = for (detail.candidates) |candidate| {
                if (std.mem.eql(u8, candidate.project_id, "open-parties-and-claims"))
                    break std.mem.eql(u8, candidate.name, "Open Parties and Claims 0.32.7");
            } else false;
            try std.testing.expect(found and ui.currentProposal(f.content.snapshot()));
        } else {
            try std.testing.expectEqual(@as(usize, 0), detail.candidates.len);
            try std.testing.expect(!ui.proposal_current and !ui.needs_prepare);
            try std.testing.expect(!ui.currentProposal(f.content.snapshot()));
        }
    }
}

fn seedWorlds(f: *Fixture, fresh_configuration: bool) !void {
    var seed_dir = try std.Io.Dir.cwd().createDirPathOpen(f.io, f.paths.vela, .{});
    defer seed_dir.close(f.io);
    if (try fixtureSeedExists(seed_dir, f.io, fixture_world_seed)) return;
    // A root from an older fixture already owns its current worlds. Adopt it
    // without recreating deleted folders or overwriting display/folder renames.
    if (!fresh_configuration) {
        try writeFixtureFile(seed_dir, f.io, fixture_world_seed, "1");
        return;
    }
    const a = f.allocator;
    const document = f.configuration.snapshot();
    if (document.instances.len == 0) return;
    for (document.instances) |instance| {
        const saves = try f.paths.instancePath(instance, "saves");
        defer a.free(saves);
        var dir = try std.Io.Dir.cwd().createDirPathOpen(f.io, saves, .{});
        dir.close(f.io);
    }
    const selected = instances.findById(document, "fixture-primary") orelse return error.FixturePrimaryMissing;
    const preview = try makePreview(a);
    defer a.free(preview);
    for ([_][]const u8{ "fixture-survival", "fixture-creative" }, 0..) |folder, index| {
        const relative = try std.fmt.allocPrint(a, "saves/{s}", .{folder});
        defer a.free(relative);
        const path = try f.paths.instancePath(selected.*, relative);
        defer a.free(path);
        var dir = try std.Io.Dir.cwd().createDirPathOpen(f.io, path, .{});
        defer dir.close(f.io);
        const level = try makeLevelDat(a, if (index == 0) "Fixture Survival" else "Fixture Creative", @intCast(index));
        defer a.free(level);
        try writeFixtureFile(dir, f.io, "level.dat", level);
        try writeFixtureFile(dir, f.io, "icon.png", preview);
    }
    try writeFixtureFile(seed_dir, f.io, fixture_world_seed, "1");
}

fn makeLevelDat(a: std.mem.Allocator, name: []const u8, game_type: i32) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temporary = arena.allocator();
    var version = nbt.builder.Compound.init(temporary);
    try version.add("Name", try nbt.builder.string(temporary, "1.21.4"));
    var data = nbt.builder.Compound.init(temporary);
    try data.add("LevelName", try nbt.builder.string(temporary, name));
    try data.add("LastPlayed", .{ .long = 1_735_689_600_000 });
    try data.add("GameType", .{ .int = game_type });
    try data.add("hardcore", .{ .byte = 0 });
    try data.add("DataVersion", .{ .int = 4189 });
    try data.add("Version", try version.finish());
    var root = nbt.builder.Compound.init(temporary);
    try root.add("Data", try data.finish());
    var options: nbt.Options = .java;
    options.compression = .gzip;
    return nbt.serialize(a, .{ .name = try temporary.dupe(u8, ""), .root = try root.finish() }, options);
}

fn writeFixtureFile(dir: std.Io.Dir, io: std.Io, name: []const u8, bytes: []const u8) !void {
    const file = dir.createFile(io, name, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn makePreview(a: std.mem.Allocator) ![]u8 {
    var pixels: [64 * (1 + 64 * 3)]u8 = undefined;
    for (0..64) |y| {
        const row = y * (1 + 64 * 3);
        pixels[row] = 0;
        for (0..64) |x| {
            const pixel = row + 1 + x * 3;
            const grass = (x / 8 + y / 8) % 2 == 0;
            const shade: u8 = @intCast((x * 3 + y * 5) % 17);
            pixels[pixel] = (if (grass) @as(u8, 63) else @as(u8, 135)) + shade;
            pixels[pixel + 1] = (if (grass) @as(u8, 132) else @as(u8, 142)) + shade;
            pixels[pixel + 2] = (if (grass) @as(u8, 54) else @as(u8, 146)) + shade;
        }
    }
    const compressed = try compression.compress(a, &pixels, .zlib, 64 * 1024);
    defer a.free(compressed);
    var png: std.ArrayList(u8) = .empty;
    errdefer png.deinit(a);
    try png.appendSlice(a, &.{ 137, 80, 78, 71, 13, 10, 26, 10 });
    var header: [13]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], 64, .big);
    std.mem.writeInt(u32, header[4..8], 64, .big);
    header[8] = 8;
    header[9] = 2;
    try pngChunk(a, &png, "IHDR", &header);
    try pngChunk(a, &png, "IDAT", compressed);
    try pngChunk(a, &png, "IEND", &.{});
    return png.toOwnedSlice(a);
}

fn pngChunk(a: std.mem.Allocator, output: *std.ArrayList(u8), kind: *const [4]u8, bytes: []const u8) !void {
    var word: [4]u8 = undefined;
    std.mem.writeInt(u32, &word, @intCast(bytes.len), .big);
    try output.appendSlice(a, &word);
    const start = output.items.len;
    try output.appendSlice(a, kind);
    try output.appendSlice(a, bytes);
    std.mem.writeInt(u32, &word, std.hash.crc.@"CRC-32/ISO-HDLC".hash(output.items[start..]), .big);
    try output.appendSlice(a, &word);
}

test "acceptance fixture exposes direct pages and dialog scenes" {
    for ([_][]const u8{ "home", "versions", "more", "settings", "theme", "java", "servers", "logs", "worlds", "instances", "mods", "mods-download", "mods-download-scroll", "mods-detail-slow", "mods-detail", "mods-detail-optional", "mods-detail-loading", "mods-confirm", "mods-task", "mods-task-complete", "mods-task-failed", "player", "account-add", "shutdown" }) |name|
        try std.testing.expect(std.meta.stringToEnum(Panel, name) != null);
    try std.testing.expect(std.meta.stringToEnum(Panel, "preview") == null);
}

test "direct preview scenes initialize target page and modal without input" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const cases = [_]struct { scene: Panel, expected: state.Panel, editor_open: bool = false }{
        .{ .scene = .versions, .expected = .versions },
        .{ .scene = .more, .expected = .more },
        .{ .scene = .theme, .expected = .more },
        .{ .scene = .@"account-add", .expected = .players, .editor_open = true },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        const f = try Fixture.create(a, io, root, case.scene, .{ .w = 1280, .h = 720 });
        defer f.destroy();
        try std.testing.expectEqual(case.expected, f.model.panel);
        if (case.scene == .theme) {
            try std.testing.expectEqual(state.Category.theme, f.model.category);
            try std.testing.expect(f.appearance.picker == &f.picker);
            try std.testing.expect(!f.appearance.dirty());
        }
        try std.testing.expectEqual(case.editor_open, f.accounts_ui.editor_open);
        try std.testing.expect(f.accounts_ui.pending == null);
        try std.testing.expect(f.accounts_ui.draft.id == null);
    }
}

test "acceptance private descriptors and clients pass actual installed receipt inspection" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var f: Fixture = undefined;
    f.allocator = a;
    f.io = io;
    f.paths = try instances.Paths.init(a, io, root);
    defer f.paths.deinit();
    f.configuration = try config.Store.init(a, io, root);
    defer f.configuration.deinit();
    try seedConfiguration(&f.configuration);
    try seedGames(&f);
    var coordinator = instance_leases.Coordinator.init(io);
    const mutation = coordinator.mutation(0);
    for (f.configuration.snapshot().instances) |instance| {
        try mutation.acquire(instance.id);
        defer mutation.release(instance.id);
        var proof = try instance_tx.inspectInstalled(a, io, root, instance, .{ .lease = .{ .context = mutation, .recheck = instance_leases.Mutation.recheckCallback } });
        defer proof.deinit();
        try std.testing.expectEqualStrings(instance.name, proof.instance.name);
        try std.testing.expectEqualStrings("1.21.4", proof.instance.minecraft_version);
        try std.testing.expectEqual(config.Loader.vanilla, proof.instance.loader);
    }
}

test "acceptance account seed uses real offline identity publication and selection" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var f: Fixture = undefined;
    f.io = io;
    var store = try config.Store.init(a, io, root);
    var store_open = true;
    defer if (store_open) store.deinit();
    try seedConfiguration(&store);
    var manager = try accounts_manager.Manager.initWithOptions(a, io, .{ .root = root, .fixture = .{
        .transport = .{ .ctx = &f, .kind = .fixture, .supports_post = true, .request = disabledAuthRequest },
        .store = .{ .ctx = &f, .vtable = &disabled_vault },
        .entropy = .{ .ctx = &f, .fill = fixtureEntropy },
        .journal = .{ .ctx = &f, .stage = disabledJournalChange, .remove = disabledJournalChange, .references = emptyJournalReferences },
    } });
    defer manager.deinit();
    try seedOfflineAccount(&manager, &store);
    const selected = accounts_manager.findAccount(store.snapshot(), store.snapshot().selected_account.?) orelse return error.FixtureAccountMissing;
    const expected = try accounts_manager.offlineUuid("FixturePlayer");
    try std.testing.expectEqualStrings(&expected, selected.uuid);
    try std.testing.expectEqual(config.AccountKind.offline, selected.kind);
    try std.testing.expect(std.mem.startsWith(u8, selected.id, "offline-"));
    try seedOfflineAccount(&manager, &store);
    try std.testing.expectEqual(@as(usize, 1), store.snapshot().accounts.len);
    try seedConfiguration(&store);
    const selected_id = try a.dupe(u8, store.snapshot().selected_account.?);
    defer a.free(selected_id);
    store.deinit();
    store_open = false;
    var reloaded = try config.Store.init(a, io, root);
    defer reloaded.deinit();
    try std.testing.expectEqualStrings(selected_id, reloaded.snapshot().selected_account.?);
}

test "acceptance fixture adapters never return successful install network launch or vault work" {
    const a = std.testing.allocator;
    var marker: u8 = 0;
    var cancel = std.atomic.Value(bool).init(false);
    const control: instances_manager.Control = .{ .cancel = &cancel, .task = null };
    try std.testing.expectError(error.FixtureInstallationDisabled, disabledInstanceInstall(null, a, std.testing.io, undefined, control));
    try std.testing.expectError(error.FixtureNetworkDisabled, disabledLoaderCatalogue(null, a, std.testing.io, "1.21.4", .fabric, control));
    try std.testing.expectError(error.FixtureNetworkDisabled, disabledContentHttp(null, a, std.testing.io, undefined));
    try std.testing.expectError(error.FixtureInstallationDisabled, disabledContentMutation(null, .before_backup, 0));
    try std.testing.expectError(error.FixtureLaunchDisabled, disabledLaunchAcquire(null, "fixture-primary"));
    try std.testing.expectError(error.TransportFailure, disabledAuthRequest(&marker, a, undefined));
    const vault: credentials.Store = .{ .ctx = &marker, .vtable = &disabled_vault };
    try std.testing.expectError(error.Unavailable, vault.get(a, "00000000000000000000000000000000"));
    cancel.store(true, .release);
    try std.testing.expectError(error.Canceled, disabledInstanceInstall(null, a, std.testing.io, undefined, control));
}

test "acceptance fixture restricts viewport to approved dimensions" {
    try std.testing.expectEqual(@as(f32, 640), (try parseViewport("640x400")).w);
    try std.testing.expectEqual(@as(f32, 400), (try parseViewport("640x400")).h);
    try std.testing.expectEqual(@as(f32, 1280), (try parseViewport("1280x720")).w);
    try std.testing.expectError(error.InvalidFixtureViewport, parseViewport("640x401"));
    try std.testing.expectError(error.InvalidFixtureViewport, parseViewport("640x400/../../"));
}

test "acceptance fixture seeds twenty active and three terminal tasks" {
    var registry = tasks.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try seedTasks(std.testing.allocator, &registry);
    const entries = registry.tasks();
    try std.testing.expectEqual(@as(usize, 23), entries.len);
    for (entries[0..20], 0..) |task, index| {
        try std.testing.expectEqual(tasks.State.running, task.state);
        try std.testing.expectEqual(@as(u64, index + 1), task.id);
        try std.testing.expectEqual(@as(?u64, 67_108_864), task.progress().total);
    }
    try std.testing.expectEqual(tasks.State.succeeded, entries[20].state);
    try std.testing.expectEqual(tasks.State.failed, entries[21].state);
    try std.testing.expectEqual(tasks.State.canceled, entries[22].state);
}

fn testFixtureTasksRunning(f: *Fixture) !void {
    const entries = f.registry.tasks();
    try std.testing.expect(entries.len >= 23);
    for (entries[0..20], 0..) |task, index| {
        try std.testing.expectEqual(@as(u64, index + 1), task.id);
        try std.testing.expectEqual(tasks.State.running, task.state);
    }
}

fn testFixturePrimaryWorlds(f: *Fixture) !void {
    const snapshot = f.worlds.snapshot();
    try std.testing.expect(!snapshot.worker_active and !snapshot.loading);
    try std.testing.expect(snapshot.failure == null);
    try std.testing.expectEqualStrings("fixture-primary", snapshot.instance.?.id);
    try std.testing.expectEqual(@as(usize, 2), snapshot.worlds.len);
    try std.testing.expectEqual(@as(usize, 2), snapshot.previews.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.backups.len);
    for ([_][]const u8{ "fixture-survival", "fixture-creative" }, 0..) |folder, index| {
        var found_world = false;
        for (snapshot.worlds) |world| {
            if (!std.mem.eql(u8, folder, world.folder)) continue;
            found_world = true;
            try std.testing.expect(world.metadata_status == .valid);
            const name = if (index == 0) "Fixture Survival" else "Fixture Creative";
            try std.testing.expectEqualStrings(name, world.displayName());
            try std.testing.expectEqualStrings(name, world.metadata.level_name.?);
            try std.testing.expectEqual(@as(?i32, @intCast(index)), world.metadata.game_type);
            try std.testing.expectEqualStrings("1.21.4", world.metadata.version_name.?);
            try std.testing.expectEqual(@as(?i32, 4189), world.metadata.data_version);
        }
        try std.testing.expect(found_world);
        var found_preview = false;
        for (snapshot.previews) |preview| {
            if (!std.mem.eql(u8, folder, preview.folder)) continue;
            found_preview = true;
            try std.testing.expect(preview.png.len >= 8);
            try std.testing.expectEqualSlices(u8, &.{ 137, 80, 78, 71, 13, 10, 26, 10 }, preview.png[0..8]);
        }
        try std.testing.expect(found_preview);
    }
    try testFixtureTasksRunning(f);
}

// Select through the production manager; its worker acquires the real lease
// and holds it until JOIN, independent of the deleted pack-review UI.
fn testSelectContent(f: *Fixture) !void {
    const doc = f.configuration.snapshot();
    const row = if (doc.selected_instance) |id| instances.findById(doc, id) else null;
    try f.content.select(if (row) |value| value.* else null);
}

test "acceptance Worlds refresh waits for real Content JOIN across primary and selected copy" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const f = try Fixture.create(a, io, root, .worlds, .{ .w = 1280, .h = 720 });
    defer f.destroy();
    try testFixtureTasksRunning(f);

    f.instance_data.hold_content.store(true, .release);
    f.worlds_ui.setPageActive(true);
    worlds_view.finish(&f.worlds_ui, &f.configuration, &f.worlds);
    try testSelectContent(f);
    try testWaitFixture(f, .content_held);
    try std.testing.expect(f.content.isBusy());
    try std.testing.expect(f.instance_data.content_entered.load(.acquire));
    try std.testing.expectError(error.InstanceBusy, f.coordinator.reserveLaunch("fixture-primary"));
    try std.testing.expect(f.worlds.pending != null);
    try std.testing.expect(f.worlds.active == null);
    try std.testing.expect(f.worlds.snapshot().worker_active and f.worlds.snapshot().loading);
    try std.testing.expect(f.worlds.snapshot().failure == null);
    try testFixtureTasksRunning(f);

    f.instance_data.hold_content.store(false, .release);
    try testWaitFixture(f, .content_idle);
    // Content releases its scope during JOIN; Coordinator observes it next tick.
    try f.tickServices();
    try testWaitFixture(f, .worlds_idle);
    try f.tickServices();
    try std.testing.expect(f.worlds.pending == null);
    try std.testing.expect(f.instance_data.content_released.load(.acquire));
    try testFixturePrimaryWorlds(f);

    f.instance_data.content_entered.store(false, .release);
    f.instance_data.content_released.store(false, .release);
    f.instance_data.hold_content.store(true, .release);
    try f.instance_manager.select(&f.configuration, "fixture-copy");
    worlds_view.finish(&f.worlds_ui, &f.configuration, &f.worlds);
    try testSelectContent(f);
    try testWaitFixture(f, .content_held);
    try std.testing.expect(f.content.isBusy());
    try std.testing.expect(f.instance_data.content_entered.load(.acquire));
    try std.testing.expectError(error.InstanceBusy, f.coordinator.reserveLaunch("fixture-copy"));
    try std.testing.expectEqualStrings("fixture-copy", f.content.snapshot().instance.?.id);
    try std.testing.expectEqualStrings("fixture-copy", f.worlds.snapshot().instance.?.id);
    try std.testing.expect(f.worlds.pending != null);
    try std.testing.expect(f.worlds.active == null);
    try std.testing.expect(f.worlds.snapshot().worker_active and f.worlds.snapshot().loading);
    try std.testing.expect(f.worlds.snapshot().failure == null);
    f.instance_data.hold_content.store(false, .release);
    try testWaitFixture(f, .content_idle);
    try f.tickServices();
    try testWaitFixture(f, .worlds_idle);
    try f.tickServices();
    const copy = f.worlds.snapshot();
    try std.testing.expect(f.worlds.pending == null);
    try std.testing.expect(!copy.worker_active and !copy.loading);
    try std.testing.expect(copy.failure == null);
    try std.testing.expectEqualStrings("fixture-copy", copy.instance.?.id);
    try std.testing.expectEqual(@as(usize, 0), copy.worlds.len);
    try std.testing.expectEqual(@as(usize, 0), copy.previews.len);
    try std.testing.expectEqual(@as(usize, 0), copy.backups.len);
    try std.testing.expect(f.instance_data.content_released.load(.acquire));
    try testFixtureTasksRunning(f);
}

test "acceptance Worlds refresh reads during matching and unrelated launch while mutations remain guarded" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const f = try Fixture.create(a, io, root, .worlds, .{ .w = 1280, .h = 720 });
    defer f.destroy();
    f.worlds_ui.setPageActive(true);
    worlds_view.finish(&f.worlds_ui, &f.configuration, &f.worlds);
    try testSelectContent(f);
    try testWaitFixture(f, .content_idle);
    try f.tickServices();
    try testWaitFixture(f, .worlds_idle);
    try f.tickServices();
    try testFixturePrimaryWorlds(f);

    try f.coordinator.reserveLaunch("fixture-primary");
    {
        defer f.coordinator.releaseLaunch();
        f.worlds_ui.refresh_queued = true;
        worlds_view.finish(&f.worlds_ui, &f.configuration, &f.worlds);
        try testWaitFixture(f, .worlds_idle);
        try testFixturePrimaryWorlds(f);
        try std.testing.expect(f.worlds.active == null and f.worlds.pending == null);
        try std.testing.expect(f.worlds.isRunning("fixture-primary"));
        try std.testing.expectError(error.InstanceRunning, f.worlds.perform(.{ .backup = "fixture-survival" }));
        try std.testing.expect(f.worlds.active == null and f.worlds.pending == null);
        // Completed reads remain idle while the matching game continues running.
        for (0..3) |_| try f.tickServices();
        try testFixturePrimaryWorlds(f);
        try std.testing.expect(f.worlds.active == null and f.worlds.pending == null);
    }
    try f.tickServices();
    f.worlds_ui.refresh_queued = true;
    worlds_view.finish(&f.worlds_ui, &f.configuration, &f.worlds);
    try testWaitFixture(f, .worlds_idle);
    try f.tickServices();
    try testFixturePrimaryWorlds(f);

    try f.coordinator.reserveLaunch("fixture-copy");
    defer f.coordinator.releaseLaunch();
    f.worlds_ui.refresh_queued = true;
    worlds_view.finish(&f.worlds_ui, &f.configuration, &f.worlds);
    try testWaitFixture(f, .worlds_idle);
    try f.tickServices();
    try testFixturePrimaryWorlds(f);
}

test "acceptance world fixture parses with production metadata reader" {
    const a = std.testing.allocator;
    const bytes = try makeLevelDat(a, "Fixture Survival", 0);
    defer a.free(bytes);
    var metadata = try @import("core/worlds_metadata.zig").parse(a, bytes);
    defer metadata.deinit(a);
    try std.testing.expectEqualStrings("Fixture Survival", metadata.level_name.?);
    try std.testing.expectEqualStrings("1.21.4", metadata.version_name.?);
    try std.testing.expectEqual(@as(?i32, 4189), metadata.data_version);
    try std.testing.expectEqual(@as(?i32, 0), metadata.game_type);
}

test "acceptance PNG has valid CRCs and a bounded nonblank pixel payload" {
    const a = std.testing.allocator;
    const png = try makePreview(a);
    defer a.free(png);
    try std.testing.expectEqualSlices(u8, &.{ 137, 80, 78, 71, 13, 10, 26, 10 }, png[0..8]);
    var offset: usize = 8;
    var width: usize = 0;
    var height: usize = 0;
    var channels: usize = 0;
    var saw_pixels = false;
    while (offset < png.len) {
        try std.testing.expect(png.len - offset >= 12);
        const length: usize = std.mem.readInt(u32, png[offset..][0..4], .big);
        const data_start = offset + 8;
        const data_end = data_start + length;
        try std.testing.expect(data_end + 4 <= png.len);
        try std.testing.expectEqual(std.hash.crc.@"CRC-32/ISO-HDLC".hash(png[offset + 4 .. data_end]), std.mem.readInt(u32, png[data_end..][0..4], .big));
        const kind = png[offset + 4 .. offset + 8];
        if (std.mem.eql(u8, kind, "IHDR")) {
            try std.testing.expectEqual(@as(usize, 13), length);
            width = std.mem.readInt(u32, png[data_start..][0..4], .big);
            height = std.mem.readInt(u32, png[data_start + 4 ..][0..4], .big);
            try std.testing.expectEqual(@as(usize, 64), width);
            try std.testing.expectEqual(@as(usize, 64), height);
            try std.testing.expectEqual(@as(u8, 8), png[data_start + 8]);
            try std.testing.expectEqual(@as(u8, 2), png[data_start + 9]);
            try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, png[data_start + 10 .. data_end]);
            channels = 3;
        }
        if (std.mem.eql(u8, kind, "IDAT")) {
            try std.testing.expectEqual(@as(usize, 3), channels);
            const row_stride = 1 + width * channels;
            const expected_size = height * row_stride;
            // The bounded reader needs one byte of allowance to observe EOF at an exact limit.
            const pixels = try compression.decompress(a, png[data_start..data_end], .zlib, expected_size + 1, true);
            defer a.free(pixels);
            try std.testing.expectEqual(expected_size, pixels.len);
            for (0..height) |row| try std.testing.expectEqual(@as(u8, 0), pixels[row * row_stride]);
            try std.testing.expect(pixels[1] != pixels[1 + 8 * channels]);
            saw_pixels = true;
        }
        offset = data_end + 4;
    }
    try std.testing.expect(saw_pixels);
    try std.testing.expectEqual(png.len, offset);
}

test "acceptance CF vault is memory-only and wipes replaced removed and retired keys" {
    var vault: FixtureVault = .{};
    defer vault.deinit();
    const store = vault.store();
    const reference = "0123456789abcdef0123456789abcdef";
    const long: [512]u8 = @splat('x');
    try store.put(reference, &long);
    const short: [3]u8 = @splat('y');
    try store.put(reference, &short);
    const slot = vault.find(reference).?;
    for (slot.bytes[short.len..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    var secret = try store.get(std.testing.allocator, reference);
    defer secret.deinit();
    try std.testing.expectEqualSlices(u8, &short, secret.bytes);
    try store.delete(reference);
    for (slot.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectError(error.NotFound, store.get(std.testing.allocator, reference));
    try store.put(reference, &long);
    vault.deinit();
    for (vault.slots) |retired| {
        try std.testing.expect(retired.reference == null);
        try std.testing.expectEqual(@as(usize, 0), retired.len);
        for (retired.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

const FixtureWait = enum { content_idle, content_held, worlds_idle, installer_held, complete, canceled, failed };
const FixtureCheckpoint = enum { setup, wait_tick, wait_terminal, wait_timeout, proof_prepare, binding, role_validation, canceled_probe, no_publication, cancel_join, publication_join };
fn testFixtureContext(f: *Fixture, checkpoint: FixtureCheckpoint, wanted: ?FixtureWait) void {
    const core = f.creation_core.snapshot();
    std.debug.print("acceptance fixture context: checkpoint={s} wait={s} creation={s} failure={s}\n", .{ @tagName(checkpoint), if (wanted) |value| @tagName(value) else "none", @tagName(core.phase), if (core.failure) |failure| @errorName(failure) else "none" });
}

fn testFixtureFailure(f: *Fixture, checkpoint: FixtureCheckpoint, wanted: ?FixtureWait, err: anyerror) void {
    const core = f.creation_core.snapshot();
    std.debug.print("acceptance fixture failure: checkpoint={s} wait={s} error={s} creation={s} failure={s}\n", .{ @tagName(checkpoint), if (wanted) |value| @tagName(value) else "none", @errorName(err), @tagName(core.phase), if (core.failure) |failure| @errorName(failure) else "none" });
}
fn testWaitFixture(f: *Fixture, wanted: FixtureWait) !void {
    const deadline = std.Io.Clock.awake.now(f.io).nanoseconds + 10 * std.time.ns_per_s;
    while (std.Io.Clock.awake.now(f.io).nanoseconds < deadline) {
        try f.tickServices();
        if (f.creation_core.snapshot().phase == .awaiting_publication) try f.creation_core.publishOrdinary(f.creationServices(), true);
        const core = f.creation_core.snapshot();
        if (core.phase == .failed and wanted != .failed) return core.failure orelse error.FixtureCreationFailed;
        const done = switch (wanted) {
            .content_idle => !f.content.isBusy(),
            .content_held => f.instance_data.content_entered.load(.acquire),
            .worlds_idle => !f.worlds.snapshot().worker_active,
            .installer_held => f.instance_data.installer_entered.load(.acquire),
            .complete => core.phase == .complete,
            .canceled => core.phase == .canceled,
            .failed => core.phase == .failed,
        };
        if (done) return;
        std.Thread.yield() catch {};
    }
    testFixtureFailure(f, .wait_timeout, wanted, error.TestTimeout);
    return error.TestTimeout;
}

test "seeded Java transfer reads coherent Task details and JOIN clears terminal speed" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const f = try Fixture.create(a, io, root, .java, .{ .w = 1280, .h = 720 });
    defer f.destroy();
    try f.seedJavaProgress();
    const controller = &f.java_download_controller;
    const task = controller.active.?.task.?;
    const known = controller.snapshot();
    try std.testing.expectEqual(@as(u64, 10 * 1024 * 1024), known.progress.completed);
    try std.testing.expectEqual(@as(?u64, 100 * 1024 * 1024), known.progress.total);
    try std.testing.expectEqual(@as(f64, 1.5 * 1024 * 1024), known.bytes_per_second);
    task.reportDetails(javaProgressDetails(.downloading, false));
    const unknown = controller.snapshot();
    try std.testing.expectEqual(@as(?u64, null), unknown.progress.total);
    try std.testing.expectEqual(known.progress.completed, unknown.progress.completed);
    try std.testing.expectEqual(known.bytes_per_second, unknown.bytes_per_second);
    task.reportDetails(javaProgressDetails(.verifying, true));
    try std.testing.expectEqual(known.bytes_per_second, task.details().bytes_per_second);
    try std.testing.expectEqual(@as(f64, 0), controller.snapshot().bytes_per_second);
    task.reportDetails(javaProgressDetails(.downloading, true));
    controller.cancelAndJoin(&f.java_manager);
    try std.testing.expectEqual(java_download.Phase.canceled, controller.snapshot().phase);
    try std.testing.expectEqual(@as(f64, 0), controller.snapshot().bytes_per_second);
    try std.testing.expectEqual(@as(f64, 0), task.details().bytes_per_second);
    try std.testing.expect(controller.active == null and controller.published.?.thread == null);
    try std.testing.expect(controller.published.?.task == null);
}

test "acceptance Root ticks each ordinary component once and never globally selects content" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const f = try Fixture.create(a, io, root, .home, .{ .w = 1280, .h = 720 });
    defer f.destroy();
    // Keep the genuine downloader install directory; do not fake base-root admission.
    try std.testing.expectEqualStrings(f.paths.jdks, f.java_download_controller.root);
    try std.testing.expect(f.content.paths == &f.paths);
    const before = f.ticks;
    try f.tickServices();
    try std.testing.expect(f.content.snapshot().instance == null);
    try std.testing.expectEqual(before.creation_core + 1, f.ticks.creation_core);
    try std.testing.expectEqual(before.content + 1, f.ticks.content);
    try std.testing.expectEqual(before.java + 1, f.ticks.java);
    try std.testing.expectEqual(before.java_download + 1, f.ticks.java_download);
    try std.testing.expectEqual(before.instances + 1, f.ticks.instances);
    const mutation_guard = f.content.options.fixture_fault.?;
    try std.testing.expectError(error.FixtureInstallationDisabled, mutation_guard.boundary(mutation_guard.context, .before_backup, 0));
    const primary = instances.findById(f.configuration.snapshot(), "fixture-primary").?;
    for ([_][]const u8{ "fixture-survival", "fixture-creative" }, 0..) |folder, index| {
        const relative = try std.fmt.allocPrint(a, "saves/{s}/level.dat", .{folder});
        defer a.free(relative);
        const path = try f.paths.instancePath(primary.*, relative);
        defer a.free(path);
        const actual = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
        defer a.free(actual);
        const expected = try makeLevelDat(a, if (index == 0) "Fixture Survival" else "Fixture Creative", @intCast(index));
        defer a.free(expected);
        try std.testing.expectEqualSlices(u8, expected, actual);
    }
}

test "acceptance selected instance copy while real content lease is held does not fail Root frame" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const f = try Fixture.create(a, io, root, .instances, .{ .w = 1280, .h = 720 });
    defer f.destroy();
    f.instance_data.hold_content.store(true, .release);
    try f.content.select(instances.findById(f.configuration.snapshot(), "fixture-primary").?.*);
    try testWaitFixture(f, .content_held);
    try std.testing.expect(f.content.isBusy());
    try f.instance_manager.select(&f.configuration, "fixture-copy");
    const before = f.ticks.content;
    try f.tickServices();
    try std.testing.expectEqual(before + 1, f.ticks.content);
    try std.testing.expectEqualStrings("fixture-copy", f.configuration.snapshot().selected_instance.?);
    try std.testing.expectEqualStrings("fixture-primary", f.content.snapshot().instance.?.id);
    f.instance_data.hold_content.store(false, .release);
    try testWaitFixture(f, .content_idle);
    try std.testing.expect(f.instance_data.content_released.load(.acquire));
    try f.tickServices();
    try std.testing.expectEqualStrings("fixture-primary", f.content.snapshot().instance.?.id);
}

test "acceptance Root teardown releases held real lease and joins worker before freeing context" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const f = try Fixture.create(a, io, root, .instances, .{ .w = 1280, .h = 720 });
    var destroyed = false;
    defer if (!destroyed) f.destroy();
    var released: std.atomic.Value(bool) = .init(false);
    f.instance_data.content_release_observer = &released;
    f.instance_data.hold_content.store(true, .release);
    try f.content.select(instances.findById(f.configuration.snapshot(), "fixture-primary").?.*);
    try testWaitFixture(f, .content_held);
    f.destroy();
    destroyed = true;
    try std.testing.expect(released.load(.acquire));
}

fn testStartPrepared(f: *Fixture) !void {
    try std.testing.expect(f.scene == .@"instance-prepared");
    try f.creation_core.start(.{ .instance = .{ .id = "fixture-synthetic", .name = instance_fixture.label, .minecraft_version = instance_fixture.base_id, .loader = .forge, .loader_version = instance_fixture.forge_id }, .preparation_generation = 1, .environment = try instance_fixture.environment() }, f.creationServices());
}

fn testPrimaryWorld(f: *Fixture) ![]u8 {
    const row = instances.findById(f.configuration.snapshot(), "fixture-primary") orelse return error.FixturePrimaryMissing;
    const path = try f.paths.instancePath(row.*, "saves/fixture-survival/level.dat");
    defer f.allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(f.io, path, f.allocator, .limited(1024 * 1024));
}
fn testPreparedNoPublication(f: *Fixture, initial_count: usize) !void {
    try std.testing.expectEqual(initial_count, f.configuration.snapshot().instances.len);
    try std.testing.expect(f.content.snapshot().proposal == null);
    try std.testing.expectEqual(@as(usize, 0), f.instance_data.http_requests.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), f.instance_data.jvm_invocations.load(.monotonic));
}

test "prepared ordinary Root scene derives genuine 17/8 before writes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const f = try Fixture.createScene(a, io, root, .instances, .{ .w = 1280, .h = 720 }, .@"instance-prepared");
    defer f.destroy();
    errdefer testFixtureContext(f, .setup, null);
    try std.testing.expectEqual(instance_fixture.Scene.@"instance-prepared", std.meta.stringToEnum(instance_fixture.Scene, "instance-prepared").?);
    var catalogue_cancel = std.atomic.Value(bool).init(false);
    var catalogue = try fixtureLoaderCatalogue(f, a, io, instance_fixture.base_id, .forge, .{ .cancel = &catalogue_cancel });
    defer catalogue.deinit();
    try std.testing.expectEqual(@as(usize, 1), catalogue.entries.len);
    try std.testing.expectEqualStrings(instance_fixture.forge_id, catalogue.entries[0].id);
    const data = f.instance_data.prepared.?;
    try std.testing.expect(!std.mem.eql(u8, data.java17_path, data.java8_path));
    try std.testing.expect(std.mem.startsWith(u8, data.java17_path, f.paths.jdks));
    try std.testing.expect(std.mem.startsWith(u8, data.java8_path, f.paths.jdks));
    try std.testing.expect(std.mem.eql(u8, f.java_download_controller.root, f.paths.jdks));
    try f.armInstanceScene(.installer);
    try testStartPrepared(f);
    try testWaitFixture(f, .installer_held);
    try std.testing.expect(f.instance_data.validated_roles.load(.acquire));
    try std.testing.expect(f.instance_data.runtime_marker_probed.load(.acquire));
    try std.testing.expect(f.instance_data.installer_marker_probed.load(.acquire));
    try std.testing.expect(f.creation_core.snapshot().instance.?.java_path == null);
    try std.testing.expect(f.instance_data.proof_borrowed.load(.acquire));
    try std.testing.expect(!f.instance_data.staged.load(.acquire));
    try std.testing.expect(f.instance_data.synthetic_requests.load(.monotonic) > 0);
    f.creation_core.cancel(f.creationServices());
    try testWaitFixture(f, .canceled);
    try std.testing.expect(!f.instance_data.proof_borrowed.load(.acquire));
    try std.testing.expect(!f.instance_manager.isBusy());
}

test "prepared ordinary Root publishes materialized synthetic game without content adoption" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const f = try Fixture.createScene(a, io, root, .instances, .{ .w = 1280, .h = 720 }, .@"instance-prepared");
    defer f.destroy();
    errdefer testFixtureContext(f, .publication_join, null);
    const initial_count = f.configuration.snapshot().instances.len;
    const before = try testPrimaryWorld(f);
    defer a.free(before);
    try testStartPrepared(f);
    try testWaitFixture(f, .complete);
    try std.testing.expectEqual(initial_count + 1, f.configuration.snapshot().instances.len);
    const row = f.creation_core.snapshot().instance.?;
    try std.testing.expect(!std.mem.eql(u8, row.id, "fixture-primary"));
    try std.testing.expect(!std.mem.eql(u8, row.id, "fixture-copy"));
    try std.testing.expectEqualStrings(instance_fixture.base_id, row.minecraft_version);
    try std.testing.expectEqual(config.Loader.forge, row.loader);
    try std.testing.expectEqualStrings(instance_fixture.forge_id, row.loader_version.?);
    try std.testing.expect(row.java_path == null);
    const saved = instances.findById(f.configuration.snapshot(), row.id) orelse return error.FixtureCreatedInstanceMissing;
    try std.testing.expect(saved.java_path == null);
    try std.testing.expect(f.content.snapshot().proposal == null);
    try std.testing.expect(f.instance_data.validated_roles.load(.acquire));
    try std.testing.expect(f.instance_data.installer_exited.load(.acquire));
    try std.testing.expect(!f.instance_data.proof_borrowed.load(.acquire));
    const receipt_path = try f.paths.instancePath(row, ".vela-loader.json");
    defer a.free(receipt_path);
    const receipt = try std.Io.Dir.cwd().readFileAlloc(io, receipt_path, a, .limited(8 * 1024 * 1024));
    defer a.free(receipt);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, receipt, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(row.id, parsed.value.object.get("instance_id").?.string);
    try std.testing.expect(parsed.value.object.get("artifact_bindings").?.array.items.len == 1);
    const client_name = try std.fmt.allocPrint(a, "{s}.jar", .{row.name});
    defer a.free(client_name);
    try std.testing.expectEqualStrings(client_name, parsed.value.object.get("client_jar").?.string);
    const client_path = try f.paths.instancePath(row, client_name);
    defer a.free(client_path);
    const client = try std.Io.Dir.cwd().readFileAlloc(io, client_path, a, .limited(8 * 1024 * 1024));
    defer a.free(client);
    try std.testing.expectEqualSlices(u8, f.instance_data.prepared.?.client_bytes, client);
    try std.testing.expectEqual(@as(i64, @intCast(client.len)), parsed.value.object.get("client_size").?.integer);
    var client_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(client, &client_digest, .{});
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(&client_digest, .lower), parsed.value.object.get("client_sha256").?.string);
    const cache_path = try f.paths.instancePath(row, ".cache");
    defer a.free(cache_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, cache_path, .{ .follow_symlinks = false }));
    const descriptor_name = try std.fmt.allocPrint(a, "{s}.json", .{row.name});
    defer a.free(descriptor_name);
    const descriptor_path = try f.paths.instancePath(row, descriptor_name);
    defer a.free(descriptor_path);
    const descriptor = try std.Io.Dir.cwd().readFileAlloc(io, descriptor_path, a, .limited(8 * 1024 * 1024));
    defer a.free(descriptor);
    var version = try @import("core/minecraft/metadata/root.zig").version.parseSlice(a, descriptor);
    defer version.deinit();
    try std.testing.expectEqualStrings(row.name, version.value.id);
    try std.testing.expectEqual(@as(u64, 17), @import("core/minecraft/metadata/root.zig").version.requiredJavaMajor(version.value));
    const after = try testPrimaryWorld(f);
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    try std.testing.expectEqual(@as(usize, 0), f.instance_data.http_requests.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), f.instance_data.jvm_invocations.load(.monotonic));
}

test "prepared genuine owner rejects root id name generation loader environment and swapped Java roles before writes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Checkpoint = enum { fixture_setup, proof_factory, requirements, binding, replay, table_binding, table_replay, missing_probes, runtime_probe, installer_probe, positive_request, explicit_runtime, swapped_installer, swapped_runtime, changed_marker, fresh_preparation, canceled_probe, no_publication };
    const Wrong = enum { root, id, name, generation, loader, environment };
    var checkpoint: Checkpoint = .fixture_setup;
    var wrong_case: ?Wrong = null;
    errdefer std.debug.print("prepared rejection failure: checkpoint={s} case={s}\n", .{ @tagName(checkpoint), if (wrong_case) |which| @tagName(which) else "none" });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const f = try Fixture.createScene(a, io, root, .instances, .{ .w = 1280, .h = 720 }, .@"instance-prepared");
    defer f.destroy();
    const initial_count = f.configuration.snapshot().instances.len;
    var cancel: std.atomic.Value(bool) = .init(false);
    const target: @import("core/loaders/install.zig").MetadataTarget = .{ .root = f.paths.root, .instance_id = "synthetic-proof", .instance_name = "SyntheticMaterialization-proof", .generation = 9, .selection = .{ .kind = .forge, .base_id = instance_fixture.base_id, .loader_id = instance_fixture.forge_id }, .environment = try instance_fixture.environment() };
    checkpoint = .proof_factory;
    var proof = try instance_fixture.prepareProof(&f.instance_data, a, io, target, &cancel);
    defer proof.deinit();
    checkpoint = .requirements;
    try std.testing.expectEqual(@as(u64, 17), proof.requirements.runtime_major);
    try std.testing.expectEqual(@as(u64, 8), proof.requirements.installer_major);
    checkpoint = .binding;
    try proof.validateBinding(a, io, target);
    checkpoint = .replay;
    try instance_fixture.replayProof(&proof, a, io, target, &cancel);
    for (std.enums.values(Wrong)) |which| {
        wrong_case = which;
        var wrong = target;
        switch (which) {
            .root => wrong.root = "/fixture-foreign-root",
            .id => wrong.instance_id = "foreign-id",
            .name => wrong.instance_name = "foreign-name",
            .generation => wrong.generation += 1,
            .loader => wrong.selection.loader_id = "1.7.10-foreign",
            .environment => wrong.environment.arch = "foreign",
        }
        const expected: anyerror = if (which == .generation) error.PreparedMetadataGenerationMismatch else error.PreparedMetadataMismatch;
        checkpoint = .table_binding;
        try std.testing.expectError(expected, proof.validateBinding(a, io, wrong));
        checkpoint = .table_replay;
        try std.testing.expectError(expected, instance_fixture.replayProof(&proof, a, io, wrong, &cancel));
    }
    wrong_case = null;
    const data = f.instance_data.prepared.?;
    var request: instances_manager.CreateRequest = .{ .root = target.root, .instance = .{ .id = target.instance_id, .name = target.instance_name, .minecraft_version = instance_fixture.base_id, .loader = .forge, .loader_version = instance_fixture.forge_id }, .lease = f.instance_manager.lease, .installer_java = data.java8_path, .metadata = .{ .loader = .{ .owner = &proof, .generation = target.generation } } };
    checkpoint = .missing_probes;
    try std.testing.expectError(error.FixtureMissingJavaProbe, instance_fixture.validateRequest(&f.instance_data, a, io, request, .{ .cancel = &cancel }));
    const runner = f.instance_data.runner();
    const selected_runtime = f.java_manager.resolve(target.instance_name, 17) orelse return error.FixtureMissingRuntime;
    const installer_key = try std.fmt.allocPrint(a, "{s}:installer", .{target.instance_id});
    defer a.free(installer_key);
    const selected_installer = f.java_manager.resolve(installer_key, 8) orelse return error.FixtureMissingInstaller;
    try std.testing.expectEqualStrings(data.java17_path, selected_runtime.path);
    try std.testing.expectEqualStrings(data.java8_path, selected_installer.path);
    checkpoint = .runtime_probe;
    const runtime = try runner.probe(runner.context, a, io, selected_runtime.path, &cancel);
    defer java.freeRuntime(a, runtime);
    try std.testing.expectError(error.FixtureMissingJavaProbe, instance_fixture.validateRequest(&f.instance_data, a, io, request, .{ .cancel = &cancel }));
    checkpoint = .installer_probe;
    const installer = try runner.probe(runner.context, a, io, selected_installer.path, &cancel);
    defer java.freeRuntime(a, installer);
    checkpoint = .positive_request;
    var recipe = try instance_fixture.validateRequest(&f.instance_data, a, io, request, .{ .cancel = &cancel });
    defer recipe.deinit();
    checkpoint = .explicit_runtime;
    request.instance.java_path = selected_runtime.path;
    var explicit_recipe = try instance_fixture.validateRequest(&f.instance_data, a, io, request, .{ .cancel = &cancel });
    defer explicit_recipe.deinit();
    checkpoint = .swapped_installer;
    request.installer_java = data.java17_path;
    try std.testing.expectError(error.FixtureWrongJavaRole, instance_fixture.validateRequest(&f.instance_data, a, io, request, .{ .cancel = &cancel }));
    request.installer_java = data.java8_path;
    checkpoint = .swapped_runtime;
    request.instance.java_path = data.java8_path;
    try std.testing.expectError(error.FixtureWrongJavaRole, instance_fixture.validateRequest(&f.instance_data, a, io, request, .{ .cancel = &cancel }));
    request.instance.java_path = null;
    checkpoint = .changed_marker;
    for ([_]struct { path: []const u8, bytes: []const u8 }{
        .{ .path = data.java17_path, .bytes = "SyntheticMaterialization Java marker 17\n" },
        .{ .path = data.java8_path, .bytes = "SyntheticMaterialization Java marker 8\n" },
    }) |marker| {
        {
            const file = try std.Io.Dir.cwd().createFile(io, marker.path, .{});
            defer file.close(io);
            try file.writeStreamingAll(io, "changed marker\n");
        }
        try std.testing.expectError(error.FixtureJavaMarkerChanged, instance_fixture.validateRequest(&f.instance_data, a, io, request, .{ .cancel = &cancel }));
        {
            const file = try std.Io.Dir.cwd().createFile(io, marker.path, .{});
            defer file.close(io);
            try file.writeStreamingAll(io, marker.bytes);
        }
    }
    checkpoint = .fresh_preparation;
    var fresh_proof = try instance_fixture.prepareProof(&f.instance_data, a, io, target, &cancel);
    defer fresh_proof.deinit();
    request.metadata = .{ .loader = .{ .owner = &fresh_proof, .generation = target.generation } };
    try std.testing.expectError(error.FixtureMissingJavaProbe, instance_fixture.validateRequest(&f.instance_data, a, io, request, .{ .cancel = &cancel }));
    checkpoint = .canceled_probe;
    cancel.store(true, .release);
    try std.testing.expectError(error.Canceled, runner.probe(runner.context, a, io, data.java17_path, &cancel));
    try std.testing.expect(!f.instance_data.runtime_marker_probed.load(.acquire));
    try std.testing.expect(!f.instance_data.installer_marker_probed.load(.acquire));
    checkpoint = .no_publication;
    try std.testing.expect(!f.instance_data.staged.load(.acquire));
    const final_path = try f.paths.instanceDirectory(target.instance_name);
    defer a.free(final_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, final_path, .{ .follow_symlinks = false }));
    try testPreparedNoPublication(f, initial_count);
}

test "prepared held installer Cancel JOIN retains genuine proof until worker exits and publishes nothing" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const f = try Fixture.createScene(a, io, root, .instances, .{ .w = 1280, .h = 720 }, .@"instance-prepared");
    defer f.destroy();
    errdefer testFixtureContext(f, .cancel_join, null);
    const initial_count = f.configuration.snapshot().instances.len;
    const before = try testPrimaryWorld(f);
    defer a.free(before);
    try f.armInstanceScene(.installer);
    try testStartPrepared(f);
    try testWaitFixture(f, .installer_held);
    try std.testing.expect(f.instance_data.proof_borrowed.load(.acquire));
    try std.testing.expect(f.instance_data.validated_roles.load(.acquire));
    try std.testing.expect(!f.instance_data.installer_exited.load(.acquire));
    try std.testing.expect(!f.instance_data.staged.load(.acquire));
    try testPreparedNoPublication(f, initial_count);
    f.creation_core.cancel(f.creationServices());
    try testWaitFixture(f, .canceled);
    try std.testing.expect(f.instance_data.installer_exited.load(.acquire));
    try std.testing.expect(!f.instance_data.proof_borrowed.load(.acquire));
    try std.testing.expect(!f.instance_manager.isBusy());
    try testPreparedNoPublication(f, initial_count);
    const after = try testPrimaryWorld(f);
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
}

test "prepared teardown JOIN and deterministic owned-stage failure roll back without publication or world mutation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var exited: std.atomic.Value(bool) = .init(false);
    {
        const f = try Fixture.createScene(a, io, root, .instances, .{ .w = 1280, .h = 720 }, .@"instance-prepared");
        defer f.destroy();
        f.instance_data.installer_exit_observer = &exited;
        try f.armInstanceScene(.installer);
        try testStartPrepared(f);
        try testWaitFixture(f, .installer_held);
        try std.testing.expect(f.instance_data.proof_borrowed.load(.acquire));
        try std.testing.expect(!exited.load(.acquire));
    }
    try std.testing.expect(exited.load(.acquire));
    const f = try Fixture.createScene(a, io, root, .instances, .{ .w = 1280, .h = 720 }, .@"instance-prepared");
    defer f.destroy();
    errdefer testFixtureContext(f, .cancel_join, null);
    const initial_count = f.configuration.snapshot().instances.len;
    const before = try testPrimaryWorld(f);
    defer a.free(before);
    f.instance_data.fail_after_staging.store(true, .release);
    try f.armInstanceScene(.installer);
    try testStartPrepared(f);
    try testWaitFixture(f, .installer_held);
    const held = f.creation_core.snapshot().instance.?;
    const final_path = try f.paths.instanceDirectory(held.name);
    defer a.free(final_path);
    const stage_path = try std.fmt.allocPrint(a, "{s}/versions/.fixture-prepared-{s}", .{ f.paths.minecraft, held.id });
    defer a.free(stage_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, final_path, .{ .follow_symlinks = false }));
    f.instance_data.hold_installer.store(false, .release);
    try testWaitFixture(f, .failed);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, stage_path, .{ .follow_symlinks = false }));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, final_path, .{ .follow_symlinks = false }));
    try std.testing.expectEqual(@as(anyerror, error.FixtureSyntheticStagingFailure), f.creation_core.snapshot().failure.?);
    try std.testing.expect(f.instance_data.staged.load(.acquire));
    try std.testing.expect(f.instance_data.rolled_back.load(.acquire));
    try std.testing.expect(f.instance_data.installer_exited.load(.acquire));
    try std.testing.expect(!f.instance_data.proof_borrowed.load(.acquire));
    try std.testing.expect(!f.instance_manager.isBusy());
    try testPreparedNoPublication(f, initial_count);
    const after = try testPrimaryWorld(f);
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
}

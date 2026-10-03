//! Isolated acceptance entry. Production App never imports this module.
const std = @import("std");
const dvui = @import("dvui");
const state = @import("ui/model.zig");
const view = @import("ui/view.zig");
const theme = @import("ui/theme.zig");
const fonts = @import("ui/fonts.zig");
const config = @import("core/config.zig");
const instances = @import("core/instances.zig");
const tasks = @import("core/tasks.zig");
const servers_core = @import("core/servers.zig");
const java_backend = @import("core/java_download.zig");
const nbt = @import("nbt");
const compression = @import("nbt_compression");
const games = @import("ui/game_library.zig");
const java = @import("ui/java_manager.zig");
const java_view = @import("ui/java_view.zig");
const game_launch = @import("ui/game_launch.zig");
const settings_view = @import("ui/settings_view.zig");
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
const content_view = @import("ui/content_view.zig");
const accounts_manager = @import("ui/accounts_manager.zig");
const accounts_view = @import("ui/accounts_view.zig");
const instance_leases = @import("core/instance_leases.zig");
const instance_tx = @import("core/instance_transactions.zig");
const content_install = @import("core/content_install.zig");
const http = @import("core/http_transport.zig");
const auth = @import("core/auth.zig");
const credentials = @import("core/credentials.zig");
const shutdown_view = @import("ui/shutdown_view.zig");
const pack_controller = @import("ui/pack_import_controller.zig");
const pack_view = @import("ui/pack_import_view.zig");
const pack_fixture = @import("gui_pack_fixture.zig");
const TickCounts = struct {
    java: usize = 0,
    java_download: usize = 0,
    instances: usize = 0,
    pack_core: usize = 0,
    pack_ui: usize = 0,
    content: usize = 0,
};

pub const dvui_app: dvui.App = .{
    .config = .{ .options = .{
        .size = .{ .w = 1280, .h = 720 },
        .min_size = .{ .w = 640, .h = 400 },
        .title = "Vela Acceptance Fixture",
        .window_init_options = .{ .keybinds_zoom = true },
    } },
    .initFn = init,
    .frameFn = frame,
    .deinitFn = deinit,
};
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

const Panel = enum { home, settings, java, servers, logs, worlds, instances, content, player, shutdown };
var fixture: ?*Fixture = null;

pub fn init(win: *dvui.Window) !void {
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
    const scene = std.meta.stringToEnum(pack_fixture.Scene, app.environ_map.get("VELA_FIXTURE_SCENE") orelse "layout") orelse return error.InvalidFixtureScene;
    const archive = std.meta.stringToEnum(pack_fixture.Archive, app.environ_map.get("VELA_FIXTURE_PACK_ARCHIVE") orelse "modrinth") orelse return error.InvalidFixtureArchive;
    const hold = std.meta.stringToEnum(pack_fixture.Hold, app.environ_map.get("VELA_FIXTURE_PACK_HOLD") orelse "none") orelse return error.InvalidFixtureHold;
    const retry_text = app.environ_map.get("VELA_FIXTURE_PACK_ADOPTION_RETRY") orelse "0";
    const retry = if (std.mem.eql(u8, retry_text, "1")) true else if (std.mem.eql(u8, retry_text, "0")) false else return error.InvalidFixtureRetry;
    const owned = try Fixture.createScene(app.gpa, app.io, root, panel, viewport, scene);
    errdefer owned.destroy();
    try owned.choosePackArchive(archive);
    try owned.armPackScene(hold, retry);
    fixture = owned;
}

pub fn deinit(_: *dvui.Window) void {
    if (fixture) |f| f.destroy();
    fixture = null;
}

pub fn frame() !dvui.App.Result {
    const f = fixture orelse return error.MissingFixture;
    dvui.currentWindow().backend.impl.log_events = false;
    try f.tickServices();
    // Constrain window bounds without an open wrapper around deferred publication.
    const win = dvui.currentWindow();
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
        .pack_import = &f.pack_core,
        .pack_import_ui = &f.pack_ui,
        .configuration = &f.configuration,
        .tasks = &f.registry,
        .task_viewport_height = f.viewport.h,
        .settings = &f.settings,
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
        .content_ui = &f.content_ui,
    });
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
    if (f.library.snapshot().phase == .loading or f.java_manager.isSearching() or f.servers.isBusy() or f.worlds.snapshot().worker_active or f.accounts.snapshot().busy or f.instance_manager.isBusy() or f.content.isBusy() or f.cf_credentials.isBusy() or f.shutdown_prompt)
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
    content_ui: content_view.Ui,
    scene: pack_fixture.Scene,
    pack_data: pack_fixture.Context,
    pack_core: pack_controller.Controller,
    pack_ui: pack_view.Ui,
    pack_retry_once: bool = false,
    ticks: TickCounts = .{},
    accounts: accounts_manager.Manager,
    accounts_ui: accounts_view.Ui,
    instance_fingerprint: u64,
    shutdown_prompt: bool,
    fixture_task_last_id: u64,

    fn packServices(f: *Fixture) pack_controller.Services {
        return .{ .store = &f.configuration, .java = &f.java_manager, .java_download = &f.java_download_controller, .instances = &f.instance_manager, .content = &f.content };
    }

    fn choosePackArchive(f: *Fixture, archive: pack_fixture.Archive) !void {
        if (f.scene == .@"pack-prepared" and archive == .curseforge) return error.FixturePreparedRequiresModrinth;
        f.pack_data.archive = archive;
        if (f.scene != .pack or archive != .curseforge) return;
        // Explicit pack scene only: synthetic reference backed exclusively by RAM.
        const reference = "0123456789abcdef0123456789abcdef";
        try f.cf_vault.store().put(reference, "fixture-pack-key");
        var document = f.configuration.snapshot().*;
        document.settings.curseforge_enabled = true;
        document.settings.curseforge_terms_approved = true;
        document.settings.curseforge_credential_ref = reference;
        try f.configuration.update(document);
        try f.tickServices();
    }

    fn armPackScene(f: *Fixture, hold: pack_fixture.Hold, retry: bool) !void {
        if (f.scene == .layout and (hold != .none or retry)) return error.FixtureControlRequiresPackScene;
        if (hold == .installer and f.scene != .@"pack-prepared") return error.FixtureControlRequiresPreparedScene;
        f.pack_data.hold_inspection.store(hold == .inspection, .release);
        f.pack_data.hold_content.store(hold == .content, .release);
        f.pack_data.hold_installer.store(hold == .installer, .release);
        f.pack_retry_once = retry;
        if (retry) f.content.options.fixture_spawn_failure = error.FixtureAdoptionSpawnFailure;
    }

    fn packPinned(f: *const Fixture) bool {
        return f.pack_ui.pinned or switch (f.pack_core.snapshot().phase) {
            .idle, .review_required, .failed, .canceled => false,
            else => true,
        };
    }

    // Same ownership and JOIN order as App; no global content selection here.
    fn tickServices(f: *Fixture) !void {
        // Content.cancel marks its actual task before its held worker can JOIN.
        if (f.content.active) |job| if (job.task) |task| {
            if (task.canceled()) f.pack_data.releaseHolds();
        };
        if (f.pack_ui.stopping or f.pack_core.snapshot().phase == .cleaning) f.pack_data.releaseHolds();
        f.coordinator.tick();
        f.library.tick();
        if (!f.pack_core.ownsJavaDiscovery()) {
            f.java_manager.tick();
            f.ticks.java += 1;
        }
        f.launcher.tick();
        if (!f.pack_core.ownsJavaDownload()) {
            f.java_download_controller.tick(&f.java_manager);
            f.ticks.java_download += 1;
        }
        f.servers.tick();
        f.worlds.tick();
        f.accounts.tick(&f.configuration);
        if (!f.pack_core.ownsInstancesPublication()) {
            f.instance_manager.tick();
            f.ticks.instances += 1;
        }
        f.pack_core.tick(f.packServices());
        f.ticks.pack_core += 1;
        if (f.pack_retry_once and f.pack_core.snapshot().phase == .awaiting_adoption) {
            f.pack_retry_once = false;
            f.content.options.fixture_spawn_failure = null;
        }
        f.pack_ui.tick(&f.pack_core);
        f.ticks.pack_ui += 1;
        f.content.tick();
        f.ticks.content += 1;
        f.cf_credentials.tick(&f.configuration);
        const snapshot = f.content.snapshot();
        if (!f.packPinned() and !f.configuration.publicationUncertain()) {
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
        if (f.pack_ui.takeReviewRequest()) {
            f.model.panel = .content;
            f.content_ui.review_requested = true;
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
    }

    fn create(a: std.mem.Allocator, io: std.Io, root: []const u8, panel: Panel, viewport: dvui.Size) !*Fixture {
        return createScene(a, io, root, panel, viewport, .layout);
    }

    fn createScene(a: std.mem.Allocator, io: std.Io, root: []const u8, panel: Panel, viewport: dvui.Size, scene: pack_fixture.Scene) !*Fixture {
        const f = try a.create(Fixture);
        errdefer a.destroy(f);
        f.allocator = a;
        f.io = io;
        f.viewport = viewport;
        f.scene = scene;
        f.ticks = .{};
        f.pack_retry_once = false;
        f.shutdown_prompt = panel == .shutdown;
        f.paths = try instances.Paths.init(a, io, root);
        errdefer f.paths.deinit();
        f.pack_data = try pack_fixture.Context.init(a, io, root);
        errdefer f.pack_data.deinit();
        if (scene == .@"pack-prepared") try pack_fixture.initPrepared(&f.pack_data, a, io, root);
        f.configuration = try config.Store.init(a, io, root);
        errdefer f.configuration.deinit();
        try seedConfiguration(&f.configuration);
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
            .root = f.paths.minecraft,
            .manifest_url = "fixture-disabled://catalogue",
            .task_registry = &f.registry,
            .cache_root = f.paths.cache,
        });
        errdefer f.library.deinit();
        f.java_manager = try java.Manager.init(a, io, root);
        errdefer f.java_manager.deinit();
        if (scene == .@"pack-prepared") try pack_fixture.registerMarkers(&f.pack_data, &f.java_manager);
        f.java_ui = java_view.Ui.init(a);
        errdefer f.java_ui.deinit();
        f.launcher = try game_launch.Controller.initWithOptions(a, io, f.paths.minecraft, .{
            .log_directory = f.paths.logs,
            .launch_guard = .{ .context = f, .acquire = disabledLaunchAcquire, .release = disabledLaunchRelease },
        });
        errdefer f.launcher.deinit();
        f.launcher.setLaunchAllowed(false);
        f.settings = try settings_view.Ui.init(a, f.configuration.snapshot().settings);
        errdefer f.settings.deinit();
        f.java_download_controller = try java_download.Controller.initWithOptions(a, io, .{
            .root = root,
            .task_registry = &f.registry,
            .transport = .{ .context = f, .get = disabledJavaGet, .download = disabledJavaDownload },
        });
        errdefer f.java_download_controller.deinit();
        f.java_download_ui = java_download_view.Ui.init(a);
        errdefer f.java_download_ui.deinit();
        f.servers = server_manager.Manager.initWithQuery(a, io, disabledServerQuery);
        errdefer f.servers.deinit();
        f.servers_ui = servers_view.Ui.init(a);
        errdefer f.servers_ui.deinit();
        f.logs_ui = .{};
        f.worlds = try worlds_manager.Manager.init(a, io, &f.paths, &f.registry, f.coordinator.guard(null));
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
        f.instance_manager = try instances_manager.Manager.init(a, io, &f.paths, &f.registry, f.coordinator.guard(instance_mutation), .{
            .context = instance_mutation,
            .acquire = instance_leases.Mutation.acquireCallback,
            .recheck = instance_leases.Mutation.recheckCallback,
            .release = instance_leases.Mutation.releaseCallback,
        });
        errdefer f.instance_manager.deinit();
        f.instance_manager.setInstaller(if (scene == .@"pack-prepared") pack_fixture.preparedInstaller(&f.pack_data) else .{ .context = f, .run = disabledInstanceInstall });
        f.instance_manager.setLoaderCatalogue(.{ .context = f, .fetch = disabledLoaderCatalogue });
        f.instances_ui = instances_view.Ui.init(a);
        errdefer f.instances_ui.deinit();
        f.content = try content_manager.Manager.initOptions(a, io, &f.paths, &f.registry, .{
            .lease = f.pack_data.contentLease(.{ .context = content_mutation, .acquire = instance_leases.Mutation.acquireCallback, .recheck = instance_leases.Mutation.recheckCallback, .release = instance_leases.Mutation.releaseCallback }),
            .transport_options = .{ .fixture_http = pack_fixture.Context.denyHttp, .fixture_context = &f.pack_data, .allow_curseforge = scene == .pack, .approved_download_hosts = &.{} },
            .fixture_credential_store = f.cf_vault.store(),
            .fixture_fault = if (scene != .layout) null else .{ .context = f, .boundary = disabledContentMutation },
            .allow_manifest_v2 = scene != .layout,
        });
        errdefer f.content.deinit();
        f.content_ui = try content_view.Ui.init(a);
        errdefer f.content_ui.deinit();
        f.pack_core = try pack_controller.Controller.init(a, io, root, .{ .task_registry = &f.registry, .runner = f.pack_data.runner() });
        var pack_ui_initialized = false;
        errdefer {
            f.pack_data.releaseHolds();
            f.pack_core.deinit(f.packServices());
            if (pack_ui_initialized) f.pack_ui.deinit();
        }
        f.pack_ui = try pack_view.Ui.initOptions(a, io, root, .{ .runner = f.pack_data.uiRunner() });
        pack_ui_initialized = true;
        f.model = .{
            .players = &.{.{ .id = 1, .name = "FixturePlayer", .initials = "FP", .kind = "Offline" }},
            .versions = &.{.{ .id = 1, .name = "fixture-game", .description = "Minecraft 1.21.4" }},
            .getting_game = false,
        };
        switch (panel) {
            .home, .shutdown => {},
            .settings => {
                f.model.panel = .more;
                f.model.category = .settings;
            },
            .java => {
                f.model.panel = .java;
                f.java_ui.modal_open = true;
            },
            .servers => f.model.panel = .servers,
            .logs => f.model.panel = .logs,
            .worlds => {
                f.model.panel = .worlds;
                f.model.category = .game;
            },
            .instances => f.model.panel = .instances,
            .content => f.model.panel = .content,
            .player => f.model.panel = .players,
        }
        const path_len = @min(root.len, f.java_ui.path_buffer.len - 1);
        @memcpy(f.java_ui.path_buffer[0..path_len], root[0..path_len]);
        try seedWorlds(f);
        f.instance_fingerprint = instanceFingerprint(f.configuration.snapshot());
        try f.library.refreshInstalled();
        if (scene != .layout) pack_view.open(&f.pack_ui);
        return f;
    }

    fn destroy(f: *Fixture) void {
        const a = f.allocator;
        f.pack_data.releaseHolds();
        f.pack_core.deinit(f.packServices());
        f.pack_ui.deinit();
        f.launcher.deinit();
        f.content.deinit();
        f.content_ui.deinit();
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
        f.library.deinit();
        f.cf_credentials.deinit();
        f.cf_vault.deinit();
        f.settings.deinit();
        for (f.registry.tasks()) |task| f.registry.finish(task, .canceled);
        f.registry.deinit();
        f.configuration.deinit();
        f.pack_data.deinit();
        f.paths.deinit();
        a.destroy(f);
    }
};

fn parseViewport(value: []const u8) !dvui.Size {
    if (std.mem.eql(u8, value, "640x400")) return .{ .w = 640, .h = 400 };
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
        if (instance.loader != .vanilla) return error.NotFixtureConfiguration;
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
            .mainClass = "net.minecraft.client.main.Main",
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
            .loader = "vanilla",
            .loader_version = @as(?[]const u8, null),
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
        const kind: u8 = @intFromEnum(instance.loader);
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

fn seedWorlds(f: *Fixture) !void {
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
    std.mem.writeInt(u32, &word, std.hash.crc.Crc32.hash(output.items[start..]), .big);
    try output.appendSlice(a, &word);
}

test "acceptance fixture exposes real instance content player and shutdown panels" {
    for ([_][]const u8{ "home", "settings", "java", "servers", "logs", "worlds", "instances", "content", "player", "shutdown" }) |name|
        try std.testing.expect(std.meta.stringToEnum(Panel, name) != null);
    try std.testing.expect(std.meta.stringToEnum(Panel, "preview") == null);
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
    for (f.configuration.snapshot().instances) |instance| {
        var proof = try instance_tx.inspectInstalled(a, io, root, instance, .{});
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
    defer store.deinit();
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
    var reloaded = try config.Store.init(a, io, root);
    defer reloaded.deinit();
    try std.testing.expectEqualStrings(store.snapshot().selected_account.?, reloaded.snapshot().selected_account.?);
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
        try std.testing.expectEqual(std.hash.crc.Crc32.hash(png[offset + 4 .. data_end]), std.mem.readInt(u32, png[data_end..][0..4], .big));
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

const FixtureWait = enum { preview, content_idle, content_held, inspection_held, installer_held, review, adoption, canceled, failed };
const FixtureCheckpoint = enum {
    setup,
    wait_tick,
    wait_terminal,
    wait_timeout,
    preview,
    confirm,
    world_before,
    review_join,
    review_failure,
    review_ready,
    review_handoff,
    commit,
    commit_join,
    commit_result,
    override_read,
    world_after,
    world_unchanged,
    override_bytes,
    no_http,
    arm_hold,
    adoption_join,
    adoption_failure,
    adoption_reset,
    retry_request,
    retry_admission,
    private_archive,
    inspection_hold,
    archive_binding,
    credential_setup,
    credential_rejection,
    credential_wipe,
    cancel_request,
    cancel_admission,
    cancel_ui,
    cancel_pin,
    cancel_archive,
    release_inspection,
    cancel_join,
    inspection_join,
    cancel_unpin,
    no_proposal,
    content_hold,
    content_busy,
    content_release,
    content_join,
    no_review,
};

fn testFixtureSetupFailure(err: anyerror) void {
    std.debug.print("acceptance fixture failure: checkpoint=setup error={s}\n", .{@errorName(err)});
}

fn testFixtureFailure(f: *Fixture, checkpoint: FixtureCheckpoint, wanted: ?FixtureWait, err: anyerror) void {
    // Core guards worker results until JOIN; Content publishes results after await.
    // No active-worker request or result data is borrowed for these diagnostics.
    const core = f.pack_core.snapshot();
    const content = f.content.snapshot();
    std.debug.print("acceptance fixture failure: checkpoint={s} wait={s} error={s} core={s} core_failure={s} cleanup_failure={s} ui_failure={s} ui_pinned={} ui_busy={}\n", .{
        @tagName(checkpoint),
        if (wanted) |value| @tagName(value) else "none",
        @errorName(err),
        @tagName(core.phase),
        if (core.failure) |failure| @errorName(failure) else "none",
        if (core.cleanup_failure) |failure| @errorName(failure) else "none",
        if (f.pack_ui.failure) |failure| @errorName(failure) else "none",
        f.pack_ui.pinned,
        f.pack_ui.isBusy(),
    });
    std.debug.print("acceptance fixture content: provider={s} selected={} busy={} active={} failure={s} recovery={} policy_generation={d} proposal={} ready={} blocker={s}\n", .{
        @tagName(content.provider),
        content.instance != null,
        content.busy,
        f.content.active != null,
        if (content.failure) |failure| @errorName(failure) else "none",
        content.recovery_required,
        content.policy_generation,
        content.proposal != null,
        if (content.proposal) |proposal| proposal.ready else false,
        if (content.proposal) |proposal| if (proposal.blocker) |failure| @errorName(failure) else "none" else "none",
    });
    std.debug.print("acceptance fixture latches: inspection_hold={} inspection_entered={} inspection_exited={} content_hold={} content_entered={} content_released={} http_requests={d}\n", .{
        f.pack_data.hold_inspection.load(.acquire),
        f.pack_data.inspection_entered.load(.acquire),
        f.pack_data.inspection_exited.load(.acquire),
        f.pack_data.hold_content.load(.acquire),
        f.pack_data.content_entered.load(.acquire),
        f.pack_data.content_released.load(.acquire),
        f.pack_data.http_requests.load(.monotonic),
    });
}

fn testWaitFixture(f: *Fixture, wanted: FixtureWait) !void {
    const deadline = std.Io.Clock.awake.now(f.io).nanoseconds + 10 * std.time.ns_per_s;
    while (std.Io.Clock.awake.now(f.io).nanoseconds < deadline) {
        f.tickServices() catch |err| {
            testFixtureFailure(f, .wait_tick, wanted, err);
            return err;
        };
        const core = f.pack_core.snapshot();
        if (core.phase == .failed and wanted != .failed) {
            const err: anyerror = if (core.failure) |core_failure| core_failure else if (core.cleanup_failure) |cleanup_failure| cleanup_failure else error.FixturePackFailed;
            testFixtureFailure(f, .wait_terminal, wanted, err);
            return err;
        }
        const done = switch (wanted) {
            .preview => if (f.pack_ui.preview) |preview| preview.inspection != null and preview.thread == null else false,
            .content_idle => !f.content.isBusy(),
            .content_held => f.pack_data.content_entered.load(.acquire),
            .inspection_held => f.pack_data.inspection_entered.load(.acquire),
            .installer_held => f.pack_data.installer_entered.load(.acquire),
            .review => f.pack_core.snapshot().phase == .review_required and !f.content.isBusy(),
            .adoption => f.pack_core.snapshot().phase == .awaiting_adoption,
            .canceled => f.pack_core.snapshot().phase == .canceled and !f.pack_ui.isBusy(),
            .failed => f.pack_core.snapshot().phase == .failed and !f.pack_ui.isBusy(),
        };
        if (done) return;
        std.Thread.yield() catch {};
    }
    testFixtureFailure(f, .wait_timeout, wanted, error.TestTimeout);
    return error.TestTimeout;
}

fn testPackPreview(f: *Fixture) !void {
    pack_view.open(&f.pack_ui);
    try f.pack_ui.queueArchive(f.pack_data.path());
    pack_view.finish(&f.pack_ui, &f.configuration, &f.pack_core, f.packServices(), false);
    try testWaitFixture(f, .preview);
    try std.testing.expect(f.pack_ui.failure == null);
    const inspection = &f.pack_ui.preview.?.inspection.?;
    const suffix = if (inspection.provider == .modrinth) ".mrpack" else ".zip";
    try std.testing.expect(std.mem.eql(u8, suffix, std.fs.path.extension(inspection.archive_absolute_path)));
    const row = instances.findById(f.configuration.snapshot(), "fixture-primary") orelse return error.FixturePrimaryMissing;
    try f.pack_ui.queueExisting(row.*);
    pack_view.finish(&f.pack_ui, &f.configuration, &f.pack_core, f.packServices(), false);
    try std.testing.expect(f.pack_ui.failure == null);
}

fn testConfirmPack(f: *Fixture) !void {
    f.pack_ui.pending = .confirm;
    pack_view.finish(&f.pack_ui, &f.configuration, &f.pack_core, f.packServices(), false);
    if (f.pack_ui.failure) |err| {
        std.debug.print("acceptance pack confirmation failed: {s} (core={s}, ui_busy={}, java_busy={}, instances_busy={}, content_busy={}, recovery={})\n", .{
            @errorName(err),
            @tagName(f.pack_core.snapshot().phase),
            f.pack_ui.isBusy(),
            f.java_manager.isSearching(),
            f.instance_manager.isBusy(),
            f.content.isBusy(),
            f.content.snapshot().recovery_required,
        });
        std.debug.print("acceptance root bindings: store_base={}, instances_base={}, content_base={}, download_base={}, download_jdks={}\n", .{
            std.mem.eql(u8, f.paths.root, f.configuration.root),
            std.mem.eql(u8, f.paths.root, f.instance_manager.root),
            std.mem.eql(u8, f.paths.root, f.content.paths.root),
            std.mem.eql(u8, f.paths.root, f.java_download_controller.root),
            std.mem.eql(u8, f.paths.jdks, f.java_download_controller.root),
        });
        return err;
    }
    try std.testing.expect(f.pack_ui.failure == null);
    try std.testing.expect(f.pack_ui.pinned);
}

fn testSetFixtureKey(ui: *settings_view.Ui) void {
    ui.key_editor.reset();
    @memset(&ui.key_editor.bytes, 0xa5);
    const key = "fixture-rejected-key";
    @memcpy(ui.key_editor.bytes[0..key.len], key);
    ui.key_editor.len = key.len;
    ui.key_editor.status = .ready;
}

fn testExpectFixtureKeyCleared(ui: *const settings_view.Ui) !void {
    try std.testing.expect(ui.key_editor.len == 0 and ui.key_editor.status == .empty);
    for (ui.key_editor.bytes) |byte| try std.testing.expect(byte == 0);
    try std.testing.expect(ui.key_pending == null);
}

test "acceptance Root ticks each pack component once and never globally selects content" {
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
    try std.testing.expectEqual(before.pack_core + 1, f.ticks.pack_core);
    try std.testing.expectEqual(before.pack_ui + 1, f.ticks.pack_ui);
    try std.testing.expectEqual(before.content + 1, f.ticks.content);
    try std.testing.expectEqual(before.java + 1, f.ticks.java);
    try std.testing.expectEqual(before.java_download + 1, f.ticks.java_download);
    try std.testing.expectEqual(before.instances + 1, f.ticks.instances);
    try std.testing.expect(!f.content.options.allow_manifest_v2);
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
    f.pack_data.hold_content.store(true, .release);
    try f.content.select(instances.findById(f.configuration.snapshot(), "fixture-primary").?.*);
    try testWaitFixture(f, .content_held);
    try std.testing.expect(f.content.isBusy());
    try f.instance_manager.select(&f.configuration, "fixture-copy");
    const before = f.ticks.content;
    try f.tickServices();
    try std.testing.expectEqual(before + 1, f.ticks.content);
    try std.testing.expectEqualStrings("fixture-copy", f.configuration.snapshot().selected_instance.?);
    try std.testing.expectEqualStrings("fixture-primary", f.content.snapshot().instance.?.id);
    f.pack_data.hold_content.store(false, .release);
    try testWaitFixture(f, .content_idle);
    try std.testing.expect(f.pack_data.content_released.load(.acquire));
    try f.tickServices();
    try std.testing.expectEqualStrings("fixture-primary", f.content.snapshot().instance.?.id);
}

test "acceptance actual mrpack reaches review and commits local override without HTTP" {
    var fixture_ready = false;
    errdefer |err| if (!fixture_ready) testFixtureSetupFailure(err);
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const f = try Fixture.createScene(a, io, root, .content, .{ .w = 1280, .h = 720 }, .pack);
    defer f.destroy();
    fixture_ready = true;
    var checkpoint: FixtureCheckpoint = .setup;
    // Runs before Fixture destruction, so diagnostic snapshots remain owned.
    errdefer |err| testFixtureFailure(f, checkpoint, null, err);
    checkpoint = .world_before;
    const world_path = try f.paths.instancePath(instances.findById(f.configuration.snapshot(), "fixture-primary").?.*, "saves/fixture-survival/level.dat");
    defer a.free(world_path);
    checkpoint = .world_before;
    const world_before = try std.Io.Dir.cwd().readFileAlloc(io, world_path, a, .limited(1024 * 1024));
    defer a.free(world_before);
    checkpoint = .preview;
    try testPackPreview(f);
    checkpoint = .confirm;
    try testConfirmPack(f);
    checkpoint = .review_join;
    try testWaitFixture(f, .review);
    checkpoint = .review_failure;
    try std.testing.expect(f.pack_core.snapshot().failure == null);
    checkpoint = .review_ready;
    try std.testing.expect(f.content.snapshot().proposal.?.ready);
    checkpoint = .review_handoff;
    try std.testing.expect(f.model.panel == .content and f.content_ui.review_requested);
    checkpoint = .review_handoff;
    try std.testing.expect(!f.pack_ui.takeReviewRequest());
    checkpoint = .commit;
    try f.content.commit();
    checkpoint = .commit_join;
    try testWaitFixture(f, .content_idle);
    checkpoint = .commit_result;
    try std.testing.expect(f.content.snapshot().failure == null);
    const primary = instances.findById(f.configuration.snapshot(), "fixture-primary").?;
    checkpoint = .override_read;
    const destination = try f.paths.instancePath(primary.*, "config/fixture-pack.cfg");
    defer a.free(destination);
    checkpoint = .override_read;
    const actual = try std.Io.Dir.cwd().readFileAlloc(io, destination, a, .limited(1024));
    defer a.free(actual);
    checkpoint = .world_after;
    const world_after = try std.Io.Dir.cwd().readFileAlloc(io, world_path, a, .limited(1024 * 1024));
    defer a.free(world_after);
    checkpoint = .world_unchanged;
    try std.testing.expectEqualSlices(u8, world_before, world_after);
    checkpoint = .override_bytes;
    try std.testing.expectEqualStrings("hermetic pack settings\n", actual);
    checkpoint = .no_http;
    try std.testing.expectEqual(@as(usize, 0), f.pack_data.http_requests.load(.monotonic));
}

test "acceptance successful existing confirmation owns provider refresh through joined review" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const f = try Fixture.createScene(a, io, root, .content, .{ .w = 1280, .h = 720 }, .pack);
    defer f.destroy();
    try f.choosePackArchive(.curseforge);
    try f.content.select(instances.findById(f.configuration.snapshot(), "fixture-primary").?.*);
    try testWaitFixture(f, .content_idle);
    const policy_generation = f.content.snapshot().policy_generation;
    try testPackPreview(f);
    try testConfirmPack(f);
    try std.testing.expectEqual(pack_controller.Phase.awaiting_provider, f.pack_core.snapshot().phase);
    try std.testing.expect(f.content.isBusy());
    try testWaitFixture(f, .review);
    try std.testing.expect(f.pack_core.snapshot().failure == null);
    try std.testing.expect(f.content.snapshot().provider == .curseforge);
    try std.testing.expect(f.content.snapshot().policy_generation > policy_generation);
    try std.testing.expect(f.content.snapshot().proposal.?.ready);
    try std.testing.expectEqual(@as(usize, 0), f.pack_data.http_requests.load(.monotonic));
}

test "acceptance blocked owned adoption retry consumes actual spawn failure and reaches review" {
    var fixture_ready = false;
    errdefer |err| if (!fixture_ready) testFixtureSetupFailure(err);
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const f = try Fixture.createScene(a, io, root, .content, .{ .w = 1280, .h = 720 }, .pack);
    defer f.destroy();
    fixture_ready = true;
    var checkpoint: FixtureCheckpoint = .setup;
    // Runs before Fixture destruction, so diagnostic snapshots remain owned.
    errdefer |err| testFixtureFailure(f, checkpoint, null, err);
    checkpoint = .preview;
    try testPackPreview(f);
    checkpoint = .arm_hold;
    try f.armPackScene(.none, true);
    checkpoint = .confirm;
    try testConfirmPack(f);
    checkpoint = .adoption_join;
    try testWaitFixture(f, .adoption);
    checkpoint = .adoption_failure;
    try std.testing.expectEqual(error.FixtureAdoptionSpawnFailure, f.pack_core.snapshot().failure.?);
    checkpoint = .adoption_reset;
    try std.testing.expect(!f.pack_retry_once and f.content.options.fixture_spawn_failure == null);
    checkpoint = .retry_request;
    try f.pack_ui.queueOwned(.retry_adoption, &f.pack_core);
    checkpoint = .retry_admission;
    pack_view.finish(&f.pack_ui, &f.configuration, &f.pack_core, f.packServices(), true);
    checkpoint = .retry_admission;
    try std.testing.expect(f.pack_ui.pending == null and f.pack_ui.failure == null);
    checkpoint = .review_join;
    try testWaitFixture(f, .review);
    checkpoint = .review_ready;
    try std.testing.expect(f.content.snapshot().proposal.?.ready);
}

test "acceptance cancellation retains private preview until actual held preparation joins" {
    var fixture_ready = false;
    errdefer |err| if (!fixture_ready) testFixtureSetupFailure(err);
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const f = try Fixture.createScene(a, io, root, .content, .{ .w = 1280, .h = 720 }, .pack);
    defer f.destroy();
    fixture_ready = true;
    var checkpoint: FixtureCheckpoint = .setup;
    // Runs before Fixture destruction, so diagnostic snapshots remain owned.
    errdefer |err| testFixtureFailure(f, checkpoint, null, err);
    checkpoint = .preview;
    try testPackPreview(f);
    checkpoint = .private_archive;
    const private_archive = try a.dupe(u8, f.pack_ui.preview.?.inspection.?.archive_absolute_path);
    defer a.free(private_archive);
    f.pack_data.inspection_entered.store(false, .release);
    f.pack_data.inspection_exited.store(false, .release);
    f.pack_data.hold_inspection.store(true, .release);
    checkpoint = .confirm;
    try testConfirmPack(f);
    checkpoint = .inspection_hold;
    try testWaitFixture(f, .inspection_held);
    checkpoint = .archive_binding;
    try std.testing.expect(f.pack_core.snapshot().archive_sha256 == null);
    checkpoint = .credential_setup;
    testSetFixtureKey(&f.settings);
    checkpoint = .credential_rejection;
    try std.testing.expectError(error.Busy, f.settings.requestKey(.save_key, f.cf_credentials.snapshot(), f.packPinned(), false));
    checkpoint = .credential_wipe;
    try testExpectFixtureKeyCleared(&f.settings);
    checkpoint = .cancel_request;
    try f.pack_ui.queueOwned(.cancel, &f.pack_core);
    checkpoint = .cancel_admission;
    pack_view.finish(&f.pack_ui, &f.configuration, &f.pack_core, f.packServices(), true);
    checkpoint = .cancel_ui;
    f.pack_ui.cancel();
    checkpoint = .cancel_pin;
    try std.testing.expect(f.pack_ui.pinned and f.pack_ui.preview != null);
    checkpoint = .cancel_archive;
    const preserved = try std.Io.Dir.cwd().openFile(io, private_archive, .{});
    preserved.close(io);
    checkpoint = .release_inspection;
    f.pack_data.hold_inspection.store(false, .release);
    checkpoint = .cancel_join;
    try testWaitFixture(f, .canceled);
    checkpoint = .inspection_join;
    try std.testing.expect(f.pack_data.inspection_exited.load(.acquire));
    checkpoint = .cancel_unpin;
    try std.testing.expect(!f.pack_ui.pinned);
    checkpoint = .no_proposal;
    try std.testing.expect(f.content.snapshot().proposal == null);
    checkpoint = .no_http;
    try std.testing.expectEqual(@as(usize, 0), f.pack_data.http_requests.load(.monotonic));
}

test "acceptance Root teardown releases held real lease and joins worker before freeing context" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const f = try Fixture.create(a, io, root, .content, .{ .w = 1280, .h = 720 });
    var destroyed = false;
    defer if (!destroyed) f.destroy();
    var released: std.atomic.Value(bool) = .init(false);
    f.pack_data.content_release_observer = &released;
    f.pack_data.hold_content.store(true, .release);
    try f.content.select(instances.findById(f.configuration.snapshot(), "fixture-primary").?.*);
    try testWaitFixture(f, .content_held);
    f.destroy();
    destroyed = true;
    try std.testing.expect(released.load(.acquire));
}

test "acceptance rejected CF Enter wipes editor and creates no delayed credential work" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const f = try Fixture.createScene(a, io, root, .settings, .{ .w = 1280, .h = 720 }, .pack);
    defer f.destroy();
    const vault_before = f.cf_vault.slots;
    const cleanup_before = f.cf_credentials.core_manager.journal.snapshot().cleanup.len;
    f.pack_data.hold_content.store(true, .release);
    try f.content.select(instances.findById(f.configuration.snapshot(), "fixture-primary").?.*);
    try testWaitFixture(f, .content_held);
    const task_count = f.registry.tasks().len;
    testSetFixtureKey(&f.settings);
    try std.testing.expectError(error.Busy, f.settings.requestKey(.save_key, f.cf_credentials.snapshot(), f.content.isBusy() or f.packPinned(), false));
    try testExpectFixtureKeyCleared(&f.settings);
    testSetFixtureKey(&f.settings);
    try f.settings.requestKey(.save_key, f.cf_credentials.snapshot(), false, false);
    settings_view.finishWithCredentials(&f.settings, &f.configuration, &f.cf_credentials, f.content.isBusy());
    try testExpectFixtureKeyCleared(&f.settings);
    try std.testing.expectEqual(error.Busy, f.settings.key_failure.?);
    f.pack_data.hold_content.store(false, .release);
    try testWaitFixture(f, .content_idle);
    testSetFixtureKey(&f.settings);
    try std.testing.expectError(error.PublicationUncertain, f.settings.requestKey(.save_key, f.cf_credentials.snapshot(), false, true));
    try testExpectFixtureKeyCleared(&f.settings);
    for (0..3) |_| {
        settings_view.finishWithCredentials(&f.settings, &f.configuration, &f.cf_credentials, false);
        try f.tickServices();
    }
    try std.testing.expect(f.cf_credentials.snapshot().phase == .idle);
    try std.testing.expect(f.cf_credentials.snapshot().task_id == null);
    try std.testing.expect(f.cf_credentials.core_manager.pending() == null);
    try std.testing.expectEqual(cleanup_before, f.cf_credentials.core_manager.journal.snapshot().cleanup.len);
    try std.testing.expectEqual(task_count, f.registry.tasks().len);
    try std.testing.expect(std.meta.eql(vault_before, f.cf_vault.slots));
    try std.testing.expect(f.configuration.snapshot().settings.curseforge_credential_ref == null);
}

test "acceptance owned Cancel releases real held content task and joins without review" {
    var fixture_ready = false;
    errdefer |err| if (!fixture_ready) testFixtureSetupFailure(err);
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const f = try Fixture.createScene(a, io, root, .content, .{ .w = 1280, .h = 720 }, .pack);
    defer f.destroy();
    fixture_ready = true;
    var checkpoint: FixtureCheckpoint = .setup;
    // Runs before Fixture destruction, so diagnostic snapshots remain owned.
    errdefer |err| testFixtureFailure(f, checkpoint, null, err);
    checkpoint = .arm_hold;
    try f.armPackScene(.content, false);
    checkpoint = .preview;
    try testPackPreview(f);
    checkpoint = .confirm;
    try testConfirmPack(f);
    checkpoint = .content_hold;
    try testWaitFixture(f, .content_held);
    checkpoint = .content_busy;
    try std.testing.expect(f.content.isBusy());
    checkpoint = .archive_binding;
    try std.testing.expect(f.pack_core.snapshot().archive_sha256 != null);
    checkpoint = .cancel_request;
    try f.pack_ui.queueOwned(.cancel, &f.pack_core);
    checkpoint = .cancel_admission;
    pack_view.finish(&f.pack_ui, &f.configuration, &f.pack_core, f.packServices(), true);
    checkpoint = .cancel_join;
    try testWaitFixture(f, .canceled);
    checkpoint = .content_release;
    try std.testing.expect(!f.pack_data.hold_content.load(.acquire));
    checkpoint = .content_release;
    try std.testing.expect(f.pack_data.content_released.load(.acquire));
    checkpoint = .content_join;
    try std.testing.expect(f.content.active == null);
    checkpoint = .no_proposal;
    try std.testing.expect(f.content.snapshot().proposal == null);
    checkpoint = .no_review;
    try std.testing.expect(!f.pack_ui.takeReviewRequest());
}

fn testPreparedPreview(f: *Fixture) !void {
    try std.testing.expect(f.scene == .@"pack-prepared");
    try f.pack_ui.queueArchive(f.pack_data.path());
    pack_view.finish(&f.pack_ui, &f.configuration, &f.pack_core, f.packServices(), false);
    try testWaitFixture(f, .preview);
    try std.testing.expect(f.pack_ui.failure == null);
    // This branch intentionally keeps the real new-target request.
    try std.testing.expect(f.pack_ui.existing == null);
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
    try std.testing.expect(!f.content_ui.review_requested);
    try std.testing.expectEqual(@as(usize, 0), f.pack_data.http_requests.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), f.pack_data.jvm_invocations.load(.monotonic));
}

test "prepared Root scene derives genuine 17/8 and rejects CurseForge before RAM vault mutation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const f = try Fixture.createScene(a, io, root, .content, .{ .w = 1280, .h = 720 }, .@"pack-prepared");
    defer f.destroy();
    errdefer |err| testFixtureFailure(f, .setup, null, err);
    try std.testing.expectEqual(pack_fixture.Scene.@"pack-prepared", std.meta.stringToEnum(pack_fixture.Scene, "pack-prepared").?);
    const data = f.pack_data.prepared.?;
    try std.testing.expect(!std.mem.eql(u8, data.java17_path, data.java8_path));
    try std.testing.expect(std.mem.startsWith(u8, data.java17_path, f.paths.jdks));
    try std.testing.expect(std.mem.startsWith(u8, data.java8_path, f.paths.jdks));
    try std.testing.expect(std.mem.eql(u8, f.java_download_controller.root, f.paths.jdks));
    try std.testing.expectError(error.FixturePreparedRequiresModrinth, f.choosePackArchive(.curseforge));
    try std.testing.expectEqual(pack_fixture.Archive.modrinth, f.pack_data.archive);
    try std.testing.expect(!f.configuration.snapshot().settings.curseforge_enabled);
    try std.testing.expect(f.configuration.snapshot().settings.curseforge_credential_ref == null);
    for (f.cf_vault.slots) |slot| try std.testing.expect(slot.reference == null);
    try f.armPackScene(.installer, false);
    try testPreparedPreview(f);
    try testConfirmPack(f);
    try testWaitFixture(f, .installer_held);
    try std.testing.expect(f.pack_data.validated_roles.load(.acquire));
    try std.testing.expect(f.pack_data.proof_borrowed.load(.acquire));
    try std.testing.expect(!f.pack_data.staged.load(.acquire));
    try std.testing.expect(f.pack_data.synthetic_requests.load(.monotonic) > 0);
    try f.pack_ui.queueOwned(.cancel, &f.pack_core);
    pack_view.finish(&f.pack_ui, &f.configuration, &f.pack_core, f.packServices(), true);
    try testWaitFixture(f, .canceled);
    try std.testing.expect(!f.pack_data.proof_borrowed.load(.acquire));
    try std.testing.expect(!f.instance_manager.isBusy());
}

test "prepared Root publishes a new synthetic game then adopts reviews and commits overrides" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const f = try Fixture.createScene(a, io, root, .content, .{ .w = 1280, .h = 720 }, .@"pack-prepared");
    defer f.destroy();
    errdefer |err| testFixtureFailure(f, .review_join, null, err);
    const initial_count = f.configuration.snapshot().instances.len;
    const before = try testPrimaryWorld(f);
    defer a.free(before);
    try testPreparedPreview(f);
    try testConfirmPack(f);
    try testWaitFixture(f, .review);
    try std.testing.expectEqual(initial_count + 1, f.configuration.snapshot().instances.len);
    const row = f.content.snapshot().instance.?;
    try std.testing.expect(!std.mem.eql(u8, row.id, "fixture-primary"));
    try std.testing.expect(!std.mem.eql(u8, row.id, "fixture-copy"));
    try std.testing.expectEqualStrings(pack_fixture.base_id, row.minecraft_version);
    try std.testing.expectEqual(config.Loader.forge, row.loader);
    try std.testing.expectEqualStrings(pack_fixture.forge_id, row.loader_version.?);
    try std.testing.expectEqualStrings(f.pack_data.prepared.?.java17_path, row.java_path.?);
    try std.testing.expect(instances.findById(f.configuration.snapshot(), row.id) != null);
    try std.testing.expect(f.content.snapshot().proposal.?.ready);
    try std.testing.expect(f.model.panel == .content and f.content_ui.review_requested);
    try std.testing.expect(!f.pack_ui.takeReviewRequest());
    try std.testing.expect(f.pack_data.validated_roles.load(.acquire));
    try std.testing.expect(f.pack_data.installer_exited.load(.acquire));
    try std.testing.expect(!f.pack_data.proof_borrowed.load(.acquire));
    const receipt_path = try f.paths.instancePath(row, ".vela-loader.json");
    defer a.free(receipt_path);
    const receipt = try std.Io.Dir.cwd().readFileAlloc(io, receipt_path, a, .limited(8 * 1024 * 1024));
    defer a.free(receipt);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, receipt, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(row.id, parsed.value.object.get("instance_id").?.string);
    try std.testing.expect(parsed.value.object.get("artifact_bindings").?.array.items.len == 1);
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
    try f.content.commit();
    try testWaitFixture(f, .content_idle);
    try std.testing.expect(f.content.snapshot().failure == null);
    const override_path = try f.paths.instancePath(row, "config/fixture-pack.cfg");
    defer a.free(override_path);
    const override = try std.Io.Dir.cwd().readFileAlloc(io, override_path, a, .limited(1024));
    defer a.free(override);
    try std.testing.expectEqualStrings("SyntheticMaterialization settings\n", override);
    const after = try testPrimaryWorld(f);
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    try std.testing.expectEqual(@as(usize, 0), f.pack_data.http_requests.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), f.pack_data.jvm_invocations.load(.monotonic));
}

test "prepared genuine owner rejects root id name generation loader environment and swapped Java roles before writes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Checkpoint = enum { fixture_setup, proof_factory, requirements, binding, replay, table_binding, table_replay, positive_request, swapped_installer, swapped_runtime, canceled_probe, no_publication };
    const Wrong = enum { root, id, name, generation, loader, environment };
    var checkpoint: Checkpoint = .fixture_setup;
    var wrong_case: ?Wrong = null;
    errdefer |err| {
        const failure: anyerror = err;
        std.debug.print("prepared rejection failure: checkpoint={s} case={s} error={s}\n", .{ @tagName(checkpoint), if (wrong_case) |which| @tagName(which) else "none", @errorName(failure) });
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const f = try Fixture.createScene(a, io, root, .content, .{ .w = 1280, .h = 720 }, .@"pack-prepared");
    defer f.destroy();
    const initial_count = f.configuration.snapshot().instances.len;
    var cancel: std.atomic.Value(bool) = .init(false);
    const target: @import("core/minecraft/loader_install.zig").MetadataTarget = .{ .root = f.paths.root, .instance_id = "synthetic-proof", .instance_name = "SyntheticMaterialization-proof", .generation = 9, .selection = .{ .kind = .forge, .base_id = pack_fixture.base_id, .loader_id = pack_fixture.forge_id }, .environment = try pack_fixture.environment() };
    checkpoint = .proof_factory;
    var proof = try pack_fixture.prepareProof(&f.pack_data, a, io, target, &cancel);
    defer proof.deinit();
    checkpoint = .requirements;
    try std.testing.expectEqual(@as(u64, 17), proof.requirements.runtime_major);
    try std.testing.expectEqual(@as(u64, 8), proof.requirements.installer_major);
    checkpoint = .binding;
    try proof.validateBinding(a, io, target);
    checkpoint = .replay;
    try pack_fixture.replayProof(&proof, a, io, target, &cancel);
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
        try std.testing.expectError(expected, pack_fixture.replayProof(&proof, a, io, wrong, &cancel));
    }
    wrong_case = null;
    const data = f.pack_data.prepared.?;
    var request: instances_manager.CreateRequest = .{ .root = target.root, .instance = .{ .id = target.instance_id, .name = target.instance_name, .minecraft_version = pack_fixture.base_id, .loader = .forge, .loader_version = pack_fixture.forge_id, .java_path = data.java17_path }, .lease = f.instance_manager.lease, .installer_java = data.java8_path, .prepared = &proof, .prepared_generation = target.generation };
    checkpoint = .positive_request;
    var recipe = try pack_fixture.validateRequest(&f.pack_data, a, io, request, .{ .cancel = &cancel });
    defer recipe.deinit();
    checkpoint = .swapped_installer;
    request.installer_java = data.java17_path;
    try std.testing.expectError(error.FixtureWrongJavaRole, pack_fixture.validateRequest(&f.pack_data, a, io, request, .{ .cancel = &cancel }));
    request.installer_java = data.java8_path;
    checkpoint = .swapped_runtime;
    request.instance.java_path = data.java8_path;
    try std.testing.expectError(error.FixtureWrongJavaRole, pack_fixture.validateRequest(&f.pack_data, a, io, request, .{ .cancel = &cancel }));
    checkpoint = .canceled_probe;
    cancel.store(true, .release);
    try std.testing.expectError(error.Canceled, f.pack_data.runner().probe(&f.pack_data, a, io, data.java17_path, &cancel));
    checkpoint = .no_publication;
    try std.testing.expect(!f.pack_data.staged.load(.acquire));
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
    const f = try Fixture.createScene(a, io, root, .content, .{ .w = 1280, .h = 720 }, .@"pack-prepared");
    defer f.destroy();
    errdefer |err| testFixtureFailure(f, .cancel_join, null, err);
    const initial_count = f.configuration.snapshot().instances.len;
    const before = try testPrimaryWorld(f);
    defer a.free(before);
    try f.armPackScene(.installer, false);
    try testPreparedPreview(f);
    try testConfirmPack(f);
    try testWaitFixture(f, .installer_held);
    try std.testing.expect(f.pack_data.proof_borrowed.load(.acquire));
    try std.testing.expect(f.pack_data.validated_roles.load(.acquire));
    try std.testing.expect(!f.pack_data.installer_exited.load(.acquire));
    try std.testing.expect(!f.pack_data.staged.load(.acquire));
    try testPreparedNoPublication(f, initial_count);
    try f.pack_ui.queueOwned(.cancel, &f.pack_core);
    pack_view.finish(&f.pack_ui, &f.configuration, &f.pack_core, f.packServices(), true);
    try testWaitFixture(f, .canceled);
    try std.testing.expect(f.pack_data.installer_exited.load(.acquire));
    try std.testing.expect(!f.pack_data.proof_borrowed.load(.acquire));
    try std.testing.expect(!f.instance_manager.isBusy());
    try std.testing.expect(!f.pack_ui.pinned);
    try std.testing.expect(!f.pack_ui.takeReviewRequest());
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
        const f = try Fixture.createScene(a, io, root, .content, .{ .w = 1280, .h = 720 }, .@"pack-prepared");
        defer f.destroy();
        f.pack_data.installer_exit_observer = &exited;
        try f.armPackScene(.installer, false);
        try testPreparedPreview(f);
        try testConfirmPack(f);
        try testWaitFixture(f, .installer_held);
        try std.testing.expect(f.pack_data.proof_borrowed.load(.acquire));
        try std.testing.expect(!exited.load(.acquire));
    }
    try std.testing.expect(exited.load(.acquire));
    const f = try Fixture.createScene(a, io, root, .content, .{ .w = 1280, .h = 720 }, .@"pack-prepared");
    defer f.destroy();
    errdefer |err| testFixtureFailure(f, .cancel_join, null, err);
    const initial_count = f.configuration.snapshot().instances.len;
    const before = try testPrimaryWorld(f);
    defer a.free(before);
    f.pack_data.fail_after_staging.store(true, .release);
    try f.armPackScene(.installer, false);
    try testPreparedPreview(f);
    try testConfirmPack(f);
    try testWaitFixture(f, .installer_held);
    const held = f.pack_core.snapshot().instance.?;
    const final_path = try f.paths.instanceDirectory(held.name);
    defer a.free(final_path);
    const stage_path = try std.fmt.allocPrint(a, "{s}/versions/.fixture-prepared-{s}", .{ f.paths.minecraft, held.id });
    defer a.free(stage_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, final_path, .{ .follow_symlinks = false }));
    f.pack_data.hold_installer.store(false, .release);
    try testWaitFixture(f, .failed);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, stage_path, .{ .follow_symlinks = false }));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, final_path, .{ .follow_symlinks = false }));
    try std.testing.expectEqual(@as(anyerror, error.FixtureSyntheticStagingFailure), f.pack_core.snapshot().failure.?);
    try std.testing.expect(f.pack_data.staged.load(.acquire));
    try std.testing.expect(f.pack_data.rolled_back.load(.acquire));
    try std.testing.expect(f.pack_data.installer_exited.load(.acquire));
    try std.testing.expect(!f.pack_data.proof_borrowed.load(.acquire));
    try std.testing.expect(!f.instance_manager.isBusy());
    try testPreparedNoPublication(f, initial_count);
    const after = try testPrimaryWorld(f);
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
}

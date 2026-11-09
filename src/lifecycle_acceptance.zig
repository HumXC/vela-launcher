//! Linux controlled-process acceptance capability. This root reuses App unchanged.
//! IPC starts owned work only; compositor input owns close/dialog decisions.
const std = @import("std");
const dvui = @import("dvui");
const app = @import("app.zig");
const config = @import("core/config.zig");
const instances = @import("core/instances.zig");
const tree = @import("core/worlds_tree.zig");
const worlds = @import("core/worlds.zig");
const world_manager = @import("application/worlds_manager.zig");
const accounts = @import("application/accounts_manager.zig");
const auth = @import("core/auth.zig");
const credentials = @import("core/credentials.zig");
const http = @import("core/http_transport.zig");
const content = @import("application/content_manager.zig");
const java_download = @import("application/java_download_controller.zig");
const java_backend = @import("core/java_download.zig");
const servers = @import("core/servers.zig");
const lifecycle = @import("core/lifecycle.zig");
const A = std.mem.Allocator;
const Io = std.Io;

pub const main = app.main;
pub const dvui_app = app.dvui_app;
pub const panic = app.panic;
pub const std_options = app.std_options;
pub const vela_lifecycle_acceptance = @This();
pub const Case = enum { restore, close_preparing, close_running, debug, abnormal, exit_together, idle_keep, idle_auxiliary, idle_cancel, ordinary_destroy };

const State = struct {
    allocator: A,
    arena: std.heap.ArenaAllocator,
    io: Io,
    root: []const u8,
    nonce: []const u8,
    helper: []const u8,
    ca: []const u8,
    case: Case,
    ipc: Io.Dir,
    status_file: Io.File,
    sequence: u32 = 0,
    frame: u64 = 0,
    ready_frames: u8 = 0,
    ready: bool = false,
    launched: bool = false,
    armed: std.atomic.Value(bool) = .init(false),
    entered: std.atomic.Value(bool) = .init(false),
    cleanup_entered: std.atomic.Value(bool) = .init(false),
    cleanup_returned: std.atomic.Value(bool) = .init(false),
    destroy_entered: bool = false,
    world_joined: bool = false,
    accounts_joined: bool = false,
    destroyed: bool = false,
    last_actions: lifecycle.Actions = .{},
    close_choice: ?lifecycle.CloseChoice = null,
};
var state: ?*State = null;

fn required(env: *const std.process.Environ.Map, name: []const u8) ![]const u8 {
    const value = env.get(name) orelse return error.MissingLifecycleEnvironment;
    if (value.len == 0 or value.len > 4096 or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidLifecycleEnvironment;
    return value;
}
fn validNonce(nonce: []const u8) bool {
    if (nonce.len != 64) return false;
    for (nonce) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}
fn pin(a: A, io: Io, root: []const u8, path: []const u8, hex: []const u8, limit: usize) !void {
    if (hex.len != 64 or !std.mem.startsWith(u8, path, root) or path.len <= root.len or path[root.len] != '/') return error.ForeignLifecyclePath;
    const canonical = try Io.Dir.cwd().realPathFileAlloc(io, path, a);
    defer a.free(canonical);
    if (!std.mem.eql(u8, canonical, path)) return error.LinkedLifecyclePath;
    var dir = try tree.openAbsolute(io, std.fs.path.dirname(path).?);
    defer dir.close(io);
    const bytes = try tree.readBounded(a, io, dir, std.fs.path.basename(path), limit);
    defer a.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual = std.fmt.bytesToHex(&digest, .lower);
    if (!std.mem.eql(u8, &actual, hex)) return error.LifecyclePinDrift;
}

/// Runs before App constructs Paths or Store. The driver pins all directory FDs,
/// ownership, source bytes and executable identities; this side rejects fallbacks.
pub fn validate(a: A, io: Io, env: *const std.process.Environ.Map) !void {
    if (@import("builtin").os.tag != .linux) return error.LifecycleLinuxOnly;
    if (state != null) return error.LifecycleAlreadyInitialized;
    const root = try required(env, "VELA_LIFECYCLE_ROOT");
    const data = try required(env, "VELA_DATA_DIR");
    if (!std.fs.path.isAbsolute(root) or !std.mem.eql(u8, root, data)) return error.ForeignLifecycleRoot;
    const nonce = try required(env, "VELA_LIFECYCLE_NONCE");
    if (!validNonce(nonce)) return error.InvalidLifecycleNonce;
    const case = std.meta.stringToEnum(Case, try required(env, "VELA_LIFECYCLE_CASE")) orelse return error.InvalidLifecycleCase;
    const canonical = try Io.Dir.cwd().realPathFileAlloc(io, root, a);
    defer a.free(canonical);
    if (!std.mem.eql(u8, root, canonical)) return error.LinkedLifecyclePath;
    var root_dir = try tree.openAbsolute(io, root);
    defer root_dir.close(io);
    const owner = try tree.readBounded(a, io, root_dir, "owner.json", 4096);
    defer a.free(owner);
    const ownership = try std.json.parseFromSlice(struct { root: []const u8, nonce: []const u8, case: Case }, a, owner, .{});
    defer ownership.deinit();
    if (!std.mem.eql(u8, ownership.value.root, root) or !std.mem.eql(u8, ownership.value.nonce, nonce) or ownership.value.case != case) return error.ForeignLifecycleOwner;
    const helper = try required(env, "VELA_LIFECYCLE_HELPER");
    const ca = try required(env, "VELA_LIFECYCLE_CA");
    try pin(a, io, root, helper, try required(env, "VELA_LIFECYCLE_HELPER_SHA256"), 64 * 1024 * 1024);
    try pin(a, io, root, try required(env, "VELA_FONT_PATH"), try required(env, "VELA_LIFECYCLE_FONT_SHA256"), 32 * 1024 * 1024);
    try pin(a, io, root, ca, try required(env, "VELA_LIFECYCLE_CA_SHA256"), 8 * 1024 * 1024);
    const config_path = try std.fs.path.join(a, &.{ root, ".vela", "config.json" });
    defer a.free(config_path);
    try pin(a, io, root, config_path, try required(env, "VELA_LIFECYCLE_CONFIG_SHA256"), 1024 * 1024);
    const java_path = try std.fs.path.join(a, &.{ root, ".vela", "java.json" });
    defer a.free(java_path);
    try pin(a, io, root, java_path, try required(env, "VELA_LIFECYCLE_JAVA_SHA256"), 1024 * 1024);
    var ipc = try root_dir.openDir(io, "ipc", .{ .iterate = true, .follow_symlinks = false });
    errdefer ipc.close(io);
    inline for (.{ "command.json", "status.json", "world-release", "probe-release", "game-release", "probe.json", "game.json" }) |name| {
        const file = try ipc.openFile(io, name, .{ .follow_symlinks = false });
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file or stat.size > 64 * 1024) return error.InvalidLifecycleIPC;
    }
    const owned = try a.create(State);
    errdefer a.destroy(owned);
    const status_file = try ipc.openFile(io, "status.json", .{ .mode = .read_write, .follow_symlinks = false });
    errdefer status_file.close(io);
    owned.* = .{ .allocator = a, .arena = .init(a), .io = io, .root = "", .nonce = "", .helper = "", .ca = "", .case = case, .ipc = ipc, .status_file = status_file };
    errdefer owned.arena.deinit();
    const g = owned.arena.allocator();
    owned.root = try g.dupe(u8, root);
    owned.nonce = try g.dupe(u8, nonce);
    owned.helper = try g.dupe(u8, helper);
    owned.ca = try g.dupe(u8, ca);
    state = owned;
    errdefer state = null;
    var fixture = try root_dir.openDir(io, ".vela", .{ .follow_symlinks = false });
    defer fixture.close(io);
    const profile_bytes = try tree.readBounded(a, io, fixture, "config.json", 1024 * 1024);
    defer a.free(profile_bytes);
    const profile = try std.json.parseFromSlice(config.Document, a, profile_bytes, .{});
    defer profile.deinit();
    try validateProfile(&profile.value);
}

pub fn validateProfile(document: *const config.Document) !void {
    const s = state orelse return error.MissingLifecycleState;
    if (document.instances.len != 2 or document.accounts.len != 1 or document.servers.len != 0 or document.selected_server != null) return error.InvalidLifecycleProfile;
    const selected = instances.findById(document, "lifecycle-world") orelse return error.InvalidLifecycleProfile;
    const game = instances.findById(document, "lifecycle-game") orelse return error.InvalidLifecycleProfile;
    if (!std.mem.eql(u8, selected.name, "selectedWorld") or !std.mem.eql(u8, game.name, "ControlledGame") or !std.mem.eql(u8, document.selected_instance orelse "", selected.id)) return error.InvalidLifecycleProfile;
    for (document.instances) |instance| {
        if (instance.loader != .vanilla or instance.loader_version != null or !std.mem.eql(u8, instance.java_path orelse "", s.helper) or !std.mem.eql(u8, instance.minecraft_version, "lifecycle-local")) return error.InvalidLifecycleProfile;
    }
    const account = document.accounts[0];
    if (account.kind != .offline or account.credential_ref != null or !std.mem.eql(u8, account.id, "lifecycle-offline") or !std.mem.eql(u8, account.name, "LifecyclePlayer") or !std.mem.eql(u8, account.uuid, "11111111111111111111111111111111") or !std.mem.eql(u8, document.selected_account orelse "", account.id)) return error.InvalidLifecycleProfile;
    const settings = document.settings;
    if (settings.microsoft_client_id.len != 0 or settings.curseforge_enabled or settings.curseforge_terms_approved or settings.curseforge_credential_ref != null) return error.InvalidLifecycleProfile;
    if (game.debug_launch != (s.case == .debug)) return error.InvalidLifecycleProfile;
    const together = s.case == .exit_together or s.case == .abnormal;
    if ((settings.game_exit_behavior == .exit_launcher) != together) return error.InvalidLifecycleProfile;
}

pub fn store() credentials.Store {
    return .{ .ctx = state.?, .vtable = &deny_vault };
}
pub fn accountOptions(root: []const u8) accounts.Options {
    return .{ .root = root, .fixture = .{ .transport = .{ .ctx = state.?, .kind = .fixture, .supports_post = true, .request = denyAuth }, .store = store(), .entropy = .{ .ctx = state.?, .fill = denyEntropy }, .journal = .{ .ctx = state.?, .stage = denyJournal, .remove = denyJournal, .references = emptyReferences } } };
}
pub fn javaOptions(root: []const u8, registry: anytype, download_budget: *@import("core/downloader.zig").Budget) java_download.Options {
    return .{ .root = root, .task_registry = registry, .download_budget = download_budget, .transport = .{ .context = state.?, .get = denyJavaGet, .download = denyJavaDownload } };
}
pub fn contentOptions(options: content.Options) content.Options {
    var result = options;
    result.fixture_credential_store = store();
    result.allow_curseforge_remote = false;
    result.curseforge = .{};
    result.transport_options = .{ .http = .{ .proxy = null, .ca_bundle = state.?.ca }, .download_budget = options.transport_options.download_budget, .allow_curseforge = false, .fixture_http = denyHttp, .fixture_context = state.? };
    return result;
}
pub fn denyServer(_: A, _: Io, _: config.Server, _: servers.Options) !servers.OwnedStatus {
    return error.LifecycleNetworkDenied;
}
fn denyHttp(_: ?*anyopaque, _: A, _: Io, _: http.Request) !http.Response {
    return error.LifecycleNetworkDenied;
}
fn denyAuth(_: *anyopaque, _: A, _: auth.Request) auth.TransportError!auth.Response {
    return error.UnsupportedTransport;
}
fn denyEntropy(_: *anyopaque, _: []u8) error{EntropyUnavailable}!void {
    return error.EntropyUnavailable;
}
const deny_vault: credentials.Store.VTable = .{ .put = denyPut, .get = denyGet, .delete = denyDelete };
fn denyPut(_: *anyopaque, _: []const u8, _: []const u8) credentials.Error!void {
    return error.Unavailable;
}
fn denyGet(_: *anyopaque, _: A, _: []const u8) credentials.Error!credentials.Secret {
    return error.NotFound;
}
fn denyDelete(_: *anyopaque, _: []const u8) credentials.Error!void {
    return error.NotFound;
}
fn denyJournal(_: *anyopaque, _: credentials.Reference) !void {
    return error.LifecycleJournalDenied;
}
fn emptyReferences(_: *anyopaque) []const credentials.Reference {
    return &.{};
}
fn denyJavaGet(_: *anyopaque, _: A, _: []const u8, _: usize, hooks: java_backend.Hooks) ![]u8 {
    try hooks.check();
    return error.LifecycleNetworkDenied;
}
fn denyJavaDownload(_: *anyopaque, _: Io, _: *const java_backend.RuntimeRelease, _: []const u8, hooks: java_backend.Hooks) !void {
    try hooks.check();
    return error.LifecycleNetworkDenied;
}

fn released(s: *State, io: Io, name: []const u8) !bool {
    const bytes = try tree.readBounded(std.heap.page_allocator, io, s.ipc, name, 64);
    defer std.heap.page_allocator.free(bytes);
    return std.mem.eql(u8, bytes, s.nonce);
}
/// Real borrowed-scope local listing. The owned fixture has no icons or mutations.
/// The hold owns its output until cleanup returns; Manager owns JOIN/publication.
pub fn worldWorker(a: A, io: Io, paths: *const instances.Paths, instance: config.Instance, request: ?world_manager.Request, options: worlds.Options) !world_manager.Result {
    if (request) |operation| if (operation != .backup or !std.mem.eql(u8, operation.backup, "Lifecycle")) return error.LifecycleMutationDenied;
    // The important-operation fixture holds a backup request without writing files.
    const held = options.held_scope orelse return error.MissingWorldScope;
    try held.recheck();
    var result: world_manager.Result = .{};
    errdefer result.deinit();
    result.world_list = try worlds.list(a, io, paths, instance, null, options);
    result.backup_list = try worlds.listBackups(a, io, paths, instance, options);
    const s = state orelse return error.MissingLifecycleState;
    if (!s.armed.load(.acquire)) return result;
    if (!std.mem.eql(u8, instance.id, "lifecycle-world")) return error.InvalidLifecycleWorld;
    s.entered.store(true, .release);
    while (!(try released(s, io, "world-release"))) {
        options.hooks.check(io) catch |err| {
            if (err != error.Canceled) return err;
            s.cleanup_entered.store(true, .release);
        };
        // Cooperative fixture cleanup is intentionally held after cancellation.
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    s.cleanup_entered.store(true, .release);
    result.deinit();
    s.cleanup_returned.store(true, .release);
    return error.Canceled;
}

const Command = struct { nonce: []const u8, sequence: u32, kind: enum { none, arm_world, start } };
pub fn beforeFrame(launcher: anytype, manager: *world_manager.Manager, configuration: *config.Store, paths: *const instances.Paths) !void {
    const s = state.?;
    const bytes = try tree.readBounded(s.allocator, s.io, s.ipc, "command.json", 4096);
    defer s.allocator.free(bytes);
    // The driver writes this pinned inode; a partial JSON write is retried next frame.
    const command = std.json.parseFromSlice(Command, s.allocator, bytes, .{}) catch return;
    defer command.deinit();
    const c = command.value;
    if (!std.mem.eql(u8, c.nonce, s.nonce)) return error.ForeignLifecycleCommand;
    if (c.sequence <= s.sequence) return;
    if (c.sequence != s.sequence + 1 or !s.ready) return error.InvalidLifecycleSequence;
    switch (c.kind) {
        .none => return error.InvalidLifecycleCommand,
        .arm_world => {
            if (s.armed.swap(true, .acq_rel)) return error.LifecycleAlreadyArmed;
            if (s.case == .idle_keep or s.case == .idle_cancel or s.case == .exit_together) {
                try manager.perform(.{ .backup = "Lifecycle" });
            } else if (manager.snapshot().instance == null) {
                const selected_id = configuration.snapshot().selected_instance orelse return error.InvalidLifecycleProfile;
                const selected = instances.findById(configuration.snapshot(), selected_id) orelse return error.InvalidLifecycleProfile;
                try manager.select(selected.*);
            } else try manager.refresh();
        },
        .start => {
            if (s.launched or (s.armed.load(.acquire) and !s.entered.load(.acquire))) return error.InvalidLifecycleStart;
            try validateProfile(configuration.snapshot());
            const game = instances.findById(configuration.snapshot(), "lifecycle-game").?;
            const directory = try paths.instanceDirectory(game.name);
            defer paths.allocator.free(directory);
            try launcher.startWithOptions(.{ .version = game.name, .java_path = s.helper, .java_major = 21, .username = "LifecyclePlayer", .max_memory_mb = 256 }, .{ .instance_id = game.id, .launcher_root = paths.root, .instance_directory = directory, .debug = game.debug_launch, .identity = .{ .name = "LifecyclePlayer", .uuid = "11111111111111111111111111111111" }, .extra_game = &.{ "--vela-lifecycle-root", s.root, "--vela-lifecycle-nonce", s.nonce } });
            s.launched = true;
        },
    }
    s.sequence = c.sequence;
}
fn emit(value: anytype) !void {
    const s = state.?;
    const bytes = try std.json.Stringify.valueAlloc(s.allocator, value, .{});
    defer s.allocator.free(bytes);
    var padded: [64 * 1024]u8 = @splat(' ');
    if (bytes.len > padded.len) return error.LifecycleEvidenceTooLarge;
    @memcpy(padded[0..bytes.len], bytes);
    try s.status_file.writePositionalAll(s.io, &padded, 0);
}
pub fn afterFrame(observation: anytype) !void {
    const s = state.?;
    s.frame += 1;
    if (!s.ready) {
        if (observation.startup_idle) s.ready_frames += 1 else s.ready_frames = 0;
        s.ready = s.ready_frames >= 3;
    }
    const flags = dvui.backend.c.SDL_GetWindowFlags(observation.window.window.?);
    try emit(.{
        .nonce = s.nonce,
        .case = @tagName(s.case),
        .frame = s.frame,
        .sequence = s.sequence,
        .ready = s.ready,
        .game = observation.game,
        .world = .{
            .worker_active = observation.world.worker_active,
            .loading = observation.world.loading,
            .failure = observation.world.failure,
            .instance_id = if (observation.world.instance) |instance| instance.id else null,
            .world_count = observation.world.worlds.len,
            .backup_count = observation.world.backups.len,
        },
        .accounts = .{
            .phase = observation.accounts.phase,
            .busy = observation.accounts.busy,
            .failure = observation.accounts.failure,
            .cleanup_count = observation.accounts.cleanup_count,
            .publication_pending = observation.accounts.publication_pending,
        },
        .task_count = observation.task_count,
        .active_background = observation.active_background,
        .policy_game = @tagName(observation.policy.game),
        .shutdown = @tagName(observation.policy.shutdown),
        .close_choice = s.close_choice,
        .panel = observation.panel,
        .viewport = dvui.windowRect(),
        .shutdown_layout = observation.shutdown_layout,
        .hidden = (flags & dvui.backend.c.SDL_WINDOW_HIDDEN) != 0,
        .world_entered = s.entered.load(.acquire),
        .cleanup_entered = s.cleanup_entered.load(.acquire),
        .cleanup_returned = s.cleanup_returned.load(.acquire),
        .destroy_entered = s.destroy_entered,
        .world_joined = s.world_joined,
        .accounts_joined = s.accounts_joined,
        .destroyed = s.destroyed,
        .actions = s.last_actions,
    });
    dvui.refresh(null, @src(), null);
}
pub fn observeActions(actions: lifecycle.Actions) void {
    state.?.last_actions = actions;
}
pub fn observeChoice(choice: lifecycle.CloseChoice) void {
    state.?.close_choice = choice;
}
fn destructionStatus() void {
    const s = state.?;
    emit(.{ .nonce = s.nonce, .case = @tagName(s.case), .frame = s.frame, .sequence = s.sequence, .destroy_entered = s.destroy_entered, .world_entered = s.entered.load(.acquire), .cleanup_entered = s.cleanup_entered.load(.acquire), .cleanup_returned = s.cleanup_returned.load(.acquire), .world_joined = s.world_joined, .accounts_joined = s.accounts_joined, .destroyed = s.destroyed, .actions = s.last_actions }) catch |err| std.log.err("Lifecycle destruction evidence: {s}", .{@errorName(err)});
}
pub fn beforeDestroy() void {
    state.?.destroy_entered = true;
    destructionStatus();
}
pub fn worldJoined() void {
    state.?.world_joined = true;
    destructionStatus();
}
pub fn accountsJoined() void {
    state.?.accounts_joined = true;
    destructionStatus();
}
pub fn destroy() void {
    if (state) |s| {
        if (s.destroy_entered) {
            s.destroyed = true;
            destructionStatus();
        }
        s.status_file.close(s.io);
        s.ipc.close(s.io);
        s.arena.deinit();
        s.allocator.destroy(s);
        state = null;
    }
}

test "nonce and case admit only finite owned protocol values" {
    try std.testing.expect(validNonce(&(comptime @as([64]u8, @splat('a')))));
    try std.testing.expect(!validNonce(&(comptime @as([63]u8, @splat('a')))));
    try std.testing.expect(!validNonce(&(comptime @as([64]u8, @splat('g')))));
    try std.testing.expect(std.meta.stringToEnum(Case, "close_running") != null);
    try std.testing.expect(std.meta.stringToEnum(Case, "force_quit") == null);
}

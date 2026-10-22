//! Genuine acceptance root: production instance ownership, official metadata and native Java.
const std = @import("std");
const builtin = @import("builtin");
const curl = @import("curl");
const config = @import("core/config.zig");
const instances = @import("core/instances.zig");
const tasks = @import("core/tasks.zig");
const leases = @import("core/instance_leases.zig");
const manager_module = @import("ui/instances_manager.zig");
const loader_install = @import("core/loaders/install.zig");
const loaders = @import("core/loaders/root.zig");
const metadata = @import("core/minecraft/metadata/root.zig");
const metadata_loader = @import("core/minecraft/metadata_loader.zig");
const http = @import("core/http_transport.zig");
const library = @import("ui/game_library.zig");
const planner = @import("core/minecraft/install_plan.zig");
const launch = @import("core/minecraft/launch.zig");
const game = @import("ui/game_launch.zig");
const java = @import("ui/java_manager.zig");
const A = std.mem.Allocator;

const Options = struct {
    root: []const u8 = "",
    report: []const u8 = "",
    cancel_file: []const u8 = "",
    kind: config.Loader = .vanilla,
    base: []const u8 = "",
    version: ?[]const u8 = null,
    runtime_java: []const u8 = "",
    installer_java: ?[]const u8 = null,
    mode: enum { catalogue, install, dryrun, launch } = .dryrun,
    seconds: u32 = 30,
    cancel_after_ms: ?u64 = null,
    memory: u32 = 2048,
    extra_jvm: std.ArrayList([]const u8) = .empty,
    extra_game: std.ArrayList([]const u8) = .empty,
};
const DownloadFailure = struct {
    path: []const u8,
    state: []const u8,
    failure: []const u8,
};

const Report = struct {
    schema_version: u32 = 1,
    phase: []const u8 = "initializing",
    genuine: bool = true,
    offline: bool = true,
    loader: []const u8 = "",
    base: []const u8 = "",
    loader_version: ?[]const u8 = null,
    runtime_java: []const u8 = "",
    installer_java: ?[]const u8 = null,
    selected_config: ?config.Instance = null,
    catalogue: []const manager_module.LoaderEntry = &.{},
    required_java_major: ?u64 = null,
    runtime_java_major: ?u32 = null,
    installer_java_major: ?u32 = null,
    receipt_path: ?[]const u8 = null,
    receipt_sha256: ?[]const u8 = null,
    metadata_sha256: ?[]const u8 = null,
    planned_argv_sanitized: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    published: bool = false,
    native_java_started: bool = false,
    worker_joined: bool = false,
    launch_joined: bool = false,
    leases_released: bool = false,
    canceled: bool = false,
    durability_uncertain: bool = false,
    download_failures: []const DownloadFailure = &.{},
    failure: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("loader-acceptance: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
fn save(a: A, io: std.Io, path: []const u8, report: Report) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, report, .{ .whitespace = .indent_2 });
    defer a.free(bytes);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}
fn elapsed(io: std.Io, start: i96) u64 {
    return @intCast(@max(0, @divFloor(std.Io.Clock.awake.now(io).nanoseconds - start, std.time.ns_per_ms)));
}
const OfficialMetadata = struct {
    client: *http.Client,
    cancel: *const std.atomic.Value(bool),
    fn get(raw: ?*anyopaque, a: A, _: std.Io, request: metadata_loader.Request) anyerror![]u8 {
        const self: *OfficialMetadata = @ptrCast(@alignCast(raw.?));
        var response = try self.client.execute(.{ .url = request.url, .max_response_bytes = request.max_bytes, .cancel = self.cancel, .require_public_address = true, .follow_redirects = false });
        defer response.deinit();
        if (response.status != 200) return error.MetadataHttpFailure;
        // fetchSources verifies the official manifest SHA-1 before parsing.
        return a.dupe(u8, response.body);
    }
};
fn nowMilliseconds(raw: ?*anyopaque) u64 {
    const clock_io: *const std.Io = @ptrCast(@alignCast(raw.?));
    return @intCast(@divFloor(std.Io.Clock.awake.now(clock_io.*).nanoseconds, std.time.ns_per_ms));
}
fn watchCancel(io: std.Io, o: Options, flag: *std.atomic.Value(bool), done: *std.atomic.Value(bool)) void {
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    while (!done.load(.acquire)) {
        if (canceled(io, o, start)) {
            flag.store(true, .release);
            return;
        }
        io.sleep(.fromMilliseconds(50), .awake) catch return;
    }
}
fn canceled(io: std.Io, o: Options, start: i96) bool {
    if (o.cancel_after_ms) |ms| if (elapsed(io, start) >= ms) return true;
    std.Io.Dir.cwd().access(io, o.cancel_file, .{}) catch return false;
    return true;
}
fn launchAcquire(raw: ?*anyopaque, id: []const u8) !void {
    const owner: *leases.Coordinator = @ptrCast(@alignCast(raw.?));
    try owner.reserveLaunch(id);
}
fn launchRelease(raw: ?*anyopaque) void {
    const owner: *leases.Coordinator = @ptrCast(@alignCast(raw.?));
    owner.releaseLaunch();
}
fn digest(a: A, bytes: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}
fn offlineUuid() [32]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.hash.Md5.hash("OfflinePlayer:Acceptance", &bytes, .{});
    bytes[6] = (bytes[6] & 0x0f) | 0x30;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return std.fmt.bytesToHex(bytes, .lower);
}
fn sensitiveKey(arg: []const u8) bool {
    const names = [_][]const u8{ "token", "password", "secret", "credential", "clientid", "xuid", "userproperties", "session", "authorization" };
    const end = std.mem.indexOfScalar(u8, arg, '=') orelse arg.len;
    for (names) |name| {
        if (name.len > end) continue;
        for (0..end - name.len + 1) |offset| {
            if (std.ascii.eqlIgnoreCase(arg[offset..][0..name.len], name)) return true;
        }
    }
    return false;
}
fn sanitize(a: A, argv: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, argv.len);
    var secret = false;
    for (argv, out) |arg, *target| {
        const key_sensitive = sensitiveKey(arg);
        const equals = std.mem.indexOfScalar(u8, arg, '=');
        target.* = if (secret) "<redacted>" else if (key_sensitive and equals != null)
            try std.fmt.allocPrint(a, "{s}=<redacted>", .{arg[0..equals.?]})
        else
            try a.dupe(u8, arg);
        secret = !secret and key_sensitive and equals == null;
    }
    return out;
}
fn parse(a: A, args: []const [:0]const u8) !Options {
    var o: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const key = args[i];
        i += 1;
        if (i >= args.len) return error.MissingOptionValue;
        const value = args[i];
        if (std.mem.eql(u8, key, "--root")) o.root = value else if (std.mem.eql(u8, key, "--report")) o.report = value else if (std.mem.eql(u8, key, "--cancel-file")) o.cancel_file = value else if (std.mem.eql(u8, key, "--loader")) o.kind = std.meta.stringToEnum(config.Loader, value) orelse return error.InvalidLoader else if (std.mem.eql(u8, key, "--base")) o.base = value else if (std.mem.eql(u8, key, "--version")) o.version = value else if (std.mem.eql(u8, key, "--java")) o.runtime_java = value else if (std.mem.eql(u8, key, "--installer-java")) o.installer_java = value else if (std.mem.eql(u8, key, "--mode")) o.mode = std.meta.stringToEnum(@TypeOf(o.mode), value) orelse return error.InvalidMode else if (std.mem.eql(u8, key, "--seconds")) o.seconds = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, key, "--cancel-after-ms")) o.cancel_after_ms = try std.fmt.parseInt(u64, value, 10) else if (std.mem.eql(u8, key, "--memory")) o.memory = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, key, "--jvm-arg")) try o.extra_jvm.append(a, value) else if (std.mem.eql(u8, key, "--game-arg")) try o.extra_game.append(a, value) else return error.UnknownOption;
    }
    if (!std.mem.startsWith(u8, o.root, "/tmp/") or o.report.len == 0 or o.base.len == 0 or o.cancel_file.len == 0) return error.IsolatedRootRequired;
    if (o.mode != .catalogue and o.kind != .vanilla and o.version == null) return error.ExactLoaderVersionRequired;
    if (o.mode != .catalogue and !std.fs.path.isAbsolute(o.runtime_java)) return error.ExactJavaPathRequired;
    if (o.installer_java) |path| if (!std.fs.path.isAbsolute(path)) return error.ExactJavaPathRequired;
    for (o.extra_game.items) |arg| if (sensitiveKey(arg) or std.mem.eql(u8, arg, "--username") or std.mem.eql(u8, arg, "--uuid")) return error.IdentityOverrideForbidden;
    for (o.extra_jvm.items) |arg| if (sensitiveKey(arg)) return error.CredentialArgumentForbidden;
    return o;
}
fn run(init: std.process.Init) anyerror!void {
    if (builtin.os.tag != .linux) return error.LinuxAcceptanceOnly;
    const a = init.arena.allocator();
    const io = init.io;
    const o = try parse(a, try init.minimal.args.toSlice(a));
    const home = init.environ_map.get("HOME") orelse return error.IsolatedHomeRequired;
    if (!std.mem.startsWith(u8, home, "/tmp/")) return error.IsolatedHomeRequired;
    var report: Report = .{ .loader = @tagName(o.kind), .base = o.base, .loader_version = o.version, .runtime_java = o.runtime_java, .installer_java = o.installer_java };
    defer save(a, io, o.report, report) catch {};
    runInner(init, o, &report) catch |err| {
        report.failure = @errorName(err);
        return err;
    };
}

fn runInner(init: std.process.Init, o: Options, report: *Report) anyerror!void {
    const a = init.arena.allocator();
    const io = init.io;
    try curl.globalInit();
    defer curl.globalDeinit();
    var paths = try instances.Paths.init(a, io, o.root);
    defer paths.deinit();
    var store = try config.Store.init(a, io, paths.root);
    defer store.deinit();
    var registry = tasks.Registry.init(init.gpa);
    defer registry.deinit();
    var coordinator = leases.Coordinator.init(io);
    const mutation = coordinator.mutation(0);
    var manager = try manager_module.Manager.init(init.gpa, io, &paths, &registry, .{}, .{ .context = mutation, .acquire = leases.Mutation.acquireCallback, .recheck = leases.Mutation.recheckCallback, .release = leases.Mutation.releaseCallback });
    defer {
        manager.cancelAndJoin();
        if (manager.snapshot().phase == .awaiting_publication) manager.publish(&store) catch {};
        manager.deinit();
        coordinator.tick();
        report.worker_joined = true;
        report.leases_released = blk: {
            coordinator.reserveLaunch("loader-acceptance") catch break :blk false;
            coordinator.releaseLaunch();
            coordinator.tick();
            break :blk true;
        };
    }
    manager.setWorkerRecheck(leases.Mutation.workerRecheckCallback);
    manager.setInstaller(manager_module.productionInstaller());
    var flag: std.atomic.Value(bool) = .init(false);
    var watching_done: std.atomic.Value(bool) = .init(false);
    var watcher = try io.concurrent(watchCancel, .{ io, o, &flag, &watching_done });
    defer {
        watching_done.store(true, .release);
        watcher.await(io);
    }
    errdefer if (flag.load(.acquire)) {
        report.canceled = true;
    };
    if (o.mode == .catalogue) {
        const adapter = manager_module.productionLoaderCatalogue();
        var catalogue = try adapter.fetch(adapter.context, a, io, o.base, o.kind, .{ .cancel = &flag, .cache_root = paths.cache });
        defer catalogue.deinit();
        const copy = try catalogue.clone(a);
        report.catalogue = copy.entries;
        report.phase = "catalogue_complete";
        return;
    }
    const runtime = try java.probe(a, io, o.runtime_java, &flag);
    report.runtime_java_major = runtime.major;
    if (o.installer_java) |path| {
        const installer_runtime = try java.probe(a, io, path, &flag);
        report.installer_java_major = installer_runtime.major;
    }
    const env = try library.hostEnvironment();
    const instance: config.Instance = .{ .id = "loader-acceptance", .name = "Acceptance", .minecraft_version = o.base, .loader = o.kind, .loader_version = o.version, .java_path = o.runtime_java, .max_memory_mb = o.memory };
    var prepared: ?loader_install.PreparedMetadata = null;
    defer if (prepared) |*owner| owner.deinit();
    // Manager must JOIN before borrowed preparation is destroyed (LIFO).
    defer manager.cancelAndJoin();
    if (instances.findById(&store.state.value, instance.id)) |existing| {
        if (!manager_module.sameInstance(existing.*, instance)) return error.SelectedConfigMismatch;
    } else {
        report.phase = "preparing";
        try save(a, io, o.report, report.*);
        if (o.kind == .vanilla) {
            try manager.startCreate(instance);
        } else {
            var client = try http.Client.init(a, io, .{});
            defer client.deinit();
            var response = try client.execute(.{ .url = metadata.version_manifest_url, .cancel = &flag, .max_response_bytes = 16 * 1024 * 1024, .require_public_address = true });
            defer response.deinit();
            if (response.status != 200) return error.ManifestHttpFailure;
            var manifest = try metadata.manifest.parseSlice(a, response.body);
            defer manifest.deinit();
            var vanilla_fetch: OfficialMetadata = .{ .client = &client, .cancel = &flag };
            prepared = try loader_install.prepareMetadata(a, io, .{ .root = paths.root, .instance_id = instance.id, .instance_name = instance.name, .generation = 1, .selection = .{ .kind = std.meta.stringToEnum(loaders.Kind, @tagName(o.kind)).?, .base_id = o.base, .loader_id = o.version.? }, .environment = env, .vanilla = .{ .version_id = o.base, .manifest = manifest.value, .cancel = &flag }, .fetcher = .{ .context = &vanilla_fetch, .fetch = OfficialMetadata.get } }, .{ .cancel = &flag, .deadline_ms = nowMilliseconds(@constCast(&io)) + 300_000, .context = @constCast(&io), .now_ms = nowMilliseconds });
            report.required_java_major = prepared.?.requirements.runtime_major;
            if (report.required_java_major.? != runtime.major) return error.JavaMajorMismatch;
            try manager.startCreatePreparedWithJava(instance, &prepared.?, 1, o.installer_java);
        }
        report.phase = "installing";
        try save(a, io, o.report, report.*);
        const start = std.Io.Clock.awake.now(io).nanoseconds;
        while (manager.snapshot().phase == .working) {
            if (canceled(io, o, start)) {
                report.canceled = true;
                manager.cancelAndJoin();
            }
            manager.tick();
            try io.sleep(.fromMilliseconds(50), .awake);
        }
        report.worker_joined = true;
        const snapshot = manager.snapshot();
        // Details retain at most eight files and strip query/fragment data.
        // Copy before releasing the manager snapshot; also redact URL userinfo.
        var failures: std.ArrayList(DownloadFailure) = .empty;
        for (snapshot.details.files[0..snapshot.details.file_count]) |file| {
            const failure = file.failure orelse continue;
            if (failure == error.Canceled) continue;
            const raw_path = file.path();
            var safe_path = raw_path[0 .. std.mem.indexOfAny(u8, raw_path, "?#") orelse raw_path.len];
            if (std.mem.indexOf(u8, safe_path, "://")) |scheme_end| {
                const authority = safe_path[scheme_end + 3 ..];
                const authority_end = std.mem.indexOfScalar(u8, authority, '/') orelse authority.len;
                if (std.mem.lastIndexOfScalar(u8, authority[0..authority_end], '@')) |userinfo_end| {
                    safe_path = try std.fmt.allocPrint(a, "{s}{s}", .{ safe_path[0 .. scheme_end + 3], authority[userinfo_end + 1 ..] });
                }
            }
            try failures.append(a, .{ .path = try a.dupe(u8, safe_path), .state = @tagName(file.state), .failure = @errorName(failure) });
        }
        report.download_failures = try failures.toOwnedSlice(a);
        if (snapshot.failure) |err| return @as(anyerror!void, err);
        if (snapshot.phase == .canceled) return error.Canceled;
        if (snapshot.phase != .awaiting_publication) return error.InstallationIncomplete;
        report.durability_uncertain = snapshot.durability_uncertain;
        try manager.publish(&store);
    }
    report.published = true;
    report.selected_config = try manager_module.cloneInstance(a, (instances.findById(&store.state.value, instance.id) orelse return error.ConfigurationNotPublished).*);
    const directory = try paths.instanceDirectory(instance.name);
    const document = try paths.versionDocument(instance.name);
    const receipt_name = if (o.kind == .vanilla) ".vela-instance.json" else ".vela-loader.json";
    const receipt = try std.fs.path.join(a, &.{ directory, receipt_name });
    report.receipt_path = receipt;
    report.receipt_sha256 = try digest(a, try std.Io.Dir.cwd().readFileAlloc(io, receipt, a, .limited(8 * 1024 * 1024)));
    report.metadata_sha256 = try digest(a, try std.Io.Dir.cwd().readFileAlloc(io, document, a, .limited(8 * 1024 * 1024)));
    report.phase = "installed";
    try save(a, io, o.report, report.*);
    if (o.mode == .install) return;
    var loaded = try metadata_loader.loadInstalled(a, io, .{ .root = paths.minecraft, .version_id = instance.name, .metadata_path = document });
    defer loaded.deinit();
    report.required_java_major = metadata.version.requiredJavaMajor(loaded.version.value);
    if (report.required_java_major.? != runtime.major) return error.JavaMajorMismatch;
    var assets = try library.loadAssets(a, io, paths.minecraft, (loaded.version.value.asset_index orelse return error.MissingAssetIndex).id);
    defer assets.deinit();
    const client_relative_path = try @import("core/minecraft/layout.zig").installedClient(a, loaded.version.value);
    defer a.free(client_relative_path);
    var plan = try planner.buildInstalled(a, loaded.version.value, assets.value, env, .{ .root = paths.minecraft, .client_relative_path = client_relative_path, .instance_name = instance.name, .game_directory = directory });
    defer plan.deinit();
    const uuid = offlineUuid();
    var command = try launch.build(a, loaded.version.value, plan.value, env, .{ .root = paths.minecraft, .java_executable = o.runtime_java, .identity = .{ .name = "Acceptance", .uuid = &uuid }, .game_directory = directory, .max_memory_mb = o.memory, .extra_jvm = o.extra_jvm.items, .extra_game = o.extra_game.items });
    defer command.deinit();
    report.planned_argv_sanitized = try sanitize(a, command.value.argv);
    report.cwd = try a.dupe(u8, command.value.cwd);
    report.phase = "dryrun_complete";
    if (o.mode == .dryrun) return;
    var controller = try game.Controller.initWithOptions(init.gpa, io, paths.minecraft, .{ .log_directory = paths.logs, .launch_guard = .{ .context = &coordinator, .acquire = launchAcquire, .release = launchRelease } });
    defer {
        controller.stop();
        controller.deinit();
        report.launch_joined = true;
    }
    try controller.startWithOptions(.{ .version = instance.name, .java_path = o.runtime_java, .java_major = runtime.major, .username = "Acceptance", .max_memory_mb = o.memory }, .{ .instance_id = instance.id, .launcher_root = paths.root, .instance_directory = directory, .metadata_path = document, .identity = .{ .name = "Acceptance", .uuid = &uuid }, .extra_jvm = o.extra_jvm.items, .extra_game = o.extra_game.items });
    var started: ?i96 = null;
    const launch_start = std.Io.Clock.awake.now(io).nanoseconds;
    while (true) {
        controller.tick();
        const snapshot = controller.snapshot();
        if (snapshot.failure) |err| return @as(anyerror!void, err);
        if (snapshot.phase == .running and started == null) {
            started = std.Io.Clock.awake.now(io).nanoseconds;
            report.native_java_started = true;
            report.phase = "running";
            try save(a, io, o.report, report.*);
        }
        if (snapshot.phase == .exited) return error.GameExitedBeforeObservation;
        if (canceled(io, o, launch_start)) {
            report.canceled = true;
            controller.stop();
            break;
        }
        if (started) |time| if (elapsed(io, time) >= @as(u64, o.seconds) * 1000) {
            controller.stop();
            break;
        };
        if (elapsed(io, launch_start) > 180 * 1000 and started == null) return error.LaunchPreparationTimeout;
        try io.sleep(.fromMilliseconds(100), .awake);
    }
    report.phase = if (report.canceled) "canceled" else "startup_observed";
}

test "offline identity and sanitized sensitive argv" {
    const a = std.testing.allocator;
    const argv = try sanitize(a, &.{ "java", "--accessToken", "0", "--xuid", "", "--username", "Acceptance" });
    defer {
        for (argv) |arg| if (!std.mem.eql(u8, arg, "<redacted>")) a.free(arg);
        a.free(argv);
    }
    try std.testing.expectEqualStrings("<redacted>", argv[2]);
    try std.testing.expectEqualStrings("<redacted>", argv[4]);
    try std.testing.expectEqualStrings("Acceptance", argv[6]);
    const uuid = offlineUuid();
    try std.testing.expectEqual(@as(u8, '3'), uuid[12]);
}

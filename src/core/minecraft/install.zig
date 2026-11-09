//! Synchronous installation orchestration. Run outside the UI thread.
const std = @import("std");
const dl = @import("../downloader.zig");
const network_proxy = @import("../proxy_policy.zig");
const telemetry = @import("../install/download_details.zig");
const task_registry = @import("../tasks.zig");
const m = @import("metadata/root.zig");
const planner = @import("install_plan.zig");
const native = @import("native_extract.zig");
const loader = @import("metadata_loader.zig");
const installation = @import("../install/root.zig");
const instances = @import("../instances.zig");
const namespace = @import("../instance_namespace.zig");
const fs = @import("../install/safe_fs.zig");
const A = std.mem.Allocator;
pub const Progress = installation.Progress;
pub const Config = struct {
    version_id: []const u8,
    root: []const u8 = ".minecraft",
    target: @import("layout.zig").Target,
    game_directory: ?[]const u8 = null,
    /// Stage extracted natives separately while root retains shared artifacts.
    natives_directory: ?[]const u8 = null,
    /// False prepares artifacts/aliases only; caller owns descriptor publication.
    publish_metadata: bool = true,
    /// Protects namespace name/reference scans only; it does not exclude launch.
    /// Managed callers must independently hold the stable-ID instance lease.
    /// Borrowed reservations remain owned by the caller through all cleanup.
    namespace_token: ?namespace.Token = null,
    /// Worker admission may wait for the short namespace stamp gate.
    worker_checks: bool = false,
    metadata_path: ?[]const u8 = null,
    metadata_limits: m.version.inheritance.Limits = .{},
    manifest_url: []const u8 = m.version_manifest_url,
    /// Metadata cache directory, owned by the caller and not shared by active services.
    http_cache: ?[]const u8 = null,
    /// Launcher-owned shared file cache; standalone callers default beneath root.
    artifact_cache_root: ?[]const u8 = null,
    environment: m.rules.Environment,
    proxy: ?[]const u8 = null,
    proxy_policy: ?*const network_proxy.Policy = null,
    ca_bundle: ?[]const u8 = null,
    window: usize = 16,
    cancel: ?*const std.atomic.Value(bool) = null,
    progress: ?*const fn (Progress) void = null,
    /// Borrowed until synchronous installation and downloader drain complete.
    task: ?*task_registry.Task = null,
};
pub const Installed = struct {
    version: m.Owned(m.version.Version),
    plan: m.Owned(planner.Plan),
    downloaded: usize,
    reused: usize,
    pub fn deinit(self: *Installed) void {
        self.plan.deinit();
        self.version.deinit();
        self.* = undefined;
    }
};
/// Caller owns service/curl lifetime. Only one installer may mutate a given root.
/// Returned metadata and plan own their data independently of download handles.
pub fn run(a: A, io: std.Io, service: *dl.Service, options: Config) !Installed {
    try validateConfig(options);
    var policy = if (options.proxy_policy) |value| try value.clone(a) else try network_proxy.capture(a, io, options.proxy);
    defer policy.deinit();
    var config = options;
    config.proxy_policy = &policy;
    const token = try reserveNamespace(io, config.namespace_token, config.worker_checks);
    defer if (config.namespace_token == null) token.release();
    var reserved_config = config;
    reserved_config.namespace_token = token;
    const loaded = if (config.metadata_path) |path|
        try loader.loadInstalled(a, io, .{ .root = config.root, .version_id = config.version_id, .metadata_path = path, .cancel = config.cancel, .limits = config.metadata_limits })
    else sources: {
        const manifest_bytes = try fetch(a, io, service, config, config.manifest_url, null, null);
        defer a.free(manifest_bytes);
        var manifest = try m.manifest.parseSlice(a, manifest_bytes);
        defer manifest.deinit();
        var fetch_context: FetchContext = .{ .service = service, .config = config };
        break :sources try loader.fetchSources(a, io, .{ .version_id = config.version_id, .manifest = manifest.value, .cancel = config.cancel, .limits = config.metadata_limits }, .{ .context = &fetch_context, .fetch = fetchMetadata });
    };
    return runLoaded(a, io, service, reserved_config, loaded, null);
}

/// Replays a sealed vanilla base without manifest or version metadata refetch.
pub fn runVanillaPrepared(a: A, io: std.Io, service: *dl.Service, config: Config, prepared: *const loader.PreparedVanilla, target: loader.VanillaTarget) !Installed {
    try validateConfig(config);
    const token = try reserveNamespace(io, config.namespace_token, config.worker_checks);
    defer if (config.namespace_token == null) token.release();
    var reserved_config = config;
    reserved_config.namespace_token = token;
    if (!std.mem.eql(u8, config.version_id, target.version_id) or !std.mem.eql(u8, config.target.name, target.instance_name)) return error.PreparedMetadataMismatch;
    var expected_paths = try instances.Paths.init(a, io, target.root);
    defer expected_paths.deinit();
    var actual_paths = try instances.Paths.init(a, io, config.root);
    defer actual_paths.deinit();
    if (!std.mem.eql(u8, actual_paths.root, expected_paths.minecraft)) return error.PreparedMetadataMismatch;
    var bound_target = target;
    bound_target.environment = config.environment;
    const loaded = try prepared.replayBase(a, io, bound_target, config.cancel);
    return runLoaded(a, io, service, reserved_config, loaded, null);
}

const reserveNamespace = @import("../install/namespace.zig").reserve;

pub fn validateConfig(config: Config) !void {
    if (config.window == 0 or config.window > 128) return error.InvalidWindow;
    try m.version.validateId(config.version_id);
    try config.target.validate();
    try canceled(config.cancel);
}

/// Consumes both loaded owners on every path; version and plan move to the result.
/// The optional external control shares cancellation and deadline semantics with adapters.
pub fn runLoaded(a: A, io: std.Io, service: *dl.Service, options: Config, owned_loaded: loader.Loaded, external_control: ?installation.Control) !Installed {
    var config = options;
    validateConfig(config) catch |err| {
        var failed_loaded = owned_loaded;
        failed_loaded.deinit();
        return err;
    };
    const token = reserveNamespace(io, config.namespace_token, config.worker_checks) catch |err| {
        var failed_loaded = owned_loaded;
        failed_loaded.deinit();
        return err;
    };
    // Registered first so task drain, native cleanup and every close finish first.
    defer if (config.namespace_token == null) token.release();
    var loaded = owned_loaded;
    defer loaded.sources.deinit();
    var version = loaded.version;
    errdefer version.deinit();
    var policy = if (config.proxy_policy) |value| try value.clone(a) else try network_proxy.capture(a, io, config.proxy);
    defer policy.deinit();
    config.proxy_policy = &policy;
    const control: InstallControl = .{ .cancel = config.cancel, .external = external_control };
    try control.check();
    const index = version.value.asset_index orelse return error.MissingAssetIndex;
    try component(index.id);
    const assets_bytes = try fetchBoundedControlled(a, io, service, config, index.url, index.sha1, index.size, 64 * 1024 * 1024, control);
    defer a.free(assets_bytes);
    var assets = try m.asset_index.parseSlice(a, assets_bytes);
    defer assets.deinit();
    try control.check();
    const cpu_arch = config.environment.arch;
    const client_relative_path = try config.target.clientPath(a);
    defer a.free(client_relative_path);
    var plan = try planner.build(a, version.value, assets.value, config.environment, .{ .root = config.root, .client_relative_path = client_relative_path, .natives = config.natives_directory, .instance_name = config.target.directory_name, .game_directory = config.game_directory });
    errdefer plan.deinit();
    try control.check();
    var publication_config = config;
    publication_config.namespace_token = token;
    const descriptor: ?Publication = if (config.publish_metadata) try preparePublication(a, io, publication_config, version.value, control) else null;
    defer if (descriptor) |value| {
        a.free(value.bytes);
        a.free(value.path);
    };
    for (plan.value.files) |file| if (file.kind == .asset_index) {
        try control.check();
        try fs.writeAtomic(a, io, file.path, assets_bytes, config.cancel);
        try control.check();
    };
    const artifact_root = if (config.artifact_cache_root) |path| try a.dupe(u8, path) else try std.fs.path.join(a, &.{ config.root, ".vela", "cache" });
    defer a.free(artifact_root);
    var downloaded: usize = 0;
    var reused: usize = 0;
    var tasks: std.ArrayList(PendingDownload) = .empty;
    var received_done: u64 = 0;
    var total_bytes_done: ?u64 = 0;
    var recent: task_registry.Details = .{};
    var download_rate: DownloadRate = .{ .io = io, .last_time = std.Io.Clock.awake.now(io).nanoseconds };
    defer tasks.deinit(a);
    // Every task handle is terminal before release, including all failure paths.
    defer if (tasks.items.len != 0) {
        for (tasks.items) |pending| pending.task.cancel();
        for (tasks.items) |pending| pending.task.join();
        reportDownloads(config.task, tasks.items, reused + downloaded, plan.value.files.len, received_done, total_bytes_done, null, &recent);
        for (tasks.items) |pending| pending.task.release() catch unreachable;
    };
    try tasks.ensureTotalCapacity(a, config.window);
    var cursor: usize = 0;
    while (cursor < plan.value.files.len or tasks.items.len != 0) {
        const completion_revision = service.completionRevision();
        try control.check();
        while (cursor < plan.value.files.len and tasks.items.len < config.window) {
            const file = plan.value.files[cursor];
            try control.check();
            try ensureParents(io, file.path);
            try control.check();
            reportChecking(config.task, tasks.items, &recent, file, reused + downloaded, plan.value.files.len, received_done, total_bytes_done, &download_rate);
            if (file.kind == .asset_index or try verifiedControlled(io, file, control)) {
                reused += 1;
                rememberFile(&recent, task_registry.File.init(file.path, file.size orelse 0, file.size, 0, .complete, null));
                reportDownloads(config.task, tasks.items, reused + downloaded, plan.value.files.len, received_done, total_bytes_done, &download_rate, &recent);
                if (config.progress) |report| report(.{ .completed = reused + downloaded, .total = plan.value.files.len, .downloaded = downloaded, .reused = reused });
                try control.check();
                cursor += 1;
                continue;
            }
            try control.check();
            const task = service.submit(.{ .url = file.url, .output = .{ .file = file.path }, .expected_sha1 = file.sha1, .expected_size = file.size, .artifact_cache_root = artifact_root, .proxy = config.proxy, .proxy_policy = config.proxy_policy, .ca_bundle = config.ca_bundle }) catch |err| {
                try control.check();
                if (err == error.QueueFull and tasks.items.len != 0) break;
                return err;
            };
            tasks.appendAssumeCapacity(.{ .task = task, .path = file.path });
            try control.check();
            cursor += 1;
        }
        reportDownloads(config.task, tasks.items, reused + downloaded, plan.value.files.len, received_done, total_bytes_done, &download_rate, &recent);
        var i: usize = 0;
        while (i < tasks.items.len) {
            try control.check();
            const task = tasks.items[i].task;
            const snapshot = task.snapshot();
            if (!dl.terminal(snapshot.progress.phase)) {
                i += 1;
                continue;
            }
            // Publish this terminal sample while the label and handle are alive.
            reportDownloads(config.task, tasks.items, reused + downloaded, plan.value.files.len, received_done, total_bytes_done, &download_rate, &recent);
            // Keep failed handles in the cleanup batch so final cancellation samples
            // cannot replace the offending file. Preserve control-error precedence.
            if (snapshot.failure != null or snapshot.progress.phase != .complete) {
                try control.check();
                if (snapshot.failure) |err| return err;
                return error.DownloadFailed;
            }
            rememberFile(&recent, telemetry.file(tasks.items[i].path, snapshot));
            if (snapshot.source != .artifact) {
                received_done +|= snapshot.progress.received;
                total_bytes_done = if (total_bytes_done) |sum| if (snapshot.progress.total) |n| sum +| n else null else null;
            }
            _ = tasks.swapRemove(i);
            try task.release();
            try control.check();
            if (snapshot.source == .artifact) reused += 1 else downloaded += 1;
            reportDownloads(config.task, tasks.items, reused + downloaded, plan.value.files.len, received_done, total_bytes_done, &download_rate, &recent);
            if (config.progress) |report| report(.{ .completed = reused + downloaded, .total = plan.value.files.len, .downloaded = downloaded, .reused = reused });
            try control.check();
        }
        if (tasks.items.len != 0) {
            try control.check();
            try service.waitForCompletion(completion_revision);
            try control.check();
        }
    }
    if (config.task) |task_owner| task_owner.report(.verifying, reused + downloaded, plan.value.files.len);
    for (plan.value.native_checks) |check| {
        try control.check();
        try native.inspectWithFamily(a, io, check.archive_path, cpu_arch, config.cancel, check.classic_family);
        try control.check();
    }
    // Shared destinations must remain one native merge transaction.
    try control.check();
    if (config.task) |task_owner| task_owner.report(.extracting, reused + downloaded, plan.value.files.len);
    try native.extractChecked(a, io, plan.value.native_extractions, cpu_arch, config.cancel);
    try control.check();
    for (plan.value.asset_materializations) |alias| {
        try control.check();
        try materializeControlled(a, io, alias, control);
        try control.check();
    }
    if (descriptor) |value| try publishMetadata(a, io, publication_config, value, control) else try control.check();
    return .{ .version = version, .plan = plan, .downloaded = downloaded, .reused = reused };
}
const PendingDownload = struct { task: *dl.Task, path: []const u8 };

/// Measured aggregate throughput across the entire artifact-download stage.
const DownloadRate = struct {
    io: std.Io,
    last_time: i96,
    last_received: u64 = 0,
    last_change: i96 = 0,
    speed: f64 = 0,

    fn update(self: *DownloadRate, now: i96, received: u64) f64 {
        const elapsed = now - self.last_time;
        const delta = received -| self.last_received;
        if (delta > 0) self.last_change = now;
        if (elapsed > 0 and (elapsed >= 100 * std.time.ns_per_ms or (self.speed == 0 and delta > 0))) {
            const measured = @as(f64, @floatFromInt(delta)) * std.time.ns_per_s / @as(f64, @floatFromInt(elapsed));
            self.speed = if (self.speed == 0) measured else 0.3 * measured + 0.7 * self.speed;
            self.last_time = now;
            self.last_received = received;
        }
        if (now - self.last_change >= std.time.ns_per_s) self.speed = 0;
        return self.speed;
    }
};
/// Bounded newest-first history. Active transfers take precedence at publication.
fn rememberFile(recent: *task_registry.Details, value: task_registry.File) void {
    var index: usize = 0;
    while (index < recent.file_count and !std.mem.eql(u8, recent.files[index].path(), value.path())) index += 1;
    const is_new = index == recent.file_count;
    index = @min(index, recent.files.len - 1);
    while (index > 0) : (index -= 1) recent.files[index] = recent.files[index - 1];
    recent.files[0] = value;
    if (is_new) recent.file_count = @min(recent.file_count + 1, recent.files.len);
}

fn reportChecking(target: ?*task_registry.Task, pending: []const PendingDownload, recent: *task_registry.Details, file: planner.File, completed: usize, total: usize, received_done: u64, total_done: ?u64, rate: *DownloadRate) void {
    if (target == null) return;
    rememberFile(recent, task_registry.File.init(file.path, 0, file.size, 0, .verifying, null));
    reportDownloads(target, pending, completed, total, received_done, total_done, rate, recent);
}

fn reportDownloads(target: ?*task_registry.Task, pending: []const PendingDownload, completed: usize, total: usize, received_done: u64, total_done: ?u64, rate: ?*DownloadRate, recent: ?*const task_registry.Details) void {
    const task = target orelse return;
    var details: task_registry.Details = .{ .stage = if (pending.len == 0) .verifying else .downloading, .completed = completed, .total = total, .received = received_done, .total_bytes = total_done };
    for (pending) |item| {
        const snapshot = item.task.snapshot();
        const value = telemetry.file(item.path, snapshot);
        if (snapshot.source != .artifact) {
            details.received +|= value.received;
            details.total_bytes = if (details.total_bytes) |sum| if (value.total) |n| sum +| n else null else null;
            details.bytes_per_second += value.bytes_per_second;
        }
        details.addFile(value);
    }
    // Completed handles contribute to received_done, so the batch rate survives
    // short-file completion and replacement instead of summing only live handles.
    if (pending.len != 0) {
        if (rate) |sample| details.bytes_per_second = sample.update(std.Io.Clock.awake.now(sample.io).nanoseconds, details.received);
    }
    if (recent) |history| for (history.files[0..history.file_count]) |entry| {
        var active = false;
        for (pending) |item| if (std.mem.eql(u8, item.path, entry.path())) {
            active = true;
            break;
        };
        if (!active) details.addFile(entry);
    };
    task.reportDetails(details);
}

const InstallControl = struct {
    cancel: fs.Cancel = null,
    external: ?installation.Control = null,
    fn check(self: InstallControl) !void {
        try canceled(self.cancel);
        if (self.external) |control| try control.check();
    }
};
fn canceled(cancel: ?*const std.atomic.Value(bool)) !void {
    if (cancel) |flag| if (flag.load(.acquire)) return error.Canceled;
}
const FetchContext = struct { service: *dl.Service, config: Config };
fn fetchMetadata(context: ?*anyopaque, a: A, io: std.Io, request: loader.Request) anyerror![]u8 {
    const state: *FetchContext = @ptrCast(@alignCast(context orelse return error.MissingVersionMetadata));
    return fetchBounded(a, io, state.service, state.config, request.url, request.sha1, request.size, request.max_bytes);
}
fn fetch(a: A, io: std.Io, service: *dl.Service, config: Config, url: []const u8, sha1: ?m.Sha1, size: ?u64) ![]u8 {
    return fetchBounded(a, io, service, config, url, sha1, size, 64 * 1024 * 1024);
}
fn fetchBounded(a: A, io: std.Io, service: *dl.Service, config: Config, url: []const u8, sha1: ?m.Sha1, size: ?u64, max_bytes: usize) ![]u8 {
    return fetchBoundedControlled(a, io, service, config, url, sha1, size, max_bytes, .{ .cancel = config.cancel });
}
fn fetchBoundedControlled(a: A, io: std.Io, service: *dl.Service, config: Config, url: []const u8, sha1: ?m.Sha1, size: ?u64, max_bytes: usize, control: InstallControl) ![]u8 {
    try control.check();
    const cache_path = if (config.http_cache) |directory| blk: {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        const filename = try std.fmt.allocPrint(a, "{s}.json", .{hex});
        defer a.free(filename);
        const path = try std.fs.path.join(a, &.{ directory, filename });
        errdefer a.free(path);
        try control.check();
        try ensureParents(io, path);
        try control.check();
        break :blk path;
    } else null;
    defer if (cache_path) |path| a.free(path);
    try control.check();
    const task = try service.submit(.{ .url = url, .output = .bytes, .expected_sha1 = sha1, .expected_size = size, .max_bytes = max_bytes, .proxy = config.proxy, .proxy_policy = config.proxy_policy, .ca_bundle = config.ca_bundle, .cache_path = cache_path });
    defer {
        task.cancel();
        task.join();
        telemetry.single(config.task, .metadata, url, task.snapshot());
        task.release() catch unreachable;
    }
    try control.check();
    while (true) {
        try control.check();
        const state = task.snapshot();
        telemetry.single(config.task, .metadata, url, state);
        if (dl.terminal(state.progress.phase)) {
            if (state.failure) |err| return err;
            if (state.progress.phase != .complete) return error.DownloadFailed;
            const bytes = try a.dupe(u8, state.result.?.bytes);
            errdefer a.free(bytes);
            try control.check();
            return bytes;
        }
        try control.check();
        try task.wait();
        try control.check();
    }
}
fn component(name: []const u8) !void {
    try fs.component(name);
}
/// Reject existing symlink parents, including inside the configured root.
/// Caller must exclude concurrent hostile filesystem mutations.
fn ensureParents(io: std.Io, path: []const u8) !void {
    var parent = try fs.openParent(io, path, true);
    parent.close(io);
}
fn verified(io: std.Io, file: planner.File, cancel: ?*const std.atomic.Value(bool)) !bool {
    return verifiedControlled(io, file, .{ .cancel = cancel });
}
fn verifiedControlled(io: std.Io, file: planner.File, control: InstallControl) !bool {
    try control.check();
    const expected = file.sha1 orelse return false;
    const f = fs.openFile(io, file.path) catch |err| {
        try control.check();
        switch (err) {
            error.FileNotFound => return false,
            else => return err,
        }
    };
    defer f.close(io);
    try control.check();
    const stat = try f.stat(io);
    try control.check();
    if (stat.kind != .file) return error.NotRegularFile;
    if (file.size) |size| if (stat.size != size) return false;
    var hash = std.crypto.hash.Sha1.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        try control.check();
        const n = try f.readPositional(io, &.{&buffer}, offset);
        try control.check();
        if (n == 0) break;
        hash.update(buffer[0..n]);
        offset += n;
    }
    var digest: m.Sha1 = undefined;
    hash.final(&digest);
    return std.mem.eql(u8, &digest, &expected);
}
fn writeAtomic(a: A, io: std.Io, path: []const u8, data: []const u8) !void {
    try fs.writeAtomic(a, io, path, data, null);
}

const Publication = struct { path: []const u8, bytes: []const u8 };
fn existingMatches(a: A, io: std.Io, path: []const u8, bytes: []const u8, cancel: fs.Cancel) !bool {
    return existingMatchesControlled(a, io, path, bytes, .{ .cancel = cancel });
}
fn existingMatchesControlled(a: A, io: std.Io, path: []const u8, bytes: []const u8, control: InstallControl) !bool {
    try control.check();
    const existing = fs.read(a, io, path, m.version.max_document_bytes, control.cancel) catch |err| {
        try control.check();
        switch (err) {
            error.FileNotFound => return false,
            else => return err,
        }
    };
    defer a.free(existing);
    try control.check();
    if (!std.mem.eql(u8, bytes, existing)) return error.InstanceMetadataCollision;
    return true;
}
fn preparePublication(a: A, io: std.Io, config: Config, version: m.version.Version, control: InstallControl) !Publication {
    const token = try reserveNamespace(io, config.namespace_token, config.worker_checks);
    defer if (config.namespace_token == null) token.release();
    try control.check();
    try config.target.validate();
    const relative = try config.target.documentPath(a);
    defer a.free(relative);
    const path = try std.fs.path.join(a, &.{ config.root, relative });
    errdefer a.free(path);
    var owned = version;
    owned.id = config.target.name;
    owned.jar = null;
    owned.inherits_from = null;
    const bytes = try @import("version_serialize.zig").serialize(a, owned);
    errdefer a.free(bytes);
    _ = try existingMatchesControlled(a, io, path, bytes, control);
    try control.check();
    return .{ .path = path, .bytes = bytes };
}
fn publishMetadata(a: A, io: std.Io, config: Config, descriptor: Publication, control: InstallControl) !void {
    const token = try reserveNamespace(io, config.namespace_token, config.worker_checks);
    defer if (config.namespace_token == null) token.release();
    try control.check();
    _ = try existingMatchesControlled(a, io, descriptor.path, descriptor.bytes, control);
    try control.check();
    // Publish only this instance; source metadata never creates parent instances.
    try fs.writeAtomic(a, io, descriptor.path, descriptor.bytes, control.cancel);
}
fn materialize(a: A, io: std.Io, alias: planner.AssetMaterialization, cancel: fs.Cancel) !void {
    return materializeControlled(a, io, alias, .{ .cancel = cancel });
}
fn materializeControlled(a: A, io: std.Io, alias: planner.AssetMaterialization, control: InstallControl) !void {
    const file: planner.File = .{ .kind = .asset, .url = "unused", .path = alias.destination, .sha1 = alias.sha1, .size = alias.size };
    if (try verifiedControlled(io, file, control)) return;
    try control.check();
    const source = try fs.openFile(io, alias.source_path);
    defer source.close(io);
    try control.check();
    const stat = try source.stat(io);
    try control.check();
    if (stat.size != alias.size) return error.AssetSizeMismatch;
    var parent = try fs.openParent(io, alias.destination, true);
    defer parent.close(io);
    try control.check();
    const name = std.fs.path.basename(alias.destination);
    const old = parent.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    try control.check();
    if (old) |info| if (info.kind != .file) return error.UnsafeDestination;
    var random: [16]u8 = undefined;
    io.random(&random);
    const temp = try std.fmt.allocPrint(a, ".asset-{s}", .{std.fmt.bytesToHex(random, .lower)});
    defer a.free(temp);
    try control.check();
    const output = try parent.createFile(io, temp, .{ .exclusive = true });
    var closed = false;
    defer if (!closed) output.close(io);
    defer parent.deleteFile(io, temp) catch {};
    try control.check();
    var hash = std.crypto.hash.Sha1.init(.{});
    var buffer: [65536]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        try control.check();
        const n = try source.readPositional(io, &.{&buffer}, offset);
        try control.check();
        if (n == 0) break;
        offset = std.math.add(u64, offset, n) catch return error.AssetSizeMismatch;
        if (offset > alias.size) return error.AssetSizeMismatch;
        hash.update(buffer[0..n]);
        try control.check();
        try output.writeStreamingAll(io, buffer[0..n]);
        try control.check();
    }
    var digest: m.Sha1 = undefined;
    hash.final(&digest);
    if (offset != alias.size) return error.AssetSizeMismatch;
    if (!std.mem.eql(u8, &digest, &alias.sha1)) return error.AssetChecksumMismatch;
    try control.check();
    try output.sync(io);
    try control.check();
    output.close(io);
    closed = true;
    try control.check();
    try parent.rename(temp, parent, name, io);
    try control.check();
}

test "existing files require streamed checksum and size verification" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const path = try std.fmt.allocPrint(a, "{s}/nested/object", .{buf[0..n]});
    defer a.free(path);
    const body = "verified game bytes";
    try writeAtomic(a, io, path, body);
    var sha: m.Sha1 = undefined;
    std.crypto.hash.Sha1.hash(body, &sha, .{});
    var file: planner.File = .{ .kind = .asset, .path = path, .url = "unused", .size = body.len, .sha1 = sha };
    try std.testing.expect(try verified(io, file, null));
    file.size = body.len + 1;
    try std.testing.expect(!try verified(io, file, null));
    file.size = body.len;
    try writeAtomic(a, io, path, "corrupted game byte");
    try std.testing.expect(!try verified(io, file, null));
    file.sha1 = null;
    try std.testing.expect(!try verified(io, file, null));
    var cancel = std.atomic.Value(bool).init(true);
    file.sha1 = sha;
    file.size = null;
    try std.testing.expectError(error.Canceled, verified(io, file, &cancel));
}

test "installation metadata IDs cannot escape their directory" {
    for ([_][]const u8{ "../evil", "/abs", "a/b", "C:bad", "..", "" }) |id|
        try std.testing.expectError(error.UnsafePath, component(id));
    try std.testing.expectError(error.UnsafePath, component(&.{ 'a', 92, 'b' }));
    try component("1.21.1");
}

test {
    _ = native;
    _ = loader;
    _ = fs;
    // Loader preflight shares this executor and must honor the same source boundary.
    _ = @import("../loaders/install.zig");
}

test "executor invalid window fails before metadata IO" {
    var service: dl.Service = undefined;
    try std.testing.expectError(error.InvalidWindow, run(std.testing.allocator, std.testing.io, &service, .{ .target = .{ .directory_name = "Pack", .name = "Pack" }, .version_id = "fixture", .environment = .{ .os_name = "linux", .arch = "x86_64" }, .window = 0 }));
}

test "explicit metadata documents stay local without manifest transport or source fallback" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "provided.json" });
    defer a.free(path);
    var service: dl.Service = undefined;
    const config: Config = .{ .target = .{ .directory_name = "CLI Instance", .name = "CLI Instance" }, .version_id = "CLI Instance", .root = root, .metadata_path = path, .environment = .{ .os_name = "linux", .arch = "x86_64" } };
    try std.testing.expectError(error.MissingVersionMetadata, run(a, io, &service, config));
    try fs.writeAtomic(a, io, path, "{\"id\":\"custom\",\"inheritsFrom\":\"missing-parent\"}", null);
    try std.testing.expectError(error.MissingVersionMetadata, run(a, io, &service, config));
    try fs.writeAtomic(a, io, path, "{\"id\":\"custom\"}", null);
    try std.testing.expectError(error.MissingClientDownload, run(a, io, &service, config));
}

test "publication owns the target without writing source instances" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    const root = buffer[0..n];
    var source = try m.version.parseSlice(a, "{\"id\":\"forge\",\"mainClass\":\"fixture.Main\",\"inheritsFrom\":\"base\",\"jar\":\"base\",\"libraries\":[]}");
    defer source.deinit();
    const config: Config = .{ .version_id = "forge", .target = .{ .directory_name = "My Forge", .name = "My Forge" }, .root = root, .environment = .{ .os_name = "linux", .arch = "x86_64" } };
    const descriptor = try preparePublication(a, io, config, source.value, .{});
    defer a.free(descriptor.path);
    defer a.free(descriptor.bytes);
    try std.testing.expectError(error.FileNotFound, fs.read(a, io, descriptor.path, 4096, null));
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Canceled, publishMetadata(a, io, config, descriptor, .{ .cancel = &cancel }));
    try std.testing.expectError(error.FileNotFound, fs.read(a, io, descriptor.path, 4096, null));
    try publishMetadata(a, io, config, descriptor, .{});
    const bytes = try fs.read(a, io, descriptor.path, 4096, null);
    defer a.free(bytes);
    var document = try m.version.parseSlice(a, bytes);
    defer document.deinit();
    try std.testing.expectEqualStrings("My Forge", document.value.id);
    try std.testing.expectEqualStrings("fixture.Main", document.value.main_class.?);
    try std.testing.expect(document.value.inherits_from == null);
    try std.testing.expect(document.value.jar == null);
    for ([_][]const u8{ "base", "forge" }) |name| {
        const path = try loader.docPath(a, root, name);
        defer a.free(path);
        try std.testing.expectError(error.FileNotFound, fs.read(a, io, path, 4096, null));
    }
    const repeated = try preparePublication(a, io, config, source.value, .{});
    defer a.free(repeated.path);
    defer a.free(repeated.bytes);
    source.value.main_class = "Other";
    try std.testing.expectError(error.InstanceMetadataCollision, preparePublication(a, io, config, source.value, .{}));
    try writeAtomic(a, io, descriptor.path, "unrelated user descriptor");
    try std.testing.expectError(error.InstanceMetadataCollision, publishMetadata(a, io, config, descriptor, .{}));
    const retained = try fs.read(a, io, descriptor.path, 4096, null);
    defer a.free(retained);
    try std.testing.expectEqualStrings("unrelated user descriptor", retained);
}

test "asset materialization verifies repairs and preserves prior bytes on failure" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    const source = try std.fmt.allocPrint(a, "{s}/objects/source", .{buffer[0..n]});
    defer a.free(source);
    const destination = try std.fmt.allocPrint(a, "{s}/resources/sound.ogg", .{buffer[0..n]});
    defer a.free(destination);
    const body = "asset fixture bytes";
    var hash: m.Sha1 = undefined;
    std.crypto.hash.Sha1.hash(body, &hash, .{});
    const alias: planner.AssetMaterialization = .{ .source_path = source, .destination = destination, .sha1 = hash, .size = body.len };
    try writeAtomic(a, io, source, body);
    try materialize(a, io, alias, null);
    const good = try fs.read(a, io, destination, 1024, null);
    defer a.free(good);
    try std.testing.expectEqualStrings(body, good);
    try materialize(a, io, alias, null);
    try writeAtomic(a, io, destination, "prior bytes");
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Canceled, materialize(a, io, alias, &cancel));
    try writeAtomic(a, io, source, "wrong fixture bytes");
    try std.testing.expectError(error.AssetChecksumMismatch, materialize(a, io, alias, null));
    const preserved = try fs.read(a, io, destination, 1024, null);
    defer a.free(preserved);
    try std.testing.expectEqualStrings("prior bytes", preserved);
    try writeAtomic(a, io, source, body);
    try materialize(a, io, alias, null);
    const repaired = try fs.read(a, io, destination, 1024, null);
    defer a.free(repaired);
    try std.testing.expectEqualStrings(body, repaired);
}

// Missing assetIndex stops prepared vanilla fixtures before artifact IO.
const prepared_run_base =
    \\{"id":"1.20.1","mainClass":"vanilla.Main","libraries":[],"javaVersion":{"component":"java-runtime-gamma","majorVersion":17},"downloads":{"client":{"url":"https://piston-data.mojang.com/client.jar","sha1":"0000000000000000000000000000000000000000","size":8}}}
;
fn preparedRunConfig(minecraft: []const u8) Config {
    return .{ .version_id = "1.20.1", .root = minecraft, .target = .{ .directory_name = "private-stage", .name = "Final Vanilla" }, .environment = .{ .os_name = "linux", .arch = "x86_64" }, .manifest_url = "https://example.invalid/not-replay", .metadata_path = "missing-prepared-version.json" };
}

test "vanilla prepared executor validates config binding and cancellation before reading owner" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const prepared: loader.PreparedVanilla = undefined;
    const target: loader.VanillaTarget = .{ .root = ".", .instance_id = "vanilla-fixture", .instance_name = "Final Vanilla", .version_id = "1.20.1", .generation = 7, .environment = .{ .os_name = "linux", .arch = "x86_64" } };
    var service: dl.Service = undefined;
    var config = preparedRunConfig(".minecraft");
    config.window = 0;
    try std.testing.expectError(error.InvalidWindow, runVanillaPrepared(a, io, &service, config, &prepared, target));
    config.window = 129;
    try std.testing.expectError(error.InvalidWindow, runVanillaPrepared(a, io, &service, config, &prepared, target));
    config.window = 16;
    config.version_id = "../escape";
    try std.testing.expectError(error.UnsafeVersionId, runVanillaPrepared(a, io, &service, config, &prepared, target));
    config.version_id = "1.20.1";
    config.target.directory_name = "../escape";
    try std.testing.expectError(error.UnsafeVersionId, runVanillaPrepared(a, io, &service, config, &prepared, target));
    config.target = .{ .directory_name = "private-stage", .name = "Final Vanilla" };
    var cancel = std.atomic.Value(bool).init(true);
    config.cancel = &cancel;
    try std.testing.expectError(error.Canceled, runVanillaPrepared(a, io, &service, config, &prepared, target));
    config.cancel = null;
    config.version_id = "1.20.2";
    try std.testing.expectError(error.PreparedMetadataMismatch, runVanillaPrepared(a, io, &service, config, &prepared, target));
    config.version_id = "1.20.1";
    config.root = "different-vanilla-root";
    try std.testing.expectError(error.PreparedMetadataMismatch, runVanillaPrepared(a, io, &service, config, &prepared, target));
}

fn vanillaRunTarget(root: []const u8) loader.VanillaTarget {
    return .{ .root = root, .instance_id = "vanilla-fixture", .instance_name = "Final Vanilla", .version_id = "1.20.1", .generation = 7, .environment = .{ .os_name = "linux", .arch = "x86_64" } };
}
fn vanillaRunAllocationFailure(a: A, config: Config, prepared: *const loader.PreparedVanilla, target: loader.VanillaTarget) !void {
    var service: dl.Service = undefined;
    var installed = runVanillaPrepared(a, std.testing.io, &service, config, prepared, target) catch |err| switch (err) {
        error.MissingAssetIndex => return,
        else => return err,
    };
    installed.deinit();
    return error.UnexpectedFixtureInstallSuccess;
}

const VanillaRunFixture = struct {
    entries: [1]m.manifest.Entry = undefined,
    calls: usize = 0,

    fn prepare(self: *VanillaRunFixture, a: A, io: std.Io, root: []const u8) !loader.PreparedVanilla {
        var checksum: m.Sha1 = undefined;
        std.crypto.hash.Sha1.hash(prepared_run_base, &checksum, .{});
        self.entries = .{.{ .id = "1.20.1", .kind = "release", .url = "https://piston-meta.mojang.com/v1/packages/fixture/1.20.1.json", .time = "", .release_time = "", .sha1 = checksum, .compliance_level = null }};
        return loader.prepareVanilla(a, io, .{
            .target = vanillaRunTarget(root),
            .vanilla = .{ .version_id = "1.20.1", .manifest = .{ .latest = .{ .release = "1.20.1", .snapshot = "1.20.1" }, .versions = &self.entries } },
            .fetcher = .{ .context = self, .fetch = VanillaRunFixture.fetch },
        });
    }
    fn fetch(raw: ?*anyopaque, a: A, _: std.Io, request: loader.Request) ![]u8 {
        const self: *VanillaRunFixture = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        try std.testing.expectEqualStrings("1.20.1", request.id);
        try std.testing.expect(request.sha1 != null);
        return a.dupe(u8, prepared_run_base);
    }
};
// Both the metadata owner and executor must reject before artifact IO.
fn expectVanillaBindingError(expected: anyerror, a: A, io: std.Io, service: *dl.Service, config: Config, prepared: *const loader.PreparedVanilla, target: loader.VanillaTarget) !void {
    var bound_target = target;
    bound_target.environment = config.environment;
    try std.testing.expectError(expected, prepared.validateBinding(a, io, bound_target));
    try std.testing.expectError(expected, runVanillaPrepared(a, io, service, config, prepared, target));
}

test "vanilla prepared executor binds sealed target and real environment without metadata refetch" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const minecraft = try std.fs.path.join(a, &.{ root, ".minecraft" });
    defer a.free(minecraft);
    var fixture: VanillaRunFixture = .{};
    var prepared = try fixture.prepare(a, io, root);
    defer prepared.deinit();
    const target = vanillaRunTarget(root);
    const config = preparedRunConfig(minecraft);
    var service: dl.Service = undefined;
    // The private stage name is intentionally distinct from Final Vanilla.
    try std.testing.expectError(error.MissingAssetIndex, runVanillaPrepared(a, io, &service, config, &prepared, target));
    var wrong = target;
    wrong.generation = 0;
    try expectVanillaBindingError(error.PreparedMetadataGenerationMismatch, a, io, &service, config, &prepared, wrong);
    wrong = target;
    wrong.generation = 8;
    try expectVanillaBindingError(error.PreparedMetadataGenerationMismatch, a, io, &service, config, &prepared, wrong);
    wrong = target;
    wrong.instance_id = "different-instance";
    try expectVanillaBindingError(error.PreparedMetadataMismatch, a, io, &service, config, &prepared, wrong);
    wrong = target;
    wrong.instance_name = "different-final-name";
    try expectVanillaBindingError(error.PreparedMetadataMismatch, a, io, &service, config, &prepared, wrong);
    var wrong_config = config;
    wrong_config.version_id = "1.20.2";
    try std.testing.expectError(error.PreparedMetadataMismatch, runVanillaPrepared(a, io, &service, wrong_config, &prepared, target));
    wrong = target;
    wrong.version_id = "1.20.2";
    try expectVanillaBindingError(error.PreparedMetadataMismatch, a, io, &service, wrong_config, &prepared, wrong);
    wrong_config = config;
    wrong_config.root = root;
    try std.testing.expectError(error.PreparedMetadataMismatch, runVanillaPrepared(a, io, &service, wrong_config, &prepared, target));
    wrong = target;
    wrong.root = "different-vanilla-root";
    try std.testing.expectError(error.PreparedMetadataMismatch, runVanillaPrepared(a, io, &service, config, &prepared, wrong));
    wrong_config = config;
    wrong_config.environment.arch = "aarch64";
    try expectVanillaBindingError(error.PreparedMetadataMismatch, a, io, &service, wrong_config, &prepared, target);
    wrong_config = config;
    wrong_config.environment.os_version = "changed-os";
    try expectVanillaBindingError(error.PreparedMetadataMismatch, a, io, &service, wrong_config, &prepared, target);
    wrong_config = config;
    wrong_config.environment.features = &.{.{ .name = "demo", .enabled = true }};
    try expectVanillaBindingError(error.PreparedMetadataMismatch, a, io, &service, wrong_config, &prepared, target);
    var cancel = std.atomic.Value(bool).init(true);
    wrong_config = config;
    wrong_config.cancel = &cancel;
    try std.testing.expectError(error.Canceled, runVanillaPrepared(a, io, &service, wrong_config, &prepared, target));
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    const stage_descriptor = try std.fs.path.join(a, &.{ minecraft, "versions", "private-stage", "private-stage.json" });
    defer a.free(stage_descriptor);
    try std.testing.expectError(error.FileNotFound, fs.read(a, io, stage_descriptor, 1024, null));
}

test "vanilla prepared executor rejects sealed base mutation and retains independently owned sources" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const minecraft = try std.fs.path.join(a, &.{ root, ".minecraft" });
    defer a.free(minecraft);
    var fixture: VanillaRunFixture = .{};
    var prepared = try fixture.prepare(a, io, root);
    defer prepared.deinit();
    const target = vanillaRunTarget(root);
    const config = preparedRunConfig(minecraft);
    var service: dl.Service = undefined;
    const original_class = prepared.base.value.main_class;
    prepared.base.value.main_class = "changed.Main";
    try expectVanillaBindingError(error.PreparedMetadataChanged, a, io, &service, config, &prepared, target);
    prepared.base.value.main_class = original_class;
    for (0..2) |_| try std.testing.expectError(error.MissingAssetIndex, runVanillaPrepared(a, io, &service, config, &prepared, target));
    try prepared.validateBinding(a, io, target);
    try std.testing.expectEqual(@as(u64, 17), prepared.runtime_major);
    try std.testing.expectEqualStrings("vanilla.Main", prepared.base.value.main_class.?);
    try std.testing.expectEqualStrings(prepared_run_base, prepared.sources[0].bytes);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "vanilla prepared replay and consuming executor release owners on every allocation failure" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const minecraft = try std.fs.path.join(a, &.{ root, ".minecraft" });
    defer a.free(minecraft);
    var fixture: VanillaRunFixture = .{};
    var prepared = try fixture.prepare(a, io, root);
    defer prepared.deinit();
    const target = vanillaRunTarget(root);
    try @import("test_allocations").checkAllAllocationFailures(a, vanillaRunAllocationFailure, .{ preparedRunConfig(minecraft), &prepared, target });
    try prepared.validateBinding(a, io, target);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "installer namespace blocker rejects artifacts-only runs before any IO" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const token = try namespace.acquire(io);
    defer token.release();
    var service: dl.Service = undefined;
    const config: Config = .{ .target = .{ .directory_name = "Pack", .name = "Pack" }, .version_id = "1.20.1", .root = root, .publish_metadata = false, .environment = .{ .os_name = "linux", .arch = "x86_64" } };
    try std.testing.expectError(error.InstanceNamespaceBusy, run(std.testing.allocator, io, &service, config));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "versions", .{ .follow_symlinks = false }));
    try token.recheck();
}

test "installer prepared entry validates namespace stamps and never releases a borrower" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var service: dl.Service = undefined;
    var prepared: loader.PreparedVanilla = undefined;
    var config: Config = .{ .target = .{ .directory_name = "Pack", .name = "Pack" }, .version_id = "1.20.1", .publish_metadata = false, .environment = .{ .os_name = "linux", .arch = "x86_64" } };
    const target: loader.VanillaTarget = .{ .root = ".", .instance_id = "fixture", .instance_name = "Pack", .version_id = "other", .generation = 1, .environment = config.environment };
    try std.testing.expectError(error.PreparedMetadataMismatch, runVanillaPrepared(a, io, &service, config, &prepared, target));
    const token = try namespace.acquire(io);
    defer token.release();
    config.namespace_token = token;
    try std.testing.expectError(error.PreparedMetadataMismatch, runVanillaPrepared(a, io, &service, config, &prepared, target));
    try token.recheck();
    try std.testing.expectError(error.InstanceNamespaceBusy, namespace.acquire(io));
    token.release();
    const current = try namespace.acquire(io);
    defer current.release();
    try std.testing.expectError(error.InstanceNamespaceLeaseLost, runVanillaPrepared(a, io, &service, config, &prepared, target));
    try current.recheck();
}

test "worker installer admission preserves active namespace busy and stale borrowed stamp errors before IO" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var service: dl.Service = undefined;
    var config: Config = .{ .target = .{ .directory_name = "Pack", .name = "Pack" }, .version_id = "1.20.1", .root = root, .publish_metadata = false, .worker_checks = true, .environment = .{ .os_name = "linux", .arch = "x86_64" } };
    const old = try namespace.acquire(io);
    defer old.release();
    try std.testing.expectError(error.InstanceNamespaceBusy, run(a, io, &service, config));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "versions", .{ .follow_symlinks = false }));
    old.release();
    const current = try namespace.acquire(io);
    defer current.release();
    config.namespace_token = old;
    try std.testing.expectError(error.InstanceNamespaceLeaseLost, run(a, io, &service, config));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "versions", .{ .follow_symlinks = false }));
    try current.recheck();
}

test "loaded executor consumes independent owners when validation or namespace admission fails" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const minecraft = try std.fs.path.join(a, &.{ root, ".minecraft" });
    defer a.free(minecraft);
    var fixture: VanillaRunFixture = .{};
    var prepared = try fixture.prepare(a, io, root);
    defer prepared.deinit();
    const target = vanillaRunTarget(root);
    var service: dl.Service = undefined; // All cases must fail before artifact service IO.
    var flag: std.atomic.Value(bool) = .init(false);
    const failures = [_]anyerror{ error.InvalidWindow, error.Canceled, error.InstanceNamespaceBusy };
    for (failures, 0..) |expected, index| {
        const loaded = try prepared.replayBase(a, io, target, null);
        var config = preparedRunConfig(minecraft);
        config.window = if (index == 0) 0 else 16;
        config.cancel = &flag;
        flag.store(index == 1, .release);
        const token: ?namespace.Token = if (index == 2) try namespace.acquire(io) else null;
        defer if (token) |held| held.release();
        try std.testing.expectError(expected, runLoaded(a, io, &service, config, loaded, null));
        if (token) |held| try held.recheck();
        flag.store(false, .release);
    }
    try prepared.validateBinding(a, io, target);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "live downloader snapshots aggregate omitted transfers before a file completes" {
    // Only Task.snapshot's coherent mutex/Io path is exercised. No service workers,
    // curl handles, submissions, filesystem artifacts or network exist in this fixture.
    var budget = try dl.Budget.init(std.testing.io, 1);
    defer budget.deinit();
    var service: dl.Service = .{ .allocator = std.testing.allocator, .io = std.testing.io, .multi = undefined, .max_active = 1, .budget = &budget };
    var url = "https://example.invalid/fixture.jar".*;
    var downloads: [12]dl.Task = undefined;
    var pending: [12]PendingDownload = undefined;
    for (&downloads, &pending) |*download, *item| {
        download.* = .{ .service = &service, .request = .{ .url = &url }, .url = &url, .temp = &.{}, .progress = .{ .phase = .downloading, .received = 10, .total = 100, .bytes_per_second = 5 } };
        item.* = .{ .task = download, .path = "/assets/object" };
    }
    var registry = task_registry.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const target = try registry.create(.game_install, "Batch");
    reportDownloads(target, &pending, 0, 12, 8, 10, null, null);
    const live = target.details();
    try std.testing.expectEqual(@as(u64, 0), live.completed);
    try std.testing.expectEqual(@as(u64, 128), live.received);
    try std.testing.expectEqual(@as(?u64, 1210), live.total_bytes);
    try std.testing.expectEqual(@as(f64, 60), live.bytes_per_second);
    try std.testing.expectEqual(@as(usize, 8), live.file_count);
    try std.testing.expectEqual(@as(usize, 4), live.omitted_files);
    downloads[11].progress.total = null;
    downloads[11].progress.phase = .failed;
    downloads[11].failure = error.ChecksumMismatch;
    pending[11].path = "/libraries/bad.jar";
    reportDownloads(target, &pending, 0, 12, 8, 10, null, null);
    const failed = target.details();
    try std.testing.expectEqual(@as(?u64, null), failed.total_bytes);
    try std.testing.expectEqual(@as(f64, 55), failed.bytes_per_second);
    try std.testing.expectEqualStrings("bad.jar", failed.files[7].name());
    try std.testing.expectEqual(@as(?anyerror, error.ChecksumMismatch), failed.files[7].failure);
    try std.testing.expectEqual(@as(f64, 0), failed.files[7].bytes_per_second);
}

test "batch download rate survives short file replacement and stops when idle" {
    var rate: DownloadRate = .{ .io = std.testing.io, .last_time = 0 };
    try std.testing.expectEqual(@as(f64, 0), rate.update(0, 0));
    const measured = rate.update(10 * std.time.ns_per_ms, 1024);
    try std.testing.expectEqual(@as(f64, 102400), measured);
    // The completed file is removed: the same bytes remain in received_done.
    try std.testing.expectEqual(measured, rate.update(20 * std.time.ns_per_ms, 1024));
    // A second small file finishes before the next regular sampling interval.
    try std.testing.expectEqual(measured, rate.update(30 * std.time.ns_per_ms, 2048));
    try std.testing.expect(rate.update(110 * std.time.ns_per_ms, 2048) > 0);
    try std.testing.expectEqual(@as(f64, 0), rate.update(2 * std.time.ns_per_s, 2048));
    try std.testing.expect(rate.update(2 * std.time.ns_per_s + std.time.ns_per_ms, 3072) > 0);
}

test "cached artifact checks replace stale metadata and retain bounded owned recent filenames" {
    var registry = task_registry.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const target = try registry.create(.game_install, "Cached install");
    var stale: task_registry.Details = .{ .stage = .metadata, .received = 596992, .total_bytes = 596992 };
    stale.addFile(task_registry.File.init("assets/34.json", 596992, 596992, 0, .complete, null));
    target.reportDetails(stale);
    var recent: task_registry.Details = .{};
    var rate: DownloadRate = .{ .io = std.testing.io, .last_time = 0, .speed = 1024 };
    const file: planner.File = .{ .kind = .asset, .path = "assets/objects/current-object", .url = "unused", .sha1 = null, .size = 100 };
    reportChecking(target, &.{}, &recent, file, 5002, 5216, 0, 0, &rate);
    const checking = target.details();
    try std.testing.expectEqual(task_registry.Stage.verifying, checking.stage);
    try std.testing.expectEqual(@as(u64, 5002), checking.completed);
    try std.testing.expectEqual(@as(?u64, 5216), checking.total);
    try std.testing.expectEqual(@as(u64, 0), checking.received);
    try std.testing.expectEqual(@as(?u64, 0), checking.total_bytes);
    try std.testing.expectEqual(@as(f64, 0), checking.bytes_per_second);
    try std.testing.expectEqualStrings("current-object", checking.files[0].name());
    try std.testing.expectEqual(task_registry.FileState.verifying, checking.files[0].state);
    var path_buffer: [96]u8 = undefined;
    for (0..1000) |index| {
        const path = try std.fmt.bufPrint(&path_buffer, "assets/objects/object-{d}", .{index});
        rememberFile(&recent, task_registry.File.init(path, 100, 100, 0, .complete, null));
    }
    @memset(&path_buffer, 0);
    reportDownloads(target, &.{}, 1000, 1000, 0, 0, &rate, &recent);
    const reused = target.details();
    try std.testing.expectEqual(task_registry.Stage.verifying, reused.stage);
    try std.testing.expectEqual(@as(u64, 1000), reused.completed);
    try std.testing.expectEqual(@as(usize, 8), reused.file_count);
    try std.testing.expectEqualStrings("object-999", reused.files[0].name());
    try std.testing.expectEqualStrings("object-992", reused.files[7].name());
    try std.testing.expectEqual(@as(u64, 0), reused.received);
    try std.testing.expectEqual(@as(f64, 0), reused.bytes_per_second);
}

test "active artifact transfers precede recent checks without double-counting files or bytes" {
    var registry = task_registry.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const target = try registry.create(.game_install, "Mixed install");
    var budget = try dl.Budget.init(std.testing.io, 1);
    defer budget.deinit();
    var service: dl.Service = .{ .allocator = std.testing.allocator, .io = std.testing.io, .multi = undefined, .max_active = 1, .budget = &budget };
    var url = "https://example.invalid/fixture.jar".*;
    var first: dl.Task = .{ .service = &service, .request = .{ .url = &url }, .url = &url, .temp = &.{}, .progress = .{ .phase = .downloading, .received = 20, .total = 100, .bytes_per_second = 5 } };
    var second: dl.Task = .{ .service = &service, .request = .{ .url = &url }, .url = &url, .temp = &.{}, .progress = .{ .phase = .downloading, .received = 30, .total = 100, .bytes_per_second = 7 } };
    const pending = [_]PendingDownload{ .{ .task = &first, .path = "libraries/first.jar" }, .{ .task = &second, .path = "libraries/second.jar" } };
    var recent: task_registry.Details = .{};
    var path_buffer: [96]u8 = undefined;
    for (0..6) |index| {
        const path = try std.fmt.bufPrint(&path_buffer, "assets/objects/cached-{d}", .{index});
        rememberFile(&recent, task_registry.File.init(path, 1000, 1000, 0, .complete, null));
    }
    rememberFile(&recent, task_registry.File.init(pending[0].path, 0, 100, 0, .verifying, null));
    rememberFile(&recent, task_registry.File.init("assets/objects/checking-now", 0, 1000, 0, .verifying, null));
    reportDownloads(target, &pending, 10, 20, 50, 50, null, &recent);
    const mixed = target.details();
    try std.testing.expectEqual(task_registry.Stage.downloading, mixed.stage);
    try std.testing.expectEqual(@as(u64, 100), mixed.received);
    try std.testing.expectEqual(@as(?u64, 250), mixed.total_bytes);
    try std.testing.expectEqual(@as(f64, 12), mixed.bytes_per_second);
    try std.testing.expectEqualStrings("first.jar", mixed.files[0].name());
    try std.testing.expectEqualStrings("second.jar", mixed.files[1].name());
    try std.testing.expectEqualStrings("checking-now", mixed.files[2].name());
    try std.testing.expectEqual(@as(usize, 8), mixed.file_count);
    try std.testing.expectEqual(@as(usize, 1), mixed.omitted_files);
    // Once the first handle is released, its owned final name remains visible.
    first.progress.phase = .complete;
    first.progress.received = 100;
    rememberFile(&recent, telemetry.file(pending[0].path, first.snapshot()));
    reportDownloads(target, pending[1..], 11, 20, 150, 150, null, &recent);
    const next = target.details();
    try std.testing.expectEqual(@as(u64, 180), next.received);
    try std.testing.expectEqual(@as(f64, 7), next.bytes_per_second);
    try std.testing.expectEqualStrings("second.jar", next.files[0].name());
    try std.testing.expectEqualStrings("first.jar", next.files[1].name());
    try std.testing.expectEqual(task_registry.FileState.complete, next.files[1].state);
    try std.testing.expectEqual(@as(f64, 0), next.files[1].bytes_per_second);
}

//! Narrow pack prerequisite coordinator. App must suppress manual Java dispatch
//! and generic instance publication while the corresponding ownership flag is set.
//! Services, Runner contexts and rule matcher context must outlive cancel + JOIN.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../core/config.zig");
const paths_mod = @import("../core/instances.zig");
const packs = @import("../core/pack_import.zig");
const providers = @import("../core/content_providers.zig");
const manifest = @import("../core/content_manifest.zig");
const metadata = @import("../core/minecraft/metadata/root.zig");
const vanilla = @import("../core/minecraft/metadata_loader.zig");
const loader = @import("../core/minecraft/loader_install.zig");
const loaders = @import("../core/minecraft/loaders.zig");
const http = @import("../core/http_transport.zig");
const tasks = @import("../core/tasks.zig");
const java_manager = @import("java_manager.zig");
const downloads = @import("java_download_controller.zig");
const java_backend = @import("../core/java_download.zig");
const instances_manager = @import("instances_manager.zig");
const content_manager = @import("content_manager.zig");
const A = std.mem.Allocator;
const Io = std.Io;

pub const Target = union(enum) { new_instance: config.Instance, existing_instance: config.Instance };
pub const Request = struct {
    archive_absolute_path: []const u8,
    identity: manifest.PackIdentity,
    preparation_generation: u64,
    provider_policy_generation: u64,
    target: Target,
    environment: metadata.rules.Environment,
};
pub const Services = struct {
    store: *config.Store,
    java: *java_manager.Manager,
    java_download: *downloads.Controller,
    instances: *instances_manager.Manager,
    content: *content_manager.Manager,
};
pub const JavaRole = enum { runtime, installer };
pub const Phase = enum {
    idle,
    awaiting_provider,
    preparing,
    discovering_java,
    probing_java,
    downloading_java,
    creating,
    awaiting_publication,
    awaiting_reconciliation,
    selecting_content,
    awaiting_adoption,
    reviewing_content,
    review_required,
    cleaning,
    failed,
    canceled,
};
pub const Snapshot = struct {
    phase: Phase,
    failure: ?anyerror,
    cleanup_failure: ?anyerror,
    preparation_generation: u64,
    serial: u64,
    role: ?JavaRole,
    runtime_major: ?u32,
    installer_major: ?u32,
    instance: ?config.Instance,
    archive_sha256: ?[64]u8,
    content_ready: bool,
};
pub const Runner = struct {
    context: ?*anyopaque = null,
    inspect: *const fn (?*anyopaque, A, Io, *const paths_mod.Paths, []const u8, ?*const packs.CancelToken) anyerror!packs.Inspection = inspectArchive,
    // A fixture may return approved catalogue metadata without native HTTP.
    manifest: ?*const fn (?*anyopaque, A, Io, ?*const packs.CancelToken) anyerror!metadata.Owned(metadata.manifest.Manifest) = null,
    fetcher: vanilla.Fetcher = .{},
    transport: ?loaders.Transport = null,
    probe: *const fn (?*anyopaque, A, Io, []const u8, ?*const packs.CancelToken) anyerror!java_manager.Runtime = probeJava,
    cleanup: *const fn (?*anyopaque, Io, *const packs.Inspection) anyerror!void = cleanInspection,
};
pub const Options = struct {
    task_registry: ?*tasks.Registry = null,
    runner: Runner = .{},
    http_options: http.Options = .{},
    java_vendor: java_backend.Vendor = .azul,
    fixture_spawn_failure: ?anyerror = null,
};

fn inspectArchive(_: ?*anyopaque, a: A, io: Io, paths: *const paths_mod.Paths, path: []const u8, cancel: ?*const packs.CancelToken) !packs.Inspection {
    return packs.inspect(a, io, paths, path, cancel);
}
fn probeJava(_: ?*anyopaque, a: A, io: Io, path: []const u8, cancel: ?*const packs.CancelToken) !java_manager.Runtime {
    return java_manager.probe(a, io, path, cancel);
}
fn cleanInspection(_: ?*anyopaque, io: Io, inspection: *const packs.Inspection) !void {
    try inspection.cleanup(io);
}
fn copiedErrorValue(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .error_set => true,
        .optional => |info| copiedErrorValue(info.child),
        else => false,
    };
}
fn clone(comptime T: type, a: A, value: T) anyerror!T {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var result: T = undefined;
            inline for (info.fields) |field| {
                @field(result, field.name) = if (comptime copiedErrorValue(field.type)) @field(value, field.name) else try clone(field.type, a, @field(value, field.name));
            }
            return result;
        },
        .@"union" => |info| {
            const tag = std.meta.activeTag(value);
            inline for (info.fields) |field| if (std.mem.eql(u8, field.name, @tagName(tag))) {
                return @unionInit(T, field.name, if (comptime copiedErrorValue(field.type)) @field(value, field.name) else try clone(field.type, a, @field(value, field.name)));
            };
            unreachable;
        },
        .optional => |info| {
            if (comptime copiedErrorValue(info.child)) return value;
            return if (value) |v| try clone(info.child, a, v) else null;
        },
        .pointer => |info| {
            if (info.size != .slice) return value;
            const out = try a.alloc(info.child, value.len);
            for (value, out) |v, *dest| {
                dest.* = if (comptime copiedErrorValue(info.child)) v else try clone(info.child, a, v);
            }
            return out;
        },
        else => return value,
    }
}
fn textEqual(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn optionalEqual(a: ?[]const u8, b: ?[]const u8) bool {
    return if (a) |v| if (b) |w| textEqual(v, w) else false else b == null;
}
fn sameRow(a: config.Instance, b: config.Instance) bool {
    return textEqual(a.id, b.id) and textEqual(a.name, b.name) and textEqual(a.minecraft_version, b.minecraft_version) and
        a.loader == b.loader and optionalEqual(a.loader_version, b.loader_version) and optionalEqual(a.java_path, b.java_path) and
        a.max_memory_mb == b.max_memory_mb and a.debug_launch == b.debug_launch and
        (if (a.origin) |v| if (b.origin) |w| v.kind == w.kind and textEqual(v.project_id, w.project_id) and textEqual(v.version_id, w.version_id) else false else b.origin == null);
}
fn rowOf(target: Target) config.Instance {
    return switch (target) {
        inline else => |row| row,
    };
}
fn hostEnvironment() !metadata.rules.Environment {
    return .{ .os_name = switch (builtin.os.tag) {
        .linux => "linux",
        .windows => "windows",
        .macos => "osx",
        else => return error.UnsupportedPlatform,
    }, .arch = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .x86 => "x86",
        else => return error.UnsupportedArchitecture,
    } };
}
fn checkEnvironment(env: metadata.rules.Environment) !void {
    const actual = try hostEnvironment();
    if (!textEqual(env.os_name, actual.os_name) or !textEqual(env.arch, actual.arch) or env.os_version.len != 0 or env.features.len != 0 or env.version_matcher != null) return error.PreparedMetadataMismatch;
}
fn matchingRow(store: *const config.Store, expected: config.Instance) !config.Instance {
    if (store.publicationUncertain()) return error.ConfigPublicationUncertain;
    var found: ?config.Instance = null;
    for (store.snapshot().instances) |row| if (textEqual(row.id, expected.id)) {
        if (found != null or !sameRow(row, expected)) return error.InstanceConfigurationChanged;
        found = row;
    };
    return found orelse error.InstanceConfigurationChanged;
}
fn checkNew(store: *const config.Store, row: config.Instance) !void {
    for (store.snapshot().instances) |existing| {
        if (std.ascii.eqlIgnoreCase(existing.id, row.id)) return error.DuplicateId;
        if (std.ascii.eqlIgnoreCase(existing.name, row.name)) return error.DuplicateName;
    }
}
fn checkTarget(store: *const config.Store, target: Target) !void {
    switch (target) {
        .new_instance => |row| try checkNew(store, row),
        .existing_instance => |row| _ = try matchingRow(store, row),
    }
}
fn checkPack(row: config.Instance, pack: manifest.PackPlan) !void {
    if (!textEqual(row.minecraft_version, pack.minecraft_version) or row.loader != pack.loader or !optionalEqual(row.loader_version, pack.loader_version)) return error.PackPrerequisitesMismatch;
}
fn major(value: u64) !u32 {
    if (value == 0 or value > std.math.maxInt(u8)) return error.UnsupportedJavaMajor;
    return @intCast(value);
}
const Proof = union(enum) {
    vanilla: vanilla.PreparedVanilla,
    loader: loader.PreparedMetadata,
    fn deinit(self: *Proof) void {
        switch (self.*) {
            inline else => |*owner| owner.deinit(),
        }
    }
};
const Action = enum { prepare, probe_runtime, probe_installer };
const Job = struct {
    a: A,
    io: Io,
    arena: std.heap.ArenaAllocator,
    paths: paths_mod.Paths,
    request: Request,
    options: Options,
    task: ?*tasks.Task = null,
    cancellation: packs.CancelToken = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    action: Action = .prepare,
    failure: ?anyerror = null,
    inspection: ?packs.Inspection = null,
    archive_binding: ?[]const u8 = null,
    archive_sha256: ?[64]u8 = null,
    proof: ?Proof = null,
    runtime_major: ?u32 = null,
    installer_major: ?u32 = null,
    probe_path: []const u8 = "",
    probe_major: u32 = 0,
    runtime_path: ?[]const u8 = null,
    installer_path: ?[]const u8 = null,
    installer_key: []const u8,
    actual_row: ?config.Instance = null,
    cleanup_thread: ?std.Thread = null,
    cleanup_mutex: Io.Mutex = .init,
    cleanup_condition: Io.Condition = .init,
    cleanup_requested: bool = false,
    cleanup_done: std.atomic.Value(bool) = .init(false),
    cleanup_failure: ?anyerror = null,

    fn create(a: A, io: Io, root: []const u8, request: Request, options: Options) !*Job {
        const self = try a.create(Job);
        errdefer a.destroy(self);
        var arena: std.heap.ArenaAllocator = .init(a);
        errdefer arena.deinit();
        var paths = try paths_mod.Paths.init(a, io, root);
        errdefer paths.deinit();
        const aa = arena.allocator();
        const owned = try clone(Request, aa, request);
        const key = try std.fmt.allocPrint(aa, "{s}:installer", .{rowOf(owned.target).id});
        self.* = .{ .a = a, .io = io, .arena = arena, .paths = paths, .request = owned, .options = try clone(Options, aa, options), .installer_key = key };
        return self;
    }
    fn destroy(self: *Job) void {
        std.debug.assert(self.thread == null and self.cleanup_thread == null and self.inspection == null and self.task == null);
        if (self.proof) |*proof| proof.deinit();
        self.paths.deinit();
        self.arena.deinit();
        self.a.destroy(self);
    }
    fn spawn(self: *Job, action: Action) !void {
        std.debug.assert(self.thread == null);
        if (self.options.fixture_spawn_failure) |err| return err;
        self.action = action;
        self.failure = null;
        self.done.store(false, .release);
        const thread = try std.Thread.spawn(.{}, work, .{self});
        self.thread = thread;
    }
    fn joinReady(self: *Job) bool {
        if (self.thread == null) return true;
        if (!self.done.load(.acquire)) return false;
        self.thread.?.join();
        self.thread = null;
        return true;
    }
    fn work(self: *Job) void {
        self.perform() catch |err| {
            self.failure = err;
        };
        self.done.store(true, .release);
    }
    fn perform(self: *Job) !void {
        try self.checkCanceled();
        const aa = self.arena.allocator();
        switch (self.action) {
            .prepare => {
                self.task.?.report(.extracting, 0, null);
                const inspected = try self.options.runner.inspect(self.options.runner.context, self.a, self.io, &self.paths, self.request.archive_absolute_path, &self.cancellation);
                self.inspection = inspected;
                const inspection = &self.inspection.?;
                if (inspection.provider != self.request.identity.provider or inspection.pack.identity.provider != inspection.provider) return error.ProviderMismatch;
                for (inspection.source_sha256) |byte| if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.ArchiveIdentityMismatch;
                self.archive_binding = try aa.dupe(u8, inspection.archive_absolute_path);
                self.archive_sha256 = inspection.source_sha256;
                try checkPack(rowOf(self.request.target), inspection.pack);
                try self.checkCanceled();
                if (self.request.target == .existing_instance) return;
                self.task.?.report(.metadata, 0, null);
                var client: ?http.Client = null;
                defer if (client) |*owned| owned.deinit();
                if (self.options.runner.manifest == null or self.options.runner.fetcher.fetch == null) {
                    const created_client = try http.Client.init(self.a, self.io, self.options.http_options);
                    client = created_client;
                }
                var catalog = if (self.options.runner.manifest) |get| try get(self.options.runner.context, self.a, self.io, &self.cancellation) else try fetchManifest(self.a, &client.?, &self.cancellation);
                defer catalog.deinit();
                var fetch_context: FetchContext = .{ .client = if (client) |*owned| owned else null, .cancel = &self.cancellation };
                const fetcher: vanilla.Fetcher = if (self.options.runner.fetcher.fetch != null) self.options.runner.fetcher else .{ .context = &fetch_context, .fetch = fetchVersion };
                const row = rowOf(self.request.target);
                const base: vanilla.Options = .{ .root = self.paths.minecraft, .version_id = row.minecraft_version, .manifest = catalog.value, .cancel = &self.cancellation };
                if (row.loader == .vanilla) {
                    const prepared = try vanilla.prepareVanilla(self.a, self.io, .{ .target = self.vanillaTarget(), .vanilla = base, .fetcher = fetcher });
                    self.proof = .{ .vanilla = prepared };
                    self.runtime_major = try major(self.proof.?.vanilla.runtime_major);
                } else {
                    const prepared = try loader.prepareMetadata(self.a, self.io, .{ .root = self.paths.root, .instance_id = row.id, .instance_name = row.name, .generation = self.request.preparation_generation, .selection = try self.selection(), .environment = self.request.environment, .vanilla = base, .fetcher = fetcher, .http_options = self.options.http_options, .transport = self.options.runner.transport }, self.control());
                    self.proof = .{ .loader = prepared };
                    self.runtime_major = try major(self.proof.?.loader.requirements.runtime_major);
                    if (self.proof.?.loader.requirements.installer_major != 0) self.installer_major = try major(self.proof.?.loader.requirements.installer_major);
                }
                try self.checkCanceled();
            },
            .probe_runtime, .probe_installer => {
                self.task.?.report(.scanning, 0, null);
                const runtime = try self.options.runner.probe(self.options.runner.context, self.a, self.io, self.probe_path, &self.cancellation);
                defer java_manager.freeRuntime(self.a, runtime);
                if (runtime.major != self.probe_major) return error.JavaMajorMismatch;
                if (!textEqual(runtime.path, self.probe_path)) return error.JavaPathChanged;
                try self.checkCanceled();
            },
        }
    }
    fn checkCanceled(self: *const Job) !void {
        if (self.cancellation.load(.acquire) or (if (self.task) |task| task.canceled() else false)) return error.Canceled;
    }
    fn selection(self: *const Job) !loaders.Selection {
        const row = rowOf(self.request.target);
        return .{ .kind = switch (row.loader) {
            .fabric => .fabric,
            .forge => .forge,
            .neoforge => .neoforge,
            .quilt => .quilt,
            .vanilla => return error.InvalidLoader,
        }, .base_id = row.minecraft_version, .loader_id = row.loader_version orelse return error.InvalidLoaderVersion };
    }
    fn vanillaTarget(self: *const Job) vanilla.VanillaTarget {
        const row = rowOf(self.request.target);
        return .{ .root = self.paths.root, .instance_id = row.id, .instance_name = row.name, .version_id = row.minecraft_version, .generation = self.request.preparation_generation, .environment = self.request.environment };
    }
    fn validateProof(self: *const Job) !void {
        switch (self.proof orelse return error.MissingPreparedMetadata) {
            .vanilla => |*proof| try proof.validateBinding(self.a, self.io, self.vanillaTarget()),
            .loader => |*proof| {
                const row = rowOf(self.request.target);
                try proof.validateBinding(self.a, self.io, .{ .root = self.paths.root, .instance_id = row.id, .instance_name = row.name, .generation = self.request.preparation_generation, .selection = try self.selection(), .environment = self.request.environment });
            },
        }
    }
    fn control(self: *Job) loaders.Control {
        return .{ .cancel = &self.cancellation, .context = &self.io, .now_ms = nowMs, .deadline_ms = std.math.maxInt(u64) };
    }
    fn requestCleanup(self: *Job) void {
        std.debug.assert(self.thread == null);
        self.cleanup_mutex.lockUncancelable(self.io);
        defer self.cleanup_mutex.unlock(self.io);
        self.cleanup_requested = true;
        self.cleanup_condition.broadcast(self.io);
    }
    fn cleanupWorker(self: *Job) void {
        self.cleanup_mutex.lockUncancelable(self.io);
        while (!self.cleanup_requested) self.cleanup_condition.waitUncancelable(self.io, &self.cleanup_mutex);
        self.cleanup_mutex.unlock(self.io);
        if (self.inspection) |*inspection| {
            self.options.runner.cleanup(self.options.runner.context, self.io, inspection) catch |err| {
                self.cleanup_failure = err;
            };
            inspection.deinit();
            self.inspection = null;
        }
        self.cleanup_done.store(true, .release);
    }
    fn joinCleanup(self: *Job, wait: bool) bool {
        if (self.cleanup_thread == null) return true;
        if (!wait and !self.cleanup_done.load(.acquire)) return false;
        self.cleanup_thread.?.join();
        self.cleanup_thread = null;
        return true;
    }
};
fn nowMs(raw: ?*anyopaque) u64 {
    const io: *const Io = @ptrCast(@alignCast(raw.?));
    return @intCast(@max(0, @divFloor(Io.Clock.awake.now(io.*).nanoseconds, std.time.ns_per_ms)));
}
const FetchContext = struct { client: ?*http.Client, cancel: ?*const packs.CancelToken };
fn fetchManifest(a: A, client: *http.Client, cancel: ?*const packs.CancelToken) !metadata.Owned(metadata.manifest.Manifest) {
    var response = try client.execute(.{ .url = metadata.version_manifest_url, .cancel = cancel, .max_response_bytes = 16 * 1024 * 1024, .require_public_address = true });
    defer response.deinit();
    if (response.status != 200) return error.MetadataHttpFailure;
    return metadata.manifest.parseSlice(a, response.body);
}
fn fetchVersion(raw: ?*anyopaque, a: A, _: Io, request: vanilla.Request) ![]u8 {
    const self: *FetchContext = @ptrCast(@alignCast(raw.?));
    var response = try self.client.?.execute(.{ .url = request.url, .cancel = self.cancel, .max_response_bytes = request.max_bytes, .require_public_address = true });
    defer response.deinit();
    if (response.status != 200) return error.MetadataHttpFailure;
    return a.dupe(u8, response.body);
}
const DownloadToken = struct { generation: u64, serial: u64, role: JavaRole, request: downloads.Request };
const Core = struct {
    a: A,
    io: Io,
    paths: paths_mod.Paths,
    java_file: []const u8,
    options_arena: std.heap.ArenaAllocator,
    options: Options,
    private_registry: tasks.Registry,
    job: ?*Job = null,
    services: ?Services = null,
    phase: Phase = .idle,
    failure: ?anyerror = null,
    publication_failure: bool = false,
    serial: u64 = 0,
    last_generation: u64 = 0,
    policy_generation: u64 = 0,
    role: ?JavaRole = null,
    discovery_owned: bool = false,
    discovered: bool = false,
    download_token: ?DownloadToken = null,
    instance_owned: bool = false,
    content_owned: bool = false,
    cancel_requested: bool = false,
    stopping: bool = false,
    content_ready: bool = false,

    fn registry(self: *Core) *tasks.Registry {
        return self.options.task_registry orelse &self.private_registry;
    }
    fn finish(self: *Core, outcome: tasks.Outcome) void {
        if (self.job) |job| if (job.task) |task| {
            self.registry().finish(task, outcome);
            job.task = null;
        };
    }
    fn checkServices(self: *const Core, services: Services) !void {
        if (self.services) |bound| if (!std.meta.eql(bound, services)) return error.PrerequisiteServicesChanged;
        if (!textEqual(self.paths.root, services.store.root) or !textEqual(self.paths.root, services.instances.root) or
            !textEqual(self.paths.root, services.content.paths.root) or !textEqual(self.paths.jdks, services.java_download.root) or
            !textEqual(self.java_file, services.java.file)) return error.ConfigurationStoreChanged;
    }
    fn checkBinding(self: *const Core, services: Services, require_row: bool) !void {
        try self.checkServices(services);
        const job = self.job orelse return error.NoPackImport;
        try checkEnvironment(job.request.environment);
        const content = services.content.snapshot();
        if (content.provider != job.request.identity.provider or content.policy_generation != self.policy_generation) return error.ContentPolicyChanged;
        if (!services.content.options.allow_manifest_v2) return error.ManifestV2CapabilityRequired;
        if (require_row) _ = try matchingRow(services.store, job.actual_row orelse rowOf(job.request.target));
    }
    fn cancelOwned(self: *Core) void {
        self.cancel_requested = true;
        if (self.job) |job| job.cancellation.store(true, .release);
        const services = self.services orelse return;
        if (self.discovery_owned) services.java.cancelSearch();
        if (self.download_token != null) services.java_download.cancel();
        if (self.instance_owned) services.instances.cancel();
        if (self.content_owned) services.content.cancel();
    }
    fn fail(self: *Core, err: anyerror) void {
        self.failure = if (err == error.Canceled) null else err;
        self.publication_failure = false;
        self.cancelOwned();
    }
    fn beginCleanup(self: *Core) void {
        const job = self.job orelse return;
        if (job.thread != null or self.discovery_owned or self.download_token != null or self.instance_owned or self.content_owned) return;
        job.requestCleanup();
        self.phase = .cleaning;
    }
    fn selected(self: *const Core, role: JavaRole) !?java_manager.Runtime {
        const services = self.services.?;
        const job = self.job.?;
        const required = if (role == .runtime) job.runtime_major.? else job.installer_major.?;
        const row = rowOf(job.request.target);
        if (role == .runtime) if (row.java_path) |path| {
            for (services.java.entries()) |runtime| if (textEqual(runtime.path, path)) {
                if (runtime.major != required) return error.IncompatibleJava;
                return runtime;
            };
            return null;
        };
        const key = if (role == .runtime) row.name else job.installer_key;
        if (services.java.selectedPath(key) != null and services.java.resolve(key, required) == null) return error.IncompatibleJava;
        return services.java.resolve(key, required);
    }
    fn exactSelection(self: *const Core, role: JavaRole, path: []const u8) !void {
        const runtime = (try self.selected(role)) orelse return error.JavaSelectionChanged;
        if (!textEqual(runtime.path, path)) return error.JavaSelectionChanged;
    }
    fn acquireJava(self: *Core, role: JavaRole) !void {
        const job = self.job.?;
        const services = self.services.?;
        try self.checkBinding(services, false);
        try job.validateProof();
        self.role = role;
        if (try self.selected(role)) |runtime| {
            job.probe_path = try job.arena.allocator().dupe(u8, runtime.path);
            job.probe_major = runtime.major;
            try job.spawn(if (role == .runtime) .probe_runtime else .probe_installer);
            self.phase = .probing_java;
            return;
        }
        if (!self.discovered) {
            if (services.java.isSearching()) return error.JavaDiscoveryBusy;
            const explicit_path = if (role == .runtime) rowOf(job.request.target).java_path else null;
            try services.java.search(explicit_path orelse "");
            self.discovery_owned = true;
            self.phase = .discovering_java;
            return;
        }
        if (role == .runtime and rowOf(job.request.target).java_path != null) return error.SelectedJavaUnavailable;
        if (services.java_download.snapshot().phase == .running) return error.JavaDownloadBusy;
        const required = if (role == .runtime) job.runtime_major.? else job.installer_major.?;
        const request: downloads.Request = .{ .vendor = self.options.java_vendor, .major = @intCast(required) };
        try services.java_download.start(request);
        // App exclusivity is required: snapshots alone cannot distinguish identical jobs.
        self.download_token = .{ .generation = job.request.preparation_generation, .serial = self.serial, .role = role, .request = request };
        self.phase = .downloading_java;
    }
    fn startCreate(self: *Core) !void {
        const services = self.services.?;
        const job = self.job.?;
        try self.checkBinding(services, false);
        try checkNew(services.store, rowOf(job.request.target));
        try job.validateProof();
        try self.exactSelection(.runtime, job.runtime_path.?);
        if (job.installer_major != null) try self.exactSelection(.installer, job.installer_path.?);
        var row = rowOf(job.request.target);
        row.java_path = job.runtime_path.?;
        const proof = if (job.proof) |*owned| owned else return error.MissingPreparedMetadata;
        switch (proof.*) {
            .vanilla => |*owner| try services.instances.startCreateVanillaPrepared(row, owner, job.request.preparation_generation),
            .loader => |*owner| try services.instances.startCreatePreparedWithJava(row, owner, job.request.preparation_generation, job.installer_path),
        }
        self.instance_owned = true;
        self.phase = .creating;
    }
    fn captureCreated(self: *Core) !void {
        const job = self.job.?;
        const actual = self.services.?.instances.snapshot().instance orelse return error.MissingCreatedInstance;
        var expected = rowOf(job.request.target);
        expected.java_path = job.runtime_path;
        if (!sameRow(actual, expected)) return error.InstanceConfigurationChanged;
        const owned_row = try clone(config.Instance, job.arena.allocator(), actual);
        job.actual_row = owned_row;
    }
    fn selectContent(self: *Core) !void {
        const services = self.services.?;
        const job = self.job.?;
        if (job.actual_row == null) job.actual_row = rowOf(job.request.target);
        try self.checkBinding(services, true);
        const row = try matchingRow(services.store, job.actual_row.?);
        if (services.content.isBusy()) return error.ContentWorkerBusy;
        const before = services.content.snapshot();
        const unchanged = if (before.instance) |content_row| sameRow(content_row, row) else false;
        try services.content.select(row);
        const after = services.content.snapshot();
        const expected_generation = if (unchanged) self.policy_generation else self.policy_generation +% 1;
        if (after.policy_generation != expected_generation or after.provider != job.request.identity.provider) return error.ContentPolicyChanged;
        self.policy_generation = expected_generation;
        if (unchanged) try services.content.refresh();
        self.content_owned = services.content.isBusy();
        self.phase = .selecting_content;
    }
    fn adopt(self: *Core) !void {
        const services = self.services.?;
        const job = self.job.?;
        try self.checkBinding(services, true);
        const content = services.content.snapshot();
        if (content.busy) return error.ContentWorkerBusy;
        if (content.failure) |err| return err;
        const content_row = content.instance orelse return error.NoSelectedInstance;
        if (!sameRow(content_row, job.actual_row.?)) return error.InstanceConfigurationChanged;
        const inspection = if (job.inspection) |*owned| owned else return error.InspectionAlreadyAdopted;
        if (!std.mem.eql(u8, &inspection.source_sha256, &job.archive_sha256.?) or !textEqual(inspection.archive_absolute_path, job.archive_binding.?)) return error.InspectedArchiveChanged;
        try checkPack(job.actual_row.?, inspection.pack);
        try services.content.importInspectedFor(inspection, job.request.identity);
        job.inspection = null;
        job.requestCleanup();
        self.content_owned = true;
        self.phase = .reviewing_content;
        self.failure = null;
    }
};

pub const Controller = struct {
    core: *Core,
    pub fn init(a: A, io: Io, root: []const u8, options: Options) !Controller {
        const core = try a.create(Core);
        errdefer a.destroy(core);
        var paths = try paths_mod.Paths.init(a, io, root);
        errdefer paths.deinit();
        const java_file = try std.fs.path.join(a, &.{ paths.vela, "java.json" });
        errdefer a.free(java_file);
        var arena: std.heap.ArenaAllocator = .init(a);
        errdefer arena.deinit();
        const owned = try clone(Options, arena.allocator(), options);
        core.* = .{ .a = a, .io = io, .paths = paths, .java_file = java_file, .options_arena = arena, .options = owned, .private_registry = .init(a) };
        return .{ .core = core };
    }
    pub fn start(self: *Controller, request: Request, services: Services) !void {
        const core = self.core;
        if (core.instance_owned or core.discovery_owned or core.download_token != null or core.content_owned) return error.Busy;
        if (core.job) |old| if (old.thread != null or old.cleanup_thread != null or old.inspection != null or old.task != null) return error.Busy;
        if (request.preparation_generation == 0 or request.preparation_generation <= core.last_generation) return error.StalePreparationGeneration;
        if (core.serial == std.math.maxInt(u64)) return error.IdExhausted;
        // No stale borrowed Store strings survive a successful request admission.
        try core.checkServices(services);
        if (services.store.publicationUncertain()) return error.ConfigPublicationUncertain;
        if (services.instances.isBusy()) return error.InstanceWorkerBusy;
        if (services.java.isSearching()) return error.JavaDiscoveryBusy;
        if (services.java_download.snapshot().phase == .running) return error.JavaDownloadBusy;
        const content = services.content.snapshot();
        if (content.busy) return error.ContentWorkerBusy;
        if (content.recovery_required) return error.RecoveryRequired;
        if (!services.content.options.allow_manifest_v2) return error.ManifestV2CapabilityRequired;
        if (content.policy_generation != request.provider_policy_generation) return error.ContentPolicyChanged;
        if (request.identity.provider != .modrinth and request.identity.provider != .curseforge) return error.ProviderDisabled;
        if (!providers.validToken(request.identity.project_id) or !providers.validToken(request.identity.version_id)) return error.InvalidId;
        if (!std.fs.path.isAbsolute(request.archive_absolute_path) or request.archive_absolute_path.len > 4096 or std.mem.indexOfScalar(u8, request.archive_absolute_path, 0) != null) return error.ArchivePathNotAbsolute;
        const row = rowOf(request.target);
        if (!config.validId(row.id) or !config.validId(row.name)) return error.UnsafeInstance;
        if (row.id.len > 502) return error.InvalidInstallerKey;
        try metadata.version.validateId(row.minecraft_version);
        try checkEnvironment(request.environment);
        try checkTarget(services.store, request.target);
        const job = try Job.create(core.a, core.io, core.paths.root, request, core.options);
        errdefer job.destroy();
        const task = try core.registry().create(.modpack_install, "Pack prerequisites");
        job.task = task;
        errdefer {
            core.registry().finish(task, .{ .failed = error.PreparationNotStarted });
            job.task = null;
        }
        try core.registry().start(task);
        const cleanup_thread = try std.Thread.spawn(.{}, Job.cleanupWorker, .{job});
        job.cleanup_thread = cleanup_thread;
        errdefer {
            job.requestCleanup();
            _ = job.joinCleanup(true);
        }
        const provider_changed = content.provider != request.identity.provider;
        if (!provider_changed) try job.spawn(.prepare);
        if (provider_changed) try services.content.selectProvider(request.identity.provider);
        if (core.job) |old| old.destroy();
        core.job = job;
        core.services = services;
        core.serial += 1;
        core.last_generation = request.preparation_generation;
        core.policy_generation = if (provider_changed) content.policy_generation +% 1 else content.policy_generation;
        job.request.provider_policy_generation = core.policy_generation;
        core.phase = if (provider_changed) .awaiting_provider else .preparing;
        core.content_owned = provider_changed and services.content.isBusy();
        core.failure = null;
        core.cancel_requested = false;
        core.stopping = false;
        core.role = null;
        core.discovered = false;
        core.content_ready = false;
        if (provider_changed) {
            const selected_provider = services.content.snapshot();
            if (selected_provider.provider != job.request.identity.provider or selected_provider.policy_generation != core.policy_generation) core.fail(error.ContentPolicyChanged);
        }
    }
    pub fn ownsInstancesPublication(self: *const Controller) bool {
        return self.core.instance_owned;
    }
    pub fn ownsJavaDownload(self: *const Controller) bool {
        return self.core.download_token != null;
    }
    pub fn ownsJavaDiscovery(self: *const Controller) bool {
        return self.core.discovery_owned;
    }
    pub fn cancel(self: *Controller, _: Services) void {
        self.core.cancelOwned();
    }
    pub fn snapshot(self: *const Controller) Snapshot {
        const core = self.core;
        const job = core.job;
        return .{ .phase = core.phase, .failure = core.failure, .cleanup_failure = if (job) |j| if (j.cleanup_thread == null) j.cleanup_failure else null else null, .preparation_generation = if (job) |j| j.request.preparation_generation else 0, .serial = core.serial, .role = core.role, .runtime_major = if (job) |j| if (j.thread == null) j.runtime_major else null else null, .installer_major = if (job) |j| if (j.thread == null) j.installer_major else null else null, .instance = if (job) |j| j.actual_row orelse rowOf(j.request.target) else null, .archive_sha256 = if (job) |j| if (j.thread == null) j.archive_sha256 else null else null, .content_ready = core.content_ready };
    }
    /// Root advances Services.content exactly once after this observation.
    /// Keep external content selection and policy changes gated for every active phase.
    pub fn tick(self: *Controller, services: Services) void {
        const core = self.core;
        const job = core.job orelse return;
        if (core.phase == .failed or core.phase == .canceled or core.phase == .review_required) return;
        core.checkServices(services) catch |err| {
            core.fail(err);
        };
        const bound = core.services.?;
        if (core.phase != .cleaning and !core.cancel_requested) core.checkBinding(bound, !core.instance_owned and (job.request.target == .existing_instance or job.actual_row != null)) catch |err| {
            core.fail(err);
        };
        if (job.task) |task| if (task.canceled()) core.cancelOwned();
        if (!job.joinReady()) return;
        if (core.phase == .cleaning) {
            if (!job.joinCleanup(false)) return;
            core.phase = if (core.failure != null) .failed else .canceled;
            core.finish(if (core.failure) |err| .{ .failed = err } else .canceled);
            return;
        }
        if (core.discovery_owned) {
            bound.java.tick();
            if (bound.java.isSearching()) return;
            core.discovery_owned = false;
            core.discovered = true;
            if (bound.java.searchFailure()) |err| core.fail(err);
            if (!core.cancel_requested) {
                for (bound.java.searchResults()) |runtime| {
                    bound.java.add(&.{runtime.path}) catch |err| {
                        core.fail(err);
                        break;
                    };
                }
                if (!core.cancel_requested) core.acquireJava(core.role.?) catch |err| {
                    core.fail(err);
                };
            }
        } else if (core.download_token) |token| {
            bound.java_download.tick(bound.java);
            const snap = bound.java_download.snapshot();
            if (!downloadMatches(token, job.request.preparation_generation, core.serial, core.role, snap.request)) core.fail(error.JavaDownloadOwnershipLost);
            if (snap.phase == .running) return;
            core.download_token = null;
            if (!core.cancel_requested) {
                validateDownload(snap) catch |err| {
                    core.fail(err);
                };
                if (!core.cancel_requested) core.acquireJava(token.role) catch |err| {
                    core.fail(err);
                };
            }
        } else if (core.instance_owned) {
            bound.instances.tick();
            const snap = bound.instances.snapshot();
            if (snap.phase == .working) return;
            if (snap.operation != .creating) {
                core.fail(error.InstancePublicationOwnershipLost);
                return;
            }
            if (snap.phase == .awaiting_publication or core.phase == .awaiting_reconciliation) {
                if (core.phase == .awaiting_reconciliation) return;
                core.phase = .awaiting_publication;
                core.captureCreated() catch |err| {
                    core.failure = err;
                    return;
                };
                bound.instances.publish(bound.store) catch |err| {
                    core.failure = err;
                    core.publication_failure = true;
                    if (bound.store.publicationUncertain()) core.phase = .awaiting_reconciliation;
                    return;
                };
                core.instance_owned = false;
                if (!core.cancel_requested or core.publication_failure) core.failure = null;
                core.publication_failure = false;
                if (!core.cancel_requested) core.selectContent() catch |err| {
                    core.failure = err;
                    core.phase = .awaiting_adoption;
                };
            } else {
                core.instance_owned = false;
                core.fail(snap.failure orelse error.InstanceCreationFailed);
            }
        } else if (core.content_owned) {
            // Root advances content exactly once, including its Future JOIN.
            const snap = bound.content.snapshot();
            if (snap.busy) return;
            core.content_owned = false;
            if (!core.cancel_requested) {
                core.checkBinding(bound, core.phase != .awaiting_provider or job.request.target == .existing_instance) catch |err| {
                    core.fail(err);
                };
                if (!core.cancel_requested and snap.failure != null) core.fail(snap.failure.?);
                if (!core.cancel_requested and core.phase == .reviewing_content) {
                    if (snap.proposal == null) core.fail(error.MissingContentProposal) else {
                        _ = job.joinCleanup(true);
                        core.content_ready = snap.proposal.?.ready;
                        core.phase = .review_required;
                        core.finish(.succeeded);
                        return;
                    }
                }
            }
        }
        if (job.thread != null) return;
        if (core.cancel_requested) {
            core.beginCleanup();
            return;
        }
        core.checkBinding(bound, job.request.target == .existing_instance or job.actual_row != null) catch |err| {
            core.fail(err);
            core.beginCleanup();
            return;
        };
        if (job.failure) |err| {
            core.fail(err);
            core.beginCleanup();
            return;
        }
        switch (core.phase) {
            .awaiting_provider => {
                if (bound.content.snapshot().recovery_required) {
                    core.fail(error.RecoveryRequired);
                } else {
                    checkTarget(bound.store, job.request.target) catch |err| core.fail(err);
                    if (!core.cancel_requested) {
                        job.spawn(.prepare) catch |err| core.fail(err);
                        if (!core.cancel_requested) core.phase = .preparing;
                    }
                }
            },
            .preparing => {
                if (job.request.target == .existing_instance) core.selectContent() catch |err| {
                    core.failure = err;
                    core.phase = .awaiting_adoption;
                } else core.acquireJava(.runtime) catch |err| {
                    core.fail(err);
                };
            },
            .probing_java => {
                core.exactSelection(core.role.?, job.probe_path) catch |err| {
                    core.fail(err);
                };
                if (!core.cancel_requested) {
                    if (core.role.? == .runtime) {
                        job.runtime_path = job.probe_path;
                        core.discovered = false;
                        if (job.installer_major != null) core.acquireJava(.installer) catch |err| {
                            core.fail(err);
                        } else core.startCreate() catch |err| {
                            core.fail(err);
                        };
                    } else {
                        job.installer_path = job.probe_path;
                        core.startCreate() catch |err| {
                            core.fail(err);
                        };
                    }
                }
            },
            .selecting_content => if (!core.content_owned) {
                core.adopt() catch |err| {
                    core.failure = err;
                    core.phase = .awaiting_adoption;
                };
            },
            else => {},
        }
        if (core.cancel_requested) core.beginCleanup();
    }
    pub fn acknowledgeReconciled(self: *Controller, services: Services) !void {
        const core = self.core;
        if (core.phase != .awaiting_reconciliation or !core.instance_owned) return error.NoOwnedPublicationUncertainty;
        try core.checkServices(services);
        if (services.store.publicationUncertain()) return error.ConfigPublicationUncertain;
        _ = try matchingRow(services.store, core.job.?.actual_row orelse return error.MissingCreatedInstance);
        try services.instances.acknowledgeReconciledCreation(services.store);
        core.instance_owned = false;
        if (!core.cancel_requested or core.publication_failure) core.failure = null;
        core.publication_failure = false;
        if (core.cancel_requested) core.beginCleanup() else core.selectContent() catch |err| {
            core.failure = err;
            core.phase = .awaiting_adoption;
            return err;
        };
    }
    pub fn retryAdoption(self: *Controller, services: Services) !void {
        const core = self.core;
        if (core.phase != .awaiting_adoption or core.cancel_requested or core.job.?.inspection == null) return error.NoRetainedInspection;
        try core.checkBinding(services, true);
        core.failure = null;
        core.selectContent() catch |err| {
            core.failure = err;
            core.phase = .awaiting_adoption;
            return err;
        };
    }
    /// App enters a no-dispatch shutdown boundary before this call. Shared
    /// managers retain committed pending rows/leases; their later deinit owns debt.
    pub fn deinit(self: *Controller, _: Services) void {
        const core = self.core;
        core.cancelOwned();
        if (core.services) |bound| {
            if (core.discovery_owned) bound.java.cancelAndJoin();
            if (core.download_token != null) bound.java_download.cancelAndJoin(bound.java);
            if (core.instance_owned) bound.instances.cancelAndJoin();
            if (core.content_owned) {
                bound.content.cancelAndJoin();
                const drained = bound.content.snapshot();
                std.debug.assert(!drained.busy);
                core.content_owned = false;
            }
            // Content retains adopted inspection and any settled ownership debt.
        }
        if (core.job) |job| {
            if (job.thread) |thread| {
                thread.join();
                job.thread = null;
            }
            job.requestCleanup();
            _ = job.joinCleanup(true);
            core.finish(.canceled);
            job.destroy();
        }
        core.private_registry.deinit();
        core.options_arena.deinit();
        core.paths.deinit();
        core.a.free(core.java_file);
        core.a.destroy(core);
        self.* = undefined;
    }
};
fn downloadMatches(token: DownloadToken, generation: u64, serial: u64, role: ?JavaRole, request: ?downloads.Request) bool {
    return token.generation == generation and token.serial == serial and role == token.role and request != null and std.meta.eql(token.request, request.?);
}
fn validateDownload(snap: downloads.Snapshot) !void {
    if (snap.phase != .complete) return snap.failure orelse error.JavaDownloadFailed;
    if (snap.probe_failure) |err| return err;
    if (snap.registration_failure) |err| return err;
    if (!snap.registered or snap.installed == null) return error.JavaNotRegistered;
}

const Fixture = struct {
    const version_json = "{\"id\":\"base\",\"mainClass\":\"Main\",\"javaVersion\":{\"component\":\"jre-legacy\",\"majorVersion\":17},\"downloads\":{\"client\":{\"url\":\"https://piston-data.mojang.com/v1/objects/a9993e364706816aba3e25717850c26c9cd0d89d/client.jar\",\"sha1\":\"a9993e364706816aba3e25717850c26c9cd0d89d\",\"size\":3}}}";
    metadata_bytes: []const u8 = version_json,
    inspect_error: ?anyerror = null,
    a: A,
    tmp: std.testing.TmpDir,
    root: [:0]const u8,
    paths: paths_mod.Paths,
    registry: tasks.Registry,
    store: config.Store,
    java: java_manager.Manager,
    instances: instances_manager.Manager,
    content: content_manager.Manager,
    download: downloads.Controller,
    row: config.Instance = .{ .id = "game", .name = "Display Name", .minecraft_version = "base", .loader = .vanilla, .max_memory_mb = 2048 },
    leased: bool = false,
    inspect_count: usize = 0,
    metadata_count: usize = 0,
    probe_count: usize = 0,
    create_count: usize = 0,
    cleanup_count: usize = 0,
    probe_major: u32 = 17,
    cleanup_error: ?anyerror = null,

    fn init() !*Fixture {
        const a = std.testing.allocator;
        const io = std.testing.io;
        const self = try a.create(Fixture);
        errdefer a.destroy(self);
        self.* = .{ .a = a, .tmp = std.testing.tmpDir(.{}), .root = undefined, .paths = undefined, .registry = tasks.Registry.init(a), .store = undefined, .java = undefined, .instances = undefined, .content = undefined, .download = undefined };
        errdefer self.tmp.cleanup();
        errdefer self.registry.deinit();
        self.root = try self.tmp.dir.realPathFileAlloc(io, ".", a);
        errdefer a.free(self.root);
        self.paths = try paths_mod.Paths.init(a, io, self.root);
        errdefer self.paths.deinit();
        self.store = try config.Store.init(a, io, self.root);
        errdefer self.store.deinit();
        self.java = try java_manager.Manager.init(a, io, self.root);
        errdefer self.java.deinit();
        self.instances = try instances_manager.Manager.init(a, io, &self.paths, &self.registry, .{}, self.lease());
        errdefer self.instances.deinit();
        self.instances.installer = .{ .context = self, .run = install };
        self.content = try content_manager.Manager.initOptions(a, io, &self.paths, &self.registry, .{ .lease = self.lease(), .allow_manifest_v2 = true });
        // These composed fixtures never dispatch a Java download.
        self.download = .{ .allocator = a, .io = io, .root = self.paths.jdks, .service = undefined, .download_connections = 8, .registry = &self.registry, .own_registry = false, .fixture_transport = null, .fixture_extractor = null, .probe = .{} };
        return self;
    }
    fn deinit(self: *Fixture) void {
        self.content.deinit();
        self.instances.deinit();
        self.java.deinit();
        self.store.deinit();
        self.registry.deinit();
        self.paths.deinit();
        self.a.free(self.root);
        self.tmp.cleanup();
        self.a.destroy(self);
    }
    fn services(self: *Fixture) Services {
        return .{ .store = &self.store, .java = &self.java, .java_download = &self.download, .instances = &self.instances, .content = &self.content };
    }
    fn request(self: *Fixture, existing: bool) !Request {
        return .{ .archive_absolute_path = self.root, .identity = .{ .provider = .modrinth, .project_id = "project", .version_id = "v1" }, .preparation_generation = 9, .provider_policy_generation = self.content.snapshot().policy_generation, .target = if (existing) .{ .existing_instance = self.row } else .{ .new_instance = self.row }, .environment = try hostEnvironment() };
    }
    fn controller(self: *Fixture) !Controller {
        return Controller.init(self.a, std.testing.io, self.root, .{ .task_registry = &self.registry, .runner = .{ .context = self, .inspect = inspect, .manifest = catalogue, .fetcher = .{ .context = self, .fetch = fetch }, .probe = probe, .cleanup = cleanup } });
    }
    fn lease(self: *Fixture) @import("../core/content_install.zig").Lease {
        return .{ .context = self, .acquire = acquire, .recheck = recheck, .release = release };
    }
    fn acquire(raw: ?*anyopaque, _: []const u8) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        if (self.leased) return error.FixtureLeaseBusy;
        self.leased = true;
    }
    fn recheck(raw: ?*anyopaque, _: []const u8) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        if (!self.leased) return error.FixtureLeaseLost;
    }
    fn release(raw: ?*anyopaque, _: []const u8) void {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        self.leased = false;
    }
    fn inspect(raw: ?*anyopaque, a: A, io: Io, _: *const paths_mod.Paths, _: []const u8, cancel: ?*const packs.CancelToken) !packs.Inspection {
        if (cancel) |value| if (value.load(.acquire)) return error.Canceled;
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        self.inspect_count += 1;
        if (self.inspect_error) |err| return err;
        var parsed: @import("../core/content_providers.zig").Owned(manifest.PackPlan) = .{ .arena = .init(a), .value = undefined };
        errdefer parsed.deinit();
        parsed.value = try clone(manifest.PackPlan, parsed.arena.allocator(), .{ .identity = .{ .provider = .modrinth, .project_id = "local", .version_id = "archive" }, .name = "Fixture pack", .version = "one", .minecraft_version = self.row.minecraft_version, .loader = self.row.loader, .loader_version = self.row.loader_version });
        var arena: std.heap.ArenaAllocator = .init(a);
        errdefer arena.deinit();
        const stage = try std.fs.path.join(arena.allocator(), &.{ self.root, ".vela", "pack-imports", "import-00000000000000000000000000000000" });
        const archive = try std.fs.path.join(arena.allocator(), &.{ stage, "archive.zip" });
        const fixture_fs = @import("../core/content_fs.zig");
        const root_dir = try fixture_fs.openAbsolute(io, self.root);
        defer root_dir.close(io);
        const vela = try fixture_fs.child(root_dir, io, ".vela", true, false);
        defer vela.close(io);
        const stages = try fixture_fs.child(vela, io, "pack-imports", true, true);
        defer stages.close(io);
        const stage_name = std.fs.path.basename(stage);
        try stages.createDir(io, stage_name, fixture_fs.privatePermissions(true));
        errdefer stages.deleteTree(io, stage_name) catch {};
        const stage_dir = try fixture_fs.child(stages, io, stage_name, false, true);
        defer stage_dir.close(io);
        try fixture_fs.write(stage_dir, io, "archive.zip", "immutable");
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash("immutable", &digest, .{});
        return .{ .arena = arena, .parsed = parsed, .pack = parsed.value, .provider = .modrinth, .source_sha256 = std.fmt.bytesToHex(digest, .lower), .archive_absolute_path = archive, .stage_absolute_path = stage };
    }
    fn catalogue(raw: ?*anyopaque, a: A, _: Io, _: ?*const packs.CancelToken) !metadata.Owned(metadata.manifest.Manifest) {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        self.metadata_count += 1;
        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(self.metadata_bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        const bytes = try std.fmt.allocPrint(a, "{{\"latest\":{{\"release\":\"base\",\"snapshot\":\"base\"}},\"versions\":[{{\"id\":\"base\",\"type\":\"release\",\"url\":\"https://piston-meta.mojang.com/v1/packages/fixture/base.json\",\"time\":\"2024-01-01T00:00:00Z\",\"releaseTime\":\"2024-01-01T00:00:00Z\",\"sha1\":\"{s}\"}}]}}", .{hex});
        defer a.free(bytes);
        return metadata.manifest.parseSlice(a, bytes);
    }
    fn fetch(raw: ?*anyopaque, a: A, _: Io, _: vanilla.Request) ![]u8 {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        return a.dupe(u8, self.metadata_bytes);
    }
    fn probe(raw: ?*anyopaque, a: A, _: Io, path: []const u8, cancel: ?*const packs.CancelToken) !java_manager.Runtime {
        if (cancel) |value| if (value.load(.acquire)) return error.Canceled;
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        self.probe_count += 1;
        const owned_path = try a.dupe(u8, path);
        errdefer a.free(owned_path);
        return .{ .path = owned_path, .major = self.probe_major, .vendor = try a.dupe(u8, "Fixture") };
    }
    fn cleanup(raw: ?*anyopaque, io: Io, inspection: *const packs.Inspection) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        self.cleanup_count += 1;
        if (self.cleanup_error) |err| return err;
        try inspection.cleanup(io);
    }
    fn install(raw: ?*anyopaque, a: A, io: Io, install_request: instances_manager.CreateRequest, _: instances_manager.Control) !instances_manager.Installed {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        self.create_count += 1;
        const proof = install_request.vanilla_prepared orelse return error.FixtureMissingVanillaProof;
        try proof.validateBinding(a, io, .{ .root = install_request.root, .instance_id = install_request.instance.id, .instance_name = install_request.instance.name, .version_id = install_request.instance.minecraft_version, .generation = install_request.prepared_generation, .environment = try hostEnvironment() });
        try self.tmp.dir.createDirPath(io, ".minecraft/versions/Display Name");
        try self.tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Display Name/committed.marker", .data = "committed" });
        try self.tmp.dir.createDirPath(io, ".vela/jdks");
        try self.tmp.dir.writeFile(io, .{ .sub_path = ".vela/jdks/retained.marker", .data = "retained" });
        return instances_manager.Installed.init(a, install_request.instance);
    }
    fn registerRuntime(self: *Fixture, major_number: u32) !void {
        const path = try std.fmt.allocPrint(self.a, "/fixture/java-{d}", .{major_number});
        defer self.a.free(path);
        try self.java.addDownloaded(.{ .path = path, .major = major_number, .vendor = "Fixture" });
    }
    fn publishExisting(self: *Fixture) !void {
        var doc = self.store.snapshot().*;
        doc.instances = &.{self.row};
        try self.store.update(doc);
    }
    fn joinPrivate(controller_value: *Controller) void {
        if (controller_value.core.job) |job| if (job.thread) |thread| {
            thread.join();
            job.thread = null;
        };
    }
    fn joinInstance(self: *Fixture) void {
        if (self.instances.active) |job| if (job.future) |*future| future.await(std.testing.io);
    }
    fn advance(self: *Fixture, controller_value: *Controller) void {
        joinPrivate(controller_value);
        if (controller_value.ownsInstancesPublication()) self.joinInstance();
        if (controller_value.core.content_owned) if (self.content.active) |job| if (job.future) |*future| future.await(std.testing.io);
        if (controller_value.snapshot().phase == .cleaning) _ = controller_value.core.job.?.joinCleanup(true);
        controller_value.tick(self.services());
        self.content.tick();
    }
    fn until(self: *Fixture, controller_value: *Controller, phase: Phase) !void {
        for (0..24) |_| {
            if (controller_value.snapshot().phase == phase) return;
            self.advance(controller_value);
            if (controller_value.snapshot().phase == .failed) {
                const failure = controller_value.snapshot().failure orelse error.FixtureUnexpectedFailure;
                std.debug.print("{s}\n", .{@errorName(failure)});
                return failure;
            }
        }
        return error.FixturePhaseNotReached;
    }
    fn previousProvider(self: *Fixture, selected: bool) !void {
        if (selected) {
            try self.publishExisting();
            try self.content.select(self.row);
            if (self.content.active) |job| if (job.future) |*future| future.await(std.testing.io);
            self.content.tick();
            try std.testing.expect(!self.content.isBusy());
            if (self.content.snapshot().failure) |err| return err;
        }
        // Seed the prior provider without credentials; the destination is Modrinth.
        self.content.provider = .curseforge;
    }
};
fn fixtureInitAllocation(a: A) !void {
    var value = try Controller.init(a, std.testing.io, "/fixture/root", .{});
    defer value.deinit(undefined);
}

test "pack coordinator initialization allocation rollback is complete" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, fixtureInitAllocation, .{});
}

test "pack coordinator full row binding includes runtime memory debug and origin" {
    const row: config.Instance = .{ .id = "game", .name = "Name", .minecraft_version = "base", .loader = .vanilla, .max_memory_mb = 2048, .origin = .{ .kind = .modrinth, .project_id = "project", .version_id = "v1" } };
    try std.testing.expect(sameRow(row, row));
    var changed = row;
    changed.java_path = "/java";
    try std.testing.expect(!sameRow(row, changed));
    changed = row;
    changed.max_memory_mb = changed.max_memory_mb.? + 1;
    try std.testing.expect(!sameRow(row, changed));
    changed = row;
    changed.debug_launch = !changed.debug_launch;
    try std.testing.expect(!sameRow(row, changed));
    changed = row;
    changed.origin.?.version_id = "v2";
    try std.testing.expect(!sameRow(row, changed));
    changed = row;
    changed.name = "Renamed";
    try std.testing.expect(!sameRow(row, changed));
}

test "pack coordinator download token binds generation serial role and exact request" {
    const request: downloads.Request = .{ .vendor = .azul, .major = 17 };
    const token: DownloadToken = .{ .generation = 9, .serial = 3, .role = .runtime, .request = request };
    try std.testing.expect(downloadMatches(token, 9, 3, .runtime, request));
    try std.testing.expect(!downloadMatches(token, 10, 3, .runtime, request));
    try std.testing.expect(!downloadMatches(token, 9, 4, .runtime, request));
    try std.testing.expect(!downloadMatches(token, 9, 3, .installer, request));
    try std.testing.expect(!downloadMatches(token, 9, 3, .runtime, null));
    try std.testing.expect(!downloadMatches(token, 9, 3, .runtime, .{ .vendor = .azul, .major = 8 }));
}

test "pack coordinator downloaded archive alone never proves a usable registered JVM" {
    var installed: java_backend.Installed = .{ .allocator = std.testing.allocator, .directory = "/jdk", .java_path = "/jdk/bin/java" };
    var snap: downloads.Snapshot = .{ .phase = .complete, .progress = .{ .stage = .finalizing, .completed = 1, .total = 1 }, .request = .{ .vendor = .azul, .major = 17 }, .installed = &installed, .release = null, .registered = false, .probe_failure = null, .registration_failure = null, .failure = null };
    try std.testing.expectError(error.JavaNotRegistered, validateDownload(snap));
    snap.registered = true;
    snap.probe_failure = error.BrokenJvm;
    try std.testing.expectError(error.BrokenJvm, validateDownload(snap));
    snap.probe_failure = null;
    snap.registration_failure = error.RegistrySaveFailed;
    try std.testing.expectError(error.RegistrySaveFailed, validateDownload(snap));
    snap.registration_failure = null;
    try validateDownload(snap);
}

test "pack coordinator fails closed on receipt capability stale generation and host environment" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    var request = try fixture.request(false);
    fixture.content.options.allow_manifest_v2 = false;
    try std.testing.expectError(error.ManifestV2CapabilityRequired, value.start(request, fixture.services()));
    fixture.content.options.allow_manifest_v2 = true;
    request.preparation_generation = 0;
    try std.testing.expectError(error.StalePreparationGeneration, value.start(request, fixture.services()));
    request = try fixture.request(false);
    request.provider_policy_generation +%= 1;
    try std.testing.expectError(error.ContentPolicyChanged, value.start(request, fixture.services()));
    request = try fixture.request(false);
    request.environment.arch = "foreign";
    try std.testing.expectError(error.PreparedMetadataMismatch, value.start(request, fixture.services()));
    try std.testing.expectEqual(@as(usize, 0), fixture.inspect_count);
}

test "pack coordinator source spawn rollback releases reserved cleanup and task" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    value.core.options.fixture_spawn_failure = error.FixtureSpawnFailure;
    try std.testing.expectError(error.FixtureSpawnFailure, value.start(try fixture.request(false), fixture.services()));
    try std.testing.expect(value.core.job == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.inspect_count);
}

test "pack coordinator selected incompatible runtime never falls back or downloads" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.registerRuntime(17);
    try fixture.registerRuntime(21);
    try fixture.java.choose(fixture.row.name, "/fixture/java-21", 21);
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    try value.start(try fixture.request(false), fixture.services());
    Fixture.joinPrivate(&value);
    value.tick(fixture.services());
    _ = value.core.job.?.joinCleanup(true);
    value.tick(fixture.services());
    try std.testing.expectEqual(Phase.failed, value.snapshot().phase);
    try std.testing.expectEqual(error.IncompatibleJava, value.snapshot().failure.?);
    try std.testing.expectEqual(@as(usize, 0), fixture.probe_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.create_count);
    try std.testing.expect(!value.ownsJavaDownload());
}

test "pack coordinator fresh probe rejects a registered JVM whose actual major changed" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.registerRuntime(17);
    fixture.probe_major = 8;
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    try value.start(try fixture.request(false), fixture.services());
    fixture.advance(&value);
    fixture.advance(&value);
    fixture.advance(&value);
    try std.testing.expectEqual(Phase.failed, value.snapshot().phase);
    try std.testing.expectEqual(error.JavaMajorMismatch, value.snapshot().failure.?);
    try std.testing.expectEqual(@as(usize, 1), fixture.probe_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.create_count);
}

test "pack coordinator existing target bypasses metadata Java and create then retains failed adoption" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.publishExisting();
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    try value.start(try fixture.request(true), fixture.services());
    try fixture.until(&value, .selecting_content);
    fixture.content.options.fixture_spawn_failure = error.AdoptionSpawnFailed;
    try fixture.until(&value, .awaiting_adoption);
    try std.testing.expectEqual(Phase.awaiting_adoption, value.snapshot().phase);
    try std.testing.expect(value.snapshot().failure.? == error.AdoptionSpawnFailed);
    try std.testing.expect(!value.core.content_owned);
    try std.testing.expect(value.core.job.?.inspection != null);
    try std.testing.expectEqual(@as(usize, 0), fixture.metadata_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.probe_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.create_count);
}

test "pack coordinator changed policy cancels owned inspection and reports cleanup failure" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.publishExisting();
    fixture.cleanup_error = error.StageCleanupFailed;
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    try value.start(try fixture.request(true), fixture.services());
    Fixture.joinPrivate(&value);
    fixture.content.policy_generation +%= 1;
    value.tick(fixture.services());
    _ = value.core.job.?.joinCleanup(true);
    value.tick(fixture.services());
    try std.testing.expectEqual(Phase.failed, value.snapshot().phase);
    try std.testing.expectEqual(error.ContentPolicyChanged, value.snapshot().failure.?);
    try std.testing.expectEqual(error.StageCleanupFailed, value.snapshot().cleanup_failure.?);
    try std.testing.expectEqual(@as(usize, 1), fixture.cleanup_count);
}

test "pack coordinator create publishes actual runtime row but failed adoption retains inspection" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.registerRuntime(17);
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    try value.start(try fixture.request(false), fixture.services());
    try fixture.until(&value, .selecting_content);
    fixture.content.options.fixture_spawn_failure = error.AdoptionSpawnFailed;
    try fixture.until(&value, .awaiting_adoption);
    try std.testing.expectEqual(Phase.awaiting_adoption, value.snapshot().phase);
    try std.testing.expect(value.snapshot().failure.? == error.AdoptionSpawnFailed);
    try std.testing.expect(!value.core.content_owned);
    const actual = value.snapshot().instance.?;
    try std.testing.expectEqualStrings("/fixture/java-17", actual.java_path.?);
    _ = try matchingRow(&fixture.store, actual);
    try std.testing.expectEqual(@as(usize, 1), fixture.create_count);
    try std.testing.expect(value.core.job.?.inspection != null);
    try std.testing.expect(!value.ownsInstancesPublication());
}

test "pack coordinator uncertainty requires external reconcile and late cancel preserves durable row" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.registerRuntime(17);
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    try value.start(try fixture.request(false), fixture.services());
    try fixture.until(&value, .creating);
    fixture.joinInstance();
    fixture.instances.tick();
    try value.core.captureCreated();
    const pending = fixture.instances.pending.?;
    var doc = fixture.store.snapshot().*;
    doc.instances = &.{pending.installed.?.instance};
    try fixture.store.update(doc);
    pending.uncertain_publication_store = &fixture.store;
    fixture.store.publication_uncertain = true;
    value.tick(fixture.services());
    try std.testing.expectEqual(Phase.awaiting_reconciliation, value.snapshot().phase);
    value.cancel(fixture.services());
    try std.testing.expectError(error.ConfigPublicationUncertain, value.acknowledgeReconciled(fixture.services()));
    try fixture.store.reconcile();
    try value.acknowledgeReconciled(fixture.services());
    fixture.advance(&value);
    try std.testing.expectEqual(Phase.canceled, value.snapshot().phase);
    try std.testing.expect(!value.ownsInstancesPublication());
    _ = try matchingRow(&fixture.store, value.snapshot().instance.?);
    var marker = try fixture.tmp.dir.openFile(std.testing.io, ".minecraft/versions/Display Name/committed.marker", .{});
    marker.close(std.testing.io);
    marker = try fixture.tmp.dir.openFile(std.testing.io, ".vela/jdks/retained.marker", .{});
    marker.close(std.testing.io);
}

test "pack coordinator shutdown joins create clears borrowed proof but preserves pending lease debt" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.registerRuntime(17);
    var value = try fixture.controller();
    var live = true;
    defer if (live) value.deinit(fixture.services());
    try value.start(try fixture.request(false), fixture.services());
    try fixture.until(&value, .creating);
    fixture.joinInstance();
    value.deinit(fixture.services());
    live = false;
    try std.testing.expect(fixture.instances.pending != null);
    try std.testing.expect(fixture.instances.pending.?.vanilla_prepared == null);
    try std.testing.expect(fixture.instances.pending.?.prepared == null);
    try std.testing.expect(fixture.leased);
    try std.testing.expectEqual(@as(usize, 1), fixture.cleanup_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.store.snapshot().instances.len);
}

test "pack coordinator changed full existing row cancels before content adoption" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.publishExisting();
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    try value.start(try fixture.request(true), fixture.services());
    Fixture.joinPrivate(&value);
    var changed = fixture.row;
    changed.debug_launch = !changed.debug_launch;
    var doc = fixture.store.snapshot().*;
    doc.instances = &.{changed};
    try fixture.store.update(doc);
    value.tick(fixture.services());
    _ = value.core.job.?.joinCleanup(true);
    value.tick(fixture.services());
    try std.testing.expectEqual(error.InstanceConfigurationChanged, value.snapshot().failure.?);
    try std.testing.expectEqual(@as(usize, 1), fixture.cleanup_count);
    try std.testing.expect(!value.core.content_owned);
}

test "pack coordinator Java roles resolve independent exact-major selections" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.registerRuntime(17);
    try fixture.registerRuntime(8);
    try fixture.java.choose(fixture.row.name, "/fixture/java-17", 17);
    try fixture.java.choose("game:installer", "/fixture/java-8", 8);
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    try value.start(try fixture.request(false), fixture.services());
    Fixture.joinPrivate(&value);
    const job = value.core.job.?;
    if (job.failure) |err| {
        std.debug.print("{s}\n", .{@errorName(err)});
        return err;
    }
    try std.testing.expect(job.proof != null);
    try std.testing.expect(job.runtime_major != null);
    job.installer_major = 8;
    const runtime = (try value.core.selected(.runtime)) orelse return error.FixtureMissingRuntime;
    const installer = (try value.core.selected(.installer)) orelse return error.FixtureMissingInstaller;
    try std.testing.expectEqual(@as(u32, 17), runtime.major);
    try std.testing.expectEqual(@as(u32, 8), installer.major);
    try std.testing.expectEqualStrings("/fixture/java-17", runtime.path);
    try std.testing.expectEqualStrings("/fixture/java-8", installer.path);
}

test "pack coordinator failed adoption retry retains inspection through fresh selection refresh" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.publishExisting();
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    try value.start(try fixture.request(true), fixture.services());
    try fixture.until(&value, .selecting_content);
    fixture.content.options.fixture_spawn_failure = error.AdoptionSpawnFailed;
    try fixture.until(&value, .awaiting_adoption);
    try std.testing.expectEqual(Phase.awaiting_adoption, value.snapshot().phase);
    try std.testing.expect(value.snapshot().failure.? == error.AdoptionSpawnFailed);
    try std.testing.expect(!value.core.content_owned);
    const stage = value.core.job.?.inspection.?.stage_absolute_path;
    fixture.content.options.fixture_spawn_failure = null;
    try value.retryAdoption(fixture.services());
    try std.testing.expectEqual(Phase.selecting_content, value.snapshot().phase);
    try std.testing.expectEqualStrings(stage, value.core.job.?.inspection.?.stage_absolute_path);
    try std.testing.expect(value.core.content_owned);
}

test "pack coordinator clone copies error values while retaining deep container ownership" {
    const Choice = union(enum) { problem: anyerror, text: []const u8 };
    const Value = struct {
        plain: anyerror,
        optional: ?anyerror,
        absent: ?anyerror,
        errors: []const anyerror,
        choice: Choice,
        text: []const u8,
    };
    var source_text = [_]u8{ 'o', 'w', 'n' };
    var source_errors = [_]anyerror{error.FixtureCloneError};
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const copied = try clone(Value, arena.allocator(), .{
        .plain = error.FixtureCloneError,
        .optional = error.FixtureCloneError,
        .absent = null,
        .errors = &source_errors,
        .choice = .{ .problem = error.FixtureCloneError },
        .text = &source_text,
    });
    source_text[0] = 'x';
    source_errors[0] = error.FixtureChangedError;
    try std.testing.expect(copied.plain == error.FixtureCloneError);
    try std.testing.expect(copied.optional.? == error.FixtureCloneError);
    try std.testing.expect(copied.absent == null);
    try std.testing.expect(copied.errors[0] == error.FixtureCloneError);
    try std.testing.expect(copied.choice.problem == error.FixtureCloneError);
    try std.testing.expectEqualStrings("own", copied.text);
}

test "pack coordinator failed trusted metadata leaves proof null through join and cleanup" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.metadata_bytes = "{\"id\":\"base\",\"javaVersion\":{\"majorVersion\":17}}";
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    try value.start(try fixture.request(false), fixture.services());
    Fixture.joinPrivate(&value);
    const job = value.core.job.?;
    try std.testing.expect(job.proof == null);
    try std.testing.expect(job.inspection != null);
    try std.testing.expect(job.failure.? == error.MissingField);
    value.tick(fixture.services());
    _ = job.joinCleanup(true);
    value.tick(fixture.services());
    try std.testing.expectEqual(Phase.failed, value.snapshot().phase);
    try std.testing.expect(value.snapshot().failure.? == error.MissingField);
    try std.testing.expect(job.proof == null);
    try std.testing.expect(job.inspection == null);
    if (value.snapshot().cleanup_failure) |err| std.debug.print("{s}\n", .{@errorName(err)});
    try std.testing.expect(value.snapshot().cleanup_failure == null);
    try std.testing.expectEqual(@as(usize, 1), fixture.cleanup_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.probe_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.create_count);
}

test "pack coordinator failed inspection never publishes a partial inspection owner" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.inspect_error = error.FixtureInspectionFailed;
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    try value.start(try fixture.request(false), fixture.services());
    Fixture.joinPrivate(&value);
    const job = value.core.job.?;
    try std.testing.expect(job.inspection == null);
    try std.testing.expect(job.proof == null);
    try std.testing.expect(job.failure.? == error.FixtureInspectionFailed);
    value.tick(fixture.services());
    _ = job.joinCleanup(true);
    value.tick(fixture.services());
    try std.testing.expectEqual(Phase.failed, value.snapshot().phase);
    try std.testing.expect(value.snapshot().failure.? == error.FixtureInspectionFailed);
    try std.testing.expect(job.inspection == null);
    try std.testing.expect(job.proof == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.metadata_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.cleanup_count);
}

test "pack coordinator provider selection without prior row owns only its policy increment" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.previousProvider(false);
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    const request = try fixture.request(false);
    const generation = request.provider_policy_generation;
    try value.start(request, fixture.services());
    try std.testing.expectEqual(Phase.awaiting_provider, value.snapshot().phase);
    try std.testing.expect(!value.core.content_owned);
    try std.testing.expect(value.core.job.?.task != null);
    try std.testing.expect(value.core.job.?.cleanup_thread != null);
    try std.testing.expect(value.core.job.?.thread == null);
    try std.testing.expectEqual(generation, request.provider_policy_generation);
    try std.testing.expectEqual(generation +% 1, value.core.job.?.request.provider_policy_generation);
    try std.testing.expectEqual(value.core.policy_generation, fixture.content.snapshot().policy_generation);
    try std.testing.expectEqual(@as(usize, 0), fixture.inspect_count);
    value.tick(fixture.services());
    try std.testing.expectEqual(Phase.preparing, value.snapshot().phase);
    Fixture.joinPrivate(&value);
    try std.testing.expect(value.core.job.?.failure == null);
    try std.testing.expect(value.core.job.?.proof != null);
    try std.testing.expectEqual(@as(usize, 1), fixture.inspect_count);
}

test "pack coordinator prior row provider refresh joins before NEW or EXISTING inspection" {
    for ([_]bool{ false, true }) |existing| {
        const fixture = try Fixture.init();
        defer fixture.deinit();
        try fixture.previousProvider(true);
        var value = try fixture.controller();
        defer value.deinit(fixture.services());
        var request = try fixture.request(existing);
        if (!existing) {
            var row = fixture.row;
            row.id = "new-game";
            row.name = "New Game";
            request.target = .{ .new_instance = row };
        }
        const generation = request.provider_policy_generation;
        try value.start(request, fixture.services());
        try std.testing.expect(value.core.content_owned);
        try std.testing.expect(fixture.content.active == null);
        value.tick(fixture.services());
        try std.testing.expectEqual(Phase.awaiting_provider, value.snapshot().phase);
        fixture.content.tick();
        const refresh = fixture.content.active orelse return error.FixtureMissingRefresh;
        if (refresh.future) |*future| future.await(std.testing.io);
        value.tick(fixture.services());
        try std.testing.expectEqual(Phase.awaiting_provider, value.snapshot().phase);
        try std.testing.expect(value.core.job.?.thread == null);
        try std.testing.expectEqual(@as(usize, 0), fixture.inspect_count);
        fixture.content.tick();
        value.tick(fixture.services());
        try std.testing.expectEqual(Phase.preparing, value.snapshot().phase);
        try std.testing.expect(!value.core.content_owned);
        try std.testing.expectEqual(generation, request.provider_policy_generation);
        Fixture.joinPrivate(&value);
        try std.testing.expect(value.core.job.?.failure == null);
        try std.testing.expectEqual(existing, value.core.job.?.proof == null);
        try std.testing.expectEqual(@as(usize, 1), fixture.inspect_count);
    }
}

test "pack coordinator stale or foreign busy provider admission never mutates or claims it" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.previousProvider(true);
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    var request = try fixture.request(true);
    const generation = request.provider_policy_generation;
    request.provider_policy_generation +%= 1;
    try std.testing.expectError(error.ContentPolicyChanged, value.start(request, fixture.services()));
    try std.testing.expectEqual(providers.Provider.curseforge, fixture.content.snapshot().provider);
    try std.testing.expectEqual(generation, fixture.content.snapshot().policy_generation);
    try std.testing.expect(value.core.job == null);
    try fixture.content.refresh();
    const foreign = fixture.content.active orelse return error.FixtureMissingRefresh;
    request.provider_policy_generation = generation;
    try std.testing.expectError(error.ContentWorkerBusy, value.start(request, fixture.services()));
    value.cancel(fixture.services());
    try std.testing.expect(!foreign.task.?.canceled());
    try std.testing.expect(!value.core.content_owned);
    try std.testing.expect(value.core.job == null);
    if (foreign.future) |*future| future.await(std.testing.io);
    fixture.content.tick();
    try std.testing.expect(fixture.content.snapshot().failure == null);
    try std.testing.expectEqual(providers.Provider.curseforge, fixture.content.snapshot().provider);
    try std.testing.expectEqual(@as(usize, 0), fixture.inspect_count);
}

test "pack coordinator queued and active provider cancellation join before owner release" {
    for ([_]bool{ false, true }) |active| {
        const fixture = try Fixture.init();
        defer fixture.deinit();
        try fixture.previousProvider(true);
        var value = try fixture.controller();
        defer value.deinit(fixture.services());
        try value.start(try fixture.request(true), fixture.services());
        if (active) fixture.content.tick();
        value.cancel(fixture.services());
        try fixture.until(&value, .canceled);
        try std.testing.expect(!value.core.content_owned);
        try std.testing.expect(!fixture.content.isBusy());
        try std.testing.expect(value.core.job.?.proof == null);
        try std.testing.expectEqual(@as(usize, 0), fixture.inspect_count);
        try std.testing.expectEqual(@as(usize, 0), fixture.metadata_count);
        try std.testing.expectEqual(providers.Provider.modrinth, fixture.content.snapshot().provider);
        _ = try matchingRow(&fixture.store, fixture.row);
    }
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.previousProvider(true);
    var value = try fixture.controller();
    var live = true;
    defer if (live) value.deinit(fixture.services());
    try value.start(try fixture.request(true), fixture.services());
    fixture.content.tick();
    try std.testing.expect(fixture.content.active != null);
    value.deinit(fixture.services());
    live = false;
    try std.testing.expect(!fixture.content.isBusy());
    try std.testing.expectEqual(@as(usize, 0), fixture.inspect_count);
    _ = try matchingRow(&fixture.store, fixture.row);
}

test "pack coordinator provider refresh and later prepare failures remain before inspection" {
    const Failure = enum { refresh_spawn, refresh_receipt, prepare_spawn };
    for ([_]Failure{ .refresh_spawn, .refresh_receipt, .prepare_spawn }) |failure| {
        const fixture = try Fixture.init();
        defer fixture.deinit();
        try fixture.previousProvider(true);
        var value = try fixture.controller();
        defer value.deinit(fixture.services());
        switch (failure) {
            .refresh_spawn => fixture.content.options.fixture_spawn_failure = error.ProviderRefreshSpawnFailed,
            .refresh_receipt => {
                const bytes = try manifest.serialize(fixture.a, .{ .instance_id = "other", .pack_version = "v1" });
                defer fixture.a.free(bytes);
                try fixture.tmp.dir.createDirPath(std.testing.io, ".vela/instances/game");
                try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".vela/instances/game/content.json", .data = bytes });
            },
            .prepare_spawn => value.core.options.fixture_spawn_failure = error.PreparationSpawnFailed,
        }
        try value.start(try fixture.request(true), fixture.services());
        for (0..8) |_| {
            fixture.advance(&value);
            if (value.snapshot().phase == .failed) break;
        }
        try std.testing.expectEqual(Phase.failed, value.snapshot().phase);
        const expected: anyerror = switch (failure) {
            .refresh_spawn => error.ProviderRefreshSpawnFailed,
            .refresh_receipt => error.InstanceMismatch,
            .prepare_spawn => error.PreparationSpawnFailed,
        };
        try std.testing.expect(value.snapshot().failure.? == expected);
        try std.testing.expect(!value.core.content_owned);
        try std.testing.expect(value.core.job.?.proof == null);
        try std.testing.expectEqual(@as(usize, 0), fixture.inspect_count);
        try std.testing.expectEqual(@as(usize, 0), fixture.metadata_count);
        try std.testing.expectEqual(providers.Provider.modrinth, fixture.content.snapshot().provider);
    }
}

test "pack coordinator provider wait rejects stale policy or full target after owned refresh" {
    for ([_]bool{ false, true }) |policy_changed| {
        const fixture = try Fixture.init();
        defer fixture.deinit();
        try fixture.previousProvider(true);
        var value = try fixture.controller();
        defer value.deinit(fixture.services());
        try value.start(try fixture.request(true), fixture.services());
        fixture.content.tick();
        if (policy_changed) {
            fixture.content.policy_generation +%= 1;
        } else {
            var changed = fixture.row;
            changed.max_memory_mb = changed.max_memory_mb.? + 1;
            var doc = fixture.store.snapshot().*;
            doc.instances = &.{changed};
            try fixture.store.update(doc);
        }
        for (0..8) |_| {
            fixture.advance(&value);
            if (value.snapshot().phase == .failed) break;
        }
        try std.testing.expectEqual(Phase.failed, value.snapshot().phase);
        const expected: anyerror = if (policy_changed) error.ContentPolicyChanged else error.InstanceConfigurationChanged;
        try std.testing.expect(value.snapshot().failure.? == expected);
        try std.testing.expect(!value.core.content_owned);
        try std.testing.expect(!fixture.content.isBusy());
        try std.testing.expectEqual(@as(usize, 0), fixture.inspect_count);
        try std.testing.expectEqual(@as(usize, 0), fixture.metadata_count);
        try std.testing.expectEqual(providers.Provider.modrinth, fixture.content.snapshot().provider);
    }
}

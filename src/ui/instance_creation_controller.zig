//! Prepared metadata, Java proof and publication ownership for ordinary instance creation.
//! App suppresses manual Java dispatch and generic publication while owned.
//! Services, Runner contexts and rule matcher context outlive cancel + JOIN.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../core/config.zig");
const paths_mod = @import("../core/instances.zig");
const CancelToken = std.atomic.Value(bool);
const metadata = @import("../core/minecraft/metadata/root.zig");
const vanilla = @import("../core/minecraft/metadata_loader.zig");
const loader = @import("../core/loaders/install.zig");
const loaders = @import("../core/loaders/root.zig");
const http = @import("../core/http_transport.zig");
const tasks = @import("../core/tasks.zig");
const java_manager = @import("java_manager.zig");
const downloads = @import("java_download_controller.zig");
const java_backend = @import("../core/java_download.zig");
const instances_manager = @import("instances_manager.zig");
const A = std.mem.Allocator;
const Io = std.Io;

pub const Request = struct {
    preparation_generation: u64,
    instance: config.Instance,
    environment: metadata.rules.Environment,
};
pub const Services = struct {
    store: *config.Store,
    java: *java_manager.Manager,
    java_download: *downloads.Controller,
    instances: *instances_manager.Manager,
};
pub const JavaRole = enum { runtime, installer };
pub const Phase = enum {
    idle,
    preparing,
    discovering_java,
    probing_java,
    downloading_java,
    creating,
    awaiting_publication,
    awaiting_reconciliation,
    cleaning,
    complete,
    failed,
    canceled,
};
pub const Snapshot = struct {
    phase: Phase,
    failure: ?anyerror,
    preparation_generation: u64,
    serial: u64,
    role: ?JavaRole,
    runtime_major: ?u32,
    installer_major: ?u32,
    instance: ?config.Instance,
};
pub const Runner = struct {
    context: ?*anyopaque = null,
    // A fixture may return approved catalogue metadata without native HTTP.
    manifest: ?*const fn (?*anyopaque, A, Io, ?*const CancelToken) anyerror!metadata.Owned(metadata.manifest.Manifest) = null,
    fetcher: vanilla.Fetcher = .{},
    transport: ?loaders.Transport = null,
    probe: *const fn (?*anyopaque, A, Io, []const u8, ?*const CancelToken) anyerror!java_manager.Runtime = probeJava,
};
pub const Options = struct {
    task_registry: ?*tasks.Registry = null,
    runner: Runner = .{},
    http_options: http.Options = .{},
    /// One absolute budget for metadata preparation.
    metadata_timeout_ms: u64 = 300_000,
    java_vendor: java_backend.Vendor = .azul,
    fixture_spawn_failure: ?anyerror = null,
};

fn probeJava(_: ?*anyopaque, a: A, io: Io, path: []const u8, cancel: ?*const CancelToken) !java_manager.Runtime {
    return java_manager.probe(a, io, path, cancel);
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
            inline for (info.field_names, info.field_types) |field_name, field_type| {
                @field(result, field_name) = if (comptime copiedErrorValue(field_type)) @field(value, field_name) else try clone(field_type, a, @field(value, field_name));
            }
            return result;
        },
        .@"union" => |info| {
            const tag = std.meta.activeTag(value);
            inline for (info.field_names, info.field_types) |field_name, field_type| if (std.mem.eql(u8, field_name, @tagName(tag))) {
                return @unionInit(T, field_name, if (comptime copiedErrorValue(field_type)) @field(value, field_name) else try clone(field_type, a, @field(value, field_name)));
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
        a.min_memory_mb == b.min_memory_mb and a.max_memory_mb == b.max_memory_mb and a.debug_launch == b.debug_launch and
        (if (a.origin) |v| if (b.origin) |w| v.kind == w.kind and textEqual(v.project_id, w.project_id) and textEqual(v.version_id, w.version_id) else false else b.origin == null);
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
    task_id: ?u64 = null,
    instance_task_id: ?u64 = null,
    terminal_details: tasks.Details = .{},
    cancellation: CancelToken = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    action: Action = .prepare,
    failure: ?anyerror = null,
    proof: ?Proof = null,
    metadata_deadline_ms: ?u64 = null,
    runtime_major: ?u32 = null,
    installer_major: ?u32 = null,
    probe_path: []const u8 = "",
    probe_major: u32 = 0,
    runtime_path: ?[]const u8 = null,
    installer_path: ?[]const u8 = null,
    installer_key: []const u8,
    actual_row: ?config.Instance = null,

    fn create(a: A, io: Io, root: []const u8, request: Request, options: Options) !*Job {
        const self = try a.create(Job);
        errdefer a.destroy(self);
        var arena: std.heap.ArenaAllocator = .init(a);
        errdefer arena.deinit();
        var paths = try paths_mod.Paths.init(a, io, root);
        errdefer paths.deinit();
        const aa = arena.allocator();
        const owned = try clone(Request, aa, request);
        const key = try std.fmt.allocPrint(aa, "{s}:installer", .{owned.instance.id});
        self.* = .{ .a = a, .io = io, .arena = arena, .paths = paths, .request = owned, .options = try clone(Options, aa, options), .installer_key = key };
        return self;
    }
    fn destroy(self: *Job) void {
        std.debug.assert(self.thread == null and self.task == null);
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
        switch (self.action) {
            .prepare => {
                self.task.?.report(.metadata, 0, null);
                self.metadata_deadline_ms = nowMs(&self.io) +| self.options.metadata_timeout_ms;
                try self.checkMetadata();
                var client: ?http.Client = null;
                defer if (client) |*owned| owned.deinit();
                if (self.options.runner.manifest == null or self.options.runner.fetcher.fetch == null) {
                    const created_client = try http.Client.init(self.a, self.io, self.options.http_options);
                    client = created_client;
                }
                var fetch_context: FetchContext = .{ .client = if (client) |*owned| owned else null, .job = self };
                var catalog = try fetchManifest(self.a, &fetch_context);
                defer catalog.deinit();
                const fetcher: vanilla.Fetcher = .{ .context = &fetch_context, .fetch = fetchVersion };
                const row = self.request.instance;
                const base: vanilla.FetchOptions = .{ .version_id = row.minecraft_version, .manifest = catalog.value, .cancel = &self.cancellation };
                if (row.loader == .vanilla) {
                    const prepared = vanilla.prepareVanilla(self.a, self.io, .{ .target = self.vanillaTarget(), .vanilla = base, .fetcher = fetcher }) catch |err| {
                        try self.checkMetadata();
                        return err;
                    };
                    self.proof = .{ .vanilla = prepared };
                    self.runtime_major = try major(self.proof.?.vanilla.runtime_major);
                } else {
                    const prepared = loader.prepareMetadata(self.a, self.io, .{ .root = self.paths.root, .worker_checks = true, .instance_id = row.id, .instance_name = row.name, .generation = self.request.preparation_generation, .selection = try self.selection(), .environment = self.request.environment, .vanilla = base, .fetcher = fetcher, .http_options = self.options.http_options, .transport = self.options.runner.transport }, self.control()) catch |err| {
                        try self.checkMetadata();
                        return err;
                    };
                    self.proof = .{ .loader = prepared };
                    self.runtime_major = try major(self.proof.?.loader.requirements.runtime_major);
                    if (self.proof.?.loader.requirements.installer_major != 0) self.installer_major = try major(self.proof.?.loader.requirements.installer_major);
                }
                try self.checkMetadata();
            },
            .probe_runtime, .probe_installer => {
                self.task.?.report(.scanning, 0, null);
                const runtime = try self.options.runner.probe(self.options.runner.context, self.a, self.io, self.probe_path, &self.cancellation);
                defer java_manager.freeRuntime(self.a, runtime);
                if (runtime.major != self.probe_major) return error.JavaMajorMismatch;
                try runtime.architecture.requireHost();
                if (!textEqual(runtime.path, self.probe_path)) return error.JavaPathChanged;
                try self.checkCanceled();
            },
        }
    }
    fn checkCanceled(self: *const Job) !void {
        if (self.cancellation.load(.acquire) or (if (self.task) |task| task.canceled() else false)) return error.Canceled;
    }
    fn selection(self: *const Job) !loaders.Selection {
        const row = self.request.instance;
        return .{ .kind = switch (row.loader) {
            .fabric => .fabric,
            .forge => .forge,
            .neoforge => .neoforge,
            .quilt => .quilt,
            .vanilla => return error.InvalidLoader,
        }, .base_id = row.minecraft_version, .loader_id = row.loader_version orelse return error.InvalidLoaderVersion };
    }
    fn vanillaTarget(self: *const Job) vanilla.VanillaTarget {
        const row = self.request.instance;
        return .{ .root = self.paths.root, .instance_id = row.id, .instance_name = row.name, .version_id = row.minecraft_version, .generation = self.request.preparation_generation, .environment = self.request.environment };
    }
    fn validateProof(self: *const Job) !void {
        switch (self.proof orelse return error.MissingPreparedMetadata) {
            .vanilla => |*proof| try proof.validateBinding(self.a, self.io, self.vanillaTarget()),
            .loader => |*proof| {
                const row = self.request.instance;
                try proof.validateBinding(self.a, self.io, .{ .root = self.paths.root, .instance_id = row.id, .instance_name = row.name, .generation = self.request.preparation_generation, .selection = try self.selection(), .environment = self.request.environment });
            },
        }
    }
    fn checkMetadata(self: *Job) !void {
        try self.checkCanceled();
        try self.control().check();
    }
    fn control(self: *Job) loaders.Control {
        return .{ .cancel = &self.cancellation, .context = &self.io, .now_ms = nowMs, .deadline_ms = self.metadata_deadline_ms.? };
    }
};
fn nowMs(raw: ?*anyopaque) u64 {
    const io: *const Io = @ptrCast(@alignCast(raw.?));
    return @intCast(@max(0, @divFloor(Io.Clock.awake.now(io.*).nanoseconds, std.time.ns_per_ms)));
}
const FetchContext = struct {
    client: ?*http.Client,
    job: *Job,

    fn request(self: *FetchContext, url: []const u8, max_bytes: usize) !http.Request {
        try self.job.checkMetadata();
        const remaining = self.job.metadata_deadline_ms.? -| nowMs(&self.job.io);
        return .{
            .url = url,
            .cancel = &self.job.cancellation,
            .max_response_bytes = max_bytes,
            .require_public_address = true,
            .timeout_ms = @intCast(@max(1, @min(30_000, remaining))),
            .deadline_ns = @as(i96, self.job.metadata_deadline_ms.?) * std.time.ns_per_ms,
        };
    }
};
// HTTP.Client returns whole bodies; these details measure received bytes, never a rate.
const MetadataTransfer = struct {
    task: *tasks.Task,
    details: tasks.Details,
    index: usize,

    fn begin(job: *Job, url: []const u8, size: ?u64) MetadataTransfer {
        const task = job.task.?;
        var details = task.details();
        details.stage = .metadata;
        details.total = null; // The inherited metadata graph is not known yet.
        details.total_bytes = if (size) |known| details.received +| known else null;
        details.stop();
        const file = tasks.File.init(url, 0, size, 0, .downloading, null);
        const index = @min(details.file_count, details.files.len - 1);
        if (details.file_count < details.files.len) {
            details.addFile(file);
        } else {
            // Keep the current request visible, including its eventual failure.
            details.files[index] = file;
            details.omitted_files += 1;
        }
        task.reportDetails(details);
        return .{ .task = task, .details = details, .index = index };
    }

    fn received(self: *MetadataTransfer, bytes: usize) void {
        const file = &self.details.files[self.index];
        self.details.received +|= bytes;
        file.received = bytes;
        if (file.total == null) file.total = bytes;
        self.details.total_bytes = self.details.received - file.received +| file.total.?;
        file.state = .verifying;
        self.task.reportDetails(self.details);
    }

    fn finish(self: *MetadataTransfer, failure: ?anyerror) void {
        const file = &self.details.files[self.index];
        file.failure = failure;
        file.state = if (failure) |err| if (err == error.Canceled) .canceled else .failed else .complete;
        if (failure == null) self.details.completed += 1;
        self.task.reportDetails(self.details);
    }
};

fn fetchManifest(a: A, self: *FetchContext) anyerror!metadata.Owned(metadata.manifest.Manifest) {
    try self.job.checkMetadata();
    var transfer = MetadataTransfer.begin(self.job, metadata.version_manifest_url, null);
    return fetchManifestInner(a, self, &transfer) catch |err| {
        transfer.finish(err);
        return err;
    };
}

fn fetchManifestInner(a: A, self: *FetchContext, transfer: *MetadataTransfer) anyerror!metadata.Owned(metadata.manifest.Manifest) {
    var catalog = if (self.job.options.runner.manifest) |get| get(self.job.options.runner.context, a, self.job.io, &self.job.cancellation) catch |err| {
        try self.job.checkMetadata();
        return @as(anyerror!metadata.Owned(metadata.manifest.Manifest), err);
    } else catalog: {
        var response = self.client.?.execute(try self.request(metadata.version_manifest_url, 16 * 1024 * 1024)) catch |err| {
            try self.job.checkMetadata();
            return @as(anyerror!metadata.Owned(metadata.manifest.Manifest), err);
        };
        defer response.deinit();
        transfer.received(response.body.len);
        try self.job.checkMetadata();
        if (response.status != 200) return error.MetadataHttpFailure;
        break :catalog try metadata.manifest.parseSlice(a, response.body);
    };
    errdefer catalog.deinit();
    try self.job.checkMetadata();
    transfer.finish(null);
    return catalog;
}
fn fetchVersion(raw: ?*anyopaque, a: A, io: Io, request: vanilla.Request) anyerror![]u8 {
    const self: *FetchContext = @ptrCast(@alignCast(raw.?));
    try self.job.checkMetadata();
    var transfer = MetadataTransfer.begin(self.job, request.url, request.size);
    return fetchVersionInner(self, a, io, request, &transfer) catch |err| {
        transfer.finish(err);
        return err;
    };
}

fn fetchVersionInner(self: *FetchContext, a: A, io: Io, request: vanilla.Request, transfer: *MetadataTransfer) anyerror![]u8 {
    const bytes = if (self.job.options.runner.fetcher.fetch) |get| bytes: {
        const body = get(self.job.options.runner.fetcher.context, a, io, request) catch |err| {
            try self.job.checkMetadata();
            return @as(anyerror![]u8, err);
        };
        transfer.received(body.len);
        break :bytes body;
    } else bytes: {
        var response = self.client.?.execute(try self.request(request.url, request.max_bytes)) catch |err| {
            try self.job.checkMetadata();
            return @as(anyerror![]u8, err);
        };
        defer response.deinit();
        transfer.received(response.body.len);
        try self.job.checkMetadata();
        if (response.status != 200) return error.MetadataHttpFailure;
        break :bytes try a.dupe(u8, response.body);
    };
    errdefer a.free(bytes);
    try self.job.checkMetadata();
    // Classify the transfer here; the core loader independently verifies untrusted bytes.
    if (bytes.len > request.max_bytes) return error.MetadataTooLarge;
    if (request.size) |size| if (bytes.len != size) return error.SizeMismatch;
    if (request.sha1) |expected| {
        var digest: metadata.Sha1 = undefined;
        std.crypto.hash.Sha1.hash(bytes, &digest, .{});
        if (!std.mem.eql(u8, &digest, &expected)) {
            if (!builtin.is_test) std.log.scoped(.minecraft_metadata).warn("metadata SHA-1 mismatch: version={s} source={s} expected={s} actual={s} bytes={d}", .{
                request.id,
                transfer.details.files[transfer.index].path(),
                std.fmt.bytesToHex(expected, .lower),
                std.fmt.bytesToHex(digest, .lower),
                bytes.len,
            });
            return error.ChecksumMismatch;
        }
    }
    transfer.finish(null);
    return bytes;
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
    role: ?JavaRole = null,
    discovery_owned: bool = false,
    discovered: bool = false,
    download_token: ?DownloadToken = null,
    instance_owned: bool = false,
    cancel_requested: bool = false,
    stopping: bool = false,

    fn registry(self: *Core) *tasks.Registry {
        return self.options.task_registry orelse &self.private_registry;
    }
    fn finish(self: *Core, outcome: tasks.Outcome) void {
        if (self.job) |job| if (job.task) |task| {
            self.registry().finish(task, outcome);
            job.terminal_details = task.details();
            job.task = null;
        };
    }
    fn checkServices(self: *const Core, services: Services) !void {
        if (self.services) |bound| if (!std.meta.eql(bound, services)) return error.PrerequisiteServicesChanged;
        if (!textEqual(self.paths.root, services.store.root) or !textEqual(self.paths.root, services.instances.root) or
            !textEqual(self.paths.jdks, services.java_download.root) or
            !textEqual(self.java_file, services.java.file)) return error.ConfigurationStoreChanged;
    }
    fn checkBinding(self: *const Core, services: Services, require_row: bool) !void {
        try self.checkServices(services);
        const job = self.job orelse return error.NoInstanceCreation;
        try checkEnvironment(job.request.environment);
        if (require_row) _ = try matchingRow(services.store, job.actual_row orelse job.request.instance);
    }
    fn cancelOwned(self: *Core) void {
        self.cancel_requested = true;
        if (self.job) |job| job.cancellation.store(true, .release);
        const services = self.services orelse return;
        if (self.discovery_owned) services.java.cancelSearch();
        if (self.download_token != null) services.java_download.cancel();
        if (self.instance_owned) services.instances.cancel();
    }
    fn fail(self: *Core, err: anyerror) void {
        self.failure = if (err == error.Canceled) null else err;
        self.publication_failure = false;
        self.cancelOwned();
    }
    fn beginCleanup(self: *Core) void {
        const job = self.job orelse return;
        if (job.thread != null or self.discovery_owned or self.download_token != null or self.instance_owned) return;
        self.phase = .cleaning;
    }
    fn selected(self: *const Core, role: JavaRole) !?java_manager.Runtime {
        const services = self.services.?;
        const job = self.job.?;
        const required = if (role == .runtime) job.runtime_major.? else job.installer_major.?;
        const row = job.request.instance;
        if (role == .runtime) if (row.java_path) |path| {
            for (services.java.entries()) |runtime| if (textEqual(runtime.path, path)) {
                if (runtime.major != required) return error.IncompatibleJava;
                try runtime.architecture.requireHost();
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
        if (services.java_download.isDeleting()) return error.JavaDownloadBusy;
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
            const explicit_path = if (role == .runtime) job.request.instance.java_path else null;
            try services.java.search(explicit_path orelse "");
            self.discovery_owned = true;
            self.phase = .discovering_java;
            return;
        }
        if (role == .runtime and job.request.instance.java_path != null) return error.SelectedJavaUnavailable;
        if (services.java_download.isBusy()) return error.JavaDownloadBusy;
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
        try checkNew(services.store, job.request.instance);
        try job.validateProof();
        try self.exactSelection(.runtime, job.runtime_path.?);
        if (job.installer_major != null) try self.exactSelection(.installer, job.installer_path.?);
        const row = job.request.instance;
        const proof = if (job.proof) |*owned| owned else return error.MissingPreparedMetadata;
        switch (proof.*) {
            .vanilla => |*owner| try services.instances.startCreateVanillaPrepared(row, owner, job.request.preparation_generation),
            .loader => |*owner| try services.instances.startCreatePreparedWithJava(row, owner, job.request.preparation_generation, job.installer_path),
        }
        job.instance_task_id = services.instances.snapshot().task_id;
        self.instance_owned = true;
        self.phase = .creating;
    }
    fn captureCreated(self: *Core) !void {
        const job = self.job.?;
        const actual = self.services.?.instances.snapshot().instance orelse return error.MissingCreatedInstance;
        const expected = job.request.instance;
        if (!sameRow(actual, expected)) return error.InstanceConfigurationChanged;
        const owned_row = try clone(config.Instance, job.arena.allocator(), actual);
        job.actual_row = owned_row;
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
        if (core.instance_owned or core.discovery_owned or core.download_token != null) return error.Busy;
        if (core.job) |old| if (old.thread != null or old.task != null) return error.Busy;
        if (request.preparation_generation == 0 or request.preparation_generation <= core.last_generation) return error.StalePreparationGeneration;
        if (core.serial == std.math.maxInt(u64)) return error.IdExhausted;
        // No stale borrowed Store strings survive a successful request admission.
        try core.checkServices(services);
        if (services.store.publicationUncertain()) return error.ConfigPublicationUncertain;
        if (services.instances.isBusy()) return error.InstanceWorkerBusy;
        if (services.java.isSearching()) return error.JavaDiscoveryBusy;
        if (services.java_download.isBusy()) return error.JavaDownloadBusy;
        const row = request.instance;
        if (row.origin != null) return error.InvalidOrdinaryCreation;
        try services.instances.checkCreationAdmission(row);
        if (!config.validId(row.id) or !config.validId(row.name)) return error.UnsafeInstance;
        if (row.id.len > 502) return error.InvalidInstallerKey;
        try metadata.version.validateId(row.minecraft_version);
        try checkEnvironment(request.environment);
        try checkNew(services.store, request.instance);
        const job = try Job.create(core.a, core.io, core.paths.root, request, core.options);
        job.instance_task_id = services.instances.snapshot().task_id;
        errdefer job.destroy();
        const task = try core.registry().create(.game_install, row.name);
        job.task = task;
        job.task_id = task.id;
        errdefer {
            core.registry().finish(task, .{ .failed = error.PreparationNotStarted });
            job.task = null;
        }
        try core.registry().start(task);
        try job.spawn(.prepare);
        if (core.job) |old| old.destroy();
        core.job = job;
        core.services = services;
        core.serial += 1;
        core.last_generation = request.preparation_generation;
        core.phase = .preparing;
        core.failure = null;
        core.cancel_requested = false;
        core.stopping = false;
        core.role = null;
        core.discovered = false;
    }
    pub fn startOrdinary(self: *Controller, row: config.Instance, services: Services) !void {
        if (self.core.last_generation == std.math.maxInt(u64)) return error.IdExhausted;
        try services.instances.checkCreationAdmission(row);
        try self.start(.{ .instance = row, .preparation_generation = self.core.last_generation + 1, .environment = try hostEnvironment() }, services);
    }
    pub fn presentsCreation(self: *const Controller, manager: *const instances_manager.Manager) bool {
        return if (self.core.job) |job| manager.snapshot().task_id == job.instance_task_id else false;
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
        return .{ .phase = core.phase, .failure = core.failure, .preparation_generation = if (job) |j| j.request.preparation_generation else 0, .serial = core.serial, .role = core.role, .runtime_major = if (job) |j| if (j.thread == null) j.runtime_major else null else null, .installer_major = if (job) |j| if (j.thread == null) j.installer_major else null else null, .instance = if (job) |j| j.actual_row orelse j.request.instance else null };
    }
    /// One task identity spans metadata, discovery, JDK download and artifact install.
    /// Borrowed row strings are consumed only within the current UI frame.
    pub fn creationSnapshot(self: *const Controller) instances_manager.Snapshot {
        const core = self.core;
        const job = core.job orelse return .{ .phase = .idle, .operation = .none, .instance = null, .failure = null, .recovery_directory = null, .completed = 0, .total = 0 };
        var result: instances_manager.Snapshot = .{ .phase = switch (core.phase) {
            .idle => .idle,
            .complete => .complete,
            .failed => .failed,
            .canceled => .canceled,
            .awaiting_publication, .awaiting_reconciliation => .awaiting_publication,
            else => .working,
        }, .operation = .creating, .instance = job.actual_row orelse job.request.instance, .failure = core.failure, .recovery_directory = null, .completed = 0, .total = 0, .task_id = job.task_id, .details = if (job.task) |task| task.details() else job.terminal_details };
        if (core.instance_owned) {
            const installed = core.services.?.instances.snapshot();
            result.details = installed.details;
            result.recovery_directory = installed.recovery_directory;
            result.durability_uncertain = installed.durability_uncertain;
        }
        result.completed = @intCast(result.details.completed);
        result.total = @intCast(result.details.total orelse 0);
        return result;
    }
    /// UI finish only. A failed write is retried by an explicit popup action.
    pub fn publishOrdinary(self: *Controller, services: Services, allow_mutations: bool) !void {
        if (!allow_mutations) return error.MutationsDisabled;
        const core = self.core;
        if (core.phase == .awaiting_reconciliation) return self.acknowledgeReconciled(services);
        if (!core.instance_owned or core.phase != .awaiting_publication) return error.NoPendingPublication;
        try core.checkBinding(services, false);
        try core.captureCreated();
        services.instances.publish(services.store) catch |err| {
            core.failure = err;
            core.publication_failure = true;
            if (services.store.publicationUncertain()) core.phase = .awaiting_reconciliation;
            return err;
        };
        core.instance_owned = false;
        core.failure = null;
        core.publication_failure = false;
        core.job.?.task.?.reportDetails(services.instances.snapshot().details);
        core.phase = .cleaning;
    }
    pub fn tick(self: *Controller, services: Services) void {
        self.tickWithMutations(services, true);
    }
    /// Even queued work cannot bypass the root shutdown mutation gate. JOIN and
    /// cancellation continue, but committed pending rows stay owned for teardown.
    pub fn tickWithMutations(self: *Controller, services: Services, allow_mutations: bool) void {
        const core = self.core;
        const job = core.job orelse return;
        if (core.phase == .complete or core.phase == .failed or core.phase == .canceled) return;
        core.checkServices(services) catch |err| {
            core.fail(err);
        };
        const bound = core.services.?;
        if (core.phase != .cleaning and !core.cancel_requested) core.checkBinding(bound, !core.instance_owned and job.actual_row != null) catch |err| {
            core.fail(err);
        };
        if (job.task) |task| if (task.canceled()) core.cancelOwned();
        if (!job.joinReady()) return;
        if (!allow_mutations and !core.cancel_requested) return;
        if (core.phase == .cleaning) {
            const succeeded = job.actual_row != null and !core.cancel_requested and core.failure == null;
            core.phase = if (succeeded) .complete else if (core.failure != null) .failed else .canceled;
            core.finish(if (succeeded) .succeeded else if (core.failure) |err| .{ .failed = err } else .canceled);
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
            if (downloadMatches(token, job.request.preparation_generation, core.serial, core.role, snap.request)) {
                job.task.?.reportDetails(snap.details);
            } else core.fail(error.JavaDownloadOwnershipLost);
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
                if (!allow_mutations) {
                    bound.instances.retainCreationForShutdown() catch |err| {
                        core.failure = err;
                        return;
                    };
                    core.instance_owned = false;
                    core.beginCleanup();
                    return;
                }
                if (core.phase == .awaiting_reconciliation) return;
                core.phase = .awaiting_publication;
                core.captureCreated() catch |err| {
                    core.failure = err;
                    return;
                };
                // Publication belongs to finish after all widgets close.
                return;
            } else {
                core.instance_owned = false;
                core.fail(snap.failure orelse error.InstanceCreationFailed);
            }
        }
        if (job.thread != null) return;
        if (core.cancel_requested) {
            core.beginCleanup();
            return;
        }
        core.checkBinding(bound, job.actual_row != null) catch |err| {
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
            .preparing => core.acquireJava(.runtime) catch |err| {
                core.fail(err);
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
        if (core.cancel_requested) core.beginCleanup() else core.phase = .cleaning;
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
        }
        if (core.job) |job| {
            if (job.thread) |thread| {
                thread.join();
                job.thread = null;
            }
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
    a: A,
    tmp: std.testing.TmpDir,
    root: [:0]const u8,
    paths: paths_mod.Paths,
    registry: tasks.Registry,
    store: config.Store,
    java: java_manager.Manager,
    instances: instances_manager.Manager,
    download: downloads.Controller,
    row: config.Instance = .{ .id = "game", .name = "Display Name", .minecraft_version = "base", .loader = .vanilla, .max_memory_mb = 2048 },
    leased: bool = false,
    metadata_count: usize = 0,
    probe_count: usize = 0,
    create_count: usize = 0,
    probe_major: u32 = 17,
    probe_architecture: @import("../core/java_runtime.zig").Architecture = @import("../core/java_runtime.zig").host(),

    fn init() !*Fixture {
        const a = std.testing.allocator;
        const io = std.testing.io;
        const self = try a.create(Fixture);
        errdefer a.destroy(self);
        self.* = .{ .a = a, .tmp = std.testing.tmpDir(.{}), .root = undefined, .paths = undefined, .registry = tasks.Registry.init(a), .store = undefined, .java = undefined, .instances = undefined, .download = undefined };
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
        // These composed fixtures never dispatch a Java download.
        self.download = .{ .allocator = a, .io = io, .root = self.paths.jdks, .service = undefined, .download_connections = 8, .registry = &self.registry, .own_registry = false, .fixture_transport = null, .fixture_extractor = null, .probe = .{} };
        return self;
    }
    fn deinit(self: *Fixture) void {
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
        return .{ .store = &self.store, .java = &self.java, .java_download = &self.download, .instances = &self.instances };
    }
    fn request(self: *Fixture) !Request {
        return .{ .instance = self.row, .preparation_generation = 9, .environment = try hostEnvironment() };
    }
    fn controller(self: *Fixture) !Controller {
        return Controller.init(self.a, std.testing.io, self.root, .{ .task_registry = &self.registry, .runner = .{ .context = self, .manifest = catalogue, .fetcher = .{ .context = self, .fetch = fetch }, .probe = probe } });
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
    fn catalogue(raw: ?*anyopaque, a: A, _: Io, _: ?*const CancelToken) !metadata.Owned(metadata.manifest.Manifest) {
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
    fn probe(raw: ?*anyopaque, a: A, _: Io, path: []const u8, cancel: ?*const CancelToken) !java_manager.Runtime {
        if (cancel) |value| if (value.load(.acquire)) return error.Canceled;
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        self.probe_count += 1;
        const owned_path = try a.dupe(u8, path);
        errdefer a.free(owned_path);
        return .{ .path = owned_path, .major = self.probe_major, .architecture = self.probe_architecture, .vendor = try a.dupe(u8, "Fixture") };
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
        try self.java.addDownloaded(.{ .path = path, .major = major_number, .architecture = @import("../core/java_runtime.zig").host(), .vendor = "Fixture" });
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
        controller_value.tick(self.services());
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
};
fn fixtureInitAllocation(a: A) !void {
    var value = try Controller.init(a, std.testing.io, "/fixture/root", .{});
    defer value.deinit(undefined);
}

// Replace only the test clock; filesystem and thread operations still use testing.io.
const MetadataBudgetFixture = struct {
    const child_json = "{\"id\":\"base\",\"inheritsFrom\":\"parent\"}";
    const parent_json = "{\"id\":\"parent\",\"mainClass\":\"Main\",\"javaVersion\":{\"component\":\"jre-legacy\",\"majorVersion\":17},\"downloads\":{\"client\":{\"url\":\"https://piston-data.mojang.com/v1/objects/a9993e364706816aba3e25717850c26c9cd0d89d/client.jar\",\"sha1\":\"a9993e364706816aba3e25717850c26c9cd0d89d\",\"size\":3}}}";
    var ms: u64 = 0;
    var fetch_count: usize = 0;
    var cancel_on_parent: bool = false;
    var cancel: ?*CancelToken = null;

    fn now(_: ?*anyopaque, _: Io.Clock) Io.Timestamp {
        return .{ .nanoseconds = @as(i96, ms) * std.time.ns_per_ms };
    }
    fn catalogue(raw: ?*anyopaque, a: A, _: Io, token: ?*const CancelToken) !metadata.Owned(metadata.manifest.Manifest) {
        const fixture: *Fixture = @ptrCast(@alignCast(raw.?));
        fixture.metadata_count += 1;
        ms += 100;
        cancel = @constCast(token.?);
        var child_digest: [20]u8 = undefined;
        var parent_digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(child_json, &child_digest, .{});
        std.crypto.hash.Sha1.hash(parent_json, &parent_digest, .{});
        const bytes = try std.fmt.allocPrint(a, "{{\"latest\":{{\"release\":\"base\",\"snapshot\":\"base\"}},\"versions\":[" ++
            "{{\"id\":\"base\",\"type\":\"release\",\"url\":\"https://piston-meta.mojang.com/v1/packages/fixture/base.json\",\"time\":\"2024-01-01T00:00:00Z\",\"releaseTime\":\"2024-01-01T00:00:00Z\",\"sha1\":\"{s}\"}}," ++
            "{{\"id\":\"parent\",\"type\":\"release\",\"url\":\"https://piston-meta.mojang.com/v1/packages/fixture/parent.json\",\"time\":\"2024-01-01T00:00:00Z\",\"releaseTime\":\"2024-01-01T00:00:00Z\",\"sha1\":\"{s}\"}}]}}", .{ std.fmt.bytesToHex(child_digest, .lower), std.fmt.bytesToHex(parent_digest, .lower) });
        defer a.free(bytes);
        return metadata.manifest.parseSlice(a, bytes);
    }
    fn fetch(_: ?*anyopaque, a: A, _: Io, request: vanilla.Request) ![]u8 {
        fetch_count += 1;
        ms += 100;
        const parent = textEqual(request.id, "parent");
        if (parent and cancel_on_parent) cancel.?.store(true, .release);
        return a.dupe(u8, if (parent) parent_json else child_json);
    }
    fn configure(value: *Controller, vtable: *Io.VTable, budget_ms: u64) void {
        ms = 0;
        fetch_count = 0;
        cancel_on_parent = false;
        cancel = null;
        vtable.* = std.testing.io.vtable.*;
        vtable.now = now;
        value.core.io = .{ .userdata = std.testing.io.userdata, .vtable = vtable };
        value.core.options.metadata_timeout_ms = budget_ms;
        value.core.options.runner.manifest = catalogue;
        value.core.options.runner.fetcher.fetch = fetch;
    }
};

test "metadata budget is shared across manifest and inherited versions" {
    {
        const fixture = try Fixture.init();
        defer fixture.deinit();
        var value = try fixture.controller();
        defer value.deinit(fixture.services());
        var vtable: Io.VTable = undefined;
        MetadataBudgetFixture.configure(&value, &vtable, 300);
        try value.startOrdinary(fixture.row, fixture.services());
        Fixture.joinPrivate(&value);
        const job = value.core.job.?;
        try std.testing.expectEqual(error.DeadlineExceeded, job.failure.?);
        try std.testing.expectEqual(@as(u64, 300), job.metadata_deadline_ms.?);
        try std.testing.expectEqual(@as(usize, 2), MetadataBudgetFixture.fetch_count);
        try std.testing.expect(job.proof == null and job.thread == null);
        for (0..8) |_| fixture.advance(&value);
        try std.testing.expectEqual(Phase.failed, value.snapshot().phase);
        try std.testing.expectEqual(error.DeadlineExceeded, value.snapshot().failure.?);
        const details = value.creationSnapshot().details;
        try std.testing.expectEqualStrings("parent.json", details.files[2].name());
        try std.testing.expectEqual(tasks.FileState.failed, details.files[2].state);
        try std.testing.expectEqual(error.DeadlineExceeded, details.files[2].failure.?);
        try std.testing.expectEqual(@as(u64, MetadataBudgetFixture.child_json.len + MetadataBudgetFixture.parent_json.len), details.received);
        try std.testing.expectEqual(@as(usize, 0), fixture.probe_count);
        try std.testing.expectEqual(@as(usize, 0), fixture.create_count);
        try std.testing.expectEqual(@as(usize, 0), fixture.store.snapshot().instances.len);
        try std.testing.expect(!fixture.registry.hasActive());
    }
}

test "metadata cancellation wins over an expired shared budget" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    var vtable: Io.VTable = undefined;
    MetadataBudgetFixture.configure(&value, &vtable, 300);
    MetadataBudgetFixture.cancel_on_parent = true;
    try value.startOrdinary(fixture.row, fixture.services());
    Fixture.joinPrivate(&value);
    try std.testing.expectEqual(error.Canceled, value.core.job.?.failure.?);
    try std.testing.expectEqual(@as(usize, 2), MetadataBudgetFixture.fetch_count);
    const details = value.creationSnapshot().details;
    try std.testing.expectEqualStrings("parent.json", details.files[2].name());
    try std.testing.expectEqual(tasks.FileState.canceled, details.files[2].state);
    try std.testing.expectEqual(error.Canceled, details.files[2].failure.?);
    try std.testing.expectEqual(@as(u64, MetadataBudgetFixture.child_json.len + MetadataBudgetFixture.parent_json.len), details.received);
    for (0..8) |_| fixture.advance(&value);
    try std.testing.expectEqual(Phase.canceled, value.snapshot().phase);
    try std.testing.expectEqual(@as(usize, 0), fixture.probe_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.create_count);
    try std.testing.expect(!fixture.registry.hasActive());
}

test "metadata HTTP uses remaining absolute budget and finished metadata does not limit Java" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.registerRuntime(17);
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    var vtable: Io.VTable = undefined;
    MetadataBudgetFixture.configure(&value, &vtable, 400);
    try value.startOrdinary(fixture.row, fixture.services());
    Fixture.joinPrivate(&value);
    const job = value.core.job.?;
    try std.testing.expect(job.failure == null and job.proof != null);
    var context: FetchContext = .{ .job = job, .client = null };
    const request = try context.request(metadata.version_manifest_url, 8 * 1024 * 1024);
    try std.testing.expectEqual(@as(u32, 100), request.timeout_ms);
    try std.testing.expectEqual(@as(i96, 400 * std.time.ns_per_ms), request.deadline_ns.?);
    MetadataBudgetFixture.ms = 400;
    try std.testing.expectError(error.DeadlineExceeded, context.request(metadata.version_manifest_url, 8 * 1024 * 1024));
    MetadataBudgetFixture.ms = 100_000;
    try fixture.until(&value, .awaiting_publication);
    try std.testing.expectEqual(@as(usize, 1), fixture.probe_count);
    try std.testing.expectEqual(@as(usize, 1), fixture.create_count);
    try value.publishOrdinary(fixture.services(), true);
    try fixture.until(&value, .complete);
}

test "ordinary creation prepares exact runtime without pack policy or content adoption" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.registerRuntime(21);
    try fixture.registerRuntime(17);
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    try value.startOrdinary(fixture.row, fixture.services());
    const task_id = value.creationSnapshot().task_id.?;
    try std.testing.expect(value.presentsCreation(&fixture.instances));
    try std.testing.expect(!value.ownsInstancesPublication());
    try fixture.until(&value, .awaiting_publication);
    try std.testing.expectEqual(@as(usize, 0), fixture.store.snapshot().instances.len);
    try std.testing.expectEqual(@as(usize, 1), fixture.probe_count);
    try std.testing.expectEqual(task_id, value.creationSnapshot().task_id.?);
    try std.testing.expect(value.creationSnapshot().instance.?.java_path == null);
    try std.testing.expectError(error.MutationsDisabled, value.publishOrdinary(fixture.services(), false));
    try value.publishOrdinary(fixture.services(), true);
    try fixture.until(&value, .complete);
    try std.testing.expectEqual(@as(usize, 1), fixture.create_count);
    try std.testing.expect(fixture.store.snapshot().instances[0].origin == null);
    try fixture.store.reconcile();
    try std.testing.expect(fixture.store.snapshot().instances[0].java_path == null);
    try std.testing.expect(!fixture.leased and !fixture.registry.hasActive());
}

test "ordinary Fabric and Quilt creation uses registered Java 21 without an installer download" {
    const ProfileFixture = struct {
        const base_json = "{\"id\":\"base\",\"mainClass\":\"Main\",\"javaVersion\":{\"component\":\"java-runtime-delta\",\"majorVersion\":21},\"downloads\":{\"client\":{\"url\":\"https://piston-data.mojang.com/v1/objects/a9993e364706816aba3e25717850c26c9cd0d89d/client.jar\",\"sha1\":\"a9993e364706816aba3e25717850c26c9cd0d89d\",\"size\":3}}}";
        const profile_json = "{\"id\":\"profile-loader\",\"inheritsFrom\":\"base\",\"mainClass\":\"loader.Main\",\"libraries\":[]}";
        fn get(_: ?*anyopaque, a: A, url: []const u8, _: usize, control: loaders.Control) !loaders.Response {
            try control.check();
            const content = if (std.mem.endsWith(u8, url, "/versions/loader/base"))
                "[{\"loader\":{\"version\":\"0.16.0\",\"stable\":true}}]"
            else if (std.mem.endsWith(u8, url, "/profile/json"))
                profile_json
            else
                return error.UnexpectedFixtureRequest;
            const bytes = try a.dupe(u8, content);
            errdefer a.free(bytes);
            return .{ .bytes = bytes, .final_url = try a.dupe(u8, url), .status = 200 };
        }
        fn install(raw: ?*anyopaque, a: A, io: Io, request: instances_manager.CreateRequest, control: instances_manager.Control) !instances_manager.Installed {
            try control.check();
            const fixture: *Fixture = @ptrCast(@alignCast(raw.?));
            const proof = request.prepared orelse return error.MissingPreparedMetadata;
            const kind: loaders.Kind = switch (request.instance.loader) {
                .fabric => .fabric,
                .quilt => .quilt,
                else => return error.InvalidLoader,
            };
            try proof.validateBinding(a, io, .{ .root = request.root, .instance_id = request.instance.id, .instance_name = request.instance.name, .generation = request.prepared_generation, .selection = .{ .kind = kind, .base_id = request.instance.minecraft_version, .loader_id = request.instance.loader_version.? }, .environment = try hostEnvironment() });
            try std.testing.expectEqual(@as(u64, 21), proof.requirements.runtime_major);
            try std.testing.expectEqual(@as(u64, 0), proof.requirements.installer_major);
            try std.testing.expect(request.installer_java == null);
            try std.testing.expect(request.instance.java_path == null);
            fixture.create_count += 1;
            try fixture.tmp.dir.createDirPath(io, ".minecraft/versions/Display Name");
            try fixture.tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Display Name/committed.marker", .data = "committed" });
            return instances_manager.Installed.init(a, request.instance);
        }
    };
    for ([_]config.Loader{ .fabric, .quilt }) |kind| {
        const fixture = try Fixture.init();
        defer fixture.deinit();
        fixture.metadata_bytes = ProfileFixture.base_json;
        fixture.probe_major = 21;
        fixture.row.loader = kind;
        fixture.row.loader_version = "0.16.0";
        fixture.instances.installer.?.run = ProfileFixture.install;
        try fixture.registerRuntime(21);
        try std.testing.expect(fixture.java.resolve("unused-installer", 8) == null);
        var value = try fixture.controller();
        defer value.deinit(fixture.services());
        value.core.options.runner.transport = .{ .get = ProfileFixture.get };
        try value.startOrdinary(fixture.row, fixture.services());
        Fixture.joinPrivate(&value);
        const job = value.core.job.?;
        try std.testing.expect(job.failure == null and job.proof != null);
        // Check before advancing: an erroneous installer requirement must fail before discovery.
        try std.testing.expectEqual(@as(?u32, 21), job.runtime_major);
        try std.testing.expect(job.installer_major == null);
        try fixture.until(&value, .awaiting_publication);
        try std.testing.expectEqual(@as(usize, 1), fixture.probe_count);
        try std.testing.expectEqual(@as(usize, 1), fixture.create_count);
        try std.testing.expect(fixture.download.active == null and value.core.download_token == null);
        try std.testing.expect(!value.core.discovered);
        try value.publishOrdinary(fixture.services(), true);
        try fixture.until(&value, .complete);
        try fixture.store.reconcile();
        try std.testing.expect(fixture.store.snapshot().instances[0].java_path == null);
        try std.testing.expect(!fixture.leased and !fixture.registry.hasActive());
    }
}

test "ordinary gate freezes preparation then resumes and explicit shutdown retains committed debt" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.registerRuntime(17);
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    try value.startOrdinary(fixture.row, fixture.services());
    Fixture.joinPrivate(&value);
    value.tickWithMutations(fixture.services(), false);
    try std.testing.expectEqual(Phase.preparing, value.snapshot().phase);
    try std.testing.expect(!value.core.cancel_requested);
    try std.testing.expectEqual(@as(usize, 0), fixture.probe_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.create_count);
    try fixture.until(&value, .awaiting_publication);
    try std.testing.expect(fixture.leased);
    const namespace_token = fixture.instances.pending.?.namespace_token;
    value.cancel(fixture.services());
    value.tickWithMutations(fixture.services(), false);
    try std.testing.expectEqual(Phase.cleaning, value.snapshot().phase);
    value.tickWithMutations(fixture.services(), false);
    try std.testing.expectEqual(Phase.canceled, value.snapshot().phase);
    try std.testing.expect(!value.ownsInstancesPublication());
    try std.testing.expect(!fixture.registry.hasActive());
    try std.testing.expectEqual(@as(usize, 0), fixture.store.snapshot().instances.len);
    try std.testing.expect(fixture.instances.pending != null and fixture.instances.active == null);
    try std.testing.expect(fixture.leased);
    try std.testing.expectEqual(namespace_token, fixture.instances.pending.?.namespace_token);
    try std.testing.expect(fixture.instances.pending.?.prepared == null);
    try std.testing.expect(fixture.instances.pending.?.vanilla_prepared == null);
}

test "ordinary wrong manual Java fails before artifacts and retry receives fresh task generation" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.registerRuntime(21);
    fixture.row.java_path = "/fixture/java-21";
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    try value.startOrdinary(fixture.row, fixture.services());
    const first = value.creationSnapshot().task_id.?;
    for (0..8) |_| fixture.advance(&value);
    try std.testing.expectEqual(Phase.failed, value.snapshot().phase);
    try std.testing.expectEqual(error.IncompatibleJava, value.snapshot().failure.?);
    try std.testing.expectEqual(@as(usize, 0), fixture.create_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.probe_count);
    try fixture.registerRuntime(17);
    fixture.row.java_path = "/fixture/java-17";
    try value.startOrdinary(fixture.row, fixture.services());
    try std.testing.expect(first != value.creationSnapshot().task_id.?);
    try std.testing.expectEqual(@as(u64, 2), value.snapshot().preparation_generation);
    try fixture.until(&value, .awaiting_publication);
    try value.publishOrdinary(fixture.services(), true);
    try fixture.until(&value, .complete);
}

test "ordinary cancellation during metadata joins without starting Java or artifact install" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    try value.startOrdinary(fixture.row, fixture.services());
    value.cancel(fixture.services());
    for (0..8) |_| fixture.advance(&value);
    try std.testing.expectEqual(Phase.canceled, value.snapshot().phase);
    try std.testing.expect(value.core.job.?.thread == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.probe_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.create_count);
    try std.testing.expect(!value.ownsJavaDiscovery() and !value.ownsJavaDownload());
    try std.testing.expect(!fixture.registry.hasActive());
}

test "ordinary coordinator initialization allocation rollback is complete" {
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, fixtureInitAllocation, .{});
}

test "ordinary coordinator full row binding includes runtime memory debug and origin" {
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

test "ordinary coordinator download token binds generation serial role and exact request" {
    const request: downloads.Request = .{ .vendor = .azul, .major = 17 };
    const token: DownloadToken = .{ .generation = 9, .serial = 3, .role = .runtime, .request = request };
    try std.testing.expect(downloadMatches(token, 9, 3, .runtime, request));
    try std.testing.expect(!downloadMatches(token, 10, 3, .runtime, request));
    try std.testing.expect(!downloadMatches(token, 9, 4, .runtime, request));
    try std.testing.expect(!downloadMatches(token, 9, 3, .installer, request));
    try std.testing.expect(!downloadMatches(token, 9, 3, .runtime, null));
    try std.testing.expect(!downloadMatches(token, 9, 3, .runtime, .{ .vendor = .azul, .major = 8 }));
}

test "ordinary coordinator downloaded archive alone never proves a usable registered JVM" {
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

test "ordinary coordinator owned deletion blocks start without preparation tasks or fixture side effects" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    var deleting: @TypeOf(fixture.download.active_delete.?.*) = .{ .io = std.testing.io };
    defer deleting.arena.deinit();
    fixture.download.active_delete = &deleting;
    defer fixture.download.active_delete = null;
    // A retained download completion is deliberately independent of deletion ownership.
    fixture.download.phase = .complete;
    const request = try fixture.request();
    for (0..3) |stage| {
        if (stage == 1) fixture.download.cancel();
        if (stage == 2) deleting.done.store(true, .release);
        try std.testing.expect(fixture.download.isDeleting() and fixture.download.isBusy());
        try std.testing.expectEqual(downloads.Phase.complete, fixture.download.snapshot().phase);
        try std.testing.expectError(error.JavaDownloadBusy, value.start(request, fixture.services()));
        try std.testing.expect(value.core.job == null and value.core.services == null);
        try std.testing.expectEqual(Phase.idle, value.snapshot().phase);
        try std.testing.expectEqual(@as(u64, 0), value.core.last_generation);
        try std.testing.expectEqual(@as(u64, 0), value.core.serial);
        try std.testing.expectEqual(@as(usize, 0), fixture.registry.tasks().len);
        try std.testing.expectEqual(@as(usize, 0), fixture.metadata_count);
        try std.testing.expectEqual(@as(usize, 0), fixture.probe_count);
        try std.testing.expectEqual(@as(usize, 0), fixture.create_count);
        try std.testing.expect(!fixture.leased);
    }
    fixture.download.active_delete = null;
    try value.start(request, fixture.services());
    try std.testing.expectEqual(Phase.preparing, value.snapshot().phase);
    try std.testing.expectEqual(request.preparation_generation, value.core.last_generation);
}

test "ordinary coordinator registered Java cannot resolve or probe while deletion stays owned" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.registerRuntime(17);
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    try value.start(try fixture.request(), fixture.services());
    Fixture.joinPrivate(&value);
    // Publish the prepared proof locally without advancing to Java acquisition.
    const job = value.core.job.?;
    try std.testing.expect(job.proof != null and job.thread == null);
    try std.testing.expect((try value.core.selected(.runtime)) != null);
    const task_count = fixture.registry.tasks().len;
    const metadata_requests = fixture.metadata_count;
    var deleting: @TypeOf(fixture.download.active_delete.?.*) = .{ .io = std.testing.io };
    defer deleting.arena.deinit();
    fixture.download.active_delete = &deleting;
    defer fixture.download.active_delete = null;
    for (0..3) |stage| {
        if (stage == 1) fixture.download.cancel();
        if (stage == 2) deleting.done.store(true, .release);
        try std.testing.expectError(error.JavaDownloadBusy, value.core.acquireJava(.runtime));
        try std.testing.expect(value.core.role == null);
        try std.testing.expectEqual(Phase.preparing, value.snapshot().phase);
        try std.testing.expect(job.thread == null and job.probe_major == 0);
        try std.testing.expectEqual(@as(usize, 0), job.probe_path.len);
        try std.testing.expectEqual(@as(usize, 0), fixture.probe_count);
        try std.testing.expectEqual(@as(usize, 0), fixture.create_count);
        try std.testing.expectEqual(task_count, fixture.registry.tasks().len);
        try std.testing.expectEqual(metadata_requests, fixture.metadata_count);
        try std.testing.expect(!fixture.java.isSearching() and !value.ownsJavaDownload());
    }
    fixture.download.active_delete = null;
    try value.core.acquireJava(.runtime);
    try std.testing.expectEqual(Phase.probing_java, value.snapshot().phase);
    Fixture.joinPrivate(&value);
    try std.testing.expectEqual(@as(usize, 1), fixture.probe_count);
}

test "ordinary coordinator worker spawn rollback releases task ownership" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    value.core.options.fixture_spawn_failure = error.FixtureSpawnFailure;
    try std.testing.expectError(error.FixtureSpawnFailure, value.start(try fixture.request(), fixture.services()));
    try std.testing.expect(value.core.job == null);
}

test "ordinary coordinator selected incompatible runtime never falls back or downloads" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.registerRuntime(17);
    try fixture.registerRuntime(21);
    try fixture.java.choose(fixture.row.name, "/fixture/java-21", 21);
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    try value.start(try fixture.request(), fixture.services());
    Fixture.joinPrivate(&value);
    value.tick(fixture.services());
    value.tick(fixture.services());
    try std.testing.expectEqual(Phase.failed, value.snapshot().phase);
    try std.testing.expectEqual(error.IncompatibleJava, value.snapshot().failure.?);
    try std.testing.expectEqual(@as(usize, 0), fixture.probe_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.create_count);
    try std.testing.expect(!value.ownsJavaDownload());
}

test "ordinary coordinator fresh probe rejects a registered JVM whose actual major changed" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.registerRuntime(17);
    fixture.probe_major = 8;
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    try value.start(try fixture.request(), fixture.services());
    fixture.advance(&value);
    fixture.advance(&value);
    fixture.advance(&value);
    try std.testing.expectEqual(Phase.failed, value.snapshot().phase);
    try std.testing.expectEqual(error.JavaMajorMismatch, value.snapshot().failure.?);
    try std.testing.expectEqual(@as(usize, 1), fixture.probe_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.create_count);
}

test "ordinary coordinator shutdown joins create clears borrowed proof but preserves pending lease debt" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.registerRuntime(17);
    var value = try fixture.controller();
    var live = true;
    defer if (live) value.deinit(fixture.services());
    try value.start(try fixture.request(), fixture.services());
    try fixture.until(&value, .creating);
    fixture.joinInstance();
    value.deinit(fixture.services());
    live = false;
    try std.testing.expect(fixture.instances.pending != null);
    try std.testing.expect(fixture.instances.pending.?.vanilla_prepared == null);
    try std.testing.expect(fixture.instances.pending.?.prepared == null);
    try std.testing.expect(fixture.leased);
    try std.testing.expectEqual(@as(usize, 0), fixture.store.snapshot().instances.len);
}

test "ordinary coordinator Java roles resolve independent exact-major selections" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.registerRuntime(17);
    try fixture.registerRuntime(8);
    try fixture.java.choose(fixture.row.name, "/fixture/java-17", 17);
    try fixture.java.choose("game:installer", "/fixture/java-8", 8);
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    try value.start(try fixture.request(), fixture.services());
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

test "ordinary coordinator clone copies error values while retaining deep container ownership" {
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

test "ordinary coordinator failed trusted metadata leaves proof null through join and cleanup" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.metadata_bytes = "{\"id\":\"base\",\"javaVersion\":{\"majorVersion\":17}}";
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    try value.start(try fixture.request(), fixture.services());
    Fixture.joinPrivate(&value);
    const job = value.core.job.?;
    try std.testing.expect(job.proof == null);
    try std.testing.expect(job.failure.? == error.MissingField);
    value.tick(fixture.services());
    value.tick(fixture.services());
    try std.testing.expectEqual(Phase.failed, value.snapshot().phase);
    try std.testing.expect(value.snapshot().failure.? == error.MissingField);
    try std.testing.expect(job.proof == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.probe_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.create_count);
    const details = value.creationSnapshot().details;
    try std.testing.expectEqual(@as(u64, fixture.metadata_bytes.len), details.received);
    try std.testing.expectEqual(tasks.FileState.complete, details.files[1].state);
    try std.testing.expect(details.files[1].failure == null);
    fixture.registry.pruneFinished(0);
    try std.testing.expectEqualDeep(details, value.creationSnapshot().details);
}

const AutoJavaFixture = struct {
    entered: CancelToken = .init(false),
    release_download: CancelToken = .init(false),
    fail_extract: bool = false,

    fn initialize(self: *AutoJavaFixture, fixture: *Fixture) !void {
        fixture.download = try downloads.Controller.initWithOptions(fixture.a, std.testing.io, .{
            .root = fixture.root,
            .task_registry = &fixture.registry,
            .transport = .{ .context = self, .get = get, .download = download },
            .extractor = .{ .context = self, .extract = extract },
            .probe = .{ .run = probe },
        });
    }
    fn start(self: *AutoJavaFixture, fixture: *Fixture, value: *Controller) !void {
        value.core.options.java_vendor = .microsoft;
        try value.startOrdinary(fixture.row, fixture.services());
        Fixture.joinPrivate(value);
        // Discovery found no runtime; exercise the ordinary auto-download admission.
        value.core.discovered = true;
        try value.core.acquireJava(.runtime);
        for (0..1500) |_| {
            if (self.entered.load(.acquire)) return;
            try std.testing.io.sleep(.fromMilliseconds(2), .awake);
        }
        return error.FixtureTimedOut;
    }
    fn get(_: *anyopaque, a: A, _: []const u8, _: usize, hooks: java_backend.Hooks) ![]u8 {
        try hooks.check();
        const platform = try downloads.hostPlatform();
        const os = if (platform.os == .macos) "macOS" else @tagName(platform.os);
        return std.fmt.allocPrint(a, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  microsoft-jdk-17.0.1-{s}-{s}.{s}", .{ os, @tagName(platform.arch), if (platform.archive() == .zip) "zip" else "tar.gz" });
    }
    fn download(raw: *anyopaque, io: Io, _: *const java_backend.RuntimeRelease, path: []const u8, hooks: java_backend.Hooks) !void {
        const self: *AutoJavaFixture = @ptrCast(@alignCast(raw));
        const file = try Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
        defer file.close(io);
        try file.writeStreamingAll(io, "abc");
        hooks.progress.?(hooks.context, .{ .phase = .downloading, .received = 3, .total = 3, .bytes_per_second = 3072 });
        self.entered.store(true, .release);
        while (!self.release_download.load(.acquire)) {
            try hooks.check();
            try io.sleep(.fromMilliseconds(2), .awake);
        }
    }
    fn extract(raw: *anyopaque, a: A, io: Io, format: java_backend.Archive, _: []const u8, dest: []const u8, hooks: java_backend.Hooks) ![]u8 {
        const self: *AutoJavaFixture = @ptrCast(@alignCast(raw));
        try hooks.check();
        if (self.fail_extract) return error.UnsupportedDirectoryLink;
        const dir = try Io.Dir.cwd().openDir(io, dest, .{});
        defer dir.close(io);
        try dir.createDir(io, "bin", .default_dir);
        const relative = if (format == .zip) "bin/java.exe" else "bin/java";
        const file = try dir.createFile(io, relative, .{ .permissions = .executable_file });
        defer file.close(io);
        try file.writeStreamingAll(io, "inert fixture");
        return a.dupe(u8, relative);
    }
    fn probe(_: ?*anyopaque, a: A, _: Io, path: []const u8, _: ?*const CancelToken) !java_manager.Runtime {
        const owned_path = try a.dupe(u8, path);
        errdefer a.free(owned_path);
        return .{ .path = owned_path, .major = 17, .architecture = @import("../core/java_runtime.zig").host(), .vendor = try a.dupe(u8, "Microsoft") };
    }
    fn joinDownload(fixture: *Fixture) void {
        if (fixture.download.active) |job| if (job.thread) |thread| {
            thread.join();
            job.thread = null;
        };
    }
};

test "ordinary auto Java forwards full live details and completes creation" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var download_fixture: AutoJavaFixture = .{};
    try download_fixture.initialize(fixture);
    defer fixture.download.deinit();
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    try download_fixture.start(fixture, &value);
    const child = fixture.download.active.?.task.?;
    var details = child.details();
    details.omitted_files = 2;
    details.addFile(.{ .received = 2, .total = 3, .bytes_per_second = 1024, .state = .downloading });
    child.reportDetails(details);
    value.tick(fixture.services());
    const parent = value.core.job.?.task.?;
    try std.testing.expectEqualDeep(child.details(), parent.details());
    try std.testing.expectEqualDeep(parent.details(), value.creationSnapshot().details);
    try std.testing.expectEqual(tasks.Stage.downloading, parent.details().stage);
    try std.testing.expectEqual(@as(f64, 3072), parent.details().bytes_per_second);
    download_fixture.release_download.store(true, .release);
    AutoJavaFixture.joinDownload(fixture);
    try fixture.until(&value, .awaiting_publication);
    try value.publishOrdinary(fixture.services(), true);
    try fixture.until(&value, .complete);
    try std.testing.expectEqual(tasks.State.succeeded, parent.state);
    const terminal = fixture.download.snapshot().details;
    try std.testing.expectEqual(@as(u64, 3), terminal.received);
    try std.testing.expectEqual(@as(?u64, 3), terminal.total_bytes);
    try std.testing.expectEqual(@as(f64, 0), terminal.bytes_per_second);
    try std.testing.expectEqual(@as(f64, 0), terminal.files[0].bytes_per_second);
    fixture.registry.pruneFinished(0);
    try std.testing.expectEqualDeep(terminal, fixture.download.snapshot().details);
}

test "ordinary auto Java extraction failure retains received history and stopped terminal details" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var download_fixture: AutoJavaFixture = .{ .fail_extract = true };
    try download_fixture.initialize(fixture);
    defer fixture.download.deinit();
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    try download_fixture.start(fixture, &value);
    value.tick(fixture.services());
    const parent = value.core.job.?.task.?;
    try std.testing.expectEqual(@as(f64, 3072), parent.details().bytes_per_second);
    download_fixture.release_download.store(true, .release);
    AutoJavaFixture.joinDownload(fixture);
    value.tick(fixture.services());
    value.tick(fixture.services());
    try std.testing.expectEqual(Phase.failed, value.snapshot().phase);
    try std.testing.expectEqual(error.UnsupportedDirectoryLink, value.snapshot().failure.?);
    try std.testing.expectEqual(tasks.State.failed, parent.state);
    try std.testing.expectEqual(error.UnsupportedDirectoryLink, parent.failure.?);
    const details = value.creationSnapshot().details;
    try std.testing.expectEqual(tasks.Stage.extracting, details.stage);
    try std.testing.expectEqual(@as(u64, 3), details.received);
    try std.testing.expectEqual(@as(?u64, 3), details.total_bytes);
    try std.testing.expectEqual(@as(f64, 0), details.bytes_per_second);
    try std.testing.expectEqualDeep(fixture.download.snapshot().details, details);
    try std.testing.expectEqualDeep(parent.details(), details);
    try std.testing.expectEqual(@as(usize, 0), fixture.create_count);
    try std.testing.expect(!fixture.registry.hasActive());
    fixture.registry.pruneFinished(0);
    try std.testing.expectEqualDeep(details, value.creationSnapshot().details);
    try std.testing.expectEqualDeep(details, fixture.download.snapshot().details);
}

test "ordinary stale Java ownership never copies unrelated download details" {
    for (0..5) |mismatch| {
        const fixture = try Fixture.init();
        defer fixture.deinit();
        var download_fixture: AutoJavaFixture = .{};
        try download_fixture.initialize(fixture);
        defer fixture.download.deinit();
        var value = try fixture.controller();
        defer value.deinit(fixture.services());
        try download_fixture.start(fixture, &value);
        const parent = value.core.job.?.task.?;
        const previous: tasks.Details = .{ .stage = .scanning, .completed = 7, .received = 11 };
        parent.reportDetails(previous);
        switch (mismatch) {
            0 => value.core.download_token.?.generation += 1,
            1 => value.core.download_token.?.serial += 1,
            2 => value.core.role = .installer,
            3 => value.core.download_token.?.request.vendor = .azul,
            4 => value.core.download_token.?.request.major = 21,
            else => unreachable,
        }
        // Before and after tick, presentation must use the same owned parent publication.
        try std.testing.expectEqualDeep(previous, value.creationSnapshot().details);
        value.tick(fixture.services());
        try std.testing.expectEqual(error.JavaDownloadOwnershipLost, value.snapshot().failure.?);
        try std.testing.expectEqualDeep(previous, parent.details());
        try std.testing.expectEqualDeep(previous, value.creationSnapshot().details);
        AutoJavaFixture.joinDownload(fixture);
        value.tick(fixture.services());
        value.tick(fixture.services());
        try std.testing.expectEqual(Phase.failed, value.snapshot().phase);
        try std.testing.expectEqualDeep(previous, value.creationSnapshot().details);
    }
}

test "ordinary fetched metadata checksum failure retains named measured bytes after join and prune" {
    const WrongBody = struct {
        const bytes = "corrupt fetched metadata";
        value: *Controller,
        called: bool = false,

        fn fetch(raw: ?*anyopaque, a: A, _: Io, request: vanilla.Request) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            var approved: metadata.Sha1 = undefined;
            std.crypto.hash.Sha1.hash(Fixture.version_json, &approved, .{});
            try std.testing.expectEqualDeep(approved, request.sha1.?);
            const details = self.value.creationSnapshot().details;
            const file = details.files[details.file_count - 1];
            try std.testing.expectEqual(tasks.Stage.metadata, details.stage);
            try std.testing.expectEqualStrings("base.json", file.name());
            try std.testing.expectEqual(tasks.FileState.downloading, file.state);
            try std.testing.expectEqual(@as(?u64, null), file.total);
            try std.testing.expectEqual(@as(u64, 0), file.received);
            self.called = true;
            return a.dupe(u8, bytes);
        }
        fn unexpected(_: ?*anyopaque, _: A, _: []const u8, _: usize, _: loaders.Control) !loaders.Response {
            return error.UnexpectedLoaderRequest;
        }
    };
    for ([_]config.Loader{ .vanilla, .fabric }) |kind| {
        const fixture = try Fixture.init();
        defer fixture.deinit();
        fixture.row.loader = kind;
        if (kind == .fabric) fixture.row.loader_version = "0.18.5";
        // Freeze the approved manifest's source bytes; the fetcher returns a separate body.
        fixture.metadata_bytes = Fixture.version_json;
        var value = try fixture.controller();
        defer value.deinit(fixture.services());
        var wrong: WrongBody = .{ .value = &value };
        value.core.options.runner.fetcher = .{ .context = &wrong, .fetch = WrongBody.fetch };
        value.core.options.runner.transport = .{ .get = WrongBody.unexpected };
        try value.startOrdinary(fixture.row, fixture.services());
        Fixture.joinPrivate(&value);
        try std.testing.expect(wrong.called);
        try std.testing.expect(value.core.job.?.proof == null);
        try std.testing.expectEqual(error.ChecksumMismatch, value.core.job.?.failure.?);
        const before = value.creationSnapshot().details;
        try std.testing.expectEqual(tasks.Stage.metadata, before.stage);
        try std.testing.expectEqual(@as(u64, WrongBody.bytes.len), before.received);
        try std.testing.expectEqual(@as(?u64, WrongBody.bytes.len), before.total_bytes);
        try std.testing.expectEqual(@as(usize, 2), before.file_count);
        const file = before.files[1];
        try std.testing.expectEqualStrings("base.json", file.name());
        try std.testing.expectEqualStrings("https://piston-meta.mojang.com/v1/packages/fixture/base.json", file.path());
        try std.testing.expectEqual(@as(u64, WrongBody.bytes.len), file.received);
        try std.testing.expectEqual(@as(?u64, WrongBody.bytes.len), file.total);
        try std.testing.expectEqual(tasks.FileState.failed, file.state);
        try std.testing.expectEqual(error.ChecksumMismatch, file.failure.?);
        try std.testing.expectEqual(@as(f64, 0), before.bytes_per_second);
        try std.testing.expectEqual(@as(f64, 0), file.bytes_per_second);
        for (0..8) |_| fixture.advance(&value);
        try std.testing.expectEqual(Phase.failed, value.snapshot().phase);
        try std.testing.expectEqualDeep(before, value.creationSnapshot().details);
        try std.testing.expectEqual(@as(usize, 0), fixture.probe_count);
        try std.testing.expectEqual(@as(usize, 0), fixture.create_count);
        try std.testing.expectEqual(@as(usize, 0), fixture.store.snapshot().instances.len);
        try std.testing.expect(!fixture.registry.hasActive());
        fixture.registry.pruneFinished(0);
        try std.testing.expectEqualDeep(before, value.creationSnapshot().details);
    }
}

test "ordinary inherited metadata beyond file cap retains the failed request and aggregate bytes" {
    const Graph = struct {
        const ids = [_][]const u8{ "base", "p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8" };
        const wrong_body = "corrupt parent metadata";
        manifest_bytes: []const u8,
        documents: [ids.len][]const u8 = @splat(""),
        fetched: usize = 0,
        received: u64 = 0,

        fn catalogue(raw: ?*anyopaque, a: A, _: Io, _: ?*const CancelToken) !metadata.Owned(metadata.manifest.Manifest) {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return metadata.manifest.parseSlice(a, self.manifest_bytes);
        }
        fn fetch(raw: ?*anyopaque, a: A, _: Io, request: vanilla.Request) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const index = self.fetched;
            try std.testing.expectEqualStrings(ids[index], request.id);
            const body = if (index == ids.len - 1) wrong_body else self.documents[index];
            self.fetched += 1;
            self.received += body.len;
            return a.dupe(u8, body);
        }
    };
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const a = fixture.a;
    var graph: Graph = .{ .manifest_bytes = undefined };
    defer for (graph.documents) |doc| if (doc.len != 0) a.free(doc);
    var manifest_bytes: std.ArrayList(u8) = .empty;
    defer manifest_bytes.deinit(a);
    try manifest_bytes.appendSlice(a, "{\"latest\":{\"release\":\"base\",\"snapshot\":\"base\"},\"versions\":[");
    for (Graph.ids, 0..) |id, i| {
        graph.documents[i] = if (i + 1 < Graph.ids.len)
            try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"inheritsFrom\":\"{s}\"}}", .{ id, Graph.ids[i + 1] })
        else
            try std.fmt.allocPrint(a, "{{\"id\":\"{s}\"}}", .{id});
        var digest: metadata.Sha1 = undefined;
        std.crypto.hash.Sha1.hash(graph.documents[i], &digest, .{});
        const entry = try std.fmt.allocPrint(a, "{s}{{\"id\":\"{s}\",\"type\":\"release\",\"url\":\"https://piston-meta.mojang.com/v1/packages/fixture/{s}.json\",\"time\":\"2024-01-01T00:00:00Z\",\"releaseTime\":\"2024-01-01T00:00:00Z\",\"sha1\":\"{s}\"}}", .{ if (i == 0) "" else ",", id, id, std.fmt.bytesToHex(digest, .lower) });
        defer a.free(entry);
        try manifest_bytes.appendSlice(a, entry);
    }
    try manifest_bytes.appendSlice(a, "]}");
    graph.manifest_bytes = manifest_bytes.items;
    var value = try fixture.controller();
    defer value.deinit(fixture.services());
    value.core.options.runner.context = &graph;
    value.core.options.runner.manifest = Graph.catalogue;
    value.core.options.runner.fetcher = .{ .context = &graph, .fetch = Graph.fetch };
    try value.startOrdinary(fixture.row, fixture.services());
    Fixture.joinPrivate(&value);
    try std.testing.expectEqual(error.ChecksumMismatch, value.core.job.?.failure.?);
    try std.testing.expectEqual(Graph.ids.len, graph.fetched);
    const details = value.creationSnapshot().details;
    try std.testing.expectEqual(@as(usize, 8), details.file_count);
    try std.testing.expectEqual(@as(usize, 2), details.omitted_files);
    try std.testing.expectEqual(graph.received, details.received);
    try std.testing.expectEqual(@as(?u64, graph.received), details.total_bytes);
    try std.testing.expectEqualStrings("p8.json", details.files[7].name());
    try std.testing.expectEqual(tasks.FileState.failed, details.files[7].state);
    try std.testing.expectEqual(error.ChecksumMismatch, details.files[7].failure.?);
    try std.testing.expectEqual(@as(u64, Graph.wrong_body.len), details.files[7].received);
    for (details.files[0..7]) |file| try std.testing.expectEqual(tasks.FileState.complete, file.state);
    for (0..8) |_| fixture.advance(&value);
    try std.testing.expectEqual(Phase.failed, value.snapshot().phase);
    try std.testing.expectEqual(@as(usize, 0), fixture.probe_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.create_count);
    fixture.registry.pruneFinished(0);
    try std.testing.expectEqualDeep(details, value.creationSnapshot().details);
}

test "creation rejects foreign selected and re-probed JVM architectures before install" {
    const architecture = @import("../core/java_runtime.zig");
    const foreign: architecture.Architecture = if (architecture.host() == .aarch64) .x86_64 else .aarch64;
    for ([_]bool{ false, true }) |cached_foreign| {
        const fixture = try Fixture.init();
        defer fixture.deinit();
        try fixture.registerRuntime(17);
        if (cached_foreign) {
            var runtime = fixture.java.entries()[0];
            runtime.architecture = foreign;
            try fixture.java.addDownloaded(runtime);
        } else fixture.probe_architecture = foreign;
        var value = try fixture.controller();
        defer value.deinit(fixture.services());
        var row = fixture.row;
        row.java_path = fixture.java.entries()[0].path;
        try value.startOrdinary(row, fixture.services());
        for (0..8) |_| fixture.advance(&value);
        try std.testing.expectEqual(Phase.failed, value.snapshot().phase);
        try std.testing.expectEqual(error.JavaArchitectureMismatch, value.snapshot().failure.?);
        try std.testing.expectEqual(@as(usize, if (cached_foreign) 0 else 1), fixture.probe_count);
        try std.testing.expectEqual(@as(usize, 0), fixture.create_count);
        try std.testing.expectEqual(@as(usize, 0), fixture.store.snapshot().instances.len);
        try std.testing.expect(!fixture.registry.hasActive());
    }
}

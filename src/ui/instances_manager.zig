//! UI-thread owner; workers own requests, filesystem results and cancellation.
//! Publication belongs to the parent finish hook, after every widget is closed.
const std = @import("std");
const config = @import("../core/config.zig");
const instances = @import("../core/instances.zig");
const tasks = @import("../core/tasks.zig");
const worlds = @import("../core/worlds.zig");
const namespace = @import("../core/instance_namespace.zig");
const transactions = @import("../core/instance_transactions.zig");
const content = @import("../core/content_install.zig");
const loader_install = @import("../core/loaders/install.zig");
const loader_base_install = @import("../core/loaders/base_install.zig");
const metadata_loader = @import("../core/minecraft/metadata_loader.zig");
const A = std.mem.Allocator;
const Io = std.Io;

pub const Phase = enum { idle, working, awaiting_publication, complete, failed, canceled };
pub const Operation = enum { none, creating, renaming, deleting, loading_loaders };
pub const Snapshot = struct {
    phase: Phase,
    operation: Operation,
    instance: ?config.Instance,
    failure: ?anyerror,
    recovery_directory: ?[]const u8,
    completed: usize,
    total: usize,
    local_client_verified: bool = false,
    durability_uncertain: bool = false,
    task_id: ?u64 = null,
    details: tasks.Details = .{},
};
/// Empty when the loader catalogue supplies no publication timestamp.
pub const LoaderEntry = struct { id: []const u8, stable: bool = true, release_time: []const u8 = "" };
pub const LoaderSnapshot = struct {
    phase: Phase,
    base: ?[]const u8,
    kind: config.Loader,
    entries: []const LoaderEntry,
    failure: ?anyerror,
};
pub const CreateRequest = struct {
    root: []const u8,
    instance: config.Instance,
    lease: content.Lease,
    namespace_token: ?namespace.Token = null,
    download_connections: u16 = 8,
    installer_java: ?[]const u8 = null,
    /// Borrowed immutable owner (including matcher context), only until worker JOIN.
    prepared: ?*const loader_install.PreparedMetadata = null,
    vanilla_prepared: ?*const metadata_loader.PreparedVanilla = null,
    prepared_generation: u64 = 0,
};
pub const Control = struct {
    cancel: *const std.atomic.Value(bool),
    task: ?*tasks.Task = null,
    /// Immutable manager-owned root, frozen for the lifetime of the worker.
    cache_root: ?[]const u8 = null,
    pub fn check(self: Control) !void {
        if (self.cancel.load(.acquire)) return error.Canceled;
    }
    pub fn report(self: Control, stage: tasks.Stage, completed: usize, total: ?usize) void {
        if (self.task) |task| task.report(stage, @intCast(completed), if (total) |n| @intCast(n) else null);
    }
};
pub const Installed = struct {
    arena: std.heap.ArenaAllocator,
    instance: config.Instance,
    durability_uncertain: bool = false,
    pub fn init(a: A, instance: config.Instance) !Installed {
        var result: Installed = .{ .arena = .init(a), .instance = instance };
        errdefer result.arena.deinit();
        result.instance = try cloneInstance(result.arena.allocator(), instance);
        return result;
    }
    pub fn deinit(self: *Installed) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub const LoaderCatalogue = struct {
    arena: std.heap.ArenaAllocator,
    base: []const u8,
    kind: config.Loader,
    entries: []const LoaderEntry,
    pub fn clone(self: LoaderCatalogue, a: A) !LoaderCatalogue {
        var arena: std.heap.ArenaAllocator = .init(a);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const entries = try owned.alloc(LoaderEntry, self.entries.len);
        for (self.entries, entries) |entry, *dest| dest.* = .{ .id = try owned.dupe(u8, entry.id), .stable = entry.stable, .release_time = try owned.dupe(u8, entry.release_time) };
        const base = try owned.dupe(u8, self.base);
        return .{ .arena = arena, .base = base, .kind = self.kind, .entries = entries };
    }
    pub fn deinit(self: *LoaderCatalogue) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
/// UI-thread admission for creation only; context must outlive the manager.
pub const CreationAdmission = struct {
    context: ?*anyopaque = null,
    check: *const fn (?*anyopaque) anyerror!void,
};
pub const Installer = struct {
    context: ?*anyopaque = null,
    run: *const fn (?*anyopaque, A, Io, CreateRequest, Control) anyerror!Installed,
};
pub const VanillaPreparationAdapter = struct {
    context: ?*anyopaque = null,
    prepare: *const fn (?*anyopaque, A, Io, metadata_loader.VanillaTarget, Control) anyerror!metadata_loader.PreparedVanilla = productionPrepareVanilla,
};
pub const CatalogueAdapter = struct {
    context: ?*anyopaque = null,
    fetch: *const fn (?*anyopaque, A, Io, []const u8, config.Loader, Control) anyerror!LoaderCatalogue,
};

/// Optional clock injection is UI-thread only; its context outlives the manager.
pub const CacheClock = struct {
    context: ?*anyopaque = null,
    now_ms: *const fn (?*anyopaque, Io) u64 = cacheMilliseconds,
};
pub const Options = struct {
    cache_root: ?[]const u8 = null,
    cache_clock: CacheClock = .{},
};
const loader_cache_capacity = 8;
const loader_cache_ttl_ms = 5 * 60 * 1000;
const LoaderCacheEntry = struct { catalogue: LoaderCatalogue, valid_until_ms: u64 };
fn cacheMilliseconds(_: ?*anyopaque, io: Io) u64 {
    return @intCast(@max(0, @divFloor(Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms)));
}

pub fn cloneInstance(a: A, source: config.Instance) !config.Instance {
    var result = source;
    result.id = try a.dupe(u8, source.id);
    errdefer a.free(result.id);
    result.name = try a.dupe(u8, source.name);
    errdefer a.free(result.name);
    result.minecraft_version = try a.dupe(u8, source.minecraft_version);
    errdefer a.free(result.minecraft_version);
    result.loader_version = if (source.loader_version) |s| try a.dupe(u8, s) else null;
    errdefer if (result.loader_version) |s| a.free(s);
    result.java_path = if (source.java_path) |s| try a.dupe(u8, s) else null;
    errdefer if (result.java_path) |s| a.free(s);
    if (source.origin) |origin| {
        const project = try a.dupe(u8, origin.project_id);
        errdefer a.free(project);
        result.origin = .{ .kind = origin.kind, .project_id = project, .version_id = try a.dupe(u8, origin.version_id) };
    }
    return result;
}
fn sameOptional(a: ?[]const u8, b: ?[]const u8) bool {
    return if (a) |x| if (b) |y| std.mem.eql(u8, x, y) else false else b == null;
}
fn sameIdentity(a: config.Instance, b: config.Instance) bool {
    if (!std.mem.eql(u8, a.id, b.id) or !std.mem.eql(u8, a.name, b.name) or !std.mem.eql(u8, a.minecraft_version, b.minecraft_version) or a.loader != b.loader or !sameOptional(a.loader_version, b.loader_version)) return false;
    if (a.origin) |x| {
        const y = b.origin orelse return false;
        return x.kind == y.kind and std.mem.eql(u8, x.project_id, y.project_id) and std.mem.eql(u8, x.version_id, y.version_id);
    }
    return b.origin == null;
}
pub fn sameInstance(a: config.Instance, b: config.Instance) bool {
    return sameIdentity(a, b) and sameOptional(a.java_path, b.java_path) and a.min_memory_mb == b.min_memory_mb and a.max_memory_mb == b.max_memory_mb and a.debug_launch == b.debug_launch;
}
fn validateRequest(instance: config.Instance) !void {
    if (!config.validId(instance.id)) return error.InvalidId;
    if (!config.validId(instance.name)) return error.InvalidInstanceName;
    if (instance.minecraft_version.len == 0 or instance.minecraft_version.len > 200 or !std.unicode.utf8ValidateSlice(instance.minecraft_version)) return error.InvalidMinecraftVersion;
    if (instance.java_path) |path| if (path.len == 0 or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null or !std.unicode.utf8ValidateSlice(path)) return error.InvalidJavaPath;
    if (instance.min_memory_mb) |mb| if (mb < 256 or mb > 1024 * 1024) return error.InvalidMemory;
    if (instance.max_memory_mb) |mb| if (mb < 256 or mb > 1024 * 1024) return error.InvalidMemory;
    if (instance.min_memory_mb) |minimum| {
        if (instance.max_memory_mb) |maximum| if (minimum > maximum) return error.InvalidMemory;
    }
    if (instance.loader != .vanilla and (instance.loader_version == null or instance.loader_version.?.len == 0)) return error.InvalidLoaderVersion;
}

const Job = struct {
    allocator: A,
    arena: std.heap.ArenaAllocator,
    io: Io,
    root: []const u8,
    operation: Operation,
    request: config.Instance,
    new_name: ?[]const u8 = null,
    /// Owned before worker launch; apply options to the committed rename result.
    renamed_options: ?config.Instance = null,
    guard: worlds.Guard,
    lease: content.Lease,
    worker_recheck: ?*const fn (?*anyopaque, []const u8) anyerror!void = null,
    leased: bool = false,
    namespace_token: ?namespace.Token = null,
    installer: ?Installer,
    catalogue_adapter: ?CatalogueAdapter,
    cache_root: ?[]const u8 = null,
    loader_generation: u64 = 0,
    download_connections: u16,
    installer_java: ?[]const u8 = null,
    prepared: ?*const loader_install.PreparedMetadata = null,
    vanilla_prepared: ?*const metadata_loader.PreparedVanilla = null,
    prepared_generation: u64 = 0,
    task: ?*tasks.Task = null,
    task_id: ?u64 = null,
    terminal_details: tasks.Details = .{},
    cancellation: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    future: ?Io.Future(void) = null,
    result: ?transactions.Result = null,
    installed: ?Installed = null,
    catalogue: ?LoaderCatalogue = null,
    uncertain_publication_store: ?*const config.Store = null,
    /// Owned server IDs removed by this job's uncertain delete publication.
    deleted_server_ids: ?[]const []const u8 = null,
    failure: ?anyerror = null,

    fn flag(self: *Job) *const std.atomic.Value(bool) {
        return if (self.task) |task| &task.cancellation else &self.cancellation;
    }
    fn value(self: *const Job) config.Instance {
        if (self.result) |result| return result.instance;
        if (self.installed) |result| return result.instance;
        return self.request;
    }
    fn work(self: *Job) void {
        defer self.done.store(true, .release);
        self.perform() catch |err| {
            self.failure = err;
        };
    }
    fn perform(self: *Job) !void {
        const a = std.heap.page_allocator;
        const control: Control = .{ .cancel = self.flag(), .task = self.task, .cache_root = self.cache_root };
        try control.check();
        // Workers use the frozen waiting checker; the owner lease stays nonblocking.
        var worker_lease = self.lease;
        worker_lease.recheck = self.worker_recheck orelse self.lease.recheck;
        const options: transactions.Options = .{ .cancel = self.flag(), .guard = .{ .running_ids = self.guard.running_ids }, .lease = .{ .context = worker_lease.context, .recheck = worker_lease.recheck }, .namespace_token = self.namespace_token, .worker_checks = true };
        switch (self.operation) {
            .renaming => {
                control.report(.backing_up, 0, null);
                self.result = try transactions.rename(a, self.io, self.root, self.request, self.new_name.?, options);
                if (self.renamed_options) |edited| {
                    self.result.?.instance.java_path = edited.java_path;
                    self.result.?.instance.min_memory_mb = edited.min_memory_mb;
                    self.result.?.instance.max_memory_mb = edited.max_memory_mb;
                    self.result.?.instance.debug_launch = edited.debug_launch;
                }
            },
            .deleting => {
                control.report(.finalizing, 0, null);
                self.result = try transactions.remove(a, self.io, self.root, self.request, options);
            },
            .creating => {
                const adapter = self.installer orelse return error.InstallAdapterUnavailable;
                self.installed = try adapter.run(adapter.context, a, self.io, .{ .root = self.root, .instance = self.request, .lease = worker_lease, .namespace_token = self.namespace_token, .download_connections = self.download_connections, .installer_java = self.installer_java, .prepared = self.prepared, .vanilla_prepared = self.vanilla_prepared, .prepared_generation = self.prepared_generation }, control);
                // Adapter success is a committed transaction: a late token cannot undo it.
            },
            .loading_loaders => {
                const adapter = self.catalogue_adapter orelse return error.LoaderCatalogueUnavailable;
                self.catalogue = try adapter.fetch(adapter.context, a, self.io, self.request.minecraft_version, self.request.loader, control);
                try control.check();
            },
            .none => unreachable,
        }
    }
    fn destroy(self: *Job) void {
        if (self.result) |*result| result.deinit();
        if (self.installed) |*result| result.deinit();
        if (self.catalogue) |*result| result.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

pub const Manager = struct {
    allocator: A,
    io: Io,
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    registry: *tasks.Registry,
    guard: worlds.Guard,
    lease: content.Lease,
    worker_recheck: ?*const fn (?*anyopaque, []const u8) anyerror!void = null,
    installer: ?Installer = null,
    creation_admission: ?CreationAdmission = null,
    download_connections: u16 = 8,
    default_java: ?[]const u8 = null,
    operation: Operation = .none,
    catalogue_adapter: ?CatalogueAdapter = null,
    cache_root: ?[]const u8 = null,
    cache_clock: CacheClock = .{},
    loader_generation: u64 = 0,
    loader_cache: [loader_cache_capacity]?LoaderCacheEntry = @splat(null),
    loader_cache_next: usize = 0,
    active: ?*Job = null,
    pending: ?*Job = null,
    published: ?*Job = null,
    loader_data: ?*Job = null,
    phase: Phase = .idle,
    loader_phase: Phase = .idle,
    failure: ?anyerror = null,
    loader_failure: ?anyerror = null,

    /// Registry, lease/guard contexts and Io outlive this manager and all workers.
    pub fn init(a: A, io: Io, paths: *const instances.Paths, registry: *tasks.Registry, guard: worlds.Guard, lease: content.Lease) !Manager {
        return initWithOptions(a, io, paths, registry, guard, lease, .{});
    }
    pub fn initWithOptions(a: A, io: Io, paths: *const instances.Paths, registry: *tasks.Registry, guard: worlds.Guard, lease: content.Lease, options: Options) !Manager {
        var arena: std.heap.ArenaAllocator = .init(a);
        errdefer arena.deinit();
        const g = arena.allocator();
        var owned_guard = guard;
        const ids = try g.alloc([]const u8, guard.running_ids.len);
        for (ids, guard.running_ids) |*target, source| target.* = try g.dupe(u8, source);
        owned_guard.running_ids = ids;
        const owned_root = try g.dupe(u8, paths.root);
        const cache_root = if (options.cache_root) |root| try g.dupe(u8, root) else null;
        return .{ .allocator = a, .io = io, .arena = arena, .root = owned_root, .cache_root = cache_root, .cache_clock = options.cache_clock, .registry = registry, .guard = owned_guard, .lease = lease };
    }
    /// Optional worker checker uses the owner lease context and is frozen per job.
    pub fn setWorkerRecheck(self: *Manager, recheck: ?*const fn (?*anyopaque, []const u8) anyerror!void) void {
        self.worker_recheck = recheck;
    }
    pub fn setCreationAdmission(self: *Manager, admission: CreationAdmission) void {
        self.creation_admission = admission;
    }
    /// Read-only admission before metadata/Java acquisition. Prepared create repeats
    /// this gate immediately before acquiring its filesystem reservations.
    pub fn checkCreationAdmission(self: *const Manager, instance: config.Instance) !void {
        if (self.isBusy()) return error.Busy;
        if (self.installer == null) return error.InstallAdapterUnavailable;
        try validateRequest(instance);
        if (self.creation_admission) |admission| try admission.check(admission.context);
    }
    pub fn setInstaller(self: *Manager, adapter: Installer) void {
        self.installer = adapter;
    }
    pub fn setLoaderCatalogue(self: *Manager, adapter: CatalogueAdapter) void {
        self.loader_generation +%= 1;
        self.clearLoaderCache();
        self.catalogue_adapter = adapter;
    }
    fn clearLoaderCache(self: *Manager) void {
        for (&self.loader_cache) |*slot| {
            if (slot.*) |*entry| entry.catalogue.deinit();
            slot.* = null;
        }
        self.loader_cache_next = 0;
    }
    pub fn setDownloadConnections(self: *Manager, connections: u16) void {
        std.debug.assert(connections > 0 and connections <= 64);
        self.download_connections = connections;
    }
    pub fn setDefaultJava(self: *Manager, path: ?[]const u8) !void {
        if (sameOptional(self.default_java, path)) return;
        if (path) |value| if (value.len == 0 or value.len > 4096 or std.mem.indexOfScalar(u8, value, 0) != null or !std.unicode.utf8ValidateSlice(value)) return error.InvalidJavaPath;
        const owned = if (path) |value| try self.allocator.dupe(u8, value) else null;
        if (self.default_java) |old| self.allocator.free(old);
        self.default_java = owned;
    }
    pub fn isBusy(self: *const Manager) bool {
        return self.active != null or self.pending != null;
    }
    pub fn deinit(self: *Manager) void {
        if (self.active) |job| {
            self.cancel();
            if (job.future) |*future| future.cancel(self.io);
            job.future = null;
            job.prepared = null;
            job.vanilla_prepared = null;
            job.prepared_generation = 0;
            self.finishTask(job, if (job.failure) |err| (if (err == error.Canceled) .canceled else .{ .failed = err }) else if (job.operation == .loading_loaders) .succeeded else .{ .failed = error.ConfigurationNotPublished });
            self.release(job);
            job.destroy();
        }
        if (self.pending) |job| {
            self.finishTask(job, .{ .failed = error.ConfigurationNotPublished });
            self.release(job);
            job.destroy();
        }
        if (self.published) |job| job.destroy();
        if (self.loader_data) |job| job.destroy();
        self.clearLoaderCache();
        if (self.default_java) |path| self.allocator.free(path);
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn cancel(self: *Manager) void {
        if (self.active) |job| {
            job.cancellation.store(true, .release);
            if (job.task) |task| _ = self.registry.cancel(task.id);
        }
        // A committed pending result stays owned and must be published.
    }
    /// Join only the active worker; committed results and recovery debt stay owned.
    /// Borrowed prepared owners may be released after this returns.
    pub fn cancelAndJoin(self: *Manager) void {
        const job = self.active orelse return;
        self.cancel();
        if (job.future) |*future| future.cancel(self.io);
        job.future = null;
        self.tick();
    }
    pub fn startCreate(self: *Manager, instance: config.Instance) !void {
        if (self.installer == null) return error.InstallAdapterUnavailable;
        try self.start(.creating, instance, null);
    }
    /// Loader-only prepared create. The caller retains prepared and all borrowed
    /// matcher context unchanged until tick joins (active == null), or deinit returns.
    /// Success, cancellation, and failure all require JOIN before owner teardown.
    pub fn startCreatePrepared(self: *Manager, instance: config.Instance, prepared: *const loader_install.PreparedMetadata, generation: u64) !void {
        if (self.installer == null) return error.InstallAdapterUnavailable;
        try self.startWithPrepared(.creating, instance, null, prepared, null, generation, false, null, null);
    }
    /// Same prepared-owner JOIN contract, but installer_java is exact: null disables
    /// fallback to both instance runtime Java and the Manager default. Path is cloned.
    pub fn startCreatePreparedWithJava(self: *Manager, instance: config.Instance, prepared: *const loader_install.PreparedMetadata, generation: u64, installer_java: ?[]const u8) !void {
        if (self.installer == null) return error.InstallAdapterUnavailable;
        try self.startWithPrepared(.creating, instance, null, prepared, null, generation, true, installer_java, null);
    }
    /// Borrow immutable vanilla metadata and matcher context until tick JOIN
    /// (active == null), or until deinit returns. Never transfers owner teardown.
    pub fn startCreateVanillaPrepared(self: *Manager, instance: config.Instance, prepared: *const metadata_loader.PreparedVanilla, generation: u64) !void {
        if (self.installer == null) return error.InstallAdapterUnavailable;
        try self.startWithPrepared(.creating, instance, null, null, prepared, generation, true, null, null);
    }
    pub fn startRename(self: *Manager, instance: config.Instance, new_name: []const u8) !void {
        if (!config.validId(new_name)) return error.InvalidInstanceName;
        if (std.ascii.eqlIgnoreCase(instance.name, new_name)) return error.InstanceNameUnchanged;
        try self.start(.renaming, instance, new_name);
    }
    /// Rename and launch options publish together; request remains the stale-check baseline.
    pub fn startRenameWithOptions(self: *Manager, original: config.Instance, updated: config.Instance) !void {
        try validateRequest(updated);
        var identity = updated;
        identity.name = original.name;
        if (!sameIdentity(original, identity)) return error.OptionsCannotChangeIdentity;
        if (std.ascii.eqlIgnoreCase(original.name, updated.name)) return error.InstanceNameUnchanged;
        try self.startWithPrepared(.renaming, original, updated.name, null, null, 0, false, null, updated);
    }
    pub fn startDelete(self: *Manager, instance: config.Instance) !void {
        try self.start(.deleting, instance, null);
    }
    pub fn loadLoaders(self: *Manager, base: []const u8, kind: config.Loader) !void {
        try self.loadLoadersInner(base, kind, false);
    }
    /// Explicit retry bypasses the in-memory success cache, but retains HTTP validators.
    pub fn refreshLoaders(self: *Manager, base: []const u8, kind: config.Loader) !void {
        try self.loadLoadersInner(base, kind, true);
    }
    fn loadLoadersInner(self: *Manager, base: []const u8, kind: config.Loader, force: bool) !void {
        if (kind == .vanilla) return error.InvalidLoader;
        if (self.catalogue_adapter == null) return error.LoaderCatalogueUnavailable;
        if (self.isBusy()) return error.Busy;
        const request: config.Instance = .{ .id = "catalogue", .name = "catalogue", .minecraft_version = base, .loader = kind, .loader_version = "catalogue" };
        try validateRequest(request);
        const now = self.cache_clock.now_ms(self.cache_clock.context, self.io);
        for (&self.loader_cache) |*slot| {
            const entry = if (slot.*) |*value| value else continue;
            if (entry.catalogue.kind != kind or !std.mem.eql(u8, entry.catalogue.base, base)) continue;
            if (now >= entry.valid_until_ms) {
                entry.catalogue.deinit();
                slot.* = null;
                break;
            }
            if (force) break;
            const job = try self.allocator.create(Job);
            job.* = .{ .allocator = self.allocator, .arena = .init(self.allocator), .io = self.io, .root = self.root, .operation = .loading_loaders, .request = request, .guard = self.guard, .lease = self.lease, .installer = null, .catalogue_adapter = null, .download_connections = self.download_connections, .done = .init(true) };
            errdefer job.destroy();
            job.catalogue = try entry.catalogue.clone(self.allocator);
            job.request.minecraft_version = job.catalogue.?.base;
            self.loader_generation +%= 1;
            job.loader_generation = self.loader_generation;
            if (self.loader_data) |old| old.destroy();
            self.loader_data = job;
            self.loader_phase = .complete;
            self.loader_failure = null;
            self.phase = .complete;
            self.failure = null;
            self.operation = .loading_loaders;
            return;
        }
        try self.start(.loading_loaders, request, null);
    }
    fn rememberCatalogue(self: *Manager, catalogue: LoaderCatalogue) !void {
        const owned = try catalogue.clone(self.allocator);
        var index = self.loader_cache_next;
        for (self.loader_cache, 0..) |slot, i| {
            if (slot) |entry| {
                if (entry.catalogue.kind == catalogue.kind and std.mem.eql(u8, entry.catalogue.base, catalogue.base)) {
                    index = i;
                    break;
                }
            }
        }
        if (self.loader_cache[index]) |*entry| entry.catalogue.deinit();
        self.loader_cache[index] = .{ .catalogue = owned, .valid_until_ms = self.cache_clock.now_ms(self.cache_clock.context, self.io) +| loader_cache_ttl_ms };
        self.loader_cache_next = (index + 1) % self.loader_cache.len;
    }
    fn start(self: *Manager, operation: Operation, instance: config.Instance, new_name: ?[]const u8) !void {
        try self.startWithPrepared(operation, instance, new_name, null, null, 0, false, null, null);
    }
    fn startWithPrepared(self: *Manager, operation: Operation, instance: config.Instance, new_name: ?[]const u8, prepared: ?*const loader_install.PreparedMetadata, vanilla_prepared: ?*const metadata_loader.PreparedVanilla, generation: u64, explicit_java: bool, installer_java: ?[]const u8, renamed_options: ?config.Instance) !void {
        if (self.isBusy()) return error.Busy;
        if (operation == .creating) if (self.creation_admission) |admission| try admission.check(admission.context);
        try validateRequest(instance);
        if (prepared != null and vanilla_prepared != null) return error.ConflictingPreparedMetadata;
        const namespace_token = if (operation != .loading_loaders) try namespace.acquire(self.io) else null;
        errdefer if (namespace_token) |token| token.release();
        if (prepared) |owner| {
            const target = try metadataTarget(self.root, instance, generation, try environment());
            try owner.validateBinding(self.allocator, self.io, target);
        }
        if (vanilla_prepared) |owner| {
            const target = try vanillaTarget(self.root, instance, generation, try environment());
            try owner.validateBinding(self.allocator, self.io, target);
        }
        const job = try self.allocator.create(Job);
        job.* = .{ .allocator = self.allocator, .arena = .init(self.allocator), .io = self.io, .root = self.root, .operation = operation, .request = instance, .guard = self.guard, .lease = self.lease, .worker_recheck = self.worker_recheck, .namespace_token = namespace_token, .installer = self.installer, .catalogue_adapter = self.catalogue_adapter, .download_connections = self.download_connections, .prepared = prepared, .vanilla_prepared = vanilla_prepared, .prepared_generation = generation };
        errdefer job.destroy();
        job.request = try cloneInstance(job.arena.allocator(), instance);
        const java_snapshot = if (explicit_java) installer_java else instance.java_path orelse self.default_java;
        if (java_snapshot) |java| {
            if (java.len == 0 or java.len > 4096 or std.mem.indexOfScalar(u8, java, 0) != null or !std.unicode.utf8ValidateSlice(java)) return error.InvalidJavaPath;
            job.installer_java = try job.arena.allocator().dupe(u8, java);
        }
        if (new_name) |name| job.new_name = try job.arena.allocator().dupe(u8, name);
        if (renamed_options) |edited| job.renamed_options = try cloneInstance(job.arena.allocator(), edited);
        if (operation != .loading_loaders) {
            try self.lease.acquire(self.lease.context, job.request.id);
            job.leased = true;
        }
        errdefer self.release(job);
        const title = try std.fmt.allocPrint(job.arena.allocator(), "{s}: {s}", .{ @tagName(operation), instance.name });
        job.task = try self.registry.create(.game_install, title);
        job.task_id = job.task.?.id;
        self.startTaskJob(job) catch |err| {
            self.finishTask(job, .{ .failed = err });
            return err;
        };
    }

    fn startTaskJob(self: *Manager, job: *Job) !void {
        const operation = job.operation;
        try self.registry.start(job.task.?);
        if (operation == .loading_loaders) {
            self.loader_generation +%= 1;
            job.loader_generation = self.loader_generation;
            job.cache_root = self.cache_root;
        }
        job.future = try self.io.concurrent(Job.work, .{job});
        self.active = job;
        self.failure = null;
        self.phase = .working;
        self.operation = operation;
        if (operation == .loading_loaders) {
            self.loader_phase = .working;
            self.loader_failure = null;
        }
    }
    pub fn tick(self: *Manager) void {
        const job = self.active orelse return;
        if (!job.done.load(.acquire)) return;
        if (job.future) |*future| future.await(self.io);
        job.future = null;
        job.prepared = null;
        job.vanilla_prepared = null;
        job.prepared_generation = 0;
        self.active = null;
        if (job.operation == .loading_loaders) {
            // Results may only enter the snapshot/cache after JOIN and exact binding.
            if (job.failure == null) {
                if (job.cancellation.load(.acquire) or job.flag().load(.acquire) or job.loader_generation != self.loader_generation) {
                    job.failure = error.Canceled;
                } else if (job.catalogue) |catalogue| {
                    if (catalogue.kind != job.request.loader or !std.mem.eql(u8, catalogue.base, job.request.minecraft_version)) job.failure = error.LoaderCatalogueMismatch;
                } else job.failure = error.LoaderCatalogueUnavailable;
            }
            if (job.failure == null) self.rememberCatalogue(job.catalogue.?) catch {};
            self.loader_failure = job.failure;
            self.loader_phase = if (job.failure) |err| (if (err == error.Canceled) .canceled else .failed) else .complete;
            self.finishTask(job, if (job.failure) |err| (if (err == error.Canceled) .canceled else .{ .failed = err }) else .succeeded);
            if (self.loader_data) |old| old.destroy();
            self.loader_data = job;
            self.phase = self.loader_phase;
            self.failure = job.failure;
        } else if (job.failure) |err| {
            self.phase = if (err == error.Canceled) .canceled else .failed;
            self.failure = err;
            self.finishTask(job, if (err == error.Canceled) .canceled else .{ .failed = err });
            if (err == error.RecoveryRequired or err == error.PermanentDeletionIncomplete) {
                self.pending = job;
            } else {
                self.release(job);
                if (self.published) |old| old.destroy();
                self.published = job;
            }
        } else {
            self.pending = job;
            self.phase = .awaiting_publication;
            if (job.task) |task| {
                const progress = task.progress();
                task.report(.finalizing, progress.completed, progress.total);
            }
        }
    }
    fn finishTask(self: *Manager, job: *Job, outcome: tasks.Outcome) void {
        if (job.task) |task| {
            self.registry.finish(task, outcome);
            job.terminal_details = task.details();
        }
        job.task = null;
    }
    fn release(self: *Manager, job: *Job) void {
        // Close all filesystem evidence before releasing either reservation.
        if (job.result) |*result| result.releasePublicationProof();
        if (job.namespace_token) |token| token.release();
        job.namespace_token = null;
        if (job.leased) {
            self.lease.release(self.lease.context, job.request.id);
            job.leased = false;
        }
    }
    pub fn snapshot(self: *const Manager) Snapshot {
        const job = if (self.operation == .loading_loaders) self.active orelse self.loader_data else self.active orelse self.pending orelse self.published;
        const details: tasks.Details = if (job) |j| if (j.task) |task| task.details() else j.terminal_details else .{};
        const completed: usize = @intCast(details.completed);
        const total: usize = @intCast(details.total orelse 0);
        // Worker result fields are not published until tick has joined the future.
        const settled = if (self.active == null) job else null;
        return .{ .phase = self.phase, .operation = self.operation, .instance = if (job) |j| (if (j.operation == .loading_loaders) null else if (self.active != null) j.request else j.value()) else null, .failure = self.failure, .recovery_directory = if (settled) |j| if (j.result) |r| r.recovery_directory else null else null, .completed = completed, .total = total, .task_id = if (job) |j| j.task_id else null, .details = details, .durability_uncertain = if (settled) |j| if (j.result) |r| r.durability_uncertain else if (j.installed) |installed| installed.durability_uncertain else false else false, .local_client_verified = self.phase == .complete and (if (settled) |j| if (j.result) |r| r.local_client_verified else false else false) };
    }
    pub fn loaderSnapshot(self: *const Manager) LoaderSnapshot {
        const job = if (self.active) |j| (if (j.operation == .loading_loaders) j else self.loader_data) else self.loader_data;
        return .{ .phase = self.loader_phase, .base = if (job) |j| j.request.minecraft_version else null, .kind = if (job) |j| j.request.loader else .vanilla, .entries = if (self.loader_phase == .complete and job != null and job.?.catalogue != null) job.?.catalogue.?.entries else &.{}, .failure = self.loader_failure };
    }
    /// No widget may retain Store strings when calling this function.
    /// An uncertain publication binds its pending job to this Store. Its address
    /// and root must remain stable, and it must outlive acknowledgment or teardown.
    pub fn publish(self: *Manager, store: *config.Store) !void {
        self.publishInner(store) catch |err| {
            self.failure = err;
            return err;
        };
        self.completePublication(self.pending.?);
    }
    /// No-dispatch shutdown accounting after JOIN. Keep committed filesystem
    /// evidence, reservations and pending row owned until deinit; never writes Store.
    pub fn retainCreationForShutdown(self: *Manager) !void {
        if (self.active != null) return error.Busy;
        const job = self.pending orelse return error.NoPendingPublication;
        if (job.operation != .creating) return error.InvalidAction;
        self.finishTask(job, .{ .failed = error.ConfigurationNotPublished });
    }
    /// Only creation may acknowledge an already reconciled exact result.
    /// Never reconciles or writes config. Missing evidence, a different Store/root,
    /// uncertainty, an unjoined worker, or a changed row/lease retain the pending job.
    pub fn acknowledgeReconciledCreation(self: *Manager, store: *const config.Store) !void {
        const job = try self.pendingPublication();
        if (job.operation != .creating) return error.UnsupportedPublicationAcknowledgment;
        const bound = job.uncertain_publication_store orelse return error.NoOwnedPublicationUncertainty;
        if (bound != store) return error.ConfigurationStoreChanged;
        try self.checkPublicationStore(job, store);
        if (store.publicationUncertain()) return error.ConfigPublicationUncertain;
        if (job.installed == null) return error.InvalidCompletedPublication;
        const value = job.value();
        if (!std.mem.eql(u8, value.id, job.request.id)) return error.InvalidCompletedPublication;
        var matches: usize = 0;
        for (store.snapshot().instances) |entry| {
            if (!std.mem.eql(u8, entry.id, job.request.id)) continue;
            if (!sameInstance(entry, value)) return error.InstanceConfigurationChanged;
            matches += 1;
        }
        if (matches != 1) return error.InstanceConfigurationChanged;
        if (!job.leased) return error.PublicationLeaseLost;
        try self.lease.recheck(self.lease.context, job.request.id);
        const token = job.namespace_token orelse return error.PublicationLeaseLost;
        try token.recheck();
        if (job.result) |*result| result.recheckPublication(self.root) catch |err| {
            self.failure = err;
            return err;
        };
        self.completePublication(job);
    }
    fn pendingPublication(self: *const Manager) !*Job {
        const job = self.pending orelse return error.NoPendingPublication;
        if (self.active != null or !job.done.load(.acquire) or job.future != null) return error.PublicationWorkerNotJoined;
        if (job.failure) |err| return err;
        return job;
    }
    fn checkPublicationStore(self: *const Manager, job: *const Job, store: *const config.Store) !void {
        if (!std.mem.eql(u8, self.root, store.root) or !std.mem.eql(u8, job.root, store.root)) return error.ConfigurationStoreChanged;
        if (job.uncertain_publication_store) |bound| {
            if (bound != store) return error.ConfigurationStoreChanged;
        }
    }
    fn completePublication(self: *Manager, job: *Job) void {
        if (job.result) |*result| result.releasePublicationProof();
        self.pending = null;
        self.phase = .complete;
        self.failure = null;
        self.finishTask(job, .succeeded);
        self.release(job);
        if (self.published) |old| old.destroy();
        self.published = job;
    }
    fn publishInner(self: *Manager, store: *config.Store) !void {
        const job = try self.pendingPublication();
        try self.checkPublicationStore(job, store);
        if (store.publicationUncertain()) return error.ConfigPublicationUncertain;
        if (!job.leased) return error.PublicationLeaseLost;
        try self.lease.recheck(self.lease.context, job.request.id);
        const token = job.namespace_token orelse return error.PublicationLeaseLost;
        try token.recheck();
        if (job.result) |*result| try result.recheckPublication(self.root);
        const doc = store.snapshot();
        if (try self.reconciledDeletion(job, doc)) return;
        var updated = doc.*;
        const a = self.allocator;
        var entries: std.ArrayList(config.Instance) = .empty;
        defer entries.deinit(a);
        var found = false;
        for (doc.instances) |entry| {
            if (std.mem.eql(u8, entry.id, job.request.id)) {
                found = true;
                if (job.operation == .creating) return error.DuplicateId;
                if (!sameInstance(entry, job.request)) return error.InstanceConfigurationChanged;
                if (job.operation != .deleting) try entries.append(a, job.value());
            } else try entries.append(a, entry);
        }
        if (job.operation == .creating) {
            try entries.append(a, job.value());
            updated.selected_instance = job.value().id;
            updated.selected_server = null;
        } else if (!found) return error.InstanceConfigurationChanged;
        updated.instances = entries.items;
        var servers: std.ArrayList(config.Server) = .empty;
        defer servers.deinit(a);
        if (job.operation == .deleting) {
            for (doc.servers) |server| {
                if (std.mem.eql(u8, server.instance_id, job.request.id)) {
                    if (sameOptional(updated.selected_server, server.id)) updated.selected_server = null;
                } else try servers.append(a, server);
            }
            updated.servers = servers.items;
            if (sameOptional(updated.selected_instance, job.request.id)) updated.selected_instance = null;
        }
        try self.lease.recheck(self.lease.context, job.request.id);
        try token.recheck();
        if (job.result) |*result| try result.recheckPublication(self.root);
        // Prepare the deletion witness before Store.update can commit. Only a save
        // failure with publication uncertainty transfers this witness to the job.
        var deleted_server_ids: ?[]const []const u8 = null;
        if (job.operation == .deleting) {
            var count: usize = 0;
            for (doc.servers) |server| if (std.mem.eql(u8, server.instance_id, job.request.id)) {
                count += 1;
            };
            const ids = try job.arena.allocator().alloc([]const u8, count);
            var index: usize = 0;
            for (doc.servers) |server| if (std.mem.eql(u8, server.instance_id, job.request.id)) {
                ids[index] = try job.arena.allocator().dupe(u8, server.id);
                index += 1;
            };
            deleted_server_ids = ids;
        }
        store.update(updated) catch |err| {
            if (store.publicationUncertain()) {
                if (job.operation == .creating or job.operation == .deleting) job.uncertain_publication_store = store;
                if (job.operation == .deleting) job.deleted_server_ids = deleted_server_ids;
            }
            return err;
        };
    }
    /// A retry may acknowledge only this job's own reconciled deletion effect.
    /// The original row still present means the ordinary guarded save must retry.
    /// No Store writes: unrelated edits in the latest authoritative document survive.
    fn reconciledDeletion(self: *const Manager, job: *const Job, doc: *const config.Document) !bool {
        _ = self;
        if (job.operation != .deleting or job.uncertain_publication_store == null) return false;
        const removed_ids = job.deleted_server_ids orelse return error.InvalidCompletedPublication;
        const result = job.result orelse return error.InvalidCompletedPublication;
        if (result.operation != .deleted or !sameInstance(result.instance, job.request) or result.recovery_directory != null) return error.InvalidCompletedPublication;
        for (doc.instances) |entry| if (std.mem.eql(u8, entry.id, job.request.id)) return false;
        if (sameOptional(doc.selected_instance, job.request.id)) return error.InstanceConfigurationChanged;
        for (doc.servers) |server| {
            if (std.mem.eql(u8, server.instance_id, job.request.id)) return error.InstanceConfigurationChanged;
            for (removed_ids) |id| if (std.mem.eql(u8, server.id, id)) return error.InstanceConfigurationChanged;
        }
        for (removed_ids) |id| if (sameOptional(doc.selected_server, id)) return error.InstanceConfigurationChanged;
        return true;
    }
    pub fn saveOptions(self: *Manager, store: *config.Store, updated: config.Instance) !void {
        try self.saveOptionsInner(store, null, updated);
    }
    /// Reject external edits against the form's owned baseline before publication.
    pub fn saveOptionsChecked(self: *Manager, store: *config.Store, original: config.Instance, updated: config.Instance) !void {
        try self.saveOptionsInner(store, original, updated);
    }
    fn saveOptionsInner(self: *Manager, store: *config.Store, original: ?config.Instance, updated: config.Instance) !void {
        if (self.isBusy()) return error.Busy;
        if (store.publicationUncertain()) return error.ConfigPublicationUncertain;
        try validateRequest(updated);
        const doc = store.snapshot();
        const entries = try self.allocator.dupe(config.Instance, doc.instances);
        defer self.allocator.free(entries);
        var found = false;
        for (entries) |*entry| if (std.mem.eql(u8, entry.id, updated.id)) {
            if (!sameIdentity(entry.*, updated)) return error.OptionsCannotChangeIdentity;
            if (original) |baseline| if (!sameInstance(entry.*, baseline)) return error.InstanceConfigurationChanged;
            entry.* = updated;
            found = true;
            break;
        };
        if (!found) return error.InstanceNotFound;
        try self.lease.acquire(self.lease.context, updated.id);
        defer self.lease.release(self.lease.context, updated.id);
        try self.lease.recheck(self.lease.context, updated.id);
        var document = doc.*;
        document.instances = entries;
        try store.update(document);
    }
    pub fn select(_: *Manager, store: *config.Store, id: []const u8) !void {
        var doc = store.snapshot().*;
        for (doc.instances) |instance| if (std.mem.eql(u8, instance.id, id)) {
            doc.selected_instance = instance.id;
            doc.selected_server = null;
            try store.update(doc);
            return;
        };
        return error.InstanceNotFound;
    }
};

/// Explicitly opt into official production downloads; injected fixtures need no curl graph.
pub fn productionInstaller() Installer {
    return .{ .run = productionRun };
}
pub fn productionLoaderCatalogue() CatalogueAdapter {
    return .{ .fetch = productionCatalogue };
}

fn vanillaTarget(root: []const u8, instance: config.Instance, generation: u64, env: @import("../core/minecraft/metadata/root.zig").rules.Environment) !metadata_loader.VanillaTarget {
    if (instance.loader != .vanilla) return error.InvalidLoader;
    return .{ .root = root, .instance_id = instance.id, .instance_name = instance.name, .version_id = instance.minecraft_version, .generation = generation, .environment = env };
}
fn metadataTarget(root: []const u8, instance: config.Instance, generation: u64, env: @import("../core/minecraft/metadata/root.zig").rules.Environment) !loader_install.MetadataTarget {
    const kind: @import("../core/loaders/root.zig").Kind = switch (instance.loader) {
        .fabric => .fabric,
        .forge => .forge,
        .neoforge => .neoforge,
        .quilt => .quilt,
        .vanilla => return error.InvalidLoader,
    };
    return .{ .root = root, .instance_id = instance.id, .instance_name = instance.name, .generation = generation, .selection = .{ .kind = kind, .base_id = instance.minecraft_version, .loader_id = instance.loader_version orelse return error.InvalidLoaderVersion }, .environment = env };
}
/// Read-only authenticated preparation for registered-instance preflight.
/// Fetches only the bounded official manifest; local version JSON is never replaced.
pub fn prepareExistingVanilla(a: A, io: Io, target: metadata_loader.VanillaTarget, control: Control) !metadata_loader.PreparedVanilla {
    return productionPrepareVanilla(null, a, io, target, control);
}

pub fn existingVanillaTarget(root: []const u8, instance: config.Instance, generation: u64) !metadata_loader.VanillaTarget {
    return vanillaTarget(root, instance, generation, try environment());
}

fn productionPrepareVanilla(_: ?*anyopaque, a: A, io: Io, target: metadata_loader.VanillaTarget, control: Control) !metadata_loader.PreparedVanilla {
    const http = @import("../core/http_transport.zig");
    const metadata = @import("../core/minecraft/metadata/root.zig");
    try control.check();
    var client = try http.Client.init(a, io, .{});
    defer client.deinit();
    var observer: @import("../core/install/download_details.zig").HttpObserver = .{ .task = control.task, .path = metadata.version_manifest_url };
    return prepareVanillaInner(a, io, target, control, &client, &observer) catch |err| {
        observer.fail(err);
        return err;
    };
}

fn prepareVanillaInner(a: A, io: Io, target: metadata_loader.VanillaTarget, control: Control, client: *@import("../core/http_transport.zig").Client, observer: *@import("../core/install/download_details.zig").HttpObserver) !metadata_loader.PreparedVanilla {
    const metadata = @import("../core/minecraft/metadata/root.zig");
    var response = try client.execute(.{ .url = metadata.version_manifest_url, .cancel = control.cancel, .max_response_bytes = 16 * 1024 * 1024, .require_public_address = true, .observer = if (control.task != null) observer.observer() else null });
    defer response.deinit();
    try control.check();
    if (response.status != 200) return error.MetadataHttpFailure;
    var manifest = try metadata.manifest.parseSlice(a, response.body);
    defer manifest.deinit();
    const minecraft_root = try std.fs.path.join(a, &.{ target.root, ".minecraft" });
    defer a.free(minecraft_root);
    var proof = try metadata_loader.prepareVanilla(a, io, .{ .target = target, .vanilla = .{ .root = minecraft_root, .version_id = target.version_id, .manifest = manifest.value, .cancel = control.cancel }, .fetcher = .{} });
    errdefer proof.deinit();
    try control.check();
    return proof;
}

fn environment() !@import("../core/minecraft/metadata/root.zig").rules.Environment {
    const target = @import("builtin").target;
    return .{
        .os_name = switch (target.os.tag) {
            .linux => "linux",
            .windows => "windows",
            .macos => "osx",
            else => return error.UnsupportedPlatform,
        },
        .arch = switch (target.cpu.arch) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            .x86 => "x86",
            else => return error.UnsupportedArchitecture,
        },
    };
}
fn clockMilliseconds(raw: ?*anyopaque) u64 {
    const io: *const Io = @ptrCast(@alignCast(raw.?));
    return @intCast(@max(0, @divFloor(Io.Clock.awake.now(io.*).nanoseconds, std.time.ns_per_ms)));
}
fn loaderControl(io: *const Io, control: Control, timeout_ms: u64) @import("../core/loaders/root.zig").Control {
    return .{ .cancel = control.cancel, .deadline_ms = clockMilliseconds(@constCast(io)) + timeout_ms, .context = @constCast(io), .now_ms = clockMilliseconds, .task = control.task };
}
const HeldLease = struct {
    fn acquire(_: ?*anyopaque, _: []const u8) !void {}
    fn release(_: ?*anyopaque, _: []const u8) void {}
    fn recheck(raw: ?*anyopaque, id: []const u8) !void {
        const lease: *const content.Lease = @ptrCast(@alignCast(raw.?));
        try lease.recheck(lease.context, id);
    }
};
fn productionCatalogue(_: ?*anyopaque, a: A, io: Io, base: []const u8, kind: config.Loader, control: Control) !LoaderCatalogue {
    const http_cache = @import("metadata_http_cache.zig");
    const loaders = @import("../core/loaders/root.zig");
    if (kind == .vanilla) return error.InvalidLoader;
    try control.check();
    var client = try http_cache.Client.init(a, io, control.cache_root);
    defer client.deinit();
    const loader_kind: loaders.Kind = switch (kind) {
        .fabric => .fabric,
        .forge => .forge,
        .neoforge => .neoforge,
        .quilt => .quilt,
        .vanilla => unreachable,
    };
    var catalogue = try loaders.fetchCatalog(a, client.transport(), loader_kind, base, loaderControl(&io, control, 30_000));
    defer catalogue.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const entries = try owned.alloc(LoaderEntry, catalogue.value.entries.len);
    for (catalogue.value.entries, entries) |entry, *dest| dest.* = .{ .id = try owned.dupe(u8, entry.id), .stable = entry.stable };
    const owned_base = try owned.dupe(u8, base);
    return .{ .arena = arena, .base = owned_base, .kind = kind, .entries = entries };
}
fn productionRun(_: ?*anyopaque, a: A, io: Io, request: CreateRequest, control: Control) !Installed {
    const files = @import("../core/loaders/files.zig");
    const tree = @import("../core/worlds_tree.zig");
    try validateRequest(request.instance);
    if (!std.fs.path.isAbsolute(request.root)) return error.InvalidRoot;
    if (request.download_connections == 0 or request.download_connections > 64) return error.InvalidConnections;
    try control.check();
    if (request.prepared != null and request.vanilla_prepared != null) return error.ConflictingPreparedMetadata;
    const owns_namespace = request.namespace_token == null;
    const namespace_token = request.namespace_token orelse try namespace.acquireWaiting(io);
    defer if (owns_namespace) namespace_token.release();
    try namespace_token.recheckWaiting();
    try request.lease.recheck(request.lease.context, request.instance.id);
    const prepared_target: ?loader_install.MetadataTarget = if (request.prepared) |owner| blk: {
        const target = try metadataTarget(request.root, request.instance, request.prepared_generation, try environment());
        try owner.validateBinding(a, io, target);
        break :blk target;
    } else null;
    const vanilla_target: ?metadata_loader.VanillaTarget = if (request.vanilla_prepared) |owner| blk: {
        const target = try vanillaTarget(request.root, request.instance, request.prepared_generation, try environment());
        try owner.validateBinding(a, io, target);
        break :blk target;
    } else null;
    // Allocate the public result before any filesystem success boundary.
    var result = try Installed.init(a, request.instance);
    errdefer result.deinit();
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const g = scratch.allocator();
    const minecraft_root = try std.fs.path.join(g, &.{ request.root, ".minecraft" });
    const versions_path = try std.fs.path.join(g, &.{ minecraft_root, "versions" });
    const versions = try files.directory(io, versions_path, true);
    defer versions.close(io);
    try absent(io, versions, request.instance.name);
    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    const hex = std.fmt.bytesToHex(&random, .lower);
    const stage_name = try std.fmt.allocPrint(g, ".vela-instance-{s}", .{hex});
    var stage_owner = try tree.StageOwner.create(io, versions, stage_name, @import("../core/content_fs.zig").privatePermissions(true));
    defer stage_owner.close(io);
    productionStage(a, io, request, control, g, minecraft_root, versions_path, versions, &stage_owner, namespace_token, prepared_target, vanilla_target, &result) catch |err| {
        if (err == error.RecoveryRequired) stage_owner.armed = false;
        stage_owner.cleanup(io) catch return error.RecoveryRequired;
        return err;
    };
    // A loader publishes its own stage; its private vanilla input still belongs here.
    stage_owner.cleanup(io) catch return error.RecoveryRequired;
    return result;
}

fn productionStage(a: A, io: Io, request: CreateRequest, control: Control, g: A, minecraft_root: []const u8, versions_path: []const u8, versions: Io.Dir, stage_owner: *@import("../core/worlds_tree.zig").StageOwner, namespace_token: namespace.Token, prepared_target: ?loader_install.MetadataTarget, vanilla_target: ?metadata_loader.VanillaTarget, result: *Installed) !void {
    const minecraft = @import("../core/minecraft/install.zig");
    const loader = @import("../core/loaders/install.zig");
    const loaders = @import("../core/loaders/root.zig");
    const files = @import("../core/loaders/files.zig");
    const serde = @import("../core/minecraft/version_serialize.zig");
    const safe = @import("../core/install/safe_fs.zig");
    const tree = @import("../core/worlds_tree.zig");
    const downloader = @import("../core/downloader.zig");
    const stage_name = stage_owner.name;
    const stage = stage_owner.directory.?;
    const stage_path = try std.fs.path.join(g, &.{ versions_path, stage_name });
    const natives = try std.fs.path.join(g, &.{ stage_path, "natives" });
    const service = try downloader.Service.init(a, io, request.download_connections);
    defer service.deinit();
    control.report(.metadata, 0, null);
    const prepared_control: ?loaders.Control = if (request.prepared != null) loaderControl(&io, control, 30 * 60 * 1000) else null;
    const base_config: minecraft.Config = .{ .root = minecraft_root, .version_id = request.instance.minecraft_version, .instance_name = stage_name, .game_directory = stage_path, .natives_directory = natives, .publish_metadata = false, .namespace_token = namespace_token, .worker_checks = true, .environment = if (prepared_target) |target| target.environment else if (vanilla_target) |target| target.environment else try environment(), .window = request.download_connections, .cancel = control.cancel, .task = control.task };
    var base = if (request.prepared) |owner|
        try loader_base_install.runPrepared(a, io, service, base_config, owner, prepared_target.?, prepared_control.?)
    else if (request.vanilla_prepared) |owner|
        try minecraft.runVanillaPrepared(a, io, service, base_config, owner, vanilla_target.?)
    else
        try minecraft.run(a, io, service, base_config);
    defer base.deinit();
    try control.check();
    const load_control = prepared_control orelse loaderControl(&io, control, 30 * 60 * 1000);
    if (request.instance.loader != .vanilla) {
        const kind: loaders.Kind = switch (request.instance.loader) {
            .fabric => .fabric,
            .forge => .forge,
            .neoforge => .neoforge,
            .quilt => .quilt,
            .vanilla => unreachable,
        };
        control.report(.installing, 0, null);
        var lease = request.lease;
        const options: loader.Options = .{ .root = request.root, .instance_id = request.instance.id, .instance_name = request.instance.name, .namespace_token = namespace_token, .worker_checks = true, .selection = .{ .kind = kind, .base_id = request.instance.minecraft_version, .loader_id = request.instance.loader_version.? }, .base = base.version.value, .base_plan = base.plan.value, .base_directory = stage_path, .environment = base_config.environment, .java = request.installer_java, .lease = .{ .context = &lease, .acquire = HeldLease.acquire, .release = HeldLease.release, .recheck = HeldLease.recheck } };
        var installed = (if (request.prepared) |owner|
            loader.installPrepared(a, io, options, owner, request.prepared_generation, load_control)
        else
            loader.install(a, io, options, load_control)) catch |err| {
            if (err == error.RecoveryRequired) stage_owner.armed = false;
            return err;
        };
        defer installed.deinit();
        result.durability_uncertain = installed.durability_uncertain;
        return;
    }
    control.report(.verifying, 0, null);
    const jar_path = try std.fs.path.join(g, &.{ stage_path, try std.fmt.allocPrint(g, "{s}.jar", .{request.instance.name}) });
    const client = for (base.plan.value.files) |file| {
        if (file.kind == .client) break file;
    } else return error.MissingClientDownload;
    const source_parent = try safe.openParent(io, client.path, false);
    defer source_parent.close(io);
    const source_stat = try source_parent.statFile(io, std.fs.path.basename(client.path), .{ .follow_symlinks = false });
    if (source_stat.kind != .file or source_stat.nlink != 1) return error.HardLinkAlias;
    try files.copy(io, client.path, jar_path, 512 * 1024 * 1024, load_control);
    try files.verify(io, jar_path, client.sha1 orelse return error.MissingClientHash, client.size, 512 * 1024 * 1024, load_control);
    var descriptor = base.version.value;
    descriptor.id = request.instance.name;
    descriptor.inherits_from = null;
    descriptor.jar = null;
    const bytes = try serde.serialize(g, descriptor);
    const document_name = try std.fmt.allocPrint(g, "{s}.json", .{request.instance.name});
    try safe.writeAtomic(g, io, try std.fs.path.join(g, &.{ stage_path, document_name }), bytes, control.cancel);
    const client_binding = binding: {
        const name = std.fs.path.basename(jar_path);
        const named = try stage.statFile(io, name, .{ .follow_symlinks = false });
        if (named.kind != .file or named.nlink != 1) return error.HardLinkAlias;
        const file = try stage.openFile(io, name, .{ .follow_symlinks = false, .allow_directory = false });
        defer file.close(io);
        const before = try file.stat(io);
        if (before.kind != .file or before.nlink != 1 or before.inode != named.inode or before.size != named.size) return error.TreeChanged;
        if (before.size > 512 * 1024 * 1024) return error.ResourceLimit;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        var buffer: [64 * 1024]u8 = undefined;
        var offset: u64 = 0;
        while (offset < before.size) {
            try control.check();
            const want: usize = @intCast(@min(buffer.len, before.size - offset));
            const n = try file.readPositional(io, &.{buffer[0..want]}, offset);
            if (n == 0) return error.TreeChanged;
            hash.update(buffer[0..n]);
            offset += n;
        }
        const after = try file.stat(io);
        const final_named = try stage.statFile(io, name, .{ .follow_symlinks = false });
        if (after.nlink != 1 or after.size != before.size or after.mtime.nanoseconds != before.mtime.nanoseconds or after.ctime.nanoseconds != before.ctime.nanoseconds or final_named.kind != .file or final_named.inode != before.inode) return error.TreeChanged;
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        break :binding .{ .sha256 = digest, .size = before.size };
    };
    const client_hex = std.fmt.bytesToHex(&client_binding.sha256, .lower);
    var metadata_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &metadata_digest, .{});
    const metadata_hex = std.fmt.bytesToHex(&metadata_digest, .lower);
    const receipt = try std.json.Stringify.valueAlloc(g, .{ .schema_version = @as(u32, 1), .instance_id = request.instance.id, .instance_name = request.instance.name, .minecraft_version = request.instance.minecraft_version, .loader = "vanilla", .loader_version = @as(?[]const u8, null), .metadata_sha256 = @as([]const u8, &metadata_hex), .client_sha256 = @as([]const u8, &client_hex), .client_size = client_binding.size }, .{});
    try safe.writeAtomic(g, io, try std.fs.path.join(g, &.{ stage_path, ".vela-instance.json" }), receipt, control.cancel);
    try tree.syncDir(io, stage);
    try control.check();
    try namespace_token.recheckWaiting();
    try request.lease.recheck(request.lease.context, request.instance.id);
    try absent(io, versions, request.instance.name);
    try commitVanillaStage(io, versions, stage_owner, request.instance.name, &result.durability_uncertain);
}

fn commitVanillaStage(io: Io, versions: Io.Dir, stage_owner: *@import("../core/worlds_tree.zig").StageOwner, final_name: []const u8, durability_uncertain: *bool) !void {
    const tree = @import("../core/worlds_tree.zig");
    // Native future cancellation cannot interrupt publication or its identity checks.
    try io.checkCancel();
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    try stage_owner.verify(io);
    const before = stage_owner.identity;
    stage_owner.armed = false;
    Io.Dir.renamePreserve(versions, stage_owner.name, versions, final_name, io) catch |err| {
        // Errors may be reported after a move: only a provably intact stage is ordinary failure.
        const current = versions.statFile(io, stage_owner.name, .{ .follow_symlinks = false }) catch return error.RecoveryRequired;
        if (current.kind != .directory or current.inode != before.inode) return error.RecoveryRequired;
        absent(io, versions, final_name) catch return error.RecoveryRequired;
        stage_owner.armed = true;
        return err;
    };
    const committed = versions.statFile(io, final_name, .{ .follow_symlinks = false }) catch return error.RecoveryRequired;
    if (committed.kind != .directory or committed.inode != before.inode) return error.RecoveryRequired;
    // No cancellation or allocation after commit; failed sync is a truthful success warning.
    durability_uncertain.* = !tree.directory_sync_supported;
    tree.syncDir(io, versions) catch {
        durability_uncertain.* = true;
    };
}

test "vanilla stage publication preserves success after native cancellation at rename" {
    const tree = @import("../core/worlds_tree.zig");
    const test_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var owner = try tree.StageOwner.create(test_io, tmp.dir, ".vela-instance-test", .default_dir);
    defer owner.close(test_io);
    try owner.directory.?.writeFile(test_io, .{ .sub_path = "client.jar", .data = "verified fixture" });
    var fault: @import("../core/loaders/tests/stage_owner.zig").FaultIo = .{ .mode = .cancel_commit, .prefix = ".vela-instance-" };
    const fault_io = fault.start();
    defer fault.stop();
    var uncertain = false;
    try commitVanillaStage(fault_io, tmp.dir, &owner, "Published", &uncertain);
    try std.testing.expect(fault.committed and !owner.armed);
    try owner.cleanup(fault_io);
    const committed = try tmp.dir.statFile(test_io, "Published", .{ .follow_symlinks = false });
    try std.testing.expectEqual(owner.identity.inode, committed.inode);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(test_io, ".vela-instance-test", .{ .follow_symlinks = false }));
    try std.testing.expectError(error.Canceled, fault_io.checkCancel());
}
fn absent(io: Io, directory: Io.Dir, name: []const u8) !void {
    if (directory.statFile(io, name, .{ .follow_symlinks = false })) |_| {
        return error.InstanceAlreadyExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
}

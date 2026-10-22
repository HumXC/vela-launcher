//! UI-thread owner of one JDK download job. Join before registry finish or pruning.
//! root is the launcher base, NOT its .vela/jdks directory. No requests occur on init.
const std = @import("std");
const builtin = @import("builtin");
const curl = @import("curl");
const backend = @import("../core/java_download.zig");
const owned_storage = @import("java_owned_storage.zig");
const archive = @import("../core/java_archive.zig");
const downloader = @import("../core/downloader.zig");
const tasks = @import("../core/tasks.zig");
const java = @import("java_manager.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const worker_allocator = std.heap.page_allocator;

pub const Request = struct { vendor: backend.Vendor = .azul, major: u8 = 21 };
pub const Phase = enum { idle, running, complete, canceled, failed };
pub const Snapshot = struct {
    phase: Phase,
    progress: tasks.Progress,
    bytes_per_second: f64 = 0,
    details: tasks.Details = .{},
    request: ?Request,
    installed: ?*const backend.Installed,
    release: ?*const backend.RuntimeRelease,
    registered: bool,
    probe_failure: ?anyerror,
    registration_failure: ?anyerror,
    failure: ?anyerror,
};
/// Paths are borrowed until the next beginOwnedDelete/deinit; confirmation is caller-owned.
pub const OwnedDeleteSnapshot = struct {
    phase: Phase,
    java_path: ?[]const u8,
    failure: ?anyerror,
    registry_failure: ?anyerror,
    files_deleted: bool,
};
pub const Probe = struct {
    context: ?*anyopaque = null,
    run: *const fn (?*anyopaque, Allocator, Io, []const u8, ?*const std.atomic.Value(bool)) anyerror!java.Runtime = probeJava,
};
/// UI-thread admission; context must outlive the controller.
pub const OwnedDeleteAdmission = struct {
    context: ?*anyopaque = null,
    check: *const fn (?*anyopaque) anyerror!void,
};
pub const Options = struct {
    root: []const u8,
    task_registry: ?*tasks.Registry = null,
    download_connections: u16 = 8,
    // Optional fixture boundaries. Contexts must outlive the active job.
    transport: ?backend.Transport = null,
    extractor: ?backend.Extractor = null,
    probe: Probe = .{},
    owned_delete_admission: ?OwnedDeleteAdmission = null,
};

fn validateDownloadConnections(connections: u16) !void {
    if (connections < 1 or connections > 64) return error.InvalidDownloadConnections;
}

pub fn platformFor(os: std.Target.Os.Tag, cpu: std.Target.Cpu.Arch) !backend.Platform {
    return .{
        .os = switch (os) {
            .linux => .linux,
            .windows => .windows,
            .macos => .macos,
            else => return error.UnsupportedJavaPlatform,
        },
        .arch = switch (cpu) {
            .x86_64 => .x64,
            .aarch64 => .aarch64,
            else => return error.UnsupportedJavaArchitecture,
        },
    };
}
pub fn hostPlatform() !backend.Platform {
    return platformFor(builtin.os.tag, builtin.cpu.arch);
}

pub fn vendorMatches(expected: backend.Vendor, actual: []const u8) bool {
    const aliases: []const []const u8 = switch (expected) {
        .azul => &.{ "Azul", "Azul Zulu", "Azul Systems", "Azul Systems, Inc", "Azul Systems, Inc." },
        .microsoft => &.{ "Microsoft", "Microsoft Corporation" },
    };
    for (aliases) |alias| if (std.ascii.eqlIgnoreCase(actual, alias)) return true;
    return false;
}
fn probeJava(_: ?*anyopaque, a: Allocator, io: Io, path: []const u8, canceled: ?*const std.atomic.Value(bool)) !java.Runtime {
    return java.probe(a, io, path, canceled);
}

const Job = struct {
    arena: std.heap.ArenaAllocator = .init(worker_allocator),
    io: Io,
    root: []const u8,
    request: Request,
    platform: backend.Platform,
    download_connections: u16,
    task: ?*tasks.Task,
    service_adapter: backend.ServiceTransport(downloader.Service),
    transport: backend.Transport = undefined,
    extractor: ?backend.Extractor,
    archive_adapter: archive.Adapter = .{},
    probe: Probe,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    probe_cancel: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    probe_failure: ?anyerror = null,
    registration_failure: ?anyerror = null,
    release: ?backend.RuntimeRelease = null,
    installed: ?backend.Installed = null,
    runtime: ?java.Runtime = null,
    registered: bool = false,
    final_details: tasks.Details = .{},

    fn destroy(self: *Job) void {
        std.debug.assert(self.thread == null and self.task == null);
        self.arena.deinit();
        worker_allocator.destroy(self);
    }
    fn hooks(self: *Job) backend.Hooks {
        return .{ .context = self, .canceled = canceled, .progress = progress };
    }
    fn canceled(context: ?*anyopaque) bool {
        const self: *Job = @ptrCast(@alignCast(context.?));
        return self.task.?.canceled();
    }
    fn progress(context: ?*anyopaque, value: backend.Progress) void {
        const self: *Job = @ptrCast(@alignCast(context.?));
        const stage: tasks.Stage = switch (value.phase) {
            .metadata => .metadata,
            .downloading => .downloading,
            .verifying => .verifying,
            .extracting => .extracting,
            .publishing, .complete => .finalizing,
        };
        const task = self.task.?;
        var details = task.details();
        details.stage = stage;
        details.completed = value.received;
        details.total = value.total;
        details.stop();
        if (stage == .metadata or stage == .downloading) {
            details.received = value.received;
            details.total_bytes = value.total;
            if (stage == .downloading and !task.canceled()) details.bytes_per_second = value.bytes_per_second;
        }
        if (stage == .downloading) {
            if (self.release) |release| {
                details.file_count = 0;
                details.omitted_files = 0;
                details.addFile(tasks.File.init(release.url, value.received, value.total, details.bytes_per_second, .downloading, null));
            }
        } else if (stage != .metadata) {
            // Keep the last measured archive transfer while hashing and extracting.
            // Reaching extraction proves that the archive passed verification.
            for (details.files[0..details.file_count]) |*file| {
                file.state = if (stage == .verifying) .verifying else .complete;
            }
        }
        task.reportDetails(details);
    }
    fn run(self: *Job) void {
        self.perform() catch |err| {
            self.failure = err;
            var details = self.task.?.details();
            for (details.files[0..details.file_count]) |*file| {
                switch (file.state) {
                    .queued, .downloading, .verifying => {
                        file.state = if (err == error.Canceled) .canceled else .failed;
                        file.failure = err;
                    },
                    .complete, .failed, .canceled => {},
                }
            }
            details.stop();
            self.task.?.reportDetails(details);
        };
        self.done.store(true, .release);
    }
    fn perform(self: *Job) !void {
        const a = self.arena.allocator();
        self.release = try backend.resolve(a, self.transport, self.request.vendor, self.request.major, self.platform, self.hooks());
        self.archive_adapter.cancel = &self.task.?.cancellation;
        self.installed = try backend.install(a, self.io, self.transport, &self.release.?, self.root, self.extractor orelse self.archive_adapter.extractor(), self.hooks());
        // Publication is committed. Only shutdown cancels the independent probe;
        // a late task cancel cannot turn a valid downloaded artifact into failure.
        self.task.?.report(.scanning, 0, null);
        const runtime = self.probe.run(self.probe.context, a, self.io, self.installed.?.java_path, &self.probe_cancel) catch |err| {
            self.probe_failure = err;
            if (err != error.Canceled and err != error.OutOfMemory) self.installed.?.status = .unusable;
            return;
        };
        const architecture_matches = runtime.architecture == switch (self.platform.arch) {
            .x64 => @import("../core/java_runtime.zig").Architecture.x86_64,
            .aarch64 => @import("../core/java_runtime.zig").Architecture.aarch64,
        };
        if (runtime.major != self.request.major or !vendorMatches(self.request.vendor, runtime.vendor) or !architecture_matches) {
            java.freeRuntime(a, runtime);
            self.probe_failure = if (runtime.major != self.request.major) error.JavaMajorMismatch else if (!architecture_matches) error.JavaArchitectureMismatch else error.JavaVendorMismatch;
            self.installed.?.status = .unusable;
            return;
        }
        self.runtime = runtime;
        self.installed.?.status = .usable;
    }
};

const DeleteJob = struct {
    arena: std.heap.ArenaAllocator = .init(worker_allocator),
    io: Io,
    root: []const u8 = "",
    java_path: []const u8 = "",
    thread: ?std.Thread = null,
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    registry_failure: ?anyerror = null,
    deleted: bool = false,

    fn run(self: *DeleteJob) void {
        owned_storage.delete(self.arena.allocator(), self.io, self.root, self.java_path, &self.cancel) catch |err| {
            self.failure = err;
            self.done.store(true, .release);
            return;
        };
        self.deleted = true;
        self.done.store(true, .release);
    }
    fn destroy(self: *DeleteJob) void {
        std.debug.assert(self.thread == null);
        self.arena.deinit();
        worker_allocator.destroy(self);
    }
};

/// Do not move an active controller. External registries outlive this owner.
/// All borrowed snapshot paths remain valid through draw, until tick/start/deinit.
pub const Controller = struct {
    allocator: Allocator,
    io: Io,
    root: []const u8,
    service: *downloader.Service,
    download_connections: u16,
    registry: *tasks.Registry,
    own_registry: bool,
    fixture_transport: ?backend.Transport,
    fixture_extractor: ?backend.Extractor,
    probe: Probe,
    owned_delete_admission: ?OwnedDeleteAdmission = null,
    active: ?*Job = null,
    published: ?*Job = null,
    phase: Phase = .idle,
    failure: ?anyerror = null,
    active_delete: ?*DeleteJob = null,
    published_delete: ?*DeleteJob = null,
    delete_phase: Phase = .idle,

    pub fn init(a: Allocator, io: Io, root: []const u8) !Controller {
        return initWithOptions(a, io, .{ .root = root });
    }
    pub fn initWithOptions(a: Allocator, io: Io, options: Options) !Controller {
        _ = try platformFor(builtin.os.tag, builtin.cpu.arch);
        try validateDownloadConnections(options.download_connections);
        if (options.root.len == 0 or std.mem.indexOfScalar(u8, options.root, 0) != null) return error.InvalidInstallRoot;
        const cwd = try std.process.currentPathAlloc(io, a);
        defer a.free(cwd);
        const root = try std.fs.path.resolve(a, &.{ cwd, options.root, ".vela", "jdks" });
        errdefer a.free(root);
        const registry = options.task_registry orelse try a.create(tasks.Registry);
        errdefer if (options.task_registry == null) a.destroy(registry);
        if (options.task_registry == null) registry.* = tasks.Registry.init(a);
        try curl.globalInit();
        errdefer curl.globalDeinit();
        const service = try downloader.Service.init(worker_allocator, io, options.download_connections);
        return .{
            .allocator = a,
            .io = io,
            .root = root,
            .service = service,
            .download_connections = options.download_connections,
            .registry = registry,
            .own_registry = options.task_registry == null,
            .fixture_transport = options.transport,
            .fixture_extractor = options.extractor,
            .probe = options.probe,
            .owned_delete_admission = options.owned_delete_admission,
        };
    }
    pub fn deinit(self: *Controller) void {
        if (self.active_delete) |job| {
            job.cancel.store(true, .release);
            if (job.thread) |thread| thread.join();
            job.thread = null;
            job.destroy();
        }
        if (self.published_delete) |job| job.destroy();
        if (self.active) |job| {
            self.cancel();
            job.probe_cancel.store(true, .release);
            job.thread.?.join();
            job.thread = null;
            self.finishTask(job);
            job.destroy();
        }
        if (self.published) |job| job.destroy();
        self.service.deinit();
        curl.globalDeinit();
        if (self.own_registry) {
            self.registry.deinit();
            self.allocator.destroy(self.registry);
        }
        self.allocator.free(self.root);
        self.* = undefined;
    }
    pub fn hostPlatform(self: *const Controller) !backend.Platform {
        _ = self;
        return platformFor(builtin.os.tag, builtin.cpu.arch);
    }
    pub fn setDownloadConnections(self: *Controller, connections: u16) !void {
        try validateDownloadConnections(connections);
        self.download_connections = connections;
    }
    /// Deletion stays owned through cancellation and worker completion until JOIN/tick.
    pub fn isDeleting(self: *const Controller) bool {
        return self.active_delete != null;
    }
    pub fn isBusy(self: *const Controller) bool {
        return self.active != null or self.isDeleting();
    }
    /// Check only on an explicit action; success permits asking for file-delete confirmation.
    pub fn checkOwnedStorage(self: *const Controller, java_path: []const u8) !void {
        try owned_storage.check(self.allocator, self.io, self.root, java_path);
    }
    /// The caller must obtain explicit confirmation before starting this worker.
    /// Ownership is rechecked in the worker; registry publication happens only in tick.
    pub fn beginOwnedDelete(self: *Controller, java_path: []const u8) !void {
        if (self.isBusy()) return error.Busy;
        if (self.owned_delete_admission) |admission| try admission.check(admission.context);
        try self.checkOwnedStorage(java_path);
        const job = try worker_allocator.create(DeleteJob);
        job.* = .{ .io = self.io };
        errdefer job.destroy();
        const a = job.arena.allocator();
        job.root = try a.dupe(u8, self.root);
        job.java_path = try a.dupe(u8, java_path);
        job.thread = try std.Thread.spawn(.{}, DeleteJob.run, .{job});
        if (self.published_delete) |old| old.destroy();
        self.published_delete = null;
        self.active_delete = job;
        self.delete_phase = .running;
    }
    pub fn ownedDeleteSnapshot(self: *const Controller) OwnedDeleteSnapshot {
        const job = self.published_delete;
        return .{
            .phase = self.delete_phase,
            .java_path = if (self.active_delete) |active| active.java_path else if (job) |result| result.java_path else null,
            .failure = if (job) |result| result.failure else null,
            .registry_failure = if (job) |result| result.registry_failure else null,
            .files_deleted = if (job) |result| result.deleted else false,
        };
    }
    fn tickOwnedDelete(self: *Controller, manager: *java.Manager) void {
        const job = self.active_delete orelse return;
        if (!job.done.load(.acquire)) return;
        if (job.thread) |thread| thread.join();
        job.thread = null;
        // Partial/canceled/failed deletion never forgets a registered Java.
        if (job.deleted) {
            manager.forget(job.java_path) catch |err| {
                if (err != error.JavaNotRegistered) {
                    job.registry_failure = err;
                    job.failure = err;
                }
            };
            // An old download snapshot must not advertise a removed install.
            if (self.published) |download| {
                if (download.installed) |installed| {
                    if (std.mem.eql(u8, installed.java_path, job.java_path)) {
                        download.destroy();
                        self.published = null;
                        self.phase = .idle;
                        self.failure = null;
                    }
                }
            }
        }
        if (self.published_delete) |old| old.destroy();
        self.published_delete = job;
        self.active_delete = null;
        const canceled = if (job.failure) |failure| failure == error.Canceled else false;
        self.delete_phase = if (job.deleted and job.failure == null) .complete else if (canceled) .canceled else .failed;
    }
    pub fn start(self: *Controller, request: Request) !void {
        if (self.isBusy()) return error.Busy;
        if (!backend.supported(request.vendor, request.major)) return error.UnsupportedRelease;
        if (self.service.max_active != self.download_connections) {
            const replacement = try downloader.Service.init(worker_allocator, self.io, self.download_connections);
            self.service.deinit();
            self.service = replacement;
        }
        const job = try worker_allocator.create(Job);
        job.* = .{
            .io = self.io,
            .root = "",
            .request = request,
            .platform = try self.hostPlatform(),
            .download_connections = self.download_connections,
            .task = null,
            .service_adapter = .{ .service = self.service, .io = self.io },
            .extractor = self.fixture_extractor,
            .probe = self.probe,
        };
        errdefer job.destroy();
        job.root = try job.arena.allocator().dupe(u8, self.root);
        job.transport = self.fixture_transport orelse job.service_adapter.transport();
        const title = try std.fmt.allocPrint(self.allocator, "Java {d} · {s}", .{ request.major, if (request.vendor == .azul) "Azul Zulu CA" else "Microsoft OpenJDK" });
        defer self.allocator.free(title);
        job.task = try self.registry.create(.java_download, title);
        self.registry.start(job.task.?) catch |err| {
            self.registry.finish(job.task.?, .{ .failed = err });
            job.task = null;
            return err;
        };
        job.thread = std.Thread.spawn(.{}, Job.run, .{job}) catch |err| {
            self.registry.finish(job.task.?, .{ .failed = err });
            job.task = null;
            return err;
        };
        self.active = job;
        self.phase = .running;
        self.failure = null;
    }
    pub fn cancel(self: *Controller) void {
        if (self.active_delete) |job| job.cancel.store(true, .release);
        if (self.active) |job| _ = self.registry.cancel(job.task.?.id);
    }
    /// Join download and probe work; tick retains committed JDKs and registration results.
    pub fn cancelAndJoin(self: *Controller, manager: *java.Manager) void {
        if (self.active_delete) |job| {
            job.cancel.store(true, .release);
            if (job.thread) |thread| thread.join();
            job.thread = null;
            self.tickOwnedDelete(manager);
        }
        const job = self.active orelse return;
        self.cancel();
        job.probe_cancel.store(true, .release);
        if (job.thread) |thread| thread.join();
        job.thread = null;
        self.tick(manager);
    }
    pub fn tick(self: *Controller, manager: *java.Manager) void {
        self.tickOwnedDelete(manager);
        const job = self.active orelse return;
        if (!job.done.load(.acquire)) return;
        if (job.thread) |thread| thread.join();
        job.thread = null;
        if (job.runtime) |runtime| {
            manager.addDownloaded(runtime) catch |err| {
                job.registration_failure = err;
            };
            job.registered = job.registration_failure == null;
        }
        self.finishTask(job);
        if (self.published) |old| old.destroy();
        self.published = job;
        self.active = null;
        self.failure = job.failure;
        self.phase = if (job.installed != null) .complete else if ((job.failure orelse error.DownloadFailed) == error.Canceled) .canceled else .failed;
    }
    fn finishTask(self: *Controller, job: *Job) void {
        const task = job.task orelse return;
        self.registry.finish(task, if (job.installed != null) .succeeded else if ((job.failure orelse error.DownloadFailed) == error.Canceled) .canceled else .{ .failed = job.failure orelse error.DownloadFailed });
        job.final_details = task.details();
        job.task = null;
    }
    pub fn snapshot(self: *const Controller) Snapshot {
        const active = self.active;
        const data = if (active == null) self.published else null;
        // Progress and telemetry describe one coherent publication, retained after JOIN.
        var details = if (active) |job| job.task.?.details() else if (data) |job| job.final_details else tasks.Details{};
        const live_download = self.phase == .running and if (active) |job| !job.task.?.canceled() and details.stage == .downloading else false;
        if (!live_download) details.stop();
        return .{
            .phase = self.phase,
            .failure = self.failure,
            .progress = .{ .stage = details.stage, .completed = details.completed, .total = details.total },
            .bytes_per_second = details.bytes_per_second,
            .details = details,
            .request = if (active) |job| job.request else if (data) |job| job.request else null,
            .installed = if (data) |job| if (job.installed != null) &job.installed.? else null else null,
            .release = if (data) |job| if (job.release != null) &job.release.? else null else null,
            .registered = if (data) |job| job.registered else false,
            .probe_failure = if (data) |job| job.probe_failure else null,
            .registration_failure = if (data) |job| job.registration_failure else null,
        };
    }
};

test "host platform is typed and publisher identities match only explicit aliases" {
    for ([_]std.Target.Os.Tag{ .linux, .windows, .macos }) |os| {
        for ([_]std.Target.Cpu.Arch{ .x86_64, .aarch64 }) |cpu| {
            const platform = try platformFor(os, cpu);
            try std.testing.expectEqual(if (os == .windows) backend.Archive.zip else backend.Archive.tar_gz, platform.archive());
        }
    }
    try std.testing.expectError(error.UnsupportedJavaArchitecture, platformFor(.linux, .arm));
    try std.testing.expectError(error.UnsupportedJavaPlatform, platformFor(.freebsd, .x86_64));
    try std.testing.expect(vendorMatches(.azul, "Azul Systems, Inc."));
    try std.testing.expect(vendorMatches(.microsoft, "microsoft"));
    for ([_][]const u8{ "Unknown", "OpenJDK", "Not Microsoft", "Microsoft Evil", "Fake Azul Systems, Inc." }) |name| {
        try std.testing.expect(!vendorMatches(.azul, name));
        try std.testing.expect(!vendorMatches(.microsoft, name));
    }
}

const Fixture = struct {
    const Mode = enum { good, unusable, wrong_major, wrong_vendor, wrong_architecture, wait_metadata, wait_probe, wait_download, fail_download };
    mode: Mode = .good,
    entered: std.atomic.Value(bool) = .init(false),
    requests: std.atomic.Value(usize) = .init(0),
    transfer_entered: std.atomic.Value(bool) = .init(false),
    continue_download: std.atomic.Value(bool) = .init(false),
    extract_entered: std.atomic.Value(bool) = .init(false),
    continue_extract: std.atomic.Value(bool) = .init(false),
    unknown_total: bool = false,
    extract_failure: bool = false,
    fn transport(self: *Fixture) backend.Transport {
        return .{ .context = self, .get = get, .download = download };
    }
    fn extractor(self: *Fixture) backend.Extractor {
        return .{ .context = self, .extract = extract };
    }
    fn probe(self: *Fixture) Probe {
        return .{ .context = self, .run = verify };
    }
    fn waitCancel(io: Io, hooks: backend.Hooks) !void {
        while (true) {
            try hooks.check();
            try io.sleep(.fromMilliseconds(2), .awake);
        }
    }
    fn get(ctx: *anyopaque, a: Allocator, url: []const u8, limit: usize, hooks: backend.Hooks) ![]u8 {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        _ = self.requests.fetchAdd(1, .monotonic);
        try hooks.check();
        const platform = try platformFor(builtin.os.tag, builtin.cpu.arch);
        const os = switch (platform.os) {
            .linux => "linux",
            .windows => "windows",
            .macos => "macOS",
        };
        const expected = try std.fmt.allocPrint(a, "https://aka.ms/download-jdk/microsoft-jdk-21-{s}-{s}.{s}.sha256sum.txt", .{ os, @tagName(platform.arch), if (platform.archive() == .zip) "zip" else "tar.gz" });
        defer a.free(expected);
        if (!std.mem.eql(u8, expected, url)) return error.UnexpectedFixtureUrl;
        self.entered.store(true, .release);
        if (self.mode == .wait_metadata) try waitCancel(std.testing.io, hooks);
        const result = try std.fmt.allocPrint(a, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  microsoft-jdk-21.0.1-{s}-{s}.{s}", .{ os, @tagName(platform.arch), if (platform.archive() == .zip) "zip" else "tar.gz" });
        errdefer a.free(result);
        if (result.len > limit) return error.MetadataTooLarge;
        return result;
    }
    fn download(ctx: *anyopaque, io: Io, release: *const backend.RuntimeRelease, path: []const u8, hooks: backend.Hooks) !void {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        try hooks.check();
        if (release.major != 21 or !std.mem.startsWith(u8, release.url, "https://aka.ms/download-jdk/microsoft-jdk-21.0.1-")) return error.UnexpectedFixtureArtifact;
        const received: u64 = if (self.mode == .fail_download) 24482688 else 2;
        const total: ?u64 = if (self.unknown_total) null else if (self.mode == .fail_download) 106674581 else 3;
        hooks.progress.?(hooks.context, .{ .phase = .downloading, .received = received, .total = total, .bytes_per_second = 14575206.4 });
        if (self.mode == .wait_download or self.mode == .fail_download) {
            self.transfer_entered.store(true, .release);
            while (!self.continue_download.load(.acquire)) {
                try hooks.check();
                try io.sleep(.fromMilliseconds(2), .awake);
            }
        }
        if (self.mode == .fail_download) {
            // The child transport's terminal sample can advance before it returns an error.
            hooks.progress.?(hooks.context, .{ .phase = .downloading, .received = received + 3, .total = total });
            return error.DownloadInterrupted;
        }
        const file = try Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
        defer file.close(io);
        try file.writeStreamingAll(io, "abc");
        hooks.progress.?(hooks.context, .{ .phase = .downloading, .received = 3, .total = 3 });
    }
    fn extract(ctx: *anyopaque, a: Allocator, io: Io, format: backend.Archive, _: []const u8, dest: []const u8, hooks: backend.Hooks) ![]u8 {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        try hooks.check();
        if (self.mode == .wait_download) {
            self.extract_entered.store(true, .release);
            while (!self.continue_extract.load(.acquire)) {
                try hooks.check();
                try io.sleep(.fromMilliseconds(2), .awake);
            }
        }
        if (self.extract_failure) return error.ExtractInterrupted;
        const dir = try Io.Dir.cwd().openDir(io, dest, .{});
        defer dir.close(io);
        try dir.createDir(io, "bin", .default_dir);
        const relative = if (format == .zip) "bin/java.exe" else "bin/java";
        const file = try dir.createFile(io, relative, .{ .permissions = .executable_file });
        {
            defer file.close(io);
            try file.writeStreamingAll(io, "inert fixture, never executed");
        }
        return a.dupe(u8, relative);
    }
    fn verify(ctx: ?*anyopaque, a: Allocator, io: Io, path: []const u8, cancel: ?*const std.atomic.Value(bool)) !java.Runtime {
        const self: *Fixture = @ptrCast(@alignCast(ctx.?));
        self.entered.store(true, .release);
        if (self.mode == .unusable) return error.FileNotFound;
        if (self.mode == .wait_probe) {
            while (!cancel.?.load(.acquire)) try io.sleep(.fromMilliseconds(2), .awake);
            return error.Canceled;
        }
        const owned_path = try a.dupe(u8, path);
        errdefer a.free(owned_path);
        const host = @import("../core/java_runtime.zig").host();
        const actual: @import("../core/java_runtime.zig").Architecture = if (self.mode == .wrong_architecture) (if (host == .aarch64) .x86_64 else .aarch64) else host;
        return .{ .path = owned_path, .major = if (self.mode == .wrong_major) 17 else 21, .architecture = actual, .vendor = try a.dupe(u8, if (self.mode == .wrong_vendor) "Fake Microsoft" else "Microsoft") };
    }
};
fn fixtureRoot(tmp: *std.testing.TmpDir) ![:0]u8 {
    return tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
}
fn awaitController(controller: *Controller, manager: *java.Manager) !void {
    for (0..1500) |_| {
        controller.tick(manager);
        if (controller.active == null) return;
        try std.testing.io.sleep(.fromMilliseconds(2), .awake);
    }
    return error.FixtureTimedOut;
}
fn awaitFlag(flag: *const std.atomic.Value(bool)) !void {
    for (0..1500) |_| {
        if (flag.load(.acquire)) return;
        try std.testing.io.sleep(.fromMilliseconds(2), .awake);
    }
    return error.FixtureTimedOut;
}

test "archive transfer details follow child transport through extraction and pruning" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer a.free(root);
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var manager = try java.Manager.init(a, io, root);
    defer manager.deinit();
    var fixture: Fixture = .{ .mode = .wait_download };
    var controller = try Controller.initWithOptions(a, io, .{ .root = root, .task_registry = &registry, .transport = fixture.transport(), .extractor = fixture.extractor(), .probe = fixture.probe() });
    defer controller.deinit();
    try controller.start(.{ .vendor = .microsoft, .major = 21 });
    const task = controller.active.?.task.?;
    try awaitFlag(&fixture.transfer_entered);
    const live = controller.snapshot();
    try std.testing.expectEqual(tasks.Stage.downloading, live.progress.stage);
    try std.testing.expectEqual(@as(u64, 2), live.progress.completed);
    try std.testing.expectEqual(@as(?u64, 3), live.progress.total);
    try std.testing.expectEqual(@as(usize, 1), live.details.file_count);
    try std.testing.expectEqual(@as(usize, 0), live.details.omitted_files);
    const entry = live.details.files[0];
    const platform = try controller.hostPlatform();
    const os = switch (platform.os) {
        .linux => "linux",
        .windows => "windows",
        .macos => "macOS",
    };
    const name = try std.fmt.allocPrint(a, "microsoft-jdk-21.0.1-{s}-{s}.{s}", .{ os, @tagName(platform.arch), if (platform.archive() == .zip) "zip" else "tar.gz" });
    defer a.free(name);
    try std.testing.expectEqualStrings(name, entry.name());
    try std.testing.expect(std.mem.startsWith(u8, entry.path(), "https://aka.ms/download-jdk/"));
    try std.testing.expectEqual(tasks.FileState.downloading, entry.state);
    try std.testing.expectEqual(@as(u64, 2), entry.received);
    try std.testing.expectEqual(@as(?u64, 3), entry.total);
    try std.testing.expectEqual(live.details.received, entry.received);
    try std.testing.expectEqual(live.details.total_bytes, entry.total);
    try std.testing.expectEqual(@as(f64, 14575206.4), entry.bytes_per_second);
    try std.testing.expectEqual(entry.bytes_per_second, live.bytes_per_second);
    fixture.continue_download.store(true, .release);
    try awaitFlag(&fixture.extract_entered);
    const extracting = controller.snapshot();
    try std.testing.expectEqual(tasks.Stage.extracting, extracting.progress.stage);
    try std.testing.expectEqual(@as(u64, 0), extracting.progress.completed);
    try std.testing.expectEqual(@as(?u64, null), extracting.progress.total);
    try std.testing.expectEqual(@as(usize, 1), extracting.details.file_count);
    try std.testing.expectEqual(@as(usize, 0), extracting.details.omitted_files);
    try std.testing.expectEqualStrings(name, extracting.details.files[0].name());
    try std.testing.expectEqual(tasks.FileState.complete, extracting.details.files[0].state);
    try std.testing.expectEqual(@as(u64, 3), extracting.details.files[0].received);
    try std.testing.expectEqual(@as(?u64, 3), extracting.details.files[0].total);
    try std.testing.expectEqual(@as(u64, 3), extracting.details.received);
    try std.testing.expectEqual(@as(?u64, 3), extracting.details.total_bytes);
    try std.testing.expectEqual(@as(f64, 0), extracting.bytes_per_second);
    try std.testing.expectEqual(@as(f64, 0), extracting.details.files[0].bytes_per_second);
    fixture.continue_extract.store(true, .release);
    try awaitController(&controller, &manager);
    try std.testing.expectEqual(tasks.State.succeeded, task.state);
    registry.pruneFinished(0);
    const final = controller.snapshot();
    try std.testing.expectEqual(Phase.complete, final.phase);
    try std.testing.expectEqual(@as(usize, 1), final.details.file_count);
    try std.testing.expectEqualStrings(name, final.details.files[0].name());
    try std.testing.expectEqual(tasks.FileState.complete, final.details.files[0].state);
    try std.testing.expectEqual(@as(u64, 3), final.details.files[0].received);
    try std.testing.expectEqual(@as(f64, 0), final.bytes_per_second);
}

test "verified archive transfer stays complete when extraction fails or is canceled" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]bool{ false, true }) |cancel| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try fixtureRoot(&tmp);
        defer a.free(root);
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var manager = try java.Manager.init(a, io, root);
        defer manager.deinit();
        var fixture: Fixture = .{ .mode = .wait_download, .extract_failure = !cancel };
        var controller = try Controller.initWithOptions(a, io, .{ .root = root, .task_registry = &registry, .transport = fixture.transport(), .extractor = fixture.extractor(), .probe = fixture.probe() });
        defer controller.deinit();
        try controller.start(.{ .vendor = .microsoft, .major = 21 });
        try awaitFlag(&fixture.transfer_entered);
        fixture.continue_download.store(true, .release);
        try awaitFlag(&fixture.extract_entered);
        if (cancel) controller.cancel() else fixture.continue_extract.store(true, .release);
        try awaitController(&controller, &manager);
        registry.pruneFinished(0);
        const final = controller.snapshot();
        try std.testing.expectEqual(if (cancel) Phase.canceled else Phase.failed, final.phase);
        try std.testing.expectEqual(@as(?anyerror, if (cancel) error.Canceled else error.ExtractInterrupted), final.failure);
        try std.testing.expectEqual(tasks.Stage.extracting, final.progress.stage);
        try std.testing.expectEqual(@as(usize, 1), final.details.file_count);
        const file = final.details.files[0];
        try std.testing.expect(file.name().len > 0);
        try std.testing.expectEqual(tasks.FileState.complete, file.state);
        try std.testing.expectEqual(@as(?anyerror, null), file.failure);
        try std.testing.expectEqual(@as(u64, 3), file.received);
        try std.testing.expectEqual(@as(?u64, 3), file.total);
        try std.testing.expectEqual(@as(f64, 0), file.bytes_per_second);
        try std.testing.expectEqual(@as(f64, 0), final.bytes_per_second);
    }
}

test "archive failure and cancellation retain measured file details after join and pruning" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]bool{ false, true }) |cancel| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try fixtureRoot(&tmp);
        defer a.free(root);
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var manager = try java.Manager.init(a, io, root);
        defer manager.deinit();
        var fixture: Fixture = .{ .mode = if (cancel) .wait_download else .fail_download, .unknown_total = cancel };
        var controller = try Controller.initWithOptions(a, io, .{ .root = root, .task_registry = &registry, .transport = fixture.transport(), .extractor = fixture.extractor(), .probe = fixture.probe() });
        defer controller.deinit();
        try controller.start(.{ .vendor = .microsoft, .major = 21 });
        const task = controller.active.?.task.?;
        try awaitFlag(&fixture.transfer_entered);
        const live = controller.snapshot();
        const total: ?u64 = if (cancel) null else 106674581;
        try std.testing.expectEqual(@as(usize, 1), live.details.file_count);
        try std.testing.expectEqual(@as(u64, if (cancel) 2 else 24482688), live.details.received);
        try std.testing.expectEqual(total, live.details.total_bytes);
        try std.testing.expectEqual(@as(f64, 14575206.4), live.bytes_per_second);
        if (cancel) {
            controller.cancel();
            try std.testing.expectEqual(@as(f64, 0), controller.snapshot().details.files[0].bytes_per_second);
        } else fixture.continue_download.store(true, .release);
        try awaitController(&controller, &manager);
        try std.testing.expectEqual(if (cancel) tasks.State.canceled else tasks.State.failed, task.state);
        registry.pruneFinished(0);
        const final = controller.snapshot();
        try std.testing.expectEqual(if (cancel) Phase.canceled else Phase.failed, final.phase);
        try std.testing.expectEqual(@as(?anyerror, if (cancel) error.Canceled else error.DownloadInterrupted), final.failure);
        try std.testing.expectEqual(tasks.Stage.downloading, final.progress.stage);
        try std.testing.expectEqual(@as(usize, 1), final.details.file_count);
        try std.testing.expectEqual(@as(usize, 0), final.details.omitted_files);
        try std.testing.expectEqualStrings(live.details.files[0].name(), final.details.files[0].name());
        try std.testing.expectEqual(if (cancel) tasks.FileState.canceled else tasks.FileState.failed, final.details.files[0].state);
        try std.testing.expectEqual(final.failure, final.details.files[0].failure);
        try std.testing.expectEqual(@as(u64, if (cancel) 2 else 24482691), final.details.files[0].received);
        try std.testing.expectEqual(final.details.files[0].received, final.details.received);
        try std.testing.expectEqual(total, final.details.files[0].total);
        try std.testing.expectEqual(total, final.details.total_bytes);
        try std.testing.expectEqual(@as(f64, 0), final.bytes_per_second);
        try std.testing.expectEqual(@as(f64, 0), final.details.files[0].bytes_per_second);
    }
}

test "joined downloaded results register only verified identity and survive registry pruning" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]Fixture.Mode{ .good, .unusable, .wrong_major, .wrong_vendor, .wrong_architecture }) |mode| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try fixtureRoot(&tmp);
        defer a.free(root);
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var manager = try java.Manager.init(a, io, root);
        defer manager.deinit();
        var fixture: Fixture = .{ .mode = mode };
        var controller = try Controller.initWithOptions(a, io, .{ .root = root, .task_registry = &registry, .transport = fixture.transport(), .extractor = fixture.extractor(), .probe = fixture.probe() });
        defer controller.deinit();
        try std.testing.expectEqual(@as(usize, 0), fixture.requests.load(.acquire));
        try controller.start(.{ .vendor = .microsoft, .major = 21 });
        const task = controller.active.?.task.?;
        try awaitController(&controller, &manager);
        try std.testing.expect(controller.published.?.thread == null and controller.published.?.task == null);
        try std.testing.expectEqual(tasks.State.succeeded, task.state);
        const snapshot = controller.snapshot();
        try std.testing.expectEqual(Phase.complete, snapshot.phase);
        try std.testing.expect(snapshot.installed != null);
        const file = try Io.Dir.cwd().openFile(io, snapshot.installed.?.java_path, .{});
        file.close(io);
        try std.testing.expectEqual(mode == .good, snapshot.registered);
        try std.testing.expectEqual(@as(usize, if (mode == .good) 1 else 0), manager.entries().len);
        if (mode != .good) try std.testing.expect(snapshot.probe_failure != null);
        registry.pruneFinished(0);
        try std.testing.expect(controller.snapshot().installed != null);
        if (mode == .good) {
            var reloaded = try java.Manager.init(a, io, root);
            defer reloaded.deinit();
            try std.testing.expectEqual(@as(usize, 1), reloaded.entries().len);
            try std.testing.expectEqualStrings(snapshot.installed.?.java_path, reloaded.entries()[0].path);
        }
    }
}

test "download cancellation joins worker before registry finish and prune" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer a.free(root);
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var manager = try java.Manager.init(a, io, root);
    defer manager.deinit();
    var fixture: Fixture = .{ .mode = .wait_metadata };
    var controller = try Controller.initWithOptions(a, io, .{ .root = root, .task_registry = &registry, .transport = fixture.transport(), .extractor = fixture.extractor(), .probe = fixture.probe() });
    defer controller.deinit();
    try controller.start(.{ .vendor = .microsoft, .major = 21 });
    const task = controller.active.?.task.?;
    try awaitFlag(&fixture.entered);
    Job.progress(controller.active.?, .{ .phase = .downloading, .received = 1024, .total = 2048, .bytes_per_second = 3072 });
    const transfer = controller.snapshot();
    try std.testing.expectEqual(@as(u64, 1024), transfer.progress.completed);
    try std.testing.expectEqual(@as(?u64, 2048), transfer.progress.total);
    try std.testing.expectEqual(@as(f64, 3072), transfer.bytes_per_second);
    try std.testing.expectEqual(@as(u64, 1024), transfer.details.received);
    try std.testing.expectEqual(@as(?u64, 2048), transfer.details.total_bytes);
    try std.testing.expectEqual(transfer.bytes_per_second, transfer.details.bytes_per_second);
    try std.testing.expectEqual(@as(usize, 0), transfer.details.file_count);
    Job.progress(controller.active.?, .{ .phase = .verifying, .received = 1024, .total = 2048, .bytes_per_second = 3072 });
    try std.testing.expectEqual(@as(f64, 0), controller.snapshot().bytes_per_second);
    task.reportDetails(.{ .stage = .downloading, .received = 1024, .total_bytes = 2048, .bytes_per_second = 3072 });
    controller.cancel();
    try std.testing.expectEqual(@as(f64, 0), controller.snapshot().bytes_per_second);
    try std.testing.expectEqual(@as(f64, 0), controller.snapshot().details.bytes_per_second);
    try std.testing.expectEqual(tasks.State.canceling, task.state);
    try awaitController(&controller, &manager);
    try std.testing.expectEqual(tasks.State.canceled, task.state);
    registry.pruneFinished(0);
    try std.testing.expectEqual(Phase.canceled, controller.snapshot().phase);
    try std.testing.expectEqual(@as(f64, 0), controller.snapshot().bytes_per_second);
    try std.testing.expectEqual(@as(u64, 1024), controller.snapshot().details.received);
    try std.testing.expectEqual(@as(?u64, 2048), controller.snapshot().details.total_bytes);
    try std.testing.expectEqual(@as(f64, 0), controller.snapshot().details.bytes_per_second);
    try std.testing.expectEqual(@as(usize, 0), controller.snapshot().details.file_count);
    try std.testing.expectEqual(@as(usize, 0), manager.entries().len);
}

test "shutdown stops independent probe without rewriting committed download" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer a.free(root);
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{ .mode = .wait_probe };
    var controller = try Controller.initWithOptions(a, io, .{ .root = root, .task_registry = &registry, .transport = fixture.transport(), .extractor = fixture.extractor(), .probe = fixture.probe() });
    var deinitialized = false;
    defer if (!deinitialized) controller.deinit();
    try controller.start(.{ .vendor = .microsoft, .major = 21 });
    const job = controller.active.?;
    // get() also sets entered; wait for scanning through the coherent task snapshot.
    for (0..1500) |_| {
        if (job.task.?.progress().stage == .scanning) break;
        try io.sleep(.fromMilliseconds(2), .awake);
    } else return error.FixtureTimedOut;
    const task = job.task.?;
    const installed_path = try a.dupe(u8, job.installed.?.java_path);
    defer a.free(installed_path);
    controller.cancel();
    try std.testing.expectEqual(tasks.State.canceling, task.state);
    controller.deinit();
    deinitialized = true;
    try std.testing.expectEqual(tasks.State.succeeded, task.state);
    const file = try Io.Dir.cwd().openFile(io, installed_path, .{});
    file.close(io);
    registry.pruneFinished(0);
}

test "registration persistence failure preserves usable installation and manager state" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer a.free(root);
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var manager = try java.Manager.init(a, io, root);
    defer manager.deinit();
    try tmp.dir.createDirPath(io, ".vela/java.json");
    var fixture: Fixture = .{};
    var controller = try Controller.initWithOptions(a, io, .{ .root = root, .task_registry = &registry, .transport = fixture.transport(), .extractor = fixture.extractor(), .probe = fixture.probe() });
    defer controller.deinit();
    try controller.start(.{ .vendor = .microsoft, .major = 21 });
    const task = controller.active.?.task.?;
    try awaitController(&controller, &manager);
    const snapshot = controller.snapshot();
    try std.testing.expectEqual(Phase.complete, snapshot.phase);
    try std.testing.expectEqual(tasks.State.succeeded, task.state);
    try std.testing.expect(snapshot.installed.?.status == .usable);
    try std.testing.expect(snapshot.probe_failure == null);
    try std.testing.expect(!snapshot.registered and snapshot.registration_failure != null);
    try std.testing.expectEqual(@as(usize, 0), manager.entries().len);
    const file = try Io.Dir.cwd().openFile(io, snapshot.installed.?.java_path, .{});
    file.close(io);
    try tmp.dir.deleteDir(io, ".vela/java.json");
    const runtime: java.Runtime = .{ .path = snapshot.installed.?.java_path, .major = 21, .architecture = @import("../core/java_runtime.zig").host(), .vendor = "Microsoft" };
    try manager.addDownloaded(runtime);
    try manager.addDownloaded(runtime);
    try std.testing.expectEqual(@as(usize, 1), manager.entries().len);
    try manager.addDownloaded(.{ .path = runtime.path, .major = 17, .architecture = @import("../core/java_runtime.zig").host(), .vendor = "Azul Systems, Inc." });
    try std.testing.expectEqual(@as(u32, 17), manager.entries()[0].major);
    try std.testing.expectEqualStrings("Azul Systems, Inc.", manager.entries()[0].vendor);
    var reloaded = try java.Manager.init(a, io, root);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(u32, 17), reloaded.entries()[0].major);
    try std.testing.expectEqualStrings("Azul Systems, Inc.", reloaded.entries()[0].vendor);
    try tmp.dir.deleteFile(io, ".vela/java.json");
    try tmp.dir.createDir(io, ".vela/java.json", .default_dir);
    if (manager.addDownloaded(runtime)) |_| return error.ExpectedPersistenceFailure else |_| {}
    try std.testing.expectEqual(@as(u32, 17), manager.entries()[0].major);
    try std.testing.expectEqualStrings("Azul Systems, Inc.", manager.entries()[0].vendor);
}

test "download connection limits validate and apply only to future jobs" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer a.free(root);
    for ([_]u16{ 0, 65 }) |connections| {
        try std.testing.expectError(error.InvalidDownloadConnections, Controller.initWithOptions(a, io, .{ .root = root, .download_connections = connections }));
    }
    for ([_]u16{ 1, 64 }) |connections| {
        var boundary = try Controller.initWithOptions(a, io, .{ .root = root, .download_connections = connections });
        defer boundary.deinit();
        try std.testing.expectEqual(connections, boundary.download_connections);
        try std.testing.expectEqual(@as(usize, connections), boundary.service.max_active);
    }
    var fixture: Fixture = .{ .mode = .wait_metadata };
    var controller = try Controller.initWithOptions(a, io, .{ .root = root, .transport = fixture.transport(), .extractor = fixture.extractor(), .probe = fixture.probe() });
    defer controller.deinit();
    var manager = try java.Manager.init(a, io, root);
    defer manager.deinit();
    try std.testing.expectEqual(@as(u16, 8), controller.download_connections);
    try std.testing.expectEqual(@as(usize, 8), controller.service.max_active);
    for ([_]u16{ 0, 65 }) |connections| {
        try std.testing.expectError(error.InvalidDownloadConnections, controller.setDownloadConnections(connections));
        try std.testing.expectEqual(@as(u16, 8), controller.download_connections);
    }
    try controller.setDownloadConnections(1);
    try controller.start(.{ .vendor = .microsoft, .major = 21 });
    try awaitFlag(&fixture.entered);
    const first_service = controller.service;
    try std.testing.expectEqual(@as(u16, 1), controller.active.?.download_connections);
    try std.testing.expectEqual(@as(usize, 1), first_service.max_active);
    try controller.setDownloadConnections(64);
    try std.testing.expectEqual(first_service, controller.service);
    try std.testing.expectEqual(@as(u16, 1), controller.active.?.download_connections);
    try std.testing.expectEqual(@as(usize, 1), first_service.max_active);
    controller.cancel();
    try awaitController(&controller, &manager);
    try controller.start(.{ .vendor = .microsoft, .major = 21 });
    try std.testing.expectEqual(@as(u16, 64), controller.active.?.download_connections);
    try std.testing.expectEqual(@as(usize, 64), controller.service.max_active);
    controller.cancel();
    try awaitController(&controller, &manager);
}

test "download cancelAndJoin synchronously cancels active work and leaves owners reusable" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer a.free(root);
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var manager = try java.Manager.init(a, io, root);
    defer manager.deinit();
    var fixture: Fixture = .{ .mode = .wait_metadata };
    var controller = try Controller.initWithOptions(a, io, .{ .root = root, .task_registry = &registry, .transport = fixture.transport(), .extractor = fixture.extractor(), .probe = fixture.probe() });
    defer controller.deinit();
    const state = manager.state;
    controller.cancelAndJoin(&manager);
    try std.testing.expect(controller.active == null and controller.published == null);
    try controller.start(.{ .vendor = .microsoft, .major = 21 });
    const job = controller.active.?;
    const task = job.task.?;
    try awaitFlag(&fixture.entered);
    controller.cancelAndJoin(&manager);
    try std.testing.expect(job.done.load(.acquire) and job.probe_cancel.load(.acquire));
    try std.testing.expect(job.thread == null and job.task == null and controller.active == null);
    try std.testing.expectEqual(job, controller.published.?);
    try std.testing.expectEqual(tasks.State.canceled, task.state);
    try std.testing.expectEqual(Phase.canceled, controller.snapshot().phase);
    registry.pruneFinished(0);
    controller.cancelAndJoin(&manager);
    controller.tick(&manager);
    try std.testing.expectEqual(job, controller.published.?);
    try std.testing.expectEqual(state, manager.state);
    try std.testing.expectEqual(@as(usize, 0), manager.entries().len);
    fixture.mode = .good;
    try controller.start(.{ .vendor = .microsoft, .major = 21 });
    try awaitController(&controller, &manager);
    try std.testing.expect(controller.snapshot().registered);
}

test "download cancelAndJoin stops independent probe but retains committed JDK and success" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer a.free(root);
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var manager = try java.Manager.init(a, io, root);
    defer manager.deinit();
    var fixture: Fixture = .{ .mode = .wait_probe };
    var controller = try Controller.initWithOptions(a, io, .{ .root = root, .task_registry = &registry, .transport = fixture.transport(), .extractor = fixture.extractor(), .probe = fixture.probe() });
    defer controller.deinit();
    try controller.start(.{ .vendor = .microsoft, .major = 21 });
    const job = controller.active.?;
    const task = job.task.?;
    for (0..1500) |_| {
        if (task.progress().stage == .scanning) break;
        try io.sleep(.fromMilliseconds(2), .awake);
    } else return error.FixtureTimedOut;
    controller.cancelAndJoin(&manager);
    try std.testing.expect(job.done.load(.acquire) and job.probe_cancel.load(.acquire));
    try std.testing.expect(job.thread == null and job.task == null and controller.active == null);
    try std.testing.expectEqual(tasks.State.succeeded, task.state);
    const snapshot = controller.snapshot();
    try std.testing.expectEqual(Phase.complete, snapshot.phase);
    try std.testing.expect(snapshot.installed != null and !snapshot.registered);
    try std.testing.expect(snapshot.probe_failure.? == error.Canceled);
    try std.testing.expect(snapshot.installed.?.status != .unusable);
    try std.testing.expectEqual(@as(usize, 0), manager.entries().len);
    const file = try Io.Dir.cwd().openFile(io, snapshot.installed.?.java_path, .{});
    file.close(io);
    registry.pruneFinished(0);
    controller.cancelAndJoin(&manager);
    controller.tick(&manager);
    try std.testing.expectEqual(job, controller.published.?);
    try std.testing.expect(controller.snapshot().installed != null);
}

test "download cancelAndJoin consumes late success and registration failures through normal tick" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]bool{ false, true }) |fail_registration| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try fixtureRoot(&tmp);
        defer a.free(root);
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var manager = try java.Manager.init(a, io, root);
        defer manager.deinit();
        if (fail_registration) try tmp.dir.createDirPath(io, ".vela/java.json");
        const state = manager.state;
        var fixture: Fixture = .{ .mode = .good };
        var controller = try Controller.initWithOptions(a, io, .{ .root = root, .task_registry = &registry, .transport = fixture.transport(), .extractor = fixture.extractor(), .probe = fixture.probe() });
        defer controller.deinit();
        try controller.start(.{ .vendor = .microsoft, .major = 21 });
        const job = controller.active.?;
        const task = job.task.?;
        try awaitFlag(&job.done);
        controller.cancelAndJoin(&manager);
        try std.testing.expect(job.thread == null and job.task == null and controller.active == null);
        try std.testing.expectEqual(job, controller.published.?);
        try std.testing.expectEqual(tasks.State.succeeded, task.state);
        const snapshot = controller.snapshot();
        try std.testing.expectEqual(Phase.complete, snapshot.phase);
        try std.testing.expect(snapshot.installed.?.status == .usable and snapshot.probe_failure == null);
        try std.testing.expectEqual(!fail_registration, snapshot.registered);
        try std.testing.expectEqual(fail_registration, snapshot.registration_failure != null);
        try std.testing.expectEqual(@as(usize, if (fail_registration) 0 else 1), manager.entries().len);
        if (fail_registration) try std.testing.expectEqual(state, manager.state);
        const file = try Io.Dir.cwd().openFile(io, snapshot.installed.?.java_path, .{});
        file.close(io);
        registry.pruneFinished(0);
        controller.cancelAndJoin(&manager);
        controller.tick(&manager);
        try std.testing.expectEqual(job, controller.published.?);
        try std.testing.expectEqual(!fail_registration, controller.snapshot().registered);
        if (!fail_registration) {
            var reloaded = try java.Manager.init(a, io, root);
            defer reloaded.deinit();
            try std.testing.expectEqual(@as(usize, 1), reloaded.entries().len);
        }
    }
}

test "owned delete validates receipts and paths, preserves links, joins before publication, and never falsely completes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Case = enum { success, interior_links, cancel_before_worker, partial_retry, registry_failure, malformed_receipt, java_symlink, java_hardlink };
    for ([_]Case{ .success, .interior_links, .cancel_before_worker, .partial_retry, .registry_failure, .malformed_receipt, .java_symlink, .java_hardlink }) |case| {
        if (builtin.os.tag == .windows and (case == .interior_links or case == .java_symlink)) continue;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try fixtureRoot(&tmp);
        defer a.free(root);
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var manager = try java.Manager.init(a, io, root);
        defer manager.deinit();
        var fixture: Fixture = .{};
        var controller = try Controller.initWithOptions(a, io, .{ .root = root, .task_registry = &registry, .transport = fixture.transport(), .extractor = fixture.extractor(), .probe = fixture.probe() });
        defer controller.deinit();
        try controller.start(.{ .vendor = .microsoft, .major = 21 });
        try awaitController(&controller, &manager);
        const path = try a.dupe(u8, controller.snapshot().installed.?.java_path);
        defer a.free(path);
        const directory_path = try a.dupe(u8, controller.snapshot().installed.?.directory);
        defer a.free(directory_path);
        try std.testing.expectEqual(@as(usize, 1), manager.entries().len);
        try std.testing.expect(!controller.isDeleting() and !controller.isBusy());
        try controller.checkOwnedStorage(path);

        const sibling = try std.fmt.allocPrint(a, "{s}-sibling/runtime/bin/java", .{controller.root});
        defer a.free(sibling);
        try std.testing.expectError(error.NotOwnedJava, controller.beginOwnedDelete(sibling));
        const traversal = try std.fs.path.join(a, &.{ controller.root, "runtime", "..", "bin", "java" });
        defer a.free(traversal);
        try std.testing.expectError(error.UnsafeOwnedPath, controller.beginOwnedDelete(traversal));
        const mismatched_java = try std.fmt.allocPrint(a, "{s}.other", .{path});
        defer a.free(mismatched_java);
        try std.testing.expectError(error.NotOwnedJava, controller.beginOwnedDelete(mismatched_java));
        try std.testing.expectEqual(Phase.idle, controller.ownedDeleteSnapshot().phase);

        const directory = try Io.Dir.cwd().openDir(io, directory_path, .{});
        defer directory.close(io);
        if (case == .malformed_receipt) {
            const receipt = try directory.createFile(io, ".vela-runtime.json", .{});
            try receipt.writeStreamingAll(io, "{}");
            receipt.close(io);
            if (controller.beginOwnedDelete(path)) |_| return error.MalformedReceiptAccepted else |_| {}
            try std.testing.expectEqual(@as(usize, 1), manager.entries().len);
            try std.testing.expectEqual(Phase.idle, controller.ownedDeleteSnapshot().phase);
            const java_file = try Io.Dir.cwd().openFile(io, path, .{});
            java_file.close(io);
            continue;
        }
        if (case == .java_hardlink) {
            try Io.Dir.cwd().hardLink(path, tmp.dir, "external-hardlink", io, .{});
            try std.testing.expectError(error.UnsafeOwnedLink, controller.beginOwnedDelete(path));
            try std.testing.expectEqual(@as(usize, 1), manager.entries().len);
            continue;
        }
        const outside = try std.fs.path.join(a, &.{ root, "outside-java" });
        defer a.free(outside);
        if (case == .interior_links or case == .java_symlink) {
            const external = try tmp.dir.createFile(io, "outside-java", .{});
            try external.writeStreamingAll(io, "must survive owned deletion");
            external.close(io);
            if (case == .java_symlink) {
                try Io.Dir.cwd().deleteFile(io, path);
                try Io.Dir.cwd().symLink(io, outside, path, .{});
                try std.testing.expectError(error.UnsafeOwnedLink, controller.beginOwnedDelete(path));
                try std.testing.expectEqual(@as(usize, 1), manager.entries().len);
                continue;
            }
            try directory.symLink(io, outside, "outside-file-link", .{});
            // A link to the launcher directory must never be recursively followed.
            try directory.symLink(io, root, "outside-directory-link", .{ .is_directory = true });
        }
        if (case == .registry_failure) {
            try tmp.dir.deleteFile(io, ".vela/java.json");
            try tmp.dir.createDir(io, ".vela/java.json", .default_dir);
        }
        if (case == .partial_retry) {
            // Model cancellation after a leaf unlink: ownership proof remains in place.
            try Io.Dir.cwd().deleteFile(io, path);
            try startCanceledOwnedDelete(&controller, path);
            try awaitFlag(&controller.active_delete.?.done);
            try std.testing.expect(controller.isDeleting() and controller.isBusy());
            controller.cancelAndJoin(&manager);
            try std.testing.expect(!controller.isDeleting() and !controller.isBusy());
            try std.testing.expectEqual(Phase.canceled, controller.ownedDeleteSnapshot().phase);
            try std.testing.expect(!controller.ownedDeleteSnapshot().files_deleted);
            try std.testing.expectEqual(@as(usize, 1), manager.entries().len);
            const proof = try directory.statFile(io, ".vela-runtime.json", .{ .follow_symlinks = false });
            try std.testing.expectEqual(Io.File.Kind.file, proof.kind);
            try controller.checkOwnedStorage(path);
        }
        if (case == .cancel_before_worker) {
            try startCanceledOwnedDelete(&controller, path);
        } else {
            try controller.beginOwnedDelete(path);
        }
        try std.testing.expectError(error.Busy, controller.start(.{ .vendor = .microsoft, .major = 21 }));
        try std.testing.expectError(error.Busy, controller.beginOwnedDelete(path));
        try std.testing.expect(controller.isDeleting() and controller.isBusy());
        const job = controller.active_delete.?;
        try awaitFlag(&job.done);
        try std.testing.expect(controller.isDeleting() and controller.isBusy());
        // A finished worker still cannot publish state until its owner joins it.
        try std.testing.expectEqual(Phase.running, controller.ownedDeleteSnapshot().phase);
        try std.testing.expect(!controller.ownedDeleteSnapshot().files_deleted);
        try std.testing.expectEqual(@as(usize, 1), manager.entries().len);
        if (case == .cancel_before_worker) controller.tick(&manager) else controller.cancelAndJoin(&manager);
        try std.testing.expect(controller.active_delete == null and job.thread == null);
        try std.testing.expect(!controller.isDeleting() and !controller.isBusy());
        const result = controller.ownedDeleteSnapshot();
        if (case == .cancel_before_worker) {
            try std.testing.expectEqual(Phase.canceled, result.phase);
            try std.testing.expect(!result.files_deleted);
            try std.testing.expectEqual(error.Canceled, result.failure.?);
            try std.testing.expectEqual(@as(usize, 1), manager.entries().len);
            try controller.checkOwnedStorage(path);
        } else {
            try std.testing.expect(result.files_deleted);
            try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, directory_path, .{ .follow_symlinks = false }));
            if (case == .registry_failure) {
                try std.testing.expectEqual(Phase.failed, result.phase);
                try std.testing.expect(result.registry_failure != null and result.failure != null);
                try std.testing.expectEqual(@as(usize, 1), manager.entries().len);
            } else {
                try std.testing.expectEqual(Phase.complete, result.phase);
                try std.testing.expect(result.failure == null and result.registry_failure == null);
                try std.testing.expectEqual(@as(usize, 0), manager.entries().len);
                var reloaded = try java.Manager.init(a, io, root);
                defer reloaded.deinit();
                try std.testing.expectEqual(@as(usize, 0), reloaded.entries().len);
            }
            if (case == .interior_links) {
                const external = try tmp.dir.openFile(io, "outside-java", .{});
                defer external.close(io);
                var bytes: [64]u8 = undefined;
                const n = try external.readPositionalAll(io, &bytes, 0);
                try std.testing.expectEqualStrings("must survive owned deletion", bytes[0..n]);
                try std.testing.expectEqual(Io.File.Kind.directory, (try tmp.dir.stat(io)).kind);
            }
        }
        controller.tick(&manager);
        try std.testing.expectEqual(result.phase, controller.ownedDeleteSnapshot().phase);
    }
}

fn startCanceledOwnedDelete(controller: *Controller, path: []const u8) !void {
    // An already-canceled real worker makes cancellation tests independent of scheduling.
    const job = try worker_allocator.create(DeleteJob);
    job.* = .{ .io = controller.io };
    errdefer job.destroy();
    job.root = try job.arena.allocator().dupe(u8, controller.root);
    job.java_path = try job.arena.allocator().dupe(u8, path);
    controller.active_delete = job;
    controller.delete_phase = .running;
    errdefer {
        controller.active_delete = null;
        controller.delete_phase = .idle;
    }
    try std.testing.expect(controller.isDeleting() and controller.isBusy());
    controller.cancel();
    try std.testing.expect(job.cancel.load(.acquire));
    try std.testing.expect(controller.isDeleting() and controller.isBusy());
    job.thread = try std.Thread.spawn(.{}, DeleteJob.run, .{job});
}

test "owned delete admission rejects before ownership allocation tasks or filesystem changes and permits retry" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Admission = struct {
        blocked: bool = true,
        checks: usize = 0,
        fn check(raw: ?*anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.checks += 1;
            if (self.blocked) return error.JavaDeletionBlocked;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer a.free(root);
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var manager = try java.Manager.init(a, io, root);
    defer manager.deinit();
    var fixture: Fixture = .{};
    var admission: Admission = .{};
    var controller = try Controller.initWithOptions(a, io, .{
        .root = root,
        .task_registry = &registry,
        .transport = fixture.transport(),
        .extractor = fixture.extractor(),
        .probe = fixture.probe(),
        .owned_delete_admission = .{ .context = &admission, .check = Admission.check },
    });
    defer controller.deinit();
    // The admission applies only to owned deletion; downloads remain available.
    try controller.start(.{ .vendor = .microsoft, .major = 21 });
    try awaitController(&controller, &manager);
    const downloaded = controller.published.?;
    const path = try a.dupe(u8, controller.snapshot().installed.?.java_path);
    defer a.free(path);
    const task_count = registry.tasks().len;
    try std.testing.expectEqual(@as(usize, 0), admission.checks);
    try std.testing.expectError(error.JavaDeletionBlocked, controller.beginOwnedDelete(path));
    // Invalid paths still return admission failure, before filesystem ownership checks.
    try std.testing.expectError(error.JavaDeletionBlocked, controller.beginOwnedDelete("invalid-owned-path"));
    try std.testing.expectEqual(@as(usize, 2), admission.checks);
    try std.testing.expect(!controller.isBusy() and !controller.isDeleting());
    try std.testing.expect(controller.active_delete == null and controller.published_delete == null);
    try std.testing.expectEqual(Phase.idle, controller.ownedDeleteSnapshot().phase);
    try std.testing.expect(controller.published.? == downloaded);
    try std.testing.expectEqual(Phase.complete, controller.snapshot().phase);
    try std.testing.expect(controller.snapshot().registered);
    try std.testing.expectEqual(task_count, registry.tasks().len);
    try std.testing.expectEqual(@as(usize, 1), manager.entries().len);
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    file.close(io);
    try controller.checkOwnedStorage(path);
    admission.blocked = false;
    try controller.beginOwnedDelete(path);
    try std.testing.expectEqual(@as(usize, 3), admission.checks);
    // Own busy wins without consulting the application admission again.
    try std.testing.expectError(error.Busy, controller.beginOwnedDelete(path));
    try std.testing.expectEqual(@as(usize, 3), admission.checks);
    try awaitFlag(&controller.active_delete.?.done);
    controller.tick(&manager);
    try std.testing.expect(!controller.isBusy() and !controller.isDeleting());
    try std.testing.expect(controller.ownedDeleteSnapshot().files_deleted);
    try std.testing.expectEqual(@as(usize, 0), manager.entries().len);
}

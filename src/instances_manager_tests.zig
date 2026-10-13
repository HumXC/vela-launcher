const std = @import("std");
const module = @import("ui/instances_manager.zig");
test {
    _ = @import("ui/metadata_http_cache.zig");
}
const config = @import("core/config.zig");
const instances = @import("core/instances.zig");
const tasks = @import("core/tasks.zig");
const loader_install = @import("core/loaders/install.zig");
const loaders = @import("core/loaders/root.zig");
const metadata = @import("core/minecraft/metadata/root.zig");
const metadata_loader = @import("core/minecraft/metadata_loader.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const Instance = config.Instance;
const example: Instance = .{ .id = "instance-owned", .name = "Owned", .minecraft_version = "1.20.1" };

const Environment = struct {
    tmp: std.testing.TmpDir,
    root: [:0]const u8,
    paths: instances.Paths,
    store: config.Store,
    store_open: bool = true,
    fn init() !Environment {
        return initWithStoreIo(io);
    }
    fn initWithStoreIo(store_io: std.Io) !Environment {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        errdefer a.free(root);
        var paths = try instances.Paths.init(a, io, root);
        errdefer paths.deinit();
        return .{ .tmp = tmp, .root = root, .paths = paths, .store = try config.Store.init(a, store_io, root) };
    }
    fn reloadStore(self: *Environment) !void {
        self.store.deinit();
        self.store_open = false;
        self.store = try config.Store.init(a, io, self.root);
        self.store_open = true;
    }
    fn deinit(self: *Environment) void {
        if (self.store_open) self.store.deinit();
        self.paths.deinit();
        a.free(self.root);
        self.tmp.cleanup();
    }
};
const Fixture = struct {
    held: std.atomic.Value(bool) = .init(false),
    entered: std.atomic.Value(bool) = .init(false),
    blocked: std.atomic.Value(bool) = .init(false),
    releases: usize = 0,
    failure: ?anyerror = null,
    telemetry: bool = false,
    recheck_failure: ?anyerror = null,
    rechecks: usize = 0,
    observed_java: [64]u8 = @splat(0),
    observed_prepared: ?*const loader_install.PreparedMetadata = null,
    observed_vanilla_prepared: ?*const metadata_loader.PreparedVanilla = null,
    observed_generation: u64 = 0,
    fn acquire(raw: ?*anyopaque, _: []const u8) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        if (self.held.swap(true, .acq_rel)) return error.InstanceBusy;
    }
    fn recheck(raw: ?*anyopaque, _: []const u8) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        self.rechecks += 1;
        if (self.recheck_failure) |err| return err;
        if (!self.held.load(.acquire)) return error.LeaseLost;
    }
    fn release(raw: ?*anyopaque, _: []const u8) void {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        std.debug.assert(self.held.swap(false, .acq_rel));
        self.releases += 1;
    }
    fn lease(self: *Fixture) @import("core/content_install.zig").Lease {
        return .{ .context = self, .acquire = acquire, .recheck = recheck, .release = release };
    }
    fn run(raw: ?*anyopaque, alloc: std.mem.Allocator, worker_io: std.Io, request: module.CreateRequest, control: module.Control) !module.Installed {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        self.observed_prepared = request.prepared;
        self.observed_vanilla_prepared = request.vanilla_prepared;
        self.observed_generation = request.prepared_generation;
        if (self.telemetry) if (control.task) |task| {
            var details: tasks.Details = .{ .stage = .downloading, .completed = 0, .total = 2, .received = 64, .total_bytes = 128, .bytes_per_second = 512 };
            var path = [_]u8{ '/', 't', '/', 'l', 'i', 'b', '.', 'j', 'a', 'r' };
            details.addFile(tasks.File.init(&path, 64, 128, 512, .downloading, null));
            @memset(&path, 'z');
            task.reportDetails(details);
        };
        self.entered.store(true, .release);
        while (self.blocked.load(.acquire)) {
            try control.check();
            try worker_io.sleep(.fromMilliseconds(1), .awake);
        }
        try control.check();
        try request.lease.recheck(request.lease.context, request.instance.id);
        if (self.failure) |err| {
            if (self.telemetry) if (control.task) |task| {
                var details = task.details();
                details.files[0].state = .failed;
                details.files[0].failure = err;
                details.stop();
                task.reportDetails(details);
            };
            return err;
        }
        if (request.installer_java) |java| @memcpy(self.observed_java[0..@min(java.len, self.observed_java.len)], java[0..@min(java.len, self.observed_java.len)]);
        control.report(.verifying, 1, 1);
        return module.Installed.init(alloc, request.instance);
    }
    fn catalogue(_: ?*anyopaque, alloc: std.mem.Allocator, _: std.Io, base: []const u8, kind: config.Loader, control: module.Control) !module.LoaderCatalogue {
        try control.check();
        var arena: std.heap.ArenaAllocator = .init(alloc);
        errdefer arena.deinit();
        const g = arena.allocator();
        const entries = try g.alloc(module.LoaderEntry, 1);
        entries[0] = .{ .id = try g.dupe(u8, "0.15.11"), .stable = true };
        const owned_base = try g.dupe(u8, base);
        return .{ .arena = arena, .base = owned_base, .kind = kind, .entries = entries };
    }
    fn installer(self: *Fixture) module.Installer {
        return .{ .context = self, .run = run };
    }
};
fn waitEntered(fixture: *Fixture) !void {
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    while (!fixture.entered.load(.acquire)) {
        if (std.Io.Clock.awake.now(io).nanoseconds - start > 3 * std.time.ns_per_s) return error.FixtureTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}
fn settle(manager: *module.Manager) !void {
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    while (manager.snapshot().phase == .working) {
        manager.tick();
        if (std.Io.Clock.awake.now(io).nanoseconds - start > 3 * std.time.ns_per_s) return error.FixtureTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

// Only Store uses this wrapper; workers keep the real test Io and userdata.
const PublicationFaultIo = struct {
    threadlocal var active: ?*PublicationFaultIo = null;
    real: std.Io = std.testing.io,
    vtable: std.Io.VTable = undefined,
    syncs: usize = 0,
    renames: usize = 0,
    writes: usize = 0,
    fail_sync: ?usize = null,
    gate_checks: usize = 0,
    gate_unavailable: usize = 0,
    require_namespace: bool = false,
    namespace_checks: usize = 0,
    namespace_unavailable: usize = 0,
    stats: usize = 0,
    opens: usize = 0,

    const Counts = struct { syncs: usize, renames: usize, writes: usize };

    fn start(self: *PublicationFaultIo) std.Io {
        std.debug.assert(active == null);
        active = self;
        self.vtable = self.real.vtable.*;
        self.vtable.fileSync = sync;
        self.vtable.dirRename = rename;
        self.vtable.operate = operate;
        self.vtable.fileStat = stat;
        self.vtable.dirOpenFile = open;
        return .{ .userdata = self.real.userdata, .vtable = &self.vtable };
    }
    fn stop(self: *PublicationFaultIo) void {
        std.debug.assert(active == self);
        active = null;
    }
    fn reset(self: *PublicationFaultIo) void {
        self.syncs = 0;
        self.renames = 0;
        self.writes = 0;
        self.fail_sync = null;
        self.gate_checks = 0;
        self.gate_unavailable = 0;
        self.namespace_checks = 0;
        self.namespace_unavailable = 0;
        self.stats = 0;
        self.opens = 0;
    }
    fn counts(self: *const PublicationFaultIo) Counts {
        return .{ .syncs = self.syncs, .renames = self.renames, .writes = self.writes };
    }
    fn probe(self: *PublicationFaultIo) void {
        const gate = &@import("core/worlds.zig").transaction_gate;
        self.gate_checks += 1;
        if (gate.tryLock()) gate.unlock(self.real) else self.gate_unavailable += 1;
        if (self.require_namespace) {
            self.namespace_checks += 1;
            if (@import("core/instance_namespace.zig").acquire(self.real)) |token| {
                token.release();
                self.namespace_unavailable += 1;
            } else |err| {
                if (err != error.InstanceNamespaceBusy) self.namespace_unavailable += 1;
            }
        }
    }
    fn stat(ctx: ?*anyopaque, file: std.Io.File) std.Io.File.StatError!std.Io.File.Stat {
        const self = active.?;
        self.probe();
        self.stats += 1;
        return self.real.vtable.fileStat(ctx, file);
    }
    fn open(ctx: ?*anyopaque, dir: std.Io.Dir, path: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
        const self = active.?;
        self.probe();
        self.opens += 1;
        return self.real.vtable.dirOpenFile(ctx, dir, path, options);
    }
    fn expectPublicationProtected(self: *const PublicationFaultIo) !void {
        try std.testing.expect(self.gate_checks > 0 and self.namespace_checks > 0);
        try std.testing.expectEqual(@as(usize, 0), self.gate_unavailable);
        try std.testing.expectEqual(@as(usize, 0), self.namespace_unavailable);
    }
    fn sync(ctx: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
        const self = active.?;
        self.probe();
        self.syncs += 1;
        if (self.fail_sync == self.syncs) return error.InputOutput;
        return self.real.vtable.fileSync(ctx, file);
    }
    fn rename(ctx: ?*anyopaque, old_dir: std.Io.Dir, old_path: []const u8, new_dir: std.Io.Dir, new_path: []const u8) std.Io.Dir.RenameError!void {
        const self = active.?;
        self.probe();
        self.renames += 1;
        return self.real.vtable.dirRename(ctx, old_dir, old_path, new_dir, new_path);
    }
    fn operate(ctx: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
        const self = active.?;
        switch (operation) {
            .file_write_streaming => {
                self.probe();
                self.writes += 1;
            },
            else => {},
        }
        return self.real.vtable.operate(ctx, operation);
    }
};

fn requireSyncFaults() !void {
    const os = @import("builtin").os.tag;
    if (os == .windows or os == .wasi) return error.SkipZigTest;
}

fn expectRetained(manager: *module.Manager, fixture: *Fixture, registry: *tasks.Registry) !void {
    const job = manager.pending orelse return error.ExpectedPendingPublication;
    try std.testing.expect(manager.active == null and job.future == null and job.done.load(.acquire));
    try std.testing.expect(job.leased and job.task != null and registry.hasActive());
    try std.testing.expect(fixture.held.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), fixture.releases);
    try std.testing.expectError(error.InstanceNamespaceBusy, @import("core/instance_namespace.zig").acquire(io));
}

test "instance manager owns queued strings and publishes only after completed join" {
    var env = try Environment.init();
    defer env.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    fixture.blocked.store(true, .release);
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    defer manager.deinit();
    manager.setInstaller(fixture.installer());
    var name = "Owned".*;
    var java = "/owned/java".*;
    var project = "project".*;
    var instance = example;
    instance.name = &name;
    instance.java_path = &java;
    instance.origin = .{ .kind = .modrinth, .project_id = &project, .version_id = "release" };
    try manager.startCreate(instance);
    try waitEntered(&fixture);
    @memset(&name, 'x');
    @memset(&java, 'x');
    @memset(&project, 'x');
    try std.testing.expectError(error.Busy, manager.startCreate(example));
    manager.tick();
    try std.testing.expectEqual(module.Phase.working, manager.snapshot().phase);
    try std.testing.expectEqual(@as(usize, 0), env.store.snapshot().instances.len);
    fixture.blocked.store(false, .release);
    try settle(&manager);
    try std.testing.expectEqual(module.Phase.awaiting_publication, manager.snapshot().phase);
    try std.testing.expect(fixture.held.load(.acquire));
    try std.testing.expectEqual(tasks.Stage.finalizing, registry.tasks()[0].progress().stage);
    try manager.publish(&env.store);
    try std.testing.expect(!fixture.held.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), fixture.releases);
    try std.testing.expectEqual(tasks.State.succeeded, registry.tasks()[0].state);
    const saved = env.store.snapshot().instances[0];
    try std.testing.expectEqualStrings("Owned", saved.name);
    try std.testing.expectEqualStrings("/owned/java", saved.java_path.?);
    try std.testing.expectEqualStrings("project", saved.origin.?.project_id);
    try std.testing.expectEqualStrings(example.id, env.store.snapshot().selected_instance.?);
    try std.testing.expectEqualStrings("/owned/java", std.mem.sliceTo(&fixture.observed_java, 0));
    manager.setLoaderCatalogue(.{ .fetch = Fixture.catalogue });
    try manager.loadLoaders("1.20.1", .fabric);
    try settle(&manager);
    try std.testing.expectEqual(module.Operation.loading_loaders, manager.snapshot().operation);
    try std.testing.expect(manager.snapshot().instance == null);
    try std.testing.expectEqualStrings("0.15.11", manager.loaderSnapshot().entries[0].id);
}

test "instance manager pre-rename config failure reconciles baseline before explicit retry" {
    try requireSyncFaults();
    var fault: PublicationFaultIo = .{};
    const store_io = fault.start();
    defer fault.stop();
    var env = try Environment.initWithStoreIo(store_io);
    defer env.deinit();
    try env.store.update(env.store.snapshot().*);
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    defer manager.deinit();
    manager.setInstaller(fixture.installer());
    try manager.startCreate(example);
    try settle(&manager);
    const job = manager.pending.?;
    fault.reset();
    fault.require_namespace = true;
    fault.fail_sync = 1;
    try std.testing.expectError(error.InputOutput, manager.publish(&env.store));
    try fault.expectPublicationProtected();
    try std.testing.expect(fault.writes > 0 and fault.syncs > 0);
    try std.testing.expect(env.store.publicationUncertain());
    try std.testing.expect(job.uncertain_publication_store == &env.store);
    try std.testing.expectEqual(@as(usize, 0), fault.renames);
    try expectRetained(&manager, &fixture, &registry);
    const blocked = fault.counts();
    try std.testing.expectError(error.ConfigPublicationUncertain, manager.publish(&env.store));
    try std.testing.expectError(error.ConfigPublicationUncertain, manager.acknowledgeReconciledCreation(&env.store));
    try std.testing.expectEqualDeep(blocked, fault.counts());
    fault.reset();
    try env.store.reconcile();
    try std.testing.expectEqual(@as(usize, 0), env.store.snapshot().instances.len);
    const reconciled = fault.counts();
    try std.testing.expectError(error.InstanceConfigurationChanged, manager.acknowledgeReconciledCreation(&env.store));
    try std.testing.expectEqualDeep(reconciled, fault.counts());
    try expectRetained(&manager, &fixture, &registry);
    try std.testing.expect(manager.pending.? == job);
    try manager.publish(&env.store);
    try std.testing.expectEqual(@as(usize, 1), env.store.snapshot().instances.len);
    try std.testing.expectEqual(@as(usize, 1), fixture.releases);
    try std.testing.expect(!registry.hasActive() and !manager.isBusy());
    try std.testing.expectEqual(tasks.State.succeeded, registry.tasks()[0].state);
}

test "instance manager acknowledges its reconciled creation once without rewriting latest config" {
    try requireSyncFaults();
    var fault: PublicationFaultIo = .{};
    const store_io = fault.start();
    defer fault.stop();
    var env = try Environment.initWithStoreIo(store_io);
    defer env.deinit();
    const other: Instance = .{ .id = "other", .name = "Other", .minecraft_version = "1.20.1" };
    try env.store.update(.{
        .instances = &.{other},
        .servers = &.{.{ .id = "other-server", .name = "Other server", .address = "localhost", .instance_id = other.id }},
        .selected_instance = other.id,
        .selected_server = "other-server",
    });
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    var manager_live = true;
    defer if (manager_live) manager.deinit();
    manager.setInstaller(fixture.installer());
    try manager.startCreate(example);
    try settle(&manager);
    const job = manager.pending.?;
    fault.reset();
    fault.require_namespace = true;
    fault.fail_sync = 3;
    try std.testing.expectError(error.InputOutput, manager.publish(&env.store));
    try fault.expectPublicationProtected();
    try std.testing.expect(fault.writes > 0 and fault.syncs > 0 and fault.renames > 0);
    try std.testing.expectEqual(@as(usize, 1), fault.renames);
    try std.testing.expectEqual(@as(usize, 1), env.store.snapshot().instances.len);
    try expectRetained(&manager, &fixture, &registry);
    fault.reset();
    fault.fail_sync = 1;
    try std.testing.expectError(error.InputOutput, env.store.reconcile());
    const blocked = fault.counts();
    try std.testing.expectError(error.ConfigPublicationUncertain, manager.acknowledgeReconciledCreation(&env.store));
    try std.testing.expectEqualDeep(blocked, fault.counts());
    try expectRetained(&manager, &fixture, &registry);
    fault.reset();
    try env.store.reconcile();
    try std.testing.expectEqual(@as(usize, 2), env.store.snapshot().instances.len);
    try std.testing.expectError(error.DuplicateId, manager.publish(&env.store));
    try std.testing.expect(manager.pending.? == job);
    var latest = env.store.snapshot().*;
    latest.settings.default_memory_mb = 8192;
    latest.selected_instance = other.id;
    latest.selected_server = "other-server";
    try env.store.update(latest);
    const bytes = try std.json.Stringify.valueAlloc(a, env.store.snapshot().*, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    defer a.free(bytes);
    const counts = fault.counts();
    const rechecks = fixture.rechecks;
    job.task.?.cancellation.store(true, .release);
    try manager.acknowledgeReconciledCreation(&env.store);
    try std.testing.expectEqualDeep(counts, fault.counts());
    try std.testing.expectEqual(rechecks + 1, fixture.rechecks);
    try std.testing.expectEqual(@as(usize, 1), fixture.releases);
    try std.testing.expect(!fixture.held.load(.acquire) and !manager.isBusy() and !registry.hasActive());
    try std.testing.expectEqual(module.Phase.complete, manager.snapshot().phase);
    try std.testing.expect(manager.snapshot().failure == null);
    try std.testing.expectEqual(tasks.State.succeeded, registry.tasks()[0].state);
    const after = try std.json.Stringify.valueAlloc(a, env.store.snapshot().*, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    defer a.free(after);
    try std.testing.expectEqualStrings(bytes, after);
    try std.testing.expectError(error.NoPendingPublication, manager.acknowledgeReconciledCreation(&env.store));
    try std.testing.expectEqualDeep(counts, fault.counts());
    manager.deinit();
    manager_live = false;
    try std.testing.expectEqual(@as(usize, 1), fixture.releases);
}

test "instance manager external exact rows and preexisting uncertainty cannot forge acknowledgment evidence" {
    try requireSyncFaults();
    for ([_]bool{ false, true }) |uncertain| {
        var fault: PublicationFaultIo = .{};
        const store_io = fault.start();
        defer fault.stop();
        var env = try Environment.initWithStoreIo(store_io);
        defer env.deinit();
        try env.store.update(env.store.snapshot().*);
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var fixture: Fixture = .{};
        var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
        defer manager.deinit();
        manager.setInstaller(fixture.installer());
        try manager.startCreate(example);
        try settle(&manager);
        const job = manager.pending.?;
        const forged: config.Document = .{ .instances = &.{example}, .selected_instance = example.id };
        fault.reset();
        if (uncertain) {
            fault.fail_sync = 3;
            try std.testing.expectError(error.InputOutput, env.store.update(forged));
            const blocked = fault.counts();
            try std.testing.expectError(error.ConfigPublicationUncertain, manager.publish(&env.store));
            try std.testing.expectEqualDeep(blocked, fault.counts());
            fault.reset();
            try env.store.reconcile();
        } else {
            try env.store.update(forged);
            try std.testing.expectError(error.DuplicateId, manager.publish(&env.store));
        }
        try std.testing.expect(job.uncertain_publication_store == null);
        try std.testing.expectEqualStrings(example.id, env.store.snapshot().instances[0].id);
        const counts = fault.counts();
        try std.testing.expectError(error.NoOwnedPublicationUncertainty, manager.acknowledgeReconciledCreation(&env.store));
        try std.testing.expectEqualDeep(counts, fault.counts());
        try expectRetained(&manager, &fixture, &registry);
        try std.testing.expect(manager.pending.? == job);
    }
}

test "instance manager cancel does not join worker and shutdown drains active task" {
    var env = try Environment.init();
    defer env.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    fixture.blocked.store(true, .release);
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    manager.setInstaller(fixture.installer());
    try manager.startCreate(example);
    try waitEntered(&fixture);
    const active = manager.active;
    manager.cancel();
    try std.testing.expect(manager.active == active);
    try settle(&manager);
    try std.testing.expectEqual(module.Phase.canceled, manager.snapshot().phase);
    try std.testing.expectEqual(tasks.State.canceled, registry.tasks()[0].state);
    try std.testing.expect(!fixture.held.load(.acquire));
    manager.deinit();
    fixture.entered.store(false, .release);
    manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    manager.setInstaller(fixture.installer());
    try manager.startCreate(example);
    try waitEntered(&fixture);
    manager.deinit();
    try std.testing.expect(!registry.hasActive());
    try std.testing.expect(!fixture.held.load(.acquire));
}

test "instance manager pins recovery required and never publishes uncertain filesystem result" {
    var env = try Environment.init();
    defer env.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{ .failure = error.RecoveryRequired };
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    manager.setInstaller(fixture.installer());
    try manager.startCreate(example);
    try settle(&manager);
    try std.testing.expectEqual(module.Phase.failed, manager.snapshot().phase);
    try std.testing.expect(manager.isBusy());
    try std.testing.expect(fixture.held.load(.acquire));
    try std.testing.expectError(error.RecoveryRequired, manager.publish(&env.store));
    try std.testing.expectError(error.RecoveryRequired, manager.acknowledgeReconciledCreation(&env.store));
    try std.testing.expectEqual(@as(usize, 0), env.store.snapshot().instances.len);
    manager.deinit();
    try std.testing.expectEqual(@as(usize, 1), fixture.releases);
}

fn editableFixture(dir: std.Io.Dir) !void {
    try dir.createDirPath(io, ".minecraft/versions/1.21");
    try dir.createDirPath(io, ".minecraft/versions/Play/saves/World");
    try dir.createDirPath(io, ".minecraft/versions/Play/config");
    try dir.writeFile(io, .{ .sub_path = ".minecraft/versions/1.21/1.21.json", .data = "{\"id\":\"1.21\",\"mainClass\":\"net.minecraft.client.main.Main\",\"downloads\":{\"client\":{\"url\":\"https://example.invalid/client\",\"size\":4}},\"arguments\":{\"game\":[],\"jvm\":[]}}" });
    try dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Play/Play.json", .data = "{\"id\":\"Play\",\"inheritsFrom\":\"1.21\"}" });
    try dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Play/saves/World/level.dat", .data = "world" });
    try dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Play/config/options.txt", .data = "options" });
}

// Transaction recovery is deliberately sealed; restore only test directories for cleanup.
fn writableFixture(dir: std.Io.Dir) void {
    dir.setPermissions(io, .fromMode(0o700)) catch return;
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch continue;
        if (stat.kind != .directory) continue;
        const child = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
        defer child.close(io);
        writableFixture(child);
    }
}

const editable: config.Instance = .{ .id = "stable-editable", .name = "Play", .minecraft_version = "1.21", .java_path = "/old/java", .max_memory_mb = 2048, .origin = .{ .kind = .modrinth, .project_id = "project", .version_id = "release" } };

test "combined rename options publishes one complete config update after JOIN and retries as one result" {
    try requireSyncFaults();
    for ([_]bool{ false, true }) |fail_first| {
        var env = try Environment.init();
        defer env.deinit();
        defer writableFixture(env.tmp.dir);
        try editableFixture(env.tmp.dir);
        try env.store.update(.{ .instances = &.{editable}, .selected_instance = editable.id, .servers = &.{.{ .id = "bound", .name = "Bound server", .address = "localhost", .instance_id = editable.id }}, .selected_server = "bound" });
        var registry = tasks.Registry.init(std.testing.allocator);
        defer registry.deinit();
        var fixture: Fixture = .{};
        var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
        defer manager.deinit();
        var updated = editable;
        updated.name = "New Play";
        updated.java_path = "/new/java";
        updated.min_memory_mb = 2048;
        updated.max_memory_mb = 8192;
        updated.debug_launch = true;
        try manager.startRenameWithOptions(editable, updated);
        try settle(&manager);
        try std.testing.expectEqual(module.Phase.awaiting_publication, manager.snapshot().phase);
        const job = manager.pending orelse return error.ExpectedPendingPublication;
        try std.testing.expect(job.future == null and job.done.load(.acquire));
        try std.testing.expect(module.sameInstance(editable, job.request));
        try std.testing.expect(module.sameInstance(updated, job.result.?.instance));
        try std.testing.expect(module.sameInstance(editable, env.store.snapshot().instances[0]));
        try std.testing.expectError(error.FileNotFound, env.tmp.dir.access(io, ".minecraft/versions/Play", .{}));
        try env.tmp.dir.access(io, ".minecraft/versions/New Play/New Play.json", .{});
        const world = try env.tmp.dir.readFileAlloc(io, ".minecraft/versions/New Play/saves/World/level.dat", std.testing.allocator, .limited(1024));
        defer std.testing.allocator.free(world);
        try std.testing.expectEqualStrings("world", world);
        var fault: PublicationFaultIo = .{ .require_namespace = true };
        env.store.io = fault.start();
        defer fault.stop();
        if (fail_first) {
            fault.fail_sync = 1;
            try std.testing.expectError(error.InputOutput, manager.publish(&env.store));
            try std.testing.expect(module.sameInstance(editable, env.store.snapshot().instances[0]));
            try expectRetained(&manager, &fixture, &registry);
            try fault.expectPublicationProtected();
            fault.reset();
            try std.testing.expect(env.store.publicationUncertain());
            try env.store.reconcile();
            try std.testing.expect(module.sameInstance(editable, env.store.snapshot().instances[0]));
            fault.reset();
        }
        try manager.publish(&env.store);
        try std.testing.expectEqual(module.Phase.complete, manager.snapshot().phase);
        try std.testing.expect(manager.pending == null and !registry.hasActive());
        try std.testing.expect(module.sameInstance(updated, env.store.snapshot().instances[0]));
        try std.testing.expectEqualStrings(editable.id, env.store.snapshot().selected_instance.?);
        try std.testing.expectEqualStrings(editable.id, env.store.snapshot().servers[0].instance_id);
        try std.testing.expectEqualStrings("bound", env.store.snapshot().selected_server.?);
        try std.testing.expectEqualStrings("project", env.store.snapshot().instances[0].origin.?.project_id);
        try std.testing.expectEqual(@as(usize, 1), fault.renames);
        try std.testing.expectEqual(@as(usize, 1), fixture.releases);
        try fault.expectPublicationProtected();
    }
}

test "checked options save rejects stale launch fields before acquiring lease or publishing" {
    var env = try Environment.init();
    defer env.deinit();
    try env.store.update(.{ .instances = &.{editable} });
    var fixture: Fixture = .{};
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    defer manager.deinit();
    var stale = editable;
    stale.debug_launch = true;
    var updated = editable;
    updated.java_path = "/new/java";
    try std.testing.expectError(error.InstanceConfigurationChanged, manager.saveOptionsChecked(&env.store, stale, updated));
    try std.testing.expect(!fixture.held.load(.acquire) and fixture.releases == 0);
    try std.testing.expect(module.sameInstance(editable, env.store.snapshot().instances[0]));
    try manager.saveOptionsChecked(&env.store, editable, updated);
    try std.testing.expect(module.sameInstance(updated, env.store.snapshot().instances[0]));
    try std.testing.expectEqual(@as(usize, 1), fixture.releases);
}

test "rename publication rejects an external options edit against the original whole config fingerprint" {
    var env = try Environment.init();
    defer env.deinit();
    defer writableFixture(env.tmp.dir);
    try editableFixture(env.tmp.dir);
    try env.store.update(.{ .instances = &.{editable} });
    var fixture: Fixture = .{};
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    defer manager.deinit();
    var updated = editable;
    updated.name = "New Play";
    updated.max_memory_mb = 8192;
    try manager.startRenameWithOptions(editable, updated);
    try settle(&manager);
    @constCast(env.store.state.value.instances)[0].min_memory_mb = 512;
    try std.testing.expectError(error.InstanceConfigurationChanged, manager.publish(&env.store));
    try std.testing.expect(manager.pending != null and fixture.releases == 0);
    try std.testing.expectEqualStrings("Play", env.store.snapshot().instances[0].name);
    try std.testing.expectEqual(@as(?u32, 512), env.store.snapshot().instances[0].min_memory_mb);
    try std.testing.expectEqual(editable.max_memory_mb, env.store.snapshot().instances[0].max_memory_mb);
    try std.testing.expectEqual(editable.debug_launch, env.store.snapshot().instances[0].debug_launch);
    try std.testing.expectError(error.InstanceNamespaceBusy, @import("core/instance_namespace.zig").acquire(io));
}

test "minimum heap admission rejects invalid endpoints and reversed explicit pairs without work" {
    var env = try Environment.init();
    defer env.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    defer manager.deinit();
    manager.setInstaller(fixture.installer());
    var invalid = example;
    for ([_]u32{ 0, 255, 1024 * 1024 + 1 }) |minimum| {
        invalid.min_memory_mb = minimum;
        try std.testing.expectError(error.InvalidMemory, manager.startCreate(invalid));
    }
    invalid.min_memory_mb = 4096;
    invalid.max_memory_mb = 2048;
    try std.testing.expectError(error.InvalidMemory, manager.startCreate(invalid));
    try std.testing.expectEqual(module.Phase.idle, manager.snapshot().phase);
    try std.testing.expect(manager.pending == null);
    try std.testing.expect(!fixture.held.load(.acquire));
    try std.testing.expect(!fixture.entered.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), fixture.releases);
    try std.testing.expectEqual(@as(usize, 0), registry.tasks().len);
    try std.testing.expectEqual(@as(usize, 0), env.store.snapshot().instances.len);
    var valid = example;
    valid.min_memory_mb = 256;
    valid.max_memory_mb = 256;
    try manager.startCreate(valid);
    try settle(&manager);
    try manager.publish(&env.store);
    try std.testing.expectEqual(@as(?u32, 256), env.store.snapshot().instances[0].min_memory_mb);
    try std.testing.expectEqual(@as(?u32, 256), env.store.snapshot().instances[0].max_memory_mb);
}

test "checked options save rejects minimum-only stale baseline and can clear minimum" {
    var env = try Environment.init();
    defer env.deinit();
    try env.store.update(.{ .instances = &.{example}, .selected_instance = example.id });
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    defer manager.deinit();
    var stale = example;
    stale.min_memory_mb = 512;
    var updated = example;
    updated.min_memory_mb = 1024;
    try std.testing.expectError(error.InstanceConfigurationChanged, manager.saveOptionsChecked(&env.store, stale, updated));
    try std.testing.expect(!fixture.held.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), fixture.releases);
    try std.testing.expectEqual(@as(?u32, null), env.store.snapshot().instances[0].min_memory_mb);
    try manager.saveOptionsChecked(&env.store, example, updated);
    try std.testing.expectEqual(@as(?u32, 1024), env.store.snapshot().instances[0].min_memory_mb);
    stale = updated;
    updated.min_memory_mb = null;
    try manager.saveOptionsChecked(&env.store, stale, updated);
    try std.testing.expectEqual(@as(?u32, null), env.store.snapshot().instances[0].min_memory_mb);
    try env.reloadStore();
    try std.testing.expectEqual(@as(?u32, null), env.store.snapshot().instances[0].min_memory_mb);
}

test "instance manager options preserve identity and default Java is cloned into worker" {
    var env = try Environment.init();
    defer env.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    defer manager.deinit();
    manager.setInstaller(fixture.installer());
    var java = "/default/java".*;
    try manager.setDefaultJava(&java);
    @memset(&java, 'x');
    try manager.startCreate(example);
    try settle(&manager);
    try manager.publish(&env.store);
    try std.testing.expectEqualStrings("/default/java", std.mem.sliceTo(&fixture.observed_java, 0));
    var updated = env.store.snapshot().instances[0];
    updated.java_path = "/override/java";
    updated.min_memory_mb = 1024;
    updated.max_memory_mb = 4096;
    updated.debug_launch = true;
    try manager.saveOptions(&env.store, updated);
    try std.testing.expectEqual(@as(?u32, 1024), env.store.snapshot().instances[0].min_memory_mb);
    try std.testing.expectEqual(@as(?u32, 4096), env.store.snapshot().instances[0].max_memory_mb);
    // saveOptions replaces the snapshot arena; refresh borrowed identity strings.
    updated = env.store.snapshot().instances[0];
    updated.name = "Different";
    try std.testing.expectError(error.OptionsCannotChangeIdentity, manager.saveOptions(&env.store, updated));
    try manager.select(&env.store, example.id);
    try std.testing.expectError(error.InstanceNotFound, manager.select(&env.store, "absent"));
}

fn allocationFailure(alloc: std.mem.Allocator, paths: *const instances.Paths) !void {
    var registry = tasks.Registry.init(alloc);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var manager = try module.Manager.init(alloc, io, paths, &registry, .{}, fixture.lease());
    defer manager.deinit();
    try manager.setDefaultJava("/default/java");
    manager.setInstaller(fixture.installer());
    try manager.startCreate(example);
    try settle(&manager);
    try std.testing.expectEqual(module.Phase.awaiting_publication, manager.snapshot().phase);
}
test "instance manager allocation failures release cloned requests and any acquired lease" {
    var env = try Environment.init();
    defer env.deinit();
    try @import("test_allocations").checkAllAllocationFailures(a, allocationFailure, .{&env.paths});
}

test "instance manager production callbacks honor pre-cancellation without networking" {
    var env = try Environment.init();
    defer env.deinit();
    var fixture: Fixture = .{};
    var canceled: std.atomic.Value(bool) = .init(true);
    const control: module.Control = .{ .cancel = &canceled };
    const installer = module.productionInstaller();
    try std.testing.expectError(error.Canceled, installer.run(installer.context, a, io, .{ .root = env.root, .instance = example, .lease = fixture.lease() }, control));
    const catalogue = module.productionLoaderCatalogue();
    try std.testing.expectError(error.Canceled, catalogue.fetch(catalogue.context, a, io, "1.20.1", .fabric, control));
    try std.testing.expect(!fixture.held.load(.acquire));
}

test "instance manager acknowledgment retains ownership on Store worker and lease mismatches" {
    try requireSyncFaults();
    var fault: PublicationFaultIo = .{};
    const store_io = fault.start();
    defer fault.stop();
    var env = try Environment.initWithStoreIo(store_io);
    defer env.deinit();
    try env.store.update(env.store.snapshot().*);
    var foreign = try Environment.initWithStoreIo(store_io);
    defer foreign.deinit();
    try foreign.store.update(.{ .instances = &.{example}, .selected_instance = example.id });
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    defer manager.deinit();
    manager.setInstaller(fixture.installer());
    try manager.startCreate(example);
    try settle(&manager);
    const job = manager.pending.?;
    fault.reset();
    const empty = fault.counts();
    try std.testing.expectError(error.ConfigurationStoreChanged, manager.publish(&foreign.store));
    try std.testing.expectEqualDeep(empty, fault.counts());
    try std.testing.expect(job.uncertain_publication_store == null);
    try std.testing.expectError(error.NoOwnedPublicationUncertainty, manager.acknowledgeReconciledCreation(&env.store));
    try expectRetained(&manager, &fixture, &registry);
    fault.fail_sync = 3;
    try std.testing.expectError(error.InputOutput, manager.publish(&env.store));
    fault.reset();
    try env.store.reconcile();
    try std.testing.expectError(error.LauncherRootInUse, config.Store.init(a, io, env.root));
    const counts = fault.counts();
    try std.testing.expectError(error.ConfigurationStoreChanged, manager.acknowledgeReconciledCreation(&foreign.store));
    try std.testing.expectError(error.ConfigurationStoreChanged, manager.publish(&foreign.store));
    {
        const root = env.store.root;
        env.store.root = foreign.root;
        defer env.store.root = root;
        try std.testing.expectError(error.ConfigurationStoreChanged, manager.acknowledgeReconciledCreation(&env.store));
    }
    {
        job.done.store(false, .release);
        defer job.done.store(true, .release);
        try std.testing.expectError(error.PublicationWorkerNotJoined, manager.acknowledgeReconciledCreation(&env.store));
    }
    {
        manager.active = job;
        defer manager.active = null;
        try std.testing.expectError(error.PublicationWorkerNotJoined, manager.acknowledgeReconciledCreation(&env.store));
    }
    for ([_]module.Operation{ .renaming, .deleting }) |operation| {
        job.operation = operation;
        defer job.operation = .creating;
        try std.testing.expectError(error.UnsupportedPublicationAcknowledgment, manager.acknowledgeReconciledCreation(&env.store));
    }
    {
        const installed = job.installed;
        job.installed = null;
        defer job.installed = installed;
        try std.testing.expectError(error.InvalidCompletedPublication, manager.acknowledgeReconciledCreation(&env.store));
    }
    {
        const id = job.installed.?.instance.id;
        job.installed.?.instance.id = "wrong-completed-id";
        defer job.installed.?.instance.id = id;
        try std.testing.expectError(error.InvalidCompletedPublication, manager.acknowledgeReconciledCreation(&env.store));
    }
    {
        job.leased = false;
        defer job.leased = true;
        try std.testing.expectError(error.PublicationLeaseLost, manager.acknowledgeReconciledCreation(&env.store));
    }
    fixture.recheck_failure = error.LeaseLost;
    try std.testing.expectError(error.LeaseLost, manager.acknowledgeReconciledCreation(&env.store));
    fixture.recheck_failure = null;
    try std.testing.expectEqualDeep(counts, fault.counts());
    try std.testing.expect(manager.pending.? == job);
    try expectRetained(&manager, &fixture, &registry);
    try manager.acknowledgeReconciledCreation(&env.store);
    try std.testing.expectEqualDeep(counts, fault.counts());
    try std.testing.expectEqual(@as(usize, 1), fixture.releases);
}

test "instance manager acknowledgment compares all completed row fields and rejects absent or duplicate rows" {
    try requireSyncFaults();
    for (0..12) |change| {
        var fault: PublicationFaultIo = .{};
        const store_io = fault.start();
        defer fault.stop();
        var env = try Environment.initWithStoreIo(store_io);
        defer env.deinit();
        try env.store.update(env.store.snapshot().*);
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var fixture: Fixture = .{};
        var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
        defer manager.deinit();
        manager.setInstaller(fixture.installer());
        var requested = example;
        requested.loader = .fabric;
        requested.loader_version = "0.16.0";
        requested.java_path = "/owned/java";
        requested.max_memory_mb = 4096;
        requested.debug_launch = true;
        requested.origin = .{ .kind = .modrinth, .project_id = "owned-project", .version_id = "owned-version" };
        try manager.startCreate(requested);
        try settle(&manager);
        const job = manager.pending.?;
        fault.reset();
        fault.fail_sync = 3;
        try std.testing.expectError(error.InputOutput, manager.publish(&env.store));
        fault.reset();
        try env.store.reconcile();
        var changed = requested;
        switch (change) {
            0 => changed.name = "Changed",
            1 => changed.minecraft_version = "1.21.5",
            2 => changed.loader = .forge,
            3 => changed.loader_version = "0.17.0",
            4 => changed.java_path = "/changed/java",
            5 => changed.max_memory_mb = 8192,
            6 => changed.debug_launch = false,
            7 => changed.origin.?.kind = .curseforge,
            8 => changed.origin.?.project_id = "changed-project",
            9 => changed.origin.?.version_id = "changed-version",
            10 => changed.origin = null,
            11 => {},
            else => unreachable,
        }
        var latest = env.store.snapshot().*;
        latest.instances = if (change == 11) &.{} else &.{changed};
        if (change == 11) latest.selected_instance = null;
        try env.store.update(latest);
        const counts = fault.counts();
        try std.testing.expectError(error.InstanceConfigurationChanged, manager.acknowledgeReconciledCreation(&env.store));
        try std.testing.expectEqualDeep(counts, fault.counts());
        try std.testing.expect(manager.pending.? == job);
        try expectRetained(&manager, &fixture, &registry);
        if (change == 0) {
            // Valid Store documents forbid duplicates; inject a borrowed view only
            // to exercise the exact-one-row acknowledgment guard, then restore it.
            const snapshot = @constCast(env.store.snapshot());
            const saved = snapshot.instances;
            defer snapshot.instances = saved;
            const duplicate = [_]Instance{ requested, requested };
            snapshot.instances = &duplicate;
            try std.testing.expectError(error.InstanceConfigurationChanged, manager.acknowledgeReconciledCreation(&env.store));
            try std.testing.expectEqualDeep(counts, fault.counts());
            try expectRetained(&manager, &fixture, &registry);
        }
    }
}

test "instance manager creation acknowledgment uses the owned completed value rather than original request" {
    try requireSyncFaults();
    var fault: PublicationFaultIo = .{};
    const store_io = fault.start();
    defer fault.stop();
    var env = try Environment.initWithStoreIo(store_io);
    defer env.deinit();
    try env.store.update(env.store.snapshot().*);
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    defer manager.deinit();
    manager.setInstaller(fixture.installer());
    try manager.startCreate(example);
    try settle(&manager);
    const job = manager.pending.?;
    var completed = example;
    completed.minecraft_version = "1.21.5";
    completed.loader = .fabric;
    completed.loader_version = "0.16.10";
    completed.origin = .{ .kind = .modrinth, .project_id = "imported-project", .version_id = "imported-version" };
    // Preserve the installer-owned completed value after the worker has joined.
    job.installed.?.deinit();
    job.installed = try module.Installed.init(a, completed);
    fault.reset();
    fault.fail_sync = 3;
    try std.testing.expectError(error.InputOutput, manager.publish(&env.store));
    try expectRetained(&manager, &fixture, &registry);
    fault.reset();
    try env.store.reconcile();
    const saved = env.store.snapshot().instances[0];
    try std.testing.expectEqualStrings(completed.minecraft_version, saved.minecraft_version);
    try std.testing.expectEqualStrings(completed.origin.?.project_id, saved.origin.?.project_id);
    try std.testing.expectError(error.DuplicateId, manager.publish(&env.store));
    const counts = fault.counts();
    try manager.acknowledgeReconciledCreation(&env.store);
    try std.testing.expectEqualDeep(counts, fault.counts());
    try std.testing.expectEqual(@as(usize, 1), fixture.releases);
    try std.testing.expectEqual(module.Operation.creating, manager.snapshot().operation);
    try std.testing.expectEqualStrings(completed.minecraft_version, manager.snapshot().instance.?.minecraft_version);
    try std.testing.expectEqual(tasks.State.succeeded, registry.tasks()[0].state);
}

const prepared_example: Instance = .{ .id = "instance-owned", .name = "Owned", .minecraft_version = "1.20.1", .loader = .fabric, .loader_version = "0.16.0" };
const prepared_vanilla_json =
    \\{"id":"1.20.1","mainClass":"vanilla.Main","libraries":[],"javaVersion":{"component":"java-runtime-gamma","majorVersion":17},"downloads":{"client":{"url":"https://piston-data.mojang.com/client.jar","sha1":"0000000000000000000000000000000000000000","size":8}}}
;
const prepared_fabric_json =
    \\{"id":"fabric-fixture","inheritsFrom":"1.20.1","mainClass":"net.fabricmc.loader.impl.launch.knot.KnotClient","libraries":[{"name":"net.fabricmc:fabric-loader:0.16.0","url":"https://maven.fabricmc.net/"}]}
;
fn unusedPreparedMatcher(_: ?*anyopaque, _: []const u8, _: []const u8) anyerror!bool {
    return false;
}
fn preparedEnvironment() !metadata.rules.Environment {
    const target = @import("builtin").target;
    return .{
        .os_name = switch (target.os.tag) {
            .linux => "linux",
            .windows => "windows",
            .macos => "osx",
            else => return error.SkipZigTest,
        },
        .arch = switch (target.cpu.arch) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            .x86 => "x86",
            else => return error.SkipZigTest,
        },
    };
}
const PreparedFixture = struct {
    entries: [1]metadata.manifest.Entry = undefined,
    vanilla_calls: usize = 0,
    loader_calls: usize = 0,
    fn prepare(self: *PreparedFixture, root: []const u8) !loader_install.PreparedMetadata {
        var checksum: metadata.Sha1 = undefined;
        std.crypto.hash.Sha1.hash(prepared_vanilla_json, &checksum, .{});
        self.entries = .{.{ .id = "1.20.1", .kind = "release", .url = "https://piston-meta.mojang.com/v1/packages/fixture/1.20.1.json", .time = "", .release_time = "", .sha1 = checksum, .compliance_level = null }};
        var canceled: std.atomic.Value(bool) = .init(false);
        const minecraft_root = try std.fs.path.join(a, &.{ root, ".minecraft" });
        defer a.free(minecraft_root);
        return loader_install.prepareMetadata(a, io, .{
            .root = root,
            .instance_id = prepared_example.id,
            .instance_name = prepared_example.name,
            .generation = 7,
            .selection = .{ .kind = .fabric, .base_id = prepared_example.minecraft_version, .loader_id = prepared_example.loader_version.? },
            .environment = try preparedEnvironment(),
            .vanilla = .{ .root = minecraft_root, .version_id = "1.20.1", .manifest = .{ .latest = .{ .release = "1.20.1", .snapshot = "1.20.1" }, .versions = &self.entries } },
            .fetcher = .{ .context = self, .fetch = fetchVanilla },
            .transport = .{ .context = self, .get = get },
        }, .{ .cancel = &canceled, .deadline_ms = std.math.maxInt(u64), .now_ms = zeroClock });
    }
    fn prepareVanilla(self: *PreparedFixture, root: []const u8, minecraft_root: []const u8) !metadata_loader.PreparedVanilla {
        var checksum: metadata.Sha1 = undefined;
        std.crypto.hash.Sha1.hash(prepared_vanilla_json, &checksum, .{});
        self.entries = .{.{ .id = "1.20.1", .kind = "release", .url = "https://piston-meta.mojang.com/v1/packages/fixture/1.20.1.json", .time = "", .release_time = "", .sha1 = checksum, .compliance_level = null }};
        return metadata_loader.prepareVanilla(a, io, .{
            .target = .{ .root = root, .instance_id = example.id, .instance_name = example.name, .version_id = example.minecraft_version, .generation = 7, .environment = try preparedEnvironment() },
            .vanilla = .{ .root = minecraft_root, .version_id = "1.20.1", .manifest = .{ .latest = .{ .release = "1.20.1", .snapshot = "1.20.1" }, .versions = &self.entries } },
            .fetcher = .{ .context = self, .fetch = fetchVanilla },
        });
    }
    fn zeroClock(_: ?*anyopaque) u64 {
        return 0;
    }
    fn fetchVanilla(raw: ?*anyopaque, alloc: std.mem.Allocator, _: std.Io, _: metadata_loader.Request) ![]u8 {
        const self: *PreparedFixture = @ptrCast(@alignCast(raw.?));
        self.vanilla_calls += 1;
        return alloc.dupe(u8, prepared_vanilla_json);
    }
    fn get(raw: ?*anyopaque, alloc: std.mem.Allocator, url: []const u8, _: usize, control: loaders.Control) !loaders.Response {
        try control.check();
        const self: *PreparedFixture = @ptrCast(@alignCast(raw.?));
        self.loader_calls += 1;
        const body = if (std.mem.endsWith(u8, url, "/v2/versions/loader/1.20.1"))
            "[{\"loader\":{\"version\":\"0.16.0\",\"stable\":true}}]"
        else if (std.mem.endsWith(u8, url, "/profile/json")) prepared_fabric_json else return error.UnexpectedFixtureRequest;
        const bytes = try alloc.dupe(u8, body);
        errdefer alloc.free(bytes);
        return .{ .status = 200, .bytes = bytes, .final_url = try alloc.dupe(u8, url) };
    }
};
fn expectPreparedRejected(manager: *module.Manager, fixture: *Fixture, registry: *tasks.Registry, instance: Instance, owner: *const loader_install.PreparedMetadata, generation: u64, expected: anyerror) !void {
    try std.testing.expectError(expected, manager.startCreatePrepared(instance, owner, generation));
    try std.testing.expect(manager.active == null and manager.pending == null);
    try std.testing.expect(!fixture.held.load(.acquire) and !fixture.entered.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), fixture.releases);
    try std.testing.expectEqual(@as(usize, 0), registry.tasks().len);
}

test "creation admission blocks every create variant before allocation lease task or borrowed owner and permits retry" {
    const Admission = struct {
        blocked: bool = true,
        checks: usize = 0,
        fn check(raw: ?*anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.checks += 1;
            if (self.blocked) return error.JavaDeletionBusy;
        }
    };
    const Variant = enum { ordinary, prepared, prepared_java, vanilla };
    for ([_]Variant{ .ordinary, .prepared, .prepared_java, .vanilla }) |variant| {
        var env = try Environment.init();
        defer env.deinit();
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var source: PreparedFixture = .{};
        var prepared = try source.prepare(env.root);
        defer prepared.deinit();
        var vanilla = try source.prepareVanilla(env.root, env.paths.minecraft);
        defer vanilla.deinit();
        const vanilla_calls = source.vanilla_calls;
        const loader_calls = source.loader_calls;
        var fixture: Fixture = .{};
        fixture.blocked.store(true, .release);
        var admission: Admission = .{};
        var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
        defer manager.deinit();
        manager.setInstaller(fixture.installer());
        manager.setCreationAdmission(.{ .context = &admission, .check = Admission.check });
        try manager.setDefaultJava("/default/java");
        const default_java = manager.default_java.?;
        // A failing allocator proves rejection occurs before even validating/cloning
        // the prepared owners, request strings, or the default Java snapshot.
        {
            var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
            manager.allocator = failing.allocator();
            defer manager.allocator = a;
            try std.testing.expectError(error.JavaDeletionBusy, switch (variant) {
                .ordinary => manager.startCreate(example),
                .prepared => manager.startCreatePrepared(prepared_example, &prepared, 7),
                .prepared_java => manager.startCreatePreparedWithJava(prepared_example, &prepared, 7, "/installer/java"),
                .vanilla => manager.startCreateVanillaPrepared(example, &vanilla, 7),
            });
        }
        try std.testing.expectEqual(@as(usize, 1), admission.checks);
        try std.testing.expect(manager.active == null and manager.pending == null and manager.published == null);
        try std.testing.expectEqual(module.Phase.idle, manager.snapshot().phase);
        try std.testing.expectEqual(module.Operation.none, manager.snapshot().operation);
        try std.testing.expect(manager.default_java.?.ptr == default_java.ptr);
        try std.testing.expect(!fixture.held.load(.acquire) and !fixture.entered.load(.acquire));
        try std.testing.expect(fixture.observed_prepared == null and fixture.observed_vanilla_prepared == null);
        try std.testing.expectEqual(@as(u64, 0), fixture.observed_generation);
        try std.testing.expectEqual(@as(usize, 0), fixture.rechecks);
        try std.testing.expectEqual(@as(usize, 0), fixture.releases);
        try std.testing.expectEqual(@as(usize, 0), registry.tasks().len);
        try std.testing.expectEqual(vanilla_calls, source.vanilla_calls);
        try std.testing.expectEqual(loader_calls, source.loader_calls);
        admission.blocked = false;
        try switch (variant) {
            .ordinary => manager.startCreate(example),
            .prepared => manager.startCreatePrepared(prepared_example, &prepared, 7),
            .prepared_java => manager.startCreatePreparedWithJava(prepared_example, &prepared, 7, "/installer/java"),
            .vanilla => manager.startCreateVanillaPrepared(example, &vanilla, 7),
        };
        try waitEntered(&fixture);
        try std.testing.expectEqual(@as(usize, 2), admission.checks);
        try std.testing.expect(fixture.held.load(.acquire));
        try std.testing.expectEqual(@as(usize, 1), registry.tasks().len);
        const active = manager.active.?;
        switch (variant) {
            .ordinary => {
                try std.testing.expect(active.prepared == null and active.vanilla_prepared == null);
                try std.testing.expectEqualStrings("/default/java", active.installer_java.?);
            },
            .prepared, .prepared_java => {
                try std.testing.expect(active.prepared.? == &prepared and fixture.observed_prepared.? == &prepared);
                try std.testing.expectEqual(@as(u64, 7), active.prepared_generation);
                try std.testing.expectEqualStrings(if (variant == .prepared_java) "/installer/java" else "/default/java", active.installer_java.?);
            },
            .vanilla => {
                try std.testing.expect(active.vanilla_prepared.? == &vanilla and fixture.observed_vanilla_prepared.? == &vanilla);
                try std.testing.expect(active.installer_java == null);
                try std.testing.expectEqual(@as(u64, 7), active.prepared_generation);
            },
        }
        // Existing ownership still wins over the live admission callback.
        try std.testing.expectError(error.Busy, manager.startCreate(example));
        try std.testing.expectEqual(@as(usize, 2), admission.checks);
        fixture.blocked.store(false, .release);
        try settle(&manager);
        const joined = manager.pending.?;
        try std.testing.expect(joined.future == null and joined.prepared == null and joined.vanilla_prepared == null);
        try std.testing.expectEqual(@as(u64, 0), joined.prepared_generation);
        try manager.publish(&env.store);
        try std.testing.expect(!fixture.held.load(.acquire));
        try std.testing.expectEqual(@as(usize, 1), fixture.releases);
        try std.testing.expectEqual(@as(usize, 1), env.store.snapshot().instances.len);
    }
}

test "prepared create rejects default foreign stale tampered and environment bindings before lease or task" {
    var env = try Environment.init();
    defer env.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    defer manager.deinit();
    manager.setInstaller(fixture.installer());
    var source: PreparedFixture = .{};
    var prepared = try source.prepare(env.root);
    defer prepared.deinit();
    var empty: loader_install.PreparedMetadata = undefined;
    empty.generation = 0; // Generation rejection must not touch any other owner field.
    try expectPreparedRejected(&manager, &fixture, &registry, prepared_example, &empty, 7, error.PreparedMetadataGenerationMismatch);
    try expectPreparedRejected(&manager, &fixture, &registry, prepared_example, &prepared, 0, error.PreparedMetadataGenerationMismatch);
    try expectPreparedRejected(&manager, &fixture, &registry, prepared_example, &prepared, 8, error.PreparedMetadataGenerationMismatch);
    inline for (.{ "id", "name", "minecraft_version", "loader_version" }) |field| {
        var wrong = prepared_example;
        @field(wrong, field) = "different";
        try expectPreparedRejected(&manager, &fixture, &registry, wrong, &prepared, 7, error.PreparedMetadataMismatch);
    }
    var wrong = prepared_example;
    wrong.loader = .quilt;
    try expectPreparedRejected(&manager, &fixture, &registry, wrong, &prepared, 7, error.PreparedMetadataMismatch);
    wrong = prepared_example;
    wrong.loader = .vanilla;
    try expectPreparedRejected(&manager, &fixture, &registry, wrong, &prepared, 7, error.InvalidLoader);
    var borrowed_copy = prepared;
    borrowed_copy.root = "/foreign/root";
    try expectPreparedRejected(&manager, &fixture, &registry, prepared_example, &borrowed_copy, 7, error.PreparedMetadataMismatch);
    borrowed_copy = prepared;
    borrowed_copy.selection.side = .server;
    try expectPreparedRejected(&manager, &fixture, &registry, prepared_example, &borrowed_copy, 7, error.PreparedMetadataMismatch);
    borrowed_copy = prepared;
    borrowed_copy.environment.os_version = "nondefault";
    try expectPreparedRejected(&manager, &fixture, &registry, prepared_example, &borrowed_copy, 7, error.PreparedMetadataMismatch);
    borrowed_copy = prepared;
    borrowed_copy.environment.features = &.{.{ .name = "is_demo_user", .enabled = true }};
    try expectPreparedRejected(&manager, &fixture, &registry, prepared_example, &borrowed_copy, 7, error.PreparedMetadataMismatch);
    borrowed_copy = prepared;
    borrowed_copy.environment.version_matcher = .{ .matches = unusedPreparedMatcher };
    try expectPreparedRejected(&manager, &fixture, &registry, prepared_example, &borrowed_copy, 7, error.PreparedMetadataMismatch);
    borrowed_copy = prepared;
    borrowed_copy.replay_digest[0] ^= 1;
    try expectPreparedRejected(&manager, &fixture, &registry, prepared_example, &borrowed_copy, 7, error.PreparedMetadataChanged);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    manager.allocator = failing.allocator();
    defer manager.allocator = a;
    try expectPreparedRejected(&manager, &fixture, &registry, prepared_example, &prepared, 7, error.OutOfMemory);
}

test "prepared create borrows metadata through JOIN owns request and explicit Java then publishes without owner" {
    var env = try Environment.init();
    defer env.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var source: PreparedFixture = .{};
    var prepared = try source.prepare(env.root);
    var owner_live = true;
    defer if (owner_live) prepared.deinit();
    var fixture: Fixture = .{};
    fixture.blocked.store(true, .release);
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    defer manager.deinit();
    manager.setInstaller(fixture.installer());
    try manager.setDefaultJava("/default/java");
    var name = "Owned".*;
    var version = "1.20.1".*;
    var loader_version = "0.16.0".*;
    var runtime_java = "/runtime17/java".*;
    var installer_java = "/installer8/java".*;
    var request = prepared_example;
    request.name = &name;
    request.minecraft_version = &version;
    request.loader_version = &loader_version;
    request.java_path = &runtime_java;
    try manager.startCreatePreparedWithJava(request, &prepared, 7, &installer_java);
    try waitEntered(&fixture);
    try std.testing.expect(fixture.observed_prepared.? == &prepared);
    try std.testing.expectEqual(@as(u64, 7), fixture.observed_generation);
    try std.testing.expect(manager.active.?.prepared.? == &prepared);
    @memset(&name, 'x');
    @memset(&version, 'x');
    @memset(&loader_version, 'x');
    @memset(&runtime_java, 'x');
    @memset(&installer_java, 'x');
    try manager.setDefaultJava("/changed/default");
    fixture.blocked.store(false, .release);
    try settle(&manager);
    try std.testing.expectEqual(module.Phase.awaiting_publication, manager.snapshot().phase);
    try std.testing.expect(manager.pending.?.future == null and manager.pending.?.prepared == null);
    try std.testing.expectEqual(@as(u64, 0), manager.pending.?.prepared_generation);
    try std.testing.expectEqualStrings("/installer8/java", std.mem.sliceTo(&fixture.observed_java, 0));
    try std.testing.expectEqualStrings("/runtime17/java", manager.pending.?.request.java_path.?);
    // Only after JOIN: manager must not own or access metadata during publication.
    prepared.deinit();
    owner_live = false;
    try manager.publish(&env.store);
    try std.testing.expect(manager.published.?.prepared == null);
    const saved = env.store.snapshot().instances[0];
    try std.testing.expectEqualStrings("Owned", saved.name);
    try std.testing.expectEqualStrings("1.20.1", saved.minecraft_version);
    try std.testing.expectEqualStrings("0.16.0", saved.loader_version.?);
    try std.testing.expectEqualStrings("/runtime17/java", saved.java_path.?);
    try std.testing.expectEqual(@as(usize, 1), source.vanilla_calls);
    try std.testing.expectEqual(@as(usize, 2), source.loader_calls);
}

test "prepared create JOIN clears borrow on cancellation failure recovery and explicit null has no Java fallback" {
    var env = try Environment.init();
    defer env.deinit();
    var source: PreparedFixture = .{};
    var prepared = try source.prepare(env.root);
    defer prepared.deinit();
    const failures = [_]?anyerror{ null, error.FixtureFailure, error.RecoveryRequired, error.Canceled };
    for (failures) |failure| {
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var fixture: Fixture = .{ .failure = failure };
        fixture.blocked.store(true, .release);
        var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
        defer manager.deinit();
        manager.setInstaller(fixture.installer());
        try manager.setDefaultJava("/default/java");
        var request = prepared_example;
        request.java_path = "/runtime/java";
        try manager.startCreatePreparedWithJava(request, &prepared, 7, null);
        try waitEntered(&fixture);
        if (failure != null and failure.? == error.Canceled) manager.cancel();
        fixture.blocked.store(false, .release);
        try settle(&manager);
        try std.testing.expect(manager.active == null);
        if (manager.pending) |job| {
            try std.testing.expect(job.future == null and job.prepared == null and job.installer_java == null);
            try std.testing.expectEqual(@as(u64, 0), job.prepared_generation);
        }
        try std.testing.expectEqualStrings("", std.mem.sliceTo(&fixture.observed_java, 0));
        if (failure) |err| {
            try std.testing.expectEqual(err, manager.snapshot().failure.?);
            if (err == error.RecoveryRequired) {
                try std.testing.expect(manager.pending != null and fixture.held.load(.acquire));
            } else {
                try std.testing.expect(manager.pending == null and !fixture.held.load(.acquire));
            }
        } else {
            try std.testing.expectEqual(module.Phase.awaiting_publication, manager.snapshot().phase);
        }
    }
}

test "prepared metadata owner remains valid after active manager teardown JOIN" {
    var env = try Environment.init();
    defer env.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var source: PreparedFixture = .{};
    var prepared = try source.prepare(env.root);
    defer prepared.deinit();
    var fixture: Fixture = .{};
    fixture.blocked.store(true, .release);
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    var manager_live = true;
    defer if (manager_live) manager.deinit();
    manager.setInstaller(fixture.installer());
    try manager.startCreatePrepared(prepared_example, &prepared, 7);
    try waitEntered(&fixture);
    manager.deinit();
    manager_live = false;
    try prepared.validateBinding(a, io, .{ .root = env.root, .instance_id = prepared_example.id, .instance_name = prepared_example.name, .generation = 7, .selection = prepared.selection, .environment = try preparedEnvironment() });
    try std.testing.expect(!fixture.held.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), fixture.releases);
}

fn expectVanillaRejected(manager: *module.Manager, fixture: *Fixture, registry: *tasks.Registry, instance: Instance, owner: *const metadata_loader.PreparedVanilla, generation: u64, expected: anyerror) !void {
    try std.testing.expectError(expected, manager.startCreateVanillaPrepared(instance, owner, generation));
    try std.testing.expect(manager.active == null and manager.pending == null);
    try std.testing.expect(!fixture.held.load(.acquire) and !fixture.entered.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), fixture.releases);
    try std.testing.expectEqual(@as(usize, 0), registry.tasks().len);
}

test "vanilla prepared create rejects wrong kind identity environment stale tampered and conflicting proofs" {
    var env = try Environment.init();
    defer env.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    defer manager.deinit();
    manager.setInstaller(fixture.installer());
    var source: PreparedFixture = .{};
    var prepared = try source.prepareVanilla(env.root, env.paths.minecraft);
    defer prepared.deinit();
    var empty: metadata_loader.PreparedVanilla = undefined;
    empty.target.generation = 0;
    try expectVanillaRejected(&manager, &fixture, &registry, example, &empty, 7, error.PreparedMetadataGenerationMismatch);
    try expectVanillaRejected(&manager, &fixture, &registry, example, &prepared, 0, error.PreparedMetadataGenerationMismatch);
    try expectVanillaRejected(&manager, &fixture, &registry, example, &prepared, 8, error.PreparedMetadataGenerationMismatch);
    try expectVanillaRejected(&manager, &fixture, &registry, prepared_example, &prepared, 7, error.InvalidLoader);
    inline for (.{ "id", "name", "minecraft_version" }) |field| {
        var wrong = example;
        @field(wrong, field) = "different";
        try expectVanillaRejected(&manager, &fixture, &registry, wrong, &prepared, 7, error.PreparedMetadataMismatch);
    }
    var borrowed_copy = prepared;
    borrowed_copy.target.root = "/foreign/root";
    try expectVanillaRejected(&manager, &fixture, &registry, example, &borrowed_copy, 7, error.PreparedMetadataMismatch);
    borrowed_copy = prepared;
    borrowed_copy.target.environment.os_version = "nondefault";
    try expectVanillaRejected(&manager, &fixture, &registry, example, &borrowed_copy, 7, error.PreparedMetadataMismatch);
    borrowed_copy = prepared;
    borrowed_copy.target.environment.features = &.{.{ .name = "is_demo_user", .enabled = true }};
    try expectVanillaRejected(&manager, &fixture, &registry, example, &borrowed_copy, 7, error.PreparedMetadataMismatch);
    borrowed_copy = prepared;
    borrowed_copy.target.environment.version_matcher = .{ .matches = unusedPreparedMatcher };
    try expectVanillaRejected(&manager, &fixture, &registry, example, &borrowed_copy, 7, error.PreparedMetadataMismatch);
    borrowed_copy = prepared;
    borrowed_copy.replay_digest[0] ^= 1;
    try expectVanillaRejected(&manager, &fixture, &registry, example, &borrowed_copy, 7, error.PreparedMetadataChanged);
    // The production entry must reject this before even touching either owner or lease.
    const production = module.productionInstaller();
    var loader_owner: loader_install.PreparedMetadata = undefined;
    var canceled: std.atomic.Value(bool) = .init(false);
    try std.testing.expectError(error.ConflictingPreparedMetadata, production.run(production.context, a, io, .{ .root = env.root, .instance = example, .lease = fixture.lease(), .prepared = &loader_owner, .vanilla_prepared = &prepared, .prepared_generation = 7 }, .{ .cancel = &canceled }));
    try std.testing.expect(!fixture.held.load(.acquire) and !fixture.entered.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), fixture.rechecks);
}

test "vanilla prepared create clones final request borrows through JOIN and publishes after owner teardown" {
    var env = try Environment.init();
    defer env.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var source: PreparedFixture = .{};
    var prepared = try source.prepareVanilla(env.root, env.paths.minecraft);
    var owner_live = true;
    defer if (owner_live) prepared.deinit();
    var fixture: Fixture = .{};
    fixture.blocked.store(true, .release);
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    defer manager.deinit();
    manager.setInstaller(fixture.installer());
    try manager.setDefaultJava("/default/java");
    var id = "instance-owned".*;
    var name = "Owned".*;
    var version = "1.20.1".*;
    var request = example;
    request.id = &id;
    request.name = &name;
    request.minecraft_version = &version;
    try manager.startCreateVanillaPrepared(request, &prepared, 7);
    try waitEntered(&fixture);
    try std.testing.expect(fixture.observed_prepared == null);
    try std.testing.expect(fixture.observed_vanilla_prepared.? == &prepared);
    try std.testing.expectEqual(@as(u64, 7), fixture.observed_generation);
    try std.testing.expect(manager.active.?.vanilla_prepared.? == &prepared);
    @memset(&id, 'x');
    @memset(&name, 'x');
    @memset(&version, 'x');
    fixture.blocked.store(false, .release);
    try settle(&manager);
    const job = manager.pending.?;
    try std.testing.expect(job.future == null and job.prepared == null and job.vanilla_prepared == null);
    try std.testing.expect(job.installer_java == null and job.prepared_generation == 0);
    prepared.deinit();
    owner_live = false;
    try manager.publish(&env.store);
    const saved = env.store.snapshot().instances[0];
    try std.testing.expectEqualStrings(example.id, saved.id);
    try std.testing.expectEqualStrings(example.name, saved.name);
    try std.testing.expectEqualStrings(example.minecraft_version, saved.minecraft_version);
    try std.testing.expectEqual(config.Loader.vanilla, saved.loader);
    try std.testing.expect(manager.published.?.vanilla_prepared == null);
    try std.testing.expectEqual(@as(usize, 1), source.vanilla_calls);
    try std.testing.expectEqual(@as(usize, 0), source.loader_calls);
}

test "vanilla prepared cancellation failure recovery and active teardown JOIN retain caller owner" {
    var env = try Environment.init();
    defer env.deinit();
    var source: PreparedFixture = .{};
    var prepared = try source.prepareVanilla(env.root, env.paths.minecraft);
    defer prepared.deinit();
    const failures = [_]anyerror{ error.FixtureFailure, error.RecoveryRequired, error.Canceled };
    for (0..4) |index| {
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var fixture: Fixture = .{ .failure = if (index < failures.len) failures[index] else null };
        fixture.blocked.store(true, .release);
        var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
        var manager_live = true;
        defer if (manager_live) manager.deinit();
        manager.setInstaller(fixture.installer());
        try manager.startCreateVanillaPrepared(example, &prepared, 7);
        try waitEntered(&fixture);
        if (index == failures.len) {
            manager.deinit();
            manager_live = false;
            try std.testing.expect(!fixture.held.load(.acquire));
        } else {
            if (failures[index] == error.Canceled) manager.cancel();
            fixture.blocked.store(false, .release);
            try settle(&manager);
            try std.testing.expect(manager.active == null);
            try std.testing.expectEqual(failures[index], manager.snapshot().failure.?);
            if (manager.pending) |job| {
                try std.testing.expect(job.future == null and job.prepared == null and job.vanilla_prepared == null);
                try std.testing.expectEqual(@as(u64, 0), job.prepared_generation);
            }
            if (failures[index] == error.RecoveryRequired) {
                try std.testing.expect(manager.pending != null and fixture.held.load(.acquire));
            } else {
                try std.testing.expect(manager.pending == null and !fixture.held.load(.acquire));
            }
        }
        try prepared.validateBinding(a, io, .{ .root = env.root, .instance_id = example.id, .instance_name = example.name, .version_id = example.minecraft_version, .generation = 7, .environment = try preparedEnvironment() });
    }
}

fn waitWorkerDone(manager: *module.Manager) !void {
    const job = manager.active orelse return error.ExpectedActiveWorker;
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    while (!job.done.load(.acquire)) {
        if (std.Io.Clock.awake.now(io).nanoseconds - start > 3 * std.time.ns_per_s) return error.FixtureTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "instance cancelAndJoin without active worker is idempotent and leaves manager usable" {
    var env = try Environment.init();
    defer env.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    defer manager.deinit();
    manager.setInstaller(fixture.installer());
    manager.cancelAndJoin();
    manager.cancelAndJoin();
    try std.testing.expectEqual(module.Phase.idle, manager.snapshot().phase);
    try std.testing.expect(!manager.isBusy() and !registry.hasActive());
    try std.testing.expectEqual(@as(usize, 0), fixture.releases);
    try std.testing.expectEqual(@as(usize, 0), registry.tasks().len);
    try manager.startCreate(example);
    try settle(&manager);
    const job = manager.pending.?;
    const task = job.task.?;
    manager.cancelAndJoin();
    manager.cancelAndJoin();
    try std.testing.expect(manager.pending.? == job and job.task.? == task);
    try std.testing.expect(!task.cancellation.load(.acquire));
    try std.testing.expectEqual(module.Phase.awaiting_publication, manager.snapshot().phase);
    try std.testing.expect(fixture.held.load(.acquire) and registry.hasActive());
    try std.testing.expectEqual(@as(usize, 0), env.store.snapshot().instances.len);
    try manager.publish(&env.store);
    try std.testing.expectEqual(@as(usize, 1), fixture.releases);
}

test "instance cancelAndJoin joins active prepared workers without destroying caller proofs" {
    var env = try Environment.init();
    defer env.deinit();
    var source: PreparedFixture = .{};
    var prepared = try source.prepare(env.root);
    defer prepared.deinit();
    var vanilla = try source.prepareVanilla(env.root, env.paths.minecraft);
    defer vanilla.deinit();
    for ([_]bool{ false, true }) |use_vanilla| {
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var fixture: Fixture = .{};
        fixture.blocked.store(true, .release);
        var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
        defer manager.deinit();
        manager.setInstaller(fixture.installer());
        if (use_vanilla) {
            try manager.startCreateVanillaPrepared(example, &vanilla, 7);
        } else {
            try manager.startCreatePrepared(prepared_example, &prepared, 7);
        }
        try waitEntered(&fixture);
        manager.cancelAndJoin();
        try std.testing.expect(manager.active == null and manager.pending == null);
        const job = manager.published.?;
        try std.testing.expect(job.done.load(.acquire));
        try std.testing.expect(job.future == null and job.prepared == null and job.vanilla_prepared == null);
        try std.testing.expectEqual(@as(u64, 0), job.prepared_generation);
        try std.testing.expectEqual(error.Canceled, manager.snapshot().failure.?);
        try std.testing.expect(!fixture.held.load(.acquire) and !registry.hasActive());
        try std.testing.expectEqual(@as(usize, 1), fixture.releases);
        manager.cancelAndJoin();
        manager.tick();
        try std.testing.expect(manager.published.? == job);
        try std.testing.expectEqual(@as(usize, 1), fixture.releases);
        try prepared.validateBinding(a, io, .{ .root = env.root, .instance_id = prepared_example.id, .instance_name = prepared_example.name, .generation = 7, .selection = prepared.selection, .environment = try preparedEnvironment() });
        try vanilla.validateBinding(a, io, .{ .root = env.root, .instance_id = example.id, .instance_name = example.name, .version_id = example.minecraft_version, .generation = 7, .environment = try preparedEnvironment() });
    }
}

test "instance cancelAndJoin retains late successful publication and recovery debt" {
    var env = try Environment.init();
    defer env.deinit();
    var source: PreparedFixture = .{};
    var prepared = try source.prepare(env.root);
    defer prepared.deinit();
    for ([_]?anyerror{ null, error.RecoveryRequired, error.FixtureFailure }) |failure| {
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var fixture: Fixture = .{ .failure = failure };
        var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
        defer manager.deinit();
        manager.setInstaller(fixture.installer());
        try manager.startCreatePrepared(prepared_example, &prepared, 7);
        try waitWorkerDone(&manager);
        const job = manager.active.?;
        manager.cancelAndJoin();
        try std.testing.expect(manager.active == null);
        try std.testing.expect(job.future == null and job.prepared == null and job.vanilla_prepared == null);
        try std.testing.expectEqual(@as(u64, 0), job.prepared_generation);
        if (failure != null and failure.? == error.FixtureFailure) {
            try std.testing.expect(manager.pending == null and manager.published.? == job);
            try std.testing.expect(!fixture.held.load(.acquire));
            try std.testing.expectEqual(@as(usize, 1), fixture.releases);
        } else {
            try std.testing.expect(manager.pending.? == job and job.leased and fixture.held.load(.acquire));
            try std.testing.expectEqual(@as(usize, 0), fixture.releases);
        }
        if (failure) |err| {
            try std.testing.expectEqual(err, manager.snapshot().failure.?);
            try std.testing.expectEqual(module.Phase.failed, manager.snapshot().phase);
            try std.testing.expect(!registry.hasActive());
            if (err == error.RecoveryRequired) try std.testing.expectError(error.RecoveryRequired, manager.publish(&env.store));
        } else {
            try std.testing.expect(manager.snapshot().failure == null);
            try std.testing.expectEqual(module.Phase.awaiting_publication, manager.snapshot().phase);
            try std.testing.expect(job.task != null and registry.hasActive());
        }
        const releases = fixture.releases;
        manager.cancelAndJoin();
        manager.tick();
        try std.testing.expectEqual(releases, fixture.releases);
        try prepared.validateBinding(a, io, .{ .root = env.root, .instance_id = prepared_example.id, .instance_name = prepared_example.name, .generation = 7, .selection = prepared.selection, .environment = try preparedEnvironment() });
    }
}

test "instance cancelAndJoin preserves owned publication uncertainty without Store writes" {
    try requireSyncFaults();
    var fault: PublicationFaultIo = .{};
    const store_io = fault.start();
    defer fault.stop();
    var env = try Environment.initWithStoreIo(store_io);
    defer env.deinit();
    try env.store.update(.{});
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    defer manager.deinit();
    manager.setInstaller(fixture.installer());
    try manager.startCreate(example);
    try settle(&manager);
    const job = manager.pending.?;
    fault.reset();
    fault.fail_sync = 3;
    try std.testing.expectError(error.InputOutput, manager.publish(&env.store));
    const counts = fault.counts();
    manager.cancelAndJoin();
    manager.cancelAndJoin();
    try std.testing.expectEqualDeep(counts, fault.counts());
    try std.testing.expect(manager.pending.? == job and job.uncertain_publication_store.? == &env.store);
    try std.testing.expect(env.store.publicationUncertain());
    try expectRetained(&manager, &fixture, &registry);
    fault.reset();
    try env.store.reconcile();
    try manager.acknowledgeReconciledCreation(&env.store);
    try std.testing.expectEqual(@as(usize, 1), fixture.releases);
    try std.testing.expectEqual(module.Phase.complete, manager.snapshot().phase);
}

fn expectRealPublicationLease(coordinator: *@import("core/instance_leases.zig").Coordinator, id: []const u8) !void {
    try std.testing.expectError(error.InstanceBusy, coordinator.reserveLaunch(id));
    try coordinator.reserveLaunch("unrelated-instance");
    coordinator.releaseLaunch();
    coordinator.tick();
    try std.testing.expectError(error.InstanceNamespaceBusy, @import("core/instance_namespace.zig").acquire(io));
}

const PublicationAllocator = struct {
    enabled: bool = false,
    calls: usize = 0,
    gate_unavailable: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
    fn allocator(self: *PublicationAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn probe(self: *PublicationAllocator) void {
        if (!self.enabled) return;
        self.calls += 1;
        const gate = &@import("core/worlds.zig").transaction_gate;
        if (gate.tryLock()) gate.unlock(io) else self.gate_unavailable += 1;
    }
    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PublicationAllocator = @ptrCast(@alignCast(raw));
        self.probe();
        return a.rawAlloc(len, alignment, ret_addr);
    }
    fn resize(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret_addr: usize) bool {
        const self: *PublicationAllocator = @ptrCast(@alignCast(raw));
        self.probe();
        return a.rawResize(memory, alignment, len, ret_addr);
    }
    fn remap(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret_addr: usize) ?[*]u8 {
        const self: *PublicationAllocator = @ptrCast(@alignCast(raw));
        self.probe();
        return a.rawRemap(memory, alignment, len, ret_addr);
    }
    fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *PublicationAllocator = @ptrCast(@alignCast(raw));
        self.probe();
        a.rawFree(memory, alignment, ret_addr);
    }
};

test "manager real lease excludes same ID through JOIN uncertain save reconcile and acknowledgment" {
    try requireSyncFaults();
    const leases = @import("core/instance_leases.zig");
    const namespace = @import("core/instance_namespace.zig");
    var fault: PublicationFaultIo = .{};
    const store_io = fault.start();
    defer fault.stop();
    var env = try Environment.initWithStoreIo(store_io);
    defer env.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var coordinator = leases.Coordinator.init(io);
    defer coordinator.tick();
    const mutation = coordinator.mutation(0);
    var fixture: Fixture = .{};
    fixture.blocked.store(true, .release);
    var allocation_probe: PublicationAllocator = .{};
    var manager = try module.Manager.init(allocation_probe.allocator(), io, &env.paths, &registry, .{}, .{
        .context = mutation,
        .acquire = leases.Mutation.acquireCallback,
        .recheck = leases.Mutation.recheckCallback,
        .release = leases.Mutation.releaseCallback,
    });
    defer manager.deinit();
    manager.setInstaller(fixture.installer());
    try manager.startCreate(example);
    try waitEntered(&fixture);
    try expectRealPublicationLease(&coordinator, example.id);
    try mutation.recheck(example.id);

    const competing_mutation = coordinator.mutation(1);
    var competitor = try module.Manager.init(a, io, &env.paths, &registry, .{}, .{
        .context = competing_mutation,
        .acquire = leases.Mutation.acquireCallback,
        .recheck = leases.Mutation.recheckCallback,
        .release = leases.Mutation.releaseCallback,
    });
    defer competitor.deinit();
    competitor.setInstaller(fixture.installer());
    const other: Instance = .{ .id = "competing-instance", .name = "Competing", .minecraft_version = "1.20.1" };
    try std.testing.expectError(error.InstanceNamespaceBusy, competitor.startCreate(other));
    try std.testing.expect(!competitor.isBusy());
    try std.testing.expectError(error.LeaseNotHeld, competing_mutation.recheck(other.id));
    try coordinator.reserveLaunch(other.id);
    coordinator.releaseLaunch();
    coordinator.tick();

    fixture.blocked.store(false, .release);
    try settle(&manager);
    const job = manager.pending.?;
    try std.testing.expect(job.future == null and job.done.load(.acquire));
    try expectRealPublicationLease(&coordinator, example.id);
    fault.reset();
    fault.require_namespace = true;
    allocation_probe.enabled = true;
    fault.fail_sync = 3;
    try std.testing.expectError(error.InputOutput, manager.publish(&env.store));
    try fault.expectPublicationProtected();
    try std.testing.expect(allocation_probe.calls > 0);
    try std.testing.expectEqual(@as(usize, 0), allocation_probe.gate_unavailable);
    try std.testing.expect(fault.writes > 0 and fault.syncs > 0 and fault.renames > 0);
    try std.testing.expect(env.store.publicationUncertain());
    try std.testing.expect(manager.pending.? == job and job.leased and job.namespace_token != null);
    try expectRealPublicationLease(&coordinator, example.id);
    const blocked = fault.counts();
    try std.testing.expectError(error.ConfigPublicationUncertain, manager.acknowledgeReconciledCreation(&env.store));
    try std.testing.expectEqualDeep(blocked, fault.counts());

    fault.reset();
    try env.store.reconcile();
    try std.testing.expect(fault.opens > 0);
    try fault.expectPublicationProtected();
    try expectRealPublicationLease(&coordinator, example.id);
    const reconciled = fault.counts();
    try manager.acknowledgeReconciledCreation(&env.store);
    try std.testing.expectEqualDeep(reconciled, fault.counts());
    try std.testing.expect(!manager.isBusy() and job.namespace_token == null and !job.leased);
    try coordinator.reserveLaunch(example.id);
    coordinator.releaseLaunch();
    coordinator.tick();
    const token = try namespace.acquire(io);
    token.release();
}

const CatalogueFixture = struct {
    calls: usize = 0,
    entered: std.atomic.Value(bool) = .init(false),
    blocked: std.atomic.Value(bool) = .init(false),
    ignore_cancel: bool = false,
    failure: ?anyerror = null,
    wrong_base: bool = false,
    wrong_kind: bool = false,
    empty: bool = false,
    observed_cache_root: ?[]const u8 = null,
    fn adapter(self: *CatalogueFixture) module.CatalogueAdapter {
        return .{ .context = self, .fetch = fetch };
    }
    fn fetch(raw: ?*anyopaque, alloc: std.mem.Allocator, worker_io: std.Io, base: []const u8, kind: config.Loader, control: module.Control) !module.LoaderCatalogue {
        const self: *CatalogueFixture = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        self.observed_cache_root = control.cache_root;
        self.entered.store(true, .release);
        while (self.blocked.load(.acquire)) {
            if (!self.ignore_cancel) try control.check();
            try worker_io.sleep(.fromMilliseconds(1), .awake);
        }
        if (!self.ignore_cancel) try control.check();
        if (self.failure) |err| return err;
        var arena: std.heap.ArenaAllocator = .init(alloc);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const entries = try owned.alloc(module.LoaderEntry, if (self.empty) 0 else 1);
        if (entries.len != 0) entries[0] = .{ .id = try owned.dupe(u8, "loader-owned"), .stable = false, .release_time = try owned.dupe(u8, "2025-04-03T12:34:56Z") };
        const owned_base = try owned.dupe(u8, if (self.wrong_base) "wrong-base" else base);
        return .{ .arena = arena, .base = owned_base, .kind = if (self.wrong_kind) .quilt else kind, .entries = entries };
    }
};
const CatalogueClock = struct {
    milliseconds: u64 = 10,
    fn now(raw: ?*anyopaque, _: std.Io) u64 {
        const self: *CatalogueClock = @ptrCast(@alignCast(raw.?));
        return self.milliseconds;
    }
    fn options(self: *CatalogueClock) module.Options {
        return .{ .cache_clock = .{ .context = self, .now_ms = now } };
    }
};
fn waitCatalogueEntered(fixture: *CatalogueFixture) !void {
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    while (!fixture.entered.load(.acquire)) {
        if (std.Io.Clock.awake.now(io).nanoseconds - start > 3 * std.time.ns_per_s) return error.FixtureTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}
fn waitCatalogueDone(manager: *module.Manager) !void {
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    while (!manager.active.?.done.load(.acquire)) {
        if (std.Io.Clock.awake.now(io).nanoseconds - start > 3 * std.time.ns_per_s) return error.FixtureTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "loader catalogue warm switching uses independent owned snapshots and base-kind keys" {
    var env = try Environment.init();
    defer env.deinit();
    var registry: tasks.Registry = .init(a);
    defer registry.deinit();
    var lease: Fixture = .{};
    var fixture: CatalogueFixture = .{ .blocked = .init(true) };
    var clock: CatalogueClock = .{};
    var cache_root = "/owned/cache".*;
    var options = clock.options();
    options.cache_root = &cache_root;
    var manager = try module.Manager.initWithOptions(a, io, &env.paths, &registry, .{}, lease.lease(), options);
    defer manager.deinit();
    manager.setLoaderCatalogue(fixture.adapter());
    var base = "1.20.1".*;
    try manager.loadLoaders(&base, .fabric);
    try waitCatalogueEntered(&fixture);
    @memset(&base, 'x');
    @memset(&cache_root, 'x');
    fixture.blocked.store(false, .release);
    try settle(&manager);
    try std.testing.expectEqualStrings("/owned/cache", fixture.observed_cache_root.?);
    const first = manager.loaderSnapshot();
    try std.testing.expectEqualStrings("1.20.1", first.base.?);
    try std.testing.expectEqualStrings("loader-owned", first.entries[0].id);
    try std.testing.expectEqualStrings("2025-04-03T12:34:56Z", first.entries[0].release_time);
    try std.testing.expect(!first.entries[0].stable);
    const cached = manager.loader_cache[0].?.catalogue;
    try std.testing.expect(cached.base.ptr != first.base.?.ptr);
    try std.testing.expect(cached.entries.ptr != first.entries.ptr);
    try std.testing.expect(cached.entries[0].id.ptr != first.entries[0].id.ptr);
    try std.testing.expect(cached.entries[0].release_time.ptr != first.entries[0].release_time.ptr);
    try manager.loadLoaders("1.20.1", .quilt);
    try settle(&manager);
    try manager.loadLoaders("1.21", .fabric);
    try settle(&manager);
    const task_count = registry.tasks().len;
    try manager.loadLoaders("1.20.1", .fabric);
    try std.testing.expect(!manager.isBusy());
    try std.testing.expectEqual(module.Phase.complete, manager.loaderSnapshot().phase);
    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
    try std.testing.expectEqual(task_count, registry.tasks().len);
    const warm = manager.loaderSnapshot();
    try std.testing.expectEqualStrings("1.20.1", warm.base.?);
    try std.testing.expectEqual(config.Loader.fabric, warm.kind);
    try std.testing.expectEqualStrings("2025-04-03T12:34:56Z", warm.entries[0].release_time);
    try std.testing.expect(warm.entries[0].id.ptr != cached.entries[0].id.ptr);
    fixture.empty = true;
    try manager.loadLoaders("empty-base", .forge);
    try settle(&manager);
    try manager.loadLoaders("1.20.1", .quilt);
    try manager.loadLoaders("empty-base", .forge);
    try std.testing.expectEqual(@as(usize, 4), fixture.calls);
    try std.testing.expectEqual(module.Phase.complete, manager.loaderSnapshot().phase);
    try std.testing.expectEqual(@as(usize, 0), manager.loaderSnapshot().entries.len);
}

test "loader catalogue monotonic expiry and explicit retry revalidate once" {
    var env = try Environment.init();
    defer env.deinit();
    var registry: tasks.Registry = .init(a);
    defer registry.deinit();
    var lease: Fixture = .{};
    var fixture: CatalogueFixture = .{};
    var clock: CatalogueClock = .{};
    var manager = try module.Manager.initWithOptions(a, io, &env.paths, &registry, .{}, lease.lease(), clock.options());
    defer manager.deinit();
    manager.setLoaderCatalogue(fixture.adapter());
    try manager.loadLoaders("1.20.1", .fabric);
    try settle(&manager);
    clock.milliseconds += 299_999;
    try manager.loadLoaders("1.20.1", .fabric);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    clock.milliseconds += 1;
    try manager.loadLoaders("1.20.1", .fabric);
    try std.testing.expect(manager.isBusy());
    try settle(&manager);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try manager.refreshLoaders("1.20.1", .fabric);
    try std.testing.expect(manager.isBusy());
    try settle(&manager);
    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
    try manager.loadLoaders("1.20.1", .fabric);
    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
}

test "loader catalogue cache stays bounded and adapter replacement invalidates successes" {
    var env = try Environment.init();
    defer env.deinit();
    var registry: tasks.Registry = .init(a);
    defer registry.deinit();
    var lease: Fixture = .{};
    var fixture: CatalogueFixture = .{};
    var clock: CatalogueClock = .{};
    var manager = try module.Manager.initWithOptions(a, io, &env.paths, &registry, .{}, lease.lease(), clock.options());
    defer manager.deinit();
    manager.setLoaderCatalogue(fixture.adapter());
    for (0..9) |i| {
        var buffer: [16]u8 = undefined;
        const base = try std.fmt.bufPrint(&buffer, "base-{d}", .{i});
        try manager.loadLoaders(base, .fabric);
        try settle(&manager);
    }
    var occupied: usize = 0;
    for (manager.loader_cache) |entry| if (entry != null) {
        occupied += 1;
    };
    try std.testing.expectEqual(@as(usize, 8), occupied);
    try manager.loadLoaders("base-1", .fabric);
    try std.testing.expectEqual(@as(usize, 9), fixture.calls);
    try manager.loadLoaders("base-0", .fabric);
    try settle(&manager);
    try std.testing.expectEqual(@as(usize, 10), fixture.calls);
    manager.setLoaderCatalogue(fixture.adapter());
    try manager.loadLoaders("base-0", .fabric);
    try settle(&manager);
    try std.testing.expectEqual(@as(usize, 11), fixture.calls);
}

test "loader catalogue failure cancellation and mismatched results never enter cache" {
    var env = try Environment.init();
    defer env.deinit();
    var registry: tasks.Registry = .init(a);
    defer registry.deinit();
    var lease: Fixture = .{};
    var fixture: CatalogueFixture = .{ .failure = error.FixtureFetchFailed };
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, lease.lease());
    defer manager.deinit();
    manager.setLoaderCatalogue(fixture.adapter());
    try manager.loadLoaders("1.20.1", .fabric);
    try settle(&manager);
    try std.testing.expectEqual(error.FixtureFetchFailed, manager.loaderSnapshot().failure.?);
    fixture.failure = null;
    fixture.wrong_base = true;
    try manager.loadLoaders("1.20.1", .fabric);
    try settle(&manager);
    try std.testing.expectEqual(error.LoaderCatalogueMismatch, manager.loaderSnapshot().failure.?);
    fixture.wrong_base = false;
    fixture.wrong_kind = true;
    try manager.loadLoaders("1.20.1", .fabric);
    try settle(&manager);
    try std.testing.expectEqual(error.LoaderCatalogueMismatch, manager.loaderSnapshot().failure.?);
    fixture.wrong_kind = false;
    fixture.entered.store(false, .release);
    fixture.blocked.store(true, .release);
    fixture.ignore_cancel = true;
    try manager.loadLoaders("1.20.1", .fabric);
    try waitCatalogueEntered(&fixture);
    try std.testing.expectError(error.Busy, manager.loadLoaders("another-base", .quilt));
    manager.cancel();
    fixture.blocked.store(false, .release);
    try settle(&manager);
    try std.testing.expectEqual(module.Phase.canceled, manager.loaderSnapshot().phase);
    try std.testing.expectEqual(@as(usize, 0), manager.loaderSnapshot().entries.len);
    for (manager.loader_cache) |entry| try std.testing.expect(entry == null);
    fixture.ignore_cancel = false;
    try manager.loadLoaders("1.20.1", .fabric);
    try settle(&manager);
    try std.testing.expectEqual(@as(usize, 5), fixture.calls);
    try std.testing.expectEqual(module.Phase.complete, manager.loaderSnapshot().phase);
    // Explicit retry retains a valid successful entry until a joined replacement.
    fixture.failure = error.FixtureFetchFailed;
    try manager.refreshLoaders("1.20.1", .fabric);
    try settle(&manager);
    fixture.failure = null;
    try manager.loadLoaders("1.20.1", .fabric);
    try std.testing.expect(!manager.isBusy());
    try std.testing.expectEqual(@as(usize, 6), fixture.calls);
    try std.testing.expectEqual(module.Phase.complete, manager.loaderSnapshot().phase);
    fixture.entered.store(false, .release);
    fixture.blocked.store(true, .release);
    try manager.refreshLoaders("1.20.1", .fabric);
    try waitCatalogueEntered(&fixture);
    manager.cancel();
    fixture.blocked.store(false, .release);
    try settle(&manager);
    try std.testing.expectEqual(module.Phase.canceled, manager.loaderSnapshot().phase);
    try manager.loadLoaders("1.20.1", .fabric);
    try std.testing.expect(!manager.isBusy());
    try std.testing.expectEqual(@as(usize, 7), fixture.calls);
    try std.testing.expectEqual(module.Phase.complete, manager.loaderSnapshot().phase);
}

test "loader catalogue late cancel and obsolete generation reject successful worker results after JOIN" {
    var env = try Environment.init();
    defer env.deinit();
    var registry: tasks.Registry = .init(a);
    defer registry.deinit();
    var lease: Fixture = .{};
    var fixture: CatalogueFixture = .{};
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, lease.lease());
    defer manager.deinit();
    manager.setLoaderCatalogue(fixture.adapter());
    try manager.loadLoaders("1.20.1", .fabric);
    try waitCatalogueDone(&manager);
    manager.cancel();
    manager.tick();
    try std.testing.expectEqual(module.Phase.canceled, manager.loaderSnapshot().phase);
    for (manager.loader_cache) |entry| try std.testing.expect(entry == null);
    try manager.loadLoaders("1.20.1", .fabric);
    try waitCatalogueDone(&manager);
    // Replacing even an equal adapter deliberately invalidates its old generation.
    manager.setLoaderCatalogue(fixture.adapter());
    manager.tick();
    try std.testing.expectEqual(module.Phase.canceled, manager.loaderSnapshot().phase);
    for (manager.loader_cache) |entry| try std.testing.expect(entry == null);
    try manager.loadLoaders("1.20.1", .fabric);
    try settle(&manager);
    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
    try std.testing.expectEqual(module.Phase.complete, manager.loaderSnapshot().phase);
}

const delete_other: Instance = .{ .id = "delete-other", .name = "Other", .minecraft_version = "1.21" };
fn seedDeleteConfiguration(env: *Environment) !void {
    try editableFixture(env.tmp.dir);
    try env.store.update(.{
        .instances = &.{ editable, delete_other },
        .servers = &.{
            .{ .id = "bound-one", .name = "First", .address = "localhost", .instance_id = editable.id },
            .{ .id = "bound-two", .name = "Second", .address = "localhost", .instance_id = editable.id },
            .{ .id = "unrelated", .name = "Other", .address = "localhost", .instance_id = delete_other.id },
        },
        .selected_instance = editable.id,
        .selected_server = "bound-two",
    });
}
fn expectDeletedConfiguration(store: *const config.Store) !void {
    try std.testing.expectEqual(@as(usize, 1), store.snapshot().instances.len);
    try std.testing.expect(module.sameInstance(delete_other, store.snapshot().instances[0]));
    try std.testing.expectEqual(@as(usize, 1), store.snapshot().servers.len);
    try std.testing.expectEqualStrings("unrelated", store.snapshot().servers[0].id);
}

test "permanent deletion publishes complete removal of bound servers after JOIN only" {
    for ([_]bool{ false, true }) |select_other| {
        var env = try Environment.init();
        defer env.deinit();
        try seedDeleteConfiguration(&env);
        if (select_other) {
            var latest = env.store.snapshot().*;
            latest.selected_instance = delete_other.id;
            latest.selected_server = "unrelated";
            try env.store.update(latest);
        }
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var fixture: Fixture = .{};
        var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
        defer manager.deinit();
        try manager.startDelete(editable);
        try settle(&manager);
        const job = manager.pending.?;
        try std.testing.expectEqual(module.Phase.awaiting_publication, manager.snapshot().phase);
        try std.testing.expectEqual(@import("core/instance_transactions.zig").Operation.deleted, job.result.?.operation);
        try std.testing.expect(manager.snapshot().recovery_directory == null);
        try std.testing.expect(module.sameInstance(editable, job.result.?.instance));
        try std.testing.expectError(error.FileNotFound, env.tmp.dir.access(io, ".minecraft/versions/Play", .{}));
        try env.tmp.dir.access(io, ".minecraft/versions/1.21/1.21.json", .{});
        try std.testing.expectEqual(@as(usize, 2), env.store.snapshot().instances.len);
        try std.testing.expectEqual(@as(usize, 3), env.store.snapshot().servers.len);
        try expectRetained(&manager, &fixture, &registry);
        try manager.publish(&env.store);
        try expectDeletedConfiguration(&env.store);
        if (select_other) {
            try std.testing.expectEqualStrings(delete_other.id, env.store.snapshot().selected_instance.?);
            try std.testing.expectEqualStrings("unrelated", env.store.snapshot().selected_server.?);
        } else {
            try std.testing.expect(env.store.snapshot().selected_instance == null);
            try std.testing.expect(env.store.snapshot().selected_server == null);
        }
        try std.testing.expectEqual(module.Phase.complete, manager.snapshot().phase);
        try std.testing.expect(manager.pending == null and !registry.hasActive());
        try std.testing.expectEqual(tasks.State.succeeded, registry.tasks()[0].state);
        try std.testing.expectEqual(@as(usize, 1), fixture.releases);
    }
}

test "permanent deletion stale whole row retains the owned result and never removes config" {
    try requireSyncFaults();
    var env = try Environment.init();
    defer env.deinit();
    try seedDeleteConfiguration(&env);
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    defer manager.deinit();
    try manager.startDelete(editable);
    try settle(&manager);
    const job = manager.pending.?;
    var fault: PublicationFaultIo = .{ .require_namespace = true };
    env.store.io = fault.start();
    defer fault.stop();
    const counts = fault.counts();
    for (0..5) |field| {
        const row = &@constCast(env.store.state.value.instances)[0];
        row.* = editable;
        switch (field) {
            0 => row.java_path = "/external/java",
            1 => row.min_memory_mb = 512,
            2 => row.max_memory_mb = 8192,
            3 => row.debug_launch = true,
            4 => row.origin = .{ .kind = .modrinth, .project_id = "external", .version_id = "release" },
            else => unreachable,
        }
        try std.testing.expectError(error.InstanceConfigurationChanged, manager.publish(&env.store));
        try std.testing.expectEqualDeep(counts, fault.counts());
        try std.testing.expect(manager.pending.? == job);
        try std.testing.expectEqual(@as(usize, 3), env.store.snapshot().servers.len);
        try expectRetained(&manager, &fixture, &registry);
    }
    @constCast(env.store.state.value.instances)[0] = editable;
    try manager.publish(&env.store);
    try expectDeletedConfiguration(&env.store);
    try std.testing.expectEqual(@as(usize, 1), fault.renames);
    try std.testing.expectEqual(@as(usize, 1), fixture.releases);
}

test "permanent deletion precommit config fault retries the same joined result" {
    try requireSyncFaults();
    var env = try Environment.init();
    defer env.deinit();
    try seedDeleteConfiguration(&env);
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    defer manager.deinit();
    try manager.startDelete(editable);
    try settle(&manager);
    const job = manager.pending.?;
    var fault: PublicationFaultIo = .{ .require_namespace = true, .fail_sync = 1 };
    env.store.io = fault.start();
    defer fault.stop();
    try std.testing.expectError(error.InputOutput, manager.publish(&env.store));
    try std.testing.expect(job.uncertain_publication_store == &env.store);
    try std.testing.expectEqual(@as(usize, 2), job.deleted_server_ids.?.len);
    try std.testing.expectEqual(@as(usize, 0), fault.renames);
    try fault.expectPublicationProtected();
    const blocked = fault.counts();
    try std.testing.expectError(error.ConfigPublicationUncertain, manager.publish(&env.store));
    try std.testing.expectEqualDeep(blocked, fault.counts());
    try expectRetained(&manager, &fixture, &registry);
    fault.reset();
    try env.store.reconcile();
    try std.testing.expectEqual(@as(usize, 2), env.store.snapshot().instances.len);
    try std.testing.expectEqual(@as(usize, 3), env.store.snapshot().servers.len);
    try std.testing.expect(manager.pending.? == job);
    fault.reset();
    try manager.publish(&env.store);
    try expectDeletedConfiguration(&env.store);
    try std.testing.expectEqual(@as(usize, 1), fault.renames);
    try fault.expectPublicationProtected();
    try std.testing.expectEqual(@as(usize, 1), fixture.releases);
}

test "permanent deletion reconciled committed save acknowledges without overwriting latest edits" {
    try requireSyncFaults();
    var env = try Environment.init();
    defer env.deinit();
    try seedDeleteConfiguration(&env);
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    defer manager.deinit();
    try manager.startDelete(editable);
    try settle(&manager);
    const job = manager.pending.?;
    var fault: PublicationFaultIo = .{ .require_namespace = true, .fail_sync = 3 };
    env.store.io = fault.start();
    defer fault.stop();
    try std.testing.expectError(error.InputOutput, manager.publish(&env.store));
    try std.testing.expectEqual(@as(usize, 1), fault.renames);
    try expectRetained(&manager, &fixture, &registry);
    fault.reset();
    fault.fail_sync = 1;
    try std.testing.expectError(error.InputOutput, env.store.reconcile());
    const blocked = fault.counts();
    try std.testing.expectError(error.ConfigPublicationUncertain, manager.publish(&env.store));
    try std.testing.expectEqualDeep(blocked, fault.counts());
    try expectRetained(&manager, &fixture, &registry);
    fault.reset();
    try env.store.reconcile();
    try expectDeletedConfiguration(&env.store);
    try std.testing.expectError(error.LauncherRootInUse, config.Store.init(a, io, env.root));
    var foreign = try Environment.init();
    defer foreign.deinit();
    try std.testing.expectError(error.ConfigurationStoreChanged, manager.publish(&foreign.store));
    var latest = env.store.snapshot().*;
    latest.settings.default_memory_mb = 8192;
    latest.selected_instance = delete_other.id;
    latest.selected_server = "unrelated";
    try env.store.update(latest);
    const counts = fault.counts();
    fixture.recheck_failure = error.LeaseLost;
    try std.testing.expectError(error.LeaseLost, manager.publish(&env.store));
    fixture.recheck_failure = null;
    const deleted = job.result.?.instance;
    job.result.?.instance.java_path = "/wrong/result";
    try std.testing.expectError(error.InvalidCompletedPublication, manager.publish(&env.store));
    job.result.?.instance = deleted;
    {
        job.done.store(false, .release);
        defer job.done.store(true, .release);
        try std.testing.expectError(error.PublicationWorkerNotJoined, manager.publish(&env.store));
    }
    {
        const operation = job.result.?.operation;
        job.result.?.operation = .renamed;
        defer job.result.?.operation = operation;
        try std.testing.expectError(error.InvalidCompletedPublication, manager.publish(&env.store));
    }
    {
        const id = job.result.?.instance.id;
        job.result.?.instance.id = delete_other.id;
        defer job.result.?.instance.id = id;
        try std.testing.expectError(error.InvalidCompletedPublication, manager.publish(&env.store));
    }
    {
        const snapshot = @constCast(env.store.snapshot());
        const saved = snapshot.servers;
        defer snapshot.servers = saved;
        const rebound = [_]config.Server{.{ .id = "bound-one", .name = "Rebound", .address = "localhost", .instance_id = delete_other.id }};
        snapshot.servers = &rebound;
        try std.testing.expectError(error.InstanceConfigurationChanged, manager.publish(&env.store));
    }
    {
        const selected = env.store.state.value.selected_instance;
        env.store.state.value.selected_instance = editable.id;
        defer env.store.state.value.selected_instance = selected;
        try std.testing.expectError(error.InstanceConfigurationChanged, manager.publish(&env.store));
    }
    {
        const selected = env.store.state.value.selected_server;
        env.store.state.value.selected_server = "bound-two";
        defer env.store.state.value.selected_server = selected;
        try std.testing.expectError(error.InstanceConfigurationChanged, manager.publish(&env.store));
    }
    {
        const snapshot = @constCast(env.store.snapshot());
        const saved = snapshot.servers;
        defer snapshot.servers = saved;
        const still_bound = [_]config.Server{.{ .id = "new-bound", .name = "Bound", .address = "localhost", .instance_id = editable.id }};
        snapshot.servers = &still_bound;
        try std.testing.expectError(error.InstanceConfigurationChanged, manager.publish(&env.store));
    }
    try std.testing.expectEqualDeep(counts, fault.counts());
    try std.testing.expect(manager.pending.? == job);
    try expectRetained(&manager, &fixture, &registry);
    manager.cancelAndJoin();
    try manager.publish(&env.store);
    try std.testing.expectEqualDeep(counts, fault.counts());
    try expectDeletedConfiguration(&env.store);
    try std.testing.expectEqual(@as(u32, 8192), env.store.snapshot().settings.default_memory_mb);
    try std.testing.expectEqualStrings(delete_other.id, env.store.snapshot().selected_instance.?);
    try std.testing.expectEqualStrings("unrelated", env.store.snapshot().selected_server.?);
    try std.testing.expectEqual(module.Phase.complete, manager.snapshot().phase);
    try std.testing.expectEqual(@as(usize, 1), fixture.releases);
    try std.testing.expectError(error.NoPendingPublication, manager.publish(&env.store));
    try std.testing.expectEqualDeep(counts, fault.counts());
}

test "permanent deletion external config absence cannot forge owned publication evidence" {
    for ([_]bool{ false, true }) |preexisting_uncertainty| {
        var env = try Environment.init();
        defer env.deinit();
        try seedDeleteConfiguration(&env);
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var fixture: Fixture = .{};
        var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
        defer manager.deinit();
        try manager.startDelete(editable);
        try settle(&manager);
        const job = manager.pending.?;
        try env.store.update(.{ .instances = &.{delete_other} });
        if (preexisting_uncertainty) {
            env.store.publication_uncertain = true;
            try std.testing.expectError(error.ConfigPublicationUncertain, manager.publish(&env.store));
            env.store.publication_uncertain = false;
        }
        try std.testing.expectError(error.InstanceConfigurationChanged, manager.publish(&env.store));
        try std.testing.expect(job.uncertain_publication_store == null and job.deleted_server_ids == null);
        try std.testing.expect(manager.pending.? == job);
        try expectRetained(&manager, &fixture, &registry);
    }
}

test "permanent deletion partial worker debt stays leased and cannot retry by starting again" {
    for ([_]anyerror{ error.PermanentDeletionIncomplete, error.InputOutput, error.Canceled }) |failure| {
        var env = try Environment.init();
        defer env.deinit();
        try seedDeleteConfiguration(&env);
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        // Inject a worker-side error before filesystem mutation; this test audits
        // manager classification without needing a destructive filesystem fault.
        var fixture: Fixture = .{ .recheck_failure = failure };
        var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
        var live = true;
        defer if (live) manager.deinit();
        try manager.startDelete(editable);
        try settle(&manager);
        try std.testing.expectEqual(failure, manager.snapshot().failure.?);
        try std.testing.expectEqual(@as(usize, 2), env.store.snapshot().instances.len);
        try std.testing.expectEqual(@as(usize, 3), env.store.snapshot().servers.len);
        try env.tmp.dir.access(io, ".minecraft/versions/Play/saves/World/level.dat", .{});
        try std.testing.expect(!registry.hasActive());
        if (failure == error.PermanentDeletionIncomplete) {
            const job = manager.pending.?;
            try std.testing.expect(manager.isBusy() and job.leased and fixture.held.load(.acquire));
            try std.testing.expect(job.future == null and job.done.load(.acquire) and job.task == null);
            try std.testing.expect(manager.snapshot().recovery_directory == null);
            try std.testing.expectError(error.PermanentDeletionIncomplete, manager.publish(&env.store));
            try std.testing.expectError(error.Busy, manager.startDelete(editable));
            manager.cancel();
            manager.cancelAndJoin();
            manager.tick();
            try std.testing.expect(manager.pending.? == job and fixture.releases == 0);
            try std.testing.expectError(error.InstanceNamespaceBusy, @import("core/instance_namespace.zig").acquire(io));
        } else {
            try std.testing.expect(!manager.isBusy() and !fixture.held.load(.acquire));
            try std.testing.expectEqual(@as(usize, 1), fixture.releases);
        }
        manager.deinit();
        live = false;
        try std.testing.expectEqual(@as(usize, 1), fixture.releases);
    }
}

test "permanent deletion late cancelAndJoin preserves committed removal and publication" {
    var env = try Environment.init();
    defer env.deinit();
    try seedDeleteConfiguration(&env);
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    defer manager.deinit();
    try manager.startDelete(editable);
    try waitWorkerDone(&manager);
    const job = manager.active.?;
    manager.cancelAndJoin();
    manager.cancelAndJoin();
    manager.tick();
    try std.testing.expect(manager.active == null and manager.pending.? == job);
    try std.testing.expectEqual(module.Phase.awaiting_publication, manager.snapshot().phase);
    try std.testing.expect(manager.snapshot().recovery_directory == null);
    try expectRetained(&manager, &fixture, &registry);
    try manager.publish(&env.store);
    try expectDeletedConfiguration(&env.store);
    try std.testing.expectEqual(tasks.State.succeeded, registry.tasks()[0].state);
    try std.testing.expectEqual(@as(usize, 1), fixture.releases);
}

fn deletionProofPublicationFixture(reconciled_save: bool) !void {
    try requireSyncFaults();
    for ([_]bool{ false, true }) |replace_versions| {
        var env = try Environment.init();
        defer env.deinit();
        try seedDeleteConfiguration(&env);
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var fixture: Fixture = .{};
        var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
        defer manager.deinit();
        try manager.startDelete(editable);
        try settle(&manager);
        const job = manager.pending.?;
        try std.testing.expect(job.result.?.deletion_proof != null);
        try std.testing.expect(manager.snapshot().recovery_directory == null);
        try std.testing.expectError(error.FileNotFound, env.tmp.dir.access(io, ".minecraft/versions/Play", .{}));
        var fault: PublicationFaultIo = .{ .require_namespace = true };
        env.store.io = fault.start();
        defer fault.stop();
        if (reconciled_save) {
            fault.fail_sync = 3;
            try std.testing.expectError(error.InputOutput, manager.publish(&env.store));
            try std.testing.expect(job.uncertain_publication_store == &env.store);
            fault.reset();
            try env.store.reconcile();
            try expectDeletedConfiguration(&env.store);
        }
        // Substitute only directories in this fixture's isolated temporary root.
        // Keep the original versions directory alive so restoring it preserves
        // its identity and permits retry against the original deletion proof.
        if (replace_versions) {
            try env.tmp.dir.renamePreserve(".minecraft/versions", env.tmp.dir, ".minecraft/versions-held", io);
            try env.tmp.dir.createDirPath(io, ".minecraft/versions");
        } else {
            try env.tmp.dir.createDirPath(io, ".minecraft/versions/Play");
        }
        const before = try std.json.Stringify.valueAlloc(a, env.store.snapshot().*, .{ .emit_null_optional_fields = false });
        defer a.free(before);
        const counts = fault.counts();
        if (manager.publish(&env.store)) |_| return error.ExpectedDeletionPublicationProofFailure else |_| {}
        try std.testing.expectEqualDeep(counts, fault.counts());
        try std.testing.expectEqual(module.Phase.awaiting_publication, manager.snapshot().phase);
        try std.testing.expect(manager.pending.? == job and job.result.?.deletion_proof != null);
        try expectRetained(&manager, &fixture, &registry);
        const after = try std.json.Stringify.valueAlloc(a, env.store.snapshot().*, .{ .emit_null_optional_fields = false });
        defer a.free(after);
        try std.testing.expectEqualStrings(before, after);
        if (replace_versions) {
            try env.tmp.dir.access(io, ".minecraft/versions", .{});
            try env.tmp.dir.access(io, ".minecraft/versions-held/1.21/1.21.json", .{});
            // Remove only the externally substituted empty directory, then put
            // back the original pinned directory without changing its identity.
            try env.tmp.dir.deleteDir(io, ".minecraft/versions");
            try env.tmp.dir.renamePreserve(".minecraft/versions-held", env.tmp.dir, ".minecraft/versions", io);
        } else {
            try env.tmp.dir.access(io, ".minecraft/versions/Play", .{});
            // The manager rejected publication and did not erase this new tree.
            // The fixture removes its own empty external recreation explicitly.
            try env.tmp.dir.deleteDir(io, ".minecraft/versions/Play");
        }
        fault.reset();
        try manager.publish(&env.store);
        if (reconciled_save) {
            try std.testing.expectEqual(@as(usize, 0), fault.writes);
            try std.testing.expectEqual(@as(usize, 0), fault.syncs);
            try std.testing.expectEqual(@as(usize, 0), fault.renames);
        } else {
            try std.testing.expectEqual(@as(usize, 1), fault.renames);
            try fault.expectPublicationProtected();
        }
        try expectDeletedConfiguration(&env.store);
        try env.tmp.dir.access(io, ".minecraft/versions/1.21/1.21.json", .{});
        try std.testing.expectEqual(module.Phase.complete, manager.snapshot().phase);
        try std.testing.expect(manager.pending == null and !registry.hasActive());
        try std.testing.expect(job.result.?.deletion_proof == null);
        try std.testing.expectEqual(tasks.State.succeeded, registry.tasks()[0].state);
        try std.testing.expectEqual(@as(usize, 1), fixture.releases);
    }
}

test "permanent deletion pending publication rejects recreated target and substituted versions" {
    try deletionProofPublicationFixture(false);
}

test "permanent deletion reconciled acknowledgment rejects recreated target and substituted versions" {
    try deletionProofPublicationFixture(true);
}

test "manager retains copied live and terminal file details after task dismissal and pruning" {
    for ([_]enum { success, failure, canceled }{ .success, .failure, .canceled }) |outcome| {
        var env = try Environment.init();
        defer env.deinit();
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var fixture: Fixture = .{ .telemetry = true, .failure = if (outcome == .failure) error.ChecksumMismatch else null };
        fixture.blocked.store(true, .release);
        var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
        defer manager.deinit();
        manager.setInstaller(fixture.installer());
        try manager.startCreate(example);
        try waitEntered(&fixture);
        const live = manager.snapshot();
        const id = live.task_id.?;
        try std.testing.expectEqual(module.Phase.working, live.phase);
        try std.testing.expectEqual(@as(u64, 0), live.details.completed);
        try std.testing.expectEqual(@as(u64, 64), live.details.received);
        try std.testing.expectEqual(@as(?u64, 128), live.details.total_bytes);
        try std.testing.expectEqual(@as(f64, 512), live.details.bytes_per_second);
        try std.testing.expectEqualStrings("lib.jar", live.details.files[0].name());
        try std.testing.expectEqualStrings("/t/lib.jar", live.details.files[0].path());
        try std.testing.expect(!registry.dismiss(id));
        if (outcome == .canceled) manager.cancel();
        fixture.blocked.store(false, .release);
        try settle(&manager);
        if (outcome == .success) {
            try std.testing.expectEqual(module.Phase.awaiting_publication, manager.snapshot().phase);
            try manager.publish(&env.store);
        }
        const terminal_snapshot = manager.snapshot();
        try std.testing.expectEqual(@as(?u64, id), terminal_snapshot.task_id);
        try std.testing.expectEqual(@as(f64, 0), terminal_snapshot.details.bytes_per_second);
        try std.testing.expectEqual(@as(f64, 0), terminal_snapshot.details.files[0].bytes_per_second);
        try std.testing.expectEqual(switch (outcome) {
            .success => tasks.FileState.complete,
            .failure => .failed,
            .canceled => .canceled,
        }, terminal_snapshot.details.files[0].state);
        if (outcome == .failure) {
            try std.testing.expectEqual(@as(?anyerror, error.ChecksumMismatch), terminal_snapshot.failure);
            try std.testing.expectEqual(@as(?anyerror, error.ChecksumMismatch), terminal_snapshot.details.files[0].failure);
        }
        if (outcome == .success) try std.testing.expectEqual(@as(usize, 1), terminal_snapshot.completed);
        if (outcome == .failure) try std.testing.expect(registry.dismiss(id)) else registry.pruneFinished(0);
        try std.testing.expectEqual(@as(usize, 0), registry.tasks().len);
        const after_prune = manager.snapshot();
        try std.testing.expectEqual(@as(?u64, id), after_prune.task_id);
        try std.testing.expectEqualDeep(terminal_snapshot.details, after_prune.details);
        try std.testing.expectEqualStrings("lib.jar", after_prune.details.files[0].name());
    }
}

const StageFault = @import("core/loaders/tests/stage_owner.zig").FaultIo;

test "instance manager production stage rolls back cancellation open and sync acquisition faults" {
    for ([_]StageFault.Mode{ .cancel_create, .fail_open, .fail_sync }) |mode| {
        if (mode == .fail_sync and !@import("core/worlds_tree.zig").directory_sync_supported) continue;
        var env = try Environment.init();
        defer env.deinit();
        var lease_fixture: Fixture = .{};
        const lease = lease_fixture.lease();
        try lease.acquire(lease.context, example.id);
        defer lease.release(lease.context, example.id);
        var fault: StageFault = .{ .mode = mode, .prefix = ".vela-instance-" };
        const fault_io = fault.start();
        defer fault.stop();
        var canceled: std.atomic.Value(bool) = .init(false);
        const installer = module.productionInstaller();
        const expected = switch (mode) {
            .cancel_create => error.Canceled,
            .fail_open => error.AccessDenied,
            .fail_sync => error.InputOutput,
            else => unreachable,
        };
        try std.testing.expectError(expected, installer.run(installer.context, a, fault_io, .{ .root = env.root, .instance = example, .lease = lease }, .{ .cancel = &canceled }));
        try std.testing.expect(fault.created and fault.removed);
        const versions_path = try std.fs.path.join(a, &.{ env.root, ".minecraft", "versions" });
        defer a.free(versions_path);
        var versions = try std.Io.Dir.cwd().openDir(io, versions_path, .{ .iterate = true });
        defer versions.close(io);
        var iterator = versions.iterate();
        while (try iterator.next(io)) |entry| try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".vela-instance-"));
        try std.testing.expectError(error.FileNotFound, versions.statFile(io, example.name, .{ .follow_symlinks = false }));
    }
}

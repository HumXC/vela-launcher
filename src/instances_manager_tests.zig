const std = @import("std");
const module = @import("ui/instances_manager.zig");
const config = @import("core/config.zig");
const instances = @import("core/instances.zig");
const tasks = @import("core/tasks.zig");
const loader_install = @import("core/minecraft/loader_install.zig");
const loaders = @import("core/minecraft/loaders.zig");
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
    fn deinit(self: *Environment) void {
        self.store.deinit();
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
        self.entered.store(true, .release);
        while (self.blocked.load(.acquire)) {
            try control.check();
            try worker_io.sleep(.fromMilliseconds(1), .awake);
        }
        try control.check();
        try request.lease.recheck(request.lease.context, request.instance.id);
        if (self.failure) |err| return err;
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
        return .{ .arena = arena, .base = try g.dupe(u8, base), .kind = kind, .entries = entries };
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

    const Counts = struct { syncs: usize, renames: usize, writes: usize };

    fn start(self: *PublicationFaultIo) std.Io {
        std.debug.assert(active == null);
        active = self;
        self.vtable = self.real.vtable.*;
        self.vtable.fileSync = sync;
        self.vtable.dirRename = rename;
        self.vtable.operate = operate;
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
    }
    fn counts(self: *const PublicationFaultIo) Counts {
        return .{ .syncs = self.syncs, .renames = self.renames, .writes = self.writes };
    }
    fn sync(ctx: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
        const self = active.?;
        self.syncs += 1;
        if (self.fail_sync == self.syncs) return error.InputOutput;
        return self.real.vtable.fileSync(ctx, file);
    }
    fn rename(ctx: ?*anyopaque, old_dir: std.Io.Dir, old_path: []const u8, new_dir: std.Io.Dir, new_path: []const u8) std.Io.Dir.RenameError!void {
        const self = active.?;
        self.renames += 1;
        return self.real.vtable.dirRename(ctx, old_dir, old_path, new_dir, new_path);
    }
    fn operate(ctx: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
        const self = active.?;
        switch (operation) {
            .file_write_streaming => self.writes += 1,
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
    fault.fail_sync = 1;
    try std.testing.expectError(error.InputOutput, manager.publish(&env.store));
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
    fault.fail_sync = 3;
    try std.testing.expectError(error.InputOutput, manager.publish(&env.store));
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
    updated.max_memory_mb = 4096;
    updated.debug_launch = true;
    try manager.saveOptions(&env.store, updated);
    try std.testing.expectEqual(@as(?u32, 4096), env.store.snapshot().instances[0].max_memory_mb);
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
    try std.testing.checkAllAllocationFailures(a, allocationFailure, .{&env.paths});
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
    var alias = try config.Store.init(a, io, env.root);
    defer alias.deinit();
    const counts = fault.counts();
    try std.testing.expectError(error.ConfigurationStoreChanged, manager.acknowledgeReconciledCreation(&alias));
    try std.testing.expectError(error.ConfigurationStoreChanged, manager.acknowledgeReconciledCreation(&foreign.store));
    try std.testing.expectError(error.ConfigurationStoreChanged, manager.publish(&alias));
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

test "instance manager import acknowledgment uses the owned completed value rather than original request" {
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
    {
        // Seed a joined fake import result; this does not test filesystem import.
        var arena: std.heap.ArenaAllocator = .init(a);
        errdefer arena.deinit();
        const value = try module.cloneInstance(arena.allocator(), completed);
        job.result = .{ .arena = arena, .operation = .imported, .instance = value };
    }
    job.operation = .importing;
    manager.operation = .importing;
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
    try std.testing.expectEqual(module.Operation.importing, manager.snapshot().operation);
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

const canonical_import: Instance = .{ .id = "canonical-existing", .name = "26.3", .minecraft_version = "" };
fn canonicalImportBytes(alloc: std.mem.Allocator) ![]u8 {
    var client_hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash("base", &client_hash, .{});
    return std.json.Stringify.valueAlloc(alloc, .{ .id = "26.3", .mainClass = "net.minecraft.client.main.Main", .javaVersion = .{ .component = "java-runtime-delta", .majorVersion = 25 }, .downloads = .{ .client = .{ .url = "https://piston-data.mojang.com/v1/objects/fixture/client.jar", .sha1 = &std.fmt.bytesToHex(&client_hash, .lower), .size = 4 } } }, .{});
}
fn seedCanonicalImport(dir: std.Io.Dir) !void {
    const bytes = try canonicalImportBytes(a);
    defer a.free(bytes);
    try dir.createDirPath(io, ".minecraft/versions/26.3/mods");
    try dir.createDirPath(io, ".minecraft/versions/26.3/saves/world");
    try dir.writeFile(io, .{ .sub_path = ".minecraft/versions/26.3/26.3.json", .data = bytes });
    try dir.writeFile(io, .{ .sub_path = ".minecraft/versions/26.3/26.3.jar", .data = "base" });
    try dir.writeFile(io, .{ .sub_path = ".minecraft/versions/26.3/mods/keep.jar", .data = "mod" });
    try dir.writeFile(io, .{ .sub_path = ".minecraft/versions/26.3/saves/world/level.dat", .data = "world" });
}
const CanonicalImportPreparation = struct {
    entered: std.atomic.Value(bool) = .init(false),
    blocked: std.atomic.Value(bool) = .init(false),
    calls: usize = 0,
    corrupt_pin: bool = false,
    wrong_generation: bool = false,
    fn adapter(self: *CanonicalImportPreparation) module.VanillaPreparationAdapter {
        return .{ .context = self, .prepare = prepare };
    }
    fn prepare(raw: ?*anyopaque, alloc: std.mem.Allocator, worker_io: std.Io, requested: metadata_loader.VanillaTarget, control: module.Control) !metadata_loader.PreparedVanilla {
        const self: *CanonicalImportPreparation = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        self.entered.store(true, .release);
        while (self.blocked.load(.acquire)) {
            try control.check();
            try worker_io.sleep(.fromMilliseconds(1), .awake);
        }
        try control.check();
        const bytes = try canonicalImportBytes(alloc);
        defer alloc.free(bytes);
        var metadata_hash: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(bytes, &metadata_hash, .{});
        if (self.corrupt_pin) metadata_hash[0] ^= 1;
        const entries = [_]metadata.manifest.Entry{.{ .id = "26.3", .kind = "release", .url = "https://piston-meta.mojang.com/v1/packages/fixture/26.3.json", .time = "", .release_time = "", .sha1 = metadata_hash, .compliance_level = null }};
        const minecraft_root = try std.fs.path.join(alloc, &.{ requested.root, ".minecraft" });
        defer alloc.free(minecraft_root);
        var target = requested;
        if (self.wrong_generation) target.generation += 1;
        return metadata_loader.prepareVanilla(alloc, worker_io, .{ .target = target, .vanilla = .{ .root = minecraft_root, .version_id = target.version_id, .manifest = .{ .latest = .{ .release = "26.3", .snapshot = "26.3" }, .versions = &entries }, .cancel = control.cancel }, .fetcher = .{} });
    }
    fn waitEntered(self: *CanonicalImportPreparation) !void {
        const started = std.Io.Clock.awake.now(io).nanoseconds;
        while (!self.entered.load(.acquire)) {
            if (std.Io.Clock.awake.now(io).nanoseconds - started > 3 * std.time.ns_per_s) return error.FixtureTimeout;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
    }
};
fn expectCanonicalData(dir: std.Io.Dir) !void {
    for ([_]struct { path: []const u8, bytes: []const u8 }{
        .{ .path = ".minecraft/versions/26.3/26.3.jar", .bytes = "base" },
        .{ .path = ".minecraft/versions/26.3/mods/keep.jar", .bytes = "mod" },
        .{ .path = ".minecraft/versions/26.3/saves/world/level.dat", .bytes = "world" },
    }) |entry| {
        const bytes = try dir.readFileAlloc(io, entry.path, a, .limited(64));
        defer a.free(bytes);
        try std.testing.expectEqualStrings(entry.bytes, bytes);
    }
    try std.testing.expectError(error.FileNotFound, dir.statFile(io, ".minecraft/versions/26.3/.vela-instance.json", .{ .follow_symlinks = false }));
    try std.testing.expectError(error.FileNotFound, dir.statFile(io, ".minecraft/versions/26.3/.vela-loader.json", .{ .follow_symlinks = false }));
}

test "canonical existing import retains authenticated owner through JOIN and publishes once under lease" {
    var env = try Environment.init();
    defer env.deinit();
    try seedCanonicalImport(env.tmp.dir);
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{};
    var preparation: CanonicalImportPreparation = .{};
    var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
    defer manager.deinit();
    manager.setVanillaPreparation(preparation.adapter());
    try manager.startImport(canonical_import);
    try std.testing.expectError(error.NoPendingPublication, manager.publish(&env.store));
    try std.testing.expect(!manager.snapshot().local_client_verified);
    try settle(&manager);
    try expectRetained(&manager, &fixture, &registry);
    const job = manager.pending.?;
    try std.testing.expect(job.import_prepared != null and job.result.?.local_client_verified);
    try std.testing.expectEqual(@as(u64, 1), job.import_prepared.?.target.generation);
    try std.testing.expectEqualStrings("26.3", job.result.?.instance.minecraft_version);
    try std.testing.expectEqual(@as(usize, 0), env.store.snapshot().instances.len);
    try std.testing.expect(!manager.snapshot().local_client_verified);
    fixture.recheck_failure = error.LeaseLost;
    try std.testing.expectError(error.LeaseLost, manager.publish(&env.store));
    try std.testing.expect(manager.pending.? == job and job.import_prepared != null);
    fixture.recheck_failure = null;
    try manager.publish(&env.store);
    try std.testing.expectEqual(@as(usize, 1), env.store.snapshot().instances.len);
    try std.testing.expectEqualStrings(canonical_import.id, env.store.snapshot().selected_instance.?);
    try std.testing.expectEqualStrings("26.3", env.store.snapshot().instances[0].minecraft_version);
    try std.testing.expect(manager.snapshot().local_client_verified and job.import_prepared == null and job.result.?.publication_proof == null);
    try std.testing.expectEqual(@as(usize, 1), fixture.releases);
    try std.testing.expectEqual(@as(usize, 1), preparation.calls);
    try std.testing.expectError(error.NoPendingPublication, manager.publish(&env.store));
    try expectCanonicalData(env.tmp.dir);
}

test "canonical publication rejects modified or replaced sources and retains pending evidence" {
    for (0..8) |change| {
        var env = try Environment.init();
        defer env.deinit();
        try seedCanonicalImport(env.tmp.dir);
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var fixture: Fixture = .{};
        var preparation: CanonicalImportPreparation = .{};
        var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
        var live = true;
        defer if (live) manager.deinit();
        manager.setVanillaPreparation(preparation.adapter());
        try manager.startImport(canonical_import);
        try settle(&manager);
        const job = manager.pending.?;
        switch (change) {
            0 => try env.tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/26.3/26.3.jar", .data = "changed-client" }),
            1 => try env.tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/26.3/26.3.json", .data = "{}" }),
            2, 3 => {
                const path = if (change == 2) ".minecraft/versions/26.3/26.3.jar" else ".minecraft/versions/26.3/26.3.json";
                const bytes = if (change == 2) try a.dupe(u8, "base") else try canonicalImportBytes(a);
                defer a.free(bytes);
                try env.tmp.dir.rename(path, env.tmp.dir, ".minecraft/versions/26.3/replaced-original", io);
                try env.tmp.dir.writeFile(io, .{ .sub_path = path, .data = bytes });
            },
            4 => {
                try env.tmp.dir.rename(".minecraft/versions/26.3", env.tmp.dir, ".minecraft/versions/held-original", io);
                try env.tmp.dir.createDirPath(io, ".minecraft/versions/26.3");
            },
            5 => try env.tmp.dir.hardLink(".minecraft/versions/26.3/26.3.jar", env.tmp.dir, "outside-client-alias", io, .{}),
            6 => try env.tmp.dir.hardLink(".minecraft/versions/26.3/26.3.json", env.tmp.dir, "outside-metadata-alias", io, .{}),
            7 => {
                try env.tmp.dir.rename(".minecraft", env.tmp.dir, "held-minecraft", io);
                try env.tmp.dir.createDirPath(io, ".minecraft/versions/26.3");
            },
            else => unreachable,
        }
        const expected = if (change == 5 or change == 6) error.HardLinkAlias else error.TreeChanged;
        try std.testing.expectError(expected, manager.publish(&env.store));
        try std.testing.expectEqual(@as(usize, 0), env.store.snapshot().instances.len);
        try std.testing.expect(env.store.snapshot().selected_instance == null and !manager.snapshot().local_client_verified);
        try std.testing.expectEqual(@as(anyerror, expected), manager.snapshot().failure orelse return error.ExpectedPublicationFailure);
        try std.testing.expect(manager.pending.? == job and job.import_prepared != null and job.result.?.publication_proof != null);
        manager.cancelAndJoin();
        try expectRetained(&manager, &fixture, &registry);
        manager.deinit();
        live = false;
        try std.testing.expectEqual(@as(usize, 1), fixture.releases);
        try std.testing.expect(!fixture.held.load(.acquire) and !registry.hasActive());
    }
}

test "canonical reconciled publication checks freshness without rewriting authoritative config" {
    try requireSyncFaults();
    for ([_]bool{ false, true }) |changed| {
        var fault: PublicationFaultIo = .{};
        const store_io = fault.start();
        defer fault.stop();
        var env = try Environment.initWithStoreIo(store_io);
        defer env.deinit();
        try env.store.update(.{});
        try seedCanonicalImport(env.tmp.dir);
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var fixture: Fixture = .{};
        var preparation: CanonicalImportPreparation = .{};
        var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
        defer manager.deinit();
        manager.setVanillaPreparation(preparation.adapter());
        try manager.startImport(canonical_import);
        try settle(&manager);
        const job = manager.pending.?;
        fault.reset();
        fault.fail_sync = 3;
        try std.testing.expectError(error.InputOutput, manager.publish(&env.store));
        try std.testing.expect(job.uncertain_publication_store == &env.store and job.import_prepared != null);
        fault.reset();
        try env.store.reconcile();
        try std.testing.expectEqual(@as(usize, 1), env.store.snapshot().instances.len);
        const before = try std.json.Stringify.valueAlloc(a, env.store.snapshot().*, .{});
        defer a.free(before);
        const counts = fault.counts();
        if (changed) {
            try env.tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/26.3/26.3.jar", .data = "changed-after-rename" });
            try std.testing.expectError(error.TreeChanged, manager.acknowledgeReconciledCreation(&env.store));
            try expectRetained(&manager, &fixture, &registry);
            try std.testing.expect(job.import_prepared != null and !manager.snapshot().local_client_verified);
            try std.testing.expectEqual(@as(anyerror, error.TreeChanged), manager.snapshot().failure orelse return error.ExpectedPublicationFailure);
        } else {
            try manager.acknowledgeReconciledCreation(&env.store);
            try std.testing.expect(manager.snapshot().local_client_verified and job.import_prepared == null);
            try std.testing.expectEqual(@as(usize, 1), fixture.releases);
        }
        const after = try std.json.Stringify.valueAlloc(a, env.store.snapshot().*, .{});
        defer a.free(after);
        try std.testing.expectEqualStrings(before, after);
        try std.testing.expectEqualDeep(counts, fault.counts());
    }
}

test "canonical preparation rejects unauthenticated pins foreign generation and cancellation after start" {
    for (0..3) |mode| {
        var env = try Environment.init();
        defer env.deinit();
        try seedCanonicalImport(env.tmp.dir);
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var fixture: Fixture = .{};
        var preparation: CanonicalImportPreparation = .{ .corrupt_pin = mode == 0, .wrong_generation = mode == 1 };
        preparation.blocked.store(mode == 2, .release);
        var manager = try module.Manager.init(a, io, &env.paths, &registry, .{}, fixture.lease());
        defer manager.deinit();
        manager.setVanillaPreparation(preparation.adapter());
        try manager.startImport(canonical_import);
        if (mode == 2) {
            try preparation.waitEntered();
            manager.cancel();
        }
        try settle(&manager);
        const expected = switch (mode) {
            0 => error.ChecksumMismatch,
            1 => error.PreparedMetadataGenerationMismatch,
            2 => error.Canceled,
            else => unreachable,
        };
        try std.testing.expectEqual(@as(anyerror, expected), manager.snapshot().failure orelse return error.ExpectedPreparationFailure);
        try std.testing.expect(!manager.snapshot().local_client_verified);
        try std.testing.expect(manager.pending == null and manager.published.?.import_prepared == null);
        try std.testing.expectEqual(@as(usize, 0), env.store.snapshot().instances.len);
        try std.testing.expectEqual(@as(usize, 1), fixture.releases);
        try std.testing.expect(!fixture.held.load(.acquire) and !registry.hasActive());
        try expectCanonicalData(env.tmp.dir);
    }
}
fn canonicalManagerAllocationFailure(alloc: std.mem.Allocator, paths: *const instances.Paths) !void {
    var registry = tasks.Registry.init(alloc);
    defer registry.deinit();
    var fixture: Fixture = .{};
    defer std.debug.assert(!fixture.held.load(.acquire));
    var preparation: CanonicalImportPreparation = .{};
    var manager = try module.Manager.init(alloc, io, paths, &registry, .{}, fixture.lease());
    defer manager.deinit();
    manager.setVanillaPreparation(preparation.adapter());
    try manager.startImport(canonical_import);
    try settle(&manager);
    if (manager.snapshot().failure) |err| return err;
    try std.testing.expectEqual(module.Phase.awaiting_publication, manager.snapshot().phase);
    try std.testing.expect(manager.pending.?.import_prepared != null and manager.pending.?.result.?.publication_proof != null);
}
test "canonical manager allocation failures release request prepared proof handles and lease after JOIN" {
    var env = try Environment.init();
    defer env.deinit();
    try seedCanonicalImport(env.tmp.dir);
    try std.testing.checkAllAllocationFailures(a, canonicalManagerAllocationFailure, .{&env.paths});
    try expectCanonicalData(env.tmp.dir);
}

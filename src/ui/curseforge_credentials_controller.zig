//! GUI-owned serial CF credential controller. No DVUI, startup recovery, or vault probe.
//! The owner must preserve the CF reference while lease() is true. Unrelated settings
//! may change: core publication merges the latest GUI-owned config snapshot.
const std = @import("std");
const config = @import("../core/config.zig");
const credentials = @import("../core/credentials.zig");
const core = @import("../core/curseforge_credentials_manager.zig");
const tasks = @import("../core/tasks.zig");
const Allocator = std.mem.Allocator;

pub const Policy = core.Policy;
pub const Phase = enum { idle, preparing, publishing, acknowledging, recovering, succeeded, cancelled, failed, recovery_required, committed_cleanup_pending };
pub const Snapshot = struct {
    phase: Phase,
    busy: bool,
    worker_active: bool,
    publication_pending: bool,
    recovery_required: bool,
    committed: bool,
    commit_uncertain: bool,
    cleanup_pending: bool,
    failure: ?anyerror,
    task_id: ?u64,
};
pub const Options = struct {
    injected_store: ?credentials.Store = null,
    registry: ?*tasks.Registry = null,
    task_kind: ?tasks.Kind = .credential_update,
};

pub const Controller = struct {
    allocator: Allocator,
    io: std.Io,
    core_manager: *core.Manager,
    registry: ?*tasks.Registry,
    task_kind: ?tasks.Kind,
    active: ?*Job = null,
    phase: Phase = .idle,
    failure: ?anyerror = null,
    frozen: bool = false,
    publication_pending: bool = false,
    recovery_required: bool = false,
    committed: bool = false,
    commit_uncertain: bool = false,
    reconcile_required: bool = false,
    last_task_id: ?u64 = null,
    // Local thread-failure seam; jobs never borrow the movable GUI controller.
    spawn: *const fn (*Job) anyerror!std.Thread = spawnThread,

    pub fn init(a: Allocator, io: std.Io, root: []const u8, options: Options) !Controller {
        if (options.registry != null and options.task_kind == null) return error.TaskKindRequired;
        const manager = try a.create(core.Manager);
        errdefer a.destroy(manager);
        manager.* = try core.Manager.init(a, io, root, options.injected_store);
        var self: Controller = .{ .allocator = a, .io = io, .core_manager = manager, .registry = options.registry, .task_kind = options.task_kind };
        self.refreshDebt();
        if (self.frozen) self.phase = .recovery_required;
        return self;
    }

    /// Registry and injected store must outlive this call. Native calls cannot be
    /// interrupted, so cancellation is followed by an unconditional worker join.
    pub fn deinit(self: *Controller) void {
        if (self.active) |job| {
            self.cancel();
            job.join();
            const failure: ?anyerror = if (job.failure) |err| err else if (job.action == .set or job.action == .remove) error.Cancelled else null;
            self.finishJoined(job, failure);
        }
        self.core_manager.deinit();
        self.allocator.destroy(self.core_manager);
        self.* = undefined;
    }

    /// Busy includes retained debt, not merely a running thread. Only explicit
    /// recovery is permitted when a completed command still holds the lease.
    pub fn isBusy(self: *const Controller) bool {
        return self.active != null or self.frozen;
    }

    pub fn lease(self: *const Controller) bool {
        return self.isBusy();
    }

    pub fn snapshot(self: *const Controller) Snapshot {
        // Never inspect the mutable core manager while its worker owns it.
        return .{ .phase = self.phase, .busy = self.isBusy(), .worker_active = self.active != null, .publication_pending = self.publication_pending, .recovery_required = self.recovery_required, .committed = self.committed, .commit_uncertain = self.commit_uncertain, .cleanup_pending = self.committed and self.frozen, .failure = self.failure, .task_id = self.last_task_id };
    }

    /// Consumes the caller's Secret on EVERY path, including Busy and preflight
    /// failure. Only ownership metadata moves; key bytes are never duplicated.
    pub fn startSet(self: *Controller, store: *config.Store, secret: *credentials.Secret, policy: Policy) !void {
        defer secret.deinit();
        try self.requireReady();
        self.beginCommand();
        const prior = core.prepareConfig(self.core_manager, store) catch |err| {
            self.commit_uncertain = store.publicationUncertain();
            return self.enqueueFailure(err);
        };
        var random: [16]u8 = undefined;
        self.io.randomSecure(&random) catch |err| return self.enqueueFailure(err);
        const reference = std.fmt.bytesToHex(random, .lower);
        if (prior.active) |old| if (std.mem.eql(u8, &old, &reference)) return self.enqueueFailure(error.ReferenceCollision);
        const job = self.newJob(.set, prior, policy) catch |err| return self.enqueueFailure(err);
        errdefer job.destroy();
        job.new_ref = reference;
        job.secret = secret.*;
        secret.bytes = &.{};
        self.launch(job, .preparing) catch |err| return self.enqueueFailure(err);
    }

    pub fn startRemove(self: *Controller, store: *config.Store, policy: Policy) !void {
        try self.requireReady();
        self.beginCommand();
        const prior = core.prepareConfig(self.core_manager, store) catch |err| {
            self.commit_uncertain = store.publicationUncertain();
            return self.enqueueFailure(err);
        };
        if (prior.active == null) return self.enqueueFailure(error.NoCredential);
        const job = self.newJob(.remove, prior, policy) catch |err| return self.enqueueFailure(err);
        errdefer job.destroy();
        self.launch(job, .preparing) catch |err| return self.enqueueFailure(err);
    }

    /// Explicit only. Reconciliation reads authoritative disk on the GUI thread;
    /// neither a settings draft nor an in-memory snapshot becomes recovery proof.
    pub fn startRecovery(self: *Controller, store: *config.Store) !void {
        if (self.active != null) return error.Busy;
        if (!std.mem.eql(u8, store.root, self.core_manager.journal.root)) return error.ForeignConfig;
        self.frozen = true;
        self.reconcile_required = true;
        self.failure = null;
        const confirmed = core.reconcileConfig(store) catch |err| {
            self.commit_uncertain = store.publicationUncertain();
            return self.enqueueFailure(err);
        };
        self.reconcile_required = false;
        if (self.commit_uncertain) {
            if (self.core_manager.pending()) |pending| {
                const expected: ?credentials.Reference = if (pending.action == .set) pending.new_ref else null;
                if (std.meta.eql(expected, confirmed.active)) self.committed = true;
            }
        }
        self.commit_uncertain = false;
        const job = self.newJob(.recover, confirmed, .{ .enabled = false, .terms_approved = false }) catch |err| return self.enqueueFailure(err);
        errdefer job.destroy();
        self.launch(job, .recovering) catch |err| return self.enqueueFailure(err);
    }

    pub fn cancel(self: *Controller) void {
        if (self.active) |job| {
            if (job.task) |task| {
                _ = self.registry.?.cancel(task.id);
            } else job.cancellation.store(true, .release);
        }
    }

    /// GUI-only. Acquire completion, join, publish latest config, validate the
    /// publication immediately before enqueueing acknowledgement, then join again.
    pub fn tick(self: *Controller, store: *config.Store) void {
        const job = self.active orelse return;
        if (!job.done.load(.acquire)) return;
        job.join();
        self.refreshDebt();
        if (job.failure) |failure| {
            self.finishJoined(job, failure);
            return;
        }
        switch (job.action) {
            .set, .remove => {
                if (job.cancelFlag().load(.acquire)) {
                    self.finishJoined(job, error.Cancelled);
                    return;
                }
                self.phase = .publishing;
                const publication = core.publish(self.core_manager, store, job.receipt.?, job.policy) catch |err| {
                    self.commit_uncertain = store.publicationUncertain();
                    self.finishJoined(job, err);
                    return;
                };
                self.committed = true;
                self.commit_uncertain = false;
                job.publication = publication;
                job.action = .acknowledge;
                core.validatePublication(self.core_manager, store, publication) catch |err| {
                    self.finishJoined(job, err);
                    return;
                };
                if (job.task) |task| task.report(.finalizing, 0, null);
                // No callback or GUI work may change config between validation and spawn.
                job.done.store(false, .release);
                job.thread = self.spawn(job) catch |err| {
                    self.finishJoined(job, err);
                    return;
                };
                self.phase = .acknowledging;
            },
            .acknowledge, .recover => self.finishJoined(job, null),
        }
    }

    fn requireReady(self: *const Controller) !void {
        if (self.isBusy()) return error.Busy;
    }

    fn beginCommand(self: *Controller) void {
        self.frozen = true;
        self.committed = false;
        self.commit_uncertain = false;
        self.failure = null;
        self.last_task_id = null;
    }

    fn enqueueFailure(self: *Controller, failure: anyerror) anyerror {
        self.refreshDebt();
        self.failure = failure;
        self.phase = if (self.committed and self.frozen) .committed_cleanup_pending else if (self.frozen) .recovery_required else if (failure == error.Cancelled) .cancelled else .failed;
        return failure;
    }

    fn newJob(self: *Controller, action: Action, proof: core.DurableConfig, policy: Policy) !*Job {
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = .{ .allocator = self.allocator, .manager = self.core_manager, .action = action, .proof = proof, .policy = policy };
        if (self.registry) |registry| {
            job.task = try registry.create(self.task_kind.?, switch (action) {
                .set => "Save CurseForge credential",
                .remove => "Remove CurseForge credential",
                .recover => "Recover CurseForge credentials",
                .acknowledge => unreachable,
            });
            self.last_task_id = job.task.?.id;
        }
        return job;
    }

    fn launch(self: *Controller, job: *Job, phase: Phase) !void {
        if (job.task) |task| {
            self.registry.?.start(task) catch |err| {
                self.registry.?.finish(task, .{ .failed = err });
                return err;
            };
            task.report(.finalizing, 0, null);
        }
        job.thread = self.spawn(job) catch |err| {
            if (job.task) |task| self.registry.?.finish(task, .{ .failed = err });
            return err;
        };
        self.active = job;
        self.phase = phase;
        self.frozen = true;
    }

    fn refreshDebt(self: *Controller) void {
        self.publication_pending = self.core_manager.pending() != null;
        self.recovery_required = self.core_manager.needsRecovery() or self.publication_pending or self.reconcile_required or self.commit_uncertain;
        self.frozen = self.recovery_required;
    }

    fn finishJoined(self: *Controller, job: *Job, failure: ?anyerror) void {
        std.debug.assert(job.thread == null);
        self.refreshDebt();
        self.failure = failure;
        self.phase = if (self.committed and self.frozen) .committed_cleanup_pending else if (self.frozen) .recovery_required else if (failure) |err| (if (err == error.Cancelled) .cancelled else .failed) else .succeeded;
        // A saved key remains committed even if cancel/error prevents cleanup.
        // Task success describes the durable command; snapshot exposes cleanup debt.
        if (job.task) |task| self.registry.?.finish(task, if (self.committed and job.action != .recover) .succeeded else if (failure) |err| (if (err == error.Cancelled) .canceled else .{ .failed = err }) else .succeeded);
        self.active = null;
        job.destroy();
    }
};

const Action = enum { set, remove, acknowledge, recover };
const Job = struct {
    allocator: Allocator,
    manager: *core.Manager,
    action: Action,
    proof: core.DurableConfig,
    policy: Policy,
    new_ref: credentials.Reference = undefined,
    secret: ?credentials.Secret = null,
    receipt: ?core.Receipt = null,
    publication: ?core.Publication = null,
    failure: ?anyerror = null,
    task: ?*tasks.Task = null,
    cancellation: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn cancelFlag(self: *Job) *std.atomic.Value(bool) {
        return if (self.task) |task| &task.cancellation else &self.cancellation;
    }
    fn join(self: *Job) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }
    fn destroy(self: *Job) void {
        std.debug.assert(self.thread == null);
        if (self.secret) |*secret| secret.deinit();
        self.allocator.destroy(self);
    }
    fn perform(self: *Job) !void {
        const cancellation: core.Cancellation = .{ .flag = self.cancelFlag() };
        switch (self.action) {
            .set => self.receipt = try self.manager.prepareSet(self.proof, self.new_ref, &self.secret.?, cancellation),
            .remove => self.receipt = try self.manager.prepareRemove(self.proof, cancellation),
            .acknowledge => try self.manager.acknowledge(self.publication.?, cancellation),
            .recover => try self.manager.recover(self.proof, cancellation),
        }
    }
    fn run(self: *Job) void {
        self.perform() catch |err| {
            self.failure = err;
        };
        // Core consumes the secret even on failure; defensive cleanup is idempotent.
        if (self.secret) |*secret| secret.deinit();
        self.done.store(true, .release);
    }
};
fn spawnThread(job: *Job) !std.Thread {
    return std.Thread.spawn(.{}, Job.run, .{job});
}

const test_policy: Policy = .{ .enabled = true, .terms_approved = true };
const test_key = "controller-test-private-key";
const old_ref: credentials.Reference = @splat('a');
const foreign_ref: credentials.Reference = @splat('b');

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    store: config.Store,
    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(std.testing.io, &buffer);
        const root = try std.testing.allocator.dupe(u8, buffer[0..len]);
        errdefer std.testing.allocator.free(root);
        return .{ .tmp = tmp, .root = root, .store = try config.Store.init(std.testing.allocator, std.testing.io, root) };
    }
    fn deinit(self: *Fixture) void {
        self.store.deinit();
        std.testing.allocator.free(self.root);
        self.tmp.cleanup();
    }
    fn noKey(self: *Fixture) !void {
        for ([_][]const u8{ ".vela/config.json", ".vela/curseforge-credentials.json" }) |path| {
            const bytes = self.tmp.dir.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer std.testing.allocator.free(bytes);
            try std.testing.expect(std.mem.indexOf(u8, bytes, test_key) == null);
        }
    }
};

const WipeSpy = struct {
    buffer: [512]u8 = undefined,
    frees: usize = 0,
    fn secret(self: *WipeSpy) credentials.Secret {
        @memcpy(self.buffer[0..test_key.len], test_key);
        return .{ .allocator = .{ .ptr = self, .vtable = &vtable }, .bytes = self.buffer[0..test_key.len] };
    }
    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
    fn alloc(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
        return null;
    }
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(ctx: *anyopaque, bytes: []u8, _: std.mem.Alignment, _: usize) void {
        const self: *WipeSpy = @ptrCast(@alignCast(ctx));
        for (bytes) |byte| std.debug.assert(byte == 0);
        self.frees += 1;
    }
};

const FakeVault = struct {
    config_path: []const u8,
    refs: [8]?credentials.Reference = @splat(null),
    puts: usize = 0,
    deletes: usize = 0,
    fail_put: bool = false,
    fail_delete: bool = false,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    block_put: bool = false,
    entered: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    exited: std.atomic.Value(bool) = .init(false),
    alive: bool = true,
    fn store(self: *FakeVault) credentials.Store {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable: credentials.Store.VTable = .{ .put = put, .get = get, .delete = delete };
    fn put(ctx: *anyopaque, ref: []const u8, _: []const u8) credentials.Error!void {
        const self: *FakeVault = @ptrCast(@alignCast(ctx));
        std.debug.assert(self.alive);
        // Preflight must durably create missing config before any vault operation.
        _ = std.Io.Dir.cwd().statFile(std.testing.io, self.config_path, .{}) catch return error.StorageFailure;
        self.puts += 1;
        for (&self.refs) |*slot| if (slot.* == null) {
            slot.* = ref[0..32].*;
            break;
        };
        self.entered.store(true, .release);
        if (self.block_put) {
            while (!self.release.load(.acquire)) {
                std.Thread.yield() catch {};
            }
        }
        if (self.cancel_flag) |flag| flag.store(true, .release);
        self.exited.store(true, .release);
        if (self.fail_put) return error.StorageFailure;
    }
    fn get(_: *anyopaque, _: Allocator, _: []const u8) credentials.Error!credentials.Secret {
        return error.NotFound;
    }
    fn delete(ctx: *anyopaque, ref: []const u8) credentials.Error!void {
        const self: *FakeVault = @ptrCast(@alignCast(ctx));
        std.debug.assert(self.alive);
        self.deletes += 1;
        if (self.fail_delete) return error.Denied;
        for (&self.refs) |*slot| if (slot.*) |value| {
            if (std.mem.eql(u8, &value, ref)) {
                slot.* = null;
                return;
            }
        };
        return error.NotFound;
    }
};

fn settle(controller: *Controller, store: *config.Store) !void {
    var phases: usize = 0;
    while (controller.active) |job| {
        try std.testing.expect(phases < 3);
        phases += 1;
        job.join();
        try std.testing.expect(job.done.load(.acquire));
        controller.tick(store);
    }
}
fn failSpawn(_: *Job) !std.Thread {
    return error.SystemResources;
}
fn cancelAfterPut(job: *Job) !std.Thread {
    const vault: *FakeVault = @ptrCast(@alignCast(job.manager.injected.?.ctx));
    vault.cancel_flag = job.cancelFlag();
    return spawnThread(job);
}
fn cancelAck(job: *Job) !std.Thread {
    if (job.action == .acknowledge) job.cancelFlag().store(true, .release);
    return spawnThread(job);
}
test "CF controller missing config preflight set remove and latest unrelated policy merge" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var vault: FakeVault = .{ .config_path = fixture.store.file };
    var registry = tasks.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var controller = try Controller.init(std.testing.allocator, std.testing.io, fixture.root, .{ .injected_store = vault.store(), .registry = &registry, .task_kind = .credential_update });
    defer controller.deinit();
    try std.testing.expectEqual(@as(usize, 0), vault.puts + vault.deletes);
    try std.testing.expect(!controller.isBusy());
    var spy: WipeSpy = .{};
    var secret = spy.secret();
    try controller.startSet(&fixture.store, &secret, test_policy);
    try std.testing.expect(controller.lease());
    try std.testing.expectEqual(@as(usize, 0), secret.bytes.len);
    controller.active.?.join();
    var latest = fixture.store.snapshot().*;
    latest.settings.download_connections = 17;
    latest.settings.microsoft_client_id = "latest-client";
    latest.settings.curseforge_enabled = false;
    latest.settings.curseforge_terms_approved = false;
    try fixture.store.update(latest);
    try settle(&controller, &fixture.store);
    try std.testing.expectEqual(@as(usize, 1), spy.frees);
    try std.testing.expectEqual(@as(u16, 17), fixture.store.snapshot().settings.download_connections);
    try std.testing.expectEqualStrings("latest-client", fixture.store.snapshot().settings.microsoft_client_id);
    try std.testing.expect(fixture.store.snapshot().settings.curseforge_enabled and fixture.store.snapshot().settings.curseforge_terms_approved);
    try std.testing.expect(controller.snapshot().committed and !controller.lease());
    try std.testing.expectEqual(@as(usize, 1), registry.tasks().len);
    try std.testing.expectEqual(tasks.State.succeeded, registry.tasks()[0].state);
    try std.testing.expectEqual(tasks.Stage.finalizing, registry.tasks()[0].progress().stage);
    try controller.startRemove(&fixture.store, .{ .enabled = false, .terms_approved = true });
    try settle(&controller, &fixture.store);
    try std.testing.expect(fixture.store.snapshot().settings.curseforge_credential_ref == null);
    try std.testing.expect(!controller.lease() and controller.snapshot().committed);
    try std.testing.expectEqual(@as(usize, 1), vault.deletes);
    try std.testing.expectEqual(@as(usize, 2), registry.tasks().len);
    try fixture.noKey();
}

test "CF controller busy and foreign preflight always consume wipe without native work" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var foreign = try Fixture.init();
    defer foreign.deinit();
    var vault: FakeVault = .{ .config_path = fixture.store.file };
    var controller = try Controller.init(std.testing.allocator, std.testing.io, fixture.root, .{ .injected_store = vault.store() });
    defer controller.deinit();
    var rejected: WipeSpy = .{};
    var secret = rejected.secret();
    try std.testing.expectError(error.ForeignConfig, controller.startSet(&foreign.store, &secret, test_policy));
    try std.testing.expectEqual(@as(usize, 1), rejected.frees);
    try std.testing.expectEqual(@as(usize, 0), vault.puts);
    try std.testing.expect(!controller.lease());
    var accepted: WipeSpy = .{};
    secret = accepted.secret();
    try controller.startSet(&fixture.store, &secret, test_policy);
    var busy: WipeSpy = .{};
    secret = busy.secret();
    try std.testing.expectError(error.Busy, controller.startSet(&fixture.store, &secret, test_policy));
    try std.testing.expectEqual(@as(usize, 1), busy.frees);
    try std.testing.expectError(error.Busy, controller.startRemove(&fixture.store, test_policy));
    try std.testing.expectError(error.Busy, controller.startRecovery(&fixture.store));
    try settle(&controller, &fixture.store);
    try std.testing.expectEqual(@as(usize, 1), accepted.frees);
}

test "CF controller ambiguous prepare failure retains debt and only explicit recovery deletes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var vault: FakeVault = .{ .config_path = fixture.store.file, .fail_put = true };
    var controller = try Controller.init(std.testing.allocator, std.testing.io, fixture.root, .{ .injected_store = vault.store() });
    defer controller.deinit();
    var spy: WipeSpy = .{};
    var secret = spy.secret();
    try controller.startSet(&fixture.store, &secret, test_policy);
    try settle(&controller, &fixture.store);
    try std.testing.expectEqual(@as(usize, 1), spy.frees);
    try std.testing.expectEqual(@as(?anyerror, error.StorageFailure), controller.snapshot().failure);
    try std.testing.expect(controller.lease() and controller.snapshot().recovery_required and !controller.snapshot().committed);
    try std.testing.expectEqual(@as(usize, 0), vault.deletes);
    controller.tick(&fixture.store);
    try std.testing.expectEqual(@as(usize, 0), vault.deletes);
    try controller.startRecovery(&fixture.store);
    try settle(&controller, &fixture.store);
    try std.testing.expect(!controller.lease());
    try std.testing.expectEqual(@as(usize, 1), vault.deletes);
    try fixture.noKey();
}

test "CF controller cancellation after noninterruptible put wipes and requires recovery" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var vault: FakeVault = .{ .config_path = fixture.store.file };
    var registry = tasks.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var controller = try Controller.init(std.testing.allocator, std.testing.io, fixture.root, .{ .injected_store = vault.store(), .registry = &registry });
    defer controller.deinit();
    controller.spawn = cancelAfterPut;
    var spy: WipeSpy = .{};
    var secret = spy.secret();
    try controller.startSet(&fixture.store, &secret, test_policy);
    try settle(&controller, &fixture.store);
    vault.cancel_flag = null;
    controller.spawn = spawnThread;
    try std.testing.expectEqual(@as(usize, 1), spy.frees);
    try std.testing.expect(controller.lease() and !controller.snapshot().committed);
    try std.testing.expectEqual(tasks.State.canceled, registry.tasks()[0].state);
    try controller.startRecovery(&fixture.store);
    try settle(&controller, &fixture.store);
    try std.testing.expect(!controller.lease());
}

test "CF controller post-config ack error is committed warning and recovery has its own outcome" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var initial = fixture.store.snapshot().*;
    initial.settings.curseforge_credential_ref = &old_ref;
    try fixture.store.update(initial);
    var vault: FakeVault = .{ .config_path = fixture.store.file, .fail_delete = true };
    vault.refs[0] = old_ref;
    var registry = tasks.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var controller = try Controller.init(std.testing.allocator, std.testing.io, fixture.root, .{ .injected_store = vault.store(), .registry = &registry });
    defer controller.deinit();
    var spy: WipeSpy = .{};
    var secret = spy.secret();
    try controller.startSet(&fixture.store, &secret, test_policy);
    try settle(&controller, &fixture.store);
    try std.testing.expectEqual(Phase.committed_cleanup_pending, controller.snapshot().phase);
    try std.testing.expect(controller.snapshot().committed and controller.snapshot().cleanup_pending);
    try std.testing.expectEqual(tasks.State.succeeded, registry.tasks()[0].state);
    try std.testing.expectEqual(@as(?anyerror, error.Denied), controller.snapshot().failure);
    try std.testing.expect(!std.mem.eql(u8, &old_ref, fixture.store.snapshot().settings.curseforge_credential_ref.?));
    try controller.startRecovery(&fixture.store);
    try settle(&controller, &fixture.store);
    try std.testing.expectEqual(tasks.State.failed, registry.tasks()[1].state);
    vault.fail_delete = false;
    try controller.startRecovery(&fixture.store);
    try settle(&controller, &fixture.store);
    try std.testing.expect(controller.snapshot().committed and !controller.snapshot().cleanup_pending and !controller.lease());
    try fixture.noKey();
}

test "CF controller canceled ack never reports durable save as canceled" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var vault: FakeVault = .{ .config_path = fixture.store.file };
    var registry = tasks.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var controller = try Controller.init(std.testing.allocator, std.testing.io, fixture.root, .{ .injected_store = vault.store(), .registry = &registry });
    defer controller.deinit();
    controller.spawn = cancelAck;
    var spy: WipeSpy = .{};
    var secret = spy.secret();
    try controller.startSet(&fixture.store, &secret, test_policy);
    try settle(&controller, &fixture.store);
    try std.testing.expect(controller.snapshot().committed and controller.snapshot().cleanup_pending);
    try std.testing.expectEqual(@as(?anyerror, error.Cancelled), controller.snapshot().failure);
    try std.testing.expectEqual(tasks.State.succeeded, registry.tasks()[0].state);
    controller.spawn = spawnThread;
    try controller.startRecovery(&fixture.store);
    try settle(&controller, &fixture.store);
    try std.testing.expect(!controller.lease());
}

test "CF controller stale prepared publication is not blindly retried" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var vault: FakeVault = .{ .config_path = fixture.store.file };
    var controller = try Controller.init(std.testing.allocator, std.testing.io, fixture.root, .{ .injected_store = vault.store() });
    defer controller.deinit();
    var spy: WipeSpy = .{};
    var secret = spy.secret();
    try controller.startSet(&fixture.store, &secret, test_policy);
    controller.active.?.join();
    var changed = fixture.store.snapshot().*;
    changed.settings.curseforge_credential_ref = &foreign_ref;
    try fixture.store.update(changed);
    controller.tick(&fixture.store);
    try std.testing.expectEqual(@as(?anyerror, error.StaleReceipt), controller.snapshot().failure);
    try std.testing.expect(controller.snapshot().publication_pending and controller.lease());
    try std.testing.expectEqualStrings(&foreign_ref, fixture.store.snapshot().settings.curseforge_credential_ref.?);
    secret = spy.secret();
    try std.testing.expectError(error.Busy, controller.startSet(&fixture.store, &secret, test_policy));
    try controller.startRecovery(&fixture.store);
    try settle(&controller, &fixture.store);
    try std.testing.expect(!controller.lease());
    try std.testing.expectEqualStrings(&foreign_ref, fixture.store.snapshot().settings.curseforge_credential_ref.?);
    try std.testing.expectEqual(@as(usize, 1), vault.puts);
}

test "CF controller thread creation failure finalizes registry and wipes transferred secret" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var vault: FakeVault = .{ .config_path = fixture.store.file };
    var registry = tasks.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var controller = try Controller.init(std.testing.allocator, std.testing.io, fixture.root, .{ .injected_store = vault.store(), .registry = &registry });
    defer controller.deinit();
    controller.spawn = failSpawn;
    var spy: WipeSpy = .{};
    var secret = spy.secret();
    try std.testing.expectError(error.SystemResources, controller.startSet(&fixture.store, &secret, test_policy));
    try std.testing.expectEqual(@as(usize, 1), spy.frees);
    try std.testing.expectEqual(@as(usize, 0), secret.bytes.len);
    try std.testing.expect(!controller.isBusy());
    try std.testing.expectEqual(tasks.State.failed, registry.tasks()[0].state);
    try std.testing.expectEqual(@as(usize, 0), vault.puts + vault.deletes);
}

test "CF controller shutdown cancels joins before freeing core and task borrows" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var vault: FakeVault = .{ .config_path = fixture.store.file, .block_put = true };
    var registry = tasks.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var controller = try Controller.init(std.testing.allocator, std.testing.io, fixture.root, .{ .injected_store = vault.store(), .registry = &registry });
    var spy: WipeSpy = .{};
    var secret = spy.secret();
    controller.startSet(&fixture.store, &secret, test_policy) catch |err| {
        controller.deinit();
        return err;
    };
    while (!vault.entered.load(.acquire)) {
        if (controller.active.?.done.load(.acquire)) {
            controller.deinit();
            return error.ExpectedBlockedPut;
        }
        std.Thread.yield() catch {};
    }
    controller.cancel();
    vault.release.store(true, .release);
    controller.deinit();
    vault.alive = false;
    try std.testing.expect(vault.exited.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), spy.frees);
    try std.testing.expectEqual(tasks.State.canceled, registry.tasks()[0].state);
    try std.testing.expectEqual(@as(usize, 1), vault.puts);
    try std.testing.expectEqual(@as(usize, 0), vault.deletes);
    // Restart loads debt only. No implicit startup recovery or vault access.
    var restarted = try Controller.init(std.testing.allocator, std.testing.io, fixture.root, .{ .injected_store = vault.store() });
    defer restarted.deinit();
    try std.testing.expect(restarted.lease() and restarted.snapshot().recovery_required);
    try std.testing.expectEqual(@as(usize, 1), vault.puts);
    try std.testing.expectEqual(@as(usize, 0), vault.deletes);
}

fn allocationFailures(a: Allocator) !void {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var vault: FakeVault = .{ .config_path = fixture.store.file };
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var controller = try Controller.init(a, std.testing.io, fixture.root, .{ .injected_store = vault.store(), .registry = &registry });
    defer controller.deinit();
    var spy: WipeSpy = .{};
    var secret = spy.secret();
    controller.startSet(&fixture.store, &secret, test_policy) catch |err| {
        try std.testing.expect(secret.bytes.len == 0 and spy.frees == 1);
        return err;
    };
    try settle(&controller, &fixture.store);
    try std.testing.expect(secret.bytes.len == 0 and spy.frees == 1);
    if (controller.failure) |failure| return failure;
    try std.testing.expect(controller.snapshot().committed);
    try fixture.noKey();
}

test "CF controller allocation failures release secret job registry and stable core" {
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, allocationFailures, .{});
}

fn failAckSpawn(job: *Job) !std.Thread {
    if (job.action == .acknowledge) return error.SystemResources;
    return spawnThread(job);
}

test "CF controller ack enqueue failure retains durable commit and recovery lease" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var vault: FakeVault = .{ .config_path = fixture.store.file };
    var registry = tasks.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var controller = try Controller.init(std.testing.allocator, std.testing.io, fixture.root, .{ .injected_store = vault.store(), .registry = &registry });
    defer controller.deinit();
    controller.spawn = failAckSpawn;
    var spy: WipeSpy = .{};
    var secret = spy.secret();
    try controller.startSet(&fixture.store, &secret, test_policy);
    try settle(&controller, &fixture.store);
    try std.testing.expectEqual(Phase.committed_cleanup_pending, controller.snapshot().phase);
    try std.testing.expect(controller.snapshot().committed and controller.snapshot().publication_pending);
    try std.testing.expectEqual(@as(?anyerror, error.SystemResources), controller.snapshot().failure);
    try std.testing.expectEqual(tasks.State.succeeded, registry.tasks()[0].state);
    controller.spawn = spawnThread;
    try controller.startRecovery(&fixture.store);
    try settle(&controller, &fixture.store);
    try std.testing.expect(!controller.lease());
}

test "CF controller preflight allocation failure wipes before any stage or vault call" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var vault: FakeVault = .{ .config_path = fixture.store.file };
    var controller = try Controller.init(std.testing.allocator, std.testing.io, fixture.root, .{ .injected_store = vault.store() });
    defer controller.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    fixture.store.a = failing.allocator();
    defer fixture.store.a = std.testing.allocator;
    var spy: WipeSpy = .{};
    var secret = spy.secret();
    try std.testing.expectError(error.OutOfMemory, controller.startSet(&fixture.store, &secret, test_policy));
    try std.testing.expectEqual(@as(usize, 0), secret.bytes.len);
    try std.testing.expectEqual(@as(usize, 1), spy.frees);
    try std.testing.expectEqual(@as(usize, 0), vault.puts + vault.deletes);
    try std.testing.expect(!controller.lease());
}

test "CF controller explicit recovery uses authoritative disk not an unrelated stale draft" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var vault: FakeVault = .{ .config_path = fixture.store.file };
    var controller = try Controller.init(std.testing.allocator, std.testing.io, fixture.root, .{ .injected_store = vault.store() });
    defer controller.deinit();
    controller.spawn = cancelAck;
    var spy: WipeSpy = .{};
    var secret = spy.secret();
    try controller.startSet(&fixture.store, &secret, test_policy);
    try settle(&controller, &fixture.store);
    const previous_connections = fixture.store.snapshot().settings.download_connections;
    // An uncooperative external replacement still needs authoritative recovery.
    // Cooperating writers cannot open another Store while this owner is alive.
    try std.testing.expectError(error.LauncherRootInUse, config.Store.init(std.testing.allocator, std.testing.io, fixture.root));
    var disk = fixture.store.snapshot().*;
    disk.settings.download_connections = 23;
    disk.settings.curseforge_enabled = false;
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, disk, .{});
    defer std.testing.allocator.free(bytes);
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".vela/config.json", .data = bytes });
    try std.testing.expectEqual(previous_connections, fixture.store.snapshot().settings.download_connections);
    controller.spawn = spawnThread;
    try controller.startRecovery(&fixture.store);
    try settle(&controller, &fixture.store);
    try std.testing.expectEqual(@as(u16, 23), fixture.store.snapshot().settings.download_connections);
    try std.testing.expect(!fixture.store.snapshot().settings.curseforge_enabled);
    try std.testing.expect(fixture.store.snapshot().settings.curseforge_credential_ref != null);
    try std.testing.expect(!controller.lease());
}

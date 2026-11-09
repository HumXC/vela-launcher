//! GUI-owned proxy jobs. Workers own their inputs and never borrow a config snapshot.
//! Only tick publishes config. Call tick after draw; cancel then join before teardown.
//! proxy_pending_credential_ref is a durable cleanup journal, never a password.
const std = @import("std");
const config = @import("../core/config.zig");
const proxy_config = @import("../core/proxy_config.zig");
const proxy_policy = @import("../core/proxy_policy.zig");
const credentials = @import("../core/credentials.zig");
const http = @import("../core/http_transport.zig");
const Allocator = std.mem.Allocator;

pub const test_url = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
pub const Phase = enum { idle, saving, testing, detecting, cleaning, saved, connected, detected, no_system_proxy, cancelled, failed, recovery_required };
pub const Stage = enum { settings, detection, connection, credentials };
pub const Source = enum { none, environment, windows, macos, gnome, kde, manual, explicit };
pub const ProbeResult = struct { source: Source = .none, proxied: bool = false };
pub const Snapshot = struct {
    phase: Phase,
    busy: bool,
    failure: ?anyerror,
    stage: Stage,
    result: ProbeResult,
    committed: bool,
    revision: u64,
};
pub const Options = struct {
    // Immutable process environment; must outlive controller and all workers.
    environ: ?*const std.process.Environ.Map = null,
    injected_store: ?credentials.Store = null,
};

pub const Controller = struct {
    a: Allocator,
    io: std.Io,
    options: Options,
    active: ?*Job = null,
    phase: Phase = .idle,
    failure: ?anyerror = null,
    stage: Stage = .settings,
    result: ProbeResult = .{},
    committed: bool = false,
    revision: u64 = 0,
    spawn: *const fn (*Job) anyerror!std.Thread = spawnThread,

    pub fn init(a: Allocator, io: std.Io, options: Options) !Controller {
        return .{ .a = a, .io = io, .options = options };
    }

    pub fn deinit(self: *Controller) void {
        if (self.active) |job| {
            self.cancel();
            job.join();
            // An interrupted vault transaction remains discoverable through the journal.
            job.destroy();
        }
        self.* = undefined;
    }

    pub fn isBusy(self: *const Controller) bool {
        return self.active != null;
    }
    pub fn snapshot(self: *const Controller) Snapshot {
        return .{ .phase = self.phase, .busy = self.isBusy(), .failure = self.failure, .stage = self.stage, .result = self.result, .committed = self.committed, .revision = self.revision };
    }
    pub fn cancel(self: *Controller) void {
        if (self.active) |job| job.cancelled.store(true, .release);
    }

    /// Copies draft strings and optional password. Caller retains and must wipe its buffer.
    /// Retain the committed reference only for the same endpoint and account.
    pub fn startSave(self: *Controller, store: *config.Store, draft: proxy_config.Settings, password: ?[]const u8, remove_password: bool) !void {
        if (self.isBusy()) return error.Busy;
        if (store.publicationUncertain()) return error.ConfigPublicationUncertain;
        if (store.snapshot().settings.proxy_pending_credential_ref != null) return error.RecoveryRequired;
        if (password != null and remove_password) return error.InvalidProxyPassword;
        var next = draft;
        next.credential_ref = if (remove_password or password != null) null else store.snapshot().settings.proxy.credential_ref;
        try proxy_config.validateCredentialReuse(store.snapshot().settings.proxy, next);
        try proxy_config.validate(next);
        if (password != null and next.username.len == 0) return error.InvalidProxyUsername;
        const job = try self.newJob(.prepare, next, password);
        errdefer job.destroy();
        job.old_ref = try copyReference(store.snapshot().settings.proxy.credential_ref);
        job.remove_password = remove_password;
        try self.launch(job, .saving);
    }

    /// detect_only resolves the same draft and target URL, without a network request.
    pub fn startProbe(self: *Controller, committed: proxy_config.Settings, draft: proxy_config.Settings, password: ?[]const u8, detect_only: bool) !void {
        if (self.isBusy()) return error.Busy;
        var next = draft;
        if (password != null) next.credential_ref = null;
        try proxy_config.validateCredentialReuse(committed, next);
        try proxy_config.validate(next);
        const job = try self.newJob(if (detect_only) .detect else .test_connection, next, password);
        errdefer job.destroy();
        try self.launch(job, if (detect_only) .detecting else .testing);
    }

    /// Explicit recovery reads authoritative config before deleting anything. If the
    /// journal aliases the active reference, preserve the active secret and only clear it.
    pub fn startRecovery(self: *Controller, store: *config.Store) !void {
        if (self.isBusy()) return error.Busy;
        try store.recover();
        const pending = try copyReference(store.snapshot().settings.proxy_pending_credential_ref);
        const reference = pending orelse {
            self.phase = .saved;
            self.failure = null;
            return;
        };
        if (sameReference(store.snapshot().settings.proxy.credential_ref, &reference)) {
            var document = store.snapshot().*;
            document.settings.proxy_pending_credential_ref = null;
            try store.update(document);
            self.phase = .saved;
            self.failure = null;
            return;
        }
        const job = try self.newJob(.wait_cleanup, store.snapshot().settings.proxy, null);
        errdefer job.destroy();
        job.cleanup_ref = reference;
        try self.launch(job, .cleaning);
    }

    pub fn tick(self: *Controller, store: *config.Store) void {
        const job = self.active orelse return;
        if (!job.done.load(.acquire)) return;
        job.join();
        self.stage = job.stage;
        self.result = job.result;
        self.advance(store, job) catch |err| {
            self.failure = err;
            const credential_job = job.action != .detect and job.action != .test_connection;
            self.phase = if (credential_job and (store.publicationUncertain() or store.snapshot().settings.proxy_pending_credential_ref != null)) .recovery_required else if (err == error.Cancelled or err == error.Canceled) .cancelled else .failed;
            self.finishJob(job);
        };
    }

    fn advance(self: *Controller, store: *config.Store, job: *Job) !void {
        if (job.failure) |failure| return failure;
        try job.checkCancelled();
        switch (job.action) {
            .detect, .test_connection => {
                self.phase = if (job.action == .test_connection) .connected else if (job.settings.mode == .system and job.result.source == .none) .no_system_proxy else .detected;
                self.finishJob(job);
            },
            .prepare => {
                try checkPrior(store, job.old_ref);
                if (store.snapshot().settings.proxy_pending_credential_ref != null) return error.RecoveryRequired;
                if (job.new_ref) |reference| {
                    var document = store.snapshot().*;
                    document.settings.proxy_pending_credential_ref = &reference;
                    try store.update(document);
                    try self.relaunch(job, .put, .saving);
                } else try self.publish(store, job);
            },
            .put => try self.publish(store, job),
            .wait_cleanup => {
                if (store.publicationUncertain()) return error.ConfigPublicationUncertain;
                const reference = job.cleanup_ref.?;
                if (!sameReference(store.snapshot().settings.proxy_pending_credential_ref, &reference) or sameReference(store.snapshot().settings.proxy.credential_ref, &reference)) return error.StaleProxySettings;
                // A settings publication affects new tasks. Existing policies may
                // need this credential again after a redirect or another download.
                if (proxy_policy.credentialInUse(self.io, &reference)) return;
                try self.relaunch(job, .cleanup, .cleaning);
            },
            .cleanup => {
                if (store.publicationUncertain()) return error.ConfigPublicationUncertain;
                const reference = job.cleanup_ref.?;
                if (!sameReference(store.snapshot().settings.proxy_pending_credential_ref, &reference)) return error.StaleProxySettings;
                // Reference was checked immediately before starting worker; writers must
                // retain proxy fields while isBusy() is true.
                if (sameReference(store.snapshot().settings.proxy.credential_ref, &reference)) return error.StaleProxySettings;
                var document = store.snapshot().*;
                document.settings.proxy_pending_credential_ref = null;
                try store.update(document);
                self.phase = .saved;
                self.finishJob(job);
            },
        }
    }

    fn publish(self: *Controller, store: *config.Store, job: *Job) !void {
        try checkPrior(store, job.old_ref);
        if (job.new_ref) |reference| {
            if (!sameReference(store.snapshot().settings.proxy_pending_credential_ref, &reference)) return error.StaleProxySettings;
        } else if (store.snapshot().settings.proxy_pending_credential_ref != null) return error.RecoveryRequired;
        var next = job.settings;
        next.credential_ref = if (job.new_ref) |*reference| reference else if (job.remove_password) null else if (job.old_ref) |*reference| reference else null;
        var document = store.snapshot().*;
        document.settings.proxy = next;
        const changed_secret = job.new_ref != null or job.remove_password;
        document.settings.proxy_pending_credential_ref = if (changed_secret) (if (job.old_ref) |*reference| reference else null) else null;
        try store.update(document);
        self.committed = true;
        self.revision +%= 1;
        if (changed_secret and job.old_ref != null) {
            job.cleanup_ref = job.old_ref;
            try self.relaunch(job, .wait_cleanup, .cleaning);
        } else {
            self.phase = .saved;
            self.finishJob(job);
        }
    }

    fn newJob(self: *Controller, action: Action, settings: proxy_config.Settings, password: ?[]const u8) !*Job {
        const owned = try proxy_config.clone(self.a, settings);
        errdefer proxy_config.deinit(self.a, owned);
        var secret: ?credentials.Secret = null;
        errdefer if (secret) |*value| value.deinit();
        if (password) |bytes| {
            if (bytes.len == 0 or bytes.len > 512 or std.mem.indexOfScalar(u8, bytes, 0) != null or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidProxyPassword;
            secret = .{ .allocator = self.a, .bytes = try self.a.dupe(u8, bytes) };
        }
        const job = try self.a.create(Job);
        job.* = .{ .a = self.a, .io = self.io, .options = self.options, .action = action, .settings = owned, .secret = secret };
        return job;
    }
    fn launch(self: *Controller, job: *Job, phase: Phase) !void {
        job.thread = try self.spawn(job);
        self.active = job;
        self.phase = phase;
        self.failure = null;
        self.result = .{};
        self.committed = false;
    }
    fn relaunch(self: *Controller, job: *Job, action: Action, phase: Phase) !void {
        job.action = action;
        job.done.store(false, .release);
        job.thread = try self.spawn(job);
        self.phase = phase;
    }
    fn finishJob(self: *Controller, job: *Job) void {
        self.active = null;
        job.destroy();
    }
};

fn copyReference(value: ?[]const u8) !?credentials.Reference {
    const reference = value orelse return null;
    if (!credentials.validateReference(reference)) return error.InvalidProxyCredential;
    return reference[0..32].*;
}
fn sameReference(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |value| return if (right) |other| std.mem.eql(u8, value, other) else false;
    return right == null;
}
fn checkPrior(store: *config.Store, prior: ?credentials.Reference) !void {
    if (store.publicationUncertain()) return error.ConfigPublicationUncertain;
    if (!sameReference(store.snapshot().settings.proxy.credential_ref, if (prior) |*reference| reference else null)) return error.StaleProxySettings;
}
const Action = enum { prepare, put, wait_cleanup, cleanup, detect, test_connection };
const Job = struct {
    a: Allocator,
    io: std.Io,
    options: Options,
    action: Action,
    settings: proxy_config.Settings,
    secret: ?credentials.Secret,
    old_ref: ?credentials.Reference = null,
    new_ref: ?credentials.Reference = null,
    cleanup_ref: ?credentials.Reference = null,
    remove_password: bool = false,
    cancelled: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    failure: ?anyerror = null,
    stage: Stage = .settings,
    result: ProbeResult = .{},

    fn join(self: *Job) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }
    fn destroy(self: *Job) void {
        std.debug.assert(self.thread == null);
        if (self.secret) |*secret| secret.deinit();
        proxy_config.deinit(self.a, self.settings);
        self.a.destroy(self);
    }
    fn checkCancelled(self: *const Job) !void {
        if (self.cancelled.load(.acquire)) return error.Cancelled;
    }
    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        self.work() catch |err| {
            self.failure = err;
        };
    }
    fn work(self: *Job) !void {
        try self.checkCancelled();
        switch (self.action) {
            .prepare => if (self.secret != null) {
                var random: [16]u8 = undefined;
                try self.io.randomSecure(&random);
                const reference = std.fmt.bytesToHex(random, .lower);
                if (self.old_ref) |old| if (std.mem.eql(u8, &old, &reference)) return error.ReferenceCollision;
                self.new_ref = reference;
            },
            .put, .cleanup => {
                self.stage = .credentials;
                var native: ?credentials.Native = null;
                defer if (native) |*value| value.deinit();
                const vault = if (self.options.injected_store) |injected| injected else blk: {
                    native = try credentials.Native.init();
                    break :blk native.?.store();
                };
                try self.checkCancelled();
                if (self.action == .put) {
                    defer {
                        if (self.secret) |*secret| secret.deinit();
                        self.secret = null;
                    }
                    try vault.put(&self.new_ref.?, self.secret.?.bytes);
                } else vault.delete(&self.cleanup_ref.?) catch |err| if (err != error.NotFound) {
                    return err;
                };
            },
            .wait_cleanup => {},
            .detect, .test_connection => try self.probe(),
        }
        try self.checkCancelled();
    }
    fn probe(self: *Job) !void {
        self.stage = .detection;
        var policy = try proxy_policy.Policy.init(self.a, self.io, self.settings, self.options.environ, null);
        defer policy.deinit();
        if (self.secret) |secret| try policy.setPassword(secret.bytes);
        var route = try policy.resolve(self.io, test_url);
        defer route.deinit();
        self.result = .{ .source = std.meta.stringToEnum(Source, @tagName(route.source)) orelse .none, .proxied = route.proxy.len != 0 };
        try self.checkCancelled();
        if (self.action == .detect) return;
        self.stage = .connection;
        var client = try http.Client.init(self.a, self.io, .{ .proxy_policy = &policy });
        defer client.deinit();
        var response = try client.execute(.{ .url = test_url, .max_response_bytes = 8 * 1024 * 1024, .timeout_ms = 30_000, .cancel = &self.cancelled });
        defer response.deinit();
        if (response.status < 200 or response.status >= 300) return error.ProxyTestHttpStatus;
    }
};
fn spawnThread(job: *Job) !std.Thread {
    return std.Thread.spawn(.{}, Job.run, .{job});
}

const FakeVault = struct {
    references: [4]?credentials.Reference = @splat(null),
    puts: usize = 0,
    deletes: usize = 0,
    fail_put: bool = false,
    fail_delete: bool = false,
    fn store(self: *FakeVault) credentials.Store {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable: credentials.Store.VTable = .{ .put = put, .get = get, .delete = delete };
    fn put(ctx: *anyopaque, reference: []const u8, _: []const u8) credentials.Error!void {
        const self: *FakeVault = @ptrCast(@alignCast(ctx));
        self.puts += 1;
        for (&self.references) |*slot| if (slot.* == null) {
            slot.* = reference[0..32].*;
            break;
        };
        if (self.fail_put) return error.StorageFailure;
    }
    fn get(_: *anyopaque, _: Allocator, _: []const u8) credentials.Error!credentials.Secret {
        return error.NotFound;
    }
    fn delete(ctx: *anyopaque, reference: []const u8) credentials.Error!void {
        const self: *FakeVault = @ptrCast(@alignCast(ctx));
        self.deletes += 1;
        if (self.fail_delete) return error.Denied;
        for (&self.references) |*slot| if (slot.*) |stored| {
            if (std.mem.eql(u8, &stored, reference)) {
                slot.* = null;
                return;
            }
        };
        return error.NotFound;
    }
};
fn settle(controller: *Controller, store: *config.Store) !void {
    var count: usize = 0;
    while (controller.active) |job| {
        count += 1;
        try std.testing.expect(count <= 4);
        job.join();
        controller.tick(store);
    }
}
fn rootPath(tmp: *std.testing.TmpDir) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buffer);
    return std.testing.allocator.dupe(u8, buffer[0..len]);
}

test "proxy cleanup waits for old task policies but not new credentials" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    var vault: FakeVault = .{};
    var controller = try Controller.init(a, io, .{ .injected_store = vault.store() });
    defer controller.deinit();
    try controller.startSave(&store, .{ .mode = .manual, .username = "user" }, "old-password", false);
    try settle(&controller, &store);
    try proxy_policy.setDefault(io, store.snapshot().settings.proxy, null);
    defer proxy_policy.clearDefault(io);
    var old_task = try proxy_policy.capture(a, io, null);
    var old_alive = true;
    defer if (old_alive) old_task.deinit();
    try controller.startSave(&store, store.snapshot().settings.proxy, "new-password", false);
    controller.active.?.join();
    controller.tick(&store); // journal -> put
    controller.active.?.join();
    controller.tick(&store); // put -> publish -> wait_cleanup
    try proxy_policy.setDefault(io, store.snapshot().settings.proxy, null);
    var new_task = try proxy_policy.capture(a, io, null);
    defer new_task.deinit();
    controller.active.?.join();
    controller.tick(&store);
    try std.testing.expect(controller.isBusy());
    try std.testing.expectEqual(@as(usize, 0), vault.deletes);
    old_task.deinit();
    old_alive = false;
    try settle(&controller, &store);
    try std.testing.expectEqual(@as(usize, 1), vault.deletes);
    try std.testing.expect(store.snapshot().settings.proxy_pending_credential_ref == null);
}

test "proxy controller journals vault write and preserves latest unrelated config" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    var vault: FakeVault = .{};
    var controller = try Controller.init(a, std.testing.io, .{ .injected_store = vault.store() });
    defer controller.deinit();
    try controller.startSave(&store, .{ .mode = .manual, .username = "user" }, "secret-canary", false);
    controller.active.?.join();
    controller.tick(&store);
    try std.testing.expect(store.snapshot().settings.proxy_pending_credential_ref != null);
    var latest = store.snapshot().*;
    latest.settings.default_memory_mb = 8192;
    latest.settings.resource_list_view = true;
    try store.update(latest);
    try settle(&controller, &store);
    try std.testing.expectEqual(Phase.saved, controller.phase);
    try std.testing.expectEqual(@as(usize, 1), vault.puts);
    try std.testing.expect(store.snapshot().settings.proxy_pending_credential_ref == null);
    const reference = store.snapshot().settings.proxy.credential_ref.?[0..32].*;
    try std.testing.expectEqual(@as(u32, 8192), store.snapshot().settings.default_memory_mb);
    try std.testing.expect(store.snapshot().settings.resource_list_view);
    const json = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, store.file, a, .limited(1024 * 1024));
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "secret-canary") == null);
    // A stale draft reference cannot replace the latest saved secret.
    try controller.startSave(&store, .{ .mode = .manual, .username = "user", .bypass = "localhost" }, null, false);
    try settle(&controller, &store);
    try std.testing.expectEqualStrings(&reference, store.snapshot().settings.proxy.credential_ref.?);
    try std.testing.expectEqual(@as(usize, 1), vault.puts);
    try controller.startSave(&store, store.snapshot().settings.proxy, null, true);
    try settle(&controller, &store);
    try std.testing.expect(store.snapshot().settings.proxy.credential_ref == null);
    try std.testing.expectEqual(@as(usize, 1), vault.deletes);
}

test "proxy controller ambiguous put retains journal and recovers without publishing secret" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    var vault: FakeVault = .{ .fail_put = true };
    var controller = try Controller.init(a, std.testing.io, .{ .injected_store = vault.store() });
    defer controller.deinit();
    try controller.startSave(&store, .{ .mode = .manual, .username = "user" }, "canary", false);
    try settle(&controller, &store);
    try std.testing.expectEqual(Phase.recovery_required, controller.phase);
    try std.testing.expect(store.snapshot().settings.proxy_pending_credential_ref != null);
    try std.testing.expect(store.snapshot().settings.proxy.credential_ref == null);
    try std.testing.expectError(error.RecoveryRequired, controller.startSave(&store, .{}, null, false));
    vault.fail_delete = true;
    try controller.startRecovery(&store);
    try settle(&controller, &store);
    try std.testing.expectEqual(Phase.recovery_required, controller.phase);
    try std.testing.expect(store.snapshot().settings.proxy_pending_credential_ref != null);
    vault.fail_delete = false;
    try controller.startRecovery(&store);
    try settle(&controller, &store);
    try std.testing.expectEqual(Phase.saved, controller.phase);
    try std.testing.expect(store.snapshot().settings.proxy_pending_credential_ref == null);
}

test "proxy controller cancellation before publish leaves old configuration and joins" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    var vault: FakeVault = .{};
    var controller = try Controller.init(a, std.testing.io, .{ .injected_store = vault.store() });
    defer controller.deinit();
    try controller.startSave(&store, .{ .mode = .manual }, null, false);
    controller.cancel();
    try settle(&controller, &store);
    try std.testing.expectEqual(Phase.cancelled, controller.phase);
    try std.testing.expectEqual(proxy_config.Mode.direct, store.snapshot().settings.proxy.mode);
    try std.testing.expectEqual(@as(usize, 0), vault.puts);
    try controller.startProbe(store.snapshot().settings.proxy, .{ .mode = .manual, .host = "127.0.0.1", .username = "name" }, "draft-only", true);
    try settle(&controller, &store);
    try std.testing.expectEqual(Phase.detected, controller.phase);
    try std.testing.expectEqual(Source.manual, controller.result.source);
    try std.testing.expect(controller.result.proxied);
    try std.testing.expectEqual(@as(usize, 0), vault.puts);
}

test "proxy controller spawn failure leaves no credential journal" {
    const Failing = struct {
        fn spawn(_: *Job) !std.Thread {
            return error.SystemResources;
        }
    };
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    var controller = try Controller.init(a, std.testing.io, .{});
    defer controller.deinit();
    controller.spawn = Failing.spawn;
    try std.testing.expectError(error.SystemResources, controller.startSave(&store, .{ .mode = .manual, .username = "user" }, "canary", false));
    try std.testing.expect(!controller.isBusy());
    try std.testing.expect(store.snapshot().settings.proxy_pending_credential_ref == null);
}

test "proxy endpoint changes require explicit credentials before saving or probing" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    var vault: FakeVault = .{};
    var controller = try Controller.init(a, std.testing.io, .{ .injected_store = vault.store() });
    defer controller.deinit();
    try controller.startSave(&store, .{ .mode = .manual, .username = "user" }, "old-password", false);
    try settle(&controller, &store);
    const original = try proxy_config.clone(a, store.snapshot().settings.proxy);
    defer proxy_config.deinit(a, original);
    for (0..4) |field| {
        var changed = original;
        switch (field) {
            0 => changed.host = "different.example",
            1 => changed.port += 1,
            2 => changed.protocol = .socks5,
            else => changed.username = "different-user",
        }
        try std.testing.expectError(error.ProxyCredentialsNeedUpdate, controller.startSave(&store, changed, null, false));
        for ([_]bool{ false, true }) |detect_only| {
            try std.testing.expectError(error.ProxyCredentialsNeedUpdate, controller.startProbe(original, changed, null, detect_only));
        }
        try std.testing.expect(!controller.isBusy());
        try std.testing.expect(proxy_config.same(original, store.snapshot().settings.proxy));
    }
    try std.testing.expectEqual(@as(usize, 1), vault.puts);
    try std.testing.expectEqual(@as(usize, 0), vault.deletes);
    var changed = original;
    changed.host = "different.example";
    try controller.startProbe(original, changed, "draft-only-password", true);
    try settle(&controller, &store);
    try std.testing.expectEqual(Phase.detected, controller.phase);
    try std.testing.expect(proxy_config.same(original, store.snapshot().settings.proxy));
    try std.testing.expectEqual(@as(usize, 1), vault.puts);
    try controller.startSave(&store, changed, "replacement-password", false);
    try settle(&controller, &store);
    try std.testing.expectEqualStrings(changed.host, store.snapshot().settings.proxy.host);
    try std.testing.expect(!sameReference(original.credential_ref, store.snapshot().settings.proxy.credential_ref));
    changed = store.snapshot().settings.proxy;
    changed.port += 1;
    try controller.startSave(&store, changed, null, true);
    try settle(&controller, &store);
    try std.testing.expect(store.snapshot().settings.proxy.credential_ref == null);
    try std.testing.expectEqual(changed.port, store.snapshot().settings.proxy.port);
}

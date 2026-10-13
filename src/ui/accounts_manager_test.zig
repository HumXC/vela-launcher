const std = @import("std");
const accounts = @import("accounts_manager.zig");
const config = @import("../core/config.zig");
const auth = @import("../core/auth.zig");
const credentials = @import("../core/credentials.zig");
const t = std.testing;
const a = t.allocator;
const io = t.io;

const device_json = "{\"device_code\":\"fixture-device-secret\",\"user_code\":\"FIXTURE-CODE\",\"verification_uri\":\"https://www.microsoft.com/link\",\"expires_in\":900,\"interval\":1}";
const oauth_json = "{\"access_token\":\"fixture-msa-secret\",\"refresh_token\":\"fixture-refresh-secret\",\"expires_in\":3600,\"token_type\":\"Bearer\"}";
const xbl_json = "{\"Token\":\"fixture-xbl-secret\",\"DisplayClaims\":{\"xui\":[{\"uhs\":\"123456789\"}]}}";
const xsts_json = "{\"Token\":\"fixture-xsts-secret\",\"DisplayClaims\":{\"xui\":[{\"uhs\":\"123456789\"}]}}";
const mc_json = "{\"access_token\":\"fixture-minecraft-secret\",\"expires_in\":3600}";
const entitlement_json = "{\"items\":[{\"name\":\"game_minecraft\"}]}";
const profile_json = "{\"id\":\"00112233445566778899aabbccddeeff\",\"name\":\"FixturePlayer\"}";
const saved_ref: credentials.Reference = @splat('a');
const orphan_ref: credentials.Reference = @splat('b');
const Step = struct { suffix: []const u8, body: []const u8, status: u16 = 200, method: auth.Method = .post };
const happy = [_]Step{
    .{ .suffix = "/devicecode", .body = device_json },
    .{ .suffix = "/token", .body = oauth_json },
    .{ .suffix = "/user/authenticate", .body = xbl_json },
    .{ .suffix = "/xsts/authorize", .body = xsts_json },
    .{ .suffix = "/login_with_xbox", .body = mc_json },
    .{ .suffix = "/entitlements/mcstore", .body = entitlement_json, .method = .get },
    .{ .suffix = "/minecraft/profile", .body = profile_json, .method = .get },
};

// All fixture state is inspected only after tick has joined its worker.
const Fake = struct {
    main_thread: std.Thread.Id = 0,
    called_on_main: std.atomic.Value(bool) = .init(false),
    entered: std.atomic.Value(bool) = .init(false),
    exited: std.atomic.Value(bool) = .init(false),
    saw_http_cancel: std.atomic.Value(bool) = .init(false),
    steps: []const Step = &happy,
    requests: usize = 0,
    block_http: bool = false,
    expect_refresh_request: bool = false,
    cancel_on_put: bool = false,
    last_cancel: ?*const auth.CancelToken = null,
    secret: [256]u8 = @splat(0),
    secret_len: usize = 0,
    ref: credentials.Reference = saved_ref,
    puts: usize = 0,
    gets: usize = 0,
    deletes: usize = 0,
    entropy_calls: usize = 0,
    fail_put_after_commit: bool = false,
    fail_delete: bool = false,
    fail_stage: bool = false,
    refs: [8]credentials.Reference = undefined,
    refs_len: usize = 0,
    stages: usize = 0,
    removes: usize = 0,
    reference_calls: usize = 0,
    stage_before_put: bool = true,

    fn from(ctx: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ctx));
    }
    fn workerOnly(self: *Fake) void {
        if (std.Thread.getCurrentId() == self.main_thread) self.called_on_main.store(true, .release);
    }
    fn fixture(self: *Fake) accounts.Fixture {
        self.main_thread = std.Thread.getCurrentId();
        return .{
            .transport = .{ .ctx = self, .kind = .fixture, .supports_post = true, .request = request },
            .store = .{ .ctx = self, .vtable = &.{ .put = put, .get = get, .delete = delete } },
            .entropy = .{ .ctx = self, .fill = entropy },
            .journal = .{ .ctx = self, .stage = stage, .remove = remove, .references = references },
        };
    }
    fn preload(self: *Fake) void {
        const value = "fixture-refresh-secret";
        @memcpy(self.secret[0..value.len], value);
        self.secret_len = value.len;
    }
    fn request(ctx: *anyopaque, allocator: std.mem.Allocator, req: auth.Request) auth.TransportError!auth.Response {
        const self = from(ctx);
        self.workerOnly();
        self.last_cancel = req.cancel;
        self.entered.store(true, .release);
        defer self.exited.store(true, .release);
        if (self.block_http) {
            const end = clockMs() + 5_000;
            while (clockMs() < end) {
                if (req.cancel) |cancel| if (cancel.cancelled()) {
                    self.saw_http_cancel.store(true, .release);
                    return error.Cancelled;
                };
                io.sleep(.fromMilliseconds(1), .awake) catch return error.TransportFailure;
            }
            return error.Timeout;
        }
        const index = self.requests;
        self.requests += 1;
        if (index >= self.steps.len) return error.TransportFailure;
        const step = self.steps[index];
        if (!std.mem.endsWith(u8, req.url, step.suffix) or req.method != step.method or
            req.timeout_ms == 0 or req.deadline_ms == 0 or req.max_response_bytes != auth.max_response_bytes) return error.TransportFailure;
        if (self.expect_refresh_request and index == 0) {
            if (std.mem.indexOf(u8, req.body, "grant_type=refresh_token") == null or
                std.mem.indexOf(u8, req.body, "refresh_token=fixture-refresh-secret") == null) return error.TransportFailure;
        }
        return .{ .status = step.status, .body = try allocator.dupe(u8, step.body) };
    }
    fn entropy(ctx: *anyopaque, bytes: []u8) error{EntropyUnavailable}!void {
        const self = from(ctx);
        self.workerOnly();
        self.entropy_calls += 1;
        @memset(bytes, 0xab);
    }
    fn put(ctx: *anyopaque, reference: []const u8, secret: []const u8) credentials.Error!void {
        const self = from(ctx);
        self.workerOnly();
        self.puts += 1;
        if (!std.mem.eql(u8, reference, &saved_ref)) {
            var staged = false;
            for (self.refs[0..self.refs_len]) |ref| if (std.mem.eql(u8, reference, &ref)) {
                staged = true;
            };
            self.stage_before_put = self.stage_before_put and staged;
        }
        if (secret.len > self.secret.len) return error.TooLarge;
        @memcpy(&self.ref, reference);
        @memset(&self.secret, 0);
        @memcpy(self.secret[0..secret.len], secret);
        self.secret_len = secret.len;
        if (self.cancel_on_put) if (self.last_cancel) |token| @constCast(token).cancel();
        if (self.fail_put_after_commit) return error.StorageFailure;
    }
    fn get(ctx: *anyopaque, allocator: std.mem.Allocator, reference: []const u8) credentials.Error!credentials.Secret {
        const self = from(ctx);
        self.workerOnly();
        self.gets += 1;
        if (self.secret_len == 0 or !std.mem.eql(u8, reference, &self.ref)) return error.NotFound;
        return .{ .allocator = allocator, .bytes = try allocator.dupe(u8, self.secret[0..self.secret_len]) };
    }
    fn delete(ctx: *anyopaque, reference: []const u8) credentials.Error!void {
        const self = from(ctx);
        self.workerOnly();
        self.deletes += 1;
        if (self.fail_delete) return error.StorageFailure;
        if (self.secret_len == 0 or !std.mem.eql(u8, reference, &self.ref)) return error.NotFound;
        std.crypto.secureZero(u8, &self.secret);
        self.secret_len = 0;
    }
    fn stage(ctx: *anyopaque, reference: credentials.Reference) anyerror!void {
        const self = from(ctx);
        self.workerOnly();
        self.stages += 1;
        if (self.fail_stage) return error.FixtureStageFailure;
        for (self.refs[0..self.refs_len]) |ref| if (std.mem.eql(u8, &ref, &reference)) return;
        if (self.refs_len == self.refs.len) return error.FixtureJournalFull;
        self.refs[self.refs_len] = reference;
        self.refs_len += 1;
    }
    fn remove(ctx: *anyopaque, reference: credentials.Reference) anyerror!void {
        const self = from(ctx);
        self.workerOnly();
        self.removes += 1;
        for (self.refs[0..self.refs_len], 0..) |ref, i| if (std.mem.eql(u8, &ref, &reference)) {
            self.refs_len -= 1;
            self.refs[i] = self.refs[self.refs_len];
            return;
        };
    }
    fn references(ctx: *anyopaque) []const credentials.Reference {
        const self = from(ctx);
        self.workerOnly();
        self.reference_calls += 1;
        return self.refs[0..self.refs_len];
    }
};

fn clockMs() u64 {
    return @intCast(@max(0, @divFloor(std.Io.Clock.awake.now(io).nanoseconds, 1_000_000)));
}
fn rootPath(tmp: *t.TmpDir) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    return a.dupe(u8, buf[0..len]);
}
fn configure(store: *config.Store) !void {
    var doc = store.snapshot().*;
    doc.settings.microsoft_client_id = "fixture-public-client";
    try store.update(doc);
}
fn savedAccount(store: *config.Store) !void {
    try store.update(.{ .settings = .{ .microsoft_client_id = "fixture-public-client" }, .accounts = &.{.{ .id = "saved-online", .name = "FixturePlayer", .uuid = "00112233445566778899aabbccddeeff", .kind = .microsoft, .credential_ref = &saved_ref }}, .selected_account = "saved-online" });
}
fn settle(manager: *accounts.Manager, store: *config.Store) !void {
    const end = clockMs() + 8_000;
    while (clockMs() < end) {
        manager.tick(store);
        const snap = manager.snapshot();
        if (!snap.busy and snap.phase != .device_pending and snap.phase != .slow_down and snap.phase != .starting) return;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.FixtureWaitTimedOut;
}
fn waitEntered(fake: *Fake) !void {
    const end = clockMs() + 2_000;
    while (!fake.entered.load(.acquire)) {
        if (clockMs() >= end) return error.FixtureWaitTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}
fn expectWorkerOnly(fake: *Fake) !void {
    try t.expect(!fake.called_on_main.load(.acquire));
}
fn expectNoPlaintext(tmp: *t.TmpDir) !void {
    const bytes = try tmp.dir.readFileAlloc(io, ".vela/config.json", a, .limited(1024 * 1024));
    defer a.free(bytes);
    for ([_][]const u8{ "fixture-minecraft-secret", "fixture-refresh-secret", "fixture-msa-secret", "fixture-device-secret", "fixture-xbl-secret", "fixture-xsts-secret", "access_token", "refresh_token" }) |secret|
        try t.expect(std.mem.indexOf(u8, bytes, secret) == null);
}

test "accounts offline UUID matches Java and validates ASCII account names" {
    try t.expectEqualStrings("5627dd98e6be3c21b8a8e92344183641", &(try accounts.offlineUuid("Steve")));
    for ([_][]const u8{ "abc", "A_1", "abcdefghijklmnop" }) |name| _ = try accounts.offlineUuid(name);
    for ([_][]const u8{ "", "ab", "abcdefghijklmnopq", "bad name", "bad-name", "bad.name", "a/b", "a\x00b", "\xffab" }) |name|
        try t.expectError(error.InvalidAccountName, accounts.offlineUuid(name));
}

test "accounts initialization is inert and unconfigured online work makes no HTTP calls" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    var fake: Fake = .{};
    var manager = try accounts.Manager.initWithOptions(a, io, .{ .root = root, .fixture = fake.fixture() });
    defer manager.deinit();
    try t.expectEqual(accounts.Phase.idle, manager.snapshot().phase);
    manager.tick(&store);
    try t.expectEqual(@as(usize, 0), fake.requests);
    try t.expectEqual(@as(usize, 0), fake.gets + fake.puts + fake.deletes + fake.stages + fake.removes);
    try t.expectError(error.FileNotFound, tmp.dir.statFile(io, ".vela", .{}));
    try t.expectError(error.Unconfigured, manager.startDevice(&store));
    try t.expectEqual(@as(usize, 0), fake.requests);
    var inert = try accounts.Manager.init(a, io, root);
    defer inert.deinit();
    try t.expectError(error.FileNotFound, tmp.dir.statFile(io, ".vela", .{}));
}

test "accounts offline CRUD persists, owns launch selection, and rejects UUID collisions" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    var manager = try accounts.Manager.init(a, io, root);
    defer manager.deinit();
    try t.expectError(error.NoAccountSelected, manager.launchIdentity(0));
    try manager.addOffline(&store, "Steve");
    const steve_id = try a.dupe(u8, store.snapshot().accounts[0].id);
    defer a.free(steve_id);
    try t.expect(store.snapshot().selected_account == null);
    try t.expectError(error.NoAccountSelected, manager.launchIdentity(0));
    try t.expect(!manager.canLaunch(0));
    try manager.select(&store, steve_id);
    try t.expect(manager.canLaunch(0));
    try t.expect(config.validId(steve_id));
    try t.expect(!std.mem.eql(u8, steve_id, "Steve"));
    try t.expectError(error.DuplicateUuid, manager.addOffline(&store, "Steve"));
    try manager.addOffline(&store, "Alex");
    try t.expectEqualStrings(steve_id, store.snapshot().selected_account.?);
    const alex_id = try a.dupe(u8, store.snapshot().accounts[1].id);
    defer a.free(alex_id);
    try t.expect(!std.mem.eql(u8, steve_id, alex_id));
    try t.expectError(error.DuplicateUuid, manager.editOffline(&store, alex_id, "Steve"));
    try manager.select(&store, alex_id);
    var owned = try manager.cloneLaunchSession(a, 0);
    defer owned.deinit();
    try manager.editOffline(&store, alex_id, "Alex_2");
    try t.expectEqualStrings("Alex", owned.username);
    try t.expect(owned.token == null);
    const identity = try manager.launchIdentity(std.math.maxInt(u64));
    try t.expectEqualStrings("Alex_2", identity.username);
    try t.expectEqualStrings(&(try accounts.offlineUuid("Alex_2")), identity.uuid);
    try t.expect(identity.access_token == null);
    try store.update(store.snapshot().*);
    try t.expectEqualStrings("Alex_2", (try manager.launchIdentity(0)).username);
    try store.reconcile();
    const reloaded = &store;
    try t.expectEqual(@as(usize, 2), reloaded.snapshot().accounts.len);
    try t.expectEqualStrings(alex_id, reloaded.snapshot().selected_account.?);
    try manager.removeOffline(&store, alex_id);
    try t.expect(store.snapshot().selected_account == null);
    try t.expectEqual(@as(usize, 1), store.snapshot().accounts.len);
    try t.expectError(error.NoAccountSelected, manager.launchIdentity(0));
    try manager.select(&store, steve_id);
    try t.expectEqualStrings("Steve", (try manager.launchIdentity(0)).username);
    try manager.removeOffline(&store, steve_id);
    try t.expect(store.snapshot().selected_account == null);
    try t.expectError(error.NoAccountSelected, manager.launchIdentity(0));
    try t.expectError(error.AccountNotFound, manager.select(&store, "missing"));
    try t.expectError(error.AccountNotFound, manager.removeOffline(&store, "missing"));
    try expectNoPlaintext(&tmp);
}

test "accounts offline login immediately selects persisted owned launch identity" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    var manager = try accounts.Manager.init(a, io, root);
    defer manager.deinit();

    try manager.loginOffline(&store, "Steve");
    const steve_id = try a.dupe(u8, store.snapshot().selected_account.?);
    defer a.free(steve_id);
    try t.expectEqual(@as(usize, 1), store.snapshot().accounts.len);
    try t.expectEqualStrings(steve_id, store.snapshot().accounts[0].id);
    try t.expect(manager.canLaunch(0));
    var owned = try manager.cloneLaunchSession(a, 0);
    defer owned.deinit();
    try t.expectEqualStrings(steve_id, owned.id);
    try t.expectEqualStrings("Steve", owned.username);
    try t.expectEqualStrings(&(try accounts.offlineUuid("Steve")), owned.uuid);
    try t.expectEqual(config.AccountKind.offline, owned.kind);
    try t.expect(owned.token == null);

    try manager.loginOffline(&store, "Alex");
    const alex_id = try a.dupe(u8, store.snapshot().selected_account.?);
    defer a.free(alex_id);
    try t.expect(!std.mem.eql(u8, steve_id, alex_id));
    try t.expectEqualStrings("Alex", (try manager.launchIdentity(0)).username);
    try t.expectEqualStrings(&(try accounts.offlineUuid("Alex")), (try manager.launchIdentity(0)).uuid);
    try t.expectEqualStrings("Steve", owned.username);
    try t.expectEqualStrings(&(try accounts.offlineUuid("Steve")), owned.uuid);

    // Adding metadata alone must preserve the explicit login selection.
    try manager.addOffline(&store, "Bob");
    try t.expectEqualStrings(alex_id, store.snapshot().selected_account.?);
    try store.reconcile();
    const reloaded = &store;
    try t.expectEqual(@as(usize, 3), reloaded.snapshot().accounts.len);
    try t.expectEqualStrings(alex_id, reloaded.snapshot().selected_account.?);
    const selected = accounts.findAccount(reloaded.snapshot(), alex_id).?;
    try t.expectEqualStrings("Alex", selected.name);
    try t.expectEqualStrings(&(try accounts.offlineUuid("Alex")), selected.uuid);
    try expectNoPlaintext(&tmp);
}

test "accounts invalid and duplicate offline login preserve config and selection" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    var manager = try accounts.Manager.init(a, io, root);
    defer manager.deinit();

    try t.expectError(error.InvalidAccountName, manager.loginOffline(&store, "ab"));
    try t.expectEqual(@as(usize, 0), store.snapshot().accounts.len);
    try t.expect(store.snapshot().selected_account == null);
    try t.expectError(error.NoAccountSelected, manager.launchIdentity(0));
    try t.expectError(error.FileNotFound, tmp.dir.statFile(io, ".vela", .{}));

    try manager.loginOffline(&store, "Steve");
    const selected_id = try a.dupe(u8, store.snapshot().selected_account.?);
    defer a.free(selected_id);
    const before = try tmp.dir.readFileAlloc(io, ".vela/config.json", a, .limited(1024 * 1024));
    defer a.free(before);
    for ([_][]const u8{ "", "ab", "abcdefghijklmnopq", "bad name", "user@example.com" }) |name|
        try t.expectError(error.InvalidAccountName, manager.loginOffline(&store, name));
    try t.expectError(error.DuplicateUuid, manager.loginOffline(&store, "Steve"));
    try t.expectEqual(@as(usize, 1), store.snapshot().accounts.len);
    try t.expectEqualStrings(selected_id, store.snapshot().selected_account.?);
    const identity = try manager.launchIdentity(0);
    try t.expectEqualStrings(selected_id, identity.id);
    try t.expectEqualStrings("Steve", identity.username);
    try t.expectEqualStrings(&(try accounts.offlineUuid("Steve")), identity.uuid);
    const after = try tmp.dir.readFileAlloc(io, ".vela/config.json", a, .limited(1024 * 1024));
    defer a.free(after);
    try t.expectEqualStrings(before, after);
}

test "accounts UUID collision includes Microsoft identities and ignores hex case" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    try store.update(.{ .accounts = &.{.{ .id = "online", .name = "Steve", .uuid = "5627DD98E6BE3C21B8A8E92344183641", .kind = .microsoft }} });
    var manager = try accounts.Manager.init(a, io, root);
    defer manager.deinit();
    try t.expectError(error.DuplicateUuid, manager.addOffline(&store, "Steve"));
    try t.expectError(error.NotOfflineAccount, manager.editOffline(&store, "online", "Alex"));
    try t.expectError(error.NotOfflineAccount, manager.removeOffline(&store, "online"));
}

test "accounts explicit refresh publishes joined fixture result with expiry and no plaintext" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    try savedAccount(&store);
    var fake: Fake = .{ .steps = happy[1..] };
    fake.preload();
    var manager = try accounts.Manager.initWithOptions(a, io, .{ .root = root, .fixture = fake.fixture() });
    defer manager.deinit();
    manager.tick(&store);
    try t.expectEqual(@as(usize, 0), fake.requests);
    try manager.select(&store, "saved-online");
    try t.expectError(error.LoginRequired, manager.launchIdentity(0));
    try manager.refreshSelected(&store);
    try settle(&manager, &store);
    try t.expectEqual(accounts.Phase.authenticated, manager.snapshot().phase);
    try t.expectEqual(@as(usize, 6), fake.requests);
    try t.expectEqualStrings("fixture-minecraft-secret", (try manager.launchIdentity(clockMs())).access_token.?);
    try t.expectError(error.AuthorizationExpired, manager.launchIdentity(std.math.maxInt(u64)));
    try t.expect(!manager.canLaunch(std.math.maxInt(u64)));
    try expectWorkerOnly(&fake);
    try expectNoPlaintext(&tmp);
}

test "accounts device flow journals before vault write then acknowledges config publication" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    try configure(&store);
    var fake: Fake = .{};
    var manager = try accounts.Manager.initWithOptions(a, io, .{ .root = root, .fixture = fake.fixture() });
    defer manager.deinit();
    try manager.startDeviceRemember(&store, true);
    try settle(&manager, &store);
    try t.expectEqual(accounts.Phase.authenticated, manager.snapshot().phase);
    try t.expectEqual(@as(usize, 7), fake.requests);
    try t.expect(fake.stage_before_put);
    try t.expectEqual(@as(usize, 1), fake.stages);
    try t.expectEqual(@as(usize, 1), fake.puts);
    try t.expectEqual(@as(usize, 0), fake.refs_len);
    try t.expectEqual(@as(usize, 1), store.snapshot().accounts.len);
    const account = store.snapshot().accounts[0];
    try t.expect(std.mem.startsWith(u8, account.id, "microsoft-"));
    try t.expect(config.validId(account.id));
    try t.expect(!std.mem.eql(u8, account.id, account.uuid));
    try t.expectEqualStrings("FixturePlayer", account.name);
    try t.expectEqualStrings("00112233445566778899aabbccddeeff", account.uuid);
    try t.expect(credentials.validateReference(account.credential_ref.?));
    try t.expectEqualStrings(account.id, store.snapshot().selected_account.?);
    try expectWorkerOnly(&fake);
    try expectNoPlaintext(&tmp);
}

test "accounts cancellation waits for HTTP worker exit and cannot publish authentication" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    try configure(&store);
    var fake: Fake = .{ .block_http = true };
    var manager = try accounts.Manager.initWithOptions(a, io, .{ .root = root, .fixture = fake.fixture() });
    defer manager.deinit();
    try manager.startDevice(&store);
    try waitEntered(&fake);
    try t.expect(manager.snapshot().busy);
    try t.expectEqual(@as(usize, 0), store.snapshot().accounts.len);
    manager.cancel();
    try settle(&manager, &store);
    try t.expect(fake.exited.load(.acquire));
    try t.expect(fake.saw_http_cancel.load(.acquire));
    try t.expectEqual(accounts.Phase.cancelled, manager.snapshot().phase);
    try t.expect(!manager.snapshot().busy);
    try t.expectEqual(@as(usize, 0), store.snapshot().accounts.len);
    try t.expectEqual(@as(usize, 0), fake.puts);
    try expectWorkerOnly(&fake);
}

test "accounts entitlement and missing profile reject fixture refresh before vault writes" {
    for ([_]bool{ false, true }) |missing_profile| {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        const root = try rootPath(&tmp);
        defer a.free(root);
        var store = try config.Store.init(a, io, root);
        defer store.deinit();
        try savedAccount(&store);
        var steps = happy;
        if (missing_profile) steps[6].status = 404 else steps[5].body = "{\"items\":[]}";
        var fake: Fake = .{ .steps = steps[1..] };
        fake.preload();
        var manager = try accounts.Manager.initWithOptions(a, io, .{ .root = root, .fixture = fake.fixture() });
        defer manager.deinit();
        try manager.select(&store, "saved-online");
        try manager.refreshSelected(&store);
        try settle(&manager, &store);
        try t.expectEqual(accounts.Phase.failed, manager.snapshot().phase);
        try t.expectEqual(if (missing_profile) @as(anyerror, error.ProfileMissing) else @as(anyerror, error.EntitlementDenied), manager.snapshot().failure.?);
        try t.expectEqual(@as(usize, 0), fake.puts);
        try t.expectError(error.LoginRequired, manager.launchIdentity(0));
        try expectWorkerOnly(&fake);
    }
}

test "accounts journal stage failure prevents native write and ambiguous commit remains cleanup debt" {
    for ([_]bool{ true, false }) |stage_failure| {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        const root = try rootPath(&tmp);
        defer a.free(root);
        var store = try config.Store.init(a, io, root);
        defer store.deinit();
        try configure(&store);
        var fake: Fake = .{ .fail_stage = stage_failure, .fail_put_after_commit = !stage_failure };
        var manager = try accounts.Manager.initWithOptions(a, io, .{ .root = root, .fixture = fake.fixture() });
        defer manager.deinit();
        try manager.startDeviceRemember(&store, true);
        try settle(&manager, &store);
        try t.expectEqual(accounts.Phase.failed, manager.snapshot().phase);
        try t.expectEqual(@as(usize, 0), store.snapshot().accounts.len);
        if (stage_failure) {
            try t.expectEqual(@as(usize, 0), fake.puts);
        } else {
            try t.expectEqual(@as(usize, 1), fake.puts);
            try t.expectEqual(@as(usize, 1), fake.refs_len);
            try t.expect(fake.secret_len > 0);
            try t.expect(manager.snapshot().cleanup_count > 0);
            try manager.retryCleanup(&store);
            try settle(&manager, &store);
            try t.expectEqual(@as(usize, 0), fake.secret_len);
            try t.expectEqual(@as(usize, 0), fake.refs_len);
            try t.expectEqual(@as(usize, 0), manager.snapshot().cleanup_count);
        }
        try expectWorkerOnly(&fake);
        try expectNoPlaintext(&tmp);
    }
}

test "accounts cleanup preserves referenced credentials but removes orphan journal debt" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    try savedAccount(&store);
    var fake: Fake = .{ .refs_len = 2 };
    fake.refs[0] = saved_ref;
    fake.refs[1] = orphan_ref;
    fake.preload();
    var manager = try accounts.Manager.initWithOptions(a, io, .{ .root = root, .fixture = fake.fixture() });
    defer manager.deinit();
    try manager.retryCleanup(&store);
    try settle(&manager, &store);
    try t.expectEqual(@as(usize, 1), fake.deletes);
    try t.expectEqual(@as(usize, 0), fake.refs_len);
    try t.expect(fake.secret_len > 0);
    try t.expectEqualStrings(&saved_ref, store.snapshot().accounts[0].credential_ref.?);
    try expectWorkerOnly(&fake);
}

test "accounts sign out invalidates main token immediately and retains reference until deletion succeeds" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    try savedAccount(&store);
    var fake: Fake = .{ .steps = happy[1..], .fail_delete = true };
    fake.preload();
    var manager = try accounts.Manager.initWithOptions(a, io, .{ .root = root, .fixture = fake.fixture() });
    defer manager.deinit();
    try manager.select(&store, "saved-online");
    try manager.refreshSelected(&store);
    try settle(&manager, &store);
    try manager.signOut(&store, "saved-online");
    try t.expectError(error.Busy, manager.launchIdentity(clockMs()));
    try t.expect(!manager.canLaunch(clockMs()));
    try settle(&manager, &store);
    try t.expectError(error.LoginRequired, manager.launchIdentity(clockMs()));
    try t.expectEqualStrings(&saved_ref, store.snapshot().accounts[0].credential_ref.?);
    fake.fail_delete = false;
    try manager.signOut(&store, "saved-online");
    try settle(&manager, &store);
    try t.expect(store.snapshot().accounts[0].credential_ref == null);
    try t.expectEqual(@as(usize, 0), fake.secret_len);
    try expectWorkerOnly(&fake);
    try expectNoPlaintext(&tmp);
}

const WipeSpy = struct {
    watched: ?[*]u8 = null,
    wiped: bool = false,
    fn allocator(self: *WipeSpy) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        return a.rawAlloc(len, alignment, ra);
    }
    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *WipeSpy = @ptrCast(@alignCast(ctx));
        if (self.watched == bytes.ptr) {
            self.wiped = true;
            for (bytes) |byte| if (byte != 0) {
                self.wiped = false;
                break;
            };
        }
        a.rawFree(bytes, alignment, ra);
    }
};

test "accounts owned launch clone outlives manager and wipes token before allocator free" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    try savedAccount(&store);
    var fake: Fake = .{ .steps = happy[1..] };
    fake.preload();
    var manager = try accounts.Manager.initWithOptions(a, io, .{ .root = root, .fixture = fake.fixture() });
    var manager_live = true;
    defer if (manager_live) manager.deinit();
    try manager.select(&store, "saved-online");
    try manager.refreshSelected(&store);
    try settle(&manager, &store);
    var spy: WipeSpy = .{};
    var owned = try manager.cloneLaunchSession(spy.allocator(), clockMs());
    var owned_live = true;
    defer if (owned_live) owned.deinit();
    spy.watched = owned.token.?.bytes.ptr;
    manager.deinit();
    manager_live = false;
    try t.expectEqualStrings("FixturePlayer", owned.username);
    try t.expectEqualStrings("fixture-minecraft-secret", owned.token.?.bytes);
    owned.deinit();
    owned_live = false;
    try t.expect(spy.wiped);
}

test "accounts session-only device login does not access vault journal or fixture entropy" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    try configure(&store);
    var fake: Fake = .{};
    var manager = try accounts.Manager.initWithOptions(a, io, .{ .root = root, .fixture = fake.fixture() });
    defer manager.deinit();
    try t.expect(!manager.snapshot().remember_available);
    try manager.startDevice(&store);
    try settle(&manager, &store);
    try t.expectEqual(accounts.Phase.authenticated, manager.snapshot().phase);
    try t.expectEqual(@as(usize, 7), fake.requests);
    try t.expectEqual(@as(usize, 0), fake.gets + fake.puts + fake.deletes + fake.stages + fake.removes + fake.entropy_calls + fake.reference_calls);
    try t.expect(store.snapshot().accounts[0].credential_ref == null);
    try t.expectEqualStrings("fixture-minecraft-secret", (try manager.launchIdentity(clockMs())).access_token.?);
    manager.tick(&store);
    try t.expectEqual(@as(usize, 7), fake.requests);
    try expectWorkerOnly(&fake);
    try expectNoPlaintext(&tmp);
}

test "accounts cancelled config publication retains committed metadata but never adopts token on retry" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    try configure(&store);
    var fake: Fake = .{};
    var manager = try accounts.Manager.initWithOptions(a, io, .{ .root = root, .fixture = fake.fixture() });
    defer manager.deinit();
    try tmp.dir.rename(".vela/config.json", tmp.dir, ".vela/previous.json", io);
    try tmp.dir.createDir(io, ".vela/config.json", .default_dir);
    try manager.startDeviceRemember(&store, true);
    try settle(&manager, &store);
    try t.expect(manager.snapshot().publication_pending);
    try t.expectEqual(@as(usize, 0), store.snapshot().accounts.len);
    try t.expectEqual(@as(usize, 1), fake.puts);
    try t.expectEqual(@as(usize, 1), fake.refs_len);
    try t.expect(store.publicationUncertain());
    try t.expectError(error.Busy, manager.startDeviceRemember(&store, true));
    try t.expectError(error.Busy, manager.retryCleanup(&store));
    const requests = fake.requests;
    manager.tick(&store);
    try t.expect(manager.snapshot().publication_pending);
    manager.cancel();
    try tmp.dir.deleteDir(io, ".vela/config.json");
    try settle(&manager, &store);
    const deletes = fake.deletes;
    try t.expectError(error.FileNotFound, manager.retryPublication(&store));
    try t.expect(manager.snapshot().publication_pending);
    try t.expect(store.publicationUncertain());
    try t.expectEqual(deletes, fake.deletes);
    try t.expectEqual(@as(usize, 1), fake.refs_len);
    try tmp.dir.rename(".vela/previous.json", tmp.dir, ".vela/config.json", io);
    try manager.retryPublication(&store);
    try settle(&manager, &store);
    try t.expect(!manager.snapshot().publication_pending);
    try t.expectError(error.LoginRequired, manager.launchIdentity(clockMs()));
    try t.expect(credentials.validateReference(store.snapshot().accounts[0].credential_ref.?));
    try t.expectEqual(requests, fake.requests);
    try t.expectEqual(@as(usize, 1), fake.puts);
    try t.expectEqual(@as(usize, 0), fake.refs_len);
    try t.expectEqual(@as(usize, 1), store.snapshot().accounts.len);
    try expectWorkerOnly(&fake);
    try expectNoPlaintext(&tmp);
}

test "accounts remembered-login capability probe is explicit and never requests HTTP" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    var fake: Fake = .{};
    var manager = try accounts.Manager.initWithOptions(a, io, .{ .root = root, .fixture = fake.fixture() });
    defer manager.deinit();
    try t.expect(!manager.snapshot().remember_available);
    try t.expectEqual(@as(usize, 0), fake.gets);
    try manager.probeRemember();
    try settle(&manager, &store);
    try t.expect(manager.snapshot().remember_available);
    try t.expectEqual(@as(usize, 0), fake.requests + fake.puts + fake.deletes + fake.stages);
    try expectWorkerOnly(&fake);
}

test "accounts cancelling another login immediately invalidates prior main session token" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    try savedAccount(&store);
    var fake: Fake = .{ .steps = happy[1..] };
    fake.preload();
    var manager = try accounts.Manager.initWithOptions(a, io, .{ .root = root, .fixture = fake.fixture() });
    defer manager.deinit();
    try manager.select(&store, "saved-online");
    try manager.refreshSelected(&store);
    try settle(&manager, &store);
    try t.expect(manager.canLaunch(clockMs()));
    var owned = try manager.cloneLaunchSession(a, clockMs());
    defer owned.deinit();
    fake.block_http = true;
    fake.entered.store(false, .release);
    fake.exited.store(false, .release);
    try manager.startDevice(&store);
    try waitEntered(&fake);
    try t.expect(!manager.canLaunch(clockMs()));
    manager.cancel();
    try t.expect(!manager.canLaunch(clockMs()));
    try t.expectError(error.Busy, manager.launchIdentity(clockMs()));
    try settle(&manager, &store);
    try t.expectError(error.LoginRequired, manager.launchIdentity(clockMs()));
    try t.expectEqual(accounts.Phase.cancelled, manager.snapshot().phase);
    try t.expect(fake.saw_http_cancel.load(.acquire));
    try t.expectEqualStrings("fixture-minecraft-secret", owned.token.?.bytes);
    try expectWorkerOnly(&fake);
}

test "accounts session-only explicit refresh uses memory refresh token without vault or journal" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    try configure(&store);
    var fake: Fake = .{};
    var manager = try accounts.Manager.initWithOptions(a, io, .{ .root = root, .fixture = fake.fixture() });
    defer manager.deinit();
    try manager.startDevice(&store);
    try settle(&manager, &store);
    try t.expectEqual(accounts.Phase.authenticated, manager.snapshot().phase);
    try t.expectEqual(@as(usize, 0), fake.gets + fake.puts + fake.deletes + fake.stages + fake.removes + fake.entropy_calls + fake.reference_calls);
    const id = try a.dupe(u8, store.snapshot().accounts[0].id);
    defer a.free(id);
    fake.steps = happy[1..];
    fake.requests = 0;
    fake.expect_refresh_request = true;
    manager.tick(&store);
    try t.expectEqual(@as(usize, 0), fake.requests);
    try manager.refreshSelected(&store);
    try settle(&manager, &store);
    try t.expectEqual(accounts.Phase.authenticated, manager.snapshot().phase);
    try t.expectEqual(@as(usize, 6), fake.requests);
    try t.expectEqual(@as(usize, 0), fake.gets + fake.puts + fake.deletes + fake.stages + fake.removes + fake.entropy_calls + fake.reference_calls);
    try t.expectEqualStrings(id, store.snapshot().selected_account.?);
    try t.expectEqual(@as(usize, 1), store.snapshot().accounts.len);
    try t.expect(store.snapshot().accounts[0].credential_ref == null);
    try t.expectEqualStrings("fixture-minecraft-secret", (try manager.launchIdentity(clockMs())).access_token.?);
    try expectWorkerOnly(&fake);
    try expectNoPlaintext(&tmp);
}

test "accounts cancellation inside successful vault put publishes metadata but never launch token" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    try configure(&store);
    var fake: Fake = .{ .cancel_on_put = true };
    var manager = try accounts.Manager.initWithOptions(a, io, .{ .root = root, .fixture = fake.fixture() });
    defer manager.deinit();
    try manager.startDeviceRemember(&store, true);
    try settle(&manager, &store);
    try t.expectEqual(@as(usize, 1), fake.puts);
    try t.expect(fake.secret_len > 0);
    try t.expectEqual(@as(usize, 1), store.snapshot().accounts.len);
    try t.expect(credentials.validateReference(store.snapshot().accounts[0].credential_ref.?));
    try t.expectEqualStrings(store.snapshot().accounts[0].id, store.snapshot().selected_account.?);
    try t.expectError(error.LoginRequired, manager.launchIdentity(clockMs()));
    try expectWorkerOnly(&fake);
    try expectNoPlaintext(&tmp);
}

test "accounts remembered refresh profile mismatch preserves secret and reference without writing" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    try savedAccount(&store);
    var fake: Fake = .{ .steps = happy[1..] };
    fake.preload();
    var manager = try accounts.Manager.initWithOptions(a, io, .{ .root = root, .fixture = fake.fixture() });
    defer manager.deinit();
    try manager.select(&store, "saved-online");
    try manager.refreshSelected(&store);
    try settle(&manager, &store);
    try t.expectEqualStrings("fixture-minecraft-secret", (try manager.launchIdentity(clockMs())).access_token.?);
    var steps = happy;
    steps[1].body = "{\"access_token\":\"fixture-msa-secret\",\"refresh_token\":\"fixture-rotated-refresh-secret\",\"expires_in\":3600,\"token_type\":\"Bearer\"}";
    steps[6].body = "{\"id\":\"ffeeddccbbaa99887766554433221100\",\"name\":\"WrongPlayer\"}";
    fake.steps = steps[1..];
    fake.requests = 0;
    fake.puts = 0;
    try manager.refreshSelected(&store);
    try settle(&manager, &store);
    try t.expectEqual(accounts.Phase.failed, manager.snapshot().phase);
    try t.expectEqual(@as(anyerror, error.AccountMismatch), manager.snapshot().failure.?);
    try t.expectEqual(@as(usize, 0), fake.puts);
    try t.expectEqualStrings("fixture-refresh-secret", fake.secret[0..fake.secret_len]);
    try t.expectEqualStrings(&saved_ref, store.snapshot().accounts[0].credential_ref.?);
    try t.expectEqualStrings("00112233445566778899aabbccddeeff", store.snapshot().accounts[0].uuid);
    try t.expectError(error.LoginRequired, manager.launchIdentity(clockMs()));
    try expectWorkerOnly(&fake);
    try expectNoPlaintext(&tmp);
}

test "accounts more than 256 offline identities do not block protected cleanup refresh or sign out" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const pool = arena.allocator();
    var list: [258]config.Account = undefined;
    for (list[0..257], 0..) |*account, index| {
        const name = try std.fmt.allocPrint(pool, "User_{d}", .{index});
        account.* = .{ .id = try std.fmt.allocPrint(pool, "offline-{d}", .{index}), .name = name, .uuid = try pool.dupe(u8, &(try accounts.offlineUuid(name))), .kind = .offline };
    }
    list[257] = .{ .id = "saved-online", .name = "FixturePlayer", .uuid = "00112233445566778899aabbccddeeff", .kind = .microsoft, .credential_ref = &saved_ref };
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    try store.update(.{ .settings = .{ .microsoft_client_id = "fixture-public-client" }, .accounts = &list, .selected_account = "saved-online" });
    var fake: Fake = .{ .steps = happy[1..] };
    fake.preload();
    fake.refs[0] = saved_ref;
    fake.refs[1] = orphan_ref;
    fake.refs_len = 2;
    var manager = try accounts.Manager.initWithOptions(a, io, .{ .root = root, .fixture = fake.fixture() });
    defer manager.deinit();
    try manager.select(&store, "saved-online");
    try manager.retryCleanup(&store);
    try settle(&manager, &store);
    try t.expectEqual(@as(usize, 1), fake.deletes);
    try t.expectEqual(@as(usize, 0), fake.refs_len);
    try t.expectEqualStrings("fixture-refresh-secret", fake.secret[0..fake.secret_len]);
    try t.expectEqualStrings(&saved_ref, store.snapshot().accounts[257].credential_ref.?);
    try manager.refreshSelected(&store);
    try settle(&manager, &store);
    try t.expect(manager.canLaunch(clockMs()));
    try t.expectEqualStrings("fixture-minecraft-secret", (try manager.launchIdentity(clockMs())).access_token.?);
    try manager.signOut(&store, "saved-online");
    try t.expect(!manager.canLaunch(clockMs()));
    try settle(&manager, &store);
    try t.expect(store.snapshot().accounts[257].credential_ref == null);
    try t.expectEqual(@as(usize, 0), fake.secret_len);
    try t.expectEqual(@as(usize, 258), store.snapshot().accounts.len);
    try expectWorkerOnly(&fake);
    try expectNoPlaintext(&tmp);
}

test "accounts offline login allocation failures never commit or replace selection and retry succeeds" {
    // Fail the account list and each owned selection string in turn.
    for (0..4) |offset| {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        const root = try rootPath(&tmp);
        defer a.free(root);
        var store = try config.Store.init(a, io, root);
        defer store.deinit();
        var failing = std.testing.FailingAllocator.init(a, .{});
        var fake: Fake = .{};
        var manager = try accounts.Manager.initWithOptions(failing.allocator(), io, .{ .root = root, .fixture = fake.fixture() });
        defer manager.deinit();
        try manager.loginOffline(&store, "Steve");
        const selected_id = try a.dupe(u8, store.snapshot().selected_account.?);
        defer a.free(selected_id);
        const before = try tmp.dir.readFileAlloc(io, ".vela/config.json", a, .limited(1024 * 1024));
        defer a.free(before);

        failing.fail_index = failing.alloc_index + offset;
        failing.resize_fail_index = failing.resize_index;
        try t.expectError(error.OutOfMemory, manager.loginOffline(&store, "Alex"));
        try t.expect(failing.has_induced_failure);
        try t.expectEqual(@as(usize, 1), store.snapshot().accounts.len);
        try t.expectEqualStrings(selected_id, store.snapshot().selected_account.?);
        const identity = try manager.launchIdentity(0);
        try t.expectEqualStrings(selected_id, identity.id);
        try t.expectEqualStrings("Steve", identity.username);
        try t.expectEqualStrings(&(try accounts.offlineUuid("Steve")), identity.uuid);
        const after = try tmp.dir.readFileAlloc(io, ".vela/config.json", a, .limited(1024 * 1024));
        defer a.free(after);
        try t.expectEqualStrings(before, after);

        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        try manager.loginOffline(&store, "Alex");
        try t.expectEqual(@as(usize, 2), store.snapshot().accounts.len);
        try t.expectEqualStrings("Alex", (try manager.launchIdentity(0)).username);
        try t.expectEqualStrings(&(try accounts.offlineUuid("Alex")), (try manager.launchIdentity(0)).uuid);
        try t.expectEqualStrings(store.snapshot().accounts[1].id, store.snapshot().selected_account.?);
    }
}

test "accounts selection allocation failure rejects stale offline identity and recovers on next tick" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    var failing = std.testing.FailingAllocator.init(a, .{});
    var fake: Fake = .{};
    var manager = try accounts.Manager.initWithOptions(failing.allocator(), io, .{ .root = root, .fixture = fake.fixture() });
    defer manager.deinit();
    try manager.addOffline(&store, "Steve");
    const steve_id = try a.dupe(u8, store.snapshot().accounts[0].id);
    defer a.free(steve_id);
    try manager.select(&store, steve_id);
    try manager.addOffline(&store, "Alex");
    const alex_id = try a.dupe(u8, store.snapshot().accounts[1].id);
    defer a.free(alex_id);
    try t.expectEqualStrings("Steve", (try manager.launchIdentity(0)).username);
    var doc = store.snapshot().*;
    doc.selected_account = alex_id;
    try store.update(doc);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    manager.tick(&store);
    try t.expect(failing.has_induced_failure);
    try t.expect(!manager.canLaunch(0));
    try t.expectError(error.NoAccountSelected, manager.launchIdentity(0));
    try t.expectEqual(@as(anyerror, error.OutOfMemory), manager.snapshot().failure.?);
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    manager.tick(&store);
    try t.expect(manager.canLaunch(0));
    try t.expectEqualStrings("Alex", (try manager.launchIdentity(0)).username);
    try t.expectEqualStrings(alex_id, (try manager.launchIdentity(0)).id);
    try t.expectEqual(@as(usize, 0), fake.requests + fake.gets + fake.puts + fake.deletes + fake.stages + fake.removes + fake.entropy_calls + fake.reference_calls);
}

test "accounts postcommit selection allocation failure cancels safely and acknowledges on publication retry" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    try configure(&store);
    var failing = std.testing.FailingAllocator.init(a, .{});
    var fake: Fake = .{};
    var manager = try accounts.Manager.initWithOptions(failing.allocator(), io, .{ .root = root, .fixture = fake.fixture() });
    defer manager.deinit();
    try manager.addOffline(&store, "Steve");
    try manager.select(&store, store.snapshot().accounts[0].id);
    try t.expectEqualStrings("Steve", (try manager.launchIdentity(0)).username);
    try manager.startDeviceRemember(&store, true);
    // The publication account-list allocation succeeds; the next selected-metadata clone fails.
    failing.fail_index = failing.alloc_index + 1;
    failing.resize_fail_index = failing.resize_index;
    try settle(&manager, &store);
    try t.expect(failing.has_induced_failure);
    try t.expect(manager.snapshot().publication_pending);
    try t.expectEqual(@as(anyerror, error.OutOfMemory), manager.snapshot().failure.?);
    try t.expectEqual(@as(usize, 2), store.snapshot().accounts.len);
    try t.expectEqual(config.AccountKind.microsoft, store.snapshot().accounts[1].kind);
    try t.expect(credentials.validateReference(store.snapshot().accounts[1].credential_ref.?));
    try t.expectEqualStrings(store.snapshot().accounts[1].id, store.snapshot().selected_account.?);
    try t.expectEqual(@as(usize, 1), fake.puts);
    try t.expectEqual(@as(usize, 1), fake.refs_len);
    try t.expect(!manager.canLaunch(clockMs()));
    try t.expectError(error.Busy, manager.launchIdentity(clockMs()));
    manager.cancel();
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try settle(&manager, &store);
    try manager.retryPublication(&store);
    try settle(&manager, &store);
    try t.expect(!manager.snapshot().publication_pending);
    try t.expectEqual(@as(usize, 0), fake.refs_len);
    try t.expectEqual(@as(usize, 1), fake.puts);
    try t.expectEqual(@as(usize, 0), fake.deletes);
    try t.expect(credentials.validateReference(store.snapshot().accounts[1].credential_ref.?));
    try t.expectEqualStrings(store.snapshot().accounts[1].id, store.snapshot().selected_account.?);
    try t.expect(!manager.canLaunch(clockMs()));
    try t.expectError(error.LoginRequired, manager.launchIdentity(clockMs()));
    try expectWorkerOnly(&fake);
    try expectNoPlaintext(&tmp);
}

test "accounts uncertain config blocks new work and cleanup recovers latest protected disk references" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    try configure(&store);
    var fake: Fake = .{};
    fake.preload();
    fake.refs[0] = saved_ref;
    fake.refs[1] = orphan_ref;
    fake.refs_len = 2;
    var manager = try accounts.Manager.initWithOptions(a, io, .{ .root = root, .fixture = fake.fixture() });
    defer manager.deinit();
    try tmp.dir.rename(".vela/config.json", tmp.dir, ".vela/previous.json", io);
    try tmp.dir.createDir(io, ".vela/config.json", .default_dir);
    if (store.update(store.snapshot().*)) |_| return error.ExpectedWriteFailure else |_| {}
    try t.expect(store.publicationUncertain());
    try t.expectError(error.ConfigPublicationUncertain, manager.startDeviceRemember(&store, true));
    try t.expectEqual(@as(usize, 0), fake.requests);
    try t.expectEqual(@as(usize, 0), fake.puts);
    try t.expectEqual(@as(usize, 0), fake.gets);
    try t.expectEqual(@as(usize, 0), fake.deletes);
    try t.expectEqual(@as(usize, 0), fake.stages);
    try t.expectEqual(@as(usize, 0), fake.reference_calls);
    try tmp.dir.deleteDir(io, ".vela/config.json");
    try t.expectError(error.FileNotFound, manager.retryCleanup(&store));
    try t.expect(store.publicationUncertain());
    try t.expectEqual(@as(usize, 0), fake.reference_calls);
    try t.expectEqual(@as(usize, 0), fake.deletes);
    try tmp.dir.rename(".vela/previous.json", tmp.dir, ".vela/config.json", io);
    // A second writer is excluded; recovery still reloads valid disk evidence.
    try t.expectError(error.LauncherRootInUse, config.Store.init(a, io, root));
    const recovered_bytes = try config.serialize(a, .{ .settings = .{ .microsoft_client_id = "fixture-public-client" }, .accounts = &.{.{ .id = "saved-online", .name = "FixturePlayer", .uuid = "00112233445566778899aabbccddeeff", .kind = .microsoft, .credential_ref = &saved_ref }}, .selected_account = "saved-online" });
    defer a.free(recovered_bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = ".vela/config.json", .data = recovered_bytes });
    try t.expectEqual(@as(usize, 0), store.snapshot().accounts.len);
    try manager.retryCleanup(&store);
    try settle(&manager, &store);
    try t.expect(!store.publicationUncertain());
    try t.expectEqualStrings(&saved_ref, store.snapshot().accounts[0].credential_ref.?);
    try t.expectEqual(@as(usize, 1), fake.deletes);
    try t.expectEqual(@as(usize, 1), fake.refs_len);
    try t.expectEqualStrings(&saved_ref, &fake.refs[0]);
    try t.expect(fake.secret_len > 0);
    try t.expectEqual(@as(usize, 0), fake.puts);
    try t.expectEqual(@as(usize, 0), fake.gets);
    try t.expectEqual(@as(usize, 0), fake.requests);
    try expectWorkerOnly(&fake);
    try expectNoPlaintext(&tmp);
}

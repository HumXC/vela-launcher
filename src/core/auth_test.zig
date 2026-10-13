//! Entirely in-memory fixtures. No networking, native vault access, or files.
const std = @import("std");
const auth = @import("auth.zig");
const credentials = @import("credentials.zig");
const testing = std.testing;
const Step = struct { method: auth.Method = .post, suffix: []const u8, body: []const u8, status: u16 = 200, request_contains: ?[]const u8 = null };
const device_json = "{\"device_code\":\"fixture-device-secret\",\"user_code\":\"FIXTURE-CODE\",\"verification_uri\":\"https://www.microsoft.com/link\",\"expires_in\":900,\"interval\":5}";
const oauth_json = "{\"access_token\":\"fixture-msa-secret\",\"refresh_token\":\"fixture-refresh-secret\",\"expires_in\":3600,\"token_type\":\"Bearer\"}";
const xbl_json = "{\"Token\":\"fixture-xbl-secret\",\"DisplayClaims\":{\"xui\":[{\"uhs\":\"123456789\"}]}}";
const xsts_json = "{\"Token\":\"fixture-xsts-secret\",\"DisplayClaims\":{\"xui\":[{\"uhs\":\"123456789\"}]}}";
const mc_json = "{\"access_token\":\"fixture-minecraft-secret\",\"expires_in\":3600}";
const entitlement_json = "{\"items\":[{\"name\":\"game_minecraft\"}]}";
const profile_json = "{\"id\":\"00112233445566778899aabbccddeeff\",\"name\":\"FixturePlayer\"}";
const happy = [_]Step{
    .{ .suffix = "/devicecode", .body = device_json, .request_contains = "scope=XboxLive.signin%20offline_access" },
    .{ .suffix = "/token", .body = oauth_json, .request_contains = "device_code=fixture-device-secret" },
    .{ .suffix = "/user/authenticate", .body = xbl_json, .request_contains = "d=fixture-msa-secret" },
    .{ .suffix = "/xsts/authorize", .body = xsts_json, .request_contains = "fixture-xbl-secret" },
    .{ .suffix = "/login_with_xbox", .body = mc_json, .request_contains = "XBL3.0 x=123456789;fixture-xsts-secret" },
    .{ .method = .get, .suffix = "/entitlements/mcstore", .body = entitlement_json },
    .{ .method = .get, .suffix = "/minecraft/profile", .body = profile_json },
};
const Fixture = struct {
    steps: []const Step,
    index: usize = 0,
    fail_at: ?usize = null,
    failure: auth.TransportError = error.Timeout,
    cancel_at: ?usize = null,
    cancel: ?*auth.CancelToken = null,
    oversized_at: ?usize = null,
    fn transport(self: *Fixture) auth.Transport {
        return .{ .ctx = self, .kind = .fixture, .supports_post = true, .request = request };
    }
    fn request(ctx: *anyopaque, a: std.mem.Allocator, req: auth.Request) auth.TransportError!auth.Response {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        const index = self.index;
        self.index += 1;
        if (self.fail_at == index) return self.failure;
        if (self.cancel_at == index) if (self.cancel) |token| token.cancel();
        if (self.oversized_at == index) return .{ .status = 200, .body = try a.alloc(u8, auth.max_response_bytes + 1) };
        if (index >= self.steps.len) return error.TransportFailure;
        const step = self.steps[index];
        if (req.method != step.method or !std.mem.endsWith(u8, req.url, step.suffix) or
            !std.mem.startsWith(u8, req.url, "https://") or req.timeout_ms == 0 or
            req.max_response_bytes != auth.max_response_bytes or req.body.len > auth.max_request_bytes or req.deadline_ms == 0)
            return error.TransportFailure;
        if (step.request_contains) |needle| if (std.mem.indexOf(u8, req.body, needle) == null) return error.TransportFailure;
        if (step.method == .get) {
            var bearer_valid = false;
            for (req.headers) |header| if (std.mem.eql(u8, header.name, "Authorization") and std.mem.eql(u8, header.value, "Bearer fixture-minecraft-secret")) {
                bearer_valid = true;
            };
            if (!bearer_valid) return error.TransportFailure;
        } else {
            var json_body = false;
            for (req.headers) |header| if (std.mem.eql(u8, header.name, "Content-Type") and std.mem.eql(u8, header.value, "application/json")) {
                json_body = true;
            };
            if (json_body) {
                const parsed = std.json.parseFromSlice(std.json.Value, a, req.body, .{}) catch return error.TransportFailure;
                if (parsed.value != .object) return error.TransportFailure;
            }
        }
        return .{ .status = step.status, .body = try a.dupe(u8, step.body) };
    }
};
const Vault = struct {
    bytes: [512]u8 = @splat(0),
    ref: credentials.Reference = @splat('a'),
    len: usize = 0,
    puts: usize = 0,
    deletes: usize = 0,
    fail_put: bool = false,
    fail_after_commit: bool = false,
    cancel_on_put: ?*auth.CancelToken = null,
    fail_delete: bool = false,
    unavailable: bool = false,
    const vtable: credentials.Store.VTable = .{ .put = put, .get = get, .delete = delete };
    fn store(self: *Vault) credentials.Store {
        return .{ .ctx = self, .vtable = &vtable };
    }
    fn put(ctx: *anyopaque, ref: []const u8, secret: []const u8) credentials.Error!void {
        const self: *Vault = @ptrCast(@alignCast(ctx));
        self.puts += 1;
        if (self.unavailable) return error.Unavailable;
        if (self.fail_put) return error.StorageFailure;
        if (secret.len > self.bytes.len) return error.TooLarge;
        @memset(&self.bytes, 0);
        @memcpy(self.bytes[0..secret.len], secret);
        @memcpy(&self.ref, ref);
        self.len = secret.len;
        if (self.cancel_on_put) |cancel| cancel.cancel();
        if (self.fail_after_commit) return error.StorageFailure;
    }
    fn get(ctx: *anyopaque, a: std.mem.Allocator, ref: []const u8) credentials.Error!credentials.Secret {
        const self: *Vault = @ptrCast(@alignCast(ctx));
        if (self.unavailable) return error.Unavailable;
        if (self.len == 0 or !std.mem.eql(u8, ref, &self.ref)) return error.NotFound;
        return .{ .allocator = a, .bytes = try a.dupe(u8, self.bytes[0..self.len]) };
    }
    fn delete(ctx: *anyopaque, ref: []const u8) credentials.Error!void {
        const self: *Vault = @ptrCast(@alignCast(ctx));
        self.deletes += 1;
        if (self.fail_delete) return error.StorageFailure;
        if (self.unavailable) return error.Unavailable;
        if (!std.mem.eql(u8, ref, &self.ref)) return error.NotFound;
        std.crypto.secureZero(u8, &self.bytes);
        self.len = 0;
    }
    fn deinit(self: *Vault) void {
        std.crypto.secureZero(u8, &self.bytes);
    }
};
fn entropy(ctx: *anyopaque, bytes: []u8) error{EntropyUnavailable}!void {
    _ = ctx;
    @memset(bytes, 0xab);
}
fn client(fixture: *Fixture, vault: ?*Vault, persist: bool) !auth.Client {
    return auth.Client.init(testing.allocator, .{ .enabled = true, .client_id = "fixture-public-client", .persist_refresh = persist }, fixture.transport(), if (vault) |v| v.store() else null, .{ .ctx = fixture, .fill = entropy });
}
fn login(c: *auth.Client) !void {
    _ = try c.beginDevice(1000, null);
    try testing.expectEqual(auth.Poll.complete, try c.poll(6000, null));
}

test "fixture official chain persists only refresh, publishes metadata, signs out" {
    var fixture: Fixture = .{ .steps = &happy };
    var vault: Vault = .{};
    defer vault.deinit();
    var c = try client(&fixture, &vault, true);
    defer c.deinit();
    try login(&c);
    try testing.expectEqual(@as(usize, 7), fixture.index);
    try testing.expectEqualStrings("FixturePlayer", c.account.?.name);
    try testing.expectEqualStrings("fixture-minecraft-secret", try c.accessToken(6001));
    try testing.expectEqualStrings("fixture-refresh-secret", vault.bytes[0..vault.len]);
    try testing.expectEqualStrings("abababababababababababababababab", &c.account.?.credential_ref.?);
    const serialized = try std.json.Stringify.valueAlloc(testing.allocator, c.account.?, .{});
    defer testing.allocator.free(serialized);
    try testing.expect(std.mem.indexOf(u8, serialized, "secret") == null);
    try testing.expectError(error.AuthorizationExpired, c.accessToken(3_606_000));
    try c.signOut(null);
    try testing.expectEqual(auth.State.signed_out, c.state);
    try testing.expect(c.account == null and c.minecraft_token == null and c.refresh_token == null and c.device == null);
    try testing.expectEqual(@as(usize, 0), vault.len);
}

test "disabled unconfigured production and unsupported gates never request" {
    var fixture: Fixture = .{ .steps = &.{} };
    var c = try auth.Client.init(testing.allocator, .{}, fixture.transport(), null, null);
    defer c.deinit();
    try testing.expectError(error.Disabled, c.beginDevice(0, null));
    c.options.enabled = true;
    try testing.expectError(error.Unconfigured, c.beginDevice(0, null));
    c.options.client_id = "fixture-client";
    c.transport.kind = .production;
    try testing.expectError(error.ProductionDisabled, c.beginDevice(0, null));
    c.transport.kind = .fixture;
    c.transport.supports_post = false;
    try testing.expectError(error.UnsupportedTransport, c.beginDevice(0, null));
    try testing.expectEqual(@as(usize, 0), fixture.index);
}

test "poll respects interval pending slow_down and device expiry" {
    const steps = [_]Step{ happy[0], .{ .suffix = "/token", .body = "{\"error\":\"authorization_pending\"}", .status = 400 }, .{ .suffix = "/token", .body = "{\"error\":\"slow_down\"}", .status = 400 } };
    var fixture: Fixture = .{ .steps = &steps };
    var c = try client(&fixture, null, false);
    defer c.deinit();
    _ = try c.beginDevice(1000, null);
    try testing.expectEqual(auth.Poll.pending, try c.poll(5999, null));
    try testing.expectEqual(@as(usize, 1), fixture.index);
    try testing.expectEqual(auth.Poll.pending, try c.poll(6000, null));
    try testing.expectEqual(@as(u64, 11000), c.deviceView().?.next_poll_ms);
    try testing.expectEqual(auth.Poll.slow_down, try c.poll(11000, null));
    try testing.expectEqual(@as(u64, 21000), c.deviceView().?.next_poll_ms);
    try testing.expectError(error.AuthorizationExpired, c.poll(901000, null));
    try testing.expect(c.device == null and c.account == null);
}

test "OAuth errors are fixed codes not server descriptions" {
    const cases = [_]struct { code: []const u8, expected: auth.Error }{
        .{ .code = "access_denied", .expected = error.AuthorizationDenied },
        .{ .code = "expired_token", .expected = error.AuthorizationExpired },
        .{ .code = "invalid_grant", .expected = error.RefreshRejected },
        .{ .code = "unknown_fixture_secret", .expected = error.HttpFailure },
    };
    for (cases) |case| {
        const body = try std.json.Stringify.valueAlloc(testing.allocator, .{ .@"error" = case.code, .error_description = "fixture-sensitive-description" }, .{});
        defer testing.allocator.free(body);
        const steps = [_]Step{ happy[0], .{ .suffix = "/token", .body = body, .status = 400 } };
        var fixture: Fixture = .{ .steps = &steps };
        var c = try client(&fixture, null, false);
        defer c.deinit();
        _ = try c.beginDevice(1000, null);
        try testing.expectError(case.expected, c.poll(6000, null));
        try testing.expect(c.device == null and c.account == null);
    }
}

test "XSTS error and user hash mismatch reject publication" {
    var steps = happy;
    steps[3] = .{ .suffix = "/xsts/authorize", .status = 401, .body = "{\"XErr\":2148916233,\"Message\":\"fixture-sensitive\"}" };
    var fixture: Fixture = .{ .steps = &steps };
    var c = try client(&fixture, null, false);
    defer c.deinit();
    _ = try c.beginDevice(1000, null);
    try testing.expectError(error.XboxAccountRequired, c.poll(6000, null));
    steps[3].status = 200;
    steps[3].body = "{\"Token\":\"fixture-xsts-secret\",\"DisplayClaims\":{\"xui\":[{\"uhs\":\"987654321\"}]}}";
    fixture.index = 0;
    c.reset();
    _ = try c.beginDevice(1000, null);
    try testing.expectError(error.MalformedResponse, c.poll(6000, null));
}

test "entitlement denied and missing profile never store credentials" {
    var steps = happy;
    steps[5].body = "{\"items\":[]}";
    var fixture: Fixture = .{ .steps = &steps };
    var vault: Vault = .{};
    defer vault.deinit();
    var c = try client(&fixture, &vault, true);
    defer c.deinit();
    _ = try c.beginDevice(1000, null);
    try testing.expectError(error.EntitlementDenied, c.poll(6000, null));
    try testing.expectEqual(@as(usize, 6), fixture.index);
    try testing.expectEqual(@as(usize, 0), vault.puts);
    steps[5] = happy[5];
    steps[6].status = 404;
    fixture.index = 0;
    c.reset();
    _ = try c.beginDevice(1000, null);
    try testing.expectError(error.ProfileMissing, c.poll(6000, null));
    try testing.expectEqual(@as(usize, 0), vault.puts);
}

test "timeout transport failure pre and post request cancellation" {
    for ([_]auth.TransportError{ error.Timeout, error.TransportFailure, error.Cancelled, error.BodyTooLarge, error.UnsupportedTransport }) |failure| {
        var fixture: Fixture = .{ .steps = &happy, .fail_at = 2, .failure = failure };
        var c = try client(&fixture, null, false);
        defer c.deinit();
        _ = try c.beginDevice(1000, null);
        try testing.expectError(failure, c.poll(6000, null));
        try testing.expect(c.device == null and c.account == null);
    }
    var token: auth.CancelToken = .{};
    var fixture: Fixture = .{ .steps = &happy, .cancel = &token };
    var c = try client(&fixture, null, false);
    defer c.deinit();
    token.cancel();
    try testing.expectError(error.Cancelled, c.beginDevice(1000, &token));
    try testing.expectEqual(@as(usize, 0), fixture.index);
    token.value.store(false, .release);
    _ = try c.beginDevice(1000, &token);
    fixture.cancel_at = 5;
    try testing.expectError(error.Cancelled, c.poll(6000, &token));
    try testing.expect(c.account == null and c.device == null);
}

test "persistence failure and unavailable store fail closed without plaintext fallback" {
    var fixture: Fixture = .{ .steps = &happy };
    var vault: Vault = .{ .fail_put = true };
    defer vault.deinit();
    var c = try client(&fixture, &vault, true);
    defer c.deinit();
    _ = try c.beginDevice(1000, null);
    try testing.expectError(error.CredentialPersistenceFailed, c.poll(6000, null));
    try testing.expect(c.account == null and c.minecraft_token == null and c.refresh_token == null);
    try testing.expectEqual(@as(usize, 0), vault.len);
    try testing.expect(c.pending_cleanup_ref != null);
    try testing.expectError(error.CredentialCleanupRequired, c.beginDevice(7000, null));
    vault.fail_delete = true;
    try testing.expectError(error.CredentialPersistenceFailed, c.retryCleanup(null));
    try testing.expect(c.pending_cleanup_ref != null);
    vault.fail_delete = false;
    try c.retryCleanup(null);
    try testing.expect(c.pending_cleanup_ref == null);
    vault.fail_put = false;
    vault.unavailable = true;
    fixture.index = 0;
    c.reset();
    _ = try c.beginDevice(1000, null);
    try testing.expectError(error.CredentialStoreUnavailable, c.poll(6000, null));
    try testing.expect(c.account == null);
    vault.unavailable = false;
    try c.retryCleanup(null);
    c.store = null;
    fixture.index = 0;
    c.reset();
    _ = try c.beginDevice(1000, null);
    try testing.expectError(error.CredentialStoreUnavailable, c.poll(6000, null));
}

test "session-only secrets are transient reset has no vault effect" {
    var fixture: Fixture = .{ .steps = &happy };
    var vault: Vault = .{};
    defer vault.deinit();
    var c = try client(&fixture, &vault, false);
    defer c.deinit();
    try login(&c);
    try testing.expect(c.account.?.credential_ref == null);
    try testing.expectEqual(@as(usize, 0), vault.puts);
    c.reset();
    try testing.expect(c.account == null and c.refresh_token == null and c.minecraft_token == null and c.device == null);
    try testing.expectEqual(@as(usize, 0), vault.deletes);
    try testing.expectError(error.InvalidState, c.accessToken(6000));
}

test "secure refresh rotation retains reference and failure preserves session" {
    var fixture: Fixture = .{ .steps = &happy };
    var vault: Vault = .{};
    defer vault.deinit();
    var c = try client(&fixture, &vault, true);
    defer c.deinit();
    try login(&c);
    const ref = c.account.?.credential_ref.?;
    var refresh_steps: [6]Step = happy[1..].*;
    refresh_steps[0].request_contains = "grant_type=refresh_token&refresh_token=fixture-refresh-secret";
    refresh_steps[0].body = "{\"access_token\":\"fixture-msa-secret\",\"refresh_token\":\"fixture-rotated-secret\",\"expires_in\":3600}";
    fixture.steps = &refresh_steps;
    fixture.index = 0;
    try c.refresh(&ref, 7000, null);
    try testing.expectEqualStrings(&ref, &c.account.?.credential_ref.?);
    try testing.expectEqualStrings("fixture-rotated-secret", vault.bytes[0..vault.len]);
    try testing.expectEqual(@as(usize, 2), vault.puts);
    refresh_steps[0].request_contains = null;
    vault.fail_put = true;
    fixture.index = 0;
    try testing.expectError(error.CredentialPersistenceFailed, c.refresh(&ref, 8000, null));
    try testing.expectEqual(auth.State.authenticated, c.state);
    try testing.expectEqualStrings("fixture-minecraft-secret", try c.accessToken(8001));
    try testing.expectEqualStrings("fixture-rotated-secret", vault.bytes[0..vault.len]);
    vault.fail_put = false;
    vault.fail_after_commit = true;
    refresh_steps[0].body = "{\"access_token\":\"fixture-msa-secret\",\"refresh_token\":\"fixture-committed-rotation\",\"expires_in\":3600}";
    fixture.index = 0;
    try testing.expectError(error.CredentialPersistenceFailed, c.refresh(&ref, 9000, null));
    try testing.expectEqualStrings("fixture-committed-rotation", vault.bytes[0..vault.len]);
    try testing.expectEqualStrings("fixture-rotated-secret", c.refresh_token.?.bytes);
    try testing.expect(c.pending_cleanup_ref == null);
    try testing.expectEqual(@as(usize, 0), vault.deletes);
    try testing.expectEqualStrings(&ref, &c.account.?.credential_ref.?);
}

test "refresh may retain old token and rejects revoked token" {
    var fixture: Fixture = .{ .steps = &happy };
    var vault: Vault = .{};
    defer vault.deinit();
    var c = try client(&fixture, &vault, true);
    defer c.deinit();
    try login(&c);
    const ref = c.account.?.credential_ref.?;
    var refresh_steps: [6]Step = happy[1..].*;
    refresh_steps[0].request_contains = null;
    refresh_steps[0].body = "{\"access_token\":\"fixture-msa-secret\",\"expires_in\":3600}";
    fixture.steps = &refresh_steps;
    fixture.index = 0;
    try c.refresh(&ref, 7000, null);
    try testing.expectEqualStrings("fixture-refresh-secret", vault.bytes[0..vault.len]);
    refresh_steps[0].status = 400;
    refresh_steps[0].body = "{\"error\":\"invalid_grant\"}";
    fixture.index = 0;
    try testing.expectError(error.RefreshRejected, c.refresh(&ref, 8000, null));
    try testing.expectEqual(auth.State.authenticated, c.state);
    try testing.expectError(error.CredentialNotFound, c.refresh("not-an-opaque-ref", 9000, null));
}

test "session-only refresh and signout deletion failure clear local secrets" {
    var fixture: Fixture = .{ .steps = &happy };
    var vault: Vault = .{};
    defer vault.deinit();
    var c = try client(&fixture, &vault, false);
    defer c.deinit();
    try login(&c);
    var refresh_steps: [6]Step = happy[1..].*;
    refresh_steps[0].request_contains = "refresh_token=fixture-refresh-secret";
    fixture.steps = &refresh_steps;
    fixture.index = 0;
    try c.refreshSession(7000, null);
    try testing.expectEqual(@as(usize, 0), vault.puts);
    vault.fail_delete = true;
    try testing.expectError(error.CredentialPersistenceFailed, c.signOut(&vault.ref));
    try testing.expect(c.minecraft_token == null and c.refresh_token == null and c.account == null);
}

test "response bounds deep JSON duplicate fields invalid link and malformed tokens" {
    const bad = [_][]const u8{
        "not-json-fixture",                                                                                                                   "{\"device_code\":\"fixture\",\"device_code\":\"duplicate\"}",
        "{\"device_code\":\"fixture\",\"user_code\":\"fixture\",\"verification_uri\":\"https://malicious.invalid/link\",\"expires_in\":900}", "{\"device_code\":\"fixture\",\"user_code\":\"fixture\",\"verification_uri\":\"https://www.microsoft.com/link\",\"expires_in\":-1}",
    };
    for (bad) |body| {
        const steps = [_]Step{.{ .suffix = "/devicecode", .body = body }};
        var fixture: Fixture = .{ .steps = &steps };
        var c = try client(&fixture, null, false);
        defer c.deinit();
        try testing.expectError(error.MalformedResponse, c.beginDevice(1000, null));
        try testing.expect(c.device == null);
    }
    var deep: [80]u8 = undefined;
    @memset(deep[0..40], '[');
    @memset(deep[40..], ']');
    const steps = [_]Step{.{ .suffix = "/devicecode", .body = &deep }};
    var fixture: Fixture = .{ .steps = &steps };
    var c = try client(&fixture, null, false);
    defer c.deinit();
    try testing.expectError(error.ResourceLimit, c.beginDevice(1000, null));
    fixture.index = 0;
    fixture.oversized_at = 0;
    try testing.expectError(error.BodyTooLarge, c.beginDevice(1000, null));
}

test "monotonic clock and invalid timeout options" {
    var fixture: Fixture = .{ .steps = &happy };
    var c = try client(&fixture, null, false);
    defer c.deinit();
    _ = try c.beginDevice(1000, null);
    try testing.expectError(error.ClockWentBackwards, c.poll(999, null));
    try testing.expectError(error.InvalidOptions, auth.Client.init(testing.allocator, .{ .request_timeout_ms = 0 }, fixture.transport(), null, null));
}

fn unavailableEntropy(_: *anyopaque, _: []u8) error{EntropyUnavailable}!void {
    return error.EntropyUnavailable;
}

test "unavailable entropy never publishes or persists secrets" {
    for ([_]bool{ false, true }) |injected| {
        var fixture: Fixture = .{ .steps = &happy };
        var vault: Vault = .{};
        defer vault.deinit();
        var c = try client(&fixture, &vault, true);
        defer c.deinit();
        c.entropy = if (injected) .{ .ctx = &fixture, .fill = unavailableEntropy } else null;
        _ = try c.beginDevice(1000, null);
        try testing.expectError(error.EntropyUnavailable, c.poll(6000, null));
        try testing.expect(c.account == null and c.refresh_token == null and c.minecraft_token == null);
        try testing.expectEqual(@as(usize, 0), vault.puts);
    }
}

test "cancelled poll outside device flow does not invalidate authenticated state" {
    var fixture: Fixture = .{ .steps = &happy };
    var c = try client(&fixture, null, false);
    defer c.deinit();
    try login(&c);
    var cancel: auth.CancelToken = .{};
    cancel.cancel();
    try testing.expectError(error.InvalidState, c.poll(7000, &cancel));
    try testing.expectEqual(auth.State.authenticated, c.state);
    try testing.expectEqualStrings("fixture-minecraft-secret", try c.accessToken(7000));
}

test "structured escaped sensitive values cannot inject headers" {
    var steps = happy;
    steps[4].body = "{\"access_token\":\"fixture\\tsecret\",\"expires_in\":3600}";
    var fixture: Fixture = .{ .steps = &steps };
    var c = try client(&fixture, null, false);
    defer c.deinit();
    _ = try c.beginDevice(1000, null);
    try testing.expectError(error.MalformedResponse, c.poll(6000, null));
    try testing.expectEqual(@as(usize, 5), fixture.index);
    try testing.expectError(error.InvalidOptions, auth.Client.init(testing.allocator, .{ .client_id = "fixture\tclient" }, fixture.transport(), null, null));
}

const WipeObserver = struct {
    scratch_frees: usize = 0,
    secret_frees: usize = 0,
    violation: bool = false,
    fn allocator(self: *WipeObserver) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(_: *anyopaque, length: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        return testing.allocator.rawAlloc(length, alignment, address);
    }
    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *WipeObserver = @ptrCast(@alignCast(ctx));
        if (bytes.len == 2 * 1024 * 1024) {
            self.scratch_frees += 1;
            if (!std.mem.allEqual(u8, bytes, 0)) self.violation = true;
        } else if (bytes.len == "fixture-device-secret".len or bytes.len == "fixture-refresh-secret".len or bytes.len == "fixture-minecraft-secret".len or bytes.len == "FIXTURE-CODE".len) {
            self.secret_frees += 1;
            if (!std.mem.allEqual(u8, bytes, 0)) self.violation = true;
        }
        testing.allocator.rawFree(bytes, alignment, address);
    }
};

test "operation scratch tokens and device code are wiped before allocator free" {
    var observer: WipeObserver = .{};
    var fixture: Fixture = .{ .steps = &happy };
    var c = try auth.Client.init(observer.allocator(), .{ .enabled = true, .client_id = "fixture-client", .persist_refresh = false }, fixture.transport(), null, null);
    errdefer c.deinit();
    try login(&c);
    c.reset();
    try testing.expectEqual(@as(usize, 2), observer.scratch_frees);
    try testing.expectEqual(@as(usize, 4), observer.secret_frees);
    try testing.expect(!observer.violation);
}

const DeleteObserver = struct {
    client: *auth.Client,
    observed_cleared: bool = false,
    fn put(_: *anyopaque, _: []const u8, _: []const u8) credentials.Error!void {
        return error.Unavailable;
    }
    fn get(_: *anyopaque, _: std.mem.Allocator, _: []const u8) credentials.Error!credentials.Secret {
        return error.Unavailable;
    }
    fn delete(ctx: *anyopaque, _: []const u8) credentials.Error!void {
        const self: *DeleteObserver = @ptrCast(@alignCast(ctx));
        self.observed_cleared = self.client.state == .signed_out and self.client.minecraft_token == null and self.client.refresh_token == null and self.client.account == null;
        return error.StorageFailure;
    }
};

test "signout is locally complete before secure-store delete is entered" {
    var fixture: Fixture = .{ .steps = &happy };
    var c = try client(&fixture, null, false);
    defer c.deinit();
    try login(&c);
    var observer: DeleteObserver = .{ .client = &c };
    c.store = .{ .ctx = &observer, .vtable = &.{ .put = DeleteObserver.put, .get = DeleteObserver.get, .delete = DeleteObserver.delete } };
    const ref: [32]u8 = @splat('a');
    try testing.expectError(error.CredentialPersistenceFailed, c.signOut(&ref));
    try testing.expect(observer.observed_cleared);
}

test "commit ambiguous write exposes only opaque cleanup debt and retry deletes it" {
    var fixture: Fixture = .{ .steps = &happy };
    var vault: Vault = .{ .fail_after_commit = true };
    defer vault.deinit();
    var c = try client(&fixture, &vault, true);
    defer c.deinit();
    _ = try c.beginDevice(1000, null);
    try testing.expectError(error.CredentialPersistenceFailed, c.poll(6000, null));
    try testing.expect(c.account == null and c.refresh_token == null and c.minecraft_token == null);
    try testing.expect(vault.len > 0);
    const ref = c.pending_cleanup_ref.?;
    c.reset();
    try testing.expectEqualStrings(&ref, &c.pending_cleanup_ref.?);
    c.options.enabled = false;
    var cancel: auth.CancelToken = .{};
    cancel.cancel();
    try testing.expectError(error.Cancelled, c.retryCleanup(&cancel));
    try testing.expect(c.pending_cleanup_ref != null);
    try c.retryCleanup(null);
    try testing.expect(c.pending_cleanup_ref == null and vault.len == 0);
}

test "late cancellation after secure write publishes committed reference" {
    var cancel: auth.CancelToken = .{};
    var fixture: Fixture = .{ .steps = &happy };
    var vault: Vault = .{ .cancel_on_put = &cancel };
    defer vault.deinit();
    var c = try client(&fixture, &vault, true);
    defer c.deinit();
    _ = try c.beginDevice(1000, &cancel);
    try testing.expectEqual(auth.Poll.complete, try c.poll(6000, &cancel));
    try testing.expect(cancel.cancelled());
    try testing.expectEqual(auth.State.authenticated, c.state);
    try testing.expect(c.account.?.credential_ref != null and c.pending_cleanup_ref == null);
    try c.signOut(null);
    try testing.expectEqual(@as(usize, 0), vault.len);
}

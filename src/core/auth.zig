//! Official device OAuth -> Xbox Live -> XSTS -> Minecraft workflow.
//! No HTTP implementation is supplied: production remains opt-in and unsupported
//! until the parent installs an adapter meeting Transport's contract. Never log
//! this module's request/response data, device codes, or accessToken() output.
const std = @import("std");
const credentials = @import("credentials.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const scratch_bytes = 2 * 1024 * 1024;
pub const max_response_bytes = 128 * 1024;
pub const max_request_bytes = 64 * 1024;
const max_token_bytes = 16 * 1024;
const scope = "XboxLive.signin offline_access";
const oauth_root = "https://login.microsoftonline.com/consumers/oauth2/v2.0/";

pub const Error = error{
    Disabled,
    Unconfigured,
    ProductionDisabled,
    UnsupportedTransport,
    InvalidOptions,
    InvalidState,
    ClockWentBackwards,
    Cancelled,
    Timeout,
    TransportFailure,
    HttpFailure,
    MalformedResponse,
    BodyTooLarge,
    ResourceLimit,
    AuthorizationDenied,
    AuthorizationExpired,
    RefreshRejected,
    XboxDenied,
    XboxAccountRequired,
    RegionRestricted,
    AgeVerificationRequired,
    ChildAccountRestricted,
    EntitlementDenied,
    ProfileMissing,
    CredentialStoreUnavailable,
    CredentialPersistenceFailed,
    CredentialCleanupRequired,
    CredentialNotFound,
    EntropyUnavailable,
    OutOfMemory,
};

pub const CancelToken = struct {
    value: std.atomic.Value(bool) = .init(false),
    pub fn cancel(self: *CancelToken) void {
        self.value.store(true, .release);
    }
    pub fn cancelled(self: *const CancelToken) bool {
        return self.value.load(.acquire);
    }
};
pub const Header = struct { name: []const u8, value: []const u8 };
pub const Method = enum { get, post };
pub const Request = struct {
    method: Method,
    url: []const u8,
    headers: []const Header,
    body: []const u8,
    max_response_bytes: usize,
    timeout_ms: u32,
    /// Absolute deadline in the same monotonic clock domain as Client arguments.
    deadline_ms: u64,
    cancel: ?*const CancelToken,
};
pub const Response = struct { status: u16, body: []u8 };
pub const TransportError = error{ UnsupportedTransport, Cancelled, Timeout, BodyTooLarge, TransportFailure, OutOfMemory };
/// Synchronous adapter borrows Request only for the call. Response.body must be
/// allocated with the supplied allocator. Enforce bounds BEFORE allocation/read;
/// HTTPS certificate verification, zero redirects, POST support, cancellation,
/// timeout_ms AND deadline_ms are mandatory. No retries, logging, or secret cache.
/// A fixture adapter must never do network I/O, even though URLs are official.
pub const Transport = struct {
    ctx: *anyopaque,
    kind: enum { fixture, production },
    supports_post: bool = false,
    request: *const fn (*anyopaque, Allocator, Request) TransportError!Response,
};
pub const Entropy = struct {
    ctx: *anyopaque,
    /// Fill all bytes with cryptographically secure randomness, or return error.
    fill: *const fn (*anyopaque, []u8) error{EntropyUnavailable}!void,
};
pub const Options = struct {
    enabled: bool = false,
    /// Borrowed public application ID, not a client secret. No borrowed IDs.
    client_id: []const u8 = "",
    allow_production: bool = false,
    persist_refresh: bool = true,
    request_timeout_ms: u32 = 15_000,
    operation_timeout_ms: u32 = 120_000,
};
pub const Gate = enum { disabled, unconfigured, production_disabled, unsupported_transport, ready };
pub const Poll = enum { pending, slow_down, complete };
pub const State = enum { signed_out, device_pending, authenticated };
/// Public metadata only; never put token-bearing Client fields in configuration.
pub const Account = struct {
    uuid: []u8,
    name: []u8,
    credential_ref: ?credentials.Reference,
};
pub const DeviceView = struct {
    user_code: []const u8,
    verification_uri: []const u8,
    expires_at_ms: u64,
    next_poll_ms: u64,
};
const Device = struct {
    code: credentials.Secret,
    user_code: []u8,
    verification_uri: []u8,
    expires_at_ms: u64,
    next_poll_ms: u64,
    interval_ms: u32,
};

/// Single-worker-owned. CancelToken alone is thread-safe. Options.client_id and
/// all injected contexts must outlive Client; views are invalidated by reset.
pub const Client = struct {
    allocator: Allocator,
    options: Options,
    transport: Transport,
    store: ?credentials.Store,
    entropy: ?Entropy,
    state: State = .signed_out,
    account: ?Account = null,
    device: ?Device = null,
    minecraft_token: ?credentials.Secret = null,
    refresh_token: ?credentials.Secret = null,
    token_expires_at_ms: u64 = 0,
    last_now_ms: ?u64 = null,
    /// Non-secret cleanup debt after a commit-ambiguous NEW-ref vault write.
    /// Parent must retain this metadata; reset intentionally does not clear it.
    pending_cleanup_ref: ?credentials.Reference = null,

    pub fn init(a: Allocator, options: Options, transport: Transport, store: ?credentials.Store, entropy: ?Entropy) Error!Client {
        if (options.client_id.len > 4096 or !safeText(options.client_id) or
            options.request_timeout_ms == 0 or options.request_timeout_ms > 120_000 or
            options.operation_timeout_ms < options.request_timeout_ms or options.operation_timeout_ms > 300_000)
            return error.InvalidOptions;
        return .{ .allocator = a, .options = options, .transport = transport, .store = store, .entropy = entropy };
    }
    pub fn gate(self: *const Client) Gate {
        if (!self.options.enabled) return .disabled;
        if (self.options.client_id.len == 0) return .unconfigured;
        if (self.transport.kind == .production and !self.options.allow_production) return .production_disabled;
        if (!self.transport.supports_post) return .unsupported_transport;
        return .ready;
    }
    fn check(self: *Client, now: u64, cancel: ?*const CancelToken) Error!void {
        switch (self.gate()) {
            .disabled => return error.Disabled,
            .unconfigured => return error.Unconfigured,
            .production_disabled => return error.ProductionDisabled,
            .unsupported_transport => return error.UnsupportedTransport,
            .ready => {},
        }
        if (self.last_now_ms) |previous| if (now < previous) return error.ClockWentBackwards;
        self.last_now_ms = now;
        try checkpoint(cancel);
    }
    fn clearDevice(self: *Client) void {
        if (self.device) |*device| {
            device.code.deinit();
            wipeFree(self.allocator, device.user_code);
            self.allocator.free(device.verification_uri);
        }
        self.device = null;
    }
    /// Memory-only reset. It never touches a vault or filesystem. A caller must
    /// retain its config credential_ref for refresh or use signOut to delete it.
    pub fn reset(self: *Client) void {
        self.clearDevice();
        if (self.minecraft_token) |*secret| secret.deinit();
        if (self.refresh_token) |*secret| secret.deinit();
        self.minecraft_token = null;
        self.refresh_token = null;
        if (self.account) |account| {
            self.allocator.free(account.uuid);
            self.allocator.free(account.name);
        }
        self.account = null;
        self.token_expires_at_ms = 0;
        self.state = .signed_out;
        self.last_now_ms = null;
    }
    pub fn deinit(self: *Client) void {
        self.reset();
    }
    pub fn deviceView(self: *const Client) ?DeviceView {
        const device = self.device orelse return null;
        return .{ .user_code = device.user_code, .verification_uri = device.verification_uri, .expires_at_ms = device.expires_at_ms, .next_poll_ms = device.next_poll_ms };
    }
    pub fn accessToken(self: *const Client, now_ms: u64) Error![]const u8 {
        if (self.state != .authenticated) return error.InvalidState;
        if (now_ms >= self.token_expires_at_ms) return error.AuthorizationExpired;
        return (self.minecraft_token orelse return error.InvalidState).bytes;
    }
    pub fn beginDevice(self: *Client, now_ms: u64, cancel: ?*const CancelToken) Error!DeviceView {
        if (self.options.persist_refresh and self.pending_cleanup_ref != null) return error.CredentialCleanupRequired;
        try self.check(now_ms, cancel);
        self.reset();
        self.last_now_ms = now_ms;
        const buf = try self.allocator.alloc(u8, scratch_bytes);
        defer wipeFree(self.allocator, buf);
        var fixed = std.heap.FixedBufferAllocator.init(buf);
        const a = fixed.allocator();
        const body = try form(a, &.{ .{ "client_id", self.options.client_id }, .{ "scope", scope } });
        const response = try self.fetch(a, .post, oauth_root ++ "devicecode", body, "application/x-www-form-urlencoded", null, now_ms, deadline(now_ms, self.options.operation_timeout_ms), cancel);
        try requireSuccess(response);
        const value = try parse(a, response.body);
        const code = try text(value, "device_code", max_token_bytes);
        const user_code = try text(value, "user_code", 128);
        const uri = try text(value, "verification_uri", 512);
        if (!validVerificationUri(uri)) return error.MalformedResponse;
        const expiry = try seconds(value, "expires_in", 3600);
        const interval = if (field(value, "interval")) |_| try seconds(value, "interval", 60) else 5;
        try checkpoint(cancel);
        const code_owned = try secretCopy(self.allocator, code);
        errdefer {
            var secret = code_owned;
            secret.deinit();
        }
        const user_owned = try self.allocator.dupe(u8, user_code);
        errdefer wipeFree(self.allocator, user_owned);
        const uri_owned = try self.allocator.dupe(u8, uri);
        self.device = .{ .code = code_owned, .user_code = user_owned, .verification_uri = uri_owned, .expires_at_ms = deadline(now_ms, expiry * 1000), .next_poll_ms = deadline(now_ms, interval * 1000), .interval_ms = interval * 1000 };
        self.state = .device_pending;
        return self.deviceView().?;
    }
    /// Call no earlier than next_poll_ms. Terminal failure wipes the device code;
    /// pending/slow_down retain it. Cancellation does not publish an account.
    pub fn poll(self: *Client, now_ms: u64, cancel: ?*const CancelToken) Error!Poll {
        if (self.state != .device_pending) return error.InvalidState;
        self.check(now_ms, cancel) catch |err| {
            if (err == error.Cancelled) {
                self.clearDevice();
                self.state = .signed_out;
            }
            return err;
        };
        errdefer {
            self.clearDevice();
            self.state = .signed_out;
        }
        const device = &self.device.?;
        if (now_ms >= device.expires_at_ms) return error.AuthorizationExpired;
        if (now_ms < device.next_poll_ms) return .pending;
        const buf = try self.allocator.alloc(u8, scratch_bytes);
        defer wipeFree(self.allocator, buf);
        var fixed = std.heap.FixedBufferAllocator.init(buf);
        const a = fixed.allocator();
        const body = try form(a, &.{ .{ "client_id", self.options.client_id }, .{ "grant_type", "urn:ietf:params:oauth:grant-type:device_code" }, .{ "device_code", device.code.bytes } });
        const expires_at = @min(device.expires_at_ms, deadline(now_ms, self.options.operation_timeout_ms));
        const response = try self.fetch(a, .post, oauth_root ++ "token", body, "application/x-www-form-urlencoded", null, now_ms, expires_at, cancel);
        const value = try parse(a, response.body);
        if (response.status != 200) {
            const code = text(value, "error", 128) catch return error.HttpFailure;
            if (response.status == 400 and std.mem.eql(u8, code, "authorization_pending")) {
                device.next_poll_ms = deadline(now_ms, device.interval_ms);
                return .pending;
            }
            if (response.status == 400 and std.mem.eql(u8, code, "slow_down")) {
                device.interval_ms = @min(device.interval_ms + 5000, 300_000);
                device.next_poll_ms = deadline(now_ms, device.interval_ms);
                return .slow_down;
            }
            return oauthError(code);
        }
        try self.exchange(a, value, null, now_ms, expires_at, cancel);
        self.clearDevice();
        return .complete;
    }
    /// Uses only a secure-store refresh token. Existing session remains valid on
    /// failure; persisted refresh rotation is committed before memory publication.
    pub fn refresh(self: *Client, reference: []const u8, now_ms: u64, cancel: ?*const CancelToken) Error!void {
        try self.check(now_ms, cancel);
        if (!credentials.validateReference(reference)) return error.CredentialNotFound;
        const store = self.store orelse return error.CredentialStoreUnavailable;
        var secret = store.get(self.allocator, reference) catch |err| return storeError(err, false);
        defer secret.deinit();
        try self.refreshWith(secret.bytes, reference, now_ms, cancel);
    }
    /// Explicit session-only refresh. No persistence and no credential_ref.
    pub fn refreshSession(self: *Client, now_ms: u64, cancel: ?*const CancelToken) Error!void {
        try self.check(now_ms, cancel);
        if (self.options.persist_refresh) return error.InvalidState;
        const token = self.refresh_token orelse return error.InvalidState;
        try self.refreshWith(token.bytes, null, now_ms, cancel);
    }
    fn refreshWith(self: *Client, token: []const u8, reference: ?[]const u8, now: u64, cancel: ?*const CancelToken) Error!void {
        const buf = try self.allocator.alloc(u8, scratch_bytes);
        defer wipeFree(self.allocator, buf);
        var fixed = std.heap.FixedBufferAllocator.init(buf);
        const a = fixed.allocator();
        const body = try form(a, &.{ .{ "client_id", self.options.client_id }, .{ "grant_type", "refresh_token" }, .{ "refresh_token", token }, .{ "scope", scope } });
        const expires_at = deadline(now, self.options.operation_timeout_ms);
        const response = try self.fetch(a, .post, oauth_root ++ "token", body, "application/x-www-form-urlencoded", null, now, expires_at, cancel);
        const value = try parse(a, response.body);
        if (response.status != 200) {
            const code = text(value, "error", 128) catch return error.HttpFailure;
            return oauthError(code);
        }
        // Microsoft may omit refresh_token when retaining the previous token.
        if (field(value, "refresh_token") == null) {
            if (value != .object) return error.MalformedResponse;
            var retained = value;
            retained.object.put(a, "refresh_token", .{ .string = token }) catch return error.ResourceLimit;
            try self.exchange(a, retained, reference, now, expires_at, cancel);
        } else try self.exchange(a, value, reference, now, expires_at, cancel);
    }
    /// Always clears local state, including on vault deletion failure. The caller
    /// must not discard config metadata until deletion succeeds (retry by ref).
    pub fn signOut(self: *Client, reference: ?[]const u8) Error!void {
        var selected_ref = if (self.account) |account| account.credential_ref orelse self.pending_cleanup_ref else self.pending_cleanup_ref;
        if (reference) |ref| {
            if (!credentials.validateReference(ref)) {
                self.reset();
                return error.CredentialNotFound;
            }
            var copy: credentials.Reference = undefined;
            @memcpy(&copy, ref);
            selected_ref = copy;
        }
        self.reset();
        var ref = selected_ref orelse return;
        const store = self.store orelse return error.CredentialStoreUnavailable;
        store.delete(&ref) catch |err| {
            if (err != error.NotFound) return storeError(err, true);
        };
        if (self.pending_cleanup_ref) |pending| {
            if (std.mem.eql(u8, &pending, &ref)) self.pending_cleanup_ref = null;
        }
    }
    /// Cleanup is allowed even when login is disabled/unconfigured. It may be
    /// retried after OS denial/timeouts; no account token is ever deleted here.
    pub fn retryCleanup(self: *Client, cancel: ?*const CancelToken) Error!void {
        try checkpoint(cancel);
        var ref = self.pending_cleanup_ref orelse return;
        const store = self.store orelse return error.CredentialStoreUnavailable;
        store.delete(&ref) catch |err| {
            if (err != error.NotFound) return storeError(err, true);
        };
        self.pending_cleanup_ref = null;
    }
    fn fetch(self: *Client, a: Allocator, method: Method, url: []const u8, body: []const u8, content_type: []const u8, bearer: ?[]const u8, now: u64, expires_at: u64, cancel: ?*const CancelToken) Error!Response {
        try checkpoint(cancel);
        if (body.len > max_request_bytes) return error.BodyTooLarge;
        if (now >= expires_at) return error.Timeout;
        var headers: [3]Header = undefined;
        headers[0] = .{ .name = "Accept", .value = "application/json" };
        headers[1] = .{ .name = "Content-Type", .value = content_type };
        var count: usize = 2;
        if (bearer) |token| {
            headers[2] = .{ .name = "Authorization", .value = std.fmt.allocPrint(a, "Bearer {s}", .{token}) catch return error.ResourceLimit };
            count = 3;
        }
        const response = self.transport.request(self.transport.ctx, a, .{ .method = method, .url = url, .headers = headers[0..count], .body = body, .max_response_bytes = max_response_bytes, .timeout_ms = @intCast(@min(self.options.request_timeout_ms, expires_at - now)), .deadline_ms = expires_at, .cancel = cancel }) catch |err| return switch (err) {
            error.UnsupportedTransport => error.UnsupportedTransport,
            error.Cancelled => error.Cancelled,
            error.Timeout => error.Timeout,
            error.BodyTooLarge => error.BodyTooLarge,
            error.TransportFailure => error.TransportFailure,
            error.OutOfMemory => error.ResourceLimit,
        };
        try checkpoint(cancel);
        if (response.body.len > max_response_bytes) return error.BodyTooLarge;
        return response;
    }
    fn jsonPost(self: *Client, a: Allocator, url: []const u8, object: anytype, now: u64, expires_at: u64, cancel: ?*const CancelToken) Error!Value {
        const body = std.json.Stringify.valueAlloc(a, object, .{}) catch return error.ResourceLimit;
        const response = try self.fetch(a, .post, url, body, "application/json", null, now, expires_at, cancel);
        const value = try parse(a, response.body);
        if (response.status != 200) {
            if (field(value, "XErr")) |code| {
                if (code != .integer) return error.XboxDenied;
                return switch (code.integer) {
                    2148916233 => error.XboxAccountRequired,
                    2148916235 => error.RegionRestricted,
                    2148916236 => error.AgeVerificationRequired,
                    2148916237, 2148916238 => error.ChildAccountRestricted,
                    else => error.XboxDenied,
                };
            }
            return error.HttpFailure;
        }
        return value;
    }
    fn exchange(self: *Client, a: Allocator, oauth: Value, existing_ref: ?[]const u8, now: u64, expires_at: u64, cancel: ?*const CancelToken) Error!void {
        const msa = try text(oauth, "access_token", max_token_bytes);
        const refresh_token = try text(oauth, "refresh_token", max_token_bytes);
        _ = try seconds(oauth, "expires_in", 86400);
        if (field(oauth, "token_type")) |_| if (!std.ascii.eqlIgnoreCase(try text(oauth, "token_type", 32), "Bearer")) return error.MalformedResponse;
        const ticket = std.fmt.allocPrint(a, "d={s}", .{msa}) catch return error.ResourceLimit;
        const xbl = try self.jsonPost(a, "https://user.auth.xboxlive.com/user/authenticate", .{
            .Properties = .{ .AuthMethod = "RPS", .SiteName = "user.auth.xboxlive.com", .RpsTicket = ticket },
            .RelyingParty = "http://auth.xboxlive.com",
            .TokenType = "JWT",
        }, now, expires_at, cancel);
        const xbl_token = try text(xbl, "Token", max_token_bytes);
        const xbl_uhs = try userHash(xbl);
        const xsts = try self.jsonPost(a, "https://xsts.auth.xboxlive.com/xsts/authorize", .{
            .Properties = .{ .SandboxId = "RETAIL", .UserTokens = [_][]const u8{xbl_token} },
            .RelyingParty = "rp://api.minecraftservices.com/",
            .TokenType = "JWT",
        }, now, expires_at, cancel);
        const xsts_token = try text(xsts, "Token", max_token_bytes);
        const uhs = try userHash(xsts);
        if (!std.mem.eql(u8, uhs, xbl_uhs)) return error.MalformedResponse;
        const identity = std.fmt.allocPrint(a, "XBL3.0 x={s};{s}", .{ uhs, xsts_token }) catch return error.ResourceLimit;
        const minecraft = try self.jsonPost(a, "https://api.minecraftservices.com/authentication/login_with_xbox", .{ .identityToken = identity }, now, expires_at, cancel);
        const mc_token = try text(minecraft, "access_token", max_token_bytes);
        const expiry = try seconds(minecraft, "expires_in", 86400);
        const entitlement_response = try self.fetch(a, .get, "https://api.minecraftservices.com/entitlements/mcstore", "", "application/json", mc_token, now, expires_at, cancel);
        try requireSuccess(entitlement_response);
        const entitlements = try parse(a, entitlement_response.body);
        const items = field(entitlements, "items") orelse return error.MalformedResponse;
        if (items != .array or items.array.items.len > 256) return error.MalformedResponse;
        var entitled = false;
        for (items.array.items) |item| {
            const name = try text(item, "name", 256);
            if (std.mem.eql(u8, name, "game_minecraft") or std.mem.eql(u8, name, "product_minecraft")) entitled = true;
        }
        if (!entitled) return error.EntitlementDenied;
        const profile_response = try self.fetch(a, .get, "https://api.minecraftservices.com/minecraft/profile", "", "application/json", mc_token, now, expires_at, cancel);
        if (profile_response.status == 404) return error.ProfileMissing;
        try requireSuccess(profile_response);
        const profile = try parse(a, profile_response.body);
        const uuid = try text(profile, "id", 32);
        const name = try text(profile, "name", 16);
        if (!validUuid(uuid) or !validName(name)) return error.MalformedResponse;
        try checkpoint(cancel);
        const uuid_owned = try self.allocator.dupe(u8, uuid);
        errdefer self.allocator.free(uuid_owned);
        const name_owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_owned);
        var mc_owned = try secretCopy(self.allocator, mc_token);
        errdefer mc_owned.deinit();
        var refresh_owned = try secretCopy(self.allocator, refresh_token);
        errdefer refresh_owned.deinit();
        var reference: ?credentials.Reference = null;
        if (self.options.persist_refresh) {
            if (existing_ref == null and self.pending_cleanup_ref != null) return error.CredentialCleanupRequired;
            const store = self.store orelse return error.CredentialStoreUnavailable;
            var ref: credentials.Reference = undefined;
            if (existing_ref) |old| @memcpy(&ref, old) else {
                const entropy = self.entropy orelse return error.EntropyUnavailable;
                var bytes: [16]u8 = undefined;
                defer std.crypto.secureZero(u8, &bytes);
                try entropy.fill(entropy.ctx, &bytes);
                const alphabet = "0123456789abcdef";
                for (bytes, 0..) |byte, i| {
                    ref[i * 2] = alphabet[byte >> 4];
                    ref[i * 2 + 1] = alphabet[byte & 15];
                }
            }
            try checkpoint(cancel);
            if (existing_ref == null) self.pending_cleanup_ref = ref;
            store.put(&ref, refresh_token) catch |err| return storeError(err, true);
            if (existing_ref == null) self.pending_cleanup_ref = null;
            reference = ref;
            // Secure-store write is the commit point; late cancellation cannot
            // hide a committed account or discard its only credential reference.
        } else try checkpoint(cancel);
        self.reset();
        self.last_now_ms = now;
        self.account = .{ .uuid = uuid_owned, .name = name_owned, .credential_ref = reference };
        self.minecraft_token = mc_owned;
        self.refresh_token = refresh_owned;
        self.token_expires_at_ms = deadline(now, expiry * 1000);
        self.state = .authenticated;
    }
};

fn wipeFree(a: Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    a.rawFree(bytes, .of(u8), @returnAddress());
}
fn secretCopy(a: Allocator, bytes: []const u8) Error!credentials.Secret {
    return .{ .allocator = a, .bytes = try a.dupe(u8, bytes) };
}
fn checkpoint(cancel: ?*const CancelToken) Error!void {
    if (cancel) |token| if (token.cancelled()) return error.Cancelled;
}
fn deadline(now: u64, duration: u32) u64 {
    return now +| duration;
}
fn requireSuccess(response: Response) Error!void {
    if (response.status != 200) return error.HttpFailure;
}
fn field(value: Value, key: []const u8) ?Value {
    if (value != .object) return null;
    return value.object.get(key);
}
fn safeText(bytes: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(bytes)) return false;
    for (bytes) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}
fn text(value: Value, key: []const u8, limit: usize) Error![]const u8 {
    const item = field(value, key) orelse return error.MalformedResponse;
    if (item != .string or item.string.len == 0 or item.string.len > limit) return error.MalformedResponse;
    if (!safeText(item.string)) return error.MalformedResponse;
    return item.string;
}
fn seconds(value: Value, key: []const u8, max: u32) Error!u32 {
    const item = field(value, key) orelse return error.MalformedResponse;
    if (item != .integer or item.integer <= 0 or item.integer > max) return error.MalformedResponse;
    return @intCast(item.integer);
}
fn parse(a: Allocator, body: []const u8) Error!Value {
    if (body.len > max_response_bytes) return error.BodyTooLarge;
    var scanner = std.json.Scanner.initCompleteInput(a, body);
    defer scanner.deinit();
    var depth: usize = 0;
    var tokens: usize = 0;
    while (true) {
        const token = scanner.next() catch return error.MalformedResponse;
        tokens += 1;
        if (tokens > 8192) return error.ResourceLimit;
        switch (token) {
            .object_begin, .array_begin => {
                depth += 1;
                if (depth > 32) return error.ResourceLimit;
            },
            .object_end, .array_end => {
                if (depth == 0) return error.MalformedResponse;
                depth -= 1;
            },
            .end_of_document => break,
            else => {},
        }
    }
    const parsed = std.json.parseFromSlice(Value, a, body, .{ .allocate = .alloc_always, .max_value_len = max_token_bytes, .duplicate_field_behavior = .@"error" }) catch |err| return if (err == error.OutOfMemory) error.ResourceLimit else error.MalformedResponse;
    // All allocations live in the bounded, wiped operation scratch region.
    return parsed.value;
}
fn form(a: Allocator, fields: []const [2][]const u8) Error![]const u8 {
    const buffer = a.alloc(u8, max_request_bytes) catch return error.ResourceLimit;
    var writer = std.Io.Writer.fixed(buffer);
    for (fields, 0..) |entry, i| {
        if (i != 0) writer.writeByte('&') catch return error.BodyTooLarge;
        std.Uri.Component.percentEncode(&writer, entry[0], formChar) catch return error.BodyTooLarge;
        writer.writeByte('=') catch return error.BodyTooLarge;
        std.Uri.Component.percentEncode(&writer, entry[1], formChar) catch return error.BodyTooLarge;
    }
    return writer.buffered();
}
fn formChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~", c) != null;
}
fn oauthError(code: []const u8) Error {
    if (std.mem.eql(u8, code, "access_denied") or std.mem.eql(u8, code, "authorization_declined")) return error.AuthorizationDenied;
    if (std.mem.eql(u8, code, "expired_token")) return error.AuthorizationExpired;
    if (std.mem.eql(u8, code, "invalid_grant")) return error.RefreshRejected;
    return error.HttpFailure;
}
fn userHash(value: Value) Error![]const u8 {
    const claims = field(value, "DisplayClaims") orelse return error.MalformedResponse;
    const xui = field(claims, "xui") orelse return error.MalformedResponse;
    if (xui != .array or xui.array.items.len != 1) return error.MalformedResponse;
    const hash = try text(xui.array.items[0], "uhs", 64);
    for (hash) |c| if (!std.ascii.isDigit(c)) return error.MalformedResponse;
    return hash;
}
fn validVerificationUri(uri: []const u8) bool {
    for ([_][]const u8{ "https://microsoft.com/devicelogin", "https://www.microsoft.com/devicelogin", "https://www.microsoft.com/link" }) |allowed| if (std.mem.eql(u8, uri, allowed)) return true;
    return false;
}
fn validUuid(uuid: []const u8) bool {
    if (uuid.len != 32) return false;
    for (uuid) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}
fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 16) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}
fn storeError(err: credentials.Error, write: bool) Error {
    return switch (err) {
        error.Unavailable, error.Denied => error.CredentialStoreUnavailable,
        error.NotFound, error.InvalidReference => error.CredentialNotFound,
        error.OutOfMemory => error.OutOfMemory,
        else => if (write) error.CredentialPersistenceFailed else error.CredentialStoreUnavailable,
    };
}

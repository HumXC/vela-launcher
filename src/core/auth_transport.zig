//! Production auth transport for an ordinary worker OS thread, never the UI.
//! The handle may move; its HTTP client and transport context remain heap-stable.
//! Join requests before deinit. Copies of the handle are not independent owners.
const std = @import("std");
const auth = @import("auth.zig");
const http = @import("http_transport.zig");
const Allocator = std.mem.Allocator;

pub const Adapter = struct {
    context: *Context,

    pub fn init(a: Allocator, io: std.Io, options: http.Options) !Adapter {
        const client = try a.create(http.Client);
        errdefer a.destroy(client);
        client.* = try http.Client.init(a, io, options);
        errdefer client.deinit();
        const context = try a.create(Context);
        context.* = .{ .allocator = a, .io = io, .backend = client, .execute = executeNative, .cleanup = cleanupNative };
        return .{ .context = context };
    }

    pub fn deinit(self: *Adapter) void {
        const context = self.context;
        const a = context.allocator;
        context.cleanup(context.backend);
        a.destroy(context);
        self.* = undefined;
    }

    /// The production gate in auth.Client still requires explicit opt-in and ID.
    /// Valid until deinit; never retains the address of this movable handle.
    pub fn transport(self: *Adapter) auth.Transport {
        return .{ .ctx = self.context, .kind = .production, .supports_post = true, .request = request };
    }
};

const Context = struct {
    allocator: Allocator,
    io: std.Io,
    backend: *anyopaque,
    execute: *const fn (*anyopaque, http.Request) anyerror!http.Response,
    cleanup: *const fn (*anyopaque) void,
};

fn executeNative(ctx: *anyopaque, req: http.Request) !http.Response {
    const client: *http.Client = @ptrCast(@alignCast(ctx));
    return client.execute(req);
}

fn cleanupNative(ctx: *anyopaque) void {
    const client: *http.Client = @ptrCast(@alignCast(ctx));
    const a = client.allocator;
    client.deinit();
    a.destroy(client);
}

fn checkpoint(context: *const Context, req: auth.Request) auth.TransportError!void {
    if (req.cancel) |token| if (token.cancelled()) return error.Cancelled;
    if (std.Io.Clock.awake.now(context.io).nanoseconds >= deadlineNs(req.deadline_ms)) return error.Timeout;
}

fn deadlineNs(milliseconds: u64) i96 {
    return @as(i96, milliseconds) * std.time.ns_per_ms;
}

fn mapError(err: anyerror) auth.TransportError {
    return switch (err) {
        error.Canceled, error.Cancelled => error.Cancelled,
        error.TimedOut, error.Timeout => error.Timeout,
        error.ResponseTooLarge, error.BodyTooLarge => error.BodyTooLarge,
        error.OutOfMemory => error.OutOfMemory,
        else => error.TransportFailure,
    };
}

fn request(ctx: *anyopaque, scratch: Allocator, req: auth.Request) auth.TransportError!auth.Response {
    const context: *Context = @ptrCast(@alignCast(ctx));
    try checkpoint(context, req);
    if (req.body.len > auth.max_request_bytes or req.max_response_bytes > auth.max_response_bytes) return error.BodyTooLarge;
    if (req.timeout_ms == 0 or (req.method == .get and req.body.len != 0) or req.headers.len > 128) return error.TransportFailure;

    const headers = try context.allocator.alloc(http.Header, req.headers.len);
    defer context.allocator.free(headers);
    for (req.headers, headers) |source, *dest| dest.* = .{ .name = source.name, .value = source.value };
    var response = context.execute(context.backend, .{
        .method = switch (req.method) {
            .get => .get,
            .post => .post,
        },
        .url = req.url,
        .headers = headers,
        .body = if (req.method == .post) req.body else null,
        .max_response_bytes = req.max_response_bytes,
        .timeout_ms = req.timeout_ms,
        .deadline_ns = deadlineNs(req.deadline_ms),
        .cancel = if (req.cancel) |token| &token.value else null,
        .sensitive = true,
        .follow_redirects = false,
        .allow_http_loopback = false,
    }) catch |err| return mapError(err);
    defer response.deinit();
    try checkpoint(context, req);
    if (response.body.len > req.max_response_bytes) return error.BodyTooLarge;
    if (response.status < 100 or response.status > 599) return error.TransportFailure;
    const body = try scratch.dupe(u8, response.body);
    errdefer {
        std.crypto.secureZero(u8, body);
        scratch.free(body);
    }
    try checkpoint(context, req);
    return .{ .status = response.status, .body = body };
}

// In-memory execute injection is private: no test constructor can enable HTTP.
const Fixture = struct {
    native: WipeAllocator = .{},
    expected: auth.Request = fixtureRequest(),
    body: []const u8 = "fixture-response-secret",
    status: u16 = 401,
    failure: ?anyerror = null,
    cancel_on_return: ?*auth.CancelToken = null,
    calls: usize = 0,

    fn adapter(self: *Fixture, a: Allocator) !Adapter {
        const context = try a.create(Context);
        context.* = .{ .allocator = a, .io = std.testing.io, .backend = self, .execute = execute, .cleanup = cleanup };
        return .{ .context = context };
    }

    fn cleanup(_: *anyopaque) void {}

    fn execute(ctx: *anyopaque, req: http.Request) !http.Response {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        const expected = self.expected;
        try std.testing.expectEqual(@as(http.Method, if (expected.method == .get) .get else .post), req.method);
        try std.testing.expectEqualStrings(expected.url, req.url);
        try std.testing.expectEqual(expected.headers.len, req.headers.len);
        for (expected.headers, req.headers) |source, actual| {
            try std.testing.expectEqualStrings(source.name, actual.name);
            try std.testing.expectEqualStrings(source.value, actual.value);
        }
        if (expected.method == .post) try std.testing.expectEqualStrings(expected.body, req.body.?) else try std.testing.expect(req.body == null);
        try std.testing.expectEqual(expected.max_response_bytes, req.max_response_bytes);
        try std.testing.expectEqual(expected.timeout_ms, req.timeout_ms);
        try std.testing.expectEqual(deadlineNs(expected.deadline_ms), req.deadline_ns.?);
        try std.testing.expect(req.cancel == if (expected.cancel) |token| &token.value else null);
        try std.testing.expect(req.sensitive and !req.follow_redirects and !req.allow_http_loopback);
        if (self.failure) |err| return err;
        if (self.cancel_on_return) |token| token.cancel();
        return .{ .status = self.status, .body = try self.native.allocator().dupe(u8, self.body), .allocator = self.native.allocator() };
    }
};

// Debug/safe Allocator.free poisons bytes after secureZero. ReleaseFast/Small
// exposes the actual wipe to this hook; run both Debug and ReleaseFast tests.
const WipeAllocator = struct {
    frees: usize = 0,
    all_wiped: bool = true,
    cancel_on_alloc: ?*auth.CancelToken = null,
    fn allocator(self: *WipeAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = Allocator.noResize, .remap = Allocator.noRemap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *WipeAllocator = @ptrCast(@alignCast(ctx));
        if (self.cancel_on_alloc) |token| token.cancel();
        return std.testing.allocator.rawAlloc(len, alignment, ret_addr);
    }
    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *WipeAllocator = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        const poison: u8 = if (@import("builtin").mode == .debug or @import("builtin").mode == .safe) 0xaa else 0;
        for (bytes) |byte| if (byte != poison) {
            self.all_wiped = false;
        };
        std.testing.allocator.rawFree(bytes, alignment, ret_addr);
    }
};

fn fixtureRequest() auth.Request {
    return .{
        .method = .post,
        .url = "https://example.invalid/fixture",
        .headers = &.{ .{ .name = "Content-Type", .value = "application/json" }, .{ .name = "Authorization", .value = "Bearer fixture-only-secret" } },
        .body = "fixture-request-secret",
        .max_response_bytes = auth.max_response_bytes,
        .timeout_ms = 1234,
        .deadline_ms = std.math.maxInt(u64),
        .cancel = null,
    };
}

fn releaseResponse(a: Allocator, response: auth.Response) void {
    std.crypto.secureZero(u8, response.body);
    a.free(response.body);
}

fn expectNativeWiped(fixture: *const Fixture) !void {
    try std.testing.expectEqual(@as(usize, 1), fixture.native.frees);
    try std.testing.expect(fixture.native.all_wiped);
}

test "auth adapter maps POST, cancellation, deadline, and copies owned response" {
    var cancel: auth.CancelToken = .{};
    var fixture: Fixture = .{};
    fixture.expected.cancel = &cancel;
    var adapter = try fixture.adapter(std.testing.allocator);
    defer adapter.deinit();
    const transport = adapter.transport();
    try std.testing.expectEqual(.production, transport.kind);
    try std.testing.expect(transport.supports_post);
    const response = try transport.request(transport.ctx, std.testing.allocator, fixture.expected);
    defer releaseResponse(std.testing.allocator, response);
    try std.testing.expectEqual(@as(u16, 401), response.status);
    try std.testing.expectEqualStrings(fixture.body, response.body);
    try expectNativeWiped(&fixture);
    try std.testing.expectEqual(@as(i96, 18_446_744_073_709_551_615_000_000), deadlineNs(std.math.maxInt(u64)));
}

test "auth adapter maps GET with no native body and stable movable handle" {
    var fixture: Fixture = .{};
    fixture.expected.method = .get;
    fixture.expected.body = "";
    fixture.expected.headers = &.{};
    var original = try fixture.adapter(std.testing.allocator);
    const transport = original.transport();
    var moved = original;
    original = undefined;
    defer moved.deinit();
    try std.testing.expect(transport.ctx == moved.transport().ctx);
    const response = try transport.request(transport.ctx, std.testing.allocator, fixture.expected);
    defer releaseResponse(std.testing.allocator, response);
    try std.testing.expectEqualStrings(fixture.body, response.body);
    try expectNativeWiped(&fixture);
}

test "auth adapter rejects request bounds and invalid GET before execute" {
    var fixture: Fixture = .{};
    var adapter = try fixture.adapter(std.testing.allocator);
    defer adapter.deinit();
    const transport = adapter.transport();
    var req = fixture.expected;
    var oversized: [auth.max_request_bytes + 1]u8 = @splat(0);
    req.body = &oversized;
    try std.testing.expectError(error.BodyTooLarge, transport.request(transport.ctx, std.testing.allocator, req));
    req = fixture.expected;
    req.max_response_bytes = auth.max_response_bytes + 1;
    try std.testing.expectError(error.BodyTooLarge, transport.request(transport.ctx, std.testing.allocator, req));
    req = fixture.expected;
    req.method = .get;
    try std.testing.expectError(error.TransportFailure, transport.request(transport.ctx, std.testing.allocator, req));
    req = fixture.expected;
    req.timeout_ms = 0;
    try std.testing.expectError(error.TransportFailure, transport.request(transport.ctx, std.testing.allocator, req));
    req = fixture.expected;
    const headers: [129]auth.Header = @splat(.{ .name = "Accept", .value = "application/json" });
    req.headers = &headers;
    try std.testing.expectError(error.TransportFailure, transport.request(transport.ctx, std.testing.allocator, req));
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}

test "auth adapter cancellation and expired awake deadline prevent execute" {
    var fixture: Fixture = .{};
    var adapter = try fixture.adapter(std.testing.allocator);
    defer adapter.deinit();
    const transport = adapter.transport();
    var req = fixture.expected;
    req.deadline_ms = 0;
    try std.testing.expectError(error.Timeout, transport.request(transport.ctx, std.testing.allocator, req));
    req.deadline_ms = @intCast(@divTrunc(std.Io.Clock.awake.now(std.testing.io).nanoseconds, std.time.ns_per_ms));
    try std.testing.expectError(error.Timeout, transport.request(transport.ctx, std.testing.allocator, req));
    var cancel: auth.CancelToken = .{};
    cancel.cancel();
    req = fixture.expected;
    req.cancel = &cancel;
    try std.testing.expectError(error.Cancelled, transport.request(transport.ctx, std.testing.allocator, req));
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}

test "auth adapter wipes native response on scratch OOM, oversize, status, cancellation" {
    for (0..4) |scenario| {
        var fixture: Fixture = .{};
        var cancel: auth.CancelToken = .{};
        if (scenario == 1) fixture.expected.max_response_bytes = 1;
        if (scenario == 2) fixture.status = 99;
        if (scenario == 3) {
            fixture.expected.cancel = &cancel;
            fixture.cancel_on_return = &cancel;
        }
        var adapter = try fixture.adapter(std.testing.allocator);
        defer adapter.deinit();
        const transport = adapter.transport();
        var empty: [0]u8 = .{};
        var fixed = std.heap.FixedBufferAllocator.init(&empty);
        const scratch = if (scenario == 0) fixed.allocator() else std.testing.allocator;
        const expected: auth.TransportError = switch (scenario) {
            0 => error.OutOfMemory,
            1 => error.BodyTooLarge,
            2 => error.TransportFailure,
            else => error.Cancelled,
        };
        try std.testing.expectError(expected, transport.request(transport.ctx, scratch, fixture.expected));
        try expectNativeWiped(&fixture);
    }
}

test "auth adapter narrows native failures without leaking details" {
    const native_errors = [_]anyerror{ error.Canceled, error.TimedOut, error.ResponseTooLarge, error.OutOfMemory, error.TlsFailure, error.InsecureUrl, error.ConnectionFailed };
    const expected_errors = [_]auth.TransportError{ error.Cancelled, error.Timeout, error.BodyTooLarge, error.OutOfMemory, error.TransportFailure, error.TransportFailure, error.TransportFailure };
    for (native_errors, expected_errors) |failure, expected| {
        var fixture: Fixture = .{ .failure = failure };
        var adapter = try fixture.adapter(std.testing.allocator);
        defer adapter.deinit();
        const transport = adapter.transport();
        try std.testing.expectError(expected, transport.request(transport.ctx, std.testing.allocator, fixture.expected));
        try std.testing.expectEqual(@as(usize, 0), fixture.native.frees);
    }
}

test "auth adapter preserves unconfigured and production-disabled gates" {
    var fixture: Fixture = .{};
    var adapter = try fixture.adapter(std.testing.allocator);
    defer adapter.deinit();
    var unconfigured = try auth.Client.init(std.testing.allocator, .{ .enabled = true }, adapter.transport(), null, null);
    defer unconfigured.deinit();
    try std.testing.expectEqual(.unconfigured, unconfigured.gate());
    var gated = try auth.Client.init(std.testing.allocator, .{ .enabled = true, .client_id = "fixture-public-application-id", .persist_refresh = false }, adapter.transport(), null, null);
    defer gated.deinit();
    try std.testing.expectEqual(.production_disabled, gated.gate());
    try std.testing.expectError(error.ProductionDisabled, gated.beginDevice(0, null));
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}

test "auth adapter accepts exact body bounds and zero-length response" {
    const request_body: [auth.max_request_bytes]u8 = @splat('q');
    const response_body: [auth.max_response_bytes]u8 = @splat('r');
    var fixture: Fixture = .{ .body = &response_body };
    fixture.expected.body = &request_body;
    var adapter = try fixture.adapter(std.testing.allocator);
    defer adapter.deinit();
    const transport = adapter.transport();
    const response = try transport.request(transport.ctx, std.testing.allocator, fixture.expected);
    defer releaseResponse(std.testing.allocator, response);
    try std.testing.expectEqualStrings(&response_body, response.body);
    try expectNativeWiped(&fixture);
    fixture.body = "";
    fixture.expected.max_response_bytes = 0;
    const empty = try transport.request(transport.ctx, std.testing.allocator, fixture.expected);
    defer releaseResponse(std.testing.allocator, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.body.len);
}

test "auth adapter wipes both copies if cancelled during scratch allocation" {
    var cancel: auth.CancelToken = .{};
    var fixture: Fixture = .{};
    fixture.expected.cancel = &cancel;
    var adapter = try fixture.adapter(std.testing.allocator);
    defer adapter.deinit();
    const transport = adapter.transport();
    var scratch: WipeAllocator = .{ .cancel_on_alloc = &cancel };
    try std.testing.expectError(error.Cancelled, transport.request(transport.ctx, scratch.allocator(), fixture.expected));
    try expectNativeWiped(&fixture);
    try std.testing.expectEqual(@as(usize, 1), scratch.frees);
    try std.testing.expect(scratch.all_wiped);
}

const ExpiringClock = struct {
    calls: usize = 0,
    fn now(ctx: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
        std.debug.assert(clock == .awake);
        const self: *ExpiringClock = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        return .{ .nanoseconds = if (self.calls == 1) 0 else std.time.ns_per_ms };
    }
};

test "auth adapter wipes native response if awake deadline expires during execute" {
    var fixture: Fixture = .{};
    fixture.expected.deadline_ms = 1;
    var adapter = try fixture.adapter(std.testing.allocator);
    defer adapter.deinit();
    var clock: ExpiringClock = .{};
    var vtable = std.testing.io.vtable.*;
    vtable.now = ExpiringClock.now;
    adapter.context.io = .{ .userdata = &clock, .vtable = &vtable };
    const transport = adapter.transport();
    try std.testing.expectError(error.Timeout, transport.request(transport.ctx, std.testing.allocator, fixture.expected));
    try expectNativeWiped(&fixture);
}

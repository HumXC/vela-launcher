//! Explicit synchronous cache coordinator for public, nonsensitive metadata GETs.
//! All inputs (including root/backend/clock contexts) are borrowed. Responses own
//! their bytes and must be deinitialized. Backend callbacks must honor the passed
//! cancellation/deadline, use identity encoding unless explicitly overridden, and
//! return http.Response with its allocator owning both body and cache headers.
//! The caller must mark private URLs/payloads sensitive; a scope is a partition,
//! not permission to cache authentication. No background work or stale-on-error.
const std = @import("std");
const http = @import("http_transport.zig");
const policy = @import("http_cache_policy.zig");
const store = @import("http_cache_store.zig");
const OwnedHeaders = @import("http_cache_headers.zig").Owned;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Mode = enum { bypass, prefer_cache, revalidate };
pub const Backend = struct {
    context: ?*anyopaque = null,
    execute: *const fn (?*anyopaque, http.Request) anyerror!http.Response,
};
pub const Clock = struct {
    context: ?*anyopaque = null,
    now: *const fn (?*anyopaque, std.Io) i64 = realSeconds,
};

// Process-wide stripes also coalesce separate Client instances. Collisions only
// serialize unrelated keys. Disk atomicity is supplied by store, not this lock.
var stripes: [64]std.Io.Mutex = @splat(.init);

pub const Client = struct {
    allocator: Allocator,
    io: std.Io,
    root: []const u8,
    backend: Backend,
    clock: Clock = .{},

    pub fn execute(self: *const Client, original: http.Request, mode: Mode, scope: []const u8) anyerror!http.Response {
        // Validate even a cache hit, including response size and header limits.
        try http.validateRequestBounded(original, 64 * 1024 * 1024);
        var request = original;
        const started = std.Io.Clock.awake.now(self.io).nanoseconds;
        request.deadline_ns = @min(original.deadline_ns orelse std.math.maxInt(i96), started + @as(i96, original.timeout_ms) * std.time.ns_per_ms);
        try self.check(request);
        if (mode == .bypass or !eligible(request, scope)) return self.fetch(request);

        const key = requestKey(request, scope);
        const key_hex = std.fmt.bytesToHex(key, .lower);
        const scope_hex = scopeDigest(scope);
        const mutex = &stripes[key[0] % stripes.len];
        while (!mutex.tryLock()) {
            try self.check(request);
            try self.io.sleep(.fromMilliseconds(10), .awake);
        }
        defer mutex.unlock(self.io);
        try self.check(request);

        // Request no-store forbids both reuse and persistence, and invalidates a
        // previous representation for this exact partition.
        if (requestNoStore(request)) {
            store.remove(self.io, self.root, key);
            try self.check(request);
            return self.fetch(request);
        }
        var entry = store.load(self.allocator, self.io, self.root, key, request.max_response_bytes) catch |err| switch (err) {
            error.Canceled => return err,
            else => null, // Persistence is an optimization, including allocation.
        };
        defer if (entry) |*value| value.deinit();
        try self.check(request);
        var cached: ?store.Record = null;
        if (entry) |value| {
            const record = value.parsed.value;
            if (std.mem.eql(u8, record.request_key, &key_hex) and
                std.mem.eql(u8, record.scope, &scope_hex) and
                std.mem.eql(u8, record.url, publicUrl(request.url)) and
                varySupported(record.headers.vary, request))
            {
                const current_time = self.now();
                const decision = policy.evaluate(record.headers, record.request_time, record.response_time, current_time);
                if (decision.store) {
                    cached = record;
                    if (mode == .prefer_cache and !requestValidate(request) and !decision.requires_validation and current_time < decision.fresh_until) {
                        var response = try self.cachedResponse(record.body, record.headers);
                        errdefer response.deinit();
                        try self.check(request);
                        response.source = .fresh_cache;
                        return response;
                    }
                } else store.remove(self.io, self.root, key);
            }
        }

        var conditional_headers: std.ArrayList(http.Header) = .empty;
        defer conditional_headers.deinit(self.allocator);
        var outgoing = request;
        var conditional = false;
        if (cached) |record| {
            if (record.headers.etag != null or record.headers.last_modified != null) {
                try conditional_headers.appendSlice(self.allocator, request.headers);
                if (record.headers.etag) |etag| {
                    try conditional_headers.append(self.allocator, .{ .name = "If-None-Match", .value = etag });
                } else if (record.headers.last_modified) |modified| {
                    try conditional_headers.append(self.allocator, .{ .name = "If-Modified-Since", .value = modified });
                }
                outgoing.headers = conditional_headers.items;
                // Corrupt/hostile persisted validators must never reach a backend.
                http.validateRequestBounded(outgoing, 64 * 1024 * 1024) catch {
                    outgoing = request;
                };
                conditional = outgoing.headers.ptr == conditional_headers.items.ptr;
            }
        }
        var request_time = self.now();
        var response = try self.fetch(outgoing);
        errdefer response.deinit();
        var response_time = self.now();
        if (response.status == 304 and conditional and cached != null) {
            const record = cached.?;
            const merged = merge304(record.headers, response.cache_headers.view());
            var result = try self.cachedResponse(record.body, merged);
            errdefer result.deinit();
            result.source = .revalidated;
            self.persist(request, key, &key_hex, &scope_hex, result, request_time, response_time);
            try self.check(request);
            response.deinit();
            return result;
        }
        if (response.status == 304) {
            // A 304 without a usable conditional representation cannot supply a
            // body. Retry exactly once with the original unconditional request.
            response.deinit();
            // Keep errdefer valid if the retry fails.
            response = .{ .status = 304, .body = &.{}, .allocation = &.{}, .allocator = self.allocator };
            request_time = self.now();
            response = try self.fetch(request);
            response_time = self.now();
            if (response.status == 304) return error.UnexpectedNotModified;
        }
        self.persist(request, key, &key_hex, &scope_hex, response, request_time, response_time);
        try self.check(request);
        return response;
    }

    fn now(self: *const Client) i64 {
        return self.clock.now(self.clock.context, self.io);
    }

    fn check(self: *const Client, request: http.Request) !void {
        if (request.cancel) |flag| if (flag.load(.acquire)) return error.Canceled;
        if (std.Io.Clock.awake.now(self.io).nanoseconds >= request.deadline_ns.?) return error.TimedOut;
    }

    fn fetch(self: *const Client, request: http.Request) !http.Response {
        try self.check(request);
        var response = try self.backend.execute(self.backend.context, request);
        errdefer response.deinit();
        try self.check(request);
        if (response.body.len > request.max_response_bytes) return error.ResponseTooLarge;
        response.source = .network;
        return response;
    }

    fn cachedResponse(self: *const Client, body: []const u8, headers: policy.Headers) !http.Response {
        const bytes = try self.allocator.dupe(u8, body);
        errdefer self.allocator.free(bytes);
        return .{ .status = 200, .body = bytes, .allocation = bytes, .allocator = self.allocator, .cache_headers = try OwnedHeaders.clone(self.allocator, headers) };
    }

    fn persist(self: *const Client, request: http.Request, key: [32]u8, key_hex: []const u8, scope_hex: []const u8, response: http.Response, request_time: i64, response_time: i64) void {
        const headers = response.cache_headers.view();
        const decision = policy.evaluate(headers, request_time, response_time, response_time);
        if (response.status != 200 or !decision.store or !varySupported(headers.vary, request)) {
            store.remove(self.io, self.root, key);
            return;
        }
        // Never turn a successful HTTP response into a persistence failure.
        self.check(request) catch return;
        store.save(self.allocator, self.io, self.root, key, .{
            .url = publicUrl(request.url),
            .scope = scope_hex,
            .request_key = key_hex,
            .stored_at = response_time,
            .request_time = request_time,
            .response_time = response_time,
            .headers = headers,
            .body_hash = @splat(0), // store computes the actual digest.
            .body = response.body,
        }) catch {};
    }
};

fn realSeconds(_: ?*anyopaque, io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}

fn same(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn eligible(request: http.Request, scope: []const u8) bool {
    if (request.method != .get or request.body != null or request.sensitive) return false;
    for (request.headers) |header| {
        // Auth/cookies, range and caller-owned conditional requests always bypass.
        if (same(header.name, "accept") or same(header.name, "accept-language") or
            same(header.name, "accept-encoding") or same(header.name, "user-agent") or
            same(header.name, "cache-control") or same(header.name, "pragma")) continue;
        if (same(header.name, "x-api-key") and scope.len != 0) continue;
        return false;
    }
    return true;
}

fn requestNoStore(request: http.Request) bool {
    for (request.headers) |header| {
        if (!same(header.name, "cache-control")) continue;
        var parts = std.mem.splitScalar(u8, header.value, ',');
        while (parts.next()) |part| {
            const name = std.mem.trim(u8, part[0 .. std.mem.findScalar(u8, part, '=') orelse part.len], " \t");
            if (same(name, "no-store")) return true;
        }
    }
    return false;
}

fn requestValidate(request: http.Request) bool {
    // Conservative for all request directives, including max-age/min-fresh.
    for (request.headers) |header| if (same(header.name, "cache-control") or same(header.name, "pragma")) return true;
    return false;
}

fn varySupported(raw: ?[]const u8, request: http.Request) bool {
    var names = std.mem.splitScalar(u8, raw orelse return true, ',');
    while (names.next()) |part| {
        const name = std.mem.trim(u8, part, " \t");
        if (name.len == 0 or same(name, "*") or same(name, "cache-control") or same(name, "pragma")) return false;
        // Host derives from the hashed URL; absent Accept-Encoding is identity.
        if (same(name, "host") or same(name, "accept-encoding")) continue;
        var explicit = false;
        for (request.headers) |header| {
            if (same(name, header.name)) {
                explicit = true;
                break;
            }
        }
        if (!explicit) return false;
    }
    return true;
}

fn merge304(old: policy.Headers, supplied: policy.Headers) policy.Headers {
    var result = old;
    inline for (.{ "cache_control", "date", "age", "expires", "etag", "last_modified", "vary" }) |field| {
        if (@field(supplied, field)) |value| @field(result, field) = value;
    }
    // Missing Date/Age describe this validation exchange, not the old exchange.
    // Policy interprets null Date as response_time and null Age as zero.
    result.date = supplied.date;
    result.age = supplied.age;
    return result;
}

fn hashPart(hash: *Sha256, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(bytes.len), .little);
    hash.update(&length);
    hash.update(bytes);
}

fn requestKey(request: http.Request, scope: []const u8) [32]u8 {
    var hash = Sha256.init(.{});
    hashPart(&hash, "vela-http-cache-v1");
    hashPart(&hash, request.url);
    hashPart(&hash, scope);
    hash.update(&.{ @intFromBool(request.require_public_address), @intFromBool(request.follow_redirects), @intFromBool(request.allow_http_loopback) });
    for (request.headers) |header| {
        // Cache directives control reuse, not representation identity.
        if (same(header.name, "cache-control") or same(header.name, "pragma")) continue;
        // Length framing prevents delimiter ambiguity. Order and duplicate fields
        // are intentionally preserved; capitalization of names is immaterial.
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(header.name.len), .little);
        hash.update(&length);
        for (header.name) |byte| hash.update(&.{std.ascii.toLower(byte)});
        hashPart(&hash, header.value);
    }
    return hash.finalResult();
}

fn scopeDigest(scope: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(scope, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn publicUrl(url: []const u8) []const u8 {
    // Query values never enter metadata. The entire URL still enters the digest,
    // so public search/filter requests remain distinct. URL userinfo is rejected
    // by transport validation before lookup. Sensitive paths require bypass.
    return url[0 .. std.mem.findScalar(u8, url, '?') orelse url.len];
}

const Fake = struct {
    calls: usize = 0,
    seconds: i64 = 1_700_000_000,
    headers: policy.Headers = .{ .cache_control = "max-age=60", .etag = "test-validator" },
    saw_validator: bool = false,
    unexpected_304: bool = false,
    fail: bool = false,
    modified: bool = false,
    body: []const u8 = "cached body",

    fn clock(context: ?*anyopaque, _: std.Io) i64 {
        const self: *Fake = @ptrCast(@alignCast(context.?));
        return self.seconds;
    }

    fn execute(context: ?*anyopaque, request: http.Request) anyerror!http.Response {
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        if (self.fail) return error.TestNetworkFailure;
        var conditional = false;
        for (request.headers) |header| {
            if ((same(header.name, "if-none-match") or same(header.name, "if-modified-since")) and std.mem.eql(u8, header.value, "test-validator")) conditional = true;
        }
        self.saw_validator = conditional;
        const not_modified = (conditional and !self.modified) or (self.unexpected_304 and self.calls == 1);
        const a = std.testing.allocator;
        const body = try a.dupe(u8, if (not_modified) "" else self.body);
        errdefer a.free(body);
        return .{
            .status = if (not_modified) 304 else 200,
            .body = body,
            .allocation = body,
            .allocator = a,
            .cache_headers = try OwnedHeaders.clone(a, self.headers),
        };
    }

    fn client(self: *Fake, root: []const u8) Client {
        return .{ .allocator = std.testing.allocator, .io = std.testing.io, .root = root, .backend = .{ .context = self, .execute = execute }, .clock = .{ .context = self, .now = clock } };
    }
};

const test_request: http.Request = .{ .url = "https://example.com/public.json" };

fn fetchAndDispose(client: *const Client, request: http.Request, mode: Mode, scope: []const u8) !void {
    var response = try client.execute(request, mode, scope);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("cached body", response.body);
}

test "fresh hits avoid network and explicit revalidation merges 304 metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var fake: Fake = .{};
    const client = fake.client(root);
    try fetchAndDispose(&client, test_request, .prefer_cache, "");
    {
        var hit = try client.execute(test_request, .prefer_cache, "");
        defer hit.deinit();
        try std.testing.expect(hit.source == .fresh_cache);
        try std.testing.expectEqual(@as(usize, 1), fake.calls);
    }
    fake.seconds += 20;
    fake.headers = .{};
    {
        var validated = try client.execute(test_request, .revalidate, "");
        defer validated.deinit();
        try std.testing.expect(validated.source == .revalidated);
        try std.testing.expect(fake.saw_validator);
        try std.testing.expectEqualStrings("max-age=60", validated.cache_headers.view().cache_control.?);
        try std.testing.expectEqualStrings("cached body", validated.body);
    }
    fake.seconds += 50;
    try fetchAndDispose(&client, test_request, .prefer_cache, "");
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    fake.seconds += 11;
    fake.fail = true;
    try std.testing.expectError(error.TestNetworkFailure, client.execute(test_request, .prefer_cache, ""));
}

test "no-cache always validates and no-store removes an existing entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var fake: Fake = .{ .headers = .{ .cache_control = "no-cache, max-age=600", .etag = "test-validator" } };
    const client = fake.client(root);
    try fetchAndDispose(&client, test_request, .prefer_cache, "");
    try fetchAndDispose(&client, test_request, .prefer_cache, "");
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expect(fake.saw_validator);
    fake.headers.cache_control = "no-store";
    try fetchAndDispose(&client, test_request, .prefer_cache, "");
    const key = requestKey(test_request, "");
    try std.testing.expect((try store.load(std.testing.allocator, std.testing.io, root, key, 1024)) == null);
    try fetchAndDispose(&client, test_request, .prefer_cache, "");
    try std.testing.expect(!fake.saw_validator);
    try fetchAndDispose(&client, test_request, .prefer_cache, "");
    try std.testing.expectEqual(@as(usize, 5), fake.calls);
}

test "headers scope URL and guard flags partition without raw scope metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var fake: Fake = .{};
    const client = fake.client(root);
    var request = test_request;
    request.url = "https://example.com/public.json?filter=one";
    request.headers = &.{.{ .name = "X-Api-Key", .value = "provider-secret" }};
    try fetchAndDispose(&client, request, .prefer_cache, "provider-private-scope");
    try fetchAndDispose(&client, request, .prefer_cache, "provider-private-scope");
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    var entry = (try store.load(std.testing.allocator, std.testing.io, root, requestKey(request, "provider-private-scope"), 1024)).?;
    defer entry.deinit();
    try std.testing.expectEqualStrings("https://example.com/public.json", entry.parsed.value.url);
    try std.testing.expectEqual(@as(usize, 64), entry.parsed.value.scope.len);
    try std.testing.expectEqual(@as(usize, 64), entry.parsed.value.request_key.len);
    try std.testing.expect(!std.mem.eql(u8, "provider-private-scope", entry.parsed.value.scope));
    try fetchAndDispose(&client, request, .prefer_cache, "other");
    request.headers = &.{.{ .name = "X-Api-Key", .value = "other-secret" }};
    try fetchAndDispose(&client, request, .prefer_cache, "other");
    request.require_public_address = true;
    try fetchAndDispose(&client, request, .prefer_cache, "other");
    request.follow_redirects = true;
    try fetchAndDispose(&client, request, .prefer_cache, "other");
    request.url = "https://example.com/public.json?filter=two";
    try fetchAndDispose(&client, request, .prefer_cache, "other");
    try std.testing.expectEqual(@as(usize, 6), fake.calls);
}

test "auth custom headers unscoped provider keys sensitive and bypass never reuse" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var fake: Fake = .{};
    const client = fake.client(root);
    for ([_][]const u8{ "Authorization", "Cookie", "Proxy-Authorization", "X-Unknown", "If-None-Match", "Range" }) |name| {
        const headers = [_]http.Header{.{ .name = name, .value = "test" }};
        var request = test_request;
        request.headers = &headers;
        try fetchAndDispose(&client, request, .prefer_cache, "explicit scope");
        try fetchAndDispose(&client, request, .prefer_cache, "explicit scope");
    }
    var request = test_request;
    request.headers = &.{.{ .name = "x-api-key", .value = "secret" }};
    try fetchAndDispose(&client, request, .prefer_cache, "");
    try fetchAndDispose(&client, request, .prefer_cache, "");
    request = test_request;
    request.sensitive = true;
    try fetchAndDispose(&client, request, .prefer_cache, "");
    try fetchAndDispose(&client, request, .prefer_cache, "");
    try fetchAndDispose(&client, test_request, .bypass, "");
    try fetchAndDispose(&client, test_request, .bypass, "");
    try std.testing.expectEqual(@as(usize, 18), fake.calls);
}

test "Vary rejects implicit unknown fields and star but supports explicit headers" {
    try std.testing.expect(varySupported("Host, Accept-Encoding", test_request));
    try std.testing.expect(!varySupported("User-Agent", test_request));
    try std.testing.expect(!varySupported("*", test_request));
    var request = test_request;
    request.headers = &.{.{ .name = "Accept-Language", .value = "en" }};
    try std.testing.expect(varySupported("accept-language", request));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var fake: Fake = .{ .headers = .{ .cache_control = "max-age=60", .vary = "User-Agent" } };
    const client = fake.client(root);
    try fetchAndDispose(&client, test_request, .prefer_cache, "");
    try fetchAndDispose(&client, test_request, .prefer_cache, "");
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
}

test "304 without cached representation retries once unconditionally" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var fake: Fake = .{ .unexpected_304 = true };
    const client = fake.client(root);
    try fetchAndDispose(&client, test_request, .prefer_cache, "");
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expect(!fake.saw_validator);
}

test "cancellation and deadline apply before lookup and during stripe wait" {
    var fake: Fake = .{};
    const client = fake.client("unused-root");
    var cancel = std.atomic.Value(bool).init(true);
    var request = test_request;
    request.cancel = &cancel;
    try std.testing.expectError(error.Canceled, client.execute(request, .prefer_cache, ""));
    cancel.store(false, .release);
    request.deadline_ns = 0;
    try std.testing.expectError(error.TimedOut, client.execute(request, .prefer_cache, ""));
    request.deadline_ns = null;
    request.timeout_ms = 1;
    const key = requestKey(request, "");
    const mutex = &stripes[key[0] % stripes.len];
    try std.testing.expect(mutex.tryLock());
    defer mutex.unlock(std.testing.io);
    try std.testing.expectError(error.TimedOut, client.execute(request, .prefer_cache, ""));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "304 resets old date and age and persistence failure preserves network success" {
    const merged = merge304(.{ .date = "Wed, 01 Jan 2020 00:00:00 GMT", .age = "900", .etag = "test-validator", .cache_control = "max-age=60" }, .{});
    try std.testing.expect(merged.date == null and merged.age == null);
    const decision = policy.evaluate(merged, 1000, 1000, 1001);
    try std.testing.expect(decision.fresh_until == 1060 and !decision.requires_validation);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "not-a-directory", .{});
    file.close(std.testing.io);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "not-a-directory", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var fake: Fake = .{};
    const client = fake.client(root);
    try fetchAndDispose(&client, test_request, .prefer_cache, "");
    try fetchAndDispose(&client, test_request, .prefer_cache, "");
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
}

test "request no-cache and Pragma refresh the ordinary key and no-store removes it" {
    for ([_][]const u8{ "Cache-Control", "Pragma" }) |directive| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        var fake: Fake = .{};
        const client = fake.client(root);
        try fetchAndDispose(&client, test_request, .prefer_cache, "");
        fake.modified = true;
        fake.body = "refreshed body";
        var request = test_request;
        const headers = [_]http.Header{.{ .name = directive, .value = "no-cache" }};
        request.headers = &headers;
        {
            var refreshed = try client.execute(request, .prefer_cache, "");
            defer refreshed.deinit();
            try std.testing.expect(refreshed.source == .network);
            try std.testing.expect(fake.saw_validator);
            try std.testing.expectEqualStrings("refreshed body", refreshed.body);
        }
        {
            var ordinary = try client.execute(test_request, .prefer_cache, "");
            defer ordinary.deinit();
            try std.testing.expect(ordinary.source == .fresh_cache);
            try std.testing.expectEqualStrings("refreshed body", ordinary.body);
            try std.testing.expectEqual(@as(usize, 2), fake.calls);
        }
        request.headers = &.{.{ .name = "cache-control", .value = "no-store" }};
        {
            var uncached = try client.execute(request, .prefer_cache, "");
            defer uncached.deinit();
            try std.testing.expect(uncached.source == .network);
            try std.testing.expect(!fake.saw_validator);
        }
        try std.testing.expect((try store.load(std.testing.allocator, std.testing.io, root, requestKey(test_request, ""), 1024)) == null);
        {
            var ordinary = try client.execute(test_request, .prefer_cache, "");
            defer ordinary.deinit();
            try std.testing.expect(ordinary.source == .network);
            try std.testing.expect(!fake.saw_validator);
            try std.testing.expectEqual(@as(usize, 4), fake.calls);
        }
    }
}

test "Vary on request cache directives never persists even with explicit headers" {
    for ([_][]const u8{ "Cache-Control", "Pragma" }) |directive| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        var fake: Fake = .{};
        const client = fake.client(root);
        try fetchAndDispose(&client, test_request, .prefer_cache, "");
        fake.headers.vary = directive;
        const headers = [_]http.Header{.{ .name = directive, .value = "no-cache" }};
        var request = test_request;
        request.headers = &headers;
        try fetchAndDispose(&client, request, .prefer_cache, "");
        try std.testing.expect(fake.saw_validator);
        try std.testing.expect((try store.load(std.testing.allocator, std.testing.io, root, requestKey(test_request, ""), 1024)) == null);
        try fetchAndDispose(&client, request, .prefer_cache, "");
        try std.testing.expect(!fake.saw_validator);
        try std.testing.expect((try store.load(std.testing.allocator, std.testing.io, root, requestKey(test_request, ""), 1024)) == null);
    }
}

test "simultaneous misses serialize and recheck the persisted response" {
    const Worker = struct {
        client: *const Client,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            fetchAndDispose(self.client, test_request, .prefer_cache, "coalesce") catch |err| {
                self.failure = err;
            };
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var fake: Fake = .{};
    const client = fake.client(root);
    var first: Worker = .{ .client = &client };
    var second: Worker = .{ .client = &client };
    const one = try std.Thread.spawn(.{}, Worker.run, .{&first});
    const two = std.Thread.spawn(.{}, Worker.run, .{&second}) catch |err| {
        one.join();
        return err;
    };
    one.join();
    two.join();
    if (first.failure) |err| return err;
    if (second.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}

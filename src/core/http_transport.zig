//! Synchronous HTTP for ordinary worker OS threads, never the UI thread.
//! Client owns a balanced libcurl global reference and copied options. Join all
//! execute calls before deinit. Concurrent execute calls require thread-safe Io
//! and allocator. Requests borrow inputs until execute returns; responses own
//! bytes (including non-2xx bodies), and deinit wipes them. No cache or logging.
const std = @import("std");
const curl = @import("curl");
const public_network = @import("public_network.zig");
const c = curl.libcurl;
const Allocator = std.mem.Allocator;
const max_url_bytes = 16 * 1024;
const max_header_bytes = 64 * 1024;
const max_body_bytes = 64 * 1024 * 1024;

pub const Header = struct { name: []const u8, value: []const u8 };
pub const Method = enum { get, post };
pub const Request = struct {
    method: Method = .get,
    url: []const u8,
    headers: []const Header = &.{},
    body: ?[]const u8 = null,
    max_response_bytes: usize = 8 * 1024 * 1024,
    /// Nonzero total timeout, including all redirects; must fit native c_long.
    timeout_ms: u32 = 30_000,
    /// Absolute std.Io.Clock.awake monotonic nanoseconds.
    deadline_ns: ?i96 = null,
    cancel: ?*const std.atomic.Value(bool) = null,
    /// Test-only exception: exact 127.0.0.1 / [::1], not DNS aliases.
    allow_http_loopback: bool = false,
    /// GET metadata only, at most five validated redirects. Disabled for POST,
    /// sensitive requests, and every non-allowlisted request header.
    follow_redirects: bool = false,
    sensitive: bool = false,
    /// Reject resolved nonpublic endpoints before socket creation; proxies unsupported.
    require_public_address: bool = false,
};
pub const Options = struct {
    /// Null or empty disables ALL environment proxy settings; explicit only.
    proxy: ?[]const u8 = null,
    /// PEM file path. Null collects the native trust store at worker init.
    ca_bundle: ?[]const u8 = null,
};
pub const Response = struct {
    status: u16,
    body: []u8,
    allocator: Allocator,

    pub fn deinit(self: *Response) void {
        std.crypto.secureZero(u8, self.body);
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

pub const Client = struct {
    allocator: Allocator,
    io: std.Io,
    proxy: [:0]u8,
    ca_path: ?[:0]u8,
    ca_pem: std.ArrayList(u8),

    pub fn init(a: Allocator, io: std.Io, options: Options) !Client {
        const proxy = options.proxy orelse "";
        if (proxy.len > max_url_bytes or badControls(proxy)) return error.InvalidProxy;
        if (options.ca_bundle) |path| {
            if (path.len == 0 or path.len > max_url_bytes or badControls(path)) return error.InvalidCaBundle;
        }
        const p = try a.dupeZ(u8, proxy);
        errdefer {
            std.crypto.secureZero(u8, p);
            a.free(p);
        }
        const ca_path = if (options.ca_bundle) |path| try a.dupeZ(u8, path) else null;
        errdefer if (ca_path) |path| a.free(path);
        var ca_pem: std.ArrayList(u8) = if (ca_path == null) try collectNativeCA(a, io) else .empty;
        errdefer ca_pem.deinit(a);
        // Vendored libcurl 8.19 supports thread-safe global init/cleanup. Its
        // global refcount composes with the downloader's app-owned reference.
        try curl.globalInit();
        return .{ .allocator = a, .io = io, .proxy = p, .ca_path = ca_path, .ca_pem = ca_pem };
    }

    pub fn deinit(self: *Client) void {
        curl.globalDeinit();
        std.crypto.secureZero(u8, self.proxy);
        self.allocator.free(self.proxy);
        if (self.ca_path) |path| self.allocator.free(path);
        self.ca_pem.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn execute(self: *const Client, request: Request) !Response {
        try validateRequest(request);
        if (request.require_public_address and self.proxy.len != 0) return error.UnsupportedProxyWithPublicAddressGuard;
        const start = std.Io.Clock.awake.now(self.io).nanoseconds;
        const deadline = @min(request.deadline_ns orelse std.math.maxInt(i96), start + @as(i96, request.timeout_ms) * std.time.ns_per_ms);
        var state: Transfer = .{ .allocator = self.allocator, .io = self.io, .request = request, .deadline = deadline };
        defer state.deinit();
        try state.check();
        var current = try self.allocator.dupeZ(u8, request.url);
        defer self.allocator.free(current);
        var headers: ?*c.curl_slist = null;
        defer freeHeaders(headers);
        for (request.headers) |header| {
            const line = try std.fmt.allocPrintSentinel(self.allocator, "{s}: {s}", .{ header.name, header.value }, 0);
            defer {
                std.crypto.secureZero(u8, line);
                self.allocator.free(line);
            }
            headers = c.curl_slist_append(headers, line.ptr) orelse return error.OutOfMemory;
        }
        const can_redirect = redirectsAllowed(request);
        var redirects: usize = 0;
        while (true) {
            try state.check();
            state.body.clear(self.allocator);
            state.location.clearRetainingCapacity();
            state.header_bytes = 0;
            state.failure = null;
            const easy = c.curl_easy_init() orelse return error.CurlInit;
            defer c.curl_easy_cleanup(easy);
            try set(easy, c.CURLOPT_URL, current.ptr);
            try set(easy, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
            try set(easy, c.CURLOPT_VERBOSE, @as(c_long, 0));
            try set(easy, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 0));
            // HTTP is enabled only after URL validation of each exact loopback
            // hop; libcurl itself never automatically follows any redirect.
            try set(easy, c.CURLOPT_PROTOCOLS_STR, @as([*:0]const u8, if (request.allow_http_loopback) "https,http" else "https"));
            try set(easy, c.CURLOPT_REDIR_PROTOCOLS_STR, @as([*:0]const u8, "https"));
            try set(easy, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 1));
            try set(easy, c.CURLOPT_SSL_VERIFYHOST, @as(c_long, 2));
            try set(easy, c.CURLOPT_PROXY_SSL_VERIFYPEER, @as(c_long, 1));
            try set(easy, c.CURLOPT_PROXY_SSL_VERIFYHOST, @as(c_long, 2));
            try set(easy, c.CURLOPT_PROXY, self.proxy.ptr);
            if (request.require_public_address) {
                try set(easy, c.CURLOPT_OPENSOCKETFUNCTION, &public_network.openSocket);
                try set(easy, c.CURLOPT_FRESH_CONNECT, @as(c_long, 1));
                try set(easy, c.CURLOPT_FORBID_REUSE, @as(c_long, 1));
                try set(easy, c.CURLOPT_OPENSOCKETDATA, &state.failure);
            }
            // Ignore environment NO_PROXY as well when an explicit proxy exists.
            try set(easy, c.CURLOPT_NOPROXY, @as([*:0]const u8, ""));
            if (self.ca_path) |path| {
                try set(easy, c.CURLOPT_CAINFO, path.ptr);
                try set(easy, c.CURLOPT_PROXY_CAINFO, path.ptr);
            } else {
                const blob: c.curl_blob = .{ .data = self.ca_pem.items.ptr, .len = self.ca_pem.items.len, .flags = c.CURL_BLOB_NOCOPY };
                try set(easy, c.CURLOPT_CAINFO_BLOB, &blob);
                try set(easy, c.CURLOPT_PROXY_CAINFO_BLOB, &blob);
            }
            const remaining = try state.remainingMillis();
            try set(easy, c.CURLOPT_TIMEOUT_MS, remaining);
            try set(easy, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, @min(remaining, 30_000)));
            try set(easy, c.CURLOPT_WRITEFUNCTION, &writeCallback);
            try set(easy, c.CURLOPT_WRITEDATA, &state);
            try set(easy, c.CURLOPT_HEADERFUNCTION, &headerCallback);
            try set(easy, c.CURLOPT_HEADERDATA, &state);
            try set(easy, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
            try set(easy, c.CURLOPT_XFERINFOFUNCTION, &progressCallback);
            try set(easy, c.CURLOPT_XFERINFODATA, &state);
            if (headers) |list| try set(easy, c.CURLOPT_HTTPHEADER, list);
            if (request.method == .post) {
                const body = request.body orelse "";
                try set(easy, c.CURLOPT_POST, @as(c_long, 1));
                try set(easy, c.CURLOPT_POSTFIELDSIZE_LARGE, @as(c.curl_off_t, @intCast(body.len)));
                try set(easy, c.CURLOPT_POSTFIELDS, body.ptr);
            } else try set(easy, c.CURLOPT_HTTPGET, @as(c_long, 1));
            try state.check();
            const result = c.curl_easy_perform(easy);
            if (state.failure) |err| return err;
            try state.check();
            if (result != c.CURLE_OK) return curlFailure(result);
            var status: c_long = 0;
            if (c.curl_easy_getinfo(easy, c.CURLINFO_RESPONSE_CODE, &status) != c.CURLE_OK) return error.CurlInfo;
            if (status < 100 or status > 599) return error.InvalidHttpStatus;
            if (can_redirect and redirectStatus(status) and state.location.items.len > 0) {
                if (redirects == 5) return error.TooManyRedirects;
                const next = try resolveRedirect(self.allocator, current, state.location.items, request.allow_http_loopback);
                self.allocator.free(current);
                current = next;
                redirects += 1;
                continue;
            }
            const owned = try self.allocator.dupe(u8, state.body.bytes());
            return .{ .status = @intCast(status), .body = owned, .allocator = self.allocator };
        }
    }
};

fn set(easy: *c.CURL, option: c.CURLoption, value: anytype) !void {
    if (c.curl_easy_setopt(easy, option, value) != c.CURLE_OK) return error.CurlOption;
}
fn curlFailure(code: c.CURLcode) anyerror {
    // Deliberately never echo curl error strings/buffers or URL/body/header data.
    return switch (code) {
        c.CURLE_OPERATION_TIMEDOUT => error.TimedOut,
        c.CURLE_OUT_OF_MEMORY => error.OutOfMemory,
        c.CURLE_PEER_FAILED_VERIFICATION, c.CURLE_SSL_CONNECT_ERROR, c.CURLE_SSL_CACERT_BADFILE => error.TlsFailure,
        c.CURLE_COULDNT_RESOLVE_HOST, c.CURLE_COULDNT_RESOLVE_PROXY => error.NameResolutionFailed,
        c.CURLE_COULDNT_CONNECT => error.ConnectionFailed,
        else => error.TransportFailed,
    };
}
fn badControls(bytes: []const u8) bool {
    for (bytes) |ch| if (ch < 32 or ch == 127) return true;
    return false;
}
fn validateUrl(url: []const u8, allow_http_loopback: bool) !void {
    if (url.len == 0 or url.len > max_url_bytes or badControls(url) or std.mem.findScalar(u8, url, ' ') != null or std.mem.findScalar(u8, url, '\\') != null) return error.InvalidUrl;
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if (uri.user != null or uri.password != null or uri.fragment != null or uri.port == 0) return error.InvalidUrl;
    const host_component = uri.host orelse return error.InvalidUrl;
    const host = switch (host_component) {
        .raw, .percent_encoded => |text| text,
    };
    if (host.len == 0 or std.mem.findScalar(u8, host, '%') != null) return error.InvalidUrl;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http") and allow_http_loopback and (std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "[::1]"))) return;
    return error.InsecureUrl;
}
fn validateRequest(request: Request) !void {
    try validateUrl(request.url, request.allow_http_loopback);
    if (request.timeout_ms == 0 or std.math.cast(c_long, request.timeout_ms) == null) return error.InvalidTimeout;
    if (request.max_response_bytes > max_body_bytes) return error.InvalidLimit;
    if (request.body) |body| {
        if (request.method != .post or body.len > max_body_bytes) return error.InvalidBody;
    }
    if (request.headers.len > 128) return error.InvalidHeader;
    var total: usize = 0;
    for (request.headers) |header| {
        if (header.name.len == 0 or header.name.len > 256 or header.value.len > max_header_bytes or badControls(header.value)) return error.InvalidHeader;
        for (header.name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != 0x60 and std.mem.findScalar(u8, "!#$%&'*+-.^_|~", ch) == null) return error.InvalidHeader;
        for ([_][]const u8{ "Host", "Content-Length", "Transfer-Encoding", "Connection", "Proxy-Connection" }) |name| if (std.ascii.eqlIgnoreCase(header.name, name)) return error.InvalidHeader;
        total += header.name.len + header.value.len + 4;
        if (total > max_header_bytes) return error.InvalidHeader;
    }
}
fn redirectsAllowed(request: Request) bool {
    if (!request.follow_redirects or request.sensitive or request.method != .get) return false;
    // A denylist cannot recognize a provider's custom secret header. Instead
    // only known noncredential metadata headers may cross a redirect boundary.
    for (request.headers) |header| {
        var safe = false;
        for ([_][]const u8{ "Accept", "Accept-Language", "User-Agent", "If-None-Match", "If-Modified-Since", "Cache-Control" }) |name| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) {
                safe = true;
                break;
            }
        }
        if (!safe) return false;
    }
    return true;
}
fn redirectStatus(status: c_long) bool {
    return status == 301 or status == 302 or status == 303 or status == 307 or status == 308;
}
fn resolveRedirect(a: Allocator, base: [:0]const u8, location: []const u8, allow_http: bool) ![:0]u8 {
    if (location.len == 0 or location.len > max_url_bytes or badControls(location) or std.mem.findScalar(u8, location, '\\') != null) return error.InvalidUrl;
    const handle = c.curl_url() orelse return error.OutOfMemory;
    defer c.curl_url_cleanup(handle);
    if (c.curl_url_set(handle, c.CURLUPART_URL, base.ptr, 0) != c.CURLUE_OK) return error.InvalidUrl;
    const relative = try a.dupeZ(u8, location);
    defer a.free(relative);
    if (c.curl_url_set(handle, c.CURLUPART_URL, relative.ptr, 0) != c.CURLUE_OK) return error.InvalidUrl;
    var resolved: [*c]u8 = null;
    if (c.curl_url_get(handle, c.CURLUPART_URL, &resolved, 0) != c.CURLUE_OK) return error.InvalidUrl;
    defer c.curl_free(resolved);
    const url = std.mem.span(resolved);
    try validateUrl(url, allow_http);
    const old_uri = std.Uri.parse(base) catch return error.InvalidUrl;
    const new_uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if (std.ascii.eqlIgnoreCase(old_uri.scheme, "https") and !std.ascii.eqlIgnoreCase(new_uri.scheme, "https")) return error.InsecureRedirect;
    return a.dupeZ(u8, url);
}
fn freeHeaders(list: ?*c.curl_slist) void {
    var cursor = list;
    while (cursor) |node| : (cursor = node.next) std.crypto.secureZero(u8, std.mem.span(node.data));
    c.curl_slist_free_all(list);
}
fn collectNativeCA(a: Allocator, io: std.Io) !std.ArrayList(u8) {
    var native: std.crypto.Certificate.Bundle = .empty;
    defer native.deinit(a);
    try native.rescan(a, io, .now(io, .real));
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(a);
    var iterator = native.map.iterator();
    while (iterator.next()) |entry| {
        const der = try std.crypto.Certificate.der.Element.parse(native.bytes.items, entry.value_ptr.*);
        const bytes = native.bytes.items[entry.value_ptr.*..der.slice.end];
        const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
        defer a.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, bytes);
        try output.appendSlice(a, "-----BEGIN CERTIFICATE-----\n");
        var pos: usize = 0;
        while (pos < encoded.len) {
            const end = @min(encoded.len, pos + 64);
            try output.appendSlice(a, encoded[pos..end]);
            try output.append(a, '\n');
            pos = end;
        }
        try output.appendSlice(a, "-----END CERTIFICATE-----\n");
    }
    if (output.items.len == 0) return error.NoTrustedCertificates;
    return output;
}

// Avoid realloc leaving copies of sensitive response bytes in freed buffers.
const BodyBuffer = struct {
    storage: []u8 = &.{},
    len: usize = 0,
    fn bytes(self: *const BodyBuffer) []const u8 {
        return self.storage[0..self.len];
    }
    fn clear(self: *BodyBuffer, a: Allocator) void {
        std.crypto.secureZero(u8, self.storage);
        a.free(self.storage);
        self.* = .{};
    }
    fn append(self: *BodyBuffer, a: Allocator, data: []const u8, limit: usize) !void {
        if (data.len > limit - self.len) return error.ResponseTooLarge;
        const needed = self.len + data.len;
        if (needed > self.storage.len) {
            const capacity = @min(limit, @max(needed, @max(4096, self.storage.len * 2)));
            const storage = try a.alloc(u8, capacity);
            @memset(storage, 0);
            @memcpy(storage[0..self.len], self.bytes());
            std.crypto.secureZero(u8, self.storage);
            a.free(self.storage);
            self.storage = storage;
        }
        @memcpy(self.storage[self.len..needed], data);
        self.len = needed;
    }
};
const Transfer = struct {
    allocator: Allocator,
    io: std.Io,
    request: Request,
    deadline: i96,
    body: BodyBuffer = .{},
    location: std.ArrayList(u8) = .empty,
    header_bytes: usize = 0,
    failure: ?anyerror = null,
    fn deinit(self: *Transfer) void {
        self.body.clear(self.allocator);
        std.crypto.secureZero(u8, self.location.items);
        self.location.deinit(self.allocator);
    }
    fn check(self: *const Transfer) !void {
        if (self.request.cancel) |flag| if (flag.load(.acquire)) return error.Canceled;
        if (std.Io.Clock.awake.now(self.io).nanoseconds >= self.deadline) return error.TimedOut;
    }
    fn remainingMillis(self: *const Transfer) !c_long {
        try self.check();
        const ns = self.deadline - std.Io.Clock.awake.now(self.io).nanoseconds;
        if (ns <= 0) return error.TimedOut;
        return @intCast(@min(@as(i96, std.math.maxInt(c_long)), @divTrunc(ns + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
    }
    fn fail(self: *Transfer, err: anyerror) void {
        if (self.failure == null) self.failure = err;
    }
};
fn writeCallback(ptr: [*c]u8, size: usize, count: usize, userdata: ?*anyopaque) callconv(.c) usize {
    const state: *Transfer = @ptrCast(@alignCast(userdata orelse return 0));
    state.check() catch |err| {
        state.fail(err);
        return 0;
    };
    const len = std.math.mul(usize, size, count) catch {
        state.fail(error.ResponseTooLarge);
        return 0;
    };
    state.body.append(state.allocator, ptr[0..len], state.request.max_response_bytes) catch |err| {
        state.fail(err);
        return 0;
    };
    return len;
}
fn headerCallback(ptr: [*c]u8, size: usize, count: usize, userdata: ?*anyopaque) callconv(.c) usize {
    const state: *Transfer = @ptrCast(@alignCast(userdata orelse return 0));
    state.check() catch |err| {
        state.fail(err);
        return 0;
    };
    const len = std.math.mul(usize, size, count) catch {
        state.fail(error.HeaderTooLarge);
        return 0;
    };
    if (len > max_header_bytes - state.header_bytes) {
        state.fail(error.HeaderTooLarge);
        return 0;
    }
    state.header_bytes += len;
    const line = ptr[0..len];
    if (std.mem.startsWith(u8, line, "HTTP/")) {
        state.location.clearRetainingCapacity();
        state.body.clear(state.allocator);
    } else if (std.mem.findScalar(u8, line, ':')) |colon| {
        if (std.ascii.eqlIgnoreCase(line[0..colon], "Location")) {
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r\n");
            if (value.len > max_url_bytes or state.location.items.len != 0) {
                state.fail(error.InvalidRedirect);
                return 0;
            }
            state.location.appendSlice(state.allocator, value) catch |err| {
                state.fail(err);
                return 0;
            };
        }
    }
    return len;
}
fn progressCallback(userdata: ?*anyopaque, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t) callconv(.c) c_int {
    const state: *Transfer = @ptrCast(@alignCast(userdata orelse return 1));
    state.check() catch |err| {
        state.fail(err);
        return 1;
    };
    return 0;
}

test "request URL, headers, body and native timeout validation" {
    try validateRequest(.{ .url = "https://example.invalid/metadata.json" });
    for ([_][]const u8{ "http://example.invalid/", "http://localhost/", "http://127.1/", "http://2130706433/", "http://127.0.0.1.example.invalid/" }) |url| try std.testing.expectError(error.InsecureUrl, validateRequest(.{ .url = url, .allow_http_loopback = true }));
    for ([_][]const u8{ "https://user:pass@example.invalid/", "https://example.invalid/#fragment", "https://example.invalid/\\x", "https://example.invalid/\r\nX: y", "https://%65xample.invalid/" }) |url| try std.testing.expectError(error.InvalidUrl, validateRequest(.{ .url = url }));
    try validateRequest(.{ .url = "http://127.0.0.1:8080/", .allow_http_loopback = true });
    try validateRequest(.{ .url = "http://[::1]:8080/", .allow_http_loopback = true });
    try std.testing.expectError(error.InvalidTimeout, validateRequest(.{ .url = "https://example.invalid/", .timeout_ms = 0 }));
    if (comptime @bitSizeOf(c_long) == 32) try std.testing.expectError(error.InvalidTimeout, validateRequest(.{ .url = "https://example.invalid/", .timeout_ms = std.math.maxInt(u32) }));
    try std.testing.expectError(error.InvalidBody, validateRequest(.{ .url = "https://example.invalid/", .body = "get body" }));
    try std.testing.expectError(error.InvalidLimit, validateRequest(.{ .url = "https://example.invalid/", .max_response_bytes = max_body_bytes + 1 }));
    for ([_]Header{ .{ .name = "X-Key\r\n", .value = "secret" }, .{ .name = "X-Key", .value = "secret\x00injected" }, .{ .name = "X-Key", .value = "secret\r\nInjected: yes" }, .{ .name = "Content-Length", .value = "7" } }) |header| try std.testing.expectError(error.InvalidHeader, validateRequest(.{ .url = "https://example.invalid/", .headers = &.{header} }));
}
test "sensitive headers, explicit sensitive GET and every POST never redirect" {
    try std.testing.expect(redirectsAllowed(.{ .url = "https://example.invalid/", .follow_redirects = true }));
    try std.testing.expect(redirectsAllowed(.{ .url = "https://example.invalid/", .headers = &.{.{ .name = "accept", .value = "application/json" }}, .follow_redirects = true }));
    for ([_][]const u8{ "aUtHoRiZaTiOn", "X-Api-Key", "Cookie", "Proxy-Authorization", "Provider-Custom-Key" }) |name| try std.testing.expect(!redirectsAllowed(.{ .url = "https://example.invalid/", .headers = &.{.{ .name = name, .value = "secret" }}, .follow_redirects = true }));
    try std.testing.expect(!redirectsAllowed(.{ .url = "https://example.invalid/", .sensitive = true, .follow_redirects = true }));
    try std.testing.expect(!redirectsAllowed(.{ .url = "https://example.invalid/", .method = .post, .follow_redirects = true }));
}
fn bufferOom(a: Allocator) !void {
    var buffer: BodyBuffer = .{};
    defer buffer.clear(a);
    try buffer.append(a, "secret", 8192);
    try buffer.append(a, &([_]u8{42} ** 5000), 8192);
    const owned = try a.dupe(u8, buffer.bytes());
    var response: Response = .{ .status = 200, .body = owned, .allocator = a };
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 5006), response.body.len);
}
test "body growth and response ownership are leak-free under OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, bufferOom, .{});
}
test "body exact limit and callback cancellation, deadline, overflow" {
    var buffer: BodyBuffer = .{};
    defer buffer.clear(std.testing.allocator);
    try buffer.append(std.testing.allocator, "abc", 3);
    try std.testing.expectError(error.ResponseTooLarge, buffer.append(std.testing.allocator, "d", 3));
    var cancel = std.atomic.Value(bool).init(true);
    var transfer: Transfer = .{ .allocator = std.testing.allocator, .io = std.testing.io, .request = .{ .url = "https://example.invalid/", .cancel = &cancel }, .deadline = std.math.maxInt(i96) };
    defer transfer.deinit();
    try std.testing.expectEqual(@as(c_int, 1), progressCallback(&transfer, 0, 0, 0, 0));
    try std.testing.expectEqual(error.Canceled, transfer.failure.?);
    cancel.store(false, .release);
    transfer.deadline = 0;
    transfer.failure = null;
    try std.testing.expectEqual(@as(usize, 0), writeCallback(@constCast("x"), 1, 1, &transfer));
    try std.testing.expectEqual(error.TimedOut, transfer.failure.?);
    transfer.deadline = std.math.maxInt(i96);
    transfer.failure = null;
    try std.testing.expectEqual(@as(usize, 0), writeCallback(@constCast("x"), std.math.maxInt(usize), 2, &transfer));
    try std.testing.expectEqual(error.ResponseTooLarge, transfer.failure.?);
}
fn initOom(a: Allocator) !void {
    var client = try Client.init(a, std.testing.io, .{ .proxy = "http://127.0.0.1:1", .ca_bundle = "fixture.pem" });
    defer client.deinit();
    try std.testing.expectEqualStrings("http://127.0.0.1:1", client.proxy);
    try std.testing.expectEqualStrings("fixture.pem", client.ca_path.?);
}
test "client option copies have balanced lifetime under OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, initOom, .{});
    try std.testing.expectError(error.InvalidProxy, Client.init(std.testing.allocator, std.testing.io, .{ .proxy = "proxy\x00" }));
    try std.testing.expectError(error.InvalidCaBundle, Client.init(std.testing.allocator, std.testing.io, .{ .ca_bundle = "" }));
}
test "structured relative redirect resolution and downgrade rejection" {
    try curl.globalInit();
    defer curl.globalDeinit();
    const a = std.testing.allocator;
    const url = try resolveRedirect(a, "https://example.invalid/a/b", "../metadata.json?q=1", false);
    defer a.free(url);
    try std.testing.expectEqualStrings("https://example.invalid/metadata.json?q=1", url);
    try std.testing.expectError(error.InsecureRedirect, resolveRedirect(a, "https://127.0.0.1/a", "http://127.0.0.1/b", true));
    try std.testing.expectError(error.InsecureUrl, resolveRedirect(a, "http://127.0.0.1/a", "http://example.invalid/b", true));
    try std.testing.expectError(error.InvalidUrl, resolveRedirect(a, "https://example.invalid/", "https://user:password@example.invalid/", false));
}
fn fixtureBase(a: Allocator) ![]u8 {
    return std.testing.environ.getAlloc(a, "HTTP_TRANSPORT_TEST_URL") catch return error.SkipZigTest;
}
fn fixtureUrl(a: Allocator, base: []const u8, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}{s}", .{ base, path });
}
fn performOom(a: Allocator, client: *const Client, url: []const u8) !void {
    var failing_client = client.*;
    failing_client.allocator = a;
    var response = try failing_client.execute(.{ .url = url, .allow_http_loopback = true, .headers = &.{.{ .name = "X-Api-Key", .value = "fixture-key" }} });
    defer response.deinit();
    try std.testing.expectEqualStrings("{\"ok\":true}", response.body);
}
test "loopback GET, POST binary bytes, auth headers, statuses, empty body and execute OOM" {
    const a = std.testing.allocator;
    const base = try fixtureBase(a);
    defer a.free(base);
    var client = try Client.init(a, std.testing.io, .{});
    defer client.deinit();
    const get = try fixtureUrl(a, base, "/get");
    defer a.free(get);
    try std.testing.expectError(error.InsecureUrl, client.execute(.{ .url = get }));
    var response = try client.execute(.{ .url = get, .allow_http_loopback = true });
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("{\"ok\":true}", response.body);
    try std.testing.checkAllAllocationFailures(a, performOom, .{ &client, get });
    const post = try fixtureUrl(a, base, "/post");
    defer a.free(post);
    var echo = try client.execute(.{ .method = .post, .url = post, .body = "one\x00two", .allow_http_loopback = true, .headers = &.{.{ .name = "Content-Type", .value = "application/octet-stream" }} });
    defer echo.deinit();
    try std.testing.expectEqual(@as(u16, 201), echo.status);
    try std.testing.expectEqualStrings("one\x00two", echo.body);
    const auth = try fixtureUrl(a, base, "/auth");
    defer a.free(auth);
    var signed = try client.execute(.{ .url = auth, .allow_http_loopback = true, .headers = &.{.{ .name = "Authorization", .value = "Bearer fixture-secret" }} });
    defer signed.deinit();
    try std.testing.expectEqual(@as(u16, 200), signed.status);
    const err_url = try fixtureUrl(a, base, "/error");
    defer a.free(err_url);
    var failed = try client.execute(.{ .url = err_url, .allow_http_loopback = true });
    defer failed.deinit();
    try std.testing.expectEqual(@as(u16, 429), failed.status);
    try std.testing.expectEqualStrings("{\"error\":\"fixture-limit\"}", failed.body);
    const empty = try fixtureUrl(a, base, "/empty");
    defer a.free(empty);
    var blank = try client.execute(.{ .url = empty, .allow_http_loopback = true, .max_response_bytes = 0 });
    defer blank.deinit();
    try std.testing.expectEqual(@as(u16, 204), blank.status);
    try std.testing.expectEqual(@as(usize, 0), blank.body.len);
}
test "loopback metadata redirects bounded, secret redirects blocked, external HTTP rejected before dispatch" {
    const a = std.testing.allocator;
    const base = try fixtureBase(a);
    defer a.free(base);
    var client = try Client.init(a, std.testing.io, .{});
    defer client.deinit();
    const redirect = try fixtureUrl(a, base, "/redirect");
    defer a.free(redirect);
    var raw = try client.execute(.{ .url = redirect, .allow_http_loopback = true });
    defer raw.deinit();
    try std.testing.expectEqual(@as(u16, 302), raw.status);
    var followed = try client.execute(.{ .url = redirect, .allow_http_loopback = true, .follow_redirects = true });
    defer followed.deinit();
    try std.testing.expectEqualStrings("{\"ok\":true}", followed.body);
    const secret = try fixtureUrl(a, base, "/secret-redirect");
    defer a.free(secret);
    for ([_][]const u8{ "aUtHoRiZaTiOn", "X-Api-Key", "Cookie", "Provider-Custom-Key" }) |name| {
        var guarded = try client.execute(.{ .url = secret, .allow_http_loopback = true, .follow_redirects = true, .headers = &.{.{ .name = name, .value = "fixture-secret" }} });
        defer guarded.deinit();
        try std.testing.expectEqual(@as(u16, 302), guarded.status);
    }
    var sensitive = try client.execute(.{ .url = secret, .allow_http_loopback = true, .sensitive = true, .follow_redirects = true });
    defer sensitive.deinit();
    try std.testing.expectEqual(@as(u16, 302), sensitive.status);
    var post = try client.execute(.{ .url = secret, .method = .post, .body = "fixture-secret", .allow_http_loopback = true, .follow_redirects = true });
    defer post.deinit();
    try std.testing.expectEqual(@as(u16, 307), post.status);
    const stats = try fixtureUrl(a, base, "/stats");
    defer a.free(stats);
    var counts = try client.execute(.{ .url = stats, .allow_http_loopback = true });
    defer counts.deinit();
    try std.testing.expectEqualStrings("0", counts.body);
    const external = try fixtureUrl(a, base, "/external-redirect");
    defer a.free(external);
    try std.testing.expectError(error.InsecureUrl, client.execute(.{ .url = external, .allow_http_loopback = true, .follow_redirects = true }));
    const userinfo = try fixtureUrl(a, base, "/userinfo-redirect");
    defer a.free(userinfo);
    try std.testing.expectError(error.InvalidUrl, client.execute(.{ .url = userinfo, .allow_http_loopback = true, .follow_redirects = true }));
    const loop = try fixtureUrl(a, base, "/loop");
    defer a.free(loop);
    try std.testing.expectError(error.TooManyRedirects, client.execute(.{ .url = loop, .allow_http_loopback = true, .follow_redirects = true }));
}
fn cancelSoon(io: std.Io, flag: *std.atomic.Value(bool)) void {
    io.sleep(.fromMilliseconds(40), .awake) catch {};
    flag.store(true, .release);
}
test "loopback response limits, truncation, total timeout, deadline and mid-transfer cancellation" {
    const a = std.testing.allocator;
    const base = try fixtureBase(a);
    defer a.free(base);
    var client = try Client.init(a, std.testing.io, .{});
    defer client.deinit();
    const large = try fixtureUrl(a, base, "/large");
    defer a.free(large);
    try std.testing.expectError(error.ResponseTooLarge, client.execute(.{ .url = large, .allow_http_loopback = true, .max_response_bytes = 4096 }));
    const truncated = try fixtureUrl(a, base, "/truncated");
    defer a.free(truncated);
    try std.testing.expectError(error.TransportFailed, client.execute(.{ .url = truncated, .allow_http_loopback = true }));
    const slow = try fixtureUrl(a, base, "/slow");
    defer a.free(slow);
    try std.testing.expectError(error.TimedOut, client.execute(.{ .url = slow, .allow_http_loopback = true, .timeout_ms = 80 }));
    try std.testing.expectError(error.TimedOut, client.execute(.{ .url = slow, .allow_http_loopback = true, .deadline_ns = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 80 * std.time.ns_per_ms }));
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Canceled, client.execute(.{ .url = slow, .allow_http_loopback = true, .cancel = &cancel }));
    try std.testing.expectError(error.TimedOut, client.execute(.{ .url = slow, .allow_http_loopback = true, .deadline_ns = 0 }));
    cancel.store(false, .release);
    const worker = try std.Thread.spawn(.{}, cancelSoon, .{ std.testing.io, &cancel });
    defer worker.join();
    try std.testing.expectError(error.Canceled, client.execute(.{ .url = slow, .allow_http_loopback = true, .cancel = &cancel, .timeout_ms = 3000 }));
}

test "public-address guard rejects explicit proxies before transfer and queue admission" {
    const a = std.testing.allocator;
    try curl.globalInit();
    defer curl.globalDeinit();
    var client = try Client.init(a, std.testing.io, .{ .proxy = "http://127.0.0.1:1" });
    defer client.deinit();
    try std.testing.expectError(error.UnsupportedProxyWithPublicAddressGuard, client.execute(.{
        .url = "https://example.invalid/",
        .require_public_address = true,
    }));
    const downloader = @import("downloader.zig");
    const service = try downloader.Service.init(a, std.testing.io, 1);
    defer service.deinit();
    try std.testing.expectError(error.UnsupportedProxyWithPublicAddressGuard, service.submit(.{
        .url = "https://example.invalid/",
        .proxy = "http://127.0.0.1:1",
        .require_public_address = true,
    }));
}

test "public-address guard blocks actual resolved loopback sockets in both transports" {
    const a = std.testing.allocator;
    const base = std.testing.environ.getAlloc(a, "PUBLIC_NETWORK_GUARD_TEST_URL") catch return error.SkipZigTest;
    defer a.free(base);
    const ipv6 = std.testing.environ.getAlloc(a, "PUBLIC_NETWORK_GUARD_TEST_V6_URL") catch null;
    defer if (ipv6) |value| a.free(value);
    try curl.globalInit();
    defer curl.globalDeinit();
    var client = try Client.init(a, std.testing.io, .{});
    defer client.deinit();
    const downloader = @import("downloader.zig");
    const service = try downloader.Service.init(a, std.testing.io, 1);
    defer service.deinit();
    const secure = try std.fmt.allocPrint(a, "https{s}/must-not-request", .{base[4..]});
    defer a.free(secure);
    const plain = try fixtureUrl(a, base, "/must-not-request");
    defer a.free(plain);
    const uri = try std.Uri.parse(base);
    const port = uri.port orelse return error.InvalidFixture;
    const mapped = try std.fmt.allocPrint(a, "https://[::ffff:127.0.0.1]:{d}/must-not-request", .{port});
    defer a.free(mapped);
    const resolved = try std.fmt.allocPrint(a, "https://localhost:{d}/must-not-request", .{port});
    defer a.free(resolved);
    for ([_]?[]const u8{ plain, secure, mapped, resolved, ipv6 }) |maybe_url| {
        const target = maybe_url orelse continue;
        try std.testing.expectError(error.NonPublicAddress, client.execute(.{
            .url = target,
            .allow_http_loopback = true,
            .require_public_address = true,
            .timeout_ms = 1000,
        }));
        const task = try service.submit(.{ .url = target, .require_public_address = true, .timeout_ms = 1000 });
        defer task.release() catch unreachable;
        const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 5 * std.time.ns_per_s;
        while (true) {
            const snapshot = task.snapshot();
            if (downloader.terminal(snapshot.progress.phase)) {
                try std.testing.expectEqual(downloader.Phase.failed, snapshot.progress.phase);
                try std.testing.expectEqual(error.NonPublicAddress, snapshot.failure.?);
                try std.testing.expectEqual(@as(u16, 0), snapshot.http_status);
                try std.testing.expect(snapshot.result == null);
                break;
            }
            if (std.Io.Clock.awake.now(std.testing.io).nanoseconds >= deadline) return error.TestTimeout;
            try std.testing.io.sleep(.fromMilliseconds(5), .awake);
        }
    }
}

test "guarded downloader cannot reuse an unguarded persistent loopback connection" {
    const a = std.testing.allocator;
    const base = try fixtureBase(a);
    defer a.free(base);
    try curl.globalInit();
    defer curl.globalDeinit();
    const downloader = @import("downloader.zig");
    const service = try downloader.Service.init(a, std.testing.io, 1);
    defer service.deinit();
    const ordinary = try fixtureUrl(a, base, "/get");
    defer a.free(ordinary);
    const blocked = try fixtureUrl(a, base, "/must-not-request");
    defer a.free(blocked);
    for ([_]bool{ false, true }) |guarded| {
        const task = try service.submit(.{
            .url = if (guarded) blocked else ordinary,
            .proxy = if (guarded) null else "",
            .require_public_address = guarded,
            .timeout_ms = 1000,
        });
        defer task.release() catch unreachable;
        const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 5 * std.time.ns_per_s;
        while (true) {
            const snapshot = task.snapshot();
            if (downloader.terminal(snapshot.progress.phase)) {
                if (guarded) {
                    try std.testing.expectEqual(error.NonPublicAddress, snapshot.failure.?);
                    try std.testing.expectEqual(@as(u16, 0), snapshot.http_status);
                } else {
                    try std.testing.expect(snapshot.failure == null);
                    try std.testing.expectEqual(downloader.Phase.complete, snapshot.progress.phase);
                }
                break;
            }
            if (std.Io.Clock.awake.now(std.testing.io).nanoseconds >= deadline) return error.TestTimeout;
            try std.testing.io.sleep(.fromMilliseconds(5), .awake);
        }
    }
    var client = try Client.init(a, std.testing.io, .{});
    defer client.deinit();
    const stats = try fixtureUrl(a, base, "/stats");
    defer a.free(stats);
    var response = try client.execute(.{ .url = stats, .allow_http_loopback = true });
    defer response.deinit();
    try std.testing.expectEqualStrings("0", response.body);
}

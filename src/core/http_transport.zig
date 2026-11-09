//! Synchronous HTTP for ordinary worker OS threads, never the UI thread.
//! Client owns a balanced libcurl global reference and copied options. Join all
//! execute calls before deinit. Concurrent execute calls require thread-safe Io
//! and allocator. Requests borrow inputs until execute returns; responses own
//! bytes (including non-2xx bodies), and deinit wipes them. No cache or logging.
const std = @import("std");
const curl = @import("curl");
const support = @import("curl_support.zig");
const network_proxy = @import("proxy_policy.zig");
const c = curl.libcurl;
const Allocator = std.mem.Allocator;
const max_url_bytes = 16 * 1024;
const max_header_bytes = 64 * 1024;
const max_body_bytes = 64 * 1024 * 1024;
pub const max_binary_response_bytes = 512 * 1024 * 1024;

pub const Header = struct { name: []const u8, value: []const u8 };
pub const Method = enum { get, post };
pub const Progress = struct { received: u64 = 0, total: ?u64 = null, bytes_per_second: f64 = 0, complete: bool = false, failure: ?anyerror = null };
pub const Observer = struct { context: ?*anyopaque = null, report: *const fn (?*anyopaque, Progress) void };
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
    /// Optional allocation-free observer, called on the execute caller thread.
    observer: ?Observer = null,
    /// Test-only exception: exact 127.0.0.1 / [::1], not DNS aliases.
    allow_http_loopback: bool = false,
    /// GET metadata only, at most five validated redirects. Disabled for POST,
    /// sensitive requests, and every non-allowlisted request header.
    follow_redirects: bool = false,
    sensitive: bool = false,
    /// Direct routes guard resolved sockets; proxies retain target URL checks.
    require_public_address: bool = false,
};
pub const Options = struct {
    /// Null captures launcher defaults; empty forces direct; explicit ignores bypass.
    proxy: ?[]const u8 = null,
    /// Optional task policy, copied by init (including draft credential overrides).
    proxy_policy: ?*const network_proxy.Policy = null,
    /// PEM file path. Null collects the native trust store at worker init.
    ca_bundle: ?[]const u8 = null,
    /// Borrowed until every Client using it is deinitialized.
    connections: ?*ConnectionPool = null,
};
pub const Response = struct {
    status: u16,
    /// Prefix view into allocation; release through deinit, not allocator.free.
    body: []u8,
    allocator: Allocator,
    /// Bounded response metadata; owned independently of the body.
    cache_headers: @import("http_cache_headers.zig").Owned = .{},
    source: enum { network, fresh_cache, revalidated } = .network,
    allocation: []u8,

    /// Return bytes owned by a; caller must wipe sensitive bytes before a.free.
    /// Same-allocator storage transfers directly if exact-sized or resize succeeds.
    /// Otherwise copy safely; allocation failure preserves this response. On
    /// success body is empty and deinit remains valid (status is unchanged).
    pub fn takeBody(self: *Response, a: Allocator) ![]u8 {
        const storage = self.allocation;
        const len = self.body.len;
        if (len == 0) {
            std.crypto.secureZero(u8, storage);
            self.allocator.free(storage);
            self.body = &.{};
            self.allocation = &.{};
            return &.{};
        }
        if (a.ptr == self.allocator.ptr and a.vtable == self.allocator.vtable) {
            std.crypto.secureZero(u8, storage[len..]);
            if (storage.len == len or self.allocator.resize(storage, len)) {
                self.body = &.{};
                self.allocation = &.{};
                return storage.ptr[0..len];
            }
        }
        const owned = try a.dupe(u8, self.body);
        std.crypto.secureZero(u8, storage);
        self.allocator.free(storage);
        self.body = &.{};
        self.allocation = &.{};
        return owned;
    }

    pub fn deinit(self: *Response) void {
        self.cache_headers.deinit(self.allocator);
        const storage = self.allocation;
        std.crypto.secureZero(u8, storage);
        self.allocator.free(storage);
        self.* = undefined;
    }
};

pub const Client = struct {
    allocator: Allocator,
    io: std.Io,
    policy: network_proxy.Policy,
    ca_path: ?[:0]u8,
    ca_pem: std.ArrayList(u8),
    pool: *ConnectionPool,
    owns_pool: bool,

    pub fn init(a: Allocator, io: std.Io, options: Options) !Client {
        var policy = if (options.proxy_policy) |value| try value.clone(a) else try network_proxy.capture(a, io, options.proxy);
        errdefer policy.deinit();
        if (options.ca_bundle) |path| {
            if (path.len == 0 or path.len > max_url_bytes or badControls(path)) return error.InvalidCaBundle;
        }
        const ca_path = if (options.ca_bundle) |path| try a.dupeSentinel(u8, path, 0) else null;
        errdefer if (ca_path) |path| a.free(path);
        var ca_pem: std.ArrayList(u8) = if (ca_path == null) try @import("curl_support.zig").collectNativeCA(a, io) else .empty;
        errdefer ca_pem.deinit(a);
        // Vendored libcurl 8.19 supports thread-safe global init/cleanup. Its
        // global refcount composes with the downloader's app-owned reference.
        try curl.globalInit();
        errdefer curl.globalDeinit();
        const pool = options.connections orelse try a.create(ConnectionPool);
        if (options.connections == null) pool.* = .{};
        return .{ .allocator = a, .io = io, .policy = policy, .ca_path = ca_path, .ca_pem = ca_pem, .pool = pool, .owns_pool = options.connections == null };
    }

    pub fn deinit(self: *Client) void {
        if (self.owns_pool) {
            self.pool.deinit();
            self.allocator.destroy(self.pool);
        }
        curl.globalDeinit();
        self.policy.deinit();
        if (self.ca_path) |path| self.allocator.free(path);
        self.ca_pem.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn execute(self: *const Client, request: Request) anyerror!Response {
        return self.executeBounded(request, max_body_bytes);
    }

    /// Explicit buffered binary GET. Callers retain responsibility for artifact
    /// origin and digest verification. Ordinary execute keeps its JSON/auth ceiling.
    /// Shares URL/header checks, redirects, deadlines, cancellation and observers.
    pub fn executeBinary(self: *const Client, request: Request) anyerror!Response {
        if (request.method != .get or request.body != null) return error.InvalidBinaryRequest;
        return self.executeBounded(request, max_binary_response_bytes);
    }

    fn executeBounded(self: *const Client, request: Request, response_limit: usize) anyerror!Response {
        try validateRequestBounded(request, response_limit);
        const start = std.Io.Clock.awake.now(self.io).nanoseconds;
        const deadline = @min(request.deadline_ns orelse std.math.maxInt(i96), start + @as(i96, request.timeout_ms) * std.time.ns_per_ms);
        var state: Transfer = .{ .allocator = self.allocator, .io = self.io, .request = request, .deadline = deadline, .sample_ns = start };
        defer state.deinit();
        return self.executeTransfer(request, &state) catch |err| {
            state.publishTerminal(err);
            return err;
        };
    }

    fn executeTransfer(self: *const Client, request: Request, state: *Transfer) anyerror!Response {
        try state.check();
        var current = try self.allocator.dupeSentinel(u8, request.url, 0);
        defer self.allocator.free(current);
        var headers: ?*c.curl_slist = null;
        defer support.freeHeaders(headers);
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
            var connection = try self.pool.acquire(request.require_public_address);
            defer connection.release();
            const easy = connection.easy;
            try set(easy, c.CURLOPT_URL, current.ptr);
            try set(easy, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
            try set(easy, c.CURLOPT_VERBOSE, @as(c_long, 0));
            try set(easy, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 0));
            // HTTP is enabled only after URL validation of each exact loopback
            // hop; libcurl itself never automatically follows any redirect.
            try set(easy, c.CURLOPT_PROTOCOLS_STR, @as([*:0]const u8, if (request.allow_http_loopback) "https,http" else "https"));
            try set(easy, c.CURLOPT_REDIR_PROTOCOLS_STR, @as([*:0]const u8, "https"));
            var route = try self.policy.resolve(self.io, current);
            defer route.deinit();
            if (request.require_public_address and route.proxy.len != 0) try network_proxy.guardTarget(self.allocator, current);
            try state.check();
            try support.configure(easy, &route, self.ca_path, self.ca_pem.items, request.require_public_address, &state.failure);
            // This transport partitions guarded sockets from ordinary sockets.
            // Every newly opened direct socket still runs the public-address callback.
            try set(easy, c.CURLOPT_FRESH_CONNECT, @as(c_long, 0));
            try set(easy, c.CURLOPT_FORBID_REUSE, @as(c_long, 0));
            const remaining = try state.remainingMillis();
            try set(easy, c.CURLOPT_TIMEOUT_MS, remaining);
            try set(easy, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, @min(remaining, 30_000)));
            try set(easy, c.CURLOPT_WRITEFUNCTION, &writeCallback);
            try set(easy, c.CURLOPT_WRITEDATA, state);
            try set(easy, c.CURLOPT_HEADERFUNCTION, &headerCallback);
            try set(easy, c.CURLOPT_HEADERDATA, state);
            try set(easy, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
            try set(easy, c.CURLOPT_XFERINFOFUNCTION, &progressCallback);
            try set(easy, c.CURLOPT_XFERINFODATA, state);
            if (headers) |list| try set(easy, c.CURLOPT_HTTPHEADER, list);
            if (request.method == .post) {
                const body = request.body orelse "";
                try set(easy, c.CURLOPT_POST, @as(c_long, 1));
                try set(easy, c.CURLOPT_POSTFIELDSIZE_LARGE, @as(c.curl_off_t, @intCast(body.len)));
                try set(easy, c.CURLOPT_POSTFIELDS, body.ptr);
            } else try set(easy, c.CURLOPT_HTTPGET, @as(c_long, 1));
            try state.check();
            const result = c.curl_easy_perform(easy);
            if (state.failure) |err| return @as(anyerror!Response, err);
            try state.check();
            if (result != c.CURLE_OK) return @as(anyerror!Response, curlFailure(result));
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
            state.publishTerminal(null);
            var response = state.body.takeResponse(self.allocator, @intCast(status));
            response.cache_headers = state.cache_headers;
            state.cache_headers = .{};
            return response;
        }
    }
};

// Each slot is independently borrowed. Busy pools fall back to an ephemeral
// handle instead of serializing callers or extending cancellation latency.
// Guarded and unguarded sockets never occupy the same connection cache.
test {
    _ = @import("http_cache_client.zig");
}

pub const ConnectionPool = struct {
    /// Heap-stable pool; owns a libcurl reference until all borrowers have joined.
    pub fn create(a: Allocator) !*ConnectionPool {
        try curl.globalInit();
        errdefer curl.globalDeinit();
        const result = try a.create(ConnectionPool);
        result.* = .{};
        return result;
    }
    pub fn destroy(self: *ConnectionPool, a: Allocator) void {
        self.deinit();
        a.destroy(self);
        curl.globalDeinit();
    }
    const Slot = struct {
        busy: std.atomic.Value(bool) = .init(false),
        easy: ?*c.CURL = null,
    };
    slots: [8]Slot = @splat(.{}),
    const Lease = struct {
        easy: *c.CURL,
        slot: ?*Slot,
        fn release(self: *Lease) void {
            if (self.slot) |slot| {
                // Drop borrowed header/body/callback pointers, retain connections.
                c.curl_easy_reset(self.easy);
                slot.busy.store(false, .release);
            } else c.curl_easy_cleanup(self.easy);
        }
    };
    fn acquire(self: *ConnectionPool, guarded: bool) !Lease {
        const start: usize = if (guarded) 4 else 0;
        for (self.slots[start..][0..4]) |*slot| {
            if (slot.busy.cmpxchgStrong(false, true, .acquire, .monotonic) != null) continue;
            errdefer slot.busy.store(false, .release);
            if (slot.easy == null) slot.easy = c.curl_easy_init() orelse return error.CurlInit;
            return .{ .easy = slot.easy.?, .slot = slot };
        }
        return .{ .easy = c.curl_easy_init() orelse return error.CurlInit, .slot = null };
    }
    fn deinit(self: *ConnectionPool) void {
        for (&self.slots) |*slot| {
            std.debug.assert(!slot.busy.load(.acquire));
            if (slot.easy) |easy| c.curl_easy_cleanup(easy);
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
    return validateRequestBounded(request, max_body_bytes);
}
pub fn validateRequestBounded(request: Request, response_limit: usize) !void {
    try validateUrl(request.url, request.allow_http_loopback);
    if (request.timeout_ms == 0 or std.math.cast(c_long, request.timeout_ms) == null) return error.InvalidTimeout;
    if (request.max_response_bytes > response_limit) return error.InvalidLimit;
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
    const relative = try a.dupeSentinel(u8, location, 0);
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
    return a.dupeSentinel(u8, url, 0);
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
    fn takeResponse(self: *BodyBuffer, a: Allocator, status: u16) Response {
        const response: Response = .{ .status = status, .body = self.storage[0..self.len], .allocator = a, .allocation = self.storage };
        self.* = .{};
        return response;
    }
    fn append(self: *BodyBuffer, a: Allocator, data: []const u8, limit: usize) !void {
        if (self.len > limit or data.len > limit - self.len) return error.ResponseTooLarge;
        const needed = self.len + data.len;
        if (needed > self.storage.len) {
            const doubled = std.math.mul(usize, self.storage.len, 2) catch limit;
            const capacity = @min(limit, @max(needed, @max(4096, doubled)));
            const previous_capacity = self.storage.len;
            if (a.resize(self.storage, capacity)) {
                self.storage = self.storage.ptr[0..capacity];
                @memset(self.storage[previous_capacity..], 0);
            } else {
                const storage = try a.alloc(u8, capacity);
                @memset(storage, 0);
                @memcpy(storage[0..self.len], self.bytes());
                std.crypto.secureZero(u8, self.storage);
                a.free(self.storage);
                self.storage = storage;
            }
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
    cache_headers: @import("http_cache_headers.zig").Owned = .{},
    header_bytes: usize = 0,
    failure: ?anyerror = null,
    progress: Progress = .{},
    sample_ns: i96 = 0,
    sample_received: u64 = 0,
    fn publishTerminal(self: *Transfer, failure: ?anyerror) void {
        self.progress.failure = failure;
        self.progress.complete = failure == null;
        self.progress.bytes_per_second = 0;
        if (self.request.observer) |observer| observer.report(observer.context, self.progress);
    }
    fn deinit(self: *Transfer) void {
        self.cache_headers.deinit(self.allocator);
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
        state.cache_headers.clear();
        state.location.clearRetainingCapacity();
        state.body.clear(state.allocator);
    } else if (std.mem.findScalar(u8, line, ':')) |colon| {
        state.cache_headers.append(state.allocator, line[0..colon], std.mem.trim(u8, line[colon + 1 ..], " \t\r\n")) catch |err| {
            state.fail(err);
            return 0;
        };
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
fn progressCallback(userdata: ?*anyopaque, total: c.curl_off_t, received: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t) callconv(.c) c_int {
    const state: *Transfer = @ptrCast(@alignCast(userdata orelse return 1));
    state.check() catch |err| {
        state.fail(err);
        return 1;
    };
    if (state.request.observer) |observer| {
        const now = std.Io.Clock.awake.now(state.io).nanoseconds;
        const bytes: u64 = @intCast(@max(0, received));
        const elapsed = now - state.sample_ns;
        if (elapsed > 0 and (elapsed >= 100 * std.time.ns_per_ms or (state.progress.bytes_per_second == 0 and bytes > state.sample_received))) {
            state.progress.bytes_per_second = @as(f64, @floatFromInt(bytes -| state.sample_received)) * std.time.ns_per_s / @as(f64, @floatFromInt(elapsed));
            state.sample_ns = now;
            state.sample_received = bytes;
        }
        state.progress.received = bytes;
        state.progress.total = if (total > 0) @intCast(total) else null;
        observer.report(observer.context, state.progress);
    }
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
    try buffer.append(a, &@as([5000]u8, @splat(42)), 8192);
    var response = buffer.takeResponse(a, 200);
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 5006), response.body.len);
}
test "body growth and response ownership are leak-free under OOM" {
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, bufferOom, .{});
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
    try std.testing.expectEqualStrings("http://127.0.0.1:1", client.policy.explicit.?);
    try std.testing.expectEqualStrings("fixture.pem", client.ca_path.?);
}
test "client option copies have balanced lifetime under OOM" {
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, initOom, .{});
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
test "persistent HTTP connection retains metadata and never bypasses public guard" {
    const a = std.testing.allocator;
    const base = try fixtureBase(a);
    defer a.free(base);
    var client = try Client.init(a, std.testing.io, .{ .proxy = "" });
    defer client.deinit();
    const url = try fixtureUrl(a, base, "/connection");
    defer a.free(url);
    var first = try client.execute(.{ .url = url, .allow_http_loopback = true });
    defer first.deinit();
    var second = try client.execute(.{ .url = url, .allow_http_loopback = true });
    defer second.deinit();
    try std.testing.expectEqualStrings(first.body, second.body);
    try std.testing.expectEqualStrings("max-age=60", second.cache_headers.view().cache_control.?);
    try std.testing.expectEqualStrings("Accept-Encoding", second.cache_headers.view().vary.?);
    try std.testing.expectError(error.NonPublicAddress, client.execute(.{ .url = url, .allow_http_loopback = true, .require_public_address = true }));
}

test "shared connections survive successive worker clients" {
    const a = std.testing.allocator;
    const base = try fixtureBase(a);
    defer a.free(base);
    const url = try fixtureUrl(a, base, "/connection");
    defer a.free(url);
    const pool = try ConnectionPool.create(a);
    defer pool.destroy(a);
    var first = response: {
        var client = try Client.init(a, std.testing.io, .{ .proxy = "", .connections = pool });
        defer client.deinit();
        break :response try client.execute(.{ .url = url, .allow_http_loopback = true });
    };
    defer first.deinit();
    var client = try Client.init(a, std.testing.io, .{ .proxy = "", .connections = pool });
    defer client.deinit();
    var second = try client.execute(.{ .url = url, .allow_http_loopback = true });
    defer second.deinit();
    try std.testing.expectEqualStrings(first.body, second.body);
    try std.testing.expectError(error.NonPublicAddress, client.execute(.{ .url = url, .allow_http_loopback = true, .require_public_address = true }));
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
    try @import("test_allocations").checkAllAllocationFailures(a, performOom, .{ &client, get });
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
test "binary API accepts loader limit while ordinary and auth requests retain their ceiling" {
    const a = std.testing.allocator;
    var client = try Client.init(a, std.testing.io, .{});
    defer client.deinit();
    var cancel = std.atomic.Value(bool).init(true);
    const request: Request = .{ .url = "https://example.invalid/installer.jar", .max_response_bytes = max_binary_response_bytes, .cancel = &cancel };
    try std.testing.expectError(error.InvalidLimit, client.execute(request));
    try std.testing.expectError(error.Canceled, client.executeBinary(request));
    var invalid = request;
    invalid.max_response_bytes += 1;
    try std.testing.expectError(error.InvalidLimit, client.executeBinary(invalid));
    invalid = request;
    invalid.method = .post;
    try std.testing.expectError(error.InvalidBinaryRequest, client.executeBinary(invalid));
    invalid = request;
    invalid.body = "unexpected";
    try std.testing.expectError(error.InvalidBinaryRequest, client.executeBinary(invalid));
    invalid = request;
    invalid.headers = &.{.{ .name = "Authorization", .value = "Bearer fixture-secret" }};
    try std.testing.expectError(error.InvalidLimit, client.execute(invalid));
    invalid = request;
    invalid.url = "http://example.invalid/installer.jar";
    try std.testing.expectError(error.InsecureUrl, client.executeBinary(invalid));
    invalid = request;
    invalid.headers = &.{.{ .name = "Host", .value = "example.invalid" }};
    try std.testing.expectError(error.InvalidHeader, client.executeBinary(invalid));
    cancel.store(false, .release);
    invalid = request;
    invalid.deadline_ns = 0;
    try std.testing.expectError(error.TimedOut, client.executeBinary(invalid));
}

test "loopback binary transfers exceed ordinary ceiling and enforce declared and streaming response bounds" {
    const Capture = struct {
        latest: Progress = .{},
        fn report(raw: ?*anyopaque, progress: Progress) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.latest = progress;
        }
    };
    const a = std.testing.allocator;
    const base = try fixtureBase(a);
    defer a.free(base);
    var client = try Client.init(a, std.testing.io, .{});
    defer client.deinit();
    for ([_][]const u8{ "/binary-large", "/binary-large-stream" }) |route| {
        const url = try fixtureUrl(a, base, route);
        defer a.free(url);
        // The actual production API must receive >64MiB, even though the loader
        // requests a 512MiB upper bound for installations of unknown size.
        var capture: Capture = .{};
        var response = try client.executeBinary(.{ .url = url, .allow_http_loopback = true, .max_response_bytes = max_binary_response_bytes, .observer = .{ .context = &capture, .report = Capture.report } });
        defer response.deinit();
        try std.testing.expectEqual(@as(u16, 200), response.status);
        try std.testing.expectEqual(@as(usize, 65 * 1024 * 1024), response.body.len);
        try std.testing.expect(std.mem.allEqual(u8, response.body, 98));
        try std.testing.expect(capture.latest.complete);
        try std.testing.expect(capture.latest.failure == null);
        try std.testing.expectEqual(@as(u64, response.body.len), capture.latest.received);
        try std.testing.expectEqual(@as(f64, 0), capture.latest.bytes_per_second);
        try std.testing.expectError(error.ResponseTooLarge, client.executeBinary(.{ .url = url, .allow_http_loopback = true, .max_response_bytes = max_body_bytes }));
        try std.testing.expectError(error.ResponseTooLarge, client.execute(.{ .url = url, .allow_http_loopback = true, .max_response_bytes = max_body_bytes }));
    }
    const small = try fixtureUrl(a, base, "/get");
    defer a.free(small);
    var default = try client.executeBinary(.{ .url = small, .allow_http_loopback = true });
    defer default.deinit();
    try std.testing.expectEqualStrings("{\"ok\":true}", default.body);
}

test "binary requests preserve mid-transfer cancellation deadline and public-address protection" {
    const a = std.testing.allocator;
    const base = try fixtureBase(a);
    defer a.free(base);
    var client = try Client.init(a, std.testing.io, .{});
    defer client.deinit();
    const slow = try fixtureUrl(a, base, "/slow");
    defer a.free(slow);
    try std.testing.expectError(error.TimedOut, client.executeBinary(.{ .url = slow, .allow_http_loopback = true, .max_response_bytes = max_binary_response_bytes, .timeout_ms = 80 }));
    try std.testing.expectError(error.TimedOut, client.executeBinary(.{ .url = slow, .allow_http_loopback = true, .max_response_bytes = max_binary_response_bytes, .deadline_ns = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 80 * std.time.ns_per_ms }));
    var cancel = std.atomic.Value(bool).init(false);
    const worker = try std.Thread.spawn(.{}, cancelSoon, .{ std.testing.io, &cancel });
    defer worker.join();
    try std.testing.expectError(error.Canceled, client.executeBinary(.{ .url = slow, .allow_http_loopback = true, .max_response_bytes = max_binary_response_bytes, .cancel = &cancel, .timeout_ms = 3000 }));
    try std.testing.expectError(error.NonPublicAddress, client.executeBinary(.{ .url = slow, .allow_http_loopback = true, .max_response_bytes = max_binary_response_bytes, .require_public_address = true }));
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

test "proxied public-address requests reject private targets before connecting" {
    const a = std.testing.allocator;
    try curl.globalInit();
    defer curl.globalDeinit();
    var client = try Client.init(a, std.testing.io, .{ .proxy = "http://127.0.0.1:1" });
    defer client.deinit();
    const downloader = @import("downloader.zig");
    var budget = try downloader.Budget.init(std.testing.io, 1);
    defer budget.deinit();
    const service = try downloader.Service.init(a, std.testing.io, &budget, 1);
    defer service.deinit();
    for ([_][]const u8{ "https://127.0.0.1/", "https://2130706433/", "https://[::1]/", "https://localhost/", "https://server.internal/" }) |url| {
        try std.testing.expectError(error.NonPublicAddress, client.execute(.{ .url = url, .require_public_address = true }));
        const task = try service.submit(.{ .url = url, .proxy = "http://127.0.0.1:1", .require_public_address = true });
        defer task.release() catch unreachable;
        task.join();
        try std.testing.expectEqual(error.NonPublicAddress, task.snapshot().failure.?);
    }
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
    var budget = try downloader.Budget.init(std.testing.io, 1);
    defer budget.deinit();
    const service = try downloader.Service.init(a, std.testing.io, &budget, 1);
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
    var budget = try downloader.Budget.init(std.testing.io, 1);
    defer budget.deinit();
    const service = try downloader.Service.init(a, std.testing.io, &budget, 1);
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

test "short HTTP downloads publish speed through the install task bridge before 100ms" {
    const tasks = @import("tasks.zig");
    const telemetry = @import("install/download_details.zig");
    var registry = tasks.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const task = try registry.create(.game_install, "Short metadata download");
    var adapter: telemetry.HttpObserver = .{ .task = task, .path = "34.json", .stage = .downloading };
    var transfer: Transfer = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .request = .{ .url = "https://example.invalid/34.json", .observer = adapter.observer() },
        .deadline = std.math.maxInt(i96),
        .sample_ns = std.Io.Clock.awake.now(std.testing.io).nanoseconds - 10 * std.time.ns_per_ms,
    };
    defer transfer.deinit();
    const bytes = 583 * 1024;
    try std.testing.expectEqual(@as(c_int, 0), progressCallback(&transfer, bytes, bytes, 0, 0));
    const live = task.details();
    try std.testing.expectEqualStrings("34.json", live.files[0].name());
    try std.testing.expectEqual(@as(u64, bytes), live.received);
    try std.testing.expect(live.bytes_per_second > 0);
    try std.testing.expectEqual(live.bytes_per_second, live.files[0].bytes_per_second);
    transfer.publishTerminal(null);
    const complete = task.details();
    try std.testing.expectEqual(@as(u64, bytes), complete.received);
    try std.testing.expectEqual(tasks.FileState.complete, complete.files[0].state);
    try std.testing.expectEqual(@as(f64, 0), complete.bytes_per_second);
}

test "HTTP observer publishes received bytes before completion and resets terminal speed" {
    const Capture = struct {
        latest: Progress = .{},
        calls: usize = 0,
        fn report(raw: ?*anyopaque, value: Progress) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.latest = value;
            self.calls += 1;
        }
    };
    var capture: Capture = .{};
    var transfer: Transfer = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .request = .{ .url = "https://example.invalid/file.jar", .observer = .{ .context = &capture, .report = Capture.report } },
        .deadline = std.math.maxInt(i96),
        .sample_ns = std.Io.Clock.awake.now(std.testing.io).nanoseconds - std.time.ns_per_s,
    };
    defer transfer.deinit();
    try std.testing.expectEqual(@as(c_int, 0), progressCallback(&transfer, 4096, 1024, 0, 0));
    try std.testing.expectEqual(@as(u64, 1024), capture.latest.received);
    try std.testing.expectEqual(@as(?u64, 4096), capture.latest.total);
    try std.testing.expect(!capture.latest.complete);
    try std.testing.expect(capture.latest.bytes_per_second > 0 and capture.latest.bytes_per_second <= 1024);
    try std.testing.expectEqual(@as(c_int, 0), progressCallback(&transfer, 0, 1536, 0, 0));
    try std.testing.expectEqual(@as(?u64, null), capture.latest.total);
    transfer.publishTerminal(error.TimedOut);
    try std.testing.expectEqual(@as(?anyerror, error.TimedOut), capture.latest.failure);
    try std.testing.expectEqual(@as(f64, 0), capture.latest.bytes_per_second);
    try std.testing.expectEqual(@as(u64, 1536), capture.latest.received);
    try std.testing.expectEqual(@as(usize, 3), capture.calls);
}

// Debug/safe free poisons bytes after secureZero; ReleaseFast observes the wipe.
const BodyWipeAllocator = struct {
    allocations: usize = 0,
    deny_allocations: bool = false,
    frees: usize = 0,
    freed_bytes: usize = 0,
    all_wiped: bool = true,

    fn allocator(self: *BodyWipeAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = Allocator.noResize, .remap = Allocator.noRemap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *BodyWipeAllocator = @ptrCast(@alignCast(ctx));
        if (self.deny_allocations) return null;
        const ptr = std.testing.allocator.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocations += 1;
        return ptr;
    }
    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *BodyWipeAllocator = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        self.freed_bytes += bytes.len;
        const poison: u8 = if (@import("builtin").mode == .debug or @import("builtin").mode == .safe) 0xaa else 0;
        for (bytes) |byte| if (byte != poison) {
            self.all_wiped = false;
        };
        std.testing.allocator.rawFree(bytes, alignment, ret_addr);
    }
};

test "body transfer allocates nothing and wipes full capacity after growth" {
    var tracking: BodyWipeAllocator = .{};
    const a = tracking.allocator();
    var buffer: BodyBuffer = .{};
    defer buffer.clear(a);
    try buffer.append(a, "secret", 8192);
    try buffer.append(a, &@as([5000]u8, @splat(42)), 8192);
    const ptr = buffer.storage.ptr;
    const allocations = tracking.allocations;
    var response = buffer.takeResponse(a, 429);
    try std.testing.expectEqual(allocations, tracking.allocations);
    try std.testing.expect(response.body.ptr == ptr);
    try std.testing.expectEqual(@as(usize, 5006), response.body.len);
    try std.testing.expectEqual(@as(usize, 8192), response.allocation.len);
    try std.testing.expectEqual(@as(usize, 0), buffer.storage.len);
    try std.testing.expectEqual(@as(usize, 1), tracking.frees);
    response.deinit();
    try std.testing.expectEqual(@as(usize, 2), tracking.frees);
    try std.testing.expectEqual(@as(usize, 4096 + 8192), tracking.freed_bytes);
    try std.testing.expect(tracking.all_wiped);
}

test "body growth and extraction use in-place resizing when available" {
    var memory: [8192]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    const a = fixed.allocator();
    var buffer: BodyBuffer = .{};
    defer buffer.clear(a);
    try buffer.append(a, "secret", 8192);
    const ptr = buffer.storage.ptr;
    try buffer.append(a, &@as([5000]u8, @splat(42)), 8192);
    try std.testing.expect(buffer.storage.ptr == ptr);
    var response = buffer.takeResponse(a, 200);
    defer response.deinit();
    const owned = try response.takeBody(a);
    defer {
        std.crypto.secureZero(u8, owned);
        a.free(owned);
    }
    try std.testing.expect(owned.ptr == ptr);
    try std.testing.expectEqual(@as(usize, 5006), owned.len);
    try std.testing.expectEqual(@as(usize, 0), response.body.len);
    try std.testing.expectEqual(@as(usize, 0), response.allocation.len);
}

test "body extraction preserves ownership on OOM and safely copies across allocators" {
    var tracking: BodyWipeAllocator = .{};
    const a = tracking.allocator();
    var buffer: BodyBuffer = .{};
    defer buffer.clear(a);
    try buffer.append(a, "secret", 8192);
    var response = buffer.takeResponse(a, 201);
    defer response.deinit();
    var empty: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&empty);
    try std.testing.expectError(error.OutOfMemory, response.takeBody(fixed.allocator()));
    try std.testing.expectEqualStrings("secret", response.body);
    try std.testing.expectEqual(@as(usize, 0), tracking.frees);
    const copied = try response.takeBody(std.testing.allocator);
    defer {
        std.crypto.secureZero(u8, copied);
        std.testing.allocator.free(copied);
    }
    try std.testing.expectEqualStrings("secret", copied);
    try std.testing.expectEqual(@as(usize, 0), response.body.len);
    try std.testing.expectEqual(@as(u16, 201), response.status);
    try std.testing.expectEqual(@as(usize, 1), tracking.frees);
    try std.testing.expect(tracking.all_wiped);
}

test "body extraction transfers exact allocations and copies when resizing fails" {
    var tracking: BodyWipeAllocator = .{};
    const a = tracking.allocator();
    const bytes = try a.dupe(u8, "secret");
    var exact: Response = .{ .status = 200, .body = bytes, .allocator = a, .allocation = bytes };
    defer exact.deinit();
    const ptr = exact.body.ptr;
    const owned = try exact.takeBody(a);
    try std.testing.expect(owned.ptr == ptr);
    std.crypto.secureZero(u8, owned);
    a.free(owned);
    var buffer: BodyBuffer = .{};
    defer buffer.clear(a);
    try buffer.append(a, "secret", 8192);
    var response = buffer.takeResponse(a, 200);
    defer response.deinit();
    const copied = try response.takeBody(a);
    try std.testing.expectEqualStrings("secret", copied);
    std.crypto.secureZero(u8, copied);
    a.free(copied);
    var blank = buffer.takeResponse(a, 204);
    defer blank.deinit();
    const empty = try blank.takeBody(a);
    a.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expect(tracking.all_wiped);
}

test "failed resize and copy preserve response ownership until retry" {
    var tracking: BodyWipeAllocator = .{};
    const a = tracking.allocator();
    var buffer: BodyBuffer = .{};
    defer buffer.clear(a);
    try buffer.append(a, "secret", 8192);
    var response = buffer.takeResponse(a, 503);
    defer response.deinit();
    const storage = response.allocation;
    @memset(storage[response.body.len..], 42);
    tracking.deny_allocations = true;
    try std.testing.expectError(error.OutOfMemory, response.takeBody(a));
    try std.testing.expectEqualStrings("secret", response.body);
    try std.testing.expectEqual(@as(u16, 503), response.status);
    try std.testing.expect(response.allocation.ptr == storage.ptr);
    try std.testing.expectEqual(storage.len, response.allocation.len);
    try std.testing.expectEqual(@as(usize, 0), tracking.frees);
    for (storage[response.body.len..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    tracking.deny_allocations = false;
    const copied = try response.takeBody(a);
    defer {
        std.crypto.secureZero(u8, copied);
        a.free(copied);
    }
    try std.testing.expectEqualStrings("secret", copied);
    try std.testing.expect(copied.ptr != storage.ptr);
    try std.testing.expectEqual(@as(usize, 0), response.allocation.len);
    try std.testing.expectEqual(@as(usize, 0), response.body.len);
    try std.testing.expectEqual(storage.len, tracking.freed_bytes);
    try std.testing.expect(tracking.all_wiped);
}

test "empty body extraction wipes and frees retained capacity" {
    var tracking: BodyWipeAllocator = .{};
    const a = tracking.allocator();
    const storage = try a.dupe(u8, "secret capacity");
    var response: Response = .{ .status = 204, .body = storage[0..0], .allocator = a, .allocation = storage };
    defer response.deinit();
    const empty = try response.takeBody(a);
    defer a.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectEqual(@as(usize, 0), response.allocation.len);
    try std.testing.expectEqual(@as(usize, 1), tracking.frees);
    try std.testing.expectEqual(storage.len, tracking.freed_bytes);
    try std.testing.expect(tracking.all_wiped);
}

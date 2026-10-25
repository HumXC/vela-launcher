//! Bounded background curl Multi service. See docs/downloader.md for ownership.
//! Call curl.globalInit before init, globalDeinit after all services are destroyed.
//! Io and allocator must support ordinary concurrent OS threads.
const std = @import("std");
const curl = @import("curl");
const public_network = @import("public_network.zig");
const c = curl.libcurl;
const Allocator = std.mem.Allocator;
const capacity = 256;

/// A deliberately narrow grammar, independent of upstream provider validation.
/// Only percent-encoded filename bytes are accepted; decoded separators, nested
/// escapes and dot segments cannot change the credential's path scope.
fn credentialUrlAllowed(url: []const u8) bool {
    const prefix = "https://edge.forgecdn.net/files/";
    if (url.len > 8192 or !std.mem.startsWith(u8, url, prefix)) return false;
    for (url) |byte| if (byte <= 32 or byte >= 127 or byte == 0x5c or byte == '?' or byte == '#') return false;
    var parts = std.mem.splitScalar(u8, url[prefix.len..], '/');
    for (0..2) |_| {
        const number = parts.next() orelse return false;
        if (number.len == 0) return false;
        for (number) |byte| if (!std.ascii.isDigit(byte)) return false;
    }
    const filename = parts.next() orelse return false;
    if (filename.len == 0 or parts.next() != null) return false;
    var decoded: [8192]u8 = undefined;
    var count: usize = 0;
    var index: usize = 0;
    while (index < filename.len) {
        const byte = if (filename[index] == '%') blk: {
            if (filename.len - index < 3) return false;
            const value = std.fmt.parseInt(u8, filename[index + 1 ..][0..2], 16) catch return false;
            index += 3;
            break :blk value;
        } else blk: {
            const value = filename[index];
            index += 1;
            break :blk value;
        };
        if (byte < 32 or byte == 127 or byte == '/' or byte == 0x5c or byte == '%' or byte == '?' or byte == '#') return false;
        decoded[count] = byte;
        count += 1;
    }
    return !std.mem.eql(u8, decoded[0..count], ".") and !std.mem.eql(u8, decoded[0..count], "..");
}

fn validateCredentialRequest(request: Request) error{InvalidCredentialScope}!void {
    const key = request.curseforge_download_key orelse return;
    if (!credentialUrlAllowed(request.url) or !request.https_only or request.follow_redirects or
        !request.require_public_address or request.cache_path != null) return error.InvalidCredentialScope;
    if (request.proxy) |proxy| if (proxy.len != 0) return error.InvalidCredentialScope;
    if (key.len == 0 or key.len > 4096) return error.InvalidCredentialScope;
    for (key) |byte| if (byte < 33 or byte > 126) return error.InvalidCredentialScope;
}

fn wipeHeaders(head: *c.curl_slist) void {
    var node: ?*c.curl_slist = head;
    while (node) |entry| {
        if (entry.data != null) std.crypto.secureZero(u8, std.mem.span(entry.data));
        node = entry.next;
    }
}

fn timeoutAsLong(timeout_ms: u32) error{InvalidTimeout}!c_long {
    return std.math.cast(c_long, timeout_ms) orelse error.InvalidTimeout;
}

test "curl timeout conversion preserves values and rejects overflow" {
    try std.testing.expectEqual(@as(c_long, 0), try timeoutAsLong(0));
    try std.testing.expectEqual(@as(c_long, 120_000), try timeoutAsLong(120_000));
    const largest: u32 = @min(std.math.maxInt(u32), std.math.maxInt(c_long));
    try std.testing.expectEqual(@as(c_long, @intCast(largest)), try timeoutAsLong(largest));
    if (comptime @bitSizeOf(c_long) == 32) {
        try std.testing.expectError(error.InvalidTimeout, timeoutAsLong(largest + 1));
        try std.testing.expectError(error.InvalidTimeout, timeoutAsLong(std.math.maxInt(u32)));
    }
}
pub const Phase = enum { queued, preparing, ready, downloading, processing, parsing, committing, complete, failed, canceled };
pub fn terminal(p: Phase) bool {
    return p == .complete or p == .failed or p == .canceled;
}
pub const Source = enum { network, revalidated };
pub const Progress = struct {
    phase: Phase = .queued,
    received: u64 = 0,
    total: ?u64 = null,
    bytes_per_second: f64 = 0,
    eta_seconds: ?f64 = null,
};
pub const Request = struct {
    url: []const u8,
    /// Borrowed only until submit returns. Never cached; scoped to the official CDN.
    curseforge_download_key: ?[]const u8 = null,
    output: union(enum) { file: []const u8, json, bytes } = .bytes,
    expected_sha1: ?[20]u8 = null,
    expected_size: ?u64 = null,
    /// null: 16MiB for memory outputs, unlimited for streamed files.
    max_bytes: ?usize = null,
    /// Persistent conditional cache for public JSON/bytes GETs only. File tasks
    /// use expected_sha1 instead; combining file and cache_path is rejected.
    /// Cache paths must not be shared by simultaneous Service instances.
    cache_path: ?[]const u8 = null,
    /// Null or empty disables ALL environment proxies; explicit proxies ignore NO_PROXY.
    proxy: ?[]const u8 = null,
    /// PEM trust for both the origin and HTTPS proxy. Null loads native trust.
    ca_bundle: ?[]const u8 = null,
    /// Zero disables the application transfer deadline and explicit connection budget.
    timeout_ms: u32 = 120_000,
    /// Abort if throughput remains below one byte/second for this many seconds.
    /// Zero disables this optional protection.
    stall_timeout_seconds: u32 = 0,
    /// Prevent initial or redirected requests from using plaintext HTTP.
    https_only: bool = false,
    /// Disable redirects for provider-pinned or otherwise sensitive transfers.
    follow_redirects: bool = true,
    /// Reject resolved nonpublic endpoints before socket creation; proxies unsupported.
    /// Disables automatic redirects so curl cannot reuse unchecked cached sockets.
    require_public_address: bool = false,
};
pub const Result = union(enum) { file: []const u8, bytes: []const u8, json: std.json.Value };
pub const Snapshot = struct { progress: Progress, result: ?Result, failure: ?anyerror, source: Source, http_status: u16 };
const CacheMeta = struct { url: []const u8, etag: []const u8, modified: []const u8, sha1: [20]u8 };

pub const Task = struct {
    service: *Service,
    request: Request,
    url: [:0]u8,
    curseforge_download_key: ?[]u8 = null,
    proxy: ?[:0]u8 = null,
    ca: ?[:0]u8 = null,
    destination: ?[]u8 = null,
    cache_path: ?[]u8 = null,
    meta_path: ?[]u8 = null,
    temp: []u8,
    progress: Progress = .{},
    result: ?Result = null,
    failure: ?anyerror = null,
    source: Source = .network,
    http_status: u16 = 0,
    canceled: std.atomic.Value(bool) = .init(false),
    release_requested: bool = false,
    easy: ?*c.CURL = null,
    headers: ?*c.curl_slist = null,
    file: ?std.Io.File = null,
    owns_temp: bool = false,
    body: std.ArrayList(u8) = .empty,
    parsed: ?std.json.Parsed(std.json.Value) = null,
    cache_meta: ?std.json.Parsed(CacheMeta) = null,
    hash: std.crypto.hash.Sha1 = .init(.{}),
    count: u64 = 0,
    etag: std.ArrayList(u8) = .empty,
    modified: std.ArrayList(u8) = .empty,
    forbid_cache: bool = false,
    status: u16 = 0,
    callback_error: ?anyerror = null,
    retry_unconditional: bool = false,
    last_time: i96 = 0,
    last_count: u64 = 0,
    fn limit(self: *Task) usize {
        return self.request.max_bytes orelse if (self.destination != null) std.math.maxInt(usize) else 16 * 1024 * 1024;
    }
    /// Borrowed result remains valid until release/deinit. Never read internal fields.
    pub fn snapshot(self: *Task) Snapshot {
        const s = self.service;
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        return .{ .progress = self.progress, .result = self.result, .failure = self.failure, .source = self.source, .http_status = self.http_status };
    }
    /// Cancellation is accepted before committing. A committed result wins races.
    pub fn cancel(self: *Task) void {
        const s = self.service;
        s.mutex.lockUncancelable(s.io);
        if (!terminal(self.progress.phase) and self.progress.phase != .committing) self.canceled.store(true, .release);
        s.mutex.unlock(s.io);
        _ = c.curl_multi_wakeup(s.multi);
    }
    /// Only terminal tasks can be released. Invalidates handle and all borrowed results.
    pub fn release(self: *Task) !void {
        const s = self.service;
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        if (!terminal(self.progress.phase)) return error.TaskBusy;
        self.release_requested = true;
        _ = c.curl_multi_wakeup(s.multi);
    }
    fn clearCredential(self: *Task) void {
        if (self.curseforge_download_key) |key| {
            std.crypto.secureZero(u8, key);
            self.service.allocator.free(key);
            self.curseforge_download_key = null;
        }
    }
    fn finish(self: *Task, failure: ?anyerror, result: ?Result) void {
        self.clearCredential();
        const s = self.service;
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const err: ?anyerror = if (self.progress.phase != .committing and self.canceled.load(.acquire)) error.Canceled else failure;
        self.failure = err;
        self.result = if (err == null) result else null;
        self.progress.phase = if (err) |e| (if (e == error.Canceled) .canceled else .failed) else .complete;
        self.progress.eta_seconds = null;
    }
};
pub const Service = struct {
    allocator: Allocator,
    io: std.Io,
    multi: *c.CURLM,
    thread: ?std.Thread = null,
    worker: ?std.Thread = null,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    tasks: [capacity]?*Task = @splat(null),
    stopping: std.atomic.Value(bool) = .init(false),
    network_done: bool = false,
    max_active: usize,
    ca_bundle: std.ArrayList(u8) = .empty,
    ca_loaded: bool = false,
    pub fn init(a: Allocator, io: std.Io, max_active: usize) !*Service {
        if (max_active == 0 or max_active > capacity) return error.InvalidConcurrency;
        const s = try a.create(Service);
        errdefer a.destroy(s);
        const multi = c.curl_multi_init() orelse return error.CurlInit;
        errdefer _ = c.curl_multi_cleanup(multi);
        s.* = .{ .allocator = a, .io = io, .multi = multi, .max_active = max_active };
        s.worker = try std.Thread.spawn(.{}, work, .{s});
        errdefer {
            s.mutex.lockUncancelable(io);
            s.network_done = true;
            s.condition.broadcast(io);
            s.mutex.unlock(io);
            s.worker.?.join();
        }
        s.thread = try std.Thread.spawn(.{}, run, .{s});
        return s;
    }
    pub fn submit(self: *Service, request: Request) !*Task {
        try validateCredentialRequest(request);
        _ = try timeoutAsLong(request.timeout_ms);
        if (request.require_public_address) {
            if (request.proxy) |proxy| if (proxy.len != 0) return error.UnsupportedProxyWithPublicAddressGuard;
        }
        if (request.output == .file and request.cache_path != null) return error.FileCacheUnsupported;
        if (!(std.mem.startsWith(u8, request.url, "http://") or std.mem.startsWith(u8, request.url, "https://"))) return error.InvalidUrl;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping.load(.acquire)) return error.Shutdown;
        var slot: ?usize = null;
        for (self.tasks, 0..) |item, i| {
            if (item) |old| {
                if (!terminal(old.progress.phase)) {
                    if (request.cache_path) |p| if (old.cache_path) |q| if (std.mem.eql(u8, p, q)) return error.PathBusy;
                    if (request.output == .file) if (old.destination) |q| if (std.mem.eql(u8, request.output.file, q)) return error.PathBusy;
                }
            } else if (slot == null) {
                slot = i;
            }
        }
        const index = slot orelse return error.QueueFull;
        const a = self.allocator;
        const t = try a.create(Task);
        errdefer a.destroy(t);
        t.* = .{ .service = self, .request = request, .url = try a.dupeSentinel(u8, request.url, 0), .temp = undefined };
        errdefer a.free(t.url);
        // Do not retain the borrowed secret even in the copied Request.
        t.request.curseforge_download_key = null;
        t.curseforge_download_key = if (request.curseforge_download_key) |key| try a.dupe(u8, key) else null;
        errdefer t.clearCredential();
        t.destination = switch (request.output) {
            .file => |p| try a.dupe(u8, p),
            else => null,
        };
        errdefer if (t.destination) |p| a.free(p);
        t.cache_path = if (request.cache_path) |p| try a.dupe(u8, p) else null;
        errdefer if (t.cache_path) |p| a.free(p);
        t.meta_path = if (request.cache_path) |p| try std.fmt.allocPrint(a, "{s}.meta.json", .{p}) else null;
        errdefer if (t.meta_path) |p| a.free(p);
        t.proxy = if (request.proxy) |p| try a.dupeSentinel(u8, p, 0) else null;
        errdefer if (t.proxy) |p| a.free(p);
        t.ca = if (request.ca_bundle) |p| try a.dupeSentinel(u8, p, 0) else null;
        errdefer if (t.ca) |p| a.free(p);
        t.temp = try std.fmt.allocPrint(a, "{s}.vela-{x}.part", .{ t.destination orelse t.cache_path orelse "download", @intFromPtr(t) });
        self.tasks[index] = t;
        self.condition.signal(self.io);
        return t;
    }
    pub fn shutdown(self: *Service) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping.store(true, .release);
        for (self.tasks) |item| if (item) |t| {
            if (!terminal(t.progress.phase) and t.progress.phase != .committing) t.canceled.store(true, .release);
        };
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        _ = c.curl_multi_wakeup(self.multi);
    }
    /// Blocking join, to be called after callers stop using this service.
    pub fn deinit(self: *Service) void {
        self.shutdown();
        self.thread.?.join();
        self.worker.?.join();
        for (self.tasks) |item| if (item) |t| self.destroyTask(t);
        _ = c.curl_multi_cleanup(self.multi);
        self.ca_bundle.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    fn destroyTask(self: *Service, t: *Task) void {
        self.detach(t);
        t.clearCredential();
        if (t.parsed) |p| p.deinit();
        if (t.cache_meta) |p| p.deinit();
        t.body.deinit(self.allocator);
        t.etag.deinit(self.allocator);
        t.modified.deinit(self.allocator);
        self.allocator.free(t.url);
        self.allocator.free(t.temp);
        if (t.destination) |p| self.allocator.free(p);
        if (t.cache_path) |p| self.allocator.free(p);
        if (t.meta_path) |p| self.allocator.free(p);
        if (t.proxy) |p| self.allocator.free(p);
        if (t.ca) |p| self.allocator.free(p);
        self.allocator.destroy(t);
    }
    fn work(self: *Service) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            var selected: ?*Task = null;
            var preparing = false;
            for (self.tasks) |item| if (item) |t| {
                if (t.progress.phase == .queued or t.progress.phase == .processing) {
                    selected = t;
                    preparing = t.progress.phase == .queued;
                    t.progress.phase = if (preparing) .preparing else .parsing;
                    break;
                }
            };
            if (selected == null) {
                if (self.network_done) {
                    self.mutex.unlock(self.io);
                    return;
                }
                self.condition.waitUncancelable(self.io, &self.mutex);
                self.mutex.unlock(self.io);
                continue;
            }
            self.mutex.unlock(self.io);
            const t = selected.?;
            if (preparing) {
                self.prepare(t) catch |err| {
                    self.cleanup(t);
                    t.finish(err, null);
                    continue;
                };
                self.mutex.lockUncancelable(self.io);
                t.progress.phase = .ready;
                self.mutex.unlock(self.io);
                _ = c.curl_multi_wakeup(self.multi);
            } else {
                const result = self.process(t) catch |err| {
                    self.cleanup(t);
                    t.finish(err, null);
                    continue;
                };
                // null means the 304 cache was missing/corrupt: retry unconditional.
                if (result) |r| t.finish(null, r);
            }
        }
    }
    fn prepare(self: *Service, t: *Task) !void {
        if (t.canceled.load(.acquire)) return error.Canceled;
        if (!self.ca_loaded and t.ca == null) {
            self.ca_bundle = try curl.allocCABundle(self.allocator, self.io);
            self.ca_loaded = true;
        }
        if (t.destination != null) {
            t.file = try std.Io.Dir.cwd().createFile(self.io, t.temp, .{ .exclusive = true });
            t.owns_temp = true;
        }
        if (t.meta_path) |path| {
            const data = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(32 * 1024)) catch return;
            defer self.allocator.free(data);
            const parsed = std.json.parseFromSlice(CacheMeta, self.allocator, data, .{ .allocate = .alloc_always }) catch return;
            if (!std.mem.eql(u8, parsed.value.url, t.url) or !validValidator(parsed.value.etag) or !validValidator(parsed.value.modified)) {
                parsed.deinit();
                return;
            }
            t.cache_meta = parsed;
        }
    }
    fn run(self: *Service) void {
        while (true) {
            var list: [capacity]?*Task = undefined;
            var garbage: [capacity]?*Task = @splat(null);
            self.mutex.lockUncancelable(self.io);
            for (&self.tasks, 0..) |*item, i| if (item.*) |t| {
                if (t.release_requested) {
                    garbage[i] = t;
                    item.* = null;
                }
            };
            list = self.tasks;
            self.mutex.unlock(self.io);
            for (garbage) |item| if (item) |t| self.destroyTask(t);
            var active: usize = 0;
            for (list) |item| if (item) |t| {
                const phase = t.snapshot().progress.phase;
                if ((phase == .downloading or phase == .ready) and t.canceled.load(.acquire)) {
                    self.cleanup(t);
                    t.finish(error.Canceled, null);
                }
                if (t.easy != null) active += 1;
            };
            for (list) |item| if (item) |t| {
                if (t.snapshot().progress.phase != .ready or active >= self.max_active) continue;
                self.start(t) catch |err| {
                    self.cleanup(t);
                    t.finish(err, null);
                    continue;
                };
                active += 1;
            };
            if (self.stopping.load(.acquire)) {
                // Preparing workers may publish ready after this iteration.
                self.mutex.lockUncancelable(self.io);
                var pending = false;
                for (self.tasks) |item| if (item) |t| {
                    if (!terminal(t.progress.phase)) pending = true;
                };
                if (!pending) {
                    self.network_done = true;
                    self.condition.broadcast(self.io);
                    self.mutex.unlock(self.io);
                    return;
                }
                self.mutex.unlock(self.io);
            }
            var running: c_int = 0;
            if (c.curl_multi_perform(self.multi, &running) != c.CURLM_OK) {
                self.shutdown();
                continue;
            }
            var remaining: c_int = 0;
            while (c.curl_multi_info_read(self.multi, &remaining)) |msg| {
                if (msg.*.msg != @as(c_uint, c.CURLMSG_DONE)) continue;
                for (list) |item| if (item) |t| {
                    if (t.easy == msg.*.easy_handle) {
                        const code = msg.*.data.result;
                        self.detach(t);
                        if (t.callback_error) |err| {
                            self.cleanup(t);
                            t.finish(err, null);
                        } else if (code != c.CURLE_OK) {
                            self.cleanup(t);
                            t.finish(if (code == c.CURLE_OPERATION_TIMEDOUT) error.TimedOut else error.TransferFailed, null);
                        } else if (t.status != 200 and t.status != 304) {
                            self.cleanup(t);
                            t.finish(error.HttpStatus, null);
                        } else {
                            self.mutex.lockUncancelable(self.io);
                            t.progress.phase = .processing;
                            t.progress.eta_seconds = null;
                            self.condition.signal(self.io);
                            self.mutex.unlock(self.io);
                        }
                        break;
                    }
                };
            }
            var n: c_int = 0;
            _ = c.curl_multi_poll(self.multi, null, 0, 50, &n);
        }
    }
    fn set(e: *c.CURL, option: c_uint, value: anytype) !void {
        if (c.curl_easy_setopt(e, option, value) != c.CURLE_OK) return error.CurlOption;
    }
    fn start(self: *Service, t: *Task) !void {
        if (t.canceled.load(.acquire)) return error.Canceled;
        const e = c.curl_easy_init() orelse return error.CurlInit;
        t.easy = e;
        t.count = 0;
        t.hash = .init(.{});
        t.body.clearRetainingCapacity();
        t.etag.clearRetainingCapacity();
        t.modified.clearRetainingCapacity();
        t.callback_error = null;
        try set(e, c.CURLOPT_URL, t.url.ptr);
        try set(e, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
        try set(e, c.CURLOPT_FOLLOWLOCATION, @as(c_long, if (t.request.follow_redirects and !t.request.require_public_address) 1 else 0));
        try set(e, c.CURLOPT_MAXREDIRS, @as(c_long, 10));
        const protocols: [*:0]const u8 = if (t.request.https_only) "https" else "http,https";
        try set(e, c.CURLOPT_PROTOCOLS_STR, protocols);
        try set(e, c.CURLOPT_REDIR_PROTOCOLS_STR, protocols);
        try set(e, c.CURLOPT_TIMEOUT_MS, try timeoutAsLong(t.request.timeout_ms));
        try set(e, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, @min(t.request.timeout_ms, 30_000)));
        try set(e, c.CURLOPT_LOW_SPEED_LIMIT, @as(c_long, if (t.request.stall_timeout_seconds == 0) 0 else 1));
        try set(e, c.CURLOPT_LOW_SPEED_TIME, try timeoutAsLong(t.request.stall_timeout_seconds));
        try set(e, c.CURLOPT_WRITEFUNCTION, &writeCallback);
        try set(e, c.CURLOPT_WRITEDATA, t);
        try set(e, c.CURLOPT_HEADERFUNCTION, &headerCallback);
        try set(e, c.CURLOPT_HEADERDATA, t);
        try set(e, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
        try set(e, c.CURLOPT_XFERINFOFUNCTION, &progressCallback);
        try set(e, c.CURLOPT_XFERINFODATA, t);
        if (t.request.require_public_address) {
            try set(e, c.CURLOPT_OPENSOCKETFUNCTION, &public_network.openSocket);
            try set(e, c.CURLOPT_FRESH_CONNECT, @as(c_long, 1));
            try set(e, c.CURLOPT_FORBID_REUSE, @as(c_long, 1));
            try set(e, c.CURLOPT_OPENSOCKETDATA, &t.callback_error);
        }
        try set(e, c.CURLOPT_PROXY, if (t.proxy) |p| p.ptr else @as([*:0]const u8, ""));
        try set(e, c.CURLOPT_NOPROXY, @as([*:0]const u8, ""));
        try set(e, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 1));
        try set(e, c.CURLOPT_SSL_VERIFYHOST, @as(c_long, 2));
        try set(e, c.CURLOPT_PROXY_SSL_VERIFYPEER, @as(c_long, 1));
        try set(e, c.CURLOPT_PROXY_SSL_VERIFYHOST, @as(c_long, 2));
        if (t.ca) |p| {
            try set(e, c.CURLOPT_CAINFO, p.ptr);
            try set(e, c.CURLOPT_PROXY_CAINFO, p.ptr);
        } else {
            const blob: c.curl_blob = .{ .data = self.ca_bundle.items.ptr, .len = self.ca_bundle.items.len, .flags = c.CURL_BLOB_NOCOPY };
            try set(e, c.CURLOPT_CAINFO_BLOB, &blob);
            try set(e, c.CURLOPT_PROXY_CAINFO_BLOB, &blob);
        }
        if (!t.retry_unconditional) if (t.cache_meta) |meta| {
            const value = if (meta.value.etag.len > 0) meta.value.etag else meta.value.modified;
            if (value.len > 0) {
                const h = try std.fmt.allocPrintSentinel(self.allocator, "{s}: {s}", .{ if (meta.value.etag.len > 0) "If-None-Match" else "If-Modified-Since", value }, 0);
                defer self.allocator.free(h);
                t.headers = c.curl_slist_append(null, h.ptr) orelse return error.OutOfMemory;
                try set(e, c.CURLOPT_HTTPHEADER, t.headers);
            }
        };
        if (t.curseforge_download_key) |key| {
            var scoped = t.request;
            scoped.url = t.url;
            scoped.curseforge_download_key = key;
            try validateCredentialRequest(scoped);
            const header = try std.fmt.allocPrintSentinel(self.allocator, "x-api-key: {s}", .{key}, 0);
            defer {
                std.crypto.secureZero(u8, header);
                self.allocator.free(header);
            }
            t.headers = c.curl_slist_append(null, header.ptr) orelse return error.OutOfMemory;
            try set(e, c.CURLOPT_HTTPHEADER, t.headers);
        }
        if (c.curl_multi_add_handle(self.multi, e) != c.CURLM_OK) return error.CurlMulti;
        self.mutex.lockUncancelable(self.io);
        t.progress = .{ .phase = .downloading };
        self.mutex.unlock(self.io);
        t.last_time = std.Io.Clock.awake.now(self.io).nanoseconds;
        t.last_count = 0;
    }
    fn detach(self: *Service, t: *Task) void {
        if (t.easy) |e| {
            _ = c.curl_multi_remove_handle(self.multi, e);
            c.curl_easy_cleanup(e);
            t.easy = null;
        }
        if (t.headers) |h| {
            // libcurl owns these allocations, but its free does not erase secrets.
            wipeHeaders(h);
            c.curl_slist_free_all(h);
            t.headers = null;
        }
        if (t.file) |f| {
            f.close(self.io);
            t.file = null;
        }
    }
    fn cleanup(self: *Service, t: *Task) void {
        self.detach(t);
        if (t.owns_temp) {
            std.Io.Dir.cwd().deleteFile(self.io, t.temp) catch {};
            t.owns_temp = false;
        }
    }
    fn retry(self: *Service, t: *Task) !?Result {
        if (t.retry_unconditional) return error.CacheInvalid;
        t.retry_unconditional = true;
        self.mutex.lockUncancelable(self.io);
        t.source = .network;
        t.progress.phase = .ready;
        self.mutex.unlock(self.io);
        _ = c.curl_multi_wakeup(self.multi);
        return null;
    }
    fn process(self: *Service, t: *Task) !?Result {
        if (t.canceled.load(.acquire)) return error.Canceled;
        if (t.status == 304) {
            const meta = t.cache_meta orelse return error.UnexpectedNotModified;
            const data = std.Io.Dir.cwd().readFileAlloc(self.io, t.cache_path.?, self.allocator, .limited(t.limit())) catch return self.retry(t);
            defer self.allocator.free(data);
            var digest: [20]u8 = undefined;
            std.crypto.hash.Sha1.hash(data, &digest, .{});
            if (!std.mem.eql(u8, &digest, &meta.value.sha1)) return self.retry(t);
            try t.body.appendSlice(self.allocator, data);
            t.hash = .init(.{});
            t.hash.update(data);
            t.count = data.len;
            self.mutex.lockUncancelable(self.io);
            t.source = .revalidated;
            self.mutex.unlock(self.io);
        }
        if (t.request.expected_size) |size| if (size != t.count) {
            if (t.status == 304) return self.retry(t);
            return error.SizeMismatch;
        };
        var digest: [20]u8 = undefined;
        t.hash.final(&digest);
        if (t.request.expected_sha1) |expected| if (!std.mem.eql(u8, &digest, &expected)) {
            if (t.status == 304) return self.retry(t);
            return error.Sha1Mismatch;
        };
        const result: Result = switch (t.request.output) {
            .json => blk: {
                t.parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, t.body.items, .{ .allocate = .alloc_always });
                break :blk .{ .json = t.parsed.?.value };
            },
            .bytes => .{ .bytes = t.body.items },
            .file => .{ .file = t.destination.? },
        };
        self.mutex.lockUncancelable(self.io);
        if (t.canceled.load(.acquire)) {
            self.mutex.unlock(self.io);
            return error.Canceled;
        }
        // Commit linearization point: subsequent cancellation is ignored.
        t.progress.phase = .committing;
        self.mutex.unlock(self.io);
        if (t.destination) |path| {
            try std.Io.Dir.cwd().rename(t.temp, std.Io.Dir.cwd(), path, self.io);
            t.owns_temp = false;
        }
        if (t.cache_path != null) try self.saveCache(t, digest);
        return result;
    }
    fn saveCache(self: *Service, t: *Task, digest: [20]u8) !void {
        if (t.forbid_cache) {
            std.Io.Dir.cwd().deleteFile(self.io, t.meta_path.?) catch {};
            std.Io.Dir.cwd().deleteFile(self.io, t.cache_path.?) catch {};
            return;
        }
        const old = if (t.cache_meta) |m| m.value else null;
        const meta: CacheMeta = .{ .url = t.url, .etag = if (t.status == 304 and t.etag.items.len == 0 and old != null) old.?.etag else t.etag.items, .modified = if (t.status == 304 and t.modified.items.len == 0 and old != null) old.?.modified else t.modified.items, .sha1 = digest };
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, meta, .{});
        defer self.allocator.free(encoded);
        // Two atomic replacements; digest binds the pair across crash windows.
        if (t.status != 304) try self.atomicWrite(t.cache_path.?, t.temp, t.body.items);
        const tmp = try std.fmt.allocPrint(self.allocator, "{s}.meta", .{t.temp});
        defer self.allocator.free(tmp);
        try self.atomicWrite(t.meta_path.?, tmp, encoded);
    }
    fn atomicWrite(self: *Service, path: []const u8, tmp: []const u8, data: []const u8) !void {
        const f = try std.Io.Dir.cwd().createFile(self.io, tmp, .{ .exclusive = true });
        defer std.Io.Dir.cwd().deleteFile(self.io, tmp) catch {};
        f.writeStreamingAll(self.io, data) catch |err| {
            f.close(self.io);
            return err;
        };
        f.close(self.io);
        try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, self.io);
    }
};
fn validValidator(s: []const u8) bool {
    return s.len <= 8192 and std.mem.indexOfAny(u8, s, "\r\n") == null;
}
fn writeCallback(ptr: [*c]u8, size: usize, nmemb: usize, userdata: ?*anyopaque) callconv(.c) usize {
    const t: *Task = @ptrCast(@alignCast(userdata.?));
    const data = ptr[0 .. size * nmemb];
    if (t.canceled.load(.acquire)) return 0;
    if (t.status != 200) return data.len; // redirect/error bodies never reach output/hash
    if (data.len > t.limit() -| t.count) {
        t.callback_error = error.ResponseTooLarge;
        return 0;
    }
    if (t.file) |f| {
        f.writeStreamingAll(t.service.io, data) catch |err| {
            t.callback_error = err;
            return 0;
        };
    } else t.body.appendSlice(t.service.allocator, data) catch |err| {
        t.callback_error = err;
        return 0;
    };
    t.hash.update(data);
    t.count += data.len;
    return data.len;
}
fn headerCallback(ptr: [*c]u8, size: usize, nmemb: usize, userdata: ?*anyopaque) callconv(.c) usize {
    const t: *Task = @ptrCast(@alignCast(userdata.?));
    const data = ptr[0 .. size * nmemb];
    if (std.mem.startsWith(u8, data, "HTTP/")) {
        t.etag.clearRetainingCapacity();
        t.modified.clearRetainingCapacity();
        t.forbid_cache = false;
        var parts = std.mem.tokenizeScalar(u8, data, ' ');
        _ = parts.next();
        t.status = std.fmt.parseInt(u16, parts.next() orelse "0", 10) catch 0;
        t.service.mutex.lockUncancelable(t.service.io);
        t.http_status = t.status;
        t.service.mutex.unlock(t.service.io);
    }
    if (std.mem.indexOfScalar(u8, data, ':')) |i| {
        const name = data[0..i];
        const value = std.mem.trim(u8, data[i + 1 ..], " \r\n\t");
        if (std.ascii.eqlIgnoreCase(name, "vary") and value.len > 0) t.forbid_cache = true;
        if (std.ascii.eqlIgnoreCase(name, "cache-control")) {
            var directives = std.mem.tokenizeScalar(u8, value, ',');
            while (directives.next()) |d| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, d, " \t"), "no-store")) {
                t.forbid_cache = true;
            };
        }
        const dest: ?*std.ArrayList(u8) = if (std.ascii.eqlIgnoreCase(name, "etag")) &t.etag else if (std.ascii.eqlIgnoreCase(name, "last-modified")) &t.modified else null;
        if (dest) |d| {
            if (!validValidator(value)) {
                t.callback_error = error.HeaderTooLarge;
                return 0;
            }
            d.clearRetainingCapacity();
            d.appendSlice(t.service.allocator, value) catch {
                t.callback_error = error.OutOfMemory;
                return 0;
            };
        }
    }
    return data.len;
}
fn progressCallback(userdata: ?*anyopaque, total: c.curl_off_t, now: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t) callconv(.c) c_int {
    const t: *Task = @ptrCast(@alignCast(userdata.?));
    if (t.canceled.load(.acquire)) return 1;
    const s = t.service;
    const time = std.Io.Clock.awake.now(s.io).nanoseconds;
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    t.progress.received = @intCast(@max(now, 0));
    t.progress.total = if (total > 0) @intCast(total) else null;
    const dt = time - t.last_time;
    // Small artifacts can finish before the regular 100 ms sampling interval.
    // Publish their first measured byte delta immediately.
    if (dt > 0 and (dt >= 100_000_000 or (t.progress.bytes_per_second == 0 and t.progress.received > t.last_count))) {
        const speed = @as(f64, @floatFromInt(t.progress.received -| t.last_count)) * 1e9 / @as(f64, @floatFromInt(dt));
        t.progress.bytes_per_second = if (t.progress.bytes_per_second == 0) speed else 0.3 * speed + 0.7 * t.progress.bytes_per_second;
        t.last_time = time;
        t.last_count = t.progress.received;
    }
    t.progress.eta_seconds = if (t.progress.total != null and t.progress.bytes_per_second > 0) @as(f64, @floatFromInt(t.progress.total.? -| t.progress.received)) / t.progress.bytes_per_second else null;
    return 0;
}

test "first download bytes produce speed before the regular sampling interval" {
    var service: Service = .{ .allocator = std.testing.allocator, .io = std.testing.io, .multi = undefined, .max_active = 1 };
    var url = "https://example.invalid/small.jar".*;
    var task: Task = .{ .service = &service, .request = .{ .url = &url }, .url = &url, .temp = &.{}, .progress = .{ .phase = .downloading }, .last_time = std.Io.Clock.awake.now(std.testing.io).nanoseconds - 10 * std.time.ns_per_ms };
    try std.testing.expectEqual(@as(c_int, 0), progressCallback(&task, 100, 50, 0, 0));
    try std.testing.expect(task.progress.bytes_per_second > 0);
    try std.testing.expectEqual(@as(u64, 50), task.progress.received);
    try std.testing.expect(task.progress.eta_seconds.? > 0);
    const speed = task.progress.bytes_per_second;
    _ = progressCallback(&task, 100, 50, 0, 0);
    try std.testing.expectEqual(speed, task.progress.bytes_per_second);
}

// These fixtures intentionally have no worker or network thread: curl handles
// are configured exactly as production, but curl_multi_perform is never called.
fn credentialFixtureRequest() Request {
    return .{ .url = "https://edge.forgecdn.net/files/1234/56/Example%20Mod.jar", .curseforge_download_key = "fixture-only-key", .https_only = true, .follow_redirects = false, .require_public_address = true };
}

fn credentialAllocationFixture(a: Allocator) !void {
    const multi = c.curl_multi_init() orelse return error.CurlInit;
    defer _ = c.curl_multi_cleanup(multi);
    var service: Service = .{ .allocator = a, .io = std.testing.io, .multi = multi, .max_active = 1 };
    var request = credentialFixtureRequest();
    request.ca_bundle = "fixture-ca-never-opened";
    request.proxy = "";
    const task = try service.submit(request);
    defer service.destroyTask(task);
    try service.start(task);
    try std.testing.expectEqualStrings("x-api-key: fixture-only-key", std.mem.span(task.headers.?.data));
    try std.testing.expect(task.headers.?.next == null);
}

test "credential submit and curl header construction clean up every allocator failure" {
    try curl.globalInit();
    defer curl.globalDeinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, credentialAllocationFixture, .{});
}

test "credential scope rejects URL ambiguities and unsafe transfer options before enqueue" {
    // An undefined curl handle proves rejected submissions do not touch curl.
    var service: Service = .{ .allocator = std.testing.allocator, .io = std.testing.io, .multi = undefined, .max_active = 1 };
    const invalid_urls = [_][]const u8{
        "http://edge.forgecdn.net/files/1/2/a.jar",
        "https://media.forgecdn.net/files/1/2/a.jar",
        "https://edge.forgecdn.net.evil.invalid/files/1/2/a.jar",
        "https://edge.forgecdn.net@evil.invalid/files/1/2/a.jar",
        "https://user@edge.forgecdn.net/files/1/2/a.jar",
        "https://edge.forgecdn.net:443/files/1/2/a.jar",
        "https://EDGE.forgecdn.net/files/1/2/a.jar",
        "https://edge.forgecdn.net./files/1/2/a.jar",
        "https://edge%2eforgecdn.net/files/1/2/a.jar",
        "https://edge.forgecdn.net/files/1/2/a.jar?api-key=fixture",
        "https://edge.forgecdn.net/files/1/2/a.jar#fragment",
        "https://edge.forgecdn.net/files/1/2/../a.jar",
        "https://edge.forgecdn.net/files/1/2/%2e%2e",
        "https://edge.forgecdn.net/files/1/2/%2fsecret",
        "https://edge.forgecdn.net/files/1/2/%5csecret",
        "https://edge.forgecdn.net/files/1/2/%252fsecret",
        "https://edge.forgecdn.net/files/1/2/%00secret",
        "https://edge.forgecdn.net/files/1/2/%0dsecret",
        "https://edge.forgecdn.net/files/1/2/%3fsecret",
        "https://edge.forgecdn.net/files/1/2/%",
        "https://edge.forgecdn.net/files/1/2/%a",
        "https://edge.forgecdn.net/files/1/2/%zz",
        "https://edge.forgecdn.net/files/1/2/",
        "https://edge.forgecdn.net/files/1//a.jar",
        "https://edge.forgecdn.net/files/%31/2/a.jar",
        "https://edge.forgecdn.net/files/1/2/a.jar/extra",
    };
    for (invalid_urls) |url| {
        var request = credentialFixtureRequest();
        request.url = url;
        try std.testing.expectError(error.InvalidCredentialScope, service.submit(request));
    }
    for (0..5) |option| {
        var request = credentialFixtureRequest();
        switch (option) {
            0 => request.https_only = false,
            1 => request.follow_redirects = true,
            2 => request.require_public_address = false,
            3 => request.proxy = "http://127.0.0.1:8080",
            4 => request.cache_path = "must-not-create-cache",
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidCredentialScope, service.submit(request));
    }
    const oversized: [4097]u8 = @splat('x');
    for ([_][]const u8{ "", "line\rbreak", "line\nbreak", "nul\x00byte", "tab\tbyte", "space key", &oversized }) |key| {
        var request = credentialFixtureRequest();
        request.curseforge_download_key = key;
        try std.testing.expectError(error.InvalidCredentialScope, service.submit(request));
    }
    for (service.tasks) |task| try std.testing.expect(task == null);
}

test "credential copy survives caller mutation and is removed on success failure cancellation and destruction" {
    try curl.globalInit();
    defer curl.globalDeinit();
    const multi = c.curl_multi_init() orelse return error.CurlInit;
    defer _ = c.curl_multi_cleanup(multi);
    var audit: CredentialWipeAudit = .{};
    var service: Service = .{ .allocator = audit.allocator(), .io = std.testing.io, .multi = multi, .max_active = 1 };
    for (0..5) |scenario| {
        var borrowed = "fixture-only-key".*;
        var request = credentialFixtureRequest();
        request.curseforge_download_key = &borrowed;
        request.ca_bundle = "fixture-ca-never-opened";
        const task = try service.submit(request);
        defer {
            service.tasks[0] = null;
            service.destroyTask(task);
        }
        try std.testing.expect(task.request.curseforge_download_key == null);
        try std.testing.expect(task.curseforge_download_key.?.ptr != &borrowed);
        @memset(&borrowed, 'z');
        try std.testing.expectEqualStrings("fixture-only-key", task.curseforge_download_key.?);
        if (scenario == 4) continue; // queued destruction, without finish
        if (scenario != 3) {
            try service.start(task);
            try std.testing.expectEqualStrings("x-api-key: fixture-only-key", std.mem.span(task.headers.?.data));
        }
        if (scenario >= 2) task.cancel();
        service.cleanup(task);
        task.finish(if (scenario == 1) error.HttpStatus else null, .{ .bytes = "fixture" });
        try std.testing.expect(task.curseforge_download_key == null);
        try std.testing.expect(task.headers == null);
        try std.testing.expect(task.easy == null);
        try std.testing.expectEqual(if (scenario >= 2) Phase.canceled else if (scenario == 1) Phase.failed else Phase.complete, task.snapshot().progress.phase);
    }
    try std.testing.expectEqual(@as(usize, 8), audit.secret_frees);
    try std.testing.expect(audit.wiped);
}

test "curl credential header list bytes are zeroed before libcurl frees them" {
    var headers: *c.curl_slist = c.curl_slist_append(null, "x-api-key: fixture-only-key") orelse return error.OutOfMemory;
    defer c.curl_slist_free_all(headers);
    headers = c.curl_slist_append(headers, "another fixture header") orelse return error.OutOfMemory;
    const first = std.mem.span(headers.data);
    const second = std.mem.span(headers.next.*.data);
    wipeHeaders(headers);
    for (first) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (second) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

const CredentialWipeAudit = struct {
    secret_frees: usize = 0,
    wiped: bool = true,
    fn allocator(self: *CredentialWipeAudit) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = Allocator.noResize, .remap = Allocator.noRemap, .free = free } };
    }
    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        return std.testing.allocator.rawAlloc(len, alignment, address);
    }
    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *CredentialWipeAudit = @ptrCast(@alignCast(ctx));
        // Fixture key and formatted header have unique allocation sizes.
        if (bytes.len == "fixture-only-key".len or bytes.len == "x-api-key: fixture-only-key".len + 1) {
            self.secret_frees += 1;
            // Allocator.free poisons after secureZero in debug/safe modes.
            const expected: u8 = if (@import("builtin").mode == .debug or @import("builtin").mode == .safe) 0xaa else 0;
            for (bytes) |byte| if (byte != expected) {
                self.wiped = false;
            };
        }
        std.testing.allocator.rawFree(bytes, alignment, address);
    }
};

test "owned key and temporary header are wiped on destruction" {
    try curl.globalInit();
    defer curl.globalDeinit();
    var audit: CredentialWipeAudit = .{};
    try credentialAllocationFixture(audit.allocator());
    try std.testing.expectEqual(@as(usize, 2), audit.secret_frees);
    try std.testing.expect(audit.wiped);
}

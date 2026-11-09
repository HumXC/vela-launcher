//! Bounded background curl Multi service. See docs/downloader.md for ownership.
//! Call curl.globalInit before init, globalDeinit after all services are destroyed.
//! Io and allocator must support ordinary concurrent OS threads.
const std = @import("std");
const curl = @import("curl");
const support = @import("curl_support.zig");
const artifact_cache = @import("artifact_cache.zig");
const diagnostic_log = @import("diagnostic_log.zig");
var diagnostic_sequence: std.atomic.Value(u64) = .init(1);
const http_cache_policy = @import("http_cache_policy.zig");
const CacheHeaders = @import("http_cache_headers.zig").Owned;
const cache_user_agent = "Vela/1";
pub const CacheMode = enum { prefer_cache, revalidate, bypass };
pub const CachePolicy = struct { store: bool = false, fresh_until: i64 = 0 };
const network_proxy = @import("proxy_policy.zig");
pub const Budget = @import("download_budget.zig").Budget;
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
    if (key.len == 0 or key.len > 4096) return error.InvalidCredentialScope;
    for (key) |byte| if (byte < 33 or byte > 126) return error.InvalidCredentialScope;
}

fn timeoutAsLong(timeout_ms: u32) error{InvalidTimeout}!c_long {
    return std.math.cast(c_long, timeout_ms) orelse error.InvalidTimeout;
}

test "retry classification excludes certificate local and permanent protocol failures" {
    for ([_]c.CURLcode{ c.CURLE_SSL_CONNECT_ERROR, c.CURLE_RECV_ERROR, c.CURLE_PARTIAL_FILE, c.CURLE_OPERATION_TIMEDOUT }) |code| try std.testing.expect(retryableTransport(code));
    for ([_]c.CURLcode{ c.CURLE_PEER_FAILED_VERIFICATION, c.CURLE_SSL_CACERT_BADFILE, c.CURLE_WRITE_ERROR, c.CURLE_OUT_OF_MEMORY, c.CURLE_UNSUPPORTED_PROTOCOL, c.CURLE_ABORTED_BY_CALLBACK }) |code| try std.testing.expect(!retryableTransport(code));
    try std.testing.expectEqual(error.TlsCertificateInvalid, transportFailure(c.CURLE_PEER_FAILED_VERIFICATION));
    try std.testing.expectEqual(error.OutOfMemory, transportFailure(c.CURLE_OUT_OF_MEMORY));
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
pub const Source = enum { network, revalidated, fresh, artifact };
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
    expected_sha256: ?[32]u8 = null,
    expected_sha512: ?[64]u8 = null,
    /// Content-addressed file cache under this root; ignored without a trusted hash.
    /// Callers must authorize provider access before submit, including cache hits.
    artifact_cache_root: ?[]const u8 = null,
    expected_size: ?u64 = null,
    /// null: 16MiB for memory outputs, unlimited for streamed files.
    max_bytes: ?usize = null,
    /// Persistent conditional cache for public JSON/bytes GETs only. File tasks
    /// use expected_sha1 instead; combining file and cache_path is rejected.
    /// Cache paths must not be shared by simultaneous Service instances.
    cache_path: ?[]const u8 = null,
    cache_mode: CacheMode = .prefer_cache,
    /// Null captures launcher defaults; empty forces direct; explicit ignores bypass.
    proxy: ?[]const u8 = null,
    proxy_policy: ?*const network_proxy.Policy = null,
    /// PEM trust for both the origin and HTTPS proxy. Null loads native trust.
    ca_bundle: ?[]const u8 = null,
    /// Zero disables the total and explicit connection timeouts, not concurrency limits.
    timeout_ms: u32 = 120_000,
    /// Abort if throughput remains below one byte/second for this many seconds.
    /// Zero disables this optional protection.
    stall_timeout_seconds: u32 = 0,
    /// Prevent initial or redirected requests from using plaintext HTTP.
    https_only: bool = false,
    /// Disable redirects for provider-pinned or otherwise sensitive transfers.
    follow_redirects: bool = true,
    /// Direct routes guard resolved sockets; proxies retain target URL checks.
    /// Public-only downloads do not follow redirects.
    require_public_address: bool = false,
};
pub const Result = union(enum) { file: []const u8, bytes: []const u8, json: std.json.Value };
pub const Snapshot = struct { progress: Progress, result: ?Result, failure: ?anyerror, source: Source, http_status: u16, cache_policy: CachePolicy = .{} };
const cache_meta_version: u8 = 2;
const CacheMeta = struct {
    url: []const u8,
    sha1: [20]u8,
    version: u8,
    headers: http_cache_policy.Headers,
    request_time: i64,
    response_time: i64,
    user_agent: []const u8,
    accept_encoding: []const u8,
};

pub const Task = struct {
    service: *Service,
    request: Request,
    url: [:0]u8,
    curseforge_download_key: ?[]u8 = null,
    policy: ?network_proxy.Policy = null,
    route: ?network_proxy.Route = null,
    initial_url: ?[:0]u8 = null,
    location: std.ArrayList(u8) = .empty,
    redirects: u8 = 0,
    network_retries: u8 = 0,
    retry_at_ns: ?i96 = null,
    retry_after_seconds: ?u64 = null,
    deadline_ns: ?i96 = null,
    ca: ?[:0]u8 = null,
    destination: ?[]u8 = null,
    artifact_path: ?[]u8 = null,
    artifact_hit: bool = false,
    cache_path: ?[]u8 = null,
    meta_path: ?[]u8 = null,
    temp: []u8,
    progress: Progress = .{},
    result: ?Result = null,
    failure: ?anyerror = null,
    source: Source = .network,
    http_status: u16 = 0,
    canceled: std.atomic.Value(bool) = .init(false),
    completion: std.Io.Event = .unset,
    release_requested: bool = false,
    easy: ?*c.CURL = null,
    budget_held: bool = false,
    headers: ?*c.curl_slist = null,
    file: ?std.Io.File = null,
    owns_temp: bool = false,
    body: std.ArrayList(u8) = .empty,
    parsed: ?std.json.Parsed(std.json.Value) = null,
    cache_meta: ?std.json.Parsed(CacheMeta) = null,
    hash: std.crypto.hash.Sha1 = .init(.{}),
    hash256: std.crypto.hash.sha2.Sha256 = .init(.{}),
    hash512: std.crypto.hash.sha2.Sha512 = .init(.{}),
    count: u64 = 0,
    response_headers: CacheHeaders = .{},
    request_time: i64 = 0,
    response_time: i64 = 0,
    fresh_hit: bool = false,
    cache_policy: CachePolicy = .{},
    status: u16 = 0,
    callback_error: ?anyerror = null,
    retry_unconditional: bool = false,
    diagnostic_id: u64 = 0,
    diagnostic_started: i96 = 0,
    curl_error: [c.CURL_ERROR_SIZE]u8 = @splat(0),
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
        return .{ .progress = self.progress, .result = self.result, .failure = self.failure, .source = self.source, .http_status = self.http_status, .cache_policy = self.cache_policy };
    }
    /// Worker-only wait: completion wakes immediately; the bounded timeout lets
    /// callers check their external cancellation tokens and publish progress.
    pub fn wait(self: *Task) std.Io.Cancelable!void {
        self.completion.waitTimeout(self.service.io, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return error.Canceled,
        };
    }

    /// Cleanup wait after cancellation, or when no progress polling is needed.
    /// The owner must still release the terminal task before destroying Service.
    pub fn join(self: *Task) void {
        self.completion.waitUncancelable(self.service.io);
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
        const elapsed_ms = @divTrunc(std.Io.Clock.awake.now(s.io).nanoseconds - self.diagnostic_started, std.time.ns_per_ms);
        if (err) |failure_reason| {
            if (failure_reason == error.Canceled) {
                diagnostic_log.write(.info, .download, "canceled id={d} elapsed_ms={d} bytes={d} file={s}", .{ self.diagnostic_id, elapsed_ms, self.count, self.destination orelse "<metadata>" });
            } else {
                diagnostic_log.write(.err, .download, "failed id={d} error={s} http={d} elapsed_ms={d} bytes={d} file={s} url={s}", .{ self.diagnostic_id, @errorName(failure_reason), self.http_status, elapsed_ms, self.count, self.destination orelse "<metadata>", self.url });
            }
        } else {
            diagnostic_log.write(.info, .download, "complete id={d} source={s} http={d} elapsed_ms={d} bytes={d} file={s}", .{ self.diagnostic_id, @tagName(self.source), self.http_status, elapsed_ms, self.count, self.destination orelse "<metadata>" });
        }
        self.completion.set(s.io);
        s.completion_revision +%= 1;
        s.completed.broadcast(s.io);
    }
};
fn artifactHashes(request: Request) artifact_cache.Hashes {
    return .{ .sha1 = request.expected_sha1, .sha256 = request.expected_sha256, .sha512 = request.expected_sha512 };
}

pub const Service = struct {
    allocator: Allocator,
    io: std.Io,
    multi: *c.CURLM,
    thread: ?std.Thread = null,
    worker: ?std.Thread = null,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    completed: std.Io.Condition = .init,
    completion_revision: u64 = 0,
    tasks: [capacity]?*Task = @splat(null),
    stopping: std.atomic.Value(bool) = .init(false),
    network_done: bool = false,
    max_active: usize,
    budget: *Budget,
    ca_bundle: std.ArrayList(u8) = .empty,
    ca_loaded: bool = false,
    pub fn init(a: Allocator, io: std.Io, budget: *Budget, max_active: usize) !*Service {
        if (max_active == 0 or max_active > capacity) return error.InvalidConcurrency;
        const s = try a.create(Service);
        errdefer a.destroy(s);
        const multi = c.curl_multi_init() orelse return error.CurlInit;
        errdefer _ = c.curl_multi_cleanup(multi);
        s.* = .{ .allocator = a, .io = io, .multi = multi, .max_active = max_active, .budget = budget };
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
    /// Capture before scanning a batch so a completion during the scan cannot
    /// be lost between observing task snapshots and starting the wait.
    pub fn completionRevision(self: *Service) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.completion_revision;
    }
    pub fn waitForCompletion(self: *Service, observed: u64) std.Io.Cancelable!void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (observed != self.completion_revision) return;
        self.completed.waitTimeout(self.io, &self.mutex, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return error.Canceled,
        };
    }

    pub fn submit(self: *Service, request: Request) !*Task {
        try validateCredentialRequest(request);
        _ = try timeoutAsLong(request.timeout_ms);
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
        t.* = .{ .service = self, .request = request, .url = try a.dupeSentinel(u8, request.url, 0), .temp = undefined, .diagnostic_id = diagnostic_sequence.fetchAdd(1, .monotonic), .diagnostic_started = std.Io.Clock.awake.now(self.io).nanoseconds };
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
        t.artifact_path = if (request.output == .file) if (request.artifact_cache_root) |root| try artifactHashes(request).path(a, root) else null else null;
        errdefer if (t.artifact_path) |p| a.free(p);
        t.request.artifact_cache_root = null;
        t.cache_path = if (request.cache_path) |p| try a.dupe(u8, p) else null;
        errdefer if (t.cache_path) |p| a.free(p);
        t.meta_path = if (request.cache_path) |p| try std.fmt.allocPrint(a, "{s}.meta.json", .{p}) else null;
        errdefer if (t.meta_path) |p| a.free(p);
        t.policy = if (request.proxy_policy) |value| try value.clone(a) else try network_proxy.capture(a, self.io, request.proxy);
        errdefer t.policy.?.deinit();
        t.request.proxy_policy = null;
        t.request.proxy = null;
        t.initial_url = try a.dupeSentinel(u8, request.url, 0);
        errdefer a.free(t.initial_url.?);
        t.ca = if (request.ca_bundle) |p| try a.dupeSentinel(u8, p, 0) else null;
        errdefer if (t.ca) |p| a.free(p);
        var nonce: [16]u8 = undefined;
        try std.Io.randomSecure(self.io, &nonce);
        t.temp = try std.fmt.allocPrint(a, "{s}.vela-{s}.part", .{ t.destination orelse t.cache_path orelse "download", std.fmt.bytesToHex(nonce, .lower) });
        diagnostic_log.write(.info, .download, "queued id={d} file={s} url={s}", .{ t.diagnostic_id, t.destination orelse "<metadata>", t.url });
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
        t.response_headers.deinit(self.allocator);
        self.allocator.free(t.url);
        self.allocator.free(t.temp);
        if (t.destination) |p| self.allocator.free(p);
        if (t.artifact_path) |p| self.allocator.free(p);
        if (t.cache_path) |p| self.allocator.free(p);
        if (t.meta_path) |p| self.allocator.free(p);
        if (t.route) |*route| route.deinit();
        if (t.policy) |*policy| policy.deinit();
        if (t.initial_url) |url| self.allocator.free(url);
        t.location.deinit(self.allocator);
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
                t.progress.phase = if (t.fresh_hit or t.artifact_hit) .processing else .ready;
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
        try self.checkTask(t);
        if (t.deadline_ns == null and t.request.timeout_ms != 0) t.deadline_ns = std.Io.Clock.awake.now(self.io).nanoseconds + @as(i96, t.request.timeout_ms) * std.time.ns_per_ms;
        if (t.redirects == 0) if (t.artifact_path) |path| {
            const count: ?u64 = artifact_cache.copyVerified(self.io, path, t.temp, artifactHashes(t.request), t.request.expected_size, t.limit(), &t.canceled) catch |err| switch (err) {
                error.Canceled => return err,
                error.FileNotFound => null,
                else => blk: {
                    diagnostic_log.write(.warn, .download, "cache_rejected id={d} error={s} file={s}", .{ t.diagnostic_id, @errorName(err), t.destination orelse "<metadata>" });
                    break :blk null;
                },
            };
            if (count) |n| {
                t.owns_temp = true;
                t.artifact_hit = true;
                t.count = n;
                self.mutex.lockUncancelable(self.io);
                t.source = .artifact;
                t.progress.received = n;
                t.progress.total = n;
                t.progress.bytes_per_second = 0;
                t.progress.eta_seconds = null;
                self.mutex.unlock(self.io);
                return;
            }
        };
        if (t.redirects == 0 and !t.retry_unconditional and t.request.cache_mode != .bypass) {
            try self.loadCache(t);
            if (t.fresh_hit) return;
        }
        if (t.route == null) t.route = try t.policy.?.resolve(self.io, t.url);
        try self.checkTask(t);
        if (t.request.require_public_address and t.route.?.proxy.len != 0) try network_proxy.guardTarget(self.allocator, t.url);
        if (!self.ca_loaded and t.ca == null) {
            self.ca_bundle = try support.collectNativeCA(self.allocator, self.io);
            self.ca_loaded = true;
        }
        if (t.destination != null) {
            t.file = try std.Io.Dir.cwd().createFile(self.io, t.temp, .{ .exclusive = true });
            t.owns_temp = true;
        }
    }
    fn checkTask(self: *Service, t: *Task) !void {
        if (t.canceled.load(.acquire)) return error.Canceled;
        if (t.deadline_ns) |deadline| if (std.Io.Clock.awake.now(self.io).nanoseconds >= deadline) return error.TimedOut;
    }
    fn loadCache(self: *Service, t: *Task) !void {
        if (t.request.https_only and !std.mem.startsWith(u8, t.url, "https://")) return;
        const path = t.meta_path orelse return;
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(64 * 1024)) catch return;
        defer self.allocator.free(data);
        const parsed = std.json.parseFromSlice(CacheMeta, self.allocator, data, .{ .allocate = .alloc_always }) catch return;
        const meta = parsed.value;
        if (meta.version != cache_meta_version or !std.mem.eql(u8, meta.url, t.url) or
            !validValidator(meta.headers.etag orelse "") or !validValidator(meta.headers.last_modified orelse "") or
            !std.mem.eql(u8, meta.user_agent, cache_user_agent) or !std.mem.eql(u8, meta.accept_encoding, "identity") or
            !supportedVary(meta.headers.vary) or !http_cache_policy.evaluate(meta.headers, meta.request_time, meta.response_time, unixSeconds(self.io)).store)
        {
            parsed.deinit();
            return;
        }
        t.cache_meta = parsed;
        const decision = http_cache_policy.evaluate(meta.headers, meta.request_time, meta.response_time, unixSeconds(self.io));
        // SWR is conservatively synchronous.
        t.fresh_hit = t.request.cache_mode == .prefer_cache and unixSeconds(self.io) < decision.fresh_until;
    }
    fn followRedirect(self: *Service, t: *Task) !void {
        if (t.redirects >= 10) return error.TooManyRedirects;
        const next = try resolveRedirect(self.allocator, t.url, t.location.items, t.request.https_only);
        self.cleanup(t);
        self.allocator.free(t.url);
        t.url = next;
        t.redirects += 1;
        if (t.route) |*route| route.deinit();
        t.route = null;
        self.mutex.lockUncancelable(self.io);
        t.progress.phase = .queued;
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
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
                if (t.snapshot().progress.phase != .ready) continue;
                if (t.retry_at_ns) |ready_at| {
                    self.checkTask(t) catch |err| {
                        self.cleanup(t);
                        t.finish(err, null);
                        continue;
                    };
                    if (std.Io.Clock.awake.now(self.io).nanoseconds < ready_at) continue;
                    t.retry_at_ns = null;
                    self.mutex.lockUncancelable(self.io);
                    t.progress.phase = .queued;
                    self.condition.signal(self.io);
                    self.mutex.unlock(self.io);
                    continue;
                }
                if (active >= self.max_active) continue;
                if (!self.budget.tryAcquire()) continue;
                t.budget_held = true;
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
                        if (code != c.CURLE_OK and !t.canceled.load(.acquire)) {
                            diagnostic_log.write(.err, .download, "transport id={d} curl_code={d} reason={s} detail={s} url={s}", .{ t.diagnostic_id, code, std.mem.span(c.curl_easy_strerror(code)), std.mem.sliceTo(&t.curl_error, 0), t.url });
                        }
                        self.detach(t);
                        if (!http_cache_policy.evaluate(t.response_headers.view(), t.request_time, t.response_time, unixSeconds(self.io)).store or !supportedVary(t.response_headers.view().vary)) {
                            // A 304 still needs the verified body for this response only.
                            if (t.status == 304) {
                                if (t.meta_path) |path| std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
                            } else self.invalidateCache(t);
                        }
                        if (t.callback_error) |err| {
                            self.cleanup(t);
                            t.finish(err, null);
                        } else if (code != c.CURLE_OK) {
                            if (retryableTransport(code) and self.scheduleRetry(t)) break;
                            self.cleanup(t);
                            t.finish(transportFailure(code), null);
                        } else if (t.request.follow_redirects and !t.request.require_public_address and isRedirect(t.status) and t.location.items.len != 0) {
                            self.followRedirect(t) catch |err| {
                                self.cleanup(t);
                                t.finish(err, null);
                            };
                        } else if (t.status != 200 and t.status != 304) {
                            if (retryableStatus(t.status) and self.scheduleRetry(t)) break;
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
    // Network-thread only. Publish readiness only after old output is discarded.
    // The preparation worker recreates the temporary file before the next attempt.
    fn scheduleRetry(self: *Service, t: *Task) bool {
        if (t.network_retries >= 3 or t.canceled.load(.acquire) or self.stopping.load(.acquire)) return false;
        const retry_after = t.retry_after_seconds orelse 0;
        if (retry_after > 86400) return false; // Never retry earlier than a long server delay.
        const delay_ms: u64 = @max((@as(u64, 500) << @intCast(t.network_retries)) + t.diagnostic_id % 251, retry_after * 1000);
        const ready_at = std.Io.Clock.awake.now(self.io).nanoseconds + @as(i96, delay_ms) * std.time.ns_per_ms;
        if (t.deadline_ns) |deadline| if (ready_at >= deadline) return false;
        diagnostic_log.write(.warn, .download, "retry id={d} retry={d}/3 delay_ms={d} http={d} url={s}", .{ t.diagnostic_id, t.network_retries + 1, delay_ms, t.status, t.url });
        self.cleanup(t);
        if (t.cache_meta) |meta| meta.deinit();
        t.cache_meta = null;
        t.fresh_hit = false;
        t.network_retries += 1;
        t.retry_at_ns = ready_at;
        self.mutex.lockUncancelable(self.io);
        t.progress = .{ .phase = .ready };
        self.mutex.unlock(self.io);
        return true;
    }
    fn start(self: *Service, t: *Task) !void {
        if (t.canceled.load(.acquire)) return error.Canceled;
        const e = c.curl_easy_init() orelse return error.CurlInit;
        t.easy = e;
        t.count = 0;
        t.status = 0;
        t.retry_after_seconds = null;
        t.location.clearRetainingCapacity();
        t.hash = .init(.{});
        t.hash256 = .init(.{});
        t.hash512 = .init(.{});
        t.body.clearRetainingCapacity();
        t.response_headers.clear();
        t.request_time = unixSeconds(self.io);
        t.callback_error = null;
        t.curl_error = @splat(0);
        try set(e, c.CURLOPT_ERRORBUFFER, &t.curl_error);
        try set(e, c.CURLOPT_URL, t.url.ptr);
        try set(e, c.CURLOPT_USERAGENT, @as([*:0]const u8, cache_user_agent));
        try set(e, c.CURLOPT_ACCEPT_ENCODING, @as([*:0]const u8, "identity"));
        try set(e, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
        // A returned permit must not leave an idle cached connection behind.
        try set(e, c.CURLOPT_FORBID_REUSE, @as(c_long, 1));
        try set(e, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 0));
        try set(e, c.CURLOPT_MAXREDIRS, @as(c_long, 10));
        const protocols: [*:0]const u8 = if (t.request.https_only) "https" else "http,https";
        try set(e, c.CURLOPT_PROTOCOLS_STR, protocols);
        try set(e, c.CURLOPT_REDIR_PROTOCOLS_STR, protocols);
        var remaining = t.request.timeout_ms;
        if (t.deadline_ns) |deadline| {
            const ns = deadline - std.Io.Clock.awake.now(self.io).nanoseconds;
            if (ns <= 0) return error.TimedOut;
            remaining = @intCast(@min(@as(i96, t.request.timeout_ms), @divTrunc(ns + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
        }
        try set(e, c.CURLOPT_TIMEOUT_MS, try timeoutAsLong(remaining));
        try set(e, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, @min(remaining, 30_000)));
        try set(e, c.CURLOPT_LOW_SPEED_LIMIT, @as(c_long, if (t.request.stall_timeout_seconds == 0) 0 else 1));
        try set(e, c.CURLOPT_LOW_SPEED_TIME, try timeoutAsLong(t.request.stall_timeout_seconds));
        try set(e, c.CURLOPT_WRITEFUNCTION, &writeCallback);
        try set(e, c.CURLOPT_WRITEDATA, t);
        try set(e, c.CURLOPT_HEADERFUNCTION, &headerCallback);
        try set(e, c.CURLOPT_HEADERDATA, t);
        try set(e, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
        try set(e, c.CURLOPT_XFERINFOFUNCTION, &progressCallback);
        try set(e, c.CURLOPT_XFERINFODATA, t);
        try support.configure(e, &t.route.?, t.ca, self.ca_bundle.items, t.request.require_public_address, &t.callback_error);
        if (!t.retry_unconditional and t.request.cache_mode != .bypass and t.redirects == 0) if (t.cache_meta) |meta| {
            const etag = meta.value.headers.etag orelse "";
            const value = if (etag.len > 0) etag else meta.value.headers.last_modified orelse "";
            if (value.len > 0) {
                const h = try std.fmt.allocPrintSentinel(self.allocator, "{s}: {s}", .{ if (etag.len > 0) "If-None-Match" else "If-Modified-Since", value }, 0);
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
        t.http_status = 0;
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
        if (t.budget_held) {
            t.budget_held = false;
            self.budget.release();
        }
        if (t.headers) |h| {
            // libcurl owns these allocations, but its free does not erase secrets.
            support.freeHeaders(h);
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
        t.fresh_hit = false;
        t.body.clearRetainingCapacity();
        self.mutex.lockUncancelable(self.io);
        t.source = .network;
        t.progress.phase = .queued;
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
        _ = c.curl_multi_wakeup(self.multi);
        return null;
    }
    fn process(self: *Service, t: *Task) !?Result {
        try self.checkTask(t);
        if (t.fresh_hit) {
            const meta = t.cache_meta.?.value;
            if (unixSeconds(self.io) >= http_cache_policy.evaluate(meta.headers, meta.request_time, meta.response_time, unixSeconds(self.io)).fresh_until) return self.retry(t);
        }
        if (t.status == 304 or t.fresh_hit) {
            const meta = t.cache_meta orelse return error.UnexpectedNotModified;
            const data = std.Io.Dir.cwd().readFileAlloc(self.io, t.cache_path.?, self.allocator, .limited(t.limit())) catch return self.retry(t);
            defer self.allocator.free(data);
            var digest: [20]u8 = undefined;
            std.crypto.hash.Sha1.hash(data, &digest, .{});
            if (!std.mem.eql(u8, &digest, &meta.value.sha1)) return self.retry(t);
            try t.body.appendSlice(self.allocator, data);
            t.hash = .init(.{});
            t.hash.update(data);
            t.hash256 = .init(.{});
            t.hash256.update(data);
            t.hash512 = .init(.{});
            t.hash512.update(data);
            t.count = data.len;
            self.mutex.lockUncancelable(self.io);
            t.source = if (t.fresh_hit) .fresh else .revalidated;
            self.mutex.unlock(self.io);
        }
        // Invalidate before parsing/integrity failures can leave an old entry reusable.
        if (!t.fresh_hit and (!http_cache_policy.evaluate(t.response_headers.view(), t.request_time, t.response_time, unixSeconds(self.io)).store or !supportedVary(t.response_headers.view().vary))) self.invalidateCache(t);
        if (t.request.expected_size) |size| if (size != t.count) {
            if (t.status == 304 or t.fresh_hit) return self.retry(t);
            return error.SizeMismatch;
        };
        var digest: [20]u8 = undefined;
        t.hash.final(&digest);
        if (!t.artifact_hit) if (t.request.expected_sha1) |expected| if (!std.mem.eql(u8, &digest, &expected)) {
            if (t.status == 304 or t.fresh_hit) return self.retry(t);
            return error.Sha1Mismatch;
        };
        if (!t.artifact_hit) {
            if (t.request.expected_sha256) |expected| {
                var actual: [32]u8 = undefined;
                t.hash256.final(&actual);
                if (!std.mem.eql(u8, &actual, &expected)) {
                    if (t.status == 304 or t.fresh_hit) return self.retry(t);
                    return error.Sha256Mismatch;
                }
            }
            if (t.request.expected_sha512) |expected| {
                var actual: [64]u8 = undefined;
                t.hash512.final(&actual);
                if (!std.mem.eql(u8, &actual, &expected)) {
                    if (t.status == 304 or t.fresh_hit) return self.retry(t);
                    return error.Sha512Mismatch;
                }
            }
        }
        const result: Result = switch (t.request.output) {
            .json => blk: {
                t.parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, t.body.items, .{ .allocate = .alloc_always });
                break :blk .{ .json = t.parsed.?.value };
            },
            .bytes => .{ .bytes = t.body.items },
            .file => .{ .file = t.destination.? },
        };
        try self.checkTask(t);
        self.mutex.lockUncancelable(self.io);
        if (t.canceled.load(.acquire)) {
            self.mutex.unlock(self.io);
            return error.Canceled;
        }
        // Commit linearization point: subsequent cancellation is ignored.
        t.progress.phase = .committing;
        self.mutex.unlock(self.io);
        if (!t.artifact_hit) if (t.artifact_path) |path| {
            // Preserve complete downloads even if later destination/install publication fails.
            artifact_cache.publish(self.allocator, self.io, t.temp, path, artifactHashes(t.request), t.request.expected_size, t.limit()) catch |err| {
                diagnostic_log.write(.warn, .download, "cache_publish_failed id={d} error={s}", .{ t.diagnostic_id, @errorName(err) });
            };
        };
        if (t.destination) |path| {
            try std.Io.Dir.cwd().rename(t.temp, std.Io.Dir.cwd(), path, self.io);
            t.owns_temp = false;
        }
        // A successful, verified result is independent of optional persistence.
        self.saveCache(t, digest) catch {};
        return result;
    }
    fn saveCache(self: *Service, t: *Task, digest: [20]u8) !void {
        const old = if (t.cache_meta) |m| m.value else null;
        const previous: ?http_cache_policy.Headers = if (old) |meta| meta.headers else null;
        const headers = if (t.fresh_hit) old.?.headers else mergedHeaders(t.response_headers.view(), if (t.status == 304) previous else null);
        const request_time = if (t.fresh_hit) old.?.request_time else t.request_time;
        const response_time = if (t.fresh_hit) old.?.response_time else t.response_time;
        const decision = http_cache_policy.evaluate(headers, request_time, response_time, unixSeconds(self.io));
        const store = decision.store and supportedVary(headers.vary) and t.redirects == 0 and t.request.cache_mode != .bypass and t.curseforge_download_key == null and t.destination == null;
        self.mutex.lockUncancelable(self.io);
        t.cache_policy = .{ .store = store, .fresh_until = if (store) decision.fresh_until else 0 };
        self.mutex.unlock(self.io);
        if (t.cache_path == null or t.request.cache_mode == .bypass) return;
        if (!store) {
            self.invalidateCache(t);
            return;
        }
        if (t.fresh_hit) return;
        const meta: CacheMeta = .{ .url = t.url, .sha1 = digest, .version = cache_meta_version, .headers = headers, .request_time = request_time, .response_time = response_time, .user_agent = cache_user_agent, .accept_encoding = "identity" };
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, meta, .{});
        defer self.allocator.free(encoded);
        // Two atomic replacements; digest binds the pair across crash windows.
        if (t.status != 304) try self.atomicWrite(t.cache_path.?, t.temp, t.body.items);
        const tmp = try std.fmt.allocPrint(self.allocator, "{s}.meta", .{t.temp});
        defer self.allocator.free(tmp);
        try self.atomicWrite(t.meta_path.?, tmp, encoded);
    }
    fn invalidateCache(self: *Service, t: *Task) void {
        if (t.meta_path) |path| std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
        if (t.cache_path) |path| std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
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
fn unixSeconds(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}
fn supportedVary(raw: ?[]const u8) bool {
    var tokens = std.mem.splitScalar(u8, raw orelse "", ',');
    while (tokens.next()) |part| {
        const name = std.mem.trim(u8, part, " \t");
        if (name.len == 0) continue;
        if (!std.ascii.eqlIgnoreCase(name, "accept-encoding") and !std.ascii.eqlIgnoreCase(name, "user-agent") and !std.ascii.eqlIgnoreCase(name, "host")) return false;
    }
    return true;
}
fn mergedHeaders(update: http_cache_policy.Headers, previous: ?http_cache_policy.Headers) http_cache_policy.Headers {
    var result = update;
    if (previous) |old| {
        inline for (.{ "cache_control", "expires", "etag", "last_modified", "vary" }) |field| {
            if (@field(result, field) == null) @field(result, field) = @field(old, field);
        }
        // Date and Age describe this validation, never the original response age.
    }
    return result;
}
fn isRedirect(status: u16) bool {
    return status == 301 or status == 302 or status == 303 or status == 307 or status == 308;
}
fn resolveRedirect(a: Allocator, base: [:0]const u8, location: []const u8, https_only: bool) ![:0]u8 {
    if (location.len == 0 or location.len > 8192) return error.InvalidUrl;
    for (location) |byte| if (byte < 32 or byte == 127 or byte == 92) return error.InvalidUrl;
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
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if (!(std.mem.eql(u8, uri.scheme, "https") or (!https_only and std.mem.eql(u8, uri.scheme, "http"))) or uri.user != null or uri.password != null) return error.InvalidUrl;
    return a.dupeSentinel(u8, url, 0);
}
fn validValidator(s: []const u8) bool {
    return s.len <= 8192 and std.mem.indexOfAny(u8, s, "\r\n") == null;
}
fn retryableTransport(code: c.CURLcode) bool {
    return switch (code) {
        c.CURLE_COULDNT_RESOLVE_PROXY, c.CURLE_COULDNT_RESOLVE_HOST, c.CURLE_COULDNT_CONNECT, c.CURLE_OPERATION_TIMEDOUT, c.CURLE_SSL_CONNECT_ERROR, c.CURLE_SEND_ERROR, c.CURLE_RECV_ERROR, c.CURLE_GOT_NOTHING, c.CURLE_PARTIAL_FILE, c.CURLE_HTTP2, c.CURLE_HTTP2_STREAM => true,
        else => false,
    };
}
fn retryableStatus(status: u16) bool {
    return switch (status) {
        408, 429, 500, 502, 503, 504 => true,
        else => false,
    };
}
fn transportFailure(code: c.CURLcode) anyerror {
    return switch (code) {
        c.CURLE_OPERATION_TIMEDOUT => error.TimedOut,
        c.CURLE_COULDNT_RESOLVE_HOST, c.CURLE_COULDNT_RESOLVE_PROXY => error.NameResolutionFailed,
        c.CURLE_COULDNT_CONNECT, c.CURLE_SSL_CONNECT_ERROR, c.CURLE_SEND_ERROR, c.CURLE_RECV_ERROR, c.CURLE_GOT_NOTHING, c.CURLE_PARTIAL_FILE, c.CURLE_HTTP2, c.CURLE_HTTP2_STREAM => error.NetworkConnectionFailed,
        c.CURLE_PEER_FAILED_VERIFICATION => error.TlsCertificateInvalid,
        c.CURLE_OUT_OF_MEMORY => error.OutOfMemory,
        else => error.TransferFailed,
    };
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
    if (t.request.expected_sha256 != null) t.hash256.update(data);
    if (t.request.expected_sha512 != null) t.hash512.update(data);
    t.count += data.len;
    return data.len;
}
fn headerCallback(ptr: [*c]u8, size: usize, nmemb: usize, userdata: ?*anyopaque) callconv(.c) usize {
    const t: *Task = @ptrCast(@alignCast(userdata.?));
    const data = ptr[0 .. size * nmemb];
    if (std.mem.startsWith(u8, data, "HTTP/")) {
        t.response_headers.clear();
        t.retry_after_seconds = null;
        t.response_time = unixSeconds(t.service.io);
        t.location.clearRetainingCapacity();
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
        if (std.ascii.eqlIgnoreCase(name, "retry-after")) {
            t.retry_after_seconds = std.fmt.parseInt(u64, value, 10) catch blk: {
                var date: [128:0]u8 = @splat(0);
                if (value.len >= date.len) break :blk null;
                @memcpy(date[0..value.len], value);
                const seconds = c.curl_getdate(&date, null);
                if (seconds < 0) break :blk null;
                break :blk @intCast(@max(0, seconds - unixSeconds(t.service.io)));
            };
        }
        t.response_headers.append(t.service.allocator, name, value) catch |err| {
            t.callback_error = err;
            return 0;
        };
        const dest: ?*std.ArrayList(u8) = if (std.ascii.eqlIgnoreCase(name, "location")) &t.location else null;
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
    var budget = try Budget.init(std.testing.io, 1);
    defer budget.deinit();
    var service: Service = .{ .allocator = std.testing.allocator, .io = std.testing.io, .multi = undefined, .max_active = 1, .budget = &budget };
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
    var budget = try Budget.init(std.testing.io, 1);
    defer budget.deinit();
    var service: Service = .{ .allocator = a, .io = std.testing.io, .multi = multi, .max_active = 1, .budget = &budget };
    var request = credentialFixtureRequest();
    request.ca_bundle = "fixture-ca-never-opened";
    request.proxy = "";
    const task = try service.submit(request);
    defer service.destroyTask(task);
    try service.prepare(task);
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
    var budget = try Budget.init(std.testing.io, 1);
    defer budget.deinit();
    var service: Service = .{ .allocator = std.testing.allocator, .io = std.testing.io, .multi = undefined, .max_active = 1, .budget = &budget };
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
    for (0..4) |option| {
        var request = credentialFixtureRequest();
        switch (option) {
            0 => request.https_only = false,
            1 => request.follow_redirects = true,
            2 => request.require_public_address = false,
            3 => request.cache_path = "must-not-create-cache",
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
    var budget = try Budget.init(std.testing.io, 1);
    defer budget.deinit();
    var service: Service = .{ .allocator = audit.allocator(), .io = std.testing.io, .multi = multi, .max_active = 1, .budget = &budget };
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
            try service.prepare(task);
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

test "completion notification preserves early and concurrent terminal publication" {
    const io = std.testing.io;
    const multi = c.curl_multi_init() orelse return error.CurlInit;
    defer _ = c.curl_multi_cleanup(multi);
    var budget = try Budget.init(io, 1);
    defer budget.deinit();
    var service: Service = .{ .allocator = std.testing.allocator, .io = io, .multi = multi, .max_active = 1, .budget = &budget };
    var url = "https://example.invalid/notification".*;
    var task: Task = .{ .service = &service, .request = .{ .url = &url }, .url = &url, .temp = &.{} };
    const revision = service.completionRevision();
    task.finish(error.ChecksumMismatch, null);
    try service.waitForCompletion(revision);
    try task.wait();
    task.join();
    task.cancel();
    try std.testing.expectEqual(error.ChecksumMismatch, task.snapshot().failure.?);
    try std.testing.expect(service.completionRevision() != revision);

    var pending: Task = .{ .service = &service, .request = .{ .url = &url }, .url = &url, .temp = &.{} };
    const Waiter = struct {
        fn run(target: *Task, started: *std.Io.Event) void {
            started.set(target.service.io);
            target.join();
        }
    };
    var started: std.Io.Event = .unset;
    const thread = try std.Thread.spawn(.{}, Waiter.run, .{ &pending, &started });
    defer thread.join();
    started.waitUncancelable(io);
    pending.cancel();
    pending.finish(null, null);
    try std.testing.expectEqual(Phase.canceled, pending.snapshot().progress.phase);
    try std.testing.expect(pending.completion.isSet());
}

test "downloader Vary identity and validation metadata merging" {
    try std.testing.expect(supportedVary("Accept-Encoding, User-Agent, Host"));
    try std.testing.expect(!supportedVary("Accept-Encoding, *"));
    try std.testing.expect(!supportedVary("Cookie"));
    const old: http_cache_policy.Headers = .{ .cache_control = "max-age=60", .etag = "old", .age = "59", .date = "invalid old date", .vary = "Accept-Encoding" };
    const merged = mergedHeaders(.{ .etag = "new" }, old);
    try std.testing.expectEqualStrings("new", merged.etag.?);
    try std.testing.expectEqualStrings("Accept-Encoding", merged.vary.?);
    try std.testing.expect(merged.age == null and merged.date == null);
    try std.testing.expectEqual(@as(i64, 160), http_cache_policy.evaluate(merged, 100, 100, 100).fresh_until);
    try std.testing.expect(!http_cache_policy.evaluate(mergedHeaders(.{ .cache_control = "no-store" }, old), 100, 100, 100).store);
}

test "fresh downloader body completes without network setup and verifies expected integrity" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    try curl.globalInit();
    defer curl.globalDeinit();
    var budget = try Budget.init(io, 1);
    defer budget.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &directory);
    const path = try std.fmt.allocPrint(a, "{s}/body", .{directory[0..n]});
    defer a.free(path);
    const meta_path = try std.fmt.allocPrint(a, "{s}.meta.json", .{path});
    defer a.free(meta_path);
    const bytes = "{\"fresh\":true}";
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(bytes, &digest, .{});
    const now = unixSeconds(io);
    const meta: CacheMeta = .{ .url = "https://cache.invalid/never-requested", .sha1 = digest, .version = cache_meta_version, .headers = .{ .cache_control = "max-age=3600", .vary = "Accept-Encoding" }, .request_time = now, .response_time = now, .user_agent = cache_user_agent, .accept_encoding = "identity" };
    const encoded = try std.json.Stringify.valueAlloc(a, meta, .{});
    defer a.free(encoded);
    const body_file = try std.Io.Dir.cwd().createFile(io, path, .{});
    try body_file.writeStreamingAll(io, bytes);
    body_file.close(io);
    const meta_file = try std.Io.Dir.cwd().createFile(io, meta_path, .{});
    try meta_file.writeStreamingAll(io, encoded);
    meta_file.close(io);
    const service = try Service.init(a, io, &budget, 1);
    defer service.deinit();
    const task = try service.submit(.{ .url = meta.url, .cache_path = path, .output = .json, .expected_sha1 = digest, .expected_size = bytes.len, .proxy = "", .timeout_ms = 1000 });
    defer task.release() catch unreachable;
    task.join();
    const state = task.snapshot();
    try std.testing.expectEqual(Phase.complete, state.progress.phase);
    try std.testing.expectEqual(Source.fresh, state.source);
    try std.testing.expectEqual(@as(u16, 0), state.http_status);
    try std.testing.expect(state.cache_policy.store);
    try std.testing.expect(state.result.?.json.object.get("fresh").?.bool);
    try std.testing.expect(!service.ca_loaded);
    try std.testing.expect(task.route == null);
}

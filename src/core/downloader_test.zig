const std = @import("std");
test {
    _ = @import("downloader_artifact_tests.zig");
    _ = @import("downloader_retry_tests.zig");
}
const curl = @import("curl");
const dl = @import("downloader.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const expect = std.testing.expect;
const eq = std.testing.expectEqual;
fn baseUrl() ![]u8 {
    return std.testing.environ.getAlloc(a, "DOWNLOADER_TEST_URL") catch return error.SkipZigTest;
}
fn url(base: []const u8, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}{s}", .{ base, path });
}
fn wait(t: *dl.Task) !dl.Snapshot {
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    while (true) {
        const state = t.snapshot();
        if (dl.terminal(state.progress.phase)) return state;
        if (std.Io.Clock.awake.now(io).nanoseconds - start > 10_000_000_000) return error.TestTimeout;
        try t.wait();
    }
}
fn success(t: *dl.Task) !dl.Snapshot {
    const state = try wait(t);
    if (state.failure) |err| {
        std.debug.print("download failed: {s}, HTTP {d}\n", .{ @errorName(err), state.http_status });
        return err;
    }
    try eq(dl.Phase.complete, state.progress.phase);
    try expect(state.result != null);
    return state;
}

test "credential scope rejection never dispatches to local fixture or follows its redirect" {
    const base = try baseUrl();
    defer a.free(base);
    try curl.globalInit();
    defer curl.globalDeinit();
    var budget = try dl.Budget.init(io, 1);
    defer budget.deinit();
    const service = try dl.Service.init(a, io, &budget, 1);
    defer service.deinit();
    const blocked_url = try url(base, "/credential-must-not-dispatch");
    defer a.free(blocked_url);
    const redirect_url = try url(base, "/redirect");
    defer a.free(redirect_url);
    for ([_][]const u8{ blocked_url, redirect_url }) |target| {
        try std.testing.expectError(error.InvalidCredentialScope, service.submit(.{
            .url = target,
            .curseforge_download_key = "fixture-only-key",
            .https_only = true,
            .follow_redirects = false,
            .require_public_address = true,
        }));
    }
    const stats_url = try url(base, "/stats");
    defer a.free(stats_url);
    const stats = try service.submit(.{ .url = stats_url, .output = .json });
    defer stats.release() catch unreachable;
    const counts = (try success(stats)).result.?.json.object;
    try expect(counts.get("/credential-must-not-dispatch") == null);
}

test "HTTPS-only requests never dispatch plaintext HTTP" {
    const base = try baseUrl();
    defer a.free(base);
    try curl.globalInit();
    defer curl.globalDeinit();
    var budget = try dl.Budget.init(io, 2);
    defer budget.deinit();
    const service = try dl.Service.init(a, io, &budget, 2);
    defer service.deinit();
    const blocked_url = try url(base, "/https-only-must-not-reach-server");
    defer a.free(blocked_url);
    const blocked = try service.submit(.{ .url = blocked_url, .https_only = true, .timeout_ms = 1000 });
    defer blocked.release() catch unreachable;
    const result = try wait(blocked);
    try eq(dl.Phase.failed, result.progress.phase);
    try eq(error.TransferFailed, result.failure.?);
    try eq(@as(u16, 0), result.http_status);
    try expect(result.result == null);
    const stats_url = try url(base, "/stats");
    defer a.free(stats_url);
    const stats = try service.submit(.{ .url = stats_url, .output = .json });
    defer stats.release() catch unreachable;
    const counts = (try success(stats)).result.?.json.object;
    try expect(counts.get("/https-only-must-not-reach-server") == null);
}
fn put(path: []const u8, data: []const u8) !void {
    const f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, data);
}
fn pathIn(tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    var buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    return std.fmt.allocPrint(a, "{s}/{s}", .{ buf[0..n], name });
}
test "service lifecycle and shutdown rejects submissions" {
    try curl.globalInit();
    defer curl.globalDeinit();
    var budget = try dl.Budget.init(io, 2);
    defer budget.deinit();
    const s = try dl.Service.init(a, io, &budget, 2);
    defer s.deinit();
    const t = try s.submit(.{ .url = "http://127.0.0.1:1/", .timeout_ms = 100 });
    t.cancel();
    s.shutdown();
    try eq(dl.Phase.canceled, (try wait(t)).progress.phase);
    try std.testing.expectError(error.Shutdown, s.submit(.{ .url = "http://127.0.0.1:1/" }));
}
test "streamed file SHA1, mismatch preserves destination, redirect body ignored" {
    const base = try baseUrl();
    defer a.free(base);
    try curl.globalInit();
    defer curl.globalDeinit();
    var budget = try dl.Budget.init(io, 3);
    defer budget.deinit();
    const s = try dl.Service.init(a, io, &budget, 3);
    defer s.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try pathIn(&tmp, "artifact.jar");
    defer a.free(path);
    const u = try url(base, "/bytes");
    defer a.free(u);
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash("hello minecraft\n", &digest, .{});
    const t = try s.submit(.{ .url = u, .output = .{ .file = path }, .expected_sha1 = digest, .expected_size = 16 });
    _ = try success(t);
    const body = try tmp.dir.readFileAlloc(io, "artifact.jar", a, .limited(100));
    defer a.free(body);
    try std.testing.expectEqualStrings("hello minecraft\n", body);
    try t.release();
    const bad = try s.submit(.{ .url = u, .output = .{ .file = path }, .expected_sha1 = @splat(0) });
    try eq(error.Sha1Mismatch, (try wait(bad)).failure.?);
    const preserved = try tmp.dir.readFileAlloc(io, "artifact.jar", a, .limited(100));
    defer a.free(preserved);
    try std.testing.expectEqualStrings(body, preserved);
    const redirect = try url(base, "/redirect");
    defer a.free(redirect);
    const r = try s.submit(.{ .url = redirect, .output = .{ .file = path }, .expected_sha1 = digest });
    _ = try success(r);
    const blocked = try s.submit(.{ .url = redirect, .output = .{ .file = path }, .expected_sha1 = digest, .follow_redirects = false });
    const blocked_result = try wait(blocked);
    try eq(@as(u16, 302), blocked_result.http_status);
    try eq(error.HttpStatus, blocked_result.failure.?);
    const after_blocked = try tmp.dir.readFileAlloc(io, "artifact.jar", a, .limited(100));
    defer a.free(after_blocked);
    try std.testing.expectEqualStrings(body, after_blocked);
}

test "HTTP byte count distinguishes rounded catalogue size from exact streamed length" {
    const base = try baseUrl();
    defer a.free(base);
    try curl.globalInit();
    defer curl.globalDeinit();
    var budget = try dl.Budget.init(io, 1);
    defer budget.deinit();
    const service = try dl.Service.init(a, io, &budget, 1);
    defer service.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try pathIn(&tmp, "java-archive");
    defer a.free(path);
    const u = try url(base, "/slow");
    defer a.free(u);
    const rounded_as_exact = try service.submit(.{ .url = u, .output = .{ .file = path }, .expected_size = 262000 });
    try eq(error.SizeMismatch, (try wait(rounded_as_exact)).failure.?);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(io, path, .{}));
    try rounded_as_exact.release();
    const body: [262144]u8 = @splat('x');
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(&body, &digest, .{});
    const bounded = try service.submit(.{ .url = u, .output = .{ .file = path }, .max_bytes = 262499, .expected_sha1 = digest });
    _ = try success(bounded);
    try bounded.release();
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    try eq(@as(u64, body.len), (try file.stat(io)).size);
}
test "JSON parsing, malformed JSON, limits, HTTP errors and explicit proxy" {
    const base = try baseUrl();
    defer a.free(base);
    try curl.globalInit();
    defer curl.globalDeinit();
    var budget = try dl.Budget.init(io, 4);
    defer budget.deinit();
    const s = try dl.Service.init(a, io, &budget, 4);
    defer s.deinit();
    const ju = try url(base, "/json");
    defer a.free(ju);
    const t = try s.submit(.{ .url = ju, .output = .json });
    const parsed = (try success(t)).result.?.json;
    try std.testing.expectEqualStrings("minecraft", parsed.object.get("name").?.string);
    const badurl = try url(base, "/invalid-json");
    defer a.free(badurl);
    const bad = try s.submit(.{ .url = badurl, .output = .json });
    try expect((try wait(bad)).failure != null);
    const large = try url(base, "/large");
    defer a.free(large);
    const limit = try s.submit(.{ .url = large, .output = .json, .max_bytes = 128 });
    try eq(error.ResponseTooLarge, (try wait(limit)).failure.?);
    const notfound = try url(base, "/not-found");
    defer a.free(notfound);
    const missing = try s.submit(.{ .url = notfound });
    try eq(error.HttpStatus, (try wait(missing)).failure.?);
    const proxy = try s.submit(.{ .url = "http://downloader-fixture.invalid/bytes", .proxy = base });
    try std.testing.expectEqualStrings("hello minecraft\n", (try success(proxy)).result.?.bytes);
}
test "obsolete cache formats miss without sending validators and are replaced" {
    const base = try baseUrl();
    defer a.free(base);
    try curl.globalInit();
    defer curl.globalDeinit();
    var budget = try dl.Budget.init(io, 1);
    defer budget.deinit();
    const service = try dl.Service.init(a, io, &budget, 1);
    defer service.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try pathIn(&tmp, "obsolete.json");
    defer a.free(path);
    const meta_path = try std.fmt.allocPrint(a, "{s}.meta.json", .{path});
    defer a.free(meta_path);
    const endpoint = try url(base, "/fresh");
    defer a.free(endpoint);
    const encoded_url = try std.json.Stringify.valueAlloc(a, endpoint, .{});
    defer a.free(encoded_url);
    const old_body = "{\"name\":\"obsolete\"}";
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(old_body, &digest, .{});
    const encoded_digest = try std.json.Stringify.valueAlloc(a, digest, .{});
    defer a.free(encoded_digest);
    const now = @divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s);
    // Exercise actual old shapes as well as version checks independently of
    // unknown-field rejection. Even a current version cannot carry old aliases.
    const formats = [_]struct { version: []const u8, aliases: bool }{
        .{ .version = "", .aliases = true },
        .{ .version = "\"version\":0,", .aliases = true },
        .{ .version = "\"version\":1,", .aliases = true },
        .{ .version = "", .aliases = false },
        .{ .version = "\"version\":0,", .aliases = false },
        .{ .version = "\"version\":1,", .aliases = false },
        .{ .version = "\"version\":3,", .aliases = false },
        .{ .version = "\"version\":2,", .aliases = true },
    };
    for (formats) |format| {
        const encoded = try std.fmt.allocPrint(
            a,
            "{{{s}{s}\"url\":{s},\"sha1\":{s}," ++
                "\"headers\":{{\"etag\":\"\\\"fixture-v1\\\"\",\"cache_control\":\"max-age=3600\"}}," ++
                "\"request_time\":{d},\"response_time\":{d},\"user_agent\":\"Vela/1\",\"accept_encoding\":\"identity\"}}",
            .{ format.version, if (format.aliases) "\"etag\":\"\\\"fixture-v1\\\"\",\"modified\":\"\"," else "", encoded_url, encoded_digest, now, now },
        );
        defer a.free(encoded);
        try put(path, old_body);
        try put(meta_path, encoded);
        const task = try service.submit(.{ .url = endpoint, .output = .json, .cache_path = path });
        const state = try success(task);
        try eq(dl.Source.network, state.source);
        try eq(@as(u16, 200), state.http_status);
        try std.testing.expectEqualStrings("minecraft", state.result.?.json.object.get("name").?.string);
        try task.release();

        const saved = try std.Io.Dir.cwd().readFileAlloc(io, meta_path, a, .limited(64 * 1024));
        defer a.free(saved);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, saved, .{});
        defer parsed.deinit();
        try eq(@as(i64, 2), parsed.value.object.get("version").?.integer);
        try expect(parsed.value.object.get("etag") == null);
        try expect(parsed.value.object.get("modified") == null);
        try std.testing.expectEqualStrings("\"fixture-v1\"", parsed.value.object.get("headers").?.object.get("etag").?.string);
        const current = try service.submit(.{ .url = endpoint, .output = .json, .cache_path = path, .cache_mode = .revalidate });
        const validated = try success(current);
        try eq(dl.Source.revalidated, validated.source);
        try eq(@as(u16, 304), validated.http_status);
        try current.release();
    }
}

test "persistent ETag cache, 304 missing and corrupt recovery, modified validator" {
    const base = try baseUrl();
    defer a.free(base);
    try curl.globalInit();
    defer curl.globalDeinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try pathIn(&tmp, "manifest.json");
    defer a.free(path);
    const u = try url(base, "/etag");
    defer a.free(u);
    {
        var first_budget = try dl.Budget.init(io, 2);
        defer first_budget.deinit();
        const s = try dl.Service.init(a, io, &first_budget, 2);
        defer s.deinit();
        const first = try s.submit(.{ .url = u, .output = .json, .cache_path = path });
        try eq(dl.Source.network, (try success(first)).source);
        const second = try s.submit(.{ .url = u, .output = .json, .cache_path = path });
        const hit = try success(second);
        try eq(dl.Source.revalidated, hit.source);
        try eq(@as(u16, 304), hit.http_status);
    }
    var budget = try dl.Budget.init(io, 1);
    defer budget.deinit();
    const s = try dl.Service.init(a, io, &budget, 2);
    defer s.deinit();
    const restart = try s.submit(.{ .url = u, .output = .json, .cache_path = path });
    try eq(dl.Source.revalidated, (try success(restart)).source);
    try std.Io.Dir.cwd().deleteFile(io, path);
    const lost = try s.submit(.{ .url = u, .output = .json, .cache_path = path });
    try eq(dl.Source.network, (try success(lost)).source);
    try put(path, "corrupt");
    const corrupt = try s.submit(.{ .url = u, .output = .json, .cache_path = path });
    try eq(dl.Source.network, (try success(corrupt)).source);
    try eq(@as(usize, 0), budget.snapshot().active);
    const modified = try url(base, "/modified");
    defer a.free(modified);
    const m1 = try s.submit(.{ .url = modified, .output = .json, .cache_path = path });
    _ = try success(m1);
    const m2 = try s.submit(.{ .url = modified, .output = .json, .cache_path = path });
    try eq(dl.Source.revalidated, (try success(m2)).source);
}
test "SHA256 and SHA512 cached mismatch recover once for fresh and 304 bodies" {
    const base = try baseUrl();
    defer a.free(base);
    try curl.globalInit();
    defer curl.globalDeinit();
    var budget = try dl.Budget.init(io, 1);
    defer budget.deinit();
    const service = try dl.Service.init(a, io, &budget, 1);
    defer service.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try pathIn(&tmp, "strong-hash.json");
    defer a.free(path);
    const meta_path = try std.fmt.allocPrint(a, "{s}.meta.json", .{path});
    defer a.free(meta_path);
    const endpoint = try url(base, "/fresh");
    defer a.free(endpoint);
    const stats_url = try url(base, "/stats");
    defer a.free(stats_url);
    const before_task = try service.submit(.{ .url = stats_url, .output = .json });
    defer before_task.release() catch unreachable;
    const before_value = (try success(before_task)).result.?.json.object.get("/fresh");
    const before = if (before_value) |value| value.integer else 0;
    const old_body = "obsolete representation";
    const current_body = "{\"name\":\"minecraft\",\"version\":1}";
    var old_sha1: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(old_body, &old_sha1, .{});
    var sha256: [32]u8 = undefined;
    var sha512: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(current_body, &sha256, .{});
    std.crypto.hash.sha2.Sha512.hash(current_body, &sha512, .{});
    const now = @divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s);
    // A valid SHA1 for the obsolete body ensures only the expected strong hash
    // rejects it. Keep the fixture validator so revalidate really receives 304.
    const metadata = try std.json.Stringify.valueAlloc(a, .{
        .version = @as(u32, 2),
        .url = endpoint,
        .sha1 = old_sha1,
        .headers = .{ .etag = "\"fixture-v1\"", .cache_control = "max-age=3600" },
        .request_time = now,
        .response_time = now,
        .user_agent = "Vela/1",
        .accept_encoding = "identity",
    }, .{});
    defer a.free(metadata);
    for ([_]bool{ false, true }) |use_sha512| {
        for ([_]dl.CacheMode{ .prefer_cache, .revalidate }) |mode| {
            try put(path, old_body);
            try put(meta_path, metadata);
            const task = try service.submit(.{
                .url = endpoint,
                .cache_path = path,
                .cache_mode = mode,
                .expected_sha256 = if (use_sha512) null else sha256,
                .expected_sha512 = if (use_sha512) sha512 else null,
            });
            defer task.release() catch unreachable;
            const state = try success(task);
            try eq(dl.Source.network, state.source);
            try eq(@as(u16, 200), state.http_status);
            try std.testing.expectEqualStrings(current_body, state.result.?.bytes);
            try expect(task.retry_unconditional);
            try eq(@as(u8, 0), task.network_retries);
        }
        // A network mismatch is terminal, even after recovering a cached mismatch.
        const task = try service.submit(.{
            .url = endpoint,
            .cache_path = path,
            .expected_sha256 = if (use_sha512) null else @as([32]u8, @splat(0)),
            .expected_sha512 = if (use_sha512) @as([64]u8, @splat(0)) else null,
        });
        defer task.release() catch unreachable;
        const state = try wait(task);
        try eq(dl.Phase.failed, state.progress.phase);
        try eq(if (use_sha512) error.Sha512Mismatch else error.Sha256Mismatch, state.failure.?);
        try expect(task.retry_unconditional);
        try eq(@as(u8, 0), task.network_retries);
    }
    const after_task = try service.submit(.{ .url = stats_url, .output = .json });
    defer after_task.release() catch unreachable;
    const after = (try success(after_task)).result.?.json.object.get("/fresh").?.integer;
    // Per algorithm: fresh recovery (1), 304 recovery (2), terminal mismatch (1).
    try eq(@as(i64, 8), after - before);
}

test "HTTP freshness, forced validation, no-cache and Age govern disk reuse" {
    const base = try baseUrl();
    defer a.free(base);
    try curl.globalInit();
    defer curl.globalDeinit();
    var budget = try dl.Budget.init(io, 2);
    defer budget.deinit();
    const service = try dl.Service.init(a, io, &budget, 2);
    defer service.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try pathIn(&tmp, "fresh.json");
    defer a.free(path);
    for ([_][]const u8{ "/fresh", "/no-cache", "/aged" }) |suffix| {
        const endpoint = try url(base, suffix);
        defer a.free(endpoint);
        const first = try service.submit(.{ .url = endpoint, .output = .json, .cache_path = path });
        try eq(dl.Source.network, (try success(first)).source);
        const second = try service.submit(.{ .url = endpoint, .output = .json, .cache_path = path });
        const cached = try success(second);
        const fresh = std.mem.eql(u8, suffix, "/fresh");
        try eq(if (fresh) dl.Source.fresh else dl.Source.revalidated, cached.source);
        try eq(@as(u16, if (fresh) 0 else 304), cached.http_status);
        const forced = try service.submit(.{ .url = endpoint, .output = .json, .cache_path = path, .cache_mode = .revalidate });
        try eq(dl.Source.revalidated, (try success(forced)).source);
        const bypass = try service.submit(.{ .url = endpoint, .output = .json, .cache_path = path, .cache_mode = .bypass });
        try eq(dl.Source.network, (try success(bypass)).source);
    }
    // Optional persistence failures must not discard successfully verified bytes.
    const missing = try std.fmt.allocPrint(a, "{s}/missing/body", .{path});
    defer a.free(missing);
    const endpoint = try url(base, "/fresh");
    defer a.free(endpoint);
    const uncached = try service.submit(.{ .url = endpoint, .cache_path = missing });
    try eq(dl.Source.network, (try success(uncached)).source);
}

test "no-store and Vary are not cached; unexpected 304 and truncated transfers fail" {
    const base = try baseUrl();
    defer a.free(base);
    try curl.globalInit();
    defer curl.globalDeinit();
    var budget = try dl.Budget.init(io, 2);
    defer budget.deinit();
    const s = try dl.Service.init(a, io, &budget, 2);
    defer s.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try pathIn(&tmp, "body");
    defer a.free(path);
    for ([_][]const u8{ "/no-store", "/vary" }) |suffix| {
        const u = try url(base, suffix);
        defer a.free(u);
        const t = try s.submit(.{ .url = u, .cache_path = path });
        _ = try success(t);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(io, path, .{}));
    }
    for ([_][]const u8{ "/unexpected-304", "/truncated" }) |suffix| {
        const u = try url(base, suffix);
        defer a.free(u);
        const t = try s.submit(.{ .url = u });
        try expect((try wait(t)).failure != null);
    }
}
test "concurrent transfers, speed ETA, cancellation and shutdown" {
    const base = try baseUrl();
    defer a.free(base);
    try curl.globalInit();
    defer curl.globalDeinit();
    var budget = try dl.Budget.init(io, 2);
    defer budget.deinit();
    const s = try dl.Service.init(a, io, &budget, 2);
    defer s.deinit();
    const slowurl = try url(base, "/slow");
    defer a.free(slowurl);
    const fasturl = try url(base, "/json");
    defer a.free(fasturl);
    const slow = try s.submit(.{ .url = slowurl });
    const fast = try s.submit(.{ .url = fasturl, .output = .json });
    _ = try success(fast);
    try expect(!dl.terminal(slow.snapshot().progress.phase));
    var observed = false;
    for (0..150) |_| {
        const p = slow.snapshot().progress;
        if (p.bytes_per_second > 0 and p.eta_seconds != null and p.received > 0) {
            observed = true;
            break;
        }
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    try expect(observed);
    slow.cancel();
    try eq(dl.Phase.canceled, (try wait(slow)).progress.phase);
    var tasks: [8]*dl.Task = undefined;
    for (&tasks) |*t| t.* = try s.submit(.{ .url = slowurl });
    s.shutdown();
    for (tasks) |t| try eq(dl.Phase.canceled, (try wait(t)).progress.phase);
}
test "bounded outstanding task capacity and release reuse" {
    try curl.globalInit();
    defer curl.globalDeinit();
    var budget = try dl.Budget.init(io, 1);
    defer budget.deinit();
    const s = try dl.Service.init(a, io, &budget, 1);
    defer s.deinit();
    var tasks: [256]*dl.Task = undefined;
    for (&tasks) |*t| {
        t.* = try s.submit(.{ .url = "http://127.0.0.1:1/", .timeout_ms = 20 });
        t.*.cancel();
    }
    try std.testing.expectError(error.QueueFull, s.submit(.{ .url = "http://127.0.0.1:1/" }));
    for (tasks) |t| {
        _ = try wait(t);
        try t.release();
    }
    var next: ?*dl.Task = null;
    for (0..100) |_| {
        next = s.submit(.{ .url = "http://127.0.0.1:1/", .timeout_ms = 20 }) catch |err| {
            if (err != error.QueueFull) return err;
            try io.sleep(.fromMilliseconds(5), .awake);
            continue;
        };
        break;
    }
    try expect(next != null);
    next.?.cancel();
    _ = try wait(next.?);
}
test "unknown length, timeout, relative file paths and path exclusion" {
    const base = try baseUrl();
    defer a.free(base);
    try curl.globalInit();
    defer curl.globalDeinit();
    var budget = try dl.Budget.init(io, 2);
    defer budget.deinit();
    const s = try dl.Service.init(a, io, &budget, 2);
    defer s.deinit();
    const unknown = try url(base, "/unknown-length");
    defer a.free(unknown);
    const u = try s.submit(.{ .url = unknown });
    const state = try success(u);
    try expect(state.progress.total == null);
    try expect(state.result.?.bytes.len > 0);
    const slow = try url(base, "/slow");
    defer a.free(slow);
    const timeout = try s.submit(.{ .url = slow, .timeout_ms = 50 });
    try eq(error.TimedOut, (try wait(timeout)).failure.?);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const relative = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/relative.bin", .{tmp.sub_path});
    defer a.free(relative);
    const t = try s.submit(.{ .url = slow, .output = .{ .file = relative } });
    try std.testing.expectError(error.PathBusy, s.submit(.{ .url = slow, .output = .{ .file = relative } }));
    t.cancel();
    try eq(dl.Phase.canceled, (try wait(t)).progress.phase);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "relative.bin", .{}));
    const bytes = try url(base, "/bytes");
    defer a.free(bytes);
    const f = try s.submit(.{ .url = bytes, .output = .{ .file = relative } });
    _ = try success(f);
    const data = try tmp.dir.readFileAlloc(io, "relative.bin", a, .limited(100));
    defer a.free(data);
    try std.testing.expectEqualStrings("hello minecraft\n", data);
    const wrongsize = try s.submit(.{ .url = bytes, .expected_size = 100 });
    try eq(error.SizeMismatch, (try wait(wrongsize)).failure.?);
}

test "null and empty proxy disable inherited proxies and explicit proxy ignores NO_PROXY" {
    const base = try baseUrl();
    defer a.free(base);
    try curl.globalInit();
    defer curl.globalDeinit();
    var budget = try dl.Budget.init(io, 1);
    defer budget.deinit();
    const service = try dl.Service.init(a, io, &budget, 1);
    defer service.deinit();
    const direct_url = try url(base, "/bytes");
    defer a.free(direct_url);
    for ([_]?[]const u8{ null, "" }) |proxy| {
        const task = try service.submit(.{ .url = direct_url, .proxy = proxy });
        try std.testing.expectEqualStrings("hello minecraft\n", (try success(task)).result.?.bytes);
        try task.release();
    }
    const proxied = try service.submit(.{ .url = "http://downloader-fixture.invalid/bytes", .proxy = base });
    defer proxied.release() catch unreachable;
    try std.testing.expectEqualStrings("hello minecraft\n", (try success(proxied)).result.?.bytes);
}

fn installFixtureFile(tmp: *std.testing.TmpDir, relative: []const u8, bytes: []const u8) !void {
    const path = try pathIn(tmp, relative);
    defer a.free(path);
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    try put(path, bytes);
}

fn expectInstallFixtureFile(tmp: *std.testing.TmpDir, relative: []const u8, expected: []const u8) !void {
    const bytes = try tmp.dir.readFileAlloc(io, relative, a, .limited(8192));
    defer a.free(bytes);
    try std.testing.expectEqualStrings(expected, bytes);
}

test "client installation stays in its stage across source and instance name collisions" {
    const installer = @import("minecraft/install.zig");
    const metadata = @import("minecraft/metadata/root.zig");
    const base = try baseUrl();
    defer a.free(base);
    const client_url = try url(base, "/instance-client/jar");
    defer a.free(client_url);
    const index_url = try url(base, "/instance-client/index");
    defer a.free(index_url);
    const index_bytes = "{\"objects\":{}}";
    const client_bytes = "hello minecraft\n";
    var client_sha: [20]u8 = undefined;
    var index_sha: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(client_bytes, &client_sha, .{});
    std.crypto.hash.Sha1.hash(index_bytes, &index_sha, .{});
    const client_hex = std.fmt.bytesToHex(client_sha, .lower);
    const index_hex = std.fmt.bytesToHex(index_sha, .lower);
    const source = try std.json.Stringify.valueAlloc(a, .{
        .id = "1.20.1",
        .mainClass = "fixture.Main",
        .libraries = [_]struct {}{},
        .downloads = .{ .client = .{ .url = client_url, .sha1 = client_hex[0..], .size = client_bytes.len } },
        .assetIndex = .{ .id = "client-fixture", .url = index_url, .sha1 = index_hex[0..], .size = index_bytes.len },
    }, .{});
    defer a.free(source);
    try curl.globalInit();
    defer curl.globalDeinit();
    var budget = try dl.Budget.init(io, 2);
    defer budget.deinit();
    const service = try dl.Service.init(a, io, &budget, 2);
    defer service.deinit();
    const preserved = [_]struct { path: []const u8, bytes: []const u8 }{
        .{ .path = "assets/objects/shared-marker", .bytes = "shared assets" },
        .{ .path = "libraries/shared/marker.jar", .bytes = "shared libraries" },
        .{ .path = "versions/Unrelated/Unrelated.jar", .bytes = "unrelated client" },
        .{ .path = "versions/Unrelated/saves/world/level.dat", .bytes = "unrelated world" },
    };
    for ([_][]const u8{ "Survival", "1.20.1" }) |name| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        for (preserved) |entry| try installFixtureFile(&tmp, entry.path, entry.bytes);
        const collision = !std.mem.eql(u8, name, "1.20.1");
        if (collision) {
            try installFixtureFile(&tmp, "versions/1.20.1/1.20.1.jar", "another Minecraft version");
            try installFixtureFile(&tmp, "versions/1.20.1/1.20.1.json", "another instance descriptor");
            try installFixtureFile(&tmp, "versions/1.20.1/saves/world/level.dat", "preserved world");
        }
        try installFixtureFile(&tmp, "source.json", source);
        const source_path = try pathIn(&tmp, "source.json");
        defer a.free(source_path);
        const stage_name = ".vela-instance-client-fixture";
        const stage = try std.fs.path.join(a, &.{ root, "versions", stage_name });
        defer a.free(stage);
        var installed = try installer.run(a, io, service, .{
            .root = root,
            .version_id = "1.20.1",
            .target = .{ .directory_name = stage_name, .name = name },
            .game_directory = stage,
            .metadata_path = source_path,
            .environment = .{ .os_name = "linux", .arch = "x86_64" },
        });
        defer installed.deinit();
        const repeat_config: installer.Config = .{
            .root = root,
            .version_id = "1.20.1",
            .target = .{ .directory_name = ".vela-repeat-cache-fixture", .name = "Second" },
            .metadata_path = source_path,
            .environment = .{ .os_name = "linux", .arch = "x86_64" },
        };
        var repeat = try installer.run(a, io, service, repeat_config);
        defer repeat.deinit();
        try eq(@as(usize, 0), repeat.downloaded);
        try expect(repeat.reused > 0);
        const repeated_jar = "versions/.vela-repeat-cache-fixture/Second.jar";
        try expectInstallFixtureFile(&tmp, repeated_jar, client_bytes);
        try tmp.dir.writeFile(io, .{ .sub_path = repeated_jar, .data = "corrupt installed client" });
        var repaired = try installer.run(a, io, service, repeat_config);
        defer repaired.deinit();
        try eq(@as(usize, 0), repaired.downloaded);
        try expectInstallFixtureFile(&tmp, repeated_jar, client_bytes);
        try tmp.dir.deleteFile(io, repeated_jar);
        var restored = try installer.run(a, io, service, repeat_config);
        defer restored.deinit();
        try eq(@as(usize, 0), restored.downloaded);
        try expectInstallFixtureFile(&tmp, repeated_jar, client_bytes);
        const cached_client = try std.fmt.allocPrint(a, ".vela/cache/artifacts/sha1/{s}", .{client_hex});
        defer a.free(cached_client);
        try tmp.dir.writeFile(io, .{ .sub_path = cached_client, .data = "corrupt cached client" });
        try tmp.dir.deleteFile(io, repeated_jar);
        var refetched = try installer.run(a, io, service, repeat_config);
        defer refetched.deinit();
        try eq(@as(usize, 1), refetched.downloaded);
        try expectInstallFixtureFile(&tmp, repeated_jar, client_bytes);
        try expectInstallFixtureFile(&tmp, cached_client, client_bytes);
        const expected_client = try std.fmt.allocPrint(a, "{s}/{s}.jar", .{ stage, name });
        defer a.free(expected_client);
        const expected_target = try std.fs.path.resolve(a, &.{expected_client});
        defer a.free(expected_target);
        const planned_target = try std.fs.path.resolve(a, &.{installed.plan.value.client_path});
        defer a.free(planned_target);
        try std.testing.expectEqualStrings(expected_target, planned_target);
        try std.testing.expectEqualStrings(installed.plan.value.client_path, installed.plan.value.classpath[installed.plan.value.classpath.len - 1]);
        const staged_jar = try std.fmt.allocPrint(a, "versions/{s}/{s}.jar", .{ stage_name, name });
        defer a.free(staged_jar);
        try expectInstallFixtureFile(&tmp, staged_jar, client_bytes);
        const staged_json = try std.fmt.allocPrint(a, "versions/{s}/{s}.json", .{ stage_name, name });
        defer a.free(staged_json);
        const document = try tmp.dir.readFileAlloc(io, staged_json, a, .limited(8192));
        defer a.free(document);
        var parsed = try metadata.version.parseSlice(a, document);
        defer parsed.deinit();
        try std.testing.expectEqualStrings(name, parsed.value.id);
        try std.testing.expect(parsed.value.jar == null and parsed.value.inherits_from == null);
        if (!collision) try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "versions/1.20.1", .{ .follow_symlinks = false }));
        var versions = try tmp.dir.openDir(io, "versions", .{});
        defer versions.close(io);
        try std.Io.Dir.renamePreserve(versions, stage_name, versions, name, io);
        const final_jar = try std.fmt.allocPrint(a, "versions/{s}/{s}.jar", .{ name, name });
        defer a.free(final_jar);
        try expectInstallFixtureFile(&tmp, final_jar, client_bytes);
        for (preserved) |entry| try expectInstallFixtureFile(&tmp, entry.path, entry.bytes);
        if (collision) {
            try expectInstallFixtureFile(&tmp, "versions/1.20.1/1.20.1.jar", "another Minecraft version");
            try expectInstallFixtureFile(&tmp, "versions/1.20.1/1.20.1.json", "another instance descriptor");
            try expectInstallFixtureFile(&tmp, "versions/1.20.1/saves/world/level.dat", "preserved world");
        }
    }
    const stats_url = try url(base, "/stats");
    defer a.free(stats_url);
    const task = try service.submit(.{ .url = stats_url, .output = .json });
    defer task.release() catch unreachable;
    const counts = (try success(task)).result.?.json.object;
    // Each root downloads the client once, then once more only after cache corruption.
    try eq(@as(i64, 4), counts.get("/instance-client/jar").?.integer);
    try eq(@as(i64, 10), counts.get("/instance-client/index").?.integer);
}

test "streamed transfers without a total deadline complete but stalled connections time out" {
    const base = try baseUrl();
    defer a.free(base);
    try curl.globalInit();
    defer curl.globalDeinit();
    var budget = try dl.Budget.init(io, 1);
    defer budget.deinit();
    const service = try dl.Service.init(a, io, &budget, 1);
    defer service.deinit();
    const slow = try url(base, "/slow");
    defer a.free(slow);
    const healthy = try service.submit(.{ .url = slow, .timeout_ms = 0, .stall_timeout_seconds = 1 });
    defer healthy.release() catch unreachable;
    const result = try success(healthy);
    try eq(@as(usize, 256 * 1024), result.result.?.bytes.len);
    const stalled = try url(base, "/stalled");
    defer a.free(stalled);
    const blocked = try service.submit(.{ .url = stalled, .timeout_ms = 0, .stall_timeout_seconds = 1 });
    defer blocked.release() catch unreachable;
    try eq(error.TimedOut, (try wait(blocked)).failure.?);
}

fn awaitPhase(task: *dl.Task, phase: dl.Phase) !void {
    const began = std.Io.Clock.awake.now(io).nanoseconds;
    while (task.snapshot().progress.phase != phase) {
        if (dl.terminal(task.snapshot().progress.phase)) return error.UnexpectedTerminal;
        if (std.Io.Clock.awake.now(io).nanoseconds - began > 5 * std.time.ns_per_s) return error.TestTimeout;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
}

test "shared budget isolates waiting owner cancellation and shutdown" {
    try curl.globalInit();
    defer curl.globalDeinit();
    var budget = try dl.Budget.init(io, 1);
    defer budget.deinit();
    // Occupy the only permit without a network dependency, forcing both queues.
    try expect(budget.tryAcquire());
    var held = true;
    defer if (held) budget.release();
    const first = try dl.Service.init(a, io, &budget, 2);
    defer first.deinit();
    const second = try dl.Service.init(a, io, &budget, 2);
    defer second.deinit();
    const canceled = try first.submit(.{ .url = "http://127.0.0.1:1/", .timeout_ms = 100 });
    const survivor = try second.submit(.{ .url = "http://127.0.0.1:1/", .timeout_ms = 100 });
    try awaitPhase(canceled, .ready);
    try awaitPhase(survivor, .ready);
    first.shutdown();
    try eq(dl.Phase.canceled, (try wait(canceled)).progress.phase);
    try eq(dl.Phase.ready, survivor.snapshot().progress.phase);
    try eq(@as(usize, 1), budget.snapshot().active);
    budget.release();
    held = false;
    try eq(dl.Phase.failed, (try wait(survivor)).progress.phase);
    try eq(@as(usize, 0), budget.snapshot().active);
}

test "shared services respect lowering and return permits after cancellation and success" {
    const base = try baseUrl();
    defer a.free(base);
    try curl.globalInit();
    defer curl.globalDeinit();
    var budget = try dl.Budget.init(io, 2);
    defer budget.deinit();
    const first = try dl.Service.init(a, io, &budget, 2);
    defer first.deinit();
    const second = try dl.Service.init(a, io, &budget, 2);
    defer second.deinit();
    const stalled_url = try url(base, "/stalled");
    defer a.free(stalled_url);
    const fast_url = try url(base, "/bytes");
    defer a.free(fast_url);
    const left = try first.submit(.{ .url = stalled_url });
    const right = try second.submit(.{ .url = stalled_url });
    try awaitPhase(left, .downloading);
    try awaitPhase(right, .downloading);
    try eq(@as(usize, 2), budget.snapshot().active);
    try budget.setLimit(1);
    const queued = try second.submit(.{ .url = fast_url });
    try awaitPhase(queued, .ready);
    left.cancel();
    try eq(dl.Phase.canceled, (try wait(left)).progress.phase);
    try eq(@as(usize, 1), budget.snapshot().active);
    // With one pre-existing permit, the newly lowered limit admits no work.
    try io.sleep(.fromMilliseconds(100), .awake);
    try eq(dl.Phase.ready, queued.snapshot().progress.phase);
    try eq(dl.Phase.downloading, right.snapshot().progress.phase);
    right.cancel();
    try eq(dl.Phase.canceled, (try wait(right)).progress.phase);
    _ = try success(queued);
    try eq(@as(usize, 0), budget.snapshot().active);
    // A terminal result wins a late cancellation and consumes no permit.
    queued.cancel();
    try eq(dl.Phase.complete, queued.snapshot().progress.phase);
}

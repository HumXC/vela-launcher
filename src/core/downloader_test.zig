const std = @import("std");
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
        try io.sleep(.fromMilliseconds(5), .awake);
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

test "HTTPS-only requests never dispatch plaintext HTTP" {
    const base = try baseUrl();
    defer a.free(base);
    try curl.globalInit();
    defer curl.globalDeinit();
    const service = try dl.Service.init(a, io, 2);
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
    const s = try dl.Service.init(a, io, 2);
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
    const s = try dl.Service.init(a, io, 3);
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
test "JSON parsing, malformed JSON, limits, HTTP errors and explicit proxy" {
    const base = try baseUrl();
    defer a.free(base);
    try curl.globalInit();
    defer curl.globalDeinit();
    const s = try dl.Service.init(a, io, 4);
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
        const s = try dl.Service.init(a, io, 2);
        defer s.deinit();
        const first = try s.submit(.{ .url = u, .output = .json, .cache_path = path });
        try eq(dl.Source.network, (try success(first)).source);
        const second = try s.submit(.{ .url = u, .output = .json, .cache_path = path });
        const hit = try success(second);
        try eq(dl.Source.revalidated, hit.source);
        try eq(@as(u16, 304), hit.http_status);
    }
    const s = try dl.Service.init(a, io, 2);
    defer s.deinit();
    const restart = try s.submit(.{ .url = u, .output = .json, .cache_path = path });
    try eq(dl.Source.revalidated, (try success(restart)).source);
    try std.Io.Dir.cwd().deleteFile(io, path);
    const lost = try s.submit(.{ .url = u, .output = .json, .cache_path = path });
    try eq(dl.Source.network, (try success(lost)).source);
    try put(path, "corrupt");
    const corrupt = try s.submit(.{ .url = u, .output = .json, .cache_path = path });
    try eq(dl.Source.network, (try success(corrupt)).source);
    const modified = try url(base, "/modified");
    defer a.free(modified);
    const m1 = try s.submit(.{ .url = modified, .output = .json, .cache_path = path });
    _ = try success(m1);
    const m2 = try s.submit(.{ .url = modified, .output = .json, .cache_path = path });
    try eq(dl.Source.revalidated, (try success(m2)).source);
}
test "no-store and Vary are not cached; unexpected 304 and truncated transfers fail" {
    const base = try baseUrl();
    defer a.free(base);
    try curl.globalInit();
    defer curl.globalDeinit();
    const s = try dl.Service.init(a, io, 2);
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
    const s = try dl.Service.init(a, io, 2);
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
    const s = try dl.Service.init(a, io, 1);
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
    const s = try dl.Service.init(a, io, 2);
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
    try eq(error.TransferFailed, (try wait(timeout)).failure.?);
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

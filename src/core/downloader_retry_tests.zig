const std = @import("std");
const dl = @import("downloader.zig");
const curl = @import("curl");
const a = std.testing.allocator;
const io = std.testing.io;
const payload = "hello minecraft\n";
fn wait(task: *dl.Task) !dl.Snapshot {
    const started = std.Io.Clock.awake.now(io).nanoseconds;
    while (true) {
        const state = task.snapshot();
        if (dl.terminal(state.progress.phase)) return state;
        if (std.Io.Clock.awake.now(io).nanoseconds - started > 12 * std.time.ns_per_s) return error.TestTimeout;
        try task.wait();
    }
}
fn succeeded(task: *dl.Task) !dl.Snapshot {
    const state = try wait(task);
    if (state.failure) |err| return err;
    try std.testing.expectEqual(dl.Phase.complete, state.progress.phase);
    return state;
}
fn target(base: []const u8, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}{s}", .{ base, path });
}
test "retry recovers HTTP and partial file transfers and remains bounded" {
    const base = std.testing.environ.getAlloc(a, "DOWNLOADER_TEST_URL") catch return error.SkipZigTest;
    defer a.free(base);
    try curl.globalInit();
    defer curl.globalDeinit();
    var budget = try dl.Budget.init(io, 1);
    defer budget.deinit();
    const service = try dl.Service.init(a, io, &budget, 1);
    defer service.deinit();
    const recover_url = try target(base, "/retry/recover");
    defer a.free(recover_url);
    const recovering = try service.submit(.{ .url = recover_url });
    defer recovering.release() catch unreachable;
    try std.testing.expectEqualStrings(payload, (try succeeded(recovering)).result.?.bytes);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    const path = try std.fmt.allocPrint(a, "{s}/result", .{buffer[0..n]});
    defer a.free(path);
    const partial_url = try target(base, "/retry/partial");
    defer a.free(partial_url);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    const partial = try service.submit(.{ .url = partial_url, .output = .{ .file = path }, .expected_sha256 = digest, .expected_size = payload.len });
    defer partial.release() catch unreachable;
    _ = try succeeded(partial);
    const data = try tmp.dir.readFileAlloc(io, "result", a, .limited(1024));
    defer a.free(data);
    try std.testing.expectEqualStrings(payload, data);
    for ([_][]const u8{ "/retry/exhaust", "/retry/not-found", "/retry/deadline" }) |suffix| {
        const endpoint = try target(base, suffix);
        defer a.free(endpoint);
        const task = try service.submit(.{ .url = endpoint, .timeout_ms = if (std.mem.eql(u8, suffix, "/retry/deadline")) 300 else 10000 });
        defer task.release() catch unreachable;
        try std.testing.expectEqual(error.HttpStatus, (try wait(task)).failure.?);
    }
    for ([_]bool{ false, true }) |checksum| {
        const endpoint = try target(base, if (checksum) "/retry/checksum" else "/retry/too-large");
        defer a.free(endpoint);
        const task = try service.submit(.{ .url = endpoint, .max_bytes = if (checksum) 1024 else 2, .expected_sha256 = if (checksum) @as([32]u8, @splat(0)) else null });
        defer task.release() catch unreachable;
        try std.testing.expectEqual(if (checksum) error.Sha256Mismatch else error.ResponseTooLarge, (try wait(task)).failure.?);
    }
    const stats_url = try target(base, "/stats");
    defer a.free(stats_url);
    const stats = try service.submit(.{ .url = stats_url, .output = .json });
    defer stats.release() catch unreachable;
    const counts = (try succeeded(stats)).result.?.json.object;
    for ([_]struct { []const u8, i64 }{ .{ "/retry/recover", 3 }, .{ "/retry/partial", 2 }, .{ "/retry/exhaust", 4 }, .{ "/retry/not-found", 1 }, .{ "/retry/deadline", 1 }, .{ "/retry/checksum", 1 }, .{ "/retry/too-large", 1 } }) |expected| {
        try std.testing.expectEqual(expected[1], counts.get(expected[0]).?.integer);
    }
}
test "retry backoff releases sole network permit and cancellation stops further requests" {
    const base = std.testing.environ.getAlloc(a, "DOWNLOADER_TEST_URL") catch return error.SkipZigTest;
    defer a.free(base);
    try curl.globalInit();
    defer curl.globalDeinit();
    var budget = try dl.Budget.init(io, 1);
    defer budget.deinit();
    const service = try dl.Service.init(a, io, &budget, 1);
    defer service.deinit();
    const endpoint = try target(base, "/retry/cancel");
    defer a.free(endpoint);
    const task = try service.submit(.{ .url = endpoint });
    defer task.release() catch unreachable;
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    while (true) {
        const state = task.snapshot();
        if (state.progress.phase == .ready and state.http_status == 503) break;
        if (dl.terminal(state.progress.phase)) return error.UnexpectedCompletion;
        if (std.Io.Clock.awake.now(io).nanoseconds - start > 2 * std.time.ns_per_s) return error.TestTimeout;
        try task.wait();
    }
    const other_url = try target(base, "/bytes");
    defer a.free(other_url);
    const other = try service.submit(.{ .url = other_url, .timeout_ms = 400 });
    defer other.release() catch unreachable;
    _ = try succeeded(other);
    task.cancel();
    try std.testing.expectEqual(error.Canceled, (try wait(task)).failure.?);
    const stats_url = try target(base, "/stats");
    defer a.free(stats_url);
    const stats = try service.submit(.{ .url = stats_url, .output = .json });
    defer stats.release() catch unreachable;
    try std.testing.expectEqual(@as(i64, 1), (try succeeded(stats)).result.?.json.object.get("/retry/cancel").?.integer);
}

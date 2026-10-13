//! Conditional public metadata GETs for loader catalogues. The parser keeps its
//! existing transport contract; downloader owns validators and verified 304 bodies.
const std = @import("std");
const builtin = @import("builtin");
const dl = @import("../core/downloader.zig");
const loaders = @import("../core/loaders/root.zig");
const common = @import("../core/loaders/common.zig");
const A = std.mem.Allocator;
const Io = std.Io;

/// One worker owns the client and calls its transport synchronously. cache_root is
/// borrowed until deinit; the Manager freezes and owns it across worker JOIN.
/// Do not share this namespace with other simultaneous Service owners.
pub const Client = struct {
    io: Io,
    service: *dl.Service,
    cache_root: ?[]const u8,

    pub fn init(a: A, io: Io, cache_root: ?[]const u8) !Client {
        return .{ .io = io, .service = try dl.Service.init(a, io, 1), .cache_root = cache_root };
    }
    pub fn deinit(self: *Client) void {
        self.service.deinit();
        self.* = undefined;
    }
    /// The callback context points at the live worker-owned Client, not an init temporary.
    pub fn transport(self: *Client) loaders.Transport {
        return .{ .context = self, .get = get };
    }
    fn get(raw: ?*anyopaque, a: A, url: []const u8, max: usize, control: loaders.Control) !loaders.Response {
        const self: *Client = @ptrCast(@alignCast(raw.?));
        try common.trusted(url);
        return self.fetch(a, url, max, control, false);
    }
    fn cachePath(self: *Client, a: A, url: []const u8) !?[]u8 {
        const root = self.cache_root orelse return null;
        const directory = try std.fs.path.join(a, &.{ root, "http", "loader-catalog" });
        defer a.free(directory);
        try Io.Dir.cwd().createDirPath(self.io, directory);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        const filename = try std.fmt.allocPrint(a, "{s}.json", .{hex});
        defer a.free(filename);
        return try std.fs.path.join(a, &.{ directory, filename });
    }
    fn fetch(self: *Client, a: A, url: []const u8, max: usize, control: loaders.Control, comptime loopback_fixture: bool) !loaders.Response {
        try control.check();
        if (max == 0 or max > 8 * 1024 * 1024) return error.ResourceLimit;
        if (loopback_fixture) {
            if (!builtin.is_test) @compileError("Loopback routing is test-only");
            try checkFixtureUrl(url);
        }
        const cache_path = try self.cachePath(a, url);
        defer if (cache_path) |path| a.free(path);
        try control.check();
        const remaining = control.deadline_ms -| control.now_ms(control.context);
        if (remaining == 0) return error.DeadlineExceeded;
        const task = try self.service.submit(.{
            .url = url,
            .max_bytes = max,
            .cache_path = cache_path,
            .timeout_ms = @intCast(@min(remaining, 30_000)),
            .https_only = !loopback_fixture,
            .follow_redirects = false,
            .require_public_address = !loopback_fixture,
        });
        defer {
            // Cancellation is a request, not a JOIN. Copy final bytes before release.
            @import("../core/install/download_details.zig").join(self.io, task);
            @import("../core/install/download_details.zig").single(control.task, .metadata, url, task.snapshot());
            task.release() catch unreachable;
        }
        while (true) {
            try control.check();
            const state = task.snapshot();
            @import("../core/install/download_details.zig").single(control.task, .metadata, url, state);
            if (dl.terminal(state.progress.phase)) {
                try control.check();
                if (state.failure) |err| {
                    // Preserve the parser's established absent-catalogue behavior.
                    if (err != error.HttpStatus or state.http_status != 404) return err;
                    const bytes = try a.alloc(u8, 0);
                    errdefer a.free(bytes);
                    return .{ .bytes = bytes, .final_url = try a.dupe(u8, url), .status = 404 };
                }
                if (state.progress.phase != .complete or state.result == null) return error.DownloadFailed;
                const bytes = try a.dupe(u8, state.result.?.bytes);
                errdefer a.free(bytes);
                const final_url = try a.dupe(u8, url);
                errdefer a.free(final_url);
                try control.check();
                // A verified cached body is a complete representation to the parser,
                // even though its network response was 304 with no body.
                return .{ .bytes = bytes, .final_url = final_url, .status = 200 };
            }
            try self.io.sleep(.fromMilliseconds(5), .awake);
        }
    }
};

fn checkFixtureUrl(url: []const u8) !void {
    const prefix = "http://127.0.0.1:";
    if (!std.mem.startsWith(u8, url, prefix)) return error.InvalidFixtureUrl;
    const tail = url[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, tail, '/') orelse return error.InvalidFixtureUrl;
    if (slash == 0) return error.InvalidFixtureUrl;
    for (tail[0..slash]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidFixtureUrl;
}

const test_a = std.testing.allocator;
const test_io = std.testing.io;
fn testNow(_: ?*anyopaque) u64 {
    return @intCast(@max(0, @divFloor(Io.Clock.awake.now(test_io).nanoseconds, std.time.ns_per_ms)));
}
fn testControl() loaders.Control {
    return .{ .deadline_ms = testNow(null) + 10_000, .now_ms = testNow };
}
fn freeResponse(response: loaders.Response) void {
    test_a.free(response.bytes);
    test_a.free(response.final_url);
}
fn fixtureBase() ![]u8 {
    const value = std.testing.environ.getAlloc(test_a, "DOWNLOADER_TEST_URL") catch return error.SkipZigTest;
    errdefer test_a.free(value);
    const probe = try std.fmt.allocPrint(test_a, "{s}/stats", .{value});
    defer test_a.free(probe);
    try checkFixtureUrl(probe);
    return value;
}
fn fixtureUrl(base: []const u8, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(test_a, "{s}{s}", .{ base, path });
}
fn statsCount(client: *Client, base: []const u8, key: []const u8) !i64 {
    const url = try fixtureUrl(base, "/stats");
    defer test_a.free(url);
    const response = try client.fetch(test_a, url, 1024 * 1024, testControl(), true);
    defer freeResponse(response);
    const parsed = try std.json.parseFromSlice(std.json.Value, test_a, response.bytes, .{});
    defer parsed.deinit();
    return if (parsed.value.object.get(key)) |value| value.integer else 0;
}
fn overwrite(path: []const u8, bytes: []const u8) !void {
    const file = try Io.Dir.cwd().createFile(test_io, path, .{});
    defer file.close(test_io);
    try file.writeStreamingAll(test_io, bytes);
}

test "loader HTTP adapter revalidates across restart with ETag and server Last-Modified" {
    const base = try fixtureBase();
    defer test_a.free(base);
    const curl = @import("curl");
    try curl.globalInit();
    defer curl.globalDeinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(test_io, ".", test_a);
    defer test_a.free(root);
    for ([_][]const u8{ "/etag", "/modified" }) |path| {
        const url = try fixtureUrl(base, path);
        defer test_a.free(url);
        const conditional_key = try std.fmt.allocPrint(test_a, "{s}:conditional", .{path});
        defer test_a.free(conditional_key);
        const initial = blk: {
            var first = try Client.init(test_a, test_io, root);
            defer first.deinit();
            const before = try statsCount(&first, base, conditional_key);
            const response = try first.fetch(test_a, url, 4096, testControl(), true);
            defer freeResponse(response);
            try std.testing.expectEqual(@as(u16, 200), response.status);
            try std.testing.expectEqualStrings(url, response.final_url);
            break :blk .{ .before = before, .expected = try test_a.dupe(u8, response.bytes) };
        };
        const before = initial.before;
        const expected = initial.expected;
        defer test_a.free(expected);
        var restarted = try Client.init(test_a, test_io, root);
        defer restarted.deinit();
        const revalidated = try restarted.fetch(test_a, url, 4096, testControl(), true);
        defer freeResponse(revalidated);
        try std.testing.expectEqual(@as(u16, 200), revalidated.status);
        try std.testing.expectEqualStrings(expected, revalidated.bytes);
        try std.testing.expectEqual(before + 1, try statsCount(&restarted, base, conditional_key));
        const cache_path = (try restarted.cachePath(test_a, url)).?;
        defer test_a.free(cache_path);
        try overwrite(cache_path, "corrupt cache");
        const recovered = try restarted.fetch(test_a, url, 4096, testControl(), true);
        defer freeResponse(recovered);
        try std.testing.expectEqual(@as(u16, 200), recovered.status);
        try std.testing.expectEqualStrings(expected, recovered.bytes);
    }
}

test "loader HTTP adapter preserves 404 and rejects redirects limits deadline and cancellation" {
    const base = try fixtureBase();
    defer test_a.free(base);
    const curl = @import("curl");
    try curl.globalInit();
    defer curl.globalDeinit();
    var client = try Client.init(test_a, test_io, null);
    defer client.deinit();
    const missing = try fixtureUrl(base, "/loader-adapter-not-found");
    defer test_a.free(missing);
    const response = try client.fetch(test_a, missing, 4096, testControl(), true);
    defer freeResponse(response);
    try std.testing.expectEqual(@as(u16, 404), response.status);
    try std.testing.expectEqual(@as(usize, 0), response.bytes.len);
    const redirect = try fixtureUrl(base, "/redirect");
    defer test_a.free(redirect);
    try std.testing.expectError(error.HttpStatus, client.fetch(test_a, redirect, 4096, testControl(), true));
    const unexpected = try fixtureUrl(base, "/unexpected-304");
    defer test_a.free(unexpected);
    try std.testing.expectError(error.UnexpectedNotModified, client.fetch(test_a, unexpected, 4096, testControl(), true));
    const large = try fixtureUrl(base, "/large");
    defer test_a.free(large);
    try std.testing.expectError(error.ResponseTooLarge, client.fetch(test_a, large, 16, testControl(), true));
    const deadline: loaders.Control = .{ .deadline_ms = 0, .now_ms = testNow };
    try std.testing.expectError(error.DeadlineExceeded, client.fetch(test_a, missing, 4096, deadline, true));
    var canceled: std.atomic.Value(bool) = .init(true);
    var control = testControl();
    control.cancel = &canceled;
    try std.testing.expectError(error.Canceled, client.fetch(test_a, missing, 4096, control, true));
}

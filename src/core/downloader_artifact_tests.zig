const std = @import("std");
const curl = @import("curl");
const dl = @import("downloader.zig");
const cache = @import("artifact_cache.zig");
const java = @import("java_download.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const payload = "hello minecraft\n";
fn finish(task: *dl.Task) !dl.Snapshot {
    task.join();
    const snapshot = task.snapshot();
    if (snapshot.failure) |err| return err;
    try std.testing.expectEqual(dl.Phase.complete, snapshot.progress.phase);
    return snapshot;
}
fn count(service: *dl.Service, base: []const u8, endpoint: []const u8) !i64 {
    const url = try std.fmt.allocPrint(a, "{s}/stats", .{base});
    defer a.free(url);
    const task = try service.submit(.{ .url = url, .output = .json });
    defer task.release() catch unreachable;
    const counts = (try finish(task)).result.?.json.object;
    return if (counts.get(endpoint)) |value| value.integer else 0;
}

test "artifact cache reuses every trusted digest and repairs corruption without mutable links" {
    const base = std.testing.environ.getAlloc(a, "DOWNLOADER_TEST_URL") catch return error.SkipZigTest;
    defer a.free(base);
    try curl.globalInit();
    defer curl.globalDeinit();
    var budget = try dl.Budget.init(io, 2);
    defer budget.deinit();
    const service = try dl.Service.init(a, io, &budget, 2);
    defer service.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const target = try std.fs.path.join(a, &.{ root, "result" });
    defer a.free(target);
    const url = try std.fmt.allocPrint(a, "{s}/bytes", .{base});
    defer a.free(url);
    var sha1: [20]u8 = undefined;
    var sha256: [32]u8 = undefined;
    var sha512: [64]u8 = undefined;
    std.crypto.hash.Sha1.hash(payload, &sha1, .{});
    std.crypto.hash.sha2.Sha256.hash(payload, &sha256, .{});
    std.crypto.hash.sha2.Sha512.hash(payload, &sha512, .{});
    for ([_]cache.Hashes{ .{ .sha1 = sha1 }, .{ .sha256 = sha256 }, .{ .sha512 = sha512 } }) |hashes| {
        const request: dl.Request = .{ .url = url, .output = .{ .file = target }, .expected_sha1 = hashes.sha1, .expected_sha256 = hashes.sha256, .expected_sha512 = hashes.sha512, .artifact_cache_root = root };
        const before = try count(service, base, "/bytes");
        const first = try service.submit(request);
        _ = try finish(first);
        try first.release();
        const cached = (try hashes.path(a, root)).?;
        defer a.free(cached);
        // Consumer mutation must not poison the cache (no hardlinks).
        try tmp.dir.writeFile(io, .{ .sub_path = "result", .data = "modified consumer" });
        const preserved = try std.Io.Dir.cwd().readFileAlloc(io, cached, a, .limited(100));
        defer a.free(preserved);
        try std.testing.expectEqualStrings(payload, preserved);
        try tmp.dir.deleteFile(io, "result");
        const second = try service.submit(request);
        const hit = try finish(second);
        try std.testing.expectEqual(dl.Source.artifact, hit.source);
        try std.testing.expectEqual(@as(u16, 0), hit.http_status);
        try std.testing.expectEqual(@as(f64, 0), hit.progress.bytes_per_second);
        try second.release();
        try std.testing.expectEqual(before + 1, try count(service, base, "/bytes"));
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cached, .data = "broken cache" });
        try tmp.dir.deleteFile(io, "result");
        const repaired = try service.submit(request);
        try std.testing.expectEqual(dl.Source.network, (try finish(repaired)).source);
        try repaired.release();
        try std.testing.expectEqual(before + 2, try count(service, base, "/bytes"));
        try tmp.dir.deleteFile(io, "result");
    }
    const invalid_hash: [32]u8 = @splat(0);
    const invalid_path = (try (cache.Hashes{ .sha256 = invalid_hash }).path(a, root)).?;
    defer a.free(invalid_path);
    const bad = try service.submit(.{ .url = url, .output = .{ .file = target }, .expected_sha256 = invalid_hash, .artifact_cache_root = root });
    try std.testing.expectError(error.Sha256Mismatch, finish(bad));
    try bad.release();
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(io, invalid_path, .{}));
    const slow = try std.fmt.allocPrint(a, "{s}/slow", .{base});
    defer a.free(slow);
    const canceled = try service.submit(.{ .url = slow, .output = .{ .file = target }, .expected_sha256 = invalid_hash, .artifact_cache_root = root });
    canceled.cancel();
    try std.testing.expectError(error.Canceled, finish(canceled));
    try canceled.release();
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(io, invalid_path, .{}));
    // Without trusted metadata, repeated URLs remain ordinary network requests.
    const before = try count(service, base, "/bytes");
    for (0..2) |_| {
        const task = try service.submit(.{ .url = url, .output = .{ .file = target }, .artifact_cache_root = root });
        try std.testing.expectEqual(dl.Source.network, (try finish(task)).source);
        try task.release();
    }
    try std.testing.expectEqual(before + 2, try count(service, base, "/bytes"));
}

test "Java installs retain verified archive after extraction failure and reuse it on retry" {
    const base = std.testing.environ.getAlloc(a, "DOWNLOADER_TEST_URL") catch return error.SkipZigTest;
    defer a.free(base);
    try curl.globalInit();
    defer curl.globalDeinit();
    var budget = try dl.Budget.init(io, 1);
    defer budget.deinit();
    const service = try dl.Service.init(a, io, &budget, 1);
    defer service.deinit();
    // This test-only bridge pins every request to the local fixture; production
    // ServiceTransport retains its HTTPS-only and official URL validation.
    const LocalService = struct {
        service: *dl.Service,
        url: []const u8,
        pub fn submit(self: *@This(), request: dl.Request) !*dl.Task {
            var local = request;
            local.url = self.url;
            local.https_only = false;
            return self.service.submit(local);
        }
        fn failExtract(_: *anyopaque, _: std.mem.Allocator, _: std.Io, _: java.Archive, _: []const u8, _: []const u8, _: java.Hooks) ![]u8 {
            return error.FixtureExtractionFailed;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const url = try std.fmt.allocPrint(a, "{s}/bytes", .{base});
    defer a.free(url);
    var local: LocalService = .{ .service = service, .url = url };
    var adapter: java.ServiceTransport(LocalService) = .{ .service = &local, .cache_root = root };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    const release: java.RuntimeRelease = .{ .allocator = a, .vendor = .microsoft, .major = 21, .platform = .{ .os = .linux, .arch = .x64 }, .version = "21.0.1", .url = "https://aka.ms/download-jdk/fixture.tar.gz", .archive = .tar_gz, .sha256 = digest, .size = payload.len };
    const before = try count(service, base, "/bytes");
    for (0..2) |_| {
        try std.testing.expectError(error.FixtureExtractionFailed, java.install(a, io, adapter.transport(), &release, root, .{ .context = &local, .extract = LocalService.failExtract }, .{}));
    }
    try std.testing.expectEqual(before + 1, try count(service, base, "/bytes"));
    const cached = (try (cache.Hashes{ .sha256 = digest }).path(a, root)).?;
    defer a.free(cached);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, cached, a, .limited(100));
    defer a.free(bytes);
    try std.testing.expectEqualStrings(payload, bytes);
}

test "persistent diagnostics retain curl failure and cache source without signed query secrets" {
    const base = std.testing.environ.getAlloc(a, "DOWNLOADER_TEST_URL") catch return error.SkipZigTest;
    defer a.free(base);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const diagnostic = @import("diagnostic_log.zig");
    try diagnostic.start(io, root);
    defer diagnostic.stop();
    try curl.globalInit();
    defer curl.globalDeinit();
    var budget = try dl.Budget.init(io, 1);
    defer budget.deinit();
    const service = try dl.Service.init(a, io, &budget, 1);
    defer service.deinit();
    const broken_url = try std.fmt.allocPrint(a, "{s}/truncated?signature=diagnostic-secret", .{base});
    defer a.free(broken_url);
    const target = try std.fs.path.join(a, &.{ root, "result" });
    defer a.free(target);
    const broken = try service.submit(.{ .url = broken_url, .output = .{ .file = target } });
    try std.testing.expectError(error.NetworkConnectionFailed, finish(broken));
    try broken.release();
    const valid_url = try std.fmt.allocPrint(a, "{s}/bytes?signature=diagnostic-secret", .{base});
    defer a.free(valid_url);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    const request: dl.Request = .{ .url = valid_url, .output = .{ .file = target }, .expected_sha256 = digest, .artifact_cache_root = root };
    const first = try service.submit(request);
    _ = try finish(first);
    try first.release();
    try tmp.dir.deleteFile(io, "result");
    const second = try service.submit(request);
    try std.testing.expectEqual(dl.Source.artifact, (try finish(second)).source);
    try second.release();
    const bytes = try tmp.dir.readFileAlloc(io, ".vela/logs/launcher.log", a, .limited(64 * 1024));
    defer a.free(bytes);
    for ([_][]const u8{ "curl_code=18", "error=NetworkConnectionFailed", "retry=3/3", "source=artifact", "elapsed_ms=", "file=" }) |expected| {
        try std.testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, bytes, "diagnostic-secret") == null);
}

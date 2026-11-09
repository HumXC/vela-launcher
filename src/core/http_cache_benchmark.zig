//! Offline HTTP cache disk benchmark. No network, authentication, or build changes.
//! Run: nix develop --offline --command zig run -O ReleaseFast src/core/http_cache_benchmark.zig
//! Baseline reproduces old JSON body encode/decode, hashing, file sync and atomic
//! rename. It omits pruning (favors baseline); v3 uses the real store including
//! pruning. Warm filesystem cache, five measured iterations after one warmup.
//! Synthetic mrpack-like bytes measure persistence, not ZIP parsing or downloads.
const std = @import("std");
const store = @import("http_cache_store.zig");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const io = init.io;
    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    const root = (".http-cache-benchmark-" ++ std.fmt.bytesToHex(random, .lower)).*;
    try Io.Dir.cwd().createDir(io, &root, .fromMode(0o700));
    defer Io.Dir.cwd().deleteTree(io, &root) catch {};
    const dir = try Io.Dir.cwd().openDir(io, &root, .{});
    defer dir.close(io);
    const cases = [_]struct { name: []const u8, size: usize, binary: bool }{
        .{ .name = "metadata", .size = 64 * 1024, .binary = false },
        .{ .name = "icon", .size = 256 * 1024, .binary = true },
        .{ .name = "mrpack-small", .size = 1024 * 1024, .binary = true },
        .{ .name = "mrpack-large", .size = 8 * 1024 * 1024, .binary = true },
    };
    std.debug.print("case,body_bytes,json_bytes,v3_bytes,json_save_ms,v3_save_ms,json_load_ms,v3_load_ms\n", .{});
    for (cases) |case| {
        const body = try a.alloc(u8, case.size);
        defer a.free(body);
        var prng = std.Random.DefaultPrng.init(12345);
        if (case.binary) prng.random().bytes(body) else for (body, 0..) |*byte, i| {
            const text = "{\"name\":\"example\",\"version\":42},";
            byte.* = text[i % text.len];
        }
        const record: store.Record = .{
            .url = "https://example.invalid/cache-benchmark",
            .request_key = "benchmark",
            .scope = "public",
            .stored_at = 30,
            .request_time = 10,
            .response_time = 20,
            .headers = .{ .cache_control = "max-age=3600", .etag = "benchmark" },
            .body_hash = @splat(0),
            .body = body,
        };
        const key: [32]u8 = @splat(1);
        var durations: [4]i96 = @splat(0);
        for (0..6) |iteration| {
            var start = Io.Clock.awake.now(io).nanoseconds;
            try baselineSave(a, io, dir, record);
            if (iteration != 0) durations[0] += Io.Clock.awake.now(io).nanoseconds - start;
            start = Io.Clock.awake.now(io).nanoseconds;
            try store.save(a, io, &root, key, record);
            if (iteration != 0) durations[1] += Io.Clock.awake.now(io).nanoseconds - start;
            start = Io.Clock.awake.now(io).nanoseconds;
            try baselineLoad(a, io, dir, body);
            if (iteration != 0) durations[2] += Io.Clock.awake.now(io).nanoseconds - start;
            start = Io.Clock.awake.now(io).nanoseconds;
            var entry = (try store.load(a, io, &root, key, body.len)) orelse return error.CacheMiss;
            defer entry.deinit();
            if (!std.mem.eql(u8, body, entry.parsed.value.body)) return error.BodyMismatch;
            if (iteration != 0) durations[3] += Io.Clock.awake.now(io).nanoseconds - start;
        }
        const baseline_size = (try dir.statFile(io, "baseline.json", .{})).size;
        const name = ("http-v3/" ++ std.fmt.bytesToHex(key, .lower) ++ ".cache").*;
        const new_size = (try dir.statFile(io, &name, .{})).size;
        var ms: [4]f64 = undefined;
        for (&ms, durations) |*value, duration| value.* = @as(f64, @floatFromInt(duration)) / 5e6;
        std.debug.print("{s},{d},{d},{d},{d:.3},{d:.3},{d:.3},{d:.3}\n", .{ case.name, body.len, baseline_size, new_size, ms[0], ms[1], ms[2], ms[3] });
    }
}

fn baselineSave(a: std.mem.Allocator, io: Io, dir: Io.Dir, record: store.Record) !void {
    var stored = record;
    Sha256.hash(stored.body, &stored.body_hash, .{});
    const bytes = try std.json.Stringify.valueAlloc(a, stored, .{});
    defer a.free(bytes);
    if (bytes.len > store.max_disk_bytes) return error.RecordTooLarge;
    const file = try dir.createFile(io, "baseline.tmp", .{ .permissions = .fromMode(0o600) });
    var closed = false;
    defer if (!closed) file.close(io);
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
    file.close(io);
    closed = true;
    try dir.rename("baseline.tmp", dir, "baseline.json", io);
}

fn baselineLoad(a: std.mem.Allocator, io: Io, dir: Io.Dir, expected: []const u8) !void {
    const bytes = try dir.readFileAlloc(io, "baseline.json", a, .limited(store.max_disk_bytes));
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(store.Record, a, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    var digest: [32]u8 = undefined;
    Sha256.hash(parsed.value.body, &digest, .{});
    if (!std.mem.eql(u8, &digest, &parsed.value.body_hash)) return error.HashMismatch;
    if (!std.mem.eql(u8, expected, parsed.value.body)) return error.BodyMismatch;
}

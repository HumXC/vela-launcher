//! Opt-in measurement of the download callback's bounded write + SHA1 work.
//! Run: nix develop --command zig test src/core/stream_write_benchmark.zig -O ReleaseFast
//! This measures buffered writes, not fsync durability or network throughput.
const std = @import("std");

test "stream write and SHA1 callback work baseline" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try std.testing.allocator.alloc(u8, 16 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0x5a);
    const file = try tmp.dir.createFile(io, "stream.bin", .{});
    defer file.close(io);
    const chunks = 4096;
    var hash = std.crypto.hash.Sha1.init(.{});
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    var maximum_ns: i96 = 0;
    for (0..chunks) |_| {
        const chunk_start = std.Io.Clock.awake.now(io).nanoseconds;
        try file.writeStreamingAll(io, bytes);
        hash.update(bytes);
        maximum_ns = @max(maximum_ns, std.Io.Clock.awake.now(io).nanoseconds - chunk_start);
    }
    const elapsed = std.Io.Clock.awake.now(io).nanoseconds - start;
    var digest: [20]u8 = undefined;
    hash.final(&digest);
    std.mem.doNotOptimizeAway(digest);
    std.debug.print("STREAM_BASELINE bytes={d} chunk_bytes={d} elapsed_ns={d} max_chunk_ns={d} buffer_bytes={d}\n", .{ chunks * bytes.len, bytes.len, elapsed, maximum_ns, bytes.len });
}

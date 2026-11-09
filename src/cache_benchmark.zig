const std = @import("std");
const artifact = @import("core/artifact_cache.zig");
const fs = @import("core/content_fs.zig");
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedTemporaryDirectory;
    const dir = try std.Io.Dir.cwd().createDirPathOpen(io, args[1], .{});
    defer dir.close(io);
    const source = try dir.createFile(io, "source", .{ .read = true, .exclusive = true });
    defer source.close(io);
    var bytes: [65536]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @truncate(i *% 71);
    for (0..512) |_| try source.writeStreamingAll(io, &bytes);
    try source.sync(io);
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    const hash = try fs.stream(source, null, io, 64 * 1024 * 1024, null, null);
    const hashed = std.Io.Clock.awake.now(io).nanoseconds;
    const src = try std.fs.path.join(a, &.{ args[1], "source" });
    defer a.free(src);
    const dst = try std.fs.path.join(a, &.{ args[1], "copy" });
    defer a.free(dst);
    const cancel: std.atomic.Value(bool) = .init(false);
    _ = try artifact.copyVerified(io, src, dst, .{ .sha1 = try artifact.parseHex(20, &hash.sha1), .sha256 = try artifact.parseHex(32, &hash.sha256), .sha512 = try artifact.parseHex(64, &hash.sha512) }, hash.size, hash.size, &cancel);
    const copied = std.Io.Clock.awake.now(io).nanoseconds;
    std.debug.print("cache_bench bytes={d} triple_hash_ms={d} verified_copy_ms={d}\n", .{ hash.size, @divTrunc(hashed - start, std.time.ns_per_ms), @divTrunc(copied - hashed, std.time.ns_per_ms) });
}

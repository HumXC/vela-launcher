//! Shared gate for libwebp's process-global DSP dispatch tables.
//! The decoder-only build has no synchronized DSP initialization (including on
//! Windows). All image consumers must enter here, including background artwork.
const std = @import("std");
extern fn WebPDecodeRGBAInto([*]const u8, usize, [*]u8, usize, c_int) ?[*]u8;
var decoder_mutex: std.Io.Mutex = .init;

pub fn rgbaInto(io: std.Io, bytes: []const u8, output: []u8, stride: c_int) !void {
    try decoder_mutex.lock(io);
    defer decoder_mutex.unlock(io);
    if (WebPDecodeRGBAInto(bytes.ptr, bytes.len, output.ptr, output.len, stride) == null) return error.InvalidWebP;
}

test "WebP concurrent cold-start decoders retain valid SIMD fallback tables" {
    const fixture = @embedFile("fixtures/webp-lossless.webp");
    const Native = struct {
        extern fn WebPGetInfo([*]const u8, usize, *c_int, *c_int) c_int;
    };
    var width: c_int = 0;
    var height: c_int = 0;
    try std.testing.expect(Native.WebPGetInfo(fixture.ptr, fixture.len, &width, &height) != 0);
    const Worker = struct {
        gate: *std.Io.Event,
        size: usize,
        stride: c_int,
        digest: [32]u8 = undefined,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.gate.waitUncancelable(std.testing.io);
            self.execute() catch |err| {
                self.failure = err;
            };
        }
        fn execute(self: *@This()) !void {
            const pixels = try std.heap.page_allocator.alloc(u8, self.size);
            defer std.heap.page_allocator.free(pixels);
            for (0..8) |iteration| {
                try rgbaInto(std.testing.io, fixture, pixels, self.stride);
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(pixels, &digest, .{});
                if (iteration == 0) self.digest = digest else try std.testing.expectEqualSlices(u8, &self.digest, &digest);
            }
        }
    };
    var gate: std.Io.Event = .unset;
    var workers: [16]Worker = undefined;
    var threads: [16]std.Thread = undefined;
    var spawned: usize = 0;
    {
        errdefer {
            gate.set(std.testing.io);
            for (threads[0..spawned]) |thread| thread.join();
        }
        for (&workers, &threads) |*worker, *thread| {
            worker.* = .{ .gate = &gate, .size = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4, .stride = width * 4 };
            thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
            spawned += 1;
        }
    }
    gate.set(std.testing.io);
    for (threads) |thread| thread.join();
    for (workers) |worker| {
        if (worker.failure) |err| return err;
        try std.testing.expectEqualSlices(u8, &workers[0].digest, &worker.digest);
    }
    var small: [4]u8 = undefined;
    try std.testing.expectError(error.InvalidWebP, rgbaInto(std.testing.io, "invalid", &small, 4));
}

//! Bounded gzip/zlib helpers for launcher metadata and PNG fixtures.
const std = @import("std");

pub const Compression = enum { none, gzip, zlib };
pub const Error = error{ MalformedCompressedData, SizeLimitExceeded, TrailingData } || std.mem.Allocator.Error;

pub fn compress(a: std.mem.Allocator, input: []const u8, kind: Compression, limit: usize) Error![]u8 {
    if (kind == .none) {
        if (input.len > limit) return error.SizeLimitExceeded;
        return a.dupe(u8, input);
    }
    if (limit <= 8) return error.SizeLimitExceeded;
    const buffer = try a.alloc(u8, limit);
    defer a.free(buffer);
    var output: std.Io.Writer = .fixed(buffer);
    const Workspace = struct {
        history: [std.compress.flate.max_window_len]u8,
        compressor: std.compress.flate.Compress,
    };
    const workspace = try a.create(Workspace);
    defer a.destroy(workspace);
    workspace.compressor = std.compress.flate.Compress.init(
        &output,
        &workspace.history,
        if (kind == .gzip) .gzip else .zlib,
        .fastest,
    ) catch return error.SizeLimitExceeded;
    workspace.compressor.writer.writeAll(input) catch return error.SizeLimitExceeded;
    workspace.compressor.finish() catch return error.SizeLimitExceeded;
    return a.dupe(u8, output.buffered());
}

pub fn decompress(a: std.mem.Allocator, input: []const u8, kind: Compression, limit: usize, reject_trailing: bool) Error![]u8 {
    if (kind == .none) {
        if (input.len > limit) return error.SizeLimitExceeded;
        return a.dupe(u8, input);
    }
    const history = try a.alloc(u8, std.compress.flate.max_window_len);
    defer a.free(history);
    var source: std.Io.Reader = .fixed(input);
    var inflater: std.compress.flate.Decompress = .init(&source, if (kind == .gzip) .gzip else .zlib, history);
    // Reader limits need an extra byte to distinguish an exact-size output from EOF.
    const plain = inflater.reader.allocRemaining(a, .limited(limit +| 1)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.SizeLimitExceeded,
        else => return error.MalformedCompressedData,
    };
    errdefer a.free(plain);
    if (plain.len > limit) return error.SizeLimitExceeded;
    if (reject_trailing and source.bufferedLen() != 0) return error.TrailingData;
    return plain;
}

test "metadata compression round trips gzip and zlib with strict output limits" {
    const a = std.testing.allocator;
    const input = "world metadata compression fixture";
    inline for (.{ Compression.gzip, Compression.zlib }) |kind| {
        const encoded = try compress(a, input, kind, 1024);
        defer a.free(encoded);
        const decoded = try decompress(a, encoded, kind, input.len, true);
        defer a.free(decoded);
        try std.testing.expectEqualStrings(input, decoded);
        try std.testing.expectError(error.SizeLimitExceeded, decompress(a, encoded, kind, input.len - 1, true));
        const trailing = try std.mem.concat(a, u8, &.{ encoded, "x" });
        defer a.free(trailing);
        try std.testing.expectError(error.TrailingData, decompress(a, trailing, kind, 1024, true));
        try std.testing.expectError(error.MalformedCompressedData, decompress(a, encoded[0 .. encoded.len - 1], kind, 1024, true));
        for (0..9) |small_limit| try std.testing.expectError(error.SizeLimitExceeded, compress(a, input, kind, small_limit));
    }
}

test "compression adapter accepts large outputs at the exact decoded limit" {
    const a = std.testing.allocator;
    var input: [64 * (1 + 64 * 3)]u8 = undefined;
    for (&input, 0..) |*byte, index| byte.* = @truncate(index / 5);
    for ([_]Compression{ .gzip, .zlib }) |kind| {
        const encoded = try compress(a, &input, kind, input.len * 2);
        defer a.free(encoded);
        const decoded = try decompress(a, encoded, kind, input.len, true);
        defer a.free(decoded);
        try std.testing.expectEqualSlices(u8, &input, decoded);
        try std.testing.expectError(error.SizeLimitExceeded, decompress(a, encoded, kind, input.len - 1, true));
    }
}

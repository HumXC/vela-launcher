const std = @import("std");
const icon = @import("server_icon.zig");
const a = std.testing.allocator;
const raw_len = 64 * (1 + 64 * 4);
const zlib_len = raw_len + 11;
const png_len = 8 + 25 + 12 + zlib_len + 12;

fn checksum(chunk: []u8) void {
    std.mem.writeInt(u32, chunk[chunk.len - 4 ..][0..4], std.hash.Crc32.hash(chunk[4 .. chunk.len - 4]), .big);
}
fn fixture() [png_len]u8 {
    var png: [png_len]u8 = @splat(0);
    @memcpy(png[0..8], "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, png[8..12], 13, .big);
    @memcpy(png[12..16], "IHDR");
    std.mem.writeInt(u32, png[16..20], 64, .big);
    std.mem.writeInt(u32, png[20..24], 64, .big);
    png[24] = 8;
    png[25] = 6;
    checksum(png[8..33]);
    std.mem.writeInt(u32, png[33..37], zlib_len, .big);
    @memcpy(png[37..41], "IDAT");
    const z = png[41..][0..zlib_len];
    @memcpy(z[0..3], &[_]u8{ 0x78, 0x01, 0x01 });
    std.mem.writeInt(u16, z[3..5], raw_len, .little);
    std.mem.writeInt(u16, z[5..7], ~@as(u16, raw_len), .little);
    const raw = z[7..][0..raw_len];
    for (0..64) |y| for (0..64) |x| {
        const at = y * 257 + 1 + x * 4;
        @memcpy(raw[at..][0..4], &[_]u8{ @intCast(x), @intCast(y), 173, 127 });
    };
    var s1: u32 = 1;
    var s2: u32 = 0;
    for (raw) |byte| {
        s1 = (s1 + byte) % 65521;
        s2 = (s2 + s1) % 65521;
    }
    std.mem.writeInt(u32, z[zlib_len - 4 ..][0..4], (s2 << 16) | s1, .big);
    checksum(png[33 .. 45 + zlib_len]);
    @memcpy(png[png_len - 8 ..][0..4], "IEND");
    checksum(png[png_len - 12 ..]);
    return png;
}
fn uriFor(allocator: std.mem.Allocator, png: []const u8) ![]u8 {
    const uri = try allocator.alloc(u8, icon.data_uri_prefix.len + std.base64.standard.Encoder.calcSize(png.len));
    @memcpy(uri[0..icon.data_uri_prefix.len], icon.data_uri_prefix);
    _ = std.base64.standard.Encoder.encode(uri[icon.data_uri_prefix.len..], png);
    return uri;
}
fn expectInvalid(png: []const u8, err: anyerror) !void {
    const uri = try uriFor(a, png);
    defer a.free(uri);
    try std.testing.expectError(err, icon.decode(a, uri));
}

test "server icon decodes actual RGBA and owns original PNG with SHA256" {
    var png = fixture();
    const uri = try uriFor(a, &png);
    defer a.free(uri);
    var result = try icon.decode(a, uri);
    defer result.deinit();
    try std.testing.expectEqualSlices(u8, &png, result.png);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&png, &digest, .{});
    try std.testing.expectEqualSlices(u8, &digest, &result.sha256);
    for (result.pixels, 0..) |pixel, i| try std.testing.expectEqualDeep(icon.Pixel{ .r = @intCast(i % 64), .g = @intCast(i / 64), .b = 173, .a = 127 }, pixel);
    @memset(uri, 0);
    @memset(&png, 0);
    try std.testing.expectEqual(@as(u8, 0x89), result.png[0]);
}

test "server icon strict MIME base64 and input size bounds" {
    try std.testing.expectError(error.InvalidDataUri, icon.decode(a, "data:image/jpeg;base64,AAAA"));
    for ([_][]const u8{ "", "A", "AAAA\n", "AA A", "!!!!", "AA-_", "AB==", "AAB=", "AAAA====" }) |bad| {
        const uri = try std.mem.concat(a, u8, &.{ icon.data_uri_prefix, bad });
        defer a.free(uri);
        try std.testing.expectError(error.InvalidBase64, icon.decode(a, uri));
    }
    const large = try a.alloc(u8, icon.max_png_bytes + 1);
    defer a.free(large);
    @memset(large, 0);
    try expectInvalid(large, error.IconTooLarge);
    const huge = try a.alloc(u8, icon.max_data_uri_bytes + 1);
    defer a.free(huge);
    @memset(huge, 'A');
    @memcpy(huge[0..icon.data_uri_prefix.len], icon.data_uri_prefix);
    try std.testing.expectError(error.IconTooLarge, icon.decode(a, huge));
}

test "server icon rejects dimensions CRC truncated PNG and corrupt IDAT" {
    var png = fixture();
    std.mem.writeInt(u32, png[16..20], 63, .big);
    checksum(png[8..33]);
    try expectInvalid(&png, error.InvalidDimensions);
    png = fixture();
    png[25] = 2; // RGB header with excess RGBA scanline data.
    checksum(png[8..33]);
    try expectInvalid(&png, error.InvalidPng);
    png = fixture();
    png[50] ^= 1;
    try expectInvalid(&png, error.InvalidPng);
    png = fixture();
    // Valid chunk CRC, invalid DEFLATE block type: structure-only checks pass.
    png[43] = 7;
    checksum(png[33 .. 45 + zlib_len]);
    try expectInvalid(&png, error.InvalidPng);
    png = fixture();
    // Valid deflate and chunk CRC, invalid zlib Adler checksum.
    png[41 + zlib_len - 1] ^= 1;
    checksum(png[33 .. 45 + zlib_len]);
    try expectInvalid(&png, error.InvalidPng);
    png = fixture();
    try expectInvalid(png[0 .. png.len - 1], error.InvalidPng);
    png[48] = 5; // Invalid PNG row filter, valid deflate and checksums below.
    var s1: u32 = 1;
    var s2: u32 = 0;
    for (png[48..][0..raw_len]) |byte| {
        s1 = (s1 + byte) % 65521;
        s2 = (s2 + s1) % 65521;
    }
    std.mem.writeInt(u32, png[41 + zlib_len - 4 ..][0..4], (s2 << 16) | s1, .big);
    checksum(png[33 .. 45 + zlib_len]);
    try expectInvalid(&png, error.InvalidPng);
}

fn allocationCase(allocator: std.mem.Allocator, uri: []const u8) !void {
    var result = try icon.decode(allocator, uri);
    defer result.deinit();
}
test "server icon cleans PNG and every native allocation under OOM" {
    const png = fixture();
    const uri = try uriFor(a, &png);
    defer a.free(uri);
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{uri});
}
fn concurrentDecode(uri: []const u8) bool {
    var result = icon.decode(std.heap.page_allocator, uri) catch return false;
    defer result.deinit();
    return result.pixels[4095].r == 63 and result.pixels[4095].g == 63;
}
test "server icon concurrent calls have independent native allocator state" {
    const png = fixture();
    const uri = try uriFor(a, &png);
    defer a.free(uri);
    var futures: [8]std.Io.Future(bool) = undefined;
    var started: usize = 0;
    defer {
        for (futures[0..started]) |*future| _ = future.await(std.testing.io);
    }
    for (&futures) |*future| {
        future.* = try std.testing.io.concurrent(concurrentDecode, .{uri});
        started += 1;
    }
    for (&futures) |*future| try std.testing.expect(future.await(std.testing.io));
}

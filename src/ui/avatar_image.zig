//! Local Minecraft face extraction; no network or window state while decoding.
const std = @import("std");
const dvui = @import("dvui");
const avatar = @import("../core/avatar.zig");

pub const Face = [64]dvui.Color.PMA;
pub const characters = [_][]const u8{ "steve", "alex", "noor", "sunny", "ari", "zuri", "makena", "kai", "efe" };
const skins = [_][]const u8{
    @embedFile("../assets/default_skins/steve.png"),
    @embedFile("../assets/default_skins/alex.png"),
    @embedFile("../assets/default_skins/noor.png"),
    @embedFile("../assets/default_skins/sunny.png"),
    @embedFile("../assets/default_skins/ari.png"),
    @embedFile("../assets/default_skins/zuri.png"),
    @embedFile("../assets/default_skins/makena.png"),
    @embedFile("../assets/default_skins/kai.png"),
    @embedFile("../assets/default_skins/efe.png"),
};

pub fn defaultFaces(a: std.mem.Allocator) ![9]Face {
    var faces: [9]Face = undefined;
    for (skins, &faces) |png, *face| face.* = try decodeFace(a, png);
    return faces;
}

pub fn defaultFace(a: std.mem.Allocator, uuid: []const u8) !Face {
    return decodeFace(a, skins[avatar.defaultIndex(uuid)]);
}

pub fn decodeFace(a: std.mem.Allocator, png: []const u8) !Face {
    try avatar.validateSkin(png);
    try validateImageData(a, png);
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const pixels = dvui.c.stbi_load_from_memory(png.ptr, @intCast(png.len), &width, &height, &channels, 4) orelse return error.InvalidSkin;
    defer dvui.c.stbi_image_free(pixels);
    if (width != 64 or (height != 64 and height != 32)) return error.InvalidSkin;
    return faceFromRgba(pixels[0..@intCast(width * height * 4)], @intCast(height));
}

// STB grows its inflate buffer and accepts redundant expanded bytes. Verify
// the exact PNG scanline budget first, including all seven Adam7 passes.
fn validateImageData(a: std.mem.Allocator, png: []const u8) !void {
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(a);
    var offset: usize = 8;
    while (offset < png.len) {
        const length: usize = std.mem.readInt(u32, png[offset..][0..4], .big);
        if (std.mem.eql(u8, png[offset + 4 ..][0..4], "IDAT")) try compressed.appendSlice(a, png[offset + 8 ..][0..length]);
        offset += length + 12;
    }
    const expected = scanlineBytes(png);
    const decoded = @import("nbt_compression").decompress(a, compressed.items, .zlib, expected, true) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SizeLimitExceeded => return error.InvalidSkinExpansion,
        else => return error.InvalidSkin,
    };
    defer a.free(decoded);
    if (decoded.len != expected) return error.InvalidSkin;
}

fn scanlineBytes(png: []const u8) usize {
    const height: usize = std.mem.readInt(u32, png[20..24], .big);
    const channels: usize = switch (png[25]) {
        0, 3 => 1,
        2 => 3,
        4 => 2,
        6 => 4,
        else => unreachable,
    };
    const bits = channels * png[24];
    if (png[28] == 0) return height * (1 + (64 * bits + 7) / 8);
    const x_start = [_]usize{ 0, 4, 0, 2, 0, 1, 0 };
    const y_start = [_]usize{ 0, 0, 4, 0, 2, 0, 1 };
    const x_step = [_]usize{ 8, 8, 4, 4, 2, 2, 1 };
    const y_step = [_]usize{ 8, 8, 8, 4, 4, 2, 2 };
    var size: usize = 0;
    for (0..7) |pass| {
        const pass_width = (64 - x_start[pass] + x_step[pass] - 1) / x_step[pass];
        const pass_height = (height - y_start[pass] + y_step[pass] - 1) / y_step[pass];
        size += pass_height * (1 + (pass_width * bits + 7) / 8);
    }
    return size;
}

fn faceFromRgba(rgba: []const u8, height: usize) !Face {
    if ((height != 32 and height != 64) or rgba.len != 64 * height * 4) return error.InvalidSkin;
    // Old 64x32 skins often fill the unused hat area with opaque background.
    var legacy_opaque_hat = height == 32;
    if (legacy_opaque_hat) {
        outer: for (0..16) |y| for (32..64) |x| {
            if (rgba[(y * 64 + x) * 4 + 3] != 255) {
                legacy_opaque_hat = false;
                break :outer;
            }
        };
    }
    var face: Face = undefined;
    for (0..8) |y| for (0..8) |x| {
        const base = ((y + 8) * 64 + x + 8) * 4;
        const hat = ((y + 8) * 64 + x + 40) * 4;
        const alpha: u16 = if (legacy_opaque_hat) 0 else rgba[hat + 3];
        // Minecraft renders the base head opaque, regardless of PNG base alpha.
        face[y * 8 + x] = .{
            .r = @intCast((@as(u16, rgba[hat]) * alpha + @as(u16, rgba[base]) * (255 - alpha) + 127) / 255),
            .g = @intCast((@as(u16, rgba[hat + 1]) * alpha + @as(u16, rgba[base + 1]) * (255 - alpha) + 127) / 255),
            .b = @intCast((@as(u16, rgba[hat + 2]) * alpha + @as(u16, rgba[base + 2]) * (255 - alpha) + 127) / 255),
            .a = 255,
        };
    };
    return face;
}

pub fn source(face: *Face) dvui.ImageSource {
    return .{ .pixelsPMA = .{ .rgba = face, .width = 8, .height = 8, .interpolation = .nearest, .invalidation = .bytes } };
}

pub fn draw(src: std.builtin.SourceLocation, face: *Face) void {
    _ = dvui.image(src, .{ .source = source(face) }, .{ .tag = "player-avatar", .label = .{ .text = "玩家头像" }, .min_size_content = .{ .w = 48, .h = 48 }, .max_size_content = .{ .w = 48, .h = 48 }, .gravity_y = 0.5, .padding = dvui.Rect.all(0), .margin = dvui.Rect.all(0) });
}

fn fixtureChunk(a: std.mem.Allocator, output: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) !void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(data.len), .big);
    try output.appendSlice(a, &length);
    const start = output.items.len;
    try output.appendSlice(a, kind);
    try output.appendSlice(a, data);
    var crc: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc, std.hash.crc.@"CRC-32/ISO-HDLC".hash(output.items[start..]), .big);
    try output.appendSlice(a, &crc);
}

fn fixturePng(a: std.mem.Allocator, header: [13]u8, encoded: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(a);
    try output.appendSlice(a, skins[0][0..8]);
    try fixtureChunk(a, &output, "IHDR", &header);
    if (header[9] == 3) try fixtureChunk(a, &output, "PLTE", &.{ 0, 0, 0 });
    // Real skins can split the same zlib stream across several IDAT chunks.
    try fixtureChunk(a, &output, "IDAT", encoded[0 .. encoded.len / 2]);
    try fixtureChunk(a, &output, "IDAT", encoded[encoded.len / 2 ..]);
    try fixtureChunk(a, &output, "IEND", "");
    return output.toOwnedSlice(a);
}

fn fixtureHeader(height: u32, depth: u8, color: u8, interlace: u8) [13]u8 {
    var header: [13]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], 64, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    header[8] = depth;
    header[9] = color;
    header[12] = interlace;
    return header;
}

test "avatar PNG excessive expansion and truncated or trailing zlib data are rejected before STB" {
    const a = std.testing.allocator;
    const compression = @import("nbt_compression");
    const header = fixtureHeader(64, 8, 6, 0);
    const raw = try a.alloc(u8, 100_000);
    defer a.free(raw);
    @memset(raw, 0);
    const expanded = try compression.compress(a, raw, .zlib, 128 * 1024);
    defer a.free(expanded);
    const bomb = try fixturePng(a, header, expanded);
    defer a.free(bomb);
    try std.testing.expect(bomb.len < 128 * 1024);
    try avatar.validateSkin(bomb);
    try std.testing.expectError(error.InvalidSkinExpansion, decodeFace(a, bomb));
    const exact = try compression.compress(a, raw[0 .. 64 * 257], .zlib, 128 * 1024);
    defer a.free(exact);
    const trailing = try std.mem.concat(a, u8, &.{ exact, "tail" });
    defer a.free(trailing);
    const bad_tail = try fixturePng(a, header, trailing);
    defer a.free(bad_tail);
    try std.testing.expectError(error.InvalidSkin, decodeFace(a, bad_tail));
    const short = try compression.compress(a, raw[0 .. 64 * 257 - 1], .zlib, 128 * 1024);
    defer a.free(short);
    const short_png = try fixturePng(a, header, short);
    defer a.free(short_png);
    try std.testing.expectError(error.InvalidSkin, decodeFace(a, short_png));
}

test "avatar bounded scanline validation supports Adam7, packed palettes and sixteen-bit skins" {
    const a = std.testing.allocator;
    const cases = [_]struct { color: u8, depth: u8 }{ .{ .color = 0, .depth = 1 }, .{ .color = 2, .depth = 8 }, .{ .color = 3, .depth = 1 }, .{ .color = 4, .depth = 16 }, .{ .color = 6, .depth = 16 } };
    for ([_]u32{ 32, 64 }) |height| for ([_]u8{ 0, 1 }) |interlace| for (cases) |case| {
        const header = fixtureHeader(height, case.depth, case.color, interlace);
        var metadata: [33]u8 = @splat(0);
        @memcpy(metadata[16..29], &header);
        const expected = scanlineBytes(&metadata);
        const raw = try a.alloc(u8, expected);
        defer a.free(raw);
        @memset(raw, 0);
        const compressed = try @import("nbt_compression").compress(a, raw, .zlib, 128 * 1024);
        defer a.free(compressed);
        const png = try fixturePng(a, header, compressed);
        defer a.free(png);
        const face = try decodeFace(a, png);
        for (face) |pixel| try std.testing.expectEqual(dvui.Color.PMA{ .r = 0, .g = 0, .b = 0, .a = 255 }, pixel);
    };
}

test "avatar nine embedded official defaults have distinct opaque faces" {
    const faces = try defaultFaces(std.testing.allocator);
    for (faces, 0..) |face, i| {
        for (face) |pixel| try std.testing.expectEqual(@as(u8, 255), pixel.a);
        for (faces[0..i]) |other| try std.testing.expect(!std.mem.eql(u8, std.mem.asBytes(&face), std.mem.asBytes(&other)));
    }
}

test "avatar crops face coordinates and alpha composites the hat without changing base opacity" {
    var rgba: [64 * 64 * 4]u8 = @splat(0);
    for (0..8) |y| for (0..8) |x| {
        const base = ((y + 8) * 64 + x + 8) * 4;
        const hat = ((y + 8) * 64 + x + 40) * 4;
        @memcpy(rgba[base..][0..4], &[_]u8{ 20, 40, 60, 0 });
        @memcpy(rgba[hat..][0..4], &[_]u8{ 100, 120, 140, 128 });
    };
    const face = try faceFromRgba(&rgba, 64);
    for (face) |pixel| try std.testing.expectEqual(dvui.Color.PMA{ .r = 60, .g = 80, .b = 100, .a = 255 }, pixel);
}

test "avatar legacy opaque unused hat is cleared but a real transparent hat is retained" {
    var rgba: [64 * 32 * 4]u8 = @splat(255);
    for (0..8) |y| for (0..8) |x| {
        const base = ((y + 8) * 64 + x + 8) * 4;
        @memcpy(rgba[base..][0..4], &[_]u8{ 20, 40, 60, 255 });
    };
    const plain = try faceFromRgba(&rgba, 32);
    try std.testing.expectEqual(@as(u8, 20), plain[0].r);
    rgba[32 * 4 + 3] = 0;
    const hat = try faceFromRgba(&rgba, 32);
    try std.testing.expectEqual(@as(u8, 255), hat[0].r);
}

//! UI-independent Minecraft server favicon decoding. Link server_icon_stb.c with
//! the pinned stb_image.h include directory and libc; no DVUI module is needed.
const std = @import("std");
const A = std.mem.Allocator;
pub const side = 64;
pub const max_png_bytes = 32 * 1024;
pub const data_uri_prefix = "data:image/png;base64,";
pub const max_data_uri_bytes = data_uri_prefix.len + std.base64.standard.Encoder.calcSize(max_png_bytes);
/// Straight (not premultiplied) RGBA8 in top-to-bottom, row-major order.
pub const Pixel = extern struct { r: u8, g: u8, b: u8, a: u8 };
pub const Bitmap = [side * side]Pixel;
pub const Icon = struct {
    allocator: A,
    png: []const u8,
    pixels: Bitmap,
    /// SHA256 of the original decoded PNG bytes, not the base64 spelling.
    sha256: [32]u8,
    pub fn deinit(self: *Icon) void {
        self.allocator.free(self.png);
        self.* = undefined;
    }
};
pub const Error = error{ InvalidDataUri, InvalidBase64, IconTooLarge, InvalidPng, InvalidDimensions, OutOfMemory };
extern fn vela_server_icon_decode([*]const u8, c_int, [*]const u8, c_int, [*]u8, *anyopaque, *const fn (*anyopaque, usize) callconv(.c) ?*anyopaque) c_int;

/// Accepts exactly the standard, padded base64 PNG data URI (no whitespace,
/// alternate MIME, URL alphabet, or noncanonical padding bits). The 32KiB cap
/// applies to decoded PNG bytes; encoded input is bounded before allocation.
/// Concurrent calls are independent; the supplied allocator must be usable on
/// the calling thread. Icon ownership can be transferred; deinit exactly once.
pub fn decode(a: A, uri: []const u8) Error!Icon {
    if (!std.mem.startsWith(u8, uri, data_uri_prefix)) return error.InvalidDataUri;
    if (uri.len > max_data_uri_bytes) return error.IconTooLarge;
    const encoded = uri[data_uri_prefix.len..];
    const decoder = std.base64.standard.Decoder;
    if (encoded.len == 0 or encoded.len % 4 != 0) return error.InvalidBase64;
    const len = decoder.calcSizeForSlice(encoded) catch return error.InvalidBase64;
    if (len > max_png_bytes) return error.IconTooLarge;
    const png = try a.alloc(u8, len);
    errdefer a.free(png);
    decoder.decode(png, encoded) catch return error.InvalidBase64;
    // Re-encoding enforces canonical pad bits even if std's decoder changes.
    var canonical: [std.base64.standard.Encoder.calcSize(max_png_bytes)]u8 = undefined;
    if (!std.mem.eql(u8, std.base64.standard.Encoder.encode(&canonical, png), encoded)) return error.InvalidBase64;
    var compressed: [max_png_bytes]u8 = undefined;
    const idat = try validatePng(png, &compressed);
    var scratch: Scratch = .{ .arena = .init(a) };
    defer scratch.arena.deinit();
    var icon: Icon = .{ .allocator = a, .png = png, .pixels = undefined, .sha256 = undefined };
    const ok = vela_server_icon_decode(png.ptr, @intCast(png.len), idat.ptr, @intCast(idat.len), std.mem.asBytes(&icon.pixels).ptr, &scratch, Scratch.allocate);
    if (scratch.oom) return error.OutOfMemory;
    if (ok == 0) return error.InvalidPng;
    std.crypto.hash.sha2.Sha256.hash(png, &icon.sha256, .{});
    return icon;
}

const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    used: usize = 0,
    oom: bool = false,
    // Bounds cumulative native allocation, including realloc's old storage.
    const limit = 512 * 1024;
    fn allocate(context: *anyopaque, len: usize) callconv(.c) ?*anyopaque {
        const self: *Scratch = @ptrCast(@alignCast(context));
        if (@max(1, len) > limit - self.used) return null;
        const bytes = self.arena.allocator().alignedAlloc(u8, .@"16", @max(1, len)) catch {
            self.oom = true;
            return null;
        };
        self.used += @max(1, len);
        return bytes.ptr;
    }
};

fn validatePng(png: []const u8, compressed: []u8) Error![]const u8 {
    if (png.len < 33 or !std.mem.eql(u8, png[0..8], "\x89PNG\r\n\x1a\n")) return error.InvalidPng;
    var pos: usize = 8;
    var written: usize = 0;
    var saw_idat = false;
    var ended_idat = false;
    while (pos < png.len) {
        if (png.len - pos < 12) return error.InvalidPng;
        const len: usize = std.mem.readInt(u32, png[pos..][0..4], .big);
        if (len > png.len - pos - 12) return error.InvalidPng;
        const kind = png[pos + 4 ..][0..4];
        const body = png[pos + 8 ..][0..len];
        const crc = std.mem.readInt(u32, png[pos + 8 + len ..][0..4], .big);
        if (std.hash.Crc32.hash(png[pos + 4 ..][0 .. 4 + len]) != crc) return error.InvalidPng;
        if (pos == 8) {
            if (!std.mem.eql(u8, kind, "IHDR") or len != 13) return error.InvalidPng;
            if (std.mem.readInt(u32, body[0..4], .big) != side or std.mem.readInt(u32, body[4..8], .big) != side) return error.InvalidDimensions;
        } else if (std.mem.eql(u8, kind, "IHDR")) return error.InvalidPng;
        if (std.mem.eql(u8, kind, "IDAT")) {
            if (ended_idat) return error.InvalidPng;
            @memcpy(compressed[written..][0..len], body);
            written += len;
            saw_idat = true;
        } else if (saw_idat) ended_idat = true;
        pos += len + 12;
        if (std.mem.eql(u8, kind, "IEND")) {
            if (len != 0 or !saw_idat or written == 0 or pos != png.len) return error.InvalidPng;
            return compressed[0..written];
        }
    }
    return error.InvalidPng;
}

test {
    _ = @import("server_icon_tests.zig");
}

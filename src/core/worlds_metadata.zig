//! Strict world metadata adapter over pinned nbt-zig and Zig's gzip inflater.
const std = @import("std");
const nbt = @import("nbt");
const worlds = @import("worlds.zig");
const compression = @import("nbt_compression");

pub fn parse(a: std.mem.Allocator, bytes: []const u8) !worlds.Metadata {
    if (bytes.len < 18 or bytes.len > 16 * 1024 * 1024 or bytes[0] != 0x1f or bytes[1] != 0x8b) return error.InvalidLevelDat;
    // Transient parser memory has a strict ceiling, independent of upstream accounting.
    const scratch = try a.alloc(u8, 64 * 1024 * 1024);
    defer a.free(scratch);
    var fixed = std.heap.FixedBufferAllocator.init(scratch);
    const transient = fixed.allocator();
    const plain = compression.decompress(transient, bytes, .gzip, 16 * 1024 * 1024, true) catch |err| return if (err == error.OutOfMemory) error.MetadataResourceLimit else err;
    defer transient.free(plain);
    // std.flate exposes but does not verify gzip's footer checksum/size.
    const footer = bytes[bytes.len - 8 ..];
    if (std.mem.readInt(u32, footer[0..4], .little) != std.hash.crc.@"CRC-32/ISO-HDLC".hash(plain) or std.mem.readInt(u32, footer[4..8], .little) != plain.len) return error.InvalidGzipChecksum;
    if (bytes[3] & 0xe0 != 0) return error.InvalidGzipHeader;
    if (bytes[3] & 2 != 0) {
        var header_end: usize = 10;
        if (bytes[3] & 4 != 0) {
            header_end += 2 + @as(usize, std.mem.readInt(u16, bytes[10..12], .little));
        }
        if (bytes[3] & 8 != 0) header_end = (std.mem.indexOfScalarPos(u8, bytes, header_end, 0) orelse return error.InvalidGzipHeader) + 1;
        if (bytes[3] & 16 != 0) header_end = (std.mem.indexOfScalarPos(u8, bytes, header_end, 0) orelse return error.InvalidGzipHeader) + 1;
        if (header_end > bytes.len - 2 or std.mem.readInt(u16, bytes[header_end..][0..2], .little) != @as(u16, @truncate(std.hash.crc.@"CRC-32/ISO-HDLC".hash(bytes[0..header_end])))) return error.InvalidGzipHeader;
    }
    var options: nbt.Options = .java;
    options.reject_trailing_bytes = true;
    options.max_input_bytes = 16 * 1024 * 1024;
    options.max_decompressed_bytes = 16 * 1024 * 1024;
    options.max_total_decoded_bytes = 32 * 1024 * 1024;
    options.max_depth = 64;
    options.max_collection_length = 1024 * 1024;
    options.max_compound_entries = 16384;
    options.max_string_bytes = 65535;
    var doc = nbt.parse(transient, plain, options) catch |err| return if (err == error.OutOfMemory) error.MetadataResourceLimit else err;
    defer doc.deinit(transient);
    if (doc.root != .compound) return error.InvalidLevelDat;
    const data_tag = doc.root.compound.get("Data") orelse return error.InvalidLevelDat;
    if (data_tag.* != .compound) return error.InvalidLevelDat;
    const data = data_tag.compound;
    var result: worlds.Metadata = .{};
    errdefer result.deinit(a);
    if (data.get("LevelName")) |t| {
        if (t.* != .string or t.string.len == 0 or std.mem.indexOfScalar(u8, t.string, 0) != null) return error.InvalidLevelName;
        result.level_name = try a.dupe(u8, t.string);
    }
    if (data.get("LastPlayed")) |t| {
        if (t.* != .long or t.long < 0) return error.InvalidLastPlayed;
        result.last_played_ms = t.long;
    }
    if (data.get("GameType")) |t| {
        if (t.* != .int) return error.InvalidMetadataType;
        result.game_type = t.int;
    }
    if (data.get("hardcore")) |t| {
        if (t.* != .byte or (t.byte != 0 and t.byte != 1)) return error.InvalidMetadataType;
        result.hardcore = t.byte != 0;
    }
    if (data.get("DataVersion")) |t| {
        if (t.* != .int) return error.InvalidMetadataType;
        result.data_version = t.int;
    }
    if (data.get("Version")) |t| {
        if (t.* != .compound) return error.InvalidMetadataType;
        if (t.compound.get("Name")) |v| {
            if (v.* != .string) return error.InvalidMetadataType;
            result.version_name = try a.dupe(u8, v.string);
        }
    }
    return result;
}

/// Rewrites only Data.LevelName; all other owned tags are serialized unchanged.
pub fn rewrite(a: std.mem.Allocator, bytes: []const u8, name: []const u8) ![]u8 {
    if (name.len == 0 or name.len > 65535 or !std.unicode.utf8ValidateSlice(name)) return error.InvalidLevelName;
    for (name) |c| if (c < 32 or c == 127) return error.InvalidLevelName;
    var checked = try parse(a, bytes);
    checked.deinit(a);
    const scratch = try a.alloc(u8, 64 * 1024 * 1024);
    defer a.free(scratch);
    var fixed = std.heap.FixedBufferAllocator.init(scratch);
    const transient = fixed.allocator();
    var opts: nbt.Options = .java;
    opts.compression = .gzip;
    opts.reject_trailing_bytes = true;
    opts.max_input_bytes = 16 * 1024 * 1024;
    opts.max_decompressed_bytes = 16 * 1024 * 1024;
    opts.max_output_bytes = 16 * 1024 * 1024;
    opts.max_total_decoded_bytes = 32 * 1024 * 1024;
    opts.max_depth = 64;
    opts.max_collection_length = 1024 * 1024;
    opts.max_compound_entries = 16384;
    opts.max_string_bytes = 65535;
    var doc = nbt.parse(transient, bytes, opts) catch |err| return if (err == error.OutOfMemory) error.MetadataResourceLimit else err;
    defer doc.deinit(transient);
    const data = doc.root.compound.getMut("Data").?;
    const tag = data.compound.getMut("LevelName") orelse return error.InvalidLevelDat;
    if (tag.* != .string) return error.InvalidLevelDat;
    const replacement = try transient.dupe(u8, name);
    transient.free(tag.string);
    tag.string = replacement;
    const encoded = nbt.serialize(transient, doc, opts) catch |err| return if (err == error.OutOfMemory) error.MetadataResourceLimit else err;
    return a.dupe(u8, encoded);
}

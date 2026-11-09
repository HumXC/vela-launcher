//! Verified, content-addressed file storage. No URLs, credentials, or HTTP metadata.
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
pub const Hashes = struct {
    sha1: ?[20]u8 = null,
    sha256: ?[32]u8 = null,
    sha512: ?[64]u8 = null,

    pub fn path(self: Hashes, a: std.mem.Allocator, root: []const u8) !?[]u8 {
        if (self.sha512) |h| return try std.fmt.allocPrint(a, "{s}/artifacts/sha512/{s}", .{ root, std.fmt.bytesToHex(h, .lower) });
        if (self.sha256) |h| return try std.fmt.allocPrint(a, "{s}/artifacts/sha256/{s}", .{ root, std.fmt.bytesToHex(h, .lower) });
        if (self.sha1) |h| return try std.fmt.allocPrint(a, "{s}/artifacts/sha1/{s}", .{ root, std.fmt.bytesToHex(h, .lower) });
        return null;
    }
};

pub fn parseHex(comptime size: usize, text: ?[]const u8) !?[size]u8 {
    const value = text orelse return null;
    if (value.len != size * 2) return error.InvalidChecksum;
    var digest: [size]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, value) catch return error.InvalidChecksum;
    return digest;
}

/// Copies and checks the exact bytes being copied, never linking mutable consumers.
/// The caller owns the unique temporary path only after this function succeeds.
pub fn copyVerified(io: Io, source: []const u8, temporary: []const u8, hashes: Hashes, size: ?u64, limit: u64, cancel: *const std.atomic.Value(bool)) !u64 {
    const input = try Dir.cwd().openFile(io, source, .{});
    defer input.close(io);
    const stat = try input.stat(io);
    if (stat.kind != .file or stat.size > limit) return error.InvalidArtifact;
    const output = try Dir.cwd().createFile(io, temporary, .{ .exclusive = true, .permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o600) });
    var output_open = true;
    defer if (output_open) output.close(io);
    errdefer {
        output.close(io);
        output_open = false;
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        Dir.cwd().deleteFile(io, temporary) catch {};
    }
    var sha1 = @import("cache_hash").Sha1.init(.{});
    var sha256 = @import("cache_hash").Sha256.init(.{});
    var sha512 = @import("cache_hash").Sha512.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var count: u64 = 0;
    while (true) {
        if (cancel.load(.acquire)) return error.Canceled;
        const n = input.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        count += n;
        if (count > limit) return error.InvalidArtifact;
        const bytes = buffer[0..n];
        if (hashes.sha1 != null) sha1.update(bytes);
        if (hashes.sha256 != null) sha256.update(bytes);
        if (hashes.sha512 != null) sha512.update(bytes);
        try output.writeStreamingAll(io, bytes);
    }
    if (size) |expected| if (count != expected) return error.SizeMismatch;
    if (hashes.sha1) |expected| {
        var actual: [20]u8 = undefined;
        sha1.final(&actual);
        if (!std.mem.eql(u8, &actual, &expected)) return error.Sha1Mismatch;
    }
    if (hashes.sha256) |expected| {
        var actual: [32]u8 = undefined;
        sha256.final(&actual);
        if (!std.mem.eql(u8, &actual, &expected)) return error.Sha256Mismatch;
    }
    if (hashes.sha512) |expected| {
        var actual: [64]u8 = undefined;
        sha512.final(&actual);
        if (!std.mem.eql(u8, &actual, &expected)) return error.Sha512Mismatch;
    }
    if (cancel.load(.acquire)) return error.Canceled;
    try output.sync(io);
    return count;
}

/// Publish only a closed, verified copy. Concurrent writers replace with identical
/// content; nobody deletes the final entry, including when recovering corruption.
pub fn publish(a: std.mem.Allocator, io: Io, source: []const u8, destination: []const u8, hashes: Hashes, size: ?u64, limit: u64) !void {
    try Dir.cwd().createDirPath(io, std.fs.path.dirname(destination).?);
    var nonce: [16]u8 = undefined;
    try Io.randomSecure(io, &nonce);
    const temporary = try std.fmt.allocPrint(a, "{s}.{s}.part", .{ destination, std.fmt.bytesToHex(nonce, .lower) });
    defer a.free(temporary);
    const uncanceled: std.atomic.Value(bool) = .init(false);
    _ = try copyVerified(io, source, temporary, hashes, size, limit, &uncanceled);
    defer Dir.cwd().deleteFile(io, temporary) catch {};
    try Dir.cwd().rename(temporary, Dir.cwd(), destination, io);
}

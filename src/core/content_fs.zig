const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const providers = @import("content_providers.zig");
const Io = std.Io;
pub const Dir = Io.Dir;
pub const File = Io.File;

pub const Fingerprint = struct {
    size: u64,
    sha1: [40]u8,
    sha256: [64]u8,
    sha512: [128]u8,

    pub fn hashes(self: *const Fingerprint) providers.Hashes {
        return .{ .sha1 = &self.sha1, .sha256 = &self.sha256, .sha512 = &self.sha512 };
    }
    pub fn eql(self: Fingerprint, other: Fingerprint) bool {
        return self.size == other.size and std.mem.eql(u8, &self.sha1, &other.sha1) and
            std.mem.eql(u8, &self.sha256, &other.sha256) and std.mem.eql(u8, &self.sha512, &other.sha512);
    }
    pub fn verify(self: *const Fingerprint, expected: providers.Hashes, size: ?u64) !void {
        try providers.validateHashes(expected);
        if (size) |n| if (self.size != n) return error.SizeMismatch;
        if (expected.sha1) |h| if (!std.ascii.eqlIgnoreCase(h, &self.sha1)) return error.HashMismatch;
        if (expected.sha256) |h| if (!std.ascii.eqlIgnoreCase(h, &self.sha256)) return error.HashMismatch;
        if (expected.sha512) |h| if (!std.ascii.eqlIgnoreCase(h, &self.sha512)) return error.HashMismatch;
    }
};

pub fn privatePermissions(directory: bool) File.Permissions {
    if (builtin.os.tag == .windows) return if (directory) .default_dir else .default_file;
    return .fromMode(if (directory) 0o700 else 0o600);
}
pub fn syncDir(dir: Dir, io: Io) !void {
    // Windows flushes file contents; directory fsync is not supported there.
    if (builtin.os.tag == .windows) return;
    const file: File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try file.sync(io);
}
pub fn safeComponent(name: []const u8) bool {
    return config.validId(name) and std.mem.indexOfScalar(u8, name, '~') == null;
}
pub fn rejectReparse(stat: File.Stat) !void {
    if (stat.kind == .sym_link) return error.UnsafeFileType;
    if (builtin.os.tag == .windows) {
        if (stat.permissions.toAttributes().REPARSE_POINT) return error.UnsafeFileType;
    }
}
/// Enumerating before lookup prevents case-fold, Unicode and Windows short-name aliases.
pub fn inspectEntry(dir: Dir, io: Io, name: []const u8) !?File.Stat {
    if (!safeComponent(name)) return error.UnsafePath;
    var exact = false;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, name)) exact = true else if (std.ascii.eqlIgnoreCase(entry.name, name)) return error.NativePathAlias;
    }
    const stat = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (!exact) return error.NativePathAlias;
    try rejectReparse(stat);
    return stat;
}
pub fn child(dir: Dir, io: Io, name: []const u8, create: bool, private: bool) !Dir {
    if (!safeComponent(name)) return error.UnsafePath;
    var stat = try inspectEntry(dir, io, name);
    if (stat == null and create) {
        try dir.createDir(io, name, if (private) privatePermissions(true) else .default_dir);
        try syncDir(dir, io);
        stat = try inspectEntry(dir, io, name);
    }
    if (stat == null) return error.FileNotFound;
    if (stat.?.kind != .directory) return error.UnsafeFileType;
    const result = try dir.openDir(io, name, .{ .iterate = true, .follow_symlinks = false });
    errdefer result.close(io);
    const opened = try result.stat(io);
    try rejectReparse(opened);
    if (opened.kind != .directory or opened.inode != stat.?.inode) return error.UnsafeFileType;
    if (private and builtin.os.tag != .windows and opened.permissions.toMode() & 0o077 != 0) return error.UnsafePrivateDirectory;
    return result;
}
pub fn openAbsolute(io: Io, path: []const u8) !Dir {
    const root_len = (try @import("native_path.zig").absoluteRoot(path)).len;
    var result = try Dir.openDirAbsolute(io, path[0..root_len], .{ .iterate = true, .follow_symlinks = false });
    errdefer result.close(io);
    try rejectReparse(try result.stat(io));
    var it = std.mem.tokenizeAny(u8, path[root_len..], "/\\");
    while (it.next()) |part| {
        const next = try child(result, io, part, false, false);
        result.close(io);
        result = next;
    }
    return result;
}
pub fn descend(dir: Dir, io: Io, path: []const u8, create: bool) !Dir {
    var result = try dir.openDir(io, ".", .{ .iterate = true, .follow_symlinks = false });
    errdefer result.close(io);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        const next = try child(result, io, part, create, false);
        result.close(io);
        result = next;
    }
    return result;
}
pub const Parent = struct {
    dir: Dir,
    name: []const u8,
    pub fn deinit(self: Parent, io: Io) void {
        self.dir.close(io);
    }
};
pub fn parent(dir: Dir, io: Io, path: []const u8, create: bool) !Parent {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |index| {
        if (!safeComponent(path[index + 1 ..])) return error.UnsafePath;
        return .{ .dir = try descend(dir, io, path[0..index], create), .name = path[index + 1 ..] };
    }
    if (!safeComponent(path)) return error.UnsafePath;
    return .{ .dir = try dir.openDir(io, ".", .{ .iterate = true, .follow_symlinks = false }), .name = path };
}
/// Read-only verification never requests data or attribute write access.
pub fn openRegular(dir: Dir, io: Io, name: []const u8) !File {
    return openRegularMode(dir, io, name, .read_only);
}
/// Sealing changes attributes and flushes data. On Windows GENERIC_WRITE grants
/// FILE_WRITE_ATTRIBUTES and the write access required by NtFlushBuffersFile.
pub fn openRegularForSeal(dir: Dir, io: Io, name: []const u8) !File {
    return openRegularMode(dir, io, name, .read_write);
}
fn openRegularMode(dir: Dir, io: Io, name: []const u8, mode: Dir.OpenFileOptions.Mode) !File {
    const entry = (try inspectEntry(dir, io, name)) orelse return error.FileNotFound;
    if (entry.kind != .file or entry.nlink != 1) return error.UnsafeFileType;
    const file = try dir.openFile(io, name, .{ .mode = mode, .follow_symlinks = false });
    errdefer file.close(io);
    const stat = try file.stat(io);
    try rejectReparse(stat);
    if (stat.kind != .file or stat.nlink != 1 or stat.inode != entry.inode) return error.UnsafeFileType;
    return file;
}
pub fn cancelled(io: Io, cancel: ?*const std.atomic.Value(bool), deadline: ?i96) !void {
    if (cancel) |c| if (c.load(.acquire)) return error.Canceled;
    if (deadline) |d| if (Io.Clock.awake.now(io).nanoseconds >= d) return error.TimedOut;
}
pub fn stream(file: File, output: ?File, io: Io, max_bytes: u64, cancel: ?*const std.atomic.Value(bool), deadline: ?i96) !Fingerprint {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
    var sha512 = std.crypto.hash.sha2.Sha512.init(.{});
    var reader_buffer: [64 * 1024]u8 = undefined;
    var copy_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    var total: u64 = 0;
    while (true) {
        try cancelled(io, cancel, deadline);
        const count = reader.interface.readSliceShort(&copy_buffer) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
        };
        if (count == 0) break;
        if (count > max_bytes - total) return error.BodyTooLarge;
        total += count;
        const bytes = copy_buffer[0..count];
        sha1.update(bytes);
        sha256.update(bytes);
        sha512.update(bytes);
        if (output) |dest| try dest.writePositionalAll(io, bytes, total - count);
    }
    var digest1: [20]u8 = undefined;
    var digest256: [32]u8 = undefined;
    var digest512: [64]u8 = undefined;
    sha1.final(&digest1);
    sha256.final(&digest256);
    sha512.final(&digest512);
    if (output) |dest| try dest.sync(io);
    return .{ .size = total, .sha1 = std.fmt.bytesToHex(digest1, .lower), .sha256 = std.fmt.bytesToHex(digest256, .lower), .sha512 = std.fmt.bytesToHex(digest512, .lower) };
}
pub fn fingerprint(dir: Dir, io: Io, path: []const u8, cancel: ?*const std.atomic.Value(bool), deadline: ?i96) !?Fingerprint {
    const leaf = parent(dir, io, path, false) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer leaf.deinit(io);
    if (try inspectEntry(leaf.dir, io, leaf.name) == null) return null;
    const file = try openRegular(leaf.dir, io, leaf.name);
    defer file.close(io);
    return try stream(file, null, io, providers.max_file_bytes, cancel, deadline);
}
pub fn copy(source: File, directory: Dir, io: Io, name: []const u8, max_bytes: u64, cancel: ?*const std.atomic.Value(bool), deadline: ?i96) !Fingerprint {
    if (try inspectEntry(directory, io, name) != null) return error.PathAlreadyExists;
    const file = try directory.createFile(io, name, .{ .read = true, .exclusive = true, .permissions = privatePermissions(false) });
    defer file.close(io);
    errdefer directory.deleteFile(io, name) catch {};
    const result = try stream(source, file, io, max_bytes, cancel, deadline);
    try syncDir(directory, io);
    return result;
}
pub fn write(directory: Dir, io: Io, name: []const u8, bytes: []const u8) !void {
    if (try inspectEntry(directory, io, name) != null) return error.PathAlreadyExists;
    const file = try directory.createFile(io, name, .{ .exclusive = true, .permissions = privatePermissions(false) });
    defer file.close(io);
    errdefer directory.deleteFile(io, name) catch {};
    try file.writePositionalAll(io, bytes, 0);
    try file.sync(io);
    try syncDir(directory, io);
}
/// Publish only within a private transaction directory; a torn temporary is disposable.
pub fn atomicWrite(directory: Dir, io: Io, name: []const u8, bytes: []const u8) !void {
    var buffer: [256]u8 = undefined;
    const temporary = try std.fmt.bufPrint(&buffer, ".{s}.pending", .{name});
    if (try inspectEntry(directory, io, name) != null) return error.PathAlreadyExists;
    if (try inspectEntry(directory, io, temporary) != null) {
        const stale = try openRegular(directory, io, temporary);
        stale.close(io);
        try directory.deleteFile(io, temporary);
        try syncDir(directory, io);
    }
    try write(directory, io, temporary, bytes);
    errdefer directory.deleteFile(io, temporary) catch {};
    try directory.renamePreserve(temporary, directory, name, io);
    try syncDir(directory, io);
}
pub fn read(a: std.mem.Allocator, directory: Dir, io: Io, name: []const u8, limit: usize) ![]u8 {
    const file = try openRegular(directory, io, name);
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const capacity = std.math.add(usize, limit, 1) catch return error.StreamTooLong;
    const bytes = reader.interface.allocRemaining(a, .limited(capacity)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => return err,
    };
    errdefer a.free(bytes);
    if (bytes.len > limit) return error.StreamTooLong;
    return bytes;
}

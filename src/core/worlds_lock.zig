//! Held inode locks compatible with Java FileChannel locks, never flock on POSIX.
//! OFD locks survive unrelated descriptor closes; unsupported kernels fail closed.
const std = @import("std");
const builtin = @import("builtin");
const tree = @import("worlds_tree.zig");
const instances = @import("instances.zig");
const Io = std.Io;

pub const Held = struct {
    file: Io.File,
    directory: Io.Dir,
    name: []const u8,

    pub fn close(self: Held, io: Io) void {
        // Closing the owning descriptor releases the OFD/native lock atomically.
        self.file.close(io);
    }

    pub fn recheck(self: Held, io: Io) !void {
        const opened = try self.file.stat(io);
        const named = self.directory.statFile(io, self.name, .{ .follow_symlinks = false }) catch return error.WorldLockChanged;
        if (named.kind != .file or named.inode != opened.inode) return error.WorldLockChanged;
    }
};

pub fn requireSupported() !void {
    switch (builtin.os.tag) {
        .linux, .macos, .windows => {},
        else => return error.WorldLockUnsupported,
    }
}

pub const Access = enum { available, in_use, unavailable };

/// Informational scan only: neither creates nor writes a session token.
/// A stale token is available; inability to inspect safely remains unavailable.
pub fn probe(io: Io, directory: Io.Dir, name: []const u8) Access {
    const held = acquireExisting(io, directory, name) catch |err| return if (err == error.WorldLocked) .in_use else .unavailable;
    if (held) |token| token.close(io);
    return .available;
}

/// Inspect live session state without creating or rewriting the token.
pub fn acquireExisting(io: Io, directory: Io.Dir, name: []const u8) !?Held {
    try requireSupported();
    const file = directory.openFile(io, name, .{ .mode = .read_write, .follow_symlinks = false, .allow_directory = false }) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    errdefer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.UnsafeFileType;
    try lock(io, file);
    const held: Held = .{ .file = file, .directory = directory, .name = name };
    try held.recheck(io);
    return held;
}

/// Existing bytes are never rewritten/truncated and lock files are never unlinked.
/// Creating exclusively, then reopening without following links closes the create race.
pub fn acquire(io: Io, directory: Io.Dir, name: []const u8) !Held {
    try requireSupported();
    if (!instances.safeRelativePath(name) or std.mem.indexOfScalar(u8, name, '/') != null) return error.UnsafePath;
    const file = directory.openFile(io, name, .{ .mode = .read_write, .follow_symlinks = false, .allow_directory = false }) catch |err| blk: {
        if (err != error.FileNotFound) return err;
        break :blk directory.createFile(io, name, .{ .read = true, .exclusive = true }) catch |create_err| {
            if (create_err != error.PathAlreadyExists) return create_err;
            break :blk try directory.openFile(io, name, .{ .mode = .read_write, .follow_symlinks = false, .allow_directory = false });
        };
    };
    errdefer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.UnsafeFileType;
    try lock(io, file);
    const held: Held = .{ .file = file, .directory = directory, .name = name };
    try held.recheck(io);
    try tree.syncDir(io, directory);
    return held;
}

fn lock(io: Io, file: Io.File) !void {
    try io.checkCancel();
    if (builtin.os.tag == .windows) {
        // NtLockFile uses the same native byte-range locks as Java LockFileEx.
        if (!try file.tryLock(io, .exclusive)) return error.WorldLocked;
    } else if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        var region: std.c.Flock = std.mem.zeroes(std.c.Flock);
        region.type = std.c.F.WRLCK;
        region.whence = std.c.SEEK.SET;
        // start=0,len=0 locks through EOF, including future bytes.
        // Darwin F_OFD_SETLK=90 is declared in Zig's bundled sys/fcntl.h.
        const command = if (builtin.os.tag == .linux) std.os.linux.F.OFD_SETLK else 90;
        while (true) {
            const result = if (builtin.os.tag == .linux)
                std.os.linux.fcntl(file.handle, command, @intFromPtr(&region))
            else
                std.c.fcntl(file.handle, command, &region);
            const err = if (builtin.os.tag == .linux) std.os.linux.errno(result) else std.posix.errno(result);
            switch (err) {
                .SUCCESS => return,
                .INTR => try io.checkCancel(),
                .ACCES, .AGAIN => return error.WorldLocked,
                .NOLCK => return error.SystemResources,
                else => return error.WorldLockUnsupported,
            }
        }
    } else return error.WorldLockUnsupported;
}

/// Refuse to mutate a name that no longer refers to the directory we read/locked.
pub fn sameDirectory(io: Io, parent: Io.Dir, name: []const u8, opened: Io.Dir) !void {
    const named = parent.statFile(io, name, .{ .follow_symlinks = false }) catch return error.TreeChanged;
    if (named.kind != .directory or named.inode != (try opened.stat(io)).inode) return error.TreeChanged;
}

//! Bounded, no-follow world trees. No arbitrary user-supplied absolute child paths.
const std = @import("std");
const instances = @import("instances.zig");
const A = std.mem.Allocator;
const Dir = std.Io.Dir;
const Sha = std.crypto.hash.sha2.Sha256;

pub const Limits = struct {
    max_files: usize = 100_000,
    max_bytes: u64 = 32 * 1024 * 1024 * 1024,
    max_file_bytes: u64 = 4 * 1024 * 1024 * 1024,
    max_depth: usize = 32,
    max_manifest_bytes: usize = 32 * 1024 * 1024,
};
pub const Hooks = struct {
    context: ?*anyopaque = null,
    canceled: ?*const fn (?*anyopaque) bool = null,
    progress: ?*const fn (?*anyopaque, usize, u64) void = null,
    /// Notification only; cancellation set here cannot undo a committed result.
    committed: ?*const fn (?*anyopaque) void = null,

    pub fn check(self: Hooks, io: std.Io) !void {
        try io.checkCancel();
        if (self.canceled) |f| if (f(self.context)) return error.Canceled;
    }
};
pub const Entry = struct { path: []const u8, directory: bool, size: u64 = 0, sha256: [32]u8 = @splat(0) };
pub const Snapshot = struct {
    allocator: A,
    entries: []Entry,
    bytes: u64,
    pub fn deinit(self: *Snapshot) void {
        for (self.entries) |e| self.allocator.free(e.path);
        self.allocator.free(self.entries);
        self.* = undefined;
    }
};

/// Every absolute path component is opened independently; no parent symlink is followed.
/// The launcher root must already exist. Child creation is relative to these handles.
pub fn openAbsolute(io: std.Io, path: []const u8) !Dir {
    if (!std.fs.path.isAbsolute(path)) return error.UnsafePath;
    const root = if (@import("builtin").os.tag == .windows) path[0 .. std.fs.path.diskDesignator(path).len + 1] else "/";
    var dir = try Dir.openDirAbsolute(io, root, .{ .iterate = true, .follow_symlinks = false });
    errdefer dir.close(io);
    var parts = std.mem.tokenizeAny(u8, path[root.len..], "/\\");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.UnsafePath;
        const next = try dir.openDir(io, part, .{ .iterate = true, .follow_symlinks = false });
        dir.close(io);
        dir = next;
    }
    return dir;
}

/// Move-only private stage owner. The parent handle and name outlive this owner.
/// Acquisition and removal block native future cancellation; token cancellation
/// remains the caller's responsibility before entering either bounded operation.
pub const StageOwner = struct {
    parent: Dir,
    name: []const u8,
    directory: ?Dir,
    identity: Dir.Stat,
    armed: bool = true,

    pub fn create(io: std.Io, parent: Dir, name: []const u8, permissions: Dir.Permissions) !StageOwner {
        try validateChild(name);
        try io.checkCancel();
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        // Exclusive creation never adopts a preexisting directory as our stage.
        try parent.createDir(io, name, permissions);
        // Without an identity, deletion cannot be proved safe. Preserve the
        // uncertain path and report recovery instead of deleting a replacement.
        const identity = parent.statFile(io, name, .{ .follow_symlinks = false }) catch return error.RecoveryRequired;
        if (identity.kind != .directory) return error.RecoveryRequired;
        var owner: StageOwner = .{ .parent = parent, .name = name, .directory = null, .identity = identity };
        errdefer owner.close(io);
        owner.directory = parent.openDir(io, name, .{ .iterate = true, .follow_symlinks = false }) catch |err| {
            owner.cleanup(io) catch return error.RecoveryRequired;
            return err;
        };
        owner.verify(io) catch |err| {
            owner.cleanup(io) catch return error.RecoveryRequired;
            return err;
        };
        syncDir(io, parent) catch |err| {
            owner.cleanup(io) catch return error.RecoveryRequired;
            return err;
        };
        return owner;
    }

    pub fn verify(self: *const StageOwner, io: std.Io) !void {
        const named = try self.parent.statFile(io, self.name, .{ .follow_symlinks = false });
        if (named.kind != .directory or named.inode != self.identity.inode) return error.TreeChanged;
        if (self.directory) |dir| {
            const opened = try dir.stat(io);
            if (opened.kind != .directory or opened.inode != self.identity.inode) return error.TreeChanged;
        }
    }

    pub fn close(self: *StageOwner, io: std.Io) void {
        if (self.directory) |dir| dir.close(io);
        self.directory = null;
    }

    pub fn cleanup(self: *StageOwner, io: std.Io) !void {
        if (!self.armed) return;
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        self.verify(io) catch |err| switch (err) {
            error.FileNotFound => {
                self.close(io);
                self.armed = false;
                return;
            },
            else => return err,
        };
        self.close(io);
        try self.parent.deleteTree(io, self.name);
        self.armed = false;
        try syncDir(io, self.parent);
    }
};

fn validateChild(name: []const u8) !void {
    if (!instances.safeRelativePath(name) or std.mem.indexOfScalar(u8, name, '/') != null) return error.UnsafePath;
}

pub fn child(io: std.Io, dir: Dir, name: []const u8, create: bool) !Dir {
    try validateChild(name);
    if (create) {
        var owner = StageOwner.create(io, dir, name, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                // Existing shared ancestors are never armed for cleanup.
                try syncDir(io, dir);
                return dir.openDir(io, name, .{ .iterate = true, .follow_symlinks = false });
            },
            else => return err,
        };
        owner.armed = false;
        return owner.directory.?;
    }
    return dir.openDir(io, name, .{ .iterate = true, .follow_symlinks = false });
}

pub fn readBounded(a: A, io: std.Io, dir: Dir, name: []const u8, limit: usize) ![]u8 {
    if (!instances.safeRelativePath(name) or std.mem.indexOfScalar(u8, name, '/') != null) return error.UnsafePath;
    const file = try dir.openFile(io, name, .{ .follow_symlinks = false });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.UnsafeFileType;
    if (stat.size > limit) return error.ResourceLimit;
    const bytes = try a.alloc(u8, @intCast(stat.size));
    errdefer a.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.TreeChanged;
    var extra: [1]u8 = undefined;
    if (try file.readPositional(io, &.{&extra}, stat.size) != 0) return error.TreeChanged;
    return bytes;
}

fn entryLess(_: void, x: Entry, y: Entry) bool {
    return std.mem.lessThan(u8, x.path, y.path);
}

pub fn snapshot(a: A, io: std.Io, source: Dir, destination: ?Dir, limits: Limits, hooks: Hooks) !Snapshot {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |e| a.free(e.path);
        entries.deinit(a);
    }
    var bytes: u64 = 0;
    try walk(a, io, source, destination, "", 0, limits, hooks, &entries, &bytes);
    std.mem.sort(Entry, entries.items, {}, entryLess);
    return .{ .allocator = a, .entries = try entries.toOwnedSlice(a), .bytes = bytes };
}

fn walk(a: A, io: std.Io, source: Dir, destination: ?Dir, prefix: []const u8, depth: usize, limits: Limits, hooks: Hooks, entries: *std.ArrayList(Entry), bytes: *u64) anyerror!void {
    if (depth > limits.max_depth) return error.ResourceLimit;
    var it = source.iterate();
    while (try it.next(io)) |item| {
        try hooks.check(io);
        if (!instances.safeRelativePath(item.name) or std.mem.indexOfScalar(u8, item.name, '/') != null) return error.UnsafePath;
        if (entries.items.len >= limits.max_files) return error.ResourceLimit;
        const relative = if (prefix.len == 0) try a.dupe(u8, item.name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, item.name });
        var owned = false;
        defer if (!owned) a.free(relative);
        if (relative.len > 4096) return error.ResourceLimit;
        const stat = try source.statFile(io, item.name, .{ .follow_symlinks = false });
        if (stat.kind != .directory and stat.kind != .file) return error.UnsafeFileType;
        // Root session.lock is ephemeral OS lock state, never backup/game data.
        // Do not open/close its descriptor: POSIX process locks can be released by
        // unrelated closes, and Windows locks also exclude reading these bytes.
        if (prefix.len == 0 and std.ascii.eqlIgnoreCase(item.name, "session.lock")) {
            if (stat.kind != .file or !std.mem.eql(u8, item.name, "session.lock")) return error.UnsafeFileType;
            continue;
        }
        if (stat.kind == .directory) {
            const src = try child(io, source, item.name, false);
            defer src.close(io);
            const dst = if (destination) |d| try child(io, d, item.name, true) else null;
            defer if (dst) |d| d.close(io);
            try entries.append(a, .{ .path = relative, .directory = true });
            owned = true;
            try walk(a, io, src, dst, relative, depth + 1, limits, hooks, entries, bytes);
        } else {
            if (stat.size > limits.max_file_bytes or stat.size > limits.max_bytes -| bytes.*) return error.ResourceLimit;
            const src = try source.openFile(io, item.name, .{ .follow_symlinks = false });
            defer src.close(io);
            const opened = try src.stat(io);
            if (opened.kind != .file or opened.inode != stat.inode or opened.size != stat.size) return error.TreeChanged;
            const dst = if (destination) |d| try d.createFile(io, item.name, .{ .exclusive = true }) else null;
            defer if (dst) |f| f.close(io);
            var digest: Sha = .init(.{});
            var buffer: [64 * 1024]u8 = undefined;
            var offset: u64 = 0;
            while (offset < stat.size) {
                try hooks.check(io);
                const want: usize = @intCast(@min(buffer.len, stat.size - offset));
                const n = try src.readPositional(io, &.{buffer[0..want]}, offset);
                if (n == 0) return error.TreeChanged;
                digest.update(buffer[0..n]);
                if (dst) |f| try f.writePositionalAll(io, buffer[0..n], offset);
                offset += n;
                if (hooks.progress) |p| p(hooks.context, entries.items.len, bytes.* + offset);
            }
            const after = try src.stat(io);
            if (after.size != stat.size or after.mtime.nanoseconds != opened.mtime.nanoseconds or after.ctime.nanoseconds != opened.ctime.nanoseconds) return error.TreeChanged;
            if (dst) |f| {
                f.setTimestamps(io, .{ .access_timestamp = .init(opened.atime), .modify_timestamp = .{ .new = opened.mtime } }) catch |err| switch (err) {
                    error.Canceled => return err,
                    else => {},
                };
                try f.sync(io);
            }
            var hash: [32]u8 = undefined;
            digest.final(&hash);
            try entries.append(a, .{ .path = relative, .directory = false, .size = stat.size, .sha256 = hash });
            owned = true;
            bytes.* += stat.size;
        }
    }
    if (destination) |dir| try syncDir(io, dir);
}

/// Io backends already support syncing native directory handles on POSIX.
/// POSIX barrier failures stop before mutation, or require uncertainty after it.
/// Windows has no portable directory barrier; callers must downgrade durability.
pub const directory_sync_supported = @import("builtin").os.tag != .windows;
pub fn syncDir(io: std.Io, dir: Dir) !void {
    if (!directory_sync_supported) return;
    const file: std.Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try file.sync(io);
}

pub fn equal(x: Snapshot, y: Snapshot) bool {
    if (x.entries.len != y.entries.len or x.bytes != y.bytes) return false;
    for (x.entries, y.entries) |a, b| {
        if (!std.mem.eql(u8, a.path, b.path) or a.directory != b.directory or a.size != b.size or !std.mem.eql(u8, &a.sha256, &b.sha256)) return false;
    }
    return true;
}

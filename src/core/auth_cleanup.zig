//! Worker-only, single-owner journal of NONSECRET opaque credential references.
//! Never pass tokens to this module. Call stage successfully before Store.put.
//! Persistence failures poison the instance: reload before any retry or vault write.
const std = @import("std");
const windows_fs = @import("windows_durable_fs.zig");
const builtin = @import("builtin");
const credentials = @import("credentials.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;

pub const max_bytes = 64 * 1024;
pub const max_references = 256;
const filename = "auth-cleanup.json";
pub const Error = error{
    OutOfMemory,
    InvalidRoot,
    InvalidJournal,
    UnsupportedSchemaVersion,
    TooManyReferences,
    InvalidReference,
    DuplicateReference,
    JournalTooLarge,
    InsecureJournal,
    PersistenceFailure,
    CommitUncertain,
    JournalUncertain,
    JournalChanged,
    UnsupportedDurability,
};

/// A fixture save must report success only when committed. Errors may be ambiguous.
pub const Backend = struct {
    ctx: *anyopaque,
    save: *const fn (*anyopaque, []const u8) Error!void,
};

pub const Journal = struct {
    a: Allocator,
    io: Io,
    root: []const u8,
    windows_root: ?windows_fs.Root = null,
    refs: std.ArrayList(credentials.Reference) = .empty,
    backend: ?Backend = null,
    exists: bool = false,
    uncertain: bool = false,

    /// Does I/O: use only on the auth worker. Root must already exist and be absolute.
    /// Missing .vela/journal gives empty state; nothing is created by init.
    /// Windows uses a held private capability; WASI remains unsupported.
    pub fn init(a: Allocator, io: Io, root: []const u8) Error!Journal {
        if (builtin.os.tag == .windows) {
            var owned: ?windows_fs.Root = windows_fs.openRoot(a, io, root, .private_journal) catch |err| return windowsError(err);
            return initWithOwnedRoot(a, io, &owned);
        }
        if (builtin.os.tag == .wasi) return error.UnsupportedDurability;
        try validateRoot(root);
        var result: Journal = .{ .a = a, .io = io, .root = try a.dupe(u8, root) };
        errdefer result.deinit();
        const base = openRoot(io, root) catch return error.InvalidRoot;
        defer base.close(io);
        const dir = openJournalDir(base, io) catch |err| switch (err) {
            error.FileNotFound => return result,
            else => return error.InsecureJournal,
        };
        defer dir.close(io);
        if (try load(a, io, dir)) |refs| {
            result.refs = refs;
            result.exists = true;
        }
        return result;
    }

    /// Consumes the capability on success AND failure. Its ops context must stay
    /// at a stable address until deinit; no filesystem path resolution is performed.
    pub fn initWithOwnedRoot(a: Allocator, io: Io, owned: *?windows_fs.Root) Error!Journal {
        var capability = owned.* orelse return error.InvalidRoot;
        owned.* = null;
        errdefer windows_fs.deinit(&capability);
        if (capability.privacy != .private_journal) return error.InsecureJournal;
        const root = try a.dupe(u8, capability.normalized);
        errdefer a.free(root);
        var loaded = windows_fs.load(&capability, a, filename, max_bytes) catch |err| return windowsError(err);
        defer if (loaded) |*bytes| bytes.deinit();
        return .{ .a = a, .io = io, .root = root, .windows_root = capability, .exists = loaded != null, .uncertain = capability.publication_uncertain, .refs = if (loaded) |bytes| try parse(a, bytes.bytes) else .empty };
    }

    /// No filesystem/vault/network calls. Owns all parsed reference bytes.
    pub fn initFixture(a: Allocator, bytes: ?[]const u8, backend: Backend) Error!Journal {
        var result: Journal = .{ .a = a, .io = undefined, .root = try a.dupe(u8, ""), .backend = backend, .exists = bytes != null };
        errdefer result.deinit();
        if (bytes) |text| result.refs = try parse(a, text);
        return result;
    }

    pub fn deinit(self: *Journal) void {
        self.refs.deinit(self.a);
        if (self.windows_root) |*root| windows_fs.deinit(root);
        self.a.free(self.root);
        self.* = undefined;
    }

    pub fn references(self: *const Journal) []const credentials.Reference {
        return self.refs.items;
    }

    /// Idempotent state; filesystem re-staging flushes again after ambiguous reload.
    /// No secret argument exists.
    pub fn stage(self: *Journal, ref: credentials.Reference) Error!void {
        if (self.uncertain) return error.JournalUncertain;
        if (!credentials.validateReference(&ref)) return error.InvalidReference;
        var found = false;
        for (self.refs.items) |old| {
            if (std.mem.eql(u8, &old, &ref)) {
                found = true;
                break;
            }
        }
        if (found and self.backend != null) return;
        if (!found and self.refs.items.len == max_references) return error.TooManyReferences;
        var next: std.ArrayList(credentials.Reference) = .empty;
        defer next.deinit(self.a);
        try next.appendSlice(self.a, self.refs.items);
        if (!found) try next.append(self.a, ref);
        try self.commit(&next);
    }

    /// Remove only after config acknowledgement, or successful explicit vault cleanup.
    pub fn remove(self: *Journal, ref: credentials.Reference) Error!void {
        if (self.uncertain) return error.JournalUncertain;
        if (!credentials.validateReference(&ref)) return error.InvalidReference;
        var found = false;
        var next: std.ArrayList(credentials.Reference) = .empty;
        defer next.deinit(self.a);
        for (self.refs.items) |old| {
            if (std.mem.eql(u8, &old, &ref)) found = true else try next.append(self.a, old);
        }
        if (found) try self.commit(&next);
    }

    fn commit(self: *Journal, next: *std.ArrayList(credentials.Reference)) Error!void {
        var strings: [max_references][]const u8 = undefined;
        for (next.items, 0..) |*ref, i| strings[i] = ref;
        const bytes = try std.json.Stringify.valueAlloc(self.a, .{
            .schemaVersion = @as(u32, 1),
            .references = strings[0..next.items.len],
        }, .{});
        defer self.a.free(bytes);
        if (self.backend) |backend| {
            backend.save(backend.ctx, bytes) catch |err| {
                self.uncertain = true;
                return err;
            };
        } else self.save(bytes) catch |err| {
            self.uncertain = true;
            return err;
        };
        self.refs.deinit(self.a);
        self.refs = next.*;
        next.* = .empty;
        self.exists = true;
    }

    fn save(self: *Journal, bytes: []const u8) Error!void {
        if (self.windows_root) |*root| {
            windows_fs.publish(root, filename, bytes, .{ .context = self, .run = checkWindowsCurrent }) catch |err| return windowsError(err);
            return;
        }
        if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.UnsupportedDurability;
        const base = openRoot(self.io, self.root) catch return error.InvalidRoot;
        defer base.close(self.io);
        const dir = openJournalDir(base, self.io) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (self.exists) return error.JournalChanged;
                base.createDir(self.io, ".vela", .fromMode(0o700)) catch return error.PersistenceFailure;
                syncDir(base, self.io) catch return error.CommitUncertain;
                break :blk openJournalDir(base, self.io) catch return error.InsecureJournal;
            },
            else => return error.InsecureJournal,
        };
        defer dir.close(self.io);
        try self.checkCurrent(dir);
        // Flush the .vela entry even if another worker created it before init.
        syncDir(base, self.io) catch return error.CommitUncertain;
        var random: [16]u8 = undefined;
        Io.randomSecure(self.io, &random) catch return error.PersistenceFailure;
        var temp_buffer: [80]u8 = undefined;
        const temp = std.fmt.bufPrint(&temp_buffer, ".auth-cleanup-{s}.tmp", .{std.fmt.bytesToHex(random, .lower)}) catch unreachable;
        // POSIX O_CREAT|O_EXCL rejects existing names, including symlinks, atomically.
        const file = dir.createFile(self.io, temp, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch return error.PersistenceFailure;
        defer file.close(self.io);
        var renamed = false;
        defer if (!renamed) dir.deleteFile(self.io, temp) catch {};
        // Enforce exact 0600 even under a restrictive process umask.
        file.setPermissions(self.io, .fromMode(0o600)) catch return error.PersistenceFailure;
        file.writeStreamingAll(self.io, bytes) catch return error.PersistenceFailure;
        file.sync(self.io) catch return error.PersistenceFailure;
        // Do not replace a malformed/insecure journal introduced during the write.
        try self.checkCurrent(dir);
        Dir.rename(dir, temp, dir, filename, self.io) catch return error.CommitUncertain;
        renamed = true;
        syncDir(dir, self.io) catch return error.CommitUncertain;
    }

    fn checkWindowsCurrent(context: ?*anyopaque, root: *windows_fs.Root) anyerror!void {
        const self: *Journal = @ptrCast(@alignCast(context.?));
        var current = try windows_fs.load(root, self.a, filename, max_bytes);
        defer if (current) |*bytes| bytes.deinit();
        if ((current != null) != self.exists) return error.JournalChanged;
        if (current) |bytes| {
            var refs = try parse(self.a, bytes.bytes);
            defer refs.deinit(self.a);
            if (refs.items.len != self.refs.items.len) return error.JournalChanged;
            for (refs.items, self.refs.items) |left, right| {
                if (!std.mem.eql(u8, &left, &right)) return error.JournalChanged;
            }
        }
    }

    fn windowsError(err: anyerror) Error {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidRoot => error.InvalidRoot,
            error.InvalidLeaf, error.InvalidJournal => error.InvalidJournal,
            error.FileTooLarge, error.JournalTooLarge => error.JournalTooLarge,
            error.UnsupportedSchemaVersion => error.UnsupportedSchemaVersion,
            error.TooManyReferences => error.TooManyReferences,
            error.InvalidReference => error.InvalidReference,
            error.DuplicateReference => error.DuplicateReference,
            error.InsecureJournal => error.InsecureJournal,
            error.JournalChanged => error.JournalChanged,
            error.CommitUncertain => error.CommitUncertain,
            error.UnsupportedDurability => error.UnsupportedDurability,
            else => error.PersistenceFailure,
        };
    }

    fn checkCurrent(self: *Journal, dir: Dir) Error!void {
        var current = try load(self.a, self.io, dir);
        defer if (current) |*refs| refs.deinit(self.a);
        if ((current != null) != self.exists) return error.JournalChanged;
        if (current) |refs| {
            if (refs.items.len != self.refs.items.len) return error.JournalChanged;
            for (refs.items, self.refs.items) |left, right| {
                if (!std.mem.eql(u8, &left, &right)) return error.JournalChanged;
            }
        }
    }
};

fn parse(a: Allocator, bytes: []const u8) Error!std.ArrayList(credentials.Reference) {
    if (bytes.len > max_bytes) return error.JournalTooLarge;
    const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{
        .allocate = .alloc_always,
        .max_value_len = max_bytes,
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidJournal;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJournal;
    const object = parsed.value.object;
    if (object.count() != 2) return error.InvalidJournal;
    const version = object.get("schemaVersion") orelse return error.InvalidJournal;
    if (version != .integer) return error.InvalidJournal;
    if (version.integer != 1) return error.UnsupportedSchemaVersion;
    const references = object.get("references") orelse return error.InvalidJournal;
    if (references != .array) return error.InvalidJournal;
    if (references.array.items.len > max_references) return error.TooManyReferences;
    var refs: std.ArrayList(credentials.Reference) = .empty;
    errdefer refs.deinit(a);
    try refs.ensureTotalCapacity(a, references.array.items.len);
    for (references.array.items) |value| {
        if (value != .string or !credentials.validateReference(value.string)) return error.InvalidReference;
        for (refs.items) |old| if (std.mem.eql(u8, &old, value.string)) return error.DuplicateReference;
        refs.appendAssumeCapacity(value.string[0..32].*);
    }
    return refs;
}

fn validateRoot(root: []const u8) Error!void {
    if (root.len == 0 or root.len > 4096 or root[0] != '/' or std.mem.indexOfAny(u8, root, "\\\x00") != null) return error.InvalidRoot;
    var parts = std.mem.tokenizeScalar(u8, root, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidRoot;
    }
}

fn openRoot(io: Io, root: []const u8) !Dir {
    // iterate=true avoids Linux O_PATH handles, which cannot be fsynced.
    var current = try Dir.openDirAbsolute(io, "/", .{ .iterate = true, .follow_symlinks = false });
    errdefer current.close(io);
    var parts = std.mem.tokenizeScalar(u8, root, '/');
    while (parts.next()) |part| {
        const stat = try current.statFile(io, part, .{ .follow_symlinks = false });
        if (stat.kind != .directory) return error.InvalidRoot;
        const next = try current.openDir(io, part, .{ .iterate = true, .follow_symlinks = false });
        current.close(io);
        current = next;
    }
    return current;
}

fn openJournalDir(base: Dir, io: Io) !Dir {
    const stat = try base.statFile(io, ".vela", .{ .follow_symlinks = false });
    if (stat.kind != .directory or stat.permissions.toMode() & 0o022 != 0) return error.InsecureJournal;
    const dir = try base.openDir(io, ".vela", .{ .iterate = true, .follow_symlinks = false });
    errdefer dir.close(io);
    const opened = try dir.stat(io);
    if (opened.kind != .directory or opened.permissions.toMode() & 0o022 != 0) return error.InsecureJournal;
    return dir;
}

fn load(a: Allocator, io: Io, dir: Dir) Error!?std.ArrayList(credentials.Reference) {
    const stat = dir.statFile(io, filename, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return error.InsecureJournal,
    };
    try checkStat(stat);
    const file = dir.openFile(io, filename, .{ .follow_symlinks = false, .allow_directory = false }) catch return error.InsecureJournal;
    defer file.close(io);
    const opened = file.stat(io) catch return error.InsecureJournal;
    try checkStat(opened);
    if (stat.inode != opened.inode) return error.JournalChanged;
    const bytes = try a.alloc(u8, max_bytes + 1);
    defer a.free(bytes);
    const n = file.readPositionalAll(io, bytes, 0) catch return error.PersistenceFailure;
    if (n > max_bytes) return error.JournalTooLarge;
    return try parse(a, bytes[0..n]);
}

fn checkStat(stat: Io.File.Stat) Error!void {
    if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o7777 != 0o600) return error.InsecureJournal;
    if (stat.size > max_bytes) return error.JournalTooLarge;
}

fn syncDir(dir: Dir, io: Io) !void {
    const file: Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try file.sync(io);
}

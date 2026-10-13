const std = @import("std");
const builtin = @import("builtin");
const cleanup = @import("auth_cleanup.zig");
const credentials = @import("credentials.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const empty = "{\"schemaVersion\":1,\"references\":[]}";
const one = "{\"schemaVersion\":1,\"references\":[\"0123456789abcdef0123456789abcdef\"]}";
const first: credentials.Reference = "0123456789abcdef0123456789abcdef".*;
const second: credentials.Reference = "abcdef0123456789abcdef0123456789".*;

const Fixture = struct {
    bytes: ?[]u8 = null,
    calls: usize = 0,
    fail: ?cleanup.Error = null,
    commit_then_fail: bool = false,
    fn backend(self: *Fixture) cleanup.Backend {
        return .{ .ctx = self, .save = save };
    }
    fn deinit(self: *Fixture) void {
        if (self.bytes) |bytes| a.free(bytes);
    }
    fn save(ctx: *anyopaque, bytes: []const u8) cleanup.Error!void {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.fail != null and !self.commit_then_fail) return self.fail.?;
        const copy = try a.dupe(u8, bytes);
        if (self.bytes) |old| a.free(old);
        self.bytes = copy;
        if (self.fail) |err| return err;
    }
};

fn rootPath(tmp: *std.testing.TmpDir) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    return a.dupe(u8, buffer[0..n]);
}
fn diskWrite(tmp: *std.testing.TmpDir, bytes: []const u8, mode: std.posix.mode_t) !void {
    tmp.dir.createDir(io, ".vela", .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const file = try tmp.dir.createFile(io, ".vela/auth-cleanup.json", .{ .permissions = .fromMode(mode) });
    defer file.close(io);
    try file.setPermissions(io, .fromMode(mode));
    try file.writeStreamingAll(io, bytes);
}
fn refFor(n: u128) credentials.Reference {
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u128, &bytes, n, .big);
    return std.fmt.bytesToHex(bytes, .lower);
}

test "fixture owns parsed references and commits reference-only JSON" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    const bytes = try a.dupe(u8, one);
    var journal = try cleanup.Journal.initFixture(a, bytes, fixture.backend());
    defer journal.deinit();
    @memset(bytes, 'x');
    a.free(bytes);
    try std.testing.expectEqual(first, journal.references()[0]);
    try journal.stage(first);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try journal.stage(second);
    try std.testing.expectEqual(@as(usize, 2), journal.references().len);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, fixture.bytes.?, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.count());
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("schemaVersion").?.integer);
    try std.testing.expectEqualStrings(&second, parsed.value.object.get("references").?.array.items[1].string);
    try journal.remove(first);
    try journal.remove(first);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqual(second, journal.references()[0]);
}

test "strict structured parsing rejects malformed, unknown, duplicate and invalid fields" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    for ([_][]const u8{
        "",                                                                   "{}",                                                          "[]",                                          "null",                                      "{",                                       empty ++ "x",
        "{\"schemaVersion\":1,\"references\":[],\"secret\":\"not allowed\"}", "{\"schemaVersion\":1,\"schemaVersion\":1,\"references\":[]}", "{\"schemaVersion\":\"1\",\"references\":[]}", "{\"schemaVersion\":1.0,\"references\":[]}", "{\"schemaVersion\":1,\"references\":{}}",
    }) |bytes| try std.testing.expectError(error.InvalidJournal, cleanup.Journal.initFixture(a, bytes, fixture.backend()));
    try std.testing.expectError(error.UnsupportedSchemaVersion, cleanup.Journal.initFixture(a, "{\"schemaVersion\":2,\"references\":[]}", fixture.backend()));
    for ([_][]const u8{
        "{\"schemaVersion\":1,\"references\":[12]}",
        "{\"schemaVersion\":1,\"references\":[\"ABCDEF0123456789abcdef0123456789\"]}",
        "{\"schemaVersion\":1,\"references\":[\"0123\"]}",
        "{\"schemaVersion\":1,\"references\":[\"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\"]}",
    }) |bytes| try std.testing.expectError(error.InvalidReference, cleanup.Journal.initFixture(a, bytes, fixture.backend()));
    try std.testing.expectError(error.DuplicateReference, cleanup.Journal.initFixture(a, "{\"schemaVersion\":1,\"references\":[\"0123456789abcdef0123456789abcdef\",\"0123456789abcdef0123456789abcdef\"]}", fixture.backend()));
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}

test "byte and count limits are enforced at boundaries" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    const oversized = try a.alloc(u8, cleanup.max_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, ' ');
    @memcpy(oversized[0..empty.len], empty);
    var exact = try cleanup.Journal.initFixture(a, oversized[0..cleanup.max_bytes], fixture.backend());
    exact.deinit();
    try std.testing.expectError(error.JournalTooLarge, cleanup.Journal.initFixture(a, oversized, fixture.backend()));
    var journal = try cleanup.Journal.initFixture(a, null, fixture.backend());
    defer journal.deinit();
    for (0..cleanup.max_references) |n| try journal.stage(refFor(n));
    try std.testing.expectEqual(@as(usize, cleanup.max_references), journal.references().len);
    try std.testing.expectError(error.TooManyReferences, journal.stage(refFor(cleanup.max_references)));
    var reloaded = try cleanup.Journal.initFixture(a, fixture.bytes.?, fixture.backend());
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, cleanup.max_references), reloaded.references().len);
    var strings: [cleanup.max_references + 1][]const u8 = undefined;
    @memset(&strings, &first);
    const too_many = try std.json.Stringify.valueAlloc(a, .{ .schemaVersion = @as(u32, 1), .references = &strings }, .{});
    defer a.free(too_many);
    try std.testing.expectError(error.TooManyReferences, cleanup.Journal.initFixture(a, too_many, fixture.backend()));
    try std.testing.expectError(error.InvalidReference, journal.stage(@splat('G')));
}

test "precommit and ambiguous stage failures forbid retry until reload" {
    for ([_]bool{ false, true }) |ambiguous| {
        var fixture: Fixture = .{ .fail = if (ambiguous) error.CommitUncertain else error.PersistenceFailure, .commit_then_fail = ambiguous };
        defer fixture.deinit();
        var journal = try cleanup.Journal.initFixture(a, null, fixture.backend());
        defer journal.deinit();
        try std.testing.expectError(fixture.fail.?, journal.stage(first));
        try std.testing.expectEqual(@as(usize, 0), journal.references().len);
        fixture.fail = null;
        try std.testing.expectError(error.JournalUncertain, journal.stage(first));
        try std.testing.expectError(error.JournalUncertain, journal.remove(first));
        var reload = try cleanup.Journal.initFixture(a, fixture.bytes, fixture.backend());
        defer reload.deinit();
        try std.testing.expectEqual(@as(usize, if (ambiguous) 1 else 0), reload.references().len);
        try reload.stage(first);
        try std.testing.expectEqual(@as(usize, 1), reload.references().len);
    }
}

test "ambiguous removal preserves old in-memory reference and reloads committed result" {
    var fixture: Fixture = .{ .fail = error.CommitUncertain, .commit_then_fail = true };
    defer fixture.deinit();
    var journal = try cleanup.Journal.initFixture(a, one, fixture.backend());
    defer journal.deinit();
    try std.testing.expectError(error.CommitUncertain, journal.remove(first));
    try std.testing.expectEqual(first, journal.references()[0]);
    fixture.fail = null;
    var reload = try cleanup.Journal.initFixture(a, fixture.bytes, fixture.backend());
    defer reload.deinit();
    try std.testing.expectEqual(@as(usize, 0), reload.references().len);
}

test "filesystem stage is atomic private and survives reload with owned root" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var journal = try cleanup.Journal.init(a, io, root);
    defer journal.deinit();
    @memset(root, 'x');
    try std.testing.expectEqual(@as(usize, 0), journal.references().len);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".vela", .{}));
    try journal.stage(first);
    const stat = try tmp.dir.statFile(io, ".vela/auth-cleanup.json", .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o7777);
    const original_root = try rootPath(&tmp);
    defer a.free(original_root);
    var reload = try cleanup.Journal.init(a, io, original_root);
    defer reload.deinit();
    try std.testing.expectEqual(first, reload.references()[0]);
    try journal.remove(first);
    var cleared = try cleanup.Journal.init(a, io, original_root);
    defer cleared.deinit();
    try std.testing.expectEqual(@as(usize, 0), cleared.references().len);
}

test "filesystem malformed insecure oversized files are never overwritten" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    try diskWrite(&tmp, "{}", 0o600);
    try std.testing.expectError(error.InvalidJournal, cleanup.Journal.init(a, io, root));
    try diskWrite(&tmp, empty, 0o644);
    try std.testing.expectError(error.InsecureJournal, cleanup.Journal.init(a, io, root));
    const oversized = try a.alloc(u8, cleanup.max_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, ' ');
    try diskWrite(&tmp, oversized, 0o600);
    try std.testing.expectError(error.JournalTooLarge, cleanup.Journal.init(a, io, root));
    try diskWrite(&tmp, empty, 0o600);
    var journal = try cleanup.Journal.init(a, io, root);
    defer journal.deinit();
    try diskWrite(&tmp, "{}", 0o600);
    try std.testing.expectError(error.InvalidJournal, journal.stage(first));
    const bytes = try tmp.dir.readFileAlloc(io, ".vela/auth-cleanup.json", a, .limited(cleanup.max_bytes));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("{}", bytes);
}

test "filesystem rejects root parent directory and file symlinks" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    try std.testing.expectError(error.InvalidRoot, cleanup.Journal.init(a, io, "relative"));
    const dotdot = try std.fmt.allocPrint(a, "{s}/../bad", .{root});
    defer a.free(dotdot);
    try std.testing.expectError(error.InvalidRoot, cleanup.Journal.init(a, io, dotdot));
    try tmp.dir.createDir(io, "target", .fromMode(0o700));
    try tmp.dir.symLink(io, "target", "link", .{ .is_directory = true });
    const linked_root = try std.fmt.allocPrint(a, "{s}/link", .{root});
    defer a.free(linked_root);
    try std.testing.expectError(error.InvalidRoot, cleanup.Journal.init(a, io, linked_root));
    const through_parent = try std.fmt.allocPrint(a, "{s}/link/child", .{root});
    defer a.free(through_parent);
    try std.testing.expectError(error.InvalidRoot, cleanup.Journal.init(a, io, through_parent));
    try tmp.dir.symLink(io, "target", ".vela", .{ .is_directory = true });
    try std.testing.expectError(error.InsecureJournal, cleanup.Journal.init(a, io, root));
    try tmp.dir.deleteFile(io, ".vela");
    try tmp.dir.createDir(io, ".vela", .fromMode(0o700));
    try tmp.dir.symLink(io, "../outside", ".vela/auth-cleanup.json", .{});
    try std.testing.expectError(error.InsecureJournal, cleanup.Journal.init(a, io, root));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "outside", .{}));
}

test "filesystem restage verifies journal and rejects changed or insecure state" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    try diskWrite(&tmp, one, 0o600);
    var journal = try cleanup.Journal.init(a, io, root);
    defer journal.deinit();
    try journal.stage(first);
    try std.testing.expectEqual(@as(usize, 1), journal.references().len);
    try diskWrite(&tmp, empty, 0o600);
    try std.testing.expectError(error.JournalChanged, journal.stage(first));
    try std.testing.expectError(error.JournalUncertain, journal.stage(second));
    var reload = try cleanup.Journal.init(a, io, root);
    defer reload.deinit();
    try diskWrite(&tmp, empty, 0o644);
    try std.testing.expectError(error.InsecureJournal, reload.stage(first));
}

test "filesystem rejects writable journal directory and substituted symlink after init" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    try tmp.dir.createDir(io, ".vela", .fromMode(0o700));
    const dir = try tmp.dir.openDir(io, ".vela", .{ .iterate = true });
    defer dir.close(io);
    try dir.setPermissions(io, .fromMode(0o777));
    try std.testing.expectError(error.InsecureJournal, cleanup.Journal.init(a, io, root));
    try dir.setPermissions(io, .fromMode(0o700));
    var journal = try cleanup.Journal.init(a, io, root);
    defer journal.deinit();
    try tmp.dir.symLink(io, "../outside", ".vela/auth-cleanup.json", .{});
    try std.testing.expectError(error.InsecureJournal, journal.stage(first));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "outside", .{}));
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| try std.testing.expectEqualStrings("auth-cleanup.json", entry.name);
}

test "filesystem rejects hardlinks and nonexistent roots without creating paths" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    const missing = try std.fmt.allocPrint(a, "{s}/missing", .{root});
    defer a.free(missing);
    try std.testing.expectError(error.InvalidRoot, cleanup.Journal.init(a, io, missing));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "missing", .{}));
    try diskWrite(&tmp, empty, 0o600);
    try std.Io.Dir.hardLink(tmp.dir, ".vela/auth-cleanup.json", tmp.dir, "alias", io, .{});
    try std.testing.expectError(error.InsecureJournal, cleanup.Journal.init(a, io, root));
}

/// Shared core-module owner fixture. No native filesystem, vault or network calls.
/// Fixture context is externally owned and stable; close ends only a Root lifetime.
pub const WindowsFake = struct {
    base_exists: bool = true,
    directory_exists: bool = true,
    directory_private: bool = true,
    file_private: bool = true,
    hardlink: bool = false,
    changed_root: bool = false,
    reparse: bool = false,
    unsupported: bool = false,
    privacy: @import("windows_durable_fs.zig").Privacy = .private_journal,
    failure: enum { none, ensure_uncertain, ensure_after, write, flush, move_before, move_after, final_flush } = .none,
    cancel_before: bool = false,
    cancel_after_move: bool = false,
    cancelled: bool = false,
    present: bool = false,
    disk: [8192]u8 = undefined,
    disk_len: usize = 0,
    staged: [8192]u8 = undefined,
    staged_len: usize = 0,
    temp_open: bool = false,
    temp_exists: bool = false,
    nonce: u64 = 0,
    temps: [32]TempRecord = @splat(.{}),
    current_temp: ?usize = null,
    discards: usize = 0,

    opens: usize = 0,
    closes: usize = 0,
    creates: usize = 0,
    ensures: usize = 0,
    moves: usize = 0,
    load_count: usize = 0,
    drift_at_load: usize = 0,
    drift_bytes: ?[]const u8 = null,
    disappear_at_load: usize = 0,
    fail_load_at: usize = 0,
    writer_in_use: bool = false,
    writer_owned: bool = false,
    writer_acquires: usize = 0,

    pub const TempRecord = struct {
        name: [64]u8 = undefined,
        name_len: usize = 0,
        identity: fs.Identity = .{ .volume = 17, .file = 101 },
        present: bool = false,
        private: bool = true,
        ambiguous: bool = false,

        pub fn nameBytes(self: *const TempRecord) []const u8 {
            return self.name[0..self.name_len];
        }
    };

    pub fn tempIndex(self: *const WindowsFake, name: []const u8) ?usize {
        for (&self.temps, 0..) |*temp, index| {
            if (temp.present and std.mem.eql(u8, temp.nameBytes(), name)) return index;
        }
        return null;
    }

    fn refreshTemps(self: *WindowsFake) void {
        self.temp_exists = false;
        for (&self.temps) |*temp| {
            if (temp.present) self.temp_exists = true;
        }
    }
    const fs = @import("windows_durable_fs.zig");
    const identity: fs.Identity = .{ .volume = 17, .file = 101 };
    fn cast(ctx: *anyopaque) *WindowsFake {
        return @ptrCast(@alignCast(ctx));
    }
    pub fn seed(self: *WindowsFake, bytes: []const u8) void {
        @memcpy(self.disk[0..bytes.len], bytes);
        self.disk_len = bytes.len;
        self.present = true;
    }
    pub fn diskBytes(self: *const WindowsFake) []const u8 {
        return self.disk[0..self.disk_len];
    }
    pub fn nativeOps(self: *WindowsFake) fs.NativeOps {
        return .{ .context = self, .open = open, .close = close, .acquire_writer = acquireWriter, .check_cancel = cancel, .validate_root = validate, .load = load, .ensure_directory = ensure, .random = random, .create_temp = create, .write = write, .flush = flush, .verify_temp = verifyTemp, .move = move, .verify_final = final, .close_file = closeFile, .discard_temp = discard };
    }
    pub fn reopen(ctx: *anyopaque, allocator: std.mem.Allocator, root: []const u8) fs.Error!fs.Root {
        return fs.openRootWithOps(allocator, root, .private_journal, cast(ctx).nativeOps());
    }
    fn open(ctx: *anyopaque, _: []const u8, privacy: fs.Privacy) fs.Error!void {
        const self = cast(ctx);
        if (self.unsupported) return error.UnsupportedDurability;
        self.privacy = privacy;
        try validate(ctx);
        self.opens += 1;
    }
    fn acquireWriter(ctx: *anyopaque) fs.Error!void {
        const self = cast(ctx);
        if (self.writer_in_use) return error.LauncherRootInUse;
        self.writer_owned = true;
        self.writer_acquires += 1;
    }
    fn close(ctx: *anyopaque) void {
        const self = cast(ctx);
        std.debug.assert(!self.temp_open);
        self.closes += 1;
        self.writer_owned = false;
    }
    fn cancel(ctx: *anyopaque) fs.Error!void {
        if (cast(ctx).cancel_before or cast(ctx).cancelled) return error.Cancelled;
    }
    fn validate(ctx: *anyopaque) fs.Error!void {
        const self = cast(ctx);
        if (!self.base_exists) return error.InvalidRoot;
        if (self.reparse) return error.InsecureJournal;
        if (self.changed_root) return error.JournalChanged;
        if (self.privacy == .private_journal and self.directory_exists and !self.directory_private) return error.InsecureJournal;
    }
    fn load(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, limit: usize, privacy: fs.Privacy) fs.Error!?fs.OwnedBytes {
        const self = cast(ctx);
        self.load_count += 1;
        if (self.fail_load_at != 0 and self.load_count == self.fail_load_at) return error.PersistenceFailure;
        if (self.drift_at_load != 0 and self.load_count == self.drift_at_load) self.seed(self.drift_bytes.?);
        if (self.disappear_at_load != 0 and self.load_count == self.disappear_at_load) self.present = false;
        if (!self.directory_exists or !self.present) return null;
        if (self.hardlink or (privacy == .private_journal and !self.file_private)) return error.InsecureJournal;
        if (self.disk_len > limit) return error.FileTooLarge;
        const bytes = try allocator.dupe(u8, self.diskBytes());
        return .{ .bytes = bytes, .allocation = bytes, .allocator = allocator };
    }
    fn ensure(ctx: *anyopaque) fs.Error!void {
        const self = cast(ctx);
        self.ensures += 1;
        if (self.failure == .ensure_uncertain) return error.CommitUncertain;
        if (!self.directory_exists) {
            self.directory_exists = true;
            self.directory_private = true;
        }
        if (self.failure == .ensure_after) return error.CommitUncertain;
    }
    fn random(ctx: *anyopaque, bytes: []u8) fs.Error!void {
        const self = cast(ctx);
        self.nonce += 1;
        @memset(bytes, 0);
        std.mem.writeInt(u64, bytes[0..8], self.nonce, .little);
    }
    fn create(ctx: *anyopaque, name: []const u8) fs.Error!fs.Temporary {
        const self = cast(ctx);
        if (self.tempIndex(name) != null) return error.TemporaryNameCollision;
        std.debug.assert(!self.temp_open and name.len <= 64);
        for (&self.temps, 0..) |*temp, index| {
            if (temp.present) continue;
            temp.* = .{ .name_len = name.len, .identity = .{ .volume = identity.volume, .file = identity.file + index }, .present = true };
            @memcpy(temp.name[0..name.len], name);
            self.current_temp = index;
            self.creates += 1;
            self.temp_open = true;
            self.refreshTemps();
            return .{ .handle = 19 + index, .identity = temp.identity };
        }
        return error.PersistenceFailure;
    }
    fn write(ctx: *anyopaque, _: usize, bytes: []const u8) fs.Error!void {
        const self = cast(ctx);
        if (self.failure == .write) return error.PersistenceFailure;
        @memcpy(self.staged[0..bytes.len], bytes);
        self.staged_len = bytes.len;
    }
    fn flush(ctx: *anyopaque, _: usize) fs.Error!void {
        if (cast(ctx).failure == .flush) return error.PersistenceFailure;
    }
    fn verifyTemp(ctx: *anyopaque, temporary: fs.Temporary, length: usize) fs.Error!void {
        const self = cast(ctx);
        const index = self.current_temp orelse return error.JournalChanged;
        const temp = &self.temps[index];
        if (!temp.present or !self.temp_open or temporary.handle != 19 + index or !std.meta.eql(temp.identity, temporary.identity) or length != self.staged_len) return error.JournalChanged;
        if (!temp.private) return error.InsecureJournal;
    }
    fn move(ctx: *anyopaque, name: []const u8, _: []const u8) fs.Error!void {
        const self = cast(ctx);
        const index = self.tempIndex(name) orelse unreachable;
        std.debug.assert(self.current_temp.? == index and self.temp_open);
        self.moves += 1;
        if (self.failure == .move_before) {
            self.temps[index].ambiguous = true;
            return error.PersistenceFailure;
        }
        self.seed(self.staged[0..self.staged_len]);
        self.temps[index].present = false;
        self.refreshTemps();
        if (self.cancel_after_move) self.cancelled = true;
        if (self.failure == .move_after) return error.PersistenceFailure;
    }
    fn final(ctx: *anyopaque, _: []const u8, _: fs.Identity, _: usize) fs.Error!void {
        if (cast(ctx).failure == .final_flush) return error.PersistenceFailure;
    }
    fn closeFile(ctx: *anyopaque, _: usize) void {
        cast(ctx).temp_open = false;
    }
    fn discard(ctx: *anyopaque, name: []const u8, expected: fs.Identity) void {
        const self = cast(ctx);
        const index = self.tempIndex(name) orelse unreachable;
        const temp = &self.temps[index];
        std.debug.assert(!temp.ambiguous and temp.private and std.meta.eql(temp.identity, expected));
        temp.present = false;
        self.discards += 1;
        self.refreshTemps();
    }
};

fn windowsJournal(allocator: std.mem.Allocator, fake: *WindowsFake) !cleanup.Journal {
    const fs = @import("windows_durable_fs.zig");
    var owned: ?fs.Root = try fs.openRootWithOps(allocator, "C:/owned/launcher", .private_journal, fake.nativeOps());
    return cleanup.Journal.initWithOwnedRoot(allocator, io, &owned);
}

test "Windows auth owner checks disk twice and keeps snapshot poisoned after staging failures" {
    const staged_reference: credentials.Reference = @splat('0');
    const next_reference: credentials.Reference = @splat('1');
    for (0..4) |which| {
        var fake: WindowsFake = .{};
        var debt = try windowsJournal(a, &fake);
        defer debt.deinit();
        try debt.stage(staged_reference);
        const prior = debt.references().ptr;
        if (which == 0) fake.failure = .write;
        if (which == 1) fake.failure = .move_after;
        if (which == 2) {
            fake.drift_at_load = fake.load_count + 2;
            fake.drift_bytes = empty;
        }
        if (which == 3) fake.cancel_before = true;
        try std.testing.expectError(if (which == 1) error.CommitUncertain else if (which == 2) error.JournalChanged else error.PersistenceFailure, debt.stage(next_reference));
        try std.testing.expectEqual(prior, debt.references().ptr);
        try std.testing.expect(debt.references().len == 1 and !fake.temp_open);
        try std.testing.expectError(error.JournalUncertain, debt.stage(next_reference));
        try std.testing.expectError(error.JournalUncertain, debt.remove(staged_reference));
    }
}

test "Windows auth ambiguous removal retains debt and explicit reload restages protected reference" {
    const staged_reference: credentials.Reference = @splat('0');
    var fake: WindowsFake = .{};
    var debt = try windowsJournal(a, &fake);
    try debt.stage(staged_reference);
    fake.failure = .move_after;
    try std.testing.expectError(error.CommitUncertain, debt.remove(staged_reference));
    try std.testing.expectEqual(@as(usize, 1), debt.references().len);
    debt.deinit();
    fake.failure = .none;
    var loaded = try windowsJournal(a, &fake);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.references().len);
    try loaded.stage(staged_reference);
    try std.testing.expectEqual(@as(usize, 1), loaded.references().len);
    try std.testing.expect(std.mem.indexOf(u8, fake.diskBytes(), "references") != null);
}

test "Windows auth init consumes root on parser security size and load failures" {
    const fs = @import("windows_durable_fs.zig");
    for (0..4) |which| {
        var fake: WindowsFake = .{};
        fake.seed(if (which == 0) "{}" else empty);
        if (which == 1) fake.file_private = false;
        if (which == 2) fake.disk_len = cleanup.max_bytes + 1;
        if (which == 3) fake.fail_load_at = 1;
        var owned: ?fs.Root = try fs.openRootWithOps(a, "C:/owned/launcher", .private_journal, fake.nativeOps());
        try std.testing.expectError(if (which == 0) error.InvalidJournal else if (which == 1) error.InsecureJournal else if (which == 2) error.JournalTooLarge else error.PersistenceFailure, cleanup.Journal.initWithOwnedRoot(a, io, &owned));
        try std.testing.expect(owned == null and fake.closes == 1 and fake.creates == 0);
    }
}

fn windowsAuthAllocationScenario(allocator: std.mem.Allocator) !void {
    var fake: WindowsFake = .{};
    var debt = try windowsJournal(allocator, &fake);
    defer debt.deinit();
    try debt.stage(@splat('0'));
    try debt.remove(@splat('0'));
}
test "Windows auth owner allocation failures release staged refs bytes and root" {
    try @import("test_allocations").checkAllAllocationFailures(a, windowsAuthAllocationScenario, .{});
}

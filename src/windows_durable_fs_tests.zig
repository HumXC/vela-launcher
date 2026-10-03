//! Hermetic protocol checks only: no native Windows APIs, filesystem or vault.
//! These test the injectable adapter contract, not physical NTFS durability/DACLs.
const std = @import("std");
const fs = @import("core/windows_durable_fs.zig");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const one = "{\"schemaVersion\":1,\"references\":[\"0123456789abcdef0123456789abcdef\"]}";
const empty = "{\"schemaVersion\":1,\"references\":[]}";

const Event = enum { open, validate, load, ensure, random, create, write, flush, verify_temp, check, move, final, close_file, discard, close };
const Failure = enum { none, ensure_uncertain, ensure_after, write, flush, move_before, move_after, final_identity, final_security, final_flush };
pub const Fake = struct {
    events: [1024]Event = undefined,
    base_exists: bool = true,
    event_count: usize = 0,
    directory_exists: bool = true,
    directory_private: bool = true,
    reparse: bool = false,
    wrong_type: bool = false,
    hardlink: bool = false,
    changed_root: bool = false,
    file_private: bool = true,
    unsupported: bool = false,
    failure: Failure = .none,
    cancel_before: bool = false,
    cancel_after_move: bool = false,
    cancelled: bool = false,
    checks: usize = 0,
    fail_check_at: usize = 0,
    moves: usize = 0,
    closes: usize = 0,
    discards: usize = 0,
    temp_open: bool = false,
    temp_exists: bool = false,
    present: bool = false,
    disk: [8192]u8 = undefined,
    disk_len: usize = 0,
    staged: [8192]u8 = undefined,
    staged_len: usize = 0,
    privacy: fs.Privacy = .private_journal,
    load_count: usize = 0,
    drift_at_load: usize = 0,
    drift_bytes: ?[]const u8 = null,
    disappear_at_load: usize = 0,
    fail_load_at: usize = 0,
    const id: fs.Identity = .{ .volume = 17, .file = 101 };
    fn cast(ctx: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ctx));
    }
    fn event(self: *Fake, value: Event) void {
        std.debug.assert(self.event_count < self.events.len);
        self.events[self.event_count] = value;
        self.event_count += 1;
    }
    pub fn saw(self: *const Fake, value: Event) bool {
        return std.mem.indexOfScalar(Event, self.events[0..self.event_count], value) != null;
    }
    pub fn seed(self: *Fake, bytes: []const u8) void {
        @memcpy(self.disk[0..bytes.len], bytes);
        self.disk_len = bytes.len;
        self.present = true;
    }
    pub fn diskBytes(self: *const Fake) []const u8 {
        return self.disk[0..self.disk_len];
    }
    pub fn nativeOps(self: *Fake) fs.NativeOps {
        return self.ops();
    }

    fn ops(self: *Fake) fs.NativeOps {
        return .{ .context = self, .open = open, .close = close, .check_cancel = checkCancel, .validate_root = validate, .load = load, .ensure_directory = ensure, .random = random, .create_temp = create, .write = write, .flush = flush, .verify_temp = verifyTemp, .move = move, .verify_final = final, .close_file = closeFile, .discard_temp = discard };
    }
    /// Separately owned fixture context survives capability close, unlike native
    /// Windows context. Every call opens a new Root through the complete ops seam.
    pub fn reopen(ctx: *anyopaque, a: Allocator, root: []const u8) fs.Error!fs.Root {
        return fs.openRootWithOps(a, root, .private_journal, cast(ctx).ops());
    }
    fn open(ctx: *anyopaque, _: []const u8, privacy: fs.Privacy) fs.Error!void {
        const self = cast(ctx);
        self.event(.open);
        if (self.unsupported) return error.UnsupportedDurability;
        self.privacy = privacy;
        try validate(ctx);
        if (privacy == .private_journal and self.directory_exists and !self.directory_private) return error.InsecureJournal;
    }
    fn close(ctx: *anyopaque) void {
        const self = cast(ctx);
        std.debug.assert(!self.temp_open);
        self.event(.close);
        self.closes += 1;
    }
    fn checkCancel(ctx: *anyopaque) fs.Error!void {
        const self = cast(ctx);
        if (self.cancel_before or self.cancelled) return error.Cancelled;
    }
    fn validate(ctx: *anyopaque) fs.Error!void {
        const self = cast(ctx);
        self.event(.validate);
        if (!self.base_exists) return error.InvalidRoot;
        if (self.reparse or self.wrong_type) return error.InsecureJournal;
        if (self.changed_root) return error.JournalChanged;
        if (self.privacy == .private_journal and self.directory_exists and !self.directory_private) return error.InsecureJournal;
    }
    fn load(ctx: *anyopaque, a: Allocator, _: []const u8, limit: usize, privacy: fs.Privacy) fs.Error!?fs.OwnedBytes {
        const self = cast(ctx);
        self.event(.load);
        self.load_count += 1;
        if (self.fail_load_at != 0 and self.load_count == self.fail_load_at) return error.PersistenceFailure;
        if (self.drift_at_load != 0 and self.load_count == self.drift_at_load) self.seed(self.drift_bytes.?);
        if (self.disappear_at_load != 0 and self.load_count == self.disappear_at_load) self.present = false;
        if (!self.directory_exists or !self.present) return null;
        if (self.hardlink or self.wrong_type or self.reparse or (privacy == .private_journal and !self.file_private)) return error.InsecureJournal;
        if (self.disk_len > limit) return error.FileTooLarge;
        const bytes = try a.dupe(u8, self.diskBytes());
        return .{ .bytes = bytes, .allocation = bytes, .allocator = a };
    }
    fn ensure(ctx: *anyopaque) fs.Error!void {
        const self = cast(ctx);
        self.event(.ensure);
        if (self.failure == .ensure_uncertain) return error.CommitUncertain;
        if (!self.directory_exists) {
            self.directory_exists = true;
            self.directory_private = true;
        }
        if (self.failure == .ensure_after) return error.CommitUncertain;
    }
    fn random(ctx: *anyopaque, bytes: []u8) fs.Error!void {
        cast(ctx).event(.random);
        @memset(bytes, 0x42);
    }
    fn create(ctx: *anyopaque, _: []const u8) fs.Error!fs.Temporary {
        const self = cast(ctx);
        self.event(.create);
        std.debug.assert(!self.temp_open);
        self.temp_open = true;
        self.temp_exists = true;
        self.staged_len = 0;
        return .{ .handle = 19, .identity = id };
    }
    fn write(ctx: *anyopaque, handle: usize, bytes: []const u8) fs.Error!void {
        const self = cast(ctx);
        self.event(.write);
        std.debug.assert(handle == 19 and self.temp_open);
        if (self.failure == .write) return error.PersistenceFailure;
        if (bytes.len > self.staged.len) return error.PersistenceFailure;
        @memcpy(self.staged[0..bytes.len], bytes);
        self.staged_len = bytes.len;
    }
    fn flush(ctx: *anyopaque, handle: usize) fs.Error!void {
        const self = cast(ctx);
        self.event(.flush);
        std.debug.assert(handle == 19 and self.temp_open);
        if (self.failure == .flush) return error.PersistenceFailure;
    }
    fn verifyTemp(ctx: *anyopaque, temp: fs.Temporary, length: usize) fs.Error!void {
        const self = cast(ctx);
        self.event(.verify_temp);
        if (!fs.Identity.eql(temp.identity, id) or self.staged_len != length) return error.JournalChanged;
    }
    fn move(ctx: *anyopaque, _: []const u8, _: []const u8) fs.Error!void {
        const self = cast(ctx);
        self.event(.move);
        self.moves += 1;
        if (self.failure == .move_before) return error.PersistenceFailure;
        self.seed(self.staged[0..self.staged_len]);
        self.temp_exists = false;
        if (self.cancel_after_move) self.cancelled = true;
        if (self.failure == .move_after) return error.PersistenceFailure;
    }
    fn final(ctx: *anyopaque, _: []const u8, identity: fs.Identity, length: usize) fs.Error!void {
        const self = cast(ctx);
        self.event(.final);
        if (!fs.Identity.eql(identity, id) or self.disk_len != length or self.failure == .final_identity) return error.JournalChanged;
        if (self.failure == .final_security) return error.InsecureJournal;
        if (self.failure == .final_flush) return error.PersistenceFailure;
    }
    fn closeFile(ctx: *anyopaque, handle: usize) void {
        const self = cast(ctx);
        self.event(.close_file);
        std.debug.assert(handle == 19 and self.temp_open);
        self.temp_open = false;
    }
    fn discard(ctx: *anyopaque, _: []const u8, identity: fs.Identity) void {
        const self = cast(ctx);
        self.event(.discard);
        std.debug.assert(!self.temp_open and fs.Identity.eql(identity, id));
        self.discards += 1;
        self.temp_exists = false;
    }
    fn check(ctx: ?*anyopaque, _: *fs.Root) anyerror!void {
        const self = cast(ctx.?);
        self.event(.check);
        self.checks += 1;
        if (self.fail_check_at == self.checks) return error.JournalChanged;
    }
    fn precommit(self: *Fake) fs.PrecommitCheck {
        return .{ .context = self, .run = check };
    }
};

fn journalRoot(a: Allocator, fake: *Fake) fs.Error!fs.Root {
    return fs.openRootWithOps(a, "C:/owned/launcher", .private_journal, fake.ops());
}

test "native absolute drive and UNC syntax normalizes without POSIX interpretation" {
    for ([_]struct { input: []const u8, want: []const u8 }{
        .{ .input = "c:/owned//launcher/./", .want = "C:\\owned\\launcher" },
        .{ .input = "C:/", .want = "C:\\" },
        .{ .input = "//server/share/owned/", .want = "\\\\server\\share\\owned" },
    }) |case| {
        const value = try fs.normalizeRoot(testing.allocator, case.input);
        defer testing.allocator.free(value);
        try testing.expectEqualStrings(case.want, value);
    }
    for ([_][]const u8{ "", "/owned", "C:relative", "C:/../other", "//server", "\\\\?\\C:\\owned", "\\\\.\\C:\\owned", "C:/NUL", "C:/con.txt", "C:/COM1", "C:/file:stream", "C:/dot.", "C:/space ", "C:/x\x00y" }) |path| {
        try testing.expectError(error.InvalidRoot, fs.normalizeRoot(testing.allocator, path));
    }
}

test "unsupported capability and insecure root stop before any publication" {
    for (0..4) |which| {
        var fake: Fake = .{};
        switch (which) {
            0 => fake.unsupported = true,
            1 => fake.reparse = true,
            2 => fake.wrong_type = true,
            3 => fake.directory_private = false,
            else => unreachable,
        }
        const expected: fs.Error = if (which == 0) error.UnsupportedDurability else error.InsecureJournal;
        try testing.expectError(expected, journalRoot(testing.allocator, &fake));
        try testing.expect(!fake.saw(.create) and fake.moves == 0);
    }
}

test "ordinary config permits ordinary existing DACL while private journals reject it" {
    var fake: Fake = .{ .directory_private = false, .file_private = false };
    fake.seed("{}");
    var root = try fs.openRootWithOps(testing.allocator, "C:/owned", .ordinary_config, fake.ops());
    defer fs.deinit(&root);
    var bytes = (try fs.load(&root, testing.allocator, "config.json", fs.config_limit)).?;
    defer bytes.deinit();
    try testing.expectEqualStrings("{}", bytes.bytes);
    try testing.expectError(error.InvalidLeaf, fs.load(&root, testing.allocator, "auth-cleanup.json", fs.journal_limit));
}

test "missing storage load is empty and creates nothing; fixed leaves and bounds are enforced" {
    var fake: Fake = .{ .directory_exists = false };
    var root = try journalRoot(testing.allocator, &fake);
    defer fs.deinit(&root);
    try testing.expect((try fs.load(&root, testing.allocator, "auth-cleanup.json", fs.journal_limit)) == null);
    try testing.expect(!fake.saw(.ensure) and !fake.saw(.create));
    for ([_][]const u8{ "../auth-cleanup.json", "config.json", "unknown.json", "auth-cleanup.json:stream" }) |leaf| {
        try testing.expectError(error.InvalidLeaf, fs.publish(&root, leaf, empty, .none));
    }
    try testing.expectError(error.FileTooLarge, fs.load(&root, testing.allocator, "auth-cleanup.json", fs.journal_limit + 1));
    const too_large = try testing.allocator.alloc(u8, fs.journal_limit + 1);
    defer testing.allocator.free(too_large);
    try testing.expectError(error.FileTooLarge, fs.publish(&root, "auth-cleanup.json", too_large, .none));
    try testing.expect(!fake.saw(.ensure) and !fake.saw(.create));
}

test "load rejects hardlinks private file DACL and changed root identity" {
    for (0..3) |which| {
        var fake: Fake = .{};
        fake.seed(one);
        var root = try journalRoot(testing.allocator, &fake);
        defer fs.deinit(&root);
        switch (which) {
            0 => fake.hardlink = true,
            1 => fake.file_private = false,
            2 => fake.changed_root = true,
            else => unreachable,
        }
        const expected: fs.Error = if (which == 2) error.JournalChanged else error.InsecureJournal;
        try testing.expectError(expected, fs.load(&root, testing.allocator, "auth-cleanup.json", fs.journal_limit));
        try testing.expect(fake.moves == 0);
    }
}

test "successful publication keeps reference bytes and checks current state twice" {
    var fake: Fake = .{};
    var root = try journalRoot(testing.allocator, &fake);
    defer fs.deinit(&root);
    try fs.publish(&root, "auth-cleanup.json", one, fake.precommit());
    try testing.expectEqualStrings(one, fake.diskBytes());
    try testing.expectEqual(@as(usize, 2), fake.checks);
    try testing.expectEqual(@as(usize, 1), fake.moves);
    try testing.expect(fake.saw(.flush) and fake.saw(.verify_temp) and fake.saw(.final));
    try testing.expect(!root.publicationUncertain() and !fake.temp_open and fake.discards == 0);
}

test "prepublication write flush or changed-document failure leaves authoritative bytes intact" {
    for (0..3) |which| {
        var fake: Fake = .{};
        fake.seed(one);
        var root = try journalRoot(testing.allocator, &fake);
        defer fs.deinit(&root);
        switch (which) {
            0 => fake.failure = .write,
            1 => fake.failure = .flush,
            2 => fake.fail_check_at = 2,
            else => unreachable,
        }
        const expected: fs.Error = if (which == 2) error.JournalChanged else error.PersistenceFailure;
        try testing.expectError(expected, fs.publish(&root, "auth-cleanup.json", empty, fake.precommit()));
        try testing.expectEqualStrings(one, fake.diskBytes());
        try testing.expect(fake.moves == 0 and fake.discards == 1 and !fake.temp_open and !root.publicationUncertain());
    }
}

test "every possible-move failure blocks automatic retry and never deletes by the moved handle" {
    for ([_]Failure{ .move_before, .move_after, .final_identity, .final_security, .final_flush }) |failure| {
        var fake: Fake = .{};
        fake.seed(one);
        var root = try journalRoot(testing.allocator, &fake);
        defer fs.deinit(&root);
        fake.failure = failure;
        try testing.expectError(error.CommitUncertain, fs.publish(&root, "auth-cleanup.json", empty, fake.precommit()));
        try testing.expect(root.publicationUncertain() and !fake.temp_open and fake.discards == 0);
        const events_before = fake.event_count;
        try testing.expectError(error.CommitUncertain, fs.publish(&root, "auth-cleanup.json", one, .none));
        try testing.expectEqual(events_before, fake.event_count);
        try testing.expectEqualStrings(if (failure == .move_before) one else empty, fake.diskBytes());
    }
}

test "ambiguous removal rereads authoritative empty references and failed reconcile retains barrier" {
    var fake: Fake = .{};
    fake.seed(one);
    var root = try journalRoot(testing.allocator, &fake);
    defer fs.deinit(&root);
    fake.failure = .move_after;
    try testing.expectError(error.CommitUncertain, fs.publish(&root, "auth-cleanup.json", empty, fake.precommit()));
    var authoritative = (try fs.load(&root, testing.allocator, "auth-cleanup.json", fs.journal_limit)).?;
    defer authoritative.deinit();
    try testing.expectEqualStrings(empty, authoritative.bytes);
    const moves_before_draft = fake.moves;
    try testing.expectError(error.JournalChanged, fs.reconcile(&root, "auth-cleanup.json", one, fake.precommit()));
    try testing.expect(root.publicationUncertain());
    try testing.expectEqual(moves_before_draft, fake.moves);
    fake.failure = .flush;
    try testing.expectError(error.PersistenceFailure, fs.reconcile(&root, "auth-cleanup.json", authoritative.bytes, fake.precommit()));
    try testing.expect(root.publicationUncertain());
    fake.failure = .none;
    try fs.reconcile(&root, "auth-cleanup.json", authoritative.bytes, fake.precommit());
    try testing.expect(!root.publicationUncertain());
    try testing.expectEqualStrings(empty, fake.diskBytes());
}

test "uncertain directory publication also blocks retry" {
    var fake: Fake = .{ .directory_exists = false, .failure = .ensure_uncertain };
    var root = try journalRoot(testing.allocator, &fake);
    defer fs.deinit(&root);
    try testing.expectError(error.CommitUncertain, fs.publish(&root, "auth-cleanup.json", one, fake.precommit()));
    try testing.expect(root.publicationUncertain() and !fake.saw(.create));
}

test "cancellation before move is clean; cancellation after move is uncertain" {
    var before: Fake = .{};
    var root_before = try journalRoot(testing.allocator, &before);
    defer fs.deinit(&root_before);
    before.cancel_before = true;
    try testing.expectError(error.Cancelled, fs.publish(&root_before, "auth-cleanup.json", one, .none));
    try testing.expect(!root_before.publicationUncertain() and before.moves == 0 and !before.saw(.create));
    var after: Fake = .{ .cancel_after_move = true };
    var root_after = try journalRoot(testing.allocator, &after);
    defer fs.deinit(&root_after);
    try testing.expectError(error.CommitUncertain, fs.publish(&root_after, "auth-cleanup.json", one, .none));
    try testing.expect(root_after.publicationUncertain() and after.saw(.final) and after.discards == 0 and !after.temp_open);
}

fn allocationScenario(a: Allocator) !void {
    var fake: Fake = .{};
    fake.seed(one);
    var root = try journalRoot(a, &fake);
    defer fs.deinit(&root);
    var owned = (try fs.load(&root, a, "auth-cleanup.json", fs.journal_limit)).?;
    defer owned.deinit();
    try fs.publish(&root, "auth-cleanup.json", owned.bytes, fake.precommit());
}
test "injected allocation failure releases owned normalization and loaded bytes" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationScenario, .{});
}

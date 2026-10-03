//! Single-owner, worker-only journal of NONSECRET CurseForge credential references.
//! Stage must complete durably before put/delete. No native vault calls occur here.
//! Resolve requires an explicit authoritative config read AND confirmed durable
//! publication, never a stale submitted draft. Cleanup must also protect the latest
//! active config reference. Forget is allowed only after confirmed delete/NotFound.
const std = @import("std");
const windows_fs = @import("windows_durable_fs.zig");
const builtin = @import("builtin");
const credentials = @import("credentials.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
pub const Reference = credentials.Reference;
pub const max_bytes = 64 * 1024;
pub const max_references = 256;
const filename = "curseforge-credentials.json";
pub const Error = error{
    OutOfMemory,
    InvalidRoot,
    InvalidJournal,
    UnsupportedSchemaVersion,
    TooManyReferences,
    InvalidReference,
    DuplicateReference,
    InvalidPending,
    PendingUnresolved,
    JournalTooLarge,
    InsecureJournal,
    PersistenceFailure,
    CommitUncertain,
    JournalUncertain,
    JournalChanged,
    UnsupportedDurability,
};
pub const Action = enum { set, remove };
pub const Pending = struct {
    action: Action,
    old_ref: ?Reference = null,
    new_ref: ?Reference = null,
};
pub const Document = struct {
    schema_version: u32 = 1,
    pending: ?Pending = null,
    cleanup: []const Reference = &.{},

    fn deinit(self: *Document, a: Allocator) void {
        a.free(self.cleanup);
        self.* = .{};
    }
};

/// A fixture factory returns a NEW owned capability. Its context is separately
/// owned, stays stable across root closes, and is never a retained NativeOps context.
pub const Reopener = struct {
    context: *anyopaque,
    open: *const fn (*anyopaque, Allocator, []const u8) windows_fs.Error!windows_fs.Root,
};

pub const Journal = struct {
    a: Allocator,
    io: Io,
    root: []const u8,
    windows_root: ?windows_fs.Root = null,
    reopener: ?Reopener = null,
    document: Document = .{},
    exists: bool = false,
    uncertain: bool = false,
    baseline_retry: enum { initial, retry, forbidden } = .initial,

    /// Missing journal is initially empty; init never creates or rewrites files.
    /// Windows holds a private native capability; WASI stays unsupported.
    pub fn init(a: Allocator, io: Io, root: []const u8) Error!Journal {
        try supported();
        if (builtin.os.tag == .windows) {
            var owned: ?windows_fs.Root = windows_fs.openRoot(a, io, root, .private_journal) catch |err| return windowsError(err);
            return initOwnedRoot(a, io, &owned, null);
        }
        try validateRoot(root);
        var self: Journal = .{ .a = a, .io = io, .root = try a.dupe(u8, root) };
        errdefer self.deinit();
        const base = openRoot(io, root) catch return error.InvalidRoot;
        defer base.close(io);
        const dir = openJournalDir(base, io) catch |err| switch (err) {
            error.FileNotFound => return self,
            else => return error.InsecureJournal,
        };
        defer dir.close(io);
        if (try load(a, io, dir)) |loaded| {
            a.free(loaded.bytes);
            self.document = loaded.document;
            self.exists = true;
            self.baseline_retry = .forbidden;
        }
        return self;
    }

    /// Explicit hermetic native-ops seam. Contexts must remain stable until deinit.
    /// Reopener owns no root and must return fresh capabilities, never old ops aliases.
    pub fn initWithNativeOps(a: Allocator, io: Io, root: []const u8, ops: windows_fs.NativeOps, reopener: Reopener) Error!Journal {
        var owned: ?windows_fs.Root = windows_fs.openRootWithOps(a, root, .private_journal, ops) catch |err| return windowsError(err);
        return initOwnedRoot(a, io, &owned, reopener);
    }

    fn initOwnedRoot(a: Allocator, io: Io, owned: *?windows_fs.Root, reopener: ?Reopener) Error!Journal {
        var capability = owned.* orelse return error.InvalidRoot;
        owned.* = null;
        errdefer windows_fs.deinit(&capability);
        if (capability.privacy != .private_journal) return error.InsecureJournal;
        const root = try a.dupe(u8, capability.normalized);
        errdefer a.free(root);
        var loaded = windows_fs.load(&capability, a, filename, max_bytes) catch |err| return windowsError(err);
        defer if (loaded) |*bytes| bytes.deinit();
        return .{ .a = a, .io = io, .root = root, .windows_root = capability, .reopener = reopener, .document = if (loaded) |bytes| try parse(a, bytes.bytes) else .{}, .exists = loaded != null, .uncertain = capability.publication_uncertain, .baseline_retry = if (loaded != null) .forbidden else .initial };
    }

    pub fn deinit(self: *Journal) void {
        self.document.deinit(self.a);
        if (self.windows_root) |*root| windows_fs.deinit(root);
        self.a.free(self.root);
        self.* = undefined;
    }

    /// Borrowed until successful mutation/reload or deinit. Errors retain ownership.
    pub fn snapshot(self: *const Journal) *const Document {
        return &self.document;
    }

    pub fn poisoned(self: *const Journal) bool {
        return self.uncertain;
    }

    /// Explicit pre-stage empty baseline. Init remains read-only; no vault lives here.
    /// Only a failed baseline may retry absence; an appeared file requires strict reload.
    pub fn ensureBaseline(self: *Journal) Error!void {
        if (self.exists) {
            try self.ready();
            return;
        }
        if (self.baseline_retry == .forbidden) return error.JournalChanged;
        if (self.uncertain and self.baseline_retry != .retry) return error.JournalUncertain;
        if (self.document.pending != null or self.document.cleanup.len != 0) return error.JournalChanged;
        try supported();
        if (self.windows_root != null and self.uncertain) try self.freshAbsentBaseline();
        self.baseline_retry = .retry;
        const bytes = try serialize(self.a, .{});
        defer self.a.free(bytes);
        self.save(bytes, null) catch |err| {
            self.uncertain = true;
            return err;
        };
        self.exists = true;
        self.uncertain = false;
        self.baseline_retry = .forbidden;
    }

    /// Fresh new reference plus old active reference are staged in ONE durable write.
    pub fn stageSet(self: *Journal, old: ?Reference, new: Reference) Error!void {
        try self.ready();
        try validRef(new);
        if (old) |ref| {
            try validRef(ref);
            if (equal(ref, new)) return error.InvalidPending;
        }
        if (self.document.pending != null) return error.PendingUnresolved;
        if (contains(self.document.cleanup, new)) return error.InvalidPending;
        try self.stage(.{ .action = .set, .old_ref = old, .new_ref = new });
    }

    pub fn stageRemove(self: *Journal, old: Reference) Error!void {
        try self.ready();
        try validRef(old);
        if (self.document.pending != null) return error.PendingUnresolved;
        try self.stage(.{ .action = .remove, .old_ref = old });
    }

    fn stage(self: *Journal, pending: Pending) Error!void {
        var refs: std.ArrayList(Reference) = .empty;
        defer refs.deinit(self.a);
        try refs.appendSlice(self.a, self.document.cleanup);
        if (pending.old_ref) |ref| try add(self.a, &refs, ref);
        if (pending.new_ref) |ref| try add(self.a, &refs, ref);
        const next: Document = .{ .pending = pending, .cleanup = refs.items };
        try self.commit(next);
    }

    /// Caller has reconciled authoritative config and confirmed durable publication.
    /// Clears pending and removes ONLY protected; all other debt remains regardless
    /// of whether a native write was confirmed or commit-ambiguous.
    pub fn resolve(self: *Journal, protected: ?Reference) Error!void {
        try self.ready();
        if (protected) |ref| try validRef(ref);
        var refs: std.ArrayList(Reference) = .empty;
        defer refs.deinit(self.a);
        for (self.document.cleanup) |ref| {
            if (protected) |active| if (equal(ref, active)) continue;
            try refs.append(self.a, ref);
        }
        // Even without pending, confirm this explicit acknowledgement durably.
        try self.commit(.{ .cleanup = refs.items });
    }

    /// Call only after confirmed native delete/NotFound; never while pending.
    pub fn forget(self: *Journal, ref: Reference) Error!void {
        try self.ready();
        try validRef(ref);
        if (self.document.pending != null) return error.PendingUnresolved;
        if (!contains(self.document.cleanup, ref)) return;
        var refs: std.ArrayList(Reference) = .empty;
        defer refs.deinit(self.a);
        for (self.document.cleanup) |old| {
            if (!equal(old, ref)) try refs.append(self.a, old);
        }
        try self.commit(.{ .cleanup = refs.items });
    }

    /// Explicit recovery: existing validated disk bytes are durably republished
    /// before memory changes or the poison barrier clears. Missing is NOT empty.
    pub fn reload(self: *Journal) Error!void {
        self.uncertain = true;
        try supported();
        if (self.windows_root) |*root| {
            root.publication_uncertain = true;
            var loaded = (windows_fs.load(root, self.a, filename, max_bytes) catch |err| return windowsError(err)) orelse return error.JournalChanged;
            defer loaded.deinit();
            var next = try parse(self.a, loaded.bytes);
            errdefer next.deinit(self.a);
            var validation: WindowsCheck = .{ .a = self.a, .expected = &next };
            windows_fs.reconcile(root, filename, loaded.bytes, .{ .context = &validation, .run = WindowsCheck.run }) catch |err| return windowsError(err);
            self.document.deinit(self.a);
            self.document = next;
            self.exists = true;
            self.baseline_retry = .forbidden;
            self.uncertain = false;
            return;
        }
        if (builtin.os.tag == .windows) return error.UnsupportedDurability;
        const base = openRoot(self.io, self.root) catch return error.InvalidRoot;
        defer base.close(self.io);
        const dir = openJournalDir(base, self.io) catch return error.InsecureJournal;
        defer dir.close(self.io);
        var loaded = (try load(self.a, self.io, dir)) orelse return error.JournalChanged;
        defer loaded.deinit(self.a);
        try self.save(loaded.bytes, &loaded.document);
        self.document.deinit(self.a);
        self.document = loaded.document;
        loaded.document = .{};
        self.exists = true;
        self.baseline_retry = .forbidden;
        self.uncertain = false;
    }

    fn ready(self: *const Journal) Error!void {
        if (self.uncertain) return error.JournalUncertain;
        try supported();
    }

    fn commit(self: *Journal, next: Document) Error!void {
        self.baseline_retry = .forbidden;
        // Preparation failures leave the previous snapshot and barrier unchanged.
        var owned = try clone(self.a, next);
        errdefer owned.deinit(self.a);
        const bytes = try serialize(self.a, owned);
        defer self.a.free(bytes);
        const expected: ?*const Document = if (self.exists) &self.document else null;
        self.save(bytes, expected) catch |err| {
            self.uncertain = true;
            return err;
        };
        self.document.deinit(self.a);
        self.document = owned;
        self.exists = true;
    }

    fn save(self: *Journal, bytes: []const u8, expected: ?*const Document) Error!void {
        try supported();
        if (self.windows_root) |*root| {
            var validation: WindowsCheck = .{ .a = self.a, .expected = expected };
            windows_fs.publish(root, filename, bytes, .{ .context = &validation, .run = WindowsCheck.run }) catch |err| return windowsError(err);
            return;
        }
        if (builtin.os.tag == .windows) return error.UnsupportedDurability;
        const base = openRoot(self.io, self.root) catch return error.InvalidRoot;
        defer base.close(self.io);
        const dir = openJournalDir(base, self.io) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (expected != null) return error.JournalChanged;
                base.createDir(self.io, ".vela", .fromMode(0o700)) catch return error.PersistenceFailure;
                syncDir(base, self.io) catch return error.CommitUncertain;
                break :blk openJournalDir(base, self.io) catch return error.InsecureJournal;
            },
            else => return error.InsecureJournal,
        };
        defer dir.close(self.io);
        try self.checkCurrent(dir, expected);
        syncDir(base, self.io) catch return error.CommitUncertain;
        var random: [16]u8 = undefined;
        Io.randomSecure(self.io, &random) catch return error.PersistenceFailure;
        var buffer: [96]u8 = undefined;
        const temp = std.fmt.bufPrint(&buffer, ".curseforge-credentials-{s}.tmp", .{std.fmt.bytesToHex(random, .lower)}) catch unreachable;
        const file = dir.createFile(self.io, temp, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch return error.PersistenceFailure;
        defer file.close(self.io);
        var renamed = false;
        defer if (!renamed) dir.deleteFile(self.io, temp) catch {};
        file.setPermissions(self.io, .fromMode(0o600)) catch return error.PersistenceFailure;
        file.writeStreamingAll(self.io, bytes) catch return error.PersistenceFailure;
        file.sync(self.io) catch return error.PersistenceFailure;
        try self.checkCurrent(dir, expected);
        Dir.rename(dir, temp, dir, filename, self.io) catch return error.CommitUncertain;
        renamed = true;
        syncDir(dir, self.io) catch return error.CommitUncertain;
    }

    /// Only a failed first baseline may retry proven absence through a fresh root.
    /// An established journal or appeared document can never use this recovery.
    fn freshAbsentBaseline(self: *Journal) Error!void {
        if (self.exists or self.baseline_retry != .retry or self.document.pending != null or self.document.cleanup.len != 0) return error.JournalChanged;
        const held = if (self.windows_root) |*root| root else return error.InvalidRoot;
        var previous_disk = windows_fs.load(held, self.a, filename, max_bytes) catch |err| return windowsError(err);
        defer if (previous_disk) |*bytes| bytes.deinit();
        if (previous_disk) |bytes| {
            self.baseline_retry = .forbidden;
            var document = try parse(self.a, bytes.bytes);
            defer document.deinit(self.a);
            return error.JournalChanged;
        }
        var fresh = if (self.reopener) |factory|
            factory.open(factory.context, self.a, self.root) catch |err| return windowsError(err)
        else
            windows_fs.openRoot(self.a, self.io, self.root, .private_journal) catch |err| return windowsError(err);
        errdefer windows_fs.deinit(&fresh);
        if (fresh.privacy != .private_journal or fresh.publication_uncertain or !std.mem.eql(u8, fresh.normalized, self.root)) return error.JournalChanged;
        var appeared = windows_fs.load(&fresh, self.a, filename, max_bytes) catch |err| return windowsError(err);
        defer if (appeared) |*bytes| bytes.deinit();
        if (appeared) |bytes| {
            self.baseline_retry = .forbidden;
            var document = try parse(self.a, bytes.bytes);
            defer document.deinit(self.a);
            return error.JournalChanged;
        }
        var previous = self.windows_root.?;
        self.windows_root = fresh;
        windows_fs.deinit(&previous);
        // Owner poison stays set until ensureBaseline durably publishes absence.
    }

    const WindowsCheck = struct {
        a: Allocator,
        expected: ?*const Document,
        fn run(context: ?*anyopaque, root: *windows_fs.Root) anyerror!void {
            const check: *WindowsCheck = @ptrCast(@alignCast(context.?));
            var current = try windows_fs.load(root, check.a, filename, max_bytes);
            defer if (current) |*bytes| bytes.deinit();
            if ((current != null) != (check.expected != null)) return error.JournalChanged;
            if (current) |bytes| {
                var document = try parse(check.a, bytes.bytes);
                defer document.deinit(check.a);
                if (!sameDocument(document, check.expected.?.*)) return error.JournalChanged;
            }
        }
    };

    fn checkCurrent(self: *Journal, dir: Dir, expected: ?*const Document) Error!void {
        var current = try load(self.a, self.io, dir);
        defer if (current) |*loaded| loaded.deinit(self.a);
        if ((current != null) != (expected != null)) return error.JournalChanged;
        if (current) |loaded| {
            if (!sameDocument(loaded.document, expected.?.*)) return error.JournalChanged;
        }
    }
};

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
        error.InvalidPending => error.InvalidPending,
        error.InsecureJournal => error.InsecureJournal,
        error.JournalChanged => error.JournalChanged,
        error.CommitUncertain => error.CommitUncertain,
        error.UnsupportedDurability => error.UnsupportedDurability,
        else => error.PersistenceFailure,
    };
}

fn supported() Error!void {
    if (builtin.os.tag == .wasi) return error.UnsupportedDurability;
}
fn validRef(ref: Reference) Error!void {
    if (!credentials.validateReference(&ref)) return error.InvalidReference;
}
fn equal(left: Reference, right: Reference) bool {
    return std.mem.eql(u8, &left, &right);
}
fn contains(refs: []const Reference, ref: Reference) bool {
    for (refs) |old| if (equal(old, ref)) return true;
    return false;
}
fn add(a: Allocator, refs: *std.ArrayList(Reference), ref: Reference) Error!void {
    if (contains(refs.items, ref)) return;
    if (refs.items.len == max_references) return error.TooManyReferences;
    try refs.append(a, ref);
}
fn validate(document: Document) Error!void {
    if (document.schema_version != 1) return error.UnsupportedSchemaVersion;
    if (document.cleanup.len > max_references) return error.TooManyReferences;
    for (document.cleanup, 0..) |ref, i| {
        try validRef(ref);
        if (contains(document.cleanup[0..i], ref)) return error.DuplicateReference;
    }
    if (document.pending) |p| {
        if (p.old_ref) |ref| try validRef(ref);
        if (p.new_ref) |ref| try validRef(ref);
        switch (p.action) {
            .set => {
                const new = p.new_ref orelse return error.InvalidPending;
                if (p.old_ref) |old| if (equal(old, new)) return error.InvalidPending;
            },
            .remove => if (p.old_ref == null or p.new_ref != null) return error.InvalidPending,
        }
        if (p.old_ref) |ref| if (!contains(document.cleanup, ref)) return error.InvalidPending;
        if (p.new_ref) |ref| if (!contains(document.cleanup, ref)) return error.InvalidPending;
    }
}
fn clone(a: Allocator, document: Document) Error!Document {
    try validate(document);
    return .{ .pending = document.pending, .cleanup = try a.dupe(Reference, document.cleanup) };
}
fn sameDocument(left: Document, right: Document) bool {
    if (left.schema_version != right.schema_version or left.cleanup.len != right.cleanup.len) return false;
    if (!std.meta.eql(left.pending, right.pending)) return false;
    for (left.cleanup, right.cleanup) |l, r| if (!equal(l, r)) return false;
    return true;
}
const WirePending = struct { action: Action, old_ref: ?[]const u8, new_ref: ?[]const u8 };
const Wire = struct { schema_version: u32, pending: ?WirePending, cleanup: []const []const u8 };
fn serialize(a: Allocator, document: Document) Error![]const u8 {
    try validate(document);
    const strings = try a.alloc([]const u8, document.cleanup.len);
    defer a.free(strings);
    for (document.cleanup, 0..) |*ref, i| strings[i] = ref;
    const wire: Wire = .{
        .schema_version = 1,
        .pending = if (document.pending) |*p| .{
            .action = p.action,
            .old_ref = if (p.old_ref) |*ref| ref else null,
            .new_ref = if (p.new_ref) |*ref| ref else null,
        } else null,
        .cleanup = strings,
    };
    const bytes = try std.json.Stringify.valueAlloc(a, wire, .{ .whitespace = .indent_2 });
    if (bytes.len > max_bytes) {
        a.free(bytes);
        return error.JournalTooLarge;
    }
    return bytes;
}
fn parseRef(value: std.json.Value) Error!?Reference {
    if (value == .null) return null;
    if (value != .string or !credentials.validateReference(value.string)) return error.InvalidReference;
    return value.string[0..32].*;
}
// Bound container amplification before dynamic Value maps/arrays are allocated.
fn preflight(a: Allocator, bytes: []const u8) Error!void {
    var scanner = std.json.Scanner.initCompleteInput(a, bytes);
    defer scanner.deinit();
    var depth: usize = 0;
    var tokens: usize = 0;
    while (true) {
        const token = scanner.nextAllocMax(a, .alloc_if_needed, max_bytes) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidJournal;
        defer switch (token) {
            .allocated_string, .allocated_number => |text| a.free(text),
            else => {},
        };
        tokens += 1;
        if (tokens > 2048) return error.InvalidJournal;
        if (tokens == 1 and token != .object_begin) return error.InvalidJournal;
        switch (token) {
            .object_begin, .array_begin => {
                depth += 1;
                if (depth > 8) return error.InvalidJournal;
            },
            .object_end, .array_end => {
                if (depth == 0) return error.InvalidJournal;
                depth -= 1;
            },
            .end_of_document => {
                if (depth != 0) return error.InvalidJournal;
                return;
            },
            else => {},
        }
    }
}
fn parse(a: Allocator, bytes: []const u8) Error!Document {
    if (bytes.len > max_bytes) return error.JournalTooLarge;
    try preflight(a, bytes);
    const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{
        .allocate = .alloc_always,
        .max_value_len = max_bytes,
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidJournal;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJournal;
    const object = parsed.value.object;
    if (object.count() != 3) return error.InvalidJournal;
    const version = object.get("schema_version") orelse return error.InvalidJournal;
    if (version != .integer) return error.InvalidJournal;
    if (version.integer != 1) return error.UnsupportedSchemaVersion;
    const pending_value = object.get("pending") orelse return error.InvalidJournal;
    var pending: ?Pending = null;
    if (pending_value != .null) {
        if (pending_value != .object or pending_value.object.count() != 3) return error.InvalidPending;
        const p = pending_value.object;
        const action = p.get("action") orelse return error.InvalidPending;
        if (action != .string) return error.InvalidPending;
        pending = .{
            .action = std.meta.stringToEnum(Action, action.string) orelse return error.InvalidPending,
            .old_ref = try parseRef(p.get("old_ref") orelse return error.InvalidPending),
            .new_ref = try parseRef(p.get("new_ref") orelse return error.InvalidPending),
        };
    }
    const refs = object.get("cleanup") orelse return error.InvalidJournal;
    if (refs != .array) return error.InvalidJournal;
    if (refs.array.items.len > max_references) return error.TooManyReferences;
    var document: Document = .{ .pending = pending, .cleanup = try a.alloc(Reference, refs.array.items.len) };
    errdefer document.deinit(a);
    for (refs.array.items, @constCast(document.cleanup)) |value, *ref| {
        ref.* = (try parseRef(value)) orelse return error.InvalidReference;
    }
    try validate(document);
    return document;
}
fn validateRoot(root: []const u8) Error!void {
    if (root.len == 0 or root.len > 4096 or root[0] != '/' or std.mem.indexOfAny(u8, root, "\\\x00") != null) return error.InvalidRoot;
    var parts = std.mem.tokenizeScalar(u8, root, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidRoot;
    }
}
fn openRoot(io: Io, root: []const u8) !Dir {
    var current = try Dir.cwd().openDir(io, "/", .{ .iterate = true, .follow_symlinks = false });
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
const Loaded = struct {
    bytes: []const u8,
    document: Document,
    fn deinit(self: *Loaded, a: Allocator) void {
        a.free(self.bytes);
        self.document.deinit(a);
    }
};
fn load(a: Allocator, io: Io, dir: Dir) Error!?Loaded {
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
    const buffer = try a.alloc(u8, max_bytes + 1);
    defer a.free(buffer);
    const n = file.readPositionalAll(io, buffer, 0) catch return error.PersistenceFailure;
    if (n > max_bytes) return error.JournalTooLarge;
    var document = try parse(a, buffer[0..n]);
    errdefer document.deinit(a);
    return .{ .bytes = try a.dupe(u8, buffer[0..n]), .document = document };
}
fn checkStat(stat: Io.File.Stat) Error!void {
    if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o7777 != 0o600) return error.InsecureJournal;
    if (stat.size > max_bytes) return error.JournalTooLarge;
}
fn syncDir(dir: Dir, io: Io) !void {
    const file: Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try file.sync(io);
}

const ref_a: Reference = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".*;
const ref_b: Reference = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".*;
const ref_c: Reference = "cccccccccccccccccccccccccccccccc".*;
fn testSupported() !void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
}
fn writeTestFile(dir: Dir, path: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(std.testing.io, path, .{ .permissions = .fromMode(0o600) });
    defer file.close(std.testing.io);
    try file.setPermissions(std.testing.io, .fromMode(0o600));
    try file.writeStreamingAll(std.testing.io, bytes);
    try file.sync(std.testing.io);
}
fn diskDocument(dir: Dir) !Document {
    const bytes = try dir.readFileAlloc(std.testing.io, ".vela/" ++ filename, std.testing.allocator, .limited(max_bytes));
    defer std.testing.allocator.free(bytes);
    return parse(std.testing.allocator, bytes);
}

test "durable set replace remove resolve preserves unrelated debt and never promotes a reference" {
    try testSupported();
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var j = try Journal.init(a, std.testing.io, root);
    defer j.deinit();
    try std.testing.expectEqual(@as(usize, 0), j.snapshot().cleanup.len);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, ".vela", .{}));
    try j.stageSet(null, ref_a);
    var disk = try diskDocument(tmp.dir);
    defer disk.deinit(a);
    try std.testing.expect(sameDocument(disk, j.snapshot().*));
    try std.testing.expectEqual(Action.set, disk.pending.?.action);
    try std.testing.expectError(error.PendingUnresolved, j.stageSet(ref_a, ref_b));
    try std.testing.expectError(error.PendingUnresolved, j.stageRemove(ref_a));
    try std.testing.expectError(error.PendingUnresolved, j.forget(ref_a));
    try j.resolve(null); // failed/unconfirmed put leaves A as debt
    try std.testing.expectError(error.InvalidPending, j.stageSet(null, ref_a));
    try j.stageSet(null, ref_c);
    try j.resolve(ref_c);
    try j.stageSet(ref_c, ref_b);
    try std.testing.expectEqual(@as(usize, 3), j.snapshot().cleanup.len);
    try j.resolve(ref_b); // confirmed publication protects B only
    try std.testing.expect(contains(j.snapshot().cleanup, ref_a));
    try std.testing.expect(contains(j.snapshot().cleanup, ref_c));
    try std.testing.expect(!contains(j.snapshot().cleanup, ref_b));
    try j.forget(ref_c); // confirmed delete/NotFound
    try j.forget(ref_c); // idempotent after acknowledgement
    try j.stageRemove(ref_b);
    try std.testing.expectEqual(Action.remove, j.snapshot().pending.?.action);
    try std.testing.expect(j.snapshot().pending.?.new_ref == null);
    try j.resolve(null);
    try std.testing.expect(contains(j.snapshot().cleanup, ref_b));
    try j.forget(ref_b);
    try j.resolve(ref_a); // no pending: remove protected reference durably
    try std.testing.expectEqual(@as(usize, 0), j.snapshot().cleanup.len);
    var restart = try Journal.init(a, std.testing.io, root);
    defer restart.deinit();
    try std.testing.expect(sameDocument(restart.snapshot().*, j.snapshot().*));
    try std.testing.expectError(error.InvalidPending, j.stageSet(ref_a, ref_a));
    try std.testing.expectError(error.InvalidReference, j.stageRemove("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".*));
}

test "strict schema rejects unknown secret keys duplicate fields refs invalid pending and trailing bytes" {
    const a = std.testing.allocator;
    const valid = "{\"schema_version\":1,\"pending\":null,\"cleanup\":[]}";
    var empty = try parse(a, valid);
    defer empty.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), empty.cleanup.len);
    const cases = [_]struct { bytes: []const u8, err: Error }{
        .{ .bytes = "{}", .err = error.InvalidJournal },
        .{ .bytes = "[]", .err = error.InvalidJournal },
        .{ .bytes = "{\"schema_version\":2,\"pending\":null,\"cleanup\":[]}", .err = error.UnsupportedSchemaVersion },
        .{ .bytes = "{\"schema_version\":1,\"pending\":null,\"cleanup\":[],\"api_key\":\"secret\"}", .err = error.InvalidJournal },
        .{ .bytes = "{\"schema_version\":1,\"schema_version\":1,\"pending\":null,\"cleanup\":[]}", .err = error.InvalidJournal },
        .{ .bytes = valid ++ " {}", .err = error.InvalidJournal },
        .{ .bytes = "{\"schema_version\":1,\"pending\":null,\"cleanup\":[null]}", .err = error.InvalidReference },
        .{ .bytes = "{\"schema_version\":1,\"pending\":null,\"cleanup\":[\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"]}", .err = error.InvalidReference },
        .{ .bytes = "{\"schema_version\":1,\"pending\":null,\"cleanup\":[\"a\"]}", .err = error.InvalidReference },
        .{ .bytes = "{\"schema_version\":1,\"pending\":{\"action\":\"set\",\"old_ref\":null,\"new_ref\":null},\"cleanup\":[]}", .err = error.InvalidPending },
        .{ .bytes = "{\"schema_version\":1,\"pending\":{\"action\":\"remove\",\"old_ref\":null,\"new_ref\":null},\"cleanup\":[]}", .err = error.InvalidPending },
        .{ .bytes = "{\"schema_version\":1,\"pending\":{\"action\":\"replace\",\"old_ref\":null,\"new_ref\":null},\"cleanup\":[]}", .err = error.InvalidPending },
        .{ .bytes = "{\"schema_version\":1,\"pending\":{\"action\":\"set\",\"old_ref\":null,\"new_ref\":null,\"key\":\"secret\"},\"cleanup\":[]}", .err = error.InvalidPending },
    };
    for (cases) |case| try std.testing.expectError(case.err, parse(a, case.bytes));
    try std.testing.expectError(error.DuplicateReference, validate(.{ .cleanup = &.{ ref_a, ref_a } }));
    try std.testing.expectError(error.InvalidPending, validate(.{ .pending = .{ .action = .set, .new_ref = ref_a } }));
    try std.testing.expectError(error.InvalidPending, validate(.{ .pending = .{ .action = .set, .old_ref = ref_a, .new_ref = ref_a }, .cleanup = &.{ref_a} }));
    try std.testing.expectError(error.InvalidPending, validate(.{ .pending = .{ .action = .remove, .old_ref = ref_a, .new_ref = ref_b }, .cleanup = &.{ ref_a, ref_b } }));
    const oversized = try a.alloc(u8, max_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.JournalTooLarge, parse(a, oversized));
    const limit = try a.alloc(u8, max_bytes);
    defer a.free(limit);
    @memset(limit, ' ');
    @memcpy(limit[0..valid.len], valid);
    var at_limit = try parse(a, limit);
    defer at_limit.deinit(a);
    var refs: [max_references + 1]Reference = undefined;
    for (&refs, 0..) |*ref, i| _ = try std.fmt.bufPrint(ref, "{x:0>32}", .{i});
    try std.testing.expectError(error.TooManyReferences, validate(.{ .cleanup = &refs }));
    const wire = try serialize(a, .{ .cleanup = refs[0..max_references] });
    defer a.free(wire);
    var roundtrip = try parse(a, wire);
    defer roundtrip.deinit(a);
    try std.testing.expectEqual(max_references, roundtrip.cleanup.len);
}

const FaultIo = struct {
    threadlocal var active: ?*FaultIo = null;
    real: Io = std.testing.io,
    vtable: Io.VTable = undefined,
    creates: usize = 0,
    renames: usize = 0,
    syncs: usize = 0,
    fail_sync: ?usize = null,
    fail_rename: bool = false,
    fn start(self: *FaultIo) Io {
        std.debug.assert(active == null);
        active = self;
        self.vtable = self.real.vtable.*;
        self.vtable.dirCreateFile = create;
        self.vtable.dirRename = rename;
        self.vtable.fileSync = sync;
        return .{ .userdata = self.real.userdata, .vtable = &self.vtable };
    }
    fn stop(self: *FaultIo) void {
        std.debug.assert(active == self);
        active = null;
    }
    fn reset(self: *FaultIo) void {
        self.creates = 0;
        self.renames = 0;
        self.syncs = 0;
        self.fail_sync = null;
        self.fail_rename = false;
    }
    fn create(ctx: ?*anyopaque, dir: Dir, path: []const u8, options: Dir.CreateFileOptions) Io.File.OpenError!Io.File {
        const self = active.?;
        self.creates += 1;
        return self.real.vtable.dirCreateFile(ctx, dir, path, options);
    }
    fn rename(ctx: ?*anyopaque, old_dir: Dir, old_path: []const u8, new_dir: Dir, new_path: []const u8) Dir.RenameError!void {
        const self = active.?;
        self.renames += 1;
        if (self.fail_rename) return error.AccessDenied;
        return self.real.vtable.dirRename(ctx, old_dir, old_path, new_dir, new_path);
    }
    fn sync(ctx: ?*anyopaque, file: Io.File) Io.File.SyncError!void {
        const self = active.?;
        self.syncs += 1;
        if (self.fail_sync == self.syncs) return error.InputOutput;
        return self.real.vtable.fileSync(ctx, file);
    }
    fn expectBlocked(self: *FaultIo, j: *Journal) !void {
        const creates = self.creates;
        const renames = self.renames;
        const syncs = self.syncs;
        try std.testing.expectError(error.JournalUncertain, j.stageSet(ref_a, ref_b));
        try std.testing.expectError(error.JournalUncertain, j.stageRemove(ref_a));
        try std.testing.expectError(error.JournalUncertain, j.resolve(ref_b));
        try std.testing.expectError(error.JournalUncertain, j.forget(ref_a));
        try std.testing.expectEqual(creates, self.creates);
        try std.testing.expectEqual(renames, self.renames);
        try std.testing.expectEqual(syncs, self.syncs);
    }
};

test "before and after rename failures retain snapshots poison all mutations and require durable reload" {
    try testSupported();
    const a = std.testing.allocator;
    for ([_]usize{ 1, 2, 3, 4 }) |failure| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        defer a.free(root);
        var fault: FaultIo = .{};
        const io = fault.start();
        defer fault.stop();
        var j = try Journal.init(a, io, root);
        defer j.deinit();
        try j.stageSet(null, ref_a);
        try j.resolve(null);
        const previous = j.snapshot().*;
        fault.reset();
        if (failure == 4) fault.fail_rename = true else fault.fail_sync = failure;
        try std.testing.expectError(if (failure == 2) error.PersistenceFailure else error.CommitUncertain, j.stageSet(ref_a, ref_b));
        try std.testing.expect(j.poisoned());
        try std.testing.expect(j.snapshot().cleanup.ptr == previous.cleanup.ptr);
        try std.testing.expect(sameDocument(j.snapshot().*, previous));
        try fault.expectBlocked(&j);
        var disk = try diskDocument(tmp.dir);
        defer disk.deinit(a);
        try std.testing.expectEqual(failure == 3, disk.pending != null);
        if (failure == 3) {
            try std.testing.expect(contains(disk.cleanup, ref_a));
            try std.testing.expect(contains(disk.cleanup, ref_b));
            try std.testing.expectEqual(ref_b, disk.pending.?.new_ref.?);
        }
        // A read of disk alone must not clear poison: failed reflush retains memory.
        fault.reset();
        fault.fail_sync = 3;
        try std.testing.expectError(error.CommitUncertain, j.reload());
        try std.testing.expect(j.poisoned());
        try std.testing.expect(j.snapshot().cleanup.ptr == previous.cleanup.ptr);
        try fault.expectBlocked(&j);
        fault.reset();
        try j.reload();
        try std.testing.expect(!j.poisoned());
        try std.testing.expect(sameDocument(j.snapshot().*, disk));
        try std.testing.expectEqual(@as(usize, 1), fault.renames);
        try std.testing.expectEqual(@as(usize, 3), fault.syncs);
        var restart = try Journal.init(a, std.testing.io, root);
        defer restart.deinit();
        try std.testing.expect(sameDocument(restart.snapshot().*, disk));
        try j.resolve(if (failure == 3) ref_b else ref_a);
    }
}

test "pending survive restart until explicit resolution and full debt cap is checked atomically" {
    try testSupported();
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var first = try Journal.init(a, std.testing.io, root);
    defer first.deinit();
    try first.stageSet(ref_a, ref_b);
    var restart = try Journal.init(a, std.testing.io, root);
    defer restart.deinit();
    try std.testing.expect(sameDocument(first.snapshot().*, restart.snapshot().*));
    try std.testing.expectError(error.PendingUnresolved, restart.forget(ref_a));
    try restart.resolve(ref_a); // config publication failed; old active remains protected
    try std.testing.expect(!contains(restart.snapshot().cleanup, ref_a));
    try std.testing.expect(contains(restart.snapshot().cleanup, ref_b));
    try restart.stageSet(ref_a, ref_c);
    try std.testing.expectEqual(@as(usize, 3), restart.snapshot().cleanup.len);
    // External owner divergence cannot silently discard old/new debt.
    try std.testing.expectError(error.JournalChanged, first.resolve(ref_b));
    try std.testing.expect(first.poisoned());
    try first.reload();
    try first.resolve(null);
    var refs: [max_references - 1]Reference = undefined;
    for (&refs, 0..) |*ref, i| _ = try std.fmt.bufPrint(ref, "{x:0>32}", .{i});
    const seed = try serialize(a, .{ .cleanup = &refs });
    defer a.free(seed);
    try writeTestFile(tmp.dir, ".vela/" ++ filename, seed);
    try first.reload();
    var fault: FaultIo = .{};
    first.io = fault.start();
    defer fault.stop();
    const previous = first.snapshot().*;
    try std.testing.expectError(error.TooManyReferences, first.stageSet(ref_a, ref_b));
    try std.testing.expect(!first.poisoned());
    try std.testing.expect(first.snapshot().cleanup.ptr == previous.cleanup.ptr);
    try std.testing.expectEqual(@as(usize, 0), fault.creates);
    try first.stageSet(refs[0], ref_b); // existing ref deduplicates, final count=256
    try std.testing.expectEqual(max_references, first.snapshot().cleanup.len);
    try first.resolve(ref_b);
    try first.stageRemove(refs[0]); // old already debt, no duplication
    try std.testing.expectEqual(max_references - 1, first.snapshot().cleanup.len);
}

test "missing corrupt oversize insecure journal recovery fails closed without rewrites" {
    try testSupported();
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var fault: FaultIo = .{};
    var j = try Journal.init(a, fault.start(), root);
    defer fault.stop();
    defer j.deinit();
    try j.stageSet(null, ref_a);
    const saved = try tmp.dir.readFileAlloc(std.testing.io, ".vela/" ++ filename, a, .limited(max_bytes));
    defer a.free(saved);
    const previous = j.snapshot().*;
    try tmp.dir.deleteFile(std.testing.io, ".vela/" ++ filename);
    fault.reset();
    try std.testing.expectError(error.JournalChanged, j.reload());
    try std.testing.expect(j.poisoned());
    try fault.expectBlocked(&j);
    const invalid = [_]struct { bytes: []const u8, err: Error }{
        .{ .bytes = "{", .err = error.InvalidJournal },
        .{ .bytes = "{\"schema_version\":2,\"pending\":null,\"cleanup\":[]}", .err = error.UnsupportedSchemaVersion },
        .{ .bytes = "{\"schema_version\":1,\"pending\":{\"action\":\"set\",\"old_ref\":null,\"new_ref\":null},\"cleanup\":[]}", .err = error.InvalidPending },
    };
    for (invalid) |case| {
        try writeTestFile(tmp.dir, ".vela/" ++ filename, case.bytes);
        fault.reset();
        try std.testing.expectError(case.err, j.reload());
        try std.testing.expectError(case.err, Journal.init(a, std.testing.io, root));
        try std.testing.expectEqual(@as(usize, 0), fault.creates);
        try std.testing.expectEqual(@as(usize, 0), fault.renames);
        try std.testing.expect(j.snapshot().cleanup.ptr == previous.cleanup.ptr);
        try fault.expectBlocked(&j);
    }
    const oversized = try a.alloc(u8, max_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, ' ');
    try writeTestFile(tmp.dir, ".vela/" ++ filename, oversized);
    fault.reset();
    try std.testing.expectError(error.JournalTooLarge, j.reload());
    try std.testing.expectEqual(@as(usize, 0), fault.creates);
    try writeTestFile(tmp.dir, ".vela/" ++ filename, saved);
    const file = try tmp.dir.openFile(std.testing.io, ".vela/" ++ filename, .{});
    defer file.close(std.testing.io);
    try file.setPermissions(std.testing.io, .fromMode(0o644));
    try std.testing.expectError(error.InsecureJournal, j.reload());
    try std.testing.expectError(error.InsecureJournal, Journal.init(a, std.testing.io, root));
    try file.setPermissions(std.testing.io, .fromMode(0o600));
    try j.reload();
    try std.testing.expect(!j.poisoned());
    var recovered = try parse(a, saved);
    defer recovered.deinit(a);
    try std.testing.expect(sameDocument(j.snapshot().*, recovered));
}

fn allocationExercise(a: Allocator) !void {
    // Escaped keys exercise preflight's temporary allocated-token cleanup.
    var escaped = try parse(a, "{\"schema_vers\\u0069on\":1,\"pending\":null,\"cleanup\":[]}");
    defer escaped.deinit(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var j = try Journal.init(a, std.testing.io, root);
    defer j.deinit();
    try j.stageSet(ref_a, ref_b);
    try j.reload();
    try j.resolve(ref_b);
    try j.forget(ref_a);
    var restart = try Journal.init(a, std.testing.io, root);
    defer restart.deinit();
    try std.testing.expectEqual(@as(usize, 0), restart.snapshot().cleanup.len);
}
test "allocation failures release owned parse mutation reload snapshots and file resources" {
    try testSupported();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{});
}
test "unsupported durability and invalid roots are rejected before native operations" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        try std.testing.expectError(error.UnsupportedDurability, Journal.init(std.testing.allocator, std.testing.io, "/"));
        return;
    }
    for ([_][]const u8{ "", "relative", "/tmp/../else", "/tmp/./else", "/tmp\\else", "/tmp\x00else" }) |root| {
        try std.testing.expectError(error.InvalidRoot, Journal.init(std.testing.allocator, std.testing.io, root));
    }
}

test "root symlink journal symlink hardlink and writable directories fail closed" {
    try testSupported();
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try tmp.dir.createDir(io, "target", .fromMode(0o700));
    try tmp.dir.symLink(io, "target", "link", .{ .is_directory = true });
    const linked = try std.fmt.allocPrint(a, "{s}/link", .{root});
    defer a.free(linked);
    try std.testing.expectError(error.InvalidRoot, Journal.init(a, io, linked));
    const through_parent = try std.fmt.allocPrint(a, "{s}/link/child", .{root});
    defer a.free(through_parent);
    try std.testing.expectError(error.InvalidRoot, Journal.init(a, io, through_parent));
    try tmp.dir.symLink(io, "target", ".vela", .{ .is_directory = true });
    try std.testing.expectError(error.InsecureJournal, Journal.init(a, io, root));
    try tmp.dir.deleteFile(io, ".vela");
    var fault: FaultIo = .{};
    var j = try Journal.init(a, fault.start(), root);
    defer fault.stop();
    defer j.deinit();
    try j.stageSet(null, ref_a);
    try Dir.hardLink(tmp.dir, ".vela/" ++ filename, tmp.dir, "alias", io, .{});
    fault.reset();
    try std.testing.expectError(error.InsecureJournal, j.resolve(ref_a));
    try std.testing.expectEqual(@as(usize, 0), fault.creates);
    try std.testing.expectError(error.InsecureJournal, j.reload());
    try std.testing.expectError(error.InsecureJournal, Journal.init(a, io, root));
    try tmp.dir.deleteFile(io, "alias");
    try j.reload();
    try tmp.dir.deleteFile(io, ".vela/" ++ filename);
    try writeTestFile(tmp.dir, "outside", "untouched");
    try tmp.dir.symLink(io, "../outside", ".vela/" ++ filename, .{});
    fault.reset();
    try std.testing.expectError(error.InsecureJournal, j.resolve(ref_a));
    try std.testing.expectEqual(@as(usize, 0), fault.creates);
    try std.testing.expectError(error.InsecureJournal, j.reload());
    const outside = try tmp.dir.readFileAlloc(io, "outside", a, .limited(64));
    defer a.free(outside);
    try std.testing.expectEqualStrings("untouched", outside);
    try tmp.dir.deleteFile(io, ".vela/" ++ filename);
    const bytes = try serialize(a, .{});
    defer a.free(bytes);
    try writeTestFile(tmp.dir, ".vela/" ++ filename, bytes);
    const dir = try tmp.dir.openDir(io, ".vela", .{ .iterate = true });
    defer dir.close(io);
    const dir_file: Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try dir_file.setPermissions(io, .fromMode(0o777));
    try std.testing.expectError(error.InsecureJournal, j.reload());
    try std.testing.expectError(error.InsecureJournal, Journal.init(a, io, root));
    try dir_file.setPermissions(io, .fromMode(0o700));
    try j.reload();
    try std.testing.expect(!j.poisoned());
}

test "resolve and forget persistence failure retain pending or debt until confirmed reload" {
    try testSupported();
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |forget| {
        for ([_]usize{ 2, 3 }) |failure| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
            defer a.free(root);
            var fault: FaultIo = .{};
            var j = try Journal.init(a, fault.start(), root);
            defer fault.stop();
            defer j.deinit();
            try j.stageSet(ref_a, ref_b);
            if (forget) try j.resolve(ref_b);
            var before = try clone(a, j.snapshot().*);
            defer before.deinit(a);
            const previous_pointer = j.snapshot().cleanup.ptr;
            fault.reset();
            fault.fail_sync = failure;
            const expected_error: Error = if (failure == 2) error.PersistenceFailure else error.CommitUncertain;
            if (forget) {
                try std.testing.expectError(expected_error, j.forget(ref_a));
            } else {
                try std.testing.expectError(expected_error, j.resolve(ref_b));
            }
            try std.testing.expect(j.poisoned());
            try std.testing.expect(j.snapshot().cleanup.ptr == previous_pointer);
            try std.testing.expect(sameDocument(before, j.snapshot().*));
            try fault.expectBlocked(&j);
            var disk = try diskDocument(tmp.dir);
            defer disk.deinit(a);
            if (failure == 2) {
                try std.testing.expect(sameDocument(before, disk));
            } else {
                try std.testing.expect(disk.pending == null);
                try std.testing.expectEqual(@as(usize, if (forget) 0 else 1), disk.cleanup.len);
                if (!forget) try std.testing.expectEqual(ref_a, disk.cleanup[0]);
            }
            fault.reset();
            try j.reload();
            try std.testing.expect(sameDocument(disk, j.snapshot().*));
        }
    }
}

test "bounded preflight rejects deeply nested and wide unknown shapes without journal rewrites" {
    try testSupported();
    const a = std.testing.allocator;
    const prefix = "{\"schema_version\":1,\"pending\":null,\"cleanup\":[],\"extra\":";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var fault: FaultIo = .{};
    var j = try Journal.init(a, fault.start(), root);
    defer fault.stop();
    defer j.deinit();
    try j.stageSet(ref_a, ref_b);
    const previous_pointer = j.snapshot().cleanup.ptr;
    var original = try clone(a, j.snapshot().*);
    defer original.deinit(a);
    for ([_]bool{ false, true }) |objects| {
        for ([_]bool{ false, true }) |truncated| {
            var bytes: std.ArrayList(u8) = .empty;
            defer bytes.deinit(a);
            try bytes.appendSlice(a, prefix);
            const layers: usize = if (objects) 10000 else 30000;
            for (0..layers) |_| try bytes.appendSlice(a, if (objects) "{\"x\":" else "[");
            try bytes.appendSlice(a, "0");
            if (!truncated) {
                for (0..layers) |_| try bytes.append(a, if (objects) '}' else ']');
                try bytes.append(a, '}');
            }
            try std.testing.expect(bytes.items.len <= max_bytes);
            // Keep the fixture at the exact byte cap, not merely a tiny deep input.
            try bytes.appendNTimes(a, ' ', max_bytes - bytes.items.len);
            try std.testing.expectError(error.InvalidJournal, parse(a, bytes.items));
            try writeTestFile(tmp.dir, ".vela/" ++ filename, bytes.items);
            fault.reset();
            try std.testing.expectError(error.InvalidJournal, j.reload());
            try std.testing.expectError(error.InvalidJournal, Journal.init(a, std.testing.io, root));
            try std.testing.expect(j.poisoned());
            try std.testing.expect(j.snapshot().cleanup.ptr == previous_pointer);
            try std.testing.expectEqual(@as(usize, 0), fault.creates);
            try std.testing.expectEqual(@as(usize, 0), fault.renames);
            try std.testing.expectEqual(@as(usize, 0), fault.syncs);
            try fault.expectBlocked(&j);
        }
    }
    var wide: std.ArrayList(u8) = .empty;
    defer wide.deinit(a);
    try wide.appendSlice(a, prefix ++ "[");
    for (0..3000) |i| try wide.appendSlice(a, if (i == 0) "0" else ",0");
    try wide.appendSlice(a, "]}");
    try std.testing.expectError(error.InvalidJournal, preflight(a, wide.items));
    try std.testing.expectError(error.InvalidJournal, parse(a, wide.items));
    try writeTestFile(tmp.dir, ".vela/" ++ filename, wide.items);
    fault.reset();
    try std.testing.expectError(error.InvalidJournal, j.reload());
    try std.testing.expectEqual(@as(usize, 0), fault.creates);
    try std.testing.expectEqual(@as(usize, 0), fault.renames);
    try std.testing.expectEqual(@as(usize, 0), fault.syncs);
    const saved = try serialize(a, original);
    defer a.free(saved);
    try writeTestFile(tmp.dir, ".vela/" ++ filename, saved);
    try j.reload();
    try std.testing.expect(!j.poisoned());
    try std.testing.expect(sameDocument(original, j.snapshot().*));
}

const WindowsJournalFake = @import("auth_cleanup_test.zig").WindowsFake;
fn windowsJournal(allocator: Allocator, fake: *WindowsJournalFake) Error!Journal {
    return Journal.initWithNativeOps(allocator, std.testing.io, "C:/owned/launcher", fake.nativeOps(), .{ .context = fake, .open = WindowsJournalFake.reopen });
}

test "Windows CF readonly init and two fresh stage parser checks" {
    const a = std.testing.allocator;
    const old: Reference = @splat('0');
    const new: Reference = @splat('1');
    const empty_disk = try serialize(a, .{});
    defer a.free(empty_disk);
    for (0..5) |which| {
        var fake: WindowsJournalFake = .{ .directory_exists = false };
        var j = try windowsJournal(a, &fake);
        defer j.deinit();
        try std.testing.expect(!fake.directory_exists and !fake.present and fake.ensures == 0 and fake.creates == 0);
        try j.ensureBaseline();
        try j.stageSet(old, new);
        const prior = j.snapshot().cleanup.ptr;
        const moves = fake.moves;
        if (which < 2) {
            fake.drift_at_load = fake.load_count + which + 1;
            fake.drift_bytes = empty_disk;
        }
        if (which == 2) {
            fake.drift_at_load = fake.load_count + 2;
            fake.drift_bytes = "{broken";
        }
        if (which == 3) fake.file_private = false;
        if (which == 4) fake.cancel_before = true;
        try std.testing.expectError(if (which < 2) error.JournalChanged else if (which == 2) error.InvalidJournal else if (which == 3) error.InsecureJournal else error.PersistenceFailure, j.resolve(new));
        try std.testing.expect(j.poisoned() and prior == j.snapshot().cleanup.ptr and j.snapshot().pending != null);
        try std.testing.expect(j.snapshot().cleanup.len == 2 and fake.moves == moves and !fake.temp_open);
        try std.testing.expectError(error.JournalUncertain, j.forget(old));
    }
}

test "Windows CF exact reload rejects retained drafts and preserves both barriers on failure" {
    const a = std.testing.allocator;
    const old: Reference = @splat('0');
    const new: Reference = @splat('1');
    for (0..7) |which| {
        var fake: WindowsJournalFake = .{};
        var j = try windowsJournal(a, &fake);
        defer j.deinit();
        try j.ensureBaseline();
        try j.stageSet(old, new);
        fake.failure = .move_after;
        try std.testing.expectError(error.CommitUncertain, j.resolve(new));
        const prior = j.snapshot().cleanup.ptr;
        const draft = try serialize(a, j.snapshot().*);
        defer a.free(draft);
        fake.failure = .none;
        try std.testing.expectError(error.JournalChanged, windows_fs.reconcile(&j.windows_root.?, filename, draft, .{}));
        try std.testing.expect(j.poisoned() and j.windows_root.?.publication_uncertain);
        const disk = try std.fmt.allocPrint(a, "  {s}  ", .{fake.diskBytes()});
        defer a.free(disk);
        fake.seed(disk);
        if (which == 0) fake.failure = .write;
        if (which == 1) fake.failure = .final_flush;
        if (which == 2) fake.fail_load_at = fake.load_count + 1;
        if (which == 3) fake.present = false;
        if (which == 4) fake.seed("{broken");
        if (which == 5) fake.hardlink = true;
        if (which == 6) {
            fake.drift_at_load = fake.load_count + 4;
            fake.drift_bytes = draft;
        }
        if (j.reload()) |_| return error.TestUnexpectedSuccess else |_| {}
        try std.testing.expect(j.poisoned() and j.windows_root.?.publication_uncertain and !fake.temp_open);
        try std.testing.expect(prior == j.snapshot().cleanup.ptr and j.snapshot().pending != null);
        try std.testing.expectError(error.JournalUncertain, j.forget(old));
        fake.failure = .none;
        fake.fail_load_at = 0;
        fake.drift_at_load = 0;
        fake.hardlink = false;
        fake.seed(disk);
        try j.reload();
        try std.testing.expect(!j.poisoned() and !j.windows_root.?.publication_uncertain);
        try std.testing.expect(j.snapshot().pending == null and j.snapshot().cleanup.len == 1);
        try std.testing.expectEqualStrings(disk, fake.diskBytes());
    }
}

test "Windows CF absent recovery owns a fresh root and rejects appearance at all four rechecks" {
    const a = std.testing.allocator;
    const empty_disk = try serialize(a, .{});
    defer a.free(empty_disk);
    for (0..5) |which| {
        var fake: WindowsJournalFake = .{ .failure = .move_before };
        {
            var j = try windowsJournal(a, &fake);
            defer j.deinit();
            try std.testing.expectError(error.CommitUncertain, j.ensureBaseline());
            try std.testing.expect(j.poisoned() and j.windows_root.?.publication_uncertain and !fake.present);
            const orphan_index = fake.current_temp.?;
            const orphan = fake.temps[orphan_index];
            const discards = fake.discards;
            try std.testing.expect(orphan.present and orphan.private and orphan.ambiguous);
            fake.failure = .none;
            if (which != 0) {
                fake.drift_at_load = fake.load_count + which;
                fake.drift_bytes = empty_disk;
            }
            if (which == 0) {
                try j.ensureBaseline();
                try std.testing.expect(fake.opens == 2 and fake.closes == 1 and !j.poisoned() and !j.windows_root.?.publication_uncertain);
            } else {
                const moves = fake.moves;
                try std.testing.expectError(error.JournalChanged, j.ensureBaseline());
                try std.testing.expect(j.poisoned() and fake.moves == moves and j.snapshot().pending == null and j.snapshot().cleanup.len == 0);
                try std.testing.expectEqual(@as(usize, if (which == 1) 1 else 2), fake.opens);
                try std.testing.expectEqual(@as(usize, if (which == 1) 0 else 1), fake.closes);
            }
            try std.testing.expectEqual(orphan_index, fake.tempIndex(orphan.nameBytes()).?);
            try std.testing.expect(fake.temps[orphan_index].private and fake.temps[orphan_index].ambiguous);
            try std.testing.expect(std.meta.eql(orphan.identity, fake.temps[orphan_index].identity));
            try std.testing.expect(fake.temp_exists);
            if (which == 0 or which == 4) {
                const fresh_index = fake.current_temp.?;
                try std.testing.expect(fresh_index != orphan_index and fake.temps[fresh_index].private);
                try std.testing.expect(!std.mem.eql(u8, orphan.nameBytes(), fake.temps[fresh_index].nameBytes()));
                try std.testing.expectEqual(@as(usize, 2), fake.creates);
                try std.testing.expect(!fake.temps[fresh_index].present);
            } else {
                try std.testing.expectEqual(@as(usize, 1), fake.creates);
            }
            try std.testing.expectEqual(discards + @as(usize, if (which == 4) 1 else 0), fake.discards);
        }
        try std.testing.expect(fake.opens == fake.closes and !fake.temp_open);
        try std.testing.expect(fake.temp_exists);
    }
}

const WindowsReopenFixture = struct {
    fake: *WindowsJournalFake,
    kind: enum { wrong_path, wrong_privacy, poisoned },
    fn open(ctx: *anyopaque, allocator: Allocator, path: []const u8) windows_fs.Error!windows_fs.Root {
        const self: *WindowsReopenFixture = @ptrCast(@alignCast(ctx));
        var root = try windows_fs.openRootWithOps(allocator, if (self.kind == .wrong_path) "D:/different/launcher" else path, if (self.kind == .wrong_privacy) .ordinary_config else .private_journal, self.fake.nativeOps());
        if (self.kind == .poisoned) root.publication_uncertain = true;
        return root;
    }
};
test "Windows CF rejected factory roots close once and keep held root poison" {
    for ([_]@TypeOf(@as(WindowsReopenFixture, undefined).kind){ .wrong_path, .wrong_privacy, .poisoned }) |kind| {
        var fake: WindowsJournalFake = .{ .failure = .move_before };
        var factory: WindowsReopenFixture = .{ .fake = &fake, .kind = kind };
        {
            var j = try Journal.initWithNativeOps(std.testing.allocator, std.testing.io, "C:/owned/launcher", fake.nativeOps(), .{ .context = &factory, .open = WindowsReopenFixture.open });
            defer j.deinit();
            try std.testing.expectError(error.CommitUncertain, j.ensureBaseline());
            const orphan_index = fake.current_temp.?;
            const orphan = fake.temps[orphan_index];
            const discards = fake.discards;
            fake.failure = .none;
            try std.testing.expectError(error.JournalChanged, j.ensureBaseline());
            try std.testing.expect(j.poisoned() and j.windows_root.?.publication_uncertain and fake.opens == 2 and fake.closes == 1);
            try std.testing.expectEqual(orphan_index, fake.tempIndex(orphan.nameBytes()).?);
            try std.testing.expect(fake.temps[orphan_index].private and fake.temps[orphan_index].ambiguous and fake.discards == discards);
        }
        try std.testing.expect(fake.opens == fake.closes and !fake.temp_open and fake.temp_exists);
    }
}

test "Windows CF established journal disappearance is never recreated" {
    for ([_]bool{ false, true }) |staged| {
        var fake: WindowsJournalFake = .{};
        var j = try windowsJournal(std.testing.allocator, &fake);
        defer j.deinit();
        try j.ensureBaseline();
        if (staged) try j.stageSet(null, @splat('0'));
        fake.present = false;
        const creates = fake.creates;
        if (staged) {
            try std.testing.expectError(error.JournalChanged, j.resolve(null));
        } else {
            try std.testing.expectError(error.JournalChanged, j.stageSet(null, @splat('0')));
        }
        try std.testing.expect(fake.creates == creates and !fake.present and j.poisoned());
        try std.testing.expectError(error.JournalChanged, j.reload());
        try std.testing.expect(fake.creates == creates and !fake.present and j.poisoned() and j.windows_root.?.publication_uncertain);
        try std.testing.expectError(error.JournalUncertain, j.ensureBaseline());
    }
}

test "Windows CF init consumes root on strict parser security size load and wrong privacy" {
    const a = std.testing.allocator;
    const empty_disk = try serialize(a, .{});
    defer a.free(empty_disk);
    for (0..5) |which| {
        var fake: WindowsJournalFake = .{};
        fake.seed(if (which == 0) "{}" else empty_disk);
        if (which == 1) fake.file_private = false;
        if (which == 2) fake.disk_len = max_bytes + 1;
        if (which == 3) fake.fail_load_at = 1;
        var owned: ?windows_fs.Root = try windows_fs.openRootWithOps(a, "C:/owned/launcher", if (which == 4) .ordinary_config else .private_journal, fake.nativeOps());
        try std.testing.expectError(if (which == 0) error.InvalidJournal else if (which == 1) error.InsecureJournal else if (which == 2) error.JournalTooLarge else if (which == 3) error.PersistenceFailure else error.InsecureJournal, Journal.initOwnedRoot(a, std.testing.io, &owned, null));
        try std.testing.expect(owned == null and fake.closes == 1 and fake.creates == 0 and fake.ensures == 0);
    }
}

fn windowsJournalAllocationScenario(allocator: Allocator) !void {
    var fake: WindowsJournalFake = .{ .failure = .move_before };
    defer std.debug.assert(fake.opens == fake.closes and !fake.temp_open);
    var j = try windowsJournal(allocator, &fake);
    defer j.deinit();
    j.ensureBaseline() catch |err| {
        if (err == error.OutOfMemory) return err;
        if (err != error.CommitUncertain) return err;
    };
    fake.failure = .none;
    try j.ensureBaseline();
    try j.stageSet(null, @splat('0'));
    try j.resolve(null);
    try j.forget(@splat('0'));
    try j.reload();
}
test "Windows CF allocation failures release owned and reopened roots docs and staging" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, windowsJournalAllocationScenario, .{});
}

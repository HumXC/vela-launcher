//! Small, persistent, reversible rename journal. Payload is never opened or copied.
const std = @import("std");
const tree = @import("worlds_tree.zig");
const safe = @import("install/safe_fs.zig");
const content_fs = @import("content_fs.zig");
const config = @import("config.zig");
const A = std.mem.Allocator;
const Dir = std.Io.Dir;
const Stat = std.Io.File.Stat;
const Inode = @TypeOf(@as(Stat, undefined).inode);
pub const File = struct { inode: Inode, size: u64, hash: [32]u8 };
pub const Metadata = struct { old_name: []const u8, new_name: []const u8, before: File, after: File };
pub const Plan = struct {
    schema: u32 = 1,
    id: []const u8,
    old_name: []const u8,
    new_name: []const u8,
    directory_inode: Inode,
    jar_inode: ?Inode,
    old_jar: []const u8,
    new_jar: []const u8,
    document: Metadata,
    receipt: ?Metadata,
};
pub fn name(a: A, id: []const u8) ![]const u8 {
    if (!config.validId(id)) return error.UnsafeInstance;
    try safe.component(id);
    return std.fmt.allocPrint(a, "rename-{s}", .{id});
}
pub fn stat(io: std.Io, dir: Dir, path: []const u8) !?Stat {
    return dir.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}
pub fn identity(io: std.Io, dir: Dir, path: []const u8, bytes: []const u8) !File {
    const s = (try stat(io, dir, path)) orelse return error.RecoveryConflict;
    if (s.kind != .file or s.nlink != 1 or s.size != bytes.len) return error.RecoveryConflict;
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return .{ .inode = s.inode, .size = s.size, .hash = hash };
}
pub fn write(io: std.Io, dir: Dir, path: []const u8, bytes: []const u8) !void {
    const f = try dir.createFile(io, path, .{ .exclusive = true, .permissions = content_fs.privatePermissions(false) });
    defer f.close(io);
    try f.writePositionalAll(io, bytes, 0);
    try f.sync(io);
}
pub fn save(a: A, io: std.Io, dir: Dir, plan: Plan) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, plan, .{});
    defer a.free(bytes);
    try write(io, dir, "prepared.json", bytes);
    try tree.syncDir(io, dir);
    try dir.renamePreserve("prepared.json", dir, "manifest.json", io);
    try tree.syncDir(io, dir);
}
pub fn load(a: A, io: std.Io, dir: Dir, id: []const u8) !std.json.Parsed(Plan) {
    const s = (try stat(io, dir, "manifest.json")) orelse return error.RecoveryRequired;
    if (s.kind != .file or s.nlink != 1 or s.size > 32768) return error.RecoveryConflict;
    const f = try dir.openFile(io, "manifest.json", .{ .follow_symlinks = false });
    defer f.close(io);
    const opened = try f.stat(io);
    if (!matches(opened, s.inode, .file) or opened.size != s.size) return error.RecoveryConflict;
    const bytes = try a.alloc(u8, @intCast(s.size));
    defer a.free(bytes);
    if (try f.readPositionalAll(io, bytes, 0) != bytes.len) return error.RecoveryConflict;
    const after = try f.stat(io);
    if (after.size != s.size or after.mtime.nanoseconds != s.mtime.nanoseconds or after.ctime.nanoseconds != s.ctime.nanoseconds) return error.RecoveryConflict;
    var parsed = try std.json.parseFromSlice(Plan, a, bytes, .{ .allocate = .alloc_always, .max_value_len = 4096 });
    errdefer parsed.deinit();
    const p = parsed.value;
    if (p.schema != 1 or !std.mem.eql(u8, p.id, id) or !config.validId(p.old_name) or !config.validId(p.new_name) or std.ascii.eqlIgnoreCase(p.old_name, p.new_name)) return error.RecoveryConflict;
    try safe.component(p.old_name);
    try safe.component(p.new_name);
    const old_json = try std.fmt.allocPrint(a, "{s}.json", .{p.old_name});
    defer a.free(old_json);
    const new_json = try std.fmt.allocPrint(a, "{s}.json", .{p.new_name});
    defer a.free(new_json);
    const old_jar = try std.fmt.allocPrint(a, "{s}.jar", .{p.old_name});
    defer a.free(old_jar);
    const new_jar = try std.fmt.allocPrint(a, "{s}.jar", .{p.new_name});
    defer a.free(new_jar);
    if (!std.mem.eql(u8, old_json, p.document.old_name) or !std.mem.eql(u8, new_json, p.document.new_name) or !std.mem.eql(u8, old_jar, p.old_jar) or !std.mem.eql(u8, new_jar, p.new_jar)) return error.RecoveryConflict;
    if (p.receipt) |r| {
        if (!std.mem.eql(u8, r.old_name, r.new_name) or (!std.mem.eql(u8, r.old_name, ".vela-instance.json") and !std.mem.eql(u8, r.old_name, ".vela-loader.json"))) return error.RecoveryConflict;
    }
    return parsed;
}
fn matches(s: ?Stat, inode: Inode, kind: std.Io.File.Kind) bool {
    const value = s orelse return false;
    return value.inode == inode and value.kind == kind and (kind == .directory or value.nlink == 1);
}
fn move(io: std.Io, from: Dir, old: []const u8, to: Dir, new: []const u8, inode: Inode, kind: std.Io.File.Kind) !void {
    const before = try stat(io, from, old);
    const after = try stat(io, to, new);
    if (before == null and matches(after, inode, kind)) {
        // An earlier rename may have succeeded before its directory sync failed.
        try tree.syncDir(io, from);
        try tree.syncDir(io, to);
        return;
    }
    if (!matches(before, inode, kind) or after != null) return error.RecoveryConflict;
    try from.renamePreserve(old, to, new, io);
    if (try stat(io, from, old) != null or !matches(try stat(io, to, new), inode, kind)) return error.RecoveryConflict;
    try tree.syncDir(io, from);
    try tree.syncDir(io, to);
}
fn verifyFile(a: A, io: std.Io, dir: Dir, path: []const u8, expected: File) !bool {
    const s = (try stat(io, dir, path)) orelse return false;
    if (!matches(s, expected.inode, .file) or s.size != expected.size or s.size > 8 * 1024 * 1024) return error.RecoveryConflict;
    const f = try dir.openFile(io, path, .{ .follow_symlinks = false });
    defer f.close(io);
    if (!matches(try f.stat(io), expected.inode, .file)) return error.RecoveryConflict;
    const bytes = try a.alloc(u8, @intCast(s.size));
    defer a.free(bytes);
    if (try f.readPositionalAll(io, bytes, 0) != bytes.len) return error.RecoveryConflict;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!std.mem.eql(u8, &digest, &expected.hash)) return error.RecoveryConflict;
    return true;
}
fn verifyPair(a: A, io: std.Io, source: Dir, journal: Dir, m: Metadata, old_slot: []const u8, new_slot: []const u8) !void {
    // Receipt paths coincide, so select the expected version by inode before hashing.
    const current_old = try stat(io, source, m.old_name);
    const current_new = try stat(io, source, m.new_name);
    const before_here = matches(current_old, m.before.inode, .file);
    const after_here = matches(current_new, m.after.inode, .file);
    if (before_here) _ = try verifyFile(a, io, source, m.old_name, m.before);
    if (after_here) _ = try verifyFile(a, io, source, m.new_name, m.after);
    const before_saved = try verifyFile(a, io, journal, old_slot, m.before);
    const after_saved = try verifyFile(a, io, journal, new_slot, m.after);
    if (before_here == before_saved or after_here == after_saved) return error.RecoveryConflict;
    if (current_old != null and !before_here and !(std.mem.eql(u8, m.old_name, m.new_name) and after_here)) return error.RecoveryConflict;
    if (current_new != null and !after_here and !(std.mem.eql(u8, m.old_name, m.new_name) and before_here)) return error.RecoveryConflict;
}
fn applyPair(io: std.Io, source: Dir, journal: Dir, m: Metadata, old_slot: []const u8, new_slot: []const u8, forward: bool) !void {
    if (forward) {
        // Already installed new metadata can share the receipt's old path.
        if (!matches(try stat(io, journal, old_slot), m.before.inode, .file)) try move(io, source, m.old_name, journal, old_slot, m.before.inode, .file);
        try move(io, journal, new_slot, source, m.new_name, m.after.inode, .file);
    } else {
        if (!matches(try stat(io, journal, new_slot), m.after.inode, .file)) try move(io, source, m.new_name, journal, new_slot, m.after.inode, .file);
        try move(io, journal, old_slot, source, m.old_name, m.before.inode, .file);
    }
}
fn portableSlot(io: std.Io, dir: Dir, path: []const u8) !void {
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |entry| {
        count += 1;
        if (count > 100_000) return error.ResourceLimit;
        if (std.ascii.eqlIgnoreCase(entry.name, path) and !std.mem.eql(u8, entry.name, path)) return error.RecoveryConflict;
    }
}
/// All validation/allocation precedes mutation. Both directions are restartable after
/// every individual rename, including a syscall which succeeded but reported failure.
pub fn apply(a: A, io: std.Io, versions: Dir, journal: Dir, p: Plan, forward: bool) !void {
    try portableSlot(io, versions, p.old_name);
    try portableSlot(io, versions, p.new_name);
    const old = try stat(io, versions, p.old_name);
    const new = try stat(io, versions, p.new_name);
    if ((old != null and new != null) or (old == null and new == null)) return error.RecoveryConflict;
    const current_name = if (old != null) p.old_name else p.new_name;
    if (!matches(old orelse new, p.directory_inode, .directory)) return error.RecoveryConflict;
    const source = try tree.child(io, versions, current_name, false);
    defer source.close(io);
    try portableSlot(io, source, p.document.old_name);
    try portableSlot(io, source, p.document.new_name);
    try portableSlot(io, source, p.old_jar);
    try portableSlot(io, source, p.new_jar);
    try verifyPair(a, io, source, journal, p.document, "old-document", "new-document");
    if (p.receipt) |r| try verifyPair(a, io, source, journal, r, "old-receipt", "new-receipt");
    if (p.jar_inode) |inode| {
        const oj = try stat(io, source, p.old_jar);
        const nj = try stat(io, source, p.new_jar);
        if (!((matches(oj, inode, .file) and nj == null) or (oj == null and matches(nj, inode, .file)))) return error.RecoveryConflict;
    }
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    try applyPair(io, source, journal, p.document, "old-document", "new-document", forward);
    if (p.receipt) |r| try applyPair(io, source, journal, r, "old-receipt", "new-receipt", forward);
    if (p.jar_inode) |inode| try move(io, source, if (forward) p.old_jar else p.new_jar, source, if (forward) p.new_jar else p.old_jar, inode, .file);
    try move(io, versions, if (forward) p.old_name else p.new_name, versions, if (forward) p.new_name else p.old_name, p.directory_inode, .directory);
}
pub fn verifyCompleted(a: A, io: std.Io, versions: Dir, p: Plan, forward: bool) !void {
    const target = if (forward) p.new_name else p.old_name;
    const absent = if (forward) p.old_name else p.new_name;
    try portableSlot(io, versions, target);
    try portableSlot(io, versions, absent);
    if (try stat(io, versions, absent) != null or !matches(try stat(io, versions, target), p.directory_inode, .directory)) return error.RecoveryConflict;
    const source = try tree.child(io, versions, target, false);
    defer source.close(io);
    const doc = p.document;
    if (!try verifyFile(a, io, source, if (forward) doc.new_name else doc.old_name, if (forward) doc.after else doc.before)) return error.RecoveryConflict;
    if (p.receipt) |r| if (!try verifyFile(a, io, source, r.old_name, if (forward) r.after else r.before)) return error.RecoveryConflict;
    if (p.jar_inode) |inode| if (!matches(try stat(io, source, if (forward) p.new_jar else p.old_jar), inode, .file)) return error.RecoveryConflict;
}
/// Tombstone first: once this is durable, recovery must never reverse this journal.
/// Cleanup only knows these fixed metadata files; no recursive deletion is performed.
pub fn finish(io: std.Io, vela: Dir, journal: Dir, journal_name: []const u8) !void {
    if (try stat(io, journal, "manifest.json") != null) {
        try journal.renamePreserve("manifest.json", journal, "finished.json", io);
    }
    // A previous attempt may have renamed the marker but failed to sync it.
    // Make that marker durable before removing any retained originals.
    try tree.syncDir(io, journal);
    for ([_][]const u8{ "old-document", "new-document", "old-receipt", "new-receipt", "prepared.json" }) |path| {
        journal.deleteFile(io, path) catch |err| if (err != error.FileNotFound) return err;
    }
    try tree.syncDir(io, journal);
    journal.deleteFile(io, "finished.json") catch |err| if (err != error.FileNotFound) return err;
    try tree.syncDir(io, journal);
    try vela.deleteDir(io, journal_name);
    try tree.syncDir(io, vela);
}

test "rename journal retries sync before accepting existing target or deleting originals" {
    if (!tree.directory_sync_supported) return error.SkipZigTest;
    const Probe = struct {
        var fail: bool = false;
        fn sync(context: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
            if (fail) return error.InputOutput;
            return std.testing.io.vtable.fileSync(context, file);
        }
    };
    const real_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(real_io, .{ .sub_path = "old", .data = "payload" });
    const inode = (try tmp.dir.statFile(real_io, "old", .{})).inode;
    var vtable = real_io.vtable.*;
    vtable.fileSync = Probe.sync;
    const io: std.Io = .{ .userdata = real_io.userdata, .vtable = &vtable };
    Probe.fail = true;
    defer Probe.fail = false;
    try std.testing.expectError(error.InputOutput, move(io, tmp.dir, "old", tmp.dir, "new", inode, .file));
    // The rename happened; the second attempt must still require a successful sync.
    try std.testing.expectError(error.InputOutput, move(io, tmp.dir, "old", tmp.dir, "new", inode, .file));
    Probe.fail = false;
    try move(io, tmp.dir, "old", tmp.dir, "new", inode, .file);
    try tmp.dir.createDirPath(real_io, "journal");
    const journal = try tmp.dir.openDir(real_io, "journal", .{ .iterate = true });
    defer journal.close(real_io);
    try journal.writeFile(real_io, .{ .sub_path = "manifest.json", .data = "intent" });
    try journal.writeFile(real_io, .{ .sub_path = "old-document", .data = "original" });
    Probe.fail = true;
    try std.testing.expectError(error.InputOutput, finish(io, tmp.dir, journal, "journal"));
    try journal.access(real_io, "finished.json", .{});
    try std.testing.expectError(error.InputOutput, finish(io, tmp.dir, journal, "journal"));
    try journal.access(real_io, "old-document", .{});
    Probe.fail = false;
    try finish(io, tmp.dir, journal, "journal");
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(real_io, "journal", .{}));
}

const std = @import("std");
const w = @import("worlds.zig");
const instances = @import("instances.zig");
const config = @import("config.zig");
const compression = @import("nbt_compression");
const a = std.testing.allocator;
const io = std.testing.io;
const one: config.Instance = .{ .id = "one", .name = "One", .minecraft_version = "1.21" };
const two: config.Instance = .{ .id = "two", .name = "Two", .minecraft_version = "1.21" };
const plain = "\x0a\x00\x00\x0a\x00\x04Data\x08\x00\x09LevelName\x00\x05Hello\x04\x00\x0aLastPlayed\x00\x00\x00\x00\x00\x00\x03\xe8\x03\x00\x08GameType\x00\x00\x00\x01\x00\x00";
fn write(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
    const f = try dir.createFile(io, path, .{});
    defer f.close(io);
    try f.writePositionalAll(io, data, 0);
}
fn fixturePaths(tmp: std.testing.TmpDir) !instances.Paths {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    return instances.Paths.init(a, io, buf[0..len]);
}
test "world metadata Java gzip CRC and malformed documents" {
    const gzip = try compression.compress(a, plain, .gzip, 1024 * 1024);
    defer a.free(gzip);
    var m = try w.parseLevelDat(a, gzip);
    defer m.deinit(a);
    try std.testing.expectEqualStrings("Hello", m.level_name.?);
    try std.testing.expectEqual(@as(i64, 1000), m.last_played_ms.?);
    try std.testing.expectEqual(@as(i32, 1), m.game_type.?);
    gzip[gzip.len - 8] ^= 1;
    try std.testing.expectError(error.InvalidGzipChecksum, w.parseLevelDat(a, gzip));
    try std.testing.expectError(error.InvalidLevelDat, w.parseLevelDat(a, "corrupt"));
}
test "world listing normal missing corrupt and portable names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    const gzip = try compression.compress(a, plain, .gzip, 1024 * 1024);
    defer a.free(gzip);
    try write(tmp.dir, ".minecraft/versions/One/saves/Normal/level.dat", gzip);
    try write(tmp.dir, ".minecraft/versions/One/saves/Corrupt/level.dat", "invalid");
    try write(tmp.dir, ".minecraft/versions/One/saves/Missing/region/data", "world");
    var result = try w.list(a, io, &paths, one, null, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.items.len);
    var valid: usize = 0;
    var corrupt: usize = 0;
    var missing: usize = 0;
    for (result.items) |world| switch (world.metadata_status) {
        .valid => valid += 1,
        .corrupt => corrupt += 1,
        .missing => missing += 1,
        else => return error.UnexpectedStatus,
    };
    try std.testing.expectEqual(@as(usize, 1), valid);
    try std.testing.expectEqual(@as(usize, 1), corrupt);
    try std.testing.expectEqual(@as(usize, 1), missing);
    for ([_][]const u8{ "../escape", "CON", "x/y", "x\\y", ".vela-worlds", "" }) |bad| try std.testing.expect(!w.validFolder(bad));
}
test "world backup restore copy rename delete recovery and guards" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    try write(tmp.dir, ".minecraft/versions/One/saves/World/region/data", "world payload");
    const ref: w.WorldRef = .{ .instance = one, .folder = "World" };
    const target: w.WorldRef = .{ .instance = two, .folder = "Copied" };
    try std.testing.expectError(error.InstanceRunning, w.copy(a, io, &paths, ref, target, .{ .guard = .{ .running_ids = &.{"one"} } }));
    try std.testing.expectError(error.InstanceRunning, w.copy(a, io, &paths, ref, target, .{ .guard = .{ .running_ids = &.{"two"} } }));
    var backup = try w.backup(a, io, &paths, ref, .{});
    defer backup.deinit();
    try std.testing.expectEqual(.committed, backup.state);
    var copied = try w.copy(a, io, &paths, ref, target, .{});
    defer copied.deinit();
    try std.testing.expectEqual(.committed, copied.state);
    try std.testing.expectError(error.ConfirmationRequired, w.copy(a, io, &paths, ref, target, .{}));
    var renamed = try w.rename(a, io, &paths, target, "Renamed", .{});
    defer renamed.deinit();
    try std.testing.expectEqual(.committed, renamed.state);
    try std.testing.expectError(error.ConfirmationRequired, w.delete(a, io, &paths, ref, .{}));
    var deleted = try w.delete(a, io, &paths, ref, .{ .confirmed_destructive = true });
    defer deleted.deinit();
    try std.testing.expectEqual(.committed, deleted.state);
    var restored = try w.restore(a, io, &paths, .{ .instance = one, .id = deleted.recovery_id }, ref, .{});
    defer restored.deinit();
    try std.testing.expectEqual(.committed, restored.state);
}

test "display rename preserves full document and UTF-8 plus recovery" {
    const nbt = @import("nbt");
    const gzip = try compression.compress(a, plain, .gzip, 1024 * 1024);
    defer a.free(gzip);
    const changed = try @import("worlds_metadata.zig").rewrite(a, gzip, "M\xc3\xbcnchen");
    defer a.free(changed);
    var opts: nbt.Options = .java;
    opts.compression = .gzip;
    opts.reject_trailing_bytes = true;
    var doc = try nbt.parse(a, changed, opts);
    defer doc.deinit(a);
    const data = doc.root.compound.get("Data").?.compound;
    try std.testing.expectEqualStrings("M\xc3\xbcnchen", data.get("LevelName").?.string);
    try std.testing.expectEqual(@as(i32, 1), data.get("GameType").?.int);
    try std.testing.expectEqual(@as(i64, 1000), data.get("LastPlayed").?.long);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    try write(tmp.dir, ".minecraft/versions/One/saves/World/level.dat", gzip);
    const ref: w.WorldRef = .{ .instance = one, .folder = "World" };
    var outcome = try w.renameDisplayName(a, io, &paths, ref, "M\xc3\xbcnchen", .{ .confirmed_destructive = true });
    defer outcome.deinit();
    try std.testing.expectEqual(.committed, outcome.state);
    var listing = try w.list(a, io, &paths, one, null, .{});
    defer listing.deinit();
    try std.testing.expectEqualStrings("M\xc3\xbcnchen", listing.items[0].metadata.level_name.?);
    var restored = try w.restore(a, io, &paths, .{ .instance = one, .id = outcome.recovery_id }, .{ .instance = one, .folder = "Original" }, .{});
    defer restored.deinit();
    try std.testing.expectEqual(.committed, restored.state);
}
const Cancel = struct {
    value: bool = false,
    fn canceled(p: ?*anyopaque) bool {
        return (@as(*Cancel, @ptrCast(@alignCast(p.?)))).value;
    }
    fn progress(p: ?*anyopaque, _: usize, _: u64) void {
        (@as(*Cancel, @ptrCast(@alignCast(p.?)))).value = true;
    }
    fn committed(p: ?*anyopaque) void {
        (@as(*Cancel, @ptrCast(@alignCast(p.?)))).value = true;
    }
};
test "cancel bounds unsafe links and integrity failure leave worlds untouched" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    try write(tmp.dir, ".minecraft/versions/One/saves/World/region/data", "world payload");
    const ref: w.WorldRef = .{ .instance = one, .folder = "World" };
    const target: w.WorldRef = .{ .instance = two, .folder = "Target" };
    var cancel: Cancel = .{};
    try std.testing.expectError(error.Canceled, w.copy(a, io, &paths, ref, target, .{ .hooks = .{ .context = &cancel, .canceled = Cancel.canceled, .progress = Cancel.progress } }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".minecraft/versions/Two/saves/Target", .{}));
    try std.testing.expectError(error.ResourceLimit, w.backup(a, io, &paths, ref, .{ .limits = .{ .max_bytes = 1 } }));
    try std.testing.expectError(error.ResourceLimit, w.backup(a, io, &paths, ref, .{ .limits = .{ .max_files = 1 } }));
    try std.testing.expectError(error.ResourceLimit, w.backup(a, io, &paths, ref, .{ .limits = .{ .max_depth = 0 } }));
    var backed = try w.backup(a, io, &paths, ref, .{});
    defer backed.deinit();
    const corrupt_path = try std.fmt.allocPrint(a, ".minecraft/versions/One/saves/.vela-worlds/{s}/payload/region/data", .{backed.recovery_id});
    defer a.free(corrupt_path);
    try write(tmp.dir, corrupt_path, "tampered");
    try std.testing.expectError(error.IntegrityMismatch, w.restore(a, io, &paths, .{ .instance = one, .id = backed.recovery_id }, target, .{}));
    try tmp.dir.symLink(io, "region/data", ".minecraft/versions/One/saves/World/link", .{});
    try std.testing.expectError(error.UnsafeFileType, w.backup(a, io, &paths, ref, .{}));
}
test "late cancellation preserves committed success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    try write(tmp.dir, ".minecraft/versions/One/saves/World/data", "world payload");
    var cancel: Cancel = .{};
    var result = try w.copy(a, io, &paths, .{ .instance = one, .folder = "World" }, .{ .instance = two, .folder = "Target" }, .{ .hooks = .{ .context = &cancel, .canceled = Cancel.canceled, .committed = Cancel.committed } });
    defer result.deinit();
    try std.testing.expectEqual(.committed, result.state);
    try std.testing.expect(cancel.value);
    _ = try tmp.dir.statFile(io, ".minecraft/versions/Two/saves/Target/data", .{});
}
fn failBackup(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    try write(tmp.dir, ".minecraft/versions/One/saves/World/data", "world payload");
    var outcome = try w.backup(allocator, io, &paths, .{ .instance = one, .folder = "World" }, .{});
    defer outcome.deinit();
}
test "world backup cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(a, failBackup, .{});
}

test "confirmed overwrite retains previous world and case collisions fail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    try write(tmp.dir, ".minecraft/versions/One/saves/World/data", "new");
    try write(tmp.dir, ".minecraft/versions/Two/saves/Target/data", "old");
    const ref: w.WorldRef = .{ .instance = one, .folder = "World" };
    const target: w.WorldRef = .{ .instance = two, .folder = "Target" };
    var overwrite = try w.copy(a, io, &paths, ref, target, .{ .confirmed_destructive = true });
    defer overwrite.deinit();
    try std.testing.expectEqual(.committed, overwrite.state);
    var recovery = try w.restore(a, io, &paths, .{ .instance = two, .id = overwrite.recovery_id, .part = .overwritten }, .{ .instance = two, .folder = "Old" }, .{});
    defer recovery.deinit();
    const file = try tmp.dir.openFile(io, ".minecraft/versions/Two/saves/Old/data", .{});
    defer file.close(io);
    var buffer: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try file.readPositionalAll(io, &buffer, 0));
    try std.testing.expectEqualStrings("old", &buffer);
    try std.testing.expectError(error.NameCollision, w.copy(a, io, &paths, ref, .{ .instance = two, .folder = "target" }, .{ .confirmed_destructive = true }));
}

test "display-name rewrite preserves unknown mod compounds lists and arrays" {
    const nbt = @import("nbt");
    var mod_entries = [_]nbt.Entry{
        .{ .name = @constCast("ints"), .value = .{ .int_array = @constCast(&[_]i32{ -9, 42 }) } },
        .{ .name = @constCast("bytes"), .value = .{ .byte_array = @constCast(&[_]u8{ 0, 255, 1 }) } },
        .{ .name = @constCast("list"), .value = .{ .list = .{ .element_type = .long, .items = @constCast(&[_]nbt.Tag{ .{ .long = -1 }, .{ .long = std.math.maxInt(i64) } }) } } },
    };
    var data_entries = [_]nbt.Entry{
        .{ .name = @constCast("LevelName"), .value = .{ .string = @constCast("Hello") } },
        .{ .name = @constCast("MyMod"), .value = .{ .compound = .{ .entries = &mod_entries } } },
    };
    var root_entries = [_]nbt.Entry{
        .{ .name = @constCast("Data"), .value = .{ .compound = .{ .entries = &data_entries } } },
        .{ .name = @constCast("UnknownRoot"), .value = .{ .double = -123.5 } },
    };
    const source: nbt.Document = .{ .name = @constCast("root"), .root = .{ .compound = .{ .entries = &root_entries } } };
    const original = try nbt.serialize(a, source, .java);
    defer a.free(original);
    var gzip_options: nbt.Options = .java;
    gzip_options.compression = .gzip;
    const gzip = try nbt.serialize(a, source, gzip_options);
    defer a.free(gzip);
    const changed = try @import("worlds_metadata.zig").rewrite(a, gzip, "New \xf0\x9f\x8c\x8d");
    defer a.free(changed);
    var document = try nbt.parse(a, changed, gzip_options);
    defer document.deinit(a);
    const level_name = document.root.compound.getMut("Data").?.compound.getMut("LevelName").?;
    level_name.deinit(a);
    level_name.* = .{ .string = try a.dupe(u8, "Hello") };
    const roundtrip = try nbt.serialize(a, document, .java);
    defer a.free(roundtrip);
    try std.testing.expectEqualSlices(u8, original, roundtrip);
}
fn pngChunk(out: *std.Io.Writer.Allocating, kind: []const u8, data: []const u8) !void {
    try out.writer.writeInt(u32, @intCast(data.len), .big);
    try out.writer.writeAll(kind);
    try out.writer.writeAll(data);
    var crc: std.hash.crc.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try out.writer.writeInt(u32, crc.final(), .big);
}
test "world preview uses validated real icon path and rejects corrupted CRC" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    var png: std.Io.Writer.Allocating = .init(a);
    defer png.deinit();
    try png.writer.writeAll("\x89PNG\r\n\x1a\n");
    try pngChunk(&png, "IHDR", "\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00");
    // Real one-pixel RGBA scanline, compressed by the existing zlib library.
    const pixels = try compression.compress(a, "\x00\xff\x00\x00\xff", .zlib, 1024);
    defer a.free(pixels);
    try pngChunk(&png, "IDAT", pixels);
    try pngChunk(&png, "IEND", "");
    try write(tmp.dir, ".minecraft/versions/One/saves/World/icon.png", png.written());
    var result = try w.list(a, io, &paths, one, null, .{});
    defer result.deinit();
    const expected = try std.fs.path.join(a, &.{ paths.minecraft, "versions", "One", "saves", "World", "icon.png" });
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, result.items[0].icon_path.?);
    png.written()[png.written().len - 1] ^= 1;
    try write(tmp.dir, ".minecraft/versions/One/saves/World/icon.png", png.written());
    var invalid = try w.list(a, io, &paths, one, null, .{});
    defer invalid.deinit();
    try std.testing.expect(invalid.items[0].icon_path == null);
}

test "recovery enumeration survives restart and exposes overwritten records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    try write(tmp.dir, ".minecraft/versions/One/saves/World/data", "new");
    try write(tmp.dir, ".minecraft/versions/Two/saves/Target/data", "old");
    var operation = try w.copy(a, io, &paths, .{ .instance = one, .folder = "World" }, .{ .instance = two, .folder = "Target" }, .{ .confirmed_destructive = true });
    defer operation.deinit();
    var items = try w.listBackups(a, io, &paths, two, .{});
    defer items.deinit();
    try std.testing.expectEqual(@as(usize, 2), items.items.len);
    var originals: usize = 0;
    var overwritten: usize = 0;
    for (items.items) |item| {
        try std.testing.expectEqualStrings(operation.recovery_id, item.id);
        try std.testing.expect(item.manifest_error == null);
        switch (item.part) {
            .original => originals += 1,
            .overwritten => overwritten += 1,
        }
    }
    try std.testing.expectEqual(@as(usize, 1), originals);
    try std.testing.expectEqual(@as(usize, 1), overwritten);
}
const Fault = struct {
    const Mode = enum { candidate_fail, rollback_fail, publish_ambiguous, remove_ambiguous, candidate_ambiguous, sync_after_commit };
    var mode: Mode = .candidate_fail;
    var candidate_committed: bool = false;
    fn rename(userdata: ?*anyopaque, old: std.Io.Dir, old_name: []const u8, new: std.Io.Dir, new_name: []const u8) std.Io.Dir.RenamePreserveError!void {
        if (std.mem.eql(u8, old_name, "candidate")) {
            if (mode == .candidate_fail or mode == .rollback_fail) return error.NoSpaceLeft;
            try io.vtable.dirRenamePreserve(userdata, old, old_name, new, new_name);
            candidate_committed = true;
            if (mode == .candidate_ambiguous) return error.Unexpected;
            return;
        }
        if (mode == .rollback_fail and std.mem.eql(u8, old_name, "removed")) return error.AccessDenied;
        try io.vtable.dirRenamePreserve(userdata, old, old_name, new, new_name);
        if ((mode == .publish_ambiguous and std.mem.startsWith(u8, old_name, ".stage-")) or (mode == .remove_ambiguous and std.mem.eql(u8, new_name, "removed"))) return error.Unexpected;
    }
    fn sync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
        if (mode == .sync_after_commit and candidate_committed) return error.Unexpected;
        return io.vtable.fileSync(userdata, file);
    }
};
test "rename failures rollback or explicitly retain uncertain committed state" {
    inline for (@typeInfo(Fault.Mode).@"enum".fields) |field| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var paths = try fixturePaths(tmp);
        defer paths.deinit();
        try write(tmp.dir, ".minecraft/versions/One/saves/World/data", "world payload");
        Fault.mode = @enumFromInt(field.value);
        Fault.candidate_committed = false;
        var table = io.vtable.*;
        table.dirRenamePreserve = Fault.rename;
        table.fileSync = Fault.sync;
        const injected: std.Io = .{ .userdata = io.userdata, .vtable = &table };
        var result = try w.renameFolder(a, injected, &paths, .{ .instance = one, .folder = "World" }, "New", .{});
        defer result.deinit();
        try std.testing.expectEqual(if (Fault.mode == .candidate_fail) @TypeOf(result.state).rolled_back else @TypeOf(result.state).uncertain, result.state);
        try std.testing.expect(result.cause != null);
        if (Fault.mode == .candidate_fail or Fault.mode == .publish_ambiguous) _ = try tmp.dir.statFile(io, ".minecraft/versions/One/saves/World/data", .{});
        if (Fault.mode == .candidate_ambiguous or Fault.mode == .sync_after_commit) _ = try tmp.dir.statFile(io, ".minecraft/versions/One/saves/New/data", .{});
        const recovery = try std.fs.path.join(a, &.{ result.recovery_directory, "payload", "data" });
        defer a.free(recovery);
        var recovery_file = try std.Io.Dir.openFileAbsolute(io, recovery, .{});
        recovery_file.close(io);
    }
}
test "file-sync failure stays fatal before commit on every platform" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    try write(tmp.dir, ".minecraft/versions/One/saves/World/data", "original");
    const Failure = struct {
        fn sync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
            const stat = file.stat(io) catch return error.Unexpected;
            if (stat.kind == .file) return error.Unexpected;
            return io.vtable.fileSync(userdata, file);
        }
    };
    var table = io.vtable.*;
    table.fileSync = Failure.sync;
    const injected: std.Io = .{ .userdata = io.userdata, .vtable = &table };
    try std.testing.expectError(error.Unexpected, w.backup(a, injected, &paths, .{ .instance = one, .folder = "World" }, .{}));
    _ = try tmp.dir.statFile(io, ".minecraft/versions/One/saves/World/data", .{});
    var recovery = try w.listBackups(a, io, &paths, one, .{});
    defer recovery.deinit();
    try std.testing.expectEqual(@as(usize, 0), recovery.items.len);
}

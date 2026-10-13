const std = @import("std");
const w = @import("worlds.zig");
const instances = @import("instances.zig");
const instance_leases = @import("instance_leases.zig");
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
    var coordinator = instance_leases.Coordinator.init(io);
    const gzip = try compression.compress(a, plain, .gzip, 1024 * 1024);
    defer a.free(gzip);
    try write(tmp.dir, ".minecraft/versions/One/saves/Normal/level.dat", gzip);
    try write(tmp.dir, ".minecraft/versions/One/saves/Corrupt/level.dat", "invalid");
    try write(tmp.dir, ".minecraft/versions/One/saves/Missing/region/data", "world");
    var result = try w.list(a, io, &paths, one, null, .{ .scope = coordinator.worldScope(3) });
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
    var coordinator = instance_leases.Coordinator.init(io);
    try write(tmp.dir, ".minecraft/versions/One/saves/World/region/data", "world payload");
    try tmp.dir.createDirPath(io, ".minecraft/versions/Two");
    const ref: w.WorldRef = .{ .instance = one, .folder = "World" };
    const target: w.WorldRef = .{ .instance = two, .folder = "Copied" };
    try std.testing.expectError(error.InstanceRunning, w.copy(a, io, &paths, ref, target, .{ .scope = coordinator.worldScope(3), .guard = .{ .running_ids = &.{"one"} } }));
    try std.testing.expectError(error.InstanceRunning, w.copy(a, io, &paths, ref, target, .{ .scope = coordinator.worldScope(3), .guard = .{ .running_ids = &.{"two"} } }));
    var backup = try w.backup(a, io, &paths, ref, .{ .scope = coordinator.worldScope(3) });
    defer backup.deinit();
    try std.testing.expectEqual(.committed, backup.state);
    var copied = try w.copy(a, io, &paths, ref, target, .{ .scope = coordinator.worldScope(3) });
    defer copied.deinit();
    try std.testing.expectEqual(.committed, copied.state);
    try std.testing.expectError(error.ConfirmationRequired, w.copy(a, io, &paths, ref, target, .{ .scope = coordinator.worldScope(3) }));
    var renamed = try w.rename(a, io, &paths, target, "Renamed", .{ .scope = coordinator.worldScope(3) });
    defer renamed.deinit();
    try std.testing.expectEqual(.committed, renamed.state);
    try std.testing.expectError(error.ConfirmationRequired, w.delete(a, io, &paths, ref, .{ .scope = coordinator.worldScope(3) }));
    var deleted = try w.delete(a, io, &paths, ref, .{ .scope = coordinator.worldScope(3), .confirmed_destructive = true });
    defer deleted.deinit();
    try std.testing.expectEqual(.committed, deleted.state);
    var restored = try w.restore(a, io, &paths, .{ .instance = one, .id = deleted.recovery_id }, ref, .{ .scope = coordinator.worldScope(3) });
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
    var coordinator = instance_leases.Coordinator.init(io);
    try write(tmp.dir, ".minecraft/versions/One/saves/World/level.dat", gzip);
    const ref: w.WorldRef = .{ .instance = one, .folder = "World" };
    var outcome = try w.renameDisplayName(a, io, &paths, ref, "M\xc3\xbcnchen", .{ .scope = coordinator.worldScope(3), .confirmed_destructive = true });
    defer outcome.deinit();
    try std.testing.expectEqual(.committed, outcome.state);
    var listing = try w.list(a, io, &paths, one, null, .{ .scope = coordinator.worldScope(3) });
    defer listing.deinit();
    try std.testing.expectEqualStrings("M\xc3\xbcnchen", listing.items[0].metadata.level_name.?);
    var restored = try w.restore(a, io, &paths, .{ .instance = one, .id = outcome.recovery_id }, .{ .instance = one, .folder = "Original" }, .{ .scope = coordinator.worldScope(3) });
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
    var coordinator = instance_leases.Coordinator.init(io);
    try write(tmp.dir, ".minecraft/versions/One/saves/World/region/data", "world payload");
    try tmp.dir.createDirPath(io, ".minecraft/versions/Two");
    const ref: w.WorldRef = .{ .instance = one, .folder = "World" };
    const target: w.WorldRef = .{ .instance = two, .folder = "Target" };
    var cancel: Cancel = .{};
    try std.testing.expectError(error.Canceled, w.copy(a, io, &paths, ref, target, .{ .scope = coordinator.worldScope(3), .hooks = .{ .context = &cancel, .canceled = Cancel.canceled, .progress = Cancel.progress } }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".minecraft/versions/Two/saves/Target", .{}));
    try std.testing.expectError(error.ResourceLimit, w.backup(a, io, &paths, ref, .{ .scope = coordinator.worldScope(3), .limits = .{ .max_bytes = 1 } }));
    try std.testing.expectError(error.ResourceLimit, w.backup(a, io, &paths, ref, .{ .scope = coordinator.worldScope(3), .limits = .{ .max_files = 1 } }));
    try std.testing.expectError(error.ResourceLimit, w.backup(a, io, &paths, ref, .{ .scope = coordinator.worldScope(3), .limits = .{ .max_depth = 0 } }));
    var backed = try w.backup(a, io, &paths, ref, .{ .scope = coordinator.worldScope(3) });
    defer backed.deinit();
    const corrupt_path = try std.fmt.allocPrint(a, ".minecraft/versions/One/saves/.vela-worlds/{s}/payload/region/data", .{backed.recovery_id});
    defer a.free(corrupt_path);
    try write(tmp.dir, corrupt_path, "tampered");
    try std.testing.expectError(error.IntegrityMismatch, w.restore(a, io, &paths, .{ .instance = one, .id = backed.recovery_id }, target, .{ .scope = coordinator.worldScope(3) }));
    try tmp.dir.symLink(io, "region/data", ".minecraft/versions/One/saves/World/link", .{});
    try std.testing.expectError(error.UnsafeFileType, w.backup(a, io, &paths, ref, .{ .scope = coordinator.worldScope(3) }));
}
test "late cancellation preserves committed success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    var coordinator = instance_leases.Coordinator.init(io);
    try write(tmp.dir, ".minecraft/versions/One/saves/World/data", "world payload");
    try tmp.dir.createDirPath(io, ".minecraft/versions/Two");
    var cancel: Cancel = .{};
    var result = try w.copy(a, io, &paths, .{ .instance = one, .folder = "World" }, .{ .instance = two, .folder = "Target" }, .{ .scope = coordinator.worldScope(3), .hooks = .{ .context = &cancel, .canceled = Cancel.canceled, .committed = Cancel.committed } });
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
    var coordinator = instance_leases.Coordinator.init(io);
    try write(tmp.dir, ".minecraft/versions/One/saves/World/data", "world payload");
    var outcome = try w.backup(allocator, io, &paths, .{ .instance = one, .folder = "World" }, .{ .scope = coordinator.worldScope(3) });
    defer outcome.deinit();
}
test "world backup cleans up every allocation failure" {
    try @import("test_allocations").checkAllAllocationFailures(a, failBackup, .{});
}

test "confirmed overwrite retains previous world and case collisions fail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    var coordinator = instance_leases.Coordinator.init(io);
    try write(tmp.dir, ".minecraft/versions/One/saves/World/data", "new");
    try write(tmp.dir, ".minecraft/versions/Two/saves/Target/data", "old");
    const ref: w.WorldRef = .{ .instance = one, .folder = "World" };
    const target: w.WorldRef = .{ .instance = two, .folder = "Target" };
    var overwrite = try w.copy(a, io, &paths, ref, target, .{ .scope = coordinator.worldScope(3), .confirmed_destructive = true });
    defer overwrite.deinit();
    try std.testing.expectEqual(.committed, overwrite.state);
    var recovery = try w.restore(a, io, &paths, .{ .instance = two, .id = overwrite.recovery_id, .part = .overwritten }, .{ .instance = two, .folder = "Old" }, .{ .scope = coordinator.worldScope(3) });
    defer recovery.deinit();
    const file = try tmp.dir.openFile(io, ".minecraft/versions/Two/saves/Old/data", .{});
    defer file.close(io);
    var buffer: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try file.readPositionalAll(io, &buffer, 0));
    try std.testing.expectEqualStrings("old", &buffer);
    try std.testing.expectError(error.NameCollision, w.copy(a, io, &paths, ref, .{ .instance = two, .folder = "target" }, .{ .scope = coordinator.worldScope(3), .confirmed_destructive = true }));
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
    var crc: std.hash.crc.@"CRC-32/ISO-HDLC" = .init();
    crc.update(kind);
    crc.update(data);
    try out.writer.writeInt(u32, crc.final(), .big);
}
test "world preview uses validated real icon path and rejects corrupted CRC" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    var coordinator = instance_leases.Coordinator.init(io);
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
    var result = try w.list(a, io, &paths, one, null, .{ .scope = coordinator.worldScope(3) });
    defer result.deinit();
    const expected = try std.fs.path.join(a, &.{ paths.minecraft, "versions", "One", "saves", "World", "icon.png" });
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, result.items[0].icon_path.?);
    png.written()[png.written().len - 1] ^= 1;
    try write(tmp.dir, ".minecraft/versions/One/saves/World/icon.png", png.written());
    var invalid = try w.list(a, io, &paths, one, null, .{ .scope = coordinator.worldScope(3) });
    defer invalid.deinit();
    try std.testing.expect(invalid.items[0].icon_path == null);
}

test "recovery enumeration survives restart and exposes overwritten records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    var coordinator = instance_leases.Coordinator.init(io);
    try write(tmp.dir, ".minecraft/versions/One/saves/World/data", "new");
    try write(tmp.dir, ".minecraft/versions/Two/saves/Target/data", "old");
    var operation = try w.copy(a, io, &paths, .{ .instance = one, .folder = "World" }, .{ .instance = two, .folder = "Target" }, .{ .scope = coordinator.worldScope(3), .confirmed_destructive = true });
    defer operation.deinit();
    var items = try w.listBackups(a, io, &paths, two, .{ .scope = coordinator.worldScope(3) });
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
    inline for (@typeInfo(Fault.Mode).@"enum".field_values) |value| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var paths = try fixturePaths(tmp);
        defer paths.deinit();
        var coordinator = instance_leases.Coordinator.init(io);
        try write(tmp.dir, ".minecraft/versions/One/saves/World/data", "world payload");
        Fault.mode = @fromBackingInt(@intCast(value));
        Fault.candidate_committed = false;
        var table = io.vtable.*;
        table.dirRenamePreserve = Fault.rename;
        table.fileSync = Fault.sync;
        const injected: std.Io = .{ .userdata = io.userdata, .vtable = &table };
        var result = try w.renameFolder(a, injected, &paths, .{ .instance = one, .folder = "World" }, "New", .{ .scope = coordinator.worldScope(3) });
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
    var coordinator = instance_leases.Coordinator.init(io);
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
    try std.testing.expectError(error.Unexpected, w.backup(a, injected, &paths, .{ .instance = one, .folder = "World" }, .{ .scope = coordinator.worldScope(3) }));
    _ = try tmp.dir.statFile(io, ".minecraft/versions/One/saves/World/data", .{});
    var recovery = try w.listBackups(a, io, &paths, one, .{ .scope = coordinator.worldScope(3) });
    defer recovery.deinit();
    try std.testing.expectEqual(@as(usize, 0), recovery.items.len);
}

// The injected Io retains the real userdata for every original vtable entry.
// This pointer is test instrumentation only; callers still supply their scope.
const LeaseIo = struct {
    coordinator: *instance_leases.Coordinator,
    source: []const u8 = "one",
    target: ?[]const u8 = null,
    calls: usize = 0,
    inspect: bool = false,
    failed: bool = false,
    guard_called: bool = false,
    var active: ?*LeaseIo = null;

    const OpenDir = @typeInfo(@typeInfo(@TypeOf(io.vtable.dirOpenDir)).pointer.child).@"fn";
    const OpenFile = @typeInfo(@typeInfo(@TypeOf(io.vtable.dirOpenFile)).pointer.child).@"fn";

    fn busy(self: *LeaseIo, id: []const u8) bool {
        self.coordinator.reserveLaunch(id) catch |err| return err == error.InstanceBusy;
        self.coordinator.releaseLaunch();
        self.coordinator.tick();
        return false;
    }
    fn observe() bool {
        const self = active.?;
        self.calls += 1;
        if (!self.inspect) return true;
        if (!w.transaction_gate.tryLock()) {
            self.failed = true;
            return false;
        }
        w.transaction_gate.unlock(io);
        if (!self.busy(self.source)) self.failed = true;
        if (self.target) |target| {
            if (!self.busy(target)) self.failed = true;
        }
        self.coordinator.reserveLaunch("unrelated") catch {
            self.failed = true;
            return false;
        };
        self.coordinator.releaseLaunch();
        self.coordinator.tick();
        return !self.failed;
    }
    fn openDir(userdata: ?*anyopaque, dir: OpenDir.param_types[1].?, path: OpenDir.param_types[2].?, options: OpenDir.param_types[3].?) OpenDir.return_type.? {
        if (!observe()) return error.Unexpected;
        return io.vtable.dirOpenDir(userdata, dir, path, options);
    }
    fn openFile(userdata: ?*anyopaque, dir: OpenFile.param_types[1].?, path: OpenFile.param_types[2].?, options: OpenFile.param_types[3].?) OpenFile.return_type.? {
        if (!observe()) return error.Unexpected;
        return io.vtable.dirOpenFile(userdata, dir, path, options);
    }
    fn rename(userdata: ?*anyopaque, old: std.Io.Dir, old_name: []const u8, new: std.Io.Dir, new_name: []const u8) std.Io.Dir.RenamePreserveError!void {
        if (!observe()) return error.Unexpected;
        return io.vtable.dirRenamePreserve(userdata, old, old_name, new, new_name);
    }
    fn sync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
        if (!observe()) return error.Unexpected;
        return io.vtable.fileSync(userdata, file);
    }
    fn dynamicGuard(context: ?*anyopaque, _: []const u8) bool {
        const self: *LeaseIo = @ptrCast(@alignCast(context.?));
        self.guard_called = true;
        return false;
    }
    fn expectObserved(self: *LeaseIo) !void {
        try std.testing.expect(self.calls > 0);
        try std.testing.expect(!self.failed);
        self.calls = 0;
    }
};

fn expectDeniedBeforeFilesystem(expected: anyerror, injected: std.Io, paths: *instances.Paths, options: w.Options) !void {
    const source: w.WorldRef = .{ .instance = one, .folder = "World" };
    const target: w.WorldRef = .{ .instance = two, .folder = "Target" };
    try std.testing.expectError(expected, w.list(a, injected, paths, one, null, options));
    try std.testing.expectError(expected, w.listBackups(a, injected, paths, one, options));
    try std.testing.expectError(expected, w.backup(a, injected, paths, source, options));
    try std.testing.expectError(expected, w.copy(a, injected, paths, source, target, options));
    try std.testing.expectError(expected, w.restore(a, injected, paths, .{ .instance = one, .id = "00000000000000000000000000000000" }, target, options));
    try std.testing.expectError(expected, w.rename(a, injected, paths, source, "Renamed", options));
    try std.testing.expectError(expected, w.renameFolder(a, injected, paths, source, "Renamed", options));
    try std.testing.expectError(expected, w.renameDisplayName(a, injected, paths, source, "New name", options));
    try std.testing.expectError(expected, w.delete(a, injected, paths, source, options));
}

test "missing target copy and restore do not create instance namespaces" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    var coordinator = instance_leases.Coordinator.init(io);
    try write(tmp.dir, ".minecraft/versions/One/saves/World/data", "world payload");
    const source: w.WorldRef = .{ .instance = one, .folder = "World" };
    const target: w.WorldRef = .{ .instance = two, .folder = "Target" };
    var backup = try w.backup(a, io, &paths, source, .{ .scope = coordinator.worldScope(3) });
    defer backup.deinit();
    try std.testing.expectError(error.FileNotFound, w.copy(a, io, &paths, source, target, .{ .scope = coordinator.worldScope(3) }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".minecraft/versions/Two", .{}));
    try std.testing.expectError(error.FileNotFound, w.restore(a, io, &paths, .{ .instance = one, .id = backup.recovery_id }, target, .{ .scope = coordinator.worldScope(3) }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".minecraft/versions/Two", .{}));
    _ = try tmp.dir.statFile(io, ".minecraft/versions/One/saves/World/data", .{});
    for ([_][]const u8{ one.id, two.id }) |id| {
        try coordinator.reserveLaunch(id);
        coordinator.releaseLaunch();
        coordinator.tick();
    }
}

test "existing target without saves admits copy and restore" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    var coordinator = instance_leases.Coordinator.init(io);
    try write(tmp.dir, ".minecraft/versions/One/saves/World/data", "world payload");
    try tmp.dir.createDirPath(io, ".minecraft/versions/Two");
    try tmp.dir.createDirPath(io, ".minecraft/versions/Three");
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".minecraft/versions/Two/saves", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".minecraft/versions/Three/saves", .{}));
    const three: config.Instance = .{ .id = "three", .name = "Three", .minecraft_version = "1.21" };
    const source: w.WorldRef = .{ .instance = one, .folder = "World" };
    var backup = try w.backup(a, io, &paths, source, .{ .scope = coordinator.worldScope(3) });
    defer backup.deinit();
    var copied = try w.copy(a, io, &paths, source, .{ .instance = two, .folder = "Copied" }, .{ .scope = coordinator.worldScope(3) });
    defer copied.deinit();
    try std.testing.expectEqual(.committed, copied.state);
    var restored = try w.restore(a, io, &paths, .{ .instance = one, .id = backup.recovery_id }, .{ .instance = three, .folder = "Restored" }, .{ .scope = coordinator.worldScope(3) });
    defer restored.deinit();
    try std.testing.expectEqual(.committed, restored.state);
    for ([_][]const u8{ ".minecraft/versions/Two/saves/Copied/data", ".minecraft/versions/Three/saves/Restored/data" }) |path| {
        const file = try tmp.dir.openFile(io, path, .{});
        defer file.close(io);
        var buffer: [13]u8 = undefined;
        try std.testing.expectEqual(@as(usize, buffer.len), try file.readPositionalAll(io, &buffer, 0));
        try std.testing.expectEqualStrings("world payload", &buffer);
    }
}

test "actual world I/O releases gate while scope excludes source and target launches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    var coordinator = instance_leases.Coordinator.init(io);
    try write(tmp.dir, ".minecraft/versions/One/saves/World/data", "world payload");
    try tmp.dir.createDirPath(io, ".minecraft/versions/Two");
    var observer: LeaseIo = .{ .coordinator = &coordinator, .inspect = true };
    LeaseIo.active = &observer;
    defer LeaseIo.active = null;
    var table = io.vtable.*;
    table.dirOpenDir = LeaseIo.openDir;
    table.dirOpenFile = LeaseIo.openFile;
    table.dirRenamePreserve = LeaseIo.rename;
    table.fileSync = LeaseIo.sync;
    const injected: std.Io = .{ .userdata = io.userdata, .vtable = &table };
    const source: w.WorldRef = .{ .instance = one, .folder = "World" };
    const target: w.WorldRef = .{ .instance = two, .folder = "Target" };

    var listing = try w.list(a, injected, &paths, one, null, .{ .scope = coordinator.worldScope(3) });
    defer listing.deinit();
    try std.testing.expectEqual(@as(usize, 1), listing.items.len);
    try observer.expectObserved();

    var backup = try w.backup(a, injected, &paths, source, .{ .scope = coordinator.worldScope(3) });
    defer backup.deinit();
    try std.testing.expectEqual(.committed, backup.state);
    try observer.expectObserved();

    var recovery = try w.listBackups(a, injected, &paths, one, .{ .scope = coordinator.worldScope(3) });
    defer recovery.deinit();
    try std.testing.expectEqual(@as(usize, 1), recovery.items.len);
    try std.testing.expectEqualStrings(backup.recovery_id, recovery.items[0].id);
    try observer.expectObserved();

    observer.target = two.id;
    var copied = try w.copy(a, injected, &paths, source, target, .{ .scope = coordinator.worldScope(3) });
    defer copied.deinit();
    try std.testing.expectEqual(.committed, copied.state);
    try observer.expectObserved();

    var restored = try w.restore(a, injected, &paths, .{ .instance = one, .id = backup.recovery_id }, .{ .instance = two, .folder = "Restored" }, .{ .scope = coordinator.worldScope(3) });
    defer restored.deinit();
    try std.testing.expectEqual(.committed, restored.state);
    try observer.expectObserved();
    _ = try tmp.dir.statFile(io, ".minecraft/versions/Two/saves/Target/data", .{});
    _ = try tmp.dir.statFile(io, ".minecraft/versions/Two/saves/Restored/data", .{});
    for ([_][]const u8{ one.id, two.id }) |id| {
        try coordinator.reserveLaunch(id);
        coordinator.releaseLaunch();
        coordinator.tick();
    }
}

test "missing scope and dynamic guard deny all world filesystem entry points" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    var coordinator = instance_leases.Coordinator.init(io);
    var observer: LeaseIo = .{ .coordinator = &coordinator };
    LeaseIo.active = &observer;
    defer LeaseIo.active = null;
    var table = io.vtable.*;
    table.dirOpenDir = LeaseIo.openDir;
    table.dirOpenFile = LeaseIo.openFile;
    table.dirRenamePreserve = LeaseIo.rename;
    table.fileSync = LeaseIo.sync;
    const injected: std.Io = .{ .userdata = io.userdata, .vtable = &table };
    try expectDeniedBeforeFilesystem(error.MissingWorldScope, injected, &paths, .{ .confirmed_destructive = true });
    try std.testing.expectEqual(@as(usize, 0), observer.calls);
    try expectDeniedBeforeFilesystem(error.UnsupportedWorldGuard, injected, &paths, .{
        .scope = coordinator.worldScope(3),
        .confirmed_destructive = true,
        .guard = .{ .context = &observer, .is_running = LeaseIo.dynamicGuard },
    });
    try std.testing.expectEqual(@as(usize, 0), observer.calls);
    try std.testing.expect(!observer.guard_called);
}

test "held transaction gate rejects all scoped world entry points before filesystem I/O" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    var coordinator = instance_leases.Coordinator.init(io);
    var observer: LeaseIo = .{ .coordinator = &coordinator };
    LeaseIo.active = &observer;
    defer LeaseIo.active = null;
    var table = io.vtable.*;
    table.dirOpenDir = LeaseIo.openDir;
    table.dirOpenFile = LeaseIo.openFile;
    table.dirRenamePreserve = LeaseIo.rename;
    table.fileSync = LeaseIo.sync;
    const injected: std.Io = .{ .userdata = io.userdata, .vtable = &table };
    try std.testing.expect(w.transaction_gate.tryLock());
    defer w.transaction_gate.unlock(io);
    try expectDeniedBeforeFilesystem(error.InstanceBusy, injected, &paths, .{
        .scope = coordinator.worldScope(3),
        .confirmed_destructive = true,
    });
    try std.testing.expectEqual(@as(usize, 0), observer.calls);
}

const world_lock = @import("worlds_lock.zig");
const builtin = @import("builtin");
extern "c" fn fork() std.c.pid_t;

/// A separate process owns a traditional fcntl record lock, as Java FileChannel does.
/// The child uses only libc calls after fork; pipe handshakes avoid timing assumptions.
const JavaLockProcess = struct {
    pid: std.c.pid_t,
    release_fd: std.c.fd_t,

    fn start(directory: std.Io.Dir, name: []const u8) !JavaLockProcess {
        const file = try directory.createFile(io, name, .{ .read = true, .truncate = false });
        defer file.close(io);
        var ready: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&ready) != 0) return error.Unexpected;
        defer _ = std.c.close(ready[0]);
        defer _ = std.c.close(ready[1]);
        var release: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&release) != 0) return error.Unexpected;
        errdefer _ = std.c.close(release[1]);
        defer _ = std.c.close(release[0]);
        const pid = fork();
        if (pid == -1) return error.Unexpected;
        if (pid == 0) {
            var region = std.mem.zeroes(std.c.Flock);
            region.type = std.c.F.WRLCK;
            region.whence = std.c.SEEK.SET;
            // Zig 0.16 F.SETLK compares @sizeOf(usize) to 64 rather than 8.
            // Linux x86_64/aarch64 use F_SETLK=6, verified against the native ABI.
            const command: i32 = if (@sizeOf(usize) == 8) 6 else std.os.linux.F.SETLK;
            const lock_error = std.os.linux.errno(std.os.linux.fcntl(file.handle, command, @intFromPtr(&region)));
            const success = lock_error == .SUCCESS;
            const marker: [1]u8 = .{if (success) 'L' else @intCast(@backingInt(lock_error))};
            if (std.c.write(ready[1], &marker, 1) != 1 or !success) std.c._exit(1);
            var token: [1]u8 = undefined;
            if (std.c.read(release[0], &token, 1) != 1) std.c._exit(2);
            std.c._exit(0);
        }
        var process: JavaLockProcess = .{ .pid = pid, .release_fd = release[1] };
        errdefer process.stop();
        var marker: [1]u8 = undefined;
        if (std.c.read(ready[0], &marker, 1) != 1 or marker[0] != 'L') {
            std.debug.print("child lock errno {d}\n", .{marker[0]});
            return error.Unexpected;
        }
        return process;
    }

    fn stop(self: JavaLockProcess) void {
        const token = [_]u8{'Q'};
        _ = std.c.write(self.release_fd, &token, 1);
        _ = std.c.close(self.release_fd);
        var status: c_int = 0;
        while (std.c.waitpid(self.pid, &status, 0) == -1) {
            if (std.posix.errno(-1) != .INTR) break;
        }
    }
};

fn expectAccess(paths: *instances.Paths, coordinator: *instance_leases.Coordinator, folder: []const u8, access: w.WorldAccess) !void {
    var listing = try w.list(a, io, paths, one, null, .{ .scope = coordinator.worldScope(3) });
    defer listing.deinit();
    for (listing.items) |world| {
        if (std.mem.eql(u8, world.folder, folder)) {
            try std.testing.expectEqual(access, world.access);
            return;
        }
    }
    return error.WorldMissing;
}

test "per-world access probe is noncreating and distinguishes stale Java locks and unsafe tokens" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    var coordinator = instance_leases.Coordinator.init(io);
    try write(tmp.dir, ".minecraft/versions/One/saves/World/data", "original");
    const directory = try tmp.dir.openDir(io, ".minecraft/versions/One/saves/World", .{});
    defer directory.close(io);
    try expectAccess(&paths, &coordinator, "World", .available);
    try std.testing.expectError(error.FileNotFound, directory.statFile(io, "session.lock", .{ .follow_symlinks = false }));
    try write(directory, "session.lock", "stale bytes");
    try expectAccess(&paths, &coordinator, "World", .available);
    {
        const player = try JavaLockProcess.start(directory, "session.lock");
        defer player.stop();
        try expectAccess(&paths, &coordinator, "World", .in_use);
        try std.testing.expectError(error.WorldLocked, world_lock.acquire(io, directory, "session.lock"));
    }
    try expectAccess(&paths, &coordinator, "World", .available);
    try directory.deleteFile(io, "session.lock");
    try directory.symLink(io, "data", "session.lock", .{});
    try expectAccess(&paths, &coordinator, "World", .unavailable);
    const refused = world_lock.acquire(io, directory, "session.lock");
    if (refused) |held| {
        held.close(io);
        return error.UnsafeLockAccepted;
    } else |_| {}
}

test "Java locked source blocks every world data operation and locked overwrite blocks copy restore" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    var coordinator = instance_leases.Coordinator.init(io);
    try write(tmp.dir, ".minecraft/versions/One/saves/World/data", "source");
    try write(tmp.dir, ".minecraft/versions/Two/saves/Target/data", "target");
    const source: w.WorldRef = .{ .instance = one, .folder = "World" };
    const target: w.WorldRef = .{ .instance = two, .folder = "Target" };
    const options: w.Options = .{ .scope = coordinator.worldScope(3), .confirmed_destructive = true };
    var backed = try w.backup(a, io, &paths, source, options);
    defer backed.deinit();
    const source_dir = try tmp.dir.openDir(io, ".minecraft/versions/One/saves/World", .{});
    defer source_dir.close(io);
    const target_dir = try tmp.dir.openDir(io, ".minecraft/versions/Two/saves/Target", .{});
    defer target_dir.close(io);
    {
        const player = try JavaLockProcess.start(source_dir, "session.lock");
        defer player.stop();
        try std.testing.expectError(error.WorldLocked, w.backup(a, io, &paths, source, options));
        try std.testing.expectError(error.WorldLocked, w.copy(a, io, &paths, source, target, options));
        try std.testing.expectError(error.WorldLocked, w.renameFolder(a, io, &paths, source, "Renamed", options));
        try std.testing.expectError(error.WorldLocked, w.renameDisplayName(a, io, &paths, source, "New name", options));
        try std.testing.expectError(error.WorldLocked, w.delete(a, io, &paths, source, options));
    }
    {
        const player = try JavaLockProcess.start(target_dir, "session.lock");
        defer player.stop();
        try std.testing.expectError(error.WorldLocked, w.copy(a, io, &paths, source, target, options));
        try std.testing.expectError(error.WorldLocked, w.restore(a, io, &paths, .{ .instance = one, .id = backed.recovery_id }, target, options));
    }
}

test "world and absent destination locks stay held across unrelated descriptor closes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const readable = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer readable.close(io);
    try write(readable, "session.lock", "stale original bytes");
    const held = try world_lock.acquire(io, readable, "session.lock");
    defer held.close(io);
    const unrelated = try tmp.dir.openFile(io, "session.lock", .{});
    unrelated.close(io);
    try std.testing.expectError(error.WorldLocked, world_lock.acquire(io, tmp.dir, "session.lock"));
    try std.testing.expectEqual(w.WorldAccess.in_use, world_lock.probe(io, tmp.dir, "session.lock"));
    const repository = try world_lock.acquire(io, readable, ".operation.lock");
    defer repository.close(io);
    try std.testing.expectError(error.WorldLocked, world_lock.acquire(io, tmp.dir, ".operation.lock"));
    try tmp.dir.rename("session.lock", tmp.dir, "old-token", io);
    try write(tmp.dir, "session.lock", "replacement");
    try std.testing.expectError(error.WorldLockChanged, held.recheck(io));
}

test "recovery excludes transient root locks and copies get fresh native lock inodes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    var coordinator = instance_leases.Coordinator.init(io);
    try write(tmp.dir, ".minecraft/versions/One/saves/World/data", "source");
    try write(tmp.dir, ".minecraft/versions/One/saves/World/session.lock", "stale token");
    try write(tmp.dir, ".minecraft/versions/One/saves/World/mod/session.lock", "mod data");
    try tmp.dir.createDirPath(io, ".minecraft/versions/Two");
    var copied = try w.copy(a, io, &paths, .{ .instance = one, .folder = "World" }, .{ .instance = two, .folder = "Target" }, .{ .scope = coordinator.worldScope(3) });
    defer copied.deinit();
    const payload = try std.fs.path.join(a, &.{ copied.recovery_directory, "payload", "session.lock" });
    defer a.free(payload);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, payload, .{ .follow_symlinks = false }));
    const source_stat = try tmp.dir.statFile(io, ".minecraft/versions/One/saves/World/session.lock", .{});
    const target_stat = try tmp.dir.statFile(io, ".minecraft/versions/Two/saves/Target/session.lock", .{});
    try std.testing.expect(source_stat.inode != target_stat.inode);
    try std.testing.expectEqual(@as(u64, 0), target_stat.size);
    try std.testing.expectEqual(@as(u64, 8), (try tmp.dir.statFile(io, ".minecraft/versions/Two/saves/Target/mod/session.lock", .{})).size);
}

test "cross-process repository guard blocks operations on absent destinations" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    var coordinator = instance_leases.Coordinator.init(io);
    try write(tmp.dir, ".minecraft/versions/One/saves/World/data", "source");
    try tmp.dir.createDirPath(io, ".minecraft/versions/Two/saves/.vela-worlds");
    const repository = try tmp.dir.openDir(io, ".minecraft/versions/Two/saves/.vela-worlds", .{});
    defer repository.close(io);
    const competing = try JavaLockProcess.start(repository, ".operation.lock");
    defer competing.stop();
    try std.testing.expectError(error.InstanceBusy, w.copy(a, io, &paths, .{ .instance = one, .folder = "World" }, .{ .instance = two, .folder = "Absent" }, .{ .scope = coordinator.worldScope(3) }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".minecraft/versions/Two/saves/Absent", .{}));
}

test "source target and candidate remain natively locked through committed notification" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    var coordinator = instance_leases.Coordinator.init(io);
    try write(tmp.dir, ".minecraft/versions/One/saves/World/data", "source");
    try tmp.dir.createDirPath(io, ".minecraft/versions/Two");
    const Observer = struct {
        root: std.Io.Dir,
        checked: bool = false,
        failed: bool = false,
        fn committed(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.checked = true;
            const source = self.root.openDir(io, ".minecraft/versions/One/saves/World", .{}) catch {
                self.failed = true;
                return;
            };
            defer source.close(io);
            const target = self.root.openDir(io, ".minecraft/versions/Two/saves/Target", .{}) catch {
                self.failed = true;
                return;
            };
            defer target.close(io);
            self.failed = world_lock.probe(io, source, "session.lock") != .in_use or world_lock.probe(io, target, "session.lock") != .in_use;
        }
    };
    var observer: Observer = .{ .root = tmp.dir };
    var copied = try w.copy(a, io, &paths, .{ .instance = one, .folder = "World" }, .{ .instance = two, .folder = "Target" }, .{ .scope = coordinator.worldScope(3), .hooks = .{ .context = &observer, .committed = Observer.committed } });
    defer copied.deinit();
    try std.testing.expect(observer.checked and !observer.failed);
    const target = try tmp.dir.openDir(io, ".minecraft/versions/Two/saves/Target", .{});
    defer target.close(io);
    try std.testing.expectEqual(w.WorldAccess.available, world_lock.probe(io, target, "session.lock"));
}

test "legacy recovery session token is excluded from integrity data but held during restore" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const tree = @import("worlds_tree.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    var coordinator = instance_leases.Coordinator.init(io);
    try write(tmp.dir, ".minecraft/versions/One/saves/World/data", "source");
    try tmp.dir.createDirPath(io, ".minecraft/versions/Two");
    const options: w.Options = .{ .scope = coordinator.worldScope(3) };
    var backed = try w.backup(a, io, &paths, .{ .instance = one, .folder = "World" }, options);
    defer backed.deinit();
    const record = try std.Io.Dir.cwd().openDir(io, backed.recovery_directory, .{ .iterate = true });
    defer record.close(io);
    const payload = try record.openDir(io, "payload", .{ .iterate = true });
    defer payload.close(io);
    const token = "legacy token bytes";
    try write(payload, "session.lock", token);
    const bytes = try tree.readBounded(a, io, record, "manifest.json", 1024 * 1024);
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(w.Manifest, a, bytes, .{});
    defer parsed.deinit();
    var legacy = parsed.value;
    const entries = try a.alloc(tree.Entry, legacy.entries.len + 1);
    defer a.free(entries);
    @memcpy(entries[0..legacy.entries.len], legacy.entries);
    entries[legacy.entries.len] = .{ .path = "session.lock", .directory = false, .size = token.len };
    legacy.entries = entries;
    legacy.bytes += token.len;
    const document = try std.json.Stringify.valueAlloc(a, legacy, .{});
    defer a.free(document);
    try write(record, "manifest.json", document);
    const target: w.WorldRef = .{ .instance = two, .folder = "Restored" };
    {
        const player = try JavaLockProcess.start(payload, "session.lock");
        defer player.stop();
        try std.testing.expectError(error.WorldLocked, w.restore(a, io, &paths, .{ .instance = one, .id = backed.recovery_id }, target, options));
    }
    var restored = try w.restore(a, io, &paths, .{ .instance = one, .id = backed.recovery_id }, target, options);
    defer restored.deinit();
    try std.testing.expectEqual(@as(u64, 0), (try tmp.dir.statFile(io, ".minecraft/versions/Two/saves/Restored/session.lock", .{})).size);
}

test "overwrite rechecks target data after candidate preparation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    var coordinator = instance_leases.Coordinator.init(io);
    try write(tmp.dir, ".minecraft/versions/One/saves/World/data", "source");
    try write(tmp.dir, ".minecraft/versions/Two/saves/Target/data", "target");
    const Actor = struct {
        root: std.Io.Dir,
        mutated: bool = false,
        failed: bool = false,
        fn progress(context: ?*anyopaque, _: usize, _: u64) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.mutated or self.failed) return;
            const repository = self.root.openDir(io, ".minecraft/versions/Two/saves/.vela-worlds", .{ .iterate = true }) catch {
                self.failed = true;
                return;
            };
            defer repository.close(io);
            var it = repository.iterate();
            while (it.next(io) catch {
                self.failed = true;
                return;
            }) |entry| {
                if (!std.mem.startsWith(u8, entry.name, ".stage-")) continue;
                const stage = repository.openDir(io, entry.name, .{}) catch {
                    self.failed = true;
                    return;
                };
                defer stage.close(io);
                const candidate = stage.statFile(io, "candidate", .{ .follow_symlinks = false }) catch |err| {
                    if (err == error.FileNotFound) continue;
                    self.failed = true;
                    return;
                };
                if (candidate.kind != .directory) continue;
                write(self.root, ".minecraft/versions/Two/saves/Target/data", "changed externally") catch {
                    self.failed = true;
                    return;
                };
                self.mutated = true;
                return;
            }
        }
    };
    var actor: Actor = .{ .root = tmp.dir };
    try std.testing.expectError(error.IntegrityMismatch, w.copy(a, io, &paths, .{ .instance = one, .folder = "World" }, .{ .instance = two, .folder = "Target" }, .{ .scope = coordinator.worldScope(3), .confirmed_destructive = true, .hooks = .{ .context = &actor, .progress = Actor.progress } }));
    try std.testing.expect(actor.mutated and !actor.failed);
    const target = try tmp.dir.openDir(io, ".minecraft/versions/Two/saves/Target", .{});
    defer target.close(io);
    const data = try @import("worlds_tree.zig").readBounded(a, io, target, "data", 64);
    defer a.free(data);
    try std.testing.expectEqualStrings("changed externally", data);
}

test "read-only world providers and held scopes cannot authorize mutations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths = try fixturePaths(tmp);
    defer paths.deinit();
    var coordinator = instance_leases.Coordinator.init(io);
    try write(tmp.dir, ".minecraft/versions/One/saves/World/data", "source");
    var read_scope = coordinator.worldScope(3);
    read_scope.read_only = true;
    const options: w.Options = .{ .scope = read_scope, .confirmed_destructive = true, .guard = .{ .running_ids = &.{"one"} } };
    var listed = try w.list(a, io, &paths, one, null, options);
    defer listed.deinit();
    try std.testing.expectEqual(@as(usize, 1), listed.items.len);
    const source: w.WorldRef = .{ .instance = one, .folder = "World" };
    const target: w.WorldRef = .{ .instance = two, .folder = "Target" };
    try std.testing.expectError(error.ReadOnlyWorldScope, w.backup(a, io, &paths, source, options));
    try std.testing.expectError(error.ReadOnlyWorldScope, w.copy(a, io, &paths, source, target, options));
    try std.testing.expectError(error.ReadOnlyWorldScope, w.renameFolder(a, io, &paths, source, "Renamed", options));
    try std.testing.expectError(error.ReadOnlyWorldScope, w.renameDisplayName(a, io, &paths, source, "New name", options));
    try std.testing.expectError(error.ReadOnlyWorldScope, w.delete(a, io, &paths, source, options));
    try std.testing.expectError(error.ReadOnlyWorldScope, w.restore(a, io, &paths, .{ .instance = one, .id = "00112233445566778899aabbccddeeff" }, target, options));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".minecraft/versions/One/saves/World/session.lock", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".minecraft/versions/One/saves/.vela-worlds", .{}));
    const entry = try w.enterReadScope(options, .{ .source = one.id });
    defer entry.deinit();
    try std.testing.expectError(error.ReadOnlyWorldScope, w.backup(a, io, &paths, source, .{ .held_scope = entry.held }));
}

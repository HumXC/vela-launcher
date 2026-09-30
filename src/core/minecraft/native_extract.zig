//! Native ZIP extraction. Transactions are per destination, not per batch.
//! Callers must serialize installs to a destination and own its parent directory.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Task = @import("install_plan.zig").NativeExtraction;

/// Merge archives sharing a destination into a fresh tree, then publish it.
/// Existing directories are backed up until publication succeeds. A crash during
/// replacement may leave the destination absent and a .native-stage-* backup;
/// it never exposes a partially extracted destination. A failed rollback retains
/// that backup for recovery. No shell or external archive program is used.
pub fn extract(a: Allocator, io: Io, tasks: []const Task, cancel: ?*const std.atomic.Value(bool)) !void {
    for (tasks, 0..) |task, i| {
        try checkCancel(cancel);
        var seen = false;
        for (tasks[0..i]) |prior| {
            if (std.mem.eql(u8, prior.destination, task.destination)) {
                seen = true;
                break;
            }
        }
        if (!seen) try extractDestination(a, io, tasks, task.destination, cancel);
    }
}

fn checkCancel(cancel: ?*const std.atomic.Value(bool)) !void {
    if (cancel) |flag| if (flag.load(.acquire)) return error.Canceled;
}

// Open every component separately with no-follow, including existing parents.
fn openParent(io: Io, path: []const u8) !Io.Dir {
    var dir = try Io.Dir.cwd().openDir(io, if (std.fs.path.isAbsolute(path)) "/" else ".", .{ .follow_symlinks = false });
    errdefer dir.close(io);
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..") or std.mem.indexOfAny(u8, part, "\\:\x00") != null) return error.UnsafePath;
        dir.createDir(io, part, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const next = try dir.openDir(io, part, .{ .follow_symlinks = false });
        dir.close(io);
        dir = next;
    }
    return dir;
}

fn extractDestination(a: Allocator, io: Io, tasks: []const Task, destination: []const u8, cancel: ?*const std.atomic.Value(bool)) !void {
    if (destination.len == 0 or destination[destination.len - 1] == '/') return error.UnsafePath;
    const base = std.fs.path.basename(destination);
    try safeName(base);
    var parent = try openParent(io, std.fs.path.dirname(destination) orelse ".");
    defer parent.close(io);
    // Refuse symlinks and non-directories instead of replacing unrelated files.
    const old_stat = parent.statFile(io, base, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (old_stat) |s| if (s.kind != .directory) return error.UnsafeDestination;
    var random: [16]u8 = undefined;
    io.random(&random);
    const stage_name = try std.fmt.allocPrint(a, ".native-stage-{x}", .{random});
    defer a.free(stage_name);
    try parent.createDir(io, stage_name, .default_dir);
    var retain_backup = false;
    defer if (!retain_backup) parent.deleteTree(io, stage_name) catch {};
    var stage = try parent.openDir(io, stage_name, .{ .follow_symlinks = false });
    defer stage.close(io);
    try stage.createDir(io, "new", .default_dir);
    {
        var output = try stage.openDir(io, "new", .{});
        defer output.close(io);
        for (tasks) |task| if (std.mem.eql(u8, task.destination, destination)) {
            try extractArchive(io, output, task, cancel);
        };
    }
    try checkCancel(cancel);
    if (old_stat != null) try parent.renamePreserve(base, stage, "old", io);
    stage.renamePreserve("new", parent, base, io) catch |err| {
        if (old_stat != null) stage.renamePreserve("old", parent, base, io) catch {
            retain_backup = true;
            return error.NativeRollbackFailed;
        };
        return err;
    };
}

fn safeName(name: []const u8) !void {
    if (name.len == 0 or name[0] == '/' or std.mem.indexOfAny(u8, name, "\\:\x00") != null) return error.UnsafePath;
    const trimmed = if (name[name.len - 1] == '/') name[0 .. name.len - 1] else name;
    var parts = std.mem.splitScalar(u8, trimmed, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.UnsafePath;
        if (part[part.len - 1] == '.' or part[part.len - 1] == ' ') return error.UnsafePath;
        for (part) |c| if (c < 32 or std.mem.indexOfScalar(u8, "<>\"|?*", c) != null) return error.UnsafePath;
        const stem = part[0 .. std.mem.indexOfScalar(u8, part, '.') orelse part.len];
        for ([_][]const u8{ "con", "prn", "aux", "nul" }) |reserved| if (std.ascii.eqlIgnoreCase(stem, reserved)) return error.UnsafePath;
        if (stem.len == 4 and (std.ascii.eqlIgnoreCase(stem[0..3], "com") or std.ascii.eqlIgnoreCase(stem[0..3], "lpt")) and stem[3] >= '1' and stem[3] <= '9') return error.UnsafePath;
    }
}

fn extractArchive(io: Io, output: Io.Dir, task: Task, cancel: ?*const std.atomic.Value(bool)) !void {
    try checkCancel(cancel);
    const file = try Io.Dir.cwd().openFile(io, task.archive_path, .{ .follow_symlinks = false, .allow_directory = false });
    defer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.UnsafeArchive;
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var iterator = try std.zip.Iterator.init(&reader);
    var names: [std.fs.max_path_bytes]u8 = undefined;
    while (try iterator.next()) |entry| {
        try checkCancel(cancel);
        if (entry.filename_len > names.len) return error.UnsafePath;
        try reader.seekTo(entry.header_zip_offset);
        const header = try reader.interface.takeStruct(std.zip.CentralDirectoryFileHeader, .little);
        const name = names[0..entry.filename_len];
        try reader.interface.readSliceAll(name);
        try safeName(name);
        const directory = name[name.len - 1] == '/';
        const kind = (header.external_file_attributes >> 16) & 0xf000;
        if (kind != 0 and kind != 0x8000 and kind != 0x4000) return error.UnsafeArchiveEntry;
        if ((kind == 0x4000 or header.external_file_attributes & 0x10 != 0) != directory and kind != 0) return error.UnsafeArchiveEntry;
        // DOS volume labels and Windows reparse points are not normal files.
        if (header.external_file_attributes & 0x408 != 0) return error.UnsafeArchiveEntry;
        var excluded = false;
        for (task.exclude) |prefix| if (std.mem.startsWith(u8, name, prefix)) {
            excluded = true;
            break;
        };
        if (excluded) continue;
        if (entry.compression_method == .store and entry.compressed_size != entry.uncompressed_size) return error.ZipSizeMismatch;
        try entry.extract(&reader, .{}, &names, output);
        if (!directory) {
            const extracted = try output.openFile(io, name, .{});
            defer extracted.close(io);
            var read_buffer: [8192]u8 = undefined;
            var check_reader = extracted.reader(io, &read_buffer);
            var crc = std.hash.Crc32.init();
            var chunk: [8192]u8 = undefined;
            while (true) {
                try checkCancel(cancel);
                const n = try check_reader.interface.readSliceShort(&chunk);
                if (n == 0) break;
                crc.update(chunk[0..n]);
            }
            if (crc.final() != entry.crc32) return error.ZipCrcMismatch;
        }
    }
}

test "reject unsafe archive names" {
    for ([_][]const u8{ "", "/native.so", "../x", "a/../b", "a\\b", "C:x", "a//b", "a/./b", "nul.dll", "a. ", "x\x00y" }) |name| try std.testing.expectError(error.UnsafePath, safeName(name));
    try safeName("linux/x64/native.so");
    try safeName("META-INF/");
}

const Fixture = struct {
    name: []const u8,
    data: []const u8 = "native",
    attributes: u32 = 0x81a40000,
    deflate: bool = false,
    bad_crc: bool = false,
};

// Small entirely in-process ZIP writer. Deflate uses a final uncompressed block.
fn fixtureZip(a: Allocator, entries: []const Fixture) ![]u8 {
    var storage: [16384]u8 = undefined;
    var w: Io.Writer = .fixed(&storage);
    var offsets: [32]u32 = undefined;
    for (entries, 0..) |entry, i| {
        offsets[i] = @intCast(w.end);
        var h = std.mem.zeroes(std.zip.LocalFileHeader);
        h.signature = std.zip.local_file_header_sig;
        h.version_needed_to_extract = 20;
        h.compression_method = if (entry.deflate) .deflate else .store;
        h.crc32 = std.hash.Crc32.hash(entry.data) ^ @as(u32, if (entry.bad_crc) 1 else 0);
        h.uncompressed_size = @intCast(entry.data.len);
        h.compressed_size = h.uncompressed_size + @as(u32, if (entry.deflate) 5 else 0);
        h.filename_len = @intCast(entry.name.len);
        try w.writeStruct(h, .little);
        try w.writeAll(entry.name);
        if (entry.deflate) {
            try w.writeByte(1);
            try w.writeInt(u16, @intCast(entry.data.len), .little);
            try w.writeInt(u16, ~@as(u16, @intCast(entry.data.len)), .little);
        }
        try w.writeAll(entry.data);
    }
    const cd_offset = w.end;
    for (entries, 0..) |entry, i| {
        var h = std.mem.zeroes(std.zip.CentralDirectoryFileHeader);
        h.signature = std.zip.central_file_header_sig;
        h.version_made_by = 0x0314;
        h.version_needed_to_extract = 20;
        h.compression_method = if (entry.deflate) .deflate else .store;
        h.crc32 = std.hash.Crc32.hash(entry.data) ^ @as(u32, if (entry.bad_crc) 1 else 0);
        h.uncompressed_size = @intCast(entry.data.len);
        h.compressed_size = h.uncompressed_size + @as(u32, if (entry.deflate) 5 else 0);
        h.filename_len = @intCast(entry.name.len);
        h.external_file_attributes = entry.attributes;
        h.local_file_header_offset = offsets[i];
        try w.writeStruct(h, .little);
        try w.writeAll(entry.name);
    }
    var end = std.mem.zeroes(std.zip.EndRecord);
    end.signature = std.zip.end_record_sig;
    end.record_count_disk = @intCast(entries.len);
    end.record_count_total = @intCast(entries.len);
    end.central_directory_offset = @intCast(cd_offset);
    end.central_directory_size = @intCast(w.end - cd_offset);
    try w.writeStruct(end, .little);
    return a.dupe(u8, w.buffered());
}

fn expectFile(dir: Io.Dir, path: []const u8, expected: []const u8) !void {
    const f = try dir.openFile(std.testing.io, path, .{});
    defer f.close(std.testing.io);
    var buf: [128]u8 = undefined;
    var r = f.reader(std.testing.io, &.{});
    const n = try r.interface.readSliceShort(&buf);
    try std.testing.expectEqualStrings(expected, buf[0..n]);
}

test "merge stored and deflated archives, exclude prefixes, replace old destination" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const archive1 = try std.fs.path.join(a, &.{ root, "one.zip" });
    defer a.free(archive1);
    const archive2 = try std.fs.path.join(a, &.{ root, "two.zip" });
    defer a.free(archive2);
    const destination = try std.fs.path.join(a, &.{ root, "nested", "natives" });
    defer a.free(destination);
    const zip1 = try fixtureZip(a, &.{ .{ .name = "lib/a.so" }, .{ .name = "META-INF/", .data = "", .attributes = 0x41ed0010 }, .{ .name = "META-INF/signature" } });
    defer a.free(zip1);
    const zip2 = try fixtureZip(a, &.{.{ .name = "lib/b.so", .data = "deflated", .deflate = true }});
    defer a.free(zip2);
    try tmp.dir.writeFile(io, .{ .sub_path = "one.zip", .data = zip1 });
    try tmp.dir.writeFile(io, .{ .sub_path = "two.zip", .data = zip2 });
    try tmp.dir.createDirPath(io, "nested/natives");
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/natives/stale", .data = "old" });
    const tasks = [_]Task{
        .{ .archive_path = archive1, .destination = destination, .exclude = &.{"META-INF/"} },
        .{ .archive_path = archive2, .destination = destination, .exclude = &.{} },
    };
    try extract(a, io, &tasks, null);
    try expectFile(tmp.dir, "nested/natives/lib/a.so", "native");
    try expectFile(tmp.dir, "nested/natives/lib/b.so", "deflated");
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "nested/natives/stale", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "nested/natives/META-INF", .{}));
    // A second install exercises replacement, not just publication to an empty path.
    try extract(a, io, &tasks, null);
}

test "unsafe members, symlink and corrupt CRC preserve previous installation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const archive = try std.fs.path.join(a, &.{ root, "bad.zip" });
    defer a.free(archive);
    const destination = try std.fs.path.join(a, &.{ root, "natives" });
    defer a.free(destination);
    try tmp.dir.createDir(io, "natives", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "natives/old", .data = "keep" });
    const task: Task = .{ .archive_path = archive, .destination = destination, .exclude = &.{} };
    const cases = [_]struct { entry: Fixture, err: anyerror }{
        .{ .entry = .{ .name = "../escape" }, .err = error.UnsafePath },
        .{ .entry = .{ .name = "/absolute" }, .err = error.UnsafePath },
        .{ .entry = .{ .name = "x\\y" }, .err = error.UnsafePath },
        .{ .entry = .{ .name = "C:drive" }, .err = error.UnsafePath },
        .{ .entry = .{ .name = "link", .attributes = 0xa1ff0000 }, .err = error.UnsafeArchiveEntry },
        .{ .entry = .{ .name = "fifo", .attributes = 0x11a40000 }, .err = error.UnsafeArchiveEntry },
        .{ .entry = .{ .name = "bad.so", .bad_crc = true }, .err = error.ZipCrcMismatch },
    };
    for (cases) |case| {
        const zip = try fixtureZip(a, &.{ .{ .name = "partial.so" }, case.entry });
        defer a.free(zip);
        try tmp.dir.writeFile(io, .{ .sub_path = "bad.zip", .data = zip });
        try std.testing.expectError(case.err, extract(a, io, &.{task}, null));
        try expectFile(tmp.dir, "natives/old", "keep");
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "natives/partial.so", .{}));
    }
    var cancel: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.Canceled, extract(a, io, &.{task}, &cancel));
    try expectFile(tmp.dir, "natives/old", "keep");
}

test "failed new install leaves no published tree and duplicate files fail closed" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const archive = try std.fs.path.join(a, &.{ root, "bad.zip" });
    defer a.free(archive);
    const destination = try std.fs.path.join(a, &.{ root, "natives" });
    defer a.free(destination);
    const task: Task = .{ .archive_path = archive, .destination = destination, .exclude = &.{} };
    const duplicate = try fixtureZip(a, &.{ .{ .name = "same.so" }, .{ .name = "same.so" } });
    defer a.free(duplicate);
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.zip", .data = duplicate });
    try std.testing.expectError(error.PathAlreadyExists, extract(a, io, &.{task}, null));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "natives", .{}));
    // Truncating the end record must fail without publishing a directory.
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.zip", .data = duplicate[0 .. duplicate.len - 10] });
    if (extract(a, io, &.{task}, null)) |_| return error.ExpectedZipFailure else |_| {}
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "natives", .{}));
    var it = tmp.dir.iterate();
    while (try it.next(io)) |entry| try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".native-stage-"));
}

test "destination and ancestor symlinks cannot redirect extraction" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const archive = try std.fs.path.join(a, &.{ root, "good.zip" });
    defer a.free(archive);
    const zip = try fixtureZip(a, &.{.{ .name = "native.so" }});
    defer a.free(zip);
    try tmp.dir.writeFile(io, .{ .sub_path = "good.zip", .data = zip });
    try tmp.dir.createDir(io, "outside", .default_dir);
    try tmp.dir.symLink(io, "outside", "link", .{ .is_directory = true });
    for ([_][]const u8{ "link", "link/natives" }) |relative| {
        const destination = try std.fs.path.join(a, &.{ root, relative });
        defer a.free(destination);
        if (extract(a, io, &.{.{ .archive_path = archive, .destination = destination, .exclude = &.{} }}, null)) |_| return error.ExpectedSymlinkFailure else |_| {}
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "outside/native.so", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "outside/natives", .{}));
}

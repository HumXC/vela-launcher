const std = @import("std");
const archive = @import("safe_archive.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const expect = std.testing.expect;
const eq = std.testing.expectEqual;

fn fixture(name: []const u8) ![]u8 {
    const root = try std.testing.environ.getAlloc(a, "SAFE_ARCHIVE_FIXTURES");
    defer a.free(root);
    return std.fs.path.join(a, &.{ root, name });
}
fn format(name: []const u8) archive.Format {
    return if (std.mem.endsWith(u8, name, ".zip")) .zip else .tar_gz;
}
fn failure(name: []const u8, wanted: ?anyerror, limits: archive.Limits) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixture(name);
    defer a.free(path);
    if (archive.extract(a, io, path, tmp.dir, format(name), limits, null)) |result| {
        var owned = result;
        owned.deinit(a);
        return error.ExpectedExtractionFailure;
    } else |err| {
        if (wanted) |expected| try eq(expected, err);
    }
}

test "ZIP store/deflate and tar.gz extract regular Java files and executable permissions" {
    for ([_][]const u8{ "good.zip", "stored.zip", "good.tgz" }) |name| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try fixture(name);
        defer a.free(path);
        var result = try archive.extract(a, io, path, tmp.dir, format(name), .{}, null);
        defer result.deinit(a);
        try eq(@as(u64, 30), result.total_bytes);
        try eq(@as(usize, 4), result.entries.len);
        var buffer: [64]u8 = undefined;
        try std.testing.expectEqualStrings("java executable", try tmp.dir.readFile(io, "jdk/bin/java", &buffer));
        const file = try tmp.dir.openFile(io, "jdk/bin/java", .{});
        defer file.close(io);
        const stat = try file.stat(io);
        try eq(std.Io.File.Kind.file, stat.kind);
        if (comptime std.Io.File.Permissions.has_executable_bit) try eq(@as(std.posix.mode_t, 0o755), stat.permissions.toMode() & 0o7777);
    }
}

test "archive paths reject traversal absolute drives separators aliases and collisions" {
    for ([_][]const u8{ "traversal.zip", "absolute.zip", "drive.zip", "mixed.zip", "reserved.zip", "trailing.zip", "empty-component.zip", "ads.zip", "traversal.tgz", "absolute.tgz" }) |name| try failure(name, error.UnsafeArchivePath, .{});
    try failure("reservedspace.zip", error.UnsafeArchivePath, .{});
    try failure("collision.zip", error.ArchiveCaseCollision, .{});
    try failure("collision.tgz", error.ArchiveCaseCollision, .{});
    try failure("duplicate.zip", error.DuplicateArchivePath, .{});
    try failure("conflict.zip", error.ArchivePathConflict, .{});
}

test "links special files and privilege bits are rejected" {
    for ([_][]const u8{ "symlink.zip", "symlink.tgz", "hardlink.tgz" }) |name| try failure(name, error.UnsafeArchiveLinkTarget, .{});
    for ([_][]const u8{ "device.zip", "device.tgz", "fifo.tgz" }) |name| try failure(name, error.UnsupportedArchiveSpecialFile, .{});
    try failure("setuid.zip", error.UnsafeArchivePermissions, .{});
}

test "CRC checksums truncation headers and trailing data are verified" {
    for ([_][]const u8{ "crc.zip", "crc.tgz" }) |name| try failure(name, error.ArchiveChecksumMismatch, .{});
    try failure("checksum.tgz", error.TarHeaderChksum, .{});
    try failure("mismatch.zip", error.ZipHeaderMismatch, .{});
    for ([_][]const u8{ "truncated.zip", "truncated.tgz", "tartruncated.tgz" }) |name| try failure(name, null, .{});
    for ([_][]const u8{ "trailing.tgz", "tartrailing.tgz" }) |name| try failure(name, error.TrailingArchiveData, .{});
    try failure("sizeoverflow.tgz", error.ArchiveSizeLimitExceeded, .{});
    try failure("hcrc.tgz", error.UnsupportedGzipHeaderChecksum, .{});
    try failure("gzipreserved.tgz", error.BadGzipHeader, .{});
    try failure("overlap.zip", error.ArchiveCompressedWorkLimitExceeded, .{});
}

test "size entry path depth compressed input and expansion limits" {
    try failure("good.zip", error.ArchiveLimitExceeded, .{ .max_archive_bytes = 10 });
    try failure("good.zip", error.ArchiveSizeLimitExceeded, .{ .max_file_bytes = 5 });
    try failure("good.zip", error.ArchiveSizeLimitExceeded, .{ .max_total_bytes = 20 });
    try failure("good.zip", error.ArchiveEntryLimitExceeded, .{ .max_entries = 1 });
    try failure("good.zip", error.ArchivePathLimitExceeded, .{ .max_path_depth = 2 });
    try failure("good.zip", error.ArchivePathLimitExceeded, .{ .max_paths = 1 });
    try failure("good.zip", error.ArchivePathLimitExceeded, .{ .max_total_path_bytes = 5 });
    try failure("good.tgz", error.ArchiveSizeLimitExceeded, .{ .max_tar_bytes = 512 });
    try failure("bomb.zip", error.ArchiveExpansionLimitExceeded, .{});
    try failure("bomb.tgz", error.ArchiveExpansionLimitExceeded, .{});
}

test "GNU long names and PAX paths use standard parsers" {
    for ([_][]const u8{ "gnu.tgz", "pax.tgz" }) |name| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try fixture(name);
        defer a.free(path);
        var result = try archive.extract(a, io, path, tmp.dir, .tar_gz, .{}, null);
        defer result.deinit(a);
        try eq(@as(u64, 3), result.total_bytes);
    }
}

test "preexisting outputs and symlink parents are never adopted or overwritten" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixture("good.zip");
    defer a.free(path);
    try tmp.dir.writeFile(io, .{ .sub_path = "sentinel", .data = "keep" });
    try std.testing.expectError(error.StagingNotEmpty, archive.extract(a, io, path, tmp.dir, .zip, .{}, null));
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("keep", try tmp.dir.readFile(io, "sentinel", &buffer));
    try tmp.dir.deleteFile(io, "sentinel");
    if (@import("builtin").os.tag != .windows) {
        try tmp.dir.symLink(io, "../", "jdk", .{ .is_directory = true });
        try std.testing.expectError(error.StagingNotEmpty, archive.extract(a, io, path, tmp.dir, .zip, .{}, null));
    }
}

fn allocationScenario(allocator: std.mem.Allocator, path: []const u8) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var result = try archive.extract(allocator, io, path, tmp.dir, .zip, .{}, null);
    defer result.deinit(allocator);
}
test "all metadata allocation failures release owned memory and remain staged" {
    const path = try fixture("good.zip");
    defer a.free(path);
    try @import("test_allocations").checkAllAllocationFailures(a, allocationScenario, .{path});
}

const Fault = struct {
    var count: usize = 0;
    var cancel: ?*archive.Cancel = null;
    var fail_at: usize = 2;
    fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
        if (operation == .file_write_streaming) {
            count += 1;
            if (count == fail_at) {
                if (cancel) |flag| flag.store(true, .release) else return .{ .file_write_streaming = error.NoSpaceLeft };
            }
        }
        return io.vtable.operate(userdata, operation);
    }
};
test "cancellation before work and during chunks never returns a result" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixture("large.zip");
    defer a.free(path);
    var cancel: archive.Cancel = .init(true);
    try std.testing.expectError(error.Canceled, archive.extract(a, io, path, tmp.dir, .zip, .{}, &cancel));
    cancel.store(false, .release);
    Fault.count = 0;
    Fault.cancel = &cancel;
    defer Fault.cancel = null;
    var vtable = io.vtable.*;
    vtable.operate = Fault.operate;
    const fault_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    try std.testing.expectError(error.Canceled, archive.extract(a, fault_io, path, tmp.dir, .zip, .{}, &cancel));
    try eq(@as(usize, 2), Fault.count);
}
test "midwrite disk failure leaves only caller-owned staging and no success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixture("large.zip");
    defer a.free(path);
    Fault.count = 0;
    Fault.cancel = null;
    var vtable = io.vtable.*;
    vtable.operate = Fault.operate;
    const fault_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    try std.testing.expectError(error.NoSpaceLeft, archive.extract(a, fault_io, path, tmp.dir, .zip, .{}, null));
    const file = try tmp.dir.openFile(io, "large", .{});
    defer file.close(io);
    try eq(@as(u64, 32 * 1024), (try file.stat(io)).size);
}

fn checkFile(dir: std.Io.Dir, name: []const u8, content: []const u8, executable: bool) !void {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(content, try dir.readFile(io, name, &buffer));
    const file = try dir.openFile(io, name, .{ .follow_symlinks = false });
    defer file.close(io);
    const stat = try file.stat(io);
    try eq(std.Io.File.Kind.file, stat.kind);
    if (comptime std.Io.File.Permissions.has_executable_bit) try eq(@as(std.posix.mode_t, if (executable) 0o755 else 0o644), stat.permissions.toMode() & 0o7777);
}

test "UTF8 names and ZIP tar forward backward chained links materialize regular files" {
    for ([_][]const u8{ "links.zip", "links.tgz" }) |name| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try fixture(name);
        defer a.free(path);
        var result = try archive.extract(a, io, path, tmp.dir, format(name), .{}, null);
        defer result.deinit(a);
        for ([_][]const u8{ "before", "chain", "bin/java", "other/after" }) |file| try checkFile(tmp.dir, file, "java executable", true);
        try checkFile(tmp.dir, "世界/数据", "UTF-8 data", false);
        if (format(name) == .tar_gz) {
            try checkFile(tmp.dir, "other/hard-before", "java executable", true);
            try checkFile(tmp.dir, "other/hard-after", "java executable", true);
        }
        try eq(@as(u64, if (format(name) == .zip) 70 else 100), result.total_bytes);
    }
}

test "GNU longlink and PAX linkpath extensions preserve long Unicode targets" {
    for ([_][]const u8{ "gnu-link.tgz", "pax-link.tgz" }) |name| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try fixture(name);
        defer a.free(path);
        var result = try archive.extract(a, io, path, tmp.dir, .tar_gz, .{}, null);
        defer result.deinit(a);
        try checkFile(tmp.dir, "link", "java executable", true);
    }
}

test "link graphs reject cycles missing directories escapes and excessive depth" {
    for ([_][]const u8{ "cycle.zip", "cycle.tgz", "self-link.zip", "self-link.tgz" }) |name| try failure(name, error.ArchiveLinkCycle, .{});
    for ([_][]const u8{ "missing-link.zip", "missing-link.tgz" }) |name| try failure(name, error.MissingArchiveLinkTarget, .{});
    for ([_][]const u8{ "directory-link.zip", "directory-link.tgz" }) |name| try failure(name, error.UnsupportedDirectoryLink, .{});
    for ([_][]const u8{ "absolute-link.zip", "absolute-link.tgz", "escape-link.zip", "escape-link.tgz", "drive-link.zip", "drive-link.tgz" }) |name| try failure(name, error.UnsafeArchiveLinkTarget, .{});
    try failure("deep-links.zip", error.ArchiveLinkDepthExceeded, .{});
    try failure("links.zip", error.ArchiveLinkDepthExceeded, .{ .max_link_depth = 1 });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixture("deep-links.zip");
    defer a.free(path);
    var result = try archive.extract(a, io, path, tmp.dir, .zip, .{ .max_link_depth = 65 }, null);
    defer result.deinit(a);
    try checkFile(tmp.dir, "link0", "data", false);
}

test "UTF8 validation rejects malformed sequences controls and superscript devices" {
    for ([_][]const u8{ "invalid-utf8.zip", "overlong-utf8.zip", "surrogate-utf8.zip", "c0.zip", "del.zip", "c1.zip", "com-super.zip", "lpt-super.zip", "com-super3.zip", "c0.tgz", "del.tgz", "c1.tgz", "com-super.tgz", "lpt-super.tgz", "com-super3.tgz" }) |name| try failure(name, error.UnsafeArchivePath, .{});
    for ([_][]const u8{ "unicode.zip", "unicode-near-device.zip" }) |name| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try fixture(name);
        defer a.free(path);
        var result = try archive.extract(a, io, path, tmp.dir, .zip, .{}, null);
        defer result.deinit(a);
        if (std.mem.eql(u8, name, "unicode.zip")) try checkFile(tmp.dir, "世界/save.dat", "bad", false);
    }
}

test "link CRC and copied bytes quota are enforced" {
    try failure("link-crc.zip", error.ArchiveChecksumMismatch, .{});
    try failure("large-link.zip", error.ArchiveSizeLimitExceeded, .{ .max_total_bytes = 262144 });
}

test "link graph allocation failures release all metadata" {
    const path = try fixture("links.zip");
    defer a.free(path);
    try @import("test_allocations").checkAllAllocationFailures(a, allocationScenario, .{path});
}

test "cancellation during link materialization stops partial copy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixture("large-link.zip");
    defer a.free(path);
    var cancel: archive.Cancel = .init(false);
    Fault.count = 0;
    Fault.fail_at = 10; // Eight source chunks, then cancel in the second copied chunk.
    Fault.cancel = &cancel;
    defer {
        Fault.cancel = null;
        Fault.fail_at = 2;
    }
    var vtable = io.vtable.*;
    vtable.operate = Fault.operate;
    const fault_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    try std.testing.expectError(error.Canceled, archive.extract(a, fault_io, path, tmp.dir, .zip, .{}, &cancel));
    try eq(@as(usize, 10), Fault.count);
    const file = try tmp.dir.openFile(io, "copy", .{ .follow_symlinks = false });
    defer file.close(io);
    const size = (try file.stat(io)).size;
    try std.testing.expect(size > 0 and size < 262144);
}

test "link materialization waits for original checksums and complete validation" {
    try failure("hardlink-checksum.tgz", error.TarHeaderChksum, .{});
    for ([_][]const u8{ "link-crc.zip", "link-target-crc.zip", "link-gzip-crc.tgz" }) |name| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try fixture(name);
        defer a.free(path);
        try std.testing.expectError(error.ArchiveChecksumMismatch, archive.extract(a, io, path, tmp.dir, format(name), .{}, null));
        try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "copy", .{ .follow_symlinks = false }));
    }
}

test "native filesystem Unicode aliases cannot overwrite existing extracted data" {
    var probe = std.testing.tmpDir(.{});
    defer probe.cleanup();
    const first = try probe.dir.createFile(io, "é", .{ .exclusive = true });
    first.close(io);
    const aliases = if (probe.dir.createFile(io, "e\u{301}", .{ .exclusive = true })) |second| blk: {
        second.close(io);
        break :blk false;
    } else |err| switch (err) {
        error.PathAlreadyExists => true,
        else => return err,
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixture("unicode-alias.zip");
    defer a.free(path);
    if (aliases) {
        try std.testing.expectError(error.PathAlreadyExists, archive.extract(a, io, path, tmp.dir, .zip, .{}, null));
        try checkFile(tmp.dir, "é", "first", false);
    } else {
        var result = try archive.extract(a, io, path, tmp.dir, .zip, .{}, null);
        defer result.deinit(a);
        try checkFile(tmp.dir, "é", "first", false);
        try checkFile(tmp.dir, "e\u{301}", "second", false);
    }
    var dirs = std.testing.tmpDir(.{});
    defer dirs.cleanup();
    const dir_path = try fixture("unicode-directory-alias.zip");
    defer a.free(dir_path);
    if (aliases) {
        try std.testing.expectError(error.AliasCollision, archive.extract(a, io, dir_path, dirs.dir, .zip, .{}, null));
        try checkFile(dirs.dir, "é/a", "first", false);
        try std.testing.expectError(error.FileNotFound, dirs.dir.openFile(io, "é/b", .{}));
    } else {
        var result = try archive.extract(a, io, dir_path, dirs.dir, .zip, .{}, null);
        defer result.deinit(a);
        try checkFile(dirs.dir, "é/a", "first", false);
        try checkFile(dirs.dir, "e\u{301}/b", "second", false);
    }
}

const directory_limits: archive.Limits = .{ .materialize_directory_links = true };

test "opt-in JDK directory aliases copy implicit trees chains and empty directories" {
    for ([_][]const u8{ "jdk-directories.zip", "jdk-directories.tgz" }) |name| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try fixture(name);
        defer a.free(path);
        var result = try archive.extract(a, io, path, tmp.dir, format(name), directory_limits, null);
        defer result.deinit(a);
        try eq(@as(u64, 66), result.total_bytes);
        try eq(@as(usize, 20), result.entries.len);
        for ([_][]const u8{ "java.base", "java.desktop", "chain" }) |part| {
            const license = try std.fmt.allocPrint(a, "jdk/legal/{s}/LICENSE", .{part});
            defer a.free(license);
            const copy = try std.fmt.allocPrint(a, "jdk/legal/{s}/COPY", .{part});
            defer a.free(copy);
            const notice = try std.fmt.allocPrint(a, "jdk/legal/{s}/nested/NOTICE", .{part});
            defer a.free(notice);
            try checkFile(tmp.dir, license, "license", false);
            try checkFile(tmp.dir, copy, "license", false);
            try checkFile(tmp.dir, notice, "notice", false);
        }
        try checkFile(tmp.dir, "jdk/legal/notice", "notice", false);
        var empty = try tmp.dir.openDir(io, "jdk/legal/empty-copy", .{ .follow_symlinks = false, .iterate = true });
        defer empty.close(io);
        var it = empty.iterate();
        try expect(try it.next(io) == null);
        try tmp.dir.writeFile(io, .{ .sub_path = "jdk/legal/java.base/LICENSE", .data = "changed" });
        try checkFile(tmp.dir, "jdk/legal/java.desktop/LICENSE", "license", false);
    }
}

test "directory copy policy rejects unsafe graphs and directory hardlinks" {
    for ([_][]const u8{ "zip", "tgz" }) |extension| {
        for ([_][]const u8{ "directory-ancestor", "directory-indirect-cycle", "directory-self-descendant", "cycle", "self-link" }) |label| {
            const name = try std.fmt.allocPrint(a, "{s}.{s}", .{ label, extension });
            defer a.free(name);
            try failure(name, error.ArchiveLinkCycle, directory_limits);
        }
        for ([_][]const u8{ "missing-link", "directory-case" }) |label| {
            const name = try std.fmt.allocPrint(a, "{s}.{s}", .{ label, extension });
            defer a.free(name);
            try failure(name, error.MissingArchiveLinkTarget, directory_limits);
        }
        const root = try std.fmt.allocPrint(a, "directory-root.{s}", .{extension});
        defer a.free(root);
        try failure(root, error.UnsupportedDirectoryLink, directory_limits);
        const conflict = try std.fmt.allocPrint(a, "directory-conflict.{s}", .{extension});
        defer a.free(conflict);
        try failure(conflict, error.ArchivePathConflict, directory_limits);
        for ([_][]const u8{ "absolute-link", "escape-link", "drive-link" }) |label| {
            const name = try std.fmt.allocPrint(a, "{s}.{s}", .{ label, extension });
            defer a.free(name);
            try failure(name, error.UnsafeArchiveLinkTarget, directory_limits);
        }
    }
    try failure("directory-hardlink.tgz", error.UnsupportedDirectoryLink, directory_limits);
    try failure("directory-hardchain.tgz", error.UnsupportedDirectoryLink, directory_limits);
    try failure("directory-crc.zip", error.ArchiveChecksumMismatch, directory_limits);
}

test "directory copies enforce byte path count path bytes depth and link limits" {
    var limits = directory_limits;
    limits.max_total_bytes = 65;
    try failure("jdk-directories.zip", error.ArchiveSizeLimitExceeded, limits);
    limits = directory_limits;
    limits.max_paths = 19;
    try failure("jdk-directories.zip", error.ArchivePathLimitExceeded, limits);
    limits = directory_limits;
    limits.max_total_path_bytes = 23; // Original paths plus target fit; copied child exceeds it.
    try failure("directory-quota.zip", error.ArchivePathLimitExceeded, limits);
    limits = directory_limits;
    limits.max_path_bytes = 13; // Original longest name is 12; copied child is 14.
    try failure("directory-quota.zip", error.UnsafeArchivePath, limits);
    limits = directory_limits;
    limits.max_path_depth = 2; // Only the copied extra/alias/a reaches depth three.
    try failure("directory-depth.zip", error.ArchivePathLimitExceeded, limits);
    limits = directory_limits;
    limits.max_link_depth = 2;
    try failure("jdk-directories.zip", error.ArchiveLinkDepthExceeded, limits);
}

fn directoryAllocationScenario(allocator: std.mem.Allocator, path: []const u8) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var result = try archive.extract(allocator, io, path, tmp.dir, .zip, directory_limits, null);
    defer result.deinit(allocator);
}

test "directory graph allocation failures release all metadata" {
    const path = try fixture("jdk-directories.zip");
    defer a.free(path);
    try @import("test_allocations").checkAllAllocationFailures(a, directoryAllocationScenario, .{path});
}

test "cancellation during directory materialization stops partial copy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixture("large-directory.zip");
    defer a.free(path);
    var cancel: archive.Cancel = .init(false);
    Fault.count = 0;
    Fault.fail_at = 10;
    Fault.cancel = &cancel;
    defer {
        Fault.cancel = null;
        Fault.fail_at = 2;
    }
    var vtable = io.vtable.*;
    vtable.operate = Fault.operate;
    const fault_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    try std.testing.expectError(error.Canceled, archive.extract(a, fault_io, path, tmp.dir, .zip, directory_limits, &cancel));
    try eq(@as(usize, 10), Fault.count);
    const file = try tmp.dir.openFile(io, "copy/large", .{ .follow_symlinks = false });
    defer file.close(io);
    const size = (try file.stat(io)).size;
    try expect(size > 0 and size < 262144);
}

test "production Java adapter accepts JDK license directory links and executable Java" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixture("jdk-install.tgz");
    defer a.free(path);
    const destination = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(destination);
    var adapter: @import("java_archive.zig").Adapter = .{};
    const extractor = adapter.extractor();
    const java = try extractor.extract(extractor.context, a, io, .tar_gz, path, destination, .{});
    defer a.free(java);
    try std.testing.expectEqualStrings("jdk/bin/java", java);
    try checkFile(tmp.dir, java, "java executable", true);
    try checkFile(tmp.dir, "jdk/legal/java.desktop/LICENSE", "license", false);
    try checkFile(tmp.dir, "jdk/legal/chain/nested/NOTICE", "notice", false);
}

test "directory copies refuse native Unicode aliases without overwriting sources" {
    var probe = std.testing.tmpDir(.{});
    defer probe.cleanup();
    try probe.dir.createDir(io, "é", .default_dir);
    const aliases = if (probe.dir.createDir(io, "e\u{301}", .default_dir)) false else |err| switch (err) {
        error.PathAlreadyExists => true,
        else => return err,
    };
    for ([_][]const u8{ "directory-alias-collision.zip", "directory-alias-collision.tgz" }) |name| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try fixture(name);
        defer a.free(path);
        if (aliases) {
            try std.testing.expectError(error.AliasCollision, archive.extract(a, io, path, tmp.dir, format(name), directory_limits, null));
        } else {
            var result = try archive.extract(a, io, path, tmp.dir, format(name), directory_limits, null);
            defer result.deinit(a);
            try checkFile(tmp.dir, "e\u{301}/a", "first", false);
        }
        try checkFile(tmp.dir, "é/a", "first", false);
    }
}

test "directory copies conservatively refuse reentrant aliases even for finite file references" {
    for ([_][]const u8{ "directory-reentrant-file.zip", "directory-reentrant-file.tgz" }) |name| {
        try failure(name, error.ArchiveLinkCycle, directory_limits);
    }
}

test "production Java adapter selects JDK launcher over embedded JRE after tar extraction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixture("jdk8-install.tgz");
    defer a.free(path);
    const destination = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(destination);
    var adapter: @import("java_archive.zig").Adapter = .{};
    const extractor = adapter.extractor();
    const java = try extractor.extract(extractor.context, a, io, .tar_gz, path, destination, .{});
    defer a.free(java);
    try std.testing.expectEqualStrings("jdk/bin/java", java);
    try checkFile(tmp.dir, java, "java executable", true);
    try checkFile(tmp.dir, "jdk/jre/bin/java", "embedded java", true);
    try checkFile(tmp.dir, "jdk/legal/java.desktop/LICENSE", "license", false);
}

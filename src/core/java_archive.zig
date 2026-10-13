//! Production bridge from Java installation to capability-based archive extraction.
//! The caller owns a private, empty staging directory and must discard it on failure.
const std = @import("std");
const java_download = @import("java_download.zig");
const safe_archive = @import("safe_archive.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Adapter = struct {
    cancel: ?*const std.atomic.Value(bool) = null,
    limits: safe_archive.Limits = .{},

    /// The returned callback borrows self; keep it alive until extraction returns.
    pub fn extractor(self: *Adapter) java_download.Extractor {
        return .{ .context = self, .extract = extract };
    }

    fn check(self: *const Adapter, hooks: java_download.Hooks) !void {
        try hooks.check();
        if (self.cancel) |flag| if (flag.load(.acquire)) return error.Canceled;
    }

    fn extract(context: *anyopaque, a: Allocator, io: Io, format: java_download.Archive, archive_path: []const u8, destination_path: []const u8, hooks: java_download.Hooks) ![]u8 {
        const self: *Adapter = @ptrCast(@alignCast(context));
        try self.check(hooks);
        if (!std.fs.path.isAbsolute(destination_path)) return error.DestinationMustBeAbsolute;
        const destination = try Io.Dir.openDirAbsolute(io, destination_path, .{ .follow_symlinks = false });
        defer destination.close(io);
        // JDK license trees use internal directory aliases. Copy them as bounded
        // independent trees; shared pack/loader extraction keeps its default refusal.
        var limits = self.limits;
        limits.materialize_directory_links = true;
        var result = try safe_archive.extract(a, io, archive_path, destination, switch (format) {
            .zip => .zip,
            .tar_gz => .tar_gz,
        }, limits, self.cancel);
        defer result.deinit(a);
        try self.check(hooks);
        const relative_java = try selectJava(result.entries, format);
        try verifyJava(io, destination, relative_java, format);
        try self.check(hooks);
        return a.dupe(u8, relative_java);
    }
};

fn javaPrefix(path: []const u8, suffix: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, path, suffix)) return null;
    const prefix_len = path.len - suffix.len;
    if (prefix_len != 0 and path[prefix_len - 1] != '/') return null;
    return path[0..prefix_len];
}

fn selectJava(entries: []const safe_archive.Entry, format: java_download.Archive) ![]const u8 {
    const suffix = if (format == .zip) "bin/java.exe" else "bin/java";
    var selected_index: ?usize = null;
    for (entries, 0..) |entry, index| {
        _ = javaPrefix(entry.path, suffix) orelse continue;
        if (selected_index == null or entry.path.len < entries[selected_index.?].path.len) selected_index = index;
    }
    const index = selected_index orelse return error.JavaNotFound;
    const java = entries[index];
    const prefix = javaPrefix(java.path, suffix).?;
    // A JDK 8 includes both its launcher and an embedded JRE launcher. Prefer
    // the outer JDK, but reject unrelated or deeper runtimes regardless of order.
    for (entries, 0..) |entry, other_index| {
        if (other_index == index) continue;
        const other_prefix = javaPrefix(entry.path, suffix) orelse continue;
        if (other_prefix.len != prefix.len + "jre/".len or
            !std.mem.startsWith(u8, other_prefix, prefix) or
            !std.mem.eql(u8, other_prefix[prefix.len..], "jre/")) return error.JavaAmbiguous;
    }
    if (java.kind != .file) return error.JavaNotRegular;
    // ZIP is the Windows artifact: its .exe need not carry POSIX mode bits.
    if (format == .tar_gz and !java.executable) return error.JavaNotExecutable;
    return java.path;
}

fn verifyJava(io: Io, destination: Io.Dir, path: []const u8, format: java_download.Archive) !void {
    var parent = try destination.openDir(io, ".", .{ .follow_symlinks = false });
    defer parent.close(io);
    // NOFOLLOW on the leaf alone would still follow symlinked parent directories.
    const leaf_start = (std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.JavaNotFound) + 1;
    var components = std.mem.splitScalar(u8, path[0 .. leaf_start - 1], '/');
    while (components.next()) |component| {
        const next = try parent.openDir(io, component, .{ .follow_symlinks = false });
        parent.close(io);
        parent = next;
    }
    const stat = try parent.statFile(io, path[leaf_start..], .{ .follow_symlinks = false });
    if (stat.kind != .file) return error.JavaNotRegular;
    if (comptime Io.File.Permissions.has_executable_bit) {
        if (format == .tar_gz and stat.permissions.toMode() & 0o111 == 0) return error.JavaNotExecutable;
    }
}

const FixtureEntry = struct {
    path: []const u8,
    data: []const u8 = "fixture Java; never executed",
    mode: u32 = 0o100644,
};

// Stored ZIP fixtures use the std ZIP wire structs, with no external fixture files.
fn fixtureZip(a: Allocator, entries: []const FixtureEntry) ![]u8 {
    var storage: [16384]u8 = undefined;
    var writer: Io.Writer = .fixed(&storage);
    var offsets: [32]u32 = undefined;
    if (entries.len > offsets.len) return error.FixtureTooLarge;
    for (entries, 0..) |entry, i| {
        offsets[i] = @intCast(writer.end);
        var header = std.mem.zeroes(std.zip.LocalFileHeader);
        header.signature = std.zip.local_file_header_sig;
        header.version_needed_to_extract = 20;
        header.compression_method = .store;
        header.crc32 = std.hash.Crc32.hash(entry.data);
        header.compressed_size = @intCast(entry.data.len);
        header.uncompressed_size = @intCast(entry.data.len);
        header.filename_len = @intCast(entry.path.len);
        try writer.writeStruct(header, .little);
        try writer.writeAll(entry.path);
        try writer.writeAll(entry.data);
    }
    const central_offset = writer.end;
    for (entries, 0..) |entry, i| {
        var header = std.mem.zeroes(std.zip.CentralDirectoryFileHeader);
        header.signature = std.zip.central_file_header_sig;
        header.version_made_by = 0x0314;
        header.version_needed_to_extract = 20;
        header.compression_method = .store;
        header.crc32 = std.hash.Crc32.hash(entry.data);
        header.compressed_size = @intCast(entry.data.len);
        header.uncompressed_size = @intCast(entry.data.len);
        header.filename_len = @intCast(entry.path.len);
        header.external_file_attributes = entry.mode << 16;
        header.local_file_header_offset = offsets[i];
        try writer.writeStruct(header, .little);
        try writer.writeAll(entry.path);
    }
    var end = std.mem.zeroes(std.zip.EndRecord);
    end.signature = std.zip.end_record_sig;
    end.record_count_disk = @intCast(entries.len);
    end.record_count_total = @intCast(entries.len);
    end.central_directory_offset = @intCast(central_offset);
    end.central_directory_size = @intCast(writer.end - central_offset);
    try writer.writeStruct(end, .little);
    return a.dupe(u8, writer.buffered());
}

const TestArchive = struct {
    tmp: std.testing.TmpDir,
    archive_path: [:0]u8,
    destination_path: [:0]u8,

    fn init(entries: []const FixtureEntry) !TestArchive {
        const a = std.testing.allocator;
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const bytes = try fixtureZip(a, entries);
        defer a.free(bytes);
        try tmp.dir.writeFile(io, .{ .sub_path = "fixture.zip", .data = bytes });
        try tmp.dir.createDir(io, "destination", .default_dir);
        const archive_path = try tmp.dir.realPathFileAlloc(io, "fixture.zip", a);
        errdefer a.free(archive_path);
        const destination_path = try tmp.dir.realPathFileAlloc(io, "destination", a);
        return .{ .tmp = tmp, .archive_path = archive_path, .destination_path = destination_path };
    }

    fn deinit(self: *TestArchive) void {
        std.testing.allocator.free(self.archive_path);
        std.testing.allocator.free(self.destination_path);
        self.tmp.cleanup();
    }

    fn extract(self: *TestArchive, adapter: *Adapter, hooks: java_download.Hooks) ![]u8 {
        const extractor = adapter.extractor();
        return extractor.extract(extractor.context, std.testing.allocator, std.testing.io, .zip, self.archive_path, self.destination_path, hooks);
    }
};

fn metadata(path: []const u8, executable: bool) safe_archive.Entry {
    return .{ .path = path, .kind = .file, .size = 1, .executable = executable };
}

test "Java selection preserves exact root prefixed and macOS paths" {
    for ([_][]const u8{ "bin/java", "jdk-25/bin/java", "jdk-25.jdk/Contents/Home/bin/java" }) |path| {
        const entries = [_]safe_archive.Entry{metadata(path, true)};
        try std.testing.expectEqualStrings(path, try selectJava(&entries, .tar_gz));
    }
    const windows = [_]safe_archive.Entry{metadata("arbitrary/prefix/bin/java.exe", false)};
    try std.testing.expectEqualStrings(windows[0].path, try selectJava(&windows, .zip));
}

test "Java selection rejects ambiguity wrong suffix kinds and missing execute bits" {
    try std.testing.expectError(error.JavaNotFound, selectJava(&.{}, .tar_gz));
    const wrong = [_]safe_archive.Entry{
        metadata("notbin/java", true),  metadata("bin/java.backup", true),
        metadata("bin/java.exe", true), metadata("bin/javac", true),
    };
    try std.testing.expectError(error.JavaNotFound, selectJava(&wrong, .tar_gz));
    try std.testing.expectError(error.JavaNotFound, selectJava(&.{metadata("bin/java", true)}, .zip));
    try std.testing.expectError(error.JavaNotExecutable, selectJava(&.{metadata("bin/java", false)}, .tar_gz));
    try std.testing.expectError(error.JavaNotRegular, selectJava(&.{.{ .path = "bin/java", .kind = .directory, .size = 0, .executable = true }}, .tar_gz));
    try std.testing.expectError(error.JavaAmbiguous, selectJava(&.{ metadata("jdk/bin/java", true), metadata("other/bin/java", false) }, .tar_gz));
}

test "adapter extracts actual ZIP fixtures and returns owned exact Java paths" {
    for ([_][]const u8{ "bin/java.exe", "jdk-25/bin/java.exe", "arbitrary/Contents/Home/bin/java.exe" }) |path| {
        var fixture = try TestArchive.init(&.{.{ .path = path }});
        defer fixture.deinit();
        var adapter: Adapter = .{};
        const relative_java = try fixture.extract(&adapter, .{});
        defer std.testing.allocator.free(relative_java);
        try std.testing.expectEqualStrings(path, relative_java);
        const stat = blk: {
            const destination = try Io.Dir.openDirAbsolute(std.testing.io, fixture.destination_path, .{});
            defer destination.close(std.testing.io);
            break :blk try destination.statFile(std.testing.io, relative_java, .{ .follow_symlinks = false });
        };
        try std.testing.expectEqual(.file, stat.kind);
        try std.testing.expectEqual(@as(u64, "fixture Java; never executed".len), stat.size);
        // In particular Windows cannot remove a directory while its handles remain open.
        try fixture.tmp.dir.deleteTree(std.testing.io, "destination");
        try std.testing.expectEqualStrings(path, relative_java);
    }
}

test "adapter rejects missing ambiguous and nonregular Java ZIP entries" {
    const cases = [_]struct { entries: []const FixtureEntry, err: anyerror }{
        .{ .entries = &.{.{ .path = "jdk/bin/java" }}, .err = error.JavaNotFound },
        .{ .entries = &.{.{ .path = "notbin/java.exe" }}, .err = error.JavaNotFound },
        .{ .entries = &.{ .{ .path = "one/bin/java.exe" }, .{ .path = "two/bin/java.exe" } }, .err = error.JavaAmbiguous },
        .{ .entries = &.{.{ .path = "bin/java.exe/child" }}, .err = error.JavaNotRegular },
    };
    for (cases) |case| {
        var fixture = try TestArchive.init(case.entries);
        defer fixture.deinit();
        var adapter: Adapter = .{};
        try std.testing.expectError(case.err, fixture.extract(&adapter, .{}));
    }
}

test "adapter forwards archive security limits and rejects nonempty staging" {
    const cases = [_]struct { entries: []const FixtureEntry, err: anyerror }{
        .{ .entries = &.{.{ .path = "../bin/java.exe" }}, .err = error.UnsafeArchivePath },
        .{ .entries = &.{ .{ .path = "bin/java.exe" }, .{ .path = "bin/java.exe" } }, .err = error.DuplicateArchivePath },
    };
    for (cases) |case| {
        var fixture = try TestArchive.init(case.entries);
        defer fixture.deinit();
        var adapter: Adapter = .{};
        try std.testing.expectError(case.err, fixture.extract(&adapter, .{}));
    }
    var fixture = try TestArchive.init(&.{.{ .path = "bin/java.exe" }});
    defer fixture.deinit();
    var adapter: Adapter = .{ .limits = .{ .max_archive_bytes = 10 } };
    try std.testing.expectError(error.ArchiveLimitExceeded, fixture.extract(&adapter, .{}));
    adapter.limits = .{};
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "destination/sentinel", .data = "keep" });
    try std.testing.expectError(error.StagingNotEmpty, fixture.extract(&adapter, .{}));
}

const TestCancellation = struct {
    checks: usize = 0,
    cancel_on: usize,
    fn canceled(context: ?*anyopaque) bool {
        const self: *TestCancellation = @ptrCast(@alignCast(context.?));
        self.checks += 1;
        return self.checks >= self.cancel_on;
    }
    fn hooks(self: *TestCancellation) java_download.Hooks {
        return .{ .context = self, .canceled = canceled };
    }
};

test "adapter checks Hooks before and after extraction and accepts atomic task cancellation" {
    var fixture = try TestArchive.init(&.{.{ .path = "bin/java.exe" }});
    defer fixture.deinit();
    var flag: std.atomic.Value(bool) = .init(true);
    var adapter: Adapter = .{ .cancel = &flag };
    try std.testing.expectError(error.Canceled, fixture.extract(&adapter, .{}));
    flag.store(false, .release);
    var before: TestCancellation = .{ .cancel_on = 1 };
    try std.testing.expectError(error.Canceled, fixture.extract(&adapter, before.hooks()));
    try std.testing.expectEqual(@as(usize, 1), before.checks);
    var after: TestCancellation = .{ .cancel_on = 2 };
    try std.testing.expectError(error.Canceled, fixture.extract(&adapter, after.hooks()));
    try std.testing.expectEqual(@as(usize, 2), after.checks);
    const stat = try fixture.tmp.dir.statFile(std.testing.io, "destination/bin/java.exe", .{ .follow_symlinks = false });
    try std.testing.expectEqual(.file, stat.kind);
}

test "adapter requires an absolute destination" {
    var adapter: Adapter = .{};
    const extractor = adapter.extractor();
    try std.testing.expectError(error.DestinationMustBeAbsolute, extractor.extract(extractor.context, std.testing.allocator, std.testing.io, .zip, "unused.zip", "relative", .{}));
}

test "actual Java stat rejects directories and POSIX files with no execute bits" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "bin", .default_dir);
    try tmp.dir.createDir(io, "bin/java.exe", .default_dir);
    try std.testing.expectError(error.JavaNotRegular, verifyJava(io, tmp.dir, "bin/java.exe", .zip));
    if (comptime Io.File.Permissions.has_executable_bit) {
        const file = try tmp.dir.createFile(io, "bin/java", .{});
        defer file.close(io);
        try file.setPermissions(io, .fromMode(0o644));
        try std.testing.expectError(error.JavaNotExecutable, verifyJava(io, tmp.dir, "bin/java", .tar_gz));
        try file.setPermissions(io, .fromMode(0o100));
        try verifyJava(io, tmp.dir, "bin/java", .tar_gz);
    }
}

test "Java verification and destination opening do not follow symlinks" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "bin", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "real.exe", .data = "never execute" });
    try tmp.dir.symLink(io, "../real.exe", "bin/java.exe", .{});
    try std.testing.expectError(error.JavaNotRegular, verifyJava(io, tmp.dir, "bin/java.exe", .zip));
    try tmp.dir.createDir(io, "real-bin", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "real-bin/java.exe", .data = "never execute" });
    try tmp.dir.symLink(io, "real-bin", "linked", .{ .is_directory = true });
    if (verifyJava(io, tmp.dir, "linked/java.exe", .zip)) return error.ExpectedNoFollowFailure else |_| {}
    try tmp.dir.createDir(io, "real-stage", .default_dir);
    try tmp.dir.symLink(io, "real-stage", "staging-link", .{ .is_directory = true });
    const bytes = try fixtureZip(std.testing.allocator, &.{.{ .path = "bin/java.exe" }});
    defer std.testing.allocator.free(bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "fixture.zip", .data = bytes });
    const archive_path = try tmp.dir.realPathFileAlloc(io, "fixture.zip", std.testing.allocator);
    defer std.testing.allocator.free(archive_path);
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const destination = try std.fs.path.join(std.testing.allocator, &.{ root, "staging-link" });
    defer std.testing.allocator.free(destination);
    var adapter: Adapter = .{};
    const extractor = adapter.extractor();
    if (extractor.extract(extractor.context, std.testing.allocator, io, .zip, archive_path, destination, .{})) |java| {
        std.testing.allocator.free(java);
        return error.ExpectedNoFollowFailure;
    } else |_| {}
}

test "Java selection prefers the JDK over its embedded JRE independent of entry order" {
    for ([_][]const u8{ "", "jdk-8/", "jdk-8.jdk/Contents/Home/" }) |prefix| {
        for ([_]java_download.Archive{ .zip, .tar_gz }) |format| {
            const suffix = if (format == .zip) "bin/java.exe" else "bin/java";
            const root = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}", .{ prefix, suffix });
            defer std.testing.allocator.free(root);
            const nested = try std.fmt.allocPrint(std.testing.allocator, "{s}jre/{s}", .{ prefix, suffix });
            defer std.testing.allocator.free(nested);
            for ([_]bool{ false, true }) |reverse| {
                const entries = if (reverse) [_]safe_archive.Entry{ metadata(nested, true), metadata(root, true) } else [_]safe_archive.Entry{ metadata(root, true), metadata(nested, true) };
                try std.testing.expectEqualStrings(root, try selectJava(&entries, format));
            }
            try std.testing.expectEqualStrings(nested, try selectJava(&.{metadata(nested, true)}, format));
        }
    }
}

test "Java selection still rejects independent and deeper runtime bundles in every order" {
    const root = "jdk/bin/java";
    for ([_][]const u8{ "other/bin/java", "jdk-other/jre/bin/java", "jdk/other/bin/java", "jdk/jre/jre/bin/java" }) |other| {
        const entries = [_]safe_archive.Entry{ metadata(root, true), metadata("jdk/jre/bin/java", true), metadata(other, true) };
        for (0..3) |rotation| {
            const rotated = [_]safe_archive.Entry{ entries[rotation], entries[(rotation + 1) % 3], entries[(rotation + 2) % 3] };
            try std.testing.expectError(error.JavaAmbiguous, selectJava(&rotated, .tar_gz));
        }
    }
    try std.testing.expectError(error.JavaNotExecutable, selectJava(&.{ metadata(root, false), metadata("jdk/jre/bin/java", true) }, .tar_gz));
    try std.testing.expectError(error.JavaNotRegular, selectJava(&.{ .{ .path = root, .kind = .directory, .size = 0, .executable = false }, metadata("jdk/jre/bin/java", true) }, .tar_gz));
}

test "adapter extracts JDK ZIP with embedded JRE and selects outer launcher" {
    for ([_]bool{ false, true }) |reverse| {
        const entries = if (reverse) [_]FixtureEntry{ .{ .path = "jdk/jre/bin/java.exe" }, .{ .path = "jdk/bin/java.exe" } } else [_]FixtureEntry{ .{ .path = "jdk/bin/java.exe" }, .{ .path = "jdk/jre/bin/java.exe" } };
        var fixture = try TestArchive.init(&entries);
        defer fixture.deinit();
        var adapter: Adapter = .{};
        const java = try fixture.extract(&adapter, .{});
        defer std.testing.allocator.free(java);
        try std.testing.expectEqualStrings("jdk/bin/java.exe", java);
    }
}

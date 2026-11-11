//! Native ZIP extraction. Transactions are per destination, not per batch.
//! Callers must serialize installs to a destination and own its parent directory.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Task = @import("install_plan.zig").NativeExtraction;
const architecture = @import("native_arch.zig");
pub const ClassicFamily = architecture.ClassicFamily;

/// All entries, including exclusions, consume the byte/member budgets.
/// Extraction shares aggregate budgets across archives at one destination.
/// max_members also bounds canonical/implicit paths in each collision map.
pub const Limits = struct {
    max_archive_bytes: u64 = 256 * 1024 * 1024,
    max_uncompressed_bytes: u64 = 512 * 1024 * 1024,
    max_member_bytes: u64 = 128 * 1024 * 1024,
    max_members: usize = 16384,
    max_path_bytes: usize = 8 * 1024 * 1024,
};

/// Inspect all members without writing files, including modern classpath natives.
pub fn inspect(a: Allocator, io: Io, archive_path: []const u8, cpu_arch: []const u8, cancel: ?*const std.atomic.Value(bool)) !void {
    try inspectWithLimits(a, io, archive_path, cpu_arch, cancel, .{});
}

pub fn inspectWithLimits(a: Allocator, io: Io, archive_path: []const u8, cpu_arch: []const u8, cancel: ?*const std.atomic.Value(bool), limits: Limits) !void {
    try inspectFamilyWithLimits(a, io, archive_path, cpu_arch, cancel, null, limits);
}

pub fn inspectWithFamily(a: Allocator, io: Io, archive_path: []const u8, cpu_arch: []const u8, cancel: ?*const std.atomic.Value(bool), family: ?ClassicFamily) !void {
    try inspectFamilyWithLimits(a, io, archive_path, cpu_arch, cancel, family, .{});
}

fn inspectFamilyWithLimits(a: Allocator, io: Io, archive_path: []const u8, cpu_arch: []const u8, cancel: ?*const std.atomic.Value(bool), family: ?ClassicFamily, limits: Limits) !void {
    var budget: Budget = .{};
    var paths: Paths = .{ .a = a, .limits = limits };
    defer paths.deinit();
    try scanArchive(a, io, null, .{ .archive_path = archive_path, .destination = "", .exclude = &.{}, .classic_family = family }, cpu_arch, cancel, limits, &budget, &paths);
}

/// Borrowed regular file, read positionally from zero; never closed or reopened.
/// The caller retains containment, source stability, and hash verification duties.
pub fn inspectFile(a: Allocator, io: Io, file: Io.File, cpu_arch: []const u8, cancel: ?*const std.atomic.Value(bool)) !void {
    try inspectFileWithFamily(a, io, file, cpu_arch, cancel, null);
}

pub fn inspectFileWithFamily(a: Allocator, io: Io, file: Io.File, cpu_arch: []const u8, cancel: ?*const std.atomic.Value(bool), family: ?ClassicFamily) !void {
    var budget: Budget = .{};
    var paths: Paths = .{ .a = a };
    defer paths.deinit();
    try scanFile(a, io, file, null, .{ .archive_path = "", .destination = "", .exclude = &.{}, .classic_family = family }, cpu_arch, cancel, .{}, &budget, &paths);
}

/// Extract with actual payload CPU checks in the same transaction.
pub fn extractChecked(a: Allocator, io: Io, tasks: []const Task, cpu_arch: []const u8, cancel: ?*const std.atomic.Value(bool)) !void {
    try extractImpl(a, io, tasks, null, null, cpu_arch, cancel);
}

/// sources[i] is the verified archive for tasks[i], held open by the caller.
/// Files are borrowed and read positionally from zero, never closed or reopened.
pub fn extractCheckedFiles(a: Allocator, io: Io, tasks: []const Task, sources: []const Io.File, cpu_arch: []const u8, cancel: ?*const std.atomic.Value(bool)) !void {
    if (sources.len != tasks.len) return error.InvalidNativeSources;
    try extractImpl(a, io, tasks, sources, null, cpu_arch, cancel);
}

/// original_stats[i] must precede the caller's hash and inspection of sources[i].
/// Validate unchanged borrowed sources until publication commits, retaining the
/// previous output for rollback. This is not a source-hash or path-binding proof.
pub fn extractCheckedFilesWithStats(a: Allocator, io: Io, tasks: []const Task, sources: []const Io.File, original_stats: []const Io.File.Stat, cpu_arch: []const u8, cancel: ?*const std.atomic.Value(bool)) !void {
    if (sources.len != tasks.len or original_stats.len != tasks.len) return error.InvalidNativeSources;
    try extractImpl(a, io, tasks, sources, original_stats, cpu_arch, cancel);
}

/// Merge archives sharing a destination into a fresh tree, then publish it.
/// Existing directories are backed up until publication succeeds. A crash during
/// replacement may leave the destination absent and a .native-stage-* backup;
/// it never exposes a partially extracted destination. A failed rollback retains
/// that backup for recovery. No shell or external archive program is used.
pub fn extract(a: Allocator, io: Io, tasks: []const Task, cancel: ?*const std.atomic.Value(bool)) !void {
    try extractImpl(a, io, tasks, null, null, null, cancel);
}

fn extractImpl(a: Allocator, io: Io, tasks: []const Task, sources: ?[]const Io.File, original_stats: ?[]const Io.File.Stat, cpu_arch: ?[]const u8, cancel: ?*const std.atomic.Value(bool)) !void {
    try checkSources(io, sources, original_stats, cancel);
    for (tasks, 0..) |task, i| {
        try checkCancel(cancel);
        var seen = false;
        for (tasks[0..i]) |prior| {
            if (std.mem.eql(u8, prior.destination, task.destination)) {
                seen = true;
                break;
            }
        }
        if (!seen) try extractDestination(a, io, tasks, sources, original_stats, task.destination, cpu_arch, cancel);
    }
}

fn checkSources(io: Io, sources: ?[]const Io.File, original_stats: ?[]const Io.File.Stat, cancel: ?*const std.atomic.Value(bool)) !void {
    const originals = original_stats orelse return;
    const files = sources.?;
    try checkCancel(cancel);
    for (files, originals) |file, before| {
        try checkCancel(cancel);
        const after = try file.stat(io);
        if (before.kind != .file or before.nlink != 1 or
            after.kind != before.kind or after.nlink != before.nlink or
            after.inode != before.inode or after.size != before.size or
            after.mtime.nanoseconds != before.mtime.nanoseconds or
            after.ctime.nanoseconds != before.ctime.nanoseconds) return error.NativeSourceChanged;
    }
    try checkCancel(cancel);
}

fn rollbackPublication(io: Io, parent: Io.Dir, stage: Io.Dir, base: []const u8, had_previous: bool, published: bool, retain_backup: *bool) !void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    if (published) parent.renamePreserve(base, stage, "new", io) catch {
        retain_backup.* = true;
        return error.NativeRollbackFailed;
    };
    if (had_previous) stage.renamePreserve("old", parent, base, io) catch {
        retain_backup.* = true;
        return error.NativeRollbackFailed;
    };
}

fn checkCancel(cancel: ?*const std.atomic.Value(bool)) !void {
    if (cancel) |flag| if (flag.load(.acquire)) return error.Canceled;
}

// Let the host path parser own drive/UNC roots; descend using no-follow handles.
fn openParent(io: Io, path: []const u8) !Io.Dir {
    var parts = std.fs.path.componentIterator(path);
    var dir = if (parts.root()) |root|
        try @import("../worlds_tree.zig").openAbsolute(io, root)
    else
        try Io.Dir.cwd().openDir(io, ".", .{ .follow_symlinks = false });
    errdefer dir.close(io);
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part.name, ".")) continue;
        try safeName(part.name);
        dir.createDir(io, part.name, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const next = try dir.openDir(io, part.name, .{ .follow_symlinks = false });
        dir.close(io);
        dir = next;
    }
    return dir;
}

fn extractDestination(a: Allocator, io: Io, tasks: []const Task, sources: ?[]const Io.File, original_stats: ?[]const Io.File.Stat, destination: []const u8, cpu_arch: ?[]const u8, cancel: ?*const std.atomic.Value(bool)) !void {
    if (destination.len == 0 or std.fs.path.isSep(destination[destination.len - 1])) return error.UnsafePath;
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
        var paths: Paths = .{ .a = a };
        defer paths.deinit();
        var budget: Budget = .{};
        for (tasks, 0..) |task, i| if (std.mem.eql(u8, task.destination, destination)) {
            if (sources) |files| {
                try scanFile(a, io, files[i], output, task, cpu_arch, cancel, .{}, &budget, &paths);
            } else {
                try scanArchive(a, io, output, task, cpu_arch, cancel, .{}, &budget, &paths);
            }
        };
    }
    try checkCancel(cancel);
    try checkSources(io, sources, original_stats, cancel);
    if (old_stat != null) try parent.renamePreserve(base, stage, "old", io);
    checkCancel(cancel) catch |err| {
        try rollbackPublication(io, parent, stage, base, old_stat != null, false, &retain_backup);
        return err;
    };
    checkSources(io, sources, original_stats, cancel) catch |err| {
        try rollbackPublication(io, parent, stage, base, old_stat != null, false, &retain_backup);
        return err;
    };
    stage.renamePreserve("new", parent, base, io) catch |err| {
        try rollbackPublication(io, parent, stage, base, old_stat != null, false, &retain_backup);
        return err;
    };
    checkSources(io, sources, original_stats, cancel) catch |err| {
        try rollbackPublication(io, parent, stage, base, old_stat != null, true, &retain_backup);
        return err;
    };
}

fn safeName(name: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(name) or name.len == 0 or name[0] == '/' or std.mem.indexOfAny(u8, name, "\\:\x00") != null) return error.UnsafePath;
    const trimmed = if (name[name.len - 1] == '/') name[0 .. name.len - 1] else name;
    var parts = std.mem.splitScalar(u8, trimmed, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.UnsafePath;
        if (part[part.len - 1] == '.' or part[part.len - 1] == ' ') return error.UnsafePath;
        var codepoints = std.unicode.Utf8View.initUnchecked(part).iterator();
        while (codepoints.nextCodepoint()) |cp| {
            if (cp < 32 or (cp >= 127 and cp <= 159)) return error.UnsafePath;
            if (cp < 128 and std.mem.indexOfScalar(u8, "<>\"|?*", @intCast(cp)) != null) return error.UnsafePath;
        }
        const stem = std.mem.trimEnd(u8, part[0 .. std.mem.indexOfScalar(u8, part, '.') orelse part.len], " ");
        for ([_][]const u8{ "con", "prn", "aux", "nul", "clock$", "conin$", "conout$" }) |reserved| if (std.ascii.eqlIgnoreCase(stem, reserved)) return error.UnsafePath;
        if (stem.len >= 4 and (std.ascii.eqlIgnoreCase(stem[0..3], "com") or std.ascii.eqlIgnoreCase(stem[0..3], "lpt"))) {
            if (stem.len == 4 and stem[3] >= '1' and stem[3] <= '9') return error.UnsafePath;
            if (stem.len == 5 and stem[3] == 0xc2 and (stem[4] == 0xb9 or stem[4] == 0xb2 or stem[4] == 0xb3)) return error.UnsafePath;
        }
    }
}

const Budget = struct { bytes: u64 = 0, members: usize = 0 };
const Paths = struct {
    const Kind = enum { file, implicit_dir, explicit_dir };
    a: Allocator,
    map: std.StringHashMapUnmanaged(Kind) = .empty,
    limits: Limits = .{},
    bytes: usize = 0,

    fn deinit(self: *Paths) void {
        var it = self.map.keyIterator();
        while (it.next()) |key| self.a.free(key.*);
        self.map.deinit(self.a);
    }

    fn add(self: *Paths, name: []const u8, merge_dirs: bool) !void {
        const directory = name[name.len - 1] == '/';
        const path = if (directory) name[0 .. name.len - 1] else name;
        const key = try self.a.dupe(u8, path);
        defer self.a.free(key);
        for (key) |*c| c.* = std.ascii.toLower(c.*);
        for (key, 0..) |c, i| {
            if (c != '/' and i != key.len - 1) continue;
            const prefix = if (c == '/') key[0..i] else key;
            const final = c != '/';
            const kind: Kind = if (!final) .implicit_dir else if (directory) .explicit_dir else .file;
            if (self.map.getPtr(prefix)) |existing| {
                if (existing.* == .file or (final and kind == .file) or (final and existing.* == .explicit_dir and !merge_dirs)) return error.PathAlreadyExists;
                if (final) existing.* = .explicit_dir;
            } else {
                if (self.map.count() >= self.limits.max_members or prefix.len > self.limits.max_path_bytes -| self.bytes) return error.NativeArchiveLimitExceeded;
                const owned = try self.a.dupe(u8, prefix);
                errdefer self.a.free(owned);
                try self.map.put(self.a, owned, kind);
                self.bytes += prefix.len;
            }
        }
    }
};

// Reject link-carrying Unix extensions rather than trusting only mode bits.
fn checkExtra(extra: []const u8) !void {
    var pos: usize = 0;
    while (pos < extra.len) {
        if (extra.len - pos < 4) return error.ZipBadExtraFieldSize;
        const id = std.mem.readInt(u16, extra[pos..][0..2], .little);
        const size = std.mem.readInt(u16, extra[pos + 2 ..][0..2], .little);
        pos += 4;
        if (size > extra.len - pos) return error.ZipBadExtraFieldSize;
        if (id == 0x000d or id == 0x756e) return error.UnsafeArchiveEntry;
        pos += size;
    }
}

fn readChecked(reader: *Io.Reader, data: []u8, cancel: ?*const std.atomic.Value(bool)) !void {
    var offset: usize = 0;
    while (offset < data.len) {
        try checkCancel(cancel);
        const end = @min(data.len, offset + 8192);
        try reader.readSliceAll(data[offset..end]);
        offset = end;
    }
    try checkCancel(cancel);
}

fn scanArchive(a: Allocator, io: Io, output: ?Io.Dir, task: Task, cpu_arch: ?[]const u8, cancel: ?*const std.atomic.Value(bool), limits: Limits, budget: *Budget, output_paths: *Paths) !void {
    try checkCancel(cancel);
    const file = try Io.Dir.cwd().openFile(io, task.archive_path, .{ .follow_symlinks = false, .allow_directory = false });
    defer file.close(io);
    try scanFile(a, io, file, output, task, cpu_arch, cancel, limits, budget, output_paths);
}

fn scanFile(a: Allocator, io: Io, file: Io.File, output: ?Io.Dir, task: Task, cpu_arch: ?[]const u8, cancel: ?*const std.atomic.Value(bool), limits: Limits, budget: *Budget, output_paths: *Paths) !void {
    try checkCancel(cancel);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.UnsafeArchive;
    if (stat.size > limits.max_archive_bytes) return error.NativeArchiveLimitExceeded;
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    reader.mode = .positional_simple;
    reader.size = stat.size;
    var iterator = try std.zip.Iterator.init(&reader);
    if (iterator.cd_record_count > limits.max_members) return error.NativeArchiveLimitExceeded;
    if (iterator.cd_zip_offset > stat.size or iterator.cd_size > stat.size - iterator.cd_zip_offset) return error.ZipSizeMismatch;
    var names: [std.fs.max_path_bytes]u8 = undefined;
    var local_names: [std.fs.max_path_bytes]u8 = undefined;
    var extra: [std.math.maxInt(u16)]u8 = undefined;
    var archive_paths: Paths = .{ .a = a, .limits = limits };
    defer archive_paths.deinit();
    const Span = struct { start: u64, end: u64 };
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(a);
    var classic: ?architecture.ClassicInventory = if (task.classic_family) |family| .{ .family = family } else null;
    while (true) {
        try checkCancel(cancel);
        if (iterator.cd_record_offset > iterator.cd_size or (iterator.cd_record_index < iterator.cd_record_count and iterator.cd_size - iterator.cd_record_offset < @sizeOf(std.zip.CentralDirectoryFileHeader))) return error.ZipSizeMismatch;
        const entry = try iterator.next() orelse break;
        if (budget.members >= limits.max_members or entry.uncompressed_size > limits.max_member_bytes or entry.compressed_size > limits.max_member_bytes or entry.uncompressed_size > std.math.maxInt(usize) or entry.compressed_size > std.math.maxInt(usize) or entry.uncompressed_size > limits.max_uncompressed_bytes -| budget.bytes) return error.NativeArchiveLimitExceeded;
        budget.members += 1;
        budget.bytes += entry.uncompressed_size;
        if (entry.filename_len > names.len) return error.UnsafePath;
        try reader.seekTo(entry.header_zip_offset);
        const header = try reader.interface.takeStruct(std.zip.CentralDirectoryFileHeader, .little);
        const name = names[0..entry.filename_len];
        try readChecked(&reader.interface, name, cancel);
        try safeName(name);
        try archive_paths.add(name, false);
        try readChecked(&reader.interface, extra[0..header.extra_len], cancel);
        try checkExtra(extra[0..header.extra_len]);
        const directory = name[name.len - 1] == '/';
        const kind = (header.external_file_attributes >> 16) & 0xf000;
        if (kind != 0 and kind != 0x8000 and kind != 0x4000) return error.UnsafeArchiveEntry;
        if ((kind != 0 and (kind == 0x4000) != directory) or (header.external_file_attributes & 0x10 != 0 and !directory)) return error.UnsafeArchiveEntry;
        if (header.external_file_attributes & 0x408 != 0) return error.UnsafeArchiveEntry;
        if (entry.flags.encrypted) return error.UnsafeArchiveEntry;
        if (entry.compression_method != .store and entry.compression_method != .deflate) return error.UnsupportedCompressionMethod;
        if (entry.compression_method == .store and entry.compressed_size != entry.uncompressed_size) return error.ZipSizeMismatch;
        if (directory and entry.uncompressed_size != 0) return error.ZipBadDirectorySize;

        if (entry.file_offset > iterator.cd_zip_offset or iterator.cd_zip_offset - entry.file_offset < @sizeOf(std.zip.LocalFileHeader)) return error.ZipSizeMismatch;
        try reader.seekTo(entry.file_offset);
        const local = try reader.interface.takeStruct(std.zip.LocalFileHeader, .little);
        if (!std.mem.eql(u8, &local.signature, &std.zip.local_file_header_sig) or local.filename_len != name.len or local.compression_method != entry.compression_method or @as(u16, @bitCast(local.flags)) != @as(u16, @bitCast(entry.flags)) or local.version_needed_to_extract != entry.version_needed_to_extract) return error.ZipHeaderMismatch;
        if (local.crc32 != 0 and local.crc32 != entry.crc32) return error.ZipHeaderMismatch;
        if (local.compressed_size != 0 and local.compressed_size != 0xffffffff and local.compressed_size != entry.compressed_size) return error.ZipSizeMismatch;
        if (local.uncompressed_size != 0 and local.uncompressed_size != 0xffffffff and local.uncompressed_size != entry.uncompressed_size) return error.ZipSizeMismatch;
        try readChecked(&reader.interface, local_names[0..local.filename_len], cancel);
        if (!std.mem.eql(u8, name, local_names[0..local.filename_len])) return error.ZipHeaderMismatch;
        try readChecked(&reader.interface, extra[0..local.extra_len], cancel);
        try checkExtra(extra[0..local.extra_len]);
        try checkLocalSizes(local, entry, extra[0..local.extra_len]);
        const data_offset = entry.file_offset + @sizeOf(std.zip.LocalFileHeader) + local.filename_len + local.extra_len;
        if (data_offset > stat.size or entry.compressed_size > stat.size - data_offset or data_offset + entry.compressed_size > iterator.cd_zip_offset) return error.ZipSizeMismatch;
        try spans.append(a, .{ .start = entry.file_offset, .end = data_offset + entry.compressed_size });
        const compressed = try a.alloc(u8, @intCast(entry.compressed_size));
        defer a.free(compressed);
        try readChecked(&reader.interface, compressed, cancel);
        const payload = try a.alloc(u8, @intCast(entry.uncompressed_size));
        defer a.free(payload);
        if (entry.compression_method == .store) {
            var source: Io.Reader = .fixed(compressed);
            try readChecked(&source, payload, cancel);
        } else {
            var source: Io.Reader = .fixed(compressed);
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var decompressor: std.compress.flate.Decompress = .init(&source, .raw, &window);
            try readChecked(&decompressor.reader, payload, cancel);
            var overflow: [1]u8 = undefined;
            if (try decompressor.reader.readSliceShort(&overflow) != 0) return error.ZipSizeMismatch;
            if (source.seek != compressed.len) return error.ZipSizeMismatch;
        }
        try checkCancel(cancel);
        var crc = std.hash.Crc32.init();
        var crc_offset: usize = 0;
        while (crc_offset < payload.len) {
            try checkCancel(cancel);
            const end = @min(payload.len, crc_offset + 8192);
            crc.update(payload[crc_offset..end]);
            crc_offset = end;
        }
        if (crc.final() != entry.crc32) return error.ZipCrcMismatch;
        var compatible = true;
        if (!directory) if (cpu_arch) |arch| {
            if (classic) |*inventory| {
                compatible = try inventory.validateMember(payload, name, arch, cancel);
            } else {
                try architecture.validateChecked(payload, name, arch, cancel);
            }
        };
        var excluded = false;
        for (task.exclude) |prefix| if (std.mem.startsWith(u8, name, prefix)) {
            excluded = true;
            break;
        };
        if (excluded or !compatible) continue;
        try output_paths.add(name, true);
        if (output) |dest| {
            if (directory) {
                try dest.createDirPath(io, name[0 .. name.len - 1]);
            } else {
                if (std.fs.path.dirname(name)) |parent| try dest.createDirPath(io, parent);
                const out = try dest.createFile(io, name, .{ .exclusive = true });
                defer out.close(io);
                var out_buffer: [8192]u8 = undefined;
                var writer = out.writer(io, &out_buffer);
                var offset: usize = 0;
                while (offset < payload.len) {
                    try checkCancel(cancel);
                    const end = @min(payload.len, offset + 8192);
                    try writer.interface.writeAll(payload[offset..end]);
                    offset = end;
                }
                try writer.end();
            }
        }
        try checkCancel(cancel);
    }
    try checkCancel(cancel);
    std.mem.sort(Span, spans.items, {}, struct {
        fn lessThan(_: void, lhs: Span, rhs: Span) bool {
            return lhs.start < rhs.start;
        }
    }.lessThan);
    for (spans.items, 0..) |span, i| {
        try checkCancel(cancel);
        if (i > 0 and span.start < spans.items[i - 1].end) return error.ZipSizeMismatch;
    }
    if (cpu_arch) |arch| if (classic) |inventory| try inventory.complete(arch);
}

fn checkLocalSizes(local: std.zip.LocalFileHeader, entry: std.zip.Iterator.Entry, extra: []const u8) !void {
    var uncompressed: u64 = local.uncompressed_size;
    var compressed: u64 = local.compressed_size;
    var pos: usize = 0;
    while (pos < extra.len) {
        const id = std.mem.readInt(u16, extra[pos..][0..2], .little);
        const size = std.mem.readInt(u16, extra[pos + 2 ..][0..2], .little);
        pos += 4;
        if (id == 1) {
            var data = extra[pos .. pos + size];
            if (uncompressed == 0xffffffff) {
                if (data.len < 8) return error.ZipSizeMismatch;
                uncompressed = std.mem.readInt(u64, data[0..8], .little);
                data = data[8..];
            }
            if (compressed == 0xffffffff) {
                if (data.len < 8) return error.ZipSizeMismatch;
                compressed = std.mem.readInt(u64, data[0..8], .little);
            }
        }
        pos += size;
    }
    const descriptor = @as(u16, @bitCast(local.flags)) & 8 != 0;
    if ((!descriptor or uncompressed != 0) and uncompressed != entry.uncompressed_size) return error.ZipSizeMismatch;
    if ((!descriptor or compressed != 0) and compressed != entry.compressed_size) return error.ZipSizeMismatch;
    if (!descriptor and local.crc32 != entry.crc32) return error.ZipHeaderMismatch;
}

test "reject unsafe archive names" {
    for ([_][]const u8{ "", "/native.so", "../x", "a/../b", "a\\b", "C:x", "a//b", "a/./b", "nul.dll", "a. ", "x\x00y" }) |name| try std.testing.expectError(error.UnsafePath, safeName(name));
    try safeName("linux/x64/native.so");
    try safeName("META-INF/");
    try safeName("中文目录/库.so");
    for ([_][]const u8{ "a\x1fb", "a\x7fb", "a\xc2\x80b", "a\xc2\x9fb", "\xff", "COM¹", "LPT².dll", "CON .json", "clock$.json", "CONIN$", "CONOUT$" }) |name| try std.testing.expectError(error.UnsafePath, safeName(name));
}

const Fixture = struct {
    name: []const u8,
    data: []const u8 = "native",
    attributes: u32 = 0x81a40000,
    deflate: bool = false,
    bad_crc: bool = false,
    extra: []const u8 = &.{},
    declared_size: ?u32 = null,
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
        h.uncompressed_size = entry.declared_size orelse @intCast(entry.data.len);
        h.compressed_size = @as(u32, @intCast(entry.data.len)) + @as(u32, if (entry.deflate) 5 else 0);
        h.extra_len = @intCast(entry.extra.len);
        h.filename_len = @intCast(entry.name.len);
        try w.writeStruct(h, .little);
        try w.writeAll(entry.name);
        try w.writeAll(entry.extra);
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
        h.uncompressed_size = entry.declared_size orelse @intCast(entry.data.len);
        h.compressed_size = @as(u32, @intCast(entry.data.len)) + @as(u32, if (entry.deflate) 5 else 0);
        h.extra_len = @intCast(entry.extra.len);
        h.filename_len = @intCast(entry.name.len);
        h.external_file_attributes = entry.attributes;
        h.local_file_header_offset = offsets[i];
        try w.writeStruct(h, .little);
        try w.writeAll(entry.name);
        try w.writeAll(entry.extra);
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

fn elfFixture(machine: u16) [64]u8 {
    var data: [64]u8 = @splat(0);
    @memcpy(data[0..4], "\x7fELF");
    data[4] = 2;
    data[5] = 1;
    data[6] = 1;
    std.mem.writeInt(u16, data[16..18], 3, .little);
    std.mem.writeInt(u16, data[18..20], machine, .little);
    std.mem.writeInt(u32, data[20..24], 1, .little);
    std.mem.writeInt(u16, data[52..54], 64, .little);
    return data;
}

fn peFixture(machine: u16) [200]u8 {
    var data: [200]u8 = @splat(0);
    @memcpy(data[0..2], "MZ");
    std.mem.writeInt(u32, data[60..64], 64, .little);
    @memcpy(data[64..68], "PE\x00\x00");
    std.mem.writeInt(u16, data[68..70], machine, .little);
    std.mem.writeInt(u16, data[84..86], 112, .little);
    std.mem.writeInt(u16, data[88..90], 0x20b, .little);
    return data;
}

fn machFixture(machine: u32, endian: std.builtin.Endian) [32]u8 {
    var data: [32]u8 = @splat(0);
    std.mem.writeInt(u32, data[0..4], 0xfeedfacf, endian);
    std.mem.writeInt(u32, data[4..8], machine, endian);
    std.mem.writeInt(u32, data[12..16], 6, endian);
    return data;
}

fn fatFixture(wide: bool, endian: std.builtin.Endian) [136]u8 {
    var data: [136]u8 = @splat(0);
    std.mem.writeInt(u32, data[0..4], if (wide) 0xcafebabf else 0xcafebabe, endian);
    std.mem.writeInt(u32, data[4..8], 2, endian);
    const record: usize = if (wide) 32 else 20;
    for ([_]u32{ 0x01000007, 0x0100000c }, 0..) |machine, i| {
        const p = 8 + i * record;
        const off = 72 + i * 32;
        std.mem.writeInt(u32, data[p..][0..4], machine, endian);
        if (wide) {
            std.mem.writeInt(u64, data[p + 8 ..][0..8], off, endian);
            std.mem.writeInt(u64, data[p + 16 ..][0..8], 32, endian);
        } else {
            std.mem.writeInt(u32, data[p + 8 ..][0..4], @intCast(off), endian);
            std.mem.writeInt(u32, data[p + 12 ..][0..4], 32, endian);
        }
        @memcpy(data[off..][0..32], &machFixture(machine, endian));
    }
    return data;
}

test "LWJGL metadata sidecars remain resources while renamed binaries retain CPU checks" {
    const metadata = "META-INF/linux/x64/org/lwjgl/freetype/libfreetype.so";
    try architecture.validate("0a0221a1347e2f1e", metadata ++ ".git", "x86_64");
    try architecture.validate("da3f35a8c9dbf22b\n", metadata ++ ".sha1", "x86_64");
    try std.testing.expectError(error.InvalidNativePayload, architecture.validate("text", "lib.so.1", "x86_64"));
    try std.testing.expectError(error.InvalidNativePayload, architecture.validate("text", "linux/x64/lib.so.sha1", "x86_64"));
    const matching = elfFixture(62);
    const wrong_cpu = elfFixture(183);
    try architecture.validate(&matching, "linux/x64/libfreetype.so", "x86_64");
    try std.testing.expectError(error.NativeArchitectureMismatch, architecture.validate(&wrong_cpu, metadata ++ ".git", "x86_64"));
    try std.testing.expectError(error.InvalidNativePayload, architecture.validate(matching[0..20], metadata ++ ".sha1", "x86_64"));
    const old = "linux/x64/org/lwjgl/liblwjgl.so";
    const git = "ad602750ad87939276d1889b28a757061e90715b\n";
    const sha1 = "b47ef1a16b9ff2143bca544d4fed43d51bb6b92d\r\n";
    try architecture.validate(git, old ++ ".git", "x86_64");
    try architecture.validate(sha1, old ++ ".sha1", "x86_64");
    try architecture.validate(sha1, "linux/x64/org/lwjgl/openal/libopenal.so.sha1", "x86_64");
    for ([_][]const u8{ "text", git[0..39], git ++ "\n", "g" ++ git[1..], sha1[0..41] }) |bad| {
        try std.testing.expectError(error.InvalidNativePayload, architecture.validate(bad, old ++ ".sha1", "x86_64"));
    }
    for ([_][]const u8{ "liblwjgl.so.sha1", "linux/x64/liblwjgl.so.sha1", "linux/x64/org/other/liblwjgl.so.sha1", "linux/x64/org/lwjgl/../liblwjgl.so.sha1", "linux/x64/org/lwjgl/liblwjgl.so.1.sha1" }) |unrelated| {
        try std.testing.expectError(error.InvalidNativePayload, architecture.validate(sha1, unrelated, "x86_64"));
    }
    try std.testing.expectError(error.NativeArchitectureMismatch, architecture.validate(&wrong_cpu, old ++ ".git", "x86_64"));
    try std.testing.expectError(error.InvalidNativePayload, architecture.validate(matching[0..20], old ++ ".sha1", "x86_64"));
}

test "LWJGL 3.3.1 Linux inventory extracts digests without weakening archive and CPU checks" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const archive = try std.fs.path.join(a, &.{ root, "native.jar" });
    defer a.free(archive);
    const destination = try std.fs.path.join(a, &.{ root, "natives" });
    defer a.free(destination);
    const name = "linux/x64/org/lwjgl/liblwjgl.so";
    // Exact sidecar bytes from the official lwjgl-3.3.1-natives-linux.jar.
    const git = "ad602750ad87939276d1889b28a757061e90715b\n";
    const sha1 = "b47ef1a16b9ff2143bca544d4fed43d51bb6b92d\r\n";
    const matching = elfFixture(62);
    const wrong = elfFixture(183);
    const good = try fixtureZip(a, &.{
        .{ .name = name, .data = &matching, .deflate = true },
        .{ .name = name ++ ".git", .data = git },
        .{ .name = name ++ ".sha1", .data = sha1, .deflate = true },
    });
    defer a.free(good);
    try tmp.dir.writeFile(io, .{ .sub_path = "native.jar", .data = good });
    try inspect(a, io, archive, "x86_64", null);
    try std.testing.expectError(error.NativeArchiveLimitExceeded, inspectWithLimits(a, io, archive, "x86_64", null, .{ .max_uncompressed_bytes = matching.len + git.len + sha1.len - 1 }));
    const task: Task = .{ .archive_path = archive, .destination = destination, .exclude = &.{} };
    try extractChecked(a, io, &.{task}, "x86_64", null);
    try expectFile(tmp.dir, "natives/" ++ name, &matching);
    try expectFile(tmp.dir, "natives/" ++ name ++ ".git", git);
    try expectFile(tmp.dir, "natives/" ++ name ++ ".sha1", sha1);
    const Case = struct { member: Fixture, failure: anyerror };
    for ([_]Case{
        .{ .member = .{ .name = name ++ ".sha1", .data = "not a digest" }, .failure = error.InvalidNativePayload },
        .{ .member = .{ .name = name ++ ".git", .data = &wrong }, .failure = error.NativeArchitectureMismatch },
        .{ .member = .{ .name = name ++ ".sha1", .data = matching[0..20] }, .failure = error.InvalidNativePayload },
        .{ .member = .{ .name = name ++ ".sha1", .data = sha1, .bad_crc = true }, .failure = error.ZipCrcMismatch },
        .{ .member = .{ .name = name ++ ".git", .data = git, .attributes = 0xa1ff0000 }, .failure = error.UnsafeArchiveEntry },
    }) |case| {
        const bad = try fixtureZip(a, &.{case.member});
        defer a.free(bad);
        try tmp.dir.writeFile(io, .{ .sub_path = "native.jar", .data = bad });
        try std.testing.expectError(case.failure, inspect(a, io, archive, "x86_64", null));
        try std.testing.expectError(case.failure, extractChecked(a, io, &.{task}, "x86_64", null));
        try expectFile(tmp.dir, "natives/" ++ name, &matching);
        try expectFile(tmp.dir, "natives/" ++ name ++ ".sha1", sha1);
    }
}

test "actual ELF PE Mach-O and universal headers determine native CPU" {
    const elf_x64 = elfFixture(62);
    const elf_arm = elfFixture(183);
    const pe_x64 = peFixture(0x8664);
    const pe_arm = peFixture(0xaa64);
    const mach_x64 = machFixture(0x01000007, .little);
    const mach_arm = machFixture(0x0100000c, .big);
    for ([_][]const u8{ &elf_x64, &pe_x64, &mach_x64 }) |data| {
        try architecture.validate(data, "resource.dat", "x86_64");
        try std.testing.expectError(error.NativeArchitectureMismatch, architecture.validate(data, "resource.dat", "aarch64"));
        try std.testing.expectError(error.InvalidNativePayload, architecture.validate(data[0..20], "native.so", "x86_64"));
    }
    for ([_][]const u8{ &elf_arm, &pe_arm, &mach_arm }) |data| {
        try architecture.validate(data, "resource.dat", "arm64");
        try std.testing.expectError(error.NativeArchitectureMismatch, architecture.validate(data, "resource.dat", "amd64"));
    }
    for ([_]bool{ false, true }) |wide| for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        const data = fatFixture(wide, endian);
        try architecture.validate(&data, "native.dylib", "x86_64");
        try architecture.validate(&data, "native.dylib", "aarch64");
        try std.testing.expectError(error.NativeArchitectureMismatch, architecture.validate(&data, "native.dylib", "x86"));
        try std.testing.expectError(error.InvalidNativePayload, architecture.validate(data[0..100], "native.dylib", "x86_64"));
    };
    try std.testing.expectError(error.InvalidNativePayload, architecture.validate("text", "lib.so.1", "x86_64"));
    try std.testing.expectError(error.InvalidNativePayload, architecture.validate("MZ", "resource.bin", "x86_64"));
    try architecture.validate("metadata", "META-INF/MANIFEST.MF", "x86_64");
    try architecture.validate("\xca\xfe\xba\xbe\x00\x00\x00\x34\x00\x02\x07", "Example.class", "x86_64");
}

test "inspect archives checks payloads including renamed and classpath natives without publication" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const archive = try std.fs.path.join(a, &.{ root, "native.jar" });
    defer a.free(archive);
    const destination = try std.fs.path.join(a, &.{ root, "natives" });
    defer a.free(destination);
    const matching = elfFixture(62);
    const wrong = peFixture(0xaa64);
    const good_zip = try fixtureZip(a, &.{ .{ .name = "META-INF/MANIFEST.MF", .data = "manifest" }, .{ .name = "native.so", .data = &matching, .deflate = true } });
    defer a.free(good_zip);
    try tmp.dir.writeFile(io, .{ .sub_path = "native.jar", .data = good_zip });
    try inspect(a, io, archive, "x86_64", null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "natives", .{}));
    const task: Task = .{ .archive_path = archive, .destination = destination, .exclude = &.{} };
    try extractChecked(a, io, &.{task}, "x86_64", null);
    try expectFile(tmp.dir, "natives/native.so", &matching);
    const bad_zip = try fixtureZip(a, &.{ .{ .name = "partial.so", .data = &matching }, .{ .name = "cpu-hidden.dat", .data = &wrong } });
    defer a.free(bad_zip);
    try tmp.dir.writeFile(io, .{ .sub_path = "native.jar", .data = bad_zip });
    try std.testing.expectError(error.NativeArchitectureMismatch, inspect(a, io, archive, "x86_64", null));
    try std.testing.expectError(error.NativeArchitectureMismatch, extractChecked(a, io, &.{task}, "x86_64", null));
    try expectFile(tmp.dir, "natives/native.so", &matching);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "natives/partial.so", .{}));
    const unknown_zip = try fixtureZip(a, &.{.{ .name = "fake.so" }});
    defer a.free(unknown_zip);
    try tmp.dir.writeFile(io, .{ .sub_path = "native.jar", .data = unknown_zip });
    try std.testing.expectError(error.InvalidNativePayload, inspect(a, io, archive, "x86_64", null));
    var cancel: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.Canceled, inspect(a, io, archive, "x86_64", &cancel));
    try std.testing.expectError(error.Canceled, extractChecked(a, io, &.{task}, "x86_64", &cancel));
    try expectFile(tmp.dir, "natives/native.so", &matching);
}

test "inspection rejects bounds links path collisions and deflate size lies" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const archive = try std.fs.path.join(a, &.{ root, "test.zip" });
    defer a.free(archive);
    const data = elfFixture(62);
    const zip = try fixtureZip(a, &.{ .{ .name = "lib.so", .data = &data, .deflate = true }, .{ .name = "resource", .data = "text" } });
    defer a.free(zip);
    try tmp.dir.writeFile(io, .{ .sub_path = "test.zip", .data = zip });
    const limits = [_]Limits{ .{ .max_archive_bytes = zip.len - 1 }, .{ .max_member_bytes = data.len - 1 }, .{ .max_uncompressed_bytes = data.len + 3 }, .{ .max_members = 1 }, .{ .max_path_bytes = 5 } };
    for (limits) |limit| try std.testing.expectError(error.NativeArchiveLimitExceeded, inspectWithLimits(a, io, archive, "x86_64", null, limit));
    const cases = [_]struct { entries: []const Fixture, err: anyerror }{
        .{ .entries = &.{.{ .name = "../escape" }}, .err = error.UnsafePath },
        .{ .entries = &.{.{ .name = "link", .attributes = 0xa1ff0000 }}, .err = error.UnsafeArchiveEntry },
        .{ .entries = &.{.{ .name = "hardlink", .extra = "\x0d\x00\x06\x00target" }}, .err = error.UnsafeArchiveEntry },
        .{ .entries = &.{ .{ .name = "Name" }, .{ .name = "name" } }, .err = error.PathAlreadyExists },
        .{ .entries = &.{ .{ .name = "parent" }, .{ .name = "parent/child" } }, .err = error.PathAlreadyExists },
        .{ .entries = &.{ .{ .name = "parent/child" }, .{ .name = "parent" } }, .err = error.PathAlreadyExists },
        .{ .entries = &.{.{ .name = "x", .deflate = true, .declared_size = 5 }}, .err = error.ZipSizeMismatch },
    };
    for (cases) |case| {
        const bad = try fixtureZip(a, case.entries);
        defer a.free(bad);
        try tmp.dir.writeFile(io, .{ .sub_path = "test.zip", .data = bad });
        try std.testing.expectError(case.err, inspect(a, io, archive, "x86_64", null));
    }
}

test "cancellation interrupts chunked reads before consuming the next chunk" {
    const CancelingReader = struct {
        reader: Io.Reader,
        flag: *std.atomic.Value(bool),
        calls: usize = 0,

        fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
            const self: *@This() = @fieldParentPtr("reader", r);
            const data: [8192]u8 = @splat(0);
            const n = limit.minInt(data.len);
            try w.writeAll(data[0..n]);
            self.calls += 1;
            self.flag.store(true, .release);
            return n;
        }
    };
    var flag: std.atomic.Value(bool) = .init(false);
    var source: CancelingReader = .{
        .reader = .{ .vtable = &.{ .stream = CancelingReader.stream }, .buffer = &.{}, .seek = 0, .end = 0 },
        .flag = &flag,
    };
    var payload: [16384]u8 = undefined;
    try std.testing.expectError(error.Canceled, readChecked(&source.reader, &payload, &flag));
    try std.testing.expectEqual(@as(usize, 1), source.calls);
}

test "malformed executable tables fail closed" {
    var elf = elfFixture(62);
    std.mem.writeInt(u64, elf[32..40], 64, .little);
    std.mem.writeInt(u16, elf[54..56], 56, .little);
    std.mem.writeInt(u16, elf[56..58], 1, .little);
    try std.testing.expectError(error.InvalidNativePayload, architecture.validate(&elf, "bad.so", "x86_64"));
    var pe = peFixture(0x8664);
    std.mem.writeInt(u32, pe[60..64], 0xffffffff, .little);
    try std.testing.expectError(error.InvalidNativePayload, architecture.validate(&pe, "bad.dll", "x86_64"));
    var mach = machFixture(0x01000007, .little);
    std.mem.writeInt(u32, mach[16..20], 1, .little);
    try std.testing.expectError(error.InvalidNativePayload, architecture.validate(&mach, "bad.dylib", "x86_64"));
    var fat = fatFixture(false, .big);
    std.mem.writeInt(u32, fat[36..40], 72, .big);
    try std.testing.expectError(error.InvalidNativePayload, architecture.validate(&fat, "bad.dylib", "x86_64"));
}

test "authenticated classic layouts validate both CPUs and extract only compatible members" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Layout = struct { family: ClassicFamily, names: []const []const u8, windows: bool = false };
    for ([_]Layout{
        .{ .family = .lwjgl2_linux, .names = &.{ "liblwjgl.so", "liblwjgl64.so", "libopenal.so", "libopenal64.so" } },
        .{ .family = .jinput_linux, .names = &.{ "libjinput-linux.so", "libjinput-linux64.so" } },
        .{ .family = .lwjgl2_windows, .names = &.{ "lwjgl.dll", "lwjgl64.dll", "OpenAL32.dll", "OpenAL64.dll" }, .windows = true },
        .{ .family = .jinput_windows, .names = &.{ "jinput-dx8.dll", "jinput-dx8_64.dll", "jinput-raw.dll", "jinput-raw_64.dll", "jinput-wintab.dll" }, .windows = true },
    }) |layout| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        const archive = try std.fs.path.join(a, &.{ root, "native.jar" });
        defer a.free(archive);
        const destination = try std.fs.path.join(a, &.{ root, "natives" });
        defer a.free(destination);
        var elf32 = elfFixture(3);
        elf32[4] = 1;
        std.mem.writeInt(u16, elf32[52..54], 0, .little);
        std.mem.writeInt(u16, elf32[40..42], 52, .little);
        const elf64 = elfFixture(62);
        var pe32 = peFixture(0x14c);
        std.mem.writeInt(u16, pe32[88..90], 0x10b, .little);
        const pe64 = peFixture(0x8664);
        const narrow: []const u8 = if (layout.windows) &pe32 else &elf32;
        const wide: []const u8 = if (layout.windows) &pe64 else &elf64;
        var entries: [5]Fixture = undefined;
        for (layout.names, 0..) |name, i| entries[i] = .{ .name = name, .data = if (i % 2 == 0) narrow else wide, .deflate = true };
        const zip = try fixtureZip(a, entries[0..layout.names.len]);
        defer a.free(zip);
        try tmp.dir.writeFile(io, .{ .sub_path = "native.jar", .data = zip });
        const source = try tmp.dir.openFile(io, "native.jar", .{});
        defer source.close(io);
        const original = try source.stat(io);
        try std.testing.expectError(error.NativeArchitectureMismatch, inspectFile(a, io, source, "x86_64", null));
        try std.testing.expectError(error.NativeArchitectureMismatch, inspectFileWithFamily(a, io, source, "aarch64", null, layout.family));
        const task: Task = .{ .archive_path = archive, .destination = destination, .exclude = &.{}, .classic_family = layout.family };
        for ([_][]const u8{ "x86_64", "i386" }, 0..) |host, host_index| {
            try inspectWithFamily(a, io, archive, host, null, layout.family);
            try inspectFileWithFamily(a, io, source, host, null, layout.family);
            try extractCheckedFilesWithStats(a, io, &.{task}, &.{source}, &.{original}, host, null);
            const output = try tmp.dir.openDir(io, "natives", .{});
            defer output.close(io);
            for (layout.names, 0..) |name, i| {
                const selected = (i % 2 == 1) == (host_index == 0);
                if (!selected) {
                    try std.testing.expectError(error.FileNotFound, output.statFile(io, name, .{}));
                    continue;
                }
                const file = try output.openFile(io, name, .{});
                defer file.close(io);
                var reader = file.reader(io, &.{});
                var bytes: [200]u8 = undefined;
                const expected = entries[i].data;
                try reader.interface.readSliceAll(bytes[0..expected.len]);
                try std.testing.expectEqualSlices(u8, expected, bytes[0..expected.len]);
                try std.testing.expectEqual(@as(u64, expected.len), (try file.stat(io)).size);
            }
        }
    }
}

test "classic peers cannot bypass completeness CRC path links budgets or native CPU validation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const archive = try std.fs.path.join(a, &.{ root, "native.jar" });
    defer a.free(archive);
    const destination = try std.fs.path.join(a, &.{ root, "natives" });
    defer a.free(destination);
    var narrow = elfFixture(3);
    narrow[4] = 1;
    std.mem.writeInt(u16, narrow[52..54], 0, .little);
    std.mem.writeInt(u16, narrow[40..42], 52, .little);
    const wide = elfFixture(62);
    const good_entries = [_]Fixture{
        .{ .name = "libjinput-linux.so", .data = &narrow },
        .{ .name = "libjinput-linux64.so", .data = &wide },
    };
    const good = try fixtureZip(a, &good_entries);
    defer a.free(good);
    const task: Task = .{ .archive_path = archive, .destination = destination, .exclude = &.{"libjinput-linux.so"}, .classic_family = .jinput_linux };
    try tmp.dir.writeFile(io, .{ .sub_path = "native.jar", .data = good });
    try extractChecked(a, io, &.{task}, "x86_64", null);
    try std.testing.expectError(error.NativeArchiveLimitExceeded, inspectFamilyWithLimits(a, io, archive, "x86_64", null, .jinput_linux, .{ .max_uncompressed_bytes = narrow.len + wide.len - 1 }));
    const Case = struct { peer: Fixture, failure: anyerror, omit_wide: bool = false, extra: ?Fixture = null };
    for ([_]Case{
        .{ .peer = good_entries[0], .failure = error.NativeArchitectureMismatch, .omit_wide = true },
        .{ .peer = .{ .name = "libjinput-linux.so", .data = &wide }, .failure = error.NativeArchitectureMismatch },
        .{ .peer = .{ .name = "libjinput-linux.so", .data = narrow[0..20] }, .failure = error.InvalidNativePayload },
        .{ .peer = .{ .name = "libjinput-linux.so", .data = &narrow, .bad_crc = true }, .failure = error.ZipCrcMismatch },
        .{ .peer = .{ .name = "libjinput-linux.so", .data = &narrow, .attributes = 0xa1ff0000 }, .failure = error.UnsafeArchiveEntry },
        .{ .peer = .{ .name = "../libjinput-linux.so", .data = &narrow }, .failure = error.UnsafePath },
        .{ .peer = .{ .name = "renamed.dat", .data = &narrow }, .failure = error.NativeArchitectureMismatch },
        .{ .peer = good_entries[0], .failure = error.NativeArchitectureMismatch, .extra = .{ .name = "unrecognized.so", .data = &narrow } },
    }) |case| {
        var entries = [_]Fixture{ case.peer, good_entries[1], undefined };
        var count: usize = if (case.omit_wide) 1 else 2;
        if (case.extra) |extra| {
            entries[count] = extra;
            count += 1;
        }
        const bad = try fixtureZip(a, entries[0..count]);
        defer a.free(bad);
        try tmp.dir.writeFile(io, .{ .sub_path = "native.jar", .data = bad });
        try std.testing.expectError(case.failure, inspectWithFamily(a, io, archive, "x86_64", null, .jinput_linux));
        try std.testing.expectError(case.failure, extractChecked(a, io, &.{task}, "x86_64", null));
        try expectFile(tmp.dir, "natives/libjinput-linux64.so", &wide);
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "natives/libjinput-linux.so", .{}));
    }
}

test "32 bit native headers and unrelated universal slices" {
    for ([_]u16{ 3, 40 }, [_][]const u8{ "i386", "armv7l" }) |machine, wanted| {
        var elf = elfFixture(machine);
        elf[4] = 1;
        std.mem.writeInt(u16, elf[52..54], 0, .little);
        std.mem.writeInt(u16, elf[40..42], 52, .little);
        try architecture.validate(&elf, "native.so", wanted);
        try std.testing.expectError(error.NativeArchitectureMismatch, architecture.validate(&elf, "native.so", "x86_64"));
    }
    for ([_]u16{ 0x14c, 0x1c4 }, [_][]const u8{ "x86", "arm" }) |machine, wanted| {
        var pe = peFixture(machine);
        std.mem.writeInt(u16, pe[88..90], 0x10b, .little);
        try architecture.validate(&pe, "native.dll", wanted);
        try std.testing.expectError(error.NativeArchitectureMismatch, architecture.validate(&pe, "native.dll", "x86_64"));
    }
    for ([_]u32{ 7, 12 }, [_][]const u8{ "x86", "arm" }) |machine, wanted| {
        var mach = machFixture(machine, .little);
        std.mem.writeInt(u32, mach[0..4], 0xfeedface, .little);
        try architecture.validate(&mach, "native.dylib", wanted);
        try std.testing.expectError(error.NativeArchitectureMismatch, architecture.validate(&mach, "native.dylib", "x86_64"));
    }
    var fat = fatFixture(false, .big);
    std.mem.writeInt(u32, fat[8..12], 0x01000012, .big);
    std.mem.writeInt(u32, fat[76..80], 0x01000012, .big);
    try architecture.validate(&fat, "native.dylib", "aarch64");
    try std.testing.expectError(error.NativeArchitectureMismatch, architecture.validate(&fat, "Renamed.class", "x86_64"));
}

test "implicit archive parent paths have bounded bookkeeping" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const archive = try std.fs.path.join(a, &.{ root, "nested.zip" });
    defer a.free(archive);
    const zip = try fixtureZip(a, &.{.{ .name = "a/b/c", .data = "" }});
    defer a.free(zip);
    try tmp.dir.writeFile(io, .{ .sub_path = "nested.zip", .data = zip });
    try std.testing.expectError(error.NativeArchiveLimitExceeded, inspectWithLimits(a, io, archive, "x86_64", null, .{ .max_members = 2 }));
}

test "cancellation before publication rolls back but late cancellation retains success" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Hook = struct {
        var flag: ?*std.atomic.Value(bool) = null;
        var cancel_on: enum { backup, publish } = .backup;
        var delegate: @TypeOf(io.vtable.dirRenamePreserve) = undefined;

        fn rename(userdata: ?*anyopaque, old_dir: Io.Dir, old_name: []const u8, new_dir: Io.Dir, new_name: []const u8) Io.Dir.RenamePreserveError!void {
            try delegate(userdata, old_dir, old_name, new_dir, new_name);
            const trigger = if (cancel_on == .backup) std.mem.eql(u8, new_name, "old") else std.mem.eql(u8, old_name, "new");
            if (trigger) if (flag) |f| f.store(true, .release);
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const archive = try std.fs.path.join(a, &.{ root, "native.zip" });
    defer a.free(archive);
    const destination = try std.fs.path.join(a, &.{ root, "natives" });
    defer a.free(destination);
    const zip = try fixtureZip(a, &.{.{ .name = "new.so" }});
    defer a.free(zip);
    try tmp.dir.writeFile(io, .{ .sub_path = "native.zip", .data = zip });
    try tmp.dir.createDir(io, "natives", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "natives/old", .data = "previous" });
    var flag: std.atomic.Value(bool) = .init(false);
    Hook.flag = &flag;
    defer Hook.flag = null;
    Hook.delegate = io.vtable.dirRenamePreserve;
    var vtable = io.vtable.*;
    vtable.dirRenamePreserve = Hook.rename;
    const hooked_io: Io = .{ .userdata = io.userdata, .vtable = &vtable };
    const task: Task = .{ .archive_path = archive, .destination = destination, .exclude = &.{} };
    Hook.cancel_on = .backup;
    try std.testing.expectError(error.Canceled, extract(a, hooked_io, &.{task}, &flag));
    try expectFile(tmp.dir, "natives/old", "previous");
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "natives/new.so", .{}));
    flag.store(false, .release);
    Hook.cancel_on = .publish;
    try extract(a, hooked_io, &.{task}, &flag);
    try std.testing.expect(flag.load(.acquire));
    try expectFile(tmp.dir, "natives/new.so", "native");
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "natives/old", .{}));
    var listing = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer listing.close(io);
    var it = listing.iterate();
    while (try it.next(io)) |entry| try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".native-stage-"));
}

test "borrowed native sources retain ownership and ignore replaced archive paths" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = elfFixture(62);
    const zip = try fixtureZip(a, &.{.{ .name = "native.so", .data = &data }});
    defer a.free(zip);
    try tmp.dir.writeFile(io, .{ .sub_path = "native.jar", .data = zip });
    const source = try tmp.dir.openFile(io, "native.jar", .{ .follow_symlinks = false });
    defer source.close(io);
    const archive = try tmp.dir.realPathFileAlloc(io, "native.jar", a);
    defer a.free(archive);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const destination = try std.fs.path.join(a, &.{ root, "natives" });
    defer a.free(destination);
    const task: Task = .{ .archive_path = archive, .destination = destination, .exclude = &.{} };
    var stream = source.readerStreaming(io, &.{});
    var bytes: [4]u8 = undefined;
    try stream.interface.readSliceAll(&bytes);
    try std.testing.expectEqualSlices(u8, zip[0..4], &bytes);
    try tmp.dir.rename("native.jar", tmp.dir, "verified.jar", io);
    try tmp.dir.writeFile(io, .{ .sub_path = "replacement.jar", .data = "not a ZIP" });
    try tmp.dir.symLink(io, "replacement.jar", "native.jar", .{});
    try inspectFile(a, io, source, "x86_64", null);
    try stream.interface.readSliceAll(&bytes);
    try std.testing.expectEqualSlices(u8, zip[4..8], &bytes);
    try std.testing.expectError(error.InvalidNativeSources, extractCheckedFiles(a, io, &.{task}, &.{}, "x86_64", null));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "natives", .{}));
    try extractCheckedFiles(a, io, &.{task}, &.{source}, "x86_64", null);
    try expectFile(tmp.dir, "natives/native.so", &data);
    try std.testing.expectEqual(@as(u64, zip.len), (try source.stat(io)).size);
}

test "borrowed native sources use shared CRC CPU and cancellation checks" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = elfFixture(62);
    const zip = try fixtureZip(a, &.{.{ .name = "native.so", .data = &data, .bad_crc = true }});
    defer a.free(zip);
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.jar", .data = zip });
    const file = try tmp.dir.openFile(io, "bad.jar", .{ .follow_symlinks = false });
    defer file.close(io);
    try std.testing.expectError(error.ZipCrcMismatch, inspectFile(a, io, file, "x86_64", null));
    var canceled: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.Canceled, inspectFile(a, io, file, "x86_64", &canceled));
    const good = try fixtureZip(a, &.{.{ .name = "native.so", .data = &data }});
    defer a.free(good);
    try tmp.dir.writeFile(io, .{ .sub_path = "good.jar", .data = good });
    const other = try tmp.dir.openFile(io, "good.jar", .{ .follow_symlinks = false });
    defer other.close(io);
    try std.testing.expectError(error.NativeArchitectureMismatch, inspectFile(a, io, other, "aarch64", null));
    _ = try file.stat(io);
    _ = try other.stat(io);
}

test "checked native source baselines reject every identity field before writes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = elfFixture(62);
    const zip = try fixtureZip(a, &.{.{ .name = "native.so", .data = &data }});
    defer a.free(zip);
    try tmp.dir.writeFile(io, .{ .sub_path = "native.jar", .data = zip });
    const source = try tmp.dir.openFile(io, "native.jar", .{ .follow_symlinks = false });
    defer source.close(io);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const destination = try std.fs.path.join(a, &.{ root, "natives" });
    defer a.free(destination);
    const task: Task = .{ .archive_path = "not reopened", .destination = destination, .exclude = &.{} };
    const original = try source.stat(io);
    try inspectFile(a, io, source, "x86_64", null);
    try std.testing.expectError(error.InvalidNativeSources, extractCheckedFilesWithStats(a, io, &.{task}, &.{source}, &.{}, "x86_64", null));
    try std.testing.expectError(error.InvalidNativeSources, extractCheckedFilesWithStats(a, io, &.{task}, &.{}, &.{original}, "x86_64", null));
    inline for (.{ "inode", "size", "nlink", "kind", "mtime", "ctime" }) |field| {
        var stale = original;
        if (comptime std.mem.eql(u8, field, "kind")) {
            stale.kind = .directory;
        } else if (comptime std.mem.eql(u8, field, "mtime") or std.mem.eql(u8, field, "ctime")) {
            @field(stale, field).nanoseconds += 1;
        } else {
            @field(stale, field) += 1;
        }
        try std.testing.expectError(error.NativeSourceChanged, extractCheckedFilesWithStats(a, io, &.{task}, &.{source}, &.{stale}, "x86_64", null));
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "natives", .{}));
    }
    var stream = source.readerStreaming(io, &.{});
    var bytes: [4]u8 = undefined;
    try stream.interface.readSliceAll(&bytes);
    try extractCheckedFilesWithStats(a, io, &.{task}, &.{source}, &.{original}, "x86_64", null);
    try stream.interface.readSliceAll(&bytes);
    try std.testing.expectEqualSlices(u8, zip[4..8], &bytes);
    try expectFile(tmp.dir, "natives/native.so", &data);
    _ = try source.stat(io);
}

test "native original baselines survive restored bytes and publication rollback" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Hook = struct {
        const Phase = enum { roundtrip, backup_mutation, publish_mutation, backup_cancel, publish_cancel, final_stat_cancel };
        var phase: Phase = .roundtrip;
        var source: Io.File = undefined;
        var second_source: Io.File = undefined;
        var original: Io.File.Stat = undefined;
        var before: []const u8 = undefined;
        var replacement: []const u8 = undefined;
        var flag: *std.atomic.Value(bool) = undefined;
        var source_stats: usize = 0;
        var mutations: usize = 0;
        var delegate_stat: @TypeOf(io.vtable.fileStat) = undefined;
        var delegate_rename: @TypeOf(io.vtable.dirRenamePreserve) = undefined;

        fn change(bytes: []const u8) !void {
            try source.writePositionalAll(io, bytes, 0);
            try source.setTimestamps(io, .{ .modify_timestamp = .{ .new = original.mtime } });
            mutations += 1;
        }

        fn stat(userdata: ?*anyopaque, file: Io.File) Io.File.StatError!Io.File.Stat {
            if (file.handle == source.handle and phase == .roundtrip) {
                source_stats += 1;
                // Extract a valid B after verification of A, then restore A and
                // its mtime before the pre-publication guard; ctime still differs.
                if (source_stats == 2) change(replacement) catch return error.Unexpected;
                if (source_stats == 3) change(before) catch return error.Unexpected;
            }
            var result = try delegate_stat(userdata, file);
            // Model a distinct mutation timestamp even on filesystems whose ctime
            // clock does not advance between these deliberately rapid writes.
            if (file.handle == source.handle and mutations != 0)
                result.ctime.nanoseconds = original.ctime.nanoseconds + 1;
            if (file.handle == second_source.handle and phase == .final_stat_cancel) {
                source_stats += 1;
                if (source_stats == 5) flag.store(true, .release);
            }
            return result;
        }

        fn rename(userdata: ?*anyopaque, old_dir: Io.Dir, old_name: []const u8, new_dir: Io.Dir, new_name: []const u8) Io.Dir.RenamePreserveError!void {
            try delegate_rename(userdata, old_dir, old_name, new_dir, new_name);
            const backup = std.mem.eql(u8, new_name, "old");
            const publish = std.mem.eql(u8, old_name, "new");
            if ((phase == .backup_mutation and backup) or (phase == .publish_mutation and publish))
                change(replacement) catch return error.Unexpected;
            if ((phase == .backup_cancel and backup) or (phase == .publish_cancel and publish))
                flag.store(true, .release);
        }
    };
    const data = elfFixture(62);
    var other_data = data;
    other_data[63] = 1;
    const zip = try fixtureZip(a, &.{.{ .name = "native.so", .data = &data }});
    defer a.free(zip);
    const replacement = try fixtureZip(a, &.{.{ .name = "native.so", .data = &other_data }});
    defer a.free(replacement);
    try std.testing.expectEqual(zip.len, replacement.len);
    const second = try fixtureZip(a, &.{.{ .name = "second.so", .data = &data }});
    defer a.free(second);
    for (std.enums.values(Hook.Phase)) |phase| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = "native.jar", .data = zip });
        try tmp.dir.writeFile(io, .{ .sub_path = "second.jar", .data = second });
        const source = try tmp.dir.openFile(io, "native.jar", .{ .mode = .read_write, .follow_symlinks = false });
        defer source.close(io);
        const second_source = try tmp.dir.openFile(io, "second.jar", .{ .follow_symlinks = false });
        defer second_source.close(io);
        const originals = [_]Io.File.Stat{ try source.stat(io), try second_source.stat(io) };
        try inspectFile(a, io, source, "x86_64", null);
        try inspectFile(a, io, second_source, "x86_64", null);
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        const destination = try std.fs.path.join(a, &.{ root, "natives" });
        defer a.free(destination);
        const tasks = [_]Task{
            .{ .archive_path = "never reopen A", .destination = destination, .exclude = &.{} },
            .{ .archive_path = "never reopen second", .destination = destination, .exclude = &.{} },
        };
        try tmp.dir.createDir(io, "natives", .default_dir);
        try tmp.dir.writeFile(io, .{ .sub_path = "natives/old", .data = "previous" });
        var canceled: std.atomic.Value(bool) = .init(false);
        Hook.phase = phase;
        Hook.source = source;
        Hook.second_source = second_source;
        Hook.original = originals[0];
        Hook.before = zip;
        Hook.replacement = replacement;
        Hook.flag = &canceled;
        Hook.source_stats = 0;
        Hook.mutations = 0;
        Hook.delegate_stat = io.vtable.fileStat;
        Hook.delegate_rename = io.vtable.dirRenamePreserve;
        var vtable = io.vtable.*;
        vtable.fileStat = Hook.stat;
        vtable.dirRenamePreserve = Hook.rename;
        const hooked_io: Io = .{ .userdata = io.userdata, .vtable = &vtable };
        var stream = source.readerStreaming(io, &.{});
        var bytes: [4]u8 = undefined;
        try stream.interface.readSliceAll(&bytes);
        const expected = switch (phase) {
            .roundtrip, .backup_mutation, .publish_mutation => error.NativeSourceChanged,
            .backup_cancel, .publish_cancel, .final_stat_cancel => error.Canceled,
        };
        try std.testing.expectError(expected, extractCheckedFilesWithStats(a, hooked_io, &tasks, &.{ source, second_source }, &originals, "x86_64", &canceled));
        try expectFile(tmp.dir, "natives/old", "previous");
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "natives/native.so", .{}));
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "natives/second.so", .{}));
        try stream.interface.readSliceAll(&bytes);
        try std.testing.expectEqualSlices(u8, zip[4..8], &bytes);
        _ = try source.stat(io);
        _ = try second_source.stat(io);
        if (phase == .roundtrip) {
            try std.testing.expectEqual(@as(usize, 2), Hook.mutations);
            const restored = try a.alloc(u8, zip.len);
            defer a.free(restored);
            var reader = source.reader(io, &.{});
            reader.mode = .positional_simple;
            reader.size = (try source.stat(io)).size;
            try std.testing.expectEqual(@as(u64, zip.len), reader.size.?);
            try reader.interface.readSliceAll(restored);
            try std.testing.expectEqualSlices(u8, zip, restored);
            try std.testing.expectEqual(originals[0].mtime.nanoseconds, (try source.stat(io)).mtime.nanoseconds);
            try std.testing.expect(originals[0].ctime.nanoseconds != (try source.stat(io)).ctime.nanoseconds);
        }
        var listing = try tmp.dir.openDir(io, ".", .{ .iterate = true });
        defer listing.close(io);
        var it = listing.iterate();
        while (try it.next(io)) |entry| try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".native-stage-"));
    }
}

test "path contract native extraction creates Unicode host parents safely" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const archive = try std.fs.path.join(a, &.{ root, "native.zip" });
    defer a.free(archive);
    const destination = try std.fs.path.join(a, &.{ root, "中文实例", "缺失目录", "natives" });
    defer a.free(destination);
    const zip = try fixtureZip(a, &.{.{ .name = "中文库.so", .data = "native" }});
    defer a.free(zip);
    try tmp.dir.writeFile(io, .{ .sub_path = "native.zip", .data = zip });
    const tasks = [_]Task{.{ .archive_path = archive, .destination = destination, .exclude = &.{} }};
    try extract(a, io, &tasks, null);
    try expectFile(tmp.dir, "中文实例/缺失目录/natives/中文库.so", "native");
    try extract(a, io, &tasks, null);
    try expectFile(tmp.dir, "中文实例/缺失目录/natives/中文库.so", "native");
    try std.testing.expectError(error.UnsafePath, openParent(io, "../outside"));
}

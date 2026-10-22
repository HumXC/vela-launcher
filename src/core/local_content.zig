//! Read-only inventory of a selected instance's local content. No archive is
//! executed or extracted to disk. Snapshot owns every returned string/byte slice.
const std = @import("std");
const builtin = @import("builtin");
const mod_path = @import("mod_path.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Kind = enum { mod, resourcepack, shader };
pub const Dependency = struct { id: []const u8, version: ?[]const u8 = null, optional: bool = false };
pub const Entry = struct {
    path: []const u8,
    physical_path: []const u8,
    name: []const u8,
    version: ?[]const u8 = null,
    description: ?[]const u8 = null,
    mod_ids: []const []const u8 = &.{},
    dependencies: []const Dependency = &.{},
    homepage: ?[]const u8 = null,
    icon_png: ?[]const u8 = null,
    mtime_ms: i64 = 0,
    size: u64 = 0,
    enabled: bool = true,
    kind: Kind = .mod,
    parse_failure: ?anyerror = null,
};
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,
    /// Enumeration stopped at max_files or max_directory_entries.
    truncated: bool = false,
    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub const ScanOptions = struct {
    kind: Kind = .mod,
    cancel: ?*const std.atomic.Value(bool) = null,
    max_files: usize = 4096,
    max_directory_entries: usize = 16384,
    max_archive_bytes: u64 = 2 * 1024 * 1024 * 1024,
    max_archive_entries: usize = 32768,
    max_metadata_bytes: usize = 1024 * 1024,
    max_icon_bytes: usize = 256 * 1024,
    max_total_read_bytes: usize = 64 * 1024 * 1024,
};
fn checkpoint(options: ScanOptions) !void {
    if (options.cancel) |cancel| if (cancel.load(.acquire)) return error.Canceled;
}
fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn reparse(stat: Io.File.Stat) bool {
    return stat.kind == .sym_link or (builtin.os.tag == .windows and stat.permissions.toAttributes().REPARSE_POINT);
}
fn component(name: []const u8) bool {
    return name.len > 0 and name.len <= 4096 and !eql(name, "..") and !eql(name, ".") and std.mem.indexOfAny(u8, name, "/\\\x00:") == null;
}
/// Open every path component independently: no intermediate symlink traversal.
fn openDirectory(io: Io, path: []const u8, iterate: bool) !Io.Dir {
    if (path.len == 0 or path.len > 16384) return error.UnsafePath;
    const absolute = std.fs.path.isAbsolute(path);
    const prefix: usize = if (absolute) (if (builtin.os.tag == .windows) std.fs.path.diskDesignator(path).len + 1 else 1) else 0;
    var dir = try Io.Dir.cwd().openDir(io, if (absolute) path[0..prefix] else ".", .{ .iterate = iterate, .follow_symlinks = false });
    errdefer dir.close(io);
    var parts = std.mem.tokenizeAny(u8, path[prefix..], "/\\");
    while (parts.next()) |part| {
        if (eql(part, ".")) continue;
        if (!component(part)) return error.UnsafePath;
        const next = try dir.openDir(io, part, .{ .iterate = iterate, .follow_symlinks = false });
        dir.close(io);
        dir = next;
        if (reparse(try dir.stat(io))) return error.UnsafeFileType;
    }
    return dir;
}
fn openRegular(dir: Io.Dir, io: Io, name: []const u8) !Io.File {
    if (!component(name)) return error.UnsafePath;
    const before = try dir.statFile(io, name, .{ .follow_symlinks = false });
    if (before.kind != .file or reparse(before)) return error.UnsafeFileType;
    const file = try dir.openFile(io, name, .{ .follow_symlinks = false, .allow_directory = false });
    errdefer file.close(io);
    const after = try file.stat(io);
    if (after.kind != .file or reparse(after) or after.inode != before.inode) return error.UnsafeFileType;
    return file;
}

pub fn scan(a: Allocator, io: Io, game_directory: []const u8, options: ScanOptions) !Snapshot {
    try checkpoint(options);
    // Hard ceilings remain effective even if a caller supplies larger options.
    if (options.max_metadata_bytes > 1024 * 1024 or options.max_icon_bytes > 256 * 1024 or options.max_files > 4096 or options.max_archive_entries > 32768 or options.max_archive_bytes > 2 * 1024 * 1024 * 1024 or options.max_total_read_bytes > 64 * 1024 * 1024 or options.max_directory_entries > 16384) return error.InvalidScanLimits;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const owned = arena.allocator();
    var entries: std.ArrayList(Entry) = .empty;
    var truncated = false;
    const folder = switch (options.kind) {
        .mod => "mods",
        .resourcepack => "resourcepacks",
        .shader => "shaderpacks",
    };
    const root = openDirectory(io, game_directory, false) catch |err| switch (err) {
        error.FileNotFound => return .{ .arena = arena, .entries = &.{} },
        else => return err,
    };
    defer root.close(io);
    const dir = root.openDir(io, folder, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .{ .arena = arena, .entries = &.{} },
        else => return err,
    };
    defer dir.close(io);
    if (reparse(try dir.stat(io))) return error.UnsafeFileType;
    var read_budget = options.max_total_read_bytes;
    var iterator = dir.iterate();
    var visited: usize = 0;
    while (try iterator.next(io)) |item| {
        try checkpoint(options);
        if (visited >= options.max_directory_entries) {
            truncated = true;
            break;
        }
        visited += 1;
        const disabled = if (options.kind == .mod) mod_path.isDisabled(item.name) else std.mem.endsWith(u8, item.name, ".disabled");
        const logical = if (options.kind == .mod) mod_path.logical(item.name) else if (disabled) item.name[0 .. item.name.len - ".disabled".len] else item.name;
        const archive = if (options.kind == .mod) mod_path.isMod(item.name) else std.ascii.endsWithIgnoreCase(logical, ".zip");
        const pack_dir = options.kind != .mod and (item.kind == .directory or item.kind == .sym_link);
        if (!archive and !pack_dir) continue;
        if (entries.items.len >= options.max_files) {
            truncated = true;
            break;
        }
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const temp = scratch.allocator();
        const relative = try std.fs.path.join(temp, &.{ folder, item.name });
        var entry: Entry = .{ .path = relative, .physical_path = try std.fs.path.join(temp, &.{ game_directory, relative }), .name = logical, .enabled = !disabled, .kind = options.kind };
        const stat = dir.statFile(io, item.name, .{ .follow_symlinks = false }) catch |err| {
            entry.parse_failure = err;
            try entries.append(owned, try cloneEntry(owned, entry));
            continue;
        };
        entry.size = stat.size;
        entry.mtime_ms = std.math.cast(i64, @divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms)) orelse 0;
        var source: Source = .{ .a = temp, .io = io, .options = options, .budget = &read_budget };
        if (reparse(stat) or (stat.kind != .file and stat.kind != .directory)) {
            entry.parse_failure = error.UnsafeFileType;
        } else if (stat.kind == .directory and options.kind != .mod) {
            const child = dir.openDir(io, item.name, .{ .follow_symlinks = false }) catch |err| {
                entry.parse_failure = err;
                try entries.append(owned, try cloneEntry(owned, entry));
                continue;
            };
            defer child.close(io);
            const opened_stat = child.stat(io) catch |err| {
                entry.parse_failure = err;
                try entries.append(owned, try cloneEntry(owned, entry));
                continue;
            };
            if (reparse(opened_stat) or opened_stat.inode != stat.inode) {
                entry.parse_failure = error.UnsafeFileType;
                try entries.append(owned, try cloneEntry(owned, entry));
                continue;
            }
            source.dir = child;
            parsePack(&source, &entry) catch |err| {
                try recordFailure(&entry, err);
            };
        } else {
            const file = openRegular(dir, io, item.name) catch |err| {
                entry.parse_failure = err;
                try entries.append(owned, try cloneEntry(owned, entry));
                continue;
            };
            defer file.close(io);
            source.file = file;
            source.indexArchive(stat.size) catch |err| {
                try recordFailure(&entry, err);
                try entries.append(owned, try cloneEntry(owned, entry));
                continue;
            };
            (if (options.kind == .mod) parseMod(&source, &entry) else parsePack(&source, &entry)) catch |err| {
                try recordFailure(&entry, err);
            };
        }
        try checkpoint(options);
        try entries.append(owned, try cloneEntry(owned, entry));
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, left: Entry, right: Entry) bool {
            return std.mem.order(u8, left.path, right.path) == .lt;
        }
    }.less);
    return .{ .arena = arena, .entries = try entries.toOwnedSlice(owned), .truncated = truncated };
}
fn recordFailure(entry: *Entry, err: anyerror) !void {
    if (err == error.OutOfMemory or err == error.Canceled) return err;
    if (entry.parse_failure == null) entry.parse_failure = err;
}
fn dupOptional(a: Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |v| try a.dupe(u8, v) else null;
}
fn cloneEntry(a: Allocator, entry: Entry) !Entry {
    var result = entry;
    result.path = try a.dupe(u8, entry.path);
    result.physical_path = try a.dupe(u8, entry.physical_path);
    result.name = try a.dupe(u8, entry.name);
    result.version = try dupOptional(a, entry.version);
    result.description = try dupOptional(a, entry.description);
    result.homepage = try dupOptional(a, entry.homepage);
    result.icon_png = try dupOptional(a, entry.icon_png);
    const ids = try a.alloc([]const u8, entry.mod_ids.len);
    for (entry.mod_ids, ids) |id, *dest| dest.* = try a.dupe(u8, id);
    result.mod_ids = ids;
    const deps = try a.alloc(Dependency, entry.dependencies.len);
    for (entry.dependencies, deps) |dep, *dest| dest.* = .{ .id = try a.dupe(u8, dep.id), .version = try dupOptional(a, dep.version), .optional = dep.optional };
    result.dependencies = deps;
    return result;
}

fn safeMember(raw: []const u8) bool {
    if (raw.len == 0 or raw.len > 4096 or raw[0] == '/' or std.mem.indexOfAny(u8, raw, "\\\x00:") != null or !std.unicode.utf8ValidateSlice(raw)) return false;
    const name = if (std.mem.endsWith(u8, raw, "/")) raw[0 .. raw.len - 1] else raw;
    var parts = std.mem.splitScalar(u8, name, '/');
    var depth: usize = 0;
    while (parts.next()) |part| {
        depth += 1;
        if (!component(part) or depth > 64) return false;
    }
    return true;
}
const Member = struct { zip: std.zip.Iterator.Entry, offset: u64 };
const Source = struct {
    a: Allocator,
    io: Io,
    options: ScanOptions,
    budget: *usize,
    dir: ?Io.Dir = null,
    file: ?Io.File = null,
    members: std.StringHashMapUnmanaged(Member) = .empty,
    fn charge(self: *Source, amount: usize) !void {
        try checkpoint(self.options);
        if (amount > self.budget.*) return error.ReadBudgetExceeded;
        self.budget.* -= amount;
    }
    fn indexArchive(self: *Source, size: u64) !void {
        if (size > self.options.max_archive_bytes) return error.ArchiveTooLarge;
        var buffer: [256]u8 = undefined;
        var input = self.file.?.reader(self.io, &buffer);
        try self.charge(2 * @as(usize, @intCast(@min(size, 65557))));
        const end = try std.zip.EndRecord.findFile(&input);
        if (end.need_zip64()) return error.UnsupportedZip64;
        var it = try std.zip.Iterator.init(&input);
        if (it.cd_record_count > self.options.max_archive_entries or it.cd_size > 8 * 1024 * 1024) return error.ArchiveEntryLimitExceeded;
        if (it.cd_zip_offset > size or it.cd_size > size - it.cd_zip_offset) return error.InvalidZipBounds;
        try self.charge(@intCast(2 * it.cd_size + 2 * it.cd_record_count * buffer.len));
        var name_bytes: usize = 0;
        while (try it.next()) |member| {
            try checkpoint(self.options);
            if (member.filename_len == 0 or member.filename_len > 4096) return error.UnsafeArchivePath;
            name_bytes += member.filename_len;
            if (name_bytes > 2 * 1024 * 1024) return error.ArchiveEntryLimitExceeded;
            try input.seekTo(member.header_zip_offset);
            const central = try input.interface.takeStruct(std.zip.CentralDirectoryFileHeader, .little);
            if (central.compressed_size == std.math.maxInt(u32) or central.uncompressed_size == std.math.maxInt(u32) or central.local_file_header_offset == std.math.maxInt(u32)) return error.UnsupportedZip64;
            var name_buffer: [4096]u8 = undefined;
            const name = name_buffer[0..member.filename_len];
            try input.interface.readSliceAll(name);
            if (!safeMember(name)) return error.UnsafeArchivePath;
            if (self.members.contains(name)) return error.DuplicateArchiveEntry;
            const unix_type = (central.external_file_attributes >> 16) & 0o170000;
            if (unix_type != 0 and unix_type != 0o100000 and unix_type != 0o040000) return error.UnsafeFileType;
            if (member.compression_method != .store and member.compression_method != .deflate) return error.UnsupportedCompressionMethod;
            // Deflate options, data descriptors and UTF-8 are the only supported flags.
            if (@as(u16, @bitCast(member.flags)) & ~@as(u16, 0x080e) != 0) return error.UnsupportedZipFlags;
            if (member.file_offset > it.cd_zip_offset or @sizeOf(std.zip.LocalFileHeader) > it.cd_zip_offset - member.file_offset) return error.InvalidZipBounds;
            try self.charge(@sizeOf(std.zip.LocalFileHeader) + member.filename_len + buffer.len);
            try input.seekTo(member.file_offset);
            const local = try input.interface.takeStruct(std.zip.LocalFileHeader, .little);
            if (!eql(&local.signature, &std.zip.local_file_header_sig) or local.filename_len != member.filename_len or local.compression_method != member.compression_method or @as(u16, @bitCast(local.flags)) != @as(u16, @bitCast(member.flags))) return error.ZipHeaderMismatch;
            if (local.compressed_size == std.math.maxInt(u32) or local.uncompressed_size == std.math.maxInt(u32)) return error.UnsupportedZip64;
            if ((local.crc32 != 0 and local.crc32 != member.crc32) or (local.compressed_size != 0 and local.compressed_size != member.compressed_size) or (local.uncompressed_size != 0 and local.uncompressed_size != member.uncompressed_size)) return error.ZipHeaderMismatch;
            var local_name: [4096]u8 = undefined;
            try input.interface.readSliceAll(local_name[0..local.filename_len]);
            if (!eql(name, local_name[0..local.filename_len])) return error.ZipHeaderMismatch;
            const offset = member.file_offset + @sizeOf(std.zip.LocalFileHeader) + local.filename_len + local.extra_len;
            if (offset > it.cd_zip_offset or member.compressed_size > it.cd_zip_offset - offset) return error.InvalidZipBounds;
            try self.members.put(self.a, try self.a.dupe(u8, name), .{ .zip = member, .offset = offset });
        }
    }
    fn read(self: *Source, name: []const u8, limit: usize) !?[]const u8 {
        try checkpoint(self.options);
        if (!safeMember(name)) return error.UnsafeArchivePath;
        if (self.dir) |root| {
            var dir = root;
            var owned_dir: ?Io.Dir = null;
            defer if (owned_dir) |d| d.close(self.io);
            if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| {
                var parts = std.mem.splitScalar(u8, name[0..slash], '/');
                while (parts.next()) |part| {
                    const child = dir.openDir(self.io, part, .{ .follow_symlinks = false }) catch |err| switch (err) {
                        error.FileNotFound => return null,
                        else => return err,
                    };
                    if (owned_dir) |d| d.close(self.io);
                    owned_dir = child;
                    dir = child;
                    if (reparse(try dir.stat(self.io))) return error.UnsafeFileType;
                }
            }
            const file = openRegular(dir, self.io, std.fs.path.basename(name)) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => return err,
            };
            defer file.close(self.io);
            const stat = try file.stat(self.io);
            if (stat.size > limit) return error.MetadataTooLarge;
            try self.charge(@intCast(stat.size));
            const bytes = try self.a.alloc(u8, @intCast(stat.size));
            if (try file.readPositionalAll(self.io, bytes, 0) != bytes.len) return error.TruncatedMetadata;
            return bytes;
        }
        const member = self.members.get(name) orelse return null;
        if (member.zip.uncompressed_size > limit or member.zip.compressed_size > 2 * 1024 * 1024) return error.MetadataTooLarge;
        if (member.zip.uncompressed_size > @max(member.zip.compressed_size, 1) * 200) return error.ExpansionLimitExceeded;
        try self.charge(@intCast(member.zip.compressed_size + member.zip.uncompressed_size));
        const compressed = try self.a.alloc(u8, @intCast(member.zip.compressed_size));
        if (try self.file.?.readPositionalAll(self.io, compressed, member.offset) != compressed.len) return error.TruncatedMetadata;
        const bytes = try self.a.alloc(u8, @intCast(member.zip.uncompressed_size));
        if (member.zip.compression_method == .store) {
            if (compressed.len != bytes.len) return error.ZipSizeMismatch;
            @memcpy(bytes, compressed);
        } else {
            var input = Io.Reader.fixed(compressed);
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var decoder: std.compress.flate.Decompress = .init(&input, .raw, &window);
            decoder.reader.readSliceAll(bytes) catch return error.InvalidDeflate;
            var extra: [1]u8 = undefined;
            if ((decoder.reader.readSliceShort(&extra) catch return error.InvalidDeflate) != 0) return error.ZipSizeMismatch;
            if (input.seek != input.end) return error.ZipCompressedSizeMismatch;
        }
        if (std.hash.Crc32.hash(bytes) != member.zip.crc32) return error.ArchiveChecksumMismatch;
        try checkpoint(self.options);
        return bytes;
    }
};

const Value = std.json.Value;
fn field(value: Value, key: []const u8) Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}
fn string(value: Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}
fn json(a: Allocator, bytes: []const u8) !Value {
    // std.json's dynamic parser is recursive; cap nesting before calling it.
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (bytes) |c| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
        } else if (c == '"') {
            in_string = true;
        } else if (c == '{' or c == '[') {
            depth += 1;
            if (depth > 64) return error.MetadataNestingTooDeep;
        } else if (c == '}' or c == ']') {
            if (depth == 0) return error.InvalidMetadata;
            depth -= 1;
        }
    }
    const parsed = try std.json.parseFromSlice(Value, a, bytes, .{ .allocate = .alloc_always, .max_value_len = 65536 });
    return parsed.value; // allocator is the per-entry scratch arena
}
fn addId(a: Allocator, ids: *std.ArrayList([]const u8), id: []const u8) !void {
    if (id.len == 0 or id.len > 256 or ids.items.len >= 256) return error.InvalidModId;
    for (ids.items) |old| if (eql(old, id)) return;
    try ids.append(a, id);
}
fn depVersion(a: Allocator, value: Value) !?[]const u8 {
    if (string(value)) |v| return v;
    if (value == .array) {
        var parts: std.ArrayList([]const u8) = .empty;
        for (value.array.items) |v| if (string(v)) |s| {
            try parts.append(a, s);
        };
        return if (parts.items.len > 0) try std.mem.join(a, " || ", parts.items) else null;
    }
    return null;
}
fn addDeps(a: Allocator, deps: *std.ArrayList(Dependency), value: Value, optional: bool) !void {
    if (value == .object) {
        var it = value.object.iterator();
        while (it.next()) |pair| {
            if (deps.items.len >= 512) return error.TooManyDependencies;
            try deps.append(a, .{ .id = pair.key_ptr.*, .version = try depVersion(a, pair.value_ptr.*), .optional = optional });
        }
    } else if (value == .array) {
        for (value.array.items) |item| {
            if (deps.items.len >= 512) return error.TooManyDependencies;
            const id = string(field(item, "id")) orelse continue;
            const opt = field(item, "optional");
            try deps.append(a, .{ .id = id, .version = try depVersion(a, field(item, "versions")), .optional = optional or (opt == .bool and opt.bool) });
        }
    }
}
fn iconName(value: Value) ?[]const u8 {
    if (string(value)) |s| return s;
    if (value == .object) {
        var it = value.object.iterator();
        var selected: ?[]const u8 = null;
        var best: usize = std.math.maxInt(usize);
        while (it.next()) |pair| {
            const size = std.fmt.parseInt(usize, pair.key_ptr.*, 10) catch continue;
            if (size < best) if (string(pair.value_ptr.*)) |s| {
                selected = s;
                best = size;
            };
        }
        return selected;
    }
    return null;
}
/// Check PNG chunk framing/CRC and bounded dimensions. Pixel decoding is left
/// to the UI; animation and unknown critical chunks are deliberately refused.
pub fn validatePng(bytes: []const u8) !void {
    if (bytes.len < 45 or !eql(bytes[0..8], "\x89PNG\r\n\x1a\n")) return error.InvalidIcon;
    var offset: usize = 8;
    var header = false;
    var data = false;
    while (offset < bytes.len) {
        if (bytes.len - offset < 12) return error.InvalidIcon;
        const length = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        if (length > bytes.len - offset - 12) return error.InvalidIcon;
        const kind = bytes[offset + 4 ..][0..4];
        const body = bytes[offset + 8 ..][0..length];
        const crc = std.mem.readInt(u32, bytes[offset + 8 + length ..][0..4], .big);
        if (std.hash.Crc32.hash(bytes[offset + 4 ..][0 .. 4 + length]) != crc) return error.InvalidIcon;
        if (!header and !eql(kind, "IHDR")) return error.InvalidIcon;
        if (eql(kind, "IHDR")) {
            if (header or length != 13) return error.InvalidIcon;
            const width = std.mem.readInt(u32, body[0..4], .big);
            const height = std.mem.readInt(u32, body[4..8], .big);
            if (width == 0 or height == 0 or width > 1024 or height > 1024 or body[10] != 0 or body[11] != 0 or body[12] > 1) return error.InvalidIcon;
            const depth = body[8];
            const valid_depth = switch (body[9]) {
                0 => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
                2, 4, 6 => depth == 8 or depth == 16,
                3 => depth == 1 or depth == 2 or depth == 4 or depth == 8,
                else => false,
            };
            if (!valid_depth) return error.InvalidIcon;
            header = true;
        } else if (eql(kind, "IDAT")) {
            data = true;
        } else if (eql(kind, "IEND")) {
            if (length != 0 or !data or offset + 12 != bytes.len) return error.InvalidIcon;
            return;
        } else if (eql(kind, "acTL") or (kind[0] & 0x20 == 0 and !eql(kind, "PLTE"))) return error.InvalidIcon;
        offset += 12 + length;
    }
    return error.InvalidIcon;
}
fn loadIcon(source: *Source, entry: *Entry, name: ?[]const u8) !void {
    const path = name orelse return;
    const bytes = (try source.read(path, source.options.max_icon_bytes)) orelse return;
    try validatePng(bytes);
    entry.icon_png = bytes;
}
fn parsePack(source: *Source, entry: *Entry) !void {
    if (try source.read("pack.mcmeta", source.options.max_metadata_bytes)) |bytes| {
        const pack = field(try json(source.a, bytes), "pack");
        if (pack != .object) return error.InvalidMetadata;
        const desc = field(pack, "description");
        entry.description = string(desc) orelse string(field(desc, "text"));
    } else if (entry.kind == .resourcepack) return error.MetadataNotFound;
    try loadIcon(source, entry, "pack.png");
}
fn parseMod(source: *Source, entry: *Entry) !void {
    for ([_][]const u8{ "fabric.mod.json", "quilt.mod.json", "META-INF/neoforge.mods.toml", "META-INF/mods.toml", "mcmod.info" }) |name| {
        const bytes = (try source.read(name, source.options.max_metadata_bytes)) orelse continue;
        if (std.mem.endsWith(u8, name, ".toml")) return parseToml(source, entry, bytes);
        const value = try json(source.a, bytes);
        if (eql(name, "mcmod.info")) return parseOldForge(source, entry, value);
        const quilt = eql(name, "quilt.mod.json");
        const loader = if (quilt) field(value, "quilt_loader") else value;
        if (loader != .object) return error.InvalidMetadata;
        var ids: std.ArrayList([]const u8) = .empty;
        const id = string(field(loader, "id")) orelse return error.InvalidModId;
        try addId(source.a, &ids, id);
        const provides = field(loader, "provides");
        if (provides == .array) for (provides.array.items) |item| {
            if (string(item) orelse string(field(item, "id"))) |provided| try addId(source.a, &ids, provided);
        };
        entry.mod_ids = ids.items;
        entry.version = string(field(loader, "version"));
        const metadata = if (quilt) field(loader, "metadata") else value;
        entry.name = string(field(metadata, "name")) orelse entry.name;
        entry.description = string(field(metadata, "description"));
        entry.homepage = string(field(field(metadata, "contact"), "homepage"));
        var deps: std.ArrayList(Dependency) = .empty;
        try addDeps(source.a, &deps, field(loader, "depends"), false);
        try addDeps(source.a, &deps, field(loader, "recommends"), true);
        try addDeps(source.a, &deps, field(loader, "suggests"), true);
        entry.dependencies = deps.items;
        try loadIcon(source, entry, iconName(field(metadata, "icon")));
        return;
    }
    return error.MetadataNotFound;
}
fn parseOldForge(source: *Source, entry: *Entry, value: Value) !void {
    const mods = if (value == .array) value else field(value, "modList");
    if (mods != .array or mods.array.items.len == 0) return error.InvalidMetadata;
    var ids: std.ArrayList([]const u8) = .empty;
    var deps: std.ArrayList(Dependency) = .empty;
    for (mods.array.items, 0..) |mod, index| {
        try addId(source.a, &ids, string(field(mod, "modid")) orelse return error.InvalidModId);
        if (index == 0) {
            entry.name = string(field(mod, "name")) orelse entry.name;
            entry.version = string(field(mod, "version"));
            entry.description = string(field(mod, "description"));
            entry.homepage = string(field(mod, "url"));
            try loadIcon(source, entry, string(field(mod, "logoFile")));
        }
        for ([_][]const u8{ "dependencies", "requiredMods" }) |key| {
            const dependencies = field(mod, key);
            if (dependencies == .array) for (dependencies.array.items) |dep| {
                var raw = string(dep) orelse continue;
                var optional = false;
                for ([_][]const u8{ "required-after:", "required-before:", "after:", "before:" }) |prefix| {
                    if (std.mem.startsWith(u8, raw, prefix)) {
                        optional = !std.mem.startsWith(u8, prefix, "required-");
                        raw = raw[prefix.len..];
                        break;
                    }
                }
                const at = std.mem.indexOfScalar(u8, raw, '@') orelse raw.len;
                if (at == 0 or at > 256) return error.InvalidModId;
                if (deps.items.len >= 512) return error.TooManyDependencies;
                try deps.append(source.a, .{ .id = raw[0..at], .version = if (at < raw.len) raw[at + 1 ..] else null, .optional = optional });
            };
        }
    }
    entry.mod_ids = ids.items;
    entry.dependencies = deps.items;
}

// Pragmatic bounded TOML reader: strings (including multiline), booleans and
// mods/dependencies tables. Unknown fields are ignored; no interpolation/code.
fn manifestVersion(source: *Source) !?[]const u8 {
    const bytes = (try source.read("META-INF/MANIFEST.MF", source.options.max_metadata_bytes)) orelse return null;
    var result: std.ArrayList(u8) = .empty;
    var found = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (found) {
            if (line.len > 0 and line[0] == ' ') {
                try result.appendSlice(source.a, line[1..]);
                continue;
            }
            return result.items;
        }
        if (line.len == 0) break; // Named manifest sections are not the main attributes.
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], "Implementation-Version")) {
            found = true;
            try result.appendSlice(source.a, std.mem.trimStart(u8, line[colon + 1 ..], " "));
        }
    }
    return if (found) result.items else null;
}
fn tomlString(a: Allocator, value: []const u8) !?[]const u8 {
    if (value.len < 2 or (value[0] != '"' and value[0] != '\'')) return null;
    const quote = value[0];
    const triple = value.len >= 6 and value[1] == quote and value[2] == quote;
    const skip: usize = if (triple) 3 else 1;
    if (value.len < skip * 2 or !std.mem.allEqual(u8, value[value.len - skip ..], quote)) return error.InvalidToml;
    const body = value[skip .. value.len - skip];
    if (quote == '\'') return body;
    if (!triple) return string(try json(a, value));
    var result: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < body.len) : (index += 1) {
        if (body[index] != '\\') {
            try result.append(a, body[index]);
            continue;
        }
        index += 1;
        if (index == body.len) return error.InvalidToml;
        try result.append(a, switch (body[index]) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '\\' => '\\',
            '"' => '"',
            else => return error.UnsupportedTomlEscape,
        });
    }
    return result.items;
}
fn parseToml(source: *Source, entry: *Entry, bytes: []const u8) !void {
    var ids: std.ArrayList([]const u8) = .empty;
    var deps: std.ArrayList(Dependency) = .empty;
    var section: enum { global, mod, dep, other } = .global;
    var mod_index: usize = 0;
    var current_dep: ?usize = null;
    var icon: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        try checkpoint(source.options);
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            if (!std.mem.endsWith(u8, line, "]")) return error.InvalidToml;
            if (eql(line, "[[mods]]")) {
                section = .mod;
                mod_index += 1;
            } else if (std.mem.startsWith(u8, line, "[[dependencies.") and std.mem.endsWith(u8, line, "]]")) {
                section = .dep;
                if (deps.items.len >= 512) return error.TooManyDependencies;
                current_dep = deps.items.len;
                try deps.append(source.a, .{ .id = "" });
            } else section = .other;
            continue;
        }
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidToml;
        const key = std.mem.trim(u8, line[0..equals], " \t");
        var value = std.mem.trim(u8, line[equals + 1 ..], " \t\r");
        // Strip comments only outside strings.
        var quote: u8 = 0;
        var escape = false;
        for (value, 0..) |c, i| {
            if (escape) {
                escape = false;
                continue;
            }
            if (quote == '"' and c == '\\') {
                escape = true;
                continue;
            }
            if (quote != 0) {
                if (c == quote) quote = 0;
            } else if (c == '"' or c == '\'') quote = c else if (c == '#') {
                value = std.mem.trimEnd(u8, value[0..i], " \t\r");
                break;
            }
        }
        if (std.mem.startsWith(u8, value, "\"\"\"") or std.mem.startsWith(u8, value, "'''")) {
            const marker = value[0..3];
            if (std.mem.indexOf(u8, value[3..], marker) == null) {
                var joined: std.ArrayList(u8) = .empty;
                try joined.appendSlice(source.a, value);
                var closed = false;
                while (lines.next()) |more| {
                    try joined.append(source.a, '\n');
                    try joined.appendSlice(source.a, more);
                    if (std.mem.indexOf(u8, more, marker) != null) {
                        closed = true;
                        break;
                    }
                }
                if (!closed) return error.InvalidToml;
                value = std.mem.trimEnd(u8, joined.items, " \t\r");
            }
        }
        const text = try tomlString(source.a, value);
        switch (section) {
            .global => {
                if (eql(key, "displayURL")) entry.homepage = text;
                if (eql(key, "logoFile")) icon = text;
            },
            .mod => {
                if (eql(key, "modId")) try addId(source.a, &ids, text orelse return error.InvalidToml);
                if (mod_index == 1) {
                    if (eql(key, "displayName")) entry.name = text orelse entry.name;
                    if (eql(key, "version")) entry.version = text;
                    if (eql(key, "description")) entry.description = text;
                    if (eql(key, "displayURL")) entry.homepage = text;
                    if (eql(key, "logoFile")) icon = text;
                }
            },
            .dep => {
                const dep = &deps.items[current_dep.?];
                if (eql(key, "modId")) dep.id = text orelse return error.InvalidToml;
                if (eql(key, "versionRange")) dep.version = text;
                if (eql(key, "mandatory")) {
                    if (!eql(value, "true") and !eql(value, "false")) return error.InvalidToml;
                    dep.optional = eql(value, "false");
                }
                if (eql(key, "type")) dep.optional = if (text) |t| eql(t, "optional") else false;
            },
            .other => {},
        }
    }
    if (ids.items.len == 0) return error.InvalidModId;
    for (deps.items) |dep| if (dep.id.len == 0) return error.InvalidToml;
    entry.mod_ids = ids.items;
    entry.dependencies = deps.items;
    if (entry.version == null or eql(entry.version.?, "${file.jarVersion}")) {
        if (try manifestVersion(source)) |version| entry.version = version;
    }
    try loadIcon(source, entry, icon);
}

const TestMember = struct { name: []const u8, bytes: []const u8, deflate: bool = false, bad_crc: bool = false, method: ?std.zip.CompressionMethod = null, flags: u16 = 0x800 };
fn testZip(a: Allocator, dir: Io.Dir, path: []const u8, members: []const TestMember) !void {
    const io = std.testing.io;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    var central_bytes: std.ArrayList(u8) = .empty;
    defer central_bytes.deinit(a);
    for (members) |member| {
        const offset = bytes.items.len;
        var compressed_buffer: [65536]u8 = undefined;
        var compress_window: [std.compress.flate.max_window_len]u8 = undefined;
        var output = Io.Writer.fixed(&compressed_buffer);
        const compressed = if (member.deflate) blk: {
            var compressor = try std.compress.flate.Compress.init(&output, &compress_window, .raw, .default);
            try compressor.writer.writeAll(member.bytes);
            try compressor.finish();
            break :blk output.buffered();
        } else member.bytes;
        const method: std.zip.CompressionMethod = member.method orelse (if (member.deflate) .deflate else .store);
        const crc = std.hash.Crc32.hash(member.bytes) ^ @as(u32, if (member.bad_crc) 1 else 0);
        const local: std.zip.LocalFileHeader = .{ .signature = std.zip.local_file_header_sig, .version_needed_to_extract = 20, .flags = @bitCast(member.flags), .compression_method = method, .last_modification_time = 0, .last_modification_date = 0, .crc32 = crc, .compressed_size = @intCast(compressed.len), .uncompressed_size = @intCast(member.bytes.len), .filename_len = @intCast(member.name.len), .extra_len = 0 };
        try bytes.appendSlice(a, std.mem.asBytes(&local));
        try bytes.appendSlice(a, member.name);
        try bytes.appendSlice(a, compressed);
        const central: std.zip.CentralDirectoryFileHeader = .{ .signature = std.zip.central_file_header_sig, .version_made_by = 20, .version_needed_to_extract = 20, .flags = local.flags, .compression_method = method, .last_modification_time = 0, .last_modification_date = 0, .crc32 = crc, .compressed_size = local.compressed_size, .uncompressed_size = local.uncompressed_size, .filename_len = local.filename_len, .extra_len = 0, .comment_len = 0, .disk_number = 0, .internal_file_attributes = 0, .external_file_attributes = 0, .local_file_header_offset = @intCast(offset) };
        try central_bytes.appendSlice(a, std.mem.asBytes(&central));
        try central_bytes.appendSlice(a, member.name);
    }
    const end: std.zip.EndRecord = .{ .signature = std.zip.end_record_sig, .disk_number = 0, .central_directory_disk_number = 0, .record_count_disk = @intCast(members.len), .record_count_total = @intCast(members.len), .central_directory_size = @intCast(central_bytes.items.len), .central_directory_offset = @intCast(bytes.items.len), .comment_len = 0 };
    try bytes.appendSlice(a, central_bytes.items);
    try bytes.appendSlice(a, std.mem.asBytes(&end));
    try dir.writeFile(io, .{ .sub_path = path, .data = bytes.items });
}
fn testPath(a: Allocator, tmp: std.testing.TmpDir) ![:0]const u8 {
    return tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
}
const fabric_fixture =
    \\{"schemaVersion":1,"id":"example","provides":["alias"],"name":"示例模组","version":"1.2.3","description":"测试描述","contact":{"homepage":"https://example.invalid"},"depends":{"minecraft":">=1.20","fabricloader":[">=0.15",">=0.16"]},"suggests":{"extra":"*"}}
;
test "stored and deflated JAR metadata, owned Unicode strings and disabled path" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "mods", .default_dir);
    try testZip(a, tmp.dir, "mods/示例.jar.disabled", &.{.{ .name = "fabric.mod.json", .bytes = fabric_fixture }});
    try testZip(a, tmp.dir, "mods/compressed.jar", &.{.{ .name = "fabric.mod.json", .bytes = fabric_fixture, .deflate = true }});
    const path = try testPath(a, tmp);
    defer a.free(path);
    var result = try scan(a, std.testing.io, path, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.entries.len);
    for (result.entries) |entry| {
        try std.testing.expectEqual(@as(?anyerror, null), entry.parse_failure);
        try std.testing.expectEqualStrings("示例模组", entry.name);
        try std.testing.expectEqualStrings("1.2.3", entry.version.?);
        try std.testing.expectEqualStrings("alias", entry.mod_ids[1]);
        try std.testing.expectEqualStrings(">=0.15 || >=0.16", entry.dependencies[1].version.?);
        try std.testing.expect(entry.dependencies[2].optional);
        try std.testing.expect(entry.size > 0 and entry.mtime_ms > 0);
    }
    try std.testing.expect(!result.entries[1].enabled);
    try std.testing.expectEqualStrings("mods/示例.jar.disabled", result.entries[1].path);
    try std.testing.expect(std.mem.endsWith(u8, result.entries[1].physical_path, "mods/示例.jar.disabled"));
}
test "scanner preserves JAR case and exact lowercase disabled suffix" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "mods", .default_dir);
    const cases = [_]struct { filename: []const u8, logical_name: []const u8, enabled: bool }{
        .{ .filename = "lower.jar", .logical_name = "lower.jar", .enabled = true },
        .{ .filename = "lower.jar.disabled", .logical_name = "lower.jar", .enabled = false },
        .{ .filename = "Upper.JAR", .logical_name = "Upper.JAR", .enabled = true },
        .{ .filename = "Upper.JAR.disabled", .logical_name = "Upper.JAR", .enabled = false },
        .{ .filename = "Mixed.JaR", .logical_name = "Mixed.JaR", .enabled = true },
        .{ .filename = "Mixed.JaR.disabled", .logical_name = "Mixed.JaR", .enabled = false },
    };
    for (cases) |case| {
        const relative = try std.fmt.allocPrint(a, "mods/{s}", .{case.filename});
        defer a.free(relative);
        try tmp.dir.writeFile(io, .{ .sub_path = relative, .data = "unparseable mod bytes" });
    }
    for ([_][]const u8{ "mods/ignored.JAR.DISABLED", "mods/ignored.zip.disabled", "mods/ignored.JAR.disabled.disabled" }) |relative|
        try tmp.dir.writeFile(io, .{ .sub_path = relative, .data = "ignored" });
    try tmp.dir.createDir(io, "mods/unrelated-directory", .default_dir);
    const path = try testPath(a, tmp);
    defer a.free(path);
    var result = try scan(a, io, path, .{});
    defer result.deinit();
    try std.testing.expectEqual(cases.len, result.entries.len);
    for (cases) |case| {
        const relative = try std.fmt.allocPrint(a, "mods/{s}", .{case.filename});
        defer a.free(relative);
        const entry = for (result.entries) |entry| {
            if (eql(entry.path, relative)) break entry;
        } else return error.TestExpectedEqual;
        try std.testing.expectEqualStrings(case.logical_name, entry.name);
        try std.testing.expectEqual(case.enabled, entry.enabled);
        try std.testing.expect(std.mem.endsWith(u8, entry.physical_path, relative));
        try std.testing.expect(entry.parse_failure != null);
    }
}

test "unrecognized damaged malformed and unsafe archives remain visible" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "mods", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "mods/damaged.jar", .data = "not a zip" });
    try testZip(a, tmp.dir, "mods/fallback.jar", &.{.{ .name = "ordinary.txt", .bytes = "hello" }});
    try testZip(a, tmp.dir, "mods/malformed.jar", &.{.{ .name = "fabric.mod.json", .bytes = "{" }});
    try testZip(a, tmp.dir, "mods/duplicate.jar", &.{ .{ .name = "fabric.mod.json", .bytes = fabric_fixture }, .{ .name = "fabric.mod.json", .bytes = fabric_fixture } });
    try testZip(a, tmp.dir, "mods/traversal.jar", &.{.{ .name = "../fabric.mod.json", .bytes = fabric_fixture }});
    try testZip(a, tmp.dir, "mods/crc.jar", &.{.{ .name = "fabric.mod.json", .bytes = fabric_fixture, .bad_crc = true }});
    try testZip(a, tmp.dir, "mods/unsupported.jar", &.{.{ .name = "fabric.mod.json", .bytes = fabric_fixture, .method = @fromBackingInt(@intCast(12)) }});
    try testZip(a, tmp.dir, "mods/flags.jar", &.{.{ .name = "fabric.mod.json", .bytes = fabric_fixture, .flags = 0x8800 }});
    const path = try testPath(a, tmp);
    defer a.free(path);
    var result = try scan(a, std.testing.io, path, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 8), result.entries.len);
    for (result.entries) |entry| {
        try std.testing.expect(entry.parse_failure != null);
        try std.testing.expectEqualStrings(std.fs.path.basename(entry.path), entry.name);
        if (eql(entry.name, "duplicate.jar")) try std.testing.expectEqual(error.DuplicateArchiveEntry, entry.parse_failure.?);
        if (eql(entry.name, "traversal.jar")) try std.testing.expectEqual(error.UnsafeArchivePath, entry.parse_failure.?);
        if (eql(entry.name, "crc.jar")) try std.testing.expectEqual(error.ArchiveChecksumMismatch, entry.parse_failure.?);
        if (eql(entry.name, "flags.jar")) try std.testing.expectEqual(error.UnsupportedZipFlags, entry.parse_failure.?);
    }
}
test "Quilt Forge NeoForge and old Forge actual metadata" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "mods", .default_dir);
    const toml =
        \\modLoader="javafml"
        \\[[mods]]
        \\modId="forge_test"
        \\displayName="Forge # name" # trailing comment
        \\version="${file.jarVersion}"
        \\description='''First line
        \\Second line'''
        \\displayURL="https://example.invalid/forge"
        \\[[mods]]
        \\modId='second'
        \\[[dependencies.forge_test]]
        \\modId="minecraft"
        \\mandatory=false
        \\versionRange="[1.20,1.22)"
    ;
    try testZip(a, tmp.dir, "mods/forge.jar", &.{ .{ .name = "META-INF/mods.toml", .bytes = toml }, .{ .name = "META-INF/MANIFEST.MF", .bytes = "Manifest-Version: 1.0\r\nImplementation-Version: 2.\r\n 0\r\n\r\n" } });
    try testZip(a, tmp.dir, "mods/neo.jar", &.{ .{ .name = "META-INF/neoforge.mods.toml", .bytes = toml, .deflate = true }, .{ .name = "META-INF/MANIFEST.MF", .bytes = "Implementation-Version: 2.0\n" } });
    try testZip(a, tmp.dir, "mods/quilt.jar", &.{.{ .name = "quilt.mod.json", .bytes = "{\"quilt_loader\":{\"id\":\"quilt_test\",\"version\":\"3\",\"metadata\":{\"name\":\"Quilt\",\"description\":\"desc\"},\"depends\":[{\"id\":\"minecraft\",\"versions\":\">=1.20\",\"optional\":true}]}}" }});
    try testZip(a, tmp.dir, "mods/old.jar", &.{.{ .name = "mcmod.info", .bytes = "[{\"modid\":\"legacy\",\"name\":\"Legacy\",\"version\":\"1\",\"requiredMods\":[\"required-after:forge@[1,)\"]}]" }});
    const path = try testPath(a, tmp);
    defer a.free(path);
    var result = try scan(a, std.testing.io, path, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 4), result.entries.len);
    for (result.entries) |entry| {
        try std.testing.expectEqual(@as(?anyerror, null), entry.parse_failure);
        try std.testing.expect(entry.mod_ids.len > 0 and entry.dependencies.len == 1);
        if (eql(entry.name, "Forge # name")) {
            try std.testing.expectEqualStrings("First line\nSecond line", entry.description.?);
            try std.testing.expectEqualStrings("2.0", entry.version.?);
            try std.testing.expectEqualStrings("second", entry.mod_ids[1]);
            try std.testing.expect(entry.dependencies[0].optional);
        }
    }
}
test "resource packs and shaders support zip and directory without writes" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "resourcepacks/directory");
    try tmp.dir.createDirPath(std.testing.io, "shaderpacks/shader-dir");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "resourcepacks/directory/pack.mcmeta", .data = "{\"pack\":{\"description\":{\"text\":\"Directory pack\"},\"pack_format\":15}}" });
    try testZip(a, tmp.dir, "resourcepacks/pack.zip", &.{.{ .name = "pack.mcmeta", .bytes = "{\"pack\":{\"description\":\"Zip pack\"}}", .deflate = true }});
    try testZip(a, tmp.dir, "shaderpacks/shader.zip", &.{.{ .name = "shaders/main.fsh", .bytes = "void main() {}" }});
    const path = try testPath(a, tmp);
    defer a.free(path);
    var packs = try scan(a, std.testing.io, path, .{ .kind = .resourcepack });
    defer packs.deinit();
    try std.testing.expectEqual(@as(usize, 2), packs.entries.len);
    try std.testing.expectEqualStrings("Directory pack", packs.entries[0].description.?);
    try std.testing.expectEqualStrings("Zip pack", packs.entries[1].description.?);
    var shaders = try scan(a, std.testing.io, path, .{ .kind = .shader });
    defer shaders.deinit();
    try std.testing.expectEqual(@as(usize, 2), shaders.entries.len);
    for (shaders.entries) |entry| try std.testing.expectEqual(@as(?anyerror, null), entry.parse_failure);
}
test "missing folders file cap read metadata budgets cancellation" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(a, tmp);
    defer a.free(path);
    var empty = try scan(a, std.testing.io, path, .{});
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.entries.len);
    try tmp.dir.createDir(std.testing.io, "mods", .default_dir);
    try testZip(a, tmp.dir, "mods/one.jar", &.{.{ .name = "fabric.mod.json", .bytes = fabric_fixture }});
    try testZip(a, tmp.dir, "mods/two.jar", &.{.{ .name = "fabric.mod.json", .bytes = fabric_fixture }});
    var capped = try scan(a, std.testing.io, path, .{ .max_files = 1 });
    defer capped.deinit();
    try std.testing.expect(capped.truncated and capped.entries.len == 1);
    var budget = try scan(a, std.testing.io, path, .{ .max_total_read_bytes = 1 });
    defer budget.deinit();
    for (budget.entries) |entry| try std.testing.expectEqual(error.ReadBudgetExceeded, entry.parse_failure.?);
    var metadata = try scan(a, std.testing.io, path, .{ .max_metadata_bytes = 8 });
    defer metadata.deinit();
    for (metadata.entries) |entry| try std.testing.expectEqual(error.MetadataTooLarge, entry.parse_failure.?);
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Canceled, scan(a, std.testing.io, path, .{ .cancel = &cancel }));
}
test "no-follow content file metadata directory and intermediate root links" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "mods");
    try tmp.dir.createDirPath(std.testing.io, "resourcepacks/unsafe");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "secret", .data = fabric_fixture });
    try tmp.dir.symLink(std.testing.io, "../secret", "mods/link.jar", .{});
    try tmp.dir.symLink(std.testing.io, "../../secret", "resourcepacks/unsafe/pack.mcmeta", .{});
    try tmp.dir.symLink(std.testing.io, ".", "root-link", .{ .is_directory = true });
    const path = try testPath(a, tmp);
    defer a.free(path);
    var result = try scan(a, std.testing.io, path, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqual(error.UnsafeFileType, result.entries[0].parse_failure.?);
    var packs = try scan(a, std.testing.io, path, .{ .kind = .resourcepack });
    defer packs.deinit();
    try std.testing.expectEqual(error.UnsafeFileType, packs.entries[0].parse_failure.?);
    const linked = try std.fs.path.join(a, &.{ path, "root-link", "mods" });
    defer a.free(linked);
    if (scan(a, std.testing.io, linked, .{})) |unexpected| {
        var clean = unexpected;
        clean.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
}
fn allocationScan(a: Allocator, path: []const u8) !void {
    var result = try scan(a, std.testing.io, path, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqual(@as(?anyerror, null), result.entries[0].parse_failure);
}
test "scan allocation failures propagate and clean up arenas" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "mods", .default_dir);
    try testZip(a, tmp.dir, "mods/owned.jar", &.{.{ .name = "fabric.mod.json", .bytes = fabric_fixture, .deflate = true }});
    const path = try testPath(a, tmp);
    defer a.free(path);
    try std.testing.checkAllAllocationFailures(a, allocationScan, .{path});
}

fn appendPngChunk(a: Allocator, output: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) !void {
    var number: [4]u8 = undefined;
    std.mem.writeInt(u32, &number, @intCast(data.len), .big);
    try output.appendSlice(a, &number);
    const start = output.items.len;
    try output.appendSlice(a, kind);
    try output.appendSlice(a, data);
    std.mem.writeInt(u32, &number, std.hash.Crc32.hash(output.items[start..]), .big);
    try output.appendSlice(a, &number);
}
fn testPng(a: Allocator) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(a);
    try output.appendSlice(a, "\x89PNG\r\n\x1a\n");
    const header = [_]u8{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0 };
    try appendPngChunk(a, &output, "IHDR", &header);
    var buffer: [256]u8 = undefined;
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compressed = Io.Writer.fixed(&buffer);
    var compressor = try std.compress.flate.Compress.init(&compressed, &window, .zlib, .default);
    try compressor.writer.writeAll(&.{ 0, 255, 0, 0, 255 });
    try compressor.finish();
    try appendPngChunk(a, &output, "IDAT", compressed.buffered());
    try appendPngChunk(a, &output, "IEND", "");
    return output.toOwnedSlice(a);
}
test "safe PNG icons are owned and malformed or escaping icons rejected" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "mods", .default_dir);
    const png = try testPng(a);
    defer a.free(png);
    const metadata = "{\"id\":\"icon_mod\",\"icon\":{\"64\":\"assets/icon.png\"}}";
    try testZip(a, tmp.dir, "mods/good.jar", &.{ .{ .name = "fabric.mod.json", .bytes = metadata }, .{ .name = "assets/icon.png", .bytes = png, .deflate = true } });
    const bad = try a.dupe(u8, png);
    defer a.free(bad);
    bad[20] ^= 1;
    try testZip(a, tmp.dir, "mods/bad.jar", &.{ .{ .name = "fabric.mod.json", .bytes = metadata }, .{ .name = "assets/icon.png", .bytes = bad } });
    try testZip(a, tmp.dir, "mods/escape.jar", &.{.{ .name = "fabric.mod.json", .bytes = "{\"id\":\"escape\",\"icon\":\"../outside.png\"}" }});
    const path = try testPath(a, tmp);
    defer a.free(path);
    var result = try scan(a, std.testing.io, path, .{});
    defer result.deinit();
    try std.testing.expectEqual(error.InvalidIcon, result.entries[0].parse_failure.?);
    try std.testing.expectEqual(error.UnsafeArchivePath, result.entries[1].parse_failure.?);
    try std.testing.expectEqual(@as(?anyerror, null), result.entries[2].parse_failure);
    try std.testing.expectEqualSlices(u8, png, result.entries[2].icon_png.?);
}
test "ZIP64 expansion nesting archive and entry budgets reject visibly" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "mods", .default_dir);
    var zip64: std.zip.EndRecord = std.mem.zeroes(std.zip.EndRecord);
    zip64.signature = std.zip.end_record_sig;
    zip64.record_count_total = std.math.maxInt(u16);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "mods/zip64.jar", .data = std.mem.asBytes(&zip64) });
    const expanded = try a.alloc(u8, 60000);
    defer a.free(expanded);
    @memset(expanded, 'a');
    try testZip(a, tmp.dir, "mods/expansion.jar", &.{.{ .name = "fabric.mod.json", .bytes = expanded, .deflate = true }});
    var nested: [130]u8 = undefined;
    @memset(nested[0..65], '[');
    @memset(nested[65..], ']');
    try testZip(a, tmp.dir, "mods/nested.jar", &.{.{ .name = "fabric.mod.json", .bytes = &nested }});
    const path = try testPath(a, tmp);
    defer a.free(path);
    var result = try scan(a, std.testing.io, path, .{});
    defer result.deinit();
    try std.testing.expectEqual(error.ExpansionLimitExceeded, result.entries[0].parse_failure.?);
    try std.testing.expectEqual(error.MetadataNestingTooDeep, result.entries[1].parse_failure.?);
    try std.testing.expectEqual(error.UnsupportedZip64, result.entries[2].parse_failure.?);
    var size_limited = try scan(a, std.testing.io, path, .{ .max_archive_bytes = 1 });
    defer size_limited.deinit();
    for (size_limited.entries) |entry| try std.testing.expectEqual(error.ArchiveTooLarge, entry.parse_failure.?);
    var entry_limited = try scan(a, std.testing.io, path, .{ .max_archive_entries = 0 });
    defer entry_limited.deinit();
    try std.testing.expectEqual(error.ArchiveEntryLimitExceeded, entry_limited.entries[0].parse_failure.?);
    var listing_limited = try scan(a, std.testing.io, path, .{ .max_directory_entries = 0 });
    defer listing_limited.deinit();
    try std.testing.expect(listing_limited.truncated and listing_limited.entries.len == 0);
    try std.testing.expectError(error.InvalidScanLimits, scan(a, std.testing.io, path, .{ .max_metadata_bytes = 1024 * 1024 + 1 }));
}
test "cancellation checked between archive indexing and metadata decoding" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testZip(a, tmp.dir, "fixture.jar", &.{.{ .name = "fabric.mod.json", .bytes = fabric_fixture, .deflate = true }});
    const file = try openRegular(tmp.dir, std.testing.io, "fixture.jar");
    defer file.close(std.testing.io);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    var budget: usize = 1024 * 1024;
    var source: Source = .{ .a = arena.allocator(), .io = std.testing.io, .options = .{ .cancel = &cancel }, .budget = &budget, .file = file };
    try source.indexArchive((try file.stat(std.testing.io)).size);
    cancel.store(true, .release);
    try std.testing.expectError(error.Canceled, source.read("fabric.mod.json", source.options.max_metadata_bytes));
}

test "large installed JAR scans repeatedly without narrow integer overflow" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "mods", .default_dir);
    const payload = try a.alloc(u8, 128 * 1024);
    defer a.free(payload);
    @memset(payload, 0x5a);
    try testZip(a, tmp.dir, "mods/large.jar", &.{ .{ .name = "fabric.mod.json", .bytes = fabric_fixture }, .{ .name = "example/Payload.class", .bytes = payload } });
    const path = try testPath(a, tmp);
    defer a.free(path);
    for (0..2) |_| {
        var result = try scan(a, std.testing.io, path, .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.entries.len);
        try std.testing.expectEqual(@as(?anyerror, null), result.entries[0].parse_failure);
        try std.testing.expectEqualStrings("1.2.3", result.entries[0].version.?);
        try std.testing.expect(result.entries[0].size > 65557);
    }
}

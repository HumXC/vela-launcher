//! Untrusted archive extraction into a caller-owned, empty staging directory.
//! No publication/rename is performed. On ANY failure discard the whole staging
//! directory; successfully written files may remain. The caller owns/exclusively
//! controls the directory capability and its lifetime (no concurrent mutation).
//! Regular-file links become independent copies after archive validation; no
//! filesystem links are created. Directory-link copies require explicit opt-in.
//! Special files, ZIP64 and global PAX remain unsupported. UTF-8 paths use ASCII
//! collision preflight plus exclusive native filesystem creates, not universal
//! Unicode case folding.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const chunk_size = 32 * 1024;
const spool_name = ".vela-archive-input.tar";

pub const Format = enum { zip, tar_gz };
pub const Cancel = std.atomic.Value(bool);
pub const Limits = struct {
    max_archive_bytes: u64 = 2 * 1024 * 1024 * 1024,
    max_file_bytes: u64 = 1024 * 1024 * 1024,
    /// Includes every materialized link copy, not just decoded members.
    max_total_bytes: u64 = 4 * 1024 * 1024 * 1024,
    /// Also bounds tar headers, padding, metadata and unused/trailing data.
    max_tar_bytes: u64 = 5 * 1024 * 1024 * 1024,
    max_entries: usize = 100_000,
    /// Includes implicit directories, not just explicit archive members.
    max_paths: usize = 200_000,
    max_path_bytes: usize = 4096,
    max_path_depth: usize = 64,
    /// Includes owned entry paths and normalized deferred link targets.
    max_total_path_bytes: usize = 32 * 1024 * 1024,
    /// Bounds decoded compression; link-copy output uses max_total_bytes.
    max_expansion_ratio: u64 = 200,
    /// Maximum link edges along any materialized branch (including directory copies).
    max_link_depth: usize = 64,
    /// Java distributions may opt in to independent copies of in-archive trees.
    /// Root targets, directory hardlinks, and repeated active aliases are rejected.
    /// The last rule conservatively refuses even finite file references through
    /// an alias already being expanded, rather than admitting recursive trees.
    materialize_directory_links: bool = false,
};
pub const Kind = enum { file, directory };
pub const Entry = struct {
    path: []const u8,
    kind: Kind,
    size: u64,
    executable: bool,
};
pub const Result = struct {
    entries: []Entry,
    total_bytes: u64,
    pub fn deinit(self: *Result, allocator: Allocator) void {
        for (self.entries) |entry| allocator.free(entry.path);
        allocator.free(self.entries);
        self.* = undefined;
    }
};

/// destination must be an open, exclusively owned staging directory. We reopen
/// "." for enumeration, so it need not have been opened with iterate=true.
/// Entry paths are owned, normalized relative UTF-8 names (including implicit
/// directories). Safe execute bits become 0755; other files become 0644 on POSIX.
pub fn extract(allocator: Allocator, io: Io, archive_path: []const u8, destination: Io.Dir, format: Format, limits: Limits, cancel: ?*const Cancel) !Result {
    try checkpoint(cancel);
    if (limits.max_path_bytes == 0 or limits.max_path_bytes > 4096 or limits.max_path_depth == 0 or limits.max_expansion_ratio == 0) return error.InvalidArchiveLimits;
    var scan = try destination.openDir(io, ".", .{ .iterate = true, .follow_symlinks = false });
    defer scan.close(io);
    var dir_it = scan.iterate();
    if (try dir_it.next(io) != null) return error.StagingNotEmpty;
    const archive = try Io.Dir.cwd().openFile(io, archive_path, .{});
    defer archive.close(io);
    const stat = try archive.stat(io);
    if (stat.kind != .file) return error.ArchiveNotRegular;
    if (stat.size > limits.max_archive_bytes) return error.ArchiveLimitExceeded;
    var context: Context = .{ .allocator = allocator, .io = io, .destination = destination, .limits = limits, .cancel = cancel };
    defer context.deinit();
    var buffer: [chunk_size]u8 = undefined;
    var input = archive.reader(io, &buffer);
    (switch (format) {
        .zip => context.zip(&input, stat.size),
        .tar_gz => context.tarGz(&input, stat.size),
    }) catch |err| {
        try checkpoint(cancel);
        return err;
    };
    try context.materializeLinks();
    try checkpoint(cancel);
    const entries = try context.entries.toOwnedSlice(allocator);
    return .{ .entries = entries, .total_bytes = context.total_bytes };
}

fn checkpoint(cancel: ?*const Cancel) error{Canceled}!void {
    if (cancel) |flag| if (flag.load(.acquire)) return error.Canceled;
}

/// Reader adapter bounds individual compressed reads and makes cancellation
/// observable even while a parser is skipping optional headers or metadata.
const CheckedReader = struct {
    source: *Io.Reader,
    cancel: ?*const Cancel,
    remaining: u64,
    reader: Io.Reader,
    fn init(source: *Io.Reader, cancel: ?*const Cancel, remaining: u64, buffer: []u8) CheckedReader {
        return .{ .source = source, .cancel = cancel, .remaining = remaining, .reader = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 } };
    }
    fn stream(reader: *Io.Reader, writer: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *CheckedReader = @fieldParentPtr("reader", reader);
        checkpoint(self.cancel) catch return error.ReadFailed;
        if (self.remaining == 0) return error.EndOfStream;
        const n = try self.source.stream(writer, limit.min(.limited(@intCast(@min(self.remaining, chunk_size)))));
        self.remaining -= n;
        return n;
    }
};

const Node = struct { index: usize, explicit: bool, link_index: ?usize = null };
const Link = struct { index: usize, target: []const u8, hard: bool };
const Context = struct {
    allocator: Allocator,
    io: Io,
    destination: Io.Dir,
    limits: Limits,
    cancel: ?*const Cancel,
    entries: std.ArrayList(Entry) = .empty,
    names: std.StringHashMapUnmanaged(Node) = .empty,
    links: std.ArrayList(Link) = .empty,
    tar_hard_links: std.AutoHashMapUnmanaged(usize, void) = .empty,
    total_bytes: u64 = 0,
    total_path_bytes: usize = 0,
    member_count: usize = 0,

    fn deinit(self: *Context) void {
        var keys = self.names.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.names.deinit(self.allocator);
        for (self.entries.items) |entry| self.allocator.free(entry.path);
        self.entries.deinit(self.allocator);
        for (self.links.items) |link| self.allocator.free(link.target);
        self.links.deinit(self.allocator);
        self.tar_hard_links.deinit(self.allocator);
    }
    fn member(self: *Context) !void {
        try checkpoint(self.cancel);
        if (self.member_count >= self.limits.max_entries) return error.ArchiveEntryLimitExceeded;
        self.member_count += 1;
    }
    fn reserveSize(self: *Context, size: u64) !void {
        if (size > self.limits.max_file_bytes or size > self.limits.max_total_bytes - self.total_bytes) return error.ArchiveSizeLimitExceeded;
        self.total_bytes += size;
    }
    fn ratio(self: *Context, expanded: u64, compressed: u64) !void {
        if (expanded > compressed *| self.limits.max_expansion_ratio) return error.ArchiveExpansionLimitExceeded;
    }

    fn lookup(self: *Context, path: []const u8) !*Node {
        var folded: [4096]u8 = undefined;
        const key = std.ascii.lowerString(folded[0..path.len], path);
        const node = self.names.getPtr(key) orelse return error.MissingArchiveLinkTarget;
        if (!std.mem.eql(u8, self.entries.items[node.index].path, path)) return error.MissingArchiveLinkTarget;
        return node;
    }

    fn queueLink(self: *Context, raw: []const u8, target: []const u8, hard: bool) !void {
        const path = try validatePath(raw, false, self.limits);
        if (target.len == 0 or target.len > self.limits.max_path_bytes or target[0] == '/') return error.UnsafeArchiveLinkTarget;
        var buffer: [4096]u8 = undefined;
        var length: usize = 0;
        if (!hard) if (std.mem.lastIndexOfScalar(u8, path, '/')) |end| {
            @memcpy(buffer[0..end], path[0..end]);
            length = end;
        };
        var parts = std.mem.splitScalar(u8, target, '/');
        while (parts.next()) |part| {
            try checkpoint(self.cancel);
            if (std.mem.eql(u8, part, ".")) continue;
            if (std.mem.eql(u8, part, "..")) {
                if (length == 0) return error.UnsafeArchiveLinkTarget;
                length = std.mem.lastIndexOfScalar(u8, buffer[0..length], '/') orelse 0;
                continue;
            }
            _ = validatePath(part, false, self.limits) catch |err| switch (err) {
                error.UnsafeArchivePath => return error.UnsafeArchiveLinkTarget,
                else => return err,
            };
            const separator: usize = if (length == 0) 0 else 1;
            if (part.len + separator > self.limits.max_path_bytes - length) return error.ArchivePathLimitExceeded;
            if (separator != 0) {
                buffer[length] = '/';
                length += 1;
            }
            @memcpy(buffer[length..][0..part.len], part);
            length += part.len;
        }
        if (length == 0) return error.UnsupportedDirectoryLink;
        _ = validatePath(buffer[0..length], false, self.limits) catch |err| switch (err) {
            error.UnsafeArchivePath => return error.UnsafeArchiveLinkTarget,
            else => return err,
        };
        const normalized = try self.allocator.dupe(u8, buffer[0..length]);
        errdefer self.allocator.free(normalized);
        const registered = try self.register(path, .file, 0, false);
        if (length > self.limits.max_total_path_bytes - self.total_path_bytes) return error.ArchivePathLimitExceeded;
        const node = try self.lookup(registered);
        try self.links.append(self.allocator, .{ .index = node.index, .target = normalized, .hard = hard });
        node.link_index = self.links.items.len - 1;
        self.total_path_bytes += length;
    }

    const Copy = struct { source: usize, destination: usize, depth: usize };
    const CopyTask = union(enum) { copy: Copy, leave_link };

    fn followLink(self: *Context, index: usize, depth: *usize, active: *std.ArrayList(usize), tasks: *std.ArrayList(CopyTask)) !Link {
        try checkpoint(self.cancel);
        if (std.mem.indexOfScalar(usize, active.items, index) != null) return error.ArchiveLinkCycle;
        if (depth.* >= self.limits.max_link_depth) return error.ArchiveLinkDepthExceeded;
        depth.* += 1;
        try active.append(self.allocator, index);
        try tasks.append(self.allocator, .leave_link);
        return self.links.items[(try self.lookup(self.entries.items[index].path)).link_index.?];
    }

    // Resolve only the immutable archive namespace, including aliases in a target's
    // parent components. Generated copies can never become new resolution sources.
    fn resolveCopy(self: *Context, source: usize, original_count: usize, depth: *usize, active: *std.ArrayList(usize), tasks: *std.ArrayList(CopyTask)) !struct { index: usize, hard: bool } {
        var index = source;
        var hard = false;
        while ((try self.lookup(self.entries.items[index].path)).link_index != null) {
            const link = try self.followLink(index, depth, active, tasks);
            hard = hard or link.hard;
            var path_buffer: [4096]u8 = undefined;
            @memcpy(path_buffer[0..link.target.len], link.target);
            var length = link.target.len;
            resolve_path: while (true) {
                try checkpoint(self.cancel);
                const node = self.lookup(path_buffer[0..length]) catch null;
                if (node) |found| {
                    if (found.index < original_count) {
                        index = found.index;
                        break :resolve_path;
                    }
                }
                var position: usize = 0;
                while (std.mem.indexOfScalarPos(u8, path_buffer[0..length], position, '/')) |end| {
                    position = end + 1;
                    const prefix = self.lookup(path_buffer[0..end]) catch continue;
                    if (prefix.index >= original_count or prefix.link_index == null) continue;
                    const parent_link = try self.followLink(prefix.index, depth, active, tasks);
                    if (parent_link.hard) return error.UnsupportedDirectoryLink;
                    const suffix = path_buffer[end..length];
                    if (parent_link.target.len + suffix.len > self.limits.max_path_bytes) return error.ArchivePathLimitExceeded;
                    var rewritten: [4096]u8 = undefined;
                    @memcpy(rewritten[0..parent_link.target.len], parent_link.target);
                    @memcpy(rewritten[parent_link.target.len..][0..suffix.len], suffix);
                    length = parent_link.target.len + suffix.len;
                    _ = try validatePath(rewritten[0..length], false, self.limits);
                    @memcpy(path_buffer[0..length], rewritten[0..length]);
                    continue :resolve_path;
                }
                return error.MissingArchiveLinkTarget;
            }
        }
        return .{ .index = index, .hard = hard };
    }

    fn materializeLinks(self: *Context) !void {
        if (self.links.items.len == 0) return;
        const original_count = self.entries.items.len;
        const none = std.math.maxInt(usize);
        const first_child = try self.allocator.alloc(usize, original_count);
        defer self.allocator.free(first_child);
        const next_sibling = try self.allocator.alloc(usize, original_count);
        defer self.allocator.free(next_sibling);
        @memset(first_child, none);
        @memset(next_sibling, none);
        for (self.entries.items, 0..) |entry, index| {
            try checkpoint(self.cancel);
            if (std.mem.lastIndexOfScalar(u8, entry.path, '/')) |end| {
                const parent = (try self.lookup(entry.path[0..end])).index;
                next_sibling[index] = first_child[parent];
                first_child[parent] = index;
            }
        }
        var tasks: std.ArrayList(CopyTask) = .empty;
        defer tasks.deinit(self.allocator);
        var active: std.ArrayList(usize) = .empty;
        defer active.deinit(self.allocator);
        for (self.links.items) |link| {
            try tasks.append(self.allocator, .{ .copy = .{ .source = link.index, .destination = link.index, .depth = 0 } });
            while (tasks.pop()) |task| {
                try checkpoint(self.cancel);
                const copy = switch (task) {
                    .leave_link => {
                        _ = active.pop();
                        continue;
                    },
                    .copy => |value| value,
                };
                var depth = copy.depth;
                const resolved = try self.resolveCopy(copy.source, original_count, &depth, &active, &tasks);
                const source = self.entries.items[resolved.index];
                const destination_path = self.entries.items[copy.destination].path;
                if (source.kind == .directory) {
                    if (!self.limits.materialize_directory_links or resolved.hard) return error.UnsupportedDirectoryLink;
                    if (self.entries.items[copy.destination].kind != .directory) {
                        var parent = try self.openParent(destination_path);
                        defer parent.close(self.io);
                        parent.createDir(self.io, std.fs.path.basename(destination_path), dirPermissions()) catch |err| switch (err) {
                            error.PathAlreadyExists => return error.AliasCollision,
                            else => return err,
                        };
                        self.entries.items[copy.destination].kind = .directory;
                    }
                    var child = first_child[resolved.index];
                    while (child != none) : (child = next_sibling[child]) {
                        try checkpoint(self.cancel);
                        const entry = self.entries.items[child];
                        const child_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ destination_path, std.fs.path.basename(entry.path) });
                        defer self.allocator.free(child_path);
                        const registered = try self.register(child_path, entry.kind, 0, false);
                        const destination = (try self.lookup(registered)).index;
                        try tasks.append(self.allocator, .{ .copy = .{ .source = child, .destination = destination, .depth = depth } });
                    }
                } else {
                    try self.reserveSize(source.size);
                    var parent = try self.openParent(source.path);
                    defer parent.close(self.io);
                    const file = try parent.openFile(self.io, std.fs.path.basename(source.path), .{ .follow_symlinks = false, .allow_directory = false });
                    defer file.close(self.io);
                    const stat = try file.stat(self.io);
                    if (stat.kind != .file or stat.size != source.size) return error.ArchiveLinkTargetChanged;
                    var buffer: [chunk_size]u8 = undefined;
                    var reader = file.reader(self.io, &buffer);
                    _ = try self.writeEntry(destination_path, &reader.interface, source.size, source.executable);
                    self.entries.items[copy.destination].size = source.size;
                    self.entries.items[copy.destination].executable = source.executable;
                }
            }
        }
    }

    fn zipPayload(self: *Context, path: []const u8, reader: *Io.Reader, size: u64, executable: bool, directory: bool, link: bool) !u32 {
        if (directory) return 0;
        if (!link) return self.writeEntry(path, reader, size, executable);
        if (size == 0 or size > self.limits.max_path_bytes) return error.UnsafeArchiveLinkTarget;
        var buffer: [4096]u8 = undefined;
        const target = buffer[0..@intCast(size)];
        try reader.readSliceAll(target);
        try self.queueLink(path, target, false);
        return std.hash.Crc32.hash(target);
    }

    fn register(self: *Context, raw: []const u8, kind: Kind, size: u64, executable: bool) ![]const u8 {
        const path = try validatePath(raw, kind == .directory, self.limits);
        if (path.len == 0) return path; // harmless ./ root directory member
        var position: usize = 0;
        while (true) {
            const end = std.mem.indexOfScalarPos(u8, path, position, '/') orelse path.len;
            const prefix = path[0..end];
            const leaf = end == path.len;
            const desired_kind: Kind = if (leaf) kind else .directory;
            var folded: [4096]u8 = undefined;
            for (prefix, 0..) |c, i| folded[i] = std.ascii.toLower(c);
            const key = folded[0..prefix.len];
            if (self.names.getPtr(key)) |node| {
                const existing = &self.entries.items[node.index];
                if (!std.mem.eql(u8, existing.path, prefix)) return error.ArchiveCaseCollision;
                if (existing.kind != desired_kind) return error.ArchivePathConflict;
                if (leaf) {
                    if (node.explicit) return error.DuplicateArchivePath;
                    node.explicit = true;
                }
            } else {
                if (self.entries.items.len >= self.limits.max_paths or prefix.len > self.limits.max_total_path_bytes - self.total_path_bytes) return error.ArchivePathLimitExceeded;
                {
                    const name = try self.allocator.dupe(u8, prefix);
                    errdefer self.allocator.free(name);
                    const owned_key = try self.allocator.dupe(u8, key);
                    errdefer self.allocator.free(owned_key);
                    try self.entries.ensureUnusedCapacity(self.allocator, 1);
                    try self.names.put(self.allocator, owned_key, .{ .index = self.entries.items.len, .explicit = leaf });
                    self.entries.appendAssumeCapacity(.{ .path = name, .kind = desired_kind, .size = if (leaf) size else 0, .executable = leaf and executable });
                    self.total_path_bytes += prefix.len;
                }
                if (desired_kind == .directory) {
                    var parent = try self.openParent(prefix);
                    defer parent.close(self.io);
                    // Existing directories are never adopted: only registry-owned
                    // directories are reopened, and always with NOFOLLOW.
                    parent.createDir(self.io, std.fs.path.basename(prefix), dirPermissions()) catch |err| switch (err) {
                        error.PathAlreadyExists => return error.AliasCollision,
                        else => return err,
                    };
                }
            }
            if (leaf) break;
            position = end + 1;
        }
        return path;
    }

    fn openParent(self: *Context, path: []const u8) !Io.Dir {
        var current = try self.destination.openDir(self.io, ".", .{ .follow_symlinks = false });
        errdefer current.close(self.io);
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |end| {
            var components = std.mem.splitScalar(u8, path[0..end], '/');
            while (components.next()) |component| {
                try checkpoint(self.cancel);
                const next = try current.openDir(self.io, component, .{ .follow_symlinks = false });
                current.close(self.io);
                current = next;
            }
        }
        return current;
    }

    fn writeEntry(self: *Context, path: []const u8, reader: *Io.Reader, size: u64, executable: bool) !u32 {
        var parent = try self.openParent(path);
        defer parent.close(self.io);
        const file = try parent.createFile(self.io, std.fs.path.basename(path), .{ .exclusive = true, .permissions = filePermissions(executable) });
        defer file.close(self.io);
        var crc: std.hash.Crc32 = .init();
        var data: [chunk_size]u8 = undefined;
        var remaining = size;
        while (remaining > 0) {
            try checkpoint(self.cancel);
            const part = data[0..@intCast(@min(remaining, data.len))];
            try reader.readSliceAll(part);
            try checkpoint(self.cancel);
            try file.writeStreamingAll(self.io, part);
            crc.update(part);
            remaining -= part.len;
        }
        try checkpoint(self.cancel);
        // chmod after creation preserves Java execute permission independently
        // of restrictive umasks; privileges and writable-by-other bits are not copied.
        try file.setPermissions(self.io, filePermissions(executable));
        return crc.final();
    }

    fn zip(self: *Context, input: *Io.File.Reader, archive_size: u64) !void {
        const end = try std.zip.EndRecord.findFile(input);
        if (end.need_zip64()) return error.UnsupportedZip64;
        var iterator = try std.zip.Iterator.init(input);
        if (iterator.cd_record_count > self.limits.max_entries) return error.ArchiveEntryLimitExceeded;
        if (iterator.cd_zip_offset > archive_size or iterator.cd_size > archive_size - iterator.cd_zip_offset) return error.InvalidZipBounds;
        var compressed_work: u64 = 0;
        while (try iterator.next()) |entry| {
            try self.member();
            // Overlapping payloads must not repeatedly decode a large stream
            // of empty deflate blocks while evading the output byte budget.
            if (entry.compressed_size > archive_size - compressed_work) return error.ArchiveCompressedWorkLimitExceeded;
            compressed_work += entry.compressed_size;
            if (entry.filename_len == 0 or entry.filename_len > self.limits.max_path_bytes) return error.UnsafeArchivePath;
            try input.seekTo(entry.header_zip_offset);
            const central = try input.interface.takeStruct(std.zip.CentralDirectoryFileHeader, .little);
            if (central.extra_len != 0 and (central.compressed_size == std.math.maxInt(u32) or central.uncompressed_size == std.math.maxInt(u32) or central.local_file_header_offset == std.math.maxInt(u32))) return error.UnsupportedZip64;
            var name_buffer: [4096]u8 = undefined;
            const name = name_buffer[0..entry.filename_len];
            try input.interface.readSliceAll(name);
            const directory = name[name.len - 1] == '/';
            const mode = central.external_file_attributes >> 16;
            const unix_type = mode & 0o170000;
            const is_link = unix_type == 0o120000;
            if (is_link and directory) return error.InvalidZipAttributes;
            if (unix_type != 0 and unix_type != 0o100000 and unix_type != 0o040000 and !is_link) return error.UnsupportedArchiveSpecialFile;
            if (mode & 0o7000 != 0) return error.UnsafeArchivePermissions;
            if ((unix_type == 0o040000 and !directory) or (unix_type == 0o100000 and directory)) return error.InvalidZipAttributes;
            if (central.external_file_attributes & 0x408 != 0) return error.UnsupportedArchiveSpecialFile;
            if (central.external_file_attributes & 0x10 != 0 and !directory) return error.InvalidZipAttributes;
            if (entry.compression_method != .store and entry.compression_method != .deflate) return error.UnsupportedCompressionMethod;
            const flags: u16 = @bitCast(entry.flags);
            if (flags & ~@as(u16, 0x080e) != 0) return error.UnsupportedZipFlags;
            if (entry.file_offset > iterator.cd_zip_offset or @sizeOf(std.zip.LocalFileHeader) > iterator.cd_zip_offset - entry.file_offset) return error.InvalidZipBounds;
            try input.seekTo(entry.file_offset);
            const local = try input.interface.takeStruct(std.zip.LocalFileHeader, .little);
            if (!std.mem.eql(u8, &local.signature, &std.zip.local_file_header_sig) or local.filename_len != entry.filename_len or local.compression_method != entry.compression_method or @as(u16, @bitCast(local.flags)) != flags) return error.ZipHeaderMismatch;
            if ((local.crc32 != 0 and local.crc32 != entry.crc32) or (local.compressed_size != 0 and local.compressed_size != entry.compressed_size) or (local.uncompressed_size != 0 and local.uncompressed_size != entry.uncompressed_size)) return error.ZipHeaderMismatch;
            var local_name_buffer: [4096]u8 = undefined;
            const local_name = local_name_buffer[0..local.filename_len];
            try input.interface.readSliceAll(local_name);
            if (!std.mem.eql(u8, name, local_name)) return error.ZipHeaderMismatch;
            const data_offset = entry.file_offset + @sizeOf(std.zip.LocalFileHeader) + local.filename_len + local.extra_len;
            if (data_offset > iterator.cd_zip_offset or entry.compressed_size > iterator.cd_zip_offset - data_offset) return error.InvalidZipBounds;
            if (directory and entry.uncompressed_size != 0) return error.InvalidArchiveDirectory;
            if (!is_link) try self.reserveSize(entry.uncompressed_size);
            try self.ratio(entry.uncompressed_size, entry.compressed_size);
            const executable = mode & 0o111 != 0;
            const path = if (is_link) name else try self.register(name, if (directory) .directory else .file, entry.uncompressed_size, executable);
            try input.seekTo(data_offset);
            var compressed_buffer: [chunk_size]u8 = undefined;
            var compressed: CheckedReader = .init(&input.interface, self.cancel, entry.compressed_size, &compressed_buffer);
            const crc = switch (entry.compression_method) {
                .store => blk: {
                    if (entry.compressed_size != entry.uncompressed_size) return error.ZipSizeMismatch;
                    break :blk try self.zipPayload(path, &compressed.reader, entry.uncompressed_size, executable, directory, is_link);
                },
                .deflate => blk: {
                    var window: [std.compress.flate.max_window_len]u8 = undefined;
                    var decoder: std.compress.flate.Decompress = .init(&compressed.reader, .raw, &window);
                    const crc = try self.zipPayload(path, &decoder.reader, entry.uncompressed_size, executable, directory, is_link);
                    if (try decoder.reader.readSliceShort(local_name_buffer[0..1]) != 0) return error.ZipSizeMismatch;
                    if (compressed.remaining != 0 or compressed.reader.seek != compressed.reader.end) return error.ZipCompressedSizeMismatch;
                    break :blk crc;
                },
                else => unreachable,
            };
            if (crc != entry.crc32) return error.ArchiveChecksumMismatch;
        }
    }

    fn tarGz(self: *Context, input: *Io.File.Reader, archive_size: u64) !void {
        const spool = try self.destination.createFile(self.io, spool_name, .{ .read = true, .exclusive = true });
        errdefer self.destination.deleteFile(self.io, spool_name) catch {};
        {
            defer spool.close(self.io);
            try self.tarGzSpool(input, archive_size, spool);
        }
        // A successful extraction must not leave its internal spool to publish.
        try self.destination.deleteFile(self.io, spool_name);
    }

    fn tarGzSpool(self: *Context, input: *Io.File.Reader, archive_size: u64, spool: Io.File) !void {
        var compressed_buffer: [chunk_size]u8 = undefined;
        var compressed: CheckedReader = .init(&input.interface, self.cancel, archive_size, &compressed_buffer);
        const gzip_header = try compressed.reader.peek(10);
        if (gzip_header[3] & 0xe0 != 0) return error.BadGzipHeader;
        // std flate deliberately skips FHCRC. Reject it rather than claiming
        // integrity for an optional header checksum that was never verified.
        if (gzip_header[3] & 0x02 != 0) return error.UnsupportedGzipHeaderChecksum;
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var decoder: std.compress.flate.Decompress = .init(&compressed.reader, .gzip, &window);
        var bytes: u64 = 0;
        var crc: std.hash.Crc32 = .init();
        var data: [chunk_size]u8 = undefined;
        while (true) {
            try checkpoint(self.cancel);
            const n = try decoder.reader.readSliceShort(&data);
            if (n == 0) break;
            if (n > self.limits.max_tar_bytes - bytes) return error.ArchiveSizeLimitExceeded;
            bytes += n;
            try self.ratio(bytes, archive_size);
            try checkpoint(self.cancel);
            try spool.writeStreamingAll(self.io, data[0..n]);
            crc.update(data[0..n]);
        }
        if (decoder.container_metadata.gzip.crc != crc.final() or decoder.container_metadata.gzip.count != @as(u32, @truncate(bytes))) return error.ArchiveChecksumMismatch;
        // Reject concatenated gzip members and trailing junk instead of silently
        // accepting a partial archive or bypassing resource/checksum accounting.
        if (compressed.remaining != 0 or compressed.reader.seek != compressed.reader.end) return error.TrailingArchiveData;
        var tar_buffer: [chunk_size]u8 = undefined;
        var tar_reader = spool.reader(self.io, &tar_buffer);
        try preflightTar(self, &tar_reader, bytes);
        tar_reader = spool.reader(self.io, &tar_buffer);
        var checked_buffer: [chunk_size]u8 = undefined;
        var checked: CheckedReader = .init(&tar_reader.interface, self.cancel, bytes, &checked_buffer);
        var name: [4096]u8 = undefined;
        var link: [4096]u8 = undefined;
        var iterator = std.tar.Iterator.init(&checked.reader, .{ .file_name_buffer = &name, .link_name_buffer = &link });
        while (try iterator.next()) |file| {
            try self.member();
            if (file.mode & ~@as(u32, 0o777) != 0) return error.UnsafeArchivePermissions;
            if (file.kind == .sym_link) {
                if (file.size != 0) return error.InvalidArchiveLink;
                try self.queueLink(file.name, file.link_name, self.tar_hard_links.contains(self.member_count - 1));
                continue;
            }
            if (file.link_name.len != 0) return error.InvalidArchiveLink;
            if (file.kind == .directory and file.size != 0) return error.InvalidArchiveDirectory;
            try self.reserveSize(file.size);
            const path = try self.register(file.name, if (file.kind == .directory) .directory else .file, file.size, file.mode & 0o111 != 0);
            if (file.kind == .file) _ = try self.writeEntry(path, &checked.reader, file.size, file.mode & 0o111 != 0);
            iterator.unread_file_bytes = 0;
        }
    }
};

fn filePermissions(executable: bool) Io.File.Permissions {
    return if (comptime Io.File.Permissions.has_executable_bit) .fromMode(if (executable) 0o755 else 0o644) else .default_file;
}
fn dirPermissions() Io.File.Permissions {
    return if (comptime Io.File.Permissions.has_executable_bit) .fromMode(0o755) else .default_dir;
}

fn validatePath(raw: []const u8, directory: bool, limits: Limits) ![]const u8 {
    if (raw.len == 0 or raw.len > limits.max_path_bytes) return error.UnsafeArchivePath;
    if (!std.unicode.utf8ValidateSlice(raw)) return error.UnsafeArchivePath;
    var codepoints = std.unicode.Utf8View.initUnchecked(raw).iterator();
    while (codepoints.nextCodepoint()) |codepoint| {
        if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f)) return error.UnsafeArchivePath;
    }
    var path = raw;
    while (std.mem.startsWith(u8, path, "./")) path = path[2..];
    if (directory and (path.len == 0 or std.mem.eql(u8, path, "."))) return path[0..0];
    if (directory and std.mem.endsWith(u8, path, "/")) path = path[0 .. path.len - 1];
    var components = std.mem.splitScalar(u8, path, '/');
    var depth: usize = 0;
    while (components.next()) |component| {
        depth += 1;
        if (depth > limits.max_path_depth) return error.ArchivePathLimitExceeded;
        if (component.len == 0 or component.len > 255 or component[component.len - 1] == '.' or component[component.len - 1] == ' ') return error.UnsafeArchivePath;
        for (component) |c| {
            if (std.mem.indexOfScalar(u8, "\\:*?\"<>|", c) != null) return error.UnsafeArchivePath;
        }
        const stem = std.mem.trimEnd(u8, component[0 .. std.mem.indexOfScalar(u8, component, '.') orelse component.len], " ");
        for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "CLOCK$", "CONIN$", "CONOUT$" }) |reserved| {
            if (std.ascii.eqlIgnoreCase(stem, reserved)) return error.UnsafeArchivePath;
        }
        if (stem.len > 3 and (std.ascii.eqlIgnoreCase(stem[0..3], "COM") or std.ascii.eqlIgnoreCase(stem[0..3], "LPT"))) {
            const suffix = stem[3..];
            if ((suffix.len == 1 and suffix[0] >= '0' and suffix[0] <= '9') or
                std.mem.eql(u8, suffix, "¹") or std.mem.eql(u8, suffix, "²") or std.mem.eql(u8, suffix, "³")) return error.UnsafeArchivePath;
        }
    }
    if (std.ascii.eqlIgnoreCase(path, spool_name)) return error.UnsafeArchivePath;
    return path;
}

/// Safety preflight around std.tar.Iterator: its alignForward(u64,size,512)
/// can overflow for hostile binary/PAX lengths. This pass only bounds framing
/// and extensions; standard tar/PAX parsers remain authoritative for names,
/// checksums and metadata. Global PAX and sparse extensions are unsupported.
fn preflightTar(ctx: *Context, input: *Io.File.Reader, length: u64) !void {
    var offset: u64 = 0;
    var count: usize = 0;
    var member_index: usize = 0;
    var pending_size: ?u64 = null;
    var pending_extension = false;
    var header: [512]u8 = undefined;
    while (offset < length) {
        try checkpoint(ctx.cancel);
        if (length - offset < 512) return error.TruncatedTar;
        try input.seekTo(offset);
        try input.interface.readSliceAll(&header);
        offset += 512;
        if (std.mem.allEqual(u8, &header, 0)) {
            if (pending_extension or length - offset < 512) return error.TruncatedTar;
            // Require both end blocks and forbid hidden archives after the end.
            var buffer: [chunk_size]u8 = undefined;
            while (offset < length) {
                try checkpoint(ctx.cancel);
                const n: usize = @intCast(@min(length - offset, buffer.len));
                try input.interface.readSliceAll(buffer[0..n]);
                if (!std.mem.allEqual(u8, buffer[0..n], 0)) return error.TrailingArchiveData;
                offset += n;
            }
            return;
        }
        if (count >= ctx.limits.max_entries) return error.ArchiveEntryLimitExceeded;
        count += 1;
        const raw = header[124..136];
        const size = if (raw[0] == 0x80) blk: {
            if (!std.mem.allEqual(u8, raw[1..4], 0)) return error.ArchiveSizeLimitExceeded;
            break :blk std.mem.readInt(u64, raw[4..12], .big);
        } else try std.fmt.parseInt(u64, blk: {
            const trimmed = std.mem.trim(u8, raw, " \x00");
            break :blk if (trimmed.len == 0) "0" else trimmed;
        }, 8);
        if (size > ctx.limits.max_tar_bytes or size > length - offset) return error.ArchiveSizeLimitExceeded;
        const padding = (512 - size % 512) % 512;
        if (padding > length - offset - size) return error.TruncatedTar;
        switch (header[156]) {
            0, '0', '1', '2', '5' => {
                if (pending_size) |pax_size| if (pax_size != size) return error.TarSizeMismatch;
                if (header[156] == '1') {
                    if (size != 0) return error.InvalidArchiveLink;
                    // Zig's tar iterator validates but does not emit hard links.
                    // Validate the original header with that parser, then adapt
                    // only its type/checksum in our private, verified spool.
                    var probe_reader: Io.Reader = .fixed(&header);
                    var probe_name: [4096]u8 = undefined;
                    var probe_link: [4096]u8 = undefined;
                    var probe = std.tar.Iterator.init(&probe_reader, .{ .file_name_buffer = &probe_name, .link_name_buffer = &probe_link });
                    _ = probe.next() catch |err| switch (err) {
                        error.TarUnsupportedHeader => null,
                        else => return err,
                    };
                    try ctx.tar_hard_links.put(ctx.allocator, member_index, {});
                    header[156] = '2';
                    @memset(header[148..156], ' ');
                    var sum: u32 = 0;
                    for (header) |byte| sum += byte;
                    _ = try std.fmt.bufPrint(header[148..156], "{o:0>6}\x00 ", .{sum});
                    try input.file.writePositionalAll(ctx.io, &header, offset - 512);
                }
                member_index += 1;
                pending_size = null;
                pending_extension = false;
            },
            'g' => return error.UnsupportedGlobalPax,
            'L', 'K' => {
                if (size > ctx.limits.max_path_bytes) return error.ArchivePathLimitExceeded;
                pending_extension = true;
            },
            'x' => {
                if (size > 64 * 1024) return error.ArchiveMetadataLimitExceeded;
                var metadata: [64 * 1024]u8 = undefined;
                const payload = metadata[0..@intCast(size)];
                try input.interface.readSliceAll(payload);
                if (std.mem.indexOf(u8, payload, "GNU.sparse") != null or std.mem.indexOf(u8, payload, "SCHILY.filetype") != null) return error.UnsupportedArchiveSpecialFile;
                var reader: Io.Reader = .fixed(payload);
                var pax: std.tar.PaxIterator = .{ .reader = &reader, .size = payload.len };
                pending_size = null;
                while (try pax.next()) |attribute| {
                    var value_buffer: [4096]u8 = undefined;
                    const value = try attribute.value(&value_buffer);
                    if (attribute.kind == .size) {
                        pending_size = try std.fmt.parseInt(u64, value, 10);
                        if (pending_size.? > ctx.limits.max_file_bytes) return error.ArchiveSizeLimitExceeded;
                    }
                }
                pending_extension = true;
            },
            else => return error.UnsupportedArchiveSpecialFile,
        }
        offset += size + padding;
    }
    return error.TruncatedTar;
}

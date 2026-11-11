//! HTTP cache persistence only; callers own request identity/policy and per-key locking.
//! Files are atomic across processes, not a cross-process transaction or LRU lock.
//! The root must be an application-owned directory. Only lowercase SHA256 .cache
//! names in http-v3 are evicted. Temporary files left by process crashes are not
//! removed: another process may still own them. Capacity counts committed files,
//! with temporary/concurrent writes allowed to exceed it until the next prune.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const Sha256 = std.crypto.hash.sha2.Sha256;
const fs = @import("content_fs.zig");

pub const Record = struct {
    schema: u32 = 1,
    url: []const u8,
    scope: []const u8 = "",
    request_key: []const u8,
    stored_at: i64,
    request_time: i64,
    response_time: i64,
    headers: @import("http_cache_policy.zig").Headers = .{},
    body_hash: [32]u8,
    body: []const u8,
};

/// All record slices are owned by parsed, independently of input/read buffers.
pub const Entry = struct {
    parsed: std.json.Parsed(Record),

    pub fn deinit(self: *Entry) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

pub const max_entries: usize = 128;
pub const max_disk_bytes: usize = 64 * 1024 * 1024;
pub const max_metadata_bytes: usize = 64 * 1024;
pub const max_scan_entries: usize = 4096;
// Version 3: 8-byte magic, LE u32 metadata length, LE u64 body length,
// SHA256(metadata), bounded JSON Record with body="", then unencoded body.
// Metadata and body checksums detect corruption, not malicious trusted-root edits.
const subdir = "http-v3";
const magic = "VELAHT03";
const frame_size = 52;
const max_encoded_metadata = max_metadata_bytes * 6 + 4096;

fn filename(key: [32]u8) [70]u8 {
    return (std.fmt.bytesToHex(key, .lower) ++ ".cache").*;
}

fn validMetadata(record: Record) bool {
    if (record.schema != 1) return false;
    var remaining: usize = max_metadata_bytes;
    for ([_][]const u8{ record.url, record.scope, record.request_key }) |value| {
        if (value.len > remaining) return false;
        remaining -= value.len;
    }
    inline for (.{ "cache_control", "date", "age", "expires", "etag", "last_modified", "vary" }) |field| {
        if (@field(record.headers, field)) |value| {
            if (value.len > remaining) return false;
            remaining -= value.len;
        }
    }
    return true;
}

/// Missing, inaccessible, oversized, unsupported and corrupt files are misses.
/// Cancellation and allocation failure propagate. No miss deletes a file: it may
/// have been replaced by another process since the read began.
pub fn load(a: Allocator, io: Io, root: []const u8, key: [32]u8, max_body: usize) !?Entry {
    const base = Dir.cwd().openDir(io, root, .{}) catch |err| switch (err) {
        error.Canceled => return err,
        else => return null,
    };
    defer base.close(io);
    const dir = base.openDir(io, subdir, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.Canceled => return err,
        else => return null,
    };
    defer dir.close(io);
    const name = filename(key);
    const file = dir.openFile(io, &name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.Canceled => return err,
        else => return null,
    };
    defer file.close(io);
    const stat = file.stat(io) catch |err| switch (err) {
        error.Canceled => return err,
        else => return null,
    };
    if (stat.kind != .file or stat.size < frame_size or stat.size > max_disk_bytes) return null;
    var frame: [frame_size]u8 = undefined;
    const frame_read = file.readPositionalAll(io, &frame, 0) catch |err| switch (err) {
        error.Canceled => return err,
        else => return null,
    };
    if (frame_read != frame_size or !std.mem.eql(u8, frame[0..8], magic)) return null;
    const metadata_len = std.mem.readInt(u32, frame[8..12], .little);
    const body_len = std.mem.readInt(u64, frame[12..20], .little);
    if (metadata_len > max_encoded_metadata or body_len > max_body or body_len > max_disk_bytes) return null;
    if (frame_size + @as(u64, metadata_len) + body_len != stat.size) return null;
    const metadata = try a.alloc(u8, metadata_len);
    defer a.free(metadata);
    const metadata_read = file.readPositionalAll(io, metadata, frame_size) catch |err| switch (err) {
        error.Canceled => return err,
        else => return null,
    };
    if (metadata_read != metadata.len) return null;
    var digest: [32]u8 = undefined;
    Sha256.hash(metadata, &digest, .{});
    if (!std.mem.eql(u8, &digest, frame[20..52])) return null;
    var parsed = std.json.parseFromSlice(Record, a, metadata, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    var keep = false;
    defer if (!keep) parsed.deinit();
    if (!validMetadata(parsed.value) or parsed.value.body.len != 0) return null;
    // Read directly into the Entry arena: no body-sized parse buffer or copy.
    const body = try parsed.arena.allocator().alloc(u8, @intCast(body_len));
    const body_read = file.readPositionalAll(io, body, frame_size + @as(u64, metadata_len)) catch |err| switch (err) {
        error.Canceled => return err,
        else => return null,
    };
    if (body_read != body.len) return null;
    // Detect growth since stat without allocating an extra body-sized buffer.
    var extra: [1]u8 = undefined;
    const extra_read = file.readPositionalAll(io, &extra, stat.size) catch |err| switch (err) {
        error.Canceled => return err,
        else => return null,
    };
    if (extra_read != 0) return null;
    Sha256.hash(body, &digest, .{});
    if (!std.mem.eql(u8, &digest, &parsed.value.body_hash)) return null;
    parsed.value.body = body;
    keep = true;
    return .{ .parsed = parsed };
}

/// Recomputes body_hash; the caller's hash need not be initialized correctly.
/// Rejects invalid metadata and records larger than the entire disk budget.
/// Uses an exclusive unpredictable temp name, then replaces only this key's
/// cache filename. Errors (including Cancelled) propagate; after rename the new
/// cache record may already be visible. Cache writes are not power-loss durable.
pub fn save(a: Allocator, io: Io, root: []const u8, key: [32]u8, record: Record) !void {
    if (!validMetadata(record)) return error.InvalidRecord;
    if (record.body.len > max_disk_bytes) return error.RecordTooLarge;
    var stored = record;
    Sha256.hash(stored.body, &stored.body_hash, .{});
    stored.body = "";
    const bytes = try std.json.Stringify.valueAlloc(a, stored, .{});
    defer a.free(bytes);
    if (bytes.len > max_encoded_metadata) return error.InvalidRecord;
    const disk_size = frame_size + bytes.len + record.body.len;
    if (disk_size > max_disk_bytes) return error.RecordTooLarge;
    var frame: [frame_size]u8 = undefined;
    @memcpy(frame[0..8], magic);
    std.mem.writeInt(u32, frame[8..12], @intCast(bytes.len), .little);
    std.mem.writeInt(u64, frame[12..20], @intCast(record.body.len), .little);
    Sha256.hash(bytes, frame[20..52], .{});
    const base = try Dir.cwd().createDirPathOpen(io, root, .{ .permissions = fs.privatePermissions(true) });
    defer base.close(io);
    base.createDir(io, subdir, fs.privatePermissions(true)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const dir = try base.openDir(io, subdir, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    const name = filename(key);
    try pruneDir(a, io, dir, &name, max_entries - 1, max_disk_bytes - disk_size);
    var random: [16]u8 = undefined;
    try Io.randomSecure(io, &random);
    const temporary = (".http-" ++ std.fmt.bytesToHex(random, .lower) ++ ".tmp").*;
    const file = try dir.createFile(io, &temporary, .{ .exclusive = true, .permissions = fs.privatePermissions(false) });
    var closed = false;
    defer if (!closed) file.close(io);
    defer dir.deleteFile(io, &temporary) catch {};
    try file.writeStreamingAll(io, &frame);
    try file.writeStreamingAll(io, bytes);
    try file.writeStreamingAll(io, record.body);
    try file.sync(io);
    file.close(io);
    closed = true;
    try dir.rename(&temporary, dir, &name, io);
}

/// Best effort by contract, including cancellation. Never creates directories.
pub fn remove(io: Io, root: []const u8, key: [32]u8) void {
    const base = Dir.cwd().openDir(io, root, .{}) catch return;
    defer base.close(io);
    const dir = base.openDir(io, subdir, .{ .follow_symlinks = false }) catch return;
    defer dir.close(io);
    const name = filename(key);
    dir.deleteFile(io, &name) catch {};
}

/// Optional maintenance; save also prunes before publishing. Scans at most 4096
/// directory entries and fails with ScanLimitExceeded before deleting anything
/// if that bound is exceeded. Deletes oldest modification times first, only
/// regular cache files. Missing directories are fine; other errors propagate.
/// Concurrent writers can exceed the budgets temporarily, so this is a bounded
/// best-effort cache budget, not a global quota. No HTTP or process locks here.
pub fn prune(a: Allocator, io: Io, root: []const u8) !void {
    const base = Dir.cwd().openDir(io, root, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer base.close(io);
    const dir = base.openDir(io, subdir, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    try pruneDir(a, io, dir, null, max_entries, max_disk_bytes);
}

const Candidate = struct {
    name: [70]u8,
    size: u64,
    modified: i128,

    fn lessThan(_: void, lhs: Candidate, rhs: Candidate) bool {
        if (lhs.modified == rhs.modified) return std.mem.lessThan(u8, &lhs.name, &rhs.name);
        return lhs.modified < rhs.modified;
    }
};

fn isCacheName(name: []const u8) bool {
    if (name.len != 70 or !std.mem.endsWith(u8, name, ".cache")) return false;
    for (name[0..64]) |c| if (!(c >= '0' and c <= '9') and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

fn pruneDir(a: Allocator, io: Io, dir: Dir, protected: ?[]const u8, count_limit: usize, byte_limit: usize) !void {
    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(a);
    var total: u64 = 0;
    var scanned: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |item| {
        scanned += 1;
        if (scanned > max_scan_entries) return error.ScanLimitExceeded;
        if (!isCacheName(item.name)) continue;
        if (protected) |name| if (std.mem.eql(u8, name, item.name)) continue;
        const stat = dir.statFile(io, item.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (stat.kind != .file) continue;
        try candidates.append(a, .{ .name = item.name[0..70].*, .size = stat.size, .modified = stat.mtime.nanoseconds });
        total = std.math.add(u64, total, stat.size) catch return error.RecordTooLarge;
    }
    std.mem.sort(Candidate, candidates.items, {}, Candidate.lessThan);
    var count = candidates.items.len;
    for (candidates.items) |item| {
        if (count <= count_limit and total <= byte_limit) break;
        dir.deleteFile(io, &item.name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        count -= 1;
        total -= item.size;
    }
}

fn testRecord(body: []const u8) Record {
    return .{
        .url = "https://example.test/metadata",
        .request_key = "GET:metadata",
        .stored_at = 30,
        .request_time = 10,
        .response_time = 20,
        .headers = .{ .etag = "\"version-1\"", .cache_control = "max-age=60" },
        .body_hash = @splat(0),
        .body = body,
    };
}

fn testWrite(dir: Dir, key: [32]u8, bytes: []const u8) !void {
    const name = filename(key);
    const file = try dir.createFile(std.testing.io, &name, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes);
}

test "binary cache preserves arbitrary icon bytes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const key: [32]u8 = @splat(91);
    var body: [256]u8 = undefined;
    for (&body, 0..) |*byte, i| byte.* = @intCast(i);
    try save(a, io, root, key, testRecord(&body));
    var entry = (try load(a, io, root, key, body.len)).?;
    defer entry.deinit();
    try std.testing.expectEqualSlices(u8, &body, entry.parsed.value.body);
}

test "cache survives independent loads and owns all parsed strings" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const key: [32]u8 = @splat(1);
    const body = "{\"versions\":[1,2]}\n";
    try save(a, io, root, key, testRecord(body));
    {
        var entry = (try load(a, io, root, key, 1024)).?;
        defer entry.deinit();
        try std.testing.expectEqualStrings(body, entry.parsed.value.body);
        try std.testing.expectEqualStrings("\"version-1\"", entry.parsed.value.headers.etag.?);
        try std.testing.expectEqual(@as(i64, 10), entry.parsed.value.request_time);
    }
    var restarted = (try load(a, io, root, key, body.len)).?;
    defer restarted.deinit();
    try std.testing.expectEqualStrings(body, restarted.parsed.value.body);
    try std.testing.expect((try load(a, io, root, key, body.len - 1)) == null);
    remove(io, root, key);
    remove(io, root, key);
    try std.testing.expect((try load(a, io, root, key, 1024)) == null);
}

test "missing cache does not create directories" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const missing = try std.fs.path.join(a, &.{ root, "missing" });
    defer a.free(missing);
    const key: [32]u8 = @splat(0);
    try std.testing.expect((try load(a, io, missing, key, 10)) == null);
    remove(io, missing, key);
    try prune(a, io, missing);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "missing", .{}));
}

test "tampering truncation schema and metadata bounds are misses" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const key: [32]u8 = @splat(2);
    try save(a, io, root, key, testRecord("original"));
    const dir = try tmp.dir.openDir(io, subdir, .{});
    defer dir.close(io);
    const name = filename(key);
    const original = try dir.readFileAlloc(io, &name, a, .limited(4096));
    defer a.free(original);
    const tampered = try a.dupe(u8, original);
    defer a.free(tampered);
    const offset = std.mem.indexOf(u8, tampered, "original").?;
    tampered[offset] = 'X';
    try testWrite(dir, key, tampered);
    try std.testing.expect((try load(a, io, root, key, 1024)) == null);
    try testWrite(dir, key, original[0 .. original.len / 2]);
    try std.testing.expect((try load(a, io, root, key, 1024)) == null);
    var bad = testRecord("original");
    bad.schema = 2;
    Sha256.hash(bad.body, &bad.body_hash, .{});
    const unsupported = try std.json.Stringify.valueAlloc(a, bad, .{});
    defer a.free(unsupported);
    try testWrite(dir, key, unsupported);
    try std.testing.expect((try load(a, io, root, key, 1024)) == null);
    try std.testing.expectError(error.InvalidRecord, save(a, io, root, key, bad));
    bad.schema = 1;
    const excessive = try a.alloc(u8, max_metadata_bytes + 1);
    defer a.free(excessive);
    @memset(excessive, 'a');
    bad.url = excessive;
    const oversized = try std.json.Stringify.valueAlloc(a, bad, .{});
    defer a.free(oversized);
    try testWrite(dir, key, oversized);
    try std.testing.expect((try load(a, io, root, key, 1024)) == null);
    try std.testing.expectError(error.InvalidRecord, save(a, io, root, key, bad));
}

test "capacity eviction ignores unrelated files" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try tmp.dir.createDir(io, subdir, .default_dir);
    const dir = try tmp.dir.openDir(io, subdir, .{ .iterate = true });
    defer dir.close(io);
    const unrelated = try dir.createFile(io, "keep.json", .{});
    unrelated.close(io);
    for (0..max_entries + 2) |i| {
        var key: [32]u8 = @splat(0);
        key[0] = @intCast(i);
        try testWrite(dir, key, "{}");
    }
    try prune(a, io, root);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |item| {
        if (isCacheName(item.name)) count += 1;
    }
    try std.testing.expectEqual(max_entries, count);
    _ = try dir.statFile(io, "keep.json", .{});
    const key: [32]u8 = @splat(255);
    try save(a, io, root, key, testRecord("published"));
    var entry = (try load(a, io, root, key, 1024)).?;
    defer entry.deinit();
    try std.testing.expectEqualStrings("published", entry.parsed.value.body);
}

test "disk byte budget evicts an oversized sparse record without reading it" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try tmp.dir.createDir(io, subdir, .default_dir);
    const dir = try tmp.dir.openDir(io, subdir, .{});
    defer dir.close(io);
    const key: [32]u8 = @splat(7);
    const name = filename(key);
    const file = try dir.createFile(io, &name, .{});
    try file.setLength(io, max_disk_bytes + 1);
    file.close(io);
    try std.testing.expect((try load(a, io, root, key, std.math.maxInt(usize))) == null);
    try prune(a, io, root);
    try std.testing.expectError(error.FileNotFound, dir.statFile(io, &name, .{}));
}

test "load and prune preserve cancellation instead of treating it as a miss" {
    const Fault = struct {
        fn open(_: ?*anyopaque, _: Dir, _: []const u8, _: Dir.OpenOptions) Dir.OpenError!Dir {
            return error.Canceled;
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.dirOpenDir = Fault.open;
    const io: Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    const key: [32]u8 = @splat(0);
    try std.testing.expectError(error.Canceled, load(std.testing.allocator, io, "unused", key, 1024));
    try std.testing.expectError(error.Canceled, prune(std.testing.allocator, io, "unused"));
    remove(io, "unused", key);
}

test "framed binary size is body plus bounded metadata and replacement is atomic" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const key: [32]u8 = @splat(42);
    const body = try a.alloc(u8, 1024 * 1024);
    defer a.free(body);
    for (body, 0..) |*byte, i| byte.* = @truncate(i);
    try save(a, io, root, key, testRecord(body));
    const dir = try tmp.dir.openDir(io, subdir, .{});
    defer dir.close(io);
    const name = filename(key);
    const before = try dir.openFile(io, &name, .{});
    defer before.close(io);
    const stat = try before.stat(io);
    if (@import("builtin").os.tag != .windows) {
        try std.testing.expectEqual(@as(std.posix.mode_t, 0), stat.permissions.toMode() & 0o077);
        const directory_stat = try tmp.dir.statFile(io, subdir, .{});
        try std.testing.expectEqual(@as(std.posix.mode_t, 0), directory_stat.permissions.toMode() & 0o077);
    }
    try std.testing.expect(stat.size > body.len);
    try std.testing.expect(stat.size < body.len + 2048);
    // An already-open reader retains the complete old inode after replacement.
    try save(a, io, root, key, testRecord("replacement"));
    var tail: [256]u8 = undefined;
    try std.testing.expectEqual(tail.len, try before.readPositionalAll(io, &tail, stat.size - tail.len));
    try std.testing.expectEqualSlices(u8, body[body.len - tail.len ..], &tail);
    var entry = (try load(a, io, root, key, 1024)).?;
    defer entry.deinit();
    try std.testing.expectEqualStrings("replacement", entry.parsed.value.body);
}

test "frame rejects metadata corruption trailing data and hostile lengths before allocation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const key: [32]u8 = @splat(43);
    try save(a, io, root, key, testRecord("body"));
    const dir = try tmp.dir.openDir(io, subdir, .{});
    defer dir.close(io);
    const name = filename(key);
    const original = try dir.readFileAlloc(io, &name, a, .limited(4096));
    defer a.free(original);
    const modified = try a.dupe(u8, original);
    defer a.free(modified);
    const offset = std.mem.indexOf(u8, modified, "max-age=60").?;
    modified[offset + 8] = '9';
    try testWrite(dir, key, modified);
    try std.testing.expect((try load(a, io, root, key, 1024)) == null);
    const trailing = try std.mem.concat(a, u8, &.{ original, "x" });
    defer a.free(trailing);
    try testWrite(dir, key, trailing);
    try std.testing.expect((try load(a, io, root, key, 1024)) == null);
    var no_memory = std.heap.FixedBufferAllocator.init(&.{});
    for ([_]usize{ 0, 8, 12 }) |offset_to_corrupt| {
        @memcpy(modified, original);
        @memset(modified[offset_to_corrupt .. offset_to_corrupt + 4], 255);
        try testWrite(dir, key, modified);
        try std.testing.expect((try load(no_memory.allocator(), io, root, key, std.math.maxInt(usize))) == null);
    }
    try testWrite(dir, key, original);
    try std.testing.expect((try load(no_memory.allocator(), io, root, key, 3)) == null);
    try std.testing.expectError(error.OutOfMemory, load(no_memory.allocator(), io, root, key, 4));
}

test "empty body and nullable metadata roundtrip without legacy JSON compatibility" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const key: [32]u8 = @splat(44);
    var record = testRecord("");
    record.headers = .{ .etag = "", .vary = "Accept", .last_modified = "Wed, 01 Jan 2025 00:00:00 GMT" };
    record.scope = "partition";
    record.stored_at = -1;
    try save(a, io, root, key, record);
    var entry = (try load(a, io, root, key, 0)).?;
    defer entry.deinit();
    try std.testing.expectEqual(@as(usize, 0), entry.parsed.value.body.len);
    try std.testing.expectEqual(@as(i64, -1), entry.parsed.value.stored_at);
    try std.testing.expectEqualStrings("partition", entry.parsed.value.scope);
    try std.testing.expectEqualStrings("", entry.parsed.value.headers.etag.?);
    try std.testing.expect(entry.parsed.value.headers.date == null);
    try std.testing.expectEqualStrings(record.headers.last_modified.?, entry.parsed.value.headers.last_modified.?);
}

test "symlink files and namespace cannot redirect cache reads or writes" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const key: [32]u8 = @splat(45);
    try save(a, io, root, key, testRecord("outside"));
    const dir = try tmp.dir.openDir(io, subdir, .{});
    defer dir.close(io);
    const name = filename(key);
    try dir.rename(&name, tmp.dir, "outside", io);
    try dir.symLink(io, "../outside", &name, .{});
    try std.testing.expect((try load(a, io, root, key, 1024)) == null);
    try prune(a, io, root);
    try std.testing.expectEqual(.sym_link, (try dir.statFile(io, &name, .{ .follow_symlinks = false })).kind);
    try save(a, io, root, key, testRecord("inside"));
    try std.testing.expectEqual(.file, (try dir.statFile(io, &name, .{ .follow_symlinks = false })).kind);
    const outside = try tmp.dir.readFileAlloc(io, "outside", a, .limited(4096));
    defer a.free(outside);
    try std.testing.expect(std.mem.endsWith(u8, outside, "outside"));
    try tmp.dir.rename(subdir, tmp.dir, "actual", io);
    try tmp.dir.symLink(io, "actual", subdir, .{ .is_directory = true });
    try std.testing.expect((try load(a, io, root, key, 1024)) == null);
    if (save(a, io, root, key, testRecord("blocked"))) |_| {
        return error.SymlinkNamespaceAccepted;
    } else |_| {}
}

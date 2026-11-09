const std = @import("std");
const builtin = @import("builtin");
const log = @import("diagnostic_log.zig");
const Io = std.Io;
const testing = std.testing;

fn readLog(dir: Io.Dir, name: []const u8) ![]u8 {
    return dir.readFileAlloc(testing.io, name, testing.allocator, .limited(1024 * 1024));
}
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "diagnostic sanitization strips URL secrets and malformed credential tails" {
    var buffer: [4096]u8 = undefined;
    const cases = [_][]const u8{
        "token=secret-value",                      "PASSWORD : secret-value",                                                "accessToken=secret-value",
        "refresh_token secret-value",              "Authorization: Bearer secret-value",                                     "x-api-key: secret-value",
        "{\"password\":\"secret-value",            "https://alice:secret-value@example.com/a?sig=secret-value#secret-value", "https://alice:secret-value",
        "https://alice:secret-value @example.com", "https://example.com/a?sig=secret-value\nsecret-value",                   "https://example.com/path/password/secret-value",
    };
    for (cases) |raw| {
        const result = log.sanitize(&buffer, raw);
        try testing.expect(!contains(result, "secret-value"));
        try testing.expect(!contains(result, "\n"));
    }
    try testing.expectEqualStrings("download https://example.com/a[query/fragment-removed]", log.sanitize(&buffer, "download https://alice:secret@example.com/a?sig=abc#def"));
    try testing.expectEqualStrings("a\\x0ab\\x1bc\\x7f", log.sanitize(&buffer, "a\nb\x1bc\x7f"));
    const formatted = try std.fmt.bufPrint(&buffer, "{f}", .{log.url("https://alice:secret@example.com/a?sig=hidden")});
    try testing.expectEqualStrings("https://example.com/a[query/fragment-removed]", formatted);
    var again: [4096]u8 = undefined;
    try testing.expectEqualStrings(formatted, log.sanitize(&again, formatted));
    try testing.expectEqualStrings("安装完成 file=枪战地图", log.sanitize(&buffer, "安装完成 file=枪战地图"));
    for ([_][]const u8{ "Cookie=session-secret", "client_secret=client-secret", "api-key=api-secret" }) |raw| {
        try testing.expectEqualStrings("[REDACTED]", log.sanitize(&buffer, raw));
    }
    var tiny: [32]u8 = undefined;
    const bounded = log.sanitize(&tiny, "a very long harmless prefix password=secret-value");
    try testing.expect(bounded.len <= tiny.len);
    try testing.expect(std.mem.endsWith(u8, bounded, log.truncation_marker));
    try testing.expect(!contains(bounded, "secret-value"));
}

test "diagnostic reopen rotates only owned files and applies private permissions" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var logger: log.Logger = .{};
    defer logger.stop();
    try logger.startAt(io, tmp.dir, .{});
    logger.write(.info, .launcher, "first session", .{});
    try tmp.dir.writeFile(io, .{ .sub_path = ".vela/logs/keep.txt", .data = "unrelated" });
    logger.stop();
    logger.write(.info, .launcher, "after stop", .{});
    logger.stop();
    try logger.startAt(io, tmp.dir, .{});
    logger.write(.err, .launcher, "second session", .{});
    logger.stop();
    const previous = try readLog(tmp.dir, ".vela/logs/launcher.log.1");
    defer testing.allocator.free(previous);
    const current = try readLog(tmp.dir, ".vela/logs/launcher.log");
    defer testing.allocator.free(current);
    const unrelated = try readLog(tmp.dir, ".vela/logs/keep.txt");
    defer testing.allocator.free(unrelated);
    try testing.expect(contains(previous, "first session"));
    try testing.expect(!contains(previous, "after stop"));
    try testing.expect(contains(current, "err launcher: second session"));
    try testing.expect(std.mem.startsWith(u8, current, "epoch_ms="));
    try testing.expectEqualStrings("unrelated", unrelated);
    if (builtin.os.tag != .windows) {
        for ([_][]const u8{ ".vela/logs/launcher.log", ".vela/logs/launcher.log.1" }) |name| {
            const stat = try tmp.dir.statFile(io, name, .{});
            try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
        }
        const stat = try tmp.dir.statFile(io, ".vela/logs", .{});
        try testing.expectEqual(@as(u32, 0o700), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
    }
}

test "diagnostic tiny rotation remains bounded and oversized input is wholly dropped" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var logger: log.Logger = .{};
    defer logger.stop();
    try logger.startAt(testing.io, tmp.dir, .{ .max_file_bytes = 256 });
    const long: [600]u8 = @splat('z');
    for (0..20) |i| logger.write(.info, .test_scope, "{d}: {s}", .{ i, &long });
    for ([_][]const u8{ "launcher.log", "launcher.log.1", "launcher.log.2", "launcher.log.3" }) |name| {
        const bytes = try logger.dir.?.readFileAlloc(testing.io, name, testing.allocator, .limited(257));
        defer testing.allocator.free(bytes);
        try testing.expect(bytes.len <= 256);
        try testing.expect(std.mem.endsWith(u8, bytes, "\n"));
        try testing.expect(contains(bytes, log.truncation_marker));
    }
    const huge: [log.max_message_bytes + 1]u8 = @splat('s');
    logger.write(.info, .test_scope, "https://{s}:secret@example.com", .{&huge});
    logger.stop();
    const bytes = try readLog(tmp.dir, ".vela/logs/launcher.log");
    defer testing.allocator.free(bytes);
    try testing.expect(!contains(bytes, "ssss"));
    try testing.expect(!contains(bytes, "secret"));
    try testing.expect(contains(bytes, "message omitted"));
}

fn worker(logger: *log.Logger, id: usize) void {
    for (0..50) |i| logger.write(.info, .worker, "id={d} entry={d} complete", .{ id, i });
}
test "diagnostic concurrent writers produce complete unique records" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var logger: log.Logger = .{};
    defer logger.stop();
    try logger.startAt(testing.io, tmp.dir, .{});
    var threads: [4]std.Thread = undefined;
    var started: usize = 0;
    {
        defer for (threads[0..started]) |thread| thread.join();
        for (&threads, 0..) |*thread, id| {
            thread.* = try std.Thread.spawn(.{}, worker, .{ &logger, id });
            started += 1;
        }
    }
    logger.stop();
    const bytes = try readLog(tmp.dir, ".vela/logs/launcher.log");
    defer testing.allocator.free(bytes);
    var records = std.mem.tokenizeScalar(u8, bytes, '\n');
    var count: usize = 0;
    while (records.next()) |record| {
        try testing.expect(std.mem.startsWith(u8, record, "epoch_ms="));
        try testing.expect(std.mem.endsWith(u8, record, " complete"));
        count += 1;
    }
    try testing.expectEqual(@as(usize, 200), count);
    var buffer: [80]u8 = undefined;
    for (0..4) |id| for (0..50) |i| {
        const needle = try std.fmt.bufPrint(&buffer, "id={d} entry={d} complete\n", .{ id, i });
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, needle));
    };
}

const FaultIo = struct {
    var active: ?*FaultIo = null;
    real: Io = testing.io,
    vtable: Io.VTable = undefined,
    fail_create: bool = false,
    fail_write: bool = false,
    partial_written: bool = false,
    syncs: usize = 0,
    fn start(self: *FaultIo) Io {
        std.debug.assert(active == null);
        active = self;
        self.vtable = self.real.vtable.*;
        self.vtable.dirCreateFile = create;
        self.vtable.fileWritePositional = write;
        self.vtable.fileSync = sync;
        return .{ .userdata = self.real.userdata, .vtable = &self.vtable };
    }
    fn create(ctx: ?*anyopaque, dir: Io.Dir, path: []const u8, options: Io.Dir.CreateFileOptions) Io.File.OpenError!Io.File {
        const self = active.?;
        if (self.fail_create) return error.AccessDenied;
        return self.real.vtable.dirCreateFile(ctx, dir, path, options);
    }
    fn write(ctx: ?*anyopaque, file: Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) Io.File.WritePositionalError!usize {
        const self = active.?;
        if (self.fail_write) {
            if (!self.partial_written) {
                self.partial_written = true;
                return self.real.vtable.fileWritePositional(ctx, file, "", &.{"partial"}, 1, offset);
            }
            return error.InputOutput;
        }
        return self.real.vtable.fileWritePositional(ctx, file, header, data, splat, offset);
    }
    fn sync(ctx: ?*anyopaque, file: Io.File) Io.File.SyncError!void {
        const self = active.?;
        self.syncs += 1;
        return self.real.vtable.fileSync(ctx, file);
    }
};

test "diagnostic initialization failure is retryable and short write disables safely" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fault: FaultIo = .{ .fail_create = true };
    const io = fault.start();
    defer FaultIo.active = null;
    var logger: log.Logger = .{};
    defer logger.stop();
    try testing.expectError(error.AccessDenied, logger.startAt(io, tmp.dir, .{}));
    logger.write(.info, .test_scope, "inactive", .{});
    try testing.expect(logger.io == null);
    fault.fail_create = false;
    try logger.startAt(io, tmp.dir, .{});
    const before_info = fault.syncs;
    logger.write(.info, .test_scope, "preserved", .{});
    try testing.expectEqual(before_info, fault.syncs);
    logger.write(.err, .test_scope, "durable", .{});
    try testing.expectEqual(before_info + 1, fault.syncs);
    const before = try readLog(tmp.dir, ".vela/logs/launcher.log");
    defer testing.allocator.free(before);
    fault.fail_write = true;
    logger.write(.info, .test_scope, "failed write", .{});
    try testing.expect(logger.failed);
    logger.write(.info, .test_scope, "never appended", .{});
    logger.stop();
    const after = try readLog(tmp.dir, ".vela/logs/launcher.log");
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "diagnostic refuses unsafe owned entries before rotating existing log" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var logger: log.Logger = .{};
    defer logger.stop();
    try logger.startAt(testing.io, tmp.dir, .{});
    logger.write(.info, .test_scope, "preserved", .{});
    logger.stop();
    try tmp.dir.createDir(testing.io, ".vela/logs/launcher.log.2", .default_dir);
    try testing.expectError(error.UnsafeFileType, logger.startAt(testing.io, tmp.dir, .{}));
    const bytes = try readLog(tmp.dir, ".vela/logs/launcher.log");
    defer testing.allocator.free(bytes);
    try testing.expect(contains(bytes, "preserved"));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, ".vela/logs/launcher.log.1", .{}));
}

test "diagnostic symlinks cannot redirect logs or rotation into another file" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "outside", .data = "untouched" });
    var logger: log.Logger = .{};
    defer logger.stop();
    try logger.startAt(io, tmp.dir, .{});
    logger.stop();
    try tmp.dir.symLink(io, "../../outside", ".vela/logs/launcher.log.3", .{});
    try testing.expectError(error.UnsafeFileType, logger.startAt(io, tmp.dir, .{}));
    const bytes = try readLog(tmp.dir, "outside");
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("untouched", bytes);
    var linked = testing.tmpDir(.{ .iterate = true });
    defer linked.cleanup();
    try linked.dir.createDir(io, "elsewhere", .default_dir);
    try linked.dir.symLink(io, "elsewhere", ".vela", .{ .is_directory = true });
    try testing.expectError(error.UnsafeFileType, logger.startAt(io, linked.dir, .{}));
}

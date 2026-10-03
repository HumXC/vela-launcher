const std = @import("std");
const A = std.mem.Allocator;
const Io = std.Io;
pub const Cancel = ?*const std.atomic.Value(bool);

pub fn canceled(cancel: Cancel) !void {
    if (cancel) |flag| if (flag.load(.acquire)) return error.Canceled;
}

pub fn component(name: []const u8) !void {
    if (name.len == 0 or name.len > 255 or !std.unicode.utf8ValidateSlice(name)) return error.UnsafePath;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.UnsafePath;
    if (name[name.len - 1] == '.' or name[name.len - 1] == ' ') return error.UnsafePath;
    var it = std.unicode.Utf8View.initUnchecked(name).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return error.UnsafePath;
        if (cp < 128 and std.mem.indexOfScalar(u8, "<>:\"/\\|?*", @intCast(cp)) != null) return error.UnsafePath;
    }
    const stem = std.mem.trimEnd(u8, name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len], " ");
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "CLOCK$", "CONIN$", "CONOUT$" }) |reserved| {
        if (std.ascii.eqlIgnoreCase(stem, reserved)) return error.UnsafePath;
    }
    if (stem.len >= 4 and (std.ascii.eqlIgnoreCase(stem[0..3], "COM") or std.ascii.eqlIgnoreCase(stem[0..3], "LPT"))) {
        if (stem.len == 4 and stem[3] >= '1' and stem[3] <= '9') return error.UnsafePath;
        if (stem.len == 5 and stem[3] == 0xc2 and (stem[4] == 0xb9 or stem[4] == 0xb2 or stem[4] == 0xb3)) return error.UnsafePath;
    }
}

pub fn openParent(io: Io, path: []const u8, create: bool) !Io.Dir {
    if (path.len == 0) return error.UnsafePath;
    try component(std.fs.path.basename(path));
    const parent = std.fs.path.dirname(path) orelse ".";
    var parts = std.fs.path.componentIterator(parent);
    const root = parts.root() orelse ".";
    if (parts.root() != null and !std.fs.path.isAbsolute(parent)) return error.UnsafePath;
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .follow_symlinks = false });
    errdefer dir.close(io);
    while (parts.next()) |entry| {
        const part = entry.name;
        if (std.mem.eql(u8, part, ".")) continue;
        try component(part);
        if (create) dir.createDir(io, part, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const next = try dir.openDir(io, part, .{ .follow_symlinks = false });
        dir.close(io);
        dir = next;
    }
    return dir;
}

pub fn openFile(io: Io, path: []const u8) !Io.File {
    const parent = try openParent(io, path, false);
    defer parent.close(io);
    return parent.openFile(io, std.fs.path.basename(path), .{ .follow_symlinks = false, .allow_directory = false });
}

pub fn read(a: A, io: Io, path: []const u8, max_bytes: usize, cancel: Cancel) ![]u8 {
    try canceled(cancel);
    const file = try openFile(io, path);
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.UnsafePath;
    if (stat.size > max_bytes) return error.MetadataTooLarge;
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(a);
    var buffer: [16384]u8 = undefined;
    while (true) {
        try canceled(cancel);
        const n = file.readStreaming(io, &.{buffer[0..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try canceled(cancel);
        if (n == 0) break;
        if (n > max_bytes - bytes.items.len) return error.MetadataTooLarge;
        try bytes.appendSlice(a, buffer[0..n]);
    }
    try canceled(cancel);
    return bytes.toOwnedSlice(a);
}

pub fn writeAtomic(a: A, io: Io, path: []const u8, bytes: []const u8, cancel: Cancel) !void {
    try canceled(cancel);
    const parent = try openParent(io, path, true);
    defer parent.close(io);
    var random: [16]u8 = undefined;
    var temporary: ?[]u8 = null;
    var file: Io.File = undefined;
    for (0..32) |_| {
        try canceled(cancel);
        Io.random(io, &random);
        const name = try std.fmt.allocPrint(a, ".vela-{s}.tmp", .{std.fmt.bytesToHex(random, .lower)});
        file = parent.createFile(io, name, .{ .exclusive = true }) catch |err| {
            a.free(name);
            if (err == error.PathAlreadyExists) continue;
            return err;
        };
        temporary = name;
        break;
    }
    const name = temporary orelse return error.TemporaryFileCollision;
    defer a.free(name);
    defer file.close(io);
    var committed = false;
    defer if (!committed) parent.deleteFile(io, name) catch {};
    var offset: usize = 0;
    while (offset < bytes.len) {
        try canceled(cancel);
        const end = offset + @min(bytes.len - offset, 16384);
        try file.writeStreamingAll(io, bytes[offset..end]);
        offset = end;
    }
    try file.sync(io);
    const destination = parent.statFile(io, std.fs.path.basename(path), .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (destination) |stat| if (stat.kind != .file) return error.UnsafePath;
    try canceled(cancel);
    try parent.rename(name, parent, std.fs.path.basename(path), io);
    committed = true;
}

test "safe filesystem rejects portable reserved components" {
    for ([_][]const u8{ "", ".", "..", "CON", "con.txt", "LPT1", "COM9", "x/../y", "trailing.", "trailing ", "a:b" }) |name| {
        try std.testing.expectError(error.UnsafePath, component(name));
    }
    try component("Minecraft 1.21+Fabric");
    const long = [_]u8{'a'} ** 256;
    try std.testing.expectError(error.UnsafePath, component(&long));
}

test "safe filesystem bounded read atomic replacement cancellation and nofollow" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "nested", "data.json" });
    defer a.free(path);
    try writeAtomic(a, io, path, "original", null);
    try writeAtomic(a, io, path, "replaced", null);
    const bytes = try read(a, io, path, 8, null);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("replaced", bytes);
    try std.testing.expectError(error.MetadataTooLarge, read(a, io, path, 7, null));
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Canceled, writeAtomic(a, io, path, "bad", &cancel));
    try std.testing.expectError(error.Canceled, read(a, io, path, 8, &cancel));
    try tmp.dir.symLink(io, "nested", "link", .{ .is_directory = true });
    const linked = try std.fs.path.join(a, &.{ root, "link", "data.json" });
    defer a.free(linked);
    if (read(a, io, linked, 8, null)) |unexpected| {
        a.free(unexpected);
        return error.TestUnexpectedResult;
    } else |_| {}
    if (writeAtomic(a, io, linked, "bad", null)) |_| return error.TestUnexpectedResult else |_| {}
    try tmp.dir.symLink(io, "nested/data.json", "file-link", .{});
    const file_link = try std.fs.path.join(a, &.{ root, "file-link" });
    defer a.free(file_link);
    try std.testing.expectError(error.UnsafePath, writeAtomic(a, io, file_link, "bad", null));
    const directory_path = try std.fs.path.join(a, &.{ root, "nested" });
    defer a.free(directory_path);
    try std.testing.expectError(error.UnsafePath, writeAtomic(a, io, directory_path, "bad", null));
    if (read(a, io, file_link, 8, null)) |unexpected| {
        a.free(unexpected);
        return error.TestUnexpectedResult;
    } else |_| {}
    const unchanged = try read(a, io, path, 8, null);
    defer a.free(unchanged);
    try std.testing.expectEqualStrings("replaced", unchanged);
}

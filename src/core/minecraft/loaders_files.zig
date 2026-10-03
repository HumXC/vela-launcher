//! Private loader staging files. All ancestors are opened no-follow; publication
//! is owned by loader_install and uses non-replacing directory rename.
const std = @import("std");
const c = @import("loaders_common.zig");
const tree = @import("../worlds_tree.zig");
const safe = @import("../safe_archive.zig");
const A = std.mem.Allocator;
const Dir = std.Io.Dir;

pub fn directory(io: std.Io, path: []const u8, create: bool) !Dir {
    try c.stageRoot(path);
    if (!create) return tree.openAbsolute(io, path);
    const root_len: usize = if (@import("builtin").os.tag == .windows) std.fs.path.diskDesignator(path).len + 1 else 1;
    var dir = try tree.openAbsolute(io, path[0..root_len]);
    errdefer dir.close(io);
    var parts = std.mem.splitScalar(u8, path[root_len..], '/');
    while (parts.next()) |part| {
        const next = try tree.child(io, dir, part, true);
        dir.close(io);
        dir = next;
    }
    return dir;
}

pub fn read(a: A, io: std.Io, path: []const u8, max: usize, control: c.Control) ![]u8 {
    try control.check();
    try c.stageRoot(path);
    const parent = try directory(io, std.fs.path.dirname(path) orelse return error.UnsafePath, false);
    defer parent.close(io);
    const bytes = try tree.readBounded(a, io, parent, std.fs.path.basename(path), max);
    errdefer a.free(bytes);
    try control.check();
    return bytes;
}

pub fn write(io: std.Io, path: []const u8, bytes: []const u8, control: c.Control) !void {
    try control.check();
    try c.stageRoot(path);
    const parent = try directory(io, std.fs.path.dirname(path) orelse return error.UnsafePath, true);
    defer parent.close(io);
    const file = try parent.createFile(io, std.fs.path.basename(path), .{ .exclusive = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try control.check();
    try file.sync(io);
    try tree.syncDir(io, parent);
}

pub fn copy(io: std.Io, source: []const u8, destination: []const u8, max: u64, control: c.Control) !void {
    try control.check();
    try c.stageRoot(source);
    try c.stageRoot(destination);
    const src_dir = try directory(io, std.fs.path.dirname(source) orelse return error.UnsafePath, false);
    defer src_dir.close(io);
    const src = try src_dir.openFile(io, std.fs.path.basename(source), .{ .follow_symlinks = false, .allow_directory = false });
    defer src.close(io);
    const before = try src.stat(io);
    if (before.kind != .file) return error.NotRegularFile;
    if (before.size > max) return error.FileTooLarge;
    const dst_dir = try directory(io, std.fs.path.dirname(destination) orelse return error.UnsafePath, true);
    defer dst_dir.close(io);
    const dst = try dst_dir.createFile(io, std.fs.path.basename(destination), .{ .exclusive = true });
    defer dst.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < before.size) {
        try control.check();
        const want: usize = @intCast(@min(buffer.len, before.size - offset));
        const n = try src.readPositional(io, &.{buffer[0..want]}, offset);
        if (n == 0) return error.FileChanged;
        try dst.writePositionalAll(io, buffer[0..n], offset);
        offset += n;
    }
    const after = try src.stat(io);
    if (after.size != before.size or after.mtime.nanoseconds != before.mtime.nanoseconds or after.ctime.nanoseconds != before.ctime.nanoseconds) return error.FileChanged;
    try dst.setPermissions(io, before.permissions);
    try dst.sync(io);
    try tree.syncDir(io, dst_dir);
    try control.check();
}

pub fn verify(io: std.Io, path: []const u8, expected: c.m.Sha1, size: ?u64, max: u64, control: c.Control) !void {
    try control.check();
    try c.stageRoot(path);
    const parent = try directory(io, std.fs.path.dirname(path) orelse return error.UnsafePath, false);
    defer parent.close(io);
    const file = try parent.openFile(io, std.fs.path.basename(path), .{ .follow_symlinks = false, .allow_directory = false });
    defer file.close(io);
    const before = try file.stat(io);
    if (before.kind != .file) return error.NotRegularFile;
    if (before.size > max) return error.FileTooLarge;
    if (size) |n| if (n != before.size) return error.SizeMismatch;
    var hash = std.crypto.hash.Sha1.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < before.size) {
        try control.check();
        const want: usize = @intCast(@min(buffer.len, before.size - offset));
        const n = try file.readPositional(io, &.{buffer[0..want]}, offset);
        if (n == 0) return error.FileChanged;
        hash.update(buffer[0..n]);
        offset += n;
    }
    const after = try file.stat(io);
    if (after.size != before.size or after.mtime.nanoseconds != before.mtime.nanoseconds or after.ctime.nanoseconds != before.ctime.nanoseconds) return error.FileChanged;
    var actual: c.m.Sha1 = undefined;
    hash.final(&actual);
    if (!std.mem.eql(u8, &actual, &expected)) return error.ChecksumMismatch;
    try control.check();
}

pub fn extract(a: A, io: std.Io, archive_path: []const u8, destination: []const u8, control: c.Control) !void {
    try control.check();
    // Ancestor capability validation also covers safe_archive's path-based source.
    const source_parent = try directory(io, std.fs.path.dirname(archive_path) orelse return error.UnsafePath, false);
    defer source_parent.close(io);
    const stat = try source_parent.statFile(io, std.fs.path.basename(archive_path), .{ .follow_symlinks = false });
    if (stat.kind != .file) return error.NotRegularFile;
    const dir = try directory(io, destination, true);
    defer dir.close(io);
    var result = try @import("loaders_archive.zig").extractInstaller(safe, a, io, archive_path, dir, .{ .max_archive_bytes = 512 * 1024 * 1024, .max_total_bytes = 1024 * 1024 * 1024, .max_file_bytes = 512 * 1024 * 1024 }, control);
    defer result.deinit(a);
    try tree.syncDir(io, dir);
}

/// JAR main-section continuation lines are unfolded per the manifest spec:
/// https://docs.oracle.com/en/java/javase/21/docs/specs/jar/jar.html
pub fn manifestClass(a: A, bytes: []const u8) ![]u8 {
    if (bytes.len > 64 * 1024 or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidJarManifest;
    var value: std.ArrayList(u8) = .empty;
    defer value.deinit(a);
    var found = false;
    var collecting = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) break;
        if (line[0] == ' ') {
            if (collecting) try value.appendSlice(a, line[1..]);
        } else {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidJarManifest;
            if (colon + 1 >= line.len or line[colon + 1] != ' ') return error.InvalidJarManifest;
            collecting = std.ascii.eqlIgnoreCase(line[0..colon], "Main-Class");
            if (collecting) {
                if (found) return error.DuplicateMainClass;
                found = true;
                try value.appendSlice(a, line[colon + 2 ..]);
            }
        }
        if (value.items.len > 512) return error.InvalidJarManifest;
    }
    if (!found or value.items.len == 0) return error.MissingMainClass;
    try @import("loaders_execute.zig").trustedClass(value.items);
    return value.toOwnedSlice(a);
}

pub fn mainClass(a: A, io: std.Io, jar: []const u8, scratch_root: []const u8, control: c.Control) ![]u8 {
    var random: [16]u8 = undefined;
    io.random(&random);
    const name = try std.fmt.allocPrint(a, "manifest-{s}", .{std.fmt.bytesToHex(&random, .lower)});
    defer a.free(name);
    const path = try c.join(a, scratch_root, name);
    defer a.free(path);
    const root = try directory(io, scratch_root, true);
    defer root.close(io);
    defer {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        root.deleteTree(io, name) catch {};
    }
    try extract(a, io, jar, path, control);
    const manifest = try c.join(a, path, "META-INF/MANIFEST.MF");
    defer a.free(manifest);
    const bytes = try read(a, io, manifest, 64 * 1024, control);
    defer a.free(bytes);
    return manifestClass(a, bytes);
}

test "manifest main class unfolds and rejects duplicate or untrusted classes" {
    const a = std.testing.allocator;
    const class = try manifestClass(a, "Manifest-Version: 1.0\r\nMain-Class: net.minecraftforge.\r\n installertools.ConsoleTool\r\n\r\nName: ignored\r\n");
    defer a.free(class);
    try std.testing.expectEqualStrings("net.minecraftforge.installertools.ConsoleTool", class);
    try std.testing.expectError(error.DuplicateMainClass, manifestClass(a, "Main-Class: net.minecraftforge.A\nMain-Class: net.minecraftforge.B\n"));
    try std.testing.expectError(error.UntrustedProcessorClass, manifestClass(a, "Main-Class: arbitrary.Code\n"));
    try std.testing.expectError(error.MissingMainClass, manifestClass(a, "Manifest-Version: 1.0\n\nMain-Class: net.minecraftforge.A\n"));
}

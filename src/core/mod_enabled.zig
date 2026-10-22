//! Rename one local mod without reading or parsing any archive contents.
const std = @import("std");
const fs = @import("content_fs.zig");
const mod_path = @import("mod_path.zig");

pub const Rename = struct { source: []const u8, target: []const u8, changed: bool };
pub fn setEnabled(a: std.mem.Allocator, io: std.Io, instance: std.Io.Dir, path: []const u8, enabled: bool) !Rename {
    if (!std.mem.startsWith(u8, path, "mods/")) return error.UnsafePath;
    const source = path["mods/".len..];
    if (!fs.safeComponent(source)) return error.UnsafePath;
    if (!mod_path.isMod(source)) return error.UnsupportedEnabledState;
    const canonical = mod_path.logical(source);
    const mods = try fs.child(instance, io, "mods", false, false);
    defer mods.close(io);
    const stat = try fs.inspectEntry(mods, io, source) orelse return error.FileNotFound;
    if (stat.kind != .file) return error.UnsafeFileType;
    const target = if (enabled) try a.dupe(u8, canonical) else try std.fmt.allocPrint(a, "{s}.disabled", .{canonical});
    defer a.free(target);
    const owned_source = try a.dupe(u8, path);
    errdefer a.free(owned_source);
    const owned_target = try std.fmt.allocPrint(a, "mods/{s}", .{target});
    errdefer a.free(owned_target);
    const result: Rename = .{ .source = owned_source, .target = owned_target, .changed = !std.mem.eql(u8, source, target) };
    if (!result.changed) return result;
    if (try fs.inspectEntry(mods, io, target) != null) return error.PathAlreadyExists;
    try mods.renamePreserve(source, mods, target, io);
    return result;
}

test "mod enable disable only renames even when archive bytes are not parseable" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "mods", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/local.jar", .data = "unparsed mod bytes" });
    const before = try tmp.dir.statFile(io, "mods/local.jar", .{});
    const off = try setEnabled(a, io, tmp.dir, "mods/local.jar", false);
    defer {
        a.free(off.source);
        a.free(off.target);
    }
    try std.testing.expect(off.changed);
    try std.testing.expectEqualStrings("mods/local.jar.disabled", off.target);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "mods/local.jar", .{}));
    const after = try tmp.dir.statFile(io, off.target, .{});
    try std.testing.expectEqual(before.size, after.size);
    try std.testing.expectEqual(before.mtime, after.mtime);
    const on = try setEnabled(a, io, tmp.dir, off.target, true);
    defer {
        a.free(on.source);
        a.free(on.target);
    }
    const bytes = try tmp.dir.readFileAlloc(io, on.target, a, .limited(100));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("unparsed mod bytes", bytes);
}

test "mod rename preserves a destination collision and rejects non-mod paths" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "mods", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/local.jar", .data = "enabled" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/local.jar.disabled", .data = "disabled" });
    try std.testing.expectError(error.PathAlreadyExists, setEnabled(a, io, tmp.dir, "mods/local.jar", false));
    for ([_][]const u8{ "../local.jar", "mods/../local.jar", "mods/nested/local.jar", "resourcepacks/local.jar" }) |path| try std.testing.expectError(error.UnsafePath, setEnabled(a, io, tmp.dir, path, false));
    const bytes = try tmp.dir.readFileAlloc(io, "mods/local.jar.disabled", a, .limited(100));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("disabled", bytes);
}

test "uppercase and mixed JAR rename preserves spelling bytes identity and collisions" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "mods", .default_dir);
    const payload = "unparsed mod bytes\x00\xff";
    for ([_][]const u8{ "mods/Example.JAR", "mods/Mixed.JaR" }) |path| {
        const disabled_path = try std.fmt.allocPrint(a, "{s}.disabled", .{path});
        defer a.free(disabled_path);
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = payload });
        const before = try tmp.dir.statFile(io, path, .{});
        const off = try setEnabled(a, io, tmp.dir, path, false);
        defer {
            a.free(off.source);
            a.free(off.target);
        }
        try std.testing.expect(off.changed);
        try std.testing.expectEqualStrings(path, off.source);
        try std.testing.expectEqualStrings(disabled_path, off.target);
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, path, .{}));
        const after = try tmp.dir.statFile(io, off.target, .{});
        try std.testing.expectEqual(before.inode, after.inode);
        try std.testing.expectEqual(before.size, after.size);
        try std.testing.expectEqual(before.mtime, after.mtime);
        const disabled_bytes = try tmp.dir.readFileAlloc(io, off.target, a, .limited(100));
        defer a.free(disabled_bytes);
        try std.testing.expectEqualStrings(payload, disabled_bytes);
        const still_off = try setEnabled(a, io, tmp.dir, off.target, false);
        defer {
            a.free(still_off.source);
            a.free(still_off.target);
        }
        try std.testing.expect(!still_off.changed);
        try std.testing.expectEqualStrings(disabled_path, still_off.source);
        try std.testing.expectEqualStrings(disabled_path, still_off.target);
        const on = try setEnabled(a, io, tmp.dir, off.target, true);
        defer {
            a.free(on.source);
            a.free(on.target);
        }
        try std.testing.expect(on.changed);
        try std.testing.expectEqualStrings(disabled_path, on.source);
        try std.testing.expectEqualStrings(path, on.target);
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, disabled_path, .{}));
        const bytes = try tmp.dir.readFileAlloc(io, on.target, a, .limited(100));
        defer a.free(bytes);
        try std.testing.expectEqualStrings(payload, bytes);
        try tmp.dir.writeFile(io, .{ .sub_path = disabled_path, .data = "collision" });
        try std.testing.expectError(error.PathAlreadyExists, setEnabled(a, io, tmp.dir, path, false));
        try std.testing.expectError(error.PathAlreadyExists, setEnabled(a, io, tmp.dir, disabled_path, true));
        const retained = try tmp.dir.readFileAlloc(io, disabled_path, a, .limited(100));
        defer a.free(retained);
        try std.testing.expectEqualStrings("collision", retained);
        const original = try tmp.dir.readFileAlloc(io, path, a, .limited(100));
        defer a.free(original);
        try std.testing.expectEqualStrings(payload, original);
    }
    for ([_][]const u8{ "mods/Example.JAR.DISABLED", "mods/notes.disabled", "mods/pack.zip", "mods/Example.JAR.disabled.disabled" }) |path|
        try std.testing.expectError(error.UnsupportedEnabledState, setEnabled(a, io, tmp.dir, path, false));
}

test "uppercase JAR rename rejects symlink sources destinations and mods directory" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "mods", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "outside", .data = "untouched" });
    try tmp.dir.symLink(io, "../outside", "mods/Link.JAR", .{});
    try std.testing.expectError(error.UnsafeFileType, setEnabled(a, io, tmp.dir, "mods/Link.JAR", false));
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/Target.JAR", .data = "enabled" });
    try tmp.dir.symLink(io, "../outside", "mods/Target.JAR.disabled", .{});
    try std.testing.expectError(error.UnsafeFileType, setEnabled(a, io, tmp.dir, "mods/Target.JAR", false));
    try tmp.dir.createDir(io, "mods/Directory.JAR", .default_dir);
    try std.testing.expectError(error.UnsafeFileType, setEnabled(a, io, tmp.dir, "mods/Directory.JAR", false));
    const bytes = try tmp.dir.readFileAlloc(io, "outside", a, .limited(100));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("untouched", bytes);
    var linked = std.testing.tmpDir(.{ .iterate = true });
    defer linked.cleanup();
    try linked.dir.createDir(io, "real-mods", .default_dir);
    try linked.dir.symLink(io, "real-mods", "mods", .{ .is_directory = true });
    try std.testing.expectError(error.UnsafeFileType, setEnabled(a, io, linked.dir, "mods/Example.JAR", false));
}

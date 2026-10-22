//! Physical resource state is observed, never persisted in ownership receipts.
const std = @import("std");
const manifest = @import("content_manifest.zig");
const fs = @import("content_fs.zig");

pub fn observe(a: std.mem.Allocator, io: std.Io, game: ?std.Io.Dir, files: []const manifest.ManagedFile) ![]const manifest.ManagedFile {
    const result = try a.dupe(manifest.ManagedFile, files);
    errdefer a.free(result);
    for (result) |*file| {
        file.enabled = true;
        if (game) |dir| if (manifest.toggleable(file.*)) {
            file.enabled = try enabled(io, dir, file.path);
        };
    }
    return result;
}

fn enabled(io: std.Io, game: std.Io.Dir, path: []const u8) !bool {
    const parent = fs.parent(game, io, path, false) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return err,
    };
    defer parent.deinit(io);
    var buffer: [manifest.max_path_bytes]u8 = undefined;
    const disabled = try std.fmt.bufPrint(&buffer, "{s}.disabled", .{parent.name});
    const ordinary = try fs.inspectEntry(parent.dir, io, parent.name);
    const inactive = try fs.inspectEntry(parent.dir, io, disabled);
    if (ordinary) |stat| if (stat.kind != .file) return error.UnsafeFileType;
    if (inactive) |stat| if (stat.kind != .file) return error.UnsafeFileType;
    if (ordinary != null and inactive != null) return error.PathAlreadyExists;
    return inactive == null;
}

fn record(path: []const u8) manifest.ManagedFile {
    return .{ .path = path, .provider = .modrinth, .project_id = "project", .version_id = "version", .hashes = .{ .sha1 = "0000000000000000000000000000000000000000" }, .identity_provenance = .official_file };
}
test "physical filenames determine enabled state without reading archive contents" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "mods", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/Active.JAR", .data = "not a jar" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/Inactive.JAR.disabled", .data = "not a jar either" });
    var active = record("mods/Active.JAR");
    active.enabled = false;
    const files = try observe(a, io, tmp.dir, &.{ active, record("mods/Inactive.JAR"), record("mods/missing.jar") });
    defer a.free(files);
    try std.testing.expect(files[0].enabled);
    try std.testing.expect(!files[1].enabled);
    try std.testing.expect(files[2].enabled);
}
test "physical counterpart conflicts are not resolved by receipt flags" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "mods", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/a.jar", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/a.jar.disabled", .data = "b" });
    try std.testing.expectError(error.PathAlreadyExists, observe(std.testing.allocator, io, tmp.dir, &.{record("mods/a.jar")}));
}

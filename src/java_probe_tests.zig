//! Root at src/ so UI Java probing can import the shared core runtime.
test {
    _ = @import("application/java_manager.zig");
}

const std = @import("std");
const java = @import("application/java_manager.zig");
const architecture = @import("core/java_runtime.zig");

test "automatic Java selection requires exact major and host architecture across reload" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var manager = try java.Manager.init(a, io, root);
    defer manager.deinit();
    const foreign: architecture.Architecture = if (architecture.host() == .aarch64) .x86_64 else .aarch64;
    const paths = [_][]const u8{
        try std.fs.path.join(a, &.{ root, "foreign-java" }),
        try std.fs.path.join(a, &.{ root, "wrong-major-java" }),
        try std.fs.path.join(a, &.{ root, "host-java" }),
    };
    defer for (paths) |path| a.free(path);
    try manager.addDownloaded(.{ .path = paths[0], .major = 17, .vendor = "Foreign", .architecture = foreign });
    try manager.addDownloaded(.{ .path = paths[1], .major = 21, .vendor = "Newer", .architecture = architecture.host() });
    try std.testing.expect(manager.resolve(17) == null);
    try manager.addDownloaded(.{ .path = paths[2], .major = 17, .vendor = "Host", .architecture = architecture.host() });
    try std.testing.expectEqualStrings(paths[2], manager.resolve(17).?.path);
    var loaded = try java.Manager.init(a, io, root);
    defer loaded.deinit();
    try std.testing.expectEqualStrings(paths[2], loaded.resolve(17).?.path);
    try loaded.hide(paths[2]);
    try std.testing.expect(loaded.resolve(17) == null);
    try loaded.unhide(paths[2]);
    try std.testing.expectEqualStrings(paths[2], loaded.resolve(17).?.path);
    try loaded.remove(paths[2]);
    try std.testing.expect(loaded.resolve(17) == null);
}

const std = @import("std");
const files = @import("core/minecraft/loaders_files.zig");
const common = @import("core/minecraft/loaders_common.zig");
fn now(_: ?*anyopaque) u64 {
    return 0;
}
const control: common.Control = .{ .now_ms = now, .deadline_ms = std.math.maxInt(u64) };
test "loader files use real regular-file IO and safe archive failures" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const src = try common.join(a, root, "nested/source");
    defer a.free(src);
    const dst = try common.join(a, root, "copied/destination");
    defer a.free(dst);
    try files.write(io, src, "abc", control);
    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash("abc", &hash, .{});
    try files.verify(io, src, hash, 3, 16, control);
    try files.copy(io, src, dst, 16, control);
    const bytes = try files.read(a, io, dst, 16, control);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("abc", bytes);
    try std.testing.expectError(error.SizeMismatch, files.verify(io, src, hash, 4, 16, control));
    try std.testing.expectError(error.ResourceLimit, files.read(a, io, src, 2, control));
    const archive_root = try common.join(a, root, "archive");
    defer a.free(archive_root);
    if (files.extract(a, io, src, archive_root, control)) |_| return error.ExpectedArchiveFailure else |_| {}
    if (files.mainClass(a, io, src, root, control)) |class| {
        a.free(class);
        return error.ExpectedArchiveFailure;
    } else |_| {}
}

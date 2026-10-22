//! Native volume boundaries used by capability-based directory walks.
const std = @import("std");
const builtin = @import("builtin");

pub fn absoluteRoot(path: []const u8) ![]const u8 {
    return rootFor(builtin.os.tag, path);
}

fn rootFor(comptime os: std.Target.Os.Tag, path: []const u8) ![]const u8 {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.UnsafePath;
    if (os == .windows) {
        const parsed = std.fs.path.parsePathWindows(u8, path);
        switch (parsed.kind) {
            .drive_absolute => return parsed.root,
            .unc_absolute => {
                var parts = std.mem.tokenizeAny(u8, parsed.root, "/\\");
                const server = parts.next() orelse return error.UnsafePath;
                const share = parts.next() orelse return error.UnsafePath;
                if (parts.next() != null or std.mem.eql(u8, server, ".") or std.mem.eql(u8, server, "..") or
                    std.mem.eql(u8, share, ".") or std.mem.eql(u8, share, "..")) return error.UnsafePath;
                return parsed.root;
            },
            else => return error.UnsafePath,
        }
    }
    const parsed = std.fs.path.parsePathPosix(path);
    if (parsed.kind != .absolute) return error.UnsafePath;
    return parsed.root;
}

test "native volume boundaries keep complete roots and UNC shares without guessing a separator" {
    const cases = .{
        .{ "C:/", "C:/" },
        .{ "c:/Games/Vela", "c:/" },
        .{ "D:\\Games\\Vela", "D:\\" },
        .{ "//NAS/Games", "//NAS/Games" },
        .{ "//NAS/Games/", "//NAS/Games/" },
        .{ "//NAS/Games/Vela", "//NAS/Games/" },
        .{ "\\\\NAS\\Games", "\\\\NAS\\Games" },
        .{ "\\\\NAS\\Games\\Vela", "\\\\NAS\\Games\\" },
    };
    inline for (cases) |item| try std.testing.expectEqualStrings(item[1], try rootFor(.windows, item[0]));
    try std.testing.expectEqualStrings("/", try rootFor(.linux, "/"));
    try std.testing.expectEqualStrings("/", try rootFor(.macos, "/Volumes/Games/Vela"));
    // On POSIX these are ordinary descendants; no server/share ancestor is skipped.
    try std.testing.expectEqualStrings("/", try rootFor(.linux, "//NAS/Games/Vela"));
}

test "native roots reject unresolved drive paths incomplete shares and device namespaces" {
    for ([_][]const u8{ "", "relative", "C:Games", "/Games", "//NAS", "//NAS/", "//NAS/.", "//NAS/..", "//?/C:/Games", "//./C:/Games", "C:/bad\x00path" }) |path|
        try std.testing.expectError(error.UnsafePath, rootFor(.windows, path));
    try std.testing.expectError(error.UnsafePath, rootFor(.linux, "relative"));
}

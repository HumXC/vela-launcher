//! Mod filename identity preserves spelling and only removes a recognized disabled suffix.
const std = @import("std");

/// Borrow the logical filename/path without changing its original case.
pub fn logical(path: []const u8) []const u8 {
    return if (isDisabled(path)) path[0 .. path.len - ".disabled".len] else path;
}

/// Recognize JARs, including their exact lowercase .disabled form.
pub fn isMod(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(logical(path), ".jar");
}

pub fn isDisabled(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".disabled") and
        std.ascii.endsWithIgnoreCase(path[0 .. path.len - ".disabled".len], ".jar");
}

test "mod paths recognize JAR case and preserve original logical spelling" {
    const cases = [_]struct { path: []const u8, expected: []const u8, disabled: bool }{
        .{ .path = "mods/example.jar", .expected = "mods/example.jar", .disabled = false },
        .{ .path = "mods/example.jar.disabled", .expected = "mods/example.jar", .disabled = true },
        .{ .path = "Example.JAR", .expected = "Example.JAR", .disabled = false },
        .{ .path = "Example.JAR.disabled", .expected = "Example.JAR", .disabled = true },
        .{ .path = "mods/Mixed.JaR", .expected = "mods/Mixed.JaR", .disabled = false },
        .{ .path = "mods/Mixed.JaR.disabled", .expected = "mods/Mixed.JaR", .disabled = true },
    };
    for (cases) |case| {
        try std.testing.expect(isMod(case.path));
        try std.testing.expectEqual(case.disabled, isDisabled(case.path));
        try std.testing.expectEqualStrings(case.expected, logical(case.path));
        try std.testing.expectEqual(case.path.ptr, logical(case.path).ptr);
        try std.testing.expectEqualStrings(case.expected, logical(logical(case.path)));
    }
}

test "unrecognized filenames never lose their suffix" {
    for ([_][]const u8{ "", ".disabled", "notes.disabled", "pack.zip", "pack.zip.disabled", "Example.JAR.DISABLED", "Example.JAR.Disabled", "Example.JAR.disabled.disabled", "Example.JAR.disabled/child", "Example.JARx", "Example.jár.disabled" }) |path| {
        try std.testing.expect(!isMod(path));
        try std.testing.expect(!isDisabled(path));
        try std.testing.expectEqualStrings(path, logical(path));
    }
}

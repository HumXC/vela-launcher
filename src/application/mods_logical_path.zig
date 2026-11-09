const std = @import("std");
const local = @import("../core/local_content.zig");
const mod_path = @import("../core/mod_path.zig");

pub fn logicalPath(entry: *const local.Entry) []const u8 {
    return if (entry.kind == .mod) mod_path.logical(entry.path) else entry.path;
}

test "mod selection keeps logical identity across JAR spellings and enabled states" {
    for ([_][]const u8{ "mods/example.jar", "mods/Example.JAR", "mods/Mixed.JaR" }) |path| {
        const disabled_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.disabled", .{path});
        defer std.testing.allocator.free(disabled_path);
        var entry: local.Entry = .{ .path = path, .physical_path = path, .name = "Example" };
        const selected = logicalPath(&entry);
        entry.path = disabled_path;
        entry.physical_path = disabled_path;
        entry.enabled = false;
        try std.testing.expectEqualStrings(selected, logicalPath(&entry));
        entry.enabled = true;
        try std.testing.expectEqualStrings(selected, logicalPath(&entry));
        entry.path = path;
        try std.testing.expectEqualStrings(selected, logicalPath(&entry));
    }
}

test "logical identity leaves non-mod content and unrecognized suffixes unchanged" {
    var entry: local.Entry = .{ .path = "mods/Example.JAR.disabled", .physical_path = "unused", .name = "Example", .enabled = false };
    for ([_]local.Kind{ .resourcepack, .shader }) |kind| {
        entry.kind = kind;
        try std.testing.expectEqualStrings(entry.path, logicalPath(&entry));
    }
    entry.kind = .mod;
    for ([_][]const u8{ "mods/Example.JAR.DISABLED", "mods/notes.disabled", "mods/pack.zip.disabled" }) |path| {
        entry.path = path;
        try std.testing.expectEqualStrings(path, logicalPath(&entry));
    }
}

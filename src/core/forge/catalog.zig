//! Official Forge catalog schema, Minecraft association and installer URLs.
const std = @import("std");
const c = @import("../loaders/common.zig");
const t = @import("../loaders/types.zig");
const j = c.j;
pub fn catalogUrl(a: std.mem.Allocator, _: []const u8) ![]const u8 {
    return a.dupe(u8, "https://files.minecraftforge.net/net/minecraftforge/forge/maven-metadata.json");
}
pub fn values(parsed: std.json.Value, base: []const u8) ![]const std.json.Value {
    return if (try j.optional(parsed, base)) |v| try j.array(v) else &.{};
}
pub const loaderId = c.text;
pub fn matches(a: std.mem.Allocator, base: []const u8, loader_id: []const u8) !bool {
    const prefix = try std.fmt.allocPrint(a, "{s}-", .{base});
    return std.mem.startsWith(u8, loader_id, prefix);
}
pub fn entry(a: std.mem.Allocator, _: []const u8, _: std.json.Value, loader_id: []const u8) !t.Entry {
    const url = try std.fmt.allocPrint(a, "https://maven.minecraftforge.net/net/minecraftforge/forge/{s}/forge-{s}-installer.jar", .{ loader_id, loader_id });
    try c.trusted(url);
    return .{ .id = try a.dupe(u8, loader_id), .url = url, .stable = releaseVersion(loader_id) };
}
fn releaseVersion(version: []const u8) bool {
    if (std.mem.indexOfScalar(u8, version, '+') != null) return false;
    for ([_][]const u8{ "alpha", "beta", "snapshot", "-pre", "-rc" }) |marker| {
        if (std.ascii.findIgnoreCase(version, marker) != null) return false;
    }
    return true;
}

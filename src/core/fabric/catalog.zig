//! Fabric Meta v2 catalog schema, profile URLs and availability policy.
const std = @import("std");
const c = @import("../loaders/common.zig");
const t = @import("../loaders/types.zig");
const j = c.j;
pub fn catalogUrl(a: std.mem.Allocator, base: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "https://meta.fabricmc.net/v2/versions/loader/{s}", .{base});
}
pub fn unavailable(status: u16, bytes: []const u8) bool {
    // Fabric alone reports unavailable games as HTTP 400 with an empty JSON list.
    return status == 400 and std.mem.eql(u8, std.mem.trim(u8, bytes, " \t\r\n"), "[]");
}
pub fn values(parsed: std.json.Value, _: []const u8) ![]const std.json.Value {
    return j.array(parsed);
}
pub fn loaderId(value: std.json.Value) ![]const u8 {
    return c.text(try j.required(try j.required(value, "loader"), "version"));
}
pub fn matches(_: std.mem.Allocator, _: []const u8, _: []const u8) !bool {
    return true;
}
pub fn entry(a: std.mem.Allocator, base: []const u8, value: std.json.Value, loader_id: []const u8) !t.Entry {
    return fabricCommon(a, base, value, loader_id, "https://meta.fabricmc.net/v2");
}
/// Quilt uses the same loader envelope and optional stability field as Fabric.
/// Its own catalog selects the v3 origin; absent stability uses the SemVer suffix.
pub fn fabricCommon(a: std.mem.Allocator, base: []const u8, value: std.json.Value, loader_id: []const u8, origin: []const u8) !t.Entry {
    const loader = try j.required(value, "loader");
    const url = try std.fmt.allocPrint(a, "{s}/versions/loader/{s}/{s}/profile/json", .{ origin, base, loader_id });
    try c.trusted(url);
    const stable = if (try j.optional(loader, "stable")) |v| try j.boolean(v) else std.mem.indexOfAny(u8, loader_id, "-+") == null;
    return .{ .id = try a.dupe(u8, loader_id), .url = url, .stable = stable };
}

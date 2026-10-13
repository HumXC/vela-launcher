//! Quilt Meta v3 catalog schema and profile policy.
const std = @import("std");
const fabric = @import("../fabric/catalog.zig");
const t = @import("../loaders/types.zig");
pub fn catalogUrl(a: std.mem.Allocator, base: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "https://meta.quiltmc.org/v3/versions/loader/{s}", .{base});
}
pub const values = fabric.values;
pub const loaderId = fabric.loaderId;
pub const matches = fabric.matches;
pub fn entry(a: std.mem.Allocator, base: []const u8, value: std.json.Value, loader_id: []const u8) !t.Entry {
    return fabric.fabricCommon(a, base, value, loader_id, "https://meta.quiltmc.org/v3");
}

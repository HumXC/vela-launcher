//! External pack dependency versions mapped to launcher catalog coordinates.
const std = @import("std");
const config = @import("config.zig");

/// Caller owns the optional result. Only Forge and legacy NeoForge use an MC
/// prefix. Never discard a supplied MC prefix: a different base is an error.
pub fn normalize(a: std.mem.Allocator, loader: config.Loader, minecraft: []const u8, version: ?[]const u8) !?[]const u8 {
    const value = version orelse return null;
    const prefixed = loader == .forge or (loader == .neoforge and std.mem.eql(u8, minecraft, "1.20.1"));
    if (prefixed and value.len != 0) {
        const prefix = try std.fmt.allocPrint(a, "{s}-", .{minecraft});
        defer a.free(prefix);
        if (std.mem.startsWith(u8, value, prefix)) return try a.dupe(u8, value);
        if (std.mem.startsWith(u8, value, "1.")) return error.LoaderVersionMismatch;
        return try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, value });
    }
    return try a.dupe(u8, value);
}

/// Compare both external short versions and stored catalog coordinates using
/// the same normalization as instance creation, retaining null distinctions.
pub fn equivalent(a: std.mem.Allocator, loader: config.Loader, minecraft: []const u8, left: ?[]const u8, right: ?[]const u8) !bool {
    const lhs = try normalize(a, loader, minecraft, left);
    defer if (lhs) |value| a.free(value);
    const rhs = try normalize(a, loader, minecraft, right);
    defer if (rhs) |value| a.free(value);
    if (lhs) |value| return if (rhs) |other| std.mem.eql(u8, value, other) else false;
    return rhs == null;
}

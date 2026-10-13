//! Official NeoForge Maven catalog and Minecraft version association policy.
const std = @import("std");
const c = @import("../loaders/common.zig");
const t = @import("../loaders/types.zig");
const j = c.j;
pub fn catalogUrl(a: std.mem.Allocator, base: []const u8) ![]const u8 {
    return a.dupe(u8, if (std.mem.eql(u8, base, "1.20.1")) "https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/forge" else "https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/neoforge");
}
pub fn values(parsed: std.json.Value, _: []const u8) ![]const std.json.Value {
    return j.array(try j.required(parsed, "versions"));
}
pub const loaderId = c.text;
pub fn matches(a: std.mem.Allocator, base: []const u8, loader_id: []const u8) !bool {
    if (std.mem.eql(u8, base, "1.20.1")) {
        const prefix = try std.fmt.allocPrint(a, "{s}-", .{base});
        return std.mem.startsWith(u8, loader_id, prefix);
    }
    const minecraft = try neoforgeMinecraftVersion(a, loader_id) orelse return false;
    return std.mem.eql(u8, minecraft, base);
}
pub fn entry(a: std.mem.Allocator, base: []const u8, _: std.json.Value, loader_id: []const u8) !t.Entry {
    const artifact = if (std.mem.eql(u8, base, "1.20.1")) "forge" else "neoforge";
    const url = try std.fmt.allocPrint(a, "https://maven.neoforged.net/releases/net/neoforged/{s}/{s}/{s}-{s}-installer.jar", .{ artifact, loader_id, artifact, loader_id });
    try c.trusted(url);
    return .{ .id = try a.dupe(u8, loader_id), .url = url, .stable = std.mem.indexOfAny(u8, loader_id, "-+") == null };
}
/// NeoForge's official selector implements this association, rather than a
/// loader-prefix guess: https://neoforged.net/js/neoforge.js and
/// https://docs.neoforged.net/docs/gettingstarted/versioning . The Maven API
/// publishes versions only. Installer install.minecraft and profile.inheritsFrom
/// remain authoritative and are checked again by recipes.prepare. Unknown naming
/// formats are omitted, never advertised against an unrelated Minecraft version.
pub fn neoforgeMinecraftVersion(a: std.mem.Allocator, version: []const u8) !?[]const u8 {
    try c.id(version);
    var metadata = std.mem.splitScalar(u8, version, '+');
    const release = metadata.next().?;
    const suffix = metadata.next();
    if (metadata.next() != null) return null;
    if (suffix) |s| {
        var valid = false;
        for ([_][]const u8{ "snapshot-", "pre-", "rc-" }) |prefix| {
            if (std.mem.startsWith(u8, s, prefix) and decimal(s[prefix.len..])) valid = true;
        }
        if (!valid) return null;
    }
    const core = release[0 .. std.mem.indexOfScalar(u8, release, '-') orelse release.len];
    var components = std.mem.splitScalar(u8, core, '.');
    const major = components.next() orelse return null;
    const minor = components.next() orelse return null;
    const patch = components.next() orelse return null;
    // The April Fools coordinate has no standard numeric game association. This
    // exact game is confirmed by its official installer, not generalized to 0.*.
    if (std.mem.eql(u8, major, "0") and std.mem.eql(u8, minor, "25w14craftmine")) {
        if (suffix != null or !decimal(patch) or components.next() != null) return null;
        return try a.dupe(u8, "25w14craftmine");
    }
    if (!decimal(major) or !decimal(minor) or !decimal(patch)) return null;
    const year = std.fmt.parseInt(u32, major, 10) catch return null;
    if (year < 20) return null;
    if (year < 26) {
        if (suffix != null or components.next() != null) return null;
        return if (std.mem.eql(u8, minor, "0"))
            try std.fmt.allocPrint(a, "1.{s}", .{major})
        else
            try std.fmt.allocPrint(a, "1.{s}.{s}", .{ major, minor });
    }
    const build = components.next() orelse return null;
    if (!decimal(build) or components.next() != null) return null;
    const game = if (std.mem.eql(u8, patch, "0"))
        try std.fmt.allocPrint(a, "{s}.{s}", .{ major, minor })
    else
        try std.fmt.allocPrint(a, "{s}.{s}.{s}", .{ major, minor, patch });
    if (suffix) |s| {
        defer a.free(game);
        return try std.fmt.allocPrint(a, "{s}-{s}", .{ game, s });
    }
    return game;
}
fn decimal(value: []const u8) bool {
    if (value.len == 0 or (value.len > 1 and value[0] == '0')) return false;
    for (value) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

const std = @import("std");
pub const m = @import("../minecraft/metadata/root.zig");
pub const j = @import("../minecraft/metadata/json.zig");
pub const Kind = enum { fabric, quilt, forge, neoforge };
pub const Side = enum { client, server };
pub const Control = @import("../install/control.zig").Control;
pub fn arena(a: std.mem.Allocator) !*std.heap.ArenaAllocator {
    const result = try a.create(std.heap.ArenaAllocator);
    result.* = .init(a);
    return result;
}
pub fn text(v: std.json.Value) ![]const u8 {
    return switch (v) {
        .string => |s| s,
        else => error.ExpectedString,
    };
}
pub fn id(value: []const u8) !void {
    try m.version.validateId(value);
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_' and c != '+') return error.InvalidLoaderId;
}
pub fn relative(path: []const u8) !void {
    if (path.len == 0 or path.len > 4096) return error.UnsafePath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| try m.version.validateId(part);
}
/// The stage is absolute and normalized; child paths always use portable '/'.
pub fn stageRoot(root: []const u8) !void {
    if (root.len == 0 or root.len > 4096 or std.mem.indexOfAny(u8, root, "\\\x00;\r\n") != null) return error.UnsafeStageRoot;
    const prefix: usize = if (root[0] == '/') 1 else if (root.len >= 3 and std.ascii.isAlphabetic(root[0]) and root[1] == ':' and root[2] == '/') 3 else return error.UnsafeStageRoot;
    relative(root[prefix..]) catch return error.UnsafeStageRoot;
}
pub fn join(a: std.mem.Allocator, root: []const u8, path: []const u8) ![]const u8 {
    try relative(path);
    return std.fmt.allocPrint(a, "{s}/{s}", .{ root, path });
}
/// HTTPS authority and decoded path are deliberately restricted. Redirect targets
/// must be revalidated by transports, never accepted just because the first URL was.
/// Historical Forge profiles named the official Maven repository over HTTP or
/// its former files.minecraftforge.net/maven path. Upgrade only these exact
/// origins; never fetch plaintext and never admit arbitrary repository URLs.
/// Returned bytes are borrowed unless rewritten; intended for recipe arenas.
pub fn normalizeLibraryUrl(a: std.mem.Allocator, url: []const u8) ![]const u8 {
    const aliases = [_]struct { from: []const u8, to: []const u8 }{
        .{ .from = "http://files.minecraftforge.net/maven/", .to = "https://maven.minecraftforge.net/" },
        .{ .from = "https://files.minecraftforge.net/maven/", .to = "https://maven.minecraftforge.net/" },
        .{ .from = "http://maven.minecraftforge.net/", .to = "https://maven.minecraftforge.net/" },
        .{ .from = "http://libraries.minecraft.net/", .to = "https://libraries.minecraft.net/" },
    };
    for (aliases) |alias| {
        if (!std.mem.startsWith(u8, url, alias.from)) continue;
        const normalized = try std.fmt.allocPrint(a, "{s}{s}", .{ alias.to, url[alias.from.len..] });
        errdefer a.free(normalized);
        try trusted(normalized);
        return normalized;
    }
    try trusted(url);
    return url;
}

pub fn trusted(url: []const u8) !void {
    if (!std.mem.startsWith(u8, url, "https://")) return error.UntrustedUrl;
    const rest = url[8..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.UntrustedUrl;
    const host = rest[0..slash];
    const hosts = [_][]const u8{ "meta.fabricmc.net", "maven.fabricmc.net", "meta.quiltmc.org", "maven.quiltmc.org", "files.minecraftforge.net", "maven.minecraftforge.net", "maven.neoforged.net", "libraries.minecraft.net", "repo.maven.apache.org" };
    var found = false;
    for (hosts) |allowed| if (std.mem.eql(u8, host, allowed)) {
        found = true;
        break;
    };
    if (!found) return error.UntrustedUrl;
    const path = rest[slash + 1 ..];
    if (std.mem.indexOfAny(u8, path, "%?#\\") != null) return error.UntrustedUrl;
    relative(std.mem.trimEnd(u8, path, "/")) catch return error.UntrustedUrl;
}
pub fn sha1(value: []const u8) !m.Sha1 {
    if (value.len != 40) return error.InvalidSha1;
    var hash: m.Sha1 = undefined;
    _ = std.fmt.hexToBytes(&hash, value) catch return error.InvalidSha1;
    return hash;
}
pub fn verify(bytes: []const u8, expected: m.Sha1) !void {
    var actual: m.Sha1 = undefined;
    std.crypto.hash.Sha1.hash(bytes, &actual, .{});
    if (!std.mem.eql(u8, &actual, &expected)) return error.ChecksumMismatch;
}

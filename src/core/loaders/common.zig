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
/// Absolute, slash-normalized stage path: Unix '/', drive 'C:/', or UNC '//host/share'.
/// A volume/share root may stand alone; descendants must be normalized safe components.
/// Windows device namespaces and drive-relative paths are never stage roots.
pub fn stageRoot(root: []const u8) !void {
    if (root.len == 0 or root.len > 4096 or std.mem.indexOfAny(u8, root, "\\\x00;\r\n") != null) return error.UnsafeStageRoot;
    const prefix = try stageRootPrefix(root);
    if (prefix < root.len) relative(root[prefix..]) catch return error.UnsafeStageRoot;
}

fn stageRootPrefix(root: []const u8) !usize {
    if (std.mem.startsWith(u8, root, "//")) {
        // A UNC volume comprises both a server and a share, not just the leading '//'.
        const server_end = std.mem.indexOfScalarPos(u8, root, 2, '/') orelse return error.UnsafeStageRoot;
        m.version.validateId(root[2..server_end]) catch return error.UnsafeStageRoot;
        const share_start = server_end + 1;
        const share_end = std.mem.indexOfScalarPos(u8, root, share_start, '/') orelse root.len;
        m.version.validateId(root[share_start..share_end]) catch return error.UnsafeStageRoot;
        return if (share_end == root.len) share_end else share_end + 1;
    }
    if (root[0] == '/') return 1;
    if (root.len >= 3 and std.ascii.isAlphabetic(root[0]) and root[1] == ':' and root[2] == '/') return 3;
    return error.UnsafeStageRoot;
}

test "stage roots accept complete Unix drive and UNC volumes on every host" {
    for ([_][]const u8{
        "/",
        "/tmp/stage fixture",
        "C:/",
        "c:/stage/Synthetic Fixture",
        "Z:/Games/游戏",
        "//NAS/Games",
        "//NAS/Games/",
        "//NAS/Games/Vela",
        "//nas.example/Games$/stage fixture",
        "//192.168.1.10/share/Vela",
    }) |root| try stageRoot(root);

    // Drive letters are parsed as Windows syntax even when these tests run on POSIX.
    var drive = [_]u8{ 'A', ':', '/' };
    for (0..26) |index| {
        drive[0] = 'A' + @as(u8, @intCast(index));
        try stageRoot(&drive);
        drive[0] = std.ascii.toLower(drive[0]);
        try stageRoot(&drive);
    }
}

test "stage roots reject malformed volumes namespaces and unsafe components on every host" {
    for ([_][]const u8{
        "",                        "relative",            "C:",                   "C:stage",           "1:/stage",          "CC:/stage",
        "//",                      "//NAS",               "//NAS/",               "///Games",          "///NAS/Games",      "//NAS//Games",
        "//./Games",               "//../Games",          "//NAS/.",              "//NAS/..",          "//?/C:/stage",      "//./C:/stage",
        "/??/C:/stage",            "C:\\stage",           "\\\\NAS\\Games\\Vela", "//NAS/Games\\Vela", "/stage/",           "C:/stage/",
        "//NAS/Games/Vela/",       "/stage//nested",      "C://stage",            "//NAS/Games//Vela", "//NAS/Games//",     "/stage/../live",
        "C:/stage/./live",         "//NAS/Games/../live", "/stage/CON",           "C:/stage/LPT1.txt", "//NAS/Games/NUL",   "/stage/trailing.",
        "C:/stage/trailing ",      "//NAS/Games./Vela",   "//NAS./Games",         "//NAS /Games",      "//NAS/Games /Vela", "/stage/stream:data",
        "//NAS/Games:stream/Vela", "//NAS:445/Games",     "/stage/a;b",           "C:/stage/a*b",      "//NAS/Games/a?b",   "/stage/a\x00b",
        "C:/stage/a\nb",           "//NAS/Games/a\rb",    "/stage/a\x1fb",        "//NAS/Games/\x7f",  "//NAS/\xff",
    }) |root| try std.testing.expectError(error.UnsafeStageRoot, stageRoot(root));
}

test "stage roots enforce total and component bounds without touching the filesystem" {
    var root: [4097]u8 = @splat('a');
    root[0] = '/';
    var separator: usize = 200;
    while (separator < root.len) : (separator += 200) root[separator] = '/';
    try stageRoot(root[0..4096]);
    try std.testing.expectError(error.UnsafeStageRoot, stageRoot(&root));

    var component: [202]u8 = @splat('a');
    component[0] = '/';
    try stageRoot(component[0..201]);
    try std.testing.expectError(error.UnsafeStageRoot, stageRoot(&component));
}
pub fn join(a: std.mem.Allocator, root: []const u8, path: []const u8) ![]const u8 {
    try relative(path);
    const separator: []const u8 = if (std.mem.endsWith(u8, root, "/")) "" else "/";
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ root, separator, path });
}

test "stage root joins retain one separator at Unix drive and UNC boundaries" {
    const a = std.testing.allocator;
    for ([_]struct { root: []const u8, expected: []const u8 }{
        .{ .root = "/", .expected = "/child/file.json" },
        .{ .root = "C:/", .expected = "C:/child/file.json" },
        .{ .root = "//NAS/Games", .expected = "//NAS/Games/child/file.json" },
        .{ .root = "//NAS/Games/", .expected = "//NAS/Games/child/file.json" },
        .{ .root = "/tmp/stage", .expected = "/tmp/stage/child/file.json" },
    }) |case| {
        const joined = try join(a, case.root, "child/file.json");
        defer a.free(joined);
        try std.testing.expectEqualStrings(case.expected, joined);
        try stageRoot(joined);
    }
    // This helper also builds safe relative artifact paths.
    const artifact = try join(a, "libraries", "org/example/fixture.jar");
    defer a.free(artifact);
    try std.testing.expectEqualStrings("libraries/org/example/fixture.jar", artifact);
    try std.testing.expectError(error.UnsafeVersionId, join(a, "/", "../outside"));
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

//! Shared text links for local metadata and provider project details.
const std = @import("std");
const dvui = @import("dvui");
const providers = @import("../core/content_providers.zig");
const theme = @import("theme.zig");
pub const Link = struct { label: []const u8, suffix: []const u8, url: ?[]const u8 };
pub fn targets(a: std.mem.Allocator, name: []const u8, homepage: ?[]const u8, provider: ?providers.Provider) ![4]Link {
    const escaped = try a.alloc(u8, name.len * 3);
    defer a.free(escaped);
    var used: usize = 0;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            escaped[used] = byte;
            used += 1;
        } else {
            escaped[used] = '%';
            escaped[used + 1] = "0123456789ABCDEF"[byte >> 4];
            escaped[used + 2] = "0123456789ABCDEF"[byte & 15];
            used += 3;
        }
    }
    const query = escaped[0..used];
    const home: ?[]const u8 = if (homepage) |url| if (url.len > 0) url else null else null;
    const known = if (home != null) provider orelse knownProvider(home.?) else null;
    return .{
        .{ .label = "主页", .suffix = "homepage", .url = home },
        .{ .label = "CurseForge", .suffix = "curseforge", .url = if (known == .curseforge) home else try std.fmt.allocPrint(a, "https://www.curseforge.com/minecraft/search?class=mc-mods&search={s}", .{query}) },
        .{ .label = "Modrinth", .suffix = "modrinth", .url = if (known == .modrinth) home else try std.fmt.allocPrint(a, "https://modrinth.com/mods?q={s}", .{query}) },
        .{ .label = "MC百科", .suffix = "mcmod", .url = try std.fmt.allocPrint(a, "https://search.mcmod.cn/s?key={s}", .{query}) },
    };
}
pub fn draw(name: []const u8, homepage: ?[]const u8, provider: ?providers.Provider, prefix: []const u8) bool {
    const a = dvui.currentWindow().arena();
    const destinations = targets(a, name, homepage, provider) catch return false;
    const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .none, .padding = .all(0), .margin = .all(0), .min_size_content = .height(theme.sizing.control_height), .background = false });
    defer row.deinit();
    var success = true;
    for (destinations, 0..) |link, index| {
        const url = link.url orelse continue;
        if (dvui.labelClick(@src(), "{s}", .{link.label}, .{}, .{ .id_extra = index, .tag = std.fmt.allocPrint(a, "{s}-{s}", .{ prefix, link.suffix }) catch null, .font = theme.fontSized(14).withUnderline(.{}), .color_text = .{ .color = theme.accent }, .gravity_y = 0.5, .margin = .{ .w = if (index == destinations.len - 1) 0 else 12 }, .padding = .all(0) })) {
            if (!dvui.openURL(.{ .url = url })) success = false;
        }
    }
    return success;
}

fn knownProvider(url: []const u8) ?providers.Provider {
    if (!providers.safeHttpsUrl(url)) return null;
    const uri = std.Uri.parse(url) catch return null;
    const host = uri.host.?.percent_encoded;
    const path = uri.path.percent_encoded;
    if ((std.ascii.eqlIgnoreCase(host, "modrinth.com") or std.ascii.eqlIgnoreCase(host, "www.modrinth.com")) and (std.mem.startsWith(u8, path, "/mod/") or std.mem.startsWith(u8, path, "/project/"))) return .modrinth;
    if ((std.ascii.eqlIgnoreCase(host, "www.curseforge.com") or std.ascii.eqlIgnoreCase(host, "curseforge.com")) and std.mem.startsWith(u8, path, "/minecraft/mc-mods/")) return .curseforge;
    return null;
}
test "platform links keep known project pages and escape search names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = "https://modrinth.com/mod/iris";
    const known = try targets(a, "Iris Shaders", home, null);
    try std.testing.expectEqualStrings(home, known[2].url.?);
    const search = try targets(a, "A & 模组", null, null);
    try std.testing.expect(search[0].url == null);
    for (search[1..]) |link| {
        try std.testing.expect(std.mem.indexOf(u8, link.url.?, "A%20%26%20%E6%A8%A1%E7%BB%84") != null);
        try std.testing.expect(std.mem.indexOfScalar(u8, link.url.?, ' ') == null);
    }
}

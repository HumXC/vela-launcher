//! Official loader catalogs and staged recipes. No app/UI or filesystem policy.
//! Sources: https://meta.fabricmc.net/ ; https://meta.quiltmc.org/openapi.yaml
//! https://files.minecraftforge.net/net/minecraftforge/forge/maven-metadata.json
//! https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/neoforge
const std = @import("std");
const c = @import("loaders_common.zig");
const m = c.m;
const j = c.j;
pub const Kind = c.Kind;
pub const Side = c.Side;
pub const Control = c.Control;
pub const recipes = @import("loaders_recipe.zig");
pub const execution = @import("loaders_execute.zig");
pub const archive = @import("loaders_archive.zig");
pub const prepare = recipes.prepare;
pub const execute = execution.execute;
pub const Selection = struct { kind: Kind, base_id: []const u8, loader_id: []const u8, side: Side = .client };
pub const Entry = struct { id: []const u8, url: []const u8, stable: bool };
pub const Catalog = struct {
    kind: Kind,
    base_id: []const u8,
    source_url: []const u8,
    entries: []const Entry,
    pub fn find(self: Catalog, loader_id: []const u8) ?Entry {
        for (self.entries) |entry| if (std.mem.eql(u8, entry.id, loader_id)) return entry;
        return null;
    }
    pub fn validate(self: Catalog, selection: Selection) !Entry {
        try c.id(selection.base_id);
        try c.id(selection.loader_id);
        if (selection.kind != self.kind or !std.mem.eql(u8, selection.base_id, self.base_id)) return error.CatalogMismatch;
        return self.find(selection.loader_id) orelse error.UnsupportedLoaderVersion;
    }
};
pub const Response = struct { bytes: []u8, final_url: []u8, status: u16 };
/// Returns allocator-owned bytes and final_url; caller frees both. Enforce max_bytes
/// during reception, TLS verification, redirects via c.trusted, and control checks.
/// Configurable transport changes routing, not the official origin trust policy.
pub const Transport = struct {
    context: ?*anyopaque = null,
    get: *const fn (?*anyopaque, std.mem.Allocator, []const u8, usize, Control) anyerror!Response,
};
pub fn catalogUrl(a: std.mem.Allocator, kind: Kind, base: []const u8) ![]const u8 {
    try c.id(base);
    return switch (kind) {
        .fabric => std.fmt.allocPrint(a, "https://meta.fabricmc.net/v2/versions/loader/{s}", .{base}),
        .quilt => std.fmt.allocPrint(a, "https://meta.quiltmc.org/v3/versions/loader/{s}", .{base}),
        .forge => a.dupe(u8, "https://files.minecraftforge.net/net/minecraftforge/forge/maven-metadata.json"),
        .neoforge => a.dupe(u8, if (std.mem.eql(u8, base, "1.20.1")) "https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/forge" else "https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/neoforge"),
    };
}
pub fn fetchCatalog(a: std.mem.Allocator, transport: Transport, kind: Kind, base: []const u8, control: Control) !m.Owned(Catalog) {
    try control.check();
    const url = try catalogUrl(a, kind, base);
    defer a.free(url);
    const response = try transport.get(transport.context, a, url, 8 * 1024 * 1024, control);
    defer a.free(response.bytes);
    defer a.free(response.final_url);
    try c.trusted(response.final_url);
    // Catalog authority cannot migrate to an unrelated allowed repository.
    if (!std.mem.eql(u8, response.final_url, url)) return error.UnexpectedRedirect;
    try control.check();
    if (response.status == 404) return parseCatalog(a, kind, base, "[]");
    if (response.status != 200) return error.HttpStatus;
    if (response.bytes.len > 8 * 1024 * 1024) return error.MetadataTooLarge;
    return parseCatalog(a, kind, base, response.bytes);
}
pub fn parseCatalog(a: std.mem.Allocator, kind: Kind, base: []const u8, bytes: []const u8) !m.Owned(Catalog) {
    try c.id(base);
    if (bytes.len > 8 * 1024 * 1024) return error.MetadataTooLarge;
    const ar = try c.arena(a);
    errdefer {
        ar.deinit();
        a.destroy(ar);
    }
    const g = ar.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, g, bytes, .{ .allocate = .alloc_always, .parse_numbers = false });
    const source = try catalogUrl(g, kind, base);
    var entries: std.ArrayList(Entry) = .empty;
    if (parsed.value == .array and parsed.value.array.items.len == 0) {
        const value: Catalog = .{ .kind = kind, .base_id = try g.dupe(u8, base), .source_url = source, .entries = &.{} };
        return .{ .arena = ar, .backing = a, .value = value };
    }
    const values = switch (kind) {
        .fabric, .quilt => try j.array(parsed.value),
        .forge => if (try j.optional(parsed.value, base)) |v| try j.array(v) else &.{},
        .neoforge => try j.array(try j.required(parsed.value, "versions")),
    };
    if (values.len > 50000) return error.CatalogTooLarge;
    for (values) |value| {
        const loader = if (kind == .fabric or kind == .quilt) try j.required(value, "loader") else value;
        const loader_id = if (kind == .fabric or kind == .quilt) try c.text(try j.required(loader, "version")) else try c.text(loader);
        try c.id(loader_id);
        if (kind == .forge or (kind == .neoforge and std.mem.eql(u8, base, "1.20.1"))) {
            const prefix = try std.fmt.allocPrint(g, "{s}-", .{base});
            if (!std.mem.startsWith(u8, loader_id, prefix)) continue;
        } else if (kind == .neoforge) {
            // NeoForge versioning omits Minecraft's leading 1. and uses zero for
            // the missing patch; installer.minecraft remains authoritative.
            if (!std.mem.startsWith(u8, base, "1.")) continue;
            var parts = std.mem.splitScalar(u8, base[2..], '.');
            const major = parts.next().?;
            const minor = parts.next() orelse "0";
            if (parts.next() != null) continue;
            const prefix = try std.fmt.allocPrint(g, "{s}.{s}.", .{ major, minor });
            if (!std.mem.startsWith(u8, loader_id, prefix)) continue;
        }
        for (entries.items) |old| if (std.mem.eql(u8, old.id, loader_id)) return error.DuplicateLoaderVersion;
        const url = switch (kind) {
            .fabric => try std.fmt.allocPrint(g, "https://meta.fabricmc.net/v2/versions/loader/{s}/{s}/profile/json", .{ base, loader_id }),
            .quilt => try std.fmt.allocPrint(g, "https://meta.quiltmc.org/v3/versions/loader/{s}/{s}/profile/json", .{ base, loader_id }),
            .forge => try std.fmt.allocPrint(g, "https://maven.minecraftforge.net/net/minecraftforge/forge/{s}/forge-{s}-installer.jar", .{ loader_id, loader_id }),
            .neoforge => try std.fmt.allocPrint(g, "https://maven.neoforged.net/releases/net/neoforged/{s}/{s}/{s}-{s}-installer.jar", .{ if (std.mem.eql(u8, base, "1.20.1")) "forge" else "neoforge", loader_id, if (std.mem.eql(u8, base, "1.20.1")) "forge" else "neoforge", loader_id }),
        };
        try c.trusted(url);
        const stable = if (kind == .fabric or kind == .quilt) if (try j.optional(loader, "stable")) |v| try j.boolean(v) else false else std.mem.indexOf(u8, loader_id, "beta") == null;
        try entries.append(g, .{ .id = try g.dupe(u8, loader_id), .url = url, .stable = stable });
    }
    const value: Catalog = .{ .kind = kind, .base_id = try g.dupe(u8, base), .source_url = source, .entries = try entries.toOwnedSlice(g) };
    return .{ .arena = ar, .backing = a, .value = value };
}
test {
    _ = @import("loaders_tests.zig");
}

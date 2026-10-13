//! Unified official loader catalogs and staged recipe entrypoints.
const std = @import("std");
const c = @import("common.zig");
const m = c.m;
pub const types = @import("types.zig");
const fabric = @import("../fabric/root.zig").catalog;
const quilt = @import("../quilt/root.zig").catalog;
const forge = @import("../forge/root.zig").catalog;
const neoforge = @import("../neoforge/root.zig").catalog;
pub const Kind = types.Kind;
pub const Side = types.Side;
pub const Control = types.Control;
pub const Selection = types.Selection;
pub const Entry = types.Entry;
pub const Catalog = types.Catalog;
pub const Response = types.Response;
pub const Transport = types.Transport;
pub const recipes = @import("recipe.zig");
pub const execution = @import("execute.zig");
pub const archive = @import("forge_installer/archive.zig");
pub const prepare = recipes.prepare;
pub const execute = execution.execute;
pub const neoforgeMinecraftVersion = neoforge.neoforgeMinecraftVersion;

pub fn catalogUrl(a: std.mem.Allocator, kind: Kind, base: []const u8) ![]const u8 {
    try c.id(base);
    return switch (kind) {
        .fabric => fabric.catalogUrl(a, base),
        .quilt => quilt.catalogUrl(a, base),
        .forge => forge.catalogUrl(a, base),
        .neoforge => neoforge.catalogUrl(a, base),
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
    if (kind == .fabric and fabric.unavailable(response.status, response.bytes))
        return parseCatalog(a, kind, base, "[]");
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
        .fabric => try fabric.values(parsed.value, base),
        .quilt => try quilt.values(parsed.value, base),
        .forge => try forge.values(parsed.value, base),
        .neoforge => try neoforge.values(parsed.value, base),
    };
    if (values.len > 50000) return error.CatalogTooLarge;
    for (values) |value| {
        const loader_id = switch (kind) {
            .fabric => try fabric.loaderId(value),
            .quilt => try quilt.loaderId(value),
            .forge => try forge.loaderId(value),
            .neoforge => try neoforge.loaderId(value),
        };
        try c.id(loader_id);
        const associated = switch (kind) {
            .fabric => try fabric.matches(g, base, loader_id),
            .quilt => try quilt.matches(g, base, loader_id),
            .forge => try forge.matches(g, base, loader_id),
            .neoforge => try neoforge.matches(g, base, loader_id),
        };
        if (!associated) continue;
        for (entries.items) |old| if (std.mem.eql(u8, old.id, loader_id)) return error.DuplicateLoaderVersion;
        const entry = switch (kind) {
            .fabric => try fabric.entry(g, base, value, loader_id),
            .quilt => try quilt.entry(g, base, value, loader_id),
            .forge => try forge.entry(g, base, value, loader_id),
            .neoforge => try neoforge.entry(g, base, value, loader_id),
        };
        try entries.append(g, entry);
    }
    const value: Catalog = .{ .kind = kind, .base_id = try g.dupe(u8, base), .source_url = source, .entries = try entries.toOwnedSlice(g) };
    return .{ .arena = ar, .backing = a, .value = value };
}

test {
    _ = @import("tests/recipes.zig");
    _ = @import("tests/catalogue.zig");
    _ = @import("tests/publication.zig");
    _ = @import("tests/forge_install.zig");
    _ = @import("tests/late_artifact.zig");
    _ = @import("tests/archive_checks.zig");
    _ = @import("tests/java_process.zig");
    _ = @import("tests/base_install.zig");
}

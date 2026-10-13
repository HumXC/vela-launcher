//! Canonical catalog contracts shared by providers, recipes and callers.
const std = @import("std");
const c = @import("common.zig");
pub const Kind = c.Kind;
pub const Side = c.Side;
pub const Control = c.Control;
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

//! Owned, bounded cache response metadata shared by HTTP transports.
const std = @import("std");
pub const PolicyHeaders = @import("http_cache_policy.zig").Headers;
const names = [_][]const u8{ "cache-control", "date", "age", "expires", "etag", "last-modified", "vary" };
pub const Owned = struct {
    values: [names.len]std.ArrayList(u8) = @splat(.empty),
    has_cookie: bool = false,
    pub fn deinit(self: *Owned, a: std.mem.Allocator) void {
        for (&self.values) |*value| value.deinit(a);
        self.* = .{};
    }
    pub fn clear(self: *Owned) void {
        self.has_cookie = false;
        for (&self.values) |*value| value.clearRetainingCapacity();
    }
    pub fn append(self: *Owned, a: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        if (std.ascii.eqlIgnoreCase(name, "set-cookie")) self.has_cookie = true;
        for (names, 0..) |known, i| {
            if (!std.ascii.eqlIgnoreCase(known, name)) continue;
            if (value.len > 8192 or self.values[i].items.len + value.len > 8192) return error.HeaderTooLarge;
            // Combining duplicate singleton fields makes malformed validators/dates
            // unusable rather than silently selecting an attacker-controlled value.
            if (self.values[i].items.len != 0) try self.values[i].appendSlice(a, ", ");
            try self.values[i].appendSlice(a, value);
            return;
        }
    }
    pub fn view(self: *const Owned) PolicyHeaders {
        var result: PolicyHeaders = .{};
        inline for (.{ "cache_control", "date", "age", "expires", "etag", "last_modified", "vary" }, 0..) |field, i| {
            @field(result, field) = if (self.values[i].items.len == 0) null else self.values[i].items;
        }
        if (self.has_cookie) result.cache_control = "no-store";
        return result;
    }
    pub fn clone(a: std.mem.Allocator, headers: PolicyHeaders) !Owned {
        var result: Owned = .{};
        errdefer result.deinit(a);
        inline for (.{ "cache_control", "date", "age", "expires", "etag", "last_modified", "vary" }, 0..) |field, i| {
            if (@field(headers, field)) |value| try result.append(a, names[i], value);
        }
        return result;
    }
};

test "cache headers combine directives and reset intermediate response metadata" {
    const a = std.testing.allocator;
    var owned: Owned = .{};
    defer owned.deinit(a);
    try owned.append(a, "Cache-Control", "max-age=60");
    try owned.append(a, "cache-control", "no-store");
    try std.testing.expectEqualStrings("max-age=60, no-store", owned.view().cache_control.?);
    owned.clear();
    try owned.append(a, "ETag", "\"v2\"");
    try std.testing.expect(owned.view().cache_control == null);
    var copy = try Owned.clone(a, owned.view());
    defer copy.deinit(a);
    try std.testing.expectEqualStrings(owned.view().etag.?, copy.view().etag.?);
}

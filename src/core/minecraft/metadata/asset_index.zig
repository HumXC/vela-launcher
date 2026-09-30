const std = @import("std");
const j = @import("json.zig");
const owned = @import("owned.zig");
pub const Asset = struct { name: []const u8, hash: j.Sha1, size: u64 };
pub const AssetIndex = struct {
    objects: []const Asset,
    virtual: ?bool,
    map_to_resources: ?bool,
    pub fn find(self: AssetIndex, name: []const u8) ?*const Asset {
        for (self.objects) |*asset| if (std.mem.eql(u8, asset.name, name)) return asset;
        return null;
    }
};
pub fn parseSlice(a: j.A, bytes: []const u8) !owned.Owned(AssetIndex) {
    return owned.fromSlice(AssetIndex, a, bytes, decode);
}
pub fn parseValue(a: j.A, value: j.V) !owned.Owned(AssetIndex) {
    return owned.fromValue(AssetIndex, a, value, decode);
}
fn decode(a: j.A, v: j.V) !AssetIndex {
    const map = try j.object(try j.required(v, "objects"));
    const out = try a.alloc(Asset, map.count());
    var it = map.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) out[i] = .{ .name = try a.dupe(u8, e.key_ptr.*), .hash = try j.sha1(try j.required(e.value_ptr.*, "hash")), .size = try j.uint(try j.required(e.value_ptr.*, "size")) };
    return .{ .objects = out, .virtual = if (try j.optional(v, "virtual")) |b| try j.boolean(b) else null, .map_to_resources = if (try j.optional(v, "map_to_resources")) |b| try j.boolean(b) else null };
}

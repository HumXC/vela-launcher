const std = @import("std");
const j = @import("json.zig");
const owned = @import("owned.zig");
pub const Entry = struct { id: []const u8, kind: []const u8, url: []const u8, time: []const u8, release_time: []const u8, sha1: ?j.Sha1, compliance_level: ?u64 };
pub const Manifest = struct {
    latest: struct { release: []const u8, snapshot: []const u8 },
    versions: []const Entry,
    pub fn find(self: Manifest, id: []const u8) ?*const Entry {
        for (self.versions) |*item| if (std.mem.eql(u8, item.id, id)) return item;
        return null;
    }
};
pub fn parseSlice(a: j.A, bytes: []const u8) !owned.Owned(Manifest) {
    return owned.fromSlice(Manifest, a, bytes, decode);
}
pub fn parseValue(a: j.A, value: j.V) !owned.Owned(Manifest) {
    return owned.fromValue(Manifest, a, value, decode);
}
fn decode(a: j.A, v: j.V) !Manifest {
    const latest = try j.required(v, "latest");
    return .{ .latest = .{ .release = try j.text(a, latest, "release"), .snapshot = try j.text(a, latest, "snapshot") }, .versions = try j.list(Entry, a, try j.required(v, "versions"), entry) };
}
fn entry(a: j.A, v: j.V) !Entry {
    return .{ .id = try j.text(a, v, "id"), .kind = try j.text(a, v, "type"), .url = try j.text(a, v, "url"), .time = try j.text(a, v, "time"), .release_time = try j.text(a, v, "releaseTime"), .sha1 = try j.maybeSha1(v, "sha1"), .compliance_level = try j.maybeUint(v, "complianceLevel") };
}

const std = @import("std");
pub const m = @import("metadata/root.zig");
pub const j = @import("metadata/json.zig");
pub const Kind = enum { fabric, quilt, forge, neoforge };
pub const Side = enum { client, server };
pub const Control = struct {
    cancel: ?*const std.atomic.Value(bool) = null,
    /// Absolute monotonic milliseconds in the callback clock's domain.
    deadline_ms: u64,
    context: ?*anyopaque = null,
    now_ms: *const fn (?*anyopaque) u64,
    pub fn check(self: Control) !void {
        if (self.cancel) |flag| if (flag.load(.acquire)) return error.Canceled;
        if (self.now_ms(self.context) >= self.deadline_ms) return error.DeadlineExceeded;
    }
};
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

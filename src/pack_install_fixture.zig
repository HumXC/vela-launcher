const std = @import("std");
const paths_mod = @import("core/instances.zig");
const Io = std.Io;
pub const Entry = struct { path: []const u8, bytes: []const u8 };
fn integer(comptime T: type, bytes: *std.ArrayList(u8), value: T) !void {
    var encoded: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &encoded, value, .little);
    try bytes.appendSlice(std.testing.allocator, &encoded);
}
pub fn zip(dir: Io.Dir, name: []const u8, entries: []const Entry) !void {
    const a = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    const offsets = try a.alloc(u32, entries.len);
    defer a.free(offsets);
    for (entries, offsets) |entry, *offset| {
        offset.* = @intCast(bytes.items.len);
        try integer(u32, &bytes, 0x04034b50);
        for ([_]u16{ 20, 0, 0, 0, 0 }) |v| try integer(u16, &bytes, v);
        try integer(u32, &bytes, std.hash.Crc32.hash(entry.bytes));
        try integer(u32, &bytes, @intCast(entry.bytes.len));
        try integer(u32, &bytes, @intCast(entry.bytes.len));
        try integer(u16, &bytes, @intCast(entry.path.len));
        try integer(u16, &bytes, 0);
        try bytes.appendSlice(a, entry.path);
        try bytes.appendSlice(a, entry.bytes);
    }
    const central: u32 = @intCast(bytes.items.len);
    for (entries, offsets) |entry, offset| {
        try integer(u32, &bytes, 0x02014b50);
        for ([_]u16{ 20, 20, 0, 0, 0, 0 }) |v| try integer(u16, &bytes, v);
        try integer(u32, &bytes, std.hash.Crc32.hash(entry.bytes));
        try integer(u32, &bytes, @intCast(entry.bytes.len));
        try integer(u32, &bytes, @intCast(entry.bytes.len));
        try integer(u16, &bytes, @intCast(entry.path.len));
        for (0..4) |_| try integer(u16, &bytes, 0);
        try integer(u32, &bytes, 0);
        try integer(u32, &bytes, offset);
        try bytes.appendSlice(a, entry.path);
    }
    const size: u32 = @intCast(bytes.items.len - central);
    try integer(u32, &bytes, 0x06054b50);
    for (0..2) |_| try integer(u16, &bytes, 0);
    for (0..2) |_| try integer(u16, &bytes, @intCast(entries.len));
    try integer(u32, &bytes, size);
    try integer(u32, &bytes, central);
    try integer(u16, &bytes, 0);
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes.items });
}
pub const Fixture = struct {
    tmp: std.testing.TmpDir,
    paths: paths_mod.Paths,
    pub fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buffer: [4096]u8 = undefined;
        const len = try tmp.dir.realPath(std.testing.io, &buffer);
        return .{ .tmp = tmp, .paths = try paths_mod.Paths.init(std.testing.allocator, std.testing.io, buffer[0..len]) };
    }
    pub fn deinit(self: *Fixture) void {
        self.paths.deinit();
        self.tmp.cleanup();
    }
    pub fn path(self: *const Fixture, name: []const u8) ![]u8 {
        return std.fs.path.join(std.testing.allocator, &.{ self.paths.root, name });
    }
};
pub const index = "{\"formatVersion\":1,\"game\":\"minecraft\",\"versionId\":\"v1\",\"name\":\"Offline Pack\",\"dependencies\":{\"minecraft\":\"1.21.1\"},\"files\":[]}";

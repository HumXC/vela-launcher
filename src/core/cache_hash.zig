//! Incremental SHA backed by separately compiled, ReleaseSafe standard-library kernels.
extern fn vela_sha1_init(*anyopaque) void;
extern fn vela_sha1_update(*anyopaque, [*]const u8, usize) void;
extern fn vela_sha1_final(*anyopaque, *[20]u8) void;
pub const Sha1 = struct {
    state: [256]u8 align(16),
    pub const digest_length = 20;
    pub fn init(_: anytype) @This() {
        var value: @This() = undefined;
        vela_sha1_init(&value.state);
        return value;
    }
    pub fn update(self: *@This(), bytes: []const u8) void {
        vela_sha1_update(&self.state, bytes.ptr, bytes.len);
    }
    pub fn final(self: *@This(), out: *[20]u8) void {
        vela_sha1_final(&self.state, out);
    }
    pub fn hash(bytes: []const u8, out: *[20]u8, _: anytype) void {
        var value = init(.{});
        value.update(bytes);
        value.final(out);
    }
};
extern fn vela_sha256_init(*anyopaque) void;
extern fn vela_sha256_update(*anyopaque, [*]const u8, usize) void;
extern fn vela_sha256_final(*anyopaque, *[32]u8) void;
pub const Sha256 = struct {
    state: [256]u8 align(16),
    pub const digest_length = 32;
    pub fn init(_: anytype) @This() {
        var value: @This() = undefined;
        vela_sha256_init(&value.state);
        return value;
    }
    pub fn update(self: *@This(), bytes: []const u8) void {
        vela_sha256_update(&self.state, bytes.ptr, bytes.len);
    }
    pub fn final(self: *@This(), out: *[32]u8) void {
        vela_sha256_final(&self.state, out);
    }
    pub fn hash(bytes: []const u8, out: *[32]u8, _: anytype) void {
        var value = init(.{});
        value.update(bytes);
        value.final(out);
    }
};
extern fn vela_sha512_init(*anyopaque) void;
extern fn vela_sha512_update(*anyopaque, [*]const u8, usize) void;
extern fn vela_sha512_final(*anyopaque, *[64]u8) void;
pub const Sha512 = struct {
    state: [256]u8 align(16),
    pub const digest_length = 64;
    pub fn init(_: anytype) @This() {
        var value: @This() = undefined;
        vela_sha512_init(&value.state);
        return value;
    }
    pub fn update(self: *@This(), bytes: []const u8) void {
        vela_sha512_update(&self.state, bytes.ptr, bytes.len);
    }
    pub fn final(self: *@This(), out: *[64]u8) void {
        vela_sha512_final(&self.state, out);
    }
    pub fn hash(bytes: []const u8, out: *[64]u8, _: anytype) void {
        var value = init(.{});
        value.update(bytes);
        value.final(out);
    }
};

test "optimized SHA matches standard digests across padding and chunk boundaries" {
    const std = @import("std");
    var data: [4097]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = @truncate(i *% 71);
    inline for (.{ .{ Sha1, std.crypto.hash.Sha1 }, .{ Sha256, std.crypto.hash.sha2.Sha256 }, .{ Sha512, std.crypto.hash.sha2.Sha512 } }) |pair| {
        for ([_]usize{ 0, 1, 55, 56, 63, 64, 65, 111, 112, 127, 128, 129, 4097 }) |len| {
            var expected: [pair[0].digest_length]u8 = undefined;
            var actual: [pair[0].digest_length]u8 = undefined;
            pair[1].hash(data[0..len], &expected, .{});
            var digest = pair[0].init(.{});
            digest.update(data[0 .. len / 2]);
            var independent = digest;
            digest.update(data[len / 2 .. len]);
            digest.final(&actual);
            try std.testing.expectEqualSlices(u8, &expected, &actual);
            independent.update(data[len / 2 .. len]);
            independent.final(&actual);
            try std.testing.expectEqualSlices(u8, &expected, &actual);
        }
    }
}

//! Isolated compilation keeps SHA kernels optimized even in Debug applications.
const std = @import("std");
comptime {
    if (@sizeOf(std.crypto.hash.Sha1) > 256 or @alignOf(std.crypto.hash.Sha1) > 16) @compileError("Digest state storage is too small");
}
export fn vela_sha1_init(raw: *anyopaque) void {
    const state: *std.crypto.hash.Sha1 = @ptrCast(@alignCast(raw));
    state.* = std.crypto.hash.Sha1.init(.{});
}
export fn vela_sha1_update(raw: *anyopaque, bytes: [*]const u8, len: usize) void {
    const state: *std.crypto.hash.Sha1 = @ptrCast(@alignCast(raw));
    state.update(bytes[0..len]);
}
export fn vela_sha1_final(raw: *anyopaque, out: *[20]u8) void {
    const state: *std.crypto.hash.Sha1 = @ptrCast(@alignCast(raw));
    state.final(out);
}
comptime {
    if (@sizeOf(std.crypto.hash.sha2.Sha256) > 256 or @alignOf(std.crypto.hash.sha2.Sha256) > 16) @compileError("Digest state storage is too small");
}
export fn vela_sha256_init(raw: *anyopaque) void {
    const state: *std.crypto.hash.sha2.Sha256 = @ptrCast(@alignCast(raw));
    state.* = std.crypto.hash.sha2.Sha256.init(.{});
}
export fn vela_sha256_update(raw: *anyopaque, bytes: [*]const u8, len: usize) void {
    const state: *std.crypto.hash.sha2.Sha256 = @ptrCast(@alignCast(raw));
    state.update(bytes[0..len]);
}
export fn vela_sha256_final(raw: *anyopaque, out: *[32]u8) void {
    const state: *std.crypto.hash.sha2.Sha256 = @ptrCast(@alignCast(raw));
    state.final(out);
}
comptime {
    if (@sizeOf(std.crypto.hash.sha2.Sha512) > 256 or @alignOf(std.crypto.hash.sha2.Sha512) > 16) @compileError("Digest state storage is too small");
}
export fn vela_sha512_init(raw: *anyopaque) void {
    const state: *std.crypto.hash.sha2.Sha512 = @ptrCast(@alignCast(raw));
    state.* = std.crypto.hash.sha2.Sha512.init(.{});
}
export fn vela_sha512_update(raw: *anyopaque, bytes: [*]const u8, len: usize) void {
    const state: *std.crypto.hash.sha2.Sha512 = @ptrCast(@alignCast(raw));
    state.update(bytes[0..len]);
}
export fn vela_sha512_final(raw: *anyopaque, out: *[64]u8) void {
    const state: *std.crypto.hash.sha2.Sha512 = @ptrCast(@alignCast(raw));
    state.final(out);
}

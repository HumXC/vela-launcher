//! Compile only: exported functions force every selected backend operation to be analyzed.
//! Never execute this harness; tests use credentials_test.zig and an injected mock.
const std = @import("std");
const credentials = @import("src/core/credentials.zig");

export fn credentials_compile_init() bool {
    var native = credentials.Native.init() catch return false;
    defer native.deinit();
    _ = native.store();
    return true;
}
export fn credentials_compile_put(native: *credentials.Native, reference: [*]const u8, secret: [*]const u8, length: usize) bool {
    native.store().put(reference[0..32], secret[0..length]) catch return false;
    return true;
}
export fn credentials_compile_get(native: *credentials.Native, reference: [*]const u8) bool {
    var secret = native.store().get(std.heap.page_allocator, reference[0..32]) catch return false;
    defer secret.deinit();
    return true;
}
export fn credentials_compile_delete(native: *credentials.Native, reference: [*]const u8) bool {
    native.store().delete(reference[0..32]) catch return false;
    return true;
}

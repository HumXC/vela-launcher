const std = @import("std");
const credentials = @import("credentials.zig");
const testing = std.testing;
const reference = "0123456789abcdef0123456789abcdef";
const other_reference = "fedcba9876543210fedcba9876543210";

// No test initializes Native or invokes any operating-system vault API.
const Mock = struct {
    bytes: [credentials.max_secret_bytes]u8 = undefined,
    length: usize = 0,
    reference: credentials.Reference = undefined,
    present: bool = false,
    calls: usize = 0,
    failure: ?credentials.Error = null,
    invalid_result: ?[]const u8 = null,

    const vtable: credentials.Store.VTable = .{ .put = put, .get = get, .delete = delete };
    fn store(self: *Mock) credentials.Store {
        return .{ .ctx = self, .vtable = &vtable };
    }
    fn from(ctx: *anyopaque) *Mock {
        return @ptrCast(@alignCast(ctx));
    }
    fn enter(self: *Mock) credentials.Error!void {
        self.calls += 1;
        if (self.failure) |err| return err;
    }
    fn deinit(self: *Mock) void {
        std.crypto.secureZero(u8, &self.bytes);
    }
    fn put(ctx: *anyopaque, ref: []const u8, bytes: []const u8) credentials.Error!void {
        const self = from(ctx);
        try self.enter();
        std.crypto.secureZero(u8, &self.bytes);
        @memcpy(self.bytes[0..bytes.len], bytes);
        @memcpy(&self.reference, ref);
        self.length = bytes.len;
        self.present = true;
    }
    fn get(ctx: *anyopaque, allocator: std.mem.Allocator, ref: []const u8) credentials.Error!credentials.Secret {
        const self = from(ctx);
        try self.enter();
        const source = self.invalid_result orelse blk: {
            if (!self.present or !std.mem.eql(u8, &self.reference, ref)) return error.NotFound;
            break :blk self.bytes[0..self.length];
        };
        return .{ .allocator = allocator, .bytes = try allocator.dupe(u8, source) };
    }
    fn delete(ctx: *anyopaque, ref: []const u8) credentials.Error!void {
        const self = from(ctx);
        try self.enter();
        if (!self.present or !std.mem.eql(u8, &self.reference, ref)) return error.NotFound;
        self.deinit();
        self.present = false;
    }
};

test "references require exactly 32 lowercase hexadecimal bytes" {
    try testing.expect(credentials.validateReference(reference));
    try testing.expect(credentials.validateReference(&(comptime @as([32]u8, @splat('a')))));
    const invalid = [_][]const u8{ "", &(comptime @as([31]u8, @splat('a'))), &(comptime @as([33]u8, @splat('a'))), &(comptime @as([32]u8, @splat('A'))), &(comptime @as([32]u8, @splat('g'))), @as([31]u8, @splat('a')) ++ "\x00", @as([31]u8, @splat('a')) ++ " " };
    var mock: Mock = .{};
    defer mock.deinit();
    for (invalid) |ref| {
        try testing.expect(!credentials.validateReference(ref));
        try testing.expectError(error.InvalidReference, mock.store().put(ref, "fixture"));
        try testing.expectError(error.InvalidReference, mock.store().get(testing.allocator, ref));
        try testing.expectError(error.InvalidReference, mock.store().delete(ref));
    }
    try testing.expectEqual(@as(usize, 0), mock.calls);
}

test "invalid secrets and oversized secrets never reach backend" {
    var mock: Mock = .{};
    defer mock.deinit();
    for ([_][]const u8{ "", "abc\x00def", "\xff", "\xc0\xaf", "\xed\xa0\x80" }) |secret| {
        try testing.expectError(error.InvalidSecret, mock.store().put(reference, secret));
    }
    const oversized: [credentials.max_secret_bytes + 1]u8 = @splat('s');
    try testing.expectError(error.TooLarge, mock.store().put(reference, &oversized));
    try testing.expectEqual(@as(usize, 0), mock.calls);
}

test "mock roundtrip replacement isolation and deletion" {
    var mock: Mock = .{};
    defer mock.deinit();
    const store = mock.store();
    try testing.expectError(error.NotFound, store.get(testing.allocator, reference));
    try store.put(reference, "fixture-one");
    var first = try store.get(testing.allocator, reference);
    defer first.deinit();
    try testing.expectEqualStrings("fixture-one", first.bytes);
    first.bytes[0] = 'x';
    var again = try store.get(testing.allocator, reference);
    defer again.deinit();
    try testing.expectEqualStrings("fixture-one", again.bytes);
    try testing.expectError(error.NotFound, store.get(testing.allocator, other_reference));
    try testing.expectError(error.NotFound, store.delete(other_reference));
    try store.put(reference, "fixture-two");
    var replacement = try store.get(testing.allocator, reference);
    defer replacement.deinit();
    try testing.expectEqualStrings("fixture-two", replacement.bytes);
    try store.delete(reference);
    try testing.expectError(error.NotFound, store.get(testing.allocator, reference));
    try testing.expectError(error.NotFound, store.delete(reference));
}

test "16 KiB and multibyte UTF8 are accepted by common contract" {
    var mock: Mock = .{};
    defer mock.deinit();
    const maximum: [credentials.max_secret_bytes]u8 = @splat('s');
    try mock.store().put(reference, &maximum);
    var result = try mock.store().get(testing.allocator, reference);
    defer result.deinit();
    try testing.expectEqualSlices(u8, &maximum, result.bytes);
    try mock.store().put(reference, "fixture-\xe2\x82\xac");
    var utf8 = try mock.store().get(testing.allocator, reference);
    defer utf8.deinit();
    try testing.expectEqualStrings("fixture-\xe2\x82\xac", utf8.bytes);
}

test "backend errors propagate without plaintext fallback" {
    var mock: Mock = .{};
    defer mock.deinit();
    const failures = [_]credentials.Error{ error.Unavailable, error.Denied, error.NotFound, error.InvalidReference, error.InvalidSecret, error.TooLarge, error.StorageFailure, error.OutOfMemory };
    for (failures) |err| {
        mock.failure = err;
        try testing.expectError(err, mock.store().put(reference, "fixture"));
        try testing.expectError(err, mock.store().get(testing.allocator, reference));
        try testing.expectError(err, mock.store().delete(reference));
    }
    try testing.expect(!mock.present);
}

test "get allocation failure is bounded and preserves stored value" {
    var mock: Mock = .{};
    defer mock.deinit();
    try mock.store().put(reference, "fixture");
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, mock.store().get(failing.allocator(), reference));
    var result = try mock.store().get(testing.allocator, reference);
    defer result.deinit();
    try testing.expectEqualStrings("fixture", result.bytes);
}

const WipeAllocator = struct {
    freed: bool = false,
    wiped: bool = false,
    fn allocator(self: *WipeAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(_: *anyopaque, length: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        return testing.allocator.rawAlloc(length, alignment, address);
    }
    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *WipeAllocator = @ptrCast(@alignCast(ctx));
        self.freed = true;
        self.wiped = std.mem.allEqual(u8, bytes, 0);
        testing.allocator.rawFree(bytes, alignment, address);
    }
};

test "Secret deinit wipes bytes before freeing" {
    var observer: WipeAllocator = .{};
    const allocator = observer.allocator();
    var secret: credentials.Secret = .{ .allocator = allocator, .bytes = try allocator.dupe(u8, "fixture-sensitive") };
    secret.deinit();
    try testing.expect(observer.freed);
    try testing.expect(observer.wiped);
    try testing.expectEqual(@as(usize, 0), secret.bytes.len);
    secret.deinit();
}

test "untrusted backend results are validated wiped and freed" {
    var mock: Mock = .{};
    defer mock.deinit();
    const oversized: [credentials.max_secret_bytes + 1]u8 = @splat('s');
    const invalid = [_][]const u8{ "bad\x00value", "\xff", &oversized };
    for (invalid, 0..) |bytes, i| {
        mock.invalid_result = bytes;
        var observer: WipeAllocator = .{};
        try testing.expectError(if (i == 2) error.TooLarge else error.InvalidSecret, mock.store().get(observer.allocator(), reference));
        try testing.expect(observer.freed);
        try testing.expect(observer.wiped);
    }
}

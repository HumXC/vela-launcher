//! Shared native trust-store conversion. The caller owns PEM through easy cleanup.
const std = @import("std");
const A = std.mem.Allocator;
const c = @import("curl").libcurl;
const public_network = @import("public_network.zig");

/// PEM and the callback error slot remain borrowed until easy cleanup.
/// Route is resolved explicitly for this URL; curl never inherits environment.
pub fn configure(easy: *c.CURL, route: *const @import("proxy_policy.zig").Route, ca_path: ?[:0]const u8, pem: []u8, public_address: bool, failure: *?anyerror) !void {
    try set(easy, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 1));
    try set(easy, c.CURLOPT_SSL_VERIFYHOST, @as(c_long, 2));
    try set(easy, c.CURLOPT_PROXY_SSL_VERIFYPEER, @as(c_long, 1));
    try set(easy, c.CURLOPT_PROXY_SSL_VERIFYHOST, @as(c_long, 2));
    try set(easy, c.CURLOPT_PROXY, route.proxy.ptr);
    try set(easy, c.CURLOPT_NOPROXY, @as([*:0]const u8, ""));
    if (route.username.len != 0) {
        try set(easy, c.CURLOPT_PROXYUSERNAME, route.username.ptr);
        try set(easy, c.CURLOPT_PROXYPASSWORD, route.password.ptr);
        // CURLAUTH_ANY is an unsigned-long bitmask; preserve its bits on LLP64.
        try set(easy, c.CURLOPT_PROXYAUTH, @as(c_long, @bitCast(@as(c_ulong, c.CURLAUTH_ANY))));
    }
    if (public_address and route.proxy.len == 0) {
        try set(easy, c.CURLOPT_OPENSOCKETFUNCTION, &public_network.openSocket);
        try set(easy, c.CURLOPT_FRESH_CONNECT, @as(c_long, 1));
        try set(easy, c.CURLOPT_FORBID_REUSE, @as(c_long, 1));
        try set(easy, c.CURLOPT_OPENSOCKETDATA, failure);
    }
    if (ca_path) |path| {
        try set(easy, c.CURLOPT_CAINFO, path.ptr);
        try set(easy, c.CURLOPT_PROXY_CAINFO, path.ptr);
    } else {
        const blob: c.curl_blob = .{ .data = pem.ptr, .len = pem.len, .flags = c.CURL_BLOB_NOCOPY };
        try set(easy, c.CURLOPT_CAINFO_BLOB, &blob);
        try set(easy, c.CURLOPT_PROXY_CAINFO_BLOB, &blob);
    }
}
fn set(easy: *c.CURL, option: c.CURLoption, value: anytype) !void {
    if (c.curl_easy_setopt(easy, option, value) != c.CURLE_OK) return error.CurlOption;
}
fn wipeHeaders(list: ?*c.curl_slist) void {
    var cursor = list;
    while (cursor) |node| : (cursor = node.next) {
        if (node.data != null) std.crypto.secureZero(u8, std.mem.span(node.data));
    }
}
pub fn freeHeaders(list: ?*c.curl_slist) void {
    wipeHeaders(list);
    c.curl_slist_free_all(list);
}
test "curl credential header list bytes are zeroed before libcurl frees them" {
    var headers: *c.curl_slist = c.curl_slist_append(null, "x-api-key: fixture-only-key") orelse return error.OutOfMemory;
    defer c.curl_slist_free_all(headers);
    headers = c.curl_slist_append(headers, "another fixture header") orelse return error.OutOfMemory;
    const first = std.mem.span(headers.data);
    const second = std.mem.span(headers.next.*.data);
    wipeHeaders(headers);
    for (first) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (second) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

pub fn collectNativeCA(a: A, io: std.Io) !std.ArrayList(u8) {
    var native: std.crypto.Certificate.Bundle = .empty;
    defer native.deinit(a);
    try native.rescan(a, io, .now(io, .real));
    const Certificates = struct {
        bundle: *std.crypto.Certificate.Bundle,
        iterator: @TypeOf(native.map.iterator()),
        fn next(self: *@This()) !?[]const u8 {
            const entry = self.iterator.next() orelse return null;
            const start = entry.value_ptr.*;
            const der = try std.crypto.Certificate.der.Element.parse(self.bundle.bytes.items, start);
            return self.bundle.bytes.items[start..der.slice.end];
        }
    };
    var certificates: Certificates = .{ .bundle = &native, .iterator = native.map.iterator() };
    return encodeCertificates(a, &certificates);
}

fn encodeCertificates(a: A, certificates: anytype) !std.ArrayList(u8) {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(a);
    while (try certificates.next()) |bytes| {
        const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
        defer a.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, bytes);
        try output.appendSlice(a, "-----BEGIN CERTIFICATE-----\n");
        var pos: usize = 0;
        while (pos < encoded.len) {
            const end = @min(encoded.len, pos + 64);
            try output.appendSlice(a, encoded[pos..end]);
            try output.append(a, '\n');
            pos = end;
        }
        try output.appendSlice(a, "-----END CERTIFICATE-----\n");
    }
    if (output.items.len == 0) return error.NoTrustedCertificates;
    return output;
}

const FixtureCertificates = struct {
    remaining: usize,
    fail_at_end: bool = false,
    fn next(self: *@This()) !?[]const u8 {
        if (self.remaining == 0) return if (self.fail_at_end) error.InvalidCertificate else null;
        self.remaining -= 1;
        return "fixture DER bytes";
    }
};
fn allocationFixture(a: A) !void {
    var certificates: FixtureCertificates = .{ .remaining = 20 };
    var pem = try encodeCertificates(a, &certificates);
    defer pem.deinit(a);
    try std.testing.expect(std.mem.startsWith(u8, pem.items, "-----BEGIN CERTIFICATE-----\n"));
}
test "native trust PEM releases partial output on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFixture, .{});
}
test "native trust PEM rejects empty trust and releases output after parse failure" {
    var empty: FixtureCertificates = .{ .remaining = 0 };
    try std.testing.expectError(error.NoTrustedCertificates, encodeCertificates(std.testing.allocator, &empty));
    var broken: FixtureCertificates = .{ .remaining = 4, .fail_at_end = true };
    try std.testing.expectError(error.InvalidCertificate, encodeCertificates(std.testing.allocator, &broken));
}

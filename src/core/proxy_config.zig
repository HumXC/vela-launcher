//! Persisted launcher network preferences; never contains proxy passwords.
const std = @import("std");
const credentials = @import("credentials.zig");

pub const Mode = enum { direct, system, manual };
pub const Protocol = enum { http, https, socks5 };
pub const Settings = struct {
    mode: Mode = .direct,
    protocol: Protocol = .http,
    host: []const u8 = "127.0.0.1",
    port: u16 = 7890,
    username: []const u8 = "",
    credential_ref: ?[]const u8 = null,
    bypass: []const u8 = "localhost,127.0.0.1,::1",
};

pub fn validate(value: Settings) !void {
    try text(value.host, 253);
    try text(value.username, 256);
    try text(value.bypass, 4096);
    if (value.credential_ref) |reference| if (!credentials.validateReference(reference)) return error.InvalidProxyCredential;
    if (value.mode != .manual) return;
    if (value.host.len == 0 or value.port == 0) return error.InvalidProxyAddress;
    if (std.mem.indexOfAny(u8, value.host, "/@?# ,;\\") != null) return error.InvalidProxyAddress;
    if (value.host[0] == '[') {
        if (value.host.len < 3 or value.host[value.host.len - 1] != ']') return error.InvalidProxyAddress;
        _ = std.Io.net.Ip6Address.parse(value.host[1 .. value.host.len - 1], 0) catch return error.InvalidProxyAddress;
    } else if (std.mem.indexOfScalar(u8, value.host, ':') != null) {
        _ = std.Io.net.Ip6Address.parse(value.host, 0) catch return error.InvalidProxyAddress;
    } else if (std.mem.indexOfAny(u8, value.host, "[]") != null) return error.InvalidProxyAddress;
    if (value.credential_ref != null and value.username.len == 0) return error.InvalidProxyUsername;
}

fn text(value: []const u8, max: usize) !void {
    if (value.len > max or !std.unicode.utf8ValidateSlice(value)) return error.InvalidProxyAddress;
    for (value) |byte| if (byte < 32 or byte == 127) return error.InvalidProxyAddress;
}

pub fn same(a: Settings, b: Settings) bool {
    return a.mode == b.mode and a.protocol == b.protocol and a.port == b.port and
        std.mem.eql(u8, a.host, b.host) and std.mem.eql(u8, a.username, b.username) and
        std.mem.eql(u8, a.bypass, b.bypass) and optionalEqual(a.credential_ref, b.credential_ref);
}
fn optionalEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |left| return if (b) |right| std.mem.eql(u8, left, right) else false;
    return b == null;
}
/// A saved secret belongs to one endpoint and account, independently of mode/bypass.
pub fn validateCredentialReuse(previous: Settings, next: Settings) !void {
    if (next.credential_ref == null) return;
    if (!optionalEqual(previous.credential_ref, next.credential_ref) or
        previous.protocol != next.protocol or previous.port != next.port or
        !std.mem.eql(u8, previous.host, next.host) or
        !std.mem.eql(u8, previous.username, next.username)) return error.ProxyCredentialsNeedUpdate;
}

pub fn clone(a: std.mem.Allocator, value: Settings) !Settings {
    const host = try a.dupe(u8, value.host);
    errdefer a.free(host);
    const username = try a.dupe(u8, value.username);
    errdefer a.free(username);
    const bypass = try a.dupe(u8, value.bypass);
    errdefer a.free(bypass);
    return .{ .mode = value.mode, .protocol = value.protocol, .host = host, .port = value.port, .username = username, .bypass = bypass, .credential_ref = if (value.credential_ref) |ref| try a.dupe(u8, ref) else null };
}
pub fn deinit(a: std.mem.Allocator, value: Settings) void {
    a.free(value.host);
    a.free(value.username);
    a.free(value.bypass);
    if (value.credential_ref) |ref| a.free(ref);
}

test "proxy settings validate modes addresses and credential references" {
    try validate(.{});
    try validate(.{ .mode = .system });
    try validate(.{ .mode = .manual, .host = "::1" });
    try std.testing.expectError(error.InvalidProxyAddress, validate(.{ .mode = .manual, .host = "http://127.0.0.1" }));
    try std.testing.expectError(error.InvalidProxyAddress, validate(.{ .mode = .manual, .port = 0 }));
    try std.testing.expectError(error.InvalidProxyCredential, validate(.{ .credential_ref = "password" }));
}

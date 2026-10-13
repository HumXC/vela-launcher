//! Conservative, per-socket public endpoint guard for libcurl transfers.
const std = @import("std");
const c = @import("curl").libcurl;

pub fn isPublicV4(ip: [4]u8) bool {
    if (ip[0] == 0 or ip[0] == 10 or ip[0] == 127 or ip[0] >= 224) return false;
    if (ip[0] == 100 and ip[1] >= 64 and ip[1] <= 127) return false;
    if (ip[0] == 169 and ip[1] == 254) return false;
    if (ip[0] == 172 and ip[1] >= 16 and ip[1] <= 31) return false;
    if (ip[0] == 192) {
        if (ip[1] == 168) return false;
        if (ip[1] == 0 and (ip[2] == 0 or ip[2] == 2)) return false;
        if (ip[1] == 88 and ip[2] == 99) return false;
    }
    if (ip[0] == 198) {
        if (ip[1] == 18 or ip[1] == 19) return false;
        if (ip[1] == 51 and ip[2] == 100) return false;
    }
    if (ip[0] == 203 and ip[1] == 0 and ip[2] == 113) return false;
    return true;
}

pub fn isPublicV6(ip: [16]u8) bool {
    if (std.mem.allEqual(u8, ip[0..10], 0) and ip[10] == 0xff and ip[11] == 0xff) {
        return isPublicV4(ip[12..16].*);
    }
    // Only ordinary global unicast; exclude transition and special-use ranges.
    if (ip[0] & 0xe0 != 0x20) return false;
    if (ip[0] == 0x20 and ip[1] == 0x01) {
        if (ip[2] < 2) return false; // IETF assignments, Teredo, benchmarking, ORCHID.
        if (ip[2] == 0x0d and ip[3] == 0xb8) return false;
    }
    if (ip[0] == 0x20 and ip[1] == 0x02) return false; // 6to4 can tunnel private IPv4.
    if (ip[0] == 0x3f and ip[1] == 0xff and ip[2] & 0xf0 == 0) return false;
    return true;
}

pub fn isPublicSocketAddress(address: [*c]const c.curl_sockaddr) bool {
    if (address == null) return false;
    // libcurl documents addr as variable-sized storage, including sockaddr_in6.
    const bytes: [*]const u8 = @ptrCast(&address.*.addr);
    if (address.*.family == c.AF_INET) {
        if (address.*.addrlen != 16) return false;
        return isPublicV4(bytes[4..8].*);
    }
    if (address.*.family == c.AF_INET6) {
        if (address.*.addrlen != 28) return false;
        return isPublicV6(bytes[8..24].*);
    }
    return false;
}

pub fn openSocket(userdata: ?*anyopaque, purpose: c.curlsocktype, address: [*c]c.curl_sockaddr) callconv(.c) c.curl_socket_t {
    const failure: *?anyerror = @ptrCast(@alignCast(userdata orelse return c.CURL_SOCKET_BAD));
    if (failure.* != null) return c.CURL_SOCKET_BAD;
    if (purpose != c.CURLSOCKTYPE_IPCXN or !isPublicSocketAddress(address)) {
        failure.* = error.NonPublicAddress;
        return c.CURL_SOCKET_BAD;
    }
    return c.socket(address.*.family, address.*.socktype, address.*.protocol);
}

test "public IPv4 guard excludes private, shared, loopback, special-use and multicast endpoints" {
    for ([_][4]u8{
        .{ 0, 1, 2, 3 },         .{ 10, 0, 0, 1 },        .{ 100, 64, 0, 1 },      .{ 100, 127, 255, 254 },
        .{ 127, 0, 0, 1 },       .{ 127, 255, 255, 254 }, .{ 169, 254, 169, 254 }, .{ 172, 16, 0, 1 },
        .{ 172, 31, 255, 254 },  .{ 192, 0, 0, 9 },       .{ 192, 0, 2, 1 },       .{ 192, 88, 99, 1 },
        .{ 192, 168, 0, 1 },     .{ 198, 18, 0, 1 },      .{ 198, 19, 255, 254 },  .{ 198, 51, 100, 1 },
        .{ 203, 0, 113, 1 },     .{ 224, 0, 0, 1 },       .{ 239, 255, 255, 254 }, .{ 240, 0, 0, 1 },
        .{ 255, 255, 255, 255 },
    }) |ip| try std.testing.expect(!isPublicV4(ip));
    for ([_][4]u8{
        .{ 1, 1, 1, 1 },        .{ 8, 8, 8, 8 },         .{ 100, 63, 255, 255 }, .{ 100, 128, 0, 0 },
        .{ 172, 15, 255, 255 }, .{ 172, 32, 0, 0 },      .{ 192, 0, 1, 1 },      .{ 198, 17, 255, 255 },
        .{ 198, 20, 0, 0 },     .{ 223, 255, 255, 254 },
    }) |ip| try std.testing.expect(isPublicV4(ip));
}

test "public IPv6 guard excludes local, mapped-private, transition and documentation endpoints" {
    for ([_][16]u8{
        @as([16]u8, @splat(0)),
        @as([15]u8, @splat(0)) ++ [_]u8{1},
        .{ 0xfc, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        .{ 0xfd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        .{ 0xfe, 0xc0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        .{ 0xff, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        .{ 0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0, 127, 0, 0, 1 },
        .{ 0x20, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        .{ 0x20, 1, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        .{ 0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        .{ 0x20, 2, 127, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        .{ 0x3f, 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 0, 0, 1 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 169, 254, 169, 254 },
    }) |ip| try std.testing.expect(!isPublicV6(ip));
    for ([_][16]u8{
        .{ 0x20, 1, 0x48, 0x60, 0x48, 0x60, 0, 0, 0, 0, 0, 0, 0, 0, 0x88, 0x88 },
        .{ 0x26, 6, 0x47, 0, 0x47, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x11, 0x11 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 8, 8, 8, 8 },
    }) |ip| try std.testing.expect(isPublicV6(ip));
}

test "socket guard rejects malformed addresses and unsupported purpose without creating a socket" {
    var failure: ?anyerror = null;
    var address: c.curl_sockaddr = .{ .family = c.AF_INET, .socktype = 1, .addrlen = 16 };
    const bytes = std.mem.asBytes(&address.addr);
    @memcpy(bytes[4..8], &[_]u8{ 127, 0, 0, 1 });
    try std.testing.expectEqual(c.CURL_SOCKET_BAD, openSocket(&failure, c.CURLSOCKTYPE_IPCXN, &address));
    try std.testing.expectEqual(error.NonPublicAddress, failure.?);
    failure = null;
    @memcpy(bytes[4..8], &[_]u8{ 8, 8, 8, 8 });
    address.addrlen = 4;
    try std.testing.expect(!isPublicSocketAddress(&address));
    address.addrlen = 16;
    try std.testing.expectEqual(c.CURL_SOCKET_BAD, openSocket(&failure, c.CURLSOCKTYPE_ACCEPT, &address));
    try std.testing.expectEqual(error.NonPublicAddress, failure.?);
    try std.testing.expect(!isPublicSocketAddress(null));
}

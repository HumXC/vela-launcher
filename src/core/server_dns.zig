//! Minecraft SRV resolution. The caller must retain its original host/port for
//! the handshake and configuration; this owned result is only the dial target.
//!
//! DNS traffic uses cancellable std.Io UDP and the machine's configured servers,
//! never public DNS/DoH. Linux/macOS use std.Io.net.HostName.ResolvConf; Windows
//! uses GetNetworkParams (link iphlpapi). This is deliberately NOT the complete
//! OS resolver policy: macOS scoped/split DNS, Windows NRPT, encrypted-only DNS,
//! search suffixes and mDNS are not implemented. Windows configuration discovery
//! is a synchronous local API, with cancellation checks before/after; no blocking
//! native DNS query or detached worker survives cancellation. Unix config file
//! reads and all network waits are cancellable. Truncated replies fail explicitly
//! (no TCP DNS retry); callers must not treat errors as absent records.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const IpAddress = Io.net.IpAddress;

pub const default_port: u16 = 25565;
pub const max_packet_bytes = 4096;
pub const max_records = 64;

pub const Result = struct {
    allocator: Allocator,
    target_host: []const u8,
    target_port: u16,
    used_srv: bool,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.target_host);
        self.* = undefined;
    }
};

/// Exchange must fill reply and return its length, propagate cancellation, and
/// impose its own time bound. It borrows all slices only until it returns.
pub const Backend = struct {
    context: ?*anyopaque = null,
    exchange: *const fn (?*anyopaque, Io, []const u8, []u8) anyerror!usize,
    /// Fixed seed for reproducible tests; production obtains fresh Io entropy.
    seed: ?u64 = null,
};

pub fn resolve(a: Allocator, io: Io, host: []const u8, port: u16) !Result {
    return resolveWith(a, io, host, port, .{ .exchange = systemExchange });
}

/// Explicit nondefault ports and numeric IPs bypass SRV. An explicit 25565 is
/// indistinguishable from the default with this API and therefore permits SRV.
/// Only NXDOMAIN or a valid response without SRV falls back. Timeout, malformed
/// replies, server failures and a root SRV target remain errors.
pub fn resolveWith(a: Allocator, io: Io, host: []const u8, port: u16, backend: Backend) !Result {
    try io.checkCancel();
    if (port == 0) return error.InvalidPort;
    if (host.len == 0 or host.len > 254) return error.InvalidAddress;
    if (IpAddress.parse(host, port)) |_| {
        return owned(a, host, port, false);
    } else |_| {}
    Io.net.HostName.validate(host) catch return error.InvalidAddress;
    if (port != default_port) return owned(a, host, port, false);
    const bare = std.mem.trimEnd(u8, host, ".");
    var name_buffer: [254]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buffer, "_minecraft._tcp.{s}", .{bare}) catch return error.InvalidAddress;
    const seed = backend.seed orelse seed: {
        var bytes: [8]u8 = undefined;
        io.random(&bytes);
        break :seed std.mem.readInt(u64, &bytes, .little);
    };
    var rng = std.Random.DefaultPrng.init(seed);
    const id = rng.random().int(u16);
    var request: [512]u8 = undefined;
    const query = try makeQuery(&request, name, id);
    var reply: [max_packet_bytes]u8 = undefined;
    const len = try backend.exchange(backend.context, io, query, &reply);
    try io.checkCancel();
    if (len > reply.len) return error.InvalidDnsPacket;
    return (try parseResponse(a, reply[0..len], id, name, rng.random())) orelse try owned(a, host, port, false);
}

fn owned(a: Allocator, host: []const u8, port: u16, srv: bool) !Result {
    return .{ .allocator = a, .target_host = try a.dupe(u8, host), .target_port = port, .used_srv = srv };
}

fn get16(bytes: []const u8, at: usize) !u16 {
    if (at > bytes.len or bytes.len - at < 2) return error.InvalidDnsPacket;
    return std.mem.readInt(u16, bytes[at..][0..2], .big);
}
fn put16(bytes: []u8, at: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[at..][0..2], value, .big);
}

fn makeQuery(buffer: []u8, name: []const u8, id: u16) ![]const u8 {
    @memset(buffer[0..12], 0);
    put16(buffer, 0, id);
    put16(buffer, 2, 0x0100);
    put16(buffer, 4, 1);
    var pos: usize = 12;
    var labels = std.mem.splitScalar(u8, name, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or pos + label.len + 6 > buffer.len) return error.InvalidAddress;
        buffer[pos] = @intCast(label.len);
        pos += 1;
        @memcpy(buffer[pos..][0..label.len], label);
        pos += label.len;
    }
    if (pos - 12 + 1 > 255) return error.InvalidAddress;
    buffer[pos] = 0;
    put16(buffer, pos + 1, 33);
    put16(buffer, pos + 3, 1);
    return buffer[0 .. pos + 5];
}

const Name = struct {
    bytes: [253]u8 = undefined,
    len: usize = 0,
    end: usize,
    fn slice(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Bounded DNS compression decoder: backward pointers only, max 128 hops,
/// 255 wire octets, 63 octets per label, and no embedded NUL/non-host bytes.
fn readName(packet: []const u8, start: usize) !Name {
    var result: Name = .{ .end = start };
    var pos = start;
    var jumped = false;
    var hops: usize = 0;
    var wire_len: usize = 1;
    while (hops < 128) : (hops += 1) {
        if (pos >= packet.len) return error.InvalidDnsPacket;
        const n = packet[pos];
        if (n & 0xc0 == 0xc0) {
            const pointer: usize = (try get16(packet, pos)) & 0x3fff;
            if (pointer >= pos or pointer < 12) return error.InvalidDnsPacket;
            if (!jumped) result.end = pos + 2;
            jumped = true;
            pos = pointer;
            continue;
        }
        if (n & 0xc0 != 0) return error.InvalidDnsPacket;
        pos += 1;
        if (n == 0) {
            if (!jumped) result.end = pos;
            return result;
        }
        wire_len += @as(usize, n) + 1;
        if (wire_len > 255 or pos + n > packet.len) return error.InvalidDnsPacket;
        if (result.len != 0) {
            if (result.len >= result.bytes.len) return error.InvalidDnsPacket;
            result.bytes[result.len] = '.';
            result.len += 1;
        }
        if (result.len + n > result.bytes.len) return error.InvalidDnsPacket;
        for (packet[pos..][0..n]) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.InvalidDnsPacket;
            result.bytes[result.len] = std.ascii.toLower(c);
            result.len += 1;
        }
        pos += n;
    }
    return error.InvalidDnsPacket;
}

const Record = struct { owner: Name, kind: u16, class: u16, begin: usize, end: usize };
const Srv = struct { name: Name, priority: u16, weight: u16, port: u16 };

/// Public wire boundary for fuzzing/offline fixtures. All returned bytes are owned.
pub fn parseResponse(a: Allocator, packet: []const u8, id: u16, question: []const u8, random: std.Random) !?Result {
    if (packet.len < 12 or packet.len > max_packet_bytes or try get16(packet, 0) != id) return error.InvalidDnsPacket;
    const flags = try get16(packet, 2);
    if (flags & 0x8000 == 0 or flags & 0x7800 != 0) return error.InvalidDnsPacket;
    if (flags & 0x0200 != 0) return error.DnsTruncated;
    if (try get16(packet, 4) != 1) return error.InvalidDnsPacket;
    const q = try readName(packet, 12);
    if (!std.ascii.eqlIgnoreCase(q.slice(), question) or try get16(packet, q.end) != 33 or try get16(packet, q.end + 2) != 1) return error.InvalidDnsPacket;
    const answer_count = try get16(packet, 6);
    const total: usize = @as(usize, answer_count) + try get16(packet, 8) + try get16(packet, 10);
    if (total > max_records) return error.TooManyDnsRecords;
    var records: [max_records]Record = undefined;
    var pos = q.end + 4;
    for (0..total) |i| {
        const owner = try readName(packet, pos);
        pos = owner.end;
        const kind = try get16(packet, pos);
        const class = try get16(packet, pos + 2);
        const length = try get16(packet, pos + 8);
        pos += 10;
        if (pos > packet.len or length > packet.len - pos) return error.InvalidDnsPacket;
        records[i] = .{ .owner = owner, .kind = kind, .class = class, .begin = pos, .end = pos + length };
        pos += length;
    }
    if (pos != packet.len) return error.InvalidDnsPacket;
    switch (flags & 15) {
        0 => {},
        3 => return null,
        else => return error.DnsServerFailure,
    }
    // Follow only in-answer CNAMEs. Do not accept unrelated SRV records.
    var canonical = q;
    var depth: usize = 0;
    while (true) {
        var next: ?Name = null;
        for (records[0..answer_count]) |record| {
            if (record.kind != 5 or record.class != 1 or !std.ascii.eqlIgnoreCase(record.owner.slice(), canonical.slice())) continue;
            if (next != null) return error.InvalidDnsPacket;
            const target = try readName(packet, record.begin);
            if (target.end != record.end or target.len == 0) return error.InvalidDnsPacket;
            next = target;
        }
        canonical = next orelse break;
        depth += 1;
        if (depth > 8) return error.InvalidDnsPacket;
    }
    var candidates: [max_records]Srv = undefined;
    var count: usize = 0;
    var priority: u16 = std.math.maxInt(u16);
    for (records[0..answer_count]) |record| {
        if (record.kind != 33 or record.class != 1 or !std.ascii.eqlIgnoreCase(record.owner.slice(), canonical.slice())) continue;
        if (record.end - record.begin < 7) return error.InvalidDnsPacket;
        const target = try readName(packet, record.begin + 6);
        if (target.end != record.end) return error.InvalidDnsPacket;
        // RFC 2782: a root target explicitly declares the service unavailable.
        if (target.len == 0) return error.ServiceUnavailable;
        Io.net.HostName.validate(target.slice()) catch return error.InvalidDnsPacket;
        const p = try get16(packet, record.begin);
        const port = try get16(packet, record.begin + 4);
        if (port == 0) return error.InvalidDnsPacket;
        if (p > priority) continue;
        if (p < priority) {
            count = 0;
            priority = p;
        }
        candidates[count] = .{ .name = target, .priority = p, .weight = try get16(packet, record.begin + 2), .port = port };
        count += 1;
    }
    if (count == 0) return null;
    var total_weight: u32 = 0;
    for (candidates[0..count]) |candidate| total_weight += candidate.weight;
    if (total_weight == 0) {
        const selected = &candidates[random.uintLessThan(usize, count)];
        return try owned(a, selected.name.slice(), selected.port, true);
    }
    // RFC 2782 puts zero weights first and draws inclusively from [0,sum].
    const ticket = random.uintAtMost(u32, total_weight);
    if (ticket == 0) for (candidates[0..count]) |*candidate| {
        if (candidate.weight == 0) return try owned(a, candidate.name.slice(), candidate.port, true);
    };
    var running: u32 = 0;
    for (candidates[0..count]) |*candidate| {
        if (candidate.weight == 0) continue;
        running += candidate.weight;
        if (running >= ticket) return try owned(a, candidate.name.slice(), candidate.port, true);
    }
    unreachable;
}

fn systemExchange(_: ?*anyopaque, io: Io, query: []const u8, reply: []u8) !usize {
    var servers: [3]IpAddress = undefined;
    const count = try configuredServers(io, &servers);
    return exchangeServers(io, servers[0..count], query, reply);
}

/// Real cancellable transport with injected DNS endpoints for loopback tests.
/// At most three servers, 700ms each. Never resets a deadline on stray packets.
pub fn exchangeServers(io: Io, servers: []const IpAddress, query: []const u8, reply: []u8) !usize {
    if (query.len < 12 or query.len > 512 or servers.len > 3) return error.InvalidOptions;
    const count = servers.len;
    var last_error: anyerror = error.DnsUnavailable;
    for (servers[0..count]) |server| {
        try io.checkCancel();
        const local: IpAddress = switch (server) {
            .ip4 => .{ .ip4 = .unspecified(0) },
            .ip6 => .{ .ip6 = .unspecified(0) },
        };
        const socket = local.bind(io, .{ .mode = .dgram, .protocol = .udp }) catch |err| {
            if (err == error.Canceled) return err;
            last_error = err;
            continue;
        };
        defer socket.close(io);
        const timeout = (Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(700), .clock = .awake } }).toDeadline(io);
        socket.sendTimeout(io, &server, query, timeout) catch |err| {
            if (err == error.Canceled) return err;
            last_error = err;
            continue;
        };
        // Bound ignored spoofed/unrelated packets as well as elapsed time.
        var ignored: usize = 0;
        while (ignored < 16) : (ignored += 1) {
            const message = socket.receiveTimeout(io, reply, timeout) catch |err| {
                if (err == error.Canceled) return err;
                last_error = err;
                break;
            };
            if (!message.from.eql(&server)) continue;
            if (message.flags.trunc) return error.DnsTruncated;
            if (message.data.len < 2 or !std.mem.eql(u8, message.data[0..2], query[0..2])) continue;
            return message.data.len;
        }
    }
    return last_error;
}

fn configuredServers(io: Io, servers: *[3]IpAddress) !usize {
    try io.checkCancel();
    if (builtin.os.tag == .windows) return Windows.servers(io, servers);
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.UnsupportedPlatform;
    const config = try Io.net.HostName.ResolvConf.init(io);
    const count = @min(servers.len, config.nameservers().len);
    @memcpy(servers[0..count], config.nameservers()[0..count]);
    return count;
}

const Windows = struct {
    const Address = extern struct { next: ?*Address, ip: [16]u8, mask: [16]u8, context: u32 };
    const Fixed = extern struct {
        host: [132]u8,
        domain: [132]u8,
        current: ?*Address,
        dns: Address,
        node_type: u32,
        scope: [260]u8,
        routing: u32,
        proxy: u32,
        enabled: u32,
    };
    extern "iphlpapi" fn GetNetworkParams(info: ?*Fixed, size: *u32) callconv(.winapi) u32;
    fn servers(io: Io, out: *[3]IpAddress) !usize {
        // Fixed upper bound avoids trusting an arbitrarily large OS allocation.
        var storage: [16384]u8 align(@alignOf(Fixed)) = undefined;
        var size: u32 = storage.len;
        const info: *Fixed = @ptrCast(&storage);
        const status = GetNetworkParams(info, &size);
        try io.checkCancel();
        if (status != 0) return error.DnsUnavailable;
        var node: ?*Address = &info.dns;
        var count: usize = 0;
        var scanned: usize = 0;
        while (node) |address| : (scanned += 1) {
            if (count == out.len or scanned == 64) break;
            const text = std.mem.sliceTo(&address.ip, 0);
            if (IpAddress.parseIp4(text, 53)) |ip| {
                out[count] = ip;
                count += 1;
            } else |_| {}
            node = address.next;
        }
        return count;
    }
};

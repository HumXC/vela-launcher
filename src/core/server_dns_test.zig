const std = @import("std");
const dns = @import("server_dns.zig");
const t = std.testing;
const Io = std.Io;

const Fixture = struct {
    calls: usize = 0,
    mode: enum { records, zero_weights, empty, nxdomain, unavailable, canceled, timeout, bad_pointer, truncated, wrong_question, too_many, short_rdata } = .records,
    fn exchange(context: ?*anyopaque, _: Io, query: []const u8, reply: []u8) !usize {
        const self: *Fixture = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        if (self.mode == .canceled) return error.Canceled;
        if (self.mode == .timeout) return error.Timeout;
        @memcpy(reply[0..query.len], query);
        reply[2] = 0x81;
        reply[3] = if (self.mode == .nxdomain) 0x83 else 0x80;
        if (self.mode == .wrong_question) reply[13] = 'x';
        if (self.mode == .truncated) reply[2] |= 2;
        if (self.mode == .too_many) {
            reply[7] = 65;
            return query.len;
        }
        if (self.mode == .empty or self.mode == .nxdomain or self.mode == .wrong_question or self.mode == .truncated) return query.len;
        var end = query.len;
        if (self.mode == .unavailable) {
            reply[7] = 1;
            append(reply, &end, 0, 0, 0, "");
        } else {
            reply[7] = 3;
            append(reply, &end, 20, 65535, 1111, "ignored.example");
            append(reply, &end, 10, if (self.mode == .zero_weights) 0 else 1, 25570, "one.example");
            append(reply, &end, 10, if (self.mode == .zero_weights) 0 else 3, 25571, "three.example");
        }
        if (self.mode == .bad_pointer) {
            const at: u16 = @intCast(query.len);
            put(reply, query.len, 0xc000 | at);
        }
        if (self.mode == .short_rdata) put(reply, query.len + 10, 2);
        return end;
    }
    fn backend(self: *Fixture, seed: u64) dns.Backend {
        return .{ .context = self, .exchange = exchange, .seed = seed };
    }
};
fn put(buffer: []u8, at: usize, n: u16) void {
    std.mem.writeInt(u16, buffer[at..][0..2], n, .big);
}
fn append(buffer: []u8, end: *usize, priority: u16, weight: u16, port: u16, host: []const u8) void {
    const at = end.*;
    @memset(buffer[at..][0..18], 0);
    put(buffer, at, 0xc00c);
    put(buffer, at + 2, 33);
    put(buffer, at + 4, 1);
    put(buffer, at + 12, priority);
    put(buffer, at + 14, weight);
    put(buffer, at + 16, port);
    var pos = at + 18;
    if (host.len != 0) {
        var labels = std.mem.splitScalar(u8, host, '.');
        while (labels.next()) |label| {
            buffer[pos] = @intCast(label.len);
            pos += 1;
            @memcpy(buffer[pos..][0..label.len], label);
            pos += label.len;
        }
    }
    buffer[pos] = 0;
    pos += 1;
    put(buffer, at + 10, @intCast(pos - at - 12));
    end.* = pos;
}

test "numeric addresses and nondefault ports never query DNS" {
    var fixture: Fixture = .{ .mode = .canceled };
    for ([_][]const u8{ "127.0.0.1", "::1", "2001:db8::1" }) |host| {
        var result = try dns.resolveWith(t.allocator, t.io, host, 25565, fixture.backend(0));
        defer result.deinit();
        try t.expect(!result.used_srv);
        try t.expectEqualStrings(host, result.target_host);
    }
    var result = try dns.resolveWith(t.allocator, t.io, "example.com", 25566, fixture.backend(0));
    defer result.deinit();
    try t.expectEqual(@as(u16, 25566), result.target_port);
    try t.expectEqual(@as(usize, 0), fixture.calls);
    // Instantiate the production path without external network access.
    var production = try dns.resolve(t.allocator, t.io, "127.0.0.1", 25565);
    defer production.deinit();
}

test "missing SRV falls back preserving original host spelling and port" {
    for ([_]@FieldType(Fixture, "mode"){ .empty, .nxdomain }) |mode| {
        var fixture: Fixture = .{ .mode = mode };
        var result = try dns.resolveWith(t.allocator, t.io, "Example.COM.", 25565, fixture.backend(2));
        defer result.deinit();
        try t.expect(!result.used_srv);
        try t.expectEqualStrings("Example.COM.", result.target_host);
        try t.expectEqual(@as(u16, 25565), result.target_port);
    }
}

test "SRV priority dominates weight and result owns selected target" {
    var fixture: Fixture = .{};
    var one: usize = 0;
    var three: usize = 0;
    for (0..500) |seed| {
        var result = try dns.resolveWith(t.allocator, t.io, "example.com", 25565, fixture.backend(seed));
        defer result.deinit();
        try t.expect(result.used_srv);
        if (std.mem.eql(u8, result.target_host, "one.example")) {
            one += 1;
            try t.expectEqual(@as(u16, 25570), result.target_port);
        } else {
            try t.expectEqualStrings("three.example", result.target_host);
            three += 1;
            try t.expectEqual(@as(u16, 25571), result.target_port);
        }
    }
    try t.expect(one > 50 and three > one);
}

test "unavailable malformed cancellation and timeout never silently fall back" {
    const Case = struct { mode: @FieldType(Fixture, "mode"), err: anyerror };
    for ([_]Case{
        .{ .mode = .unavailable, .err = error.ServiceUnavailable },
        .{ .mode = .canceled, .err = error.Canceled },
        .{ .mode = .timeout, .err = error.Timeout },
        .{ .mode = .bad_pointer, .err = error.InvalidDnsPacket },
        .{ .mode = .short_rdata, .err = error.InvalidDnsPacket },
        .{ .mode = .wrong_question, .err = error.InvalidDnsPacket },
        .{ .mode = .truncated, .err = error.DnsTruncated },
        .{ .mode = .too_many, .err = error.TooManyDnsRecords },
    }) |case| {
        var fixture: Fixture = .{ .mode = case.mode };
        try t.expectError(case.err, dns.resolveWith(t.allocator, t.io, "example.com", 25565, fixture.backend(5)));
    }
}

test "bounded parser rejects arbitrary short packets without allocations" {
    var rng = std.Random.DefaultPrng.init(44);
    var bytes: [256]u8 = undefined;
    for (0..256) |len| {
        rng.random().bytes(&bytes);
        const result = dns.parseResponse(t.allocator, bytes[0..len], 1, "_minecraft._tcp.example.com", rng.random()) catch continue;
        if (result) |value| {
            var owned = value;
            owned.deinit();
        }
    }
}

const Local = struct {
    address: Io.net.IpAddress,
    fn exchange(context: ?*anyopaque, io: Io, query: []const u8, reply: []u8) !usize {
        const self: *Local = @ptrCast(@alignCast(context.?));
        return dns.exchangeServers(io, (&self.address)[0..1], query, reply);
    }
    fn run(self: *Local) !dns.Result {
        return dns.resolveWith(t.allocator, t.io, "example.com", 25565, .{ .context = self, .exchange = exchange, .seed = 1 });
    }
};

test "real loopback UDP accepts matching response and cancellation joins blocked receive" {
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    const socket = try address.bind(t.io, .{ .mode = .dgram, .protocol = .udp });
    defer socket.close(t.io);
    var local: Local = .{ .address = socket.address };
    var worker = try t.io.concurrent(Local.run, .{&local});
    var active = true;
    defer if (active) {
        if (worker.cancel(t.io)) |value| {
            var owned_result = value;
            owned_result.deinit();
        } else |_| {}
    };
    var request: [512]u8 = undefined;
    const message = try socket.receiveTimeout(t.io, &request, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    var response: [4096]u8 = undefined;
    var fixture: Fixture = .{};
    const len = try Fixture.exchange(&fixture, t.io, message.data, &response);
    // Wrong transaction ID is ignored even when it comes from the right port.
    response[0] ^= 1;
    try socket.send(t.io, &message.from, response[0..len]);
    response[0] ^= 1;
    try socket.send(t.io, &message.from, response[0..len]);
    const completed = worker.await(t.io);
    active = false;
    var result = try completed;
    defer result.deinit();
    try t.expect(result.used_srv);
    var canceled = try t.io.concurrent(Local.run, .{&local});
    var cancel_active = true;
    defer if (cancel_active) {
        if (canceled.cancel(t.io)) |value| {
            var extra = value;
            extra.deinit();
        } else |_| {}
    };
    _ = try socket.receiveTimeout(t.io, &request, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    const cancellation_result = canceled.cancel(t.io);
    cancel_active = false;
    try t.expectError(error.Canceled, cancellation_result);
}

test "real loopback silent DNS server reaches bounded timeout" {
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    const socket = try address.bind(t.io, .{ .mode = .dgram, .protocol = .udp });
    defer socket.close(t.io);
    var local: Local = .{ .address = socket.address };
    try t.expectError(error.Timeout, local.run());
}

test "all zero SRV weights remain eligible" {
    var seen_one = false;
    var seen_three = false;
    var fixture: Fixture = .{ .mode = .zero_weights };
    for (0..32) |seed| {
        var result = try dns.resolveWith(t.allocator, t.io, "example.com", 25565, fixture.backend(seed));
        defer result.deinit();
        seen_one = seen_one or result.target_port == 25570;
        seen_three = seen_three or result.target_port == 25571;
    }
    try t.expect(seen_one and seen_three);
}

fn allocationCase(a: std.mem.Allocator) !void {
    var fixture: Fixture = .{};
    var result = try dns.resolveWith(a, t.io, "example.com", 25565, fixture.backend(0));
    defer result.deinit();
}

test "selected target allocation failure leaves no ownership behind" {
    try t.checkAllAllocationFailures(t.allocator, allocationCase, .{});
}

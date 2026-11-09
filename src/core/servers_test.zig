const std = @import("std");
const servers = @import("servers.zig");
const config = @import("config.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const valid_json = "{\"version\":{\"name\":\"1.21\",\"protocol\":767},\"players\":{\"online\":3,\"max\":20},\"description\":{\"text\":\"Hello \\u4e16\\u754c\",\"extra\":[{\"text\":\"!\"}]}}";
const endpoint: servers.Endpoint = .{ .host = "virtual.example", .port = 25565 };

fn varInt(w: *std.Io.Writer, v: u32) !void {
    var value = v;
    while (true) {
        const byte: u8 = @intCast(value & 127);
        value >>= 7;
        try w.writeByte(byte | (if (value == 0) @as(u8, 0) else 128));
        if (value == 0) return;
    }
}
fn fixtureBytes(json: []const u8, buffer: []u8) ![]const u8 {
    var body: [servers.max_json_bytes + 6]u8 = undefined;
    var b = std.Io.Writer.fixed(&body);
    try b.writeByte(0);
    try varInt(&b, @intCast(json.len));
    try b.writeAll(json);
    var w = std.Io.Writer.fixed(buffer);
    try varInt(&w, @intCast(b.end));
    try w.writeAll(b.buffered());
    try w.writeAll(&.{ 9, 1, 0, 0, 0, 0, 0, 0, 0, 0 });
    return w.buffered();
}
const Fixture = struct {
    input: []const u8,
    offset: usize = 0,
    output: [512]u8 = undefined,
    output_len: usize = 0,
    reads: usize = 0,
    cancel_at: ?usize = null,
    timeout_at: ?usize = null,
    failure: ?anyerror = null,
    fn adapter(self: *Fixture) servers.Stream {
        return .{ .context = self, .read = read, .write = write, .checkpoint = check, .now_ms = now };
    }
    fn read(ctx: *anyopaque, bytes: []u8) anyerror!usize {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        if (self.failure) |failure| return failure;
        self.reads += 1;
        const n = @min(@min(bytes.len, self.input.len - self.offset), 3);
        @memcpy(bytes[0..n], self.input[self.offset..][0..n]);
        self.offset += n;
        return n;
    }
    fn write(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        @memcpy(self.output[self.output_len..][0..bytes.len], bytes);
        self.output_len += bytes.len;
    }
    fn check(ctx: *anyopaque) anyerror!void {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        if (self.cancel_at) |n| if (self.reads >= n) return error.Canceled;
        if (self.timeout_at) |n| if (self.reads >= n) return error.Timeout;
    }
    fn now(_: *anyopaque) i64 {
        return 0;
    }
};

test "addresses are explicit and separate from port" {
    for ([_][]const u8{ "example.org", "localhost", "mc-1.example.org.", "127.0.0.1", "[::1]", "[2001:db8::1]" }) |host| {
        _ = try servers.validateAddress(host, 25565);
    }
    try std.testing.expectEqualStrings("::1", (try servers.validateAddress("[::1]", 123)).host);
    for ([_][]const u8{ "", "http://host", "host:25565", "::1", "[::1]:25565", "[nope]", "host/path", "host name", "bad\nname", "-host", "host-", "999.1.1.1", "127.1", "01.2.3.4", "host..name", "[fe80::1%bad]" }) |host| {
        try std.testing.expectError(error.InvalidAddress, servers.validateAddress(host, 25565));
    }
    try std.testing.expectError(error.InvalidPort, servers.validateAddress("host", 0));
}

test "server launch selects exact bound instance without modifying selection" {
    const instances = [_]config.Instance{
        .{ .id = "one", .name = "One", .minecraft_version = "1.21" },
        .{ .id = "two", .name = "Two", .minecraft_version = "1.20" },
    };
    const records = [_]config.Server{.{ .id = "s", .name = "S", .address = "[::1]", .port = 1234, .instance_id = "two" }};
    const doc: config.Document = .{ .instances = &instances, .servers = &records, .selected_instance = "one", .selected_server = "s" };
    const launch = (try servers.selectedLaunch(doc)).?;
    try std.testing.expect(launch.instance == &instances[1]);
    try std.testing.expectEqualStrings("::1", launch.address);
    try std.testing.expectEqual(@as(u16, 1234), launch.port);
    try std.testing.expectEqualStrings("one", doc.selected_instance.?);
    var record = records[0];
    record.instance_id = "Two";
    try std.testing.expectError(error.UnboundInstance, servers.selectLaunch(record, &instances));
    try std.testing.expectEqual(@as(?servers.LaunchDescriptor, null), try servers.selectedLaunch(.{}));
    try std.testing.expectError(error.UnknownServer, servers.selectedLaunch(.{ .selected_server = "missing" }));
}

test "status JSON owns UTF8 text structured MOTD and counts" {
    var status = try servers.parseStatus(a, valid_json);
    defer status.deinit();
    try std.testing.expectEqualStrings("Hello \xe4\xb8\x96\xe7\x95\x8c!", status.motd);
    try std.testing.expectEqualStrings("1.21", status.version);
    try std.testing.expectEqual(@as(i32, 767), status.protocol);
    try std.testing.expectEqual(@as(?u32, 3), status.players_online);
    try std.testing.expectEqual(@as(?u32, 20), status.players_max);
    try std.testing.expect(status.description == .object);
    const original = try a.dupe(u8, valid_json);
    var owned = try servers.parseStatus(a, original);
    defer owned.deinit();
    @memset(original, 0);
    a.free(original);
    try std.testing.expectEqualStrings("1.21", owned.version);
    var minimal = try servers.parseStatus(a, "{\"version\":{\"name\":\"x\",\"protocol\":-1}}");
    defer minimal.deinit();
    try std.testing.expectEqual(@as(?u32, null), minimal.players_online);
    try std.testing.expectEqualStrings("", minimal.motd);
}

test "structured JSON rejects malformed fields counts duplicate keys UTF8" {
    for ([_][]const u8{ "{", "{}", "[]", "{\"version\":1}", "{\"version\":{\"name\":1,\"protocol\":1}}", "{\"version\":{\"name\":\"x\",\"protocol\":2147483648}}", "{\"version\":{\"name\":\"x\",\"protocol\":1},\"players\":{\"online\":-1}}", "{\"version\":{\"name\":\"x\",\"protocol\":1},\"version\":{}}" }) |json| {
        if (servers.parseStatus(a, json)) |s| {
            var status = s;
            status.deinit();
            return error.ExpectedFailure;
        } else |err| {
            try std.testing.expect(err == error.InvalidJson or err == error.InvalidStatus);
        }
    }
}

fn pngChunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}
fn pngFixture(buffer: []u8, width: u32) ![]const u8 {
    var w = std.Io.Writer.fixed(buffer);
    try w.writeAll("\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = .{ 0, 0, 0, 64, 0, 0, 0, 64, 8, 0, 0, 0, 0 };
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    try pngChunk(&w, "IHDR", &ihdr);
    var zlib: [4171]u8 = @splat(0);
    zlib[0] = 0x78;
    zlib[1] = 1;
    zlib[2] = 1;
    std.mem.writeInt(u16, zlib[3..5], 4160, .little);
    std.mem.writeInt(u16, zlib[5..7], ~@as(u16, 4160), .little);
    std.mem.writeInt(u32, zlib[4167..4171], std.hash.Adler32.hash(zlib[7..4167]), .big);
    try pngChunk(&w, "IDAT", &zlib);
    try pngChunk(&w, "IEND", "");
    return w.buffered();
}
fn expectBadIcon(json: []const u8) !void {
    var status = try servers.parseStatus(a, json);
    defer status.deinit();
    try std.testing.expect(status.icon == null);
    try std.testing.expect(status.icon_issue != null);
    try std.testing.expectEqualStrings("x", status.version);
}
fn iconJson(allocator: std.mem.Allocator, png: []const u8) ![]u8 {
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(png.len));
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, png);
    return std.fmt.allocPrint(allocator, "{{\"version\":{{\"name\":\"x\",\"protocol\":1}},\"favicon\":\"data:image/png;base64,{s}\"}}", .{encoded});
}

test "base64 PNG icon enforces dimensions checksums and size" {
    var buffer: [5000]u8 = undefined;
    const png = try pngFixture(&buffer, 64);
    const json = try iconJson(a, png);
    defer a.free(json);
    var status = try servers.parseStatus(a, json);
    defer status.deinit();
    try std.testing.expectEqualSlices(u8, png, status.icon.?.png);
    const wrong = try iconJson(a, try pngFixture(&buffer, 128));
    defer a.free(wrong);
    try expectBadIcon(wrong);
    _ = try pngFixture(&buffer, 64);
    buffer[50] ^= 1;
    const corrupt = try iconJson(a, buffer[0..png.len]);
    defer a.free(corrupt);
    try expectBadIcon(corrupt);
    for ([_][]const u8{ "%%%%", "AAAA", "A===", "AAAA=" }) |encoded| {
        const malformed = try std.fmt.allocPrint(a, "{{\"version\":{{\"name\":\"x\",\"protocol\":1}},\"favicon\":\"data:image/png;base64,{s}\"}}", .{encoded});
        defer a.free(malformed);
        try expectBadIcon(malformed);
    }
    const huge = try a.alloc(u8, servers.max_icon_bytes + 1);
    defer a.free(huge);
    @memset(huge, 0);
    const oversized = try iconJson(a, huge);
    defer a.free(oversized);
    try expectBadIcon(oversized);
}

test "fragmented protocol exchanges configured host handshake ping and owned result" {
    var buffer: [4096]u8 = undefined;
    var fixture: Fixture = .{ .input = try fixtureBytes(valid_json, &buffer) };
    var status = try servers.queryStream(a, endpoint, -1, fixture.adapter());
    defer status.deinit();
    try std.testing.expectEqual(@as(?u32, 3), status.players_online);
    try std.testing.expectEqual(@as(?u64, 0), status.latency_ms);
    try std.testing.expect(std.mem.indexOf(u8, fixture.output[0..fixture.output_len], "virtual.example") != null);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff, 0x0f }, fixture.output[2..7]);
    try std.testing.expectEqualSlices(u8, &.{ 9, 1, 0, 0, 0, 0, 0, 0, 0, 0 }, fixture.output[fixture.output_len - 10 .. fixture.output_len]);
}

test "malformed oversized truncated and invalid pong frames" {
    for ([_][]const u8{ &.{0}, &.{0x80}, &.{ 0xff, 0xff, 0xff, 0xff, 0x10 }, &.{ 0x80, 0x80, 0x80, 0x80, 0x80 }, &.{ 1, 1 }, &.{ 2, 0, 4 }, &.{ 2, 0, 0 }, &.{ 0x81, 0x80, 0x08 } }) |bytes| {
        var fixture: Fixture = .{ .input = bytes };
        if (servers.queryStream(a, endpoint, -1, fixture.adapter())) |s| {
            var status = s;
            status.deinit();
            return error.ExpectedFailure;
        } else |err| {
            try std.testing.expect(err == error.InvalidPacket or err == error.InvalidVarInt or err == error.PacketTooLarge or err == error.InvalidJson or err == error.EndOfStream);
        }
    }
    var buffer: [4096]u8 = undefined;
    const bytes = try fixtureBytes(valid_json, &buffer);
    buffer[bytes.len - 1] = 99;
    var fixture: Fixture = .{ .input = bytes };
    var partial = try servers.queryStream(a, endpoint, -1, fixture.adapter());
    defer partial.deinit();
    try std.testing.expectEqual(@as(?u64, null), partial.latency_ms);
    try std.testing.expectEqual(error.InvalidPacket, partial.latency_issue.?);
    try std.testing.expectEqualStrings("1.21", partial.version);
}

test "valid status survives EOF and deadline during pong but not user cancellation" {
    var buffer: [4096]u8 = undefined;
    const bytes = try fixtureBytes(valid_json, &buffer);
    const status_bytes = bytes[0 .. bytes.len - 10];
    var disconnected: Fixture = .{ .input = status_bytes };
    var status = try servers.queryStream(a, endpoint, -1, disconnected.adapter());
    defer status.deinit();
    try std.testing.expectEqual(error.EndOfStream, status.latency_issue.?);
    try std.testing.expectEqual(@as(?u64, null), status.latency_ms);
    try std.testing.expectEqual(@as(?u32, 3), status.players_online);
    var timed: Fixture = .{ .input = status_bytes, .timeout_at = disconnected.reads };
    var partial = try servers.queryStream(a, endpoint, -1, timed.adapter());
    defer partial.deinit();
    try std.testing.expectEqual(error.Timeout, partial.latency_issue.?);
    var canceled: Fixture = .{ .input = status_bytes, .cancel_at = disconnected.reads };
    try std.testing.expectError(error.Canceled, servers.queryStream(a, endpoint, -1, canceled.adapter()));
}

test "stream cancellation deadline and offline errors propagate" {
    var buffer: [4096]u8 = undefined;
    const bytes = try fixtureBytes(valid_json, &buffer);
    var canceled: Fixture = .{ .input = bytes, .cancel_at = 4 };
    try std.testing.expectError(error.Canceled, servers.queryStream(a, endpoint, -1, canceled.adapter()));
    var timed: Fixture = .{ .input = bytes, .timeout_at = 5 };
    try std.testing.expectError(error.Timeout, servers.queryStream(a, endpoint, -1, timed.adapter()));
    var offline: Fixture = .{ .input = bytes, .failure = error.ConnectionRefused };
    try std.testing.expectError(error.ConnectionRefused, servers.queryStream(a, endpoint, -1, offline.adapter()));
    try std.testing.expectEqual(servers.Failure.offline, servers.classifyFailure(error.ConnectionRefused));
    try std.testing.expectEqual(servers.Failure.timeout, servers.classifyFailure(error.Timeout));
    try std.testing.expectEqual(servers.Failure.canceled, servers.classifyFailure(error.Canceled));
}
fn oomParse(allocator: std.mem.Allocator) !void {
    var buffer: [5000]u8 = undefined;
    const json = try iconJson(allocator, try pngFixture(&buffer, 64));
    defer allocator.free(json);
    var status = try servers.parseStatus(allocator, json);
    defer status.deinit();
}
fn oomStream(allocator: std.mem.Allocator) !void {
    var buffer: [4096]u8 = undefined;
    var fixture: Fixture = .{ .input = try fixtureBytes(valid_json, &buffer) };
    var status = try servers.queryStream(allocator, endpoint, -1, fixture.adapter());
    defer status.deinit();
}
test "all allocation failures free JSON icon and protocol ownership" {
    try @import("test_allocations").checkAllAllocationFailures(a, oomParse, .{});
    try @import("test_allocations").checkAllAllocationFailures(a, oomStream, .{});
}

test "resolved dial endpoint preserves configured handshake identity and owned target" {
    const Redirect = struct {
        var target_port: u16 = 0;
        fn resolve(allocator: std.mem.Allocator, _: std.Io, host: []const u8, port: u16) !@import("server_dns.zig").Result {
            try std.testing.expectEqualStrings("virtual.example", host);
            try std.testing.expectEqual(@as(u16, 25565), port);
            return .{ .allocator = allocator, .target_host = try allocator.dupe(u8, "127.0.0.1"), .target_port = target_port, .used_srv = true };
        }
    };
    const ip = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try ip.listen(io, .{});
    defer listener.deinit(io);
    Redirect.target_port = listener.socket.address.getPort();
    var fixture: Loopback = .{ .listener = &listener, .mode = .normal, .expected_host = "virtual.example", .expected_port = 25565 };
    var worker = try io.concurrent(Loopback.run, .{&fixture});
    defer worker.cancel(io) catch {};
    var diagnostics: servers.Diagnostics = .{};
    const record: config.Server = .{ .id = "fixture", .name = "Fixture", .address = "virtual.example", .port = 25565 };
    var status = try servers.query(a, io, record, .{ .timeout_ms = 2000, .resolve_endpoint = Redirect.resolve, .diagnostics = &diagnostics });
    defer status.deinit();
    try worker.await(io);
    try std.testing.expectEqualStrings("127.0.0.1", status.connection.?.host);
    try std.testing.expectEqual(Redirect.target_port, status.connection.?.port);
    try std.testing.expect(status.connection.?.used_srv);
    try std.testing.expectEqual(servers.Phase.complete, diagnostics.phase);
    try std.testing.expect(diagnostics.used_srv);
    try std.testing.expectEqualStrings("virtual.example", record.address);
    try std.testing.expectEqual(@as(u16, 25565), record.port);
}

const Loopback = struct {
    listener: *std.Io.net.Server,
    mode: enum { normal, stall, cancel, no_pong, cancel_pong },
    expected_host: []const u8 = "127.0.0.1",
    expected_port: ?u16 = null,
    cancellation: ?*std.atomic.Value(bool) = null,
    fn run(self: *Loopback) anyerror!void {
        const connection = try self.listener.accept(io);
        defer connection.close(io);
        var read_buffer: [512]u8 = undefined;
        var reader = connection.reader(io, &read_buffer);
        var prefix: [1]u8 = undefined;
        try reader.interface.readSliceAll(&prefix);
        if (prefix[0] >= 128) return error.InvalidFixture;
        var handshake: [128]u8 = undefined;
        try reader.interface.readSliceAll(handshake[0..prefix[0]]);
        if (std.mem.indexOf(u8, handshake[0..prefix[0]], self.expected_host) == null) return error.InvalidFixture;
        if (self.expected_port) |port| if (std.mem.readInt(u16, handshake[prefix[0] - 3 ..][0..2], .big) != port) return error.InvalidFixture;
        var request: [12]u8 = undefined;
        try reader.interface.readSliceAll(&request);
        if (!std.mem.eql(u8, request[0..4], &.{ 1, 0, 9, 1 })) return error.InvalidFixture;
        if (self.mode == .stall or self.mode == .cancel) {
            if (self.cancellation) |token| token.store(true, .release);
            try io.sleep(.fromSeconds(10), .awake);
            return;
        }
        var output: [4096]u8 = undefined;
        const bytes = try fixtureBytes(valid_json, &output);
        @memcpy(output[bytes.len - 8 .. bytes.len], request[4..12]);
        var write_buffer: [512]u8 = undefined;
        var writer = connection.writer(io, &write_buffer);
        try writer.interface.writeAll(if (self.mode == .no_pong or self.mode == .cancel_pong) bytes[0 .. bytes.len - 10] else bytes);
        try writer.interface.flush();
        if (self.mode == .no_pong or self.mode == .cancel_pong) {
            if (self.mode == .cancel_pong) if (self.cancellation) |token| token.store(true, .release);
            try io.sleep(.fromSeconds(10), .awake);
        }
    }
};
fn loopbackCase(mode: @FieldType(Loopback, "mode")) !void {
    const ip = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try ip.listen(io, .{});
    defer listener.deinit(io);
    var token = std.atomic.Value(bool).init(false);
    var fixture: Loopback = .{ .listener = &listener, .mode = mode, .cancellation = if (mode == .cancel or mode == .cancel_pong) &token else null };
    var worker = try io.concurrent(Loopback.run, .{&fixture});
    defer worker.cancel(io) catch |err| {
        if (err != error.Canceled) std.debug.panic("loopback fixture failed: {s}", .{@errorName(err)});
    };
    const record: config.Server = .{ .id = "fixture", .name = "Fixture", .address = "127.0.0.1", .port = listener.socket.address.getPort(), .instance_id = "test" };
    const options: servers.Options = .{ .timeout_ms = if (mode == .normal) 2000 else 100, .cancellation = &token };
    switch (mode) {
        .normal => {
            var status = try servers.query(a, io, record, options);
            defer status.deinit();
            try std.testing.expectEqualStrings("1.21", status.version);
            try worker.await(io);
        },
        .stall => try std.testing.expectError(error.Timeout, servers.query(a, io, record, options)),
        .cancel, .cancel_pong => try std.testing.expectError(error.Canceled, servers.query(a, io, record, options)),
        .no_pong => {
            var status = try servers.query(a, io, record, options);
            defer status.deinit();
            try std.testing.expectEqualStrings("1.21", status.version);
            try std.testing.expectEqual(@as(?u64, null), status.latency_ms);
            try std.testing.expectEqual(error.Timeout, status.latency_issue.?);
        },
    }
}
test "production std.Io.net only loopback normal timeout and atomic cancellation" {
    try loopbackCase(.normal);
    try loopbackCase(.stall);
    try loopbackCase(.cancel);
    try loopbackCase(.no_pong);
    try loopbackCase(.cancel_pong);
}
test "production options and pre-cancellation do not connect" {
    const record: config.Server = .{ .id = "fixture", .name = "Fixture", .address = "127.0.0.1", .instance_id = "test" };
    try std.testing.expectError(error.InvalidOptions, servers.query(a, io, record, .{ .timeout_ms = 0 }));
    var token = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Canceled, servers.query(a, io, record, .{ .cancellation = &token }));
}

test "bounded JSON MOTD and component nesting" {
    const huge = try a.alloc(u8, servers.max_json_bytes + 1);
    defer a.free(huge);
    @memset(huge, ' ');
    try std.testing.expectError(error.PacketTooLarge, servers.parseStatus(a, huge));
    const long = try a.alloc(u8, servers.max_motd_bytes + 1);
    defer a.free(long);
    @memset(long, 'a');
    const json = try std.fmt.allocPrint(a, "{{\"version\":{{\"name\":\"x\",\"protocol\":1}},\"description\":\"{s}\"}}", .{long});
    defer a.free(json);
    var oversized = try servers.parseStatus(a, json);
    defer oversized.deinit();
    try std.testing.expectEqual(error.MotdTooLarge, oversized.motd_issue.?);
    var buffer: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try w.writeAll("{\"version\":{\"name\":\"x\",\"protocol\":1},\"description\":");
    for (0..35) |_| try w.writeByte('[');
    try w.writeAll("\"text\"");
    for (0..35) |_| try w.writeByte(']');
    try w.writeByte('}');
    var nested = try servers.parseStatus(a, w.buffered());
    defer nested.deinit();
    try std.testing.expectEqual(error.InvalidStatus, nested.motd_issue.?);
}

test "production future cancellation interrupts blocked loopback read and joins" {
    const ip = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try ip.listen(io, .{});
    defer listener.deinit(io);
    var ready = std.atomic.Value(bool).init(false);
    var fixture: Loopback = .{ .listener = &listener, .mode = .stall, .cancellation = &ready };
    var fixture_worker = try io.concurrent(Loopback.run, .{&fixture});
    defer fixture_worker.cancel(io) catch |err| {
        if (err != error.Canceled) std.debug.panic("loopback fixture failed: {s}", .{@errorName(err)});
    };
    const record: config.Server = .{ .id = "fixture", .name = "Fixture", .address = "127.0.0.1", .port = listener.socket.address.getPort(), .instance_id = "test" };
    var worker = try io.concurrent(servers.query, .{ a, io, record, servers.Options{ .timeout_ms = 1000 } });
    defer {
        if (worker.cancel(io)) |owned| {
            var status = owned;
            status.deinit();
        } else |_| {}
    }
    const started = std.Io.Clock.now(.awake, io);
    while (!ready.load(.acquire)) {
        if (started.durationTo(std.Io.Clock.now(.awake, io)).toMilliseconds() > 2000) return error.FixtureTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expectError(error.Canceled, worker.cancel(io));
}

test "production refused loopback reports offline" {
    const ip = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try ip.listen(io, .{});
    const port = listener.socket.address.getPort();
    listener.deinit(io);
    const record: config.Server = .{ .id = "fixture", .name = "Fixture", .address = "127.0.0.1", .port = port, .instance_id = "test" };
    try std.testing.expectError(error.ConnectionRefused, servers.query(a, io, record, .{ .timeout_ms = 1000 }));
}

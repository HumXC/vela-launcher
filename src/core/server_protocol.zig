//! Bounded Java status wire protocol, independent of DNS and socket ownership.
const std = @import("std");
const status_model = @import("server_status.zig");
const Allocator = std.mem.Allocator;
pub const max_packet_bytes = 128 * 1024;
pub const Endpoint = struct { host: []const u8, port: u16 };
pub const Stream = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque, []u8) anyerror!usize,
    write: *const fn (*anyopaque, []const u8) anyerror!void,
    checkpoint: *const fn (*anyopaque) anyerror!void,
    now_ms: *const fn (*anyopaque) i64,
    fn readAll(self: Stream, bytes: []u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            try self.checkpoint(self.context);
            const n = try self.read(self.context, bytes[offset..]);
            if (n == 0) return error.EndOfStream;
            if (n > bytes.len - offset) return error.InvalidPacket;
            offset += n;
        }
        try self.checkpoint(self.context);
    }
    fn send(self: Stream, bytes: []const u8) !void {
        try self.checkpoint(self.context);
        try self.write(self.context, bytes);
        try self.checkpoint(self.context);
    }
};
fn writeVarInt(w: *std.Io.Writer, value: u32) !void {
    var remaining = value;
    while (true) {
        const byte: u8 = @intCast(remaining & 127);
        remaining >>= 7;
        try w.writeByte(byte | (if (remaining == 0) @as(u8, 0) else 128));
        if (remaining == 0) return;
    }
}
fn varInt(bytes: []const u8, offset: *usize) !u32 {
    var value: u32 = 0;
    for (0..5) |i| {
        if (offset.* == bytes.len) return error.InvalidPacket;
        const byte = bytes[offset.*];
        offset.* += 1;
        if (i == 4 and byte > 15) return error.InvalidVarInt;
        value |= @as(u32, byte & 127) << @as(u5, @intCast(i * 7));
        if (byte & 128 == 0) return value;
    }
    return error.InvalidVarInt;
}
fn readPacket(a: Allocator, stream: Stream) ![]u8 {
    var prefix: [5]u8 = undefined;
    for (0..5) |i| {
        try stream.readAll(prefix[i..][0..1]);
        if (prefix[i] & 128 == 0) {
            var offset: usize = 0;
            const length = try varInt(prefix[0 .. i + 1], &offset);
            if (length > max_packet_bytes) return error.PacketTooLarge;
            if (length == 0) return error.InvalidPacket;
            const packet = try a.alloc(u8, length);
            errdefer a.free(packet);
            try stream.readAll(packet);
            return packet;
        }
    }
    return error.InvalidVarInt;
}
pub const Exchange = struct { status: status_model.OwnedStatus, started: i64 };
/// Pipeline ping to accommodate servers which wait for it before sending status.
/// The owner can retain a valid status even if the subsequent pong never arrives.
pub fn begin(a: Allocator, endpoint: Endpoint, protocol: i32, stream: Stream) !Exchange {
    if (endpoint.port == 0) return error.InvalidPort;
    if (endpoint.host.len == 0 or endpoint.host.len > 255) return error.InvalidAddress;
    if (std.Io.net.IpAddress.parse(endpoint.host, endpoint.port)) |_| {} else |_| {
        std.Io.net.HostName.validate(endpoint.host) catch return error.InvalidAddress;
    }
    var body: [300]u8 = undefined;
    var writer = std.Io.Writer.fixed(&body);
    try writeVarInt(&writer, 0);
    try writeVarInt(&writer, @bitCast(protocol));
    try writeVarInt(&writer, @intCast(endpoint.host.len));
    try writer.writeAll(endpoint.host);
    try writer.writeInt(u16, endpoint.port, .big);
    try writeVarInt(&writer, 1);
    var header: [5]u8 = undefined;
    var h = std.Io.Writer.fixed(&header);
    try writeVarInt(&h, @intCast(writer.end));
    try stream.send(h.buffered());
    try stream.send(writer.buffered());
    try stream.send(&.{ 1, 0 });
    const started = stream.now_ms(stream.context);
    var ping: [10]u8 = .{ 9, 1, 0, 0, 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(i64, ping[2..10], started, .big);
    try stream.send(&ping);
    const response = try readPacket(a, stream);
    defer a.free(response);
    var offset: usize = 0;
    if (try varInt(response, &offset) != 0) return error.InvalidPacket;
    const json_length = try varInt(response, &offset);
    if (json_length > status_model.max_json_bytes) return error.PacketTooLarge;
    if (json_length != response.len - offset) return error.InvalidPacket;
    return .{ .status = try status_model.parseStatus(a, response[offset..]), .started = started };
}
pub fn finish(a: Allocator, stream: Stream, started: i64) !u64 {
    const pong = try readPacket(a, stream);
    defer a.free(pong);
    if (pong.len != 9 or pong[0] != 1 or std.mem.readInt(i64, pong[1..9], .big) != started) return error.InvalidPacket;
    try stream.checkpoint(stream.context);
    return @intCast(@max(0, stream.now_ms(stream.context) - started));
}
pub fn queryStream(a: Allocator, endpoint: Endpoint, protocol: i32, stream: Stream) !status_model.OwnedStatus {
    var exchange = try begin(a, endpoint, protocol, stream);
    errdefer exchange.status.deinit();
    exchange.status.latency_ms = finish(a, stream, exchange.started) catch |err| blk: {
        if (err == error.Canceled or err == error.OutOfMemory) return err;
        exchange.status.latency_issue = err;
        break :blk null;
    };
    stream.checkpoint(stream.context) catch |err| {
        if (err == error.Canceled or err == error.OutOfMemory) return err;
        exchange.status.latency_ms = null;
        exchange.status.latency_issue = err;
    };
    return exchange.status;
}

//! Configured Minecraft Java 1.7+ server status. Call query only in a background
//! worker (std.Io.concurrent), then join before releasing config or allocator.
//! No discovery, defaults, SRV redirection, or mutation of instances.
const std = @import("std");
const config = @import("config.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const max_packet_bytes = 128 * 1024;
pub const max_json_bytes = 96 * 1024;
pub const max_icon_bytes = 32 * 1024;
pub const max_motd_bytes = 16 * 1024;
pub const State = enum { idle, querying, online, offline, canceled };
pub const Failure = enum { offline, timeout, canceled, invalid_response, invalid_configuration, resource };

pub fn classifyFailure(err: anyerror) Failure {
    return switch (err) {
        error.Canceled => .canceled,
        error.Timeout => .timeout,
        error.OutOfMemory, error.ConcurrencyUnavailable, error.SystemResources => .resource,
        error.InvalidAddress, error.InvalidPort, error.UnboundInstance, error.UnknownServer, error.InvalidOptions => .invalid_configuration,
        error.InvalidVarInt, error.PacketTooLarge, error.InvalidPacket, error.InvalidJson, error.InvalidStatus, error.InvalidIcon, error.MotdTooLarge, error.EndOfStream => .invalid_response,
        else => .offline,
    };
}

pub const Endpoint = struct { host: []const u8, port: u16 };

/// Separate port field only; rejects URL syntax, embedded ports, bare IPv6 and
/// ambiguous numeric IPv4 spellings. Brackets are syntax, not part of the host.
pub fn validateAddress(address: []const u8, port: u16) !Endpoint {
    if (port == 0) return error.InvalidPort;
    if (address.len == 0 or address.len > 255) return error.InvalidAddress;
    if (address[0] == '[') {
        if (address.len < 4 or address[address.len - 1] != ']') return error.InvalidAddress;
        const host = address[1 .. address.len - 1];
        _ = Io.net.IpAddress.parseIp6(host, port) catch return error.InvalidAddress;
        return .{ .host = host, .port = port };
    }
    if (std.mem.indexOfScalar(u8, address, ':') != null) return error.InvalidAddress;
    var numeric = true;
    for (address) |c| if (!std.ascii.isDigit(c) and c != '.') {
        numeric = false;
    };
    if (numeric) {
        _ = Io.net.IpAddress.parseIp4(address, port) catch return error.InvalidAddress;
    } else {
        Io.net.HostName.validate(address) catch return error.InvalidAddress;
    }
    return .{ .host = address, .port = port };
}

pub const LaunchDescriptor = struct {
    instance: *const config.Instance,
    address: []const u8,
    port: u16,
};

/// Borrowed descriptor. Preserve config storage through launch construction.
/// Pass address/port into game_launch.LaunchOptions.server at the call site.
pub fn selectLaunch(server: config.Server, instances: []const config.Instance) !LaunchDescriptor {
    const endpoint = try validateAddress(server.address, server.port);
    const instance_id = server.instance_id orelse return error.UnboundInstance;
    for (instances) |*instance| {
        if (std.mem.eql(u8, instance.id, instance_id))
            return .{ .instance = instance, .address = endpoint.host, .port = endpoint.port };
    }
    return error.UnboundInstance;
}

pub fn selectedLaunch(doc: config.Document) !?LaunchDescriptor {
    const id = doc.selected_server orelse return null;
    for (doc.servers) |server| {
        if (std.mem.eql(u8, server.id, id)) return try selectLaunch(server, doc.instances);
    }
    return error.UnknownServer;
}

pub const Options = struct {
    timeout_ms: u32 = 3000,
    protocol_version: i32 = -1,
    /// Optional shared token; caller must keep it alive until query is joined.
    cancellation: ?*const std.atomic.Value(bool) = null,
};

pub const OwnedStatus = struct {
    arena: std.heap.ArenaAllocator,
    version: []const u8,
    protocol: i32,
    players_online: ?u32,
    players_max: ?u32,
    motd: []const u8,
    /// Full structured text component for future rich presentation/translation.
    description: std.json.Value,
    /// Structurally validated 64x64 PNG. UI decoder must still reject bad IDAT.
    icon_png: ?[]const u8,
    latency_ms: u64 = 0,

    pub fn deinit(self: *OwnedStatus) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn object(value: std.json.Value) !std.json.ObjectMap {
    return if (value == .object) value.object else error.InvalidStatus;
}
fn string(value: std.json.Value) ![]const u8 {
    if (value != .string or !std.unicode.utf8ValidateSlice(value.string)) return error.InvalidStatus;
    return value.string;
}
fn count(value: std.json.Value) !u32 {
    if (value != .integer or value.integer < 0 or value.integer > std.math.maxInt(u32)) return error.InvalidStatus;
    return @intCast(value.integer);
}
fn appendText(a: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidStatus;
    if (text.len > max_motd_bytes - out.items.len) return error.MotdTooLarge;
    try out.appendSlice(a, text);
}
fn flatten(a: Allocator, out: *std.ArrayList(u8), value: std.json.Value, depth: u8) anyerror!void {
    if (depth > 32) return error.InvalidStatus;
    switch (value) {
        .string => |text| try appendText(a, out, text),
        .array => |items| for (items.items) |item| try flatten(a, out, item, depth + 1),
        .object => |fields| {
            if (fields.get("text")) |text| try appendText(a, out, try string(text)) else if (fields.get("translate")) |key| try appendText(a, out, try string(key));
            if (fields.get("extra")) |extra| {
                if (extra != .array) return error.InvalidStatus;
                try flatten(a, out, extra, depth + 1);
            }
        },
        else => return error.InvalidStatus,
    }
}

fn validatePng(bytes: []const u8) !void {
    if (bytes.len > max_icon_bytes or bytes.len < 57 or !std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return error.InvalidIcon;
    var offset: usize = 8;
    var chunks: usize = 0;
    var idat = false;
    while (offset < bytes.len) {
        if (bytes.len - offset < 12) return error.InvalidIcon;
        const size = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        if (size > bytes.len - offset - 12) return error.InvalidIcon;
        const kind = bytes[offset + 4 ..][0..4];
        const data = bytes[offset + 8 ..][0..size];
        const crc = std.mem.readInt(u32, bytes[offset + 8 + size ..][0..4], .big);
        if (std.hash.Crc32.hash(bytes[offset + 4 ..][0 .. size + 4]) != crc) return error.InvalidIcon;
        if (chunks == 0) {
            if (!std.mem.eql(u8, kind, "IHDR") or size != 13) return error.InvalidIcon;
            if (std.mem.readInt(u32, data[0..4], .big) != 64 or std.mem.readInt(u32, data[4..8], .big) != 64) return error.InvalidIcon;
            const valid_depth = switch (data[9]) {
                0 => data[8] == 1 or data[8] == 2 or data[8] == 4 or data[8] == 8 or data[8] == 16,
                2, 4, 6 => data[8] == 8 or data[8] == 16,
                3 => data[8] == 1 or data[8] == 2 or data[8] == 4 or data[8] == 8,
                else => false,
            };
            if (!valid_depth or data[10] != 0 or data[11] != 0 or data[12] > 1) return error.InvalidIcon;
        } else if (std.mem.eql(u8, kind, "IHDR")) return error.InvalidIcon;
        if (std.mem.eql(u8, kind, "IDAT")) idat = true;
        offset += size + 12;
        chunks += 1;
        if (std.mem.eql(u8, kind, "IEND")) {
            if (size != 0 or !idat or offset != bytes.len) return error.InvalidIcon;
            return;
        }
    }
    return error.InvalidIcon;
}

fn decodeIcon(a: Allocator, value: std.json.Value) ![]const u8 {
    const uri = try string(value);
    const prefix = "data:image/png;base64,";
    if (!std.mem.startsWith(u8, uri, prefix)) return error.InvalidIcon;
    const encoded = uri[prefix.len..];
    if (encoded.len > std.base64.standard.Encoder.calcSize(max_icon_bytes)) return error.InvalidIcon;
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(encoded) catch return error.InvalidIcon;
    if (size > max_icon_bytes) return error.InvalidIcon;
    const bytes = try a.alloc(u8, size);
    decoder.decode(bytes, encoded) catch return error.InvalidIcon;
    try validatePng(bytes);
    return bytes;
}

/// Owns every returned field independently of input JSON/config/transport.
pub fn parseStatus(allocator: Allocator, json: []const u8) !OwnedStatus {
    if (json.len > max_json_bytes) return error.PacketTooLarge;
    if (!std.unicode.utf8ValidateSlice(json)) return error.InvalidJson;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const value = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{
        .allocate = .alloc_always,
        .max_value_len = max_json_bytes,
    }) catch |err| return if (err == error.OutOfMemory) err else error.InvalidJson;
    const root = try object(value);
    const version = try object(root.get("version") orelse return error.InvalidStatus);
    const name = try string(version.get("name") orelse return error.InvalidStatus);
    if (name.len > 1024) return error.InvalidStatus;
    const protocol = version.get("protocol") orelse return error.InvalidStatus;
    if (protocol != .integer or protocol.integer < std.math.minInt(i32) or protocol.integer > std.math.maxInt(i32)) return error.InvalidStatus;
    var online: ?u32 = null;
    var maximum: ?u32 = null;
    if (root.get("players")) |players_value| {
        const players = try object(players_value);
        if (players.get("online")) |v| online = try count(v);
        if (players.get("max")) |v| maximum = try count(v);
    }
    const description = root.get("description") orelse std.json.Value{ .string = "" };
    var motd: std.ArrayList(u8) = .empty;
    try flatten(a, &motd, description, 0);
    const icon = if (root.get("favicon")) |v| try decodeIcon(a, v) else null;
    return .{ .arena = arena, .version = name, .protocol = @intCast(protocol.integer), .players_online = online, .players_max = maximum, .motd = motd.items, .description = description, .icon_png = icon };
}

/// Injectable bounded stream. read returns 0 at EOF; write consumes all bytes.
/// checkpoint must honor cancellation and an absolute deadline before blocking.
/// Implementations retain ownership; queryStream never closes the adapter.
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

fn writeVarInt(writer: *Io.Writer, value: u32) !void {
    var remaining = value;
    while (true) {
        const byte: u8 = @intCast(remaining & 0x7f);
        remaining >>= 7;
        try writer.writeByte(byte | (if (remaining == 0) @as(u8, 0) else 0x80));
        if (remaining == 0) return;
    }
}
fn varIntBytes(bytes: []const u8, offset: *usize) !u32 {
    var value: u32 = 0;
    for (0..5) |i| {
        if (offset.* == bytes.len) return error.InvalidPacket;
        const b = bytes[offset.*];
        offset.* += 1;
        if (i == 4 and b > 0x0f) return error.InvalidVarInt;
        value |= @as(u32, b & 0x7f) << @as(u5, @intCast(i * 7));
        if (b & 0x80 == 0) return value;
    }
    return error.InvalidVarInt;
}
fn readPacket(a: Allocator, stream: Stream) ![]u8 {
    var prefix: [5]u8 = undefined;
    for (0..5) |i| {
        try stream.readAll(prefix[i..][0..1]);
        if (prefix[i] & 0x80 == 0) {
            var offset: usize = 0;
            const length = try varIntBytes(prefix[0 .. i + 1], &offset);
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

pub fn queryStream(a: Allocator, endpoint: Endpoint, protocol: i32, stream: Stream) !OwnedStatus {
    if (endpoint.port == 0) return error.InvalidPort;
    if (endpoint.host.len == 0 or endpoint.host.len > 255) return error.InvalidAddress;
    if (std.mem.indexOfScalar(u8, endpoint.host, ':') != null) {
        _ = Io.net.IpAddress.parseIp6(endpoint.host, endpoint.port) catch return error.InvalidAddress;
    } else {
        _ = try validateAddress(endpoint.host, endpoint.port);
    }
    var body: [300]u8 = undefined;
    var w = Io.Writer.fixed(&body);
    try writeVarInt(&w, 0);
    try writeVarInt(&w, @bitCast(protocol));
    try writeVarInt(&w, @intCast(endpoint.host.len));
    try w.writeAll(endpoint.host);
    try w.writeInt(u16, endpoint.port, .big);
    try writeVarInt(&w, 1);
    var header: [5]u8 = undefined;
    var h = Io.Writer.fixed(&header);
    try writeVarInt(&h, @intCast(w.end));
    try stream.send(h.buffered());
    try stream.send(w.buffered());
    try stream.send(&.{ 1, 0 });
    // Send ping before waiting: some servers defer status until ping arrives.
    const started = stream.now_ms(stream.context);
    var ping: [10]u8 = .{ 9, 1, 0, 0, 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(i64, ping[2..10], started, .big);
    try stream.send(&ping);
    const response = try readPacket(a, stream);
    defer a.free(response);
    var offset: usize = 0;
    if (try varIntBytes(response, &offset) != 0) return error.InvalidPacket;
    const json_length = try varIntBytes(response, &offset);
    if (json_length > max_json_bytes) return error.PacketTooLarge;
    if (json_length != response.len - offset) return error.InvalidPacket;
    var status = try parseStatus(a, response[offset..]);
    errdefer status.deinit();
    const pong = try readPacket(a, stream);
    defer a.free(pong);
    if (pong.len != 9 or pong[0] != 1 or !std.mem.eql(u8, pong[1..], ping[2..])) return error.InvalidPacket;
    try stream.checkpoint(stream.context);
    status.latency_ms = @intCast(@max(0, stream.now_ms(stream.context) - started));
    return status;
}

const Native = struct {
    io: Io,
    reader: Io.net.Stream.Reader,
    writer: Io.net.Stream.Writer,
    options: Options,
    fn adapter(self: *Native) Stream {
        return .{ .context = self, .read = read, .write = write, .checkpoint = checkpoint, .now_ms = now };
    }
    fn read(ctx: *anyopaque, bytes: []u8) anyerror!usize {
        const self: *Native = @ptrCast(@alignCast(ctx));
        return self.reader.interface.readSliceShort(bytes) catch |err| return self.reader.err orelse err;
    }
    fn write(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *Native = @ptrCast(@alignCast(ctx));
        self.writer.interface.writeAll(bytes) catch |err| return self.writer.err orelse err;
        self.writer.interface.flush() catch |err| return self.writer.err orelse err;
    }
    fn checkpoint(ctx: *anyopaque) anyerror!void {
        const self: *Native = @ptrCast(@alignCast(ctx));
        try self.io.checkCancel();
        if (self.options.cancellation) |token| if (token.load(.acquire)) return error.Canceled;
    }
    fn now(ctx: *anyopaque) i64 {
        const self: *Native = @ptrCast(@alignCast(ctx));
        return Io.Clock.now(.awake, self.io).toMilliseconds();
    }
};

fn network(a: Allocator, io: Io, endpoint: Endpoint, options: Options) anyerror!OwnedStatus {
    try io.checkCancel();
    const socket = if (Io.net.IpAddress.parse(endpoint.host, endpoint.port)) |ip|
        try ip.connect(io, .{ .mode = .stream })
    else |_|
        try (Io.net.HostName{ .bytes = endpoint.host }).connect(io, endpoint.port, .{ .mode = .stream });
    defer socket.close(io);
    var read_buffer: [1024]u8 = undefined;
    var write_buffer: [512]u8 = undefined;
    var native: Native = .{ .io = io, .reader = socket.reader(io, &read_buffer), .writer = socket.writer(io, &write_buffer), .options = options };
    return queryStream(a, endpoint, options.protocol_version, native.adapter());
}
fn guard(io: Io, options: Options, start: Io.Timestamp) anyerror!void {
    while (true) {
        if (options.cancellation) |token| if (token.load(.acquire)) return error.Canceled;
        const elapsed = start.durationTo(Io.Clock.now(.awake, io)).toMilliseconds();
        if (elapsed >= options.timeout_ms) return error.Timeout;
        try io.sleep(.fromMilliseconds(@min(10, @as(i64, options.timeout_ms) - elapsed)), .awake);
    }
}

/// Blocking worker API. Entire DNS/connect/write/read/parse operation has a total
/// deadline; cancellation interrupts std.Io network calls and joins all children.
/// Use a thread-safe allocator; underlying I/O must support concurrency.
pub fn query(a: Allocator, io: Io, server: config.Server, options: Options) !OwnedStatus {
    const endpoint = try validateAddress(server.address, server.port);
    if (options.timeout_ms == 0 or options.timeout_ms > 60_000) return error.InvalidOptions;
    if (options.cancellation) |token| if (token.load(.acquire)) return error.Canceled;
    const started = Io.Clock.now(.awake, io);
    const Result = union(enum) { network: anyerror!OwnedStatus, guard: anyerror!void };
    var results: [2]Result = undefined;
    var select = Io.Select(Result).init(io, &results);
    defer while (select.cancel()) |result| {
        if (result == .network) {
            if (result.network) |owned| {
                var status = owned;
                status.deinit();
            } else |_| {}
        }
    };
    try select.concurrent(.network, network, .{ a, io, endpoint, options });
    try select.concurrent(.guard, guard, .{ io, options, started });
    return switch (try select.await()) {
        .network => |status| status,
        .guard => |result| blk: {
            try result;
            break :blk error.Timeout;
        },
    };
}

test {
    _ = @import("servers_test.zig");
}

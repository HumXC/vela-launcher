//! Configured Minecraft Java 1.7+ server status. Call query only in a background
//! worker (std.Io.concurrent), then join before releasing config or allocator.
//! System DNS SRV routing and bounded TCP queries; configuration is never mutated.
const std = @import("std");
const wire = @import("server_protocol.zig");
const dns = @import("server_dns.zig");
const config = @import("config.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const max_packet_bytes = wire.max_packet_bytes;
pub const max_json_bytes = @import("server_status.zig").max_json_bytes;
pub const max_icon_bytes = @import("server_icon.zig").max_png_bytes;
pub const max_motd_bytes = @import("server_status.zig").max_motd_bytes;
pub const State = enum { idle, querying, online, offline, canceled };
pub const Failure = enum { offline, timeout, canceled, invalid_response, invalid_configuration, resource };

pub fn classifyFailure(err: anyerror) Failure {
    return switch (err) {
        error.Canceled => .canceled,
        error.Timeout => .timeout,
        error.OutOfMemory, error.ConcurrencyUnavailable, error.SystemResources => .resource,
        error.InvalidAddress, error.InvalidPort, error.UnboundInstance, error.UnknownServer, error.InvalidOptions => .invalid_configuration,
        error.InvalidVarInt, error.PacketTooLarge, error.InvalidPacket, error.InvalidJson, error.InvalidStatus, error.InvalidDnsPacket, error.DnsTruncated, error.TooManyDnsRecords, error.EndOfStream => .invalid_response,
        else => .offline,
    };
}

pub const Endpoint = wire.Endpoint;

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
    /// Written only after child work is joined, including failed queries.
    diagnostics: ?*Diagnostics = null,
    resolve_endpoint: *const fn (Allocator, Io, []const u8, u16) anyerror!dns.Result = dns.resolve,
};

pub const OwnedStatus = @import("server_status.zig").OwnedStatus;
pub const parseStatus = @import("server_status.zig").parseStatus;
pub const Stream = wire.Stream;
pub const queryStream = wire.queryStream;

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

pub const Phase = enum { validation, resolving, connecting, status, pong, complete };
pub const Diagnostics = struct { phase: Phase = .validation, elapsed_ms: u64 = 0, used_srv: bool = false };
const Progress = struct {
    diagnostics: Diagnostics = .{},
    status: ?OwnedStatus = null,
};
fn network(a: Allocator, io: Io, endpoint: Endpoint, options: Options, progress: *Progress) anyerror!void {
    try io.checkCancel();
    progress.diagnostics.phase = .resolving;
    var resolved = try options.resolve_endpoint(a, io, endpoint.host, endpoint.port);
    defer resolved.deinit();
    progress.diagnostics.used_srv = resolved.used_srv;
    progress.diagnostics.phase = .connecting;
    const socket = if (Io.net.IpAddress.parse(resolved.target_host, resolved.target_port)) |ip|
        try ip.connect(io, .{ .mode = .stream })
    else |_|
        try (Io.net.HostName{ .bytes = resolved.target_host }).connect(io, resolved.target_port, .{ .mode = .stream });
    defer socket.close(io);
    var read_buffer: [1024]u8 = undefined;
    var write_buffer: [512]u8 = undefined;
    var native: Native = .{ .io = io, .reader = socket.reader(io, &read_buffer), .writer = socket.writer(io, &write_buffer), .options = options };
    progress.diagnostics.phase = .status;
    const exchange = try wire.begin(a, endpoint, options.protocol_version, native.adapter());
    progress.status = exchange.status;
    const status = &progress.status.?;
    status.connection = .{ .host = try status.arena.allocator().dupe(u8, resolved.target_host), .port = resolved.target_port, .used_srv = resolved.used_srv };
    progress.diagnostics.phase = .pong;
    status.latency_ms = wire.finish(a, native.adapter(), exchange.started) catch |err| blk: {
        if (err == error.Canceled or err == error.OutOfMemory) return err;
        status.latency_issue = err;
        break :blk null;
    };
    try Native.checkpoint(&native);
    progress.diagnostics.phase = .complete;
}
fn guard(io: Io, options: Options, start: Io.Timestamp) anyerror!void {
    while (true) {
        if (options.cancellation) |token| if (token.load(.acquire)) return error.Canceled;
        const elapsed = start.durationTo(Io.Clock.now(.awake, io)).toMilliseconds();
        if (elapsed >= options.timeout_ms) return error.Timeout;
        try io.sleep(.fromMilliseconds(@min(10, @as(i64, options.timeout_ms) - elapsed)), .awake);
    }
}

/// Total DNS/connect/status/pong deadline. A valid status survives a pong timeout;
/// user cancellation always wins and all children are joined before publication.
pub fn query(a: Allocator, io: Io, server: config.Server, options: Options) !OwnedStatus {
    const started = Io.Clock.now(.awake, io);
    var progress: Progress = .{};
    defer {
        progress.diagnostics.elapsed_ms = @intCast(@max(0, started.durationTo(Io.Clock.now(.awake, io)).toMilliseconds()));
        if (options.diagnostics) |output| output.* = progress.diagnostics;
        if (progress.status) |*status| status.deinit();
    }
    const endpoint = try validateAddress(server.address, server.port);
    if (options.timeout_ms == 0 or options.timeout_ms > 60_000) return error.InvalidOptions;
    if (options.cancellation) |token| if (token.load(.acquire)) return error.Canceled;
    const Result = union(enum) { network: anyerror!void, guard: anyerror!void };
    var results: [2]Result = undefined;
    var select = Io.Select(Result).init(io, &results);
    defer while (select.cancel()) |_| {};
    try select.concurrent(.network, network, .{ a, io, endpoint, options, &progress });
    try select.concurrent(.guard, guard, .{ io, options, started });
    const result = try select.await();
    // Progress is worker-owned until this join; no unsynchronized status reads.
    while (select.cancel()) |_| {}
    try io.checkCancel();
    if (options.cancellation) |token| if (token.load(.acquire)) return error.Canceled;
    switch (result) {
        .network => |value| try value,
        .guard => |value| value catch |err| {
            if (err != error.Timeout or progress.status == null or (progress.diagnostics.phase != .pong and progress.diagnostics.phase != .complete)) return err;
            if (progress.status.?.latency_ms == null) progress.status.?.latency_issue = error.Timeout;
        },
    }
    const status = progress.status orelse return error.InvalidStatus;
    progress.status = null;
    return status;
}

test {
    _ = @import("servers_test.zig");
    _ = @import("server_dns_test.zig");
    _ = @import("server_status_test.zig");
}

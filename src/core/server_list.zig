//! Minecraft Java servers.dat. Preserve the complete NBT tree and only append.
const std = @import("std");
const nbt = @import("nbt");
const fs = @import("content_fs.zig");
const limit = 4 * 1024 * 1024;
const filename = "servers.dat";
const options: nbt.Options = .{ .max_input_bytes = limit, .max_output_bytes = limit, .max_decompressed_bytes = limit, .max_total_decoded_bytes = 16 * 1024 * 1024, .max_depth = 32, .max_collection_length = 65536, .max_compound_entries = 65536, .max_string_bytes = 65535, .reject_trailing_bytes = true };
pub const Server = struct { name: []const u8, host: []const u8, port: u16 };
const Endpoint = struct { host: []const u8, port: u16 };
fn endpoint(text: []const u8) ?Endpoint {
    if (text.len == 0) return null;
    var host = text;
    var port: u16 = 25565;
    if (text[0] == '[') {
        const end = std.mem.indexOfScalar(u8, text, ']') orelse return null;
        host = text[1..end];
        if (end + 1 < text.len) {
            if (text[end + 1] != ':') return null;
            port = std.fmt.parseInt(u16, text[end + 2 ..], 10) catch return null;
        }
    } else if (std.mem.count(u8, text, ":") == 1) {
        const split = std.mem.indexOfScalar(u8, text, ':').?;
        host = text[0..split];
        port = std.fmt.parseInt(u16, text[split + 1 ..], 10) catch return null;
    }
    if (host.len == 0 or port == 0) return null;
    return .{ .host = host, .port = port };
}
fn sameAddress(text: []const u8, server: Server) bool {
    const existing = endpoint(text) orelse return false;
    if (existing.port != server.port) return false;
    if (std.mem.indexOfScalar(u8, server.host, ':') != null) {
        const left = std.Io.net.IpAddress.parseIp6(existing.host, existing.port) catch return false;
        const right = std.Io.net.IpAddress.parseIp6(server.host, server.port) catch return false;
        return left.eql(&right);
    }
    return std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, existing.host, "."), std.mem.trimEnd(u8, server.host, "."));
}
/// null means already present: the original file must not be rewritten.
fn appended(a: std.mem.Allocator, original: ?[]const u8, server: Server) !?[]u8 {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var doc: nbt.Document = if (original) |bytes| try nbt.parse(scratch, bytes, options) else .{ .name = @constCast(""), .root = .{ .compound = .{ .entries = &.{} } } };
    if (doc.root != .compound) return error.InvalidServerList;
    var found: ?*nbt.Tag = null;
    for (doc.root.compound.entries) |*entry| {
        if (std.mem.eql(u8, entry.name, "servers")) {
            if (found != null) return error.InvalidServerList;
            found = &entry.value;
        }
    }
    if (found == null) {
        const entries = try scratch.alloc(nbt.Entry, doc.root.compound.entries.len + 1);
        @memcpy(entries[0..doc.root.compound.entries.len], doc.root.compound.entries);
        entries[entries.len - 1] = .{ .name = @constCast("servers"), .value = .{ .list = .{ .element_type = .compound, .items = &.{} } } };
        doc.root.compound.entries = entries;
        found = &entries[entries.len - 1].value;
    }
    const tag = found.?;
    if (tag.* != .list or (tag.list.element_type != .compound and !(tag.list.element_type == .end and tag.list.items.len == 0))) return error.InvalidServerList;
    for (tag.list.items) |item| {
        const ip = item.compound.get("ip") orelse continue;
        if (ip.* == .string and sameAddress(ip.string, server)) return null;
    }
    const ip = if (std.mem.indexOfScalar(u8, server.host, ':') != null)
        try std.fmt.allocPrint(scratch, "[{s}]:{d}", .{ server.host, server.port })
    else if (server.port == 25565) try scratch.dupe(u8, server.host) else try std.fmt.allocPrint(scratch, "{s}:{d}", .{ server.host, server.port });
    const fields = try scratch.alloc(nbt.Entry, 2);
    fields[0] = .{ .name = @constCast("name"), .value = .{ .string = @constCast(server.name) } };
    fields[1] = .{ .name = @constCast("ip"), .value = .{ .string = ip } };
    const items = try scratch.alloc(nbt.Tag, tag.list.items.len + 1);
    @memcpy(items[0..tag.list.items.len], tag.list.items);
    items[items.len - 1] = .{ .compound = .{ .entries = fields } };
    tag.list = .{ .element_type = .compound, .items = items };
    return try nbt.serialize(a, doc, options);
}
fn read(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !?[]u8 {
    return fs.read(a, dir, io, filename, limit) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}
/// Call under the launch guard, before starting the client. No game directories
/// are created. Corruption, links and detected concurrent edits fail closed.
pub fn ensure(a: std.mem.Allocator, io: std.Io, directory: []const u8, server: Server, cancel: *const std.atomic.Value(bool)) !void {
    try fs.cancelled(io, cancel, null);
    const dir = try fs.openAbsolute(io, directory);
    defer dir.close(io);
    const original = try read(a, io, dir);
    defer if (original) |bytes| a.free(bytes);
    const updated = (try appended(a, original, server)) orelse return;
    defer a.free(updated);
    var nonce: [16]u8 = undefined;
    try std.Io.randomSecure(io, &nonce);
    const temporary = (".servers-" ++ std.fmt.bytesToHex(nonce, .lower) ++ ".tmp").*;
    const stat = try fs.inspectEntry(dir, io, filename);
    const file = try dir.createFile(io, &temporary, .{ .exclusive = true, .permissions = if (stat) |value| value.permissions else .default_file });
    var closed = false;
    defer if (!closed) file.close(io);
    defer dir.deleteFile(io, &temporary) catch {};
    try file.writeStreamingAll(io, updated);
    try file.sync(io);
    file.close(io);
    closed = true;
    const current = try read(a, io, dir);
    defer if (current) |bytes| a.free(bytes);
    if ((original == null) != (current == null)) return error.ServerListChanged;
    if (original) |bytes| if (!std.mem.eql(u8, bytes, current.?)) return error.ServerListChanged;
    try fs.cancelled(io, cancel, null);
    try io.checkCancel();
    if (original == null) try dir.renamePreserve(&temporary, dir, filename, io) else try dir.rename(&temporary, dir, filename, io);
    try fs.syncDir(dir, io);
}

test "server addresses compare ports domains and IPv6 without DNS resolution" {
    const server: Server = .{ .name = "Test", .host = "Example.COM", .port = 25565 };
    try std.testing.expect(sameAddress("example.com:25565", server));
    try std.testing.expect(sameAddress("example.com.", server));
    try std.testing.expect(!sameAddress("example.com:25566", server));
    try std.testing.expect(!sameAddress("127.0.0.1", server));
    try std.testing.expect(sameAddress("[0:0:0:0:0:0:0:1]:25565", .{ .name = "v6", .host = "::1", .port = 25565 }));
}

test "append preserves existing entries preferences and unknown NBT fields" {
    const a = std.testing.allocator;
    var fields = [_]nbt.Entry{
        .{ .name = @constCast("name"), .value = .{ .string = @constCast("Player name") } },
        .{ .name = @constCast("ip"), .value = .{ .string = @constCast("old.example") } },
        .{ .name = @constCast("acceptTextures"), .value = .{ .byte = 0 } },
        .{ .name = @constCast("icon"), .value = .{ .string = @constCast("original-icon") } },
        .{ .name = @constCast("modField"), .value = .{ .long = 1234 } },
    };
    var items = [_]nbt.Tag{.{ .compound = .{ .entries = &fields } }};
    var entries = [_]nbt.Entry{
        .{ .name = @constCast("servers"), .value = .{ .list = .{ .element_type = .compound, .items = &items } } },
        .{ .name = @constCast("unknownRoot"), .value = .{ .int = 42 } },
    };
    const original: nbt.Document = .{ .name = @constCast("custom-root"), .root = .{ .compound = .{ .entries = &entries } } };
    const bytes = try nbt.serialize(a, original, options);
    defer a.free(bytes);
    try std.testing.expect((try appended(a, bytes, .{ .name = "Do not rename", .host = "OLD.EXAMPLE", .port = 25565 })) == null);
    const updated = (try appended(a, bytes, .{ .name = "New server", .host = "new.example", .port = 24444 })).?;
    defer a.free(updated);
    var parsed = try nbt.parse(a, updated, options);
    defer parsed.deinit(a);
    try std.testing.expectEqualStrings(original.name, parsed.name);
    try std.testing.expect(parsed.root.compound.get("unknownRoot").?.eql(entries[1].value));
    const result = parsed.root.compound.get("servers").?.list.items;
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expect(result[0].eql(items[0]));
    try std.testing.expectEqualStrings("new.example:24444", result[1].compound.get("ip").?.string);
    try std.testing.expectEqualStrings("New server", result[1].compound.get("name").?.string);
}

test "server list creation is idempotent and corruption and cancellation preserve bytes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path);
    var cancel: std.atomic.Value(bool) = .init(false);
    const server: Server = .{ .name = "My server", .host = "example.com", .port = 25565 };
    try ensure(a, io, path[0..len], server, &cancel);
    const first = try tmp.dir.readFileAlloc(io, filename, a, .limited(limit));
    defer a.free(first);
    try ensure(a, io, path[0..len], .{ .name = "Changed", .host = "EXAMPLE.COM", .port = 25565 }, &cancel);
    const second = try tmp.dir.readFileAlloc(io, filename, a, .limited(limit));
    defer a.free(second);
    try std.testing.expectEqualSlices(u8, first, second);
    try tmp.dir.writeFile(io, .{ .sub_path = filename, .data = "broken" });
    if (ensure(a, io, path[0..len], server, &cancel)) |_| return error.ExpectedFailure else |_| {}
    const broken = try tmp.dir.readFileAlloc(io, filename, a, .limited(limit));
    defer a.free(broken);
    try std.testing.expectEqualStrings("broken", broken);
    cancel.store(true, .release);
    try std.testing.expectError(error.Canceled, ensure(a, io, path[0..len], server, &cancel));
}

fn allocationFixture(a: std.mem.Allocator) !void {
    const first = (try appended(a, null, .{ .name = "First", .host = "one.example", .port = 25565 })).?;
    defer a.free(first);
    const second = (try appended(a, first, .{ .name = "Second", .host = "two.example", .port = 25565 })).?;
    defer a.free(second);
}
test "server list allocation failures release parsed and appended trees" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFixture, .{});
}

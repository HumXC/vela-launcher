//! Offline scrolling and cancellable metadata transport for resource navigation tests.
const std = @import("std");
const http = @import("../core/http_transport.zig");
const base = @import("resource_download_fixture.zig");
pub const Gate = struct {
    match: []const u8,
    late_result: bool = false,
    started: std.atomic.Value(bool) = .init(false),
    cancel_seen: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    requests: std.atomic.Value(u32) = .init(0),
};
pub const Context = struct {
    scenario: ?*base.Scenario = null,
    gate: ?*Gate = null,
    long_catalog: bool = false,
};
pub fn execute(raw: ?*anyopaque, a: std.mem.Allocator, io: std.Io, request: http.Request) !http.Response {
    const ctx: *Context = @ptrCast(@alignCast(raw orelse return error.MissingNavigationContext));
    if (request.cancel) |cancel| if (cancel.load(.acquire)) return error.Canceled;
    if (ctx.gate) |gate| if (std.mem.startsWith(u8, request.url, "https://api.modrinth.com/")) {
        _ = gate.requests.fetchAdd(1, .monotonic);
        if (std.mem.indexOf(u8, request.url, gate.match) != null) {
            const cancel = request.cancel orelse return error.MissingFixtureCancel;
            gate.started.store(true, .release);
            while (!gate.release.load(.acquire)) {
                if (cancel.load(.acquire)) {
                    gate.cancel_seen.store(true, .release);
                    if (!gate.late_result) return error.Canceled;
                }
                try io.sleep(.fromMilliseconds(1), .awake);
            }
            if (cancel.load(.acquire)) gate.cancel_seen.store(true, .release);
        }
    };
    if (ctx.long_catalog) {
        if (std.mem.startsWith(u8, request.url, "https://api.modrinth.com/v2/search?")) return .{ .status = 200, .body = try catalog(a), .allocator = a };
        const prefix = "https://api.modrinth.com/v2/project/";
        if (std.mem.startsWith(u8, request.url, prefix ++ "preview-") and std.mem.endsWith(u8, request.url, "/version")) return .{ .status = 200, .body = try version(a, request.url[prefix.len .. request.url.len - "/version".len]), .allocator = a };
        if (std.mem.startsWith(u8, request.url, "https://cdn.modrinth.com/fixture/preview-")) return .{ .status = 200, .body = try a.dupe(u8, base.payload), .allocator = a };
    }
    return base.execute(if (ctx.scenario) |scenario| @ptrCast(scenario) else null, a, io, request);
}
fn catalog(a: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    const Hit = struct { project_id: []const u8, project_type: []const u8 = "mod", title: []const u8, description: []const u8 = "离线导航预览项目", icon_url: []const u8 = "https://cdn.modrinth.com/fixture/icons/iris.webp" };
    var hits: std.ArrayList(Hit) = .empty;
    for (0..40) |i| try hits.append(temp, .{ .project_id = try std.fmt.allocPrint(temp, "preview-{d}", .{i + 1}), .title = try std.fmt.allocPrint(temp, "预览模组 {d:0>2}", .{i + 1}) });
    return std.json.Stringify.valueAlloc(a, .{ .hits = hits.items, .total_hits = 40 }, .{});
}
fn version(a: std.mem.Allocator, id: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var digest: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(base.payload, &digest, .{});
    const hash = std.fmt.bytesToHex(digest, .lower);
    const item = .{ .id = try std.fmt.allocPrint(temp, "{s}-1", .{id}), .project_id = id, .name = "1.8.8 · Fabric", .version_number = "1.8.8", .game_versions = [_][]const u8{"1.21.4"}, .loaders = [_][]const u8{"fabric"}, .dependencies = [_]u8{}, .files = .{.{ .filename = try std.fmt.allocPrint(temp, "{s}.jar", .{id}), .url = try std.fmt.allocPrint(temp, "https://cdn.modrinth.com/fixture/{s}.jar", .{id}), .size = base.payload.len, .primary = true, .hashes = .{ .sha512 = @as([]const u8, &hash) } }} };
    return std.json.Stringify.valueAlloc(a, .{item}, .{});
}

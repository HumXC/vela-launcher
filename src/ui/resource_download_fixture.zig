//! Deterministic offline metadata for resource UI tests and isolated previews.
const std = @import("std");
const http = @import("../core/http_transport.zig");
const providers = @import("../core/content_providers.zig");
pub const payload = "resource fixture bytes";
pub const project: providers.Project = .{ .provider = .modrinth, .id = "iris", .name = "Iris Shaders", .summary = "为 Fabric 实例提供光影加载支持。", .official_page = "https://modrinth.com/project/iris", .icon_url = "https://cdn.modrinth.com/fixture/icons/iris.webp" };
pub const Lease = struct {
    pub fn acquire(_: ?*anyopaque, _: []const u8) !void {}
    pub fn recheck(_: ?*anyopaque, _: []const u8) !void {}
    pub fn release(_: ?*anyopaque, _: []const u8) void {}
    pub fn callbacks() @import("../core/content_install.zig").Lease {
        return .{ .context = null, .acquire = acquire, .recheck = recheck, .release = release };
    }
};
pub const Scenario = struct {
    transitive: bool = false,
    optional: bool = false,
    preview_optional_dependency: bool = false,
    multiple_sodium: bool = false,
    reverse_versions: bool = false,
    fail_requests: std.atomic.Value(bool) = .init(false),
    pause_downloads: bool = false,
};
const default_scenario: Scenario = .{};
pub fn execute(raw: ?*anyopaque, a: std.mem.Allocator, io: std.Io, request: http.Request) !http.Response {
    const scenario: *const Scenario = if (raw) |context| @ptrCast(@alignCast(context)) else &default_scenario;
    if (scenario.fail_requests.load(.acquire)) return error.FixtureMetadataUnavailable;
    if (request.cancel) |cancel| if (cancel.load(.acquire)) return error.Canceled;
    if (request.method != .get) return error.UnexpectedNetwork;
    if (scenario.pause_downloads and std.mem.startsWith(u8, request.url, "https://cdn.modrinth.com/fixture/")) {
        const cancel = request.cancel orelse return error.MissingFixtureCancel;
        while (!cancel.load(.acquire)) try io.sleep(.fromMilliseconds(1), .awake);
        return error.Canceled;
    }
    const body = if (std.mem.startsWith(u8, request.url, "https://api.modrinth.com/v2/search?")) try a.dupe(u8,
        \\{"hits":[{"project_id":"iris","project_type":"mod","title":"Iris Shaders","description":"为 Fabric 实例提供光影加载支持。","icon_url":"https://cdn.modrinth.com/fixture/icons/iris.webp"},{"project_id":"sodium","project_type":"mod","title":"Sodium","description":"优化渲染性能，提高游戏帧率。","icon_url":"https://cdn.modrinth.com/fixture/icons/sodium.webp"},{"project_id":"fabric-api","project_type":"mod","title":"Fabric API","description":"为 Fabric 模组提供基础接口。","icon_url":"https://cdn.modrinth.com/fixture/icons/fabric-api.png"},{"project_id":"lithium","project_type":"mod","title":"Lithium","description":"优化游戏逻辑与服务器性能。","icon_url":"https://cdn.modrinth.com/fixture/icons/lithium.webp"}],"total_hits":4}
    ) else if (std.mem.eql(u8, request.url, "https://cdn.modrinth.com/fixture/iris.jar") or std.mem.eql(u8, request.url, "https://cdn.modrinth.com/fixture/sodium.jar") or std.mem.eql(u8, request.url, "https://cdn.modrinth.com/fixture/fabric-api.jar") or std.mem.eql(u8, request.url, "https://cdn.modrinth.com/fixture/lithium.jar")) try a.dupe(u8, payload) else blk: {
        const ids = [_][]const u8{ "iris", "sodium", "fabric-api", "lithium", "open-parties-and-claims" };
        for (ids) |id| {
            if (std.mem.eql(u8, id, "open-parties-and-claims") and !scenario.preview_optional_dependency) continue;
            const url = try std.fmt.allocPrint(a, "https://api.modrinth.com/v2/project/{s}/version", .{id});
            defer a.free(url);
            if (std.mem.eql(u8, request.url, url)) {
                const json = try versionJson(a, scenario, id, "1");
                defer a.free(json);
                if (std.mem.eql(u8, id, "iris") or (scenario.multiple_sodium and std.mem.eql(u8, id, "sodium"))) {
                    const second = try versionJson(a, scenario, id, "2");
                    defer a.free(second);
                    break :blk try std.fmt.allocPrint(a, "[{s},{s}]", .{ if (scenario.reverse_versions) second else json, if (scenario.reverse_versions) json else second });
                }
                break :blk try std.fmt.allocPrint(a, "[{s}]", .{json});
            }
            const one_url = try std.fmt.allocPrint(a, "https://api.modrinth.com/v2/version/{s}-1", .{id});
            defer a.free(one_url);
            if (std.mem.eql(u8, request.url, one_url)) break :blk try versionJson(a, scenario, id, "1");
        }
        return error.UnexpectedNetwork;
    };
    return .{ .status = 200, .body = body, .allocator = a, .allocation = body };
}
fn versionJson(a: std.mem.Allocator, scenario: *const Scenario, id: []const u8, version: []const u8) ![]u8 {
    var digest: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(payload, &digest, .{});
    const hash = std.fmt.bytesToHex(digest, .lower);
    const deps = if (std.mem.eql(u8, id, "iris"))
        (if (scenario.preview_optional_dependency) "[{\"project_id\":\"sodium\",\"version_id\":\"sodium-1\",\"dependency_type\":\"required\"},{\"project_id\":\"open-parties-and-claims\",\"version_id\":\"open-parties-and-claims-1\",\"dependency_type\":\"optional\"}]" else if (scenario.optional) "[{\"project_id\":\"sodium\",\"version_id\":\"sodium-1\",\"dependency_type\":\"required\"},{\"project_id\":\"lithium\",\"version_id\":\"lithium-1\",\"dependency_type\":\"optional\"}]" else if (scenario.multiple_sodium) "[{\"project_id\":\"sodium\",\"dependency_type\":\"required\"}]" else "[{\"project_id\":\"sodium\",\"version_id\":\"sodium-1\",\"dependency_type\":\"required\"}]")
    else if (scenario.transitive and std.mem.eql(u8, id, "sodium")) (if (scenario.optional) "[{\"project_id\":\"fabric-api\",\"version_id\":\"fabric-api-1\",\"dependency_type\":\"optional\"}]" else "[{\"project_id\":\"fabric-api\",\"version_id\":\"fabric-api-1\",\"dependency_type\":\"required\"}]") else "[]";
    const name = if (std.mem.eql(u8, id, "iris")) (if (std.mem.eql(u8, version, "1")) "Iris 1.8.8" else "Iris 1.8.7") else if (std.mem.eql(u8, id, "sodium")) "Sodium 0.6.13" else if (std.mem.eql(u8, id, "fabric-api")) "Fabric API 0.119.2+1.21.4" else if (std.mem.eql(u8, id, "open-parties-and-claims")) "Open Parties and Claims 0.32.7" else "Lithium 0.15.0";
    return try std.fmt.allocPrint(a, "{{\"date_published\":\"{s}\",\"id\":\"{s}-{s}\",\"project_id\":\"{s}\",\"name\":\"{s}\",\"version_number\":\"{s}\",\"game_versions\":[\"1.21.4\"],\"loaders\":[\"fabric\"],\"dependencies\":{s},\"files\":[{{\"filename\":\"{s}.jar\",\"url\":\"https://cdn.modrinth.com/fixture/{s}.jar\",\"size\":{d},\"primary\":true,\"hashes\":{{\"sha512\":\"{s}\"}}}}]}}", .{ if (std.mem.eql(u8, version, "1")) "2025-02-01T12:00:00Z" else "2025-01-01T12:00:00Z", id, version, id, name, version, deps, id, id, payload.len, hash });
}

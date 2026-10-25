const std = @import("std");
const catalog = @import("ui/pack_catalog.zig");
const http = @import("core/http_transport.zig");
const credentials = @import("core/credentials.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const Fixture = struct {
    calls: std.atomic.Value(usize) = .init(0),
    entered: std.atomic.Value(bool) = .init(false),
    exited: std.atomic.Value(bool) = .init(false),
    block: bool = false,
    filtered: bool = false,
    cf: bool = false,
    fail: bool = false,
    fn execute(ctx: ?*anyopaque, alloc: std.mem.Allocator, job_io: std.Io, req: http.Request) !http.Response {
        const self: *Fixture = @ptrCast(@alignCast(ctx.?));
        _ = self.calls.fetchAdd(1, .monotonic);
        self.entered.store(true, .release);
        defer self.exited.store(true, .release);
        try std.testing.expect(req.require_public_address);
        try std.testing.expect(!req.follow_redirects);
        if (self.block) {
            while (!req.cancel.?.load(.acquire)) try job_io.sleep(.fromMilliseconds(1), .awake);
            return error.Canceled;
        }
        if (self.fail) return error.FixtureFailure;
        if (self.cf) {
            try std.testing.expect(std.mem.startsWith(u8, req.url, "https://api.curseforge.com/v1/mods/search?"));
            try std.testing.expect(std.mem.indexOf(u8, req.url, "classId=4471") != null);
            try std.testing.expect(std.mem.indexOf(u8, req.url, "gameVersion=") == null);
            try std.testing.expect(std.mem.indexOf(u8, req.url, "modLoaderType=") == null);
            var authorized = false;
            for (req.headers) |h| if (std.mem.eql(u8, h.name, "x-api-key")) {
                authorized = std.mem.eql(u8, h.value, "fixture-only-key");
            };
            try std.testing.expect(authorized);
            return .{ .allocator = alloc, .status = 200, .body = try alloc.dupe(u8, "{\"data\":[],\"pagination\":{\"index\":0,\"pageSize\":40,\"resultCount\":0,\"totalCount\":0}}") };
        }
        for (req.headers) |h| try std.testing.expect(!std.mem.eql(u8, h.name, "x-api-key"));
        if (std.mem.indexOf(u8, req.url, "/version?") != null) {
            return .{ .allocator = alloc, .status = 200, .body = try alloc.dupe(u8, "[{\"id\":\"v1\",\"project_id\":\"pack1\",\"name\":\"Release\",\"date_published\":\"2025-01-01T00:00:00Z\",\"game_versions\":[\"1.20.1\"],\"loaders\":[\"fabric\"],\"dependencies\":[],\"files\":[{\"filename\":\"test.mrpack\",\"url\":\"https://cdn.modrinth.com/test.mrpack\",\"primary\":true,\"size\":1,\"hashes\":{\"sha1\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}}]}]") };
        }
        try std.testing.expect(std.mem.indexOf(u8, req.url, "project_type%3Amodpack") != null);
        try std.testing.expectEqual(self.filtered, std.mem.indexOf(u8, req.url, "versions%3A1.20.1") != null);
        try std.testing.expectEqual(self.filtered, std.mem.indexOf(u8, req.url, "categories%3Afabric") != null);
        return .{ .allocator = alloc, .status = 200, .body = try alloc.dupe(u8, "{\"hits\":[{\"project_id\":\"pack1\",\"project_type\":\"modpack\",\"title\":\"Fixture pack\",\"description\":\"Owned metadata\"}],\"total_hits\":1}") };
    }
    fn options(self: *Fixture) catalog.Options {
        return .{ .transport_options = .{ .fixture_http = execute, .fixture_context = self } };
    }
};
fn drain(controller: *catalog.Controller) !void {
    for (0..10000) |_| {
        controller.tick();
        if (!controller.snapshot().busy) return;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.WorkerTimeout;
}
test "pack catalog unfiltered search owns requests and versions without instance" {
    var fixture: Fixture = .{};
    var controller = try catalog.Controller.init(a, io, fixture.options());
    defer controller.deinit();
    var query = [_]u8{'x'};
    try controller.search(.{ .query = &query });
    query[0] = 'y';
    try drain(&controller);
    try std.testing.expectEqual(null, controller.snapshot().failure);
    try std.testing.expectEqual(@as(u64, 1), controller.snapshot().total);
    try std.testing.expectEqualStrings("Fixture pack", controller.snapshot().catalog[0].name);
    try controller.loadVersions(controller.snapshot().catalog[0], .{});
    try drain(&controller);
    try std.testing.expectEqual(null, controller.snapshot().failure);
    try std.testing.expectEqual(@as(usize, 1), controller.snapshot().versions.len);
    try std.testing.expectEqualStrings("v1", controller.snapshot().versions[0].id);
    try controller.loadVersions(controller.snapshot().catalog[0], .{ .loader = .forge });
    try drain(&controller);
    try std.testing.expectEqual(@as(usize, 0), controller.snapshot().versions.len);
    fixture.filtered = true;
    try controller.search(.{ .filter = .{ .minecraft_version = "1.20.1", .loader = .fabric } });
    try drain(&controller);
    try std.testing.expectEqual(null, controller.snapshot().failure);
}
test "pack catalog cancellation joins worker and cannot publish stale data" {
    var fixture: Fixture = .{ .block = true };
    var controller = try catalog.Controller.init(a, io, fixture.options());
    try controller.search(.{});
    while (!fixture.entered.load(.acquire)) try io.sleep(.fromMilliseconds(1), .awake);
    controller.cancel();
    try std.testing.expect(!controller.snapshot().busy);
    controller.deinit();
    try std.testing.expect(fixture.exited.load(.acquire));
}
test "pack catalog policy gates fail closed and async failures are published" {
    var fixture: Fixture = .{ .fail = true };
    var controller = try catalog.Controller.init(a, io, fixture.options());
    defer controller.deinit();
    try std.testing.expectError(error.ProviderDisabled, controller.search(.{ .provider = .curseforge }));
    try std.testing.expectEqual(@as(usize, 0), fixture.calls.load(.acquire));
    try controller.search(.{});
    try drain(&controller);
    try std.testing.expectEqual(error.FixtureFailure, controller.snapshot().failure.?);
    controller.cancel();
    try std.testing.expectEqual(null, controller.snapshot().failure);
}
const Vault = struct {
    fn put(_: *anyopaque, _: []const u8, _: []const u8) credentials.Error!void {
        return error.Denied;
    }
    fn delete(_: *anyopaque, _: []const u8) credentials.Error!void {
        return error.Denied;
    }
    fn get(_: *anyopaque, alloc: std.mem.Allocator, _: []const u8) credentials.Error!credentials.Secret {
        return .{ .allocator = alloc, .bytes = try alloc.dupe(u8, "fixture-only-key") };
    }
    const vtable: credentials.Store.VTable = .{ .put = put, .get = get, .delete = delete };
};
test "pack catalog authorized CurseForge has no implicit compatibility filters" {
    var fixture: Fixture = .{ .cf = true };
    var options = fixture.options();
    options.transport_options.allow_curseforge = true;
    options.curseforge = .{ .enabled = true, .terms_approved = true, .credential_ref = "0123456789abcdef0123456789abcdef".* };
    options.fixture_credential_store = .{ .ctx = &fixture, .vtable = &Vault.vtable };
    var controller = try catalog.Controller.init(a, io, options);
    defer controller.deinit();
    try std.testing.expect(controller.snapshot().curseforge_available);
    try controller.search(.{ .provider = .curseforge });
    try drain(&controller);
    try std.testing.expectEqual(null, controller.snapshot().failure);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls.load(.acquire));
}
const CfVersions = struct {
    fn execute(_: ?*anyopaque, alloc: std.mem.Allocator, _: std.Io, req: http.Request) !http.Response {
        try std.testing.expect(std.mem.indexOf(u8, req.url, "gameVersion=") == null);
        try std.testing.expect(std.mem.indexOf(u8, req.url, "modLoaderType=") == null);
        const body: []const u8 = if (std.mem.endsWith(u8, req.url, "/mods/12"))
            "{\"data\":{\"id\":12,\"gameId\":432,\"classId\":4471,\"name\":\"CF pack\",\"summary\":\"fixture\",\"links\":{\"websiteUrl\":\"https://www.curseforge.com/minecraft/modpacks/fixture\"},\"allowModDistribution\":true}}"
        else if (std.mem.indexOf(u8, req.url, "/mods/12/files?") != null)
            "{\"data\":[{\"id\":34,\"modId\":12,\"gameId\":432,\"displayName\":\"Release\",\"fileName\":\"pack.zip\",\"fileDate\":\"2025-01-01T00:00:00Z\",\"gameVersions\":[\"1.20.1\",\"Fabric\"],\"hashes\":[{\"algo\":1,\"value\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}],\"dependencies\":[],\"isAvailable\":true,\"fileLength\":1,\"downloadUrl\":\"https://evil.example/pack.zip\"}],\"pagination\":{\"index\":0,\"pageSize\":50,\"resultCount\":1,\"totalCount\":1}}"
        else
            return error.UnexpectedRequest;
        return .{ .allocator = alloc, .status = 200, .body = try alloc.dupe(u8, body) };
    }
};
test "pack catalog CurseForge versions remain manual and do not trust download host" {
    var fixture: Fixture = .{};
    var options = fixture.options();
    options.transport_options.fixture_http = CfVersions.execute;
    options.transport_options.allow_curseforge = true;
    options.curseforge = .{ .enabled = true, .terms_approved = true, .credential_ref = "0123456789abcdef0123456789abcdef".* };
    options.fixture_credential_store = .{ .ctx = &fixture, .vtable = &Vault.vtable };
    var controller = try catalog.Controller.init(a, io, options);
    defer controller.deinit();
    try controller.loadVersions(.{ .provider = .curseforge, .id = "12", .name = "pack", .official_page = "https://www.curseforge.com/minecraft/modpacks/fixture" }, .{});
    try drain(&controller);
    try std.testing.expectEqual(null, controller.snapshot().failure);
    const version = controller.snapshot().versions[0];
    try std.testing.expectEqualStrings("34", version.id);
    try std.testing.expect(version.files[0].download == .manual_required);
    try std.testing.expectEqual(null, version.files[0].authorization);
}
test "pack catalog superseded completed request never publishes" {
    var fixture: Fixture = .{};
    var controller = try catalog.Controller.init(a, io, fixture.options());
    defer controller.deinit();
    try controller.search(.{});
    // Wait for transport completion, but intentionally do not publish with tick.
    while (!fixture.exited.load(.acquire)) try io.sleep(.fromMilliseconds(1), .awake);
    try controller.loadVersions(.{ .provider = .modrinth, .id = "pack1", .name = "pack", .official_page = "https://modrinth.com/modpack/pack1" }, .{});
    try drain(&controller);
    try std.testing.expectEqual(null, controller.snapshot().failure);
    try std.testing.expectEqual(@as(usize, 0), controller.snapshot().catalog.len);
    try std.testing.expectEqual(@as(usize, 1), controller.snapshot().versions.len);
}

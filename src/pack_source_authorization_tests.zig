const std = @import("std");
const source = @import("core/pack_source_authorization.zig");
const providers = @import("core/content_providers.zig");
const imports = @import("core/pack_import.zig");
const manifest = @import("core/content_manifest.zig");
const credentials = @import("core/credentials.zig");
const http = @import("core/http_transport.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const hosts: []const []const u8 = &.{ "cdn.modrinth.com", "edge.forgecdn.net" };
const Fixture = struct {
    calls: usize = 0,
    gets: usize = 0,
    allowed: bool = true,
    bad_host: bool = false,
    status: u16 = 200,
    fn execute(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: std.Io, req: http.Request) !http.Response {
        const self: *Fixture = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        try std.testing.expect(req.require_public_address);
        try std.testing.expect(!req.follow_redirects);
        try std.testing.expect(std.mem.startsWith(u8, req.url, providers.curseforge_api_base ++ "/mods/12"));
        var key = false;
        for (req.headers) |h| if (std.mem.eql(u8, h.name, "x-api-key")) {
            key = std.mem.eql(u8, h.value, "fixture-only-key");
        };
        try std.testing.expect(key);
        const body = if (std.mem.endsWith(u8, req.url, "/files/34"))
            try std.fmt.allocPrint(alloc, "{{\"data\":{{\"id\":34,\"modId\":12,\"gameId\":432,\"displayName\":\"Release\",\"fileName\":\"pack.zip\",\"hashes\":[{{\"algo\":1,\"value\":\"{s}\"}}],\"fileLength\":123,\"isAvailable\":true,\"downloadUrl\":\"https://{s}/pack.zip\",\"gameVersions\":[\"1.20.1\",\"Fabric\"],\"dependencies\":[]}}}}", .{ hash, if (self.bad_host) @as([]const u8, "evil.example") else "edge.forgecdn.net" })
        else
            try std.fmt.allocPrint(alloc, "{{\"data\":{{\"id\":12,\"gameId\":432,\"classId\":6,\"name\":\"Example\",\"summary\":\"Fixture\",\"allowModDistribution\":{s},\"links\":{{\"websiteUrl\":\"https://www.curseforge.com/minecraft/mc-mods/example\"}}}}}}", .{if (self.allowed) @as([]const u8, "true") else "false"});
        return .{ .allocator = alloc, .status = self.status, .body = body, .allocation = body };
    }
    fn put(_: *anyopaque, _: []const u8, _: []const u8) credentials.Error!void {
        return error.Denied;
    }
    fn delete(_: *anyopaque, _: []const u8) credentials.Error!void {
        return error.Denied;
    }
    fn get(ctx: *anyopaque, alloc: std.mem.Allocator, _: []const u8) credentials.Error!credentials.Secret {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        self.gets += 1;
        return .{ .allocator = alloc, .bytes = try alloc.dupe(u8, "fixture-only-key") };
    }
    const vt: credentials.Store.VTable = .{ .put = put, .get = get, .delete = delete };
    fn options(self: *Fixture) source.Options {
        return .{ .policy = .{ .enabled = true, .terms_approved = true, .credential_ref = "0123456789abcdef0123456789abcdef".* }, .transport_options = .{ .allow_curseforge = true, .approved_download_hosts = hosts, .fixture_http = execute, .fixture_context = self }, .fixture_credential_store = .{ .ctx = self, .vtable = &vt } };
    }
};
fn version() providers.Version {
    return .{ .provider = .curseforge, .project_id = "12", .id = "34", .name = "Untrusted", .minecraft_versions = &.{}, .loaders = &.{}, .dependencies = &.{}, .files = &.{.{ .filename = "wrong.zip", .hashes = .{ .sha1 = hash }, .size = 1, .download = .{ .remote = "https://evil.example/untrusted.zip" } }} };
}
fn inspection() imports.Inspection {
    const pack: manifest.PackPlan = .{ .identity = .{ .provider = .curseforge, .project_id = "pack", .version_id = "archive" }, .name = "Pack", .version = "1", .minecraft_version = "1.20.1", .loader = .fabric, .unresolved = &.{.{ .project_id = "12", .file_id = "34", .required = false, .selected = true }} };
    return .{ .arena = std.heap.ArenaAllocator.init(a), .parsed = .{ .arena = std.heap.ArenaAllocator.init(a), .value = pack }, .pack = pack, .provider = .curseforge, .source_sha256 = @splat('a'), .archive_absolute_path = "", .stage_absolute_path = "" };
}
test "pack source CF archive replaces untrusted metadata with fresh client proof" {
    var f: Fixture = .{};
    var result = try source.authorizeArchive(a, io, version(), f.options(), null);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), f.calls);
    const file = result.value.files[0];
    try std.testing.expectEqualStrings("pack.zip", file.filename);
    try std.testing.expectEqualStrings(hash, file.hashes.sha1.?);
    try std.testing.expectEqual(@as(?u64, 123), file.size);
    try providers.validateRemoteAuthorization(.curseforge, "12", "34", file, .{ .enabled = true, .approved_download_hosts = hosts });
}
test "pack source resolves CF references and reauthorizes already resolved files" {
    var f: Fixture = .{};
    var item = inspection();
    defer item.deinit();
    try source.resolveInspection(a, io, &item, f.options(), null);
    try std.testing.expectEqual(@as(usize, 0), item.pack.unresolved.len);
    try std.testing.expectEqualStrings("mods/pack.zip", item.pack.files[0].record.path);
    try std.testing.expect(!item.pack.files[0].required);
    try std.testing.expectEqual(@as(?bool, true), item.pack.files[0].selected);
    try std.testing.expectEqualStrings(hash, item.pack.files[0].record.hashes.sha1.?);
    f.allowed = false;
    try source.resolveInspection(a, io, &item, f.options(), null);
    try std.testing.expectEqual(providers.ManualReason.distribution_disabled, item.pack.files[0].download.manual_required.reason);
    try std.testing.expectEqual(null, item.pack.files[0].authorization);
    try std.testing.expectEqual(@as(?u64, 123), item.pack.files[0].record.size);
}
test "pack source disabled distribution remains manual and retains integrity" {
    var f: Fixture = .{ .allowed = false };
    var result = try source.authorizeArchive(a, io, version(), f.options(), null);
    defer result.deinit();
    try std.testing.expectEqual(providers.ManualReason.distribution_disabled, result.value.files[0].download.manual_required.reason);
    try std.testing.expectEqualStrings(hash, result.value.files[0].hashes.sha1.?);
    try std.testing.expectEqual(null, result.value.files[0].authorization);
}
test "pack source rejects absent gates before reading credentials" {
    var f: Fixture = .{};
    var options = f.options();
    options.policy.terms_approved = false;
    try std.testing.expectError(error.ProviderDisabled, source.authorizeArchive(a, io, version(), options, null));
    try std.testing.expectEqual(@as(usize, 0), f.gets);
    try std.testing.expectEqual(@as(usize, 0), f.calls);
}
test "pack source rejects unapproved host and redirects without mutating inspection" {
    var f: Fixture = .{ .bad_host = true };
    var item = inspection();
    defer item.deinit();
    try std.testing.expectError(error.UnapprovedDownloadHost, source.resolveInspection(a, io, &item, f.options(), null));
    try std.testing.expectEqual(@as(usize, 1), item.pack.unresolved.len);
    try std.testing.expectEqual(@as(usize, 0), item.pack.files.len);
    f.bad_host = false;
    f.status = 302;
    try std.testing.expectError(error.RedirectRejected, source.authorizeArchive(a, io, version(), f.options(), null));
}
test "pack source cancellation touches neither metadata nor vault" {
    var f: Fixture = .{};
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Canceled, source.authorizeArchive(a, io, version(), f.options(), &cancel));
    try std.testing.expectEqual(@as(usize, 0), f.gets);
}
test "pack source default Modrinth passes and foreign URLs fail" {
    var v = version();
    v.provider = .modrinth;
    var file: providers.File = .{ .filename = "pack.mrpack", .hashes = .{ .sha1 = hash }, .size = 123, .download = .{ .remote = "https://cdn.modrinth.com/data/pack.mrpack" } };
    v.files = (&file)[0..1];
    var result = try source.authorizeArchive(a, io, v, .{}, null);
    defer result.deinit();
    try std.testing.expectEqualStrings(file.download.remote, result.value.files[0].download.remote);
    file.download = .{ .remote = "https://127.0.0.1/pack.mrpack" };
    try std.testing.expectError(error.UnapprovedDownloadHost, source.authorizeArchive(a, io, v, .{}, null));
}
test "pack source MR inspection permits empty content and staged overrides" {
    var item = inspection();
    defer item.deinit();
    item.provider = .modrinth;
    item.pack.identity.provider = .modrinth;
    item.pack.unresolved = &.{};
    var files = [_]manifest.InstallFile{
        .{ .record = .{ .path = "config/empty.txt", .provider = .modrinth, .project_id = "p", .version_id = "v", .hashes = .{ .sha1 = hash }, .size = 0, .identity_provenance = .pack_archive }, .download = .{ .remote = "https://cdn.modrinth.com/empty.txt" } },
        .{ .record = .{ .path = "config/local.txt", .provider = .modrinth, .project_id = "p", .version_id = "v", .hashes = .{ .sha1 = hash }, .size = 0, .identity_provenance = .pack_override, .role = .override }, .download = .{ .manual_required = .{ .official_page = "", .reason = .missing_url } } },
    };
    item.pack.files = &files;
    try source.resolveInspection(a, io, &item, .{}, null);
    files[0].alternatives = &.{"https://evil.example/file"};
    try std.testing.expectError(error.UnapprovedDownloadHost, source.resolveInspection(a, io, &item, .{}, null));
}

test "indexed worlds retain source host and alternative authorization" {
    var item = inspection();
    defer item.deinit();
    item.provider = .modrinth;
    item.pack.identity.provider = .modrinth;
    item.pack.files = &.{};
    item.pack.unresolved = &.{};
    var worlds = [_]manifest.InstallFile{.{ .record = .{ .path = "saves/World/level.dat", .provider = .modrinth, .project_id = "p", .version_id = "v", .hashes = .{ .sha1 = hash }, .size = 0, .identity_provenance = .pack_archive }, .download = .{ .remote = "https://cdn.modrinth.com/world.dat" } }};
    item.pack.initial_world_files = &worlds;
    try source.resolveInspection(a, io, &item, .{}, null);
    worlds[0].alternatives = &.{"https://evil.example/world.dat"};
    try std.testing.expectError(error.UnapprovedDownloadHost, source.resolveInspection(a, io, &item, .{}, null));
    worlds[0].alternatives = &.{};
    worlds[0].download = .{ .remote = "https://evil.example/world.dat" };
    try std.testing.expectError(error.UnapprovedDownloadHost, source.resolveInspection(a, io, &item, .{}, null));
}

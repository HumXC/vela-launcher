const std = @import("std");
const backend = @import("core/pack_install.zig");
const credentials = @import("core/credentials.zig");
const http = @import("core/http_transport.zig");
const fs = @import("core/content_fs.zig");
const fixtures = @import("pack_install_fixture.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const Provider = struct {
    metadata: usize = 0,
    downloads: usize = 0,
    keys: usize = 0,
    telemetry: ?*@import("core/tasks.zig").Task = null,
    fn request(raw: ?*anyopaque, alloc: std.mem.Allocator, _: std.Io, req: http.Request) !http.Response {
        const self: *Provider = @ptrCast(@alignCast(raw.?));
        try std.testing.expect(!req.follow_redirects and req.require_public_address);
        var authenticated = false;
        for (req.headers) |header| if (std.mem.eql(u8, header.name, "x-api-key")) {
            authenticated = std.mem.eql(u8, header.value, "fixture-only-key");
        };
        try std.testing.expect(authenticated);
        const bytes: []const u8 = if (std.mem.eql(u8, req.url, "https://edge.forgecdn.net/files/12/34/example.jar")) blk: {
            self.downloads += 1;
            if (self.telemetry) |task| {
                const pending = task.details();
                try std.testing.expectEqual(.downloading, pending.stage);
                try std.testing.expectEqual(@as(usize, 1), pending.file_count);
                try std.testing.expectEqualStrings("example.jar", pending.files[0].name());
                try std.testing.expectEqual(.downloading, pending.files[0].state);
            }
            break :blk "good";
        } else blk: {
            self.metadata += 1;
            if (std.mem.eql(u8, req.url, "https://api.curseforge.com/v1/mods/12")) break :blk
            \\{"data":{"id":12,"gameId":432,"classId":6,"name":"Example","summary":"Fixture","allowModDistribution":true,"links":{"websiteUrl":"https://www.curseforge.com/minecraft/mc-mods/example"}}}
            ;
            try std.testing.expectEqualStrings("https://api.curseforge.com/v1/mods/12/files/34", req.url);
            break :blk
            \\{"data":{"id":34,"modId":12,"gameId":432,"displayName":"Release","fileName":"example.jar","hashes":[{"algo":1,"value":"fc19318dd13128ce14344d066510a982269c241b"}],"fileLength":4,"isAvailable":true,"downloadUrl":"https://edge.forgecdn.net/files/12/34/example.jar","gameVersions":["1.20.1","Forge"],"dependencies":[]}}
            ;
        };
        return .{ .allocator = alloc, .status = 200, .body = try alloc.dupe(u8, bytes) };
    }
    fn get(raw: *anyopaque, alloc: std.mem.Allocator, _: []const u8) credentials.Error!credentials.Secret {
        const self: *Provider = @ptrCast(@alignCast(raw));
        self.keys += 1;
        return .{ .allocator = alloc, .bytes = try alloc.dupe(u8, "fixture-only-key") };
    }
    fn put(_: *anyopaque, _: []const u8, _: []const u8) credentials.Error!void {
        return error.Denied;
    }
    fn delete(_: *anyopaque, _: []const u8) credentials.Error!void {
        return error.Denied;
    }
    const vtable: credentials.Store.VTable = .{ .get = get, .put = put, .delete = delete };
    fn options(self: *Provider) backend.Options {
        return .{ .source_policy = .{ .enabled = true, .terms_approved = true, .credential_ref = "0123456789abcdef0123456789abcdef".* }, .fixture_credential_store = .{ .ctx = self, .vtable = &vtable }, .transport_options = .{ .allow_curseforge = true, .approved_download_hosts = &.{"edge.forgecdn.net"}, .fixture_http = request, .fixture_context = self } };
    }
};
test "CurseForge archive references are reauthorized and installed only in the private stage" {
    var fixture = try fixtures.Fixture.init();
    defer fixture.deinit();
    const manifest =
        \\{"manifestType":"minecraftModpack","manifestVersion":1,"name":"CF Pack","version":"1","minecraft":{"version":"1.20.1","modLoaders":[{"id":"forge-47.3.0","primary":true}]},"files":[{"projectID":12,"fileID":34,"required":true}],"overrides":"overrides"}
    ;
    try fixtures.zip(fixture.tmp.dir, "pack.zip", &.{ .{ .path = "manifest.json", .bytes = manifest }, .{ .path = "overrides/config/settings.txt", .bytes = "private" } });
    const archive = try fixture.path("pack.zip");
    defer a.free(archive);
    var provider: Provider = .{};
    var cancel: backend.CancelToken = .init(false);
    var inspection = try backend.inspect(a, io, &fixture.paths, .{ .local = archive }, provider.options(), &cancel);
    defer inspection.deinit();
    defer inspection.cleanup(io) catch {};
    try std.testing.expectEqual(@as(usize, 0), inspection.pack.unresolved.len);
    try std.testing.expect(inspection.pack.files[0].authorization != null);
    const stage = try fs.descend(fixture.tmp.dir, io, "private-stage", true);
    defer stage.close(io);
    const path = try fixture.path("private-stage");
    defer a.free(path);
    const loader_version = (try @import("core/pack_loader_version.zig").normalize(a, inspection.pack.loader, inspection.pack.minecraft_version, inspection.pack.loader_version)).?;
    defer a.free(loader_version);
    try std.testing.expectEqualStrings("1.20.1-47.3.0", loader_version);
    var request: backend.Request = .{ .paths = &fixture.paths, .inspection = &inspection, .instance = .{ .id = "cf-pack", .name = "CF Pack", .minecraft_version = "1.20.1", .loader = .forge, .loader_version = loader_version }, .options = provider.options() };
    var telemetry: @import("core/tasks.zig").Task = .{ .id = 0, .title = "pack test", .kind = .modpack_install };
    provider.telemetry = &telemetry;
    request.options.telemetry = &telemetry;
    try backend.precommit(&request, a, io, path, &cancel);
    const details = telemetry.details();
    try std.testing.expectEqual(@as(usize, 1), details.file_count);
    try std.testing.expectEqualStrings("example.jar", details.files[0].name());
    try std.testing.expectEqual(@as(u64, 4), details.received);
    try std.testing.expectEqual(.complete, details.files[0].state);
    try std.testing.expectEqual(.finalizing, details.stage);
    try std.testing.expectEqual(@as(f64, 0), details.bytes_per_second);
    const bytes = try stage.readFileAlloc(io, "mods/example.jar", a, .limited(16));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("good", bytes);
    try stage.access(io, "config/settings.txt", .{});
    try stage.access(io, ".vela/pack-content.json", .{});
    try std.testing.expectEqual(@as(usize, 4), provider.metadata);
    try std.testing.expectEqual(@as(usize, 1), provider.downloads);
    try std.testing.expectEqual(@as(usize, 3), provider.keys);
    const final = try fixture.paths.instanceDirectory("CF Pack");
    defer a.free(final);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, final, .{}));
    request.options.source_policy.enabled = false;
    try std.testing.expectError(error.ProviderDisabled, backend.precommit(&request, a, io, path, &cancel));
    try std.testing.expectEqual(@as(usize, 1), provider.downloads);
}

test "online pack archives above 256 MiB reach transfer while import cap remains enforced" {
    const providers = @import("core/content_providers.zig");
    const packs = @import("core/pack_import.zig");
    const Probe = struct {
        calls: usize = 0,
        fn request(raw: ?*anyopaque, _: std.mem.Allocator, _: std.Io, req: http.Request) !http.Response {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            try std.testing.expectEqual(packs.archive_limit, req.max_response_bytes);
            return error.TransferProbeReached;
        }
    };
    var fixture = try fixtures.Fixture.init();
    defer fixture.deinit();
    var probe: Probe = .{};
    var cancel: backend.CancelToken = .init(false);
    for ([_]u64{ 355708364, packs.archive_limit, packs.archive_limit + 1 }) |size| {
        probe.calls = 0;
        const files = [_]providers.File{.{ .filename = "BattleArmory.mrpack", .primary = true, .size = size, .hashes = .{ .sha1 = "356e4bbce700730e5cbf8b50097afb39f92d27b2" }, .download = .{ .remote = "https://cdn.modrinth.com/data/rQiXwLhB/versions/TX0XBjIG/BattleArmory.mrpack" } }};
        const version: providers.Version = .{ .provider = .modrinth, .project_id = "rQiXwLhB", .id = "TX0XBjIG", .name = "26.0.5", .minecraft_versions = &.{"1.20.1"}, .loaders = &.{"forge"}, .files = &files, .dependencies = &.{} };
        const expected = if (size > packs.archive_limit) error.ArchiveTooLarge else error.TransferProbeReached;
        try std.testing.expectError(expected, backend.inspect(a, io, &fixture.paths, .{ .online = version }, .{ .transport_options = .{ .fixture_http = Probe.request, .fixture_context = &probe } }, &cancel));
        try std.testing.expectEqual(@as(usize, if (size > packs.archive_limit) 0 else 1), probe.calls);
    }
}

test "adapted pack instances prepare and precommit both external archive formats" {
    const packs = @import("core/pack_import.zig");
    const versions = @import("core/pack_loader_version.zig");
    const config = @import("core/config.zig");
    const Case = struct { loader: config.Loader, minecraft: []const u8 = "1.20.1", dependency: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .loader = .forge, .dependency = "47.4.10", .expected = "1.20.1-47.4.10" },
        .{ .loader = .forge, .dependency = "1.20.1-47.4.10", .expected = "1.20.1-47.4.10" },
        .{ .loader = .neoforge, .dependency = "47.1.106", .expected = "1.20.1-47.1.106" },
        .{ .loader = .neoforge, .dependency = "1.20.1-47.1.106", .expected = "1.20.1-47.1.106" },
        .{ .loader = .neoforge, .minecraft = "1.21.1", .dependency = "21.1.80-beta", .expected = "21.1.80-beta" },
        .{ .loader = .fabric, .dependency = "0.16.0", .expected = "0.16.0" },
        .{ .loader = .quilt, .dependency = "0.27.0", .expected = "0.27.0" },
    };
    for ([_]bool{ false, true }) |curseforge| {
        for (cases) |case| {
            var fixture = try fixtures.Fixture.init();
            defer fixture.deinit();
            const bytes = try versionPackManifest(curseforge, case.loader, case.minecraft, case.dependency);
            defer a.free(bytes);
            const archive_name = if (curseforge) "pack.zip" else "pack.mrpack";
            try fixtures.zip(fixture.tmp.dir, archive_name, &.{
                .{ .path = if (curseforge) "manifest.json" else "modrinth.index.json", .bytes = bytes },
                .{ .path = "overrides/config/settings.txt", .bytes = "adapted-instance" },
            });
            const archive = try fixture.path(archive_name);
            defer a.free(archive);
            var cancel: backend.CancelToken = .init(false);
            var inspection = try packs.inspect(a, io, &fixture.paths, archive, &cancel);
            defer inspection.deinit();
            defer inspection.cleanup(io) catch {};
            const adapted = (try versions.normalize(a, inspection.pack.loader, inspection.pack.minecraft_version, inspection.pack.loader_version)).?;
            defer a.free(adapted);
            try std.testing.expectEqualStrings(case.expected, adapted);
            const instance: config.Instance = .{ .id = "pack", .name = "Pack", .minecraft_version = inspection.pack.minecraft_version, .loader = inspection.pack.loader, .loader_version = adapted };
            var prepared = try packs.prepareInspected(a, io, &fixture.paths, instance, &inspection, &cancel);
            defer prepared.deinit();
            defer prepared.cleanup(io) catch {};
            try std.testing.expectEqualStrings(case.dependency, prepared.pack.loader_version.?);
            try std.testing.expectEqual(@as(usize, 1), prepared.files.len);
            const stage = try fs.descend(fixture.tmp.dir, io, "private-stage", true);
            defer stage.close(io);
            const stage_path = try fixture.path("private-stage");
            defer a.free(stage_path);
            var provider: Provider = .{};
            var request: backend.Request = .{ .paths = &fixture.paths, .inspection = &inspection, .instance = instance, .options = provider.options() };
            try backend.precommit(&request, a, io, stage_path, &cancel);
            const installed = try stage.readFileAlloc(io, "config/settings.txt", a, .limited(100));
            defer a.free(installed);
            try std.testing.expectEqualStrings("adapted-instance", installed);
            try stage.access(io, ".vela/pack-content.json", .{});
            try std.testing.expect(try fs.inspectEntry(stage, io, ".vela-pack-work") == null);
            const final = try fixture.paths.instanceDirectory(instance.name);
            defer a.free(final);
            try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, final, .{}));
        }
    }
}

test "pack preparation and precommit reject wrong MC prefixes and unequal loader versions" {
    const packs = @import("core/pack_import.zig");
    const versions = @import("core/pack_loader_version.zig");
    const config = @import("core/config.zig");
    for ([_]bool{ false, true }) |curseforge| {
        for ([_]config.Loader{ .forge, .neoforge }) |loader| {
            for ([_][]const u8{ "1.20.2-47.4.10", "47.4.11", "47.4.10" }) |dependency| {
                var fixture = try fixtures.Fixture.init();
                defer fixture.deinit();
                const bytes = try versionPackManifest(curseforge, loader, "1.20.1", dependency);
                defer a.free(bytes);
                const archive_name = if (curseforge) "pack.zip" else "pack.mrpack";
                try fixtures.zip(fixture.tmp.dir, archive_name, &.{.{ .path = if (curseforge) "manifest.json" else "modrinth.index.json", .bytes = bytes }});
                const archive = try fixture.path(archive_name);
                defer a.free(archive);
                var cancel: backend.CancelToken = .init(false);
                var inspection = try packs.inspect(a, io, &fixture.paths, archive, &cancel);
                defer inspection.deinit();
                defer inspection.cleanup(io) catch {};
                if (std.mem.startsWith(u8, dependency, "1.20.2-"))
                    try std.testing.expectError(error.LoaderVersionMismatch, versions.normalize(a, loader, "1.20.1", dependency));
                // Exercise a wrong pack prefix, a different release, and a wrong
                // instance prefix. None may become equal by stripping prefixes.
                const instance: config.Instance = .{ .id = "pack", .name = "Pack", .minecraft_version = "1.20.1", .loader = loader, .loader_version = if (std.mem.eql(u8, dependency, "47.4.10")) "1.20.2-47.4.10" else "1.20.1-47.4.10" };
                try std.testing.expectError(error.LoaderVersionMismatch, packs.prepareInspected(a, io, &fixture.paths, instance, &inspection, &cancel));
                try std.testing.expectError(error.LoaderVersionMismatch, packs.prepare(a, io, &fixture.paths, instance, archive, &cancel));
                const stage = try fs.descend(fixture.tmp.dir, io, "private-stage", true);
                defer stage.close(io);
                const stage_path = try fixture.path("private-stage");
                defer a.free(stage_path);
                var request: backend.Request = .{ .paths = &fixture.paths, .inspection = &inspection, .instance = instance };
                try std.testing.expectError(error.LoaderVersionMismatch, backend.precommit(&request, a, io, stage_path, &cancel));
                try std.testing.expect(try fs.inspectEntry(stage, io, ".vela") == null);
                try std.testing.expect(try fs.inspectEntry(stage, io, ".vela-pack-work") == null);
            }
        }
    }
}

fn versionPackManifest(curseforge: bool, loader: @import("core/config.zig").Loader, minecraft: []const u8, dependency: []const u8) ![]u8 {
    if (curseforge) return std.fmt.allocPrint(a, "{{\"manifestVersion\":1,\"manifestType\":\"minecraftModpack\",\"name\":\"Pack\",\"version\":\"1\",\"minecraft\":{{\"version\":\"{s}\",\"modLoaders\":[{{\"id\":\"{s}-{s}\",\"primary\":true}}]}},\"files\":[],\"overrides\":\"overrides\"}}", .{ minecraft, @tagName(loader), dependency });
    const key = switch (loader) {
        .fabric => "fabric-loader",
        .quilt => "quilt-loader",
        else => @tagName(loader),
    };
    return std.fmt.allocPrint(a, "{{\"formatVersion\":1,\"game\":\"minecraft\",\"versionId\":\"1\",\"name\":\"Pack\",\"dependencies\":{{\"minecraft\":\"{s}\",\"{s}\":\"{s}\"}},\"files\":[]}}", .{ minecraft, key, dependency });
}

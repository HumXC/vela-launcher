//! Atomic pack installation and UI ownership regression suite.
test {
    _ = @import("application/pack_install_controller.zig");
    _ = @import("core/pack_install.zig");
    _ = @import("pack_source_integration_tests.zig");
    _ = @import("pack_page_tests.zig");
    _ = @import("pack_live_tests.zig");
}
const std = @import("std");
const backend = @import("core/pack_install.zig");
const packs = @import("core/pack_import.zig");
const fs = @import("core/content_fs.zig");
const config = @import("core/config.zig");
const fixtures = @import("pack_install_fixture.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const row: config.Instance = .{ .id = "pack", .name = "Pack", .minecraft_version = "1.21.1" };

test "atomic pack precommit assembles overrides privately and receipt publication is idempotent" {
    var fixture = try fixtures.Fixture.init();
    defer fixture.deinit();
    try fixtures.zip(fixture.tmp.dir, "pack.mrpack", &.{
        .{ .path = "modrinth.index.json", .bytes = fixtures.index },
        .{ .path = "overrides/config/options.txt", .bytes = "verified" },
        .{ .path = "overrides/saves/枪战地图/level.dat", .bytes = "initial map" },
    });
    const archive = try fixture.path("pack.mrpack");
    defer a.free(archive);
    var cancel: backend.CancelToken = .init(false);
    var inspection = try packs.inspect(a, io, &fixture.paths, archive, &cancel, null);
    defer inspection.deinit();
    defer inspection.cleanup(io) catch {};
    const stage = try fs.descend(fixture.tmp.dir, io, ".minecraft/versions/private-stage", true);
    defer stage.close(io);
    const stage_path = try fixture.path(".minecraft/versions/private-stage");
    defer a.free(stage_path);
    var request: backend.Request = .{ .paths = &fixture.paths, .inspection = &inspection, .instance = row };
    try backend.precommit(&request, a, io, stage_path, &cancel);
    const bytes = try stage.readFileAlloc(io, "config/options.txt", a, .limited(100));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("verified", bytes);
    const world = try stage.readFileAlloc(io, "saves/枪战地图/level.dat", a, .limited(100));
    defer a.free(world);
    try std.testing.expectEqualStrings("initial map", world);
    const receipt = try stage.readFileAlloc(io, ".vela/pack-content.json", a, .limited(65536));
    defer a.free(receipt);
    var managed = try @import("core/content_manifest.zig").parse(a, receipt);
    defer managed.deinit();
    try std.testing.expectEqual(@as(usize, 1), managed.value.files.len);
    try std.testing.expectEqualStrings("config/options.txt", managed.value.files[0].path);
    for (managed.value.pack_membership.?.paths) |path| try std.testing.expect(!std.mem.startsWith(u8, path, "saves/"));
    try std.testing.expect(try fs.inspectEntry(stage, io, ".vela-pack-work") == null);
    const versions = try fs.descend(fixture.tmp.dir, io, ".minecraft/versions", false);
    defer versions.close(io);
    try std.testing.expect(try fs.inspectEntry(versions, io, "Pack") == null);
    const manifest_path = try fixture.paths.instanceManifest(row.id);
    defer a.free(manifest_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, manifest_path, .{}));
    try versions.renamePreserve("private-stage", versions, "Pack", io);
    var actual = row;
    actual.origin = .{ .kind = inspection.pack.identity.provider, .project_id = inspection.pack.identity.project_id, .version_id = inspection.pack.identity.version_id };
    try backend.publishManifest(a, io, &fixture.paths, actual);
    try backend.publishManifest(a, io, &fixture.paths, actual);
    try std.Io.Dir.cwd().access(io, manifest_path, .{});
}

test "atomic pack cancellation and game collision never publish final instance" {
    var fixture = try fixtures.Fixture.init();
    defer fixture.deinit();
    try fixtures.zip(fixture.tmp.dir, "pack.mrpack", &.{ .{ .path = "modrinth.index.json", .bytes = fixtures.index }, .{ .path = "overrides/config/options.txt", .bytes = "pack" } });
    const archive = try fixture.path("pack.mrpack");
    defer a.free(archive);
    var cancel: backend.CancelToken = .init(false);
    var inspection = try packs.inspect(a, io, &fixture.paths, archive, &cancel, null);
    defer inspection.deinit();
    defer inspection.cleanup(io) catch {};
    const stage = try fs.descend(fixture.tmp.dir, io, ".minecraft/versions/private-stage", true);
    defer stage.close(io);
    const stage_path = try fixture.path(".minecraft/versions/private-stage");
    defer a.free(stage_path);
    var request: backend.Request = .{ .paths = &fixture.paths, .inspection = &inspection, .instance = row };
    cancel.store(true, .release);
    try std.testing.expectError(error.Canceled, backend.precommit(&request, a, io, stage_path, &cancel));
    cancel.store(false, .release);
    const directory = try fs.child(stage, io, "config", true, false);
    defer directory.close(io);
    try fs.write(directory, io, "options.txt", "game-owned");
    try std.testing.expectError(error.PackGameCollision, backend.precommit(&request, a, io, stage_path, &cancel));
    try std.testing.expect(try fs.inspectEntry(stage, io, ".vela") == null);
    const bytes = try fs.read(a, directory, io, "options.txt", 100);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("game-owned", bytes);
    const final = try fixture.paths.instanceDirectory("Pack");
    defer a.free(final);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, final, .{}));
}

test "atomic pack controller declaration surface" {
    std.testing.refAllDecls(@import("application/pack_install_controller.zig").Controller);
}

test "optional decisions are explicit and manual substitutes retain original hash validation" {
    for ([_]bool{ false, true }) |valid| {
        var fixture = try fixtures.Fixture.init();
        defer fixture.deinit();
        try fixtures.zip(fixture.tmp.dir, "source.mrpack", &.{.{ .path = "modrinth.index.json", .bytes = "{\"formatVersion\":1,\"game\":\"minecraft\",\"versionId\":\"v1\",\"name\":\"Offline Pack\",\"dependencies\":{\"minecraft\":\"1.21.1\"},\"files\":[{\"path\":\"mods/example.jar\",\"hashes\":{\"sha1\":\"fc19318dd13128ce14344d066510a982269c241b\",\"sha512\":\"10259bfe1a41058e4671d05a3b962b774c4b16946b4040bc055059d1859d5f15ec4d7f01ca3f7561632d00add6122d337022a151174e5b9cebf430254b8e9fa7\"},\"fileSize\":4,\"downloads\":[\"https://cdn.modrinth.com/data/example/versions/v1/example.jar\"],\"env\":{\"client\":\"optional\",\"server\":\"optional\"}}]}" }});
        const archive = try fixture.path("source.mrpack");
        defer a.free(archive);
        var cancel: backend.CancelToken = .init(false);
        var inspection = try packs.inspect(a, io, &fixture.paths, archive, &cancel, null);
        defer inspection.deinit();
        defer inspection.cleanup(io) catch {};
        const stage = try fs.descend(fixture.tmp.dir, io, "stage", true);
        defer stage.close(io);
        const stage_path = try fixture.path("stage");
        defer a.free(stage_path);
        var request: backend.Request = .{ .paths = &fixture.paths, .inspection = &inspection, .instance = row };
        try std.testing.expectError(error.OptionalDecisionRequired, backend.precommit(&request, a, io, stage_path, &cancel));
        try fixture.tmp.dir.writeFile(io, .{ .sub_path = "manual.jar", .data = if (valid) "good" else "evil" });
        const manual_path = try fixture.path("manual.jar");
        defer a.free(manual_path);
        request.optional = &.{.{ .path = "mods/example.jar", .include = true }};
        request.manual_files = &.{.{ .path = "mods/example.jar", .source_absolute_path = manual_path }};
        if (valid) {
            try backend.precommit(&request, a, io, stage_path, &cancel);
            const bytes = try stage.readFileAlloc(io, "mods/example.jar", a, .limited(10));
            defer a.free(bytes);
            try std.testing.expectEqualStrings("good", bytes);
        } else {
            try std.testing.expectError(error.HashMismatch, backend.precommit(&request, a, io, stage_path, &cancel));
            try std.testing.expect(try fs.inspectEntry(stage, io, "mods") == null);
            try std.testing.expect(try fs.inspectEntry(stage, io, ".vela") == null);
            try std.testing.expect(try fs.inspectEntry(stage, io, ".vela-pack-work") == null);
        }
    }
}

test "canceling completed inspection before publication discards its late result and private copy" {
    for ([_]bool{ false, true }) |already_ready| {
        var fixture = try fixtures.Fixture.init();
        defer fixture.deinit();
        try fixtures.zip(fixture.tmp.dir, "source.mrpack", &.{.{ .path = "modrinth.index.json", .bytes = fixtures.index }});
        const archive = try fixture.path("source.mrpack");
        defer a.free(archive);
        var controller = try @import("application/pack_install_controller.zig").Controller.init(a, io, &fixture.paths, .{});
        defer controller.deinit(undefined);
        try controller.inspectLocal(archive);
        const job = controller.core.job.?;
        job.thread.?.join();
        job.thread = null;
        const private_copy = try a.dupe(u8, job.inspection.?.stage_absolute_path);
        defer a.free(private_copy);
        if (already_ready) {
            controller.tick(undefined);
            try std.testing.expectEqual(.ready, controller.snapshot().phase);
        }
        controller.cancel(undefined);
        controller.tick(undefined);
        try std.testing.expectEqual(.canceled, controller.snapshot().phase);
        try std.testing.expect(controller.snapshot().pack_plan == null);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, private_copy, .{}));
    }
}

test "pack Forge dependencies from both providers resolve exact catalog coordinates" {
    const manifest = @import("core/content_manifest.zig");
    const loaders = @import("core/loaders/root.zig");
    const adapt = @import("core/pack_loader_version.zig").normalize;
    var catalog = try loaders.parseCatalog(a, .forge, "1.20.1", "{\"1.20.1\":[\"1.20.1-47.4.10\"]}");
    defer catalog.deinit();
    for ([_]bool{ false, true }) |curseforge| {
        for ([_][]const u8{ "47.4.10", "1.20.1-47.4.10", "1.20.2-47.4.10" }) |dependency| {
            const bytes = if (curseforge)
                try std.fmt.allocPrint(a, "{{\"manifestVersion\":1,\"manifestType\":\"minecraftModpack\",\"name\":\"Pack\",\"version\":\"2.3\",\"minecraft\":{{\"version\":\"1.20.1\",\"modLoaders\":[{{\"id\":\"forge-{s}\",\"primary\":true}}]}},\"files\":[],\"overrides\":\"overrides\"}}", .{dependency})
            else
                try std.fmt.allocPrint(a, "{{\"formatVersion\":1,\"game\":\"minecraft\",\"versionId\":\"2.3\",\"name\":\"Pack\",\"dependencies\":{{\"minecraft\":\"1.20.1\",\"forge\":\"{s}\"}},\"files\":[]}}", .{dependency});
            defer a.free(bytes);
            var plan = if (curseforge)
                try manifest.parseCurseForgePack(a, bytes, .{ .provider = .curseforge, .project_id = "1", .version_id = "2" })
            else
                try manifest.parseMrpack(a, bytes, .{ .provider = .modrinth, .project_id = "pack", .version_id = "v2" }, .client);
            defer plan.deinit();
            if (std.mem.startsWith(u8, dependency, "1.20.2-")) {
                try std.testing.expectError(error.LoaderVersionMismatch, adapt(a, plan.value.loader, plan.value.minecraft_version, plan.value.loader_version));
                try std.testing.expectError(error.UnsupportedLoaderVersion, catalog.value.validate(.{ .kind = .forge, .base_id = "1.20.1", .loader_id = dependency }));
                continue;
            }
            const version = (try adapt(a, plan.value.loader, plan.value.minecraft_version, plan.value.loader_version)).?;
            defer a.free(version);
            const selection: loaders.Selection = .{ .kind = .forge, .base_id = plan.value.minecraft_version, .loader_id = version };
            try std.testing.expectEqualStrings("1.20.1-47.4.10", (try catalog.value.validate(selection)).id);
            try std.testing.expectError(error.CatalogMismatch, catalog.value.validate(.{ .kind = .forge, .base_id = "1.20.2", .loader_id = version }));
        }
    }
}

test "pack loader adaptation preserves modern loader contracts and legacy NeoForge" {
    const adapt = @import("core/pack_loader_version.zig").normalize;
    const loaders = @import("core/loaders/root.zig");
    var catalog = try loaders.parseCatalog(a, .neoforge, "1.20.1", "{\"versions\":[\"1.20.1-47.1.106\"]}");
    defer catalog.deinit();
    for ([_][]const u8{ "47.1.106", "1.20.1-47.1.106" }) |input| {
        const version = (try adapt(a, .neoforge, "1.20.1", input)).?;
        defer a.free(version);
        _ = try catalog.value.validate(.{ .kind = .neoforge, .base_id = "1.20.1", .loader_id = version });
    }
    for ([_]config.Loader{ .fabric, .quilt, .neoforge, .vanilla }) |kind| {
        const version = (try adapt(a, kind, "1.21.1", "21.1.80-beta")).?;
        defer a.free(version);
        try std.testing.expectEqualStrings("21.1.80-beta", version);
        try std.testing.expectEqual(null, try adapt(a, kind, "1.21.1", null));
    }
}

const WorldTransport = struct {
    corrupt: bool = false,
    calls: usize = 0,
    fn request(raw: ?*anyopaque, allocator: std.mem.Allocator, _: std.Io, req: @import("core/http_transport.zig").Request) !@import("core/http_transport.zig").Response {
        const self: *WorldTransport = @ptrCast(@alignCast(raw.?));
        try std.testing.expectEqualStrings("https://cdn.modrinth.com/world.dat", req.url);
        try std.testing.expect(req.require_public_address and !req.follow_redirects);
        self.calls += 1;
        const bytes = try allocator.dupe(u8, if (self.corrupt) "evil" else "good");
        return .{ .allocator = allocator, .status = 200, .body = bytes, .allocation = bytes };
    }
};

test "indexed initial maps verify remote and manual bytes preserve optional choices and reject existing installs" {
    const Mode = enum { remote_good, remote_bad, manual_good, manual_bad, exclude, undecided, existing };
    for ([_]Mode{ .remote_good, .remote_bad, .manual_good, .manual_bad, .exclude, .undecided, .existing }) |mode| {
        var fixture = try fixtures.Fixture.init();
        defer fixture.deinit();
        try fixtures.zip(fixture.tmp.dir, "world.mrpack", &.{.{ .path = "modrinth.index.json", .bytes = "{\"formatVersion\":1,\"game\":\"minecraft\",\"versionId\":\"v1\",\"name\":\"World Pack\",\"dependencies\":{\"minecraft\":\"1.21.1\"},\"files\":[{\"path\":\"saves/World/level.dat\",\"hashes\":{\"sha1\":\"fc19318dd13128ce14344d066510a982269c241b\",\"sha512\":\"10259bfe1a41058e4671d05a3b962b774c4b16946b4040bc055059d1859d5f15ec4d7f01ca3f7561632d00add6122d337022a151174e5b9cebf430254b8e9fa7\"},\"fileSize\":4,\"downloads\":[\"https://cdn.modrinth.com/world.dat\"],\"env\":{\"client\":\"optional\",\"server\":\"optional\"}}]}" }});
        const archive = try fixture.path("world.mrpack");
        defer a.free(archive);
        var transport: WorldTransport = .{ .corrupt = mode == .remote_bad };
        var cancel: backend.CancelToken = .init(false);
        const options: backend.Options = .{ .transport_options = .{ .fixture_http = WorldTransport.request, .fixture_context = &transport } };
        var inspection = try backend.inspect(a, io, &fixture.paths, .{ .local = archive }, options, &cancel);
        defer inspection.deinit();
        defer inspection.cleanup(io) catch {};
        try std.testing.expectEqual(@as(usize, 0), inspection.pack.files.len);
        try std.testing.expectEqual(@as(usize, 1), inspection.pack.initial_world_files.len);
        try std.testing.expectError(error.ProtectedPath, packs.prepare(a, io, &fixture.paths, row, archive, &cancel));
        try std.testing.expectError(error.ProtectedPath, packs.prepareInspected(a, io, &fixture.paths, row, &inspection, &cancel));
        const stage = try fs.descend(fixture.tmp.dir, io, "stage", true);
        defer stage.close(io);
        const path = try fixture.path("stage");
        defer a.free(path);
        var request: backend.Request = .{ .paths = &fixture.paths, .inspection = &inspection, .instance = row, .options = options };
        if (mode != .undecided) request.optional = &.{.{ .path = "saves/World/level.dat", .include = mode != .exclude }};
        const manual_path = try fixture.path("manual.dat");
        defer a.free(manual_path);
        if (mode == .manual_good or mode == .manual_bad) {
            try fixture.tmp.dir.writeFile(io, .{ .sub_path = "manual.dat", .data = if (mode == .manual_good) "good" else "evil" });
            request.manual_files = &.{.{ .path = "saves/World/level.dat", .source_absolute_path = manual_path }};
        }
        if (mode == .existing) {
            const existing = try fs.descend(stage, io, "saves/World", true);
            defer existing.close(io);
            try fs.write(existing, io, "level.dat", "user");
        }
        const expected: ?anyerror = switch (mode) {
            .remote_bad => error.Sha1Mismatch,
            .manual_bad => error.HashMismatch,
            .undecided => error.OptionalDecisionRequired,
            .existing => error.PackGameCollision,
            else => null,
        };
        if (expected) |err| {
            try std.testing.expectError(err, backend.precommit(&request, a, io, path, &cancel));
            try std.testing.expect(try fs.inspectEntry(stage, io, ".vela") == null);
            if (mode != .existing) try std.testing.expect(try fs.inspectEntry(stage, io, "saves") == null);
        } else {
            try backend.precommit(&request, a, io, path, &cancel);
            const receipt = try stage.readFileAlloc(io, ".vela/pack-content.json", a, .limited(65536));
            defer a.free(receipt);
            var parsed = try @import("core/content_manifest.zig").parse(a, receipt);
            defer parsed.deinit();
            try std.testing.expectEqual(@as(usize, 0), parsed.value.files.len);
            try std.testing.expectEqual(@as(usize, 0), parsed.value.pack_membership.?.paths.len);
        }
        if (mode == .remote_good or mode == .manual_good or mode == .existing) {
            const bytes = try stage.readFileAlloc(io, "saves/World/level.dat", a, .limited(10));
            defer a.free(bytes);
            try std.testing.expectEqualStrings(if (mode == .existing) "user" else "good", bytes);
        }
        if (mode == .exclude) try std.testing.expect(try fs.inspectEntry(stage, io, "saves") == null);
        if (mode == .exclude or mode == .undecided or mode == .manual_good or mode == .manual_bad) try std.testing.expectEqual(@as(usize, 0), transport.calls);
        try std.testing.expect(try fs.inspectEntry(stage, io, ".vela-pack-work") == null);
    }
}

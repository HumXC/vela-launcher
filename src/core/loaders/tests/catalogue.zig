//! Small projections of live official catalogues and installer base metadata.
//! Only fields needed for compatibility are retained; these are not full recipes
//! or an assertion that every mod works. Processor/launch tests live separately.
const std = @import("std");
const l = @import("../root.zig");
const c = @import("../common.zig");
const a = std.testing.allocator;

// https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/neoforge
// Same coordinates occur in
// https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml
const neo_catalogue =
    \\{"isSnapshot":false,"versions":["0.25w14craftmine.5-beta","20.2.88","21.0.167","21.1.1","26.1.0.0-alpha.2+snapshot-1","26.1.0.0-alpha.15+pre-3","26.1.0.1-beta","26.1.2.71"]}
;
// https://files.minecraftforge.net/net/minecraftforge/forge/maven-metadata.json
const forge_catalogue =
    \\{"1.7.10":["1.7.10-10.13.2.1230","1.7.10-10.13.4.1614-1.7.10"],"1.12.2":["1.12.2-14.23.5.2847","1.12.2-14.23.5.2859"]}
;
// https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/forge
// The API also includes unprefixed 47.1.82; its installer returned 404. Do not
// guess a Minecraft association for that coordinate.
const neo_original =
    \\{"isSnapshot":false,"versions":["1.20.1-47.1.5","1.20.1-47.1.106","47.1.82"]}
;
// Game-scoped APIs actually reject unavailable games (Fabric 400 [], Quilt404).
// https://meta.fabricmc.net/v2/versions/loader/26.1-snapshot-1
const fabric_catalogue =
    \\[{"loader":{"maven":"net.fabricmc:fabric-loader:0.19.5","version":"0.19.5","stable":true}}]
;
// https://meta.quiltmc.org/v3/versions/loader/26.1-snapshot-1
const quilt_catalogue =
    \\[{"loader":{"maven":"org.quiltmc:quilt-loader:0.20.0-beta.9","version":"0.20.0-beta.9"}}]
;

const InstallerAssociation = struct { version: []const u8, minecraft: []const u8, sha1: []const u8 };
// Each downloaded official installer had BOTH install_profile.minecraft and
// version.json.inheritsFrom equal to minecraft below. Archives were inspected,
// never executed. Full URL = official Maven /<version>/neoforge-<version>-installer.jar.
// https://maven.neoforged.net/releases/net/neoforged/neoforge/26.1.0.1-beta/neoforge-26.1.0.1-beta-installer.jar
// https://maven.neoforged.net/releases/net/neoforged/neoforge/26.1.0.0-alpha.2+snapshot-1/neoforge-26.1.0.0-alpha.2+snapshot-1-installer.jar
// https://maven.neoforged.net/releases/net/neoforged/neoforge/0.25w14craftmine.5-beta/neoforge-0.25w14craftmine.5-beta-installer.jar
const installer_associations = [_]InstallerAssociation{
    .{ .version = "26.1.0.1-beta", .minecraft = "26.1", .sha1 = "7d38f2fbcc4cf60bdd81886a45a84b9c576cf50a" },
    .{ .version = "26.1.0.0-alpha.2+snapshot-1", .minecraft = "26.1-snapshot-1", .sha1 = "a1e2eb1d1c73005146c020bd0ba043213c9a60e7" },
    .{ .version = "0.25w14craftmine.5-beta", .minecraft = "25w14craftmine", .sha1 = "a01f0efca33b9cd49b91298a2b593689a7c7efa7" },
};

test "catalogue official NeoForge game association including 26 snapshots and patch releases" {
    const cases = [_]struct { game: []const u8, loader: []const u8, stable: bool }{
        .{ .game = "1.20.2", .loader = "20.2.88", .stable = true },
        .{ .game = "1.21", .loader = "21.0.167", .stable = true },
        .{ .game = "1.21.1", .loader = "21.1.1", .stable = true },
        .{ .game = "26.1", .loader = "26.1.0.1-beta", .stable = false },
        .{ .game = "26.1.2", .loader = "26.1.2.71", .stable = true },
        .{ .game = "26.1-snapshot-1", .loader = "26.1.0.0-alpha.2+snapshot-1", .stable = false },
        .{ .game = "26.1-pre-3", .loader = "26.1.0.0-alpha.15+pre-3", .stable = false },
        .{ .game = "25w14craftmine", .loader = "0.25w14craftmine.5-beta", .stable = false },
    };
    for (cases) |case| {
        var cat = try l.parseCatalog(a, .neoforge, case.game, neo_catalogue);
        defer cat.deinit();
        try std.testing.expectEqual(@as(usize, 1), cat.value.entries.len);
        const entry = try cat.value.validate(.{ .kind = .neoforge, .base_id = case.game, .loader_id = case.loader });
        try std.testing.expectEqual(case.stable, entry.stable);
        try c.trusted(entry.url);
        try std.testing.expect(std.mem.endsWith(u8, entry.url, "-installer.jar"));
        try std.testing.expectError(error.CatalogMismatch, cat.value.validate(.{ .kind = .forge, .base_id = case.game, .loader_id = case.loader }));
        try std.testing.expectError(error.CatalogMismatch, cat.value.validate(.{ .kind = .neoforge, .base_id = "1.12.2", .loader_id = case.loader }));
    }
    for ([_][]const u8{ "1.19.4", "1.20.1", "26.1.0", "26.1-snapshot-10", "26.1-pre-1", "1.26.1", "26.4" }) |game| {
        var cat = try l.parseCatalog(a, .neoforge, game, neo_catalogue);
        defer cat.deinit();
        try std.testing.expectEqual(@as(usize, 0), cat.value.entries.len);
        try std.testing.expectError(error.UnsupportedLoaderVersion, cat.value.validate(.{ .kind = .neoforge, .base_id = game, .loader_id = "26.1.0.1-beta" }));
    }
}

test "catalogue original NeoForge endpoint and historical Forge keyed association" {
    var neo = try l.parseCatalog(a, .neoforge, "1.20.1", neo_original);
    defer neo.deinit();
    try std.testing.expectEqual(@as(usize, 2), neo.value.entries.len);
    try std.testing.expectEqualStrings("https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/forge", neo.value.source_url);
    try std.testing.expectEqualStrings("https://maven.neoforged.net/releases/net/neoforged/forge/1.20.1-47.1.106/forge-1.20.1-47.1.106-installer.jar", neo.value.entries[1].url);
    for ([_][]const u8{ "1.7.10", "1.12.2" }) |game| {
        var forge = try l.parseCatalog(a, .forge, game, forge_catalogue);
        defer forge.deinit();
        try std.testing.expectEqual(@as(usize, 2), forge.value.entries.len);
        for (forge.value.entries) |entry| {
            try std.testing.expect(entry.stable);
            try std.testing.expect(std.mem.startsWith(u8, entry.url, "https://maven.minecraftforge.net/net/minecraftforge/forge/"));
        }
    }
    var unavailable = try l.parseCatalog(a, .forge, "26.1-snapshot-1", forge_catalogue);
    defer unavailable.deinit();
    try std.testing.expectEqual(@as(usize, 0), unavailable.value.entries.len);
}

test "catalogue exact Fabric Quilt selection and stability without Quilt stable field" {
    var fabric = try l.parseCatalog(a, .fabric, "26.1-snapshot-1", fabric_catalogue);
    defer fabric.deinit();
    try std.testing.expect(fabric.value.entries[0].stable);
    try std.testing.expectEqualStrings("https://meta.fabricmc.net/v2/versions/loader/26.1-snapshot-1/0.19.5/profile/json", fabric.value.entries[0].url);
    var quilt = try l.parseCatalog(a, .quilt, "26.1-snapshot-1", quilt_catalogue);
    defer quilt.deinit();
    try std.testing.expect(!quilt.value.entries[0].stable);
    // Synthetic SemVer edge cases, distinct from the live projection above.
    var labels = try l.parseCatalog(a, .quilt, "26.1", "[{\"loader\":{\"version\":\"0.29.2\"}},{\"loader\":{\"version\":\"0.30.0-dev.1\"}},{\"loader\":{\"version\":\"0.30.0-rc.1\"}}]");
    defer labels.deinit();
    try std.testing.expect(labels.value.entries[0].stable);
    try std.testing.expect(!labels.value.entries[1].stable and !labels.value.entries[2].stable);
    try std.testing.expectError(error.UnsupportedLoaderVersion, quilt.value.validate(.{ .kind = .quilt, .base_id = "26.1-snapshot-1", .loader_id = "0.29.2" }));
}

test "catalogue unsupported NeoForge naming formats remain unavailable" {
    for ([_][]const u8{ "0.unknown.1-beta", "26.1.0", "26.1.0.1.2", "26.01.0.1", "26.1.0.1+unknown-1", "26.1.0.1+snapshot-1+pre-1", "26.1.0.1+snapshot-", "21.1.1+snapshot-1", "nonsense" }) |version| {
        try std.testing.expectEqual(@as(?[]const u8, null), try l.neoforgeMinecraftVersion(a, version));
    }
    try std.testing.expectError(error.UnsafeVersionId, l.neoforgeMinecraftVersion(a, "26.1/0.1"));
    try std.testing.expectError(error.DuplicateLoaderVersion, l.parseCatalog(a, .neoforge, "26.1", "{\"versions\":[\"26.1.0.1-beta\",\"26.1.0.1-beta\"]}"));
}

fn vanilla(game: []const u8) !c.m.Owned(c.m.version.Version) {
    const bytes = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"mainClass\":\"vanilla.Main\",\"libraries\":[],\"downloads\":{{\"client\":{{\"url\":\"https://piston-data.mojang.com/client.jar\"}}}}}}", .{game});
    defer a.free(bytes);
    return c.m.version.parseSlice(a, bytes);
}

test "catalogue authoritative installer and profile base are both checked after association" {
    for (installer_associations) |fixture| {
        const association = (try l.neoforgeMinecraftVersion(a, fixture.version)).?;
        defer a.free(association);
        try std.testing.expectEqualStrings(fixture.minecraft, association);
        var base = try vanilla(fixture.minecraft);
        defer base.deinit();
        var cat = try l.parseCatalog(a, .neoforge, fixture.minecraft, neo_catalogue);
        defer cat.deinit();
        const selection: l.Selection = .{ .kind = .neoforge, .base_id = fixture.minecraft, .loader_id = fixture.version };
        const options: l.recipes.Options = .{ .instance_name = "Catalogue base validation", .stage_root = "/fixture-stage", .environment = .{ .os_name = "linux", .arch = "x86_64" } };
        // Deliberately minimal generated profiles preserve the observed base fields;
        // processor inputs are omitted because this test only exercises admission.
        const profile = try std.fmt.allocPrint(a, "{{\"minecraft\":\"{s}\",\"json\":\"/version.json\",\"libraries\":[]}}", .{fixture.minecraft});
        defer a.free(profile);
        const version = try std.fmt.allocPrint(a, "{{\"id\":\"fixture\",\"inheritsFrom\":\"{s}\",\"mainClass\":\"loader.Main\",\"libraries\":[]}}", .{fixture.minecraft});
        defer a.free(version);
        var hash: c.m.Sha1 = undefined;
        _ = try std.fmt.hexToBytes(&hash, fixture.sha1);
        var prepared = try l.prepare(a, cat.value, selection, base.value, .{ .source_url = cat.value.find(fixture.version).?.url, .profile = profile, .version_json = version, .installer_sha1 = hash }, options);
        prepared.deinit();
        try std.testing.expectError(error.BaseVersionMismatch, l.prepare(a, cat.value, selection, base.value, .{ .source_url = cat.value.find(fixture.version).?.url, .profile = "{\"minecraft\":\"wrong-game\",\"json\":\"/version.json\",\"libraries\":[]}", .version_json = version, .installer_sha1 = hash }, options));
        try std.testing.expectError(error.BaseVersionMismatch, l.prepare(a, cat.value, selection, base.value, .{ .source_url = cat.value.find(fixture.version).?.url, .profile = profile, .version_json = "{\"id\":\"fixture\",\"inheritsFrom\":\"wrong-game\",\"mainClass\":\"loader.Main\",\"libraries\":[]}", .installer_sha1 = hash }, options));
    }
}

test "catalogue historical Forge official origins normalize safely without weakening trust" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const g = arena.allocator();
    // Real library/path/checksum projection from the current official 1614 and
    // 2847 installers, whose profiles currently use HTTPS maven.minecraftforge.net.
    // https://maven.minecraftforge.net/net/minecraftforge/forge/1.7.10-10.13.4.1614-1.7.10/forge-1.7.10-10.13.4.1614-1.7.10-installer.jar
    // Installer SHA1 fccafccf8ad4ce6d9f008e786b48ff53172bf9de
    // https://maven.minecraftforge.net/net/minecraftforge/forge/1.12.2-14.23.5.2847/forge-1.12.2-14.23.5.2847-installer.jar
    // asm-all 5.2 SHA1 2ea49e08b876bbd33e0a7ce75c8f371d29e1f10a
    // Scala library 2.11.1 SHA1 0e11da23da3eabab9f4777b9220e60d44c1aab6a
    const path = "org/scala-lang/scala-library/2.11.1/scala-library-2.11.1.jar";
    const expected = try std.fmt.allocPrint(g, "https://maven.minecraftforge.net/{s}", .{path});
    // HTTP/old-host variants below are synthetic historical-equivalence cases.
    for ([_][]const u8{ "http://files.minecraftforge.net/maven/", "https://files.minecraftforge.net/maven/", "http://maven.minecraftforge.net/", "https://maven.minecraftforge.net/" }) |origin| {
        const url = try std.fmt.allocPrint(g, "{s}{s}", .{ origin, path });
        try std.testing.expectEqualStrings(expected, try c.normalizeLibraryUrl(g, url));
    }
    try std.testing.expectEqualStrings("https://libraries.minecraft.net/org/ow2/asm/asm-all/5.2/asm-all-5.2.jar", try c.normalizeLibraryUrl(g, "http://libraries.minecraft.net/org/ow2/asm/asm-all/5.2/asm-all-5.2.jar"));
    for ([_][]const u8{ "http://evil.example/a.jar", "http://maven.minecraftforge.net.evil/a.jar", "http://maven.minecraftforge.net@evil.example/a.jar", "http://maven.minecraftforge.net:80/a.jar", "http://files.minecraftforge.net/other/a.jar", "http://files.minecraftforge.net/maven/../a.jar", "http://files.minecraftforge.net/maven/%2e%2e/a.jar", "http://libraries.minecraft.net/a.jar?redirect=evil", "https://maven.minecraftforge.net/a.jar#fragment" }) |url| {
        try std.testing.expectError(error.UntrustedUrl, c.normalizeLibraryUrl(g, url));
    }
    // Trust itself still refuses plaintext: only metadata normalization upgrades it.
    try std.testing.expectError(error.UntrustedUrl, c.trusted("http://maven.minecraftforge.net/a.jar"));
}

const FakeTransport = struct {
    status: u16,
    bytes: []const u8,
    redirect: ?[]const u8 = null,
    fn get(ctx: ?*anyopaque, allocator: std.mem.Allocator, url: []const u8, max_bytes: usize, control: l.Control) !l.Response {
        const self: *FakeTransport = @ptrCast(@alignCast(ctx.?));
        try control.check();
        try std.testing.expectEqual(@as(usize, 8 * 1024 * 1024), max_bytes);
        const bytes = try allocator.dupe(u8, self.bytes);
        errdefer allocator.free(bytes);
        return .{ .status = self.status, .bytes = bytes, .final_url = try allocator.dupe(u8, self.redirect orelse url) };
    }
    fn transport(self: *FakeTransport) l.Transport {
        return .{ .context = self, .get = get };
    }
};

fn zero(_: ?*anyopaque) u64 {
    return 0;
}
const fixture_control: l.Control = .{ .deadline_ms = 100, .now_ms = zero };

test "catalogue verified unavailable service responses preserve origin and failure semantics" {
    var fake: FakeTransport = .{ .status = 400, .bytes = " []\n" };
    var fabric = try l.fetchCatalog(a, fake.transport(), .fabric, "not-a-real-game", fixture_control);
    defer fabric.deinit();
    try std.testing.expectEqual(@as(usize, 0), fabric.value.entries.len);
    fake.bytes = "{\"error\":\"bad request\"}";
    try std.testing.expectError(error.HttpStatus, l.fetchCatalog(a, fake.transport(), .fabric, "26.1", fixture_control));
    fake.status = 404;
    var quilt = try l.fetchCatalog(a, fake.transport(), .quilt, "not-a-real-game", fixture_control);
    defer quilt.deinit();
    try std.testing.expectEqual(@as(usize, 0), quilt.value.entries.len);
    fake = .{ .status = 200, .bytes = fabric_catalogue, .redirect = "https://maven.minecraftforge.net/catalogue.json" };
    try std.testing.expectError(error.UnexpectedRedirect, l.fetchCatalog(a, fake.transport(), .fabric, "26.1", fixture_control));
}

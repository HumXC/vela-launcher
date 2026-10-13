//! Validated recipe dispatch and arena ownership for all loader providers.
const std = @import("std");
const c = @import("common.zig");
const l = @import("types.zig");
const r = @import("recipe_types.zig");
const m = c.m;
const j = c.j;

pub const Artifact = r.Artifact;
pub const Member = r.Member;
pub const Bundle = r.Bundle;
pub const Options = r.Options;
pub const Recipe = r.Recipe;
pub const JavaRequirements = r.JavaRequirements;
pub const javaRequirements = r.javaRequirements;
pub const digest = r.digest;
pub const mergeArtifact = r.mergeArtifact;

pub fn prepare(a: std.mem.Allocator, catalog: l.Catalog, selection: l.Selection, base: m.version.Version, bundle: Bundle, options: Options) !m.Owned(Recipe) {
    const entry = try catalog.validate(selection);
    if (selection.side != options.side) return error.SideMismatch;
    if (!std.mem.eql(u8, base.id, selection.base_id) or base.inherits_from != null) return error.UnresolvedVanillaBase;
    try m.version.validateId(options.instance_name);
    try c.stageRoot(options.stage_root);
    try c.trusted(bundle.source_url);
    if (!std.mem.eql(u8, entry.url, bundle.source_url)) return error.ProfileProvenanceMismatch;
    if (bundle.profile.len > 8 * 1024 * 1024) return error.MetadataTooLarge;
    const ar = try c.arena(a);
    errdefer {
        ar.deinit();
        a.destroy(ar);
    }
    const g = ar.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, g, bundle.profile, .{ .allocate = .alloc_always, .parse_numbers = false });
    const raw = parsed.value;
    const prepared = switch (selection.kind) {
        .fabric => try @import("../fabric/recipe.zig").build(g, base, raw, bundle, options),
        .quilt => try @import("../quilt/recipe.zig").build(g, base, raw, bundle, options),
        .forge => try @import("../forge/recipe.zig").build(g, base, raw, bundle, options),
        .neoforge => try @import("../neoforge/recipe.zig").build(g, base, raw, bundle, options),
    };
    const game_java = m.version.requiredJavaMajor(prepared.version);
    const install_java = prepared.installer_java_major;
    const value: Recipe = .{
        .selection = .{ .kind = selection.kind, .base_id = try g.dupe(u8, selection.base_id), .loader_id = try g.dupe(u8, selection.loader_id), .side = selection.side },
        .instance_name = try g.dupe(u8, options.instance_name),
        .stage_root = try g.dupe(u8, options.stage_root),
        .version = prepared.version,
        .source_url = try g.dupe(u8, bundle.source_url),
        .source_sha1 = digest(bundle.profile),
        .installer_sha1 = bundle.installer_sha1,
        .artifacts = prepared.artifacts,
        .members = prepared.members,
        .processors = prepared.processors,
        .game_java_major = game_java,
        .installer_java_major = install_java,
    };
    return .{ .arena = ar, .backing = a, .value = value };
}

fn javaFixtureBase(a: std.mem.Allocator, id: []const u8, major: u64) !m.Owned(m.version.Version) {
    const bytes = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"mainClass\":\"vanilla.Main\",\"libraries\":[],\"javaVersion\":{{\"component\":\"fixture\",\"majorVersion\":{d}}},\"downloads\":{{\"client\":{{\"url\":\"https://piston-data.mojang.com/client.jar\"}}}}}}", .{ id, major });
    defer a.free(bytes);
    return m.version.parseSlice(a, bytes);
}
test "Java requirements preserve runtime and Forge floors while profile loaders need no installer JVM" {
    const a = std.testing.allocator;
    const child = "{\"id\":\"fixture-loader\",\"inheritsFrom\":\"1.20.1\",\"mainClass\":\"loader.Main\",\"libraries\":[]}";
    const modern = "{\"minecraft\":\"1.20.1\",\"json\":\"/version.json\",\"libraries\":[],\"data\":{},\"processors\":[]}";
    for ([_]u64{ 8, 17, 21 }) |major| {
        var base = try javaFixtureBase(a, "1.20.1", major);
        defer base.deinit();
        for ([_]l.Kind{ .fabric, .quilt, .forge, .neoforge }) |kind| {
            const catalogue_bytes = switch (kind) {
                .fabric, .quilt => "[{\"loader\":{\"version\":\"0.16.0\",\"stable\":true}}]",
                .forge => "{\"1.20.1\":[\"1.20.1-47.2.0\"]}",
                .neoforge => "{\"versions\":[\"1.20.1-47.2.0\"]}",
            };
            var catalogue = try @import("root.zig").parseCatalog(a, kind, "1.20.1", catalogue_bytes);
            defer catalogue.deinit();
            const entry = catalogue.value.entries[0];
            const modern_loader = kind == .forge or kind == .neoforge;
            var recipe = try prepare(a, catalogue.value, .{ .kind = kind, .base_id = "1.20.1", .loader_id = entry.id }, base.value, .{
                .source_url = entry.url,
                .profile = if (modern_loader) modern else child,
                .version_json = if (modern_loader) child else null,
                .installer_sha1 = if (modern_loader) digest("fixture installer") else null,
            }, .{ .instance_name = "JavaFloors", .stage_root = "/fixture-stage", .environment = .{ .os_name = "linux", .arch = "x86_64" } });
            defer recipe.deinit();
            const requirements = javaRequirements(recipe.value);
            try std.testing.expectEqual(major, requirements.runtime_major);
            try std.testing.expectEqual(if (modern_loader) @max(@as(u64, 8), major) else @as(u64, 0), requirements.installer_major);
            if (!modern_loader) try std.testing.expectEqual(@as(usize, 0), recipe.value.processors.len);
        }
    }
}
test "legacy inherited runtime binpatch remains supported and installer transforms fail with exact errors" {
    const a = std.testing.allocator;
    const legacy_version = "{\"id\":\"legacy-fixture\",\"inheritsFrom\":\"1.7.10\",\"jar\":\"1.7.10\",\"mainClass\":\"net.minecraft.launchwrapper.Launch\",\"libraries\":[{\"name\":\"net.minecraftforge:forge:1.7.10-10.13.4.1614-1.7.10\",\"url\":\"https://maven.minecraftforge.net/\"}]}";
    const install = "\"install\":{\"minecraft\":\"1.7.10\",\"path\":\"net.minecraftforge:forge:1.7.10-10.13.4.1614-1.7.10\",\"filePath\":\"forge-universal.jar\"}";
    const profile = try std.fmt.allocPrint(a, "{{{s},\"versionInfo\":{s}}}", .{ install, legacy_version });
    defer a.free(profile);
    var base = try javaFixtureBase(a, "1.7.10", 17);
    defer base.deinit();
    var catalogue = try @import("root.zig").parseCatalog(a, .forge, "1.7.10", "{\"1.7.10\":[\"1.7.10-10.13.4.1614-1.7.10\"]}");
    defer catalogue.deinit();
    const selection: l.Selection = .{ .kind = .forge, .base_id = "1.7.10", .loader_id = catalogue.value.entries[0].id };
    var bundle: Bundle = .{ .source_url = catalogue.value.entries[0].url, .profile = profile, .installer_sha1 = digest("fixture installer") };
    const options: Options = .{ .instance_name = "LegacyFloors", .stage_root = "/fixture-stage", .environment = .{ .os_name = "linux", .arch = "x86_64" } };
    var recipe = try prepare(a, catalogue.value, selection, base.value, bundle, options);
    defer recipe.deinit();
    try std.testing.expectEqual(@as(u64, 17), javaRequirements(recipe.value).runtime_major);
    try std.testing.expectEqual(@as(u64, 8), javaRequirements(recipe.value).installer_major);
    try std.testing.expectEqualStrings("forge-universal.jar", recipe.value.artifacts[0].member.?);
    const transformed = try std.fmt.allocPrint(a, "{{{s},\"transforms\":[{{}}],\"versionInfo\":{s}}}", .{ install, legacy_version });
    defer a.free(transformed);
    bundle.profile = transformed;
    try std.testing.expectError(error.LegacyForgeTransformsRequired, prepare(a, catalogue.value, selection, base.value, bundle, options));
    const copied = try std.fmt.allocPrint(a, "{{{s},\"versionInfo\":{{\"id\":\"legacy-copy\",\"mainClass\":\"loader.Main\",\"libraries\":[]}}}}", .{install});
    defer a.free(copied);
    bundle.profile = copied;
    try std.testing.expectError(error.MissingUniversalLibrary, prepare(a, catalogue.value, selection, base.value, bundle, options));
}

// Small public metadata excerpts from the authenticated 14.23.5.2859 installer.
const embedded_fixture_coordinate = "net.minecraftforge:forge:1.12.2-14.23.5.2859";
const embedded_fixture_path = "net/minecraftforge/forge/1.12.2-14.23.5.2859/forge-1.12.2-14.23.5.2859.jar";
const embedded_fixture_proof = ",\"sha1\":\"bfc07a510e23e5181b6a32fdcea9c9d9a1445a46\",\"size\":4466108";
const embedded_fixture_library = "{\"name\":\"net.minecraftforge:forge:1.12.2-14.23.5.2859\",\"downloads\":{\"artifact\":{\"path\":\"net/minecraftforge/forge/1.12.2-14.23.5.2859/forge-1.12.2-14.23.5.2859.jar\",\"url\":\"\",\"sha1\":\"bfc07a510e23e5181b6a32fdcea9c9d9a1445a46\",\"size\":4466108}}}";

fn embeddedFixtureLibrary(a: std.mem.Allocator, path: []const u8, proof: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{{\"name\":\"{s}\",\"downloads\":{{\"artifact\":{{\"path\":\"{s}\",\"url\":\"\"{s}}}}}}}", .{ embedded_fixture_coordinate, path, proof });
}

fn embeddedFixturePrepare(a: std.mem.Allocator, root_path: ?[]const u8, version_library: []const u8, root_library: []const u8) !m.Owned(Recipe) {
    const path_field = if (root_path) |path| try std.fmt.allocPrint(a, "\"path\":\"{s}\",", .{path}) else "";
    defer if (root_path != null) a.free(path_field);
    return embeddedFixturePrepareFields(a, path_field, version_library, root_library);
}

fn embeddedFixturePrepareFields(a: std.mem.Allocator, path_field: []const u8, version_library: []const u8, root_library: []const u8) !m.Owned(Recipe) {
    var base = try javaFixtureBase(a, "1.12.2", 8);
    defer base.deinit();
    var catalog = try @import("root.zig").parseCatalog(a, .forge, "1.12.2", "{\"1.12.2\":[\"1.12.2-14.23.5.2859\"]}");
    defer catalog.deinit();
    const profile = try std.fmt.allocPrint(a, "{{\"spec\":0,\"minecraft\":\"1.12.2\",\"json\":\"/version.json\",{s}\"libraries\":[{s}],\"data\":{{}},\"processors\":[]}}", .{ path_field, root_library });
    defer a.free(profile);
    const version = try std.fmt.allocPrint(a, "{{\"id\":\"1.12.2-forge-14.23.5.2859\",\"inheritsFrom\":\"1.12.2\",\"mainClass\":\"net.minecraft.launchwrapper.Launch\",\"libraries\":[{s}]}}", .{version_library});
    defer a.free(version);
    return prepare(a, catalog.value, .{ .kind = .forge, .base_id = "1.12.2", .loader_id = catalog.value.entries[0].id }, base.value, .{
        .source_url = catalog.value.entries[0].url,
        .profile = profile,
        .version_json = version,
        .installer_sha1 = digest("fixture installer"),
    }, .{ .instance_name = "EmbeddedForge", .stage_root = "/fixture-stage", .environment = .{ .os_name = "linux", .arch = "x86_64" } });
}

fn embeddedFixtureAllocationCheck(a: std.mem.Allocator) !void {
    // prepare owns all fields after the catalog, JSON and base are released.
    var recipe = try embeddedFixturePrepare(a, embedded_fixture_coordinate, embedded_fixture_library, embedded_fixture_library);
    defer recipe.deinit();
    try std.testing.expectEqual(@as(usize, 1), recipe.value.artifacts.len);
    const artifact = recipe.value.artifacts[0];
    try std.testing.expectEqualStrings(embedded_fixture_coordinate, artifact.coordinate);
    try std.testing.expectEqualStrings("libraries/" ++ embedded_fixture_path, artifact.path);
    try std.testing.expectEqualStrings("maven/" ++ embedded_fixture_path, artifact.member.?);
    try std.testing.expectEqualStrings("", artifact.url.?);
    try std.testing.expectEqual(@as(u64, 4466108), artifact.size.?);
    try std.testing.expectEqual(try c.sha1("bfc07a510e23e5181b6a32fdcea9c9d9a1445a46"), artifact.sha1.?);
    try std.testing.expectEqual(@as(usize, 0), recipe.value.processors.len);
}

test "authentic 1.12.2 embedded Maven metadata is owned after both library declarations merge" {
    try embeddedFixtureAllocationCheck(std.testing.allocator);
    for ([_]bool{ false, true }) |root_only| {
        var recipe = try embeddedFixturePrepare(std.testing.allocator, embedded_fixture_coordinate, if (root_only) "" else embedded_fixture_library, if (root_only) embedded_fixture_library else "");
        defer recipe.deinit();
        try std.testing.expectEqualStrings("maven/" ++ embedded_fixture_path, recipe.value.artifacts[0].member.?);
    }
}

test "modern embedded Maven binding releases every allocation on OOM" {
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, embeddedFixtureAllocationCheck, .{});
}

test "modern embedded Maven binding requires declared hash and size and canonical paths" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "",
        ",\"size\":4466108",
        ",\"sha1\":null,\"size\":4466108",
        ",\"sha1\":\"bfc07a510e23e5181b6a32fdcea9c9d9a1445a46\"",
    }) |proof| {
        const library = try embeddedFixtureLibrary(a, embedded_fixture_path, proof);
        defer a.free(library);
        try std.testing.expectError(error.MissingEmbeddedArtifactProof, embeddedFixturePrepare(a, embedded_fixture_coordinate, library, library));
    }
    const null_size = try embeddedFixtureLibrary(a, embedded_fixture_path, ",\"sha1\":\"bfc07a510e23e5181b6a32fdcea9c9d9a1445a46\",\"size\":null");
    defer a.free(null_size);
    try std.testing.expectError(error.ExpectedInteger, embeddedFixturePrepare(a, embedded_fixture_coordinate, null_size, null_size));
    const wrong_path = try embeddedFixtureLibrary(a, "../forge.jar", embedded_fixture_proof);
    defer a.free(wrong_path);
    try std.testing.expectError(error.LibraryPathMismatch, embeddedFixturePrepare(a, embedded_fixture_coordinate, wrong_path, wrong_path));
    const wrong_size = try embeddedFixtureLibrary(a, embedded_fixture_path, ",\"sha1\":\"bfc07a510e23e5181b6a32fdcea9c9d9a1445a46\",\"size\":1");
    defer a.free(wrong_size);
    try std.testing.expectError(error.ConflictingArtifact, embeddedFixturePrepare(a, embedded_fixture_coordinate, embedded_fixture_library, wrong_size));
    const wrong_hash = try embeddedFixtureLibrary(a, embedded_fixture_path, ",\"sha1\":\"0000000000000000000000000000000000000000\",\"size\":4466108");
    defer a.free(wrong_hash);
    try std.testing.expectError(error.ConflictingArtifact, embeddedFixturePrepare(a, embedded_fixture_coordinate, embedded_fixture_library, wrong_hash));
}

test "modern absent or unrelated root path preserves empty URL processor routing" {
    for ([_]?[]const u8{ null, "net.minecraftforge:other:1" }) |path| {
        var recipe = try embeddedFixturePrepare(std.testing.allocator, path, embedded_fixture_library, embedded_fixture_library);
        defer recipe.deinit();
        try std.testing.expect(recipe.value.artifacts[0].member == null);
        try std.testing.expectEqualStrings("", recipe.value.artifacts[0].url.?);
    }
}

test "modern JSON null root path is absent while malformed nonstring values fail" {
    const a = std.testing.allocator;
    var recipe = try embeddedFixturePrepareFields(a, "\"path\":null,", embedded_fixture_library, embedded_fixture_library);
    defer recipe.deinit();
    try std.testing.expect(recipe.value.artifacts[0].member == null);
    try std.testing.expectEqualStrings("", recipe.value.artifacts[0].url.?);
    for ([_][]const u8{ "\"path\":true,", "\"path\":42,", "\"path\":[],", "\"path\":{}," }) |path_field| {
        try std.testing.expectError(error.ExpectedString, embeddedFixturePrepareFields(a, path_field, embedded_fixture_library, embedded_fixture_library));
    }
}

// Unmodified install_profile.json from the official 14.23.5.2860 installer:
// https://maven.minecraftforge.net/net/minecraftforge/forge/1.12.2-14.23.5.2860/forge-1.12.2-14.23.5.2860-installer.jar
// Official installer SHA1: 5e8a91f71ef3d1f77de3f8d3261aedcc2f551c9d.
test "authentic Forge 2860 recipe keeps embedded runtime authority through Java 8 launch planning" {
    const a = std.testing.allocator;
    const install = @import("../minecraft/install_plan.zig");
    const launch = @import("../minecraft/launch.zig");
    const coordinate = "net.minecraftforge:forge:1.12.2-14.23.5.2860";
    const path = "libraries/net/minecraftforge/forge/1.12.2-14.23.5.2860/forge-1.12.2-14.23.5.2860.jar";
    const installer_hash = try c.sha1("5e8a91f71ef3d1f77de3f8d3261aedcc2f551c9d");
    var base = try m.version.parseSlice(a, @embedFile("../launch_fixtures/vanilla_1_12_2_version.json"));
    defer base.deinit();
    var catalog = try @import("root.zig").parseCatalog(a, .forge, "1.12.2", "{\"1.12.2\":[\"1.12.2-14.23.5.2860\"]}");
    defer catalog.deinit();
    for ([_][]const u8{ "linux", "windows", "osx" }) |os| {
        const env: m.rules.Environment = .{ .os_name = os, .arch = "x86_64" };
        var recipe = try prepare(a, catalog.value, .{ .kind = .forge, .base_id = "1.12.2", .loader_id = "1.12.2-14.23.5.2860" }, base.value, .{
            .source_url = catalog.value.entries[0].url,
            .profile = @embedFile("fixtures/forge_1_12_2_install.json"),
            .version_json = @embedFile("../launch_fixtures/forge_1_12_2_version.json"),
            .installer_sha1 = installer_hash,
        }, .{ .instance_name = "Forge 2860", .stage_root = "/fixture-stage", .environment = env });
        defer recipe.deinit();
        try std.testing.expectEqual(@as(usize, 0), recipe.value.processors.len);
        try std.testing.expectEqual(@as(usize, 2), recipe.value.members.len);
        try std.testing.expectEqual(@as(u64, 8), recipe.value.game_java_major);
        try std.testing.expectEqual(@as(u64, 8), recipe.value.installer_java_major);
        try std.testing.expectEqual(installer_hash, recipe.value.installer_sha1.?);
        var embedded: usize = 0;
        for (recipe.value.artifacts) |artifact| {
            try std.testing.expect(artifact.producer == null);
            if (!std.mem.eql(u8, artifact.coordinate, coordinate)) {
                try std.testing.expect(artifact.member == null);
                try std.testing.expect(artifact.url != null and artifact.url.?.len != 0);
                continue;
            }
            embedded += 1;
            try std.testing.expectEqualStrings(path, artifact.path);
            try std.testing.expectEqualStrings("maven/net/minecraftforge/forge/1.12.2-14.23.5.2860/forge-1.12.2-14.23.5.2860.jar", artifact.member.?);
            try std.testing.expectEqualStrings("", artifact.url.?);
            try std.testing.expectEqual(try c.sha1("029250575d3aa2cf80b56dffb66238a1eeaea2ac"), artifact.sha1.?);
            try std.testing.expectEqual(@as(u64, 4466148), artifact.size.?);
        }
        try std.testing.expectEqual(@as(usize, 1), embedded);
        // The download planner handles vanilla sources. Embedded runtime paths
        // come from the verified recipe rather than a fabricated download URL.
        var base_plan = try install.build(a, base.value, .{ .objects = &.{}, .virtual = null, .map_to_resources = null }, env, .{ .root = "/fixture-stage", .native_arch = .bits64, .cpu_arch = "x86_64" });
        defer base_plan.deinit();
        const g = recipe.arena.allocator();
        var classpath: std.ArrayList([]const u8) = .empty;
        try classpath.appendSlice(g, base_plan.value.classpath);
        for (recipe.value.artifacts) |artifact| {
            var runtime = false;
            for (recipe.value.version.libraries.?) |library| {
                if (std.mem.eql(u8, library.name, artifact.coordinate)) runtime = true;
            }
            if (!runtime) continue;
            const installed = try c.join(g, recipe.value.stage_root, artifact.path);
            var duplicate = false;
            for (classpath.items) |entry| {
                if (std.mem.eql(u8, installed, entry)) duplicate = true;
            }
            if (!duplicate) try classpath.append(g, installed);
        }
        var plan = base_plan.value;
        plan.classpath = classpath.items;
        try std.testing.expectEqualStrings("/fixture-stage/versions/1.12.2/1.12.2.jar", plan.client_path);
        var classpath_entries: usize = 0;
        for (plan.classpath) |entry| {
            if (std.mem.eql(u8, entry, "/fixture-stage/" ++ path)) classpath_entries += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), classpath_entries);
        var command = try launch.build(a, recipe.value.version, plan, env, .{
            .root = "/fixture-stage",
            .java_executable = "/fixture-java8/bin/java",
            .identity = .{ .name = "Player", .uuid = "1234" },
        });
        defer command.deinit();
        var main_count: usize = 0;
        var tweak_count: usize = 0;
        for (command.value.argv, 0..) |arg, index| {
            if (std.mem.eql(u8, arg, "net.minecraft.launchwrapper.Launch")) main_count += 1;
            if (std.mem.eql(u8, arg, "--tweakClass")) {
                try std.testing.expect(index + 1 < command.value.argv.len);
                try std.testing.expectEqualStrings("net.minecraftforge.fml.common.launcher.FMLTweaker", command.value.argv[index + 1]);
                tweak_count += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), main_count);
        try std.testing.expectEqual(@as(usize, 1), tweak_count);
    }
}

const flat_profile = @embedFile("fixtures/forge_1_7_10_1230_install.json");
fn flatFixturePrepare(base: m.version.Version, profile: []const u8, os: []const u8) !m.Owned(Recipe) {
    const a = std.testing.allocator;
    var catalog = try @import("root.zig").parseCatalog(a, .forge, "1.7.10", "{\"1.7.10\":[\"1.7.10-10.13.2.1230\"]}");
    defer catalog.deinit();
    return prepare(a, catalog.value, .{ .kind = .forge, .base_id = "1.7.10", .loader_id = "1.7.10-10.13.2.1230" }, base, .{
        .source_url = catalog.value.entries[0].url,
        .profile = profile,
        .installer_sha1 = try c.sha1("31af0f4ebbca4641de767047b3b840ac5d0ba2c7"),
    }, .{ .instance_name = "Forge 1230", .stage_root = "/fixture-stage", .environment = .{ .os_name = os, .arch = "x86_64" } });
}
fn flatFixtureLibrary(raw: std.json.Value, name: []const u8) !*std.json.Value {
    for (raw.object.get("libraries").?.array.items) |*library| {
        if (std.mem.eql(u8, library.object.get("name").?.string, name)) return library;
    }
    return error.MissingFixtureLibrary;
}
// Unmodified official install_profile.json from the Forge 1230 installer
// (official .sha1: 31af0f4ebbca4641de767047b3b840ac5d0ba2c7), paired with Mojang:
// https://piston-meta.mojang.com/v1/packages/ed5d8789ed29872ea2ef1c348302b0c55e3f3468/1.7.10.json
// The recipe consumes the authenticated descriptors; this test starts after ZIP verification.
test "authentic flat Forge 1230 keeps vanilla native proofs and Java 8 launch plan" {
    const a = std.testing.allocator;
    const install = @import("../minecraft/install_plan.zig");
    const launch = @import("../minecraft/launch.zig");
    var base = try m.version.parseSlice(a, @embedFile("../launch_fixtures/vanilla_1_7_10_version.json"));
    defer base.deinit();
    for ([_][]const u8{ "linux", "windows", "osx" }) |os| {
        var recipe = try flatFixturePrepare(base.value, flat_profile, os);
        defer recipe.deinit();
        try std.testing.expectEqualStrings("1.7.10", recipe.value.version.jar.?);
        try std.testing.expectEqualStrings("Forge 1230", recipe.value.version.id);
        try std.testing.expectEqual(@as(u64, 8), recipe.value.game_java_major);
        try std.testing.expectEqual(@as(u64, 8), recipe.value.installer_java_major);
        try std.testing.expectEqual(@as(usize, 0), recipe.value.processors.len);
        var native_libraries: usize = 0;
        for (recipe.value.version.libraries.?) |library| {
            if (library.natives.len == 0) continue;
            native_libraries += 1;
            var found = false;
            for (base.value.libraries.?) |vanilla| {
                if (!std.mem.eql(u8, vanilla.name, library.name)) continue;
                try std.testing.expectEqualDeep(vanilla, library);
                found = true;
            }
            try std.testing.expect(found);
            for (recipe.value.artifacts) |artifact| try std.testing.expect(!std.mem.eql(u8, library.name, artifact.coordinate));
        }
        try std.testing.expectEqual(@as(usize, 4), native_libraries);
        var embedded: usize = 0;
        for (recipe.value.artifacts) |artifact| {
            if (artifact.member) |member| {
                embedded += 1;
                try std.testing.expectEqualStrings("forge-1.7.10-10.13.2.1230-universal.jar", member);
                try std.testing.expectEqualStrings("net.minecraftforge:forge:1.7.10-10.13.2.1230", artifact.coordinate);
                try std.testing.expect(artifact.url == null and artifact.producer == null);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), embedded);
        const env: m.rules.Environment = .{ .os_name = os, .arch = "x86_64" };
        const directories: install.Directories = .{ .root = "/fixture-stage", .instance_name = "Forge 1230", .native_arch = .bits64, .cpu_arch = "x86_64" };
        const assets: m.asset_index.AssetIndex = .{ .objects = &.{}, .virtual = null, .map_to_resources = null };
        var vanilla_plan = try install.build(a, base.value, assets, env, directories);
        defer vanilla_plan.deinit();
        var plan = try install.build(a, recipe.value.version, assets, env, directories);
        defer plan.deinit();
        try std.testing.expectEqualDeep(vanilla_plan.value.native_extractions, plan.value.native_extractions);
        try std.testing.expectEqualDeep(vanilla_plan.value.native_checks, plan.value.native_checks);
        try std.testing.expect(plan.value.native_extractions.len >= 2);
        var native_files: usize = 0;
        for (plan.value.files) |file| {
            if (file.kind != .native) continue;
            native_files += 1;
            var found = false;
            for (vanilla_plan.value.files) |vanilla| {
                if (vanilla.kind == .native and std.mem.eql(u8, vanilla.path, file.path)) {
                    try std.testing.expectEqualDeep(vanilla, file);
                    try std.testing.expect(file.sha1 != null and file.size != null and file.size.? > 0);
                    found = true;
                }
            }
            try std.testing.expect(found);
        }
        try std.testing.expectEqual(plan.value.native_extractions.len, native_files);
        try std.testing.expectEqualStrings("/fixture-stage/versions/1.7.10/1.7.10.jar", plan.value.client_path);
        var forge_classpath: usize = 0;
        for (plan.value.classpath) |entry| {
            if (std.mem.eql(u8, entry, "/fixture-stage/libraries/net/minecraftforge/forge/1.7.10-10.13.2.1230/forge-1.7.10-10.13.2.1230.jar")) forge_classpath += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), forge_classpath);
        var command = try launch.build(a, recipe.value.version, plan.value, env, .{ .root = "/fixture-stage", .java_executable = "/fixture-java8/bin/java", .identity = .{ .name = "Player", .uuid = "1234" } });
        defer command.deinit();
        var main: usize = 0;
        var tweak: usize = 0;
        for (command.value.argv, 0..) |arg, i| {
            if (std.mem.eql(u8, arg, "net.minecraft.launchwrapper.Launch")) main += 1;
            if (std.mem.eql(u8, arg, "--tweakClass")) {
                try std.testing.expectEqualStrings("cpw.mods.fml.common.launcher.FMLTweaker", command.value.argv[i + 1]);
                tweak += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), main);
        try std.testing.expectEqual(@as(usize, 1), tweak);
    }
}
test "flat native inheritance rejects additions mismatches and hidden OS spoofing" {
    const a = std.testing.allocator;
    var base = try m.version.parseSlice(a, @embedFile("../launch_fixtures/vanilla_1_7_10_version.json"));
    defer base.deinit();
    // Twitch is disallowed on Linux. Every mutation must still be validated.
    const cases = [_]struct { key: []const u8, value: []const u8, expected: anyerror }{
        .{ .key = "name", .value = "\"loader:added-natives:1\"", .expected = error.LoaderNativeLibraryRequiresVanillaPlan },
        .{ .key = "name", .value = "\"tv.twitch:twitch-platform:5.17\"", .expected = error.LoaderNativeLibraryRequiresVanillaPlan },
        .{ .key = "natives", .value = "{\"linux\":\"natives-linux\",\"osx\":\"natives-osx\",\"windows\":\"natives-spoof\"}", .expected = error.LoaderNativeLibraryMismatch },
        .{ .key = "natives", .value = "{}", .expected = error.LoaderNativeLibraryMismatch },
        .{ .key = "rules", .value = "[]", .expected = error.LoaderNativeLibraryMismatch },
        .{ .key = "extract", .value = "{\"exclude\":[]}", .expected = error.LoaderNativeLibraryMismatch },
        .{ .key = "url", .value = "\"https://maven.minecraftforge.net/\"", .expected = error.LoaderNativeLibraryMismatch },
        .{ .key = "url", .value = "\"https://example.invalid/\"", .expected = error.UntrustedUrl },
        .{ .key = "checksums", .value = "[\"0000000000000000000000000000000000000000\"]", .expected = error.LoaderNativeLibraryMismatch },
        .{ .key = "clientreq", .value = "false", .expected = error.LoaderNativeLibraryMismatch },
        .{ .key = "clientreq", .value = "\"malformed\"", .expected = error.ExpectedBoolean },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, a, flat_profile, .{});
        defer parsed.deinit();
        const g = parsed.arena.allocator();
        const library = try flatFixtureLibrary(parsed.value.object.get("versionInfo").?, "tv.twitch:twitch-platform:5.16");
        const value = try std.json.parseFromSlice(std.json.Value, g, case.value, .{});
        try library.object.put(g, case.key, value.value);
        const bytes = try std.json.Stringify.valueAlloc(g, parsed.value, .{});
        try std.testing.expectError(case.expected, flatFixturePrepare(base.value, bytes, "linux"));
    }
    var parsed = try std.json.parseFromSlice(std.json.Value, a, flat_profile, .{});
    defer parsed.deinit();
    const g = parsed.arena.allocator();
    // Explicit inheritance is outside the flat-profile exception.
    try parsed.value.object.getPtr("versionInfo").?.object.put(g, "inheritsFrom", .{ .string = "1.7.10" });
    try std.testing.expectError(error.LoaderNativeLibraryRequiresVanillaPlan, flatFixturePrepare(base.value, try std.json.Stringify.valueAlloc(g, parsed.value, .{}), "linux"));
}
test "flat native explicit download proofs must equal verified vanilla metadata" {
    const a = std.testing.allocator;
    var base = try m.version.parseSlice(a, @embedFile("../launch_fixtures/vanilla_1_7_10_version.json"));
    defer base.deinit();
    const cases = [_]struct { key: ?[]const u8, value: []const u8 }{
        .{ .key = null, .value = "null" },
        .{ .key = "sha1", .value = "\"0000000000000000000000000000000000000000\"" },
        .{ .key = "size", .value = "1" },
        .{ .key = "path", .value = "\"spoof/native.jar\"" },
        .{ .key = "url", .value = "\"https://maven.minecraftforge.net/spoof.jar\"" },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, a, flat_profile, .{});
        defer parsed.deinit();
        const g = parsed.arena.allocator();
        const vanilla = try std.json.parseFromSlice(std.json.Value, g, @embedFile("../launch_fixtures/vanilla_1_7_10_version.json"), .{});
        const library = try flatFixtureLibrary(parsed.value.object.get("versionInfo").?, "org.lwjgl.lwjgl:lwjgl-platform:2.9.1");
        const original = try flatFixtureLibrary(vanilla.value, "org.lwjgl.lwjgl:lwjgl-platform:2.9.1");
        try library.object.put(g, "downloads", original.object.get("downloads").?);
        try library.object.put(g, "url", .{ .string = "https://libraries.minecraft.net/" });
        if (case.key) |key| {
            const descriptor = library.object.getPtr("downloads").?.object.getPtr("classifiers").?.object.getPtr("natives-linux").?;
            const value = try std.json.parseFromSlice(std.json.Value, g, case.value, .{});
            try descriptor.object.put(g, key, value.value);
        }
        const bytes = try std.json.Stringify.valueAlloc(g, parsed.value, .{});
        if (case.key != null) {
            try std.testing.expectError(error.LoaderNativeLibraryMismatch, flatFixturePrepare(base.value, bytes, "linux"));
        } else {
            var recipe = try flatFixturePrepare(base.value, bytes, "linux");
            recipe.deinit();
        }
    }
    const libraries_copy = try a.dupe(m.version.Library, base.value.libraries.?);
    defer a.free(libraries_copy);
    var unproven = base.value;
    unproven.libraries = libraries_copy;
    for (libraries_copy) |*library| {
        if (library.natives.len != 0) library.downloads = null;
    }
    try std.testing.expectError(error.LoaderNativeLibraryRequiresVanillaPlan, flatFixturePrepare(unproven, flat_profile, "linux"));
}

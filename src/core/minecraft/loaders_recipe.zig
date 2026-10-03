//! Forge spec: https://github.com/MinecraftForge/Installer/blob/2.0/src/main/java/net/minecraftforge/installer/actions/PostProcessors.java
//! Legacy runtime patches: https://github.com/MinecraftForge/FML/blob/1.7.10/src/main/java/cpw/mods/fml/common/asm/transformers/PatchingTransformer.java
const std = @import("std");
const c = @import("loaders_common.zig");
const l = @import("loaders.zig");
const p = @import("loaders_processors.zig");
const m = c.m;
const j = c.j;
pub const Artifact = struct { coordinate: []const u8, path: []const u8, url: ?[]const u8, sha1: ?m.Sha1, size: ?u64, member: ?[]const u8 = null };
pub const Member = struct { source: []const u8, destination: []const u8, sha1: ?m.Sha1 = null };
pub const Bundle = struct {
    source_url: []const u8,
    /// Official JSON profile, or install_profile.json extracted from verified ZIP.
    profile: []const u8,
    /// Required for modern Forge/NeoForge's referenced json member.
    version_json: ?[]const u8 = null,
    /// Required for installers. Obtained from official .sha1 metadata, never user input.
    installer_sha1: ?m.Sha1 = null,
};
pub const Options = struct { instance_name: []const u8, stage_root: []const u8, environment: m.rules.Environment, side: c.Side = .client };
pub const Recipe = struct {
    selection: l.Selection,
    instance_name: []const u8,
    stage_root: []const u8,
    version: m.version.Version,
    source_url: []const u8,
    source_sha1: m.Sha1,
    installer_sha1: ?m.Sha1,
    artifacts: []const Artifact,
    members: []const Member,
    processors: []const p.Processor,
    game_java_major: u64,
    installer_java_major: u64,
};
pub const JavaRequirements = struct { runtime_major: u64, installer_major: u64 };

pub fn javaRequirements(recipe: Recipe) JavaRequirements {
    return .{ .runtime_major = recipe.game_java_major, .installer_major = recipe.installer_java_major };
}

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
    const installer = selection.kind == .forge or selection.kind == .neoforge;
    var profile_raw = raw;
    var members: std.ArrayList(Member) = .empty;
    var embedded_coordinate: ?[]const u8 = null;
    var embedded_member: ?[]const u8 = null;
    var modern = false;
    if (installer) {
        if (bundle.installer_sha1 == null) return error.MissingInstallerChecksum;
        try members.append(g, .{ .source = "install_profile.json", .destination = ".loader/profile.json", .sha1 = digest(bundle.profile) });
        if (try j.optional(raw, "versionInfo")) |old| {
            const install = try j.required(raw, "install");
            if (!std.mem.eql(u8, try c.text(try j.required(install, "minecraft")), base.id)) return error.BaseVersionMismatch;
            // Ordinary inherited 1.7.10 uses FML runtime binpatching. Explicitly
            // reject installer-side transforms instead of skipping them.
            if (try j.optional(install, "transforms")) |v| if ((try j.array(v)).len != 0) return error.LegacyForgeTransformsRequired;
            if (try j.optional(raw, "transforms")) |v| if ((try j.array(v)).len != 0) return error.LegacyForgeTransformsRequired;
            profile_raw = old;
            embedded_coordinate = try c.text(try j.required(install, "path"));
            embedded_member = try c.text(try j.required(install, "filePath"));
            try c.relative(embedded_member.?);
        } else {
            modern = true;
            if (!std.mem.eql(u8, try c.text(try j.required(raw, "minecraft")), base.id)) return error.BaseVersionMismatch;
            const member = try c.text(try j.required(raw, "json"));
            const normalized = std.mem.trimStart(u8, member, "/");
            try c.relative(normalized);
            const bytes = bundle.version_json orelse return error.MissingInstallerVersionJson;
            if (bytes.len > 8 * 1024 * 1024) return error.MetadataTooLarge;
            const version_parsed = try std.json.parseFromSlice(std.json.Value, g, bytes, .{ .allocate = .alloc_always, .parse_numbers = false });
            profile_raw = version_parsed.value;
            try members.append(g, .{ .source = try g.dupe(u8, normalized), .destination = ".loader/version.json", .sha1 = digest(bytes) });
        }
    }
    const child = try m.version.parseValue(g, profile_raw);
    if (!std.mem.eql(u8, child.value.inherits_from orelse return error.LegacyForgeVanillaCopyRequired, base.id)) return error.BaseVersionMismatch;
    if (child.value.jar) |jar| if (!std.mem.eql(u8, jar, base.id)) return error.BaseVersionMismatch;
    var merged = try m.version.inheritance.resolve(g, child.value.id, &.{ child.value, base }, .{});
    merged.value.id = try g.dupe(u8, options.instance_name);
    var artifacts: std.ArrayList(Artifact) = .empty;
    try libraries(g, profile_raw, child.value.libraries orelse &.{}, options, &artifacts);
    if (embedded_coordinate) |coordinate| {
        var found = false;
        for (artifacts.items) |*artifact| if (std.mem.eql(u8, coordinate, artifact.coordinate)) {
            artifact.url = null;
            artifact.member = try g.dupe(u8, embedded_member.?);
            found = true;
        };
        if (!found) return error.MissingUniversalLibrary;
    }
    var root_libraries: []const m.version.Library = &.{};
    if (modern) {
        // Reuse structured decoder for installer library descriptors.
        var object: std.json.ObjectMap = .empty;
        try object.put(g, "id", .{ .string = "installer-libraries" });
        try object.put(g, "libraries", try j.required(raw, "libraries"));
        const holder: std.json.Value = .{ .object = object };
        const install_libraries = try m.version.parseValue(g, holder);
        root_libraries = install_libraries.value.libraries orelse &.{};
        try libraries(g, holder, root_libraries, options, &artifacts);
    }
    var processors: []const p.Processor = &.{};
    if (modern) {
        processors = try p.build(g, raw, artifacts.items, options.stage_root, base.id, options.side, &members);
        try bindModernEmbedded(g, raw, root_libraries, artifacts.items, processors, options.stage_root);
    }
    const game_java = m.version.requiredJavaMajor(merged.value);
    const install_java = if (modern) @max(@as(u64, 8), game_java) else 8;
    const value: Recipe = .{
        .selection = .{ .kind = selection.kind, .base_id = try g.dupe(u8, selection.base_id), .loader_id = try g.dupe(u8, selection.loader_id), .side = selection.side },
        .instance_name = try g.dupe(u8, options.instance_name),
        .stage_root = try g.dupe(u8, options.stage_root),
        .version = merged.value,
        .source_url = try g.dupe(u8, bundle.source_url),
        .source_sha1 = digest(bundle.profile),
        .installer_sha1 = bundle.installer_sha1,
        .artifacts = try artifacts.toOwnedSlice(g),
        .members = try members.toOwnedSlice(g),
        .processors = processors,
        .game_java_major = game_java,
        .installer_java_major = install_java,
    };
    return .{ .arena = ar, .backing = a, .value = value };
}
// Only the installer's named artifact is eligible for embedded Maven authority.
// Empty URLs for other coordinates retain their processor-output semantics.
fn bindModernEmbedded(a: std.mem.Allocator, raw: std.json.Value, root_libraries: []const m.version.Library, artifacts: []Artifact, processors: []const p.Processor, stage_root: []const u8) !void {
    const value = (try j.optional(raw, "path")) orelse return;
    if (value == .null) return;
    const coordinate = try c.text(value);
    for (artifacts) |*artifact| {
        if (!std.mem.eql(u8, coordinate, artifact.coordinate)) continue;
        const url = artifact.url orelse continue;
        if (url.len != 0) continue;
        // A declared processor output retains its existing generated authority,
        // even when it is the installer's named coordinate.
        const destination = try c.join(a, stage_root, artifact.path);
        var generated = false;
        for (processors) |processor| {
            for (processor.outputs) |output| {
                if (std.mem.eql(u8, output.path, destination)) generated = true;
            }
        }
        if (generated) continue;
        if (artifact.sha1 == null or artifact.size == null) return error.MissingEmbeddedArtifactProof;
        // Root and linked-version declarations must agree, including size.
        // The shared library merge already rejects differing URLs and hashes.
        for (root_libraries) |library| {
            if (!std.mem.eql(u8, coordinate, library.name)) continue;
            const downloads = library.downloads orelse return error.MissingEmbeddedArtifactProof;
            const download = downloads.artifact orelse return error.MissingEmbeddedArtifactProof;
            if (!std.meta.eql(download.sha1, artifact.sha1) or !std.meta.eql(download.size, artifact.size)) return error.ConflictingArtifact;
        }
        const parsed = try m.version.mavenCoordinate(coordinate);
        const canonical = try parsed.path(a, null);
        const path = try std.fmt.allocPrint(a, "libraries/{s}", .{canonical});
        try c.relative(path);
        if (!std.mem.eql(u8, path, artifact.path)) return error.LibraryPathMismatch;
        const member = try std.fmt.allocPrint(a, "maven/{s}", .{canonical});
        try c.relative(member);
        artifact.member = member;
    }
}

pub fn digest(bytes: []const u8) m.Sha1 {
    var result: m.Sha1 = undefined;
    std.crypto.hash.Sha1.hash(bytes, &result, .{});
    return result;
}
fn libraries(a: std.mem.Allocator, raw: std.json.Value, decoded: []const m.version.Library, options: Options, out: *std.ArrayList(Artifact)) !void {
    const raw_libraries = try j.array(try j.required(raw, "libraries"));
    for (decoded, 0..) |library, index| {
        const source = raw_libraries[index];
        if (try j.optional(source, if (options.side == .client) "clientreq" else "serverreq")) |required| if (!try j.boolean(required)) continue;
        if (!try m.rules.allows(library.rules, options.environment)) continue;
        if (library.natives.len != 0) return error.LoaderNativeLibraryRequiresVanillaPlan;
        const coordinate = try m.version.mavenCoordinate(library.name);
        const expected_path = try coordinate.path(a, null);
        const path = try std.fmt.allocPrint(a, "libraries/{s}", .{expected_path});
        try c.relative(path);
        var url: []const u8 = undefined;
        var hash: ?m.Sha1 = null;
        var size: ?u64 = null;
        if (library.downloads) |downloads| {
            const download = downloads.artifact orelse return error.MissingLibraryDownload;
            if (download.path) |download_path| if (!std.mem.eql(u8, download_path, expected_path)) return error.LibraryPathMismatch;
            url = download.url;
            hash = download.sha1;
            size = download.size;
        } else {
            const root = library.url orelse "https://libraries.minecraft.net/";
            url = try std.fmt.allocPrint(a, "{s}/{s}", .{ std.mem.trimEnd(u8, root, "/"), expected_path });
            if (try j.optional(source, "checksums")) |checksums| {
                const list = try j.array(checksums);
                if (list.len > 0) hash = try c.sha1(try c.text(list[0]));
            }
        }
        if (url.len != 0) try c.trusted(url);
        var duplicate = false;
        for (out.items) |old| if (std.mem.eql(u8, old.path, path)) {
            if (!std.mem.eql(u8, old.url orelse "", url) or !std.meta.eql(old.sha1, hash)) return error.ConflictingArtifact;
            duplicate = true;
            break;
        };
        if (!duplicate) try out.append(a, .{ .coordinate = try a.dupe(u8, library.name), .path = path, .url = try a.dupe(u8, url), .sha1 = hash, .size = size });
    }
}

fn javaFixtureBase(a: std.mem.Allocator, id: []const u8, major: u64) !m.Owned(m.version.Version) {
    const bytes = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"mainClass\":\"vanilla.Main\",\"libraries\":[],\"javaVersion\":{{\"component\":\"fixture\",\"majorVersion\":{d}}},\"downloads\":{{\"client\":{{\"url\":\"https://piston-data.mojang.com/client.jar\"}}}}}}", .{ id, major });
    defer a.free(bytes);
    return m.version.parseSlice(a, bytes);
}
test "Java requirements preserve runtime metadata and existing installer floors for every loader kind" {
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
            var catalogue = try l.parseCatalog(a, kind, "1.20.1", catalogue_bytes);
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
            try std.testing.expectEqual(if (modern_loader) @max(@as(u64, 8), major) else @as(u64, 8), requirements.installer_major);
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
    var catalogue = try l.parseCatalog(a, .forge, "1.7.10", "{\"1.7.10\":[\"1.7.10-10.13.4.1614-1.7.10\"]}");
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
    try std.testing.expectError(error.LegacyForgeVanillaCopyRequired, prepare(a, catalogue.value, selection, base.value, bundle, options));
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
    var catalog = try l.parseCatalog(a, .forge, "1.12.2", "{\"1.12.2\":[\"1.12.2-14.23.5.2859\"]}");
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
    try std.testing.checkAllAllocationFailures(std.testing.allocator, embeddedFixtureAllocationCheck, .{});
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

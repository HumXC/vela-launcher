//! Authentic embedded-member proof only: NOT a full Forge installation.
//! Authentic archive/profile/version bytes and metadata declarations are retained.
//! A test-local Recipe view reduces artifacts to the already-prepared embedded JAR.
//! wrong_source_hash changes only the test expectation after production prepare.
//! Vanilla is a synthetic, SHA1/size-bound fixture. No remote dependencies, MCP,
//! assets/natives, production receipts/registry publication, or JVM are exercised.
//! Undeclared member hashes/lengths are sampled from the extracted source before copy.
//! This relies on truthful callbacks and private-stage ownership; source sampling does
//! not reauthenticate changes to extracted bytes against the pinned archive.
//! Physical copy corruption/truncation must fail in the executor before commit.
//! Parent execution after source freeze:
//! VELA_FORGE_AUDIT_DIR=/tmp/vela-forge-profile-audit.zPv5snot direnv exec . zig test src/forge_authentic_zip_checks.zig -O ReleaseSafe -lc --test-filter 'authentic Forge embedded ZIP'
const std = @import("std");
const l = @import("core/minecraft/loaders.zig");
const c = @import("core/minecraft/loaders_common.zig");
const files = @import("core/minecraft/loaders_files.zig");
const safe = @import("core/safe_archive.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const archive_limit = 16 * 1024 * 1024;
const metadata_limit = 8 * 1024 * 1024;
const synthetic_client = "synthetic vanilla client; not Minecraft";
const environment: c.m.rules.Environment = .{ .os_name = "linux", .arch = "x86_64" };
const extraction_limits: safe.Limits = .{
    .max_archive_bytes = archive_limit,
    .max_file_bytes = archive_limit,
    .max_total_bytes = 64 * 1024 * 1024,
    .max_entries = 8192,
    .max_paths = 16384,
    .max_path_bytes = 4096,
    .max_path_depth = 64,
    .max_total_path_bytes = 1024 * 1024,
    .max_expansion_ratio = 200,
};

const Release = struct {
    base_id: []const u8,
    installer_name: []const u8,
    installer_url: []const u8,
    installer_sha1: []const u8,
    installer_size: usize,
    profile_sha1: []const u8,
    profile_size: usize,
    version_sha1: ?[]const u8 = null,
    version_size: ?usize = null,
    coordinate: []const u8,
    artifact_path: []const u8,
    member: []const u8,
    member_sha1: []const u8,
    member_sha256: []const u8,
    member_size: usize,
    main_class: []const u8 = "net.minecraft.launchwrapper.Launch",
    tweak_class: []const u8,
    catalog_json: []const u8,
};

const modern: Release = .{
    .base_id = "1.12.2",
    .installer_name = "forge-1.12.2-14.23.5.2859-installer.jar",
    .installer_url = "https://maven.minecraftforge.net/net/minecraftforge/forge/1.12.2-14.23.5.2859/forge-1.12.2-14.23.5.2859-installer.jar",
    .installer_sha1 = "6b3d5be8b58d5385fda9c4d285367f4cb6e697b2",
    .installer_size = 4681890,
    .profile_sha1 = "33f57a8bb340c807b7662ae37f7bb9bf8505e9a7",
    .profile_size = 11568,
    .version_sha1 = "c54d0e772bd9e4c0ddcf60071a7b63b946175037",
    .version_size = 12358,
    .coordinate = "net.minecraftforge:forge:1.12.2-14.23.5.2859",
    .artifact_path = "libraries/net/minecraftforge/forge/1.12.2-14.23.5.2859/forge-1.12.2-14.23.5.2859.jar",
    .member = "maven/net/minecraftforge/forge/1.12.2-14.23.5.2859/forge-1.12.2-14.23.5.2859.jar",
    .member_sha1 = "bfc07a510e23e5181b6a32fdcea9c9d9a1445a46",
    .member_sha256 = "bd8314729d787e35164476d75afb337afb9783917e4f6fa1f77f049adba22f2d",
    .member_size = 4466108,
    .tweak_class = "net.minecraftforge.fml.common.launcher.FMLTweaker",
    .catalog_json = "{\"1.12.2\":[\"1.12.2-14.23.5.2859\"]}",
};
const legacy: Release = .{
    .base_id = "1.7.10",
    .installer_name = "forge-1.7.10-10.13.4.1614-1.7.10-installer.jar",
    .installer_url = "https://maven.minecraftforge.net/net/minecraftforge/forge/1.7.10-10.13.4.1614-1.7.10/forge-1.7.10-10.13.4.1614-1.7.10-installer.jar",
    .installer_sha1 = "fccafccf8ad4ce6d9f008e786b48ff53172bf9de",
    .installer_size = 3699647,
    .profile_sha1 = "c137fed2696db8911a035b51875c70a1727ae2ec",
    .profile_size = 5152,
    .coordinate = "net.minecraftforge:forge:1.7.10-10.13.4.1614-1.7.10",
    .artifact_path = "libraries/net/minecraftforge/forge/1.7.10-10.13.4.1614-1.7.10/forge-1.7.10-10.13.4.1614-1.7.10.jar",
    .member = "forge-1.7.10-10.13.4.1614-1.7.10-universal.jar",
    .member_sha1 = "25fd97f72beca728112256938e03e8105b1b78cc",
    .member_sha256 = "00d1ca02192c7efb87da95552ebf247021f1e1d642f86d0a03076314def11529",
    .member_size = 3018833,
    .tweak_class = "cpw.mods.fml.common.launcher.FMLTweaker",
    .catalog_json = "{\"1.7.10\":[\"1.7.10-10.13.4.1614-1.7.10\"]}",
};

fn now(_: ?*anyopaque) u64 {
    return @intCast(@divTrunc(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms));
}
fn control() c.Control {
    return .{ .deadline_ms = now(null) + 30_000, .now_ms = now };
}
fn rootPath(g: std.mem.Allocator, dir: std.Io.Dir) ![]const u8 {
    var buffer: [4096]u8 = undefined;
    const path = try g.dupe(u8, buffer[0..try dir.realPath(io, &buffer)]);
    for (path) |*byte| if (byte.* == '\\') {
        byte.* = '/';
    };
    try c.stageRoot(path);
    return path;
}
fn extract(g: std.mem.Allocator, source: []const u8, destination: []const u8, ctl: c.Control) !void {
    const dir = try files.directory(io, destination, true);
    defer dir.close(io);
    var result = try l.archive.extractInstaller(safe, g, io, source, dir, extraction_limits, ctl);
    defer result.deinit(g);
}
fn verifyBytes(bytes: []const u8, expected_sha1: []const u8, expected_size: usize) !void {
    if (bytes.len != expected_size) return error.SizeMismatch;
    try c.verify(bytes, try c.sha1(expected_sha1));
}
fn verifyMember(bytes: []const u8, release: Release) !void {
    try verifyBytes(bytes, release.member_sha1, release.member_size);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const hex = std.fmt.bytesToHex(&hash, .lower);
    try std.testing.expectEqualStrings(release.member_sha256, &hex);
}
fn deleteFile(path: []const u8) !void {
    const parent = try files.directory(io, std.fs.path.dirname(path) orelse return error.UnsafePath, false);
    defer parent.close(io);
    try parent.deleteFile(io, std.fs.path.basename(path));
}
// files.write is exclusive-create. Mutations replace only an owned private file.
fn mutate(g: std.mem.Allocator, path: []const u8, truncate: bool, ctl: c.Control) !void {
    const bytes = try files.read(g, io, path, archive_limit, ctl);
    defer g.free(bytes);
    if (bytes.len == 0) return error.EmptyMutationTarget;
    const replacement = if (truncate) bytes[0 .. bytes.len - 1] else bytes;
    if (!truncate) replacement[0] ^= 1;
    try deleteFile(path);
    try files.write(io, path, replacement, ctl);
}

const Mode = enum { valid, wrong_source_hash, corrupt_source, missing_member, corrupt_copy, truncate_copy, final_reread_mutation };
const Fixture = struct {
    g: std.mem.Allocator,
    release: Release,
    snapshot: []const u8,
    profile: []const u8,
    version: ?[]const u8,
    members: []const l.recipes.Member,
    stage: []const u8,
    installer: []const u8,
    extracted: []const u8,
    from: []const u8,
    destination: []const u8,
    base_source: []const u8,
    processor_client: []const u8,
    final_client: []const u8,
    expected_source_hash: c.m.Sha1,
    mode: Mode,
    ctl: c.Control,
    begins: usize = 0,
    vanilla_calls: usize = 0,
    downloads: usize = 0,
    extracts: usize = 0,
    metadata_copies: usize = 0,
    artifact_attempts: usize = 0,
    artifact_copies: usize = 0,
    artifact_reads: usize = 0,
    source_reads: usize = 0,
    commit_calls: usize = 0,
    commits: usize = 0,
    rollbacks: usize = 0,
    forbidden_calls: usize = 0,
    rollback_failed: bool = false,

    fn self(raw: ?*anyopaque) *Fixture {
        return @ptrCast(@alignCast(raw.?));
    }
    fn callbacks(f: *Fixture) l.execution.Callbacks {
        return .{ .context = f, .begin = begin, .vanilla = vanilla, .download = download, .extract_installer = extractInstaller, .copy = copy, .read = read, .main_class = mainClass, .process = process, .commit = commit, .rollback = rollback };
    }
    fn begin(raw: ?*anyopaque, stage: []const u8, ctl: c.Control) !void {
        const f = self(raw);
        try ctl.check();
        try std.testing.expectEqualStrings(f.stage, stage);
        f.begins += 1;
        const dir = try files.directory(io, stage, true);
        dir.close(io);
    }
    fn vanilla(raw: ?*anyopaque, recipe: l.recipes.Recipe, ctl: c.Control) !void {
        const f = self(raw);
        f.vanilla_calls += 1;
        try std.testing.expectEqualStrings(f.release.base_id, recipe.version.jar.?);
        const hash = l.recipes.digest(synthetic_client);
        try files.verify(io, f.base_source, hash, synthetic_client.len, archive_limit, ctl);
        try files.copy(io, f.base_source, f.processor_client, archive_limit, ctl);
        try files.copy(io, f.base_source, f.final_client, archive_limit, ctl);
        try files.verify(io, f.processor_client, hash, synthetic_client.len, archive_limit, ctl);
        try files.verify(io, f.final_client, hash, synthetic_client.len, archive_limit, ctl);
    }
    fn download(raw: ?*anyopaque, url: []const u8, destination: []const u8, expected: ?c.m.Sha1, ctl: c.Control) !void {
        const f = self(raw);
        if (!std.mem.eql(u8, url, f.release.installer_url)) {
            f.forbidden_calls += 1;
            return error.UnexpectedRemoteDependency;
        }
        try std.testing.expectEqualStrings(f.installer, destination);
        try std.testing.expectEqual(f.expected_source_hash, expected.?);
        f.downloads += 1;
        try files.write(io, destination, f.snapshot, ctl);
        if (f.mode == .corrupt_source) try mutate(f.g, destination, false, ctl);
    }
    fn extractInstaller(raw: ?*anyopaque, source: []const u8, destination: []const u8, ctl: c.Control) !void {
        const f = self(raw);
        try std.testing.expectEqualStrings(f.installer, source);
        try std.testing.expectEqualStrings(f.extracted, destination);
        f.extracts += 1;
        try extract(f.g, source, destination, ctl);
        // The ZIP is real and unchanged; remove a physical extracted file only.
        if (f.mode == .missing_member) try deleteFile(f.from);
    }
    fn copy(raw: ?*anyopaque, source: []const u8, destination: []const u8, ctl: c.Control) !void {
        const f = self(raw);
        if (std.mem.eql(u8, source, f.from)) {
            try std.testing.expectEqualStrings(f.destination, destination);
            f.artifact_attempts += 1;
            try files.copy(io, source, destination, archive_limit, ctl);
            f.artifact_copies += 1;
            if (f.mode == .corrupt_copy) try mutate(f.g, destination, false, ctl);
            if (f.mode == .truncate_copy) try mutate(f.g, destination, true, ctl);
            return;
        }
        for (f.members) |member| {
            const from = try c.join(f.g, f.extracted, member.source);
            const to = try c.join(f.g, f.stage, member.destination);
            if (!std.mem.eql(u8, source, from)) continue;
            try std.testing.expectEqualStrings(to, destination);
            try files.copy(io, source, destination, archive_limit, ctl);
            f.metadata_copies += 1;
            return;
        }
        return error.UnexpectedCopyPath;
    }
    fn read(raw: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8, max: usize, ctl: c.Control) ![]u8 {
        const f = self(raw);
        if (std.mem.eql(u8, path, f.from)) {
            f.source_reads += 1;
            try std.testing.expect(f.release.version_sha1 == null);
            try std.testing.expectEqual(@as(usize, 1), f.extracts);
            try std.testing.expectEqual(@as(usize, 0), f.artifact_attempts);
        }
        const bytes = try files.read(allocator, io, path, @min(max, archive_limit), ctl);
        errdefer allocator.free(bytes);
        if (std.mem.eql(u8, path, f.destination)) {
            f.artifact_reads += 1;
            // Mutate after the first destination verify sampled its unchanged bytes.
            if (f.mode == .final_reread_mutation and f.artifact_reads == 1) try mutate(f.g, path, false, ctl);
        }
        // Never synthesize an archive member or verification read payload.
        return bytes;
    }
    fn mainClass(raw: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: c.Control) ![]u8 {
        self(raw).forbidden_calls += 1;
        return error.UnexpectedProcessor;
    }
    fn process(raw: ?*anyopaque, _: l.execution.Invocation) !l.execution.ProcessResult {
        self(raw).forbidden_calls += 1;
        return error.UnexpectedProcessor;
    }
    fn commit(raw: ?*anyopaque, recipe: l.recipes.Recipe) !void {
        const f = self(raw);
        f.commit_calls += 1;
        try std.testing.expectEqual(@as(usize, 1), recipe.artifacts.len);
        const artifact = try files.read(f.g, io, f.destination, archive_limit, f.ctl);
        defer f.g.free(artifact);
        // Independent fixed audit proof, not a production receipt or publication.
        // Copy corruption/truncation must already have failed before this callback.
        try verifyMember(artifact, f.release);
        const hash = l.recipes.digest(synthetic_client);
        try files.verify(io, f.processor_client, hash, synthetic_client.len, archive_limit, f.ctl);
        try files.verify(io, f.final_client, hash, synthetic_client.len, archive_limit, f.ctl);
        for (f.members) |member| {
            const bytes = try files.read(f.g, io, try c.join(f.g, f.stage, member.destination), metadata_limit, f.ctl);
            defer f.g.free(bytes);
            const expected = if (std.mem.eql(u8, member.source, "install_profile.json")) f.profile else f.version orelse return error.UnexpectedMetadataMember;
            try std.testing.expectEqualSlices(u8, expected, bytes);
        }
        f.commits += 1;
    }
    fn rollback(raw: ?*anyopaque, stage: []const u8) void {
        const f = self(raw);
        f.rollbacks += 1;
        if (!std.mem.eql(u8, f.stage, stage)) {
            f.rollback_failed = true;
            return;
        }
        const parent = files.directory(io, std.fs.path.dirname(stage) orelse {
            f.rollback_failed = true;
            return;
        }, false) catch {
            f.rollback_failed = true;
            return;
        };
        defer parent.close(io);
        parent.deleteTree(io, std.fs.path.basename(stage)) catch {
            f.rollback_failed = true;
        };
    }
};

fn exercise(release: Release, snapshot: []const u8, profile: []const u8, version: ?[]const u8, full: l.recipes.Recipe, artifact: l.recipes.Artifact, mode: Mode) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const g = arena.allocator();
    const root = try rootPath(g, tmp.dir);
    const stage = try c.join(g, root, "stage");
    const ctl = control();
    const base_source = try c.join(g, root, "synthetic-base/client.jar");
    try files.write(io, base_source, synthetic_client, ctl);
    // Test-local artifact projection. Do not rewrite any authentic declaration.
    const selected = [_]l.recipes.Artifact{artifact};
    var focused = full;
    focused.stage_root = stage;
    focused.artifacts = &selected;
    if (mode == .wrong_source_hash) focused.installer_sha1 = l.recipes.digest("wrong expected installer SHA1");
    var fixture: Fixture = .{
        .g = g,
        .release = release,
        .snapshot = snapshot,
        .profile = profile,
        .version = version,
        .members = full.members,
        .stage = stage,
        .installer = try c.join(g, stage, ".loader/installer.jar"),
        .extracted = try c.join(g, stage, ".loader/archive"),
        .from = try c.join(g, stage, try std.fmt.allocPrint(g, ".loader/archive/{s}", .{artifact.member.?})),
        .destination = try c.join(g, stage, artifact.path),
        .base_source = base_source,
        .processor_client = try c.join(g, stage, try std.fmt.allocPrint(g, "versions/{s}/{s}.jar", .{ release.base_id, release.base_id })),
        .final_client = try c.join(g, stage, "AuthenticEmbeddedProof.jar"),
        .expected_source_hash = focused.installer_sha1.?,
        .mode = mode,
        .ctl = ctl,
    };
    const outcome = l.execute(a, focused, fixture.callbacks(), .{ .max_file_bytes = archive_limit }, ctl);
    const expected_error: ?anyerror = switch (mode) {
        .valid => null,
        .wrong_source_hash, .corrupt_source, .corrupt_copy, .final_reread_mutation => error.ChecksumMismatch,
        .missing_member => error.FileNotFound,
        .truncate_copy => error.SizeMismatch,
    };
    if (expected_error) |failure| {
        try std.testing.expectError(failure, outcome);
    } else try outcome;
    try std.testing.expectEqual(@as(usize, 1), fixture.begins);
    try std.testing.expectEqual(@as(usize, 1), fixture.vanilla_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.downloads);
    try std.testing.expectEqual(@as(usize, 0), fixture.forbidden_calls);
    const rejected_source = mode == .wrong_source_hash or mode == .corrupt_source;
    const missing = mode == .missing_member;
    const source_bound = release.version_sha1 == null;
    const expected_reads: usize = if (rejected_source or missing) 0 else if (mode == .corrupt_copy or mode == .truncate_copy) 1 else 2;
    try std.testing.expectEqual(@as(usize, if (rejected_source) 0 else 1), fixture.extracts);
    try std.testing.expectEqual(@as(usize, if (rejected_source) 0 else full.members.len), fixture.metadata_copies);
    try std.testing.expectEqual(@as(usize, if (rejected_source or (missing and source_bound)) 0 else 1), fixture.artifact_attempts);
    try std.testing.expectEqual(@as(usize, if (!rejected_source and source_bound) 1 else 0), fixture.source_reads);
    try std.testing.expectEqual(@as(usize, if (rejected_source or missing) 0 else 1), fixture.artifact_copies);
    try std.testing.expectEqual(expected_reads, fixture.artifact_reads);
    try std.testing.expectEqual(@as(usize, if (mode == .valid) 1 else 0), fixture.commit_calls);
    try std.testing.expectEqual(@as(usize, if (mode == .valid) 1 else 0), fixture.commits);
    try std.testing.expectEqual(@as(usize, if (mode == .valid) 0 else 1), fixture.rollbacks);
    try std.testing.expect(!fixture.rollback_failed);
    if (mode != .valid) {
        const surviving = files.directory(io, stage, false);
        if (surviving) |dir| {
            dir.close(io);
            return error.StageSurvivedRollback;
        } else |err| try std.testing.expect(err == error.FileNotFound);
    }
    // Rollback must not remove the separate fixture base or alter its bytes.
    try files.verify(io, base_source, l.recipes.digest(synthetic_client), synthetic_client.len, archive_limit, ctl);
}

fn runRelease(release: Release) !void {
    const audit_dir = std.mem.span(std.c.getenv("VELA_FORGE_AUDIT_DIR") orelse return error.MissingAuthenticArchiveEnvironment);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const g = arena.allocator();
    const root = try rootPath(g, tmp.dir);
    const ctl = control();
    // Trust comes from the pinned previously authenticated official sidecar,
    // never from computing an expected installer hash from the supplied bytes.
    const snapshot = try files.read(g, io, try c.join(g, audit_dir, release.installer_name), archive_limit, ctl);
    try verifyBytes(snapshot, release.installer_sha1, release.installer_size);
    const source = try c.join(g, root, ".prepare/installer.jar");
    try files.write(io, source, snapshot, ctl);
    const extracted = try c.join(g, root, ".prepare/archive");
    try extract(g, source, extracted, ctl);
    const profile = try files.read(g, io, try c.join(g, extracted, "install_profile.json"), metadata_limit, ctl);
    try verifyBytes(profile, release.profile_sha1, release.profile_size);
    const version: ?[]const u8 = if (release.version_sha1) |hash| blk: {
        const bytes = try files.read(g, io, try c.join(g, extracted, "version.json"), metadata_limit, ctl);
        try verifyBytes(bytes, hash, release.version_size.?);
        break :blk bytes;
    } else null;
    const member = try files.read(g, io, try c.join(g, extracted, release.member), archive_limit, ctl);
    try verifyMember(member, release);
    // Exact-release catalog factory is approved fixture data, not a catalog fetch.
    var catalog = try l.parseCatalog(a, .forge, release.base_id, release.catalog_json);
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 1), catalog.value.entries.len);
    try std.testing.expectEqualStrings(release.installer_url, catalog.value.entries[0].url);
    const hash = std.fmt.bytesToHex(&l.recipes.digest(synthetic_client), .lower);
    const base_json = try std.json.Stringify.valueAlloc(g, .{
        .id = release.base_id,
        .mainClass = "synthetic.Vanilla",
        .libraries = .{},
        .downloads = .{ .client = .{ .url = "https://piston-data.mojang.com/synthetic-client.jar", .sha1 = hash, .size = synthetic_client.len } },
    }, .{});
    var base = try c.m.version.parseSlice(a, base_json);
    defer base.deinit();
    var prepared = try l.prepare(a, catalog.value, .{ .kind = .forge, .base_id = release.base_id, .loader_id = catalog.value.entries[0].id }, base.value, .{
        .source_url = release.installer_url,
        .profile = profile,
        .version_json = version,
        .installer_sha1 = try c.sha1(release.installer_sha1),
    }, .{ .instance_name = "AuthenticEmbeddedProof", .stage_root = try c.join(g, root, "unused-prepared-stage"), .environment = environment });
    defer prepared.deinit();
    const full = prepared.value;
    try std.testing.expectEqual(@as(usize, 0), full.processors.len);
    try std.testing.expect(full.artifacts.len > 1); // Full remote recipe is preserved.
    try std.testing.expectEqual(@as(usize, if (version != null) 2 else 1), full.members.len);
    try std.testing.expectEqualStrings(release.base_id, full.version.jar.?);
    var inherited_client = false;
    for (full.version.downloads) |entry| {
        if (!std.mem.eql(u8, entry.name, "client")) continue;
        try std.testing.expect(!inherited_client);
        try std.testing.expectEqual(l.recipes.digest(synthetic_client), entry.download.sha1.?);
        try std.testing.expectEqual(@as(u64, synthetic_client.len), entry.download.size.?);
        inherited_client = true;
    }
    try std.testing.expect(inherited_client);
    try std.testing.expectEqualStrings(release.main_class, full.version.main_class.?);
    try std.testing.expect(std.mem.indexOf(u8, full.version.minecraft_arguments.?, release.tweak_class) != null);
    var found: ?l.recipes.Artifact = null;
    for (full.artifacts) |artifact| {
        if (!std.mem.eql(u8, artifact.coordinate, release.coordinate)) continue;
        try std.testing.expect(found == null);
        found = artifact;
    }
    const artifact = found orelse return error.MissingAuthenticEmbeddedArtifact;
    try std.testing.expectEqualStrings(release.artifact_path, artifact.path);
    try std.testing.expectEqualStrings(release.member, artifact.member.?);
    const coordinate = try c.m.version.mavenCoordinate(artifact.coordinate);
    const canonical = try coordinate.path(g, null);
    try std.testing.expectEqualStrings(artifact.path, try std.fmt.allocPrint(g, "libraries/{s}", .{canonical}));
    if (version != null) {
        try std.testing.expectEqualStrings("", artifact.url.?);
        try std.testing.expectEqual(try c.sha1(release.member_sha1), artifact.sha1.?);
        try std.testing.expectEqual(@as(u64, release.member_size), artifact.size.?);
        try std.testing.expectEqualStrings(artifact.member.?, try std.fmt.allocPrint(g, "maven/{s}", .{canonical}));
    } else {
        try std.testing.expect(artifact.url == null);
        // Do not invent a legacy library SHA1/size declaration. Its independent
        // authenticated archive-member audit is enforced in the proof callback.
        try std.testing.expect(artifact.sha1 == null);
        try std.testing.expect(artifact.size == null);
    }
    for ([_]Mode{ .valid, .wrong_source_hash, .corrupt_source, .missing_member, .corrupt_copy, .truncate_copy, .final_reread_mutation }) |mode| {
        try exercise(release, snapshot, profile, version, full, artifact, mode);
    }
}

test "authentic Forge embedded ZIP member proof only - 1.12.2 physical failures" {
    try runRelease(modern);
}

test "authentic Forge embedded ZIP member proof only - 1.7.10 universal and audit boundary" {
    try runRelease(legacy);
}

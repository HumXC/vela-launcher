//! Synchronous transaction orchestration. Real I/O/process adapters are supplied
//! by the installer owner; pure planning and validation are implemented here.
const std = @import("std");
const c = @import("loaders_common.zig");
const r = @import("loaders_recipe.zig");
const p = @import("loaders_processors.zig");
pub const ProcessResult = union(enum) { exited: u8, signaled: u32, canceled, deadline, output_limit };
pub const Invocation = struct {
    java: []const u8,
    main_class: []const u8,
    classpath: []const []const u8,
    args: []const []const u8,
    working_directory: []const u8,
    max_output_bytes: usize = 4 * 1024 * 1024,
    control: c.Control,
};
/// All callback arguments are borrowed for the call only. Calls are synchronous:
/// return only after downloads/children stop and handles are closed/reaped. Spawn
/// java directly with -cp, Main-Class and each args element separately; no shell.
/// Process adapter enforces deadline/cancel, bounded logs and termination/reaping.
/// Filesystem adapters must reject symlink parents and non-regular reads/writes.
/// begin creates an empty private stage; vanilla fills that stage from resolved
/// base WITHOUT writing installed root. commit atomically publishes artifacts,
/// metadata and instance registry together. Error means no visible publication.
/// rollback removes only caller's private stage, not immutable verified caches.
pub const Callbacks = struct {
    context: ?*anyopaque = null,
    begin: *const fn (?*anyopaque, []const u8, c.Control) anyerror!void,
    vanilla: *const fn (?*anyopaque, r.Recipe, c.Control) anyerror!void,
    download: *const fn (?*anyopaque, []const u8, []const u8, ?c.m.Sha1, c.Control) anyerror!void,
    /// Must use shared safe_archive.extract into an empty private directory.
    extract_installer: *const fn (?*anyopaque, []const u8, []const u8, c.Control) anyerror!void,
    copy: *const fn (?*anyopaque, []const u8, []const u8, c.Control) anyerror!void,
    /// Return allocator-owned bytes, bounded while reading, regular files only.
    read: *const fn (?*anyopaque, std.mem.Allocator, []const u8, usize, c.Control) anyerror![]u8,
    /// Read Main-Class from the previously hash-verified JAR manifest using safe
    /// ZIP parsing; return allocator-owned class name, maximum 512 bytes.
    main_class: *const fn (?*anyopaque, std.mem.Allocator, []const u8, c.Control) anyerror![]u8,
    process: *const fn (?*anyopaque, Invocation) anyerror!ProcessResult,
    commit: *const fn (?*anyopaque, r.Recipe) anyerror!void,
    rollback: *const fn (?*anyopaque, []const u8) void,
};
pub const Options = struct { java: ?[]const u8 = null, java_major: ?u64 = null, max_file_bytes: usize = 512 * 1024 * 1024 };
pub fn execute(a: std.mem.Allocator, recipe: r.Recipe, callbacks: Callbacks, options: Options, control: c.Control) !void {
    try control.check();
    if (options.max_file_bytes == 0 or options.max_file_bytes > 1024 * 1024 * 1024) return error.InvalidFileLimit;
    if (recipe.processors.len != 0) {
        if (options.java == null or options.java.?.len == 0 or options.java_major == null) return error.MissingJava;
        if (options.java_major.? < recipe.installer_java_major) return error.JavaTooOld;
    }
    const ar = try c.arena(a);
    defer {
        ar.deinit();
        a.destroy(ar);
    }
    const g = ar.allocator();
    const Receipt = struct { path: []const u8, sha1: c.m.Sha1, size: ?u64 };
    var receipts: std.ArrayList(Receipt) = .empty;
    const ctx = callbacks.context;
    // Even a partially failed begin is rolled back under the same stage owner.
    var committed = false;
    defer if (!committed) callbacks.rollback(ctx, recipe.stage_root);
    try callbacks.begin(ctx, recipe.stage_root, control);
    try control.check();
    try callbacks.vanilla(ctx, recipe, control);
    try control.check();
    const source = try c.join(g, recipe.stage_root, if (recipe.installer_sha1 != null) ".loader/installer.jar" else ".loader/profile.json");
    const source_hash = recipe.installer_sha1 orelse recipe.source_sha1;
    try callbacks.download(ctx, recipe.source_url, source, source_hash, control);
    try verified(a, callbacks, source, source_hash, null, options.max_file_bytes, control);
    if (recipe.installer_sha1 != null) {
        const extracted = try c.join(g, recipe.stage_root, ".loader/archive");
        try callbacks.extract_installer(ctx, source, extracted, control);
        for (recipe.members) |member| {
            try control.check();
            const from = try c.join(g, extracted, member.source);
            const to = try c.join(g, recipe.stage_root, member.destination);
            if (member.sha1) |hash| try verified(a, callbacks, from, hash, null, options.max_file_bytes, control);
            try callbacks.copy(ctx, from, to, control);
            if (member.sha1) |hash| try verified(a, callbacks, to, hash, null, options.max_file_bytes, control);
        }
    }
    for (recipe.artifacts) |artifact| {
        try control.check();
        const destination = try c.join(g, recipe.stage_root, artifact.path);
        if (artifact.member) |member| {
            const path = try std.fmt.allocPrint(g, ".loader/archive/{s}", .{member});
            const member_source = try c.join(g, recipe.stage_root, path);
            var size = artifact.size;
            const hash = artifact.sha1 orelse blk: {
                // Bind the copy to the sampled private-stage source, not the destination.
                // This relies on truthful callbacks; it does not reauthenticate extraction.
                const bytes = try callbacks.read(ctx, a, member_source, options.max_file_bytes, control);
                defer a.free(bytes);
                if (bytes.len > options.max_file_bytes) return error.FileTooLarge;
                size = artifact.size orelse @as(u64, bytes.len);
                break :blk r.digest(bytes);
            };
            try callbacks.copy(ctx, member_source, destination, control);
            try verified(a, callbacks, destination, hash, size, options.max_file_bytes, control);
            try receipts.append(g, .{ .path = destination, .sha1 = hash, .size = size });
        } else if (artifact.url) |url| {
            if (url.len == 0) {
                if (!produced(recipe, destination)) return error.MissingGeneratedLibrary;
                continue;
            }
            try c.trusted(url);
            const hash = if (artifact.sha1) |hash| hash else blk: {
                const sidecar_url = try std.fmt.allocPrint(g, "{s}.sha1", .{url});
                const sidecar = try std.fmt.allocPrint(g, "{s}.sha1", .{destination});
                try callbacks.download(ctx, sidecar_url, sidecar, null, control);
                const bytes = try callbacks.read(ctx, a, sidecar, 256, control);
                defer a.free(bytes);
                if (bytes.len > 256) return error.MetadataTooLarge;
                const trimmed = std.mem.trim(u8, bytes, " \r\n\t");
                break :blk try c.sha1(trimmed);
            };
            try callbacks.download(ctx, url, destination, hash, control);
            try verified(a, callbacks, destination, hash, artifact.size, options.max_file_bytes, control);
            try receipts.append(g, .{ .path = destination, .sha1 = hash, .size = artifact.size });
        } else return error.MissingArtifactSource;
    }
    for (recipe.processors) |processor| {
        try control.check();
        const main = try callbacks.main_class(ctx, a, processor.jar, control);
        defer a.free(main);
        try trustedClass(main);
        const result = try callbacks.process(ctx, .{ .java = options.java.?, .main_class = main, .classpath = processor.classpath, .args = processor.args, .working_directory = recipe.stage_root, .control = control });
        switch (result) {
            .exited => |code| if (code != 0) return error.ProcessorFailed,
            .signaled => return error.ProcessorSignaled,
            .canceled => return error.Canceled,
            .deadline => return error.DeadlineExceeded,
            .output_limit => return error.ProcessorOutputLimit,
        }
        try control.check();
        for (processor.outputs) |output| {
            try p.underRoot(recipe.stage_root, output.path);
            try verified(a, callbacks, output.path, output.sha1, null, options.max_file_bytes, control);
        }
    }
    // Final revalidation detects later processors changing an earlier output.
    for (recipe.processors) |processor| for (processor.outputs) |output| try verified(a, callbacks, output.path, output.sha1, null, options.max_file_bytes, control);
    // Keep sidecar-derived receipts too: processors may have changed downloaded inputs.
    for (receipts.items) |receipt| try verified(a, callbacks, receipt.path, receipt.sha1, receipt.size, options.max_file_bytes, control);
    // Generated runtime libraries also obey their version.json digest and size.
    for (recipe.artifacts) |artifact| {
        if (artifact.member != null or artifact.url == null or artifact.url.?.len != 0) continue;
        const path = try c.join(g, recipe.stage_root, artifact.path);
        for (recipe.processors) |processor| for (processor.outputs) |output| {
            if (std.mem.eql(u8, path, output.path)) try verified(a, callbacks, path, artifact.sha1 orelse output.sha1, artifact.size, options.max_file_bytes, control);
        };
    }
    try control.check();
    // Linearization point: late cancellation never undoes a successful commit.
    try callbacks.commit(ctx, recipe);
    committed = true;
}
fn verified(a: std.mem.Allocator, cb: Callbacks, path: []const u8, hash: c.m.Sha1, size: ?u64, max: usize, control: c.Control) !void {
    try control.check();
    const bytes = try cb.read(cb.context, a, path, max, control);
    defer a.free(bytes);
    if (bytes.len > max) return error.FileTooLarge;
    if (size) |expected| if (bytes.len != expected) return error.SizeMismatch;
    try c.verify(bytes, hash);
    try control.check();
}
fn produced(recipe: r.Recipe, path: []const u8) bool {
    for (recipe.processors) |processor| for (processor.outputs) |output| if (std.mem.eql(u8, output.path, path)) return true;
    return false;
}
pub fn trustedClass(main: []const u8) !void {
    if (main.len == 0 or main.len > 512) return error.UntrustedProcessorClass;
    if (!std.mem.startsWith(u8, main, "net.minecraftforge.") and !std.mem.startsWith(u8, main, "net.neoforged.")) return error.UntrustedProcessorClass;
    for (main) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '_' and ch != '$') return error.UntrustedProcessorClass;
}

const EmbeddedExecutionFixture = struct {
    const coordinate = "net.minecraftforge:forge:1.12.2-14.23.5.2859";
    const library_path = "net/minecraftforge/forge/1.12.2-14.23.5.2859/forge-1.12.2-14.23.5.2859.jar";
    const destination = "/fixture-stage/libraries/" ++ library_path;
    const archive_member = "/fixture-stage/.loader/archive/maven/" ++ library_path;
    const tool_path = "/fixture-stage/libraries/net/minecraftforge/installertools/1/installertools-1.jar";
    const Mode = enum { valid, missing_member, wrong_bytes, wrong_artifact, late_tamper, generated, bad_generated };

    mode: Mode = .valid,
    installer_downloads: usize = 0,
    tool_downloads: usize = 0,
    extracts: usize = 0,
    copies: usize = 0,
    metadata_copies: usize = 0,
    profile_bytes: []const u8 = "",
    version_bytes: []const u8 = "",
    profile_copied: bool = false,
    version_copied: bool = false,
    reads: usize = 0,
    processes: usize = 0,
    commits: usize = 0,
    rollbacks: usize = 0,
    copied: bool = false,
    generated: bool = false,

    fn prepare(a: std.mem.Allocator, root_path: ?[]const u8, size: u64, generated: bool, fixture: *EmbeddedExecutionFixture) !c.m.Owned(r.Recipe) {
        const loaders = @import("loaders.zig");
        var base = try c.m.version.parseSlice(a, "{\"id\":\"1.12.2\",\"mainClass\":\"vanilla.Main\",\"libraries\":[],\"downloads\":{\"client\":{\"url\":\"https://piston-data.mojang.com/client.jar\"}}}");
        defer base.deinit();
        var catalog = try loaders.parseCatalog(a, .forge, "1.12.2", "{\"1.12.2\":[\"1.12.2-14.23.5.2859\"]}");
        defer catalog.deinit();
        const library = try std.fmt.allocPrint(a, "{{\"name\":\"{s}\",\"downloads\":{{\"artifact\":{{\"path\":\"{s}\",\"url\":\"\",\"sha1\":\"a9993e364706816aba3e25717850c26c9cd0d89d\",\"size\":{d}}}}}}}", .{ coordinate, library_path, size });
        defer a.free(library);
        const path_field = if (root_path) |path| try std.fmt.allocPrint(a, "\"path\":\"{s}\",", .{path}) else "";
        defer if (root_path != null) a.free(path_field);
        const tool = if (generated) ",{\"name\":\"net.minecraftforge:installertools:1\",\"downloads\":{\"artifact\":{\"path\":\"net/minecraftforge/installertools/1/installertools-1.jar\",\"url\":\"https://maven.minecraftforge.net/net/minecraftforge/installertools/1/installertools-1.jar\",\"sha1\":\"a9993e364706816aba3e25717850c26c9cd0d89d\",\"size\":3}}}" else "";
        const processors = if (generated) "[{\"jar\":\"net.minecraftforge:installertools:1\",\"classpath\":[],\"args\":[],\"outputs\":{\"[net.minecraftforge:forge:1.12.2-14.23.5.2859]\":\"a9993e364706816aba3e25717850c26c9cd0d89d\"}}]" else "[]";
        const profile = try std.fmt.allocPrint(a, "{{\"spec\":0,\"minecraft\":\"1.12.2\",\"json\":\"/version.json\",{s}\"libraries\":[{s}{s}],\"data\":{{}},\"processors\":{s}}}", .{ path_field, library, tool, processors });
        defer a.free(profile);
        const version = try std.fmt.allocPrint(a, "{{\"id\":\"1.12.2-forge-14.23.5.2859\",\"inheritsFrom\":\"1.12.2\",\"mainClass\":\"net.minecraft.launchwrapper.Launch\",\"libraries\":[{s}]}}", .{library});
        defer a.free(version);
        var recipe = try r.prepare(a, catalog.value, .{ .kind = .forge, .base_id = "1.12.2", .loader_id = catalog.value.entries[0].id }, base.value, .{
            .source_url = catalog.value.entries[0].url,
            .profile = profile,
            .version_json = version,
            .installer_sha1 = r.digest("fixture installer"),
        }, .{ .instance_name = "EmbeddedExecution", .stage_root = "/fixture-stage", .environment = .{ .os_name = "linux", .arch = "x86_64" } });
        errdefer recipe.deinit();
        const g = recipe.arena.allocator();
        fixture.profile_bytes = try g.dupe(u8, profile);
        fixture.version_bytes = try g.dupe(u8, version);
        return recipe;
    }

    fn self(ctx: ?*anyopaque) *EmbeddedExecutionFixture {
        return @ptrCast(@alignCast(ctx.?));
    }
    fn begin(_: ?*anyopaque, _: []const u8, control: c.Control) !void {
        try control.check();
    }
    fn vanilla(_: ?*anyopaque, _: r.Recipe, control: c.Control) !void {
        try control.check();
    }
    fn download(ctx: ?*anyopaque, _: []const u8, path: []const u8, _: ?c.m.Sha1, control: c.Control) !void {
        try control.check();
        const fixture = self(ctx);
        if (std.mem.eql(u8, path, "/fixture-stage/.loader/installer.jar")) {
            fixture.installer_downloads += 1;
        } else if (std.mem.eql(u8, path, tool_path)) {
            fixture.tool_downloads += 1;
        } else return error.UnexpectedArtifactDownload;
    }
    fn extract(ctx: ?*anyopaque, _: []const u8, _: []const u8, control: c.Control) !void {
        try control.check();
        self(ctx).extracts += 1;
    }
    fn copy(ctx: ?*anyopaque, from: []const u8, to: []const u8, control: c.Control) !void {
        try control.check();
        const fixture = self(ctx);
        try std.testing.expectEqual(@as(usize, 1), fixture.extracts);
        if (std.mem.eql(u8, from, "/fixture-stage/.loader/archive/install_profile.json")) {
            try std.testing.expectEqualStrings("/fixture-stage/.loader/profile.json", to);
            fixture.profile_copied = true;
            fixture.metadata_copies += 1;
            return;
        }
        if (std.mem.eql(u8, from, "/fixture-stage/.loader/archive/version.json")) {
            try std.testing.expectEqualStrings("/fixture-stage/.loader/version.json", to);
            fixture.version_copied = true;
            fixture.metadata_copies += 1;
            return;
        }
        try std.testing.expectEqualStrings(archive_member, from);
        try std.testing.expectEqualStrings(destination, to);
        if (fixture.mode == .missing_member) return error.FileNotFound;
        fixture.copies += 1;
        fixture.copied = true;
    }
    fn read(ctx: ?*anyopaque, a: std.mem.Allocator, path: []const u8, _: usize, control: c.Control) ![]u8 {
        try control.check();
        const fixture = self(ctx);
        if (std.mem.eql(u8, path, "/fixture-stage/.loader/installer.jar") and fixture.installer_downloads == 1) return a.dupe(u8, "fixture installer");
        if (fixture.extracts == 1) {
            if (std.mem.eql(u8, path, "/fixture-stage/.loader/archive/install_profile.json")) return a.dupe(u8, if (fixture.mode == .wrong_bytes) "corrupt profile" else fixture.profile_bytes);
            if (std.mem.eql(u8, path, "/fixture-stage/.loader/archive/version.json")) return a.dupe(u8, fixture.version_bytes);
            if (std.mem.eql(u8, path, archive_member)) {
                if (fixture.mode == .missing_member) return error.FileNotFound;
                return a.dupe(u8, if (fixture.mode == .wrong_artifact) "abd" else "abc");
            }
        }
        if (std.mem.eql(u8, path, "/fixture-stage/.loader/profile.json") and fixture.profile_copied) return a.dupe(u8, fixture.profile_bytes);
        if (std.mem.eql(u8, path, "/fixture-stage/.loader/version.json") and fixture.version_copied) return a.dupe(u8, fixture.version_bytes);
        if (std.mem.eql(u8, path, tool_path) and fixture.tool_downloads == 1) return a.dupe(u8, "abc");
        if (!std.mem.eql(u8, path, destination) or (!fixture.copied and !fixture.generated)) return error.FileNotFound;
        fixture.reads += 1;
        const changed = fixture.mode == .wrong_artifact or fixture.mode == .bad_generated or (fixture.mode == .late_tamper and fixture.reads > 1);
        return a.dupe(u8, if (changed) "abd" else "abc");
    }
    fn mainClass(_: ?*anyopaque, a: std.mem.Allocator, _: []const u8, control: c.Control) ![]u8 {
        try control.check();
        return a.dupe(u8, "net.minecraftforge.installertools.ConsoleTool");
    }
    fn process(ctx: ?*anyopaque, invocation: Invocation) !ProcessResult {
        try invocation.control.check();
        const fixture = self(ctx);
        fixture.processes += 1;
        fixture.generated = true;
        return .{ .exited = 0 };
    }
    fn commit(ctx: ?*anyopaque, _: r.Recipe) !void {
        self(ctx).commits += 1;
    }
    fn rollback(ctx: ?*anyopaque, _: []const u8) void {
        self(ctx).rollbacks += 1;
    }
    const test_control: c.Control = .{ .deadline_ms = 1, .now_ms = frozenNow };
    fn frozenNow(_: ?*anyopaque) u64 {
        return 0;
    }
    fn callbacks(fixture: *EmbeddedExecutionFixture) Callbacks {
        return .{ .context = fixture, .begin = begin, .vanilla = vanilla, .download = download, .extract_installer = extract, .copy = copy, .read = read, .main_class = mainClass, .process = process, .commit = commit, .rollback = rollback };
    }
};

test "modern zero processor Maven member copies and verifies before commit" {
    var fixture: EmbeddedExecutionFixture = .{};
    var recipe = try EmbeddedExecutionFixture.prepare(std.testing.allocator, EmbeddedExecutionFixture.coordinate, 3, false, &fixture);
    defer recipe.deinit();
    try execute(std.testing.allocator, recipe.value, fixture.callbacks(), .{}, EmbeddedExecutionFixture.test_control);
    try std.testing.expectEqual(@as(usize, 1), fixture.installer_downloads);
    try std.testing.expectEqual(@as(usize, 1), fixture.extracts);
    try std.testing.expectEqual(@as(usize, 1), fixture.copies);
    try std.testing.expectEqual(@as(usize, 2), fixture.metadata_copies);
    try std.testing.expectEqual(@as(usize, 2), fixture.reads);
    try std.testing.expectEqual(@as(usize, 0), fixture.tool_downloads);
    try std.testing.expectEqual(@as(usize, 0), fixture.processes);
    try std.testing.expectEqual(@as(usize, 1), fixture.commits);
    try std.testing.expectEqual(@as(usize, 0), fixture.rollbacks);
}

test "missing mismatched and late changed embedded Maven members roll back without fallback" {
    const cases = [_]struct { mode: EmbeddedExecutionFixture.Mode, size: u64, failure: anyerror, copies: usize, metadata_copies: usize, reads: usize }{
        .{ .mode = .missing_member, .size = 3, .failure = error.FileNotFound, .copies = 0, .metadata_copies = 2, .reads = 0 },
        .{ .mode = .wrong_bytes, .size = 3, .failure = error.ChecksumMismatch, .copies = 0, .metadata_copies = 0, .reads = 0 },
        .{ .mode = .wrong_artifact, .size = 3, .failure = error.ChecksumMismatch, .copies = 1, .metadata_copies = 2, .reads = 1 },
        .{ .mode = .valid, .size = 4, .failure = error.SizeMismatch, .copies = 1, .metadata_copies = 2, .reads = 1 },
        .{ .mode = .late_tamper, .size = 3, .failure = error.ChecksumMismatch, .copies = 1, .metadata_copies = 2, .reads = 2 },
    };
    for (cases) |case| {
        var fixture: EmbeddedExecutionFixture = .{ .mode = case.mode };
        var recipe = try EmbeddedExecutionFixture.prepare(std.testing.allocator, EmbeddedExecutionFixture.coordinate, case.size, false, &fixture);
        defer recipe.deinit();
        try std.testing.expectError(case.failure, execute(std.testing.allocator, recipe.value, fixture.callbacks(), .{}, EmbeddedExecutionFixture.test_control));
        try std.testing.expectEqual(case.copies, fixture.copies);
        try std.testing.expectEqual(case.metadata_copies, fixture.metadata_copies);
        try std.testing.expectEqual(case.reads, fixture.reads);
        try std.testing.expectEqual(@as(usize, 0), fixture.tool_downloads);
        try std.testing.expectEqual(@as(usize, 0), fixture.processes);
        try std.testing.expectEqual(@as(usize, 0), fixture.commits);
        try std.testing.expectEqual(@as(usize, 1), fixture.rollbacks);
    }
}

test "absent and unrelated modern root paths never gain embedded or download fallback" {
    for ([_]?[]const u8{ null, "net.minecraftforge:other:1" }) |root_path| {
        var fixture: EmbeddedExecutionFixture = .{};
        var recipe = try EmbeddedExecutionFixture.prepare(std.testing.allocator, root_path, 3, false, &fixture);
        defer recipe.deinit();
        try std.testing.expectError(error.MissingGeneratedLibrary, execute(std.testing.allocator, recipe.value, fixture.callbacks(), .{}, EmbeddedExecutionFixture.test_control));
        try std.testing.expectEqual(@as(usize, 0), fixture.copies);
        try std.testing.expectEqual(@as(usize, 2), fixture.metadata_copies);
        try std.testing.expectEqual(@as(usize, 0), fixture.tool_downloads);
        try std.testing.expectEqual(@as(usize, 0), fixture.processes);
        try std.testing.expectEqual(@as(usize, 0), fixture.commits);
        try std.testing.expectEqual(@as(usize, 1), fixture.rollbacks);
    }
}

test "genuine processor generated empty URL library retains output verification" {
    const cases = [_]struct { mode: EmbeddedExecutionFixture.Mode, root_path: []const u8 }{
        .{ .mode = .generated, .root_path = EmbeddedExecutionFixture.coordinate },
        .{ .mode = .bad_generated, .root_path = EmbeddedExecutionFixture.coordinate },
        .{ .mode = .generated, .root_path = "net.minecraftforge:installertools:1" },
        .{ .mode = .bad_generated, .root_path = "net.minecraftforge:installertools:1" },
    };
    for (cases) |case| {
        const mode = case.mode;
        var fixture: EmbeddedExecutionFixture = .{ .mode = mode };
        var recipe = try EmbeddedExecutionFixture.prepare(std.testing.allocator, case.root_path, 3, true, &fixture);
        defer recipe.deinit();
        try std.testing.expect(recipe.value.artifacts[0].member == null);
        try std.testing.expectEqual(@as(usize, 1), recipe.value.processors.len);
        if (mode == .generated) {
            try execute(std.testing.allocator, recipe.value, fixture.callbacks(), .{ .java = "fixture-java", .java_major = 8 }, EmbeddedExecutionFixture.test_control);
        } else {
            try std.testing.expectError(error.ChecksumMismatch, execute(std.testing.allocator, recipe.value, fixture.callbacks(), .{ .java = "fixture-java", .java_major = 8 }, EmbeddedExecutionFixture.test_control));
        }
        try std.testing.expectEqual(@as(usize, 1), fixture.tool_downloads);
        try std.testing.expectEqual(@as(usize, 0), fixture.copies);
        try std.testing.expectEqual(@as(usize, 2), fixture.metadata_copies);
        try std.testing.expectEqual(@as(usize, 1), fixture.processes);
        try std.testing.expectEqual(@as(usize, if (mode == .generated) 1 else 0), fixture.commits);
        try std.testing.expectEqual(@as(usize, if (mode == .generated) 0 else 1), fixture.rollbacks);
    }
}

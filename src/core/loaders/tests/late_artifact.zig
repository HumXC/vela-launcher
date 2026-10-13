//! Late artifact integrity checks exercise the real executor with in-memory adapters.
const std = @import("std");
const execute = @import("../execute.zig");
const recipes = @import("../recipe.zig");
const common = @import("../common.zig");
const processors = @import("../forge_installer/processors.zig");
const A = std.mem.Allocator;
const root = "/tmp/vela-late-artifact-fixture";
const artifact_relative = "libraries/net/minecraftforge/fixture/1.0/fixture-1.0.jar";
const artifact_path = root ++ "/" ++ artifact_relative;
const artifact_url = "https://maven.minecraftforge.net/net/minecraftforge/fixture/1.0/fixture-1.0.jar";
const source_url = "https://maven.minecraftforge.net/fixture/profile.json";
const profile_bytes = "{}";
const sidecar_bytes = "a9993e364706816aba3e25717850c26c9cd0d89d\n";
const Mode = enum { sidecar, metadata, embedded };
fn now(_: ?*anyopaque) u64 {
    return 0;
}
const control: common.Control = .{ .now_ms = now, .deadline_ms = std.math.maxInt(u64) };

const Fixture = struct {
    mode: Mode,
    corrupt: bool = true,
    processed: bool = false,
    jar_ready: bool = false,
    begun: usize = 0,
    vanilla_calls: usize = 0,
    sidecars: usize = 0,
    artifact_downloads: usize = 0,
    extracted: usize = 0,
    copied: usize = 0,
    initial_reads: usize = 0,
    source_reads: usize = 0,
    final_reads: usize = 0,
    process_calls: usize = 0,
    commits: usize = 0,
    rollbacks: usize = 0,

    fn self(raw: ?*anyopaque) *Fixture {
        return @ptrCast(@alignCast(raw.?));
    }
    fn begin(raw: ?*anyopaque, stage: []const u8, ctl: common.Control) !void {
        try ctl.check();
        try std.testing.expectEqualStrings(root, stage);
        self(raw).begun += 1;
    }
    fn vanilla(raw: ?*anyopaque, _: recipes.Recipe, ctl: common.Control) !void {
        try ctl.check();
        self(raw).vanilla_calls += 1;
    }
    fn download(raw: ?*anyopaque, url: []const u8, destination: []const u8, hash: ?common.m.Sha1, ctl: common.Control) !void {
        try ctl.check();
        const f = self(raw);
        if (std.mem.eql(u8, url, source_url)) {
            try std.testing.expect(hash != null);
            try std.testing.expectEqualDeep(recipes.digest(if (f.mode == .embedded) "installer" else profile_bytes), hash.?);
            try std.testing.expectEqualStrings(if (f.mode == .embedded) root ++ "/.loader/installer.jar" else root ++ "/.loader/profile.json", destination);
        } else if (std.mem.eql(u8, url, artifact_url ++ ".sha1")) {
            try std.testing.expect(f.mode == .sidecar);
            try std.testing.expect(hash == null);
            try std.testing.expectEqualStrings(artifact_path ++ ".sha1", destination);
            f.sidecars += 1;
        } else if (std.mem.eql(u8, url, artifact_url)) {
            try std.testing.expect(f.mode != .embedded);
            try std.testing.expectEqualStrings(artifact_path, destination);
            try std.testing.expectEqualDeep(recipes.digest("abc"), hash.?);
            f.artifact_downloads += 1;
            f.jar_ready = true;
        } else return error.UnexpectedFixtureDownload;
    }
    fn extract(raw: ?*anyopaque, source: []const u8, destination: []const u8, ctl: common.Control) !void {
        try ctl.check();
        const f = self(raw);
        try std.testing.expect(f.mode == .embedded);
        try std.testing.expectEqualStrings(root ++ "/.loader/installer.jar", source);
        try std.testing.expectEqualStrings(root ++ "/.loader/archive", destination);
        f.extracted += 1;
    }
    fn copy(raw: ?*anyopaque, source: []const u8, destination: []const u8, ctl: common.Control) !void {
        try ctl.check();
        const f = self(raw);
        try std.testing.expect(f.mode == .embedded);
        try std.testing.expectEqualStrings(root ++ "/.loader/archive/fixture.jar", source);
        try std.testing.expectEqualStrings(artifact_path, destination);
        f.copied += 1;
        f.jar_ready = true;
    }
    fn read(raw: ?*anyopaque, a: A, path: []const u8, max: usize, ctl: common.Control) ![]u8 {
        try ctl.check();
        const f = self(raw);
        const bytes: []const u8 = if (std.mem.eql(u8, path, root ++ "/.loader/profile.json")) profile_bytes else if (std.mem.eql(u8, path, root ++ "/.loader/installer.jar")) "installer" else if (std.mem.eql(u8, path, artifact_path ++ ".sha1")) sidecar_bytes else if (std.mem.eql(u8, path, root ++ "/.loader/archive/fixture.jar")) blk: {
            try std.testing.expect(f.mode == .embedded and f.extracted == 1 and !f.jar_ready and !f.processed);
            f.source_reads += 1;
            break :blk "abc";
        } else if (std.mem.eql(u8, path, artifact_path)) blk: {
            try std.testing.expect(f.jar_ready);
            if (f.processed) {
                f.final_reads += 1;
                break :blk if (f.corrupt) "bad" else "abc";
            }
            f.initial_reads += 1;
            break :blk "abc";
        } else return error.UnexpectedFixtureRead;
        try std.testing.expect(bytes.len <= max);
        return a.dupe(u8, bytes);
    }
    fn mainClass(raw: ?*anyopaque, a: A, jar: []const u8, ctl: common.Control) ![]u8 {
        try ctl.check();
        const f = self(raw);
        try std.testing.expect(f.jar_ready and f.initial_reads > 0 and !f.processed);
        try std.testing.expectEqualStrings(artifact_path, jar);
        return a.dupe(u8, "net.minecraftforge.fixture.Main");
    }
    fn process(raw: ?*anyopaque, invocation: execute.Invocation) !execute.ProcessResult {
        try invocation.control.check();
        const f = self(raw);
        try std.testing.expectEqualStrings("java-fixture", invocation.java);
        try std.testing.expectEqualStrings("net.minecraftforge.fixture.Main", invocation.main_class);
        try std.testing.expectEqualStrings(root, invocation.working_directory);
        try std.testing.expectEqual(@as(usize, 1), invocation.classpath.len);
        try std.testing.expectEqualStrings(artifact_path, invocation.classpath[0]);
        try std.testing.expectEqual(@as(usize, 0), invocation.args.len);
        f.process_calls += 1;
        f.processed = true;
        return .{ .exited = 0 };
    }
    fn commit(raw: ?*anyopaque, _: recipes.Recipe) !void {
        self(raw).commits += 1;
    }
    fn rollback(raw: ?*anyopaque, _: []const u8) void {
        self(raw).rollbacks += 1;
    }
    fn callbacks(f: *Fixture) execute.Callbacks {
        return .{ .context = f, .begin = begin, .vanilla = vanilla, .download = download, .extract_installer = extract, .copy = copy, .read = read, .main_class = mainClass, .process = process, .commit = commit, .rollback = rollback };
    }
    fn expectExecuted(f: Fixture) !void {
        try std.testing.expectEqual(@as(usize, 1), f.begun);
        try std.testing.expectEqual(@as(usize, 1), f.vanilla_calls);
        try std.testing.expectEqual(@as(usize, 1), f.process_calls);
        try std.testing.expectEqual(@as(usize, 1), f.final_reads);
        try std.testing.expectEqual(@as(usize, 1), f.initial_reads);
        try std.testing.expectEqual(@as(usize, if (f.mode == .embedded) 1 else 0), f.source_reads);
        try std.testing.expectEqual(@as(usize, if (f.mode == .sidecar) 1 else 0), f.sidecars);
        try std.testing.expectEqual(@as(usize, if (f.mode == .embedded) 0 else 1), f.artifact_downloads);
        try std.testing.expectEqual(@as(usize, if (f.mode == .embedded) 1 else 0), f.extracted);
        try std.testing.expectEqual(@as(usize, if (f.mode == .embedded) 1 else 0), f.copied);
    }
};

fn check(mode: Mode, corrupt: bool) !void {
    const a = std.testing.allocator;
    var version = try common.m.version.parseSlice(a, "{\"id\":\"Custom\"}");
    defer version.deinit();
    const artifacts = [_]recipes.Artifact{.{ .coordinate = "net.minecraftforge:fixture:1.0", .path = artifact_relative, .url = if (mode == .embedded) null else artifact_url, .sha1 = if (mode == .metadata) recipes.digest("abc") else null, .size = 3, .member = if (mode == .embedded) "fixture.jar" else null }};
    const steps = [_]processors.Processor{.{ .jar = artifact_path, .classpath = &.{artifact_path}, .args = &.{}, .outputs = &.{} }};
    const recipe: recipes.Recipe = .{
        .selection = .{ .kind = .forge, .base_id = "1.20.1", .loader_id = "47.0.0" },
        .instance_name = "Custom",
        .stage_root = root,
        .version = version.value,
        .source_url = source_url,
        .source_sha1 = recipes.digest(profile_bytes),
        .installer_sha1 = if (mode == .embedded) recipes.digest("installer") else null,
        .artifacts = &artifacts,
        .members = &.{},
        .processors = &steps,
        .game_java_major = 17,
        .installer_java_major = 17,
    };
    var f: Fixture = .{ .mode = mode, .corrupt = corrupt };
    const options: execute.Options = .{ .java = "java-fixture", .java_major = 17 };
    if (corrupt) {
        try std.testing.expectError(error.ChecksumMismatch, execute.execute(a, recipe, f.callbacks(), options, control));
        try std.testing.expectEqual(@as(usize, 0), f.commits);
        try std.testing.expectEqual(@as(usize, 1), f.rollbacks);
    } else {
        try execute.execute(a, recipe, f.callbacks(), options, control);
        try std.testing.expectEqual(@as(usize, 1), f.commits);
        try std.testing.expectEqual(@as(usize, 0), f.rollbacks);
    }
    try f.expectExecuted();
}

test "late processor mutation of sidecar verified artifact rolls back without commit" {
    try check(.sidecar, true);
}

test "late processor mutation of metadata verified artifact rolls back without commit" {
    try check(.metadata, true);
}

test "late processor mutation of embedded initially digested artifact rolls back without commit" {
    try check(.embedded, true);
}

test "unchanged sidecar metadata and embedded artifacts retain verified commit path" {
    for ([_]Mode{ .sidecar, .metadata, .embedded }) |mode| try check(mode, false);
}

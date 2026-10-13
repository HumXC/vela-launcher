const std = @import("std");
const l = @import("../root.zig");
const c = @import("../common.zig");
const r = l.recipes;
const x = l.execution;
const p = @import("../forge_installer/processors.zig");
const a = std.testing.allocator;
const env: c.m.rules.Environment = .{ .os_name = "linux", .arch = "x86_64" };
fn base(id: []const u8) !c.m.Owned(c.m.version.Version) {
    const json = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"mainClass\":\"vanilla.Main\",\"libraries\":[],\"downloads\":{{\"client\":{{\"url\":\"https://piston-data.mojang.com/client.jar\"}}}}}}", .{id});
    defer a.free(json);
    return c.m.version.parseSlice(a, json);
}
const fabric_profile =
    \\{"id":"fabric-loader-0.16.0-1.20.1","inheritsFrom":"1.20.1","mainClass":"net.fabricmc.loader.impl.launch.knot.KnotClient","libraries":[{"name":"net.fabricmc:fabric-loader:0.16.0","url":"https://maven.fabricmc.net/"}],"arguments":{"game":["--fabric"]}}
;
fn catalog(kind: l.Kind, id: []const u8) !c.m.Owned(l.Catalog) {
    return l.parseCatalog(a, kind, id, switch (kind) {
        .fabric, .quilt => "[{\"loader\":{\"version\":\"0.16.0\",\"stable\":true}}]",
        .forge => "{\"1.7.10\":[\"1.7.10-10.13.4.1614-1.7.10\"],\"1.20.1\":[\"1.20.1-47.2.0\"]}",
        .neoforge => "{\"versions\":[\"20.2.3-beta\",\"21.0.1-beta\",\"20.4.1\"]}",
    });
}
test "catalog only official actual supported pairs and exact IDs" {
    var neo = try catalog(.neoforge, "1.20.2");
    defer neo.deinit();
    try std.testing.expectEqual(@as(usize, 1), neo.value.entries.len);
    try std.testing.expect(neo.value.find("21.0.1-beta") == null);
    try std.testing.expectError(error.UnsupportedLoaderVersion, neo.value.validate(.{ .kind = .neoforge, .base_id = "1.20.2", .loader_id = "20.4.1" }));
    var legacy = try catalog(.forge, "1.7.10");
    defer legacy.deinit();
    try std.testing.expectEqual(@as(usize, 1), legacy.value.entries.len);
    var unsupported = try catalog(.forge, "1.7.11");
    defer unsupported.deinit();
    try std.testing.expectEqual(@as(usize, 0), unsupported.value.entries.len);
    try std.testing.expectError(error.UnsafeVersionId, l.parseCatalog(a, .fabric, "../bad", "[]"));
}
test "Fabric and Quilt merge preserves vanilla and custom instance" {
    for ([_]l.Kind{ .fabric, .quilt }) |kind| {
        var cat = try catalog(kind, "1.20.1");
        defer cat.deinit();
        var vanilla = try base("1.20.1");
        defer vanilla.deinit();
        var recipe = try l.prepare(a, cat.value, .{ .kind = kind, .base_id = "1.20.1", .loader_id = "0.16.0" }, vanilla.value, .{ .source_url = cat.value.entries[0].url, .profile = fabric_profile }, .{ .instance_name = "My Custom Instance", .stage_root = "/tmp/synthetic stage", .environment = env });
        defer recipe.deinit();
        try std.testing.expectEqualStrings("My Custom Instance", recipe.value.version.id);
        try std.testing.expectEqualStrings("1.20.1", recipe.value.version.jar.?);
        try std.testing.expectEqual(@as(usize, 1), recipe.value.artifacts.len);
        try std.testing.expectEqual(@as(usize, 0), recipe.value.processors.len);
        try std.testing.expectEqualStrings("libraries/net/fabricmc/fabric-loader/0.16.0/fabric-loader-0.16.0.jar", recipe.value.artifacts[0].path);
    }
}
const old_profile =
    \\{"install":{"minecraft":"1.7.10","path":"net.minecraftforge:forge:1.7.10-10.13.4.1614-1.7.10","filePath":"forge-universal.jar"},"versionInfo":{"id":"1.7.10-Forge","inheritsFrom":"1.7.10","jar":"1.7.10","mainClass":"net.minecraft.launchwrapper.Launch","minecraftArguments":"--tweakClass cpw.mods.fml.common.launcher.FMLTweaker","libraries":[{"name":"net.minecraftforge:forge:1.7.10-10.13.4.1614-1.7.10","url":"https://maven.minecraftforge.net/"}]}}
;
test "actual old Forge inherited runtime-binpatch recipe extracts universal" {
    var cat = try catalog(.forge, "1.7.10");
    defer cat.deinit();
    var vanilla = try base("1.7.10");
    defer vanilla.deinit();
    var recipe = try l.prepare(a, cat.value, .{ .kind = .forge, .base_id = "1.7.10", .loader_id = cat.value.entries[0].id }, vanilla.value, .{ .source_url = cat.value.entries[0].url, .profile = old_profile, .installer_sha1 = r.digest("archive") }, .{ .instance_name = "Legacy", .stage_root = "/stage", .environment = env });
    defer recipe.deinit();
    try std.testing.expectEqualStrings("forge-universal.jar", recipe.value.artifacts[0].member.?);
    try std.testing.expect(recipe.value.artifacts[0].url == null);
    try std.testing.expectEqual(@as(usize, 0), recipe.value.processors.len);
    try std.testing.expectEqualStrings("1.7.10", recipe.value.version.jar.?);
}
const modern_profile =
    \\{"minecraft":"1.20.1","json":"/version.json","libraries":[{"name":"net.minecraftforge:installertools:1.0","downloads":{"artifact":{"path":"net/minecraftforge/installertools/1.0/installertools-1.0.jar","url":"https://maven.minecraftforge.net/net/minecraftforge/installertools/1.0/installertools-1.0.jar","sha1":"fb391320cf8346ac96b8bd3dce6d7d8eaccf87f2"}}}],"data":{"HASH":{"client":"'c00dbbc9dadfbe1e232e93a729dd4752fade0abf'","server":"'c00dbbc9dadfbe1e232e93a729dd4752fade0abf'"},"PATCH":{"client":"/data/client.lzma","server":"/data/server.lzma"}},"processors":[{"sides":["server"],"jar":"untrusted:never:1","classpath":[],"args":[]},{"sides":["client"],"jar":"net.minecraftforge:installertools:1.0","classpath":[],"args":["--input","{MINECRAFT_JAR}","literal with spaces;$(no shell)","{PATCH}"],"outputs":{"{ROOT}/libraries/generated.jar":"{HASH}"}}]}
;
const modern_version =
    \\{"id":"forge-modern","inheritsFrom":"1.20.1","mainClass":"cpw.mods.bootstraplauncher.BootstrapLauncher","libraries":[]}
;
fn modernRecipe() !c.m.Owned(r.Recipe) {
    var cat = try catalog(.forge, "1.20.1");
    defer cat.deinit();
    var vanilla = try base("1.20.1");
    defer vanilla.deinit();
    return l.prepare(a, cat.value, .{ .kind = .forge, .base_id = "1.20.1", .loader_id = cat.value.entries[0].id }, vanilla.value, .{ .source_url = cat.value.entries[0].url, .profile = modern_profile, .version_json = modern_version, .installer_sha1 = r.digest("archive") }, .{ .instance_name = "Modern", .stage_root = "/stage", .environment = env });
}
test "modern processors data side filter output expansion" {
    var recipe = try modernRecipe();
    defer recipe.deinit();
    try std.testing.expectEqual(@as(usize, 1), recipe.value.processors.len);
    const proc = recipe.value.processors[0];
    try std.testing.expectEqualStrings("literal with spaces;$(no shell)", proc.args[2]);
    try std.testing.expectEqualStrings("/stage/.loader/data/data/client.lzma", proc.args[3]);
    try std.testing.expectEqualStrings("/stage/libraries/generated.jar", proc.outputs[0].path);
}
test "traversal URLs malformed processor data and classes rejected" {
    for ([_][]const u8{ "https://maven.minecraftforge.net.evil/x", "http://maven.minecraftforge.net/x", "https://maven.minecraftforge.net/a/%2e%2e/x", "https://maven.minecraftforge.net/a/../x", "https://user@maven.minecraftforge.net/x" }) |url| try std.testing.expectError(error.UntrustedUrl, c.trusted(url));
    try std.testing.expectError(error.OutputEscapesStage, p.underRoot("/stage", "/elsewhere/x.jar"));
    try std.testing.expectError(error.UnsafeVersionId, p.underRoot("/stage", "/stage/../x.jar"));
    try std.testing.expectError(error.UntrustedProcessorClass, x.trustedClass("java.lang.Runtime"));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const data = std.StringHashMap([]const u8).init(arena.allocator());
    try std.testing.expectError(error.MissingProcessorData, p.expand(arena.allocator(), "{MISSING}", data, "/stage"));
    try std.testing.expectError(error.MalformedProcessorToken, p.expand(arena.allocator(), "{BAD", data, "/stage"));
}
fn zero(_: ?*anyopaque) u64 {
    return 0;
}
const control: c.Control = .{ .deadline_ms = 100, .now_ms = zero };
const Fake = struct {
    committed: bool = false,
    rolled_back: bool = false,
    began: bool = false,
    processed: bool = false,
    bad_output: bool = false,
    output_reads: usize = 0,
    late_output_tamper: bool = false,
    empty_output: bool = false,
    fail_process: bool = false,
    fail_commit: bool = false,
    fail_begin: bool = false,
    cancel_after_process: ?*std.atomic.Value(bool) = null,
    result: x.ProcessResult = .{ .exited = 0 },
    fn self(ctx: ?*anyopaque) *Fake {
        return @ptrCast(@alignCast(ctx.?));
    }
    fn begin(ctx: ?*anyopaque, _: []const u8, _: c.Control) !void {
        self(ctx).began = true;
        if (self(ctx).fail_begin) return error.InjectedBegin;
    }
    fn vanilla(_: ?*anyopaque, _: r.Recipe, _: c.Control) !void {}
    fn download(_: ?*anyopaque, _: []const u8, _: []const u8, _: ?c.m.Sha1, _: c.Control) !void {}
    fn extract(_: ?*anyopaque, _: []const u8, _: []const u8, _: c.Control) !void {}
    fn copy(_: ?*anyopaque, _: []const u8, _: []const u8, _: c.Control) !void {}
    fn read(ctx: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8, _: usize, _: c.Control) ![]u8 {
        if (std.mem.endsWith(u8, path, "generated.jar")) {
            const f = self(ctx);
            f.output_reads += 1;
            return allocator.dupe(u8, if (f.empty_output) "" else if (f.bad_output or (f.late_output_tamper and f.output_reads > 1)) "bad" else "old");
        }
        const bytes = if (std.mem.endsWith(u8, path, "installer.jar")) "archive" else if (std.mem.endsWith(u8, path, "install_profile.json") or std.mem.endsWith(u8, path, "profile.json")) modern_profile else if (std.mem.endsWith(u8, path, "version.json")) modern_version else "tool";
        return allocator.dupe(u8, bytes);
    }
    fn main(_: ?*anyopaque, allocator: std.mem.Allocator, _: []const u8, _: c.Control) ![]u8 {
        return allocator.dupe(u8, "net.minecraftforge.installertools.ConsoleTool");
    }
    fn process(ctx: ?*anyopaque, invocation: x.Invocation) !x.ProcessResult {
        const f = self(ctx);
        try std.testing.expect(!f.committed);
        try std.testing.expectEqualStrings("literal with spaces;$(no shell)", invocation.args[2]);
        f.processed = true;
        if (f.cancel_after_process) |flag| flag.store(true, .release);
        if (f.fail_process) return error.InjectedProcess;
        return f.result;
    }
    fn commit(ctx: ?*anyopaque, _: r.Recipe) !void {
        if (self(ctx).fail_commit) return error.InjectedCommit;
        try std.testing.expect(self(ctx).processed);
        self(ctx).committed = true;
    }
    fn rollback(ctx: ?*anyopaque, _: []const u8) void {
        self(ctx).rolled_back = true;
    }
    fn callbacks(f: *Fake) x.Callbacks {
        return .{ .context = f, .begin = begin, .vanilla = vanilla, .download = download, .extract_installer = extract, .copy = copy, .read = read, .main_class = main, .process = process, .commit = commit, .rollback = rollback };
    }
};
const java: x.Options = .{ .java = "/synthetic/java", .java_major = 21 };
test "transaction verifies outputs before atomic custom instance commit" {
    var recipe = try modernRecipe();
    defer recipe.deinit();
    // Fixture's artifact digest is computed, never a remote processor.
    const artifacts = @constCast(recipe.value.artifacts);
    artifacts[0].sha1 = r.digest("tool");
    var fake: Fake = .{};
    try l.execute(a, recipe.value, fake.callbacks(), java, control);
    try std.testing.expect(fake.committed and fake.processed and !fake.rolled_back);
}
test "missing Java cancel deadline and processor failures never early commit" {
    var recipe = try modernRecipe();
    defer recipe.deinit();
    @constCast(recipe.value.artifacts)[0].sha1 = r.digest("tool");
    var fake: Fake = .{};
    try std.testing.expectError(error.MissingJava, l.execute(a, recipe.value, fake.callbacks(), .{}, control));
    try std.testing.expect(!fake.began and !fake.committed);
    try std.testing.expectError(error.JavaTooOld, l.execute(a, recipe.value, fake.callbacks(), .{ .java = "java", .java_major = 7 }, control));
    var flag = std.atomic.Value(bool).init(true);
    var canceled_control = control;
    canceled_control.cancel = &flag;
    try std.testing.expectError(error.Canceled, l.execute(a, recipe.value, fake.callbacks(), java, canceled_control));
    var expired = control;
    expired.deadline_ms = 0;
    try std.testing.expectError(error.DeadlineExceeded, l.execute(a, recipe.value, fake.callbacks(), java, expired));
    flag.store(false, .release);
    fake = .{ .cancel_after_process = &flag };
    try std.testing.expectError(error.Canceled, l.execute(a, recipe.value, fake.callbacks(), java, canceled_control));
    try std.testing.expect(fake.rolled_back and !fake.committed);
    fake = .{ .bad_output = true };
    try std.testing.expectError(error.ChecksumMismatch, l.execute(a, recipe.value, fake.callbacks(), java, control));
    try std.testing.expect(fake.rolled_back and !fake.committed);
    fake = .{ .result = .{ .exited = 1 } };
    try std.testing.expectError(error.ProcessorFailed, l.execute(a, recipe.value, fake.callbacks(), java, control));
    try std.testing.expect(fake.rolled_back and !fake.committed);
    fake = .{ .fail_begin = true };
    try std.testing.expectError(error.InjectedBegin, l.execute(a, recipe.value, fake.callbacks(), java, control));
    try std.testing.expect(fake.rolled_back and !fake.committed);
    fake = .{ .fail_commit = true };
    try std.testing.expectError(error.InjectedCommit, l.execute(a, recipe.value, fake.callbacks(), java, control));
    try std.testing.expect(fake.rolled_back and !fake.committed);
}
fn allocationCatalog(allocator: std.mem.Allocator) !void {
    var cat = try l.parseCatalog(allocator, .fabric, "1.20.1", "[{\"loader\":{\"version\":\"0.16.0\"}}]");
    defer cat.deinit();
}
fn allocationRecipe(allocator: std.mem.Allocator) !void {
    var cat = try catalog(.forge, "1.20.1");
    defer cat.deinit();
    var vanilla = try base("1.20.1");
    defer vanilla.deinit();
    var recipe = try l.prepare(allocator, cat.value, .{ .kind = .forge, .base_id = "1.20.1", .loader_id = cat.value.entries[0].id }, vanilla.value, .{ .source_url = cat.value.entries[0].url, .profile = modern_profile, .version_json = modern_version, .installer_sha1 = r.digest("archive") }, .{ .instance_name = "Custom", .stage_root = "/stage", .environment = env });
    defer recipe.deinit();
}
fn allocationExecute(allocator: std.mem.Allocator) !void {
    var recipe = try modernRecipe();
    defer recipe.deinit();
    @constCast(recipe.value.artifacts)[0].sha1 = r.digest("tool");
    var fake: Fake = .{};
    l.execute(allocator, recipe.value, fake.callbacks(), java, control) catch |err| {
        if (fake.began) try std.testing.expect(fake.rolled_back and !fake.committed);
        return err;
    };
}
test "allocation failure cleanup catalog recipe executor and no early commit" {
    try @import("test_allocations").checkAllAllocationFailures(a, allocationCatalog, .{});
    try @import("test_allocations").checkAllAllocationFailures(a, allocationRecipe, .{});
    try @import("test_allocations").checkAllAllocationFailures(a, allocationExecute, .{});
}
const HttpFake = struct {
    status: u16 = 200,
    redirect: ?[]const u8 = null,
    called: bool = false,
    fn get(ctx: ?*anyopaque, allocator: std.mem.Allocator, url: []const u8, max: usize, ctl: c.Control) !l.Response {
        const f: *HttpFake = @ptrCast(@alignCast(ctx.?));
        try ctl.check();
        f.called = true;
        try std.testing.expectEqual(@as(usize, 8 * 1024 * 1024), max);
        const bytes = try allocator.dupe(u8, "[]");
        errdefer allocator.free(bytes);
        return .{ .status = f.status, .bytes = bytes, .final_url = try allocator.dupe(u8, f.redirect orelse url) };
    }
    fn transport(f: *HttpFake) l.Transport {
        return .{ .context = f, .get = get };
    }
};
test "injectable transport owns bytes and rejects origin changes status cancel" {
    var fake: HttpFake = .{};
    var result = try l.fetchCatalog(a, fake.transport(), .fabric, "1.20.1", control);
    defer result.deinit();
    try std.testing.expect(fake.called);
    for ([_]l.Kind{ .fabric, .quilt, .forge, .neoforge }) |kind| {
        fake = .{ .status = 404 };
        var absent = try l.fetchCatalog(a, fake.transport(), kind, "1.20.1", control);
        defer absent.deinit();
        try std.testing.expectEqual(@as(usize, 0), absent.value.entries.len);
    }
    fake = .{ .status = 503 };
    try std.testing.expectError(error.HttpStatus, l.fetchCatalog(a, fake.transport(), .fabric, "1.20.1", control));
    fake = .{ .redirect = "https://evil.invalid/profile" };
    try std.testing.expectError(error.UntrustedUrl, l.fetchCatalog(a, fake.transport(), .fabric, "1.20.1", control));
    fake = .{ .redirect = "https://maven.minecraftforge.net/other" };
    try std.testing.expectError(error.UnexpectedRedirect, l.fetchCatalog(a, fake.transport(), .fabric, "1.20.1", control));
    fake = .{};
    var canceled = std.atomic.Value(bool).init(true);
    var ctl = control;
    ctl.cancel = &canceled;
    try std.testing.expectError(error.Canceled, l.fetchCatalog(a, fake.transport(), .fabric, "1.20.1", ctl));
    try std.testing.expect(!fake.called);
}
const neo_profile =
    \\{"minecraft":"1.20.2","json":"/version.json","libraries":[{"name":"net.neoforged:installertools:1.0","downloads":{"artifact":{"path":"net/neoforged/installertools/1.0/installertools-1.0.jar","url":"https://maven.neoforged.net/releases/net/neoforged/installertools/1.0/installertools-1.0.jar","sha1":"fb391320cf8346ac96b8bd3dce6d7d8eaccf87f2"}}}],"data":{"OUT":{"client":"[net.neoforged:neoforge:20.2.3-beta:client]","server":"[net.neoforged:neoforge:20.2.3-beta:server]"},"HASH":{"client":"'c00dbbc9dadfbe1e232e93a729dd4752fade0abf'","server":"'c00dbbc9dadfbe1e232e93a729dd4752fade0abf'"}},"processors":[{"jar":"net.neoforged:installertools:1.0","classpath":[],"args":["--output","{OUT}"],"outputs":{"{OUT}":"{HASH}"}}]}
;
const neo_version =
    \\{"id":"neoforge-modern","inheritsFrom":"1.20.2","mainClass":"cpw.mods.bootstraplauncher.BootstrapLauncher","libraries":[]}
;
test "NeoForge new profile Maven data and side output checksums" {
    var cat = try catalog(.neoforge, "1.20.2");
    defer cat.deinit();
    var vanilla = try base("1.20.2");
    defer vanilla.deinit();
    for ([_]c.Side{ .client, .server }) |side| {
        var recipe = try l.prepare(a, cat.value, .{ .kind = .neoforge, .base_id = "1.20.2", .loader_id = cat.value.entries[0].id, .side = side }, vanilla.value, .{ .source_url = cat.value.entries[0].url, .profile = neo_profile, .version_json = neo_version, .installer_sha1 = r.digest("archive") }, .{ .instance_name = "Neo Custom", .stage_root = "/stage", .environment = env, .side = side });
        defer recipe.deinit();
        try std.testing.expectEqual(@as(usize, 1), recipe.value.processors.len);
        try std.testing.expectEqualStrings(recipe.value.processors[0].outputs[0].path, recipe.value.processors[0].args[1]);
        try std.testing.expect(std.mem.indexOf(u8, recipe.value.processors[0].args[1], if (side == .client) "-client.jar" else "-server.jar") != null);
        try std.testing.expectEqual(r.digest("old"), recipe.value.processors[0].outputs[0].sha1);
    }
}
// Official https://maven.minecraftforge.net/net/minecraftforge/forge/1.20.1-47.2.0/forge-1.20.1-47.2.0-installer.jar
// Only its metadata was extracted; no installer or game code is executed.
test "actual modern Forge official installer profile plans all client processors" {
    var cat = try catalog(.forge, "1.20.1");
    defer cat.deinit();
    var vanilla = try base("1.20.1");
    defer vanilla.deinit();
    var recipe = try l.prepare(a, cat.value, .{ .kind = .forge, .base_id = "1.20.1", .loader_id = "1.20.1-47.2.0" }, vanilla.value, .{ .source_url = cat.value.entries[0].url, .profile = @embedFile("../fixtures/forge_1_20_1_install.json"), .version_json = @embedFile("../fixtures/forge_1_20_1_version.json"), .installer_sha1 = r.digest("archive") }, .{ .instance_name = "Actual Modern Forge", .stage_root = "/stage", .environment = env });
    defer recipe.deinit();
    try std.testing.expectEqual(@as(usize, 6), recipe.value.processors.len);
    try std.testing.expect(recipe.value.artifacts.len > 20);
    const patched = "net.minecraftforge:forge:1.20.1-47.2.0:client";
    const extra = "net.minecraft:client:1.20.1-20230612.114412:extra";
    var generated: usize = 0;
    for (recipe.value.artifacts) |artifact| {
        const producer = artifact.producer orelse continue;
        generated += 1;
        try std.testing.expectEqualStrings("", artifact.url.?);
        try std.testing.expect(artifact.member == null);
        const proc = recipe.value.processors[producer];
        var bound = false;
        for (proc.outputs) |out| if (std.mem.eql(u8, out.path["/stage/".len..], artifact.path)) {
            try std.testing.expectEqual(artifact.sha1, out.sha1);
            bound = true;
        };
        try std.testing.expect(bound);
        if (std.mem.eql(u8, artifact.coordinate, patched)) {
            try std.testing.expectEqual(@as(usize, 5), producer);
            try std.testing.expectEqual(try c.sha1("3e175b011146785588f1649a20d1834d10282a7c"), artifact.sha1.?);
        } else if (std.mem.eql(u8, artifact.coordinate, extra)) {
            try std.testing.expectEqual(@as(usize, 3), producer);
            try std.testing.expect(artifact.sha1 != null);
        } else {
            try std.testing.expectEqualStrings("net.minecraft:client:1.20.1-20230612.114412:srg", artifact.coordinate);
            try std.testing.expectEqual(@as(usize, 4), producer);
            try std.testing.expect(artifact.sha1 == null);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), generated);
    try std.testing.expectEqual(@as(usize, 1), recipe.value.processors[4].outputs.len);
    try std.testing.expect(recipe.value.processors[4].outputs[0].sha1 == null);
    for (recipe.value.artifacts) |artifact| {
        try std.testing.expect(std.mem.indexOf(u8, artifact.coordinate, ":slim") == null);
        try std.testing.expect(std.mem.indexOf(u8, artifact.coordinate, "mappings") == null);
    }
}
test "stage roots malformed data outputs rules and legacy transforms fail explicitly" {
    for ([_][]const u8{ "relative", "/stage/../live", "/stage/", "/stage//nested", "C:/stage/../live", "C:\\stage" }) |root| try std.testing.expectError(error.UnsafeStageRoot, c.stageRoot(root));
    try c.stageRoot("C:/stage/Synthetic Fixture");
    try c.stageRoot("/tmp/stage fixture");
    var cat = try catalog(.forge, "1.7.10");
    defer cat.deinit();
    var vanilla = try base("1.7.10");
    defer vanilla.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const g = arena.allocator();
    var parsed = try std.json.parseFromSlice(std.json.Value, g, old_profile, .{ .allocate = .alloc_always });
    const install = parsed.value.object.getPtr("install").?;
    const transforms = try std.json.parseFromSlice(std.json.Value, g, "[{}]", .{});
    try install.object.put(g, "transforms", transforms.value);
    const changed = try std.json.Stringify.valueAlloc(g, parsed.value, .{});
    try std.testing.expectError(error.LegacyForgeTransformsRequired, l.prepare(a, cat.value, .{ .kind = .forge, .base_id = "1.7.10", .loader_id = cat.value.entries[0].id }, vanilla.value, .{ .source_url = cat.value.entries[0].url, .profile = changed, .installer_sha1 = r.digest("archive") }, .{ .instance_name = "Legacy", .stage_root = "/stage", .environment = env }));
    const artifacts = [_]r.Artifact{.{ .coordinate = "net.minecraftforge:installertools:1.0", .path = "libraries/tool.jar", .url = "https://maven.minecraftforge.net/tool.jar", .sha1 = r.digest("tool"), .size = null }};
    const cases = [_]struct { json: []const u8, expected: anyerror }{
        .{ .json = "{\"data\":{\"ROOT\":{\"client\":\"'bad'\"}},\"processors\":[]}", .expected = error.ReservedProcessorData },
        .{ .json = "{\"data\":{\"X\":{\"client\":\"/../secret\"}},\"processors\":[]}", .expected = error.UnsafeVersionId },
        .{ .json = "{\"data\":{\"X\":{\"client\":\"'{ROOT}'\"}},\"processors\":[]}", .expected = error.InvalidProcessorLiteral },
        .{ .json = "{\"processors\":[{\"jar\":\"net.minecraftforge:installertools:1.0\",\"classpath\":[],\"args\":[],\"outputs\":{\"{ROOT}/out.jar\":\"broken\"}}]}", .expected = error.InvalidSha1 },
        .{ .json = "{\"processors\":[{\"jar\":\"net.minecraftforge:installertools:1.0\",\"classpath\":[],\"args\":[],\"sides\":[\"both\"]}]}", .expected = error.InvalidProcessorSide },
    };
    for (cases) |case| {
        const raw = try std.json.parseFromSlice(std.json.Value, g, case.json, .{});
        var members: std.ArrayList(r.Member) = .empty;
        var artifact_list: std.ArrayList(r.Artifact) = .empty;
        try artifact_list.appendSlice(g, &artifacts);
        try std.testing.expectError(case.expected, p.build(g, raw.value, &artifact_list, "/stage", "1.20.1", .client, &members));
    }
    var fabric = try catalog(.fabric, "1.20.1");
    defer fabric.deinit();
    var fabric_base = try base("1.20.1");
    defer fabric_base.deinit();
    const profile =
        \\{"id":"fabric-loader","inheritsFrom":"1.20.1","mainClass":"net.fabricmc.loader.impl.launch.knot.KnotClient","libraries":[{"name":"net.fabricmc:fabric-loader:0.16.0","url":"https://maven.fabricmc.net/","rules":[{"action":"disallow","os":{"name":"linux"}}]}]}
    ;
    var recipe = try l.prepare(a, fabric.value, .{ .kind = .fabric, .base_id = "1.20.1", .loader_id = "0.16.0" }, fabric_base.value, .{ .source_url = fabric.value.entries[0].url, .profile = profile }, .{ .instance_name = "Rules", .stage_root = "/stage", .environment = env });
    defer recipe.deinit();
    try std.testing.expectEqual(@as(usize, 0), recipe.value.artifacts.len);
}
test "generated libraries validate runtime metadata digest and size before commit" {
    var recipe = try modernRecipe();
    defer recipe.deinit();
    var artifacts = [_]r.Artifact{
        recipe.value.artifacts[0],
        .{ .coordinate = "net.minecraftforge:generated:1.0", .path = "libraries/generated.jar", .url = "", .sha1 = r.digest("old"), .size = 4 },
    };
    artifacts[0].sha1 = r.digest("tool");
    recipe.value.artifacts = &artifacts;
    var fake: Fake = .{};
    try std.testing.expectError(error.SizeMismatch, l.execute(a, recipe.value, fake.callbacks(), java, control));
    try std.testing.expect(fake.rolled_back and !fake.committed);
    artifacts[1].size = 3;
    artifacts[1].sha1 = r.digest("bad");
    fake = .{};
    try std.testing.expectError(error.ChecksumMismatch, l.execute(a, recipe.value, fake.callbacks(), java, control));
    try std.testing.expect(fake.rolled_back and !fake.committed);
    artifacts[1].sha1 = r.digest("old");
    fake = .{};
    try l.execute(a, recipe.value, fake.callbacks(), java, control);
    try std.testing.expect(fake.committed and !fake.rolled_back);
}
test "generated artifacts without upstream SHA retain producer and observed integrity" {
    var recipe = try modernRecipe();
    defer recipe.deinit();
    var artifacts = [_]r.Artifact{
        recipe.value.artifacts[0],
        .{ .coordinate = "net.neoforged:neoforge:21.1.1:client", .path = "libraries/generated.jar", .url = "", .sha1 = null, .size = null, .producer = 0 },
    };
    artifacts[0].sha1 = r.digest("tool");
    const outputs = [_]p.Output{.{ .path = "/stage/libraries/generated.jar", .sha1 = null, .runtime = true }};
    var processors = [_]p.Processor{recipe.value.processors[0]};
    processors[0].outputs = &outputs;
    recipe.value.processors = &processors;
    recipe.value.artifacts = &artifacts;
    var fake: Fake = .{};
    try l.execute(a, recipe.value, fake.callbacks(), java, control);
    try std.testing.expect(fake.committed and artifacts[1].sha1 == null);
    fake = .{ .late_output_tamper = true };
    try std.testing.expectError(error.ChecksumMismatch, l.execute(a, recipe.value, fake.callbacks(), java, control));
    try std.testing.expect(fake.rolled_back and !fake.committed);
    fake = .{ .empty_output = true };
    try std.testing.expectError(error.EmptyProcessorOutput, l.execute(a, recipe.value, fake.callbacks(), java, control));
    try std.testing.expect(fake.rolled_back and !fake.committed);
    artifacts[1].producer = 1;
    fake = .{};
    try std.testing.expectError(error.InvalidGeneratedArtifact, l.execute(a, recipe.value, fake.callbacks(), java, control));
    try std.testing.expect(fake.rolled_back and !fake.committed);
}
test "artifact declarations enrich missing proofs and consistently reject conflicts" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const g = arena.allocator();
    var artifacts: std.ArrayList(r.Artifact) = .empty;
    const bare: r.Artifact = .{ .coordinate = "g:a:1", .path = "libraries/g/a/1/a-1.jar", .url = null, .sha1 = null, .size = null };
    try r.mergeArtifact(g, &artifacts, bare);
    const proof: r.Artifact = .{ .coordinate = "g:a:1@jar", .path = bare.path, .url = "https://maven.minecraftforge.net/g/a/1/a-1.jar", .sha1 = r.digest("old"), .size = 3 };
    try r.mergeArtifact(g, &artifacts, proof);
    try r.mergeArtifact(g, &artifacts, bare);
    try std.testing.expectEqual(@as(usize, 1), artifacts.items.len);
    try std.testing.expectEqual(proof.sha1, artifacts.items[0].sha1);
    try std.testing.expectEqual(proof.size, artifacts.items[0].size);
    var conflict = proof;
    conflict.sha1 = r.digest("bad");
    try std.testing.expectError(error.ConflictingArtifact, r.mergeArtifact(g, &artifacts, conflict));
    conflict = proof;
    conflict.size = 4;
    try std.testing.expectError(error.ConflictingArtifact, r.mergeArtifact(g, &artifacts, conflict));
    conflict = proof;
    conflict.url = "https://maven.minecraftforge.net/other.jar";
    try std.testing.expectError(error.ConflictingArtifact, r.mergeArtifact(g, &artifacts, conflict));
    try std.testing.expectEqual(proof.sha1, artifacts.items[0].sha1);
    try std.testing.expectEqual(proof.size, artifacts.items[0].size);
}

test "authentic NeoForge 21 and 26 client profiles resolve processor jar aliases and bind runtime outputs" {
    const cases = .{
        .{ "1.21.1", "21.1.1", @as(u64, 21), @embedFile("../fixtures/neoforge_1_21_1_install.json"), @embedFile("../fixtures/neoforge_1_21_1_version.json") },
        .{ "26.1", "26.1.0.1-beta", @as(u64, 25), @embedFile("../fixtures/neoforge_26_1_install.json"), @embedFile("../fixtures/neoforge_26_1_version.json") },
    };
    inline for (cases) |case| {
        const vanilla_bytes = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"mainClass\":\"vanilla.Main\",\"libraries\":[],\"javaVersion\":{{\"component\":\"fixture\",\"majorVersion\":{d}}},\"downloads\":{{\"client\":{{\"url\":\"https://piston-data.mojang.com/client.jar\"}}}}}}", .{ case[0], case[2] });
        defer a.free(vanilla_bytes);
        var vanilla = try c.m.version.parseSlice(a, vanilla_bytes);
        defer vanilla.deinit();
        const catalog_bytes = try std.fmt.allocPrint(a, "{{\"versions\":[\"{s}\"]}}", .{case[1]});
        defer a.free(catalog_bytes);
        var cat = try l.parseCatalog(a, .neoforge, case[0], catalog_bytes);
        defer cat.deinit();
        var recipe = try l.prepare(a, cat.value, .{ .kind = .neoforge, .base_id = case[0], .loader_id = case[1] }, vanilla.value, .{
            .source_url = cat.value.entries[0].url,
            .profile = case[3],
            .version_json = case[4],
            .installer_sha1 = r.digest("fixture installer binding; real installer tested separately"),
        }, .{ .instance_name = "NeoAliases", .stage_root = "/stage", .environment = env });
        defer recipe.deinit();
        try std.testing.expectEqual(case[2], recipe.value.game_java_major);
        try std.testing.expectEqual(case[2], recipe.value.installer_java_major);
        try std.testing.expect(recipe.value.processors.len > 0);
        var generated: usize = 0;
        for (recipe.value.artifacts) |artifact| {
            if (artifact.producer) |producer| {
                try std.testing.expect(producer < recipe.value.processors.len);
                try std.testing.expect(artifact.url != null and artifact.url.?.len == 0);
                generated += 1;
            }
        }
        try std.testing.expect(generated > 0);
    }
}

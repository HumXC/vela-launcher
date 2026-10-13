const std = @import("std");
const m = @import("minecraft/metadata/root.zig");
const inheritance = @import("minecraft/metadata/inheritance.zig");
const install = @import("minecraft/install_plan.zig");
const launch = @import("minecraft/launch.zig");
const a = std.testing.allocator;
const root = "/game/shared runtime";
const options: launch.Options = .{
    .root = root,
    .java_executable = "/fake/java",
    .game_directory = "/game/instance with spaces",
    .identity = .{ .name = "Player $(literal)", .uuid = "1234", .access_token = "secret token" },
};
const vanilla_1201 = @embedFile("launch_fixtures/vanilla_1_20_1_version.json");
const vanilla_1211 = @embedFile("launch_fixtures/vanilla_1_21_1_version.json");
const forge_1201 = @embedFile("loaders/fixtures/forge_1_20_1_version.json");
const neo_1211 = @embedFile("launch_fixtures/neoforge_1_21_1_version.json");

fn count(argv: []const []const u8, token: []const u8) usize {
    var n: usize = 0;
    for (argv) |arg| if (std.mem.eql(u8, arg, token)) {
        n += 1;
    };
    return n;
}
fn index(argv: []const []const u8, token: []const u8) !usize {
    for (argv, 0..) |arg, i| if (std.mem.eql(u8, arg, token)) return i;
    return error.MissingArgument;
}
fn value(argv: []const []const u8, token: []const u8) ![]const u8 {
    const i = try index(argv, token);
    if (i + 1 == argv.len) return error.MissingArgumentValue;
    return argv[i + 1];
}
fn expectBoundary(argv: []const []const u8, version: m.version.Version, plan: install.Plan, os: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 1), count(argv, "-cp"));
    try std.testing.expectEqual(@as(usize, 0), count(argv, "-classpath"));
    try std.testing.expectEqual(@as(usize, 0), count(argv, "--class-path"));
    const cp = try std.mem.join(a, if (std.mem.eql(u8, os, "windows")) ";" else ":", plan.classpath);
    defer a.free(cp);
    try std.testing.expectEqualStrings(cp, try value(argv, "-cp"));
    const main = try index(argv, version.main_class.?);
    try std.testing.expect((try index(argv, "-cp")) < main);
    try std.testing.expect((try index(argv, "--username")) > main);
    try std.testing.expectEqualStrings(options.identity.name, try value(argv, "--username"));
    try std.testing.expectEqualStrings(options.identity.access_token, try value(argv, "--accessToken"));
    try std.testing.expectEqualStrings(options.game_directory.?, try value(argv, "--gameDir"));
    for (argv) |arg| try std.testing.expect(std.mem.indexOf(u8, arg, "${") == null);
    try std.testing.expect(std.mem.indexOf(u8, try value(argv, "-cp"), plan.client_path) != null);
}
fn expectModules(argv: []const []const u8, plan: install.Plan, os: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 1), count(argv, "--module-path"));
    try std.testing.expectEqual(@as(usize, 0), count(argv, "-p"));
    var modules = std.mem.splitScalar(u8, try value(argv, "--module-path"), if (std.mem.eql(u8, os, "windows")) ';' else ':');
    var n: usize = 0;
    while (modules.next()) |path| {
        try std.testing.expect(std.mem.startsWith(u8, path, root ++ "/libraries/"));
        try std.testing.expectEqual(@as(usize, 1), count(plan.classpath, path));
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 8), n);
    try std.testing.expectEqualStrings("ALL-MODULE-PATH", try value(argv, "--add-modules"));
    try std.testing.expectEqual(@as(usize, 2), count(argv, "--add-opens"));
    try std.testing.expectEqual(@as(usize, 2), count(argv, "--add-exports"));
    try std.testing.expectEqual(@as(usize, 1), count(argv, "-DlibraryDirectory=" ++ root ++ "/libraries"));
}

test "retained authentic vanilla metadata launches legacy and modern clients on target OS" {
    const profiles = [_][]const u8{
        @embedFile("launch_fixtures/vanilla_1_7_10_version.json"),
        @embedFile("launch_fixtures/vanilla_1_12_2_version.json"),
        vanilla_1201,
        vanilla_1211,
    };
    for (profiles) |bytes| {
        var parsed = try m.version.parseSlice(a, bytes);
        defer parsed.deinit();
        var resolved = try inheritance.resolve(a, parsed.value.id, &.{parsed.value}, .{});
        defer resolved.deinit();
        for ([_][]const u8{ "linux", "windows", "osx" }) |os| {
            const env: m.rules.Environment = .{ .os_name = os, .arch = "x86_64" };
            var planned = try install.build(a, resolved.value, .{ .objects = &.{}, .virtual = null, .map_to_resources = null }, env, .{ .root = root, .native_arch = .bits64, .cpu_arch = "x86_64" });
            defer planned.deinit();
            var result = try launch.build(a, resolved.value, planned.value, env, options);
            defer result.deinit();
            try expectBoundary(result.value.argv, resolved.value, planned.value, os);
            const expected_client = try std.fmt.allocPrint(a, "{s}/versions/{s}/{s}.jar", .{ root, parsed.value.id, parsed.value.id });
            defer a.free(expected_client);
            try std.testing.expectEqualStrings(expected_client, planned.value.client_path);
            if (std.mem.eql(u8, os, "osx")) try std.testing.expectEqual(@as(usize, 1), count(result.value.argv, "-XstartOnFirstThread"));
        }
    }
}

test "retained authentic Forge Fabric Quilt NeoForge metadata goes through inheritance plan and launch build" {
    const Profile = struct { base: []const u8, loader: []const u8, main: []const u8, modules: bool };
    const profiles = [_]Profile{
        .{ .base = vanilla_1201, .loader = forge_1201, .main = "cpw.mods.bootstraplauncher.BootstrapLauncher", .modules = true },
        .{ .base = vanilla_1201, .loader = @embedFile("launch_fixtures/fabric_1_20_1_version.json"), .main = "net.fabricmc.loader.impl.launch.knot.KnotClient", .modules = false },
        .{ .base = vanilla_1201, .loader = @embedFile("launch_fixtures/quilt_1_20_1_version.json"), .main = "org.quiltmc.loader.impl.launch.knot.KnotClient", .modules = false },
        .{ .base = vanilla_1211, .loader = neo_1211, .main = "cpw.mods.bootstraplauncher.BootstrapLauncher", .modules = true },
    };
    for (profiles) |profile| {
        var base = try m.version.parseSlice(a, profile.base);
        defer base.deinit();
        var loader = try m.version.parseSlice(a, profile.loader);
        defer loader.deinit();
        var resolved = try inheritance.resolve(a, loader.value.id, &.{ base.value, loader.value }, .{});
        defer resolved.deinit();
        try std.testing.expectEqualStrings(profile.main, resolved.value.main_class.?);
        try std.testing.expectEqualStrings(base.value.id, resolved.value.jar.?);
        for ([_][]const u8{ "linux", "windows" }) |os| {
            const env: m.rules.Environment = .{ .os_name = os, .arch = "x86_64" };
            var planned = try install.build(a, resolved.value, .{ .objects = &.{}, .virtual = null, .map_to_resources = null }, env, .{ .root = root, .native_arch = .bits64, .cpu_arch = "x86_64" });
            defer planned.deinit();
            var result = try launch.build(a, resolved.value, planned.value, env, options);
            defer result.deinit();
            const argv = result.value.argv;
            try expectBoundary(argv, resolved.value, planned.value, os);
            try std.testing.expectEqual(@as(usize, 1), count(argv, "-Dminecraft.launcher.brand=vela"));
            if (profile.modules) {
                try expectModules(argv, planned.value, os);
                try std.testing.expectEqualStrings("forgeclient", try value(argv, "--launchTarget"));
                try std.testing.expectEqualStrings(base.value.id, try value(argv, "--fml.mcVersion"));
                if (std.mem.eql(u8, base.value.id, "1.20.1")) {
                    try std.testing.expectEqualStrings("47.2.0", try value(argv, "--fml.forgeVersion"));
                    try std.testing.expectEqualStrings("net.minecraftforge", try value(argv, "--fml.forgeGroup"));
                    try std.testing.expectEqualStrings("20230612.114412", try value(argv, "--fml.mcpVersion"));
                } else {
                    try std.testing.expectEqualStrings("21.1.1", try value(argv, "--fml.neoForgeVersion"));
                    try std.testing.expectEqualStrings("4.0.24", try value(argv, "--fml.fmlVersion"));
                    try std.testing.expectEqualStrings("20240808.144430", try value(argv, "--fml.neoFormVersion"));
                }
            } else if (std.mem.eql(u8, profile.main, "net.fabricmc.loader.impl.launch.knot.KnotClient")) {
                try std.testing.expectEqual(@as(usize, 1), count(argv, "-DFabricMcEmu= net.minecraft.client.main.Main "));
            }
        }
    }
}

test "retained authentic old Forge installer metadata preserves legacy tweak and inherited client" {
    const old_install = try std.json.parseFromSlice(std.json.Value, a, @embedFile("launch_fixtures/forge_1_7_10_install_profile.json"), .{});
    defer old_install.deinit();
    var old_forge = try m.version.parseValue(a, old_install.value.object.get("versionInfo").?);
    defer old_forge.deinit();
    var later_forge = try m.version.parseSlice(a, @embedFile("launch_fixtures/forge_1_12_2_version.json"));
    defer later_forge.deinit();
    const bases = [_][]const u8{ @embedFile("launch_fixtures/vanilla_1_7_10_version.json"), @embedFile("launch_fixtures/vanilla_1_12_2_version.json") };
    const tweaks = [_][]const u8{ "cpw.mods.fml.common.launcher.FMLTweaker", "net.minecraftforge.fml.common.launcher.FMLTweaker" };
    for ([_]m.version.Version{ old_forge.value, later_forge.value }, bases, tweaks) |loader, bytes, tweak| {
        var base = try m.version.parseSlice(a, bytes);
        defer base.deinit();
        var resolved = try inheritance.resolve(a, loader.id, &.{ base.value, loader }, .{});
        defer resolved.deinit();
        try std.testing.expectEqualStrings(base.value.id, resolved.value.jar.?);
        const env: m.rules.Environment = .{ .os_name = "linux", .arch = "amd64" };
        var base_plan = try install.build(a, base.value, .{ .objects = &.{}, .virtual = null, .map_to_resources = null }, env, .{ .root = root });
        defer base_plan.deinit();
        // Old installers embed the Forge runtime without a public artifact URL.
        // Supply its published runtime path to launch, leaving authentic metadata intact.
        const coordinate = try m.version.mavenCoordinate(loader.libraries.?[0].name);
        const runtime = try std.fmt.allocPrint(a, "{s}/libraries/net/minecraftforge/forge/{s}/forge-{s}-universal.jar", .{ root, coordinate.version, coordinate.version });
        defer a.free(runtime);
        var cp: std.ArrayList([]const u8) = .empty;
        defer cp.deinit(a);
        try cp.appendSlice(a, base_plan.value.classpath);
        try cp.appendSlice(a, &.{ runtime, root ++ "/libraries/net/minecraft/launchwrapper/1.12/launchwrapper-1.12.jar" });
        var plan = base_plan.value;
        plan.classpath = cp.items;
        var result = try launch.build(a, resolved.value, plan, env, options);
        defer result.deinit();
        try expectBoundary(result.value.argv, resolved.value, plan, "linux");
        try std.testing.expectEqualStrings("net.minecraft.launchwrapper.Launch", resolved.value.main_class.?);
        try std.testing.expectEqualStrings(tweak, try value(result.value.argv, "--tweakClass"));
        try std.testing.expectEqual(@as(usize, 1), count(result.value.argv, "--tweakClass"));
        try std.testing.expectEqual(@as(usize, if (std.mem.eql(u8, base.value.id, "1.12.2")) 1 else 0), count(result.value.argv, "--versionType"));
    }
}

test "inherited classpath module aliases and FML singleton options replace while module directives and tweaks accumulate" {
    var base = try m.version.parseSlice(a, "{\"id\":\"base\",\"mainClass\":\"Main\",\"downloads\":{\"client\":{\"url\":\"https://example.invalid/client.jar\"}},\"arguments\":{\"jvm\":[\"-cp\",\"${classpath}\",\"-p\",\"/modules/old\",\"--add-opens\",\"java.base/java.util=ALL-UNNAMED\",\"-Dexample=old\"],\"game\":[\"--launchTarget\",\"old\",\"--fml.mcVersion\",\"old\",\"--tweakClass\",\"First\"]}}");
    defer base.deinit();
    var child = try m.version.parseSlice(a, "{\"id\":\"child\",\"inheritsFrom\":\"base\",\"arguments\":{\"jvm\":[\"--class-path=/metadata/new.jar\",\"--module-path=/modules/new\",\"--add-opens\",\"java.base/java.lang=ALL-UNNAMED\",\"-Dexample=new\"],\"game\":[\"--launchTarget=new\",\"--fml.mcVersion=new\",\"--tweakClass\",\"Second\"]}}");
    defer child.deinit();
    var resolved = try inheritance.resolve(a, child.value.id, &.{ base.value, child.value }, .{});
    defer resolved.deinit();
    const plan: install.Plan = .{ .files = &.{}, .native_extractions = &.{}, .classpath = &.{"/client.jar"}, .client_path = "/client.jar" };
    var o = options;
    o.extra_jvm = &.{ "-classpath", "/override/classpath.jar", "-p", "/override/modules", "--add-exports", "java.base/sun.security.util=ALL-UNNAMED" };
    o.extra_game = &.{ "--launchTarget", "final", "--fml.mcVersion=final", "--tweakClass=Third" };
    var result = try launch.build(a, resolved.value, plan, .{ .os_name = "linux", .arch = "amd64" }, o);
    defer result.deinit();
    const argv = result.value.argv;
    try std.testing.expectEqualStrings("/override/classpath.jar", try value(argv, "-cp"));
    try std.testing.expectEqualStrings("/override/modules", try value(argv, "--module-path"));
    try std.testing.expectEqual(@as(usize, 1), count(argv, "-cp"));
    try std.testing.expectEqual(@as(usize, 1), count(argv, "--module-path"));
    try std.testing.expectEqual(@as(usize, 2), count(argv, "--add-opens"));
    try std.testing.expectEqual(@as(usize, 1), count(argv, "--add-exports"));
    try std.testing.expectEqual(@as(usize, 1), count(argv, "-Dexample=new"));
    try std.testing.expectEqual(@as(usize, 0), count(argv, "-Dexample=old"));
    try std.testing.expectEqualStrings("final", try value(argv, "--launchTarget"));
    try std.testing.expectEqualStrings("final", try value(argv, "--fml.mcVersion"));
    try std.testing.expectEqual(@as(usize, 1), count(argv, "--launchTarget"));
    try std.testing.expectEqual(@as(usize, 1), count(argv, "--fml.mcVersion"));
    try std.testing.expectEqual(@as(usize, 3), count(argv, "--tweakClass"));
    var seen: usize = 0;
    for (argv, 0..) |arg, i| if (std.mem.eql(u8, arg, "--tweakClass")) {
        try std.testing.expectEqualStrings(([_][]const u8{ "First", "Second", "Third" })[seen], argv[i + 1]);
        seen += 1;
    };
}

test "modern loader JVM overlay preserves legacy parent defaults and normalized game arguments" {
    var base = try m.version.parseSlice(a, @embedFile("launch_fixtures/vanilla_1_12_2_version.json"));
    defer base.deinit();
    var child = try m.version.parseSlice(a, "{\"id\":\"legacy-overlay\",\"inheritsFrom\":\"1.12.2\",\"mainClass\":\"net.minecraft.launchwrapper.Launch\",\"arguments\":{\"jvm\":[\"-Dloader=overlay\",\"--class-path\",\"${classpath}\",\"-Djava.library.path=/loader/native dir\"],\"game\":[\"--tweakClass\",\"LoaderTweaker\"]}}");
    defer child.deinit();
    var resolved = try inheritance.resolve(a, child.value.id, &.{ base.value, child.value }, .{});
    defer resolved.deinit();
    const env: m.rules.Environment = .{ .os_name = "windows", .arch = "x86_64" };
    var planned = try install.build(a, resolved.value, .{ .objects = &.{}, .virtual = null, .map_to_resources = null }, env, .{ .root = root, .native_arch = .bits64, .cpu_arch = "x86_64" });
    defer planned.deinit();
    var result = try launch.build(a, resolved.value, planned.value, env, options);
    defer result.deinit();
    try expectBoundary(result.value.argv, resolved.value, planned.value, "windows");
    try std.testing.expectEqual(@as(usize, 1), count(result.value.argv, "-Dloader=overlay"));
    try std.testing.expectEqual(@as(usize, 1), count(result.value.argv, "-Dminecraft.launcher.brand=vela"));
    try std.testing.expectEqual(@as(usize, 1), count(result.value.argv, "-Djava.library.path=/loader/native dir"));
    try std.testing.expectEqualStrings("LoaderTweaker", try value(result.value.argv, "--tweakClass"));
}

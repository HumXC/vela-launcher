const std = @import("std");
const launch = @import("minecraft/launch.zig");
const m = @import("minecraft/metadata/root.zig");
const install = @import("minecraft/install_plan.zig");
const fixture = "{\"id\":\"test\",\"type\":\"release\",\"mainClass\":\"game.Main\",\"assetIndex\":{\"id\":\"assets\",\"url\":\"https://example/index\"},\"arguments\":{\"jvm\":[\"-Djava.library.path=${natives_directory}\",\"-cp\",\"${classpath}\",\"-Xmx1G\"],\"game\":[\"--username\",\"${auth_player_name}\",\"--accessToken\",\"${auth_access_token}\",\"--gameDir\",\"${game_directory}\",{\"rules\":[],\"value\":[\"--demo\"]}]}}";
const plan: install.Plan = .{ .files = &.{}, .classpath = &.{ "/game/libs/a.jar", "/game/client.jar" }, .native_extractions = &.{}, .client_path = "/game/client.jar" };
const env: m.rules.Environment = .{ .os_name = "linux", .arch = "amd64" };
const options: launch.Options = .{ .root = "/game", .java_executable = "/fake/java", .identity = .{ .name = "Player With Space", .uuid = "1234" }, .min_memory_mb = 512, .max_memory_mb = 2048, .extra_jvm = &.{"-Xmx3G"}, .extra_game = &.{ "--username=Override Name", "--width", "800" } };
fn find(argv: []const []const u8, value: []const u8) ?usize {
    for (argv, 0..) |token, i| if (std.mem.eql(u8, token, value)) return i;
    return null;
}
test "launch argv owns data and preserves JVM main game boundaries with overriding" {
    const a = std.testing.allocator;
    var result: m.Owned(launch.Launch) = undefined;
    {
        var version = try m.version.parseSlice(a, fixture);
        defer version.deinit();
        result = try launch.build(a, version.value, plan, env, options);
    }
    defer result.deinit();
    const argv = result.value.argv;
    try std.testing.expectEqualStrings("/fake/java", argv[0]);
    try std.testing.expectEqualStrings("/game", result.value.cwd);
    const main = find(argv, "game.Main").?;
    try std.testing.expect(find(argv, "-Xms512M").? < main);
    try std.testing.expect(find(argv, "-Xmx3G").? < main);
    try std.testing.expect(find(argv, "--username").? > main);
    try std.testing.expectEqualStrings("Override Name", argv[find(argv, "--username").? + 1]);
    try std.testing.expectEqualStrings("0", argv[find(argv, "--accessToken").? + 1]);
    try std.testing.expectEqualStrings("/game/libs/a.jar:/game/client.jar", argv[find(argv, "-cp").? + 1]);
    try std.testing.expect(find(argv, "-Djava.library.path=/game/versions/test/natives") != null);
    try std.testing.expect(find(argv, "--demo") == null);
    try std.testing.expect(find(argv, "-Xmx1G") == null);
}
test "optional minimum heap emits actual argv and extra JVM heap values keep override precedence" {
    const a = std.testing.allocator;
    var version = try m.version.parseSlice(a, fixture);
    defer version.deinit();
    var o = options;
    o.min_memory_mb = null;
    o.extra_jvm = &.{};
    var default_minimum = try launch.build(a, version.value, plan, env, o);
    defer default_minimum.deinit();
    for (default_minimum.value.argv) |token| try std.testing.expect(!std.mem.startsWith(u8, token, "-Xms"));
    try std.testing.expect(find(default_minimum.value.argv, "-Xmx2048M") != null);
    o.min_memory_mb = 1024;
    o.max_memory_mb = 4096;
    var bounded = try launch.build(a, version.value, plan, env, o);
    defer bounded.deinit();
    try std.testing.expect(find(bounded.value.argv, "-Xms1024M").? < find(bounded.value.argv, "game.Main").?);
    try std.testing.expect(find(bounded.value.argv, "-Xmx4096M").? < find(bounded.value.argv, "game.Main").?);
    try std.testing.expect(find(bounded.value.argv, "-Xmx1G") == null);
    o.extra_jvm = &.{ "-Xms2G", "-Xmx8G" };
    var overridden = try launch.build(a, version.value, plan, env, o);
    defer overridden.deinit();
    try std.testing.expect(find(overridden.value.argv, "-Xms2G").? < find(overridden.value.argv, "game.Main").?);
    try std.testing.expect(find(overridden.value.argv, "-Xmx8G").? < find(overridden.value.argv, "game.Main").?);
    try std.testing.expect(find(overridden.value.argv, "-Xms1024M") == null);
    try std.testing.expect(find(overridden.value.argv, "-Xmx4096M") == null);
}

test "configured minimum heap replaces metadata minimum and extra JVM replaces the configured value" {
    const a = std.testing.allocator;
    var version = try m.version.parseSlice(
        a,
        "{\"id\":\"test\",\"type\":\"release\",\"mainClass\":\"game.Main\",\"assetIndex\":{\"id\":\"assets\",\"url\":\"https://example/index\"},\"arguments\":{\"jvm\":[\"-Xms256M\",\"-cp\",\"${classpath}\"],\"game\":[]}}",
    );
    defer version.deinit();
    var o = options;
    o.extra_jvm = &.{};
    var configured = try launch.build(a, version.value, plan, env, o);
    defer configured.deinit();
    try std.testing.expect(find(configured.value.argv, "-Xms512M") != null);
    try std.testing.expect(find(configured.value.argv, "-Xms256M") == null);
    var count: usize = 0;
    for (configured.value.argv) |token| {
        if (std.mem.startsWith(u8, token, "-Xms")) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    o.extra_jvm = &.{"-Xms1G"};
    var overridden = try launch.build(a, version.value, plan, env, o);
    defer overridden.deinit();
    try std.testing.expect(find(overridden.value.argv, "-Xms1G") != null);
    try std.testing.expect(find(overridden.value.argv, "-Xms512M") == null);
    try std.testing.expect(find(overridden.value.argv, "-Xms256M") == null);
    count = 0;
    for (overridden.value.argv) |token| {
        if (std.mem.startsWith(u8, token, "-Xms")) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "launch rejects zero minimum heap and minimum above explicit maximum" {
    const a = std.testing.allocator;
    var version = try m.version.parseSlice(a, fixture);
    defer version.deinit();
    var o = options;
    o.min_memory_mb = 0;
    try std.testing.expectError(error.InvalidMemory, launch.build(a, version.value, plan, env, o));
    o.min_memory_mb = 2049;
    try std.testing.expectError(error.InvalidMemory, launch.build(a, version.value, plan, env, o));
    o.min_memory_mb = 2048;
    var equal = try launch.build(a, version.value, plan, env, o);
    defer equal.deinit();
    try std.testing.expect(find(equal.value.argv, "-Xms2048M") != null);
    o.min_memory_mb = 512;
    o.max_memory_mb = null;
    var implicit_maximum = try launch.build(a, version.value, plan, env, o);
    defer implicit_maximum.deinit();
    try std.testing.expect(find(implicit_maximum.value.argv, "-Xms512M") != null);
}

test "launch rejects missing substitutions relative plans and JVM entry point injection" {
    const a = std.testing.allocator;
    var version = try m.version.parseSlice(a, fixture);
    defer version.deinit();
    var o = options;
    o.extra_game = &.{"${unknown}"};
    try std.testing.expectError(error.UnknownPlaceholder, launch.build(a, version.value, plan, env, o));
    o = options;
    o.extra_jvm = &.{ "-jar", "evil.jar" };
    try std.testing.expectError(error.InvalidJvmToken, launch.build(a, version.value, plan, env, o));
    o.extra_jvm = &.{"evil.Main"};
    try std.testing.expectError(error.InvalidJvmToken, launch.build(a, version.value, plan, env, o));
    o = options;
    o.root = ".minecraft";
    try std.testing.expectError(error.AbsoluteRootRequired, launch.build(a, version.value, plan, env, o));
    version.value.arguments = null;
    try std.testing.expectError(error.UnsupportedLegacyArguments, launch.build(a, version.value, plan, env, options));
}
fn allocationCase(a: std.mem.Allocator) !void {
    var version = try m.version.parseSlice(a, fixture);
    defer version.deinit();
    var result = try launch.build(a, version.value, plan, env, options);
    defer result.deinit();
}
test "launch allocation failures clean up" {
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
test "logging resolution and quick play expand without splitting spaced values" {
    const a = std.testing.allocator;
    var version = try m.version.parseSlice(a, fixture);
    defer version.deinit();
    version.value.logging = &.{.{ .name = "client", .argument = "-Dlog.config=$" ++ "{path}", .kind = "log4j2-xml", .file = .{ .id = "log.xml", .url = "https://example/log", .sha1 = null, .size = null } }};
    var p = plan;
    p.files = &.{.{ .kind = .logging, .url = "https://example/log", .path = "/game/log file.xml", .sha1 = null, .size = null }};
    var o = options;
    o.resolution_width = 1280;
    o.resolution_height = 720;
    o.quick_play_singleplayer = "My World";
    o.extra_game = &.{ "--quickPlaySingleplayer", "$" ++ "{quickPlaySingleplayer}" };
    var result = try launch.build(a, version.value, p, env, o);
    defer result.deinit();
    const argv = result.value.argv;
    try std.testing.expect(find(argv, "-Dlog.config=/game/log file.xml") != null);
    try std.testing.expectEqualStrings("1280", argv[find(argv, "--width").? + 1]);
    try std.testing.expectEqualStrings("720", argv[find(argv, "--height").? + 1]);
    try std.testing.expectEqualStrings("My World", argv[find(argv, "--quickPlaySingleplayer").? + 1]);
}

test {
    _ = @import("launch_loader_test.zig");
}

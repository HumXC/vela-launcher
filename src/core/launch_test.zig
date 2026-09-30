const std = @import("std");
const launch = @import("minecraft/launch.zig");
const m = @import("minecraft/metadata/root.zig");
const install = @import("minecraft/install_plan.zig");
const fixture = "{\"id\":\"test\",\"type\":\"release\",\"mainClass\":\"game.Main\",\"assetIndex\":{\"id\":\"assets\",\"url\":\"https://example/index\"},\"arguments\":{\"jvm\":[\"-Djava.library.path=${natives_directory}\",\"-cp\",\"${classpath}\",\"-Xmx1G\"],\"game\":[\"--username\",\"${auth_player_name}\",\"--accessToken\",\"${auth_access_token}\",\"--gameDir\",\"${game_directory}\",{\"rules\":[],\"value\":[\"--demo\"]}]}}";
const plan: install.Plan = .{ .files = &.{}, .classpath = &.{ "/game/libs/a.jar", "/game/client.jar" }, .native_extractions = &.{}, .client_path = "/game/client.jar" };
const env: m.rules.Environment = .{ .os_name = "linux", .arch = "amd64" };
const options: launch.Options = .{ .root = "/game", .java_executable = "/fake/java", .identity = .{ .name = "Player With Space", .uuid = "1234" }, .max_memory_mb = 2048, .extra_jvm = &.{"-Xmx3G"}, .extra_game = &.{ "--username=Override Name", "--width", "800" } };
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
    try std.testing.expect(find(argv, "-Xmx3G").? < main);
    try std.testing.expect(find(argv, "--username").? > main);
    try std.testing.expectEqualStrings("Override Name", argv[find(argv, "--username").? + 1]);
    try std.testing.expectEqualStrings("0", argv[find(argv, "--accessToken").? + 1]);
    try std.testing.expectEqualStrings("/game/libs/a.jar:/game/client.jar", argv[find(argv, "-cp").? + 1]);
    try std.testing.expect(find(argv, "-Djava.library.path=/game/versions/test/natives") != null);
    try std.testing.expect(find(argv, "--demo") == null);
    try std.testing.expect(find(argv, "-Xmx1G") == null);
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
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
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

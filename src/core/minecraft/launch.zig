//! Pure modern/legacy launch preparation. Execution and Java discovery belong to caller.
const std = @import("std");
const m = @import("metadata/root.zig");
const install = @import("install_plan.zig");
const command = @import("../command.zig");
const java = @import("../java_arguments.zig");
pub const Identity = struct {
    name: []const u8,
    uuid: []const u8,
    /// "0" explicitly denotes offline identity; this module performs no authentication.
    access_token: []const u8 = "0",
    user_type: []const u8 = "legacy",
    client_id: []const u8 = "",
    xuid: []const u8 = "",
    user_properties: []const u8 = "{}",
};
pub const Options = struct {
    root: []const u8,
    java_executable: []const u8,
    identity: Identity,
    min_memory_mb: ?u32 = null,
    max_memory_mb: ?u32 = null,
    extra_jvm: []const []const u8 = &.{},
    extra_game: []const []const u8 = &.{},
    natives_directory: ?[]const u8 = null,
    game_directory: ?[]const u8 = null,
    game_assets: ?[]const u8 = null,
    launcher_name: []const u8 = "vela",
    launcher_version: []const u8 = "dev",
    resolution_width: ?u32 = null,
    resolution_height: ?u32 = null,
    quick_play_path: ?[]const u8 = null,
    quick_play_singleplayer: ?[]const u8 = null,
    quick_play_multiplayer: ?[]const u8 = null,
    quick_play_realms: ?[]const u8 = null,
};
pub const Launch = struct { argv: []const []const u8, cwd: []const u8 };

/// Plan paths and root must be absolute: changing child cwd must not reinterpret them.
/// Returned argv contains credentials; do not print it in normal logs.
pub fn build(allocator: std.mem.Allocator, version: m.version.Version, plan: install.Plan, env: m.rules.Environment, options: Options) !m.Owned(Launch) {
    if (version.inherits_from != null) return error.UnresolvedInheritance;
    const arguments = version.arguments orelse m.version.Arguments{ .game = null, .jvm = null };
    if (version.arguments == null and version.minecraft_arguments == null) return error.UnsupportedLegacyArguments;
    const main = version.main_class orelse return error.MissingMainClass;
    if (main.len == 0 or main[0] == '-' or main[0] == '@') return error.InvalidMainClass;
    if (!std.fs.path.isAbsolute(options.root)) return error.AbsoluteRootRequired;
    if (std.mem.indexOfScalar(u8, options.root, 0) != null) return error.EmbeddedNul;
    if (options.identity.name.len == 0 or options.identity.uuid.len == 0) return error.InvalidIdentity;
    if ((options.resolution_width == null) != (options.resolution_height == null)) return error.IncompleteResolution;
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const a = arena.allocator();
    for (plan.classpath) |path| if (!std.fs.path.isAbsolute(path)) return error.AbsolutePlanPathRequired;
    if (plan.classpath.len == 0) return error.EmptyClasspath;
    const separator = if (std.mem.eql(u8, env.os_name, "windows")) ";" else ":";
    const cp = try std.mem.join(a, separator, plan.classpath);
    const natives = options.natives_directory orelse if (plan.native_extractions.len != 0) plan.native_extractions[0].destination else try std.fs.path.join(a, &.{ options.root, "versions", version.id, "natives" });
    if (!std.fs.path.isAbsolute(natives)) return error.AbsoluteNativePathRequired;
    for (plan.native_extractions) |extraction| if (!std.mem.eql(u8, extraction.destination, natives)) return error.NativeDirectoryMismatch;
    const game_directory = options.game_directory orelse options.root;
    if (!std.fs.path.isAbsolute(game_directory)) return error.AbsoluteGamePathRequired;
    try tokenValid(game_directory);
    const game_assets = options.game_assets orelse plan.game_assets_directory orelse try std.fs.path.join(a, &.{ options.root, "assets" });
    if (!std.fs.path.isAbsolute(game_assets)) return error.AbsoluteAssetPathRequired;
    try tokenValid(game_assets);
    for (plan.native_checks) |check| if (check.suitability == .incompatible) return error.IncompatibleNativeArchitecture;
    var context: Context = .{ .a = a, .version = version, .options = options, .classpath = cp, .classpath_separator = separator, .natives = natives, .game_assets = game_assets };
    var jvm = try command.Builder.init(a, options.java_executable);
    defer jvm.deinit();
    // A loader JVM overlay on a legacy parent still needs its launcher defaults.
    // Keyed JVM options let the overlay replace defaults without a second classpath.
    const jvm_tokens = if (arguments.jvm) |args| try context.arguments(args, env) else &.{};
    try validateJvm(jvm_tokens);
    if (arguments.jvm == null or version.minecraft_arguments != null) {
        const defaults = try context.expandMany(if (std.mem.eql(u8, env.os_name, "osx")) &.{ "-XstartOnFirstThread", "-Djava.library.path=${natives_directory}", "-Dminecraft.launcher.brand=${launcher_name}", "-Dminecraft.launcher.version=${launcher_version}", "-cp", "${classpath}" } else &.{ "-Djava.library.path=${natives_directory}", "-Dminecraft.launcher.brand=${launcher_name}", "-Dminecraft.launcher.version=${launcher_version}", "-cp", "${classpath}" });
        try appendJvm(&jvm, defaults);
    }
    try appendJvm(&jvm, jvm_tokens);
    // Ensure classpath exists even for minimal metadata, preserving explicit metadata setting.
    if (!jvm.has(.{ .namespace = "java.option", .name = "classpath" })) try java.append(&jvm, &.{ "-cp", cp });
    for (version.logging) |logging| {
        if (!std.mem.eql(u8, logging.name, "client")) continue;
        var file_path: ?[]const u8 = null;
        for (plan.files) |file| if (file.kind == .logging) {
            file_path = file.path;
            break;
        };
        const path = file_path orelse return error.MissingLoggingFile;
        if (!std.fs.path.isAbsolute(path)) return error.AbsolutePlanPathRequired;
        context.logging_path = path;
        const token = try context.expand(logging.argument);
        try validateJvm(&.{token});
        try java.append(&jvm, &.{token});
        context.logging_path = null;
    }
    if (options.min_memory_mb) |mb| {
        if (mb == 0) return error.InvalidMemory;
        if (options.max_memory_mb) |maximum| if (mb > maximum) return error.InvalidMemory;
        try java.append(&jvm, &.{try std.fmt.allocPrint(a, "-Xms{d}M", .{mb})});
    }
    if (options.max_memory_mb) |mb| {
        if (mb == 0) return error.InvalidMemory;
        try java.append(&jvm, &.{try std.fmt.allocPrint(a, "-Xmx{d}M", .{mb})});
    }
    const extra_jvm = try context.expandMany(options.extra_jvm);
    try validateJvm(extra_jvm);
    try appendJvm(&jvm, extra_jvm);
    var game = try command.Builder.init(a, "game");
    defer game.deinit();
    const game_tokens = if (arguments.game) |args| try context.arguments(args, env) else try context.expandMany(try m.version.tokenizeLegacy(a, version.minecraft_arguments orelse return error.MissingGameArguments));
    try appendGame(&game, game_tokens);
    if (options.resolution_width) |width| {
        if (width == 0 or options.resolution_height.? == 0) return error.InvalidResolution;
        try appendGame(&game, &.{ "--width", try std.fmt.allocPrint(a, "{d}", .{width}), "--height", try std.fmt.allocPrint(a, "{d}", .{options.resolution_height.?}) });
    }
    try appendGame(&game, try context.expandMany(options.extra_game));
    const jvm_argv = try jvm.render(a);
    const game_argv = try game.render(a);
    const out = try a.alloc([]const u8, jvm_argv.len + game_argv.len);
    for (jvm_argv, 0..) |token, i| out[i] = try a.dupe(u8, token);
    try tokenValid(main);
    out[jvm_argv.len] = try a.dupe(u8, main);
    for (game_argv[1..], jvm_argv.len + 1..) |token, i| out[i] = try a.dupe(u8, token);
    return .{ .value = .{ .argv = out, .cwd = try a.dupe(u8, game_directory) }, .arena = arena, .backing = allocator };
}
const Context = struct {
    a: std.mem.Allocator,
    version: m.version.Version,
    options: Options,
    classpath: []const u8,
    classpath_separator: []const u8,
    natives: []const u8,
    game_assets: []const u8,
    logging_path: ?[]const u8 = null,
    fn arguments(self: *Context, source: []const m.version.Argument, env: m.rules.Environment) ![]const []const u8 {
        var tokens: std.ArrayList([]const u8) = .empty;
        for (source) |arg| switch (arg) {
            .literal => |v| try tokens.append(self.a, try self.expand(v)),
            .conditional => |conditional| if (try m.rules.allows(conditional.rules, env)) {
                for (conditional.values) |v| try tokens.append(self.a, try self.expand(v));
            },
        };
        return tokens.toOwnedSlice(self.a);
    }
    fn expandMany(self: *Context, source: []const []const u8) ![]const []const u8 {
        const out = try self.a.alloc([]const u8, source.len);
        for (source, out) |v, *item| item.* = try self.expand(v);
        return out;
    }
    fn expand(self: *Context, source: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var rest = source;
        while (std.mem.indexOf(u8, rest, "$" ++ "{")) |start| {
            try out.appendSlice(self.a, rest[0..start]);
            const end = std.mem.indexOfScalarPos(u8, rest, start + 2, '}') orelse return error.UnclosedPlaceholder;
            try out.appendSlice(self.a, try self.lookup(rest[start + 2 .. end]));
            rest = rest[end + 1 ..];
        }
        try out.appendSlice(self.a, rest);
        try tokenValid(out.items);
        return out.toOwnedSlice(self.a);
    }
    fn lookup(self: *Context, name: []const u8) ![]const u8 {
        const o = self.options;
        const values = .{
            .{ "classpath", self.classpath },                      .{ "natives_directory", self.natives },
            .{ "launcher_name", o.launcher_name },                 .{ "launcher_version", o.launcher_version },
            .{ "auth_player_name", o.identity.name },              .{ "auth_uuid", o.identity.uuid },
            .{ "auth_access_token", o.identity.access_token },     .{ "user_type", o.identity.user_type },
            .{ "version_name", self.version.id },                  .{ "version_type", self.version.kind orelse "release" },
            .{ "game_directory", o.game_directory orelse o.root }, .{ "clientid", o.identity.client_id },
            .{ "auth_xuid", o.identity.xuid },                     .{ "user_properties", o.identity.user_properties },
        };
        inline for (values) |pair| if (std.mem.eql(u8, name, pair[0])) return pair[1];
        if (std.mem.eql(u8, name, "game_assets")) return self.game_assets;
        if (std.mem.eql(u8, name, "classpath_separator")) return self.classpath_separator;
        if (std.mem.eql(u8, name, "library_directory")) return std.fs.path.join(self.a, &.{ o.root, "libraries" });
        if (std.mem.eql(u8, name, "assets_root")) return std.fs.path.join(self.a, &.{ o.root, "assets" });
        if (std.mem.eql(u8, name, "assets_index_name")) return (self.version.asset_index orelse return error.MissingAssetIndex).id;
        if (std.mem.eql(u8, name, "resolution_width")) return std.fmt.allocPrint(self.a, "{d}", .{o.resolution_width orelse return error.MissingResolution});
        if (std.mem.eql(u8, name, "resolution_height")) return std.fmt.allocPrint(self.a, "{d}", .{o.resolution_height orelse return error.MissingResolution});
        if (std.mem.eql(u8, name, "path")) return self.logging_path orelse return error.UnknownPlaceholder;
        if (std.mem.eql(u8, name, "auth_session")) return std.fmt.allocPrint(self.a, "token:{s}:{s}", .{ o.identity.access_token, o.identity.uuid });
        if (std.mem.eql(u8, name, "quickPlayPath")) return o.quick_play_path orelse return error.MissingQuickPlayValue;
        if (std.mem.eql(u8, name, "quickPlaySingleplayer")) return o.quick_play_singleplayer orelse return error.MissingQuickPlayValue;
        if (std.mem.eql(u8, name, "quickPlayMultiplayer")) return o.quick_play_multiplayer orelse return error.MissingQuickPlayValue;
        if (std.mem.eql(u8, name, "quickPlayRealms")) return o.quick_play_realms orelse return error.MissingQuickPlayValue;
        return error.UnknownPlaceholder;
    }
};
fn tokenValid(token: []const u8) !void {
    if (std.mem.indexOfScalar(u8, token, 0) != null) return error.EmbeddedNul;
}
// Java uses one module path (the final alias wins), independently of the classpath.
// Keep repeatable module directives intact; java.append owns the other JVM keys.
fn appendJvm(builder: *command.Builder, tokens: []const []const u8) !void {
    var i: usize = 0;
    var start: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];
        const end = std.mem.indexOfScalar(u8, token, '=') orelse token.len;
        const name = token[0..end];
        const canonical: ?[]const u8 = if (std.mem.eql(u8, name, "-p") or std.mem.eql(u8, name, "--module-path")) "--module-path" else if (std.mem.eql(u8, name, "--upgrade-module-path")) "--upgrade-module-path" else if (std.mem.eql(u8, name, "--limit-modules")) "--limit-modules" else null;
        if (canonical) |option| {
            try java.append(builder, tokens[start..i]);
            const value = if (end < token.len) token[end + 1 ..] else blk: {
                i += 1;
                if (i == tokens.len) return error.MissingValue;
                break :blk tokens[i];
            };
            try builder.add(.{ .key = .{ .namespace = "java.option", .name = option }, .canonical = option, .arity = .value }, value);
            start = i + 1;
        } else {
            // An operand may itself look like a module-path option. Skip it.
            for ([_][]const u8{ "-cp", "-classpath", "--class-path", "--add-modules", "--add-reads", "--add-exports", "--add-opens", "--patch-module", "--enable-native-access", "--source" }) |option| {
                if (std.mem.eql(u8, token, option)) {
                    i += 1;
                    if (i == tokens.len) return error.MissingValue;
                    break;
                }
            }
        }
    }
    try java.append(builder, tokens[start..]);
}
fn validateJvm(tokens: []const []const u8) !void {
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];
        if (token.len < 2 or token[0] != '-' or std.mem.eql(u8, token, "--")) return error.InvalidJvmToken;
        if (std.mem.eql(u8, token, "-jar") or std.mem.eql(u8, token, "-m") or std.mem.eql(u8, token, "--module") or std.mem.startsWith(u8, token, "--module=")) return error.InvalidJvmToken;
        for ([_][]const u8{ "-cp", "-classpath", "--class-path", "-p", "--module-path", "--upgrade-module-path", "--add-modules", "--limit-modules", "--add-reads", "--add-exports", "--add-opens", "--patch-module", "--enable-native-access", "--source" }) |name| {
            if (std.mem.eql(u8, token, name)) {
                i += 1;
                if (i == tokens.len) return error.MissingValue;
                break;
            }
        }
    }
}
fn appendGame(builder: *command.Builder, tokens: []const []const u8) !void {
    const valued = [_][]const u8{ "--username", "--version", "--gameDir", "--assetsDir", "--assetIndex", "--uuid", "--accessToken", "--clientId", "--xuid", "--userType", "--versionType", "--userProperties", "--profileProperties", "--session", "--width", "--height", "--server", "--port", "--quickPlayPath", "--quickPlaySingleplayer", "--quickPlayMultiplayer", "--quickPlayRealms", "--launchTarget", "--fml.forgeVersion", "--fml.mcVersion", "--fml.forgeGroup", "--fml.mcpVersion", "--fml.neoForgeVersion", "--fml.fmlVersion", "--fml.neoFormVersion", "--tweakClass" };
    const flags = [_][]const u8{ "--demo", "--fullscreen", "--disableMultiplayer", "--disableChat" };
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];
        const end = std.mem.indexOfScalar(u8, token, '=') orelse token.len;
        var recognized = false;
        for (valued) |name| if (std.mem.eql(u8, token[0..end], name)) {
            const value = if (end < token.len) token[end + 1 ..] else blk: {
                i += 1;
                if (i == tokens.len) return error.MissingGameValue;
                break :blk tokens[i];
            };
            try builder.add(.{ .key = .{ .namespace = "game", .name = name }, .canonical = name, .arity = .value, .merge = if (std.mem.eql(u8, name, "--tweakClass")) .append else .replace }, value);
            recognized = true;
            break;
        };
        if (recognized) continue;
        for (flags) |name| if (std.mem.eql(u8, token, name)) {
            try builder.add(.{ .key = .{ .namespace = "game", .name = name }, .canonical = name, .arity = .flag, .layout = .flag }, null);
            recognized = true;
            break;
        };
        if (!recognized) try builder.addRaw(token);
    }
}

const legacy_launch_fixture = "{\"id\":\"1.7.10-forge\",\"mainClass\":\"net.minecraft.launchwrapper.Launch\",\"minecraftArguments\":\"--username ${auth_player_name} --version ${version_name} --gameDir ${game_directory} --assetsDir ${game_assets} --accessToken ${auth_access_token} --session ${auth_session} --userProperties ${user_properties} --tweakClass first --tweakClass second \\\"literal quoted value\\\"\",\"assetIndex\":{\"id\":\"legacy\",\"url\":\"https://example/index\"}}";
const legacy_launch_plan: install.Plan = .{
    .files = &.{},
    .native_extractions = &.{},
    .classpath = &.{ "/game/libraries/launchwrapper.jar", "/game/versions/1.7.10/1.7.10.jar" },
    .client_path = "/game/versions/1.7.10/1.7.10.jar",
    .game_assets_directory = "/game/assets/virtual/legacy",
};
const legacy_launch_options: Options = .{
    .root = "/game",
    .java_executable = "/fake/java",
    .game_directory = "/game/versions/My Forge",
    .natives_directory = "/game/versions/My Forge/natives",
    .identity = .{ .name = "Offline Player $(no-shell)", .uuid = "0123456789abcdef0123456789abcdef", .user_properties = "{\"skin\":[\"a b\"]}" },
};
fn legacyLaunchAllocationCase(a: std.mem.Allocator) !void {
    var version = try m.version.parseSlice(a, legacy_launch_fixture);
    defer version.deinit();
    var launched = try build(a, version.value, legacy_launch_plan, .{ .os_name = "linux", .arch = "x86_64" }, legacy_launch_options);
    defer launched.deinit();
    try std.testing.expectEqualStrings("/game/versions/My Forge", launched.value.cwd);
}
fn argvIndex(argv: []const []const u8, token: []const u8) ?usize {
    for (argv, 0..) |item, i| if (std.mem.eql(u8, item, token)) return i;
    return null;
}
test "legacy launch preserves Forge tweaks and substitutes without retokenizing" {
    const a = std.testing.allocator;
    try @import("test_allocations").checkAllAllocationFailures(a, legacyLaunchAllocationCase, .{});
    var version = try m.version.parseSlice(a, legacy_launch_fixture);
    defer version.deinit();
    var launched = try build(a, version.value, legacy_launch_plan, .{ .os_name = "linux", .arch = "x86_64" }, legacy_launch_options);
    defer launched.deinit();
    const argv = launched.value.argv;
    const main = argvIndex(argv, "net.minecraft.launchwrapper.Launch").?;
    const cp = argvIndex(argv, "-cp").?;
    try std.testing.expect(cp < main);
    try std.testing.expectEqualStrings("/game/libraries/launchwrapper.jar:/game/versions/1.7.10/1.7.10.jar", argv[cp + 1]);
    try std.testing.expect(argvIndex(argv, "-Djava.library.path=/game/versions/My Forge/natives") != null);
    try std.testing.expectEqualStrings(legacy_launch_options.identity.name, argv[argvIndex(argv, "--username").? + 1]);
    try std.testing.expectEqualStrings("/game/assets/virtual/legacy", argv[argvIndex(argv, "--assetsDir").? + 1]);
    try std.testing.expectEqualStrings("token:0:0123456789abcdef0123456789abcdef", argv[argvIndex(argv, "--session").? + 1]);
    try std.testing.expectEqualStrings(legacy_launch_options.identity.user_properties, argv[argvIndex(argv, "--userProperties").? + 1]);
    const tweaks = argvIndex(argv, "--tweakClass").?;
    try std.testing.expectEqualStrings("first", argv[tweaks + 1]);
    try std.testing.expectEqualStrings("--tweakClass", argv[tweaks + 2]);
    try std.testing.expectEqualStrings("second", argv[tweaks + 3]);
    try std.testing.expectEqualStrings("literal quoted value", argv[tweaks + 4]);
    try std.testing.expectEqual(@as(u64, 8), m.version.requiredJavaMajor(version.value));
    var mac = try build(a, version.value, legacy_launch_plan, .{ .os_name = "osx", .arch = "aarch64" }, legacy_launch_options);
    defer mac.deinit();
    try std.testing.expect(argvIndex(mac.value.argv, "-XstartOnFirstThread").? < argvIndex(mac.value.argv, "net.minecraft.launchwrapper.Launch").?);
    var checked = legacy_launch_plan;
    checked.native_checks = &.{.{ .archive_path = "/game/custom.jar", .classifier = "natives-osx", .suitability = .inspection_required }};
    var pending = try build(a, version.value, checked, .{ .os_name = "osx", .arch = "aarch64" }, legacy_launch_options);
    defer pending.deinit();
    checked.native_checks = &.{.{ .archive_path = "/game/custom.jar", .classifier = "natives-osx", .suitability = .incompatible }};
    try std.testing.expectError(error.IncompatibleNativeArchitecture, build(a, version.value, checked, .{ .os_name = "osx", .arch = "aarch64" }, legacy_launch_options));
}

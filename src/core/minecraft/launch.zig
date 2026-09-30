//! Pure modern-vanilla launch preparation. Execution and Java discovery belong to caller.
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
    max_memory_mb: ?u32 = null,
    extra_jvm: []const []const u8 = &.{},
    extra_game: []const []const u8 = &.{},
    natives_directory: ?[]const u8 = null,
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
    if (version.jar != null) return error.UnsupportedJarOverride;
    const arguments = version.arguments orelse return error.UnsupportedLegacyArguments;
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
    const cp = try std.mem.join(a, if (std.mem.eql(u8, env.os_name, "windows")) ";" else ":", plan.classpath);
    const natives = options.natives_directory orelse if (plan.native_extractions.len != 0) plan.native_extractions[0].destination else try std.fs.path.join(a, &.{ options.root, "versions", version.id, "natives" });
    if (!std.fs.path.isAbsolute(natives)) return error.AbsoluteNativePathRequired;
    for (plan.native_extractions) |extraction| if (!std.mem.eql(u8, extraction.destination, natives)) return error.NativeDirectoryMismatch;
    var context: Context = .{ .a = a, .version = version, .options = options, .classpath = cp, .natives = natives };
    var jvm = try command.Builder.init(a, options.java_executable);
    defer jvm.deinit();
    const jvm_tokens = try context.arguments(arguments.jvm orelse return error.MissingJvmArguments, env);
    try validateJvm(jvm_tokens);
    try java.append(&jvm, jvm_tokens);
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
    if (options.max_memory_mb) |mb| {
        if (mb == 0) return error.InvalidMemory;
        try java.append(&jvm, &.{try std.fmt.allocPrint(a, "-Xmx{d}M", .{mb})});
    }
    const extra_jvm = try context.expandMany(options.extra_jvm);
    try validateJvm(extra_jvm);
    try java.append(&jvm, extra_jvm);
    var game = try command.Builder.init(a, "game");
    defer game.deinit();
    try appendGame(&game, try context.arguments(arguments.game orelse return error.MissingGameArguments, env));
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
    return .{ .value = .{ .argv = out, .cwd = try a.dupe(u8, options.root) }, .arena = arena, .backing = allocator };
}
const Context = struct {
    a: std.mem.Allocator,
    version: m.version.Version,
    options: Options,
    classpath: []const u8,
    natives: []const u8,
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
            .{ "classpath", self.classpath },                  .{ "natives_directory", self.natives },
            .{ "launcher_name", o.launcher_name },             .{ "launcher_version", o.launcher_version },
            .{ "auth_player_name", o.identity.name },          .{ "auth_uuid", o.identity.uuid },
            .{ "auth_access_token", o.identity.access_token }, .{ "user_type", o.identity.user_type },
            .{ "version_name", self.version.id },              .{ "version_type", self.version.kind orelse "release" },
            .{ "game_directory", o.root },                     .{ "clientid", o.identity.client_id },
            .{ "auth_xuid", o.identity.xuid },                 .{ "user_properties", o.identity.user_properties },
        };
        inline for (values) |pair| if (std.mem.eql(u8, name, pair[0])) return pair[1];
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
    const valued = [_][]const u8{ "--username", "--version", "--gameDir", "--assetsDir", "--assetIndex", "--uuid", "--accessToken", "--clientId", "--xuid", "--userType", "--versionType", "--userProperties", "--profileProperties", "--width", "--height", "--server", "--port", "--quickPlayPath", "--quickPlaySingleplayer", "--quickPlayMultiplayer", "--quickPlayRealms" };
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
            try builder.add(.{ .key = .{ .namespace = "game", .name = name }, .canonical = name, .arity = .value }, value);
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

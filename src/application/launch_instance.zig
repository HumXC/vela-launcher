//! Main-thread launch use case. Prepared selections borrow the current configuration
//! and managers and must be consumed before either owner changes.
const std = @import("std");
const config = @import("../core/config.zig");
const instances = @import("../core/instances.zig");
const java = @import("../ui/java_manager.zig");
const accounts = @import("../ui/accounts_manager.zig");
const launch = @import("../ui/game_launch.zig");

pub const Selection = struct {
    document: *const config.Document,
    instance: config.Instance,
    java_path: []const u8,
    java_candidates: []const java.Runtime,
    account_manager: *const accounts.Manager,

    pub fn start(self: Selection, allocator: std.mem.Allocator, io: std.Io, launcher: *launch.Controller) !void {
        const now_ms: u64 = @intCast(@max(0, std.Io.Clock.awake.now(io).toMilliseconds()));
        var session = try self.account_manager.cloneLaunchSession(allocator, now_ms);
        defer session.deinit();
        const directory = try std.fs.path.join(allocator, &.{ launcher.root, "versions", self.instance.name });
        defer allocator.free(directory);
        const endpoint = try serverEndpoint(self.document, self.instance.id);
        const args = arguments(self.document, self.instance, self.java_path, self.java_candidates, &session, launcher.root, directory, endpoint);
        // startWithOptions synchronously deep-copies all borrowed request/options
        // data before returning, including the session token and directory.
        try launcher.startWithOptions(args.request, args.options);
    }
};

pub fn prepare(document: *const config.Document, java_manager: *const java.Manager, account_manager: ?*const accounts.Manager) !Selection {
    const instance = try selectedInstance(document);
    const java_path = instance.java_path orelse java_manager.selectedPath(instance.name) orelse "";
    const selected_accounts = account_manager orelse return error.NoAccountSelected;
    return .{
        .document = document,
        .instance = instance,
        .java_path = java_path,
        .java_candidates = java_manager.entries(),
        .account_manager = selected_accounts,
    };
}

fn selectedInstance(document: *const config.Document) !config.Instance {
    const id = document.selected_instance orelse return error.InstanceNotSelected;
    return (instances.findById(document, id) orelse return error.InstanceNotConfigured).*;
}

fn serverEndpoint(document: *const config.Document, instance_id: []const u8) !?launch.ServerEndpoint {
    if (document.selected_server) |id| {
        for (document.servers) |server| if (std.mem.eql(u8, server.id, id)) {
            if (server.instance_id == null or !std.mem.eql(u8, server.instance_id.?, instance_id)) return error.ServerInstanceMismatch;
            return .{ .address = server.address, .port = server.port };
        };
    }
    // Preserve the existing behavior for a stale selected server ID.
    return null;
}

const Arguments = struct { request: launch.Request, options: launch.LaunchOptions };

fn arguments(document: *const config.Document, instance: config.Instance, java_path: []const u8, candidates: []const java.Runtime, session: *const accounts.OwnedLaunchSession, root: []const u8, directory: []const u8, endpoint: ?launch.ServerEndpoint) Arguments {
    return .{
        .request = .{
            .version = instance.name,
            .java_path = java_path,
            .java_major = 0,
            .username = session.username,
            .min_memory_mb = instance.min_memory_mb,
            .max_memory_mb = instance.max_memory_mb orelse document.settings.default_memory_mb,
        },
        .options = .{
            .resolve_java_from_metadata = true,
            .java_candidates = candidates,
            .debug = instance.debug_launch,
            .instance_directory = directory,
            .instance_id = instance.id,
            .launcher_root = std.fs.path.dirname(root),
            .identity = .{ .name = session.username, .uuid = session.uuid, .access_token = if (session.token) |token| token.bytes else "0", .user_type = if (session.kind == .microsoft) "msa" else "legacy" },
            .server = endpoint,
        },
    };
}

test "launch instance selection distinguishes absent and stale IDs and uses stable identity" {
    var document: config.Document = .{};
    try std.testing.expectError(error.InstanceNotSelected, selectedInstance(&document));
    document.selected_instance = "stable-id";
    try std.testing.expectError(error.InstanceNotConfigured, selectedInstance(&document));
    document.instances = &.{.{ .id = "stable-id", .name = "renamed-game", .minecraft_version = "1.21" }};
    try std.testing.expectEqualStrings("renamed-game", (try selectedInstance(&document)).name);
}

test "launch instance server endpoint rejects unbound and mismatched selections" {
    var servers = [_]config.Server{.{ .id = "server", .name = "Test", .address = "localhost", .port = 25566 }};
    var document: config.Document = .{ .servers = &servers };
    try std.testing.expect(try serverEndpoint(&document, "instance") == null);
    document.selected_server = "missing";
    try std.testing.expect(try serverEndpoint(&document, "instance") == null);
    document.selected_server = "server";
    try std.testing.expectError(error.ServerInstanceMismatch, serverEndpoint(&document, "instance"));
    servers[0].instance_id = "other";
    try std.testing.expectError(error.ServerInstanceMismatch, serverEndpoint(&document, "instance"));
    servers[0].instance_id = "instance";
    const endpoint = (try serverEndpoint(&document, "instance")).?;
    try std.testing.expectEqualStrings("localhost", endpoint.address);
    try std.testing.expectEqual(@as(u16, 25566), endpoint.port);
}

test "launch instance arguments preserve memory defaults identity and worker Java resolution" {
    const a = std.testing.allocator;
    var session: accounts.OwnedLaunchSession = .{
        .allocator = a,
        .id = try a.dupe(u8, "account"),
        .username = try a.dupe(u8, "Player"),
        .uuid = try a.dupe(u8, "0123456789abcdef0123456789abcdef"),
        .kind = .offline,
    };
    defer session.deinit();
    const document: config.Document = .{ .settings = .{ .default_memory_mb = 4096 } };
    var instance: config.Instance = .{ .id = "stable-id", .name = "game", .minecraft_version = "1.21", .min_memory_mb = 512, .debug_launch = true };
    const offline = arguments(&document, instance, "", &.{}, &session, "/launcher/game", "/launcher/game/versions/game", null);
    try std.testing.expectEqualStrings("game", offline.request.version);
    try std.testing.expectEqualStrings("", offline.request.java_path);
    try std.testing.expectEqual(@as(u32, 0), offline.request.java_major);
    try std.testing.expectEqual(@as(?u32, 512), offline.request.min_memory_mb);
    try std.testing.expectEqual(@as(u32, 4096), offline.request.max_memory_mb);
    try std.testing.expect(offline.options.resolve_java_from_metadata and offline.options.debug);
    try std.testing.expectEqualStrings("stable-id", offline.options.instance_id.?);
    try std.testing.expectEqualStrings("/launcher", offline.options.launcher_root.?);
    try std.testing.expectEqualStrings("/launcher/game/versions/game", offline.options.instance_directory.?);
    try std.testing.expectEqualStrings("Player", offline.request.username);
    try std.testing.expectEqualStrings(session.uuid, offline.options.identity.?.uuid);
    try std.testing.expectEqualStrings("0", offline.options.identity.?.access_token);
    try std.testing.expectEqualStrings("legacy", offline.options.identity.?.user_type);
    try std.testing.expect(offline.options.server == null);

    session.kind = .microsoft;
    session.token = .{ .allocator = a, .bytes = try a.dupe(u8, "test-only-token") };
    instance.max_memory_mb = 8192;
    const online = arguments(&document, instance, "/java/bin/java", &.{}, &session, "/launcher/game", "/launcher/game/versions/game", .{ .address = "localhost", .port = 25566 });
    try std.testing.expectEqualStrings("/java/bin/java", online.request.java_path);
    try std.testing.expectEqual(@as(u32, 8192), online.request.max_memory_mb);
    try std.testing.expectEqualStrings("msa", online.options.identity.?.user_type);
    try std.testing.expectEqualStrings("test-only-token", online.options.identity.?.access_token);
    try std.testing.expectEqualStrings("localhost", online.options.server.?.address);
    try std.testing.expectEqual(@as(u16, 25566), online.options.server.?.port);
}

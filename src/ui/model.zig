const std = @import("std");

pub const Panel = enum { home, players, versions, more, library, java, servers, logs, instances, content, worlds };
pub const Category = enum { game, settings };
pub const VersionFilter = enum { release, snapshot, all };

pub const GameName = struct {
    bytes: [256]u8 = undefined,
    len: usize = 0,

    pub fn get(self: *const GameName) []const u8 {
        return self.bytes[0..self.len];
    }
    pub fn set(self: *GameName, name: []const u8) bool {
        if (name.len == 0 or name.len > self.bytes.len or std.mem.indexOfAny(u8, name, "/\\") != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
        @memcpy(self.bytes[0..name.len], name);
        self.len = name.len;
        return true;
    }
};
pub const Player = struct { id: u32, name: []const u8, initials: []const u8, kind: []const u8 };
pub const Version = struct { id: u32, name: []const u8, description: []const u8 };
const preview_players = [_]Player{.{ .id = 1, .name = "Player", .initials = "P", .kind = "离线玩家" }};
const preview_versions = [_]Version{.{ .id = 1, .name = "1.21.1", .description = "原版 · 界面预览" }};

pub const Msg = union(enum) {
    open_players,
    open_versions,
    open_more,
    open_library,
    library_back,
    open_java,
    java_back,
    open_servers,
    open_logs,
    open_instances,
    open_content,
    open_worlds,
    utility_back,
    select_category: Category,
    get_game,
    inspect_game: []const u8,
    use_game: []const u8,
    choose_download: []const u8,
    filter_versions: VersionFilter,
    back,
    select_player: u32,
    select_version: u32,
    start,
};

pub const Model = struct {
    labels: @import("labels.zig").Labels = .{},
    panel: Panel = .home,
    sidebar_width: f32 = 276,
    instance_leave: ?Msg = null,
    players: []const Player = &preview_players,
    versions: []const Version = &preview_versions,
    selected_player: u32 = 1,
    selected_version: u32 = 1,
    launch_notice: bool = false,
    category: Category = .game,
    getting_game: bool = true,
    version_filter: VersionFilter = .release,
    library_game: GameName = .{},
    download_game: GameName = .{},
    active_game: GameName = .{},
    search: [64]u8 = @splat(0),
    library_error: ?anyerror = null,

    pub fn player(model: *const Model) ?Player {
        for (model.players) |item| if (item.id == model.selected_player) return item;
        return null;
    }
    pub fn version(model: *const Model) ?Version {
        for (model.versions) |item| if (item.id == model.selected_version) return item;
        return null;
    }
    pub fn playerName(model: *const Model) []const u8 {
        return if (model.player()) |p| p.name else "选择玩家";
    }
    pub fn playerInitials(model: *const Model) []const u8 {
        return if (model.player()) |p| p.initials else "?";
    }
    pub fn playerKind(model: *const Model) []const u8 {
        return if (model.player()) |p| p.kind else "尚未选择玩家";
    }
    pub fn versionName(model: *const Model) []const u8 {
        if (model.active_game.len != 0) return model.active_game.get();
        return if (model.version()) |v| v.name else "选择版本";
    }
    pub fn isHome(model: *const Model) bool {
        return model.panel == .home;
    }
    pub fn isPlayers(model: *const Model) bool {
        return model.panel == .players;
    }
    pub fn isVersions(model: *const Model) bool {
        return model.panel == .versions;
    }
    pub fn isMore(model: *const Model) bool {
        return model.panel == .more;
    }
    pub fn hasPlayers(model: *const Model) bool {
        return model.players.len != 0;
    }
    pub fn hasVersions(model: *const Model) bool {
        return model.versions.len != 0;
    }
    pub fn startDisabled(model: *const Model) bool {
        return model.player() == null or (model.active_game.len == 0 and model.version() == null);
    }
};

/// Pure UI transitions. Selection IDs are validated before committing; no I/O.
pub fn transition(model: *Model, msg: Msg) void {
    switch (msg) {
        .open_players => {
            model.panel = .players;
            model.launch_notice = false;
        },
        .open_versions => {
            model.panel = .versions;
            model.launch_notice = false;
        },
        .open_more => {
            model.panel = .more;
            model.launch_notice = false;
        },
        .open_library => {
            model.panel = .instances;
            model.launch_notice = false;
        },
        .open_java => {
            model.panel = .java;
            model.launch_notice = false;
        },
        .java_back => {
            if (model.panel == .java) model.panel = .more;
        },
        .library_back => {
            if (model.panel == .library or model.panel == .instances) model.panel = .more;
        },
        .open_servers => {
            model.panel = .servers;
            model.launch_notice = false;
        },
        .open_instances => {
            model.panel = .instances;
            model.launch_notice = false;
        },
        .open_content => {
            model.panel = .content;
            model.launch_notice = false;
        },
        .open_worlds => {
            model.panel = .worlds;
            model.launch_notice = false;
        },
        .open_logs => {
            model.panel = .logs;
            model.launch_notice = false;
        },
        .utility_back => {
            if (model.panel == .servers or model.panel == .logs or model.panel == .instances or model.panel == .content or model.panel == .worlds) {
                model.panel = .more;
                model.category = .game;
            }
        },
        .select_category => |category| {
            if (model.panel == .more) model.category = category;
        },
        .get_game, .inspect_game => {
            model.panel = .instances;
            model.launch_notice = false;
        },
        .use_game => |name| {
            if (model.panel == .versions and model.active_game.set(name)) {
                model.panel = .home;
                model.launch_notice = false;
            }
        },
        .choose_download, .filter_versions => {
            model.panel = .instances;
            model.launch_notice = false;
        },
        .back => {
            model.panel = .home;
            model.launch_notice = false;
        },
        .select_player => |id| {
            if (model.panel != .players) return;
            for (model.players) |p| if (p.id == id) {
                model.selected_player = id;
                model.panel = .home;
                model.launch_notice = false;
                return;
            };
        },
        .select_version => |id| {
            if (model.panel != .versions) return;
            for (model.versions) |v| if (v.id == id) {
                model.selected_version = id;
                model.panel = .home;
                model.launch_notice = false;
                return;
            };
        },
        .start => {
            if (model.isHome() and !model.startDisabled()) model.launch_notice = true;
        },
    }
}

test "picker switching and back retain committed selections" {
    var model: Model = .{};
    transition(&model, .open_players);
    try std.testing.expect(model.isPlayers() and !model.isHome());
    transition(&model, .open_versions);
    try std.testing.expect(model.isVersions());
    transition(&model, .back);
    try std.testing.expect(model.isHome());
    try std.testing.expectEqual(@as(u32, 1), model.selected_player);
    try std.testing.expectEqual(@as(u32, 1), model.selected_version);
}
test "valid selection commits and invalid selection cannot corrupt state" {
    const players = [_]Player{ preview_players[0], .{ .id = 7, .name = "Other", .initials = "O", .kind = "离线玩家" } };
    const versions = [_]Version{ preview_versions[0], .{ .id = 9, .name = "test", .description = "test only" } };
    var model: Model = .{ .players = &players, .versions = &versions };
    transition(&model, .{ .select_player = 7 });
    try std.testing.expectEqual(@as(u32, 1), model.selected_player);
    transition(&model, .open_players);
    transition(&model, .{ .select_player = 99 });
    try std.testing.expect(model.isPlayers());
    transition(&model, .{ .select_player = 7 });
    try std.testing.expect(model.isHome());
    try std.testing.expectEqualStrings("Other", model.playerName());
    transition(&model, .open_versions);
    transition(&model, .{ .select_version = 9 });
    try std.testing.expectEqualStrings("test", model.versionName());
    try std.testing.expect(model.isHome());
}
test "empty and stale selections disable start and keep navigation available" {
    var model: Model = .{ .players = &.{}, .versions = &.{} };
    try std.testing.expect(model.startDisabled() and !model.hasPlayers() and !model.hasVersions());
    transition(&model, .start);
    try std.testing.expect(!model.launch_notice);
    transition(&model, .open_players);
    transition(&model, .back);
    try std.testing.expect(model.isHome());
    model = .{ .selected_version = 999 };
    try std.testing.expect(model.startDisabled());
}
test "launch feedback clears in more and returning retains selections" {
    var model: Model = .{};
    transition(&model, .start);
    try std.testing.expect(model.launch_notice);
    transition(&model, .open_more);
    try std.testing.expect(model.isMore() and !model.isHome() and !model.launch_notice);
    try std.testing.expectEqualStrings("设置", model.labels.settings);
    transition(&model, .start);
    try std.testing.expect(!model.launch_notice);
    transition(&model, .back);
    try std.testing.expect(model.isHome());
    try std.testing.expectEqual(@as(u32, 1), model.selected_player);
    try std.testing.expectEqual(@as(u32, 1), model.selected_version);
}

test "legacy directory aliases route to instance management without a second catalogue" {
    var model: Model = .{};
    _ = model.active_game.set("1.21.1");
    for ([_]Msg{ .open_library, .get_game, .{ .inspect_game = "1.21.1" }, .{ .choose_download = "1.20.1" }, .{ .filter_versions = .snapshot } }) |message| {
        transition(&model, message);
        try std.testing.expectEqual(Panel.instances, model.panel);
        try std.testing.expectEqualStrings("1.21.1", model.active_game.get());
        transition(&model, .library_back);
        try std.testing.expectEqual(Panel.more, model.panel);
    }
}

test "game name owns validated path component" {
    var value: GameName = .{};
    var name = "1.21".*;
    try std.testing.expect(value.set(&name));
    name[0] = '9';
    try std.testing.expectEqualStrings("1.21", value.get());
    try std.testing.expect(!value.set("../escape"));
    try std.testing.expectEqualStrings("1.21", value.get());
}

test "using a real installed version updates home without borrowing catalogue memory" {
    var model: Model = .{ .versions = &.{}, .selected_version = 0 };
    try std.testing.expect(model.startDisabled());
    transition(&model, .open_versions);
    transition(&model, .{ .use_game = "1.21.1" });
    try std.testing.expect(model.isHome() and !model.startDisabled());
    try std.testing.expectEqualStrings("1.21.1", model.versionName());
    transition(&model, .open_more);
    transition(&model, .{ .use_game = "wrong panel" });
    try std.testing.expectEqualStrings("1.21.1", model.versionName());
}

test "Java management navigation preserves game and player selections" {
    var model: Model = .{};
    _ = model.active_game.set("1.21.1");
    transition(&model, .open_more);
    transition(&model, .open_java);
    try std.testing.expectEqual(Panel.java, model.panel);
    transition(&model, .java_back);
    try std.testing.expectEqual(Panel.more, model.panel);
    transition(&model, .open_java);
    transition(&model, .back);
    try std.testing.expect(model.isHome());
    try std.testing.expectEqualStrings("1.21.1", model.active_game.get());
    try std.testing.expectEqual(@as(u32, 1), model.selected_player);
}

test "independent archives and instance management return to game without changing selections" {
    for ([_]Msg{ .open_worlds, .open_instances }) |message| {
        var model: Model = .{ .category = .settings };
        _ = model.active_game.set("1.21.1");
        _ = model.library_game.set("1.20.1");
        transition(&model, message);
        try std.testing.expect(model.panel == if (message == .open_worlds) Panel.worlds else Panel.instances);
        transition(&model, .utility_back);
        try std.testing.expectEqual(Panel.more, model.panel);
        try std.testing.expectEqual(Category.game, model.category);
        try std.testing.expectEqualStrings("1.21.1", model.active_game.get());
        try std.testing.expectEqualStrings("1.20.1", model.library_game.get());
        try std.testing.expectEqual(@as(u32, 1), model.selected_player);
        transition(&model, message);
        transition(&model, .back);
        try std.testing.expect(model.isHome());
        try std.testing.expectEqualStrings("1.21.1", model.active_game.get());
    }
}

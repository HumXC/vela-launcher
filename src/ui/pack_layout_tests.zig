const std = @import("std");
const dvui = @import("dvui");
const view = @import("pack_view.zig");
const theme = @import("theme.zig");
const providers = @import("../core/content_providers.zig");
const Frame = struct {
    var ui: *view.Ui = undefined;
    var state: view.Presentation = .{};
    var allowed: bool = true;
    fn draw() !dvui.App.Result {
        const root = dvui.box(@src(), .{}, .{ .expand = .both, .padding = .all(24), .margin = .all(0) });
        defer root.deinit();
        view.draw(ui, state, allowed);
        return .ok;
    }
};
fn inside(outer: dvui.Rect.Physical, inner: dvui.Rect.Physical) bool {
    return inner.w > 0 and inner.h > 0 and inner.x >= outer.x - 1 and inner.y >= outer.y - 1 and inner.x + inner.w <= outer.x + outer.w + 1 and inner.y + inner.h <= outer.y + outer.h + 1;
}
test "pack page keeps pagination fixed across async loading and empty states" {
    for ([_]f32{ 420, 800 }) |width| {
        var ui = view.Ui.init(std.testing.allocator);
        defer ui.deinit();
        Frame.ui = &ui;
        Frame.state = .{};
        var window = try dvui.testing.init(.{ .window_size = .{ .w = width, .h = 640 } });
        defer window.deinit();
        window.backend.size_pixels = .{ .w = width, .h = 640 };
        theme.install(dvui.currentWindow());
        theme.applyTypography();
        try dvui.testing.settle(Frame.draw);
        const before = (dvui.tagGet("pack-back") orelse return error.BackMissing).rect;
        for ([_][]const u8{ "pack-back", "pack-previous", "pack-next", "pack-refresh" }) |tag| {
            const rect = (dvui.tagGet(tag) orelse return error.FooterMissing).rect;
            if (width >= 480 or !std.mem.eql(u8, tag, "pack-refresh")) try std.testing.expect(inside(.{ .x = 24, .y = 24, .w = width - 48, .h = 592 }, rect));
            try std.testing.expectApproxEqAbs(before.y, rect.y, 1);
        }
        Frame.state.busy = true;
        try dvui.testing.settle(Frame.draw);
        const loading = (dvui.tagGet("pack-back") orelse return error.BackMissing).rect;
        try std.testing.expectApproxEqAbs(before.y, loading.y, 1);
        Frame.state.busy = false;
        ui.searched = true;
        try dvui.testing.settle(Frame.draw);
        try std.testing.expectApproxEqAbs(before.y, (dvui.tagGet("pack-back") orelse return error.BackMissing).rect.y, 1);
    }
}
test "pack UI retains independent catalog project and version owners" {
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var source: std.heap.ArenaAllocator = .init(std.testing.allocator);
    const a = source.allocator();
    const title = try a.dupe(u8, "A modpack");
    const project: providers.Project = .{ .provider = .modrinth, .id = "test", .name = title, .official_page = "https://modrinth.com/modpack/test" };
    try ui.acceptCatalog(&.{project}, 1);
    try ui.openProject(0);
    source.deinit();
    try ui.acceptCatalog(&.{}, 0);
    try std.testing.expectEqualStrings("A modpack", ui.project.?.name);
    try std.testing.expectEqual(@as(usize, 0), ui.catalog.len);
}

test "pack disabled frames do not enqueue icons and prevent shutdown drain" {
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    ui.icon_cache = @import("resource_icons.zig").Manager.init(std.testing.allocator, std.testing.io);
    try ui.acceptCatalog(&.{.{ .provider = .modrinth, .id = "example", .name = "Pack", .official_page = "https://modrinth.com/modpack/example", .icon_url = "https://cdn.modrinth.com/example.png" }}, 1);
    Frame.ui = &ui;
    Frame.state = .{};
    Frame.allowed = false;
    defer Frame.allowed = true;
    var window = try dvui.testing.init(.{ .window_size = .{ .w = 800, .h = 640 } });
    defer window.deinit();
    window.backend.size_pixels = .{ .w = 800, .h = 640 };
    theme.install(dvui.currentWindow());
    theme.applyTypography();
    try dvui.testing.settle(Frame.draw);
    try std.testing.expect(!ui.icon_cache.?.busy());
    try std.testing.expectEqual(@as(usize, 0), ui.icon_cache.?.entries.items.len);
}

test "pack search source and import controls stay visible at wide and narrow widths" {
    for ([_]f32{ 420, 800, 1104, 1440 }) |width| {
        var ui = view.Ui.init(std.testing.allocator);
        defer ui.deinit();
        Frame.ui = &ui;
        Frame.state = .{};
        var window = try dvui.testing.init(.{ .window_size = .{ .w = width, .h = 640 } });
        defer window.deinit();
        window.backend.size_pixels = .{ .w = width, .h = 640 };
        theme.install(dvui.currentWindow());
        theme.applyTypography();
        try dvui.testing.settle(Frame.draw);
        for ([_][]const u8{ "pack-source", "pack-search", "pack-import" }) |tag| {
            const rect = (dvui.tagGet(tag) orelse return error.SearchControlMissing).rect;
            try std.testing.expect(inside(.{ .x = 24, .y = 24, .w = width - 48, .h = 592 }, rect));
        }
        const source = dvui.tagGet("pack-source").?.rect;
        const search = dvui.tagGet("pack-search").?.rect;
        try std.testing.expect(source.x + source.w <= search.x + 1);
        const import_button = dvui.tagGet("pack-import").?.rect;
        const refresh = dvui.tagGet("pack-refresh").?.rect;
        try std.testing.expect(import_button.x + import_button.w <= refresh.x);
        try std.testing.expectApproxEqAbs(import_button.y, refresh.y, 1);
    }
}

test "pack detail action aligns at the right center of its result row" {
    for ([_]f32{ 420, 800, 1104, 1440 }) |width| {
        var ui = view.Ui.init(std.testing.allocator);
        defer ui.deinit();
        try ui.acceptCatalog(&.{.{ .provider = .modrinth, .id = "test", .name = "Example pack", .summary = "Explore and build", .official_page = "https://modrinth.com/modpack/test" }}, 1);
        Frame.ui = &ui;
        Frame.state = .{};
        var window = try dvui.testing.init(.{ .window_size = .{ .w = width, .h = 800 } });
        defer window.deinit();
        window.backend.size_pixels = .{ .w = width, .h = 800 };
        theme.install(dvui.currentWindow());
        theme.applyTypography();
        try dvui.testing.settle(Frame.draw);
        const row = (dvui.tagGet("pack-project-row-0") orelse return error.RowMissing).rect;
        const action = (dvui.tagGet("pack-project-0") orelse return error.ActionMissing).rect;
        try std.testing.expect(inside(row, action));
        try std.testing.expectApproxEqAbs(row.x + row.w, action.x + action.w, 1);
        try std.testing.expectApproxEqAbs(row.y + row.h / 2, action.y + action.h / 2, 1);
    }
}

test "pack detail retains its icon and version selector during archive preparation" {
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    try ui.acceptCatalog(&.{.{ .provider = .modrinth, .id = "test", .name = "Example pack", .official_page = "https://modrinth.com/modpack/test" }}, 1);
    try ui.openProject(0);
    try ui.acceptVersions(&.{.{ .provider = .modrinth, .project_id = "test", .id = "release", .name = "Release", .minecraft_versions = &.{"1.20.1"}, .loaders = &.{"fabric"}, .files = &.{}, .dependencies = &.{} }});
    Frame.ui = &ui;
    Frame.state = .{};
    var window = try dvui.testing.init(.{ .window_size = .{ .w = 1104, .h = 800 } });
    defer window.deinit();
    window.backend.size_pixels = .{ .w = 1104, .h = 800 };
    theme.install(dvui.currentWindow());
    theme.applyTypography();
    try dvui.testing.settle(Frame.draw);
    const icon = (dvui.tagGet("pack-detail-icon") orelse return error.IconMissing).rect;
    try std.testing.expect(icon.w >= 80 and icon.h >= 80);
    const before = (dvui.tagGet("pack-version") orelse return error.VersionMissing).rect;
    Frame.state = .{ .busy = true, .task = .working };
    try dvui.testing.settle(Frame.draw);
    const during = (dvui.tagGet("pack-version") orelse return error.VersionMissing).rect;
    try std.testing.expectApproxEqAbs(before.y, during.y, 1);
    try std.testing.expect(dvui.tagGet("pack-detail-icon") != null);
    try std.testing.expect(dvui.tagGet("pack-import") == null);
    try std.testing.expect(dvui.tagGet("pack-project-link") != null);
}

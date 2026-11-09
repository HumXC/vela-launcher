const std = @import("std");
const dvui = @import("dvui");
const config = @import("../core/config.zig");
const accounts = @import("../application/accounts_manager.zig");
const chooser = @import("accounts_view.zig");
const avatar = @import("avatar_manager.zig");

const Frame = struct {
    var store: *config.Store = undefined;
    var accounts_manager: *accounts.Manager = undefined;
    var avatars: *avatar.Manager = undefined;
    var ui: *chooser.Ui = undefined;

    fn draw() !dvui.App.Result {
        dvui.debug.captureScopeBegin(dvui.currentWindow().gpa);
        defer dvui.debug.captureScopeEnd();
        // Join only the deterministic cache-only test worker before checking
        // the previous frame's visible interests; production never waits here.
        if (avatars.active) |job| if (job.future) |*future| future.await(std.testing.io);
        avatars.tick();
        try avatars.sync(store.snapshot(), true);
        avatars.beginPicker(true);
        const root = dvui.box(@src(), .{}, .{ .expand = .both, .padding = dvui.Rect.all(12) });
        defer root.deinit();
        chooser.draw(ui, store, accounts_manager, avatars);
        return .ok;
    }
};

test "UI layout account avatars stay inside cards and only visible rows load without changing identity" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    const names = [_][]const u8{ "Player", "Second", "Third", "Fourth", "Fifth", "Sixth", "Seventh", "Eighth", "Ninth", "Tenth", "Eleventh", "Twelfth" };
    const uuid = "a01e3843e5213998958af459800e4d11";
    var fixtures: [names.len]config.Account = undefined;
    for (names, &fixtures) |name, *account| account.* = .{ .id = name, .name = name, .uuid = uuid };
    fixtures[1].kind = .microsoft;
    try store.update(.{ .accounts = &fixtures, .selected_account = names[0] });
    var manager = try accounts.Manager.init(a, std.testing.io, root);
    defer manager.deinit();
    var avatars = try avatar.Manager.init(a, std.testing.io, root, .{}, false);
    defer avatars.deinit();
    var ui = try chooser.Ui.init(a);
    defer ui.deinit();
    Frame.store = &store;
    Frame.accounts_manager = &manager;
    Frame.avatars = &avatars;
    Frame.ui = &ui;
    for ([_]dvui.Size{ .{ .w = 640, .h = 400 }, .{ .w = 1280, .h = 720 } }) |size| {
        try store.update(.{ .accounts = &fixtures, .selected_account = names[0] });
        var window = try dvui.testing.init(.{ .window_size = size });
        defer window.deinit();
        window.backend.size_pixels = .{ .w = size.w, .h = size.h };
        window.window.themeSet(dvui.Theme.builtin.adwaita_dark);
        try dvui.testing.settle(Frame.draw);
        var visible: usize = 0;
        for (names) |name| {
            const card_name = try std.fmt.allocPrint(window.window.arena(), "account-card-{s}", .{name});
            const face_name = try std.fmt.allocPrint(window.window.arena(), "account-avatar-{s}", .{name});
            const card = try dvui.testing.tagGet(card_name);
            const face = try dvui.testing.tagGet(face_name);
            const capture = dvui.debug.lastCapture() orelse return error.AccountCardCaptureMissing;
            const card_widget = for (capture.widgets.items) |widget| {
                if (widget.id == card.id) break widget;
            } else return error.AccountCardWidgetMissing;
            const track = for (capture.widgets.items) |widget| {
                if (widget.id == card_widget.parent_id) break widget.rect_content;
            } else return error.AccountCardTrackMissing;
            // Use the settled ScrollContainer track, including scrollbar reservation.
            try std.testing.expect(track.w > 460);
            try std.testing.expectApproxEqAbs(track.w, card.rect.w, 0.1);
            try std.testing.expectApproxEqAbs(track.x, card.rect.x, 0.1);
            try std.testing.expectApproxEqAbs(track.x + track.w, card.rect.x + card.rect.w, 0.1);
            try std.testing.expect(face.rect.x >= card.rect.x + 12 - 0.1);
            try std.testing.expect(face.rect.y >= card.rect.y + 12 - 0.1);
            try std.testing.expect(face.rect.x + face.rect.w <= card.rect.x + card.rect.w - 12 + 0.1);
            try std.testing.expect(face.rect.y + face.rect.h <= card.rect.y + card.rect.h - 12 + 0.1);
            try std.testing.expectApproxEqAbs(@as(f32, 48), face.rect.w, 0.1);
            try std.testing.expectApproxEqAbs(@as(f32, 48), face.rect.h, 0.1);
            if (card.visible) visible += 1;
        }
        try std.testing.expect(visible > 1 and visible <= names.len);
        if (size.h < 480) try std.testing.expect(visible < names.len);
        try std.testing.expectEqual(visible, avatars.visible_count);
        try std.testing.expectEqualStrings(names[0], store.snapshot().selected_account.?);
        for (store.snapshot().accounts) |account| try std.testing.expectEqualStrings(uuid, account.uuid);
        const second = try dvui.testing.tagGet("account-card-Second");
        try std.testing.expect(second.visible);
        _ = try window.window.addEventMouseMotion(.{ .pt = second.rect.center() });
        try dvui.testing.click(.left);
        try dvui.testing.settle(Frame.draw);
        try std.testing.expect(ui.pending != null);
        chooser.finish(&ui, &store, &manager);
        try std.testing.expectEqualStrings(names[1], store.snapshot().selected_account.?);
        try dvui.testing.settle(Frame.draw);
        for (store.snapshot().accounts) |account| try std.testing.expectEqualStrings(uuid, account.uuid);
        avatars.beginPicker(false);
    }
}

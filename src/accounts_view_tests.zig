const std = @import("std");
const view = @import("ui/accounts_view.zig");
const dvui = @import("dvui");
const config = @import("core/config.zig");
const accounts_manager = @import("ui/accounts_manager.zig");

test "accounts view native entrypoints compile" {
    std.mem.doNotOptimizeAway(&view.draw);
    std.mem.doNotOptimizeAway(&view.finish);
    std.testing.refAllDecls(view);
}

const AccountFrame = struct {
    var ui: *view.Ui = undefined;
    var store: *config.Store = undefined;
    var manager: *accounts_manager.Manager = undefined;
    var management_text_seen = false;

    fn draw() !dvui.App.Result {
        const win = dvui.currentWindow();
        var commands: std.ArrayList(dvui.RenderCommand) = .empty;
        defer commands.deinit(win.arena());
        const previous_commands = win.defer_render_cmds;
        const previous_rendering = win.render_target.rendering;
        win.defer_render_cmds = &commands;
        win.render_target.rendering = false;
        dvui.debug.captureScopeBegin(win.gpa);
        defer {
            dvui.debug.captureScopeEnd();
            win.defer_render_cmds = previous_commands;
            win.render_target.rendering = previous_rendering;
        }
        {
            const root = dvui.box(@src(), .{}, .{ .expand = .both, .padding = dvui.Rect.all(12) });
            defer root.deinit();
            view.draw(ui, store, manager, null);
        }
        management_text_seen = false;
        for (commands.items) |command| switch (command.cmd) {
            .text => |text| if (std.mem.indexOf(u8, text.text, "账户管理") != null) {
                management_text_seen = true;
            },
            else => {},
        };
        return .ok;
    }

    fn click(tag: []const u8) !void {
        const control = try dvui.testing.tagGet(tag);
        try std.testing.expect(control.visible);
        _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = control.rect.center() });
        try dvui.testing.click(.left);
        try dvui.testing.settle(draw);
    }

    fn modalControl(tag: []const u8, source: []const u8) !dvui.Rect.Physical {
        const control = try dvui.testing.tagGet(tag);
        try std.testing.expect(control.visible);
        const capture = dvui.debug.lastCapture() orelse return error.AccountCaptureMissing;
        for (capture.widgets.items) |widget| {
            if (widget.id != control.id) continue;
            try std.testing.expectEqualStrings("Button", widget.name orelse "");
            try std.testing.expectEqualStrings(source, widget.src_fn);
            const modal = dvui.currentWindow().subwindows.get(widget.subwindow_id) orelse return error.AccountModalMissing;
            try std.testing.expect(modal.modal);
            try inside(modal.rect_pixels, control.rect);
            try inside(dvui.windowRectPixels(), control.rect);
            return control.rect;
        }
        return error.AccountControlMissing;
    }

    fn cancelConfirmation() !void {
        const capture = dvui.debug.lastCapture() orelse return error.AccountCaptureMissing;
        var modal_id: ?dvui.Id = null;
        for (capture.widgets.items) |widget| {
            if (std.mem.eql(u8, widget.name orelse "", "FloatingWindow") and std.mem.eql(u8, widget.src_fn, "drawConfirmation")) modal_id = widget.id;
        }
        const id = modal_id orelse return error.AccountConfirmationMissing;
        const modal = dvui.currentWindow().subwindows.get(id) orelse return error.AccountConfirmationMissing;
        // The left form action is Cancel; click its actual captured native button.
        for (capture.widgets.items) |widget| {
            if (widget.subwindow_id != id or !std.mem.eql(u8, widget.name orelse "", "Button") or !std.mem.eql(u8, widget.src_fn, "modalFormActions")) continue;
            if (widget.rect_border.center().x >= modal.rect_pixels.center().x) continue;
            try inside(modal.rect_pixels, widget.rect_border);
            _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = widget.rect_border.center() });
            try dvui.testing.click(.left);
            try dvui.testing.settle(draw);
            return;
        }
        return error.AccountConfirmationCancelMissing;
    }

    fn inside(outer: dvui.Rect.Physical, inner: dvui.Rect.Physical) !void {
        try std.testing.expect(inner.x >= outer.x - 0.01 and inner.y >= outer.y - 0.01);
        try std.testing.expect(inner.x + inner.w <= outer.x + outer.w + 0.01);
        try std.testing.expect(inner.y + inner.h <= outer.y + outer.h + 0.01);
    }
};

test "accounts view native selected Edit precedes Add and Delete stays inside selected editor" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    var manager = try accounts_manager.Manager.init(a, std.testing.io, root);
    defer manager.deinit();
    var ui = try view.Ui.init(a);
    defer ui.deinit();
    AccountFrame.ui = &ui;
    AccountFrame.store = &store;
    AccountFrame.manager = &manager;
    for ([_]dvui.Size{ .{ .w = 640, .h = 400 }, .{ .w = 1280, .h = 720 } }) |size| {
        for ([_]config.AccountKind{ .offline, .microsoft }) |kind| {
            const account: config.Account = .{ .id = "fixture-account", .name = "FixturePlayer", .uuid = "00112233445566778899aabbccddeeff", .kind = kind };
            try store.update(.{ .accounts = &.{account} });
            var window = try dvui.testing.init(.{ .window_size = size });
            defer window.deinit();
            window.backend.size_pixels = .{ .w = size.w, .h = size.h };
            try dvui.testing.settle(AccountFrame.draw);
            try std.testing.expect(dvui.tagGet("account-edit") == null);
            try std.testing.expect(dvui.tagGet("account-delete") == null);
            try store.update(.{ .accounts = &.{account}, .selected_account = account.id });
            try dvui.testing.settle(AccountFrame.draw);
            const edit = try dvui.testing.tagGet("account-edit");
            const add = try dvui.testing.tagGet("account-add");
            try std.testing.expect(edit.visible and add.visible);
            try std.testing.expect(edit.rect.x + edit.rect.w <= add.rect.x);
            try std.testing.expectApproxEqAbs(edit.rect.y, add.rect.y, 0.01);
            try std.testing.expect(!AccountFrame.management_text_seen);
            try std.testing.expect(dvui.tagGet("account-delete") == null);
            try AccountFrame.click("account-add");
            try std.testing.expect(ui.pending.?.action == .add and !ui.editor_open);
            view.finish(&ui, &store, &manager);
            try dvui.testing.settle(AccountFrame.draw);
            try std.testing.expect(ui.editor_open and ui.draft.id == null);
            try std.testing.expect(dvui.tagGet("account-delete") == null);
            try AccountFrame.click("account-cancel");
            view.finish(&ui, &store, &manager);
            try dvui.testing.settle(AccountFrame.draw);
            try AccountFrame.click("account-edit");
            try std.testing.expect(ui.pending.?.action == .edit and !ui.editor_open);
            view.finish(&ui, &store, &manager);
            try dvui.testing.settle(AccountFrame.draw);
            try std.testing.expect(ui.editor_open);
            _ = try AccountFrame.modalControl("account-delete", "drawEditor");
            _ = try AccountFrame.modalControl("account-cancel", "drawEditor");
            if (kind == .microsoft) {
                try std.testing.expect(dvui.tagGet("account-name") == null);
                try std.testing.expect(dvui.tagGet("account-offline-login") == null);
                _ = try AccountFrame.modalControl("account-sign-out", "drawEditor");
            } else {
                try dvui.testing.expectVisible("account-name");
                _ = try AccountFrame.modalControl("account-offline-login", "drawEditor");
            }
            try AccountFrame.click("account-delete");
            try std.testing.expect(ui.confirmation == null);
            try std.testing.expect(if (kind == .microsoft) ui.pending.?.action == .ask_sign_out else ui.pending.?.action == .ask_delete);
            view.finish(&ui, &store, &manager);
            try std.testing.expect(ui.confirmation.?.sign_out == (kind == .microsoft));
            try dvui.testing.settle(AccountFrame.draw);
            try AccountFrame.cancelConfirmation();
            try std.testing.expect(ui.pending.?.action == .close_confirm);
            view.finish(&ui, &store, &manager);
            try dvui.testing.settle(AccountFrame.draw);
            try std.testing.expect(ui.confirmation == null and ui.editor_open);
            try std.testing.expectEqualStrings(account.id, ui.draft.id.?);
            try std.testing.expectEqualStrings(account.name, std.mem.sliceTo(&ui.draft.name, 0));
            try std.testing.expectEqualStrings(account.id, store.snapshot().selected_account.?);
            _ = try AccountFrame.modalControl("account-delete", "drawEditor");
            try AccountFrame.click("account-cancel");
            view.finish(&ui, &store, &manager);
            try std.testing.expect(!ui.editor_open and ui.draft.id == null);
            try std.testing.expectEqualStrings(account.name, store.snapshot().accounts[0].name);
            try std.testing.expectEqualStrings(account.uuid, store.snapshot().accounts[0].uuid);
            try std.testing.expectEqualStrings(account.id, store.snapshot().selected_account.?);
        }
    }
}

test "accounts view native same-frame text edit and save captures final field value" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    var manager = try accounts_manager.Manager.init(a, std.testing.io, root);
    defer manager.deinit();
    var ui = try view.Ui.init(a);
    defer ui.deinit();
    ui.editor_open = true;
    @memcpy(ui.draft.name[0..6], "Before");
    AccountFrame.ui = &ui;
    AccountFrame.store = &store;
    AccountFrame.manager = &manager;
    var window = try dvui.testing.init(.{ .window_size = .{ .w = 1280, .h = 720 } });
    defer window.deinit();
    window.backend.size_pixels = .{ .w = 1280, .h = 720 };
    try dvui.testing.settle(AccountFrame.draw);
    try AccountFrame.click("account-name");
    try dvui.testing.pressKey(.a, .lcontrol);
    try dvui.testing.writeText("AfterEdit");
    // Both text and the real footer click belong to the very next frame.
    const save = try dvui.testing.tagGet("account-offline-login");
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = save.rect.center() });
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(AccountFrame.draw);
    try std.testing.expectEqualStrings("AfterEdit", std.mem.sliceTo(&ui.draft.name, 0));
    try std.testing.expectEqualStrings("AfterEdit", ui.pending.?.text.?);
    // Queued metadata owns the value, independent of later draft edits.
    ui.draft.name[0] = 'Z';
    view.finish(&ui, &store, &manager);
    try std.testing.expectEqualStrings("AfterEdit", store.snapshot().accounts[0].name);
    try std.testing.expect(!ui.editor_open);
}

//! Independent instance-wide recovery renderer and input regression.
const std = @import("std");
const dvui = @import("dvui");
const config = @import("core/config.zig");
const instances = @import("core/instances.zig");
const tasks = @import("core/tasks.zig");
const leases = @import("core/instance_leases.zig");
const worlds = @import("core/worlds.zig");
const manager_module = @import("application/worlds_manager.zig");
const view = @import("ui/worlds_view.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const source: config.Instance = .{ .id = "backup-owner", .name = "Owner", .minecraft_version = "1.21" };
const original_id = "0123456789abcdef0123456789abcdef";
const broken_id = "11111111111111111111111111111111";
const overwritten_id = "22222222222222222222222222222222";

fn settleManager(manager: *manager_module.Manager) !void {
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    while (manager.snapshot().worker_active) {
        manager.tick();
        if (std.Io.Clock.awake.now(io).nanoseconds - start > 3 * std.time.ns_per_s) return error.BackupViewWorkerTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    if (manager.snapshot().failure) |err| return err;
}

fn ownedBackup(alloc: std.mem.Allocator, id: []const u8, part: @FieldType(worlds.BackupRef, "part"), folder: ?[]const u8) !worlds.Backup {
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const directory = try alloc.dupe(u8, "/unused-renderer-fixture");
    errdefer alloc.free(directory);
    const owned_folder = if (folder) |value| try alloc.dupe(u8, value) else null;
    errdefer if (owned_folder) |value| alloc.free(value);
    const instance = if (folder != null) try alloc.dupe(u8, source.id) else null;
    return .{ .id = owned_id, .part = part, .directory = directory, .source_folder = owned_folder, .source_instance = instance, .created_ms = 1735776000000, .operation = if (folder != null) .delete else null, .manifest_error = if (folder == null) error.InvalidManifest else null };
}

const Frame = struct {
    var ui: *view.Ui = undefined;
    var manager: *manager_module.Manager = undefined;
    var doc: *const config.Document = undefined;
    var controls_enabled = true;
    var saw_manifest_error = false;
    var saw_old_folder = false;

    fn work(alloc: std.mem.Allocator, worker_io: std.Io, _: *const instances.Paths, _: config.Instance, request: ?manager_module.Request, options: worlds.Options) !manager_module.Result {
        if (request != null) return error.UnexpectedRendererMutation;
        try options.hooks.check(worker_io);
        try options.held_scope.?.recheck();
        const backups = try alloc.alloc(worlds.Backup, 3);
        errdefer alloc.free(backups);
        backups[0] = try ownedBackup(alloc, original_id, .original, "old-folder");
        errdefer backups[0].deinit(alloc);
        backups[1] = try ownedBackup(alloc, broken_id, .original, null);
        errdefer backups[1].deinit(alloc);
        backups[2] = try ownedBackup(alloc, overwritten_id, .overwritten, "old-folder");
        return .{ .backup_list = .{ .allocator = alloc, .items = backups } };
    }

    fn draw() !dvui.App.Result {
        const win = dvui.currentWindow();
        dvui.debug.captureScopeBegin(win.gpa);
        defer dvui.debug.captureScopeEnd();
        var commands: std.ArrayList(dvui.RenderCommand) = .empty;
        defer commands.deinit(win.arena());
        const previous_commands = win.defer_render_cmds;
        const previous_rendering = win.render_target.rendering;
        win.defer_render_cmds = &commands;
        win.render_target.rendering = false;
        defer {
            win.defer_render_cmds = previous_commands;
            win.render_target.rendering = previous_rendering;
        }
        try view.drawWithEnabled(ui, doc, manager, controls_enabled);
        try view.drawModal(ui, doc, manager);
        var text: std.ArrayList(u8) = .empty;
        for (commands.items) |command| switch (command.cmd) {
            .text => |value| try text.appendSlice(win.arena(), value.text),
            else => {},
        };
        saw_manifest_error = saw_manifest_error or std.mem.indexOf(u8, text.items, "无法安全恢复") != null;
        saw_old_folder = std.mem.indexOf(u8, text.items, "old-folder") != null;
        return .ok;
    }

    fn viewport(tag: []const u8) !dvui.Rect.Physical {
        const tagged = try dvui.testing.tagGet(tag);
        const capture = dvui.debug.lastCapture() orelse return error.MissingWorldCapture;
        var clip = dvui.currentWindow().rect_pixels;
        var current = tagged.id;
        // The backup dock is outside the world list and has its own scroll area.
        // Reveal controls through their actual ancestors, including nested clips.
        for (0..capture.widgets.items.len) |_| {
            const parent = for (capture.widgets.items) |widget| {
                if (widget.id == current) break widget;
            } else {
                // Window parents are outside the captured view scope.
                if (current == tagged.id) return error.MissingWorldViewport;
                return clip;
            };
            if (std.mem.eql(u8, parent.name orelse "", "ScrollAreaWidget"))
                clip = clip.intersect(parent.rect_content);
            if (parent.parent_id == parent.id) return clip;
            current = parent.parent_id;
        }
        return error.MissingWorldViewport;
    }

    fn reveal(tag: []const u8) !void {
        for (0..8) |_| {
            const widget = try dvui.testing.tagGet(tag);
            const clip = try viewport(tag);
            if (widget.visible and widget.rect.y >= clip.y - 0.1 and widget.rect.y + widget.rect.h <= clip.y + clip.h + 0.1) return;
            _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = clip.center() });
            _ = try dvui.currentWindow().addEventMouseWheel(clip.center().y - widget.rect.center().y, .vertical, null);
            try dvui.testing.settle(draw);
        }
        return error.BackupControlNotVisible;
    }

    fn expectTab(tag: []const u8, enabled: bool) !void {
        const widget = try dvui.testing.tagGet(tag);
        var count: usize = 0;
        for (dvui.currentWindow().tab_index_prev.items) |entry| if (entry.widgetId == widget.id) {
            count += 1;
        };
        try std.testing.expectEqual(@as(usize, if (enabled) 1 else 0), count);
    }

    fn click(tag: []const u8) !void {
        try reveal(tag);
        try dvui.testing.moveTo(tag);
        try dvui.testing.click(.left);
        try dvui.testing.settle(draw);
    }
};

test "world backup view layout exposes deleted old-folder and malformed backups without live worlds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var coordinator = leases.Coordinator.init(io);
    var manager = try manager_module.Manager.initOptions(a, io, &paths, &registry, .{ .scope = coordinator.worldScope(3), .worker = Frame.work });
    defer manager.deinit();
    try manager.select(source);
    try settleManager(&manager);
    const doc: config.Document = .{ .instances = &.{source}, .selected_instance = source.id };
    Frame.doc = &doc;
    Frame.manager = &manager;
    const valid = "world-restore-" ++ original_id ++ "-original";
    const broken = "world-restore-" ++ broken_id ++ "-original";
    const overwritten = "world-restore-" ++ overwritten_id ++ "-overwritten";
    for ([_]dvui.Size{ .{ .w = 300, .h = 400 }, .{ .w = 640, .h = 400 }, .{ .w = 1280, .h = 720 } }) |size| {
        for ([_]f32{ 16, 24 }) |font_size| {
            var window = try dvui.testing.init(.{ .window_size = size });
            defer window.deinit();
            window.backend.size_pixels = .{ .w = size.w, .h = size.h };
            var theme = dvui.themeGet();
            theme.font_body = theme.font_body.withSize(font_size);
            window.window.themeSet(theme);
            var ui = try view.Ui.init(a);
            defer ui.deinit();
            Frame.ui = &ui;
            Frame.controls_enabled = true;
            Frame.saw_manifest_error = false;
            Frame.saw_old_folder = false;
            try dvui.testing.settle(Frame.draw);
            try std.testing.expect(ui.selected_world == null and manager.snapshot().worlds.len == 0);
            try std.testing.expect(dvui.tagGet("world-backups-toggle") != null);
            try std.testing.expect(dvui.tagGet("world-recovery-list") == null);
            try Frame.click("world-backups-toggle");
            try std.testing.expect(ui.backups_expanded);
            try Frame.reveal(valid);
            try Frame.expectTab(valid, true);
            try std.testing.expect(Frame.saw_old_folder);
            const row = try dvui.testing.tagGet("world-backup-item-" ++ original_id ++ "-original");
            const restore = try dvui.testing.tagGet(valid);
            try std.testing.expect(restore.rect.x >= row.rect.x and restore.rect.x + restore.rect.w <= row.rect.x + row.rect.w + 0.1);
            // The diagnostic precedes the restore button; scroll the row into
            // view separately so clipping cannot hide it on compact windows.
            for (0..4) |_| {
                const broken_row = try dvui.testing.tagGet("world-backup-item-" ++ broken_id ++ "-original");
                const clip = try Frame.viewport("world-backup-item-" ++ broken_id ++ "-original");
                _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = clip.center() });
                _ = try dvui.currentWindow().addEventMouseWheel(clip.center().y - broken_row.rect.center().y, .vertical, null);
                try dvui.testing.settle(Frame.draw);
            }
            try Frame.reveal(broken);
            try Frame.expectTab(broken, false);
            try std.testing.expect(Frame.saw_manifest_error);
            try Frame.click(broken);
            try std.testing.expect(ui.draft == null and ui.requests.items.len == 0);
            try Frame.reveal(overwritten);
            try Frame.expectTab(overwritten, true);
            // A stale selection from a renamed/deleted world cannot hide history.
            ui.selected_world = try a.dupe(u8, "renamed-folder");
            try dvui.testing.settle(Frame.draw);
            try std.testing.expect(ui.backups_expanded and dvui.tagGet(valid) != null);
            try coordinator.reserveLaunch(source.id);
            try dvui.testing.settle(Frame.draw);
            try Frame.expectTab(valid, false);
            try Frame.click(valid);
            try std.testing.expect(ui.draft == null);
            coordinator.releaseLaunch();
            Frame.controls_enabled = false;
            try dvui.testing.settle(Frame.draw);
            try Frame.expectTab(valid, false);
            Frame.controls_enabled = true;
            try dvui.testing.settle(Frame.draw);
            try Frame.click(overwritten);
            try std.testing.expect(ui.draft != null and ui.requests.items.len == 0);
            try std.testing.expectEqualStrings(overwritten_id, ui.draft.?.backup_id);
            try std.testing.expectEqualStrings("old-folder", std.mem.sliceTo(&ui.draft.?.name, 0));
            try std.testing.expect(ui.draft.?.part == .overwritten and !ui.draft.?.confirmed and !ui.draft.?.replace_backed_up);
        }
    }
}

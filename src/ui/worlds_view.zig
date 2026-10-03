//! Borrow snapshots only while drawing; apply intents after every root/modal is closed.
const std = @import("std");
const dvui = @import("dvui");
const config = @import("../core/config.zig");
const worlds = @import("../core/worlds.zig");
const worlds_manager = @import("worlds_manager.zig");
const theme = @import("theme.zig");
const A = std.mem.Allocator;
const R = dvui.Rect;
const Part = @FieldType(worlds.BackupRef, "part");
const preview_limit = 4 * 1024 * 1024;
const warning = dvui.Color.fromHex("E5BA78");
const danger = dvui.Color.fromHex("F0A6A1");

const Operation = enum { copy, rename_display, rename_folder, restore, delete };

const OwnedDirectoryOpen = struct {
    arena: std.heap.ArenaAllocator,
    source: config.Instance,
    folder: []const u8,

    fn init(a: A, source: config.Instance, folder: []const u8) !OwnedDirectoryOpen {
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const owned_source = try cloneInstance(owned, source);
        const owned_folder = try owned.dupe(u8, folder);
        return .{ .arena = arena, .source = owned_source, .folder = owned_folder };
    }

    fn deinit(self: *OwnedDirectoryOpen) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn cloneInstance(a: A, value: config.Instance) !config.Instance {
    var result = value;
    result.id = try a.dupe(u8, value.id);
    result.name = try a.dupe(u8, value.name);
    result.minecraft_version = try a.dupe(u8, value.minecraft_version);
    if (value.loader_version) |v| result.loader_version = try a.dupe(u8, v);
    if (value.java_path) |v| result.java_path = try a.dupe(u8, v);
    if (value.origin) |v| result.origin = .{ .kind = v.kind, .project_id = try a.dupe(u8, v.project_id), .version_id = try a.dupe(u8, v.version_id) };
    return result;
}

const OwnedRequest = struct {
    arena: std.heap.ArenaAllocator,
    source: config.Instance,
    value: worlds_manager.Request,

    fn init(a: A, source: config.Instance, request: worlds_manager.Request) !OwnedRequest {
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const value: worlds_manager.Request = switch (request) {
            .backup => |v| .{ .backup = try owned.dupe(u8, v) },
            .copy => |v| .{ .copy = .{ .folder = try owned.dupe(u8, v.folder), .target = try cloneInstance(owned, v.target), .target_folder = try owned.dupe(u8, v.target_folder), .confirmed = v.confirmed } },
            .rename_display => |v| .{ .rename_display = .{ .folder = try owned.dupe(u8, v.folder), .name = try owned.dupe(u8, v.name), .confirmed = v.confirmed } },
            .rename_folder => |v| .{ .rename_folder = .{ .folder = try owned.dupe(u8, v.folder), .name = try owned.dupe(u8, v.name), .confirmed = v.confirmed } },
            .restore => |v| .{ .restore = .{ .backup_id = try owned.dupe(u8, v.backup_id), .part = v.part, .target_folder = try owned.dupe(u8, v.target_folder), .confirmed = v.confirmed } },
            .delete => |v| .{ .delete = .{ .folder = try owned.dupe(u8, v.folder), .confirmed = v.confirmed } },
        };
        const owned_source = try cloneInstance(owned, source);
        return .{ .arena = arena, .source = owned_source, .value = value };
    }

    fn deinit(self: *OwnedRequest) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const Draft = struct {
    arena: std.heap.ArenaAllocator,
    operation: Operation,
    source: config.Instance,
    folder: []const u8,
    display_name: []const u8,
    backup_id: []const u8 = "",
    part: Part = .original,
    target_id: ?[]const u8 = null,
    name: [1025]u8 = @splat(0),
    name_too_long: bool = false,
    confirmed: bool = false,
    replace_backed_up: bool = false,
    open: bool = true,

    fn init(a: A, operation: Operation, source: config.Instance, folder: []const u8, display_name: []const u8, initial_name: []const u8) !Draft {
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const owned_source = try cloneInstance(owned, source);
        const owned_folder = try owned.dupe(u8, folder);
        const owned_name = try owned.dupe(u8, display_name);
        var result: Draft = .{ .arena = arena, .operation = operation, .source = owned_source, .folder = owned_folder, .display_name = owned_name };
        result.name_too_long = initial_name.len >= result.name.len;
        if (!result.name_too_long) @memcpy(result.name[0..initial_name.len], initial_name);
        return result;
    }

    fn deinit(self: *Draft) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn setTarget(self: *Draft, id: []const u8) !void {
        const owned = self.arena.allocator();
        const next = try owned.dupe(u8, id);
        if (self.target_id) |old| owned.free(old);
        self.target_id = next;
        self.confirmed = false;
        self.replace_backed_up = false;
    }

    fn request(self: *const Draft, doc: *const config.Document) !worlds_manager.Request {
        if (!self.confirmed) return error.ConfirmationRequired;
        const source = findInstance(doc, self.source.id) orelse return error.InstanceNotFound;
        if (!sameInstance(source, self.source)) return error.SelectionChanged;
        const name = std.mem.sliceTo(&self.name, 0);
        if (self.name_too_long) return error.NameTooLong;
        if (self.operation != .delete and (name.len == 0 or !std.unicode.utf8ValidateSlice(name))) return error.InvalidWorldName;
        if (self.operation != .rename_display and self.operation != .delete and !worlds.validFolder(name)) return error.UnsafeWorldName;
        return switch (self.operation) {
            .copy => blk: {
                const target = findInstance(doc, self.target_id orelse return error.TargetRequired) orelse return error.InstanceNotFound;
                if (std.mem.eql(u8, target.id, source.id)) return error.SameInstance;
                break :blk .{ .copy = .{ .folder = self.folder, .target = target, .target_folder = name, .confirmed = self.replace_backed_up } };
            },
            .rename_display => .{ .rename_display = .{ .folder = self.folder, .name = name, .confirmed = true } },
            .rename_folder => .{ .rename_folder = .{ .folder = self.folder, .name = name, .confirmed = self.replace_backed_up } },
            .restore => .{ .restore = .{ .backup_id = self.backup_id, .part = self.part, .target_folder = name, .confirmed = self.replace_backed_up } },
            .delete => .{ .delete = .{ .folder = self.folder, .confirmed = true } },
        };
    }
};

pub const Ui = struct {
    allocator: A,
    failure: ?anyerror = null,
    draft: ?Draft = null,
    selected_world: ?[]u8 = null,
    pending_select: ?[]u8 = null,
    select_queued: bool = false,
    refresh_queued: bool = false,
    cancel_queued: bool = false,
    requests: std.ArrayList(OwnedRequest) = .empty,
    synced_id: ?[]u8 = null,
    synced_name: ?[]u8 = null,
    sync_initialized: bool = false,
    directory_open: ?OwnedDirectoryOpen = null,

    pub fn init(a: A) !Ui {
        return .{ .allocator = a };
    }

    pub fn deinit(self: *Ui) void {
        self.closeDraft();
        self.releaseDirectoryOpen();
        if (self.selected_world) |v| self.allocator.free(v);
        if (self.pending_select) |v| self.allocator.free(v);
        if (self.synced_id) |v| self.allocator.free(v);
        if (self.synced_name) |v| self.allocator.free(v);
        self.releaseRequests();
        self.requests.deinit(self.allocator);
        self.* = undefined;
    }

    fn releaseDirectoryOpen(self: *Ui) void {
        if (self.directory_open) |*intent| intent.deinit();
        self.directory_open = null;
    }

    fn queueDirectoryOpen(self: *Ui, source: config.Instance, folder: []const u8) !void {
        const next = try OwnedDirectoryOpen.init(self.allocator, source, folder);
        self.releaseDirectoryOpen();
        self.directory_open = next;
    }

    fn closeDraft(self: *Ui) void {
        if (self.draft) |*draft| draft.deinit();
        self.draft = null;
    }

    fn releaseRequests(self: *Ui) void {
        for (self.requests.items) |*request| request.deinit();
        self.requests.clearRetainingCapacity();
    }

    fn queueSelect(self: *Ui, id: ?[]const u8) !void {
        const next = if (id) |v| try self.allocator.dupe(u8, v) else null;
        if (self.pending_select) |old| self.allocator.free(old);
        self.pending_select = next;
        self.select_queued = true;
    }

    fn queueRequest(self: *Ui, source: config.Instance, value: worlds_manager.Request) !void {
        var owned = try OwnedRequest.init(self.allocator, source, value);
        errdefer owned.deinit();
        try self.requests.append(self.allocator, owned);
    }

    fn selectWorld(self: *Ui, folder: []const u8) !void {
        const next = try self.allocator.dupe(u8, folder);
        if (self.selected_world) |old| self.allocator.free(old);
        self.selected_world = next;
    }

    fn openWorld(self: *Ui, operation: Operation, source: config.Instance, world: worlds.World) !void {
        const next = try Draft.init(self.allocator, operation, source, world.folder, world.displayName(), if (operation == .rename_display) world.displayName() else world.folder);
        self.closeDraft();
        self.draft = next;
        self.failure = null;
    }

    fn openBackup(self: *Ui, source: config.Instance, backup: worlds.Backup) !void {
        var next = try Draft.init(self.allocator, .restore, source, "", backup.source_folder orelse backup.id, backup.source_folder orelse self.selected_world orelse "");
        errdefer next.deinit();
        next.backup_id = try next.arena.allocator().dupe(u8, backup.id);
        next.part = backup.part;
        self.closeDraft();
        self.draft = next;
        self.failure = null;
    }
};

fn findInstance(doc: *const config.Document, id: []const u8) ?config.Instance {
    for (doc.instances) |instance| if (std.mem.eql(u8, id, instance.id)) return instance;
    return null;
}
fn selectedInstance(doc: *const config.Document) ?config.Instance {
    return findInstance(doc, doc.selected_instance orelse return null);
}
fn sameInstance(a: config.Instance, b: config.Instance) bool {
    return std.mem.eql(u8, a.id, b.id) and std.mem.eql(u8, a.name, b.name);
}
fn sameId(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |v| return if (b) |w| std.mem.eql(u8, v, w) else false;
    return b == null;
}
fn fmt(comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), format, args) catch "";
}
fn wrapped(src: std.builtin.SourceLocation, value: []const u8, color: dvui.Color) void {
    const text = dvui.textLayout(src, .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = .{ .h = 4 }, .color_text = .{ .color = color } });
    text.addText(value, .{});
    text.deinit();
}
fn line(src: std.builtin.SourceLocation, value: []const u8, color: dvui.Color) void {
    const text = dvui.textLayout(src, .{ .break_lines = false }, .{ .expand = .horizontal, .min_size_content = .{ .h = 20 }, .max_size_content = .{ .w = 0, .h = 20 }, .padding = R.all(0), .margin = R.all(0), .color_text = .{ .color = color } });
    text.addText(value, .{});
    text.deinit();
}
fn iconButton(src: std.builtin.SourceLocation, name: []const u8, asset: []const u8, enabled: bool) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{}, .{ .label = .{ .text = name }, .min_size_content = .{ .w = 16, .h = 16 }, .max_size_content = .{ .w = 16, .h = 16 }, .padding = R.all(6), .margin = .{ .x = 2 }, .corners = .all(4), .color_text = .{ .color = if (enabled) theme.accent else theme.muted } });
    if (enabled) button.processEvents();
    button.drawBackground();
    dvui.icon(src, name, asset, .{}, button.style().override(.{ .padding = R.all(0), .margin = R.all(0), .min_size_content = .{ .w = 16, .h = 16 }, .max_size_content = .{ .w = 16, .h = 16 }, .role = .none }));
    button.drawFocus();
    const clicked = enabled and button.clicked();
    const hovered = button.hovered();
    const rect = button.data().rectScale().r;
    button.deinit();
    if (hovered) dvui.tooltip(src, .{ .active_rect = rect }, "{s}", .{name}, .{ .id_extra = 1 });
    return clicked;
}
fn command(src: std.builtin.SourceLocation, label: []const u8, asset: []const u8, enabled: bool) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{}, .{ .label = .{ .text = label }, .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 }, .margin = .{ .x = 4 }, .corners = .all(4), .min_size_content = .{ .h = 20 }, .max_size_content = .height(20) });
    if (enabled) button.processEvents();
    button.drawBackground();
    const row = dvui.box(src, .{ .dir = .horizontal }, .{ .padding = R.all(0), .margin = R.all(0) });
    dvui.icon(src, label, asset, .{}, .{ .min_size_content = .{ .w = 16, .h = 16 }, .max_size_content = .{ .w = 16, .h = 16 }, .padding = R.all(0), .margin = .{ .w = 6 }, .color_text = .{ .color = if (enabled) theme.accent else theme.muted } });
    dvui.labelNoFmt(src, label, .{}, .{ .padding = R.all(0), .margin = R.all(0), .color_text = .{ .color = if (enabled) theme.accent else theme.muted } });
    row.deinit();
    button.drawFocus();
    const clicked = enabled and button.clicked();
    button.deinit();
    return clicked;
}

const Dimensions = struct { width: u32, height: u32 };
// Bound encoded and decoded storage before stb is allowed to allocate pixels.
fn pngDimensions(bytes: []const u8) !Dimensions {
    if (bytes.len > preview_limit or bytes.len < 45 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return error.InvalidPreview;
    var offset: usize = 8;
    var dimensions: ?Dimensions = null;
    var pixels = false;
    while (offset <= bytes.len - 12) {
        const length: usize = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        if (length > bytes.len - offset - 12) return error.InvalidPreview;
        const kind = bytes[offset + 4 ..][0..4];
        const payload = bytes[offset + 8 ..][0..length];
        const crc = std.mem.readInt(u32, bytes[offset + 8 + length ..][0..4], .big);
        if (std.hash.Crc32.hash(bytes[offset + 4 ..][0 .. length + 4]) != crc) return error.InvalidPreview;
        if (dimensions == null) {
            if (!std.mem.eql(u8, kind, "IHDR") or length != 13) return error.InvalidPreview;
            const width = std.mem.readInt(u32, payload[0..4], .big);
            const height = std.mem.readInt(u32, payload[4..8], .big);
            if (width == 0 or height == 0 or width > 4096 or height > 4096 or @as(u64, width) * height * 4 > preview_limit) return error.PreviewTooLarge;
            dimensions = .{ .width = width, .height = height };
        } else if (std.mem.eql(u8, kind, "IHDR")) return error.InvalidPreview;
        if (std.mem.eql(u8, kind, "IDAT") and length != 0) pixels = true;
        offset += length + 12;
        if (std.mem.eql(u8, kind, "IEND")) {
            if (length != 0 or !pixels or offset != bytes.len) return error.InvalidPreview;
            return dimensions orelse error.InvalidPreview;
        }
    }
    return error.InvalidPreview;
}
fn drawPreview(folder: []const u8, previews: []const worlds_manager.Preview, budget: *usize) void {
    const slot = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 48, .h = 48 }, .max_size_content = .{ .w = 48, .h = 48 }, .padding = R.all(0), .margin = .{ .w = 10 } });
    defer slot.deinit();
    for (previews) |preview| {
        if (!std.mem.eql(u8, preview.folder, folder)) continue;
        const dimensions = pngDimensions(preview.png) catch return;
        const required: usize = @as(usize, dimensions.width) * dimensions.height * 4;
        if (required > budget.*) return;
        budget.* -= required;
        const decoded = dvui.Color.PMAImage.fromImageFile("world-preview", dvui.currentWindow().arena(), preview.png) catch return;
        if (decoded.width != dimensions.width or decoded.height != dimensions.height or decoded.pma.len != required / 4) return;
        _ = dvui.image(@src(), .{ .source = .{ .pixelsPMA = .{ .rgba = decoded.pma, .width = decoded.width, .height = decoded.height, .invalidation = .bytes } }, .shrink = .ratio }, .{ .label = .{ .text = "世界预览" }, .min_size_content = .{ .w = 48, .h = 48 }, .max_size_content = .{ .w = 48, .h = 48 }, .padding = R.all(0), .margin = R.all(0) });
        return;
    }
}

fn sidebarEnabled(ui: *const Ui, snapshot: worlds_manager.Snapshot, enabled: bool) bool {
    return enabled and !snapshot.worker_active and ui.draft == null and !ui.select_queued and
        ui.requests.items.len == 0 and ui.directory_open == null and !ui.refresh_queued and !ui.cancel_queued;
}

fn queueSidebarSelect(ui: *Ui, id: []const u8, snapshot: worlds_manager.Snapshot, enabled: bool) !void {
    if (sidebarEnabled(ui, snapshot, enabled)) try ui.queueSelect(id);
}

fn sidebarRow(src: std.builtin.SourceLocation, instance: config.Instance, selected: bool, enabled: bool) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{ .grayed = !enabled, .draw_focus = enabled }, .{ .id_extra = @as(usize, @truncate(std.hash.Wyhash.hash(0, instance.id))), .label = .{ .text = instance.name }, .expand = .horizontal, .max_size_content = .width(0), .min_size_content = .{ .h = 20 }, .padding = R.all(6), .margin = .{ .h = 4 }, .corners = .all(4), .style = if (selected) .highlight else .control, .tab_index = if (enabled) null else 0 });
    defer button.deinit();
    if (enabled) button.processEvents();
    button.drawBackground();
    const label = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .{ .w = 0, .h = 40 }, .min_size_content = .{ .h = 20 }, .padding = R.all(0), .margin = R.all(0) });
    label.addText(instance.name, .{});
    label.deinit();
    if (enabled) button.drawFocus();
    if (button.hovered()) dvui.tooltip(src, .{ .active_rect = button.data().rectScale().r }, "{s}", .{instance.name}, .{ .id_extra = 1 });
    return enabled and button.clicked();
}

pub fn drawSidebar(ui: *Ui, doc: *const config.Document, manager: *worlds_manager.Manager, enabled: bool) void {
    const snapshot = manager.snapshot();
    const allowed = sidebarEnabled(ui, snapshot, enabled);
    const scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .expand = .both, .padding = R.all(0), .margin = R.all(0), .background = false });
    defer scroll.deinit();
    if (doc.instances.len == 0) wrapped(@src(), "尚无实例", theme.muted);
    for (doc.instances) |instance| {
        const selected = sameId(doc.selected_instance, instance.id);
        if (sidebarRow(@src(), instance, selected, allowed) and !selected) queueSidebarSelect(ui, instance.id, snapshot, enabled) catch |err| {
            ui.failure = err;
        };
    }
}

fn drawHeader(ui: *Ui, doc: *const config.Document, snapshot: worlds_manager.Snapshot, enabled: bool) void {
    const header = dvui.box(@src(), .{}, .{ .expand = .horizontal, .padding = R.all(0), .margin = .{ .h = 8 } });
    defer header.deinit();
    wrapped(@src(), if (selectedInstance(doc)) |instance| fmt("{s} · 存档", .{instance.name}) else "存档", dvui.themeGet().text);
    const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = R.all(0), .margin = R.all(0) });
    defer actions.deinit();
    if (iconButton(@src(), "刷新世界与恢复记录", dvui.entypo.cw, enabled and !snapshot.worker_active and snapshot.instance != null and !ui.select_queued and ui.draft == null)) ui.refresh_queued = true;
    if (iconButton(@src(), "取消当前任务", dvui.entypo.cross, enabled and snapshot.worker_active)) ui.cancel_queued = true;
}
fn drawOutcome(outcome: *const worlds.Outcome) void {
    const color = switch (outcome.state) {
        .committed => theme.accent,
        .rolled_back => warning,
        .uncertain => danger,
    };
    wrapped(@src(), switch (outcome.state) {
        .committed => "已提交",
        .rolled_back => "操作已回滚",
        .uncertain => "提交状态不确定，请检查保留路径",
    }, color);
    if (outcome.cause) |err| wrapped(@src(), fmt("原因：{s}", .{@errorName(err)}), color);
    wrapped(@src(), fmt("恢复路径：{s}", .{outcome.recovery_directory}), theme.muted);
    if (outcome.staging_directory) |path| wrapped(@src(), fmt("暂存路径：{s}", .{path}), color);
}

/// Draw only borrows Store/Manager snapshots and queues owned intents.
/// Draw the modal separately after the page root has closed.
pub fn draw(ui: *Ui, doc: *const config.Document, manager: *worlds_manager.Manager) !void {
    try drawWithEnabled(ui, doc, manager, true);
}

pub fn drawWithEnabled(ui: *Ui, doc: *const config.Document, manager: *worlds_manager.Manager, controls_enabled: bool) !void {
    const snapshot = manager.snapshot();
    const root = dvui.box(@src(), .{}, .{ .expand = .both, .padding = R.all(0), .margin = R.all(0) });
    defer root.deinit();
    drawHeader(ui, doc, snapshot, controls_enabled);
    const scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .expand = .both, .padding = R.all(0), .margin = R.all(0) });
    defer scroll.deinit();
    if (ui.failure) |err| wrapped(@src(), fmt("操作失败：{s}", .{@errorName(err)}), danger);
    if (snapshot.failure) |err| wrapped(@src(), fmt("任务失败：{s}", .{@errorName(err)}), danger);
    if (snapshot.outcome) |outcome| drawOutcome(outcome);
    if (snapshot.worker_active) wrapped(@src(), if (snapshot.loading) "正在读取世界与恢复记录…" else "世界任务进行中…", theme.muted);
    const source = snapshot.instance orelse {
        wrapped(@src(), if (doc.instances.len == 0) "尚无实例" else "未选择实例", theme.muted);
        return;
    };
    const desired = selectedInstance(doc);
    const current = if (desired) |v| sameInstance(v, source) else false;
    const running = manager.isRunning(source.id);
    if (running) wrapped(@src(), "实例正在运行，世界操作已锁定", warning);
    if (!current) {
        wrapped(@src(), "正在切换实例…", theme.muted);
        return;
    }
    const enabled = controls_enabled and current and !running and !snapshot.worker_active and !ui.select_queued and ui.draft == null;
    var budget: usize = preview_limit;
    if (snapshot.worlds.len == 0 and !snapshot.loading) wrapped(@src(), "此实例暂无世界", theme.muted);
    for (snapshot.worlds, 0..) |world, index| {
        const row = dvui.box(@src(), .{}, .{ .id_extra = index, .expand = .horizontal, .min_size_content = .{ .h = 124 }, .max_size_content = .height(124), .padding = .{ .y = 6, .h = 6 }, .margin = R.all(0) });
        {
            const details = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = R.all(0), .margin = R.all(0) });
            drawPreview(world.folder, snapshot.previews, &budget);
            const text = dvui.box(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = R.all(0) });
            line(@src(), world.displayName(), if (sameId(ui.selected_world, world.folder)) theme.accent else dvui.Color.fromHex("EDF1EA"));
            line(@src(), fmt("文件夹：{s}", .{world.folder}), theme.muted);
            line(@src(), fmt("版本：{s}", .{world.metadata.version_name orelse "未知"}), theme.muted);
            if (world.metadata.last_played_ms) |ms| line(@src(), fmt("最后游玩：{s}", .{timestamp(ms)}), theme.muted) else line(@src(), "最后游玩：未知", theme.muted);
            text.deinit();
            details.deinit();
        }
        {
            const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = R.all(0), .margin = R.all(0) });
            if (iconButton(@src(), "选择世界", dvui.entypo.check, controls_enabled and ui.draft == null and current and !ui.select_queued)) ui.selectWorld(world.folder) catch |err| {
                ui.failure = err;
            };
            if (iconButton(@src(), "备份世界", dvui.entypo.archive, enabled)) ui.queueRequest(source, .{ .backup = world.folder }) catch |err| {
                ui.failure = err;
            };
            if (iconButton(@src(), "复制到其他实例", dvui.entypo.documents, enabled and doc.instances.len > 1)) ui.openWorld(.copy, source, world) catch |err| {
                ui.failure = err;
            };
            if (iconButton(@src(), "修改世界显示名称", dvui.entypo.pencil, enabled)) ui.openWorld(.rename_display, source, world) catch |err| {
                ui.failure = err;
            };
            if (iconButton(@src(), "修改世界文件夹名", dvui.entypo.folder, enabled)) ui.openWorld(.rename_folder, source, world) catch |err| {
                ui.failure = err;
            };
            if (iconButton(@src(), "打开世界目录", dvui.entypo.folder, controls_enabled and current and !ui.select_queued and ui.draft == null)) ui.queueDirectoryOpen(source, world.folder) catch |err| {
                ui.failure = err;
            };
            if (iconButton(@src(), "删除世界", dvui.entypo.trash, enabled)) ui.openWorld(.delete, source, world) catch |err| {
                ui.failure = err;
            };
            actions.deinit();
        }
        row.deinit();
        _ = dvui.separator(@src(), .{ .id_extra = index, .expand = .horizontal, .padding = R.all(0), .margin = R.all(0) });
    }
    wrapped(@src(), fmt("恢复记录 · {d}", .{snapshot.backups.len}), theme.accent);
    for (snapshot.backups, 0..) |backup, index| {
        const row = dvui.box(@src(), .{}, .{ .id_extra = index, .expand = .horizontal, .min_size_content = .{ .h = 100 }, .max_size_content = .height(100), .padding = .{ .y = 6, .h = 6 }, .margin = R.all(0) });
        line(@src(), fmt("{s} · {s}", .{ backup.source_folder orelse "来源未知", if (backup.part == .original) "原始数据" else "被替换数据" }), theme.muted);
        line(@src(), fmt("{s} · {s}", .{ backup.id, timestamp(backup.created_ms) }), theme.muted);
        if (backup.manifest_error) |err| line(@src(), fmt("清单不可用：{s}", .{@errorName(err)}), danger) else line(@src(), operationText(backup.operation), theme.muted);
        if (iconButton(@src(), "恢复此份数据", dvui.entypo.ccw, enabled and backup.manifest_error == null)) ui.openBackup(source, backup) catch |err| {
            ui.failure = err;
        };
        row.deinit();
        _ = dvui.separator(@src(), .{ .id_extra = index + snapshot.worlds.len, .expand = .horizontal, .padding = R.all(0), .margin = R.all(0) });
    }
}
fn operationText(operation: ?worlds.Operation) []const u8 {
    return if (operation) |value| switch (value) {
        .backup => "世界备份",
        .restore => "恢复前数据",
        .copy => "复制前数据",
        .rename => "文件夹重命名前数据",
        .rename_display_name => "显示名称修改前数据",
        .delete => "删除前数据",
    } else "来源未知";
}
fn timestamp(ms: i64) []const u8 {
    if (ms < 0) return fmt("{d} ms", .{ms});
    const seconds: u64 = @intCast(@divTrunc(ms, 1000));
    if (seconds > 253402300799) return fmt("{d} ms", .{ms});
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const day = epoch.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    return fmt("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{ day.year, @intFromEnum(month.month), month.day_index + 1, time.getHoursIntoDay(), time.getMinutesIntoHour() });
}
fn title(operation: Operation) []const u8 {
    return switch (operation) {
        .copy => "复制世界",
        .rename_display => "修改显示名称",
        .rename_folder => "修改文件夹名",
        .restore => "恢复世界",
        .delete => "删除世界",
    };
}
fn draftBlocked(draft: *const Draft, doc: *const config.Document, manager: *worlds_manager.Manager) ?anyerror {
    const snapshot = manager.snapshot();
    if (snapshot.worker_active) return error.Busy;
    const current = snapshot.instance orelse return error.SelectionChanged;
    const selected = selectedInstance(doc) orelse return error.SelectionChanged;
    if (!sameInstance(draft.source, current) or !sameInstance(draft.source, selected)) return error.SelectionChanged;
    if (manager.isRunning(draft.source.id)) return error.InstanceRunning;
    if (draft.operation == .copy) {
        if (draft.target_id) |id| {
            _ = findInstance(doc, id) orelse return error.InstanceNotFound;
            if (manager.isRunning(id)) return error.InstanceRunning;
        } else return error.TargetRequired;
    }
    return null;
}

/// Call outside the page root. Only Ui-owned drafts are retained across frames.
pub fn drawModal(ui: *Ui, doc: *const config.Document, manager: *worlds_manager.Manager) !void {
    if (ui.draft == null) return;
    var submitted = false;
    const draft = &ui.draft.?;
    const window = dvui.windowRect();
    const width = @max(0, @min(460, window.w - 24));
    const height = @max(0, @min(370, window.h - 24));
    {
        const modal = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &draft.open, .resize = .none, .window_avoid = .none }, .{ .rect = .{ .x = window.x + (window.w - width) / 2, .y = window.y + (window.h - height) / 2, .w = width, .h = height }, .min_size_content = .{ .w = @max(0, width - 26), .h = @max(0, height - 26) }, .max_size_content = .{ .w = @max(0, width - 26), .h = @max(0, height - 26) }, .padding = R.all(12), .margin = R.all(0), .border = R.all(1), .corners = .all(8), .label = .{ .text = title(draft.operation) } });
        defer modal.deinit();
        modal.dragAreaSet(dvui.windowHeader(title(draft.operation), "", &draft.open));
        const scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .expand = .both, .padding = R.all(0), .margin = R.all(0) });
        defer scroll.deinit();
        wrapped(@src(), fmt("世界：{s}", .{draft.display_name}), theme.accent);
        wrapped(@src(), fmt("源实例：{s}", .{draft.source.name}), theme.muted);
        if (draft.operation == .restore) {
            wrapped(@src(), fmt("恢复记录：{s} · {s}", .{ draft.backup_id, if (draft.part == .original) "原始数据" else "被替换数据" }), theme.muted);
        } else wrapped(@src(), fmt("文件夹：{s}", .{draft.folder}), theme.muted);
        if (draft.operation == .copy) {
            const a = dvui.currentWindow().arena();
            const labels = try a.alloc([]const u8, doc.instances.len + 1);
            const ids = try a.alloc(?[]const u8, doc.instances.len + 1);
            labels[0] = "选择目标实例";
            ids[0] = null;
            var count: usize = 1;
            var selected: usize = 0;
            for (doc.instances) |instance| {
                if (std.mem.eql(u8, instance.id, draft.source.id)) continue;
                labels[count] = instance.name;
                ids[count] = instance.id;
                if (sameId(draft.target_id, instance.id)) selected = count;
                count += 1;
            }
            dvui.labelNoFmt(@src(), "目标实例", .{}, .{ .padding = R.all(0), .margin = .{ .h = 4 } });
            var choice: ?usize = selected;
            if (dvui.dropdown(@src(), labels[0..count], .{ .choice_nullable = &choice }, .{ .placeholder = "选择目标实例", .null_selectable = false }, .{ .label = .{ .text = "目标实例" }, .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(6), .corners = .all(4) })) {
                const index = choice orelse 0;
                if (ids[index]) |id| try draft.setTarget(id) else {
                    draft.target_id = null;
                    draft.confirmed = false;
                    draft.replace_backed_up = false;
                }
            }
        }
        if (draft.operation != .delete) {
            const label = if (draft.operation == .rename_display) "新显示名称" else if (draft.operation == .rename_folder) "新文件夹名" else "目标世界文件夹";
            dvui.labelNoFmt(@src(), label, .{}, .{ .padding = R.all(0), .margin = .{ .y = 6, .h = 4 } });
            const input = dvui.textEntry(@src(), .{ .text = .{ .buffer = &draft.name } }, .{ .label = .{ .text = label }, .expand = .horizontal, .max_size_content = .width(0), .min_size_content = .{ .h = 20 }, .padding = R.all(6), .margin = .{ .h = 4 }, .corners = .all(4) });
            if (input.text_changed) {
                draft.confirmed = false;
                draft.replace_backed_up = false;
                draft.name_too_long = false;
            }
            input.deinit();
        }
        if (draft.name_too_long) wrapped(@src(), "名称过长，请重新输入", danger);
        if (draft.operation == .copy or draft.operation == .restore or draft.operation == .rename_folder) {
            _ = dvui.checkbox(@src(), &draft.replace_backed_up, "目标存在时，先备份再替换", .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = .{ .y = 6, .h = 6 } });
        }
        if (draft.operation == .delete) wrapped(@src(), "世界将从 saves 移除，删除前数据保留在恢复记录中。", warning);
        _ = dvui.checkbox(@src(), &draft.confirmed, switch (draft.operation) {
            .delete => "确认删除此世界",
            .rename_display => "确认修改显示名称并保留恢复数据",
            .rename_folder => "确认修改文件夹名并保留恢复数据",
            .copy => "确认复制到所选目标",
            .restore => "确认恢复所选数据",
        }, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = .{ .y = 4, .h = 8 } });
        const blocked = draftBlocked(draft, doc, manager);
        if (blocked) |err| wrapped(@src(), fmt("暂不可执行：{s}", .{@errorName(err)}), warning);
        if (ui.failure) |err| wrapped(@src(), fmt("操作失败：{s}", .{@errorName(err)}), danger);
        const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = R.all(0), .margin = R.all(0) });
        defer actions.deinit();
        if (command(@src(), "取消", dvui.entypo.cross, true)) draft.open = false;
        if (command(@src(), "确认", dvui.entypo.check, blocked == null and draft.confirmed and !ui.select_queued)) {
            const request = draft.request(doc) catch |err| {
                ui.failure = err;
                return;
            };
            ui.queueRequest(draft.source, request) catch |err| {
                ui.failure = err;
                return;
            };
            submitted = true;
        }
    }
    if (submitted or !draft.open) ui.closeDraft();
}

fn syncSelection(ui: *Ui, store: *config.Store, manager: *worlds_manager.Manager) !void {
    const desired = selectedInstance(store.snapshot());
    const id: ?[]const u8 = if (desired) |v| v.id else null;
    const name: ?[]const u8 = if (desired) |v| v.name else null;
    if (ui.sync_initialized and sameId(ui.synced_id, id) and sameId(ui.synced_name, name)) return;
    const snapshot = manager.snapshot();
    const next_id = if (id) |v| try ui.allocator.dupe(u8, v) else null;
    errdefer if (next_id) |v| ui.allocator.free(v);
    const next_name = if (name) |v| try ui.allocator.dupe(u8, v) else null;
    errdefer if (next_name) |v| ui.allocator.free(v);
    const matches = if (desired) |v| if (snapshot.instance) |current| sameInstance(v, current) else false else snapshot.instance == null;
    const changed = ui.sync_initialized or !matches;
    if (!matches) try manager.select(desired);
    if (ui.synced_id) |old| ui.allocator.free(old);
    if (ui.synced_name) |old| ui.allocator.free(old);
    ui.synced_id = next_id;
    ui.synced_name = next_name;
    ui.sync_initialized = true;
    if (changed) {
        if (ui.selected_world) |old| ui.allocator.free(old);
        ui.selected_world = null;
        ui.closeDraft();
    }
}
fn applyRequest(owned: *const OwnedRequest, store: *config.Store, manager: *worlds_manager.Manager) !void {
    const selected = selectedInstance(store.snapshot()) orelse return error.SelectionChanged;
    const snapshot = manager.snapshot();
    const current = snapshot.instance orelse return error.SelectionChanged;
    if (!sameInstance(owned.source, selected) or !sameInstance(owned.source, current)) return error.SelectionChanged;
    if (manager.isRunning(owned.source.id)) return error.InstanceRunning;
    if (owned.value == .copy) {
        const target = findInstance(store.snapshot(), owned.value.copy.target.id) orelse return error.InstanceNotFound;
        if (!sameInstance(target, owned.value.copy.target)) return error.SelectionChanged;
        if (manager.isRunning(target.id)) return error.InstanceRunning;
    }
    try manager.perform(owned.value);
}

/// Call only AFTER ALL root widgets and floating windows have been closed.
/// Every queued request is released even when Store/Manager rejects it; never auto-retry.
pub fn finish(ui: *Ui, store: *config.Store, manager: *worlds_manager.Manager) void {
    defer ui.releaseRequests();
    defer ui.releaseDirectoryOpen();
    const refresh = ui.refresh_queued;
    ui.refresh_queued = false;
    if (ui.cancel_queued) {
        ui.cancel_queued = false;
        manager.cancel();
    }
    if (ui.select_queued) {
        ui.select_queued = false;
        defer {
            if (ui.pending_select) |id| ui.allocator.free(id);
            ui.pending_select = null;
        }
        var document = store.snapshot().*;
        if (ui.pending_select) |id| {
            const instance = findInstance(&document, id) orelse {
                ui.failure = error.InstanceNotFound;
                return;
            };
            document.selected_instance = instance.id;
        } else document.selected_instance = null;
        store.update(document) catch |err| {
            ui.failure = err;
            return;
        };
    }
    syncSelection(ui, store, manager) catch |err| {
        ui.failure = err;
        return;
    };
    if (refresh) {
        manager.refresh() catch |err| {
            ui.failure = err;
        };
    }
    for (ui.requests.items) |*request| {
        applyRequest(request, store, manager) catch |err| {
            ui.failure = err;
            continue;
        };
        ui.failure = null;
    }
    if (ui.directory_open) |*intent| {
        const selected = selectedInstance(store.snapshot()) orelse {
            ui.failure = error.SelectionChanged;
            return;
        };
        if (!sameInstance(intent.source, selected)) {
            ui.failure = error.SelectionChanged;
            return;
        }
        const uri = manager.worldDirectoryUri(intent.source, intent.folder) catch |err| {
            ui.failure = err;
            return;
        };
        defer manager.allocator.free(uri);
        // dvui.openURL only allows HTTP(S); the SDL backend supports file URIs.
        dvui.currentWindow().backend.openURL(uri, true) catch |err| {
            ui.failure = err;
            return;
        };
        ui.failure = null;
    }
}

test "world view owns deferred selection and request strings" {
    const a = std.testing.allocator;
    var ui = try Ui.init(a);
    defer ui.deinit();
    var id = [_]u8{ 'i', 'd' };
    try ui.queueSelect(&id);
    id[0] = 'x';
    try std.testing.expectEqualStrings("id", ui.pending_select.?);
    try std.testing.expect(ui.select_queued);
    var folder = [_]u8{ 'm', 'a', 'p' };
    const source: config.Instance = .{ .id = "exact-id", .name = "different-folder", .minecraft_version = "1.21" };
    try ui.queueRequest(source, .{ .backup = &folder });
    folder[0] = 'x';
    try std.testing.expectEqualStrings("map", ui.requests.items[0].value.backup);
    try std.testing.expectEqualStrings("exact-id", ui.requests.items[0].source.id);
    try std.testing.expectEqualStrings("different-folder", ui.requests.items[0].source.name);
    ui.releaseRequests();
    try std.testing.expectEqual(@as(usize, 0), ui.requests.items.len);
}

test "modal consent never implies collision replacement" {
    const a = std.testing.allocator;
    const source: config.Instance = .{ .id = "source", .name = "source-folder", .minecraft_version = "1.21" };
    const target: config.Instance = .{ .id = "target", .name = "target-folder", .minecraft_version = "1.21" };
    const doc: config.Document = .{ .instances = &.{ source, target }, .selected_instance = source.id };
    var draft = try Draft.init(a, .copy, source, "world", "显示名称", "world-copy");
    defer draft.deinit();
    try draft.setTarget(target.id);
    try std.testing.expectError(error.ConfirmationRequired, draft.request(&doc));
    draft.confirmed = true;
    try std.testing.expect(!(try draft.request(&doc)).copy.confirmed);
    draft.replace_backed_up = true;
    try std.testing.expect((try draft.request(&doc)).copy.confirmed);
    try draft.setTarget(target.id);
    try std.testing.expect(!draft.confirmed and !draft.replace_backed_up);
    var rename = try Draft.init(a, .rename_folder, source, "world", "世界", "renamed");
    defer rename.deinit();
    rename.confirmed = true;
    try std.testing.expect(!(try rename.request(&doc)).rename_folder.confirmed);
    rename.replace_backed_up = true;
    try std.testing.expect((try rename.request(&doc)).rename_folder.confirmed);
}

test "delete requires explicit modal consent and restore preserves payload part" {
    const a = std.testing.allocator;
    const source: config.Instance = .{ .id = "exact", .name = "folder", .minecraft_version = "1.21" };
    const doc: config.Document = .{ .instances = &.{source}, .selected_instance = source.id };
    var draft = try Draft.init(a, .delete, source, "world", "世界", "");
    defer draft.deinit();
    try std.testing.expectError(error.ConfirmationRequired, draft.request(&doc));
    draft.confirmed = true;
    try std.testing.expect((try draft.request(&doc)).delete.confirmed);
    var restore = try Draft.init(a, .restore, source, "", "world", "world");
    defer restore.deinit();
    restore.part = .overwritten;
    restore.backup_id = "recovery";
    restore.confirmed = true;
    const request = try restore.request(&doc);
    try std.testing.expect(request.restore.part == .overwritten);
    try std.testing.expect(!request.restore.confirmed);
}

test "preview rejects malformed bytes before decoder allocation" {
    try std.testing.expectError(error.InvalidPreview, pngDimensions("not an image"));
    var png: [45]u8 = @splat(0);
    @memcpy(png[0..8], "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, png[8..12], 13, .big);
    @memcpy(png[12..16], "IHDR");
    std.mem.writeInt(u32, png[16..20], 4097, .big);
    std.mem.writeInt(u32, png[20..24], 1, .big);
    std.mem.writeInt(u32, png[29..33], std.hash.Crc32.hash(png[12..29]), .big);
    try std.testing.expectError(error.PreviewTooLarge, pngDimensions(&png));
    std.mem.writeInt(u32, png[16..20], 4096, .big);
    std.mem.writeInt(u32, png[20..24], 4096, .big);
    std.mem.writeInt(u32, png[29..33], std.hash.Crc32.hash(png[12..29]), .big);
    try std.testing.expectError(error.PreviewTooLarge, pngDimensions(&png));
}

test "world directory intents own source and folder until finish" {
    var ui = try Ui.init(std.testing.allocator);
    defer ui.deinit();
    var id = "instance-id".*;
    var name = "instance-folder".*;
    var folder = "World".*;
    try ui.queueDirectoryOpen(.{ .id = &id, .name = &name, .minecraft_version = "1.21" }, &folder);
    @memset(&id, 'x');
    @memset(&name, 'x');
    @memset(&folder, 'x');
    try std.testing.expectEqualStrings("instance-id", ui.directory_open.?.source.id);
    try std.testing.expectEqualStrings("instance-folder", ui.directory_open.?.source.name);
    try std.testing.expectEqualStrings("World", ui.directory_open.?.folder);
    try ui.queueDirectoryOpen(.{ .id = "next", .name = "Next", .minecraft_version = "1.21" }, "Other");
    try std.testing.expectEqualStrings("Other", ui.directory_open.?.folder);
    ui.releaseDirectoryOpen();
    try std.testing.expect(ui.directory_open == null);
    try ui.queueDirectoryOpen(.{ .id = "pending", .name = "Pending", .minecraft_version = "1.21" }, "Pending world");
}

test "world directory intent allocation failures retain previous intent and release arenas" {
    const Fixture = struct {
        fn run(a: A) !void {
            var ui = try Ui.init(a);
            defer ui.deinit();
            const source: config.Instance = .{ .id = "instance", .name = "Instance", .minecraft_version = "1.21" };
            try ui.queueDirectoryOpen(source, "World");
            ui.queueDirectoryOpen(source, "Replacement") catch |err| {
                try std.testing.expectEqualStrings("World", ui.directory_open.?.folder);
                return err;
            };
            try std.testing.expectEqualStrings("Replacement", ui.directory_open.?.folder);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Fixture.run, .{});
}

test "world sidebar owns stable queued ID and selected right model rejects stale snapshot" {
    const a = std.testing.allocator;
    var ui = try Ui.init(a);
    defer ui.deinit();
    var id = "stable-b".*;
    try queueSidebarSelect(&ui, &id, .{}, true);
    @memset(&id, 'x');
    try std.testing.expect(ui.select_queued);
    try std.testing.expectEqualStrings("stable-b", ui.pending_select.?);
    var rows = [_]config.Instance{
        .{ .id = "stable-a", .name = "First", .minecraft_version = "1.20" },
        .{ .id = "stable-b", .name = "Second", .minecraft_version = "1.21" },
    };
    var doc: config.Document = .{ .instances = &rows, .selected_instance = "stable-a" };
    const previous = selectedInstance(&doc).?;
    std.mem.swap(config.Instance, &rows[0], &rows[1]);
    doc.selected_instance = findInstance(&doc, ui.pending_select.?).?.id;
    const desired = selectedInstance(&doc).?;
    try std.testing.expectEqualStrings("Second", desired.name);
    try std.testing.expect(!sameInstance(previous, desired));
    try std.testing.expect(sameInstance(rows[0], desired));
    rows[0].name = "Renamed";
    try std.testing.expect(!sameInstance(desired, selectedInstance(&doc).?));
    doc.selected_instance = "missing";
    try std.testing.expect(selectedInstance(&doc) == null);
}

test "world sidebar respects disabled draft worker and queued intent gates" {
    const a = std.testing.allocator;
    var ui = try Ui.init(a);
    defer ui.deinit();
    const source: config.Instance = .{ .id = "source", .name = "Source", .minecraft_version = "1.21" };
    try ui.selectWorld("Preserved world");
    try queueSidebarSelect(&ui, "other", .{}, false);
    try queueSidebarSelect(&ui, "other", .{ .worker_active = true }, true);
    try std.testing.expect(!ui.select_queued and ui.pending_select == null);
    ui.draft = try Draft.init(a, .delete, source, "world", "World", "");
    try queueSidebarSelect(&ui, "other", .{}, true);
    try std.testing.expect(!ui.select_queued and ui.draft != null);
    ui.closeDraft();
    ui.refresh_queued = true;
    try queueSidebarSelect(&ui, "other", .{}, true);
    ui.refresh_queued = false;
    ui.cancel_queued = true;
    try queueSidebarSelect(&ui, "other", .{}, true);
    ui.cancel_queued = false;
    try ui.queueDirectoryOpen(source, "world");
    try queueSidebarSelect(&ui, "other", .{}, true);
    try std.testing.expect(!ui.select_queued and ui.directory_open != null);
    ui.releaseDirectoryOpen();
    try ui.queueRequest(source, .{ .backup = "world" });
    try queueSidebarSelect(&ui, "other", .{}, true);
    try std.testing.expect(!ui.select_queued and ui.requests.items.len == 1);
    ui.releaseRequests();
    try queueSidebarSelect(&ui, "first", .{}, true);
    try queueSidebarSelect(&ui, "second", .{}, true);
    try std.testing.expectEqualStrings("first", ui.pending_select.?);
    try std.testing.expectEqualStrings("Preserved world", ui.selected_world.?);
}

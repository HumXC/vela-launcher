//! Borrow snapshots only while drawing; apply intents after every root/modal is closed.
const std = @import("std");
const dvui = @import("dvui");
const config = @import("../core/config.zig");
const worlds = @import("../core/worlds.zig");
const worlds_manager = @import("../application/worlds_manager.zig");
const local_time = @import("local_time.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const card_grid = @import("card_grid.zig");
const A = std.mem.Allocator;
const R = dvui.Rect;
const Part = @FieldType(worlds.BackupRef, "part");
const preview_limit = 4 * 1024 * 1024;

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
    backups_expanded: bool = false,
    pending_select: ?[]u8 = null,
    select_queued: bool = false,
    refresh_queued: bool = false,
    cancel_queued: bool = false,
    draft_action: components.FormAction = .none,
    requests: std.ArrayList(OwnedRequest) = .empty,
    synced_id: ?[]u8 = null,
    synced_name: ?[]u8 = null,
    sync_initialized: bool = false,
    page_active: bool = false,
    entry_refresh_pending: bool = false,
    directory_open: ?OwnedDirectoryOpen = null,

    pub fn init(a: A) !Ui {
        return .{ .allocator = a };
    }

    /// Record the visible route every frame, even when service dispatch is gated.
    pub fn setPageActive(self: *Ui, active: bool) void {
        if (active and !self.page_active) self.entry_refresh_pending = true;
        if (!active) self.entry_refresh_pending = false;
        self.page_active = active;
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

    fn queueDraft(self: *Ui, doc: *const config.Document) !void {
        const draft = &(self.draft orelse return error.NoDraft);
        const request = try draft.request(doc);
        try self.queueRequest(draft.source, request);
        self.draft_action = .save;
    }

    fn finishDraft(self: *Ui, action: components.FormAction, accepted: bool) void {
        if (action == .cancel or (action == .save and accepted)) {
            self.closeDraft();
            self.failure = null;
        }
    }

    fn selectWorld(self: *Ui, folder: []const u8) !void {
        if (sameId(self.selected_world, folder)) return;
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
        if (!backupRestorable(backup)) return error.InvalidManifest;
        const folder = backup.source_folder.?;
        var next = try Draft.init(self.allocator, .restore, source, "", folder, folder);
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
fn previewSource(folder: []const u8, previews: []const worlds_manager.Preview, budget: *usize) ?dvui.ImageSource {
    for (previews) |preview| {
        if (!std.mem.eql(u8, preview.folder, folder)) continue;
        const dimensions = pngDimensions(preview.png) catch return null;
        const required: usize = @as(usize, dimensions.width) * dimensions.height * 4;
        if (required > budget.*) return null;
        budget.* -= required;
        const decoded = dvui.Color.PMAImage.fromImageFile("world-preview", dvui.currentWindow().arena(), preview.png) catch return null;
        if (decoded.width != dimensions.width or decoded.height != dimensions.height or decoded.pma.len != required / 4) return null;
        return .{ .pixelsPMA = .{ .rgba = decoded.pma, .width = decoded.width, .height = decoded.height, .invalidation = .bytes } };
    }
    return null;
}

fn sidebarEnabled(ui: *const Ui, snapshot: worlds_manager.Snapshot, enabled: bool) bool {
    return enabled and !snapshot.worker_active and ui.draft == null and !ui.select_queued and
        ui.requests.items.len == 0 and ui.directory_open == null and !ui.refresh_queued and !ui.cancel_queued;
}

fn queueSidebarSelect(ui: *Ui, id: []const u8, snapshot: worlds_manager.Snapshot, enabled: bool) !void {
    if (sidebarEnabled(ui, snapshot, enabled)) try ui.queueSelect(id);
}

pub fn drawSidebar(ui: *Ui, doc: *const config.Document, manager: *worlds_manager.Manager, enabled: bool) void {
    const snapshot = manager.snapshot();
    const allowed = sidebarEnabled(ui, snapshot, enabled);
    const scroll = components.scrollBody(@src());
    defer scroll.deinit();
    if (doc.instances.len == 0) components.emptyState(@src(), "尚无实例");
    for (doc.instances) |instance| {
        const selected = sameId(doc.selected_instance, instance.id);
        if (components.sidebarItem(@src(), instance.id, instance.name, .{ .selected = selected, .enabled = allowed }) and !selected) queueSidebarSelect(ui, instance.id, snapshot, enabled) catch |err| {
            ui.failure = err;
        };
    }
}

fn drawHeader(ui: *Ui, doc: *const config.Document, snapshot: worlds_manager.Snapshot, enabled: bool) void {
    const header = dvui.box(@src(), .{}, .{ .expand = .horizontal, .padding = R.all(0), .margin = .{ .h = if (dvui.windowRect().h < theme.style.layout.compact_height) theme.spacing.row_gap else theme.spacing.page_title_gap }, .background = false });
    defer header.deinit();
    const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = R.all(0), .margin = R.all(0), .background = false });
    {
        const heading = dvui.box(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .background = false });
        components.title(@src(), "存档");
        if (selectedInstance(doc)) |instance| {
            const subtitle = fmt("{s} · {d} 个存档", .{ instance.name, snapshot.worlds.len });
            if (header.data().contentRect().w < theme.style.layout.world_compact_width)
                components.hint(@src(), subtitle)
            else
                components.text(@src(), subtitle, theme.colors.muted);
        }
        heading.deinit();
    }
    if (components.button(@src(), "刷新", .{ .standalone = true, .icon = dvui.entypo.cw, .tag = "world-refresh", .placement = .footer, .enabled = enabled and !snapshot.worker_active and snapshot.instance != null and !ui.select_queued and ui.draft == null })) ui.refresh_queued = true;
    actions.deinit();
    if (snapshot.worker_active) {
        const task = components.toolbar(@src());
        defer task.deinit();
        components.text(@src(), if (snapshot.loading) "正在读取存档…" else "正在处理存档…", theme.colors.muted);
        if (components.iconButton(@src(), "取消当前任务", dvui.entypo.cross, .{ .standalone = true, .tag = "world-cancel", .enabled = enabled })) ui.cancel_queued = true;
    }
}

/// Draw only borrows Store/Manager snapshots and queues owned intents.
/// Draw the modal separately after the page root has closed.
pub fn draw(ui: *Ui, doc: *const config.Document, manager: *worlds_manager.Manager) !void {
    try drawWithEnabled(ui, doc, manager, true);
}

fn worldMode(world: worlds.World) []const u8 {
    if (world.metadata.hardcore orelse false) return "极限模式";
    return switch (world.metadata.game_type orelse -1) {
        0 => "生存模式",
        1 => "创造模式",
        2 => "冒险模式",
        3 => "旁观模式",
        else => "游戏模式未知",
    };
}
fn worldStatus(world: worlds.World) ?[]const u8 {
    return switch (world.access) {
        .in_use => "正在游玩",
        .unavailable => "无法确认使用状态",
        .available => if (world.metadata_status != .valid) "存档信息无法读取" else null,
    };
}
fn failureText(err: anyerror) []const u8 {
    return switch (err) {
        error.WorldLocked => "此存档正在游玩，请退出世界后再操作。",
        error.WorldLockUnsupported => "此文件系统无法安全锁定存档，暂时不能修改。",
        error.WorldLockChanged => "存档的使用状态已改变，请刷新后重试。",
        error.InstanceRunning => "实例正在运行，请结束游戏后再修改存档。",
        error.InstanceBusy, error.Busy => "实例有其他操作进行中，请稍后重试。",
        error.SelectionChanged => "实例或存档已切换，请重新选择。",
        else => fmt("操作失败：{s}", .{@errorName(err)}),
    };
}
fn drawWorldActions(ui: *Ui, doc: *const config.Document, source: config.Instance, world: worlds.World, enabled: bool, can_view: bool) void {
    const section = dvui.box(@src(), .{}, .{ .tag = "world-selected-actions", .expand = .horizontal, .gravity_y = 1, .padding = .{ .y = if (dvui.windowRect().h < theme.style.layout.compact_height) theme.spacing.row_gap else theme.spacing.footer_gap }, .margin = R.all(0), .background = false });
    defer section.deinit();
    const compact = section.data().contentRect().w < theme.style.layout.world_compact_width;
    const action_size = if (section.data().contentRect().w < theme.style.layout.world_compact_actions_width) theme.sizing.compact_icon_button else theme.sizing.control_height;
    const actions = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal, .padding = R.all(0), .margin = R.all(0), .background = false });
    defer actions.deinit();
    const backup_clicked = if (compact) components.iconButton(@src(), "备份", dvui.entypo.box, .{ .standalone = true, .tag = "world-backup", .enabled = enabled, .size = action_size }) else components.button(@src(), "备份", .{ .standalone = true, .tag = "world-backup", .enabled = enabled });
    if (backup_clicked) ui.queueRequest(source, .{ .backup = world.folder }) catch |err| {
        ui.failure = err;
    };
    const copy_clicked = if (compact) components.iconButton(@src(), "复制到实例", dvui.entypo.copy, .{ .standalone = true, .tag = "world-copy", .enabled = enabled and doc.instances.len > 1, .size = action_size }) else components.button(@src(), "复制到实例", .{ .standalone = true, .tag = "world-copy", .enabled = enabled and doc.instances.len > 1 });
    if (copy_clicked) ui.openWorld(.copy, source, world) catch |err| {
        ui.failure = err;
    };
    const rename_clicked = if (compact) components.iconButton(@src(), "重命名", dvui.entypo.pencil, .{ .standalone = true, .tag = "world-rename", .enabled = enabled and world.metadata_status == .valid, .size = action_size }) else components.button(@src(), "重命名", .{ .standalone = true, .tag = "world-rename", .enabled = enabled and world.metadata_status == .valid });
    if (rename_clicked) ui.openWorld(.rename_display, source, world) catch |err| {
        ui.failure = err;
    };
    const folder_clicked = if (compact) components.iconButton(@src(), "修改文件夹名称", dvui.entypo.folder, .{ .standalone = true, .tag = "world-rename-folder", .enabled = enabled, .size = action_size }) else components.button(@src(), "修改文件夹", .{ .standalone = true, .tag = "world-rename-folder", .enabled = enabled });
    if (folder_clicked) ui.openWorld(.rename_folder, source, world) catch |err| {
        ui.failure = err;
    };
    const open_clicked = if (compact) components.iconButton(@src(), "打开存档目录", dvui.entypo.folder, .{ .standalone = true, .tag = "world-open", .enabled = can_view, .size = action_size }) else components.button(@src(), "打开目录", .{ .standalone = true, .tag = "world-open", .enabled = can_view });
    if (open_clicked) ui.queueDirectoryOpen(source, world.folder) catch |err| {
        ui.failure = err;
    };
    if (components.button(@src(), "删除", .{ .standalone = true, .tag = "world-delete", .destructive = true, .enabled = enabled, .min_width = if (compact) 0 else theme.sizing.button_min_width })) ui.openWorld(.delete, source, world) catch |err| {
        ui.failure = err;
    };
}
pub fn drawWithEnabled(ui: *Ui, doc: *const config.Document, manager: *worlds_manager.Manager, controls_enabled: bool) !void {
    const snapshot = manager.snapshot();
    const root = dvui.box(@src(), .{}, .{ .tag = "worlds-page", .expand = .both, .padding = R.all(0), .margin = R.all(0), .background = false });
    defer root.deinit();
    drawHeader(ui, doc, snapshot, controls_enabled);
    const source = snapshot.instance orelse {
        if (ui.failure) |err| components.text(@src(), failureText(err), theme.colors.danger);
        if (snapshot.failure) |err| components.text(@src(), failureText(err), theme.colors.danger);
        components.emptyState(@src(), if (doc.instances.len == 0) "尚无实例" else if (ui.entry_refresh_pending) "正在读取存档…" else "从左侧选择一个实例");
        return;
    };
    const desired = selectedInstance(doc);
    const current = if (desired) |v| sameInstance(v, source) else false;
    const running = manager.isRunning(source.id);
    if (!current) {
        components.text(@src(), "正在切换实例…", theme.colors.muted);
        return;
    }
    const can_view = controls_enabled and !ui.select_queued and ui.draft == null;
    const enabled = can_view and !running and !snapshot.worker_active;
    var selected_world: ?worlds.World = null;
    for (snapshot.worlds) |world| {
        if (sameId(ui.selected_world, world.folder)) {
            selected_world = world;
            break;
        }
    }
    // Reserve the action bar before the scrolling content uses the remaining height.
    if (selected_world) |world| drawWorldActions(ui, doc, source, world, enabled and world.access == .available, can_view);
    drawBackups(ui, source, snapshot.backups, snapshot.worlds, enabled);
    const scroll = components.scrollBody(@src());
    defer scroll.deinit();
    if (ui.failure) |err| components.text(@src(), failureText(err), theme.colors.danger);
    if (snapshot.failure) |err| components.text(@src(), failureText(err), theme.colors.danger);
    if (running) components.text(@src(), "实例正在运行，可以查看存档，修改操作暂不可用", theme.colors.warning);
    if (snapshot.worlds.len == 0 and !snapshot.loading) components.emptyState(@src(), "此实例还没有存档");
    var budget: usize = preview_limit;
    {
        const text_inset = theme.style.cards.world_preview + 2 * theme.spacing.panel_compact_padding + theme.spacing.card_gap + theme.sizing.selection_diameter + theme.spacing.detail_gap;
        const minimum_width = @max(theme.style.layout.world_min_width, text_inset + theme.captionFont().textSize("最后游玩：2026-10-07 13:42").w);
        var grid = card_grid.init(@src(), snapshot.worlds.len, .{ .min_width = minimum_width, .max_columns = 2, .tag = "world-card-grid" });
        defer grid.deinit();
        for (snapshot.worlds, 0..) |world, index| {
            const selected = sameId(ui.selected_world, world.folder);
            if (selected) selected_world = world;
            const slot = grid.cell(@src(), index, world.folder);
            const card_width = grid.cardWidth(index);
            const date = if (world.metadata.last_played_ms) |ms| timestamp(ms) else "未知";
            const full_description = if (world.access == .in_use)
                fmt("文件夹：{s} · {s}", .{ world.folder, worldMode(world) })
            else
                fmt("文件夹：{s} · {s}\n最后游玩：{s}", .{ world.folder, worldMode(world), date });
            const description = if (card_width < minimum_width)
                if (world.access == .in_use)
                    fmt("{s}\n{s}", .{ world.folder, worldMode(world) })
                else
                    fmt("{s}\n{s}\n{s}", .{ world.folder, worldMode(world), date })
            else
                full_description;
            if (components.selectionCard(@src(), world.folder, world.displayName(), .{
                .selected = selected,
                .enabled = can_view,
                .width = card_width,
                .stretch = true,
                .bounded_text = true,
                .compact = true,
                .height = theme.style.cards.world_height,
                .tooltip = full_description,
                .avatar_text = "存",
                .avatar_source = previewSource(world.folder, snapshot.previews, &budget),
                .avatar_size = theme.style.cards.world_preview,
                .avatar_radius = theme.controlRadius(),
                .avatar_tag = fmt("world-preview-{s}", .{world.folder}),
                .description = description,
                .status = worldStatus(world),
                .status_color = if (world.access == .in_use) theme.colors.accent else theme.colors.warning,
                .status_gap = theme.spacing.row_gap,
                .tag = fmt("world-card-{s}", .{world.folder}),
            })) {
                ui.selectWorld(world.folder) catch |err| {
                    ui.failure = err;
                };
                selected_world = world;
            }
            slot.deinit();
        }
    }
}

fn backupRestorable(backup: worlds.Backup) bool {
    return backup.manifest_error == null and worlds.validRecoveryId(backup.id) and
        config.validId(backup.source_instance orelse return false) and
        worlds.validFolder(backup.source_folder orelse return false);
}

fn drawBackups(ui: *Ui, source: config.Instance, backups: []const worlds.Backup, live_worlds: []const worlds.World, enabled: bool) void {
    // The repository belongs to the selected instance; manifest provenance and live
    // world selection must not hide deleted worlds, old folders or damaged records.
    const count = backups.len;
    if (count == 0) return;

    // Reserve the backup dock before the world list expands into the remaining space.
    const compact_height = dvui.windowRect().h < theme.style.layout.compact_height;
    const section = components.disclosurePanel(@src(), "world-backups-toggle", fmt("备份 · {d}", .{count}), &ui.backups_expanded, .{ .tag = "world-backups", .gravity_y = 1, .margin = .{ .y = if (compact_height) theme.spacing.detail_gap else theme.spacing.section_gap } });
    defer section.deinit();
    const compact = section.data().contentRect().w < theme.style.layout.world_compact_width;
    if (!ui.backups_expanded) return;

    // At the minimum supported window height, keep both scroll regions usable.
    const recovery_height: f32 = if (compact_height) theme.style.layout.recovery_compact_height else @min(theme.style.layout.recovery_max_height, dvui.windowRect().h * theme.style.layout.recovery_height_share);
    const list = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .tag = "world-recovery-list", .expand = .horizontal, .max_size_content = .{ .w = 0, .h = recovery_height }, .padding = R.all(0), .margin = R.all(0), .background = false });
    defer list.deinit();
    for (backups) |backup| {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = @as(usize, @truncate(std.hash.Wyhash.hash(@backingInt(backup.part), backup.id))),
            .tag = fmt("world-backup-item-{s}-{s}", .{ backup.id, @tagName(backup.part) }),
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.panel_compact_padding - theme.sizing.control_border, .y = theme.spacing.row_gap - theme.sizing.control_border, .w = theme.spacing.panel_compact_padding - theme.sizing.control_border, .h = theme.spacing.row_gap - theme.sizing.control_border },
            .margin = .{ .h = theme.spacing.row_gap },
            .border = R.all(theme.sizing.control_border),
            .color_border = .{ .color = theme.colors.outline },
            .corners = .all(theme.cardRadius()),
            .background = true,
            .color_fill = .{ .color = theme.colors.surface },
        });
        {
            const info = dvui.box(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .gravity_y = 0.5, .padding = R.all(0), .margin = .{ .w = if (compact) theme.spacing.row_gap else theme.spacing.card_gap }, .background = false });
            dvui.labelNoFmt(@src(), timestamp(backup.created_ms), .{ .ellipsize = true }, .{ .font = theme.bodyFont(), .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = .{ .h = theme.spacing.detail_gap }, .background = false });
            const caption = if (backup.source_folder) |folder| fmt("{s} · 原文件夹：{s}", .{ operationText(backup.operation), folder }) else fmt("{s} · 记录：{s}", .{ operationText(backup.operation), backup.id });
            dvui.labelNoFmt(@src(), caption, .{ .ellipsize = true }, .{ .font = theme.captionFont(), .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = R.all(0), .background = false, .color_text = .{ .color = theme.colors.muted } });
            if (backup.part == .overwritten) components.hint(@src(), if (compact) "已替换" else "被替换数据");
            if (!sameId(backup.source_instance, source.id) and backup.source_instance != null) components.hint(@src(), fmt("来源实例：{s}", .{backup.source_instance.?}));
            if (!backupRestorable(backup)) components.hint(@src(), "备份信息不可用，无法安全恢复");
            const info_id = info.data().id;
            const info_rect = info.data().borderRectScale().r;
            info.deinit();
            components.tooltip(@src(), info_id, info_rect, fmt("{s}\n{s}", .{ timestamp(backup.created_ms), caption }));
        }
        const restore = dvui.box(@src(), .{}, .{ .gravity_y = 0.5, .padding = R.all(0), .margin = R.all(0), .background = false });
        const restore_tag = fmt("world-restore-{s}-{s}", .{ backup.id, @tagName(backup.part) });
        const target_available = blk: {
            const folder = backup.source_folder orelse break :blk true;
            for (live_worlds) |world| {
                if (std.mem.eql(u8, world.folder, folder)) break :blk world.access == .available;
            }
            break :blk true;
        };
        const can_restore = enabled and backupRestorable(backup) and target_available;
        const restore_clicked = components.button(@src(), "恢复", .{ .tag = restore_tag, .placement = .footer, .min_width = theme.style.sizing.list_action_width, .enabled = can_restore });
        if (restore_clicked) ui.openBackup(source, backup) catch |err| {
            ui.failure = err;
        };
        restore.deinit();
        row.deinit();
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
    const buffer = dvui.currentWindow().arena().alloc(u8, 16) catch return "未知";
    return local_time.format(buffer, ms) orelse "未知";
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
    const draft = &ui.draft.?;
    const height: f32 = switch (draft.operation) {
        .copy => theme.style.dialogs.world_copy_height,
        .restore => theme.style.dialogs.world_restore_height,
        .rename_folder => theme.style.dialogs.world_folder_height,
        .rename_display => theme.style.dialogs.world_rename_height,
        .delete => theme.style.dialogs.world_delete_height,
    };
    {
        const modal = components.modalWithClose(@src(), title(draft.operation), height, &draft.open);
        defer modal.deinit();
        const action = components.modalFormActions(@src(), .{ .save_label = switch (draft.operation) {
            .copy => "复制",
            .restore => "恢复",
            .delete => "确认删除",
            .rename_display, .rename_folder => "保存",
        }, .save_enabled = draftBlocked(draft, doc, manager) == null and draft.confirmed and !ui.select_queued and ui.draft_action == .none });
        if (action == .cancel) draft.open = false;
        const scroll = components.scrollBody(@src());
        defer scroll.deinit();
        {
            const identity = components.modalSection(@src(), .{ .min_height = 128, .tag = "world-dialog-identity" });
            defer identity.deinit();
            components.text(@src(), fmt("世界：{s}", .{draft.display_name}), theme.colors.muted);
            _ = dvui.spacer(@src(), .{ .min_size_content = .height(theme.spacing.row_gap) });
            components.text(@src(), fmt("源实例：{s}", .{draft.source.name}), theme.colors.muted);
            _ = dvui.spacer(@src(), .{ .min_size_content = .height(theme.spacing.row_gap) });
            if (draft.operation == .restore) {
                components.text(@src(), fmt("恢复记录：{s} · {s}", .{ draft.backup_id, if (draft.part == .original) "原始数据" else "被替换数据" }), theme.colors.muted);
            } else components.text(@src(), fmt("文件夹：{s}", .{draft.folder}), theme.colors.muted);
        }
        const confirmation = components.modalSection(@src(), .{ .min_height = switch (draft.operation) {
            .copy => 284,
            .restore => 220,
            .rename_folder => 216,
            .rename_display, .delete => 176,
        }, .gap_after = 0, .tag = "world-dialog-confirmation" });
        defer confirmation.deinit();
        if (draft.operation != .delete) {
            // The dialog confirmation section already owns the form inset.
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
                components.fieldLabel(@src(), "目标实例");
                var choice: ?usize = selected;
                if (components.dropdown(@src(), "目标实例", labels[0..count], .{ .choice_nullable = &choice }, .{ .placeholder = "选择目标实例", .null_selectable = false }, .{})) {
                    const index = choice orelse 0;
                    if (ids[index]) |id| try draft.setTarget(id) else {
                        draft.target_id = null;
                        draft.confirmed = false;
                        draft.replace_backed_up = false;
                    }
                }
            }
            const label = if (draft.operation == .rename_display) "新显示名称" else if (draft.operation == .rename_folder) "新文件夹名" else "目标世界文件夹";
            if (components.field(@src(), label, &draft.name, .{ .gap_after = 0 })) {
                draft.confirmed = false;
                draft.replace_backed_up = false;
                draft.name_too_long = false;
            }
        }
        if (draft.operation != .delete) _ = dvui.spacer(@src(), .{ .min_size_content = .height(theme.spacing.card_gap) });
        if (draft.name_too_long) components.text(@src(), "名称过长，请重新输入", theme.colors.danger);
        if (draft.operation == .copy or draft.operation == .restore or draft.operation == .rename_folder) {
            _ = components.checkbox(@src(), &draft.replace_backed_up, "目标存在时，先备份再替换", true);
        }
        if (draft.operation == .delete) {
            components.text(@src(), "世界将从 saves 移除，删除前数据保留在恢复记录中。", theme.colors.warning);
            _ = dvui.spacer(@src(), .{ .min_size_content = .height(theme.spacing.card_gap) });
        }
        _ = components.checkbox(@src(), &draft.confirmed, switch (draft.operation) {
            .delete => "确认删除此世界",
            .rename_display => "确认修改显示名称并保留恢复数据",
            .rename_folder => "确认修改文件夹名并保留恢复数据",
            .copy => "确认复制到所选目标",
            .restore => "确认恢复所选数据",
        }, true);
        const blocked = draftBlocked(draft, doc, manager);
        if (blocked) |err| components.text(@src(), fmt("暂不可执行：{s}", .{@errorName(err)}), theme.colors.warning);
        if (ui.failure) |err| components.text(@src(), fmt("操作失败：{s}", .{@errorName(err)}), theme.colors.danger);
        if (action == .save and draft.open and blocked == null and draft.confirmed and !ui.select_queued) {
            ui.queueDraft(doc) catch |err| {
                ui.failure = err;
                return;
            };
        }
    }
    if (!draft.open) ui.draft_action = .cancel;
}

const SelectionSync = enum { unchanged, scanned, deferred };

fn mutationPending(manager: *const worlds_manager.Manager) bool {
    if (manager.active) |job| if (job.request != null) return true;
    if (manager.pending) |job| if (job.request != null) return true;
    return false;
}

fn syncSelection(ui: *Ui, store: *config.Store, manager: *worlds_manager.Manager) !SelectionSync {
    const desired = selectedInstance(store.snapshot());
    const id: ?[]const u8 = if (desired) |v| v.id else null;
    const name: ?[]const u8 = if (desired) |v| v.name else null;
    const snapshot = manager.snapshot();
    const matches = if (desired) |v| if (snapshot.instance) |current| sameInstance(v, current) else false else snapshot.instance == null;
    if (matches and ui.sync_initialized and sameId(ui.synced_id, id) and sameId(ui.synced_name, name)) return .unchanged;
    // select() cancels active jobs; wait until a mutation has published its result.
    if (!matches and mutationPending(manager)) return .deferred;
    const next_id = if (id) |v| try ui.allocator.dupe(u8, v) else null;
    errdefer if (next_id) |v| ui.allocator.free(v);
    const next_name = if (name) |v| try ui.allocator.dupe(u8, v) else null;
    errdefer if (next_name) |v| ui.allocator.free(v);
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
        ui.backups_expanded = false;
        ui.closeDraft();
    }
    return if (!matches and desired != null) .scanned else .unchanged;
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
    if (!ui.page_active) return;
    defer ui.releaseRequests();
    const draft_action = ui.draft_action;
    ui.draft_action = .none;
    if (draft_action == .cancel) {
        ui.releaseRequests();
        ui.finishDraft(draft_action, false);
    }
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
    const sync = syncSelection(ui, store, manager) catch |err| {
        ui.failure = err;
        ui.entry_refresh_pending = false;
        return;
    };
    if (sync == .deferred) return;
    const has_selected_instance = selectedInstance(store.snapshot()) != null;
    // A matching pending/active read already fulfills this entry. Never replace
    // it on another render or reentry; mutations keep the entry pending instead.
    if (ui.entry_refresh_pending and !mutationPending(manager)) {
        ui.entry_refresh_pending = false;
        if (has_selected_instance and sync != .scanned and !manager.snapshot().loading) {
            manager.refresh() catch |err| {
                ui.failure = err;
            };
        }
    }
    if (refresh and has_selected_instance and sync != .scanned and !manager.snapshot().worker_active) {
        manager.refresh() catch |err| {
            ui.failure = err;
        };
    }
    for (ui.requests.items) |*request| {
        applyRequest(request, store, manager) catch |err| {
            ui.failure = err;
            continue;
        };
        ui.finishDraft(draft_action, true);
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

test "world backup view real deleted and folder-renamed records restore to safe targets" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".minecraft/versions/Owner/saves/old-folder/region");
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Owner/saves/old-folder/region/data", .data = "recovery payload" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try @import("../core/instances.zig").Paths.init(a, io, root);
    defer paths.deinit();
    var registry = @import("../core/tasks.zig").Registry.init(a);
    defer registry.deinit();
    var coordinator = @import("../core/instance_leases.zig").Coordinator.init(io);
    var manager = try worlds_manager.Manager.initOptions(a, io, &paths, &registry, .{ .scope = coordinator.worldScope(3) });
    defer manager.deinit();
    const source: config.Instance = .{ .id = "owner", .name = "Owner", .minecraft_version = "1.21" };
    const doc: config.Document = .{ .instances = &.{source}, .selected_instance = source.id };
    try manager.select(source);
    try settleLifecycle(&manager);
    try std.testing.expect(manager.snapshot().failure == null);
    try manager.perform(.{ .delete = .{ .folder = "old-folder", .confirmed = true } });
    try settleLifecycle(&manager);
    try std.testing.expect(manager.snapshot().failure == null);
    try std.testing.expect(manager.snapshot().outcome.?.state == .committed);
    try std.testing.expectEqual(@as(usize, 0), manager.snapshot().worlds.len);
    try std.testing.expectEqual(@as(usize, 1), manager.snapshot().backups.len);
    var ui = try Ui.init(a);
    defer ui.deinit();
    try ui.openBackup(source, manager.snapshot().backups[0]);
    try std.testing.expect(ui.selected_world == null);
    try std.testing.expectError(error.ConfirmationRequired, ui.queueDraft(&doc));
    ui.draft.?.confirmed = true;
    try ui.queueDraft(&doc);
    try std.testing.expect(!ui.requests.items[0].value.restore.confirmed);
    try coordinator.reserveLaunch(source.id);
    try std.testing.expectError(error.InstanceRunning, manager.perform(ui.requests.items[0].value));
    coordinator.releaseLaunch();
    try manager.perform(ui.requests.items[0].value);
    ui.releaseRequests();
    ui.closeDraft();
    try settleLifecycle(&manager);
    try std.testing.expect(manager.snapshot().failure == null and manager.snapshot().outcome.?.state == .committed);
    const restored = try tmp.dir.readFileAlloc(io, ".minecraft/versions/Owner/saves/old-folder/region/data", a, .limited(64));
    defer a.free(restored);
    try std.testing.expectEqualStrings("recovery payload", restored);
    try manager.perform(.{ .rename_folder = .{ .folder = "old-folder", .name = "renamed-folder" } });
    try settleLifecycle(&manager);
    try std.testing.expect(manager.snapshot().failure == null and manager.snapshot().outcome.?.state == .committed);
    try std.testing.expectEqual(@as(usize, 1), manager.snapshot().worlds.len);
    try std.testing.expectEqualStrings("renamed-folder", manager.snapshot().worlds[0].folder);
    try ui.selectWorld("renamed-folder");
    // Both the delete record and folder-rename record retain the old source folder.
    for (manager.snapshot().backups) |backup| {
        if (backup.operation != .rename) continue;
        try ui.openBackup(source, backup);
        break;
    }
    try std.testing.expect(ui.draft != null);
    try std.testing.expectEqualStrings("old-folder", std.mem.sliceTo(&ui.draft.?.name, 0));
    @memset(&ui.draft.?.name, 0);
    @memcpy(ui.draft.?.name[0.."recovered-folder".len], "recovered-folder");
    ui.draft.?.confirmed = true;
    try ui.queueDraft(&doc);
    try manager.perform(ui.requests.items[0].value);
    ui.releaseRequests();
    ui.closeDraft();
    try settleLifecycle(&manager);
    try std.testing.expect(manager.snapshot().failure == null and manager.snapshot().outcome.?.state == .committed);
    const recovered = try tmp.dir.readFileAlloc(io, ".minecraft/versions/Owner/saves/recovered-folder/region/data", a, .limited(64));
    defer a.free(recovered);
    try std.testing.expectEqualStrings("recovery payload", recovered);
    try tmp.dir.access(io, ".minecraft/versions/Owner/saves/renamed-folder/region/data", .{});
}

test "world backup view missing source permits safe target and preserves consent and part" {
    const a = std.testing.allocator;
    const source: config.Instance = .{ .id = "owner", .name = "Owner", .minecraft_version = "1.21" };
    const doc: config.Document = .{ .instances = &.{source}, .selected_instance = source.id };
    var ui = try Ui.init(a);
    defer ui.deinit();
    const backup: worlds.Backup = .{ .id = "0123456789abcdef0123456789abcdef", .part = .overwritten, .directory = "/unused", .source_instance = source.id, .source_folder = "old-folder", .created_ms = 0 };
    try ui.openBackup(source, backup);
    try std.testing.expect(ui.selected_world == null);
    try std.testing.expectEqualStrings("old-folder", std.mem.sliceTo(&ui.draft.?.name, 0));
    try std.testing.expectError(error.ConfirmationRequired, ui.queueDraft(&doc));
    const draft = &ui.draft.?;
    @memset(&draft.name, 0);
    @memcpy(draft.name[0.."restored-folder".len], "restored-folder");
    draft.confirmed = true;
    try ui.queueDraft(&doc);
    const restore = ui.requests.items[0].value.restore;
    try std.testing.expectEqualStrings("restored-folder", restore.target_folder);
    try std.testing.expect(restore.part == .overwritten and !restore.confirmed);
    ui.releaseRequests();
    @memset(&draft.name, 0);
    @memcpy(draft.name[0..3], "../");
    try std.testing.expectError(error.UnsafeWorldName, ui.queueDraft(&doc));
    try std.testing.expect(ui.requests.items.len == 0);
}

test "world backup view rejects malformed and unsafe records before opening draft" {
    var ui = try Ui.init(std.testing.allocator);
    defer ui.deinit();
    const source: config.Instance = .{ .id = "owner", .name = "Owner", .minecraft_version = "1.21" };
    var backup: worlds.Backup = .{ .id = "0123456789abcdef0123456789abcdef", .part = .original, .directory = "/unused", .created_ms = 0, .manifest_error = error.InvalidManifest };
    try std.testing.expectError(error.InvalidManifest, ui.openBackup(source, backup));
    backup.manifest_error = null;
    try std.testing.expectError(error.InvalidManifest, ui.openBackup(source, backup));
    backup.source_instance = source.id;
    backup.source_folder = "../unsafe";
    try std.testing.expectError(error.InvalidManifest, ui.openBackup(source, backup));
    backup.source_folder = "old-folder";
    backup.id = "../unsafe";
    try std.testing.expectError(error.InvalidManifest, ui.openBackup(source, backup));
    try std.testing.expect(ui.draft == null and ui.requests.items.len == 0);
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

test "world form submission retains rejected draft and cancel only discards draft" {
    const a = std.testing.allocator;
    const source: config.Instance = .{ .id = "source", .name = "source-folder", .minecraft_version = "1.21" };
    const doc: config.Document = .{ .instances = &.{source}, .selected_instance = source.id };
    var ui = try Ui.init(a);
    defer ui.deinit();
    ui.draft = try Draft.init(a, .rename_display, source, "world", "Old", "New");
    try std.testing.expectError(error.ConfirmationRequired, ui.queueDraft(&doc));
    try std.testing.expect(ui.draft != null and ui.requests.items.len == 0);
    ui.draft.?.confirmed = true;
    try ui.queueDraft(&doc);
    try std.testing.expect(ui.draft != null and ui.draft_action == .save);
    try std.testing.expectEqualStrings("New", ui.requests.items[0].value.rename_display.name);
    ui.failure = error.PublicationUncertain;
    ui.finishDraft(.save, false);
    try std.testing.expect(ui.draft != null);
    try std.testing.expectEqual(@as(?anyerror, error.PublicationUncertain), ui.failure);
    ui.releaseRequests();
    try ui.queueDraft(&doc);
    ui.finishDraft(.save, true);
    try std.testing.expect(ui.draft == null and ui.failure == null);
    ui.releaseRequests();
    ui.draft = try Draft.init(a, .rename_display, source, "world", "Old", "Discard");
    ui.draft_action = .cancel;
    try std.testing.expect(ui.draft != null);
    ui.finishDraft(.cancel, false);
    try std.testing.expect(ui.draft == null and ui.requests.items.len == 0 and !ui.cancel_queued);
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
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, Fixture.run, .{});
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

const LifecycleWorker = struct {
    scans: std.atomic.Value(usize) = .init(0),
    mutations: std.atomic.Value(usize) = .init(0),
    hold: std.atomic.Value(bool) = .init(false),
    entered: std.atomic.Value(bool) = .init(false),
    fail_scan: bool = false,

    fn work(a: A, io: std.Io, _: *const @import("../core/instances.zig").Paths, _: config.Instance, request: ?worlds_manager.Request, options: worlds.Options) anyerror!worlds_manager.Result {
        const self: *LifecycleWorker = @ptrCast(@alignCast(options.guard.context.?));
        if (request == null) {
            _ = self.scans.fetchAdd(1, .release);
        } else {
            _ = self.mutations.fetchAdd(1, .release);
        }
        self.entered.store(true, .release);
        while (self.hold.load(.acquire)) {
            try options.hooks.check(io);
            try io.sleep(.fromMilliseconds(1), .awake);
        }
        try options.hooks.check(io);
        if (request == null) {
            if (self.fail_scan) return error.TestScanFailure;
            return .{};
        }
        const id = try a.dupe(u8, "lifecycle-operation");
        errdefer a.free(id);
        return .{ .outcome = .{
            .allocator = a,
            .state = .committed,
            .recovery_id = id,
            .recovery_directory = try a.dupe(u8, "/tmp/lifecycle-operation"),
        } };
    }
};

fn settleLifecycle(manager: *worlds_manager.Manager) !void {
    for (0..5000) |_| {
        manager.tick();
        if (!manager.snapshot().worker_active) return;
        try manager.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.TestWorkerTimedOut;
}

fn waitLifecycleEntered(manager: *worlds_manager.Manager, worker: *LifecycleWorker) !void {
    for (0..5000) |_| {
        manager.tick();
        if (worker.entered.load(.acquire)) return;
        try manager.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.TestWorkerTimedOut;
}

const lifecycle_rows = [_]config.Instance{
    .{ .id = "source-id", .name = "Source", .minecraft_version = "1.21" },
    .{ .id = "copy-id", .name = "Copied", .minecraft_version = "1.21" },
};

test "world page scans only on entry selection change and manual refresh" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    try store.update(.{ .instances = &lifecycle_rows, .selected_instance = "source-id" });
    var paths = try @import("../core/instances.zig").Paths.init(a, io, root);
    defer paths.deinit();
    var registry = @import("../core/tasks.zig").Registry.init(a);
    defer registry.deinit();
    var coordinator = @import("../core/instance_leases.zig").Coordinator.init(io);
    var worker: LifecycleWorker = .{};
    var manager = try worlds_manager.Manager.initOptions(a, io, &paths, &registry, .{ .scope = coordinator.worldScope(3), .guard = .{ .context = &worker }, .worker = LifecycleWorker.work });
    defer manager.deinit();
    var ui = try Ui.init(a);
    defer ui.deinit();

    for (0..5) |_| finish(&ui, &store, &manager);
    try std.testing.expect(manager.selected == null and manager.pending == null);
    ui.setPageActive(true);
    finish(&ui, &store, &manager);
    try settleLifecycle(&manager);
    try std.testing.expectEqual(@as(usize, 1), worker.scans.load(.acquire));
    for (0..5) |_| {
        ui.setPageActive(true);
        finish(&ui, &store, &manager);
        manager.tick();
    }
    // Store republication replaces all borrowed strings without changing identity.
    try store.update(store.snapshot().*);
    finish(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 1), worker.scans.load(.acquire));
    ui.setPageActive(false);
    finish(&ui, &store, &manager);
    ui.setPageActive(true);
    finish(&ui, &store, &manager);
    try settleLifecycle(&manager);
    try std.testing.expectEqual(@as(usize, 2), worker.scans.load(.acquire));
    ui.refresh_queued = true;
    finish(&ui, &store, &manager);
    try settleLifecycle(&manager);
    try std.testing.expectEqual(@as(usize, 3), worker.scans.load(.acquire));

    ui.setPageActive(false);
    var document = store.snapshot().*;
    document.selected_instance = "copy-id";
    try store.update(document);
    finish(&ui, &store, &manager);
    try std.testing.expectEqualStrings("source-id", manager.snapshot().instance.?.id);
    ui.setPageActive(true);
    finish(&ui, &store, &manager);
    try settleLifecycle(&manager);
    try std.testing.expectEqual(@as(usize, 4), worker.scans.load(.acquire));
    try std.testing.expectEqualStrings("copy-id", manager.snapshot().instance.?.id);
    var renamed = lifecycle_rows;
    renamed[1].name = "Renamed copy";
    try store.update(.{ .instances = &renamed, .selected_instance = "copy-id" });
    finish(&ui, &store, &manager);
    try settleLifecycle(&manager);
    try std.testing.expectEqual(@as(usize, 5), worker.scans.load(.acquire));
    worker.fail_scan = true;
    ui.refresh_queued = true;
    finish(&ui, &store, &manager);
    try settleLifecycle(&manager);
    try std.testing.expectEqual(@as(?anyerror, error.TestScanFailure), manager.snapshot().failure);
    for (0..5) |_| finish(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 6), worker.scans.load(.acquire));
    document = store.snapshot().*;
    document.selected_instance = null;
    try store.update(document);
    finish(&ui, &store, &manager);
    try std.testing.expect(manager.snapshot().instance == null and !manager.snapshot().worker_active);
    try std.testing.expect(ui.failure == null);
}

test "world page reentry preserves active scan and mutation completion refresh" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    try store.update(.{ .instances = &lifecycle_rows, .selected_instance = "source-id" });
    var paths = try @import("../core/instances.zig").Paths.init(a, io, root);
    defer paths.deinit();
    var registry = @import("../core/tasks.zig").Registry.init(a);
    defer registry.deinit();
    var coordinator = @import("../core/instance_leases.zig").Coordinator.init(io);
    var worker: LifecycleWorker = .{};
    var manager = try worlds_manager.Manager.initOptions(a, io, &paths, &registry, .{ .scope = coordinator.worldScope(3), .guard = .{ .context = &worker }, .worker = LifecycleWorker.work });
    defer manager.deinit();
    defer worker.hold.store(false, .release);
    var ui = try Ui.init(a);
    defer ui.deinit();

    worker.hold.store(true, .release);
    ui.setPageActive(true);
    finish(&ui, &store, &manager);
    try waitLifecycleEntered(&manager, &worker);
    const scan = manager.active.?;
    for (0..5) |_| {
        ui.setPageActive(false);
        ui.setPageActive(true);
        finish(&ui, &store, &manager);
        try std.testing.expect(manager.active.? == scan and manager.pending == null);
        try std.testing.expect(!ui.entry_refresh_pending);
    }
    worker.hold.store(false, .release);
    try settleLifecycle(&manager);
    try std.testing.expectEqual(@as(usize, 1), worker.scans.load(.acquire));

    worker.entered.store(false, .release);
    worker.hold.store(true, .release);
    try manager.perform(.{ .backup = "World" });
    try waitLifecycleEntered(&manager, &worker);
    const mutation = manager.active.?;
    ui.setPageActive(false);
    ui.setPageActive(true);
    for (0..5) |_| finish(&ui, &store, &manager);
    try std.testing.expect(ui.entry_refresh_pending);
    try std.testing.expect(manager.active.? == mutation and manager.pending == null);
    worker.hold.store(false, .release);
    // JOIN queues the manager's normal post-operation read. Let finish consume
    // the entry while that same read is pending, without replacing it.
    for (0..5000) |_| {
        if (mutation.done.load(.acquire)) break;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(mutation.done.load(.acquire));
    manager.tick();
    finish(&ui, &store, &manager);
    try settleLifecycle(&manager);
    try std.testing.expect(!ui.entry_refresh_pending);
    try std.testing.expectEqual(@as(usize, 1), worker.mutations.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), worker.scans.load(.acquire));
    try std.testing.expect(manager.operation_failure == null);

    worker.entered.store(false, .release);
    worker.hold.store(true, .release);
    try manager.perform(.{ .backup = "World" });
    try waitLifecycleEntered(&manager, &worker);
    const second_mutation = manager.active.?;
    var document = store.snapshot().*;
    document.selected_instance = "copy-id";
    try store.update(document);
    for (0..5) |_| finish(&ui, &store, &manager);
    try std.testing.expect(manager.active.? == second_mutation and manager.pending == null);
    try std.testing.expectEqualStrings("source-id", manager.snapshot().instance.?.id);
    worker.hold.store(false, .release);
    try settleLifecycle(&manager);
    finish(&ui, &store, &manager);
    try settleLifecycle(&manager);
    try std.testing.expectEqual(@as(usize, 2), worker.mutations.load(.acquire));
    try std.testing.expectEqualStrings("copy-id", manager.snapshot().instance.?.id);
}

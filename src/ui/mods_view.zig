//! Intent-only local content body. Snapshot pointers are borrowed for this frame only.
const std = @import("std");
const dvui = @import("dvui");
const local = @import("../core/local_content.zig");
const theme = @import("theme.zig");
const style = @import("style.zig");
const components = @import("components.zig");
const card_grid = @import("card_grid.zig");
const local_time = @import("local_time.zig");
const resource_download = @import("resource_download_state.zig");
const resource_menu = @import("resource_type_menu.zig");
const A = std.mem.Allocator;
const R = dvui.Rect;

const inventory = @import("../application/mods_snapshot.zig");
const Row = inventory.Row;
const Snapshot = inventory.Snapshot;
pub const Intent = union(enum) {
    refresh,
    list_view: bool,
    toggle: struct { path: []const u8, enabled: bool },
    back,
};
pub const Filter = enum { all, enabled, disabled };
pub const Sort = enum { name_ascending, name_descending, newest, oldest };

const InventoryVersion = inventory.InventoryVersion;

const DerivedRows = struct {
    indices: []usize = &.{},
    count: usize = 0,
    version: ?InventoryVersion = null,
    search: [513]u8 = @splat(0),
    kind: local.Kind = .mod,
    filter: Filter = .all,
    sort: Sort = .name_ascending,
    rebuilds: usize = 0,

    fn deinit(self: *DerivedRows, a: A) void {
        a.free(self.indices);
        self.* = .{};
    }

    fn get(self: *DerivedRows, ui: *const Ui, snapshot: Snapshot) ![]const usize {
        if (snapshot.inventory) |version| if (self.version) |previous| {
            if (std.meta.eql(version, previous) and self.indices.len == snapshot.rows.len and
                self.kind == ui.kind and self.filter == ui.filter and self.sort == ui.sort and
                std.mem.eql(u8, &self.search, &ui.search)) return self.indices[0..self.count];
        };
        // Invalidate before allocation: a failed rebuild must never expose stale indices.
        self.version = null;
        if (self.indices.len != snapshot.rows.len) {
            const next = try ui.allocator.alloc(usize, snapshot.rows.len);
            ui.allocator.free(self.indices);
            self.indices = next;
        }
        self.count = 0;
        for (snapshot.rows, 0..) |row, index| if (matches(ui, row)) {
            self.indices[self.count] = index;
            self.count += 1;
        };
        const Order = struct {
            rows: []const Row,
            sort: Sort,
            fn before(context: @This(), lhs: usize, rhs: usize) bool {
                return lessThan(context.sort, context.rows[lhs], context.rows[rhs]);
            }
        };
        std.mem.sort(usize, self.indices[0..self.count], Order{ .rows = snapshot.rows, .sort = ui.sort }, Order.before);
        self.search = ui.search;
        self.kind = ui.kind;
        self.filter = ui.filter;
        self.sort = ui.sort;
        self.version = snapshot.inventory;
        self.rebuilds +%= 1;
        return self.indices[0..self.count];
    }
};

pub const Ui = struct {
    allocator: A,
    derived: DerivedRows = .{},
    acquisition: resource_download.Ui,
    resource_menu: resource_menu.State = .{},
    resource_menu_route: resource_download.Route = .local,
    selected_path: ?[]const u8 = null,
    filter_after_toggle: ?Filter = null,
    kind: local.Kind = .mod,
    pending: ?Intent = null,
    search: [513]u8 = @splat(0),
    filter: Filter = .all,
    sort: Sort = .name_ascending,
    list: bool = false,
    info_path: ?[]const u8 = null,
    info_open: bool = false,
    locate_path: ?[]const u8 = null,
    locate_settle: u8 = 0,
    failure: ?anyerror = null,

    pub fn init(a: A) !Ui {
        return .{ .allocator = a, .acquisition = resource_download.Ui.init(a) };
    }
    pub fn deinit(self: *Ui) void {
        self.clearIntent();
        self.acquisition.deinit();
        self.derived.deinit(self.allocator);
        if (self.selected_path) |path| self.allocator.free(path);
        if (self.info_path) |path| self.allocator.free(path);
        if (self.locate_path) |path| self.allocator.free(path);
        self.* = undefined;
    }
    pub fn selectPath(self: *Ui, path: ?[]const u8) !void {
        const next = if (path) |value| try self.allocator.dupe(u8, selectionKey(value)) else null;
        if (self.selected_path) |old| self.allocator.free(old);
        self.selected_path = next;
        if (path == null) {
            if (self.locate_path) |old| self.allocator.free(old);
            self.locate_path = null;
            self.locate_settle = 0;
        }
    }
    /// Queue a copy, preserving the first unconsumed action.
    pub fn queue(self: *Ui, intent: Intent) !void {
        if (self.pending != null) return error.IntentPending;
        self.pending = switch (intent) {
            .toggle => |value| .{ .toggle = .{ .path = try self.allocator.dupe(u8, value.path), .enabled = value.enabled } },
            .refresh => .refresh,
            .list_view => |list| .{ .list_view = list },
            .back => .back,
        };
    }
    /// Transfer ownership. Call deinitIntent after processing, before Ui.deinit.
    pub fn takeIntent(self: *Ui) ?Intent {
        const value = self.pending;
        self.pending = null;
        return value;
    }
    pub fn deinitIntent(self: *Ui, intent: Intent) void {
        switch (intent) {
            .toggle => |value| self.allocator.free(value.path),
            else => {},
        }
    }
    pub fn clearIntent(self: *Ui) void {
        if (self.takeIntent()) |value| self.deinitIntent(value);
    }
    fn openInfo(self: *Ui, path: []const u8) !void {
        const next = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(next);
        try self.selectPath(path);
        if (self.info_path) |old| self.allocator.free(old);
        self.info_path = next;
        self.info_open = true;
    }
    fn locate(self: *Ui, row: Row) !void {
        const next = try self.allocator.dupe(u8, row.entry.path);
        errdefer self.allocator.free(next);
        try self.selectPath(row.entry.path);
        if (self.locate_path) |old| self.allocator.free(old);
        self.locate_path = next;
        // Grid rows and scroll bounds are measured across successive frames.
        self.locate_settle = 2;
        self.kind = row.entry.kind;
        self.filter = if (row.entry.enabled) .enabled else .disabled;
        @memset(&self.search, 0);
        self.info_open = false;
    }
};

fn selectionKey(path: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, path, ".jar.disabled")) path[0 .. path.len - ".disabled".len] else path;
}
fn samePath(path: ?[]const u8, other: []const u8) bool {
    return if (path) |value| std.mem.eql(u8, selectionKey(value), selectionKey(other)) else false;
}
fn findPath(rows: []const Row, path: ?[]const u8) ?Row {
    for (rows) |row| if (samePath(path, row.entry.path)) return row;
    return null;
}
fn containsInsensitive(value: []const u8, needle: []const u8) bool {
    if (needle.len > value.len) return false;
    for (0..value.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(value[i..][0..needle.len], needle)) return true;
    }
    return false;
}
fn matches(ui: *const Ui, row: Row) bool {
    const entry = row.entry;
    if (entry.kind != ui.kind) return false;
    if (ui.filter == .enabled and !entry.enabled or ui.filter == .disabled and entry.enabled) return false;
    const query = std.mem.trim(u8, std.mem.sliceTo(&ui.search, 0), " \t\r\n");
    if (containsInsensitive(entry.name, query) or containsInsensitive(entry.path, query)) return true;
    for (entry.mod_ids) |id| if (containsInsensitive(id, query)) return true;
    return false;
}
fn lessThan(sort: Sort, lhs: Row, rhs: Row) bool {
    const a = lhs.entry;
    const b = rhs.entry;
    if (sort == .newest or sort == .oldest) {
        if (a.mtime_ms != b.mtime_ms) return if (sort == .newest) a.mtime_ms > b.mtime_ms else a.mtime_ms < b.mtime_ms;
    }
    const order = std.ascii.orderIgnoreCase(a.name, b.name);
    if (order != .eq) return if (sort == .name_descending) order == .gt else order == .lt;
    return std.mem.order(u8, a.path, b.path) == .lt;
}
fn dependencyTarget(rows: []const Row, id: []const u8) ?Row {
    for (rows) |row| {
        if (row.entry.kind != .mod) continue;
        for (row.entry.mod_ids) |mod_id| if (std.mem.eql(u8, mod_id, id)) return row;
    }
    return null;
}
fn kindTitle(kind: local.Kind) []const u8 {
    return switch (kind) {
        .mod => "模组",
        .resourcepack => "材质包",
        .shader => "光影包",
    };
}
fn frameFmt(comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), format, args) catch "";
}
fn caption(src: std.builtin.SourceLocation, value: []const u8, font: dvui.Font, rect: ?R) void {
    const width = if (rect) |r| r.w else dvui.parentGet().data().contentRect().w;
    dvui.labelNoFmt(src, components.ellipsize(value, font, @max(0, width)), .{}, .{
        .rect = rect,
        .font = font,
        .expand = if (rect == null) .horizontal else .none,
        .max_size_content = .width(0),
        .color_text = .{ .color = theme.colors.muted },
        .padding = .all(0),
        .margin = .all(0),
        .background = false,
    });
}

/// Draw only the main body; the app owns the instance sidebar and routing.
pub fn draw(ui: *Ui, snapshot: Snapshot) void {
    const root = dvui.box(@src(), .{}, .{ .tag = "mods-page", .expand = .both, .max_size_content = .width(0), .padding = .all(0), .margin = .all(0), .background = false });
    defer root.deinit();
    {
        const header = dvui.box(@src(), .{}, .{ .tag = "mods-header", .expand = .horizontal, .max_size_content = .width(0), .padding = .all(0), .margin = .{ .h = if (dvui.windowRect().h < style.layout.compact_height) theme.spacing.row_gap else theme.spacing.page_title_gap }, .background = false });
        defer header.deinit();
        components.title(@src(), snapshot.title orelse kindTitle(ui.kind));
        if (snapshot.subtitle) |value| {
            _ = dvui.spacer(@src(), .{ .min_size_content = .height(theme.spacing.detail_gap) });
            components.hint(@src(), value);
        }
    }
    if (!snapshot.busy) if (ui.filter_after_toggle) |filter| {
        if (snapshot.failure == null) ui.filter = filter;
        ui.filter_after_toggle = null;
    };
    drawSearch(ui);
    drawToolbar(ui);
    // Reserve the footer before the scrolling rows consume remaining height.
    drawFooter(ui, snapshot);
    const scroll = components.scrollBody(@src());
    defer scroll.deinit();
    if (snapshot.failure) |err| components.text(@src(), frameFmt("读取失败：{s}", .{@errorName(err)}), theme.colors.danger);
    if (ui.failure) |err| components.text(@src(), frameFmt("操作失败：{s}", .{@errorName(err)}), theme.colors.danger);
    if (snapshot.recovery_required) components.text(@src(), "需要先恢复内容状态，修改操作暂不可用", theme.colors.warning);
    if (snapshot.truncated) components.text(@src(), "目录内容超过扫描上限，当前仅显示部分文件", theme.colors.warning);
    const rows = ui.derived.get(ui, snapshot) catch |err| {
        ui.failure = err;
        return;
    };
    if (rows.len == 0 and !snapshot.busy and snapshot.failure == null and !snapshot.truncated) components.emptyState(@src(), if (snapshot.rows.len == 0) "此实例尚无本地内容" else "没有符合搜索和筛选条件的内容");
    if (ui.list) {
        for (rows) |index| drawCard(ui, snapshot.rows[index], dvui.parentGet().data().contentRect().w, true);
    } else {
        var grid = card_grid.init(@src(), rows.len, .{ .min_width = 280, .max_columns = 3, .tag = "mods-card-grid" });
        defer grid.deinit();
        for (rows, 0..) |index, i| {
            const row = snapshot.rows[index];
            const cell = grid.cell(@src(), i, selectionKey(row.entry.path));
            drawCard(ui, row, grid.cardWidth(i), false);
            cell.deinit();
        }
    }
}
fn drawSearch(ui: *Ui) void {
    const compact = dvui.windowRect().h < style.layout.compact_height;
    const font = theme.bodyFont();
    const height = if (compact) style.sizing.compact_icon_button else style.sizing.control_height;
    const inset_y = @max(0, (height - 2 - font.textHeight()) / 2);
    var input: dvui.TextEntryWidget = undefined;
    input.init(@src(), .{ .text = .{ .buffer = &ui.search }, .placeholder = "搜索名称 / ID" }, theme.controlOptions(font.textHeight()).override(.{
        .tag = "mods-search",
        .label = .{ .text = "搜索名称、文件名或模组 ID" },
        .expand = .horizontal,
        .max_size_content = .width(0),
        .min_size_content = .height(@max(0, height - 2 * (inset_y + 1))),
        .padding = .{ .x = 16, .w = 16, .y = inset_y, .h = inset_y },
        .margin = .{ .h = style.spacing.row_gap },
    }));
    defer input.deinit();
    input.processEvents();
    input.draw();
}
fn drawToolbar(ui: *Ui) void {
    const width = dvui.parentGet().data().contentRect().w;
    const narrow = width < 650;
    const compact = dvui.windowRect().h < style.layout.compact_height;
    const height = if (compact) style.sizing.compact_icon_button else style.sizing.control_height;
    var sort_index: usize = @backingInt(ui.sort);
    const track = dvui.box(@src(), .{ .dir = if (narrow) .vertical else .horizontal }, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = .all(0), .margin = .{ .h = if (compact) 8 else style.spacing.card_gap }, .background = false });
    defer track.deinit();
    const filters = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = .all(0), .margin = .{ .h = if (narrow) 8 else 0 }, .background = false });
    for ([_][]const u8{ "全部", "已启用", "已禁用" }, 0..) |label, i| {
        const item = dvui.box(@src(), .{}, .{ .id_extra = i, .expand = if (narrow) .horizontal else .none, .padding = .all(0), .margin = .{ .w = if (i < 2) 8 else 0 }, .background = false });
        const value: Filter = @fromBackingInt(@intCast(i));
        const font = theme.bodyFont();
        const geometry = theme.controlGeometry(@max(font.lineHeight(), font.textSize(label).h), height, if (narrow) 0 else 104, 16, 1);
        var button: dvui.ButtonWidget = undefined;
        button.init(@src(), .{}, theme.panelButtonOptions(theme.controlOptions(font.lineHeight()).override(.{
            .tag = frameFmt("mods-filter-{d}", .{i}),
            .label = .{ .text = label },
            .expand = if (narrow) .horizontal else .none,
            .min_size_content = geometry.content,
            .padding = geometry.padding,
            .margin = .all(0),
            .style = if (ui.filter == value) .highlight else .control,
        }), ui.filter == value));
        button.processEvents();
        theme.buttonBackground(&button, .{ .material = ui.filter != value });
        dvui.labelNoFmt(@src(), label, .{ .align_y = 0.5 }, button.style().override(.{ .gravity_x = 0.5, .gravity_y = 0.5, .padding = .all(0), .margin = .all(0), .background = false }));
        if (button.clicked()) ui.filter = value;
        button.deinit();
        item.deinit();
    }
    filters.deinit();
    const controls = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = if (narrow) .horizontal else .none, .gravity_x = if (narrow) 0 else 1, .padding = .all(0), .margin = .all(0), .background = false });
    defer controls.deinit();
    const sort_geometry = theme.controlGeometry(theme.bodyFont().lineHeight(), height, 0, 16, 1);
    _ = components.dropdown(@src(), "排序", &.{ "名称 A–Z", "名称 Z–A", "文件时间：最新", "文件时间：最早" }, .{ .choice = &sort_index }, .{}, .{ .tag = "mods-sort", .expand = if (narrow) .horizontal else .none, .min_size_content = .{ .w = if (narrow) 0 else 180, .h = height }, .max_size_content = .width(if (narrow) 0 else 180), .padding = sort_geometry.padding, .margin = .{ .w = 8 } });
    if (components.iconButton(@src(), "网格", dvui.entypo.grid, .{ .standalone = true, .selected = !ui.list, .size = height, .tag = "mods-grid" })) ui.queue(.{ .list_view = false }) catch |err| {
        ui.failure = err;
    };
    if (components.iconButton(@src(), "列表", dvui.entypo.list, .{ .standalone = true, .selected = ui.list, .size = height, .tag = "mods-list" })) ui.queue(.{ .list_view = true }) catch |err| {
        ui.failure = err;
    };
    ui.sort = @fromBackingInt(@intCast(sort_index));
}
fn drawFooter(ui: *Ui, snapshot: Snapshot) void {
    const compact = dvui.windowRect().h < style.layout.compact_height;
    const footer = dvui.box(@src(), .{}, .{ .expand = .horizontal, .gravity_y = 1, .padding = .{ .y = if (compact) 8 else style.spacing.footer_gap }, .margin = .all(0), .background = false });
    defer footer.deinit();
    const gap = theme.spacing.action_gap;
    const narrow = dvui.parentGet().data().contentRect().w < 480;
    const actions = dvui.box(@src(), .{ .dir = if (narrow) .vertical else .horizontal }, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = .all(0), .margin = .all(0), .background = false });
    defer actions.deinit();
    const available = actions.data().contentRect().w;
    const left = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = .all(0), .margin = .{ .h = if (narrow) gap else 0, .w = if (narrow) 0 else gap }, .background = false });
    const selected = findPath(snapshot.rows, ui.selected_path);
    const allowed = snapshot.can_mutate and !snapshot.busy and !snapshot.recovery_required and ui.pending == null and !ui.info_open;
    const managed = if (selected) |row| row.entry.kind == .mod else false;
    const label = if (selected) |row| if (row.entry.enabled) "禁用" else "启用" else "禁用";
    const hint: ?[:0]const u8 = if (selected == null) "先选择一项内容" else if (!managed) "仅模组支持启用或禁用" else if (snapshot.recovery_required) "需要先恢复内容状态" else if (!snapshot.can_mutate) "当前实例状态不允许修改" else null;
    const width = if (narrow) @max(0, (available - gap) / 2) else theme.footerButtonWidth(available);
    if (components.button(@src(), label, .{ .enabled = allowed and managed, .primary = allowed and managed, .placement = .footer, .standalone = true, .min_width = width, .tooltip = hint, .tag = "mods-toggle" })) {
        const row = selected.?;
        ui.queue(.{ .toggle = .{ .path = row.entry.path, .enabled = !row.entry.enabled } }) catch |err| {
            ui.failure = err;
        };
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .width(gap) });
    if (components.button(@src(), "刷新", .{ .enabled = !snapshot.busy and ui.pending == null and !ui.info_open, .placement = .footer, .standalone = true, .min_width = width, .tag = "mods-refresh" })) ui.queue(.refresh) catch |err| {
        ui.failure = err;
    };
    left.deinit();
    if (components.button(@src(), switch (ui.kind) {
        .mod => "获取模组",
        .resourcepack => "获取资源包",
        .shader => "获取光影",
    }, .{ .enabled = snapshot.can_mutate and !snapshot.busy and !ui.info_open, .primary = true, .placement = .footer, .standalone = true, .gravity_x = if (narrow) 0 else 1, .min_width = if (narrow) available else width, .tag = "mods-download" })) ui.acquisition.open();
}
fn drawCard(ui: *Ui, row: Row, width: f32, list: bool) void {
    const entry = row.entry;
    const selected = samePath(ui.selected_path, entry.path);
    const height: f32 = if (list) 56 else 128;
    const inset_x: f32 = @min(23, @max(0, (width - 26) / 2));
    const inset_y: f32 = if (list) 0 else 20;
    const content_width = @max(0, width - 2 * (inset_x + 1));
    const content_height = height - 2 * (inset_y + 1);
    var card: dvui.ButtonWidget = undefined;
    card.init(@src(), .{ .draw_focus = false }, .{
        .id_extra = @truncate(std.hash.Wyhash.hash(0, selectionKey(entry.path))),
        .tag = frameFmt("mods-row-{s}", .{entry.path}),
        .label = .{ .text = entry.name },
        .expand = .horizontal,
        .min_size_content = .{ .w = content_width, .h = content_height },
        .max_size_content = .{ .w = content_width, .h = content_height },
        .padding = .{ .x = inset_x, .w = inset_x, .y = inset_y, .h = inset_y },
        .margin = .{ .h = if (list) 8 else 0 },
        .border = .all(1),
        .corners = .all(if (list) theme.controlRadius() else theme.cardRadius()),
        .color_border = .{ .color = if (selected) theme.colors.accent else theme.colors.outline },
        .color_fill = .{ .color = theme.panelColor(theme.colors.surface) },
        .color_fill_hover = .{ .color = theme.panelColor(theme.colors.surface) },
        .color_fill_press = .{ .color = theme.panelColor(theme.colors.surface) },
    });
    defer card.deinit();
    const visible = !card.data().borderRectScale().r.intersect(dvui.clipGet()).empty();
    if (card.data().accesskit_node()) |node| dvui.AccessKit.nodeSetSelected(node, selected);
    // Keep each fixed-size card registered for layout, keyboard navigation and locate.
    // Offscreen artwork must not evict visible icons from the bounded decode cache.
    if (visible or card.focused()) {
        card.processHover();
        theme.buttonBackground(&card, .{ .material = true });
        if (selected or card.hovered() or card.focused()) {
            if (infoButton(ui, .{ .x = @max(0, content_width - 24), .y = if (list) (content_height - 24) / 2 else content_height - 24, .w = 24, .h = 24 }, entry.path)) ui.openInfo(entry.path) catch |err| {
                ui.failure = err;
            };
        }
        const title_font = theme.fontSized(18);
        var buffer: [16]u8 = undefined;
        const date = local_time.format(&buffer, entry.mtime_ms) orelse "未知";
        if (list) {
            localIcon(ui, entry.icon_png, 32, .{ .y = (content_height - 32) / 2, .w = 32, .h = 32 }, entry.enabled);
            const usable = @max(0, content_width - 32 - 44);
            const title_w = usable * 0.44;
            const version_w = usable * 0.24;
            rowLabel(@src(), entry.name, title_font, .{ .x = 44, .y = 0, .w = @max(0, title_w - 8), .h = content_height }, theme.colors.foreground);
            versionCaption(@src(), entry.version orelse "版本未知", entry.enabled, .{ .x = 44 + title_w, .w = @max(0, version_w - 8), .h = content_height });
            rowLabel(@src(), date, theme.fontSized(14), .{ .x = 44 + title_w + version_w, .w = usable - title_w - version_w, .h = content_height }, theme.colors.muted);
        } else {
            localIcon(ui, entry.icon_png, 48, .{ .w = 48, .h = 48 }, entry.enabled);
            rowLabel(@src(), entry.name, title_font, .{ .x = 64, .w = @max(0, content_width - 64), .h = 28 }, theme.colors.foreground);
            versionCaption(@src(), entry.version orelse "版本未知", entry.enabled, .{ .x = 64, .y = 36, .w = @max(0, content_width - 64), .h = 24 });
            caption(@src(), date, theme.fontSized(14), .{ .y = 64, .w = @max(0, content_width - 32), .h = 20 });
        }
    }
    // Children receive events first so clicking info never also selects/toggles the card.
    card.processEvents();
    if (card.focused()) card.data().focusBorder();
    if (card.clicked()) ui.selectPath(entry.path) catch |err| {
        ui.failure = err;
    };
    if (samePath(ui.locate_path, entry.path)) {
        if (ui.locate_settle > 0) {
            ui.locate_settle -= 1;
            dvui.refresh(null, @src(), card.data().id);
        } else {
            var target = card.data().borderRectScale().r;
            // A tall card must reveal its heading in a short viewport.
            if (dvui.ScrollContainerWidget.current()) |scroll| target.h = @min(target.h, scroll.data().contentRectScale().r.h);
            dvui.scrollTo(.{ .screen_rect = target, .over_scroll = true });
            ui.allocator.free(ui.locate_path.?);
            ui.locate_path = null;
        }
    }
    if (visible) components.tooltip(@src(), card.data().id, card.data().borderRectScale().r, frameFmt("{s}\n{s}{s}", .{ entry.name, entry.path, if (entry.parse_failure != null) "\n元数据读取失败" else "" }));
}
fn versionCaption(src: std.builtin.SourceLocation, value: []const u8, enabled: bool, rect: R) void {
    if (enabled) return rowLabel(src, value, theme.bodyFont(), rect, theme.colors.muted);
    const line = dvui.box(src, .{ .dir = .horizontal }, .{ .rect = rect, .padding = .all(0), .margin = .all(0), .background = false });
    defer line.deinit();
    dvui.labelNoFmt(@src(), components.ellipsize(value, theme.bodyFont(), @max(0, rect.w - 64)), .{}, .{ .font = theme.bodyFont(), .gravity_y = 0.5, .padding = .all(0), .margin = .{ .w = 8 }, .color_text = .{ .color = theme.colors.muted } });
    dvui.labelNoFmt(@src(), "· 已禁用", .{}, .{ .font = theme.fontSized(14), .gravity_y = 0.5, .padding = .all(0), .margin = .all(0), .color_text = .{ .color = theme.colors.muted } });
}
fn rowLabel(src: std.builtin.SourceLocation, value: []const u8, font: dvui.Font, rect: R, color: dvui.Color) void {
    dvui.labelNoFmt(src, components.ellipsize(value, font, rect.w), .{ .align_y = 0.5 }, .{ .rect = rect, .font = font, .padding = .all(0), .margin = .all(0), .background = false, .color_text = .{ .color = color }, .role = .none });
}
fn infoButton(ui: *Ui, rect: R, path: []const u8) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(@src(), .{ .draw_focus = false }, .{ .rect = rect, .tag = frameFmt("mods-info-{s}", .{path}), .label = .{ .text = "查看信息" }, .min_size_content = .all(24), .max_size_content = .size(.all(24)), .padding = .all(0), .margin = .all(0), .border = .all(0), .background = false, .color_text = .{ .color = theme.colors.accent } });
    defer button.deinit();
    button.processEvents();
    dvui.icon(@src(), "查看信息", dvui.entypo.info_with_circle, .{}, .{ .min_size_content = .all(24), .max_size_content = .size(.all(24)), .padding = .all(0), .margin = .all(0), .role = .none, .color_text = .{ .color = theme.colors.accent } });
    if (button.focused()) {
        button.data().focusBorder();
        // Keep the pure icon visible when keyboard focus moves from the card.
        if (!samePath(ui.selected_path, path)) ui.selectPath(path) catch |err| {
            ui.failure = err;
        };
    }
    return button.clicked();
}

fn legitimateHomepage(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") and !std.ascii.eqlIgnoreCase(uri.scheme, "http")) return false;
    if (uri.host == null or uri.host.?.isEmpty() or uri.user != null or uri.password != null) return false;
    for (url) |byte| if (byte <= 32 or byte == 127) return false;
    return true;
}
fn localIcon(ui: *Ui, bytes: ?[]const u8, size: f32, rect: ?R, enabled: bool) void {
    const bitmap = if (ui.acquisition.icons) |*cache| if (bytes) |png| (if (enabled) cache.local(png) else cache.localDisabled(png)) else null else null;
    if (!enabled and bitmap == null) {
        dvui.icon(@src(), "模组图标", dvui.entypo.archive, .{}, .{ .rect = rect, .min_size_content = .all(size), .max_size_content = .size(.all(size)), .padding = .all(0), .margin = .all(0), .color_text = .{ .color = theme.colors.muted } });
    } else @import("resource_icons.zig").draw(@src(), bitmap, size, rect);
}
pub fn drawDialogs(ui: *Ui, snapshot: Snapshot) void {
    if (!ui.info_open) return;
    const row = findPath(snapshot.rows, ui.info_path) orelse {
        ui.info_open = false;
        return;
    };
    const entry = row.entry;
    const compact = dvui.windowRect().h < style.layout.compact_height;
    const modal = components.modalWithClose(@src(), frameFmt("{s}信息", .{kindTitle(entry.kind)}), 512, &ui.info_open);
    defer modal.deinit();
    {
        const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_y = 1, .padding = .{ .y = 16 }, .margin = .all(0), .background = false });
        defer actions.deinit();
        const homepage = if (entry.homepage) |url| if (legitimateHomepage(url)) url else null else null;
        if (!@import("resource_links.zig").draw(entry.name, homepage, null, "mods")) ui.failure = error.HomepageOpenFailed;
        if (components.button(@src(), "关闭", .{ .primary = true, .gravity_x = 1, .min_width = 124, .tag = "mods-info-close" })) ui.info_open = false;
    }
    {
        const heading = dvui.box(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .height(64), .max_size_content = .height(64), .padding = .all(0), .margin = .{ .h = if (compact) 16 else 40 }, .background = false });
        defer heading.deinit();
        localIcon(ui, entry.icon_png, 64, .{ .x = 0, .y = 0, .w = 64, .h = 64 }, true);
        const width = @max(0, heading.data().contentRect().w - 88);
        dvui.labelNoFmt(@src(), components.ellipsize(entry.name, theme.headingFont(), width), .{}, .{ .rect = .{ .x = 88, .y = 4, .w = width, .h = 28 }, .font = theme.headingFont(), .color_text = .{ .color = theme.colors.foreground }, .padding = .all(0), .margin = .all(0), .background = false });
        dvui.labelNoFmt(@src(), components.ellipsize(entry.version orelse "版本未知", theme.bodyFont(), width), .{}, .{ .rect = .{ .x = 88, .y = 40, .w = width, .h = 24 }, .font = theme.bodyFont(), .color_text = .{ .color = theme.colors.muted }, .padding = .all(0), .margin = .all(0), .background = false });
    }
    dvui.labelNoFmt(@src(), "依赖", .{}, .{ .font = theme.headingFont(), .min_size_content = .height(24), .expand = .horizontal, .padding = .all(0), .margin = .{ .h = if (compact) 8 else 16 }, .background = false, .color_text = .{ .color = theme.colors.foreground } });
    const dependencies = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .expand = .both, .max_size_content = .width(0), .padding = .{ .x = 8, .w = 8, .y = 4, .h = 4 }, .margin = .{ .h = if (compact) 8 else 24 }, .border = .all(1), .corners = .all(theme.cardRadius()), .background = true, .color_fill = .{ .color = theme.colors.inset }, .color_border = .{ .color = theme.colors.outline }, .tag = "mods-dependencies" });
    defer dependencies.deinit();
    if (entry.dependencies.len == 0) components.hint(@src(), if (entry.parse_failure != null) "无法读取依赖" else "没有声明依赖");
    for (entry.dependencies, 0..) |dependency, i| {
        const target = dependencyTarget(snapshot.rows, dependency.id);
        const name = if (target) |match| match.entry.name else if (std.mem.eql(u8, dependency.id, "fabricloader")) "Fabric Loader" else if (std.mem.eql(u8, dependency.id, "minecraft")) "Minecraft" else dependency.id;
        const version = if (target) |match| match.entry.version orelse dependency.version orelse "任意版本" else dependency.version orelse "任意版本";
        var track: dvui.ButtonWidget = undefined;
        track.init(@src(), .{ .draw_focus = target != null }, .{ .id_extra = i, .tag = frameFmt("mods-dependency-{d}", .{i}), .label = .{ .text = frameFmt("{s}{s}", .{ if (target != null) "定位 " else "", name }) }, .role = if (target != null) .button else .none, .tab_index = if (target != null) null else 0, .expand = .horizontal, .min_size_content = .height(56), .max_size_content = .width(0), .padding = .{ .x = 12, .w = 4 }, .margin = .all(0), .border = .all(0), .corners = .all(theme.controlRadius()), .background = true, .color_fill = .{ .color = theme.style.colors.transparent }, .color_fill_hover = .{ .color = if (target != null) theme.colors.selected_surface else theme.style.colors.transparent }, .color_fill_press = .{ .color = if (target != null) theme.colors.pressed_surface else theme.style.colors.transparent } });
        defer track.deinit();
        if (target != null) {
            track.processHover();
        }
        theme.surface.buttonBackground(&track);
        const width = track.data().contentRect().w;
        const arrow_x = @max(0, width - 48);
        const version_width = @min(192, @max(0, width * 0.36));
        const version_x = @max(0, arrow_x - 20 - version_width);
        const name_width = @max(0, version_x - 16);
        const display_name = frameFmt("{s}{s}", .{ name, if (dependency.optional) " · 可选" else "" });
        const name_font = theme.bodyFont();
        const version_font = theme.captionFont();
        dvui.labelNoFmt(@src(), components.ellipsize(display_name, name_font, name_width), .{}, .{ .rect = .{ .x = 0, .y = (56 - name_font.textHeight()) / 2, .w = name_width, .h = name_font.textHeight() }, .font = name_font, .padding = .all(0), .margin = .all(0), .background = false, .color_text = .{ .color = theme.colors.foreground } });
        dvui.labelNoFmt(@src(), components.ellipsize(version, version_font, version_width), .{}, .{ .rect = .{ .x = version_x, .y = (56 - version_font.textHeight()) / 2, .w = version_width, .h = version_font.textHeight() }, .font = version_font, .padding = .all(0), .margin = .all(0), .background = false, .color_text = .{ .color = theme.colors.muted } });
        if (target) |match| {
            const arrow = dvui.box(@src(), .{}, .{ .rect = .{ .x = arrow_x, .y = 4, .w = 48, .h = 48 }, .padding = .all(0), .margin = .all(0), .border = .all(0), .corners = .all(theme.controlRadius()), .background = false, .color_border = .{ .color = if (track.hovered() or track.focused()) theme.colors.accent else theme.colors.outline } });
            if (components.iconButton(@src(), "定位模组", dvui.entypo.chevron_small_right, .{ .size = 48, .selected = true, .tag = frameFmt("mods-dependency-arrow-{d}", .{i}) })) ui.locate(match) catch |err| {
                ui.failure = err;
            };
            arrow.deinit();
            track.processEvents();
            if (track.clicked()) ui.locate(match) catch |err| {
                ui.failure = err;
            };
        }
        if (i + 1 < entry.dependencies.len) {
            const divider = dvui.box(@src(), .{}, .{ .rect = .{ .x = 0, .y = 55, .w = @max(0, width - 8), .h = 1 }, .padding = .all(0), .margin = .all(0), .background = true, .color_fill = .{ .color = theme.colors.outline }, .role = .none });
            divider.deinit();
        }
        components.tooltip(@src(), track.data().id, track.data().borderRectScale().r, frameFmt("{s}\n要求 {s}", .{ name, dependency.version orelse "任意版本" }));
    }
}

test "mods view owns selected and transferred intent paths" {
    var ui = try Ui.init(std.testing.allocator);
    defer ui.deinit();
    var path = [_]u8{ 'a', '.', 'j', 'a', 'r' };
    try ui.selectPath(&path);
    try ui.queue(.{ .toggle = .{ .path = &path, .enabled = false } });
    path[0] = 'b';
    try std.testing.expectEqualStrings("a.jar", ui.selected_path.?);
    try std.testing.expectError(error.IntentPending, ui.queue(.refresh));
    const intent = ui.takeIntent().?;
    defer ui.deinitIntent(intent);
    try std.testing.expect(ui.pending == null);
    try std.testing.expectEqualStrings("a.jar", intent.toggle.path);
}
test "mods view resolves dependency IDs rather than display names" {
    const first: local.Entry = .{ .path = "a.jar", .physical_path = "a.jar", .name = "sodium", .mod_ids = &.{"other"} };
    const second: local.Entry = .{ .path = "b.jar", .physical_path = "b.jar", .name = "Translated name", .mod_ids = &.{"sodium"} };
    const rows = [_]Row{ .{ .entry = &first }, .{ .entry = &second } };
    try std.testing.expectEqualStrings("b.jar", dependencyTarget(&rows, "sodium").?.entry.path);
    try std.testing.expect(dependencyTarget(&rows, "Translated name") == null);
}
test "mods derived rows reuse indices and invalidate in-place edits and query changes" {
    var ui = try Ui.init(std.testing.allocator);
    defer ui.deinit();
    var alpha: local.Entry = .{ .path = "a.jar", .physical_path = "a.jar", .name = "Alpha", .mtime_ms = 1 };
    const beta: local.Entry = .{ .path = "b.jar", .physical_path = "b.jar", .name = "Beta", .mtime_ms = 2 };
    const rows = [_]Row{ .{ .entry = &beta }, .{ .entry = &alpha } };
    var snapshot: Snapshot = .{ .rows = &rows, .inventory = .{ .source = 1, .revision = 1 } };
    try std.testing.expectEqualSlices(usize, &.{ 1, 0 }, try ui.derived.get(&ui, snapshot));
    const allocation = ui.derived.indices.ptr;
    for (0..100) |_| _ = try ui.derived.get(&ui, snapshot);
    try std.testing.expectEqual(@as(usize, 1), ui.derived.rebuilds);
    try std.testing.expect(allocation == ui.derived.indices.ptr);
    ui.sort = .newest;
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, try ui.derived.get(&ui, snapshot));
    ui.filter = .enabled;
    _ = try ui.derived.get(&ui, snapshot);
    alpha.enabled = false;
    snapshot.inventory.?.revision += 1;
    try std.testing.expectEqualSlices(usize, &.{0}, try ui.derived.get(&ui, snapshot));
    ui.filter = .all;
    @memcpy(ui.search[0..5], "ALPHA");
    try std.testing.expectEqualSlices(usize, &.{1}, try ui.derived.get(&ui, snapshot));
    ui.kind = .shader;
    try std.testing.expectEqual(@as(usize, 0), (try ui.derived.get(&ui, snapshot)).len);
    ui.kind = .mod;
    @memset(&ui.search, 0);
    // A new source may reuse the same revision and row count, with different order.
    const replacement = [_]Row{ .{ .entry = &alpha }, .{ .entry = &beta } };
    snapshot.rows = &replacement;
    snapshot.inventory.?.source = 2;
    try std.testing.expectEqualSlices(usize, &.{ 1, 0 }, try ui.derived.get(&ui, snapshot));
    // Managed state is read from the current frame, not retained in the cache.
    const before = ui.derived.rebuilds;
    _ = try ui.derived.get(&ui, snapshot);
    try std.testing.expectEqual(before, ui.derived.rebuilds);
    snapshot.rows = &.{};
    snapshot.inventory.?.revision += 1;
    _ = try ui.derived.get(&ui, snapshot);
    try std.testing.expectEqual(@as(usize, 0), ui.derived.indices.len);
}

test "mods derived rows failed growth cannot reuse stale cache and releases allocations" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var ui = try Ui.init(failing.allocator());
    defer ui.deinit();
    const entry: local.Entry = .{ .path = "a.jar", .physical_path = "a.jar", .name = "Alpha" };
    const rows = [_]Row{ .{ .entry = &entry }, .{ .entry = &entry } };
    var snapshot: Snapshot = .{ .rows = rows[0..1], .inventory = .{ .source = 1, .revision = 1 } };
    _ = try ui.derived.get(&ui, snapshot);
    snapshot.rows = &rows;
    snapshot.inventory.?.revision += 1;
    try std.testing.expectError(error.OutOfMemory, ui.derived.get(&ui, snapshot));
    try std.testing.expect(ui.derived.version == null);
    // Returning to a smaller inventory must rebuild, even after the failed allocation.
    snapshot.rows = rows[0..1];
    try std.testing.expectEqualSlices(usize, &.{0}, try ui.derived.get(&ui, snapshot));
    try std.testing.expectEqual(@as(usize, 2), ui.derived.rebuilds);
    // Without a version contract even identical slice addresses must not hit cache.
    snapshot.inventory = null;
    _ = try ui.derived.get(&ui, snapshot);
    _ = try ui.derived.get(&ui, snapshot);
    try std.testing.expectEqual(@as(usize, 4), ui.derived.rebuilds);
}

test "mods view search state filter and deterministic sort" {
    var ui = try Ui.init(std.testing.allocator);
    defer ui.deinit();
    const a: local.Entry = .{ .path = "z.jar", .physical_path = "z.jar", .name = "Alpha", .mod_ids = &.{"real_id"}, .mtime_ms = 10 };
    const b: local.Entry = .{ .path = "a.jar", .physical_path = "a.jar", .name = "alpha", .enabled = false, .mtime_ms = 20 };
    @memcpy(ui.search[0..7], "REAL_ID");
    try std.testing.expect(matches(&ui, .{ .entry = &a }));
    try std.testing.expect(!matches(&ui, .{ .entry = &b }));
    ui.filter = .disabled;
    try std.testing.expect(!matches(&ui, .{ .entry = &a }));
    try std.testing.expect(lessThan(.newest, .{ .entry = &b }, .{ .entry = &a }));
    try std.testing.expect(lessThan(.name_ascending, .{ .entry = &b }, .{ .entry = &a }));
    try std.testing.expect(legitimateHomepage("https://example.org/project"));
    try std.testing.expect(!legitimateHomepage("file:///tmp/content"));
    try std.testing.expect(!legitimateHomepage("https://user:pass@example.org"));
}

test "mods view drawing declarations compile" {
    var ui = try Ui.init(std.testing.allocator);
    defer ui.deinit();
    // Analyze lazy drawing bodies without opening a native window in pure tests.
    var render = false;
    std.mem.doNotOptimizeAway(&render);
    if (render) {
        draw(&ui, .{});
        drawDialogs(&ui, .{});
    }
}

test "UI layout large mods lists only touch visible icons during resize and locate" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    const Fixture = struct {
        var ui: Ui = undefined;
        var rows: [256]Row = undefined;
        fn frame() !dvui.App.Result {
            draw(&ui, .{ .rows = &rows, .inventory = .{ .source = 1, .revision = 1 } });
            return .ok;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entries: [256]local.Entry = undefined;
    for (&entries, &Fixture.rows, 0..) |*entry, *row, i| {
        const path = try std.fmt.allocPrint(a, "mod-{d:0>4}.jar", .{i});
        // Unique invalid artwork also exercises the cache's negative entries.
        entry.* = .{ .path = path, .physical_path = path, .name = path, .icon_png = path };
        row.* = .{ .entry = entry };
    }
    for ([_]bool{ true, false }) |list| {
        Fixture.ui = try Ui.init(std.testing.allocator);
        defer Fixture.ui.deinit();
        Fixture.ui.list = list;
        Fixture.ui.acquisition.icons = @import("resource_icons.zig").Manager.init(std.testing.allocator, std.testing.io);
        var window = try dvui.testing.init(.{ .window_size = .{ .w = 1000, .h = 720 } });
        defer window.deinit();
        for ([_]f32{ 1000, 620, 1280 }) |width| {
            window.backend.size = .{ .w = width, .h = 720 };
            window.backend.size_pixels = .{ .w = width, .h = 720 };
            try dvui.testing.settle(Fixture.frame);
            const before = Fixture.ui.acquisition.icons.?.clock;
            _ = try dvui.testing.step(Fixture.frame);
            const visits = Fixture.ui.acquisition.icons.?.clock - before;
            try std.testing.expectEqual(@as(usize, 1), Fixture.ui.derived.rebuilds);
            try std.testing.expect(visits > 0);
            try std.testing.expect(visits < 48);
        }
        const first_y = (try dvui.testing.tagGet("mods-row-mod-0000.jar")).rect.y;
        try dvui.testing.moveTo("mods-row-mod-0000.jar");
        for (0..8) |_| {
            _ = try window.window.addEventMouseWheel(-96, .vertical, null);
            const start_clock = Fixture.ui.acquisition.icons.?.clock;
            _ = try dvui.testing.step(Fixture.frame);
            try std.testing.expect(Fixture.ui.acquisition.icons.?.clock - start_clock < 48);
        }
        try dvui.testing.settle(Fixture.frame);
        try std.testing.expect((try dvui.testing.tagGet("mods-row-mod-0000.jar")).rect.y < first_y);
        Fixture.ui.locate_path = try std.testing.allocator.dupe(u8, entries[255].path);
        Fixture.ui.locate_settle = 2;
        try dvui.testing.settle(Fixture.frame);
        try std.testing.expect(Fixture.ui.locate_path == null);
        const last = try dvui.testing.tagGet("mods-row-mod-0255.jar");
        try std.testing.expect(last.rect.y < 720 and last.rect.y + last.rect.h > 0);
        const before = Fixture.ui.acquisition.icons.?.clock;
        _ = try dvui.testing.step(Fixture.frame);
        try std.testing.expect(Fixture.ui.acquisition.icons.?.clock - before < 48);
    }
}

test "resource cache performance baseline" {
    const enabled = std.testing.environ.getAlloc(std.testing.allocator, "VELA_RESOURCE_BENCH") catch return error.SkipZigTest;
    defer std.testing.allocator.free(enabled);
    const iterations = 200;
    for ([_]usize{ 256, 1024, 4096 }) |count| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const entries = try a.alloc(local.Entry, count);
        const rows = try a.alloc(Row, count);
        for (entries, rows, 0..) |*entry, *row, index| {
            const name = try std.fmt.allocPrint(a, "mod-{d:0>5}.jar", .{count - index});
            entry.* = .{ .name = name, .path = name, .physical_path = name };
            row.* = .{ .entry = entry };
        }
        var allocations = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var ui = try Ui.init(allocations.allocator());
        defer ui.deinit();
        var snapshot: Snapshot = .{ .rows = rows, .inventory = .{ .source = 1, .revision = 1 } };
        _ = try ui.derived.get(&ui, snapshot);
        const before_allocations = allocations.alloc_index;
        const cached_start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        for (0..iterations) |_| std.mem.doNotOptimizeAway(try ui.derived.get(&ui, snapshot));
        const cached_ns = std.Io.Clock.awake.now(std.testing.io).nanoseconds - cached_start;
        try std.testing.expectEqual(before_allocations, allocations.alloc_index);
        try std.testing.expectEqual(@as(usize, 1), ui.derived.rebuilds);
        snapshot.inventory = null;
        const rebuild_start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        for (0..iterations) |_| std.mem.doNotOptimizeAway(try ui.derived.get(&ui, snapshot));
        const rebuild_ns = std.Io.Clock.awake.now(std.testing.io).nanoseconds - rebuild_start;
        std.debug.print("RESOURCE_BASELINE rows={d} iterations={d} cached_ns={d} rebuild_ns={d} retained_index_bytes={d} cached_allocations=0\n", .{ count, iterations, cached_ns, rebuild_ns, ui.derived.indices.len * @sizeOf(usize) });
        snapshot.rows = &.{};
        _ = try ui.derived.get(&ui, snapshot);
        try std.testing.expectEqual(@as(usize, 0), ui.derived.indices.len);
    }
}

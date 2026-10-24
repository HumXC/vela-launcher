const std = @import("std");
const dvui = @import("dvui");
const java = @import("java_manager.zig");
const download = @import("java_download_controller.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const download_view = @import("java_download_view.zig");
const file_picker = @import("file_picker.zig");
const R = dvui.Rect;

const Choice = struct { game: []const u8, path: []const u8, required: u32 };
const Command = union(enum) {
    search: []const u8,
    browse_folder,
    cancel,
    cancel_search,
    remove: []const u8,
    forget: []const u8,
    hide: []const u8,
    unhide: []const u8,
    delete_files: []const u8,
    add: []const []const u8,
    choose: Choice,

    fn deinit(self: Command, a: std.mem.Allocator) void {
        switch (self) {
            .search, .remove, .forget, .hide, .unhide, .delete_files => |path| a.free(path),
            .cancel, .cancel_search, .browse_folder => {},
            .add => |paths| {
                for (paths) |path| a.free(path);
                a.free(paths);
            },
            .choose => |choice| {
                a.free(choice.game);
                a.free(choice.path);
            },
        }
    }
};

pub const Ui = struct {
    allocator: std.mem.Allocator,
    path_buffer: [4096]u8 = @splat(0),
    search_selection: []bool = &.{},
    selection_fingerprint: ?u64 = null,
    failure: ?anyerror = null,
    add_failure: ?anyerror = null,
    choice_failure: ?anyerror = null,
    choice_context: ?u64 = null,
    acquisition_open: bool = true,
    acquisition_mode: enum { download, local } = .download,
    search_started: bool = false,
    download_requested: bool = false,
    requested_major: u32 = 21,
    search_queued: bool = false,
    commands: std.ArrayList(Command) = .empty,
    selected_path: ?[]const u8 = null,
    delete_confirmation: ?[]const u8 = null,
    show_hidden: bool = false,
    interactive: bool = true,
    download_controller: ?*download.Controller = null,
    picker_service: ?*file_picker.Service = null,
    picker_ticket: ?file_picker.Ticket = null,
    picker_path_snapshot: [4096]u8 = @splat(0),
    picker_path_changed: bool = false,

    pub fn init(a: std.mem.Allocator) Ui {
        return .{ .allocator = a };
    }

    pub fn deinit(self: *Ui) void {
        discardPicker(self);
        for (self.commands.items) |command| command.deinit(self.allocator);
        self.commands.deinit(self.allocator);
        self.allocator.free(self.search_selection);
        if (self.selected_path) |path| self.allocator.free(path);
        if (self.delete_confirmation) |path| self.allocator.free(path);
        self.* = undefined;
    }

    fn resetSearch(self: *Ui) void {
        self.clearSelection();
        self.add_failure = null;
    }

    fn syncChoiceContext(self: *Ui, game: []const u8, required: u32) void {
        const context = std.hash.Wyhash.hash(required, game);
        if (self.choice_context != context) self.choice_failure = null;
        self.choice_context = context;
    }

    fn enqueue(self: *Ui, command: Command) !void {
        errdefer command.deinit(self.allocator);
        try self.commands.append(self.allocator, command);
    }

    fn queuePath(self: *Ui, path: []const u8, searching: bool) !void {
        if (searching) discardPicker(self);
        const owned = try self.allocator.dupe(u8, path);
        try self.enqueue(if (searching) .{ .search = owned } else .{ .remove = owned });
    }

    fn selectPath(self: *Ui, path: []const u8) !void {
        const owned = try self.allocator.dupe(u8, path);
        if (self.selected_path) |old| self.allocator.free(old);
        self.selected_path = owned;
    }
    fn queueManagement(self: *Ui, path: []const u8, kind: enum { hide, unhide, delete_files }) !void {
        const owned = try self.allocator.dupe(u8, path);
        try self.enqueue(switch (kind) {
            .hide => .{ .hide = owned },
            .unhide => .{ .unhide = owned },
            .delete_files => .{ .delete_files = owned },
        });
    }
    fn queueChoice(self: *Ui, game: []const u8, path: []const u8, required: u32) !void {
        const owned_game = try self.allocator.dupe(u8, game);
        const owned_path = self.allocator.dupe(u8, path) catch |err| {
            self.allocator.free(owned_game);
            return err;
        };
        try self.enqueue(.{ .choose = .{ .game = owned_game, .path = owned_path, .required = required } });
    }

    fn clearSelection(self: *Ui) void {
        self.allocator.free(self.search_selection);
        self.search_selection = &.{};
        self.selection_fingerprint = null;
    }

    fn syncSelection(self: *Ui, results: []const java.Runtime) !void {
        var hash = std.hash.Wyhash.init(0);
        for (results) |runtime| {
            hash.update(std.mem.asBytes(&runtime.path.len));
            hash.update(runtime.path);
            hash.update(std.mem.asBytes(&runtime.major));
            hash.update(std.mem.asBytes(&runtime.vendor.len));
            hash.update(runtime.vendor);
        }
        const fingerprint = hash.final();
        if (self.selection_fingerprint == fingerprint and self.search_selection.len == results.len) return;
        const flags = try self.allocator.alloc(bool, results.len);
        @memset(flags, false);
        self.clearSelection();
        self.search_selection = flags;
        self.selection_fingerprint = fingerprint;
    }

    fn queueSelected(self: *Ui, results: []const java.Runtime) !void {
        const count = self.selectedCount();
        if (count == 0 or results.len != self.search_selection.len) return;
        const paths = try self.allocator.alloc([]const u8, count);
        var copied: usize = 0;
        errdefer {
            for (paths[0..copied]) |path| self.allocator.free(path);
            self.allocator.free(paths);
        }
        for (results, self.search_selection) |runtime, selected| {
            if (!selected) continue;
            paths[copied] = try self.allocator.dupe(u8, runtime.path);
            copied += 1;
        }
        // Ownership transfers only after append succeeds.
        try self.commands.append(self.allocator, .{ .add = paths });
    }

    fn selectedCount(self: *const Ui) usize {
        var count: usize = 0;
        for (self.search_selection) |selected| count += @intFromBool(selected);
        return count;
    }
};

pub fn hasModal(ui: *const Ui) bool {
    return ui.delete_confirmation != null;
}

fn gap(src: std.builtin.SourceLocation, height: f32) void {
    _ = dvui.spacer(src, .{ .min_size_content = .{ .h = height } });
}

fn clippedLabel(src: std.builtin.SourceLocation, text: []const u8, small: bool) void {
    dvui.labelNoFmt(src, text, .{}, .{
        .expand = .horizontal,
        .max_size_content = .width(0),
        .font = if (small) theme.captionFont() else theme.bodyFont(),
        .color_text = if (small) .{ .color = theme.colors.muted } else null,
        .background = false,
        .padding = R.all(0),
        .margin = R.all(0),
    });
}

fn frameFmt(comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), format, args) catch "";
}

fn runtimeDetails(runtime: java.Runtime) void {
    const details = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .gravity_y = 0.5,
        .padding = R.all(0),
        .margin = R.all(0),
    });
    defer details.deinit();
    const previous_clip = dvui.clip(details.data().contentRectScale().r);
    defer dvui.clipSet(previous_clip);
    clippedLabel(@src(), frameFmt("{s} · Java {d}", .{ runtime.vendor, runtime.major }), false);
    gap(@src(), theme.spacing.detail_gap);
    clippedLabel(@src(), runtime.path, true);
}

fn rowHeight() f32 {
    return @max(theme.style.sizing.control_height - theme.style.spacing.row_gap, theme.bodyFont().textSize("Java").h + theme.style.spacing.detail_gap + theme.captionFont().textSize("Java").h) + 2 * theme.style.spacing.list_row_padding;
}

pub fn setDownloadController(ui: *Ui, controller: *download.Controller) void {
    ui.download_controller = controller;
}

/// Discard commands when a launch/pack operation acquired the Java use lease.
pub fn discardCommands(ui: *Ui) void {
    discardPicker(ui);
    for (ui.commands.items) |command| command.deinit(ui.allocator);
    ui.commands.clearRetainingCapacity();
    ui.search_queued = false;
}

fn discardPickerReceipt(ui: *Ui) void {
    if (ui.picker_ticket) |ticket| if (ui.picker_service) |service| service.discard(ticket);
    ui.picker_ticket = null;
    ui.picker_path_changed = false;
}

/// Call before syncing receipts when navigating away from the Java page.
pub fn discardPicker(ui: *Ui) void {
    discardPickerReceipt(ui);
    var index: usize = 0;
    while (index < ui.commands.items.len) {
        if (ui.commands.items[index] == .browse_folder) {
            _ = ui.commands.orderedRemove(index);
        } else index += 1;
    }
}

fn requestPicker(ui: *Ui) void {
    if (ui.picker_ticket != null or !ui.acquisition_open or ui.acquisition_mode != .local or !ui.interactive or hasModal(ui)) return;
    const service = ui.picker_service orelse return;
    ui.picker_path_snapshot = ui.path_buffer;
    const ticket = service.request(.{ .kind = .folder, .title = "选择 Java 搜索目录", .default_path = std.mem.sliceTo(&ui.path_buffer, 0) }) catch |err| {
        ui.failure = err;
        return;
    };
    ui.picker_ticket = ticket;
    ui.picker_path_changed = false;
    ui.failure = null;
}

fn applyPickerResult(ui: *Ui, result: *const file_picker.Result) void {
    if (ui.picker_path_changed or !std.mem.eql(u8, std.mem.sliceTo(&ui.path_buffer, 0), std.mem.sliceTo(&ui.picker_path_snapshot, 0))) return;
    if (result.failure) |err| {
        ui.failure = err;
        return;
    }
    const path = result.path orelse return;
    if (path.len >= ui.path_buffer.len) {
        ui.failure = error.JavaSearchPathTooLong;
        return;
    }
    @memset(&ui.path_buffer, 0);
    @memcpy(ui.path_buffer[0..path.len], path);
    ui.failure = null;
}

/// App pumps the service and calls this after applying page navigation intents.
pub fn syncPicker(ui: *Ui) void {
    const ticket = ui.picker_ticket orelse return;
    const service = ui.picker_service orelse return;
    if (!ui.acquisition_open or ui.acquisition_mode != .local or !ui.interactive or hasModal(ui) or ui.search_queued) {
        discardPickerReceipt(ui);
        return;
    }
    var result = service.take(ticket) orelse return;
    defer result.deinit();
    ui.picker_ticket = null;
    applyPickerResult(ui, &result);
    ui.picker_path_changed = false;
}

fn registered(manager: *const java.Manager, path: []const u8) bool {
    for (manager.allEntries()) |runtime| if (std.mem.eql(u8, runtime.path, path)) return true;
    return false;
}

fn managementRuntime(ui: *const Ui, manager: *const java.Manager) ?java.Runtime {
    const path = ui.selected_path orelse return null;
    for (manager.allEntries()) |runtime| if (std.mem.eql(u8, runtime.path, path)) return runtime;
    for (manager.hiddenEntries()) |runtime| if (std.mem.eql(u8, runtime.path, path)) return runtime;
    return null;
}

fn sidebarRow(ui: *Ui, runtime: java.Runtime, interactive: bool, last: bool) void {
    const row = dvui.box(@src(), .{}, .{ .id_extra = @as(usize, @truncate(std.hash.Wyhash.hash(0, runtime.path))), .expand = .horizontal, .padding = R.all(0), .margin = R.all(0) });
    defer row.deinit();
    const selected = !ui.acquisition_open and if (ui.selected_path) |path| std.mem.eql(u8, path, runtime.path) else false;
    const enabled = interactive and !hasModal(ui);
    const border = if (selected) theme.style.sizing.selected_border else theme.style.sizing.control_border;
    // Preserve the design line boxes while allowing larger active fonts to fit.
    const body_font = theme.bodyFont();
    const body_height = @max(theme.typography.body * theme.typography.body_line_height, @max(body_font.textHeight(), body_font.textSize(runtime.vendor).h));
    const path_height = @max(theme.typography.caption * theme.typography.body_line_height, theme.captionFont().textHeight());
    const detail_gap = theme.style.spacing.row_gap;
    const content_height = 2 * body_height + 2 * detail_gap + path_height;
    var control: dvui.ButtonWidget = undefined;
    control.init(@src(), .{ .grayed = !enabled, .draw_focus = enabled }, .{
        .label = .{ .text = frameFmt("{s} · Java {d}", .{ runtime.vendor, runtime.major }) },
        .expand = .horizontal,
        .max_size_content = .width(0),
        .min_size_content = .height(content_height),
        .padding = R.all(theme.style.spacing.list_row_padding - border),
        .border = R.all(border),
        .corners = .all(theme.cardRadius()),
        .margin = .{ .h = if (last) 0 else theme.spacing.card_gap },
        .background = true,
        .color_border = .{ .color = if (selected) theme.colors.accent else theme.colors.outline },
        .color_fill = .{ .color = if (selected) theme.colors.selected_surface else theme.colors.sidebar },
        .color_fill_hover = .{ .color = if (enabled or selected) theme.colors.selected_surface else theme.colors.sidebar },
        .color_fill_press = .{ .color = if (enabled) theme.colors.pressed_surface else if (selected) theme.colors.selected_surface else theme.colors.sidebar },
        .tab_index = if (enabled) null else 0,
    });
    defer control.deinit();
    if (control.data().accesskit_node()) |node| {
        dvui.AccessKit.nodeSetSelected(node, selected);
        if (!enabled) {
            dvui.AccessKit.nodeSetDisabled(node);
            dvui.AccessKit.nodeRemoveAction(node, .click);
            dvui.AccessKit.nodeRemoveAction(node, .focus);
        }
    }
    if (enabled) control.processEvents() else control.processHover();
    theme.surface.buttonBackground(&control);
    const width = control.data().contentRect().w;
    dvui.labelNoFmt(@src(), runtime.vendor, .{ .align_y = 0.5 }, control.style().override(.{ .font = theme.bodyFont(), .rect = .{ .x = 0, .y = 0, .w = width, .h = body_height }, .padding = R.all(0), .margin = R.all(0), .background = false, .color_text = .{ .color = if (!enabled) theme.colors.muted else if (selected) theme.colors.selected_text else theme.colors.foreground }, .role = .none, .tab_index = 0 }));
    dvui.labelNoFmt(@src(), frameFmt("Java {d}", .{runtime.major}), .{ .align_y = 0.5 }, control.style().override(.{ .font = theme.bodyFont(), .rect = .{ .x = 0, .y = body_height + detail_gap, .w = width, .h = body_height }, .padding = R.all(0), .margin = R.all(0), .background = false, .color_text = .{ .color = theme.colors.muted }, .role = .none, .tab_index = 0 }));
    dvui.labelNoFmt(@src(), runtime.path, .{ .align_y = 0.5 }, control.style().override(.{ .font = theme.captionFont(), .rect = .{ .x = 0, .y = 2 * (body_height + detail_gap), .w = width, .h = path_height }, .padding = R.all(0), .margin = R.all(0), .background = false, .color_text = .{ .color = theme.colors.muted }, .role = .none, .tab_index = 0 }));
    components.tooltip(@src(), control.data().id, control.data().borderRectScale().r, frameFmt("{s} · Java {d}\n{s}", .{ runtime.vendor, runtime.major, runtime.path }));
    if (enabled and control.clicked()) {
        ui.selectPath(runtime.path) catch |err| {
            ui.failure = err;
            return;
        };
        discardPicker(ui);
        ui.acquisition_open = false;
    }
}

pub fn drawSidebar(ui: *Ui, manager: *java.Manager, interactive: bool) void {
    ui.interactive = interactive;
    if (components.sidebarAction(@src(), "acquire-java", "获取 Java", .{ .icon = dvui.entypo.plus, .selected = ui.acquisition_open or managementRuntime(ui, manager) == null, .enabled = interactive and !hasModal(ui), .gap_after = 0 })) ui.acquisition_open = true;
    const list = components.scrollBody(@src());
    defer list.deinit();
    components.section(@src(), "已注册 Java");
    if (manager.entries().len == 0) components.emptyState(@src(), "暂无 Java");
    const entries = manager.entries();
    for (entries, 0..) |runtime, index| sidebarRow(ui, runtime, interactive, index + 1 == entries.len);
    const hidden = manager.hiddenEntries();
    if (hidden.len != 0) {
        gap(@src(), theme.spacing.section_gap);
        if (components.sidebarItem(@src(), "hidden-java", frameFmt("已隐藏 ({d})", .{hidden.len}), .{ .icon = if (ui.show_hidden) dvui.entypo.chevron_down else dvui.entypo.chevron_right, .enabled = !hasModal(ui), .gap_after = if (ui.show_hidden) theme.spacing.section_label_gap else 0 })) ui.show_hidden = !ui.show_hidden;
        if (ui.show_hidden) for (hidden, 0..) |runtime, index| sidebarRow(ui, runtime, interactive, index + 1 == hidden.len);
    }
}

pub fn drawPage(ui: *Ui, manager: *java.Manager, download_ui: *download_view.Ui, controller: *download.Controller) void {
    const runtime = managementRuntime(ui, manager);
    if (runtime == null) ui.acquisition_open = true;
    const acquiring = ui.acquisition_open or runtime == null;
    const deletion = controller.ownedDeleteSnapshot();
    const enabled = ui.interactive and !hasModal(ui) and deletion.phase != .running;
    if (!acquiring) {
        components.title(@src(), frameFmt("Java {d}", .{runtime.?.major}));
        gap(@src(), theme.spacing.row_gap);
    }
    var download_action: download_view.Action = .none;
    var search_action: SearchAction = .none;
    if (acquiring) {
        const methods = components.toolbar(@src());
        defer methods.deinit();
        if (components.button(@src(), "下载", .{ .standalone = true, .primary = ui.acquisition_mode == .download, .enabled = ui.interactive and !hasModal(ui), .tag = "java-acquire-download" })) {
            discardPicker(ui);
            ui.acquisition_mode = .download;
        }
        if (components.button(@src(), "本机", .{ .standalone = true, .primary = ui.acquisition_mode == .local, .enabled = ui.interactive and !hasModal(ui), .tag = "java-acquire-local" })) ui.acquisition_mode = .local;
    }
    if (acquiring) {
        const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_y = 1, .padding = R.all(0), .margin = .{ .y = theme.spacing.footer_gap }, .tag = "java-actions" });
        defer actions.deinit();
        switch (ui.acquisition_mode) {
            .download => download_action = download_view.drawActions(download_ui, controller, enabled),
            .local => search_action = drawSearchActions(ui, manager, enabled),
        }
    } else {
        const actions = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal, .gravity_y = 1, .padding = R.all(0), .margin = .{ .y = theme.spacing.footer_gap }, .tag = "java-actions" });
        defer actions.deinit();
        const selected = runtime.?;
        const hidden = manager.isHidden(selected.path);
        const is_registered = registered(manager, selected.path);
        if ((hidden or is_registered) and components.button(@src(), if (hidden) "恢复显示" else "隐藏 Java", .{ .standalone = true, .enabled = enabled })) ui.queueManagement(selected.path, if (hidden) .unhide else .hide) catch |err| {
            ui.failure = err;
        };
        if (is_registered and components.button(@src(), "移除 Java", .{ .standalone = true, .enabled = enabled, .destructive = true, .tag = "java-remove" })) ui.queuePath(selected.path, false) catch |err| {
            ui.failure = err;
        };
    }
    const body = dvui.box(@src(), .{}, .{ .id_extra = if (acquiring) @as(usize, @backingInt(ui.acquisition_mode)) + 1 else @as(usize, @truncate(std.hash.Wyhash.hash(3, runtime.?.path))), .expand = .both, .padding = R.all(0), .margin = R.all(0) });
    defer body.deinit();
    const page = components.scrollBody(@src());
    defer page.deinit();
    if (ui.failure) |err| components.text(@src(), frameFmt("操作失败：{s}", .{@errorName(err)}), theme.colors.danger);
    if (!ui.interactive) components.text(@src(), "正在启动游戏或管理模组包，请稍后修改 Java。", theme.colors.muted);
    if (deletion.phase == .running) {
        components.text(@src(), "正在删除 Java…", theme.colors.muted);
        if (components.button(@src(), "取消删除", .{ .standalone = true, .enabled = ui.interactive })) ui.enqueue(.cancel) catch |err| {
            ui.failure = err;
        };
    } else if (deletion.failure) |err| {
        components.text(@src(), frameFmt("删除未完成：{s}", .{@errorName(err)}), theme.colors.danger);
        if (deletion.files_deleted) components.text(@src(), "Java 文件已删除，条目保存失败；请再次移除条目。", theme.colors.warning);
    } else if (deletion.phase == .complete) {
        components.text(@src(), "Java 已移除", theme.colors.muted);
    } else if (deletion.phase == .canceled) {
        components.text(@src(), "删除已取消；条目保留，部分文件可能已删除，可重试完成清理。", theme.colors.warning);
    }
    if (acquiring) {
        switch (ui.acquisition_mode) {
            .download => {
                download_view.drawInline(download_ui, controller, enabled);
                download_view.applyAction(download_ui, download_action);
            },
            .local => {
                drawSearch(ui, manager, enabled);
                applySearchAction(ui, manager, search_action);
            },
        }
        return;
    }
    const compact = dvui.windowRect().h < theme.style.layout.compact_height;
    const panel = components.formPanel(@src(), .{ .tag = "java-runtime-detail", .compact = compact });
    defer panel.deinit();
    const selected = runtime.?;
    components.text(@src(), selected.vendor, theme.colors.muted);
    gap(@src(), if (compact) theme.spacing.detail_gap else theme.spacing.section_gap);
    components.fieldLabel(@src(), "路径");
    components.hint(@src(), selected.path);
    if (manager.isHidden(selected.path)) {
        gap(@src(), if (compact) theme.spacing.detail_gap else theme.spacing.section_gap);
        components.text(@src(), "已隐藏 · 不参与游戏启动", theme.colors.muted);
    }
}

const SearchAction = enum { none, search, cancel, add };

fn drawSearchActions(ui: *Ui, manager: *java.Manager, enabled: bool) SearchAction {
    const busy = ui.search_queued or manager.isSearching();
    if (!busy and ui.search_started) {
        ui.syncSelection(manager.searchResults()) catch |err| {
            ui.failure = err;
            return .none;
        };
        for (manager.searchResults(), 0..) |runtime, index| {
            if (registered(manager, runtime.path)) ui.search_selection[index] = false;
        }
    }
    const compact = dvui.parentGet().data().contentRect().w < 400;
    if (!busy and ui.search_started and manager.searchResults().len != 0) {
        if (components.button(@src(), if (compact) "添加所选" else "添加所选 Java", .{ .standalone = true, .enabled = enabled and ui.selectedCount() != 0, .min_width = 0, .placement = .footer, .tag = "java-search-add", .tooltip = "添加所选 Java" })) return .add;
    }
    if (components.button(@src(), if (busy) "取消搜索" else if (compact) "搜索" else "搜索本机 Java", .{ .standalone = true, .enabled = enabled and (!busy or !ui.search_queued), .primary = !busy, .min_width = 0, .gravity_x = 1, .placement = .footer, .tag = "java-search-start", .tooltip = if (busy) "取消搜索" else "搜索本机 Java" })) return if (busy) .cancel else .search;
    return .none;
}

// Footer buttons reserve space first; read drafts after their widgets process input.
fn applySearchAction(ui: *Ui, manager: *java.Manager, action: SearchAction) void {
    switch (action) {
        .none => {},
        .cancel => ui.enqueue(.cancel_search) catch |err| {
            ui.failure = err;
        },
        .search => {
            ui.queuePath(std.mem.sliceTo(&ui.path_buffer, 0), true) catch |err| {
                ui.failure = err;
                return;
            };
            ui.search_queued = true;
            ui.resetSearch();
            ui.search_started = true;
            ui.failure = null;
        },
        .add => ui.queueSelected(manager.searchResults()) catch |err| {
            ui.add_failure = err;
        },
    }
}

fn clearDeleteConfirmation(ui: *Ui) void {
    if (ui.delete_confirmation) |path| ui.allocator.free(path);
    ui.delete_confirmation = null;
}

fn drawDeleteConfirmation(ui: *Ui) void {
    const path = ui.delete_confirmation orelse return;
    var open = true;
    {
        const modal = components.modalWithClose(@src(), "删除启动器下载的 Java", theme.style.dialogs.java_delete_height, &open);
        defer modal.deinit();
        // Reserve all actions before allowing the information to fill the remainder.
        {
            const actions = components.modalActions(@src(), 3);
            defer actions.deinit();
            if (actions.action(@src(), 0, "仅移除条目", .{ .enabled = ui.interactive })) {
                const owned = ui.allocator.dupe(u8, path) catch |err| {
                    ui.failure = err;
                    return;
                };
                ui.enqueue(.{ .forget = owned }) catch |err| {
                    ui.failure = err;
                    return;
                };
                open = false;
            }
            if (actions.action(@src(), 1, "删除 Java 文件", .{ .enabled = ui.interactive, .primary = true, .destructive = true })) {
                ui.queueManagement(path, .delete_files) catch |err| {
                    ui.failure = err;
                    return;
                };
                open = false;
            }
            if (actions.action(@src(), 2, "取消", .{})) open = false;
        }
        const information = components.scrollBody(@src());
        defer information.deinit();
        const confirmation = components.modalSection(@src(), .{ .min_height = 172, .gap_after = 0, .tag = "java-delete-information" });
        defer confirmation.deinit();
        components.text(@src(), path, theme.colors.muted);
        gap(@src(), theme.spacing.card_gap);
        components.text(@src(), "删除文件只作用于经所有权凭据验证的 Java 安装目录。此操作无法撤销。", theme.colors.muted);
    }
    if (!open) clearDeleteConfirmation(ui);
}

pub fn drawModal(ui: *Ui) void {
    drawDeleteConfirmation(ui);
}

fn drawSearch(ui: *Ui, manager: *java.Manager, enabled: bool) void {
    const busy = ui.search_queued or manager.isSearching();
    if (busy) discardPicker(ui);
    {
        const panel = components.formPanel(@src(), .{ .tag = "java-search-form" });
        defer panel.deinit();
        if (components.field(@src(), "搜索路径", &ui.path_buffer, .{ .tag = "java-search-path", .gap_after = theme.style.spacing.row_gap }) and ui.picker_ticket != null) ui.picker_path_changed = true;
        if (ui.picker_service) |service| {
            if (components.button(@src(), "浏览文件夹", .{ .enabled = enabled and !busy and ui.picker_ticket == null and !service.isBusy(), .tag = "java-search-browse" })) ui.enqueue(.browse_folder) catch |err| {
                ui.failure = err;
            };
        }
        components.hint(@src(), "目录或 Java 文件；留空搜索 PATH");
    }
    if (!ui.search_started and !busy) return;
    if (busy or ui.search_queued) {
        components.text(@src(), "正在搜索…", theme.colors.muted);
        return;
    }
    if (manager.searchFailure()) |err| {
        components.text(@src(), frameFmt("搜索失败：{s}", .{@errorName(err)}), theme.colors.danger);
        return;
    }
    const results = manager.searchResults();
    ui.syncSelection(results) catch |err| {
        ui.failure = err;
        return;
    };
    if (results.len == 0) components.emptyState(@src(), "未找到 Java，可修改搜索路径后重试。");
    if (results.len != 0) {
        const list = dvui.box(@src(), .{}, .{ .expand = .horizontal, .padding = R.all(0), .margin = .{ .y = theme.spacing.card_gap }, .background = false });
        defer list.deinit();
        for (results, 0..) |result, index| {
            const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = @as(usize, @truncate(std.hash.Wyhash.hash(0, result.path))), .expand = .horizontal, .min_size_content = .{ .h = rowHeight() - 2 * theme.spacing.list_row_padding }, .padding = .{ .y = theme.spacing.list_row_padding, .h = theme.spacing.list_row_padding }, .margin = R.all(0) });
            {
                defer row.deinit();
                if (registered(manager, result.path)) {
                    ui.search_selection[index] = false;
                    dvui.labelNoFmt(@src(), "已注册", .{}, .{ .gravity_y = 0.5, .padding = R.all(0), .margin = .{ .w = theme.spacing.card_gap }, .color_text = .{ .color = theme.colors.muted }, .background = false });
                } else if (enabled) {
                    _ = dvui.checkbox(@src(), &ui.search_selection[index], null, .{ .min_size_content = .{ .w = theme.style.sizing.selection_diameter, .h = theme.style.sizing.selection_diameter }, .max_size_content = .{ .w = theme.style.sizing.selection_diameter, .h = theme.style.sizing.selection_diameter }, .gravity_y = 0.5, .margin = .{ .w = theme.spacing.card_gap }, .padding = R.all(theme.style.spacing.tooltip_padding), .label = .{ .text = frameFmt("选择 {s} Java {d} {s}", .{ result.vendor, result.major, result.path }) } });
                }
                runtimeDetails(result);
            }
            _ = dvui.separator(@src(), .{ .id_extra = @as(usize, @truncate(std.hash.Wyhash.hash(0, result.path))), .expand = .horizontal, .margin = R.all(0) });
        }
    }
    if (ui.add_failure) |err| components.text(@src(), frameFmt("添加失败：{s}", .{@errorName(err)}), theme.colors.danger);
}

pub fn versionChoice(ui: *Ui, manager: *java.Manager, game: []const u8, required: u32) void {
    ui.syncChoiceContext(game, required);
    if (components.action(@src(), "获取 Java", ui.interactive and !hasModal(ui))) {
        ui.acquisition_mode = .download;
        ui.requested_major = required;
        ui.download_requested = true;
    }
    const heading = frameFmt("Java {d}", .{required});
    clippedLabel(@src(), heading, true);
    gap(@src(), theme.spacing.row_gap);
    if (ui.choice_failure) |err| {
        components.text(@src(), frameFmt("选择失败：{s}", .{@errorName(err)}), theme.colors.danger);
        gap(@src(), theme.spacing.row_gap);
    }
    const entries = manager.entries();
    const selected = manager.resolve(game, required);
    var selected_index: ?usize = null;
    var compatible_count: usize = 0;
    for (entries) |runtime| {
        if (!java.compatible(runtime.major, required)) continue;
        if (selected) |current| {
            if (std.mem.eql(u8, current.path, runtime.path)) selected_index = compatible_count;
        }
        compatible_count += 1;
    }
    if (compatible_count == 0) {
        clippedLabel(@src(), "未选择", true);
        return;
    }
    const current_label = if (selected) |runtime| frameFmt("{s} · Java {d} · {s}", .{ runtime.vendor, runtime.major, runtime.path }) else "未选择";
    var dropdown: dvui.DropdownWidget = undefined;
    dropdown.init(@src(), .{
        .selected_index = selected_index,
        .label = null,
        .placeholder = null,
    }, components.entryOptions(heading, .{ .gap_after = 0 }));
    defer dropdown.deinit();
    {
        const control = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
            .padding = R.all(0),
            .margin = R.all(0),
        });
        clippedLabel(@src(), current_label, false);
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = theme.spacing.row_gap } });
        dvui.icon(@src(), "展开 Java 选项", dvui.entypo.chevron_small_down, .{}, .{
            .min_size_content = .{ .w = theme.style.sizing.compact_icon, .h = theme.style.sizing.compact_icon },
            .max_size_content = .{ .w = theme.style.sizing.compact_icon, .h = theme.style.sizing.compact_icon },
            .gravity_y = 0.5,
            .padding = R.all(0),
            .margin = R.all(0),
            .role = .none,
        });
        control.deinit();
    }
    if (dropdown.dropped()) {
        for (entries) |runtime| {
            if (!java.compatible(runtime.major, required)) continue;
            const item = dropdown.addChoice();
            {
                const content = dvui.box(@src(), .{}, .{
                    .expand = .horizontal,
                    .min_size_content = .{ .h = rowHeight() - 2 * theme.spacing.list_row_padding },
                    .padding = .{ .y = theme.spacing.control_padding_y, .h = theme.spacing.control_padding_y },
                    .margin = R.all(0),
                    .label = .{ .text = frameFmt("{s} Java {d} {s}", .{ runtime.vendor, runtime.major, runtime.path }) },
                });
                runtimeDetails(runtime);
                content.deinit();
            }
            const chosen = item.activeRect() != null;
            item.deinit();
            if (chosen) {
                dropdown.close();
                ui.queueChoice(game, runtime.path, required) catch |err| {
                    ui.choice_failure = err;
                };
            }
        }
    }
}

// Call only after the parent's entire draw, including floating widgets, is closed.
pub fn finish(ui: *Ui, manager: *java.Manager) void {
    for (ui.commands.items) |command| {
        if (!ui.interactive and command != .cancel) continue;
        switch (command) {
            .browse_folder => if (!manager.isSearching() and !ui.search_queued) requestPicker(ui),
            .search => |path| {
                discardPickerReceipt(ui);
                ui.failure = null;
                manager.search(path) catch |err| {
                    ui.failure = err;
                };
                ui.search_queued = false;
            },
            .cancel_search => {
                manager.cancelSearch();
                ui.search_queued = false;
                ui.search_started = false;
                ui.clearSelection();
            },
            .cancel => {
                discardPickerReceipt(ui);
                manager.cancelSearch();
                if (ui.download_controller) |controller| controller.cancel();
            },
            .remove => |path| {
                ui.failure = null;
                var owned = false;
                if (ui.download_controller) |controller| {
                    if (controller.checkOwnedStorage(path)) |_| {
                        owned = true;
                    } else |_| {}
                }
                if (owned) {
                    const copy = ui.allocator.dupe(u8, path) catch |err| {
                        ui.failure = err;
                        continue;
                    };
                    clearDeleteConfirmation(ui);
                    ui.delete_confirmation = copy;
                } else manager.forget(path) catch |err| {
                    ui.failure = err;
                };
            },
            .forget => |path| {
                ui.failure = null;
                manager.forget(path) catch |err| {
                    ui.failure = err;
                };
            },
            .hide => |path| {
                ui.failure = null;
                manager.hide(path) catch |err| {
                    ui.failure = err;
                };
            },
            .unhide => |path| {
                ui.failure = null;
                manager.unhide(path) catch |err| {
                    ui.failure = err;
                };
            },
            .delete_files => |path| {
                ui.failure = null;
                const controller = ui.download_controller orelse {
                    ui.failure = error.JavaDeleteUnavailable;
                    continue;
                };
                controller.beginOwnedDelete(path) catch |err| {
                    ui.failure = err;
                };
            },
            .add => |paths| {
                ui.add_failure = null;
                manager.add(paths) catch |err| {
                    ui.add_failure = err;
                    if (!ui.acquisition_open) ui.failure = err;
                    continue;
                };
                ui.clearSelection();
            },
            .choose => |choice| {
                ui.syncChoiceContext(choice.game, choice.required);
                ui.choice_failure = null;
                manager.choose(choice.game, choice.path, choice.required) catch |err| {
                    ui.choice_failure = err;
                };
            },
        }
    }
    for (ui.commands.items) |command| command.deinit(ui.allocator);
    ui.commands.clearRetainingCapacity();
}

test "deferred paths and choices own their input bytes" {
    var ui = Ui.init(std.testing.allocator);
    defer ui.deinit();
    var path = [_]u8{ '/', 'j', 'd', 'k' };
    var game = [_]u8{ '1', '.', '2', '1' };
    try ui.queuePath(&path, true);
    try ui.queuePath(&path, false);
    try ui.queueChoice(&game, &path, 21);
    @memset(&path, 'x');
    @memset(&game, 'y');
    try std.testing.expectEqualStrings("/jdk", ui.commands.items[0].search);
    try std.testing.expectEqualStrings("/jdk", ui.commands.items[1].remove);
    try std.testing.expectEqualStrings("/jdk", ui.commands.items[2].choose.path);
    try std.testing.expectEqualStrings("1.21", ui.commands.items[2].choose.game);
    try std.testing.expectEqual(@as(u32, 21), ui.commands.items[2].choose.required);
}

test "search selection follows result identity and adds only checked owned paths" {
    var ui = Ui.init(std.testing.allocator);
    defer ui.deinit();
    var first_path = [_]u8{ '/', 'a' };
    const results = [_]java.Runtime{
        .{ .path = &first_path, .major = 21, .architecture = @import("../core/java_runtime.zig").host(), .vendor = "Vendor A" },
        .{ .path = "/b", .major = 17, .architecture = @import("../core/java_runtime.zig").host(), .vendor = "Vendor B" },
    };
    try ui.syncSelection(&results);
    ui.search_selection[0] = true;
    try ui.syncSelection(&results);
    try std.testing.expect(ui.search_selection[0]);
    try ui.queueSelected(&results);
    first_path[1] = 'z';
    try std.testing.expectEqual(@as(usize, 1), ui.commands.items[0].add.len);
    try std.testing.expectEqualStrings("/a", ui.commands.items[0].add[0]);
    try ui.syncSelection(&results);
    try std.testing.expectEqual(@as(usize, 0), ui.selectedCount());
    try ui.queueSelected(&results);
    try std.testing.expectEqual(@as(usize, 1), ui.commands.items.len);
}

fn exerciseQueueAllocations(a: std.mem.Allocator) !void {
    var ui = Ui.init(a);
    defer ui.deinit();
    try ui.queuePath("/search", true);
    try ui.queuePath("/remove", false);
    try ui.queueChoice("1.21", "/chosen", 21);
    const results = [_]java.Runtime{
        .{ .path = "/a", .major = 21, .architecture = @import("../core/java_runtime.zig").host(), .vendor = "Vendor A" },
        .{ .path = "/b", .major = 21, .architecture = @import("../core/java_runtime.zig").host(), .vendor = "Vendor B" },
    };
    try ui.syncSelection(&results);
    @memset(ui.search_selection, true);
    try ui.queueSelected(&results);
}

test "deferred command ownership releases all partial allocations" {
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, exerciseQueueAllocations, .{});
}

test "a new search clears selection even when results are identical" {
    var ui = Ui.init(std.testing.allocator);
    defer ui.deinit();
    const results = [_]java.Runtime{.{ .path = "/a", .major = 21, .architecture = @import("../core/java_runtime.zig").host(), .vendor = "Vendor A" }};
    try ui.syncSelection(&results);
    ui.search_selection[0] = true;
    ui.clearSelection();
    try ui.syncSelection(&results);
    try std.testing.expectEqual(@as(usize, 0), ui.selectedCount());
}

test "choice persistence failure is visible scoped and reset on successful retry" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, ".vela", .default_dir);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".vela/java.json",
        .data = comptime std.fmt.comptimePrint("{{\"version\":2,\"runtimes\":[{{\"path\":\"/java-test\",\"major\":21,\"vendor\":\"Test Vendor\",\"architecture\":\"{s}\"}}],\"choices\":[],\"hidden\":[]}}", .{@tagName(@import("../core/java_runtime.zig").host())}),
    });
    var root_buffer: [4096]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var manager = try java.Manager.init(a, io, root);
    defer manager.deinit();
    var ui = Ui.init(a);
    defer ui.deinit();
    try tmp.dir.deleteFile(io, ".vela/java.json");
    try tmp.dir.createDir(io, ".vela/java.json", .default_dir);
    try ui.queueChoice("game", "/java-test", 21);
    finish(&ui, &manager);
    try std.testing.expect(ui.choice_failure != null);
    try std.testing.expect(ui.failure == null);
    const failure = ui.choice_failure;
    ui.syncChoiceContext("game", 21);
    try std.testing.expectEqual(failure, ui.choice_failure);
    ui.syncChoiceContext("other-game", 21);
    try std.testing.expect(ui.choice_failure == null);
    try ui.queueChoice("game", "/java-test", 21);
    finish(&ui, &manager);
    try std.testing.expect(ui.choice_failure != null);
    ui.syncChoiceContext("game", 17);
    try std.testing.expect(ui.choice_failure == null);
    try ui.queueChoice("game", "/java-test", 21);
    finish(&ui, &manager);
    try std.testing.expect(ui.choice_failure != null);
    try tmp.dir.deleteDir(io, ".vela/java.json");
    try ui.queueChoice("game", "/java-test", 21);
    finish(&ui, &manager);
    try std.testing.expect(ui.choice_failure == null);
    try std.testing.expectEqualStrings("/java-test", manager.selectedPath("game").?);
}

test "failed add keeps selection and allows a smaller retry without fatal search error" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [4096]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var manager = try java.Manager.init(a, std.testing.io, root);
    defer manager.deinit();
    var ui = Ui.init(a);
    defer ui.deinit();
    const results = [_]java.Runtime{
        .{ .path = "/a", .major = 21, .architecture = @import("../core/java_runtime.zig").host(), .vendor = "Vendor A" },
        .{ .path = "/b", .major = 21, .architecture = @import("../core/java_runtime.zig").host(), .vendor = "Vendor B" },
    };
    ui.search_started = true;
    try ui.syncSelection(&results);
    @memset(ui.search_selection, true);
    try ui.queueSelected(&results);
    finish(&ui, &manager);
    try std.testing.expect(ui.add_failure != null);
    try std.testing.expect(ui.failure == null);
    try std.testing.expect(ui.search_started);
    try std.testing.expectEqual(@as(usize, 2), ui.selectedCount());
    try std.testing.expectEqual(@as(usize, 0), ui.commands.items.len);
    ui.search_selection[1] = false;
    try ui.queueSelected(&results);
    try std.testing.expectEqual(@as(usize, 1), ui.commands.items[0].add.len);
    finish(&ui, &manager);
    try std.testing.expect(ui.add_failure != null);
    try std.testing.expect(ui.failure == null);
    try std.testing.expectEqual(@as(usize, 1), ui.selectedCount());
    try std.testing.expectEqual(@as(usize, 0), ui.commands.items.len);
    ui.resetSearch();
    try std.testing.expect(ui.add_failure == null);
    try std.testing.expectEqual(@as(usize, 0), ui.selectedCount());
}

test "management commands and selected paths own bytes and discard releases them" {
    const a = std.testing.allocator;
    var ui = Ui.init(a);
    defer ui.deinit();
    var path = [_]u8{ '/', 'j', 'a', 'v', 'a' };
    try ui.selectPath(&path);
    try ui.queueManagement(&path, .hide);
    try ui.queueManagement(&path, .unhide);
    try ui.queueManagement(&path, .delete_files);
    @memset(&path, 'x');
    try std.testing.expectEqualStrings("/java", ui.selected_path.?);
    try std.testing.expectEqualStrings("/java", ui.commands.items[0].hide);
    try std.testing.expectEqualStrings("/java", ui.commands.items[1].unhide);
    try std.testing.expectEqualStrings("/java", ui.commands.items[2].delete_files);
    discardCommands(&ui);
    try std.testing.expectEqual(@as(usize, 0), ui.commands.items.len);
    try std.testing.expect(!ui.search_queued);
}

test "deferred management filters choices and obeys use lease barrier" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    const path = try std.fs.path.join(a, &.{ root, "java" });
    defer a.free(path);
    var manager = try java.Manager.init(a, std.testing.io, root);
    defer manager.deinit();
    try manager.addDownloaded(.{ .path = path, .major = 21, .architecture = @import("../core/java_runtime.zig").host(), .vendor = "OpenJDK" });
    try manager.choose("game", path, 21);
    var ui = Ui.init(a);
    defer ui.deinit();
    try ui.queueManagement(path, .hide);
    finish(&ui, &manager);
    try std.testing.expect(ui.failure == null);
    try std.testing.expect(manager.isHidden(path));
    try std.testing.expect(manager.resolve("game", 21) == null);
    try ui.queueManagement(path, .unhide);
    finish(&ui, &manager);
    try std.testing.expect(!manager.isHidden(path));
    ui.interactive = false;
    try ui.queueManagement(path, .hide);
    finish(&ui, &manager);
    try std.testing.expect(!manager.isHidden(path));
    try std.testing.expectEqual(@as(usize, 0), ui.commands.items.len);
    ui.interactive = true;
    try ui.queuePath(path, false);
    finish(&ui, &manager);
    try std.testing.expect(ui.delete_confirmation == null);
    try std.testing.expectEqual(@as(usize, 0), manager.entries().len);
}

test "restoring a forgotten hidden Java clears suppression without registering it" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    const path = try std.fs.path.join(a, &.{ root, "java" });
    defer a.free(path);
    var manager = try java.Manager.init(a, std.testing.io, root);
    defer manager.deinit();
    try manager.addDownloaded(.{ .path = path, .major = 21, .architecture = @import("../core/java_runtime.zig").host(), .vendor = "OpenJDK" });
    var ui = Ui.init(a);
    defer ui.deinit();
    try ui.selectPath(path);
    try ui.queueManagement(path, .hide);
    finish(&ui, &manager);
    try ui.enqueue(.{ .forget = try a.dupe(u8, path) });
    finish(&ui, &manager);
    try std.testing.expect(ui.failure == null);
    try std.testing.expect(manager.isHidden(path));
    try std.testing.expect(!registered(&manager, path));
    try std.testing.expect(managementRuntime(&ui, &manager) != null);
    try ui.queueManagement(path, .unhide);
    finish(&ui, &manager);
    try std.testing.expect(ui.failure == null);
    try std.testing.expect(!manager.isHidden(path));
    try std.testing.expect(!registered(&manager, path));
    try std.testing.expectEqual(@as(usize, 0), manager.entries().len);
    try std.testing.expect(manager.resolve("game", 21) == null);
}

test "UI layout Java search-only runtime cannot resolve management after all registered runtimes are removed" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var manager = try java.Manager.init(a, std.testing.io, root);
    defer manager.deinit();
    const runtime: java.Runtime = .{ .path = "/fixture/java", .architecture = @import("../core/java_runtime.zig").host(), .vendor = "Fixture", .major = 21 };
    try manager.addDownloaded(runtime);
    var ui = Ui.init(a);
    defer ui.deinit();
    try ui.selectPath(runtime.path);
    ui.acquisition_open = false;
    try std.testing.expect(managementRuntime(&ui, &manager) != null);
    try ui.queuePath(runtime.path, false);
    finish(&ui, &manager);
    try std.testing.expectEqual(@as(usize, 0), manager.allEntries().len);
    try manager.state.search_visible.append(manager.state.arena.allocator(), runtime);
    ui.search_started = true;
    try std.testing.expectEqual(@as(usize, 1), manager.searchResults().len);
    try std.testing.expect(managementRuntime(&ui, &manager) == null);
    try ui.syncSelection(manager.searchResults());
    ui.search_selection[0] = true;
    try ui.queueSelected(manager.searchResults());
    try std.testing.expectEqualStrings(runtime.path, ui.commands.items[0].add[0]);
}

test "UI layout Java picker receipts copy bounded paths and preserve canceled or edited drafts" {
    var ui = Ui.init(std.testing.allocator);
    defer ui.deinit();
    const original = "/draft/java";
    @memcpy(ui.path_buffer[0..original.len], original);
    ui.picker_path_snapshot = ui.path_buffer;
    var receipt: file_picker.Result = .{};
    receipt.path = null;
    receipt.failure = null;
    applyPickerResult(&ui, &receipt);
    try std.testing.expectEqualStrings(original, std.mem.sliceTo(&ui.path_buffer, 0));
    var picked = [_]u8{ '/', 'j', 'd', 'k' };
    receipt.path = &picked;
    applyPickerResult(&ui, &receipt);
    @memset(&picked, 'x');
    try std.testing.expectEqualStrings("/jdk", std.mem.sliceTo(&ui.path_buffer, 0));
    ui.picker_path_snapshot = ui.path_buffer;
    receipt.path = "/stale/java";
    ui.picker_path_changed = true;
    applyPickerResult(&ui, &receipt);
    try std.testing.expectEqualStrings("/jdk", std.mem.sliceTo(&ui.path_buffer, 0));
    ui.picker_path_changed = false;
    ui.path_buffer[1] = 'e';
    applyPickerResult(&ui, &receipt);
    try std.testing.expectEqualStrings("/edk", std.mem.sliceTo(&ui.path_buffer, 0));
    ui.picker_path_snapshot = ui.path_buffer;
    const too_long: [4096]u8 = @splat('a');
    receipt.path = &too_long;
    applyPickerResult(&ui, &receipt);
    try std.testing.expectEqual(error.JavaSearchPathTooLong, ui.failure.?);
    try std.testing.expectEqualStrings("/edk", std.mem.sliceTo(&ui.path_buffer, 0));
    ui.failure = null;
    receipt.path = null;
    receipt.failure = error.DialogFailed;
    applyPickerResult(&ui, &receipt);
    try std.testing.expectEqual(error.DialogFailed, ui.failure.?);
}

test "UI layout Java browse captures latest draft and discards canceled navigated and stale receipts" {
    const Driver = struct {
        pending: ?*file_picker.Pending = null,
        fn start(context: ?*anyopaque, pending: *file_picker.Pending) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.pending = pending;
        }
        fn complete(self: *@This(), path: ?[]const u8) void {
            const pending = self.pending.?;
            self.pending = null;
            pending.complete(.{ .path = path });
        }
    };
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var manager = try java.Manager.init(a, std.testing.io, root);
    defer manager.deinit();
    var service = file_picker.Service.init(a);
    defer service.deinit();
    var ui = Ui.init(a);
    defer ui.deinit();
    ui.picker_service = &service;
    ui.acquisition_mode = .local;
    var driver: Driver = .{};
    const picker_driver: file_picker.Driver = .{ .context = &driver, .start = Driver.start };
    const initial = "/draft/old";
    @memcpy(ui.path_buffer[0..initial.len], initial);
    try ui.enqueue(.browse_folder);
    const latest = "/draft/latest";
    @memset(&ui.path_buffer, 0);
    @memcpy(ui.path_buffer[0..latest.len], latest);
    finish(&ui, &manager);
    try std.testing.expect(ui.picker_ticket != null);
    service.startPending(picker_driver);
    try std.testing.expectEqual(file_picker.Kind.folder, driver.pending.?.kind);
    try std.testing.expectEqualStrings(latest, driver.pending.?.default_path);
    driver.complete("/picked/jdk");
    syncPicker(&ui);
    try std.testing.expect(ui.picker_ticket == null);
    try std.testing.expectEqualStrings("/picked/jdk", std.mem.sliceTo(&ui.path_buffer, 0));
    try ui.enqueue(.browse_folder);
    finish(&ui, &manager);
    service.startPending(picker_driver);
    driver.complete(null);
    syncPicker(&ui);
    try std.testing.expectEqualStrings("/picked/jdk", std.mem.sliceTo(&ui.path_buffer, 0));
    try ui.enqueue(.browse_folder);
    finish(&ui, &manager);
    service.startPending(picker_driver);
    ui.path_buffer[1] = 'e';
    driver.complete("/stale/jdk");
    syncPicker(&ui);
    try std.testing.expectEqualStrings("/eicked/jdk", std.mem.sliceTo(&ui.path_buffer, 0));
    try ui.enqueue(.browse_folder);
    finish(&ui, &manager);
    service.startPending(picker_driver);
    ui.acquisition_mode = .download;
    driver.complete("/departed/jdk");
    syncPicker(&ui);
    try std.testing.expect(ui.picker_ticket == null);
    try std.testing.expectEqualStrings("/eicked/jdk", std.mem.sliceTo(&ui.path_buffer, 0));
    try std.testing.expect(!service.isBusy());
    ui.acquisition_mode = .local;
    try ui.enqueue(.browse_folder);
    discardPicker(&ui);
    finish(&ui, &manager);
    try std.testing.expect(!service.isBusy());
    try ui.enqueue(.browse_folder);
    finish(&ui, &manager);
    service.startPending(picker_driver);
    discardPicker(&ui);
    driver.complete("/discarded/jdk");
    syncPicker(&ui);
    try std.testing.expectEqualStrings("/eicked/jdk", std.mem.sliceTo(&ui.path_buffer, 0));
    try std.testing.expect(!service.isBusy());
}

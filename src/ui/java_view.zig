const std = @import("std");
const dvui = @import("dvui");
const java = @import("java_manager.zig");
const download = @import("java_download_controller.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const download_view = @import("java_download_view.zig");
const R = dvui.Rect;

const Choice = struct { game: []const u8, path: []const u8, required: u32 };
const Command = union(enum) {
    search: []const u8,
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
            .cancel, .cancel_search => {},
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

    pub fn init(a: std.mem.Allocator) Ui {
        return .{ .allocator = a };
    }

    pub fn deinit(self: *Ui) void {
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
    fn queueAddOne(self: *Ui, path: []const u8) !void {
        const paths = try self.allocator.alloc([]const u8, 1);
        errdefer self.allocator.free(paths);
        paths[0] = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(paths[0]);
        try self.commands.append(self.allocator, .{ .add = paths });
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
        .font = if (small) dvui.themeGet().font_body.withSize(14) else dvui.themeGet().font_body,
        .color_text = if (small) .{ .color = theme.muted } else null,
        .background = false,
        .padding = R.all(0),
        .margin = R.all(0),
    });
}

fn frameFmt(comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), format, args) catch "";
}

// Keep the button registered when concealed so keyboard focus can reveal it.
fn iconButton(src: std.builtin.SourceLocation, name: []const u8, asset: []const u8, revealed: bool) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{}, .{
        .min_size_content = .{ .w = 20, .h = 20 },
        .max_size_content = .{ .w = 20, .h = 20 },
        .padding = R.all(10),
        .margin = R.all(0),
        .corners = .all(8),
        .border = R.all(0),
        .gravity_y = 0.5,
        .label = .{ .text = name },
    });
    button.processEvents();
    const visible = revealed or button.hover or dvui.focusedWidgetIdInCurrentSubwindow() == button.data().id;
    const clicked = button.clicked();
    const rect = button.data().borderRectScale().r;
    const control_id = button.data().id;
    if (visible) {
        button.drawBackground();
        dvui.icon(@src(), name, asset, .{}, button.style().override(.{
            .min_size_content = .{ .w = 20, .h = 20 },
            .max_size_content = .{ .w = 20, .h = 20 },
            .padding = R.all(0),
            .margin = R.all(0),
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .role = .none,
        }));
        button.drawFocus();
    }
    button.deinit();
    components.tooltip(src, control_id, rect, name);
    return clicked;
}

fn textButton(src: std.builtin.SourceLocation, text: []const u8, disabled: bool, highlighted: bool) bool {
    _ = highlighted;
    return components.action(src, text, !disabled);
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
    gap(@src(), 4);
    clippedLabel(@src(), runtime.path, true);
}

fn rowHeight() f32 {
    return @max(40, dvui.themeGet().font_body.textSize("Java").h + 4 + dvui.themeGet().font_body.withSize(14).textSize("Java").h) + 20;
}

pub fn setDownloadController(ui: *Ui, controller: *download.Controller) void {
    ui.download_controller = controller;
}

/// Discard commands when a launch/pack operation acquired the Java use lease.
pub fn discardCommands(ui: *Ui) void {
    for (ui.commands.items) |command| command.deinit(ui.allocator);
    ui.commands.clearRetainingCapacity();
    ui.search_queued = false;
}

fn registered(manager: *const java.Manager, path: []const u8) bool {
    for (manager.allEntries()) |runtime| if (std.mem.eql(u8, runtime.path, path)) return true;
    return false;
}

fn managementRuntime(ui: *const Ui, manager: *const java.Manager) ?java.Runtime {
    const path = ui.selected_path orelse return null;
    for (manager.allEntries()) |runtime| if (std.mem.eql(u8, runtime.path, path)) return runtime;
    for (manager.searchResults()) |runtime| if (std.mem.eql(u8, runtime.path, path)) return runtime;
    for (manager.hiddenEntries()) |runtime| if (std.mem.eql(u8, runtime.path, path)) return runtime;
    return null;
}

fn sidebarRow(ui: *Ui, runtime: java.Runtime, interactive: bool, indent: f32) void {
    const row = dvui.box(@src(), .{}, .{ .id_extra = @as(usize, @truncate(std.hash.Wyhash.hash(0, runtime.path))), .expand = .horizontal, .padding = R.all(0), .margin = R.all(0) });
    defer row.deinit();
    const selected = !ui.acquisition_open and if (ui.selected_path) |path| std.mem.eql(u8, path, runtime.path) else false;
    if (components.sidebarItem(@src(), runtime.path, frameFmt("{s} · Java {d}", .{ runtime.vendor, runtime.major }), .{ .selected = selected, .enabled = interactive and !hasModal(ui), .indent = indent, .subtitle = runtime.path })) {
        ui.selectPath(runtime.path) catch |err| {
            ui.failure = err;
            return;
        };
        ui.acquisition_open = false;
    }
    gap(@src(), 8);
}

pub fn drawSidebar(ui: *Ui, manager: *java.Manager, interactive: bool) void {
    ui.interactive = interactive;
    if (components.sidebarItem(@src(), "acquire-java", "获取 Java", .{ .icon = dvui.entypo.plus, .selected = ui.acquisition_open or managementRuntime(ui, manager) == null, .enabled = interactive and !hasModal(ui) })) ui.acquisition_open = true;
    gap(@src(), 12);
    const list = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .expand = .both, .padding = R.all(0), .margin = R.all(0), .border = R.all(0), .background = false });
    defer list.deinit();
    components.section(@src(), "已注册 Java");
    if (manager.entries().len == 0) components.emptyState(@src(), "暂无 Java");
    for (manager.entries()) |runtime| sidebarRow(ui, runtime, interactive, 0);
    const hidden = manager.hiddenEntries();
    if (hidden.len != 0) {
        gap(@src(), 16);
        if (components.sidebarItem(@src(), "hidden-java", frameFmt("已隐藏 ({d})", .{hidden.len}), .{ .icon = if (ui.show_hidden) dvui.entypo.chevron_down else dvui.entypo.chevron_right, .enabled = !hasModal(ui) })) ui.show_hidden = !ui.show_hidden;
        if (ui.show_hidden) for (hidden) |runtime| sidebarRow(ui, runtime, interactive, 12);
    }
}

pub fn drawPage(ui: *Ui, manager: *java.Manager, download_ui: *download_view.Ui, controller: *download.Controller) void {
    const page = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .expand = .both, .padding = R.all(0), .margin = R.all(0), .border = R.all(0), .background = false });
    defer page.deinit();
    dvui.labelNoFmt(@src(), "Java 管理", .{}, .{ .font = dvui.themeGet().font_title, .expand = .horizontal, .margin = R.all(0), .padding = R.all(0) });
    gap(@src(), 16);
    const runtime = managementRuntime(ui, manager);
    if (ui.failure) |err| components.text(@src(), frameFmt("操作失败：{s}", .{@errorName(err)}), theme.muted);
    if (!ui.interactive) components.text(@src(), "正在启动游戏或管理模组包，请稍后修改 Java。", theme.muted);
    const deletion = controller.ownedDeleteSnapshot();
    if (deletion.phase == .running) {
        components.text(@src(), "正在删除启动器下载的 Java…", theme.muted);
        if (components.action(@src(), "取消删除", ui.interactive)) ui.enqueue(.cancel) catch |err| {
            ui.failure = err;
        };
    } else if (deletion.failure) |err| {
        components.text(@src(), frameFmt("删除未完成：{s}", .{@errorName(err)}), theme.muted);
        if (deletion.files_deleted) components.text(@src(), "Java 文件已删除，条目保存失败；请再次移除条目。", theme.muted);
    } else if (deletion.phase == .complete) {
        components.text(@src(), "Java 文件已删除，条目已移除。", theme.muted);
    } else if (deletion.phase == .canceled) {
        components.text(@src(), "删除已取消；条目保留，部分文件可能已删除，可重试完成清理。", theme.muted);
    }
    const enabled = ui.interactive and !hasModal(ui) and deletion.phase != .running;
    if (ui.acquisition_open or runtime == null) {
        components.section(@src(), "获取 Java");
        components.text(@src(), "下载受支持的 Java，或添加本机已有的运行环境。", theme.muted);
        components.section(@src(), "下载 Java");
        download_view.drawInline(download_ui, controller, enabled);
        gap(@src(), 16);
        components.section(@src(), "查找本机 Java");
        drawSearch(ui, manager, enabled);
        return;
    }
    const selected = runtime.?;
    gap(@src(), 16);
    runtimeDetails(selected);
    const hidden = manager.isHidden(selected.path);
    const is_registered = registered(manager, selected.path);
    gap(@src(), 12);
    components.text(@src(), if (hidden) "已隐藏 · 不参与游戏启动" else if (is_registered) "已注册" else "尚未添加", theme.muted);
    {
        const actions = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal, .padding = R.all(0), .margin = .{ .y = 16 } });
        defer actions.deinit();
        if (!is_registered and !hidden and components.action(@src(), "添加 Java", enabled)) ui.queueAddOne(selected.path) catch |err| {
            ui.failure = err;
        };
        if ((hidden or is_registered) and components.action(@src(), if (hidden) "恢复显示" else "隐藏 Java", enabled)) ui.queueManagement(selected.path, if (hidden) .unhide else .hide) catch |err| {
            ui.failure = err;
        };
        if (is_registered and components.action(@src(), "删除 Java", enabled)) ui.queuePath(selected.path, false) catch |err| {
            ui.failure = err;
        };
    }
    components.text(@src(), "系统 Java 只会移除启动器条目。启动器下载的 Java 可在确认后删除文件。", theme.muted);
}

fn clearDeleteConfirmation(ui: *Ui) void {
    if (ui.delete_confirmation) |path| ui.allocator.free(path);
    ui.delete_confirmation = null;
}

fn drawDeleteConfirmation(ui: *Ui) void {
    const path = ui.delete_confirmation orelse return;
    const rect = dvui.windowRect();
    var open = true;
    {
        const width = @min(560, rect.w - 16);
        const height = @min(340, rect.h - 16);
        const modal = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &open, .resize = .none, .window_avoid = .none }, .{ .rect = .{ .x = rect.x + (rect.w - width) / 2, .y = rect.y + (rect.h - height) / 2, .w = width, .h = height }, .padding = R.all(20) });
        defer modal.deinit();
        clippedLabel(@src(), "删除启动器下载的 Java？", false);
        // Reserve all actions before allowing the information to fill the remainder.
        {
            const actions = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal, .gravity_y = 1, .padding = R.all(0), .margin = R.all(0) });
            defer actions.deinit();
            if (textButton(@src(), "仅移除条目", !ui.interactive, false)) {
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
            if (textButton(@src(), "删除 Java 文件", !ui.interactive, true)) {
                ui.queueManagement(path, .delete_files) catch |err| {
                    ui.failure = err;
                    return;
                };
                open = false;
            }
            if (textButton(@src(), "取消", false, false)) open = false;
        }
        const information = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .expand = .both, .padding = R.all(0), .margin = .{ .y = 12, .h = 12 }, .background = false });
        defer information.deinit();
        components.text(@src(), path, theme.muted);
        gap(@src(), 12);
        components.text(@src(), "删除文件只作用于经所有权凭据验证的 Java 安装目录。此操作无法撤销。", theme.muted);
    }
    if (!open) clearDeleteConfirmation(ui);
}

pub fn drawModal(ui: *Ui) void {
    drawDeleteConfirmation(ui);
}

fn drawSearch(ui: *Ui, manager: *java.Manager, enabled: bool) void {
    const busy = ui.search_queued or manager.isSearching();
    const input = dvui.textEntry(@src(), .{ .text = .{ .buffer = &ui.path_buffer }, .placeholder = "目录或可执行文件 · 留空搜索 PATH" }, .{ .expand = .horizontal, .min_size_content = .{ .h = 20 }, .padding = R.all(10), .margin = .{ .h = 8 }, .corners = .all(4), .label = .{ .text = "Java 搜索路径" } });
    input.deinit();
    {
        const actions = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal, .padding = R.all(0), .margin = R.all(0) });
        defer actions.deinit();
        if (components.action(@src(), "搜索本机 Java", enabled and !busy)) {
            ui.queuePath(std.mem.sliceTo(&ui.path_buffer, 0), true) catch |err| {
                ui.failure = err;
            };
            ui.search_queued = ui.commands.items.len > 0 and ui.commands.items[ui.commands.items.len - 1] == .search;
            if (ui.search_queued) {
                ui.resetSearch();
                ui.search_started = true;
                ui.failure = null;
            }
        }
        if (busy and components.action(@src(), "取消搜索", enabled)) ui.enqueue(.cancel_search) catch |err| {
            ui.failure = err;
        };
    }
    components.text(@src(), "搜索结果不会自动添加；选择运行环境后添加到管理列表。", theme.muted);
    if (!ui.search_started and !busy) return;
    if (busy or ui.search_queued) {
        components.text(@src(), "正在搜索…", theme.muted);
        return;
    }
    if (manager.searchFailure()) |err| {
        components.text(@src(), frameFmt("搜索失败：{s}", .{@errorName(err)}), theme.muted);
        return;
    }
    const results = manager.searchResults();
    ui.syncSelection(results) catch |err| {
        ui.failure = err;
        return;
    };
    if (results.len == 0) components.emptyState(@src(), "未找到 Java，可修改搜索路径后重试。");
    if (results.len != 0) {
        const list = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .expand = .horizontal, .min_size_content = .{ .h = @min(280, @as(f32, @floatFromInt(results.len)) * rowHeight()) }, .max_size_content = .height(280), .padding = R.all(0), .margin = .{ .y = 12 }, .border = R.all(0), .background = false });
        defer list.deinit();
        for (results, 0..) |result, index| {
            const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = @as(usize, @truncate(std.hash.Wyhash.hash(0, result.path))), .expand = .horizontal, .min_size_content = .{ .h = rowHeight() - 20 }, .padding = .{ .y = 10, .h = 10 }, .margin = R.all(0) });
            {
                defer row.deinit();
                if (registered(manager, result.path)) {
                    ui.search_selection[index] = false;
                    dvui.labelNoFmt(@src(), "已注册", .{}, .{ .gravity_y = 0.5, .padding = R.all(0), .margin = .{ .w = 12 }, .color_text = .{ .color = theme.muted }, .background = false });
                } else if (enabled) {
                    _ = dvui.checkbox(@src(), &ui.search_selection[index], null, .{ .min_size_content = .{ .w = 20, .h = 20 }, .max_size_content = .{ .w = 20, .h = 20 }, .gravity_y = 0.5, .margin = .{ .w = 12 }, .padding = R.all(6), .label = .{ .text = frameFmt("选择 {s} Java {d} {s}", .{ result.vendor, result.major, result.path }) } });
                }
                runtimeDetails(result);
            }
            _ = dvui.separator(@src(), .{ .id_extra = @as(usize, @truncate(std.hash.Wyhash.hash(0, result.path))), .expand = .horizontal, .margin = R.all(0) });
        }
    }
    if (ui.add_failure) |err| components.text(@src(), frameFmt("添加失败：{s}", .{@errorName(err)}), theme.muted);
    if (components.action(@src(), "添加所选 Java", enabled and ui.selectedCount() != 0)) ui.queueSelected(results) catch |err| {
        ui.add_failure = err;
    };
}

pub fn versionChoice(ui: *Ui, manager: *java.Manager, game: []const u8, required: u32) void {
    ui.syncChoiceContext(game, required);
    if (components.action(@src(), "获取 Java", ui.interactive and !hasModal(ui))) {
        ui.requested_major = required;
        ui.download_requested = true;
    }
    const heading = frameFmt("Java {d}", .{required});
    clippedLabel(@src(), heading, true);
    gap(@src(), 8);
    if (ui.choice_failure) |err| {
        clippedLabel(@src(), frameFmt("选择失败：{s}", .{@errorName(err)}), true);
        gap(@src(), 8);
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
    }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = 24 },
        .max_size_content = .width(0),
        .padding = R.all(8),
        .margin = R.all(0),
        .corners = .all(8),
        .label = .{ .text = heading },
    });
    defer dropdown.deinit();
    {
        const control = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
            .padding = R.all(0),
            .margin = R.all(0),
        });
        clippedLabel(@src(), current_label, false);
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8 } });
        dvui.icon(@src(), "展开 Java 选项", dvui.entypo.chevron_small_down, .{}, .{
            .min_size_content = .{ .w = 16, .h = 16 },
            .max_size_content = .{ .w = 16, .h = 16 },
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
                    .min_size_content = .{ .h = rowHeight() - 20 },
                    .padding = .{ .y = 6, .h = 6 },
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
            .search => |path| {
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
        .{ .path = &first_path, .major = 21, .vendor = "Vendor A" },
        .{ .path = "/b", .major = 17, .vendor = "Vendor B" },
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
        .{ .path = "/a", .major = 21, .vendor = "Vendor A" },
        .{ .path = "/b", .major = 21, .vendor = "Vendor B" },
    };
    try ui.syncSelection(&results);
    @memset(ui.search_selection, true);
    try ui.queueSelected(&results);
}

test "deferred command ownership releases all partial allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseQueueAllocations, .{});
}

test "a new search clears selection even when results are identical" {
    var ui = Ui.init(std.testing.allocator);
    defer ui.deinit();
    const results = [_]java.Runtime{.{ .path = "/a", .major = 21, .vendor = "Vendor A" }};
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
        .data = "{\"version\":1,\"runtimes\":[{\"path\":\"/java-test\",\"major\":21,\"vendor\":\"Test Vendor\"}],\"choices\":[]}",
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
        .{ .path = "/a", .major = 21, .vendor = "Vendor A" },
        .{ .path = "/b", .major = 21, .vendor = "Vendor B" },
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
    try manager.addDownloaded(.{ .path = path, .major = 21, .vendor = "OpenJDK" });
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
    try manager.addDownloaded(.{ .path = path, .major = 21, .vendor = "OpenJDK" });
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

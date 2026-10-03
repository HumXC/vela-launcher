const std = @import("std");
const dvui = @import("dvui");
const java = @import("java_manager.zig");
const theme = @import("theme.zig");
const R = dvui.Rect;

const Choice = struct { game: []const u8, path: []const u8, required: u32 };
const Command = union(enum) {
    search: []const u8,
    cancel,
    remove: []const u8,
    add: []const []const u8,
    choose: Choice,

    fn deinit(self: Command, a: std.mem.Allocator) void {
        switch (self) {
            .search, .remove => |path| a.free(path),
            .cancel => {},
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
    modal_open: bool = false,
    download_requested: bool = false,
    search_queued: bool = false,
    commands: std.ArrayList(Command) = .empty,

    pub fn init(a: std.mem.Allocator) Ui {
        return .{ .allocator = a };
    }

    pub fn deinit(self: *Ui) void {
        for (self.commands.items) |command| command.deinit(self.allocator);
        self.commands.deinit(self.allocator);
        self.allocator.free(self.search_selection);
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
    return ui.modal_open;
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
    if (visible) dvui.tooltip(src, .{ .active_rect = rect }, "{s}", .{name}, .{ .id_extra = 1 });
    return clicked;
}

fn textButton(src: std.builtin.SourceLocation, text: []const u8, disabled: bool, highlighted: bool) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{ .grayed = disabled }, .{
        .style = if (highlighted) .highlight else .control,
        .min_size_content = .{ .h = 20 },
        .padding = R.all(10),
        .margin = R.all(0),
        .border = R.all(1),
        .corners = .all(8),
        .gravity_x = 1,
        .tab_index = if (disabled) 0 else null,
        .label = .{ .text = text },
    });
    if (!disabled) button.processEvents();
    button.drawBackground();
    dvui.labelNoFmt(@src(), text, .{ .align_x = 0.5, .align_y = 0.5 }, button.style().override(.{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .padding = R.all(0),
        .margin = R.all(0),
    }));
    if (!disabled) button.drawFocus();
    const clicked = !disabled and button.clicked();
    button.deinit();
    return clicked;
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

pub fn drawPage(ui: *Ui, manager: *java.Manager) void {
    dvui.labelNoFmt(@src(), "Java 管理", .{}, .{
        .font = dvui.themeGet().font_title,
        .expand = .horizontal,
        .margin = R.all(0),
        .padding = R.all(0),
    });
    gap(@src(), 20);
    {
        const header = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .h = 40 },
            .padding = R.all(0),
            .margin = R.all(0),
        });
        defer header.deinit();
        {
            const entry = dvui.textEntry(@src(), .{
                .text = .{ .buffer = &ui.path_buffer },
                .placeholder = "搜索目录",
            }, .{
                .expand = .horizontal,
                .min_size_content = .{ .h = 20 },
                .max_size_content = .height(20),
                .padding = R.all(10),
                .margin = R.all(0),
                .corners = .all(8),
                .label = .{ .text = "搜索目录" },
            });
            entry.deinit();
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8 } });
        if (iconButton(@src(), "搜索 Java", dvui.entypo.magnifying_glass, true)) {
            const path = std.mem.sliceTo(&ui.path_buffer, 0);
            ui.queuePath(path, true) catch |err| {
                ui.failure = err;
            };
            ui.resetSearch();
            ui.modal_open = true;
            ui.search_queued = ui.commands.items.len > 0 and ui.commands.items[ui.commands.items.len - 1] == .search;
            if (ui.search_queued) ui.failure = null;
        }
        if (iconButton(@src(), "下载 Java", dvui.entypo.download, true)) ui.download_requested = true;
    }
    gap(@src(), 16);
    if (ui.failure != null and !ui.modal_open) {
        clippedLabel(@src(), frameFmt("操作失败：{s}", .{@errorName(ui.failure.?)}), true);
        gap(@src(), 12);
    }
    const list = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{
        .expand = .both,
        .padding = R.all(0),
        .margin = R.all(0),
    });
    defer list.deinit();
    const entries = manager.entries();
    if (entries.len == 0) clippedLabel(@src(), "暂无 Java", true);
    for (entries, 0..) |runtime, i| {
        {
            const row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = i,
                .expand = .horizontal,
                .min_size_content = .{ .h = rowHeight() - 20 },
                .padding = .{ .y = 10, .h = 10 },
                .margin = R.all(0),
            });
            defer row.deinit();
            const rect = row.data().borderRectScale().r;
            const hovered = !ui.modal_open and rect.contains(dvui.currentWindow().mouse_pt) and dvui.clipGet().contains(dvui.currentWindow().mouse_pt);
            runtimeDetails(runtime);
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12 } });
            if (iconButton(@src(), "移除 Java 条目", dvui.entypo.trash, hovered)) {
                ui.queuePath(runtime.path, false) catch |err| {
                    ui.failure = err;
                };
            }
        }
        _ = dvui.separator(@src(), .{ .id_extra = i, .expand = .horizontal, .margin = R.all(0) });
    }
}

pub fn drawSearchModal(ui: *Ui, manager: *java.Manager) void {
    if (!ui.modal_open) return;
    const window = dvui.windowRect();
    const width = @max(160, @min(720, window.w - 56));
    const height = @max(140, @min(520, window.h - 56));
    {
        const modal = dvui.floatingWindow(@src(), .{
            .modal = true,
            .open_flag = &ui.modal_open,
            .resize = .none,
            .window_avoid = .none,
        }, .{
            .rect = .{
                .x = window.x + (window.w - width - 26) / 2,
                .y = window.y + (window.h - height - 26) / 2,
                .w = width + 26,
                .h = height + 26,
            },
            .min_size_content = .{ .w = width, .h = height },
            .max_size_content = .{ .w = width, .h = height },
            .padding = R.all(12),
            .margin = R.all(0),
            .corners = .all(8),
            .label = .{ .text = "搜索 Java" },
        });
        defer modal.deinit();
        modal.dragAreaSet(dvui.windowHeader("搜索 Java", "", &ui.modal_open));
        const busy = ui.search_queued or manager.isSearching();
        const failure: ?anyerror = if (ui.failure) |err| err else if (ui.search_queued) null else manager.searchFailure();
        gap(@src(), 8);
        {
            const list = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{
                .expand = .both,
                .padding = R.all(0),
                .margin = R.all(0),
            });
            defer list.deinit();
            if (busy) {
                clippedLabel(@src(), "正在搜索…", true);
            } else if (failure) |err| {
                clippedLabel(@src(), frameFmt("搜索失败：{s}", .{@errorName(err)}), true);
            } else {
                const results = manager.searchResults();
                ui.syncSelection(results) catch |err| {
                    ui.clearSelection();
                    ui.failure = err;
                };
                if (results.len == 0) clippedLabel(@src(), "未找到 Java", true);
                if (ui.search_selection.len == results.len) {
                    for (results, 0..) |runtime, i| {
                        {
                            const row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                                .id_extra = i,
                                .expand = .horizontal,
                                .min_size_content = .{ .h = rowHeight() - 20 },
                                .padding = .{ .y = 10, .h = 10 },
                                .margin = R.all(0),
                            });
                            defer row.deinit();
                            _ = dvui.checkbox(@src(), &ui.search_selection[i], null, .{
                                .min_size_content = .{ .w = 20, .h = 20 },
                                .max_size_content = .{ .w = 20, .h = 20 },
                                .gravity_y = 0.5,
                                .margin = .{ .w = 12 },
                                .padding = R.all(6),
                                .label = .{ .text = frameFmt("选择 {s} Java {d} {s}", .{ runtime.vendor, runtime.major, runtime.path }) },
                            });
                            runtimeDetails(runtime);
                        }
                        _ = dvui.separator(@src(), .{ .id_extra = i, .expand = .horizontal, .margin = R.all(0) });
                    }
                }
            }
        }
        gap(@src(), 12);
        if (ui.add_failure) |err| {
            clippedLabel(@src(), frameFmt("添加失败：{s}", .{@errorName(err)}), true);
            gap(@src(), 8);
        }
        {
            const footer = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .min_size_content = .{ .h = 40 },
                .padding = R.all(0),
                .margin = R.all(0),
            });
            defer footer.deinit();
            _ = dvui.spacer(@src(), .{ .expand = .horizontal });
            if (textButton(@src(), "取消", false, false)) ui.modal_open = false;
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8 } });
            if (textButton(@src(), "添加所选", busy or failure != null or ui.selectedCount() == 0, true)) {
                ui.queueSelected(manager.searchResults()) catch |err| {
                    ui.add_failure = err;
                };
            }
        }
    }
    if (!ui.modal_open) {
        ui.enqueue(.cancel) catch |err| {
            ui.failure = err;
        };
        ui.clearSelection();
    }
}

pub fn versionChoice(ui: *Ui, manager: *java.Manager, game: []const u8, required: u32) void {
    ui.syncChoiceContext(game, required);
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
        switch (command) {
            .search => |path| {
                ui.failure = null;
                manager.search(path) catch |err| {
                    ui.failure = err;
                };
                ui.search_queued = false;
            },
            .cancel => manager.cancelSearch(),
            .remove => |path| {
                ui.failure = null;
                manager.remove(path) catch |err| {
                    ui.failure = err;
                };
            },
            .add => |paths| {
                ui.add_failure = null;
                manager.add(paths) catch |err| {
                    ui.add_failure = err;
                    continue;
                };
                ui.modal_open = false;
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
    ui.modal_open = true;
    try ui.syncSelection(&results);
    @memset(ui.search_selection, true);
    try ui.queueSelected(&results);
    finish(&ui, &manager);
    try std.testing.expect(ui.add_failure != null);
    try std.testing.expect(ui.failure == null);
    try std.testing.expect(ui.modal_open);
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

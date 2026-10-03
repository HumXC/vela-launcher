//! Call finish only after every root and floating widget has closed.
const std = @import("std");
const dvui = @import("dvui");
const config = @import("../core/config.zig");
const theme = @import("theme.zig");
const manager_module = @import("instances_manager.zig");
const library = @import("game_library.zig");
const Allocator = std.mem.Allocator;
const R = dvui.Rect;

pub const Mode = enum { none, create, import_folder, options, rename, delete_confirm };
pub const Action = enum { create, import_folder, edit, ask_rename, ask_delete, select, submit, confirm, close, cancel, retry_publication, choose_base, choose_loader_kind, choose_loader, load_loaders };
const Pending = struct { action: Action, text: ?[]u8 = null, kind: config.Loader = .vanilla };

pub const Draft = struct {
    id: ?[]u8 = null,
    name: [201]u8 = @splat(0),
    original_name: [201]u8 = @splat(0),
    java_path: [4097]u8 = @splat(0),
    memory: [11]u8 = @splat(0),
    debug_launch: bool = false,
    base: ?[]u8 = null,
    loader: config.Loader = .vanilla,
    loader_version: ?[]u8 = null,
    origin: ?config.Origin = null,

    pub fn deinit(self: *Draft, a: Allocator) void {
        if (self.id) |s| a.free(s);
        if (self.base) |s| a.free(s);
        if (self.loader_version) |s| a.free(s);
        if (self.origin) |o| {
            a.free(o.project_id);
            a.free(o.version_id);
        }
        self.* = .{};
    }

    pub fn fromInstance(a: Allocator, instance: config.Instance) !Draft {
        var draft: Draft = .{};
        errdefer draft.deinit(a);
        draft.id = try a.dupe(u8, instance.id);
        try setText(&draft.name, instance.name);
        try setText(&draft.original_name, instance.name);
        draft.base = try a.dupe(u8, instance.minecraft_version);
        draft.loader = instance.loader;
        if (instance.loader_version) |s| draft.loader_version = try a.dupe(u8, s);
        if (instance.java_path) |s| try setText(&draft.java_path, s);
        if (instance.max_memory_mb) |m| _ = try std.fmt.bufPrint(draft.memory[0 .. draft.memory.len - 1], "{d}", .{m});
        draft.debug_launch = instance.debug_launch;
        if (instance.origin) |o| {
            const project = try a.dupe(u8, o.project_id);
            errdefer a.free(project);
            const version = try a.dupe(u8, o.version_id);
            draft.origin = .{ .kind = o.kind, .project_id = project, .version_id = version };
        }
        return draft;
    }

    pub fn ensureId(self: *Draft, a: Allocator, io: std.Io) !void {
        if (self.id != null) return;
        var random: [16]u8 = undefined;
        try io.randomSecure(&random);
        const id = try std.fmt.allocPrint(a, "instance-{s}", .{std.fmt.bytesToHex(random, .lower)});
        self.id = id;
    }

    pub fn value(self: *const Draft, mode: Mode, doc: *const config.Document) !config.Instance {
        const name = text(&self.name);
        try validateName(doc, name, if (mode == .options or mode == .rename) self.id else null);
        const java = text(&self.java_path);
        if (!validText(java, true)) return error.InvalidJavaPath;
        const memory = try parseMemory(text(&self.memory));
        const base = self.base orelse if (mode == .import_folder) "" else return error.MinecraftVersionRequired;
        if (mode != .import_folder and !validText(base, false)) return error.InvalidMinecraftVersion;
        if (mode != .import_folder and self.loader != .vanilla and self.loader_version == null) return error.LoaderVersionRequired;
        if (self.loader_version) |version| if (!validText(version, false)) return error.InvalidLoaderVersion;
        return .{ .id = self.id orelse return error.InvalidId, .name = name, .minecraft_version = base, .loader = self.loader, .loader_version = self.loader_version, .java_path = if (java.len == 0) null else java, .max_memory_mb = memory, .debug_launch = self.debug_launch, .origin = self.origin };
    }
};

pub const Ui = struct {
    allocator: Allocator,
    draft: Draft = .{},
    mode: Mode = .none,
    rename_confirmed: bool = false,
    pending: ?Pending = null,
    failure: ?anyerror = null,
    publication_failed: bool = false,
    submitted: bool = false,
    pack_requested: bool = false,

    pub fn init(a: Allocator) Ui {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Ui) void {
        self.draft.deinit(self.allocator);
        if (self.pending) |p| if (p.text) |s| self.allocator.free(s);
        self.pending = null;
    }
    pub fn queue(self: *Ui, action: Action, borrowed: ?[]const u8) void {
        const owned = if (borrowed) |s| self.allocator.dupe(u8, s) catch |err| {
            self.failure = err;
            return;
        } else null;
        if (self.pending) |p| if (p.text) |s| self.allocator.free(s);
        self.pending = .{ .action = action, .text = owned };
    }
    fn reset(self: *Ui) void {
        self.draft.deinit(self.allocator);
        self.mode = .none;
        self.rename_confirmed = false;
        self.submitted = false;
    }
};

fn text(buffer: []const u8) []const u8 {
    return buffer[0 .. std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len];
}
fn setText(buffer: []u8, s: []const u8) !void {
    if (s.len >= buffer.len) return error.TextTooLong;
    @memset(buffer, 0);
    @memcpy(buffer[0..s.len], s);
}
fn validText(s: []const u8, allow_empty: bool) bool {
    if ((!allow_empty and s.len == 0) or !std.unicode.utf8ValidateSlice(s)) return false;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return false;
    return true;
}
pub fn parseMemory(s: []const u8) !?u32 {
    if (s.len == 0) return null;
    for (s) |ch| if (ch < '0' or ch > '9') return error.InvalidMemory;
    const memory = std.fmt.parseInt(u32, s, 10) catch return error.InvalidMemory;
    if (memory < 256 or memory > 1024 * 1024) return error.InvalidMemory;
    return memory;
}
pub fn validateName(doc: *const config.Document, name: []const u8, excluding: ?[]const u8) !void {
    if (!config.validId(name)) return error.InvalidInstanceName;
    for (doc.instances) |instance| {
        if (excluding) |id| if (std.mem.eql(u8, id, instance.id)) continue;
        if (std.ascii.eqlIgnoreCase(instance.name, name)) return error.DuplicateInstanceName;
    }
}
fn find(doc: *const config.Document, id: []const u8) !config.Instance {
    for (doc.instances) |instance| if (std.mem.eql(u8, instance.id, id)) return instance;
    return error.InstanceNotFound;
}
fn replaceOwned(a: Allocator, target: *?[]u8, borrowed: []const u8) !void {
    const owned = try a.dupe(u8, borrowed);
    if (target.*) |old| a.free(old);
    target.* = owned;
}

fn perform(ui: *Ui, store: *config.Store, manager: anytype, p: Pending) !void {
    const doc = store.snapshot();
    switch (p.action) {
        .create, .import_folder => {
            if (manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
            var draft: Draft = .{};
            errdefer draft.deinit(ui.allocator);
            try draft.ensureId(ui.allocator, store.io);
            ui.reset();
            ui.draft = draft;
            ui.mode = if (p.action == .create) .create else .import_folder;
        },
        .edit, .ask_rename, .ask_delete => {
            if (manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
            const draft = try Draft.fromInstance(ui.allocator, try find(doc, p.text orelse return error.InvalidId));
            ui.reset();
            ui.draft = draft;
            ui.mode = switch (p.action) {
                .edit => .options,
                .ask_rename => .rename,
                else => .delete_confirm,
            };
        },
        .select => try manager.select(store, p.text orelse return error.InvalidId),
        .close => {
            if (manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
            ui.reset();
        },
        .cancel => manager.cancel(),
        .retry_publication => {
            if (manager.snapshot().phase != .awaiting_publication) return error.NoPendingPublication;
            ui.publication_failed = true;
            try manager.publish(store);
            ui.publication_failed = false;
            if (ui.submitted) ui.reset();
        },
        .choose_base => {
            try replaceOwned(ui.allocator, &ui.draft.base, p.text orelse return error.MinecraftVersionRequired);
            if (ui.draft.loader_version) |old| ui.allocator.free(old);
            ui.draft.loader_version = null;
        },
        .choose_loader_kind => {
            ui.draft.loader = p.kind;
            if (ui.draft.loader_version) |old| ui.allocator.free(old);
            ui.draft.loader_version = null;
        },
        .choose_loader => try replaceOwned(ui.allocator, &ui.draft.loader_version, p.text orelse return error.LoaderVersionRequired),
        .load_loaders => try manager.loadLoaders(ui.draft.base orelse return error.MinecraftVersionRequired, ui.draft.loader),
        .submit => {
            if (manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
            if (ui.mode == .rename) {
                try validateName(doc, text(&ui.draft.name), ui.draft.id);
                ui.rename_confirmed = true;
                return;
            }
            try ui.draft.ensureId(ui.allocator, store.io);
            const instance = try ui.draft.value(ui.mode, doc);
            switch (ui.mode) {
                .create => {
                    manager.setDownloadConnections(doc.settings.download_connections);
                    try manager.startCreate(instance);
                },
                .import_folder => try manager.startImport(instance),
                .options => {
                    try manager.saveOptions(store, instance);
                    ui.reset();
                    return;
                },
                else => return error.InvalidAction,
            }
            ui.submitted = true;
            ui.publication_failed = false;
        },
        .confirm => {
            if (manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
            const original = try find(doc, ui.draft.id orelse return error.InvalidId);
            if (!std.mem.eql(u8, original.name, text(&ui.draft.original_name))) return error.InstanceChanged;
            switch (ui.mode) {
                .rename => {
                    if (!ui.rename_confirmed) return error.ConfirmationRequired;
                    try validateName(doc, text(&ui.draft.name), ui.draft.id);
                    try manager.startRename(original, text(&ui.draft.name));
                },
                .delete_confirm => try manager.startDelete(original),
                else => return error.InvalidAction,
            }
            ui.submitted = true;
            ui.publication_failed = false;
        },
    }
}

/// Generic seam for state-only fixture tests; no widget construction is needed.
pub fn finishWithManager(ui: *Ui, store: *config.Store, manager: anytype) void {
    if (ui.pending) |p| {
        ui.pending = null;
        defer if (p.text) |s| ui.allocator.free(s);
        perform(ui, store, manager, p) catch |err| {
            ui.failure = err;
            return;
        };
        ui.failure = null;
    }
    if (manager.snapshot().phase == .awaiting_publication and !ui.publication_failed) {
        manager.publish(store) catch |err| {
            ui.publication_failed = true;
            ui.failure = err;
            return;
        };
        ui.failure = null;
        if (ui.submitted) ui.reset();
    }
}
pub fn finish(ui: *Ui, store: *config.Store, manager: *manager_module.Manager) void {
    finishWithManager(ui, store, manager);
}

fn fmt(comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), format, args) catch "";
}
fn wrapped(src: std.builtin.SourceLocation, value: []const u8, color: dvui.Color) void {
    const layout = dvui.textLayout(src, .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = .{ .h = 6 }, .color_text = .{ .color = color } });
    layout.addText(value, .{});
    layout.deinit();
}
fn iconButton(src: std.builtin.SourceLocation, name: []const u8, asset: []const u8) bool {
    return iconButtonWithEnabled(src, name, asset, true);
}

fn iconButtonWithEnabled(src: std.builtin.SourceLocation, name: []const u8, asset: []const u8, enabled: bool) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{ .grayed = !enabled, .draw_focus = enabled }, .{ .label = .{ .text = name }, .min_size_content = .{ .w = 18, .h = 18 }, .max_size_content = .{ .w = 18, .h = 18 }, .padding = R.all(8), .margin = .{ .x = 4 }, .corners = .all(4), .tab_index = if (enabled) null else 0 });
    if (enabled) button.processEvents();
    button.drawBackground();
    dvui.icon(@src(), name, asset, .{}, button.style().override(.{ .padding = R.all(0), .margin = R.all(0), .min_size_content = .{ .w = 18, .h = 18 }, .max_size_content = .{ .w = 18, .h = 18 }, .role = .none }));
    if (enabled) button.drawFocus();
    const clicked = enabled and button.clicked();
    const hovered = button.hovered();
    const rect = button.data().rectScale().r;
    button.deinit();
    if (hovered) dvui.tooltip(src, .{ .active_rect = rect }, "{s}", .{name}, .{ .id_extra = 1 });
    return clicked;
}
fn entry(src: std.builtin.SourceLocation, name: []const u8, buffer: []u8, numeric: bool) void {
    dvui.labelNoFmt(src, name, .{}, .{ .padding = R.all(0), .margin = .{ .y = 8, .h = 4 } });
    const height = (dvui.Options{}).fontGet().sizeM(0, 1).h;
    const input = dvui.textEntry(src, .{ .text = .{ .buffer = buffer } }, .{ .id_extra = 1, .label = .{ .text = name }, .expand = .horizontal, .min_size_content = .{ .h = height }, .max_size_content = .height(height), .padding = R.all(8), .corners = .all(4), .margin = .{ .h = 6 } });
    if (numeric) input.filterIn("0123456789");
    input.deinit();
}
fn dropdown(src: std.builtin.SourceLocation, labels: []const []const u8, selected: ?[]const u8, placeholder: []const u8) ?usize {
    var choice: ?usize = null;
    if (selected) |s| for (labels, 0..) |label, index| {
        if (std.mem.eql(u8, s, label)) {
            choice = index;
            break;
        }
    };
    if (labels.len == 0) {
        wrapped(src, placeholder, theme.muted);
        return null;
    }
    if (dvui.dropdown(src, labels, .{ .choice_nullable = &choice }, .{ .placeholder = placeholder, .null_selectable = false }, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(8), .corners = .all(4), .margin = .{ .h = 6 } })) return choice;
    return null;
}

fn drawEditor(ui: *Ui, doc: *const config.Document, manager: *manager_module.Manager, catalogue: library.Snapshot, enabled: bool) void {
    const section = dvui.box(@src(), .{}, .{ .expand = .horizontal, .padding = .{ .y = 12 }, .border = .{ .y = 1 }, .margin = .{ .h = 12 } });
    defer section.deinit();
    const locked = !enabled or manager.isBusy() or manager.snapshot().phase == .awaiting_publication;
    if (ui.mode == .delete_confirm) {
        wrapped(@src(), fmt("将实例「{s}」的独立目录移至恢复区？", .{text(&ui.draft.original_name)}), theme.accent);
        var count: usize = 0;
        for (doc.servers) |server| if (ui.draft.id) |id| {
            if (std.mem.eql(u8, server.instance_id, id)) count += 1;
        };
        wrapped(@src(), fmt("同时移除绑定的 {d} 条服务器配置：", .{count}), theme.muted);
        for (doc.servers, 0..) |server, index| if (ui.draft.id) |id| {
            if (std.mem.eql(u8, server.instance_id, id)) {
                const row = dvui.box(@src(), .{}, .{ .id_extra = index, .expand = .horizontal, .padding = R.all(0) });
                wrapped(@src(), server.name, theme.muted);
                row.deinit();
            }
        };
        wrapped(@src(), "不删除其他实例、服务器文件或世界目录。", theme.muted);
        const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = R.all(0) });
        if (!locked and iconButton(@src(), "确认移至恢复区", dvui.entypo.trash)) ui.queue(.confirm, null);
        if (!locked and iconButton(@src(), "取消删除", dvui.entypo.cross)) ui.queue(.close, null);
        actions.deinit();
        return;
    }
    if (ui.mode == .rename and ui.rename_confirmed) {
        wrapped(@src(), fmt("确认将「{s}」重命名为「{s}」？", .{ text(&ui.draft.original_name), text(&ui.draft.name) }), theme.accent);
        const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = R.all(0) });
        if (!locked and iconButton(@src(), "确认重命名", dvui.entypo.check)) ui.queue(.confirm, null);
        if (!locked and iconButton(@src(), "取消重命名", dvui.entypo.cross)) ui.queue(.close, null);
        actions.deinit();
        return;
    }
    if (locked) {
        wrapped(@src(), fmt("{s}", .{text(&ui.draft.name)}), theme.muted);
        return;
    }
    dvui.labelNoFmt(@src(), switch (ui.mode) {
        .create => "创建实例",
        .import_folder => "导入已有目录",
        .options => "启动选项",
        .rename => "重命名实例",
        else => "实例",
    }, .{}, .{ .padding = R.all(0) });
    if (ui.mode != .options) entry(@src(), if (ui.mode == .import_folder) "目录名称" else "实例名称", &ui.draft.name, false);
    if (ui.mode == .import_folder) wrapped(@src(), fmt(".minecraft/versions/{s}", .{text(&ui.draft.name)}), theme.muted);
    if (ui.mode == .create) {
        dvui.labelNoFmt(@src(), "Minecraft 版本", .{}, .{ .padding = R.all(0), .margin = .{ .y = 8, .h = 4 } });
        const labels = dvui.currentWindow().arena().alloc([]const u8, catalogue.available.len) catch {
            ui.failure = error.OutOfMemory;
            return;
        };
        for (catalogue.available, 0..) |version, index| labels[index] = version.id;
        if (dropdown(@src(), labels, ui.draft.base, "暂无 Minecraft 目录")) |index| ui.queue(.choose_base, labels[index]);
        if (catalogue.failure) |err| wrapped(@src(), fmt("Minecraft 目录：{s}", .{@errorName(err)}), theme.muted);
        dvui.labelNoFmt(@src(), "加载器", .{}, .{ .padding = R.all(0), .margin = .{ .y = 8, .h = 4 } });
        const kinds = [_]config.Loader{ .vanilla, .fabric, .forge, .neoforge, .quilt };
        const names = [_][]const u8{ "原版", "Fabric", "Forge", "NeoForge", "Quilt" };
        var choice: usize = 0;
        for (kinds, 0..) |kind, index| if (kind == ui.draft.loader) {
            choice = index;
        };
        if (dropdown(@src(), &names, names[choice], "选择加载器")) |index| {
            ui.queue(.choose_loader_kind, null);
            if (ui.pending) |*p| p.kind = kinds[index];
        }
        if (ui.draft.loader != .vanilla) {
            const loaders = manager.loaderSnapshot();
            const matches = if (loaders.base) |base| ui.draft.base != null and std.mem.eql(u8, base, ui.draft.base.?) and loaders.kind == ui.draft.loader else false;
            if (matches and loaders.entries.len != 0) {
                const versions = dvui.currentWindow().arena().alloc([]const u8, loaders.entries.len) catch {
                    ui.failure = error.OutOfMemory;
                    return;
                };
                for (loaders.entries, 0..) |loader, index| versions[index] = loader.id;
                if (dropdown(@src(), versions, ui.draft.loader_version, "选择加载器版本")) |index| ui.queue(.choose_loader, versions[index]);
            }
            const load = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = R.all(0) });
            wrapped(@src(), if (matches and loaders.phase == .working) "正在读取加载器版本" else "加载器版本", theme.muted);
            if (iconButton(@src(), "读取加载器版本", dvui.entypo.cw)) ui.queue(.load_loaders, null);
            load.deinit();
            if (matches) if (loaders.failure) |err| wrapped(@src(), fmt("加载器目录：{s}", .{@errorName(err)}), theme.muted);
        }
    }
    if (ui.mode == .options or ui.mode == .create or ui.mode == .import_folder) {
        entry(@src(), "Java 路径（留空使用默认）", &ui.draft.java_path, false);
        entry(@src(), "内存 MiB（留空使用默认）", &ui.draft.memory, true);
        _ = dvui.checkbox(@src(), &ui.draft.debug_launch, "调试启动", .{ .margin = .{ .y = 8, .h = 8 } });
    }
    const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = R.all(0) });
    if (iconButton(@src(), switch (ui.mode) {
        .create => "创建实例",
        .import_folder => "验证并导入",
        .rename => "继续重命名",
        else => "保存启动选项",
    }, if (ui.mode == .options) dvui.entypo.save else dvui.entypo.check)) ui.queue(.submit, null);
    if (iconButton(@src(), "取消编辑", dvui.entypo.cross)) ui.queue(.close, null);
    actions.deinit();
}

fn selectedInstance(doc: *const config.Document) ?config.Instance {
    return find(doc, doc.selected_instance orelse return null) catch null;
}

fn sidebarEnabled(ui: *const Ui, busy: bool, enabled: bool) bool {
    return enabled and !busy and ui.mode == .none and ui.pending == null and !ui.pack_requested;
}

fn queueSidebarAction(ui: *Ui, action: Action, id: ?[]const u8, busy: bool, enabled: bool) void {
    if (sidebarEnabled(ui, busy, enabled)) ui.queue(action, id);
}

fn queueSidebarPack(ui: *Ui, busy: bool, enabled: bool) void {
    if (sidebarEnabled(ui, busy, enabled)) ui.pack_requested = true;
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

pub fn drawSidebar(ui: *Ui, store: *config.Store, manager: *manager_module.Manager, enabled: bool) void {
    const doc = store.snapshot();
    const busy = manager.isBusy() or manager.snapshot().phase == .awaiting_publication;
    const allowed = sidebarEnabled(ui, busy, enabled);
    {
        var create: dvui.ButtonWidget = undefined;
        create.init(@src(), .{ .grayed = !allowed, .draw_focus = allowed }, .{ .label = .{ .text = "新建实例" }, .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(6), .margin = .{ .h = 6 }, .corners = .all(4), .tab_index = if (allowed) null else 0 });
        if (allowed) create.processEvents();
        create.drawBackground();
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = R.all(0), .margin = R.all(0) });
        dvui.icon(@src(), "新建实例", dvui.entypo.plus, .{}, .{ .min_size_content = .{ .w = 18, .h = 18 }, .max_size_content = .{ .w = 18, .h = 18 }, .padding = R.all(0), .margin = .{ .w = 6 } });
        dvui.labelNoFmt(@src(), "新建实例", .{}, .{ .padding = R.all(0), .margin = R.all(0), .gravity_y = 0.5 });
        row.deinit();
        if (allowed) create.drawFocus();
        const clicked = allowed and create.clicked();
        create.deinit();
        if (clicked) queueSidebarAction(ui, .create, null, busy, enabled);
    }
    {
        const imports = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = R.all(0), .margin = .{ .h = 8 } });
        if (iconButtonWithEnabled(@src(), "导入已有目录", dvui.entypo.folder, allowed)) queueSidebarAction(ui, .import_folder, null, busy, enabled);
        if (iconButtonWithEnabled(@src(), "导入整合包", dvui.entypo.archive, allowed)) queueSidebarPack(ui, busy, enabled);
        imports.deinit();
    }
    const scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .expand = .both, .padding = R.all(0), .margin = R.all(0), .background = false });
    defer scroll.deinit();
    if (doc.instances.len == 0) wrapped(@src(), "暂无实例", theme.muted);
    for (doc.instances) |instance| {
        const selected = if (doc.selected_instance) |id| std.mem.eql(u8, id, instance.id) else false;
        if (sidebarRow(@src(), instance, selected, allowed) and !selected) queueSidebarAction(ui, .select, instance.id, busy, enabled);
    }
}

pub fn draw(ui: *Ui, store: *config.Store, manager: *manager_module.Manager, catalogue: library.Snapshot) void {
    drawWithEnabled(ui, store, manager, catalogue, true);
}

fn failureMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InstanceAlreadyExists => "同名实例或目录已存在；如果列表中没有它，请使用“导入已有目录”验证登记。",
        else => @errorName(err),
    };
}

pub fn drawWithEnabled(ui: *Ui, store: *config.Store, manager: *manager_module.Manager, catalogue: library.Snapshot, enabled: bool) void {
    const doc = store.snapshot();
    const snapshot = manager.snapshot();
    const busy = !enabled or manager.isBusy() or snapshot.phase == .awaiting_publication;
    const selected = selectedInstance(doc);
    const scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false, .padding = R.all(0), .border = R.all(0) });
    defer scroll.deinit();
    const column = dvui.box(@src(), .{}, .{ .expand = .horizontal, .padding = R.all(0) });
    defer column.deinit();
    {
        const heading = dvui.box(@src(), .{}, .{ .expand = .horizontal, .padding = R.all(0), .margin = .{ .h = 12 } });
        wrapped(@src(), if (selected) |instance| instance.name else "实例", dvui.themeGet().text);
        if (selected) |instance| {
            wrapped(@src(), fmt("Minecraft {s} · {s}{s}{s}", .{ instance.minecraft_version, @tagName(instance.loader), if (instance.loader_version != null) " " else "", instance.loader_version orelse "" }), theme.muted);
            const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = R.all(0) });
            if (!busy and ui.mode == .none and ui.pending == null) {
                if (iconButton(@src(), "编辑启动选项", dvui.entypo.cog)) ui.queue(.edit, instance.id);
                if (iconButton(@src(), "重命名实例", dvui.entypo.pencil)) ui.queue(.ask_rename, instance.id);
                if (iconButton(@src(), "移至恢复区", dvui.entypo.trash)) ui.queue(.ask_delete, instance.id);
            }
            actions.deinit();
        }
        heading.deinit();
    }
    if (ui.failure) |err| wrapped(@src(), fmt("操作失败：{s}", .{failureMessage(err)}), dvui.Color.fromHex("F0A6A1"));
    if (snapshot.failure) |err| wrapped(@src(), fmt("实例任务：{s}", .{failureMessage(err)}), dvui.Color.fromHex("F0A6A1"));
    if (snapshot.durability_uncertain) wrapped(@src(), "目录操作已提交，但尚未确认写入持久化；请保留恢复目录，勿重复执行。", dvui.Color.fromHex("F0C78D"));
    switch (snapshot.phase) {
        .working => {
            const status = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = R.all(0) });
            wrapped(@src(), fmt("处理中 · {d}/{d}", .{ snapshot.completed, snapshot.total }), theme.muted);
            if (enabled and iconButton(@src(), "取消任务", dvui.entypo.cross)) ui.queue(.cancel, null);
            status.deinit();
        },
        .awaiting_publication => {
            wrapped(@src(), "文件操作已完成，等待保存配置。", theme.muted);
            if (enabled and ui.publication_failed and iconButton(@src(), "重试保存配置", dvui.entypo.cw)) ui.queue(.retry_publication, null);
        },
        .complete => wrapped(@src(), switch (snapshot.operation) {
            .creating => "实例安装已完成。",
            .importing => if (snapshot.local_client_verified) "已登记：原版本地元数据和客户端哈希、大小已验证；依赖及 Java 尚未验证。" else "已导入：仅验证元数据，尚未验证依赖。",
            .renaming => "实例已重命名。",
            .deleting => "实例已移至恢复区，绑定服务器配置已移除。",
            .loading_loaders => "加载器目录已读取。",
            else => "操作已完成。",
        }, theme.muted),
        .canceled => wrapped(@src(), "操作已取消。", theme.muted),
        else => {},
    }
    if (snapshot.recovery_directory) |path| wrapped(@src(), fmt("恢复目录：{s}", .{path}), theme.muted);
    if (ui.mode != .none) drawEditor(ui, doc, manager, catalogue, enabled);
    if (selected == null and ui.mode == .none) wrapped(@src(), if (doc.instances.len == 0) "暂无实例" else "未选择实例", theme.muted);
}

test "instance sidebar owns queued stable selection and right detail follows ID after reorder" {
    const a = std.testing.allocator;
    var ui = Ui.init(a);
    defer ui.deinit();
    var id = "stable-b".*;
    queueSidebarAction(&ui, .select, &id, false, true);
    @memset(&id, 'x');
    try std.testing.expectEqual(Action.select, ui.pending.?.action);
    try std.testing.expectEqualStrings("stable-b", ui.pending.?.text.?);
    var rows = [_]config.Instance{
        .{ .id = "stable-a", .name = "First", .minecraft_version = "1.20" },
        .{ .id = "stable-b", .name = "Second", .minecraft_version = "1.21", .loader = .fabric, .loader_version = "0.16" },
    };
    var doc: config.Document = .{ .instances = &rows, .selected_instance = ui.pending.?.text.? };
    try std.testing.expectEqualStrings("Second", selectedInstance(&doc).?.name);
    std.mem.swap(config.Instance, &rows[0], &rows[1]);
    try std.testing.expectEqualStrings("stable-b", selectedInstance(&doc).?.id);
    try std.testing.expectEqualStrings("1.21", selectedInstance(&doc).?.minecraft_version);
    try std.testing.expectEqual(config.Loader.fabric, selectedInstance(&doc).?.loader);
    doc.selected_instance = "missing";
    try std.testing.expect(selectedInstance(&doc) == null);
    doc.selected_instance = null;
    try std.testing.expect(selectedInstance(&doc) == null);
}

test "instance sidebar respects disabled draft worker pending and pack gates" {
    var ui = Ui.init(std.testing.allocator);
    defer ui.deinit();
    queueSidebarAction(&ui, .select, "other", false, false);
    queueSidebarPack(&ui, false, false);
    try std.testing.expect(ui.pending == null and !ui.pack_requested);
    queueSidebarAction(&ui, .create, null, true, true);
    queueSidebarPack(&ui, true, true);
    try std.testing.expect(ui.pending == null and !ui.pack_requested);
    try setText(&ui.draft.name, "Preserved draft");
    for ([_]Mode{ .create, .import_folder, .options, .rename, .delete_confirm }) |mode| {
        ui.mode = mode;
        queueSidebarAction(&ui, .select, "other", false, true);
        queueSidebarPack(&ui, false, true);
        try std.testing.expect(ui.pending == null and !ui.pack_requested);
        try std.testing.expectEqualStrings("Preserved draft", text(&ui.draft.name));
    }
    ui.mode = .none;
    queueSidebarAction(&ui, .import_folder, null, false, true);
    queueSidebarAction(&ui, .select, "other", false, true);
    queueSidebarPack(&ui, false, true);
    try std.testing.expectEqual(Action.import_folder, ui.pending.?.action);
    try std.testing.expect(!ui.pack_requested);
    ui.pending = null;
    queueSidebarPack(&ui, false, true);
    try std.testing.expect(ui.pack_requested);
    queueSidebarAction(&ui, .create, null, false, true);
    try std.testing.expect(ui.pending == null);
}

test "draft ID allocation failure remains empty and safely retries without replacing an existing ID" {
    const a = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var draft: Draft = .{};
    defer draft.deinit(a);
    try std.testing.expectError(error.OutOfMemory, draft.ensureId(failing.allocator(), std.testing.io));
    try std.testing.expect(draft.id == null);
    draft.deinit(failing.allocator());
    try std.testing.expect(draft.id == null);
    try draft.ensureId(a, std.testing.io);
    const generated_id = draft.id.?;
    try std.testing.expect(std.mem.startsWith(u8, generated_id, "instance-"));
    try std.testing.expectEqual(@as(usize, 41), generated_id.len);
    try draft.ensureId(failing.allocator(), std.testing.io);
    try std.testing.expect(draft.id.?.ptr == generated_id.ptr);
    try std.testing.expectEqualStrings(generated_id, draft.id.?);

    var existing: Draft = .{ .id = try a.dupe(u8, "pending-valid-id") };
    defer existing.deinit(a);
    const existing_id = existing.id.?;
    try existing.ensureId(failing.allocator(), std.testing.io);
    try std.testing.expect(existing.id.?.ptr == existing_id.ptr);
    try std.testing.expectEqualStrings("pending-valid-id", existing.id.?);
}

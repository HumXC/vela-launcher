//! Native pack discovery and installation presentation. Actions run after widgets close.
const std = @import("std");
const dvui = @import("dvui");
const components = @import("components.zig");
const theme = @import("theme.zig");
const config = @import("../core/config.zig");
const providers = @import("../core/content_providers.zig");
const manifest = @import("../core/content_manifest.zig");
const picker = @import("file_picker.zig");
const icons = @import("resource_icons.zig");

pub const Route = enum { catalog, detail, local, confirm };
pub const Intent = union(enum) { search, refresh, page: u32, project: usize, back, import_file, choose_archive, inspect_archive, prepare, install, cancel, dismiss, retry_publication, view_instance, manual: usize, optional: struct { index: usize, include: bool } };
pub const Task = enum { none, working, complete, failed, canceled };
pub const Manual = struct { path: []const u8, url: []const u8, index: usize, verified: bool = false };
pub const Presentation = struct {
    busy: bool = false,
    curseforge_available: bool = false,
    pack: ?manifest.PackPlan = null,
    manual: []const Manual = &.{},
    ready: bool = false,
    task: Task = .none,
    stage: []const u8 = "正在准备",
    fraction: ?f32 = null,
    details: @import("../core/tasks.zig").Details = .{},
    publication_pending: bool = false,
    failure: ?anyerror = null,
};
pub const Ui = struct {
    allocator: std.mem.Allocator,
    catalog_owner: std.heap.ArenaAllocator,
    detail_owner: std.heap.ArenaAllocator,
    catalog: []const providers.Project = &.{},
    project: ?providers.Project = null,
    versions: []const providers.Version = &.{},
    selected_version: usize = 0,
    route: Route = .catalog,
    return_route: Route = .detail,
    query: [513]u8 = @splat(0),
    submitted_query: [513]u8 = @splat(0),
    submitted_minecraft: [65]u8 = @splat(0),
    submitted_loader: usize = 0,
    submitted_provider: usize = 0,
    minecraft: [65]u8 = @splat(0),
    loader_choice: usize = 0,
    provider_choice: usize = 0,
    offset: u32 = 0,
    total: u64 = 0,
    searched: bool = false,
    name: [201]u8 = @splat(0),
    archive: [32769]u8 = @splat(0),
    catalog_scroll: dvui.ScrollInfo = .{},
    detail_scroll: dvui.ScrollInfo = .{},
    pending: ?Intent = null,
    failure: ?anyerror = null,
    picker_service: ?*picker.Service = null,
    picker_ticket: ?picker.Ticket = null,
    picker_manual: ?usize = null,
    active: bool = false,
    task_visible: bool = false,
    icon_cache: ?icons.Manager = null,

    pub fn init(a: std.mem.Allocator) Ui {
        return .{ .allocator = a, .catalog_owner = .init(a), .detail_owner = .init(a) };
    }
    pub fn deinit(self: *Ui) void {
        self.discardPicker();
        if (self.icon_cache) |*cache| cache.deinit();
        self.detail_owner.deinit();
        self.catalog_owner.deinit();
    }
    pub fn discardPicker(self: *Ui) void {
        if (self.picker_ticket) |ticket| if (self.picker_service) |service| service.discard(ticket);
        self.picker_ticket = null;
        self.picker_manual = null;
    }
    pub fn queue(self: *Ui, intent: Intent) void {
        if (self.pending == null) self.pending = intent;
    }
    pub fn acceptCatalog(self: *Ui, projects: []const providers.Project, total: u64) !void {
        var next = std.heap.ArenaAllocator.init(self.allocator);
        errdefer next.deinit();
        const values = try copy([]const providers.Project, next.allocator(), projects);
        self.catalog_owner.deinit();
        self.catalog_owner = next;
        self.catalog = values;
        self.total = total;
        self.searched = true;
    }
    pub fn openProject(self: *Ui, index: usize) !void {
        if (index >= self.catalog.len) return error.NoProject;
        var next = std.heap.ArenaAllocator.init(self.allocator);
        errdefer next.deinit();
        const project = try copy(providers.Project, next.allocator(), self.catalog[index]);
        self.detail_owner.deinit();
        self.detail_owner = next;
        self.project = project;
        self.versions = &.{};
        self.selected_version = 0;
        self.detail_scroll = .{};
        self.route = .detail;
    }
    pub fn acceptVersions(self: *Ui, versions: []const providers.Version) !void {
        var next = std.heap.ArenaAllocator.init(self.allocator);
        errdefer next.deinit();
        const project = try copy(?providers.Project, next.allocator(), self.project);
        const owned = try copy([]const providers.Version, next.allocator(), versions);
        self.detail_owner.deinit();
        self.detail_owner = next;
        self.project = project;
        self.versions = owned;
        self.selected_version = 0;
    }
    pub fn version(self: *const Ui) ?providers.Version {
        return if (self.selected_version < self.versions.len) self.versions[self.selected_version] else null;
    }
};
fn copy(comptime T: type, a: std.mem.Allocator, value: T) anyerror!T {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var result: T = undefined;
            inline for (info.field_names, info.field_types) |name, F| @field(result, name) = try copy(F, a, @field(value, name));
            return result;
        },
        .@"union" => |info| {
            inline for (info.field_names, info.field_types) |name, F| if (std.meta.activeTag(value) == @field(info.tag_type.?, name)) return @unionInit(T, name, try copy(F, a, @field(value, name)));
            unreachable;
        },
        .optional => |info| return if (value) |v| try copy(info.child, a, v) else null,
        .pointer => |info| {
            if (info.size != .slice) return value;
            const out = try a.alloc(info.child, value.len);
            for (value, out) |v, *p| p.* = try copy(info.child, a, v);
            return out;
        },
        else => return value,
    }
}
pub fn text(buffer: []const u8) []const u8 {
    return buffer[0 .. std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len];
}
pub fn setText(buffer: []u8, value: []const u8) !void {
    if (value.len >= buffer.len) return error.TextTooLong;
    @memset(buffer, 0);
    @memcpy(buffer[0..value.len], value);
}
fn fmt(comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), f, args) catch "";
}
fn plain(src: std.builtin.SourceLocation, dir: @FieldType(dvui.BoxWidget.InitOptions, "dir"), options: dvui.Options) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = dir }, (dvui.Options{ .expand = .horizontal, .max_size_content = .width(0), .padding = .all(0), .margin = .all(0), .background = false }).override(options));
}
fn entry(src: std.builtin.SourceLocation, label: []const u8, placeholder: []const u8, buffer: []u8) void {
    var input: dvui.TextEntryWidget = undefined;
    const font = theme.bodyFont();
    const geometry = theme.textEntryGeometry(font.textHeight(), 0);
    input.init(src, .{ .text = .{ .buffer = buffer }, .placeholder = placeholder }, theme.controlOptions(font.textHeight()).override(.{ .label = .{ .text = label }, .expand = .horizontal, .max_size_content = .width(0), .min_size_content = geometry.content, .padding = geometry.padding, .margin = .all(0) }));
    const empty = input.len == 0;
    if (empty) _ = input.textLayout.selectionGet(0);
    input.processEvents();
    if (empty and input.textLayout.sel_move == .mouse) input.textLayout.sel_move = .none;
    if (input.data().id == dvui.focusedWidgetId()) input.init_opts.placeholder = null;
    input.draw();
    input.deinit();
}
pub fn failureMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ProviderDisabled => "CurseForge 尚未配置，请在设置中配置后使用。",
        error.InvalidInstanceName => "请输入有效的实例名称。",
        error.DuplicateInstanceName, error.DuplicateName => "实例名称已存在，请换一个名称。",
        error.HashMismatch, error.SizeMismatch, error.ManualFileMismatch => "文件校验不通过，请重新选择。",
        error.UnsupportedPackArchive, error.PackFormatMismatch => "请选择有效的 .mrpack 或 CurseForge 整合包 .zip 文件。",
        error.Cancelled, error.Canceled => "操作已取消。",
        error.TimedOut, error.DeadlineExceeded => "连接或传输等待超时，请检查网络后重试。",
        error.SourcePolicyChanged => "来源设置已改变，请返回并重新读取整合包。",
        error.ManualArchiveRequired => "此整合包需要手动下载，请从项目主页下载后选择从文件导入。",
        error.UnresolvedPackReferences => "整合包文件信息尚未解析完成，请检查来源设置后重新读取。",
        error.ManualFileRequired => "请选择所有必需的手动下载文件。",
        error.ProtectedPath => "整合包包含受保护路径，无法写入。",
        error.PackGameCollision => "整合包文件与实例已有文件冲突，已停止安装。",
        else => fmt("操作失败：{s}", .{@errorName(err)}),
    };
}
pub fn draw(ui: *Ui, state: Presentation, allowed: bool) void {
    const root = plain(@src(), .vertical, .{ .expand = .both, .tag = "pack-page" });
    defer root.deinit();
    const ready = allowed and !state.busy and ui.picker_ticket == null;
    {
        const heading = plain(@src(), .horizontal, .{ .margin = .{ .h = 16 } });
        defer heading.deinit();
        components.title(@src(), switch (ui.route) {
            .catalog => "获取整合包",
            .detail => "整合包详情",
            .local => "从文件导入",
            .confirm => "创建整合包实例",
        });
    }
    if (ui.route == .catalog) searchControls(ui, state, ready);
    {
        const footer = plain(@src(), .horizontal, .{ .gravity_y = 1, .min_size_content = .height(48), .max_size_content = .height(48), .margin = .{ .y = 16 } });
        defer footer.deinit();
        const w = footer.data().contentRect().w;
        const bw: f32 = if (w < 480) 64 else 96;
        if (components.button(@src(), "返回", .{ .standalone = true, .enabled = allowed and state.task != .working, .rect = .{ .w = bw, .h = 48 }, .placement = .footer, .min_width = bw, .tag = "pack-back" })) ui.queue(.back);
        if (ui.route == .catalog) {
            if (components.button(@src(), "上一页", .{ .standalone = true, .enabled = ready and ui.offset >= 40, .rect = .{ .x = bw + 8, .w = bw, .h = 48 }, .placement = .footer, .min_width = bw, .tag = "pack-previous" })) ui.queue(.{ .page = ui.offset - 40 });
            if (components.button(@src(), "下一页", .{ .standalone = true, .enabled = ready and @as(u64, ui.offset) + ui.catalog.len < ui.total and ui.offset <= std.math.maxInt(u32) - 40, .rect = .{ .x = 2 * (bw + 8), .w = bw, .h = 48 }, .placement = .footer, .min_width = bw, .tag = "pack-next" })) ui.queue(.{ .page = ui.offset + 40 });
            const import_x = @max(3 * (bw + 8), w - bw - 152);
            if (components.button(@src(), "从文件导入", .{ .standalone = true, .enabled = ready, .rect = .{ .x = import_x, .w = 144, .h = 48 }, .placement = .footer, .min_width = 144, .tag = "pack-import" })) ui.queue(.import_file);
            if (components.button(@src(), "刷新", .{ .standalone = true, .enabled = ready, .rect = .{ .x = import_x + 152, .w = bw, .h = 48 }, .placement = .footer, .min_width = bw, .tag = "pack-refresh" })) ui.queue(.refresh);
        } else if (ui.route == .detail) {
            if (components.button(@src(), "安装为新实例", .{ .standalone = true, .enabled = ready and ui.version() != null, .primary = true, .gravity_x = 1, .placement = .footer, .tag = "pack-prepare" })) ui.queue(.prepare);
        } else if (ui.route == .local) {
            if (components.button(@src(), "下一步", .{ .standalone = true, .enabled = ready and state.pack != null, .primary = true, .gravity_x = 1, .placement = .footer, .tag = "pack-next-import" })) ui.queue(.prepare);
        } else {
            if (components.button(@src(), "创建实例", .{ .standalone = true, .enabled = ready and state.ready and text(&ui.name).len != 0, .primary = true, .gravity_x = 1, .placement = .footer, .tag = "pack-install" })) ui.queue(.install);
        }
    }
    const scroll = dvui.scrollArea(@src(), .{ .horizontal = .none, .scroll_info = if (ui.route == .catalog) &ui.catalog_scroll else &ui.detail_scroll }, .{ .expand = .both, .background = false, .padding = .all(0), .margin = .all(0), .border = .all(0) });
    defer scroll.deinit();
    // Task failures belong to the task dialog, including after it is dismissed.
    const display_failure: ?anyerror = if (state.task == .none and ui.failure != state.failure) ui.failure else null;
    if (display_failure) |err| components.text(@src(), failureMessage(err), theme.colors.danger);
    switch (ui.route) {
        .catalog => catalog(ui, state, ready),
        .detail => detail(ui, state, ready),
        .local => local(ui, state, ready),
        .confirm => confirmation(ui, state, ready),
    }
}
fn searchControls(ui: *Ui, state: Presentation, ready: bool) void {
    const narrow = dvui.parentGet().data().contentRect().w < 680;
    {
        const row = plain(@src(), if (narrow) .vertical else .horizontal, .{ .margin = .{ .h = 16 } });
        defer row.deinit();
        {
            const query = plain(@src(), .vertical, .{ .margin = .{ .w = if (narrow) 0 else 16 } });
            defer query.deinit();
            entry(@src(), "搜索整合包", "搜索名称或关键词", &ui.query);
        }
        const source = plain(@src(), .horizontal, .{ .expand = if (narrow) .horizontal else .none, .min_size_content = .width(if (narrow) 0 else 324), .max_size_content = .width(if (narrow) 0 else 324), .margin = .{ .y = if (narrow) 8 else 0 } });
        defer source.deinit();
        _ = components.dropdown(@src(), "整合包来源", &.{ "Modrinth", if (state.curseforge_available) "CurseForge" else "CurseForge（未配置）" }, .{ .choice = &ui.provider_choice }, .{}, .{ .expand = .horizontal, .margin = .{ .w = 8 }, .tag = "pack-source" });
        if (components.button(@src(), if (state.busy) "搜索中…" else "搜索", .{ .enabled = ready, .primary = true, .min_width = 96, .placement = .footer, .tag = "pack-search" })) ui.queue(.search);
    }
    const filters = plain(@src(), .horizontal, .{ .margin = .{ .h = 16 } });
    defer filters.deinit();
    {
        const game = plain(@src(), .vertical, .{ .margin = .{ .w = 16 } });
        defer game.deinit();
        entry(@src(), "游戏版本筛选", "全部游戏版本", &ui.minecraft);
    }
    _ = components.dropdown(@src(), "加载器筛选", &.{ "全部加载器", "Fabric", "Forge", "NeoForge", "Quilt" }, .{ .choice = &ui.loader_choice }, .{}, .{ .expand = .horizontal, .tag = "pack-loader" });
}
fn catalog(ui: *Ui, state: Presentation, ready: bool) void {
    components.hint(@src(), fmt("第 {d} 页 · 共 {d} 个整合包", .{ ui.offset / 40 + 1, ui.total }));
    if (state.busy) components.hint(@src(), "正在搜索整合包…");
    if (ui.catalog.len == 0 and !state.busy and ui.failure == null and state.failure == null) components.emptyState(@src(), if (ui.searched) "没有找到整合包，试试其他关键词或筛选条件。" else "搜索整合包，或从本地文件导入。");
    for (ui.catalog, 0..) |project, i| {
        const card = components.bentoPanel(@src(), .{ .id_extra = i, .expand = .horizontal, .max_size_content = .width(0), .padding = .all(16), .margin = .{ .h = 16 } });
        defer card.deinit();
        const row = plain(@src(), .horizontal, .{ .tag = fmt("pack-project-row-{d}", .{i}) });
        defer row.deinit();
        {
            const action = plain(@src(), .vertical, .{ .expand = .none, .gravity_x = 1, .gravity_y = 0.5, .min_size_content = .width(120), .max_size_content = .width(120), .margin = .{ .x = 16 } });
            defer action.deinit();
            if (components.button(@src(), "查看详情", .{ .enabled = ready, .min_width = 120, .placement = .footer, .tag = fmt("pack-project-{d}", .{i}) })) ui.queue(.{ .project = i });
        }
        // Only visible rows request work; disabled frames only reuse presentation pixels.
        const visible = !card.data().borderRectScale().r.intersect(dvui.clipGet()).empty();
        const bitmap = projectBitmap(ui, project.icon_url, ready and visible);
        icons.draw(@src(), bitmap, 64, null);
        const info = plain(@src(), .vertical, .{ .margin = .{ .x = 16 } });
        defer info.deinit();
        components.fieldLabel(@src(), project.name);
        components.text(@src(), project.summary, theme.colors.foreground);
    }
}
fn projectBitmap(ui: *Ui, url: ?[]const u8, request: bool) ?*const icons.Bitmap {
    const cache = if (ui.icon_cache) |*value| value else return null;
    if (request) return cache.get(url);
    const value = url orelse return null;
    for (cache.entries.items) |cached| if (std.mem.eql(u8, cached.url, value)) return cached.bitmap;
    return null;
}
fn detail(ui: *Ui, state: Presentation, ready: bool) void {
    if (ui.project) |project| {
        {
            const card = components.bentoPanel(@src(), .{ .expand = .horizontal, .padding = .{ .x = 23, .w = 23, .y = 15, .h = 15 }, .margin = .{ .h = 16 } });
            defer card.deinit();
            const row = plain(@src(), .horizontal, .{});
            defer row.deinit();
            {
                const image = plain(@src(), .vertical, .{ .expand = .none, .min_size_content = .width(80), .max_size_content = .width(80), .tag = "pack-detail-icon" });
                defer image.deinit();
                const visible = !card.data().borderRectScale().r.intersect(dvui.clipGet()).empty();
                icons.draw(@src(), projectBitmap(ui, project.icon_url, ready and visible), 80, null);
            }
            const info = plain(@src(), .vertical, .{ .margin = .{ .x = 16 } });
            defer info.deinit();
            if (dvui.labelClick(@src(), "{s}", .{project.name}, .{}, .{ .tag = "pack-project-link", .font = theme.fontSized(18).withUnderline(.{}), .color_text = .{ .color = theme.colors.accent }, .padding = .all(0), .margin = .all(0) }) and ready) openPage(ui, project.official_page);
            components.text(@src(), project.summary, theme.colors.foreground);
        }
        const card = components.bentoPanel(@src(), .{ .expand = .horizontal, .padding = .{ .x = 23, .w = 23, .y = 15, .h = 15 } });
        defer card.deinit();
        components.fieldLabel(@src(), "选择版本");
        if (state.busy and state.task == .none) {
            components.hint(@src(), "正在读取版本…");
            return;
        }
        if (ui.versions.len == 0) {
            components.emptyState(@src(), "没有符合条件的版本。");
            if (components.button(@src(), "重试", .{ .enabled = ready })) ui.queue(.refresh);
            return;
        }
        const labels = dvui.currentWindow().arena().alloc([]const u8, ui.versions.len) catch return;
        for (ui.versions, labels) |version, *label| label.* = version.name;
        _ = components.dropdown(@src(), "整合包版本", labels, .{ .choice = &ui.selected_version }, .{}, .{ .expand = .horizontal, .tag = "pack-version" });
        if (ui.version()) |version| {
            components.hint(@src(), fmt("Minecraft：{s}", .{if (version.minecraft_versions.len > 0) version.minecraft_versions[0] else "以包内清单为准"}));
            components.hint(@src(), fmt("加载器：{s}", .{if (version.loaders.len > 0) version.loaders[0] else "以包内清单为准"}));
        }
    }
}
fn local(ui: *Ui, state: Presentation, ready: bool) void {
    {
        const card = components.bentoPanel(@src(), .{ .expand = .horizontal, .padding = .{ .x = 23, .w = 23, .y = 15, .h = 15 }, .margin = .{ .h = 16 } });
        defer card.deinit();
        components.fieldLabel(@src(), "整合包文件");
        entry(@src(), "整合包归档", "选择 .mrpack 或 .zip 文件", &ui.archive);
        if (components.button(@src(), "选择文件", .{ .enabled = ready, .tag = "pack-choose-archive" })) ui.queue(.choose_archive);
        if (components.button(@src(), "读取文件", .{ .enabled = ready and text(&ui.archive).len != 0 })) ui.queue(.inspect_archive);
        components.hint(@src(), "支持 Modrinth .mrpack 与 CurseForge 整合包 .zip。");
    }
    if (state.busy) components.hint(@src(), "正在检查整合包文件…");
    if (state.pack) |pack| packSummary(pack);
}
fn packSummary(pack: manifest.PackPlan) void {
    const card = components.bentoPanel(@src(), .{ .expand = .horizontal, .padding = .{ .x = 23, .w = 23, .y = 15, .h = 15 }, .margin = .{ .h = 16 } });
    defer card.deinit();
    components.fieldLabel(@src(), fmt("{s} · {s}", .{ pack.name, pack.version }));
    components.text(@src(), fmt("Minecraft {s} / {s} {s}", .{ pack.minecraft_version, @tagName(pack.loader), pack.loader_version orelse "" }), theme.colors.foreground);
    components.hint(@src(), "Java：自动选择");
    components.hint(@src(), "游戏与加载器版本由整合包确定。");
}
fn confirmation(ui: *Ui, state: Presentation, ready: bool) void {
    {
        const card = components.bentoPanel(@src(), .{ .expand = .horizontal, .padding = .{ .x = 23, .w = 23, .y = 15, .h = 15 }, .margin = .{ .h = 16 }, .tag = "pack-name-card" });
        defer card.deinit();
        components.fieldLabel(@src(), "实例名称");
        entry(@src(), "实例名称", "输入实例名称", &ui.name);
    }
    if (state.pack) |pack| {
        packSummary(pack);
        const card = components.bentoPanel(@src(), .{ .expand = .horizontal, .padding = .{ .x = 23, .w = 23, .y = 15, .h = 15 } });
        defer card.deinit();
        components.fieldLabel(@src(), "安装内容");
        components.hint(@src(), "必需模组与配置将全部安装。");
        for (0..pack.sourceFileCount()) |i| {
            const file = pack.sourceFile(i);
            if (file.required) continue;
            var selected = file.selected orelse false;
            if (dvui.checkbox(@src(), &selected, file.record.path, .{ .id_extra = i })) if (ready) ui.queue(.{ .optional = .{ .index = i, .include = selected } });
        }
        for (state.manual, 0..) |file, i| {
            const row = plain(@src(), .vertical, .{ .id_extra = i, .margin = .{ .y = 16 } });
            defer row.deinit();
            components.text(@src(), file.path, theme.colors.foreground);
            components.hint(@src(), if (file.verified) "已选择，安装时校验" else "此文件需要手动下载并选择");
            if (components.button(@src(), "打开下载页", .{ .enabled = ready })) openPage(ui, file.url);
            if (components.button(@src(), "选择文件", .{ .enabled = ready })) ui.queue(.{ .manual = file.index });
        }
    }
}
fn openPage(ui: *Ui, url: []const u8) void {
    if (!providers.safeHttpsUrl(url)) {
        ui.failure = error.InvalidDownloadUrl;
        return;
    }
    if (!dvui.openURL(.{ .url = url })) ui.failure = error.OpenUrlFailed;
}
pub fn failureStage(stage: @import("../core/tasks.zig").Stage) []const u8 {
    return switch (stage) {
        .metadata => "获取整合包信息失败",
        .downloading => "下载失败",
        .verifying => "文件校验失败",
        .extracting => "解压或检查整合包失败",
        .finalizing => "完成安装失败",
        else => "安装失败",
    };
}
pub fn dialogs(ui: *Ui, state: Presentation, allowed: bool) void {
    if (!ui.task_visible or state.task == .none) return;
    const task_style = @import("download_task_style.zig");
    const metrics = @import("instance_task_view.zig");
    const window = components.modalPanel(@src(), "下载与安装", task_style.modal_height, null);
    defer window.deinit();
    const layout = task_style.Layout.current();
    const width = layout.width;
    const failure = if (ui.failure != null) ui.failure else state.failure;
    const failed = state.task == .failed;
    task_style.text(@src(), "下载与安装", theme.fontSized(24), .{ .w = width, .h = 36 }, if (failed) theme.colors.danger else theme.colors.foreground);
    const summary = if (state.pack) |pack| fmt("{s} · {s}", .{ pack.name, pack.version }) else if (ui.project) |project| project.name else "整合包实例";
    task_style.text(@src(), summary, theme.bodyFont(), .{ .y = if (layout.compact) 44 else 52, .w = width, .h = 24 }, theme.colors.muted);
    task_style.text(@src(), if (failed) (if (layout.compact and failure != null and state.details.file_count == 0) failureMessage(failure.?) else failureStage(state.details.stage)) else state.stage, theme.bodyFont(), .{ .y = if (layout.compact) 76 else 88, .w = width, .h = 24 }, if (failed) theme.colors.danger else if (state.task == .complete) theme.colors.accent else theme.colors.muted);
    _ = dvui.separator(@src(), .{ .rect = .{ .y = if (layout.compact) 108 else 128, .w = width, .h = 1 }, .padding = .all(0), .margin = .all(0), .color_border = .{ .color = theme.colors.outline } });
    var amount_buffer: [64]u8 = undefined;
    var total_buffer: [64]u8 = undefined;
    var speed_buffer: [64]u8 = undefined;
    {
        const scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .rect = .{ .y = layout.body_y, .w = width, .h = @max(0, layout.hint_y - layout.body_y - 16) }, .padding = .all(0), .margin = .all(0), .background = false });
        defer scroll.deinit();
        for (state.details.files[0..@min(state.details.file_count, state.details.files.len)], 0..) |*file, index| {
            const percent = metrics.fraction(file.received, file.total);
            const status: []const u8 = switch (file.state) {
                .queued => "等待下载",
                .downloading => if (file.total != null) fmt("下载中 · {d:.0}%", .{percent * 100}) else "下载中",
                .verifying => "校验中",
                .complete => "已下载",
                .failed => failureStage(state.details.stage),
                .canceled => "已取消",
            };
            const color = if (file.state == .failed) theme.colors.danger else if (file.state == .canceled or file.state == .queued) theme.colors.muted else theme.colors.accent;
            const subtitle = if (file.failure) |err| failureMessage(err) else fmt("{s} / {s} · {s}", .{ metrics.formatBytes(&amount_buffer, file.received) catch "—", if (file.total) |total| metrics.formatBytes(&total_buffer, total) catch "—" else "大小未知", metrics.formatSpeed(&speed_buffer, file.bytes_per_second, file.state == .downloading) catch "—" });
            task_style.fileCard(index, if (file.failure != null) file.path() else file.name(), subtitle, status, percent, color, fmt("pack-task-file-{d}", .{index}));
        }
        if (state.details.file_count == 0 and state.task == .working) components.hint(@src(), "正在准备文件列表…");
        if (state.details.omitted_files > 0) components.hint(@src(), fmt("另有 {d} 个文件未显示", .{state.details.omitted_files}));
    }
    if (!layout.compact) {
        const summary_metrics = fmt("已接收 {s} / {s} · {s}", .{ metrics.formatBytes(&amount_buffer, state.details.received) catch "—", if (state.details.total_bytes) |total| metrics.formatBytes(&total_buffer, total) catch "—" else "大小未知", metrics.formatSpeed(&speed_buffer, state.details.bytes_per_second, state.task == .working) catch "—" });
        task_style.text(@src(), if (failure) |err| failureMessage(err) else summary_metrics, theme.bodyFont(), .{ .y = layout.hint_y, .w = width, .h = 48 }, if (failed) theme.colors.danger else theme.colors.muted);
    }
    const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .rect = .{ .y = layout.footer_y, .w = width, .h = 48 }, .padding = .all(0), .margin = .all(0), .background = false });
    defer actions.deinit();
    if (state.task == .working) {
        if (state.publication_pending) {
            if (components.button(@src(), "重试保存配置", .{ .enabled = allowed, .gravity_x = 1, .min_width = 144, .placement = .footer })) ui.queue(.retry_publication);
        } else if (components.button(@src(), "取消任务", .{ .enabled = allowed, .gravity_x = 1, .min_width = 144, .placement = .footer, .tag = "pack-task-cancel" })) ui.queue(.cancel);
    } else if (state.task == .complete) {
        if (components.button(@src(), "查看实例", .{ .enabled = allowed, .primary = true, .gravity_x = 1, .min_width = 144, .placement = .footer })) ui.queue(.view_instance);
    } else {
        if (components.button(@src(), "关闭", .{ .enabled = allowed, .gravity_x = 1, .min_width = 144, .placement = .footer })) ui.queue(.dismiss);
    }
}

test "pack disabled frames retain cached bitmap without queuing downloads" {
    const a = std.testing.allocator;
    var ui = Ui.init(a);
    defer ui.deinit();
    ui.icon_cache = icons.Manager.init(a, std.testing.io);
    const url = "https://cdn.modrinth.com/cached.png";
    const bitmap = try a.create(icons.Bitmap);
    bitmap.* = @splat(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
    try ui.icon_cache.?.entries.append(a, .{ .url = try a.dupe(u8, url), .bitmap = bitmap, .touched = 0, .pending = false });
    try std.testing.expect(projectBitmap(&ui, url, false).? == bitmap);
    try std.testing.expect(projectBitmap(&ui, "https://cdn.modrinth.com/missing.png", false) == null);
    try std.testing.expect(!ui.icon_cache.?.busy());
    try std.testing.expectEqual(@as(usize, 1), ui.icon_cache.?.entries.items.len);
}

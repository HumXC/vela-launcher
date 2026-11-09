//! Resource discovery, detail, confirmation and blocking installation dialogs.
const std = @import("std");
const dvui = @import("dvui");
const state = @import("resource_download_state.zig");
const local = @import("../core/local_content.zig");
const content = @import("../application/content_manager.zig");
const providers = @import("../core/content_providers.zig");
const manifest = @import("../core/content_manifest.zig");
const components = @import("components.zig");
const theme = @import("theme.zig");
const footer_button_width: f32 = 96;
const footer_button_step = footer_button_width + theme.spacing.action_gap;

fn fmt(comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), format, args) catch "";
}
pub fn kindName(ui: *const state.Ui) []const u8 {
    return switch (ui.kind) {
        .mod => "模组",
        .resourcepack => "资源包",
        .shader => "光影",
    };
}
fn plain(src: std.builtin.SourceLocation, dir: @FieldType(dvui.BoxWidget.InitOptions, "dir"), options: dvui.Options) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = dir }, (dvui.Options{ .expand = .horizontal, .max_size_content = .width(0), .padding = .all(0), .margin = .all(0), .background = false }).override(options));
}
fn rememberedScroll(src: std.builtin.SourceLocation, info: *dvui.ScrollInfo) *dvui.ScrollAreaWidget {
    return dvui.scrollArea(src, .{ .horizontal = .none, .scroll_info = info }, .{ .expand = .both, .background = false, .padding = .all(0), .margin = .all(0), .border = .all(0) });
}
fn failureMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ProviderDisabled => "CurseForge 尚未配置，暂不可用。可在设置中配置后使用。",
        error.DisabledRequiredDependency => "必需依赖已安装但被禁用，请返回资源管理启用后重试。",
        error.ReceiptUpgradeRequired => "当前实例的资源记录需要升级后才能安装。",
        error.RecoveryRequired => "上次安装尚未完成恢复，请先恢复资源状态。",
        error.ContentControlsLocked, error.InstanceBusy, error.ContentWorkerBusy => "当前实例正在执行其他操作，请稍后重试。",
        error.FilePickerUnavailable => "文件选择器暂不可用。",
        error.HashMismatch, error.SizeMismatch, error.ManualFileMismatch => "选择的文件与此版本不匹配，请重新选择。",
        error.NoVersion, error.MissingDependencyVersion => "没有适用于当前实例的版本。",
        error.ConnectionResetByPeer, error.ConnectionReset, error.ConnectionTimedOut, error.NetworkUnreachable, error.ConnectionRefused, error.HttpRequestFailed, error.RequestTimeout => "网络连接中断，请重试。",
        error.Cancelled, error.Canceled => "操作已取消。",
        else => fmt("操作失败：{s}", .{@errorName(err)}),
    };
}
fn errorHint(ui: *state.Ui) void {
    if (ui.failure) |err| components.text(@src(), failureMessage(err), theme.colors.danger);
}
fn enabled(ui: *const state.Ui, snapshot: content.Snapshot, allowed: bool) bool {
    return allowed and ui.job == .idle and !snapshot.busy and !snapshot.recovery_required and ui.pending == null;
}
fn footer() *dvui.BoxWidget {
    const panel = plain(@src(), .vertical, .{ .gravity_y = 1, .padding = .{ .y = 16 } });
    return panel;
}
fn installedLabel(snapshot: content.Snapshot, entries: []const local.Entry, provider: providers.Provider, project: []const u8) void {
    const file = state.installed(snapshot, provider, project) orelse return;
    const version = state.installedVersion(snapshot, file, entries);
    components.text(@src(), fmt("已安装{s}{s}", .{ if (version) |name| fmt(" {s}", .{name}) else "", if (file.enabled) "" else " · 已禁用" }), theme.colors.accent);
}
pub fn draw(ui: *state.Ui, snapshot: content.Snapshot, allowed: bool, entries: []const local.Entry) void {
    const root = plain(@src(), .vertical, .{ .expand = .both, .tag = "resource-download-page" });
    defer root.deinit();
    const ready = enabled(ui, snapshot, allowed);
    {
        const heading = plain(@src(), .horizontal, .{ .margin = .{ .h = 8 } });
        defer heading.deinit();
        const title = plain(@src(), .vertical, .{ .gravity_y = 0.5 });
        defer title.deinit();
        components.title(@src(), fmt("{s}{s}", .{ if (ui.route == .catalog) "下载" else "", if (ui.route == .catalog) kindName(ui) else fmt("{s}详情", .{kindName(ui)}) }));
    }
    if (ui.instance) |instance| components.hint(@src(), fmt("{s} · Minecraft {s} · {s}", .{ instance.name, instance.minecraft_version, @tagName(instance.loader) }));
    if (ui.route != .catalog) _ = dvui.spacer(@src(), .{ .min_size_content = .height(2 * theme.spacing.card_gap) });
    if (ui.route == .catalog) drawCatalog(ui, snapshot, ready, entries) else drawDetail(ui, snapshot, ready, entries);
}
fn drawCatalog(ui: *state.Ui, snapshot: content.Snapshot, ready: bool, entries: []const local.Entry) void {
    const narrow = dvui.parentGet().data().contentRect().w < 680;
    {
        const controls = plain(@src(), if (narrow) .vertical else .horizontal, .{ .margin = .{ .y = 16, .h = 16 } });
        defer controls.deinit();
        {
            const search = plain(@src(), .vertical, .{ .margin = .{ .w = if (narrow) 0 else 16 } });
            defer search.deinit();
            var input: dvui.TextEntryWidget = undefined;
            const font = theme.bodyFont();
            const geometry = theme.textEntryGeometry(font.textHeight(), 0);
            input.init(@src(), .{ .text = .{ .buffer = &ui.query }, .placeholder = "搜索名称或关键词" }, theme.controlOptions(font.textHeight()).override(.{ .tag = "resource-query", .label = .{ .text = "搜索资源" }, .expand = .horizontal, .max_size_content = .width(0), .min_size_content = geometry.content, .padding = geometry.padding, .margin = .all(0) }));
            const was_empty = input.len == 0;
            if (was_empty) _ = input.textLayout.selectionGet(0);
            input.processEvents();
            // DVUI lays the hint out as selectable text and can defer an empty
            // click until the first glyph. Keep that click from moving typed text.
            if (was_empty and input.textLayout.sel_move == .mouse) input.textLayout.sel_move = .none;
            if (input.data().id == dvui.focusedWidgetId()) input.init_opts.placeholder = null;
            input.draw();
            input.deinit();
        }
        {
            const source = plain(@src(), .vertical, .{ .expand = if (narrow) .horizontal else .none, .min_size_content = .width(if (narrow) 0 else 324), .max_size_content = .width(if (narrow) 0 else 324) });
            defer source.deinit();
            const source_row = plain(@src(), .horizontal, .{});
            defer source_row.deinit();
            var choice: usize = if (ui.provider == .modrinth) 0 else 1;
            const previous = choice;
            _ = components.dropdown(@src(), "资源来源", &.{ "Modrinth", if (snapshot.curseforge_available) "CurseForge" else "CurseForge（未配置）" }, .{ .choice = &choice }, .{}, .{ .tag = "resource-provider", .expand = .horizontal, .min_size_content = .height(theme.sizing.control_height), .margin = .{ .w = theme.spacing.action_gap } });
            if (components.button(@src(), if (ui.job == .search) "搜索中…" else "搜索", .{ .standalone = true, .enabled = ready, .primary = true, .placement = .footer, .min_width = 96, .tag = "resource-search" })) ui.queue(.search);
            if (choice != previous and ready) {
                if (choice == 1 and !snapshot.curseforge_available) ui.failure = error.ProviderDisabled else ui.queue(.{ .provider = if (choice == 0) .modrinth else .curseforge });
            }
        }
    }
    {
        const area = footer();
        defer area.deinit();
        const actions = plain(@src(), .horizontal, .{ .min_size_content = .height(theme.sizing.control_height), .max_size_content = .height(theme.sizing.control_height), .margin = .{ .h = theme.spacing.action_gap } });
        defer actions.deinit();
        const previous_clip = dvui.clip(actions.data().contentRectScale().r);
        defer dvui.clipSet(previous_clip);
        backButtonAt(ui, .{ .w = footer_button_width, .h = theme.sizing.control_height });
        pagination(ui, ready);
        const refresh_x = @max(3 * footer_button_step, actions.data().contentRect().w - footer_button_width);
        if (components.button(@src(), "刷新", .{ .standalone = true, .enabled = ready, .placement = .footer, .rect = .{ .x = refresh_x, .w = footer_button_width, .h = theme.sizing.control_height }, .min_width = footer_button_width, .tag = "resource-refresh" })) ui.queue(.search);
    }
    const scroll = rememberedScroll(@src(), &ui.catalog_scroll);
    defer scroll.deinit();
    errorHint(ui);
    if (ui.catalog.len == 0 and ui.job == .idle and ui.failure == null) components.emptyState(@src(), if (ui.searched) "没有找到兼容的资源，请尝试其他关键词" else "输入关键词，查找适用于当前实例的资源");
    for (ui.catalog, 0..) |project, i| {
        const row = components.bentoPanel(@src(), .{ .id_extra = i, .expand = .horizontal, .max_size_content = .width(0), .padding = .all(if (narrow) 15 else 23), .margin = .{ .h = 12 } });
        defer row.deinit();
        const track = plain(@src(), .horizontal, .{});
        defer track.deinit();
        projectIcon(ui, project, if (narrow) 48 else 64);
        if (!narrow) {
            const action = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .none, .gravity_x = 1, .gravity_y = 0.5, .padding = .all(0), .margin = .{ .x = theme.spacing.action_gap }, .background = false });
            defer action.deinit();
            if (components.button(@src(), "查看详情", .{ .enabled = ready, .placement = .footer, .tag = fmt("resource-project-{s}", .{project.id}) })) ui.queue(.{ .project = project });
        }
        {
            const details = plain(@src(), .vertical, .{});
            defer details.deinit();
            dvui.labelNoFmt(@src(), components.ellipsize(project.name, theme.headingFont(), details.data().contentRect().w), .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .font = theme.headingFont(), .padding = .all(0), .margin = .{ .h = 8 }, .color_text = .{ .color = theme.colors.foreground } });
            components.hint(@src(), project.summary);
            installedLabel(snapshot, entries, project.provider, project.id);
        }
        if (narrow and components.button(@src(), "查看详情", .{ .enabled = ready, .tag = fmt("resource-project-{s}", .{project.id}) })) ui.queue(.{ .project = project });
    }
}
fn fixedText(src: std.builtin.SourceLocation, value: []const u8, font: dvui.Font, rect: dvui.Rect, color: dvui.Color) void {
    dvui.labelNoFmt(src, components.ellipsize(value, font, @max(0, rect.w)), .{}, .{ .rect = rect, .font = font, .padding = .all(0), .margin = .all(0), .background = false, .color_text = .{ .color = color } });
}
fn loaderTitle(loader: anytype) []const u8 {
    return switch (loader) {
        .fabric => "Fabric Loader",
        .forge => "Forge",
        .neoforge => "NeoForge",
        .quilt => "Quilt Loader",
        else => "原版",
    };
}
fn platformRow(src: std.builtin.SourceLocation, name: []const u8, version: []const u8, compatible: bool) void {
    dependencySeparator(src, 0);
    const row = plain(src, .vertical, .{ .id_extra = 1, .expand = .horizontal, .min_size_content = .height(64) });
    defer row.deinit();
    const width = row.data().contentRect().w;
    const left = @min(260, width * 0.48);
    fixedText(@src(), name, theme.headingFont(), .{ .w = left, .h = 28 }, theme.colors.foreground);
    fixedText(@src(), fmt("当前实例 {s}", .{version}), theme.fontSized(14), .{ .y = 28, .w = left, .h = 24 }, theme.colors.muted);
    fixedText(@src(), if (compatible) "所选发布版支持" else "兼容信息未提供", theme.fontSized(14), .{ .x = left + 24, .y = 28, .w = @max(0, width - left - 24), .h = 24 }, if (compatible) theme.colors.accent else theme.colors.muted);
}
fn drawDetail(ui: *state.Ui, snapshot: content.Snapshot, ready: bool, entries: []const local.Entry) void {
    const detail = ui.frame() orelse return;
    {
        const area = footer();
        defer area.deinit();
        const compact = dvui.parentGet().data().contentRect().w < 560;
        if (compact) resourceLinks(ui, detail.project);
        const actions = plain(@src(), .horizontal, .{});
        defer actions.deinit();
        backButton(ui);
        if (!compact) resourceLinks(ui, detail.project);
        const installed = state.installed(snapshot, detail.project.provider, detail.project.id);
        const label = if (installed != null) "安装 / 更新" else "安装";
        if (ui.failure != null and components.button(@src(), "重试", .{ .standalone = true, .enabled = ready, .tag = "resource-detail-retry" })) ui.queue(.retry);
        if (components.button(@src(), if (ui.job == .prepare) "检查中…" else label, .{ .standalone = true, .enabled = ready and detail.version() != null and ui.currentProposal(snapshot), .primary = true, .placement = .footer, .gravity_x = 1, .min_width = 144, .tag = "resource-install" })) ui.queue(.confirm);
    }
    const scroll = rememberedScroll(@src(), &detail.scroll);
    defer scroll.deinit();
    const panel = components.bentoPanel(@src(), .{ .expand = .horizontal, .min_size_content = .height(@max(0, scroll.data().contentRect().h - 56)), .max_size_content = .width(0), .padding = .all(23), .margin = .all(0), .corners = .all(theme.panelRadius()) });
    defer panel.deinit();
    {
        const heading = plain(@src(), .vertical, .{ .expand = .horizontal, .min_size_content = .height(64), .max_size_content = .height(64), .margin = .{ .h = 32 } });
        defer heading.deinit();
        const width = heading.data().contentRect().w;
        const bitmap = if (ui.icons) |*cache| cache.get(detail.project.icon_url) else null;
        @import("resource_icons.zig").draw(@src(), bitmap, 64, .{ .w = 64, .h = 64 });
        if (ui.icons) |*cache| if (cache.busy()) dvui.refresh(null, @src(), null);
        const receipt = state.installed(snapshot, detail.project.provider, detail.project.id);
        fixedText(@src(), detail.project.name, theme.fontSized(24), .{ .x = 88, .w = @max(0, width - 88 - (if (receipt != null and width > 620) @as(f32, 256) else 0)), .h = 36 }, theme.colors.foreground);
        fixedText(@src(), detail.project.summary, theme.bodyFont(), .{ .x = 88, .y = 40, .w = @max(0, width - 88), .h = 24 }, theme.colors.muted);
        if (receipt) |file| {
            const version = state.installedVersion(snapshot, file, entries);
            const text = fmt("已安装{s}{s}", .{ if (version) |name| fmt(" {s}", .{name}) else "", if (file.enabled) "" else " · 已禁用" });
            if (width > 620) fixedText(@src(), text, theme.fontSized(14), .{ .x = width - 240, .w = 240, .h = 24 }, if (file.enabled) theme.colors.accent else theme.colors.warning);
        }
    }
    {
        const line = plain(@src(), .horizontal, .{ .min_size_content = .height(24), .margin = .{ .h = 4 } });
        defer line.deinit();
        dvui.labelNoFmt(@src(), "选择版本", .{}, .{ .font = theme.fontSized(14), .min_size_content = .{ .w = 176, .h = 24 }, .padding = .all(0), .margin = .{ .w = 40 }, .color_text = .{ .color = theme.colors.foreground } });
        if (line.data().contentRect().w > 620) if (ui.instance) |instance| {
            dvui.labelNoFmt(@src(), "兼容条件", .{}, .{ .font = theme.fontSized(14), .padding = .all(0), .margin = .{ .w = 16 }, .color_text = .{ .color = theme.colors.foreground } });
            dvui.labelNoFmt(@src(), fmt("Minecraft {s} · {s}", .{ instance.minecraft_version, loaderTitle(instance.loader) }), .{}, .{ .font = theme.fontSized(14), .padding = .all(0), .margin = .all(0), .color_text = .{ .color = theme.colors.muted } });
        };
    }
    if (detail.versions.len == 0) {
        const version_slot = plain(@src(), .horizontal, .{ .expand = .horizontal, .min_size_content = .height(theme.sizing.control_height), .max_size_content = .height(theme.sizing.control_height) });
        defer version_slot.deinit();
        pendingVersion(@src(), version_slot.data().contentRect().w, if (ui.job != .idle) "正在加载版本…" else if (ui.failure != null) "版本加载失败" else "没有适用于当前实例的版本");
        return;
    }
    const names = dvui.currentWindow().arena().alloc([]const u8, detail.versions.len) catch {
        ui.failure = error.OutOfMemory;
        return;
    };
    for (detail.versions, names) |version, *name| name.* = version.name;
    var choice = detail.selected;
    _ = components.dropdown(@src(), "安装版本", names, .{ .choice = &choice }, .{}, .{ .tag = "resource-version", .expand = .horizontal, .max_size_content = .width(0), .margin = .all(0) });
    if (choice != detail.selected and ready) ui.queue(.{ .version = choice });
    _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .y = 24, .h = 23 }, .color_border = .{ .color = theme.colors.outline } });
    {
        const header = plain(@src(), .horizontal, .{ .min_size_content = .height(32), .margin = .{ .h = 24 } });
        defer header.deinit();
        dvui.labelNoFmt(@src(), "依赖", .{}, .{ .font = theme.headingFont(), .padding = .all(0), .margin = .{ .w = 64 }, .color_text = .{ .color = theme.colors.foreground } });
        dvui.labelNoFmt(@src(), if (ui.failure) |err| failureMessage(err) else "按所选版本识别", .{}, .{ .font = theme.fontSized(14), .gravity_y = 0.5, .padding = .all(0), .margin = .all(0), .color_text = .{ .color = if (ui.failure != null) theme.colors.danger else theme.colors.muted } });
    }
    const version = detail.version().?;
    if (version.dependencies.len == 0) components.hint(@src(), "此版本没有声明依赖");
    for (version.dependencies, 0..) |dep, i| {
        if (i > 0) dependencySeparator(@src(), i);
        drawDependency(ui, snapshot, detail, version, dep, i, ready, entries);
    }
    if (ui.instance) |instance| {
        var game_supported = false;
        for (version.minecraft_versions) |game| if (std.mem.eql(u8, game, instance.minecraft_version)) {
            game_supported = true;
            break;
        };
        var loader_supported = false;
        for (version.loaders) |loader| if (std.mem.eql(u8, loader, @tagName(instance.loader))) {
            loader_supported = true;
            break;
        };
        platformRow(@src(), "Minecraft", instance.minecraft_version, game_supported);
        if (instance.loader != .vanilla) platformRow(@src(), loaderTitle(instance.loader), instance.loader_version orelse "版本未知", loader_supported);
    }
}
fn pendingVersion(src: std.builtin.SourceLocation, width: f32, message: []const u8) void {
    const placeholder = plain(src, .horizontal, .{ .expand = .none, .rect = .{ .w = width, .h = theme.sizing.control_height }, .padding = .{ .x = 12, .w = 12 }, .border = .all(theme.sizing.control_border), .corners = .all(theme.controlRadius()), .background = true, .color_fill = .{ .color = theme.colors.surface }, .color_border = .{ .color = theme.colors.outline } });
    defer placeholder.deinit();
    dvui.labelNoFmt(@src(), message, .{}, .{ .font = theme.bodyFont(), .gravity_y = 0.5, .padding = .all(0), .margin = .all(0), .color_text = .{ .color = theme.colors.muted } });
}
fn dependencySeparator(src: std.builtin.SourceLocation, index: usize) void {
    _ = dvui.separator(src, .{ .id_extra = index, .expand = .horizontal, .margin = .{ .y = theme.spacing.action_gap, .h = theme.spacing.action_gap }, .color_border = .{ .color = theme.colors.outline } });
}
fn dependencyDisplayName(ui: *const state.Ui, dep: providers.Dependency, versions: []const providers.Version, provider: providers.Provider) []const u8 {
    const project_id: ?[]const u8 = if (versions.len > 0) versions[0].project_id else dep.project_id;
    if (project_id) |id| for (ui.catalog) |project| {
        if (project.provider == provider and std.mem.eql(u8, project.id, id)) return project.name;
    };
    if (versions.len > 0) return state.dependencyName(versions[0]);
    if (dep.file_name) |name| return name;
    if (ui.failure != null) return "依赖名称加载失败";
    return if (ui.job != .idle or !ui.proposal_current) "正在加载依赖…" else "未知依赖";
}
fn dependencyInclude(src: std.builtin.SourceLocation, value: *bool, ready: bool, index: usize) bool {
    const slot = plain(src, .horizontal, .{ .expand = .none, .rect = .{ .w = 104, .h = theme.sizing.control_height }, .border = .all(theme.sizing.control_border), .corners = .all(theme.controlRadius()), .background = true, .color_fill = .{ .color = theme.colors.surface }, .color_border = .{ .color = if (value.*) theme.colors.accent else theme.colors.control_outline } });
    defer slot.deinit();
    const opts = components.checkboxOptions("包含", .{ .tag = fmt("resource-dep-include-{d}", .{index}) }).override(.{ .expand = .none, .rect = .{ .w = 102, .h = 46 }, .min_size_content = .height(0), .max_size_content = .width(102), .margin = .all(0), .padding = .{ .x = 11, .w = 11 }, .border = .all(0), .corners = .all(4), .background = false });
    const checkbox_src = @src();
    if (ready) return dvui.checkbox(checkbox_src, value, "包含", opts);
    const row = dvui.box(checkbox_src, .{ .dir = .horizontal }, opts.override(.{ .tab_index = 0, .color_text = .{ .color = theme.colors.muted } }));
    defer row.deinit();
    // Keep only the current focus target registered while its metadata refreshes.
    if (dvui.focusedWidgetId() == row.data().id) dvui.tabIndexSet(row.data().id, 1, row.data().rectScale().r);
    if (row.data().accesskit_node()) |node| {
        dvui.AccessKit.nodeSetDisabled(node);
        dvui.AccessKit.nodeSetToggled(node, if (value.*) .ak_true else .ak_false);
    }
    const mark = dvui.spacer(@src(), .{ .min_size_content = dvui.Size.all(opts.fontGet().textHeight()), .gravity_y = 0.5 });
    if (row.data().visible()) dvui.checkmark(value.*, false, mark.borderRectScale(), false, 0, opts);
    _ = dvui.spacer(@src(), .{ .min_size_content = .width(dvui.checkbox_defaults.paddingGet().w) });
    dvui.labelNoFmt(@src(), "包含", .{}, opts.strip().override(.{ .gravity_y = 0.5, .color_text = .{ .color = theme.colors.muted } }));
    return false;
}
fn drawDependency(ui: *state.Ui, snapshot: content.Snapshot, detail: *state.Detail, root: providers.Version, dep: providers.Dependency, index: usize, ready: bool, entries: []const local.Entry) void {
    const values = dvui.currentWindow().arena().alloc(providers.Version, detail.candidates.len) catch {
        ui.failure = error.OutOfMemory;
        return;
    };
    var count: usize = 0;
    for (detail.candidates) |candidate| if (state.matchesDependency(candidate, root, dep)) {
        values[count] = candidate;
        count += 1;
    };
    const versions = values[0..count];
    const choice = detail.choice(index);
    const selected_id = if (choice) |value| value.version_id else null;
    const row_width = dvui.parentGet().data().contentRect().w;
    const optional = dep.kind == .optional;
    const narrow = row_width < 680;
    const can_choose = versions.len > 0 or dep.kind == .required or optional;
    const group_width = if (can_choose) @min(row_width, @as(f32, if (optional) 410 else 294)) else 0;
    const stack_include = optional and group_width < 410;
    const controls_height: f32 = if (!can_choose) 0 else if (stack_include) 108 else 48;
    const row_height = if (narrow) 64 + controls_height else 64;
    const row = plain(@src(), .vertical, .{ .id_extra = index, .min_size_content = .height(row_height), .max_size_content = .{ .w = 0, .h = row_height } });
    defer row.deinit();
    {
        const description = plain(@src(), .vertical, .{ .expand = .none, .rect = .{ .w = if (narrow or !can_choose) row_width else @max(0, row_width - group_width - 16), .h = 64 } });
        defer description.deinit();
        const width = description.data().contentRect().w;
        const left = @min(260, width * 0.48);
        const name = dependencyDisplayName(ui, dep, versions, root.provider);
        fixedText(@src(), name, theme.headingFont(), .{ .w = width, .h = 28 }, theme.colors.foreground);
        fixedText(@src(), switch (dep.kind) {
            .required => "必需依赖",
            .optional => "可选依赖",
            .incompatible => "不兼容资源",
            .embedded => "已内置",
        }, theme.fontSized(14), .{ .y = 28, .w = left, .h = 24 }, theme.colors.muted);
        if (versions.len > 0) {
            const receipt = state.installed(snapshot, root.provider, versions[0].project_id);
            const label = if (receipt) |file| block: {
                const version = state.installedVersion(snapshot, file, entries);
                break :block fmt("已安装{s}{s}", .{ if (version) |value| fmt(" {s}", .{value}) else "", if (file.enabled) "" else " · 已禁用" });
            } else if (dep.kind == .required or (if (choice) |value| value.include else false)) "缺失 · 自动补齐" else "未包含";
            fixedText(@src(), label, theme.fontSized(14), .{ .x = left + 16, .y = 28, .w = @max(0, width - left - 16), .h = 24 }, if (receipt != null and !receipt.?.enabled) theme.colors.warning else theme.colors.accent);
        }
    }
    if (!can_choose) return;
    const controls = plain(@src(), .vertical, .{ .expand = .none, .rect = .{ .x = row_width - group_width, .y = if (narrow) 64 else 8, .w = group_width, .h = controls_height } });
    defer controls.deinit();
    if (optional) {
        var include = if (choice) |value| value.include else false;
        if (dependencyInclude(@src(), &include, ready, index)) ui.queue(.{ .choice = .{ .dependency_index = index, .version_id = selected_id, .include = include } });
    }
    const control_width = @min(@as(f32, 294), group_width);
    const version_controls = plain(@src(), .horizontal, .{ .expand = .none, .rect = .{ .x = group_width - control_width, .y = if (stack_include) 60 else 0, .w = control_width, .h = 48 } });
    defer version_controls.deinit();
    if (versions.len > 0) {
        const names = dvui.currentWindow().arena().alloc([]const u8, versions.len) catch {
            ui.failure = error.OutOfMemory;
            return;
        };
        var selected: usize = 0;
        for (versions, 0..) |version, i| {
            names[i] = version.name;
            if (selected_id) |id| if (std.mem.eql(u8, id, version.id)) {
                selected = i;
            };
        }
        const previous = selected;
        _ = components.dropdown(@src(), "依赖版本", names, .{ .choice = &selected }, .{}, .{ .tag = fmt("resource-dep-version-{d}", .{index}), .expand = .none, .max_size_content = .width(@max(0, control_width - 56)), .rect = .{ .w = @max(0, control_width - 56), .h = 48 }, .margin = .all(0) });
        if (previous != selected and ready) ui.queue(.{ .choice = .{ .dependency_index = index, .version_id = versions[selected].id, .include = if (dep.kind == .required) true else if (choice) |value| value.include else false } });
    } else {
        const loading = ui.failure == null and (ui.job != .idle or !ui.proposal_current);
        pendingVersion(@src(), @max(0, control_width - 56), if (loading) "正在加载版本…" else "未找到兼容版本");
    }
    if (components.iconButton(@src(), "查看依赖详情", dvui.entypo.chevron_small_right, .{ .enabled = ready and versions.len > 0, .selected = true, .rect = .{ .x = control_width - 48, .w = 48, .h = 48 }, .tag = fmt("resource-dep-detail-{d}", .{index}) })) ui.queue(.{ .dependency = index });
}
fn openPage(ui: *state.Ui, url: []const u8) void {
    if (!providers.safeHttpsUrl(url)) {
        ui.failure = error.InvalidOfficialPage;
        return;
    }
    if (!dvui.openURL(.{ .url = url })) ui.failure = error.HomepageOpenFailed;
}
fn resourceLinks(ui: *state.Ui, project: providers.Project) void {
    if (!@import("resource_links.zig").draw(project.name, project.official_page, project.provider, "resource")) ui.failure = error.HomepageOpenFailed;
}
fn projectIcon(ui: *state.Ui, project: providers.Project, size: f32) void {
    const bitmap = if (ui.icons) |*cache| cache.get(project.icon_url) else null;
    @import("resource_icons.zig").draw(@src(), bitmap, size, null);
    if (ui.icons) |*cache| if (cache.busy()) dvui.refresh(null, @src(), null);
}
fn backButton(ui: *state.Ui) void {
    backButtonAt(ui, null);
}
fn backButtonAt(ui: *state.Ui, rect: ?dvui.Rect) void {
    if (components.button(@src(), "返回", .{ .standalone = true, .enabled = !ui.confirm_open and ui.task_state == .none and ui.job != .install and ui.job != .recover, .min_width = footer_button_width, .placement = if (rect != null) .footer else .inline_action, .rect = rect, .tag = "resource-download-back" })) ui.queue(.back);
}
fn pagination(ui: *state.Ui, ready: bool) void {
    if (components.button(@src(), "上一页", .{ .standalone = true, .enabled = ready and ui.offset >= 40, .min_width = footer_button_width, .placement = .footer, .rect = .{ .x = footer_button_step, .w = footer_button_width, .h = theme.sizing.control_height }, .tag = "resource-previous" })) ui.queue(.{ .page = ui.offset - 40 });
    if (components.button(@src(), "下一页", .{ .standalone = true, .enabled = ready and ui.catalog.len == 40 and ui.offset < std.math.maxInt(u32) - 40, .min_width = footer_button_width, .placement = .footer, .rect = .{ .x = 2 * footer_button_step, .w = footer_button_width, .h = theme.sizing.control_height }, .tag = "resource-next" })) ui.queue(.{ .page = ui.offset + 40 });
}
fn proposalBelongs(ui: *state.Ui, proposal: *const content.Proposal) bool {
    return ui.currentProposal(.{ .proposal = proposal });
}
pub fn drawDialogs(ui: *state.Ui, snapshot: content.Snapshot, allowed: bool) void {
    if (ui.task_state != .none) {
        drawTask(ui, snapshot, allowed);
        return;
    }
    if (!ui.confirm_open) return;
    const modal = components.modal(@src(), "安装确认", 600);
    defer modal.deinit();
    const proposal = snapshot.proposal;
    const ready = enabled(ui, snapshot, allowed) and ui.picker_ticket == null;
    {
        const area = footer();
        defer area.deinit();
        const actions = plain(@src(), .horizontal, .{});
        defer actions.deinit();
        if (components.button(@src(), "取消", .{ .enabled = ready, .tag = "resource-confirm-cancel" })) ui.queue(.dismiss);
        const valid = if (proposal) |value| proposalBelongs(ui, value) else false;
        const can_commit = valid and proposal.?.ready;
        if (can_commit) {
            if (components.button(@src(), "确认安装", .{ .enabled = ready, .primary = true, .gravity_x = 1, .min_width = 144, .tag = "resource-confirm-install" })) ui.queue(.commit);
        } else {
            const path = if (proposal) |value| firstManual(value) else null;
            if (components.button(@src(), if (path != null) "选择文件" else "确认安装", .{ .enabled = ready and path != null, .primary = path != null, .gravity_x = 1, .min_width = 144, .tag = "resource-confirm-files" })) ui.queue(.{ .choose_manual = path.? });
        }
    }
    const scroll = components.scrollBody(@src());
    defer scroll.deinit();
    errorHint(ui);
    if (proposal) |value| {
        if (!proposalBelongs(ui, value)) {
            components.hint(@src(), "安装方案已失效，请返回详情重试。");
            return;
        }
        if (ui.frame()) |detail| {
            components.section(@src(), detail.project.name);
            if (detail.version()) |version| components.hint(@src(), version.name);
        }
        if (ui.instance) |instance| components.hint(@src(), fmt("安装到：{s}", .{instance.name}));
        if (value.blocker) |err| components.text(@src(), failureMessage(err), theme.colors.warning);
        if (!value.dependencies_ready) components.hint(@src(), "请返回详情选择依赖的兼容版本，或启用已有的必需依赖。");
        components.section(@src(), "安装内容与依赖");
        for (value.files, 0..) |file, i| {
            if (file.selected == false) continue;
            const row = components.bentoPanel(@src(), .{ .id_extra = i, .expand = .horizontal, .max_size_content = .width(0), .padding = .all(15), .margin = .{ .h = 8 } });
            defer row.deinit();
            components.text(@src(), std.fs.path.basename(file.record.path), theme.colors.foreground);
            const previous = state.installed(snapshot, file.record.provider, file.record.project_id);
            components.hint(@src(), if (previous) |old| if (std.mem.eql(u8, old.version_id, file.record.version_id)) (if (old.enabled) "版本相同，保留已有文件" else "已有版本被禁用") else "将更新已有版本" else if (value.root != null and !std.mem.eql(u8, value.root.?.id, file.record.version_id)) "自动补齐依赖" else "将安装此版本");
            if (file.download == .manual_required) {
                const status = for (value.manual_source_status) |mapping| {
                    if (std.mem.eql(u8, mapping.path, file.record.path)) break mapping;
                } else null;
                if (status) |mapping| {
                    if (mapping.verified) components.text(@src(), "文件已匹配", theme.colors.accent) else if (mapping.source_absolute_path != null) components.text(@src(), "文件不匹配，请重新选择", theme.colors.danger) else components.hint(@src(), "需要手动下载并选择文件");
                }
                const actions = plain(@src(), .horizontal, .{});
                defer actions.deinit();
                if (components.button(@src(), "手动下载", .{ .enabled = ready, .tag = fmt("resource-manual-web-{d}", .{i}) })) openPage(ui, file.download.manual_required.official_page);
                if (components.button(@src(), if (status != null and status.?.source_absolute_path != null) "重新选择" else "选择文件", .{ .enabled = ready, .gravity_x = 1, .tag = fmt("resource-manual-file-{d}", .{i}) })) ui.queue(.{ .choose_manual = file.record.path });
            }
        }
        for (value.plan.conflicts, 0..) |conflict, i| {
            const row = plain(@src(), .vertical, .{ .id_extra = i, .margin = .{ .h = 8 } });
            defer row.deinit();
            components.text(@src(), fmt("文件冲突：{s}", .{conflict.path}), theme.colors.warning);
            const actions = plain(@src(), .horizontal, .{});
            defer actions.deinit();
            if (components.button(@src(), "保留本地", .{ .enabled = ready, .tag = fmt("resource-keep-{d}", .{i}) })) ui.queue(.{ .conflict = .{ .path = conflict.path, .choice = .keep_local } });
            if (components.button(@src(), "备份并替换", .{ .enabled = ready, .tag = fmt("resource-replace-{d}", .{i}) })) ui.queue(.{ .conflict = .{ .path = conflict.path, .choice = .replace } });
        }
    } else components.hint(@src(), "没有可用的安装方案，请返回详情重试。");
}
fn firstManual(proposal: *const content.Proposal) ?[]const u8 {
    for (proposal.files) |file| {
        if (file.download != .manual_required or file.selected == false) continue;
        const verified = for (proposal.manual_source_status) |status| {
            if (std.mem.eql(u8, status.path, file.record.path)) break status.verified;
        } else false;
        if (!verified) return file.record.path;
    }
    return null;
}
fn drawTask(ui: *state.Ui, snapshot: content.Snapshot, allowed: bool) void {
    @import("resource_task_view.zig").draw(ui, snapshot, allowed, failureMessage);
}

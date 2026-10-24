//! Owned theme draft: live window appearance with explicit persistence.
const std = @import("std");
const dvui = @import("dvui");
const appearance = @import("../core/appearance.zig");
const config = @import("../core/config.zig");
const model = @import("model.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const file_picker = @import("file_picker.zig");
const background = @import("background_image.zig");
const A = std.mem.Allocator;
const R = dvui.Rect;
const Command = enum { apply, cancel, defaults, choose_image, remove_image, reload, save_navigation, discard_navigation, cancel_navigation, retry_image };

pub const Ui = struct {
    a: A,
    io: std.Io,
    allow_mutations: bool = true,
    picker: ?*file_picker.Service = null,
    ticket: ?file_picker.Ticket = null,
    draft: appearance.Settings,
    baseline: appearance.Settings,
    hex: [32]u8 = @splat(0),
    hex_valid: bool = true,
    preview_image: background.Cache,
    applied_image: background.Cache,
    frame_images: [2]?*background.Image = .{ null, null },
    pending: ?Command = null,
    failure: ?anyerror = null,
    saved: bool = false,
    drawn: bool = false,
    active: bool = false,
    navigation: ?model.Msg = null,
    resume_navigation: ?model.Msg = null,
    close_requested: bool = false,
    resume_close: bool = false,

    pub fn init(a: A, io: std.Io, initial: appearance.Settings) !Ui {
        try appearance.validate(initial);
        const draft = try ownSettings(a, initial);
        errdefer freeSettings(a, draft);
        const baseline = try ownSettings(a, initial);
        var ui: Ui = .{ .a = a, .io = io, .draft = draft, .baseline = baseline, .preview_image = .init(io), .applied_image = .init(io) };
        ui.syncHex();
        return ui;
    }
    pub fn deinit(self: *Ui) void {
        self.releaseFrameImages();
        self.discardPicker();
        self.preview_image.deinit();
        self.applied_image.deinit();
        freeSettings(self.a, self.draft);
        freeSettings(self.a, self.baseline);
        self.* = undefined;
    }
    fn releaseFrameImages(self: *Ui) void {
        for (&self.frame_images) |*image| {
            if (image.*) |retained| retained.release();
            image.* = null;
        }
    }
    pub fn dirty(self: *const Ui) bool {
        return !self.hex_valid or !settingsEqual(self.draft, self.baseline);
    }
    fn syncHex(self: *Ui) void {
        @memset(&self.hex, 0);
        _ = std.fmt.bufPrint(&self.hex, "#{X:0>6}", .{self.draft.background_color}) catch unreachable;
        self.hex_valid = true;
    }
    fn edited(self: *Ui) void {
        self.failure = null;
        self.saved = false;
        if (dvui.current_window != null) dvui.refresh(null, @src(), null);
    }
    fn discardPicker(self: *Ui) void {
        if (self.ticket) |ticket| if (self.picker) |picker| picker.discard(ticket);
        self.ticket = null;
    }
    fn replaceDraft(self: *Ui, settings: appearance.Settings) !void {
        const next = try ownSettings(self.a, settings);
        errdefer freeSettings(self.a, next);
        try self.preview_image.request(next.image_path);
        freeSettings(self.a, self.draft);
        self.draft = next;
        self.syncHex();
        self.discardPicker();
        self.edited();
    }
    fn setPath(self: *Ui, path: ?[]const u8) !void {
        const next = if (path) |p| try self.a.dupe(u8, p) else null;
        errdefer if (next) |p| self.a.free(p);
        try self.preview_image.request(next);
        if (background.samePath(self.draft.image_path, path)) self.preview_image.retry();
        if (self.draft.image_path) |old| self.a.free(old);
        self.draft.image_path = next;
        self.edited();
    }
    fn canApply(self: *const Ui, store: *config.Store) bool {
        if (!self.allow_mutations or store.publicationUncertain() or !self.hex_valid or self.ticket != null) return false;
        appearance.validate(self.draft) catch return false;
        return self.draft.background_mode != .image or self.preview_image.ready();
    }
};

fn ownSettings(a: A, settings: appearance.Settings) !appearance.Settings {
    var result = settings;
    if (settings.image_path) |path| result.image_path = try a.dupe(u8, path);
    return result;
}
fn freeSettings(a: A, settings: appearance.Settings) void {
    if (settings.image_path) |path| a.free(path);
}
fn settingsEqual(a: appearance.Settings, b: appearance.Settings) bool {
    return a.preset == b.preset and a.background_mode == b.background_mode and a.background_color == b.background_color and background.samePath(a.image_path, b.image_path) and a.image_layout == b.image_layout and a.image_blur == b.image_blur and a.image_dimming == b.image_dimming and a.corner_radius == b.corner_radius and a.panel_opacity == b.panel_opacity and a.panel_blur == b.panel_blur;
}

/// The draft affects the whole window while the editor is active, without publishing it.
pub fn visibleSettings(ui: *const Ui, store: *config.Store) appearance.Settings {
    return if (ui.active or ui.drawn) ui.draft else store.snapshot().appearance;
}

/// Call every frame, including while other pages are visible. No borrowed snapshot survives.
pub fn beginFrame(ui: *Ui, store: *config.Store) void {
    ui.releaseFrameImages();
    ui.active = ui.drawn;
    ui.drawn = false;
    if (ui.ticket) |ticket| if (ui.picker) |picker| if (picker.take(ticket)) |result_value| {
        var result = result_value;
        defer result.deinit();
        ui.ticket = null;
        if (result.failure) |err| {
            ui.failure = err;
        } else if (result.path) |path| {
            ui.setPath(path) catch |err| {
                ui.failure = err;
            };
        }
    };
    const applied = store.snapshot().appearance;
    if (!settingsEqual(applied, ui.baseline)) {
        const was_dirty = ui.dirty();
        const next = ownSettings(ui.a, applied) catch |err| {
            ui.failure = err;
            return;
        };
        freeSettings(ui.a, ui.baseline);
        ui.baseline = next;
        if (!was_dirty) ui.replaceDraft(applied) catch |err| {
            ui.failure = err;
        };
    }
    ui.preview_image.request(ui.draft.image_path) catch |err| {
        ui.failure = err;
    };
    ui.applied_image.request(applied.image_path) catch |err| {
        ui.failure = err;
    };
    ui.preview_image.poll();
    ui.applied_image.poll();
    // DVUI queues image uploads until Window.end. Preserve every drawn pixel buffer
    // through that boundary, even when save/cancel replaces a cache after drawing.
    ui.frame_images = .{ if (ui.preview_image.image) |image| image.retain() else null, if (ui.applied_image.image) |image| image.retain() else null };
    // Worker completion has no SDL dependency; keep polling while work is outstanding.
    if (ui.preview_image.job != null or ui.applied_image.job != null or ui.ticket != null) dvui.refresh(null, @src(), null);
}

pub fn drawBackground(ui: *Ui, store: *config.Store, bounds: R) void {
    const settings = visibleSettings(ui, store);
    const image = if (settings.image_path == null) null else if (ui.active or ui.drawn) ui.preview_image.image orelse ui.applied_image.image else ui.applied_image.image;
    const screen = dvui.parentGet().screenRectScale(bounds);
    theme.setPanelBackdrop(image, settings, screen);
    screen.r.fill(.{}, .{ .color = .{ .color = background.rgb(settings.background_color) } });
    if (settings.background_mode == .image) if (image) |artwork| background.draw(artwork, settings, screen);
}

fn imageName(path: []const u8) []const u8 {
    const name = std.fs.path.basename(path);
    const directory = std.fs.path.dirname(path) orelse return name;
    const parent = std.fs.path.dirname(directory) orelse return name;
    return if (std.mem.eql(u8, std.fs.path.basename(directory), "backgrounds") and std.mem.eql(u8, std.fs.path.basename(parent), ".vela")) "已保存的背景图片" else name;
}

pub fn draw(ui: *Ui, store: *config.Store) !void {
    ui.drawn = true;
    const page = dvui.box(@src(), .{}, .{ .expand = .both, .padding = .all(0), .margin = .all(0) });
    defer page.deinit();
    components.title(@src(), "主题");
    components.hint(@src(), "修改实时显示，点击保存后保留设置。");
    if (store.publicationUncertain()) {
        components.text(@src(), "保存结果尚未确认。重新加载已保存配置后可继续保存；当前草稿会保留。", theme.colors.warning);
        if (components.button(@src(), "重新加载已保存配置", .{ .standalone = true, .tag = "theme-reload" })) ui.pending = .reload;
    }
    if (ui.failure) |err| drawFailure(err);
    if (ui.saved) components.text(@src(), "主题已保存", theme.colors.accent);
    _ = dvui.spacer(@src(), .{ .min_size_content = .height(24) });
    drawFooter(ui, store);
    const scroll = components.scrollBody(@src());
    defer scroll.deinit();
    const width = dvui.parentGet().data().contentRect().w;
    const wide = width >= 840;
    const columns = dvui.box(@src(), .{ .dir = if (wide) .horizontal else .vertical }, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = .all(0), .margin = .all(0) });
    defer columns.deinit();
    {
        const left_width = @max(0, (width - 16) * 0.61832);
        const left = dvui.box(@src(), .{}, .{ .expand = if (wide) .none else .horizontal, .min_size_content = .width(if (wide) left_width else 0), .max_size_content = .width(if (wide) left_width else 0), .padding = .all(0), .margin = if (wide) .{ .w = 16 } else .all(0) });
        defer left.deinit();
        drawPresets(ui);
        drawBackgroundControls(ui);
    }
    {
        const right = dvui.box(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = .all(0), .margin = .all(0) });
        defer right.deinit();
        drawDetails(ui);
    }
}

fn drawFooter(ui: *Ui, store: *config.Store) void {
    const keyboard = dvui.tabIndexGroup(@src(), .{ .tab_index = 65000 });
    defer keyboard.deinit();
    const width = dvui.parentGet().data().contentRect().w;
    const compact = width < 440;
    const footer = dvui.box(@src(), .{ .dir = if (compact) .vertical else .horizontal }, .{ .expand = .horizontal, .gravity_y = 1, .min_size_content = .height(if (compact) 108 else 48), .padding = .all(0), .margin = .{ .y = 16 } });
    defer footer.deinit();
    if (components.button(@src(), "恢复默认", .{ .tag = "theme-defaults", .placement = .footer, .standalone = true, .min_width = 0 })) ui.pending = .defaults;
    const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_x = 1, .padding = .all(0), .margin = .{ .y = if (compact) 12 else 0 } });
    defer actions.deinit();
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    const button_width = @max(0, @min(144, (actions.data().contentRect().w - 12) / 2));
    if (components.button(@src(), "取消", .{ .tag = "theme-cancel", .placement = .footer, .standalone = true, .min_width = button_width })) ui.pending = .cancel;
    _ = dvui.spacer(@src(), .{ .min_size_content = .width(12) });
    if (components.button(@src(), "保存主题", .{ .tag = "theme-apply", .primary = true, .enabled = ui.dirty() and ui.canApply(store), .placement = .footer, .standalone = true, .min_width = button_width })) ui.pending = .apply;
}

fn drawPresets(ui: *Ui) void {
    const panel = components.formPanel(@src(), .{ .tag = "theme-presets" });
    defer panel.deinit();
    panelTitle(@src(), "预制配色");
    const available = panel.data().contentRect().w;
    const count: usize = if (available >= 440) 3 else if (available >= 260) 2 else 1;
    const cell_width = @max(0, (available - 12 * @as(f32, @floatFromInt(count - 1))) / @as(f32, @floatFromInt(count)));
    const values = [_]appearance.Preset{ .moss, .mist, .graphite, .sunset, .violet, .frost };
    var row_index: usize = 0;
    while (row_index < values.len) : (row_index += count) {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = row_index, .expand = .horizontal, .padding = .all(0), .margin = .{ .h = if (row_index + count < values.len) 12 else 0 } });
        defer row.deinit();
        for (row_index..@min(row_index + count, values.len)) |index| {
            const preset = values[index];
            const palette = appearance.palette(preset);
            const selected = ui.draft.preset == preset;
            var control: dvui.ButtonWidget = undefined;
            control.init(@src(), .{}, .{ .id_extra = index, .label = .{ .text = appearance.presetName(preset) }, .min_size_content = .{ .w = @max(0, cell_width - 26), .h = 24 }, .max_size_content = .width(@max(0, cell_width - 26)), .padding = .{ .x = 12, .w = 12, .y = 11, .h = 11 }, .margin = .{ .w = if (index + 1 < @min(row_index + count, values.len)) 12 else 0 }, .border = .all(1), .corners = .all(theme.controlRadius()), .background = true, .color_fill = .{ .color = if (selected) theme.colors.selected_surface else theme.colors.surface }, .color_border = .{ .color = if (selected) theme.colors.accent else theme.colors.outline } });
            defer control.deinit();
            if (control.data().accesskit_node()) |node| dvui.AccessKit.nodeSetSelected(node, selected);
            control.processEvents();
            theme.surface.buttonBackground(&control);
            {
                const content = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .min_size_content = .height(24), .padding = .all(0), .margin = .all(0) });
                defer content.deinit();
                for ([_]u32{ palette.background, palette.surface, palette.accent }, 0..) |color, color_index| {
                    const swatch = dvui.box(@src(), .{}, .{ .id_extra = color_index, .min_size_content = .{ .w = 6, .h = 24 }, .padding = .all(0), .margin = .{ .w = if (color_index == 2) 10 else 0 }, .background = true, .color_fill = .{ .color = background.rgb(color) }, .corners = .all(3) });
                    swatch.deinit();
                }
                dvui.labelNoFmt(@src(), appearance.presetName(preset), .{}, .{ .font = theme.bodyFont(), .padding = .all(0), .margin = .all(0), .gravity_y = 0.5, .role = .none, .tab_index = 0 });
                if (selected) dvui.icon(@src(), "已选中", dvui.entypo.check, .{}, .{ .min_size_content = .{ .w = 18, .h = 18 }, .gravity_x = 1, .gravity_y = 0.5, .color_text = .{ .color = theme.colors.accent }, .padding = .all(0), .margin = .all(0), .role = .none });
            }
            if (control.clicked()) {
                ui.draft.preset = preset;
                ui.draft.background_color = palette.background;
                ui.syncHex();
                ui.edited();
            }
        }
    }
}

fn panelTitle(src: std.builtin.SourceLocation, title: []const u8) void {
    dvui.labelNoFmt(src, title, .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .font = theme.headingFont(), .color_text = .{ .color = theme.colors.muted }, .background = false, .padding = .all(0), .margin = .{ .h = theme.spacing.section_label_gap } });
}

fn selectionRow(src: std.builtin.SourceLocation, labels: []const []const u8, selected: usize) ?usize {
    const row = dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .all(0), .margin = .{ .h = 16 } });
    defer row.deinit();
    const cell_width = @max(0, (row.data().contentRect().w - 8 * @as(f32, @floatFromInt(labels.len - 1))) / @as(f32, @floatFromInt(labels.len)));
    var clicked: ?usize = null;
    for (labels, 0..) |label, index| {
        const chosen = selected == index;
        var control: dvui.ButtonWidget = undefined;
        control.init(src, .{}, .{ .id_extra = index, .label = .{ .text = label }, .min_size_content = .{ .w = @max(0, cell_width - 22), .h = 24 }, .max_size_content = .width(@max(0, cell_width - 22)), .padding = .{ .x = 10, .w = 10, .y = 11, .h = 11 }, .margin = .{ .w = if (index + 1 < labels.len) 8 else 0 }, .border = .all(1), .corners = .all(theme.controlRadius()), .background = true, .color_fill = .{ .color = if (chosen) theme.colors.selected_surface else theme.colors.surface }, .color_border = .{ .color = if (chosen) theme.colors.accent else theme.colors.outline } });
        defer control.deinit();
        if (control.data().accesskit_node()) |node| dvui.AccessKit.nodeSetSelected(node, chosen);
        control.processEvents();
        theme.surface.buttonBackground(&control);
        dvui.labelNoFmt(src, label, .{}, .{ .font = theme.bodyFont(), .padding = .all(0), .margin = .all(0), .gravity_x = 0.5, .gravity_y = 0.5, .role = .none, .tab_index = 0 });
        if (control.clicked()) clicked = index;
    }
    return clicked;
}

fn drawBackgroundControls(ui: *Ui) void {
    const panel = components.formPanel(@src(), .{ .tag = "theme-background" });
    defer panel.deinit();
    panelTitle(@src(), "背景");
    const mode: usize = if (ui.draft.background_mode == .solid) 0 else 1;
    if (selectionRow(@src(), &.{ "纯色", "图片" }, mode)) |next| {
        ui.draft.background_mode = if (next == 0) .solid else .image;
        ui.syncHex();
        ui.edited();
    }
    if (ui.draft.background_mode == .solid) {
        if (components.field(@src(), "背景颜色（#RRGGBB）", &ui.hex, .{ .tag = "theme-background-hex" })) {
            if (appearance.parseHex(std.mem.sliceTo(&ui.hex, 0))) |color| {
                ui.draft.background_color = color;
                ui.hex_valid = true;
            } else |_| {
                ui.hex_valid = false;
            }
            ui.edited();
        }
        if (!ui.hex_valid) components.text(@src(), "请输入 #RRGGBB 格式的六位十六进制颜色", theme.colors.danger);
        const per_row: usize = if (panel.data().contentRect().w >= 300) 6 else if (panel.data().contentRect().w >= 150) 3 else if (panel.data().contentRect().w >= 100) 2 else 1;
        var first: usize = 0;
        while (first < appearance.presets.len) : (first += per_row) {
            const colors = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = first, .expand = .horizontal, .padding = .all(0), .margin = .{ .h = 6 } });
            defer colors.deinit();
            for (first..@min(first + per_row, appearance.presets.len)) |index| {
                const preset = appearance.presets[index];
                const color = appearance.palette(preset).background;
                var control: dvui.ButtonWidget = undefined;
                control.init(@src(), .{}, .{ .id_extra = index, .label = .{ .text = appearance.presetName(preset) }, .min_size_content = .{ .w = 34, .h = 34 }, .padding = .all(4), .margin = .{ .w = 6 }, .border = .all(1), .corners = .all(6), .background = true, .color_fill = .{ .color = background.rgb(color) }, .color_fill_hover = .{ .color = background.rgb(color) }, .color_fill_press = .{ .color = background.rgb(color) }, .color_border = .{ .color = if (ui.draft.background_color == color) theme.colors.accent else theme.colors.control_outline } });
                defer control.deinit();
                if (control.data().accesskit_node()) |node| dvui.AccessKit.nodeSetSelected(node, ui.draft.background_color == color);
                control.processEvents();
                theme.surface.buttonBackground(&control);
                if (control.clicked()) {
                    ui.draft.background_color = color;
                    ui.syncHex();
                    ui.edited();
                }
            }
        }
    } else {
        components.fieldLabel(@src(), "背景图片");
        const available = dvui.parentGet().data().contentRect().w;
        const thumbnail_width = @min(160, @max(96, available * 0.28));
        const image_area = dvui.box(@src(), .{ .dir = .horizontal }, .{ .tag = "theme-image-status", .expand = .horizontal, .max_size_content = .width(0), .padding = .all(12), .margin = .{ .h = 12 }, .background = true, .color_fill = .{ .color = theme.colors.inset }, .corners = .all(theme.cardRadius()) });
        {
            defer image_area.deinit();
            if (ui.preview_image.image) |image| {
                _ = @import("surface.zig").image(@src(), .{ .source = image.source(0) }, .{ .label = .{ .text = "背景图片缩略图" }, .min_size_content = .{ .w = thumbnail_width, .h = thumbnail_width * 9 / 16 }, .max_size_content = .{ .w = thumbnail_width, .h = thumbnail_width * 9 / 16 }, .corners = .all(theme.controlRadius()), .padding = .all(0), .margin = .{ .w = 16 }, .gravity_y = 0.5 });
            } else {
                _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = thumbnail_width, .h = thumbnail_width * 9 / 16 }, .margin = .{ .w = 16 } });
            }
            const information = dvui.box(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = .all(0), .margin = .all(0), .gravity_y = 0.5 });
            defer information.deinit();
            components.text(@src(), if (ui.draft.image_path) |path| imageName(path) else "尚未选择图片", theme.colors.muted);
            if (ui.preview_image.failure) |err| drawFailure(err) else if (ui.preview_image.job != null) components.text(@src(), "正在处理图片…", theme.colors.muted);
            const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .all(0), .margin = .{ .y = 8 } });
            defer actions.deinit();
            _ = dvui.spacer(@src(), .{ .expand = .horizontal });
            if (components.button(@src(), if (ui.draft.image_path == null) "选择图片" else "替换图片", .{ .enabled = ui.ticket == null and ui.picker != null, .tag = "theme-image-choose", .min_width = 0 })) ui.pending = .choose_image;
            _ = dvui.spacer(@src(), .{ .min_size_content = .width(12) });
            if (components.button(@src(), "移除图片", .{ .enabled = ui.draft.image_path != null, .tag = "theme-image-remove", .min_width = 0 })) ui.pending = .remove_image;
        }
        if (ui.preview_image.failure != null and components.button(@src(), "重新读取图片", .{ .min_width = 0 })) ui.pending = .retry_image;
        components.hint(@src(), "PNG、JPEG、WebP · 最大 32 MiB、2400 万像素");
        var layout: usize = switch (ui.draft.image_layout) {
            .fill => 0,
            .fit => 1,
            .stretch => 2,
        };
        components.fieldLabel(@src(), "图片布局");
        if (components.dropdown(@src(), "图片布局", &.{ "填充", "适应", "拉伸" }, .{ .choice = &layout }, .{}, .{})) {
            ui.draft.image_layout = switch (layout) {
                1 => .fit,
                2 => .stretch,
                else => .fill,
            };
            ui.edited();
        }
        var blur: usize = switch (ui.draft.image_blur) {
            4 => 1,
            8 => 2,
            16 => 3,
            else => 0,
        };
        components.fieldLabel(@src(), "背景模糊");
        if (components.dropdown(@src(), "背景模糊", &.{ "关闭", "轻微", "中等", "明显" }, .{ .choice = &blur }, .{}, .{})) {
            ui.draft.image_blur = ([_]u8{ 0, 4, 8, 16 })[blur];
            ui.edited();
        }
        percentage(@src(), ui, "背景暗化", &ui.draft.image_dimming, 0);
    }
}

fn percentage(src: std.builtin.SourceLocation, ui: *Ui, name: []const u8, value: *u8, minimum: u8) void {
    const label = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} · {d}%", .{ name, value.* }) catch name;
    components.fieldLabel(src, label);
    var fraction = @as(f32, @floatFromInt(value.* - minimum)) / @as(f32, @floatFromInt(100 - minimum));
    if (dvui.slider(src, .{ .fraction = &fraction }, .{ .id_extra = 1, .label = .{ .text = name }, .expand = .horizontal, .min_size_content = .height(20), .padding = .{ .y = 12, .h = 12 }, .margin = .{ .h = 12 } })) {
        value.* = minimum + @as(u8, @intFromFloat(@round(fraction * @as(f32, @floatFromInt(100 - minimum)))));
        ui.edited();
    }
}

fn drawDetails(ui: *Ui) void {
    const panel = components.formPanel(@src(), .{ .tag = "theme-details" });
    defer panel.deinit();
    panelTitle(@src(), "界面细节");
    const radius: usize = switch (ui.draft.corner_radius) {
        0 => 0,
        8 => 1,
        20 => 3,
        else => 2,
    };
    components.fieldLabel(@src(), "圆角大小");
    if (selectionRow(@src(), &.{ "直角", "小", "默认", "大" }, radius)) |next| {
        ui.draft.corner_radius = ([_]u8{ 0, 8, 12, 20 })[next];
        ui.edited();
    }
    percentage(@src(), ui, "面板不透明度", &ui.draft.panel_opacity, 60);
    components.fieldLabel(@src(), "面板模糊");
    const strength: usize = switch (ui.draft.panel_blur) {
        4 => 1,
        8 => 2,
        16 => 3,
        else => 0,
    };
    if (selectionRow(@src(), &.{ "关闭", "轻微", "中等", "明显" }, strength)) |next| {
        ui.draft.panel_blur = ([_]u8{ 0, 4, 8, 16 })[next];
        ui.edited();
    }
    if (ui.draft.panel_blur > 0 and ui.draft.panel_opacity == 100) components.hint(@src(), "降低面板不透明度可显示模糊效果。");
}

fn drawFailure(err: anyerror) void {
    const message: []const u8 = switch (err) {
        error.BackgroundImageTooLarge, error.StreamTooLong => "图片过大：请使用不超过 32 MiB、2400 万像素、单边 8192 像素的图片",
        error.InvalidBackgroundImage, error.UnsupportedBackgroundFormat => "无法读取图片，请选择有效的 PNG、JPEG 或 WebP 文件",
        error.FileNotFound => "图片文件不存在，请重新选择",
        error.ConfigPublicationUncertain => "请先重新加载已保存配置",
        error.AccessDenied => "无法保存，请检查启动器目录的写入权限",
        error.NoSpaceLeft, error.DiskQuota => "磁盘空间不足，草稿已保留",
        error.ShutdownInProgress => "正在关闭启动器，暂时不能保存主题",
        else => "操作未完成，草稿已保留",
    };
    components.text(@src(), message, theme.colors.danger);
}

/// Queue-only drawing is published here, after all snapshot borrowers finish.
pub fn finish(ui: *Ui, store: *config.Store) void {
    const command = ui.pending orelse return;
    ui.pending = null;
    if (dvui.current_window != null) dvui.refresh(null, @src(), null);
    execute(ui, store, command) catch |err| {
        std.log.warn("Theme action {s} failed: {s}", .{ @tagName(command), @errorName(err) });
        ui.failure = err;
        ui.saved = false;
    };
}
fn execute(ui: *Ui, store: *config.Store, command: Command) !void {
    if (!ui.allow_mutations) switch (command) {
        .apply, .save_navigation, .choose_image, .reload => return error.ShutdownInProgress,
        else => {},
    };
    switch (command) {
        .defaults => try ui.replaceDraft(.{}),
        .cancel => {
            try ui.replaceDraft(store.snapshot().appearance);
            ui.navigation = null;
            ui.close_requested = false;
            ui.resume_close = false;
        },
        .choose_image => {
            const picker = ui.picker orelse return error.FilePickerUnavailable;
            if (ui.ticket != null) return;
            ui.ticket = try picker.request(.{ .kind = .file, .title = "选择背景图片", .default_path = ui.draft.image_path orelse "", .extensions = background.extensions });
            ui.edited();
        },
        .remove_image => {
            ui.discardPicker();
            try ui.setPath(null);
            ui.draft.background_mode = .solid;
        },
        .retry_image => ui.preview_image.retry(),
        .reload => {
            try store.recover();
            ui.edited();
        },
        .cancel_navigation => {
            ui.navigation = null;
            ui.close_requested = false;
        },
        .discard_navigation => {
            try ui.replaceDraft(store.snapshot().appearance);
            resumeLeave(ui);
        },
        .apply, .save_navigation => {
            if (!ui.canApply(store)) return error.ThemeNotReady;
            var settings = ui.draft;
            if (settings.background_mode == .solid) settings.image_path = null;
            const image = if (settings.image_path != null) ui.preview_image.image else null;
            var managed_path: ?[]u8 = null;
            defer if (managed_path) |path| ui.a.free(path);
            if (settings.image_path != null) {
                if (!ui.preview_image.ready()) return error.ThemeNotReady;
                managed_path = try background.persist(image.?, ui.a, store.io, store.root);
                settings.image_path = managed_path;
            }
            // Allocate every owned copy before Store.update, so OOM cannot turn a
            // successful publication into a failed UI transition.
            const next_draft = try ownSettings(ui.a, settings);
            errdefer freeSettings(ui.a, next_draft);
            const next_baseline = try ownSettings(ui.a, settings);
            errdefer freeSettings(ui.a, next_baseline);
            var document = store.snapshot().*;
            document.appearance = settings;
            try store.update(document);
            freeSettings(ui.a, ui.draft);
            freeSettings(ui.a, ui.baseline);
            ui.draft = next_draft;
            ui.baseline = next_baseline;
            ui.syncHex();
            ui.failure = null;
            ui.saved = true;
            if (image) |processed| {
                // Applied cache transitions happen at the next frame boundary.
                // Never retire an image still referenced by queued draw commands.
                ui.preview_image.adopt(processed, settings.image_path.?) catch {};
            }
            if (command == .save_navigation) {
                resumeLeave(ui);
            }
        },
    }
}

fn resumeLeave(ui: *Ui) void {
    ui.resume_navigation = ui.navigation;
    ui.navigation = null;
    ui.resume_close = ui.close_requested;
    ui.close_requested = false;
}

/// Defers a window close until the user saves or discards the owned draft.
pub fn guardClose(ui: *Ui) bool {
    if (!ui.dirty()) return true;
    ui.navigation = null;
    ui.resume_navigation = null;
    ui.close_requested = true;
    if (dvui.current_window != null) dvui.refresh(null, @src(), null);
    return false;
}

pub fn takeClose(ui: *Ui) bool {
    const ready = ui.resume_close;
    ui.resume_close = false;
    return ready;
}

/// Call before model reduction every frame. Only actual route changes are retained;
/// string-bearing selection/start messages never become borrowed deferred payloads.
pub fn guardNavigation(ui: *Ui, pending: *?model.Msg, store: *config.Store) void {
    _ = store;
    if (ui.resume_navigation) |message| {
        pending.* = message;
        ui.resume_navigation = null;
        ui.active = false;
        return;
    }
    if (ui.navigation != null or ui.close_requested) {
        pending.* = null;
        return;
    }
    if (!ui.active and !ui.drawn) return;
    const message = pending.* orelse return;
    const leaving = switch (message) {
        .select_category => |category| category != .theme,
        .open_players, .open_versions, .open_java, .open_servers, .open_logs, .open_instances, .open_worlds, .open_mods, .back, .instances_back, .java_back, .utility_back => true,
        else => false,
    };
    if (leaving) {
        if (ui.dirty()) {
            ui.navigation = message;
            pending.* = null;
        } else ui.discardPicker();
    }
}

pub fn dialogs(ui: *Ui, store: *config.Store) !void {
    if (ui.navigation == null and !ui.close_requested) return;
    const dialog = components.modal(@src(), "保存主题更改？", 420);
    defer dialog.deinit();
    components.text(@src(), "主题草稿尚未保存。保存后离开，或放弃本次更改。", theme.colors.foreground);
    if (ui.failure) |err| drawFailure(err);
    if (store.publicationUncertain()) {
        components.text(@src(), "保存结果尚未确认，请先重新加载配置。草稿会保留。", theme.colors.warning);
        if (components.button(@src(), "重新加载已保存配置", .{})) ui.pending = .reload;
    }
    const actions = dvui.box(@src(), .{}, .{ .expand = .horizontal, .gravity_y = 1, .padding = .all(0), .margin = .{ .y = 16 } });
    defer actions.deinit();
    if (components.button(@src(), "保存并离开", .{ .enabled = ui.canApply(store), .primary = true, .expand = true, .tag = "theme-navigation-save" })) ui.pending = .save_navigation;
    if (components.button(@src(), "放弃更改", .{ .expand = true, .tag = "theme-navigation-discard" })) ui.pending = .discard_navigation;
    if (components.button(@src(), "取消", .{ .expand = true, .tag = "theme-navigation-cancel" })) ui.pending = .cancel_navigation;
}

test "dirty theme navigation preserves drafts and permits discard during shutdown" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    var ui = try Ui.init(a, io, store.snapshot().appearance);
    defer ui.deinit();
    ui.drawn = true;
    ui.draft.preset = .mist;
    ui.draft.background_color = appearance.palette(.mist).background;
    var pending: ?model.Msg = .{ .select_category = .settings };
    guardNavigation(&ui, &pending, &store);
    try std.testing.expect(pending == null and ui.navigation != null and ui.dirty());
    ui.pending = .cancel_navigation;
    finish(&ui, &store);
    try std.testing.expect(ui.navigation == null and ui.dirty());
    pending = .{ .select_category = .settings };
    guardNavigation(&ui, &pending, &store);
    ui.allow_mutations = false;
    ui.pending = .save_navigation;
    finish(&ui, &store);
    try std.testing.expectEqual(error.ShutdownInProgress, ui.failure.?);
    try std.testing.expectEqual(appearance.Preset.moss, store.snapshot().appearance.preset);
    try std.testing.expect(ui.dirty() and ui.navigation != null);
    ui.pending = .discard_navigation;
    finish(&ui, &store);
    try std.testing.expect(!ui.dirty() and ui.navigation == null);
    guardNavigation(&ui, &pending, &store);
    try std.testing.expectEqual(model.Category.settings, pending.?.select_category);
}

test "window close waits for theme save discard or cancellation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    var ui = try Ui.init(a, io, store.snapshot().appearance);
    defer ui.deinit();
    ui.drawn = true;
    ui.draft.preset = .frost;
    try std.testing.expect(!guardClose(&ui) and ui.close_requested);
    ui.pending = .cancel_navigation;
    finish(&ui, &store);
    try std.testing.expect(ui.dirty() and !ui.close_requested and !takeClose(&ui));
    try std.testing.expect(!guardClose(&ui));
    ui.pending = .discard_navigation;
    finish(&ui, &store);
    try std.testing.expect(!ui.dirty() and takeClose(&ui) and !takeClose(&ui));
    ui.draft.preset = .mist;
    try std.testing.expect(!guardClose(&ui));
    ui.pending = .save_navigation;
    finish(&ui, &store);
    try std.testing.expect(!ui.dirty() and takeClose(&ui));
    try std.testing.expectEqual(appearance.Preset.mist, store.snapshot().appearance.preset);
}

test "live appearance draft never publishes until save and cancel restores the window" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    try store.update(.{});
    const before = try tmp.dir.readFileAlloc(io, ".vela/config.json", a, .limited(1024 * 1024));
    defer a.free(before);
    var ui = try Ui.init(a, io, store.snapshot().appearance);
    defer ui.deinit();
    ui.active = true;
    ui.draft.preset = .frost;
    ui.draft.panel_opacity = 75;
    ui.draft.panel_blur = 8;
    ui.edited();
    try std.testing.expectEqual(appearance.Preset.frost, visibleSettings(&ui, &store).preset);
    try std.testing.expectEqual(@as(u8, 8), visibleSettings(&ui, &store).panel_blur);
    try std.testing.expectEqual(appearance.Preset.moss, store.snapshot().appearance.preset);
    const after = try tmp.dir.readFileAlloc(io, ".vela/config.json", a, .limited(1024 * 1024));
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    try execute(&ui, &store, .cancel);
    try std.testing.expect(!ui.dirty());
    try std.testing.expectEqual(appearance.Preset.moss, visibleSettings(&ui, &store).preset);
    try std.testing.expectEqual(@as(u8, 0), visibleSettings(&ui, &store).panel_blur);
    ui.draft.preset = .mist;
    ui.draft.panel_blur = 16;
    try execute(&ui, &store, .apply);
    try store.reconcile();
    try std.testing.expectEqual(appearance.Preset.mist, store.snapshot().appearance.preset);
    try std.testing.expectEqual(@as(u8, 16), store.snapshot().appearance.panel_blur);
}

test "wallpaper pixels survive palette saves and removals through deferred rendering" {
    const a = std.testing.allocator;
    const heap = std.heap.page_allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    const initial: appearance.Settings = .{ .background_mode = .image, .image_path = "retained-test.png" };
    try store.update(.{ .appearance = initial });
    const image = blk: {
        var pixels: [4][]dvui.Color.PMA = undefined;
        var allocated: usize = 0;
        errdefer for (pixels[0..allocated]) |slice| heap.free(slice);
        for (&pixels) |*slice| {
            slice.* = try heap.alloc(dvui.Color.PMA, 1);
            allocated += 1;
            slice.*[0] = .{ .r = 160, .g = 80, .b = 40, .a = 255 };
        }
        const bytes = try heap.dupe(u8, "retained image bytes");
        errdefer heap.free(bytes);
        const path = try heap.dupe(u8, initial.image_path.?);
        errdefer heap.free(path);
        const owned = try heap.create(background.Image);
        owned.* = .{ .bytes = bytes, .path = path, .width = 1, .height = 1, .pixels = pixels, .digest = @splat(0), .extension = "png" };
        break :blk owned;
    };
    defer image.release();
    var ui = try Ui.init(a, io, initial);
    defer ui.deinit();
    try ui.preview_image.adopt(image, initial.image_path.?);
    try ui.applied_image.adopt(image, initial.image_path.?);
    ui.drawn = true;
    beginFrame(&ui, &store);
    try std.testing.expectEqual(@as(usize, 5), image.refs);
    for (appearance.presets) |preset| {
        ui.draft.preset = preset;
        ui.draft.background_color = appearance.palette(preset).background;
        try std.testing.expectEqual(appearance.BackgroundMode.image, visibleSettings(&ui, &store).background_mode);
        try std.testing.expectEqualStrings(initial.image_path.?, visibleSettings(&ui, &store).image_path.?);
        try std.testing.expectEqual(@as(u8, 160), ui.frame_images[0].?.pixels[0][0].r);
    }
    try execute(&ui, &store, .apply);
    try std.testing.expectEqual(@as(usize, 5), image.refs);
    try execute(&ui, &store, .remove_image);
    try std.testing.expectEqual(@as(usize, 4), image.refs);
    try std.testing.expectEqual(@as(u8, 160), ui.frame_images[0].?.pixels[0][0].r);
    ui.releaseFrameImages();
    try std.testing.expectEqual(@as(usize, 2), image.refs);
}

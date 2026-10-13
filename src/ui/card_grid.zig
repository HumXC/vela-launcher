//! Responsive, non-scrolling card layout. Use inside the caller's scroll body.
//! Cells are direct children keyed by record, so reflow does not change IDs.
const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme.zig");

pub const Options = struct {
    min_width: f32 = 320,
    max_columns: usize = 3,
    gap: f32 = theme.spacing.card_gap,
    tag: ?[]const u8 = null,
};

pub const Grid = struct {
    columns: usize,
    /// Total available grid width. Use cardWidth(index) for a card's outer width.
    width: f32,
    layout: *Layout,

    /// Open one cell, render its card, then deinit the cell before opening another.
    /// Keys must be unique within this grid and stable across frames. The index
    /// controls placement only; it is deliberately excluded from widget identity.
    pub fn cell(self: *Grid, src: std.builtin.SourceLocation, index: usize, key: []const u8) *dvui.BoxWidget {
        const layout = self.layout;
        std.debug.assert(index < layout.count);
        std.debug.assert(dvui.parentGet().data().id == layout.wd.id);
        std.debug.assert(layout.pending_index == null);
        layout.pending_index = index;
        return dvui.box(src, .{}, .{
            .name = "CardGridCell",
            .id_extra = @as(usize, @truncate(std.hash.Wyhash.hash(0, key))),
            .expand = .both,
            .max_size_content = .width(self.cardWidth(index)),
            .padding = .all(0),
            .margin = .all(0),
            .border = .all(0),
            .background = false,
            .role = .none,
        });
    }

    /// Exact cell content width, including the final column's fractional remainder.
    /// Cell wrappers have no padding, border or margin. Cards own their decoration
    /// and should expand both to occupy the measured row height.
    pub fn cardWidth(self: *const Grid, index: usize) f32 {
        return self.layout.geometry.columnRect(index % self.columns).w;
    }

    pub fn deinit(self: *Grid) void {
        self.layout.deinit();
        self.* = undefined;
    }
};

/// Like DVUI's built-in containers, natural heights are measured this frame and
/// allocated on the next refresh. Each row shares one allocation, and fresh
/// measurements start at zero so removing or shortening content can shrink it.
/// No ScrollArea or ScrollContainer is introduced by this widget.
pub fn init(src: std.builtin.SourceLocation, count: usize, options: Options) Grid {
    const layout = dvui.widgetAlloc(Layout);
    layout.init(src, count, options);
    return .{
        .columns = layout.geometry.columns,
        .width = layout.geometry.width,
        .layout = layout,
    };
}

const Row = struct {
    y: f32,
    height: f32,
};

const Layout = struct {
    wd: dvui.WidgetData,
    geometry: Geometry,
    count: usize,
    rows: []Row,
    measured: []f32,
    pending_index: ?usize = null,

    fn init(self: *Layout, src: std.builtin.SourceLocation, count: usize, options: Options) void {
        const wd = dvui.WidgetData.init(src, .{}, .{
            .name = "CardGrid",
            .tag = options.tag,
            .expand = .horizontal,
            // Card minima must never force the enclosing scroll body wider.
            .max_size_content = .width(0),
            .padding = .all(0),
            .margin = .all(0),
            .border = .all(0),
            .background = false,
            .role = .none,
        });
        const geometry = Geometry.init(wd.contentRect().w, count, options);
        const row_count = count / geometry.columns + @intFromBool(count % geometry.columns != 0);
        const arena = dvui.currentWindow().arena();
        const rows = arena.alloc(Row, row_count) catch @panic("out of memory allocating card grid rows");
        const measured = arena.alloc(f32, row_count) catch @panic("out of memory measuring card grid rows");
        @memset(measured, 0);
        const previous = dvui.dataGetSlice(null, wd.id, "card_grid_heights", []f32) orelse &.{};
        var y: f32 = 0;
        for (rows, 0..) |*row, i| {
            const height = if (i < previous.len) finiteNonnegative(previous[i]) else 0;
            row.* = .{ .y = y, .height = height };
            y += height;
            if (i + 1 < rows.len) y += geometry.gap;
        }
        self.* = .{ .wd = wd, .geometry = geometry, .count = count, .rows = rows, .measured = measured };
        self.wd.register();
        dvui.parentSet(self.widget());
    }

    fn widget(self: *Layout) dvui.Widget {
        return dvui.Widget.init(self, data, rectFor, screenRectScale, minSizeForChild);
    }

    fn data(self: *Layout) *dvui.WidgetData {
        return self.wd.validate();
    }

    fn rectFor(self: *Layout, _: dvui.Id, _: dvui.Size, _: dvui.Options.Expand, _: dvui.Options.Gravity) dvui.Rect {
        const index = self.pending_index orelse @panic("card grid children must be opened with cell()");
        const row = self.rows[index / self.geometry.columns];
        var rect = self.geometry.columnRect(index % self.geometry.columns);
        rect.y = row.y;
        rect.h = row.height;
        return rect;
    }

    fn screenRectScale(self: *Layout, rect: dvui.Rect) dvui.RectScale {
        return self.wd.contentRectScale().rectToRectScale(rect);
    }

    fn minSizeForChild(self: *Layout, size: dvui.Size) void {
        const index = self.pending_index orelse @panic("card grid cell reported size twice");
        const row = index / self.geometry.columns;
        self.measured[row] = @max(self.measured[row], finiteNonnegative(size.h));
        self.pending_index = null;
    }

    fn deinit(self: *Layout) void {
        defer dvui.widgetFree(self);
        defer self.* = undefined;
        std.debug.assert(self.pending_index == null);
        var height: f32 = 0;
        var changed = false;
        for (self.measured, self.rows, 0..) |measured, row, i| {
            changed = changed or measured != row.height;
            height += measured;
            if (i + 1 < self.rows.len) height += self.geometry.gap;
        }
        // Report natural height, never the allocated height of expanded children.
        self.wd.minSizeMax(.{ .h = height });
        self.wd.minSizeSetAndRefresh();
        self.wd.minSizeReportToParent();
        if (changed) dvui.refresh(null, @src(), self.wd.id);
        dvui.dataSetSlice(null, self.wd.id, "card_grid_heights", @as([]const f32, self.measured));
        dvui.parentReset(self.wd.id, self.wd.parent);
    }
};

const Geometry = struct {
    width: f32,
    columns: usize,
    gap: f32,

    fn init(available: f32, _: usize, options: Options) Geometry {
        const width = finiteNonnegative(available);
        const min_width: f64 = if (std.math.isFinite(options.min_width) and options.min_width > 0) options.min_width else 320;
        const gap = finiteNonnegative(options.gap);
        const limit = @max(1, options.max_columns);
        // Compare before converting: even a tiny min_width cannot overflow usize.
        const fits = @floor((@as(f64, width) + gap) / (min_width + gap));
        const columns: usize = if (fits >= @as(f64, @floatFromInt(limit))) limit else if (fits >= 1) @intFromFloat(fits) else 1;
        return .{ .width = width, .columns = columns, .gap = gap };
    }

    fn columnRect(self: Geometry, column: usize) dvui.Rect {
        std.debug.assert(column < self.columns);
        const columns: f64 = @floatFromInt(self.columns);
        const col: f64 = @floatFromInt(column);
        const available = @max(0, @as(f64, self.width) - @as(f64, self.gap) * (columns - 1));
        // Derive every edge independently, rather than adding f32 widths until a
        // flex container accidentally wraps the last card. Keep the final edge
        // exactly at the available width, including its fractional remainder.
        const x: f32 = @floatCast(@floor(available * col / columns) + @as(f64, self.gap) * col);
        const right: f32 = if (column + 1 == self.columns) self.width else @floatCast(@floor(available * (col + 1) / columns) + @as(f64, self.gap) * col);
        return .{ .x = x, .w = @max(0, right - x) };
    }
};

fn finiteNonnegative(value: f32) f32 {
    return if (std.math.isFinite(value)) @max(0, value) else 0;
}

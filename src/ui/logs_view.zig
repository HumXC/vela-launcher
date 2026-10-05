const std = @import("std");
const dvui = @import("dvui");
const logs = @import("../core/logs.zig");
const game_launch = @import("game_launch.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const R = dvui.Rect;
const row_height: f32 = 24;
const clipboard_limit = 1024 * 1024;
const marker_limit = 128;

const Filters = struct {
    sources: [2]bool = .{ true, true },
    severities: [6]bool = .{ true, true, true, true, true, true },

    fn accepts(self: Filters, line: anytype) bool {
        return self.sources[@intFromEnum(line.source)] and self.severities[@intFromEnum(line.severity)];
    }
};

/// Initialize with .{}. Drawing borrows only until each call returns; finish must
/// run after the application's outer Root closes, even when this view is hidden.
pub const View = struct {
    filters: Filters = .{},
    query: [256]u8 = @splat(0),
    cursor: ?logs.Cursor = null,
    selected: ?u64 = null,
    jump: ?u64 = null,
    anchor: ?u64 = null,
    anchor_fraction: f32 = 0,
    follow_tail: bool = true,
    scroll: dvui.ScrollInfo = .{ .vertical = .given, .horizontal = .given },
    attempt: ?u64 = null,
    pending_clear: bool = false,
    pending_stop: bool = false,
    pending_attempt: u64 = 0,
    search_status: enum { none, found, no_match, boundary } = .none,
    copy_status: enum { none, copied, limited } = .none,

    pub fn finish(self: *View, controller: *game_launch.Controller) void {
        const same_attempt = self.pending_attempt == controller.snapshot().attempt_id;
        if (same_attempt and self.pending_stop) controller.stop();
        if (same_attempt and self.pending_clear) {
            controller.clearLogs();
            self.resetNavigation();
        }
        self.pending_clear = false;
        self.pending_stop = false;
    }

    fn resetNavigation(self: *View) void {
        self.cursor = null;
        self.selected = null;
        self.jump = null;
        self.anchor = null;
        self.anchor_fraction = 0;
        self.scroll.viewport.x = 0;
        self.scroll.viewport.y = 0;
        self.scroll.velocity = .{};
        self.search_status = .none;
        self.copy_status = .none;
    }

    // Both entry points synchronize before using selection or search state.
    fn synchronize(self: *View, controller: *game_launch.Controller) void {
        const snapshot = controller.snapshot();
        if (self.attempt == null or self.attempt.? != snapshot.attempt_id) {
            self.resetNavigation();
            self.follow_tail = true;
            self.attempt = snapshot.attempt_id;
        }
        const buffer = controller.logBuffer();
        if (self.selected) |id| if (buffer.get(id) == null) {
            self.selected = null;
        };
        if (self.cursor) |cursor| if (buffer.get(cursor.id) == null) {
            self.cursor = null;
            self.search_status = .none;
        };
    }

    /// Draw inside the parent's utility menu, before draw renders the viewport.
    pub fn drawSidebar(self: *View, controller: *game_launch.Controller) !void {
        self.synchronize(controller);
        const buffer = controller.logBuffer();
        const snap = controller.snapshot();
        // Keep controls reachable in short windows; the parent's footer stays outside.
        const area = dvui.scrollArea(@src(), .{ .vertical_bar = .auto, .horizontal_bar = .auto }, .{ .expand = .both, .padding = R.all(0), .margin = R.all(0), .corners = .all(0) });
        defer area.deinit();
        const controls = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = R.all(0), .margin = R.all(0) });
        defer controls.deinit();

        components.section(@src(), "View");
        _ = dvui.checkbox(@src(), &self.follow_tail, "Follow latest output", .{ .expand = .horizontal, .padding = R.all(6), .margin = R.all(0) });
        if (components.sidebarItem(@src(), "jump-latest", "Jump to latest", .{ .icon = dvui.entypo.chevron_down, .enabled = buffer.lineCount() != 0 })) {
            self.jump = null;
            self.follow_tail = true;
            self.scroll.velocity = .{};
        }

        if (self.filterBar()) {
            self.anchor = null;
            self.cursor = null;
            self.search_status = .none;
            self.scroll.viewport.y = 0;
        }

        components.section(@src(), "Search");
        self.searchBar(buffer);
        const message: []const u8 = switch (self.search_status) {
            .none => "Search retained output",
            .found => "Match selected",
            .no_match => "No matches in enabled filters",
            .boundary => "No more matches",
        };
        statusText(@src(), message, theme.muted, .{ .y = 4 }, 0);

        components.section(@src(), "Output");
        if (components.sidebarItem(@src(), "copy-line", "Copy selected line", .{ .icon = dvui.entypo.copy, .enabled = self.selected != null })) self.copySelected(buffer);
        if (components.sidebarItem(@src(), "copy-output", "Copy retained output", .{ .icon = dvui.entypo.documents, .enabled = buffer.lineCount() != 0 })) self.copyRetained(buffer);
        if (self.copy_status != .none) statusText(@src(), if (self.copy_status == .limited) "Copied first 1 MiB" else "Copied", theme.muted, .{ .y = 4 }, 0);
        if (components.sidebarItem(@src(), "clear-output", "Clear retained output", .{ .icon = dvui.entypo.trash, .enabled = buffer.lineCount() != 0 })) {
            self.pending_clear = true;
            self.pending_attempt = snap.attempt_id;
        }
        if (components.sidebarItem(@src(), "stop-game", "Stop game", .{ .icon = dvui.entypo.controller_stop, .enabled = snap.phase == .preparing or snap.phase == .running })) {
            self.pending_stop = true;
            self.pending_attempt = snap.attempt_id;
        }
    }

    pub fn draw(self: *View, controller: *game_launch.Controller) !void {
        self.synchronize(controller);
        const buffer = controller.logBuffer();
        const arena = dvui.currentWindow().arena();
        const column = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = R.all(0), .margin = R.all(0) });
        defer column.deinit();
        self.header(controller);
        const lines = buffer.lines();
        const storage = try arena.alloc(usize, lines.len);
        var count: usize = 0;
        var max_bytes: usize = 0;
        for (lines, 0..) |line, i| {
            if (!self.filters.accepts(line)) continue;
            storage[count] = i;
            count += 1;
            max_bytes = @max(max_bytes, line.text.len);
        }
        const indices = storage[0..count];
        self.scroll.virtual_size = .{
            .h = @as(f32, @floatFromInt(count)) * row_height,
            .w = @max(self.scroll.viewport.w, 196 + @as(f32, @floatFromInt(max_bytes)) * dvui.Font.theme(.mono).withSize(13).textSize("M").w),
        };
        if (!self.follow_tail) {
            if (self.anchor) |id| {
                if (rowForId(lines, indices, id)) |row| self.scroll.viewport.y = @as(f32, @floatFromInt(row)) * row_height + self.anchor_fraction;
            }
        }
        if (self.jump) |id| {
            if (rowForId(lines, indices, id)) |row| {
                self.scroll.viewport.y = @max(0, @as(f32, @floatFromInt(row)) * row_height - self.scroll.viewport.h * 0.35);
                self.scroll.viewport.x = 0;
                self.scroll.velocity = .{};
                self.follow_tail = false;
            }
            self.jump = null;
        }
        if (self.follow_tail) self.scroll.viewport.y = self.scroll.scrollMax(.vertical);
        self.scroll.viewport.y = std.math.clamp(self.scroll.viewport.y, 0, self.scroll.scrollMax(.vertical));
        const body = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .padding = R.all(0), .margin = R.all(0) });
        {
            defer body.deinit();
            // A fixed-size rail bounds marker widgets even when every line is an error.
            const rail = dvui.box(@src(), .{}, .{ .expand = .vertical, .gravity_x = 1, .min_size_content = .{ .w = 12 }, .max_size_content = .width(12), .padding = R.all(0), .margin = R.all(0) });
            {
                defer rail.deinit();
                try self.errorRail(buffer, indices, rail.data().contentRect().h);
            }
            const before = self.scroll.viewport.y;
            var user_scroll: dvui.Point = .{};
            const area = dvui.scrollArea(@src(), .{ .scroll_info = &self.scroll, .vertical_bar = .show, .horizontal_bar = .auto, .user_scroll = &user_scroll }, .{ .expand = .both, .padding = R.all(0), .margin = R.all(0), .corners = .all(0) });
            {
                defer {
                    area.deinit();
                    if (user_scroll.y < -0.1 or self.scroll.viewport.y < before - 0.5) self.follow_tail = false;
                    if (self.follow_tail) self.scroll.viewport.y = self.scroll.scrollMax(.vertical);
                    const top = visibleRows(indices.len, self.scroll.viewport.y, 0).first;
                    if (top < indices.len) {
                        self.anchor = lines[indices[top]].id;
                        self.anchor_fraction = @max(0, self.scroll.viewport.y) - @as(f32, @floatFromInt(top)) * row_height;
                    } else self.anchor = null;
                }
                const visible = visibleRows(count, self.scroll.viewport.y, self.scroll.viewport.h);
                for (indices[visible.first..visible.end], visible.first..) |index, row| self.drawLine(lines[index], row);
                if (count == 0) dvui.labelNoFmt(@src(), if (lines.len == 0) "No retained output" else "No matching lines", .{}, .{ .padding = R.all(16), .color_text = .{ .color = theme.muted } });
            }
        }
        try self.status(controller, count);
    }

    fn header(self: *View, controller: *game_launch.Controller) void {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .min_size_content = .{ .h = 36 }, .padding = R.all(0), .margin = .{ .h = 4 } });
        defer row.deinit();
        dvui.labelNoFmt(@src(), if (self.follow_tail) "Live output" else "Retained output", .{ .align_y = 0.5 }, .{ .font = dvui.themeGet().font_heading, .background = false, .margin = .{ .w = 12 } });
        dvui.labelNoFmt(@src(), if (self.follow_tail) "Following latest" else "Scroll paused", .{ .align_y = 0.5 }, .{ .color_text = .{ .color = if (self.follow_tail) theme.accent else theme.muted }, .background = false, .padding = R.all(0), .margin = R.all(0) });
        dvui.label(@src(), "{d} errors", .{controller.logBuffer().errorIds().len}, .{ .gravity_x = 1, .gravity_y = 0.5, .color_text = .{ .color = severityColor(.@"error") }, .background = false, .padding = R.all(0), .margin = .{ .w = 8 } });
    }

    fn filterBar(self: *View) bool {
        var changed = false;
        components.section(@src(), "Sources");
        inline for (.{ "stdout", "stderr" }, 0..) |name, i| {
            changed = dvui.checkbox(@src(), &self.filters.sources[i], name, .{ .id_extra = i, .expand = .horizontal, .padding = R.all(6), .margin = R.all(0) }) or changed;
        }
        components.section(@src(), "Severity");
        inline for (.{ "Trace", "Debug", "Info", "Warning", "Error", "Fatal" }, 0..) |name, i| {
            changed = dvui.checkbox(@src(), &self.filters.severities[i], name, .{ .id_extra = i, .expand = .horizontal, .font = dvui.Font.theme(.mono).withSize(13), .color_text = .{ .color = severityColor(@enumFromInt(i)) }, .padding = R.all(6), .margin = R.all(0) }) or changed;
        }
        return changed;
    }

    fn searchBar(self: *View, buffer: *const logs.Buffer) void {
        const column = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = R.all(0), .margin = R.all(0) });
        defer column.deinit();
        const entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = &self.query }, .placeholder = "Search logs" }, .{ .label = .{ .text = "Search logs" }, .expand = .horizontal, .min_size_content = .{ .h = 20 }, .padding = R.all(6), .margin = R.all(0), .corners = .all(4) });
        const changed = entry.text_changed;
        const empty = entry.getText().len == 0;
        entry.deinit();
        if (changed) {
            self.cursor = null;
            self.search_status = .none;
            if (!empty) self.search(buffer, .forward);
        }
        const navigation = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = R.all(0), .margin = .{ .y = 4 } });
        defer navigation.deinit();
        if (tool(@src(), "Previous match", dvui.entypo.chevron_up, empty)) self.search(buffer, .backward);
        if (tool(@src(), "Next match", dvui.entypo.chevron_down, empty)) self.search(buffer, .forward);
        dvui.labelNoFmt(@src(), "Previous / next match", .{ .align_y = 0.5 }, .{ .font = dvui.themeGet().font_body.withSize(12), .color_text = .{ .color = theme.muted }, .background = false, .padding = R.all(0), .margin = .{ .x = 4 } });
    }

    fn search(self: *View, buffer: *const logs.Buffer, direction: logs.Direction) void {
        const query = std.mem.sliceTo(&self.query, 0);
        var start: ?logs.Cursor = null;
        if (self.cursor) |cursor| {
            start = nextCursor(cursor, direction == .forward);
            if (start == null) {
                self.search_status = .boundary;
                return;
            }
        }
        while (buffer.find(query, start, direction)) |hit| {
            const line = buffer.get(hit.id) orelse break;
            if (self.filters.accepts(line.*)) {
                self.cursor = hit;
                self.selected = hit.id;
                self.jump = hit.id;
                self.follow_tail = false;
                self.search_status = .found;
                return;
            }
            // Skip hidden lines as a whole, not one match at a time.
            start = if (direction == .forward)
                .{ .id = hit.id, .byte_offset = std.math.maxInt(usize) }
            else if (hit.id > 0) .{ .id = hit.id - 1, .byte_offset = std.math.maxInt(usize) } else null;
            if (start == null) break;
        }
        self.search_status = if (self.cursor == null) .no_match else .boundary;
    }

    fn drawLine(self: *View, line: logs.Line, row: usize) void {
        var button: dvui.ButtonWidget = undefined;
        const selected = self.selected != null and self.selected.? == line.id;
        const matched = self.cursor != null and self.cursor.?.id == line.id;
        button.init(@src(), .{}, .{ .id_extra = @intCast(line.id), .rect = .{ .x = 0, .y = @as(f32, @floatFromInt(row)) * row_height, .w = self.scroll.virtual_size.w, .h = row_height }, .padding = R.all(0), .margin = R.all(0), .border = R.all(0), .corners = .all(0), .color_fill = .{ .color = if (selected) dvui.Color.fromHex("38483C") else if (matched) dvui.Color.fromHex("323D35") else theme.background }, .label = .{ .text = "Log line" } });
        defer button.deinit();
        button.processEvents();
        button.drawBackground();
        const opts: dvui.Options = .{ .font = dvui.Font.theme(.mono).withSize(13), .background = false, .padding = R.all(0), .margin = R.all(0), .role = .none };
        dvui.labelNoFmt(@src(), if (line.source == .stdout) "OUT" else "ERR", .{ .align_y = 0.5 }, opts.override(.{ .rect = .{ .x = 6, .y = 0, .w = 32, .h = row_height }, .color_text = .{ .color = if (line.source == .stdout) theme.muted else dvui.Color.fromHex("E2AF80") } }));
        dvui.labelNoFmt(@src(), @tagName(line.severity), .{ .align_y = 0.5 }, opts.override(.{ .rect = .{ .x = 44, .y = 0, .w = 48, .h = row_height }, .color_text = .{ .color = severityColor(line.severity) } }));
        dvui.labelNoFmt(@src(), if (line.truncated) "CUT" else if (line.invalid_utf8) "UTF" else "", .{ .align_y = 0.5 }, opts.override(.{ .rect = .{ .x = 98, .y = 0, .w = 28, .h = row_height }, .color_text = .{ .color = theme.muted } }));
        dvui.labelNoFmt(@src(), line.text, .{ .align_y = 0.5 }, opts.override(.{ .rect = .{ .x = 132, .y = 0, .w = self.scroll.virtual_size.w - 132, .h = row_height }, .color_text = .{ .color = severityColor(line.severity) } }));
        button.drawFocus();
        if (button.clicked()) self.selected = line.id;
    }

    fn errorRail(self: *View, buffer: *const logs.Buffer, indices: []const usize, height: f32) !void {
        if (indices.len == 0 or height < 6) return;
        const bins: usize = @intFromFloat(@min(@as(f32, marker_limit), @floor(height / 6)));
        var ids: [marker_limit]?u64 = @splat(null);
        for (buffer.errorIds()) |id| {
            const position = buffer.position(id) orelse continue;
            const row = rankOf(indices, position) orelse continue;
            const bin = markerBin(row, indices.len, bins);
            if (ids[bin] == null) ids[bin] = id;
        }
        for (ids[0..bins], 0..) |maybe_id, bin| {
            const id = maybe_id orelse continue;
            const name = try std.fmt.allocPrint(dvui.currentWindow().arena(), "Error line {d}", .{id});
            var marker: dvui.ButtonWidget = undefined;
            marker.init(@src(), .{}, .{ .id_extra = bin, .rect = .{ .x = 2, .y = @as(f32, @floatFromInt(bin)) * height / @as(f32, @floatFromInt(bins)), .w = 8, .h = 5 }, .padding = R.all(0), .margin = R.all(0), .border = R.all(0), .corners = .all(0), .color_fill = .{ .color = severityColor(.@"error") }, .label = .{ .text = name } });
            marker.processEvents();
            marker.drawBackground();
            marker.drawFocus();
            components.tooltip(@src(), marker.data().id, marker.data().borderRectScale().r, name);
            if (marker.clicked()) {
                self.selected = id;
                self.jump = id;
                self.follow_tail = false;
            }
            marker.deinit();
        }
    }

    fn copySelected(self: *View, buffer: *const logs.Buffer) void {
        const line = buffer.get(self.selected orelse return) orelse return;
        const text = utf8Prefix(line.text, clipboard_limit);
        dvui.clipboardTextSet(text);
        self.copy_status = if (text.len < line.text.len) .limited else .copied;
    }

    fn copyRetained(self: *View, buffer: *const logs.Buffer) void {
        const arena = dvui.currentWindow().arena();
        const memory = arena.alloc(u8, clipboard_limit) catch return;
        var used: usize = 0;
        var limited = false;
        for (buffer.lines()) |line| {
            if (used == memory.len) {
                limited = true;
                break;
            }
            const text = utf8Prefix(line.text, memory.len - used - 1);
            @memcpy(memory[used..][0..text.len], text);
            used += text.len;
            memory[used] = '\n';
            used += 1;
            if (text.len != line.text.len) {
                limited = true;
                break;
            }
        }
        dvui.clipboardTextSet(memory[0..used]);
        self.copy_status = if (limited) .limited else .copied;
    }

    fn status(_: *View, controller: *game_launch.Controller, visible_count: usize) !void {
        const buffer = controller.logBuffer();
        const snap = controller.snapshot();
        const health = controller.logStatus();
        const arena = dvui.currentWindow().arena();
        const summary = try std.fmt.allocPrint(arena, "{s}  {s}  {d}/{d} lines  {d} KiB  {d} errors  omitted {d}", .{ @tagName(snap.phase), snap.version_id orelse "", visible_count, buffer.lineCount(), buffer.byteCount() / 1024, buffer.errorIds().len, health.dropped_packets });
        statusText(@src(), summary, theme.muted, .{ .y = 4 }, 0);
        const failures = .{ health.disk_failure, health.capture_failure, health.view_failure, snap.failure };
        inline for (.{ "Disk", "Capture", "View", "Launch" }, 0..) |name, i| {
            if (failures[i]) |failure| {
                const text = try std.fmt.allocPrint(arena, "{s}: {s}", .{ name, @errorName(failure) });
                statusText(@src(), text, severityColor(.@"error"), R.all(0), i);
            }
        }
        if (snap.exit_code) |code| dvui.label(@src(), "Exit code: {d}", .{code}, .{ .color_text = .{ .color = theme.muted }, .padding = R.all(0) });
    }
};

fn statusText(src: std.builtin.SourceLocation, text: []const u8, color: dvui.Color, margin: R, id: usize) void {
    const layout = dvui.textLayout(src, .{}, .{ .id_extra = id, .expand = .horizontal, .max_size_content = .width(0), .font = dvui.Font.theme(.mono).withSize(12), .color_text = .{ .color = color }, .background = false, .padding = R.all(0), .margin = margin });
    layout.addText(text, .{});
    layout.deinit();
}

fn tool(src: std.builtin.SourceLocation, name: []const u8, asset: []const u8, disabled: bool) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{ .grayed = disabled }, .{ .min_size_content = .{ .w = 18, .h = 18 }, .padding = R.all(6), .margin = R.all(0), .corners = .all(4), .border = R.all(0), .label = .{ .text = name }, .tab_index = if (disabled) 0 else null });
    defer button.deinit();
    if (!disabled) button.processEvents();
    button.drawBackground();
    dvui.icon(@src(), name, asset, .{}, button.style().override(.{ .min_size_content = .{ .w = 18, .h = 18 }, .padding = R.all(0), .margin = R.all(0), .gravity_x = 0.5, .gravity_y = 0.5, .role = .none }));
    if (!disabled) button.drawFocus();
    components.tooltip(src, button.data().id, button.data().borderRectScale().r, name);
    return !disabled and button.clicked();
}

fn severityColor(severity: logs.Severity) dvui.Color {
    return switch (severity) {
        .trace, .debug => theme.muted,
        .info => dvui.Color.fromHex("EDF1EA"),
        .warn => dvui.Color.fromHex("EAC985"),
        .@"error" => dvui.Color.fromHex("F0A6A1"),
        .fatal => dvui.Color.fromHex("FF7E89"),
    };
}

fn visibleRows(count: usize, offset: f32, height: f32) struct { first: usize, end: usize } {
    const first: usize = @intFromFloat(@min(@as(f32, @floatFromInt(count)), @floor(@max(0, offset) / row_height)));
    const end: usize = @intFromFloat(@min(@as(f32, @floatFromInt(count)), @ceil((@max(0, offset) + @max(0, height)) / row_height) + 1));
    return .{ .first = first, .end = @max(first, end) };
}

fn rankOf(indices: []const usize, position: usize) ?usize {
    var left: usize = 0;
    var right = indices.len;
    while (left < right) {
        const middle = left + (right - left) / 2;
        if (indices[middle] < position) left = middle + 1 else right = middle;
    }
    return if (left < indices.len and indices[left] == position) left else null;
}

fn rowForId(lines: anytype, indices: []const usize, id: u64) ?usize {
    var left: usize = 0;
    var right = indices.len;
    while (left < right) {
        const middle = left + (right - left) / 2;
        if (lines[indices[middle]].id < id) left = middle + 1 else right = middle;
    }
    return if (left < indices.len and lines[indices[left]].id == id) left else null;
}

fn markerBin(row: usize, count: usize, bins: usize) usize {
    if (count == 0 or bins == 0) return 0;
    return @min(bins - 1, row * bins / count);
}

fn nextCursor(cursor: anytype, forward: bool) ?@TypeOf(cursor) {
    if (forward) {
        if (cursor.byte_offset == std.math.maxInt(usize)) return null;
        return .{ .id = cursor.id, .byte_offset = cursor.byte_offset + 1 };
    }
    if (cursor.byte_offset > 0) return .{ .id = cursor.id, .byte_offset = cursor.byte_offset - 1 };
    if (cursor.id == 0) return null;
    return .{ .id = cursor.id - 1, .byte_offset = std.math.maxInt(usize) };
}

fn utf8Prefix(text: []const u8, limit: usize) []const u8 {
    var end = @min(text.len, limit);
    while (end > 0 and end < text.len and text[end] & 0xc0 == 0x80) end -= 1;
    return text[0..end];
}

test "source and severity filters compose without excluding unknown info" {
    const Source = enum { stdout, stderr };
    const Severity = enum { trace, debug, info, warn, @"error", fatal };
    const Line = struct { source: Source, severity: Severity };
    var filter: Filters = .{};
    try std.testing.expect(filter.accepts(Line{ .source = .stdout, .severity = .info }));
    filter.sources[1] = false;
    try std.testing.expect(!filter.accepts(Line{ .source = .stderr, .severity = .fatal }));
    filter.severities[4] = false;
    try std.testing.expect(!filter.accepts(Line{ .source = .stdout, .severity = .@"error" }));
    try std.testing.expect(filter.accepts(Line{ .source = .stdout, .severity = .warn }));
}

test "virtual rows stay bounded and handle empty, overscroll and partial rows" {
    const empty = visibleRows(0, 0, 300);
    try std.testing.expectEqual(@as(usize, 0), empty.end);
    const rows = visibleRows(10_000, 2400, 480);
    try std.testing.expectEqual(@as(usize, 100), rows.first);
    try std.testing.expectEqual(@as(usize, 121), rows.end);
    const partial = visibleRows(10, -20, 25);
    try std.testing.expectEqual(@as(usize, 0), partial.first);
    try std.testing.expectEqual(@as(usize, 3), partial.end);
    const past = visibleRows(10, 10000, 480);
    try std.testing.expectEqual(@as(usize, 10), past.first);
    try std.testing.expectEqual(@as(usize, 10), past.end);
}

test "stable IDs and filtered positions do not alias evicted or hidden lines" {
    const Line = struct { id: u64 };
    const lines = [_]Line{ .{ .id = 41 }, .{ .id = 42 }, .{ .id = 43 }, .{ .id = 44 } };
    const indices = [_]usize{ 0, 2, 3 };
    try std.testing.expectEqual(@as(?usize, 1), rowForId(&lines, &indices, 43));
    try std.testing.expect(rowForId(&lines, &indices, 42) == null);
    try std.testing.expect(rowForId(&lines, &indices, 40) == null);
    try std.testing.expect(rowForId(&lines, &indices, 99) == null);
    try std.testing.expectEqual(@as(?usize, 2), rankOf(&indices, 3));
    try std.testing.expect(rankOf(&indices, 1) == null);
    try std.testing.expect(rankOf(&.{}, 0) == null);
}

test "error marker bins map first and last current positions" {
    try std.testing.expectEqual(@as(usize, 0), markerBin(0, 10_000, 128));
    try std.testing.expectEqual(@as(usize, 127), markerBin(9999, 10_000, 128));
    try std.testing.expectEqual(@as(usize, 64), markerBin(5000, 10_000, 128));
    try std.testing.expectEqual(@as(usize, 0), markerBin(0, 0, 0));
}

test "inclusive searches advance without repeating first-byte matches" {
    const Cursor = struct { id: u64, byte_offset: usize = 0 };
    try std.testing.expectEqual(Cursor{ .id = 8, .byte_offset = 4 }, nextCursor(Cursor{ .id = 8, .byte_offset = 3 }, true).?);
    try std.testing.expectEqual(Cursor{ .id = 7, .byte_offset = std.math.maxInt(usize) }, nextCursor(Cursor{ .id = 8 }, false).?);
    try std.testing.expect(nextCursor(Cursor{ .id = 0 }, false) == null);
}

test "bounded clipboard prefixes never split UTF-8" {
    const text = "a\xc3\xa9z";
    try std.testing.expectEqualStrings("a", utf8Prefix(text, 2));
    try std.testing.expectEqualStrings("a\xc3\xa9", utf8Prefix(text, 3));
    try std.testing.expectEqualStrings(text, utf8Prefix(text, 100));
    try std.testing.expectEqualStrings("", utf8Prefix(text, 0));
}

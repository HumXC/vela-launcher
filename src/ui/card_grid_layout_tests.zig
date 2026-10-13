//! Renderer regressions for the shared explicit card grid.
const std = @import("std");
const dvui = @import("dvui");
const card_grid = @import("card_grid.zig");
const components = @import("components.zig");

const tolerance: f32 = 0.1;
const gap: f32 = 12;
const capacity = 16;

const Snapshot = struct {
    track: dvui.Rect.Physical,
    cards: [capacity]dvui.TagData = undefined,
    count: usize,
};

fn expectRect(expected: dvui.Rect.Physical, actual: dvui.Rect.Physical) !void {
    errdefer std.debug.print("grid rect: expected={any}, actual={any}\n", .{ expected, actual });
    try std.testing.expectApproxEqAbs(expected.x, actual.x, tolerance);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, tolerance);
    try std.testing.expectApproxEqAbs(expected.w, actual.w, tolerance);
    try std.testing.expectApproxEqAbs(expected.h, actual.h, tolerance);
}

fn expectGrid(snapshot: Snapshot, columns: usize) !void {
    errdefer std.debug.print("grid geometry: columns={d}, track={any}, cards={any}\n", .{ columns, snapshot.track, snapshot.cards[0..snapshot.count] });
    if (snapshot.count == 0) return;
    try std.testing.expect(columns > 0);
    const width = snapshot.cards[0].rect.w;
    var row_start: usize = 0;
    var previous_bottom: ?f32 = null;
    while (row_start < snapshot.count) : (row_start += columns) {
        const row_end = @min(row_start + columns, snapshot.count);
        const first = snapshot.cards[row_start].rect;
        try std.testing.expectApproxEqAbs(snapshot.track.x, first.x, tolerance);
        if (previous_bottom) |bottom| {
            try std.testing.expectApproxEqAbs(gap, first.y - bottom, tolerance);
        } else {
            try std.testing.expectApproxEqAbs(snapshot.track.y, first.y, tolerance);
        }
        for (row_start..row_end) |index| {
            const rect = snapshot.cards[index].rect;
            try std.testing.expect(rect.w > 0 and rect.h > 0);
            // Pixel-aligned columns distribute at most one pixel of remainder.
            try std.testing.expect(@abs(width - rect.w) <= 1 + tolerance);
            if (index >= columns) {
                const same_column = snapshot.cards[index % columns].rect;
                try std.testing.expectApproxEqAbs(same_column.x, rect.x, tolerance);
                try std.testing.expectApproxEqAbs(same_column.w, rect.w, tolerance);
            }
            try std.testing.expectApproxEqAbs(first.y, rect.y, tolerance);
            try std.testing.expectApproxEqAbs(first.y + first.h, rect.y + rect.h, tolerance);
            try std.testing.expect(rect.x >= snapshot.track.x - tolerance);
            try std.testing.expect(rect.x + rect.w <= snapshot.track.x + snapshot.track.w + tolerance);
            if (index > row_start) {
                const previous = snapshot.cards[index - 1].rect;
                try std.testing.expectApproxEqAbs(gap, rect.x - previous.x - previous.w, tolerance);
            }
        }
        if (row_end - row_start == columns) {
            const last = snapshot.cards[row_end - 1].rect;
            try std.testing.expectApproxEqAbs(snapshot.track.x + snapshot.track.w, last.x + last.w, tolerance);
        }
        previous_bottom = first.y + first.h;
    }
}

fn expectSameGeometry(expected: Snapshot, actual: Snapshot) !void {
    try std.testing.expectEqual(expected.count, actual.count);
    try expectRect(expected.track, actual.track);
    for (0..actual.count) |index| try expectRect(expected.cards[index].rect, actual.cards[index].rect);
}

const keys = [_][]const u8{
    "grid-card-a", "grid-card-b", "grid-card-c", "grid-card-d",
    "grid-card-e", "grid-card-f", "grid-card-g", "grid-card-h",
    "grid-card-i", "grid-card-j", "grid-card-k", "grid-card-l",
    "grid-card-m", "grid-card-n", "grid-card-o", "grid-card-p",
};
const long_text = "A deliberately long description with enough distinct words to wrap onto several lines at narrow card widths. It changes the natural height of this card while its short neighbours retain just one description line.";

const Frame = struct {
    var count: usize = 5;
    var max_columns: usize = 3;
    var min_width: f32 = 220;
    var long_mask: u32 = 2;
    var order: [capacity]usize = undefined;
    var clicked: ?usize = null;
    var click_count: usize = 0;
    var track: dvui.Rect.Physical = undefined;

    fn reset(item_count: usize, column_limit: usize) void {
        count = item_count;
        max_columns = column_limit;
        min_width = 220;
        long_mask = 2;
        clicked = null;
        click_count = 0;
        for (&order, 0..) |*key, index| key.* = index;
    }

    fn draw() !dvui.App.Result {
        dvui.debug.captureScopeBegin(dvui.currentWindow().gpa);
        defer dvui.debug.captureScopeEnd();
        const root = dvui.box(@src(), .{}, .{
            .expand = .both,
            .padding = dvui.Rect.all(16),
            .margin = dvui.Rect.all(0),
            .border = dvui.Rect.all(0),
        });
        defer root.deinit();
        track = root.data().contentRectScale().r;
        {
            var grid = card_grid.init(@src(), count, .{
                .min_width = min_width,
                .max_columns = max_columns,
                .gap = gap,
                .tag = "grid-renderer",
            });
            defer grid.deinit();
            for (order[0..count], 0..) |key, index| {
                const cell = grid.cell(@src(), index, keys[key]);
                defer cell.deinit();
                const is_long = long_mask & (@as(u32, 1) << @intCast(key)) != 0;
                if (components.selectionCard(@src(), keys[key], if (is_long) long_text else "Short", .{
                    .width = grid.cardWidth(index),
                    .stretch = true,
                    .description = if (is_long) long_text else "Brief",
                    .tag = keys[key],
                })) {
                    clicked = key;
                    click_count += 1;
                }
            }
        }
        _ = dvui.spacer(@src(), .{
            .tag = "grid-after",
            .min_size_content = .{ .h = 10 },
            .padding = dvui.Rect.all(0),
            .margin = dvui.Rect.all(0),
        });
        return .ok;
    }

    fn snapshot() !Snapshot {
        var result: Snapshot = .{ .track = track, .count = count };
        for (order[0..count], 0..) |key, index| result.cards[index] = try dvui.testing.tagGet(keys[key]);
        return result;
    }
};

fn setFont(window: *dvui.testing, size: f32) void {
    var theme = dvui.Theme.builtin.adwaita_dark;
    theme.font_body = theme.font_body.withSize(size);
    theme.font_heading = theme.font_body.withSize(size);
    theme.font_title = theme.font_body.withSize(size);
    window.window.themeSet(theme);
}

fn resize(window: *dvui.testing, width: f32) !void {
    window.backend.size = .{ .w = width, .h = 4000 };
    window.backend.size_pixels = .{ .w = width, .h = 4000 };
    // begin() samples the changed backend size before the following settled frames.
    _ = try dvui.testing.step(Frame.draw);
    try dvui.testing.settle(Frame.draw);
}

fn expectFootprint(snapshot: Snapshot) !void {
    const after = try dvui.testing.tagGet("grid-after");
    const bottom = if (snapshot.count == 0) snapshot.track.y else blk: {
        const last = snapshot.cards[snapshot.count - 1].rect;
        break :blk last.y + last.h;
    };
    try std.testing.expectApproxEqAbs(bottom, after.rect.y, tolerance);
}

fn freshSnapshot(width: f32, font_size: f32) !Snapshot {
    var window = try dvui.testing.init(.{ .window_size = .{ .w = width, .h = 4000 } });
    defer window.deinit();
    window.backend.size_pixels = .{ .w = width, .h = 4000 };
    setFont(&window, font_size);
    try dvui.testing.settle(Frame.draw);
    const result = try Frame.snapshot();
    try expectFootprint(result);
    return result;
}

test "UI layout shared card grid mixed content aligns rows and partial row keeps full column width" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    for ([_]f32{ 16, 24 }) |font_size| {
        Frame.reset(5, 3);
        const mixed = try freshSnapshot(1000, font_size);
        try expectGrid(mixed, 3);
        Frame.long_mask = 0;
        const short = try freshSnapshot(1000, font_size);
        try expectGrid(short, 3);
        try std.testing.expect(mixed.cards[0].rect.h > short.cards[0].rect.h + 1);
        // A taller first row must move the next row, without changing its own natural height.
        try std.testing.expectApproxEqAbs(short.cards[3].rect.h, mixed.cards[3].rect.h, tolerance);
        try std.testing.expect(mixed.cards[3].rect.y > short.cards[3].rect.y + 1);
    }
}

test "UI layout shared card grid empty and single item leave no phantom row or trailing gap" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    Frame.reset(0, 3);
    const empty = try freshSnapshot(1000, 16);
    try std.testing.expectEqual(@as(usize, 0), empty.count);
    Frame.count = 1;
    Frame.long_mask = 0;
    const one = try freshSnapshot(1000, 16);
    try expectGrid(one, 3);
    Frame.count = 3;
    const full = try freshSnapshot(1000, 16);
    try expectGrid(full, 3);
    try expectRect(full.cards[0].rect, one.cards[0].rect);
}

test "UI layout shared card grid breakpoint sweep fills right edge and never wraps an extra card at 1982" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    const cases = [_]struct { width: f32, columns: usize }{
        .{ .width = 251, .columns = 1 },  .{ .width = 252, .columns = 1 },  .{ .width = 253, .columns = 1 },
        .{ .width = 483, .columns = 1 },  .{ .width = 484, .columns = 2 },  .{ .width = 485, .columns = 2 },
        .{ .width = 715, .columns = 2 },  .{ .width = 716, .columns = 3 },  .{ .width = 717, .columns = 3 },
        .{ .width = 947, .columns = 3 },  .{ .width = 948, .columns = 4 },  .{ .width = 949, .columns = 4 },
        .{ .width = 1179, .columns = 4 }, .{ .width = 1180, .columns = 5 }, .{ .width = 1181, .columns = 5 },
        .{ .width = 1982, .columns = 8 },
    };
    for ([_]f32{ 16, 24 }) |font_size| {
        Frame.reset(capacity, capacity);
        var window = try dvui.testing.init(.{ .window_size = .{ .w = 1000, .h = 4000 } });
        defer window.deinit();
        window.backend.size_pixels = .{ .w = 1000, .h = 4000 };
        setFont(&window, font_size);
        for (cases) |case| {
            errdefer std.debug.print("grid breakpoint: width={d}, font={d}\n", .{ case.width, font_size });
            try resize(&window, case.width);
            const snapshot = try Frame.snapshot();
            try std.testing.expectApproxEqAbs(case.width - 32, snapshot.track.w, tolerance);
            try expectGrid(snapshot, case.columns);
            try expectFootprint(snapshot);
        }
        // Sweep back through the same boundaries to exercise cached wider layouts shrinking.
        var index = cases.len;
        while (index > 0) {
            index -= 1;
            try resize(&window, cases[index].width);
            try expectGrid(try Frame.snapshot(), cases[index].columns);
            try expectFootprint(try Frame.snapshot());
        }
    }
}

test "UI layout shared card grid keyed clicks and identities survive resize reorder and removal" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    Frame.reset(5, 3);
    Frame.long_mask = 0;
    var window = try dvui.testing.init(.{ .window_size = .{ .w = 1000, .h = 4000 } });
    defer window.deinit();
    window.backend.size_pixels = .{ .w = 1000, .h = 4000 };
    setFont(&window, 16);
    try dvui.testing.settle(Frame.draw);
    const initial = try Frame.snapshot();
    for ([_]f32{ 715, 483, 1982, 1000 }) |width| {
        try resize(&window, width);
        for (0..Frame.count) |index| {
            const card = try dvui.testing.tagGet(keys[index]);
            try std.testing.expectEqual(initial.cards[index].id, card.id);
            try std.testing.expect(card.visible);
            try dvui.testing.moveTo(keys[index]);
            try dvui.testing.click(.left);
            Frame.clicked = null;
            const previous_clicks = Frame.click_count;
            try dvui.testing.settle(Frame.draw);
            try std.testing.expectEqual(@as(?usize, index), Frame.clicked);
            try std.testing.expectEqual(previous_clicks + 1, Frame.click_count);
        }
    }
    Frame.order = .{ 4, 2, 0, 3, 1, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    try dvui.testing.settle(Frame.draw);
    for (Frame.order[0..Frame.count]) |key| try std.testing.expectEqual(initial.cards[key].id, (try dvui.testing.tagGet(keys[key])).id);
    Frame.count = 3;
    try dvui.testing.settle(Frame.draw);
    for (Frame.order[0..Frame.count]) |key| {
        try std.testing.expectEqual(initial.cards[key].id, (try dvui.testing.tagGet(keys[key])).id);
        try dvui.testing.moveTo(keys[key]);
        try dvui.testing.click(.left);
        Frame.clicked = null;
        try dvui.testing.settle(Frame.draw);
        try std.testing.expectEqual(@as(?usize, key), Frame.clicked);
    }
}

test "UI layout shared card grid content updates reorder and tallest removal shrink to fresh natural heights" {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    for ([_]f32{ 16, 24 }) |font_size| {
        Frame.reset(6, 3);
        var shortened: Snapshot = undefined;
        var reordered: Snapshot = undefined;
        var removed: Snapshot = undefined;
        var enlarged_font: Snapshot = undefined;
        {
            var window = try dvui.testing.init(.{ .window_size = .{ .w = 1000, .h = 4000 } });
            defer window.deinit();
            window.backend.size_pixels = .{ .w = 1000, .h = 4000 };
            setFont(&window, font_size);
            try dvui.testing.settle(Frame.draw);
            const long = try Frame.snapshot();
            Frame.long_mask = 0;
            try dvui.testing.settle(Frame.draw);
            shortened = try Frame.snapshot();
            try expectGrid(shortened, 3);
            try expectFootprint(shortened);
            try std.testing.expect(shortened.cards[0].rect.h + 1 < long.cards[0].rect.h);
            Frame.long_mask = 2;
            Frame.order = .{ 0, 2, 3, 1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
            try dvui.testing.settle(Frame.draw);
            reordered = try Frame.snapshot();
            try expectGrid(reordered, 3);
            try expectFootprint(reordered);
            try std.testing.expect(reordered.cards[0].rect.h + 1 < long.cards[0].rect.h);
            try std.testing.expect(reordered.cards[3].rect.h > reordered.cards[0].rect.h + 1);
            Frame.order = .{ 0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 1 };
            Frame.count = 5;
            try dvui.testing.settle(Frame.draw);
            removed = try Frame.snapshot();
            try expectGrid(removed, 3);
            try expectFootprint(removed);
            try std.testing.expect(removed.cards[3].rect.h + 1 < reordered.cards[3].rect.h);
            setFont(&window, if (font_size == 16) 24 else 16);
            try dvui.testing.settle(Frame.draw);
            enlarged_font = try Frame.snapshot();
            try expectGrid(enlarged_font, 3);
            try expectFootprint(enlarged_font);
        }
        try expectSameGeometry(enlarged_font, try freshSnapshot(1000, if (font_size == 16) 24 else 16));
        try expectSameGeometry(removed, try freshSnapshot(1000, font_size));
        Frame.count = 6;
        Frame.order = .{ 0, 2, 3, 1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
        try expectSameGeometry(reordered, try freshSnapshot(1000, font_size));
        Frame.long_mask = 0;
        for (&Frame.order, 0..) |*key, index| key.* = index;
        try expectSameGeometry(shortened, try freshSnapshot(1000, font_size));
    }
}

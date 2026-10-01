const std = @import("std");
const dvui = @import("dvui");

pub const max_bytes = 512;
pub const Status = enum { empty, ready, invalid_input, too_long };
pub const Result = struct {
    edited: bool = false,
    submit: bool = false,
    cancel: bool = false,
    status: Status = .empty,
};

/// Keep at a stable address after first use. Never preload a stored credential.
/// The caller must reset after Save completion/rejection, navigation, or Cancel.
/// Only this buffer, its tails, and consumed mutable text events are wiped here;
/// SDL/AccessKit/IME input storage and backend logging are outside this module.
pub const Editor = struct {
    bytes: [max_bytes + 1]u8 = @splat(0),
    len: usize = 0,
    address: ?usize = null,
    status: Status = .empty,

    pub fn reset(self: *Editor) void {
        self.pin();
        std.crypto.secureZero(u8, &self.bytes);
        self.len = 0;
        self.status = .empty;
    }

    pub fn deinit(self: *Editor) void {
        self.reset();
    }

    /// Borrow only until the next edit/reset. Copy into an owned job before reset.
    pub fn borrowForSave(self: *const Editor) error{InvalidKey}![]const u8 {
        self.checkAddress();
        if (self.len == 0 or self.len > max_bytes or !printable(self.bytes[0..self.len]))
            return error.InvalidKey;
        return self.bytes[0..self.len];
    }

    pub fn draw(self: *Editor, src: std.builtin.SourceLocation, opts: dvui.Options) Result {
        _ = src;
        var entry: dvui.TextEntryWidget = undefined;
        self.initEntry(&entry, opts);
        defer self.finishEntry(&entry);
        var result: Result = .{};
        for (dvui.events()) |*event| {
            // matchEvent has passive touch side effects even for handled events.
            const matched = entry.matchEvent(event);
            lockExports(&entry);
            if (!matched) continue;
            if (result.cancel) {
                discard(&entry, event);
            } else {
                self.dispatch(&entry, event, &result);
            }
            self.sync(&entry);
        }
        if (result.cancel) {
            self.reset();
            entry.setLen(0);
            entry.textLayout.selection.* = .{};
        }
        self.sync(&entry);
        entry.draw();
        lockExports(&entry);
        // Replace TextLayout's teardown cursor loop without its passive matching.
        for (dvui.events()) |*event| {
            if (event.evt == .mouse and event.evt.mouse.action == .position and
                dvui.eventMatchSimple(event, entry.textLayout.data()))
                dvui.cursorSet(.ibeam);
        }
        result.edited = entry.text_changed or result.cancel;
        result.submit = entry.enter_pressed and !result.cancel;
        result.status = self.status;
        return result;
    }

    fn initEntry(self: *Editor, entry: *dvui.TextEntryWidget, opts: dvui.Options) void {
        self.pin();
        self.wipeTail();
        var safe = opts;
        // A module-owned source location plus the stable instance address cannot
        // inherit an ordinary text entry's persisted touch toolbar state.
        safe.id_extra = @intFromPtr(self);
        safe.role = .password_input;
        safe.name = "CurseForgeKeyEditor";
        safe.tag = null;
        safe.label = .{ .text = "CurseForge API key" };
        entry.init(@src(), .{
            .text = .{ .buffer = self.bytes[0..max_bytes] },
            .password_char = "*",
            .multiline = false,
            .placeholder = null,
            .cache_layout = false,
            .tree_sitter = null,
        }, safe);
        lockExports(entry);
        if (dvui.accesskit_enabled) {
            if (entry.data().accesskit_node()) |node| {
                dvui.AccessKit.nodeClearValue(node);
                inline for (unsupported_actions) |name|
                    dvui.AccessKit.nodeRemoveAction(node, @field(dvui.AccessKit.Action, name));
            }
        }
    }

    fn finishEntry(self: *Editor, entry: *dvui.TextEntryWidget) void {
        self.sync(entry);
        // Disable teardown's matchEvent loop BEFORE it can re-enable context.
        // TextLayout then persists false, blocking next init's copy/cut toolbar.
        lockExports(entry);
        entry.deinit();
    }

    fn dispatch(self: *Editor, entry: *dvui.TextEntryWidget, event: *dvui.Event, result: *Result) void {
        defer lockExports(entry);
        switch (event.evt) {
            .key => |key| {
                if (key.matchBind("copy") or key.matchBind("cut")) {
                    event.handle(@src(), entry.data());
                    return;
                }
                if (key.matchBind("paste")) {
                    event.handle(@src(), entry.data());
                    if (key.action == .down) self.insert(entry, dvui.clipboardText(), false);
                    return;
                }
                if (key.code == .escape and key.action == .down) {
                    event.handle(@src(), entry.data());
                    result.cancel = true;
                    return;
                }
            },
            .text => |text| switch (text.action) {
                .value => |value| {
                    defer std.crypto.secureZero(u8, value.txt);
                    event.handle(@src(), entry.data());
                    self.insert(entry, value.txt, value.selected);
                    return;
                },
                .selection => {},
            },
            .mouse => |mouse| {
                if (mouse.action == .press and mouse.button == .middle) {
                    event.handle(@src(), entry.data());
                    dvui.focusWidget(entry.data().id, null, event.num);
                    self.insert(entry, dvui.primarySelectionText(), false);
                    return;
                }
            },
            else => {},
        }
        entry.processEvent(event);
    }

    fn insert(self: *Editor, entry: *dvui.TextEntryWidget, input: []const u8, selected: bool) void {
        if (!printable(input)) {
            self.status = .invalid_input;
            return;
        }
        const selection = entry.textLayout.selectionGet(entry.len);
        if (selection.end < selection.start) {
            self.status = .invalid_input;
            return;
        }
        const remaining = entry.len - (selection.end - selection.start);
        if (input.len > max_bytes - remaining) {
            self.status = .too_long;
            return;
        }
        // Validation precedes DVUI's selection deletion, CR/LF stripping and
        // capacity truncation, so rejected replacements leave the key intact.
        entry.textTyped(input, selected);
        self.status = if (entry.len == 0) .empty else .ready;
        self.sync(entry);
    }

    fn sync(self: *Editor, entry: *const dvui.TextEntryWidget) void {
        self.len = entry.len;
        self.wipeTail();
        if (self.status == .ready and self.len == 0) self.status = .empty;
    }

    fn wipeTail(self: *Editor) void {
        std.crypto.secureZero(u8, self.bytes[self.len..]);
    }

    fn pin(self: *Editor) void {
        self.checkAddress();
        self.address = @intFromPtr(self);
    }

    fn checkAddress(self: *const Editor) void {
        if (self.address) |address| {
            if (address != @intFromPtr(self)) @panic("credential editor moved after first use");
        }
    }
};

const unsupported_actions = [_][]const u8{
    "replace_selected_text",
    "scroll_into_view",
    "show_context_menu",
    "custom_action",
};

fn lockExports(entry: *dvui.TextEntryWidget) void {
    entry.textLayout.te_show_context_menu = false;
    entry.textLayout.process_events_in_deinit = false;
}

fn discard(entry: *dvui.TextEntryWidget, event: *dvui.Event) void {
    if (event.evt == .text and event.evt.text.action == .value)
        std.crypto.secureZero(u8, event.evt.text.action.value.txt);
    event.handle(@src(), entry.data());
}

fn printable(input: []const u8) bool {
    for (input) |byte| if (byte < 33 or byte > 126) return false;
    return true;
}

fn testAdvance(fixture: *dvui.testing) !void {
    _ = try fixture.window.end(.{});
    try fixture.window.begin(fixture.window.frame_time_ns + 100 * std.time.ns_per_ms);
}

fn testKey(entry: *dvui.TextEntryWidget, code: dvui.enums.Key, mod: dvui.enums.Mod) dvui.Event {
    return .{ .target_widgetId = entry.data().id, .evt = .{ .key = .{
        .code = code,
        .mod = mod,
        .action = .down,
    } } };
}

fn testDispatch(editor: *Editor, entry: *dvui.TextEntryWidget, event: *dvui.Event) !void {
    const matched = entry.matchEvent(event);
    lockExports(entry);
    try std.testing.expect(matched);
    var result: Result = .{};
    editor.dispatch(entry, event, &result);
    editor.sync(entry);
}

fn testZeros(bytes: []const u8) !void {
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "CF key editor validates full ASCII range and save boundary" {
    var editor: Editor = .{};
    defer editor.deinit();
    try std.testing.expectError(error.InvalidKey, editor.borrowForSave());
    for (0..256) |value| {
        const byte = [_]u8{@intCast(value)};
        try std.testing.expectEqual(value >= 33 and value <= 126, printable(&byte));
    }
    var fixture = try dvui.testing.init(.{});
    defer fixture.deinit();
    var entry: dvui.TextEntryWidget = undefined;
    editor.initEntry(&entry, .{});
    defer editor.finishEntry(&entry);
    const full: [max_bytes]u8 = @splat('K');
    editor.insert(&entry, &full, false);
    try std.testing.expectEqual(max_bytes, entry.len);
    try std.testing.expectEqualStrings(&full, try editor.borrowForSave());
    try testZeros(editor.bytes[max_bytes..]);
    editor.insert(&entry, "X", false);
    try std.testing.expectEqual(Status.too_long, editor.status);
    try std.testing.expectEqualStrings(&full, try editor.borrowForSave());
    entry.textLayout.selection.* = .{ .start = 0, .cursor = max_bytes, .end = max_bytes };
    const oversized: [max_bytes + 1]u8 = @splat('Z');
    editor.insert(&entry, &oversized, false);
    try std.testing.expectEqualStrings(&full, try editor.borrowForSave());
    try std.testing.expectEqual(@as(usize, 0), entry.textLayout.selection.start);
    editor.insert(&entry, "ValidReplacement", false);
    try std.testing.expectEqualStrings("ValidReplacement", try editor.borrowForSave());
    try testZeros(editor.bytes[editor.len..]);
    entry.draw();
}

test "CF key editor rejects invalid replacements and wipes consumed events" {
    var fixture = try dvui.testing.init(.{});
    defer fixture.deinit();
    var editor: Editor = .{};
    defer editor.deinit();
    var entry: dvui.TextEntryWidget = undefined;
    editor.initEntry(&entry, .{});
    defer editor.finishEntry(&entry);
    editor.insert(&entry, "OwnedCanary!", false);
    const invalid = [_][]const u8{ "bad key", "bad\rkey", "bad\nkey", "bad\tkey", "bad\x00key", "bad\xc3\xa9" };
    for (invalid) |input| {
        entry.textLayout.selection.* = .{ .start = 0, .end = entry.len, .cursor = entry.len };
        var buffer: [40]u8 = @splat(0);
        @memcpy(buffer[0..input.len], input);
        var event: dvui.Event = .{ .target_widgetId = entry.data().id, .evt = .{ .text = .{
            .action = .{ .value = .{ .txt = buffer[0..input.len], .selected = false } },
        } } };
        try testDispatch(&editor, &entry, &event);
        try std.testing.expect(event.handled);
        try testZeros(buffer[0..input.len]);
        try std.testing.expectEqual(Status.invalid_input, editor.status);
        try std.testing.expectEqualStrings("OwnedCanary!", try editor.borrowForSave());
    }
    var accepted = "FreshCanary!".*;
    var event: dvui.Event = .{ .target_widgetId = entry.data().id, .evt = .{ .text = .{
        .action = .{ .value = .{ .txt = &accepted, .selected = true } },
    } } };
    try testDispatch(&editor, &entry, &event);
    try testZeros(&accepted);
    try std.testing.expectEqualStrings("FreshCanary!", try editor.borrowForSave());
    try std.testing.expectEqual(editor.len, entry.textLayout.selection.end);
    entry.draw();
}

test "CF key editor copy cut aliases never change clipboard or selection" {
    var fixture = try dvui.testing.init(.{});
    defer fixture.deinit();
    try fixture.backend.clipboardTextSet("PublicClipboard");
    var editor: Editor = .{};
    defer editor.deinit();
    var entry: dvui.TextEntryWidget = undefined;
    editor.initEntry(&entry, .{});
    defer editor.finishEntry(&entry);
    editor.insert(&entry, "ExportCanary!", false);
    entry.textLayout.selection.* = .{ .start = 0, .cursor = entry.len, .end = entry.len };
    // Exercise a chained cut alias as well as DVUI's existing copy alias.
    var cut = fixture.window.keybinds.get("cut").?;
    cut.also = "test_cut_alias";
    try fixture.window.keybinds.put(fixture.window.gpa, "cut", cut);
    try fixture.window.keybinds.put(fixture.window.gpa, "test_cut_alias", .{ .key = .delete, .shift = true });
    const keys = [_]dvui.Event.Key{
        .{ .code = .c, .mod = .lcontrol, .action = .down },
        .{ .code = .x, .mod = .lcontrol, .action = .down },
        .{ .code = .insert, .mod = .lcontrol, .action = .down },
        .{ .code = .delete, .mod = .lshift, .action = .down },
    };
    for (keys) |key| {
        var event: dvui.Event = .{ .target_widgetId = entry.data().id, .evt = .{ .key = key } };
        try std.testing.expect(key.matchBind("copy") or key.matchBind("cut"));
        try testDispatch(&editor, &entry, &event);
        try std.testing.expect(event.handled);
        try std.testing.expectEqualStrings("PublicClipboard", fixture.backend.clipboard.?);
        try std.testing.expectEqualStrings("ExportCanary!", try editor.borrowForSave());
        try std.testing.expectEqual(editor.len, entry.textLayout.selection.end);
    }
    entry.draw();
}

test "CF key editor validated paste preserves navigation and deletion" {
    var fixture = try dvui.testing.init(.{});
    defer fixture.deinit();
    var editor: Editor = .{};
    defer editor.deinit();
    var entry: dvui.TextEntryWidget = undefined;
    editor.initEntry(&entry, .{});
    defer editor.finishEntry(&entry);
    try fixture.backend.clipboardTextSet("PasteCanary!");
    var paste = testKey(&entry, .insert, .lshift);
    try std.testing.expect(paste.evt.key.matchBind("paste"));
    try testDispatch(&editor, &entry, &paste);
    try std.testing.expectEqualStrings("PasteCanary!", try editor.borrowForSave());
    try fixture.backend.clipboardTextSet("Rejected\nPaste");
    var invalid_paste = testKey(&entry, .v, .lcontrol);
    try testDispatch(&editor, &entry, &invalid_paste);
    try std.testing.expectEqualStrings("PasteCanary!", try editor.borrowForSave());
    var left = testKey(&entry, .left, .none);
    try testDispatch(&editor, &entry, &left);
    entry.draw();
    try std.testing.expectEqual(editor.len - 1, entry.textLayout.selection.cursor);
    editor.finishEntry(&entry);
    try testAdvance(&fixture);
    editor.initEntry(&entry, .{});
    var delete = testKey(&entry, .delete, .none);
    try testDispatch(&editor, &entry, &delete);
    try std.testing.expectEqualStrings("PasteCanary", try editor.borrowForSave());
    try testZeros(editor.bytes[editor.len..]);
    var backspace = testKey(&entry, .backspace, .none);
    try testDispatch(&editor, &entry, &backspace);
    try std.testing.expectEqualStrings("PasteCanar", try editor.borrowForSave());
    try testZeros(editor.bytes[editor.len..]);
    var tab = testKey(&entry, .tab, .none);
    try testDispatch(&editor, &entry, &tab);
    try std.testing.expect(tab.handled);
    entry.draw();
}

test "CF key editor first repeated touch and handled release persist export lock" {
    var fixture = try dvui.testing.init(.{});
    defer fixture.deinit();
    try fixture.backend.clipboardTextSet("PublicClipboard");
    var editor: Editor = .{};
    defer editor.deinit();
    for (0..4) |frame| {
        var entry: dvui.TextEntryWidget = undefined;
        editor.initEntry(&entry, .{});
        try std.testing.expectEqual(frame != 0, entry.textLayout.touch_editing);
        try std.testing.expect(!entry.textLayout.te_show_context_menu);
        try std.testing.expect(!entry.textLayout.process_events_in_deinit);
        try std.testing.expectEqualStrings("PublicClipboard", fixture.backend.clipboard.?);
        if (frame == 0) editor.insert(&entry, "TouchCanary!", false);
        entry.textLayout.touch_editing = true;
        var release: dvui.Event = .{ .handled = true, .evt = .{ .mouse = .{
            .action = .release,
            .button = .touch0,
            .mod = .none,
            .p = .{},
            .floating_win = fixture.window.data().id,
        } } };
        // Prove the dependency regression trigger, then enforce wrapper reset.
        _ = entry.matchEvent(&release);
        try std.testing.expect(entry.textLayout.te_show_context_menu);
        lockExports(&entry);
        entry.draw();
        // Leave a handled release in the real queue: default deinit would set
        // context true again while doing its cursor-only event traversal.
        try fixture.window.events.insert(fixture.window.arena(), fixture.window.events.items.len - 1, release);
        const layout_id = entry.textLayout.data().id;
        editor.finishEntry(&entry);
        try std.testing.expect(!dvui.dataGet(null, layout_id, "_te_show_context_menu", bool).?);
        try std.testing.expectEqualStrings("TouchCanary!", try editor.borrowForSave());
        try std.testing.expectEqualStrings("PublicClipboard", fixture.backend.clipboard.?);
        try testAdvance(&fixture);
    }
}

test "CF key editor public draw keeps identity private and cancellation wipes" {
    var fixture = try dvui.testing.init(.{});
    defer fixture.deinit();
    var editor: Editor = .{};
    defer editor.deinit();
    var data: dvui.WidgetData = undefined;
    _ = editor.draw(@src(), .{ .data_out = &data, .role = .text_input, .label = .{ .text = "NeverUsed" } });
    try std.testing.expectEqual(dvui.AccessKit.Role.password_input, data.options.role.?);
    try std.testing.expectEqualStrings("CurseForge API key", data.options.label.?.text);
    try testAdvance(&fixture);
    _ = try fixture.window.addEventText(.{ .text = "PublicDrawCanary!", .target_id = data.id });
    const inserted = editor.draw(@src(), .{ .data_out = &data });
    try std.testing.expect(inserted.edited);
    try std.testing.expectEqualStrings("PublicDrawCanary!", try editor.borrowForSave());
    for (dvui.events()) |event| {
        if (event.evt == .text and event.evt.text.action == .value) try testZeros(event.evt.text.action.value.txt);
    }
    try testAdvance(&fixture);
    dvui.focusWidget(data.id, null, null);
    _ = try fixture.window.addEventKey(.{ .code = .escape, .mod = .none, .action = .down });
    _ = try fixture.window.addEventText(.{ .text = "AfterCancelCanary!", .target_id = data.id });
    const cancelled = editor.draw(@src(), .{});
    try std.testing.expect(cancelled.cancel);
    try std.testing.expect(!cancelled.submit);
    try testZeros(&editor.bytes);
    for (dvui.events()) |event| {
        if (event.evt == .text and event.evt.text.action == .value) try testZeros(event.evt.text.action.value.txt);
    }
    try std.testing.expectError(error.InvalidKey, editor.borrowForSave());
}

test "CF key editor configured mask and lifecycle contain no raw cache" {
    var fixture = try dvui.testing.init(.{});
    defer fixture.deinit();
    var editor: Editor = .{};
    defer editor.deinit();
    var entry: dvui.TextEntryWidget = undefined;
    editor.initEntry(&entry, .{ .role = .text_input, .tag = "ordinary", .name = "ordinary" });
    editor.insert(&entry, "CacheCanary!", false);
    const id = entry.data().id;
    try std.testing.expectEqual(dvui.AccessKit.Role.password_input, entry.data().options.role.?);
    try std.testing.expectEqualStrings("*", entry.init_opts.password_char.?);
    try std.testing.expect(!entry.init_opts.cache_layout);
    try std.testing.expect(entry.init_opts.tree_sitter == null);
    try std.testing.expect(entry.init_opts.placeholder == null);
    try std.testing.expectEqual(max_bytes, entry.text.len);
    try std.testing.expectEqual(@intFromPtr(&editor.bytes), @intFromPtr(entry.text.ptr));
    entry.draw();
    editor.finishEntry(&entry);
    try std.testing.expect(dvui.dataGetSlice(null, id, "_buffer", []u8) == null);
    editor.reset();
    try testZeros(&editor.bytes);
    try std.testing.expectError(error.InvalidKey, editor.borrowForSave());
    // TestingBackend forcibly disables AccessKit in the pinned dependency.
    // This checks mask/role configuration, NOT live AK node or run values.
    try std.testing.expect(!dvui.accesskit_enabled);
    try std.testing.expectEqualStrings("replace_selected_text", unsupported_actions[0]);
}

test "CF key editor supported selection submit middle focus and final reset" {
    var fixture = try dvui.testing.init(.{});
    defer fixture.deinit();
    var editor: Editor = .{};
    defer editor.deinit();
    var data: dvui.WidgetData = undefined;
    _ = editor.draw(@src(), .{ .data_out = &data });
    try testAdvance(&fixture);
    dvui.focusWidget(data.id, null, null);
    _ = try fixture.window.addEventText(.{ .text = "SubmitCanary!", .target_id = data.id });
    _ = editor.draw(@src(), .{ .data_out = &data });
    try testAdvance(&fixture);
    // This is the same public selection+text event route used by AK set_value.
    // The external AccessKit allocation itself is deliberately not simulated.
    _ = try fixture.window.addEventTextSelect(.{ .start = 0, .end = editor.len, .target_id = data.id });
    _ = try fixture.window.addEventText(.{ .text = "NewCanary!", .target_id = data.id });
    _ = try fixture.window.addEventKey(.{ .code = .enter, .action = .down, .mod = .none });
    const submitted = editor.draw(@src(), .{ .data_out = &data });
    try std.testing.expect(submitted.submit);
    try std.testing.expect(!submitted.cancel);
    try std.testing.expectEqualStrings("NewCanary!", try editor.borrowForSave());
    for (dvui.events()) |event| {
        if (event.evt == .text and event.evt.text.action == .value) try testZeros(event.evt.text.action.value.txt);
    }
    try testAdvance(&fixture);
    var entry: dvui.TextEntryWidget = undefined;
    editor.initEntry(&entry, .{});
    // TestingBackend has no PRIMARY method: the supported empty-input path
    // must still focus without exporting or changing an unselected key.
    entry.textLayout.selection.* = .{ .start = entry.len, .end = entry.len, .cursor = entry.len };
    var middle: dvui.Event = .{ .target_widgetId = entry.data().id, .evt = .{ .mouse = .{
        .action = .press,
        .button = .middle,
        .mod = .none,
        .p = entry.data().rectScale().r.center(),
        .floating_win = fixture.window.data().id,
    } } };
    var result: Result = .{};
    editor.dispatch(&entry, &middle, &result);
    editor.sync(&entry);
    try std.testing.expect(middle.handled);
    try std.testing.expectEqual(entry.data().id, dvui.focusedWidgetId().?);
    try std.testing.expectEqualStrings("NewCanary!", try editor.borrowForSave());
    // Cmd bindings and non-down export actions must use the same alias filter.
    try fixture.window.keybinds.put(fixture.window.gpa, "copy", .{ .key = .c, .command = true });
    try fixture.window.keybinds.put(fixture.window.gpa, "cut", .{ .key = .x, .command = true });
    try fixture.backend.clipboardTextSet("PublicClipboard");
    entry.textLayout.selection.* = .{ .start = 0, .end = entry.len, .cursor = entry.len };
    for ([_]dvui.enums.Key{ .c, .x }) |code| {
        var event = testKey(&entry, code, .lcommand);
        for ([_]@TypeOf(event.evt.key.action){ .down, .repeat, .up }) |action| {
            event = testKey(&entry, code, .lcommand);
            event.evt.key.action = action;
            try testDispatch(&editor, &entry, &event);
            try std.testing.expect(event.handled);
            try std.testing.expectEqualStrings("PublicClipboard", fixture.backend.clipboard.?);
            try std.testing.expectEqualStrings("NewCanary!", try editor.borrowForSave());
        }
    }
    entry.draw();
    editor.finishEntry(&entry);
    editor.reset();
    try testZeros(&editor.bytes);
    try std.testing.expectError(error.InvalidKey, editor.borrowForSave());
}

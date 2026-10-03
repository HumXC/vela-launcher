const std = @import("std");
const dvui = @import("dvui");
const c = dvui.backend.c;

pub fn getNativeSDLWindow(win: *dvui.Window) *c.SDL_Window {
    return win.backend.impl.window;
}

/// Keep this at a stable address until deinit; use one control for the launcher.
/// init/deinit/hide/restoreAndFocus and takeCloseRequested belong on the UI thread.
/// The filter may run on another thread and only records intent plus a wake event.
pub const Control = struct {
    window: ?*c.SDL_Window = null,
    window_id: u32 = 0,
    wake_type: u32 = 0,
    close_intent: std.atomic.Value(bool) = .init(false),
    interception_enabled: std.atomic.Value(bool) = .init(false),
    previous_filter: c.SDL_EventFilter = null,
    previous_userdata: ?*anyopaque = null,
    installed: bool = false,

    pub fn init(self: *Control, win: *dvui.Window) !void {
        if (self.installed) return error.AlreadyInitialized;
        const window = getNativeSDLWindow(win);
        const id = c.SDL_GetWindowID(window);
        if (id == 0) return error.InvalidWindow;
        const wake_type = c.SDL_RegisterEvents(1);
        if (wake_type == std.math.maxInt(u32)) return error.RegisterEventFailed;
        self.window = window;
        self.window_id = id;
        self.wake_type = wake_type;
        self.close_intent.store(false, .release);
        self.previous_filter = null;
        self.previous_userdata = null;
        _ = c.SDL_GetEventFilter(&self.previous_filter, &self.previous_userdata);
        self.installed = true;
        self.interception_enabled.store(true, .release);
        c.SDL_SetEventFilter(filter, self);
    }

    pub fn deinit(self: *Control) void {
        if (!self.installed) return;
        self.interception_enabled.store(false, .release);
        var current_filter: c.SDL_EventFilter = null;
        var current_userdata: ?*anyopaque = null;
        _ = c.SDL_GetEventFilter(&current_filter, &current_userdata);
        if (current_filter == @as(c.SDL_EventFilter, filter) and current_userdata == @as(?*anyopaque, self)) {
            c.SDL_SetEventFilter(self.previous_filter, self.previous_userdata);
        } else {
            // A later filter may chain this one: retain the stable Control storage.
            dvui.log.warn("Launcher SDL filter was replaced before deinit", .{});
        }
        self.installed = false;
        self.window = null;
        self.close_intent.store(false, .release);
    }

    pub fn takeCloseRequested(self: *Control) bool {
        return self.close_intent.swap(false, .acq_rel);
    }

    pub fn hide(self: *Control) !void {
        const window = self.window orelse return error.NotInitialized;
        if (!c.SDL_HideWindow(window)) return error.HideWindowFailed;
    }

    pub fn restoreAndFocus(self: *Control) !void {
        const window = self.window orelse return error.NotInitialized;
        if (!c.SDL_ShowWindow(window)) return error.ShowWindowFailed;
        if (!c.SDL_RestoreWindow(window)) return error.RestoreWindowFailed;
        if (!c.SDL_RaiseWindow(window)) return error.RaiseWindowFailed;
    }

    fn filter(userdata: ?*anyopaque, event: [*c]c.SDL_Event) callconv(.c) bool {
        const self: *Control = @ptrCast(@alignCast(userdata orelse return true));
        if (self.previous_filter) |previous| {
            if (!previous(self.previous_userdata, event)) return false;
        }
        if (event == null or !self.interception_enabled.load(.acquire)) return true;
        const window_close = event.*.type == c.SDL_EVENT_WINDOW_CLOSE_REQUESTED and event.*.window.windowID == self.window_id;
        // SDL_QUIT has no window ID or origin; it is an application-wide intent.
        // Other windows' close requests and other system event types stay intact.
        if (window_close or event.*.type == c.SDL_EVENT_QUIT) {
            self.close_intent.store(true, .release);
            event.* = std.mem.zeroes(c.SDL_Event);
            event.*.type = self.wake_type;
            event.*.user.windowID = self.window_id;
        }
        return true;
    }
};

test "close interception is scoped and converted into a wake without SDL calls" {
    var control: Control = .{ .window_id = 42, .wake_type = c.SDL_EVENT_USER + 1, .interception_enabled = .init(true) };
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_WINDOW_CLOSE_REQUESTED;
    event.window.windowID = 7;
    try std.testing.expect(Control.filter(&control, &event));
    try std.testing.expectEqual(@as(u32, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED), event.type);
    try std.testing.expect(!control.takeCloseRequested());
    event.window.windowID = 42;
    try std.testing.expect(Control.filter(&control, &event));
    try std.testing.expectEqual(control.wake_type, event.type);
    try std.testing.expectEqual(@as(u32, 42), event.user.windowID);
    try std.testing.expect(control.takeCloseRequested());
    try std.testing.expect(!control.takeCloseRequested());
}

test "global quit becomes close intent but other system events are preserved" {
    var control: Control = .{ .window_id = 42, .wake_type = c.SDL_EVENT_USER + 1, .interception_enabled = .init(true) };
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_QUIT;
    try std.testing.expect(Control.filter(&control, &event));
    try std.testing.expectEqual(control.wake_type, event.type);
    try std.testing.expect(control.takeCloseRequested());
    event.type = c.SDL_EVENT_TERMINATING;
    try std.testing.expect(Control.filter(&control, &event));
    try std.testing.expectEqual(@as(u32, c.SDL_EVENT_TERMINATING), event.type);
    try std.testing.expect(!control.takeCloseRequested());
}

fn rejectEvent(_: ?*anyopaque, _: [*c]c.SDL_Event) callconv(.c) bool {
    return false;
}

test "prior filter may reject original close before policy records intent" {
    var control: Control = .{ .window_id = 42, .wake_type = c.SDL_EVENT_USER + 1, .interception_enabled = .init(true), .previous_filter = rejectEvent };
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_QUIT;
    try std.testing.expect(!Control.filter(&control, &event));
    try std.testing.expectEqual(@as(u32, c.SDL_EVENT_QUIT), event.type);
    try std.testing.expect(!control.takeCloseRequested());
}

test "disabled interception preserves close events after teardown" {
    var control: Control = .{ .window_id = 42, .wake_type = c.SDL_EVENT_USER + 1 };
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_QUIT;
    try std.testing.expect(Control.filter(&control, &event));
    try std.testing.expectEqual(@as(u32, c.SDL_EVENT_QUIT), event.type);
    try std.testing.expect(!control.takeCloseRequested());
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Control);
}

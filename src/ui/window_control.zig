const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const c = dvui.backend.c;

/// Configure before SDL initialization; compositors without server decorations
/// may leave the window without a titlebar when libdecor is disabled.
pub fn configureNativeBackend() !void {
    if (comptime builtin.os.tag != .linux) return;
    // Avoid libdecor's unsafe dispatch loop when the Wayland compositor exits.
    const hint = c.SDL_HINT_VIDEO_WAYLAND_ALLOW_LIBDECOR;
    if (!c.SDL_SetHintWithPriority(hint, "0", c.SDL_HINT_OVERRIDE)) return error.NativeDecorationConfigurationFailed;
    const effective = c.SDL_GetHint(hint);
    if (effective == null) return error.NativeDecorationHintUnavailable;
    if (!std.mem.eql(u8, std.mem.span(effective), "0")) return error.NativeDecorationConfigurationNotApplied;
}

pub fn getNativeSDLWindow(win: *dvui.Window) *c.SDL_Window {
    return win.backend.impl.window;
}

/// UI-thread guard; the cached display belongs to SDL's native-window lifetime.
/// Current SDL does not reconnect Wayland displays after a fatal connection error.
const NativeDisplayGuard = struct {
    const GetErrorFn = *const fn (*anyopaque) callconv(.c) c_int;

    object: ?*c.SDL_SharedObject = null,
    display: ?*anyopaque = null,
    get_error: ?GetErrorFn = null,

    fn init(self: *NativeDisplayGuard, native_window: *c.SDL_Window) !void {
        if (comptime builtin.os.tag != .linux) return;
        if (self.object != null) return error.AlreadyInitialized;

        const driver = c.SDL_GetCurrentVideoDriver();
        if (driver == null) return error.NativeVideoDriverUnavailable;
        if (!std.mem.eql(u8, std.mem.span(driver), "wayland")) return;

        const properties = c.SDL_GetWindowProperties(native_window);
        if (properties == 0) return error.NativeWindowPropertiesUnavailable;
        const display = c.SDL_GetPointerProperty(
            properties,
            c.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER,
            null,
        ) orelse return error.NativeWaylandDisplayUnavailable;

        // SDL's Wayland backend already owns a reference to this same SONAME.
        const object = c.SDL_LoadObject("libwayland-client.so.0") orelse return error.WaylandLibraryUnavailable;
        errdefer c.SDL_UnloadObject(object);
        const symbol = c.SDL_LoadFunction(object, "wl_display_get_error") orelse return error.WaylandErrorQueryUnavailable;
        const get_error: GetErrorFn = @ptrCast(symbol);

        self.object = object;
        self.display = display;
        self.get_error = get_error;
    }

    fn check(self: *const NativeDisplayGuard) !void {
        const get_error = self.get_error orelse return; // Non-Wayland is inert.
        const display = self.display orelse return error.NativeWaylandDisplayUnavailable;
        if (get_error(display) != 0) return error.NativeDisplayDisconnected;
    }

    fn deinit(self: *NativeDisplayGuard) void {
        const object = self.object;
        self.* = .{};
        if (object) |loaded| c.SDL_UnloadObject(loaded);
    }
};

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
    native_display: NativeDisplayGuard = .{},

    pub fn init(self: *Control, win: *dvui.Window) !void {
        if (self.installed) return error.AlreadyInitialized;
        const window = getNativeSDLWindow(win);
        const id = c.SDL_GetWindowID(window);
        if (id == 0) return error.InvalidWindow;
        try self.native_display.init(window);
        errdefer self.native_display.deinit();
        if (comptime builtin.os.tag == .linux) {
            if (self.native_display.display != null) {
                // Avoid SDL's Wayland frame-callback wait; DVUI still schedules frames.
                // This does not prevent a disconnect during EGL presentation.
                const renderer = win.backend.impl.renderer;
                if (!c.SDL_SetRenderVSync(renderer, 0)) return error.NativeFramePacingConfigurationFailed;
                var render_vsync: c_int = -1;
                if (!c.SDL_GetRenderVSync(renderer, &render_vsync)) return error.NativeFramePacingQueryUnavailable;
                if (render_vsync != 0) return error.NativeFramePacingNotDisabled;

                // SDL can accept vsync=0 even when its renderer backend rejects it.
                const name = c.SDL_GetRendererName(renderer);
                if (name == null) return error.NativeRendererNameUnavailable;
                const renderer_name = std.mem.span(name);
                if (std.mem.eql(u8, renderer_name, "opengl") or
                    std.mem.eql(u8, renderer_name, "opengles") or
                    std.mem.eql(u8, renderer_name, "opengles2"))
                {
                    var swap_interval: c_int = -1;
                    if (!c.SDL_GL_GetSwapInterval(&swap_interval)) return error.NativeSwapIntervalQueryUnavailable;
                    if (swap_interval != 0) return error.NativeSwapIntervalNotDisabled;
                }
                // Bound continuous refresh now that native vsync is disabled.
                win.max_fps = win.max_fps orelse 60;
            }
        }
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
        self.native_display.deinit();
        self.window = null;
        self.close_intent.store(false, .release);
    }

    /// Call after the backend pumps SDL events, before building a frame.
    /// A fatal error must unwind App deinit without a final presentation.
    pub fn checkNativeDisplay(self: *const Control) !void {
        if (!self.installed) return error.NotInitialized;
        try self.native_display.check();
    }

    pub fn takeCloseRequested(self: *Control) bool {
        return self.close_intent.swap(false, .acq_rel);
    }

    pub fn hide(self: *Control) !void {
        const window = self.window orelse return error.NotInitialized;
        if (!c.SDL_HideWindow(window)) return error.HideWindowFailed;
    }

    /// Prompting must not restore or raise an already-visible normal window.
    pub fn showForPrompt(self: *Control) !void {
        const window = self.window orelse return error.NotInitialized;
        const flags = c.SDL_GetWindowFlags(window);
        const hidden = flags & c.SDL_WINDOW_HIDDEN != 0;
        const minimized = flags & c.SDL_WINDOW_MINIMIZED != 0;
        if (hidden and !c.SDL_ShowWindow(window)) return error.ShowWindowFailed;
        if (minimized and !c.SDL_RestoreWindow(window)) return error.RestoreWindowFailed;
        if ((hidden or minimized) and !c.SDL_RaiseWindow(window)) return error.RaiseWindowFailed;
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
        const alt_f4 = event.*.type == c.SDL_EVENT_KEY_DOWN and
            event.*.key.windowID == self.window_id and
            event.*.key.down and !event.*.key.repeat and
            event.*.key.key == c.SDLK_F4 and
            (event.*.key.mod & c.SDL_KMOD_ALT) != 0;
        // SDL_QUIT has no window ID or origin; it is an application-wide intent.
        // Other windows' close requests and other system event types stay intact.
        if (window_close or alt_f4 or event.*.type == c.SDL_EVENT_QUIT) {
            self.close_intent.store(true, .release);
            event.* = std.mem.zeroes(c.SDL_Event);
            event.*.type = self.wake_type;
            event.*.user.windowID = self.window_id;
        }
        return true;
    }
};

test "native display guard is inert without Wayland and control requires initialization" {
    var guard: NativeDisplayGuard = .{};
    try guard.check();
    guard.deinit();
    try std.testing.expect(guard.object == null and guard.display == null and guard.get_error == null);
    const control: Control = .{};
    try std.testing.expectError(error.NotInitialized, control.checkNativeDisplay());
}

test "native display health preserves pending close policy while fatal errors stop the frame" {
    const Probe = struct {
        error_code: c_int = 0,
        calls: usize = 0,

        fn query(display: *anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(display));
            self.calls += 1;
            return self.error_code;
        }
    };
    var probe: Probe = .{};
    var control: Control = .{
        .installed = true,
        .close_intent = .init(true),
        .native_display = .{ .display = &probe, .get_error = Probe.query },
    };
    try control.checkNativeDisplay();
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(control.close_intent.load(.acquire));

    probe.error_code = 32;
    try std.testing.expectError(error.NativeDisplayDisconnected, control.checkNativeDisplay());
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expect(control.close_intent.load(.acquire));
    control.native_display.deinit();
    try std.testing.expect(control.native_display.display == null and control.native_display.get_error == null);
}

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

fn altF4Event(window_id: u32) c.SDL_Event {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.windowID = window_id;
    event.key.down = true;
    event.key.repeat = false;
    event.key.key = c.SDLK_F4;
    event.key.mod = c.SDL_KMOD_LALT;
    return event;
}

test "left and right Alt-F4 with lock modifiers become close intent and a wake" {
    const locks = c.SDL_KMOD_CAPS | c.SDL_KMOD_NUM | c.SDL_KMOD_SCROLL;
    const modifiers = [_]c.SDL_Keymod{
        c.SDL_KMOD_LALT,
        c.SDL_KMOD_RALT,
        c.SDL_KMOD_LALT | locks,
        c.SDL_KMOD_RALT | locks,
    };
    for (modifiers) |mod| {
        var control: Control = .{ .window_id = 42, .wake_type = c.SDL_EVENT_USER + 1, .interception_enabled = .init(true) };
        var event = altF4Event(42);
        event.key.mod = mod;
        try std.testing.expect(Control.filter(&control, &event));
        try std.testing.expectEqual(control.wake_type, event.type);
        try std.testing.expectEqual(control.window_id, event.user.windowID);
        try std.testing.expect(control.takeCloseRequested());
        try std.testing.expect(!control.takeCloseRequested());
    }
}

test "non-shortcut keyboard events preserve their payload and record no close intent" {
    const cases = [_]struct {
        event_type: u32 = c.SDL_EVENT_KEY_DOWN,
        window_id: u32 = 42,
        down: bool = true,
        repeat: bool = false,
        key: c.SDL_Keycode = c.SDLK_F4,
        mod: c.SDL_Keymod = c.SDL_KMOD_LALT,
    }{
        .{ .key = c.SDLK_F3 },
        .{ .mod = 0 },
        .{ .event_type = c.SDL_EVENT_KEY_UP, .down = false },
        .{ .event_type = c.SDL_EVENT_KEY_UP },
        .{ .down = false },
        .{ .repeat = true },
        .{ .window_id = 7 },
        .{ .window_id = 0 },
        .{ .mod = c.SDL_KMOD_CTRL | c.SDL_KMOD_SHIFT | c.SDL_KMOD_GUI | c.SDL_KMOD_CAPS | c.SDL_KMOD_NUM | c.SDL_KMOD_SCROLL },
    };
    for (cases) |case| {
        var control: Control = .{ .window_id = 42, .wake_type = c.SDL_EVENT_USER + 1, .interception_enabled = .init(true) };
        var event = altF4Event(case.window_id);
        event.type = case.event_type;
        event.key.timestamp = 123;
        event.key.down = case.down;
        event.key.repeat = case.repeat;
        event.key.key = case.key;
        event.key.mod = case.mod;
        const original = event;
        try std.testing.expect(Control.filter(&control, &event));
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&original), std.mem.asBytes(&event));
        try std.testing.expect(!control.takeCloseRequested());
    }
}

test "disabled interception preserves Alt-F4 without close intent" {
    var control: Control = .{ .window_id = 42, .wake_type = c.SDL_EVENT_USER + 1 };
    var event = altF4Event(42);
    const original = event;
    try std.testing.expect(Control.filter(&control, &event));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&original), std.mem.asBytes(&event));
    try std.testing.expect(!control.takeCloseRequested());
}

test "prior filter rejection preserves Alt-F4 before policy records intent" {
    var control: Control = .{ .window_id = 42, .wake_type = c.SDL_EVENT_USER + 1, .interception_enabled = .init(true), .previous_filter = rejectEvent };
    var event = altF4Event(42);
    const original = event;
    try std.testing.expect(!Control.filter(&control, &event));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&original), std.mem.asBytes(&event));
    try std.testing.expect(!control.takeCloseRequested());
}

test "native close Alt-F4 and global quit coalesce in every order before consumption" {
    const close = c.SDL_EVENT_WINDOW_CLOSE_REQUESTED;
    const shortcut = c.SDL_EVENT_KEY_DOWN;
    const quit = c.SDL_EVENT_QUIT;
    const sequences = [_][3]u32{
        .{ close, shortcut, quit },
        .{ shortcut, close, quit },
        .{ close, quit, shortcut },
        .{ shortcut, quit, close },
        .{ quit, close, shortcut },
        .{ quit, shortcut, close },
    };
    for (sequences) |sequence| {
        var control: Control = .{ .window_id = 42, .wake_type = c.SDL_EVENT_USER + 1, .interception_enabled = .init(true) };
        for (sequence) |event_type| {
            var event = if (event_type == shortcut) altF4Event(42) else std.mem.zeroes(c.SDL_Event);
            event.type = event_type;
            if (event_type == close) event.window.windowID = 42;
            try std.testing.expect(Control.filter(&control, &event));
            try std.testing.expectEqual(control.wake_type, event.type);
            try std.testing.expectEqual(control.window_id, event.user.windowID);
            try std.testing.expect(control.close_intent.load(.acquire));
        }
        try std.testing.expect(control.takeCloseRequested());
        try std.testing.expect(!control.takeCloseRequested());
    }
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Control);
}

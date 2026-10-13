//! SDL3 chooser adapter. Call pump from the main-thread DVUI frame; DVUI keeps
//! pumping SDL events (including Linux portal/DBus events) while dialogs are open.
//! No worker process, nested event loop, or callback access to UI state is needed.
const std = @import("std");
const dvui = @import("dvui");
const picker = @import("file_picker.zig");

/// Starts queued requests and reaps discarded completions. Periodic DVUI timers
/// ensure an otherwise idle app observes callbacks, including during shutdown.
pub fn pump(service: *picker.Service, win: *dvui.Window) void {
    if (comptime dvui.backend.kind == .sdl3) {
        service.startPending(.{ .context = win, .start = Native.start });
    } else {
        service.startPending(.{ .start = unavailable });
    }
    const poll_id = win.data().id.update("file_picker.poll");
    if (service.isBusy()) {
        win.timer(poll_id, 50_000);
    } else {
        win.timerRemove(poll_id);
    }
}

fn unavailable(_: ?*anyopaque, pending: *picker.Pending) void {
    pending.complete(.{
        .failure = error.NativeDialogUnavailable,
        .error_message = "Native file dialogs require the SDL3 backend.",
    });
}

// The testing backend has neither SDL C declarations nor a native window.
// Keep the entire native implementation behind a compile-time backend choice.
const Native = if (dvui.backend.kind == .sdl3) struct {
    const c = dvui.backend.c;
    const Dialog = struct {
        pending: *picker.Pending,
        filters: [1]c.SDL_DialogFileFilter,
    };

    fn start(context: ?*anyopaque, pending: *picker.Pending) void {
        const win: *dvui.Window = @ptrCast(@alignCast(context.?));
        const dialog = std.heap.page_allocator.create(Dialog) catch |err| {
            pending.complete(.{ .failure = err });
            return;
        };
        dialog.* = .{
            .pending = pending,
            .filters = .{.{
                .name = "Supported files",
                .pattern = if (pending.extensions) |extensions| extensions.ptr else "*",
            }},
        };
        const props = c.SDL_CreateProperties();
        if (props == 0) {
            fail(dialog);
            return;
        }
        // SDL copies properties before returning. Pointer-valued filter data
        // stays in Dialog and Pending until the callback is invoked.
        defer c.SDL_DestroyProperties(props);
        if (!c.SDL_SetPointerProperty(props, c.SDL_PROP_FILE_DIALOG_WINDOW_POINTER, win.backend.impl.window) or
            !c.SDL_SetBooleanProperty(props, c.SDL_PROP_FILE_DIALOG_MANY_BOOLEAN, false))
        {
            fail(dialog);
            return;
        }
        if (pending.title.len != 0 and !c.SDL_SetStringProperty(props, c.SDL_PROP_FILE_DIALOG_TITLE_STRING, pending.title.ptr)) {
            fail(dialog);
            return;
        }
        if (pending.default_path.len != 0 and !c.SDL_SetStringProperty(props, c.SDL_PROP_FILE_DIALOG_LOCATION_STRING, pending.default_path.ptr)) {
            fail(dialog);
            return;
        }
        if (pending.kind == .file and pending.extensions != null) {
            if (!c.SDL_SetPointerProperty(props, c.SDL_PROP_FILE_DIALOG_FILTERS_POINTER, &dialog.filters) or
                !c.SDL_SetNumberProperty(props, c.SDL_PROP_FILE_DIALOG_NFILTERS_NUMBER, dialog.filters.len))
            {
                fail(dialog);
                return;
            }
        }
        const kind: c.SDL_FileDialogType = switch (pending.kind) {
            .file => c.SDL_FILEDIALOG_OPENFILE,
            .folder => c.SDL_FILEDIALOG_OPENFOLDER,
        };
        // An immediate failure may invoke callback here and free dialog. Never
        // inspect dialog or pending after this call.
        c.SDL_ShowFileDialogWithProperties(kind, callback, dialog, props);
    }

    fn callback(userdata: ?*anyopaque, filelist: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
        const dialog: *Dialog = @ptrCast(@alignCast(userdata.?));
        if (filelist == null) {
            // SDL_GetError is thread-local: obtain and copy it here, never later
            // on the UI thread. The callback does not touch Window or DVUI.
            fail(dialog);
        } else if (filelist[0] == null) {
            finish(dialog, .{});
        } else if (boundedCString(filelist[0], picker.max_path_bytes)) |path| {
            // Some native backends (including Zenity) use an empty first
            // string on Cancel instead of a null first list entry.
            if (path.len == 0) {
                finish(dialog, .{});
            } else {
                finish(dialog, .{ .path = path });
            }
        } else {
            finish(dialog, .{
                .failure = error.InputTooLong,
                .error_message = "The selected path exceeds the supported length.",
            });
        }
        // SDL owns filelist and frees it after this callback returns.
    }

    fn fail(dialog: *Dialog) void {
        const message = boundedCString(c.SDL_GetError(), picker.max_error_message_bytes) orelse
            "Native dialog failed; its error message exceeds the supported length.";
        finish(dialog, .{ .failure = error.NativeDialogFailed, .error_message = message });
    }

    fn finish(dialog: *Dialog, completion: picker.Completion) void {
        const pending = dialog.pending;
        // Free adapter state before publishing done, so shutdown cannot race
        // cleanup or retain a hidden callback reference after isDrained is true.
        std.heap.page_allocator.destroy(dialog);
        pending.complete(completion);
    }

    fn boundedCString(pointer: [*c]const u8, limit: usize) ?[]const u8 {
        if (pointer == null) return null;
        var length: usize = 0;
        while (length <= limit) : (length += 1) {
            if (pointer[length] == 0) return pointer[0..length];
        }
        return null;
    }
} else struct {};

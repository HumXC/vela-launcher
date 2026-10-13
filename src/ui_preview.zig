//! Native component mock entry; production App and acceptance fixture do not import this root.
const std = @import("std");
const dvui = @import("dvui");
const options = @import("ui_preview_options");
const preview = @import("ui/component_preview.zig");
const fonts = @import("ui/fonts.zig");
const theme = @import("ui/theme.zig");

pub const dvui_app: dvui.App = .{
    .config = .{ .startFn = start },
    .initFn = init,
    .frameFn = frame,
    .deinitFn = deinit,
};
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

var context: ?preview.Context = null;
var parsed_data: ?std.json.Parsed(preview.Data) = null;
var viewport: dvui.Size = .{ .w = 1280, .h = 720 };
var receipt_events: ?u64 = null;

fn start() dvui.App.StartOptions {
    return .{ .size = parseSize(options.size) catch .{ .w = 1280, .h = 720 }, .min_size = .{ .w = 320, .h = 240 }, .title = "Vela · Component Mock Preview", .vsync = false };
}

fn init(win: *dvui.Window) !void {
    const app = dvui.App.main_init orelse return error.MissingAppInit;
    const env = app.environ_map;
    const scene = std.meta.stringToEnum(preview.Scene, env.get("VELA_PREVIEW_SCENE") orelse options.scene) orelse return error.InvalidPreviewScene;
    const variant = std.meta.stringToEnum(preview.Variant, env.get("VELA_PREVIEW_STATE") orelse options.state) orelse return error.InvalidPreviewState;
    viewport = try parseSize(env.get("VELA_PREVIEW_VIEWPORT") orelse options.size);
    try fonts.install(win);
    theme.install(win);
    const data_path: ?[]const u8 = if (env.get("VELA_PREVIEW_DATA")) |path| path else options.data_file;
    var data: preview.Data = .{};
    if (data_path) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(64 * 1024));
        defer app.gpa.free(bytes);
        parsed_data = try std.json.parseFromSlice(preview.Data, app.gpa, bytes, .{ .allocate = .alloc_always });
        data = parsed_data.?.value;
    }
    errdefer {
        if (parsed_data) |*parsed| parsed.deinit();
        parsed_data = null;
    }
    context = try preview.Context.init(app.gpa, scene, variant, data);
    std.log.info("Mock preview scene={s} state={s}; no business services", .{ @tagName(scene), @tagName(variant) });
}

fn deinit(_: *dvui.Window) void {
    if (context) |*value| value.deinit();
    context = null;
    if (parsed_data) |*parsed| parsed.deinit();
    parsed_data = null;
}

fn frame() !dvui.App.Result {
    const value = if (context) |*c| c else return error.MissingPreviewContext;
    const app = dvui.App.main_init orelse return error.MissingAppInit;
    const win = dvui.currentWindow();
    theme.applyTypography();
    // Screenshot bounds are deterministic; interactive previews follow the resized window.
    const fixed = app.environ_map.get("VELA_PREVIEW_VIEWPORT") != null;
    const old_rect = win.data().rect;
    const old_pixels = win.rect_pixels;
    if (fixed) {
        win.data().rect = .{ .w = viewport.w, .h = viewport.h };
        win.rect_pixels = .{ .w = viewport.w * win.natural_scale, .h = viewport.h * win.natural_scale };
    }
    defer {
        win.data().rect = old_rect;
        win.rect_pixels = old_pixels;
    }
    const old_clip = dvui.clip(win.rect_pixels);
    defer dvui.clipSet(old_clip);
    value.draw();
    if (receipt_events == null or receipt_events.? != value.event_count) {
        if (app.environ_map.get("VELA_PREVIEW_RECEIPT")) |path| {
            const bytes = try std.json.Stringify.valueAlloc(app.gpa, .{
                .mock = true,
                .scene = @tagName(value.scene),
                .state = @tagName(value.variant),
                .business_services = 0,
                .events = value.event_count,
                .last_event = @tagName(value.last_event),
                .username = std.mem.sliceTo(&value.account_ui.draft.name, 0),
                .instance_name = std.mem.sliceTo(&value.instance_ui.draft.original_name, 0),
            }, .{});
            defer app.gpa.free(bytes);
            try std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = bytes });
        }
        receipt_events = value.event_count;
    }
    return .ok;
}

fn parseSize(text: []const u8) !dvui.Size {
    const at = std.mem.indexOfScalar(u8, text, 'x') orelse return error.InvalidPreviewSize;
    const width = std.fmt.parseInt(u16, text[0..at], 10) catch return error.InvalidPreviewSize;
    const height = std.fmt.parseInt(u16, text[at + 1 ..], 10) catch return error.InvalidPreviewSize;
    if (width < 320 or width > 4096 or height < 240 or height > 4096) return error.InvalidPreviewSize;
    return .{ .w = @floatFromInt(width), .h = @floatFromInt(height) };
}

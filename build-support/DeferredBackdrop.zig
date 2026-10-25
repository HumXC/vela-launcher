//! Executed at final subwindow z replay, before this modal's fill and children.
//! Read the composed lower layers, never replay widgets or cache stale backgrounds.
const std = @import("std");
const dvui = @import("dvui.zig");
pub const Options = struct {
    region: dvui.RectScale,
    corners: dvui.CornerRect,
    radius: f32,
};

/// Owned by Window, never by a global pointer cache. Slots follow final z replay
/// order so nested modals never mutate a texture still needed by another modal.
pub const State = struct {
    capture: std.ArrayList(u8) = .empty,
    pixels: std.ArrayList(u8) = .empty,
    scratch: std.ArrayList(u8) = .empty,
    textures: std.ArrayList(?dvui.TextureTarget) = .empty,
    used: usize = 0,
    read_pixels: usize = 0,
    blur_pixels: usize = 0,
    texture_creates: usize = 0,

    pub fn begin(self: *State) void {
        self.used = 0;
        self.read_pixels = 0;
        self.blur_pixels = 0;
        self.texture_creates = 0;
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator, backend: dvui.Backend) void {
        for (self.textures.items) |texture| if (texture) |t| backend.textureDestroyTarget(t);
        self.textures.deinit(allocator);
        self.capture.deinit(allocator);
        self.pixels.deinit(allocator);
        self.scratch.deinit(allocator);
        self.* = .{};
    }
};

pub fn draw(options: Options) !void {
    if (comptime !dvui.Backend.support_read_pixels) return;
    if (options.radius <= 0 or options.region.s <= 0) return;
    const win = dvui.currentWindow();
    const region = options.region.r;
    const visible = region.intersect(dvui.clipGet());
    if (visible.empty()) return;
    // Three box passes approximate a Gaussian; pad by their combined support so
    // pixels outside the panel contribute at its edges. Clamp only at the target.
    const radius: usize = @intFromFloat(@ceil(@min(128, options.radius * options.region.s / 2)));
    const pad: f32 = @floatFromInt(radius * 3);
    const offset = win.render_target.offset;
    const bounds: dvui.Rect.Physical = if (win.render_target.texture) |target|
        .{ .x = offset.x, .y = offset.y, .w = @floatFromInt(target.width), .h = @floatFromInt(target.height) }
    else
        dvui.windowRectPixels();
    const x = @max(bounds.x, @floor(visible.x - pad));
    const y = @max(bounds.y, @floor(visible.y - pad));
    const right = @min(bounds.x + bounds.w, @ceil(visible.x + visible.w + pad));
    const bottom = @min(bounds.y + bounds.h, @ceil(visible.y + visible.h + pad));
    if (right <= x or bottom <= y) return;
    const capture: dvui.Rect.Physical = .{ .x = x, .y = y, .w = right - x, .h = bottom - y };
    const source_width: usize = @intFromFloat(capture.w);
    const source_height: usize = @intFromFloat(capture.h);
    // About two logical pixels per texel, with a hard bound independent of DPI
    // and window size. Readback remains native resolution (backend contract),
    // but the six filter passes and texture upload never exceed 512 * 512.
    const factor = @max(@max(1, options.region.s * 2), @max(capture.w, capture.h) / 512);
    const width: usize = @max(1, @min(512, @as(usize, @intFromFloat(@ceil(capture.w / factor)))));
    const height: usize = @max(1, @min(512, @as(usize, @intFromFloat(@ceil(capture.h / factor)))));
    const state = &win.deferred_backdrop;
    try state.capture.resize(win.gpa, source_width * source_height * 4);
    try state.pixels.resize(win.gpa, width * height * 4);
    try state.scratch.resize(win.gpa, width * height * 4);
    try win.backend.readPixels(capture.offsetNegPoint(offset), state.capture.items.ptr);
    state.read_pixels += source_width * source_height;
    state.blur_pixels += width * height;
    const pixels = state.pixels.items;
    const scratch = state.scratch.items;
    // Area averages preserve sub-texel stripes instead of aliasing them away.
    // The renderer's composed target is premultiplied RGBA, including alpha.
    downsample(state.capture.items, pixels, source_width, source_height, width, height);
    const rx: usize = @max(1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(radius)) * @as(f32, @floatFromInt(width)) / capture.w))));
    const ry: usize = @max(1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(radius)) * @as(f32, @floatFromInt(height)) / capture.h))));
    for (0..3) |_| {
        boxPass(pixels, scratch, width, height, rx, false);
        boxPass(scratch, pixels, width, height, ry, true);
    }
    if (state.used == state.textures.items.len) try state.textures.append(win.gpa, null);
    const slot = &state.textures.items[state.used];
    state.used += 1;
    if (slot.*) |texture| {
        if (texture.width != width or texture.height != height) {
            texture.destroyLater();
            slot.* = null;
        }
    }
    if (slot.* == null) {
        // Surface-backed SDL textures may silently choose another pixel format.
        // Explicit targets preserve RGBA for every subsequent textureUpdate.
        slot.* = try win.backend.textureCreateTarget(.{ .width = @intCast(width), .height = @intCast(height), .interpolation = .linear });
        state.texture_creates += 1;
    }
    try win.backend.textureUpdate(dvui.Texture.cast(slot.*.?), pixels.ptr);
    try dvui.renderTexture(dvui.Texture.cast(slot.*.?), options.region, .{ .corners = options.corners, .uv_rect = capture });
}

fn downsample(src: []const u8, dst: []u8, sw: usize, sh: usize, dw: usize, dh: usize) void {
    for (0..dh) |y| {
        const y0 = y * sh / dh;
        const y1 = (y + 1) * sh / dh;
        for (0..dw) |x| {
            const x0 = x * sw / dw;
            const x1 = (x + 1) * sw / dw;
            var sum: [4]u64 = .{ 0, 0, 0, 0 };
            for (y0..y1) |sy| {
                for (x0..x1) |sx| {
                    const i = (sy * sw + sx) * 4;
                    inline for (0..4) |c| sum[c] += src[i + c];
                }
            }
            const count = (x1 - x0) * (y1 - y0);
            inline for (0..4) |c| dst[(y * dw + x) * 4 + c] = @intCast((sum[c] + count / 2) / count);
        }
    }
}

// Sliding sums keep cost linear in captured pixels, independent of blur strength.
fn boxPass(src: []const u8, dst: []u8, width: usize, height: usize, radius: usize, vertical: bool) void {
    const length = if (vertical) height else width;
    const lines = if (vertical) width else height;
    const stride: usize = if (vertical) width * 4 else 4;
    const divisor: u32 = @intCast(radius * 2 + 1);
    for (0..lines) |line| {
        const base = if (vertical) line * 4 else line * width * 4;
        for (0..4) |channel| {
            var sum: u32 = @as(u32, src[base + channel]) * @as(u32, @intCast(radius + 1));
            for (1..radius + 1) |i| sum += src[base + @min(i, length - 1) * stride + channel];
            for (0..length) |i| {
                dst[base + i * stride + channel] = @intCast((sum + divisor / 2) / divisor);
                sum -= src[base + (i -| radius) * stride + channel];
                sum += src[base + @min(i + radius + 1, length - 1) * stride + channel];
            }
        }
    }
}

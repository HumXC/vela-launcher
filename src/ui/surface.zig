//! The only low-level entry point for UI surfaces. Widget options may contain
//! theme-relative corners; drawing always resolves them and applies a physical-pixel fringe.
const std = @import("std");
const dvui = @import("dvui");

pub const edge_fade: f32 = 1;

/// Composite material layers without edge masks, then apply coverage exactly once.
/// Text and child widgets are drawn after finish, at the original framebuffer scale.
pub const Material = struct {
    picture: dvui.Picture,
    region: dvui.RectScale,
    corners: dvui.CornerRect,
    previous_clip: dvui.Rect.Physical,
    previous_alpha: f32,

    pub fn start(region: dvui.RectScale, corners: dvui.CornerRect) ?Material {
        const picture = dvui.Picture.start(region.r.outsetAll(edge_fade)) orelse return null;
        const previous_alpha = dvui.alpha(1);
        dvui.alphaSet(1);
        const previous_clip = dvui.clip(picture.r);
        return .{ .picture = picture, .region = region, .corners = corners.finalize(null), .previous_clip = previous_clip, .previous_alpha = previous_alpha };
    }

    pub fn bounds(self: *const Material) dvui.RectScale {
        return .{ .r = self.picture.r, .s = self.region.s };
    }

    pub fn finish(self: *Material) void {
        self.picture.stop();
        dvui.clipSet(self.previous_clip);
        dvui.alphaSet(self.previous_alpha);
        const texture = dvui.textureFromTarget(self.picture.texture) catch {
            self.picture.texture.destroyLater();
            return;
        };
        dvui.textureDestroyLater(texture);
        // Texture snapping must not move the final mask relative to its fill/outline.
        const previous_snap = dvui.snapToPixelsSet(false);
        defer _ = dvui.snapToPixelsSet(previous_snap);
        dvui.renderTexture(texture, self.region, .{ .corners = self.corners, .fade = fringe(self.corners), .uv_rect = self.picture.r }) catch {};
    }
};

fn fringe(corners: dvui.CornerRect) f32 {
    return if (corners.tl.radius() > 0 or corners.tr.radius() > 0 or corners.bl.radius() > 0 or corners.br.radius() > 0) edge_fade else 0;
}

pub fn fill(region: dvui.RectScale, corners: dvui.CornerRect, color: dvui.ColorOrGradient) void {
    const resolved = corners.finalize(null);
    region.r.fill(resolved.scale(region.s, dvui.CornerRect.Physical), .{ .color = color.scale(region.s), .fade = fringe(resolved) });
}

pub fn renderImage(source: dvui.ImageSource, region: dvui.RectScale, options: dvui.RenderTextureOptions) !void {
    var resolved = options;
    resolved.corners = options.corners.finalize(null);
    resolved.fade = fringe(resolved.corners);
    const previous_snap = dvui.snapToPixels();
    defer _ = dvui.snapToPixelsSet(previous_snap);
    if (resolved.fade > 0) _ = dvui.snapToPixelsSet(false);
    try dvui.renderImage(source, region, resolved);
}

/// A stroke shares the fill's outer contour at every width, including keyboard focus.
pub fn outline(data: *dvui.WidgetData, width: f32, color: dvui.ColorOrGradient) void {
    if (!data.visible() or width <= 0) return;
    const rs = data.borderRectScale();
    const border = data.options.borderGet();
    var corners = data.options.cornersGet().finalize(null);
    inline for (.{ "tl", "tr", "br", "bl" }) |field| {
        const corner = &@field(corners, field);
        if (corner.rx > 0) corner.rx = @max(0, corner.rx + border.x - width / 2);
        if (corner.y > 0) corner.y = @max(0, corner.y + border.y - width / 2);
    }
    rs.r.insetAll(width * rs.s / 2).stroke(corners.scale(rs.s, dvui.CornerRect.Physical), .{ .thickness = width * rs.s, .color = color.scale(rs.s), .after = true });
}

/// Keep native shadow, state fill and ninepatch handling, replacing only the contour.
/// This includes keyboard focus; callers must not add a second ButtonWidget.drawFocus.
/// Non-uniform borders retain native painting and focus behavior.
pub fn buttonBackground(button: *dvui.ButtonWidget) void {
    const data = button.data();
    const border = data.options.borderGet();
    if (!(border.x == border.y and border.x == border.w and border.x == border.h)) {
        button.drawBackground();
        if (!button.init_options.grayed) button.drawFocus();
        return;
    }
    const original_border = data.options.color_border;
    data.options.color_border = .{ .color = dvui.Color.transparent };
    button.drawBackground();
    data.options.color_border = original_border;
    buttonOutline(button);
}

pub fn buttonOutline(button: *dvui.ButtonWidget) void {
    const data = button.data();
    const focused = button.init_options.draw_focus and !button.init_options.grayed and button.focused();
    outline(data, if (focused) 2 else data.options.borderGet().x, if (focused) .{ .color = data.options.themeGet().focus } else data.options.color(.border));
}

/// Native image layout/semantics with the same rounded mask policy as panel textures.
pub fn image(src: std.builtin.SourceLocation, init_options: dvui.ImageInitOptions, options: dvui.Options) dvui.WidgetData {
    const size = options.min_size_content orelse (dvui.imageSize(init_options.source) catch dvui.Size{ .w = 10, .h = 10 });
    var data = dvui.WidgetData.init(src, .{}, (dvui.Options{ .name = "image", .role = .image }).override(options).override(.{ .min_size_content = size }));
    data.register();
    const content = data.contentRect();
    const minimum = data.options.min_size_contentGet();
    const too_big = minimum.w > content.w or minimum.h > content.h;
    const expand = if (too_big) init_options.shrink orelse data.options.expandGet() else data.options.expandGet();
    const gravity = data.options.gravityGet();
    var rect = dvui.placeIn(content, minimum, expand, gravity);
    if (too_big and expand != .ratio) {
        if (minimum.w > content.w and !expand.isHorizontal()) {
            rect.w = minimum.w;
            rect.x -= gravity.x * (minimum.w - content.w);
        }
        if (minimum.h > content.h and !expand.isVertical()) {
            rect.h = minimum.h;
            rect.y -= gravity.y * (minimum.h - content.h);
        }
    }
    data.rect = rect.outset(data.options.paddingGet()).outset(data.options.borderGet()).outset(data.options.marginGet());
    const rotation = data.options.rotationGet();
    if (rotation == 0) data.borderAndBackground(.{});
    renderImage(init_options.source, data.contentRectScale(), .{ .corners = data.options.cornersGet(), .uv = init_options.uv, .rotation = rotation, .background_color = if (rotation != 0 and data.options.backgroundGet()) data.options.color(.fill).toColor() else null }) catch |err| dvui.logError(@src(), err, "Could not render surface image", .{});
    data.minSizeSetAndRefresh();
    data.minSizeReportToParent();
    return data;
}

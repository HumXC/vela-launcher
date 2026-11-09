//! Bounded local artwork processing. Workers never touch DVUI window/backend state.
const std = @import("std");
const dvui = @import("dvui");
const surface = @import("surface.zig");
const appearance = @import("../core/appearance.zig");
const fs = @import("../core/content_fs.zig");
const A = std.mem.Allocator;
const heap = std.heap.page_allocator;
pub const extensions = "png;jpg;jpeg;webp";
pub const max_file_bytes = 32 * 1024 * 1024;
const max_pixels = 24_000_000;
const max_side = 1440;
extern fn stbi_info_from_memory([*]const u8, c_int, *c_int, *c_int, *c_int) c_int;
extern fn WebPGetInfo([*]const u8, usize, *c_int, *c_int) c_int;
const webp_decoder = @import("../core/webp_decode.zig");

/// UI-thread reference count. Jobs transfer ownership only after done/acquire.
pub const Image = struct {
    refs: usize = 1,
    bytes: []u8,
    path: []u8,
    width: u32,
    height: u32,
    pixels: [4][]dvui.Color.PMA,
    digest: [32]u8,
    extension: []const u8,

    pub fn retain(self: *Image) *Image {
        self.refs += 1;
        return self;
    }
    pub fn release(self: *Image) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        for (self.pixels) |pixels| heap.free(pixels);
        heap.free(self.bytes);
        heap.free(self.path);
        heap.destroy(self);
    }
    pub fn source(self: *Image, blur_radius: u8) dvui.ImageSource {
        const index: usize = switch (blur_radius) {
            4 => 1,
            8 => 2,
            16 => 3,
            else => 0,
        };
        return .{ .pixelsPMA = .{ .rgba = self.pixels[index], .width = self.width, .height = self.height } };
    }
};

const Job = struct {
    io: std.Io,
    path: []u8,
    generation: u64,
    done: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    wake: std.Io.Event = .unset,
    result: ?*Image = null,
    failure: ?anyerror = null,

    fn requestCancel(self: *Job) void {
        self.cancel.store(true, .release);
        self.wake.set(self.io);
    }

    // The coordinator owns the future and is always joined before freeing the Job
    // or the caller's Io. UI cancellation only signals this event; it never waits
    // for decoding. Future.cancel interrupts cancellable open/stat/read operations.
    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        var future = self.io.concurrent(Job.process, .{self}) catch |err| {
            self.failure = err;
            return;
        };
        self.wake.waitUncancelable(self.io);
        if (self.cancel.load(.acquire)) {
            future.cancel(self.io);
        } else {
            future.await(self.io);
        }
    }

    fn process(self: *Job) void {
        defer self.wake.set(self.io);
        self.result = decode(self.io, self.path, &self.cancel) catch |err| blk: {
            self.failure = err;
            break :blk null;
        };
    }
    fn destroy(self: *Job) void {
        if (self.thread) |thread| thread.join();
        if (self.result) |result| result.release();
        heap.free(self.path);
        heap.destroy(self);
    }
};

/// At most one decoder per slot, with a joined coordinator for I/O cancellation.
pub const Cache = struct {
    io: std.Io,
    wanted: ?[]u8 = null,
    generation: u64 = 0,
    attempted: u64 = 0,
    resolved: ?u64 = null,
    image: ?*Image = null,
    job: ?*Job = null,
    failure: ?anyerror = null,

    pub fn init(io: std.Io) Cache {
        return .{ .io = io };
    }
    pub fn deinit(self: *Cache) void {
        if (self.job) |job| {
            job.requestCancel();
            job.destroy();
        }
        if (self.image) |image| image.release();
        if (self.wanted) |path| heap.free(path);
        self.* = .{ .io = self.io };
    }
    pub fn request(self: *Cache, path: ?[]const u8) !void {
        if (samePath(self.wanted, path)) return;
        const owned = if (path) |p| try heap.dupe(u8, p) else null;
        if (self.wanted) |p| heap.free(p);
        self.wanted = owned;
        self.generation +%= 1;
        self.failure = null;
        if (self.job) |job| job.requestCancel();
        if (path == null) {
            if (self.image) |image| image.release();
            self.image = null;
        }
    }
    pub fn retry(self: *Cache) void {
        self.generation +%= 1;
        self.failure = null;
        if (self.job) |job| job.requestCancel();
    }
    pub fn poll(self: *Cache) void {
        if (self.job) |job| {
            if (!job.done.load(.acquire)) return;
            if (job.generation == self.generation) {
                self.failure = job.failure;
                if (job.result) |image| {
                    // A new allocation may reuse a recently freed pixel address.
                    // Invalidate that address once, on the UI thread, before drawing.
                    for ([_]u8{ 0, 4, 8, 16 }) |radius| dvui.textureInvalidateCache(image.source(radius).hash());
                    if (self.image) |old| old.release();
                    self.image = image;
                    self.resolved = self.generation;
                    job.result = null;
                }
            }
            job.destroy();
            self.job = null;
        }
        const path = self.wanted orelse return;
        if (self.attempted == self.generation) return;
        self.attempted = self.generation;
        const job = heap.create(Job) catch |err| {
            self.failure = err;
            return;
        };
        const owned = heap.dupe(u8, path) catch |err| {
            heap.destroy(job);
            self.failure = err;
            return;
        };
        job.* = .{ .io = self.io, .path = owned, .generation = self.generation };
        job.thread = std.Thread.spawn(.{}, Job.run, .{job}) catch |err| {
            job.destroy();
            self.failure = err;
            return;
        };
        self.job = job;
    }
    pub fn ready(self: *const Cache) bool {
        return self.image != null and self.wanted != null and self.failure == null and self.job == null and self.resolved == self.generation;
    }
    /// Reuse already processed data after a successful publication, avoiding decoding twice.
    pub fn adopt(self: *Cache, image: *Image, path: []const u8) !void {
        try self.request(path);
        // Supersede a decoder still finishing the same path as well as path changes.
        self.generation +%= 1;
        if (self.job) |job| job.requestCancel();
        self.failure = null;
        const retained = image.retain();
        if (self.image) |old| old.release();
        self.image = retained;
        self.attempted = self.generation;
        self.resolved = self.generation;
    }
};

pub fn samePath(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |left| return if (b) |right| std.mem.eql(u8, left, right) else false;
    return b == null;
}

fn checkCancelled(cancel: *std.atomic.Value(bool)) !void {
    if (cancel.load(.acquire)) return error.Cancelled;
}

// Check both before open (a FIFO without a writer blocks in open itself) and
// after open (the path may have been replaced). All I/O runs in a cancellable
// future, including the open between these checks. Never read a stream to EOF.
fn readImageBytes(io: std.Io, path: []const u8, cancel: *std.atomic.Value(bool)) ![]u8 {
    try checkCancelled(cancel);
    const before = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (before.kind != .file) return error.BackgroundImageNotRegularFile;
    if (before.size > max_file_bytes) return error.BackgroundImageTooLarge;
    try checkCancelled(cancel);
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.BackgroundImageNotRegularFile;
    if (stat.size > max_file_bytes) return error.BackgroundImageTooLarge;
    const bytes = try heap.alloc(u8, @intCast(stat.size));
    errdefer heap.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        try checkCancelled(cancel);
        const end = @min(bytes.len, offset + 64 * 1024);
        const count = try file.readPositional(io, &.{bytes[offset..end]}, offset);
        if (count == 0) return error.InvalidBackgroundImage;
        offset += count;
    }
    try checkCancelled(cancel);
    // Reject growth instead of silently retaining a prefix of the source file.
    var extra: [1]u8 = undefined;
    if (try file.readPositional(io, &.{&extra}, offset) != 0) return error.BackgroundImageChanged;
    return bytes;
}

fn decode(io: std.Io, path: []const u8, cancel: *std.atomic.Value(bool)) !*Image {
    const bytes = try readImageBytes(io, path, cancel);
    errdefer heap.free(bytes);
    if (bytes.len < 12) return error.InvalidBackgroundImage;
    const png = std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n");
    const jpeg = bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff;
    const webp = std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP");
    if (!png and !jpeg and !webp) return error.UnsupportedBackgroundFormat;
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    if (webp) {
        if (WebPGetInfo(bytes.ptr, bytes.len, &width, &height) == 0) return error.InvalidBackgroundImage;
    } else if (stbi_info_from_memory(bytes.ptr, @intCast(bytes.len), &width, &height, &channels) == 0) return error.InvalidBackgroundImage;
    if (width <= 0 or height <= 0 or width > 8192 or height > 8192) return error.BackgroundImageTooLarge;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    if (w * h > max_pixels) return error.BackgroundImageTooLarge;
    try checkCancelled(cancel);
    // Bound PNG expansion before STB's permissive inflater allocates anything.
    if (png) try validatePng(bytes, w, h);
    const rgba: []u8 = if (webp) blk: {
        const data = try heap.alloc(u8, w * h * 4);
        errdefer heap.free(data);
        webp_decoder.rgbaInto(io, bytes, data, @intCast(w * 4)) catch |err| return if (err == error.Canceled) err else error.InvalidBackgroundImage;
        break :blk data;
    } else blk: {
        const data = dvui.c.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &width, &height, &channels, 4) orelse return error.InvalidBackgroundImage;
        break :blk data[0 .. w * h * 4];
    };
    defer if (webp) heap.free(rgba) else dvui.c.stbi_image_free(rgba.ptr);
    if (width != @as(c_int, @intCast(w)) or height != @as(c_int, @intCast(h))) return error.InvalidBackgroundImage;
    const longest = @max(w, h);
    const out_w = @max(1, w * @min(longest, max_side) / longest);
    const out_h = @max(1, h * @min(longest, max_side) / longest);
    var variants: [4][]dvui.Color.PMA = undefined;
    var allocated: usize = 0;
    errdefer for (variants[0..allocated]) |pixels| heap.free(pixels);
    variants[0] = try heap.alloc(dvui.Color.PMA, out_w * out_h);
    allocated = 1;
    for (0..out_h) |y| {
        try checkCancelled(cancel);
        for (0..out_w) |x| {
            const at = ((y * h / out_h) * w + x * w / out_w) * 4;
            const alpha: u16 = rgba[at + 3];
            variants[0][y * out_w + x] = .{ .r = @intCast((@as(u16, rgba[at]) * alpha + 127) / 255), .g = @intCast((@as(u16, rgba[at + 1]) * alpha + 127) / 255), .b = @intCast((@as(u16, rgba[at + 2]) * alpha + 127) / 255), .a = @intCast(alpha) };
        }
    }
    for ([_]usize{ 4, 8, 16 }, 1..) |radius, index| {
        variants[index] = try heap.alloc(dvui.Color.PMA, out_w * out_h);
        allocated += 1;
        try blur(variants[0], variants[index], out_w, out_h, radius, cancel);
    }
    const owned_path = try heap.dupe(u8, path);
    errdefer heap.free(owned_path);
    const image = try heap.create(Image);
    image.* = .{ .bytes = bytes, .path = owned_path, .width = @intCast(out_w), .height = @intCast(out_h), .pixels = variants, .digest = undefined, .extension = if (png) "png" else if (jpeg) "jpg" else "webp" };
    std.crypto.hash.sha2.Sha256.hash(bytes, &image.digest, .{});
    return image;
}

fn validatePng(bytes: []const u8, width: usize, height: usize) !void {
    if (bytes.len < 33 or !std.mem.eql(u8, bytes[12..16], "IHDR") or std.mem.readInt(u32, bytes[8..12], .big) != 13) return error.InvalidBackgroundImage;
    if (std.mem.readInt(u32, bytes[16..20], .big) != width or std.mem.readInt(u32, bytes[20..24], .big) != height or bytes[26] != 0 or bytes[27] != 0 or bytes[28] > 1) return error.InvalidBackgroundImage;
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(heap);
    var offset: usize = 8;
    while (offset < bytes.len) {
        if (bytes.len - offset < 12) return error.InvalidBackgroundImage;
        const len: usize = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        if (len > bytes.len - offset - 12) return error.InvalidBackgroundImage;
        const kind = bytes[offset + 4 ..][0..4];
        if (offset != 8 and std.mem.eql(u8, kind, "IHDR")) return error.InvalidBackgroundImage;
        if (std.mem.eql(u8, kind, "IDAT")) try compressed.appendSlice(heap, bytes[offset + 8 ..][0..len]);
        offset += len + 12;
    }
    // Sixteen-bit RGBA plus per-row filters and Adam7 overhead, bounded by dimensions.
    const budget = height * (width * 8 + 8) + 8192;
    const raw = try @import("nbt_compression").decompress(heap, compressed.items, .zlib, budget, true);
    heap.free(raw);
}

/// Two sliding-window passes: O(pixels), independent of selected radius.
fn blur(input: []const dvui.Color.PMA, output: []dvui.Color.PMA, width: usize, height: usize, radius: usize, cancel: *std.atomic.Value(bool)) !void {
    const temp = try heap.alloc(dvui.Color.PMA, input.len);
    defer heap.free(temp);
    for (0..2) |pass| {
        const src: []const dvui.Color.PMA = if (pass == 0) input else temp;
        const dst = if (pass == 0) temp else output;
        const lines = if (pass == 0) height else width;
        const length = if (pass == 0) width else height;
        const stride = if (pass == 0) @as(usize, 1) else width;
        for (0..lines) |line| {
            try checkCancelled(cancel);
            const base = if (pass == 0) line * width else line;
            var sums: [4]u32 = @splat(0);
            var left: usize = 0;
            var right: usize = 0;
            for (0..length) |position| {
                const end = @min(length, position + radius + 1);
                while (right < end) : (right += 1) addPixel(&sums, src[base + right * stride]);
                const start = position -| radius;
                while (left < start) : (left += 1) subPixel(&sums, src[base + left * stride]);
                const count: u32 = @intCast(right - left);
                dst[base + position * stride] = .{ .r = @intCast(sums[0] / count), .g = @intCast(sums[1] / count), .b = @intCast(sums[2] / count), .a = @intCast(sums[3] / count) };
            }
        }
    }
}
fn addPixel(sum: *[4]u32, p: dvui.Color.PMA) void {
    sum[0] += p.r;
    sum[1] += p.g;
    sum[2] += p.b;
    sum[3] += p.a;
}
fn subPixel(sum: *[4]u32, p: dvui.Color.PMA) void {
    sum[0] -= p.r;
    sum[1] -= p.g;
    sum[2] -= p.b;
    sum[3] -= p.a;
}

/// Returns an owned absolute path. Retained original bytes survive source deletion.
/// Content-addressed copies are retained on config failure (including uncertain publish).
pub fn persist(image: *Image, a: A, io: std.Io, root: []const u8) ![]u8 {
    return persistBytes(a, io, root, image.bytes, image.digest, image.extension);
}

fn persistBytes(a: A, io: std.Io, root: []const u8, bytes: []const u8, digest: [32]u8, extension: []const u8) ![]u8 {
    const directory_path = try std.fs.path.join(a, &.{ root, ".vela", "backgrounds" });
    defer a.free(directory_path);
    const directory = try std.Io.Dir.cwd().createDirPathOpen(io, directory_path, .{ .open_options = .{ .iterate = true } });
    defer directory.close(io);
    const name = try std.fmt.allocPrint(a, "{s}.{s}", .{ std.fmt.bytesToHex(digest, .lower), extension });
    defer a.free(name);
    const path = try std.fs.path.join(a, &.{ directory_path, name });
    errdefer a.free(path);
    var atomic = try directory.createFileAtomic(io, name, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
    try fs.syncDir(directory, io);
    const parent = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer parent.close(io);
    const vela = try parent.openDir(io, ".vela", .{ .iterate = true });
    defer vela.close(io);
    try fs.syncDir(vela, io);
    try fs.syncDir(parent, io);
    return path;
}

pub fn rgb(value: u32) dvui.Color {
    return .{ .r = @intCast((value >> 16) & 255), .g = @intCast((value >> 8) & 255), .b = @intCast(value & 255) };
}

/// Draw one screen-aligned backdrop region, including rounded glass panels.
pub fn draw(image: *Image, settings: appearance.Settings, screen: dvui.RectScale) void {
    drawRegion(image, settings, screen, screen, .{});
}

pub fn drawRegion(image: *Image, settings: appearance.Settings, screen: dvui.RectScale, region: dvui.RectScale, corners: dvui.CornerRect) void {
    if (screen.r.w <= 0 or screen.r.h <= 0 or region.r.w <= 0 or region.r.h <= 0) return;
    const old_clip = dvui.clip(region.r);
    defer dvui.clipSet(old_clip);
    surface.fill(region, corners, .{ .color = rgb(settings.background_color) });
    var target = screen;
    var uv: dvui.Rect = .{ .w = 1, .h = 1 };
    const iw: f32 = @floatFromInt(image.width);
    const ih: f32 = @floatFromInt(image.height);
    const scale_x = screen.r.w / iw;
    const scale_y = screen.r.h / ih;
    switch (settings.image_layout) {
        .fill => {
            const scale = @max(scale_x, scale_y);
            uv.w = screen.r.w / (iw * scale);
            uv.h = screen.r.h / (ih * scale);
            uv.x = (1 - uv.w) / 2;
            uv.y = (1 - uv.h) / 2;
        },
        .fit => {
            const scale = @min(scale_x, scale_y);
            target.r.w = iw * scale;
            target.r.h = ih * scale;
            target.r.x += (screen.r.w - target.r.w) / 2;
            target.r.y += (screen.r.h - target.r.h) / 2;
        },
        .stretch => {},
    }
    const region_clip = dvui.clip(target.r);
    surface.renderImage(image.source(settings.image_blur), region, .{ .uv = uv, .uv_rect = target.r, .corners = corners }) catch {};
    dvui.clipSet(region_clip);
    surface.fill(region, corners, .{ .color = .{ .r = 0, .g = 0, .b = 0, .a = @intCast(@as(u16, settings.image_dimming) * 255 / 100) } });
}

test "managed background copy persists retained bytes after source deletion and supports retry" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = "retained background image bytes";
    try tmp.dir.writeFile(io, .{ .sub_path = "source.jpg", .data = original });
    const retained = try tmp.dir.readFileAlloc(io, "source.jpg", a, .limited(1024));
    defer a.free(retained);
    try tmp.dir.deleteFile(io, "source.jpg");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(retained, &digest, .{});
    const first = try persistBytes(a, io, root, retained, digest, "jpg");
    defer a.free(first);
    const second = try persistBytes(a, io, root, retained, digest, "jpg");
    defer a.free(second);
    try std.testing.expectEqualStrings(first, second);
    const saved = try std.Io.Dir.cwd().readFileAlloc(io, second, a, .limited(1024));
    defer a.free(saved);
    try std.testing.expectEqualStrings(original, saved);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "source.jpg", .{}));
}

fn waitForImageJob(job: *Job) !void {
    const io = std.testing.io;
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5 * std.time.ns_per_s;
    while (!job.done.load(.acquire)) {
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return error.BackgroundJobTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "background image rejects FIFO without writer and replacement still completes" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const linux = std.os.linux;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.mknodat(tmp.dir.handle, "artwork.fifo", linux.S.IFIFO | 0o600, 0)));
    const fifo = try tmp.dir.realPathFileAlloc(io, "artwork.fifo", a);
    defer a.free(fifo);
    var cancel: std.atomic.Value(bool) = .init(false);
    try std.testing.expectError(error.BackgroundImageNotRegularFile, readImageBytes(io, fifo, &cancel));
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try std.testing.expectError(error.BackgroundImageNotRegularFile, readImageBytes(io, root, &cancel));

    try tmp.dir.writeFile(io, .{ .sub_path = "invalid.png", .data = "not an image but a regular file" });
    const regular = try tmp.dir.realPathFileAlloc(io, "invalid.png", a);
    defer a.free(regular);
    const bytes = try readImageBytes(io, regular, &cancel);
    defer heap.free(bytes);
    try std.testing.expectEqualStrings("not an image but a regular file", bytes);

    var cache = Cache.init(io);
    defer cache.deinit();
    try cache.request(fifo);
    cache.poll();
    try waitForImageJob(cache.job orelse return error.BackgroundJobMissing);
    cache.poll();
    try std.testing.expectEqual(error.BackgroundImageNotRegularFile, cache.failure.?);
    try cache.request(regular);
    cache.poll();
    try waitForImageJob(cache.job orelse return error.BackgroundJobMissing);
    cache.poll();
    try std.testing.expectEqual(error.UnsupportedBackgroundFormat, cache.failure.?);
    try std.testing.expect(cache.job == null);
}

test "background image cancels blocked open on replacement retry and shutdown" {
    const io = std.testing.io;
    const Harness = struct {
        var entered: std.Io.Event = .unset;
        var canceled: std.atomic.Value(usize) = .init(0);

        fn stat(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir.StatFileOptions) std.Io.Dir.StatFileError!std.Io.File.Stat {
            // Model a regular path swapped for a FIFO between stat and open.
            return .{ .inode = 0, .nlink = 1, .size = 12, .permissions = .default_file, .kind = .file, .atime = null, .mtime = .{ .nanoseconds = 0 }, .ctime = .{ .nanoseconds = 0 }, .block_size = 1 };
        }

        fn open(_: ?*anyopaque, _: std.Io.Dir, path: []const u8, _: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
            if (!std.mem.eql(u8, path, "blocked")) return error.FileNotFound;
            entered.set(std.testing.io);
            std.testing.io.sleep(.fromSeconds(30), .awake) catch |err| {
                _ = canceled.fetchAdd(1, .monotonic);
                return err;
            };
            return error.FileNotFound;
        }

        fn waitEntered() !void {
            const deadline: std.Io.Timeout = .{ .deadline = .fromNow(std.testing.io, .{ .raw = .fromSeconds(5), .clock = .awake }) };
            while (!entered.isSet()) entered.waitTimeout(std.testing.io, deadline) catch |err| switch (err) {
                error.Timeout => if (std.Io.Clock.awake.now(std.testing.io).nanoseconds >= deadline.deadline.raw.nanoseconds) return err,
                else => return err,
            };
        }
    };
    Harness.entered.reset();
    Harness.canceled.store(0, .monotonic);
    var vtable = io.vtable.*;
    vtable.dirStatFile = Harness.stat;
    vtable.dirOpenFile = Harness.open;
    const controlled: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var cache = Cache.init(controlled);
    defer cache.deinit();

    try cache.request("blocked");
    cache.poll();
    try Harness.waitEntered();
    try cache.request("replacement");
    try waitForImageJob(cache.job.?);
    cache.poll();
    try waitForImageJob(cache.job orelse return error.BackgroundJobMissing);
    cache.poll();
    try std.testing.expectEqual(error.FileNotFound, cache.failure.?);
    try std.testing.expectEqual(@as(usize, 1), Harness.canceled.load(.monotonic));

    Harness.entered.reset();
    try cache.request("blocked");
    cache.poll();
    try Harness.waitEntered();
    cache.retry();
    try waitForImageJob(cache.job.?);
    Harness.entered.reset();
    cache.poll();
    try Harness.waitEntered();
    try std.testing.expectEqual(@as(usize, 2), Harness.canceled.load(.monotonic));
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    cache.deinit();
    try std.testing.expect(std.Io.Clock.awake.now(io).nanoseconds - start < 2 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(usize, 3), Harness.canceled.load(.monotonic));
    try std.testing.expect(cache.job == null);
}

test "background image rejects oversized stat before opening" {
    const Harness = struct {
        fn stat(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir.StatFileOptions) std.Io.Dir.StatFileError!std.Io.File.Stat {
            return .{ .inode = 0, .nlink = 1, .size = max_file_bytes + 1, .permissions = .default_file, .kind = .file, .atime = null, .mtime = .{ .nanoseconds = 0 }, .ctime = .{ .nanoseconds = 0 }, .block_size = 1 };
        }
        fn open(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
            return error.Unexpected;
        }
    };
    const io = std.testing.io;
    var vtable = io.vtable.*;
    vtable.dirStatFile = Harness.stat;
    vtable.dirOpenFile = Harness.open;
    const controlled: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var cancel: std.atomic.Value(bool) = .init(false);
    try std.testing.expectError(error.BackgroundImageTooLarge, readImageBytes(controlled, "oversized", &cancel));
}

test "background image rechecks opened handle and bounds growing files" {
    const Harness = struct {
        fn nonRegular(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.StatError!std.Io.File.Stat {
            var stat = try std.testing.io.vtable.fileStat(userdata, file);
            stat.kind = .named_pipe;
            return stat;
        }
        fn smaller(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.StatError!std.Io.File.Stat {
            var stat = try std.testing.io.vtable.fileStat(userdata, file);
            stat.size = 1;
            return stat;
        }
    };
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "growing.png", .data = "more than one byte" });
    const path = try tmp.dir.realPathFileAlloc(io, "growing.png", a);
    defer a.free(path);
    var vtable = io.vtable.*;
    vtable.fileStat = Harness.nonRegular;
    const controlled: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var cancel: std.atomic.Value(bool) = .init(false);
    try std.testing.expectError(error.BackgroundImageNotRegularFile, readImageBytes(controlled, path, &cancel));
    vtable.fileStat = Harness.smaller;
    try std.testing.expectError(error.BackgroundImageChanged, readImageBytes(controlled, path, &cancel));
}

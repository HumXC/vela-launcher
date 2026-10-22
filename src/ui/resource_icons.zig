//! UI-owned bounded image cache. Public artwork loads independently of content mutations.
const std = @import("std");
const dvui = @import("dvui");
const transport = @import("../core/content_transport.zig");
const http = @import("../core/http_transport.zig");
const providers = @import("../core/content_providers.zig");
const local = @import("../core/local_content.zig");
const theme = @import("theme.zig");
const A = std.mem.Allocator;
pub const side = 64;
pub const Bitmap = [side * side]dvui.Color.PMA;
const max_bytes = 2 * 1024 * 1024;
const capacity = 48;
extern fn WebPGetInfo([*]const u8, usize, *c_int, *c_int) c_int;
extern fn WebPDecodeRGBAInto([*]const u8, usize, [*]u8, usize, c_int) ?[*]u8;
extern fn stbi_info_from_memory([*]const u8, c_int, *c_int, *c_int, *c_int) c_int;

pub fn allowedUrl(url: []const u8) bool {
    if (url.len > 4096 or !providers.safeHttpsUrl(url)) return false;
    const uri = std.Uri.parse(url) catch return false;
    const host = uri.host.?.percent_encoded;
    return std.ascii.eqlIgnoreCase(host, "cdn.modrinth.com") or std.ascii.eqlIgnoreCase(host, "media.forgecdn.net") or std.ascii.eqlIgnoreCase(host, "mediafilez.forgecdn.net") or std.ascii.eqlIgnoreCase(host, "edge.forgecdn.net");
}

/// Decodes on the worker. Every cache entry retains only a 64x64 thumbnail.
pub fn decode(a: A, bytes: []const u8) !Bitmap {
    if (bytes.len < 12 or bytes.len > max_bytes) return error.InvalidIcon;
    var width: c_int = 0;
    var height: c_int = 0;
    const webp = std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP");
    var channels: c_int = 0;
    if (webp) {
        if (WebPGetInfo(bytes.ptr, bytes.len, &width, &height) == 0) return error.InvalidIcon;
    } else if (stbi_info_from_memory(bytes.ptr, @intCast(bytes.len), &width, &height, &channels) == 0) return error.InvalidIcon;
    if (width <= 0 or height <= 0 or width > 1024 or height > 1024) return error.InvalidIcon;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) {
        try local.validatePng(bytes);
        var compressed: std.ArrayList(u8) = .empty;
        defer compressed.deinit(a);
        var offset: usize = 8;
        while (offset < bytes.len) {
            const len = std.mem.readInt(u32, bytes[offset..][0..4], .big);
            if (std.mem.eql(u8, bytes[offset + 4 ..][0..4], "IDAT")) try compressed.appendSlice(a, bytes[offset + 8 ..][0..len]);
            offset += len + 12;
        }
        const raw = try @import("nbt_compression").decompress(a, compressed.items, .zlib, 9 * 1024 * 1024, true);
        a.free(raw);
    }
    var result: Bitmap = @splat(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
    if (webp) {
        const rgba = try a.alloc(u8, w * h * 4);
        defer a.free(rgba);
        if (WebPDecodeRGBAInto(bytes.ptr, bytes.len, rgba.ptr, rgba.len, @intCast(w * 4)) == null) return error.InvalidIcon;
        for (&result, 0..) |*pixel, i| {
            const at = (sampleIndex(i, w, h) orelse continue) * 4;
            const alpha: u16 = rgba[at + 3];
            pixel.* = .{ .r = @intCast((@as(u16, rgba[at]) * alpha + 127) / 255), .g = @intCast((@as(u16, rgba[at + 1]) * alpha + 127) / 255), .b = @intCast((@as(u16, rgba[at + 2]) * alpha + 127) / 255), .a = @intCast(alpha) };
        }
    } else {
        const image = try dvui.Color.PMAImage.fromImageFile("resource-icon", a, bytes);
        defer a.free(image.pma);
        for (&result, 0..) |*pixel, i| if (sampleIndex(i, w, h)) |at| {
            pixel.* = image.pma[at];
        };
    }
    return result;
}

fn sampleIndex(index: usize, width: usize, height: usize) ?usize {
    const fit_w = if (width >= height) side else @max(1, width * side / height);
    const fit_h = if (height >= width) side else @max(1, height * side / width);
    const x = index % side;
    const y = index / side;
    const left = (side - fit_w) / 2;
    const top = (side - fit_h) / 2;
    if (x < left or x >= left + fit_w or y < top or y >= top + fit_h) return null;
    return (y - top) * height / fit_h * width + (x - left) * width / fit_w;
}
const Job = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    url: []const u8,
    options: transport.Adapter.Options,
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,
    bitmap: ?Bitmap = null,
    fn create(io: std.Io, url: []const u8, options: transport.Adapter.Options) !*Job {
        const job = try std.heap.page_allocator.create(Job);
        errdefer std.heap.page_allocator.destroy(job);
        job.* = .{ .arena = .init(std.heap.page_allocator), .io = io, .url = undefined, .options = options };
        errdefer job.arena.deinit();
        const a = job.arena.allocator();
        job.url = try a.dupe(u8, url);
        if (options.http.proxy) |proxy| job.options.http.proxy = try a.dupe(u8, proxy);
        if (options.http.ca_bundle) |ca| job.options.http.ca_bundle = try a.dupe(u8, ca);
        return job;
    }
    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        if (self.cancel.load(.acquire)) return;
        self.fetch() catch {};
    }
    fn fetch(self: *Job) !void {
        const a = self.arena.allocator();
        const request: http.Request = .{ .url = self.url, .max_response_bytes = max_bytes, .timeout_ms = 5000, .cancel = &self.cancel, .require_public_address = true, .headers = &.{.{ .name = "User-Agent", .value = transport.user_agent }} };
        var response = if (self.options.fixture_http) |get| try get(self.options.fixture_context, a, self.io, request) else response: {
            var client = try http.Client.init(a, self.io, self.options.http);
            defer client.deinit();
            break :response try client.executeBinary(request);
        };
        defer response.deinit();
        if (response.status != 200 or self.cancel.load(.acquire)) return error.IconUnavailable;
        const bitmap = try decode(a, response.body);
        if (!self.cancel.load(.acquire)) self.bitmap = bitmap;
    }
    fn destroy(self: *Job) void {
        self.arena.deinit();
        std.heap.page_allocator.destroy(self);
    }
};
const Entry = struct { url: []const u8, bitmap: ?*Bitmap = null, disabled_bitmap: ?*Bitmap = null, touched: u64 = 0, retry_at: i64 = 0, pending: bool = true };
pub const Manager = struct {
    allocator: A,
    io: std.Io,
    entries: std.ArrayList(Entry) = .empty,
    active: ?*Job = null,
    clock: u64 = 0,
    pub fn init(a: A, io: std.Io) Manager {
        return .{ .allocator = a, .io = io };
    }
    pub fn deinit(self: *Manager) void {
        if (self.active) |job| {
            job.cancel.store(true, .release);
            if (job.future) |*future| future.cancel(self.io);
            job.destroy();
        }
        for (self.entries.items) |entry| self.freeEntry(entry);
        self.entries.deinit(self.allocator);
    }
    fn freeEntry(self: *Manager, entry: Entry) void {
        self.allocator.free(entry.url);
        if (entry.bitmap) |bitmap| self.allocator.destroy(bitmap);
        if (entry.disabled_bitmap) |bitmap| self.allocator.destroy(bitmap);
    }
    pub fn localDisabled(self: *Manager, bytes: []const u8) ?*const Bitmap {
        const original = self.local(bytes) orelse return null;
        for (self.entries.items) |*entry| {
            if (entry.bitmap != original) continue;
            if (entry.disabled_bitmap) |bitmap| return bitmap;
            const bitmap = self.allocator.create(Bitmap) catch return null;
            for (original, bitmap) |pixel, *gray| {
                const luminance = (@as(u32, pixel.r) * 54 + @as(u32, pixel.g) * 183 + @as(u32, pixel.b) * 19) * 85 / 25600;
                gray.* = .{ .r = @intCast(luminance), .g = @intCast(luminance), .b = @intCast(luminance), .a = pixel.a };
            }
            entry.disabled_bitmap = bitmap;
            return bitmap;
        }
        return null;
    }
    pub fn local(self: *Manager, bytes: []const u8) ?*const Bitmap {
        var storage: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&storage, "local:{x}", .{std.hash.Wyhash.hash(0, bytes)}) catch return null;
        self.clock +%= 1;
        for (self.entries.items) |*entry| if (std.mem.eql(u8, entry.url, key)) {
            entry.touched = self.clock;
            return entry.bitmap;
        };
        if (self.entries.items.len == capacity) {
            var victim: ?usize = null;
            for (self.entries.items, 0..) |entry, i| {
                if (self.active) |job| if (std.mem.eql(u8, job.url, entry.url)) continue;
                if (victim == null or entry.touched < self.entries.items[victim.?].touched) victim = i;
            }
            if (victim) |i| self.freeEntry(self.entries.swapRemove(i)) else return null;
        }
        const value = decode(self.allocator, bytes) catch null;
        const bitmap = if (value) |image| block: {
            const owned = self.allocator.create(Bitmap) catch return null;
            owned.* = image;
            break :block owned;
        } else null;
        const owned = self.allocator.dupe(u8, key) catch {
            if (bitmap) |image| self.allocator.destroy(image);
            return null;
        };
        self.entries.append(self.allocator, .{ .url = owned, .bitmap = bitmap, .touched = self.clock, .pending = false, .retry_at = std.math.maxInt(i64) }) catch {
            self.freeEntry(.{ .url = owned, .bitmap = bitmap });
            return null;
        };
        return bitmap;
    }
    pub fn get(self: *Manager, url: ?[]const u8) ?*const Bitmap {
        const value = url orelse return null;
        if (!allowedUrl(value)) return null;
        self.clock +%= 1;
        for (self.entries.items) |*entry| if (std.mem.eql(u8, entry.url, value)) {
            entry.touched = self.clock;
            if (entry.bitmap == null and now(self.io) >= entry.retry_at) entry.pending = true;
            return entry.bitmap;
        };
        if (self.entries.items.len == capacity) {
            var victim: ?usize = null;
            for (self.entries.items, 0..) |entry, i| {
                if (self.active) |job| if (std.mem.eql(u8, job.url, entry.url)) continue;
                if (victim == null or entry.touched < self.entries.items[victim.?].touched) victim = i;
            }
            if (victim) |i| self.freeEntry(self.entries.swapRemove(i)) else return null;
        }
        const owned = self.allocator.dupe(u8, value) catch return null;
        self.entries.append(self.allocator, .{ .url = owned, .touched = self.clock }) catch {
            self.allocator.free(owned);
        };
        return null;
    }
    pub fn poll(self: *Manager, options: transport.Adapter.Options) void {
        if (self.active) |job| {
            if (!job.done.load(.acquire)) return;
            if (job.future) |*future| future.await(self.io);
            for (self.entries.items) |*entry| if (std.mem.eql(u8, entry.url, job.url)) {
                if (job.bitmap) |bitmap| {
                    const owned = self.allocator.create(Bitmap) catch break;
                    owned.* = bitmap;
                    if (entry.bitmap) |old| self.allocator.destroy(old);
                    entry.bitmap = owned;
                }
                entry.pending = false;
                entry.retry_at = now(self.io) + 30_000;
                break;
            };
            job.destroy();
            self.active = null;
        }
        for (self.entries.items) |*entry| if (entry.pending) {
            entry.pending = false;
            entry.retry_at = now(self.io) + 30_000;
            const job = Job.create(self.io, entry.url, options) catch return;
            job.future = self.io.concurrent(Job.run, .{job}) catch {
                job.destroy();
                return;
            };
            self.active = job;
            return;
        };
    }
    pub fn busy(self: *const Manager) bool {
        if (self.active != null) return true;
        for (self.entries.items) |entry| if (entry.pending) return true;
        return false;
    }
};
fn now(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).toMilliseconds());
}

pub fn draw(src: std.builtin.SourceLocation, bitmap: ?*const Bitmap, size: f32, rect: ?dvui.Rect) void {
    const options: dvui.Options = .{ .rect = rect, .min_size_content = .all(size), .max_size_content = .size(.all(size)), .padding = .all(0), .margin = .{ .w = if (rect == null) 16 else 0 }, .corners = .all(theme.sizing.control_radius), .gravity_y = 0.5 };
    if (bitmap) |pixels| {
        _ = dvui.image(src, .{ .source = .{ .pixelsPMA = .{ .rgba = @constCast(pixels)[0..], .width = side, .height = side, .invalidation = .bytes } } }, options);
    } else dvui.icon(src, "资源图标", dvui.entypo.archive, .{}, options.override(.{ .color_text = .{ .color = theme.accent } }));
}

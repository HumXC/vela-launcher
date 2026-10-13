//! One application-wide native chooser. All Service methods belong to the UI
//! thread; only Pending.complete may run on another thread. A ticket belongs to
//! its requesting editor, which must take it or discard it when that editor closes.
//! Keep pumping frames after beginShutdown until isDrained, before destroying SDL.
const std = @import("std");

pub const Kind = enum { file, folder };
pub const Options = struct {
    kind: Kind,
    title: []const u8 = "",
    default_path: []const u8 = "",
    /// SDL extension syntax, e.g. "mrpack;zip", not glob syntax "*.zip".
    extensions: ?[]const u8 = null,
};
pub const Ticket = u64;
pub const max_title_bytes = 4096;
pub const max_path_bytes = 32768;
pub const max_extensions_bytes = 1024;
pub const max_error_message_bytes = 65536;

/// Strings returned by take are owned copies allocated with page_allocator.
/// The caller may keep them beyond Service.deinit and must call deinit once.
pub const Result = struct {
    path: ?[]const u8 = null,
    failure: ?anyerror = null,
    error_message: ?[]const u8 = null,

    pub fn deinit(self: *Result) void {
        if (self.path) |path| std.heap.page_allocator.free(path);
        if (self.error_message) |message| std.heap.page_allocator.free(message);
        self.* = .{};
    }
};

/// Borrowed callback data. Null path and null failure represent cancellation.
/// Empty selected paths are normalized to cancellation as well.
pub const Completion = struct {
    path: ?[]const u8 = null,
    failure: ?anyerror = null,
    error_message: ?[]const u8 = null,
};

/// A driver must arrange exactly one complete call, including start failures.
/// start can finish synchronously. context is only borrowed during start.
pub const Driver = struct {
    context: ?*anyopaque = null,
    start: *const fn (?*anyopaque, *Pending) void,
};

/// Heap-stable request, independent of Service's address. Drivers may retain
/// these immutable strings until complete; complete must be their last access
/// to Pending, since it publishes permission for the UI thread to free it.
pub const Pending = struct {
    kind: Kind,
    title: [:0]const u8,
    default_path: [:0]const u8,
    extensions: ?[:0]const u8,
    ticket: Ticket,
    started: bool = false, // UI-thread only
    discarded: bool = false, // UI-thread only
    done: std.atomic.Value(bool) = .init(false),
    result: Result = .{}, // callback writes; UI reads after acquire

    pub fn complete(self: *Pending, completion: Completion) void {
        var result: Result = .{ .failure = completion.failure };
        if (completion.failure == null) {
            if (completion.path) |path| {
                if (path.len != 0) {
                    result.path = copyCallbackText(path, max_path_bytes) catch |err| blk: {
                        result.failure = err;
                        break :blk null;
                    };
                }
            }
        }
        if (completion.error_message) |message| {
            result.error_message = copyCallbackText(message, max_error_message_bytes) catch |err| blk: {
                result.failure = err;
                if (result.path) |path| std.heap.page_allocator.free(path);
                result.path = null;
                break :blk null;
            };
        }
        self.result = result;
        // No allocation, driver cleanup or Pending access after this release.
        self.done.store(true, .release);
    }

    fn destroy(self: *Pending, allocator: std.mem.Allocator) void {
        self.result.deinit();
        allocator.free(self.title);
        allocator.free(self.default_path);
        if (self.extensions) |extensions| allocator.free(extensions);
        allocator.destroy(self);
    }
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    pending: ?*Pending = null,
    next_ticket: Ticket = 1,
    shutting_down: bool = false,

    pub fn init(allocator: std.mem.Allocator) Service {
        return .{ .allocator = allocator };
    }

    /// Queue a chooser; the adapter starts it on the next main-thread pump.
    /// Completed results remain busy until their owner takes or discards them.
    pub fn request(self: *Service, options: Options) !Ticket {
        self.reapDiscarded();
        if (self.shutting_down) return error.ShuttingDown;
        if (self.pending != null) return error.Busy;
        if (self.next_ticket == std.math.maxInt(Ticket)) return error.TicketExhausted;
        try validateText(options.title, max_title_bytes);
        try validateText(options.default_path, max_path_bytes);
        if (options.extensions) |extensions| try validateExtensions(extensions);

        const title = try self.allocator.dupeSentinel(u8, options.title, 0);
        errdefer self.allocator.free(title);
        const default_path = try self.allocator.dupeSentinel(u8, options.default_path, 0);
        errdefer self.allocator.free(default_path);
        const extensions = if (options.extensions) |text| try self.allocator.dupeSentinel(u8, text, 0) else null;
        errdefer if (extensions) |text| self.allocator.free(text);
        const pending = try self.allocator.create(Pending);
        const ticket = self.next_ticket;
        pending.* = .{
            .kind = options.kind,
            .title = title,
            .default_path = default_path,
            .extensions = extensions,
            .ticket = ticket,
        };
        self.pending = pending;
        self.next_ticket += 1;
        return ticket;
    }

    /// Call on the UI/main thread. Set started before calling the driver so an
    /// immediate callback is safe, and never start the same request twice.
    pub fn startPending(self: *Service, driver: Driver) void {
        self.reapDiscarded();
        if (self.shutting_down) return;
        const pending = self.pending orelse return;
        if (pending.started or pending.discarded) return;
        pending.started = true;
        driver.start(driver.context, pending);
    }

    /// Only the requesting owner should call take; stale tickets cannot consume
    /// a newer request. A non-null Result transfers ownership to the caller.
    pub fn take(self: *Service, ticket: Ticket) ?Result {
        self.reapDiscarded();
        const pending = self.pending orelse return null;
        if (pending.ticket != ticket or pending.discarded) return null;
        if (!pending.done.load(.acquire)) return null;
        const result = pending.result;
        pending.result = .{};
        self.pending = null;
        pending.destroy(self.allocator);
        return result;
    }

    /// SDL has no chooser cancellation handle. Invalidate the owner immediately,
    /// but retain a started request until its callback publishes completion.
    pub fn discard(self: *Service, ticket: Ticket) void {
        const pending = self.pending orelse return;
        if (pending.ticket != ticket) return;
        pending.discarded = true;
        self.reapDiscarded();
    }

    pub fn isBusy(self: *Service) bool {
        self.reapDiscarded();
        return self.pending != null;
    }

    pub fn beginShutdown(self: *Service) void {
        self.shutting_down = true;
        if (self.pending) |pending| pending.discarded = true;
        self.reapDiscarded();
    }

    /// Reaps invalidated callback results. Keep SDL and its event loop alive
    /// while false; this method never blocks or dispatches native events itself.
    pub fn isDrained(self: *Service) bool {
        self.reapDiscarded();
        return self.pending == null;
    }

    pub fn deinit(self: *Service) void {
        self.beginShutdown();
        std.debug.assert(self.isDrained());
        self.* = undefined;
    }

    fn reapDiscarded(self: *Service) void {
        const pending = self.pending orelse return;
        if (!pending.discarded) return;
        if (pending.started and !pending.done.load(.acquire)) return;
        self.pending = null;
        pending.destroy(self.allocator);
    }
};

fn validateText(text: []const u8, limit: usize) !void {
    if (text.len > limit) return error.InputTooLong;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.EmbeddedNul;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
}

fn validateExtensions(extensions: []const u8) !void {
    try validateText(extensions, max_extensions_bytes);
    if (std.mem.eql(u8, extensions, "*")) return;
    var parts = std.mem.splitScalar(u8, extensions, ';');
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidExtensions;
        for (part) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.')
                return error.InvalidExtensions;
        }
    }
}

fn copyCallbackText(text: []const u8, limit: usize) ![]const u8 {
    try validateText(text, limit);
    // The caller's allocator may be an arena/GPA without thread safety.
    return try std.heap.page_allocator.dupe(u8, text);
}

const TestDriver = struct {
    pending: ?*Pending = null,
    starts: usize = 0,
    immediate: ?Completion = null,

    fn driver(self: *TestDriver) Driver {
        return .{ .context = self, .start = start };
    }

    fn start(context: ?*anyopaque, pending: *Pending) void {
        const self: *TestDriver = @ptrCast(@alignCast(context.?));
        self.starts += 1;
        self.pending = pending;
        if (self.immediate) |completion| pending.complete(completion);
    }

    fn finish(self: *TestDriver, completion: Completion) void {
        const pending = self.pending.?;
        self.pending = null;
        pending.complete(completion);
    }
};

test "cancel returns an owned empty result exactly once" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();
    var driver: TestDriver = .{};
    const ticket = try service.request(.{ .kind = .folder });
    try std.testing.expect(service.take(ticket) == null);
    service.startPending(driver.driver());
    driver.finish(.{});
    try std.testing.expect(service.isBusy());
    var result = service.take(ticket).?;
    defer result.deinit();
    try std.testing.expect(result.path == null);
    try std.testing.expect(result.failure == null);
    try std.testing.expect(result.error_message == null);
    try std.testing.expect(service.take(ticket) == null);
    try std.testing.expect(!service.isBusy());
}

test "empty callback path is cancellation for file and folder requests" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();
    var driver: TestDriver = .{};
    for ([_]Kind{ .file, .folder }) |kind| {
        const ticket = try service.request(.{ .kind = kind });
        service.startPending(driver.driver());
        // Zenity may return a non-null first entry containing only the NUL.
        driver.finish(.{ .path = "" });
        var result = service.take(ticket).?;
        defer result.deinit();
        try std.testing.expect(result.path == null);
        try std.testing.expect(result.failure == null);
        try std.testing.expect(result.error_message == null);
        try std.testing.expect(service.take(ticket) == null);
        try std.testing.expect(!service.isBusy());
    }
}

test "callback path is copied and survives request and service destruction" {
    var service = Service.init(std.testing.allocator);
    var driver: TestDriver = .{};
    const ticket = try service.request(.{ .kind = .file });
    service.startPending(driver.driver());
    var path = [_]u8{ '/', 't', 'm', 'p', '/', 'a' };
    driver.finish(.{ .path = &path });
    @memset(&path, 'x');
    var result = service.take(ticket).?;
    service.deinit();
    defer result.deinit();
    try std.testing.expectEqualStrings("/tmp/a", result.path.?);
    try std.testing.expect(result.failure == null);
}

test "native failure message is copied on the callback thread" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();
    var driver: TestDriver = .{};
    const ticket = try service.request(.{ .kind = .file });
    service.startPending(driver.driver());
    var message = [_]u8{ 'p', 'o', 'r', 't', 'a', 'l' };
    driver.finish(.{ .failure = error.NativeDialogFailed, .error_message = &message });
    @memset(&message, 'x');
    var result = service.take(ticket).?;
    defer result.deinit();
    try std.testing.expectEqual(error.NativeDialogFailed, result.failure.?);
    try std.testing.expectEqualStrings("portal", result.error_message.?);
    try std.testing.expect(result.path == null);
}

test "queued strings are stable owned UTF8 and NUL terminated" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();
    var driver: TestDriver = .{};
    var title = [_]u8{ 'P', 'a', 'c', 'k' };
    var location = [_]u8{ '/', 'p', 'a', 'c', 'k' };
    var extensions = [_]u8{ 'm', 'r', 'p', 'a', 'c', 'k', ';', 'z', 'i', 'p' };
    const ticket = try service.request(.{ .kind = .file, .title = &title, .default_path = &location, .extensions = &extensions });
    @memset(&title, 'x');
    @memset(&location, 'x');
    @memset(&extensions, 'x');
    service.startPending(driver.driver());
    const pending = driver.pending.?;
    try std.testing.expectEqualStrings("Pack", pending.title);
    try std.testing.expectEqualStrings("/pack", pending.default_path);
    try std.testing.expectEqualStrings("mrpack;zip", pending.extensions.?);
    try std.testing.expectEqual(@as(u8, 0), pending.title[pending.title.len]);
    try std.testing.expectEqual(@as(u8, 0), pending.default_path[pending.default_path.len]);
    try std.testing.expectEqual(@as(u8, 0), pending.extensions.?[pending.extensions.?.len]);
    driver.finish(.{});
    service.discard(ticket);
}

test "one app-wide request remains busy until its owner's result is consumed" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();
    var driver: TestDriver = .{};
    const ticket = try service.request(.{ .kind = .file });
    try std.testing.expectError(error.Busy, service.request(.{ .kind = .folder }));
    service.startPending(driver.driver());
    service.startPending(driver.driver());
    try std.testing.expectEqual(@as(usize, 1), driver.starts);
    try std.testing.expectError(error.Busy, service.request(.{ .kind = .folder }));
    driver.finish(.{ .path = "/tmp/result" });
    try std.testing.expectError(error.Busy, service.request(.{ .kind = .folder }));
    try std.testing.expect(service.take(ticket + 1) == null);
    var result = service.take(ticket).?;
    defer result.deinit();
    const next = try service.request(.{ .kind = .folder });
    try std.testing.expect(next != ticket);
    service.discard(next);
}

test "discarded in-flight ticket cannot leak into another owner" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();
    var driver: TestDriver = .{};
    const old = try service.request(.{ .kind = .file });
    service.startPending(driver.driver());
    service.discard(old);
    try std.testing.expect(service.take(old) == null);
    try std.testing.expect(service.isBusy());
    try std.testing.expect(!service.isDrained());
    try std.testing.expectError(error.Busy, service.request(.{ .kind = .folder }));
    driver.finish(.{ .path = "/late/old/path", .error_message = "late data" });
    try std.testing.expect(!service.isBusy());
    const next = try service.request(.{ .kind = .folder });
    service.discard(old); // Must not invalidate the new owner.
    service.startPending(driver.driver());
    driver.finish(.{ .path = "/new/owner" });
    try std.testing.expect(service.take(old) == null);
    var result = service.take(next).?;
    defer result.deinit();
    try std.testing.expectEqualStrings("/new/owner", result.path.?);
}

test "queued discard never starts a native dialog" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();
    var driver: TestDriver = .{};
    const ticket = try service.request(.{ .kind = .file });
    service.discard(ticket);
    service.startPending(driver.driver());
    try std.testing.expectEqual(@as(usize, 0), driver.starts);
    try std.testing.expect(service.isDrained());
}

test "shutdown invalidates queued and in-flight owners and waits for callback" {
    var service = Service.init(std.testing.allocator);
    var driver: TestDriver = .{};
    const ticket = try service.request(.{ .kind = .file });
    service.startPending(driver.driver());
    service.beginShutdown();
    service.beginShutdown();
    try std.testing.expectError(error.ShuttingDown, service.request(.{ .kind = .folder }));
    try std.testing.expect(service.take(ticket) == null);
    try std.testing.expect(!service.isDrained());
    driver.finish(.{ .failure = error.NativeDialogFailed, .error_message = "shutdown completion" });
    try std.testing.expect(service.isDrained());
    service.deinit();

    var queued = Service.init(std.testing.allocator);
    defer queued.deinit();
    _ = try queued.request(.{ .kind = .folder });
    queued.beginShutdown();
    queued.startPending(driver.driver());
    try std.testing.expect(queued.isDrained());
    try std.testing.expectEqual(@as(usize, 1), driver.starts);
}

test "synchronous callback and moving Service preserve stable storage" {
    var original = Service.init(std.testing.allocator);
    const ticket = try original.request(.{ .kind = .file });
    var moved = original;
    original = undefined; // Move, never use two live copies of Service.
    defer moved.deinit();
    var driver: TestDriver = .{ .immediate = .{ .path = "/immediate" } };
    moved.startPending(driver.driver());
    moved.startPending(driver.driver());
    try std.testing.expectEqual(@as(usize, 1), driver.starts);
    var result = moved.take(ticket).?;
    defer result.deinit();
    try std.testing.expectEqualStrings("/immediate", result.path.?);
}

test "background callback copies payload without the caller's allocator" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();
    var driver: TestDriver = .{};
    const ticket = try service.request(.{ .kind = .folder });
    service.startPending(driver.driver());
    const worker = try std.Thread.spawn(.{}, struct {
        fn run(pending: *Pending) void {
            var path = [_]u8{ '/', 'u', 't', 'f', '8', '/', 0xe4, 0xb8, 0xad };
            pending.complete(.{ .path = &path });
            @memset(&path, 'x');
        }
    }.run, .{driver.pending.?});
    worker.join();
    var result = service.take(ticket).?;
    defer result.deinit();
    try std.testing.expectEqualStrings("/utf8/中", result.path.?);
}

test "request rejects invalid strings and SDL glob patterns before queueing" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();
    try std.testing.expectError(error.EmbeddedNul, service.request(.{ .kind = .file, .title = "bad\x00title" }));
    try std.testing.expectError(error.InvalidUtf8, service.request(.{ .kind = .folder, .default_path = "\xff" }));
    const long_title: [max_title_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InputTooLong, service.request(.{ .kind = .file, .title = &long_title }));
    const bad_extensions = [_][]const u8{ "", "*.zip", "zip;", ";zip", "zip;;mrpack", "zip/mrpack", "zip mrpack" };
    for (bad_extensions) |extensions| {
        try std.testing.expectError(error.InvalidExtensions, service.request(.{ .kind = .file, .extensions = extensions }));
    }
    try std.testing.expect(!service.isBusy());
    const ticket = try service.request(.{ .kind = .file, .extensions = "tar.gz;mr-pack;abc_1" });
    service.discard(ticket);
    service.discard(try service.request(.{ .kind = .file, .extensions = "*" }));
}

test "invalid callback UTF8 is reported rather than returned as a chosen path" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();
    var driver: TestDriver = .{ .immediate = .{ .path = "/bad/\xff" } };
    const ticket = try service.request(.{ .kind = .file });
    service.startPending(driver.driver());
    var result = service.take(ticket).?;
    defer result.deinit();
    try std.testing.expect(result.path == null);
    try std.testing.expectEqual(error.InvalidUtf8, result.failure.?);
}

test "failed request allocations do not strand the service or leak strings" {
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var service = Service.init(allocator);
            defer service.deinit();
            const ticket = try service.request(.{ .kind = .file, .title = "title", .default_path = "/tmp", .extensions = "zip;mrpack" });
            service.discard(ticket);
            try std.testing.expect(service.isDrained());
        }
    }.run, .{});
}

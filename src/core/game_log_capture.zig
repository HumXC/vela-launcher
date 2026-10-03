//! Concurrent process-pipe drainage. Only sanitized bytes cross the bounded handoff.
//! The owner must stop/reap its child before canceling readers or destroying Capture.
const std = @import("std");
const logs = @import("logs.zig");
const Allocator = std.mem.Allocator;
pub const packet_bytes = 4096;
pub const Limits = struct { max_packets: usize = 64, max_secret_bytes: usize = 64 * 1024 };
pub const Status = struct {
    dropped_packets: u64 = 0,
    disk_failure: ?anyerror = null,
    capture_failure: ?anyerror = null,
};
const Packet = struct { source: logs.Source, len: usize, bytes: [packet_bytes]u8 };
const Delivery = struct { packet: Packet, omitted: u64 };

const Queue = struct {
    allocator: Allocator,
    mutex: std.atomic.Mutex = .unlocked,
    packets: []Packet,
    head: usize = 0,
    count: usize = 0,
    pending_omissions: u64 = 0,
    status: Status = .{},

    fn init(a: Allocator, capacity: usize) !Queue {
        if (capacity == 0 or capacity > 4096) return error.InvalidCaptureLimits;
        return .{ .allocator = a, .packets = try a.alloc(Packet, capacity) };
    }
    fn deinit(self: *Queue) void {
        self.allocator.free(self.packets);
    }
    fn push(self: *Queue, source: logs.Source, bytes: []const u8) void {
        std.debug.assert(bytes.len > 0 and bytes.len <= packet_bytes);
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (self.count == self.packets.len) {
            self.head = (self.head + 1) % self.packets.len;
            self.count -= 1;
            self.pending_omissions +|= 1;
            self.status.dropped_packets +|= 1;
        }
        const packet = &self.packets[(self.head + self.count) % self.packets.len];
        packet.source = source;
        packet.len = bytes.len;
        @memcpy(packet.bytes[0..bytes.len], bytes);
        self.count += 1;
    }
    fn pop(self: *Queue) ?Delivery {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (self.count == 0) return null;
        const result: Delivery = .{ .packet = self.packets[self.head], .omitted = self.pending_omissions };
        self.pending_omissions = 0;
        self.head = (self.head + 1) % self.packets.len;
        self.count -= 1;
        return result;
    }
    fn failure(self: *Queue, disk: bool, err: anyerror) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (disk) {
            if (self.status.disk_failure == null) self.status.disk_failure = err;
        } else if (self.status.capture_failure == null) self.status.capture_failure = err;
    }
    fn snapshot(self: *Queue) Status {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        return self.status;
    }
};

const Reader = struct {
    source: logs.Source,
    queue: *Queue,
    redactor: logs.Redactor,
    io: std.Io = undefined,
    pipe: ?std.Io.File = null,
    disk: ?std.Io.File = null,
    future: ?std.Io.Future(void) = null,
    done: std.atomic.Value(bool) = .init(false),

    fn work(self: *Reader) void {
        const pipe = self.pipe.?;
        defer {
            pipe.close(self.io);
            self.pipe = null;
            self.done.store(true, .release);
        }
        var sink: Sink = .{ .reader = self };
        var bytes: [packet_bytes]u8 = undefined;
        var sanitize = true;
        while (true) {
            const n = pipe.readStreaming(self.io, &.{&bytes}) catch |err| {
                if (err != error.EndOfStream and err != error.Canceled) self.queue.failure(false, err);
                // EOF flushes to disk; cancellation flushes masked lookahead only to UI.
                sink.skip_disk = err != error.EndOfStream;
                break;
            };
            if (n == 0) continue;
            if (sanitize) {
                self.redactor.feed(self.source, bytes[0..n], &sink) catch |err| {
                    self.queue.failure(false, err);
                    sanitize = false;
                };
                sink.flush();
            }
        }
        if (sanitize) self.redactor.finish(self.source, &sink) catch |err| self.queue.failure(false, err);
        sink.flush();
    }
};

const Sink = struct {
    reader: *Reader,
    bytes: [packet_bytes]u8 = undefined,
    len: usize = 0,
    skip_disk: bool = false,

    pub fn writeAll(self: *Sink, bytes: []const u8) !void {
        var remaining = bytes;
        while (remaining.len > 0) {
            const n = @min(remaining.len, self.bytes.len - self.len);
            @memcpy(self.bytes[self.len..][0..n], remaining[0..n]);
            self.len += n;
            remaining = remaining[n..];
            if (self.len == self.bytes.len) self.flush();
        }
    }
    fn flush(self: *Sink) void {
        if (self.len == 0) return;
        const bytes = self.bytes[0..self.len];
        self.reader.queue.push(self.reader.source, bytes);
        if (!self.skip_disk) if (self.reader.disk) |file| {
            file.writeStreamingAll(self.reader.io, bytes) catch |err| {
                self.reader.queue.failure(true, err);
                self.skip_disk = true;
            };
        };
        self.len = 0;
    }
};

pub const Capture = struct {
    allocator: Allocator,
    queue: Queue,
    readers: [2]Reader,
    started: bool = false,

    pub fn init(a: Allocator, limits: Limits, secrets: []const []const u8) !*Capture {
        const self = try a.create(Capture);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .queue = try Queue.init(a, limits.max_packets), .readers = undefined };
        errdefer self.queue.deinit();
        var count: usize = 0;
        errdefer for (self.readers[0..count]) |*reader| reader.redactor.deinit();
        for (&self.readers, [_]logs.Source{ .stdout, .stderr }) |*reader, source| {
            reader.* = .{ .source = source, .queue = &self.queue, .redactor = try logs.Redactor.init(a, secrets, limits.max_secret_bytes) };
            count += 1;
        }
        return self;
    }

    /// Transfers both pipe handles. Disk files remain borrowed until join/cancel completes.
    /// If startup fails, all transferred pipe handles are closed and started readers joined.
    pub fn start(self: *Capture, io: std.Io, child: *std.process.Child, disk: [2]?std.Io.File) !void {
        if (self.started) return error.CaptureAlreadyStarted;
        if (child.stdout == null or child.stderr == null) return error.MissingCapturePipe;
        self.started = true;
        self.readers[0].pipe = child.stdout;
        self.readers[1].pipe = child.stderr;
        child.stdout = null;
        child.stderr = null;
        errdefer self.cancel(io);
        for (&self.readers, disk) |*reader, file| {
            reader.io = io;
            reader.disk = file;
            reader.future = try std.Io.concurrent(io, Reader.work, .{reader});
        }
    }

    pub fn status(self: *Capture) Status {
        return self.queue.snapshot();
    }
    pub fn noteDiskFailure(self: *Capture, err: anyerror) void {
        self.queue.failure(true, err);
    }

    /// Main-thread-only. At most one queue capacity per tick, even under continuous output.
    /// A loss boundary flushes both partials and adds an explicit omission row before resuming.
    pub fn drain(self: *Capture, buffer: *logs.Buffer) !void {
        for (0..self.queue.packets.len) |_| {
            const delivery = self.queue.pop() orelse break;
            if (delivery.omitted > 0) {
                try buffer.finish(.stdout);
                try buffer.finish(.stderr);
                var marker: [112]u8 = undefined;
                const text = try std.fmt.bufPrint(&marker, "[WARN] [... {d} log handoff packets omitted ...]\n", .{delivery.omitted});
                try buffer.feed(.stderr, text);
            }
            const packet = &delivery.packet;
            try buffer.feed(packet.source, packet.bytes[0..packet.len]);
        }
    }

    fn readersDone(self: *const Capture) bool {
        return self.readers[0].done.load(.acquire) and self.readers[1].done.load(.acquire);
    }

    /// Called after the child is reaped. EOF normally finishes immediately; inherited pipe
    /// writers get a bounded grace period so descendants cannot indefinitely retain a job.
    pub fn drainAndJoin(self: *Capture, io: std.Io) void {
        const deadline = std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(250));
        while (!self.readersDone()) {
            if (std.Io.Clock.awake.now(io).nanoseconds >= deadline.nanoseconds) break;
            std.Io.sleep(io, .fromMilliseconds(5), .awake) catch break;
        }
        self.cancel(io);
    }

    /// Join every reader; cancel only readers which have not reached EOF. Does not kill child.
    pub fn cancel(self: *Capture, io: std.Io) void {
        for (&self.readers) |*reader| {
            if (reader.future) |*future| {
                if (reader.done.load(.acquire)) future.await(io) else future.cancel(io);
                reader.future = null;
            } else if (reader.pipe) |pipe| {
                pipe.close(io);
                reader.pipe = null;
            }
        }
    }
    pub fn deinit(self: *Capture, io: std.Io) void {
        self.cancel(io);
        for (&self.readers) |*reader| reader.redactor.deinit();
        self.queue.deinit();
        self.allocator.destroy(self);
    }
};

fn allocationCase(a: Allocator) !void {
    const capture = try Capture.init(a, .{ .max_packets = 3 }, &.{"fake-access-token"});
    defer capture.deinit(std.testing.io);
}
test "capture allocation ownership and bounded ring handoff" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
    const capture = try Capture.init(std.testing.allocator, .{ .max_packets = 2 }, &.{});
    defer capture.deinit(std.testing.io);
    capture.queue.push(.stdout, "old\n");
    capture.queue.push(.stderr, "middle\n");
    capture.queue.push(.stdout, "new\n");
    var buffer = try logs.Buffer.init(std.testing.allocator, .{}, &.{});
    defer buffer.deinit();
    try capture.drain(&buffer);
    try std.testing.expectEqual(@as(u64, 1), capture.status().dropped_packets);
    try std.testing.expectEqual(@as(usize, 3), buffer.lineCount());
    try std.testing.expect(std.mem.indexOf(u8, buffer.lines()[0].text, "1 log handoff packets omitted") != null);
    try std.testing.expectEqualStrings("middle", buffer.lines()[1].text);
    try std.testing.expectEqualStrings("new", buffer.lines()[2].text);
    try std.testing.expectError(error.InvalidCaptureLimits, Capture.init(std.testing.allocator, .{ .max_packets = 0 }, &.{}));
}

test "sink masks chunk split secret before disk and isolates sources" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const disk = try tmp.dir.createFile(io, "sanitized.log", .{ .read = true });
    defer disk.close(io);
    const capture = try Capture.init(std.testing.allocator, .{}, &.{"fake-token-123"});
    defer capture.deinit(io);
    const reader = &capture.readers[0];
    reader.io = io;
    reader.disk = disk;
    var sink: Sink = .{ .reader = reader };
    try reader.redactor.feed(.stdout, "before fake-to", &sink);
    sink.flush();
    try reader.redactor.feed(.stdout, "ken-123 after\n", &sink);
    try reader.redactor.finish(.stdout, &sink);
    sink.flush();
    var bytes: [100]u8 = undefined;
    const n = try disk.readPositional(io, &.{&bytes}, 0);
    try std.testing.expectEqualStrings("before [REDACTED] after\n", bytes[0..n]);
    var buffer = try logs.Buffer.init(std.testing.allocator, .{}, &.{});
    defer buffer.deinit();
    try capture.drain(&buffer);
    try std.testing.expectEqualStrings("before [REDACTED] after", buffer.lines()[0].text);
}

test "disk errors disable writes without disabling producer drainage" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const created = try tmp.dir.createFile(io, "readonly.log", .{});
    created.close(io);
    const readonly = try tmp.dir.openFile(io, "readonly.log", .{});
    defer readonly.close(io);
    const capture = try Capture.init(std.testing.allocator, .{ .max_packets = 4 }, &.{});
    defer capture.deinit(io);
    const reader = &capture.readers[0];
    reader.io = io;
    reader.disk = readonly;
    var sink: Sink = .{ .reader = reader };
    for (0..10_000) |_| {
        try sink.writeAll("continued\n");
        sink.flush();
    }
    try std.testing.expect(capture.status().disk_failure != null);
    try std.testing.expectEqual(@as(u64, 9996), capture.status().dropped_packets);
    try std.testing.expect(sink.skip_disk);
}

test "concurrent stdout and stderr pipes are drained even without a consumer" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    const capture = try Capture.init(std.testing.allocator, .{ .max_packets = 4 }, &.{"fake-token-123"});
    defer capture.deinit(io);
    var child = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", "i=0; while [ $i -lt 10000 ]; do printf 'fake-token-123 stdout\\n'; printf 'stderr\\n' >&2; i=$((i+1)); done" }, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe });
    defer child.kill(io);
    try capture.start(io, &child, .{ null, null });
    const term = try child.wait(io);
    capture.drainAndJoin(io);
    try std.testing.expectEqual(@as(u8, 0), term.exited);
    try std.testing.expect(capture.status().dropped_packets > 0);
    try std.testing.expect(capture.status().capture_failure == null);
    var buffer = try logs.Buffer.init(std.testing.allocator, .{}, &.{});
    defer buffer.deinit();
    try capture.drain(&buffer);
    try buffer.finish(.stdout);
    try buffer.finish(.stderr);
    for (buffer.lines()) |line| try std.testing.expect(std.mem.indexOf(u8, line.text, "fake-token-123") == null);
}

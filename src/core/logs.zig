//! Bounded single-owner log storage, independent of I/O and application modules.
//! Feed in arrival order; complete lines (or finish) publish in completion order.
//! All borrowed views expire on mutation. Register exact credentials before feed.
//! Never write raw pipe chunks to disk: use Redactor with a source-specific writer.
//! On ingestion/writer failure stop and discard the instance; do not replay chunks.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Source = enum { stdout, stderr };
pub const Severity = enum { trace, debug, info, warn, @"error", fatal };
pub const Direction = enum { forward, backward };
pub const Cursor = struct { id: u64, byte_offset: usize = 0 };
pub const Line = struct {
    id: u64,
    generation: u64,
    source: Source,
    severity: Severity,
    text: []const u8,
    truncated: bool,
    /// Invalid/incomplete UTF-8 or an ASCII terminal control was replaced.
    invalid_utf8: bool,
};
pub const Limits = struct {
    max_bytes: usize = 8 * 1024 * 1024,
    max_lines: usize = 10_000,
    /// Includes truncation_marker; must fit it and not exceed max_bytes.
    max_line_bytes: usize = 64 * 1024,
    /// Bounds owned secrets and each stream's redaction lookahead.
    max_secret_bytes: usize = 64 * 1024,
};
pub const truncation_marker = "[... truncated]";
pub const redaction_marker = "[REDACTED]";

/// Exact byte-string streaming redaction, including secrets containing newlines.
/// writer needs writeAll([]const u8) !void; std.Io.Writer is supported directly.
/// Potential secret prefixes remain private until resolved; finish conservatively
/// masks incomplete prefixes at EOF. Leftmost-longest, non-overlapping matching.
/// Replacement text is synthetic, not a claim it excludes every possible supplied
/// string (e.g. a secret equal to "REDACTED"). Empty secrets reject. Unregistered
/// or encoded secrets are not detected. Fields are internal, never consumer text.
pub const Redactor = struct {
    allocator: Allocator,
    secrets: [][]u8,
    pending: [2]std.ArrayList(u8),

    pub fn init(allocator: Allocator, secrets: []const []const u8, max_secret_bytes: usize) !Redactor {
        var total: usize = 0;
        var longest: usize = 0;
        for (secrets) |secret| {
            if (secret.len == 0) return error.EmptySecret;
            total = std.math.add(usize, total, secret.len) catch return error.SecretLimitExceeded;
            if (total > max_secret_bytes) return error.SecretLimitExceeded;
            longest = @max(longest, secret.len);
        }
        const owned = try allocator.alloc([]u8, secrets.len);
        errdefer allocator.free(owned);
        var count: usize = 0;
        errdefer for (owned[0..count]) |secret| allocator.free(secret);
        for (secrets, 0..) |secret, i| {
            owned[i] = try allocator.dupe(u8, secret);
            count += 1;
        }
        var first = try std.ArrayList(u8).initCapacity(allocator, longest);
        errdefer first.deinit(allocator);
        const second = try std.ArrayList(u8).initCapacity(allocator, longest);
        return .{ .allocator = allocator, .secrets = owned, .pending = .{ first, second } };
    }

    pub fn deinit(self: *Redactor) void {
        for (self.secrets) |secret| {
            @memset(secret, 0);
            self.allocator.free(secret);
        }
        self.allocator.free(self.secrets);
        for (&self.pending) |*pending| {
            @memset(pending.allocatedSlice(), 0);
            pending.deinit(self.allocator);
        }
        self.* = undefined;
    }

    pub fn clear(self: *Redactor) void {
        for (&self.pending) |*pending| {
            @memset(pending.allocatedSlice(), 0);
            pending.clearRetainingCapacity();
        }
    }

    pub fn feed(self: *Redactor, source: Source, bytes: []const u8, writer: anytype) !void {
        if (self.secrets.len == 0) return writer.writeAll(bytes);
        const pending = &self.pending[@intFromEnum(source)];
        for (bytes) |byte| {
            pending.appendAssumeCapacity(byte);
            try self.drain(pending, false, writer);
        }
    }

    pub fn finish(self: *Redactor, source: Source, writer: anytype) !void {
        try self.drain(&self.pending[@intFromEnum(source)], true, writer);
    }

    fn drain(self: *Redactor, pending: *std.ArrayList(u8), eof: bool, writer: anytype) !void {
        while (pending.items.len != 0) {
            var full: usize = 0;
            var prefix = false;
            for (self.secrets) |secret| {
                if (pending.items.len >= secret.len) {
                    if (std.mem.startsWith(u8, pending.items, secret)) full = @max(full, secret.len);
                } else if (std.mem.startsWith(u8, secret, pending.items)) prefix = true;
            }
            if (prefix and !eof) return;
            const consumed = if (prefix) pending.items.len else if (full != 0) full else 1;
            if (full != 0 or prefix) {
                try writer.writeAll(redaction_marker);
            } else {
                try writer.writeAll(pending.items[0..1]);
            }
            const remaining = pending.items.len - consumed;
            std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[consumed..]);
            @memset(pending.items[remaining..], 0);
            pending.items.len = remaining;
        }
    }
};

const Partial = struct {
    text: std.ArrayList(u8),
    utf8: [4]u8 = @splat(0),
    utf8_len: usize = 0,
    utf8_expected: usize = 0,
    skip_lf: bool = false,
    truncated: bool = false,
    invalid_utf8: bool = false,

    fn clear(self: *Partial) void {
        self.text.clearRetainingCapacity();
        self.utf8 = @splat(0);
        self.utf8_len = 0;
        self.utf8_expected = 0;
        self.truncated = false;
        self.invalid_utf8 = false;
    }
};

pub const Buffer = struct {
    allocator: Allocator,
    limits: Limits,
    redactor: Redactor,
    partial: [2]Partial,
    storage: []Line,
    head: usize = 0,
    len: usize = 0,
    retained_bytes: usize = 0,
    next_id: u64 = 0,
    /// Pair cursors with generation; clear/reset invalidate pre-clear cursors.
    generation: u64 = 0,
    counts: [6]usize = @splat(0),
    errors: []u64,
    error_head: usize = 0,
    error_len: usize = 0,

    pub fn init(allocator: Allocator, limits: Limits, secrets: []const []const u8) !Buffer {
        if (limits.max_lines == 0 or limits.max_line_bytes < truncation_marker.len or
            limits.max_line_bytes > limits.max_bytes) return error.InvalidLimits;
        const slots = std.math.mul(usize, limits.max_lines, 2) catch return error.InvalidLimits;
        _ = std.math.add(usize, limits.max_bytes, limits.max_line_bytes) catch return error.InvalidLimits;
        var redactor = try Redactor.init(allocator, secrets, limits.max_secret_bytes);
        errdefer redactor.deinit();
        const storage = try allocator.alloc(Line, slots);
        errdefer allocator.free(storage);
        const errors = try allocator.alloc(u64, slots);
        errdefer allocator.free(errors);
        var first = try std.ArrayList(u8).initCapacity(allocator, limits.max_line_bytes);
        errdefer first.deinit(allocator);
        const second = try std.ArrayList(u8).initCapacity(allocator, limits.max_line_bytes);
        return .{ .allocator = allocator, .limits = limits, .redactor = redactor, .storage = storage, .errors = errors, .partial = .{ .{ .text = first }, .{ .text = second } } };
    }

    pub fn deinit(self: *Buffer) void {
        self.clear();
        self.redactor.deinit();
        for (&self.partial) |*partial| partial.text.deinit(self.allocator);
        self.allocator.free(self.storage);
        self.allocator.free(self.errors);
        self.* = undefined;
    }

    /// Discards partials and retained lines; IDs never restart, generation advances.
    pub fn clear(self: *Buffer) void {
        for (self.lines()) |line| self.allocator.free(line.text);
        self.head = 0;
        self.len = 0;
        self.retained_bytes = 0;
        self.counts = @splat(0);
        self.error_head = 0;
        self.error_len = 0;
        self.generation +%= 1;
        self.redactor.clear();
        for (&self.partial) |*partial| {
            partial.clear();
            partial.skip_lf = false;
        }
    }

    pub fn reset(self: *Buffer) void {
        self.clear();
    }
    pub fn lines(self: *const Buffer) []const Line {
        return self.storage[self.head..][0..self.len];
    }
    pub fn lineCount(self: *const Buffer) usize {
        return self.len;
    }
    /// Published UTF-8 bytes, including markers, excluding metadata and partials.
    pub fn byteCount(self: *const Buffer) usize {
        return self.retained_bytes;
    }
    pub fn firstId(self: *const Buffer) ?u64 {
        return if (self.len == 0) null else self.storage[self.head].id;
    }
    pub fn severityCount(self: *const Buffer, severity: Severity) usize {
        return self.counts[@intFromEnum(severity)];
    }
    /// Error/fatal IDs in arrival order; position(id) is the current virtual row.
    pub fn errorIds(self: *const Buffer) []const u64 {
        return self.errors[self.error_head..][0..self.error_len];
    }

    pub fn position(self: *const Buffer, id: u64) ?usize {
        const first = self.firstId() orelse return null;
        if (id < first) return null;
        const offset = id - first;
        if (offset >= self.len) return null;
        return @intCast(offset);
    }

    pub fn get(self: *const Buffer, id: u64) ?*const Line {
        const row = self.position(id) orelse return null;
        return &self.storage[self.head + row];
    }

    pub fn feed(self: *Buffer, source: Source, bytes: []const u8) !void {
        try self.redactor.feed(source, bytes, Sink{ .buffer = self, .source = source });
    }

    /// EOF flush; repeated finish is harmless. Feeding again afterwards is legal.
    pub fn finish(self: *Buffer, source: Source) !void {
        try self.redactor.finish(source, Sink{ .buffer = self, .source = source });
        const partial = &self.partial[@intFromEnum(source)];
        self.flushInvalid(partial);
        if (partial.text.items.len != 0 or partial.truncated) try self.publish(source);
        partial.skip_lf = false;
    }

    const Sink = struct {
        buffer: *Buffer,
        source: Source,
        pub fn writeAll(self: Sink, bytes: []const u8) !void {
            for (bytes) |byte| try self.buffer.accept(self.source, byte);
        }
    };

    fn accept(self: *Buffer, source: Source, byte: u8) !void {
        const partial = &self.partial[@intFromEnum(source)];
        if (partial.skip_lf) {
            partial.skip_lf = false;
            if (byte == '\n') return;
        }
        if (byte == '\r' or byte == '\n') {
            self.flushInvalid(partial);
            try self.publish(source);
            partial.skip_lf = byte == '\r';
            return;
        }
        if (partial.utf8_len != 0) {
            if (byte >= 0x80 and byte <= 0xbf) {
                partial.utf8[partial.utf8_len] = byte;
                partial.utf8_len += 1;
                if (partial.utf8_len == partial.utf8_expected) {
                    const sequence = partial.utf8[0..partial.utf8_len];
                    if (std.unicode.utf8Decode(sequence)) |_| {
                        self.appendText(partial, sequence);
                        partial.utf8_len = 0;
                    } else |_| self.flushInvalid(partial);
                }
                return;
            }
            self.flushInvalid(partial);
        }
        if (byte < 0x80) {
            // Preserve tabs but replace NUL/terminal controls before consumers.
            if ((byte < 0x20 and byte != '\t') or byte == 0x7f) {
                partial.invalid_utf8 = true;
                self.appendText(partial, "\xef\xbf\xbd");
            } else self.appendText(partial, &.{byte});
        } else {
            const expected = std.unicode.utf8ByteSequenceLength(byte) catch {
                partial.invalid_utf8 = true;
                self.appendText(partial, "\xef\xbf\xbd");
                return;
            };
            partial.utf8[0] = byte;
            partial.utf8_len = 1;
            partial.utf8_expected = expected;
        }
    }

    fn flushInvalid(self: *Buffer, partial: *Partial) void {
        if (partial.utf8_len == 0) return;
        partial.invalid_utf8 = true;
        self.appendText(partial, "\xef\xbf\xbd");
        partial.utf8_len = 0;
    }

    fn appendText(self: *Buffer, partial: *Partial, text: []const u8) void {
        if (partial.truncated) return;
        if (text.len <= self.limits.max_line_bytes - partial.text.items.len) {
            partial.text.appendSliceAssumeCapacity(text);
            return;
        }
        partial.truncated = true;
        var end = @min(partial.text.items.len, self.limits.max_line_bytes - truncation_marker.len);
        // Retreat to a codepoint boundary before appending the explicit marker.
        while (end > 0 and end < partial.text.items.len and (partial.text.items[end] & 0xc0) == 0x80) end -= 1;
        partial.text.items.len = end;
        partial.text.appendSliceAssumeCapacity(truncation_marker);
    }

    fn publish(self: *Buffer, source: Source) !void {
        if (self.next_id == std.math.maxInt(u64)) return error.IdExhausted;
        const partial = &self.partial[@intFromEnum(source)];
        const text = try self.allocator.dupe(u8, partial.text.items);
        const severity = classify(text, source);
        if (self.head + self.len == self.storage.len) {
            std.mem.copyForwards(Line, self.storage[0..self.len], self.lines());
            self.head = 0;
        }
        if (self.error_head + self.error_len == self.errors.len) {
            std.mem.copyForwards(u64, self.errors[0..self.error_len], self.errorIds());
            self.error_head = 0;
        }
        self.storage[self.head + self.len] = .{ .id = self.next_id, .generation = self.generation, .source = source, .severity = severity, .text = text, .truncated = partial.truncated, .invalid_utf8 = partial.invalid_utf8 };
        self.len += 1;
        self.retained_bytes += text.len;
        self.counts[@intFromEnum(severity)] += 1;
        if (severity == .@"error" or severity == .fatal) {
            self.errors[self.error_head + self.error_len] = self.next_id;
            self.error_len += 1;
        }
        self.next_id += 1;
        partial.clear();
        self.prune();
    }

    /// Automatic after publish; explicitly calling it also invalidates views.
    pub fn prune(self: *Buffer) void {
        while (self.len > self.limits.max_lines or self.retained_bytes > self.limits.max_bytes) {
            const line = self.storage[self.head];
            self.retained_bytes -= line.text.len;
            self.counts[@intFromEnum(line.severity)] -= 1;
            if (line.severity == .@"error" or line.severity == .fatal) {
                self.error_head += 1;
                self.error_len -= 1;
            }
            self.allocator.free(line.text);
            self.head += 1;
            self.len -= 1;
        }
    }

    /// Inclusive start, no wrap. null starts at the direction's retained edge.
    /// Stale IDs clamp to the edge only when searching toward retained rows;
    /// searching away returns null. Offsets are UTF-8 BYTE offsets, not columns.
    /// ASCII letters fold; non-ASCII bytes match exactly (no Unicode case folding,
    /// normalization, or locale). Empty queries return null. Only stored text searched.
    pub fn find(self: *const Buffer, query: []const u8, start: ?Cursor, direction: Direction) ?Cursor {
        if (query.len == 0 or self.len == 0) return null;
        const retained = self.lines();
        const first = retained[0].id;
        const last = retained[retained.len - 1].id;
        var row: usize = if (direction == .forward) 0 else retained.len - 1;
        var offset: usize = if (direction == .forward) 0 else std.math.maxInt(usize);
        if (start) |cursor| {
            if (cursor.id < first) {
                if (direction == .backward) return null;
            } else if (cursor.id > last) {
                if (direction == .forward) return null;
            } else {
                row = @intCast(cursor.id - first);
                offset = cursor.byte_offset;
            }
        }
        while (true) {
            const line = retained[row];
            if (query.len <= line.text.len) {
                const max_start = line.text.len - query.len;
                if (direction == .forward) {
                    var i = offset;
                    while (i <= max_start) : (i += 1) {
                        if (asciiEqual(line.text[i..][0..query.len], query)) return .{ .id = line.id, .byte_offset = i };
                    }
                } else {
                    var i = @min(offset, max_start);
                    while (true) {
                        if (asciiEqual(line.text[i..][0..query.len], query)) return .{ .id = line.id, .byte_offset = i };
                        if (i == 0) break;
                        i -= 1;
                    }
                }
            }
            if (direction == .forward) {
                row += 1;
                if (row == retained.len) return null;
                offset = 0;
            } else {
                if (row == 0) return null;
                row -= 1;
                offset = std.math.maxInt(usize);
            }
        }
    }
};

fn asciiEqual(a: []const u8, b: []const u8) bool {
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

/// Explicit Minecraft levels take precedence, then Java exceptions/stack frames.
/// Unclassified stderr defaults to error, stdout info; ordinary "errors" prose
/// on stdout does not classify as an exception.
pub fn classify(text: []const u8, source: Source) Severity {
    inline for (.{ .{ "FATAL", Severity.fatal }, .{ "ERROR", Severity.@"error" }, .{ "WARN", Severity.warn }, .{ "WARNING", Severity.warn }, .{ "INFO", Severity.info }, .{ "DEBUG", Severity.debug }, .{ "TRACE", Severity.trace } }) |entry| {
        if (std.mem.indexOf(u8, text, "/" ++ entry[0] ++ "]") != null or
            std.mem.indexOf(u8, text, "[" ++ entry[0] ++ "]") != null) return entry[1];
    }
    const trimmed = std.mem.trimStart(u8, text, " \t");
    for ([_][]const u8{ "Caused by:", "Suppressed:", "Exception in thread " }) |prefix| {
        if (std.mem.startsWith(u8, trimmed, prefix)) return .@"error";
    }
    if (std.mem.startsWith(u8, trimmed, "at ") and std.mem.endsWith(u8, trimmed, ")")) {
        if (std.mem.indexOfScalar(u8, trimmed, '(')) |paren| {
            if (std.mem.indexOfScalar(u8, trimmed[3..paren], '.') != null) return .@"error";
        }
    }
    if (std.mem.startsWith(u8, trimmed, "... ") and std.mem.endsWith(u8, trimmed, " more") and trimmed.len > 9) {
        const digits = trimmed[4 .. trimmed.len - 5];
        var numeric = true;
        for (digits) |byte| numeric = numeric and std.ascii.isDigit(byte);
        if (numeric) return .@"error";
    }
    const end = std.mem.indexOfAny(u8, trimmed, ": \t") orelse trimmed.len;
    const name = trimmed[0..end];
    if (std.mem.indexOfScalar(u8, name, '.') != null and
        (std.mem.endsWith(u8, name, "Exception") or std.mem.endsWith(u8, name, "Error"))) return .@"error";
    return if (source == .stderr) .@"error" else .info;
}

const testing = std.testing;
const test_limits: Limits = .{ .max_lines = 4, .max_bytes = 128, .max_line_bytes = 32 };

test "owned lines, source separation, CRLF, UTF8 splits, and EOF" {
    var buffer = try Buffer.init(testing.allocator, test_limits, &.{});
    defer buffer.deinit();
    var input = [_]u8{ 'a', 0xe2 };
    try buffer.feed(.stdout, &input);
    input[0] = 'z';
    try buffer.feed(.stderr, "err\r");
    try buffer.feed(.stdout, "\x82\xac\r");
    try buffer.feed(.stderr, "\nnext");
    try buffer.feed(.stdout, "\nlast");
    try buffer.finish(.stdout);
    try buffer.finish(.stderr);
    try buffer.finish(.stderr);
    try testing.expectEqual(@as(usize, 4), buffer.lineCount());
    try testing.expectEqualStrings("err", buffer.lines()[0].text);
    try testing.expectEqualStrings("a\xe2\x82\xac", buffer.lines()[1].text);
    try testing.expectEqualStrings("last", buffer.lines()[2].text);
    try testing.expectEqualStrings("next", buffer.lines()[3].text);
    try testing.expectEqual(Source.stderr, buffer.lines()[0].source);
    try testing.expectEqual(@as(usize, 2), buffer.errorIds().len);
}

test "invalid and incomplete UTF8 repaired to valid bounded text" {
    var buffer = try Buffer.init(testing.allocator, test_limits, &.{});
    defer buffer.deinit();
    try buffer.feed(.stdout, "\xff\xc0\xaf\xe2x\xed\xa0\x80\x00\n\xf0\x9f");
    try buffer.finish(.stdout);
    for (buffer.lines()) |line| {
        try testing.expect(line.invalid_utf8);
        try testing.expect(std.unicode.utf8ValidateSlice(line.text));
    }
    try testing.expectEqualStrings("\xef\xbf\xbd", buffer.lines()[1].text);
}

test "large lines truncate with marker without splitting a codepoint" {
    var buffer = try Buffer.init(testing.allocator, .{ .max_lines = 3, .max_bytes = 64, .max_line_bytes = 18 }, &.{});
    defer buffer.deinit();
    try buffer.feed(.stdout, "a\xe2\x82\xac012345678901234567890123456789\n");
    const line = buffer.lines()[0];
    try testing.expect(line.truncated);
    try testing.expect(line.text.len <= 18);
    try testing.expect(std.unicode.utf8ValidateSlice(line.text));
    try testing.expect(std.mem.endsWith(u8, line.text, truncation_marker));
    try buffer.feed(.stdout, "123456789012345678\n");
    try testing.expect(!buffer.lines()[1].truncated);
}

test "retention bytes, stable IDs, marker rows, and generation" {
    var buffer = try Buffer.init(testing.allocator, .{ .max_lines = 3, .max_bytes = 32, .max_line_bytes = 20 }, &.{});
    defer buffer.deinit();
    try buffer.feed(.stdout, "[ERROR] alpha\nbeta123456789\ngamma123456789\n");
    try testing.expectEqual(@as(?u64, 1), buffer.firstId());
    try testing.expectEqual(@as(usize, 27), buffer.byteCount());
    try testing.expectEqual(@as(usize, 0), buffer.errorIds().len);
    try testing.expect(buffer.get(0) == null);
    try buffer.feed(.stderr, "fail\n");
    try testing.expectEqual(@as(?usize, 2), buffer.position(buffer.errorIds()[0]));
    try testing.expectEqual(@as(usize, 1), buffer.severityCount(.@"error"));
    const generation = buffer.generation;
    buffer.clear();
    try testing.expectEqual(generation + 1, buffer.generation);
    try testing.expectEqual(@as(usize, 0), buffer.byteCount());
    try testing.expect(buffer.firstId() == null);
    try buffer.feed(.stdout, "new\n");
    try testing.expectEqual(@as(u64, 4), buffer.lines()[0].id);
    try testing.expectEqual(generation + 1, buffer.lines()[0].generation);
}

test "levels, Java stack lines, error positions, and ASCII-only search" {
    var buffer = try Buffer.init(testing.allocator, .{ .max_lines = 12, .max_bytes = 1024, .max_line_bytes = 128 }, &.{});
    defer buffer.deinit();
    try buffer.feed(.stdout, "[12:00] [Render thread/WARN]: Hello\n[ERROR] Failed\njava.lang.RuntimeException: Failed\n\tat demo.Main.run(Main.java:1)\nCaused by: java.io.IOException\n[DEBUG] hello HELLO\n\xc3\x84\n");
    try testing.expectEqual(Severity.warn, buffer.lines()[0].severity);
    try testing.expectEqual(@as(usize, 4), buffer.errorIds().len);
    try testing.expectEqual(@as(?usize, 1), buffer.position(buffer.errorIds()[0]));
    const first = buffer.find("HELLO", null, .forward).?;
    try testing.expectEqual(@as(u64, 0), first.id);
    const last = buffer.find("hello", null, .backward).?;
    try testing.expectEqual(@as(u64, 5), last.id);
    try testing.expectEqual(@as(usize, 14), last.byte_offset);
    try testing.expect(buffer.find("", null, .forward) == null);
    try testing.expect(buffer.find("missing", null, .forward) == null);
    try testing.expect(buffer.find("hello", .{ .id = 999 }, .forward) == null);
    try testing.expect(buffer.find("hello", .{ .id = 999 }, .backward) != null);
    try testing.expect(buffer.find("hello", .{ .id = 0, .byte_offset = 999 }, .forward).?.id == 5);
    try testing.expect(buffer.find("\xc3\xa4", null, .forward) == null);
    try testing.expect(buffer.find("\xc3\x84", null, .forward) != null);
    try testing.expectEqual(Severity.fatal, classify("[FATAL] shutdown", .stdout));
    try testing.expectEqual(Severity.info, classify("[INFO] note", .stderr));
    try testing.expectEqual(Severity.info, classify("no errors", .stdout));
}

test "secret redaction across every chunk split precedes truncation" {
    const fake = "fake-token-12345";
    for (0..fake.len + 1) |split| {
        var buffer = try Buffer.init(testing.allocator, test_limits, &.{fake});
        defer buffer.deinit();
        try buffer.feed(.stdout, "--accessToken ");
        try buffer.feed(.stdout, fake[0..split]);
        try testing.expectEqual(@as(usize, 0), buffer.lineCount());
        try buffer.feed(.stdout, fake[split..]);
        try buffer.feed(.stdout, " tail\n");
        const line = buffer.lines()[0];
        try testing.expect(std.mem.indexOf(u8, line.text, fake) == null);
        try testing.expectEqualStrings("--accessToken [REDACTED] tail", line.text);
    }
    var buffer = try Buffer.init(testing.allocator, .{ .max_lines = 2, .max_bytes = 40, .max_line_bytes = 20 }, &.{fake});
    defer buffer.deinit();
    try buffer.feed(.stdout, "123456789012345678" ++ fake ++ "\n");
    try testing.expect(buffer.lines()[0].truncated);
    try testing.expect(std.mem.indexOf(u8, buffer.lines()[0].text, "fake") == null);
    try buffer.feed(.stdout, fake[0..8]);
    try buffer.finish(.stdout);
    try testing.expectEqualStrings(redaction_marker, buffer.lines()[1].text);
}

const TestWriter = struct {
    allocator: Allocator,
    bytes: std.ArrayList(u8) = .empty,
    pub fn writeAll(self: *TestWriter, bytes: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, bytes);
    }
};

test "disk redactor owns secrets, leftmost-longest, and separate streams" {
    var fake = [_]u8{ 't', 'o', 'k', 'e', 'n' };
    var redactor = try Redactor.init(testing.allocator, &.{ &fake, "token-long", "line\nbreak" }, 64);
    defer redactor.deinit();
    @memset(&fake, 'z');
    var out = TestWriter{ .allocator = testing.allocator };
    defer out.bytes.deinit(testing.allocator);
    var err = TestWriter{ .allocator = testing.allocator };
    defer err.bytes.deinit(testing.allocator);
    try redactor.feed(.stdout, "to", &out);
    try testing.expectEqual(@as(usize, 0), out.bytes.items.len);
    try redactor.feed(.stderr, "ken!", &err);
    try redactor.feed(.stdout, "ken-long line\n", &out);
    try redactor.feed(.stdout, "break tok", &out);
    try redactor.finish(.stdout, &out);
    try redactor.finish(.stderr, &err);
    try testing.expectEqualStrings("[REDACTED] [REDACTED] [REDACTED]", out.bytes.items);
    try testing.expectEqualStrings("ken!", err.bytes.items);
    redactor.clear();
    try redactor.feed(.stdout, "t", &out);
    redactor.clear();
    try redactor.feed(.stdout, "safe", &err);
    try redactor.finish(.stdout, &err);
    try testing.expectEqualStrings("ken!safe", err.bytes.items);
}

test "10000 lines retain bounded arrays without quadratic front removal" {
    var buffer = try Buffer.init(testing.allocator, .{ .max_lines = 100, .max_bytes = 4096, .max_line_bytes = 32 }, &.{});
    defer buffer.deinit();
    for (0..10_000) |i| try buffer.feed(if (i % 2 == 0) .stdout else .stderr, "entry\n");
    try testing.expectEqual(@as(usize, 100), buffer.lineCount());
    try testing.expectEqual(@as(usize, 500), buffer.byteCount());
    try testing.expectEqual(@as(?u64, 9900), buffer.firstId());
    try testing.expectEqual(@as(usize, 50), buffer.errorIds().len);
    try testing.expectEqual(@as(usize, 200), buffer.storage.len);
    try testing.expectEqual(@as(?usize, 99), buffer.position(9999));
    try testing.expect(buffer.get(9899) == null);
    try testing.expect(buffer.find("entry", .{ .id = 0 }, .forward).?.id == 9900);
    try testing.expect(buffer.find("entry", .{ .id = 0 }, .backward) == null);
}

test "limits and empty secret validation" {
    try testing.expectError(error.InvalidLimits, Buffer.init(testing.allocator, .{ .max_lines = 0 }, &.{}));
    try testing.expectError(error.InvalidLimits, Buffer.init(testing.allocator, .{ .max_line_bytes = 2 }, &.{}));
    try testing.expectError(error.InvalidLimits, Buffer.init(testing.allocator, .{ .max_bytes = 32 }, &.{}));
    try testing.expectError(error.EmptySecret, Buffer.init(testing.allocator, test_limits, &.{""}));
    try testing.expectError(error.SecretLimitExceeded, Redactor.init(testing.allocator, &.{"fake-secret"}, 2));
}

fn allocationScenario(allocator: Allocator) !void {
    var buffer = try Buffer.init(allocator, test_limits, &.{"fake-token"});
    defer buffer.deinit();
    try buffer.feed(.stdout, "fake-to");
    try buffer.feed(.stdout, "ken\nfirst\nsecond\nthird\nfourth\nfifth\n");
    try buffer.feed(.stderr, "partial");
    try buffer.finish(.stderr);
    buffer.reset();
    try buffer.feed(.stdout, "again\n");
}

test "every allocation failure is leak free" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationScenario, .{});
}

test "std Io writer redacts longest match once and masks incomplete longer match" {
    var redactor = try Redactor.init(testing.allocator, &.{ "fake", "fake-long", "REDACTED", "aba", "bab" }, 64);
    defer redactor.deinit();
    var bytes: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try redactor.feed(.stdout, "fake-long fake! abab fake-lo", &writer);
    try redactor.finish(.stdout, &writer);
    try testing.expectEqualStrings("[REDACTED] [REDACTED]! [REDACTED]b [REDACTED]", writer.buffered());
}

test "huge partial chunks stay bounded, clear discards lookahead, empty rows" {
    var buffer = try Buffer.init(testing.allocator, .{ .max_lines = 2, .max_bytes = 64, .max_line_bytes = 32 }, &.{"fake-token"});
    defer buffer.deinit();
    const huge = [_]u8{'x'} ** 100_000;
    try buffer.feed(.stdout, &huge);
    try testing.expectEqual(@as(usize, 0), buffer.lineCount());
    try testing.expect(buffer.partial[0].text.items.len <= 32);
    try buffer.feed(.stdout, "fake-token\n\n\n");
    try testing.expectEqual(@as(usize, 2), buffer.lineCount());
    try testing.expectEqual(@as(usize, 0), buffer.byteCount());
    try testing.expectEqualStrings("", buffer.lines()[0].text);
    try testing.expect(buffer.get(0) == null);
    try buffer.feed(.stdout, "fake-to");
    buffer.clear();
    try buffer.feed(.stdout, "visible\x1b[31m\n");
    try testing.expectEqualStrings("visible\xef\xbf\xbd[31m", buffer.lines()[0].text);
    try testing.expect(buffer.find("fake", null, .forward) == null);
}

test "severity coverage and retained-only search after clear and pruning" {
    try testing.expectEqual(Severity.trace, classify("[TRACE] detail", .stdout));
    try testing.expectEqual(Severity.debug, classify("[main/DEBUG] detail", .stdout));
    try testing.expectEqual(Severity.warn, classify("[WARNING] detail", .stdout));
    try testing.expectEqual(Severity.@"error", classify("Exception in thread main", .stdout));
    try testing.expectEqual(Severity.@"error", classify("Suppressed: java.io.IOException", .stdout));
    try testing.expectEqual(Severity.@"error", classify("... 42 more", .stdout));
    try testing.expectEqual(Severity.info, classify("at least no errors", .stdout));
    try testing.expectEqual(Severity.info, classify("... ordinary prose", .stdout));
    var buffer = try Buffer.init(testing.allocator, .{ .max_lines = 1, .max_bytes = 32, .max_line_bytes = 32 }, &.{});
    defer buffer.deinit();
    try buffer.feed(.stdout, "old\nnew\n");
    try testing.expect(buffer.find("old", null, .forward) == null);
    const old_cursor = Cursor{ .id = 1 };
    buffer.reset();
    try testing.expect(buffer.find("new", old_cursor, .forward) == null);
    try buffer.feed(.stdout, "new\n");
    try testing.expect(buffer.get(old_cursor.id) == null);
    try testing.expectEqual(@as(u64, 2), buffer.find("new", old_cursor, .forward).?.id);
    try testing.expect(buffer.find("new", old_cursor, .backward) == null);
}

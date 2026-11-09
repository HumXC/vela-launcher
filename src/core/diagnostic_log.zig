//! Persistent launcher diagnostics, separate from game stdout capture.
//! start/stop must be serialized with workers joined before stop. The Io must
//! outlive the logger. Logging is thread-safe; inactive/failed sinks drop calls.
//! Single process ownership of the log directory is required (no process lock).
const std = @import("std");
const builtin = @import("builtin");
const fs = @import("content_fs.zig");
const Io = std.Io;

pub const max_line_bytes = 4096;
pub const max_message_bytes = 8192;
pub const truncation_marker = " [... truncated]";
const names = [_][]const u8{ "launcher.log", "launcher.log.1", "launcher.log.2", "launcher.log.3" };

pub const Options = struct { max_file_bytes: usize = 4 * 1024 * 1024 };
var global: Logger = .{};

/// directory is the launcher root, NOT the logs directory. Creates .vela/logs.
/// Initialization errors are returned for the caller to catch and ignore;
/// never propagate these into installation/launcher failure.
pub fn start(io: Io, directory: []const u8) !void {
    const root = if (std.fs.path.isAbsolute(directory))
        try fs.openAbsolute(io, directory)
    else if (std.mem.eql(u8, directory, "."))
        try Io.Dir.cwd().openDir(io, ".", .{ .iterate = true, .follow_symlinks = false })
    else
        try fs.descend(Io.Dir.cwd(), io, directory, false);
    defer root.close(io);
    try global.startAt(io, root, .{});
}

pub fn stop() void {
    global.stop();
}
pub fn write(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
    global.write(level, scope, fmt, args);
}

pub const Logger = struct {
    io: ?Io = null,
    dir: ?Io.Dir = null,
    file: ?Io.File = null,
    mutex: Io.Mutex = .init,
    size: usize = 0,
    limit: usize = 4 * 1024 * 1024,
    failed: bool = false,

    /// Root is borrowed; logger owns separate .vela/logs handles. Small limits
    /// (>=128 bytes) permit deterministic rotation tests without huge fixtures.
    pub fn startAt(self: *Logger, io: Io, root: Io.Dir, options: Options) !void {
        if (self.io != null) return error.AlreadyStarted;
        if (options.max_file_bytes < 128) return error.InvalidLogLimit;
        const metadata = try privateChild(root, io, ".vela");
        defer metadata.close(io);
        const dir = try privateChild(metadata, io, "logs");
        errdefer dir.close(io);
        self.limit = options.max_file_bytes;
        self.failed = false;
        // Preflight every owned name before changing any of them.
        try checkFiles(dir, io);
        try rotateFiles(dir, io);
        const file = try freshFile(dir, io);
        self.io = io;
        self.dir = dir;
        self.file = file;
        self.size = 0;
    }

    pub fn stop(self: *Logger) void {
        const io = self.io orelse return;
        if (self.file) |file| {
            file.sync(io) catch {
                self.failed = true;
            };
            file.close(io);
        }
        if (self.dir) |dir| dir.close(io);
        self.file = null;
        self.dir = null;
        self.io = null;
        self.size = 0;
    }

    pub fn write(self: *Logger, comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
        const io = self.io orelse return;
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.file == null or self.failed) return;
        var raw: [max_message_bytes]u8 = undefined;
        // Never sanitize a partial raw message: an incomplete URL/userinfo or
        // credential key near its end may otherwise expose earlier bytes.
        const message = std.fmt.bufPrint(&raw, fmt, args) catch "[message omitted: formatting overflow; truncated]";
        var line: [max_line_bytes]u8 = undefined;
        const capacity = @min(line.len, self.limit);
        var out: Bounded = .{ .bytes = line[0 .. capacity - truncation_marker.len - 1] };
        var prefix: [160]u8 = undefined;
        const header = std.fmt.bufPrint(&prefix, "epoch_ms={d} {s} ", .{ Io.Clock.real.now(io).toMilliseconds(), @tagName(level) }) catch "epoch_ms=? ";
        out.add(header);
        escape(&out, @tagName(scope));
        out.add(": ");
        sanitizeInto(&out, message);
        if (out.truncated) {
            @memcpy(line[out.len..][0..truncation_marker.len], truncation_marker);
            out.len += truncation_marker.len;
        }
        line[out.len] = 0x0a;
        out.len += 1;
        self.append(io, line[0..out.len], level == .err) catch {
            self.failed = true;
            // No std.log, no user-controlled content, no recursion.
            Io.File.stderr().writeStreamingAll(io, "vela: diagnostic log disabled after I/O failure\n") catch {};
        };
    }

    fn append(self: *Logger, io: Io, line: []const u8, durable: bool) !void {
        if (line.len > self.limit - self.size) {
            try self.file.?.sync(io);
            self.file.?.close(io);
            self.file = null;
            try checkFiles(self.dir.?, io);
            try rotateFiles(self.dir.?, io);
            self.file = try freshFile(self.dir.?, io);
            self.size = 0;
        }
        const file = self.file.?;
        file.writePositionalAll(io, line, self.size) catch |err| {
            // Remove a short-write tail where the backend permits recovery.
            file.setLength(io, self.size) catch {};
            file.sync(io) catch {};
            return err;
        };
        self.size += line.len;
        if (durable) try file.sync(io);
    }
};

fn privateChild(parent: Io.Dir, io: Io, name: []const u8) !Io.Dir {
    if (try fs.inspectEntry(parent, io, name) == null)
        try parent.createDir(io, name, fs.privatePermissions(true));
    const dir = try fs.child(parent, io, name, false, false);
    errdefer dir.close(io);
    if (builtin.os.tag != .windows) try dir.setPermissions(io, fs.privatePermissions(true));
    return dir;
}

fn checkFiles(dir: Io.Dir, io: Io) !void {
    for (names) |name| {
        if (try fs.inspectEntry(dir, io, name) != null) {
            const file = try fs.openRegularForSeal(dir, io, name);
            defer file.close(io);
            if (builtin.os.tag != .windows) try file.setPermissions(io, fs.privatePermissions(false));
        }
    }
}
fn rotateFiles(dir: Io.Dir, io: Io) !void {
    // Exact, fixed filenames only. Never enumerate-and-delete arbitrary entries.
    if (try fs.inspectEntry(dir, io, names[3]) != null) try dir.deleteFile(io, names[3]);
    var index: usize = 3;
    while (index > 0) : (index -= 1) {
        if (try fs.inspectEntry(dir, io, names[index - 1]) != null)
            try dir.renamePreserve(names[index - 1], dir, names[index], io);
    }
    try fs.syncDir(dir, io);
}
fn freshFile(dir: Io.Dir, io: Io) !Io.File {
    const file = try dir.createFile(io, names[0], .{ .exclusive = true, .permissions = fs.privatePermissions(false) });
    errdefer file.close(io);
    try fs.rejectReparse(try file.stat(io));
    try fs.syncDir(dir, io);
    return file;
}

const Bounded = struct {
    bytes: []u8,
    len: usize = 0,
    truncated: bool = false,
    fn add(self: *Bounded, text: []const u8) void {
        if (self.truncated) return;
        if (text.len > self.bytes.len - self.len) {
            self.truncated = true;
            return;
        }
        @memcpy(self.bytes[self.len..][0..text.len], text);
        self.len += text.len;
    }
};
fn escape(out: *Bounded, text: []const u8) void {
    const hex = "0123456789abcdef";
    var index: usize = 0;
    while (index < text.len) {
        const c = text[index];
        if (c >= 0x80) {
            const length = std.unicode.utf8ByteSequenceLength(c) catch 1;
            if (length > 1 and length <= text.len - index and std.unicode.utf8ValidateSlice(text[index..][0..length])) {
                out.add(text[index..][0..length]);
                index += length;
                continue;
            }
        }
        index += 1;
        if (c < 0x20 or c >= 0x7f) {
            const escaped = [_]u8{ 0x5c, 'x', hex[c >> 4], hex[c & 15] };
            out.add(&escaped);
        } else out.add(&.{c});
    }
}
fn startsIgnoreCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}
fn sensitive(text: []const u8) bool {
    // Deliberately match substrings, independent of separators/JSON quoting.
    // Over-redaction is preferable to missing malformed credential fields.
    for ([_][]const u8{ "token", "password", "passwd", "authorization", "bearer", "x-api-key", "api_key", "apikey", "access_token", "refresh_token", "accesstoken", "refreshtoken", "client_secret", "clientsecret", "cookie", "api-key", "passphrase" }) |key| {
        if (startsIgnoreCase(text, key)) return true;
    }
    return false;
}
fn urlEnd(text: []const u8) usize {
    for (text, 0..) |c, i| if (c <= 0x20 or c == 0x22 or c == 0x27 or c == '<' or c == '>') return i;
    return text.len;
}
fn safeUrlInto(out: *Bounded, raw: []const u8) void {
    const scheme = std.mem.indexOf(u8, raw, "://") orelse {
        out.add("[URL REDACTED]");
        return;
    };
    if (scheme == 0 or urlEnd(raw) != raw.len or std.mem.indexOfScalar(u8, raw, 0x5c) != null) {
        out.add("[URL REDACTED]");
        return;
    }
    const end = std.mem.indexOfAny(u8, raw, "?#") orelse raw.len;
    if (end < scheme + 3) {
        out.add("[URL REDACTED]");
        return;
    }
    const authority_end = if (std.mem.indexOfScalar(u8, raw[scheme + 3 .. end], '/')) |i| scheme + 3 + i else end;
    const authority = raw[scheme + 3 .. authority_end];
    const host = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |i| authority[i + 1 ..] else authority;
    if (host.len == 0) {
        out.add("[URL REDACTED]");
        return;
    }
    // Reject ambiguous/malformed authority rather than expose a partial password.
    if (std.mem.indexOfScalar(u8, host, ':')) |colon| {
        if (colon == 0 or colon + 1 == host.len) {
            out.add("[URL REDACTED]");
            return;
        }
        for (host[colon + 1 ..]) |c| {
            if (!std.ascii.isDigit(c)) {
                out.add("[URL REDACTED]");
                return;
            }
        }
    }
    var check: usize = 0;
    while (check < raw.len) : (check += 1) {
        if (sensitive(raw[check..])) {
            out.add("[URL REDACTED]");
            return;
        }
    }
    escape(out, raw[0 .. scheme + 3]);
    escape(out, host);
    escape(out, raw[authority_end..end]);
    if (end != raw.len) out.add("[query/fragment-removed]");
}
fn sanitizeInto(out: *Bounded, raw: []const u8) void {
    var i: usize = 0;
    while (i < raw.len and !out.truncated) {
        if (sensitive(raw[i..])) {
            out.add("[REDACTED]");
            return;
        }
        // Recognize all conventional schemes, not just HTTP.
        if (std.ascii.isAlphabetic(raw[i]) and (i == 0 or !(std.ascii.isAlphanumeric(raw[i - 1]) or raw[i - 1] == '+' or raw[i - 1] == '-' or raw[i - 1] == '.'))) {
            var end = i;
            while (end < raw.len and (std.ascii.isAlphanumeric(raw[end]) or raw[end] == '+' or raw[end] == '-' or raw[end] == '.')) : (end += 1) {}
            if (std.mem.startsWith(u8, raw[end..], "://")) {
                // Consume the remainder conservatively: whitespace inside a
                // malformed URL must not turn a credential tail into plain text.
                safeUrlInto(out, raw[i..]);
                return;
            }
        }
        const length = std.unicode.utf8ByteSequenceLength(raw[i]) catch 1;
        const count = if (length <= raw.len - i and std.unicode.utf8ValidateSlice(raw[i..][0..length])) length else 1;
        escape(out, raw[i..][0..count]);
        i += count;
    }
}

/// Bounded sanitized UTF-8 message; controls/invalid bytes escaped. Caller owns output.
/// On overflow appends a marker; buffers smaller than the marker return empty.
pub fn sanitize(buffer: []u8, raw: []const u8) []const u8 {
    if (buffer.len < truncation_marker.len) return buffer[0..0];
    var out: Bounded = .{ .bytes = buffer[0 .. buffer.len - truncation_marker.len] };
    sanitizeInto(&out, raw);
    if (out.truncated) {
        @memcpy(buffer[out.len..][0..truncation_marker.len], truncation_marker);
        out.len += truncation_marker.len;
    }
    return buffer[0..out.len];
}

/// Use with {f}. Formats only a bounded sanitized URL, never credentials/query.
pub fn url(raw: []const u8) SafeUrl {
    return .{ .raw = raw };
}
pub const SafeUrl = struct {
    raw: []const u8,
    pub fn format(self: SafeUrl, writer: *Io.Writer) Io.Writer.Error!void {
        var buffer: [2048]u8 = undefined;
        var out: Bounded = .{ .bytes = buffer[0 .. buffer.len - truncation_marker.len] };
        // A URL containing whitespace/control is malformed; hide it entirely.
        if (urlEnd(self.raw) != self.raw.len) out.add("[URL REDACTED]") else safeUrlInto(&out, self.raw);
        try writer.writeAll(buffer[0..out.len]);
        if (out.truncated) try writer.writeAll(truncation_marker);
    }
};

test {
    _ = @import("diagnostic_log_tests.zig");
}

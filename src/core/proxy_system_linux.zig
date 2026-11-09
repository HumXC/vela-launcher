//! GNOME GSettings and KDE KConfig discovery. Helpers are read-only, use the
//! supplied environment, and are bounded by GNU timeout plus output limits.
const std = @import("std");
const common = @import("proxy_system.zig");
const policy = @import("proxy_policy.zig");
const A = std.mem.Allocator;

pub fn resolve(a: A, io: std.Io, environ: ?*const std.process.Environ.Map, url: []const u8) !common.Resolved {
    const desktop = common.env(environ, "XDG_CURRENT_DESKTOP") orelse common.env(environ, "DESKTOP_SESSION") orelse return error.UnsupportedSystemProxy;
    const source = desktopSource(desktop) orelse return error.UnsupportedSystemProxy;
    const map = environ orelse return error.UnsupportedSystemProxy;
    const timeout = try executable(a, io, map, "timeout");
    defer a.free(timeout);
    if (source == .gnome) {
        const program = try executable(a, io, map, "gsettings");
        defer a.free(program);
        const output = try run(a, io, map, timeout, program, &.{ "list-recursively", "org.gnome.system.proxy" });
        defer wipeFree(a, output);
        return parseGnome(a, output, url);
    }
    const program = executable(a, io, map, "kreadconfig6") catch |err| switch (err) {
        error.SystemProxyToolUnavailable => try executable(a, io, map, "kreadconfig5"),
        else => return err,
    };
    defer a.free(program);
    const context: Kde = .{ .a = a, .io = io, .environ = map, .timeout = timeout, .program = program };
    return context.resolve(url);
}

fn desktopSource(desktop: []const u8) ?common.Source {
    var parts = std.mem.tokenizeAny(u8, desktop, ":;");
    while (parts.next()) |part| {
        if (std.ascii.eqlIgnoreCase(part, "GNOME") or std.ascii.eqlIgnoreCase(part, "Unity")) return .gnome;
        if (std.ascii.eqlIgnoreCase(part, "KDE") or std.ascii.eqlIgnoreCase(part, "plasma")) return .kde;
    }
    return null;
}
fn wipeFree(a: A, value: []u8) void {
    std.crypto.secureZero(u8, value);
    a.free(value);
}
fn executable(a: A, io: std.Io, environ: *const std.process.Environ.Map, name: []const u8) ![]u8 {
    const path = common.env(environ, "PATH") orelse return error.SystemProxyToolUnavailable;
    var dirs = std.mem.splitScalar(u8, path, ':');
    while (dirs.next()) |dir| {
        // Do not execute relative PATH entries or implicitly consult cwd.
        if (!std.fs.path.isAbsolute(dir)) continue;
        const candidate = try std.fs.path.join(a, &.{ dir, name });
        std.Io.Dir.accessAbsolute(io, candidate, .{ .execute = true }) catch |err| {
            a.free(candidate);
            switch (err) {
                error.FileNotFound, error.AccessDenied, error.PermissionDenied => continue,
                error.Canceled => return error.Canceled,
                else => return error.ProxyDetectionFailed,
            }
        };
        return candidate;
    }
    return error.SystemProxyToolUnavailable;
}
fn run(a: A, io: std.Io, environ: *const std.process.Environ.Map, timeout: []const u8, program: []const u8, args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.appendSlice(a, &.{ timeout, "--signal=KILL", "3s", program });
    try argv.appendSlice(a, args);
    const result = std.process.run(a, io, .{
        .argv = argv.items,
        .environ_map = environ,
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(4 * 1024),
        .timeout = (std.Io.Timeout{ .duration = .{ .raw = .fromSeconds(4), .clock = .awake } }).toDeadline(io),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        error.Timeout => return error.ProxyDetectionTimeout,
        else => return error.ProxyDetectionFailed,
    };
    defer wipeFree(a, result.stderr);
    errdefer wipeFree(a, result.stdout);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            if (code == 124 or code == 137) return error.ProxyDetectionTimeout;
            return error.ProxyDetectionFailed;
        },
        else => return error.ProxyDetectionFailed,
    }
    return result.stdout;
}

fn setting(output: []const u8, schema: []const u8, key: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, schema) or line.len <= schema.len or line[schema.len] != ' ') continue;
        const rest = std.mem.trim(u8, line[schema.len + 1 ..], " \t\r");
        if (!std.mem.startsWith(u8, rest, key) or rest.len <= key.len or rest[key.len] != ' ') continue;
        return std.mem.trim(u8, rest[key.len + 1 ..], " \t\r");
    }
    return error.ProxyDetectionFailed;
}
fn boolValue(text: []const u8) !bool {
    if (std.mem.eql(u8, text, "true")) return true;
    if (std.mem.eql(u8, text, "false")) return false;
    return error.InvalidProxyConfiguration;
}
/// GVariant's printed strings, without evaluating shell syntax or commands.
fn quoted(a: A, input: []const u8) ![]u8 {
    const text = std.mem.trim(u8, input, " \t\r\n");
    if (text.len < 2 or (text[0] != '\'' and text[0] != '"') or text[text.len - 1] != text[0]) return error.InvalidProxyConfiguration;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 1;
    while (i < text.len - 1) : (i += 1) {
        var byte = text[i];
        if (byte == text[0]) return error.InvalidProxyConfiguration;
        if (byte == '\\') {
            i += 1;
            if (i >= text.len - 1) return error.InvalidProxyConfiguration;
            byte = switch (text[i]) {
                '\\', '\'', '"' => text[i],
                else => return error.InvalidProxyConfiguration,
            };
        }
        if (byte < 0x20 or byte == 0x7f) return error.InvalidProxyConfiguration;
        try out.append(a, byte);
    }
    return out.toOwnedSlice(a);
}
fn stringArray(a: A, input: []const u8) ![]u8 {
    var text = std.mem.trim(u8, input, " \t\r\n");
    if (std.mem.startsWith(u8, text, "@as ")) text = std.mem.trimStart(u8, text[4..], " ");
    if (text.len < 2 or text[0] != '[' or text[text.len - 1] != ']') return error.InvalidProxyConfiguration;
    text = std.mem.trim(u8, text[1 .. text.len - 1], " ");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    while (text.len != 0) {
        const quote = text[0];
        if (quote != '\'' and quote != '"') return error.InvalidProxyConfiguration;
        var end: usize = 1;
        while (end < text.len and text[end] != quote) : (end += 1) {
            if (text[end] == '\\') end += 1;
        }
        if (end >= text.len) return error.InvalidProxyConfiguration;
        const value = try quoted(a, text[0 .. end + 1]);
        defer wipeFree(a, value);
        if (std.mem.findAny(u8, value, ",; ") != null) return error.UnsupportedProxyBypass;
        if (out.items.len != 0) try out.append(a, ',');
        try out.appendSlice(a, value);
        text = std.mem.trimStart(u8, text[end + 1 ..], " ");
        if (text.len == 0) break;
        if (text[0] != ',') return error.InvalidProxyConfiguration;
        text = std.mem.trimStart(u8, text[1..], " ");
    }
    return out.toOwnedSlice(a);
}
fn gnomeString(a: A, output: []const u8, schema: []const u8, key: []const u8) ![]u8 {
    return quoted(a, try setting(output, schema, key));
}
fn parseGnome(a: A, output: []const u8, url: []const u8) !common.Resolved {
    const mode = try gnomeString(a, output, "org.gnome.system.proxy", "mode");
    defer a.free(mode);
    if (std.mem.eql(u8, mode, "none")) return common.owned(a, "", "", .gnome);
    if (std.mem.eql(u8, mode, "auto")) return error.UnsupportedProxyAutoConfig;
    if (!std.mem.eql(u8, mode, "manual")) return error.InvalidProxyConfiguration;
    const uri = try common.parseUrl(url);
    const same = try boolValue(setting(output, "org.gnome.system.proxy", "use-same-proxy") catch "false");
    var schema: []const u8 = if (same or std.ascii.eqlIgnoreCase(uri.scheme, "http")) "org.gnome.system.proxy.http" else "org.gnome.system.proxy.https";
    var host = try gnomeString(a, output, schema, "host");
    defer wipeFree(a, host);
    var proxy_scheme: []const u8 = "http";
    if (host.len == 0) {
        const socks_host = try gnomeString(a, output, "org.gnome.system.proxy.socks", "host");
        a.free(host);
        host = socks_host;
        schema = "org.gnome.system.proxy.socks";
        proxy_scheme = "socks5h";
    }
    if (host.len == 0) return common.owned(a, "", "", .gnome);
    const port = std.fmt.parseInt(u16, try setting(output, schema, "port"), 10) catch return error.InvalidProxyConfiguration;
    const proxy = try common.endpoint(a, proxy_scheme, host, port);
    defer wipeFree(a, proxy);
    const exclusions = try stringArray(a, try setting(output, "org.gnome.system.proxy", "ignore-hosts"));
    defer a.free(exclusions);
    const bypass = try common.desktopBypass(a, exclusions, url);
    defer a.free(bypass);
    // Validate the full exclusion list before matching, then check credentials
    // only for requests that will actually use this proxy.
    if (try policy.bypasses(url, bypass)) return common.owned(a, "", "", .gnome);
    if (std.mem.eql(u8, schema, "org.gnome.system.proxy.http") and try boolValue(try setting(output, schema, "use-authentication"))) return error.UnsupportedProxyAuthentication;
    return common.owned(a, proxy, bypass, .gnome);
}

const Kde = struct {
    a: A,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    timeout: []const u8,
    program: []const u8,

    fn get(self: Kde, key: []const u8, default: []const u8) ![]u8 {
        return run(self.a, self.io, self.environ, self.timeout, self.program, &.{ "--file", "kioslaverc", "--group", "Proxy Settings", "--key", key, "--default", default });
    }
    fn resolve(self: Kde, url: []const u8) !common.Resolved {
        const mode_raw = try self.get("ProxyType", "0");
        defer self.a.free(mode_raw);
        const mode = std.fmt.parseInt(u8, std.mem.trim(u8, mode_raw, " \r\n"), 10) catch return error.InvalidProxyConfiguration;
        switch (mode) {
            0 => return common.owned(self.a, "", "", .kde),
            1 => {},
            2, 3 => return error.UnsupportedProxyAutoConfig,
            // KDE environment mode permits custom variable names. It must not
            // silently become direct after the normal curl environment lookup.
            4 => return error.UnsupportedSystemProxy,
            else => return error.InvalidProxyConfiguration,
        }
        const reverse_raw = try self.get("ReversedException", "false");
        defer self.a.free(reverse_raw);
        if (try boolValue(std.mem.trim(u8, reverse_raw, " \r\n"))) return error.UnsupportedProxyBypass;
        const uri = try common.parseUrl(url);
        const key: []const u8 = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) "httpsProxy" else "httpProxy";
        var proxy_raw = try self.get(key, "");
        defer wipeFree(self.a, proxy_raw);
        var proxy_scheme: []const u8 = "http";
        if (std.mem.trim(u8, proxy_raw, " \r\n").len == 0) {
            const socks = try self.get("socksProxy", "");
            self.a.free(proxy_raw);
            proxy_raw = socks;
            proxy_scheme = "socks5h";
        }
        const proxy = try kdeProxy(self.a, std.mem.trim(u8, proxy_raw, " \r\n"), proxy_scheme);
        defer wipeFree(self.a, proxy);
        if (proxy.len == 0) return common.owned(self.a, "", "", .kde);
        const exclusions = try self.get("NoProxyFor", "");
        defer self.a.free(exclusions);
        const bypass = try common.desktopBypass(self.a, std.mem.trim(u8, exclusions, " \r\n"), url);
        defer self.a.free(bypass);
        return common.owned(self.a, proxy, bypass, .kde);
    }
};
fn kdeProxy(a: A, value: []const u8, default_scheme: []const u8) ![]u8 {
    try common.validateText(value);
    if (value.len == 0) return a.dupe(u8, "");
    var scheme = default_scheme;
    var authority = value;
    if (std.mem.find(u8, value, "://")) |n| {
        scheme = value[0..n];
        authority = value[n + 3 ..];
    }
    if (std.ascii.eqlIgnoreCase(scheme, "socks")) scheme = "socks5h";
    if (!std.mem.eql(u8, scheme, "http") and !std.mem.eql(u8, scheme, "https") and
        !std.mem.eql(u8, scheme, "socks4") and !std.mem.eql(u8, scheme, "socks4a") and
        !std.mem.eql(u8, scheme, "socks5") and !std.mem.eql(u8, scheme, "socks5h")) return error.UnsupportedSystemProxy;
    if (authority.len == 0) return error.InvalidProxyConfiguration;
    // KConfig commonly stores "http://proxy.example 8080".
    if (std.mem.findScalar(u8, authority, ' ')) |space| {
        const port = std.fmt.parseInt(u16, std.mem.trim(u8, authority[space + 1 ..], " "), 10) catch return error.InvalidProxyConfiguration;
        if (port == 0 or space == 0) return error.InvalidProxyConfiguration;
        return a.print("{s}://{s}:{d}", .{ scheme, authority[0..space], port });
    }
    return a.print("{s}://{s}", .{ scheme, authority });
}

test "desktop selection does not guess unknown sessions" {
    try std.testing.expectEqual(common.Source.gnome, desktopSource("ubuntu:GNOME").?);
    try std.testing.expectEqual(common.Source.kde, desktopSource("KDE").?);
    try std.testing.expectEqual(@as(?common.Source, null), desktopSource("sway"));
}
test "GVariant parsing and KDE host port representation" {
    const a = std.testing.allocator;
    const array = try stringArray(a, "['localhost', '*.example.org', '::1']");
    defer a.free(array);
    try std.testing.expectEqualStrings("localhost,*.example.org,::1", array);
    const empty = try stringArray(a, "@as []");
    defer a.free(empty);
    try std.testing.expectEqualStrings("", empty);
    try std.testing.expectError(error.InvalidProxyConfiguration, quoted(a, "'unterminated"));
    const proxy = try kdeProxy(a, "http://proxy.example 8080", "http");
    defer a.free(proxy);
    try std.testing.expectEqualStrings("http://proxy.example:8080", proxy);
}
test "GNOME none auto manual and malformed detection remain distinct" {
    const a = std.testing.allocator;
    var none = try parseGnome(a, "org.gnome.system.proxy mode 'none'\n", "https://example.org");
    defer none.deinit(a);
    try std.testing.expectEqualStrings("", none.proxy);
    try std.testing.expectError(error.UnsupportedProxyAutoConfig, parseGnome(a, "org.gnome.system.proxy mode 'auto'\n", "https://example.org"));
    try std.testing.expectError(error.ProxyDetectionFailed, parseGnome(a, "", "https://example.org"));
    var manual = try parseGnome(a,
        \\org.gnome.system.proxy mode 'manual'
        \\org.gnome.system.proxy ignore-hosts ['localhost', '*.example.org']
        \\org.gnome.system.proxy.https host 'secure-proxy.example'
        \\org.gnome.system.proxy.https port 8443
    , "https://outside.example.net");
    defer manual.deinit(a);
    try std.testing.expectEqualStrings("http://secure-proxy.example:8443", manual.proxy);
    try std.testing.expectEqualStrings("localhost,.example.org", manual.bypass);
}

test "GNOME authenticated shared proxy allows only matching bypass routes" {
    const a = std.testing.allocator;
    const settings =
        \\org.gnome.system.proxy mode 'manual'
        \\org.gnome.system.proxy use-same-proxy true
        \\org.gnome.system.proxy.http host 'proxy.example'
        \\org.gnome.system.proxy.http port 8080
        \\org.gnome.system.proxy.http use-authentication true
        \\
    ;
    const exclusions = "org.gnome.system.proxy ignore-hosts ['*.example.org']\n";
    var direct = try parseGnome(a, settings ++ exclusions, "https://sub.example.org/file");
    defer direct.deinit(a);
    try std.testing.expectEqualStrings("", direct.proxy);
    try std.testing.expectEqualStrings("", direct.bypass);
    try std.testing.expectEqual(common.Source.gnome, direct.source);
    try std.testing.expectError(error.UnsupportedProxyAuthentication, parseGnome(a, settings ++ exclusions, "https://outside.example.net/file"));
    try std.testing.expectError(error.UnsupportedProxyBypass, parseGnome(a, settings ++ "org.gnome.system.proxy ignore-hosts ['*.example.org', 'bad*pattern']\n", "https://sub.example.org/file"));
}

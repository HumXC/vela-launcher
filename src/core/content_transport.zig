//! Worker-only adapter. Place Adapter at its final address before obtaining
//! callbacks; do not move it or deinit until every callback has returned.
//! Explicit fixture HTTP replaces transport only; installation and filesystem execution remain real.
const std = @import("std");
const http = @import("http_transport.zig");
const providers = @import("content_providers.zig");
const install = @import("content_install.zig");
const downloader = @import("downloader.zig");
const fs = @import("content_fs.zig");
const task_metrics = @import("tasks.zig");
const Allocator = std.mem.Allocator;

pub const CancelToken = std.atomic.Value(bool);
/// Kept in sync with build.zig.zon's application version; no credentials/contact guesses.
pub const user_agent = "Vela/0.1.0";
pub const HttpFunction = *const fn (?*anyopaque, Allocator, std.Io, http.Request) anyerror!http.Response;

pub const Adapter = struct {
    pub const Options = struct {
        http: http.Options = .{},
        /// Required for production downloads; fixture-only transports need no network budget.
        download_budget: ?*downloader.Budget = null,
        allow_curseforge: bool = false,
        /// Worker-only secret, borrowed only until initWithOptions returns.
        /// The adapter owns a private copy and securely erases it at deinit.
        curseforge_download_key: ?[]const u8 = null,
        /// Explicit test transport for metadata and downloads; never falls back to real HTTP.
        /// The returned response owns its body and records its owning allocator.
        fixture_http: ?HttpFunction = null,
        fixture_context: ?*anyopaque = null,
        /// Exact DNS names, not suffix patterns. Copied during initialization.
        approved_download_hosts: []const []const u8 = &.{"cdn.modrinth.com"},
    };

    allocator: Allocator,
    io: std.Io,
    cancel: ?*const CancelToken,
    connections: u16,
    download_budget: ?*downloader.Budget,
    allow_curseforge: bool,
    curseforge_download_key: ?[]u8,
    client: http.Client,
    fixture_http: ?HttpFunction,
    fixture_context: ?*anyopaque,
    approved_download_hosts: [][]const u8,
    service: ?*downloader.Service = null,
    /// Borrowed until the owning worker joins; publication copies bounded data.
    telemetry: ?*task_metrics.Task = null,
    transfer_details: task_metrics.Details = .{},
    transfer_base_received: u64 = 0,
    transfer_index: usize = 0,

    pub fn init(a: Allocator, io: std.Io, cancel: ?*const CancelToken, connections: u16) !Adapter {
        return initWithOptions(a, io, cancel, connections, .{});
    }

    pub fn initWithOptions(a: Allocator, io: std.Io, cancel: ?*const CancelToken, connections: u16, options: Options) !Adapter {
        if (connections == 0 or connections > 64) return error.InvalidConcurrency;
        if (options.http.proxy) |proxy| if (proxy.len != 0) return error.UnsupportedProxyWithPublicAddressGuard;
        if (options.approved_download_hosts.len > 64) return error.TooManyHosts;
        const hosts = try a.alloc([]const u8, options.approved_download_hosts.len);
        errdefer a.free(hosts);
        var copied: usize = 0;
        errdefer for (hosts[0..copied]) |host| a.free(host);
        for (options.approved_download_hosts, 0..) |host, i| {
            const url = try std.fmt.allocPrint(a, "https://{s}/", .{host});
            defer a.free(url);
            if (!providers.safeHttpsUrl(url)) return error.InvalidDownloadHost;
            const uri = try std.Uri.parse(url);
            if (!std.mem.eql(u8, uri.host.?.percent_encoded, host)) return error.InvalidDownloadHost;
            hosts[i] = try a.dupe(u8, host);
            copied += 1;
        }
        const key = if (options.curseforge_download_key) |value| blk: {
            if (value.len == 0 or value.len > 512) return error.InvalidCredential;
            for (value) |byte| if (byte < 33 or byte > 126) return error.InvalidCredential;
            break :blk try a.dupe(u8, value);
        } else null;
        errdefer if (key) |owned| {
            std.crypto.secureZero(u8, owned);
            a.free(owned);
        };
        return .{
            .allocator = a,
            .io = io,
            .cancel = cancel,
            .connections = connections,
            .download_budget = options.download_budget,
            .allow_curseforge = options.allow_curseforge,
            .curseforge_download_key = key,
            .client = try http.Client.init(a, io, options.http),
            .fixture_http = options.fixture_http,
            .fixture_context = options.fixture_context,
            .approved_download_hosts = hosts,
        };
    }

    pub fn deinit(self: *Adapter) void {
        // Client's libcurl global reference outlives the streaming service.
        if (self.service) |service| service.deinit();
        self.client.deinit();
        if (self.curseforge_download_key) |key| {
            std.crypto.secureZero(u8, key);
            self.allocator.free(key);
        }
        for (self.approved_download_hosts) |host| self.allocator.free(host);
        self.allocator.free(self.approved_download_hosts);
        self.* = undefined;
    }

    pub fn providerTransport(self: *Adapter) providers.Transport {
        return .{ .context = self, .get = get };
    }

    pub fn fetcher(self: *Adapter) install.Fetcher {
        return .{ .context = self, .fetchToFile = fetchToFile };
    }

    fn get(context: ?*anyopaque, a: Allocator, request: providers.Request) !providers.Response {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return error.MissingContext));
        try fs.cancelled(self.io, self.cancel, null);
        try validateProviderRequest(request);
        if (!self.allow_curseforge and std.mem.startsWith(u8, request.url, providers.curseforge_api_base ++ "/")) return error.ProviderDisabled;
        var headers: [3]http.Header = undefined;
        headers[0] = .{ .name = "User-Agent", .value = user_agent };
        headers[1] = .{ .name = "Accept", .value = "application/json" };
        var header_count: usize = 2;
        if (request.credential_header) |header| {
            headers[2] = .{ .name = header.name, .value = header.value };
            header_count += 1;
        }
        const bounded: http.Request = .{
            .url = request.url,
            .headers = headers[0..header_count],
            .max_response_bytes = request.max_body_bytes,
            .timeout_ms = request.timeout_ms,
            .cancel = self.cancel,
            .follow_redirects = false,
            .require_public_address = true,
        };
        var response = if (self.fixture_http) |execute|
            try execute(self.fixture_context, a, self.io, bounded)
        else
            try self.client.execute(bounded);
        defer response.deinit();
        try fs.cancelled(self.io, self.cancel, null);
        if (response.body.len > request.max_body_bytes) return error.ResponseTooLarge;
        if (response.status < 100 or response.status > 599) return error.InvalidHttpStatus;
        return .{ .status = response.status, .body = try a.dupe(u8, response.body) };
    }

    /// Serial callback use on the owning worker. The downloader itself manages
    /// up to connections active transfers; no filesystem transaction is bypassed.
    fn fetchToFile(context: ?*anyopaque, io: std.Io, request: install.FetchRequest) !void {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return error.MissingContext));
        try self.checkFetch(io, request);
        if (!self.approvedUrl(request.url)) return error.UnapprovedDownloadHost;
        if (!fs.safeComponent(request.name) or !std.fs.path.isAbsolute(request.absolute_path)) return error.UnsafePath;
        if (request.max_bytes == 0 or request.max_bytes > providers.max_file_bytes) return error.InvalidLimit;
        if (request.expected_size) |size| if (size > request.max_bytes) return error.InvalidLimit;
        self.beginTransfer(request);
        self.fetchTransfer(io, request) catch |err| {
            if (self.telemetry != null) {
                const current = self.transfer_details.files[self.transfer_index];
                self.publishTransfer(current.received, current.total, 0, if (err == error.Canceled) .canceled else .failed, err);
            }
            return err;
        };
    }

    fn fetchTransfer(self: *Adapter, io: std.Io, request: install.FetchRequest) !void {
        if (self.fixture_http) |execute| {
            try self.fetchFixture(io, request, execute);
            if (self.telemetry != null) {
                const current = self.transfer_details.files[self.transfer_index];
                self.publishTransfer(current.received, current.total, 0, .complete, null);
            }
            return;
        }
        const download: downloader.Request = .{
            .url = request.url,
            .output = .{ .file = request.absolute_path },
            .curseforge_download_key = self.downloadKey(request.url),
            .expected_sha1 = request.expected_sha1,
            .expected_size = request.expected_size,
            .max_bytes = std.math.cast(usize, request.max_bytes) orelse return error.BodyTooLarge,
            .proxy = self.client.proxy,
            .ca_bundle = self.client.ca_path,
            // Progress and cancellation remain user-controlled for large pack files.
            .timeout_ms = 0,
            .https_only = true,
            .follow_redirects = false,
            .require_public_address = true,
        };
        if (self.service == null) self.service = try downloader.Service.init(self.allocator, self.io, self.download_budget orelse return error.MissingDownloadBudget, self.connections);
        const task = try self.service.?.submit(download);
        var cancellation: ?anyerror = null;
        while (true) {
            const snapshot = task.snapshot();
            self.publishTransfer(snapshot.progress.received, snapshot.progress.total orelse request.expected_size, snapshot.progress.bytes_per_second, switch (snapshot.progress.phase) {
                .complete => .complete,
                .failed => .failed,
                .canceled => .canceled,
                .processing, .parsing, .committing => .verifying,
                else => .downloading,
            }, snapshot.failure);
            if (downloader.terminal(snapshot.progress.phase)) {
                defer task.release() catch unreachable;
                if (cancellation) |err| return err;
                try self.checkFetch(io, request);
                if (snapshot.failure) |err| return err;
                if (snapshot.http_status < 200 or snapshot.http_status >= 300) return error.HttpStatus;
                return;
            }
            self.checkFetch(io, request) catch |err| {
                cancellation = err;
                task.cancel();
            };
            // Even on cancellation, drain the task before releasing borrowed inputs.
            task.wait() catch |err| {
                cancellation = err;
                task.cancel();
                task.join();
            };
        }
    }

    fn fetchFixture(self: *Adapter, io: std.Io, request: install.FetchRequest, execute: HttpFunction) !void {
        const limit = std.math.cast(usize, request.max_bytes) orelse return error.BodyTooLarge;
        const key = self.downloadKey(request.url);
        const headers: [1]http.Header = .{.{ .name = "x-api-key", .value = key orelse "" }};
        const bounded: http.Request = .{
            .url = request.url,
            .headers = if (key != null) &headers else &.{},
            .sensitive = key != null,
            .max_response_bytes = limit,
            .timeout_ms = 120_000,
            .deadline_ns = request.deadline_ns,
            .cancel = request.cancel orelse self.cancel,
            .follow_redirects = false,
            .allow_http_loopback = false,
            .require_public_address = true,
        };
        try self.checkFetch(io, request);
        var response = try execute(self.fixture_context, self.allocator, io, bounded);
        defer response.deinit();
        try self.checkFetch(io, request);
        if (response.status < 100 or response.status > 599) return error.InvalidHttpStatus;
        if (response.status < 200 or response.status >= 300) return error.HttpStatus;
        if (response.body.len > limit) return error.BodyTooLarge;
        if (request.expected_size) |size| if (response.body.len != size) return error.SizeMismatch;
        if (try fs.inspectEntry(request.directory, io, request.name) != null) return error.PathAlreadyExists;
        const file = try request.directory.createFile(io, request.name, .{ .exclusive = true, .permissions = fs.privatePermissions(false) });
        defer file.close(io);
        errdefer request.directory.deleteFile(io, request.name) catch {};
        var hash = std.crypto.hash.Sha1.init(.{});
        var offset: usize = 0;
        while (offset < response.body.len) {
            try self.checkFetch(io, request);
            const end = offset + @min(@as(usize, 64 * 1024), response.body.len - offset);
            const bytes = response.body[offset..end];
            try file.writePositionalAll(io, bytes, @intCast(offset));
            if (request.expected_sha1 != null) hash.update(bytes);
            offset = end;
            self.publishTransfer(@intCast(offset), @intCast(response.body.len), 0, .downloading, null);
        }
        try self.checkFetch(io, request);
        if (request.expected_sha1) |expected| {
            var digest: [20]u8 = undefined;
            hash.final(&digest);
            if (!std.mem.eql(u8, &digest, &expected)) return error.Sha1Mismatch;
        }
        try file.sync(io);
        try fs.syncDir(request.directory, io);
        try self.checkFetch(io, request);
    }

    fn beginTransfer(self: *Adapter, request: install.FetchRequest) void {
        if (self.telemetry == null) return;
        self.transfer_base_received = self.transfer_details.received;
        self.transfer_index = @min(self.transfer_details.file_count, self.transfer_details.files.len - 1);
        const row = task_metrics.File.init(request.url, 0, request.expected_size, 0, .downloading, null);
        if (self.transfer_details.file_count < self.transfer_details.files.len) self.transfer_details.addFile(row) else {
            self.transfer_details.omitted_files += 1;
            self.transfer_details.files[self.transfer_index] = row;
        }
        self.publishTransfer(0, request.expected_size, 0, .downloading, null);
    }

    fn publishTransfer(self: *Adapter, received: u64, total: ?u64, speed: f64, file_state: task_metrics.FileState, failure: ?anyerror) void {
        const destination = self.telemetry orelse return;
        const row = &self.transfer_details.files[self.transfer_index];
        row.received = received;
        row.total = total;
        row.bytes_per_second = speed;
        row.state = file_state;
        row.failure = failure;
        self.transfer_details.stage = .downloading;
        self.transfer_details.received = self.transfer_base_received +| received;
        self.transfer_details.total_bytes = if (total) |limit| self.transfer_base_received +| limit else null;
        self.transfer_details.completed = self.transfer_details.received;
        self.transfer_details.total = self.transfer_details.total_bytes;
        self.transfer_details.bytes_per_second = speed;
        destination.reportDetails(self.transfer_details);
    }

    fn checkFetch(self: *const Adapter, io: std.Io, request: install.FetchRequest) !void {
        try fs.cancelled(io, self.cancel, request.deadline_ns);
        try fs.cancelled(io, request.cancel, request.deadline_ns);
    }

    fn downloadKey(self: *const Adapter, url: []const u8) ?[]const u8 {
        if (!self.allow_curseforge or !curseforgeDownloadUrlAllowed(url)) return null;
        for (self.approved_download_hosts) |host| {
            if (std.mem.eql(u8, host, "edge.forgecdn.net")) return self.curseforge_download_key;
        }
        return null;
    }

    fn approvedUrl(self: *const Adapter, url: []const u8) bool {
        // Syntactic public-host rules and exact approval complement the HTTP and
        // downloader resolved-peer guard; neither substitutes for that guard.
        if (!providers.safeHttpsUrl(url)) return false;
        const uri = std.Uri.parse(url) catch return false;
        const host = uri.host.?.percent_encoded;
        for (self.approved_download_hosts) |allowed| if (std.ascii.eqlIgnoreCase(allowed, host)) return true;
        return false;
    }
};

/// Separate from metadata credentialScopeAllowed: download credentials must never
/// broaden the api.curseforge.com metadata scope. Only server-returned URLs enter here.
pub fn curseforgeDownloadUrlAllowed(url: []const u8) bool {
    if (!providers.safeHttpsUrl(url)) return false;
    const prefix = "https://edge.forgecdn.net/files/";
    if (!std.mem.startsWith(u8, url, prefix)) return false;
    const uri = std.Uri.parse(url) catch return false;
    if (uri.query != null) return false;
    var parts = std.mem.splitScalar(u8, url[prefix.len..], '/');
    for (0..2) |_| {
        const number = parts.next() orelse return false;
        if (number.len == 0) return false;
        for (number) |byte| if (!std.ascii.isDigit(byte)) return false;
    }
    const filename = parts.next() orelse return false;
    if (filename.len == 0 or parts.next() != null) return false;
    var decoded: [providers.max_string_bytes]u8 = undefined;
    var count: usize = 0;
    var index: usize = 0;
    while (index < filename.len) {
        const byte = if (filename[index] == '%') blk: {
            const value = std.fmt.parseInt(u8, filename[index + 1 ..][0..2], 16) catch return false;
            index += 3;
            break :blk value;
        } else blk: {
            const value = filename[index];
            index += 1;
            break :blk value;
        };
        if (byte < 32 or byte == 127 or byte == '/' or byte == '\\' or byte == '%' or byte == '?' or byte == '#') return false;
        decoded[count] = byte;
        count += 1;
    }
    return !std.mem.eql(u8, decoded[0..count], ".") and !std.mem.eql(u8, decoded[0..count], "..");
}

fn validateProviderRequest(request: providers.Request) !void {
    if (request.follow_redirects) return error.RedirectsDisabled;
    if (request.max_body_bytes == 0 or request.max_body_bytes > providers.max_json_bytes) return error.InvalidLimit;
    if (request.timeout_ms == 0 or request.timeout_ms > 120_000) return error.InvalidTimeout;
    if (!providers.safeHttpsUrl(request.url)) return error.UnapprovedProviderUrl;
    if (!providers.credentialScopeAllowed(request)) return error.InvalidCredentialScope;
    const uri = try std.Uri.parse(request.url);
    const path = uri.path.percent_encoded;
    if (std.mem.startsWith(u8, request.url, providers.curseforge_api_base ++ "/")) {
        if (request.credential_header == null) return error.ProviderDisabled;
        if (std.mem.eql(u8, path, "/v1/mods/search")) return;
        if (!std.mem.startsWith(u8, path, "/v1/mods/")) return error.UnapprovedProviderRoute;
        var parts = std.mem.splitScalar(u8, path["/v1/mods/".len..], '/');
        if (!validCurseForgeId(parts.next() orelse return error.UnapprovedProviderRoute)) return error.UnapprovedProviderRoute;
        if (parts.next()) |segment| {
            if (!std.mem.eql(u8, segment, "files")) return error.UnapprovedProviderRoute;
            if (parts.next()) |file_id| {
                if (!validCurseForgeId(file_id) or parts.next() != null or uri.query != null) return error.UnapprovedProviderRoute;
            }
        } else if (uri.query != null) return error.UnapprovedProviderRoute;
        return;
    }
    if (!std.mem.startsWith(u8, request.url, "https://api.modrinth.com/v2/")) return error.ProviderDisabled;
    if (std.mem.eql(u8, path, "/v2/search")) return;
    if (std.mem.startsWith(u8, path, "/v2/project/")) {
        const rest = path["/v2/project/".len..];
        if (std.mem.endsWith(u8, rest, "/version")) {
            if (providers.validToken(rest[0 .. rest.len - "/version".len])) return;
        } else if (providers.validToken(rest) and uri.query == null) return;
    }
    if (std.mem.startsWith(u8, path, "/v2/version/") and uri.query == null and providers.validToken(path["/v2/version/".len..])) return;
    return error.UnapprovedProviderRoute;
}

fn validCurseForgeId(id: []const u8) bool {
    if (id.len == 0 or id.len > 10 or id[0] == '0') return false;
    for (id) |byte| if (!std.ascii.isDigit(byte)) return false;
    const value = std.fmt.parseInt(u32, id, 10) catch return false;
    return value <= std.math.maxInt(i32);
}

const scoped_fixture_key = "fixture-key-not-a-real-secret";
const ScopedFixture = struct {
    calls: usize = 0,
    max_bytes: usize = providers.max_json_bytes,
    timeout_ms: u32 = 15000,

    fn execute(context: ?*anyopaque, a: Allocator, _: std.Io, request: http.Request) !http.Response {
        const self: *ScopedFixture = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        try std.testing.expectEqual(http.Method.get, request.method);
        try std.testing.expect(!request.follow_redirects);
        try std.testing.expect(request.require_public_address);
        try std.testing.expectEqual(self.max_bytes, request.max_response_bytes);
        try std.testing.expectEqual(self.timeout_ms, request.timeout_ms);
        try std.testing.expectEqualStrings("User-Agent", request.headers[0].name);
        try std.testing.expectEqualStrings(user_agent, request.headers[0].value);
        try std.testing.expectEqualStrings("Accept", request.headers[1].name);
        try std.testing.expectEqualStrings("application/json", request.headers[1].value);
        if (std.mem.startsWith(u8, request.url, providers.curseforge_api_base ++ "/")) {
            try std.testing.expectEqual(@as(usize, 3), request.headers.len);
            try std.testing.expectEqualStrings("x-api-key", request.headers[2].name);
            try std.testing.expectEqualStrings(scoped_fixture_key, request.headers[2].value);
        } else {
            try std.testing.expectEqual(@as(usize, 2), request.headers.len);
        }
        return .{ .status = 200, .body = try a.dupe(u8, "{}"), .allocator = a };
    }
};

fn scopedFixtureRequest() providers.Request {
    return .{
        .url = providers.curseforge_api_base ++ "/mods/1",
        .user_agent = "ignored caller user agent",
        .credential_header = .{ .name = "x-api-key", .value = scoped_fixture_key },
    };
}

test "CF transport default admission denies an enabled client before HTTP" {
    const a = std.testing.allocator;
    var fixture: ScopedFixture = .{};
    var adapter = try Adapter.initWithOptions(a, std.testing.io, null, 1, .{ .fixture_http = ScopedFixture.execute, .fixture_context = &fixture });
    defer adapter.deinit();
    const transport = adapter.providerTransport();
    try std.testing.expectError(error.ProviderDisabled, transport.get(transport.context, a, scopedFixtureRequest()));
    const client: providers.CurseForgeClient = .{
        .allocator = a,
        .transport = transport,
        .user_agent = user_agent,
        .options = .{ .enabled = true, .terms_approved = true, .api_key = scoped_fixture_key },
    };
    try std.testing.expectError(error.ProviderDisabled, client.project("1"));
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}

test "CF transport explicit admission scopes headers to four bounded GET routes" {
    const a = std.testing.allocator;
    var fixture: ScopedFixture = .{ .max_bytes = 512, .timeout_ms = 1000 };
    var adapter = try Adapter.initWithOptions(a, std.testing.io, null, 1, .{ .allow_curseforge = true, .fixture_http = ScopedFixture.execute, .fixture_context = &fixture });
    defer adapter.deinit();
    const transport = adapter.providerTransport();
    var request = scopedFixtureRequest();
    request.max_body_bytes = fixture.max_bytes;
    request.timeout_ms = fixture.timeout_ms;
    for ([_][]const u8{
        providers.curseforge_api_base ++ "/mods/search?gameId=432&classId=6",
        providers.curseforge_api_base ++ "/mods/1",
        providers.curseforge_api_base ++ "/mods/2147483647/files?index=0&pageSize=20",
        providers.curseforge_api_base ++ "/mods/1/files/2",
    }) |url| {
        request.url = url;
        const response = try transport.get(transport.context, a, request);
        a.free(response.body);
    }
    request.url = "https://api.modrinth.com/v2/search?query=fixture";
    request.credential_header = null;
    const response = try transport.get(transport.context, a, request);
    defer a.free(response.body);
    try std.testing.expectEqual(@as(usize, 5), fixture.calls);
}

test "CF transport rejects missing malformed and oversized credentials before HTTP" {
    const a = std.testing.allocator;
    var fixture: ScopedFixture = .{};
    var adapter = try Adapter.initWithOptions(a, std.testing.io, null, 1, .{ .allow_curseforge = true, .fixture_http = ScopedFixture.execute, .fixture_context = &fixture });
    defer adapter.deinit();
    const transport = adapter.providerTransport();
    var request = scopedFixtureRequest();
    request.credential_header = null;
    try std.testing.expectError(error.ProviderDisabled, transport.get(transport.context, a, request));
    for ([_][]const u8{ "", "bad key", "bad\r\nx-api-key: other", "bad\x00key", "bad\x7fkey", "bad\x80key" }) |key| {
        request.credential_header = .{ .name = "x-api-key", .value = key };
        try std.testing.expectError(error.InvalidCredentialScope, transport.get(transport.context, a, request));
    }
    const oversized: [513]u8 = @splat('a');
    request.credential_header = .{ .name = "x-api-key", .value = &oversized };
    try std.testing.expectError(error.InvalidCredentialScope, transport.get(transport.context, a, request));
    request.credential_header = .{ .name = "Authorization", .value = scoped_fixture_key };
    try std.testing.expectError(error.InvalidCredentialScope, transport.get(transport.context, a, request));
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}

test "CF transport rejects credential origin leaks and ambiguous numeric routes before HTTP" {
    const a = std.testing.allocator;
    var fixture: ScopedFixture = .{};
    var adapter = try Adapter.initWithOptions(a, std.testing.io, null, 1, .{ .allow_curseforge = true, .fixture_http = ScopedFixture.execute, .fixture_context = &fixture });
    defer adapter.deinit();
    const transport = adapter.providerTransport();
    var request = scopedFixtureRequest();
    for ([_][]const u8{
        "https://api.modrinth.com/v2/search",
        "https://edge.forgecdn.net/files/1/fixture.jar",
        "https://api.curseforge.com.evil.example/v1/mods/1",
        "https://api.curseforge.com:443/v1/mods/1",
        "https://user@api.curseforge.com/v1/mods/1",
        "http://api.curseforge.com/v1/mods/1",
        "https://api.curseforge.com/v1/mods/1#fragment",
        "https://api.curseforge.com/v1/mods",
        "https://api.curseforge.com/v1/mods/0",
        "https://api.curseforge.com/v1/mods/01",
        "https://api.curseforge.com/v1/mods/2147483648",
        "https://api.curseforge.com/v1/mods/%31",
        "https://api.curseforge.com/v1/mods/1%2ffiles/2",
        "https://api.curseforge.com/v1/mods/1/../search",
        "https://api.curseforge.com/v1/mods/1/",
        "https://api.curseforge.com/v1/mods/1/files/",
        "https://api.curseforge.com/v1/mods/1/files/2/extra",
        "https://api.curseforge.com/v1/mods/1/files/2?extra=1",
        "https://api.curseforge.com/v1/mods/1?extra=1",
        "https://api.curseforge.com/v1/mods/1/files/2%5c3",
    }) |url| {
        request.url = url;
        if (transport.get(transport.context, a, request)) |response| {
            a.free(response.body);
            return error.UnsafeUrlAccepted;
        } else |_| {}
    }
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}

test "CF transport enforces redirects bounds and cancellation before HTTP buffering" {
    const a = std.testing.allocator;
    var cancel: CancelToken = .init(false);
    var fixture: ScopedFixture = .{};
    var adapter = try Adapter.initWithOptions(a, std.testing.io, &cancel, 1, .{ .allow_curseforge = true, .fixture_http = ScopedFixture.execute, .fixture_context = &fixture });
    defer adapter.deinit();
    const transport = adapter.providerTransport();
    var request = scopedFixtureRequest();
    request.follow_redirects = true;
    try std.testing.expectError(error.RedirectsDisabled, transport.get(transport.context, a, request));
    request = scopedFixtureRequest();
    request.max_body_bytes = 0;
    try std.testing.expectError(error.InvalidLimit, transport.get(transport.context, a, request));
    request.max_body_bytes = providers.max_json_bytes + 1;
    try std.testing.expectError(error.InvalidLimit, transport.get(transport.context, a, request));
    request = scopedFixtureRequest();
    request.timeout_ms = 0;
    try std.testing.expectError(error.InvalidTimeout, transport.get(transport.context, a, request));
    request.timeout_ms = 120001;
    try std.testing.expectError(error.InvalidTimeout, transport.get(transport.context, a, request));
    request = scopedFixtureRequest();
    cancel.store(true, .release);
    try std.testing.expectError(error.Canceled, transport.get(transport.context, a, request));
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    cancel.store(false, .release);
    request.max_body_bytes = 1;
    fixture.max_bytes = 1;
    try std.testing.expectError(error.ResponseTooLarge, transport.get(transport.context, a, request));
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "provider routes are pinned and request bounds fail closed" {
    const a = std.testing.allocator;
    _ = a;
    for ([_][]const u8{
        "https://api.modrinth.com/v2/search?query=test",
        "https://api.modrinth.com/v2/project/project-id",
        "https://api.modrinth.com/v2/project/project-id/version?loaders=%5B%22fabric%22%5D",
        "https://api.modrinth.com/v2/version/version-id",
    }) |url| try validateProviderRequest(.{ .url = url, .user_agent = user_agent });
    for ([_][]const u8{
        "https://api.curseforge.com/v1/mods",
        "https://api.modrinth.com.evil.example/v2/search",
        "https://api.modrinth.com/v2x/search",
        "https://api.modrinth.com/v2/user/me",
        "https://api.modrinth.com/v2/project/../version",
        "https://api.modrinth.com/v2/project/%2e%2e/version",
        "https://api.modrinth.com:443/v2/search",
        "http://api.modrinth.com/v2/search",
        "https://api.modrinth.com/v2/search#fragment",
    }) |url| {
        if (validateProviderRequest(.{ .url = url, .user_agent = user_agent })) |_| return error.UnsafeUrlAccepted else |_| {}
    }
    const valid: providers.Request = .{ .url = "https://api.modrinth.com/v2/search", .user_agent = user_agent };
    var invalid = valid;
    invalid.follow_redirects = true;
    try std.testing.expectError(error.RedirectsDisabled, validateProviderRequest(invalid));
    invalid = valid;
    invalid.max_body_bytes = providers.max_json_bytes + 1;
    try std.testing.expectError(error.InvalidLimit, validateProviderRequest(invalid));
    invalid = valid;
    invalid.timeout_ms = 0;
    try std.testing.expectError(error.InvalidTimeout, validateProviderRequest(invalid));
}

const Fixture = struct {
    calls: usize = 0,
    status: u16 = 200,
    body: []const u8 = "{}",
    response_allocator: ?Allocator = null,
    cancel_after: ?*CancelToken = null,
    fn execute(context: ?*anyopaque, a: Allocator, _: std.Io, request: http.Request) !http.Response {
        const self: *Fixture = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        try std.testing.expectEqual(http.Method.get, request.method);
        try std.testing.expect(!request.follow_redirects and !request.allow_http_loopback);
        try std.testing.expect(request.body == null);
        try std.testing.expect(request.require_public_address);
        try std.testing.expectEqualStrings(user_agent, request.headers[0].value);
        try std.testing.expectEqualStrings("application/json", request.headers[1].value);
        try std.testing.expect(request.max_response_bytes <= providers.max_json_bytes);
        try std.testing.expect(request.timeout_ms > 0 and request.timeout_ms <= 120_000);
        const owner = self.response_allocator orelse a;
        const body = try owner.dupe(u8, self.body);
        if (self.cancel_after) |cancel| cancel.store(true, .release);
        return .{ .allocator = owner, .status = self.status, .body = body };
    }
};

test "fixture metadata retains ownership cancellation status and bounds" {
    const a = std.testing.allocator;
    var fixture: Fixture = .{};
    var cancel: CancelToken = .init(false);
    var adapter = try Adapter.initWithOptions(a, std.testing.io, &cancel, 4, .{ .fixture_http = Fixture.execute, .fixture_context = &fixture });
    defer adapter.deinit();
    const transport = adapter.providerTransport();
    const request: providers.Request = .{ .url = "https://api.modrinth.com/v2/search", .user_agent = "untrusted caller value" };
    const response = try transport.get(transport.context, a, request);
    defer a.free(response.body);
    try std.testing.expectEqualStrings("{}", response.body);
    fixture.status = 429;
    const limited = try transport.get(transport.context, a, request);
    defer a.free(limited.body);
    try std.testing.expectEqual(@as(u16, 429), limited.status);
    var small = request;
    small.max_body_bytes = 1;
    try std.testing.expectError(error.ResponseTooLarge, transport.get(transport.context, a, small));
    cancel.store(true, .release);
    const calls = fixture.calls;
    try std.testing.expectError(error.Canceled, transport.get(transport.context, a, request));
    try std.testing.expectEqual(calls, fixture.calls);
    try std.testing.expect(adapter.service == null);
}

test "initialization rejects unsafe concurrency and unapproved download targets" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidConcurrency, Adapter.init(a, std.testing.io, null, 0));
    try std.testing.expectError(error.InvalidConcurrency, Adapter.init(a, std.testing.io, null, 65));
    try std.testing.expectError(error.UnsupportedProxyWithPublicAddressGuard, Adapter.initWithOptions(a, std.testing.io, null, 1, .{ .http = .{ .proxy = "https://proxy.example" } }));
    try std.testing.expectError(error.InvalidDownloadHost, Adapter.initWithOptions(a, std.testing.io, null, 1, .{ .approved_download_hosts = &.{"127.0.0.1"} }));
    try std.testing.expectError(error.InvalidDownloadHost, Adapter.initWithOptions(a, std.testing.io, null, 1, .{ .approved_download_hosts = &.{"cdn.modrinth.com/path"} }));
    var adapter = try Adapter.init(a, std.testing.io, null, 64);
    defer adapter.deinit();
    try std.testing.expect(adapter.approvedUrl("https://cdn.modrinth.com/data/file.jar"));
    for ([_][]const u8{
        "https://cdn.modrinth.com.evil.example/file.jar",
        "https://127.0.0.1/file.jar",
        "https://localhost/file.jar",
        "https://cdn.modrinth.com:443/file.jar",
        "https://user@cdn.modrinth.com/file.jar",
        "http://cdn.modrinth.com/file.jar",
        "https://api.curseforge.com/file.jar",
    }) |url| try std.testing.expect(!adapter.approvedUrl(url));
}

test "fetcher rejects unsafe targets and cancellation before staging or HTTP" {
    const a = std.testing.allocator;
    var fixture: Fixture = .{};
    var cancel: CancelToken = .init(false);
    var adapter = try Adapter.initWithOptions(a, std.testing.io, &cancel, 1, .{ .fixture_http = Fixture.execute, .fixture_context = &fixture });
    defer adapter.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fetch = adapter.fetcher();
    var request: install.FetchRequest = .{
        .url = "https://unapproved.example/file.jar",
        .directory = tmp.dir,
        .name = "stage",
        .absolute_path = "/unused-stage",
        .max_bytes = 1024,
        .expected_size = null,
        .expected_sha1 = null,
        .deadline_ns = null,
        .cancel = null,
    };
    try std.testing.expectError(error.UnapprovedDownloadHost, fetch.fetchToFile(fetch.context, std.testing.io, request));
    request.url = "https://cdn.modrinth.com/file.jar";
    request.name = "../escape";
    try std.testing.expectError(error.UnsafePath, fetch.fetchToFile(fetch.context, std.testing.io, request));
    request.name = "stage";
    request.max_bytes = 0;
    try std.testing.expectError(error.InvalidLimit, fetch.fetchToFile(fetch.context, std.testing.io, request));
    request.max_bytes = 1024;
    var request_cancel: CancelToken = .init(true);
    request.cancel = &request_cancel;
    try std.testing.expectError(error.Canceled, fetch.fetchToFile(fetch.context, std.testing.io, request));
    request.cancel = null;
    request.deadline_ns = 0;
    try std.testing.expectError(error.TimedOut, fetch.fetchToFile(fetch.context, std.testing.io, request));
    request.deadline_ns = null;
    cancel.store(true, .release);
    try std.testing.expectError(error.Canceled, fetch.fetchToFile(fetch.context, std.testing.io, request));
    try std.testing.expect(adapter.service == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "stage", .{}));
}

test "fixture response allocator and cancellation after HTTP are independent" {
    const a = std.testing.allocator;
    var cancel: CancelToken = .init(false);
    var fixture: Fixture = .{ .response_allocator = a };
    var adapter = try Adapter.initWithOptions(a, std.testing.io, &cancel, 1, .{ .fixture_http = Fixture.execute, .fixture_context = &fixture });
    defer adapter.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const caller = arena.allocator();
    const transport = adapter.providerTransport();
    const request: providers.Request = .{ .url = "https://api.modrinth.com/v2/search", .user_agent = "ignored" };
    const response = try transport.get(transport.context, caller, request);
    defer caller.free(response.body);
    try std.testing.expectEqualStrings("{}", response.body);
    fixture.body = "second response";
    fixture.cancel_after = &cancel;
    try std.testing.expectError(error.Canceled, transport.get(transport.context, caller, request));
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqualStrings("{}", response.body);
}

const DownloadFixture = struct {
    calls: usize = 0,
    status: u16 = 200,
    body: []const u8 = "fixture bytes",
    response_allocator: ?Allocator = null,
    failure: ?anyerror = null,
    cancel_after: ?*CancelToken = null,
    expected_limit: usize = 64,
    expected_cancel: ?*const CancelToken = null,
    expected_deadline: ?i96 = null,
    fn execute(context: ?*anyopaque, a: Allocator, _: std.Io, request: http.Request) !http.Response {
        const self: *DownloadFixture = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        try std.testing.expectEqual(http.Method.get, request.method);
        try std.testing.expectEqualStrings("https://edge.forgecdn.net/files/0/34/example.jar", request.url);
        try std.testing.expectEqual(@as(usize, 0), request.headers.len);
        try std.testing.expect(request.body == null and !request.sensitive);
        try std.testing.expect(request.require_public_address and !request.follow_redirects and !request.allow_http_loopback);
        try std.testing.expectEqual(self.expected_limit, request.max_response_bytes);
        try std.testing.expectEqual(@as(u32, 120_000), request.timeout_ms);
        try std.testing.expectEqual(self.expected_cancel, request.cancel);
        try std.testing.expectEqual(self.expected_deadline, request.deadline_ns);
        if (self.failure) |failure| return failure;
        const owner = self.response_allocator orelse a;
        const body = try owner.dupe(u8, self.body);
        if (self.cancel_after) |cancel| cancel.store(true, .release);
        return .{ .allocator = owner, .status = self.status, .body = body };
    }
};

fn fixtureDownloadRequest(dir: std.Io.Dir, absolute: []const u8) install.FetchRequest {
    return .{ .url = "https://edge.forgecdn.net/files/0/34/example.jar", .directory = dir, .name = "download.bin", .absolute_path = absolute, .max_bytes = 64, .expected_size = null, .expected_sha1 = null, .deadline_ns = null, .cancel = null };
}

test "explicit fixture CDN fetch is unkeyed bounded verified and never creates a real service" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const absolute = try std.fs.path.join(a, &.{ root, "download.bin" });
    defer a.free(absolute);
    const payload = try a.alloc(u8, 128 * 1024 + 17);
    defer a.free(payload);
    @memset(payload, 0x7b);
    var fixture: DownloadFixture = .{ .body = payload, .expected_limit = payload.len, .response_allocator = std.heap.page_allocator };
    var adapter = try Adapter.initWithOptions(a, io, null, 4, .{ .allow_curseforge = true, .approved_download_hosts = &.{"edge.forgecdn.net"}, .fixture_http = DownloadFixture.execute, .fixture_context = &fixture });
    defer adapter.deinit();
    const fetch = adapter.fetcher();
    var request = fixtureDownloadRequest(tmp.dir, absolute);
    request.max_bytes = payload.len;
    request.expected_size = payload.len;
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(payload, &digest, .{});
    request.expected_sha1 = digest;
    try std.testing.expect(adapter.service == null);
    try fetch.fetchToFile(fetch.context, io, request);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(adapter.service == null);
    const downloaded = try fs.openRegular(tmp.dir, io, "download.bin");
    defer downloaded.close(io);
    try std.testing.expectEqual(@as(u64, @intCast(payload.len)), (try downloaded.stat(io)).size);
    const bytes = try tmp.dir.readFileAlloc(io, "download.bin", a, .limited(payload.len + 1));
    defer a.free(bytes);
    try std.testing.expectEqualSlices(u8, payload, bytes);
    try std.testing.expectError(error.PathAlreadyExists, fetch.fetchToFile(fetch.context, io, request));
    try std.testing.expect(adapter.service == null);
}

test "fixture CDN status size hash and callback failures cannot fall through or leave output" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const absolute = try std.fs.path.join(a, &.{ root, "download.bin" });
    defer a.free(absolute);
    var fixture: DownloadFixture = .{};
    var adapter = try Adapter.initWithOptions(a, io, null, 1, .{ .allow_curseforge = true, .approved_download_hosts = &.{"edge.forgecdn.net"}, .fixture_http = DownloadFixture.execute, .fixture_context = &fixture });
    defer adapter.deinit();
    const fetch = adapter.fetcher();
    const Case = struct { status: u16 = 200, max: usize = 64, size: ?u64 = null, sha1: ?[20]u8 = null, failure: ?anyerror = null, expected: anyerror };
    const cases = [_]Case{
        .{ .status = 99, .expected = error.InvalidHttpStatus },
        .{ .status = 600, .expected = error.InvalidHttpStatus },
        .{ .status = 302, .expected = error.HttpStatus },
        .{ .status = 429, .expected = error.HttpStatus },
        .{ .status = 500, .expected = error.HttpStatus },
        .{ .max = 3, .expected = error.BodyTooLarge },
        .{ .size = 1, .expected = error.SizeMismatch },
        .{ .sha1 = @as([20]u8, @splat(0)), .expected = error.Sha1Mismatch },
        .{ .failure = error.NonPublicAddress, .expected = error.NonPublicAddress },
        .{ .failure = error.OutOfMemory, .expected = error.OutOfMemory },
        .{ .failure = error.Canceled, .expected = error.Canceled },
        .{ .failure = error.TimedOut, .expected = error.TimedOut },
    };
    for (cases, 0..) |case, index| {
        fixture.status = case.status;
        fixture.failure = case.failure;
        fixture.expected_limit = case.max;
        var request = fixtureDownloadRequest(tmp.dir, absolute);
        request.max_bytes = case.max;
        request.expected_size = case.size;
        request.expected_sha1 = case.sha1;
        try std.testing.expectError(case.expected, fetch.fetchToFile(fetch.context, io, request));
        try std.testing.expectEqual(index + 1, fixture.calls);
        try std.testing.expect(adapter.service == null);
        try std.testing.expect((try fs.inspectEntry(tmp.dir, io, "download.bin")) == null);
    }
}

test "fixture CDN policy bounds deadline and cancellation checks run before and after callback" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const absolute = try std.fs.path.join(a, &.{ root, "download.bin" });
    defer a.free(absolute);
    var cancel: CancelToken = .init(false);
    var request_cancel: CancelToken = .init(false);
    var fixture: DownloadFixture = .{ .expected_cancel = &request_cancel };
    var adapter = try Adapter.initWithOptions(a, io, &cancel, 1, .{ .allow_curseforge = true, .approved_download_hosts = &.{"edge.forgecdn.net"}, .fixture_http = DownloadFixture.execute, .fixture_context = &fixture });
    defer adapter.deinit();
    const fetch = adapter.fetcher();
    var request = fixtureDownloadRequest(tmp.dir, absolute);
    request.cancel = &request_cancel;
    request.url = "https://unapproved.example/file.jar";
    try std.testing.expectError(error.UnapprovedDownloadHost, fetch.fetchToFile(fetch.context, io, request));
    request.url = "https://127.0.0.1/file.jar";
    try std.testing.expectError(error.UnapprovedDownloadHost, fetch.fetchToFile(fetch.context, io, request));
    request.url = "https://key@edge.forgecdn.net/file.jar";
    try std.testing.expectError(error.UnapprovedDownloadHost, fetch.fetchToFile(fetch.context, io, request));
    request.url = "https://edge.forgecdn.net/files/0/34/example.jar";
    request.max_bytes = 0;
    try std.testing.expectError(error.InvalidLimit, fetch.fetchToFile(fetch.context, io, request));
    request.max_bytes = 64;
    request.expected_size = 65;
    try std.testing.expectError(error.InvalidLimit, fetch.fetchToFile(fetch.context, io, request));
    request.expected_size = null;
    request.deadline_ns = 0;
    try std.testing.expectError(error.TimedOut, fetch.fetchToFile(fetch.context, io, request));
    request.deadline_ns = null;
    cancel.store(true, .release);
    try std.testing.expectError(error.Canceled, fetch.fetchToFile(fetch.context, io, request));
    cancel.store(false, .release);
    request_cancel.store(true, .release);
    try std.testing.expectError(error.Canceled, fetch.fetchToFile(fetch.context, io, request));
    request_cancel.store(false, .release);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    const deadline = std.math.maxInt(i96);
    request.deadline_ns = deadline;
    fixture.expected_deadline = deadline;
    fixture.cancel_after = &request_cancel;
    try std.testing.expectError(error.Canceled, fetch.fetchToFile(fetch.context, io, request));
    request_cancel.store(false, .release);
    fixture.cancel_after = &cancel;
    try std.testing.expectError(error.Canceled, fetch.fetchToFile(fetch.context, io, request));
    cancel.store(false, .release);
    request.cancel = null;
    fixture.expected_cancel = &cancel;
    try std.testing.expectError(error.Canceled, fetch.fetchToFile(fetch.context, io, request));
    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
    try std.testing.expect(adapter.service == null);
    try std.testing.expect((try fs.inspectEntry(tmp.dir, io, "download.bin")) == null);
}

test "fixture CDN injection cannot authorize disabled keyed CF metadata" {
    const a = std.testing.allocator;
    var fixture: DownloadFixture = .{};
    var adapter = try Adapter.initWithOptions(a, std.testing.io, null, 1, .{ .allow_curseforge = false, .approved_download_hosts = &.{"edge.forgecdn.net"}, .fixture_http = DownloadFixture.execute, .fixture_context = &fixture });
    defer adapter.deinit();
    const metadata = adapter.providerTransport();
    const request: providers.Request = .{ .url = "https://api.curseforge.com/v1/mods/12/files/34", .user_agent = user_agent, .credential_header = .{ .name = "x-api-key", .value = "fixture-key" } };
    try std.testing.expectError(error.ProviderDisabled, metadata.get(metadata.context, a, request));
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expect(adapter.service == null);
}

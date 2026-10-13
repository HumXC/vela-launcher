//! Official free JDK catalog and transactional installer. No UI or execution probe.
//! Azul provenance: https://docs.azul.com/core/install/metadata-api and
//! https://docs.azul.com/core/data/metadata_zulu.json (CA, GA, package detail SHA256).
//! Microsoft provenance: https://learn.microsoft.com/en-us/java/openjdk/download-major-urls
//! documents every major/platform alias and appending .sha256sum.txt. Its checksum
//! filename pins the versioned artifact, avoiding a latest-alias update race.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;

pub const Vendor = enum { azul, microsoft };
pub const Os = enum { linux, windows, macos };
pub const Arch = enum { x64, aarch64 };
pub const Archive = enum { tar_gz, zip };
pub const Platform = struct {
    os: Os,
    arch: Arch,
    pub fn archive(self: Platform) Archive {
        return if (self.os == .windows) .zip else .tar_gz;
    }
};
pub const majors = [_]u8{ 8, 11, 16, 17, 21, 25 };
const microsoft_majors = [_]u8{ 11, 17, 21, 25 };
pub const max_archive_bytes: usize = 1024 * 1024 * 1024;
pub const max_metadata_bytes: usize = 1024 * 1024;
const azul_api = "https://api.azul.com/metadata/v1/zulu/packages/";
const microsoft_base = "https://aka.ms/download-jdk/";

/// Official vendor catalogue majors; used by both validation and the download UI.
pub fn vendorMajors(vendor: Vendor) []const u8 {
    return switch (vendor) {
        .azul => &majors,
        .microsoft => &microsoft_majors,
    };
}

pub fn supported(vendor: Vendor, major: u8) bool {
    for (vendorMajors(vendor)) |m| if (m == major) return true;
    return false;
}

/// All string fields are owned by allocator; do not copy ownership.
pub const RuntimeRelease = struct {
    allocator: Allocator,
    vendor: Vendor,
    major: u8,
    platform: Platform,
    version: []const u8,
    url: []const u8,
    archive: Archive,
    sha256: [32]u8,
    /// Literal catalogue size. Exact unless parseAzul explicitly marks the observed
    /// decimal-kB precision of an official CA package (SHA256 is always mandatory).
    size: ?u64 = null,
    size_precision: enum { exact, azul_rounded_kilobyte } = .exact,

    pub fn acceptsSize(self: *const RuntimeRelease, actual: u64) bool {
        const reported = self.size orelse return true;
        if (self.size_precision == .exact) return actual == reported;
        if (self.vendor != .azul or reported == 0 or reported % 1000 != 0) return false;
        return (actual +| 500) / 1000 == reported / 1000;
    }

    fn downloadLimit(self: *const RuntimeRelease) usize {
        if (self.size) |reported| {
            const upper = if (self.size_precision == .azul_rounded_kilobyte) reported +| 499 else reported;
            return @intCast(@min(max_archive_bytes, upper));
        }
        return max_archive_bytes;
    }

    pub fn deinit(self: *RuntimeRelease) void {
        self.allocator.free(self.version);
        self.allocator.free(self.url);
        self.* = undefined;
    }
};

pub const Phase = enum { metadata, downloading, verifying, extracting, publishing, complete };
pub const Progress = struct { phase: Phase, received: u64 = 0, total: ?u64 = null, bytes_per_second: f64 = 0 };
/// Called on the backend worker, never implicitly on the UI thread.
pub const Hooks = struct {
    context: ?*anyopaque = null,
    canceled: ?*const fn (?*anyopaque) bool = null,
    progress: ?*const fn (?*anyopaque, Progress) void = null,
    pub fn check(self: Hooks) !void {
        if (self.canceled) |f| if (f(self.context)) return error.Canceled;
    }
    fn report(self: Hooks, value: Progress) void {
        if (self.progress) |f| f(self.context, value);
    }
};

/// get must return allocator-owned bytes, enforce limit and HTTP success, honor
/// cancellation and bounded timeouts, and allow HTTPS redirects only. download
/// must finish/close its output before returning and honor the same hooks/limit.
pub const Transport = struct {
    context: *anyopaque,
    get: *const fn (*anyopaque, Allocator, []const u8, usize, Hooks) anyerror![]u8,
    download: *const fn (*anyopaque, Io, *const RuntimeRelease, []const u8, Hooks) anyerror!void,
};

fn getBytes(t: Transport, a: Allocator, url: []const u8, limit: usize, hooks: Hooks) ![]u8 {
    try hooks.check();
    const bytes = try t.get(t.context, a, url, limit, hooks);
    errdefer a.free(bytes);
    if (bytes.len > limit) return error.MetadataTooLarge;
    try hooks.check();
    return bytes;
}

pub fn resolve(a: Allocator, t: Transport, vendor: Vendor, major: u8, platform: Platform, hooks: Hooks) !RuntimeRelease {
    if (!supported(vendor, major)) return error.UnsupportedRelease;
    hooks.report(.{ .phase = .metadata });
    return switch (vendor) {
        .azul => resolveAzul(a, t, major, platform, hooks),
        .microsoft => resolveMicrosoft(a, t, major, platform, hooks),
    };
}

fn extension(archive: Archive) []const u8 {
    return if (archive == .zip) "zip" else "tar.gz";
}
fn osName(os: Os) []const u8 {
    return @tagName(os);
}
fn parseHash(text: []const u8) ![32]u8 {
    if (text.len != 64) return error.InvalidChecksum;
    var digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, text) catch return error.InvalidChecksum;
    return digest;
}
fn string(value: std.json.Value, key: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidMetadata;
    const field = value.object.get(key) orelse return error.InvalidMetadata;
    if (field != .string) return error.InvalidMetadata;
    return field.string;
}
fn integer(value: std.json.Value, key: []const u8) !i64 {
    if (value != .object) return error.InvalidMetadata;
    const field = value.object.get(key) orelse return error.InvalidMetadata;
    if (field != .integer) return error.InvalidMetadata;
    return field.integer;
}
fn matches(value: std.json.Value, key: []const u8, expected: []const u8) bool {
    const s = string(value, key) catch return false;
    return std.mem.eql(u8, s, expected);
}
fn falseField(value: std.json.Value, key: []const u8) bool {
    if (value != .object) return false;
    const field = value.object.get(key) orelse return false;
    return field == .bool and !field.bool;
}
fn javaVersion(value: std.json.Value, major: u8) ![]const std.json.Value {
    if (value != .object) return error.InvalidMetadata;
    const field = value.object.get("java_version") orelse return error.InvalidMetadata;
    if (field != .array or field.array.items.len == 0 or field.array.items.len > 6) return error.InvalidMetadata;
    for (field.array.items) |n| if (n != .integer or n.integer < 0 or n.integer > 65535) return error.InvalidMetadata;
    if (field.array.items[0].integer != major) return error.ReleaseMismatch;
    return field.array.items;
}
fn uuidValid(uuid: []const u8) bool {
    if (uuid.len != 36) return false;
    for (uuid, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn resolveAzul(a: Allocator, t: Transport, major: u8, platform: Platform, hooks: Hooks) !RuntimeRelease {
    const url = try std.fmt.allocPrint(a, "{s}?java_version={d}&os={s}&arch={s}&archive_type={s}&java_package_type=jdk&javafx_bundled=false&crac_supported=false&release_status=ga&availability_types=CA&latest=true&page_size=100", .{
        azul_api, major, if (platform.os == .linux) "linux-glibc" else osName(platform.os), @tagName(platform.arch), extension(platform.archive()),
    });
    defer a.free(url);
    const bytes = try getBytes(t, a, url, max_metadata_bytes, hooks);
    defer a.free(bytes);
    var list = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer list.deinit();
    if (list.value != .array) return error.InvalidMetadata;
    if (list.value.array.items.len == 0) return error.ReleaseUnavailable;
    if (list.value.array.items.len > 100) return error.InvalidMetadata;
    for (list.value.array.items) |item| {
        if (!matches(item, "availability_type", "CA") or !matches(item, "product", "zulu")) continue;
        _ = javaVersion(item, major) catch continue;
        const uuid = try string(item, "package_uuid");
        if (!uuidValid(uuid)) return error.InvalidMetadata;
        const detail_url = try std.fmt.allocPrint(a, "{s}{s}", .{ azul_api, uuid });
        defer a.free(detail_url);
        const detail = try getBytes(t, a, detail_url, max_metadata_bytes, hooks);
        defer a.free(detail);
        var release = parseAzul(a, detail, major, platform) catch |err| switch (err) {
            error.ReleaseMismatch => continue,
            else => return err,
        };
        errdefer release.deinit();
        if (!std.mem.eql(u8, release.url, try string(item, "download_url"))) return error.ReleaseMismatch;
        return release;
    }
    return error.ReleaseUnavailable;
}

pub fn parseAzul(a: Allocator, bytes: []const u8, major: u8, platform: Platform) !RuntimeRelease {
    if (!supported(.azul, major)) return error.UnsupportedRelease;
    if (bytes.len > max_metadata_bytes) return error.MetadataTooLarge;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer parsed.deinit();
    const v = parsed.value;
    const versions = try javaVersion(v, major);
    if (!matches(v, "product", "zulu") or !matches(v, "availability_type", "CA") or
        !matches(v, "java_package_type", "jdk") or !matches(v, "release_status", "ga") or
        !matches(v, "os", osName(platform.os)) or !matches(v, "archive_type", extension(platform.archive())) or
        !matches(v, "arch", if (platform.arch == .x64) "x86" else "arm") or
        try integer(v, "hw_bitness") != 64 or !falseField(v, "javafx_bundled") or !falseField(v, "crac_supported") or
        (platform.os == .linux and !matches(v, "lib_c_type", "glibc"))) return error.ReleaseMismatch;
    const download_url = try string(v, "download_url");
    if (!std.mem.startsWith(u8, download_url, "https://cdn.azul.com/zulu/bin/")) return error.InvalidArtifactUrl;
    const name = try string(v, "name");
    if (!safeComponent(name) or !std.mem.eql(u8, download_url["https://cdn.azul.com/zulu/bin/".len..], name)) return error.InvalidArtifactUrl;
    const sha256 = try parseHash(try string(v, "sha256_hash"));
    const size = try integer(v, "size");
    if (size <= 0 or size > max_archive_bytes) return error.InvalidArchiveSize;
    var version: std.Io.Writer.Allocating = .init(a);
    defer version.deinit();
    for (versions, 0..) |n, i| {
        if (i != 0) version.writer.writeByte('.') catch return error.OutOfMemory;
        version.writer.print("{d}", .{n.integer}) catch return error.OutOfMemory;
    }
    const version_owned = try a.dupe(u8, version.written());
    errdefer a.free(version_owned);
    // Observed official CA package details report 213089000 for 213089356 bytes,
    // and 106675000 for 106674581 bytes. The API schema only says integer, with
    // no precision contract. Keep the literal size and restrict compatibility to
    // its nearest decimal-kB bucket; mandatory SHA256 still pins the exact bytes.
    return .{ .allocator = a, .vendor = .azul, .major = major, .platform = platform, .version = version_owned, .url = try a.dupe(u8, download_url), .archive = platform.archive(), .sha256 = sha256, .size = @intCast(size), .size_precision = if (@mod(size, 1000) == 0) .azul_rounded_kilobyte else .exact };
}

fn resolveMicrosoft(a: Allocator, t: Transport, major: u8, platform: Platform, hooks: Hooks) !RuntimeRelease {
    const alias = try std.fmt.allocPrint(a, "{s}microsoft-jdk-{d}-{s}-{s}.{s}.sha256sum.txt", .{
        microsoft_base, major, if (platform.os == .macos) "macOS" else osName(platform.os), @tagName(platform.arch), extension(platform.archive()),
    });
    defer a.free(alias);
    const bytes = try getBytes(t, a, alias, 4096, hooks);
    defer a.free(bytes);
    return parseMicrosoft(a, bytes, major, platform);
}

pub fn parseMicrosoft(a: Allocator, bytes: []const u8, major: u8, platform: Platform) !RuntimeRelease {
    if (!supported(.microsoft, major)) return error.UnsupportedRelease;
    if (bytes.len > 4096) return error.MetadataTooLarge;
    var tokens = std.mem.tokenizeAny(u8, bytes, " \t\r\n");
    const digest = try parseHash(tokens.next() orelse return error.InvalidChecksum);
    var filename = tokens.next() orelse return error.InvalidChecksum;
    if (tokens.next() != null) return error.InvalidChecksum;
    if (filename.len != 0 and filename[0] == '*') filename = filename[1..];
    if (!safeComponent(filename) or !std.mem.startsWith(u8, filename, "microsoft-jdk-")) return error.InvalidArtifactUrl;
    const rest = filename["microsoft-jdk-".len..];
    const end = std.mem.indexOfScalar(u8, rest, '-') orelse return error.InvalidMetadata;
    const version = rest[0..end];
    var nums = std.mem.splitScalar(u8, version, '.');
    const first = nums.next() orelse return error.InvalidMetadata;
    if ((std.fmt.parseInt(u8, first, 10) catch return error.InvalidMetadata) != major) return error.ReleaseMismatch;
    var count: usize = 1;
    while (nums.next()) |part| {
        if (part.len == 0) return error.InvalidMetadata;
        for (part) |c| if (!std.ascii.isDigit(c)) return error.InvalidMetadata;
        _ = std.fmt.parseInt(u16, part, 10) catch return error.InvalidMetadata;
        count += 1;
    }
    if (count < 3 or count > 4) return error.InvalidMetadata;
    const suffix = try std.fmt.allocPrint(a, "-{s}-{s}.{s}", .{ osName(platform.os), @tagName(platform.arch), extension(platform.archive()) });
    defer a.free(suffix);
    // Microsoft historically uses macOS in aliases and macos in pinned files.
    if (!std.ascii.eqlIgnoreCase(rest[end..], suffix)) return error.ReleaseMismatch;
    const version_owned = try a.dupe(u8, version);
    errdefer a.free(version_owned);
    return .{ .allocator = a, .vendor = .microsoft, .major = major, .platform = platform, .version = version_owned, .url = try std.fmt.allocPrint(a, "{s}{s}", .{ microsoft_base, filename }), .archive = platform.archive(), .sha256 = digest };
}

fn safeComponent(s: []const u8) bool {
    if (s.len == 0 or s.len > 300 or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_') return false;
    return true;
}
fn relativePath(s: []const u8) bool {
    if (s.len == 0 or s.len > 4096) return false;
    var parts = std.mem.splitScalar(u8, s, '/');
    while (parts.next()) |part| if (!safeComponent(part)) return false;
    return true;
}

/// REQUIRED secure archive integration. Destination is a newly created private
/// empty directory. Callback must reject absolute/traversal/drive/UNC paths,
/// duplicate/conflicting entries, devices and escaping symlinks/hardlinks;
/// enforce expanded byte/entry limits, preserve POSIX executable permissions,
/// and observe hooks.check throughout extraction. Never execute archive contents.
/// Normalize the JDK layout into destination and return allocator-owned relative
/// path ending bin/java (bin/java.exe on Windows), including Contents/Home on mac.
/// Return only after all files are closed; failed/canceled output is discarded.
/// Callback may not mutate anything outside destination, including the archive.
pub const Extractor = struct {
    context: *anyopaque,
    extract: *const fn (*anyopaque, Allocator, Io, Archive, []const u8, []const u8, Hooks) anyerror![]u8,
};
pub const Installed = struct {
    allocator: Allocator,
    directory: []const u8,
    java_path: []const u8,
    /// Publication proves archive integrity, not actual Java identity or launchability.
    status: enum { installed_unverified, usable, unusable } = .installed_unverified,
    pub fn deinit(self: *Installed) void {
        self.allocator.free(self.directory);
        self.allocator.free(self.java_path);
        self.* = undefined;
    }
};

/// jdks_root must be the caller's absolute .vela/jdks path. Probe/registration is
/// separate and may fail on NixOS; a probe failure is not download failure.
/// Success linearizes at atomic non-replacing rename. Cancellation arriving
/// after that commit does not turn a published installation into a failure.
pub fn install(a: Allocator, io: Io, t: Transport, release: *const RuntimeRelease, jdks_root: []const u8, extractor: Extractor, hooks: Hooks) !Installed {
    try hooks.check();
    if (!std.fs.path.isAbsolute(jdks_root)) return error.RootMustBeAbsolute;
    if (!supported(release.vendor, release.major) or release.archive != release.platform.archive()) return error.ReleaseMismatch;
    if (release.size) |size| if (size == 0 or size > max_archive_bytes) return error.InvalidArchiveSize;
    if (!std.mem.startsWith(u8, release.url, if (release.vendor == .azul) "https://cdn.azul.com/zulu/bin/" else microsoft_base)) return error.InvalidArtifactUrl;
    const root = try Dir.cwd().createDirPathOpen(io, jdks_root, .{});
    defer root.close(io);
    var random: [16]u8 = undefined;
    io.random(&random);
    const stage_name = try std.fmt.allocPrint(a, ".stage-{s}", .{std.fmt.bytesToHex(&random, .lower)});
    defer a.free(stage_name);
    const permissions: Io.File.Permissions = if (@import("builtin").os.tag == .windows) .default_dir else .fromMode(0o700);
    try root.createDir(io, stage_name, permissions);
    defer {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        root.deleteTree(io, stage_name) catch |err| std.log.warn("JDK staging cleanup failed: {s}", .{@errorName(err)});
    }
    const stage = try root.openDir(io, stage_name, .{});
    defer stage.close(io);
    try stage.createDir(io, "runtime", .default_dir);
    const archive_path = try std.fs.path.join(a, &.{ jdks_root, stage_name, "archive" });
    defer a.free(archive_path);
    const runtime_path = try std.fs.path.join(a, &.{ jdks_root, stage_name, "runtime" });
    defer a.free(runtime_path);
    hooks.report(.{ .phase = .downloading, .total = release.size });
    try t.download(t.context, io, release, archive_path, hooks);
    try hooks.check();
    hooks.report(.{ .phase = .verifying, .total = release.size });
    try verify(io, archive_path, release, hooks);
    hooks.report(.{ .phase = .extracting });
    const java_relative = try extractor.extract(extractor.context, a, io, release.archive, archive_path, runtime_path, hooks);
    defer a.free(java_relative);
    try hooks.check();
    const expected = if (release.platform.os == .windows) "bin/java.exe" else "bin/java";
    if (!relativePath(java_relative) or !(std.mem.eql(u8, java_relative, expected) or
        (std.mem.endsWith(u8, java_relative, expected) and java_relative[java_relative.len - expected.len - 1] == '/'))) return error.InvalidJavaPath;
    const runtime = try stage.openDir(io, "runtime", .{});
    defer runtime.close(io);
    // The secure callback rejects escaping parent links; require java itself to
    // be a regular non-symlink file, without trying to execute downloaded code.
    const stat = try runtime.statFile(io, java_relative, .{ .follow_symlinks = false });
    if (stat.kind != .file or stat.size == 0) return error.InvalidJavaExecutable;
    if (@import("builtin").os.tag != .windows and stat.permissions.toMode() & 0o111 == 0)
        return error.InvalidJavaExecutable;
    const manifest = try std.json.Stringify.valueAlloc(a, .{
        .schema = @as(u8, 1),
        .vendor = @tagName(release.vendor),
        .major = release.major,
        .version = release.version,
        .os = @tagName(release.platform.os),
        .arch = @tagName(release.platform.arch),
        .url = release.url,
        .sha256 = std.fmt.bytesToHex(&release.sha256, .lower),
        .java = java_relative,
    }, .{});
    defer a.free(manifest);
    const file = try runtime.createFile(io, ".vela-runtime.json", .{ .exclusive = true });
    {
        defer file.close(io);
        try file.writeStreamingAll(io, manifest);
        try file.sync(io);
    }
    const final_name = try std.fmt.allocPrint(a, "{s}-{d}-{s}-{s}-{s}", .{
        @tagName(release.vendor), release.major, @tagName(release.platform.os), @tagName(release.platform.arch), std.fmt.bytesToHex(&release.sha256, .lower),
    });
    defer a.free(final_name);
    const directory = try std.fs.path.join(a, &.{ jdks_root, final_name });
    errdefer a.free(directory);
    const java_path = try std.fs.path.join(a, &.{ directory, java_relative });
    errdefer a.free(java_path);
    hooks.report(.{ .phase = .publishing });
    try hooks.check();
    try stage.renamePreserve("runtime", root, final_name, io);
    hooks.report(.{ .phase = .complete });
    return .{ .allocator = a, .directory = directory, .java_path = java_path };
}

fn verify(io: Io, path: []const u8, release: *const RuntimeRelease, hooks: Hooks) !void {
    const file = try Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size == 0 or stat.size > max_archive_bytes) return error.InvalidArchiveSize;
    if (!release.acceptsSize(stat.size)) return error.ArchiveSizeMismatch;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var count: u64 = 0;
    while (true) {
        try hooks.check();
        const n = file.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        count += n;
        if (count > max_archive_bytes) return error.InvalidArchiveSize;
        hash.update(buffer[0..n]);
        hooks.report(.{ .phase = .verifying, .received = count, .total = stat.size });
    }
    if (count != stat.size) return error.ArchiveSizeMismatch;
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    if (!std.mem.eql(u8, &digest, &release.sha256)) return error.Sha256Mismatch;
    try hooks.check();
}

/// Adapter for current downloader.Service. Kept generic so fixture tests do not
/// require curl, and Service API changes are checked by the integrating caller.
/// Keep this adapter alive until every resolve/install call finishes; do not
/// destroy Service concurrently. Its allocator and Io must be thread-safe.
pub fn ServiceTransport(comptime Service: type) type {
    return struct {
        service: *Service,
        io: Io,
        const Self = @This();
        pub fn transport(self: *Self) Transport {
            return .{ .context = self, .get = get, .download = download };
        }
        fn wait(self: *Self, task: anytype, hooks: Hooks, phase: Phase) !void {
            var canceled = false;
            while (true) {
                hooks.check() catch {
                    canceled = true;
                    task.cancel();
                };
                const snapshot = task.snapshot();
                // Forward the terminal measurement before releasing this child task.
                // Keep the backend phase: archive verification owns completion/failure.
                hooks.report(.{ .phase = phase, .received = snapshot.progress.received, .total = snapshot.progress.total, .bytes_per_second = if (!canceled and phase == .downloading and snapshot.progress.phase == .downloading) snapshot.progress.bytes_per_second else 0 });
                switch (snapshot.progress.phase) {
                    .complete => {
                        if (canceled) return error.Canceled;
                        return;
                    },
                    .failed, .canceled => return if (canceled) error.Canceled else snapshot.failure orelse error.DownloadFailed,
                    else => {},
                }
                // Drain accepted task cancellation before release, even when Io
                // itself was canceled. No live Task or Service borrower escapes.
                self.io.sleep(.fromMilliseconds(5), .awake) catch {
                    canceled = true;
                    task.cancel();
                    const protection = self.io.swapCancelProtection(.blocked);
                    self.io.sleep(.fromMilliseconds(5), .awake) catch {};
                    _ = self.io.swapCancelProtection(protection);
                };
            }
        }
        fn get(context: *anyopaque, a: Allocator, url: []const u8, limit: usize, hooks: Hooks) ![]u8 {
            const self: *Self = @ptrCast(@alignCast(context));
            try hooks.check();
            const task = try self.service.submit(.{ .url = url, .output = .bytes, .max_bytes = limit, .timeout_ms = 30_000, .https_only = true });
            defer task.release() catch unreachable;
            try self.wait(task, hooks, .metadata);
            try hooks.check();
            const result = task.snapshot().result orelse return error.DownloadFailed;
            return switch (result) {
                .bytes => |bytes| a.dupe(u8, bytes),
                else => error.InvalidTransportResult,
            };
        }
        fn download(context: *anyopaque, io: Io, release: *const RuntimeRelease, path: []const u8, hooks: Hooks) !void {
            _ = io;
            const self: *Self = @ptrCast(@alignCast(context));
            try hooks.check();
            const task = try self.service.submit(.{ .url = release.url, .output = .{ .file = path }, .expected_size = if (release.size_precision == .exact) release.size else null, .max_bytes = release.downloadLimit(), .timeout_ms = 600_000, .https_only = true });
            defer task.release() catch unreachable;
            try self.wait(task, hooks, .downloading);
            try hooks.check();
        }
    };
}

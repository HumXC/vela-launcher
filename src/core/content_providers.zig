const std = @import("std");
const config = @import("config.zig");

// Official schema provenance (no requests in tests):
// https://docs.modrinth.com/api/operations/searchprojects/
// https://docs.modrinth.com/api/operations/getprojectversions/
// https://docs.modrinth.com/api/operations/getversion/
// https://docs.curseforge.com/rest-api/ (File, HashAlgo, FileRelationType)
pub const Provider = config.SourceKind;
pub const max_json_bytes = 4 * 1024 * 1024;
pub const max_items = 4096;
pub const max_string_bytes = 4096;
pub const max_file_bytes: u64 = 16 * 1024 * 1024 * 1024;

pub fn Owned(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,
        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

pub const Compatibility = struct {
    minecraft_version: []const u8,
    loader: config.Loader,
};
pub const Hashes = struct { sha1: ?[]const u8 = null, sha256: ?[]const u8 = null, sha512: ?[]const u8 = null };
pub const ManualReason = enum { distribution_disabled, missing_url, unavailable, provider_disabled };
pub const ManualRequired = struct { official_page: []const u8, reason: ManualReason };
pub const Download = union(enum) { remote: []const u8, manual_required: ManualRequired };
pub const File = struct {
    filename: []const u8,
    hashes: Hashes,
    size: ?u64 = null,
    primary: bool = false,
    download: Download,
    /// In-memory proof from authorized official metadata, never a receipt permission.
    authorization: ?RemoteAuthorization = null,
};

pub const RemotePolicy = struct {
    enabled: bool = false,
    approved_download_hosts: []const []const u8 = &.{},
};
pub const RemoteAuthorization = struct {
    project_id: []const u8,
    file_id: []const u8,
    filename: []const u8,
    url: []const u8,
    sha1: []const u8,
    size: u64,
    official_page: []const u8,
    distribution_allowed: bool,
    available: bool,
    approved_download_hosts: []const []const u8,
};
pub fn approvedDownloadUrl(url: []const u8, hosts: []const []const u8) bool {
    if (!safeHttpsUrl(url)) return false;
    const uri = std.Uri.parse(url) catch return false;
    const host = (uri.host orelse return false).percent_encoded;
    for (hosts) |approved| if (std.ascii.eqlIgnoreCase(host, approved)) return true;
    return false;
}
fn sameHostSnapshot(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!std.ascii.eqlIgnoreCase(left, right)) return false;
    return true;
}
pub fn validateRemoteAuthorization(provider: Provider, project_id: []const u8, file_id: []const u8, file: File, policy: RemotePolicy) !void {
    if (!policy.enabled) return error.ProviderDisabled;
    if (provider != .curseforge or file.download != .remote) return error.InvalidRemoteAuthorization;
    const proof = file.authorization orelse return error.MissingRemoteAuthorization;
    try curseForgeId(project_id);
    try curseForgeId(file_id);
    if (!proof.distribution_allowed or !proof.available or !officialCurseForgePage(proof.official_page)) return error.InvalidRemoteAuthorization;
    if (!std.mem.eql(u8, proof.project_id, project_id) or !std.mem.eql(u8, proof.file_id, file_id) or
        !std.mem.eql(u8, proof.filename, file.filename) or !std.mem.eql(u8, proof.url, file.download.remote) or
        file.size == null or proof.size != file.size.? or proof.size == 0 or proof.size > max_file_bytes or
        file.hashes.sha1 == null or !std.mem.eql(u8, proof.sha1, file.hashes.sha1.?) or file.hashes.sha256 != null or file.hashes.sha512 != null or
        !sameHostSnapshot(proof.approved_download_hosts, policy.approved_download_hosts)) return error.InvalidRemoteAuthorization;
    if (!config.validId(file.filename)) return error.UnsafeFilename;
    try validateHashes(file.hashes);
    if (!approvedDownloadUrl(proof.url, policy.approved_download_hosts)) return error.UnapprovedDownloadHost;
}
fn authorizeFiles(result: *Owned(VersionSet), project_value: Project, policy: RemotePolicy) !void {
    const a = result.arena.allocator();
    if (policy.approved_download_hosts.len == 0 or policy.approved_download_hosts.len > 64) return error.UnapprovedDownloadHost;
    const hosts = try a.alloc([]const u8, policy.approved_download_hosts.len);
    for (policy.approved_download_hosts, hosts) |host, *out| {
        if (host.len == 0 or host.len > 253) return error.UnapprovedDownloadHost;
        out.* = try a.dupe(u8, host);
    }
    for (@constCast(result.value.versions)) |*version_value| {
        for (@constCast(version_value.files)) |*file| {
            if (file.download != .remote) continue;
            const sha1 = file.hashes.sha1 orelse return error.MissingHash;
            const size = file.size orelse return error.MissingFileSize;
            if (size == 0 or size > max_file_bytes) return error.InvalidFileSize;
            const proof: RemoteAuthorization = .{
                .project_id = try a.dupe(u8, version_value.project_id),
                .file_id = try a.dupe(u8, version_value.id),
                .filename = try a.dupe(u8, file.filename),
                .url = try a.dupe(u8, file.download.remote),
                .sha1 = try a.dupe(u8, sha1),
                .size = size,
                .official_page = try a.dupe(u8, project_value.official_page),
                .distribution_allowed = project_value.distribution_allowed,
                .available = true, // Only available files acquire a remote tag in the parser.
                .approved_download_hosts = hosts,
            };
            var candidate = file.*;
            candidate.authorization = proof;
            try validateRemoteAuthorization(version_value.provider, version_value.project_id, version_value.id, candidate, policy);
            file.authorization = proof;
        }
    }
}

pub const DependencyKind = enum { required, optional, incompatible, embedded };
pub const Dependency = struct {
    kind: DependencyKind,
    project_id: ?[]const u8 = null,
    version_id: ?[]const u8 = null,
    file_name: ?[]const u8 = null,
};
pub const Project = struct {
    provider: Provider,
    id: []const u8,
    name: []const u8,
    summary: []const u8 = "",
    official_page: []const u8,
    distribution_allowed: bool = false,
};
pub const Catalog = struct { projects: []const Project, total: u64 };
pub const Version = struct {
    provider: Provider,
    project_id: []const u8,
    id: []const u8,
    name: []const u8,
    minecraft_versions: []const []const u8,
    loaders: []const []const u8,
    files: []const File,
    dependencies: []const Dependency,
};
pub const VersionSet = struct { versions: []const Version };

/// Shared bounded structured-JSON accessors. Missing/type-invalid fields fail closed.
pub const Json = struct {
    pub fn parse(a: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
        if (bytes.len > max_json_bytes) return error.ResponseTooLarge;
        return std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always, .max_value_len = max_string_bytes });
    }
    pub fn field(v: std.json.Value, key: []const u8) !std.json.Value {
        if (v != .object) return error.InvalidResponse;
        return v.object.get(key) orelse error.MissingField;
    }
    pub fn optional(v: std.json.Value, key: []const u8) !?std.json.Value {
        if (v != .object) return error.InvalidResponse;
        const value = v.object.get(key) orelse return null;
        return if (value == .null) null else value;
    }
    pub fn string(v: std.json.Value) ![]const u8 {
        if (v != .string or v.string.len > max_string_bytes or !std.unicode.utf8ValidateSlice(v.string)) return error.InvalidString;
        return v.string;
    }
    pub fn text(v: std.json.Value, key: []const u8) ![]const u8 {
        return string(try field(v, key));
    }
    pub fn optText(v: std.json.Value, key: []const u8) !?[]const u8 {
        return if (try optional(v, key)) |item| try string(item) else null;
    }
    pub fn unsigned(v: std.json.Value) !u64 {
        if (v != .integer or v.integer < 0) return error.InvalidNumber;
        return @intCast(v.integer);
    }
    pub fn number(v: std.json.Value, key: []const u8) !u64 {
        return unsigned(try field(v, key));
    }
    pub fn boolean(v: std.json.Value) !bool {
        if (v != .bool) return error.InvalidResponse;
        return v.bool;
    }
    pub fn array(v: std.json.Value) ![]const std.json.Value {
        if (v != .array) return error.InvalidResponse;
        if (v.array.items.len > max_items) return error.TooManyItems;
        return v.array.items;
    }
    pub fn strings(a: std.mem.Allocator, v: std.json.Value) ![]const []const u8 {
        const items = try array(v);
        const result = try a.alloc([]const u8, items.len);
        for (items, result) |item, *out| out.* = try string(item);
        return result;
    }
};

pub fn validToken(s: []const u8) bool {
    if (s.len == 0 or s.len > 128) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    return !std.mem.eql(u8, s, ".") and !std.mem.eql(u8, s, "..");
}
fn token(s: []const u8) ![]const u8 {
    if (!validToken(s)) return error.InvalidId;
    return s;
}
fn numericId(a: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    const n = try Json.unsigned(v);
    if (n == 0 or n > std.math.maxInt(i32)) return error.InvalidId;
    return std.fmt.allocPrint(a, "{d}", .{n});
}
pub fn validHash(s: []const u8, len: usize) bool {
    if (s.len != len) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}
pub fn validateHashes(h: Hashes) !void {
    if (h.sha1 == null and h.sha256 == null and h.sha512 == null) return error.MissingHash;
    if (h.sha256) |s| if (!validHash(s, 64)) return error.InvalidHash;
    if (h.sha1) |s| if (!validHash(s, 40)) return error.InvalidHash;
    if (h.sha512) |s| if (!validHash(s, 128)) return error.InvalidHash;
}
pub fn parseHashes(v: std.json.Value) !Hashes {
    const h: Hashes = .{ .sha1 = try Json.optText(v, "sha1"), .sha256 = try Json.optText(v, "sha256"), .sha512 = try Json.optText(v, "sha512") };
    try validateHashes(h);
    return h;
}
pub fn hashesMatch(expected: Hashes, actual: Hashes) bool {
    validateHashes(expected) catch return false;
    validateHashes(actual) catch return false;
    if (expected.sha256) |e| if (!std.ascii.eqlIgnoreCase(e, actual.sha256 orelse return false)) return false;
    if (expected.sha1) |e| if (!std.ascii.eqlIgnoreCase(e, actual.sha1 orelse return false)) return false;
    if (expected.sha512) |e| if (!std.ascii.eqlIgnoreCase(e, actual.sha512 orelse return false)) return false;
    return true;
}
pub fn verifyBytes(bytes: []const u8, hashes: Hashes, size: ?u64) !void {
    try validateHashes(hashes);
    if (size) |s| if (s != bytes.len) return error.SizeMismatch;
    if (hashes.sha1) |expected| {
        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        if (!std.ascii.eqlIgnoreCase(expected, &hex)) return error.HashMismatch;
    }
    if (hashes.sha256) |expected| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        if (!std.ascii.eqlIgnoreCase(expected, &hex)) return error.HashMismatch;
    }
    if (hashes.sha512) |expected| {
        var digest: [64]u8 = undefined;
        std.crypto.hash.sha2.Sha512.hash(bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        if (!std.ascii.eqlIgnoreCase(expected, &hex)) return error.HashMismatch;
    }
}

/// Lexical check only. The future executor must also reject private resolved IPs,
/// symlink traversal and redirects; this module never opens a download URL.
pub fn safeHttpsUrl(url: []const u8) bool {
    if (url.len > max_string_bytes or !std.mem.startsWith(u8, url, "https://")) return false;
    for (url, 0..) |c, i| {
        if (c <= 32 or c >= 127 or std.mem.indexOfScalar(u8, "\\\"<>`{}|^[]", c) != null) return false;
        if (c == '%' and (i + 2 >= url.len or !std.ascii.isHex(url[i + 1]) or !std.ascii.isHex(url[i + 2]))) return false;
    }
    const uri = std.Uri.parse(url) catch return false;
    if (uri.user != null or uri.password != null or uri.port != null or uri.fragment != null) return false;
    const host = if (uri.host) |h| h.percent_encoded else return false;
    if (host.len == 0 or std.mem.indexOfScalar(u8, host, '.') == null or std.mem.endsWith(u8, host, ".local") or std.mem.endsWith(u8, host, ".localhost")) return false;
    var all_numeric = true;
    for (host) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '.') return false;
        if (!std.ascii.isDigit(c) and c != '.') all_numeric = false;
    }
    return !all_numeric;
}
pub fn officialCurseForgePage(url: []const u8) bool {
    if (!safeHttpsUrl(url)) return false;
    if (!std.mem.startsWith(u8, url, "https://www.curseforge.com/minecraft/")) return false;
    if (std.mem.indexOfAny(u8, url, "?#%") != null or std.mem.endsWith(u8, url, "/")) return false;
    var parts = std.mem.splitScalar(u8, url["https://www.curseforge.com/minecraft/".len..], '/');
    const category = parts.next() orelse return false;
    if (!std.mem.eql(u8, category, "mc-mods") and !std.mem.eql(u8, category, "modpacks") and !std.mem.eql(u8, category, "texture-packs") and !std.mem.eql(u8, category, "shaders")) return false;
    if (!validToken(parts.next() orelse return false)) return false;
    return parts.next() == null;
}
pub fn compatible(v: Version, filter: Compatibility) bool {
    const loader = if (filter.loader == .vanilla) "minecraft" else @tagName(filter.loader);
    return contains(v.minecraft_versions, filter.minecraft_version) and contains(v.loaders, loader);
}
fn contains(items: []const []const u8, text: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, text)) return true;
    return false;
}

fn modrinthProject(a: std.mem.Allocator, v: std.json.Value, search: bool) !Project {
    const id = try token(try Json.text(v, if (search) "project_id" else "id"));
    const kind = try token(try Json.text(v, "project_type"));
    if (!contains(&.{ "mod", "modpack", "resourcepack", "shader", "datapack", "plugin" }, kind)) return error.UnsupportedProjectType;
    return .{ .provider = .modrinth, .id = id, .name = try Json.text(v, "title"), .summary = try Json.text(v, "description"), .official_page = try std.fmt.allocPrint(a, "https://modrinth.com/{s}/{s}", .{ kind, id }), .distribution_allowed = true };
}
pub fn parseModrinthCatalog(a: std.mem.Allocator, bytes: []const u8, search: bool) !Owned(Catalog) {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();
    const parsed = try Json.parse(aa, bytes);
    const items = if (search) try Json.array(try Json.field(parsed.value, "hits")) else &.{parsed.value};
    const projects = try aa.alloc(Project, items.len);
    for (items, projects) |v, *p| p.* = try modrinthProject(aa, v, search);
    try uniqueProjects(projects);
    const value: Catalog = .{ .projects = projects, .total = if (search) try Json.number(parsed.value, "total_hits") else 1 };
    return .{ .arena = arena, .value = value };
}
fn modrinthVersion(a: std.mem.Allocator, v: std.json.Value) !Version {
    const raw_files = try Json.array(try Json.field(v, "files"));
    if (raw_files.len == 0) return error.MissingFiles;
    const files = try a.alloc(File, raw_files.len);
    var primary_count: usize = 0;
    for (raw_files, files) |f, *out| {
        const filename = try Json.text(f, "filename");
        if (!config.validId(filename)) return error.UnsafeFilename;
        const url = try Json.text(f, "url");
        if (!safeHttpsUrl(url)) return error.UnsafeUrl;
        const size = if (try Json.optional(f, "size")) |s| try Json.unsigned(s) else null;
        if (size) |s| if (s > max_file_bytes) return error.FileTooLarge;
        const primary = try Json.boolean(try Json.field(f, "primary"));
        if (primary) primary_count += 1;
        out.* = .{ .filename = filename, .hashes = try parseHashes(try Json.field(f, "hashes")), .size = size, .primary = primary, .download = .{ .remote = url } };
    }
    if (primary_count > 1) return error.AmbiguousPrimaryFile;
    if (primary_count == 0) files[0].primary = true;
    try uniqueFiles(files);
    const raw_deps = try Json.array(try Json.field(v, "dependencies"));
    const deps = try a.alloc(Dependency, raw_deps.len);
    for (raw_deps, deps) |d, *out| {
        const kind = std.meta.stringToEnum(DependencyKind, try Json.text(d, "dependency_type")) orelse return error.UnsupportedDependency;
        const pid = try Json.optText(d, "project_id");
        const vid = try Json.optText(d, "version_id");
        const filename = try Json.optText(d, "file_name");
        if (pid) |s| _ = try token(s);
        if (vid) |s| _ = try token(s);
        if (filename) |s| if (!config.validId(s)) return error.UnsafeFilename;
        out.* = .{ .kind = kind, .project_id = pid, .version_id = vid, .file_name = filename };
    }
    return .{ .provider = .modrinth, .project_id = try token(try Json.text(v, "project_id")), .id = try token(try Json.text(v, "id")), .name = try Json.text(v, "name"), .minecraft_versions = try Json.strings(a, try Json.field(v, "game_versions")), .loaders = try Json.strings(a, try Json.field(v, "loaders")), .files = files, .dependencies = deps };
}
pub fn parseModrinthVersions(a: std.mem.Allocator, bytes: []const u8, single: bool, filter: ?Compatibility) !Owned(VersionSet) {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();
    const parsed = try Json.parse(aa, bytes);
    const items = if (single) &.{parsed.value} else try Json.array(parsed.value);
    var versions: std.ArrayList(Version) = .empty;
    for (items) |v| {
        const version = try modrinthVersion(aa, v);
        if (filter) |f| if (!compatible(version, f)) continue;
        try versions.append(aa, version);
    }
    try uniqueVersions(versions.items);
    const value: VersionSet = .{ .versions = try versions.toOwnedSlice(aa) };
    return .{ .arena = arena, .value = value };
}
fn uniqueProjects(projects: []const Project) !void {
    for (projects, 0..) |p, i| for (projects[0..i]) |other| if (std.mem.eql(u8, p.id, other.id)) return error.DuplicateId;
}
fn uniqueVersions(versions: []const Version) !void {
    for (versions, 0..) |v, i| for (versions[0..i]) |other| if (v.provider == other.provider and std.mem.eql(u8, v.id, other.id)) return error.DuplicateId;
}
fn uniqueFiles(files: []const File) !void {
    for (files, 0..) |f, i| for (files[0..i]) |other| if (std.ascii.eqlIgnoreCase(f.filename, other.filename)) return error.PathCollision;
}

fn curseforgeProject(a: std.mem.Allocator, v: std.json.Value) !Project {
    const page = try Json.text(try Json.field(v, "links"), "websiteUrl");
    if (!officialCurseForgePage(page)) return error.UnsafeOfficialPage;
    return .{ .provider = .curseforge, .id = try numericId(a, try Json.field(v, "id")), .name = try Json.text(v, "name"), .summary = try Json.text(v, "summary"), .official_page = page, .distribution_allowed = if (try Json.optional(v, "allowModDistribution")) |allowed| try Json.boolean(allowed) else false };
}
/// Bounded metadata parser; never performs transport or handles credentials.
pub fn parseCurseForgeCatalog(a: std.mem.Allocator, bytes: []const u8, single: bool) !Owned(Catalog) {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();
    const parsed = try Json.parse(aa, bytes);
    const data = try Json.field(parsed.value, "data");
    const items = if (single) &.{data} else try Json.array(data);
    const projects = try aa.alloc(Project, items.len);
    for (items, projects) |v, *p| p.* = try curseforgeProject(aa, v);
    try uniqueProjects(projects);
    const value: Catalog = .{ .projects = projects, .total = if (single) 1 else try Json.number(try Json.field(parsed.value, "pagination"), "totalCount") };
    return .{ .arena = arena, .value = value };
}
fn cfDependency(a: std.mem.Allocator, d: std.json.Value) !Dependency {
    const relation = try Json.number(d, "relationType");
    const kind: DependencyKind = switch (relation) {
        1 => .embedded,
        2 => .optional,
        3 => .required,
        5 => .incompatible,
        else => return error.UnsupportedDependency,
    };
    return .{ .kind = kind, .project_id = try numericId(a, try Json.field(d, "modId")) };
}
fn curseforgeVersion(a: std.mem.Allocator, v: std.json.Value, project: Project, allow_remote: bool) !Version {
    if (project.provider != .curseforge or !officialCurseForgePage(project.official_page)) return error.InvalidProject;
    const pid = try numericId(a, try Json.field(v, "modId"));
    if (!std.mem.eql(u8, pid, project.id)) return error.ProjectMismatch;
    const id = try numericId(a, try Json.field(v, "id"));
    const filename = try Json.text(v, "fileName");
    if (!config.validId(filename)) return error.UnsafeFilename;
    var hashes: Hashes = .{};
    for (try Json.array(try Json.field(v, "hashes"))) |h| {
        switch (try Json.number(h, "algo")) {
            1 => {
                if (hashes.sha1 != null) return error.DuplicateHash;
                hashes.sha1 = try Json.text(h, "value");
            },
            2 => {}, // Official HashAlgo 2 is MD5, NOT SHA512.
            else => return error.UnsupportedHash,
        }
    }
    try validateHashes(hashes);
    const size = if (try Json.optional(v, "fileLength")) |s| try Json.unsigned(s) else null;
    if (size) |s| if (s > max_file_bytes) return error.FileTooLarge;
    const available = try Json.boolean(try Json.field(v, "isAvailable"));
    const url = try Json.optText(v, "downloadUrl");
    const reason: ManualReason = if (!project.distribution_allowed) .distribution_disabled else if (!available) .unavailable else if (url == null or url.?.len == 0) .missing_url else .provider_disabled;
    const files = try a.alloc(File, 1);
    const download: Download = if (allow_remote and project.distribution_allowed and available and url != null and url.?.len != 0) remote: {
        if (!safeHttpsUrl(url.?)) return error.UnsafeDownloadUrl;
        break :remote .{ .remote = url.? };
    } else .{ .manual_required = .{ .official_page = try std.fmt.allocPrint(a, "{s}/files/{s}", .{ project.official_page, id }), .reason = reason } };
    files[0] = .{ .filename = filename, .hashes = hashes, .size = size, .primary = true, .download = download };
    const raw_deps = try Json.array(try Json.field(v, "dependencies"));
    const deps = try a.alloc(Dependency, raw_deps.len);
    for (raw_deps, deps) |d, *out| out.* = try cfDependency(a, d);
    const game_versions = try Json.strings(a, try Json.field(v, "gameVersions"));
    var loaders: std.ArrayList([]const u8) = .empty;
    for (game_versions) |s| {
        const loader: ?[]const u8 = if (std.mem.eql(u8, s, "Fabric")) "fabric" else if (std.mem.eql(u8, s, "Forge")) "forge" else if (std.mem.eql(u8, s, "NeoForge")) "neoforge" else if (std.mem.eql(u8, s, "Quilt")) "quilt" else null;
        if (loader) |l| if (!contains(loaders.items, l)) try loaders.append(a, l);
    }
    if (loaders.items.len == 0 and (std.mem.indexOf(u8, project.official_page, "/texture-packs/") != null or std.mem.indexOf(u8, project.official_page, "/shaders/") != null)) try loaders.append(a, "minecraft");
    return .{ .provider = .curseforge, .project_id = pid, .id = id, .name = try Json.text(v, "displayName"), .minecraft_versions = game_versions, .loaders = try loaders.toOwnedSlice(a), .files = files, .dependencies = deps };
}
pub fn parseCurseForgeVersions(a: std.mem.Allocator, bytes: []const u8, single: bool, project: Project, filter: ?Compatibility) !Owned(VersionSet) {
    return parseCurseForgeVersionsMode(a, bytes, single, project, filter, false);
}
fn parseCurseForgeVersionsMode(a: std.mem.Allocator, bytes: []const u8, single: bool, project: Project, filter: ?Compatibility, allow_remote: bool) !Owned(VersionSet) {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();
    const parsed = try Json.parse(aa, bytes);
    const data = try Json.field(parsed.value, "data");
    const items = if (single) &.{data} else try Json.array(data);
    var versions: std.ArrayList(Version) = .empty;
    for (items) |v| {
        const version = try curseforgeVersion(aa, v, project, allow_remote);
        if (filter) |f| if (!compatible(version, f)) continue;
        try versions.append(aa, version);
    }
    try uniqueVersions(versions.items);
    const value: VersionSet = .{ .versions = try versions.toOwnedSlice(aa) };
    return .{ .arena = arena, .value = value };
}

pub const Request = struct {
    url: []const u8,
    user_agent: []const u8,
    max_body_bytes: usize = max_json_bytes,
    timeout_ms: u32 = 15000,
    follow_redirects: bool = false,
    /// Borrowed for this request only; adapters must not log, persist, or forward it.
    credential_header: ?CredentialHeader = null,
};
pub const Response = struct { status: u16, body: []u8 };
pub const RequestObserver = struct {
    context: ?*anyopaque,
    /// Called once immediately before each actual HTTP attempt; errors prevent transport.
    before_request: *const fn (?*anyopaque) anyerror!void,
};
pub const Transport = struct {
    context: ?*anyopaque,
    /// Return allocator-owned body; enforce bounds before buffering. No redirects.
    get: *const fn (?*anyopaque, std.mem.Allocator, Request) anyerror!Response,
};
pub const Client = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    user_agent: []const u8,
    timeout_ms: u32 = 15000,
    fn fetch(self: Client, path: []const u8) ![]u8 {
        if (self.user_agent.len == 0 or self.user_agent.len > 256 or self.timeout_ms == 0 or self.timeout_ms > 120000) return error.InvalidTransportOptions;
        for (self.user_agent) |c| if (c < 32 or c > 126) return error.InvalidTransportOptions;
        const url = try std.mem.concat(self.allocator, u8, &.{ "https://api.modrinth.com/v2", path });
        defer self.allocator.free(url);
        const response = try self.transport.get(self.transport.context, self.allocator, .{ .url = url, .user_agent = self.user_agent, .timeout_ms = self.timeout_ms });
        errdefer self.allocator.free(response.body);
        if (response.body.len > max_json_bytes) return error.ResponseTooLarge;
        if (response.status == 429) return error.RateLimited;
        if (response.status != 200) return error.HttpFailure;
        return response.body;
    }
    pub fn search(self: Client, query: []const u8, kind: []const u8, filter: Compatibility, offset: u32, limit: u16) !Owned(Catalog) {
        if (limit == 0 or limit > 100 or query.len > 512 or !std.unicode.utf8ValidateSlice(query) or !contains(&.{ "mod", "modpack", "resourcepack", "shader", "datapack", "plugin" }, kind)) return error.InvalidQuery;
        _ = try token(filter.minecraft_version);
        const loader = if (filter.loader == .vanilla) "minecraft" else @tagName(filter.loader);
        const type_facet = try std.fmt.allocPrint(self.allocator, "project_type:{s}", .{kind});
        defer self.allocator.free(type_facet);
        const game_facet = try std.fmt.allocPrint(self.allocator, "versions:{s}", .{filter.minecraft_version});
        defer self.allocator.free(game_facet);
        const loader_facet = try std.fmt.allocPrint(self.allocator, "categories:{s}", .{loader});
        defer self.allocator.free(loader_facet);
        const facets = try std.json.Stringify.valueAlloc(self.allocator, .{ .{type_facet}, .{game_facet}, .{loader_facet} }, .{});
        defer self.allocator.free(facets);
        const encoded = try encode(self.allocator, facets);
        defer self.allocator.free(encoded);
        const q = try encode(self.allocator, query);
        defer self.allocator.free(q);
        const path = try std.fmt.allocPrint(self.allocator, "/search?query={s}&facets={s}&offset={d}&limit={d}", .{ q, encoded, offset, limit });
        defer self.allocator.free(path);
        const bytes = try self.fetch(path);
        defer self.allocator.free(bytes);
        return parseModrinthCatalog(self.allocator, bytes, true);
    }
    pub fn project(self: Client, id: []const u8) !Owned(Catalog) {
        _ = try token(id);
        const path = try std.fmt.allocPrint(self.allocator, "/project/{s}", .{id});
        defer self.allocator.free(path);
        const bytes = try self.fetch(path);
        defer self.allocator.free(bytes);
        var result = try parseModrinthCatalog(self.allocator, bytes, false);
        errdefer result.deinit();
        if (result.value.projects.len != 1 or !std.mem.eql(u8, result.value.projects[0].id, id)) return error.ProjectMismatch;
        return result;
    }
    pub fn versions(self: Client, id: []const u8, filter: Compatibility) !Owned(VersionSet) {
        _ = try token(id);
        _ = try token(filter.minecraft_version);
        const loaders = try std.json.Stringify.valueAlloc(self.allocator, .{if (filter.loader == .vanilla) "minecraft" else @tagName(filter.loader)}, .{});
        defer self.allocator.free(loaders);
        const games = try std.json.Stringify.valueAlloc(self.allocator, .{filter.minecraft_version}, .{});
        defer self.allocator.free(games);
        const el = try encode(self.allocator, loaders);
        defer self.allocator.free(el);
        const eg = try encode(self.allocator, games);
        defer self.allocator.free(eg);
        const path = try std.fmt.allocPrint(self.allocator, "/project/{s}/version?loaders={s}&game_versions={s}&include_changelog=false", .{ id, el, eg });
        defer self.allocator.free(path);
        const bytes = try self.fetch(path);
        defer self.allocator.free(bytes);
        var result = try parseModrinthVersions(self.allocator, bytes, false, filter);
        errdefer result.deinit();
        for (result.value.versions) |v| if (!std.mem.eql(u8, v.project_id, id)) return error.ProjectMismatch;
        return result;
    }
    pub fn version(self: Client, id: []const u8, filter: Compatibility) !Owned(VersionSet) {
        _ = try token(id);
        const path = try std.fmt.allocPrint(self.allocator, "/version/{s}", .{id});
        defer self.allocator.free(path);
        const bytes = try self.fetch(path);
        defer self.allocator.free(bytes);
        var result = try parseModrinthVersions(self.allocator, bytes, true, filter);
        errdefer result.deinit();
        if (result.value.versions.len != 1 or !std.mem.eql(u8, result.value.versions[0].id, id)) return error.VersionMismatch;
        return result;
    }
    /// Legacy Modrinth client is never authorized for CurseForge requests.
    pub fn curseForge(_: Client) !void {
        return error.ProviderDisabled;
    }
};
pub const CredentialHeader = struct { name: []const u8, value: []const u8 };
pub const CurseForgeOptions = struct {
    enabled: bool = false,
    api_key: ?[]const u8 = null,
    terms_approved: bool = false,
};
pub const curseforge_api_origin = "https://api.curseforge.com";
pub const curseforge_api_base = curseforge_api_origin ++ "/v1";

fn validCurseForgeKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 512) return false;
    for (key) |c| if (c < 33 or c > 126) return false;
    return true;
}
/// Adapters must enforce this again before emitting any credential header.
pub fn credentialScopeAllowed(request: Request) bool {
    const header = request.credential_header orelse return true;
    return std.mem.eql(u8, header.name, "x-api-key") and validCurseForgeKey(header.value) and
        !request.follow_redirects and safeHttpsUrl(request.url) and
        std.mem.startsWith(u8, request.url, curseforge_api_base ++ "/");
}
fn curseForgeId(id: []const u8) !void {
    if (id.len == 0 or id.len > 10 or id[0] == '0') return error.InvalidId;
    for (id) |c| if (!std.ascii.isDigit(c)) return error.InvalidId;
    const value = std.fmt.parseInt(u32, id, 10) catch return error.InvalidId;
    if (value > std.math.maxInt(i32)) return error.InvalidId;
}
fn curseForgeClass(kind: []const u8) !u32 {
    if (std.mem.eql(u8, kind, "mod")) return 6;
    if (std.mem.eql(u8, kind, "modpack")) return 4471;
    if (std.mem.eql(u8, kind, "resourcepack")) return 12;
    if (std.mem.eql(u8, kind, "shader")) return 6552;
    return error.InvalidQuery;
}
fn curseForgeLoader(loader: config.Loader) u8 {
    return switch (loader) {
        .vanilla => 0,
        .forge => 1,
        .fabric => 4,
        .quilt => 5,
        .neoforge => 6,
    };
}
fn curseForgeProjectMetadata(v: std.json.Value, expected_class: ?u32) !void {
    if (try Json.number(v, "gameId") != 432) return error.GameMismatch;
    const class = try Json.number(v, "classId");
    if (expected_class) |expected| {
        if (class != expected) return error.ProjectTypeMismatch;
    } else if (class != 6 and class != 4471 and class != 12 and class != 6552) return error.UnsupportedProjectType;
}
fn curseForgePagination(v: std.json.Value, count: usize, index: u32, page_size: u16) !u64 {
    const pagination = try Json.field(v, "pagination");
    const total = try Json.number(pagination, "totalCount");
    if (try Json.number(pagination, "index") != index or try Json.number(pagination, "pageSize") != page_size or
        try Json.number(pagination, "resultCount") != count or count > page_size or
        (count != 0 and @as(u64, index) + count > total)) return error.InvalidPagination;
    return total;
}

/// No transport is authorized until all three independent opt-in gates pass.
/// Credentials and user-agent are borrowed for the lifetime of each synchronous request.
pub const CurseForgeClient = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    user_agent: []const u8,
    timeout_ms: u32 = 15000,
    options: CurseForgeOptions = .{},
    request_observer: ?RequestObserver = null,

    fn authorize(self: CurseForgeClient) ![]const u8 {
        if (!self.options.enabled or !self.options.terms_approved) return error.ProviderDisabled;
        const key = self.options.api_key orelse return error.ProviderDisabled;
        if (key.len == 0) return error.ProviderDisabled;
        if (!validCurseForgeKey(key)) return error.InvalidCredential;
        if (self.user_agent.len == 0 or self.user_agent.len > 256 or self.timeout_ms == 0 or self.timeout_ms > 120000) return error.InvalidTransportOptions;
        for (self.user_agent) |c| if (c < 32 or c > 126) return error.InvalidTransportOptions;
        return key;
    }
    fn fetch(self: CurseForgeClient, path: []const u8) ![]u8 {
        const key = try self.authorize();
        const url = try std.mem.concat(self.allocator, u8, &.{ curseforge_api_base, path });
        defer self.allocator.free(url);
        const request: Request = .{ .url = url, .user_agent = self.user_agent, .timeout_ms = self.timeout_ms, .credential_header = .{ .name = "x-api-key", .value = key } };
        if (!credentialScopeAllowed(request)) return error.InvalidCredentialScope;
        if (self.request_observer) |observer| try observer.before_request(observer.context);
        const response = try self.transport.get(self.transport.context, self.allocator, request);
        errdefer self.allocator.free(response.body);
        if (response.body.len > max_json_bytes) return error.ResponseTooLarge;
        if (response.status == 401 or response.status == 403) return error.InvalidApiKey;
        if (response.status == 429) return error.RateLimited;
        if (response.status >= 300 and response.status < 400) return error.RedirectRejected;
        if (response.status != 200) return error.HttpFailure;
        return response.body;
    }
    pub fn search(self: CurseForgeClient, query: []const u8, kind: []const u8, filter: Compatibility, offset: u32, limit: u16) !Owned(Catalog) {
        _ = try self.authorize();
        if (limit == 0 or limit > 50 or offset > 10000 - @as(u32, limit) or query.len > 512 or !std.unicode.utf8ValidateSlice(query)) return error.InvalidQuery;
        const class = try curseForgeClass(kind);
        _ = try token(filter.minecraft_version);
        const q = try encode(self.allocator, query);
        defer self.allocator.free(q);
        const path = try std.fmt.allocPrint(self.allocator, "/mods/search?gameId=432&classId={d}&gameVersion={s}&modLoaderType={d}&searchFilter={s}&index={d}&pageSize={d}", .{ class, filter.minecraft_version, curseForgeLoader(filter.loader), q, offset, limit });
        defer self.allocator.free(path);
        const bytes = try self.fetch(path);
        defer self.allocator.free(bytes);
        const parsed = try Json.parse(self.allocator, bytes);
        defer parsed.deinit();
        const items = try Json.array(try Json.field(parsed.value, "data"));
        _ = try curseForgePagination(parsed.value, items.len, offset, limit);
        for (items) |item| try curseForgeProjectMetadata(item, class);
        return parseCurseForgeCatalog(self.allocator, bytes, false);
    }
    pub fn project(self: CurseForgeClient, id: []const u8) !Owned(Catalog) {
        return self.projectMode(id, null);
    }
    fn projectMode(self: CurseForgeClient, id: []const u8, expected_class: ?u32) !Owned(Catalog) {
        _ = try self.authorize();
        try curseForgeId(id);
        const path = try std.fmt.allocPrint(self.allocator, "/mods/{s}", .{id});
        defer self.allocator.free(path);
        const bytes = try self.fetch(path);
        defer self.allocator.free(bytes);
        const parsed = try Json.parse(self.allocator, bytes);
        defer parsed.deinit();
        try curseForgeProjectMetadata(try Json.field(parsed.value, "data"), expected_class);
        var result = try parseCurseForgeCatalog(self.allocator, bytes, true);
        errdefer result.deinit();
        if (result.value.projects.len != 1 or !std.mem.eql(u8, result.value.projects[0].id, id)) return error.ProjectMismatch;
        return result;
    }
    fn validateProject(project_value: Project) !void {
        if (project_value.provider != .curseforge or !officialCurseForgePage(project_value.official_page)) return error.InvalidProject;
        try curseForgeId(project_value.id);
    }
    pub fn manualVersions(self: CurseForgeClient, project_value: Project, filter: Compatibility) !Owned(VersionSet) {
        return self.versionsMode(project_value, filter, false, false);
    }
    pub fn versions(self: CurseForgeClient, project_value: Project, filter: Compatibility) !Owned(VersionSet) {
        return self.versionsMode(project_value, filter, true, false);
    }
    pub fn manualModpackCandidates(self: CurseForgeClient, project_value: Project, minecraft_version: []const u8) !Owned(VersionSet) {
        try validateModpackProject(project_value);
        _ = try token(minecraft_version);
        var fresh = try self.projectMode(project_value.id, 4471);
        defer fresh.deinit();
        if (!std.mem.eql(u8, fresh.value.projects[0].official_page, project_value.official_page)) return error.ProjectMismatch;
        return self.versionsMode(fresh.value.projects[0], .{ .minecraft_version = minecraft_version, .loader = .vanilla }, false, true);
    }
    pub fn authorizedModpackCandidates(self: CurseForgeClient, project_id: []const u8, minecraft_version: []const u8, policy: RemotePolicy) !Owned(VersionSet) {
        if (!policy.enabled) return error.ProviderDisabled;
        _ = try token(minecraft_version);
        var fresh = try self.projectMode(project_id, 4471);
        defer fresh.deinit();
        var result = try self.versionsMode(fresh.value.projects[0], .{ .minecraft_version = minecraft_version, .loader = .vanilla }, true, true);
        errdefer result.deinit();
        try authorizeFiles(&result, fresh.value.projects[0], policy);
        return result;
    }
    fn validateModpackProject(project_value: Project) !void {
        try validateProject(project_value);
        const uri = try std.Uri.parse(project_value.official_page);
        if (!std.mem.startsWith(u8, uri.path.percent_encoded, "/minecraft/modpacks/")) return error.ProjectTypeMismatch;
    }
    fn versionsMode(self: CurseForgeClient, project_value: Project, filter: Compatibility, allow_remote: bool, modpack_candidates: bool) !Owned(VersionSet) {
        _ = try self.authorize();
        try validateProject(project_value);
        _ = try token(filter.minecraft_version);
        if (modpack_candidates) try validateModpackProject(project_value);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();
        var versions_list: std.ArrayList(Version) = .empty;
        var index: u32 = 0;
        var expected_total: ?u64 = null;
        var total_bytes: usize = 0;
        while (true) {
            const path = if (modpack_candidates)
                try std.fmt.allocPrint(self.allocator, "/mods/{s}/files?gameVersion={s}&index={d}&pageSize=50", .{ project_value.id, filter.minecraft_version, index })
            else
                try std.fmt.allocPrint(self.allocator, "/mods/{s}/files?gameVersion={s}&modLoaderType={d}&index={d}&pageSize=50", .{ project_value.id, filter.minecraft_version, curseForgeLoader(filter.loader), index });
            defer self.allocator.free(path);
            const bytes = try self.fetch(path);
            defer self.allocator.free(bytes);
            total_bytes += bytes.len;
            if (total_bytes > max_json_bytes) return error.ResponseTooLarge;
            const parsed = try Json.parse(aa, bytes);
            const items = try Json.array(try Json.field(parsed.value, "data"));
            const total = try curseForgePagination(parsed.value, items.len, index, 50);
            if (total > max_items) return error.TooManyItems;
            if (expected_total) |expected| if (total != expected) return error.InvalidPagination;
            expected_total = total;
            for (items) |item| {
                if (try Json.number(item, "gameId") != 432) return error.GameMismatch;
                const version_value = try curseforgeVersion(aa, item, project_value, allow_remote);
                const accepted = if (modpack_candidates) contains(version_value.minecraft_versions, filter.minecraft_version) else compatible(version_value, filter);
                if (accepted) try versions_list.append(aa, version_value);
            }
            index += @intCast(items.len);
            if (index >= total) break;
            if (items.len == 0) return error.InvalidPagination;
        }
        try uniqueVersions(versions_list.items);
        return .{ .arena = arena, .value = .{ .versions = try versions_list.toOwnedSlice(aa) } };
    }
    pub fn manualVersion(self: CurseForgeClient, project_value: Project, id: []const u8, filter: ?Compatibility) !Owned(VersionSet) {
        return self.versionMode(project_value, id, filter, false);
    }
    pub fn version(self: CurseForgeClient, project_value: Project, id: []const u8, filter: ?Compatibility) !Owned(VersionSet) {
        return self.versionMode(project_value, id, filter, true);
    }
    fn versionMode(self: CurseForgeClient, project_value: Project, id: []const u8, filter: ?Compatibility, allow_remote: bool) !Owned(VersionSet) {
        _ = try self.authorize();
        try validateProject(project_value);
        try curseForgeId(id);
        if (filter) |f| _ = try token(f.minecraft_version);
        const path = try std.fmt.allocPrint(self.allocator, "/mods/{s}/files/{s}", .{ project_value.id, id });
        defer self.allocator.free(path);
        const bytes = try self.fetch(path);
        defer self.allocator.free(bytes);
        const parsed = try Json.parse(self.allocator, bytes);
        defer parsed.deinit();
        if (try Json.number(try Json.field(parsed.value, "data"), "gameId") != 432) return error.GameMismatch;
        var result = try parseCurseForgeVersionsMode(self.allocator, bytes, true, project_value, null, allow_remote);
        errdefer result.deinit();
        if (result.value.versions.len != 1 or !std.mem.eql(u8, result.value.versions[0].id, id)) return error.VersionMismatch;
        if (filter) |f| if (!compatible(result.value.versions[0], f)) return error.IncompatibleVersion;
        return result;
    }
    pub fn authorizedVersions(self: CurseForgeClient, project_id: []const u8, filter: Compatibility, policy: RemotePolicy) !Owned(VersionSet) {
        if (!policy.enabled) return error.ProviderDisabled;
        var fresh = try self.project(project_id);
        defer fresh.deinit();
        var result = try self.versions(fresh.value.projects[0], filter);
        errdefer result.deinit();
        try authorizeFiles(&result, fresh.value.projects[0], policy);
        return result;
    }
    pub fn authorizedVersion(self: CurseForgeClient, project_id: []const u8, file_id: []const u8, filter: ?Compatibility, policy: RemotePolicy) !Owned(VersionSet) {
        if (!policy.enabled) return error.ProviderDisabled;
        try curseForgeId(file_id);
        var fresh = try self.project(project_id);
        defer fresh.deinit();
        var result = try self.version(fresh.value.projects[0], file_id, filter);
        errdefer result.deinit();
        try authorizeFiles(&result, fresh.value.projects[0], policy);
        return result;
    }
};

fn encode(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') try result.append(a, c) else {
            try result.appendSlice(a, &.{ '%', "0123456789ABCDEF"[c >> 4], "0123456789ABCDEF"[c & 15] });
        }
    }
    return result.toOwnedSlice(a);
}

pub const VersionKey = struct { provider: Provider, id: []const u8 };
pub const DependencyChoice = struct {
    from: VersionKey,
    dependency_index: usize,
    include: bool,
    version_id: ?[]const u8 = null,
};
pub const IssueKind = enum { optional_choice, ambiguous_version, required_unknown, incompatible, embedded_external };
pub const DependencyIssue = struct { from_index: usize, dependency_index: usize, kind: IssueKind };
pub const DependencyPlan = struct {
    /// Indices into the input catalog, in dependency-first order. No borrowed pointers.
    indices: []const usize,
    issues: []const DependencyIssue,
    ready: bool,
};

pub fn planDependencies(a: std.mem.Allocator, versions: []const Version, roots: []const VersionKey, filter: Compatibility, choices: []const DependencyChoice) !Owned(DependencyPlan) {
    if (versions.len > max_items or roots.len > max_items or choices.len > max_items) return error.TooManyItems;
    try uniqueVersions(versions);
    for (versions) |v| {
        _ = try token(v.id);
        _ = try token(v.project_id);
        if (v.dependencies.len > max_items) return error.TooManyItems;
    }
    for (choices, 0..) |choice, i| {
        const vi = findVersion(versions, choice.from) orelse return error.InvalidChoice;
        if (choice.dependency_index >= versions[vi].dependencies.len) return error.InvalidChoice;
        const dep = versions[vi].dependencies[choice.dependency_index];
        if (dep.kind == .incompatible or dep.kind == .embedded or (!choice.include and dep.kind == .required)) return error.InvalidChoice;
        if (choice.version_id) |id| _ = try token(id);
        for (choices[0..i]) |other| if (choice.from.provider == other.from.provider and std.mem.eql(u8, choice.from.id, other.from.id) and choice.dependency_index == other.dependency_index) return error.DuplicateChoice;
    }
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();
    const colors = try aa.alloc(u8, versions.len);
    @memset(colors, 0);
    var resolver: Resolver = .{ .a = aa, .versions = versions, .filter = filter, .choices = choices, .colors = colors };
    for (roots) |root| try resolver.visit(findVersion(versions, root) orelse return error.UnknownRequiredVersion, 0);
    for (resolver.indices.items) |vi| for (versions[vi].dependencies, 0..) |dep, di| {
        if (dep.kind != .incompatible) continue;
        for (resolver.indices.items) |candidate| if (matches(versions[candidate], versions[vi].provider, dep)) {
            try resolver.issues.append(aa, .{ .from_index = vi, .dependency_index = di, .kind = .incompatible });
            break;
        };
    };
    const indices = try resolver.indices.toOwnedSlice(aa);
    const issues = try resolver.issues.toOwnedSlice(aa);
    const value: DependencyPlan = .{ .indices = indices, .issues = issues, .ready = issues.len == 0 };
    return .{ .arena = arena, .value = value };
}
fn findVersion(versions: []const Version, key: VersionKey) ?usize {
    for (versions, 0..) |v, i| if (v.provider == key.provider and std.mem.eql(u8, v.id, key.id)) return i;
    return null;
}
fn matches(v: Version, provider: Provider, dep: Dependency) bool {
    if (v.provider != provider) return false;
    if (dep.project_id) |id| if (!std.mem.eql(u8, v.project_id, id)) return false;
    if (dep.version_id) |id| if (!std.mem.eql(u8, v.id, id)) return false;
    return dep.project_id != null or dep.version_id != null;
}
const Resolver = struct {
    a: std.mem.Allocator,
    versions: []const Version,
    filter: Compatibility,
    choices: []const DependencyChoice,
    colors: []u8,
    indices: std.ArrayList(usize) = .empty,
    issues: std.ArrayList(DependencyIssue) = .empty,
    fn visit(self: *Resolver, vi: usize, depth: usize) anyerror!void {
        if (depth > 256) return error.DependencyDepth;
        if (self.colors[vi] == 1) return error.DependencyCycle;
        if (self.colors[vi] == 2) return;
        const version = self.versions[vi];
        if (!compatible(version, self.filter)) return error.IncompatibleVersion;
        self.colors[vi] = 1;
        for (version.dependencies, 0..) |dep, di| {
            if (dep.kind == .incompatible) continue;
            if (dep.kind == .embedded) {
                // Embedded dependencies ship inside the parent, not as another jar.
                if (dep.project_id == null and dep.version_id == null and dep.file_name == null) try self.issues.append(self.a, .{ .from_index = vi, .dependency_index = di, .kind = .embedded_external });
                continue;
            }
            var choice: ?DependencyChoice = null;
            for (self.choices) |c| if (c.from.provider == version.provider and std.mem.eql(u8, c.from.id, version.id) and c.dependency_index == di) {
                choice = c;
                break;
            };
            if (dep.kind == .optional and choice == null) {
                try self.issues.append(self.a, .{ .from_index = vi, .dependency_index = di, .kind = .optional_choice });
                continue;
            }
            if (choice) |c| if (!c.include) continue;
            var candidate: ?usize = null;
            var count: usize = 0;
            for (self.versions, 0..) |v, i| {
                if (!matches(v, version.provider, dep) or !compatible(v, self.filter)) continue;
                if (choice) |c| if (c.version_id) |id| if (!std.mem.eql(u8, id, v.id)) continue;
                candidate = i;
                count += 1;
            }
            if (count != 1) {
                try self.issues.append(self.a, .{ .from_index = vi, .dependency_index = di, .kind = if (count == 0) .required_unknown else .ambiguous_version });
                continue;
            }
            try self.visit(candidate.?, depth + 1);
        }
        // Two distinct versions of the same project cannot be silently co-installed.
        for (self.indices.items) |other| if (self.versions[other].provider == version.provider and std.mem.eql(u8, self.versions[other].project_id, version.project_id)) return error.ProjectVersionConflict;
        self.colors[vi] = 2;
        try self.indices.append(self.a, vi);
    }
};

const testing = std.testing;
const test_hash = "0000000000000000000000000000000000000000";
const test_filter: Compatibility = .{ .minecraft_version = "1.20.1", .loader = .fabric };
const mr_version_fixture =
    \\{"id":"V1","project_id":"P1","name":"v1","game_versions":["1.20.1"],"loaders":["fabric"],"dependencies":[{"dependency_type":"optional","project_id":"P2","version_id":null,"file_name":null}],"files":[{"filename":"mod.jar","primary":true,"url":"https://cdn.modrinth.com/data/P1/V1/mod.jar","hashes":{"sha1":"0000000000000000000000000000000000000000"},"size":3}]}
;
const cf_catalog_fixture =
    \\{"data":[{"id":12,"name":"Example","summary":"fixture","links":{"websiteUrl":"https://www.curseforge.com/minecraft/mc-mods/example"},"allowModDistribution":false}],"pagination":{"totalCount":1}}
;
const cf_version_fixture =
    \\{"data":[{"id":34,"modId":12,"displayName":"Example 1","fileName":"example.jar","isAvailable":true,"downloadUrl":null,"fileLength":3,"hashes":[{"algo":1,"value":"0000000000000000000000000000000000000000"},{"algo":2,"value":"md5-ignored"}],"gameVersions":["1.20.1","Fabric"],"dependencies":[{"modId":42,"relationType":3}]}]}
;
fn exerciseParsers(a: std.mem.Allocator) !void {
    var mr = try parseModrinthVersions(a, mr_version_fixture, true, test_filter);
    defer mr.deinit();
    var cf = try parseCurseForgeCatalog(a, cf_catalog_fixture, false);
    defer cf.deinit();
    var versions = try parseCurseForgeVersions(a, cf_version_fixture, false, cf.value.projects[0], test_filter);
    defer versions.deinit();
}
test "owned version strings compatibility hashes and CurseForge restriction" {
    const input = try testing.allocator.dupe(u8, mr_version_fixture);
    defer testing.allocator.free(input);
    var mr = try parseModrinthVersions(testing.allocator, input, true, test_filter);
    defer mr.deinit();
    @memset(input, 'x');
    try testing.expectEqualStrings("V1", mr.value.versions[0].id);
    try testing.expect(compatible(mr.value.versions[0], test_filter));
    try testing.expect(!compatible(mr.value.versions[0], .{ .minecraft_version = "1.20.1", .loader = .forge }));
    var cf = try parseCurseForgeCatalog(testing.allocator, cf_catalog_fixture, false);
    defer cf.deinit();
    var versions = try parseCurseForgeVersions(testing.allocator, cf_version_fixture, false, cf.value.projects[0], test_filter);
    defer versions.deinit();
    const file = versions.value.versions[0].files[0];
    try testing.expectEqual(ManualReason.distribution_disabled, file.download.manual_required.reason);
    try testing.expectEqualStrings("https://www.curseforge.com/minecraft/mc-mods/example/files/34", file.download.manual_required.official_page);
    try testing.expectEqualStrings(test_hash, file.hashes.sha1.?);
    try testing.expect(file.hashes.sha512 == null);
    try testing.expectEqual(DependencyKind.required, versions.value.versions[0].dependencies[0].kind);
}
test "provider parse OOM unwinds all ownership" {
    try testing.checkAllAllocationFailures(testing.allocator, exerciseParsers, .{});
}
test "hash algorithms verify correctly and URLs and malformed responses fail closed" {
    try verifyBytes("abc", .{ .sha1 = "a9993e364706816aba3e25717850c26c9cd0d89d", .sha512 = "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f" }, 3);
    try testing.expectError(error.HashMismatch, verifyBytes("abc", .{ .sha1 = test_hash }, null));
    try testing.expectError(error.SizeMismatch, verifyBytes("abc", .{ .sha1 = test_hash }, 4));
    for ([_][]const u8{ "http://cdn.modrinth.com/a", "https://localhost/a", "https://127.0.0.1/a", "https://a:b@cdn.modrinth.com/a", "https://cdn.modrinth.com:8443/a", "https://cdn.modrinth.com/a#fragment" }) |url| try testing.expect(!safeHttpsUrl(url));
    try testing.expectError(error.InvalidResponse, parseModrinthCatalog(testing.allocator, "[]", true));
    try testing.expectError(error.MissingHash, validateHashes(.{}));
    try testing.expectError(error.InvalidHash, validateHashes(.{ .sha512 = test_hash }));
    const too_large = try testing.allocator.alloc(u8, max_json_bytes + 1);
    defer testing.allocator.free(too_large);
    try testing.expectError(error.ResponseTooLarge, parseModrinthVersions(testing.allocator, too_large, false, null));
}
fn fixtureVersion(id: []const u8, project_id: []const u8, deps: []const Dependency) Version {
    return .{ .provider = .modrinth, .id = id, .project_id = project_id, .name = id, .minecraft_versions = &.{"1.20.1"}, .loaders = &.{"fabric"}, .files = &.{}, .dependencies = deps };
}
fn exerciseDependencies(a: std.mem.Allocator) !void {
    const versions = [_]Version{ fixtureVersion("a", "A", &.{.{ .kind = .required, .project_id = "B" }}), fixtureVersion("b", "B", &.{}) };
    var plan = try planDependencies(a, &versions, &.{.{ .provider = .modrinth, .id = "a" }}, test_filter, &.{});
    defer plan.deinit();
    try testing.expect(plan.value.ready);
}
test "dependency cycles unknown required ambiguity optional and incompatible" {
    const root: VersionKey = .{ .provider = .modrinth, .id = "a" };
    const cycles = [_]Version{ fixtureVersion("a", "A", &.{.{ .kind = .required, .project_id = "B" }}), fixtureVersion("b", "B", &.{.{ .kind = .required, .project_id = "A" }}) };
    try testing.expectError(error.DependencyCycle, planDependencies(testing.allocator, &cycles, &.{root}, test_filter, &.{}));
    const missing = [_]Version{fixtureVersion("a", "A", &.{.{ .kind = .required, .project_id = "missing" }})};
    var unresolved = try planDependencies(testing.allocator, &missing, &.{root}, test_filter, &.{});
    defer unresolved.deinit();
    try testing.expect(!unresolved.value.ready);
    try testing.expectEqual(IssueKind.required_unknown, unresolved.value.issues[0].kind);
    const optional = [_]Version{ fixtureVersion("a", "A", &.{.{ .kind = .optional, .project_id = "B" }}), fixtureVersion("b", "B", &.{}), fixtureVersion("c", "B", &.{}) };
    var undecided = try planDependencies(testing.allocator, &optional, &.{root}, test_filter, &.{});
    defer undecided.deinit();
    try testing.expectEqual(IssueKind.optional_choice, undecided.value.issues[0].kind);
    var ambiguous = try planDependencies(testing.allocator, &optional, &.{root}, test_filter, &.{.{ .from = root, .dependency_index = 0, .include = true }});
    defer ambiguous.deinit();
    try testing.expectEqual(IssueKind.ambiguous_version, ambiguous.value.issues[0].kind);
    var chosen = try planDependencies(testing.allocator, &optional, &.{root}, test_filter, &.{.{ .from = root, .dependency_index = 0, .include = true, .version_id = "b" }});
    defer chosen.deinit();
    try testing.expect(chosen.value.ready);
    try testing.expectEqualSlices(usize, &.{ 1, 0 }, chosen.value.indices);
    const incompatible = [_]Version{ fixtureVersion("a", "A", &.{.{ .kind = .incompatible, .project_id = "B" }}), fixtureVersion("b", "B", &.{}) };
    var blocked = try planDependencies(testing.allocator, &incompatible, &.{ root, .{ .provider = .modrinth, .id = "b" } }, test_filter, &.{});
    defer blocked.deinit();
    try testing.expectEqual(IssueKind.incompatible, blocked.value.issues[0].kind);
    try testing.checkAllAllocationFailures(testing.allocator, exerciseDependencies, .{});
}
const FixtureTransport = struct {
    calls: usize = 0,
    mode: enum { search, project, versions, version, rate_limited, oversized } = .search,
    fn get(ctx: ?*anyopaque, a: std.mem.Allocator, req: Request) !Response {
        const self: *FixtureTransport = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        try testing.expect(std.mem.startsWith(u8, req.url, "https://api.modrinth.com/v2/"));
        try testing.expect(!req.follow_redirects and req.max_body_bytes == max_json_bytes and req.timeout_ms > 0);
        try testing.expect(req.credential_header == null);
        const body = switch (self.mode) {
            .search => blk: {
                try testing.expect(std.mem.indexOf(u8, req.url, "query=a%26b") != null);
                try testing.expect(std.mem.indexOf(u8, req.url, "facets=%5B") != null);
                break :blk try a.dupe(u8, "{\"hits\":[{\"project_id\":\"P1\",\"project_type\":\"mod\",\"title\":\"Example\",\"description\":\"fixture\"}],\"total_hits\":1}");
            },
            .project => try a.dupe(u8, "{\"id\":\"P1\",\"project_type\":\"mod\",\"title\":\"Example\",\"description\":\"fixture\"}"),
            .versions => try std.mem.concat(a, u8, &.{ "[", mr_version_fixture, "]" }),
            .version => try a.dupe(u8, mr_version_fixture),
            .rate_limited => try a.dupe(u8, "{}"),
            .oversized => try a.alloc(u8, max_json_bytes + 1),
        };
        return .{ .status = if (self.mode == .rate_limited) 429 else 200, .body = body };
    }
};
fn exerciseClient(a: std.mem.Allocator) !void {
    var fixture: FixtureTransport = .{};
    const client: Client = .{ .allocator = a, .transport = .{ .context = &fixture, .get = FixtureTransport.get }, .user_agent = "Vela/fixture (test.invalid)" };
    var search = try client.search("a&b", "mod", test_filter, 0, 10);
    defer search.deinit();
    fixture.mode = .project;
    var project = try client.project("P1");
    defer project.deinit();
    fixture.mode = .versions;
    var versions = try client.versions("P1", test_filter);
    defer versions.deinit();
    fixture.mode = .version;
    var version = try client.version("V1", test_filter);
    defer version.deinit();
}
test "bounded injectable transport CF gate response guards and OOM" {
    try exerciseClient(testing.allocator);
    try testing.checkAllAllocationFailures(testing.allocator, exerciseClient, .{});
    var fixture: FixtureTransport = .{ .mode = .rate_limited };
    const client: Client = .{ .allocator = testing.allocator, .transport = .{ .context = &fixture, .get = FixtureTransport.get }, .user_agent = "Vela/fixture" };
    try testing.expectError(error.ProviderDisabled, client.curseForge());
    try testing.expectEqual(@as(usize, 0), fixture.calls);
    try testing.expectError(error.RateLimited, client.project("P1"));
    fixture.mode = .oversized;
    try testing.expectError(error.ResponseTooLarge, client.project("P1"));
}

test "SHA256 standalone mixed hash verification and case-insensitive comparisons" {
    const expected: Hashes = .{ .sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" };
    try verifyBytes("abc", expected, 3);
    try testing.expect(hashesMatch(expected, .{ .sha256 = "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD" }));
    try testing.expect(!hashesMatch(expected, .{ .sha1 = test_hash }));
    try testing.expectError(error.InvalidHash, validateHashes(.{ .sha256 = test_hash }));
    try testing.expectError(error.HashMismatch, verifyBytes("abcd", expected, null));
    try verifyBytes("abc", .{ .sha1 = "a9993e364706816aba3e25717850c26c9cd0d89d", .sha256 = expected.sha256 }, null);
}
fn replaceFixture(a: std.mem.Allocator, bytes: []const u8, before: []const u8, after: []const u8) ![]u8 {
    const i = std.mem.indexOf(u8, bytes, before) orelse unreachable;
    return std.mem.concat(a, u8, &.{ bytes[0..i], after, bytes[i + before.len ..] });
}
test "CurseForge missing URL and permitted fixtures stay manual unsupported relations reject" {
    var catalog = try parseCurseForgeCatalog(testing.allocator, cf_catalog_fixture, false);
    defer catalog.deinit();
    var project = catalog.value.projects[0];
    project.distribution_allowed = true;
    var missing = try parseCurseForgeVersions(testing.allocator, cf_version_fixture, false, project, null);
    defer missing.deinit();
    try testing.expectEqual(ManualReason.missing_url, missing.value.versions[0].files[0].download.manual_required.reason);
    const bytes = try replaceFixture(testing.allocator, cf_version_fixture, "\"downloadUrl\":null", "\"downloadUrl\":\"https://edge.forgecdn.net/fixture.jar\"");
    defer testing.allocator.free(bytes);
    var disabled = try parseCurseForgeVersions(testing.allocator, bytes, false, project, null);
    defer disabled.deinit();
    try testing.expectEqual(ManualReason.provider_disabled, disabled.value.versions[0].files[0].download.manual_required.reason);
    const unknown_relation = try replaceFixture(testing.allocator, cf_version_fixture, "\"relationType\":3", "\"relationType\":4");
    defer testing.allocator.free(unknown_relation);
    try testing.expectError(error.UnsupportedDependency, parseCurseForgeVersions(testing.allocator, unknown_relation, false, project, null));
    try testing.expect(!safeHttpsUrl("https://cdn.modrinth.com/a%GG.jar"));
    try testing.expect(!safeHttpsUrl("https://cdn.modrinth.com/a\".jar"));
}
test "invalid download filenames version IDs and duplicate files reject" {
    const cases = [_]struct { before: []const u8, after: []const u8, expected: anyerror }{
        .{ .before = "\"filename\":\"mod.jar\"", .after = "\"filename\":\"../mod.jar\"", .expected = error.UnsafeFilename },
        .{ .before = "\"id\":\"V1\"", .after = "\"id\":\"\"", .expected = error.InvalidId },
        .{ .before = "\"dependency_type\":\"optional\"", .after = "\"dependency_type\":\"new-type\"", .expected = error.UnsupportedDependency },
        .{ .before = "\"size\":3", .after = "\"size\":17179869185", .expected = error.FileTooLarge },
    };
    for (cases) |case| {
        const bytes = try replaceFixture(testing.allocator, mr_version_fixture, case.before, case.after);
        defer testing.allocator.free(bytes);
        try testing.expectError(case.expected, parseModrinthVersions(testing.allocator, bytes, true, null));
    }
    const duplicate = try std.mem.concat(testing.allocator, u8, &.{ "[", mr_version_fixture, ",", mr_version_fixture, "]" });
    defer testing.allocator.free(duplicate);
    try testing.expectError(error.DuplicateId, parseModrinthVersions(testing.allocator, duplicate, false, null));
    const duplicates = [_]File{
        .{ .filename = "A.jar", .hashes = .{ .sha1 = test_hash }, .download = .{ .remote = "https://cdn.modrinth.com/a.jar" } },
        .{ .filename = "a.jar", .hashes = .{ .sha1 = test_hash }, .download = .{ .remote = "https://cdn.modrinth.com/a.jar" } },
    };
    try testing.expectError(error.PathCollision, uniqueFiles(&duplicates));
}

const cf_fixture_key = "in-memory-fixture-key";
const CurseForgeFixtureTransport = struct {
    mode: enum { search, project, versions, version } = .search,
    fresh_routes: bool = false,
    modpack_candidates: bool = false,
    distribution_allowed: bool = true,
    file_length: ?u64 = 3,
    calls: usize = 0,
    expected_url: ?[]const u8 = null,
    status: u16 = 200,
    oversized: bool = false,
    raw_body: ?[]const u8 = null,
    game_id: u32 = 432,
    project_id: i64 = 12,
    file_project_id: i64 = 12,
    file_id: i64 = 34,
    class_id: u32 = 6,
    available: bool = true,
    download_url: ?[]const u8 = "https://edge.forgecdn.net/files/0/34/example.jar",
    official_page: []const u8 = "https://www.curseforge.com/minecraft/mc-mods/example",
    hash: []const u8 = test_hash,
    relation: u8 = 3,
    game_versions: []const []const u8 = &.{ "1.20.1", "Fabric" },
    total: u32 = 1,
    page_index: u32 = 0,
    empty_page: bool = false,
    bad_pagination: bool = false,

    fn client(self: *@This(), a: std.mem.Allocator) CurseForgeClient {
        return .{ .allocator = a, .transport = .{ .context = self, .get = get }, .user_agent = "Vela/pure-fixture", .options = .{ .enabled = true, .api_key = cf_fixture_key, .terms_approved = true } };
    }
    fn get(ctx: ?*anyopaque, a: std.mem.Allocator, request: Request) !Response {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        try testing.expect(credentialScopeAllowed(request));
        try testing.expect(request.credential_header != null);
        try testing.expect(std.mem.eql(u8, request.credential_header.?.value, cf_fixture_key));
        try testing.expect(std.mem.eql(u8, request.user_agent, "Vela/pure-fixture"));
        try testing.expect(!request.follow_redirects and request.max_body_bytes == max_json_bytes and request.timeout_ms == 15000);
        if (self.expected_url) |expected| try testing.expectEqualStrings(expected, request.url);
        if (self.oversized) return .{ .status = self.status, .body = try a.alloc(u8, max_json_bytes + 1) };
        if (self.raw_body) |raw| return .{ .status = self.status, .body = try a.dupe(u8, raw) };
        const project_value = .{ .id = self.project_id, .gameId = self.game_id, .classId = self.class_id, .name = "Example", .summary = "fixture", .links = .{ .websiteUrl = self.official_page }, .allowModDistribution = self.distribution_allowed };
        const file_value = .{ .id = self.file_id + self.page_index, .gameId = self.game_id, .modId = self.file_project_id, .displayName = "Example 1", .fileName = "example.jar", .isAvailable = self.available, .downloadUrl = self.download_url, .fileLength = self.file_length, .hashes = .{.{ .algo = 1, .value = self.hash }}, .gameVersions = self.game_versions, .dependencies = .{.{ .modId = 42, .relationType = self.relation }} };
        const route = if (self.fresh_routes and std.mem.eql(u8, request.url, "https://api.curseforge.com/v1/mods/12")) .project else self.mode;
        const body = switch (route) {
            .search => try std.json.Stringify.valueAlloc(a, .{ .data = .{project_value}, .pagination = .{ .index = 0, .pageSize = 10, .resultCount = 1, .totalCount = self.total } }, .{}),
            .project => try std.json.Stringify.valueAlloc(a, .{ .data = project_value }, .{}),
            .version => try std.json.Stringify.valueAlloc(a, .{ .data = file_value }, .{}),
            .versions => blk: {
                const files: []const @TypeOf(file_value) = if (self.empty_page) &.{} else &.{file_value};
                const index = self.page_index;
                self.page_index += @intCast(files.len);
                const url = if (self.modpack_candidates)
                    try std.fmt.allocPrint(a, "https://api.curseforge.com/v1/mods/12/files?gameVersion=1.20.1&index={d}&pageSize=50", .{index})
                else
                    try std.fmt.allocPrint(a, "https://api.curseforge.com/v1/mods/12/files?gameVersion=1.20.1&modLoaderType=4&index={d}&pageSize=50", .{index});
                defer a.free(url);
                try testing.expectEqualStrings(url, request.url);
                break :blk try std.json.Stringify.valueAlloc(a, .{ .data = files, .pagination = .{ .index = if (self.bad_pagination) index + 1 else index, .pageSize = 50, .resultCount = files.len, .totalCount = self.total } }, .{});
            },
        };
        return .{ .status = self.status, .body = body };
    }
};
const cf_fixture_project: Project = .{ .provider = .curseforge, .id = "12", .name = "Example", .official_page = "https://www.curseforge.com/minecraft/mc-mods/example", .distribution_allowed = true };

fn exerciseCurseForgeClient(a: std.mem.Allocator) !void {
    var fixture: CurseForgeFixtureTransport = .{ .expected_url = "https://api.curseforge.com/v1/mods/search?gameId=432&classId=6&gameVersion=1.20.1&modLoaderType=4&searchFilter=a%26b&index=0&pageSize=10" };
    const client = fixture.client(a);
    var catalog = try client.search("a&b", "mod", test_filter, 0, 10);
    defer catalog.deinit();
    try testing.expectEqualStrings("12", catalog.value.projects[0].id);
    fixture.mode = .project;
    fixture.expected_url = "https://api.curseforge.com/v1/mods/12";
    var project_value = try client.project("12");
    defer project_value.deinit();
    fixture.mode = .versions;
    fixture.expected_url = null;
    fixture.total = 2;
    var versions_value = try client.versions(project_value.value.projects[0], test_filter);
    defer versions_value.deinit();
    try testing.expectEqual(@as(usize, 2), versions_value.value.versions.len);
    try testing.expectEqualStrings("35", versions_value.value.versions[1].id);
    try testing.expectEqualStrings("42", versions_value.value.versions[0].dependencies[0].project_id.?);
    fixture.mode = .version;
    fixture.page_index = 0;
    fixture.expected_url = "https://api.curseforge.com/v1/mods/12/files/34";
    var version_value = try client.version(project_value.value.projects[0], "34", test_filter);
    defer version_value.deinit();
    try testing.expect(version_value.value.versions[0].files[0].download == .remote);
    try testing.expectEqualStrings("example.jar", version_value.value.versions[0].files[0].filename);
}
test "CurseForge opt-in client URLs owned metadata pagination and OOM are pure" {
    try exerciseCurseForgeClient(testing.allocator);
    try testing.checkAllAllocationFailures(testing.allocator, exerciseCurseForgeClient, .{});
}
test "CurseForge all missing opt-in gates short circuit every route before transport" {
    var fixture: CurseForgeFixtureTransport = .{};
    const options = [_]CurseForgeOptions{
        .{},
        .{ .api_key = cf_fixture_key, .terms_approved = true },
        .{ .enabled = true, .api_key = cf_fixture_key },
        .{ .enabled = true, .terms_approved = true },
        .{ .enabled = true, .api_key = "", .terms_approved = true },
    };
    for (options) |option| {
        var client = fixture.client(testing.allocator);
        client.options = option;
        try testing.expectError(error.ProviderDisabled, client.search("", "mod", test_filter, 0, 10));
        try testing.expectError(error.ProviderDisabled, client.project("12"));
        try testing.expectError(error.ProviderDisabled, client.versions(cf_fixture_project, test_filter));
        try testing.expectError(error.ProviderDisabled, client.version(cf_fixture_project, "34", null));
    }
    const long_key = [_]u8{'x'} ** 513;
    for ([_][]const u8{ "bad\r\nheader", "bad key", "\x7f", "\x80", &long_key }) |key| {
        var client = fixture.client(testing.allocator);
        client.options.api_key = key;
        try testing.expectError(error.InvalidCredential, client.project("12"));
    }
    try testing.expectEqual(@as(usize, 0), fixture.calls);
}
test "CurseForge credential scope forbids origin lookalikes and redirects" {
    var request: Request = .{ .url = "https://api.curseforge.com/v1/mods/12", .user_agent = "fixture", .credential_header = .{ .name = "x-api-key", .value = cf_fixture_key } };
    try testing.expect(credentialScopeAllowed(request));
    for ([_][]const u8{ "https://api.modrinth.com/v2/project/12", "https://api.curseforge.com.evil.invalid/v1/mods/12", "https://api.curseforge.com@evil.invalid/v1/mods/12", "https://api.curseforge.com:443/v1/mods/12", "http://api.curseforge.com/v1/mods/12", "https://edge.forgecdn.net/files/12.jar", "https://api.curseforge.com/v10/mods/12" }) |url| {
        request.url = url;
        try testing.expect(!credentialScopeAllowed(request));
    }
    request.url = "https://api.curseforge.com/v1/mods/12";
    request.follow_redirects = true;
    try testing.expect(!credentialScopeAllowed(request));
    request.follow_redirects = false;
    request.credential_header.?.name = "Authorization";
    try testing.expect(!credentialScopeAllowed(request));
}
test "CurseForge status body size malformed JSON and ID errors fail closed" {
    var fixture: CurseForgeFixtureTransport = .{ .mode = .project, .raw_body = "{}" };
    const client = fixture.client(testing.allocator);
    for ([_]struct { status: u16, expected: anyerror }{ .{ .status = 401, .expected = error.InvalidApiKey }, .{ .status = 403, .expected = error.InvalidApiKey }, .{ .status = 429, .expected = error.RateLimited }, .{ .status = 302, .expected = error.RedirectRejected }, .{ .status = 500, .expected = error.HttpFailure } }) |case| {
        fixture.status = case.status;
        try testing.expectError(case.expected, client.project("12"));
    }
    fixture.status = 200;
    fixture.oversized = true;
    try testing.expectError(error.ResponseTooLarge, client.project("12"));
    fixture.oversized = false;
    try testing.expectError(error.MissingField, client.project("12"));
    fixture.raw_body = "{";
    try testing.expectError(error.UnexpectedEndOfInput, client.project("12"));
    fixture.raw_body = null;
    for ([_][]const u8{ "0", "01", "-1", "2147483648", "12/path", "12?query", "" }) |id| try testing.expectError(error.InvalidId, client.project(id));
    fixture.project_id = 13;
    try testing.expectError(error.ProjectMismatch, client.project("12"));
    fixture.project_id = 12;
    fixture.game_id = 1;
    try testing.expectError(error.GameMismatch, client.project("12"));
    fixture.game_id = 432;
    fixture.class_id = 1;
    try testing.expectError(error.UnsupportedProjectType, client.project("12"));
}
test "CurseForge official manual fallback remains typed hash verified and root bound" {
    var fixture: CurseForgeFixtureTransport = .{ .mode = .version, .download_url = null };
    const client = fixture.client(testing.allocator);
    var version_value = try client.version(cf_fixture_project, "34", test_filter);
    defer version_value.deinit();
    const file = version_value.value.versions[0].files[0];
    try testing.expectEqual(ManualReason.missing_url, file.download.manual_required.reason);
    try testing.expectEqualStrings("https://www.curseforge.com/minecraft/mc-mods/example/files/34", file.download.manual_required.official_page);
    try testing.expectError(error.HashMismatch, verifyBytes("abc", file.hashes, file.size));
    var restricted = cf_fixture_project;
    restricted.distribution_allowed = false;
    fixture.download_url = "https://edge.forgecdn.net/files/0/34/example.jar";
    var restricted_value = try client.version(restricted, "34", null);
    defer restricted_value.deinit();
    try testing.expectEqual(ManualReason.distribution_disabled, restricted_value.value.versions[0].files[0].download.manual_required.reason);
    fixture.available = false;
    var unavailable = try client.version(cf_fixture_project, "34", null);
    defer unavailable.deinit();
    try testing.expectEqual(ManualReason.unavailable, unavailable.value.versions[0].files[0].download.manual_required.reason);
    fixture.available = true;
    fixture.hash = "malformed";
    try testing.expectError(error.InvalidHash, client.version(cf_fixture_project, "34", null));
    fixture.hash = test_hash;
    fixture.file_project_id = 13;
    try testing.expectError(error.ProjectMismatch, client.version(cf_fixture_project, "34", null));
    fixture.file_project_id = 12;
    fixture.file_id = 35;
    try testing.expectError(error.VersionMismatch, client.version(cf_fixture_project, "34", null));
    fixture.file_id = 34;
    fixture.download_url = "https://unsafe.invalid@evil.invalid/file.jar";
    try testing.expectError(error.UnsafeDownloadUrl, client.version(cf_fixture_project, "34", null));
    fixture.download_url = null;
    try testing.expectError(error.IncompatibleVersion, client.version(cf_fixture_project, "34", .{ .minecraft_version = "1.7.10", .loader = .forge }));
    fixture.relation = 4;
    try testing.expectError(error.UnsupportedDependency, client.version(cf_fixture_project, "34", null));
}
test "CurseForge search classes loader IDs and pagination bounds" {
    try testing.expectEqual(@as(u8, 0), curseForgeLoader(.vanilla));
    try testing.expectEqual(@as(u8, 1), curseForgeLoader(.forge));
    try testing.expectEqual(@as(u8, 4), curseForgeLoader(.fabric));
    try testing.expectEqual(@as(u8, 5), curseForgeLoader(.quilt));
    try testing.expectEqual(@as(u8, 6), curseForgeLoader(.neoforge));
    try testing.expectEqual(@as(u32, 4471), try curseForgeClass("modpack"));
    try testing.expectEqual(@as(u32, 12), try curseForgeClass("resourcepack"));
    try testing.expectEqual(@as(u32, 6552), try curseForgeClass("shader"));
    var fixture: CurseForgeFixtureTransport = .{};
    const client = fixture.client(testing.allocator);
    try testing.expectError(error.InvalidQuery, client.search("", "mod", test_filter, 0, 51));
    try testing.expectError(error.InvalidQuery, client.search("", "mod", test_filter, 9991, 10));
    try testing.expectError(error.InvalidQuery, client.search("", "unknown", test_filter, 0, 10));
    try testing.expectEqual(@as(usize, 0), fixture.calls);
    fixture.class_id = 12;
    try testing.expectError(error.ProjectTypeMismatch, client.search("", "mod", test_filter, 0, 10));
    fixture.mode = .versions;
    fixture.total = max_items + 1;
    try testing.expectError(error.TooManyItems, client.versions(cf_fixture_project, test_filter));
    fixture.total = 1;
    fixture.page_index = 0;
    fixture.bad_pagination = true;
    try testing.expectError(error.InvalidPagination, client.versions(cf_fixture_project, test_filter));
    fixture.bad_pagination = false;
    fixture.page_index = 0;
    fixture.empty_page = true;
    try testing.expectError(error.InvalidPagination, client.versions(cf_fixture_project, test_filter));
}

const authorized_fixture_policy: RemotePolicy = .{ .enabled = true, .approved_download_hosts = &.{"edge.forgecdn.net"} };
const FixtureRequestBudget = struct {
    count: usize = 0,
    limit: usize = 64,
    fn before(context: ?*anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.count >= self.limit) return error.TooManyRequests;
        self.count += 1;
    }
};
fn exerciseAuthorizedCurseForge(a: std.mem.Allocator) !void {
    var fixture: CurseForgeFixtureTransport = .{ .fresh_routes = true, .mode = .version };
    var budget: FixtureRequestBudget = .{};
    var client = fixture.client(a);
    client.request_observer = .{ .context = &budget, .before_request = FixtureRequestBudget.before };
    var result = try client.authorizedVersion("12", "34", test_filter, authorized_fixture_policy);
    defer result.deinit();
    const version_value = result.value.versions[0];
    const file = version_value.files[0];
    try testing.expectEqual(@as(usize, 2), fixture.calls);
    try testing.expectEqual(fixture.calls, budget.count);
    try validateRemoteAuthorization(.curseforge, "12", "34", file, authorized_fixture_policy);
    try testing.expectEqualStrings(cf_fixture_project.official_page, file.authorization.?.official_page);
    try testing.expectEqualStrings("edge.forgecdn.net", file.authorization.?.approved_download_hosts[0]);
}
test "authorized CF metadata owns fresh project proof and cleans every allocation failure" {
    try exerciseAuthorizedCurseForge(testing.allocator);
    try testing.checkAllAllocationFailures(testing.allocator, exerciseAuthorizedCurseForge, .{});
}
test "manual CF metadata and raw remote URLs never authorize installation" {
    var fixture: CurseForgeFixtureTransport = .{ .mode = .version };
    const client = fixture.client(testing.allocator);
    var manual = try client.manualVersion(cf_fixture_project, "34", test_filter);
    defer manual.deinit();
    try testing.expect(manual.value.versions[0].files[0].download == .manual_required);
    try testing.expect(manual.value.versions[0].files[0].authorization == null);
    var raw = try client.version(cf_fixture_project, "34", test_filter);
    defer raw.deinit();
    try testing.expectError(error.MissingRemoteAuthorization, validateRemoteAuthorization(.curseforge, "12", "34", raw.value.versions[0].files[0], authorized_fixture_policy));
    const calls = fixture.calls;
    try testing.expectError(error.ProviderDisabled, client.authorizedVersion("12", "34", test_filter, .{}));
    try testing.expectEqual(calls, fixture.calls);
}
test "CF authorization binds identity filename URL size hash availability and host snapshot" {
    var fixture: CurseForgeFixtureTransport = .{ .fresh_routes = true, .mode = .version };
    var result = try fixture.client(testing.allocator).authorizedVersion("12", "34", test_filter, authorized_fixture_policy);
    defer result.deinit();
    const file = result.value.versions[0].files[0];
    try testing.expectError(error.InvalidRemoteAuthorization, validateRemoteAuthorization(.curseforge, "13", "34", file, authorized_fixture_policy));
    try testing.expectError(error.InvalidRemoteAuthorization, validateRemoteAuthorization(.curseforge, "12", "35", file, authorized_fixture_policy));
    var changed = file;
    changed.filename = "other.jar";
    try testing.expectError(error.InvalidRemoteAuthorization, validateRemoteAuthorization(.curseforge, "12", "34", changed, authorized_fixture_policy));
    changed = file;
    changed.size = 4;
    try testing.expectError(error.InvalidRemoteAuthorization, validateRemoteAuthorization(.curseforge, "12", "34", changed, authorized_fixture_policy));
    changed = file;
    changed.download = .{ .remote = "https://edge.forgecdn.net/other.jar" };
    try testing.expectError(error.InvalidRemoteAuthorization, validateRemoteAuthorization(.curseforge, "12", "34", changed, authorized_fixture_policy));
    changed = file;
    changed.hashes.sha1 = "1111111111111111111111111111111111111111";
    try testing.expectError(error.InvalidRemoteAuthorization, validateRemoteAuthorization(.curseforge, "12", "34", changed, authorized_fixture_policy));
    changed = file;
    var proof = file.authorization.?;
    proof.available = false;
    changed.authorization = proof;
    try testing.expectError(error.InvalidRemoteAuthorization, validateRemoteAuthorization(.curseforge, "12", "34", changed, authorized_fixture_policy));
    try testing.expectError(error.InvalidRemoteAuthorization, validateRemoteAuthorization(.curseforge, "12", "34", file, .{ .enabled = true, .approved_download_hosts = &.{"cdn.modrinth.com"} }));
}
test "fresh CF project restrictions size URL and page requests fail closed" {
    var fixture: CurseForgeFixtureTransport = .{ .fresh_routes = true, .mode = .version, .distribution_allowed = false };
    var restricted = try fixture.client(testing.allocator).authorizedVersion("12", "34", test_filter, authorized_fixture_policy);
    defer restricted.deinit();
    try testing.expect(restricted.value.versions[0].files[0].download == .manual_required);
    try testing.expect(restricted.value.versions[0].files[0].authorization == null);
    fixture.distribution_allowed = true;
    fixture.available = false;
    var unavailable = try fixture.client(testing.allocator).authorizedVersion("12", "34", test_filter, authorized_fixture_policy);
    defer unavailable.deinit();
    try testing.expect(unavailable.value.versions[0].files[0].authorization == null);
    fixture.available = true;
    fixture.file_length = null;
    try testing.expectError(error.MissingFileSize, fixture.client(testing.allocator).authorizedVersion("12", "34", test_filter, authorized_fixture_policy));
    fixture.file_length = 0;
    try testing.expectError(error.InvalidFileSize, fixture.client(testing.allocator).authorizedVersion("12", "34", test_filter, authorized_fixture_policy));
    fixture.file_length = 3;
    fixture.download_url = "https://edge.forgecdn.net.attacker.invalid/a.jar";
    try testing.expectError(error.UnapprovedDownloadHost, fixture.client(testing.allocator).authorizedVersion("12", "34", test_filter, authorized_fixture_policy));
    fixture.download_url = "https://edge.forgecdn.net:443/a.jar";
    try testing.expectError(error.UnsafeDownloadUrl, fixture.client(testing.allocator).authorizedVersion("12", "34", test_filter, authorized_fixture_policy));
    fixture.download_url = "https://edge.forgecdn.net/a.jar";
    fixture.mode = .versions;
    fixture.total = 3;
    fixture.page_index = 0;
    var budget: FixtureRequestBudget = .{ .limit = 3 };
    var client = fixture.client(testing.allocator);
    client.request_observer = .{ .context = &budget, .before_request = FixtureRequestBudget.before };
    const calls = fixture.calls;
    try testing.expectError(error.TooManyRequests, client.authorizedVersions("12", test_filter, authorized_fixture_policy));
    try testing.expectEqual(@as(usize, 3), fixture.calls - calls);
    try testing.expectEqual(@as(usize, 3), budget.count);
}

const cf_fixture_modpack: Project = .{ .provider = .curseforge, .id = "12", .name = "Pack", .official_page = "https://www.curseforge.com/minecraft/modpacks/example", .distribution_allowed = true };

fn exerciseModpackCandidates(a: std.mem.Allocator) !void {
    var fixture: CurseForgeFixtureTransport = .{ .fresh_routes = true, .mode = .versions, .modpack_candidates = true, .class_id = 4471, .official_page = cf_fixture_modpack.official_page, .game_versions = &.{"1.20.1"} };
    var manual = try fixture.client(a).manualModpackCandidates(cf_fixture_modpack, "1.20.1");
    defer manual.deinit();
    try testing.expectEqual(@as(usize, 1), manual.value.versions.len);
    try testing.expectEqual(@as(usize, 0), manual.value.versions[0].loaders.len);
    try testing.expectEqualStrings("https://www.curseforge.com/minecraft/modpacks/example/files/34", manual.value.versions[0].files[0].download.manual_required.official_page);
    fixture.page_index = 0;
    var remote = try fixture.client(a).authorizedModpackCandidates("12", "1.20.1", authorized_fixture_policy);
    defer remote.deinit();
    const file = remote.value.versions[0].files[0];
    try testing.expectEqualStrings(cf_fixture_modpack.official_page, file.authorization.?.official_page);
    try validateRemoteAuthorization(.curseforge, "12", "34", file, authorized_fixture_policy);
}

test "CF modpack candidates own manual and remote results across allocation failures" {
    try exerciseModpackCandidates(testing.allocator);
    try testing.checkAllAllocationFailures(testing.allocator, exerciseModpackCandidates, .{});
}

test "CF modpack candidates preserve tags and Minecraft filtering while ordinary versions stay strict" {
    var fixture: CurseForgeFixtureTransport = .{ .fresh_routes = true, .mode = .versions, .modpack_candidates = true, .class_id = 4471, .official_page = cf_fixture_modpack.official_page, .game_versions = &.{"1.20.1"} };
    var untagged = try fixture.client(testing.allocator).manualModpackCandidates(cf_fixture_modpack, "1.20.1");
    defer untagged.deinit();
    try testing.expectEqual(@as(usize, 1), untagged.value.versions.len);
    fixture.page_index = 0;
    fixture.modpack_candidates = false;
    var ordinary = try fixture.client(testing.allocator).versions(cf_fixture_modpack, test_filter);
    defer ordinary.deinit();
    try testing.expectEqual(@as(usize, 0), ordinary.value.versions.len);
    fixture.page_index = 0;
    fixture.modpack_candidates = true;
    fixture.game_versions = &.{ "1.20.1", "Forge" };
    var known = try fixture.client(testing.allocator).manualModpackCandidates(cf_fixture_modpack, "1.20.1");
    defer known.deinit();
    try testing.expectEqualStrings("forge", known.value.versions[0].loaders[0]);
    try testing.expect(!compatible(known.value.versions[0], test_filter));
    fixture.page_index = 0;
    fixture.game_versions = &.{"1.19.4"};
    var mismatch = try fixture.client(testing.allocator).manualModpackCandidates(cf_fixture_modpack, "1.20.1");
    defer mismatch.deinit();
    try testing.expectEqual(@as(usize, 0), mismatch.value.versions.len);
}

test "CF modpack candidates require fresh class page and valid input before file requests" {
    var fixture: CurseForgeFixtureTransport = .{ .fresh_routes = true, .mode = .versions, .modpack_candidates = true, .class_id = 6, .official_page = cf_fixture_modpack.official_page, .game_versions = &.{"1.20.1"} };
    try testing.expectError(error.ProjectTypeMismatch, fixture.client(testing.allocator).manualModpackCandidates(cf_fixture_modpack, "1.20.1"));
    try testing.expectEqual(@as(usize, 1), fixture.calls);
    fixture.calls = 0;
    fixture.class_id = 4471;
    fixture.official_page = "https://www.curseforge.com/minecraft/mc-mods/example";
    try testing.expectError(error.ProjectTypeMismatch, fixture.client(testing.allocator).authorizedModpackCandidates("12", "1.20.1", authorized_fixture_policy));
    try testing.expectEqual(@as(usize, 1), fixture.calls);
    fixture.calls = 0;
    fixture.official_page = "https://www.curseforge.com/minecraft/modpacks/renamed";
    try testing.expectError(error.ProjectMismatch, fixture.client(testing.allocator).manualModpackCandidates(cf_fixture_modpack, "1.20.1"));
    try testing.expectEqual(@as(usize, 1), fixture.calls);
    fixture.calls = 0;
    try testing.expectError(error.InvalidId, fixture.client(testing.allocator).manualModpackCandidates(cf_fixture_modpack, ""));
    try testing.expectEqual(@as(usize, 0), fixture.calls);
}

test "CF modpack candidate pagination observer and fresh distribution remain enforced" {
    var fixture: CurseForgeFixtureTransport = .{ .fresh_routes = true, .mode = .versions, .modpack_candidates = true, .class_id = 4471, .official_page = cf_fixture_modpack.official_page, .game_versions = &.{"1.20.1"}, .distribution_allowed = false };
    var restricted = try fixture.client(testing.allocator).authorizedModpackCandidates("12", "1.20.1", authorized_fixture_policy);
    defer restricted.deinit();
    const file = restricted.value.versions[0].files[0];
    try testing.expect(file.authorization == null);
    try testing.expectEqual(ManualReason.distribution_disabled, file.download.manual_required.reason);
    fixture.page_index = 0;
    fixture.bad_pagination = true;
    try testing.expectError(error.InvalidPagination, fixture.client(testing.allocator).manualModpackCandidates(cf_fixture_modpack, "1.20.1"));
    fixture.page_index = 0;
    fixture.bad_pagination = false;
    fixture.calls = 0;
    var budget: FixtureRequestBudget = .{ .limit = 1 };
    var client = fixture.client(testing.allocator);
    client.request_observer = .{ .context = &budget, .before_request = FixtureRequestBudget.before };
    try testing.expectError(error.TooManyRequests, client.authorizedModpackCandidates("12", "1.20.1", authorized_fixture_policy));
    try testing.expectEqual(@as(usize, 1), fixture.calls);
    try testing.expectEqual(@as(usize, 1), budget.count);
}

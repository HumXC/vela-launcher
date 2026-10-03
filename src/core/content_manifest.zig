const std = @import("std");
const config = @import("config.zig");
const providers = @import("content_providers.zig");
const J = providers.Json;
const Owned = providers.Owned;

pub const schema_version: u32 = 2;
pub const legacy_schema_version: u32 = 1;
pub const max_path_bytes = 1024;
pub const Side = enum { client, server };
pub const FileRole = enum { content, configuration, override };
pub const IdentityProvenance = enum { legacy_unknown, official_file, pack_archive, pack_override };
pub const PackMembership = struct { identity: PackIdentity, paths: []const []const u8 };
pub const ManagedFile = struct {
    path: []const u8,
    provider: providers.Provider,
    project_id: []const u8,
    version_id: []const u8,
    hashes: providers.Hashes,
    size: ?u64 = null,
    role: FileRole = .content,
    enabled: bool = true,
    /// pack_archive IDs name the archive, not a fabricated official child identity.
    identity_provenance: IdentityProvenance = .legacy_unknown,
    standalone: bool = true,
};
pub const Manifest = struct {
    schema_version: u32 = 1,
    instance_id: []const u8,
    pack_version: []const u8,
    files: []const ManagedFile = &.{},
    pack_membership: ?PackMembership = null,
};
// The exact v1 shape rejects unknown fields instead of interpreting new permissions.
const LegacyFile = struct {
    path: []const u8,
    provider: providers.Provider,
    project_id: []const u8,
    version_id: []const u8,
    hashes: providers.Hashes,
    size: ?u64 = null,
    role: FileRole = .content,
    enabled: bool = true,
};
const LegacyManifest = struct {
    schema_version: u32 = 1,
    instance_id: []const u8,
    pack_version: []const u8,
    files: []const LegacyFile = &.{},
};

/// Lexical path validation only. The executor must use a guarded instance root,
/// reject symlinks in every ancestor and recheck hashes under its instance lease.
pub fn safeRelativePath(path: []const u8) bool {
    if (path.len == 0 or path.len > max_path_bytes or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var segments = std.mem.splitScalar(u8, path, '/');
    var depth: usize = 0;
    while (segments.next()) |segment| {
        if (!config.validId(segment)) return false;
        depth += 1;
        if (depth > 16) return false;
    }
    return true;
}
pub fn protectedPath(path: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
    for ([_][]const u8{ "saves", "world", "world_nether", "world_the_end", ".vela", ".minecraft", "assets", "libraries", "versions" }) |name| if (std.ascii.eqlIgnoreCase(path[0..end], name)) return true;
    return false;
}
fn checkedPath(path: []const u8) !void {
    if (!safeRelativePath(path)) return error.UnsafeRelativePath;
    if (protectedPath(path)) return error.ProtectedPath;
}
pub fn pathsCollide(a: []const u8, b: []const u8) bool {
    const len = @min(a.len, b.len);
    if (!std.ascii.eqlIgnoreCase(a[0..len], b[0..len])) return false;
    return a.len == b.len or (a.len > len and a[len] == '/') or (b.len > len and b[len] == '/');
}
fn validText(text: []const u8) bool {
    return text.len != 0 and text.len <= 256 and std.unicode.utf8ValidateSlice(text) and std.mem.indexOfScalar(u8, text, 0) == null;
}
/// Logical ownership stays at the JAR name; both physical spellings are reserved.
pub fn toggleable(file: ManagedFile) bool {
    return (file.role == .content or file.role == .override) and
        std.mem.startsWith(u8, file.path, "mods/") and std.mem.endsWith(u8, file.path, ".jar") and
        file.path.len <= max_path_bytes - ".disabled".len;
}
pub fn physicalPath(a: std.mem.Allocator, file: ManagedFile) ![]u8 {
    try checkedPath(file.path);
    if (file.enabled) return a.dupe(u8, file.path);
    if (!toggleable(file)) return error.UnsupportedEnabledState;
    return std.fmt.allocPrint(a, "{s}.disabled", .{file.path});
}
fn validateFile(file: ManagedFile) !void {
    try checkedPath(file.path);
    if (!providers.validToken(file.project_id) or !providers.validToken(file.version_id)) return error.InvalidContentId;
    try providers.validateHashes(file.hashes);
    if (file.size) |s| if (s > providers.max_file_bytes) return error.FileTooLarge;
    if (!file.enabled and !toggleable(file)) return error.UnsupportedEnabledState;
}
pub fn validate(document: Manifest) !void {
    if (document.schema_version != schema_version and document.schema_version != legacy_schema_version) return error.UnsupportedSchema;
    if (document.schema_version == legacy_schema_version and document.pack_membership != null) return error.ReceiptUpgradeRequired;
    if (!config.validId(document.instance_id)) return error.InvalidInstanceId;
    if (!validText(document.pack_version)) return error.InvalidPackVersion;
    if (document.files.len > providers.max_items) return error.TooManyItems;
    for (document.files, 0..) |file, i| {
        try validateFile(file);
        for (document.files[0..i]) |other| if (pathsCollide(file.path, other.path)) return error.PathCollision;
    }
    for (document.files) |file| if (toggleable(file)) {
        var buffer: [max_path_bytes]u8 = undefined;
        const reserved = try std.fmt.bufPrint(&buffer, "{s}.disabled", .{file.path});
        for (document.files) |other| if (pathsCollide(reserved, other.path)) return error.PathCollision;
    };
    if (document.pack_membership) |membership| {
        try validateIdentity(membership.identity);
        if (membership.paths.len > providers.max_items) return error.TooManyItems;
        for (membership.paths, 0..) |path, i| {
            try checkedPath(path);
            for (membership.paths[0..i]) |other| if (pathsCollide(path, other)) return error.PathCollision;
            const record = findManaged(document.files, path) orelse return error.MissingPackMember;
            if (!std.mem.eql(u8, record.path, path) or record.provider != membership.identity.provider or
                record.identity_provenance == .legacy_unknown) return error.UnverifiedPackMember;
            if (record.identity_provenance == .pack_archive or record.identity_provenance == .pack_override) {
                if (!std.mem.eql(u8, record.project_id, membership.identity.project_id) or
                    !std.mem.eql(u8, record.version_id, membership.identity.version_id)) return error.PackIdentityMismatch;
            }
        }
    }
}
pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Owned(Manifest) {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();
    const raw = try J.parse(aa, bytes);
    const version = try J.number(raw.value, "schema_version");
    const document: Manifest = if (version == legacy_schema_version) legacy: {
        const parsed = try std.json.parseFromSlice(LegacyManifest, aa, bytes, .{ .allocate = .alloc_always, .max_value_len = providers.max_string_bytes });
        const files = try aa.alloc(ManagedFile, parsed.value.files.len);
        for (parsed.value.files, files) |file, *out| out.* = .{
            .path = file.path,
            .provider = file.provider,
            .project_id = file.project_id,
            .version_id = file.version_id,
            .hashes = file.hashes,
            .size = file.size,
            .role = file.role,
            .enabled = file.enabled,
        };
        break :legacy .{ .schema_version = 1, .instance_id = parsed.value.instance_id, .pack_version = parsed.value.pack_version, .files = files };
    } else if (version == schema_version) modern: {
        const parsed = try std.json.parseFromSlice(Manifest, aa, bytes, .{ .allocate = .alloc_always, .max_value_len = providers.max_string_bytes });
        break :modern parsed.value;
    } else return error.UnsupportedSchema;
    try validate(document);
    return .{ .arena = arena, .value = document };
}
pub fn serialize(a: std.mem.Allocator, document: Manifest) ![]u8 {
    try validate(document);
    const bytes = if (document.schema_version == legacy_schema_version) legacy: {
        const files = try a.alloc(LegacyFile, document.files.len);
        defer a.free(files);
        for (document.files, files) |file, *out| {
            if (file.identity_provenance != .legacy_unknown or !file.standalone) return error.ReceiptUpgradeRequired;
            out.* = .{ .path = file.path, .provider = file.provider, .project_id = file.project_id, .version_id = file.version_id, .hashes = file.hashes, .size = file.size, .role = file.role, .enabled = file.enabled };
        }
        break :legacy try std.json.Stringify.valueAlloc(a, LegacyManifest{ .instance_id = document.instance_id, .pack_version = document.pack_version, .files = files }, .{ .emit_null_optional_fields = false });
    } else try std.json.Stringify.valueAlloc(a, document, .{ .emit_null_optional_fields = false });
    errdefer a.free(bytes);
    if (bytes.len > providers.max_json_bytes) return error.ResponseTooLarge;
    return bytes;
}
fn cloneInto(comptime T: type, a: std.mem.Allocator, value: T) !T {
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{ .emit_null_optional_fields = false });
    const parsed = try std.json.parseFromSlice(T, a, bytes, .{ .allocate = .alloc_always });
    return parsed.value;
}

pub const PackIdentity = struct { provider: providers.Provider, project_id: []const u8, version_id: []const u8 };

pub fn membershipForPack(a: std.mem.Allocator, pack: PackPlan) !Owned(PackMembership) {
    try validateIdentity(pack.identity);
    try validateInstallFiles(pack.files);
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();
    var paths: std.ArrayList([]const u8) = .empty;
    var records: std.ArrayList(ManagedFile) = .empty;
    for (pack.files) |file| {
        if (!file.required and file.selected != true) continue;
        try paths.append(aa, file.record.path);
        try records.append(aa, file.record);
    }
    const membership: PackMembership = .{ .identity = pack.identity, .paths = paths.items };
    try validate(.{ .schema_version = 2, .instance_id = "proof", .pack_version = pack.version, .files = records.items, .pack_membership = membership });
    const value = try cloneInto(PackMembership, aa, membership);
    return .{ .arena = arena, .value = value };
}

/// Membership proves pack ownership independently of official child-ID provenance.
pub fn packReplacementPaths(a: std.mem.Allocator, previous: Manifest, identity: PackIdentity) !Owned([]const []const u8) {
    try validate(previous);
    try validateIdentity(identity);
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();
    var paths: std.ArrayList([]const u8) = .empty;
    if (previous.pack_membership) |membership| {
        if (membership.identity.provider != identity.provider or !std.mem.eql(u8, membership.identity.project_id, identity.project_id)) return error.PackIdentityMismatch;
        for (membership.paths) |path| {
            const record = findManaged(previous.files, path).?;
            if (record.standalone or record.identity_provenance == .legacy_unknown) continue;
            try paths.append(aa, try aa.dupe(u8, path));
        }
    }
    return .{ .arena = arena, .value = try paths.toOwnedSlice(aa) };
}

pub const LegacyApproval = struct { path: []const u8, expected_hashes: providers.Hashes, expected_size: ?u64 };
pub fn legacyReplacementPaths(a: std.mem.Allocator, previous: Manifest, recorded_identity: PackIdentity, approvals: []const LegacyApproval) !Owned([]const []const u8) {
    try validate(previous);
    try validateIdentity(recorded_identity);
    if (approvals.len > providers.max_items) return error.TooManyItems;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();
    const paths = try aa.alloc([]const u8, approvals.len);
    for (approvals, paths, 0..) |approval, *out, i| {
        try checkedPath(approval.path);
        for (approvals[0..i]) |other| if (pathsCollide(approval.path, other.path)) return error.PathCollision;
        const record = findManaged(previous.files, approval.path) orelse return error.StaleLegacyApproval;
        if (!std.mem.eql(u8, record.path, approval.path) or record.identity_provenance != .legacy_unknown or
            record.provider != recorded_identity.provider or !std.mem.eql(u8, record.project_id, recorded_identity.project_id) or
            !std.mem.eql(u8, record.version_id, recorded_identity.version_id) or record.size != approval.expected_size or
            !providers.hashesMatch(record.hashes, approval.expected_hashes) or !providers.hashesMatch(approval.expected_hashes, record.hashes)) return error.StaleLegacyApproval;
        out.* = try aa.dupe(u8, approval.path);
    }
    return .{ .arena = arena, .value = paths };
}
pub const InstallFile = struct {
    record: ManagedFile,
    download: providers.Download,
    authorization: ?providers.RemoteAuthorization = null,
    /// Original approved alternatives, never synthesized mirrors or CDN paths.
    alternatives: []const []const u8 = &.{},
    required: bool = true,
    selected: ?bool = null,
};
pub const PackReference = struct { project_id: []const u8, file_id: []const u8, required: bool, selected: ?bool = null };
pub const PackPlan = struct {
    identity: PackIdentity,
    name: []const u8,
    version: []const u8,
    minecraft_version: []const u8,
    loader: config.Loader = .vanilla,
    loader_version: ?[]const u8 = null,
    files: []const InstallFile = &.{},
    unresolved: []const PackReference = &.{},
    /// Layers apply in this order. Archive extraction is not implemented here.
    override_layers: []const []const u8 = &.{},
};
fn validateIdentity(identity: PackIdentity) !void {
    if (!providers.validToken(identity.project_id) or !providers.validToken(identity.version_id)) return error.InvalidContentId;
}
fn validateInstallFiles(files: []const InstallFile) !void {
    if (files.len > providers.max_items) return error.TooManyItems;
    for (files, 0..) |file, i| {
        try validateFile(file.record);
        if (file.required and file.selected == false) return error.RequiredFileExcluded;
        for (files[0..i]) |other| if (pathsCollide(file.record.path, other.record.path)) return error.PathCollision;
    }
}
/// Explicit mrpack host whitelist per the official format. Future download
/// adapters must validate every redirect and resolved address before connecting.
pub fn approvedPackUrl(url: []const u8) bool {
    if (!providers.safeHttpsUrl(url)) return false;
    const uri = std.Uri.parse(url) catch return false;
    const host = uri.host.?.percent_encoded;
    for ([_][]const u8{ "cdn.modrinth.com", "github.com", "raw.githubusercontent.com", "gitlab.com" }) |allowed| if (std.ascii.eqlIgnoreCase(host, allowed)) return true;
    return false;
}
fn roleFor(path: []const u8) FileRole {
    return if (std.mem.startsWith(u8, path, "config/")) .configuration else .content;
}

// https://support.modrinth.com/en/articles/8802351-modrinth-modpack-format-mrpack
pub fn parseMrpack(a: std.mem.Allocator, bytes: []const u8, identity: PackIdentity, side: Side) !Owned(PackPlan) {
    try validateIdentity(identity);
    if (identity.provider != .modrinth) return error.ProviderMismatch;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();
    const parsed = try J.parse(aa, bytes);
    const root = parsed.value;
    if (try J.number(root, "formatVersion") != 1) return error.UnsupportedSchema;
    if (!std.mem.eql(u8, try J.text(root, "game"), "minecraft")) return error.UnsupportedGame;
    const version = try J.text(root, "versionId");
    const name = try J.text(root, "name");
    if (!validText(version) or !validText(name)) return error.InvalidPackVersion;
    const deps = try J.field(root, "dependencies");
    if (deps != .object) return error.InvalidResponse;
    const minecraft = try J.text(deps, "minecraft");
    if (!providers.validToken(minecraft)) return error.InvalidMinecraftVersion;
    var loader: config.Loader = .vanilla;
    var loader_version: ?[]const u8 = null;
    var it = deps.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "minecraft")) continue;
        const candidate: config.Loader = if (std.mem.eql(u8, key, "fabric-loader")) .fabric else if (std.mem.eql(u8, key, "quilt-loader")) .quilt else if (std.mem.eql(u8, key, "forge")) .forge else if (std.mem.eql(u8, key, "neoforge")) .neoforge else return error.UnknownRequiredDependency;
        if (loader != .vanilla) return error.AmbiguousLoader;
        loader = candidate;
        loader_version = try J.string(entry.value_ptr.*);
        if (!providers.validToken(loader_version.?)) return error.InvalidLoaderVersion;
    }
    const raw_files = try J.array(try J.field(root, "files"));
    var files: std.ArrayList(InstallFile) = .empty;
    for (raw_files) |f| {
        const path = try J.text(f, "path");
        try checkedPath(path);
        var required = true;
        var unsupported = false;
        if (try J.optional(f, "env")) |env| {
            // Both sides must be valid even if only one side is being installed.
            for ([_][]const u8{ "client", "server" }) |key| {
                const value = try J.text(env, key);
                if (!std.mem.eql(u8, value, "required") and !std.mem.eql(u8, value, "optional") and !std.mem.eql(u8, value, "unsupported")) return error.InvalidEnvironment;
            }
            const value = try J.text(env, @tagName(side));
            required = std.mem.eql(u8, value, "required");
            unsupported = std.mem.eql(u8, value, "unsupported");
        }
        const hashes = try providers.parseHashes(try J.field(f, "hashes"));
        if (hashes.sha1 == null or hashes.sha512 == null) return error.MissingHash;
        const size = try J.number(f, "fileSize");
        if (size > providers.max_file_bytes) return error.FileTooLarge;
        const urls = try J.strings(aa, try J.field(f, "downloads"));
        if (urls.len == 0 or urls.len > 16) return error.MissingDownload;
        for (urls) |url| if (!approvedPackUrl(url)) return error.UnapprovedDownloadHost;
        if (unsupported) continue;
        try files.append(aa, .{ .record = .{ .path = path, .provider = .modrinth, .project_id = try aa.dupe(u8, identity.project_id), .version_id = try aa.dupe(u8, identity.version_id), .hashes = hashes, .size = size, .role = roleFor(path), .identity_provenance = .pack_archive, .standalone = false }, .download = .{ .remote = urls[0] }, .alternatives = urls, .required = required });
    }
    const result_files = try files.toOwnedSlice(aa);
    try validateInstallFiles(result_files);
    const layers = try aa.alloc([]const u8, 2);
    layers[0] = "overrides";
    layers[1] = if (side == .client) "client-overrides" else "server-overrides";
    const value: PackPlan = .{ .identity = try cloneInto(PackIdentity, aa, identity), .name = name, .version = version, .minecraft_version = minecraft, .loader = loader, .loader_version = loader_version, .files = result_files, .override_layers = layers };
    return .{ .arena = arena, .value = value };
}

/// Standard exported CurseForge manifest JSON only. Files are unresolved IDs;
/// this never invents filenames, hashes, official slugs or download URLs.
pub fn parseCurseForgePack(a: std.mem.Allocator, bytes: []const u8, identity: PackIdentity) !Owned(PackPlan) {
    try validateIdentity(identity);
    if (identity.provider != .curseforge) return error.ProviderMismatch;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();
    const parsed = try J.parse(aa, bytes);
    const root = parsed.value;
    if (try J.number(root, "manifestVersion") != 1) return error.UnsupportedSchema;
    if (!std.mem.eql(u8, try J.text(root, "manifestType"), "minecraftModpack")) return error.UnsupportedGame;
    const name = try J.text(root, "name");
    const version = try J.text(root, "version");
    if (!validText(name) or !validText(version)) return error.InvalidPackVersion;
    const minecraft = try J.field(root, "minecraft");
    const game = try J.text(minecraft, "version");
    if (!providers.validToken(game)) return error.InvalidMinecraftVersion;
    const raw_loaders = try J.array(try J.field(minecraft, "modLoaders"));
    if (raw_loaders.len > 1) return error.AmbiguousLoader;
    var loader: config.Loader = .vanilla;
    var loader_version: ?[]const u8 = null;
    if (raw_loaders.len == 1) {
        const id = try J.text(raw_loaders[0], "id");
        _ = try J.boolean(try J.field(raw_loaders[0], "primary"));
        inline for (.{ .{ "forge-", config.Loader.forge }, .{ "neoforge-", config.Loader.neoforge }, .{ "fabric-", config.Loader.fabric }, .{ "quilt-", config.Loader.quilt } }) |entry| {
            if (std.mem.startsWith(u8, id, entry[0])) {
                loader = entry[1];
                loader_version = id[entry[0].len..];
            }
        }
        if (loader == .vanilla) return error.UnknownRequiredDependency;
        if (!providers.validToken(loader_version.?)) return error.InvalidLoaderVersion;
    }
    const raw_files = try J.array(try J.field(root, "files"));
    const refs = try aa.alloc(PackReference, raw_files.len);
    for (raw_files, refs, 0..) |f, *out, i| {
        const project = try J.number(f, "projectID");
        const file = try J.number(f, "fileID");
        if (project == 0 or file == 0 or project > std.math.maxInt(i32) or file > std.math.maxInt(i32)) return error.InvalidContentId;
        out.* = .{ .project_id = try std.fmt.allocPrint(aa, "{d}", .{project}), .file_id = try std.fmt.allocPrint(aa, "{d}", .{file}), .required = try J.boolean(try J.field(f, "required")) };
        for (refs[0..i]) |other| if (std.mem.eql(u8, other.project_id, out.project_id)) return error.DuplicateContent;
    }
    const overrides = try J.text(root, "overrides");
    try checkedPath(overrides);
    const layers = try aa.alloc([]const u8, 1);
    layers[0] = overrides;
    const value: PackPlan = .{ .identity = try cloneInto(PackIdentity, aa, identity), .name = name, .version = version, .minecraft_version = game, .loader = loader, .loader_version = loader_version, .unresolved = refs, .override_layers = layers };
    return .{ .arena = arena, .value = value };
}

/// Attach supplied fixture metadata. Caller owns source plans/versions; output
/// owns every string. Unknown required IDs remain unresolved, not successful.
pub fn resolveCurseForgePack(a: std.mem.Allocator, pack: PackPlan, versions: []const providers.Version) !Owned(PackPlan) {
    return resolveCurseForgePackMode(a, pack, versions, null);
}
pub fn resolveCurseForgePackAuthorized(a: std.mem.Allocator, pack: PackPlan, versions: []const providers.Version, policy: providers.RemotePolicy) !Owned(PackPlan) {
    if (!policy.enabled) return error.ProviderDisabled;
    return resolveCurseForgePackMode(a, pack, versions, policy);
}
fn resolveCurseForgePackMode(a: std.mem.Allocator, pack: PackPlan, versions: []const providers.Version, policy: ?providers.RemotePolicy) !Owned(PackPlan) {
    if (pack.identity.provider != .curseforge) return error.ProviderMismatch;
    try validateIdentity(pack.identity);
    try validateInstallFiles(pack.files);
    if (versions.len > providers.max_items or pack.unresolved.len > providers.max_items) return error.TooManyItems;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();
    var result = try cloneInto(PackPlan, aa, pack);
    var files: std.ArrayList(InstallFile) = .empty;
    var unresolved: std.ArrayList(PackReference) = .empty;
    try files.appendSlice(aa, result.files);
    for (result.unresolved) |ref| {
        var found: ?providers.Version = null;
        for (versions) |v| if (v.provider == .curseforge and std.mem.eql(u8, v.project_id, ref.project_id) and std.mem.eql(u8, v.id, ref.file_id)) {
            if (found != null) return error.AmbiguousVersion;
            found = v;
        };
        if (found) |v| {
            if (!providers.compatible(v, .{ .minecraft_version = result.minecraft_version, .loader = result.loader })) return error.IncompatibleVersion;
            if (v.files.len != 1) return error.AmbiguousFiles;
            const f = v.files[0];
            if (!config.validId(f.filename)) return error.UnsafeFilename;
            const base_page = if (f.download == .remote) remote: {
                try providers.validateRemoteAuthorization(v.provider, v.project_id, v.id, f, policy orelse return error.ProviderDisabled);
                break :remote f.authorization.?.official_page;
            } else manual: {
                const page = f.download.manual_required.official_page;
                const marker = std.mem.lastIndexOf(u8, page, "/files/") orelse return error.UnsafeOfficialPage;
                if (!providers.officialCurseForgePage(page[0..marker]) or !std.mem.eql(u8, page[marker + "/files/".len ..], v.id)) return error.UnsafeOfficialPage;
                break :manual page[0..marker];
            };
            const directory = if (std.mem.startsWith(u8, base_page, "https://www.curseforge.com/minecraft/mc-mods/")) "mods" else if (std.mem.startsWith(u8, base_page, "https://www.curseforge.com/minecraft/texture-packs/")) "resourcepacks" else return error.UnsupportedProjectType;
            const record: ManagedFile = .{ .path = try std.fmt.allocPrint(aa, "{s}/{s}", .{ directory, f.filename }), .provider = .curseforge, .project_id = ref.project_id, .version_id = ref.file_id, .hashes = f.hashes, .size = f.size, .identity_provenance = .official_file, .standalone = false };
            const install: InstallFile = .{ .record = record, .download = f.download, .authorization = f.authorization, .required = ref.required, .selected = ref.selected };
            try files.append(aa, try cloneInto(InstallFile, aa, install));
        } else try unresolved.append(aa, ref);
    }
    result.files = try files.toOwnedSlice(aa);
    result.unresolved = try unresolved.toOwnedSlice(aa);
    try validateInstallFiles(result.files);
    return .{ .arena = arena, .value = result };
}

pub const LocalFile = struct { hashes: providers.Hashes, size: u64, regular: bool = true };
pub const Probe = struct {
    context: ?*anyopaque,
    /// Return actual hashes of the selected/staged local file, not its filename.
    inspect: *const fn (?*anyopaque, []const u8) anyerror!?LocalFile,
};
pub const CompletionPrerequisites = struct {
    overrides_processed: bool = false,
    dependencies_resolved: bool = false,
    loader_ready: bool = false,
};
pub const Completeness = struct {
    complete: bool,
    verified_files: usize,
    missing_required: usize,
    missing_manual: usize,
    hash_mismatches: usize,
    undecided_optional: usize,
    unresolved_references: usize,
};
pub fn checkCompleteness(pack: PackPlan, probe: Probe, prerequisites: CompletionPrerequisites) !Completeness {
    try validateInstallFiles(pack.files);
    if (pack.unresolved.len > providers.max_items) return error.TooManyItems;
    var result: Completeness = .{ .complete = false, .verified_files = 0, .missing_required = 0, .missing_manual = 0, .hash_mismatches = 0, .undecided_optional = 0, .unresolved_references = 0 };
    for (pack.unresolved) |ref| {
        if (!ref.required and ref.selected == false) continue;
        result.unresolved_references += 1;
        if (!ref.required and ref.selected == null) result.undecided_optional += 1;
    }
    for (pack.files) |file| {
        if (!file.required) {
            if (file.selected == null) {
                result.undecided_optional += 1;
                continue;
            }
            if (!file.selected.?) continue;
        }
        if (try probe.inspect(probe.context, file.record.path)) |actual| {
            if (!actual.regular or !providers.hashesMatch(file.record.hashes, actual.hashes) or (file.record.size != null and file.record.size.? != actual.size)) result.hash_mismatches += 1 else result.verified_files += 1;
        } else {
            result.missing_required += 1;
            if (file.download == .manual_required) result.missing_manual += 1;
        }
    }
    result.complete = prerequisites.overrides_processed and prerequisites.dependencies_resolved and prerequisites.loader_ready and result.missing_required == 0 and result.hash_mismatches == 0 and result.undecided_optional == 0 and result.unresolved_references == 0;
    return result;
}

pub const InstanceGuard = struct { instance_id: []const u8, running: bool };
pub const ObservedFile = struct { path: []const u8, hashes: ?providers.Hashes, size: u64, regular: bool = true };
pub const ConflictReason = enum { modified_managed, unmanaged, unknown_hash };
pub const ConflictChoice = enum { keep_local, replace };
pub const ConflictDecision = struct { path: []const u8, choice: ConflictChoice };
pub const Conflict = struct { path: []const u8, reason: ConflictReason, choice: ?ConflictChoice = null };
pub const ActionKind = enum { backup, install, remove, toggle };
pub const Action = struct {
    kind: ActionKind,
    path: []const u8,
    /// Recheck the exact observed value before executing, not just the old manifest.
    expected_before: ?providers.Hashes = null,
    expected_size: ?u64 = null,
    desired: ?ManagedFile = null,
    /// Exact persisted ownership and state, rechecked by the executor.
    previous: ?ManagedFile = null,
};
pub const UpdatePlan = struct {
    actions: []const Action,
    conflicts: []const Conflict,
    next_manifest: Manifest,
    ready: bool,
    /// False for keep_local overrides. Ready means decisions made, not installed.
    fully_applied: bool,
};

/// An explicit local state override never approves replacing modified bytes.
pub fn buildEnabledPlan(a: std.mem.Allocator, previous: Manifest, path: []const u8, enabled: bool, observed: []const ObservedFile, instance_guard: InstanceGuard) !Owned(UpdatePlan) {
    try validate(previous);
    const old = findManaged(previous.files, path) orelse return error.UnmanagedFile;
    if (!std.mem.eql(u8, old.path, path)) return error.PathCaseChanged;
    if (!toggleable(old)) return error.UnsupportedEnabledState;
    const actual = for (observed) |file| {
        if (std.mem.eql(u8, file.path, path)) break file;
    } else return error.LocalFileChanged;
    if (!observedMatches(old, actual)) return error.LocalFileChanged;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const files = try arena.allocator().dupe(ManagedFile, previous.files);
    for (files) |*file| if (std.mem.eql(u8, file.path, path)) {
        file.enabled = enabled;
        break;
    };
    var desired = previous;
    desired.files = files;
    return buildUpdatePlan(a, previous, desired, observed, &.{}, instance_guard);
}

/// Pure transaction plan: no filesystem reads, downloads or writes. Each backup
/// must durably finish before its install/remove; manifest publication is last.
/// Executor must stage+verify all downloads, hold the instance guard, recheck
/// observations, reject symlinks, and rollback on failure/cancel. Never use this
/// plan's ready bit as an installation-complete signal.
pub fn buildUpdatePlan(a: std.mem.Allocator, previous: Manifest, desired: Manifest, observed: []const ObservedFile, decisions: []const ConflictDecision, instance_guard: InstanceGuard) !Owned(UpdatePlan) {
    try validate(previous);
    try validate(desired);
    if (instance_guard.running) return error.InstanceRunning;
    if (!std.mem.eql(u8, instance_guard.instance_id, previous.instance_id) or !std.mem.eql(u8, instance_guard.instance_id, desired.instance_id)) return error.InstanceMismatch;
    if (observed.len > providers.max_items or decisions.len > providers.max_items) return error.TooManyItems;
    for (observed, 0..) |file, i| {
        if (!safeRelativePath(file.path)) return error.UnsafeRelativePath;
        if (file.hashes) |h| try providers.validateHashes(h);
        for (observed[0..i]) |other| if (pathsCollide(file.path, other.path)) return error.PathCollision;
    }
    for (decisions, 0..) |decision, i| {
        try checkedPath(decision.path);
        if (findManaged(previous.files, decision.path) == null and findManaged(desired.files, decision.path) == null) return error.InvalidDecision;
        for (decisions[0..i]) |other| if (std.ascii.eqlIgnoreCase(decision.path, other.path)) return error.DuplicateDecision;
    }
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();
    var builder: UpdateBuilder = .{ .a = aa, .observed = observed, .decisions = decisions };
    for (desired.files) |new| {
        const old = findManaged(previous.files, new.path);
        if (old) |f| if (!std.mem.eql(u8, f.path, new.path)) return error.PathCaseChanged;
        try builder.change(old, new);
    }
    for (previous.files) |old| if (findManaged(desired.files, old.path) == null) try builder.change(old, null);
    const next_files = try builder.files.toOwnedSlice(aa);
    const membership = try survivingMembership(aa, previous, desired, next_files, builder.ready and builder.fully_applied);
    const next: Manifest = .{ .schema_version = if (previous.schema_version == schema_version) schema_version else desired.schema_version, .instance_id = desired.instance_id, .pack_version = desired.pack_version, .files = next_files, .pack_membership = membership };
    try validate(next);
    const plan: UpdatePlan = .{ .actions = try builder.actions.toOwnedSlice(aa), .conflicts = try builder.conflicts.toOwnedSlice(aa), .next_manifest = next, .ready = builder.ready, .fully_applied = builder.ready and builder.fully_applied };
    const value = try cloneInto(UpdatePlan, aa, plan);
    return .{ .arena = arena, .value = value };
}
fn survivingMembership(a: std.mem.Allocator, previous: Manifest, desired: Manifest, files: []const ManagedFile, complete: bool) !?PackMembership {
    const source = if (complete) desired else previous;
    const membership = source.pack_membership orelse return null;
    var paths: std.ArrayList([]const u8) = .empty;
    for (membership.paths) |path| {
        const old = findManaged(source.files, path).?;
        const current = findManaged(files, path) orelse continue;
        if (current.provider != old.provider or current.identity_provenance != old.identity_provenance or
            !std.mem.eql(u8, current.project_id, old.project_id) or !std.mem.eql(u8, current.version_id, old.version_id) or
            !providers.hashesMatch(old.hashes, current.hashes) or !providers.hashesMatch(current.hashes, old.hashes) or
            current.size != old.size or current.role != old.role or current.enabled != old.enabled or current.standalone != old.standalone) continue;
        try paths.append(a, path);
    }
    if (paths.items.len == 0) return null;
    return .{ .identity = membership.identity, .paths = try paths.toOwnedSlice(a) };
}
fn findManaged(files: []const ManagedFile, path: []const u8) ?ManagedFile {
    for (files) |file| if (std.ascii.eqlIgnoreCase(file.path, path)) return file;
    return null;
}
const UpdateBuilder = struct {
    a: std.mem.Allocator,
    observed: []const ObservedFile,
    decisions: []const ConflictDecision,
    files: std.ArrayList(ManagedFile) = .empty,
    actions: std.ArrayList(Action) = .empty,
    conflicts: std.ArrayList(Conflict) = .empty,
    ready: bool = true,
    fully_applied: bool = true,
    fn change(self: *UpdateBuilder, old: ?ManagedFile, new: ?ManagedFile) !void {
        const path = if (new) |f| f.path else old.?.path;
        var actual: ?ObservedFile = null;
        for (self.observed) |file| {
            if (std.ascii.eqlIgnoreCase(file.path, path)) {
                if (!std.mem.eql(u8, file.path, path)) return error.PathCaseChanged;
                if (!file.regular) return error.UnsafeObservedFile;
                actual = file;
            } else if (pathsCollide(file.path, path)) return error.PathCollision;
        }
        if (actual) |local| {
            if (old) |prior| if (new) |f| if (observedMatches(f, local)) {
                if (prior.enabled != f.enabled) {
                    if (!observedMatches(prior, local)) return error.LocalFileChanged;
                    const backup: Action = .{ .kind = .backup, .path = path, .expected_before = local.hashes, .expected_size = local.size };
                    try self.actions.append(self.a, backup);
                    try self.actions.append(self.a, .{ .kind = .toggle, .path = path, .expected_before = local.hashes, .expected_size = local.size, .previous = prior, .desired = f });
                }
                try self.files.append(self.a, f);
                return;
            };
            const clean = if (old) |f| observedMatches(f, local) else false;
            if (!clean) {
                var decision: ?ConflictChoice = null;
                for (self.decisions) |d| if (std.ascii.eqlIgnoreCase(d.path, path)) {
                    decision = d.choice;
                    break;
                };
                const reason: ConflictReason = if (old == null) .unmanaged else if (local.hashes == null) .unknown_hash else .modified_managed;
                try self.conflicts.append(self.a, .{ .path = path, .reason = reason, .choice = decision });
                if (decision == null) {
                    self.ready = false;
                    if (old) |f| try self.files.append(self.a, f);
                    return;
                }
                if (decision.? == .keep_local) {
                    self.fully_applied = false;
                    if (old) |f| try self.files.append(self.a, f);
                    return;
                }
                if (old == null) return error.UnmanagedReplacement;
                if (local.hashes == null) return error.UnknownLocalHash;
            }
            const before: Action = .{ .kind = .backup, .path = path, .expected_before = local.hashes, .expected_size = local.size };
            try self.actions.append(self.a, before);
            try self.actions.append(self.a, .{ .kind = if (new != null) .install else .remove, .path = path, .expected_before = local.hashes, .expected_size = local.size, .desired = new, .previous = old });
        } else if (new) |f| try self.actions.append(self.a, .{ .kind = .install, .path = path, .desired = f });
        if (new) |f| try self.files.append(self.a, f);
    }
};
fn observedMatches(file: ManagedFile, observed: ObservedFile) bool {
    return observed.regular and providers.hashesMatch(file.hashes, observed.hashes orelse return false) and (file.size == null or file.size.? == observed.size);
}

const testing = std.testing;
const sha1_a = "0000000000000000000000000000000000000000";
const sha1_b = "1111111111111111111111111111111111111111";
const sha512_a = "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
const mrpack_fixture =
    \\{"formatVersion":1,"game":"minecraft","versionId":"release-1","name":"Fixture Pack","dependencies":{"minecraft":"1.20.1","fabric-loader":"0.15.0"},"files":[{"path":"mods/a.jar","hashes":{"sha1":"0000000000000000000000000000000000000000","sha512":"00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"},"downloads":["https://cdn.modrinth.com/a.jar"],"fileSize":3},{"path":"mods/optional.jar","hashes":{"sha1":"0000000000000000000000000000000000000000","sha512":"00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"},"env":{"client":"optional","server":"unsupported"},"downloads":["https://github.com/project/file.jar"],"fileSize":3}]}
;
const cfpack_fixture =
    \\{"manifestVersion":1,"manifestType":"minecraftModpack","name":"Fixture Pack","version":"1.0","minecraft":{"version":"1.20.1","modLoaders":[{"id":"fabric-0.15.0","primary":true}]},"files":[{"projectID":12,"fileID":34,"required":true}],"overrides":"overrides"}
;
const mr_identity: PackIdentity = .{ .provider = .modrinth, .project_id = "pack", .version_id = "version1" };
const cf_identity: PackIdentity = .{ .provider = .curseforge, .project_id = "1", .version_id = "2" };
fn managed(path: []const u8, hash: []const u8, version: []const u8) ManagedFile {
    return .{ .path = path, .provider = .modrinth, .project_id = "P1", .version_id = version, .hashes = .{ .sha1 = hash }, .size = 3, .role = roleFor(path) };
}
fn manifest(files: []const ManagedFile, version: []const u8) Manifest {
    return .{ .instance_id = "instance", .pack_version = version, .files = files };
}
fn observedFile(path: []const u8, hash: []const u8) ObservedFile {
    return .{ .path = path, .hashes = .{ .sha1 = hash }, .size = 3 };
}
const guard: InstanceGuard = .{ .instance_id = "instance", .running = false };

test "portable paths reject traversal devices collisions protected saves and schema" {
    for ([_][]const u8{ "../mods/a.jar", "/mods/a.jar", "C:/mods/a.jar", "mods\\a.jar", "mods//a.jar", "mods/CON.jar", "mods/a./b", "mods/a /b", "mods/./a.jar" }) |path| try testing.expect(!safeRelativePath(path));
    try testing.expect(safeRelativePath("mods/Unicode.jar"));
    try testing.expect(pathsCollide("Mods/A.jar", "mods/a.jar"));
    try testing.expect(pathsCollide("config/folder", "CONFIG/folder/file"));
    try testing.expect(!pathsCollide("mods/a", "mods/abc"));
    try testing.expectError(error.ProtectedPath, validate(manifest(&.{managed("SAVES/world/level.dat", sha1_a, "v1")}, "v1")));
    try testing.expectError(error.PathCollision, validate(manifest(&.{ managed("mods/A.jar", sha1_a, "v1"), managed("mods/a.jar", sha1_a, "v1") }, "v1")));
    try testing.expectError(error.UnsupportedSchema, parse(testing.allocator, "{\"schema_version\":3,\"future_key\":true}"));
    try testing.expectError(error.MissingField, parse(testing.allocator, "{}"));
}
fn exerciseManifest(a: std.mem.Allocator) !void {
    const original = manifest(&.{managed("mods/a.jar", sha1_a, "v1")}, "v1");
    const bytes = try serialize(a, original);
    defer a.free(bytes);
    var result = try parse(a, bytes);
    defer result.deinit();
    try testing.expectEqualStrings("mods/a.jar", result.value.files[0].path);
}
test "manifest roundtrip owns strings omits null fields rejects unknown fields and OOM" {
    const bytes = try serialize(testing.allocator, manifest(&.{managed("mods/a.jar", sha1_a, "v1")}, "v1"));
    defer testing.allocator.free(bytes);
    var result = try parse(testing.allocator, bytes);
    defer result.deinit();
    @memset(bytes, 'x');
    try testing.expectEqualStrings("instance", result.value.instance_id);
    const encoded = try serialize(testing.allocator, result.value);
    defer testing.allocator.free(encoded);
    try testing.expect(std.mem.indexOf(u8, encoded, "null") == null);
    try testing.expectError(error.UnknownField, parse(testing.allocator, "{\"schema_version\":1,\"instance_id\":\"instance\",\"pack_version\":\"v1\",\"secret\":\"not-allowed\"}"));
    try testing.checkAllAllocationFailures(testing.allocator, exerciseManifest, .{});
}
fn exercisePacks(a: std.mem.Allocator) !void {
    var mr = try parseMrpack(a, mrpack_fixture, mr_identity, .client);
    defer mr.deinit();
    var cf = try parseCurseForgePack(a, cfpack_fixture, cf_identity);
    defer cf.deinit();
    var resolved = try resolveCurseForgePack(a, cf.value, &.{});
    defer resolved.deinit();
}
test "mrpack environment loaders and CurseForge refs remain explicit" {
    var mr = try parseMrpack(testing.allocator, mrpack_fixture, mr_identity, .client);
    defer mr.deinit();
    try testing.expectEqual(config.Loader.fabric, mr.value.loader);
    try testing.expectEqualStrings("0.15.0", mr.value.loader_version.?);
    try testing.expectEqual(@as(usize, 2), mr.value.files.len);
    try testing.expect(!mr.value.files[1].required and mr.value.files[1].selected == null);
    try testing.expectEqualStrings("client-overrides", mr.value.override_layers[1]);
    var server = try parseMrpack(testing.allocator, mrpack_fixture, mr_identity, .server);
    defer server.deinit();
    try testing.expectEqual(@as(usize, 1), server.value.files.len);
    var cf = try parseCurseForgePack(testing.allocator, cfpack_fixture, cf_identity);
    defer cf.deinit();
    try testing.expectEqual(@as(usize, 1), cf.value.unresolved.len);
    try testing.expectEqualStrings("34", cf.value.unresolved[0].file_id);
    try testing.expectEqual(@as(usize, 0), cf.value.files.len);
    try testing.checkAllAllocationFailures(testing.allocator, exercisePacks, .{});
}
fn replacedFixture(a: std.mem.Allocator, input: []const u8, from: []const u8, to: []const u8) ![]u8 {
    const index = std.mem.indexOf(u8, input, from) orelse unreachable;
    return std.mem.concat(a, u8, &.{ input[0..index], to, input[index + from.len ..] });
}
test "pack malformed bounds traversal unknown dependencies invalid hosts and collisions" {
    const cases = [_]struct { from: []const u8, to: []const u8, expected: anyerror }{
        .{ .from = "mods/a.jar", .to = "../a.jar", .expected = error.UnsafeRelativePath },
        .{ .from = "mods/a.jar", .to = "saves/a.jar", .expected = error.ProtectedPath },
        .{ .from = "mods/optional.jar", .to = "Mods/A.jar", .expected = error.PathCollision },
        .{ .from = "fabric-loader", .to = "future-loader", .expected = error.UnknownRequiredDependency },
        .{ .from = "https://cdn.modrinth.com/a.jar", .to = "https://evil.invalid/a.jar", .expected = error.UnapprovedDownloadHost },
        .{ .from = "\"client\":\"optional\"", .to = "\"client\":\"nonsense\"", .expected = error.InvalidEnvironment },
        .{ .from = "\"fileSize\":3", .to = "\"fileSize\":-1", .expected = error.InvalidNumber },
        .{ .from = "\"formatVersion\":1", .to = "\"formatVersion\":2", .expected = error.UnsupportedSchema },
    };
    for (cases) |case| {
        const bytes = try replacedFixture(testing.allocator, mrpack_fixture, case.from, case.to);
        defer testing.allocator.free(bytes);
        try testing.expectError(case.expected, parseMrpack(testing.allocator, bytes, mr_identity, .client));
    }
    try testing.expectError(error.InvalidResponse, parseCurseForgePack(testing.allocator, "[]", cf_identity));
    const ambiguous = try replacedFixture(testing.allocator, mrpack_fixture, "\"fabric-loader\":\"0.15.0\"", "\"fabric-loader\":\"0.15.0\",\"forge\":\"1.0\"");
    defer testing.allocator.free(ambiguous);
    try testing.expectError(error.AmbiguousLoader, parseMrpack(testing.allocator, ambiguous, mr_identity, .client));
}
const FixtureProbe = struct {
    mode: enum { missing, valid, mismatch, size_mismatch, symlink } = .missing,
    fn inspect(ctx: ?*anyopaque, _: []const u8) !?LocalFile {
        const self: *FixtureProbe = @ptrCast(@alignCast(ctx.?));
        if (self.mode == .missing) return null;
        return .{ .hashes = .{ .sha1 = if (self.mode == .mismatch) sha1_b else sha1_a, .sha512 = sha512_a }, .size = if (self.mode == .size_mismatch) 4 else 3, .regular = self.mode != .symlink };
    }
};
const ready_prerequisites: CompletionPrerequisites = .{ .overrides_processed = true, .dependencies_resolved = true, .loader_ready = true };
const manual_pack: PackPlan = .{ .identity = cf_identity, .name = "Fixture", .version = "1", .minecraft_version = "1.20.1", .files = &.{.{ .record = managed("mods/a.jar", sha1_a, "v1"), .download = .{ .manual_required = .{ .official_page = "https://www.curseforge.com/minecraft/mc-mods/example/files/34", .reason = .distribution_disabled } } }} };
test "manual missing or hash mismatch never complete and prerequisite gates" {
    var fixture: FixtureProbe = .{};
    const probe: Probe = .{ .context = &fixture, .inspect = FixtureProbe.inspect };
    const pack = manual_pack;
    const missing = try checkCompleteness(pack, probe, ready_prerequisites);
    try testing.expect(!missing.complete and missing.missing_manual == 1 and missing.missing_required == 1);
    fixture.mode = .mismatch;
    const mismatch = try checkCompleteness(pack, probe, ready_prerequisites);
    try testing.expect(!mismatch.complete and mismatch.hash_mismatches == 1);
    fixture.mode = .size_mismatch;
    try testing.expect(!(try checkCompleteness(pack, probe, ready_prerequisites)).complete);
    fixture.mode = .symlink;
    try testing.expect(!(try checkCompleteness(pack, probe, ready_prerequisites)).complete);
    fixture.mode = .valid;
    try testing.expect((try checkCompleteness(pack, probe, ready_prerequisites)).complete);
    try testing.expect(!(try checkCompleteness(pack, probe, .{})).complete);
    var cf = try parseCurseForgePack(testing.allocator, cfpack_fixture, cf_identity);
    defer cf.deinit();
    try testing.expect(!(try checkCompleteness(cf.value, probe, ready_prerequisites)).complete);
    var mr = try parseMrpack(testing.allocator, mrpack_fixture, mr_identity, .client);
    defer mr.deinit();
    const undecided = try checkCompleteness(mr.value, probe, ready_prerequisites);
    try testing.expect(!undecided.complete and undecided.undecided_optional == 1);
}
fn exerciseUpdate(a: std.mem.Allocator) !void {
    const previous = manifest(&.{ managed("mods/a.jar", sha1_a, "v1"), managed("config/modified.cfg", sha1_a, "v1") }, "v1");
    const desired = manifest(&.{ managed("mods/a.jar", sha1_b, "v2"), managed("config/modified.cfg", sha1_b, "v2") }, "v2");
    var plan = try buildUpdatePlan(a, previous, desired, &.{ observedFile("mods/a.jar", sha1_a), observedFile("config/modified.cfg", sha1_b), observedFile("mods/user.jar", sha1_a), observedFile("saves/world/level.dat", sha1_a) }, &.{}, guard);
    defer plan.deinit();
    try testing.expect(plan.value.ready);
    try testing.expectEqual(@as(usize, 2), plan.value.actions.len);
    try testing.expectEqual(ActionKind.backup, plan.value.actions[0].kind);
    try testing.expectEqual(ActionKind.install, plan.value.actions[1].kind);
}
test "update only managed files backup first preserves unmanaged mods and saves OOM" {
    try exerciseUpdate(testing.allocator);
    try testing.checkAllAllocationFailures(testing.allocator, exerciseUpdate, .{});
    const old = manifest(&.{managed("mods/a.jar", sha1_a, "v1")}, "v1");
    const new = manifest(&.{managed("mods/a.jar", sha1_b, "v2")}, "v2");
    var plan = try buildUpdatePlan(testing.allocator, old, new, &.{observedFile("mods/a.jar", sha1_a)}, &.{}, guard);
    defer plan.deinit();
    try testing.expectEqualStrings("v2", plan.value.next_manifest.files[0].version_id);
    try testing.expect(plan.value.fully_applied);
    try testing.expectError(error.InstanceRunning, buildUpdatePlan(testing.allocator, old, new, &.{}, &.{}, .{ .instance_id = "instance", .running = true }));
    try testing.expectError(error.InstanceMismatch, buildUpdatePlan(testing.allocator, old, new, &.{}, &.{}, .{ .instance_id = "other", .running = false }));
}
test "modified configuration explicit choices keep local metadata or backup replacement" {
    const old = manifest(&.{managed("config/custom.cfg", sha1_a, "v1")}, "v1");
    const new = manifest(&.{managed("config/custom.cfg", sha1_b, "v2")}, "v2");
    const local = ObservedFile{ .path = "config/custom.cfg", .hashes = .{ .sha1 = "2222222222222222222222222222222222222222" }, .size = 3 };
    var unresolved = try buildUpdatePlan(testing.allocator, old, new, &.{local}, &.{}, guard);
    defer unresolved.deinit();
    try testing.expect(!unresolved.value.ready and unresolved.value.actions.len == 0);
    try testing.expectEqual(ConflictReason.modified_managed, unresolved.value.conflicts[0].reason);
    var keep = try buildUpdatePlan(testing.allocator, old, new, &.{local}, &.{.{ .path = local.path, .choice = .keep_local }}, guard);
    defer keep.deinit();
    try testing.expect(keep.value.ready and !keep.value.fully_applied and keep.value.actions.len == 0);
    try testing.expectEqualStrings("v1", keep.value.next_manifest.files[0].version_id);
    var replace = try buildUpdatePlan(testing.allocator, old, new, &.{local}, &.{.{ .path = local.path, .choice = .replace }}, guard);
    defer replace.deinit();
    try testing.expect(replace.value.ready and replace.value.actions.len == 2);
    try testing.expectEqualStrings(local.hashes.?.sha1.?, replace.value.actions[0].expected_before.?.sha1.?);
    try testing.expectEqual(ActionKind.backup, replace.value.actions[0].kind);
}
test "managed removal uses backup and modified removal requires a decision" {
    const old = manifest(&.{managed("mods/a.jar", sha1_a, "v1")}, "v1");
    const empty = manifest(&.{}, "v2");
    var clean = try buildUpdatePlan(testing.allocator, old, empty, &.{observedFile("mods/a.jar", sha1_a)}, &.{}, guard);
    defer clean.deinit();
    try testing.expectEqual(ActionKind.backup, clean.value.actions[0].kind);
    try testing.expectEqual(ActionKind.remove, clean.value.actions[1].kind);
    var modified = try buildUpdatePlan(testing.allocator, old, empty, &.{observedFile("mods/a.jar", sha1_b)}, &.{}, guard);
    defer modified.deinit();
    try testing.expect(!modified.value.ready);
}
test "unmanaged desired target stays unmanaged even identical hashes and explicit replace rejects" {
    const empty = manifest(&.{}, "v1");
    const desired = manifest(&.{managed("mods/user.jar", sha1_a, "v2")}, "v2");
    const actual = observedFile("mods/user.jar", sha1_a);
    var plan = try buildUpdatePlan(testing.allocator, empty, desired, &.{actual}, &.{}, guard);
    defer plan.deinit();
    try testing.expect(!plan.value.ready and plan.value.conflicts[0].reason == .unmanaged and plan.value.actions.len == 0);
    try testing.expectError(error.UnmanagedReplacement, buildUpdatePlan(testing.allocator, empty, desired, &.{actual}, &.{.{ .path = actual.path, .choice = .replace }}, guard));
    var keep = try buildUpdatePlan(testing.allocator, empty, desired, &.{actual}, &.{.{ .path = actual.path, .choice = .keep_local }}, guard);
    defer keep.deinit();
    try testing.expect(keep.value.ready and !keep.value.fully_applied and keep.value.next_manifest.files.len == 0);
}
test "update rejects unknown hashes symlinks prefix collisions and stale invalid decisions" {
    const old = manifest(&.{managed("mods/a.jar", sha1_a, "v1")}, "v1");
    const desired = manifest(&.{managed("mods/a.jar", sha1_b, "v2")}, "v2");
    try testing.expectError(error.UnsafeObservedFile, buildUpdatePlan(testing.allocator, old, desired, &.{.{ .path = "mods/a.jar", .hashes = .{ .sha1 = sha1_a }, .size = 3, .regular = false }}, &.{}, guard));
    try testing.expectError(error.UnknownLocalHash, buildUpdatePlan(testing.allocator, old, desired, &.{.{ .path = "mods/a.jar", .hashes = null, .size = 3 }}, &.{.{ .path = "mods/a.jar", .choice = .replace }}, guard));
    try testing.expectError(error.PathCollision, buildUpdatePlan(testing.allocator, old, desired, &.{observedFile("mods", sha1_a)}, &.{}, guard));
    try testing.expectError(error.PathCaseChanged, buildUpdatePlan(testing.allocator, old, desired, &.{observedFile("Mods/A.jar", sha1_a)}, &.{}, guard));
    try testing.expectError(error.InvalidDecision, buildUpdatePlan(testing.allocator, old, desired, &.{}, &.{.{ .path = "mods/other.jar", .choice = .replace }}, guard));
}

fn exerciseResolvedPack(a: std.mem.Allocator) !void {
    const file: providers.File = .{ .filename = "a.jar", .hashes = .{ .sha1 = sha1_a }, .size = 3, .primary = true, .download = .{ .manual_required = .{ .official_page = "https://www.curseforge.com/minecraft/mc-mods/example/files/34", .reason = .distribution_disabled } } };
    const v: providers.Version = .{ .provider = .curseforge, .project_id = "12", .id = "34", .name = "fixture", .minecraft_versions = &.{"1.20.1"}, .loaders = &.{"fabric"}, .files = &.{file}, .dependencies = &.{} };
    var result = blk: {
        var cf = try parseCurseForgePack(a, cfpack_fixture, cf_identity);
        defer cf.deinit();
        break :blk try resolveCurseForgePack(a, cf.value, &.{v});
    };
    defer result.deinit();
    try testing.expect(result.value.unresolved.len == 0 and result.value.files.len == 1);
    try testing.expectEqualStrings("mods/a.jar", result.value.files[0].record.path);
    // Source owner is gone; the complete resolved plan remains independently owned.
    try testing.expectEqualStrings("https://www.curseforge.com/minecraft/mc-mods/example/files/34", result.value.files[0].download.manual_required.official_page);
}
fn exerciseConflicts(a: std.mem.Allocator) !void {
    const old = manifest(&.{managed("config/local.cfg", sha1_a, "v1")}, "v1");
    const new = manifest(&.{managed("config/local.cfg", sha1_b, "v2")}, "v2");
    const actual: ObservedFile = .{ .path = "config/local.cfg", .hashes = .{ .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }, .size = 3 };
    var undecided = try buildUpdatePlan(a, old, new, &.{actual}, &.{}, guard);
    defer undecided.deinit();
    try testing.expect(!undecided.value.ready and undecided.value.conflicts[0].choice == null);
    var keep = try buildUpdatePlan(a, old, new, &.{actual}, &.{.{ .path = actual.path, .choice = .keep_local }}, guard);
    defer keep.deinit();
    var replace = try buildUpdatePlan(a, old, new, &.{actual}, &.{.{ .path = actual.path, .choice = .replace }}, guard);
    defer replace.deinit();
    try testing.expect(replace.value.actions[0].expected_before.?.sha256 != null);
}
test "resolved pack and all conflict clone paths own memory under OOM" {
    try exerciseResolvedPack(testing.allocator);
    try exerciseConflicts(testing.allocator);
    try testing.checkAllAllocationFailures(testing.allocator, exerciseResolvedPack, .{});
    try testing.checkAllAllocationFailures(testing.allocator, exerciseConflicts, .{});
}
test "manifest and pack count and string size bounds" {
    const files = try testing.allocator.alloc(ManagedFile, providers.max_items + 1);
    defer testing.allocator.free(files);
    try testing.expectError(error.TooManyItems, validate(manifest(files, "v1")));
    const large_path = try testing.allocator.alloc(u8, max_path_bytes + 1);
    defer testing.allocator.free(large_path);
    @memset(large_path, 'a');
    try testing.expect(!safeRelativePath(large_path));
    const bytes = try testing.allocator.alloc(u8, providers.max_json_bytes + 1);
    defer testing.allocator.free(bytes);
    try testing.expectError(error.ResponseTooLarge, parse(testing.allocator, bytes));
    try testing.expectError(error.ResponseTooLarge, parseMrpack(testing.allocator, bytes, mr_identity, .client));
    try testing.expectError(error.ResponseTooLarge, parseCurseForgePack(testing.allocator, bytes, cf_identity));
}

fn exerciseModernReceipt(a: std.mem.Allocator) !void {
    var file = managed("mods/a.jar", sha1_a, "v1");
    file.identity_provenance = .official_file;
    file.standalone = false;
    const document: Manifest = .{ .schema_version = 2, .instance_id = "instance", .pack_version = "v1", .files = &.{file}, .pack_membership = .{ .identity = mr_identity, .paths = &.{file.path} } };
    const bytes = try serialize(a, document);
    defer a.free(bytes);
    var parsed = try parse(a, bytes);
    defer parsed.deinit();
    try testing.expectEqual(@as(u32, 2), parsed.value.schema_version);
    try testing.expectEqual(IdentityProvenance.official_file, parsed.value.files[0].identity_provenance);
    try testing.expectEqualStrings("P1", parsed.value.files[0].project_id);
    try testing.expectEqualStrings("pack", parsed.value.pack_membership.?.identity.project_id);
    var paths = try packReplacementPaths(a, parsed.value, .{ .provider = .modrinth, .project_id = "pack", .version_id = "version2" });
    defer paths.deinit();
    try testing.expectEqualStrings(file.path, paths.value[0]);
}
test "strict v2 receipt roundtrip and allocation failures preserve real child identity" {
    try exerciseModernReceipt(testing.allocator);
    try testing.checkAllAllocationFailures(testing.allocator, exerciseModernReceipt, .{});
    try testing.expectError(error.UnknownField, parse(testing.allocator, "{\"schema_version\":2,\"instance_id\":\"instance\",\"pack_version\":\"v2\",\"authorization\":{}}"));
    try testing.expectError(error.UnknownField, parse(testing.allocator, "{\"schema_version\":1,\"instance_id\":\"instance\",\"pack_version\":\"v1\",\"pack_membership\":null}"));
    var promoted = managed("mods/a.jar", sha1_a, "v1");
    promoted.identity_provenance = .official_file;
    try testing.expectError(error.ReceiptUpgradeRequired, serialize(testing.allocator, manifest(&.{promoted}, "v1")));
}
fn exerciseLegacyApproval(a: std.mem.Allocator) !void {
    const prior = manifest(&.{managed("mods/old.jar", sha1_a, "recorded-pack-version")}, "display-version");
    const bytes = try serialize(a, prior);
    defer a.free(bytes);
    var parsed = try parse(a, bytes);
    defer parsed.deinit();
    const file = parsed.value.files[0];
    try testing.expectEqual(IdentityProvenance.legacy_unknown, file.identity_provenance);
    try testing.expect(file.standalone and parsed.value.pack_membership == null);
    try testing.expectEqualStrings("recorded-pack-version", file.version_id);
    const identity: PackIdentity = .{ .provider = .modrinth, .project_id = "P1", .version_id = "recorded-pack-version" };
    var approved = try legacyReplacementPaths(a, parsed.value, identity, &.{.{ .path = file.path, .expected_hashes = file.hashes, .expected_size = file.size }});
    defer approved.deinit();
    try testing.expectEqual(@as(usize, 1), approved.value.len);
    const desired = manifest(&.{managed("mods/new.jar", sha1_b, "fresh-file-version")}, "new-display");
    var plan = try buildUpdatePlan(a, prior, desired, &.{observedFile(file.path, sha1_a)}, &.{}, guard);
    defer plan.deinit();
    try testing.expect(plan.value.ready and plan.value.fully_applied);
    try testing.expectEqual(@as(usize, 3), plan.value.actions.len);
}
test "strict legacy read literal tuples and exact approval allow explicit reviewed updates" {
    try exerciseLegacyApproval(testing.allocator);
    try testing.checkAllAllocationFailures(testing.allocator, exerciseLegacyApproval, .{});
    const old = manifest(&.{managed("mods/old.jar", sha1_a, "v1")}, "v1");
    const identity: PackIdentity = .{ .provider = .modrinth, .project_id = "P1", .version_id = "v1" };
    try testing.expectError(error.StaleLegacyApproval, legacyReplacementPaths(testing.allocator, old, identity, &.{.{ .path = "mods/old.jar", .expected_hashes = .{ .sha1 = sha1_b }, .expected_size = 3 }}));
    try testing.expectError(error.StaleLegacyApproval, legacyReplacementPaths(testing.allocator, old, identity, &.{.{ .path = "mods/old.jar", .expected_hashes = .{ .sha1 = sha1_a }, .expected_size = 4 }}));
    var unapproved = try legacyReplacementPaths(testing.allocator, old, identity, &.{});
    defer unapproved.deinit();
    try testing.expectEqual(@as(usize, 0), unapproved.value.len);
}
test "MR archive membership permits obsolete removal without inventing official child IDs" {
    var pack = try parseMrpack(testing.allocator, mrpack_fixture, mr_identity, .client);
    defer pack.deinit();
    var proof = try membershipForPack(testing.allocator, pack.value);
    defer proof.deinit();
    const file = pack.value.files[0].record;
    try testing.expectEqual(IdentityProvenance.pack_archive, file.identity_provenance);
    try testing.expectEqualStrings(mr_identity.project_id, file.project_id);
    try testing.expectEqual(@as(usize, 1), proof.value.paths.len);
    const prior: Manifest = .{ .schema_version = 2, .instance_id = "instance", .pack_version = "old", .files = &.{file}, .pack_membership = proof.value };
    var removals = try packReplacementPaths(testing.allocator, prior, .{ .provider = .modrinth, .project_id = "pack", .version_id = "new" });
    defer removals.deinit();
    try testing.expectEqualStrings(file.path, removals.value[0]);
    const next: Manifest = .{ .schema_version = 2, .instance_id = "instance", .pack_version = "new" };
    var plan = try buildUpdatePlan(testing.allocator, prior, next, &.{.{ .path = file.path, .hashes = file.hashes, .size = file.size.? }}, &.{}, guard);
    defer plan.deinit();
    try testing.expect(plan.value.actions.len == 2 and plan.value.actions[1].kind == .remove);
    try testing.expect(plan.value.next_manifest.pack_membership == null);
}
test "CF pack membership retains true file IDs and standalone members need separate review" {
    var pack = try parseCurseForgePack(testing.allocator, cfpack_fixture, cf_identity);
    defer pack.deinit();
    const file: providers.File = .{ .filename = "a.jar", .hashes = .{ .sha1 = sha1_a }, .size = 3, .download = .{ .manual_required = .{ .official_page = "https://www.curseforge.com/minecraft/mc-mods/example/files/34", .reason = .distribution_disabled } } };
    const version: providers.Version = .{ .provider = .curseforge, .project_id = "12", .id = "34", .name = "fixture", .minecraft_versions = &.{"1.20.1"}, .loaders = &.{"fabric"}, .files = &.{file}, .dependencies = &.{} };
    var resolved = try resolveCurseForgePack(testing.allocator, pack.value, &.{version});
    defer resolved.deinit();
    var proof = try membershipForPack(testing.allocator, resolved.value);
    defer proof.deinit();
    var record = resolved.value.files[0].record;
    try testing.expectEqualStrings("12", record.project_id);
    try testing.expectEqualStrings("34", record.version_id);
    try testing.expectEqual(IdentityProvenance.official_file, record.identity_provenance);
    record.standalone = true;
    const prior: Manifest = .{ .schema_version = 2, .instance_id = "instance", .pack_version = "old", .files = &.{record}, .pack_membership = proof.value };
    var removals = try packReplacementPaths(testing.allocator, prior, cf_identity);
    defer removals.deinit();
    try testing.expectEqual(@as(usize, 0), removals.value.len);
    var legacy = record;
    legacy.identity_provenance = .legacy_unknown;
    var invalid = prior;
    invalid.files = &.{legacy};
    try testing.expectError(error.UnverifiedPackMember, validate(invalid));
}
test "partial keep-local receipt retains prior ownership without claiming a new pack version" {
    var old = managed("config/local.cfg", sha1_a, "version1");
    old.project_id = "pack";
    old.identity_provenance = .pack_archive;
    old.standalone = false;
    var fresh = old;
    fresh.version_id = "version2";
    fresh.hashes.sha1 = sha1_b;
    const prior: Manifest = .{ .schema_version = 2, .instance_id = "instance", .pack_version = "old", .files = &.{old}, .pack_membership = .{ .identity = mr_identity, .paths = &.{old.path} } };
    const next: Manifest = .{ .schema_version = 2, .instance_id = "instance", .pack_version = "new", .files = &.{fresh}, .pack_membership = .{ .identity = .{ .provider = .modrinth, .project_id = "pack", .version_id = "version2" }, .paths = &.{fresh.path} } };
    var plan = try buildUpdatePlan(testing.allocator, prior, next, &.{observedFile(old.path, "2222222222222222222222222222222222222222")}, &.{.{ .path = old.path, .choice = .keep_local }}, guard);
    defer plan.deinit();
    try testing.expect(plan.value.ready and !plan.value.fully_applied);
    try testing.expectEqualStrings("version1", plan.value.next_manifest.pack_membership.?.identity.version_id);
    try testing.expectEqualStrings("version1", plan.value.next_manifest.files[0].version_id);
}

fn exerciseAuthorizedCFPack(a: std.mem.Allocator) !void {
    var pack = try parseCurseForgePack(a, cfpack_fixture, cf_identity);
    defer pack.deinit();
    const hosts: []const []const u8 = &.{"edge.forgecdn.net"};
    const url = "https://edge.forgecdn.net/files/34/a.jar";
    const proof: providers.RemoteAuthorization = .{ .project_id = "12", .file_id = "34", .filename = "a.jar", .url = url, .sha1 = sha1_a, .size = 3, .official_page = "https://www.curseforge.com/minecraft/mc-mods/example", .distribution_allowed = true, .available = true, .approved_download_hosts = hosts };
    const file: providers.File = .{ .filename = "a.jar", .hashes = .{ .sha1 = sha1_a }, .size = 3, .download = .{ .remote = url }, .authorization = proof };
    const version: providers.Version = .{ .provider = .curseforge, .project_id = "12", .id = "34", .name = "fixture", .minecraft_versions = &.{"1.20.1"}, .loaders = &.{"fabric"}, .files = &.{file}, .dependencies = &.{} };
    var resolved = try resolveCurseForgePackAuthorized(a, pack.value, &.{version}, .{ .enabled = true, .approved_download_hosts = hosts });
    defer resolved.deinit();
    try testing.expect(resolved.value.files[0].authorization != null);
    try testing.expectEqualStrings("12", resolved.value.files[0].record.project_id);
    var membership = try membershipForPack(a, resolved.value);
    defer membership.deinit();
    const bytes = try serialize(a, .{ .schema_version = 2, .instance_id = "instance", .pack_version = "v2", .files = &.{resolved.value.files[0].record}, .pack_membership = membership.value });
    defer a.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "authorization") == null and std.mem.indexOf(u8, bytes, "forgecdn.net") == null);
}
test "authorized CF pack preserves transient proof but receipts never authorize later downloads" {
    try exerciseAuthorizedCFPack(testing.allocator);
    try testing.checkAllAllocationFailures(testing.allocator, exerciseAuthorizedCFPack, .{});
}

test "managed mod enabled state has canonical physical paths and reserved counterparts" {
    const a = testing.allocator;
    const hashes: providers.Hashes = .{ .sha256 = "0000000000000000000000000000000000000000000000000000000000000000" };
    const file: ManagedFile = .{ .path = "mods/state.jar", .provider = .modrinth, .project_id = "project", .version_id = "v1", .hashes = hashes, .size = 3, .identity_provenance = .official_file };
    var disabled = file;
    disabled.enabled = false;
    const enabled_path = try physicalPath(a, file);
    defer a.free(enabled_path);
    const disabled_path = try physicalPath(a, disabled);
    defer a.free(disabled_path);
    try testing.expectEqualStrings("mods/state.jar", enabled_path);
    try testing.expectEqualStrings("mods/state.jar.disabled", disabled_path);
    const document: Manifest = .{ .schema_version = 2, .instance_id = "instance", .pack_version = "local", .files = &.{disabled} };
    const bytes = try serialize(a, document);
    defer a.free(bytes);
    var parsed = try parse(a, bytes);
    defer parsed.deinit();
    try testing.expectEqualStrings(file.path, parsed.value.files[0].path);
    try testing.expect(!parsed.value.files[0].enabled);
    for ([_][]const u8{ "mods/STATE.jar.disabled", "mods/state.jar.disabled/child" }) |path| {
        var collision = file;
        collision.path = path;
        try testing.expectError(error.PathCollision, validate(.{ .schema_version = 2, .instance_id = "instance", .pack_version = "local", .files = &.{ file, collision } }));
    }
    for ([_][]const u8{ "resourcepacks/state.jar", "config/state.jar", "mods/state.zip", "assets/state.jar", "mods/state.jar.disabled" }) |path| {
        var unsupported = disabled;
        unsupported.path = path;
        try testing.expect(!toggleable(unsupported));
        try testing.expectError(if (protectedPath(path)) error.ProtectedPath else error.UnsupportedEnabledState, physicalPath(a, unsupported));
    }
    var resource = file;
    resource.role = .configuration;
    try testing.expect(!toggleable(resource));
    var override = file;
    override.role = .override;
    override.identity_provenance = .pack_override;
    override.standalone = false;
    try testing.expect(toggleable(override));
}

test "enabled state plan preserves receipts and rejects unsafe or unowned requests" {
    const a = testing.allocator;
    const hashes: providers.Hashes = .{ .sha256 = "0000000000000000000000000000000000000000000000000000000000000000" };
    const file: ManagedFile = .{ .path = "mods/state.jar", .provider = .modrinth, .project_id = "project", .version_id = "v1", .hashes = hashes, .size = 3, .identity_provenance = .official_file };
    const previous: Manifest = .{ .schema_version = 2, .instance_id = "instance", .pack_version = "local", .files = &.{file} };
    const observed = [_]ObservedFile{.{ .path = file.path, .hashes = hashes, .size = 3 }};
    const instance_state_guard: InstanceGuard = .{ .instance_id = "instance", .running = false };
    var off = try buildEnabledPlan(a, previous, file.path, false, &observed, instance_state_guard);
    defer off.deinit();
    try testing.expect(off.value.ready);
    try testing.expectEqual(@as(usize, 2), off.value.actions.len);
    try testing.expectEqual(ActionKind.backup, off.value.actions[0].kind);
    try testing.expectEqual(ActionKind.toggle, off.value.actions[1].kind);
    try testing.expectEqualDeep(file, off.value.actions[1].previous.?);
    var expected = file;
    expected.enabled = false;
    try testing.expectEqualDeep(expected, off.value.next_manifest.files[0]);
    var again = try buildEnabledPlan(a, off.value.next_manifest, file.path, false, &observed, instance_state_guard);
    defer again.deinit();
    try testing.expectEqual(@as(usize, 0), again.value.actions.len);
    try testing.expectError(error.UnmanagedFile, buildEnabledPlan(a, previous, "mods/user.jar", false, &observed, instance_state_guard));
    try testing.expectError(error.PathCaseChanged, buildEnabledPlan(a, previous, "mods/STATE.jar", false, &observed, instance_state_guard));
    try testing.expectError(error.LocalFileChanged, buildEnabledPlan(a, previous, file.path, false, &.{}, instance_state_guard));
    const changed = [_]ObservedFile{.{ .path = file.path, .hashes = hashes, .size = 4 }};
    try testing.expectError(error.LocalFileChanged, buildEnabledPlan(a, previous, file.path, false, &changed, instance_state_guard));
    const unsafe = [_]ObservedFile{.{ .path = file.path, .hashes = hashes, .size = 3, .regular = false }};
    try testing.expectError(error.LocalFileChanged, buildEnabledPlan(a, previous, file.path, false, &unsafe, instance_state_guard));
    try testing.expectError(error.InstanceRunning, buildEnabledPlan(a, previous, file.path, false, &observed, .{ .instance_id = "instance", .running = true }));
    try testing.expectError(error.InstanceMismatch, buildEnabledPlan(a, previous, file.path, false, &observed, .{ .instance_id = "another", .running = false }));
}

const std = @import("std");
const loaders = @import("loaders.zig");
const c = @import("loaders_common.zig");
const files = @import("loaders_files.zig");
const serde = @import("loaders_json.zig");
const java_process = @import("loaders_java_process.zig");
const m = @import("metadata/root.zig");
const json = @import("metadata/json.zig");
const metadata_loader = @import("metadata_loader.zig");
const plan_module = @import("install_plan.zig");
const http = @import("../http_transport.zig");
const instances = @import("../instances.zig");
const namespace = @import("../instance_namespace.zig");
const tree = @import("../worlds_tree.zig");
const A = std.mem.Allocator;
const max_file = 512 * 1024 * 1024;
const max_artifact_bindings = 4096;
const max_receipt_bytes = 8 * 1024 * 1024;

/// The caller holds the launch/world-mutation exclusion from acquire to release.
/// recheck must use the same exclusion, not an unrelated running-state snapshot.
/// RecoveryRequired retains this exclusion; the caller must resolve publication before release.
pub const Lease = struct {
    context: ?*anyopaque = null,
    acquire: *const fn (?*anyopaque, []const u8) anyerror!void,
    recheck: *const fn (?*anyopaque, []const u8) anyerror!void,
    release: *const fn (?*anyopaque, []const u8) void,
};
pub const Options = struct {
    root: []const u8,
    instance_id: []const u8,
    instance_name: []const u8,
    selection: loaders.Selection,
    /// A successfully installed, independently resolved and verified vanilla base.
    base: ?m.version.Version = null,
    base_plan: ?plan_module.Plan = null,
    /// Optional private vanilla stage, contained under launcher root and opened nofollow.
    base_directory: ?[]const u8 = null,
    environment: m.rules.Environment,
    java: ?[]const u8 = null,
    lease: Lease,
    /// Borrowed reservations are validated and never released by this operation.
    namespace_token: ?namespace.Token = null,
    /// Worker admission may wait for the short namespace stamp gate.
    worker_checks: bool = false,
    http_options: http.Options = .{},
    /// Optional metadata/artifact fixture transport; production uses shared HTTP.
    transport: ?loaders.Transport = null,
};
pub const JavaRequirements = loaders.recipes.JavaRequirements;
/// Final coordinator identity: launcher root and final name, never a private stage.
pub const MetadataTarget = struct {
    root: []const u8,
    instance_id: []const u8,
    instance_name: []const u8,
    generation: u64,
    selection: loaders.Selection,
    environment: m.rules.Environment,
};
pub const MetadataOptions = struct {
    root: []const u8,
    instance_id: []const u8,
    instance_name: []const u8,
    generation: u64,
    selection: loaders.Selection,
    environment: m.rules.Environment,
    vanilla: metadata_loader.Options,
    fetcher: metadata_loader.Fetcher = .{},
    namespace_token: ?namespace.Token = null,
    worker_checks: bool = false,
    http_options: http.Options = .{},
    transport: ?loaders.Transport = null,
};
const SourceBinding = struct { id: []const u8, url: []const u8, sha1: m.Sha1, bytes: []const u8 };

/// Move-only owner. Treat fields as immutable; opaque rule matcher context must
/// outlive this owner and installation, as with the existing Options contract.
pub const PreparedMetadata = struct {
    arena: *std.heap.ArenaAllocator,
    backing: A,
    root: []const u8,
    instance_id: []const u8,
    instance_name: []const u8,
    generation: u64 = 0,
    selection: loaders.Selection,
    environment: m.rules.Environment,
    base: m.Owned(m.version.Version),
    catalog: m.Owned(loaders.Catalog),
    source_bytes: []const u8,
    bundle: loaders.recipes.Bundle,
    requirements: JavaRequirements,
    vanilla_sources: []const SourceBinding = &.{},
    replay_digest: [32]u8,

    pub fn deinit(self: *PreparedMetadata) void {
        self.base.deinit();
        self.catalog.deinit();
        self.arena.deinit();
        self.backing.destroy(self.arena);
        self.* = undefined;
    }

    pub fn validate(self: *const PreparedMetadata, a: A, io: std.Io, options: Options) !void {
        try self.validateBinding(a, io, .{ .root = options.root, .instance_id = options.instance_id, .instance_name = options.instance_name, .generation = self.generation, .selection = options.selection, .environment = options.environment });
        const base = options.base orelse return error.BaseNotInstalled;
        const original = try serde.serialize(a, self.base.value);
        defer a.free(original);
        const current = try serde.serialize(a, base);
        defer a.free(current);
        if (!std.mem.eql(u8, original, current)) return error.PreparedBaseChanged;
    }
    pub fn validateBinding(self: *const PreparedMetadata, a: A, io: std.Io, target: MetadataTarget) !void {
        if (target.generation == 0 or target.generation != self.generation) return error.PreparedMetadataGenerationMismatch;
        var paths = try instances.Paths.init(a, io, target.root);
        defer paths.deinit();
        const root = try normalized(a, paths.root);
        defer a.free(root);
        if (!std.mem.eql(u8, root, self.root) or
            !std.mem.eql(u8, target.instance_id, self.instance_id) or
            !std.mem.eql(u8, target.instance_name, self.instance_name) or
            !sameSelection(target.selection, self.selection) or
            !sameEnvironment(target.environment, self.environment)) return error.PreparedMetadataMismatch;
        const digest = try metadataDigest(a, self);
        if (!std.mem.eql(u8, &digest, &self.replay_digest)) return error.PreparedMetadataChanged;
    }

    pub fn replayBase(self: *const PreparedMetadata, a: A, io: std.Io, target: MetadataTarget, control: loaders.Control) !metadata_loader.Loaded {
        try control.check();
        try self.validateBinding(a, io, target);
        const canonical = try serde.serialize(a, self.base.value);
        defer a.free(canonical);
        var version = try m.version.parseSlice(a, canonical);
        errdefer version.deinit();
        const arena = try c.arena(a);
        errdefer {
            arena.deinit();
            a.destroy(arena);
        }
        const g = arena.allocator();
        const sources = try g.alloc(metadata_loader.Source, self.vanilla_sources.len);
        for (self.vanilla_sources, sources) |source, *copy| {
            try control.check();
            copy.* = .{ .id = try g.dupe(u8, source.id), .bytes = try g.dupe(u8, source.bytes) };
        }
        try control.check();
        return .{ .version = version, .sources = .{ .arena = arena, .backing = a, .value = sources } };
    }
};

fn reserveNamespace(io: std.Io, borrowed: ?namespace.Token, worker: bool) !namespace.Token {
    if (borrowed) |token| {
        if (worker) try token.recheckWaiting() else try token.recheck();
        return token;
    }
    return if (worker) namespace.acquireWaiting(io) else namespace.acquire(io);
}

/// No JVM, game installation, or final publication. Only private temporary ZIP
/// extraction is permitted; the returned owner retains bytes, not scratch paths.
pub fn prepareMetadata(a: A, io: std.Io, options: MetadataOptions, control: loaders.Control) !PreparedMetadata {
    const token = try reserveNamespace(io, options.namespace_token, options.worker_checks);
    // Runs after metadata stage removal, all closes and cancellation restoration.
    defer if (options.namespace_token == null) token.release();
    try control.check();
    if (options.generation == 0) return error.InvalidPreparationGeneration;
    try c.id(options.instance_id);
    try m.version.validateId(options.instance_name);
    if (options.selection.side != .client) return error.ClientInstallationRequired;
    if (!std.mem.eql(u8, options.vanilla.version_id, options.selection.base_id)) return error.BaseVersionMismatch;
    var paths = try instances.Paths.init(a, io, options.root);
    defer paths.deinit();
    var vanilla_paths = try instances.Paths.init(a, io, options.vanilla.root);
    defer vanilla_paths.deinit();
    if (!std.mem.eql(u8, vanilla_paths.root, paths.minecraft)) return error.PreparedMetadataMismatch;
    const minecraft = try normalized(a, paths.minecraft);
    defer a.free(minecraft);
    try control.check();
    var fetch: VanillaFetch = .{ .fetcher = options.fetcher, .control = control };
    var loaded = try metadata_loader.loadTrusted(a, io, options.vanilla, .{ .context = &fetch, .fetch = VanillaFetch.get });
    defer loaded.deinit();
    try control.check();
    const versions = try c.join(a, minecraft, "versions");
    defer a.free(versions);
    const parent = try files.directory(io, versions, true);
    defer parent.close(io);
    var random: [16]u8 = undefined;
    io.random(&random);
    const name = try std.fmt.allocPrint(a, ".metadata-{s}", .{std.fmt.bytesToHex(&random, .lower)});
    defer a.free(name);
    const stage = try c.join(a, versions, name);
    defer a.free(stage);
    const directory = try tree.child(io, parent, name, true);
    directory.close(io);
    var cleanup_needed = true;
    defer if (cleanup_needed) {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        parent.deleteTree(io, name) catch {};
    };
    var prepared = try acquireMetadata(a, io, .{
        .root = paths.root,
        .instance_id = options.instance_id,
        .instance_name = options.instance_name,
        .selection = options.selection,
        .environment = options.environment,
        .http_options = options.http_options,
        .transport = options.transport,
    }, loaded.version.value, stage, control);
    errdefer prepared.deinit();
    prepared.generation = options.generation;
    const g = prepared.arena.allocator();
    const bindings = try g.alloc(SourceBinding, loaded.sources.value.len);
    const manifest = options.vanilla.manifest orelse return error.MissingVersionMetadata;
    for (loaded.sources.value, bindings) |source, *binding| {
        try control.check();
        const entry = manifest.find(source.id) orelse return error.MissingVersionMetadata;
        binding.* = .{ .id = try g.dupe(u8, source.id), .url = try g.dupe(u8, entry.url), .sha1 = entry.sha1 orelse return error.MissingMetadataChecksum, .bytes = try g.dupe(u8, source.bytes) };
    }
    prepared.vanilla_sources = bindings;
    prepared.replay_digest = try metadataDigest(a, &prepared);
    try control.check();
    {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        try parent.deleteTree(io, name);
        cleanup_needed = false;
    }
    try control.check();
    return prepared;
}

const VanillaFetch = struct {
    fetcher: metadata_loader.Fetcher,
    control: loaders.Control,
    fn get(raw: ?*anyopaque, a: A, io: std.Io, request: metadata_loader.Request) ![]u8 {
        const self: *VanillaFetch = @ptrCast(@alignCast(raw.?));
        try self.control.check();
        const callback = self.fetcher.fetch orelse return error.MissingVersionMetadata;
        const bytes = try callback(self.fetcher.context, a, io, request);
        errdefer a.free(bytes);
        try self.control.check();
        return bytes;
    }
};
const AcquisitionOptions = struct {
    root: []const u8,
    instance_id: []const u8,
    instance_name: []const u8,
    selection: loaders.Selection,
    environment: m.rules.Environment,
    http_options: http.Options,
    transport: ?loaders.Transport,
    client: ?*http.Client = null,
};
const MetadataFetch = struct {
    client: ?*http.Client,
    transport: ?loaders.Transport,
    fn get(raw: ?*anyopaque, a: A, url: []const u8, max: usize, control: loaders.Control) !loaders.Response {
        const self: *MetadataFetch = @ptrCast(@alignCast(raw.?));
        return fetchResponse(a, self.client, self.transport, url, max, control);
    }
};

fn acquireMetadata(a: A, io: std.Io, options: AcquisitionOptions, base: m.version.Version, stage: []const u8, control: loaders.Control) !PreparedMetadata {
    try control.check();
    const arena = try c.arena(a);
    errdefer {
        arena.deinit();
        a.destroy(arena);
    }
    const g = arena.allocator();
    const base_bytes = try serde.serialize(g, base);
    var base_owner = try m.version.parseSlice(a, base_bytes);
    errdefer base_owner.deinit();
    var client: ?http.Client = if (options.transport == null and options.client == null) try http.Client.init(a, io, options.http_options) else null;
    defer if (client) |*value| value.deinit();
    var fetch: MetadataFetch = .{ .client = options.client orelse if (client) |*value| value else null, .transport = options.transport };
    const transport: loaders.Transport = .{ .context = &fetch, .get = MetadataFetch.get };
    var catalog = try loaders.fetchCatalog(a, transport, options.selection.kind, options.selection.base_id, control);
    errdefer catalog.deinit();
    const selection: loaders.Selection = .{ .kind = options.selection.kind, .side = options.selection.side, .base_id = try g.dupe(u8, options.selection.base_id), .loader_id = try g.dupe(u8, options.selection.loader_id) };
    const entry = try catalog.value.validate(selection);
    const source = try transport.get(transport.context, g, entry.url, max_file, control);
    var bundle: loaders.recipes.Bundle = .{ .source_url = try g.dupe(u8, entry.url), .profile = source.bytes };
    if (selection.kind == .forge or selection.kind == .neoforge) {
        const checksum = try transport.get(transport.context, g, try std.fmt.allocPrint(g, "{s}.sha1", .{entry.url}), 4096, control);
        bundle.installer_sha1 = try c.sha1(std.mem.trim(u8, checksum.bytes, " \r\n\t"));
        try c.verify(source.bytes, bundle.installer_sha1.?);
        const archive = try c.join(g, stage, ".prepare/installer.jar");
        try files.write(io, archive, source.bytes, control);
        const extracted = try c.join(g, stage, ".prepare/archive");
        try files.extract(a, io, archive, extracted, control);
        bundle.profile = try files.read(g, io, try c.join(g, extracted, "install_profile.json"), 8 * 1024 * 1024, control);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, bundle.profile, .{ .max_value_len = 8 * 1024 * 1024 });
        defer parsed.deinit();
        const object = try json.object(parsed.value);
        if (object.get("json")) |value| {
            const member = std.mem.trimStart(u8, try c.text(value), "/");
            try c.relative(member);
            bundle.version_json = try files.read(g, io, try c.join(g, extracted, member), 8 * 1024 * 1024, control);
        }
    }
    const environment = try ownEnvironment(g, options.environment);
    const name = try g.dupe(u8, options.instance_name);
    var recipe = try loaders.prepare(a, catalog.value, selection, base_owner.value, bundle, .{ .instance_name = name, .stage_root = stage, .environment = environment });
    defer recipe.deinit();
    if (recipe.value.artifacts.len > max_artifact_bindings) return error.ResourceLimit;
    var result: PreparedMetadata = .{
        .arena = arena,
        .backing = a,
        .root = try normalized(g, options.root),
        .instance_id = try g.dupe(u8, options.instance_id),
        .instance_name = name,
        .selection = selection,
        .environment = environment,
        .base = base_owner,
        .catalog = catalog,
        .source_bytes = source.bytes,
        .bundle = bundle,
        .requirements = loaders.recipes.javaRequirements(recipe.value),
        .replay_digest = undefined,
    };
    result.replay_digest = try metadataDigest(a, &result);
    try control.check();
    return result;
}

fn ownEnvironment(a: A, value: m.rules.Environment) !m.rules.Environment {
    const features = try a.alloc(m.rules.Feature, value.features.len);
    for (features, value.features) |*out, feature| out.* = .{ .name = try a.dupe(u8, feature.name), .enabled = feature.enabled };
    return .{ .os_name = try a.dupe(u8, value.os_name), .arch = try a.dupe(u8, value.arch), .os_version = try a.dupe(u8, value.os_version), .features = features, .version_matcher = value.version_matcher };
}
fn sameSelection(a: loaders.Selection, b: loaders.Selection) bool {
    return a.kind == b.kind and a.side == b.side and std.mem.eql(u8, a.base_id, b.base_id) and std.mem.eql(u8, a.loader_id, b.loader_id);
}
fn sameEnvironment(a: m.rules.Environment, b: m.rules.Environment) bool {
    if (!std.mem.eql(u8, a.os_name, b.os_name) or !std.mem.eql(u8, a.arch, b.arch) or
        !std.mem.eql(u8, a.os_version, b.os_version) or !std.meta.eql(a.version_matcher, b.version_matcher) or a.features.len != b.features.len) return false;
    for (a.features, b.features) |left, right| if (left.enabled != right.enabled or !std.mem.eql(u8, left.name, right.name)) return false;
    return true;
}
fn digestField(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    hash.update(&digest);
}
fn metadataDigest(a: A, value: *const PreparedMetadata) ![32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    digestField(&hash, "vela-prepared-metadata-v1");
    for ([_][]const u8{ value.root, value.instance_id, value.instance_name, @tagName(value.selection.kind), @tagName(value.selection.side), value.selection.base_id, value.selection.loader_id, value.environment.os_name, value.environment.arch, value.environment.os_version, value.source_bytes, value.bundle.source_url, value.bundle.profile }) |bytes| digestField(&hash, bytes);
    digestField(&hash, if (value.bundle.version_json != null) "present" else "absent");
    digestField(&hash, value.bundle.version_json orelse "");
    if (value.bundle.installer_sha1) |checksum| digestField(&hash, &checksum) else digestField(&hash, "no-checksum");
    digestField(&hash, std.mem.asBytes(&value.environment.features.len));
    for (value.environment.features) |feature| {
        digestField(&hash, feature.name);
        digestField(&hash, if (feature.enabled) "true" else "false");
    }
    if (value.environment.version_matcher) |matcher| {
        digestField(&hash, "matcher");
        const context: usize = if (matcher.context) |pointer| @intFromPtr(pointer) else 0;
        const callback: usize = @intFromPtr(matcher.matches);
        digestField(&hash, std.mem.asBytes(&context));
        digestField(&hash, std.mem.asBytes(&callback));
    } else digestField(&hash, "no-matcher");
    const base = try serde.serialize(a, value.base.value);
    defer a.free(base);
    digestField(&hash, base);
    const catalog = try std.json.Stringify.valueAlloc(a, value.catalog.value, .{});
    defer a.free(catalog);
    digestField(&hash, catalog);
    digestField(&hash, std.mem.asBytes(&value.vanilla_sources.len));
    for (value.vanilla_sources) |binding| {
        digestField(&hash, binding.id);
        digestField(&hash, binding.url);
        digestField(&hash, &binding.sha1);
        digestField(&hash, binding.bytes);
    }
    digestField(&hash, std.mem.asBytes(&value.generation));
    digestField(&hash, std.mem.asBytes(&value.requirements.runtime_major));
    digestField(&hash, std.mem.asBytes(&value.requirements.installer_major));
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

pub const Installed = struct {
    arena: std.heap.ArenaAllocator,
    instance_id: []const u8,
    instance_name: []const u8,
    version_document: []const u8,
    game_directory: []const u8,
    loader_version: []const u8,
    game_java_major: u64,
    durability_uncertain: bool = false,
    pub fn deinit(self: *Installed) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Official profiles/installers only. No installer Java is fetched or executed
/// until catalog compatibility, profile provenance and installer SHA1 are proven.
/// https://meta.fabricmc.net/ and https://meta.quiltmc.org/openapi.yaml
/// https://github.com/MinecraftForge/Installer/blob/2.0/src/main/java/net/minecraftforge/installer/actions/PostProcessors.java
pub fn install(a: A, io: std.Io, options: Options, control: loaders.Control) !Installed {
    return installCore(a, io, options, null, control);
}

/// Borrows the move-only prepared owner for this entire synchronous operation.
/// This entry point executes Java when required; prepareMetadata never does.
pub fn installPrepared(a: A, io: std.Io, options: Options, prepared: *const PreparedMetadata, generation: u64, control: loaders.Control) !Installed {
    try control.check();
    if (generation == 0 or generation != prepared.generation) return error.PreparedMetadataGenerationMismatch;
    return installCore(a, io, options, prepared, control);
}

fn installCore(a: A, io: std.Io, options: Options, supplied: ?*const PreparedMetadata, control: loaders.Control) !Installed {
    const token = try reserveNamespace(io, options.namespace_token, options.worker_checks);
    defer if (options.namespace_token == null) token.release();
    try control.check();
    if (supplied) |prepared| try prepared.validate(a, io, options);
    try c.id(options.instance_id);
    try m.version.validateId(options.instance_name);
    if (options.selection.side != .client) return error.ClientInstallationRequired;
    const base = options.base orelse return error.BaseNotInstalled;
    const supplied_plan = options.base_plan orelse return error.BaseNotInstalled;
    if (!std.mem.eql(u8, base.id, options.selection.base_id)) return error.BaseVersionMismatch;
    var recovery_required = false;
    try options.lease.acquire(options.lease.context, options.instance_id);
    defer if (!recovery_required) options.lease.release(options.lease.context, options.instance_id);
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const g = arena.allocator();
    const base_plan = try normalizePlan(g, supplied_plan);
    const paths = try instances.Paths.init(g, io, options.root);
    const minecraft = try normalized(g, paths.minecraft);
    const versions = try c.join(g, minecraft, "versions");
    const base_directory = if (options.base_directory) |directory| try normalized(g, directory) else try c.join(g, versions, base.id);
    _ = try within(base_directory, try normalized(g, paths.root));
    const base_dir = try files.directory(io, base_directory, false);
    base_dir.close(io);
    const final_directory = try std.fmt.allocPrint(g, "{s}/{s}", .{ versions, options.instance_name });
    try verifyBase(io, minecraft, base_directory, base, base_plan, control);
    const version_dir = try files.directory(io, versions, true);
    defer version_dir.close(io);
    if (version_dir.statFile(io, options.instance_name, .{ .follow_symlinks = false })) |_| return error.InstanceAlreadyExists else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    var random: [16]u8 = undefined;
    io.random(&random);
    const stage_name = try std.fmt.allocPrint(g, ".loader-{s}", .{std.fmt.bytesToHex(&random, .lower)});
    const stage = try c.join(g, versions, stage_name);
    const stage_dir = try tree.child(io, version_dir, stage_name, true);
    stage_dir.close(io);
    var published = false;
    defer if (!published and !recovery_required) {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        version_dir.deleteTree(io, stage_name) catch {};
    };
    var client = try http.Client.init(a, io, options.http_options);
    defer client.deinit();
    var ctx: Context = .{ .a = a, .g = g, .io = io, .client = &client, .options = options, .base_plan = base_plan, .base_directory = base_directory, .minecraft = minecraft, .versions = versions, .stage = stage, .stage_name = stage_name, .final_directory = final_directory, .control = control, .recovery_required = &recovery_required };
    ctx.options.namespace_token = token;
    var acquired: ?PreparedMetadata = null;
    defer if (acquired) |*prepared| prepared.deinit();
    if (supplied == null) acquired = try acquireMetadata(a, io, .{
        .root = paths.root,
        .instance_id = options.instance_id,
        .instance_name = options.instance_name,
        .selection = options.selection,
        .environment = options.environment,
        .http_options = options.http_options,
        .transport = options.transport,
        .client = &client,
    }, base, stage, control);
    const prepared: *const PreparedMetadata = if (supplied) |value| value else &acquired.?;
    ctx.source_url = prepared.bundle.source_url;
    ctx.source_bytes = prepared.source_bytes;
    ctx.options.base = prepared.base.value;
    var recipe = try loaders.prepare(a, prepared.catalog.value, prepared.selection, prepared.base.value, prepared.bundle, .{
        .instance_name = options.instance_name,
        .stage_root = stage,
        .environment = options.environment,
    });
    defer recipe.deinit();
    if (!std.meta.eql(loaders.recipes.javaRequirements(recipe.value), prepared.requirements)) return error.PreparedMetadataChanged;
    if (recipe.value.artifacts.len > max_artifact_bindings) return error.ResourceLimit;
    var java_major: ?u64 = null;
    if (options.java) |path| java_major = try java_process.probe(a, io, path, control);
    const result_id = try g.dupe(u8, options.instance_id);
    const result_name = try g.dupe(u8, options.instance_name);
    const result_loader = try g.dupe(u8, options.selection.loader_id);
    try loaders.execute(a, recipe.value, ctx.callbacks(), .{ .java = options.java, .java_major = java_major, .max_file_bytes = max_file }, control);
    published = true;
    return .{ .arena = arena, .instance_id = result_id, .instance_name = result_name, .version_document = ctx.version_document.?, .game_directory = final_directory, .loader_version = result_loader, .game_java_major = recipe.value.game_java_major, .durability_uncertain = ctx.durability_uncertain };
}

fn normalized(a: A, path: []const u8) ![]const u8 {
    const result = try a.dupe(u8, path);
    if (@import("builtin").os.tag == .windows) std.mem.replaceScalar(u8, result, '\\', '/');
    try c.stageRoot(result);
    return result;
}
fn within(path: []const u8, root: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, path, root) or path.len <= root.len or path[root.len] != '/') return error.UnsafeBasePath;
    const relative = path[root.len + 1 ..];
    try c.relative(relative);
    return relative;
}
fn verifyBase(io: std.Io, minecraft: []const u8, base_directory: []const u8, base: m.version.Version, plan: plan_module.Plan, control: loaders.Control) !void {
    const client = try clientDownload(base);
    try baseFile(plan.client_path, minecraft, base_directory);
    files.verify(io, plan.client_path, client.sha1 orelse return error.BaseNotInstalled, client.size, max_file, control) catch |err| switch (err) {
        error.FileNotFound => return error.BaseNotInstalled,
        else => return err,
    };
    for (plan.files) |file| {
        try baseFile(file.path, minecraft, base_directory);
        if (file.sha1) |hash| files.verify(io, file.path, hash, file.size, max_file, control) catch |err| switch (err) {
            error.FileNotFound => return error.BaseNotInstalled,
            else => return err,
        };
    }
    for (plan.native_checks) |check| if (check.suitability == .incompatible) return error.IncompatibleNativeArchitecture;
    for (plan.asset_materializations) |asset| {
        _ = try within(asset.source_path, minecraft);
        if (!std.mem.startsWith(u8, asset.destination, minecraft)) _ = try within(asset.destination, base_directory);
        try files.verify(io, asset.source_path, asset.sha1, asset.size, max_file, control);
    }
    for (plan.native_extractions) |native| _ = try within(native.destination, base_directory);
}
fn baseFile(path: []const u8, minecraft: []const u8, base_directory: []const u8) !void {
    _ = within(path, minecraft) catch try within(path, base_directory);
}

const Context = struct {
    a: A,
    g: A,
    io: std.Io,
    client: *http.Client,
    options: Options,
    base_plan: plan_module.Plan,
    base_directory: []const u8,
    minecraft: []const u8,
    versions: []const u8,
    stage: []const u8,
    stage_name: []const u8,
    final_directory: []const u8,
    control: loaders.Control,
    source_url: []const u8 = "",
    source_bytes: []const u8 = "",
    version_document: ?[]const u8 = null,
    recovery_required: *bool,
    durability_uncertain: bool = !tree.directory_sync_supported,
    fn self(raw: ?*anyopaque) *Context {
        return @ptrCast(@alignCast(raw.?));
    }
    fn get(raw: ?*anyopaque, a: A, url: []const u8, max: usize, control: loaders.Control) !loaders.Response {
        return self(raw).fetch(a, url, max, control);
    }
    fn fetch(ctx: *Context, a: A, url: []const u8, max: usize, control: loaders.Control) !loaders.Response {
        return fetchResponse(a, ctx.client, ctx.options.transport, url, max, control);
    }
    fn callbacks(ctx: *Context) loaders.execution.Callbacks {
        return .{ .context = ctx, .begin = begin, .vanilla = vanilla, .download = download, .extract_installer = extract, .copy = copy, .read = read, .main_class = mainClass, .process = process, .commit = commit, .rollback = rollback };
    }
    fn begin(raw: ?*anyopaque, stage: []const u8, control: loaders.Control) !void {
        const ctx = self(raw);
        try control.check();
        if (!std.mem.eql(u8, stage, ctx.stage)) return error.StageMismatch;
    }
    fn vanilla(raw: ?*anyopaque, recipe: loaders.recipes.Recipe, control: loaders.Control) !void {
        const ctx = self(raw);
        const base = ctx.options.base.?;
        const processor_client = try std.fmt.allocPrint(ctx.g, "{s}/versions/{s}/{s}.jar", .{ ctx.stage, base.id, base.id });
        const final_client = try std.fmt.allocPrint(ctx.g, "{s}/{s}.jar", .{ ctx.stage, recipe.instance_name });
        try files.copy(ctx.io, ctx.base_plan.client_path, processor_client, max_file, control);
        try files.copy(ctx.io, ctx.base_plan.client_path, final_client, max_file, control);
        const client = try clientDownload(base);
        try files.verify(ctx.io, processor_client, client.sha1.?, client.size, max_file, control);
        try files.verify(ctx.io, final_client, client.sha1.?, client.size, max_file, control);
        const natives = try files.directory(ctx.io, try c.join(ctx.g, ctx.stage, "natives"), true);
        defer natives.close(ctx.io);
        for (ctx.base_plan.native_extractions) |extraction| {
            _ = try within(extraction.destination, ctx.base_directory);
            const source = try files.directory(ctx.io, extraction.destination, false);
            defer source.close(ctx.io);
            var snapshot = try tree.snapshot(ctx.a, ctx.io, source, natives, .{}, .{ .context = @constCast(&control), .canceled = snapshotCanceled });
            snapshot.deinit();
            break; // vanilla plan coalesces all natives into one destination
        }
        for (ctx.base_plan.asset_materializations) |asset| {
            if (std.mem.startsWith(u8, asset.destination, ctx.base_directory)) {
                const relative = try within(asset.destination, ctx.base_directory);
                try files.copy(ctx.io, asset.source_path, try c.join(ctx.g, ctx.stage, relative), max_file, control);
                try files.verify(ctx.io, try c.join(ctx.g, ctx.stage, relative), asset.sha1, asset.size, max_file, control);
            }
        }
    }
    fn snapshotCanceled(raw: ?*anyopaque) bool {
        const control: *const loaders.Control = @ptrCast(@alignCast(raw.?));
        control.check() catch return true;
        return false;
    }
    fn download(raw: ?*anyopaque, url: []const u8, destination: []const u8, hash: ?m.Sha1, control: loaders.Control) !void {
        const ctx = self(raw);
        _ = try within(destination, ctx.stage);
        if (std.mem.eql(u8, url, ctx.source_url)) {
            if (hash) |expected| try c.verify(ctx.source_bytes, expected);
            return files.write(ctx.io, destination, ctx.source_bytes, control);
        }
        const response = try ctx.fetch(ctx.a, url, max_file, control);
        defer ctx.a.free(response.bytes);
        defer ctx.a.free(response.final_url);
        if (hash) |expected| try c.verify(response.bytes, expected);
        try files.write(ctx.io, destination, response.bytes, control);
    }
    fn extract(raw: ?*anyopaque, source: []const u8, destination: []const u8, control: loaders.Control) !void {
        const ctx = self(raw);
        _ = try within(source, ctx.stage);
        _ = try within(destination, ctx.stage);
        try files.extract(ctx.a, ctx.io, source, destination, control);
    }
    fn copy(raw: ?*anyopaque, source: []const u8, destination: []const u8, control: loaders.Control) !void {
        const ctx = self(raw);
        _ = try within(source, ctx.stage);
        _ = try within(destination, ctx.stage);
        try files.copy(ctx.io, source, destination, max_file, control);
    }
    fn read(raw: ?*anyopaque, a: A, path: []const u8, max: usize, control: loaders.Control) ![]u8 {
        const ctx = self(raw);
        _ = try within(path, ctx.stage);
        return files.read(a, ctx.io, path, max, control);
    }
    fn mainClass(raw: ?*anyopaque, a: A, jar: []const u8, control: loaders.Control) ![]u8 {
        const ctx = self(raw);
        _ = try within(jar, ctx.stage);
        return files.mainClass(a, ctx.io, jar, try c.join(ctx.g, ctx.stage, ".loader/manifests"), control);
    }
    fn process(raw: ?*anyopaque, invocation: loaders.execution.Invocation) !loaders.execution.ProcessResult {
        const ctx = self(raw);
        return java_process.run(ctx.a, ctx.io, invocation);
    }
    fn commit(raw: ?*anyopaque, recipe: loaders.recipes.Recipe) !void {
        const ctx = self(raw);
        // All arena allocations and descriptor writes precede publication.
        var resolved = recipe.version;
        resolved.jar = null;
        resolved.inherits_from = null;
        const metadata = try serde.serialize(ctx.a, resolved);
        defer ctx.a.free(metadata);
        const descriptor = try std.fmt.allocPrint(ctx.g, "{s}/{s}.json", .{ ctx.stage, recipe.instance_name });
        ctx.version_document = try std.fmt.allocPrint(ctx.g, "{s}/{s}.json", .{ ctx.final_directory, recipe.instance_name });
        try files.write(ctx.io, descriptor, metadata, ctx.control);
        var metadata_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(metadata, &metadata_hash, .{});
        const client_jar = try std.fmt.allocPrint(ctx.g, "{s}.jar", .{recipe.instance_name});
        const client = try finalClientBinding(ctx, try c.join(ctx.g, ctx.stage, client_jar));
        const artifact_bindings = try artifactBindings(ctx, recipe);
        const source_hash = recipe.installer_sha1 orelse recipe.source_sha1;
        const receipt = try std.json.Stringify.valueAlloc(ctx.a, .{ .schema_version = @as(u32, 1), .instance_id = ctx.options.instance_id, .instance_name = recipe.instance_name, .minecraft_version = recipe.selection.base_id, .loader = @tagName(recipe.selection.kind), .loader_version = recipe.selection.loader_id, .source_url = recipe.source_url, .source_sha1 = std.fmt.bytesToHex(&source_hash, .lower), .profile_sha1 = std.fmt.bytesToHex(&recipe.source_sha1, .lower), .metadata_sha256 = std.fmt.bytesToHex(&metadata_hash, .lower), .client_sha256 = std.fmt.bytesToHex(&client.sha256, .lower), .client_size = client.size, .client_jar = client_jar, .artifact_bindings = artifact_bindings }, .{});
        defer ctx.a.free(receipt);
        if (receipt.len > max_receipt_bytes) return error.ResourceLimit;
        try files.write(ctx.io, try c.join(ctx.g, ctx.stage, ".vela-loader.json"), receipt, ctx.control);
        // Shared verified artifacts may be cached, but never replaced. Generated
        // artifacts without independent metadata SHA1 remain processor-verified.
        for (recipe.artifacts) |artifact| {
            const source = try c.join(ctx.g, ctx.stage, artifact.path);
            const expected = artifact.sha1 orelse try digestFile(ctx, source);
            try publishLibrary(ctx, source, try c.join(ctx.g, ctx.minecraft, artifact.path), expected, artifact.size);
        }
        const stage_dir = try files.directory(ctx.io, ctx.stage, false);
        defer stage_dir.close(ctx.io);
        try tree.syncDir(ctx.io, stage_dir);
        const version_dir = try files.directory(ctx.io, ctx.versions, false);
        defer version_dir.close(ctx.io);
        try ctx.control.check();
        if (ctx.options.worker_checks) try ctx.options.namespace_token.?.recheckWaiting() else try ctx.options.namespace_token.?.recheck();
        try ctx.options.lease.recheck(ctx.options.lease.context, ctx.options.instance_id);
        // No cancellable operation or fallible allocation follows this boundary.
        const protection = ctx.io.swapCancelProtection(.blocked);
        defer _ = ctx.io.swapCancelProtection(protection);
        version_dir.renamePreserve(ctx.stage_name, version_dir, recipe.instance_name, ctx.io) catch |err| {
            // A surviving exclusively owned source proves the atomic move did not happen.
            if (version_dir.statFile(ctx.io, ctx.stage_name, .{ .follow_symlinks = false })) |stat| {
                if (stat.kind == .directory) return err;
            } else |_| {}
            ctx.recovery_required.* = true;
            return error.RecoveryRequired;
        };
        tree.syncDir(ctx.io, version_dir) catch {
            ctx.durability_uncertain = true;
        };
    }
    fn rollback(_: ?*anyopaque, _: []const u8) void {} // outer owner removes private stage on every error
};
const ArtifactBinding = struct { path: []const u8, sha256: [64]u8, size: u64 };
fn artifactBindings(ctx: *Context, recipe: loaders.recipes.Recipe) ![]const ArtifactBinding {
    if (!std.mem.eql(u8, recipe.stage_root, ctx.stage)) return error.StageMismatch;
    if (recipe.artifacts.len > max_artifact_bindings) return error.ResourceLimit;
    var paths = std.StringHashMap(void).init(ctx.g);
    defer paths.deinit();
    const bindings = try ctx.g.alloc(ArtifactBinding, recipe.artifacts.len);
    // The executor calls commit only after final sidecar and processor verification.
    for (recipe.artifacts, bindings) |artifact, *binding| {
        try ctx.control.check();
        try c.relative(artifact.path);
        const coordinate = try m.version.mavenCoordinate(artifact.coordinate);
        const canonical = try c.join(ctx.g, "libraries", try coordinate.path(ctx.g, null));
        if (!std.mem.eql(u8, artifact.path, canonical)) return error.UnsafeArtifactPath;
        const portable_key = try std.ascii.allocLowerString(ctx.g, artifact.path);
        const entry = try paths.getOrPut(portable_key);
        if (entry.found_existing) return error.DuplicateArtifactPath;
        const final = try finalClientBinding(ctx, try c.join(ctx.g, ctx.stage, artifact.path));
        binding.* = .{ .path = artifact.path, .sha256 = std.fmt.bytesToHex(&final.sha256, .lower), .size = final.size };
    }
    return bindings;
}
const ClientBinding = struct { sha256: [32]u8, size: u64 };
fn finalClientBinding(ctx: *Context, path: []const u8) !ClientBinding {
    try ctx.control.check();
    _ = try within(path, ctx.stage);
    const parent = try files.directory(ctx.io, std.fs.path.dirname(path) orelse return error.UnsafeArtifactPath, false);
    defer parent.close(ctx.io);
    const name = std.fs.path.basename(path);
    const file = try parent.openFile(ctx.io, name, .{ .follow_symlinks = false, .allow_directory = false });
    defer file.close(ctx.io);
    const before = try file.stat(ctx.io);
    if (before.kind != .file or before.nlink != 1) return error.NotRegularFile;
    if (before.size > max_file) return error.FileTooLarge;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < before.size) {
        try ctx.control.check();
        const want: usize = @intCast(@min(buffer.len, before.size - offset));
        const n = try file.readPositional(ctx.io, &.{buffer[0..want]}, offset);
        if (n == 0) return error.FileChanged;
        hash.update(buffer[0..n]);
        offset += n;
    }
    const after = try file.stat(ctx.io);
    const current = try parent.statFile(ctx.io, name, .{ .follow_symlinks = false });
    if (after.nlink != 1 or after.size != before.size or after.mtime.nanoseconds != before.mtime.nanoseconds or after.ctime.nanoseconds != before.ctime.nanoseconds or current.kind != .file or current.inode != before.inode or current.size != before.size or current.mtime.nanoseconds != before.mtime.nanoseconds or current.ctime.nanoseconds != before.ctime.nanoseconds) return error.FileChanged;
    try ctx.control.check();
    return .{ .sha256 = hash.finalResult(), .size = offset };
}
fn digestFile(ctx: *Context, path: []const u8) !m.Sha1 {
    const bytes = try files.read(ctx.a, ctx.io, path, max_file, ctx.control);
    defer ctx.a.free(bytes);
    var hash: m.Sha1 = undefined;
    std.crypto.hash.Sha1.hash(bytes, &hash, .{});
    return hash;
}
fn publishLibrary(ctx: *Context, source: []const u8, destination: []const u8, hash: m.Sha1, size: ?u64) !void {
    const parent_path = std.fs.path.dirname(destination) orelse return error.UnsafeArtifactPath;
    const name = std.fs.path.basename(destination);
    const parent = try files.directory(ctx.io, parent_path, true);
    defer parent.close(ctx.io);
    if (parent.statFile(ctx.io, name, .{ .follow_symlinks = false })) |_| return files.verify(ctx.io, destination, hash, size, max_file, ctx.control) else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    var random: [16]u8 = undefined;
    ctx.io.random(&random);
    const temporary = try std.fmt.allocPrint(ctx.g, ".loader-{s}", .{std.fmt.bytesToHex(&random, .lower)});
    const temp_path = try c.join(ctx.g, parent_path, temporary);
    defer {
        const protection = ctx.io.swapCancelProtection(.blocked);
        defer _ = ctx.io.swapCancelProtection(protection);
        parent.deleteFile(ctx.io, temporary) catch {};
    }
    try files.copy(ctx.io, source, temp_path, max_file, ctx.control);
    try files.verify(ctx.io, temp_path, hash, size, max_file, ctx.control);
    parent.renamePreserve(temporary, parent, name, ctx.io) catch |err| switch (err) {
        error.PathAlreadyExists => try files.verify(ctx.io, destination, hash, size, max_file, ctx.control),
        else => return err,
    };
    try tree.syncDir(ctx.io, parent);
}
fn clientDownload(version: m.version.Version) !m.version.Download {
    for (version.downloads) |entry| if (std.mem.eql(u8, entry.name, "client")) return entry.download;
    return error.BaseNotInstalled;
}
fn normalizePlan(a: A, source: plan_module.Plan) !plan_module.Plan {
    var result = source;
    result.client_path = try normalized(a, source.client_path);
    const entries = try a.dupe(plan_module.File, source.files);
    for (entries) |*entry| entry.path = try normalized(a, entry.path);
    result.files = entries;
    const natives = try a.dupe(plan_module.NativeExtraction, source.native_extractions);
    for (natives) |*native| {
        native.archive_path = try normalized(a, native.archive_path);
        native.destination = try normalized(a, native.destination);
    }
    result.native_extractions = natives;
    const aliases = try a.dupe(plan_module.AssetMaterialization, source.asset_materializations);
    for (aliases) |*alias| {
        alias.source_path = try normalized(a, alias.source_path);
        alias.destination = try normalized(a, alias.destination);
    }
    result.asset_materializations = aliases;
    return result;
}

/// Borrow the configured shared HTTP client for real official catalog queries.
/// The transport remains valid only while that client is alive.
pub fn httpTransport(client: *http.Client) loaders.Transport {
    return .{ .context = client, .get = httpGet };
}
fn httpGet(raw: ?*anyopaque, a: A, url: []const u8, max: usize, control: loaders.Control) !loaders.Response {
    const client: *http.Client = @ptrCast(@alignCast(raw.?));
    return httpResponse(client, a, url, max, control);
}
fn fetchResponse(a: A, client: ?*http.Client, transport: ?loaders.Transport, url: []const u8, max: usize, control: loaders.Control) !loaders.Response {
    try control.check();
    try c.trusted(url);
    const response = if (transport) |value| try value.get(value.context, a, url, max, control) else try httpResponse(client orelse return error.TransportUnavailable, a, url, max, control);
    errdefer {
        a.free(response.bytes);
        a.free(response.final_url);
    }
    try control.check();
    if (response.status != 200) return error.HttpStatus;
    if (response.bytes.len > max) return error.ResourceLimit;
    if (!std.mem.eql(u8, response.final_url, url)) return error.UntrustedRedirect;
    return response;
}

fn httpResponse(client: *http.Client, a: A, url: []const u8, max: usize, control: loaders.Control) !loaders.Response {
    try control.check();
    try c.trusted(url);
    if (max == 0 or max > max_file) return error.ResourceLimit;
    const current = control.now_ms(control.context);
    if (current >= control.deadline_ms) return error.DeadlineExceeded;
    const remaining = control.deadline_ms - current;
    var response = try client.execute(.{ .url = url, .max_response_bytes = max, .cancel = control.cancel, .timeout_ms = @intCast(@min(remaining, 30_000)), .follow_redirects = false });
    defer response.deinit();
    try control.check();
    const bytes = try a.dupe(u8, response.body);
    errdefer a.free(bytes);
    return .{ .bytes = bytes, .final_url = try a.dupe(u8, url), .status = response.status };
}

fn metadataFixtureNow(_: ?*anyopaque) u64 {
    return 0;
}
const metadata_fixture_control: loaders.Control = .{ .deadline_ms = std.math.maxInt(u64), .now_ms = metadataFixtureNow };
const metadata_fixture_vanilla =
    \\{"id":"1.20.1","mainClass":"vanilla.Main","libraries":[],"javaVersion":{"component":"java-runtime-gamma","majorVersion":17},"downloads":{"client":{"url":"https://piston-data.mojang.com/client.jar","sha1":"0000000000000000000000000000000000000000","size":8}}}
;
const metadata_fixture_fabric =
    \\{"id":"fabric-fixture","inheritsFrom":"1.20.1","mainClass":"net.fabricmc.loader.impl.launch.knot.KnotClient","libraries":[{"name":"net.fabricmc:fabric-loader:0.16.0","url":"https://maven.fabricmc.net/"}]}
;
const metadata_fixture_forge =
    \\{"minecraft":"1.20.1","json":"/version.json","libraries":[{"name":"net.minecraftforge:fixture:1","url":"https://maven.minecraftforge.net/"}],"data":{"PATCH":{"client":"/data/client.lzma","server":"/data/server.lzma"}},"processors":[{"sides":["client"],"jar":"net.minecraftforge:fixture:1","classpath":[],"args":["{ROOT}","{MINECRAFT_JAR}","{PATCH}"],"outputs":{}}]}
;
const metadata_fixture_version =
    \\{"id":"forge-fixture","inheritsFrom":"1.20.1","mainClass":"cpw.mods.bootstraplauncher.BootstrapLauncher","libraries":[]}
;
const MetadataFixture = struct {
    entries: [1]m.manifest.Entry = undefined,
    metadata_root: [4096]u8 = undefined,
    installer: ?[]const u8 = null,
    bad_checksum: bool = false,
    redirect: bool = false,
    vanilla_calls: usize = 0,
    loader_calls: usize = 0,
    lease_calls: usize = 0,
    cancel: ?*std.atomic.Value(bool) = null,
    probe_namespace: bool = false,
    gate_available_probes: usize = 0,

    fn probeNamespace(self: *MetadataFixture, io: std.Io) !void {
        if (!self.probe_namespace) return;
        try std.testing.expectError(error.InstanceNamespaceBusy, namespace.acquire(io));
        const worlds = @import("../worlds.zig");
        try std.testing.expect(worlds.transaction_gate.tryLock());
        worlds.transaction_gate.unlock(io);
        self.gate_available_probes += 1;
    }

    fn options(self: *MetadataFixture, root: []const u8) MetadataOptions {
        var checksum: m.Sha1 = undefined;
        std.crypto.hash.Sha1.hash(metadata_fixture_vanilla, &checksum, .{});
        self.entries = .{.{ .id = "1.20.1", .kind = "release", .url = "https://piston-meta.mojang.com/v1/packages/fixture/1.20.1.json", .time = "", .release_time = "", .sha1 = checksum, .compliance_level = null }};
        return .{
            .root = root,
            .instance_id = "pack-fixture",
            .instance_name = "Pack",
            .generation = 7,
            .selection = .{ .kind = if (self.installer != null) .forge else .fabric, .base_id = "1.20.1", .loader_id = if (self.installer != null) "1.20.1-47.2.0" else "0.16.0" },
            .environment = .{ .os_name = "linux", .arch = "x86_64" },
            .vanilla = .{ .root = std.fmt.bufPrint(&self.metadata_root, "{s}{s}.minecraft", .{ root, std.fs.path.sep_str }) catch unreachable, .version_id = "1.20.1", .manifest = .{ .latest = .{ .release = "1.20.1", .snapshot = "1.20.1" }, .versions = &self.entries } },
            .fetcher = .{ .context = self, .fetch = vanilla },
            .transport = .{ .context = self, .get = get },
        };
    }
    fn vanilla(raw: ?*anyopaque, a: A, _: std.Io, request: metadata_loader.Request) ![]u8 {
        const self: *MetadataFixture = @ptrCast(@alignCast(raw.?));
        try self.probeNamespace(std.testing.io);
        self.vanilla_calls += 1;
        try std.testing.expect(request.sha1 != null);
        return a.dupe(u8, metadata_fixture_vanilla);
    }
    fn get(raw: ?*anyopaque, a: A, url: []const u8, _: usize, _: loaders.Control) !loaders.Response {
        const self: *MetadataFixture = @ptrCast(@alignCast(raw.?));
        try self.probeNamespace(std.testing.io);
        self.loader_calls += 1;
        const body = if (std.mem.endsWith(u8, url, ".sha1")) blk: {
            const checksum = if (self.bad_checksum) @as(m.Sha1, .{0} ** 20) else loaders.recipes.digest(self.installer.?);
            const hex = std.fmt.bytesToHex(&checksum, .lower);
            break :blk try a.dupe(u8, &hex);
        } else if (std.mem.endsWith(u8, url, "maven-metadata.json"))
            try a.dupe(u8, "{\"1.20.1\":[\"1.20.1-47.2.0\"]}")
        else if (std.mem.endsWith(u8, url, "/v2/versions/loader/1.20.1"))
            try a.dupe(u8, "[{\"loader\":{\"version\":\"0.16.0\",\"stable\":true}}]")
        else if (std.mem.endsWith(u8, url, ".jar"))
            try a.dupe(u8, self.installer orelse return error.UnexpectedFixtureRequest)
        else if (std.mem.endsWith(u8, url, "/profile/json"))
            try a.dupe(u8, metadata_fixture_fabric)
        else
            return error.UnexpectedFixtureRequest;
        errdefer a.free(body);
        const final_url = try a.dupe(u8, if (self.redirect) "https://example.invalid/redirect" else url);
        if (self.cancel) |flag| flag.store(true, .release);
        return .{ .bytes = body, .final_url = final_url, .status = 200 };
    }
    fn acquire(raw: ?*anyopaque, _: []const u8) !void {
        const self: *MetadataFixture = @ptrCast(@alignCast(raw.?));
        self.lease_calls += 1;
        return error.FixtureLeaseStop;
    }
    fn recheck(_: ?*anyopaque, _: []const u8) !void {
        return error.FixtureLeaseStop;
    }
    fn release(_: ?*anyopaque, _: []const u8) void {}
    fn installOptions(self: *MetadataFixture, prepared: *const PreparedMetadata) Options {
        return .{ .root = prepared.root, .instance_id = prepared.instance_id, .instance_name = prepared.instance_name, .selection = prepared.selection, .environment = prepared.environment, .base = prepared.base.value, .base_plan = .{ .files = &.{}, .native_extractions = &.{}, .classpath = &.{}, .client_path = "/fixture-not-installed" }, .lease = .{ .context = self, .acquire = acquire, .recheck = recheck, .release = release }, .transport = .{ .context = self, .get = get } };
    }
};
fn metadataFixtureTarget(prepared: *const PreparedMetadata) MetadataTarget {
    return .{ .root = prepared.root, .instance_id = prepared.instance_id, .instance_name = prepared.instance_name, .generation = prepared.generation, .selection = prepared.selection, .environment = prepared.environment };
}
const MetadataZipEntry = struct { path: []const u8, bytes: []const u8 };
fn metadataFixtureZip(a: A) ![]u8 {
    const entries = [_]MetadataZipEntry{
        .{ .path = "install_profile.json", .bytes = metadata_fixture_forge },
        .{ .path = "version.json", .bytes = metadata_fixture_version },
        .{ .path = "data/client.lzma", .bytes = "patch" },
    };
    var storage: [16384]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    var offsets: [entries.len]u32 = undefined;
    for (entries, 0..) |entry, index| {
        offsets[index] = @intCast(writer.end);
        var header = std.mem.zeroes(std.zip.LocalFileHeader);
        header.signature = std.zip.local_file_header_sig;
        header.version_needed_to_extract = 20;
        header.compression_method = .store;
        header.crc32 = std.hash.Crc32.hash(entry.bytes);
        header.compressed_size = @intCast(entry.bytes.len);
        header.uncompressed_size = @intCast(entry.bytes.len);
        header.filename_len = @intCast(entry.path.len);
        try writer.writeStruct(header, .little);
        try writer.writeAll(entry.path);
        try writer.writeAll(entry.bytes);
    }
    const central_offset = writer.end;
    for (entries, 0..) |entry, index| {
        var header = std.mem.zeroes(std.zip.CentralDirectoryFileHeader);
        header.signature = std.zip.central_file_header_sig;
        header.version_made_by = 0x0314;
        header.version_needed_to_extract = 20;
        header.compression_method = .store;
        header.crc32 = std.hash.Crc32.hash(entry.bytes);
        header.compressed_size = @intCast(entry.bytes.len);
        header.uncompressed_size = @intCast(entry.bytes.len);
        header.filename_len = @intCast(entry.path.len);
        header.external_file_attributes = 0o100644 << 16;
        header.local_file_header_offset = offsets[index];
        try writer.writeStruct(header, .little);
        try writer.writeAll(entry.path);
    }
    var end = std.mem.zeroes(std.zip.EndRecord);
    end.signature = std.zip.end_record_sig;
    end.record_count_disk = @intCast(entries.len);
    end.record_count_total = @intCast(entries.len);
    end.central_directory_offset = @intCast(central_offset);
    end.central_directory_size = @intCast(writer.end - central_offset);
    try writer.writeStruct(end, .little);
    return a.dupe(u8, writer.buffered());
}
test "metadata preflight owns sources without JVM lease or final game publication" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var fixture: MetadataFixture = .{};
    var prepared = try prepareMetadata(a, io, fixture.options(root), metadata_fixture_control);
    defer prepared.deinit();
    try std.testing.expectEqual(@as(u64, 17), prepared.requirements.runtime_major);
    try std.testing.expectEqual(@as(u64, 8), prepared.requirements.installer_major);
    try std.testing.expectEqual(@as(usize, 1), prepared.vanilla_sources.len);
    try std.testing.expectEqualStrings(metadata_fixture_vanilla, prepared.vanilla_sources[0].bytes);
    try std.testing.expectEqualStrings(metadata_fixture_fabric, prepared.bundle.profile);
    try std.testing.expectEqual(@as(usize, 1), fixture.vanilla_calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.loader_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.lease_calls);
    const final_game = try c.join(a, root, ".minecraft/versions/Pack");
    defer a.free(final_game);
    try std.testing.expectError(error.FileNotFound, files.directory(io, final_game, false));
    const options = fixture.installOptions(&prepared);
    try prepared.validate(a, io, options);
    try std.testing.expectError(error.PreparedMetadataGenerationMismatch, installPrepared(a, io, options, &prepared, 8, metadata_fixture_control));
    var wrong = options;
    wrong.instance_id = "different-instance";
    try std.testing.expectError(error.PreparedMetadataMismatch, installPrepared(a, io, wrong, &prepared, 7, metadata_fixture_control));
    wrong = options;
    wrong.root = "/different-launcher-root";
    try std.testing.expectError(error.PreparedMetadataMismatch, installPrepared(a, io, wrong, &prepared, 7, metadata_fixture_control));
    wrong = options;
    wrong.selection.loader_id = "changed-loader";
    try std.testing.expectError(error.PreparedMetadataMismatch, installPrepared(a, io, wrong, &prepared, 7, metadata_fixture_control));
    const retained = prepared.bundle.profile;
    prepared.bundle.profile = "{}";
    try std.testing.expectError(error.PreparedMetadataChanged, installPrepared(a, io, options, &prepared, 7, metadata_fixture_control));
    prepared.bundle.profile = retained;
    var changed_base = prepared.base.value;
    changed_base.main_class = "changed.Main";
    wrong = options;
    wrong.base = changed_base;
    try std.testing.expectError(error.PreparedBaseChanged, installPrepared(a, io, wrong, &prepared, 7, metadata_fixture_control));
    try std.testing.expectEqual(@as(usize, 0), fixture.lease_calls);
    fixture.redirect = true;
    try std.testing.expectError(error.FixtureLeaseStop, installPrepared(a, io, options, &prepared, 7, metadata_fixture_control));
    try std.testing.expectEqual(@as(usize, 1), fixture.lease_calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.loader_calls);
}
test "verified installer preflight rebuilds processor paths for actual stage and rejects corrupt provenance" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const archive = try metadataFixtureZip(a);
    defer a.free(archive);
    var fixture: MetadataFixture = .{ .installer = archive, .bad_checksum = true };
    try std.testing.expectError(error.ChecksumMismatch, prepareMetadata(a, io, fixture.options(root), metadata_fixture_control));
    fixture.bad_checksum = false;
    fixture.redirect = true;
    try std.testing.expectError(error.UntrustedRedirect, prepareMetadata(a, io, fixture.options(root), metadata_fixture_control));
    fixture.redirect = false;
    var prepared = try prepareMetadata(a, io, fixture.options(root), metadata_fixture_control);
    defer prepared.deinit();
    try std.testing.expectEqual(@as(u64, 17), prepared.requirements.runtime_major);
    try std.testing.expectEqual(@as(u64, 17), prepared.requirements.installer_major);
    try std.testing.expectEqualStrings(archive, prepared.source_bytes);
    try std.testing.expectEqualStrings(metadata_fixture_forge, prepared.bundle.profile);
    const actual_stage = try c.join(a, root, ".minecraft/versions/.stage-actual");
    defer a.free(actual_stage);
    var recipe = try loaders.prepare(a, prepared.catalog.value, prepared.selection, prepared.base.value, prepared.bundle, .{ .instance_name = prepared.instance_name, .stage_root = actual_stage, .environment = prepared.environment });
    defer recipe.deinit();
    try std.testing.expectEqual(@as(usize, 1), recipe.value.processors.len);
    try std.testing.expectEqualStrings(actual_stage, recipe.value.processors[0].args[0]);
    const actual_jar = try std.fmt.allocPrint(a, "{s}/versions/1.20.1/1.20.1.jar", .{actual_stage});
    defer a.free(actual_jar);
    try std.testing.expectEqualStrings(actual_jar, recipe.value.processors[0].args[1]);
    try std.testing.expect(std.mem.startsWith(u8, recipe.value.processors[0].args[2], actual_stage));
    try std.testing.expectEqual(@as(usize, 0), fixture.lease_calls);
}
fn metadataAllocationFixture(a: A, root: []const u8, installer: ?[]const u8) !void {
    var fixture: MetadataFixture = .{ .installer = installer };
    var prepared = try prepareMetadata(a, std.testing.io, fixture.options(root), metadata_fixture_control);
    defer prepared.deinit();
    try prepared.validate(a, std.testing.io, fixture.installOptions(&prepared));
    var replay = try prepared.replayBase(a, std.testing.io, metadataFixtureTarget(&prepared), metadata_fixture_control);
    defer replay.deinit();
}
test "metadata preflight allocation failures release stable owners for profiles and installers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    try std.testing.checkAllAllocationFailures(a, metadataAllocationFixture, .{ root, @as(?[]const u8, null) });
    const installer = try metadataFixtureZip(a);
    defer a.free(installer);
    try std.testing.checkAllAllocationFailures(a, metadataAllocationFixture, .{ root, @as(?[]const u8, installer) });
}
test "metadata preflight cancellation never enters installation and generation is mandatory" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var cancel = std.atomic.Value(bool).init(false);
    var fixture: MetadataFixture = .{ .cancel = &cancel };
    var options = fixture.options(root);
    options.generation = 0;
    try std.testing.expectError(error.InvalidPreparationGeneration, prepareMetadata(a, std.testing.io, options, metadata_fixture_control));
    try std.testing.expectEqual(@as(usize, 0), fixture.vanilla_calls);
    options.generation = 7;
    try std.testing.expectError(error.Canceled, prepareMetadata(a, std.testing.io, options, .{ .cancel = &cancel, .deadline_ms = std.math.maxInt(u64), .now_ms = metadataFixtureNow }));
    try std.testing.expectEqual(@as(usize, 0), fixture.lease_calls);
}
test "vanilla replay validates target before cloning and survives prepared owner destruction" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var fixture: MetadataFixture = .{};
    var prepared = try prepareMetadata(a, io, fixture.options(root), metadata_fixture_control);
    var live = true;
    defer if (live) prepared.deinit();
    const target = metadataFixtureTarget(&prepared);
    var wrong = target;
    wrong.generation = 0;
    try std.testing.expectError(error.PreparedMetadataGenerationMismatch, prepared.replayBase(a, io, wrong, metadata_fixture_control));
    wrong = target;
    wrong.instance_name = ".private-vanilla-stage";
    try std.testing.expectError(error.PreparedMetadataMismatch, prepared.replayBase(a, io, wrong, metadata_fixture_control));
    wrong = target;
    wrong.environment.arch = "aarch64";
    try std.testing.expectError(error.PreparedMetadataMismatch, prepared.replayBase(a, io, wrong, metadata_fixture_control));
    const retained = prepared.vanilla_sources;
    prepared.vanilla_sources = &.{};
    try std.testing.expectError(error.PreparedMetadataChanged, prepared.replayBase(a, io, target, metadata_fixture_control));
    prepared.vanilla_sources = retained;
    var replay = try prepared.replayBase(a, io, target, metadata_fixture_control);
    defer replay.deinit();
    prepared.deinit();
    live = false;
    try std.testing.expectEqualStrings("1.20.1", replay.version.value.id);
    try std.testing.expectEqual(@as(u64, 17), m.version.requiredJavaMajor(replay.version.value));
    try std.testing.expectEqual(@as(usize, 1), replay.sources.value.len);
    try std.testing.expectEqualStrings("1.20.1", replay.sources.value[0].id);
    try std.testing.expectEqualStrings(metadata_fixture_vanilla, replay.sources.value[0].bytes);
    try std.testing.expectEqual(@as(usize, 1), fixture.vanilla_calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.loader_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.lease_calls);
}
test "metadata preflight copies caller feature storage before validating replay" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var feature_name = "custom".*;
    var features = [_]m.rules.Feature{.{ .name = &feature_name, .enabled = true }};
    var fixture: MetadataFixture = .{};
    var options = fixture.options(root);
    options.environment.features = &features;
    var prepared = try prepareMetadata(a, io, options, metadata_fixture_control);
    defer prepared.deinit();
    feature_name[0] = 'd';
    features[0].enabled = false;
    try std.testing.expectEqualStrings("custom", prepared.environment.features[0].name);
    try std.testing.expect(prepared.environment.features[0].enabled);
    const target = metadataFixtureTarget(&prepared);
    try prepared.validateBinding(a, io, target);
    var changed = target;
    changed.environment = options.environment;
    try std.testing.expectError(error.PreparedMetadataMismatch, prepared.replayBase(a, io, changed, metadata_fixture_control));
}

test "metadata preparation rejects unsafe and mismatched roots before any fetch" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var fixture: MetadataFixture = .{};
    var options = fixture.options(root);
    options.root = "";
    try std.testing.expectError(error.UnsafeDataRoot, prepareMetadata(a, io, options, metadata_fixture_control));
    options.root = "bad\x00root";
    try std.testing.expectError(error.UnsafeDataRoot, prepareMetadata(a, io, options, metadata_fixture_control));
    options = fixture.options(root);
    options.vanilla.root = root;
    try std.testing.expectError(error.PreparedMetadataMismatch, prepareMetadata(a, io, options, metadata_fixture_control));
    options.vanilla.root = "";
    try std.testing.expectError(error.UnsafeDataRoot, prepareMetadata(a, io, options, metadata_fixture_control));
    options.vanilla.root = "bad\x00root";
    try std.testing.expectError(error.UnsafeDataRoot, prepareMetadata(a, io, options, metadata_fixture_control));
    try std.testing.expectEqual(@as(usize, 0), fixture.vanilla_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.loader_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.lease_calls);
}

test "metadata namespace blocker prevents earliest directory and fetch side effects" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var fixture: MetadataFixture = .{};
    const options = fixture.options(root);
    const token = try namespace.acquire(io);
    defer token.release();
    try std.testing.expectError(error.InstanceNamespaceBusy, prepareMetadata(a, io, options, metadata_fixture_control));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".minecraft", .{ .follow_symlinks = false }));
    try std.testing.expectEqual(@as(usize, 0), fixture.vanilla_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.loader_calls);
    try token.recheck();
}

test "metadata direct and borrowed namespace lifetimes leave the gate available" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var fixture: MetadataFixture = .{ .probe_namespace = true };
    var options = fixture.options(root);
    var direct = try prepareMetadata(a, io, options, metadata_fixture_control);
    defer direct.deinit();
    try std.testing.expect(fixture.gate_available_probes > 0);
    const token = try namespace.acquire(io);
    defer token.release();
    options.namespace_token = token;
    var borrowed = try prepareMetadata(a, io, options, metadata_fixture_control);
    defer borrowed.deinit();
    try token.recheck();
    try std.testing.expectError(error.InstanceNamespaceBusy, namespace.acquire(io));
    token.release();
    const current = try namespace.acquire(io);
    defer current.release();
    const vanilla_calls = fixture.vanilla_calls;
    const loader_calls = fixture.loader_calls;
    try std.testing.expectError(error.InstanceNamespaceLeaseLost, prepareMetadata(a, io, options, metadata_fixture_control));
    try std.testing.expectEqual(vanilla_calls, fixture.vanilla_calls);
    try std.testing.expectEqual(loader_calls, fixture.loader_calls);
    try current.recheck();
}

test "worker loader and metadata admission reject active namespace and stale borrowers before side effects" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var fixture: MetadataFixture = .{};
    var metadata_options = fixture.options(root);
    metadata_options.worker_checks = true;
    var options: Options = .{ .root = root, .instance_id = "pack-fixture", .instance_name = "Pack", .selection = metadata_options.selection, .environment = metadata_options.environment, .lease = undefined, .worker_checks = true };
    const old = try namespace.acquire(io);
    defer old.release();
    try std.testing.expectError(error.InstanceNamespaceBusy, prepareMetadata(a, io, metadata_options, metadata_fixture_control));
    try std.testing.expectError(error.InstanceNamespaceBusy, install(a, io, options, metadata_fixture_control));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".minecraft", .{ .follow_symlinks = false }));
    try std.testing.expectEqual(@as(usize, 0), fixture.vanilla_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.loader_calls);
    old.release();
    const current = try namespace.acquire(io);
    defer current.release();
    metadata_options.namespace_token = old;
    options.namespace_token = old;
    try std.testing.expectError(error.InstanceNamespaceLeaseLost, prepareMetadata(a, io, metadata_options, metadata_fixture_control));
    try std.testing.expectError(error.InstanceNamespaceLeaseLost, install(a, io, options, metadata_fixture_control));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".minecraft", .{ .follow_symlinks = false }));
    try std.testing.expectEqual(@as(usize, 0), fixture.vanilla_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.loader_calls);
    try current.recheck();
}

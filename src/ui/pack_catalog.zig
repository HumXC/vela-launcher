//! Instance-independent, metadata-only modpack browser. No instance or lease is
//! required; this module never installs or writes content. Default filters are
//! absent (including loader); explicit filters are independent and optional.
//!
//! Controller.init(a, io, options) owns copies of option strings. Call all public
//! methods on one UI thread; a need not be thread safe. Worker allocations use
//! page_allocator. The Io implementation must support concurrent tasks and outlive
//! deinit. Fixture contexts/stores are borrowed and must also outlive deinit.
//! search(Search) and loadVersions(Project, Filter) copy inputs before returning,
//! cancel the previous request, and start a concurrent worker. They may fail to
//! allocate/spawn; errors from HTTP/parsing appear in snapshot().failure on tick.
//! cancel is nonblocking: it signals cancellation and retires the worker. tick
//! publishes only the current request, JOINs completed workers, and reaps retired
//! workers. deinit cancels and JOINs every worker before freeing any owned data;
//! it may block for an in-flight credential-store call or transport callback.
//!
//! snapshot returns borrowed immutable slices valid until the next successful
//! search/loadVersions, result-publishing tick, or deinit. Copy selected IDs before
//! retaining them elsewhere. loadVersions retains catalog results. New search
//! clears catalog and versions. cancel retains published results and clears error.
//! Options freeze authorization for this controller's lifetime: when credentials
//! or policy change, deinit and initialize again. curseforge_available reports
//! configured gates, not successful vault access. No raw key enters snapshots.
//! CurseForge versions are metadata/manual-only; installation must independently
//! re-fetch and authorize the selected project/file under the current policy.
const std = @import("std");
const config = @import("../core/config.zig");
const providers = @import("../core/content_providers.zig");
const transport = @import("../core/content_transport.zig");
const credentials = @import("../core/credentials.zig");
const A = std.mem.Allocator;
const Io = std.Io;

pub const Filter = struct { minecraft_version: ?[]const u8 = null, loader: ?config.Loader = null };
pub const Search = struct {
    query: []const u8 = "",
    provider: providers.Provider = .modrinth,
    filter: Filter = .{},
    offset: u32 = 0,
    limit: u16 = 40,
};
pub const CurseForgePolicy = struct {
    enabled: bool = false,
    terms_approved: bool = false,
    credential_ref: ?credentials.Reference = null,
};
pub const Options = struct {
    transport_options: transport.Adapter.Options = .{},
    curseforge: CurseForgePolicy = .{},
    fixture_credential_store: ?credentials.Store = null,
};
pub const Snapshot = struct {
    catalog: []const providers.Project = &.{},
    versions: []const providers.Version = &.{},
    total: u64 = 0,
    provider: providers.Provider = .modrinth,
    busy: bool = false,
    failure: ?anyerror = null,
    curseforge_available: bool = false,
};
const Request = union(enum) { search: Search, versions: struct { project: providers.Project, filter: Filter } };

fn copy(comptime T: type, a: A, value: T) anyerror!T {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var out: T = undefined;
            inline for (info.field_names, info.field_types) |name, F| @field(out, name) = try copy(F, a, @field(value, name));
            return out;
        },
        .@"union" => |info| {
            inline for (info.field_names, info.field_types) |name, F| if (std.meta.activeTag(value) == @field(info.tag_type.?, name)) return @unionInit(T, name, try copy(F, a, @field(value, name)));
            unreachable;
        },
        .optional => |info| return if (value) |v| try copy(info.child, a, v) else null,
        .pointer => |info| {
            if (info.size != .slice) return value;
            const out = try a.alloc(info.child, value.len);
            for (value, out) |v, *dest| dest.* = try copy(info.child, a, v);
            return out;
        },
        else => return value,
    }
}
fn available(options: Options) bool {
    const ref = options.curseforge.credential_ref orelse return false;
    return options.curseforge.enabled and options.curseforge.terms_approved and
        options.transport_options.allow_curseforge and credentials.validateReference(&ref);
}
fn validateFilter(filter: Filter) !void {
    if (filter.minecraft_version) |v| {
        if (v.len == 0 or v.len > 128) return error.InvalidFilter;
        for (v) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_') return error.InvalidFilter;
    }
}
fn validateProvider(provider: providers.Provider, options: Options) !void {
    switch (provider) {
        .modrinth => {},
        .curseforge => if (!available(options)) return error.ProviderDisabled,
    }
}

pub const Controller = struct {
    allocator: A,
    io: Io,
    arena: std.heap.ArenaAllocator,
    options: Options,
    current: ?*Job = null,
    retired: ?*Job = null,
    catalog: ?*Job = null,
    versions: ?*Job = null,
    provider: providers.Provider = .modrinth,
    failure: ?anyerror = null,

    pub fn init(a: A, io: Io, options: Options) !Controller {
        var arena: std.heap.ArenaAllocator = .init(a);
        errdefer arena.deinit();
        const owned_options = try copy(Options, arena.allocator(), options);
        return .{ .allocator = a, .io = io, .arena = arena, .options = owned_options };
    }
    pub fn deinit(self: *Controller) void {
        self.cancel();
        while (self.retired) |job| {
            self.retired = job.next;
            job.future.?.cancel(self.io);
            job.destroy(self.allocator);
        }
        if (self.catalog) |job| job.destroy(self.allocator);
        if (self.versions) |job| job.destroy(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn search(self: *Controller, request: Search) !void {
        try validateProvider(request.provider, self.options);
        try validateFilter(request.filter);
        if (request.query.len > 512 or !std.unicode.utf8ValidateSlice(request.query) or request.limit == 0 or request.limit > 50 or request.offset > 10000 - @as(u32, request.limit)) return error.InvalidQuery;
        try self.start(.{ .search = request });
        if (self.catalog) |job| job.destroy(self.allocator);
        self.catalog = null;
        if (self.versions) |job| job.destroy(self.allocator);
        self.versions = null;
        self.provider = request.provider;
    }
    pub fn loadVersions(self: *Controller, project: providers.Project, filter: Filter) !void {
        try validateProvider(project.provider, self.options);
        try validateFilter(filter);
        if (project.id.len == 0 or project.id.len > 128) return error.InvalidId;
        for (project.id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.InvalidId;
        try self.start(.{ .versions = .{ .project = project, .filter = filter } });
        if (self.versions) |job| job.destroy(self.allocator);
        self.versions = null;
        self.provider = project.provider;
    }
    fn start(self: *Controller, request: Request) !void {
        const job = try self.allocator.create(Job);
        job.* = .{ .io = self.io, .options = self.options, .request = undefined };
        errdefer job.destroy(self.allocator);
        job.request = try copy(Request, job.inputs.allocator(), request);
        job.future = try self.io.concurrent(Job.run, .{job});
        self.cancel();
        self.current = job;
    }
    pub fn cancel(self: *Controller) void {
        if (self.current) |job| {
            job.cancel.store(true, .release);
            job.next = self.retired;
            self.retired = job;
            self.current = null;
        }
        self.failure = null;
    }
    pub fn tick(self: *Controller) void {
        var link = &self.retired;
        while (link.*) |job| {
            if (!job.done.load(.acquire)) {
                link = &job.next;
                continue;
            }
            job.future.?.await(self.io);
            link.* = job.next;
            job.destroy(self.allocator);
        }
        const job = self.current orelse return;
        if (!job.done.load(.acquire)) return;
        job.future.?.await(self.io);
        self.current = null;
        self.failure = job.failure;
        if (job.failure != null) {
            job.destroy(self.allocator);
            return;
        }
        switch (job.request) {
            .search => {
                if (self.catalog) |old| old.destroy(self.allocator);
                self.catalog = job;
            },
            .versions => {
                if (self.versions) |old| old.destroy(self.allocator);
                self.versions = job;
            },
        }
    }
    pub fn snapshot(self: *const Controller) Snapshot {
        return .{
            .catalog = if (self.catalog) |job| job.projects else &.{},
            .total = if (self.catalog) |job| job.total else 0,
            .versions = if (self.versions) |job| job.releases else &.{},
            .provider = self.provider,
            .busy = self.current != null,
            .failure = self.failure,
            .curseforge_available = available(self.options),
        };
    }
};

const Job = struct {
    io: Io,
    options: Options,
    request: Request,
    inputs: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    output: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    future: ?Io.Future(void) = null,
    next: ?*Job = null,
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    projects: []const providers.Project = &.{},
    releases: []const providers.Version = &.{},
    total: u64 = 0,
    fn destroy(self: *Job, a: A) void {
        self.inputs.deinit();
        self.output.deinit();
        a.destroy(self);
    }
    fn check(self: *Job) !void {
        if (self.cancel.load(.acquire)) return error.Canceled;
        try self.io.checkCancel();
    }
    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        self.execute() catch |err| {
            self.failure = err;
        };
    }
    fn execute(self: *Job) !void {
        try self.check();
        var adapter = try transport.Adapter.initWithOptions(std.heap.page_allocator, self.io, &self.cancel, 1, self.options.transport_options);
        defer adapter.deinit();
        const provider = switch (self.request) {
            .search => |s| s.provider,
            .versions => |v| v.project.provider,
        };
        var native: ?credentials.Native = null;
        defer if (native) |*n| n.deinit();
        var secret: ?credentials.Secret = null;
        defer if (secret) |*s| s.deinit();
        if (provider == .curseforge) {
            try validateProvider(provider, self.options);
            const store = self.options.fixture_credential_store orelse blk: {
                native = try credentials.Native.init();
                break :blk native.?.store();
            };
            try self.check();
            secret = try store.get(std.heap.page_allocator, &self.options.curseforge.credential_ref.?);
            try self.check();
        }
        const key: ?[]const u8 = if (secret) |s| s.bytes else null;
        switch (self.request) {
            .search => |s| try self.searchMetadata(&adapter, s, key),
            .versions => |v| try self.versionMetadata(&adapter, v.project, v.filter, key),
        }
        try self.check();
    }
    fn fetch(self: *Job, adapter: *transport.Adapter, provider: providers.Provider, path: []const u8, key: ?[]const u8) ![]const u8 {
        try self.check();
        const a = self.output.allocator();
        const base = if (provider == .modrinth) "https://api.modrinth.com/v2" else providers.curseforge_api_base;
        const request: providers.Request = .{ .url = try std.mem.concat(a, u8, &.{ base, path }), .user_agent = transport.user_agent, .credential_header = if (key) |k| .{ .name = "x-api-key", .value = k } else null };
        if (provider == .curseforge and (key == null or !available(self.options))) return error.ProviderDisabled;
        if (!providers.credentialScopeAllowed(request)) return error.InvalidCredentialScope;
        const t = adapter.providerTransport();
        const response = try t.get(t.context, a, request);
        try self.check();
        if (response.status == 429) return error.RateLimited;
        if (response.status != 200) return error.HttpFailure;
        return response.body;
    }
    fn searchMetadata(self: *Job, adapter: *transport.Adapter, s: Search, key: ?[]const u8) !void {
        const a = self.output.allocator();
        const path = try searchPath(a, s);
        const bytes = try self.fetch(adapter, s.provider, path, key);
        if (s.provider == .curseforge) {
            const parsed = try providers.Json.parse(a, bytes);
            defer parsed.deinit();
            const items = try providers.Json.array(try providers.Json.field(parsed.value, "data"));
            _ = try pagination(parsed.value, items.len, s.offset, s.limit);
            for (items) |item| {
                if (try providers.Json.number(item, "gameId") != 432) return error.GameMismatch;
                if (try providers.Json.number(item, "classId") != 4471) return error.ProjectTypeMismatch;
            }
        }
        var result = if (s.provider == .modrinth) try providers.parseModrinthCatalog(a, bytes, true) else try providers.parseCurseForgeCatalog(a, bytes, false);
        defer result.deinit();
        self.projects = try copy([]const providers.Project, a, result.value.projects);
        self.total = result.value.total;
    }
    fn versionMetadata(self: *Job, adapter: *transport.Adapter, project: providers.Project, filter: Filter, key: ?[]const u8) !void {
        const a = self.output.allocator();
        if (project.provider == .modrinth) {
            const path = try std.fmt.allocPrint(a, "/project/{s}/version?include_changelog=false", .{project.id});
            const bytes = try self.fetch(adapter, .modrinth, path, null);
            var result = try providers.parseModrinthVersions(a, bytes, false, null);
            defer result.deinit();
            self.releases = try selectVersions(a, result.value.versions, project.id, filter);
            return;
        }
        // Revalidate project metadata with the established authorized client.
        const client: providers.CurseForgeClient = .{ .allocator = a, .transport = adapter.providerTransport(), .user_agent = transport.user_agent, .options = .{ .enabled = self.options.curseforge.enabled, .terms_approved = self.options.curseforge.terms_approved, .api_key = key } };
        var fresh = try client.project(project.id);
        defer fresh.deinit();
        const verified = fresh.value.projects[0];
        const uri = try std.Uri.parse(verified.official_page);
        if (!std.mem.startsWith(u8, uri.path.percent_encoded, "/minecraft/modpacks/")) return error.ProjectTypeMismatch;
        var index: u32 = 0;
        var expected_total: ?u64 = null;
        var byte_count: usize = 0;
        var releases: std.ArrayList(providers.Version) = .empty;
        while (true) {
            const path = try std.fmt.allocPrint(a, "/mods/{s}/files?index={d}&pageSize=50{s}", .{ project.id, index, try cfFilter(a, filter) });
            const bytes = try self.fetch(adapter, .curseforge, path, key);
            byte_count += bytes.len;
            if (byte_count > providers.max_json_bytes) return error.ResponseTooLarge;
            const parsed = try providers.Json.parse(a, bytes);
            defer parsed.deinit();
            const items = try providers.Json.array(try providers.Json.field(parsed.value, "data"));
            const total = try pagination(parsed.value, items.len, index, 50);
            if (total > providers.max_items) return error.TooManyItems;
            if (expected_total) |n| if (total != n) return error.InvalidPagination;
            expected_total = total;
            for (items) |item| if (try providers.Json.number(item, "gameId") != 432) return error.GameMismatch;
            var result = try providers.parseCurseForgeVersions(a, bytes, false, verified, null);
            defer result.deinit();
            const selected = try selectVersions(a, result.value.versions, project.id, filter);
            for (selected) |v| {
                for (releases.items) |old| if (std.mem.eql(u8, old.id, v.id)) return error.DuplicateVersion;
                try releases.append(a, v);
            }
            index += @intCast(items.len);
            if (index >= total) break;
            if (items.len == 0) return error.InvalidPagination;
        }
        self.releases = try releases.toOwnedSlice(a);
    }
};

fn pagination(value: std.json.Value, count: usize, index: u32, size: u16) !u64 {
    const p = try providers.Json.field(value, "pagination");
    const total = try providers.Json.number(p, "totalCount");
    if (try providers.Json.number(p, "index") != index or try providers.Json.number(p, "pageSize") != size or
        try providers.Json.number(p, "resultCount") != count or count > size or (count != 0 and @as(u64, index) + count > total)) return error.InvalidPagination;
    return total;
}
fn encode(a: A, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const hex = "0123456789ABCDEF";
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') try out.append(a, c) else try out.appendSlice(a, &.{ '%', hex[c >> 4], hex[c & 15] });
    }
    return try out.toOwnedSlice(a);
}
fn loaderName(loader: config.Loader) []const u8 {
    return if (loader == .vanilla) "minecraft" else @tagName(loader);
}
fn cfFilter(a: A, filter: Filter) ![]const u8 {
    const game = if (filter.minecraft_version) |v| try std.fmt.allocPrint(a, "&gameVersion={s}", .{try encode(a, v)}) else "";
    const loader = if (filter.loader) |v| try std.fmt.allocPrint(a, "&modLoaderType={d}", .{@as(u8, switch (v) {
        .vanilla => 0,
        .forge => 1,
        .fabric => 4,
        .quilt => 5,
        .neoforge => 6,
    })}) else "";
    return try std.mem.concat(a, u8, &.{ game, loader });
}
fn searchPath(a: A, s: Search) ![]const u8 {
    const query = try encode(a, s.query);
    if (s.provider == .curseforge) return try std.fmt.allocPrint(a, "/mods/search?gameId=432&classId=4471&searchFilter={s}&index={d}&pageSize={d}{s}", .{ query, s.offset, s.limit, try cfFilter(a, s.filter) });
    var facets: std.ArrayList([]const []const u8) = .empty;
    try facets.append(a, &.{"project_type:modpack"});
    if (s.filter.minecraft_version) |v| {
        const group = try a.alloc([]const u8, 1);
        group[0] = try std.fmt.allocPrint(a, "versions:{s}", .{v});
        try facets.append(a, group);
    }
    if (s.filter.loader) |v| {
        const group = try a.alloc([]const u8, 1);
        group[0] = try std.fmt.allocPrint(a, "categories:{s}", .{loaderName(v)});
        try facets.append(a, group);
    }
    const json = try std.json.Stringify.valueAlloc(a, facets.items, .{});
    return try std.fmt.allocPrint(a, "/search?query={s}&facets={s}&offset={d}&limit={d}", .{ query, try encode(a, json), s.offset, s.limit });
}
fn selectVersions(a: A, values: []const providers.Version, project_id: []const u8, filter: Filter) ![]const providers.Version {
    var out: std.ArrayList(providers.Version) = .empty;
    for (values) |v| {
        if (!std.mem.eql(u8, v.project_id, project_id)) return error.ProjectMismatch;
        if (filter.minecraft_version) |mc| {
            var found = false;
            for (v.minecraft_versions) |item| {
                if (std.mem.eql(u8, item, mc)) found = true;
            }
            if (!found) continue;
        }
        if (filter.loader) |loader| {
            var found = false;
            for (v.loaders) |item| {
                if (std.mem.eql(u8, item, loaderName(loader))) found = true;
            }
            if (!found) continue;
        }
        try out.append(a, try copy(providers.Version, a, v));
    }
    return try out.toOwnedSlice(a);
}

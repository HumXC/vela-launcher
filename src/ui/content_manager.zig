//! Owned asynchronous content workflows. The supplied lease is mandatory and
//! reserves the selected stable instance ID before any filesystem worker starts.
const std = @import("std");
const config = @import("../core/config.zig");
const instances = @import("../core/instances.zig");
const instance_preparation = @import("instances_manager.zig");
const tasks = @import("../core/tasks.zig");
const providers = @import("../core/content_providers.zig");
const credentials = @import("../core/credentials.zig");
const manifest = @import("../core/content_manifest.zig");
const install = @import("../core/content_install.zig");
const fs = @import("../core/content_fs.zig");
const transport = @import("../core/content_transport.zig");
const packs = @import("../core/pack_import.zig");
const instance_tx = @import("../core/instance_transactions.zig");
const game_metadata = @import("../core/minecraft/metadata/root.zig");
const metadata_loader = @import("../core/minecraft/metadata_loader.zig");
const game_plan = @import("../core/minecraft/install_plan.zig");
const native_verify = @import("../core/minecraft/native_extract.zig");
const builtin = @import("builtin");
const A = std.mem.Allocator;
const Io = std.Io;
pub const Kind = enum { mod, resourcepack, shader, modpack };
pub const OptionalChoice = struct { path: []const u8, include: bool };
pub const Proposal = struct {
    files: []const manifest.InstallFile = &.{},
    manual_files: []const install.ManualFile = &.{},
    pack: ?manifest.PackPlan = null,
    plan: manifest.UpdatePlan,
    desired: ?manifest.Manifest = null,
    prerequisites: manifest.CompletionPrerequisites = .{},
    stage_path: ?[]const u8 = null,
    ready: bool = false,
    dependencies_ready: bool = false,
    missing_manual: usize = 0,
    blocker: ?anyerror = null,
    root: ?providers.VersionKey = null,
    kind: Kind = .mod,
    choices: []const providers.DependencyChoice = &.{},
    legacy_identity: ?manifest.PackIdentity = null,
    legacy_approvals: []const manifest.LegacyApproval = &.{},
};
pub const Snapshot = struct {
    instance: ?config.Instance = null,
    provider: providers.Provider = .modrinth,
    policy_generation: u64 = 0,
    curseforge_available: bool = false,
    pack_membership: ?manifest.PackMembership = null,
    catalog: []const providers.Project = &.{},
    versions: []const providers.Version = &.{},
    candidates: []const providers.Version = &.{},
    dependency_issues: []const providers.DependencyIssue = &.{},
    proposal: ?*const Proposal = null,
    installed: []const manifest.ManagedFile = &.{},
    transactions: []const []const u8 = &.{},
    report: ?*const install.Report = null,
    busy: bool = false,
    recovery_required: bool = false,
    failure: ?anyerror = null,
    progress: ?tasks.Progress = null,
};
pub const CurseForgePolicy = struct {
    enabled: bool = false,
    terms_approved: bool = false,
    credential_ref: ?credentials.Reference = null,
};
pub const Options = struct {
    lease: install.Lease,
    transport_options: transport.Adapter.Options = .{},
    fixture_fault: ?install.Fault = null,
    curseforge: CurseForgePolicy = .{},
    fixture_credential_store: ?credentials.Store = null,
    allow_curseforge_remote: bool = false,
    allow_manifest_v2: bool = false,
    /// Keep the adapter context frozen until the worker has canceled and joined.
    vanilla_preparation: instance_preparation.VanillaPreparationAdapter = .{},
    fixture_spawn_failure: ?anyerror = null,
};
const ResolveRequest = struct {
    proposal: Proposal,
    candidates: []const providers.Version,
    choices: []const providers.DependencyChoice,
    decisions: []const manifest.ConflictDecision,
    manual_files: []const install.ManualFile,
    optional: []const OptionalChoice,
};
const Request = union(enum) {
    refresh,
    search: struct { query: []const u8, kind: Kind, offset: u32, provider: providers.Provider },
    versions: struct { project: providers.Project, kind: Kind },
    prepare: struct { version: providers.Version, kind: Kind, choices: []const providers.DependencyChoice },
    import_pack: struct { absolute_path: []const u8, identity: manifest.PackIdentity },
    inspected_pack: manifest.PackIdentity,
    update: struct { provider: providers.Provider, project_id: []const u8, version_id: []const u8, kind: Kind, legacy_identity: ?manifest.PackIdentity = null, legacy_approvals: []const manifest.LegacyApproval = &.{} },
    resolve: ResolveRequest,
    resolve_pack_references: ResolveRequest,
    commit: Proposal,
    remove: []const u8,
    enabled_state: struct { path: []const u8, enabled: bool },
    recover: []const u8,
};

fn clone(comptime T: type, a: A, value: T) anyerror!T {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var result: T = undefined;
            inline for (info.fields) |field| @field(result, field.name) = try clone(field.type, a, @field(value, field.name));
            return result;
        },
        .@"union" => |info| {
            const tag = std.meta.activeTag(value);
            inline for (info.fields) |field| if (tag == @field(info.tag_type.?, field.name)) return @unionInit(T, field.name, try clone(field.type, a, @field(value, field.name)));
            unreachable;
        },
        .optional => |info| {
            if (@typeInfo(info.child) == .error_set) return value;
            return if (value) |some| try clone(info.child, a, some) else null;
        },
        .pointer => |info| {
            if (info.size != .slice) @compileError("Only slices are cloned");
            const result = try a.alloc(info.child, value.len);
            for (value, result) |item, *dest| dest.* = try clone(info.child, a, item);
            return result;
        },
        else => return value,
    }
}
const Selection = struct {
    arena: std.heap.ArenaAllocator,
    instance: config.Instance,
    fn create(a: A, instance: config.Instance) !*Selection {
        const self = try a.create(Selection);
        errdefer a.destroy(self);
        self.* = .{ .arena = .init(a), .instance = undefined };
        errdefer self.arena.deinit();
        self.instance = try clone(config.Instance, self.arena.allocator(), instance);
        return self;
    }
    fn destroy(self: *Selection, a: A) void {
        self.arena.deinit();
        a.destroy(self);
    }
};
const Result = struct {
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    catalog: ?providers.Catalog = null,
    versions: ?providers.VersionSet = null,
    candidates: []const providers.Version = &.{},
    dependency_issues: []const providers.DependencyIssue = &.{},
    proposal: ?Proposal = null,
    installed: ?manifest.Manifest = null,
    transactions: ?[]const []const u8 = null,
    report: ?install.Report = null,
    fn deinit(self: *Result) void {
        if (self.report) |*report| report.deinit();
        self.arena.deinit();
    }
};
const Job = struct {
    allocator: A,
    arena: std.heap.ArenaAllocator,
    io: Io,
    paths: instances.Paths,
    instance: config.Instance,
    request: Request,
    options: Options,
    connections: u16,
    legacy_identity: ?manifest.PackIdentity = null,
    legacy_approvals: []const manifest.LegacyApproval = &.{},
    task: ?*tasks.Task = null,
    held: bool = false,
    borrowed_hold: bool = false,
    recovery_verified: bool = false,
    current: bool = true,
    done: std.atomic.Value(bool) = .init(false),
    future: ?Io.Future(void) = null,
    failure: ?anyerror = null,
    result: Result = .{},
    next_retired: ?*Job = null,
    cleanup_retired: ?*Job = null,
    cleanup_preview: ?*Job = null,
    stage_discarded: bool = false,
    inspection: ?packs.Inspection = null,
    metadata_requests: usize = 0,
    fn create(a: A, io: Io, paths: *const instances.Paths, instance: config.Instance, request: Request, options: Options, connections: u16) !*Job {
        const self = try a.create(Job);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .arena = .init(a), .io = io, .paths = paths.*, .instance = undefined, .request = undefined, .options = options, .connections = connections };
        errdefer self.arena.deinit();
        const owned = self.arena.allocator();
        self.paths.root = try owned.dupe(u8, paths.root);
        self.paths.minecraft = try owned.dupe(u8, paths.minecraft);
        self.paths.vela = try owned.dupe(u8, paths.vela);
        self.options.transport_options.approved_download_hosts = try clone([]const []const u8, owned, options.transport_options.approved_download_hosts);
        self.options.transport_options.http.proxy = try clone(?[]const u8, owned, options.transport_options.http.proxy);
        self.options.transport_options.http.ca_bundle = try clone(?[]const u8, owned, options.transport_options.http.ca_bundle);
        self.instance = try clone(config.Instance, owned, instance);
        self.request = try clone(Request, owned, request);
        // Paths methods allocate on the owning worker, never the UI allocator.
        self.paths.allocator = std.heap.page_allocator;
        return self;
    }
    fn destroy(self: *Job) void {
        if (self.inspection) |*inspection| inspection.deinit();
        self.result.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
    fn stage(self: *const Job) ?[]const u8 {
        return if (self.result.proposal) |proposal| proposal.stage_path else null;
    }
    fn discardStage(self: *Job) void {
        const path = self.stage() orelse {
            self.stage_discarded = true;
            return;
        };
        if (self.stage_discarded) return;
        packs.cleanup(self.io, path) catch |err| {
            if (err != error.FileNotFound) return;
        };
        self.stage_discarded = true;
    }
    fn discardReserved(self: *Job, old: *Job) void {
        if (!std.mem.eql(u8, self.instance.id, old.instance.id)) return;
        nestedAcquire(self, self.instance.id) catch return;
        old.discardStage();
    }
    fn cleanupWork(self: *Job) void {
        var retired = self.cleanup_retired;
        while (retired) |old| : (retired = old.next_retired) self.discardReserved(old);
        if (self.cleanup_preview) |old| {
            if (self.failure == null and !optionalEqual(self.stage(), old.stage())) self.discardReserved(old);
        }
        if (self.failure != null and self.stage() != null) {
            const retained = if (self.cleanup_preview) |old| old.stage() else null;
            if (!optionalEqual(self.stage(), retained)) self.discardReserved(self);
        }
        if (self.inspection) |*inspection| {
            if (self.held) inspection.cleanup(self.io) catch {};
        }
    }
    fn nestedAcquire(context: ?*anyopaque, id: []const u8) anyerror!void {
        const self: *Job = @ptrCast(@alignCast(context.?));
        if (!self.held or !std.mem.eql(u8, id, self.instance.id)) return error.LeaseNotHeld;
        try self.options.lease.recheck(self.options.lease.context, id);
    }
    fn nestedRelease(_: ?*anyopaque, _: []const u8) void {}
    fn nestedLease(self: *Job) install.Lease {
        return .{ .context = self, .acquire = nestedAcquire, .recheck = nestedAcquire, .release = nestedRelease };
    }
    fn cancelToken(self: *Job) *const std.atomic.Value(bool) {
        return &self.task.?.cancellation;
    }
    fn check(self: *Job) !void {
        try fs.cancelled(self.io, self.cancelToken(), null);
        if (self.held) try nestedAcquire(self, self.instance.id);
    }
    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        defer self.cleanupWork();
        runBackend(self) catch |err| {
            self.failure = err;
            if (err == error.RecoveryRequired) {
                var pending = if (@hasDecl(install, "listPendingTransactions")) install.listPendingTransactions(std.heap.page_allocator, self.io, &self.paths, self.instance.id, self.instance.name) catch return else install.listTransactions(std.heap.page_allocator, self.io, &self.paths, self.instance.id, self.instance.name) catch return;
                defer pending.deinit();
                self.result.transactions = clone([]const []const u8, self.result.arena.allocator(), pending.value) catch null;
            }
        };
    }
};

pub const Manager = struct {
    allocator: A,
    io: Io,
    paths: *const instances.Paths,
    registry: *tasks.Registry,
    options: Options,
    provider: providers.Provider = .modrinth,
    policy_generation: u64 = 0,
    connections: u16 = 8,
    selected: ?*Selection = null,
    active: ?*Job = null,
    pinned: ?*Job = null,
    recovery_attempt: ?*Job = null,
    catalog_job: ?*Job = null,
    versions_job: ?*Job = null,
    proposal_job: ?*Job = null,
    local_job: ?*Job = null,
    report_job: ?*Job = null,
    retired_stages: ?*Job = null,
    pending_refresh: bool = false,
    joining: bool = false,
    failure: ?anyerror = null,
    pub fn init(a: A, io: Io, paths: *const instances.Paths, registry: *tasks.Registry, lease: install.Lease) !Manager {
        return initOptions(a, io, paths, registry, .{ .lease = lease });
    }
    pub fn initOptions(a: A, io: Io, paths: *const instances.Paths, registry: *tasks.Registry, options: Options) !Manager {
        return .{ .allocator = a, .io = io, .paths = paths, .registry = registry, .options = options };
    }
    pub fn deinit(self: *Manager) void {
        self.cancel();
        if (self.active) |job| {
            if (job.future) |*future| future.await(self.io);
            self.finishTask(job);
            self.release(job);
            self.retireOwned(job, null);
            self.active = null;
        }
        if (self.recovery_attempt) |job| job.destroy();
        if (self.pinned) |job| {
            self.release(job);
            job.destroy();
        }
        self.pinned = null;
        self.recovery_attempt = null;
        self.clearPublished();
        self.cleanupRetiredShutdown();
        while (self.retired_stages) |old| {
            self.retired_stages = old.next_retired;
            old.destroy();
        }
        if (self.selected) |selection| selection.destroy(self.allocator);
        self.selected = null;
    }
    fn retireOwned(self: *Manager, job: *Job, next_stage: ?[]const u8) void {
        if (!job.stage_discarded and job.stage() != null and !optionalEqual(job.stage(), next_stage)) {
            job.next_retired = self.retired_stages;
            self.retired_stages = job;
        } else job.destroy();
    }
    fn retirePreview(self: *Manager, next_stage: ?[]const u8) void {
        if (self.proposal_job) |old| self.retireOwned(old, next_stage);
        self.proposal_job = null;
    }
    fn collectRetired(self: *Manager) void {
        var cursor = &self.retired_stages;
        while (cursor.*) |old| {
            if (old.stage_discarded) {
                cursor.* = old.next_retired;
                old.destroy();
            } else cursor = &old.next_retired;
        }
    }
    fn cleanupRetiredShutdown(self: *Manager) void {
        if (self.retired_stages == null) return;
        const task = self.registry.create(.modpack_install, "Discard staged packs") catch return;
        self.registry.start(task) catch |err| {
            self.registry.finish(task, .{ .failed = err });
            return;
        };
        var cleanup_error: ?anyerror = null;
        var node = self.retired_stages;
        while (node) |old| : (node = old.next_retired) {
            if (old.stage_discarded) continue;
            self.options.lease.acquire(self.options.lease.context, old.instance.id) catch |err| {
                if (cleanup_error == null) cleanup_error = err;
                continue;
            };
            var future = self.io.concurrent(Job.discardStage, .{old}) catch |err| {
                self.options.lease.release(self.options.lease.context, old.instance.id);
                if (cleanup_error == null) cleanup_error = err;
                continue;
            };
            future.await(self.io);
            self.options.lease.release(self.options.lease.context, old.instance.id);
            if (!old.stage_discarded and cleanup_error == null) cleanup_error = error.StageCleanupFailed;
        }
        self.registry.finish(task, if (cleanup_error) |err| .{ .failed = err } else .succeeded);
        self.collectRetired();
    }
    fn clearPublished(self: *Manager) void {
        self.retirePreview(null);
        inline for (.{ "catalog_job", "versions_job", "local_job", "report_job" }) |field| {
            if (@field(self, field)) |job| job.destroy();
            @field(self, field) = null;
        }
    }
    pub fn select(self: *Manager, instance: ?config.Instance) !void {
        if (self.pinned != null) return error.RecoveryRequired;
        if (self.active) |job| if (job.held) return error.ContentWorkerBusy;
        if (instance) |value| {
            if (!config.validId(value.id) or !config.validId(value.name)) return error.UnsafeInstance;
            if (self.selected) |selected| if (sameInstance(selected.instance, value)) return;
        } else if (self.selected == null) return;
        const next = if (instance) |value| try Selection.create(self.allocator, value) else null;
        self.cancel();
        if (self.active) |job| job.current = false;
        self.clearPublished();
        if (self.selected) |old| old.destroy(self.allocator);
        self.selected = next;
        self.policy_generation +%= 1;
        self.failure = null;
        self.pending_refresh = next != null;
        if (self.active == null and self.pending_refresh) {
            self.pending_refresh = false;
            self.refresh() catch |err| {
                self.failure = err;
            };
        }
    }
    pub fn snapshot(self: *const Manager) Snapshot {
        var snap: Snapshot = .{ .instance = if (self.pinned) |job| job.instance else if (self.selected) |selected| selected.instance else null, .provider = self.provider, .policy_generation = self.policy_generation, .curseforge_available = self.canResolvePackReferences(), .busy = self.isBusy(), .failure = self.failure };
        if (self.catalog_job) |job| if (job.result.catalog) |catalog| {
            snap.catalog = catalog.projects;
        };
        if (self.versions_job) |job| if (job.result.versions) |versions| {
            snap.versions = versions.versions;
        };
        if (self.proposal_job) |job| {
            snap.candidates = job.result.candidates;
            snap.dependency_issues = job.result.dependency_issues;
            if (job.result.proposal) |*proposal| snap.proposal = proposal;
        }
        if (self.local_job) |job| {
            if (job.result.installed) |installed| {
                snap.installed = installed.files;
                snap.pack_membership = installed.pack_membership;
            }
            snap.transactions = job.result.transactions orelse &.{};
        }
        if (self.report_job) |job| if (job.result.report) |*report| {
            snap.report = report;
        };
        if (self.pinned) |job| {
            snap.transactions = if (self.recovery_attempt) |attempt| attempt.result.transactions orelse job.result.transactions orelse &.{} else job.result.transactions orelse &.{};
            snap.recovery_required = true;
        }
        if (self.active) |job| if (job.task) |task| {
            snap.progress = task.progress();
        };
        return snap;
    }
    pub fn isBusy(self: *const Manager) bool {
        return self.active != null or self.pending_refresh;
    }
    pub fn setDownloadConnections(self: *Manager, connections: u16) !void {
        if (connections == 0 or connections > 64) return error.InvalidConnections;
        self.connections = connections;
    }
    pub fn cancel(self: *Manager) void {
        self.pending_refresh = false;
        if (self.active) |job| if (job.task) |task| {
            _ = self.registry.cancel(task.id);
        };
    }
    /// Shutdown only: join the owned worker and publish its outcome through tick.
    pub fn cancelAndJoin(self: *Manager) void {
        self.cancel();
        self.joining = true;
        defer {
            self.joining = false;
            self.pending_refresh = false;
        }
        if (self.active) |job| {
            if (job.future) |*future| future.await(self.io);
            self.tick();
        }
    }
    pub fn refresh(self: *Manager) !void {
        try self.start(.refresh);
    }
    pub fn search(self: *Manager, query: []const u8, kind: Kind, offset: u32) !void {
        if (query.len > 512 or !std.unicode.utf8ValidateSlice(query)) return error.InvalidQuery;
        if (self.provider == .curseforge and !self.canResolvePackReferences()) return error.ProviderDisabled;
        try self.start(.{ .search = .{ .query = query, .kind = kind, .offset = offset, .provider = self.provider } });
    }
    pub fn loadVersions(self: *Manager, project: providers.Project, kind: Kind) !void {
        if (project.provider != self.provider) return error.ProviderMismatch;
        if (project.provider == .curseforge and !self.canResolvePackReferences()) return error.ProviderDisabled;
        if (!providers.validToken(project.id)) return error.InvalidId;
        try self.start(.{ .versions = .{ .project = project, .kind = kind } });
    }
    pub fn prepareVersion(self: *Manager, version: providers.Version, kind: Kind, choices: []const providers.DependencyChoice) !void {
        if (!providers.validToken(version.id) or !providers.validToken(version.project_id)) return error.InvalidId;
        if (version.provider == .curseforge and !self.canResolvePackReferences()) return error.ProviderDisabled;
        try self.start(.{ .prepare = .{ .version = version, .kind = kind, .choices = choices } });
    }
    pub fn prepareUpdate(self: *Manager, provider: providers.Provider, project_id: []const u8, version_id: []const u8, kind: Kind) !void {
        if (!providers.validToken(project_id) or !providers.validToken(version_id)) return error.InvalidId;
        if (provider == .curseforge and !self.canResolvePackReferences()) return error.ProviderDisabled;
        try self.start(.{ .update = .{ .provider = provider, .project_id = project_id, .version_id = version_id, .kind = kind } });
    }
    pub fn prepareLegacyUpdate(self: *Manager, recorded_identity: manifest.PackIdentity, approvals: []const manifest.LegacyApproval, version_id: []const u8, kind: Kind) !void {
        if (!providers.validToken(recorded_identity.project_id) or !providers.validToken(recorded_identity.version_id) or !providers.validToken(version_id) or approvals.len == 0) return error.InvalidChoice;
        if (recorded_identity.provider == .curseforge and !self.canResolvePackReferences()) return error.ProviderDisabled;
        try self.start(.{ .update = .{ .provider = recorded_identity.provider, .project_id = recorded_identity.project_id, .version_id = version_id, .kind = kind, .legacy_identity = recorded_identity, .legacy_approvals = approvals } });
    }
    pub fn selectProvider(self: *Manager, provider: providers.Provider) !void {
        if (self.provider == provider) return;
        if (self.isBusy()) return error.ContentWorkerBusy;
        if (self.pinned != null) return error.RecoveryRequired;
        if (provider == .curseforge and !self.canResolvePackReferences()) return error.ProviderDisabled;
        if (provider != .modrinth and provider != .curseforge) return error.ProviderDisabled;
        self.clearPublished();
        self.provider = provider;
        self.policy_generation +%= 1;
        self.pending_refresh = self.selected != null;
    }
    pub fn importInspectedFor(self: *Manager, inspection: *packs.Inspection, identity: manifest.PackIdentity) !void {
        if (!providers.validToken(identity.project_id) or !providers.validToken(identity.version_id)) return error.InvalidId;
        if (inspection.provider != identity.provider or inspection.pack.identity.provider != inspection.provider) return error.ProviderMismatch;
        try validateAbsolute(inspection.archive_absolute_path);
        for (inspection.source_sha256) |byte| if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.ArchiveIdentityMismatch;
        try validateAbsolute(inspection.stage_absolute_path);
        try self.startOwned(.{ .inspected_pack = identity }, inspection);
    }
    pub fn importPack(self: *Manager, absolute_path: []const u8) !void {
        const selected = self.selected orelse return error.NoSelectedInstance;
        const origin = selected.instance.origin orelse return error.PackIdentityRequired;
        try self.importPackFor(absolute_path, .{ .provider = origin.kind, .project_id = origin.project_id, .version_id = origin.version_id });
    }
    pub fn importPackFor(self: *Manager, absolute_path: []const u8, identity: manifest.PackIdentity) !void {
        try validateAbsolute(absolute_path);
        if (!providers.validToken(identity.project_id) or !providers.validToken(identity.version_id)) return error.InvalidId;
        try self.start(.{ .import_pack = .{ .absolute_path = absolute_path, .identity = identity } });
    }
    pub fn setCurseForgePolicy(self: *Manager, policy: CurseForgePolicy) !void {
        if (self.isBusy()) return error.ContentWorkerBusy;
        if (self.pinned != null) return error.RecoveryRequired;
        if (policy.credential_ref) |reference| if (!credentials.validateReference(&reference)) return error.InvalidReference;
        if (std.meta.eql(self.options.curseforge, policy)) return;
        self.options.curseforge = policy;
        self.policy_generation +%= 1;
        self.clearPublished();
        if (self.provider == .curseforge and !self.canResolvePackReferences()) self.provider = .modrinth;
        self.pending_refresh = self.selected != null;
    }
    pub fn canResolvePackReferences(self: *const Manager) bool {
        const policy = self.options.curseforge;
        const reference = policy.credential_ref orelse return false;
        return policy.enabled and policy.terms_approved and credentials.validateReference(&reference) and self.options.transport_options.allow_curseforge;
    }
    pub fn resolvePackReferences(self: *Manager, choices: []const providers.DependencyChoice, decisions: []const manifest.ConflictDecision, manual_files: []const install.ManualFile, optional: []const OptionalChoice) !void {
        if (self.isBusy()) return error.ContentWorkerBusy;
        if (!self.canResolvePackReferences()) return error.ProviderDisabled;
        const snap = self.snapshot();
        const proposal = snap.proposal orelse return error.NoProposal;
        const pack = proposal.pack orelse return error.NoPack;
        if (pack.identity.provider != .curseforge) return error.ProviderMismatch;
        for (manual_files) |file| {
            if (!manifest.safeRelativePath(file.path)) return error.UnsafePath;
            try validateAbsolute(file.source_absolute_path);
        }
        try self.start(.{ .resolve_pack_references = .{ .proposal = proposal.*, .candidates = snap.candidates, .choices = choices, .decisions = decisions, .manual_files = manual_files, .optional = optional } });
    }
    pub fn resolve(self: *Manager, choices: []const providers.DependencyChoice, decisions: []const manifest.ConflictDecision, manual_files: []const install.ManualFile, optional: []const OptionalChoice) !void {
        const snap = self.snapshot();
        const proposal = snap.proposal orelse return error.NoProposal;
        for (manual_files) |file| {
            if (!manifest.safeRelativePath(file.path)) return error.UnsafePath;
            try validateAbsolute(file.source_absolute_path);
        }
        try self.start(.{ .resolve = .{ .proposal = proposal.*, .candidates = snap.candidates, .choices = choices, .decisions = decisions, .manual_files = manual_files, .optional = optional } });
    }
    pub fn commit(self: *Manager) !void {
        const proposal = self.snapshot().proposal orelse return error.NoProposal;
        if (!proposal.ready) return error.IncompleteContent;
        try self.start(.{ .commit = proposal.* });
    }
    pub fn prepareEnabled(self: *Manager, path: []const u8, enabled: bool) !void {
        if (!manifest.safeRelativePath(path) or manifest.protectedPath(path)) return error.UnsafePath;
        try self.start(.{ .enabled_state = .{ .path = path, .enabled = enabled } });
    }
    pub fn prepareRemove(self: *Manager, path: []const u8) !void {
        if (!manifest.safeRelativePath(path) or manifest.protectedPath(path)) return error.UnsafePath;
        try self.start(.{ .remove = path });
    }
    pub fn recover(self: *Manager, transaction_id: []const u8) !void {
        if (!config.validId(transaction_id) or !std.mem.startsWith(u8, transaction_id, "txn-")) return error.UnsafeTransaction;
        try self.start(.{ .recover = transaction_id });
    }
    fn start(self: *Manager, request: Request) !void {
        try self.startOwned(request, null);
    }
    fn startOwned(self: *Manager, request: Request, inspection: ?*packs.Inspection) !void {
        if (self.isBusy()) return error.ContentWorkerBusy;
        if (self.pinned != null and request != .recover) return error.RecoveryRequired;
        const instance = if (self.pinned) |pinned| pinned.instance else if (self.selected) |selected| selected.instance else return error.NoSelectedInstance;
        const job = try Job.create(self.allocator, self.io, self.paths, instance, request, self.options, self.connections);
        errdefer job.destroy();
        const needs_lease = request != .search and request != .versions;
        if (self.pinned != null) {
            try self.options.lease.recheck(self.options.lease.context, instance.id);
            job.held = true;
            job.borrowed_hold = true;
        } else if (needs_lease) {
            try self.options.lease.acquire(self.options.lease.context, instance.id);
            job.held = true;
        }
        errdefer self.release(job);
        if (job.held) {
            job.cleanup_retired = self.retired_stages;
            if (request == .prepare or request == .update or request == .import_pack or request == .inspected_pack or request == .remove or request == .enabled_state or request == .commit or request == .recover) job.cleanup_preview = self.proposal_job;
        }
        const kind: tasks.Kind = if (request == .import_pack or request == .inspected_pack or request == .resolve_pack_references or (request == .prepare and request.prepare.kind == .modpack) or (request == .update and request.update.kind == .modpack)) .modpack_install else .mod_install;
        const task = try self.registry.create(kind, title(request));
        job.task = task;
        self.registry.start(task) catch |err| {
            self.registry.finish(task, .{ .failed = err });
            return err;
        };
        task.report(if (request == .commit) .installing else if (request == .import_pack) .extracting else .metadata, 0, null);
        if (inspection) |owned| job.inspection = owned.*;
        if (self.options.fixture_spawn_failure) |err| {
            job.inspection = null;
            self.registry.finish(task, .{ .failed = err });
            return err;
        }
        job.future = self.io.concurrent(Job.run, .{job}) catch |err| {
            // A rejected spawn has not adopted the caller's inspection.
            job.inspection = null;
            self.registry.finish(task, .{ .failed = err });
            return err;
        };
        if (inspection) |owned| owned.* = undefined;
        self.active = job;
        self.failure = null;
    }
    fn release(self: *Manager, job: *Job) void {
        if (job.held and !job.borrowed_hold) {
            self.options.lease.release(self.options.lease.context, job.instance.id);
            job.held = false;
        }
    }
    fn finishTask(self: *Manager, job: *Job) void {
        const committed = if (job.request == .recover) job.recovery_verified else if (job.result.report) |report| report.committed else false;
        const outcome: tasks.Outcome = if (committed) .succeeded else if (job.failure) |err| if (err == error.Canceled) .canceled else .{ .failed = err } else .succeeded;
        if (job.task) |task| self.registry.finish(task, outcome);
    }
    pub fn tick(self: *Manager) void {
        if (self.active) |job| {
            if (!job.done.load(.acquire)) return;
            if (job.future) |*future| future.await(self.io);
            self.active = null;
            self.collectRetired();
            self.finishTask(job);
            if (job.failure != null and job.failure.? == error.RecoveryRequired) {
                self.pending_refresh = false;
                self.failure = error.RecoveryRequired;
                if (self.pinned == null) {
                    self.pinned = job;
                } else {
                    if (self.recovery_attempt) |old| old.destroy();
                    self.recovery_attempt = job;
                }
                return;
            }
            if (self.pinned) |pinned| {
                if (!job.recovery_verified) {
                    self.failure = job.failure orelse error.RecoveryRequired;
                    if (self.recovery_attempt) |old| old.destroy();
                    self.recovery_attempt = job;
                    return;
                }
                if (self.recovery_attempt) |old| old.destroy();
                self.recovery_attempt = null;
                self.release(pinned);
                pinned.destroy();
                self.pinned = null;
                job.held = false;
                job.borrowed_hold = false;
            }
            self.release(job);
            if (!job.current) job.destroy() else {
                const committed = if (job.result.report) |report| report.committed or report.recovered else false;
                if (job.failure != null and !committed) {
                    self.failure = job.failure;
                    self.retireOwned(job, if (self.proposal_job) |old| old.stage() else null);
                } else {
                    self.failure = if (committed) null else job.failure;
                    const field: []const u8 = switch (job.request) {
                        .search => "catalog_job",
                        .versions => "versions_job",
                        .prepare, .update, .import_pack, .inspected_pack, .resolve, .resolve_pack_references, .remove, .enabled_state => "proposal_job",
                        .commit, .recover => "report_job",
                        .refresh => "local_job",
                    };
                    inline for (.{ "catalog_job", "versions_job", "proposal_job", "local_job", "report_job" }) |name| if (std.mem.eql(u8, field, name)) {
                        if (comptime std.mem.eql(u8, name, "proposal_job")) self.retirePreview(job.stage()) else if (@field(self, name)) |old| old.destroy();
                        @field(self, name) = job;
                    };
                    if (committed) {
                        self.retirePreview(null);
                        self.pending_refresh = self.selected != null;
                    }
                }
            }
            // Coordinator publishes releases until the next app tick. Do not
            // reacquire this mutation for a refresh in the same completion poll.
            return;
        }
        if (self.active == null and self.pending_refresh and !self.joining) {
            self.pending_refresh = false;
            self.refresh() catch |err| {
                if (err == error.InstanceBusy) {
                    self.pending_refresh = true;
                    return;
                }
                self.failure = err;
            };
        }
    }
};

fn sameInstance(a: config.Instance, b: config.Instance) bool {
    return std.mem.eql(u8, a.id, b.id) and std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.minecraft_version, b.minecraft_version) and a.loader == b.loader and optionalEqual(a.loader_version, b.loader_version);
}
fn optionalEqual(a: ?[]const u8, b: ?[]const u8) bool {
    return if (a) |left| if (b) |right| std.mem.eql(u8, left, right) else false else b == null;
}
fn validateAbsolute(path: []const u8) !void {
    if (path.len == 0 or path.len > 4096 or !std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.AbsolutePathRequired;
}
fn title(request: Request) []const u8 {
    return switch (request) {
        .search => "Content search",
        .versions => "Content versions",
        .prepare, .update, .resolve, .resolve_pack_references => "Review content",
        .import_pack, .inspected_pack => "Import modpack",
        .commit => "Install content",
        .remove => "Review removal",
        .enabled_state => |request_state| if (request_state.enabled) "Review enabling mod" else "Review disabling mod",
        .recover => "Recover content",
        .refresh => "Installed content",
    };
}

fn gameDirectory(job: *Job) !?Io.Dir {
    const root = try fs.openAbsolute(job.io, job.paths.root);
    defer root.close(job.io);
    const minecraft = fs.child(root, job.io, ".minecraft", false, false) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer minecraft.close(job.io);
    const versions = fs.child(minecraft, job.io, "versions", false, false) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer versions.close(job.io);
    return fs.child(versions, job.io, job.instance.name, false, false) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
}
fn readManifest(job: *Job, a: A) !manifest.Manifest {
    const empty: manifest.Manifest = .{ .instance_id = job.instance.id, .pack_version = "local", .files = &.{} };
    const root = try fs.openAbsolute(job.io, job.paths.root);
    defer root.close(job.io);
    const vela = fs.child(root, job.io, ".vela", false, false) catch |err| switch (err) {
        error.FileNotFound => return try clone(manifest.Manifest, a, empty),
        else => return err,
    };
    defer vela.close(job.io);
    const entries = fs.child(vela, job.io, "instances", false, false) catch |err| switch (err) {
        error.FileNotFound => return try clone(manifest.Manifest, a, empty),
        else => return err,
    };
    defer entries.close(job.io);
    const metadata = fs.child(entries, job.io, job.instance.id, false, false) catch |err| switch (err) {
        error.FileNotFound => return try clone(manifest.Manifest, a, empty),
        else => return err,
    };
    defer metadata.close(job.io);
    const bytes = fs.read(a, metadata, job.io, "content.json", providers.max_json_bytes) catch |err| switch (err) {
        error.FileNotFound => return try clone(manifest.Manifest, a, empty),
        else => return err,
    };
    var parsed = try manifest.parse(a, bytes);
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.instance_id, job.instance.id)) return error.InstanceMismatch;
    return try clone(manifest.Manifest, a, parsed.value);
}
fn localSnapshot(job: *Job) !void {
    const a = job.result.arena.allocator();
    job.result.installed = try readManifest(job, a);
    var transactions = install.listTransactions(a, job.io, &job.paths, job.instance.id, job.instance.name) catch |err| switch (err) {
        error.FileNotFound => {
            job.result.transactions = &.{};
            return;
        },
        else => return err,
    };
    defer transactions.deinit();
    job.result.transactions = try clone([]const []const u8, a, transactions.value);
}
fn fingerprintRecord(a: A, value: fs.Fingerprint) !manifest.ObservedFile {
    return .{ .path = "", .hashes = .{ .sha1 = try a.dupe(u8, &value.sha1), .sha256 = try a.dupe(u8, &value.sha256), .sha512 = try a.dupe(u8, &value.sha512) }, .size = value.size };
}
fn observe(job: *Job, a: A, previous: manifest.Manifest, desired: manifest.Manifest) ![]const manifest.ObservedFile {
    const game = (try gameDirectory(job)) orelse return &.{};
    defer game.close(job.io);
    var records: std.ArrayList(manifest.ObservedFile) = .empty;
    for ([_][]const manifest.ManagedFile{ previous.files, desired.files }) |files| for (files) |file| {
        var seen = false;
        for (records.items) |record| if (std.ascii.eqlIgnoreCase(file.path, record.path)) {
            seen = true;
            break;
        };
        if (seen) continue;
        try job.check();
        if (manifest.toggleable(file)) {
            var counterpart = file;
            counterpart.enabled = !file.enabled;
            const reserved = try manifest.physicalPath(a, counterpart);
            const parent = fs.parent(game, job.io, reserved, false) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            if (parent) |entry| {
                defer entry.deinit(job.io);
                if (try fs.inspectEntry(entry.dir, job.io, entry.name) != null) return error.PathAlreadyExists;
            }
        }
        const physical = try manifest.physicalPath(a, file);
        const found = (try fs.fingerprint(game, job.io, physical, job.cancelToken(), null)) orelse continue;
        var record = try fingerprintRecord(a, found);
        record.path = try a.dupe(u8, file.path);
        try records.append(a, record);
    };
    return try records.toOwnedSlice(a);
}
fn desiredFor(a: A, previous: manifest.Manifest, files: []const manifest.InstallFile, pack: ?manifest.PackPlan, legacy_paths: []const []const u8) !manifest.Manifest {
    var records: std.ArrayList(manifest.ManagedFile) = .empty;
    var replacement: ?providers.Owned([]const []const u8) = null;
    defer if (replacement) |*owned| owned.deinit();
    if (pack) |value| replacement = try manifest.packReplacementPaths(a, previous, value.identity);
    for (previous.files) |old| {
        var replaced = false;
        for (legacy_paths) |path| if (std.mem.eql(u8, path, old.path)) {
            replaced = true;
            break;
        };
        if (replacement) |owned| for (owned.value) |path| {
            if (std.mem.eql(u8, path, old.path)) {
                replaced = true;
                break;
            }
        };
        if (pack == null) for (files) |new| {
            if (new.selected == false or (!new.required and new.selected == null)) continue;
            if (old.standalone and new.record.standalone and old.identity_provenance == .official_file and old.provider == new.record.provider and std.mem.eql(u8, old.project_id, new.record.project_id)) {
                replaced = true;
                break;
            }
        };
        if (!replaced) try records.append(a, old);
    }
    for (files) |file| if (file.selected != false) {
        if (!file.required and file.selected == null) continue;
        try records.append(a, file.record);
    };
    var membership = previous.pack_membership;
    if (pack) |value| {
        var owned = try manifest.membershipForPack(a, value);
        defer owned.deinit();
        membership = try clone(manifest.PackMembership, a, owned.value);
    } else if (membership) |value| {
        var paths: std.ArrayList([]const u8) = .empty;
        for (value.paths) |path| for (records.items) |file| {
            if (std.mem.eql(u8, path, file.path) and !file.standalone) {
                try paths.append(a, path);
                break;
            }
        };
        membership = .{ .identity = value.identity, .paths = try paths.toOwnedSlice(a) };
    }
    const desired: manifest.Manifest = .{ .schema_version = 2, .instance_id = previous.instance_id, .pack_version = if (pack) |value| value.identity.version_id else previous.pack_version, .files = try records.toOwnedSlice(a), .pack_membership = membership };
    try manifest.validate(desired);
    const bytes = try manifest.serialize(a, desired);
    defer a.free(bytes);
    var readback = try manifest.parse(a, bytes);
    defer readback.deinit();
    const replay = try manifest.serialize(a, readback.value);
    defer a.free(replay);
    if (!std.mem.eql(u8, replay, bytes)) return error.ReceiptReadbackMismatch;
    return desired;
}
fn verifyManual(job: *Job, file: manifest.InstallFile, mappings: []const install.ManualFile) !bool {
    for (mappings) |mapping| if (std.mem.eql(u8, mapping.path, file.record.path)) {
        try validateAbsolute(mapping.source_absolute_path);
        const dir = try fs.openAbsolute(job.io, std.fs.path.dirname(mapping.source_absolute_path) orelse return error.UnsafePath);
        defer dir.close(job.io);
        const source = try fs.openRegular(dir, job.io, std.fs.path.basename(mapping.source_absolute_path));
        defer source.close(job.io);
        const actual = try fs.stream(source, null, job.io, providers.max_file_bytes, job.cancelToken(), null);
        try actual.verify(file.record.hashes, file.record.size);
        return true;
    };
    return false;
}
test "content manager verifies exact index snapshot after a path replacement" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const original = try std.json.Stringify.valueAlloc(a, .{ .objects = std.json.Value{ .object = .empty } }, .{});
    defer a.free(original);
    var expected: game_metadata.Sha1 = undefined;
    std.crypto.hash.Sha1.hash(original, &expected, .{});
    const expected_hex = std.fmt.bytesToHex(&expected, .lower);
    try tmp.dir.writeFile(io, .{ .sub_path = "index.json", .data = original });
    const verified = (try fs.fingerprint(tmp.dir, io, "index.json", null, null)).?;
    try verified.verify(.{ .sha1 = &expected_hex }, original.len);
    const replacement = try a.dupe(u8, original);
    defer a.free(replacement);
    replacement[0] = '[';
    try tmp.dir.writeFile(io, .{ .sub_path = "index.json", .data = replacement });
    const parsed_snapshot = try fs.read(a, tmp.dir, io, "index.json", 1024);
    defer a.free(parsed_snapshot);
    try std.testing.expectError(error.HashMismatch, verifyIndexSnapshot(parsed_snapshot, expected, original.len));
    try verifyIndexSnapshot(original, expected, original.len);
    try std.testing.expectError(error.SizeMismatch, verifyIndexSnapshot(original, expected, original.len + 1));
    try std.testing.expectError(error.UnverifiableGamePrerequisite, verifyIndexSnapshot(original, expected, null));
}

fn verifyIndexSnapshot(bytes: []const u8, expected: game_metadata.Sha1, size: ?u64) !void {
    if (size == null) return error.UnverifiableGamePrerequisite;
    if (bytes.len != size.?) return error.SizeMismatch;
    var actual: game_metadata.Sha1 = undefined;
    std.crypto.hash.Sha1.hash(bytes, &actual, .{});
    if (!std.mem.eql(u8, &actual, &expected)) return error.HashMismatch;
}
fn gameReady(job: *Job) !bool {
    const a = job.result.arena.allocator();
    const canonical_vanilla = job.instance.loader == .vanilla and job.instance.loader_version == null and
        std.mem.eql(u8, job.instance.name, job.instance.minecraft_version);
    var prepared: ?metadata_loader.PreparedVanilla = null;
    defer if (prepared) |*owned| owned.deinit();
    var proof = instance_tx.inspectInstalledLeased(a, job.io, job.paths.root, job.instance, .{ .cancel = job.cancelToken() }, .{ .context = job, .recheck = Job.nestedAcquire }) catch |err| retry: {
        if (err != error.MissingInstallReceipt or !canonical_vanilla) return err;
        try job.check();
        const task = job.task orelse return error.InvalidPreparationGeneration;
        const target = try instance_preparation.existingVanillaTarget(job.paths.root, job.instance, task.id);
        const adapter = job.options.vanilla_preparation;
        prepared = try adapter.prepare(adapter.context, a, job.io, target, .{ .cancel = job.cancelToken(), .task = task });
        try job.check();
        break :retry try instance_tx.inspectInstalledLeased(a, job.io, job.paths.root, job.instance, .{
            .cancel = job.cancelToken(),
            .trusted_vanilla = .{ .prepared = &prepared.?, .generation = task.id, .environment = target.environment },
        }, .{ .context = job, .recheck = Job.nestedAcquire });
    };
    defer proof.deinit();
    if (!std.mem.eql(u8, proof.instance.id, job.instance.id) or !std.mem.eql(u8, proof.instance.name, job.instance.name) or
        !std.mem.eql(u8, proof.instance.minecraft_version, job.instance.minecraft_version) or proof.instance.loader != job.instance.loader or
        !optionalEqual(proof.instance.loader_version, job.instance.loader_version)) return error.InstalledGameIdentityMismatch;
    const game = (try gameDirectory(job)) orelse return false;
    defer game.close(job.io);
    const descriptor_name = try std.fmt.allocPrint(a, "{s}.json", .{job.instance.name});
    const bytes = try fs.read(a, game, job.io, descriptor_name, providers.max_json_bytes);
    const bindings: []const ArtifactBinding = if (canonical_vanilla and proof.local_client_verified) &.{} else try gameReceiptBindings(job, game, bytes);
    var version = try game_metadata.version.parseSlice(a, bytes);
    defer version.deinit();
    const index = version.value.asset_index orelse return error.MissingAssetIndex;
    const index_hash = index.sha1 orelse return error.UnverifiableGamePrerequisite;
    const minecraft = try fs.openAbsolute(job.io, job.paths.minecraft);
    defer minecraft.close(job.io);
    const index_path = try std.fmt.allocPrint(a, "assets/indexes/{s}.json", .{index.id});
    const index_parent = try fs.parent(minecraft, job.io, index_path, false);
    defer index_parent.deinit(job.io);
    const index_bytes = fs.read(a, index_parent.dir, job.io, index_parent.name, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    try verifyIndexSnapshot(index_bytes, index_hash, index.size);
    var assets = try game_metadata.asset_index.parseSlice(a, index_bytes);
    defer assets.deinit();
    const os_name = switch (builtin.os.tag) {
        .linux => "linux",
        .windows => "windows",
        .macos => "osx",
        else => return error.UnsupportedGamePlatform,
    };
    const game_path = try job.paths.instanceDirectory(job.instance.name);
    var plan = try game_plan.build(a, version.value, assets.value, .{ .os_name = os_name, .arch = @tagName(builtin.cpu.arch) }, .{
        .root = job.paths.minecraft,
        .instance_name = job.instance.name,
        .game_directory = game_path,
        .cpu_arch = @tagName(builtin.cpu.arch),
        .native_arch = if (@bitSizeOf(usize) == 64) .bits64 else .bits32,
    });
    defer plan.deinit();
    for (plan.value.files) |file| {
        const expected = try gameFileExpected(job, file, bindings);
        const relative = try gameRelative(job, file.path);
        const actual = (try fs.fingerprint(minecraft, job.io, relative, job.cancelToken(), null)) orelse return false;
        try actual.verify(expected.hashes, expected.size);
    }
    for (plan.value.native_checks) |check| {
        if (check.suitability == .incompatible) return error.NativePrerequisiteUnsupported;
        try verifyNativeArchive(job, minecraft, check.archive_path, plan.value.files, bindings);
    }
    // Launch extracts legacy natives; content readiness only verifies each source.
    for (plan.value.native_extractions) |extraction| {
        var checked = false;
        for (plan.value.native_checks) |check| if (std.mem.eql(u8, check.archive_path, extraction.archive_path)) {
            checked = true;
            break;
        };
        if (!checked) try verifyNativeArchive(job, minecraft, extraction.archive_path, plan.value.files, bindings);
    }
    for (plan.value.asset_materializations) |file| if (!try plannedFileReady(job, minecraft, file.destination, file.sha1, file.size)) return false;
    try Job.nestedAcquire(job, job.instance.id);
    return true;
}
const ArtifactBinding = struct { path: []const u8, sha256: []const u8, size: u64 };
const GameFileExpected = struct { hashes: providers.Hashes, size: u64 };
test "content manager native baseline rejects every source identity field" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = "source" });
    const source = try fs.openRegular(tmp.dir, io, "source");
    defer source.close(io);
    const baseline = try source.stat(io);
    try checkNativeSourceStat(baseline, baseline);
    inline for (.{ "inode", "size", "nlink", "kind", "mtime", "ctime" }) |field| {
        var changed = baseline;
        if (comptime std.mem.eql(u8, field, "kind")) {
            changed.kind = .directory;
        } else if (comptime std.mem.eql(u8, field, "mtime") or std.mem.eql(u8, field, "ctime")) {
            @field(changed, field).nanoseconds += 1;
        } else {
            @field(changed, field) += 1;
        }
        try std.testing.expectError(error.NativeSourceChanged, checkNativeSourceStat(baseline, changed));
    }
    var unsafe = baseline;
    unsafe.nlink = 2;
    try std.testing.expectError(error.NativeSourceChanged, checkNativeSourceStat(unsafe, unsafe));
    unsafe = baseline;
    unsafe.kind = .directory;
    try std.testing.expectError(error.NativeSourceChanged, checkNativeSourceStat(unsafe, unsafe));
}

test "content manager native baseline rejects wrong CPU ABA with identical trusted hashes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Hook = struct {
        var source: std.Io.File = undefined;
        var baseline: std.Io.File.Stat = undefined;
        var original: []const u8 = undefined;
        var replacement: []const u8 = undefined;
        var stats: usize = 0;
        var mutations: usize = 0;
        var delegate: @TypeOf(io.vtable.fileStat) = undefined;
        fn change(bytes: []const u8) !void {
            try source.writePositionalAll(io, bytes, 0);
            try source.setTimestamps(io, .{ .modify_timestamp = .{ .new = baseline.mtime } });
            mutations += 1;
        }
        fn stat(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.StatError!std.Io.File.Stat {
            if (file.handle != source.handle) return delegate(userdata, file);
            stats += 1;
            if (stats == 4) change(original) catch return error.Unexpected;
            const result = try delegate(userdata, file);
            // Return the pre-inspection baseline, then inspect actual good B.
            if (stats == 2) change(replacement) catch return error.Unexpected;
            return result;
        }
        fn archive(machine: u16) [188]u8 {
            var bytes = [_]u8{0} ** 188;
            var elf = [_]u8{0} ** 64;
            @memcpy(elf[0..4], "\x7fELF");
            elf[4] = 2;
            elf[5] = 1;
            elf[6] = 1;
            elf[16] = 3;
            std.mem.writeInt(u16, elf[18..20], machine, .little);
            elf[20] = 1;
            elf[52] = 64;
            const crc = std.hash.Crc32.hash(&elf);
            std.mem.writeInt(u32, bytes[0..4], 0x04034b50, .little);
            std.mem.writeInt(u16, bytes[4..6], 20, .little);
            std.mem.writeInt(u32, bytes[14..18], crc, .little);
            std.mem.writeInt(u32, bytes[18..22], 64, .little);
            std.mem.writeInt(u32, bytes[22..26], 64, .little);
            std.mem.writeInt(u16, bytes[26..28], 13, .little);
            @memcpy(bytes[30..43], "libfixture.so");
            @memcpy(bytes[43..107], &elf);
            std.mem.writeInt(u32, bytes[107..111], 0x02014b50, .little);
            std.mem.writeInt(u16, bytes[111..113], 20, .little);
            std.mem.writeInt(u16, bytes[113..115], 20, .little);
            std.mem.writeInt(u32, bytes[123..127], crc, .little);
            std.mem.writeInt(u32, bytes[127..131], 64, .little);
            std.mem.writeInt(u32, bytes[131..135], 64, .little);
            std.mem.writeInt(u16, bytes[135..137], 13, .little);
            @memcpy(bytes[153..166], "libfixture.so");
            std.mem.writeInt(u32, bytes[166..170], 0x06054b50, .little);
            std.mem.writeInt(u16, bytes[174..176], 1, .little);
            std.mem.writeInt(u16, bytes[176..178], 1, .little);
            std.mem.writeInt(u32, bytes[178..182], 59, .little);
            std.mem.writeInt(u32, bytes[182..186], 107, .little);
            return bytes;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const wrong = Hook.archive(183);
    const good = Hook.archive(62);
    const source = try tmp.dir.createFile(io, "native.jar", .{ .read = true });
    defer source.close(io);
    try source.writePositionalAll(io, &wrong, 0);
    Hook.source = source;
    Hook.original = &wrong;
    Hook.replacement = &good;
    Hook.baseline = try source.stat(io);
    Hook.delegate = io.vtable.fileStat;
    Hook.stats = 0;
    Hook.mutations = 0;
    var table = io.vtable.*;
    table.fileStat = Hook.stat;
    const injected: std.Io = .{ .userdata = io.userdata, .vtable = &table };
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(&wrong, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const expected: GameFileExpected = .{ .hashes = .{ .sha1 = &hex }, .size = wrong.len };
    try std.testing.expectError(error.NativeArchitectureMismatch, native_verify.inspectFile(a, io, source, "x86_64", null));
    // The old hash/inspect/hash sequence accepts A, inspecting only good B.
    _ = try source.stat(injected);
    const first = try fs.stream(source, null, injected, providers.max_file_bytes, null, null);
    try first.verify(expected.hashes, expected.size);
    _ = try source.stat(injected);
    try native_verify.inspectFile(a, injected, source, "x86_64", null);
    const restored = try source.stat(injected);
    const last = try fs.stream(source, null, injected, providers.max_file_bytes, null, null);
    try last.verify(expected.hashes, expected.size);
    try std.testing.expectEqual(Hook.baseline.mtime.nanoseconds, restored.mtime.nanoseconds);
    try std.testing.expect(restored.ctime.nanoseconds != Hook.baseline.ctime.nanoseconds);
    try std.testing.expectEqual(@as(usize, 2), Hook.mutations);
    Hook.baseline = try source.stat(io);
    Hook.stats = 0;
    Hook.mutations = 0;
    var cursor = source.readerStreaming(io, &.{});
    var prefix: [4]u8 = undefined;
    try cursor.interface.readSliceAll(&prefix);
    try std.testing.expectError(error.NativeSourceChanged, verifyNativeSource(a, injected, source, expected, "x86_64", null));
    try std.testing.expectEqual(@as(usize, 2), Hook.mutations);
    try cursor.interface.readSliceAll(&prefix);
    try std.testing.expectEqualSlices(u8, wrong[4..8], &prefix);
    const final = try fs.stream(source, null, io, providers.max_file_bytes, null, null);
    try final.verify(expected.hashes, expected.size);
}

fn verifyNativeArchive(job: *Job, minecraft: std.Io.Dir, path: []const u8, files: []const game_plan.File, bindings: []const ArtifactBinding) !void {
    var expected: ?GameFileExpected = null;
    for (files) |file| if (std.mem.eql(u8, file.path, path)) {
        expected = try gameFileExpected(job, file, bindings);
        break;
    };
    const verified = expected orelse return error.UnverifiableGamePrerequisite;
    const relative = try gameRelative(job, path);
    const leaf = try fs.parent(minecraft, job.io, relative, false);
    defer leaf.deinit(job.io);
    const source = try fs.openRegular(leaf.dir, job.io, leaf.name);
    defer source.close(job.io);
    try verifyNativeSource(job.result.arena.allocator(), job.io, source, verified, @tagName(builtin.cpu.arch), job.cancelToken());
}
fn verifyNativeSource(a: A, io: std.Io, source: std.Io.File, expected: GameFileExpected, cpu: []const u8, cancel: ?*const std.atomic.Value(bool)) !void {
    const baseline = try source.stat(io);
    try checkNativeSourceStat(baseline, baseline);
    const before = try fs.stream(source, null, io, providers.max_file_bytes, cancel, null);
    try before.verify(expected.hashes, expected.size);
    try checkNativeSourceStat(baseline, try source.stat(io));
    try native_verify.inspectFile(a, io, source, cpu, cancel);
    try checkNativeSourceStat(baseline, try source.stat(io));
    const after = try fs.stream(source, null, io, providers.max_file_bytes, cancel, null);
    try after.verify(expected.hashes, expected.size);
    try checkNativeSourceStat(baseline, try source.stat(io));
}
fn checkNativeSourceStat(before: std.Io.File.Stat, after: std.Io.File.Stat) !void {
    if (before.kind != .file or before.nlink != 1 or
        after.kind != before.kind or after.nlink != before.nlink or
        after.inode != before.inode or after.size != before.size or
        after.mtime.nanoseconds != before.mtime.nanoseconds or
        after.ctime.nanoseconds != before.ctime.nanoseconds) return error.NativeSourceChanged;
}
fn gameRelative(job: *Job, absolute_path: []const u8) ![]const u8 {
    const relative = try std.fs.path.relative(job.result.arena.allocator(), job.paths.minecraft, null, job.paths.minecraft, absolute_path);
    if (builtin.os.tag == .windows) for (relative) |*byte| {
        if (byte.* == 92) byte.* = '/';
    };
    if (!manifest.safeRelativePath(relative)) return error.UnsafeGamePrerequisite;
    return relative;
}
fn gameFileExpected(job: *Job, file: game_plan.File, bindings: []const ArtifactBinding) !GameFileExpected {
    if (file.sha1) |hash| {
        const hex = std.fmt.bytesToHex(&hash, .lower);
        return .{ .hashes = .{ .sha1 = try job.result.arena.allocator().dupe(u8, &hex) }, .size = file.size orelse return error.UnverifiableGamePrerequisite };
    }
    const relative = try gameRelative(job, file.path);
    if (!std.mem.startsWith(u8, relative, "libraries/")) return error.UnverifiableGamePrerequisite;
    for (bindings) |binding| if (std.mem.eql(u8, relative, binding.path)) {
        if (file.size) |size| if (size != binding.size) return error.ArtifactBindingSizeMismatch;
        return .{ .hashes = .{ .sha256 = binding.sha256 }, .size = binding.size };
    };
    return error.UnverifiableGamePrerequisite;
}
fn lowerSha256(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}
fn bindingAncestor(parent: []const u8, child: []const u8) bool {
    return parent.len < child.len and child[parent.len] == '/' and std.ascii.eqlIgnoreCase(parent, child[0..parent.len]);
}
fn gameReceiptBindings(job: *Job, game: Io.Dir, metadata_bytes: []const u8) ![]const ArtifactBinding {
    const a = job.result.arena.allocator();
    const name = if (job.instance.loader == .vanilla) ".vela-instance.json" else ".vela-loader.json";
    const bytes = try fs.read(a, game, job.io, name, instance_tx.max_install_receipt_bytes);
    var parsed = try instance_tx.parseInstallReceipt(a, bytes);
    defer parsed.deinit();
    const value = parsed.value;
    if (value != .object or try providers.Json.number(value, "schema_version") != 1 or
        !std.mem.eql(u8, try providers.Json.text(value, "instance_id"), job.instance.id) or
        !std.mem.eql(u8, try providers.Json.text(value, "instance_name"), job.instance.name) or
        !std.mem.eql(u8, try providers.Json.text(value, "minecraft_version"), job.instance.minecraft_version) or
        !std.mem.eql(u8, try providers.Json.text(value, "loader"), @tagName(job.instance.loader))) return error.InstalledGameIdentityMismatch;
    const version = try providers.Json.field(value, "loader_version");
    if (job.instance.loader == .vanilla) {
        if (version != .null or job.instance.loader_version != null) return error.InstalledGameIdentityMismatch;
    } else {
        if (version != .string or !std.mem.eql(u8, version.string, job.instance.loader_version orelse return error.InstalledGameIdentityMismatch)) return error.InstalledGameIdentityMismatch;
    }
    var metadata_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(metadata_bytes, &metadata_hash, .{});
    const metadata_hex = std.fmt.bytesToHex(&metadata_hash, .lower);
    if (!std.mem.eql(u8, try providers.Json.text(value, "metadata_sha256"), &metadata_hex)) return error.MetadataReceiptMismatch;
    const client_hash = try providers.Json.text(value, "client_sha256");
    if (!lowerSha256(client_hash)) return error.InvalidLoaderArtifactBindings;
    const jar = try std.fmt.allocPrint(a, "{s}.jar", .{job.instance.name});
    const client = (try fs.fingerprint(game, job.io, jar, job.cancelToken(), null)) orelse return error.MissingGamePrerequisite;
    try client.verify(.{ .sha256 = client_hash }, try providers.Json.number(value, "client_size"));
    if (job.instance.loader == .vanilla) return &.{};
    const raw = value.object.get("artifact_bindings") orelse return &.{};
    const items = try providers.Json.array(raw);
    if (items.len > 4096) return error.InvalidLoaderArtifactBindings;
    const result = try a.alloc(ArtifactBinding, items.len);
    for (items, 0..) |item, index| {
        const path = try providers.Json.text(item, "path");
        const hash = try providers.Json.text(item, "sha256");
        if (path.len > 4096 or !manifest.safeRelativePath(path) or !std.mem.startsWith(u8, path, "libraries/") or !lowerSha256(hash)) return error.InvalidLoaderArtifactBindings;
        for (result[0..index]) |previous| if (std.ascii.eqlIgnoreCase(path, previous.path) or bindingAncestor(path, previous.path) or bindingAncestor(previous.path, path)) return error.InvalidLoaderArtifactBindings;
        result[index] = .{ .path = try a.dupe(u8, path), .sha256 = try a.dupe(u8, hash), .size = try providers.Json.number(item, "size") };
    }
    return result;
}
fn plannedFileReady(job: *Job, minecraft: Io.Dir, absolute_path: []const u8, hash: game_metadata.Sha1, size: ?u64) !bool {
    const relative = try std.fs.path.relative(job.result.arena.allocator(), job.paths.minecraft, null, job.paths.minecraft, absolute_path);
    if (builtin.os.tag == .windows) for (relative) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    };
    if (!manifest.safeRelativePath(relative)) return error.UnsafeGamePrerequisite;
    const actual = (try fs.fingerprint(minecraft, job.io, relative, job.cancelToken(), null)) orelse return false;
    const hex = std.fmt.bytesToHex(&hash, .lower);
    try actual.verify(.{ .sha1 = &hex }, size);
    return true;
}
fn included(file: manifest.InstallFile) bool {
    return file.selected != false and (file.required or file.selected == true);
}
fn memberPath(previous: manifest.Manifest, path: []const u8) bool {
    const membership = previous.pack_membership orelse return false;
    for (membership.paths) |owned| if (std.mem.eql(u8, owned, path)) return true;
    return false;
}
fn approvedPath(paths: []const []const u8, path: []const u8) bool {
    for (paths) |owned| if (std.mem.eql(u8, owned, path)) return true;
    return false;
}
fn choiceScope(previous: manifest.Manifest, old: manifest.ManagedFile, new: manifest.ManagedFile, pack: ?manifest.PackPlan, legacy_paths: []const []const u8) bool {
    if (pack) |next| {
        if (new.standalone) return false;
        if (approvedPath(legacy_paths, old.path) and std.mem.eql(u8, old.path, new.path)) return true;
        const prior = previous.pack_membership orelse return false;
        return !old.standalone and memberPath(previous, old.path) and prior.identity.provider == next.identity.provider and
            std.mem.eql(u8, prior.identity.project_id, next.identity.project_id);
    }
    return old.standalone and new.standalone;
}
fn officialProject(old: manifest.ManagedFile, new: manifest.ManagedFile) bool {
    return old.identity_provenance == .official_file and new.identity_provenance == .official_file and
        old.provider == new.provider and std.mem.eql(u8, old.project_id, new.project_id);
}
fn exactChoice(old: manifest.ManagedFile, new: manifest.ManagedFile, legacy_paths: []const []const u8) bool {
    if (!std.mem.eql(u8, old.path, new.path) or old.role != new.role) return false;
    if (approvedPath(legacy_paths, old.path)) return true;
    if (old.provider != new.provider or old.identity_provenance != new.identity_provenance) return false;
    return if (old.identity_provenance == .official_file) officialProject(old, new) else true;
}
const NormalizedChoices = struct { files: []const manifest.InstallFile, pack: ?manifest.PackPlan, blocker: ?anyerror = null };
fn normalizeChoices(a: A, previous: manifest.Manifest, input: []const manifest.InstallFile, pack_input: ?manifest.PackPlan, legacy_paths: []const []const u8) !NormalizedChoices {
    const files = try a.dupe(manifest.InstallFile, input);
    const matched = try a.alloc(bool, previous.files.len);
    @memset(matched, false);
    var blocker: ?anyerror = null;
    for (files) |*file| {
        if (!manifest.toggleable(file.record)) continue;
        var exact: ?usize = null;
        var candidate: ?usize = null;
        var old_count: usize = 0;
        for (previous.files, 0..) |old, index| {
            if (!choiceScope(previous, old, file.record, pack_input, legacy_paths)) continue;
            if (exactChoice(old, file.record, legacy_paths)) exact = index;
            if (officialProject(old, file.record)) {
                candidate = index;
                old_count += 1;
            }
        }
        if (exact == null and candidate != null) {
            var new_count: usize = 0;
            for (files) |other| if (included(other) and officialProject(file.record, other.record)) {
                new_count += 1;
            };
            if (old_count == 1 and new_count == 1) exact = candidate else {
                for (previous.files) |old| if (!old.enabled and choiceScope(previous, old, file.record, pack_input, legacy_paths) and officialProject(old, file.record)) {
                    blocker = error.DisabledIdentityUnresolved;
                };
            }
        }
        if (exact) |index| {
            matched[index] = true;
            if (!previous.files[index].enabled) file.record.enabled = false;
        }
    }
    if (pack_input) |pack| {
        const same_pack = if (previous.pack_membership) |prior| prior.identity.provider == pack.identity.provider and std.mem.eql(u8, prior.identity.project_id, pack.identity.project_id) else false;
        for (previous.files, 0..) |old, index| {
            if (old.enabled or !manifest.toggleable(old) or matched[index]) continue;
            if ((same_pack and !old.standalone and memberPath(previous, old.path)) or approvedPath(legacy_paths, old.path)) blocker = error.DisabledIdentityUnresolved;
        }
    }
    var normalized_pack = pack_input;
    if (normalized_pack) |*pack| {
        const pack_files = try a.dupe(manifest.InstallFile, pack.files);
        for (pack_files) |*file| for (files) |normalized| if (std.mem.eql(u8, file.record.path, normalized.record.path)) {
            file.record.enabled = normalized.record.enabled;
            break;
        };
        pack.files = pack_files;
    }
    return .{ .files = files, .pack = normalized_pack, .blocker = blocker };
}
/// Installed payload is not proof that a required mod is active.
fn disabledRequiredDependency(versions: []const providers.Version, desired: manifest.Manifest) bool {
    for (versions) |version| {
        var active = false;
        for (desired.files) |file| if (file.enabled and file.role == .content and file.provider == version.provider and std.mem.eql(u8, file.project_id, version.project_id) and std.mem.eql(u8, file.version_id, version.id)) {
            active = true;
            break;
        };
        if (!active) continue;
        for (version.dependencies) |dependency| {
            if (dependency.kind != .required) continue;
            var enabled = false;
            var disabled = false;
            for (desired.files) |file| {
                if (file.role != .content or file.provider != version.provider) continue;
                const matches = if (dependency.version_id) |id| std.mem.eql(u8, file.version_id, id) else if (dependency.project_id) |id| std.mem.eql(u8, file.project_id, id) else false;
                if (matches) {
                    if (file.enabled) enabled = true else disabled = true;
                }
            }
            if (disabled and !enabled) return true;
        }
    }
    return false;
}
fn makeProposal(job: *Job, input_files: []const manifest.InstallFile, input_pack: ?manifest.PackPlan, previous: manifest.Manifest, decisions: []const manifest.ConflictDecision, manual: []const install.ManualFile, dependencies_ready: bool, stage_path: ?[]const u8, kind: Kind, root: ?providers.VersionKey, choices: []const providers.DependencyChoice) !void {
    const a = job.result.arena.allocator();
    var legacy: ?providers.Owned([]const []const u8) = null;
    defer if (legacy) |*owned| owned.deinit();
    if (job.legacy_identity) |identity| legacy = try manifest.legacyReplacementPaths(a, previous, identity, job.legacy_approvals);
    const normalized = try normalizeChoices(a, previous, input_files, input_pack, if (legacy) |owned| owned.value else &.{});
    const files = normalized.files;
    const pack = normalized.pack;
    const desired = try desiredFor(a, previous, files, pack, if (legacy) |owned| owned.value else &.{});
    const choice_blocker: ?anyerror = normalized.blocker orelse @as(?anyerror, if (disabledRequiredDependency(job.result.candidates, desired)) error.DisabledRequiredDependency else null);
    const active_dependencies_ready = dependencies_ready and choice_blocker == null;
    const observed = try observe(job, a, previous, desired);
    var plan = try manifest.buildUpdatePlan(a, previous, desired, observed, decisions, .{ .instance_id = job.instance.id, .running = false });
    defer plan.deinit();
    if (choice_blocker != null) {
        plan.value.ready = false;
        plan.value.fully_applied = false;
    }
    var missing: usize = 0;
    var undecided: usize = 0;
    for (files) |file| {
        if (file.selected == false) continue;
        if (!file.required and file.selected == null) {
            undecided += 1;
            continue;
        }
        if (file.download == .manual_required and !(try verifyManual(job, file, manual))) missing += 1;
    }
    for (manual, 0..) |mapping, index| {
        var found = false;
        for (files) |file| if (std.mem.eql(u8, file.record.path, mapping.path) and file.download == .manual_required) {
            found = true;
            break;
        };
        if (!found) return error.UnknownManualFile;
        for (manual[0..index]) |other| if (std.mem.eql(u8, other.path, mapping.path)) return error.DuplicateManualFile;
    }
    var readiness_error: ?anyerror = null;
    const loader_ready = if (pack != null) gameReady(job) catch |err| blk: {
        if (err == error.OutOfMemory or err == error.Cancelled or err == error.Canceled) return err;
        readiness_error = err;
        break :blk false;
    } else true;
    const prerequisites: manifest.CompletionPrerequisites = .{ .overrides_processed = true, .dependencies_resolved = active_dependencies_ready, .loader_ready = loader_ready };
    const complete_pack = if (pack) |value| value.unresolved.len == 0 else true;
    job.result.proposal = .{
        .files = try clone([]const manifest.InstallFile, a, files),
        .manual_files = try clone([]const install.ManualFile, a, manual),
        .pack = try clone(?manifest.PackPlan, a, pack),
        .plan = try clone(manifest.UpdatePlan, a, plan.value),
        .desired = try clone(manifest.Manifest, a, desired),
        .prerequisites = prerequisites,
        .stage_path = try clone(?[]const u8, a, stage_path),
        .ready = job.options.allow_manifest_v2 and plan.value.ready and missing == 0 and undecided == 0 and active_dependencies_ready and complete_pack and loader_ready,
        .dependencies_ready = active_dependencies_ready,
        .missing_manual = missing,
        .blocker = if (!job.options.allow_manifest_v2) error.ReceiptUpgradeRequired else choice_blocker orelse if (loader_ready) null else readiness_error orelse error.MissingGamePrerequisite,
        .root = try clone(?providers.VersionKey, a, root),
        .kind = kind,
        .choices = try clone([]const providers.DependencyChoice, a, choices),
        .legacy_identity = try clone(?manifest.PackIdentity, a, job.legacy_identity),
        .legacy_approvals = try clone([]const manifest.LegacyApproval, a, job.legacy_approvals),
    };
}
fn beforeMetadata(context: ?*anyopaque) anyerror!void {
    const job: *Job = @ptrCast(@alignCast(context.?));
    try job.check();
    if (job.metadata_requests >= 64) return error.DependencyLimit;
    job.metadata_requests += 1;
}
fn remotePolicy(job: *const Job) providers.RemotePolicy {
    return .{ .enabled = job.options.allow_curseforge_remote and job.options.curseforge.enabled and job.options.curseforge.terms_approved and job.options.transport_options.allow_curseforge, .approved_download_hosts = job.options.transport_options.approved_download_hosts };
}
// Construct at a stable address; keyed metadata never shares the CDN adapter.
const CfMetadata = struct {
    job: *Job = undefined,
    native: ?credentials.Native = null,
    secret: ?credentials.Secret = null,
    adapter: ?transport.Adapter = null,
    fn open(self: *CfMetadata, job: *Job) !void {
        self.job = job;
        errdefer self.deinit();
        const policy = job.options.curseforge;
        const reference = policy.credential_ref orelse return error.ProviderDisabled;
        if (!policy.enabled or !policy.terms_approved or !job.options.transport_options.allow_curseforge) return error.ProviderDisabled;
        if (!credentials.validateReference(&reference)) return error.InvalidReference;
        try job.check();
        const store = job.options.fixture_credential_store orelse blk: {
            self.native = try credentials.Native.init();
            try job.check();
            break :blk self.native.?.store();
        };
        try job.check();
        self.secret = try store.get(std.heap.page_allocator, &reference);
        try job.check();
        self.adapter = try transport.Adapter.initWithOptions(std.heap.page_allocator, job.io, job.cancelToken(), job.connections, job.options.transport_options);
    }
    fn deinit(self: *CfMetadata) void {
        if (self.secret) |*secret| secret.deinit();
        self.secret = null;
        if (self.adapter) |*adapter| adapter.deinit();
        self.adapter = null;
        if (self.native) |*native| native.deinit();
        self.native = null;
    }
    fn client(self: *CfMetadata) providers.CurseForgeClient {
        return .{ .allocator = std.heap.page_allocator, .transport = self.adapter.?.providerTransport(), .user_agent = transport.user_agent, .options = .{ .enabled = true, .terms_approved = true, .api_key = self.secret.?.bytes }, .request_observer = .{ .context = self.job, .before_request = beforeMetadata } };
    }
};
fn fetchCfVersions(job: *Job, project_id: []const u8, file_id: ?[]const u8, kind: Kind) ![]const providers.Version {
    var scoped: CfMetadata = .{};
    try scoped.open(job);
    defer scoped.deinit();
    const client = scoped.client();
    const filter: providers.Compatibility = .{ .minecraft_version = job.instance.minecraft_version, .loader = if (kind == .mod or kind == .modpack) job.instance.loader else .vanilla };
    const policy = remotePolicy(job);
    const exact_filter: ?providers.Compatibility = if (kind == .modpack) null else filter;
    var result = if (policy.enabled) (if (file_id) |id| try client.authorizedVersion(project_id, id, exact_filter, policy) else if (kind == .modpack) try client.authorizedModpackCandidates(project_id, job.instance.minecraft_version, policy) else try client.authorizedVersions(project_id, filter, policy)) else manual: {
        var project = try client.project(project_id);
        defer project.deinit();
        break :manual if (file_id) |id| try client.manualVersion(project.value.projects[0], id, exact_filter) else if (kind == .modpack) try client.manualModpackCandidates(project.value.projects[0], job.instance.minecraft_version) else try client.manualVersions(project.value.projects[0], filter);
    };
    defer result.deinit();
    try job.check();
    if (result.value.versions.len > 128) return error.DependencyLimit;
    var out: std.ArrayList(providers.Version) = .empty;
    const a = job.result.arena.allocator();
    for (result.value.versions) |version| {
        if (version.provider != .curseforge or !std.mem.eql(u8, version.project_id, project_id)) return error.ProjectMismatch;
        if (file_id) |id| if (!std.mem.eql(u8, version.id, id)) return error.VersionMismatch;
        if (compatibleKind(version, job.instance, kind)) {
            try out.append(a, try clone(providers.Version, a, version));
        } else if (file_id != null) return error.IncompatibleVersion;
    }
    return try out.toOwnedSlice(a);
}
fn fetchProviderVersions(job: *Job, adapter: *transport.Adapter, provider: providers.Provider, project_id: []const u8, file_id: ?[]const u8, kind: Kind) ![]const providers.Version {
    if (provider == .curseforge) return fetchCfVersions(job, project_id, file_id, kind);
    if (provider != .modrinth) return error.ProviderDisabled;
    const result = try fetchVersions(job, adapter, job.instance, file_id orelse project_id, file_id != null, kind);
    for (result) |version| if (!std.mem.eql(u8, version.project_id, project_id)) return error.ProjectMismatch;
    return result;
}
fn fetchJson(job: *Job, adapter: *transport.Adapter, path: []const u8) ![]u8 {
    const a = job.result.arena.allocator();
    try beforeMetadata(job);
    const url = try std.mem.concat(a, u8, &.{ "https://api.modrinth.com/v2", path });
    defer a.free(url);
    const callback = adapter.providerTransport();
    const response = try callback.get(callback.context, a, .{ .url = url, .user_agent = transport.user_agent });
    errdefer a.free(response.body);
    if (response.body.len > providers.max_json_bytes) return error.ResponseTooLarge;
    if (response.status == 429) return error.RateLimited;
    if (response.status != 200) return error.HttpFailure;
    return response.body;
}
fn confirmedCurseForgeModpack(version: providers.Version) bool {
    if (version.provider != .curseforge or version.files.len == 0) return false;
    for (version.files) |file| {
        const page = switch (file.download) {
            .remote => if (file.authorization) |authorization| authorization.official_page else return false,
            .manual_required => |manual| page: {
                const marker = std.mem.lastIndexOf(u8, manual.official_page, "/files/") orelse return false;
                if (!std.mem.eql(u8, manual.official_page[marker + "/files/".len ..], version.id)) return false;
                break :page manual.official_page[0..marker];
            },
        };
        if (!providers.officialCurseForgePage(page) or !std.mem.startsWith(u8, page, "https://www.curseforge.com/minecraft/modpacks/")) return false;
    }
    return true;
}
fn compatibleKind(version: providers.Version, instance: config.Instance, kind: Kind) bool {
    if (kind == .modpack and version.provider == .curseforge) {
        if (!confirmedCurseForgeModpack(version)) return false;
        if (version.loaders.len == 0) {
            for (version.minecraft_versions) |value| if (std.mem.eql(u8, value, instance.minecraft_version)) return true;
            return false;
        }
    }
    if (kind == .mod or kind == .modpack) return providers.compatible(version, .{ .minecraft_version = instance.minecraft_version, .loader = instance.loader });
    for (version.minecraft_versions) |value| if (std.mem.eql(u8, value, instance.minecraft_version)) return true;
    return false;
}
fn fetchVersions(job: *Job, adapter: *transport.Adapter, instance: config.Instance, id: []const u8, single: bool, kind: Kind) ![]const providers.Version {
    const a = job.result.arena.allocator();
    if (!providers.validToken(id)) return error.InvalidId;
    const path = if (single) try std.fmt.allocPrint(a, "/version/{s}", .{id}) else try std.fmt.allocPrint(a, "/project/{s}/version", .{id});
    defer a.free(path);
    const bytes = try fetchJson(job, adapter, path);
    defer a.free(bytes);
    var parsed = try providers.parseModrinthVersions(a, bytes, single, null);
    defer parsed.deinit();
    var versions: std.ArrayList(providers.Version) = .empty;
    for (parsed.value.versions) |version| {
        if ((single and !std.mem.eql(u8, version.id, id)) or (!single and !std.mem.eql(u8, version.project_id, id))) return error.ProjectMismatch;
        if (compatibleKind(version, instance, kind)) try versions.append(a, try clone(providers.Version, a, version));
    }
    return try versions.toOwnedSlice(a);
}
fn queryChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
}
fn queryEncode(a: A, text: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    try std.Uri.Component.percentEncode(&output.writer, text, queryChar);
    return try a.dupe(u8, output.written());
}
fn searchContent(job: *Job, adapter: *transport.Adapter, query: []const u8, kind: Kind, offset: u32) !void {
    const a = job.result.arena.allocator();
    if (job.request.search.provider == .curseforge) {
        var scoped: CfMetadata = .{};
        try scoped.open(job);
        defer scoped.deinit();
        var parsed = try scoped.client().search(query, @tagName(kind), .{ .minecraft_version = job.instance.minecraft_version, .loader = if (kind == .mod or kind == .modpack) job.instance.loader else .vanilla }, offset, 40);
        defer parsed.deinit();
        try job.check();
        job.result.catalog = try clone(providers.Catalog, a, parsed.value);
        return;
    }
    const type_facet = try std.fmt.allocPrint(a, "project_type:{s}", .{@tagName(kind)});
    const game_facet = try std.fmt.allocPrint(a, "versions:{s}", .{job.instance.minecraft_version});
    const loader_facet = try std.fmt.allocPrint(a, "categories:{s}", .{if (job.instance.loader == .vanilla) "minecraft" else @tagName(job.instance.loader)});
    const facets: []const []const []const u8 = if (kind == .mod or kind == .modpack) &.{ &.{type_facet}, &.{game_facet}, &.{loader_facet} } else &.{ &.{type_facet}, &.{game_facet} };
    const json = try std.json.Stringify.valueAlloc(a, facets, .{});
    const path = try std.fmt.allocPrint(a, "/search?query={s}&facets={s}&offset={d}&limit=40", .{ try queryEncode(a, query), try queryEncode(a, json), offset });
    const bytes = try fetchJson(job, adapter, path);
    var parsed = try providers.parseModrinthCatalog(a, bytes, true);
    defer parsed.deinit();
    job.result.catalog = try clone(providers.Catalog, a, parsed.value);
}
fn gatherDependencies(job: *Job, adapter: *transport.Adapter, root: providers.Version, choices: []const providers.DependencyChoice) ![]const providers.Version {
    const a = job.result.arena.allocator();
    var versions: std.ArrayList(providers.Version) = .empty;
    try versions.append(a, try clone(providers.Version, a, root));
    var work: std.ArrayList(providers.VersionKey) = .empty;
    try work.append(a, .{ .provider = root.provider, .id = root.id });
    var queried: std.StringHashMapUnmanaged(void) = .empty;
    var processed: std.StringHashMapUnmanaged(void) = .empty;
    var cursor: usize = 0;
    var requests: usize = 0;
    while (cursor < work.items.len) : (cursor += 1) {
        if (work.items.len > 128) return error.DependencyLimit;
        const key = work.items[cursor];
        const version = for (versions.items) |value| {
            if (value.provider == key.provider and std.mem.eql(u8, value.id, key.id)) break value;
        } else return error.MissingDependencyVersion;
        const active_key = try std.fmt.allocPrint(a, "{s}:{s}", .{ @tagName(key.provider), key.id });
        if (processed.contains(active_key)) continue;
        try processed.put(a, active_key, {});
        for (version.dependencies, 0..) |dep, index| {
            if (dep.kind != .required and dep.kind != .optional) continue;
            if (version.provider != .modrinth and version.provider != .curseforge) return error.ProviderDisabled;
            const query_key = if (dep.version_id) |id| try std.fmt.allocPrint(a, "{s}:v:{s}", .{ @tagName(version.provider), id }) else if (dep.project_id) |id| try std.fmt.allocPrint(a, "{s}:p:{s}", .{ @tagName(version.provider), id }) else continue;
            // Load optional candidates for review; expand only selected dependencies.
            if (!queried.contains(query_key)) {
                if (requests >= 64) return error.DependencyLimit;
                try queried.put(a, query_key, {});
                try job.check();
                const found = if (version.provider == .modrinth and dep.project_id == null) try fetchVersions(job, adapter, job.instance, dep.version_id.?, true, .mod) else try fetchProviderVersions(job, adapter, version.provider, dep.project_id orelse return error.MissingDependencyProject, dep.version_id, .mod);
                requests += 1;
                if (versions.items.len + found.len > 128) return error.DependencyLimit;
                for (found) |candidate| {
                    var duplicate = false;
                    for (versions.items) |other| if (candidate.provider == other.provider and std.mem.eql(u8, candidate.id, other.id)) {
                        duplicate = true;
                        break;
                    };
                    if (!duplicate) try versions.append(a, candidate);
                }
            }
            var include = dep.kind == .required;
            var chosen: ?[]const u8 = dep.version_id;
            for (choices) |choice| if (choice.from.provider == version.provider and std.mem.eql(u8, choice.from.id, version.id) and choice.dependency_index == index) {
                include = choice.include;
                chosen = choice.version_id orelse dep.version_id;
            };
            if (!include) continue;
            var match: ?providers.VersionKey = null;
            var count: usize = 0;
            for (versions.items) |candidate| {
                if (candidate.provider != version.provider) continue;
                if (dep.project_id) |id| if (!std.mem.eql(u8, candidate.project_id, id)) continue;
                if (chosen) |id| if (!std.mem.eql(u8, candidate.id, id)) continue;
                match = .{ .provider = candidate.provider, .id = candidate.id };
                count += 1;
            }
            if (count == 1) try work.append(a, match.?);
        }
    }
    return try versions.toOwnedSlice(a);
}
fn dependencyFiles(job: *Job, versions: []const providers.Version, root: providers.VersionKey, kind: Kind, choices: []const providers.DependencyChoice) ![]const manifest.InstallFile {
    const a = job.result.arena.allocator();
    const planning_versions = try clone([]const providers.Version, a, versions);
    if (kind == .resourcepack or kind == .shader) {
        for (@constCast(planning_versions)) |*version| if (version.provider == root.provider and std.mem.eql(u8, version.id, root.id)) {
            // Asset pack applicability is Minecraft-only; loader requirements apply to mod dependencies.
            version.loaders = &.{if (job.instance.loader == .vanilla) "minecraft" else @tagName(job.instance.loader)};
        };
    }
    var plan = try providers.planDependencies(a, planning_versions, &.{root}, .{ .minecraft_version = job.instance.minecraft_version, .loader = job.instance.loader }, choices);
    defer plan.deinit();
    var issues: std.ArrayList(providers.DependencyIssue) = .empty;
    try issues.appendSlice(a, plan.value.issues);
    for (plan.value.indices) |index| for (versions[index].dependencies, 0..) |dep, di| {
        if (dep.kind != .required) continue;
        var explicit = false;
        for (choices) |choice| if (choice.from.provider == versions[index].provider and std.mem.eql(u8, choice.from.id, versions[index].id) and choice.dependency_index == di and choice.include and choice.version_id != null) {
            explicit = true;
            break;
        };
        if (!explicit) try issues.append(a, .{ .from_index = index, .dependency_index = di, .kind = .ambiguous_version });
    };
    job.result.dependency_issues = try issues.toOwnedSlice(a);
    job.result.candidates = try clone([]const providers.Version, a, versions);
    var files: std.ArrayList(manifest.InstallFile) = .empty;
    for (plan.value.indices) |index| {
        const version = versions[index];
        const file = try primaryFile(version);
        const root_version = version.provider == root.provider and std.mem.eql(u8, version.id, root.id);
        const folder: []const u8 = if (!root_version or kind == .mod) "mods" else switch (kind) {
            .resourcepack => "resourcepacks",
            .shader => "shaderpacks",
            .modpack => return error.ArchiveRequired,
            .mod => unreachable,
        };
        if (version.provider == .curseforge and file.download == .remote) try providers.validateRemoteAuthorization(version.provider, version.project_id, version.id, file, remotePolicy(job));
        try files.append(a, .{ .record = .{ .path = try std.fmt.allocPrint(a, "{s}/{s}", .{ folder, file.filename }), .provider = version.provider, .project_id = version.project_id, .version_id = version.id, .hashes = file.hashes, .size = file.size, .identity_provenance = .official_file }, .download = file.download, .authorization = file.authorization });
    }
    return try files.toOwnedSlice(a);
}
fn prepareSelected(job: *Job, adapter: *transport.Adapter, version: providers.Version, kind: Kind, choices: []const providers.DependencyChoice) !void {
    if (!compatibleKind(version, job.instance, kind)) return error.IncompatibleVersion;
    if (kind == .modpack) return try downloadArchive(job, adapter, version);
    const previous = try readManifest(job, job.result.arena.allocator());
    const candidates = try gatherDependencies(job, adapter, version, choices);
    const root: providers.VersionKey = .{ .provider = version.provider, .id = version.id };
    const files = try dependencyFiles(job, candidates, root, kind, choices);
    try makeProposal(job, files, null, previous, &.{}, &.{}, job.result.dependency_issues.len == 0, null, kind, root, choices);
}
fn primaryFile(version: providers.Version) !providers.File {
    if (version.files.len == 0 or version.files.len > providers.max_items) return error.MissingFile;
    var chosen: ?providers.File = null;
    for (version.files) |file| {
        if (!config.validId(file.filename)) return error.UnsafePath;
        try providers.validateHashes(file.hashes);
        if (file.primary) {
            if (chosen != null) return error.MultiplePrimaryFiles;
            chosen = file;
        }
    }
    return chosen orelse version.files[0];
}
fn publishPrepared(job: *Job, prepared: *const packs.Prepared, identity: manifest.PackIdentity) !void {
    const a = job.result.arena.allocator();
    if (prepared.pack.identity.provider != identity.provider) return error.ProviderMismatch;
    var pack = try clone(manifest.PackPlan, a, prepared.pack);
    pack.identity = try clone(manifest.PackIdentity, a, identity);
    const records = try clone([]const manifest.InstallFile, a, prepared.files);
    for (@constCast(records)) |*file| {
        file.record.standalone = false;
        // Only extracted override mappings establish archive ownership for legacy importer records.
        if (file.record.identity_provenance == .legacy_unknown) {
            if (file.record.role != .override or file.download != .manual_required or file.record.hashes.sha256 == null or file.record.size == null) return error.UnverifiedPackMember;
            var extracted_override = false;
            for (prepared.manual_files) |mapping| if (std.mem.eql(u8, mapping.path, file.record.path)) {
                extracted_override = true;
                break;
            };
            if (!extracted_override) return error.UnverifiedPackMember;
            file.record.identity_provenance = .pack_override;
        }
        if (file.record.identity_provenance == .pack_archive or file.record.identity_provenance == .pack_override) {
            file.record.provider = identity.provider;
            file.record.project_id = pack.identity.project_id;
            file.record.version_id = pack.identity.version_id;
        }
    }
    pack.files = records;
    const previous = try readManifest(job, a);
    try makeProposal(job, records, pack, previous, &.{}, prepared.manual_files, pack.unresolved.len == 0, prepared.stage_absolute_path, .modpack, null, &.{});
}
fn prepareArchive(job: *Job, archive_path: []const u8, identity: manifest.PackIdentity) !void {
    var prepared = try packs.prepare(std.heap.page_allocator, job.io, &job.paths, job.instance, archive_path, job.cancelToken());
    defer prepared.deinit();
    errdefer prepared.cleanup(job.io) catch {};
    try publishPrepared(job, &prepared, identity);
}
fn prepareInspection(job: *Job, identity: manifest.PackIdentity) !void {
    const inspection = if (job.inspection) |*owned| owned else return error.MissingInspection;
    if (inspection.provider != identity.provider) return error.ProviderMismatch;
    var prepared = try packs.prepareInspected(std.heap.page_allocator, job.io, &job.paths, job.instance, inspection, job.cancelToken());
    defer prepared.deinit();
    errdefer prepared.cleanup(job.io) catch {};
    try publishPrepared(job, &prepared, identity);
}
fn downloadArchive(job: *Job, adapter: *transport.Adapter, version: providers.Version) !void {
    if (version.provider != .modrinth and version.provider != .curseforge) return error.ProviderDisabled;
    const file = try primaryFile(version);
    if (file.download != .remote) return error.ManualArchiveRequired;
    if (version.provider == .curseforge) {
        if (!job.options.allow_manifest_v2) return error.ReceiptUpgradeRequired;
        try providers.validateRemoteAuthorization(version.provider, version.project_id, version.id, file, remotePolicy(job));
    }
    const root = try fs.openAbsolute(job.io, job.paths.root);
    defer root.close(job.io);
    const vela = try fs.child(root, job.io, ".vela", true, true);
    defer vela.close(job.io);
    const staging = try fs.child(vela, job.io, "content-archives", true, true);
    defer staging.close(job.io);
    var nonce: [16]u8 = undefined;
    try Io.randomSecure(job.io, &nonce);
    const a = job.result.arena.allocator();
    const extension: []const u8 = if (version.provider == .curseforge) ".zip" else ".mrpack";
    const name = try std.fmt.allocPrint(a, "download-{s}{s}", .{ std.fmt.bytesToHex(nonce, .lower), extension });
    const absolute = try std.fs.path.join(a, &.{ job.paths.vela, "content-archives", name });
    defer staging.deleteFile(job.io, name) catch {};
    const fetcher = adapter.fetcher();
    const limit: u64 = 256 * 1024 * 1024;
    if (file.size) |size| if (size > limit) return error.ArchiveTooLarge;
    try fetcher.fetchToFile(fetcher.context, job.io, .{ .url = file.download.remote, .directory = staging, .name = name, .absolute_path = absolute, .max_bytes = limit, .expected_size = file.size, .expected_sha1 = null, .deadline_ns = null, .cancel = job.cancelToken() });
    const actual = (try fs.fingerprint(staging, job.io, name, job.cancelToken(), null)) orelse return error.MissingArchive;
    try actual.verify(file.hashes, file.size);
    try prepareArchive(job, absolute, .{ .provider = version.provider, .project_id = version.project_id, .version_id = version.id });
}
fn resolveProposal(job: *Job, adapter: *transport.Adapter, request: @FieldType(Request, "resolve")) !void {
    job.legacy_identity = request.proposal.legacy_identity;
    job.legacy_approvals = request.proposal.legacy_approvals;
    const a = job.result.arena.allocator();
    const previous = try readManifest(job, a);
    if (request.proposal.root == null and request.proposal.pack == null and request.proposal.files.len == 0) {
        if (request.manual_files.len != 0 or request.choices.len != 0 or request.optional.len != 0) return error.InvalidChoice;
        const desired = request.proposal.desired orelse request.proposal.plan.next_manifest;
        const observed = try observe(job, a, previous, desired);
        var plan = try manifest.buildUpdatePlan(a, previous, desired, observed, request.decisions, .{ .instance_id = job.instance.id, .running = false });
        defer plan.deinit();
        job.result.proposal = .{ .plan = try clone(manifest.UpdatePlan, a, plan.value), .desired = try clone(manifest.Manifest, a, desired), .ready = plan.value.ready, .dependencies_ready = true };
        return;
    }
    var proposal = request.proposal;
    var files = try clone([]const manifest.InstallFile, a, proposal.files);
    var deps_ready = proposal.dependencies_ready;
    if (proposal.root) |root| {
        const version = for (request.candidates) |candidate| {
            if (candidate.provider == root.provider and std.mem.eql(u8, candidate.id, root.id)) break candidate;
        } else return error.MissingRootVersion;
        const candidates = try gatherDependencies(job, adapter, version, request.choices);
        files = try dependencyFiles(job, candidates, root, proposal.kind, request.choices);
        deps_ready = job.result.dependency_issues.len == 0;
    } else {
        job.result.candidates = try clone([]const providers.Version, a, request.candidates);
        for (@constCast(files)) |*file| for (request.optional) |choice| if (std.mem.eql(u8, choice.path, file.record.path)) {
            if (file.required and !choice.include) return error.RequiredFile;
            file.selected = choice.include;
        };
        for (request.optional, 0..) |choice, index| {
            var found = false;
            for (files) |file| if (std.mem.eql(u8, choice.path, file.record.path)) {
                found = true;
                break;
            };
            if (!found) return error.UnknownOptionalFile;
            for (request.optional[0..index]) |other| if (std.mem.eql(u8, choice.path, other.path)) return error.DuplicateChoice;
        }
    }
    if (proposal.pack) |*pack| {
        pack.files = files;
        if (pack.identity.provider == .curseforge) deps_ready = try packDependencies(job, pack.*, request.choices);
    }
    var manual: std.ArrayList(install.ManualFile) = .empty;
    for (proposal.manual_files) |mapping| {
        var replaced = false;
        for (request.manual_files) |new| if (std.mem.eql(u8, mapping.path, new.path)) {
            replaced = true;
            break;
        };
        if (!replaced) try manual.append(a, mapping);
    }
    try manual.appendSlice(a, request.manual_files);
    try makeProposal(job, files, proposal.pack, previous, request.decisions, manual.items, deps_ready, proposal.stage_path, proposal.kind, proposal.root, request.choices);
    if (!deps_ready and proposal.pack != null and proposal.pack.?.identity.provider == .curseforge and job.result.proposal.?.blocker == null) job.result.proposal.?.blocker = error.MissingPackDependency;
}
fn packDependencies(job: *Job, pack: manifest.PackPlan, choices: []const providers.DependencyChoice) !bool {
    const a = job.result.arena.allocator();
    var roots: std.ArrayList(providers.VersionKey) = .empty;
    for (pack.files) |file| {
        if (file.record.role != .content or file.selected == false or (!file.required and file.selected != true)) continue;
        const key: providers.VersionKey = .{ .provider = file.record.provider, .id = file.record.version_id };
        var found = false;
        for (job.result.candidates) |version| if (version.provider == key.provider and std.mem.eql(u8, version.id, key.id) and std.mem.eql(u8, version.project_id, file.record.project_id)) {
            found = true;
            break;
        };
        if (!found) return false;
        try roots.append(a, key);
    }
    var plan = try providers.planDependencies(a, job.result.candidates, roots.items, .{ .minecraft_version = pack.minecraft_version, .loader = pack.loader }, choices);
    defer plan.deinit();
    job.result.dependency_issues = try clone([]const providers.DependencyIssue, a, plan.value.issues);
    var ready = plan.value.ready and pack.unresolved.len == 0;
    for (plan.value.indices) |index| {
        const version = job.result.candidates[index];
        var file_included = false;
        for (pack.files) |file| if (file.record.role == .content and file.selected != false and (file.required or file.selected == true) and file.record.provider == version.provider and std.mem.eql(u8, file.record.project_id, version.project_id) and std.mem.eql(u8, file.record.version_id, version.id)) {
            file_included = true;
            break;
        };
        if (!file_included) ready = false;
    }
    return ready;
}

fn resolvePackReferences(job: *Job, adapter: *transport.Adapter, request: ResolveRequest) !void {
    const a = job.result.arena.allocator();
    const pack = request.proposal.pack orelse return error.NoPack;
    if (pack.identity.provider != .curseforge) return error.ProviderMismatch;
    var references: std.ArrayList(manifest.PackReference) = .empty;
    try references.appendSlice(a, pack.unresolved);
    for (pack.files) |file| if (file.record.provider == .curseforge and file.record.identity_provenance == .official_file) {
        try references.append(a, .{ .project_id = file.record.project_id, .file_id = file.record.version_id, .required = file.required, .selected = file.selected });
    };
    var candidates: std.ArrayList(providers.Version) = .empty;
    try candidates.appendSlice(a, try clone([]const providers.Version, a, request.candidates));
    var queried = std.StringHashMapUnmanaged(void){};
    var metadata_error: ?anyerror = null;
    for (references.items) |ref| {
        const key = try std.fmt.allocPrint(a, "{s}:{s}", .{ ref.project_id, ref.file_id });
        if (queried.contains(key)) continue;
        try queried.put(a, key, {});
        const found = fetchCfVersions(job, ref.project_id, ref.file_id, .mod) catch |err| switch (err) {
            error.HttpFailure => {
                metadata_error = err;
                continue;
            },
            else => return err,
        };
        if (found.len != 1) return error.UnknownVersion;
        for (found[0].files) |file| if (file.size == null) return error.MissingSize;
        var replaced = false;
        for (candidates.items) |*version| if (version.provider == .curseforge and std.mem.eql(u8, version.project_id, ref.project_id) and std.mem.eql(u8, version.id, ref.file_id)) {
            version.* = found[0];
            replaced = true;
            break;
        };
        if (!replaced) {
            if (candidates.items.len >= 128) return error.DependencyLimit;
            try candidates.append(a, found[0]);
        }
    }
    const refreshed = try clone(manifest.PackPlan, a, pack);
    const refreshed_files = @constCast(refreshed.files);
    for (refreshed_files) |*file| {
        if (file.record.provider != .curseforge or file.record.identity_provenance != .official_file) continue;
        var metadata: ?providers.File = null;
        for (candidates.items) |version| if (version.provider == .curseforge and std.mem.eql(u8, version.project_id, file.record.project_id) and std.mem.eql(u8, version.id, file.record.version_id)) {
            if (version.files.len != 1) return error.AmbiguousFiles;
            metadata = version.files[0];
            break;
        };
        const fresh = metadata orelse return error.UnknownVersion;
        if (!std.mem.eql(u8, std.fs.path.basename(file.record.path), fresh.filename) or fresh.size == null) return error.VersionMismatch;
        if (fresh.download == .remote) try providers.validateRemoteAuthorization(.curseforge, file.record.project_id, file.record.version_id, fresh, remotePolicy(job));
        file.record.hashes = try clone(providers.Hashes, a, fresh.hashes);
        file.record.size = fresh.size;
        file.download = try clone(providers.Download, a, fresh.download);
        file.authorization = try clone(?providers.RemoteAuthorization, a, fresh.authorization);
    }
    var resolved = if (job.options.allow_curseforge_remote) try manifest.resolveCurseForgePackAuthorized(a, refreshed, candidates.items, remotePolicy(job)) else try manifest.resolveCurseForgePack(a, refreshed, candidates.items);
    defer resolved.deinit();
    var next = request;
    next.proposal.pack = resolved.value;
    next.proposal.files = resolved.value.files;
    next.candidates = candidates.items;
    try job.check();
    try resolveProposal(job, adapter, next);
    if (metadata_error) |err| {
        job.result.proposal.?.ready = false;
        job.result.proposal.?.dependencies_ready = false;
        if (job.result.proposal.?.blocker == null or job.result.proposal.?.blocker.? == error.MissingPackDependency) job.result.proposal.?.blocker = err;
    }
}

fn prepareState(job: *Job, path: []const u8, enabled: bool) !void {
    const a = job.result.arena.allocator();
    const previous = try readManifest(job, a);
    const observed = try observe(job, a, previous, previous);
    var plan = try manifest.buildEnabledPlan(a, previous, path, enabled, observed, .{ .instance_id = job.instance.id, .running = false });
    defer plan.deinit();
    job.result.proposal = .{ .plan = try clone(manifest.UpdatePlan, a, plan.value), .desired = try clone(manifest.Manifest, a, plan.value.next_manifest), .ready = plan.value.ready, .dependencies_ready = true };
}
fn prepareRemoval(job: *Job, adapter: *transport.Adapter, path: []const u8) !void {
    const a = job.result.arena.allocator();
    const previous = try readManifest(job, a);
    var removed: ?manifest.ManagedFile = null;
    var records: std.ArrayList(manifest.ManagedFile) = .empty;
    for (previous.files) |file| if (std.mem.eql(u8, file.path, path)) {
        removed = file;
    } else try records.append(a, file);
    const target = removed orelse return error.UnmanagedFile;
    if (target.role == .content and std.mem.startsWith(u8, target.path, "mods/")) {
        for (records.items) |file| {
            if (file.role != .content or !std.mem.startsWith(u8, file.path, "mods/")) continue;
            if (file.identity_provenance == .pack_archive or file.identity_provenance == .pack_override) return error.UnverifiedDependencies;
            const found = try fetchProviderVersions(job, adapter, file.provider, file.project_id, file.version_id, .mod);
            if (found.len != 1) return error.UnverifiedDependencies;
            for (found[0].dependencies) |dep| if (dep.kind == .required and ((dep.project_id != null and std.mem.eql(u8, dep.project_id.?, target.project_id)) or (dep.version_id != null and std.mem.eql(u8, dep.version_id.?, target.version_id)))) return error.RequiredByInstalledContent;
        }
    }
    const desired: manifest.Manifest = .{ .instance_id = previous.instance_id, .pack_version = previous.pack_version, .files = try records.toOwnedSlice(a) };
    const observed = try observe(job, a, previous, desired);
    var plan = try manifest.buildUpdatePlan(a, previous, desired, observed, &.{}, .{ .instance_id = job.instance.id, .running = false });
    defer plan.deinit();
    job.result.proposal = .{ .plan = try clone(manifest.UpdatePlan, a, plan.value), .desired = try clone(manifest.Manifest, a, desired), .ready = plan.value.ready, .dependencies_ready = true };
}
fn runBackend(job: *Job) !void {
    try job.check();
    var adapter = try transport.Adapter.initWithOptions(std.heap.page_allocator, job.io, job.cancelToken(), job.connections, job.options.transport_options);
    defer adapter.deinit();
    if (job.held and job.request != .recover) {
        if (@hasDecl(install, "requireRecoveryClear")) try install.requireRecoveryClear(std.heap.page_allocator, job.io, &job.paths, job.instance.id, job.instance.name);
    }
    switch (job.request) {
        .refresh => try localSnapshot(job),
        .search => |request| try searchContent(job, &adapter, request.query, request.kind, request.offset),
        .versions => |request| job.result.versions = .{ .versions = try fetchProviderVersions(job, &adapter, request.project.provider, request.project.id, null, request.kind) },
        .prepare => |request| {
            const version = if (request.version.provider == .curseforge) blk: {
                const found = try fetchCfVersions(job, request.version.project_id, request.version.id, request.kind);
                if (found.len != 1) return error.UnknownVersion;
                break :blk found[0];
            } else request.version;
            try prepareSelected(job, &adapter, version, request.kind, request.choices);
        },
        .update => |request| {
            job.legacy_identity = request.legacy_identity;
            job.legacy_approvals = request.legacy_approvals;
            const found = try fetchProviderVersions(job, &adapter, request.provider, request.project_id, request.version_id, request.kind);
            if (found.len != 1) return error.UnknownVersion;
            try prepareSelected(job, &adapter, found[0], request.kind, &.{});
        },
        .import_pack => |request| try prepareArchive(job, request.absolute_path, request.identity),
        .inspected_pack => |identity| try prepareInspection(job, identity),
        .resolve => |request| try resolveProposal(job, &adapter, request),
        .resolve_pack_references => |request| try resolvePackReferences(job, &adapter, request),
        .remove => |path| try prepareRemoval(job, &adapter, path),
        .enabled_state => |state| try prepareState(job, state.path, state.enabled),
        .commit => |proposal| {
            if (!proposal.ready or !proposal.dependencies_ready) return error.IncompleteContent;
            try Job.nestedAcquire(job, job.instance.id);
            if (proposal.pack != null and !(try gameReady(job))) return error.MissingGamePrerequisite;
            if (!job.options.allow_manifest_v2) return error.ReceiptUpgradeRequired;
            for (proposal.files) |file| if (file.record.provider == .curseforge and file.download == .remote and file.selected != false) {
                try providers.validateRemoteAuthorization(file.record.provider, file.record.project_id, file.record.version_id, .{ .filename = std.fs.path.basename(file.record.path), .hashes = file.record.hashes, .size = file.record.size, .download = file.download, .authorization = file.authorization }, remotePolicy(job));
            };
            job.result.report = try install.execute(std.heap.page_allocator, job.io, .{ .paths = &job.paths, .instance_id = job.instance.id, .instance_name = job.instance.name, .plan = proposal.plan, .files = proposal.files, .lease = job.nestedLease(), .pack = proposal.pack, .prerequisites = proposal.prerequisites, .manual_files = proposal.manual_files, .allow_partial = !proposal.plan.fully_applied, .cancel = job.cancelToken(), .fetcher = adapter.fetcher(), .fault = job.options.fixture_fault, .allow_curseforge_remote = job.options.allow_curseforge_remote, .allow_manifest_v2 = job.options.allow_manifest_v2, .approved_download_hosts = job.options.transport_options.approved_download_hosts });
            // After the durable commit, a late cancellation cannot revoke success.
            if (job.result.report.?.committed) {
                if (proposal.stage_path) |path| packs.cleanup(job.io, path) catch {};
            }
        },
        .recover => |id| {
            job.result.report = try install.recover(std.heap.page_allocator, job.io, .{ .paths = &job.paths, .instance_id = job.instance.id, .instance_name = job.instance.name, .transaction_id = id, .lease = job.nestedLease(), .fault = job.options.fixture_fault });
            if (@hasDecl(install, "requireRecoveryClear")) {
                try install.requireRecoveryClear(std.heap.page_allocator, job.io, &job.paths, job.instance.id, job.instance.name);
            } else return error.RecoveryGuardUnavailable;
            job.recovery_verified = true;
        },
    }
}

test "CF modpack candidate compatibility defers only tagless confirmed archives" {
    const instance: config.Instance = .{ .id = "stable", .name = "Instance", .minecraft_version = "1.20.1" };
    const file: providers.File = .{ .filename = "pack.zip", .hashes = .{}, .download = .{ .manual_required = .{ .official_page = "https://www.curseforge.com/minecraft/modpacks/example/files/34", .reason = .missing_url } } };
    var version: providers.Version = .{ .provider = .curseforge, .project_id = "12", .id = "34", .name = "Pack", .minecraft_versions = &.{"1.20.1"}, .loaders = &.{}, .files = &.{file}, .dependencies = &.{} };
    try std.testing.expect(compatibleKind(version, instance, .modpack));
    var forge = instance;
    forge.loader = .forge;
    forge.loader_version = "47.2.0";
    try std.testing.expect(compatibleKind(version, forge, .modpack));
    try std.testing.expect(!compatibleKind(version, instance, .mod));
    version.provider = .modrinth;
    try std.testing.expect(!compatibleKind(version, instance, .modpack));
    version.provider = .curseforge;
    version.loaders = &.{"forge"};
    try std.testing.expect(!compatibleKind(version, instance, .modpack));
    try std.testing.expect(compatibleKind(version, forge, .modpack));
    version.loaders = &.{};
    version.minecraft_versions = &.{"1.19.4"};
    try std.testing.expect(!compatibleKind(version, instance, .modpack));
    version.minecraft_versions = &.{"1.20.1"};
    var nonpack = file;
    nonpack.download.manual_required.official_page = "https://www.curseforge.com/minecraft/mc-mods/example/files/34";
    version.files = &.{nonpack};
    try std.testing.expect(!compatibleKind(version, instance, .modpack));
    version.files = &.{};
    try std.testing.expect(!compatibleKind(version, instance, .modpack));
}

test "standalone official update preserves matching pack-owned child and membership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const previous: manifest.Manifest = .{
        .schema_version = 2,
        .instance_id = "stable-id",
        .pack_version = "200",
        .pack_membership = .{ .identity = .{ .provider = .curseforge, .project_id = "100", .version_id = "200" }, .paths = &.{"mods/owned.jar"} },
        .files = &.{.{
            .path = "mods/owned.jar",
            .provider = .curseforge,
            .project_id = "12",
            .version_id = "34",
            .hashes = .{ .sha1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
            .size = 3,
            .identity_provenance = .official_file,
            .standalone = false,
        }},
    };
    const files = [_]manifest.InstallFile{.{
        .record = .{
            .path = "mods/new.jar",
            .provider = .curseforge,
            .project_id = "12",
            .version_id = "44",
            .hashes = .{ .sha1 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
            .size = 3,
            .identity_provenance = .official_file,
            .standalone = true,
        },
        .download = .{ .manual_required = .{ .official_page = "https://www.curseforge.com/minecraft/mc-mods/example/files/44", .reason = .distribution_disabled } },
    }};
    const desired = try desiredFor(arena.allocator(), previous, &files, null, &.{});
    try std.testing.expectEqual(@as(u32, 2), desired.schema_version);
    try std.testing.expectEqual(@as(usize, 2), desired.files.len);
    try std.testing.expectEqualStrings("mods/owned.jar", desired.files[0].path);
    try std.testing.expect(!desired.files[0].standalone);
    try std.testing.expectEqualStrings("mods/new.jar", desired.files[1].path);
    try std.testing.expect(desired.files[1].standalone);
    try std.testing.expect(desired.pack_membership != null);
    try std.testing.expectEqual(@as(usize, 1), desired.pack_membership.?.paths.len);
    try std.testing.expectEqualStrings("mods/owned.jar", desired.pack_membership.?.paths[0]);
}

const CancelJoinFixture = struct {
    const Mode = enum { canceled_refresh, late_refresh, committed, recovered, recovery_required, publication_uncertain };
    const instance: config.Instance = .{ .id = "join-test", .name = "Join fixture", .minecraft_version = "1.20.1" };
    const paths: instances.Paths = .{ .allocator = std.testing.allocator, .root = "/unused-join-fixture", .minecraft = "/unused-join-fixture/.minecraft", .vela = "/unused-join-fixture/.vela", .assets = "/unused-join-fixture/.minecraft/assets", .libraries = "/unused-join-fixture/.minecraft/libraries", .jdks = "/unused-join-fixture/.vela/jdks", .cache = "/unused-join-fixture/.vela/cache", .logs = "/unused-join-fixture/.vela/logs" };

    releases: usize = 0,

    fn acquire(_: ?*anyopaque, _: []const u8) anyerror!void {}
    fn release(context: ?*anyopaque, _: []const u8) void {
        const self: *CancelJoinFixture = @ptrCast(@alignCast(context.?));
        self.releases += 1;
    }
    fn options(self: *CancelJoinFixture) Options {
        return .{
            .lease = .{ .context = self, .acquire = acquire, .release = release, .recheck = acquire },
            // A broken shutdown dispatch must fail before reaching the real backend.
            .fixture_spawn_failure = error.UnexpectedShutdownRefresh,
        };
    }
    fn run(job: *Job, mode: Mode) void {
        defer job.done.store(true, .release);
        var polls: usize = 0;
        while (!job.task.?.canceled()) : (polls += 1) {
            if (polls == 1000) {
                job.failure = error.FixtureCancellationTimedOut;
                return;
            }
            job.io.sleep(.fromMilliseconds(1), .awake) catch |err| {
                job.failure = err;
                return;
            };
        }
        switch (mode) {
            .canceled_refresh => job.failure = error.Canceled,
            .late_refresh => job.result.installed = .{ .instance_id = job.instance.id, .pack_version = "join-fixture-version", .files = &.{} },
            .committed, .recovered => {
                job.failure = error.Canceled;
                job.result.report = .{
                    .allocator = job.result.arena.allocator(),
                    .backup_directory = job.result.arena.allocator().dupe(u8, "retained-backup") catch |err| {
                        job.failure = err;
                        return;
                    },
                    .transaction_id = "joined-transaction",
                    .committed = mode == .committed,
                    .recovered = mode == .recovered,
                    .applied_files = 2,
                    .complete = true,
                };
                if (mode == .recovered) job.recovery_verified = true;
            },
            .recovery_required => {
                job.failure = error.RecoveryRequired;
                job.result.transactions = &.{"retained-transaction"};
            },
            .publication_uncertain => job.failure = error.PublicationUncertain,
        }
    }
    fn start(service: *Manager, mode: Mode) !*tasks.Task {
        const document: manifest.Manifest = .{ .instance_id = instance.id, .pack_version = "join-fixture-version", .files = &.{} };
        const request: Request = switch (mode) {
            .recovered => .{ .recover = "joined-transaction" },
            .committed, .publication_uncertain => .{ .commit = .{ .plan = .{
                .actions = &.{},
                .conflicts = &.{},
                .next_manifest = document,
                .ready = true,
                .fully_applied = true,
            } } },
            else => .refresh,
        };
        const job = try Job.create(service.allocator, service.io, service.paths, instance, request, service.options, service.connections);
        errdefer job.destroy();
        try service.options.lease.acquire(service.options.lease.context, instance.id);
        job.held = true;
        errdefer service.release(job);
        const task = try service.registry.create(.mod_install, "Cancel and join fixture");
        job.task = task;
        errdefer service.registry.finish(task, .{ .failed = error.FixtureSetupFailed });
        try service.registry.start(task);
        job.future = try service.io.concurrent(run, .{ job, mode });
        service.active = job;
        return task;
    }
};

test "content shutdown drain is idempotent and clears pending refresh without a worker" {
    var fixture: CancelJoinFixture = .{};
    var registry = tasks.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var service = try Manager.initOptions(std.testing.allocator, std.testing.io, &CancelJoinFixture.paths, &registry, fixture.options());
    defer service.deinit();
    service.selected = try Selection.create(std.testing.allocator, CancelJoinFixture.instance);
    service.failure = error.ExistingContentFailure;
    for (0..2) |_| {
        service.pending_refresh = true;
        service.cancelAndJoin();
        try std.testing.expect(!service.isBusy());
        try std.testing.expect(!service.joining);
        try std.testing.expectEqual(@as(?anyerror, error.ExistingContentFailure), service.snapshot().failure);
        try std.testing.expectEqual(@as(usize, 0), registry.tasks().len);
        try std.testing.expectEqual(@as(usize, 0), fixture.releases);
    }
}

test "content shutdown drain joins bounded fakes and preserves late publication and recovery" {
    for (std.enums.values(CancelJoinFixture.Mode)) |mode| {
        var fixture: CancelJoinFixture = .{};
        var registry = tasks.Registry.init(std.testing.allocator);
        defer registry.deinit();
        var service = try Manager.initOptions(std.testing.allocator, std.testing.io, &CancelJoinFixture.paths, &registry, fixture.options());
        defer service.deinit();
        service.selected = try Selection.create(std.testing.allocator, CancelJoinFixture.instance);
        const task = try CancelJoinFixture.start(&service, mode);
        service.pending_refresh = true;
        service.cancelAndJoin();
        try std.testing.expect(task.canceled());
        try std.testing.expect(service.active == null);
        try std.testing.expect(!service.isBusy());
        try std.testing.expect(!service.joining);
        try std.testing.expectEqual(@as(usize, 1), registry.tasks().len);
        const expected_failure: ?anyerror = switch (mode) {
            .canceled_refresh => error.Canceled,
            .recovery_required => error.RecoveryRequired,
            .publication_uncertain => error.PublicationUncertain,
            else => null,
        };
        try std.testing.expectEqual(expected_failure, service.snapshot().failure);
        const expected_state: tasks.State = switch (mode) {
            .canceled_refresh => .canceled,
            .recovery_required, .publication_uncertain => .failed,
            else => .succeeded,
        };
        try std.testing.expectEqual(expected_state, task.state);
        if (mode == .late_refresh) {
            const joined = service.local_job orelse return error.MissingJoinedRefresh;
            const managed = joined.result.installed orelse return error.MissingJoinedRefresh;
            try std.testing.expectEqualStrings(CancelJoinFixture.instance.id, managed.instance_id);
            try std.testing.expectEqualStrings("join-fixture-version", managed.pack_version);
        }
        if (mode == .committed or mode == .recovered) {
            const report = service.snapshot().report orelse return error.MissingJoinedReport;
            try std.testing.expectEqual(mode == .committed, report.committed);
            try std.testing.expectEqual(mode == .recovered, report.recovered);
            if (mode == .recovered) {
                const joined = service.report_job orelse return error.MissingJoinedRecovery;
                try std.testing.expect(joined.request == .recover);
                try std.testing.expect(joined.recovery_verified);
            }
            try std.testing.expectEqual(@as(usize, 2), report.applied_files);
            try std.testing.expectEqualStrings("joined-transaction", report.transaction_id);
            try std.testing.expect(service.failure == null);
        }
        if (mode == .recovery_required) {
            try std.testing.expect(service.pinned != null);
            try std.testing.expect(service.pinned.?.held);
            try std.testing.expectEqual(@as(usize, 0), fixture.releases);
            try std.testing.expectEqualStrings("retained-transaction", service.snapshot().transactions[0]);
        } else try std.testing.expectEqual(@as(usize, 1), fixture.releases);
        const local = service.local_job;
        const report = service.report_job;
        const pinned = service.pinned;
        const releases = fixture.releases;
        service.pending_refresh = true;
        service.cancelAndJoin();
        try std.testing.expect(!service.pending_refresh);
        try std.testing.expectEqual(local, service.local_job);
        try std.testing.expectEqual(report, service.report_job);
        try std.testing.expectEqual(pinned, service.pinned);
        try std.testing.expectEqual(releases, fixture.releases);
        try std.testing.expectEqual(expected_state, task.state);
        try std.testing.expectEqual(expected_failure, service.snapshot().failure);
        try std.testing.expectEqual(@as(usize, 1), registry.tasks().len);
    }
}

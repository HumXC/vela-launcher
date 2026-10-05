//! Hermetic acceptance data. Game bytes are inert; no Minecraft/JVM execution.
//! Context stays at its final heap address until every worker has JOINed.
const std = @import("std");
const packs = @import("core/pack_import.zig");
const paths = @import("core/instances.zig");
const metadata = @import("core/minecraft/metadata/root.zig");
const metadata_loader = @import("core/minecraft/metadata_loader.zig");
const content_install = @import("core/content_install.zig");
const http = @import("core/http_transport.zig");
const controller = @import("ui/pack_import_controller.zig");
const pack_view = @import("ui/pack_import_view.zig");
const builtin = @import("builtin");
const java = @import("ui/java_manager.zig");
const instances_manager = @import("ui/instances_manager.zig");
const loader_install = @import("core/minecraft/loader_install.zig");
const loaders = @import("core/minecraft/loaders.zig");
const install_plan = @import("core/minecraft/install_plan.zig");
const serde = @import("core/minecraft/loaders_json.zig");
const content_manifest = @import("core/content_manifest.zig");
const content_manager = @import("ui/content_manager.zig");
const content_view = @import("ui/content_view.zig");
const A = std.mem.Allocator;
const Io = std.Io;

pub const Scenario = enum { default, @"cf-restricted", @"cf-manual", @"update-keep", @"update-replace", @"protected-reject" };

const DeepData = struct {
    arena: std.heap.ArenaAllocator,
    scenario: Scenario,
    root: []const u8,
    archive_path: []const u8,
    archive_sha256: [64]u8,
    trace_path: []const u8,
    project_requests: std.atomic.Value(usize) = .init(0),
    file_requests: std.atomic.Value(usize) = .init(0),
    unexpected_requests: std.atomic.Value(usize) = .init(0),
    cdn_requests: std.atomic.Value(usize) = .init(0),
    manual_picks: std.atomic.Value(usize) = .init(0),
    import_attempted: bool = false,
    import_rejected: bool = false,
    review_observed: bool = false,
    ready: bool = false,
    dependencies_ready: bool = false,
    missing_manual: usize = 0,
    confirmed: bool = false,
    current_reasons: [4][]const u8 = undefined,
    current_reason_count: usize = 0,
    seen_reasons: [4][]const u8 = undefined,
    seen_reason_count: usize = 0,
    errors: [32][]const u8 = undefined,
    error_count: usize = 0,
    decision: []const u8 = "none",
    commit_attempted: bool = false,
    commit_completed: bool = false,
    last_job: u64 = 0,
    completed_job: u64 = 0,
    last_kind: enum { other, import_pack, commit } = .other,

    fn init(a: A, io: Io, root: []const u8, scenario: Scenario) !DeepData {
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const g = arena.allocator();
        const mr = "{\"formatVersion\":1,\"game\":\"minecraft\",\"versionId\":\"fixture-v1\",\"name\":\"Deep Fixture Pack\",\"files\":[],\"dependencies\":{\"minecraft\":\"1.21.4\"}}";
        const cf = "{\"manifestType\":\"minecraftModpack\",\"manifestVersion\":1,\"name\":\"Deep Fixture Pack\",\"version\":\"fixture-v1\",\"author\":\"Fixture\",\"overrides\":\"overrides\",\"minecraft\":{\"version\":\"1.21.4\",\"modLoaders\":[]},\"files\":[{\"projectID\":12,\"fileID\":34,\"required\":true}]}";
        const entries: []const ZipEntry = switch (scenario) {
            .@"cf-restricted", .@"cf-manual" => &.{ .{ .path = "manifest.json", .bytes = cf }, .{ .path = "overrides/config/fixture-pack.cfg", .bytes = "hermetic pack settings\n" } },
            .@"update-keep", .@"update-replace" => &.{ .{ .path = "modrinth.index.json", .bytes = mr }, .{ .path = "overrides/config/fixture-pack.cfg", .bytes = "updated config\n" }, .{ .path = "overrides/mods/state.jar", .bytes = "new" } },
            .@"protected-reject" => &.{ .{ .path = "modrinth.index.json", .bytes = mr }, .{ .path = "overrides/assets/a.txt", .bytes = "attempted replacement\n" } },
            .default => return error.FixtureDeepScenarioRequired,
        };
        const archive_name = switch (scenario) {
            .@"cf-restricted", .@"cf-manual" => "fixture-pack-deep.zip",
            .@"update-keep", .@"update-replace", .@"protected-reject" => "fixture-pack-deep.mrpack",
            .default => return error.FixtureDeepScenarioRequired,
        };
        const archive_path = try std.fs.path.join(g, &.{ root, archive_name });
        const bytes = try zipBytes(g, entries);
        try ensureBytes(g, io, archive_path, bytes, true);
        if (scenario == .@"cf-manual") for (manual_names, manual_bytes) |name, payload| try ensureBytes(g, io, try std.fs.path.join(g, &.{ root, name }), payload, true);
        return .{ .arena = arena, .scenario = scenario, .root = try g.dupe(u8, root), .archive_path = archive_path, .archive_sha256 = std.fmt.bytesToHex(&sha256(bytes), .lower), .trace_path = try std.fs.path.join(g, &.{ root, "native-pack-deep-trace.json" }) };
    }

    fn seed(self: *DeepData, io: Io, instance_paths: *const paths.Paths, fresh: bool) !void {
        const g = self.arena.allocator();
        const game = try instance_paths.instanceDirectory("fixture-game");
        defer instance_paths.allocator.free(game);
        if (self.scenario == .@"update-keep" or self.scenario == .@"update-replace") {
            const seeds = [_]struct { path: []const u8, bytes: []const u8 }{
                .{ .path = "config/fixture-pack.cfg", .bytes = "locally edited config\n" }, .{ .path = "config/obsolete.cfg", .bytes = "obsolete bytes\n" }, .{ .path = "mods/state.jar.disabled", .bytes = "old" }, .{ .path = "mods/user.jar", .bytes = "unmanaged bytes\n" }, .{ .path = "mods/standalone.jar", .bytes = "standalone bytes\n" },
            };
            for (seeds) |item| try ensureBytes(g, io, try std.fs.path.join(g, &.{ game, item.path }), item.bytes, fresh);
            var records = [_]content_manifest.ManagedFile{ try seedRecord(g, "config/fixture-pack.cfg", "original config\n", true), try seedRecord(g, "config/obsolete.cfg", "obsolete bytes\n", true), try seedRecord(g, "mods/state.jar", "old", false), try seedRecord(g, "mods/standalone.jar", "standalone bytes\n", true) };
            records[3].project_id = "fixture-standalone";
            records[3].role = .content;
            records[3].identity_provenance = .official_file;
            records[3].standalone = true;
            const document: content_manifest.Manifest = .{ .schema_version = 2, .instance_id = "fixture-primary", .pack_version = "fixture-v0", .files = &records, .pack_membership = .{ .identity = .{ .provider = .modrinth, .project_id = "DraftAlpha42", .version_id = "fixture-v0" }, .paths = &.{ "config/fixture-pack.cfg", "config/obsolete.cfg", "mods/state.jar" } } };
            const encoded = try content_manifest.serialize(g, document);
            const manifest_path = try instance_paths.instanceManifest("fixture-primary");
            defer instance_paths.allocator.free(manifest_path);
            try ensureBytes(g, io, manifest_path, encoded, fresh);
        } else if (self.scenario == .@"protected-reject") {
            try ensureBytes(g, io, try std.fs.path.join(g, &.{ game, "assets/a.txt" }), "protected asset sentinel\n", fresh);
        }
        if (fresh) try self.writeTrace(io, false) else {
            // A resumed owner must still match its unmodified seeded state.
            const expected = try self.traceBytes(g, false);
            try ensureBytes(g, io, self.trace_path, expected, false);
        }
    }

    fn addReason(self: *DeepData, reason: []const u8) void {
        for (self.seen_reasons[0..self.seen_reason_count]) |known| if (std.mem.eql(u8, known, reason)) return;
        if (self.seen_reason_count < self.seen_reasons.len) {
            self.seen_reasons[self.seen_reason_count] = reason;
            self.seen_reason_count += 1;
        }
    }

    fn outcome(self: *DeepData, failure: ?anyerror, committed: bool) void {
        if (self.last_job == self.completed_job) return;
        self.completed_job = self.last_job;
        if (failure) |err| {
            if (self.error_count < self.errors.len) {
                self.errors[self.error_count] = @errorName(err);
                self.error_count += 1;
            }
            if (self.last_kind == .import_pack) self.import_rejected = true;
        }
        if (self.last_kind == .commit and committed) self.commit_completed = true;
    }

    // Only acquire-published job outcomes are read; all review values are copied
    // while the draft is alive. No Manager/UI-owned slice survives in this data.
    fn observe(self: *DeepData, manager: *content_manager.Manager, ui: *content_view.Ui) void {
        if (manager.active) |job| {
            if (job.task) |task| {
                // A collected commit can immediately spawn refresh in tick().
                // Consume its retained report before changing the observed ID.
                if (task.id != self.last_job and self.last_job != self.completed_job) {
                    const snapshot = manager.snapshot();
                    self.outcome(snapshot.failure, if (snapshot.report) |report| report.committed else false);
                }
                self.last_job = task.id;
            }
            self.last_kind = if (job.request == .import_pack or job.request == .inspected_pack) .import_pack else if (job.request == .commit) .commit else .other;
            if (self.last_kind == .import_pack) self.import_attempted = true;
            if (self.last_kind == .commit) self.commit_attempted = true;
            if (job.done.load(.acquire)) self.outcome(job.failure, if (job.result.report) |report| report.committed else false);
        } else if (self.last_job != self.completed_job) {
            const snapshot = manager.snapshot();
            self.outcome(snapshot.failure, if (snapshot.report) |report| report.committed else false);
        }
        if (ui.draft) |draft| if (draft.open and std.mem.eql(u8, draft.source.id, "fixture-primary")) {
            self.review_observed = true;
            self.ready = draft.proposal.ready;
            self.dependencies_ready = draft.proposal.dependencies_ready;
            self.missing_manual = draft.proposal.missing_manual;
            self.confirmed = draft.confirmed;
            self.current_reason_count = 0;
            for (draft.proposal.files) |file| {
                if (!file.required or !(file.selected orelse true) or file.download != .manual_required) continue;
                var verified = false;
                for (draft.proposal.manual_source_status) |status| if (std.mem.eql(u8, status.path, file.record.path)) {
                    verified = status.verified;
                    break;
                };
                if (verified) continue;
                const reason = @tagName(file.download.manual_required.reason);
                var duplicate = false;
                for (self.current_reasons[0..self.current_reason_count]) |known| if (std.mem.eql(u8, known, reason)) {
                    duplicate = true;
                    break;
                };
                if (!duplicate and self.current_reason_count < self.current_reasons.len) {
                    self.current_reasons[self.current_reason_count] = reason;
                    self.current_reason_count += 1;
                }
                self.addReason(reason);
            }
            for (draft.decisions.items) |decision| if (std.mem.eql(u8, decision.path, "config/fixture-pack.cfg")) {
                self.decision = if (decision.choice == .keep_local) "keep_local" else "replace_backup";
            };
        };
    }

    fn traceBytes(self: *DeepData, a: A, joined: bool) ![]u8 {
        const picks = @min(self.manual_picks.load(.acquire), manual_labels.len);
        return std.json.Stringify.valueAlloc(a, .{
            .schema_version = @as(u32, 1),
            .fixture_root = self.root,
            .scenario = @tagName(self.scenario),
            .instance_id = "fixture-primary",
            .archive_sha256 = self.archive_sha256[0..],
            .phase = if (joined) @as([]const u8, "joined") else "seeded",
            .workers_joined = joined,
            .http = .{ .project = self.project_requests.load(.acquire), .file = self.file_requests.load(.acquire), .unexpected = self.unexpected_requests.load(.acquire), .cdn = self.cdn_requests.load(.acquire) },
            .manual_picks = manual_labels[0..picks],
            .manual_reasons_seen = self.seen_reasons[0..self.seen_reason_count],
            .errors = self.errors[0..self.error_count],
            .import = .{ .attempted = self.import_attempted, .rejected = self.import_rejected },
            .review = .{ .observed = self.review_observed, .ready = self.ready, .dependencies_ready = self.dependencies_ready, .missing_manual = self.missing_manual, .manual_reasons = self.current_reasons[0..self.current_reason_count], .confirmed = self.confirmed },
            .decision = self.decision,
            .commit = .{ .attempted = self.commit_attempted, .completed = self.commit_completed },
        }, .{});
    }
    fn writeTrace(self: *DeepData, io: Io, joined: bool) !void {
        const a = self.arena.child_allocator;
        const bytes = try self.traceBytes(a, joined);
        defer a.free(bytes);
        try writeBytes(io, self.trace_path, bytes);
    }
};
const manual_names = [_][]const u8{ "deep-manual-wrong-length.bin", "deep-manual-wrong-hash.bin", "deep-manual-correct.bin" };
const manual_bytes = [_][]const u8{ "wrong", "bad", "mod" };
// Preserve a fourth attempted pick as invalid rather than clamping to success.
const manual_labels = [_][]const u8{ "wrong-length", "wrong-hash", "correct", "unexpected" };
fn ensureBytes(a: A, io: Io, path: []const u8, expected: []const u8, create: bool) !void {
    const actual = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            if (!create) return error.FixtureDeepSeedMissing;
            try writeBytes(io, path, expected);
            return;
        },
        else => return err,
    };
    defer a.free(actual);
    if (!std.mem.eql(u8, actual, expected)) return error.FixtureDeepSeedChanged;
}
fn seedRecord(a: A, path: []const u8, bytes: []const u8, enabled: bool) !content_manifest.ManagedFile {
    return .{ .path = path, .provider = .modrinth, .project_id = "DraftAlpha42", .version_id = "fixture-v0", .hashes = .{ .sha256 = try a.dupe(u8, &std.fmt.bytesToHex(&sha256(bytes), .lower)) }, .size = bytes.len, .role = .override, .enabled = enabled, .identity_provenance = .pack_override, .standalone = false };
}

pub const Scene = enum { layout, pack, @"pack-prepared" };
pub const Archive = enum { modrinth, curseforge };
pub const Hold = enum { none, inspection, content, installer };

pub const Context = struct {
    allocator: A,
    archive_path: []u8,
    curseforge_path: []u8,
    archive: Archive = .modrinth,
    inner_lease: ?content_install.Lease = null,
    inner_worker_recheck: ?*const fn (?*anyopaque, []const u8) anyerror!void = null,
    hold_inspection: std.atomic.Value(bool) = .init(false),
    inspection_entered: std.atomic.Value(bool) = .init(false),
    inspection_exited: std.atomic.Value(bool) = .init(false),
    hold_content: std.atomic.Value(bool) = .init(false),
    content_entered: std.atomic.Value(bool) = .init(false),
    content_released: std.atomic.Value(bool) = .init(false),
    http_requests: std.atomic.Value(usize) = .init(0),
    content_release_observer: ?*std.atomic.Value(bool) = null,
    prepared: ?PreparedData = null,
    hold_installer: std.atomic.Value(bool) = .init(false),
    installer_entered: std.atomic.Value(bool) = .init(false),
    installer_exited: std.atomic.Value(bool) = .init(false),
    proof_borrowed: std.atomic.Value(bool) = .init(false),
    validated_roles: std.atomic.Value(bool) = .init(false),
    staged: std.atomic.Value(bool) = .init(false),
    rolled_back: std.atomic.Value(bool) = .init(false),
    fail_after_staging: std.atomic.Value(bool) = .init(false),
    synthetic_requests: std.atomic.Value(usize) = .init(0),
    jvm_invocations: std.atomic.Value(usize) = .init(0),
    installer_exit_observer: ?*std.atomic.Value(bool) = null,
    deep: ?DeepData = null,

    pub fn initScenario(a: A, io: Io, root: []const u8, scenario: Scenario) !Context {
        var self = try init(a, io, root);
        errdefer self.deinit();
        if (scenario != .default) self.deep = try DeepData.init(a, io, root, scenario);
        return self;
    }

    pub fn init(a: A, io: Io, root: []const u8) !Context {
        const archive_path = try std.fs.path.join(a, &.{ root, "fixture-pack.mrpack" });
        errdefer a.free(archive_path);
        const curseforge_path = try std.fs.path.join(a, &.{ root, "fixture-pack-curseforge.zip" });
        errdefer a.free(curseforge_path);
        var dir = try Io.Dir.cwd().openDir(io, root, .{});
        defer dir.close(io);
        const index = "{\"formatVersion\":1,\"game\":\"minecraft\",\"versionId\":\"fixture-v1\",\"name\":\"Fixture Pack\",\"files\":[],\"dependencies\":{\"minecraft\":\"1.21.4\"}}";
        try storedZip(a, io, dir, "fixture-pack.mrpack", &.{
            .{ .path = "modrinth.index.json", .bytes = index },
            .{ .path = "overrides/config/fixture-pack.cfg", .bytes = "hermetic pack settings\n" },
        });
        const cf_manifest = "{\"manifestType\":\"minecraftModpack\",\"manifestVersion\":1,\"name\":\"Fixture Pack\",\"version\":\"fixture-v1\",\"author\":\"Fixture\",\"overrides\":\"overrides\",\"minecraft\":{\"version\":\"1.21.4\",\"modLoaders\":[]},\"files\":[]}";
        try storedZip(a, io, dir, "fixture-pack-curseforge.zip", &.{
            .{ .path = "manifest.json", .bytes = cf_manifest },
            .{ .path = "overrides/config/fixture-pack.cfg", .bytes = "hermetic pack settings\n" },
        });
        return .{ .allocator = a, .archive_path = archive_path, .curseforge_path = curseforge_path };
    }

    pub fn path(self: *const Context) []const u8 {
        if (self.deep) |data| return data.archive_path;
        if (self.prepared) |data| return data.archive_path;
        return if (self.archive == .modrinth) self.archive_path else self.curseforge_path;
    }

    pub fn releaseHolds(self: *Context) void {
        self.hold_inspection.store(false, .release);
        self.hold_content.store(false, .release);
        self.hold_installer.store(false, .release);
    }

    /// Owner must JOIN Controller/Ui/Content before calling this.
    pub fn deinit(self: *Context) void {
        if (self.deep) |*data| data.arena.deinit();
        if (self.prepared) |*data| data.deinit();
        self.allocator.free(self.archive_path);
        self.allocator.free(self.curseforge_path);
        self.* = undefined;
    }

    pub fn runner(self: *Context) controller.Runner {
        if (self.prepared != null) return .{ .context = self, .inspect = inspect, .manifest = syntheticManifest, .fetcher = .{ .context = self, .fetch = syntheticMetadata }, .transport = .{ .context = self, .get = syntheticGet }, .probe = markerProbe };
        return .{ .context = self, .inspect = inspect, .manifest = denyManifest, .fetcher = .{ .context = self, .fetch = denyMetadata } };
    }

    pub fn uiRunner(self: *Context) pack_view.Runner {
        // Deterministic Browse selection; inspection and cleanup remain real.
        return .{ .context = self, .pick = pick, .inspect = inspectPreview };
    }

    pub fn contentLease(self: *Context, inner: content_install.Lease, worker_recheck: *const fn (?*anyopaque, []const u8) anyerror!void) content_install.Lease {
        self.inner_lease = inner;
        self.inner_worker_recheck = worker_recheck;
        return .{ .context = self, .acquire = acquire, .recheck = recheck, .release = release };
    }

    fn from(raw: ?*anyopaque) !*Context {
        return @ptrCast(@alignCast(raw orelse return error.MissingFixtureContext));
    }

    fn pick(raw: ?*anyopaque, a: A) !?[:0]const u8 {
        const self = try from(raw);
        const owned = try a.dupeZ(u8, self.path());
        return owned;
    }

    fn inspectPreview(_: ?*anyopaque, a: A, io: Io, root: *const paths.Paths, archive: []const u8, cancel: ?*const packs.CancelToken) !packs.Inspection {
        // Preview completes before a held Controller preparation is admitted.
        return packs.inspect(a, io, root, archive, cancel);
    }

    fn inspect(raw: ?*anyopaque, a: A, io: Io, root: *const paths.Paths, archive: []const u8, cancel: ?*const packs.CancelToken) !packs.Inspection {
        const self = try from(raw);
        var inspection = try packs.inspect(a, io, root, archive, cancel);
        errdefer {
            inspection.cleanup(io) catch {};
            inspection.deinit();
        }
        self.inspection_entered.store(true, .release);
        defer self.inspection_exited.store(true, .release);
        while (self.hold_inspection.load(.acquire)) {
            if (cancel) |token| if (token.load(.acquire)) return error.Canceled;
            std.Thread.yield() catch {};
        }
        if (cancel) |token| if (token.load(.acquire)) return error.Canceled;
        return inspection;
    }

    fn denyManifest(_: ?*anyopaque, _: A, _: Io, _: ?*const packs.CancelToken) !metadata.Owned(metadata.manifest.Manifest) {
        return error.FixtureMetadataUnavailable;
    }

    fn denyMetadata(_: ?*anyopaque, _: A, _: Io, _: metadata_loader.Request) ![]u8 {
        return error.FixtureMetadataUnavailable;
    }

    pub fn seedScenario(self: *Context, io: Io, instance_paths: *const paths.Paths, fresh: bool) !void {
        if (self.deep) |*data| try data.seed(io, instance_paths, fresh);
    }

    pub fn observeContent(self: *Context, manager: *content_manager.Manager, ui: *content_view.Ui) void {
        if (self.deep) |*data| data.observe(manager, ui);
    }

    /// Caller invokes only after Controller, picker and all services have JOINed.
    pub fn writeJoinedTrace(self: *Context, io: Io) !void {
        if (self.deep) |*data| try data.writeTrace(io, true);
    }

    pub fn contentPicker(self: *Context) content_view.PickerRunner {
        return if (self.deep != null) .{ .context = self, .pick = pickContent } else .{};
    }

    fn pickContent(raw: ?*anyopaque, a: A, kind: content_view.PickerKind) !?[:0]const u8 {
        const self = try from(raw);
        const data = if (self.deep) |*value| value else return error.FixtureDeepScenarioRequired;
        if (kind == .archive) return try a.dupeZ(u8, data.archive_path);
        if (data.scenario != .@"cf-manual") return error.FixtureUnexpectedManualPick;
        const index = data.manual_picks.fetchAdd(1, .acq_rel);
        if (index >= manual_names.len) return error.FixtureUnexpectedManualPick;
        const picked_path = try std.fs.path.join(a, &.{ data.root, manual_names[index] });
        defer a.free(picked_path);
        return try a.dupeZ(u8, picked_path);
    }

    pub fn contentHttp(raw: ?*anyopaque, a: A, io: Io, request: http.Request) !http.Response {
        const self = try from(raw);
        const data = if (self.deep) |*value| value else return denyHttp(raw, a, io, request);
        if (std.mem.startsWith(u8, request.url, "https://edge.forgecdn.net/")) _ = data.cdn_requests.fetchAdd(1, .monotonic);
        const project = std.mem.eql(u8, request.url, "https://api.curseforge.com/v1/mods/12");
        const file = std.mem.eql(u8, request.url, "https://api.curseforge.com/v1/mods/12/files/34");
        var keyed = false;
        for (request.headers) |header| if (std.ascii.eqlIgnoreCase(header.name, "x-api-key")) {
            keyed = std.mem.eql(u8, header.value, "fixture-pack-key");
            break;
        };
        if ((data.scenario != .@"cf-restricted" and data.scenario != .@"cf-manual") or request.method != .get or request.body != null or !keyed or (!project and !file)) {
            _ = data.unexpected_requests.fetchAdd(1, .monotonic);
            return error.FixtureUnexpectedHttp;
        }
        const count = if (project) data.project_requests.fetchAdd(1, .monotonic) else data.file_requests.fetchAdd(1, .monotonic);
        if (count != 0) {
            _ = data.unexpected_requests.fetchAdd(1, .monotonic);
            return error.FixtureUnexpectedHttp;
        }
        const restricted = data.scenario == .@"cf-restricted";
        const body = if (project) try std.json.Stringify.valueAlloc(a, .{ .data = .{
            .id = @as(u32, 12),
            .gameId = @as(u32, 432),
            .classId = @as(u32, 12),
            .name = "Example",
            .summary = "fixture",
            .links = .{ .websiteUrl = "https://www.curseforge.com/minecraft/texture-packs/example" },
            .allowModDistribution = !restricted,
        } }, .{}) else try std.json.Stringify.valueAlloc(a, .{ .data = .{
            .id = @as(u32, 34),
            .gameId = @as(u32, 432),
            .modId = @as(u32, 12),
            .displayName = "Example 1",
            .fileName = "example.jar",
            .isAvailable = true,
            .downloadUrl = if (restricted) @as(?[]const u8, "https://edge.forgecdn.net/files/0/34/example.jar") else @as(?[]const u8, null),
            .fileLength = @as(u64, 3),
            .hashes = &.{.{ .algo = @as(u32, 1), .value = std.fmt.bytesToHex(&sha1("mod"), .lower)[0..] }},
            .gameVersions = &.{"1.21.4"},
            .dependencies = @as([]const struct {}, &.{}),
        } }, .{});
        return .{ .allocator = a, .status = 200, .body = body };
    }

    pub fn denyHttp(raw: ?*anyopaque, _: A, _: Io, _: http.Request) !http.Response {
        const self = try from(raw);
        _ = self.http_requests.fetchAdd(1, .monotonic);
        return error.FixtureUnexpectedHttp;
    }

    fn acquire(raw: ?*anyopaque, id: []const u8) !void {
        const self = try from(raw);
        const inner = self.inner_lease orelse return error.MissingFixtureLease;
        try inner.acquire(inner.context, id);
        self.content_released.store(false, .release);
    }

    fn recheck(raw: ?*anyopaque, id: []const u8) !void {
        const self = try from(raw);
        const inner = self.inner_lease orelse return error.MissingFixtureLease;
        try inner.recheck(inner.context, id);
    }

    /// Forward the real waiting lease check without holding ordinary refreshes.
    pub fn workerRecheckUnheld(raw: ?*anyopaque, id: []const u8) !void {
        const self = try from(raw);
        const inner = self.inner_lease orelse return error.MissingFixtureLease;
        const recheck_worker = self.inner_worker_recheck orelse return error.MissingFixtureWorkerCheck;
        try recheck_worker(inner.context, id);
    }

    /// Real waiting lease check completes and unlocks before the diagnostic hold.
    pub fn workerRecheck(raw: ?*anyopaque, id: []const u8) !void {
        try workerRecheckUnheld(raw, id);
        const self = try from(raw);
        self.content_entered.store(true, .release);
        // Tests hold only a worker that passed the actual stable-ID checker.
        while (self.hold_content.load(.acquire)) std.Thread.yield() catch {};
    }

    fn release(raw: ?*anyopaque, id: []const u8) void {
        const self = from(raw) catch return;
        const inner = self.inner_lease orelse return;
        inner.release(inner.context, id);
        self.content_released.store(true, .release);
        if (self.content_release_observer) |observer| observer.store(true, .release);
    }
};

const ZipEntry = struct { path: []const u8, bytes: []const u8 };
fn number(comptime T: type, a: A, bytes: *std.ArrayList(u8), value: T) !void {
    var encoded: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &encoded, value, .little);
    try bytes.appendSlice(a, &encoded);
}
fn storedZip(a: A, io: Io, dir: Io.Dir, name: []const u8, entries: []const ZipEntry) !void {
    const bytes = try zipBytes(a, entries);
    defer a.free(bytes);
    try dir.writeFile(io, .{ .sub_path = name, .data = bytes });
}
fn zipBytes(a: A, entries: []const ZipEntry) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(a);
    const offsets = try a.alloc(u32, entries.len);
    defer a.free(offsets);
    for (entries, offsets) |entry, *offset| {
        offset.* = @intCast(bytes.items.len);
        try number(u32, a, &bytes, 0x04034b50);
        for ([_]u16{ 20, 0, 0, 0, 0 }) |value| try number(u16, a, &bytes, value);
        try number(u32, a, &bytes, std.hash.Crc32.hash(entry.bytes));
        for (0..2) |_| try number(u32, a, &bytes, @intCast(entry.bytes.len));
        try number(u16, a, &bytes, @intCast(entry.path.len));
        try number(u16, a, &bytes, 0);
        try bytes.appendSlice(a, entry.path);
        try bytes.appendSlice(a, entry.bytes);
    }
    const central: u32 = @intCast(bytes.items.len);
    for (entries, offsets) |entry, offset| {
        try number(u32, a, &bytes, 0x02014b50);
        for ([_]u16{ 20, 20, 0, 0, 0, 0 }) |value| try number(u16, a, &bytes, value);
        try number(u32, a, &bytes, std.hash.Crc32.hash(entry.bytes));
        for (0..2) |_| try number(u32, a, &bytes, @intCast(entry.bytes.len));
        try number(u16, a, &bytes, @intCast(entry.path.len));
        for (0..4) |_| try number(u16, a, &bytes, 0);
        try number(u32, a, &bytes, 0);
        try number(u32, a, &bytes, offset);
        try bytes.appendSlice(a, entry.path);
    }
    const central_size: u32 = @intCast(bytes.items.len - central);
    try number(u32, a, &bytes, 0x06054b50);
    for (0..2) |_| try number(u16, a, &bytes, 0);
    for (0..2) |_| try number(u16, a, &bytes, @intCast(entries.len));
    try number(u32, a, &bytes, central_size);
    try number(u32, a, &bytes, central);
    try number(u16, a, &bytes, 0);
    return bytes.toOwnedSlice(a);
}

// These bytes and the Java-17 vanilla declaration are synthetic acceptance data.
// Legacy 1.7.10 does not historically require Java 17; no playable install is claimed.
pub const label = "SyntheticMaterialization";
pub const base_id = "1.7.10";
pub const forge_id = "1.7.10-10.13.4.1614-1.7.10";
const vanilla_url = "https://piston-meta.mojang.com/v1/packages/fixture/1.7.10.json";
const catalog_url = "https://files.minecraftforge.net/net/minecraftforge/forge/maven-metadata.json";
const installer_url = "https://maven.minecraftforge.net/net/minecraftforge/forge/" ++ forge_id ++ "/forge-" ++ forge_id ++ "-installer.jar";
const index_url = "https://piston-meta.mojang.com/v1/packages/fixture/assets.json";
const index_bytes = "{\"objects\":{}}";
const profile_bytes =
    "{\"install\":{\"minecraft\":\"1.7.10\",\"path\":\"net.minecraftforge:forge:1.7.10-10.13.4.1614-1.7.10\",\"filePath\":\"forge-universal.jar\"},\"versionInfo\":{\"id\":\"SyntheticMaterialization-Forge\",\"inheritsFrom\":\"1.7.10\",\"jar\":\"1.7.10\",\"mainClass\":\"net.minecraft.launchwrapper.Launch\",\"minecraftArguments\":\"--tweakClass cpw.mods.fml.common.launcher.FMLTweaker\",\"libraries\":[{\"name\":\"net.minecraftforge:forge:1.7.10-10.13.4.1614-1.7.10\",\"url\":\"https://maven.minecraftforge.net/\"}]}}";

pub const PreparedData = struct {
    arena: *std.heap.ArenaAllocator,
    backing: A,
    root: []const u8,
    archive_path: []const u8,
    java17_path: []const u8,
    java8_path: []const u8,
    vanilla_bytes: []const u8,
    manifest_bytes: []const u8,
    installer_bytes: []const u8,
    installer_hex: [40]u8,
    client_bytes: []const u8,
    library_bytes: []const u8,
    client_url: []const u8,

    fn deinit(self: *PreparedData) void {
        self.arena.deinit();
        self.backing.destroy(self.arena);
        self.* = undefined;
    }
};

pub fn initPrepared(self: *Context, a: A, io: Io, root: []const u8) !void {
    if (self.prepared != null) return error.FixturePreparedAlreadyInitialized;
    const arena = try a.create(std.heap.ArenaAllocator);
    arena.* = .init(a);
    errdefer {
        arena.deinit();
        a.destroy(arena);
    }
    const g = arena.allocator();
    var p = try paths.Paths.init(g, io, root);
    defer p.deinit();
    const client = try zipBytes(g, &.{});
    const library = try zipBytes(g, &.{});
    const client_hex = std.fmt.bytesToHex(&sha1(client), .lower);
    const index_hex = std.fmt.bytesToHex(&sha1(index_bytes), .lower);
    const client_url = try std.fmt.allocPrint(g, "https://piston-data.mojang.com/v1/objects/{s}/client.jar", .{client_hex});
    const vanilla_bytes = try std.json.Stringify.valueAlloc(g, .{
        .id = base_id,
        .type = "release",
        .mainClass = "net.minecraft.client.main.Main",
        .minecraftArguments = "--username fixture",
        .javaVersion = .{ .majorVersion = @as(u32, 17), .component = label },
        .downloads = .{ .client = .{ .url = client_url, .sha1 = client_hex[0..], .size = client.len } },
        .assetIndex = .{ .id = "fixture-synthetic", .url = index_url, .sha1 = index_hex[0..], .size = index_bytes.len, .totalSize = @as(u64, 0) },
        .assets = "fixture-synthetic",
        .libraries = .{},
    }, .{});
    const vanilla_document = vanilla_bytes;
    const vanilla_hex = std.fmt.bytesToHex(&sha1(vanilla_document), .lower);
    const manifest_bytes = try std.json.Stringify.valueAlloc(g, .{
        .latest = .{ .release = base_id, .snapshot = base_id },
        .versions = .{.{ .id = base_id, .type = "release", .url = vanilla_url, .sha1 = vanilla_hex[0..], .time = "2024-01-01T00:00:00+00:00", .releaseTime = "2024-01-01T00:00:00+00:00", .complianceLevel = @as(u32, 1) }},
    }, .{});
    const installer = try zipBytes(g, &.{ .{ .path = "install_profile.json", .bytes = profile_bytes }, .{ .path = "forge-universal.jar", .bytes = library } });
    const java_name = if (builtin.os.tag == .windows) "java.exe" else "java";
    const java17 = try std.fs.path.join(g, &.{ p.jdks, "SyntheticMaterialization-17", "bin", java_name });
    const java8 = try std.fs.path.join(g, &.{ p.jdks, "SyntheticMaterialization-8", "bin", java_name });
    try writeBytes(io, java17, "SyntheticMaterialization Java marker 17\n");
    try writeBytes(io, java8, "SyntheticMaterialization Java marker 8\n");
    const archive_path = try std.fs.path.join(g, &.{ p.root, "fixture-pack-prepared.mrpack" });
    const index = "{\"formatVersion\":1,\"game\":\"minecraft\",\"versionId\":\"synthetic-v1\",\"name\":\"SyntheticMaterialization\",\"files\":[],\"dependencies\":{\"minecraft\":\"1.7.10\",\"forge\":\"1.7.10-10.13.4.1614-1.7.10\"}}";
    const archive_bytes = try zipBytes(g, &.{ .{ .path = "modrinth.index.json", .bytes = index }, .{ .path = "overrides/config/fixture-pack.cfg", .bytes = "SyntheticMaterialization settings\n" } });
    try writeBytes(io, archive_path, archive_bytes);
    // Publish only after every allocation/write succeeds; callbacks borrow this owner.
    self.prepared = .{ .arena = arena, .backing = a, .root = try g.dupe(u8, p.root), .archive_path = archive_path, .java17_path = java17, .java8_path = java8, .vanilla_bytes = vanilla_document, .manifest_bytes = manifest_bytes, .installer_bytes = installer, .installer_hex = std.fmt.bytesToHex(&sha1(installer), .lower), .client_bytes = client, .library_bytes = library, .client_url = client_url };
}

pub fn registerMarkers(self: *Context, manager: *java.Manager) !void {
    const data = self.prepared orelse return error.FixtureMetadataUnavailable;
    try manager.addDownloaded(.{ .path = data.java17_path, .major = 17, .vendor = label });
    try manager.addDownloaded(.{ .path = data.java8_path, .major = 8, .vendor = label });
}

fn checkCancel(cancel: ?*const packs.CancelToken) !void {
    if (cancel) |token| if (token.load(.acquire)) return error.Canceled;
}
fn syntheticManifest(raw: ?*anyopaque, a: A, _: Io, cancel: ?*const packs.CancelToken) !metadata.Owned(metadata.manifest.Manifest) {
    try checkCancel(cancel);
    const self = try Context.from(raw);
    const data = self.prepared orelse return error.FixtureMetadataUnavailable;
    _ = self.synthetic_requests.fetchAdd(1, .monotonic);
    return metadata.manifest.parseSlice(a, data.manifest_bytes);
}
fn syntheticMetadata(raw: ?*anyopaque, a: A, _: Io, request: metadata_loader.Request) ![]u8 {
    const self = try Context.from(raw);
    const data = self.prepared orelse return error.FixtureMetadataUnavailable;
    if (!std.mem.eql(u8, request.id, base_id) or !std.mem.eql(u8, request.url, vanilla_url)) return error.FixtureUnexpectedMetadata;
    const expected = request.sha1 orelse return error.MissingHash;
    const actual = sha1(data.vanilla_bytes);
    if (!std.mem.eql(u8, &expected, &actual)) return error.HashMismatch;
    if (request.size) |size| if (size != data.vanilla_bytes.len) return error.SizeMismatch;
    if (data.vanilla_bytes.len > request.max_bytes) return error.MetadataTooLarge;
    _ = self.synthetic_requests.fetchAdd(1, .monotonic);
    return a.dupe(u8, data.vanilla_bytes);
}
fn syntheticGet(raw: ?*anyopaque, a: A, url: []const u8, max_bytes: usize, control: loaders.Control) !loaders.Response {
    try control.check();
    const self = try Context.from(raw);
    const data = self.prepared orelse return error.FixtureMetadataUnavailable;
    const body: []const u8 = if (std.mem.eql(u8, url, catalog_url)) "{\"1.7.10\":[\"1.7.10-10.13.4.1614-1.7.10\"]}" else if (std.mem.eql(u8, url, installer_url)) data.installer_bytes else if (std.mem.eql(u8, url, installer_url ++ ".sha1")) &data.installer_hex else return error.FixtureUnexpectedMetadata;
    if (body.len > max_bytes) return error.MetadataTooLarge;
    _ = self.synthetic_requests.fetchAdd(1, .monotonic);
    const bytes = try a.dupe(u8, body);
    errdefer a.free(bytes);
    const final_url = try a.dupe(u8, url);
    errdefer a.free(final_url);
    try control.check();
    return .{ .bytes = bytes, .final_url = final_url, .status = 200 };
}
fn markerProbe(raw: ?*anyopaque, a: A, io: Io, path: []const u8, cancel: ?*const packs.CancelToken) !java.Runtime {
    try checkCancel(cancel);
    const self = try Context.from(raw);
    const data = self.prepared orelse return error.FixtureMetadataUnavailable;
    const major: u32 = if (std.mem.eql(u8, path, data.java17_path)) 17 else if (std.mem.eql(u8, path, data.java8_path)) 8 else return error.FixtureUnexpectedJavaPath;
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(128));
    defer a.free(bytes);
    const expected = if (major == 17) "SyntheticMaterialization Java marker 17\n" else "SyntheticMaterialization Java marker 8\n";
    if (!std.mem.eql(u8, bytes, expected)) return error.FixtureJavaMarkerChanged;
    try checkCancel(cancel);
    const owned_path = try a.dupe(u8, path);
    errdefer a.free(owned_path);
    return .{ .path = owned_path, .major = major, .vendor = try a.dupe(u8, label) };
}

pub fn environment() !metadata.rules.Environment {
    return .{ .os_name = switch (builtin.os.tag) {
        .linux => "linux",
        .windows => "windows",
        .macos => "osx",
        else => return error.UnsupportedPlatform,
    }, .arch = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .x86 => "x86",
        else => return error.UnsupportedArchitecture,
    } };
}
fn nowMs(raw: ?*anyopaque) u64 {
    const io: *const Io = @ptrCast(@alignCast(raw.?));
    return @intCast(@divTrunc(Io.Clock.awake.now(io.*).nanoseconds, std.time.ns_per_ms));
}
fn loaderControl(io: *const Io, cancel: *const std.atomic.Value(bool)) loaders.Control {
    return .{ .cancel = cancel, .context = @constCast(io), .now_ms = nowMs, .deadline_ms = nowMs(@constCast(io)) + 10_000 };
}
pub fn prepareProof(self: *Context, a: A, io: Io, target: loader_install.MetadataTarget, cancel: *const std.atomic.Value(bool)) !loader_install.PreparedMetadata {
    var manifest = try syntheticManifest(self, a, io, cancel);
    defer manifest.deinit();
    var p = try paths.Paths.init(a, io, target.root);
    defer p.deinit();
    return loader_install.prepareMetadata(a, io, .{ .root = target.root, .worker_checks = true, .instance_id = target.instance_id, .instance_name = target.instance_name, .generation = target.generation, .selection = target.selection, .environment = target.environment, .vanilla = .{ .root = p.minecraft, .version_id = target.selection.base_id, .manifest = manifest.value, .cancel = cancel }, .fetcher = .{ .context = self, .fetch = syntheticMetadata }, .transport = .{ .context = self, .get = syntheticGet } }, loaderControl(&io, cancel));
}

// Request fields are checked against the genuine owner, not a rewritten proof.
pub fn validateRequest(self: *Context, a: A, io: Io, request: instances_manager.CreateRequest, control: instances_manager.Control) !metadata.Owned(loaders.recipes.Recipe) {
    try control.check();
    const data = self.prepared orelse return error.FixtureMetadataUnavailable;
    const proof = request.prepared orelse return error.MissingPreparedMetadata;
    const loader_id = request.instance.loader_version orelse return error.PreparedMetadataMismatch;
    if (request.instance.loader != .forge or !std.mem.eql(u8, request.root, data.root)) return error.PreparedMetadataMismatch;
    const target: loader_install.MetadataTarget = .{ .root = request.root, .instance_id = request.instance.id, .instance_name = request.instance.name, .generation = request.prepared_generation, .selection = .{ .kind = .forge, .base_id = request.instance.minecraft_version, .loader_id = loader_id }, .environment = try environment() };
    try proof.validateBinding(a, io, target);
    const expected_installer = try zipBytes(a, &.{ .{ .path = "install_profile.json", .bytes = profile_bytes }, .{ .path = "forge-universal.jar", .bytes = data.library_bytes } });
    defer a.free(expected_installer);
    if (!std.mem.eql(u8, proof.source_bytes, expected_installer)) return error.FixturePreparedSourceChanged;
    var replay = try proof.replayBase(a, io, target, loaderControl(&io, control.cancel));
    defer replay.deinit();
    var p = try paths.Paths.init(a, io, request.root);
    defer p.deinit();
    const stage = try std.fmt.allocPrint(a, "{s}/versions/.fixture-prepared-{s}", .{ p.minecraft, request.instance.id });
    defer a.free(stage);
    var recipe = try loaders.prepare(a, proof.catalog.value, target.selection, replay.version.value, proof.bundle, .{ .instance_name = request.instance.name, .stage_root = stage, .environment = target.environment });
    errdefer recipe.deinit();
    const requirements = loaders.recipes.javaRequirements(recipe.value);
    if (requirements.runtime_major != proof.requirements.runtime_major or requirements.installer_major != proof.requirements.installer_major or requirements.runtime_major != 17 or requirements.installer_major != 8) return error.FixtureJavaRequirementsChanged;
    const runtime = try markerProbe(self, a, io, request.instance.java_path orelse return error.FixtureWrongJavaRole, control.cancel);
    defer java.freeRuntime(a, runtime);
    const installer = try markerProbe(self, a, io, request.installer_java orelse return error.FixtureWrongJavaRole, control.cancel);
    defer java.freeRuntime(a, installer);
    if (runtime.major != requirements.runtime_major or installer.major != requirements.installer_major or std.mem.eql(u8, runtime.path, installer.path)) return error.FixtureWrongJavaRole;
    try control.check();
    return recipe;
}

pub fn replayProof(proof: *const loader_install.PreparedMetadata, a: A, io: Io, target: loader_install.MetadataTarget, cancel: *const std.atomic.Value(bool)) !void {
    var replay = try proof.replayBase(a, io, target, loaderControl(&io, cancel));
    defer replay.deinit();
}

fn sha1(bytes: []const u8) metadata.Sha1 {
    var result: metadata.Sha1 = undefined;
    std.crypto.hash.Sha1.hash(bytes, &result, .{});
    return result;
}
fn sha256(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}
fn writeBytes(io: Io, path: []const u8, bytes: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path) orelse return error.FixtureUnsafePath);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

pub fn preparedInstaller(self: *Context) instances_manager.Installer {
    return .{ .context = self, .run = syntheticInstall };
}
const ArtifactBinding = struct { path: []const u8, sha256: [64]u8, size: u64 };
const Materialized = struct { destination: []const u8, staged_path: []const u8, bytes: []const u8 };

fn verifyBytes(bytes: []const u8, expected_hash: ?metadata.Sha1, expected_size: ?u64) !void {
    if (expected_size) |size| if (bytes.len != size) return error.SizeMismatch;
    if (expected_hash) |expected| {
        const actual = sha1(bytes);
        if (!std.mem.eql(u8, &actual, &expected)) return error.HashMismatch;
    }
}
fn verifyWritten(a: A, io: Io, path: []const u8, bytes: []const u8) !void {
    const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .file or stat.size != bytes.len) return error.FixtureMaterializedFileChanged;
    const actual = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(8 * 1024 * 1024));
    defer a.free(actual);
    const expected_hash = sha256(bytes);
    const actual_hash = sha256(actual);
    if (!std.mem.eql(u8, &expected_hash, &actual_hash)) return error.HashMismatch;
}
// Existing verified caches are borrowed. Only files created here are rolled back.
fn publishCache(a: A, io: Io, path: []const u8, bytes: []const u8) !bool {
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path) orelse return error.FixtureUnsafePath);
    const file = Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            try verifyWritten(a, io, path, bytes);
            return false;
        },
        else => return err,
    };
    defer file.close(io);
    errdefer Io.Dir.cwd().deleteFile(io, path) catch {};
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
    try verifyWritten(a, io, path, bytes);
    return true;
}

fn syntheticInstall(raw: ?*anyopaque, a: A, io: Io, request: instances_manager.CreateRequest, control: instances_manager.Control) !instances_manager.Installed {
    const self = try Context.from(raw);
    self.proof_borrowed.store(request.prepared != null, .release);
    defer {
        self.proof_borrowed.store(false, .release);
        self.installer_exited.store(true, .release);
        if (self.installer_exit_observer) |observer| observer.store(true, .release);
    }
    var recipe = try validateRequest(self, a, io, request, control);
    defer recipe.deinit();
    try request.lease.recheck(request.lease.context, request.instance.id);
    self.validated_roles.store(true, .release);
    self.installer_entered.store(true, .release);
    while (self.hold_installer.load(.acquire)) {
        try control.check();
        std.Thread.yield() catch {};
    }
    try control.check();
    const data = self.prepared orelse return error.FixtureMetadataUnavailable;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const g = arena.allocator();
    var p = try paths.Paths.init(g, io, request.root);
    defer p.deinit();
    const stage = recipe.value.stage_root;
    const versions = try std.fs.path.join(g, &.{ p.minecraft, "versions" });
    const final = try p.instanceDirectory(request.instance.name);
    const cache_stage = try std.fs.path.join(g, &.{ stage, ".cache" });
    try Io.Dir.cwd().createDirPath(io, versions);
    // Exclusive ownership precedes any staged write; a collision is never removed.
    try Io.Dir.cwd().createDir(io, stage, .fromMode(0o700));
    var committed = false;
    var created: std.ArrayList([]const u8) = .empty;
    defer {
        if (!committed) {
            var rollback_complete = true;
            for (created.items) |path| Io.Dir.cwd().deleteFile(io, path) catch {
                rollback_complete = false;
            };
            Io.Dir.cwd().deleteTree(io, stage) catch {
                rollback_complete = false;
            };
            self.rolled_back.store(rollback_complete, .release);
        }
    }
    const staged_client = try std.fmt.allocPrint(g, "{s}/{s}.jar", .{ stage, request.instance.name });
    try writeBytes(io, staged_client, data.client_bytes);
    try verifyWritten(g, io, staged_client, data.client_bytes);
    self.staged.store(true, .release);
    if (self.fail_after_staging.load(.acquire)) return error.FixtureSyntheticStagingFailure;
    var assets = try metadata.asset_index.parseSlice(g, index_bytes);
    defer assets.deinit();
    var plan = try install_plan.build(g, recipe.value.version, assets.value, try environment(), .{ .root = p.minecraft, .instance_name = request.instance.name, .game_directory = final, .cpu_arch = @tagName(builtin.cpu.arch), .native_arch = if (@bitSizeOf(usize) == 64) .bits64 else .bits32 });
    defer plan.deinit();
    // The declared synthetic metadata has no processors, natives, logging or assets.
    // Reject a changed plan instead of silently skipping any required artifact.
    if (recipe.value.processors.len != 0 or plan.value.native_extractions.len != 0 or plan.value.native_checks.len != 0 or plan.value.asset_materializations.len != 0) return error.FixtureUnexpectedGamePlan;
    var materialized: std.ArrayList(Materialized) = .empty;
    for (plan.value.files) |file| {
        try control.check();
        const bytes: []const u8 = switch (file.kind) {
            .client => if (std.mem.eql(u8, file.url, data.client_url)) data.client_bytes else return error.FixtureUnexpectedGamePlan,
            .asset_index => if (std.mem.eql(u8, file.url, index_url)) index_bytes else return error.FixtureUnexpectedGamePlan,
            .library => blk: {
                if (recipe.value.artifacts.len != 1) return error.FixtureUnexpectedGamePlan;
                const library_path = try std.fs.path.join(g, &.{ p.minecraft, recipe.value.artifacts[0].path });
                if (!std.mem.eql(u8, file.path, library_path)) return error.FixtureUnexpectedGamePlan;
                break :blk data.library_bytes;
            },
            .native, .asset, .logging => return error.FixtureUnexpectedGamePlan,
        };
        try verifyBytes(bytes, file.sha1, file.size);
        const relative = try std.fs.path.relative(g, p.root, null, p.minecraft, file.path);
        if (std.mem.startsWith(u8, relative, "..") or std.fs.path.isAbsolute(relative)) return error.FixtureUnsafePath;
        const staged_path = try std.fs.path.join(g, &.{ cache_stage, relative });
        try writeBytes(io, staged_path, bytes);
        try verifyWritten(g, io, staged_path, bytes);
        try materialized.append(g, .{ .destination = file.path, .staged_path = staged_path, .bytes = bytes });
    }
    if (materialized.items.len != 3 or recipe.value.artifacts.len != 1) return error.FixtureUnexpectedGamePlan;
    const bindings = try g.alloc(ArtifactBinding, recipe.value.artifacts.len);
    for (recipe.value.artifacts, bindings) |artifact, *binding| {
        try verifyBytes(data.library_bytes, artifact.sha1, artifact.size);
        binding.* = .{ .path = artifact.path, .sha256 = std.fmt.bytesToHex(&sha256(data.library_bytes), .lower), .size = data.library_bytes.len };
    }
    var resolved = recipe.value.version;
    resolved.jar = null;
    resolved.inherits_from = null;
    const document = try serde.serialize(g, resolved);
    const descriptor = try std.fmt.allocPrint(g, "{s}/{s}.json", .{ stage, request.instance.name });
    try writeBytes(io, descriptor, document);
    try verifyWritten(g, io, descriptor, document);
    const source_hash = recipe.value.installer_sha1 orelse return error.MissingInstallerChecksum;
    const receipt = try std.json.Stringify.valueAlloc(g, .{ .schema_version = @as(u32, 1), .instance_id = request.instance.id, .instance_name = request.instance.name, .minecraft_version = request.instance.minecraft_version, .loader = @tagName(request.instance.loader), .loader_version = request.instance.loader_version.?, .source_url = recipe.value.source_url, .source_sha1 = std.fmt.bytesToHex(&source_hash, .lower), .profile_sha1 = std.fmt.bytesToHex(&recipe.value.source_sha1, .lower), .metadata_sha256 = std.fmt.bytesToHex(&sha256(document), .lower), .client_sha256 = std.fmt.bytesToHex(&sha256(data.client_bytes), .lower), .client_size = data.client_bytes.len, .client_jar = try std.fmt.allocPrint(g, "{s}.jar", .{request.instance.name}), .artifact_bindings = bindings }, .{});
    const receipt_path = try std.fs.path.join(g, &.{ stage, ".vela-loader.json" });
    try writeBytes(io, receipt_path, receipt);
    try verifyWritten(g, io, receipt_path, receipt);
    var installed = try instances_manager.Installed.init(a, request.instance);
    errdefer installed.deinit();
    try created.ensureTotalCapacity(g, materialized.items.len);
    for (materialized.items) |file| {
        try control.check();
        try request.lease.recheck(request.lease.context, request.instance.id);
        try verifyWritten(g, io, file.staged_path, file.bytes);
        if (try publishCache(g, io, file.destination, file.bytes)) created.appendAssumeCapacity(file.destination);
    }
    try Io.Dir.cwd().deleteTree(io, cache_stage);
    try control.check();
    try request.lease.recheck(request.lease.context, request.instance.id);
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    // Result allocation and all verification precede this atomic directory publication.
    Io.Dir.cwd().renamePreserve(stage, Io.Dir.cwd(), final, io) catch |err| {
        // Do not guess whether an uncertain move published a directory.
        if (Io.Dir.cwd().statFile(io, stage, .{ .follow_symlinks = false })) |_| return err else |_| {
            installed.durability_uncertain = true;
            committed = true;
            return installed;
        }
    };
    committed = true;
    return installed;
}

test "generated deep Context archives reach production inspection with exact formats and identities" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]Scenario{ .@"cf-restricted", .@"cf-manual", .@"update-keep", .@"update-replace", .@"protected-reject" }) |scenario| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root_buffer: [4096]u8 = undefined;
        const root_len = try tmp.dir.realPath(io, &root_buffer);
        var instance_paths = try paths.Paths.init(a, io, root_buffer[0..root_len]);
        defer instance_paths.deinit();
        var context = try Context.initScenario(a, io, instance_paths.root, scenario);
        defer context.deinit();
        try context.seedScenario(io, &instance_paths, true);
        const data = &context.deep.?;
        // Use the same generated archive handoff as Browse, never a separately built ZIP.
        if (scenario == .@"protected-reject") {
            try std.testing.expectEqualStrings(".mrpack", std.fs.path.extension(context.path()));
            try std.testing.expectError(error.ProtectedPath, packs.inspect(a, io, &instance_paths, context.path(), null));
            const sentinel = try std.fs.path.join(a, &.{ instance_paths.minecraft, "versions", "fixture-game", "assets/a.txt" });
            defer a.free(sentinel);
            try verifyWritten(a, io, sentinel, "protected asset sentinel\n");
            continue;
        }
        var inspected = try packs.inspect(a, io, &instance_paths, context.path(), null);
        defer inspected.deinit();
        defer inspected.cleanup(io) catch unreachable;
        try std.testing.expectEqualStrings(&data.archive_sha256, &inspected.source_sha256);
        try std.testing.expectEqualStrings("Deep Fixture Pack", inspected.pack.name);
        try std.testing.expectEqualStrings("fixture-v1", inspected.pack.version);
        try std.testing.expectEqualStrings("1.21.4", inspected.pack.minecraft_version);
        try std.testing.expectEqual(inspected.provider, inspected.pack.identity.provider);
        try std.testing.expectEqualStrings(&data.archive_sha256, inspected.pack.identity.version_id);
        const local_project = try std.fmt.allocPrint(a, "local-{s}", .{data.archive_sha256});
        defer a.free(local_project);
        try std.testing.expectEqualStrings(local_project, inspected.pack.identity.project_id);
        if (scenario == .@"cf-restricted" or scenario == .@"cf-manual") {
            try std.testing.expect(inspected.provider == .curseforge);
            try std.testing.expectEqual(@as(usize, 1), inspected.pack.unresolved.len);
            try std.testing.expectEqualStrings("12", inspected.pack.unresolved[0].project_id);
            try std.testing.expectEqualStrings("34", inspected.pack.unresolved[0].file_id);
            continue;
        }
        try std.testing.expect(inspected.provider == .modrinth);
        try std.testing.expectEqual(@as(usize, 0), inspected.pack.unresolved.len);
        var prepared = try packs.prepareInspected(a, io, &instance_paths, .{ .id = "fixture-primary", .name = "fixture-game", .minecraft_version = "1.21.4" }, &inspected, null);
        defer prepared.deinit();
        defer prepared.cleanup(io) catch unreachable;
        try std.testing.expectEqualStrings("fixture-primary", prepared.instance_id);
        try std.testing.expectEqualStrings("fixture-game", prepared.instance_name);
        try std.testing.expectEqualStrings(local_project, prepared.pack.identity.project_id);
        try std.testing.expectEqualStrings(&data.archive_sha256, prepared.pack.identity.version_id);
        try std.testing.expectEqual(@as(usize, 2), prepared.files.len);
        try std.testing.expectEqual(@as(usize, 2), prepared.manual_files.len);
        var config_seen = false;
        var mod_seen = false;
        for (prepared.files) |file| {
            const is_config = std.mem.eql(u8, file.record.path, "config/fixture-pack.cfg");
            if (is_config) config_seen = true else {
                try std.testing.expectEqualStrings("mods/state.jar", file.record.path);
                mod_seen = true;
            }
            const expected: []const u8 = if (is_config) "updated config\n" else "new";
            try std.testing.expect(file.record.provider == .modrinth);
            try std.testing.expectEqualStrings(local_project, file.record.project_id);
            try std.testing.expectEqualStrings(&data.archive_sha256, file.record.version_id);
            try std.testing.expectEqualStrings(&std.fmt.bytesToHex(&sha256(expected), .lower), file.record.hashes.sha256.?);
            try std.testing.expectEqual(@as(?u64, expected.len), file.record.size);
            try std.testing.expect(file.record.role == .override);
            var mapped = false;
            for (prepared.manual_files) |source| if (std.mem.eql(u8, source.path, file.record.path)) {
                try verifyWritten(a, io, source.source_absolute_path, expected);
                mapped = true;
            };
            try std.testing.expect(mapped);
        }
        try std.testing.expect(config_seen and mod_seen);
        // Preparation leaves the original update baseline and ownership untouched.
        const manifest_path = try instance_paths.instanceManifest("fixture-primary");
        defer a.free(manifest_path);
        const baseline_bytes = try Io.Dir.cwd().readFileAlloc(io, manifest_path, a, .limited(1024 * 1024));
        defer a.free(baseline_bytes);
        var baseline = try content_manifest.parse(a, baseline_bytes);
        defer baseline.deinit();
        try std.testing.expectEqualStrings("fixture-primary", baseline.value.instance_id);
        try std.testing.expectEqualStrings("fixture-v0", baseline.value.pack_version);
        const membership = baseline.value.pack_membership.?;
        try std.testing.expect(membership.identity.provider == .modrinth);
        try std.testing.expectEqualStrings("DraftAlpha42", membership.identity.project_id);
        try std.testing.expectEqualStrings("fixture-v0", membership.identity.version_id);
        try std.testing.expectEqual(@as(usize, 3), membership.paths.len);
        try std.testing.expectEqualStrings("config/fixture-pack.cfg", baseline.value.files[0].path);
        try std.testing.expectEqualStrings("DraftAlpha42", baseline.value.files[0].project_id);
        try std.testing.expectEqualStrings("fixture-v0", baseline.value.files[0].version_id);
        try std.testing.expectEqualStrings(&std.fmt.bytesToHex(&sha256("original config\n"), .lower), baseline.value.files[0].hashes.sha256.?);
        const config_path = try std.fs.path.join(a, &.{ instance_paths.minecraft, "versions", "fixture-game", "config/fixture-pack.cfg" });
        defer a.free(config_path);
        try verifyWritten(a, io, config_path, "locally edited config\n");
    }
}

test "deep observation counts actual failed jobs once and preserves reason history" {
    var data: DeepData = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .scenario = .@"cf-manual", .root = "fixture", .archive_path = "fixture/archive.zip", .archive_sha256 = @splat('0'), .trace_path = "fixture/trace.json" };
    defer data.arena.deinit();
    data.last_job = 1;
    data.outcome(error.SizeMismatch, false);
    data.outcome(error.SizeMismatch, false);
    data.last_job = 2;
    data.outcome(error.HashMismatch, false);
    try std.testing.expectEqual(@as(usize, 2), data.error_count);
    try std.testing.expectEqualStrings("SizeMismatch", data.errors[0]);
    try std.testing.expectEqualStrings("HashMismatch", data.errors[1]);
    data.addReason("missing_url");
    data.addReason("missing_url");
    data.current_reason_count = 0;
    try std.testing.expectEqual(@as(usize, 1), data.seen_reason_count);
    try std.testing.expectEqualStrings("missing_url", data.seen_reasons[0]);
    data.last_job = 3;
    data.last_kind = .commit;
    data.outcome(null, true);
    try std.testing.expect(data.commit_completed);
    data.manual_picks.store(4, .release);
    const bytes = try data.traceBytes(std.testing.allocator, true);
    defer std.testing.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    const picks = parsed.value.object.get("manual_picks").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), picks.len);
    try std.testing.expectEqualStrings("unexpected", picks[3].string);
}

//! Owned navigation state for resource discovery. Worker snapshots are copied before reuse.
const std = @import("std");
const dvui = @import("dvui");
const config = @import("../core/config.zig");
const providers = @import("../core/content_providers.zig");
const manifest = @import("../core/content_manifest.zig");
const install = @import("../core/content_install.zig");
const local = @import("../core/local_content.zig");
const content = @import("content_manager.zig");
const logicalPath = @import("mods_logical_path.zig").logicalPath;
const picker_module = @import("file_picker.zig");
const tasks_module = @import("../core/tasks.zig");
const A = std.mem.Allocator;

fn owned(comptime T: type, a: A, value: T) anyerror!T {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var result: T = undefined;
            inline for (info.field_names, info.field_types) |name, field_type| @field(result, name) = try owned(field_type, a, @field(value, name));
            return result;
        },
        .@"union" => |info| {
            const tag = std.meta.activeTag(value);
            inline for (info.field_names, info.field_types) |name, field_type| if (tag == @field(info.tag_type.?, name)) return @unionInit(T, name, try owned(field_type, a, @field(value, name)));
            unreachable;
        },
        .optional => |info| return if (value) |some| try owned(info.child, a, some) else null,
        .pointer => |info| {
            if (info.size != .slice) @compileError("Only slices are copied");
            const result = try a.alloc(info.child, value.len);
            for (value, result) |item, *dest| dest.* = try owned(info.child, a, item);
            return result;
        },
        else => return value,
    }
}
pub const Route = enum { local, catalog, detail };
pub const Job = enum { idle, search, versions, prepare, resolve, install, recover };
pub const TaskState = enum { none, running, succeeded, failed, canceled };
pub const Choice = struct { dependency_index: usize, version_id: ?[]const u8, include: bool };
pub const Intent = union(enum) {
    search,
    retry,
    page: u32,
    provider: providers.Provider,
    project: providers.Project,
    back,
    version: usize,
    dependency: usize,
    choice: Choice,
    confirm,
    commit,
    cancel,
    dismiss,
    view_local,
    choose_manual: []const u8,
    conflict: manifest.ConflictDecision,
    recover: []const u8,
};
pub const Detail = struct {
    arena: std.heap.ArenaAllocator,
    results: std.heap.ArenaAllocator,
    project: providers.Project,
    versions: []const providers.Version = &.{},
    selected: usize = 0,
    parent_dependency_index: ?usize = null,
    version_changed: bool = false,
    scroll: dvui.ScrollInfo = .{},
    candidates: []const providers.Version = &.{},
    issues: []const providers.DependencyIssue = &.{},
    choices: std.ArrayList(providers.DependencyChoice) = .empty,
    fn create(a: A, project: providers.Project) !*Detail {
        const frame = try a.create(Detail);
        errdefer a.destroy(frame);
        frame.* = .{ .arena = .init(a), .results = .init(a), .project = undefined };
        errdefer frame.arena.deinit();
        frame.project = try owned(providers.Project, frame.arena.allocator(), project);
        return frame;
    }
    fn destroy(self: *Detail, a: A) void {
        self.results.deinit();
        self.arena.deinit();
        a.destroy(self);
    }
    pub fn version(self: *const Detail) ?providers.Version {
        return if (self.selected < self.versions.len) self.versions[self.selected] else null;
    }
    pub fn choice(self: *const Detail, index: usize) ?providers.DependencyChoice {
        const root = self.version() orelse return null;
        for (self.choices.items) |value| if (value.from.provider == root.provider and std.mem.eql(u8, value.from.id, root.id) and value.dependency_index == index) return value;
        return null;
    }
    fn rememberChoice(self: *Detail, value: providers.DependencyChoice) !void {
        const next = try owned(providers.DependencyChoice, self.arena.allocator(), value);
        for (self.choices.items) |*current| if (current.from.provider == next.from.provider and std.mem.eql(u8, current.from.id, next.from.id) and current.dependency_index == next.dependency_index) {
            current.* = next;
            return;
        };
        try self.choices.append(self.arena.allocator(), next);
    }
    fn setChoice(self: *Detail, value: Choice) !void {
        const root = self.version() orelse return error.NoVersion;
        if (value.dependency_index >= root.dependencies.len) return error.InvalidChoice;
        try self.rememberChoice(.{ .from = .{ .provider = root.provider, .id = root.id }, .dependency_index = value.dependency_index, .version_id = value.version_id, .include = value.include });
    }
    fn prepareChoices(self: *Detail) !bool {
        const root = self.version() orelse return error.NoVersion;
        var changed = false;
        var reachable: [129]providers.Version = undefined;
        reachable[0] = root;
        var count: usize = 1;
        var cursor: usize = 0;
        while (cursor < count) : (cursor += 1) {
            const graph_node = reachable[cursor];
            for (graph_node.dependencies, 0..) |dependency, index| {
                if (dependency.kind != .required and dependency.kind != .optional) continue;
                const prior: ?providers.DependencyChoice = for (self.choices.items) |existing| {
                    if (existing.from.provider == graph_node.provider and std.mem.eql(u8, existing.from.id, graph_node.id) and existing.dependency_index == index) break existing;
                } else null;
                if (prior == null or prior.?.version_id == null) {
                    // Provider lists are newest first. Keep explicit choices and
                    // leave optional dependencies excluded until requested.
                    const newest: ?providers.Version = for (self.candidates) |candidate| {
                        if (matchesDependency(candidate, graph_node, dependency)) break candidate;
                    } else null;
                    if (newest != null or (prior == null and dependency.kind == .optional)) {
                        try self.rememberChoice(.{ .from = .{ .provider = graph_node.provider, .id = graph_node.id }, .dependency_index = index, .version_id = if (newest) |candidate| candidate.id else null, .include = if (prior) |existing| existing.include else dependency.kind == .required });
                        changed = true;
                    }
                }
                var include = dependency.kind == .required;
                var selected_id = dependency.version_id;
                for (self.choices.items) |graph_choice| if (graph_choice.from.provider == graph_node.provider and std.mem.eql(u8, graph_choice.from.id, graph_node.id) and graph_choice.dependency_index == index) {
                    include = graph_choice.include;
                    selected_id = graph_choice.version_id orelse dependency.version_id;
                    break;
                };
                if (!include) continue;
                var match: ?providers.Version = null;
                var matches: usize = 0;
                for (self.candidates) |candidate| if (matchesDependency(candidate, graph_node, dependency) and (selected_id == null or std.mem.eql(u8, candidate.id, selected_id.?))) {
                    match = candidate;
                    matches += 1;
                };
                if (matches != 1) continue;
                const next = match.?;
                var seen = false;
                for (reachable[0..count]) |visited| if (visited.provider == next.provider and std.mem.eql(u8, visited.id, next.id)) {
                    seen = true;
                    break;
                };
                if (!seen) {
                    if (count >= reachable.len) return error.DependencyLimit;
                    reachable[count] = next;
                    count += 1;
                }
            }
        }
        var retained: usize = 0;
        for (self.choices.items) |graph_choice| {
            const keep = for (reachable[0..count]) |graph_node| {
                if (graph_choice.from.provider == graph_node.provider and std.mem.eql(u8, graph_choice.from.id, graph_node.id)) break true;
            } else false;
            if (keep) {
                self.choices.items[retained] = graph_choice;
                retained += 1;
            }
        }
        changed = changed or retained != self.choices.items.len;
        self.choices.items.len = retained;
        return changed;
    }
};
pub const Ui = struct {
    allocator: A,
    icons: ?@import("resource_icons.zig").Manager = null,
    context: std.heap.ArenaAllocator,
    catalog_arena: std.heap.ArenaAllocator,
    catalog: []const providers.Project = &.{},
    catalog_scroll: dvui.ScrollInfo = .{},
    instance: ?config.Instance = null,
    kind: local.Kind = .mod,
    route: Route = .local,
    frames: std.ArrayList(*Detail) = .empty,
    provider: providers.Provider = .modrinth,
    query: [513]u8 = @splat(0),
    submitted_query: [513]u8 = @splat(0),
    offset: u32 = 0,
    searched: bool = false,
    job: Job = .idle,
    proposal_current: bool = false,
    needs_prepare: bool = false,
    pending: ?Intent = null,
    confirm_open: bool = false,
    task_state: TaskState = .none,
    task_details: ?tasks_module.Details = null,
    failure: ?anyerror = null,
    changed: bool = false,
    picker: ?*picker_module.Service = null,
    picker_ticket: ?picker_module.Ticket = null,
    picker_path: ?[]const u8 = null,
    manual: std.ArrayList(install.ManualFile) = .empty,
    decisions: std.ArrayList(manifest.ConflictDecision) = .empty,

    pub fn init(a: A) Ui {
        return .{ .allocator = a, .context = .init(a), .catalog_arena = .init(a) };
    }
    pub fn discardPicker(self: *Ui) void {
        if (self.picker_ticket) |ticket| if (self.picker) |picker| picker.discard(ticket);
        self.picker_ticket = null;
        self.picker_path = null;
    }
    pub fn deinit(self: *Ui) void {
        self.discardPicker();
        if (self.icons) |*icons| icons.deinit();
        self.clearFrames();
        self.frames.deinit(self.allocator);
        self.context.deinit();
        self.catalog_arena.deinit();
        self.* = undefined;
    }
    fn clearFrames(self: *Ui) void {
        for (self.frames.items) |detail| detail.destroy(self.allocator);
        self.frames.clearRetainingCapacity();
    }
    pub fn reset(self: *Ui) void {
        const allocator = self.allocator;
        const picker = self.picker;
        const icons = self.icons;
        self.icons = null;
        self.deinit();
        self.* = init(allocator);
        self.picker = picker;
        self.icons = icons;
    }
    pub fn bind(self: *Ui, instance: config.Instance, kind: local.Kind) !void {
        if (self.instance) |current| if (kind == self.kind and std.mem.eql(u8, current.id, instance.id) and std.mem.eql(u8, current.name, instance.name) and std.mem.eql(u8, current.minecraft_version, instance.minecraft_version) and current.loader == instance.loader) return;
        self.reset();
        self.instance = try owned(config.Instance, self.context.allocator(), instance);
        self.kind = kind;
    }
    pub fn locked(self: *const Ui) bool {
        return self.confirm_open or self.task_state != .none or self.job == .install or self.job == .recover;
    }
    pub fn cancelPageLoads(self: *Ui, backend: *content.Manager) void {
        if (self.confirm_open or self.task_state != .none or self.job == .install or self.job == .recover) return;
        if (self.job != .idle) backend.cancelMetadata();
        self.job = .idle;
        self.proposal_current = false;
        self.needs_prepare = false;
        self.pending = null;
        self.failure = null;
    }
    pub fn frame(self: *const Ui) ?*Detail {
        return if (self.frames.items.len > 0) self.frames.items[self.frames.items.len - 1] else null;
    }
    pub fn currentProposal(self: *const Ui, snapshot: content.Snapshot) bool {
        const detail = self.frame() orelse return false;
        const version = detail.version() orelse return false;
        const proposal = snapshot.proposal orelse return false;
        const root = proposal.root orelse return false;
        return self.proposal_current and self.job == .idle and root.provider == version.provider and std.mem.eql(u8, root.id, version.id);
    }
    pub fn queue(self: *Ui, intent: Intent) void {
        if (intent == .back or intent == .cancel or self.pending == null) self.pending = intent;
    }
    pub fn open(self: *Ui) void {
        if (self.locked()) return;
        self.route = .catalog;
        self.failure = null;
        self.queue(.search);
    }
    pub fn contentKind(self: *const Ui) content.Kind {
        return switch (self.kind) {
            .mod => .mod,
            .resourcepack => .resourcepack,
            .shader => .shader,
        };
    }
    fn clearConfirm(self: *Ui) void {
        self.discardPicker();
        self.manual.clearRetainingCapacity();
        self.decisions.clearRetainingCapacity();
    }
    fn prepare(self: *Ui, backend: *content.Manager) !void {
        self.proposal_current = false;
        self.needs_prepare = false;
        const detail = self.frame() orelse return error.NoVersion;
        const version = detail.version() orelse return error.NoVersion;
        self.clearConfirm();
        _ = try detail.prepareChoices();
        try backend.prepareVersion(version, self.contentKind(), detail.choices.items);
        self.job = .prepare;
    }
    fn resolve(self: *Ui, backend: *content.Manager) !void {
        self.proposal_current = false;
        const detail = self.frame() orelse return error.NoVersion;
        try backend.resolve(detail.choices.items, self.decisions.items, self.manual.items, &.{});
        self.job = .resolve;
    }
    pub fn tick(self: *Ui, backend: *content.Manager, allowed: bool) void {
        if (self.icons == null) self.icons = @import("resource_icons.zig").Manager.init(self.allocator, backend.io);
        self.icons.?.poll(backend.options.transport_options);
        self.tickFallible(backend, allowed) catch |err| {
            self.failure = err;
            self.job = .idle;
        };
    }
    fn tickFallible(self: *Ui, backend: *content.Manager, allowed: bool) !void {
        if (self.needs_prepare and allowed and self.job == .idle and !backend.isBusy()) try self.prepare(backend);
        if (self.job == .install or self.job == .recover) {
            if (backend.active) |job| if (job.task) |task| {
                self.task_details = task.details();
            };
        }
        if (self.picker_ticket) |ticket| if (self.picker) |picker| if (picker.take(ticket)) |receipt| {
            var result = receipt;
            defer result.deinit();
            self.picker_ticket = null;
            if (result.failure) |err| return err;
            if (result.path) |source| {
                if (!allowed or !self.confirm_open or self.job != .idle) return error.ContentControlsLocked;
                const target = self.picker_path orelse return error.StaleContentSelection;
                const next: install.ManualFile = .{ .path = target, .source_absolute_path = try self.context.allocator().dupe(u8, source) };
                var found = false;
                for (self.manual.items) |*mapping| if (std.mem.eql(u8, mapping.path, target)) {
                    mapping.* = next;
                    found = true;
                    break;
                };
                if (!found) try self.manual.append(self.context.allocator(), next);
                self.picker_path = null;
                try self.resolve(backend);
            }
        };
        if (self.job == .idle or backend.isBusy()) return;
        const snapshot = backend.snapshot();
        const completed = self.job;
        self.job = .idle;
        if (snapshot.failure) |err| {
            self.failure = err;
            if (completed == .install or completed == .recover) self.task_state = if (err == error.Cancelled or err == error.Canceled) .canceled else .failed;
            return;
        }
        switch (completed) {
            .search => {
                _ = self.catalog_arena.reset(.free_all);
                self.catalog = &.{};
                self.catalog = try owned([]const providers.Project, self.catalog_arena.allocator(), snapshot.catalog);
                self.searched = true;
            },
            .versions => {
                const detail = self.frame() orelse return error.NoVersion;
                detail.versions = try owned([]const providers.Version, detail.arena.allocator(), snapshot.versions);
                detail.selected = 0;
                if (detail.versions.len > 0 and allowed) try self.prepare(backend);
            },
            .prepare, .resolve => {
                const detail = self.frame() orelse return error.NoVersion;
                _ = detail.results.reset(.free_all);
                detail.candidates = &.{};
                detail.issues = &.{};
                detail.candidates = try owned([]const providers.Version, detail.results.allocator(), snapshot.candidates);
                detail.issues = try owned([]const providers.DependencyIssue, detail.results.allocator(), snapshot.dependency_issues);
                if (allowed and try detail.prepareChoices()) try self.resolve(backend) else self.proposal_current = true;
            },
            .install, .recover => {
                if (snapshot.recovery_required) {
                    self.failure = error.RecoveryRequired;
                    self.task_state = .failed;
                } else if (snapshot.report != null and (snapshot.report.?.committed or snapshot.report.?.recovered)) {
                    self.task_state = .succeeded;
                    self.changed = true;
                } else {
                    self.failure = error.IncompleteContent;
                    self.task_state = .failed;
                }
            },
            .idle => {},
        }
    }
    pub fn finish(self: *Ui, backend: *content.Manager, allowed: bool, active: bool) void {
        const intent = self.pending orelse return;
        self.pending = null;
        if (!active or (!allowed and intent != .back and intent != .cancel)) {
            self.discardPicker();
            self.failure = error.ContentControlsLocked;
            return;
        }
        self.apply(backend, intent) catch |err| {
            self.failure = err;
        };
    }
    fn apply(self: *Ui, backend: *content.Manager, intent: Intent) !void {
        if (intent == .back) {
            if (self.confirm_open or self.task_state != .none or self.job == .install or self.job == .recover) return error.ContentControlsLocked;
            self.cancelPageLoads(backend);
            self.failure = null;
            if (self.route == .detail) {
                self.proposal_current = false;
                if (self.frames.items.len > 1) {
                    const child = self.frame().?;
                    const parent = self.frames.items[self.frames.items.len - 2];
                    if (child.version_changed) {
                        const dependency_index = child.parent_dependency_index orelse return error.InvalidDependency;
                        const selected_version = child.version() orelse return error.NoVersion;
                        const prior_choice = parent.choice(dependency_index);
                        try parent.setChoice(.{ .dependency_index = dependency_index, .version_id = selected_version.id, .include = if (prior_choice) |previous| previous.include else parent.version().?.dependencies[dependency_index].kind == .required });
                    }
                    for (child.choices.items) |choice| try parent.rememberChoice(choice);
                }
                if (self.frames.pop()) |detail| detail.destroy(self.allocator);
                self.clearConfirm();
                self.needs_prepare = self.frame() != null;
                if (!self.needs_prepare) self.route = .catalog;
            } else {
                self.route = .local;
                self.clearFrames();
            }
            return;
        }
        if (intent == .cancel) {
            backend.cancel();
            return;
        }
        if (intent == .view_local) {
            if (self.job != .idle or self.task_state != .succeeded or backend.snapshot().recovery_required) return error.ContentControlsLocked;
            self.confirm_open = false;
            self.task_state = .none;
            self.task_details = null;
            self.needs_prepare = false;
            self.clearConfirm();
            self.clearFrames();
            self.route = .local;
            return;
        }
        if (intent == .dismiss) {
            if (self.job != .idle or backend.snapshot().recovery_required) return error.ContentWorkerBusy;
            self.confirm_open = false;
            self.task_state = .none;
            self.task_details = null;
            self.needs_prepare = self.route == .detail and self.frame() != null;
            self.clearConfirm();
            self.failure = null;
            return;
        }
        if (backend.isBusy() or self.job != .idle) return error.ContentWorkerBusy;
        self.failure = null;
        switch (intent) {
            .search, .page => {
                if (self.route != .catalog) return error.StaleContentSelection;
                self.catalog_scroll = .{};
                if (intent == .search) {
                    self.offset = 0;
                    self.submitted_query = self.query;
                } else self.offset = intent.page;
                try backend.search(std.mem.trim(u8, std.mem.sliceTo(&self.submitted_query, 0), " \t\r\n"), self.contentKind(), self.offset);
                self.job = .search;
            },
            .provider => |provider| {
                try backend.selectProvider(provider);
                self.provider = provider;
                self.catalog = &.{};
                self.searched = false;
                self.offset = 0;
                self.pending = .search;
            },
            .retry => {
                const retrying_task = self.task_state == .failed or self.task_state == .canceled;
                self.task_state = .none;
                self.task_details = null;
                if (retrying_task) self.confirm_open = true;
                const detail = self.frame() orelse return error.NoVersion;
                if (detail.versions.len == 0) {
                    try backend.loadVersions(detail.project, self.contentKind());
                    self.job = .versions;
                } else try self.prepare(backend);
            },
            .project => |project| {
                if (self.route != .catalog or self.frames.items.len != 0) return error.StaleContentSelection;
                const detail = try Detail.create(self.allocator, project);
                errdefer detail.destroy(self.allocator);
                try self.frames.append(self.allocator, detail);
                errdefer _ = self.frames.pop();
                try backend.loadVersions(detail.project, self.contentKind());
                self.route = .detail;
                self.job = .versions;
            },
            .back => unreachable,
            .version => |index| {
                const detail = self.frame() orelse return error.NoVersion;
                if (index >= detail.versions.len) return error.InvalidChoice;
                detail.selected = index;
                detail.version_changed = true;
                detail.choices.clearRetainingCapacity();
                try self.prepare(backend);
            },
            .choice => |value| {
                self.proposal_current = false;
                try (self.frame() orelse return error.NoVersion).setChoice(value);
                try self.prepare(backend);
            },
            .dependency => |index| {
                const parent = self.frame() orelse return error.NoVersion;
                const root = parent.version() orelse return error.NoVersion;
                if (index >= root.dependencies.len or self.frames.items.len >= 8) return error.DependencyLimit;
                const dep = root.dependencies[index];
                const chosen = parent.choice(index);
                var versions: std.ArrayList(providers.Version) = .empty;
                defer versions.deinit(self.allocator);
                for (parent.candidates) |candidate| if (matchesDependency(candidate, root, dep)) try versions.append(self.allocator, candidate);
                if (versions.items.len == 0) return error.MissingDependencyVersion;
                const version = versions.items[0];
                const project: providers.Project = for (self.catalog) |known| {
                    if (known.provider == root.provider and std.mem.eql(u8, known.id, version.project_id)) break known;
                } else .{ .provider = root.provider, .id = version.project_id, .name = dependencyName(version), .official_page = if (root.provider == .modrinth) try std.fmt.allocPrint(parent.arena.allocator(), "https://modrinth.com/project/{s}", .{version.project_id}) else "" };
                const detail = try Detail.create(self.allocator, project);
                errdefer detail.destroy(self.allocator);
                detail.versions = try owned([]const providers.Version, detail.arena.allocator(), versions.items);
                detail.parent_dependency_index = index;
                detail.candidates = try owned([]const providers.Version, detail.results.allocator(), parent.candidates);
                for (parent.choices.items) |choice| try detail.rememberChoice(choice);
                const selected_id = if (chosen) |choice| choice.version_id orelse dep.version_id else dep.version_id;
                if (selected_id) |id| for (detail.versions, 0..) |candidate, i| if (std.mem.eql(u8, candidate.id, id)) {
                    detail.selected = i;
                    break;
                };
                try self.frames.append(self.allocator, detail);
                errdefer _ = self.frames.pop();
                try self.prepare(backend);
            },
            .confirm => {
                if (!self.currentProposal(backend.snapshot())) return error.NoProposal;
                self.confirm_open = true;
            },
            .commit => {
                if (!self.confirm_open or self.picker_ticket != null or !self.currentProposal(backend.snapshot())) return error.ContentControlsLocked;
                try backend.commit();
                self.proposal_current = false;
                self.confirm_open = false;
                self.task_state = .running;
                self.task_details = null;
                self.job = .install;
            },
            .choose_manual => |path| {
                if (!self.confirm_open) return error.ContentControlsLocked;
                if (!self.currentProposal(backend.snapshot())) return error.StaleContentSelection;
                const proposal = backend.snapshot().proposal orelse return error.NoProposal;
                var found = false;
                for (proposal.files) |file| if (std.mem.eql(u8, file.record.path, path) and file.download == .manual_required and file.selected != false) {
                    found = true;
                    break;
                };
                if (!found) return error.UnknownManualFile;
                const picker = self.picker orelse return error.FilePickerUnavailable;
                self.picker_path = try self.context.allocator().dupe(u8, path);
                self.picker_ticket = try picker.request(.{ .kind = .file, .title = "选择下载的资源文件", .extensions = if (std.mem.endsWith(u8, path, ".jar") or std.mem.endsWith(u8, path, ".jar.disabled")) "jar" else "zip" });
            },
            .conflict => |value| {
                if (!self.confirm_open or !self.currentProposal(backend.snapshot())) return error.StaleContentSelection;
                const next = try owned(manifest.ConflictDecision, self.context.allocator(), value);
                var found = false;
                for (self.decisions.items) |*decision| if (std.mem.eql(u8, decision.path, next.path)) {
                    decision.* = next;
                    found = true;
                    break;
                };
                if (!found) try self.decisions.append(self.context.allocator(), next);
                try self.resolve(backend);
            },
            .recover => |id| {
                try backend.recover(id);
                self.job = .recover;
                self.task_state = .running;
            },
            .cancel, .dismiss, .view_local => unreachable,
        }
    }
};
pub fn matchesDependency(candidate: providers.Version, root: providers.Version, dependency: providers.Dependency) bool {
    if (candidate.provider != root.provider) return false;
    if (dependency.project_id) |id| if (!std.mem.eql(u8, id, candidate.project_id)) return false;
    if (dependency.version_id) |id| if (!std.mem.eql(u8, id, candidate.id)) return false;
    return dependency.project_id != null or dependency.version_id != null;
}
pub fn dependencyName(version: providers.Version) []const u8 {
    // Providers expose version titles; project names are not guessed from opaque IDs.
    return version.name;
}
pub fn installed(snapshot: content.Snapshot, provider: providers.Provider, project_id: []const u8) ?manifest.ManagedFile {
    for (snapshot.installed) |file| if (file.provider == provider and file.identity_provenance == .official_file and std.mem.eql(u8, file.project_id, project_id)) return file;
    return null;
}

pub fn installedVersion(snapshot: content.Snapshot, file: manifest.ManagedFile, entries: []const local.Entry) ?[]const u8 {
    for ([_][]const providers.Version{ snapshot.versions, snapshot.candidates }) |versions| {
        for (versions) |version| {
            if (version.provider != file.provider or !std.mem.eql(u8, version.project_id, file.project_id) or !std.mem.eql(u8, version.id, file.version_id)) continue;
            const name = std.mem.trim(u8, version.name, " \t\r\n");
            if (name.len > 0 and !std.mem.eql(u8, name, file.version_id)) return name;
        }
    }
    for (entries) |*entry| {
        if (!std.mem.eql(u8, logicalPath(entry), file.path)) continue;
        if (entry.version) |version| {
            const name = std.mem.trim(u8, version, " \t\r\n");
            if (name.len > 0) return name;
        }
    }
    return null;
}

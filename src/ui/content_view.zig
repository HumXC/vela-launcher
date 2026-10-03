//! Snapshots are borrowed while drawing. Only finish mutates the manager.
const std = @import("std");
const dvui = @import("dvui");
const config = @import("../core/config.zig");
const providers = @import("../core/content_providers.zig");
const manifest = @import("../core/content_manifest.zig");
const install = @import("../core/content_install.zig");
const content = @import("content_manager.zig");
const theme = @import("theme.zig");
const A = std.mem.Allocator;
const R = dvui.Rect;
const warning = dvui.Color.fromHex("E5BA78");
const danger = dvui.Color.fromHex("F0A6A1");
const Page = enum { browse, managed, recovery };
const Action = enum { provider, search, versions, update_versions, prepare, update, import_pack, resolve, resolve_pack_references, commit, remove, enable, disable, refresh, recover, connections };

// Match the content core's arena-owned structured cloning convention.
fn clone(comptime T: type, a: A, value: T) !T {
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{ .emit_null_optional_fields = false });
    const parsed = try std.json.parseFromSlice(T, a, bytes, .{ .allocate = .alloc_always });
    return parsed.value;
}
fn text(buffer: []const u8) []const u8 {
    return std.mem.sliceTo(buffer, 0);
}
fn setText(buffer: []u8, value: []const u8) !void {
    if (value.len >= buffer.len) return error.PathTooLong;
    @memset(buffer, 0);
    @memcpy(buffer[0..value.len], value);
}
fn sameId(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |v| return if (b) |w| std.mem.eql(u8, v, w) else false;
    return b == null;
}
fn sameInstance(a: config.Instance, b: config.Instance) bool {
    return sameId(a.id, b.id) and sameId(a.name, b.name) and sameId(a.minecraft_version, b.minecraft_version) and a.loader == b.loader and sameId(a.loader_version, b.loader_version);
}
fn selected(doc: *const config.Document) ?config.Instance {
    const id = doc.selected_instance orelse return null;
    for (doc.instances) |instance| if (sameId(instance.id, id)) return instance;
    return null;
}
const Request = struct {
    arena: std.heap.ArenaAllocator,
    source: config.Instance,
    action: Action,
    kind: content.Kind = .mod,
    value: []const u8 = "",
    offset: u32 = 0,
    provider: providers.Provider = .modrinth,
    policy_generation: u64 = 0,
    project: ?providers.Project = null,
    legacy_identity: ?manifest.PackIdentity = null,
    legacy_approvals: []const manifest.LegacyApproval = &.{},
    version: ?providers.Version = null,
    choices: []const providers.DependencyChoice = &.{},
    decisions: []const manifest.ConflictDecision = &.{},
    manual: []const install.ManualFile = &.{},
    optional: []const content.OptionalChoice = &.{},
    connections: u16 = 8,
    identity: ?manifest.PackIdentity = null,
};
const ManualDraft = struct { path: []const u8, absolute: [4096]u8 = @splat(0) };
const Draft = struct {
    arena: std.heap.ArenaAllocator,
    source: config.Instance,
    proposal: content.Proposal,
    candidates: []const providers.Version,
    issues: []const providers.DependencyIssue,
    choices: std.ArrayList(providers.DependencyChoice) = .empty,
    decisions: std.ArrayList(manifest.ConflictDecision) = .empty,
    optional: std.ArrayList(content.OptionalChoice) = .empty,
    manual: []ManualDraft,
    open: bool = true,
    confirmed: bool = false,
    dirty: bool = false,

    fn init(a: A, snapshot: content.Snapshot) !Draft {
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const aa = arena.allocator();
        var proposal = snapshot.proposal.?.*;
        proposal.files = try clone([]const manifest.InstallFile, aa, proposal.files);
        proposal.manual_files = try clone([]const install.ManualFile, aa, proposal.manual_files);
        proposal.pack = try clone(?manifest.PackPlan, aa, proposal.pack);
        proposal.plan = try clone(manifest.UpdatePlan, aa, proposal.plan);
        proposal.stage_path = try clone(?[]const u8, aa, proposal.stage_path);
        proposal.root = try clone(?providers.VersionKey, aa, proposal.root);
        proposal.choices = try clone([]const providers.DependencyChoice, aa, proposal.choices);
        proposal.desired = try clone(?manifest.Manifest, aa, proposal.desired);
        proposal.legacy_identity = try clone(?manifest.PackIdentity, aa, proposal.legacy_identity);
        proposal.legacy_approvals = try clone([]const manifest.LegacyApproval, aa, proposal.legacy_approvals);
        var result: Draft = .{ .arena = arena, .source = try clone(config.Instance, aa, snapshot.instance.?), .proposal = proposal, .candidates = try clone([]const providers.Version, aa, snapshot.candidates), .issues = try clone([]const providers.DependencyIssue, aa, snapshot.dependency_issues), .manual = &.{} };
        try result.choices.appendSlice(aa, proposal.choices);
        var manual: std.ArrayList(ManualDraft) = .empty;
        for (proposal.files) |file| {
            if (!file.required) try result.optional.append(aa, .{ .path = file.record.path, .include = file.selected orelse false });
            if (file.download == .manual_required) {
                var item: ManualDraft = .{ .path = file.record.path };
                for (proposal.manual_files) |known| if (sameId(known.path, item.path)) {
                    try setText(&item.absolute, known.source_absolute_path);
                    break;
                };
                try manual.append(aa, item);
            }
        }
        result.manual = try manual.toOwnedSlice(aa);
        for (proposal.plan.conflicts) |conflict| if (conflict.choice) |choice| try result.decisions.append(aa, .{ .path = conflict.path, .choice = choice });
        result.arena = arena;
        return result;
    }
    fn choiceIndex(self: *const Draft, from: providers.VersionKey, di: usize) ?usize {
        for (self.choices.items, 0..) |choice, i| if (choice.from.provider == from.provider and sameId(choice.from.id, from.id) and choice.dependency_index == di) return i;
        return null;
    }
    fn putChoice(self: *Draft, choice: providers.DependencyChoice) !void {
        const value = try clone(providers.DependencyChoice, self.arena.allocator(), choice);
        if (self.choiceIndex(choice.from, choice.dependency_index)) |i| self.choices.items[i] = value else try self.choices.append(self.arena.allocator(), value);
        self.dirty = true;
        self.confirmed = false;
    }
    fn putDecision(self: *Draft, path: []const u8, choice: manifest.ConflictChoice) !void {
        for (self.decisions.items) |*decision| if (sameId(decision.path, path)) {
            decision.choice = choice;
            self.dirty = true;
            self.confirmed = false;
            return;
        };
        try self.decisions.append(self.arena.allocator(), .{ .path = try self.arena.allocator().dupe(u8, path), .choice = choice });
        self.dirty = true;
        self.confirmed = false;
    }
};

// Native dialogs are blocking and not thread-safe. Serialize this view's picker
// off the render thread; publish only an owned path and an atomic done flag.
const Picker = struct {
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    result: ?[:0]const u8 = null,
    failure: ?anyerror = null,
    manual_index: ?usize,
    instance_id: []const u8,
    draft_epoch: u64,
    fn run(self: *Picker) void {
        self.result = dvui.native_dialogs.Native.open(std.heap.page_allocator, .{ .title = if (self.manual_index == null) "Import modpack" else "Select verified source file", .filters = if (self.manual_index == null) &.{ "*.mrpack", "*.zip" } else null }) catch |err| blk: {
            self.failure = err;
            break :blk null;
        };
        self.done.store(true, .release);
    }
    fn destroy(self: *Picker) void {
        if (self.thread) |thread| thread.join();
        if (self.result) |path| std.heap.page_allocator.free(path);
        std.heap.page_allocator.free(self.instance_id);
        std.heap.page_allocator.destroy(self);
    }
};

pub const Ui = struct {
    allocator: A,
    failure: ?anyerror = null,
    kind: content.Kind = .mod,
    page: Page = .browse,
    query: [256]u8 = @splat(0),
    archive: [4096]u8 = @splat(0),
    connections: [6]u8 = .{ '8', 0, 0, 0, 0, 0 },
    offset: u32 = 0,
    provider: providers.Provider = .modrinth,
    policy_generation: u64 = 0,
    pending: ?Request = null,
    update_selection: ?Request = null,
    legacy_path: [1024]u8 = @splat(0),
    pending_select: ?[]u8 = null,
    select_queued: bool = false,
    cancel_queued: bool = false,
    draft: ?Draft = null,
    review_requested: bool = false,
    review_refresh: bool = false,
    picker: ?*Picker = null,
    picker_queued: bool = false,
    picker_manual: ?usize = null,
    archive_provider: providers.Provider = .modrinth,
    archive_project: [128]u8 = @splat(0),
    archive_version: [128]u8 = @splat(0),
    draft_epoch: u64 = 0,

    pub fn init(a: A) !Ui {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Ui) void {
        self.clearPending();
        self.closeDraft();
        self.clearUpdate();
        if (self.pending_select) |id| self.allocator.free(id);
        if (self.picker) |picker| picker.destroy();
        self.* = undefined;
    }
    fn clearPending(self: *Ui) void {
        if (self.pending) |*request| request.arena.deinit();
        self.pending = null;
    }
    fn clearUpdate(self: *Ui) void {
        if (self.update_selection) |*request| request.arena.deinit();
        self.update_selection = null;
        @memset(&self.legacy_path, 0);
    }
    fn rememberUpdate(self: *Ui, source: config.Instance, identity: manifest.PackIdentity, approval: ?manifest.LegacyApproval) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();
        var next: Request = .{
            .arena = arena,
            .source = try clone(config.Instance, aa, source),
            .action = .update,
            .kind = self.kind,
            .provider = self.provider,
            .policy_generation = self.policy_generation,
            .project = .{ .provider = identity.provider, .id = try aa.dupe(u8, identity.project_id), .name = try aa.dupe(u8, identity.project_id), .official_page = "" },
            .legacy_identity = if (approval != null) try clone(manifest.PackIdentity, aa, identity) else null,
            .legacy_approvals = if (approval) |value| try clone([]const manifest.LegacyApproval, aa, &.{value}) else &.{},
        };
        self.clearUpdate();
        next.arena = arena;
        self.update_selection = next;
    }
    fn refreshReview(self: *Ui, snapshot: content.Snapshot) !void {
        if (!self.review_refresh or snapshot.busy or snapshot.proposal == null or snapshot.instance == null) return;
        var next = try Draft.init(self.allocator, snapshot);
        errdefer next.arena.deinit();
        if (self.draft) |*old| {
            if (!sameInstance(old.source, next.source)) return error.SelectionChanged;
            for (old.choices.items) |choice| try next.putChoice(choice);
            for (old.decisions.items) |decision| try next.putDecision(decision.path, decision.choice);
            for (next.optional.items) |*item| for (old.optional.items) |known| if (sameId(item.path, known.path)) {
                item.include = known.include;
                break;
            };
            for (next.manual) |*item| for (old.manual) |known| if (sameId(item.path, known.path)) {
                item.absolute = known.absolute;
                break;
            };
            next.dirty = old.dirty;
        }
        self.closeDraft();
        self.draft = next;
    }
    fn closeDraft(self: *Ui) void {
        self.draft_epoch +%= 1;
        self.review_refresh = false;
        if (self.draft) |*draft| draft.arena.deinit();
        self.draft = null;
    }
    fn queueSelect(self: *Ui, id: ?[]const u8) !void {
        const owned = if (id) |value| try self.allocator.dupe(u8, value) else null;
        if (self.pending_select) |old| self.allocator.free(old);
        self.pending_select = owned;
        self.select_queued = true;
    }
    pub fn queueEnabled(self: *Ui, source: config.Instance, path: []const u8, enabled: bool) !void {
        try self.queue(source, if (enabled) .enable else .disable, path, null, null);
    }
    fn queue(self: *Ui, source: config.Instance, action: Action, value: []const u8, project: ?providers.Project, version: ?providers.Version) !void {
        if (self.pending != null) return error.CommandAlreadyQueued;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();
        var request: Request = .{ .arena = arena, .source = try clone(config.Instance, aa, source), .action = action, .kind = self.kind, .value = try aa.dupe(u8, value), .offset = self.offset, .provider = self.provider, .policy_generation = self.policy_generation, .project = if (project) |v| try clone(providers.Project, aa, v) else null, .version = if (version) |v| try clone(providers.Version, aa, v) else null };
        if (action == .connections) {
            request.connections = try parseConnections(value);
        }
        if (action == .resolve or action == .resolve_pack_references) {
            const draft = &(self.draft orelse return error.NoProposal);
            request.choices = try clone([]const providers.DependencyChoice, aa, draft.choices.items);
            request.decisions = try clone([]const manifest.ConflictDecision, aa, draft.decisions.items);
            request.optional = try clone([]const content.OptionalChoice, aa, draft.optional.items);
            var manual: std.ArrayList(install.ManualFile) = .empty;
            for (draft.manual) |item| {
                const path = std.mem.trim(u8, text(&item.absolute), " \t\r\n");
                if (path.len == 0) continue;
                try validateAbsolute(path);
                try manual.append(aa, .{ .path = try aa.dupe(u8, item.path), .source_absolute_path = try aa.dupe(u8, path) });
            }
            request.manual = try manual.toOwnedSlice(aa);
        }
        if (action == .update) {
            const selection = self.update_selection orelse return error.InvalidChoice;
            if (!sameInstance(selection.source, source) or version == null or selection.project.?.provider != version.?.provider or !std.mem.eql(u8, selection.project.?.id, version.?.project_id)) return error.InvalidChoice;
            request.legacy_identity = try clone(?manifest.PackIdentity, aa, selection.legacy_identity);
            request.legacy_approvals = try clone([]const manifest.LegacyApproval, aa, selection.legacy_approvals);
        }
        if (action == .import_pack) {
            const project_id = text(&self.archive_project);
            const version_id = text(&self.archive_version);
            if (!providers.validToken(project_id) or !providers.validToken(version_id)) return error.PackIdentityRequired;
            request.identity = .{ .provider = self.archive_provider, .project_id = try aa.dupe(u8, project_id), .version_id = try aa.dupe(u8, version_id) };
        }
        request.arena = arena;
        self.pending = request;
    }
    fn enqueue(self: *Ui, source: config.Instance, action: Action, value: []const u8) void {
        self.queue(source, action, value, null, null) catch |err| {
            self.failure = err;
        };
    }
};
fn parseConnections(value: []const u8) !u16 {
    const number = std.fmt.parseInt(u16, value, 10) catch return error.InvalidDownloadConnections;
    if (number == 0 or number > 64) return error.InvalidDownloadConnections;
    return number;
}
fn validateAbsolute(path: []const u8) !void {
    if (path.len == 0 or !std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.AbsolutePathRequired;
}
fn fmt(comptime pattern: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), pattern, args) catch "";
}
fn line(src: std.builtin.SourceLocation, value: []const u8, color: dvui.Color) void {
    const layout = dvui.textLayout(src, .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = .{ .h = 4 }, .color_text = .{ .color = color } });
    layout.addText(value, .{});
    layout.deinit();
}
fn button(src: std.builtin.SourceLocation, label: []const u8, enabled: bool) bool {
    var widget: dvui.ButtonWidget = undefined;
    widget.init(src, .{}, .{ .label = .{ .text = label }, .padding = R.all(6), .corners = .all(4), .color_text = .{ .color = if (enabled) theme.accent else theme.muted } });
    if (enabled) widget.processEvents();
    widget.drawBackground();
    dvui.labelNoFmt(src, label, .{}, widget.style().override(.{ .padding = R.all(0), .margin = R.all(0) }));
    widget.drawFocus();
    const clicked = enabled and widget.clicked();
    widget.deinit();
    return clicked;
}
fn icon(src: std.builtin.SourceLocation, label: []const u8, asset: []const u8, enabled: bool) bool {
    var widget: dvui.ButtonWidget = undefined;
    widget.init(src, .{}, .{ .label = .{ .text = label }, .min_size_content = .{ .w = 16, .h = 16 }, .max_size_content = .{ .w = 16, .h = 16 }, .padding = R.all(6), .corners = .all(4), .color_text = .{ .color = if (enabled) theme.accent else theme.muted } });
    if (enabled) widget.processEvents();
    widget.drawBackground();
    dvui.icon(src, label, asset, .{}, widget.style().override(.{ .padding = R.all(0), .margin = R.all(0), .role = .none }));
    widget.drawFocus();
    const clicked = enabled and widget.clicked();
    const hovered = widget.hovered();
    const rect = widget.data().rectScale().r;
    widget.deinit();
    if (hovered) dvui.tooltip(src, .{ .active_rect = rect }, "{s}", .{label}, .{ .id_extra = 1 });
    return clicked;
}
fn input(src: std.builtin.SourceLocation, label: []const u8, buffer: []u8) bool {
    const entry = dvui.textEntry(src, .{ .text = .{ .buffer = buffer } }, .{ .label = .{ .text = label }, .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(6), .corners = .all(4) });
    defer entry.deinit();
    return entry.text_changed;
}
fn row(src: std.builtin.SourceLocation, index: usize) *dvui.BoxWidget {
    return dvui.box(src, .{}, .{ .id_extra = index, .expand = .horizontal, .padding = .{ .y = 6, .h = 6 }, .border = .{ .h = 1 }, .margin = R.all(0) });
}

pub fn draw(ui: *Ui, doc: *const config.Document, manager: *content.Manager) !void {
    const snapshot = manager.snapshot();
    if (ui.policy_generation != snapshot.policy_generation or ui.provider != snapshot.provider) {
        ui.clearPending();
        ui.closeDraft();
        ui.review_requested = false;
        ui.clearUpdate();
        ui.offset = 0;
        ui.policy_generation = snapshot.policy_generation;
        ui.provider = snapshot.provider;
    }
    const root = dvui.box(@src(), .{}, .{ .expand = .both, .padding = R.all(0), .margin = R.all(0) });
    defer root.deinit();
    const labels = try dvui.currentWindow().arena().alloc([]const u8, doc.instances.len + 1);
    labels[0] = "Select instance";
    var choice: ?usize = 0;
    for (doc.instances, 0..) |instance, i| {
        labels[i + 1] = instance.name;
        if (sameId(doc.selected_instance, instance.id)) choice = i + 1;
    }
    if (snapshot.recovery_required) {
        line(@src(), "Recovery required; content instance is locked", danger);
        ui.page = .recovery;
    } else if (dvui.dropdown(@src(), labels, .{ .choice_nullable = &choice }, .{ .null_selectable = false }, .{ .label = .{ .text = "Content instance" }, .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(6), .corners = .all(4) })) {
        const i = choice orelse 0;
        try ui.queueSelect(if (i == 0) null else doc.instances[i - 1].id);
    }
    const failure: ?anyerror = if (ui.failure) |err| err else snapshot.failure;
    if (failure) |err| line(@src(), fmt("Content operation failed: {s}", .{@errorName(err)}), danger);
    if (snapshot.report) |report| {
        line(@src(), if (report.recovered) "Transaction recovered" else if (report.complete and report.committed and report.fully_applied) "Installation complete" else if (report.committed) "Transaction committed; installation incomplete" else "Transaction not committed", if (report.recovered or (report.complete and report.committed and report.fully_applied)) theme.accent else warning);
        line(@src(), fmt("Applied: {d}   Kept local: {d}   Backup: {s}", .{ report.applied_files, report.kept_local, report.backup_directory }), theme.muted);
    }
    const source = snapshot.instance orelse {
        line(@src(), "No content instance selected", theme.muted);
        return;
    };
    const desired = selected(doc);
    const current = if (desired) |value| sameInstance(value, source) else false;
    const enabled = current and !snapshot.recovery_required and !snapshot.busy and !ui.select_queued and ui.pending == null and ui.draft == null and !ui.review_requested;
    line(@src(), fmt("{s}   Minecraft {s}   {s}", .{ source.name, source.minecraft_version, @tagName(source.loader) }), theme.muted);
    if (!current) line(@src(), "Instance selection changed", warning);
    if (snapshot.busy) {
        if (snapshot.progress) |progress| {
            if (progress.total) |total| line(@src(), fmt("{s}: {d} / {d}", .{ @tagName(progress.stage), progress.completed, total }), theme.muted) else line(@src(), fmt("{s}: {d}", .{ @tagName(progress.stage), progress.completed }), theme.muted);
        } else line(@src(), "Content task running", theme.muted);
    }
    {
        const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = R.all(0) });
        defer actions.deinit();
        const page_labels = [_][]const u8{ "Browse", "Managed", "Recovery" };
        for (page_labels, 0..) |label, i| if (dvui.button(@src(), label, .{}, .{ .id_extra = i, .color_text = .{ .color = if (@intFromEnum(ui.page) == i) theme.accent else theme.muted }, .corners = .all(4) })) {
            ui.page = @enumFromInt(i);
        };
        if (icon(@src(), "Refresh content", dvui.entypo.cw, enabled)) ui.enqueue(source, .refresh, "");
        if (icon(@src(), "Cancel content task", dvui.entypo.cross, snapshot.busy and !snapshot.recovery_required)) ui.cancel_queued = true;
    }
    if (current and !snapshot.recovery_required) try ui.refreshReview(snapshot);
    if (ui.review_requested and ui.draft == null and snapshot.proposal != null and current and !snapshot.busy and !snapshot.recovery_required) {
        ui.draft = try Draft.init(ui.allocator, snapshot);
        ui.review_requested = false;
    }
    const scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .expand = .both, .padding = R.all(0), .margin = R.all(0) });
    defer scroll.deinit();
    switch (if (snapshot.recovery_required) Page.recovery else ui.page) {
        .browse => try drawBrowse(ui, source, snapshot, enabled),
        .managed => {
            if (snapshot.installed.len == 0) line(@src(), "No managed content", theme.muted);
            if (snapshot.pack_membership) |membership| {
                line(@src(), fmt("{s}  {s}  {s}", .{ @tagName(membership.identity.provider), membership.identity.project_id, membership.identity.version_id }), theme.accent);
                if (icon(@src(), "Review modpack updates", dvui.entypo.cw, enabled and (membership.identity.provider == .modrinth or snapshot.curseforge_available))) {
                    ui.kind = .modpack;
                    ui.rememberUpdate(source, membership.identity, null) catch |err| {
                        ui.failure = err;
                        return;
                    };
                    ui.queue(source, .update_versions, "", ui.update_selection.?.project, null) catch |err| {
                        ui.failure = err;
                    };
                }
            }
            for (snapshot.installed, 0..) |file, i| {
                const item = row(@src(), i);
                defer item.deinit();
                line(@src(), file.path, theme.accent);
                if (manifest.toggleable(file)) {
                    line(@src(), if (file.enabled) "Enabled" else "Disabled (.jar.disabled)", if (file.enabled) theme.accent else warning);
                    if (button(@src(), if (file.enabled) "Review disabling mod" else "Review enabling mod", enabled)) {
                        ui.queueEnabled(source, file.path, !file.enabled) catch |err| {
                            ui.failure = err;
                        };
                    }
                }
                line(@src(), fmt("{s}   {s}   {s}", .{ @tagName(file.provider), file.project_id, file.version_id }), theme.muted);
                line(@src(), @tagName(file.identity_provenance), theme.muted);
                var legacy_approved = std.mem.eql(u8, text(&ui.legacy_path), file.path);
                if (file.identity_provenance == .legacy_unknown and dvui.checkbox(@src(), &legacy_approved, "Approve this legacy file for replacement", .{})) {
                    setText(&ui.legacy_path, if (legacy_approved) file.path else "") catch |err| {
                        ui.failure = err;
                    };
                }
                const updateable = file.identity_provenance == .official_file or (file.identity_provenance == .legacy_unknown and legacy_approved);
                if (icon(@src(), "Review file updates", dvui.entypo.cw, enabled and updateable and (file.provider == .modrinth or snapshot.curseforge_available))) {
                    ui.kind = if (std.mem.startsWith(u8, file.path, "resourcepacks/")) .resourcepack else if (std.mem.startsWith(u8, file.path, "shaderpacks/")) .shader else .mod;
                    const identity: manifest.PackIdentity = .{ .provider = file.provider, .project_id = file.project_id, .version_id = file.version_id };
                    const approval: ?manifest.LegacyApproval = if (file.identity_provenance == .legacy_unknown) .{ .path = file.path, .expected_hashes = file.hashes, .expected_size = file.size } else null;
                    ui.rememberUpdate(source, identity, approval) catch |err| {
                        ui.failure = err;
                        return;
                    };
                    ui.queue(source, .update_versions, "", ui.update_selection.?.project, null) catch |err| {
                        ui.failure = err;
                    };
                }
                if (button(@src(), "Review removal", enabled and file.identity_provenance != .pack_archive and file.identity_provenance != .pack_override)) ui.enqueue(source, .remove, file.path);
            }
        },
        .recovery => {
            if (snapshot.transactions.len == 0) line(@src(), "No pending transactions", theme.muted);
            for (snapshot.transactions, 0..) |id, i| {
                const item = row(@src(), i);
                defer item.deinit();
                line(@src(), id, warning);
                if (button(@src(), "Recover transaction", if (snapshot.recovery_required) !snapshot.busy and ui.pending == null else enabled)) ui.enqueue(source, .recover, id);
            }
        },
    }
}
fn drawBrowse(ui: *Ui, source: config.Instance, snapshot: content.Snapshot, enabled: bool) !void {
    line(@src(), fmt("{s}: {s}", .{ if (snapshot.provider == .curseforge) "CurseForge" else "Modrinth", @tagName(ui.kind) }), theme.accent);
    var provider_choice: ?usize = if (snapshot.provider == .curseforge) 1 else 0;
    const names: []const []const u8 = if (snapshot.curseforge_available) &.{ "Modrinth", "CurseForge" } else &.{"Modrinth"};
    if (dvui.dropdown(@src(), names, .{ .choice_nullable = &provider_choice }, .{ .null_selectable = false }, .{ .label = .{ .text = "Provider" }, .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(6), .corners = .all(4) }) and enabled) {
        ui.enqueue(source, .provider, if (provider_choice == 1) "curseforge" else "modrinth");
    }
    {
        const tabs = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = R.all(0) });
        defer tabs.deinit();
        const kinds = [_]content.Kind{ .mod, .resourcepack, .shader, .modpack };
        const labels = [_][]const u8{ "Mods", "Resource packs", "Shaders", "Modpacks" };
        if (dvui.windowRect().w < 520) {
            var kind_choice: ?usize = @intFromEnum(ui.kind);
            if (dvui.dropdown(@src(), &labels, .{ .choice_nullable = &kind_choice }, .{ .null_selectable = false }, .{ .label = .{ .text = "Content type" }, .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(6), .corners = .all(4) }) and enabled) {
                ui.kind = kinds[kind_choice orelse 0];
                ui.offset = 0;
                ui.enqueue(source, .search, text(&ui.query));
            }
        } else {
            for (kinds, labels) |kind, label| if (button(@src(), label, enabled)) {
                ui.kind = kind;
                ui.offset = 0;
                ui.enqueue(source, .search, text(&ui.query));
            };
        }
    }
    _ = input(@src(), "Search", &ui.query);
    if (button(@src(), "Search", enabled)) {
        ui.offset = 0;
        ui.enqueue(source, .search, text(&ui.query));
    }
    {
        const pages = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = R.all(0) });
        defer pages.deinit();
        if (icon(@src(), "Previous results", dvui.entypo.chevron_left, enabled and ui.offset > 0)) {
            ui.offset -|= 20;
            ui.enqueue(source, .search, text(&ui.query));
        }
        dvui.label(@src(), "Offset {d}", .{ui.offset}, .{});
        if (icon(@src(), "Next results", dvui.entypo.chevron_right, enabled and snapshot.catalog.len > 0 and ui.offset <= std.math.maxInt(u32) - 20)) {
            ui.offset += 20;
            ui.enqueue(source, .search, text(&ui.query));
        }
    }
    for (snapshot.catalog, 0..) |project, i| {
        const item = row(@src(), i);
        defer item.deinit();
        line(@src(), project.name, theme.accent);
        line(@src(), project.summary, theme.muted);
        if (button(@src(), "Versions", enabled and (project.provider == .modrinth or snapshot.curseforge_available))) ui.queue(source, .versions, "", project, null) catch |err| {
            ui.failure = err;
        };
    }
    for (snapshot.versions, 0..) |version, i| {
        const item = row(@src(), i + snapshot.catalog.len);
        defer item.deinit();
        line(@src(), fmt("{s}   {s}", .{ version.name, version.id }), theme.accent);
        line(@src(), fmt("Files: {d}   Dependencies: {d}", .{ version.files.len, version.dependencies.len }), theme.muted);
        const updating = if (ui.update_selection) |selection| selection.project.?.provider == version.provider and std.mem.eql(u8, selection.project.?.id, version.project_id) else false;
        if (button(@src(), if (updating) "Review update" else "Prepare version", enabled)) ui.queue(source, if (updating) .update else .prepare, "", null, version) catch |err| {
            ui.failure = err;
        };
    }
    line(@src(), "Archive import", theme.accent);
    _ = input(@src(), "Absolute .mrpack or CurseForge .zip path", &ui.archive);
    var archive_source: ?usize = if (ui.archive_provider == .modrinth) 0 else 1;
    if (dvui.dropdown(@src(), &.{ "Modrinth archive", "CurseForge archive" }, .{ .choice_nullable = &archive_source }, .{ .null_selectable = false }, .{ .label = .{ .text = "Archive source" }, .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(6), .corners = .all(4) })) ui.archive_provider = if ((archive_source orelse 0) == 0) .modrinth else .curseforge;
    _ = input(@src(), "Official project ID", &ui.archive_project);
    _ = input(@src(), "Official version or file ID", &ui.archive_version);
    if (icon(@src(), "Choose archive", dvui.entypo.folder, enabled and dvui.useTinyFileDialogs and ui.picker == null)) {
        ui.picker_queued = true;
        ui.picker_manual = null;
    }
    if (button(@src(), "Import archive", enabled)) ui.enqueue(source, .import_pack, text(&ui.archive));
    line(@src(), "Download connections", theme.muted);
    _ = input(@src(), "Download connections (1-64)", &ui.connections);
    if (button(@src(), "Apply connections", enabled)) ui.enqueue(source, .connections, text(&ui.connections));
}

fn matchesDependency(candidate: providers.Version, parent: providers.Version, dep: providers.Dependency, source: config.Instance) bool {
    if (candidate.provider != parent.provider) return false;
    if (dep.project_id) |id| if (!sameId(candidate.project_id, id)) return false;
    if (dep.version_id) |id| if (!sameId(candidate.id, id)) return false;
    if (dep.project_id == null and dep.version_id == null) return false;
    return providers.compatible(candidate, .{ .minecraft_version = source.minecraft_version, .loader = source.loader });
}
fn activeCandidates(draft: *const Draft, a: A) ![]bool {
    const active = try a.alloc(bool, draft.candidates.len);
    @memset(active, false);
    const root = draft.proposal.root orelse return active;
    for (draft.candidates, 0..) |version, i| if (version.provider == root.provider and sameId(version.id, root.id)) {
        active[i] = true;
    };
    var changed = true;
    while (changed) {
        changed = false;
        for (draft.candidates, 0..) |version, vi| {
            if (!active[vi]) continue;
            for (version.dependencies, 0..) |dep, di| {
                if (dep.kind != .required and dep.kind != .optional) continue;
                const ci = draft.choiceIndex(.{ .provider = version.provider, .id = version.id }, di);
                if (dep.kind == .optional and (ci == null or !draft.choices.items[ci.?].include)) continue;
                const id = (if (ci) |i| draft.choices.items[i].version_id else dep.version_id) orelse continue;
                for (draft.candidates, 0..) |candidate, i| if (!active[i] and candidate.provider == version.provider and sameId(candidate.id, id) and matchesDependency(candidate, version, dep, draft.source)) {
                    active[i] = true;
                    changed = true;
                };
            }
        }
    }
    return active;
}
fn drawDependencies(draft: *Draft) !bool {
    const active = try activeCandidates(draft, dvui.currentWindow().arena());
    var required_ready = true;
    for (draft.candidates, 0..) |version, vi| {
        if (!active[vi]) continue;
        for (version.dependencies, 0..) |dep, di| {
            if (dep.kind != .required and dep.kind != .optional) continue;
            const item = row(@src(), vi * providers.max_items + di);
            defer item.deinit();
            line(@src(), fmt("{s}: {s} ({s})", .{ version.name, dep.project_id orelse dep.version_id orelse dep.file_name orelse "Unknown dependency", @tagName(dep.kind) }), theme.muted);
            const from: providers.VersionKey = .{ .provider = version.provider, .id = version.id };
            const ci = draft.choiceIndex(from, di);
            var include = if (ci) |index| draft.choices.items[index].include else dep.kind == .required;
            if (dep.kind == .optional and dvui.checkbox(@src(), &include, "Include optional dependency", .{})) try draft.putChoice(.{ .from = from, .dependency_index = di, .include = include, .version_id = if (ci) |index| draft.choices.items[index].version_id else null });
            if (dep.kind == .required and (ci == null or !draft.choices.items[ci.?].include or draft.choices.items[ci.?].version_id == null)) required_ready = false;
            if (!include) continue;
            const aa = dvui.currentWindow().arena();
            var labels: std.ArrayList([]const u8) = .empty;
            var ids: std.ArrayList(?[]const u8) = .empty;
            try labels.append(aa, "Choose dependency version");
            try ids.append(aa, null);
            var selection: ?usize = 0;
            for (draft.candidates) |candidate| if (matchesDependency(candidate, version, dep, draft.source)) {
                try labels.append(aa, fmt("{s} ({s})", .{ candidate.name, candidate.id }));
                try ids.append(aa, candidate.id);
                if (ci) |index| if (sameId(draft.choices.items[index].version_id, candidate.id)) {
                    selection = ids.items.len - 1;
                };
            };
            if (dvui.dropdown(@src(), labels.items, .{ .choice_nullable = &selection }, .{ .null_selectable = false }, .{ .label = .{ .text = "Dependency version" }, .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(6), .corners = .all(4) })) {
                try draft.putChoice(.{ .from = from, .dependency_index = di, .include = true, .version_id = ids.items[selection orelse 0] });
            }
            if (ids.items.len == 1) line(@src(), "No compatible candidate metadata available", warning);
        }
    }
    for (draft.issues) |issue| {
        if (issue.from_index >= draft.candidates.len) {
            line(@src(), "Invalid dependency candidate index", danger);
            continue;
        }
        const version = draft.candidates[issue.from_index];
        line(@src(), fmt("{s}: {s} (dependency {d})", .{ version.name, @tagName(issue.kind), issue.dependency_index }), warning);
    }
    return required_ready;
}

pub fn drawModal(ui: *Ui, doc: *const config.Document, manager: *content.Manager) !void {
    if (ui.draft == null) return;
    const draft = &ui.draft.?;
    const snapshot = manager.snapshot();
    if (snapshot.recovery_required) return;
    const source = selected(doc);
    const current = if (source) |instance| sameInstance(instance, draft.source) and (if (snapshot.instance) |instance_now| sameInstance(instance_now, draft.source) else false) else false;
    const enabled = current and !snapshot.busy and !ui.select_queued and ui.pending == null;
    const window = dvui.windowRect();
    const width = @max(0, @min(680, window.w - 24));
    const height = @max(0, @min(640, window.h - 24));
    {
        const modal = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &draft.open, .resize = .none, .window_avoid = .none }, .{ .rect = .{ .x = window.x + (window.w - width) / 2, .y = window.y + (window.h - height) / 2, .w = width, .h = height }, .padding = R.all(12), .corners = .all(8), .label = .{ .text = "Content review" } });
        defer modal.deinit();
        modal.dragAreaSet(dvui.windowHeader("Content review", "", &draft.open));
        const scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .expand = .both, .padding = R.all(0) });
        defer scroll.deinit();
        line(@src(), fmt("{s}   {s}", .{ draft.source.name, draft.source.minecraft_version }), theme.accent);
        if (!current) line(@src(), "Instance selection changed; review is locked", warning);
        if (ui.failure) |err| line(@src(), @errorName(err), danger);
        const required_choices_ready = try drawDependencies(draft);
        if (draft.proposal.pack) |pack| {
            line(@src(), fmt("{s}   {s}", .{ pack.name, pack.version }), theme.accent);
            for (pack.unresolved, 0..) |ref, i| {
                const item = row(@src(), i);
                defer item.deinit();
                line(@src(), fmt("Missing CurseForge metadata: project {s}, file {s}", .{ ref.project_id, ref.file_id }), warning);
                if (!manager.canResolvePackReferences()) line(@src(), "CurseForge transport disabled", warning);
            }
            if (pack.unresolved.len != 0 and icon(@src(), "Resolve CurseForge file metadata", dvui.entypo.cw, enabled and manager.canResolvePackReferences())) ui.enqueue(draft.source, .resolve_pack_references, "");
            if (!draft.proposal.prerequisites.loader_ready) line(@src(), "Required Minecraft loader is not ready", warning);
            if (!draft.proposal.prerequisites.overrides_processed) line(@src(), "Archive overrides not processed", warning);
        }
        for (draft.optional.items, 0..) |*optional, i| if (dvui.checkbox(@src(), &optional.include, optional.path, .{ .id_extra = i })) {
            draft.dirty = true;
            draft.confirmed = false;
        };
        for (draft.manual, 0..) |*manual, i| {
            const item = row(@src(), i);
            defer item.deinit();
            line(@src(), manual.path, theme.accent);
            for (draft.proposal.files) |file| if (sameId(file.record.path, manual.path) and file.download == .manual_required) {
                const required = file.download.manual_required;
                line(@src(), @tagName(required.reason), warning);
                dvui.link(@src(), .{ .label = "Official download page", .url = required.official_page }, .{});
                break;
            };
            if (input(@src(), "Absolute local file path", &manual.absolute)) {
                draft.dirty = true;
                draft.confirmed = false;
            }
            if (icon(@src(), "Choose local file", dvui.entypo.folder, enabled and dvui.useTinyFileDialogs and ui.picker == null)) {
                ui.picker_queued = true;
                ui.picker_manual = i;
            }
        }
        for (draft.proposal.plan.conflicts, 0..) |conflict, i| {
            const item = row(@src(), i);
            defer item.deinit();
            line(@src(), fmt("{s}   {s}", .{ conflict.path, @tagName(conflict.reason) }), warning);
            var choice: ?usize = 0;
            for (draft.decisions.items) |decision| if (sameId(decision.path, conflict.path)) {
                choice = if (decision.choice == .keep_local) 1 else 2;
                break;
            };
            if (dvui.dropdown(@src(), &.{ "Choose conflict action", "Keep local", "Replace (back up local)" }, .{ .choice_nullable = &choice }, .{ .null_selectable = false }, .{ .label = .{ .text = "Conflict action" }, .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(6), .corners = .all(4) })) {
                if ((choice orelse 0) > 0) try draft.putDecision(conflict.path, if (choice.? == 1) .keep_local else .replace);
            }
        }
        for (draft.proposal.plan.actions, 0..) |action, i| line(@src(), fmt("{d}. {s}   {s}", .{ i + 1, @tagName(action.kind), action.path }), theme.muted);
        for (draft.proposal.plan.actions) |action| if (action.kind == .toggle) {
            line(@src(), "Local override: changing an installed mod's state can break dependencies or startup. No other mods will change state automatically.", warning);
            break;
        };
        if (draft.proposal.blocker) |err| {
            line(@src(), @errorName(err), warning);
            if (err == error.DisabledIdentityUnresolved) line(@src(), "A disabled pack file could not be matched. Close this review, enable the old file, retry the pack update, then disable the new file you choose.", warning);
            if (err == error.DisabledRequiredDependency) line(@src(), "A required dependency is disabled. Close this review, enable that dependency explicitly, then retry.", warning);
        }
        line(@src(), fmt("Dependencies ready: {s}   Missing manual files: {d}", .{ if (draft.proposal.dependencies_ready) "yes" else "no", draft.proposal.missing_manual }), if (draft.proposal.ready) theme.accent else warning);
        if (!draft.proposal.plan.fully_applied) line(@src(), "Kept-local overrides leave the requested installation incomplete", warning);
        if (button(@src(), "Recompute review", enabled)) ui.enqueue(draft.source, .resolve, "");
        _ = dvui.checkbox(@src(), &draft.confirmed, "Confirm reviewed file changes", .{});
        if (!required_choices_ready) line(@src(), "Required dependency version choices are incomplete", warning);
        if (button(@src(), "Commit transaction", enabled and draft.confirmed and !draft.dirty and draft.proposal.ready and required_choices_ready)) ui.enqueue(draft.source, .commit, "");
        if (button(@src(), "Close", true)) draft.open = false;
    }
    if (!draft.open) ui.closeDraft();
}

fn collectPicker(ui: *Ui, doc: *const config.Document) void {
    const picker = ui.picker orelse return;
    if (!picker.done.load(.acquire)) return;
    defer {
        picker.destroy();
        ui.picker = null;
    }
    if (picker.failure) |err| {
        ui.failure = err;
        return;
    }
    if (!sameId(picker.instance_id, doc.selected_instance)) {
        ui.failure = error.SelectionChanged;
        return;
    }
    const path = picker.result orelse return;
    if (picker.manual_index) |i| {
        if (ui.draft) |*draft| {
            if (picker.draft_epoch != ui.draft_epoch or !sameId(draft.source.id, picker.instance_id) or i >= draft.manual.len) {
                ui.failure = error.SelectionChanged;
                return;
            }
            setText(&draft.manual[i].absolute, path) catch |err| {
                ui.failure = err;
                return;
            };
            draft.dirty = true;
            draft.confirmed = false;
        }
    } else setText(&ui.archive, path) catch |err| {
        ui.failure = err;
    };
}
fn startPicker(ui: *Ui, doc: *const config.Document) !void {
    if (!dvui.useTinyFileDialogs) return error.NativeFileDialogUnavailable;
    if (ui.picker != null) return error.Busy;
    const instance = selected(doc) orelse return error.InstanceNotFound;
    const a = std.heap.page_allocator;
    const picker = try a.create(Picker);
    errdefer a.destroy(picker);
    const id = try a.dupe(u8, instance.id);
    errdefer a.free(id);
    picker.* = .{ .manual_index = ui.picker_manual, .instance_id = id, .draft_epoch = ui.draft_epoch };
    picker.thread = try std.Thread.spawn(.{}, Picker.run, .{picker});
    ui.picker = picker;
}
fn apply(request: *const Request, manager: *content.Manager) !void {
    const snapshot = manager.snapshot();
    if (request.policy_generation != snapshot.policy_generation or request.provider != snapshot.provider) return error.ContentPolicyChanged;
    switch (request.action) {
        .provider => try manager.selectProvider(if (std.mem.eql(u8, request.value, "curseforge")) .curseforge else .modrinth),
        .update_versions => {
            try manager.selectProvider(request.project.?.provider);
            try manager.loadVersions(request.project.?, request.kind);
        },
        .update => if (request.legacy_identity) |identity|
            try manager.prepareLegacyUpdate(identity, request.legacy_approvals, request.version.?.id, request.kind)
        else
            try manager.prepareUpdate(request.version.?.provider, request.version.?.project_id, request.version.?.id, request.kind),
        .search => try manager.search(request.value, request.kind, request.offset),
        .versions => try manager.loadVersions(request.project.?, request.kind),
        .prepare => try manager.prepareVersion(request.version.?, request.kind, request.choices),
        .import_pack => {
            try validateAbsolute(request.value);
            if (!std.mem.endsWith(u8, request.value, ".mrpack") and !std.mem.endsWith(u8, request.value, ".zip")) return error.UnsupportedPackArchive;
            try manager.importPackFor(request.value, request.identity orelse return error.PackIdentityRequired);
        },
        .resolve => try manager.resolve(request.choices, request.decisions, request.manual, request.optional),
        .resolve_pack_references => try manager.resolvePackReferences(request.choices, request.decisions, request.manual, request.optional),
        .commit => try manager.commit(),
        .remove => try manager.prepareRemove(request.value),
        .enable => try manager.prepareEnabled(request.value, true),
        .disable => try manager.prepareEnabled(request.value, false),
        .refresh => try manager.refresh(),
        .recover => try manager.recover(request.value),
        .connections => try manager.setDownloadConnections(request.connections),
    }
}

/// Call AFTER all root and modal widgets close. Never retain borrowed snapshots.
pub fn finish(ui: *Ui, store: *config.Store, manager: *content.Manager) void {
    defer ui.clearPending();
    const pinned = manager.snapshot();
    if (pinned.recovery_required) {
        ui.cancel_queued = false;
        ui.select_queued = false;
        if (ui.pending_select) |id| ui.allocator.free(id);
        ui.pending_select = null;
        ui.picker_queued = false;
        ui.closeDraft();
        ui.review_requested = false;
        collectPicker(ui, store.snapshot());
        const request = if (ui.pending) |*value| value else return;
        if (request.action != .recover) {
            ui.failure = error.RecoveryRequired;
            return;
        }
        const instance = pinned.instance orelse {
            ui.failure = error.InstanceNotFound;
            return;
        };
        if (!sameInstance(instance, request.source)) {
            ui.failure = error.SelectionChanged;
            return;
        }
        apply(request, manager) catch |err| {
            ui.failure = err;
            return;
        };
        ui.failure = null;
        return;
    }
    if (ui.cancel_queued) {
        ui.cancel_queued = false;
        manager.cancel();
    }
    if (ui.select_queued) {
        ui.select_queued = false;
        defer {
            if (ui.pending_select) |id| ui.allocator.free(id);
            ui.pending_select = null;
        }
        var document = store.snapshot().*;
        document.selected_instance = ui.pending_select;
        if (ui.pending_select != null and selected(&document) == null) {
            ui.failure = error.InstanceNotFound;
            return;
        }
        store.update(document) catch |err| {
            ui.failure = err;
            return;
        };
    }
    const desired = selected(store.snapshot());
    const current = manager.snapshot().instance;
    const changed = if (desired) |instance| (if (current) |value| !sameInstance(instance, value) else true) else current != null;
    if (changed) {
        ui.closeDraft();
        ui.review_requested = false;
        manager.select(desired) catch |err| {
            ui.failure = err;
            return;
        };
    }
    collectPicker(ui, store.snapshot());
    if (ui.picker_queued) {
        ui.picker_queued = false;
        startPicker(ui, store.snapshot()) catch |err| {
            ui.failure = err;
        };
    }
    const request = if (ui.pending) |*value| value else return;
    const instance = desired orelse {
        ui.failure = error.SelectionChanged;
        return;
    };
    if (!sameInstance(instance, request.source) or changed) {
        ui.failure = error.SelectionChanged;
        return;
    }
    const manager_instance = manager.snapshot().instance orelse {
        ui.failure = error.SelectionChanged;
        return;
    };
    if (!sameInstance(instance, manager_instance)) {
        ui.failure = error.SelectionChanged;
        return;
    }
    apply(request, manager) catch |err| {
        ui.failure = err;
        return;
    };
    ui.failure = null;
    if (request.action == .update_versions) {
        ui.page = .browse;
        ui.provider = manager.snapshot().provider;
        ui.policy_generation = manager.snapshot().policy_generation;
    }
    switch (request.action) {
        .prepare, .update, .import_pack, .remove, .enable, .disable, .resolve => {
            ui.closeDraft();
            ui.review_requested = true;
        },
        .resolve_pack_references => {
            if (ui.draft) |*draft| {
                draft.dirty = false;
                draft.confirmed = false;
            }
            ui.review_refresh = true;
        },
        .commit => {
            ui.closeDraft();
            ui.review_requested = false;
        },
        else => {},
    }
}

test "content UI owns queued query and stable instance id" {
    const a = std.testing.allocator;
    var ui = try Ui.init(a);
    defer ui.deinit();
    var query = [_]u8{ 'a', 'b' };
    const instance: config.Instance = .{ .id = "stable-id", .name = "Display", .minecraft_version = "1.21" };
    try ui.queue(instance, .search, &query, null, null);
    query[0] = 'z';
    try std.testing.expectEqualStrings("ab", ui.pending.?.value);
    try std.testing.expectEqualStrings("stable-id", ui.pending.?.source.id);
    try ui.queueSelect("stable-id");
    try std.testing.expectEqualStrings("stable-id", ui.pending_select.?);
}
test "content UI rejects relative sources and invalid connection counts" {
    try std.testing.expectError(error.AbsolutePathRequired, validateAbsolute("relative.mrpack"));
    try validateAbsolute("/tmp/user-selected.mrpack");
    try std.testing.expectError(error.InvalidDownloadConnections, parseConnections("0"));
    try std.testing.expectError(error.InvalidDownloadConnections, parseConnections("65"));
    try std.testing.expectEqual(@as(u16, 8), try parseConnections("8"));
}
test "content selection follows ids rather than display names" {
    const doc: config.Document = .{ .selected_instance = "second", .instances = &.{ .{ .id = "first", .name = "Same", .minecraft_version = "1.21" }, .{ .id = "second", .name = "Same", .minecraft_version = "1.21" } } };
    try std.testing.expectEqualStrings("second", selected(&doc).?.id);
}

test "content review owns manual paths choices and blockers" {
    const a = std.testing.allocator;
    var path = [_]u8{ 'm', 'o', 'd', 's', '/', 'a', '.', 'j', 'a', 'r' };
    const file: manifest.InstallFile = .{ .record = .{ .path = &path, .provider = .modrinth, .project_id = "project", .version_id = "version", .hashes = .{} }, .download = .{ .manual_required = .{ .official_page = "https://modrinth.com/mod/project", .reason = .missing_url } } };
    const proposal: content.Proposal = .{ .files = &.{file}, .plan = .{ .actions = &.{}, .conflicts = &.{}, .next_manifest = .{ .instance_id = "stable", .pack_version = "version" }, .ready = false, .fully_applied = false }, .blocker = error.LoaderPrerequisiteUnsupported };
    const snapshot: content.Snapshot = .{ .instance = .{ .id = "stable", .name = "Instance", .minecraft_version = "1.21" }, .proposal = &proposal };
    var ui = try Ui.init(a);
    defer ui.deinit();
    ui.draft = try Draft.init(a, snapshot);
    path[5] = 'z';
    try std.testing.expectEqualStrings("mods/a.jar", ui.draft.?.manual[0].path);
    try std.testing.expectEqual(error.LoaderPrerequisiteUnsupported, ui.draft.?.proposal.blocker.?);
    try setText(&ui.draft.?.manual[0].absolute, "/tmp/source.jar");
    try ui.draft.?.putChoice(.{ .from = .{ .provider = .modrinth, .id = "root" }, .dependency_index = 0, .include = true, .version_id = "dependency" });
    try ui.queue(ui.draft.?.source, .resolve, "", null, null);
    ui.closeDraft();
    try std.testing.expectEqualStrings("/tmp/source.jar", ui.pending.?.manual[0].source_absolute_path);
    try std.testing.expectEqualStrings("dependency", ui.pending.?.choices[0].version_id.?);
}

test "content archive requests require explicit owned source identity" {
    const a = std.testing.allocator;
    var ui = try Ui.init(a);
    defer ui.deinit();
    const instance: config.Instance = .{ .id = "stable", .name = "Instance", .minecraft_version = "1.21" };
    try std.testing.expectError(error.PackIdentityRequired, ui.queue(instance, .import_pack, "/tmp/pack.mrpack", null, null));
    try setText(&ui.archive_project, "project");
    try setText(&ui.archive_version, "version");
    try ui.queue(instance, .import_pack, "/tmp/pack.mrpack", null, null);
    try setText(&ui.archive_project, "changed");
    try std.testing.expectEqualStrings("project", ui.pending.?.identity.?.project_id);
}

test "content metadata review refresh preserves live paths choices optional and conflict decisions" {
    const a = std.testing.allocator;
    const old_file: manifest.InstallFile = .{ .record = .{ .path = "mods/a.jar", .provider = .curseforge, .project_id = "12", .version_id = "34", .hashes = .{} }, .download = .{ .manual_required = .{ .official_page = "https://www.curseforge.com/minecraft/mc-mods/example/files/34", .reason = .missing_url } }, .required = false, .selected = false };
    var added = old_file;
    added.record.path = "mods/new.jar";
    added.record.project_id = "42";
    added.record.version_id = "43";
    added.required = true;
    added.selected = true;
    const proposal: content.Proposal = .{ .files = &.{old_file}, .plan = .{ .actions = &.{}, .conflicts = &.{}, .next_manifest = .{ .instance_id = "stable", .pack_version = "v1" }, .ready = false, .fully_applied = false } };
    var updated = proposal;
    updated.files = &.{ old_file, added };
    const snapshot: content.Snapshot = .{ .instance = .{ .id = "stable", .name = "Instance", .minecraft_version = "1.20.1" }, .proposal = &proposal };
    var ui = try Ui.init(a);
    defer ui.deinit();
    ui.draft = try Draft.init(a, snapshot);
    ui.review_refresh = true;
    ui.draft.?.optional.items[0].include = true;
    try setText(&ui.draft.?.manual[0].absolute, "/tmp/changed-while-busy.jar");
    try ui.draft.?.putChoice(.{ .from = .{ .provider = .curseforge, .id = "34" }, .dependency_index = 0, .include = true, .version_id = "43" });
    try ui.draft.?.putDecision("mods/a.jar", .keep_local);
    var next = snapshot;
    next.proposal = &updated;
    next.busy = true;
    try ui.refreshReview(next);
    try std.testing.expect(ui.review_refresh and ui.draft.?.manual.len == 1);
    next.busy = false;
    try ui.refreshReview(next);
    try std.testing.expect(!ui.review_refresh and ui.draft.?.dirty and !ui.draft.?.confirmed);
    try std.testing.expectEqual(@as(usize, 2), ui.draft.?.manual.len);
    try std.testing.expectEqualStrings("/tmp/changed-while-busy.jar", text(&ui.draft.?.manual[0].absolute));
    try std.testing.expectEqualStrings("", text(&ui.draft.?.manual[1].absolute));
    try std.testing.expect(ui.draft.?.optional.items[0].include);
    try std.testing.expectEqualStrings("43", ui.draft.?.choices.items[0].version_id.?);
    try std.testing.expectEqual(manifest.ConflictChoice.keep_local, ui.draft.?.decisions.items[0].choice);
    try ui.queue(ui.draft.?.source, .resolve_pack_references, "", null, null);
    ui.closeDraft();
    try std.testing.expectEqual(Action.resolve_pack_references, ui.pending.?.action);
    try std.testing.expectEqualStrings("/tmp/changed-while-busy.jar", ui.pending.?.manual[0].source_absolute_path);
    try std.testing.expect(ui.pending.?.optional[0].include);
    try std.testing.expectEqual(manifest.ConflictChoice.keep_local, ui.pending.?.decisions[0].choice);
}

test "content failed or canceled metadata refresh retains the existing review" {
    const a = std.testing.allocator;
    const file: manifest.InstallFile = .{ .record = .{ .path = "mods/a.jar", .provider = .curseforge, .project_id = "12", .version_id = "34", .hashes = .{} }, .download = .{ .manual_required = .{ .official_page = "https://www.curseforge.com/minecraft/mc-mods/example/files/34", .reason = .missing_url } } };
    const proposal: content.Proposal = .{ .files = &.{file}, .plan = .{ .actions = &.{}, .conflicts = &.{}, .next_manifest = .{ .instance_id = "stable", .pack_version = "v1" }, .ready = false, .fully_applied = false } };
    const snapshot: content.Snapshot = .{ .instance = .{ .id = "stable", .name = "Instance", .minecraft_version = "1.20.1" }, .proposal = &proposal };
    var ui = try Ui.init(a);
    defer ui.deinit();
    ui.draft = try Draft.init(a, snapshot);
    try setText(&ui.draft.?.manual[0].absolute, "/tmp/local.jar");
    for ([_]anyerror{ error.Canceled, error.ProjectMismatch }) |failure| {
        ui.review_refresh = true;
        var failed = snapshot;
        failed.failure = failure;
        try ui.refreshReview(failed);
        try std.testing.expect(ui.draft != null);
        try std.testing.expectEqualStrings("mods/a.jar", ui.draft.?.manual[0].path);
        try std.testing.expectEqualStrings("/tmp/local.jar", text(&ui.draft.?.manual[0].absolute));
    }
}

test "content deferred commands reject stale provider and policy generation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const instances = @import("../core/instances.zig");
    const tasks = @import("../core/tasks.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    const FakeLease = struct {
        fn acquire(_: ?*anyopaque, _: []const u8) anyerror!void {
            return error.UnexpectedLease;
        }
        fn release(_: ?*anyopaque, _: []const u8) void {
            unreachable;
        }
    };
    var manager = try content.Manager.initOptions(a, io, &paths, &registry, .{ .lease = .{ .context = null, .acquire = FakeLease.acquire, .recheck = FakeLease.acquire, .release = FakeLease.release }, .curseforge = .{ .enabled = true, .terms_approved = true, .credential_ref = "0123456789abcdef0123456789abcdef".* }, .transport_options = .{ .allow_curseforge = true } });
    defer manager.deinit();
    var ui = try Ui.init(a);
    defer ui.deinit();
    const source: config.Instance = .{ .id = "stable", .name = "Instance", .minecraft_version = "1.20.1" };
    try setText(&ui.connections, "16");
    try ui.queue(source, .connections, text(&ui.connections), null, null);
    try apply(&ui.pending.?, &manager);
    try std.testing.expectEqual(@as(u16, 16), manager.connections);
    try manager.selectProvider(.curseforge);
    try std.testing.expectError(error.ContentPolicyChanged, apply(&ui.pending.?, &manager));
    ui.pending.?.policy_generation = manager.snapshot().policy_generation;
    try std.testing.expectError(error.ContentPolicyChanged, apply(&ui.pending.?, &manager));
    ui.pending.?.provider = .curseforge;
    try manager.setCurseForgePolicy(.{});
    try std.testing.expectError(error.ContentPolicyChanged, apply(&ui.pending.?, &manager));
    try std.testing.expectEqual(@as(u16, 16), manager.connections);
    try std.testing.expect(!manager.snapshot().curseforge_available);
}

test "content update selection owns legacy proof and preserves old exact tuple" {
    const a = std.testing.allocator;
    var ui = try Ui.init(a);
    defer ui.deinit();
    ui.kind = .resourcepack;
    ui.provider = .curseforge;
    ui.policy_generation = 7;
    const source: config.Instance = .{ .id = "stable", .name = "Instance", .minecraft_version = "1.20.1" };
    var path = "mods/legacy.jar".*;
    var old_version = "34".*;
    var hash = ("a" ** 40).*;
    try ui.rememberUpdate(source, .{ .provider = .curseforge, .project_id = "12", .version_id = &old_version }, .{ .path = &path, .expected_hashes = .{ .sha1 = &hash }, .expected_size = 3 });
    path[0] = 'X';
    old_version[0] = '9';
    hash[0] = 'b';
    const next: providers.Version = .{ .provider = .curseforge, .project_id = "12", .id = "44", .name = "Next", .minecraft_versions = &.{"1.20.1"}, .loaders = &.{"minecraft"}, .files = &.{}, .dependencies = &.{} };
    try ui.queue(source, .update, "", null, next);
    ui.clearUpdate();
    const request = &ui.pending.?;
    try std.testing.expectEqual(@as(u64, 7), request.policy_generation);
    try std.testing.expectEqualStrings("44", request.version.?.id);
    try std.testing.expectEqualStrings("34", request.legacy_identity.?.version_id);
    try std.testing.expectEqualStrings("mods/legacy.jar", request.legacy_approvals[0].path);
    try std.testing.expectEqualStrings("a" ** 40, request.legacy_approvals[0].expected_hashes.sha1.?);
    try std.testing.expectEqual(@as(?u64, 3), request.legacy_approvals[0].expected_size);
}

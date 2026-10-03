//! Local archive preview and target UI. App must JOIN Controller before deinit:
//! a running preparation may still read this UI's private preview archive.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const config = @import("../core/config.zig");
const paths_mod = @import("../core/instances.zig");
const packs = @import("../core/pack_import.zig");
const manifest = @import("../core/content_manifest.zig");
const metadata = @import("../core/minecraft/metadata/root.zig");
const pack_controller = @import("pack_import_controller.zig");
const instances_view = @import("instances_view.zig");
const theme = @import("theme.zig");
const A = std.mem.Allocator;
const Io = std.Io;
const R = dvui.Rect;

pub const OwnedAction = enum { close, cancel, reconcile, retry_adoption };
const DrainBinding = struct {
    epoch: u64,
    generation: u64,
    serial: u64,
    role: ?pack_controller.JavaRole,
    phase: pack_controller.Phase,
    pinned: bool,
};
pub const Runner = struct {
    context: ?*anyopaque = null,
    pick: *const fn (?*anyopaque, A) anyerror!?[:0]const u8 = nativePick,
    inspect: *const fn (?*anyopaque, A, Io, *const paths_mod.Paths, []const u8, ?*const packs.CancelToken) anyerror!packs.Inspection = inspectArchive,
    cleanup: *const fn (?*anyopaque, Io, *const packs.Inspection) anyerror!void = cleanupArchive,
    owned_snapshot: *const fn (?*anyopaque, *const pack_controller.Controller) pack_controller.Snapshot = ownedSnapshot,
    drain: *const fn (?*anyopaque, OwnedAction, *config.Store, *pack_controller.Controller, pack_controller.Services) anyerror!void = drainOwned,
};
pub const Options = struct {
    runner: Runner = .{},
    fixture_picker_spawn_failure: ?anyerror = null,
    fixture_cleanup_spawn_failure: ?anyerror = null,
    fixture_inspect_spawn_failure: ?anyerror = null,
};
fn ownedSnapshot(_: ?*anyopaque, controller: *const pack_controller.Controller) pack_controller.Snapshot {
    return controller.snapshot();
}
fn drainOwned(_: ?*anyopaque, action: OwnedAction, store: *config.Store, controller: *pack_controller.Controller, services: pack_controller.Services) !void {
    switch (action) {
        .cancel => controller.cancel(services),
        .retry_adoption => try controller.retryAdoption(services),
        .reconcile => {
            if (!controller.ownsInstancesPublication()) return error.NoOwnedPublicationUncertainty;
            if (services.store != store or !equal(store.root, services.instances.root) or
                !equal(store.root, services.content.paths.root) or !equal(store.root, services.java_download.root)) return error.ConfigurationChanged;
            try store.reconcile();
            try controller.acknowledgeReconciled(services);
        },
        .close => unreachable,
    }
}
fn nativePick(_: ?*anyopaque, a: A) !?[:0]const u8 {
    return dvui.native_dialogs.Native.open(a, .{ .title = "Import modpack", .filters = &.{ "*.mrpack", "*.zip" } });
}
fn inspectArchive(_: ?*anyopaque, a: A, io: Io, paths: *const paths_mod.Paths, path: []const u8, cancel: ?*const packs.CancelToken) !packs.Inspection {
    return packs.inspect(a, io, paths, path, cancel);
}
fn cleanupArchive(_: ?*anyopaque, io: Io, inspection: *const packs.Inspection) !void {
    try inspection.cleanup(io);
}
fn validPath(path: []const u8) bool {
    return path.len != 0 and path.len <= 4096 and std.fs.path.isAbsolute(path) and
        std.mem.indexOfScalar(u8, path, 0) == null and std.unicode.utf8ValidateSlice(path);
}
fn text(buffer: []const u8) []const u8 {
    return buffer[0 .. std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len];
}
fn setText(buffer: []u8, value: []const u8) !void {
    if (value.len >= buffer.len or std.mem.indexOfScalar(u8, value, 0) != null or !std.unicode.utf8ValidateSlice(value)) return error.InvalidText;
    @memset(buffer, 0);
    @memcpy(buffer[0..value.len], value);
}
fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn optionalEqual(a: ?[]const u8, b: ?[]const u8) bool {
    return if (a) |v| if (b) |w| equal(v, w) else false else b == null;
}
pub fn sameRow(a: config.Instance, b: config.Instance) bool {
    return equal(a.id, b.id) and equal(a.name, b.name) and equal(a.minecraft_version, b.minecraft_version) and
        a.loader == b.loader and optionalEqual(a.loader_version, b.loader_version) and optionalEqual(a.java_path, b.java_path) and
        a.max_memory_mb == b.max_memory_mb and a.debug_launch == b.debug_launch and
        (if (a.origin) |v| if (b.origin) |w| v.kind == w.kind and equal(v.project_id, w.project_id) and equal(v.version_id, w.version_id) else false else b.origin == null);
}
pub fn matchesPack(row: config.Instance, pack: manifest.PackPlan) bool {
    return equal(row.minecraft_version, pack.minecraft_version) and row.loader == pack.loader and optionalEqual(row.loader_version, pack.loader_version);
}
fn clone(comptime T: type, a: A, value: T) anyerror!T {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var result: T = undefined;
            inline for (info.fields) |field| @field(result, field.name) = try clone(field.type, a, @field(value, field.name));
            return result;
        },
        .optional => |info| return if (value) |v| try clone(info.child, a, v) else null,
        .pointer => |info| {
            if (info.size != .slice) return value;
            const out = try a.alloc(info.child, value.len);
            for (value, out) |v, *dest| dest.* = try clone(info.child, a, v);
            return out;
        },
        else => return value,
    }
}
const OwnedRow = struct {
    arena: std.heap.ArenaAllocator,
    value: config.Instance,
    fn init(a: A, row: config.Instance) !OwnedRow {
        var arena: std.heap.ArenaAllocator = .init(a);
        errdefer arena.deinit();
        const value = try clone(config.Instance, arena.allocator(), row);
        return .{ .arena = arena, .value = value };
    }
    fn deinit(self: *OwnedRow) void {
        self.arena.deinit();
    }
};
const Picker = struct {
    a: A,
    runner: Runner,
    epoch: u64,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    path: ?[:0]const u8 = null,
    failure: ?anyerror = null,
    fn run(self: *Picker) void {
        const owned_path = self.runner.pick(self.runner.context, self.a) catch |err| blk: {
            self.failure = err;
            break :blk null;
        };
        self.path = owned_path;
        self.done.store(true, .release);
    }
    fn destroy(self: *Picker) void {
        if (self.thread) |thread| thread.join();
        if (self.path) |path| self.a.free(path);
        self.a.destroy(self);
    }
};
const Preview = struct {
    a: A,
    io: Io,
    options: Options,
    root: []u8,
    source: []u8,
    epoch: u64,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    cancellation: packs.CancelToken = .init(false),
    failure: ?anyerror = null,
    inspection: ?packs.Inspection = null,
    cleanup_thread: ?std.Thread = null,
    cleanup_mutex: Io.Mutex = .init,
    cleanup_condition: Io.Condition = .init,
    cleanup_requested: bool = false,
    cleanup_done: std.atomic.Value(bool) = .init(false),
    cleanup_failure: ?anyerror = null,
    cleanup_stage: [8193]u8 = @splat(0),
    draft: instances_view.Draft = .{},
    fn create(a: A, io: Io, root: []const u8, source: []const u8, epoch: u64, options: Options) !*Preview {
        const self = try a.create(Preview);
        errdefer a.destroy(self);
        const owned_root = try a.dupe(u8, root);
        errdefer a.free(owned_root);
        const owned_source = try a.dupe(u8, source);
        errdefer a.free(owned_source);
        self.* = .{ .a = a, .io = io, .root = owned_root, .source = owned_source, .epoch = epoch, .options = options };
        // Reserve the cleanup worker before inspection can create a private stage.
        if (options.fixture_cleanup_spawn_failure) |err| return err;
        const cleanup_thread = try std.Thread.spawn(.{}, cleanupWorker, .{self});
        self.cleanup_thread = cleanup_thread;
        errdefer {
            self.requestCleanup();
            self.cleanup_thread.?.join();
            self.cleanup_thread = null;
        }
        if (options.fixture_inspect_spawn_failure) |err| return err;
        const thread = try std.Thread.spawn(.{}, run, .{self});
        self.thread = thread;
        return self;
    }
    fn run(self: *Preview) void {
        self.perform() catch |err| {
            self.failure = err;
        };
        self.done.store(true, .release);
    }
    fn perform(self: *Preview) !void {
        var paths = try paths_mod.Paths.init(self.a, self.io, self.root);
        defer paths.deinit();
        const owned_inspection = try self.options.runner.inspect(self.options.runner.context, self.a, self.io, &paths, self.source, &self.cancellation);
        self.inspection = owned_inspection;
        const inspection = &self.inspection.?;
        try setText(&self.cleanup_stage, inspection.stage_absolute_path);
        if (!validPath(inspection.archive_absolute_path)) return error.InvalidPrivateArchivePath;
        if (self.cancellation.load(.acquire)) return error.Canceled;
        const owned_draft = try makeDraft(self.a, self.io, inspection.pack);
        self.draft = owned_draft;
    }
    fn joinReady(self: *Preview) bool {
        if (self.thread == null) return true;
        if (!self.done.load(.acquire)) return false;
        self.thread.?.join();
        self.thread = null;
        return true;
    }
    fn requestCleanup(self: *Preview) void {
        std.debug.assert(self.thread == null);
        self.cleanup_mutex.lockUncancelable(self.io);
        defer self.cleanup_mutex.unlock(self.io);
        self.cleanup_requested = true;
        self.cleanup_condition.broadcast(self.io);
    }
    fn cleanupWorker(self: *Preview) void {
        self.cleanup_mutex.lockUncancelable(self.io);
        while (!self.cleanup_requested) self.cleanup_condition.waitUncancelable(self.io, &self.cleanup_mutex);
        self.cleanup_mutex.unlock(self.io);
        if (self.inspection) |*inspection| {
            self.options.runner.cleanup(self.options.runner.context, self.io, inspection) catch |err| {
                self.cleanup_failure = err;
            };
            inspection.deinit();
            self.inspection = null;
        }
        self.cleanup_done.store(true, .release);
    }
    fn destroy(self: *Preview) void {
        std.debug.assert(self.thread == null and self.cleanup_thread == null and self.inspection == null);
        self.a.free(self.source);
        self.a.free(self.root);
        self.draft.deinit(self.a);
        self.a.destroy(self);
    }
};
const Command = union(enum) {
    browse,
    inspect: []u8,
    choose_new,
    choose_existing: OwnedRow,
    confirm,
    close,
    cancel,
    retry_adoption,
    reconcile,
    fn deinit(self: *Command, a: A) void {
        switch (self.*) {
            .inspect => |path| a.free(path),
            .choose_existing => |*row| row.deinit(),
            else => {},
        }
    }
};

pub const Ui = struct {
    allocator: A,
    io: Io,
    root: []u8,
    options: Options,
    modal_open: bool = false,
    archive: [4097]u8 = @splat(0),
    draft: instances_view.Draft = .{},
    existing: ?OwnedRow = null,
    picker: ?*Picker = null,
    preview: ?*Preview = null,
    pending: ?Command = null,
    epoch: u64 = 0,
    generation: u64 = 0,
    pinned: bool = false,
    owner_controller: ?*pack_controller.Controller = null,
    owner_services: ?pack_controller.Services = null,
    pending_drain: ?DrainBinding = null,
    stopping: bool = false,
    review_requested: bool = false,
    failure: ?anyerror = null,
    cleanup_failure: ?anyerror = null,
    cleanup_stage: [8193]u8 = @splat(0),

    pub fn init(a: A, io: Io, root: []const u8) !Ui {
        return initOptions(a, io, root, .{});
    }
    pub fn initOptions(a: A, io: Io, root: []const u8, options: Options) !Ui {
        if (!validPath(root)) return error.UnsafeDataRoot;
        const owned_root = try a.dupe(u8, root);
        return .{ .allocator = a, .io = io, .root = owned_root, .options = options };
    }
    /// Controller must be canceled and JOINed first; it may still read preview.
    pub fn deinit(self: *Ui) void {
        if (self.pending) |*command| command.deinit(self.allocator);
        if (self.picker) |picker| picker.destroy();
        if (self.preview) |preview| {
            preview.cancellation.store(true, .release);
            if (preview.thread) |thread| {
                thread.join();
                preview.thread = null;
            }
            if (!preview.cleanup_requested) preview.requestCleanup();
            if (preview.cleanup_thread) |thread| {
                thread.join();
                preview.cleanup_thread = null;
            }
            if (preview.cleanup_failure) |err| std.log.err("Pack preview cleanup failed: {s}; stage: {s}", .{ @errorName(err), text(&preview.cleanup_stage) });
            preview.destroy();
        }
        if (self.existing) |*row| row.deinit();
        self.draft.deinit(self.allocator);
        self.allocator.free(self.root);
        self.* = undefined;
    }
    pub fn isBusy(self: *const Ui) bool {
        if (self.pinned or self.picker != null) return true;
        if (self.preview) |preview| return preview.thread != null or preview.cleanup_requested;
        return false;
    }
    /// App cancels Controller first. Native.open has no interruption API; its
    /// Picker remains busy until its own result is returned and JOINed.
    pub fn cancel(self: *Ui) void {
        self.stopping = true;
        self.modal_open = false;
        self.review_requested = false;
        if (self.pending) |*command| command.deinit(self.allocator);
        self.pending = null;
        if (self.picker) |picker| picker.epoch = 0;
        self.pending_drain = null;
        if (!self.pinned) self.releasePreview();
    }
    fn collectPicker(self: *Ui, admit: bool) void {
        const picker = self.picker orelse return;
        if (!picker.done.load(.acquire)) return;
        picker.thread.?.join();
        picker.thread = null;
        self.picker = null;
        defer picker.destroy();
        if (admit and picker.epoch == self.epoch and self.modal_open and !self.pinned) {
            if (picker.failure) |err| self.failure = err else if (picker.path) |path| self.beginPreview(path) catch |err| {
                self.failure = err;
            };
        }
    }
    pub fn takeReviewRequest(self: *Ui) bool {
        const requested = self.review_requested;
        self.review_requested = false;
        return requested;
    }
    fn queue(self: *Ui, command: Command) void {
        if (self.stopping or self.pending != null) {
            var rejected = command;
            rejected.deinit(self.allocator);
            return;
        }
        self.pending_drain = null;
        self.pending = command;
    }
    pub fn queueOwned(self: *Ui, action: OwnedAction, controller: *pack_controller.Controller) !void {
        if (self.pending != null) return error.PendingCommand;
        if (self.stopping and action != .cancel and action != .close) return error.UiStopping;
        if (self.pinned and self.owner_controller != controller) return error.StalePreparationGeneration;
        const snapshot = self.options.runner.owned_snapshot(self.options.runner.context, controller);
        self.pending_drain = .{ .epoch = self.epoch, .generation = self.generation, .serial = snapshot.serial, .role = snapshot.role, .phase = snapshot.phase, .pinned = self.pinned };
        self.pending = switch (action) {
            .close => .close,
            .cancel => .cancel,
            .reconcile => .reconcile,
            .retry_adoption => .retry_adoption,
        };
    }
    pub fn queueArchive(self: *Ui, path: []const u8) !void {
        if (self.stopping) return error.UiStopping;
        if (!validPath(path)) return error.ArchivePathNotAbsolute;
        if (self.pending != null) return error.PendingCommand;
        const owned_path = try self.allocator.dupe(u8, path);
        self.pending = .{ .inspect = owned_path };
    }
    pub fn queueExisting(self: *Ui, row: config.Instance) !void {
        if (self.stopping) return error.UiStopping;
        if (self.pending != null) return error.PendingCommand;
        const owned_row = try OwnedRow.init(self.allocator, row);
        self.pending = .{ .choose_existing = owned_row };
    }
    fn nextEpoch(self: *Ui) !void {
        if (self.epoch == std.math.maxInt(u64)) return error.IdExhausted;
        self.epoch += 1;
    }
    fn beginPreview(self: *Ui, source: []const u8) !void {
        if (self.isBusy() or self.preview != null) return error.Busy;
        if (self.cleanup_failure != null) return error.PreviewCleanupRequired;
        if (!validPath(source)) return error.ArchivePathNotAbsolute;
        try self.nextEpoch();
        try setText(&self.archive, source);
        self.failure = null;
        const preview = try Preview.create(self.allocator, self.io, self.root, source, self.epoch, self.options);
        if (self.existing) |*row| row.deinit();
        self.existing = null;
        self.draft.deinit(self.allocator);
        self.draft = .{};
        self.preview = preview;
    }
    fn beginPicker(self: *Ui) !void {
        if (self.isBusy() or self.preview != null) return error.Busy;
        if (self.cleanup_failure != null) return error.PreviewCleanupRequired;
        try self.nextEpoch();
        const picker = try self.allocator.create(Picker);
        errdefer self.allocator.destroy(picker);
        picker.* = .{ .a = self.allocator, .runner = self.options.runner, .epoch = self.epoch };
        if (self.options.fixture_picker_spawn_failure) |err| return err;
        const thread = try std.Thread.spawn(.{}, Picker.run, .{picker});
        picker.thread = thread;
        self.picker = picker;
        self.failure = null;
    }
    fn releasePreview(self: *Ui) void {
        if (self.preview) |preview| {
            preview.cancellation.store(true, .release);
            if (preview.thread == null and !preview.cleanup_requested) preview.requestCleanup();
        }
    }
    pub fn tick(self: *Ui, controller: *const pack_controller.Controller) void {
        const snapshot = controller.snapshot();
        if (self.pinned and snapshot.preparation_generation == self.generation) {
            if (snapshot.archive_sha256 != null) self.releasePreview();
            switch (snapshot.phase) {
                .review_required => {
                    self.pinned = false;
                    self.modal_open = false;
                    self.review_requested = !self.stopping;
                    self.releasePreview();
                },
                .failed, .canceled => {
                    self.pinned = false;
                    self.failure = snapshot.failure;
                    self.releasePreview();
                },
                else => {},
            }
        } else if (self.pinned and snapshot.preparation_generation != self.generation) {
            // A newer admitted request implies the previous private worker JOINed.
            self.pinned = false;
            self.failure = error.PreparationGenerationChanged;
            self.releasePreview();
        }
        if (self.preview) |preview| {
            if (!preview.joinReady()) return;
            if (!self.pinned and !preview.cleanup_requested and (preview.failure != null or preview.epoch != self.epoch or !self.modal_open)) {
                if (preview.failure) |err| self.failure = err;
                preview.requestCleanup();
            } else if (!preview.cleanup_requested and self.draft.base == null) {
                self.draft = preview.draft;
                preview.draft = .{};
            }
            if (preview.cleanup_requested and preview.cleanup_done.load(.acquire)) {
                preview.cleanup_thread.?.join();
                preview.cleanup_thread = null;
                if (preview.cleanup_failure) |err| {
                    self.cleanup_failure = err;
                    self.cleanup_stage = preview.cleanup_stage;
                }
                preview.destroy();
                self.preview = null;
            }
        }
    }
    fn confirm(self: *Ui, store: *config.Store, controller: *pack_controller.Controller, services: pack_controller.Services) !void {
        if (self.isBusy()) return error.Busy;
        if (services.store != store or !equal(store.root, self.root)) return error.ConfigurationChanged;
        if (store.publicationUncertain()) return error.ConfigPublicationUncertain;
        const preview = self.preview orelse return error.NoArchivePreview;
        const inspection = preview.inspection orelse return error.NoArchivePreview;
        if (preview.epoch != self.epoch or preview.failure != null or preview.cleanup_requested) return error.StaleArchivePreview;
        var target: pack_controller.Target = undefined;
        if (self.existing) |owned| {
            var actual: ?config.Instance = null;
            for (store.snapshot().instances) |row| if (equal(row.id, owned.value.id)) {
                if (actual != null or !sameRow(row, owned.value)) return error.InstanceConfigurationChanged;
                actual = row;
            };
            const row = actual orelse return error.InstanceConfigurationChanged;
            if (!matchesPack(row, inspection.pack)) return error.PackPrerequisitesMismatch;
            target = .{ .existing_instance = owned.value };
        } else {
            const row = try self.draft.value(.create, store.snapshot());
            if (!matchesPack(row, inspection.pack)) return error.PackPrerequisitesMismatch;
            target = .{ .new_instance = row };
        }
        if (services.java.isSearching() or services.java_download.snapshot().phase == .running or services.instances.isBusy() or services.content.isBusy()) return error.Busy;
        if (services.instances.snapshot().phase == .awaiting_publication) return error.InstancePublicationPending;
        if (services.content.snapshot().recovery_required) return error.RecoveryRequired;
        if (!services.content.options.allow_manifest_v2) return error.ManifestV2CapabilityRequired;
        const last_generation = @max(self.generation, controller.snapshot().preparation_generation);
        if (last_generation == std.math.maxInt(u64)) return error.IdExhausted;
        const environment = try hostEnvironment();
        if (self.existing) |owned| try services.instances.select(store, owned.value.id);
        const policy_generation = services.content.snapshot().policy_generation;
        self.generation = last_generation + 1;
        try controller.start(.{
            .archive_absolute_path = inspection.archive_absolute_path,
            .identity = inspection.pack.identity,
            .preparation_generation = self.generation,
            .provider_policy_generation = policy_generation,
            .target = target,
            .environment = environment,
        }, services);
        self.owner_controller = controller;
        self.owner_services = services;
        self.pinned = true;
        self.failure = null;
    }
};
pub fn open(ui: *Ui) void {
    if (!ui.stopping) ui.modal_open = true;
}

fn makeDraft(a: A, io: Io, pack: manifest.PackPlan) !instances_view.Draft {
    var draft: instances_view.Draft = .{};
    try draft.ensureId(a, io);
    errdefer draft.deinit(a);
    const base = try a.dupe(u8, pack.minecraft_version);
    draft.base = base;
    draft.loader = pack.loader;
    if (pack.loader_version) |version| {
        const owned_version = try a.dupe(u8, version);
        draft.loader_version = owned_version;
    }
    // A pack title need not be a legal instance folder name.
    try setText(&draft.name, if (pack.name.len < draft.name.len and config.validId(pack.name) and std.unicode.utf8ValidateSlice(pack.name)) pack.name else "Imported pack");
    return draft;
}

fn hostEnvironment() !metadata.rules.Environment {
    return .{
        .os_name = switch (builtin.os.tag) {
            .linux => "linux",
            .windows => "windows",
            .macos => "osx",
            else => return error.UnsupportedPlatform,
        },
        .arch = switch (builtin.cpu.arch) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            .x86 => "x86",
            else => return error.UnsupportedArchitecture,
        },
    };
}
fn line(src: std.builtin.SourceLocation, value: []const u8, color: dvui.Color) void {
    const layout = dvui.textLayout(src, .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = .{ .h = 8 }, .color_text = .{ .color = color } });
    layout.addText(value, .{});
    layout.deinit();
}
fn fmt(comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), format, args) catch "";
}
fn commandButton(src: std.builtin.SourceLocation, name: []const u8, asset: []const u8, enabled: bool) bool {
    return targetButton(src, name, asset, enabled, 0);
}
fn targetButton(src: std.builtin.SourceLocation, name: []const u8, asset: []const u8, enabled: bool, id_extra: usize) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{ .grayed = !enabled }, .{ .id_extra = id_extra, .expand = .horizontal, .max_size_content = .width(0), .min_size_content = .{ .h = 20 }, .padding = R.all(8), .margin = .{ .h = 6 }, .corners = .all(4), .label = .{ .text = name }, .tab_index = if (enabled) 0 else null });
    defer button.deinit();
    if (enabled) button.processEvents();
    button.drawBackground();
    const row = dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = R.all(0) });
    dvui.icon(src, name, asset, .{}, .{ .min_size_content = .{ .w = 18, .h = 18 }, .max_size_content = .{ .w = 18, .h = 18 }, .padding = R.all(0), .margin = .{ .w = 8 } });
    const label = dvui.textLayout(src, .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0) });
    label.addText(name, .{});
    label.deinit();
    row.deinit();
    button.drawFocus();
    dvui.tooltip(src, .{ .active_rect = button.data().borderRectScale().r }, "{s}", .{name}, .{});
    return enabled and button.clicked();
}
fn entry(src: std.builtin.SourceLocation, name: []const u8, buffer: []u8, numeric: bool) void {
    dvui.labelNoFmt(src, name, .{}, .{ .expand = .horizontal, .padding = R.all(0), .margin = .{ .y = 8, .h = 4 } });
    const input = dvui.textEntry(src, .{ .text = .{ .buffer = buffer } }, .{ .label = .{ .text = name }, .expand = .horizontal, .padding = R.all(8), .corners = .all(4) });
    if (numeric) input.filterIn("0123456789");
    input.deinit();
}
pub fn drawModal(ui: *Ui, store: *config.Store, controller: *pack_controller.Controller, blocked: bool) !void {
    if (!ui.modal_open) return;
    const snapshot = controller.snapshot();
    const rect = dvui.windowRect();
    var visible = true;
    const modal = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &visible, .resize = .none, .window_avoid = .none }, .{ .rect = .{ .x = rect.x + @max(12, (rect.w - 620) / 2), .y = rect.y + 12, .w = @max(0, @min(620, rect.w - 24)), .h = @max(0, @min(680, rect.h - 24)) }, .padding = R.all(16), .corners = .all(8), .label = .{ .text = "Import modpack" } });
    defer modal.deinit();
    modal.dragAreaSet(dvui.windowHeader("Import modpack", "", &visible));
    const scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .expand = .both, .padding = R.all(0), .border = R.all(0) });
    defer scroll.deinit();
    if (ui.failure) |err| line(@src(), @errorName(err), dvui.Color.fromHex("F0A6A1"));
    if (ui.cleanup_failure) |err| {
        line(@src(), fmt("Cleanup failed: {s}", .{@errorName(err)}), dvui.Color.fromHex("F0A6A1"));
        line(@src(), text(&ui.cleanup_stage), theme.muted);
    }
    if (ui.pinned) {
        const drain_enabled = !ui.stopping and ui.pending == null and ui.owner_controller == controller and snapshot.preparation_generation == ui.generation;
        line(@src(), @tagName(snapshot.phase), theme.accent);
        if (snapshot.failure) |err| line(@src(), @errorName(err), dvui.Color.fromHex("F0A6A1"));
        if (snapshot.runtime_major) |major| line(@src(), fmt("Runtime Java {d}", .{major}), theme.muted);
        if (snapshot.installer_major) |major| line(@src(), fmt("Installer Java {d}", .{major}), theme.muted);
        if (snapshot.phase == .awaiting_adoption and commandButton(@src(), "Retry content adoption", dvui.entypo.cw, drain_enabled)) ui.queueOwned(.retry_adoption, controller) catch |err| {
            ui.failure = err;
        };
        if (snapshot.phase == .awaiting_reconciliation and commandButton(@src(), "Reconcile saved instance", dvui.entypo.cw, drain_enabled)) ui.queueOwned(.reconcile, controller) catch |err| {
            ui.failure = err;
        };
        if (commandButton(@src(), "Cancel import", dvui.entypo.cross, drain_enabled)) ui.queueOwned(.cancel, controller) catch |err| {
            ui.failure = err;
        };
    } else if (ui.preview) |preview| {
        if (preview.thread != null or preview.cleanup_requested) {
            line(@src(), if (preview.cleanup_requested) "Cleaning private preview" else "Inspecting archive", theme.muted);
        } else if (preview.inspection) |inspection| {
            line(@src(), inspection.pack.name, theme.accent);
            line(@src(), fmt("Minecraft {s} / {s}{s}{s}", .{ inspection.pack.minecraft_version, @tagName(inspection.pack.loader), if (inspection.pack.loader_version != null) " " else "", inspection.pack.loader_version orelse "" }), theme.muted);
            line(@src(), fmt("SHA-256 {s}", .{inspection.source_sha256}), theme.muted);
            const enabled = !blocked and ui.pending == null;
            if (commandButton(@src(), "New instance", dvui.entypo.plus, enabled)) ui.queue(.choose_new);
            for (store.snapshot().instances) |instance| if (matchesPack(instance, inspection.pack)) {
                if (targetButton(@src(), instance.name, if (ui.existing) |chosen| if (sameRow(chosen.value, instance)) dvui.entypo.check else dvui.entypo.box else dvui.entypo.box, enabled, @as(usize, @truncate(std.hash.Wyhash.hash(0, instance.id))))) ui.queueExisting(instance) catch |err| {
                    ui.failure = err;
                };
            };
            if (ui.existing) |chosen| {
                line(@src(), chosen.value.name, theme.accent);
            } else if (enabled) {
                entry(@src(), "Instance name", &ui.draft.name, false);
                entry(@src(), "Maximum memory (MB)", &ui.draft.memory, true);
            } else {
                line(@src(), text(&ui.draft.name), theme.muted);
            }
            if (commandButton(@src(), "Start import", dvui.entypo.download, enabled and ui.cleanup_failure == null)) ui.queue(.confirm);
        }
    } else if (ui.picker != null) {
        line(@src(), "Selecting archive", theme.muted);
    } else if (!blocked) {
        entry(@src(), "Archive path", &ui.archive, false);
        if (commandButton(@src(), "Browse archive", dvui.entypo.folder, ui.pending == null and ui.cleanup_failure == null)) ui.queue(.browse);
        if (commandButton(@src(), "Inspect archive", dvui.entypo.magnifying_glass, ui.pending == null and validPath(text(&ui.archive)) and ui.cleanup_failure == null)) ui.queueArchive(text(&ui.archive)) catch |err| {
            ui.failure = err;
        };
    }
    const close_enabled = (!ui.pinned or ui.stopping) and ui.pending == null;
    if (commandButton(@src(), "Close", dvui.entypo.cross, close_enabled)) ui.queueOwned(.close, controller) catch |err| {
        ui.failure = err;
    };
    if (!visible and close_enabled) ui.queueOwned(.close, controller) catch |err| {
        ui.failure = err;
    };
}
fn ownedAction(command: *const Command) ?OwnedAction {
    return switch (command.*) {
        .close => .close,
        .cancel => .cancel,
        .reconcile => .reconcile,
        .retry_adoption => .retry_adoption,
        else => null,
    };
}
fn validateDrain(ui: *const Ui, action: OwnedAction, binding: ?DrainBinding, store: *config.Store, controller: *pack_controller.Controller, services: pack_controller.Services) !void {
    if (ui.stopping and action != .cancel and action != .close) return error.UiStopping;
    const queued = binding orelse return error.StalePreparationGeneration;
    if (queued.epoch != ui.epoch or queued.generation != ui.generation or queued.pinned != ui.pinned) return error.StalePreparationGeneration;
    if (action == .close and !ui.pinned) return;
    if (!ui.pinned or ui.generation == 0 or ui.owner_controller != controller) return error.StalePreparationGeneration;
    const owned_services = ui.owner_services orelse return error.ConfigurationChanged;
    if (services.store != store or !std.meta.eql(owned_services, services)) return error.ConfigurationChanged;
    const snapshot = ui.options.runner.owned_snapshot(ui.options.runner.context, controller);
    if (snapshot.preparation_generation != queued.generation or snapshot.serial != queued.serial or
        snapshot.role != queued.role or snapshot.phase != queued.phase) return error.StalePreparationGeneration;
    switch (action) {
        .close => if (!ui.stopping) return error.CancelImportFirst,
        .reconcile => if (snapshot.phase != .awaiting_reconciliation) return error.StalePreparationGeneration,
        .retry_adoption => if (snapshot.phase != .awaiting_adoption) return error.StalePreparationGeneration,
        .cancel => switch (snapshot.phase) {
            .idle, .failed, .canceled, .review_required => return error.StalePreparationGeneration,
            else => {},
        },
    }
}
pub fn finish(ui: *Ui, store: *config.Store, controller: *pack_controller.Controller, services: pack_controller.Services, blocked: bool) void {
    // Reject queued foreign commands; do not replay them after ownership changes.
    const restricted = blocked or ui.stopping;
    if (restricted) {
        if (ui.picker) |picker| picker.epoch = 0;
        ui.collectPicker(false);
    }
    if (restricted) {
        const action = if (ui.pending) |*command| ownedAction(command) else null;
        if (action == null) {
            if (ui.pending) |*command| command.deinit(ui.allocator);
            ui.pending = null;
            ui.pending_drain = null;
            return;
        }
    }
    if (!equal(ui.root, store.root)) {
        if (ui.pending) |*command| command.deinit(ui.allocator);
        ui.pending = null;
        ui.pending_drain = null;
        if (ui.picker) |picker| picker.epoch = 0;
        ui.collectPicker(false);
        ui.failure = error.ConfigurationChanged;
        return;
    }
    if (!restricted) ui.collectPicker(true);
    var command = ui.pending orelse return;
    const binding = ui.pending_drain;
    ui.pending = null;
    ui.pending_drain = null;
    defer command.deinit(ui.allocator);
    if (ownedAction(&command)) |action| {
        validateDrain(ui, action, binding, store, controller, services) catch |err| {
            ui.failure = err;
            return;
        };
    } else if (restricted) return;
    perform(ui, store, controller, services, &command) catch |err| {
        ui.failure = err;
    };
}
fn perform(ui: *Ui, store: *config.Store, controller: *pack_controller.Controller, services: pack_controller.Services, command: *Command) !void {
    switch (command.*) {
        .browse => try ui.beginPicker(),
        .inspect => |path| try ui.beginPreview(path),
        .choose_new => {
            if (ui.isBusy()) return error.Busy;
            if (ui.existing) |*row| row.deinit();
            ui.existing = null;
        },
        .choose_existing => |*owned| {
            if (ui.isBusy()) return error.Busy;
            const preview = ui.preview orelse return error.NoArchivePreview;
            if (!matchesPack(owned.value, preview.inspection.?.pack)) return error.PackPrerequisitesMismatch;
            if (ui.existing) |*old| old.deinit();
            ui.existing = owned.*;
            // Transfer the queued row arena to Ui; leave an empty arena to destroy.
            owned.arena = .init(ui.allocator);
        },
        .confirm => try ui.confirm(store, controller, services),
        .close => {
            if (ui.pinned) {
                if (!ui.stopping) return error.CancelImportFirst;
                ui.modal_open = false;
                return;
            }
            try ui.nextEpoch();
            ui.modal_open = false;
            ui.releasePreview();
            if (ui.existing) |*row| row.deinit();
            ui.existing = null;
            ui.draft.deinit(ui.allocator);
            ui.draft = .{};
        },
        .cancel, .retry_adoption, .reconcile => try ui.options.runner.drain(ui.options.runner.context, ownedAction(command).?, store, controller, services),
    }
}

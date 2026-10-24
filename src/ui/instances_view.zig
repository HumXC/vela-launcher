//! Call finish only after every root and floating widget has closed.
const std = @import("std");
const dvui = @import("dvui");
const config = @import("../core/config.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const manager_module = @import("instances_manager.zig");
const library = @import("game_library.zig");
const java_module = @import("java_manager.zig");
const task_view = @import("instance_task_view.zig");
const Allocator = std.mem.Allocator;
const R = dvui.Rect;

pub const metrics = struct {
    pub const control_font = theme.typography.body;
    pub const title_font = theme.typography.title;
    pub const sidebar_title_font = theme.typography.title;
    pub const version_font = theme.typography.heading;
    pub const date_font = theme.typography.caption;
    pub const group_gap = theme.spacing.group_gap;
    pub const row_gap = theme.spacing.row_gap;
    pub const card_gap = theme.style.cards.version_gap;
    pub const sidebar_padding = theme.spacing.sidebar_padding;
    pub const loading_diameter = theme.sizing.loading_diameter;
    pub const control_height = theme.sizing.control_height;
    pub const primary_height = theme.sizing.control_height;
    pub const card_height = theme.style.cards.version_height;
    pub const card_padding_x = theme.spacing.panel_compact_padding - theme.sizing.control_border;
    pub const card_padding_y = theme.style.cards.version_padding_y - theme.sizing.control_border;
    pub const check_diameter = theme.sizing.selection_diameter;
    pub const check_icon = theme.sizing.selection_icon;
};

pub const Mode = enum { none, create, options, rename, delete_confirm };
pub const CreateStep = enum { version, loader, confirm };
pub const VersionFilter = enum { release, snapshot, old };
pub const Action = enum { create, edit, ask_rename, ask_delete, select, submit, confirm, close, cancel, close_task, retry_publication, choose_base, choose_loader_kind, choose_loader, load_loaders, next_step, previous_step, save_navigation, discard_navigation, cancel_navigation, leave };
const Pending = struct { action: Action, text: ?[]u8 = null, kind: config.Loader = .vanilla, force_refresh: bool = false };
pub const Draft = struct {
    id: ?[]u8 = null,
    name: [201]u8 = @splat(0),
    original_name: [201]u8 = @splat(0),
    original_java_path: [4097]u8 = @splat(0),
    original_min_memory: ?u32 = null,
    original_memory: ?u32 = null,
    original_debug: bool = false,
    installed: bool = false,
    /// Launch-options persistence; the editor chooses a registered runtime.
    java_path: [4097]u8 = @splat(0),
    min_memory: [11]u8 = @splat(0),
    memory: [11]u8 = @splat(0),
    debug_launch: bool = false,
    base: ?[]u8 = null,
    loader: config.Loader = .vanilla,
    loader_version: ?[]u8 = null,
    origin: ?config.Origin = null,

    pub fn deinit(self: *Draft, a: Allocator) void {
        if (self.id) |s| a.free(s);
        if (self.base) |s| a.free(s);
        if (self.loader_version) |s| a.free(s);
        if (self.origin) |o| {
            a.free(o.project_id);
            a.free(o.version_id);
        }
        self.* = .{};
    }

    pub fn fromInstance(a: Allocator, instance: config.Instance) !Draft {
        var draft: Draft = .{};
        errdefer draft.deinit(a);
        draft.id = try a.dupe(u8, instance.id);
        try setText(&draft.name, instance.name);
        try setText(&draft.original_name, instance.name);
        draft.base = try a.dupe(u8, instance.minecraft_version);
        draft.loader = instance.loader;
        if (instance.loader_version) |s| draft.loader_version = try a.dupe(u8, s);
        if (instance.java_path) |s| try setText(&draft.java_path, s);
        if (instance.min_memory_mb) |m| _ = try std.fmt.bufPrint(draft.min_memory[0 .. draft.min_memory.len - 1], "{d}", .{m});
        if (instance.max_memory_mb) |m| _ = try std.fmt.bufPrint(draft.memory[0 .. draft.memory.len - 1], "{d}", .{m});
        draft.debug_launch = instance.debug_launch;
        draft.installed = true;
        if (instance.java_path) |s| try setText(&draft.original_java_path, s);
        draft.original_min_memory = instance.min_memory_mb;
        draft.original_memory = instance.max_memory_mb;
        draft.original_debug = instance.debug_launch;
        if (instance.origin) |o| {
            const project = try a.dupe(u8, o.project_id);
            errdefer a.free(project);
            const version = try a.dupe(u8, o.version_id);
            draft.origin = .{ .kind = o.kind, .project_id = project, .version_id = version };
        }
        return draft;
    }

    pub fn ensureId(self: *Draft, a: Allocator, io: std.Io) !void {
        if (self.id != null) return;
        var random: [16]u8 = undefined;
        try io.randomSecure(&random);
        const id = try std.fmt.allocPrint(a, "instance-{s}", .{std.fmt.bytesToHex(random, .lower)});
        self.id = id;
    }

    pub fn value(self: *const Draft, mode: Mode, doc: *const config.Document) !config.Instance {
        const name = text(&self.name);
        try validateName(doc, name, if (mode == .options or mode == .rename) self.id else null);
        const java = text(&self.java_path);
        if (!validText(java, true)) return error.InvalidJavaPath;
        const min_memory = try parseMemory(text(&self.min_memory));
        const memory = try parseMemory(text(&self.memory));
        if (min_memory) |minimum| if (minimum > (memory orelse doc.settings.default_memory_mb)) return error.InvalidMemory;
        const base = self.base orelse return error.MinecraftVersionRequired;
        if (!validText(base, false)) return error.InvalidMinecraftVersion;
        if (self.loader != .vanilla and self.loader_version == null) return error.LoaderVersionRequired;
        if (self.loader_version) |version| if (!validText(version, false)) return error.InvalidLoaderVersion;
        return .{ .id = self.id orelse return error.InvalidId, .name = name, .minecraft_version = base, .loader = self.loader, .loader_version = self.loader_version, .java_path = if (java.len == 0) null else java, .min_memory_mb = min_memory, .max_memory_mb = memory, .debug_launch = self.debug_launch, .origin = self.origin };
    }
    pub fn original(self: *const Draft) !config.Instance {
        if (!self.installed) return error.InvalidAction;
        const java = text(&self.original_java_path);
        return .{ .id = self.id orelse return error.InvalidId, .name = text(&self.original_name), .minecraft_version = self.base orelse return error.MinecraftVersionRequired, .loader = self.loader, .loader_version = self.loader_version, .java_path = if (java.len == 0) null else java, .min_memory_mb = self.original_min_memory, .max_memory_mb = self.original_memory, .debug_launch = self.original_debug, .origin = self.origin };
    }

    pub fn dirty(self: *const Draft) bool {
        if (!self.installed) return false;
        const min_memory = parseMemory(text(&self.min_memory)) catch return true;
        const memory = parseMemory(text(&self.memory)) catch return true;
        return !std.mem.eql(u8, text(&self.name), text(&self.original_name)) or
            !std.mem.eql(u8, text(&self.java_path), text(&self.original_java_path)) or
            min_memory != self.original_min_memory or memory != self.original_memory or self.debug_launch != self.original_debug;
    }
};

pub const Ui = struct {
    allocator: Allocator,
    draft: Draft = .{},
    mode: Mode = .none,
    rename_confirmed: bool = false,
    pending: ?Pending = null,
    navigation: ?Pending = null,
    navigation_prompt: bool = false,
    saving_navigation: bool = false,
    form_focus: ?u64 = null,
    form_subwindow: ?u64 = null,
    restore_form_focus: bool = false,
    /// Recomputed by the page renderer; drawModal has no manager dependency.
    delete_confirmation_locked: bool = false,
    /// Incremented only after an admitted navigation executes; modal clicks do not count.
    navigation_serial: u64 = 0,
    exit_requested: bool = false,
    manage_requested: bool = false,
    failure: ?anyerror = null,
    task: task_view.State = .{},
    task_can_cancel: bool = false,
    task_can_retry: bool = false,
    settings_failure_scroll_pending: bool = false,
    publication_failed: bool = false,
    submitted: bool = false,
    /// The shared prerequisite owner supplies the popup until all stages JOIN.
    creation_active: bool = false,
    /// Recomputed per frame; avoid observing the underlying artifact task twice.
    creation_presented: bool = false,
    catalogue_requested: bool = false,
    create_step: CreateStep = .version,
    version_filter: VersionFilter = .release,
    search: [64]u8 = @splat(0),
    loader_search: [64]u8 = @splat(0),
    browse_loader: config.Loader = .fabric,
    generated_name: [201]u8 = @splat(0),
    name_custom: bool = false,
    name_focus_pending: bool = false,
    name_focus_layout_seen: bool = false,
    name_focus_requested: bool = false,
    /// Reassigned by page integration before drawing; never dereference between frames.
    java_preview: @import("version_preview_types.zig").Snapshot = .{},

    pub fn init(a: Allocator) Ui {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Ui) void {
        self.draft.deinit(self.allocator);
        self.task.deinit(self.allocator);
        if (self.pending) |p| if (p.text) |s| self.allocator.free(s);
        self.pending = null;
        self.clearNavigation();
    }
    pub fn queue(self: *Ui, action: Action, borrowed: ?[]const u8) void {
        if (action == .confirm and (self.submitted or self.pending != null or (self.mode == .delete_confirm and self.delete_confirmation_locked))) return;
        const owned = if (borrowed) |s| self.allocator.dupe(u8, s) catch |err| {
            self.failure = err;
            return;
        } else null;
        if (self.pending) |p| if (p.text) |s| self.allocator.free(s);
        self.pending = .{ .action = action, .text = owned };
    }
    pub fn blocksPackWorkflow(self: *const Ui) bool {
        return (self.mode != .none and self.mode != .options) or self.pending != null or
            self.navigation != null or self.submitted;
    }
    fn clearNavigation(self: *Ui) void {
        if (self.navigation) |p| if (p.text) |s| self.allocator.free(s);
        self.navigation = null;
        self.navigation_prompt = false;
        self.saving_navigation = false;
    }
    fn reset(self: *Ui) void {
        self.draft.deinit(self.allocator);
        self.mode = .none;
        self.rename_confirmed = false;
        self.submitted = false;
        self.settings_failure_scroll_pending = false;
        self.create_step = .version;
        self.catalogue_requested = false;
        self.version_filter = .release;
        self.search = @splat(0);
        self.loader_search = @splat(0);
        self.browse_loader = .fabric;
        self.generated_name = @splat(0);
        self.name_custom = false;
        self.name_focus_pending = false;
        self.name_focus_layout_seen = false;
        self.name_focus_requested = false;
    }
};

fn text(buffer: []const u8) []const u8 {
    return buffer[0 .. std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len];
}
fn setText(buffer: []u8, s: []const u8) !void {
    if (s.len >= buffer.len) return error.TextTooLong;
    @memset(buffer, 0);
    @memcpy(buffer[0..s.len], s);
}
fn validText(s: []const u8, allow_empty: bool) bool {
    if ((!allow_empty and s.len == 0) or !std.unicode.utf8ValidateSlice(s)) return false;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return false;
    return true;
}
pub fn parseMemory(s: []const u8) !?u32 {
    if (s.len == 0) return null;
    for (s) |ch| if (ch < '0' or ch > '9') return error.InvalidMemory;
    const memory = std.fmt.parseInt(u32, s, 10) catch return error.InvalidMemory;
    if (memory < 256 or memory > 1024 * 1024) return error.InvalidMemory;
    return memory;
}
pub fn validateName(doc: *const config.Document, name: []const u8, excluding: ?[]const u8) !void {
    if (!config.validId(name)) return error.InvalidInstanceName;
    for (doc.instances) |instance| {
        if (excluding) |id| if (std.mem.eql(u8, id, instance.id)) continue;
        if (std.ascii.eqlIgnoreCase(instance.name, name)) return error.DuplicateInstanceName;
    }
}
fn find(doc: *const config.Document, id: []const u8) !config.Instance {
    for (doc.instances) |instance| if (std.mem.eql(u8, instance.id, id)) return instance;
    return error.InstanceNotFound;
}
fn replaceOwned(a: Allocator, target: *?[]u8, borrowed: []const u8) !void {
    const owned = try a.dupe(u8, borrowed);
    if (target.*) |old| a.free(old);
    target.* = owned;
}

fn isNavigation(action: Action) bool {
    return switch (action) {
        .select, .create, .edit, .ask_rename, .leave => true,
        else => false,
    };
}

fn syncSelected(ui: *Ui, store: *config.Store) !void {
    if (ui.submitted or ui.navigation != null or ui.exit_requested) return;
    const instance = selectedInstance(store.snapshot()) orelse return;
    if (ui.mode == .options) {
        if (ui.draft.dirty()) return;
        if (ui.draft.id) |id| if (std.mem.eql(u8, id, instance.id)) return;
    } else if (ui.mode != .none) return;
    const draft = try Draft.fromInstance(ui.allocator, instance);
    ui.reset();
    ui.draft = draft;
    ui.mode = .options;
}

fn saveInstalled(ui: *Ui, store: *config.Store, manager: anytype) !void {
    if (manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
    if (store.publicationUncertain()) return error.ConfigPublicationUncertain;
    const original = try ui.draft.original();
    if (!manager_module.sameInstance(original, try find(store.snapshot(), original.id))) return error.InstanceChanged;
    const updated = try ui.draft.value(.options, store.snapshot());
    if (!std.mem.eql(u8, original.name, updated.name)) {
        manager.startRenameWithOptions(original, updated) catch |err| {
            ui.task.failAdmission(ui.allocator, .renaming, updated.name, err);
            return err;
        };
        ui.submitted = true;
        ui.publication_failed = false;
        return;
    }
    var refreshed = try Draft.fromInstance(ui.allocator, updated);
    errdefer refreshed.deinit(ui.allocator);
    try manager.saveOptionsChecked(store, original, updated);
    ui.reset();
    ui.draft = refreshed;
    ui.mode = .options;
}

fn resumeNavigation(ui: *Ui, store: *config.Store, manager: anytype) anyerror!void {
    const destination = ui.navigation orelse return;
    ui.navigation_prompt = false;
    ui.saving_navigation = false;
    // A completed save or explicit discard authorizes this destination only.
    try performDirect(ui, store, manager, destination);
    ui.navigation_serial +%= 1;
    ui.clearNavigation();
}

fn perform(ui: *Ui, store: *config.Store, manager: anytype, p: Pending) !void {
    if (isNavigation(p.action)) {
        if (ui.mode == .delete_confirm) return error.Busy;
        if (manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
        if (ui.navigation != null) return error.NavigationPending;
        const same_row = (p.action == .select or p.action == .edit) and ui.mode == .options and
            if (p.text) |id| if (ui.draft.id) |current| std.mem.eql(u8, id, current) else false else false;
        if (same_row) {
            ui.navigation_serial +%= 1;
            return;
        }
        if (ui.draft.installed and ui.draft.dirty()) {
            const owned = if (p.text) |s| try ui.allocator.dupe(u8, s) else null;
            ui.navigation = .{ .action = p.action, .text = owned, .kind = p.kind };
            ui.navigation_prompt = true;
            return;
        }
    }
    try performDirect(ui, store, manager, p);
    if (isNavigation(p.action)) ui.navigation_serial +%= 1;
}

fn performDirect(ui: *Ui, store: *config.Store, manager: anytype, p: Pending) !void {
    const doc = store.snapshot();
    switch (p.action) {
        .create => {
            if (manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
            var draft: Draft = .{};
            errdefer draft.deinit(ui.allocator);
            try draft.ensureId(ui.allocator, store.io);
            ui.reset();
            ui.draft = draft;
            ui.mode = .create;
            ui.catalogue_requested = true;
        },
        .edit, .ask_rename, .ask_delete => {
            if (manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
            if (p.action == .ask_delete and (ui.submitted or ui.navigation != null)) return error.Busy;
            if (p.action == .ask_delete and ui.mode == .options) {
                if (ui.draft.id) |id| if (std.mem.eql(u8, id, p.text orelse return error.InvalidId)) {
                    ui.mode = .delete_confirm;
                    return;
                };
            }
            const draft = try Draft.fromInstance(ui.allocator, try find(doc, p.text orelse return error.InvalidId));
            ui.reset();
            ui.draft = draft;
            ui.mode = switch (p.action) {
                .edit => .options,
                .ask_rename => .rename,
                else => .delete_confirm,
            };
        },
        .select => {
            if (manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
            var draft = try Draft.fromInstance(ui.allocator, try find(doc, p.text orelse return error.InvalidId));
            errdefer draft.deinit(ui.allocator);
            try manager.select(store, draft.id.?);
            ui.reset();
            ui.draft = draft;
            ui.mode = .options;
        },
        .save_navigation => {
            if (ui.navigation == null) return error.NoPendingNavigation;
            try saveInstalled(ui, store, manager);
            if (ui.submitted) {
                ui.saving_navigation = true;
                ui.navigation_prompt = false;
            } else try resumeNavigation(ui, store, manager);
        },
        .discard_navigation => {
            if (ui.navigation == null) return error.NoPendingNavigation;
            if (manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
            try resumeNavigation(ui, store, manager);
        },
        .cancel_navigation => {
            ui.clearNavigation();
            ui.restore_form_focus = true;
        },
        .leave => {
            ui.reset();
            ui.exit_requested = true;
        },
        .close => {
            if (manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
            if (ui.mode == .delete_confirm) {
                closeDeleteConfirmation(ui);
            } else ui.reset();
        },
        .close_task => {
            if (ui.task.phase != .working and ui.task.phase != .awaiting_publication) ui.task.visible = false;
        },
        .cancel => {
            const current = manager.snapshot();
            // A worker can finish between the click and this deferred action.
            if (current.phase != .working) return;
            if (ui.task.task_id == null or ui.task.task_id != current.task_id) return;
            manager.cancel();
            ui.task.visible = false;
        },
        .retry_publication => {
            const current = manager.snapshot();
            if (current.phase != .awaiting_publication) return error.NoPendingPublication;
            if (ui.task.task_id == null or ui.task.task_id != current.task_id) return error.NoPendingPublication;
            ui.publication_failed = true;
            try manager.publish(store);
            ui.publication_failed = false;
            if (ui.submitted) ui.reset();
            if (ui.navigation != null) try resumeNavigation(ui, store, manager);
        },
        .next_step => {
            if (manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
            const before = ui.create_step;
            try advanceCreateStep(ui);
            if (before == .version) {
                try manager.loadLoaders(ui.draft.base.?, ui.browse_loader);
            } else try refreshGeneratedName(ui, doc);
        },
        .previous_step => {
            if (manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
            if (ui.mode != .create) return error.InvalidAction;
            try previousCreateStep(ui);
        },
        .choose_base => {
            try chooseBase(ui, doc, p.text orelse return error.MinecraftVersionRequired);
        },
        .choose_loader_kind => {
            if (ui.mode != .create or ui.create_step != .loader) return error.InvalidAction;
            if (p.kind == .vanilla) {
                if (manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
                clearLoader(ui);
                try refreshGeneratedName(ui, doc);
            } else {
                ui.browse_loader = p.kind;
                ui.loader_search = @splat(0);
                clearLoader(ui);
                try refreshGeneratedName(ui, doc);
                try manager.loadLoaders(ui.draft.base orelse return error.MinecraftVersionRequired, ui.browse_loader);
            }
        },
        .choose_loader => {
            try chooseLoader(ui, doc, p.kind, p.text orelse return error.LoaderVersionRequired);
        },
        .load_loaders => {
            const base = ui.draft.base orelse return error.MinecraftVersionRequired;
            if (p.force_refresh) try manager.refreshLoaders(base, ui.browse_loader) else try manager.loadLoaders(base, ui.browse_loader);
        },
        .submit => {
            if (manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
            if (ui.mode == .create and ui.create_step != .confirm) return error.WizardStepRequired;
            if (ui.mode == .rename) {
                try validateName(doc, text(&ui.draft.name), ui.draft.id);
                ui.rename_confirmed = true;
                return;
            }
            if (store.publicationUncertain()) return error.ConfigPublicationUncertain;
            if (ui.mode != .create and ui.mode != .options) return error.InvalidAction;
            try ui.draft.ensureId(ui.allocator, store.io);
            const instance = try ui.draft.value(ui.mode, doc);
            switch (ui.mode) {
                .create => {
                    manager.setDownloadConnections(doc.settings.download_connections);
                    manager.startCreate(instance) catch |err| {
                        ui.task.failAdmission(ui.allocator, .creating, instance.name, err);
                        return err;
                    };
                },
                .options => {
                    try saveInstalled(ui, store, manager);
                    return;
                },
                else => return error.InvalidAction,
            }
            ui.submitted = true;
            ui.publication_failed = false;
        },
        .confirm => {
            if (ui.submitted or manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
            const original = try find(doc, ui.draft.id orelse return error.InvalidId);
            if (!manager_module.sameInstance(original, try ui.draft.original())) return error.InstanceChanged;
            switch (ui.mode) {
                .rename => {
                    if (!ui.rename_confirmed) return error.ConfirmationRequired;
                    try validateName(doc, text(&ui.draft.name), ui.draft.id);
                    manager.startRename(original, text(&ui.draft.name)) catch |err| {
                        ui.task.failAdmission(ui.allocator, .renaming, original.name, err);
                        return err;
                    };
                },
                .delete_confirm => {
                    manager.startDelete(original) catch |err| {
                        ui.task.failAdmission(ui.allocator, .deleting, original.name, err);
                        return err;
                    };
                    // Accepted deletion leaves confirmation; submitted keeps the draft inert.
                    ui.mode = .options;
                },
                else => return error.InvalidAction,
            }
            ui.submitted = true;
            ui.publication_failed = false;
        },
    }
}

/// Generic seam for state-only fixture tests; no widget construction is needed.
pub fn finishWithManager(ui: *Ui, store: *config.Store, manager: anytype) void {
    if (ui.pending) |p| {
        // Keep the user intent until tick has joined the canceled catalogue worker.
        const can_skip_catalogue = ui.mode == .create and ui.create_step == .loader and (p.action == .next_step or p.action == .previous_step or (p.action == .choose_loader_kind and p.kind == .vanilla));
        if (can_skip_catalogue and manager.isBusy()) {
            const state = manager.snapshot();
            if (state.operation == .loading_loaders) {
                manager.cancel();
                return;
            }
        }
        ui.pending = null;
        defer if (p.text) |s| ui.allocator.free(s);
        perform(ui, store, manager, p) catch |err| {
            ui.failure = err;
            if (p.action == .submit and ui.mode == .options) ui.settings_failure_scroll_pending = true;
            if (ui.navigation != null and !ui.submitted) ui.navigation_prompt = true;
            return;
        };
        if (p.action == .close_task or p.action == .cancel) return;
        ui.failure = null;
    }
    const snapshot = manager.snapshot();
    if (ui.submitted and (snapshot.phase == .failed or snapshot.phase == .canceled)) {
        ui.submitted = false;
        ui.failure = snapshot.failure;
        if (ui.navigation != null) {
            ui.saving_navigation = false;
            ui.navigation_prompt = true;
        }
    }
    if (snapshot.phase == .awaiting_publication and !ui.publication_failed) {
        manager.publish(store) catch |err| {
            ui.publication_failed = true;
            ui.failure = err;
            return;
        };
        ui.failure = null;
        if (ui.submitted) ui.reset();
        if (ui.navigation != null) resumeNavigation(ui, store, manager) catch |err| {
            ui.failure = err;
            ui.navigation_prompt = true;
            return;
        };
    }
    syncSelected(ui, store) catch |err| {
        ui.failure = err;
    };
}
pub fn finish(ui: *Ui, store: *config.Store, manager: *manager_module.Manager) void {
    finishWithManager(ui, store, manager);
}

/// Ordinary acquisition has the same foreground popup as the artifact worker.
/// Call only after root/floating widgets close; pack publication never enters here.
pub fn finishWithPreflight(ui: *Ui, store: *config.Store, manager: anytype, controller: anytype, services: anytype, allow_mutations: bool) void {
    if (!allow_mutations) {
        if (ui.pending) |pending| if (pending.text) |owned| ui.allocator.free(owned);
        ui.pending = null;
        return;
    }
    if (!ui.creation_active) {
        if (ui.pending) |pending| {
            if (pending.action == .submit and ui.mode == .create) {
                ui.pending = null;
                defer if (pending.text) |owned| ui.allocator.free(owned);
                startPreflight(ui, store, manager, controller, services) catch |err| {
                    ui.failure = err;
                    return;
                };
            } else {
                finishWithManager(ui, store, manager);
                return;
            }
        } else {
            finishWithManager(ui, store, manager);
            return;
        }
    }
    const snapshot = controller.creationSnapshot();
    const current = ui.task.task_id != null and ui.task.task_id == snapshot.task_id;
    syncTaskSnapshot(ui, snapshot);
    if (ui.pending) |pending| {
        ui.pending = null;
        defer if (pending.text) |owned| ui.allocator.free(owned);
        switch (pending.action) {
            .cancel => if (current and snapshot.phase == .working) {
                controller.cancel(services);
                ui.task.visible = false;
                return;
            },
            .close_task => if (snapshot.phase == .complete or snapshot.phase == .failed or snapshot.phase == .canceled) {
                ui.task.visible = false;
            },
            .retry_publication => {
                if (current and snapshot.phase == .awaiting_publication) {
                    ui.publication_failed = false;
                } else {
                    ui.failure = error.NoPendingPublication;
                }
            },
            else => {},
        }
    }
    if (snapshot.phase == .awaiting_publication and !ui.publication_failed) {
        controller.publishOrdinary(services, allow_mutations) catch |err| {
            ui.failure = err;
            ui.publication_failed = true;
            return;
        };
        ui.failure = null;
    }
    if (snapshot.phase == .complete) {
        ui.creation_active = false;
        ui.reset();
    } else if (snapshot.phase == .failed or snapshot.phase == .canceled) {
        ui.creation_active = false;
        ui.submitted = false;
        ui.failure = snapshot.failure;
    }
}

fn startPreflight(ui: *Ui, store: *config.Store, manager: anytype, controller: anytype, services: anytype) !void {
    if (ui.submitted or manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
    if (ui.create_step != .confirm) return error.WizardStepRequired;
    if (store.publicationUncertain()) return error.ConfigPublicationUncertain;
    try ui.draft.ensureId(ui.allocator, store.io);
    const instance = try ui.draft.value(.create, store.snapshot());
    manager.setDownloadConnections(store.snapshot().settings.download_connections);
    controller.startOrdinary(instance, services) catch |err| {
        ui.task.failAdmission(ui.allocator, .creating, text(&ui.draft.name), err);
        return err;
    };
    ui.submitted = true;
    ui.creation_active = true;
    ui.publication_failed = false;
    ui.failure = null;
}

fn fmt(comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), format, args) catch "";
}

pub fn advanceCreateStep(ui: *Ui) !void {
    if (ui.mode != .create) return error.InvalidAction;
    const base = ui.draft.base orelse return error.MinecraftVersionRequired;
    if (!validText(base, false) or !supportedMinecraft(base)) return error.InvalidMinecraftVersion;
    switch (ui.create_step) {
        .version => ui.create_step = .loader,
        .loader => {
            if (ui.draft.loader != .vanilla and ui.draft.loader_version == null) return error.LoaderVersionRequired;
            ui.create_step = .confirm;
            if (!ui.name_focus_requested and !ui.name_custom) {
                ui.name_focus_pending = true;
                ui.name_focus_layout_seen = false;
            }
        },
        .confirm => return error.InvalidAction,
    }
}

pub fn previousCreateStep(ui: *Ui) !void {
    if (ui.mode != .create) return error.InvalidAction;
    ui.create_step = switch (ui.create_step) {
        .version => return error.InvalidAction,
        .loader => .version,
        .confirm => .loader,
    };
    ui.name_focus_pending = false;
}

pub fn loaderTitle(kind: config.Loader) []const u8 {
    return switch (kind) {
        .vanilla => "不使用 Mod 加载器",
        .fabric => "Fabric",
        .forge => "Forge",
        .neoforge => "NeoForge",
        .quilt => "Quilt",
    };
}

/// Generates a free default only; callers must never apply it to custom input.
pub fn defaultName(buffer: []u8, doc: *const config.Document, base: []const u8, kind: config.Loader) ![]const u8 {
    var suffix: usize = 1;
    while (true) : (suffix += 1) {
        const loader = if (kind == .vanilla) "" else loaderTitle(kind);
        const candidate = if (suffix == 1)
            try std.fmt.bufPrint(buffer, "{s}{s}{s}", .{ base, if (kind == .vanilla) "" else "-", loader })
        else
            try std.fmt.bufPrint(buffer, "{s}{s}{s}-{d}", .{ base, if (kind == .vanilla) "" else "-", loader, suffix });
        validateName(doc, candidate, null) catch |err| switch (err) {
            error.DuplicateInstanceName => continue,
            else => return err,
        };
        return candidate;
    }
}

fn observeNameEdit(ui: *Ui) void {
    if (!std.mem.eql(u8, text(&ui.draft.name), text(&ui.generated_name))) {
        ui.name_custom = true;
        ui.name_focus_pending = false;
    }
}

pub fn refreshGeneratedName(ui: *Ui, doc: *const config.Document) !void {
    observeNameEdit(ui);
    if (ui.name_custom) return;
    var buffer: [200]u8 = undefined;
    const generated = try defaultName(&buffer, doc, ui.draft.base orelse return error.MinecraftVersionRequired, ui.draft.loader);
    try setText(&ui.draft.name, generated);
    try setText(&ui.generated_name, generated);
}

fn clearLoader(ui: *Ui) void {
    if (ui.draft.loader_version) |old| ui.allocator.free(old);
    ui.draft.loader_version = null;
    ui.draft.loader = .vanilla;
}

pub fn chooseBase(ui: *Ui, doc: *const config.Document, base: []const u8) !void {
    if (ui.mode != .create or ui.create_step != .version) return error.InvalidAction;
    if (!supportedMinecraft(base)) return error.InvalidMinecraftVersion;
    if (ui.draft.base) |current| if (std.mem.eql(u8, current, base)) return;
    try replaceOwned(ui.allocator, &ui.draft.base, base);
    clearLoader(ui);
    try refreshGeneratedName(ui, doc);
}

pub fn chooseLoader(ui: *Ui, doc: *const config.Document, kind: config.Loader, version: []const u8) !void {
    if (ui.mode != .create or ui.create_step != .loader) return error.InvalidAction;
    if (kind == .vanilla or kind != ui.browse_loader or !validText(version, false)) return error.InvalidLoaderVersion;
    const selected = ui.draft.loader == kind and if (ui.draft.loader_version) |current| std.mem.eql(u8, current, version) else false;
    if (selected) {
        clearLoader(ui);
    } else {
        try replaceOwned(ui.allocator, &ui.draft.loader_version, version);
        ui.draft.loader = kind;
    }
    try refreshGeneratedName(ui, doc);
}

pub fn supportedMinecraft(id: []const u8) bool {
    if (std.mem.startsWith(u8, id, "1.")) {
        var parts = std.mem.splitScalar(u8, id[2..], '.');
        const minor_text = parts.next() orelse return false;
        const minor = std.fmt.parseInt(u32, minor_text[0 .. std.mem.indexOfScalar(u8, minor_text, '-') orelse minor_text.len], 10) catch return false;
        if (minor != 7) return minor > 7;
        const patch_text = parts.next() orelse return false;
        const patch = std.fmt.parseInt(u32, patch_text[0 .. std.mem.indexOfScalar(u8, patch_text, '-') orelse patch_text.len], 10) catch return false;
        return patch >= 10;
    }
    // Weekly snapshots from the 1.8 era onward; older alpha/beta IDs never match.
    if (id.len >= 6 and id[2] == 'w') {
        const year = std.fmt.parseInt(u32, id[0..2], 10) catch return false;
        const week = std.fmt.parseInt(u32, id[3..5], 10) catch return false;
        return year > 14 or (year == 14 and week >= 26);
    }
    const end = std.mem.indexOfScalar(u8, id, '.') orelse return false;
    const major = std.fmt.parseInt(u32, id[0..end], 10) catch return false;
    return major >= 2;
}

fn catalogueMatches(kind: []const u8, filter: VersionFilter) bool {
    return std.mem.eql(u8, kind, if (filter == .snapshot) "snapshot" else "release");
}

fn searchMatches(value: []const u8, query: []const u8) bool {
    if (query.len > value.len) return false;
    for (0..value.len - query.len + 1) |start| if (std.ascii.eqlIgnoreCase(value[start .. start + query.len], query)) return true;
    return false;
}

fn wizardButtonEvents(control: *dvui.ButtonWidget, enabled: bool) void {
    if (control.data().accesskit_node()) |node| if (!enabled) {
        dvui.AccessKit.nodeSetDisabled(node);
        dvui.AccessKit.nodeRemoveAction(node, .click);
        dvui.AccessKit.nodeRemoveAction(node, .focus);
    };
    if (enabled) control.processEvents() else control.processHover();
}

fn wizardButtonState(control: *dvui.ButtonWidget, enabled: bool, material: bool) void {
    wizardButtonEvents(control, enabled);
    theme.buttonBackground(control, .{ .material = material });
}

fn wizardTab(src: std.builtin.SourceLocation, name: []const u8, tag: []const u8, selected: bool, enabled: bool, horizontal_padding: f32, gap: f32) bool {
    var control: dvui.ButtonWidget = undefined;
    const font = theme.bodyFont();
    const geometry = theme.controlGeometry(@max(font.lineHeight(), font.textSize(name).h), metrics.control_height, 0, horizontal_padding, theme.sizing.control_border);
    control.init(src, .{ .grayed = !enabled, .draw_focus = enabled }, theme.panelButtonOptions(theme.controlOptions(@max(font.lineHeight(), font.textSize(name).h)).override(.{
        .id_extra = @as(usize, @truncate(std.hash.Wyhash.hash(0, tag))),
        .tag = tag,
        .label = .{ .text = name },
        .min_size_content = geometry.content,
        .padding = geometry.padding,
        .margin = .{ .w = gap, .h = if (dvui.windowRect().h < 480) theme.spacing.detail_gap else theme.spacing.row_gap },
        .style = if (selected and enabled) .highlight else .control,
        .color_fill_hover = if (!enabled) .{ .color = theme.colors.surface } else null,
        .color_fill_press = if (!enabled) .{ .color = theme.colors.surface } else null,
        .tab_index = if (enabled) null else 0,
    }), selected and enabled));
    defer control.deinit();
    wizardButtonState(&control, enabled, !(selected and enabled));
    if (control.data().accesskit_node()) |node| dvui.AccessKit.nodeSetSelected(node, selected);
    dvui.labelNoFmt(@src(), name, .{}, control.style().override(.{ .id_extra = @as(usize, @truncate(std.hash.Wyhash.hash(0, tag))), .font = theme.fontSized(metrics.control_font), .gravity_y = 0.5, .padding = R.all(0), .margin = R.all(0), .background = false }));
    return enabled and control.clicked();
}

fn wizardSearch(src: std.builtin.SourceLocation, name: []const u8, tag: []const u8, buffer: []u8, enabled: bool) void {
    var input: dvui.TextEntryWidget = undefined;
    input.init(src, .{ .text = .{ .buffer = buffer }, .placeholder = name }, components.entryOptions(name, .{ .tag = tag }).override(.{ .margin = .{ .h = if (dvui.windowRect().h < 480) theme.spacing.row_gap else theme.spacing.section_gap }, .tab_index = if (enabled) null else 0 }));
    defer input.deinit();
    if (enabled) input.processEvents();
    input.draw();
}

fn wizardLoading(src: std.builtin.SourceLocation, tag: []const u8, name: []const u8, loading: bool) void {
    const slot_size: dvui.Size = .{ .w = metrics.loading_diameter, .h = metrics.control_height };
    const slot = dvui.box(src, .{}, .{
        .id_extra = @as(usize, @truncate(std.hash.Wyhash.hash(0, tag))),
        .tag = fmt("{s}-slot", .{tag}),
        .min_size_content = slot_size,
        .max_size_content = .size(slot_size),
        .padding = R.all(0),
        .margin = .{ .h = if (dvui.windowRect().h < 480) theme.spacing.detail_gap else theme.spacing.row_gap },
        .border = R.all(0),
        .background = false,
        .role = .none,
        .tab_index = 0,
    });
    defer slot.deinit();
    if (loading) dvui.spinner(@src(), .{
        .tag = tag,
        .label = .{ .text = name },
        .role = .progress_indicator,
        .tab_index = 0,
        .min_size_content = dvui.Size.all(metrics.loading_diameter),
        .max_size_content = .size(dvui.Size.all(metrics.loading_diameter)),
        .gravity_y = 0.5,
        .padding = R.all(0),
        .margin = R.all(0),
        .border = R.all(0),
        .background = false,
        .color_text = .{ .color = theme.colors.muted },
    });
}

fn releaseDate(release_time: []const u8) []const u8 {
    if (release_time.len < 10 or release_time[4] != '-' or release_time[7] != '-') return release_time;
    return fmt("{s}/{s}/{s}", .{ release_time[0..4], release_time[5..7], release_time[8..10] });
}

fn wizardVersionRow(src: std.builtin.SourceLocation, key: []const u8, name: []const u8, release_time: []const u8, selected: bool, enabled: bool) bool {
    var control: dvui.ButtonWidget = undefined;
    control.init(src, .{ .grayed = !enabled, .draw_focus = enabled }, theme.panelButtonOptions(.{
        .id_extra = @as(usize, @truncate(std.hash.Wyhash.hash(0, key))),
        .tag = key,
        .label = .{ .text = name },
        .expand = .horizontal,
        .max_size_content = .width(0),
        .font = theme.fontSized(metrics.version_font),
        .min_size_content = .{ .h = metrics.card_height - 2 * metrics.card_padding_y - 2 },
        .padding = .{ .x = metrics.card_padding_x, .w = metrics.card_padding_x, .y = metrics.card_padding_y, .h = metrics.card_padding_y },
        .margin = R.all(0),
        .border = R.all(1),
        .corners = .all(theme.panelRadius()),
        .color_border = if (selected) .{ .color = theme.colors.accent } else null,
        .color_fill = .{ .color = theme.colors.surface },
        .color_fill_hover = .{ .color = if (enabled) theme.colors.selected_surface else theme.colors.surface },
        .color_fill_press = .{ .color = if (enabled) theme.style.colors.pressed_surface else theme.colors.surface },
        .tab_index = if (enabled) null else 0,
    }, false));
    defer control.deinit();
    wizardButtonState(&control, enabled, true);
    if (control.data().accesskit_node()) |node| dvui.AccessKit.nodeSetSelected(node, selected);
    {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .max_size_content = .width(0), .min_size_content = .{ .h = metrics.card_height - 2 * metrics.card_padding_y - 2 }, .padding = R.all(0), .margin = R.all(0), .background = false });
        defer row.deinit();
        {
            // Reserve the upper-right slot before measuring the expanding title.
            components.selectionCheck(@src(), .{
                .selected = selected,
                .enabled = enabled,
                .diameter = metrics.check_diameter,
                .icon_size = metrics.check_icon,
                .gap = metrics.card_gap,
                .gravity_y = 0.5,
                .slot_tag = fmt("{s}-check-slot", .{key}),
                .badge_tag = fmt("{s}-selected", .{key}),
                .icon_tag = fmt("{s}-check-icon", .{key}),
            });
        }
        const date = releaseDate(release_time);
        if (date.len > 0) dvui.labelNoFmt(@src(), date, .{}, .{ .tag = fmt("{s}-date", .{key}), .font = theme.captionFont(), .gravity_x = 1, .gravity_y = 0.5, .padding = R.all(0), .margin = .{ .w = theme.spacing.card_gap }, .color_text = .{ .color = theme.colors.muted }, .background = false });
        const details = dvui.box(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .gravity_y = 0.5, .padding = R.all(0), .margin = R.all(0), .background = false });
        defer details.deinit();
        const title = dvui.textLayout(@src(), .{ .break_lines = false }, theme.foregroundOptions(control.style()).override(.{ .tag = fmt("{s}-name", .{key}), .font = theme.headingFont(), .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = R.all(0), .background = false }));
        title.addText(components.ellipsize(name, theme.headingFont(), details.data().contentRect().w), .{});
        title.deinit();
    }
    return enabled and control.clicked();
}

fn wizardName(ui: *Ui, enabled: bool) void {
    const row = dvui.box(@src(), .{}, .{ .tag = "instance-wizard-name-row", .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = .{ .h = settingsGap() }, .background = false });
    defer row.deinit();
    dvui.labelNoFmt(@src(), "名称:", .{}, .{ .tag = "instance-wizard-name-label", .font = theme.bodyFont(), .padding = R.all(0), .margin = .{ .h = settingsLabelGap() }, .background = false });
    var input: dvui.TextEntryWidget = undefined;
    input.init(@src(), .{ .text = .{ .buffer = &ui.draft.name } }, components.entryOptions("名称", .{ .tag = "instance-wizard-name" }).override(.{ .expand = .horizontal, .max_size_content = .width(0), .margin = R.all(0), .tab_index = if (enabled) null else 0 }));
    defer input.deinit();
    if (enabled) input.processEvents();
    observeNameEdit(ui);
    if (ui.name_focus_pending and enabled) {
        if (ui.name_focus_layout_seen and dvui.minSizeGet(input.data().id) != null and input.data().rect.w > 0 and input.data().rect.h > 0) {
            dvui.focusWidget(input.data().id, null, null);
            input.textLayout.selection.selectAll();
            ui.name_focus_pending = false;
            ui.name_focus_requested = true;
        } else {
            ui.name_focus_layout_seen = true;
            dvui.refresh(null, @src(), input.data().id);
        }
    }
    input.draw();
}

fn wizardFooterButton(src: std.builtin.SourceLocation, name: []const u8, tag: []const u8, enabled: bool, primary: bool, width_limit: f32) bool {
    const font = theme.bodyFont();
    const available = dvui.parentGet().data().contentRect().w;
    var control: dvui.ButtonWidget = undefined;
    control.init(src, .{ .grayed = !enabled, .draw_focus = enabled }, theme.footerButtonOptions(name, width_limit).override(.{
        .tag = tag,
        .label = .{ .text = name },
        .rect = .{ .x = if (primary) @max(0, available - width_limit) else 0, .y = 0, .w = width_limit, .h = metrics.control_height },
        .style = if (primary and enabled) .highlight else .control,
        .color_fill = if (primary and enabled) null else .{ .color = theme.panelColor(theme.colors.surface) },
        .color_fill_hover = if (primary and enabled) null else .{ .color = theme.panelColor(if (enabled) theme.colors.selected_surface else theme.colors.surface) },
        .color_fill_press = if (primary and enabled) null else .{ .color = theme.panelColor(if (enabled) theme.colors.pressed_surface else theme.colors.surface) },
        .tab_index = if (enabled) null else 0,
    }));
    defer control.deinit();
    wizardButtonState(&control, enabled, !(primary and enabled));
    var label_style = theme.foregroundOptions(control.style());
    // Keep disabled labels readable after ButtonWidget averages grayed colors.
    if (!enabled) label_style.color_text = .{ .color = theme.colors.muted };
    const bounds = control.data().contentRect();
    const text_size = font.textSize(name);
    const label = dvui.textLayout(@src(), .{ .break_lines = false }, label_style.override(.{ .tag = fmt("{s}-label", .{tag}), .font = font, .rect = .{ .x = @max(0, (bounds.w - text_size.w) / 2), .y = @max(0, (bounds.h - text_size.h) / 2), .w = @min(bounds.w, text_size.w), .h = text_size.h }, .padding = R.all(0), .margin = R.all(0), .background = false }));
    label.addText(name, .{});
    label.deinit();
    return enabled and control.clicked();
}

fn drawWizardFooter(ui: *Ui, doc: *const config.Document, locked: bool) void {
    const footer = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .tag = "instance-wizard-footer",
        .expand = .horizontal,
        .max_size_content = .width(0),
        .gravity_y = 1,
        .min_size_content = .{ .h = metrics.control_height },
        .padding = R.all(0),
        .margin = .{ .y = theme.spacing.footer_gap },
        .background = false,
    });
    defer footer.deinit();
    const first = ui.create_step == .version;
    const previous_label = if (first) "取消" else "上一步";
    const button_width = theme.footerButtonWidth(footer.data().contentRect().w);
    if (wizardFooterButton(@src(), previous_label, if (first) "instance-wizard-cancel" else "instance-wizard-previous", !locked, false, button_width)) ui.queue(if (first) .close else .previous_step, null);
    const valid_name = valid: {
        validateName(doc, text(&ui.draft.name), null) catch break :valid false;
        break :valid true;
    };
    const ready = !locked and ui.draft.base != null and (ui.draft.loader == .vanilla or ui.draft.loader_version != null) and (ui.create_step != .confirm or valid_name);
    const label = switch (ui.create_step) {
        .version => "下一步",
        .loader => if (ui.draft.loader == .vanilla) "使用原版" else fmt("使用 {s}", .{loaderTitle(ui.draft.loader)}),
        .confirm => "安装",
    };
    if (wizardFooterButton(@src(), label, if (ui.create_step == .confirm) "instance-wizard-install" else "instance-wizard-next", ready, true, button_width)) ui.queue(if (ui.create_step == .confirm) .submit else .next_step, null);
}

fn drawAcquisition(ui: *Ui, doc: *const config.Document, manager: *manager_module.Manager, catalogue: library.Snapshot, enabled: bool) void {
    const state = manager.snapshot();
    const catalogue_busy = ui.create_step == .loader and manager.isBusy() and state.operation == .loading_loaders;
    const footer_locked = !enabled or ui.submitted or ui.navigation != null or (manager.isBusy() and !catalogue_busy) or state.phase == .awaiting_publication or ui.pending != null;
    const locked = footer_locked or catalogue_busy;
    {
        const header = dvui.box(@src(), .{ .dir = .horizontal }, .{ .tag = "instance-wizard-header", .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = .{ .h = theme.spacing.page_title_gap }, .background = false });
        defer header.deinit();
        dvui.labelNoFmt(@src(), switch (ui.create_step) {
            .version => "1/3",
            .loader => "2/3",
            .confirm => "3/3",
        }, .{}, .{ .tag = "instance-wizard-prefix", .role = .label, .tab_index = 0, .font = theme.titleFont(), .color_text = .{ .color = theme.colors.muted }, .gravity_y = 0.5, .padding = R.all(0), .margin = .{ .w = theme.spacing.row_gap }, .background = false });
        const title = dvui.textLayout(@src(), .{ .break_lines = true, .process_events_in_deinit = false }, .{ .tag = "instance-wizard-title", .role = .label, .tab_index = 0, .font = theme.titleFont(), .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = R.all(0), .background = false });
        title.addText(switch (ui.create_step) {
            .version => "选择 Minecraft 版本",
            .loader => "选择 Mod 加载器",
            .confirm => "创建实例",
        }, .{});
        title.deinit();
    }
    drawWizardFooter(ui, doc, footer_locked);
    if (!taskFailureOwned(ui) and ui.failure != null) {
        const validation = dvui.box(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .gravity_y = 1, .padding = R.all(0), .margin = R.all(0), .background = false });
        drawFormFailure(ui, "instance-wizard-validation");
        validation.deinit();
    }
    switch (ui.create_step) {
        .version => {
            {
                const filters = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .tag = "instance-version-filters", .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = .{ .h = theme.spacing.detail_gap }, .background = false });
                defer filters.deinit();
                const compact = filters.data().contentRect().w < 360;
                const filter_geometry = theme.filterGeometry(@max(0, filters.data().contentRect().w - metrics.loading_diameter), if (compact) &.{ "正式", "快照", "远古" } else &.{ "正式版", "快照版", "远古版" });
                inline for (.{ VersionFilter.release, VersionFilter.snapshot, VersionFilter.old }, .{ "正式版", "快照版", "远古版" }, .{ "正式", "快照", "远古" }) |filter, label, short_label| {
                    if (wizardTab(@src(), if (compact) short_label else label, "instance-version-filter-" ++ @tagName(filter), ui.version_filter == filter, !locked, filter_geometry.padding_x, filter_geometry.gap)) ui.version_filter = filter;
                }
                wizardLoading(@src(), "instance-version-loading", "正在获取官方版本列表", catalogue.phase == .loading);
            }
            wizardSearch(@src(), "搜索版本", "instance-version-search", &ui.search, !locked);
            const scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .tag = "instance-wizard-version-list", .expand = .both, .background = false, .padding = R.all(0), .margin = R.all(0), .border = R.all(0) });
            defer scroll.deinit();
            if (catalogue.failure) |err| {
                components.text(@src(), fmt("版本列表：{s}", .{@errorName(err)}), theme.colors.muted);
                if (components.button(@src(), "重试", .{ .standalone = true, .enabled = !locked })) ui.catalogue_requested = true;
            }
            if (ui.version_filter == .old) for (catalogue.available) |version| {
                if (std.mem.startsWith(u8, version.kind, "old_") and !supportedMinecraft(version.id)) {
                    components.hint(@src(), "远古版列出受支持的历史正式版；支持 Minecraft 1.7.10 及以上，早期 Alpha / Beta 版本暂不支持。");
                    break;
                }
            };
            var latest: ?[]const u8 = null;
            for (catalogue.available) |version| if (std.mem.eql(u8, version.kind, "release") and supportedMinecraft(version.id)) {
                latest = version.id;
                break;
            };
            var count: usize = 0;
            for (catalogue.available) |version| {
                if (!catalogueMatches(version.kind, ui.version_filter) or !supportedMinecraft(version.id) or !searchMatches(version.id, text(&ui.search))) continue;
                if (ui.version_filter == .old) if (latest) |id| if (std.mem.eql(u8, id, version.id)) continue;
                count += 1;
                const selected = if (ui.draft.base) |base| std.mem.eql(u8, base, version.id) else false;
                const key = fmt("instance-version-{s}", .{version.id});
                if (wizardVersionRow(@src(), key, version.id, version.release_time, selected, !locked)) ui.queue(.choose_base, version.id);
                _ = dvui.spacer(@src(), .{ .id_extra = @as(usize, @truncate(std.hash.Wyhash.hash(0, key))), .min_size_content = .{ .h = metrics.card_gap } });
            }
            if (count == 0 and catalogue.phase != .loading) components.text(@src(), if (catalogue.available.len == 0) "暂无版本，请刷新列表" else "没有匹配的版本", theme.colors.muted);
        },
        .loader => {
            const loaders = manager.loaderSnapshot();
            const matches = if (loaders.base) |base| ui.draft.base != null and std.mem.eql(u8, base, ui.draft.base.?) and loaders.kind == ui.browse_loader else false;
            {
                const kinds = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .tag = "instance-loader-kinds", .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = .{ .h = theme.spacing.detail_gap }, .background = false });
                defer kinds.deinit();
                const filter_geometry = theme.filterGeometry(@max(0, kinds.data().contentRect().w - metrics.loading_diameter), &.{ "Fabric", "Forge", "NeoForge", "Quilt" });
                inline for (.{ config.Loader.fabric, config.Loader.forge, config.Loader.neoforge, config.Loader.quilt }) |kind| {
                    if (wizardTab(@src(), loaderTitle(kind), "instance-loader-kind-" ++ @tagName(kind), ui.browse_loader == kind, !locked, filter_geometry.padding_x, filter_geometry.gap)) {
                        ui.queue(.choose_loader_kind, null);
                        if (ui.pending) |*p| p.kind = kind;
                    }
                }
                wizardLoading(@src(), "instance-loader-loading", "正在读取加载器版本", matches and loaders.phase == .working);
            }
            wizardSearch(@src(), "搜索加载器版本", "instance-loader-search", &ui.loader_search, !locked);
            const scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .tag = "instance-wizard-loader-list", .expand = .both, .background = false, .padding = R.all(0), .margin = R.all(0), .border = R.all(0) });
            defer scroll.deinit();
            if (matches) if (loaders.failure) |err| {
                if (err != error.NonPublicAddress) {
                    components.text(@src(), fmt("加载器目录：{s}", .{@errorName(err)}), theme.colors.muted);
                    if (components.button(@src(), "重试", .{ .standalone = true, .enabled = !locked })) {
                        ui.queue(.load_loaders, null);
                        if (ui.pending) |*p| p.force_refresh = true;
                    }
                }
            };
            var count: usize = 0;
            if (matches) for (loaders.entries) |loader| {
                if (!searchMatches(loader.id, text(&ui.loader_search))) continue;
                count += 1;
                const selected = ui.draft.loader == ui.browse_loader and if (ui.draft.loader_version) |version| std.mem.eql(u8, version, loader.id) else false;
                const key = fmt("instance-loader-{s}-{s}", .{ @tagName(ui.browse_loader), loader.id });
                if (wizardVersionRow(@src(), key, loader.id, loader.release_time, selected, !locked)) {
                    ui.queue(.choose_loader, loader.id);
                    if (ui.pending) |*p| p.kind = ui.browse_loader;
                }
                _ = dvui.spacer(@src(), .{ .id_extra = @as(usize, @truncate(std.hash.Wyhash.hash(0, key))), .min_size_content = .{ .h = metrics.card_gap } });
            };
            if (count == 0 and loaders.phase != .working) components.text(@src(), if (matches and loaders.entries.len != 0) "没有匹配的版本" else "此 Minecraft 版本暂无可用加载器版本，可继续使用原版。", theme.colors.muted);
        },
        .confirm => {
            const scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .tag = "instance-wizard-confirm-body", .expand = .both, .background = false, .padding = R.all(0), .margin = R.all(0), .border = R.all(0) });
            defer scroll.deinit();
            wizardName(ui, !locked);
            validateName(doc, text(&ui.draft.name), null) catch |err| components.text(@src(), switch (err) {
                error.DuplicateInstanceName => "同名实例已存在，请选择其他名称。",
                else => "请输入有效的实例名称，不能包含路径分隔符或保留名称。",
            }, theme.colors.danger);
            const summary_inset_y = if (dvui.windowRect().h < 480 or scroll.data().contentRect().w < 360) theme.spacing.panel_compact_padding else theme.spacing.panel_padding;
            const summary = theme.panel(@src(), .{}, .{
                .tag = "instance-wizard-summary-card",
                .expand = .horizontal,
                .max_size_content = .width(0),
                .padding = .{ .x = theme.spacing.panel_padding, .w = theme.spacing.panel_padding, .y = summary_inset_y, .h = summary_inset_y },
                .margin = R.all(0),
                .border = R.all(1),
                .corners = .all(theme.panelRadius()),
                .background = true,
                .color_fill = .{ .color = theme.panelColor(theme.colors.surface) },
            });
            defer summary.deinit();
            wizardSummary(@src(), "instance-wizard-summary-minecraft", fmt("Minecraft: {s}", .{ui.draft.base orelse ""}));
            wizardSummary(@src(), "instance-wizard-summary-loader", if (ui.draft.loader == .vanilla) "Mod Loader: 不使用 Mod 加载器" else fmt("Mod Loader: {s} {s}", .{ loaderTitle(ui.draft.loader), ui.draft.loader_version orelse "" }));
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = theme.spacing.row_gap } });
            const preview_matches = if (ui.java_preview.version) |version| ui.draft.base != null and std.mem.eql(u8, version, ui.draft.base.?) else false;
            if (preview_matches and ui.java_preview.java_major != null) {
                wizardSummary(@src(), "instance-wizard-summary-java", fmt("目标 Java 版本: {d}", .{ui.java_preview.java_major.?}));
            } else {
                wizardSummary(@src(), "instance-wizard-summary-java", if (preview_matches and ui.java_preview.phase == .failed) "目标 Java 版本: 暂时无法读取" else "目标 Java 版本: 正在读取…");
            }
        },
    }
}

fn wizardSummary(src: std.builtin.SourceLocation, tag: []const u8, value: []const u8) void {
    const line = dvui.textLayout(src, .{ .break_lines = true, .process_events_in_deinit = false }, .{
        .tag = tag,
        .label = .{ .text = value },
        .role = .label,
        .tab_index = 0,
        .font = theme.fontSized(metrics.control_font),
        .expand = .horizontal,
        .max_size_content = .width(0),
        .color_text = .{ .color = theme.colors.muted },
        .padding = R.all(0),
        .margin = .{ .h = theme.spacing.row_gap },
        .background = false,
    });
    defer line.deinit();
    line.addText(value, .{});
}

fn javaChoice(path: []const u8, registered_java: []const java_module.Runtime) ?usize {
    if (path.len == 0) return 0;
    for (registered_java, 0..) |runtime, index| if (std.mem.eql(u8, path, runtime.path)) return index + 1;
    return null;
}

fn chooseJava(draft: *Draft, registered_java: []const java_module.Runtime, choice: usize) !void {
    if (choice == 0) return setText(&draft.java_path, "");
    if (choice > registered_java.len) return error.JavaNotRegistered;
    const path = registered_java[choice - 1].path;
    if (!validText(path, false)) return error.InvalidJavaPath;
    // Registry commits replace its arena; only draft-owned bytes outlive this frame.
    try setText(&draft.java_path, path);
}

fn settingsGap() f32 {
    return if (dvui.windowRect().h < 480) theme.spacing.compact_field_gap else theme.spacing.field_gap;
}

fn settingsLabelGap() f32 {
    return if (dvui.windowRect().h < 480) theme.spacing.compact_label_gap else theme.spacing.field_label_gap;
}

fn settingsFieldLabel(src: std.builtin.SourceLocation, name: []const u8, tag: []const u8) void {
    const label = dvui.textLayout(src, .{}, .{ .tag = tag, .role = .label, .tab_index = 0, .font = theme.bodyFont(), .expand = .horizontal, .max_size_content = .width(0), .background = false, .padding = R.all(0), .margin = .{ .h = settingsLabelGap() } });
    label.addText(name, .{});
    label.deinit();
}

fn javaPicker(ui: *Ui, src: std.builtin.SourceLocation, registered_java: []const java_module.Runtime, enabled: bool) void {
    settingsFieldLabel(src, "Java", "instance-settings-java-label");
    const choice = javaChoice(text(&ui.draft.java_path), registered_java);
    const label = if (choice) |index| if (index == 0) "自动选择" else fmt("Java {d} · {s}", .{ registered_java[index - 1].major, registered_java[index - 1].vendor }) else "保留现有 Java 绑定";
    // A disabled picker keeps the dropdown line leading, not TextEntry glyph padding.
    const control_options = theme.controlOptions(@max(theme.bodyFont().lineHeight(), theme.bodyFont().textSize(label).h));
    if (enabled) {
        var picker: dvui.DropdownWidget = undefined;
        picker.init(src, .{ .selected_index = choice, .label = if (choice != null) label else null, .placeholder = "保留现有 Java 绑定" }, control_options.override(.{ .tag = "instance-settings-java", .label = .{ .text = "Java" }, .expand = .horizontal, .min_size_content = .{ .h = theme.sizing.control_height }, .max_size_content = .width(0), .id_extra = 1, .margin = R.all(0) }));
        defer picker.deinit();
        dvui.tag("instance-settings-java-control", .{ .id = picker.menuItem.data().id, .rect = picker.menuItem.data().borderRectScale().r, .visible = picker.menuItem.data().visible() });
        if (dvui.focusedWidgetId() == picker.menuItem.data().id) {
            ui.form_focus = @backingInt(picker.menuItem.data().id);
            ui.form_subwindow = @backingInt(dvui.focusedSubwindowId());
        }
        if (picker.dropped()) {
            if (picker.addChoiceLabel("自动选择")) chooseJava(&ui.draft, registered_java, 0) catch |err| {
                ui.failure = err;
            };
            for (registered_java, 0..) |runtime, index| {
                if (picker.addChoiceLabel(fmt("Java {d} · {s}", .{ runtime.major, runtime.vendor }))) chooseJava(&ui.draft, registered_java, index + 1) catch |err| {
                    ui.failure = err;
                };
            }
        }
    } else {
        // DropdownWidget.init processes events itself; a disabled control must not call it.
        var control: dvui.ButtonWidget = undefined;
        control.init(src, .{ .grayed = true, .draw_focus = false }, control_options.override(.{ .tag = "instance-settings-java", .label = .{ .text = "Java" }, .expand = .horizontal, .max_size_content = .width(0), .id_extra = 1, .role = .combo_box, .tab_index = 0, .margin = R.all(0) }));
        dvui.tag("instance-settings-java-control", .{ .id = control.data().id, .rect = control.data().borderRectScale().r, .visible = control.data().visible() });
        defer control.deinit();
        wizardButtonState(&control, false, false);
        dvui.labelNoFmt(@src(), label, .{}, control.style().override(.{ .font = theme.bodyFont(), .color_text = .{ .color = theme.colors.muted }, .padding = R.all(0), .margin = .{ .w = theme.spacing.row_gap }, .gravity_y = 0.5, .expand = .horizontal, .background = false }));
        dvui.icon(@src(), "dropdown_triangle", dvui.entypo.chevron_small_down, .{}, control.style().override(.{ .gravity_x = 1, .gravity_y = 0.5, .padding = R.all(0), .margin = R.all(0), .role = .none, .background = false }));
    }
    if (choice == null) components.text(@src(), if (std.mem.eql(u8, text(&ui.draft.java_path), text(&ui.draft.original_java_path))) "已保存的 Java 不在已登记列表中（可能已隐藏或移除）。保留现有绑定，或选择已登记的运行时。" else "所选 Java 已不在已登记列表中（可能已隐藏或移除）。保留当前选择，或重新选择运行时。", theme.colors.muted);
    if (registered_java.len == 0) components.text(@src(), "暂无已登记的 Java，请先在 Java 管理中添加。", theme.colors.muted);
}

fn installedEntry(ui: *Ui, src: std.builtin.SourceLocation, name: []const u8, tag: []const u8, buffer: []u8, numeric: bool, enabled: bool) void {
    settingsFieldLabel(src, name, fmt("{s}-label", .{tag}));
    var input: dvui.TextEntryWidget = undefined;
    input.init(src, .{ .text = .{ .buffer = buffer } }, components.entryOptions(name, .{ .tag = tag, .gap_after = 0 }).override(.{ .id_extra = 1, .tab_index = if (enabled) null else 0, .color_text = if (enabled) null else .{ .color = theme.colors.muted } }));
    defer input.deinit();
    if (!enabled) if (input.data().accesskit_node()) |node| dvui.AccessKit.nodeSetDisabled(node);
    if (enabled) input.processEvents();
    if (numeric and enabled) input.filterIn("0123456789");
    input.draw();
    if (enabled and dvui.focusedWidgetId() == input.data().id) {
        ui.form_focus = @backingInt(input.data().id);
        ui.form_subwindow = @backingInt(dvui.focusedSubwindowId());
    }
}

fn installedDebug(ui: *Ui, src: std.builtin.SourceLocation, enabled: bool) void {
    var control: dvui.ButtonWidget = undefined;
    control.init(src, .{ .grayed = !enabled, .draw_focus = enabled }, .{ .tag = "instance-settings-debug", .label = .{ .text = "调试启动" }, .role = .ak_switch, .expand = .horizontal, .gravity_y = 0.5, .max_size_content = .width(0), .min_size_content = .{ .h = metrics.control_height }, .padding = R.all(0), .border = R.all(0), .margin = R.all(0), .background = false, .tab_index = if (enabled) null else 0 });
    defer control.deinit();
    wizardButtonState(&control, enabled, false);
    if (enabled and control.clicked()) ui.draft.debug_launch = !ui.draft.debug_launch;
    if (control.data().accesskit_node()) |node| dvui.AccessKit.nodeSetToggled(node, if (ui.draft.debug_launch) .ak_true else .ak_false);
    dvui.labelNoFmt(@src(), "调试启动", .{}, .{ .tag = "instance-settings-debug-label", .font = theme.bodyFont(), .expand = .horizontal, .gravity_y = 0.5, .max_size_content = .width(0), .padding = R.all(0), .margin = .{ .w = theme.sizing.switch_width + theme.spacing.row_gap }, .color_text = if (enabled) null else .{ .color = theme.colors.muted }, .role = .none, .tab_index = 0 });
    const track = dvui.box(@src(), .{}, .{ .tag = "instance-settings-debug-switch", .rect = .{ .x = @max(0, control.data().contentRect().w - theme.sizing.switch_width), .y = (metrics.control_height - theme.sizing.switch_height) / 2, .w = theme.sizing.switch_width, .h = theme.sizing.switch_height }, .padding = R.all(0), .margin = R.all(0), .corners = .all(theme.sizing.switch_height / 2), .border = R.all(0), .background = true, .color_fill = .{ .color = if (ui.draft.debug_launch) theme.colors.accent else theme.colors.muted }, .role = .none, .tab_index = 0 });
    const knob = dvui.box(@src(), .{}, .{ .tag = "instance-settings-debug-knob", .rect = .{ .x = if (ui.draft.debug_launch) theme.sizing.switch_width - theme.sizing.switch_inset - theme.sizing.switch_knob else theme.sizing.switch_inset, .y = theme.sizing.switch_inset, .w = theme.sizing.switch_knob, .h = theme.sizing.switch_knob }, .padding = R.all(0), .margin = R.all(0), .background = true, .border = R.all(0), .corners = .all(theme.sizing.switch_knob / 2), .color_fill = .{ .color = theme.colors.foreground }, .role = .none, .tab_index = 0 });
    knob.deinit();
    track.deinit();
    if (enabled and dvui.focusedWidgetId() == control.data().id) {
        ui.form_focus = @backingInt(control.data().id);
        ui.form_subwindow = @backingInt(dvui.focusedSubwindowId());
    }
}

fn drawSettingsFooter(ui: *Ui, enabled: bool) void {
    const footer = dvui.box(@src(), .{ .dir = .horizontal }, .{ .tag = "instance-settings-footer", .expand = .horizontal, .max_size_content = .width(0), .gravity_y = 1, .min_size_content = .{ .h = metrics.control_height }, .padding = R.all(0), .margin = .{ .y = theme.spacing.footer_gap }, .background = false });
    defer footer.deinit();
    const labels: components.FormOptions = .{};
    const width = theme.footerButtonWidth(footer.data().contentRect().w);
    if (wizardFooterButton(@src(), labels.cancel_label, "instance-settings-cancel", enabled, false, width)) ui.queue(.close, null);
    if (wizardFooterButton(@src(), labels.save_label, "instance-settings-save", enabled, true, width)) ui.queue(.submit, null);
}

fn settingsMode(mode: Mode) bool {
    return mode == .options or mode == .delete_confirm;
}

fn closeDeleteConfirmation(ui: *Ui) void {
    ui.mode = .options;
    ui.restore_form_focus = true;
}

fn deleteDismissalAllowed(ui: *const Ui) bool {
    return ui.mode == .delete_confirm and !ui.delete_confirmation_locked and
        !ui.submitted and ui.pending == null and ui.navigation == null;
}

fn deleteConfirmationAllowed(ui: *const Ui, enabled: bool) bool {
    return enabled and deleteDismissalAllowed(ui);
}

fn durabilityMessage(operation: manager_module.Operation) []const u8 {
    return switch (operation) {
        .deleting => "删除已完成，但文件同步状态不确定。请检查实例目录，勿重复执行删除。",
        .renaming => "重命名已提交，但文件同步状态不确定；请保留恢复目录，勿重复执行。",
        else => "文件操作已提交，但文件同步状态不确定；请检查相关目录，勿重复执行。",
    };
}

fn deleteModalButton(src: std.builtin.SourceLocation, name: []const u8, tag: []const u8, enabled: bool, primary: bool, width: f32, focus_on_entry: bool) bool {
    const font = theme.bodyFont();
    const available = dvui.parentGet().data().contentRect().w;
    var control: dvui.ButtonWidget = undefined;
    control.init(src, .{ .grayed = !enabled, .draw_focus = enabled }, theme.footerButtonOptions(name, width).override(.{
        .tag = tag,
        .label = .{ .text = name },
        .rect = .{ .x = if (primary) @max(0, available - width) else 0, .y = 0, .w = width, .h = metrics.control_height },
        .style = if (primary and enabled) .highlight else .control,
        .tab_index = if (enabled) null else 0,
    }));
    defer control.deinit();
    if (enabled and focus_on_entry) dvui.focusWidget(control.data().id, null, null);
    wizardButtonState(&control, enabled, false);
    var label_style = theme.foregroundOptions(control.style());
    if (!enabled) label_style.color_text = .{ .color = theme.colors.muted };
    const bounds = control.data().contentRect();
    const text_size = font.textSize(name);
    const label = dvui.textLayout(@src(), .{ .break_lines = false }, label_style.override(.{ .tag = fmt("{s}-label", .{tag}), .font = font, .rect = .{ .x = @max(0, (bounds.w - text_size.w) / 2), .y = @max(0, (bounds.h - text_size.h) / 2), .w = @min(bounds.w, text_size.w), .h = text_size.h }, .padding = R.all(0), .margin = R.all(0), .background = false }));
    label.addText(name, .{});
    label.deinit();
    return enabled and control.clicked();
}

fn deleteModalText(src: std.builtin.SourceLocation, tag: []const u8, message: []const u8, heading: bool) void {
    const layout = dvui.textLayout(src, .{}, .{
        .tag = tag,
        .role = .label,
        .tab_index = 0,
        .font = if (heading) theme.headingFont() else theme.bodyFont(),
        .color_text = .{ .color = if (heading) theme.colors.accent else theme.colors.muted },
        .expand = .horizontal,
        .max_size_content = .width(0),
        .padding = R.all(0),
        .margin = .{ .h = theme.spacing.card_gap },
        .background = false,
    });
    layout.addText(message, .{});
    layout.deinit();
}

fn drawDeleteConfirmation(ui: *Ui, enabled: bool) void {
    const modal = components.modalPanel(@src(), "永久删除实例", theme.style.dialogs.instance_delete_height, null);
    const content_size = modal.data().contentRect().size();
    defer modal.deinit();
    dvui.tag("instance-delete-confirm-modal", .{ .id = modal.data().id, .rect = modal.data().borderRectScale().r, .visible = modal.data().visible() });
    const first_frame = dvui.firstFrame(modal.data().id);
    for (dvui.events()) |*event| {
        if (!dvui.eventMatch(event, .{ .id = modal.data().id, .focus_id = dvui.focusedWidgetIdInCurrentSubwindow(), .r = modal.data().rectScale().r })) continue;
        if (event.evt == .key and event.evt.key.action == .down and event.evt.key.code == .escape) {
            event.handle(@src(), modal.data());
            if (deleteDismissalAllowed(ui)) {
                ui.queue(.close, null);
                // State settles after rendering; request a frame without the closed modal.
                dvui.refresh(null, @src(), modal.data().id);
            }
        }
    }
    // Reserve the action row before the body so a small viewport can scroll the warning.
    {
        const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .tag = "instance-delete-confirm-actions",
            .expand = .horizontal,
            .gravity_y = 1,
            .min_size_content = .{ .h = metrics.control_height },
            .max_size_content = .{ .w = content_size.w, .h = metrics.control_height },
            .padding = R.all(0),
            .margin = .{ .y = theme.style.dialogs.footer_gap },
            .background = false,
        });
        defer actions.deinit();
        const button_width = @min(theme.style.dialogs.action_width, theme.footerButtonWidth(actions.data().contentRect().w));
        if (deleteModalButton(@src(), "取消删除", "instance-delete-confirm-cancel", deleteDismissalAllowed(ui), false, button_width, first_frame)) ui.queue(.close, null);
        if (deleteModalButton(@src(), "永久删除", "instance-delete-confirm-submit", deleteConfirmationAllowed(ui, enabled), true, button_width, false)) ui.queue(.confirm, null);
    }
    const body = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{
        .tag = "instance-delete-confirm-body",
        .expand = .both,
        .padding = R.all(0),
        .margin = R.all(0),
        .border = R.all(0),
        .background = false,
    });
    defer body.deinit();
    components.modalTitle(@src(), "永久删除实例", "instance-delete-confirm-title");
    const information = components.modalSection(@src(), .{ .min_height = 204, .gap_after = 0, .tag = "instance-delete-confirm-information" });
    defer information.deinit();
    deleteModalText(@src(), "instance-delete-confirm-warning", fmt("实例「{s}」目录内的存档、Mod 和配置将永久删除，无法恢复。", .{text(&ui.draft.original_name)}), false);
    deleteModalText(@src(), "instance-delete-confirm-servers", "绑定服务器将保留，仅解除与此实例的绑定。共享 Minecraft 资源、其他实例和外部服务器文件不受影响。", false);
    if (ui.failure) |err| deleteModalText(@src(), "instance-delete-confirm-failure", fmt("操作失败：{s}", .{failureMessage(err)}), false);
}

/// Synchronize globally before drawModal; presentation owns all retained text.
pub fn syncTaskSnapshot(ui: *Ui, snapshot: manager_module.Snapshot) void {
    ui.task.observe(ui.allocator, snapshot) catch |err| {
        ui.failure = err;
    };
    const current = ui.task.task_id != null and ui.task.task_id == snapshot.task_id;
    ui.task_can_cancel = current and snapshot.phase == .working;
    ui.task_can_retry = current and snapshot.phase == .awaiting_publication and ui.publication_failed;
    if (current and snapshot.phase == .awaiting_publication and ui.publication_failed) ui.task.failure = ui.failure;
}

fn taskFailureOwned(ui: *const Ui) bool {
    return ui.failure != null and ui.task.available() and ui.failure == ui.task.failure;
}

fn taskOperation(operation: manager_module.Operation) []const u8 {
    return switch (operation) {
        .creating => "安装实例",
        .renaming => "重命名实例",
        .deleting => "永久删除实例",
        else => "实例任务",
    };
}

fn taskStatus(ui: *const Ui) []const u8 {
    return switch (ui.task.phase) {
        .idle => "等待开始",
        .working => if (ui.task.operation == .deleting) "正在永久删除实例。" else "处理中",
        .awaiting_publication => if (ui.task.operation == .deleting) (if (ui.publication_failed) "实例文件已删除，保存配置失败。" else "实例文件已删除，等待保存配置。") else if (ui.publication_failed) "文件操作已完成，保存配置失败。" else "文件操作已完成，等待保存配置。",
        .failed => if (ui.task.admission_failure) "任务未能启动。" else "任务失败。",
        .canceled => "操作已取消。",
        .complete => switch (ui.task.operation) {
            .creating => "实例安装已完成。",
            .renaming => "实例已重命名。",
            .deleting => if (ui.task.durability_uncertain) "实例删除已完成，但文件同步状态不确定；服务器已保留并解除绑定。" else "实例已永久删除，服务器已保留并解除绑定。",
            else => "操作已完成。",
        },
    };
}

fn taskStage(stage: @import("../core/tasks.zig").Stage) []const u8 {
    return switch (stage) {
        .queued => "等待",
        .metadata => "读取元数据",
        .downloading => "下载文件",
        .verifying => "校验文件",
        .extracting => "解压文件",
        .installing => "安装",
        .scanning => "扫描",
        .backing_up => "备份",
        .restoring => "恢复",
        .copying => "复制",
        .finalizing => "完成文件操作",
    };
}

fn drawFormFailure(ui: *const Ui, tag: []const u8) void {
    if (taskFailureOwned(ui)) return;
    const err = ui.failure orelse return;
    if (err == error.Canceled) return;
    const layout = dvui.textLayout(@src(), .{}, .{ .tag = tag, .role = .label, .tab_index = 0, .font = theme.bodyFont(), .expand = .horizontal, .max_size_content = .width(0), .color_text = .{ .color = theme.colors.danger }, .padding = R.all(0), .margin = .{ .h = theme.spacing.detail_gap }, .background = false });
    layout.addText(failureMessage(err), .{});
    layout.deinit();
}

fn taskFont() dvui.Font {
    return theme.bodyFont();
}

fn taskLabel(src: std.builtin.SourceLocation, tag: []const u8, value: []const u8, heading: bool) void {
    dvui.labelNoFmt(src, value, .{ .ellipsize = true }, .{
        .tag = tag,
        .label = .{ .text = value },
        .font = if (heading) theme.headingFont() else taskFont(),
        .color_text = .{ .color = theme.colors.muted },
        .expand = .horizontal,
        .max_size_content = .width(0),
        .padding = R.all(0),
        .margin = .{ .h = theme.spacing.row_gap },
        .background = false,
        .tab_index = 0,
    });
}

fn taskText(src: std.builtin.SourceLocation, tag: []const u8, value: []const u8) void {
    const layout = dvui.textLayout(src, .{}, .{
        .tag = tag,
        .label = .{ .text = value },
        .role = .label,
        .tab_index = 0,
        .font = taskFont(),
        .color_text = .{ .color = theme.colors.muted },
        .expand = .horizontal,
        .max_size_content = .width(0),
        .padding = R.all(0),
        .margin = .{ .h = 3 },
        .background = false,
    });
    layout.addText(value, .{});
    layout.deinit();
}

fn taskError(err: anyerror) []const u8 {
    return fmt("原因：{s}\n错误代码：{s}", .{ if (std.mem.eql(u8, failureMessage(err), @errorName(err))) "任务未完成，请检查网络连接、磁盘空间与实例目录。" else failureMessage(err), @errorName(err) });
}

fn drawTaskPopup(ui: *Ui, _: bool) void {
    const deleting = ui.task.operation == .deleting;
    const delete_error = ui.task.failure != null or ui.task.durability_uncertain or ui.task.recovery_directory != null or ui.task_can_retry;
    const height = if (deleting) (if (delete_error) theme.style.dialogs.instance_delete_task_error_height else theme.style.dialogs.instance_delete_task_height) else if (ui.task.failure != null) theme.style.dialogs.task_failed_height else theme.style.dialogs.task_height;
    const modal = components.modalPanel(@src(), "实例任务详情", height, null);
    const content_size = modal.data().contentRect().size();
    defer modal.deinit();
    dvui.tag("instance-task-modal", .{ .id = modal.data().id, .rect = modal.data().borderRectScale().r, .visible = modal.data().visible() });
    for (dvui.events()) |*event| {
        if (!dvui.eventMatch(event, .{ .id = modal.data().id, .focus_id = dvui.focusedWidgetIdInCurrentSubwindow(), .r = modal.data().rectScale().r })) continue;
        if (event.evt == .key and event.evt.key.action == .down and event.evt.key.code == .escape) {
            // The running task stays in front until its explicit cancellation.
            event.handle(@src(), modal.data());
        }
    }
    {
        const footer = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .tag = "instance-task-footer",
            .expand = .horizontal,
            .gravity_y = 1,
            .min_size_content = .{ .h = metrics.control_height },
            .max_size_content = .{ .w = content_size.w, .h = metrics.control_height },
            .padding = R.all(0),
            .margin = .{ .y = theme.style.dialogs.footer_gap },
            .background = false,
        });
        defer footer.deinit();
        const button_width = @min(theme.style.dialogs.task_action_width, footer.data().contentRect().w);
        const unfinished = ui.task.phase == .working or ui.task.phase == .awaiting_publication;
        const allowed = ui.pending == null and (!unfinished or ui.task_can_cancel);
        const finished_install = ui.task.operation == .creating and ui.task.phase == .complete;
        if (deleteModalButton(@src(), if (unfinished) "取消" else if (finished_install) "完成" else "关闭", if (unfinished) "instance-task-cancel" else "instance-task-close", allowed, true, button_width, dvui.firstFrame(modal.data().id))) ui.queue(if (unfinished) .cancel else .close_task, null);
    }
    const body = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{
        .tag = "instance-task-body",
        .expand = .both,
        .max_size_content = .width(0),
        .padding = R.all(0),
        .margin = R.all(0),
        .border = R.all(0),
        .background = false,
    });
    defer body.deinit();
    components.modalTitle(@src(), fmt("{s} · {s}", .{ taskOperation(ui.task.operation), ui.task.instance_name orelse "未知实例" }), "instance-task-operation");
    if (deleting) {
        // Deletion has no useful transfer telemetry; keep its result and recovery actions.
        taskText(@src(), "instance-task-status", taskStatus(ui));
        if (ui.task.failure) |err| if (err != error.Canceled) taskText(@src(), "instance-task-failure", taskError(err));
        if (ui.task_can_retry and components.button(@src(), "重试保存配置", .{ .tag = "instance-task-retry", .enabled = ui.pending == null })) ui.queue(.retry_publication, null);
        if (ui.task.durability_uncertain) taskText(@src(), "instance-task-durability", durabilityMessage(ui.task.operation));
        if (ui.task.recovery_directory) |path| taskText(@src(), "instance-task-recovery", fmt("恢复目录：{s}", .{path}));
        return;
    }
    const details = &ui.task.details;
    {
        const summary = components.modalSection(@src(), .{ .min_height = 132, .tag = "instance-task-summary" });
        defer summary.deinit();
        taskLabel(@src(), "instance-task-status", fmt("{s} · {s}", .{ taskStatus(ui), taskStage(ui.task.details.stage) }), true);
        if (task_view.percent(details.completed, details.total)) |p| {
            taskLabel(@src(), "instance-task-progress", fmt("总体进度：{d}/{d} · {d:.1}%", .{ details.completed, details.total.?, p }), false);
        } else taskLabel(@src(), "instance-task-progress", fmt("总体进度：{d} · 总量未知", .{details.completed}), false);
        {
            const transfer = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = R.all(0), .background = false });
            defer transfer.deinit();
            var received_buffer: [64]u8 = undefined;
            var total_buffer: [64]u8 = undefined;
            var speed_buffer: [64]u8 = undefined;
            const received = task_view.formatBytes(&received_buffer, details.received) catch "—";
            const bytes = if (details.total_bytes) |total| fmt("传输：{s}/{s}", .{ received, task_view.formatBytes(&total_buffer, total) catch "—" }) else fmt("传输：{s}", .{received});
            taskLabel(@src(), "instance-task-bytes", bytes, false);
            const transfer_active = ui.task.phase == .working and (details.stage == .downloading or details.stage == .metadata);
            const speed = fmt("速度：{s}", .{task_view.formatSpeed(&speed_buffer, details.bytes_per_second, transfer_active) catch "—"});
            dvui.labelNoFmt(@src(), speed, .{ .ellipsize = true }, .{
                .tag = "instance-task-speed",
                .label = .{ .text = speed },
                .font = taskFont(),
                .color_text = .{ .color = theme.colors.muted },
                .expand = .none,
                .padding = R.all(0),
                .margin = .{ .x = 8, .h = 3 },
                .background = false,
                .tab_index = 0,
            });
        }
        if (ui.task.failure) |err| if (err != error.Canceled) taskText(@src(), "instance-task-failure", taskError(err));
        if (ui.task_can_retry and components.button(@src(), "重试保存配置", .{ .tag = "instance-task-retry", .enabled = ui.pending == null })) ui.queue(.retry_publication, null);
        if (ui.task.durability_uncertain) taskText(@src(), "instance-task-durability", durabilityMessage(ui.task.operation));
        if (ui.task.recovery_directory) |path| taskText(@src(), "instance-task-recovery", fmt("恢复目录：{s}", .{path}));
    }
    const file_height = if (ui.task.failure != null) theme.style.dialogs.task_failed_files_height else theme.style.dialogs.task_files_height;
    const file_panel = components.modalSection(@src(), .{ .min_height = file_height, .gap_after = 0, .tag = "instance-task-files-panel" });
    defer file_panel.deinit();
    const files = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{
        .tag = "instance-task-files",
        .expand = .horizontal,
        .min_size_content = .height(file_height - 2 * theme.spacing.panel_compact_padding),
        .max_size_content = .{ .w = 0, .h = file_height - 2 * theme.spacing.panel_compact_padding },
        .padding = R.all(0),
        .margin = R.all(0),
        .border = R.all(0),
        .background = false,
    });
    defer files.deinit();
    for (details.files[0..@min(details.file_count, details.files.len)], 0..) |*file, index| {
        const row = dvui.box(@src(), .{}, .{ .id_extra = index, .tag = fmt("instance-task-file-{d}", .{index}), .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = .{ .h = 8 }, .background = false });
        defer row.deinit();
        taskLabel(@src(), fmt("instance-task-file-name-{d}", .{index}), task_view.basename(if (file.path().len > 0) file.path() else file.name()), false);
        dvui.progress(@src(), .{ .percent = task_view.fraction(file.received, file.total), .color = theme.colors.accent }, .{
            .tag = fmt("instance-task-file-progress-{d}", .{index}),
            .label = .{ .text = if (details.stage == .verifying) "文件校验进度" else "文件下载进度" },
            .expand = .horizontal,
            .min_size_content = .height(theme.style.feedback.progress_height),
            .max_size_content = .{ .w = 0, .h = theme.style.feedback.progress_height },
            .padding = R.all(0),
            .margin = R.all(0),
            .border = R.all(0),
            .corners = .all(2),
            .color_fill = .{ .color = theme.colors.inset },
            .tab_index = 0,
        });
        if (file.failure) |err| if (err != error.Canceled and (ui.task.failure == null or ui.task.failure.? != err)) taskText(@src(), fmt("instance-task-file-failure-{d}", .{index}), taskError(err));
    }
    if (details.file_count == 0) taskText(@src(), "instance-task-no-files", "暂无文件详情。");
    if (details.omitted_files > 0) taskText(@src(), "instance-task-omitted", fmt("另有 {d} 个文件未显示，优先显示当前任务，其余为最近完成的文件。", .{details.omitted_files}));
}

/// Draw after page roots close; transitions remain deferred to finish.
pub fn drawModal(ui: *Ui, enabled: bool) void {
    if (ui.task.visible and ui.task.available()) {
        drawTaskPopup(ui, enabled);
        return;
    }
    if (ui.restore_form_focus) {
        ui.restore_form_focus = false;
        if (ui.form_subwindow) |id| dvui.focusSubwindow(@fromBackingInt(@intCast(id)), null);
        if (ui.form_focus) |id| dvui.focusWidget(@fromBackingInt(@intCast(id)), if (ui.form_subwindow) |s| @fromBackingInt(@intCast(s)) else null, null);
    }
    if (!ui.navigation_prompt) {
        if (ui.mode == .delete_confirm and !ui.submitted) drawDeleteConfirmation(ui, enabled);
        return;
    }
    const dialog = components.modal(@src(), "实例未保存更改确认", theme.style.dialogs.unsaved_height);
    defer dialog.deinit();
    {
        const actions = components.modalActions(@src(), 3);
        defer actions.deinit();
        const allowed = enabled and ui.pending == null and !ui.submitted;
        if (actions.action(@src(), 0, "保存并继续", .{ .enabled = allowed })) ui.queue(.save_navigation, null);
        if (actions.action(@src(), 1, "放弃更改", .{ .enabled = allowed })) ui.queue(.discard_navigation, null);
        if (actions.action(@src(), 2, "取消", .{ .enabled = allowed })) ui.queue(.cancel_navigation, null);
    }
    const body = components.scrollBody(@src());
    defer body.deinit();
    const information = components.modalSection(@src(), .{ .min_height = 68, .gap_after = 0 });
    defer information.deinit();
    components.text(@src(), "当前实例有未保存的更改。保存后继续，或放弃更改。", theme.colors.muted);
    if (ui.failure) |err| components.text(@src(), fmt("保存未完成：{s}", .{@errorName(err)}), theme.colors.accent);
}

fn drawEditor(ui: *Ui, doc: *const config.Document, manager: *manager_module.Manager, registered_java: []const java_module.Runtime, enabled: bool) void {
    _ = doc;
    const locked = !enabled or ui.submitted or ui.navigation != null or ui.pending != null or manager.isBusy() or manager.snapshot().phase == .awaiting_publication;
    if (settingsMode(ui.mode)) {
        const editable = !locked and ui.mode != .delete_confirm;
        {
            const panel = components.formPanel(@src(), .{ .tag = "instance-identity", .options = .{ .margin = R.all(0) } });
            defer panel.deinit();
            installedEntry(ui, @src(), "名称", "instance-settings-name", &ui.draft.name, false, editable);
            _ = dvui.spacer(@src(), .{ .min_size_content = .height(theme.spacing.field_gap) });
            javaPicker(ui, @src(), registered_java, editable);
        }
        {
            const actions = dvui.box(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = .{ .y = theme.spacing.group_gap, .h = theme.spacing.group_gap }, .background = false });
            defer actions.deinit();
            if (ui.draft.id != null and components.button(@src(), "资源管理", .{ .standalone = true, .tag = "instance-manage-mods", .enabled = editable, .expand = true, .placement = .footer })) ui.manage_requested = true;
        }
        {
            const available = dvui.parentGet().data().contentRect().w;
            const side_by_side = available >= theme.style.layout.resources_breakpoint;
            const memory_width = (available - theme.spacing.card_gap) * theme.style.layout.memory_share;
            const field_height = @max(theme.bodyFont().lineHeight(), theme.bodyFont().textSize("最小内存（MiB）").h) + settingsLabelGap() + metrics.control_height;
            const row = dvui.box(@src(), .{ .dir = if (side_by_side) .horizontal else .vertical }, .{ .tag = "instance-resources-row", .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = .{ .h = theme.spacing.group_gap }, .background = false });
            defer row.deinit();
            {
                const panel = components.bentoPanel(@src(), .{
                    .tag = "instance-resources",
                    .expand = if (side_by_side) .none else .horizontal,
                    .min_size_content = .{ .w = if (side_by_side) memory_width - 2 * theme.spacing.panel_padding else 0, .h = if (side_by_side) field_height else 0 },
                    .max_size_content = .width(if (side_by_side) memory_width - 2 * theme.spacing.panel_padding else 0),
                    .margin = if (side_by_side) .{ .w = theme.spacing.card_gap } else .{ .h = theme.spacing.group_gap },
                });
                defer panel.deinit();
                const fields = dvui.box(@src(), .{ .dir = if (side_by_side) .horizontal else .vertical, .equal_space = side_by_side }, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = R.all(0), .background = false });
                defer fields.deinit();
                {
                    const field = dvui.box(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = if (side_by_side) .{ .w = theme.spacing.field_gap / 2 } else .{ .h = theme.spacing.field_gap }, .background = false });
                    defer field.deinit();
                    installedEntry(ui, @src(), "最小内存（MiB）", "instance-settings-min-memory", &ui.draft.min_memory, true, editable);
                }
                {
                    const field = dvui.box(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = .{ .x = if (side_by_side) theme.spacing.field_gap / 2 else 0 }, .background = false });
                    defer field.deinit();
                    installedEntry(ui, @src(), "最大内存（MiB）", "instance-settings-max-memory", &ui.draft.memory, true, editable);
                }
            }
            {
                const panel = components.bentoPanel(@src(), .{ .tag = "instance-debug", .min_size_content = .height(if (side_by_side) field_height else metrics.control_height), .margin = R.all(0) });
                defer panel.deinit();
                installedDebug(ui, @src(), editable);
            }
        }
        if (components.button(@src(), "删除", .{ .standalone = true, .tag = "instance-settings-delete", .expand = true, .placement = .footer, .enabled = editable, .destructive = true })) {
            // Restore the actual trigger, rather than an older entry that would scroll into view.
            if (dvui.tagGet("instance-settings-delete")) |trigger| {
                ui.form_focus = @backingInt(trigger.id);
                ui.form_subwindow = @backingInt(dvui.subwindowCurrentId());
            }
            ui.queue(.ask_delete, ui.draft.id);
        }
        return;
    }
    if (ui.mode == .rename and ui.rename_confirmed) {
        components.text(@src(), fmt("确认将「{s}」重命名为「{s}」？", .{ text(&ui.draft.original_name), text(&ui.draft.name) }), theme.colors.accent);
        const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = R.all(0) });
        if (!locked and components.iconButton(@src(), "确认重命名", dvui.entypo.check, .{})) ui.queue(.confirm, null);
        if (!locked and components.iconButton(@src(), "取消重命名", dvui.entypo.cross, .{})) ui.queue(.close, null);
        actions.deinit();
        return;
    }
    if (locked) {
        components.text(@src(), fmt("{s}", .{text(&ui.draft.name)}), theme.colors.muted);
        return;
    }
    if (ui.mode == .rename) {
        _ = components.field(@src(), "实例名称", &ui.draft.name, .{});
        drawFormFailure(ui, "instance-rename-validation");
        if (components.action(@src(), "继续重命名", !locked)) ui.queue(.submit, null);
        if (components.action(@src(), "取消", !locked)) ui.queue(.close, null);
    }
}

fn selectedInstance(doc: *const config.Document) ?config.Instance {
    return find(doc, doc.selected_instance orelse return null) catch null;
}

fn sidebarEnabled(ui: *const Ui, busy: bool, enabled: bool) bool {
    return enabled and !busy and ui.mode != .delete_confirm and !ui.submitted and ui.pending == null and ui.navigation == null;
}

fn queueSidebarAction(ui: *Ui, action: Action, id: ?[]const u8, busy: bool, enabled: bool) void {
    if (sidebarEnabled(ui, busy, enabled)) ui.queue(action, id);
}

fn instanceSidebarRow(src: std.builtin.SourceLocation, key: []const u8, name: []const u8, options: components.ItemOptions, bottom_gap: f32, hide_idle_border: bool) bool {
    _ = hide_idle_border;
    const font = theme.bodyFont();
    const geometry = theme.controlGeometry(@max(font.lineHeight(), font.textSize(name).h), metrics.control_height, 0, theme.spacing.control_padding_x, theme.sizing.control_border);
    const content_height = geometry.content.h;
    var control: dvui.ButtonWidget = undefined;
    control.init(src, .{ .grayed = !options.enabled, .draw_focus = options.enabled }, .{
        .id_extra = @as(usize, @truncate(std.hash.Wyhash.hash(0, key))),
        .tag = key,
        .label = .{ .text = name },
        .font = font,
        .expand = .horizontal,
        .max_size_content = .width(0),
        .min_size_content = .{ .h = content_height },
        .padding = geometry.padding,
        .margin = .{ .h = bottom_gap },
        .border = R.all(theme.sizing.control_border),
        .corners = .all(theme.controlRadius()),
        .color_border = .{ .color = if (options.selected) theme.colors.accent else theme.colors.outline },
        .color_fill = .{ .color = if (options.selected) theme.colors.selected_surface else theme.colors.sidebar },
        .color_fill_hover = .{ .color = if (options.enabled or options.selected) theme.colors.selected_surface else theme.colors.sidebar },
        .color_fill_press = .{ .color = if (options.enabled) theme.colors.pressed_surface else if (options.selected) theme.colors.selected_surface else theme.colors.sidebar },
        .color_text = if (options.selected) .{ .color = theme.colors.selected_text } else null,
        .tab_index = if (options.enabled) null else 0,
    });
    defer control.deinit();
    wizardButtonEvents(&control, options.enabled);
    theme.surface.buttonBackground(&control);
    if (control.data().accesskit_node()) |node| dvui.AccessKit.nodeSetSelected(node, options.selected);
    {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .max_size_content = .width(0), .min_size_content = .{ .h = content_height }, .padding = R.all(0), .margin = R.all(0), .background = false });
        defer row.deinit();
        if (options.icon) |asset| dvui.icon(@src(), name, asset, .{}, control.style().override(.{ .min_size_content = dvui.Size.all(theme.sizing.sidebar_icon), .max_size_content = .size(dvui.Size.all(theme.sizing.sidebar_icon)), .gravity_y = 0.5, .padding = R.all(0), .margin = .{ .w = theme.spacing.control_padding_x }, .role = .none }));
        const title = dvui.textLayout(@src(), .{ .break_lines = false }, theme.foregroundOptions(control.style()).override(.{ .font = font, .expand = .horizontal, .max_size_content = .width(0), .gravity_y = 0.5, .padding = R.all(0), .margin = R.all(0), .background = false }));
        title.addText(name, .{});
        title.deinit();
    }
    components.tooltip(src, control.data().id, control.data().borderRectScale().r, name);
    return options.enabled and control.clicked();
}

pub fn sidebarPanel(src: std.builtin.SourceLocation) *dvui.BoxWidget {
    return theme.panel(src, .{}, .{ .tag = "instance-sidebar", .expand = .both, .padding = R.all(metrics.sidebar_padding), .margin = .{ .x = theme.spacing.page_margin, .y = theme.spacing.page_margin, .h = theme.spacing.page_margin }, .corners = .all(theme.sidebarRadius()), .background = true, .color_fill = .{ .color = theme.panelColor(theme.colors.sidebar) } });
}

pub fn sidebarHeading(src: std.builtin.SourceLocation) void {
    dvui.labelNoFmt(src, "实例管理", .{}, .{ .tag = "instance-sidebar-title", .font = theme.titleFont(), .padding = R.all(0), .margin = .{ .h = theme.spacing.sidebar_header_gap } });
}

/// Reserve the parent-page return before the expanding instance list.
pub fn sidebarFooter(src: std.builtin.SourceLocation, parent_label: []const u8) bool {
    const row = dvui.box(src, .{ .dir = .horizontal }, .{ .tag = "instance-sidebar-footer", .expand = .horizontal, .gravity_y = 1, .min_size_content = .{ .h = metrics.control_height }, .padding = R.all(0), .margin = .{ .y = theme.spacing.sidebar_footer_gap }, .background = false });
    defer row.deinit();
    return components.sidebarNavigationButton(@src(), "back", parent_label, true);
}

pub fn drawSidebar(ui: *Ui, store: *config.Store, manager: *manager_module.Manager, enabled: bool) void {
    const doc = store.snapshot();
    const busy = manager.isBusy() or manager.snapshot().phase == .awaiting_publication;
    const allowed = sidebarEnabled(ui, busy, enabled);
    if (components.sidebarAction(@src(), "new-instance", "新建实例", .{ .icon = dvui.entypo.plus, .selected = ui.mode == .create, .enabled = allowed })) queueSidebarAction(ui, .create, null, busy, enabled);
    _ = dvui.separator(@src(), .{ .tag = "instance-sidebar-separator", .expand = .horizontal, .margin = .{ .y = theme.spacing.sidebar_separator_before, .h = theme.spacing.sidebar_separator_after } });
    const scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .tag = "instance-sidebar-list", .expand = .both, .background = false, .padding = R.all(0), .margin = R.all(0), .border = R.all(0) });
    defer scroll.deinit();
    if (doc.instances.len == 0) components.text(@src(), "暂无实例", theme.colors.muted);
    for (doc.instances) |instance| {
        const selected = if (doc.selected_instance) |id| std.mem.eql(u8, id, instance.id) else false;
        if (instanceSidebarRow(@src(), instance.id, instance.name, .{ .selected = selected and ui.mode != .create, .enabled = allowed }, theme.spacing.sidebar_action_gap, true)) queueSidebarAction(ui, .select, instance.id, busy, enabled);
    }
}

/// registered_java is a frame-local borrow of Java Manager.entries(), never searchResults().
pub fn draw(ui: *Ui, store: *config.Store, manager: *manager_module.Manager, catalogue: library.Snapshot, registered_java: []const java_module.Runtime) void {
    drawWithEnabled(ui, store, manager, catalogue, registered_java, true);
}

fn failureMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InstanceAlreadyExists, error.DuplicateInstanceName => "同名实例或目录已存在，请使用其他名称。",
        error.InvalidInstanceName => "实例名称无效，请勿使用路径分隔符或保留名称。",
        error.InvalidMemory => "内存必须为 256–1048576 MiB，且最小内存不能大于最大内存（留空时使用默认值）。",
        error.InstanceNameUnchanged => "暂不支持仅修改名称大小写，请使用不同名称。",
        error.InstanceReferenced => "此实例正被其他版本继承或引用，暂时无法删除或重命名。请先处理依赖它的版本。",
        error.MissingInstallReceipt => "缺少实例安装信息，无法安全核对版本身份。请修复或重新安装实例后重试。",
        error.PermanentDeletionIncomplete => "删除未完成，部分文件可能已经删除。请检查实例目录。",
        error.SizeMismatch => "下载文件大小与预期不符，文件可能不完整。",
        error.ChecksumMismatch => "文件内容与预期校验值不一致，请重新获取后重试。",
        error.UnsupportedDirectoryLink => "压缩包包含不受支持的目录链接。若正在安装 Java，可改用其他发行版，或在 Java 管理中添加本机 Java 后重试。",
        error.JavaAmbiguous => "下载包中存在多个独立的 Java 运行时，无法自动确定入口。请在 Java 管理中添加所需版本后重试。",
        else => @errorName(err),
    };
}

/// Copy selected runtime paths into the draft before the registry can change.
pub fn drawWithEnabled(ui: *Ui, store: *config.Store, manager: *manager_module.Manager, catalogue: library.Snapshot, registered_java: []const java_module.Runtime, enabled: bool) void {
    if (!ui.creation_presented) syncTaskSnapshot(ui, manager.snapshot());
    syncSelected(ui, store) catch |err| {
        ui.failure = err;
    };
    const doc = store.snapshot();
    const snapshot = manager.snapshot();
    const busy = !enabled or manager.isBusy() or snapshot.phase == .awaiting_publication;
    ui.delete_confirmation_locked = manager.isBusy() or snapshot.phase == .awaiting_publication;
    const selected = selectedInstance(doc);
    if (ui.mode != .create) {
        const header = dvui.box(@src(), .{}, .{ .expand = .horizontal, .padding = R.all(0), .margin = .{ .h = theme.spacing.page_title_gap }, .background = false });
        defer header.deinit();
        const heading = dvui.textLayout(@src(), .{}, .{ .tag = "instance-settings-title", .role = .label, .tab_index = 0, .font = theme.titleFont(), .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = R.all(0), .background = false });
        heading.addText(if (ui.draft.installed) text(&ui.draft.original_name) else if (selected) |instance| instance.name else "实例", .{});
        heading.deinit();
    }
    // Reserve the fixed footer before the settings body consumes the remaining height.
    if (settingsMode(ui.mode)) {
        drawSettingsFooter(ui, ui.mode != .delete_confirm and !busy and !ui.submitted and ui.navigation == null and ui.pending == null);
        // Validation belongs beside Save and must remain visible even when the form is scrolled.
        if (ui.mode == .options and !taskFailureOwned(ui) and ui.failure != null) {
            const validation = dvui.box(@src(), .{}, .{ .tag = "instance-settings-validation-region", .expand = .horizontal, .max_size_content = .width(0), .gravity_y = 1, .padding = R.all(0), .margin = R.all(0), .background = false });
            drawFormFailure(ui, "instance-settings-validation");
            validation.deinit();
        }
    }
    // This scroll area stays within the right pane.
    const reveal_settings_failure = ui.mode == .options and ui.settings_failure_scroll_pending and ui.failure != null;
    const scroll = if (ui.mode != .create) dvui.scrollArea(@src(), .{ .horizontal = .none, .frame_viewport = if (reveal_settings_failure) dvui.Point{} else null }, .{ .tag = "instance-settings-body", .expand = .both, .background = false, .padding = R.all(0), .margin = R.all(0), .border = R.all(0) }) else null;
    defer if (scroll) |area| area.deinit();
    if (reveal_settings_failure) if (scroll) |area| {
        area.si.scrollToOffset(.vertical, 0);
        area.si.velocity.y = 0;
    };
    if (ui.mode == .options) ui.settings_failure_scroll_pending = false;
    // The wizard consumes its allocated page width; child content stays constrained to it.
    const column = dvui.box(@src(), .{}, .{
        .tag = if (ui.mode == .create) "instance-wizard-column" else null,
        .expand = if (ui.mode == .create) .both else .horizontal,
        .max_size_content = .width(0),
        .gravity_x = 0,
        .padding = R.all(0),
    });
    defer column.deinit();
    if (ui.mode == .create) {
        drawAcquisition(ui, doc, manager, catalogue, enabled);
    } else if (ui.mode != .none) drawEditor(ui, doc, manager, registered_java, enabled);
    if (selected == null and ui.mode == .none) components.text(@src(), if (doc.instances.len == 0) "暂无实例" else "未选择实例", theme.colors.muted);
}

test "deletion confirmation dismissal preserves dirty draft ownership and form focus" {
    var ui = Ui.init(std.testing.allocator);
    defer ui.deinit();
    ui.draft = try Draft.fromInstance(ui.allocator, .{ .id = "saved-id", .name = "Saved name", .minecraft_version = "1.21.1", .java_path = "/saved/java", .min_memory_mb = 512, .max_memory_mb = 2048 });
    try setText(&ui.draft.name, "Unsaved name");
    try setText(&ui.draft.java_path, "/unsaved/java");
    try setText(&ui.draft.min_memory, "768");
    try setText(&ui.draft.memory, "4096");
    ui.draft.debug_launch = true;
    ui.mode = .delete_confirm;
    ui.form_focus = 41;
    ui.form_subwindow = 7;
    const before = ui.draft;
    try std.testing.expect(ui.draft.dirty());
    try std.testing.expect(settingsMode(ui.mode));
    closeDeleteConfirmation(&ui);
    try std.testing.expectEqual(Mode.options, ui.mode);
    try std.testing.expectEqualDeep(before, ui.draft);
    try std.testing.expectEqual(@as(?u64, 41), ui.form_focus);
    try std.testing.expectEqual(@as(?u64, 7), ui.form_subwindow);
    try std.testing.expect(ui.restore_form_focus);
    try std.testing.expect(ui.draft.dirty());
    try std.testing.expect(ui.pending == null and !ui.submitted);
    try std.testing.expectEqualStrings("Saved name", text(&ui.draft.original_name));
}

test "deletion confirmation admission guards busy submitted pending and navigation state" {
    var ui = Ui.init(std.testing.allocator);
    defer ui.deinit();
    ui.mode = .delete_confirm;
    try std.testing.expect(deleteConfirmationAllowed(&ui, true));
    try std.testing.expect(!deleteConfirmationAllowed(&ui, false));
    // Global work admission can close while state-only dismissal remains available.
    try std.testing.expect(deleteDismissalAllowed(&ui));
    ui.delete_confirmation_locked = true;
    try std.testing.expect(!deleteConfirmationAllowed(&ui, true));
    ui.queue(.confirm, null);
    try std.testing.expect(ui.pending == null);
    ui.delete_confirmation_locked = false;
    ui.submitted = true;
    try std.testing.expect(!deleteConfirmationAllowed(&ui, true));
    ui.queue(.confirm, null);
    try std.testing.expect(ui.pending == null);
    ui.submitted = false;
    ui.queue(.close, "owned cancel intent");
    const cancel_text = ui.pending.?.text.?;
    ui.queue(.confirm, "must not replace cancellation");
    try std.testing.expectEqual(Action.close, ui.pending.?.action);
    try std.testing.expectEqual(cancel_text.ptr, ui.pending.?.text.?.ptr);
    try std.testing.expect(!deleteConfirmationAllowed(&ui, true));
    ui.allocator.free(cancel_text);
    ui.pending = null;
    ui.queue(.confirm, null);
    ui.queue(.confirm, "duplicate confirmation");
    try std.testing.expectEqual(Action.confirm, ui.pending.?.action);
    try std.testing.expect(ui.pending.?.text == null);
    ui.pending = null;
    ui.navigation = .{ .action = .leave };
    try std.testing.expect(!deleteConfirmationAllowed(&ui, true));
    ui.navigation = null;
    ui.mode = .options;
    try std.testing.expect(!deleteConfirmationAllowed(&ui, true));
    try std.testing.expect(settingsMode(ui.mode));
    try std.testing.expect(!settingsMode(.rename));
}

test "instance reference protection explains the actual blocker" {
    const message = failureMessage(error.InstanceReferenced);
    try std.testing.expect(std.mem.indexOf(u8, message, "继承或引用") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "网络") == null);
    try std.testing.expect(!std.mem.eql(u8, message, @errorName(error.InstanceReferenced)));
    try std.testing.expect(!std.mem.eql(u8, failureMessage(error.MissingInstallReceipt), @errorName(error.MissingInstallReceipt)));
}

test "permanent deletion uncertainty does not promise recovery while rename retains it" {
    try std.testing.expectEqualStrings("删除未完成，部分文件可能已经删除。请检查实例目录。", failureMessage(error.PermanentDeletionIncomplete));
    try std.testing.expectEqualStrings("删除已完成，但文件同步状态不确定。请检查实例目录，勿重复执行删除。", durabilityMessage(.deleting));
    try std.testing.expect(std.mem.indexOf(u8, durabilityMessage(.deleting), "恢复") == null);
    try std.testing.expect(std.mem.indexOf(u8, durabilityMessage(.renaming), "恢复目录") != null);
    try std.testing.expect(std.mem.indexOf(u8, durabilityMessage(.creating), "恢复目录") == null);
}

test "Java picker preserves legacy bindings and resolves registered choices by path" {
    const a = std.testing.allocator;
    var draft = try Draft.fromInstance(a, .{ .id = "stable", .name = "Play", .minecraft_version = "1.21", .java_path = "/legacy/java" });
    defer draft.deinit(a);
    var entries = [_]java_module.Runtime{
        .{ .path = "/registered/java-a", .major = 21, .architecture = @import("../core/java_runtime.zig").host(), .vendor = "Vendor" },
        .{ .path = "/registered/java-b", .major = 21, .architecture = @import("../core/java_runtime.zig").host(), .vendor = "Vendor" },
    };
    try std.testing.expect(javaChoice(text(&draft.java_path), &entries) == null);
    try std.testing.expect(!draft.dirty());
    try std.testing.expectEqualStrings("/legacy/java", (try draft.value(.options, &.{})).java_path.?);
    try chooseJava(&draft, &entries, 2);
    try std.testing.expect(draft.dirty());
    std.mem.swap(java_module.Runtime, &entries[0], &entries[1]);
    try std.testing.expectEqual(@as(?usize, 1), javaChoice(text(&draft.java_path), &entries));
    try std.testing.expect(javaChoice(text(&draft.java_path), &.{}) == null);
    try std.testing.expectEqualStrings("/registered/java-b", text(&draft.java_path));
    try std.testing.expectEqualStrings("/legacy/java", text(&draft.original_java_path));
    try chooseJava(&draft, &entries, 0);
    try std.testing.expectEqual(@as(?usize, 0), javaChoice(text(&draft.java_path), &entries));
    try std.testing.expect((try draft.value(.options, &.{})).java_path == null);
}

test "Java selection copies registry bytes and rejected choices preserve the draft" {
    var draft: Draft = .{};
    var path = "/registered/java".*;
    const entries = [_]java_module.Runtime{.{ .path = &path, .major = 21, .architecture = @import("../core/java_runtime.zig").host(), .vendor = "Vendor" }};
    try chooseJava(&draft, &entries, 1);
    @memset(&path, 'x');
    try std.testing.expectEqualStrings("/registered/java", text(&draft.java_path));
    try std.testing.expectError(error.JavaNotRegistered, chooseJava(&draft, &entries, 2));
    const invalid = [_]java_module.Runtime{.{ .path = "bad\npath", .major = 21, .architecture = @import("../core/java_runtime.zig").host(), .vendor = "Vendor" }};
    try std.testing.expectError(error.InvalidJavaPath, chooseJava(&draft, &invalid, 1));
    const oversized: [4097]u8 = @splat('x');
    const too_long = [_]java_module.Runtime{.{ .path = &oversized, .major = 21, .architecture = @import("../core/java_runtime.zig").host(), .vendor = "Vendor" }};
    try std.testing.expectError(error.TextTooLong, chooseJava(&draft, &too_long, 1));
    try std.testing.expectEqualStrings("/registered/java", text(&draft.java_path));
}

test "instance sidebar owns queued stable selection and right detail follows ID after reorder" {
    const a = std.testing.allocator;
    var ui = Ui.init(a);
    defer ui.deinit();
    var id = "stable-b".*;
    queueSidebarAction(&ui, .select, &id, false, true);
    @memset(&id, 'x');
    try std.testing.expectEqual(Action.select, ui.pending.?.action);
    try std.testing.expectEqualStrings("stable-b", ui.pending.?.text.?);
    var rows = [_]config.Instance{
        .{ .id = "stable-a", .name = "First", .minecraft_version = "1.20" },
        .{ .id = "stable-b", .name = "Second", .minecraft_version = "1.21", .loader = .fabric, .loader_version = "0.16" },
    };
    var doc: config.Document = .{ .instances = &rows, .selected_instance = ui.pending.?.text.? };
    try std.testing.expectEqualStrings("Second", selectedInstance(&doc).?.name);
    std.mem.swap(config.Instance, &rows[0], &rows[1]);
    try std.testing.expectEqualStrings("stable-b", selectedInstance(&doc).?.id);
    try std.testing.expectEqualStrings("1.21", selectedInstance(&doc).?.minecraft_version);
    try std.testing.expectEqual(config.Loader.fabric, selectedInstance(&doc).?.loader);
    doc.selected_instance = "missing";
    try std.testing.expect(selectedInstance(&doc) == null);
    doc.selected_instance = null;
    try std.testing.expect(selectedInstance(&doc) == null);
}

test "draft ID allocation failure remains empty and safely retries without replacing an existing ID" {
    const a = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var draft: Draft = .{};
    defer draft.deinit(a);
    try std.testing.expectError(error.OutOfMemory, draft.ensureId(failing.allocator(), std.testing.io));
    try std.testing.expect(draft.id == null);
    draft.deinit(failing.allocator());
    try std.testing.expect(draft.id == null);
    try draft.ensureId(a, std.testing.io);
    const generated_id = draft.id.?;
    try std.testing.expect(std.mem.startsWith(u8, generated_id, "instance-"));
    try std.testing.expectEqual(@as(usize, 41), generated_id.len);
    try draft.ensureId(failing.allocator(), std.testing.io);
    try std.testing.expect(draft.id.?.ptr == generated_id.ptr);
    try std.testing.expectEqualStrings(generated_id, draft.id.?);

    var existing: Draft = .{ .id = try a.dupe(u8, "pending-valid-id") };
    defer existing.deinit(a);
    const existing_id = existing.id.?;
    try existing.ensureId(failing.allocator(), std.testing.io);
    try std.testing.expect(existing.id.?.ptr == existing_id.ptr);
    try std.testing.expectEqualStrings("pending-valid-id", existing.id.?);
}

test "wizard requires a base and traverses all three steps without selecting a loader implicitly" {
    var ui = Ui.init(std.testing.allocator);
    defer ui.deinit();
    try std.testing.expectError(error.InvalidAction, advanceCreateStep(&ui));
    ui.mode = .create;
    try std.testing.expectError(error.MinecraftVersionRequired, advanceCreateStep(&ui));
    try chooseBase(&ui, &.{}, "26.3");
    try advanceCreateStep(&ui);
    try std.testing.expectEqual(CreateStep.loader, ui.create_step);
    try std.testing.expectEqual(config.Loader.fabric, ui.browse_loader);
    try std.testing.expectEqual(config.Loader.vanilla, ui.draft.loader);
    try std.testing.expect(ui.draft.loader_version == null);
    try advanceCreateStep(&ui);
    try std.testing.expectEqual(CreateStep.confirm, ui.create_step);
    try std.testing.expect(ui.name_focus_pending);
    try std.testing.expectError(error.InvalidAction, advanceCreateStep(&ui));
    try previousCreateStep(&ui);
    try std.testing.expectEqual(CreateStep.loader, ui.create_step);
    try previousCreateStep(&ui);
    try std.testing.expectEqual(CreateStep.version, ui.create_step);
    try std.testing.expectError(error.InvalidAction, previousCreateStep(&ui));
    ui.reset();
    try std.testing.expect(ui.mode == .none and ui.create_step == .version and !ui.name_focus_pending);
    try std.testing.expect(ui.draft.base == null and ui.draft.loader_version == null);
}

test "wizard loader rows toggle explicit selection and preserve selection on back forward" {
    var ui = Ui.init(std.testing.allocator);
    defer ui.deinit();
    ui.mode = .create;
    try chooseBase(&ui, &.{}, "26.3");
    try advanceCreateStep(&ui);
    try std.testing.expectError(error.InvalidLoaderVersion, chooseLoader(&ui, &.{}, .vanilla, "0.19.1"));
    try std.testing.expect(ui.draft.loader_version == null);
    try chooseLoader(&ui, &.{}, .fabric, "0.19.1");
    try std.testing.expectEqual(config.Loader.fabric, ui.draft.loader);
    try std.testing.expectEqualStrings("26.3-Fabric", text(&ui.draft.name));
    try advanceCreateStep(&ui);
    try previousCreateStep(&ui);
    try std.testing.expectEqualStrings("0.19.1", ui.draft.loader_version.?);
    try chooseLoader(&ui, &.{}, .fabric, "0.19.1");
    try std.testing.expectEqual(config.Loader.vanilla, ui.draft.loader);
    try std.testing.expect(ui.draft.loader_version == null);
    try std.testing.expectEqualStrings("26.3", text(&ui.draft.name));
    ui.browse_loader = .quilt;
    try std.testing.expectError(error.InvalidLoaderVersion, chooseLoader(&ui, &.{}, .forge, "1"));
    try chooseLoader(&ui, &.{}, .quilt, "0.28.0");
    try std.testing.expectEqualStrings("26.3-Quilt", text(&ui.draft.name));
    try previousCreateStep(&ui);
    try chooseBase(&ui, &.{}, "1.21.1");
    try std.testing.expectEqual(config.Loader.vanilla, ui.draft.loader);
    try std.testing.expectEqualStrings("1.21.1", text(&ui.draft.name));
}

test "wizard default names choose case insensitive first free suffix for each loader" {
    const rows = [_]config.Instance{
        .{ .id = "one", .name = "26.3-fABRIC", .minecraft_version = "26.3" },
        .{ .id = "two", .name = "26.3-Fabric-2", .minecraft_version = "26.3" },
        .{ .id = "four", .name = "26.3-Fabric-4", .minecraft_version = "26.3" },
        .{ .id = "vanilla", .name = "26.3", .minecraft_version = "26.3" },
    };
    const doc: config.Document = .{ .instances = &rows };
    var buffer: [200]u8 = undefined;
    try std.testing.expectEqualStrings("26.3-Fabric-3", try defaultName(&buffer, &doc, "26.3", .fabric));
    try std.testing.expectEqualStrings("26.3-2", try defaultName(&buffer, &doc, "26.3", .vanilla));
    try std.testing.expectEqualStrings("26.3-Forge", try defaultName(&buffer, &doc, "26.3", .forge));
    try std.testing.expectEqualStrings("26.3-NeoForge", try defaultName(&buffer, &doc, "26.3", .neoforge));
    try std.testing.expectEqualStrings("26.3-Quilt", try defaultName(&buffer, &doc, "26.3", .quilt));
    try std.testing.expectError(error.InvalidInstanceName, defaultName(&buffer, &doc, "../invalid", .vanilla));
}

test "wizard preserves custom invalid and duplicate input through base and loader changes" {
    const rows = [_]config.Instance{.{ .id = "taken", .name = "My World", .minecraft_version = "26.3" }};
    const doc: config.Document = .{ .instances = &rows };
    var ui = Ui.init(std.testing.allocator);
    defer ui.deinit();
    ui.mode = .create;
    try chooseBase(&ui, &doc, "26.3");
    try setText(&ui.draft.name, "My World");
    try advanceCreateStep(&ui);
    try chooseLoader(&ui, &doc, .fabric, "0.19.1");
    try std.testing.expect(ui.name_custom);
    try std.testing.expectEqualStrings("My World", text(&ui.draft.name));
    try std.testing.expectError(error.DuplicateInstanceName, validateName(&doc, text(&ui.draft.name), null));
    try advanceCreateStep(&ui);
    try std.testing.expect(!ui.name_focus_pending);
    try setText(&ui.draft.name, "../outside");
    try previousCreateStep(&ui);
    try previousCreateStep(&ui);
    try chooseBase(&ui, &doc, "1.20.1");
    try std.testing.expectEqualStrings("../outside", text(&ui.draft.name));
    try std.testing.expectError(error.InvalidInstanceName, validateName(&doc, text(&ui.draft.name), null));
    try advanceCreateStep(&ui);
    try chooseLoader(&ui, &doc, .fabric, "0.16.10");
    try std.testing.expectEqualStrings("../outside", text(&ui.draft.name));
    try setText(&ui.draft.name, "");
    try refreshGeneratedName(&ui, &doc);
    try std.testing.expectEqualStrings("", text(&ui.draft.name));
}

test "wizard refreshes defaults on back changes and selects a generated name only once" {
    var ui = Ui.init(std.testing.allocator);
    defer ui.deinit();
    ui.mode = .create;
    try chooseBase(&ui, &.{}, "26.3");
    try advanceCreateStep(&ui);
    try advanceCreateStep(&ui);
    ui.name_focus_requested = true;
    ui.name_focus_pending = false;
    try previousCreateStep(&ui);
    try previousCreateStep(&ui);
    try chooseBase(&ui, &.{}, "1.21.1");
    try std.testing.expectEqualStrings("1.21.1", text(&ui.draft.name));
    try advanceCreateStep(&ui);
    try chooseLoader(&ui, &.{}, .fabric, "0.16.10");
    try advanceCreateStep(&ui);
    try refreshGeneratedName(&ui, &.{});
    try std.testing.expectEqualStrings("1.21.1-Fabric", text(&ui.draft.name));
    try std.testing.expect(!ui.name_focus_pending);
}

test "official acquisition filters retain supported older releases and reject pre 1.7.10" {
    try std.testing.expect(catalogueMatches("release", .release));
    try std.testing.expect(catalogueMatches("release", .old));
    try std.testing.expect(catalogueMatches("snapshot", .snapshot));
    try std.testing.expect(!catalogueMatches("release", .snapshot));
    for ([_][]const u8{ "old_alpha", "old_beta", "unknown" }) |kind| {
        try std.testing.expect(!catalogueMatches(kind, .release));
        try std.testing.expect(!catalogueMatches(kind, .snapshot));
        try std.testing.expect(!catalogueMatches(kind, .old));
    }
    for ([_][]const u8{ "1.7.10", "1.8", "1.12.2", "1.21.1", "26.3", "26.1-snapshot-1", "14w26a", "25w14a" }) |id| try std.testing.expect(supportedMinecraft(id));
    for ([_][]const u8{ "1.7.9", "1.7", "1.6.4", "1.0", "b1.7.3", "a1.2.6", "13w10a", "14w02a" }) |id| try std.testing.expect(!supportedMinecraft(id));
}

test "installed memory draft preserves its baseline validates effective maximum and allows clearing" {
    const a = std.testing.allocator;
    var draft = try Draft.fromInstance(a, .{ .id = "stable", .name = "Play", .minecraft_version = "1.21", .min_memory_mb = 1024, .max_memory_mb = 4096 });
    defer draft.deinit(a);
    try std.testing.expectEqualStrings("1024", text(&draft.min_memory));
    try std.testing.expectEqualStrings("4096", text(&draft.memory));
    try std.testing.expect(!draft.dirty());
    try std.testing.expectEqual(@as(?u32, 1024), (try draft.original()).min_memory_mb);
    try setText(&draft.min_memory, "2048");
    try std.testing.expect(draft.dirty());
    const updated = try draft.value(.options, &.{});
    try std.testing.expectEqual(@as(?u32, 2048), updated.min_memory_mb);
    try std.testing.expectEqual(@as(?u32, 4096), updated.max_memory_mb);
    try std.testing.expectEqual(@as(?u32, 1024), (try draft.original()).min_memory_mb);
    try setText(&draft.min_memory, "4097");
    try std.testing.expectError(error.InvalidMemory, draft.value(.options, &.{}));
    try setText(&draft.memory, "");
    try setText(&draft.min_memory, "2048");
    const doc: config.Document = .{ .settings = .{ .default_memory_mb = 1024 } };
    try std.testing.expectError(error.InvalidMemory, draft.value(.options, &doc));
    try setText(&draft.min_memory, "256");
    const default_max = try draft.value(.options, &doc);
    try std.testing.expectEqual(@as(?u32, 256), default_max.min_memory_mb);
    try std.testing.expect(default_max.max_memory_mb == null);
    try setText(&draft.min_memory, "255");
    try std.testing.expectError(error.InvalidMemory, draft.value(.options, &doc));
    try setText(&draft.min_memory, "1048577");
    try std.testing.expectError(error.InvalidMemory, draft.value(.options, &doc));
    try setText(&draft.min_memory, "invalid");
    try std.testing.expectError(error.InvalidMemory, draft.value(.options, &doc));
    try setText(&draft.min_memory, "");
    const cleared = try draft.value(.options, &doc);
    try std.testing.expect(cleared.min_memory_mb == null and cleared.max_memory_mb == null);
    try std.testing.expect(draft.dirty());
    try setText(&draft.min_memory, "1024");
    try setText(&draft.memory, "4096");
    try std.testing.expect(!draft.dirty());
}

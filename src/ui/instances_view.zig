//! Call finish only after every root and floating widget has closed.
const std = @import("std");
const dvui = @import("dvui");
const config = @import("../core/config.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const manager_module = @import("instances_manager.zig");
const library = @import("game_library.zig");
const java_module = @import("java_manager.zig");
const Allocator = std.mem.Allocator;
const R = dvui.Rect;

pub const Mode = enum { none, create, import_folder, options, rename, delete_confirm };
pub const CreateStep = enum { version, loader };
pub const VersionFilter = enum { release, snapshot };
pub const Action = enum { create, import_folder, import_pack, edit, ask_rename, ask_delete, select, submit, confirm, close, cancel, retry_publication, choose_base, choose_loader_kind, choose_loader, load_loaders, next_step, previous_step, save_navigation, discard_navigation, cancel_navigation, leave };
const Pending = struct { action: Action, text: ?[]u8 = null, kind: config.Loader = .vanilla };

pub const Draft = struct {
    id: ?[]u8 = null,
    name: [201]u8 = @splat(0),
    original_name: [201]u8 = @splat(0),
    original_java_path: [4097]u8 = @splat(0),
    original_memory: ?u32 = null,
    original_debug: bool = false,
    installed: bool = false,
    /// Launch-options persistence; the editor chooses a registered runtime.
    java_path: [4097]u8 = @splat(0),
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
        if (instance.max_memory_mb) |m| _ = try std.fmt.bufPrint(draft.memory[0 .. draft.memory.len - 1], "{d}", .{m});
        draft.debug_launch = instance.debug_launch;
        draft.installed = true;
        if (instance.java_path) |s| try setText(&draft.original_java_path, s);
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
        // Import accepts a directory name; the backend derives its version and loader.
        // Launch options are configured only after publication in Installed.
        if (mode == .import_folder) return .{ .id = self.id orelse return error.InvalidId, .name = name, .minecraft_version = "" };
        const java = text(&self.java_path);
        if (!validText(java, true)) return error.InvalidJavaPath;
        const memory = try parseMemory(text(&self.memory));
        const base = self.base orelse return error.MinecraftVersionRequired;
        if (!validText(base, false)) return error.InvalidMinecraftVersion;
        if (self.loader != .vanilla and self.loader_version == null) return error.LoaderVersionRequired;
        if (self.loader_version) |version| if (!validText(version, false)) return error.InvalidLoaderVersion;
        return .{ .id = self.id orelse return error.InvalidId, .name = name, .minecraft_version = base, .loader = self.loader, .loader_version = self.loader_version, .java_path = if (java.len == 0) null else java, .max_memory_mb = memory, .debug_launch = self.debug_launch, .origin = self.origin };
    }
    pub fn original(self: *const Draft) !config.Instance {
        if (!self.installed) return error.InvalidAction;
        const java = text(&self.original_java_path);
        return .{ .id = self.id orelse return error.InvalidId, .name = text(&self.original_name), .minecraft_version = self.base orelse return error.MinecraftVersionRequired, .loader = self.loader, .loader_version = self.loader_version, .java_path = if (java.len == 0) null else java, .max_memory_mb = self.original_memory, .debug_launch = self.original_debug, .origin = self.origin };
    }

    pub fn dirty(self: *const Draft) bool {
        if (!self.installed) return false;
        const memory = parseMemory(text(&self.memory)) catch return true;
        return !std.mem.eql(u8, text(&self.name), text(&self.original_name)) or
            !std.mem.eql(u8, text(&self.java_path), text(&self.original_java_path)) or
            memory != self.original_memory or self.debug_launch != self.original_debug;
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
    /// Incremented only after an admitted navigation executes; modal clicks do not count.
    navigation_serial: u64 = 0,
    exit_requested: bool = false,
    failure: ?anyerror = null,
    publication_failed: bool = false,
    submitted: bool = false,
    pack_requested: bool = false,
    catalogue_requested: bool = false,
    create_step: CreateStep = .version,
    version_filter: VersionFilter = .release,
    search: [64]u8 = @splat(0),

    pub fn init(a: Allocator) Ui {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Ui) void {
        self.draft.deinit(self.allocator);
        if (self.pending) |p| if (p.text) |s| self.allocator.free(s);
        self.pending = null;
        self.clearNavigation();
    }
    pub fn queue(self: *Ui, action: Action, borrowed: ?[]const u8) void {
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
        self.create_step = .version;
        self.catalogue_requested = false;
        self.version_filter = .release;
        self.search = @splat(0);
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
        .select, .create, .import_folder, .import_pack, .edit, .ask_rename, .leave => true,
        else => false,
    };
}

fn syncSelected(ui: *Ui, store: *config.Store) !void {
    if (ui.submitted or ui.navigation != null or ui.pack_requested or ui.exit_requested) return;
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
        if (comptime @hasDecl(@TypeOf(manager.*), "startRenameWithOptions")) {
            try manager.startRenameWithOptions(original, updated);
        } else {
            // Keep the old fixture seam for name-only renames, never partially save options.
            var name_only = updated;
            name_only.name = original.name;
            if (!manager_module.sameInstance(original, name_only)) return error.CombinedRenameUnavailable;
            try manager.startRename(original, updated.name);
        }
        ui.submitted = true;
        ui.publication_failed = false;
        return;
    }
    var refreshed = try Draft.fromInstance(ui.allocator, updated);
    errdefer refreshed.deinit(ui.allocator);
    if (comptime @hasDecl(@TypeOf(manager.*), "saveOptionsChecked")) {
        try manager.saveOptionsChecked(store, original, updated);
    } else try manager.saveOptions(store, updated);
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
        .create, .import_folder => {
            if (manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
            var draft: Draft = .{};
            errdefer draft.deinit(ui.allocator);
            try draft.ensureId(ui.allocator, store.io);
            ui.reset();
            ui.draft = draft;
            ui.mode = if (p.action == .create) .create else .import_folder;
            ui.catalogue_requested = p.action == .create;
        },
        .import_pack => {
            if (manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
            ui.reset();
            ui.pack_requested = true;
        },
        .edit, .ask_rename, .ask_delete => {
            if (manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
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
                ui.mode = .options;
            } else ui.reset();
        },
        .cancel => manager.cancel(),
        .retry_publication => {
            if (manager.snapshot().phase != .awaiting_publication) return error.NoPendingPublication;
            ui.publication_failed = true;
            try manager.publish(store);
            ui.publication_failed = false;
            if (ui.submitted) ui.reset();
            if (ui.navigation != null) try resumeNavigation(ui, store, manager);
        },
        .next_step => {
            if (manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
            try advanceCreateStep(ui);
        },
        .previous_step => {
            if (manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
            if (ui.mode != .create) return error.InvalidAction;
            ui.create_step = .version;
        },
        .choose_base => {
            const default_name = text(&ui.draft.name).len == 0 or if (ui.draft.base) |base| std.mem.eql(u8, text(&ui.draft.name), base) else false;
            try replaceOwned(ui.allocator, &ui.draft.base, p.text orelse return error.MinecraftVersionRequired);
            if (ui.draft.loader_version) |old| ui.allocator.free(old);
            ui.draft.loader_version = null;
            if (default_name) try setText(&ui.draft.name, ui.draft.base.?);
        },
        .choose_loader_kind => {
            ui.draft.loader = p.kind;
            if (ui.draft.loader_version) |old| ui.allocator.free(old);
            ui.draft.loader_version = null;
        },
        .choose_loader => try replaceOwned(ui.allocator, &ui.draft.loader_version, p.text orelse return error.LoaderVersionRequired),
        .load_loaders => try manager.loadLoaders(ui.draft.base orelse return error.MinecraftVersionRequired, ui.draft.loader),
        .submit => {
            if (manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
            if (ui.mode == .create and ui.create_step != .loader) return error.WizardStepRequired;
            if (ui.mode == .rename) {
                try validateName(doc, text(&ui.draft.name), ui.draft.id);
                ui.rename_confirmed = true;
                return;
            }
            try ui.draft.ensureId(ui.allocator, store.io);
            const instance = try ui.draft.value(ui.mode, doc);
            switch (ui.mode) {
                .create => {
                    manager.setDownloadConnections(doc.settings.download_connections);
                    try manager.startCreate(instance);
                },
                .import_folder => try manager.startImport(instance),
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
            if (manager.isBusy() or manager.snapshot().phase == .awaiting_publication) return error.Busy;
            const original = try find(doc, ui.draft.id orelse return error.InvalidId);
            if (!manager_module.sameInstance(original, try ui.draft.original())) return error.InstanceChanged;
            switch (ui.mode) {
                .rename => {
                    if (!ui.rename_confirmed) return error.ConfirmationRequired;
                    try validateName(doc, text(&ui.draft.name), ui.draft.id);
                    try manager.startRename(original, text(&ui.draft.name));
                },
                .delete_confirm => try manager.startDelete(original),
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
        ui.pending = null;
        defer if (p.text) |s| ui.allocator.free(s);
        perform(ui, store, manager, p) catch |err| {
            ui.failure = err;
            if (ui.navigation != null and !ui.submitted) ui.navigation_prompt = true;
            return;
        };
        ui.failure = null;
    }
    const snapshot = manager.snapshot();
    if (ui.submitted and (snapshot.phase == .failed or snapshot.phase == .canceled)) {
        ui.submitted = false;
        if (comptime @hasField(@TypeOf(snapshot), "failure")) ui.failure = snapshot.failure;
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

fn fmt(comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), format, args) catch "";
}
fn wrapped(src: std.builtin.SourceLocation, value: []const u8, color: dvui.Color) void {
    components.text(src, value, color);
}
fn iconButton(src: std.builtin.SourceLocation, name: []const u8, asset: []const u8) bool {
    return iconButtonWithEnabled(src, name, asset, true);
}

fn iconButtonWithEnabled(src: std.builtin.SourceLocation, name: []const u8, asset: []const u8, enabled: bool) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{ .grayed = !enabled, .draw_focus = enabled }, .{ .label = .{ .text = name }, .min_size_content = .{ .w = 18, .h = 18 }, .max_size_content = .{ .w = 18, .h = 18 }, .padding = R.all(8), .margin = .{ .x = 4 }, .corners = .all(4), .tab_index = if (enabled) null else 0 });
    if (enabled) button.processEvents();
    button.drawBackground();
    dvui.icon(@src(), name, asset, .{}, button.style().override(.{ .padding = R.all(0), .margin = R.all(0), .min_size_content = .{ .w = 18, .h = 18 }, .max_size_content = .{ .w = 18, .h = 18 }, .role = .none }));
    if (enabled) button.drawFocus();
    const clicked = enabled and button.clicked();
    const control_id = button.data().id;
    const rect = button.data().borderRectScale().r;
    button.deinit();
    components.tooltip(src, control_id, rect, name);
    return clicked;
}
fn entry(src: std.builtin.SourceLocation, name: []const u8, buffer: []u8, numeric: bool) void {
    dvui.labelNoFmt(src, name, .{}, .{ .padding = R.all(0), .margin = .{ .y = 8, .h = 4 } });
    const height = (dvui.Options{}).fontGet().sizeM(0, 1).h;
    const input = dvui.textEntry(src, .{ .text = .{ .buffer = buffer } }, .{ .id_extra = 1, .label = .{ .text = name }, .expand = .horizontal, .min_size_content = .{ .h = height }, .max_size_content = .height(height), .padding = R.all(8), .corners = .all(4), .margin = .{ .h = 6 } });
    if (numeric) input.filterIn("0123456789");
    input.deinit();
}
fn dropdown(src: std.builtin.SourceLocation, labels: []const []const u8, selected: ?[]const u8, placeholder: []const u8) ?usize {
    var choice: ?usize = null;
    if (selected) |s| for (labels, 0..) |label, index| {
        if (std.mem.eql(u8, s, label)) {
            choice = index;
            break;
        }
    };
    if (labels.len == 0) {
        wrapped(src, placeholder, theme.muted);
        return null;
    }
    if (dvui.dropdown(src, labels, .{ .choice_nullable = &choice }, .{ .placeholder = placeholder, .null_selectable = false }, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(8), .corners = .all(4), .margin = .{ .h = 6 } })) return choice;
    return null;
}

fn advanceCreateStep(ui: *Ui) !void {
    if (ui.mode != .create or ui.create_step != .version) return error.InvalidAction;
    const base = ui.draft.base orelse return error.MinecraftVersionRequired;
    if (!validText(base, false)) return error.InvalidMinecraftVersion;
    ui.create_step = .loader;
}

fn wizardButton(src: std.builtin.SourceLocation, label: []const u8, enabled: bool, primary: bool, right: bool) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{ .grayed = !enabled, .draw_focus = enabled }, .{ .label = .{ .text = label }, .gravity_x = if (right) 1 else 0, .padding = R.all(12), .margin = .{ .w = 8 }, .corners = .all(8), .style = if (primary) .highlight else .control, .tab_index = if (enabled) null else 0 });
    defer button.deinit();
    if (enabled) button.processEvents();
    button.drawBackground();
    dvui.labelNoFmt(@src(), label, .{}, button.style().override(.{ .padding = R.all(0), .margin = R.all(0) }));
    if (enabled) button.drawFocus();
    return enabled and button.clicked();
}

fn catalogueMatches(kind: []const u8, filter: VersionFilter) bool {
    return std.mem.eql(u8, kind, if (filter == .release) "release" else "snapshot");
}

fn drawAcquisition(ui: *Ui, doc: *const config.Document, manager: *manager_module.Manager, catalogue: library.Snapshot, registered_java: []const java_module.Runtime, enabled: bool) void {
    const locked = !enabled or manager.isBusy() or manager.snapshot().phase == .awaiting_publication or ui.pending != null;
    wrapped(@src(), if (ui.create_step == .version) "1 / 2 · 选择 Minecraft 版本" else "2 / 2 · 加载器与安装选项", theme.muted);
    // Reserve the action strip before either scrolling step consumes the remainder.
    {
        const ready = !locked and ui.draft.base != null and (ui.create_step == .version or (text(&ui.draft.name).len != 0 and (ui.draft.loader == .vanilla or ui.draft.loader_version != null)));
        switch (components.formActions(@src(), .{ .save_enabled = ready, .cancel_enabled = !locked, .save_label = if (ui.create_step == .version) "下一步" else "保存" })) {
            .save => ui.queue(if (ui.create_step == .version) .next_step else .submit, null),
            .cancel => ui.queue(.close, null),
            .none => {},
        }
    }
    if (ui.create_step == .loader and components.action(@src(), "上一步", !locked)) ui.queue(.previous_step, null);
    if (ui.create_step == .loader) {
        const scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .expand = .both, .padding = R.all(0), .margin = R.all(0), .background = false });
        defer scroll.deinit();
        drawEditor(ui, doc, manager, registered_java, enabled);
        return;
    }
    {
        const filters = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = R.all(0), .margin = .{ .y = 12, .h = 12 } });
        defer filters.deinit();
        if (wizardButton(@src(), "正式版", !locked, ui.version_filter == .release, false)) ui.version_filter = .release;
        if (wizardButton(@src(), "快照", !locked, ui.version_filter == .snapshot, false)) ui.version_filter = .snapshot;
        if (iconButtonWithEnabled(@src(), "刷新版本列表", dvui.entypo.cw, !locked and catalogue.phase != .loading)) ui.catalogue_requested = true;
    }
    const search = dvui.textEntry(@src(), .{ .text = .{ .buffer = &ui.search }, .placeholder = "搜索版本" }, .{ .expand = .horizontal, .label = .{ .text = "搜索版本" }, .margin = .{ .h = 12 } });
    search.deinit();
    if (catalogue.phase == .loading) wrapped(@src(), "正在获取官方版本列表…", theme.muted);
    if (catalogue.failure) |err| wrapped(@src(), fmt("版本列表：{s}", .{@errorName(err)}), theme.muted);
    const scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .expand = .both, .padding = R.all(0), .margin = R.all(0), .background = false });
    defer scroll.deinit();
    var count: usize = 0;
    for (catalogue.available, 0..) |version, index| {
        if (!catalogueMatches(version.kind, ui.version_filter) or std.mem.indexOf(u8, version.id, text(&ui.search)) == null) continue;
        count += 1;
        const selected = if (ui.draft.base) |base| std.mem.eql(u8, base, version.id) else false;
        const row = dvui.box(@src(), .{}, .{ .id_extra = index, .expand = .horizontal, .padding = R.all(0), .margin = .{ .h = 6 } });
        defer row.deinit();
        if (wizardButton(@src(), version.id, !locked, selected, false)) ui.queue(.choose_base, version.id);
        if (selected) wrapped(@src(), "已选择", theme.accent);
    }
    if (count == 0 and catalogue.phase != .loading) wrapped(@src(), if (catalogue.available.len == 0) "暂无版本，请刷新列表" else "没有匹配的版本", theme.muted);
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

fn javaPicker(ui: *Ui, src: std.builtin.SourceLocation, registered_java: []const java_module.Runtime, enabled: bool) void {
    components.section(src, "Java 运行时");
    const choice = javaChoice(text(&ui.draft.java_path), registered_java);
    const label = if (choice) |index| if (index == 0) "使用默认 Java" else fmt("Java {d} · {s}", .{ registered_java[index - 1].major, registered_java[index - 1].vendor }) else "保留现有 Java 绑定";
    if (choice == null) wrapped(@src(), if (std.mem.eql(u8, text(&ui.draft.java_path), text(&ui.draft.original_java_path))) "已保存的 Java 不在已登记列表中（可能已隐藏或移除）。保留现有绑定，或选择已登记的运行时。" else "所选 Java 已不在已登记列表中（可能已隐藏或移除）。保留当前选择，或重新选择运行时。", theme.muted);
    if (registered_java.len == 0) wrapped(@src(), "暂无已登记的 Java，请先在 Java 管理中添加。", theme.muted);
    if (!enabled) {
        wrapped(@src(), label, theme.muted);
        return;
    }
    var picker: dvui.DropdownWidget = undefined;
    picker.init(src, .{ .selected_index = choice, .label = if (choice != null) label else null, .placeholder = "保留现有 Java 绑定" }, .{ .id_extra = 1, .label = .{ .text = "Java 运行时" }, .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(8), .corners = .all(4), .margin = .{ .h = 8 } });
    defer picker.deinit();
    if (dvui.focusedWidgetId() == picker.menuItem.data().id) {
        ui.form_focus = @intFromEnum(picker.menuItem.data().id);
        ui.form_subwindow = @intFromEnum(dvui.focusedSubwindowId());
    }
    if (picker.dropped()) {
        if (picker.addChoiceLabel("使用默认 Java")) chooseJava(&ui.draft, registered_java, 0) catch |err| {
            ui.failure = err;
        };
        for (registered_java, 0..) |runtime, index| {
            if (picker.addChoiceLabel(fmt("Java {d} · {s}", .{ runtime.major, runtime.vendor }))) chooseJava(&ui.draft, registered_java, index + 1) catch |err| {
                ui.failure = err;
            };
        }
    }
}

fn installedEntry(ui: *Ui, src: std.builtin.SourceLocation, name: []const u8, buffer: []u8, numeric: bool, enabled: bool) void {
    components.section(src, name);
    var input: dvui.TextEntryWidget = undefined;
    input.init(src, .{ .text = .{ .buffer = buffer } }, .{ .id_extra = 1, .expand = .horizontal, .max_size_content = .width(0), .min_size_content = .{ .w = 0, .h = (dvui.Options{}).fontGet().textHeight() }, .padding = R.all(8), .margin = .{ .h = 8 }, .tab_index = if (enabled) null else 0 });
    defer input.deinit();
    if (enabled) input.processEvents();
    if (numeric and enabled) input.filterIn("0123456789");
    input.draw();
    if (enabled and dvui.focusedWidgetId() == input.data().id) {
        ui.form_focus = @intFromEnum(input.data().id);
        ui.form_subwindow = @intFromEnum(dvui.focusedSubwindowId());
    }
}

fn debugSwitch(src: std.builtin.SourceLocation, value: *bool, enabled: bool) void {
    const row = dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = R.all(0), .margin = .{ .y = 8, .h = 12 } });
    defer row.deinit();
    dvui.labelNoFmt(@src(), "调试启动", .{}, .{ .gravity_y = 0.5, .padding = R.all(0) });
    var button: dvui.ButtonWidget = undefined;
    button.init(@src(), .{ .grayed = !enabled, .draw_focus = enabled }, .{ .label = .{ .text = "调试启动" }, .role = .ak_switch, .gravity_x = 1, .min_size_content = .{ .w = 42, .h = 24 }, .max_size_content = .{ .w = 42, .h = 24 }, .padding = R.all(0), .corners = .all(12), .border = R.all(0), .color_fill = .{ .color = if (value.*) theme.accent else theme.muted }, .tab_index = if (enabled) null else 0 });
    defer button.deinit();
    if (enabled) button.processEvents();
    if (enabled and button.clicked()) value.* = !value.*;
    button.drawBackground();
    const knob = dvui.box(@src(), .{}, .{ .rect = .{ .x = if (value.*) 21 else 3, .y = 3, .w = 18, .h = 18 }, .padding = R.all(0), .background = true, .border = R.all(0), .corners = .all(9), .color_fill = .{ .color = .white } });
    knob.deinit();
    if (enabled) button.drawFocus();
}

/// Draw after page roots close; transitions remain deferred to finish.
pub fn drawModal(ui: *Ui, enabled: bool) void {
    if (ui.restore_form_focus) {
        ui.restore_form_focus = false;
        if (ui.form_subwindow) |id| dvui.focusSubwindow(@enumFromInt(id), null);
        if (ui.form_focus) |id| dvui.focusWidget(@enumFromInt(id), if (ui.form_subwindow) |s| @enumFromInt(s) else null, null);
    }
    if (!ui.navigation_prompt) return;
    const dialog = dvui.floatingWindow(@src(), .{ .modal = true }, .{ .min_size_content = .{ .w = 360 }, .max_size_content = .width(460), .padding = R.all(18), .background = true, .color_fill = .{ .color = theme.surface }, .corners = .all(6) });
    defer dialog.deinit();
    dvui.labelNoFmt(@src(), "保存实例更改？", .{}, .{ .padding = R.all(0), .margin = .{ .h = 12 } });
    wrapped(@src(), "当前实例有未保存的更改。保存后继续，或放弃更改。", theme.muted);
    if (ui.failure) |err| wrapped(@src(), fmt("保存未完成：{s}", .{@errorName(err)}), theme.accent);
    const actions = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal, .padding = R.all(0), .margin = .{ .y = 16 } });
    defer actions.deinit();
    const allowed = enabled and ui.pending == null and !ui.submitted;
    if (components.action(@src(), "保存并继续", allowed)) ui.queue(.save_navigation, null);
    if (components.action(@src(), "放弃更改", allowed)) ui.queue(.discard_navigation, null);
    if (components.action(@src(), "取消", allowed)) ui.queue(.cancel_navigation, null);
}

fn drawEditor(ui: *Ui, doc: *const config.Document, manager: *manager_module.Manager, registered_java: []const java_module.Runtime, enabled: bool) void {
    const section = dvui.box(@src(), .{}, .{ .expand = .horizontal, .padding = .{ .y = 12 }, .border = .{ .y = 1 }, .margin = .{ .h = 12 } });
    defer section.deinit();
    const locked = !enabled or ui.submitted or ui.navigation != null or manager.isBusy() or manager.snapshot().phase == .awaiting_publication;
    if (ui.mode == .options or ui.mode == .delete_confirm) {
        const editable = !locked and ui.mode == .options;
        installedEntry(ui, @src(), "实例名称", &ui.draft.name, false, editable);
        components.section(@src(), "启动选项");
        javaPicker(ui, @src(), registered_java, editable);
        installedEntry(ui, @src(), "内存上限（MiB）", &ui.draft.memory, true, editable);
        debugSwitch(@src(), &ui.draft.debug_launch, editable);
        if (ui.mode == .options) {
            if (components.action(@src(), "移至恢复区", editable)) ui.queue(.ask_delete, ui.draft.id);
            return;
        }
    }
    if (ui.mode == .delete_confirm) {
        wrapped(@src(), fmt("将实例「{s}」的独立目录移至恢复区？", .{text(&ui.draft.original_name)}), theme.accent);
        var count: usize = 0;
        for (doc.servers) |server| if (ui.draft.id) |id| {
            if (std.mem.eql(u8, server.instance_id, id)) count += 1;
        };
        wrapped(@src(), fmt("同时移除绑定的 {d} 条服务器配置：", .{count}), theme.muted);
        for (doc.servers, 0..) |server, index| if (ui.draft.id) |id| {
            if (std.mem.eql(u8, server.instance_id, id)) {
                const row = dvui.box(@src(), .{}, .{ .id_extra = index, .expand = .horizontal, .padding = R.all(0) });
                wrapped(@src(), server.name, theme.muted);
                row.deinit();
            }
        };
        wrapped(@src(), "不删除其他实例、服务器文件或世界目录。", theme.muted);
        const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = R.all(0) });
        if (!locked and iconButton(@src(), "确认移至恢复区", dvui.entypo.trash)) ui.queue(.confirm, null);
        if (!locked and iconButton(@src(), "取消删除", dvui.entypo.cross)) ui.queue(.close, null);
        actions.deinit();
        return;
    }
    if (ui.mode == .rename and ui.rename_confirmed) {
        wrapped(@src(), fmt("确认将「{s}」重命名为「{s}」？", .{ text(&ui.draft.original_name), text(&ui.draft.name) }), theme.accent);
        const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = R.all(0) });
        if (!locked and iconButton(@src(), "确认重命名", dvui.entypo.check)) ui.queue(.confirm, null);
        if (!locked and iconButton(@src(), "取消重命名", dvui.entypo.cross)) ui.queue(.close, null);
        actions.deinit();
        return;
    }
    if (locked) {
        wrapped(@src(), fmt("{s}", .{text(&ui.draft.name)}), theme.muted);
        return;
    }
    dvui.labelNoFmt(@src(), switch (ui.mode) {
        .create => "创建实例",
        .import_folder => "导入已有目录",
        .options => "启动选项",
        .rename => "重命名实例",
        else => "实例",
    }, .{}, .{ .padding = R.all(0) });
    if (ui.mode != .options) entry(@src(), if (ui.mode == .import_folder) "目录名称" else "实例名称", &ui.draft.name, false);
    if (ui.mode == .import_folder) {
        wrapped(@src(), fmt(".minecraft/versions/{s}", .{text(&ui.draft.name)}), theme.muted);
        return;
    }
    if (ui.mode == .create) {
        wrapped(@src(), fmt("Minecraft {s}", .{ui.draft.base orelse ""}), theme.muted);
        dvui.labelNoFmt(@src(), "加载器", .{}, .{ .padding = R.all(0), .margin = .{ .y = 8, .h = 4 } });
        const kinds = [_]config.Loader{ .vanilla, .fabric, .forge, .neoforge, .quilt };
        const names = [_][]const u8{ "原版", "Fabric", "Forge", "NeoForge", "Quilt" };
        var choice: usize = 0;
        for (kinds, 0..) |kind, index| if (kind == ui.draft.loader) {
            choice = index;
        };
        if (dropdown(@src(), &names, names[choice], "选择加载器")) |index| {
            ui.queue(.choose_loader_kind, null);
            if (ui.pending) |*p| p.kind = kinds[index];
        }
        if (ui.draft.loader != .vanilla) {
            const loaders = manager.loaderSnapshot();
            const matches = if (loaders.base) |base| ui.draft.base != null and std.mem.eql(u8, base, ui.draft.base.?) and loaders.kind == ui.draft.loader else false;
            if (matches and loaders.entries.len != 0) {
                const versions = dvui.currentWindow().arena().alloc([]const u8, loaders.entries.len) catch {
                    ui.failure = error.OutOfMemory;
                    return;
                };
                for (loaders.entries, 0..) |loader, index| versions[index] = loader.id;
                if (dropdown(@src(), versions, ui.draft.loader_version, "选择加载器版本")) |index| ui.queue(.choose_loader, versions[index]);
            }
            const load = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = R.all(0) });
            wrapped(@src(), if (matches and loaders.phase == .working) "正在读取加载器版本" else "加载器版本", theme.muted);
            if (iconButton(@src(), "读取加载器版本", dvui.entypo.cw)) ui.queue(.load_loaders, null);
            load.deinit();
            if (matches) if (loaders.failure) |err| wrapped(@src(), fmt("加载器目录：{s}", .{@errorName(err)}), theme.muted);
        }
    }
    if (ui.mode == .create) {
        javaPicker(ui, @src(), registered_java, !locked);
        entry(@src(), "内存 MiB（留空使用默认）", &ui.draft.memory, true);
        _ = dvui.checkbox(@src(), &ui.draft.debug_launch, "调试启动", .{ .margin = .{ .y = 8, .h = 8 } });
    }
    if (ui.mode == .create) return;
    if (ui.mode == .rename) {
        if (components.action(@src(), "继续重命名", !locked)) ui.queue(.submit, null);
        if (components.action(@src(), "取消", !locked)) ui.queue(.close, null);
    }
}

fn selectedInstance(doc: *const config.Document) ?config.Instance {
    return find(doc, doc.selected_instance orelse return null) catch null;
}

fn sidebarEnabled(ui: *const Ui, busy: bool, enabled: bool) bool {
    return enabled and !busy and !ui.submitted and ui.pending == null and ui.navigation == null and !ui.pack_requested;
}

fn queueSidebarAction(ui: *Ui, action: Action, id: ?[]const u8, busy: bool, enabled: bool) void {
    if (sidebarEnabled(ui, busy, enabled)) ui.queue(action, id);
}

fn queueSidebarPack(ui: *Ui, busy: bool, enabled: bool) void {
    if (sidebarEnabled(ui, busy, enabled)) ui.queue(.import_pack, null);
}

fn sidebarRow(src: std.builtin.SourceLocation, instance: config.Instance, selected: bool, enabled: bool) bool {
    return components.sidebarItem(src, instance.id, instance.name, .{ .selected = selected, .enabled = enabled });
}

pub fn drawSidebar(ui: *Ui, store: *config.Store, manager: *manager_module.Manager, enabled: bool) void {
    const doc = store.snapshot();
    const busy = manager.isBusy() or manager.snapshot().phase == .awaiting_publication;
    const allowed = sidebarEnabled(ui, busy, enabled);
    if (components.sidebarItem(@src(), "new-instance", "新建实例", .{ .icon = dvui.entypo.plus, .selected = ui.mode == .create, .enabled = allowed })) queueSidebarAction(ui, .create, null, busy, enabled);
    if (components.sidebarItem(@src(), "import-folder", "导入已有目录", .{ .selected = ui.mode == .import_folder, .enabled = allowed })) queueSidebarAction(ui, .import_folder, null, busy, enabled);
    if (components.sidebarItem(@src(), "import-pack", "导入整合包", .{ .enabled = allowed })) queueSidebarAction(ui, .import_pack, null, busy, enabled);
    components.section(@src(), "已安装");
    const scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .expand = .both, .padding = R.all(0), .margin = R.all(0), .background = false });
    defer scroll.deinit();
    if (doc.instances.len == 0) wrapped(@src(), "暂无实例", theme.muted);
    for (doc.instances) |instance| {
        const selected = if (doc.selected_instance) |id| std.mem.eql(u8, id, instance.id) else false;
        if (sidebarRow(@src(), instance, selected and ui.mode != .create and ui.mode != .import_folder, allowed)) queueSidebarAction(ui, .select, instance.id, busy, enabled);
    }
}

/// registered_java is a frame-local borrow of Java Manager.entries(), never searchResults().
pub fn draw(ui: *Ui, store: *config.Store, manager: *manager_module.Manager, catalogue: library.Snapshot, registered_java: []const java_module.Runtime) void {
    drawWithEnabled(ui, store, manager, catalogue, registered_java, true);
}

fn failureMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InstanceAlreadyExists => "同名实例或目录已存在；如果列表中没有它，请使用“导入已有目录”验证登记。",
        else => @errorName(err),
    };
}

/// Copy selected runtime paths into the draft before the registry can change.
pub fn drawWithEnabled(ui: *Ui, store: *config.Store, manager: *manager_module.Manager, catalogue: library.Snapshot, registered_java: []const java_module.Runtime, enabled: bool) void {
    syncSelected(ui, store) catch |err| {
        ui.failure = err;
    };
    const doc = store.snapshot();
    const snapshot = manager.snapshot();
    const busy = !enabled or manager.isBusy() or snapshot.phase == .awaiting_publication;
    const selected = selectedInstance(doc);
    // Reserve the shared footer before the body consumes the remaining height.
    if (ui.mode == .options or ui.mode == .import_folder) {
        const allowed = !busy and !ui.submitted and ui.navigation == null and ui.pending == null;
        switch (components.formActions(@src(), .{ .save_enabled = allowed, .cancel_enabled = allowed, .save_label = if (ui.mode == .import_folder) "导入" else "保存" })) {
            .save => ui.queue(.submit, null),
            .cancel => ui.queue(.close, null),
            .none => {},
        }
    }
    // This scroll area stays within the right pane.
    const scroll = if (ui.mode != .create) dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .expand = .both, .background = false, .padding = R.all(0), .border = R.all(0) }) else null;
    defer if (scroll) |area| area.deinit();
    const column = dvui.box(@src(), .{}, .{ .expand = if (ui.mode == .create) .both else .horizontal, .padding = R.all(0) });
    defer column.deinit();
    {
        const heading = dvui.box(@src(), .{}, .{ .expand = .horizontal, .padding = R.all(0), .margin = .{ .h = 12 } });
        wrapped(@src(), if (ui.mode == .create or ui.mode == .import_folder) "获取 / 导入实例" else if (selected) |instance| instance.name else "实例", dvui.themeGet().text);
        if (ui.mode != .create and ui.mode != .import_folder) if (selected) |instance| {
            wrapped(@src(), fmt("Minecraft {s} · {s}{s}{s}", .{ instance.minecraft_version, @tagName(instance.loader), if (instance.loader_version != null) " " else "", instance.loader_version orelse "" }), theme.muted);
        };
        heading.deinit();
    }
    if (ui.failure) |err| wrapped(@src(), fmt("操作失败：{s}", .{failureMessage(err)}), dvui.Color.fromHex("F0A6A1"));
    if (snapshot.failure) |err| wrapped(@src(), fmt("实例任务：{s}", .{failureMessage(err)}), dvui.Color.fromHex("F0A6A1"));
    if (snapshot.durability_uncertain) wrapped(@src(), "目录操作已提交，但尚未确认写入持久化；请保留恢复目录，勿重复执行。", dvui.Color.fromHex("F0C78D"));
    switch (snapshot.phase) {
        .working => {
            const status = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = R.all(0) });
            wrapped(@src(), fmt("处理中 · {d}/{d}", .{ snapshot.completed, snapshot.total }), theme.muted);
            if (enabled and iconButton(@src(), "取消任务", dvui.entypo.cross)) ui.queue(.cancel, null);
            status.deinit();
        },
        .awaiting_publication => {
            wrapped(@src(), "文件操作已完成，等待保存配置。", theme.muted);
            if (enabled and ui.publication_failed and iconButton(@src(), "重试保存配置", dvui.entypo.cw)) ui.queue(.retry_publication, null);
        },
        .complete => wrapped(@src(), switch (snapshot.operation) {
            .creating => "实例安装已完成。",
            .importing => if (snapshot.local_client_verified) "已登记：原版本地元数据和客户端哈希、大小已验证；依赖及 Java 尚未验证。" else "已导入：仅验证元数据，尚未验证依赖。",
            .renaming => "实例已重命名。",
            .deleting => "实例已移至恢复区，绑定服务器配置已移除。",
            .loading_loaders => "加载器目录已读取。",
            else => "操作已完成。",
        }, theme.muted),
        .canceled => wrapped(@src(), "操作已取消。", theme.muted),
        else => {},
    }
    if (snapshot.recovery_directory) |path| wrapped(@src(), fmt("恢复目录：{s}", .{path}), theme.muted);
    if (ui.mode == .create) {
        drawAcquisition(ui, doc, manager, catalogue, registered_java, enabled);
    } else if (ui.mode != .none) drawEditor(ui, doc, manager, registered_java, enabled);
    if (selected == null and ui.mode == .none) wrapped(@src(), if (doc.instances.len == 0) "暂无实例" else "未选择实例", theme.muted);
}

test "Java picker preserves legacy bindings and resolves registered choices by path" {
    const a = std.testing.allocator;
    var draft = try Draft.fromInstance(a, .{ .id = "stable", .name = "Play", .minecraft_version = "1.21", .java_path = "/legacy/java" });
    defer draft.deinit(a);
    var entries = [_]java_module.Runtime{
        .{ .path = "/registered/java-a", .major = 21, .vendor = "Vendor" },
        .{ .path = "/registered/java-b", .major = 21, .vendor = "Vendor" },
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
    const entries = [_]java_module.Runtime{.{ .path = &path, .major = 21, .vendor = "Vendor" }};
    try chooseJava(&draft, &entries, 1);
    @memset(&path, 'x');
    try std.testing.expectEqualStrings("/registered/java", text(&draft.java_path));
    try std.testing.expectError(error.JavaNotRegistered, chooseJava(&draft, &entries, 2));
    const invalid = [_]java_module.Runtime{.{ .path = "bad\npath", .major = 21, .vendor = "Vendor" }};
    try std.testing.expectError(error.InvalidJavaPath, chooseJava(&draft, &invalid, 1));
    const oversized: [4097]u8 = @splat('x');
    const too_long = [_]java_module.Runtime{.{ .path = &oversized, .major = 21, .vendor = "Vendor" }};
    try std.testing.expectError(error.TextTooLong, chooseJava(&draft, &too_long, 1));
    try std.testing.expectEqualStrings("/registered/java", text(&draft.java_path));
}

test "directory import derives its name and submits only default launch options" {
    const a = std.testing.allocator;
    var draft: Draft = .{ .loader = .fabric, .debug_launch = true };
    defer draft.deinit(a);
    try draft.ensureId(a, std.testing.io);
    try setText(&draft.name, "Existing folder");
    try setText(&draft.java_path, "/old/java");
    try setText(&draft.memory, "invalid");
    draft.base = try a.dupe(u8, "1.20");
    draft.loader_version = try a.dupe(u8, "old-loader");
    const imported = try draft.value(.import_folder, &.{});
    try std.testing.expectEqualStrings("Existing folder", imported.name);
    try std.testing.expectEqualStrings("", imported.minecraft_version);
    try std.testing.expectEqual(config.Loader.vanilla, imported.loader);
    try std.testing.expect(imported.loader_version == null and imported.java_path == null and imported.max_memory_mb == null and imported.origin == null);
    try std.testing.expect(!imported.debug_launch);
    const existing = [_]config.Instance{.{ .id = "other", .name = "Existing folder", .minecraft_version = "1.21" }};
    try std.testing.expectError(error.DuplicateInstanceName, draft.value(.import_folder, &.{ .instances = &existing }));
    try setText(&draft.name, "../outside");
    try std.testing.expectError(error.InvalidInstanceName, draft.value(.import_folder, &.{}));
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

test "instance sidebar remains interactive for drafts and guards pending worker and pack transitions" {
    var ui = Ui.init(std.testing.allocator);
    defer ui.deinit();
    queueSidebarAction(&ui, .select, "other", false, false);
    queueSidebarPack(&ui, false, false);
    try std.testing.expect(ui.pending == null and !ui.pack_requested);
    queueSidebarAction(&ui, .create, null, true, true);
    queueSidebarPack(&ui, true, true);
    try std.testing.expect(ui.pending == null and !ui.pack_requested);
    try setText(&ui.draft.name, "Preserved draft");
    for ([_]Mode{ .create, .import_folder, .options, .rename, .delete_confirm }) |mode| {
        ui.mode = mode;
        queueSidebarAction(&ui, .select, "other", false, true);
        try std.testing.expectEqual(Action.select, ui.pending.?.action);
        queueSidebarPack(&ui, false, true);
        try std.testing.expectEqual(Action.select, ui.pending.?.action);
        try std.testing.expectEqualStrings("Preserved draft", text(&ui.draft.name));
        ui.allocator.free(ui.pending.?.text.?);
        ui.pending = null;
    }
    queueSidebarPack(&ui, false, true);
    try std.testing.expectEqual(Action.import_pack, ui.pending.?.action);
    try std.testing.expect(!ui.pack_requested);
    ui.pending = null;
    ui.pack_requested = true;
    queueSidebarAction(&ui, .create, null, false, true);
    try std.testing.expect(ui.pending == null);
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

test "acquisition wizard requires a selected base and preserves choices through both steps" {
    const a = std.testing.allocator;
    var ui = Ui.init(a);
    defer ui.deinit();
    try std.testing.expectError(error.InvalidAction, advanceCreateStep(&ui));
    ui.mode = .create;
    try std.testing.expectError(error.MinecraftVersionRequired, advanceCreateStep(&ui));
    ui.draft.base = try a.dupe(u8, "1.21.1");
    try advanceCreateStep(&ui);
    try std.testing.expectEqual(CreateStep.loader, ui.create_step);
    try std.testing.expectError(error.InvalidAction, advanceCreateStep(&ui));
    ui.draft.loader = .fabric;
    ui.draft.loader_version = try a.dupe(u8, "0.16.10");
    ui.create_step = .version;
    try advanceCreateStep(&ui);
    try std.testing.expectEqualStrings("1.21.1", ui.draft.base.?);
    try std.testing.expectEqualStrings("0.16.10", ui.draft.loader_version.?);
    ui.catalogue_requested = true;
    ui.reset();
    try std.testing.expect(ui.mode == .none and ui.create_step == .version and !ui.catalogue_requested);
    try std.testing.expect(ui.draft.base == null and ui.draft.loader_version == null);
}

test "official acquisition filters exclude legacy alpha and beta builds" {
    try std.testing.expect(catalogueMatches("release", .release));
    try std.testing.expect(catalogueMatches("snapshot", .snapshot));
    try std.testing.expect(!catalogueMatches("release", .snapshot));
    try std.testing.expect(!catalogueMatches("snapshot", .release));
    for ([_][]const u8{ "old_alpha", "old_beta", "unknown" }) |kind| {
        try std.testing.expect(!catalogueMatches(kind, .release));
        try std.testing.expect(!catalogueMatches(kind, .snapshot));
    }
}

//! Standalone state-only tests: direnv exec . zig test src/instances_view_tests.zig -lc
const std = @import("std");
const config = @import("core/config.zig");
const view = @import("ui/instances_view.zig");
const Phase = enum { idle, working, awaiting_publication, complete, failed, canceled };
const FixtureManager = struct {
    phase: Phase = .idle,
    selects: usize = 0,
    saves: usize = 0,
    starts: usize = 0,
    publishes: usize = 0,
    renames: usize = 0,
    deletes: usize = 0,
    loads: usize = 0,
    fail_start: bool = false,
    fail_save: bool = false,
    fail_publish: bool = false,
    captured_id: [201]u8 = @splat(0),
    captured_name: [201]u8 = @splat(0),
    captured_base: [201]u8 = @splat(0),
    captured_java: [4097]u8 = @splat(0),
    captured_memory: ?u32 = null,
    captured_debug: bool = false,
    rename_pending: bool = false,
    pub fn setDownloadConnections(_: *FixtureManager, _: u16) void {}
    pub fn isBusy(self: *FixtureManager) bool {
        return self.phase == .working;
    }
    pub fn snapshot(self: *FixtureManager) struct { phase: Phase } {
        return .{ .phase = self.phase };
    }
    pub fn cancel(self: *FixtureManager) void {
        self.phase = .canceled;
    }
    pub fn select(self: *FixtureManager, store: *config.Store, id: []const u8) !void {
        self.selects += 1;
        store.state.value.selected_instance = try store.state.arena.allocator().dupe(u8, id);
    }
    pub fn saveOptions(self: *FixtureManager, store: *config.Store, instance: config.Instance) !void {
        self.saves += 1;
        if (self.fail_save) return error.DiskFailure;
        capture(&self.captured_java, instance.java_path orelse "");
        self.captured_memory = instance.max_memory_mb;
        self.captured_debug = instance.debug_launch;
        for (@constCast(store.state.value.instances)) |*entry| if (std.mem.eql(u8, entry.id, instance.id)) {
            entry.java_path = if (instance.java_path) |java| try store.state.arena.allocator().dupe(u8, java) else null;
            entry.max_memory_mb = instance.max_memory_mb;
            entry.debug_launch = instance.debug_launch;
        };
    }
    pub fn startCreate(self: *FixtureManager, instance: config.Instance) !void {
        self.starts += 1;
        capture(&self.captured_id, instance.id);
        capture(&self.captured_name, instance.name);
        capture(&self.captured_base, instance.minecraft_version);
        if (self.fail_start) return error.InstallAdapterUnavailable;
        self.phase = .working;
    }
    pub fn startImport(self: *FixtureManager, instance: config.Instance) !void {
        try self.startCreate(instance);
    }
    pub fn startRename(self: *FixtureManager, _: config.Instance, name: []const u8) !void {
        self.renames += 1;
        capture(&self.captured_name, name);
        self.phase = .working;
    }
    pub fn startRenameWithOptions(self: *FixtureManager, original: config.Instance, updated: config.Instance) !void {
        if (self.fail_start) return error.WorkerUnavailable;
        try self.startRename(original, updated.name);
        capture(&self.captured_id, original.id);
        capture(&self.captured_java, updated.java_path orelse "");
        self.captured_memory = updated.max_memory_mb;
        self.captured_debug = updated.debug_launch;
        self.rename_pending = true;
    }
    pub fn startDelete(self: *FixtureManager, _: config.Instance) !void {
        self.deletes += 1;
        self.phase = .working;
    }
    pub fn publish(self: *FixtureManager, store: *config.Store) !void {
        self.publishes += 1;
        if (self.fail_publish) return error.DiskFailure;
        if (self.rename_pending) {
            for (@constCast(store.state.value.instances)) |*entry| if (std.mem.eql(u8, entry.id, string(&self.captured_id))) {
                entry.name = try store.state.arena.allocator().dupe(u8, string(&self.captured_name));
                const java = string(&self.captured_java);
                entry.java_path = if (java.len == 0) null else try store.state.arena.allocator().dupe(u8, java);
                entry.max_memory_mb = self.captured_memory;
                entry.debug_launch = self.captured_debug;
            };
            self.rename_pending = false;
        }
        self.phase = .complete;
    }
    pub fn loadLoaders(self: *FixtureManager, _: []const u8, _: config.Loader) !void {
        self.loads += 1;
    }
};
fn capture(buffer: []u8, s: []const u8) void {
    @memset(buffer, 0);
    @memcpy(buffer[0..s.len], s);
}
fn string(buffer: []const u8) []const u8 {
    return buffer[0 .. std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len];
}
fn storeFixture() !config.Store {
    return .{ .a = std.testing.allocator, .io = std.testing.io, .root = "", .file = "", .state = try std.json.parseFromSlice(config.Document, std.testing.allocator,
        \\{"instances":[{"id":"first","name":"First","minecraft_version":"1.21.1","loader":"fabric","loader_version":"0.16.0","origin":{"kind":"modrinth","project_id":"project","version_id":"release"}},{"id":"second","name":"Second","minecraft_version":"1.20.1"}]}
    , .{ .allocate = .alloc_always }) };
}

test "view declarations stay lazy without DVUI or production manager" {
    _ = view.Ui;
    _ = view.Draft;
    _ = view.finish;
}
test "owned draft copies all instance strings and survives source mutation" {
    var store = try storeFixture();
    defer store.state.deinit();
    var draft = try view.Draft.fromInstance(std.testing.allocator, store.snapshot().instances[0]);
    defer draft.deinit(std.testing.allocator);
    const source = store.snapshot().instances[0];
    try std.testing.expect(draft.id.?.ptr != source.id.ptr);
    try std.testing.expect(draft.base.?.ptr != source.minecraft_version.ptr);
    try std.testing.expect(draft.loader_version.?.ptr != source.loader_version.?.ptr);
    try std.testing.expect(draft.origin.?.project_id.ptr != source.origin.?.project_id.ptr);
    try std.testing.expect(draft.origin.?.version_id.ptr != source.origin.?.version_id.ptr);
    @constCast(source.minecraft_version)[0] = '9';
    try std.testing.expectEqualStrings("1.21.1", draft.base.?);
    try std.testing.expectEqualStrings("First", string(&draft.name));
}
test "edit select and options mutate only during finish and retain failed draft" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    ui.queue(.edit, "first");
    try std.testing.expectEqual(view.Mode.none, ui.mode);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(view.Mode.options, ui.mode);
    capture(&ui.draft.java_path, "/jdk/bin/java");
    capture(&ui.draft.memory, "4096");
    ui.draft.debug_launch = true;
    manager.fail_save = true;
    ui.queue(.submit, null);
    try std.testing.expectEqual(@as(usize, 0), manager.saves);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(error.DiskFailure, ui.failure.?);
    try std.testing.expectEqualStrings("/jdk/bin/java", string(&ui.draft.java_path));
    manager.fail_save = false;
    ui.queue(.submit, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(?u32, 4096), manager.captured_memory);
    try std.testing.expect(manager.captured_debug);
    try std.testing.expectEqual(view.Mode.options, ui.mode);
    var id = [_]u8{ 's', 'e', 'c', 'o', 'n', 'd' };
    ui.queue(.select, &id);
    id[0] = 'X';
    try std.testing.expectEqual(@as(usize, 0), manager.selects);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqualStrings("second", store.snapshot().selected_instance.?);
}
test "secure 128 bit stable draft id is retained across installation retries" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{ .fail_start = true };
    ui.queue(.create, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 41), ui.draft.id.?.len);
    try std.testing.expect(std.mem.startsWith(u8, ui.draft.id.?, "instance-"));
    for (ui.draft.id.?[9..]) |ch| try std.testing.expect(std.ascii.isHex(ch));
    const original_id = try std.testing.allocator.dupe(u8, ui.draft.id.?);
    defer std.testing.allocator.free(original_id);
    capture(&ui.draft.name, "Portable");
    ui.queue(.choose_base, "1.21.1");
    view.finishWithManager(&ui, &store, &manager);
    ui.queue(.next_step, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(view.CreateStep.loader, ui.create_step);
    ui.queue(.submit, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(error.InstallAdapterUnavailable, ui.failure.?);
    try std.testing.expectEqualStrings(original_id, ui.draft.id.?);
    ui.queue(.submit, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 2), manager.starts);
    try std.testing.expectEqualStrings(original_id, string(&manager.captured_id));
    try std.testing.expectEqualStrings("Portable", string(&ui.draft.name));
    var other: view.Draft = .{};
    defer other.deinit(std.testing.allocator);
    try other.ensureId(std.testing.allocator, std.testing.io);
    try std.testing.expect(!std.mem.eql(u8, original_id, other.id.?));
}
test "base and loader selection copy borrowed catalogues and defer replacement" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    ui.queue(.create, null);
    view.finishWithManager(&ui, &store, &manager);
    var base = [_]u8{ '1', '.', '2', '1' };
    ui.queue(.choose_base, &base);
    base[0] = '9';
    try std.testing.expect(ui.draft.base == null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqualStrings("1.21", ui.draft.base.?);
    ui.queue(.choose_loader, "0.16.0");
    view.finishWithManager(&ui, &store, &manager);
    const previous = ui.draft.loader_version.?;
    ui.queue(.choose_base, "1.20.1");
    try std.testing.expectEqualStrings("0.16.0", previous);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expect(ui.draft.loader_version == null);
}
test "failed publication is latched until explicit retry without per frame disk attempts" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{ .phase = .awaiting_publication, .fail_publish = true };
    ui.draft.id = try std.testing.allocator.dupe(u8, "stable-id");
    ui.mode = .create;
    ui.submitted = true;
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.publishes);
    for (0..8) |_| view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.publishes);
    try std.testing.expectEqualStrings("stable-id", ui.draft.id.?);
    ui.queue(.retry_publication, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 2), manager.publishes);
    manager.fail_publish = false;
    ui.queue(.retry_publication, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 3), manager.publishes);
    try std.testing.expectEqual(view.Mode.none, ui.mode);
    try std.testing.expect(ui.failure == null);
}
test "rename is deferred and requires explicit second confirmation" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    ui.queue(.ask_rename, "first");
    view.finishWithManager(&ui, &store, &manager);
    capture(&ui.draft.name, "Renamed");
    ui.queue(.confirm, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(error.ConfirmationRequired, ui.failure.?);
    ui.queue(.submit, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expect(ui.rename_confirmed);
    try std.testing.expectEqual(@as(usize, 0), manager.renames);
    ui.queue(.confirm, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.renames);
}
test "import only supplies portable rooted folder name with unknown base placeholder" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    ui.queue(.import_folder, null);
    view.finishWithManager(&ui, &store, &manager);
    capture(&ui.draft.name, "Existing");
    ui.queue(.submit, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqualStrings("", string(&manager.captured_base));
    try std.testing.expectEqualStrings("Existing", string(&manager.captured_name));
}
test "portable case folded names and strict optional memory validation" {
    var store = try storeFixture();
    defer store.state.deinit();
    try std.testing.expectError(error.DuplicateInstanceName, view.validateName(store.snapshot(), "fIRST", null));
    try view.validateName(store.snapshot(), "first", "first");
    for ([_][]const u8{ "", "../escape", "/absolute", "name/child", "name\\child", "CON", "trailing.", "trailing " }) |name| try std.testing.expectError(error.InvalidInstanceName, view.validateName(store.snapshot(), name, null));
    try std.testing.expectEqual(@as(?u32, null), try view.parseMemory(""));
    try std.testing.expectEqual(@as(?u32, 256), try view.parseMemory("256"));
    try std.testing.expectEqual(@as(?u32, 1048576), try view.parseMemory("1048576"));
    for ([_][]const u8{ "0", "255", "1048577", "4294967296", "-1", "+512", "512 ", "1.5", "MiB" }) |memory| try std.testing.expectError(error.InvalidMemory, view.parseMemory(memory));
}
test "delete waits for explicit confirmation and can be dismissed" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    ui.queue(.ask_delete, "first");
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(view.Mode.delete_confirm, ui.mode);
    try std.testing.expectEqual(@as(usize, 0), manager.deletes);
    ui.queue(.close, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(view.Mode.options, ui.mode);
    try std.testing.expectEqual(@as(usize, 0), manager.deletes);
    ui.queue(.ask_delete, "first");
    view.finishWithManager(&ui, &store, &manager);
    ui.queue(.confirm, null);
    try std.testing.expectEqual(@as(usize, 0), manager.deletes);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.deletes);
}
test "awaiting publication preserves the draft even when manager is not busy" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    ui.queue(.edit, "first");
    view.finishWithManager(&ui, &store, &manager);
    manager.phase = .awaiting_publication;
    manager.fail_publish = true;
    try std.testing.expect(!manager.isBusy());
    ui.queue(.create, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(view.Mode.options, ui.mode);
    try std.testing.expectEqualStrings("first", ui.draft.id.?);
    try std.testing.expectEqual(@as(anyerror, error.Busy), ui.failure.?);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expect(ui.publication_failed);
    try std.testing.expectEqual(@as(usize, 1), manager.publishes);
    ui.queue(.edit, "second");
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqualStrings("first", ui.draft.id.?);
    try std.testing.expectEqual(@as(usize, 1), manager.publishes);
    ui.queue(.retry_publication, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expect(ui.publication_failed);
    try std.testing.expectEqual(@as(usize, 2), manager.publishes);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 2), manager.publishes);
}

test "selected installed form initializes once and semantic memory comparison ignores leading zeroes" {
    var store = try storeFixture();
    defer store.state.deinit();
    store.state.value.selected_instance = "first";
    @constCast(store.state.value.instances)[0].max_memory_mb = 2048;
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(view.Mode.options, ui.mode);
    const owned_id = ui.draft.id.?.ptr;
    capture(&ui.draft.memory, "02048");
    try std.testing.expect(!ui.draft.dirty());
    for (0..3) |_| view.finishWithManager(&ui, &store, &manager);
    try std.testing.expect(ui.draft.id.?.ptr == owned_id);
    try std.testing.expectEqualStrings("02048", string(&ui.draft.memory));
    capture(&ui.draft.memory, "invalid");
    try std.testing.expect(ui.draft.dirty());
}

test "create draft jumps directly to installed selection and clean installed draft switches without prompt" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    ui.queue(.create, null);
    view.finishWithManager(&ui, &store, &manager);
    capture(&ui.draft.name, "Incomplete create");
    ui.queue(.select, "first");
    try std.testing.expect(store.snapshot().selected_instance == null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqualStrings("first", store.snapshot().selected_instance.?);
    try std.testing.expect(ui.navigation == null and !ui.navigation_prompt);
    try std.testing.expectEqual(view.Mode.options, ui.mode);
    ui.queue(.select, "second");
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqualStrings("second", ui.draft.id.?);
    try std.testing.expect(ui.navigation == null and manager.saves == 0);
}

test "dirty installed navigation prompts before mutation and Cancel retains draft focus and selection" {
    for ([_]view.Action{ .select, .create, .import_folder, .import_pack, .leave }) |action| {
        var store = try storeFixture();
        defer store.state.deinit();
        var ui = view.Ui.init(std.testing.allocator);
        defer ui.deinit();
        var manager: FixtureManager = .{};
        ui.queue(.select, "first");
        view.finishWithManager(&ui, &store, &manager);
        capture(&ui.draft.name, "Changed first");
        capture(&ui.draft.java_path, "/edited/java");
        ui.form_focus = 42;
        ui.form_subwindow = 7;
        const serial = ui.navigation_serial;
        ui.queue(action, if (action == .select) "second" else null);
        view.finishWithManager(&ui, &store, &manager);
        try std.testing.expect(ui.navigation_prompt and ui.navigation != null);
        try std.testing.expectEqualStrings("first", store.snapshot().selected_instance.?);
        try std.testing.expect(manager.saves == 0 and manager.renames == 0 and manager.selects == 1);
        try std.testing.expectEqual(serial, ui.navigation_serial);
        ui.queue(.cancel_navigation, null);
        view.finishWithManager(&ui, &store, &manager);
        try std.testing.expect(ui.navigation == null and !ui.navigation_prompt and ui.restore_form_focus);
        try std.testing.expectEqual(@as(?u64, 42), ui.form_focus);
        try std.testing.expectEqual(@as(?u64, 7), ui.form_subwindow);
        try std.testing.expectEqualStrings("Changed first", string(&ui.draft.name));
        try std.testing.expectEqualStrings("/edited/java", string(&ui.draft.java_path));
        try std.testing.expectEqualStrings("first", store.snapshot().selected_instance.?);
        ui.queue(action, if (action == .select) "second" else null);
        view.finishWithManager(&ui, &store, &manager);
        ui.queue(.discard_navigation, null);
        view.finishWithManager(&ui, &store, &manager);
        try std.testing.expect(ui.navigation == null and !ui.navigation_prompt);
        try std.testing.expectEqual(serial + 1, ui.navigation_serial);
        try std.testing.expect(manager.saves == 0 and manager.renames == 0);
        switch (action) {
            .select => try std.testing.expectEqualStrings("second", store.snapshot().selected_instance.?),
            .create => try std.testing.expectEqual(view.Mode.create, ui.mode),
            .import_folder => try std.testing.expectEqual(view.Mode.import_folder, ui.mode),
            .import_pack => try std.testing.expect(ui.pack_requested),
            .leave => try std.testing.expect(ui.exit_requested),
            else => unreachable,
        }
    }
}

test "Save before navigation failure retains destination and draft then success saves before switching" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    ui.queue(.select, "first");
    view.finishWithManager(&ui, &store, &manager);
    capture(&ui.draft.java_path, "/updated/java");
    capture(&ui.draft.memory, "4096");
    ui.draft.debug_launch = true;
    var destination = "second".*;
    ui.queue(.select, &destination);
    @memset(&destination, 'x');
    view.finishWithManager(&ui, &store, &manager);
    manager.fail_save = true;
    ui.queue(.save_navigation, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(error.DiskFailure, ui.failure.?);
    try std.testing.expect(ui.navigation_prompt and ui.navigation != null);
    try std.testing.expectEqualStrings("second", ui.navigation.?.text.?);
    try std.testing.expectEqualStrings("first", store.snapshot().selected_instance.?);
    try std.testing.expect(store.snapshot().instances[0].java_path == null);
    try std.testing.expectEqualStrings("/updated/java", string(&ui.draft.java_path));
    manager.fail_save = false;
    ui.queue(.save_navigation, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expect(ui.failure == null and ui.navigation == null);
    try std.testing.expectEqualStrings("second", store.snapshot().selected_instance.?);
    try std.testing.expectEqualStrings("/updated/java", store.snapshot().instances[0].java_path.?);
    try std.testing.expectEqual(@as(?u32, 4096), store.snapshot().instances[0].max_memory_mb);
    try std.testing.expect(store.snapshot().instances[0].debug_launch);
}

test "combined rename and options save navigates only after successful publication and explicit retry" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    ui.queue(.select, "first");
    view.finishWithManager(&ui, &store, &manager);
    capture(&ui.draft.name, "Renamed first");
    capture(&ui.draft.java_path, "/combined/java");
    capture(&ui.draft.memory, "8192");
    ui.draft.debug_launch = true;
    ui.queue(.select, "second");
    view.finishWithManager(&ui, &store, &manager);
    ui.queue(.save_navigation, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.renames);
    try std.testing.expectEqual(@as(usize, 0), manager.saves);
    try std.testing.expect(ui.submitted and ui.saving_navigation and ui.navigation != null);
    try std.testing.expectEqualStrings("First", store.snapshot().instances[0].name);
    try std.testing.expectEqualStrings("first", store.snapshot().selected_instance.?);
    manager.phase = .awaiting_publication;
    manager.fail_publish = true;
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expect(ui.publication_failed and ui.navigation != null);
    try std.testing.expectEqualStrings("Renamed first", string(&ui.draft.name));
    try std.testing.expectEqualStrings("first", store.snapshot().selected_instance.?);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.publishes);
    manager.fail_publish = false;
    ui.queue(.retry_publication, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expect(ui.navigation == null and ui.failure == null);
    try std.testing.expectEqualStrings("second", store.snapshot().selected_instance.?);
    const saved = store.snapshot().instances[0];
    try std.testing.expectEqualStrings("Renamed first", saved.name);
    try std.testing.expectEqualStrings("/combined/java", saved.java_path.?);
    try std.testing.expectEqual(@as(?u32, 8192), saved.max_memory_mb);
    try std.testing.expect(saved.debug_launch);
    try std.testing.expectEqualStrings("first", saved.id);
    try std.testing.expectEqualStrings("project", saved.origin.?.project_id);
    try std.testing.expectEqualStrings("0.16.0", saved.loader_version.?);
}

test "external options edit invalidates original draft and keeps queued navigation" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    ui.queue(.select, "first");
    view.finishWithManager(&ui, &store, &manager);
    capture(&ui.draft.memory, "4096");
    ui.queue(.create, null);
    view.finishWithManager(&ui, &store, &manager);
    @constCast(store.state.value.instances)[0].debug_launch = true;
    ui.queue(.save_navigation, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(error.InstanceChanged, ui.failure.?);
    try std.testing.expect(ui.navigation_prompt and ui.navigation != null);
    try std.testing.expect(manager.saves == 0 and manager.renames == 0);
    try std.testing.expectEqualStrings("4096", string(&ui.draft.memory));
}

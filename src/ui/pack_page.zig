//! Owns the pack page, independent discovery and transactional creation lifecycle.
const std = @import("std");
const dvui = @import("dvui");
const catalog = @import("pack_catalog.zig");
const install = @import("pack_install_controller.zig");
const view = @import("pack_view.zig");
const instances_ui = @import("instances_view.zig");
const config = @import("../core/config.zig");
const paths_mod = @import("../core/instances.zig");
const providers = @import("../core/content_providers.zig");
const content = @import("../core/content_install.zig");
const manifest = @import("../core/content_manifest.zig");
const tasks = @import("../core/tasks.zig");
const model = @import("model.zig");
const A = std.mem.Allocator;
pub const Page = struct {
    allocator: A,
    io: std.Io,
    ui: view.Ui,
    browser: catalog.Controller,
    installer: install.Controller,
    lookup: enum { none, search, versions } = .none,
    opening: bool = false,
    policy: catalog.CurseForgePolicy = .{},
    inspection_policy: catalog.CurseForgePolicy = .{},
    inspected_archive: [32769]u8 = @splat(0),
    pending_query: [513]u8 = @splat(0),
    pending_minecraft: [65]u8 = @splat(0),
    pending_loader: usize = 0,
    pending_provider: usize = 0,
    pending_offset: u32 = 0,
    publication_attempted: bool = false,
    download_connections: u16 = 8,
    pub fn init(a: A, io: std.Io, paths: *const paths_mod.Paths, registry: *tasks.Registry) !Page {
        var browser = try catalog.Controller.init(a, io, .{ .transport_options = .{ .allow_curseforge = true } });
        errdefer browser.deinit();
        const installer = try install.Controller.init(a, io, paths, .{ .creation_options = .{ .task_registry = registry } });
        var ui = view.Ui.init(a);
        ui.icon_cache = @import("resource_icons.zig").Manager.init(a, io);
        return .{ .allocator = a, .io = io, .ui = ui, .browser = browser, .installer = installer };
    }
    pub fn deinit(self: *Page, services: install.Services) void {
        self.ui.deinit();
        self.browser.deinit();
        self.installer.deinit(services);
    }
    pub fn pinned(self: *const Page) bool {
        return self.installer.snapshot().phase == .creating or self.installer.ownsInstancesPublication() or self.installer.ownsJavaDiscovery() or self.installer.ownsJavaDownload();
    }
    pub fn busy(self: *const Page) bool {
        return self.installer.isBusy() or self.browser.current != null or self.browser.retired != null or (if (self.ui.icon_cache) |*icons| icons.busy() else false);
    }
    pub fn configure(self: *Page, policy: catalog.CurseForgePolicy, connections: u16) !void {
        self.download_connections = connections;
        if (std.meta.eql(self.policy, policy)) return;
        if (self.pinned()) return error.Busy;
        if (self.browser.current != null or self.browser.retired != null) {
            self.browser.cancel();
            self.lookup = .none;
            return; // Retry after tick retires canceled workers without blocking the UI.
        }
        var replacement = try catalog.Controller.init(self.allocator, self.io, .{ .transport_options = .{ .allow_curseforge = true }, .curseforge = policy });
        errdefer replacement.deinit();
        self.browser.deinit();
        self.browser = replacement;
        self.policy = policy;
        self.lookup = .none;
    }
    fn resetInstaller(self: *Page, services: install.Services) !void {
        if (self.installer.isBusy() or self.pinned()) return error.Busy;
        var options = self.installer.core.options;
        options.backend_options.download_connections = self.download_connections;
        options.backend_options.transport_options.allow_curseforge = true;
        // Official CDN documented at https://blog.curseforge.com/introducing-api-key-authentication-for-curseforge-file-downloads/
        options.backend_options.transport_options.approved_download_hosts = &.{ "cdn.modrinth.com", "edge.forgecdn.net" };
        options.backend_options.source_policy = .{ .enabled = self.policy.enabled, .terms_approved = self.policy.terms_approved, .credential_ref = self.policy.credential_ref };
        const next = try install.Controller.init(self.allocator, self.io, &self.installer.core.paths, options);
        self.installer.deinit(services);
        self.installer = next;
        self.inspection_policy = self.policy;
        self.opening = false;
        self.ui.task_visible = false;
        self.publication_attempted = false;
    }
    fn readArchive(self: *Page, services: install.Services) !void {
        try self.resetInstaller(services);
        const path = view.text(&self.ui.archive);
        try self.installer.inspectLocal(path);
        self.ui.task_visible = true;
        self.ui.return_route = .local;
        try view.setText(&self.inspected_archive, path);
    }
    fn cancelIcons(self: *Page) void {
        if (self.ui.icon_cache) |*icons| {
            for (icons.entries.items) |*entry| entry.pending = false;
            if (icons.active) |job| job.cancel.store(true, .release);
        }
    }
    pub fn cancel(self: *Page, services: install.Services) void {
        self.cancelIcons();
        self.browser.cancel();
        self.lookup = .none;
        self.opening = false;
        self.ui.discardPicker();
        self.installer.cancel(services);
    }
    pub fn syncActive(self: *Page, active: bool, services: install.Services) void {
        if (self.ui.active and !active) {
            self.browser.cancel();
            self.lookup = .none;
            self.ui.discardPicker();
            if (!self.pinned()) {
                self.installer.cancel(services);
                self.opening = false;
            }
        }
        if (active and !self.ui.active and !self.ui.searched and self.lookup == .none and self.ui.route == .catalog) self.search(0, true) catch |err| {
            self.ui.failure = err;
        };
        if (!active) self.cancelIcons();
        self.ui.active = active;
    }
    pub fn tick(self: *Page, services: install.Services, allowed: bool) void {
        if (!allowed) self.cancelIcons();
        if (self.ui.icon_cache) |*icons| icons.poll(.{});
        self.browser.tick();
        self.installer.tickWithMutations(services, allowed);
        self.tickResults(services) catch |err| {
            self.ui.failure = err;
        };
    }
    fn tickResults(self: *Page, services: install.Services) !void {
        const result = self.browser.snapshot();
        if (!result.busy and self.lookup != .none) {
            const kind = self.lookup;
            self.lookup = .none;
            if (self.ui.active) {
                if (result.failure) |err| {
                    self.ui.failure = err;
                } else {
                    switch (kind) {
                        .search => {
                            try self.ui.acceptCatalog(result.catalog, result.total);
                            self.ui.submitted_query = self.pending_query;
                            self.ui.submitted_minecraft = self.pending_minecraft;
                            self.ui.submitted_loader = self.pending_loader;
                            self.ui.submitted_provider = self.pending_provider;
                            self.ui.offset = self.pending_offset;
                            self.ui.catalog_scroll = .{};
                        },
                        .versions => try self.ui.acceptVersions(result.versions),
                        .none => unreachable,
                    }
                }
            }
        }
        const state = self.installer.snapshot();
        if (self.opening and !state.busy) {
            self.opening = false;
            if (self.ui.active and state.phase == .ready) {
                self.ui.return_route = .detail;
                self.ui.task_visible = false;
                try self.confirm(services);
            }
        }
        // Local inspection stays on the file page; failures remain in the task modal.
        if (self.ui.route == .local and state.phase == .ready) self.ui.task_visible = false;
        if (self.ui.picker_ticket) |ticket| if (self.ui.picker_service) |picker| if (picker.take(ticket)) |receipt| {
            var owned = receipt;
            defer owned.deinit();
            const manual = self.ui.picker_manual;
            self.ui.picker_ticket = null;
            self.ui.picker_manual = null;
            if (!self.ui.active) return;
            if (owned.failure) |err| return err;
            if (owned.path) |path| {
                if (manual) |index| try self.selectManual(index, path) else {
                    try view.setText(&self.ui.archive, path);
                    try self.readArchive(services);
                }
            }
        };
    }
    fn confirm(self: *Page, services: install.Services) !void {
        const state = self.installer.snapshot();
        const pack = state.pack_plan orelse return error.MissingInspection;
        var choices: std.ArrayList(install.OptionalChoice) = .empty;
        defer choices.deinit(self.allocator);
        for (pack.files) |file| if (!file.required) try choices.append(self.allocator, .{ .path = file.record.path, .include = file.selected orelse false });
        try self.installer.setDecisions(state.manual_files, choices.items);
        try view.setText(&self.ui.name, "整合包实例");
        if (pack.name.len < self.ui.name.len and config.validId(pack.name)) try view.setText(&self.ui.name, pack.name);
        var suffix: usize = 2;
        const base = try self.allocator.dupe(u8, view.text(&self.ui.name));
        defer self.allocator.free(base);
        while (true) : (suffix += 1) {
            instances_ui.validateName(services.store.snapshot(), view.text(&self.ui.name), null) catch |err| {
                if (err != error.DuplicateInstanceName) return err;
                const next = try std.fmt.allocPrint(self.allocator, "{s} {d}", .{ base, suffix });
                defer self.allocator.free(next);
                try view.setText(&self.ui.name, next);
                continue;
            };
            break;
        }
        self.ui.route = .confirm;
        self.ui.failure = null;
        self.ui.detail_scroll = .{};
    }
    fn loader(choice: usize) ?@import("../core/config.zig").Loader {
        return switch (choice) {
            1 => .fabric,
            2 => .forge,
            3 => .neoforge,
            4 => .quilt,
            else => null,
        };
    }
    fn filter(self: *Page) catalog.Filter {
        const game = std.mem.trim(u8, view.text(&self.ui.submitted_minecraft), " ");
        return .{ .minecraft_version = if (game.len == 0) null else game, .loader = loader(self.ui.submitted_loader) };
    }
    fn search(self: *Page, offset: u32, fresh: bool) !void {
        const query = if (fresh) self.ui.query else self.ui.submitted_query;
        const minecraft = if (fresh) self.ui.minecraft else self.ui.submitted_minecraft;
        const selected_loader = if (fresh) self.ui.loader_choice else self.ui.submitted_loader;
        const provider = if (fresh) self.ui.provider_choice else self.ui.submitted_provider;
        const game = std.mem.trim(u8, view.text(&minecraft), " ");
        try self.browser.search(.{ .query = view.text(&query), .provider = if (provider == 0) .modrinth else .curseforge, .filter = .{ .minecraft_version = if (game.len == 0) null else game, .loader = loader(selected_loader) }, .offset = offset });
        self.pending_query = query;
        self.pending_minecraft = minecraft;
        self.pending_loader = selected_loader;
        self.pending_provider = provider;
        self.pending_offset = offset;
        self.lookup = .search;
    }
    fn selectManual(self: *Page, index: usize, absolute: []const u8) !void {
        const state = self.installer.snapshot();
        const pack = state.pack_plan orelse return error.MissingInspection;
        if (index >= pack.files.len or pack.files[index].download != .manual_required) return error.UnknownPackFile;
        const path = pack.files[index].record.path;
        var mappings: std.ArrayList(content.ManualFile) = .empty;
        defer mappings.deinit(self.allocator);
        for (state.manual_files) |file| if (!std.mem.eql(u8, file.path, path)) try mappings.append(self.allocator, file);
        try mappings.append(self.allocator, .{ .path = path, .source_absolute_path = absolute });
        try self.installer.setDecisions(mappings.items, state.optional);
    }
    pub fn finish(self: *Page, state_model: *model.Model, navigation: *instances_ui.Ui, services: install.Services, allowed: bool) void {
        if (!allowed) {
            self.ui.pending = null;
            return;
        }
        if (self.installer.snapshot().creation.phase == .awaiting_publication and !self.publication_attempted) {
            self.publication_attempted = true;
            self.installer.publish(services, true) catch |err| {
                self.ui.failure = err;
            };
        }
        const intent = self.ui.pending orelse return;
        self.ui.pending = null;
        self.ui.failure = null;
        self.apply(intent, state_model, navigation, services) catch |err| {
            self.ui.failure = err;
        };
    }
    fn apply(self: *Page, intent: view.Intent, state_model: *model.Model, navigation: *instances_ui.Ui, services: install.Services) !void {
        switch (intent) {
            .search => try self.search(0, true),
            .page => |offset| try self.search(offset, false),
            .refresh => if (self.ui.route == .detail) {
                try self.browser.loadVersions(self.ui.project orelse return error.NoProject, self.filter());
                self.lookup = .versions;
            } else try self.search(self.ui.offset, false),
            .project => |index| {
                try self.resetInstaller(services);
                try self.ui.openProject(index);
                try self.browser.loadVersions(self.ui.project.?, self.filter());
                self.lookup = .versions;
            },
            .back => {
                if (self.pinned()) return;
                self.browser.cancel();
                self.lookup = .none;
                self.opening = false;
                self.ui.discardPicker();
                self.installer.cancel(services);
                switch (self.ui.route) {
                    .catalog => {
                        navigation.queue(.close, null);
                        state_model.panel = .instances;
                    },
                    .detail, .local => self.ui.route = .catalog,
                    .confirm => self.ui.route = self.ui.return_route,
                }
            },
            .import_file => {
                try self.resetInstaller(services);
                self.ui.route = .local;
                self.ui.detail_scroll = .{};
            },
            .choose_archive, .manual => {
                const picker = self.ui.picker_service orelse return error.FilePickerUnavailable;
                self.ui.picker_ticket = try picker.request(.{ .kind = .file, .title = if (intent == .manual) "选择下载的整合包文件" else "选择整合包归档", .extensions = if (intent == .manual) null else "mrpack;zip" });
                self.ui.picker_manual = if (intent == .manual) intent.manual else null;
            },
            .inspect_archive => try self.readArchive(services),
            .prepare => {
                if (self.ui.route == .local) {
                    self.ui.return_route = .local;
                    try self.confirm(services);
                } else {
                    try self.resetInstaller(services);
                    try self.installer.inspectOnline(self.ui.version() orelse return error.NoVersion);
                    self.opening = true;
                    self.ui.return_route = .detail;
                    self.ui.task_visible = true;
                }
            },
            .optional => |decision| {
                const snapshot = self.installer.snapshot();
                const pack = snapshot.pack_plan orelse return error.MissingInspection;
                if (decision.index >= pack.files.len) return error.UnknownPackFile;
                const path = pack.files[decision.index].record.path;
                var choices: std.ArrayList(install.OptionalChoice) = .empty;
                defer choices.deinit(self.allocator);
                for (snapshot.optional) |choice| if (!std.mem.eql(u8, choice.path, path)) try choices.append(self.allocator, choice);
                try choices.append(self.allocator, .{ .path = path, .include = decision.include });
                try self.installer.setDecisions(snapshot.manual_files, choices.items);
            },
            .install => {
                if (!std.meta.eql(self.inspection_policy, self.policy)) return error.SourcePolicyChanged;
                const name = view.text(&self.ui.name);
                try instances_ui.validateName(services.store.snapshot(), name, null);
                var random: [16]u8 = undefined;
                try self.io.randomSecure(&random);
                const id = try std.fmt.allocPrint(self.allocator, "instance-{s}", .{std.fmt.bytesToHex(random, .lower)});
                defer self.allocator.free(id);
                try self.installer.start(.{ .id = id, .name = name, .minecraft_version = "", .java_path = null }, services);
                self.publication_attempted = false;
                self.ui.task_visible = true;
            },
            .cancel => self.installer.cancel(services),
            .dismiss => {
                self.ui.task_visible = false;
                self.ui.route = self.ui.return_route;
            },
            .retry_publication => {
                if (services.store.publicationUncertain()) try services.store.reconcile();
                try self.installer.publish(services, true);
                self.publication_attempted = true;
            },
            .view_instance => {
                const row = self.installer.snapshot().creation.instance orelse return error.MissingCreatedInstance;
                navigation.queue(.select, row.id);
                state_model.panel = .instances;
                self.ui.task_visible = false;
            },
        }
    }
    pub fn presentation(self: *Page, a: A) !view.Presentation {
        const state = self.installer.snapshot();
        var pack = state.pack_plan;
        if (self.ui.route == .local and !std.mem.eql(u8, view.text(&self.ui.archive), view.text(&self.inspected_archive))) pack = null;
        var manual: std.ArrayList(view.Manual) = .empty;
        if (pack) |*p| {
            const files = try a.dupe(manifest.InstallFile, p.files);
            p.files = files;
            for (files, 0..) |*file, index| {
                for (state.optional) |choice| if (std.mem.eql(u8, choice.path, file.record.path)) {
                    file.selected = choice.include;
                };
                if (!file.required and file.selected == false) continue;
                if (file.download == .manual_required) {
                    var chosen = false;
                    for (state.manual_files) |mapping| if (std.mem.eql(u8, mapping.path, file.record.path)) {
                        chosen = true;
                    };
                    try manual.append(a, .{ .path = file.record.path, .url = file.download.manual_required.official_page, .verified = chosen, .index = index });
                }
            }
        }
        const phase = state.creation.phase;
        const details = self.installer.details();
        const stage: []const u8 = switch (state.phase) {
            .idle => "等待选择整合包",
            .inspecting => switch (details.stage) {
                .downloading => "正在下载整合包归档",
                .verifying => "正在校验整合包归档",
                .extracting => "正在解压并读取整合包",
                else => "正在准备整合包来源",
            },
            .ready => "整合包已准备",
            .complete => "整合包文件已校验，实例创建完成。",
            .failed => "安装失败，请检查后重新创建。",
            .canceled => "安装已取消。",
            .creating => switch (phase) {
                .preparing => "正在准备游戏元数据",
                .discovering_java, .probing_java => "正在选择并验证 Java",
                .downloading_java => "正在下载 Java",
                .awaiting_publication => "正在保存实例",
                .awaiting_reconciliation => "配置发布状态待确认，请重新加载配置后重试。",
                .cleaning => "正在取消并清理",
                else => switch (details.stage) {
                    .downloading => "正在下载游戏与整合包文件",
                    .verifying => "正在校验游戏与整合包文件",
                    .extracting => "正在解压整合包文件",
                    .finalizing => "正在完成实例安装",
                    else => "正在安装游戏与整合包文件",
                },
            },
        };
        const total = if (details.stage == .downloading) details.total_bytes else details.total;
        const completed = if (details.stage == .downloading) details.received else details.completed;
        const fraction: ?f32 = if (total) |count| if (count > 0) @min(1, @as(f32, @floatFromInt(completed)) / @as(f32, @floatFromInt(count))) else null else null;
        return .{ .busy = state.busy or self.browser.snapshot().busy, .curseforge_available = self.browser.snapshot().curseforge_available, .pack = pack, .manual = manual.items, .ready = state.phase == .ready and state.blocker == null, .failure = state.failure, .stage = stage, .details = details, .fraction = fraction, .publication_pending = phase == .awaiting_publication or phase == .awaiting_reconciliation, .task = if (!self.ui.task_visible) .none else switch (state.phase) {
            .complete => .complete,
            .failed => .failed,
            .canceled => .canceled,
            else => .working,
        } };
    }
};

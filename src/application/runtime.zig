//! Main-thread scheduling and shutdown for application-owned workers.
//! App owns storage and destruction; this borrowed assembly is rebuilt per call.
const config = @import("../core/config.zig");
const tasks = @import("../core/tasks.zig");
const creation = @import("instance_creation_controller.zig");

pub const Runtime = struct {
    store: *config.Store,
    tasks: *tasks.Registry,
    library: *@import("game_library.zig").Controller,
    java: *@import("java_manager.zig").Manager,
    java_download: *@import("java_download_controller.zig").Controller,
    launcher: *@import("game_launch.zig").Controller,
    leases: *@import("../core/instance_leases.zig").Coordinator,
    servers: *@import("server_manager.zig").Manager,
    worlds: *@import("worlds_manager.zig").Manager,
    accounts: *@import("accounts_manager.zig").Manager,
    instances: *@import("instances_manager.zig").Manager,
    content: *@import("content_manager.zig").Manager,
    mods: *@import("mods_controller.zig").Controller,
    credentials: ?*@import("curseforge_credentials_controller.zig").Controller,
    proxy_settings: ?*@import("proxy_settings_controller.zig").Controller = null,
    ordinary_creation: *creation.Controller,
    pack_creation: *@import("pack_install_controller.zig").Controller,
    pack_catalog: *@import("pack_catalog.zig").Controller,

    pub fn creationServices(self: Runtime) creation.Services {
        return .{ .store = self.store, .java = self.java, .java_download = self.java_download, .instances = self.instances };
    }

    pub fn tick(self: Runtime, allow_mutations: bool) void {
        // Capture ownership before advancing either coordinator. Creation retains
        // its workers through cancellation and terminal presentation until joined.
        const owners = self.ordinary_creation.ownership().merge(self.pack_creation.ownership());
        self.library.tick();
        self.pack_catalog.tick();
        _ = owners.tickJava(self.java);
        self.launcher.tick();
        self.leases.tick();
        _ = owners.tickJavaDownload(self.java_download, self.java);
        self.servers.tick();
        self.worlds.tick();
        self.accounts.tick(self.store);
        _ = owners.tickInstances(self.instances);
        self.ordinary_creation.tickWithMutations(self.creationServices(), allow_mutations);
        self.pack_creation.tickWithMutations(self.creationServices(), allow_mutations);
        self.content.tick();
        self.mods.tick(self.content);
        if (self.credentials) |controller| controller.tick(self.store);
        if (self.proxy_settings) |controller| controller.tick(self.store);
    }

    pub fn shutdownSummary(self: Runtime) @import("../core/shutdown.zig").Summary {
        var result: @import("../core/shutdown.zig").Summary = .{};
        const ordinary = self.ordinary_creation.ownership();
        const pack = self.pack_creation.ownership();
        const owners = ordinary.merge(pack);
        if (pack.pinned) result.add(.pack_install);
        if (ordinary.pinned or (!pack.instances_publication and self.instances.isBusy() and self.instances.snapshot().operation == .creating)) result.add(.instance_install);
        if (self.java_download.isBusy() and !owners.java_download) result.add(.java_install);
        if (self.content.shutdownOperation()) |operation| result.add(operation);
        if (self.worlds.shutdownOperation()) |operation| result.add(operation);
        return result;
    }

    /// Called once after the user has consented, or immediately for auxiliary work.
    /// Never blanket-cancel the registry: local committed edits must finish.
    pub fn beginShutdown(self: Runtime) void {
        self.ordinary_creation.cancel(self.creationServices());
        self.pack_creation.cancel(self.creationServices());
        self.library.cancelAll();
        self.pack_catalog.cancel();
        self.java.cancelSearch();
        self.java_download.cancel();
        self.servers.cancel();
        self.worlds.beginShutdown();
        self.accounts.beginShutdown();
        const operation = self.instances.snapshot().operation;
        if (operation == .creating or operation == .loading_loaders) self.instances.cancel();
        self.content.beginShutdown();
        self.mods.cancel();
        if (self.proxy_settings) |controller| {
            const phase = controller.snapshot().phase;
            if (phase == .testing or phase == .detecting) controller.cancel();
        }
    }

    /// A confirmation blocks new UI intents, not completion of accepted work.
    pub fn finishAccepted(self: Runtime) void {
        const services = self.creationServices();
        const ordinary = self.ordinary_creation.snapshot();
        if (ordinary.phase == .awaiting_publication and ordinary.failure == null) {
            self.ordinary_creation.publishOrdinary(services, true) catch {};
        }
        const pack = self.pack_creation.snapshot();
        if (pack.creation.phase == .awaiting_publication and pack.failure == null) {
            self.pack_creation.publish(services, true) catch {};
        }
        const owners = self.ordinary_creation.ownership().merge(self.pack_creation.ownership());
        const instance = self.instances.snapshot();
        if (!owners.instances_publication and instance.phase == .awaiting_publication and instance.failure == null) {
            self.instances.publish(self.store) catch {};
        }
    }

    /// Workers are advanced by tick(false); pending short mutations still publish.
    pub fn finishShutdown(self: Runtime) void {
        const owners = self.ordinary_creation.ownership().merge(self.pack_creation.ownership());
        if (!owners.instances_publication) self.instances.finishShutdown(self.store);
        self.accounts.finishShutdown(self.store);
    }

    /// Count outstanding work, including workers whose task is already terminal
    /// but whose resources still require a main-thread join. Used as a drain gate.
    pub fn activeCount(self: Runtime) usize {
        var count: usize = 0;
        for (self.tasks.tasks()) |task| switch (task.state) {
            .queued, .running, .canceling => count += 1,
            else => {},
        };
        if (self.library.isBusy()) count += 1;
        if (self.pack_catalog.current != null or self.pack_catalog.retired != null) count += 1;
        if (self.java.isSearching()) count += 1;
        if (self.java_download.isBusy()) count += 1;
        if (self.servers.isBusy()) count += 1;
        if (self.worlds.snapshot().worker_active) count += 1;
        if (self.accounts.shutdownBusy()) count += 1;
        if (self.instances.isBusy()) count += 1;
        if (self.content.isBusy()) count += 1;
        if (self.mods.busy()) count += 1;
        // Retained credential recovery debt blocks editing, not process shutdown.
        if (self.credentials) |controller| if (controller.snapshot().worker_active) {
            count += 1;
        };
        if (self.proxy_settings) |controller| if (controller.isBusy()) {
            count += 1;
        };
        if (self.ordinary_creation.ownership().pinned) count += 1;
        if (self.pack_creation.isBusy() or self.pack_creation.ownership().pinned) count += 1;
        return count;
    }
};

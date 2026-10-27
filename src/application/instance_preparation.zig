//! Worker-only metadata preparation shared by creation and existing-instance checks.
//! Targets borrow their strings; callers retain them and adapter contexts until JOIN.
//! Returned proofs own their data and must be deinitialized by their consumer.
const std = @import("std");
const config = @import("../core/config.zig");
const metadata = @import("../core/minecraft/metadata/root.zig");
const metadata_loader = @import("../core/minecraft/metadata_loader.zig");
const http = @import("../core/http_transport.zig");
const details = @import("../core/install/download_details.zig");
const tasks = @import("../core/tasks.zig");
const A = std.mem.Allocator;
const Io = std.Io;

pub const Control = struct {
    cancel: *const std.atomic.Value(bool),
    task: ?*tasks.Task = null,

    pub fn check(self: Control) !void {
        if (self.cancel.load(.acquire)) return error.Canceled;
    }
};

pub const VanillaPreparationAdapter = struct {
    context: ?*anyopaque = null,
    prepare: *const fn (?*anyopaque, A, Io, metadata_loader.VanillaTarget, Control) anyerror!metadata_loader.PreparedVanilla = prepareVanilla,
};

pub fn vanillaTarget(root: []const u8, instance: config.Instance, generation: u64, env: metadata.rules.Environment) !metadata_loader.VanillaTarget {
    if (instance.loader != .vanilla) return error.InvalidLoader;
    return .{ .root = root, .instance_id = instance.id, .instance_name = instance.name, .version_id = instance.minecraft_version, .generation = generation, .environment = env };
}

pub fn existingVanillaTarget(root: []const u8, instance: config.Instance, generation: u64) !metadata_loader.VanillaTarget {
    return vanillaTarget(root, instance, generation, try environment());
}

fn prepareVanilla(_: ?*anyopaque, a: A, io: Io, target: metadata_loader.VanillaTarget, control: Control) !metadata_loader.PreparedVanilla {
    try control.check();
    var client = try http.Client.init(a, io, .{});
    defer client.deinit();
    var observer: details.HttpObserver = .{ .task = control.task, .path = metadata.version_manifest_url };
    return prepareWithClient(a, io, target, control, &client, &observer) catch |err| {
        observer.fail(err);
        return err;
    };
}

fn prepareWithClient(a: A, io: Io, target: metadata_loader.VanillaTarget, control: Control, client: *http.Client, observer: *details.HttpObserver) !metadata_loader.PreparedVanilla {
    var response = try client.execute(.{ .url = metadata.version_manifest_url, .cancel = control.cancel, .max_response_bytes = 16 * 1024 * 1024, .require_public_address = true, .observer = if (control.task != null) observer.observer() else null });
    defer response.deinit();
    try control.check();
    if (response.status != 200) return error.MetadataHttpFailure;
    var manifest = try metadata.manifest.parseSlice(a, response.body);
    defer manifest.deinit();
    const Source = struct {
        client: *http.Client,
        control: Control,
        fn fetch(raw: ?*anyopaque, allocator: A, _: Io, request: metadata_loader.Request) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try self.control.check();
            var detail: details.HttpObserver = .{ .task = self.control.task, .path = request.url };
            var result = self.client.execute(.{ .url = request.url, .cancel = self.control.cancel, .max_response_bytes = request.max_bytes, .require_public_address = true, .observer = if (self.control.task != null) detail.observer() else null }) catch |err| {
                detail.fail(err);
                return err;
            };
            defer result.deinit();
            try self.control.check();
            if (result.status != 200) return error.MetadataHttpFailure;
            return allocator.dupe(u8, result.body);
        }
    };
    var source: Source = .{ .client = client, .control = control };
    var proof = try metadata_loader.prepareVanilla(a, io, .{ .target = target, .vanilla = .{ .version_id = target.version_id, .manifest = manifest.value, .cancel = control.cancel }, .fetcher = .{ .context = &source, .fetch = Source.fetch } });
    errdefer proof.deinit();
    try control.check();
    return proof;
}

pub fn environment() !metadata.rules.Environment {
    const target = @import("builtin").target;
    return .{
        .os_name = switch (target.os.tag) {
            .linux => "linux",
            .windows => "windows",
            .macos => "osx",
            else => return error.UnsupportedPlatform,
        },
        .arch = switch (target.cpu.arch) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            .x86 => "x86",
            else => return error.UnsupportedArchitecture,
        },
    };
}

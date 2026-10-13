//! Bind loader-prepared metadata to the Mojang artifact installation pipeline.
const std = @import("std");
const minecraft = @import("../minecraft/install.zig");
const installation = @import("../install/root.zig");
const reservation = @import("../install/namespace.zig");
const instances = @import("../instances.zig");
const downloader = @import("../downloader.zig");
const metadata = @import("install.zig");

/// Prepared remains borrowed through subsequent loader installation and JOIN.
pub fn runPrepared(a: std.mem.Allocator, io: std.Io, service: *downloader.Service, config: minecraft.Config, prepared: *const metadata.PreparedMetadata, target: metadata.MetadataTarget, control: installation.Control) !minecraft.Installed {
    try minecraft.validateConfig(config);
    const token = try reservation.reserve(io, config.namespace_token, config.worker_checks);
    defer if (config.namespace_token == null) token.release();
    var reserved_config = config;
    reserved_config.namespace_token = token;
    try control.check();
    if (!std.mem.eql(u8, config.version_id, target.selection.base_id)) return error.PreparedMetadataMismatch;
    var expected_paths = try instances.Paths.init(a, io, target.root);
    defer expected_paths.deinit();
    var actual_paths = try instances.Paths.init(a, io, config.root);
    defer actual_paths.deinit();
    if (!std.mem.eql(u8, actual_paths.root, expected_paths.minecraft)) return error.PreparedMetadataMismatch;
    // Bind the real planner environment rather than an earlier caller snapshot.
    var bound_target = target;
    bound_target.environment = config.environment;
    const loaded = try prepared.replayBase(a, io, bound_target, control);
    return minecraft.runLoaded(a, io, service, reserved_config, loaded, control);
}

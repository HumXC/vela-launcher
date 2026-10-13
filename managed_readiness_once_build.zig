//! Build-only explicit read-only prerequisite audit; never execute by default.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    if (target.result.os.tag != .linux) @panic("This one-shot audit is for the owned Linux workspace");
    const curl = b.dependency("curl", .{
        .target = target,
        .optimize = optimize,
        .link_vendor = true,
        .mbedtls_pthreads = true,
    });
    const nbt = b.dependency("nbt", .{ .target = target, .optimize = optimize });
    const module = b.createModule(.{
        .root_source_file = b.path("src/managed_readiness_once.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "curl", .module = curl.module("curl") },
            .{ .name = "nbt", .module = nbt.module("nbt") },
            .{ .name = "nbt_compression", .module = b.createModule(.{
                .root_source_file = b.path("src/core/worlds_gzip.zig"),
                .target = target,
                .optimize = optimize,
            }) },
        },
    });
    const exe = b.addExecutable(.{ .name = "vela-audit-existing-once", .root_module = module });
    b.step("build-readiness-once", "Compile/install explicit opt-in read-only audit; never execute")
        .dependOn(&b.addInstallArtifact(exe, .{}).step);
}

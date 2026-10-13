const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const curl = b.dependency("curl", .{
        .target = target,
        .optimize = optimize,
        .link_vendor = true,
        .mbedtls_pthreads = target.result.os.tag == .linux or target.result.os.tag.isDarwin(),
    });
    const nbt = b.dependency("nbt", .{ .target = target, .optimize = optimize });
    const module = b.createModule(.{
        .root_source_file = b.path("src/path_contract_checks.zig"),
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
    module.addImport("test_allocations", b.createModule(.{ .root_source_file = b.path("src/test_allocations.zig") }));
    if (target.result.os.tag == .linux)
        module.addImport("linux_c", @import("build-support/linux_c.zig").create(b, target, optimize));
    const filter = b.option([]const u8, "test-filter", "Select offline regression tests") orelse "path contract";
    const tests = b.addTest(.{ .root_module = module, .filters = &.{filter} });
    b.step("compile", "Compile selected tests without running (also for cross targets)").dependOn(&tests.step);
    const run = b.addRunArtifact(tests);
    b.default_step.dependOn(&run.step);
}

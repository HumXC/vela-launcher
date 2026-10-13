//! Explicit compile/install only. Never registered with the launcher test root.
const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    if (target.result.os.tag != .linux or target.result.abi.isMusl())
        @panic("Native vault acceptance requires Linux with dynamic libc");
    const module = b.createModule(.{
        .root_source_file = b.path("src/native_vault_acceptance.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("linux_c", @import("build-support/linux_c.zig").create(b, target, optimize));
    const tests = b.addTest(.{
        .name = "vela-native-vault-acceptance",
        .root_module = module,
        .filters = &.{"owned native vault acceptance"},
    });
    const install = b.addInstallArtifact(tests, .{});
    b.step("native-vault-acceptance", "Compile/install owned Linux vault acceptance; never execute")
        .dependOn(&install.step);
}

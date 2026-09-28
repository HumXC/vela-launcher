const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdl = b.dependency("sdl", .{
        .optimize = optimize,
        .target = target,
    });
    const sdl_lib = sdl.artifact("SDL3");

    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
    });
    const dvui = dvui_dep.module("dvui_sdl3");
    dvui.linkLibrary(sdl_lib);

    const curl_dep = b.dependency("curl", .{
        .target = target,
        .optimize = optimize,
        .link_vendor = true,
    });

    const clap_dep = b.dependency("clap", .{});

    const exe = b.addExecutable(.{
        .name = "vela-launcher",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/app.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "curl", .module = curl_dep.module("curl") },
                .{ .name = "clap", .module = clap_dep.module("clap") },
                .{ .name = "dvui", .module = dvui },
            },
        }),
    });

    const compile_step = b.step("compile-app", "Compile App");
    compile_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    b.getInstallStep().dependOn(compile_step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(compile_step);

    const run_step = b.step("run", "Run App");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Test the examples");
    const test_cmd = b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module, .name = "test-app" }));
    test_step.dependOn(&test_cmd.step);
}

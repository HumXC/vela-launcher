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
        // Independent download services may use TLS from multiple OS threads.
        .mbedtls_pthreads = target.result.os.tag == .linux or target.result.os.tag.isDarwin(),
    });

    const clap_dep = b.dependency("clap", .{});

    const zio_dep = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });

    const dusty_dep = b.dependency("dusty", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "vela-launcher",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/app.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dvui", .module = dvui },
                .{ .name = "curl", .module = curl_dep.module("curl") },
                .{ .name = "clap", .module = clap_dep.module("clap") },
                .{ .name = "zio", .module = zio_dep.module("zio") },
                .{ .name = "dusty", .module = dusty_dep.module("dusty") },
            },
        }),
    });

    const downloader_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core/downloader_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "curl", .module = curl_dep.module("curl") }},
    }) });
    const download_test_step = b.step("test-downloader", "Test downloader against local HTTP fixture");
    download_test_step.dependOn(&b.addRunArtifact(downloader_tests).step);

    const mc = b.addExecutable(.{ .name = "vela-mc", .root_module = b.createModule(.{
        .root_source_file = b.path("src/mc_cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "curl", .module = curl_dep.module("curl") }},
    }) });
    const mc_install = b.addInstallArtifact(mc, .{});
    b.step("mc-cli", "Build headless Minecraft installer and launcher").dependOn(&mc_install.step);
    const mc_run = b.addRunArtifact(mc);
    if (b.args) |args| mc_run.addArgs(args);
    b.step("mc", "Install or launch Minecraft without UI").dependOn(&mc_run.step);
    const mc_tests = b.addTest(.{ .root_module = mc.root_module });
    b.step("test-minecraft", "Test Minecraft installation and launch modules").dependOn(&b.addRunArtifact(mc_tests).step);

    const compile_step = b.step("compile-app", "Compile App");
    compile_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    b.getInstallStep().dependOn(compile_step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(compile_step);

    const run_step = b.step("run", "Run App");
    run_step.dependOn(&run_cmd.step);

    const metadata_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core/minecraft/metadata/root.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const metadata_test_step = b.step("test-metadata", "Test independent Minecraft metadata parsing");
    metadata_test_step.dependOn(&b.addRunArtifact(metadata_tests).step);

    const test_step = b.step("test", "Test the examples");
    const test_cmd = b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module, .name = "test-app" }));
    test_step.dependOn(&test_cmd.step);
}

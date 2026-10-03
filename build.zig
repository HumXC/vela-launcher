const std = @import("std");
const macos_sdk = @import("build-support/macos_sdk.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sdk = macos_sdk.choose(b, target.result.os.tag);
    const sdl = b.dependency("sdl", .{ .target = target, .optimize = optimize });
    const dvui_dep = if (sdk) |root| b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
        .system_include_path = @as(std.Build.LazyPath, .{ .cwd_relative = b.pathJoin(&.{ root, "usr/include" }) }),
        .system_framework_path = @as(std.Build.LazyPath, .{ .cwd_relative = b.pathJoin(&.{ root, "System/Library/Frameworks" }) }),
        .library_path = @as(std.Build.LazyPath, .{ .cwd_relative = "/usr/lib" }),
    }) else b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3 });
    const dvui = dvui_dep.module("dvui_sdl3");
    dvui.linkLibrary(sdl.artifact("SDL3"));
    const curl_dep = b.dependency("curl", .{
        .target = target,
        .optimize = optimize,
        .link_vendor = true,
        // Independent download services may use TLS from multiple OS threads.
        .mbedtls_pthreads = target.result.os.tag == .linux or target.result.os.tag.isDarwin(),
    });
    if (target.result.os.tag == .windows) {
        disableWindowsTranslationFortify(dvui_dep.module("sdl3").import_table.get("sdl3-c").?);
        disableWindowsTranslationFortify(dvui.import_table.get("dvui-c").?);
        disableWindowsTranslationFortify(curl_dep.module("curl").import_table.get("c").?);
    }
    const clap_dep = b.dependency("clap", .{});
    const zio_dep = b.dependency("zio", .{ .target = target, .optimize = optimize });
    const nbt_dep = b.dependency("nbt", .{ .target = target, .optimize = optimize });
    const nbt_module = nbt_dep.module("nbt");
    const nbt_compression = b.createModule(.{
        .root_source_file = b.path("src/core/worlds_gzip.zig"),
        .target = target,
        .optimize = optimize,
    });
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "dvui", .module = dvui },
            .{ .name = "curl", .module = curl_dep.module("curl") },
            .{ .name = "clap", .module = clap_dep.module("clap") },
            .{ .name = "zio", .module = zio_dep.module("zio") },
            .{ .name = "nbt", .module = nbt_module },
            .{ .name = "nbt_compression", .module = nbt_compression },
        },
    });
    if (target.result.os.tag == .macos) {
        app_mod.linkFramework("Security", .{});
        app_mod.linkFramework("CoreFoundation", .{});
    }
    if (sdk) |root| macos_sdk.apply(b, app_mod, root);
    const exe = b.addExecutable(.{ .name = "vela", .root_module = app_mod });
    if (target.result.os.tag == .windows) exe.subsystem = .windows;
    const gui_fixture = b.addExecutable(.{
        .name = "vela-gui-fixture",
        .root_module = cloneAppModule(b, app_mod, b.path("src/gui_acceptance.zig")),
    });
    if (target.result.os.tag == .windows) gui_fixture.subsystem = .windows;
    b.step("build-gui-fixture", "Build isolated GUI acceptance fixture").dependOn(&b.addInstallArtifact(gui_fixture, .{}).step);
    const compile_step = b.step("compile-app", "Compile App");
    compile_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    b.getInstallStep().dependOn(compile_step);
    const run_cmd = b.addRunArtifact(exe);
    const data_dir = b.option([]const u8, "data-dir", "Launcher data root for the run step") orelse
        b.graph.environ_map.get("VELA_DATA_DIR") orelse b.build_root.path orelse ".";
    run_cmd.setEnvironmentVariable("VELA_DATA_DIR", data_dir);
    run_cmd.step.dependOn(compile_step);
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run App").dependOn(&run_cmd.step);
    const test_step = b.step("test", "Test application and UI state");
    const app_tests = b.addTest(.{ .root_module = app_mod, .name = "test-app" });
    test_step.dependOn(&b.addRunArtifact(app_tests).step);
    const nbt_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = nbt_dep.path("tests/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nbt", .module = nbt_module }},
    }) });
    const nbt_run = b.addRunArtifact(nbt_tests);
    test_step.dependOn(&nbt_run.step);
    b.step("test-nbt", "Test the declared upstream NBT dependency").dependOn(&nbt_run.step);
    const instances_manager_tests = b.addTest(.{
        .name = "test-instances-manager",
        .root_module = cloneAppModule(b, app_mod, b.path("src/instances_manager_tests.zig")),
    });
    b.step("test-instances-manager", "Test instance manager with production adapters").dependOn(&b.addRunArtifact(instances_manager_tests).step);
    const foundation_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core/foundation_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "nbt", .module = nbt_module },
            .{ .name = "nbt_compression", .module = nbt_compression },
        },
    }) });
    const foundation_run = b.addRunArtifact(foundation_tests);
    test_step.dependOn(&foundation_run.step);
    b.step("test-foundation", "Test configuration, instances and task services").dependOn(&foundation_run.step);
    const java_probe_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/ui/java_manager.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    b.step("test-java-probe", "Test Java probing, cancellation and child cleanup").dependOn(&b.addRunArtifact(java_probe_tests).step);
    const worlds_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core/worlds.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "nbt", .module = nbt_module },
            .{ .name = "nbt_compression", .module = nbt_compression },
        },
    }) });
    b.step("test-worlds", "Test world transactions and NBT metadata").dependOn(&b.addRunArtifact(worlds_tests).step);
    const compression_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core/worlds_gzip.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const compression_run = b.addRunArtifact(compression_tests);
    test_step.dependOn(&compression_run.step);
    b.step("test-compression", "Test bounded gzip and zlib compression").dependOn(&compression_run.step);
    const worlds_directory_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/worlds_directory_checks.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "nbt", .module = nbt_module },
            .{ .name = "nbt_compression", .module = nbt_compression },
        },
    }) });
    const worlds_directory_run = b.addRunArtifact(worlds_directory_tests);
    test_step.dependOn(&worlds_directory_run.step);
    b.step("test-worlds-directory", "Test validated world directory opening").dependOn(&worlds_directory_run.step);

    const downloader_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core/downloader_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "curl", .module = curl_dep.module("curl") }},
    }) });
    b.step("test-downloader", "Test downloader against local HTTP fixture").dependOn(&b.addRunArtifact(downloader_tests).step);
    const http_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core/http_transport.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "curl", .module = curl_dep.module("curl") }},
    }) });
    const http_run = b.addRunArtifact(http_tests);
    test_step.dependOn(&http_run.step);
    b.step("test-http-transport", "Test secure HTTP transport against local fixtures").dependOn(&http_run.step);
    const content_install_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core/content_install_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "curl", .module = curl_dep.module("curl") },
            .{ .name = "nbt", .module = nbt_module },
            .{ .name = "nbt_compression", .module = nbt_compression },
        },
    }) });
    const content_install_run = b.addRunArtifact(content_install_tests);
    test_step.dependOn(&content_install_run.step);
    b.step("test-content-install", "Test staged content installation and recovery").dependOn(&content_install_run.step);
    const pack_inspection_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core/pack_import.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "curl", .module = curl_dep.module("curl") }},
    }) });
    const pack_inspection_run = b.addRunArtifact(pack_inspection_tests);
    test_step.dependOn(&pack_inspection_run.step);
    b.step("test-pack-inspection", "Test bounded pack inspection and immutable-copy preparation").dependOn(&pack_inspection_run.step);
    const cf_credentials_module = b.createModule(.{
        .root_source_file = b.path("src/core/curseforge_credentials_manager.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (target.result.os.tag == .windows) {
        cf_credentials_module.linkSystemLibrary("advapi32", .{});
        cf_credentials_module.linkSystemLibrary("kernel32", .{});
    } else if (target.result.os.tag.isDarwin()) {
        cf_credentials_module.linkFramework("Security", .{});
        cf_credentials_module.linkFramework("CoreFoundation", .{});
    }
    const cf_credentials_tests = b.addTest(.{ .root_module = cf_credentials_module });
    const cf_credentials_run = b.addRunArtifact(cf_credentials_tests);
    test_step.dependOn(&cf_credentials_run.step);
    b.step("test-curseforge-credentials", "Test reference-only CurseForge credential publication and recovery").dependOn(&cf_credentials_run.step);
    const cf_credentials_ui_module = b.createModule(.{
        .root_source_file = b.path("src/curseforge_credentials_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (target.result.os.tag == .windows) {
        cf_credentials_ui_module.linkSystemLibrary("advapi32", .{});
        cf_credentials_ui_module.linkSystemLibrary("kernel32", .{});
    } else if (target.result.os.tag.isDarwin()) {
        cf_credentials_ui_module.linkFramework("Security", .{});
        cf_credentials_ui_module.linkFramework("CoreFoundation", .{});
    }
    const cf_credentials_ui_tests = b.addTest(.{ .root_module = cf_credentials_ui_module });
    const cf_credentials_ui_run = b.addRunArtifact(cf_credentials_ui_tests);
    test_step.dependOn(&cf_credentials_ui_run.step);
    b.step("test-curseforge-credentials-ui", "Test serial CurseForge credential controller and task lifecycle").dependOn(&cf_credentials_ui_run.step);
    const mc = b.addExecutable(.{ .name = "vela-mc", .root_module = b.createModule(.{
        .root_source_file = b.path("src/mc_cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "curl", .module = curl_dep.module("curl") }},
    }) });
    b.step("mc-cli", "Build headless Minecraft installer and launcher").dependOn(&b.addInstallArtifact(mc, .{}).step);
    const mc_run = b.addRunArtifact(mc);
    if (b.args) |args| mc_run.addArgs(args);
    b.step("mc", "Install or launch Minecraft without UI").dependOn(&mc_run.step);
    const mc_tests = b.addTest(.{ .root_module = mc.root_module });
    b.step("test-minecraft", "Test Minecraft installation and launch modules").dependOn(&b.addRunArtifact(mc_tests).step);
    const metadata_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core/minecraft/metadata/root.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("test-metadata", "Test independent Minecraft metadata parsing").dependOn(&b.addRunArtifact(metadata_tests).step);
    const content_ui_tests = b.addTest(.{
        .name = "test-content-ui",
        .root_module = cloneAppModule(b, app_mod, b.path("src/content_ui_tests.zig")),
    });
    const content_ui_run = b.addRunArtifact(content_ui_tests);
    b.step("test-content-ui", "Test content workflows with production UI bindings").dependOn(&content_ui_run.step);
    test_step.dependOn(&content_ui_run.step);
    const pack_import_controller_tests = b.addTest(.{
        .name = "test-pack-import-controller",
        .root_module = cloneAppModule(b, app_mod, b.path("src/pack_import_controller_tests.zig")),
    });
    const pack_import_controller_run = b.addRunArtifact(pack_import_controller_tests);
    b.step("test-pack-import-controller", "Test pinned pack prerequisites and publication ownership").dependOn(&pack_import_controller_run.step);
    test_step.dependOn(&pack_import_controller_run.step);
    const pack_import_view_tests = b.addTest(.{
        .name = "test-pack-import-view",
        .root_module = cloneAppModule(b, app_mod, b.path("src/pack_import_view_tests.zig")),
    });
    const pack_import_view_run = b.addRunArtifact(pack_import_view_tests);
    b.step("test-pack-import-view", "Test private pack previews and durable target admission").dependOn(&pack_import_view_run.step);
    test_step.dependOn(&pack_import_view_run.step);
    const gui_fixture_tests = b.addTest(.{
        .name = "test-gui-fixture",
        .root_module = cloneAppModule(b, app_mod, b.path("src/gui_acceptance.zig")),
    });
    b.step("test-gui-fixture", "Test deterministic GUI fixture data").dependOn(&b.addRunArtifact(gui_fixture_tests).step);
}

fn cloneAppModule(b: *std.Build, app_mod: *const std.Build.Module, root_source_file: std.Build.LazyPath) *std.Build.Module {
    const module = b.allocator.create(std.Build.Module) catch @panic("OOM");
    module.init(b, .{ .existing = app_mod });
    module.root_source_file = root_source_file;
    return module;
}

fn disableWindowsTranslationFortify(module: *std.Build.Module) void {
    const source = module.root_source_file orelse @panic("C binding module has no source");
    const generated = switch (source) {
        .generated => |generated| generated,
        else => @panic("C binding module is not generated"),
    };
    const translate = generated.file.step.cast(std.Build.Step.TranslateC) orelse
        @panic("C binding module is not generated by TranslateC");
    // Zig 0.16 translates MinGW fortify wrappers into unused local declarations.
    translate.defineCMacro("_FORTIFY_SOURCE", "0");
}

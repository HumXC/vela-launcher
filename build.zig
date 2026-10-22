const std = @import("std");
const macos_sdk = @import("build-support/macos_sdk.zig");
const linux_c = @import("build-support/linux_c.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_allocations = b.createModule(.{ .root_source_file = b.path("src/test_allocations.zig") });
    const java_process_fixture_install = if (b.graph.host.result.os.tag == .linux and
        target.result.os.tag == .linux and target.result.cpu.arch == b.graph.host.result.cpu.arch)
    fixture: {
        const helper = b.addExecutable(.{
            .name = "vela-java-process-fixture",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/core/loaders/tests/java_process_fixture.zig"),
                .target = b.graph.host,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        // Test runners own this local installation; normal launcher installation does not.
        break :fixture b.addInstallArtifact(helper, .{});
    } else null;
    const sdk = macos_sdk.choose(b, target.result.os.tag);
    const sdl = b.dependency("sdl", .{ .target = target, .optimize = optimize });
    // Apply SDK paths through the module graph below. DVUI forwards its SDK
    // options to SDL with names unsupported by the pinned SDL build script.
    const dvui_dep = b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3 });
    const dvui = dvui_dep.module("dvui_sdl3");
    dvui.linkLibrary(sdl.artifact("SDL3"));
    @import("build-support/webp.zig").link(b, target, optimize, dvui);
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
            .{ .name = "nbt", .module = nbt_module },
            .{ .name = "nbt_compression", .module = nbt_compression },
        },
    });
    const linux_bindings = if (target.result.os.tag == .linux) linux_c.create(b, target, optimize) else null;
    if (linux_bindings) |bindings| app_mod.addImport("linux_c", bindings);
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

    const preview_options = b.addOptions();
    preview_options.addOption([]const u8, "scene", b.option([]const u8, "scene", "Component mock preview scene") orelse "account-add");
    preview_options.addOption([]const u8, "state", b.option([]const u8, "state", "Component mock preview state") orelse "default");
    preview_options.addOption([]const u8, "size", b.option([]const u8, "preview-size", "Component mock preview viewport") orelse "1280x720");
    preview_options.addOption(?[]const u8, "data_file", b.option([]const u8, "mock-data", "JSON component mock data file"));
    const preview_module = cloneAppModule(b, app_mod, b.path("src/ui_preview.zig"));
    // cloneAppModule shares import-table storage; use private storage before adding options.
    preview_module.import_table = .{};
    var preview_imports = app_mod.import_table.iterator();
    while (preview_imports.next()) |entry| preview_module.addImport(entry.key_ptr.*, entry.value_ptr.*);
    preview_module.addOptions("ui_preview_options", preview_options);
    const preview = b.addExecutable(.{ .name = "vela-ui-preview", .root_module = preview_module });
    if (target.result.os.tag == .windows) preview.subsystem = .windows;
    b.step("build-ui-preview", "Build independent component mock preview").dependOn(&b.addInstallArtifact(preview, .{}).step);
    const preview_run = b.addRunArtifact(preview);
    preview_run.setCwd(b.path("."));
    b.step("ui-preview", "Render a component directly with mock data and no business services").dependOn(&preview_run.step);
    const preview_tests_module = cloneAppModule(b, app_mod, b.path("src/ui_preview_tests.zig"));
    preview_tests_module.addImport("test_allocations", test_allocations);
    const preview_tests = b.addTest(.{ .root_module = preview_tests_module, .filters = &.{"component preview"} });
    b.step("test-ui-preview", "Test mock data, states and intent-only interactions").dependOn(&b.addRunArtifact(preview_tests).step);
    // Acceptance clones the production module; this root is never default-installed.
    const lifecycle_exe = b.addExecutable(.{
        .name = "vela-lifecycle-acceptance",
        .root_module = cloneAppModule(b, app_mod, b.path("src/lifecycle_acceptance.zig")),
    });
    const lifecycle_child = b.addExecutable(.{
        .name = "vela-lifecycle-child",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/lifecycle_acceptance_child.zig"), .target = target, .optimize = optimize }),
    });
    const lifecycle_step = b.step("build-lifecycle-acceptance", "Build SAME-App lifecycle root and controlled Java helper only");
    lifecycle_step.dependOn(&b.addInstallArtifact(lifecycle_exe, .{}).step);
    lifecycle_step.dependOn(&b.addInstallArtifact(lifecycle_child, .{}).step);
    const loader_acceptance = b.addExecutable(.{
        .name = "vela-loader-acceptance",
        .root_module = cloneAppModule(b, app_mod, b.path("src/loader_acceptance.zig")),
    });
    b.step("build-loader-acceptance", "Build genuine production loader installation and native Java acceptance harness").dependOn(&b.addInstallArtifact(loader_acceptance, .{}).step);
    const loader_acceptance_tests = b.addTest(.{
        .root_module = cloneAppModule(b, app_mod, b.path("src/loader_acceptance.zig")),
        .filters = &.{"offline identity and sanitized sensitive argv"},
    });
    b.step("test-loader-acceptance", "Test isolated loader acceptance identity and argument sanitization").dependOn(&runTestWithFixture(b, java_process_fixture_install, loader_acceptance_tests).step);
    const compile_step = b.step("compile-app", "Compile App");
    compile_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    b.getInstallStep().dependOn(compile_step);
    const run_cmd = b.addRunArtifact(exe);
    // Keep the Run environment unset so cached build graphs inherit the current session.
    // Pass only the explicit data-root choice as argv; VELA_DATA_DIR is read at runtime.
    if (b.option([]const u8, "data-dir", "Launcher data root for the run step")) |data_dir| {
        run_cmd.addArgs(&.{ "--data-dir", data_dir });
    } else {
        run_cmd.addArgs(&.{ "--default-data-dir", "." });
    }
    run_cmd.setCwd(b.path("."));
    run_cmd.step.dependOn(compile_step);
    run_cmd.addPassthruArgs();
    b.step("run", "Run App").dependOn(&run_cmd.step);
    const test_step = b.step("test", "Test application and UI state");
    const allocation_tests = b.addTest(.{
        .name = "test-allocations",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/test_allocations_tests.zig"), .target = target, .optimize = optimize }),
    });
    const allocation_run = b.addRunArtifact(allocation_tests);
    b.step("test-allocations", "Test exhaustive OOM injection and leak diagnostics").dependOn(&allocation_run.step);
    test_step.dependOn(&allocation_run.step);
    const file_picker_tests = b.addTest(.{
        .name = "test-file-picker",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/ui/file_picker.zig"), .target = target, .optimize = optimize }),
    });
    const file_picker_run = runTestWithFixture(b, java_process_fixture_install, file_picker_tests);
    b.step("test-file-picker", "Test shared native picker ownership and shutdown").dependOn(&file_picker_run.step);
    test_step.dependOn(&file_picker_run.step);
    const server_picker_tests = b.addTest(.{
        .name = "test-server-picker",
        .root_module = cloneAppModule(b, app_mod, b.path("src/server_picker_tests.zig")),
    });
    const server_picker_run = runTestWithFixture(b, java_process_fixture_install, server_picker_tests);
    b.step("test-server-picker", "Test independent server-card polling and cancellation").dependOn(&server_picker_run.step);
    test_step.dependOn(&server_picker_run.step);
    const game_selection_tests = b.addTest(.{
        .name = "test-game-selection",
        .root_module = cloneAppModule(b, app_mod, b.path("src/game_selection_tests.zig")),
    });
    const game_selection_run = runTestWithFixture(b, java_process_fixture_install, game_selection_tests);
    b.step("test-game-selection", "Test exact instance and server selection").dependOn(&game_selection_run.step);
    test_step.dependOn(&game_selection_run.step);
    const mods_tests = b.addTest(.{ .name = "test-mods", .root_module = cloneAppModule(b, app_mod, b.path("src/mods_view_tests.zig")), .filters = if (b.option([]const u8, "mods-test-filter", "Run a focused resource UI test group")) |filter| &.{filter} else &.{} });
    mods_tests.root_module.addImport("test_allocations", test_allocations);
    const mods_run = runTestWithFixture(b, java_process_fixture_install, mods_tests);
    b.step("test-mods", "Test local inventory and mod view/controller").dependOn(&mods_run.step);
    test_step.dependOn(&mods_run.step);
    const app_test_filter = b.option([]const u8, "test-filter", "Run a focused application test group");
    const app_tests = b.addTest(.{ .root_module = app_mod, .name = "test-app", .filters = if (app_test_filter) |filter| &.{filter} else &.{} });
    const app_test_run = runTestWithFixture(b, java_process_fixture_install, app_tests);
    test_step.dependOn(&app_test_run.step);
    b.step("test-app", "Test application state and production bindings").dependOn(&app_test_run.step);
    const windows_durable_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/windows_durable_fs_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    const windows_durable_run = runTestWithFixture(b, java_process_fixture_install, windows_durable_tests);
    test_step.dependOn(&windows_durable_run.step);
    b.step("test-windows-durable-fs", "Test hermetic Windows durable filesystem protocol").dependOn(&windows_durable_run.step);
    const windows_durable_check = b.step("check-windows-durable-fs", "Compile Windows durable filesystem and owner operations for x64 and ARM64 without execution");
    inline for (.{ std.Target.Cpu.Arch.x86_64, std.Target.Cpu.Arch.aarch64 }) |arch| {
        const check = b.addObject(.{
            .name = "windows-durable-fs-" ++ @tagName(arch),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/windows_durable_fs_checks.zig"),
                .target = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .windows, .abi = .gnu }),
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        windows_durable_check.dependOn(&check.step);
    }
    const install_platform_check = b.step("check-install-platforms", "Compile installation, recovery, native planning and JVM APIs for Linux/Windows/macOS x64 and ARM64");
    inline for (.{ std.Target.Os.Tag.linux, std.Target.Os.Tag.windows, std.Target.Os.Tag.macos }) |os| {
        inline for (.{ std.Target.Cpu.Arch.x86_64, std.Target.Cpu.Arch.aarch64 }) |arch| {
            const platform = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = os, .abi = if (os == .macos) .none else .gnu });
            const platform_curl = b.dependency("curl", .{ .target = platform, .optimize = optimize, .link_vendor = true, .mbedtls_pthreads = os.isDarwin() });
            // Objects validate target ABI declarations without resolving a target libcurl binary.
            const curl_source = platform_curl.module("curl");
            const curl_bindings = b.createModule(.{ .root_source_file = curl_source.root_source_file, .target = platform, .optimize = optimize, .link_libc = true });
            for (curl_source.import_table.keys(), curl_source.import_table.values()) |name, imported| curl_bindings.addImport(name, imported);
            if (os == .windows) disableWindowsTranslationFortify(platform_curl.module("curl").import_table.get("c").?);
            const platform_nbt = b.dependency("nbt", .{ .target = platform, .optimize = optimize });
            const platform_module = b.createModule(.{
                .root_source_file = b.path("src/install_platform_checks.zig"),
                .target = platform,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "curl", .module = curl_bindings },
                    .{ .name = "nbt", .module = platform_nbt.module("nbt") },
                    .{ .name = "nbt_compression", .module = b.createModule(.{ .root_source_file = b.path("src/core/worlds_gzip.zig"), .target = platform, .optimize = optimize }) },
                },
            });
            if (os == .linux) platform_module.addImport("linux_c", linux_c.create(b, platform, optimize));
            const check = b.addObject(.{ .name = "install-" ++ @tagName(os) ++ "-" ++ @tagName(arch), .root_module = platform_module });
            install_platform_check.dependOn(&check.step);
        }
    }
    const nbt_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = nbt_dep.path("tests/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nbt", .module = nbt_module },
            .{ .name = "fixtures", .module = b.createModule(.{
                .root_source_file = nbt_dep.path("tests/fixtures/root.zig"),
                .imports = &.{.{ .name = "nbt", .module = nbt_module }},
            }) },
        },
    }) });
    const nbt_run = runTestWithFixture(b, java_process_fixture_install, nbt_tests);
    test_step.dependOn(&nbt_run.step);
    b.step("test-nbt", "Test the declared upstream NBT dependency").dependOn(&nbt_run.step);
    const instances_manager_tests = b.addTest(.{
        .name = "test-instances-manager",
        .root_module = cloneAppModule(b, app_mod, b.path("src/instances_manager_tests.zig")),
    });
    b.step("test-instances-manager", "Test instance manager with production adapters").dependOn(&runTestWithFixture(b, java_process_fixture_install, instances_manager_tests).step);
    const safe_archive_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core/safe_archive_test.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const python = b.option([]const u8, "python", "Python 3 interpreter for local generated test fixtures") orelse "python3";
    const safe_archive_run = b.addSystemCommand(&.{ python, "scripts/test-safe-archive.py", "--test-exe" });
    safe_archive_run.addArtifactArg(safe_archive_tests);
    test_step.dependOn(&safe_archive_run.step);
    b.step("test-safe-archive", "Test bounded archive extraction with local generated fixtures").dependOn(&safe_archive_run.step);
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
    const foundation_run = runTestWithFixture(b, java_process_fixture_install, foundation_tests);
    test_step.dependOn(&foundation_run.step);
    b.step("test-foundation", "Test configuration, instances and task services").dependOn(&foundation_run.step);
    const java_probe_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/ui/java_manager.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    if (linux_bindings) |bindings| java_probe_tests.root_module.addImport("linux_c", bindings);
    b.step("test-java-probe", "Test Java probing, cancellation and child cleanup").dependOn(&runTestWithFixture(b, java_process_fixture_install, java_probe_tests).step);
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
    b.step("test-worlds", "Test world transactions and NBT metadata").dependOn(&runTestWithFixture(b, java_process_fixture_install, worlds_tests).step);
    const compression_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core/worlds_gzip.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const compression_run = runTestWithFixture(b, java_process_fixture_install, compression_tests);
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
    const worlds_directory_run = runTestWithFixture(b, java_process_fixture_install, worlds_directory_tests);
    test_step.dependOn(&worlds_directory_run.step);
    b.step("test-worlds-directory", "Test validated world directory opening").dependOn(&worlds_directory_run.step);

    const downloader_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core/downloader_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "curl", .module = curl_dep.module("curl") },
            .{ .name = "nbt", .module = nbt_module },
            .{ .name = "nbt_compression", .module = nbt_compression },
        },
    }) });
    if (linux_bindings) |bindings| downloader_tests.root_module.addImport("linux_c", bindings);
    b.step("test-downloader", "Test downloader against local HTTP fixture").dependOn(&runTestWithFixture(b, java_process_fixture_install, downloader_tests).step);
    const http_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core/http_transport.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "curl", .module = curl_dep.module("curl") }},
    }) });
    const http_run = runTestWithFixture(b, java_process_fixture_install, http_tests);
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
    const content_install_run = runTestWithFixture(b, java_process_fixture_install, content_install_tests);
    test_step.dependOn(&content_install_run.step);
    b.step("test-content-install", "Test staged content installation and recovery").dependOn(&content_install_run.step);
    const pack_inspection_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core/pack_import.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "curl", .module = curl_dep.module("curl") }},
    }) });
    const pack_inspection_run = runTestWithFixture(b, java_process_fixture_install, pack_inspection_tests);
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
    const cf_credentials_run = runTestWithFixture(b, java_process_fixture_install, cf_credentials_tests);
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
    const cf_credentials_ui_run = runTestWithFixture(b, java_process_fixture_install, cf_credentials_ui_tests);
    test_step.dependOn(&cf_credentials_ui_run.step);
    b.step("test-curseforge-credentials-ui", "Test serial CurseForge credential controller and task lifecycle").dependOn(&cf_credentials_ui_run.step);
    const mc = b.addExecutable(.{ .name = "vela-mc", .root_module = b.createModule(.{
        .root_source_file = b.path("src/mc_cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "curl", .module = curl_dep.module("curl") },
            .{ .name = "nbt", .module = nbt_module },
            .{ .name = "nbt_compression", .module = nbt_compression },
        },
    }) });
    if (linux_bindings) |bindings| mc.root_module.addImport("linux_c", bindings);
    b.step("mc-cli", "Build headless Minecraft installer and launcher").dependOn(&b.addInstallArtifact(mc, .{}).step);
    const mc_run = b.addRunArtifact(mc);
    mc_run.addPassthruArgs();
    b.step("mc", "Install or launch Minecraft without UI").dependOn(&mc_run.step);
    const mc_tests = b.addTest(.{ .root_module = mc.root_module });
    b.step("test-minecraft", "Test Minecraft installation and launch modules").dependOn(&runTestWithFixture(b, java_process_fixture_install, mc_tests).step);
    const metadata_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core/minecraft/metadata/root.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("test-metadata", "Test independent Minecraft metadata parsing").dependOn(&runTestWithFixture(b, java_process_fixture_install, metadata_tests).step);
    const content_ui_tests = b.addTest(.{
        .name = "test-content-ui",
        .root_module = cloneAppModule(b, app_mod, b.path("src/content_ui_tests.zig")),
    });
    const content_ui_run = runTestWithFixture(b, java_process_fixture_install, content_ui_tests);
    b.step("test-content-ui", "Test content workflows with production UI bindings").dependOn(&content_ui_run.step);
    test_step.dependOn(&content_ui_run.step);
    const instance_creation_controller_tests = b.addTest(.{
        .name = "test-instance-creation-controller",
        .root_module = cloneAppModule(b, app_mod, b.path("src/instance_creation_controller_tests.zig")),
    });
    const instance_creation_controller_run = runTestWithFixture(b, java_process_fixture_install, instance_creation_controller_tests);
    b.step("test-ordinary-creation", "Test ordinary instance prerequisites and publication ownership").dependOn(&instance_creation_controller_run.step);
    test_step.dependOn(&instance_creation_controller_run.step);
    const gui_fixture_tests = b.addTest(.{
        .name = "test-gui-fixture",
        .root_module = cloneAppModule(b, app_mod, b.path("src/gui_acceptance.zig")),
        .filters = if (b.option([]const u8, "gui-test-filter", "Run a focused GUI fixture test group")) |filter| &.{filter} else &.{},
    });
    b.step("test-gui-fixture", "Test deterministic GUI fixture data").dependOn(&runTestWithFixture(b, java_process_fixture_install, gui_fixture_tests).step);
    // Independently rooted test modules share deterministic exhaustive OOM injection.
    for ([_]*std.Build.Step.Compile{
        loader_acceptance_tests,
        file_picker_tests,
        server_picker_tests,
        game_selection_tests,
        app_tests,
        windows_durable_tests,
        instances_manager_tests,
        safe_archive_tests,
        foundation_tests,
        java_probe_tests,
        worlds_tests,
        compression_tests,
        worlds_directory_tests,
        downloader_tests,
        http_tests,
        content_install_tests,
        pack_inspection_tests,
        cf_credentials_tests,
        cf_credentials_ui_tests,
        mc_tests,
        metadata_tests,
        content_ui_tests,
        instance_creation_controller_tests,
        gui_fixture_tests,
    }) |test_compile| test_compile.root_module.addImport("test_allocations", test_allocations);
}

fn runTestWithFixture(b: *std.Build, fixture_install: ?*std.Build.Step.InstallArtifact, tests: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = b.addRunArtifact(tests);
    if (fixture_install) |install| {
        run.step.dependOn(&install.step);
        // Resolve the generated helper path at make time, including on cache hits.
        var test_argv = run.argv;
        defer test_argv.deinit(b.allocator);
        run.argv = .empty;
        run.addArg("env");
        run.addFileArg2(install.artifact.getEmittedBin(), .{
            .prefix = "VELA_JAVA_PROCESS_FIXTURE=",
            .make_absolute = true,
        });
        run.argv.appendSlice(b.allocator, test_argv.items) catch @panic("OOM");
    }
    return run;
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
    const step = module.owner.graph.generated_files.items[@backingInt(generated.index)];
    // MinGW fortify wrappers contain inline bodies that are unnecessary for bindings.
    if (step.cast(std.Build.Step.TranslateC)) |translate| {
        translate.defineCMacro("_FORTIFY_SOURCE", "0");
    } else if (step.cast(std.Build.Step.Run)) |translate| {
        translate.addArg("-D_FORTIFY_SOURCE=0");
    } else @panic("C binding module is not generated by a C translator");
}

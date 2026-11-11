const std = @import("std");
const macos_sdk = @import("build-support/macos_sdk.zig");
const dependencies = @import("build-support/dependencies.zig");
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
    const dvui_dep = b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3, .@"tree-sitter" = false });
    // Let Zig fetch newly discovered lazy dependencies before inspecting their artifacts.
    if (b.graph.needed_lazy_dependencies.count() != 0) return;
    const dvui = dvui_dep.module("dvui_sdl3");
    @import("build-support/freetype.zig").apply(b, dvui);
    @import("build-support/dvui_backdrop.zig").apply(b, dvui);
    dvui.linkLibrary(sdl.artifact("SDL3"));
    @import("build-support/sdl_software.zig").apply(b, dvui);
    @import("build-support/webp.zig").link(b, target, optimize, dvui);
    const core = dependencies.Core.init(b, target, optimize);
    const server_probe = b.addExecutable(.{ .name = "vela-server-probe", .root_module = core.createModule(b.path("src/server_probe.zig")) });
    const server_probe_run = b.addRunArtifact(server_probe);
    server_probe_run.addPassthruArgs();
    b.step("probe-server", "Query explicit Java server host/port pairs without reading configuration").dependOn(&server_probe_run.step);
    const cache_hash_tests = b.addTest(.{ .root_module = core.cache_hash });
    b.step("test-cache-hash", "Test optimized digest kernels against standard SHA").dependOn(&b.addRunArtifact(cache_hash_tests).step);
    const cache_benchmark = b.addExecutable(.{ .name = "vela-cache-benchmark", .root_module = core.createModule(b.path("src/cache_benchmark.zig")) });
    const cache_benchmark_run = b.addRunArtifact(cache_benchmark);
    cache_benchmark_run.addArg(b.option([]const u8, "cache-bench-dir", "Fresh temporary directory for cache benchmark") orelse "/tmp/vela-cache-benchmark");
    b.step("bench-cache", "Benchmark local cache hashing and verified copying").dependOn(&cache_benchmark_run.step);
    const curl_dep = core.curl_dep;
    const nbt_dep = core.nbt_dep;
    const nbt_module = nbt_dep.module("nbt");
    const nbt_compression = core.compression;
    const linux_bindings = core.linux;
    if (target.result.os.tag == .windows) {
        dependencies.disableWindowsTranslationFortify(dvui_dep.module("sdl3").import_table.get("sdl3-c").?);
        dependencies.disableWindowsTranslationFortify(dvui.import_table.get("dvui-c").?);
    }
    const app_modules: dependencies.App = .{ .core = core, .dvui = dvui, .sdk = sdk };
    const app_mod = app_modules.createModule(b.path("src/app.zig"));
    if (sdk) |root| macos_sdk.apply(b, app_mod, root);
    const exe = b.addExecutable(.{ .name = "vela", .root_module = app_mod });
    if (target.result.os.tag == .windows) exe.subsystem = .windows;
    const gui_fixture = b.addExecutable(.{
        .name = "vela-gui-fixture",
        .root_module = app_modules.createModule(b.path("src/gui_acceptance.zig")),
    });
    if (target.result.os.tag == .windows) gui_fixture.subsystem = .windows;
    b.step("build-gui-fixture", "Build isolated GUI acceptance fixture").dependOn(&b.addInstallArtifact(gui_fixture, .{}).step);

    const preview_options = b.addOptions();
    preview_options.addOption([]const u8, "scene", b.option([]const u8, "scene", "Component mock preview scene") orelse "account-add");
    preview_options.addOption([]const u8, "state", b.option([]const u8, "state", "Component mock preview state") orelse "default");
    preview_options.addOption([]const u8, "size", b.option([]const u8, "preview-size", "Component mock preview viewport") orelse "1280x720");
    preview_options.addOption(?[]const u8, "data_file", b.option([]const u8, "mock-data", "JSON component mock data file"));
    const preview_module = app_modules.createModule(b.path("src/ui_preview.zig"));
    preview_module.addOptions("ui_preview_options", preview_options);
    const preview = b.addExecutable(.{ .name = "vela-ui-preview", .root_module = preview_module });
    if (target.result.os.tag == .windows) preview.subsystem = .windows;
    b.step("build-ui-preview", "Build independent component mock preview").dependOn(&b.addInstallArtifact(preview, .{}).step);
    const preview_run = b.addRunArtifact(preview);
    preview_run.setCwd(b.path("."));
    b.step("ui-preview", "Render a component directly with mock data and no business services").dependOn(&preview_run.step);
    const preview_tests_module = app_modules.createModule(b.path("src/ui_preview_tests.zig"));
    preview_tests_module.addImport("test_allocations", test_allocations);
    const preview_tests = b.addTest(.{ .root_module = preview_tests_module, .filters = &.{"component preview"} });
    b.step("test-ui-preview", "Test mock data, states and intent-only interactions").dependOn(&runTestWithFixture(b, java_process_fixture_install, preview_tests).step);
    const modal_pixels = b.addExecutable(.{ .name = "vela-modal-backdrop-pixels", .root_module = app_modules.createModule(b.path("src/ui_modal_backdrop_pixels.zig")) });
    const modal_pixels_step = b.step("test-modal-backdrop-pixels", "Test native modal backdrop z-order and pixels on OpenGL and software");
    const modal_gl = b.addRunArtifact(modal_pixels);
    modal_gl.setEnvironmentVariable("SDL_VIDEODRIVER", "offscreen");
    modal_gl.setEnvironmentVariable("SDL_AUDIODRIVER", "dummy");
    modal_gl.setEnvironmentVariable("SDL_RENDER_DRIVER", "opengl");
    const modal_software = b.addRunArtifact(modal_pixels);
    modal_software.setEnvironmentVariable("SDL_VIDEODRIVER", "dummy");
    modal_software.setEnvironmentVariable("SDL_AUDIODRIVER", "dummy");
    modal_software.setEnvironmentVariable("SDL_RENDER_DRIVER", "software");
    modal_software.step.dependOn(&modal_gl.step);
    modal_pixels_step.dependOn(&modal_software.step);
    const surface_pixels = b.addExecutable(.{ .name = "vela-surface-pixels", .root_module = app_modules.createModule(b.path("src/ui_surface_pixels.zig")) });
    b.step("build-ui-pixels", "Build native surface pixel regression for graphics-driver checks").dependOn(&b.addInstallArtifact(surface_pixels, .{}).step);
    const surface_pixels_run = b.addRunArtifact(surface_pixels);
    surface_pixels_run.setEnvironmentVariable("SDL_VIDEODRIVER", "offscreen");
    surface_pixels_run.setEnvironmentVariable("SDL_AUDIODRIVER", "dummy");
    surface_pixels_run.setEnvironmentVariable("SDL_RENDER_DRIVER", "opengl");
    const layout_filter = b.option([]const u8, "layout-test-filter", "Run a focused UI layout test group") orelse "UI layout";
    b.step("test-ui-layout", "Test production UI layout with the testing renderer").dependOn(&@import("ui_layout_test_build.zig").addTests(b, core, layout_filter).step);
    const surface_pixels_step = b.step("test-ui-pixels", "Compare native SDL material pixels with OpenGL and software rendering");
    surface_pixels_step.dependOn(&surface_pixels_run.step);
    const surface_pixels_software_run = b.addRunArtifact(surface_pixels);
    surface_pixels_software_run.setEnvironmentVariable("SDL_VIDEODRIVER", "dummy");
    surface_pixels_software_run.setEnvironmentVariable("SDL_AUDIODRIVER", "dummy");
    surface_pixels_software_run.setEnvironmentVariable("SDL_RENDER_DRIVER", "software");
    surface_pixels_software_run.step.dependOn(&surface_pixels_run.step);
    surface_pixels_step.dependOn(&surface_pixels_software_run.step);
    // Acceptance uses the production dependency policy; this root is never default-installed.
    const lifecycle_exe = b.addExecutable(.{
        .name = "vela-lifecycle-acceptance",
        .root_module = app_modules.createModule(b.path("src/lifecycle_acceptance.zig")),
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
        .root_module = app_modules.createModule(b.path("src/loader_acceptance.zig")),
    });
    b.step("build-loader-acceptance", "Build genuine production loader installation and native Java acceptance harness").dependOn(&b.addInstallArtifact(loader_acceptance, .{}).step);
    const loader_acceptance_tests = b.addTest(.{
        .root_module = app_modules.createModule(b.path("src/loader_acceptance.zig")),
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
    const allocation_tests = b.addTest(.{
        .name = "test-allocations",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/test_allocations_tests.zig"), .target = target, .optimize = optimize }),
    });
    const allocation_run = b.addRunArtifact(allocation_tests);
    b.step("test-allocations", "Test exhaustive OOM injection and leak diagnostics").dependOn(&allocation_run.step);
    const file_picker_tests = b.addTest(.{
        .name = "test-file-picker",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/ui/file_picker.zig"), .target = target, .optimize = optimize }),
    });
    const file_picker_run = runTestWithFixture(b, java_process_fixture_install, file_picker_tests);
    b.step("test-file-picker", "Test shared native picker ownership and shutdown").dependOn(&file_picker_run.step);
    const server_picker_tests = b.addTest(.{
        .name = "test-server-picker",
        .root_module = app_modules.createModule(b.path("src/server_picker_tests.zig")),
    });
    const server_picker_run = runTestWithFixture(b, java_process_fixture_install, server_picker_tests);
    b.step("test-server-picker", "Test independent server-card polling and cancellation").dependOn(&server_picker_run.step);
    const game_selection_tests = b.addTest(.{
        .name = "test-game-selection",
        .root_module = app_modules.createModule(b.path("src/game_selection_tests.zig")),
    });
    const game_selection_run = runTestWithFixture(b, java_process_fixture_install, game_selection_tests);
    b.step("test-game-selection", "Test exact instance and server selection").dependOn(&game_selection_run.step);
    const mods_tests = b.addTest(.{ .name = "test-mods", .root_module = app_modules.createModule(b.path("src/mods_view_tests.zig")), .filters = if (b.option([]const u8, "mods-test-filter", "Run a focused resource UI test group")) |filter| &.{filter} else &.{} });
    mods_tests.root_module.addImport("test_allocations", test_allocations);
    const mods_run = runTestWithFixture(b, java_process_fixture_install, mods_tests);
    b.step("test-mods", "Test local inventory and mod view/controller").dependOn(&mods_run.step);
    const webp_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/core/webp_decode.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
    @import("build-support/webp.zig").link(b, target, optimize, webp_tests.root_module);
    b.step("test-webp", "Test concurrent cold-start WebP decoding").dependOn(&b.addRunArtifact(webp_tests).step);
    const app_test_filter = b.option([]const u8, "test-filter", "Run a focused application test group");
    const app_tests = b.addTest(.{ .root_module = app_modules.createModule(b.path("src/app.zig")), .name = "test-app", .filters = if (app_test_filter) |filter| &.{filter} else &.{} });
    const app_test_run = runTestWithFixture(b, java_process_fixture_install, app_tests);
    b.step("test-app", "Test application state and production bindings").dependOn(&app_test_run.step);
    const windows_durable_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/windows_durable_fs_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    const windows_durable_run = runTestWithFixture(b, java_process_fixture_install, windows_durable_tests);
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
            const platform_curl = dependencies.curl(b, platform, optimize);
            // Objects validate target ABI declarations without resolving a target libcurl binary.
            const curl_source = platform_curl.module("curl");
            const curl_bindings = b.createModule(.{ .root_source_file = curl_source.root_source_file, .target = platform, .optimize = optimize, .link_libc = true });
            for (curl_source.import_table.keys(), curl_source.import_table.values()) |name, imported| curl_bindings.addImport(name, imported);
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
    b.step("test-nbt", "Test the declared upstream NBT dependency").dependOn(&nbt_run.step);
    const instances_manager_tests = b.addTest(.{
        .name = "test-instances-manager",
        .root_module = app_modules.createModule(b.path("src/instances_manager_tests.zig")),
    });
    b.step("test-instances-manager", "Test instance manager with production adapters").dependOn(&runTestWithFixture(b, java_process_fixture_install, instances_manager_tests).step);
    const diagnostic_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core/diagnostic_log.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    b.step("test-diagnostic-log", "Test persistent launcher diagnostics and redaction").dependOn(&b.addRunArtifact(diagnostic_tests).step);
    const safe_archive_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core/safe_archive_test.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const python = b.option([]const u8, "python", "Python 3 interpreter for local generated test fixtures") orelse "python3";
    const safe_archive_run = b.addSystemCommand(&.{ python, "scripts/test-safe-archive.py", "--test-exe" });
    safe_archive_run.addArtifactArg(safe_archive_tests);
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
    b.step("test-foundation", "Test configuration, instances and task services").dependOn(&foundation_run.step);
    const java_probe_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/java_probe_tests.zig"),
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
    const downloader_run = runTestWithFixture(b, java_process_fixture_install, downloader_tests);
    // Fixture ports and proxy/guard environment change independently of artifacts.
    downloader_run.has_side_effects = true;
    b.step("test-downloader", "Test downloader against local HTTP fixture").dependOn(&downloader_run.step);
    const http_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core/http_transport.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "curl", .module = curl_dep.module("curl") }},
    }) });
    const http_run = runTestWithFixture(b, java_process_fixture_install, http_tests);
    http_run.has_side_effects = true;
    b.step("test-http-transport", "Test secure HTTP transport against local fixtures").dependOn(&http_run.step);
    const proxy_tests = b.addTest(.{ .root_module = core.createModule(b.path("src/proxy_tests.zig")), .filters = &.{"proxy"} });
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
    b.step("test-content-install", "Test staged content installation and recovery").dependOn(&content_install_run.step);
    const pack_inspection_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core/pack_import.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "curl", .module = curl_dep.module("curl") }},
    }) });
    const pack_inspection_run = runTestWithFixture(b, java_process_fixture_install, pack_inspection_tests);
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
    b.step("test-curseforge-credentials-ui", "Test serial CurseForge credential controller and task lifecycle").dependOn(&cf_credentials_ui_run.step);
    const mc = b.addExecutable(.{ .name = "vela-mc", .root_module = core.createModule(b.path("src/mc_cli.zig")) });
    b.step("mc-cli", "Build headless Minecraft installer and launcher").dependOn(&b.addInstallArtifact(mc, .{}).step);
    const mc_run = b.addRunArtifact(mc);
    mc_run.addPassthruArgs();
    b.step("mc", "Install or launch Minecraft without UI").dependOn(&mc_run.step);
    const mc_tests = b.addTest(.{ .root_module = core.createModule(b.path("src/mc_cli.zig")) });
    b.step("test-minecraft", "Test Minecraft installation and launch modules").dependOn(&runTestWithFixture(b, java_process_fixture_install, mc_tests).step);
    const metadata_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core/minecraft/metadata/root.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("test-metadata", "Test independent Minecraft metadata parsing").dependOn(&runTestWithFixture(b, java_process_fixture_install, metadata_tests).step);
    const content_ui_tests = b.addTest(.{
        .name = "test-content-ui",
        .root_module = app_modules.createModule(b.path("src/content_ui_tests.zig")),
    });
    const content_ui_run = runTestWithFixture(b, java_process_fixture_install, content_ui_tests);
    b.step("test-content-ui", "Test content workflows with production UI bindings").dependOn(&content_ui_run.step);
    const instance_creation_controller_tests = b.addTest(.{
        .name = "test-instance-creation-controller",
        .root_module = app_modules.createModule(b.path("src/instance_creation_controller_tests.zig")),
    });
    const instance_creation_controller_run = runTestWithFixture(b, java_process_fixture_install, instance_creation_controller_tests);
    b.step("test-ordinary-creation", "Test ordinary instance prerequisites and publication ownership").dependOn(&instance_creation_controller_run.step);
    const pack_download_auth_tests = b.addTest(.{ .name = "test-pack-download-auth", .root_module = app_modules.createModule(b.path("src/pack_download_auth_tests.zig")) });
    const pack_download_auth_run = runTestWithFixture(b, java_process_fixture_install, pack_download_auth_tests);
    b.step("test-pack-download-auth", "Test scoped pack download credentials").dependOn(&pack_download_auth_run.step);
    const pack_source_tests = b.addTest(.{ .name = "test-pack-source", .root_module = app_modules.createModule(b.path("src/pack_source_authorization_tests.zig")) });
    const pack_source_run = runTestWithFixture(b, java_process_fixture_install, pack_source_tests);
    b.step("test-pack-source", "Test pack source policy and file authorization").dependOn(&pack_source_run.step);
    const pack_install_tests = b.addTest(.{ .name = "test-pack-install", .root_module = app_modules.createModule(b.path("src/pack_install_controller_tests.zig")) });
    const pack_install_run = runTestWithFixture(b, java_process_fixture_install, pack_install_tests);
    b.step("test-pack-install", "Test private-stage pack creation").dependOn(&pack_install_run.step);
    const pack_tests = b.addTest(.{ .name = "test-packs", .root_module = app_modules.createModule(b.path("src/pack_tests.zig")) });
    const pack_run = runTestWithFixture(b, java_process_fixture_install, pack_tests);
    b.step("test-packs", "Test independent modpack discovery and creation").dependOn(&pack_run.step);
    const gui_fixture_tests = b.addTest(.{
        .name = "test-gui-fixture",
        .root_module = app_modules.createModule(b.path("src/gui_acceptance.zig")),
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
        proxy_tests,
        content_install_tests,
        pack_inspection_tests,
        cf_credentials_tests,
        cf_credentials_ui_tests,
        mc_tests,
        metadata_tests,
        content_ui_tests,
        instance_creation_controller_tests,
        pack_tests,
        pack_install_tests,
        pack_source_tests,
        pack_download_auth_tests,
        gui_fixture_tests,
        diagnostic_tests,
    }) |test_compile| {
        test_compile.root_module.addImport("test_allocations", test_allocations);
        test_compile.root_module.addImport("cache_hash", core.cache_hash);
        test_compile.root_module.linkLibrary(core.server_icon_native);
        dependencies.linkNetworkPlatform(test_compile.root_module, target);
    }
    const suites = @import("build-support/test_suites.zig");
    const download_fixture = suites.pythonFixture(b, python, "scripts/test-downloader.py", downloader_tests, java_process_fixture_install);
    b.step("test-downloader-fixture", "Run downloader tests with local HTTP fixtures").dependOn(&download_fixture.step);
    const http_fixture = suites.pythonFixture(b, python, "scripts/test-http-transport.py", http_tests, java_process_fixture_install);
    b.step("test-http-fixture", "Run HTTP tests with local fixtures").dependOn(&http_fixture.step);
    const proxy_fixture = suites.pythonFixture(b, python, "scripts/test-proxy.py", proxy_tests, java_process_fixture_install);
    b.step("test-proxy-fixture", "Verify authenticated HTTP and SOCKS5 HTTPS proxy transfers").dependOn(&proxy_fixture.step);
    const guard_fixture = suites.pythonFixture(b, python, "scripts/test-public-network.py", http_tests, java_process_fixture_install);
    guard_fixture.step.dependOn(&http_fixture.step);
    b.step("test-public-network", "Verify forbidden IPv4/IPv6 connections and connection reuse").dependOn(&guard_fixture.step);
    const minecraft_fixture = suites.pythonFixture(b, python, "scripts/test-http-transport.py", mc_tests, java_process_fixture_install);
    b.step("test-minecraft-fixture", "Run Minecraft module tests with local HTTP fixtures").dependOn(&minecraft_fixture.step);
    const fixture_runner_tests = b.addSystemCommand(&.{ python, "-B" });
    fixture_runner_tests.addFileArg(b.path("scripts/test-build-fixtures.py"));
    fixture_runner_tests.setCwd(b.path("."));
    b.step("test-build-fixtures", "Test fixture runner CLI, cleanup and guard assertions").dependOn(&fixture_runner_tests.step);
    suites.add(b);
    // Regression guards: configuring tests and previews cannot mutate production roots.
    std.debug.assert(!app_mod.import_table.contains("test_allocations"));
    std.debug.assert(!app_mod.import_table.contains("ui_preview_options"));
    std.debug.assert(!mc.root_module.import_table.contains("test_allocations"));
}

fn runTestWithFixture(b: *std.Build, fixture_install: ?*std.Build.Step.InstallArtifact, tests: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = b.addRunArtifact(tests);
    if (tests.root_module.import_table.contains("dvui")) {
        run.setEnvironmentVariable("SDL_VIDEODRIVER", "dummy");
        run.setEnvironmentVariable("SDL_AUDIODRIVER", "dummy");
        run.setEnvironmentVariable("SDL_RENDER_DRIVER", "software");
    }
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

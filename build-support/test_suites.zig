//! Explicit suite membership; a target is compiled once even when suites overlap.
const std = @import("std");

pub fn add(b: *std.Build) void {
    const unit = group(b, "test-unit", "Run hermetic foundation and parser tests", &.{
        "test-allocations", "test-file-picker", "test-windows-durable-fs", "test-nbt",
        "test-foundation",  "test-compression", "test-worlds-directory",   "test-metadata",
        "test-worlds",
    });
    const workflows = group(b, "test-workflows", "Run application, ownership and transaction tests", &.{
        "test-app",                "test-instances-manager",      "test-java-probe",                "test-content-install",
        "test-pack-inspection",    "test-curseforge-credentials", "test-curseforge-credentials-ui", "test-ordinary-creation",
        "test-pack-download-auth", "test-pack-source",            "test-pack-install",              "test-loader-acceptance",
    });
    const ui = group(b, "test-ui", "Run layout and UI workflow tests without a desktop", &.{
        "test-ui-layout", "test-ui-preview", "test-server-picker", "test-game-selection",
        "test-mods",      "test-content-ui", "test-packs",         "test-gui-fixture",
    });
    const integration = group(b, "test-integration", "Run managed local network, archive and Minecraft module fixtures", &.{
        "test-downloader-fixture", "test-http-fixture", "test-public-network", "test-safe-archive", "test-minecraft-fixture", "test-build-fixtures",
    });
    const tests = b.step("test", "Run local unit, workflow, UI and integration suites");
    for ([_]*std.Build.Step{ unit, workflows, ui, integration }) |suite| tests.dependOn(suite);
    _ = group(b, "check-platforms", "Compile supported installation and Windows filesystem targets", &.{
        "check-install-platforms", "check-windows-durable-fs",
    });
    _ = group(b, "test-graphics", "Run native OpenGL and software pixel regressions (requires drivers)", &.{
        "test-ui-pixels", "test-modal-backdrop-pixels",
    });
    _ = group(b, "test-all", "Run all headless suites, compile the app and check platform APIs", &.{
        "test", "compile-app", "check-platforms",
    });
}

fn group(b: *std.Build, name: []const u8, description: []const u8, members: []const []const u8) *std.Build.Step {
    const result = b.step(name, description);
    for (members) |member| result.dependOn(&b.top_level_steps.get(member).?.step);
    return result;
}

pub fn pythonFixture(b: *std.Build, python: []const u8, script: []const u8, tests: *std.Build.Step.Compile, fixture: ?*std.Build.Step.InstallArtifact) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{if (fixture != null) "env" else python});
    if (fixture) |helper| {
        run.addFileArg2(helper.artifact.getEmittedBin(), .{ .prefix = "VELA_JAVA_PROCESS_FIXTURE=", .make_absolute = true });
        run.addArg(python);
    }
    run.addFileArg(b.path(script));
    run.addArg("--test-exe");
    run.addArtifactArg(tests);
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    return run;
}

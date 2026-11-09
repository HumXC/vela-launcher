//! Offline path-contract regressions; no application or network entrypoint.
test {
    _ = @import("core/minecraft/install_plan.zig");
    _ = @import("core/minecraft/native_extract.zig");
    _ = @import("application/game_library.zig");
    _ = @import("application/game_launch.zig");
}

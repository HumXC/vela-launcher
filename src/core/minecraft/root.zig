//! Minecraft metadata and pure installation planning.
pub const metadata = @import("metadata/root.zig");
pub const install_plan = @import("install_plan.zig");
pub const install = @import("install.zig");
pub const launch = @import("launch.zig");
test {
    _ = metadata;
    _ = install_plan;
    _ = install;
    _ = launch;
}

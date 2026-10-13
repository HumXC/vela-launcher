pub const command = @import("command.zig");
pub const java_arguments = @import("java_arguments.zig");
pub const config = @import("config.zig");
pub const instances = @import("instances.zig");
pub const tasks = @import("tasks.zig");
pub const install = @import("install/root.zig");
pub const loaders = @import("loaders/root.zig");

test {
    _ = @import("minecraft/root.zig");
    _ = install;
    _ = loaders;
    _ = command;
    _ = java_arguments;
}

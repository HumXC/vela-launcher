pub const command = @import("command.zig");
pub const java_arguments = @import("java_arguments.zig");
pub const config = @import("config.zig");
pub const instances = @import("instances.zig");
pub const tasks = @import("tasks.zig");

test {
    _ = @import("minecraft/root.zig");
    _ = command;
    _ = java_arguments;
}

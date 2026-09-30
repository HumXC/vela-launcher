pub const command = @import("command.zig");
pub const java_arguments = @import("java_arguments.zig");

test {
    _ = @import("minecraft/root.zig");
    _ = command;
    _ = java_arguments;
}

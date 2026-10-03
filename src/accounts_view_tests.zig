const std = @import("std");
const view = @import("ui/accounts_view.zig");

test "accounts view native entrypoints compile" {
    std.mem.doNotOptimizeAway(&view.draw);
    std.mem.doNotOptimizeAway(&view.finish);
    std.testing.refAllDecls(view);
}

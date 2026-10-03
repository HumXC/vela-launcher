// Temporary isolated test root; no app startup or production network requests.
test {
    _ = @import("ui/server_manager.zig");
    _ = @import("ui/servers_view.zig");
}

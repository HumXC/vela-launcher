//! Root at src/ so UI Java probing can import the shared core runtime.
test {
    _ = @import("ui/java_manager.zig");
}

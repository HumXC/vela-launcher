//! Borrowed inventory data shared by the application service and its views.
const local = @import("../core/local_content.zig");

pub const Row = struct { entry: *const local.Entry, managed: bool = false };
pub const InventoryVersion = struct { source: usize, revision: u64 };
pub const Snapshot = struct {
    rows: []const Row = &.{},
    /// Changes with membership, order or searchable/sortable data.
    inventory: ?InventoryVersion = null,
    busy: bool = false,
    failure: ?anyerror = null,
    can_mutate: bool = false,
    recovery_required: bool = false,
    truncated: bool = false,
    title: ?[]const u8 = null,
    subtitle: ?[]const u8 = null,
};

//! Shared installation contracts, filesystem safety and download telemetry.
pub const Control = @import("control.zig").Control;
pub const Progress = struct { completed: usize, total: usize, downloaded: usize, reused: usize };
pub const files = @import("safe_fs.zig");
pub const telemetry = @import("download_details.zig");

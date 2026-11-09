//! Value-only preview types keep the wizard model independent of workers and HTTP.
pub const Phase = enum { idle, loading, complete, failed };

pub const Snapshot = struct {
    /// Borrowed for one UI frame; the controller owns the version identity.
    version: ?[]const u8 = null,
    java_major: ?u32 = null,
    phase: Phase = .idle,
    failure: ?anyerror = null,
};

//! Value-only creation ownership policy and generic-service scheduling.
//! Capture again after advancing a creation controller; never retain across frames.
//! No borrowed strings, controller pointers, allocations or worker lifetimes live here.
const std = @import("std");

pub const Gates = struct { java: bool, instances: bool, content: bool, worlds: bool };

pub const Ownership = struct {
    pinned: bool = false,
    java_discovery: bool = false,
    java_download: bool = false,
    instances_publication: bool = false,

    pub fn merge(self: Ownership, other: Ownership) Ownership {
        return .{
            .pinned = self.pinned or other.pinned,
            .java_discovery = self.java_discovery or other.java_discovery,
            .java_download = self.java_download or other.java_download,
            .instances_publication = self.instances_publication or other.instances_publication,
        };
    }

    pub fn gates(self: Ownership, allow_mutations: bool) Gates {
        const blocked = self.pinned or !allow_mutations;
        return .{
            .java = blocked or self.java_discovery or self.java_download,
            .instances = blocked or self.instances_publication,
            .content = blocked,
            .worlds = blocked,
        };
    }

    // The generic entry points accept production managers and counting test doubles.
    // Return whether the generic owner advanced; creation owners tick their own work.
    pub fn tickJava(self: Ownership, manager: anytype) bool {
        if (self.java_discovery) return false;
        manager.tick();
        return true;
    }

    pub fn tickJavaDownload(self: Ownership, controller: anytype, java: anytype) bool {
        if (self.java_download) return false;
        controller.tick(java);
        return true;
    }

    pub fn tickInstances(self: Ownership, manager: anytype) bool {
        if (self.instances_publication) return false;
        manager.tick();
        return true;
    }
};

test "creation ownership keeps draining work owned even when presentation is terminal" {
    const held: Ownership = .{ .java_download = true, .instances_publication = true };
    const Counter = struct {
        count: usize = 0,
        pub fn tick(self: *@This()) void {
            self.count += 1;
        }
    };
    const Download = struct {
        count: usize = 0,
        pub fn tick(self: *@This(), _: *Counter) void {
            self.count += 1;
        }
    };
    var java: Counter = .{};
    var instances: Counter = .{};
    var download: Download = .{};
    try std.testing.expect(held.tickJava(&java));
    try std.testing.expect(!held.tickJavaDownload(&download, &java));
    try std.testing.expect(!held.tickInstances(&instances));
    const gates = held.gates(true);
    try std.testing.expect(gates.java and gates.instances and !gates.content);
    const released: Ownership = .{};
    try std.testing.expect(released.tickJavaDownload(&download, &java));
    try std.testing.expect(released.tickInstances(&instances));
    try std.testing.expectEqual(@as(usize, 1), java.count);
    try std.testing.expectEqual(@as(usize, 1), download.count);
    try std.testing.expectEqual(@as(usize, 1), instances.count);
}

test "creation admission combines owners and shutdown without stopping generic cleanup" {
    const ordinary: Ownership = .{ .pinned = true, .java_discovery = true };
    const pack: Ownership = .{ .java_download = true, .instances_publication = true };
    const joined = ordinary.merge(pack);
    try std.testing.expect(joined.java_discovery and joined.java_download and joined.instances_publication);
    const gates = joined.gates(true);
    try std.testing.expect(gates.java and gates.instances and gates.content and gates.worlds);
    const idle: Ownership = .{};
    const shutdown = idle.gates(false);
    try std.testing.expect(shutdown.java and shutdown.instances and shutdown.content and shutdown.worlds);
    try std.testing.expect(!idle.java_discovery and !idle.java_download and !idle.instances_publication);
}

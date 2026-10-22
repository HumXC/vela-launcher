//! Instance file ownership is independent of the Minecraft download version.
const std = @import("std");
const metadata = @import("metadata/root.zig");

pub const Target = struct {
    /// Storage directory, including a private stage during installation.
    directory_name: []const u8,
    /// Final instance name used by its JSON and JAR.
    name: []const u8,

    pub fn validate(self: Target) !void {
        try metadata.version.validateId(self.directory_name);
        try metadata.version.validateId(self.name);
    }

    pub fn clientPath(self: Target, a: std.mem.Allocator) ![]u8 {
        try self.validate();
        return std.fmt.allocPrint(a, "versions/{s}/{s}.jar", .{ self.directory_name, self.name });
    }

    pub fn documentPath(self: Target, a: std.mem.Allocator) ![]u8 {
        try self.validate();
        return std.fmt.allocPrint(a, "versions/{s}/{s}.json", .{ self.directory_name, self.name });
    }
};

/// Only installed metadata may redirect a client to another instance.
/// Installers always use an explicit Target and publish their own client.
pub fn installedClient(a: std.mem.Allocator, version: metadata.version.Version) ![]u8 {
    const owner = version.jar orelse version.id;
    return (Target{ .directory_name = owner, .name = owner }).clientPath(a);
}

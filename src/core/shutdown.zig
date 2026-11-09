//! Pure operation summary for the single application exit confirmation.
const std = @import("std");

pub const Operation = enum {
    instance_install,
    java_install,
    pack_install,
    pack_update,
    mod_install,
    resourcepack_install,
    shader_install,
    save_backup,
    save_copy,
    save_restore,

    pub fn label(operation: Operation) []const u8 {
        return switch (operation) {
            .instance_install => "安装实例",
            .java_install => "安装 Java",
            .pack_install => "安装整合包",
            .pack_update => "更新整合包",
            .mod_install => "安装模组",
            .resourcepack_install => "安装资源包",
            .shader_install => "安装光影",
            .save_backup => "备份存档",
            .save_copy => "复制存档",
            .save_restore => "恢复存档",
        };
    }
};

pub const Summary = struct {
    operations: [@typeInfo(Operation).@"enum".field_names.len]bool = @splat(false),

    pub fn add(self: *Summary, operation: Operation) void {
        self.operations[@backingInt(operation)] = true;
    }

    pub fn contains(self: Summary, operation: Operation) bool {
        return self.operations[@backingInt(operation)];
    }

    pub fn any(self: Summary) bool {
        for (self.operations) |active| if (active) return true;
        return false;
    }

    pub fn count(self: Summary) usize {
        var total: usize = 0;
        for (self.operations) |active| if (active) {
            total += 1;
        };
        return total;
    }

    pub fn cancelLabel(self: Summary) []const u8 {
        return if (self.contains(.save_backup) or self.contains(.save_copy) or self.contains(.save_restore) or self.contains(.pack_update))
            "取消操作并退出"
        else
            "取消安装并退出";
    }
};

test "shutdown summary starts empty and deduplicates each operation" {
    var summary: Summary = .{};
    try std.testing.expect(!summary.any());
    try std.testing.expectEqual(@as(usize, 0), summary.count());
    inline for (@typeInfo(Operation).@"enum".field_names) |field| {
        const operation: Operation = @field(Operation, field);
        try std.testing.expect(!summary.contains(operation));
        summary.add(operation);
        summary.add(operation);
        try std.testing.expect(summary.contains(operation));
    }
    try std.testing.expect(summary.any());
    try std.testing.expectEqual(@typeInfo(Operation).@"enum".field_names.len, summary.count());
}

test "shutdown cancellation wording distinguishes installation and save operations" {
    inline for (@typeInfo(Operation).@"enum".field_names) |field| {
        const operation: Operation = @field(Operation, field);
        var summary: Summary = .{};
        summary.add(operation);
        const expected = switch (operation) {
            .save_backup, .save_copy, .save_restore, .pack_update => "取消操作并退出",
            else => "取消安装并退出",
        };
        try std.testing.expectEqualStrings(expected, summary.cancelLabel());
        try std.testing.expect(operation.label().len > 0);
    }
}

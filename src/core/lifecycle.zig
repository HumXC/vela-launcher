const std = @import("std");

pub const ExitBehavior = enum { restore_launcher, exit_launcher };
pub const Options = struct {
    after_game: ExitBehavior = .restore_launcher,
    debug_launch: bool = false,
};
pub const GameState = enum { idle, preparing, running };
pub const EndReason = union(enum) {
    exited: u32,
    stopped,
    failed,
    terminated,

    pub fn abnormal(self: EndReason) bool {
        return switch (self) {
            .exited => |code| code != 0,
            .stopped => false,
            .failed, .terminated => true,
        };
    }
};
pub const CloseChoice = enum { wait, cancel_and_quit, keep_open };
pub const Shutdown = enum { none, prompt, wait, canceling };
pub const Actions = struct {
    hide: bool = false,
    restore: bool = false,
    show_logs: bool = false,
    show_home: bool = false,
    prompt_background: bool = false,
    cancel_background: bool = false,
    quit: bool = false,
};

/// Main-thread policy only. Apply actions after closing frame widgets.
/// Background counts must include canceling workers until they have been joined.
pub const Policy = struct {
    game: GameState = .idle,
    options: Options = .{},
    shutdown: Shutdown = .none,
    hidden_by_close: bool = false,

    pub fn canLaunch(self: *const Policy) bool {
        return self.game == .idle and self.shutdown == .none;
    }

    pub fn launchStarted(self: *Policy, options: Options) Actions {
        if (!self.canLaunch()) return .{};
        self.game = .preparing;
        self.options = options;
        self.hidden_by_close = false;
        return if (options.debug_launch) .{ .restore = true, .show_logs = true } else .{};
    }

    pub fn gameRunning(self: *Policy) Actions {
        if (self.game != .preparing) return .{};
        self.game = .running;
        return if (self.options.debug_launch)
            .{ .restore = !self.hidden_by_close, .show_logs = true }
        else
            .{ .hide = true };
    }

    /// Deliver the controller's end reason even if no running frame was drawn.
    /// A late failure still overrides a pending normal-exit shutdown.
    pub fn gameEnded(self: *Policy, reason: EndReason, active_background: usize) Actions {
        const was_active = self.game != .idle;
        const closed_logs = self.options.debug_launch and self.hidden_by_close;
        self.game = .idle;
        self.hidden_by_close = false;
        // Closing debug output dismisses that page for this launch, including
        // abnormal exits. Restore Home after the child has finished.
        if (was_active and closed_logs) {
            self.shutdown = .none;
            return .{ .restore = true, .show_home = true };
        }
        if (reason.abnormal()) {
            self.shutdown = .none;
            return .{ .restore = true, .show_logs = true };
        }
        if (!was_active) return .{};
        if (self.options.debug_launch) {
            self.shutdown = .none;
            return .{ .restore = true, .show_logs = true };
        }
        if (self.options.after_game == .restore_launcher) return .{ .restore = true };
        return self.requestShutdown(active_background);
    }

    pub fn closeRequested(self: *Policy, active_background: usize) Actions {
        if (self.game != .idle) {
            self.hidden_by_close = true;
            return .{ .hide = true };
        }
        return self.requestShutdown(active_background);
    }

    fn requestShutdown(self: *Policy, active_background: usize) Actions {
        if (self.shutdown != .none) return .{};
        if (active_background == 0) return .{ .quit = true };
        self.shutdown = .prompt;
        return .{ .restore = true, .prompt_background = true };
    }

    pub fn chooseClose(self: *Policy, choice: CloseChoice, active_background: usize) Actions {
        if (self.shutdown != .prompt or self.game != .idle) return .{};
        switch (choice) {
            .keep_open => {
                self.shutdown = .none;
                return .{};
            },
            .wait => {
                self.shutdown = .wait;
                return self.backgroundChanged(active_background);
            },
            .cancel_and_quit => {
                self.shutdown = .canceling;
                // Even zero active tasks requires an explicit join acknowledgement.
                return .{ .cancel_background = true };
            },
        }
    }

    /// Registry terminal states must only be published after worker joins.
    pub fn backgroundChanged(self: *Policy, active_background: usize) Actions {
        if (self.game == .idle and self.shutdown == .wait and active_background == 0) {
            self.shutdown = .none;
            return .{ .quit = true };
        }
        return .{};
    }

    /// Call only after joining ALL background tasks, not just sending cancel tokens.
    pub fn backgroundJoined(self: *Policy) Actions {
        if (self.game == .idle and self.shutdown == .canceling) {
            self.shutdown = .none;
            return .{ .quit = true };
        }
        return .{};
    }
};

test "ordinary launch hides only once running and restores by default" {
    var policy: Policy = .{};
    try std.testing.expectEqual(Actions{}, policy.launchStarted(.{}));
    try std.testing.expectEqual(GameState.preparing, policy.game);
    try std.testing.expectEqual(Actions{ .hide = true }, policy.gameRunning());
    try std.testing.expectEqual(Actions{}, policy.gameRunning());
    try std.testing.expectEqual(Actions{ .restore = true }, policy.gameEnded(.{ .exited = 0 }, 0));
    try std.testing.expect(policy.canLaunch());
}

test "fast success before running frame honors exit preference without hiding" {
    var policy: Policy = .{};
    _ = policy.launchStarted(.{ .after_game = .exit_launcher });
    try std.testing.expectEqual(Actions{ .quit = true }, policy.gameEnded(.{ .exited = 0 }, 0));
    try std.testing.expectEqual(Actions{}, policy.gameRunning());
    try std.testing.expectEqual(Actions{}, policy.gameEnded(.{ .exited = 0 }, 0));
}

test "all abnormal outcomes override exit and restore logs in every phase" {
    const reasons = [_]EndReason{ .failed, .terminated, .{ .exited = 1 }, .{ .exited = 137 } };
    for (reasons) |reason| {
        for ([_]bool{ false, true }) |running| {
            var policy: Policy = .{};
            _ = policy.launchStarted(.{ .after_game = .exit_launcher });
            if (running) _ = policy.gameRunning();
            try std.testing.expectEqual(Actions{ .restore = true, .show_logs = true }, policy.gameEnded(reason, 5));
            try std.testing.expectEqual(Shutdown.none, policy.shutdown);
            try std.testing.expectEqual(Actions{}, policy.backgroundChanged(0));
        }
    }
}

test "explicit stop is normal even when underlying process was killed" {
    var policy: Policy = .{};
    _ = policy.launchStarted(.{});
    _ = policy.gameRunning();
    try std.testing.expectEqual(Actions{ .restore = true }, policy.gameEnded(.stopped, 0));
    _ = policy.launchStarted(.{ .after_game = .exit_launcher });
    try std.testing.expectEqual(Actions{ .quit = true }, policy.gameEnded(.stopped, 0));
}

test "debug shows logs in preparation and running and suppresses autoexit" {
    var policy: Policy = .{};
    const logs = Actions{ .restore = true, .show_logs = true };
    try std.testing.expectEqual(logs, policy.launchStarted(.{ .debug_launch = true, .after_game = .exit_launcher }));
    try std.testing.expectEqual(logs, policy.gameRunning());
    try std.testing.expectEqual(logs, policy.gameEnded(.{ .exited = 0 }, 2));
    try std.testing.expectEqual(Shutdown.none, policy.shutdown);
    _ = policy.launchStarted(.{ .debug_launch = true, .after_game = .exit_launcher });
    try std.testing.expectEqual(logs, policy.gameEnded(.{ .exited = 0 }, 0));
}

test "window close while preparing or running only hides and keeps game alive" {
    for ([_]bool{ false, true }) |debug| {
        for ([_]bool{ false, true }) |running| {
            var policy: Policy = .{};
            _ = policy.launchStarted(.{ .debug_launch = debug, .after_game = .exit_launcher });
            if (running) _ = policy.gameRunning();
            const state = policy.game;
            try std.testing.expectEqual(Actions{ .hide = true }, policy.closeRequested(3));
            try std.testing.expectEqual(state, policy.game);
            try std.testing.expectEqual(Shutdown.none, policy.shutdown);
            try std.testing.expectEqual(Actions{}, policy.chooseClose(.cancel_and_quit, 3));
            if (debug and !running) {
                try std.testing.expectEqual(Actions{ .show_logs = true }, policy.gameRunning());
            }
            if (debug) {
                try std.testing.expectEqual(Actions{ .restore = true, .show_home = true }, policy.gameEnded(.stopped, 0));
            }
        }
    }
}

test "dismissed debug logs restore Home for every end reason and reset per launch" {
    const reasons = [_]EndReason{ .{ .exited = 0 }, .{ .exited = 1 }, .stopped, .failed, .terminated };
    for (reasons) |reason| {
        for ([_]bool{ false, true }) |running| {
            for ([_]ExitBehavior{ .restore_launcher, .exit_launcher }) |after_game| {
                var policy: Policy = .{};
                _ = policy.launchStarted(.{ .debug_launch = true, .after_game = after_game });
                if (running) _ = policy.gameRunning();
                _ = policy.closeRequested(3);
                try std.testing.expectEqual(Actions{ .restore = true, .show_home = true }, policy.gameEnded(reason, 3));
                try std.testing.expectEqual(Shutdown.none, policy.shutdown);
                try std.testing.expect(!policy.hidden_by_close);
                try std.testing.expect(policy.canLaunch());
                try std.testing.expectEqual(Actions{}, policy.backgroundChanged(0));
                try std.testing.expectEqual(Actions{ .restore = true, .show_logs = true }, policy.launchStarted(.{ .debug_launch = true }));
                try std.testing.expectEqual(Actions{ .restore = true, .show_logs = true }, policy.gameEnded(.{ .exited = 0 }, 0));
            }
        }
    }
}

test "idle close exits directly only without active background tasks" {
    var policy: Policy = .{};
    try std.testing.expectEqual(Actions{ .quit = true }, policy.closeRequested(0));
    try std.testing.expectEqual(Actions{ .restore = true, .prompt_background = true }, policy.closeRequested(2));
    try std.testing.expect(!policy.canLaunch());
    try std.testing.expectEqual(Actions{}, policy.closeRequested(2));
    try std.testing.expectEqual(Actions{}, policy.chooseClose(.keep_open, 2));
    try std.testing.expect(policy.canLaunch());
    try std.testing.expectEqual(Actions{}, policy.backgroundChanged(0));
}

test "wait keeps tasks active and exits only after all joined tasks finish" {
    var policy: Policy = .{};
    _ = policy.closeRequested(2);
    try std.testing.expectEqual(Actions{}, policy.chooseClose(.wait, 2));
    try std.testing.expectEqual(Shutdown.wait, policy.shutdown);
    try std.testing.expectEqual(Actions{}, policy.backgroundChanged(1));
    try std.testing.expectEqual(Actions{}, policy.backgroundJoined());
    try std.testing.expectEqual(Actions{ .quit = true }, policy.backgroundChanged(0));
    try std.testing.expectEqual(Actions{}, policy.backgroundChanged(0));
}

test "cancel requests cancellation but zero count alone cannot authorize quit" {
    var policy: Policy = .{};
    _ = policy.closeRequested(1);
    try std.testing.expectEqual(Actions{ .cancel_background = true }, policy.chooseClose(.cancel_and_quit, 1));
    try std.testing.expectEqual(Actions{}, policy.backgroundChanged(0));
    try std.testing.expectEqual(Actions{}, policy.closeRequested(0));
    try std.testing.expectEqual(Actions{ .quit = true }, policy.backgroundJoined());
    try std.testing.expectEqual(Actions{}, policy.backgroundJoined());
}

test "autoexit with background tasks prompts and accepts wait or cancel" {
    for ([_]CloseChoice{ .wait, .cancel_and_quit, .keep_open }) |choice| {
        var policy: Policy = .{};
        _ = policy.launchStarted(.{ .after_game = .exit_launcher });
        try std.testing.expectEqual(Actions{ .restore = true, .prompt_background = true }, policy.gameEnded(.{ .exited = 0 }, 1));
        const action = policy.chooseClose(choice, 0);
        switch (choice) {
            .wait => try std.testing.expectEqual(Actions{ .quit = true }, action),
            .cancel_and_quit => {
                try std.testing.expectEqual(Actions{ .cancel_background = true }, action);
                try std.testing.expectEqual(Actions{ .quit = true }, policy.backgroundJoined());
            },
            .keep_open => try std.testing.expectEqual(Actions{}, action),
        }
    }
}

test "late failure cancels pending exit regardless of close choice" {
    for ([_]Shutdown{ .prompt, .wait, .canceling }) |pending| {
        var policy: Policy = .{};
        _ = policy.launchStarted(.{ .after_game = .exit_launcher });
        _ = policy.gameEnded(.{ .exited = 0 }, 1);
        policy.shutdown = pending;
        try std.testing.expectEqual(Actions{ .restore = true, .show_logs = true }, policy.gameEnded(.failed, 0));
        try std.testing.expectEqual(Actions{}, policy.backgroundChanged(0));
        try std.testing.expectEqual(Actions{}, policy.backgroundJoined());
    }
}

test "duplicate launch cannot change current game or preferences" {
    var policy: Policy = .{};
    _ = policy.launchStarted(.{});
    try std.testing.expectEqual(Actions{}, policy.launchStarted(.{ .after_game = .exit_launcher, .debug_launch = true }));
    try std.testing.expectEqual(Actions{ .restore = true }, policy.gameEnded(.{ .exited = 0 }, 0));
}

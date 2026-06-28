// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const rules = @import("game");
const state_hash = rules.DeterministicHash;

pub const FixedFps: u16 = 60;
pub const DasDelayFrames: u8 = 10;
pub const ArrIntervalFrames: u8 = 2;
pub const SoftDropCellsPerFrame: u32 = 1;

pub const HorizontalDirection = enum {
    left,
    right,
};

pub const FrameInput = struct {
    left_down: bool = false,
    right_down: bool = false,
    down_down: bool = false,

    left_pressed: bool = false,
    right_pressed: bool = false,
    rotate_cw_pressed: bool = false,
    rotate_ccw_pressed: bool = false,
    rotate_180_pressed: bool = false,
    hold_pressed: bool = false,
    hard_drop_pressed: bool = false,
    pause_pressed: bool = false,
    restart_pressed: bool = false,
};

pub const ApplyResult = struct {
    paused_toggled: bool = false,
    restarted: bool = false,
    hard_dropped: bool = false,
    soft_dropped: bool = false,
    lock_result: ?rules.LockResult = null,
};

pub const RepeatKey = struct {
    down: bool = false,
    frames_until_repeat: u8 = 0,

    pub fn reset(self: *RepeatKey) void {
        self.* = .{};
    }

    pub fn update(self: *RepeatKey, is_down: bool) bool {
        if (!is_down) {
            self.reset();
            return false;
        }

        if (!self.down) {
            self.down = true;
            self.frames_until_repeat = DasDelayFrames;
            return true;
        }

        if (self.frames_until_repeat > 0) {
            self.frames_until_repeat -= 1;
            if (self.frames_until_repeat > 0) return false;
        }

        self.frames_until_repeat = ArrIntervalFrames;
        return true;
    }
};

pub const Controller = struct {
    left: RepeatKey = .{},
    right: RepeatKey = .{},
    horizontal_preference: ?HorizontalDirection = null,

    pub fn reset(self: *Controller) void {
        self.* = .{};
    }

    pub fn clearHorizontal(self: *Controller) void {
        self.left.reset();
        self.right.reset();
        self.horizontal_preference = null;
    }

    /// Feed deterministic controller repeat/preference state into the match
    /// state hash. Frame input itself is not stored here; only input-derived
    /// DAS/ARR state that can affect future simulation is included.
    pub fn feedDeterministicHash(self: *const Controller, hasher: *std.hash.XxHash64) void {
        feedRepeatKeyHash(hasher, self.left);
        feedRepeatKeyHash(hasher, self.right);
        feedOptionalHorizontalDirectionHash(hasher, self.horizontal_preference);
    }

    pub fn horizontalMoveThisFrame(self: *Controller, frame: FrameInput) i32 {
        self.updateHorizontalPreference(frame);
        const left_fired = self.left.update(frame.left_down);
        const right_fired = self.right.update(frame.right_down);

        const preference = self.horizontal_preference orelse return 0;
        return switch (preference) {
            .left => if (left_fired) -1 else 0,
            .right => if (right_fired) 1 else 0,
        };
    }

    /// Apply gameplay controls for one fixed frame.
    ///
    /// This intentionally ignores shell-level pause/restart bits. Callers that
    /// own a pause menu, restart policy, or match lifecycle must resolve those
    /// before calling this helper.
    pub fn applyGameplayToGame(self: *Controller, game: *rules.Game, frame: FrameInput) ApplyResult {
        var result = ApplyResult{};

        if (game.game_over) {
            self.clearHorizontal();
            return result;
        }

        if (frame.hold_pressed) _ = game.holdPiece();
        if (frame.rotate_ccw_pressed) {
            _ = game.tryRotate(.counter_clockwise);
        } else if (frame.rotate_cw_pressed) {
            _ = game.tryRotate(.clockwise);
        } else if (frame.rotate_180_pressed) {
            _ = game.tryRotate(.half_turn);
        }

        const dx = self.horizontalMoveThisFrame(frame);
        if (dx != 0) _ = game.tryMove(dx, 0);

        if (frame.hard_drop_pressed) {
            if (game.hardDropAndLockDetailed()) |lock_result| {
                result.hard_dropped = true;
                result.lock_result = lock_result;
            }
            return result;
        }

        if (frame.down_down) {
            result.soft_dropped = game.softDropCells(SoftDropCellsPerFrame) > 0;
        }
        return result;
    }

    /// Apply one-player shell policy before gameplay controls.
    ///
    /// Deterministic input order for a fixed frame: restart, pause, hold, one
    /// rotation (CCW/CW/180 priority), horizontal DAS/ARR, hard drop, soft drop.
    /// The main loop then applies lock-delay ticking and natural gravity only
    /// when no soft-drop cell moved this frame.
    pub fn applyToGame(self: *Controller, game: *rules.Game, frame: FrameInput, paused: *bool, restart_seed: u64) ApplyResult {
        var result = ApplyResult{};

        if (frame.restart_pressed) {
            game.* = rules.Game.init(restart_seed);
            paused.* = false;
            self.reset();
            result.restarted = true;
            return result;
        }

        if (frame.pause_pressed and !game.game_over) {
            paused.* = !paused.*;
            self.clearHorizontal();
            result.paused_toggled = true;
            return result;
        }

        if (game.game_over) {
            paused.* = false;
            self.clearHorizontal();
            return result;
        }

        if (paused.*) {
            self.clearHorizontal();
            return result;
        }

        return self.applyGameplayToGame(game, frame);
    }

    fn updateHorizontalPreference(self: *Controller, frame: FrameInput) void {
        if (frame.left_pressed and frame.right_pressed) {
            self.horizontal_preference = .right;
        } else if (frame.left_pressed) {
            self.horizontal_preference = .left;
        } else if (frame.right_pressed) {
            self.horizontal_preference = .right;
        }

        if (self.horizontal_preference) |direction| {
            switch (direction) {
                .left => if (!frame.left_down) {
                    self.horizontal_preference = if (frame.right_down) .right else null;
                },
                .right => if (!frame.right_down) {
                    self.horizontal_preference = if (frame.left_down) .left else null;
                },
            }
        }

        if (self.horizontal_preference == null) {
            if (frame.right_down) {
                self.horizontal_preference = .right;
            } else if (frame.left_down) {
                self.horizontal_preference = .left;
            }
        }
    }
};

fn feedRepeatKeyHash(hasher: *std.hash.XxHash64, key: RepeatKey) void {
    state_hash.feedBool(hasher, key.down);
    state_hash.feedU8(hasher, key.frames_until_repeat);
}

fn feedOptionalHorizontalDirectionHash(hasher: *std.hash.XxHash64, direction: ?HorizontalDirection) void {
    if (direction) |value| {
        state_hash.feedBool(hasher, true);
        feedHorizontalDirectionHash(hasher, value);
    } else {
        state_hash.feedBool(hasher, false);
    }
}

fn feedHorizontalDirectionHash(hasher: *std.hash.XxHash64, direction: HorizontalDirection) void {
    state_hash.feedU8(hasher, switch (direction) {
        .left => 0,
        .right => 1,
    });
}

fn testControllerDeterministicHash(controller: *const Controller) u64 {
    var hasher = std.hash.XxHash64.init(0);
    controller.feedDeterministicHash(&hasher);
    return hasher.final();
}

test "controller deterministic hash tracks repeat and preference state" {
    var left = Controller{};
    var right = Controller{};
    try std.testing.expectEqual(testControllerDeterministicHash(&left), testControllerDeterministicHash(&right));

    _ = left.horizontalMoveThisFrame(.{ .left_down = true, .left_pressed = true });
    try std.testing.expect(testControllerDeterministicHash(&left) != testControllerDeterministicHash(&right));

    _ = right.horizontalMoveThisFrame(.{ .left_down = true, .left_pressed = true });
    try std.testing.expectEqual(testControllerDeterministicHash(&left), testControllerDeterministicHash(&right));
}

test "DAS/ARR emits initial move then delayed repeats" {
    var controller = Controller{};
    try std.testing.expectEqual(@as(i32, -1), controller.horizontalMoveThisFrame(.{
        .left_down = true,
        .left_pressed = true,
    }));

    for (0..@as(usize, DasDelayFrames - 1)) |_| {
        try std.testing.expectEqual(@as(i32, 0), controller.horizontalMoveThisFrame(.{ .left_down = true }));
    }
    try std.testing.expectEqual(@as(i32, -1), controller.horizontalMoveThisFrame(.{ .left_down = true }));

    for (0..@as(usize, ArrIntervalFrames - 1)) |_| {
        try std.testing.expectEqual(@as(i32, 0), controller.horizontalMoveThisFrame(.{ .left_down = true }));
    }
    try std.testing.expectEqual(@as(i32, -1), controller.horizontalMoveThisFrame(.{ .left_down = true }));
}

test "most recently pressed horizontal direction wins conflicts" {
    var controller = Controller{};
    try std.testing.expectEqual(@as(i32, -1), controller.horizontalMoveThisFrame(.{
        .left_down = true,
        .left_pressed = true,
    }));
    try std.testing.expectEqual(@as(i32, 1), controller.horizontalMoveThisFrame(.{
        .left_down = true,
        .right_down = true,
        .right_pressed = true,
    }));
}

test "simultaneous rotation inputs use one deterministic priority action" {
    var controller = Controller{};
    var game = rules.Game.initNoSpawn(91);
    game.active = .{
        .kind = .t,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = 30 },
    };

    _ = controller.applyGameplayToGame(&game, .{
        .rotate_ccw_pressed = true,
        .rotate_cw_pressed = true,
        .rotate_180_pressed = true,
    });

    try std.testing.expectEqual(rules.Rotation.left, game.active.?.rotation);
}

test "pause input is ignored once the game is over" {
    var controller = Controller{};
    var game = rules.Game.initNoSpawn(94);
    var paused = true;
    game.game_over = true;

    const result = controller.applyToGame(&game, .{ .pause_pressed = true }, &paused, 94);

    try std.testing.expect(!paused);
    try std.testing.expect(!result.paused_toggled);
}

test "gameplay-only input ignores shell pause and restart bits" {
    var controller = Controller{};
    var game = rules.Game.initNoSpawn(95);
    game.active = .{
        .kind = .o,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = 30 },
    };

    const result = controller.applyGameplayToGame(&game, .{
        .pause_pressed = true,
        .restart_pressed = true,
        .hard_drop_pressed = true,
    });

    try std.testing.expect(!result.paused_toggled);
    try std.testing.expect(!result.restarted);
    try std.testing.expect(result.hard_dropped);
    try std.testing.expectEqual(@as(u32, 1), game.pieces_locked);
}

test "soft drop reports moved cells for main loop gravity suppression" {
    var controller = Controller{};
    var game = rules.Game.initNoSpawn(92);
    game.active = .{
        .kind = .o,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = rules.BoardHeightI - 3 },
    };

    const result = controller.applyGameplayToGame(&game, .{ .down_down = true });

    try std.testing.expect(result.soft_dropped);
    try std.testing.expectEqual(@as(i32, rules.BoardHeightI - 2), game.active.?.pos.y);

    const lock_result = game.lockActiveDetailed().?;
    try std.testing.expectEqual(@as(u32, 1), lock_result.soft_drop_points);
}

test "hard drop keeps earlier soft drop points but skips same-frame soft drop" {
    var controller = Controller{};
    var game = rules.Game.initNoSpawn(93);
    game.active = .{
        .kind = .o,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = 30 },
    };

    try std.testing.expect(game.softDropOne());
    const result = controller.applyGameplayToGame(&game, .{
        .down_down = true,
        .hard_drop_pressed = true,
    });

    try std.testing.expect(result.hard_dropped);
    try std.testing.expect(!result.soft_dropped);
    try std.testing.expectEqual(@as(u32, 7), result.lock_result.?.hard_drop_cells);
    try std.testing.expectEqual(@as(u32, 1), result.lock_result.?.soft_drop_points);
    try std.testing.expectEqual(@as(u32, 15), result.lock_result.?.score_delta);
}

test "hard drop input locks immediately before soft drop" {
    var controller = Controller{};
    var game = rules.Game.initNoSpawn(90);
    game.active = .{
        .kind = .o,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = 30 },
    };

    const result = controller.applyGameplayToGame(&game, .{
        .down_down = true,
        .hard_drop_pressed = true,
    });

    try std.testing.expect(result.hard_dropped);
    try std.testing.expect(!result.soft_dropped);
    try std.testing.expectEqual(@as(u32, 8), result.lock_result.?.hard_drop_cells);
    try std.testing.expectEqual(@as(u32, 0), result.lock_result.?.soft_drop_points);
    try std.testing.expectEqual(@as(u32, 1), game.pieces_locked);
}

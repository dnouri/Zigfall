// SPDX-License-Identifier: GPL-3.0-or-later

//! Deterministic two-player match runner.
//!
//! This module owns match-level policy: two independent games, fixed-frame
//! stepping, global pause/restart, and outcome detection. Rendering and raylib
//! input polling stay outside this module.

const std = @import("std");
const rules = @import("game");
const controls = @import("input");

pub const PlayerCount: usize = 2;

pub const PlayerIndex = enum(u1) {
    p1 = 0,
    p2 = 1,

    pub fn index(self: PlayerIndex) usize {
        return switch (self) {
            .p1 => 0,
            .p2 => 1,
        };
    }

    pub fn opponent(self: PlayerIndex) PlayerIndex {
        return switch (self) {
            .p1 => .p2,
            .p2 => .p1,
        };
    }
};

pub const MatchSettings = struct {
    player_seeds: [PlayerCount]u64,
};

pub const MatchInput = struct {
    players: [PlayerCount]controls.FrameInput = .{ .{}, .{} },
};

pub const PlayerStepResult = struct {
    lock_result: ?rules.LockResult = null,
    hard_dropped: bool = false,
    soft_dropped: bool = false,
    gravity_moved: bool = false,
};

pub const MatchOutcome = union(enum) {
    winner: PlayerIndex,
    draw,
};

pub const MatchStepResult = struct {
    players: [PlayerCount]PlayerStepResult = .{ .{}, .{} },
    restarted: bool = false,
    pause_toggled: bool = false,
    paused: bool = false,
    outcome: ?MatchOutcome = null,
};

pub const PlayerRuntime = struct {
    game: rules.Game,
    controller: controls.Controller = .{},
    gravity_counter: u16 = 0,

    pub fn init(seed: u64) PlayerRuntime {
        return .{ .game = rules.Game.init(seed) };
    }

    pub fn alive(self: *const PlayerRuntime) bool {
        return !self.game.game_over;
    }
};

pub const Match = struct {
    settings: MatchSettings,
    players: [PlayerCount]PlayerRuntime,
    paused: bool = false,
    /// Non-restart Match.step calls accepted by the match, including paused
    /// frames and frames after an outcome has already been reached.
    input_frame_count: u64 = 0,
    /// Frames where unpaused gameplay actually advanced for both players.
    gameplay_frame_count: u64 = 0,
    outcome: ?MatchOutcome = null,

    pub fn init(settings: MatchSettings) Match {
        return .{
            .settings = settings,
            .players = .{
                PlayerRuntime.init(settings.player_seeds[0]),
                PlayerRuntime.init(settings.player_seeds[1]),
            },
        };
    }

    pub fn player(self: *Match, index: PlayerIndex) *PlayerRuntime {
        return &self.players[index.index()];
    }

    pub fn playerConst(self: *const Match, index: PlayerIndex) *const PlayerRuntime {
        return &self.players[index.index()];
    }

    pub fn restart(self: *Match) void {
        self.* = Match.init(self.settings);
    }

    /// Advance one match input frame. Restart resets the match and is not
    /// counted. Paused frames and frames after a final outcome increment
    /// `input_frame_count`, while only unpaused gameplay frames increment
    /// `gameplay_frame_count`.
    pub fn step(self: *Match, match_input: MatchInput) MatchStepResult {
        var result = MatchStepResult{
            .paused = self.paused,
            .outcome = self.outcome,
        };

        if (requestedRestart(match_input)) {
            self.restart();
            result.restarted = true;
            result.paused = false;
            result.outcome = null;
            return result;
        }

        self.input_frame_count += 1;

        self.updateOutcome();
        if (self.outcome != null) {
            self.resetControllers();
            result.paused = self.paused;
            result.outcome = self.outcome;
            return result;
        }

        if (requestedPause(match_input)) {
            self.paused = !self.paused;
            self.resetControllers();
            self.resetGravityCounters();
            result.pause_toggled = true;
            result.paused = self.paused;
            return result;
        }

        if (self.paused) {
            self.resetControllers();
            result.paused = true;
            return result;
        }

        // Phase 1 steps players sequentially, but the contract is simultaneous:
        // collect every player's result for this input frame before resolving
        // any later match-level effects such as garbage or final outcome.
        inline for (0..PlayerCount) |i| {
            result.players[i] = self.stepPlayer(i, match_input.players[i]);
        }

        self.updateOutcome();
        self.gameplay_frame_count += 1;
        result.outcome = self.outcome;
        return result;
    }

    fn stepPlayer(self: *Match, comptime player_index: usize, frame: controls.FrameInput) PlayerStepResult {
        var player_runtime = &self.players[player_index];
        const input_result = player_runtime.controller.applyGameplayToGame(&player_runtime.game, frame);

        var result = PlayerStepResult{
            .lock_result = input_result.lock_result,
            .hard_dropped = input_result.hard_dropped,
            .soft_dropped = input_result.soft_dropped,
        };

        if (input_result.hard_dropped or input_result.soft_dropped) {
            player_runtime.gravity_counter = 0;
        }

        if (input_result.hard_dropped or player_runtime.game.game_over) {
            return result;
        }

        const gravity_due = !input_result.soft_dropped and advanceGravityCounter(
            &player_runtime.gravity_counter,
            player_runtime.game.gravityIntervalFrames(),
        );
        const step_result = player_runtime.game.step(.{ .apply_gravity = gravity_due });
        result.gravity_moved = step_result.gravity_moved;
        if (step_result.lock_result) |lock_result| {
            result.lock_result = lock_result;
            player_runtime.gravity_counter = 0;
        }
        return result;
    }

    fn updateOutcome(self: *Match) void {
        const p1_over = self.players[0].game.game_over;
        const p2_over = self.players[1].game.game_over;
        self.outcome = if (p1_over and p2_over)
            .draw
        else if (p1_over)
            .{ .winner = .p2 }
        else if (p2_over)
            .{ .winner = .p1 }
        else
            null;
    }

    fn resetControllers(self: *Match) void {
        for (&self.players) |*player_runtime| {
            player_runtime.controller.reset();
        }
    }

    fn resetGravityCounters(self: *Match) void {
        for (&self.players) |*player_runtime| {
            player_runtime.gravity_counter = 0;
        }
    }
};

pub fn advanceGravityCounter(counter: *u16, interval_frames: u16) bool {
    if (interval_frames <= 1) return true;
    counter.* += 1;
    if (counter.* >= interval_frames) {
        counter.* = 0;
        return true;
    }
    return false;
}

fn requestedRestart(match_input: MatchInput) bool {
    for (match_input.players) |frame| {
        if (frame.restart_pressed) return true;
    }
    return false;
}

fn requestedPause(match_input: MatchInput) bool {
    for (match_input.players) |frame| {
        if (frame.pause_pressed) return true;
    }
    return false;
}

fn testSettings() MatchSettings {
    return .{ .player_seeds = .{ 0x5A49_4746_414C_4C21, 0x5457_4F50_4C41_5932 } };
}

fn testInput(p1: controls.FrameInput, p2: controls.FrameInput) MatchInput {
    return .{ .players = .{ p1, p2 } };
}

fn expectMatchesEqual(expected: *const Match, actual: *const Match) !void {
    try std.testing.expectEqualDeep(expected.*, actual.*);
}

fn expectWinner(outcome: ?MatchOutcome, winner: PlayerIndex) !void {
    const actual = outcome orelse {
        try std.testing.expect(false);
        return;
    };
    switch (actual) {
        .winner => |actual_winner| try std.testing.expectEqual(winner, actual_winner),
        .draw => try std.testing.expect(false),
    }
}

fn expectDraw(outcome: ?MatchOutcome) !void {
    const actual = outcome orelse {
        try std.testing.expect(false);
        return;
    };
    switch (actual) {
        .winner => try std.testing.expect(false),
        .draw => {},
    }
}

fn prepareHiddenTopOutLock(player_runtime: *PlayerRuntime) void {
    const active_piece = rules.ActivePiece{
        .kind = .o,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = rules.HiddenRowsI - 2 },
    };
    player_runtime.game.active = active_piece;

    // Support the O piece exactly below the hidden/visible boundary so a hard
    // drop locks it in hidden rows and tops out immediately.
    player_runtime.game.board[rules.HiddenRows][4] = .i;
    player_runtime.game.board[rules.HiddenRows][5] = .i;
}

test "gravity counter reports due frame and resets" {
    var counter: u16 = 0;
    try std.testing.expect(!advanceGravityCounter(&counter, 3));
    try std.testing.expectEqual(@as(u16, 1), counter);
    try std.testing.expect(!advanceGravityCounter(&counter, 3));
    try std.testing.expectEqual(@as(u16, 2), counter);
    try std.testing.expect(advanceGravityCounter(&counter, 3));
    try std.testing.expectEqual(@as(u16, 0), counter);
    try std.testing.expect(advanceGravityCounter(&counter, 1));
    try std.testing.expectEqual(@as(u16, 0), counter);
}

test "same seeds and inputs produce same deterministic runtime state" {
    var left = Match.init(testSettings());
    var right = Match.init(testSettings());

    const sequence = [_]MatchInput{
        testInput(.{ .left_down = true, .left_pressed = true }, .{}),
        testInput(.{ .left_down = true }, .{ .right_down = true, .right_pressed = true }),
        testInput(.{ .hard_drop_pressed = true }, .{}),
        testInput(.{}, .{ .hard_drop_pressed = true }),
        testInput(.{ .down_down = true }, .{ .down_down = true }),
    };

    for (sequence) |frame| {
        const left_result = left.step(frame);
        const right_result = right.step(frame);
        try std.testing.expectEqualDeep(left_result, right_result);
    }
    try expectMatchesEqual(&left, &right);
}

test "one player's hard drop does not mutate the other player's board" {
    var match = Match.init(testSettings());
    const p2_board_before = match.players[1].game.board;
    const p2_active_before = match.players[1].game.active;
    const p2_next_before = match.players[1].game.next;

    const result = match.step(testInput(.{ .hard_drop_pressed = true }, .{}));

    try std.testing.expect(result.players[0].lock_result != null);
    try std.testing.expect(result.players[1].lock_result == null);
    try std.testing.expectEqual(@as(u32, 1), match.players[0].game.pieces_locked);
    try std.testing.expectEqual(@as(u32, 0), match.players[1].game.pieces_locked);
    try std.testing.expectEqualDeep(p2_board_before, match.players[1].game.board);
    try std.testing.expectEqualDeep(p2_active_before, match.players[1].game.active);
    try std.testing.expectEqualDeep(p2_next_before, match.players[1].game.next);
}

test "hard drop locks exactly one piece for the acting player" {
    var match = Match.init(testSettings());

    const result = match.step(testInput(.{ .hard_drop_pressed = true }, .{}));

    try std.testing.expect(result.players[0].hard_dropped);
    try std.testing.expect(result.players[0].lock_result != null);
    try std.testing.expect(!result.players[1].hard_dropped);
    try std.testing.expect(result.players[1].lock_result == null);
    try std.testing.expectEqual(@as(u32, 1), match.players[0].game.pieces_locked);
    try std.testing.expectEqual(@as(u32, 0), match.players[1].game.pieces_locked);
}

test "same-frame locks are collected before match-level outcome resolution" {
    var match = Match.init(testSettings());
    prepareHiddenTopOutLock(&match.players[0]);
    prepareHiddenTopOutLock(&match.players[1]);

    const result = match.step(testInput(.{ .hard_drop_pressed = true }, .{ .hard_drop_pressed = true }));

    try std.testing.expect(result.players[0].lock_result != null);
    try std.testing.expect(result.players[1].lock_result != null);
    try std.testing.expect(match.players[0].game.game_over);
    try std.testing.expect(match.players[1].game.game_over);
    try std.testing.expectEqual(@as(u32, 1), match.players[0].game.pieces_locked);
    try std.testing.expectEqual(@as(u32, 1), match.players[1].game.pieces_locked);
    try expectDraw(result.outcome);
}

test "gravity advances independently per player" {
    var match = Match.init(testSettings());
    match.players[0].game.level = rules.MaxLevel;
    match.players[1].game.level = 1;
    const p1_y_before = match.players[0].game.active.?.pos.y;
    const p2_y_before = match.players[1].game.active.?.pos.y;

    const result = match.step(.{});

    try std.testing.expect(result.players[0].gravity_moved);
    try std.testing.expect(!result.players[1].gravity_moved);
    try std.testing.expectEqual(p1_y_before + 1, match.players[0].game.active.?.pos.y);
    try std.testing.expectEqual(p2_y_before, match.players[1].game.active.?.pos.y);
}

test "soft drop suppresses same-frame natural gravity but still steps" {
    var match = Match.init(testSettings());
    match.players[0].game.level = rules.MaxLevel;
    const p1_y_before = match.players[0].game.active.?.pos.y;

    const result = match.step(testInput(.{ .down_down = true }, .{}));

    try std.testing.expect(result.players[0].soft_dropped);
    try std.testing.expect(!result.players[0].gravity_moved);
    try std.testing.expectEqual(p1_y_before + 1, match.players[0].game.active.?.pos.y);
}

test "pause is global and freezes gameplay until unpaused" {
    var match = Match.init(testSettings());

    const pause_result = match.step(testInput(.{ .pause_pressed = true }, .{ .pause_pressed = true }));
    try std.testing.expect(pause_result.pause_toggled);
    try std.testing.expect(match.paused);
    try std.testing.expectEqual(@as(u64, 1), match.input_frame_count);
    try std.testing.expectEqual(@as(u64, 0), match.gameplay_frame_count);

    const ignored_result = match.step(testInput(.{ .hard_drop_pressed = true }, .{}));
    try std.testing.expect(ignored_result.paused);
    try std.testing.expectEqual(@as(u32, 0), match.players[0].game.pieces_locked);
    try std.testing.expectEqual(@as(u64, 2), match.input_frame_count);
    try std.testing.expectEqual(@as(u64, 0), match.gameplay_frame_count);

    const unpause_result = match.step(testInput(.{}, .{ .pause_pressed = true }));
    try std.testing.expect(unpause_result.pause_toggled);
    try std.testing.expect(!match.paused);
    try std.testing.expectEqual(@as(u64, 3), match.input_frame_count);
    try std.testing.expectEqual(@as(u64, 0), match.gameplay_frame_count);
}

test "restart resets both players from initial seeds" {
    var match = Match.init(testSettings());
    _ = match.step(testInput(.{ .hard_drop_pressed = true }, .{ .hard_drop_pressed = true }));
    try std.testing.expectEqual(@as(u32, 1), match.players[0].game.pieces_locked);
    try std.testing.expectEqual(@as(u32, 1), match.players[1].game.pieces_locked);
    try std.testing.expectEqual(@as(u64, 1), match.input_frame_count);
    try std.testing.expectEqual(@as(u64, 1), match.gameplay_frame_count);

    const restart_result = match.step(testInput(.{}, .{ .restart_pressed = true }));
    const fresh = Match.init(testSettings());

    try std.testing.expect(restart_result.restarted);
    try std.testing.expect(!match.paused);
    try std.testing.expectEqual(@as(u64, 0), match.input_frame_count);
    try std.testing.expectEqual(@as(u64, 0), match.gameplay_frame_count);
    try expectMatchesEqual(&fresh, &match);
}

test "match outcome stops gameplay until restart" {
    var match = Match.init(testSettings());
    match.players[0].game.game_over = true;

    const outcome_result = match.step(.{});
    try expectWinner(outcome_result.outcome, .p2);

    const ignored_result = match.step(testInput(.{}, .{ .hard_drop_pressed = true }));
    try expectWinner(ignored_result.outcome, .p2);
    try std.testing.expectEqual(@as(u32, 0), match.players[1].game.pieces_locked);

    const restart_result = match.step(testInput(.{ .restart_pressed = true }, .{}));
    try std.testing.expect(restart_result.restarted);
    try std.testing.expect(match.outcome == null);
}

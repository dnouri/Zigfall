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

    pub fn fromIndex(player_index: usize) PlayerIndex {
        return switch (player_index) {
            0 => .p1,
            1 => .p2,
            else => unreachable,
        };
    }
};

pub const Ruleset = enum {
    modern,
};

pub const RulesetSettings = union(Ruleset) {
    modern: ModernRulesetSettings,
};

pub const DefaultGarbageSeed: u64 = 0x4741_5242_4147_4521;

pub const InvalidGarbageSettings = error{
    InvalidHoleChangeDenominator,
    InvalidHoleChangeNumerator,
    InitialGarbageHoleOutOfBounds,
};

pub const HoleChangeChance = struct {
    numerator: u8 = 1,
    denominator: u8 = 4,

    pub fn never() HoleChangeChance {
        return .{ .numerator = 0, .denominator = 1 };
    }

    pub fn always() HoleChangeChance {
        return .{ .numerator = 1, .denominator = 1 };
    }

    pub fn validate(self: HoleChangeChance) InvalidGarbageSettings!void {
        if (self.denominator == 0) return error.InvalidHoleChangeDenominator;
        if (self.numerator > self.denominator) return error.InvalidHoleChangeNumerator;
    }

    fn shouldChange(self: HoleChangeChance, rng: *GarbageRng) bool {
        self.validate() catch |err| {
            std.debug.panic("invalid HoleChangeChance invariant after settings validation: {}", .{err});
        };
        if (self.numerator == 0) return false;
        if (self.numerator == self.denominator) return true;
        return rng.index(self.denominator) < self.numerator;
    }
};

pub const ModernGarbageSettings = struct {
    hole_change_chance: HoleChangeChance = .{},
    initial_holes: [PlayerCount]?u8 = .{ null, null },

    pub fn validate(self: ModernGarbageSettings) InvalidGarbageSettings!void {
        try self.hole_change_chance.validate();
        for (self.initial_holes) |initial_hole| {
            if (initial_hole) |hole_x| {
                try validateInitialHole(hole_x);
            }
        }
    }
};

pub const ModernRulesetSettings = struct {
    garbage_seed: u64 = DefaultGarbageSeed,
    garbage: ModernGarbageSettings = .{},

    pub fn validate(self: ModernRulesetSettings) InvalidGarbageSettings!void {
        try self.garbage.validate();
    }
};

pub const MatchSettings = struct {
    player_seeds: [PlayerCount]u64,
    ruleset: RulesetSettings = .{ .modern = .{} },

    pub fn validate(self: MatchSettings) InvalidGarbageSettings!void {
        switch (self.ruleset) {
            .modern => |modern| try modern.validate(),
        }
    }
};

const GarbageRng = struct {
    state: u64,

    fn init(seed: u64) GarbageRng {
        return .{ .state = seed };
    }

    fn next(self: *GarbageRng) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    fn index(self: *GarbageRng, upper_bound: usize) usize {
        const bound: u64 = @intCast(upper_bound);
        return @intCast(self.next() % bound);
    }
};

fn validateInitialHole(hole_x: u8) InvalidGarbageSettings!void {
    if (@as(usize, hole_x) >= rules.BoardWidth) return error.InitialGarbageHoleOutOfBounds;
}

pub const GarbageHoleGeneratorSettings = struct {
    seed: u64,
    initial_hole: ?u8 = null,
    change_chance: HoleChangeChance = .{},

    pub fn validate(self: GarbageHoleGeneratorSettings) InvalidGarbageSettings!void {
        try self.change_chance.validate();
        if (self.initial_hole) |hole_x| {
            try validateInitialHole(hole_x);
        }
    }
};

pub const GarbageHoleGenerator = struct {
    rng: GarbageRng,
    current_hole: rules.GarbageHole,
    change_chance: HoleChangeChance,

    pub fn init(settings: GarbageHoleGeneratorSettings) InvalidGarbageSettings!GarbageHoleGenerator {
        try settings.validate();
        return initValidated(settings);
    }

    fn initValidated(settings: GarbageHoleGeneratorSettings) GarbageHoleGenerator {
        var rng = GarbageRng.init(settings.seed);
        const initial_hole = if (settings.initial_hole) |hole_x|
            rules.GarbageHole.init(hole_x) catch unreachable
        else
            rules.GarbageHole.fromValidIndex(rng.index(rules.BoardWidth));
        return .{
            .rng = rng,
            .current_hole = initial_hole,
            .change_chance = settings.change_chance,
        };
    }

    pub fn current(self: *const GarbageHoleGenerator) rules.GarbageHole {
        return self.current_hole;
    }

    /// Return the current hole for this line, then maybe move the streak to a
    /// different column for the next inserted line.
    pub fn next(self: *GarbageHoleGenerator) rules.GarbageHole {
        const hole = self.current_hole;
        if (self.change_chance.shouldChange(&self.rng)) {
            const offset = self.rng.index(rules.BoardWidth - 1) + 1;
            self.current_hole = rules.GarbageHole.fromValidIndex((hole.index() + offset) % rules.BoardWidth);
        }
        return hole;
    }
};

fn defaultGarbageHoleGenerator() GarbageHoleGenerator {
    return .{
        .rng = GarbageRng.init(0),
        .current_hole = rules.GarbageHole.fromValidIndex(0),
        .change_chance = .{},
    };
}

pub const MatchInput = struct {
    players: [PlayerCount]controls.FrameInput = .{ .{}, .{} },
};

/// Pending garbage queues saturate at this value instead of wrapping. Normal
/// gameplay attacks are tiny; this cap is only a corruption/abuse guard.
pub const MaxPendingGarbage: u32 = std.math.maxInt(u32);

/// A non-clearing lock inserts at most one board worth of pending garbage in a
/// frame. Additional pending lines are consumed and force top-out.
pub const MaxPendingGarbageInsertionsPerLock: u32 = @intCast(rules.BoardHeight);

pub const PlayerGarbageStepResult = struct {
    /// Attack lines generated by this player's lock this frame.
    generated: u32 = 0,
    /// Generated lines spent canceling this player's pre-existing pending queue.
    canceled: u32 = 0,
    /// Generated lines accepted into the opponent pending queue during this
    /// frame's queue phase. Same-frame non-clearing locks may immediately
    /// insert these lines, so the opponent's final pending count can be lower.
    /// This can be lower than generated-minus-canceled only when the abuse
    /// guard saturates an already-near-maximum queue.
    queued: u32 = 0,
    /// Pending incoming lines inserted into this player's board this frame.
    inserted: u32 = 0,
};

pub const PlayerStepResult = struct {
    lock_result: ?rules.LockResult = null,
    hard_dropped: bool = false,
    soft_dropped: bool = false,
    gravity_moved: bool = false,
    garbage: PlayerGarbageStepResult = .{},
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
    /// Incoming garbage waiting for the next non-clearing lock. Match queueing
    /// uses saturating arithmetic at MaxPendingGarbage.
    pending_garbage: u32 = 0,
    garbage_holes: GarbageHoleGenerator,

    pub fn init(seed: u64) PlayerRuntime {
        return initWithGarbage(seed, defaultGarbageHoleGenerator());
    }

    fn initWithGarbage(seed: u64, garbage_holes: GarbageHoleGenerator) PlayerRuntime {
        return .{
            .game = rules.Game.init(seed),
            .garbage_holes = garbage_holes,
        };
    }

    pub fn alive(self: *const PlayerRuntime) bool {
        return !self.game.game_over;
    }

    pub fn pendingGarbageCount(self: *const PlayerRuntime) u32 {
        return self.pending_garbage;
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

    pub fn init(settings: MatchSettings) InvalidGarbageSettings!Match {
        try settings.validate();
        return initValidated(settings);
    }

    fn initValidated(settings: MatchSettings) Match {
        return .{
            .settings = settings,
            .players = .{
                initPlayerRuntimeValidated(settings, 0),
                initPlayerRuntimeValidated(settings, 1),
            },
        };
    }

    fn initPlayerRuntimeValidated(settings: MatchSettings, player_index: usize) PlayerRuntime {
        const player_seed = settings.player_seeds[player_index];
        return switch (settings.ruleset) {
            .modern => |modern| PlayerRuntime.initWithGarbage(player_seed, GarbageHoleGenerator.initValidated(.{
                .seed = garbageSeedForPlayer(modern.garbage_seed, player_index),
                .initial_hole = modern.garbage.initial_holes[player_index],
                .change_chance = modern.garbage.hole_change_chance,
            })),
        };
    }

    pub fn player(self: *Match, index: PlayerIndex) *PlayerRuntime {
        return &self.players[index.index()];
    }

    pub fn playerConst(self: *const Match, index: PlayerIndex) *const PlayerRuntime {
        return &self.players[index.index()];
    }

    pub fn restart(self: *Match) void {
        self.settings.validate() catch |err| {
            std.debug.panic("invalid Match.settings invariant after Match.init: {}", .{err});
        };
        self.* = Match.initValidated(self.settings);
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

        // Step players sequentially, but keep the contract simultaneous: all
        // lock results are collected before Modern garbage or outcome effects.
        inline for (0..PlayerCount) |i| {
            result.players[i] = self.stepPlayer(i, match_input.players[i]);
        }

        self.resolveLockEffects(&result);
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

    fn resolveLockEffects(self: *Match, result: *MatchStepResult) void {
        switch (self.settings.ruleset) {
            .modern => self.resolveModernGarbage(result),
        }
    }

    fn resolveModernGarbage(self: *Match, result: *MatchStepResult) void {
        var attack_lines_by_attacker = [_]u32{0} ** PlayerCount;
        var incoming_lines_by_recipient = [_]u32{0} ** PlayerCount;

        // Option B phase order:
        // - snapshot generated attacks before mutating pending queues;
        // - cancel only each attacker's pre-existing pending garbage;
        // - queue remainders for recipients before non-clearing insertion.
        // Same-frame remainders can insert immediately but cannot cross-cancel.
        for (0..PlayerCount) |attacker_index| {
            const lock_result = result.players[attacker_index].lock_result orelse continue;
            const attack_lines = @as(u32, lock_result.attack_lines);
            attack_lines_by_attacker[attacker_index] = attack_lines;
            result.players[attacker_index].garbage.generated = attack_lines;
        }

        for (0..PlayerCount) |attacker_index| {
            const attack_lines = attack_lines_by_attacker[attacker_index];
            if (attack_lines == 0) continue;

            const canceled = @min(attack_lines, self.players[attacker_index].pending_garbage);
            self.players[attacker_index].pending_garbage -= canceled;
            result.players[attacker_index].garbage.canceled = canceled;

            const remainder = attack_lines - canceled;
            const recipient_index = opponentIndex(attacker_index);
            incoming_lines_by_recipient[recipient_index] = saturatingAddU32(incoming_lines_by_recipient[recipient_index], remainder);
        }

        // Queue by recipient so same-frame insertion sees accepted attacks, but
        // report the queued event on the attacker who generated the lines.
        for (0..PlayerCount) |recipient_index| {
            const incoming_lines = incoming_lines_by_recipient[recipient_index];
            const accepted = self.queuePendingGarbageForPlayer(recipient_index, incoming_lines);
            const attacker_index = opponentIndex(recipient_index);
            result.players[attacker_index].garbage.queued = accepted;
        }

        for (0..PlayerCount) |player_index| {
            const lock_result = result.players[player_index].lock_result orelse continue;
            if (lock_result.lines_cleared == 0) {
                result.players[player_index].garbage.inserted = self.insertPendingGarbageForPlayer(player_index);
            }
        }
    }

    fn queuePendingGarbageForPlayer(self: *Match, player_index: usize, lines: u32) u32 {
        if (lines == 0) return 0;

        const pending = &self.players[player_index].pending_garbage;
        const accepted = @min(lines, MaxPendingGarbage - pending.*);
        pending.* += accepted;
        return accepted;
    }

    fn insertPendingGarbageForPlayer(self: *Match, player_index: usize) u32 {
        var player_runtime = &self.players[player_index];
        if (player_runtime.pending_garbage == 0 or player_runtime.game.game_over) return 0;

        const pending = player_runtime.pending_garbage;
        const lines_to_insert: usize = @intCast(@min(pending, MaxPendingGarbageInsertionsPerLock));
        var holes: [rules.BoardHeight]rules.GarbageHole = undefined;
        for (holes[0..lines_to_insert]) |*hole| {
            hole.* = player_runtime.garbage_holes.next();
        }

        player_runtime.game.insertGarbageLinesAt(holes[0..lines_to_insert]);
        if (pending > MaxPendingGarbageInsertionsPerLock) {
            player_runtime.game.game_over = true;
        }
        player_runtime.pending_garbage = 0;
        return @intCast(lines_to_insert);
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

fn opponentIndex(player_index: usize) usize {
    return PlayerIndex.fromIndex(player_index).opponent().index();
}

fn saturatingAddU32(a: u32, b: u32) u32 {
    if (MaxPendingGarbage - a < b) return MaxPendingGarbage;
    return a + b;
}

fn garbageSeedForPlayer(base_seed: u64, player_index: usize) u64 {
    const index_seed = @as(u64, @intCast(player_index + 1)) *% 0xD1B5_4A32_D192_ED03;
    return base_seed ^ index_seed;
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
    player_runtime.game.board[rules.HiddenRows][4] = rules.Cell.fromPiece(.i);
    player_runtime.game.board[rules.HiddenRows][5] = rules.Cell.fromPiece(.i);
}

fn fakeLockResult(lines_cleared: u8, attack_lines: u8) rules.LockResult {
    return .{
        .piece_kind = .i,
        .lines_cleared = lines_cleared,
        .t_spin_kind = .none,
        .perfect_clear = false,
        .combo_after_lock = if (lines_cleared > 0) 0 else -1,
        .back_to_back_active_after_lock = false,
        .back_to_back_bonus_applied = false,
        .difficult_clear = lines_cleared == 4,
        .base_score_points = 0,
        .back_to_back_bonus_points = 0,
        .combo_bonus_points = 0,
        .perfect_clear_bonus_points = 0,
        .hard_drop_cells = 0,
        .hard_drop_points = 0,
        .soft_drop_points = 0,
        .score_delta = 0,
        .total_score_after_lock = 0,
        .attack_lines = attack_lines,
    };
}

fn forcedHoleSettings(player: PlayerIndex, hole_x: u8, chance: HoleChangeChance) MatchSettings {
    var settings = testSettings();
    switch (settings.ruleset) {
        .modern => |*modern| {
            modern.garbage.hole_change_chance = chance;
            modern.garbage.initial_holes[player.index()] = hole_x;
        },
    }
    return settings;
}

fn fillRowExcept(game: *rules.Game, y: usize, gaps: []const usize, kind: rules.PieceKind) void {
    for (0..rules.BoardWidth) |x| {
        var is_gap = false;
        for (gaps) |gap| {
            if (x == gap) {
                is_gap = true;
                break;
            }
        }
        game.board[y][x] = if (is_gap) null else rules.Cell.fromPiece(kind);
    }
}

fn prepareQuad(player_runtime: *PlayerRuntime) void {
    player_runtime.game.board[0][0] = rules.Cell.fromPiece(.i);
    for (36..40) |y| fillRowExcept(&player_runtime.game, y, &.{4}, .j);
    player_runtime.game.active = .{
        .kind = .i,
        .rotation = .right,
        .pos = .{ .x = 2, .y = 36 },
    };
}

fn prepareHiddenQuadTopOut(player_runtime: *PlayerRuntime) void {
    for ((rules.HiddenRows - 4)..rules.HiddenRows) |y| {
        fillRowExcept(&player_runtime.game, y, &.{4}, .j);
    }
    player_runtime.game.board[rules.HiddenRows][4] = rules.Cell.fromPiece(.i);
    player_runtime.game.active = .{
        .kind = .i,
        .rotation = .right,
        .pos = .{ .x = 2, .y = rules.HiddenRowsI - 4 },
    };
}

fn expectGarbageHoleRow(game: *const rules.Game, y: usize, hole_x: usize) !void {
    for (0..rules.BoardWidth) |x| {
        const cell = game.board[y][x];
        if (x == hole_x) {
            try std.testing.expect(cell == null);
        } else {
            try std.testing.expect(cell != null);
            try std.testing.expect(cell.?.isGarbage());
        }
    }
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

test "Modern ruleset settings exist and default hole change chance is one in four" {
    const settings = testSettings();
    switch (settings.ruleset) {
        .modern => |modern| {
            try std.testing.expectEqual(@as(u8, 1), modern.garbage.hole_change_chance.numerator);
            try std.testing.expectEqual(@as(u8, 4), modern.garbage.hole_change_chance.denominator);
        },
    }
}

test "public garbage settings reject invalid chance and initial holes" {
    var zero_denominator = testSettings();
    switch (zero_denominator.ruleset) {
        .modern => |*modern| modern.garbage.hole_change_chance.denominator = 0,
    }
    try std.testing.expectError(error.InvalidHoleChangeDenominator, zero_denominator.validate());
    try std.testing.expectError(error.InvalidHoleChangeDenominator, Match.init(zero_denominator));

    var oversized_numerator = testSettings();
    switch (oversized_numerator.ruleset) {
        .modern => |*modern| modern.garbage.hole_change_chance = .{ .numerator = 5, .denominator = 4 },
    }
    try std.testing.expectError(error.InvalidHoleChangeNumerator, oversized_numerator.validate());
    try std.testing.expectError(error.InvalidHoleChangeNumerator, Match.init(oversized_numerator));

    var bad_hole = testSettings();
    switch (bad_hole.ruleset) {
        .modern => |*modern| modern.garbage.initial_holes[0] = @as(u8, @intCast(rules.BoardWidth)),
    }
    try std.testing.expectError(error.InitialGarbageHoleOutOfBounds, bad_hole.validate());
    try std.testing.expectError(error.InitialGarbageHoleOutOfBounds, Match.init(bad_hole));
}

test "garbage hole generator rejects invalid settings" {
    try std.testing.expectError(error.InvalidHoleChangeDenominator, GarbageHoleGenerator.init(.{
        .seed = 0,
        .change_chance = .{ .numerator = 0, .denominator = 0 },
    }));
    try std.testing.expectError(error.InvalidHoleChangeNumerator, GarbageHoleGenerator.init(.{
        .seed = 0,
        .change_chance = .{ .numerator = 2, .denominator = 1 },
    }));
    try std.testing.expectError(error.InitialGarbageHoleOutOfBounds, GarbageHoleGenerator.init(.{
        .seed = 0,
        .initial_hole = @as(u8, @intCast(rules.BoardWidth)),
    }));
}

test "quad sends exactly four pending garbage lines under Modern" {
    var match = try Match.init(testSettings());
    prepareQuad(&match.players[0]);

    const result = match.step(testInput(.{ .hard_drop_pressed = true }, .{}));

    const lock_result = result.players[0].lock_result.?;
    try std.testing.expectEqual(@as(u8, 4), lock_result.lines_cleared);
    try std.testing.expectEqual(@as(u8, 4), lock_result.attack_lines);
    try std.testing.expectEqual(@as(u32, 4), result.players[0].garbage.generated);
    try std.testing.expectEqual(@as(u32, 0), result.players[0].garbage.canceled);
    try std.testing.expectEqual(@as(u32, 4), result.players[0].garbage.queued);
    try std.testing.expectEqual(@as(u32, 0), match.players[0].pendingGarbageCount());
    try std.testing.expectEqual(@as(u32, 4), match.players[1].pendingGarbageCount());
}

test "Modern attack cancellation consumes attacker's pending garbage before queueing remainder" {
    var match = try Match.init(testSettings());
    match.players[0].pending_garbage = 3;

    var result = MatchStepResult{};
    result.players[0].lock_result = fakeLockResult(4, 5);
    match.resolveLockEffects(&result);

    try std.testing.expectEqual(@as(u32, 5), result.players[0].garbage.generated);
    try std.testing.expectEqual(@as(u32, 3), result.players[0].garbage.canceled);
    try std.testing.expectEqual(@as(u32, 2), result.players[0].garbage.queued);
    try std.testing.expectEqual(@as(u32, 0), match.players[0].pendingGarbageCount());
    try std.testing.expectEqual(@as(u32, 2), match.players[1].pendingGarbageCount());
}

test "Modern same-frame attacks do not cross-cancel or depend on player order" {
    var match = try Match.init(testSettings());
    match.players[0].pending_garbage = 2;
    match.players[1].pending_garbage = 1;

    var result = MatchStepResult{};
    result.players[0].lock_result = fakeLockResult(4, 4);
    result.players[1].lock_result = fakeLockResult(4, 4);
    match.resolveLockEffects(&result);

    try std.testing.expectEqual(@as(u32, 2), result.players[0].garbage.canceled);
    try std.testing.expectEqual(@as(u32, 2), result.players[0].garbage.queued);
    try std.testing.expectEqual(@as(u32, 1), result.players[1].garbage.canceled);
    try std.testing.expectEqual(@as(u32, 3), result.players[1].garbage.queued);
    try std.testing.expectEqual(@as(u32, 3), match.players[0].pendingGarbageCount());
    try std.testing.expectEqual(@as(u32, 2), match.players[1].pendingGarbageCount());
}

test "Modern garbage queue saturates instead of overflowing" {
    var match = try Match.init(testSettings());
    match.players[1].pending_garbage = MaxPendingGarbage - 2;

    var result = MatchStepResult{};
    result.players[0].lock_result = fakeLockResult(4, 4);
    match.resolveLockEffects(&result);

    try std.testing.expectEqual(@as(u32, 4), result.players[0].garbage.generated);
    try std.testing.expectEqual(@as(u32, 0), result.players[0].garbage.canceled);
    try std.testing.expectEqual(@as(u32, 2), result.players[0].garbage.queued);
    try std.testing.expectEqual(MaxPendingGarbage, match.players[1].pendingGarbageCount());
}

test "Modern non-clearing lock inserts queued garbage and clears pending queue" {
    var match = try Match.init(forcedHoleSettings(.p1, 3, HoleChangeChance.never()));
    match.players[0].pending_garbage = 2;

    var result = MatchStepResult{};
    result.players[0].lock_result = fakeLockResult(0, 0);
    match.resolveLockEffects(&result);

    try std.testing.expectEqual(@as(u32, 2), result.players[0].garbage.inserted);
    try std.testing.expectEqual(@as(u32, 0), match.players[0].pendingGarbageCount());
    try expectGarbageHoleRow(&match.players[0].game, rules.BoardHeight - 2, 3);
    try expectGarbageHoleRow(&match.players[0].game, rules.BoardHeight - 1, 3);
}

test "Modern clearing lock delays queued garbage" {
    var match = try Match.init(forcedHoleSettings(.p1, 3, HoleChangeChance.never()));
    match.players[0].pending_garbage = 2;

    var result = MatchStepResult{};
    result.players[0].lock_result = fakeLockResult(1, 0);
    match.resolveLockEffects(&result);

    try std.testing.expectEqual(@as(u32, 0), result.players[0].garbage.inserted);
    try std.testing.expectEqual(@as(u32, 2), match.players[0].pendingGarbageCount());
    try std.testing.expect(match.players[0].game.board[rules.BoardHeight - 1][0] == null);
}

test "Modern huge pending garbage is bounded to one board and tops out" {
    var match = try Match.init(forcedHoleSettings(.p1, 4, HoleChangeChance.never()));
    const active_piece = rules.ActivePiece{
        .kind = .i,
        .rotation = .right,
        .pos = .{ .x = 2, .y = rules.HiddenRowsI },
    };
    match.players[0].game.active = active_piece;
    match.players[0].pending_garbage = MaxPendingGarbage;

    var result = MatchStepResult{};
    result.players[0].lock_result = fakeLockResult(0, 0);
    match.resolveLockEffects(&result);

    try std.testing.expectEqual(MaxPendingGarbageInsertionsPerLock, result.players[0].garbage.inserted);
    try std.testing.expectEqual(@as(u32, 0), match.players[0].pendingGarbageCount());
    try std.testing.expect(!match.players[0].game.collides(active_piece));
    try std.testing.expect(match.players[0].game.game_over);
}

test "garbage hole generator is deterministic and streaky with forced settings" {
    var never = try GarbageHoleGenerator.init(.{
        .seed = 0x1234,
        .initial_hole = 6,
        .change_chance = HoleChangeChance.never(),
    });
    for (0..5) |_| {
        try std.testing.expectEqual(@as(usize, 6), never.next().index());
    }

    var left = try GarbageHoleGenerator.init(.{
        .seed = 0xCAFE,
        .initial_hole = 4,
        .change_chance = HoleChangeChance.always(),
    });
    var right = try GarbageHoleGenerator.init(.{
        .seed = 0xCAFE,
        .initial_hole = 4,
        .change_chance = HoleChangeChance.always(),
    });
    var previous: ?usize = null;
    for (0..8) |_| {
        const a = left.next().index();
        const b = right.next().index();
        try std.testing.expectEqual(a, b);
        if (previous) |prev| try std.testing.expect(a != prev);
        previous = a;
    }
}

test "Modern garbage top-out ends affected player and reports outcome" {
    var match = try Match.init(forcedHoleSettings(.p1, 0, HoleChangeChance.never()));
    match.players[0].pending_garbage = 1;
    match.players[0].game.board[0][1] = rules.Cell.fromPiece(.s);

    const result = match.step(testInput(.{ .hard_drop_pressed = true }, .{}));

    try std.testing.expectEqual(@as(u8, 0), result.players[0].lock_result.?.lines_cleared);
    try std.testing.expectEqual(@as(u32, 1), result.players[0].garbage.inserted);
    try std.testing.expect(match.players[0].game.game_over);
    try expectWinner(result.outcome, .p2);
}

test "Modern resolver passes through constructed high attack_lines without special casing" {
    var match = try Match.init(testSettings());

    var result = MatchStepResult{};
    result.players[0].lock_result = fakeLockResult(2, 17);
    match.resolveLockEffects(&result);

    try std.testing.expectEqual(@as(u32, 17), result.players[0].garbage.generated);
    try std.testing.expectEqual(@as(u32, 17), result.players[0].garbage.queued);
    try std.testing.expectEqual(@as(u32, 17), match.players[1].pendingGarbageCount());
}

test "attack from a top-out lock still participates before outcome" {
    var match = try Match.init(testSettings());
    match.players[0].game.game_over = true;

    var result = MatchStepResult{};
    result.players[0].lock_result = fakeLockResult(4, 4);
    match.resolveLockEffects(&result);
    match.updateOutcome();
    result.outcome = match.outcome;

    try std.testing.expectEqual(@as(u32, 4), result.players[0].garbage.generated);
    try std.testing.expectEqual(@as(u32, 4), result.players[0].garbage.queued);
    try std.testing.expectEqual(@as(u32, 4), match.players[1].pendingGarbageCount());
    try expectWinner(result.outcome, .p2);
}

test "real top-out quad sends attack before outcome" {
    var match = try Match.init(testSettings());
    prepareHiddenQuadTopOut(&match.players[0]);

    const result = match.step(testInput(.{ .hard_drop_pressed = true }, .{}));

    try std.testing.expect(match.players[0].game.game_over);
    try std.testing.expectEqual(@as(u8, 4), result.players[0].lock_result.?.lines_cleared);
    try std.testing.expectEqual(@as(u8, 4), result.players[0].lock_result.?.attack_lines);
    try std.testing.expectEqual(@as(u32, 4), result.players[0].garbage.generated);
    try std.testing.expectEqual(@as(u32, 4), result.players[0].garbage.queued);
    try std.testing.expectEqual(@as(u32, 4), match.players[1].pendingGarbageCount());
    try expectWinner(result.outcome, .p2);
}

test "top-out quad queues before same-frame opponent non-clear inserts garbage" {
    var match = try Match.init(testSettings());
    prepareHiddenQuadTopOut(&match.players[0]);
    // Keep P2 seed-independent: this O hard-drop clears nothing, while the
    // row-0 sentinel makes accepted garbage top out during insertion.
    match.players[1].game.active = .{
        .kind = .o,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = rules.HiddenRowsI - 2 },
    };
    match.players[1].game.board[0][1] = rules.Cell.fromPiece(.s);

    const result = match.step(testInput(.{ .hard_drop_pressed = true }, .{ .hard_drop_pressed = true }));

    try std.testing.expect(match.players[0].game.game_over);
    try std.testing.expect(match.players[1].game.game_over);
    try std.testing.expectEqual(@as(u8, 4), result.players[0].lock_result.?.lines_cleared);
    try std.testing.expectEqual(@as(u8, 4), result.players[0].lock_result.?.attack_lines);
    try std.testing.expect(result.players[1].lock_result != null);
    try std.testing.expectEqual(@as(u8, 0), result.players[1].lock_result.?.lines_cleared);
    try std.testing.expectEqual(@as(u8, 0), result.players[1].lock_result.?.attack_lines);
    try std.testing.expectEqual(@as(u32, 4), result.players[0].garbage.generated);
    try std.testing.expectEqual(@as(u32, 4), result.players[0].garbage.queued);
    try std.testing.expectEqual(@as(u32, 4), result.players[1].garbage.inserted);
    try std.testing.expectEqual(@as(u32, 0), match.players[1].pendingGarbageCount());
    try expectDraw(result.outcome);
}

test "same seeds and inputs produce same deterministic runtime state" {
    var left = try Match.init(testSettings());
    var right = try Match.init(testSettings());

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
    var match = try Match.init(testSettings());
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
    var match = try Match.init(testSettings());

    const result = match.step(testInput(.{ .hard_drop_pressed = true }, .{}));

    try std.testing.expect(result.players[0].hard_dropped);
    try std.testing.expect(result.players[0].lock_result != null);
    try std.testing.expect(!result.players[1].hard_dropped);
    try std.testing.expect(result.players[1].lock_result == null);
    try std.testing.expectEqual(@as(u32, 1), match.players[0].game.pieces_locked);
    try std.testing.expectEqual(@as(u32, 0), match.players[1].game.pieces_locked);
}

test "same-frame locks are collected before match-level outcome resolution" {
    var match = try Match.init(testSettings());
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
    var match = try Match.init(testSettings());
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
    var match = try Match.init(testSettings());
    match.players[0].game.level = rules.MaxLevel;
    const p1_y_before = match.players[0].game.active.?.pos.y;

    const result = match.step(testInput(.{ .down_down = true }, .{}));

    try std.testing.expect(result.players[0].soft_dropped);
    try std.testing.expect(!result.players[0].gravity_moved);
    try std.testing.expectEqual(p1_y_before + 1, match.players[0].game.active.?.pos.y);
}

test "pause is global and freezes gameplay until unpaused" {
    var match = try Match.init(testSettings());

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
    var match = try Match.init(testSettings());
    _ = match.step(testInput(.{ .hard_drop_pressed = true }, .{ .hard_drop_pressed = true }));
    try std.testing.expectEqual(@as(u32, 1), match.players[0].game.pieces_locked);
    try std.testing.expectEqual(@as(u32, 1), match.players[1].game.pieces_locked);
    try std.testing.expectEqual(@as(u64, 1), match.input_frame_count);
    try std.testing.expectEqual(@as(u64, 1), match.gameplay_frame_count);

    const restart_result = match.step(testInput(.{}, .{ .restart_pressed = true }));
    const fresh = try Match.init(testSettings());

    try std.testing.expect(restart_result.restarted);
    try std.testing.expect(!match.paused);
    try std.testing.expectEqual(@as(u64, 0), match.input_frame_count);
    try std.testing.expectEqual(@as(u64, 0), match.gameplay_frame_count);
    try expectMatchesEqual(&fresh, &match);
}

test "match outcome stops gameplay until restart" {
    var match = try Match.init(testSettings());
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

// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

pub const DeterministicHash = @import("state_hash.zig");
const state_hash = DeterministicHash;

pub const BoardWidth: usize = 10;
pub const BoardHeight: usize = 40;
pub const VisibleHeight: usize = 20;
pub const HiddenRows: usize = BoardHeight - VisibleHeight;

pub const BoardWidthI: i32 = 10;
pub const BoardHeightI: i32 = 40;
pub const HiddenRowsI: i32 = 20;

pub const NextQueueLength: usize = 5;
pub const PieceCount: usize = 7;

pub const DefaultLockDelayFrames: u16 = 30;
pub const DefaultMaxLockMoveResets: u8 = 15;
pub const MaxLevel: u8 = 15;

const GravityFramesByLevel = [_]u16{ 48, 43, 38, 33, 28, 23, 18, 13, 8, 6, 5, 4, 3, 2, 1 };

pub const PieceKind = enum(u3) {
    i,
    o,
    t,
    s,
    z,
    j,
    l,
};

pub const Cell = union(enum) {
    piece: PieceKind,
    garbage,

    pub fn fromPiece(kind: PieceKind) Cell {
        return .{ .piece = kind };
    }

    pub fn pieceKind(self: Cell) ?PieceKind {
        return switch (self) {
            .piece => |kind| kind,
            .garbage => null,
        };
    }

    pub fn isGarbage(self: Cell) bool {
        return switch (self) {
            .piece => false,
            .garbage => true,
        };
    }
};

pub const Rotation = enum(u2) {
    spawn = 0,
    right = 1,
    reverse = 2,
    left = 3,
};

pub const RotationDirection = enum {
    clockwise,
    counter_clockwise,
    half_turn,
};

pub const TSpinKind = enum {
    none,
    mini,
    full,
};

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const ActivePiece = struct {
    kind: PieceKind,
    rotation: Rotation,
    pos: Point,
};

pub const LockResult = struct {
    piece_kind: PieceKind,
    lines_cleared: u8,
    t_spin_kind: TSpinKind,
    perfect_clear: bool,
    combo_after_lock: i32,
    back_to_back_active_after_lock: bool,
    back_to_back_bonus_applied: bool,
    difficult_clear: bool,
    base_score_points: u32,
    back_to_back_bonus_points: u32,
    combo_bonus_points: u32,
    perfect_clear_bonus_points: u32,
    hard_drop_cells: u32,
    hard_drop_points: u32,
    soft_drop_points: u32,
    score_delta: u32,
    total_score_after_lock: u32,
    attack_lines: u8,
};

pub const StepOptions = struct {
    apply_gravity: bool = false,
};

pub const StepResult = struct {
    gravity_moved: bool = false,
    lock_result: ?LockResult = null,
};

pub const GarbageInsertError = error{
    HoleOutOfBounds,
};

pub const GarbageHole = enum(u4) {
    c0 = 0,
    c1 = 1,
    c2 = 2,
    c3 = 3,
    c4 = 4,
    c5 = 5,
    c6 = 6,
    c7 = 7,
    c8 = 8,
    c9 = 9,

    pub fn init(hole_x: u8) GarbageInsertError!GarbageHole {
        if (@as(usize, hole_x) >= BoardWidth) return error.HoleOutOfBounds;
        return fromValidIndex(@as(usize, hole_x));
    }

    pub fn fromValidIndex(hole_x: usize) GarbageHole {
        std.debug.assert(hole_x < BoardWidth);
        return switch (hole_x) {
            0 => .c0,
            1 => .c1,
            2 => .c2,
            3 => .c3,
            4 => .c4,
            5 => .c5,
            6 => .c6,
            7 => .c7,
            8 => .c8,
            9 => .c9,
            else => unreachable,
        };
    }

    pub fn index(self: GarbageHole) usize {
        return @as(usize, @intFromEnum(self));
    }
};

comptime {
    if (BoardWidth != 10) @compileError("GarbageHole enum must be updated when BoardWidth changes");
}

pub const Board = [BoardHeight][BoardWidth]?Cell;

pub const all_piece_kinds = [_]PieceKind{ .i, .o, .t, .s, .z, .j, .l };

const LastPieceAction = enum {
    none,
    move,
    rotate,
};

const RotationEvent = struct {
    piece_kind: PieceKind,
    from: Rotation,
    to: Rotation,
    direction: RotationDirection,
    kick_index: u8,
    kick: Point,
};

const KickTests = struct {
    kicks: [5]Point,
    len: usize,
};

pub const SevenBag = struct {
    rng: BagRng,
    bag: [PieceCount]PieceKind,
    index: usize,

    pub fn init(seed: u64) SevenBag {
        var self = SevenBag{
            .rng = BagRng.init(seed),
            .bag = undefined,
            .index = PieceCount,
        };
        self.refill();
        return self;
    }

    pub fn next(self: *SevenBag) PieceKind {
        if (self.index >= PieceCount) {
            self.refill();
        }
        const piece = self.bag[self.index];
        self.index += 1;
        return piece;
    }

    fn refill(self: *SevenBag) void {
        self.bag = all_piece_kinds;
        var i: usize = PieceCount - 1;
        while (i > 0) : (i -= 1) {
            const j = self.rng.index(i + 1);
            const tmp = self.bag[i];
            self.bag[i] = self.bag[j];
            self.bag[j] = tmp;
        }
        self.index = 0;
    }
};

const BagRng = struct {
    state: u64,

    fn init(seed: u64) BagRng {
        return .{ .state = seed };
    }

    fn next(self: *BagRng) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    fn index(self: *BagRng, upper_bound: usize) usize {
        const bound: u64 = @intCast(upper_bound);
        return @intCast(self.next() % bound);
    }
};

pub const Game = struct {
    board: Board,
    randomizer: SevenBag,
    next: [NextQueueLength]PieceKind,
    hold: ?PieceKind,
    held_this_piece: bool,
    active: ?ActivePiece,
    game_over: bool,
    total_lines_cleared: u32,
    pieces_locked: u32,

    score: u32,
    level: u8,
    combo_counter: i32,
    back_to_back_active: bool,
    last_lock_result: ?LockResult,

    lock_delay_frames: u16,
    max_lock_move_resets: u8,
    lock_delay_elapsed: u16,
    lock_move_resets_used: u8,

    soft_drop_points_pending: u32,
    last_piece_action: LastPieceAction,
    last_successful_rotation: ?RotationEvent,

    pub fn init(seed: u64) Game {
        var self = Game.initNoSpawn(seed);
        _ = self.spawnNext();
        return self;
    }

    pub fn initNoSpawn(seed: u64) Game {
        var self = Game{
            .board = emptyBoard(),
            .randomizer = SevenBag.init(seed),
            .next = undefined,
            .hold = null,
            .held_this_piece = false,
            .active = null,
            .game_over = false,
            .total_lines_cleared = 0,
            .pieces_locked = 0,
            .score = 0,
            .level = levelForLines(0),
            .combo_counter = -1,
            .back_to_back_active = false,
            .last_lock_result = null,
            .lock_delay_frames = DefaultLockDelayFrames,
            .max_lock_move_resets = DefaultMaxLockMoveResets,
            .lock_delay_elapsed = 0,
            .lock_move_resets_used = 0,
            .soft_drop_points_pending = 0,
            .last_piece_action = .none,
            .last_successful_rotation = null,
        };
        for (&self.next) |*slot| {
            slot.* = self.randomizer.next();
        }
        return self;
    }

    pub fn spawnNext(self: *Game) bool {
        if (self.game_over) return false;
        const kind = self.popNext();
        return self.spawnKind(kind, false);
    }

    pub fn holdPiece(self: *Game) bool {
        if (self.game_over or self.held_this_piece) return false;
        const current_piece = self.active orelse return false;
        const current_kind = current_piece.kind;

        if (self.hold) |held_kind| {
            self.hold = current_kind;
            return self.spawnKind(held_kind, true);
        }

        self.hold = current_kind;
        return self.spawnKind(self.popNext(), true);
    }

    pub fn tryMove(self: *Game, dx: i32, dy: i32) bool {
        return self.moveActive(dx, dy, .move, false);
    }

    pub fn softDropOne(self: *Game) bool {
        return self.moveActive(0, 1, .move, true);
    }

    pub fn softDropCells(self: *Game, requested_cells: u32) u32 {
        var moved: u32 = 0;
        while (moved < requested_cells and self.softDropOne()) {
            moved += 1;
        }
        return moved;
    }

    pub fn tryRotate(self: *Game, direction: RotationDirection) bool {
        if (self.game_over) return false;
        const current = self.active orelse return false;
        const next_rotation = turned(current.rotation, direction);
        const kicks = kickTestsFor(current.kind, current.rotation, next_rotation, direction);

        var index: usize = 0;
        while (index < kicks.len) : (index += 1) {
            const kick = kicks.kicks[index];
            const candidate = ActivePiece{
                .kind = current.kind,
                .rotation = next_rotation,
                .pos = .{
                    .x = current.pos.x + kick.x,
                    .y = current.pos.y + kick.y,
                },
            };
            if (!self.collides(candidate)) {
                self.active = candidate;
                self.last_piece_action = .rotate;
                self.last_successful_rotation = .{
                    .piece_kind = current.kind,
                    .from = current.rotation,
                    .to = next_rotation,
                    .direction = direction,
                    .kick_index = @intCast(index),
                    .kick = kick,
                };
                self.maybeResetLockDelayAfterPlayerAction();
                return true;
            }
        }
        return false;
    }

    pub fn hardDropAndLock(self: *Game) u32 {
        const result = self.hardDropAndLockDetailed() orelse return 0;
        return result.hard_drop_cells;
    }

    pub fn hardDropAndLockDetailed(self: *Game) ?LockResult {
        const dropped = self.dropActiveToFloor();
        return self.lockActiveDetailedWithDrop(dropped);
    }

    pub fn lockActive(self: *Game) u8 {
        const result = self.lockActiveDetailed() orelse return 0;
        return result.lines_cleared;
    }

    pub fn lockActiveDetailed(self: *Game) ?LockResult {
        return self.lockActiveDetailedWithDrop(0);
    }

    pub fn step(self: *Game, options: StepOptions) StepResult {
        var result = StepResult{};
        if (options.apply_gravity and !self.isActiveGrounded()) {
            result.gravity_moved = self.moveActive(0, 1, .none, false);
        }
        result.lock_result = self.tick();
        return result;
    }

    pub fn tick(self: *Game) ?LockResult {
        if (self.game_over) return null;
        if (self.active == null) return null;

        if (!self.isActiveGrounded()) {
            self.lock_delay_elapsed = 0;
            return null;
        }

        if (self.lock_delay_elapsed < self.lock_delay_frames) {
            self.lock_delay_elapsed += 1;
        }

        if (self.lock_delay_elapsed >= self.lock_delay_frames) {
            return self.lockActiveDetailed();
        }
        return null;
    }

    pub fn clearFullLines(self: *Game) u8 {
        var write_y: usize = BoardHeight;
        var read_y: usize = BoardHeight;
        var cleared: u8 = 0;

        while (read_y > 0) {
            read_y -= 1;
            if (rowFull(&self.board[read_y])) {
                cleared += 1;
            } else {
                write_y -= 1;
                if (write_y != read_y) {
                    self.board[write_y] = self.board[read_y];
                }
            }
        }

        while (write_y > 0) {
            write_y -= 1;
            self.board[write_y] = emptyRow();
        }

        self.total_lines_cleared += @as(u32, cleared);
        return cleared;
    }

    pub fn insertGarbageLine(self: *Game, hole_x: u8) GarbageInsertError!void {
        try self.insertGarbageLines(&.{hole_x});
    }

    /// Insert garbage at the bottom, shifting existing board rows toward y = 0.
    /// Occupied cells shifted out of row 0 top out the game. The active piece is
    /// not moved or cleared; after the full batch is inserted, if the shifted
    /// board overlaps it, `game_over` is set and `active` remains available for
    /// post-frame inspection. Public hole values are validated for the whole
    /// batch before any board mutation, so `HoleOutOfBounds` leaves the game
    /// unchanged.
    pub fn insertGarbageLines(self: *Game, holes: []const u8) GarbageInsertError!void {
        for (holes) |hole_x| {
            _ = try GarbageHole.init(hole_x);
        }
        if (self.game_over or holes.len == 0) return;

        var top_out = false;
        for (holes) |hole_x| {
            self.insertGarbageLineUnchecked(GarbageHole.fromValidIndex(@as(usize, hole_x)), &top_out);
        }

        self.finishGarbageInsertion(top_out);
    }

    /// Infallible insertion for holes that were already validated or generated
    /// by deterministic match state.
    pub fn insertGarbageLineAt(self: *Game, hole: GarbageHole) void {
        self.insertGarbageLinesAt(&.{hole});
    }

    /// Infallible batch insertion for bounded hole values. Like the public
    /// checked wrapper, active-piece collision is evaluated once after the full
    /// batch is inserted.
    pub fn insertGarbageLinesAt(self: *Game, holes: []const GarbageHole) void {
        if (self.game_over or holes.len == 0) return;

        var top_out = false;
        for (holes) |hole| {
            self.insertGarbageLineUnchecked(hole, &top_out);
        }

        self.finishGarbageInsertion(top_out);
    }

    fn insertGarbageLineUnchecked(self: *Game, hole: GarbageHole, top_out: *bool) void {
        if (rowOccupied(&self.board[0])) top_out.* = true;
        var y: usize = 0;
        while (y < BoardHeight - 1) : (y += 1) {
            self.board[y] = self.board[y + 1];
        }
        self.board[BoardHeight - 1] = garbageRow(hole);
    }

    fn finishGarbageInsertion(self: *Game, top_out: bool) void {
        var did_top_out = top_out;
        if (self.active) |piece| {
            if (self.collides(piece)) did_top_out = true;
        }
        if (did_top_out) self.game_over = true;
    }

    pub fn collides(self: *const Game, piece: ActivePiece) bool {
        const blocks = blockPositions(piece);
        for (blocks) |point| {
            if (point.x < 0 or point.x >= BoardWidthI) return true;
            if (point.y < 0 or point.y >= BoardHeightI) return true;

            const x: usize = @intCast(point.x);
            const y: usize = @intCast(point.y);
            if (self.board[y][x] != null) return true;
        }
        return false;
    }

    pub fn isActiveGrounded(self: *const Game) bool {
        const piece = self.active orelse return false;
        var candidate = piece;
        candidate.pos.y += 1;
        return self.collides(candidate);
    }

    pub fn dropDistance(self: *const Game, piece: ActivePiece) u32 {
        if (self.collides(piece)) return 0;

        var probe = piece;
        var distance: u32 = 0;
        while (true) {
            var candidate = probe;
            candidate.pos.y += 1;
            if (self.collides(candidate)) break;
            probe = candidate;
            distance += 1;
        }
        return distance;
    }

    pub fn activeDropDistance(self: *const Game) u32 {
        const piece = self.active orelse return 0;
        return self.dropDistance(piece);
    }

    pub fn ghostPiece(self: *const Game) ?ActivePiece {
        var piece = self.active orelse return null;
        piece.pos.y += @as(i32, @intCast(self.dropDistance(piece)));
        return piece;
    }

    pub fn gravityIntervalFrames(self: *const Game) u16 {
        return gravityIntervalFramesForLevel(self.level);
    }

    /// Feed only deterministic gameplay state into a stable hash stream.
    ///
    /// This deliberately hashes fields one-by-one instead of hashing the raw
    /// `Game` struct, so padding, enum layout, and native pointer details never
    /// affect lockstep desync checks.
    pub fn feedDeterministicHash(self: *const Game, hasher: *std.hash.XxHash64) void {
        feedBoardHash(hasher, &self.board);
        feedSevenBagHash(hasher, &self.randomizer);
        feedPieceKindArrayHash(NextQueueLength, hasher, &self.next);
        feedOptionalPieceKindHash(hasher, self.hold);
        state_hash.feedBool(hasher, self.held_this_piece);
        feedOptionalActivePieceHash(hasher, self.active);
        state_hash.feedBool(hasher, self.game_over);
        state_hash.feedU32(hasher, self.total_lines_cleared);
        state_hash.feedU32(hasher, self.pieces_locked);
        state_hash.feedU32(hasher, self.score);
        state_hash.feedU8(hasher, self.level);
        state_hash.feedI32(hasher, self.combo_counter);
        state_hash.feedBool(hasher, self.back_to_back_active);
        feedOptionalLockResultHash(hasher, self.last_lock_result);
        state_hash.feedU16(hasher, self.lock_delay_frames);
        state_hash.feedU8(hasher, self.max_lock_move_resets);
        state_hash.feedU16(hasher, self.lock_delay_elapsed);
        state_hash.feedU8(hasher, self.lock_move_resets_used);
        state_hash.feedU32(hasher, self.soft_drop_points_pending);
        feedLastPieceActionHash(hasher, self.last_piece_action);
        feedOptionalRotationEventHash(hasher, self.last_successful_rotation);
    }

    fn moveActive(self: *Game, dx: i32, dy: i32, action: LastPieceAction, soft_drop_scoring: bool) bool {
        if (self.game_over) return false;
        var moved = self.active orelse return false;
        moved.pos.x += dx;
        moved.pos.y += dy;
        if (self.collides(moved)) return false;

        self.active = moved;
        if (soft_drop_scoring and dy > 0) {
            self.soft_drop_points_pending += @intCast(dy);
        }
        if (action != .none) {
            self.last_piece_action = action;
            if (action != .rotate) {
                self.last_successful_rotation = null;
            }
            self.maybeResetLockDelayAfterPlayerAction();
        } else if (!self.isActiveGrounded()) {
            self.lock_delay_elapsed = 0;
        }
        return true;
    }

    fn dropActiveToFloor(self: *Game) u32 {
        if (self.game_over) return 0;
        var piece = self.active orelse return 0;
        const dropped = self.dropDistance(piece);
        piece.pos.y += @as(i32, @intCast(dropped));
        self.active = piece;
        self.lock_delay_elapsed = 0;
        return dropped;
    }

    fn lockActiveDetailedWithDrop(self: *Game, hard_drop_cells: u32) ?LockResult {
        if (self.game_over) return null;
        const piece = self.active orelse return null;
        if (self.collides(piece)) {
            self.active = null;
            self.game_over = true;
            return null;
        }

        const t_spin_kind = self.detectTSpin(piece);

        var top_out = false;
        const blocks = blockPositions(piece);
        for (blocks) |point| {
            const x: usize = @intCast(point.x);
            const y: usize = @intCast(point.y);
            if (y < HiddenRows) top_out = true;
            self.board[y][x] = Cell.fromPiece(piece.kind);
        }

        self.active = null;
        self.held_this_piece = false;
        self.pieces_locked += 1;

        const cleared = self.clearFullLines();
        const perfect_clear = cleared > 0 and boardEmpty(&self.board);
        const result = self.finishScoring(piece.kind, cleared, t_spin_kind, perfect_clear, hard_drop_cells);
        self.level = levelForLines(self.total_lines_cleared);
        self.last_lock_result = result;

        self.lock_delay_elapsed = 0;
        self.lock_move_resets_used = 0;
        self.soft_drop_points_pending = 0;
        self.last_piece_action = .none;
        self.last_successful_rotation = null;

        if (top_out) {
            self.game_over = true;
            return result;
        }

        _ = self.spawnNext();
        return result;
    }

    fn finishScoring(
        self: *Game,
        piece_kind: PieceKind,
        lines_cleared: u8,
        t_spin_kind: TSpinKind,
        perfect_clear: bool,
        hard_drop_cells: u32,
    ) LockResult {
        const difficult_clear = isDifficultClear(lines_cleared, t_spin_kind);
        const b2b_bonus_applied = difficult_clear and self.back_to_back_active;

        if (lines_cleared > 0) {
            if (difficult_clear) {
                self.back_to_back_active = true;
            } else {
                self.back_to_back_active = false;
            }
            self.combo_counter += 1;
        } else {
            self.combo_counter = -1;
        }

        const level_multiplier: u32 = @intCast(self.level);
        const base_score = scoreTable(t_spin_kind, lines_cleared) * level_multiplier;
        const b2b_bonus = if (b2b_bonus_applied) base_score / 2 else 0;
        const combo_bonus = if (self.combo_counter > 0)
            @as(u32, @intCast(self.combo_counter)) * 50 * level_multiplier
        else
            0;
        const perfect_clear_bonus = if (perfect_clear)
            perfectClearScore(lines_cleared, b2b_bonus_applied) * level_multiplier
        else
            0;
        const hard_drop_points = hard_drop_cells * 2;
        const soft_drop_points = self.soft_drop_points_pending;
        const score_delta = base_score + b2b_bonus + combo_bonus + perfect_clear_bonus + hard_drop_points + soft_drop_points;
        self.score += score_delta;

        return .{
            .piece_kind = piece_kind,
            .lines_cleared = lines_cleared,
            .t_spin_kind = t_spin_kind,
            .perfect_clear = perfect_clear,
            .combo_after_lock = self.combo_counter,
            .back_to_back_active_after_lock = self.back_to_back_active,
            .back_to_back_bonus_applied = b2b_bonus_applied,
            .difficult_clear = difficult_clear,
            .base_score_points = base_score,
            .back_to_back_bonus_points = b2b_bonus,
            .combo_bonus_points = combo_bonus,
            .perfect_clear_bonus_points = perfect_clear_bonus,
            .hard_drop_cells = hard_drop_cells,
            .hard_drop_points = hard_drop_points,
            .soft_drop_points = soft_drop_points,
            .score_delta = score_delta,
            .total_score_after_lock = self.score,
            .attack_lines = attackLines(t_spin_kind, lines_cleared, b2b_bonus_applied, self.combo_counter, perfect_clear),
        };
    }

    fn detectTSpin(self: *const Game, piece: ActivePiece) TSpinKind {
        if (piece.kind != .t) return .none;
        if (self.last_piece_action != .rotate) return .none;
        const rotation_event = self.last_successful_rotation orelse return .none;
        if (rotation_event.piece_kind != .t or rotation_event.to != piece.rotation) return .none;

        const center = tCenter(piece);
        const nw = self.filledOrWall(.{ .x = center.x - 1, .y = center.y - 1 });
        const ne = self.filledOrWall(.{ .x = center.x + 1, .y = center.y - 1 });
        const sw = self.filledOrWall(.{ .x = center.x - 1, .y = center.y + 1 });
        const se = self.filledOrWall(.{ .x = center.x + 1, .y = center.y + 1 });

        const occupied_corners = boolCount(nw) + boolCount(ne) + boolCount(sw) + boolCount(se);
        if (occupied_corners < 3) return .none;

        const front_corners = switch (piece.rotation) {
            .spawn => boolCount(nw) + boolCount(ne),
            .right => boolCount(ne) + boolCount(se),
            .reverse => boolCount(sw) + boolCount(se),
            .left => boolCount(nw) + boolCount(sw),
        };

        if (front_corners == 2) return .full;
        if (rotation_event.kick_index == 4) return .full;
        return .mini;
    }

    fn filledOrWall(self: *const Game, point: Point) bool {
        if (point.x < 0 or point.x >= BoardWidthI) return true;
        if (point.y < 0 or point.y >= BoardHeightI) return true;
        const x: usize = @intCast(point.x);
        const y: usize = @intCast(point.y);
        return self.board[y][x] != null;
    }

    fn maybeResetLockDelayAfterPlayerAction(self: *Game) void {
        if (self.active == null) return;
        if (!self.isActiveGrounded()) {
            self.lock_delay_elapsed = 0;
            return;
        }
        if (self.lock_delay_elapsed == 0) return;
        if (self.lock_move_resets_used >= self.max_lock_move_resets) return;

        self.lock_delay_elapsed = 0;
        self.lock_move_resets_used += 1;
    }

    fn popNext(self: *Game) PieceKind {
        const piece = self.next[0];
        for (0..(NextQueueLength - 1)) |i| {
            self.next[i] = self.next[i + 1];
        }
        self.next[NextQueueLength - 1] = self.randomizer.next();
        return piece;
    }

    fn spawnKind(self: *Game, kind: PieceKind, hold_used: bool) bool {
        const piece = ActivePiece{
            .kind = kind,
            .rotation = .spawn,
            .pos = spawnPosition(),
        };
        if (self.collides(piece)) {
            self.active = null;
            self.game_over = true;
            return false;
        }
        self.active = piece;
        self.held_this_piece = hold_used;
        self.lock_delay_elapsed = 0;
        self.lock_move_resets_used = 0;
        self.soft_drop_points_pending = 0;
        self.last_piece_action = .none;
        self.last_successful_rotation = null;
        return true;
    }
};

fn feedBoardHash(hasher: *std.hash.XxHash64, board: *const Board) void {
    for (board.*) |row| {
        for (row) |cell| {
            feedOptionalCellHash(hasher, cell);
        }
    }
}

fn feedOptionalCellHash(hasher: *std.hash.XxHash64, cell: ?Cell) void {
    if (cell) |filled| {
        switch (filled) {
            .piece => |kind| {
                state_hash.feedU8(hasher, 1);
                feedPieceKindHash(hasher, kind);
            },
            .garbage => state_hash.feedU8(hasher, 2),
        }
    } else {
        state_hash.feedU8(hasher, 0);
    }
}

fn feedSevenBagHash(hasher: *std.hash.XxHash64, bag: *const SevenBag) void {
    state_hash.feedU64(hasher, bag.rng.state);
    feedPieceKindArrayHash(PieceCount, hasher, &bag.bag);
    std.debug.assert(bag.index <= PieceCount);
    state_hash.feedU8(hasher, @intCast(bag.index));
}

fn feedPieceKindArrayHash(comptime len: usize, hasher: *std.hash.XxHash64, pieces: *const [len]PieceKind) void {
    for (pieces.*) |kind| {
        feedPieceKindHash(hasher, kind);
    }
}

fn feedOptionalPieceKindHash(hasher: *std.hash.XxHash64, piece_kind: ?PieceKind) void {
    if (piece_kind) |kind| {
        state_hash.feedBool(hasher, true);
        feedPieceKindHash(hasher, kind);
    } else {
        state_hash.feedBool(hasher, false);
    }
}

fn feedOptionalActivePieceHash(hasher: *std.hash.XxHash64, active: ?ActivePiece) void {
    if (active) |piece| {
        state_hash.feedBool(hasher, true);
        feedActivePieceHash(hasher, piece);
    } else {
        state_hash.feedBool(hasher, false);
    }
}

fn feedActivePieceHash(hasher: *std.hash.XxHash64, piece: ActivePiece) void {
    feedPieceKindHash(hasher, piece.kind);
    feedRotationHash(hasher, piece.rotation);
    feedPointHash(hasher, piece.pos);
}

fn feedPointHash(hasher: *std.hash.XxHash64, point: Point) void {
    state_hash.feedI32(hasher, point.x);
    state_hash.feedI32(hasher, point.y);
}

fn feedOptionalLockResultHash(hasher: *std.hash.XxHash64, result: ?LockResult) void {
    if (result) |lock_result| {
        state_hash.feedBool(hasher, true);
        feedLockResultHash(hasher, lock_result);
    } else {
        state_hash.feedBool(hasher, false);
    }
}

fn feedLockResultHash(hasher: *std.hash.XxHash64, result: LockResult) void {
    feedPieceKindHash(hasher, result.piece_kind);
    state_hash.feedU8(hasher, result.lines_cleared);
    feedTSpinKindHash(hasher, result.t_spin_kind);
    state_hash.feedBool(hasher, result.perfect_clear);
    state_hash.feedI32(hasher, result.combo_after_lock);
    state_hash.feedBool(hasher, result.back_to_back_active_after_lock);
    state_hash.feedBool(hasher, result.back_to_back_bonus_applied);
    state_hash.feedBool(hasher, result.difficult_clear);
    state_hash.feedU32(hasher, result.base_score_points);
    state_hash.feedU32(hasher, result.back_to_back_bonus_points);
    state_hash.feedU32(hasher, result.combo_bonus_points);
    state_hash.feedU32(hasher, result.perfect_clear_bonus_points);
    state_hash.feedU32(hasher, result.hard_drop_cells);
    state_hash.feedU32(hasher, result.hard_drop_points);
    state_hash.feedU32(hasher, result.soft_drop_points);
    state_hash.feedU32(hasher, result.score_delta);
    state_hash.feedU32(hasher, result.total_score_after_lock);
    state_hash.feedU8(hasher, result.attack_lines);
}

fn feedOptionalRotationEventHash(hasher: *std.hash.XxHash64, event: ?RotationEvent) void {
    if (event) |rotation_event| {
        state_hash.feedBool(hasher, true);
        feedRotationEventHash(hasher, rotation_event);
    } else {
        state_hash.feedBool(hasher, false);
    }
}

fn feedRotationEventHash(hasher: *std.hash.XxHash64, event: RotationEvent) void {
    feedPieceKindHash(hasher, event.piece_kind);
    feedRotationHash(hasher, event.from);
    feedRotationHash(hasher, event.to);
    feedRotationDirectionHash(hasher, event.direction);
    state_hash.feedU8(hasher, event.kick_index);
    feedPointHash(hasher, event.kick);
}

fn feedPieceKindHash(hasher: *std.hash.XxHash64, kind: PieceKind) void {
    state_hash.feedU8(hasher, switch (kind) {
        .i => 0,
        .o => 1,
        .t => 2,
        .s => 3,
        .z => 4,
        .j => 5,
        .l => 6,
    });
}

fn feedRotationHash(hasher: *std.hash.XxHash64, rotation: Rotation) void {
    state_hash.feedU8(hasher, switch (rotation) {
        .spawn => 0,
        .right => 1,
        .reverse => 2,
        .left => 3,
    });
}

fn feedRotationDirectionHash(hasher: *std.hash.XxHash64, direction: RotationDirection) void {
    state_hash.feedU8(hasher, switch (direction) {
        .clockwise => 0,
        .counter_clockwise => 1,
        .half_turn => 2,
    });
}

fn feedTSpinKindHash(hasher: *std.hash.XxHash64, kind: TSpinKind) void {
    state_hash.feedU8(hasher, switch (kind) {
        .none => 0,
        .mini => 1,
        .full => 2,
    });
}

fn feedLastPieceActionHash(hasher: *std.hash.XxHash64, action: LastPieceAction) void {
    state_hash.feedU8(hasher, switch (action) {
        .none => 0,
        .move => 1,
        .rotate => 2,
    });
}

fn testGameDeterministicHash(game: *const Game) u64 {
    var hasher = std.hash.XxHash64.init(0);
    game.feedDeterministicHash(&hasher);
    return hasher.final();
}

pub fn levelForLines(total_lines_cleared: u32) u8 {
    const uncapped_level = 1 + total_lines_cleared / 10;
    return @intCast(@min(uncapped_level, @as(u32, MaxLevel)));
}

pub fn gravityIntervalFramesForLevel(level: u8) u16 {
    const normalized_level = if (level == 0) 1 else level;
    const capped_level = @min(normalized_level, MaxLevel);
    const index: usize = @intCast(capped_level - 1);
    return GravityFramesByLevel[index];
}

pub fn blockPositions(piece: ActivePiece) [4]Point {
    const offsets = shapeOffsets(piece.kind, piece.rotation);
    var result: [4]Point = undefined;
    for (offsets, 0..) |offset, i| {
        result[i] = .{
            .x = piece.pos.x + offset.x,
            .y = piece.pos.y + offset.y,
        };
    }
    return result;
}

pub fn shapeOffsets(kind: PieceKind, rotation: Rotation) [4]Point {
    const base = baseOffsets(kind);
    if (kind == .o) return base;

    const size: i32 = if (kind == .i) 4 else 3;
    const turns: u8 = @intFromEnum(rotation);
    var result: [4]Point = undefined;

    for (base, 0..) |point, i| {
        var rotated = point;
        var turn: u8 = 0;
        while (turn < turns) : (turn += 1) {
            rotated = rotatePointClockwise(rotated, size);
        }
        result[i] = rotated;
    }
    return result;
}

fn baseOffsets(kind: PieceKind) [4]Point {
    return switch (kind) {
        .i => .{
            .{ .x = 0, .y = 1 },
            .{ .x = 1, .y = 1 },
            .{ .x = 2, .y = 1 },
            .{ .x = 3, .y = 1 },
        },
        .o => .{
            .{ .x = 1, .y = 0 },
            .{ .x = 2, .y = 0 },
            .{ .x = 1, .y = 1 },
            .{ .x = 2, .y = 1 },
        },
        .t => .{
            .{ .x = 1, .y = 0 },
            .{ .x = 0, .y = 1 },
            .{ .x = 1, .y = 1 },
            .{ .x = 2, .y = 1 },
        },
        .s => .{
            .{ .x = 1, .y = 0 },
            .{ .x = 2, .y = 0 },
            .{ .x = 0, .y = 1 },
            .{ .x = 1, .y = 1 },
        },
        .z => .{
            .{ .x = 0, .y = 0 },
            .{ .x = 1, .y = 0 },
            .{ .x = 1, .y = 1 },
            .{ .x = 2, .y = 1 },
        },
        .j => .{
            .{ .x = 0, .y = 0 },
            .{ .x = 0, .y = 1 },
            .{ .x = 1, .y = 1 },
            .{ .x = 2, .y = 1 },
        },
        .l => .{
            .{ .x = 2, .y = 0 },
            .{ .x = 0, .y = 1 },
            .{ .x = 1, .y = 1 },
            .{ .x = 2, .y = 1 },
        },
    };
}

fn spawnPosition() Point {
    return .{ .x = 3, .y = HiddenRowsI - 2 };
}

fn rotatePointClockwise(point: Point, size: i32) Point {
    return .{
        .x = size - 1 - point.y,
        .y = point.x,
    };
}

fn turned(rotation: Rotation, direction: RotationDirection) Rotation {
    const raw: u8 = @intFromEnum(rotation);
    const next = switch (direction) {
        .clockwise => (raw + 1) % 4,
        .counter_clockwise => (raw + 3) % 4,
        .half_turn => (raw + 2) % 4,
    };
    return @enumFromInt(next);
}

fn kickTestsFor(kind: PieceKind, from: Rotation, to: Rotation, direction: RotationDirection) KickTests {
    if (direction == .half_turn) return halfTurnKicks(kind);
    return switch (kind) {
        .i => iKicks(from, to),
        .o => noKick(),
        .t, .s, .z, .j, .l => jlStzKicks(from, to),
    };
}

fn noKick() KickTests {
    return .{ .kicks = .{ pt(0, 0), pt(0, 0), pt(0, 0), pt(0, 0), pt(0, 0) }, .len = 1 };
}

fn halfTurnKicks(kind: PieceKind) KickTests {
    if (kind == .o) return noKick();
    return .{ .kicks = .{ pt(0, 0), pt(1, 0), pt(-1, 0), pt(0, 1), pt(0, -1) }, .len = 5 };
}

fn jlStzKicks(from: Rotation, to: Rotation) KickTests {
    if (from == .spawn and to == .right) return .{ .kicks = .{ pt(0, 0), pt(-1, 0), pt(-1, -1), pt(0, 2), pt(-1, 2) }, .len = 5 };
    if (from == .right and to == .spawn) return .{ .kicks = .{ pt(0, 0), pt(1, 0), pt(1, 1), pt(0, -2), pt(1, -2) }, .len = 5 };
    if (from == .right and to == .reverse) return .{ .kicks = .{ pt(0, 0), pt(1, 0), pt(1, 1), pt(0, -2), pt(1, -2) }, .len = 5 };
    if (from == .reverse and to == .right) return .{ .kicks = .{ pt(0, 0), pt(-1, 0), pt(-1, -1), pt(0, 2), pt(-1, 2) }, .len = 5 };
    if (from == .reverse and to == .left) return .{ .kicks = .{ pt(0, 0), pt(1, 0), pt(1, -1), pt(0, 2), pt(1, 2) }, .len = 5 };
    if (from == .left and to == .reverse) return .{ .kicks = .{ pt(0, 0), pt(-1, 0), pt(-1, 1), pt(0, -2), pt(-1, -2) }, .len = 5 };
    if (from == .left and to == .spawn) return .{ .kicks = .{ pt(0, 0), pt(-1, 0), pt(-1, 1), pt(0, -2), pt(-1, -2) }, .len = 5 };
    if (from == .spawn and to == .left) return .{ .kicks = .{ pt(0, 0), pt(1, 0), pt(1, -1), pt(0, 2), pt(1, 2) }, .len = 5 };
    return noKick();
}

fn iKicks(from: Rotation, to: Rotation) KickTests {
    if (from == .spawn and to == .right) return .{ .kicks = .{ pt(0, 0), pt(-2, 0), pt(1, 0), pt(-2, 1), pt(1, -2) }, .len = 5 };
    if (from == .right and to == .spawn) return .{ .kicks = .{ pt(0, 0), pt(2, 0), pt(-1, 0), pt(2, -1), pt(-1, 2) }, .len = 5 };
    if (from == .right and to == .reverse) return .{ .kicks = .{ pt(0, 0), pt(-1, 0), pt(2, 0), pt(-1, -2), pt(2, 1) }, .len = 5 };
    if (from == .reverse and to == .right) return .{ .kicks = .{ pt(0, 0), pt(1, 0), pt(-2, 0), pt(1, 2), pt(-2, -1) }, .len = 5 };
    if (from == .reverse and to == .left) return .{ .kicks = .{ pt(0, 0), pt(2, 0), pt(-1, 0), pt(2, -1), pt(-1, 2) }, .len = 5 };
    if (from == .left and to == .reverse) return .{ .kicks = .{ pt(0, 0), pt(-2, 0), pt(1, 0), pt(-2, 1), pt(1, -2) }, .len = 5 };
    if (from == .left and to == .spawn) return .{ .kicks = .{ pt(0, 0), pt(1, 0), pt(-2, 0), pt(1, 2), pt(-2, -1) }, .len = 5 };
    if (from == .spawn and to == .left) return .{ .kicks = .{ pt(0, 0), pt(-1, 0), pt(2, 0), pt(-1, -2), pt(2, 1) }, .len = 5 };
    return noKick();
}

fn pt(x: i32, y: i32) Point {
    return .{ .x = x, .y = y };
}

fn tCenter(piece: ActivePiece) Point {
    return .{ .x = piece.pos.x + 1, .y = piece.pos.y + 1 };
}

fn boolCount(value: bool) u8 {
    return if (value) 1 else 0;
}

fn isDifficultClear(lines_cleared: u8, t_spin_kind: TSpinKind) bool {
    return lines_cleared == 4 or (lines_cleared > 0 and t_spin_kind != .none);
}

fn scoreTable(t_spin_kind: TSpinKind, lines_cleared: u8) u32 {
    return switch (t_spin_kind) {
        .none => switch (lines_cleared) {
            0 => 0,
            1 => 100,
            2 => 300,
            3 => 500,
            4 => 800,
            else => 0,
        },
        .mini => switch (lines_cleared) {
            0 => 100,
            1 => 200,
            2 => 400,
            else => 0,
        },
        .full => switch (lines_cleared) {
            0 => 400,
            1 => 800,
            2 => 1200,
            3 => 1600,
            else => 0,
        },
    };
}

fn perfectClearScore(lines_cleared: u8, back_to_back_bonus_applied: bool) u32 {
    if (lines_cleared == 4 and back_to_back_bonus_applied) return 3200;
    return switch (lines_cleared) {
        1 => 800,
        2 => 1200,
        3 => 1800,
        4 => 2000,
        else => 0,
    };
}

fn attackLines(
    t_spin_kind: TSpinKind,
    lines_cleared: u8,
    back_to_back_bonus_applied: bool,
    combo_after_lock: i32,
    perfect_clear: bool,
) u8 {
    var attack: u8 = switch (t_spin_kind) {
        .none => switch (lines_cleared) {
            0, 1 => 0,
            2 => 1,
            3 => 2,
            4 => 4,
            else => 0,
        },
        .mini => switch (lines_cleared) {
            0, 1 => 0,
            2 => 1,
            else => 0,
        },
        .full => switch (lines_cleared) {
            0 => 0,
            1 => 2,
            2 => 4,
            3 => 6,
            else => 0,
        },
    };

    if (back_to_back_bonus_applied and attack > 0) attack += 1;
    if (lines_cleared > 0) attack += comboAttack(combo_after_lock);
    if (perfect_clear) attack += 10;
    return attack;
}

fn comboAttack(combo_after_lock: i32) u8 {
    if (combo_after_lock <= 0) return 0;
    if (combo_after_lock <= 2) return 1;
    if (combo_after_lock <= 4) return 2;
    if (combo_after_lock <= 6) return 3;
    return 4;
}

fn emptyBoard() Board {
    return [_][BoardWidth]?Cell{emptyRow()} ** BoardHeight;
}

fn emptyRow() [BoardWidth]?Cell {
    return [_]?Cell{null} ** BoardWidth;
}

fn garbageRow(hole: GarbageHole) [BoardWidth]?Cell {
    var row = [_]?Cell{Cell.garbage} ** BoardWidth;
    row[hole.index()] = null;
    return row;
}

fn rowFull(row: *const [BoardWidth]?Cell) bool {
    for (row.*) |cell| {
        if (cell == null) return false;
    }
    return true;
}

fn rowOccupied(row: *const [BoardWidth]?Cell) bool {
    for (row.*) |cell| {
        if (cell != null) return true;
    }
    return false;
}

fn boardEmpty(board: *const Board) bool {
    for (board.*) |row| {
        for (row) |cell| {
            if (cell != null) return false;
        }
    }
    return true;
}

fn pieceIndex(kind: PieceKind) usize {
    return @intCast(@intFromEnum(kind));
}

fn fillRowExcept(game: *Game, y: usize, gaps: []const usize, kind: PieceKind) void {
    for (0..BoardWidth) |x| {
        var is_gap = false;
        for (gaps) |gap| {
            if (x == gap) {
                is_gap = true;
                break;
            }
        }
        game.board[y][x] = if (is_gap) null else Cell.fromPiece(kind);
    }
}

fn markLastRotationForTest(game: *Game, piece: ActivePiece, from: Rotation, kick_index: u8) void {
    game.active = piece;
    game.last_piece_action = .rotate;
    game.last_successful_rotation = .{
        .piece_kind = piece.kind,
        .from = from,
        .to = piece.rotation,
        .direction = .clockwise,
        .kick_index = kick_index,
        .kick = pt(0, 0),
    };
}

fn expectPieceCell(expected: PieceKind, cell: ?Cell) !void {
    try std.testing.expect(cell != null);
    const actual = cell.?.pieceKind() orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(expected, actual);
}

fn expectGarbageCell(cell: ?Cell) !void {
    try std.testing.expect(cell != null);
    try std.testing.expect(cell.?.isGarbage());
}

test "game deterministic hash is stable for equal fresh games" {
    const left = Game.init(0x1234_5678);
    const right = Game.init(0x1234_5678);

    try std.testing.expectEqual(testGameDeterministicHash(&left), testGameDeterministicHash(&right));
}

test "game deterministic hash changes for board and gameplay metadata" {
    const base = Game.init(0x1234_5678);
    const base_hash = testGameDeterministicHash(&base);

    var board_changed = base;
    board_changed.board[BoardHeight - 1][0] = Cell.fromPiece(.i);
    try std.testing.expect(testGameDeterministicHash(&board_changed) != base_hash);

    var lock_metadata_changed = base;
    _ = lock_metadata_changed.hardDropAndLockDetailed();
    try std.testing.expect(testGameDeterministicHash(&lock_metadata_changed) != base_hash);
}

test "seven bag produces one of each tetromino before repeat" {
    var bag = SevenBag.init(0x1234_5678);

    var seen = [_]bool{false} ** PieceCount;
    for (0..PieceCount) |_| {
        const piece = bag.next();
        try std.testing.expect(!seen[pieceIndex(piece)]);
        seen[pieceIndex(piece)] = true;
    }
    for (seen) |was_seen| {
        try std.testing.expect(was_seen);
    }

    seen = [_]bool{false} ** PieceCount;
    for (0..PieceCount) |_| {
        const piece = bag.next();
        try std.testing.expect(!seen[pieceIndex(piece)]);
        seen[pieceIndex(piece)] = true;
    }
    for (seen) |was_seen| {
        try std.testing.expect(was_seen);
    }
}

test "SRS kicks use JLSTZ and I tables" {
    var t_game = Game.initNoSpawn(10);
    t_game.active = .{
        .kind = .t,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = 24 },
    };
    t_game.board[24][4] = Cell.fromPiece(.z);

    try std.testing.expect(t_game.tryRotate(.clockwise));
    try std.testing.expectEqual(Rotation.right, t_game.active.?.rotation);
    try std.testing.expectEqual(@as(i32, 2), t_game.active.?.pos.x);
    try std.testing.expectEqual(@as(u8, 1), t_game.last_successful_rotation.?.kick_index);
    try std.testing.expectEqual(@as(i32, -1), t_game.last_successful_rotation.?.kick.x);
    try std.testing.expectEqual(@as(i32, 0), t_game.last_successful_rotation.?.kick.y);

    var i_game = Game.initNoSpawn(11);
    i_game.active = .{
        .kind = .i,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = 24 },
    };
    i_game.board[24][5] = Cell.fromPiece(.z);

    try std.testing.expect(i_game.tryRotate(.clockwise));
    try std.testing.expectEqual(Rotation.right, i_game.active.?.rotation);
    try std.testing.expectEqual(@as(i32, 1), i_game.active.?.pos.x);
    try std.testing.expectEqual(@as(u8, 1), i_game.last_successful_rotation.?.kick_index);
    try std.testing.expectEqual(@as(i32, -2), i_game.last_successful_rotation.?.kick.x);
    try std.testing.expectEqual(@as(i32, 0), i_game.last_successful_rotation.?.kick.y);

    var wall_game = Game.initNoSpawn(13);
    wall_game.active = .{
        .kind = .t,
        .rotation = .left,
        .pos = .{ .x = 8, .y = 24 },
    };
    try std.testing.expect(wall_game.tryRotate(.counter_clockwise));
    try std.testing.expectEqual(Rotation.reverse, wall_game.active.?.rotation);
    try std.testing.expectEqual(@as(i32, 7), wall_game.active.?.pos.x);
    try std.testing.expectEqual(@as(u8, 1), wall_game.last_successful_rotation.?.kick_index);
    try std.testing.expectEqual(@as(i32, -1), wall_game.last_successful_rotation.?.kick.x);
}

test "O rotates in place and half turn is available" {
    var game = Game.initNoSpawn(12);
    game.active = .{
        .kind = .o,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = 24 },
    };

    try std.testing.expect(game.tryRotate(.clockwise));
    try std.testing.expectEqual(Rotation.right, game.active.?.rotation);
    try std.testing.expectEqual(@as(i32, 3), game.active.?.pos.x);
    try std.testing.expectEqual(@as(i32, 24), game.active.?.pos.y);

    try std.testing.expect(game.tryRotate(.half_turn));
    try std.testing.expectEqual(Rotation.left, game.active.?.rotation);
    try std.testing.expectEqual(@as(i32, 3), game.active.?.pos.x);
    try std.testing.expectEqual(@as(i32, 24), game.active.?.pos.y);
}

test "collision and locking stop a piece at the floor" {
    var game = Game.initNoSpawn(1);
    game.active = .{
        .kind = .o,
        .rotation = .spawn,
        .pos = .{ .x = 4, .y = BoardHeightI - 2 },
    };

    try std.testing.expect(!game.collides(game.active.?));
    try std.testing.expect(!game.tryMove(0, 1));

    const cleared = game.lockActive();
    try std.testing.expectEqual(@as(u8, 0), cleared);
    try std.testing.expectEqual(@as(u32, 1), game.pieces_locked);
    try expectPieceCell(.o, game.board[BoardHeight - 1][5]);
    try expectPieceCell(.o, game.board[BoardHeight - 2][6]);
    try std.testing.expect(game.active != null);
    try std.testing.expect(!game.game_over);
}

test "locking a piece clears completed lines" {
    var game = Game.initNoSpawn(2);
    for (0..BoardWidth) |x| {
        game.board[BoardHeight - 1][x] = Cell.fromPiece(.t);
    }
    game.board[BoardHeight - 1][4] = null;
    game.board[BoardHeight - 1][5] = null;
    game.active = .{
        .kind = .o,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = BoardHeightI - 2 },
    };

    const cleared = game.lockActive();
    try std.testing.expectEqual(@as(u8, 1), cleared);
    try std.testing.expectEqual(@as(u32, 1), game.total_lines_cleared);
    try expectPieceCell(.o, game.board[BoardHeight - 1][4]);
    try expectPieceCell(.o, game.board[BoardHeight - 1][5]);
    try std.testing.expect(game.board[BoardHeight - 1][0] == null);
    try std.testing.expect(!game.game_over);
}

test "garbage insertion appends bottom row with hole and shifts cells upward" {
    var game = Game.initNoSpawn(60);
    game.board[BoardHeight - 1][0] = Cell.fromPiece(.i);
    game.board[BoardHeight - 2][2] = Cell.fromPiece(.t);

    try game.insertGarbageLine(3);

    try expectPieceCell(.i, game.board[BoardHeight - 2][0]);
    try expectPieceCell(.t, game.board[BoardHeight - 3][2]);
    try std.testing.expect(game.board[BoardHeight - 1][3] == null);
    for (0..BoardWidth) |x| {
        if (x == 3) continue;
        try expectGarbageCell(game.board[BoardHeight - 1][x]);
    }
    try std.testing.expect(!game.game_over);
}

test "garbage insertion rejects holes outside the board" {
    var game = Game.initNoSpawn(61);
    const before = game.board;

    try std.testing.expectError(error.HoleOutOfBounds, game.insertGarbageLine(@intCast(BoardWidth)));

    try std.testing.expectEqualDeep(before, game.board);
    try std.testing.expect(!game.game_over);
}

test "external garbage insertion validates full batch before mutating" {
    var game = Game.initNoSpawn(65);
    game.board[BoardHeight - 1][0] = Cell.fromPiece(.i);
    const before = game.board;
    const holes = [_]u8{ 3, @intCast(BoardWidth), 2 };

    try std.testing.expectError(error.HoleOutOfBounds, game.insertGarbageLines(&holes));

    try std.testing.expectEqualDeep(before, game.board);
    try std.testing.expect(!game.game_over);
}

// Public wrappers reject arbitrary bytes, while bounded garbage holes are
// valid-by-construction for deterministic generated insertion.
test "bounded garbage hole insertion is infallible once constructed" {
    try std.testing.expectError(error.HoleOutOfBounds, GarbageHole.init(@intCast(BoardWidth)));

    var game = Game.initNoSpawn(67);
    const hole = try GarbageHole.init(2);
    game.insertGarbageLineAt(hole);

    try std.testing.expect(game.board[BoardHeight - 1][2] == null);
    try expectGarbageCell(game.board[BoardHeight - 1][0]);
    try std.testing.expect(!game.game_over);
}

test "bounded garbage insertion finalizes top-out internally" {
    var ejection = Game.initNoSpawn(68);
    ejection.board[0][1] = Cell.fromPiece(.s);
    ejection.insertGarbageLineAt(GarbageHole.fromValidIndex(0));
    try std.testing.expect(ejection.game_over);

    var collision = Game.initNoSpawn(69);
    const active_piece = ActivePiece{
        .kind = .o,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = BoardHeightI - 2 },
    };
    collision.active = active_piece;
    collision.insertGarbageLinesAt(&.{GarbageHole.fromValidIndex(0)});
    try std.testing.expect(collision.game_over);
    try std.testing.expectEqual(active_piece, collision.active.?);
    try std.testing.expect(collision.collides(active_piece));
}

test "multi-line garbage collision uses final batch state" {
    var game = Game.initNoSpawn(66);
    const active_piece = ActivePiece{
        .kind = .i,
        .rotation = .right,
        .pos = .{ .x = 2, .y = BoardHeightI - 6 },
    };
    game.active = active_piece;
    game.board[BoardHeight - 2][4] = Cell.fromPiece(.s);

    try std.testing.expect(!game.collides(active_piece));
    try game.insertGarbageLines(&.{ 4, 4, 4, 4, 4 });

    try std.testing.expect(!game.game_over);
    try std.testing.expect(!game.collides(active_piece));
    try expectPieceCell(.s, game.board[BoardHeight - 7][4]);
}

test "garbage insertion top-outs when row zero ejects occupied cells" {
    var game = Game.initNoSpawn(62);
    game.board[0][1] = Cell.fromPiece(.s);

    try game.insertGarbageLine(0);

    try std.testing.expect(game.game_over);
    try std.testing.expect(game.board[0][1] == null);
    try std.testing.expect(game.board[BoardHeight - 1][0] == null);
    try expectGarbageCell(game.board[BoardHeight - 1][1]);
}

test "garbage insertion top-outs when shifted board collides with active piece" {
    var game = Game.initNoSpawn(63);
    const active_piece = ActivePiece{
        .kind = .o,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = BoardHeightI - 2 },
    };
    game.active = active_piece;

    try std.testing.expect(!game.collides(active_piece));
    try game.insertGarbageLine(0);

    try std.testing.expect(game.game_over);
    try std.testing.expectEqual(active_piece, game.active.?);
    try std.testing.expect(game.collides(active_piece));
}

test "line clearing treats piece cells and garbage cells as occupied" {
    var game = Game.initNoSpawn(64);
    game.board[BoardHeight - 2][0] = Cell.fromPiece(.l);
    for (0..BoardWidth) |x| {
        game.board[BoardHeight - 1][x] = if (x == 4) Cell.fromPiece(.t) else Cell.garbage;
    }

    const cleared = game.clearFullLines();

    try std.testing.expectEqual(@as(u8, 1), cleared);
    try std.testing.expectEqual(@as(u32, 1), game.total_lines_cleared);
    try expectPieceCell(.l, game.board[BoardHeight - 1][0]);
    try std.testing.expect(game.board[BoardHeight - 2][0] == null);
}

test "hold can be used only once per active piece" {
    var game = Game.init(3);
    const first_kind = game.active.?.kind;
    const first_next = game.next[0];

    try std.testing.expect(game.holdPiece());
    try std.testing.expectEqual(first_kind, game.hold.?);
    try std.testing.expectEqual(first_next, game.active.?.kind);
    try std.testing.expect(game.held_this_piece);

    const active_after_hold = game.active.?.kind;
    try std.testing.expect(!game.holdPiece());
    try std.testing.expectEqual(active_after_hold, game.active.?.kind);
    try std.testing.expectEqual(first_kind, game.hold.?);

    _ = game.hardDropAndLock();
    try std.testing.expect(!game.game_over);
    try std.testing.expect(!game.held_this_piece);
    try std.testing.expect(game.holdPiece());
}

test "game over when spawn is blocked or a piece locks in hidden rows" {
    var blocked = Game.initNoSpawn(4);
    const spawn_kind = blocked.next[0];
    const spawn_piece = ActivePiece{
        .kind = spawn_kind,
        .rotation = .spawn,
        .pos = spawnPosition(),
    };
    for (blockPositions(spawn_piece)) |block| {
        const x: usize = @intCast(block.x);
        const y: usize = @intCast(block.y);
        blocked.board[y][x] = Cell.fromPiece(.z);
    }

    try std.testing.expect(!blocked.spawnNext());
    try std.testing.expect(blocked.game_over);
    try std.testing.expect(blocked.active == null);

    var hidden_lock = Game.initNoSpawn(5);
    hidden_lock.active = .{
        .kind = .o,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = HiddenRowsI - 2 },
    };
    _ = hidden_lock.lockActive();
    try std.testing.expect(hidden_lock.game_over);
}

test "T-spin single double triple and mini are detected" {
    var single = Game.initNoSpawn(20);
    fillRowExcept(&single, 36, &.{ 3, 4, 5 }, .j);
    single.board[35][3] = Cell.fromPiece(.j);
    single.board[35][5] = Cell.fromPiece(.j);
    single.board[37][3] = Cell.fromPiece(.j);
    markLastRotationForTest(&single, .{
        .kind = .t,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = 35 },
    }, .left, 0);
    const single_result = single.lockActiveDetailed().?;
    try std.testing.expectEqual(@as(u8, 1), single_result.lines_cleared);
    try std.testing.expectEqual(TSpinKind.full, single_result.t_spin_kind);
    try std.testing.expectEqual(@as(u32, 800), single_result.base_score_points);
    try std.testing.expect(single_result.difficult_clear);

    var double = Game.initNoSpawn(21);
    fillRowExcept(&double, 35, &.{4}, .j);
    fillRowExcept(&double, 36, &.{ 3, 4, 5 }, .j);
    double.board[37][3] = Cell.fromPiece(.j);
    markLastRotationForTest(&double, .{
        .kind = .t,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = 35 },
    }, .left, 0);
    const double_result = double.lockActiveDetailed().?;
    try std.testing.expectEqual(@as(u8, 2), double_result.lines_cleared);
    try std.testing.expectEqual(TSpinKind.full, double_result.t_spin_kind);
    try std.testing.expectEqual(@as(u32, 1200), double_result.base_score_points);

    var triple = Game.initNoSpawn(22);
    fillRowExcept(&triple, 34, &.{4}, .j);
    fillRowExcept(&triple, 35, &.{ 4, 5 }, .j);
    fillRowExcept(&triple, 36, &.{4}, .j);
    markLastRotationForTest(&triple, .{
        .kind = .t,
        .rotation = .right,
        .pos = .{ .x = 3, .y = 34 },
    }, .spawn, 0);
    const triple_result = triple.lockActiveDetailed().?;
    try std.testing.expectEqual(@as(u8, 3), triple_result.lines_cleared);
    try std.testing.expectEqual(TSpinKind.full, triple_result.t_spin_kind);
    try std.testing.expectEqual(@as(u32, 1600), triple_result.base_score_points);

    var mini = Game.initNoSpawn(23);
    fillRowExcept(&mini, 36, &.{ 3, 4, 5 }, .j);
    mini.board[35][3] = Cell.fromPiece(.j);
    mini.board[37][3] = Cell.fromPiece(.j);
    mini.board[37][5] = Cell.fromPiece(.j);
    markLastRotationForTest(&mini, .{
        .kind = .t,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = 35 },
    }, .left, 0);
    const mini_result = mini.lockActiveDetailed().?;
    try std.testing.expectEqual(@as(u8, 1), mini_result.lines_cleared);
    try std.testing.expectEqual(TSpinKind.mini, mini_result.t_spin_kind);
    try std.testing.expectEqual(@as(u32, 200), mini_result.base_score_points);
}

test "combo counter back-to-back and scoring metadata" {
    var combo = Game.initNoSpawn(30);
    combo.board[0][0] = Cell.fromPiece(.i);
    fillRowExcept(&combo, BoardHeight - 1, &.{ 4, 5 }, .j);
    combo.active = .{
        .kind = .o,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = BoardHeightI - 2 },
    };
    const first = combo.lockActiveDetailed().?;
    try std.testing.expectEqual(@as(u8, 1), first.lines_cleared);
    try std.testing.expectEqual(@as(i32, 0), first.combo_after_lock);
    try std.testing.expectEqual(@as(u32, 0), first.combo_bonus_points);

    combo.board = emptyBoard();
    combo.board[0][0] = Cell.fromPiece(.i);
    fillRowExcept(&combo, BoardHeight - 1, &.{ 4, 5 }, .j);
    combo.active = .{
        .kind = .o,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = BoardHeightI - 2 },
    };
    const second = combo.lockActiveDetailed().?;
    try std.testing.expectEqual(@as(i32, 1), second.combo_after_lock);
    try std.testing.expectEqual(@as(u32, 50), second.combo_bonus_points);

    combo.board = emptyBoard();
    combo.board[0][0] = Cell.fromPiece(.i);
    combo.active = .{
        .kind = .o,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = BoardHeightI - 2 },
    };
    const miss = combo.lockActiveDetailed().?;
    try std.testing.expectEqual(@as(u8, 0), miss.lines_cleared);
    try std.testing.expectEqual(@as(i32, -1), miss.combo_after_lock);

    var b2b = Game.initNoSpawn(31);
    b2b.board[0][0] = Cell.fromPiece(.i);
    for (36..40) |y| fillRowExcept(&b2b, y, &.{4}, .j);
    b2b.active = .{
        .kind = .i,
        .rotation = .right,
        .pos = .{ .x = 2, .y = 36 },
    };
    const first_quad = b2b.lockActiveDetailed().?;
    try std.testing.expectEqual(@as(u8, 4), first_quad.lines_cleared);
    try std.testing.expect(first_quad.difficult_clear);
    try std.testing.expect(first_quad.back_to_back_active_after_lock);
    try std.testing.expect(!first_quad.back_to_back_bonus_applied);
    try std.testing.expectEqual(@as(u32, 800), first_quad.base_score_points);

    b2b.board = emptyBoard();
    b2b.board[0][0] = Cell.fromPiece(.i);
    for (36..40) |y| fillRowExcept(&b2b, y, &.{4}, .j);
    b2b.active = .{
        .kind = .i,
        .rotation = .right,
        .pos = .{ .x = 2, .y = 36 },
    };
    const second_quad = b2b.lockActiveDetailed().?;
    try std.testing.expect(second_quad.back_to_back_bonus_applied);
    try std.testing.expect(second_quad.back_to_back_active_after_lock);
    try std.testing.expectEqual(@as(u32, 800), second_quad.base_score_points);
    try std.testing.expectEqual(@as(u32, 400), second_quad.back_to_back_bonus_points);
    try std.testing.expectEqual(@as(u32, 50), second_quad.combo_bonus_points);
    try std.testing.expectEqual(@as(u8, 6), second_quad.attack_lines);
}

test "perfect clear and drop points are included in lock result" {
    var game = Game.initNoSpawn(40);
    fillRowExcept(&game, BoardHeight - 2, &.{ 4, 5 }, .j);
    fillRowExcept(&game, BoardHeight - 1, &.{ 4, 5 }, .j);
    game.active = .{
        .kind = .o,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = 30 },
    };

    const result = game.hardDropAndLockDetailed().?;
    try std.testing.expectEqual(@as(u32, 8), result.hard_drop_cells);
    try std.testing.expectEqual(@as(u32, 16), result.hard_drop_points);
    try std.testing.expectEqual(@as(u8, 2), result.lines_cleared);
    try std.testing.expect(result.perfect_clear);
    try std.testing.expectEqual(@as(u32, 1200), result.perfect_clear_bonus_points);
    try std.testing.expectEqual(@as(u32, 1516), result.score_delta);
    try std.testing.expectEqual(@as(u8, 11), result.attack_lines);
}

test "pure drop distance and ghost piece do not mutate active piece" {
    var game = Game.initNoSpawn(42);
    game.active = .{
        .kind = .o,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = 30 },
    };

    const before = game.active.?;
    try std.testing.expectEqual(@as(u32, 8), game.dropDistance(before));
    const ghost = game.ghostPiece().?;
    try std.testing.expectEqual(@as(i32, 38), ghost.pos.y);
    try std.testing.expectEqual(before, game.active.?);

    game.board[BoardHeight - 1][4] = Cell.fromPiece(.i);
    try std.testing.expectEqual(@as(u32, 7), game.activeDropDistance());
    const blocked_ghost = game.ghostPiece().?;
    try std.testing.expectEqual(@as(i32, 37), blocked_ghost.pos.y);
    try std.testing.expectEqual(before, game.active.?);
}

test "soft drop points are included in lock result" {
    var game = Game.initNoSpawn(41);
    game.active = .{
        .kind = .o,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = BoardHeightI - 4 },
    };

    try std.testing.expect(game.softDropOne());
    const result = game.lockActiveDetailed().?;
    try std.testing.expectEqual(@as(u32, 1), result.soft_drop_points);
    try std.testing.expectEqual(@as(u32, 1), result.score_delta);
}

test "lock delay ticks and successful grounded movement resets it" {
    var game = Game.initNoSpawn(50);
    game.lock_delay_frames = 3;
    game.active = .{
        .kind = .o,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = BoardHeightI - 2 },
    };

    try std.testing.expect(game.tick() == null);
    try std.testing.expectEqual(@as(u16, 1), game.lock_delay_elapsed);
    try std.testing.expect(game.tick() == null);
    try std.testing.expectEqual(@as(u16, 2), game.lock_delay_elapsed);

    try std.testing.expect(game.tryMove(1, 0));
    try std.testing.expectEqual(@as(u16, 0), game.lock_delay_elapsed);
    try std.testing.expectEqual(@as(u8, 1), game.lock_move_resets_used);

    try std.testing.expect(game.tick() == null);
    try std.testing.expect(game.tick() == null);
    const result = game.tick().?;
    try std.testing.expectEqual(@as(u8, 0), result.lines_cleared);
    try std.testing.expectEqual(@as(u32, 1), game.pieces_locked);
}

test "lock delay move reset cap is enforced" {
    var game = Game.initNoSpawn(51);
    game.lock_delay_frames = 5;
    game.max_lock_move_resets = 1;
    game.active = .{
        .kind = .o,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = BoardHeightI - 2 },
    };

    _ = game.tick();
    _ = game.tick();
    try std.testing.expectEqual(@as(u16, 2), game.lock_delay_elapsed);

    try std.testing.expect(game.tryMove(1, 0));
    try std.testing.expectEqual(@as(u16, 0), game.lock_delay_elapsed);
    try std.testing.expectEqual(@as(u8, 1), game.lock_move_resets_used);

    _ = game.tick();
    _ = game.tick();
    try std.testing.expectEqual(@as(u16, 2), game.lock_delay_elapsed);

    try std.testing.expect(game.tryMove(-1, 0));
    try std.testing.expectEqual(@as(u16, 2), game.lock_delay_elapsed);
    try std.testing.expectEqual(@as(u8, 1), game.lock_move_resets_used);

    _ = game.tick();
    _ = game.tick();
    const result = game.tick().?;
    try std.testing.expectEqual(@as(u8, 0), result.lines_cleared);
    try std.testing.expectEqual(@as(u32, 1), game.pieces_locked);
}

test "grounded floor kick rotation resets lock delay" {
    var game = Game.initNoSpawn(52);
    game.lock_delay_frames = 5;
    game.active = .{
        .kind = .t,
        .rotation = .spawn,
        .pos = .{ .x = 3, .y = BoardHeightI - 2 },
    };

    _ = game.tick();
    _ = game.tick();
    try std.testing.expectEqual(@as(u16, 2), game.lock_delay_elapsed);

    try std.testing.expect(game.tryRotate(.clockwise));
    try std.testing.expectEqual(Rotation.right, game.active.?.rotation);
    try std.testing.expectEqual(@as(i32, 2), game.active.?.pos.x);
    try std.testing.expectEqual(@as(i32, BoardHeightI - 3), game.active.?.pos.y);
    try std.testing.expectEqual(@as(u8, 2), game.last_successful_rotation.?.kick_index);
    try std.testing.expectEqual(@as(i32, -1), game.last_successful_rotation.?.kick.x);
    try std.testing.expectEqual(@as(i32, -1), game.last_successful_rotation.?.kick.y);
    try std.testing.expectEqual(@as(u16, 0), game.lock_delay_elapsed);
    try std.testing.expectEqual(@as(u8, 1), game.lock_move_resets_used);
}

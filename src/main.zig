// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const game = @import("game");
const input = @import("input");

const emscripten = std.os.emscripten;

const screen_width: i32 = 1100;
const screen_height: i32 = 720;
const cell_size: i32 = 24;
const board_x: i32 = 330;
const board_y: i32 = 118;
const board_w: i32 = game.BoardWidthI * cell_size;
const board_h: i32 = @as(i32, @intCast(game.VisibleHeight)) * cell_size;
const game_seed: u64 = 0x5A49_4746_414C_4C21;

const color_bg = rl.Color.init(9, 12, 24, 255);
const color_bg_grid = rl.Color.init(20, 28, 48, 255);
const color_panel = rl.Color.init(18, 25, 43, 235);
const color_panel_soft = rl.Color.init(23, 32, 54, 235);
const color_panel_border = rl.Color.init(67, 84, 125, 255);
const color_board_bg = rl.Color.init(6, 9, 17, 255);
const color_board_grid = rl.Color.init(32, 42, 63, 255);
const color_text = rl.Color.init(230, 237, 255, 255);
const color_text_dim = rl.Color.init(147, 164, 199, 255);
const color_accent = rl.Color.init(91, 214, 255, 255);
const color_warning = rl.Color.init(255, 177, 66, 255);
const color_danger = rl.Color.init(255, 86, 108, 255);

const App = struct {
    state: game.Game,
    controller: input.Controller,
    paused: bool,
    gravity_counter: u16,
    frame_count: u64,

    fn init() App {
        return .{
            .state = game.Game.init(game_seed),
            .controller = .{},
            .paused = false,
            .gravity_counter = 0,
            .frame_count = 0,
        };
    }

    fn updateAndDraw(self: *App) void {
        const frame_input = readFrameInput();
        const input_result = self.controller.applyToGame(&self.state, frame_input, &self.paused, game_seed);

        if (input_result.restarted or input_result.hard_dropped or input_result.paused_toggled or input_result.soft_dropped) {
            self.gravity_counter = 0;
        }

        const should_step = !input_result.restarted and !input_result.paused_toggled and !input_result.hard_dropped and !self.paused and !self.state.game_over;
        if (should_step) {
            const gravity_due = !input_result.soft_dropped and advanceGravityCounter(&self.gravity_counter, self.state.gravityIntervalFrames());
            const step_result = self.state.step(.{ .apply_gravity = gravity_due });
            if (step_result.lock_result != null) self.gravity_counter = 0;
        }

        self.frame_count += 1;

        rl.beginDrawing();
        rl.clearBackground(color_bg);

        drawBackground();
        drawHeader(&self.state, self.frame_count);
        drawHoldPanel(&self.state);
        drawControlsPanel();
        drawBoard(&self.state);
        drawNextPanel(&self.state);
        drawStatusPanel(&self.state, self.paused);

        if (self.state.game_over) {
            drawGameOverOverlay(&self.state);
        } else if (self.paused) {
            drawPauseOverlay();
        }

        rl.endDrawing();
    }
};

var web_app: App = undefined;

pub fn main() void {
    rl.initWindow(screen_width, screen_height, "Zigfall");

    if (builtin.os.tag == .emscripten) {
        web_app = App.init();
        emscripten.emscripten_set_main_loop(updateDrawFrame, 0, 1);
    } else {
        defer rl.closeWindow();
        rl.setTargetFPS(@intCast(input.FixedFps));

        var app = App.init();
        while (!rl.windowShouldClose()) {
            app.updateAndDraw();
        }
    }
}

fn updateDrawFrame() callconv(.c) void {
    web_app.updateAndDraw();
}

fn readFrameInput() input.FrameInput {
    return .{
        .left_down = rl.isKeyDown(.left),
        .right_down = rl.isKeyDown(.right),
        .down_down = rl.isKeyDown(.down),
        .left_pressed = rl.isKeyPressed(.left),
        .right_pressed = rl.isKeyPressed(.right),
        .rotate_cw_pressed = rl.isKeyPressed(.x) or rl.isKeyPressed(.up),
        .rotate_ccw_pressed = rl.isKeyPressed(.z),
        .rotate_180_pressed = rl.isKeyPressed(.a),
        .hold_pressed = rl.isKeyPressed(.c) or rl.isKeyPressed(.left_shift),
        .hard_drop_pressed = rl.isKeyPressed(.space),
        .pause_pressed = rl.isKeyPressed(.p),
        .restart_pressed = rl.isKeyPressed(.r),
    };
}

fn advanceGravityCounter(counter: *u16, interval_frames: u16) bool {
    if (interval_frames <= 1) return true;
    counter.* += 1;
    if (counter.* >= interval_frames) {
        counter.* = 0;
        return true;
    }
    return false;
}

fn drawBackground() void {
    rl.drawRectangle(0, 0, screen_width, 82, rl.Color.init(12, 18, 34, 255));

    var y: i32 = 82;
    while (y < screen_height) : (y += 32) {
        rl.drawLine(0, y, screen_width, y, color_bg_grid.alpha(0.42));
    }

    var x: i32 = 0;
    while (x < screen_width) : (x += 32) {
        rl.drawLine(x, 82, x, screen_height, color_bg_grid.alpha(0.25));
    }
}

fn drawHeader(state: *const game.Game, frame_count: u64) void {
    rl.drawText("ZIGFALL", 36, 22, 30, color_text);
    rl.drawText("Advanced scoring, hold, ghost, DAS/ARR, lock delay", 38, 55, 15, color_text_dim);

    const right_x: i32 = 820;
    rl.drawText(rl.textFormat("FPS %i / fixed %i", .{ rl.getFPS(), @as(i32, input.FixedFps) }), right_x, 22, 18, color_accent);
    rl.drawText(rl.textFormat("frame %u  pieces %u", .{ @as(u32, @truncate(frame_count)), state.pieces_locked }), right_x, 50, 14, color_text_dim);
}

fn drawPanel(x: i32, y: i32, w: i32, h: i32, title: [:0]const u8) void {
    const rec = rect(x, y, w, h);
    rl.drawRectangleRounded(rec, 0.08, 12, color_panel);
    rl.drawRectangleRoundedLinesEx(rec, 0.08, 12, 1.5, color_panel_border.alpha(0.85));
    rl.drawText(title, x + 16, y + 13, 18, color_text);
}

fn drawHoldPanel(state: *const game.Game) void {
    const x: i32 = 40;
    const y: i32 = 112;
    const w: i32 = 250;
    const h: i32 = 160;
    drawPanel(x, y, w, h, "HOLD");

    rl.drawRectangleRounded(rect(x + 18, y + 46, w - 36, 78), 0.12, 10, color_panel_soft);
    rl.drawRectangleRoundedLinesEx(rect(x + 18, y + 46, w - 36, 78), 0.12, 10, 1.0, color_panel_border.alpha(0.5));

    if (state.hold) |kind| {
        drawMiniPiece(kind, x + 26, y + 52, w - 52, 64, 18);
    } else {
        drawCenteredText("EMPTY", x + @divTrunc(w, 2), y + 75, 16, color_text_dim);
    }

    const status = if (state.held_this_piece) "USED UNTIL LOCK" else "READY";
    const status_color = if (state.held_this_piece) color_warning else color_accent;
    drawPill(x + 65, y + 128, 120, 22, status, status_color);
}

fn drawControlsPanel() void {
    const x: i32 = 40;
    const y: i32 = 302;
    const w: i32 = 250;
    const h: i32 = 320;
    drawPanel(x, y, w, h, "CONTROLS");

    var line_y: i32 = y + 50;
    drawHelpLine("Move", "Left / Right", x + 20, line_y);
    line_y += 28;
    drawHelpLine("Soft drop", "Down", x + 20, line_y);
    line_y += 28;
    drawHelpLine("Hard drop", "Space", x + 20, line_y);
    line_y += 28;
    drawHelpLine("Rotate", "X/Up CW, Z CCW", x + 20, line_y);
    line_y += 28;
    drawHelpLine("180", "A", x + 20, line_y);
    line_y += 28;
    drawHelpLine("Hold", "C or Left Shift", x + 20, line_y);
    line_y += 28;
    drawHelpLine("Pause", "P", x + 20, line_y);
    line_y += 28;
    drawHelpLine("Restart", "R", x + 20, line_y);

    rl.drawLine(x + 18, y + h - 38, x + w - 18, y + h - 38, color_panel_border.alpha(0.45));
    rl.drawText(rl.textFormat("DAS %if  ARR %if  Lock %if", .{ @as(i32, input.DasDelayFrames), @as(i32, input.ArrIntervalFrames), @as(i32, game.DefaultLockDelayFrames) }), x + 20, y + h - 25, 13, color_text_dim);
}

fn drawHelpLine(label: [:0]const u8, value: [:0]const u8, x: i32, y: i32) void {
    rl.drawText(label, x, y, 14, color_text_dim);
    rl.drawText(value, x + 88, y - 1, 15, color_text);
}

fn drawBoard(state: *const game.Game) void {
    const frame_x = board_x - 18;
    const frame_y = board_y - 48;
    const frame_w = board_w + 36;
    const frame_h = board_h + 74;

    rl.drawRectangleRounded(rect(frame_x, frame_y, frame_w, frame_h), 0.045, 14, color_panel);
    rl.drawRectangleRoundedLinesEx(rect(frame_x, frame_y, frame_w, frame_h), 0.045, 14, 1.5, color_panel_border);
    rl.drawText("MATRIX", board_x, board_y - 38, 18, color_text);
    rl.drawText("hidden spawn rows above this line", board_x + 82, board_y - 35, 12, color_text_dim);

    rl.drawRectangle(board_x - 5, board_y - 5, board_w + 10, board_h + 10, rl.Color.init(2, 5, 12, 255));
    rl.drawRectangle(board_x - 3, board_y - 3, board_w + 6, board_h + 6, color_panel_border);
    rl.drawRectangle(board_x, board_y, board_w, board_h, color_board_bg);

    drawBoardGrid();
    drawLockedCells(state);

    if (state.ghostPiece()) |ghost| {
        drawGhostPiece(ghost);
    }
    if (state.active) |piece| {
        drawPiece(piece, pieceColor(piece.kind));
    }

    drawHiddenBoundary();
}

fn drawBoardGrid() void {
    var x: i32 = 0;
    while (x <= game.BoardWidthI) : (x += 1) {
        const screen_x = board_x + x * cell_size;
        rl.drawLine(screen_x, board_y, screen_x, board_y + board_h, color_board_grid);
    }

    var y: i32 = 0;
    while (y <= @as(i32, @intCast(game.VisibleHeight))) : (y += 1) {
        const screen_y = board_y + y * cell_size;
        rl.drawLine(board_x, screen_y, board_x + board_w, screen_y, color_board_grid);
    }
}

fn drawLockedCells(state: *const game.Game) void {
    var y: usize = game.HiddenRows;
    while (y < game.BoardHeight) : (y += 1) {
        const visible_y: i32 = @intCast(y - game.HiddenRows);
        var x: usize = 0;
        while (x < game.BoardWidth) : (x += 1) {
            if (state.board[y][x]) |kind| {
                const screen_x = board_x + @as(i32, @intCast(x)) * cell_size;
                const screen_y = board_y + visible_y * cell_size;
                drawCell(screen_x, screen_y, cell_size, pieceColor(kind));
            }
        }
    }
}

fn drawHiddenBoundary() void {
    rl.drawLine(board_x, board_y, board_x + board_w, board_y, color_warning);
    rl.drawLine(board_x, board_y + 1, board_x + board_w, board_y + 1, color_warning.alpha(0.55));

    var segment_x = board_x;
    while (segment_x < board_x + board_w) : (segment_x += 18) {
        rl.drawLine(segment_x, board_y - 8, @min(segment_x + 10, board_x + board_w), board_y - 8, color_warning.alpha(0.75));
    }

    rl.drawText("SPAWN / HIDDEN", board_x + 4, board_y - 22, 11, color_warning);
}

fn drawPiece(piece: game.ActivePiece, color: rl.Color) void {
    const blocks = game.blockPositions(piece);
    for (blocks) |point| {
        const screen_pos = blockScreenPosition(point) orelse continue;
        drawCell(screen_pos.x, screen_pos.y, cell_size, color);
    }
}

fn drawGhostPiece(piece: game.ActivePiece) void {
    const color = pieceColor(piece.kind);
    const blocks = game.blockPositions(piece);
    for (blocks) |point| {
        const screen_pos = blockScreenPosition(point) orelse continue;
        rl.drawRectangle(screen_pos.x + 6, screen_pos.y + 6, cell_size - 12, cell_size - 12, color.alpha(0.16));
        rl.drawRectangleLines(screen_pos.x + 3, screen_pos.y + 3, cell_size - 6, cell_size - 6, color.alpha(0.72));
        rl.drawRectangleLines(screen_pos.x + 6, screen_pos.y + 6, cell_size - 12, cell_size - 12, color.alpha(0.45));
    }
}

fn blockScreenPosition(point: game.Point) ?struct { x: i32, y: i32 } {
    if (point.x < 0 or point.x >= game.BoardWidthI) return null;
    if (point.y < game.HiddenRowsI or point.y >= game.BoardHeightI) return null;

    return .{
        .x = board_x + point.x * cell_size,
        .y = board_y + (point.y - game.HiddenRowsI) * cell_size,
    };
}

fn drawCell(screen_x: i32, screen_y: i32, size: i32, color: rl.Color) void {
    rl.drawRectangle(screen_x + 1, screen_y + 1, size - 2, size - 2, color);
    rl.drawRectangle(screen_x + 2, screen_y + 2, size - 4, @max(2, @divTrunc(size, 3)), color.brightness(0.22));
    rl.drawRectangle(screen_x + 2, screen_y + size - 6, size - 4, 4, color.brightness(-0.26));
    rl.drawRectangleLines(screen_x, screen_y, size, size, color.brightness(-0.48));
}

fn drawNextPanel(state: *const game.Game) void {
    const x: i32 = 610;
    const y: i32 = 112;
    const w: i32 = 172;
    const h: i32 = 426;
    drawPanel(x, y, w, h, "NEXT");

    for (state.next, 0..) |kind, i| {
        const row_y = y + 48 + @as(i32, @intCast(i)) * 70;
        const row_h: i32 = 58;
        rl.drawRectangleRounded(rect(x + 14, row_y, w - 28, row_h), 0.13, 8, color_panel_soft);
        rl.drawRectangleRoundedLinesEx(rect(x + 14, row_y, w - 28, row_h), 0.13, 8, 1.0, color_panel_border.alpha(0.4));
        drawMiniPiece(kind, x + 22, row_y + 6, w - 44, row_h - 12, 14);
    }
}

fn drawStatusPanel(state: *const game.Game, paused: bool) void {
    const x: i32 = 810;
    const y: i32 = 112;
    const w: i32 = 250;
    const h: i32 = 568;
    drawPanel(x, y, w, h, "STATUS");

    var line_y: i32 = y + 48;
    drawMetric("State", if (state.game_over) "game over" else if (paused) "paused" else "playing", x + 18, line_y, if (state.game_over) color_danger else if (paused) color_warning else color_accent);
    line_y += 25;
    drawMetric("Score", rl.textFormat("%u", .{state.score}), x + 18, line_y, color_text);
    line_y += 25;
    drawMetric("Lines", rl.textFormat("%u", .{state.total_lines_cleared}), x + 18, line_y, color_text);
    line_y += 25;
    drawMetric("Level", rl.textFormat("%i", .{@as(i32, state.level)}), x + 18, line_y, color_text);
    line_y += 25;
    drawMetric("Speed", rl.textFormat("%if/cell", .{@as(i32, state.gravityIntervalFrames())}), x + 18, line_y, color_text);
    line_y += 25;
    drawMetric("Lock", rl.textFormat("%i/%i  resets %i", .{ @as(i32, state.lock_delay_elapsed), @as(i32, state.lock_delay_frames), @as(i32, state.max_lock_move_resets - state.lock_move_resets_used) }), x + 18, line_y, color_text_dim);
    line_y += 25;
    drawMetric("Combo", comboText(state.combo_counter), x + 18, line_y, if (state.combo_counter >= 1) color_warning else color_text_dim);
    line_y += 25;
    drawMetric("B2B", if (state.back_to_back_active) "active" else "off", x + 18, line_y, if (state.back_to_back_active) color_warning else color_text_dim);

    line_y += 38;
    drawSectionTitle("LAST LOCK", x + 18, line_y);
    line_y += 26;

    if (state.last_lock_result) |result| {
        drawMetric("Piece", pieceLabel(result.piece_kind), x + 18, line_y, pieceColor(result.piece_kind));
        line_y += 23;
        drawMetric("Clear", clearSummary(result), x + 18, line_y, if (result.lines_cleared > 0) color_accent else color_text_dim);
        line_y += 23;
        drawMetric("T-spin", tSpinValue(result.t_spin_kind), x + 18, line_y, if (result.t_spin_kind == .none) color_text_dim else color_warning);
        line_y += 23;
        drawMetric("Perfect", if (result.perfect_clear) "YES" else "no", x + 18, line_y, if (result.perfect_clear) color_warning else color_text_dim);
        line_y += 23;
        drawMetric("Output", rl.textFormat("+%i", .{@as(i32, result.attack_lines)}), x + 18, line_y, if (result.attack_lines > 0) color_danger else color_text_dim);
        line_y += 23;
        drawMetric("Score +", rl.textFormat("%u", .{result.score_delta}), x + 18, line_y, color_text);
        line_y += 23;
        drawMetric("Base/B2B", rl.textFormat("%u / %u", .{ result.base_score_points, result.back_to_back_bonus_points }), x + 18, line_y, color_text_dim);
        line_y += 23;
        drawMetric("Combo/PC", rl.textFormat("%u / %u", .{ result.combo_bonus_points, result.perfect_clear_bonus_points }), x + 18, line_y, color_text_dim);
        line_y += 23;
        drawMetric("Drop", rl.textFormat("HD %u:%u  SD %u", .{ result.hard_drop_cells, result.hard_drop_points, result.soft_drop_points }), x + 18, line_y, color_text_dim);
    } else {
        drawMetric("Clear", "none yet", x + 18, line_y, color_text_dim);
    }

    rl.drawLine(x + 18, y + h - 54, x + w - 18, y + h - 54, color_panel_border.alpha(0.45));
    rl.drawText(rl.textFormat("FPS: %i    fixed step: %i", .{ rl.getFPS(), @as(i32, input.FixedFps) }), x + 18, y + h - 37, 14, color_accent);
    rl.drawText(exitInstructionText(), x + 18, y + h - 18, 12, color_text_dim);
}

fn drawMetric(label: [:0]const u8, value: [:0]const u8, x: i32, y: i32, value_color: rl.Color) void {
    rl.drawText(label, x, y, 14, color_text_dim);
    rl.drawText(value, x + 82, y - 2, 16, value_color);
}

fn drawSectionTitle(text: [:0]const u8, x: i32, y: i32) void {
    rl.drawText(text, x, y, 15, color_accent);
    rl.drawLine(x + 82, y + 9, x + 214, y + 9, color_panel_border.alpha(0.55));
}

fn drawMiniPiece(kind: game.PieceKind, area_x: i32, area_y: i32, area_w: i32, area_h: i32, mini_cell: i32) void {
    const offsets = game.shapeOffsets(kind, .spawn);
    var min_x = offsets[0].x;
    var max_x = offsets[0].x;
    var min_y = offsets[0].y;
    var max_y = offsets[0].y;

    for (offsets) |point| {
        min_x = @min(min_x, point.x);
        max_x = @max(max_x, point.x);
        min_y = @min(min_y, point.y);
        max_y = @max(max_y, point.y);
    }

    const piece_w = (max_x - min_x + 1) * mini_cell;
    const piece_h = (max_y - min_y + 1) * mini_cell;
    const start_x = area_x + @divTrunc(area_w - piece_w, 2) - min_x * mini_cell;
    const start_y = area_y + @divTrunc(area_h - piece_h, 2) - min_y * mini_cell;
    const color = pieceColor(kind);

    for (offsets) |point| {
        drawCell(start_x + point.x * mini_cell, start_y + point.y * mini_cell, mini_cell, color);
    }
}

fn drawPill(x: i32, y: i32, w: i32, h: i32, text: [:0]const u8, color: rl.Color) void {
    rl.drawRectangleRounded(rect(x, y, w, h), 0.45, 12, color.alpha(0.16));
    rl.drawRectangleRoundedLinesEx(rect(x, y, w, h), 0.45, 12, 1.0, color.alpha(0.85));
    drawCenteredText(text, x + @divTrunc(w, 2), y + 5, 12, color);
}

fn drawPauseOverlay() void {
    drawOverlay("PAUSED", "Press P to resume", color_warning);
}

fn drawGameOverOverlay(state: *const game.Game) void {
    rl.drawRectangle(0, 0, screen_width, screen_height, rl.Color.init(0, 0, 0, 145));
    const x = board_x - 56;
    const y = board_y + 150;
    const w: i32 = board_w + 112;
    const h: i32 = 168;
    rl.drawRectangleRounded(rect(x, y, w, h), 0.09, 14, rl.Color.init(24, 12, 22, 238));
    rl.drawRectangleRoundedLinesEx(rect(x, y, w, h), 0.09, 14, 2.0, color_danger);
    drawCenteredText("GAME OVER", x + @divTrunc(w, 2), y + 26, 34, color_danger);
    drawCenteredText(rl.textFormat("Score %u  |  Lines %u", .{ state.score, state.total_lines_cleared }), x + @divTrunc(w, 2), y + 78, 18, color_text);
    drawCenteredText("Press R to restart", x + @divTrunc(w, 2), y + 112, 18, color_text_dim);
    drawCenteredText(exitOverlayText(), x + @divTrunc(w, 2), y + 137, 14, color_text_dim);
}

fn exitInstructionText() [:0]const u8 {
    return if (builtin.os.tag == .emscripten) "Close browser tab to exit" else "ESC closes the window";
}

fn exitOverlayText() [:0]const u8 {
    return if (builtin.os.tag == .emscripten) "Close browser tab to exit" else "ESC exits";
}

fn drawOverlay(title: [:0]const u8, subtitle: [:0]const u8, accent: rl.Color) void {
    rl.drawRectangle(0, 0, screen_width, screen_height, rl.Color.init(0, 0, 0, 115));
    const x = board_x - 44;
    const y = board_y + 172;
    const w: i32 = board_w + 88;
    const h: i32 = 124;
    rl.drawRectangleRounded(rect(x, y, w, h), 0.1, 14, rl.Color.init(15, 22, 40, 238));
    rl.drawRectangleRoundedLinesEx(rect(x, y, w, h), 0.1, 14, 2.0, accent);
    drawCenteredText(title, x + @divTrunc(w, 2), y + 28, 34, accent);
    drawCenteredText(subtitle, x + @divTrunc(w, 2), y + 78, 18, color_text);
}

fn drawCenteredText(text: [:0]const u8, center_x: i32, y: i32, size: i32, color: rl.Color) void {
    rl.drawText(text, center_x - @divTrunc(rl.measureText(text, size), 2), y, size, color);
}

fn comboText(combo: i32) [:0]const u8 {
    if (combo < 0) return "none";
    return rl.textFormat("x%i", .{combo});
}

fn clearSummary(result: game.LockResult) [:0]const u8 {
    return switch (result.t_spin_kind) {
        .none => lineClearLabel(result.lines_cleared),
        .mini => switch (result.lines_cleared) {
            0 => "Mini T-spin",
            1 => "Mini T-spin Single",
            2 => "Mini T-spin Double",
            else => "Mini T-spin",
        },
        .full => switch (result.lines_cleared) {
            0 => "T-spin",
            1 => "T-spin Single",
            2 => "T-spin Double",
            3 => "T-spin Triple",
            else => "T-spin",
        },
    };
}

fn lineClearLabel(lines: u8) [:0]const u8 {
    return switch (lines) {
        0 => "No clear",
        1 => "Single",
        2 => "Double",
        3 => "Triple",
        4 => "Quad",
        else => "Multi clear",
    };
}

fn tSpinValue(kind: game.TSpinKind) [:0]const u8 {
    return switch (kind) {
        .none => "none",
        .mini => "mini",
        .full => "full",
    };
}

fn pieceLabel(kind: game.PieceKind) [:0]const u8 {
    return switch (kind) {
        .i => "I",
        .o => "O",
        .t => "T",
        .s => "S",
        .z => "Z",
        .j => "J",
        .l => "L",
    };
}

fn pieceColor(kind: game.PieceKind) rl.Color {
    return switch (kind) {
        .i => rl.Color.init(79, 219, 255, 255),
        .o => rl.Color.init(255, 216, 80, 255),
        .t => rl.Color.init(194, 114, 255, 255),
        .s => rl.Color.init(84, 222, 132, 255),
        .z => rl.Color.init(255, 89, 113, 255),
        .j => rl.Color.init(89, 133, 255, 255),
        .l => rl.Color.init(255, 160, 70, 255),
    };
}

fn rect(x: i32, y: i32, w: i32, h: i32) rl.Rectangle {
    return rl.Rectangle.init(
        @as(f32, @floatFromInt(x)),
        @as(f32, @floatFromInt(y)),
        @as(f32, @floatFromInt(w)),
        @as(f32, @floatFromInt(h)),
    );
}

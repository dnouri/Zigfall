// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const app_controls = @import("app_controls");
const game = @import("game");
const input = @import("input");
const lockstep = @import("lockstep");
const match_mod = @import("match");
const online_session = @import("online_session");
const protocol = @import("protocol");
const web_invite = @import("web_invite");
const web_transport = @import("web_transport");

const emscripten = std.os.emscripten;

// Zig 0.16's default panic handler currently pulls in std IO paths that fail
// the wasm32-emscripten ReleaseSmall build. Keep formatted panic messages by
// routing web panics to the browser console, while native keeps the default.
pub const panic = std.debug.FullPanic(appPanic);

extern fn emscripten_console_error(utf8String: [*:0]const u8) void;

fn appPanic(message: []const u8, first_trace_addr: ?usize) noreturn {
    if (comptime builtin.os.tag == .emscripten) {
        webConsoleError(message);
        @trap();
    }
    std.debug.defaultPanic(message, first_trace_addr);
}

fn webConsoleError(message: []const u8) void {
    const max_len = 4095;
    var buffer: [max_len + 1:0]u8 = undefined;
    const len = @min(message.len, max_len);
    @memcpy(buffer[0..len], message[0..len]);
    buffer[len] = 0;
    emscripten_console_error(&buffer);
}

const screen_width: i32 = 1100;
const screen_height: i32 = 720;
const single_cell_size: i32 = 24;
const versus_cell_size: i32 = 18;
const game_seed: u64 = 0x5A49_4746_414C_4C21;
const p2_game_seed: u64 = 0x5457_4F50_4C41_5932;
const local_garbage_seed: u64 = 0x4C4F_4341_4C56_5333;
const online_hash_seed: u64 = 0x4F4E_4C49_4E45_5036;
const online_state_hash_interval_frames: u64 = 60;
const online_max_steps_per_frame: usize = 4;
const online_input_batch_target_count: u8 = 4;
const online_input_batch_max_hold_frames: u8 = 3;
const online_result_drain_frames: u16 = 120;
const online_notice_frames: u16 = 180;
const online_message_capacity: usize = 192;
const online_notice_capacity: usize = 128;

const single_board_layout = BoardLayout{ .x = 330, .y = 118, .cell = single_cell_size };
const versus_p1_board_layout = BoardLayout{ .x = 180, .y = 160, .cell = versus_cell_size };
const versus_p2_board_layout = BoardLayout{ .x = 740, .y = 160, .cell = versus_cell_size };

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

const BoardLayout = struct {
    x: i32,
    y: i32,
    cell: i32,

    fn width(self: BoardLayout) i32 {
        return game.BoardWidthI * self.cell;
    }

    fn height(self: BoardLayout) i32 {
        return @as(i32, @intCast(game.VisibleHeight)) * self.cell;
    }
};

const AppMode = app_controls.AppMode;

const Mode = union(AppMode) {
    single: SinglePlayerState,
    local_versus: LocalVersusState,
    online: OnlineState,
};

const SinglePlayerState = struct {
    state: game.Game,
    controller: input.Controller,
    paused: bool,
    gravity_counter: u16,
    frame_count: u64,

    fn init() SinglePlayerState {
        return .{
            .state = game.Game.init(game_seed),
            .controller = .{},
            .paused = false,
            .gravity_counter = 0,
            .frame_count = 0,
        };
    }

    fn update(self: *SinglePlayerState) void {
        const frame_input = readSinglePlayerInput();
        const input_result = self.controller.applyToGame(&self.state, frame_input, &self.paused, game_seed);

        if (input_result.restarted or input_result.hard_dropped or input_result.paused_toggled or input_result.soft_dropped) {
            self.gravity_counter = 0;
        }

        const should_step = !input_result.restarted and !input_result.paused_toggled and !input_result.hard_dropped and !self.paused and !self.state.game_over;
        if (should_step) {
            const gravity_due = !input_result.soft_dropped and match_mod.advanceGravityCounter(&self.gravity_counter, self.state.gravityIntervalFrames());
            const step_result = self.state.step(.{ .apply_gravity = gravity_due });
            if (step_result.lock_result != null) self.gravity_counter = 0;
        }

        self.frame_count += 1;
    }

    fn draw(self: *const SinglePlayerState) void {
        drawSingleHeader(&self.state, self.frame_count);
        drawHoldPanel(&self.state);
        drawControlsPanel();
        drawBoard(&self.state, single_board_layout, "MATRIX", "hidden spawn rows above this line");
        drawNextPanel(&self.state);
        drawStatusPanel(&self.state, self.paused);

        if (self.state.game_over) {
            drawGameOverOverlay(&self.state);
        } else if (self.paused) {
            drawPauseOverlay();
        }
    }
};

const LocalVersusState = struct {
    match_state: match_mod.Match,
    last_step_result: match_mod.MatchStepResult = .{},

    fn init() LocalVersusState {
        return .{
            .match_state = match_mod.Match.init(localVersusSettings()) catch unreachable,
        };
    }

    fn update(self: *LocalVersusState) void {
        self.last_step_result = self.match_state.step(readLocalVersusInput());
    }

    fn draw(self: *const LocalVersusState) void {
        drawVersusHeader(&self.match_state);
        drawVersusPlayer(.p1, &self.match_state, self.last_step_result.players[0]);
        drawVersusPlayer(.p2, &self.match_state, self.last_step_result.players[1]);
        drawVersusControlsStrip();
        drawMatchOverlay(&self.match_state);
    }
};

const OnlineTerminal = enum {
    none,
    finished,
    disconnected,
    desynced,
    unsupported,
    failed,
};

const OnlineTerminalPacket = union(enum) {
    none,
    result,
    desync,
    disconnect: u8,
};

const OnlineState = struct {
    role: ?online_session.Role = null,
    session: ?online_session.Session = null,
    last_step_result: match_mod.MatchStepResult = .{},
    room_buf: [web_invite.MaxRoomIdLength]u8 = undefined,
    room_len: usize = 0,
    join_url_buf: [web_invite.MaxJoinUrlLength]u8 = undefined,
    join_url_len: usize = 0,
    receive_buf: [web_transport.MaxPacketSize]u8 = undefined,
    message_buf: [online_message_capacity]u8 = undefined,
    message_len: usize = 0,
    notice_buf: [online_notice_capacity]u8 = undefined,
    notice_len: usize = 0,
    notice_frames_left: u16 = 0,
    sent_setup: bool = false,
    sent_ack: bool = false,
    sent_result: bool = false,
    sent_desync: bool = false,
    pending_remote_result: ?protocol.Result = null,
    pending_input_batch: online_session.InputBatcher = .{},
    result_drain_frames_left: u16 = 0,
    next_hash_frame: u64 = online_state_hash_interval_frames,
    ever_had_peer: bool = false,
    terminal: OnlineTerminal = .none,

    fn startHost(self: *OnlineState) void {
        self.* = .{};
        if (comptime builtin.os.tag != .emscripten) {
            self.markTerminal(.unsupported, "Online invites are web-only in this build.", .{});
            return;
        }

        const room_id = web_invite.createHostRoom(&self.room_buf) catch |err| {
            self.markTerminal(.failed, "Could not create invite room: {s}", .{@errorName(err)});
            return;
        };
        self.room_len = room_id.len;
        self.refreshJoinUrl();

        const settings = onlineSettingsForRoom(room_id);
        const match_id = onlineMatchIdForRoom(room_id);
        self.session = online_session.Session.initHost(match_id, settings) catch |err| {
            self.markTerminal(.failed, "Could not create online session: {s}", .{@errorName(err)});
            return;
        };
        self.role = .host;

        web_transport.connect(room_id) catch |err| {
            self.markTerminal(.failed, "Could not connect invite room: {s}", .{@errorName(err)});
            return;
        };

        self.setMessage("Invite ready. Share the link and wait for P2.", .{});
    }

    fn startJoinRoom(self: *OnlineState, room_id: []const u8) void {
        self.* = .{};
        if (comptime builtin.os.tag != .emscripten) {
            self.markTerminal(.unsupported, "Online join links are web-only in this build.", .{});
            return;
        }
        if (!self.setRoom(room_id)) return;
        self.refreshJoinUrl();
        self.session = online_session.Session.initJoinerForMatch(onlineMatchIdForRoom(self.roomId()));
        self.role = .joiner;

        web_transport.connect(self.roomId()) catch |err| {
            self.markTerminal(.failed, "Could not join invite room: {s}", .{@errorName(err)});
            return;
        };

        self.setMessage("Joining invite. Waiting for host setup.", .{});
    }

    fn startJoinError(self: *OnlineState, err: anyerror) void {
        self.* = .{};
        self.markTerminal(.failed, "Invalid join link: {s}", .{@errorName(err)});
    }

    fn deinit(self: *OnlineState) void {
        if (self.terminal == .none) self.sendDisconnectBestEffort(1);
        web_transport.disconnect();
    }

    fn update(self: *OnlineState) void {
        const online_input = readOnlineInput();
        self.tickNotice();
        self.handleShellActions(online_input);
        if (self.terminal != .none) return;

        self.pollTransport();
        if (self.terminal != .none) return;

        self.updateTransportHealth();
        if (self.terminal != .none) return;

        self.driveHandshake();
        if (self.terminal != .none) return;

        self.driveLockstep(online_input.frame);
    }

    fn draw(self: *const OnlineState) void {
        if (self.lockstepPeerConst()) |peer| {
            drawOnlineHeader(self, &peer.match);
            drawVersusPlayer(.p1, &peer.match, self.last_step_result.players[0]);
            drawVersusPlayer(.p2, &peer.match, self.last_step_result.players[1]);
            drawOnlineControlsStrip(self);
            if (self.terminal == .none) drawOnlineMatchOverlay(self, &peer.match);
        } else {
            drawOnlineHeader(self, null);
            drawOnlineWaitingPanel(self);
            drawOnlineControlsStrip(self);
        }

        if (self.terminal != .none) {
            drawOnlineTerminalOverlay(self);
        } else if (!self.isPlaying()) {
            drawOnlineWaitingOverlay(self);
        }
        if (self.notice_frames_left > 0 and self.notice_len > 0) drawOnlineNotice(self.notice());
    }

    fn handleShellActions(self: *OnlineState, online_input: app_controls.OnlineInput) void {
        if (online_input.copy_link_pressed) self.copyJoinLink();
        if (online_input.restart_pressed) {
            self.setNotice("Online rematch/restart is not available yet; use 1/2/3 for a fresh mode.", .{});
        }
    }

    fn updateTransportHealth(self: *OnlineState) void {
        const status = web_transport.status();
        if (web_transport.peerCount() > 0) self.ever_had_peer = true;
        // Trystero can report noPeer immediately after delivering a final result.
        // Let local result validation/drain finish before treating peer leave as terminal.
        const defer_peer_leave_disconnect = self.shouldDeferPeerLeaveDisconnect();

        switch (status) {
            .busy => {
                self.enterTerminal(.failed, .{ .disconnect = 2 }, "Extra peer joined this room; match stopped. Create a new invite.", .{});
                return;
            },
            .missing_js => {
                self.enterTerminal(.failed, .none, "Web transport helper is missing; reload the page.", .{});
                return;
            },
            .unavailable => {
                self.enterTerminal(.unsupported, .none, "Online transport is unavailable in this build.", .{});
                return;
            },
            .disconnected => if (self.ever_had_peer and !defer_peer_leave_disconnect) {
                self.enterTerminal(.disconnected, .none, "Opponent disconnected.", .{});
                return;
            },
            .connecting, .connected => {},
        }

        switch (web_transport.lastError()) {
            .no_peer => if (self.ever_had_peer and !defer_peer_leave_disconnect) {
                self.enterTerminal(.disconnected, .none, "Opponent disconnected.", .{});
            },
            .queue_full => {
                self.enterTerminal(.failed, .{ .disconnect = 3 }, "Network receive backlog overflowed; match stopped before hiding a lost packet.", .{});
            },
            .send_failed => {
                self.enterTerminal(.failed, .{ .disconnect = 3 }, "Transport send failed; match stopped.", .{});
            },
            else => {},
        }
    }

    fn pollTransport(self: *OnlineState) void {
        var packets_read: usize = 0;
        while (packets_read < 256) : (packets_read += 1) {
            const maybe_packet = web_transport.poll(&self.receive_buf) catch |err| {
                self.enterTerminal(.failed, .{ .disconnect = 6 }, "Receive failed: {s}", .{@errorName(err)});
                return;
            };
            const bytes = maybe_packet orelse break;
            self.handlePacket(bytes);
            if (self.terminal != .none) return;
        }
    }

    fn handlePacket(self: *OnlineState, bytes: []const u8) void {
        const ignore_stale = online_session.shouldIgnorePacketForKnownMatch(self.currentMatchId(), bytes) catch |err| {
            self.enterTerminal(.failed, .{ .disconnect = 8 }, "Malformed network packet header: {s}", .{@errorName(err)});
            return;
        };
        if (ignore_stale) return;

        const packet = protocol.decode(bytes) catch |err| {
            self.enterTerminal(.failed, .{ .disconnect = 9 }, "Malformed network packet: {s}", .{@errorName(err)});
            return;
        };

        switch (packet) {
            .setup => |setup| self.handleSetup(setup),
            .ack => |ack| self.handleAck(ack),
            .input_batch, .state_hash, .desync => self.handleRuntimePacket(bytes),
            .disconnect => |disconnect| self.handleDisconnect(disconnect),
            .result => |result| self.handleResult(result),
        }
    }

    fn handleSetup(self: *OnlineState, setup: protocol.Setup) void {
        if (self.role != .joiner) {
            self.enterTerminal(.failed, .{ .disconnect = 14 }, "Unexpected setup packet from peer.", .{});
            return;
        }
        var session = self.sessionPtr() orelse return;
        switch (session.state) {
            .waiting_for_setup => {},
            .setup_received, .playing => return,
            .waiting_for_ack => {
                self.enterTerminal(.failed, .{ .disconnect = 15 }, "Joiner received setup while waiting for ack.", .{});
                return;
            },
        }

        session.acceptSetup(setup) catch |err| {
            self.enterTerminal(.failed, .{ .disconnect = 16 }, "Host setup rejected: {s}", .{@errorName(err)});
            return;
        };
        const ack = session.encodeJoinerAck() catch |err| {
            self.enterTerminal(.failed, .{ .disconnect = 17 }, "Could not encode join ack: {s}", .{@errorName(err)});
            return;
        };
        if (!self.sendPacketBytes(ack.slice())) return;
        self.sent_ack = true;
        self.next_hash_frame = online_state_hash_interval_frames;
        self.setMessage("Setup accepted. Online match started as P2.", .{});
    }

    fn handleAck(self: *OnlineState, ack: protocol.Ack) void {
        if (self.role != .host) return;
        var session = self.sessionPtr() orelse return;
        switch (session.state) {
            .waiting_for_ack => {},
            .playing => return,
            else => {
                self.enterTerminal(.failed, .{ .disconnect = 18 }, "Host received ack before setup was ready.", .{});
                return;
            },
        }
        session.acceptAck(ack) catch |err| {
            self.enterTerminal(.failed, .{ .disconnect = 19 }, "Join ack rejected: {s}", .{@errorName(err)});
            return;
        };
        self.next_hash_frame = online_state_hash_interval_frames;
        self.setMessage("Joiner acknowledged setup. Online match started as P1.", .{});
    }

    fn handleRuntimePacket(self: *OnlineState, bytes: []const u8) void {
        if (!self.isPlaying()) return;
        var peer = self.lockstepPeer() orelse return;
        peer.receiveBytes(bytes) catch |err| {
            self.handleLockstepError(err);
            return;
        };
        self.handlePeerStatus();
    }

    fn handleDisconnect(self: *OnlineState, disconnect: protocol.Disconnect) void {
        if (self.role) |role| {
            online_session.validateLifecycleSender(role, disconnect.sender_slot) catch |err| {
                self.enterTerminal(.failed, .{ .disconnect = 10 }, "Disconnect sender rejected: {s}", .{@errorName(err)});
                return;
            };
        } else return;
        // A best-effort lifecycle disconnect may be queued behind a final result
        // when the peer closes quickly; do not let it overwrite result handling.
        if (self.shouldDeferPeerLeaveDisconnect()) return;
        self.enterTerminal(.disconnected, .none, "Opponent disconnected at frame {}.", .{@as(u32, @truncate(disconnect.last_frame_cursor))});
    }

    fn handleResult(self: *OnlineState, result: protocol.Result) void {
        const role = self.role orelse return;
        const peer = self.lockstepPeerConst() orelse return;
        if (self.pending_remote_result) |pending| {
            if (!std.meta.eql(pending, result)) {
                self.enterTerminal(.failed, .{ .disconnect = 11 }, "Opponent sent conflicting result packets.", .{});
                return;
            }
        }

        switch (online_session.validateRemoteResult(role, peer, result) catch |err| {
            self.handleRemoteResultValidationError(err);
            return;
        }) {
            .accepted => {
                self.pending_remote_result = result;
                self.finishOnlineMatch();
            },
            .pending_local_result => {
                self.pending_remote_result = result;
                self.setNotice("Opponent reported a result; waiting for local lockstep to catch up.", .{});
            },
        }
    }

    fn driveHandshake(self: *OnlineState) void {
        var session = self.sessionPtr() orelse return;
        if (self.role == .host and session.state == .waiting_for_ack and web_transport.status() == .connected and !self.sent_setup) {
            const setup = session.encodeSetupPacket() catch |err| {
                self.enterTerminal(.failed, .{ .disconnect = 20 }, "Could not encode host setup: {s}", .{@errorName(err)});
                return;
            };
            if (!self.sendPacketBytes(setup.slice())) return;
            self.sent_setup = true;
            self.setMessage("Setup sent. Waiting for P2 ack.", .{});
        }
    }

    fn driveLockstep(self: *OnlineState, frame_input: input.FrameInput) void {
        if (!self.isPlaying()) return;
        var peer = self.lockstepPeer() orelse return;
        if (peer.match.outcome != null) {
            self.finishOnlineMatch();
            return;
        }

        self.pending_input_batch.noteFrameHeld();
        if (self.pending_input_batch.isFull()) {
            if (!self.sendPendingInputBatch()) return;
        }

        if (peer.canSampleLocalInput() and !self.pending_input_batch.isFull()) {
            const sample = peer.sampleLocalInputFrame(frame_input) catch |err| {
                self.handleLockstepError(err);
                return;
            };
            self.pending_input_batch.append(sample) catch |err| {
                self.handleLockstepError(err);
                return;
            };
        } else if (peer.canSampleLocalInput()) {
            self.setNotice("Network input backlog is full; waiting for transport to drain.", .{});
        }

        if (self.pending_input_batch.shouldFlush(online_input_batch_target_count, online_input_batch_max_hold_frames)) {
            if (!self.sendPendingInputBatch()) return;
        }

        const advanced = peer.stepAvailableMax(online_max_steps_per_frame) catch |err| {
            self.handleLockstepError(err);
            return;
        };
        self.last_step_result = if (advanced > 0) peer.last_step_result else .{};
        self.handlePeerStatus();
        if (self.terminal != .none) return;

        self.sendDueStateHash(peer);
        if (self.terminal != .none) return;

        if (peer.match.outcome != null) self.finishOnlineMatch();
    }

    fn sendDueStateHash(self: *OnlineState, peer: *lockstep.Peer) void {
        const frame_cursor = peer.frameCursor();
        if (frame_cursor < self.next_hash_frame) return;
        const hash_packet = peer.makeStateHashPacket() catch |err| {
            self.handleLockstepError(err);
            return;
        };
        if (!self.sendPacketBytes(hash_packet.slice())) return;
        while (self.next_hash_frame <= frame_cursor) {
            self.next_hash_frame += online_state_hash_interval_frames;
        }
    }

    fn sendPendingInputBatch(self: *OnlineState) bool {
        if (!self.pending_input_batch.hasPending()) return true;
        const encoded = self.pending_input_batch.encode() catch |err| {
            self.handleLockstepError(err);
            return false;
        };
        if (!self.sendPacketBytes(encoded.slice())) return false;
        self.pending_input_batch.clear();
        return true;
    }

    fn flushPendingInputBestEffort(self: *OnlineState) void {
        if (!self.pending_input_batch.hasPending()) return;
        const encoded = self.pending_input_batch.encode() catch {
            self.pending_input_batch.clear();
            return;
        };
        web_transport.send(encoded.slice()) catch {};
        self.pending_input_batch.clear();
    }

    fn finishOnlineMatch(self: *OnlineState) void {
        if (self.terminal != .none) return;
        if (self.pending_remote_result != null) {
            if (!self.validatePendingRemoteResult()) return;
            if (!self.sent_result) {
                self.flushPendingInputBestEffort();
                self.sendResultBestEffort();
                self.result_drain_frames_left = online_result_drain_frames;
                self.setMessage("Match result validated. Closing connection shortly.", .{});
            }
            if (self.result_drain_frames_left > 0) {
                self.result_drain_frames_left -= 1;
                return;
            }
            self.enterTerminal(.finished, .none, "Match complete. Online rematch is not implemented yet.", .{});
            return;
        }

        if (!self.sent_result) {
            self.flushPendingInputBestEffort();
            self.sendResultBestEffort();
            self.result_drain_frames_left = online_result_drain_frames;
            self.setMessage("Match complete locally. Waiting briefly for opponent result.", .{});
        }
        if (self.result_drain_frames_left > 0) {
            self.result_drain_frames_left -= 1;
            return;
        }
        self.enterTerminal(.finished, .none, "Match complete. Opponent result was not received before disconnect.", .{});
    }

    fn validatePendingRemoteResult(self: *OnlineState) bool {
        const result = self.pending_remote_result orelse return true;
        const role = self.role orelse return true;
        const peer = self.lockstepPeerConst() orelse return true;
        switch (online_session.validateRemoteResult(role, peer, result) catch |err| {
            self.handleRemoteResultValidationError(err);
            return false;
        }) {
            .accepted => return true,
            .pending_local_result => return true,
        }
    }

    fn handleRemoteResultValidationError(self: *OnlineState, err: anyerror) void {
        switch (err) {
            error.ResultOutcomeMismatch, error.ResultFrameCursorMismatch, error.ResultStateHashMismatch => {
                self.enterTerminal(.desynced, .desync, "Opponent result disagreed with local final state: {s}", .{@errorName(err)});
            },
            error.InvalidResultSenderSlot => {
                self.enterTerminal(.failed, .{ .disconnect = 12 }, "Opponent result sender rejected: {s}", .{@errorName(err)});
            },
            error.WrongMatchId => {},
            else => {
                self.enterTerminal(.failed, .{ .disconnect = 13 }, "Opponent result rejected: {s}", .{@errorName(err)});
            },
        }
    }

    fn handleLockstepError(self: *OnlineState, err: anyerror) void {
        self.handlePeerStatus();
        if (self.terminal != .none) return;
        if (err == error.StateHashMismatch) {
            self.enterTerminal(.desynced, .desync, "Desync detected; match stopped.", .{});
            return;
        }
        self.enterTerminal(.failed, .{ .disconnect = 4 }, "Lockstep error: {s}", .{@errorName(err)});
    }

    fn handlePeerStatus(self: *OnlineState) void {
        const peer = self.lockstepPeer() orelse return;
        switch (peer.status) {
            .ok => {},
            .protocol_error => |reason| {
                self.enterTerminal(.failed, .{ .disconnect = 5 }, "Protocol error: {s}", .{protocolErrorText(reason).ptr});
            },
            .desync => {
                self.enterTerminal(.desynced, .desync, "Desync detected; match stopped.", .{});
            },
        }
    }

    fn copyJoinLink(self: *OnlineState) void {
        if (self.room_len == 0) {
            self.setNotice("No invite link is available yet.", .{});
            return;
        }
        web_invite.requestCopyJoinUrl(self.roomId()) catch |err| {
            self.setNotice("Copy failed: {s}", .{@errorName(err)});
            return;
        };
        self.setNotice("Copy requested. Browser clipboard status appears below.", .{});
    }

    fn sendPacketBytes(self: *OnlineState, bytes: []const u8) bool {
        web_transport.send(bytes) catch |err| {
            // After a peer has sent or received a result, noPeer/notConnected send
            // failures are just the transport close racing the result drain.
            if (self.shouldDeferPeerLeaveDisconnect()) switch (err) {
                error.NoPeer, error.NotConnected => return true,
                else => {},
            };
            self.enterTerminal(.failed, .none, "Send failed: {s}", .{@errorName(err)});
            return false;
        };
        return true;
    }

    fn sendDisconnectBestEffort(self: *OnlineState, reason: u8) void {
        const match_id = self.currentMatchId() orelse return;
        var encoded = online_session.EncodedPacket{};
        const frame_cursor = if (self.lockstepPeerConst()) |peer| peer.frameCursor() else 0;
        encoded.len = protocol.encode(.{ .disconnect = .{
            .match_id = match_id,
            .sender_slot = self.localProtocolSlot(),
            .reason = reason,
            .last_frame_cursor = frame_cursor,
        } }, encoded.bytes[0..]) catch return;
        web_transport.send(encoded.slice()) catch {};
    }

    fn sendDesyncBestEffort(self: *OnlineState) void {
        if (self.sent_desync) return;
        const match_id = self.currentMatchId() orelse return;
        const peer = self.lockstepPeerConst() orelse return;
        const info = switch (peer.status) {
            .desync => |desync| desync,
            else => lockstep.DesyncInfo{
                .frame_cursor = peer.frameCursor(),
                .local_hash = peer.stateHash(),
                .peer_hash = 0,
            },
        };
        var encoded = online_session.EncodedPacket{};
        encoded.len = protocol.encode(.{ .desync = .{
            .match_id = match_id,
            .sender_slot = self.localProtocolSlot(),
            .reason = 1,
            .frame_cursor = info.frame_cursor,
            .local_hash = info.local_hash,
            .peer_hash = info.peer_hash,
        } }, encoded.bytes[0..]) catch return;
        web_transport.send(encoded.slice()) catch {};
        self.sent_desync = true;
    }

    fn sendResultBestEffort(self: *OnlineState) void {
        if (self.sent_result) return;
        const match_id = self.currentMatchId() orelse return;
        const peer = self.lockstepPeerConst() orelse return;
        const outcome = peer.match.outcome orelse return;
        var encoded = online_session.EncodedPacket{};
        encoded.len = protocol.encode(.{ .result = .{
            .match_id = match_id,
            .sender_slot = self.localProtocolSlot(),
            .outcome = online_session.resultOutcomeFromMatchOutcome(outcome),
            .frame_cursor = peer.frameCursor(),
            .state_hash = peer.stateHash(),
        } }, encoded.bytes[0..]) catch return;
        web_transport.send(encoded.slice()) catch {};
        self.sent_result = true;
    }

    fn setRoom(self: *OnlineState, room_id: []const u8) bool {
        if (room_id.len == 0 or room_id.len > self.room_buf.len) {
            self.markTerminal(.failed, "Invalid invite room id.", .{});
            return false;
        }
        @memcpy(self.room_buf[0..room_id.len], room_id);
        self.room_len = room_id.len;
        return true;
    }

    fn refreshJoinUrl(self: *OnlineState) void {
        if (self.room_len == 0) return;
        const url = web_invite.joinUrl(self.roomId(), &self.join_url_buf) catch {
            self.join_url_len = 0;
            return;
        };
        self.join_url_len = url.len;
    }

    fn markTerminal(self: *OnlineState, terminal: OnlineTerminal, comptime fmt: []const u8, args: anytype) void {
        self.enterTerminal(terminal, .none, fmt, args);
    }

    fn enterTerminal(self: *OnlineState, terminal: OnlineTerminal, packet: OnlineTerminalPacket, comptime fmt: []const u8, args: anytype) void {
        if (self.terminal != .none) return;
        self.flushPendingInputBestEffort();
        switch (packet) {
            .none => {},
            .result => self.sendResultBestEffort(),
            .desync => self.sendDesyncBestEffort(),
            .disconnect => |reason| self.sendDisconnectBestEffort(reason),
        }
        self.terminal = terminal;
        self.setMessage(fmt, args);
        web_transport.disconnect();
    }

    fn setMessage(self: *OnlineState, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.message_buf, fmt, args) catch {
            const fallback = "online status message too long";
            @memcpy(self.message_buf[0..fallback.len], fallback);
            self.message_len = fallback.len;
            return;
        };
        self.message_len = text.len;
    }

    fn setNotice(self: *OnlineState, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.notice_buf, fmt, args) catch {
            const fallback = "online notice too long";
            @memcpy(self.notice_buf[0..fallback.len], fallback);
            self.notice_len = fallback.len;
            self.notice_frames_left = online_notice_frames;
            return;
        };
        self.notice_len = text.len;
        self.notice_frames_left = online_notice_frames;
    }

    fn tickNotice(self: *OnlineState) void {
        if (self.notice_frames_left > 0) self.notice_frames_left -= 1;
    }

    fn isPlaying(self: *const OnlineState) bool {
        const session = self.sessionConst() orelse return false;
        return session.state == .playing;
    }

    fn currentMatchId(self: *const OnlineState) ?u64 {
        const session = self.sessionConst() orelse return null;
        return session.match_id;
    }

    fn resultCompletionState(self: *const OnlineState) online_session.ResultCompletionState {
        return .{
            .pending_remote_result = self.pending_remote_result != null,
            .sent_result = self.sent_result,
            .has_local_outcome = if (self.lockstepPeerConst()) |peer| peer.match.outcome != null else false,
            .result_drain_active = self.result_drain_frames_left > 0,
        };
    }

    fn shouldDeferPeerLeaveDisconnect(self: *const OnlineState) bool {
        return online_session.shouldDeferPeerLeaveDisconnect(self.resultCompletionState());
    }

    fn localProtocolSlot(self: *const OnlineState) u8 {
        return online_session.localProtocolSlotForRole(self.role orelse .host);
    }

    fn phaseText(self: *const OnlineState) [:0]const u8 {
        return switch (self.terminal) {
            .finished => "finished",
            .disconnected => "disconnected",
            .desynced => "desynced",
            .unsupported => "web-only unsupported",
            .failed => "error",
            .none => if (self.sessionConst()) |session| switch (session.state) {
                .waiting_for_setup => "waiting for host setup",
                .waiting_for_ack => "waiting for join ack",
                .setup_received => "sending join ack",
                .playing => if (self.sent_result and self.pending_remote_result == null) "validating result" else "playing",
            } else "starting online",
        };
    }

    fn roleText(self: *const OnlineState) [:0]const u8 {
        return switch (self.role orelse return "not assigned") {
            .host => "host P1",
            .joiner => "joiner P2",
        };
    }

    fn roomId(self: *const OnlineState) []const u8 {
        return self.room_buf[0..self.room_len];
    }

    fn joinUrl(self: *const OnlineState) []const u8 {
        return self.join_url_buf[0..self.join_url_len];
    }

    fn message(self: *const OnlineState) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    fn notice(self: *const OnlineState) []const u8 {
        return self.notice_buf[0..self.notice_len];
    }

    fn sessionPtr(self: *OnlineState) ?*online_session.Session {
        return if (self.session) |*session| session else null;
    }

    fn sessionConst(self: *const OnlineState) ?*const online_session.Session {
        return if (self.session) |*session| session else null;
    }

    fn lockstepPeer(self: *OnlineState) ?*lockstep.Peer {
        const session = self.sessionPtr() orelse return null;
        return if (session.peer) |*peer_value| peer_value else null;
    }

    fn lockstepPeerConst(self: *const OnlineState) ?*const lockstep.Peer {
        const session = self.sessionConst() orelse return null;
        return if (session.peer) |*peer_value| peer_value else null;
    }
};

const App = struct {
    mode: Mode,

    fn init() App {
        var app = App{ .mode = .{ .single = SinglePlayerState.init() } };
        var room_buf: [web_invite.MaxRoomIdLength]u8 = undefined;
        switch (initialOnlineFromLocation(&room_buf)) {
            .none => {},
            .join_room => |room| {
                app.startOnlineJoin(room);
                return app;
            },
            .join_error => |err| {
                app.startOnlineJoinError(err);
                return app;
            },
        }

        switch (app_controls.initialMode()) {
            .single => {},
            .local_versus => app.mode = .{ .local_versus = LocalVersusState.init() },
            .online => app.startOnlineHost(),
        }
        return app;
    }

    fn updateAndDraw(self: *App) void {
        const changed_mode = switch (modeHotkeyTransition(self.currentMode())) {
            .unchanged => false,
            .changed_mode => |selected_mode| changed: {
                self.startMode(selected_mode);
                break :changed true;
            },
        };

        // Draw the new mode immediately, but do not let gameplay keys chorded
        // with 1/2/3 step a freshly-created game on the transition frame.
        if (!changed_mode) {
            switch (self.mode) {
                .single => |*single| single.update(),
                .local_versus => |*versus| versus.update(),
                .online => |*online| online.update(),
            }
        }

        rl.beginDrawing();
        rl.clearBackground(color_bg);

        drawBackground();
        switch (self.mode) {
            .single => |*single| single.draw(),
            .local_versus => |*versus| versus.draw(),
            .online => |*online| online.draw(),
        }
        drawWebTransportFooter();

        rl.endDrawing();
    }

    fn currentMode(self: *const App) AppMode {
        return switch (self.mode) {
            .single => .single,
            .local_versus => .local_versus,
            .online => .online,
        };
    }

    fn startMode(self: *App, mode: AppMode) void {
        self.deinitOnlineIfActive();
        switch (mode) {
            .single => self.mode = .{ .single = SinglePlayerState.init() },
            .local_versus => self.mode = .{ .local_versus = LocalVersusState.init() },
            .online => self.startOnlineHost(),
        }
    }

    fn startOnlineHost(self: *App) void {
        self.mode = .{ .online = undefined };
        switch (self.mode) {
            .online => |*online| online.startHost(),
            else => unreachable,
        }
    }

    fn startOnlineJoin(self: *App, room_id: []const u8) void {
        self.mode = .{ .online = undefined };
        switch (self.mode) {
            .online => |*online| online.startJoinRoom(room_id),
            else => unreachable,
        }
    }

    fn startOnlineJoinError(self: *App, err: anyerror) void {
        self.mode = .{ .online = undefined };
        switch (self.mode) {
            .online => |*online| online.startJoinError(err),
            else => unreachable,
        }
    }

    fn deinitOnlineIfActive(self: *App) void {
        switch (self.mode) {
            .online => |*online| online.deinit(),
            else => {},
        }
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
        defer app.deinitOnlineIfActive();
        while (!rl.windowShouldClose()) {
            app.updateAndDraw();
        }
    }
}

fn updateDrawFrame() callconv(.c) void {
    web_app.updateAndDraw();
}

const InitialOnline = union(enum) {
    none,
    join_room: []const u8,
    join_error: anyerror,
};

fn initialOnlineFromLocation(room_buf: *[web_invite.MaxRoomIdLength]u8) InitialOnline {
    const join_room = web_invite.initialJoinRoom(room_buf) catch |err| return .{ .join_error = err };
    if (join_room) |room| return .{ .join_room = room };
    return .none;
}

fn localVersusSettings() match_mod.MatchSettings {
    return .{
        .player_seeds = .{ game_seed, p2_game_seed },
        .ruleset = modernRulesetSettings(local_garbage_seed),
    };
}

fn onlineSettingsForRoom(room_id: []const u8) match_mod.MatchSettings {
    return .{
        .player_seeds = .{
            onlineSeed("p1", room_id),
            onlineSeed("p2", room_id),
        },
        .ruleset = modernRulesetSettings(onlineSeed("garbage", room_id)),
    };
}

fn modernRulesetSettings(garbage_seed: u64) match_mod.RulesetSettings {
    return .{ .modern = .{
        .garbage_seed = garbage_seed,
        .garbage = .{
            .hole_change_chance = .{ .numerator = 1, .denominator = 4 },
            .initial_holes = .{ null, null },
        },
    } };
}

fn onlineMatchIdForRoom(room_id: []const u8) u64 {
    return onlineSeed("match", room_id);
}

fn onlineSeed(comptime label: []const u8, room_id: []const u8) u64 {
    var hasher = std.hash.XxHash64.init(online_hash_seed);
    hasher.update("Zigfall.Phase6.Online.");
    hasher.update(label);
    hasher.update(".");
    hasher.update(room_id);
    return hasher.final();
}

fn protocolErrorText(reason: lockstep.ProtocolError) [:0]const u8 {
    return switch (reason) {
        .invalid_player_slot => "invalid player slot",
        .input_window_exceeded => "input window exceeded",
        .state_hash_window_exceeded => "state hash window exceeded",
        .frame_index_overflow => "frame index overflow",
        .restart_input_unsupported => "restart input unsupported",
        .conflicting_input_duplicate => "conflicting input duplicate",
        .conflicting_state_hash => "conflicting state hash",
        .malformed_packet => "malformed packet",
        .state_hash_too_old => "state hash too old",
        .unexpected_sender_slot => "unexpected sender slot",
    };
}

fn modeHotkeyTransition(current_mode: AppMode) app_controls.ModeTransition {
    return app_controls.modeTransitionForHotkey(current_mode, .{
        .one_pressed = rl.isKeyPressed(.one),
        .two_pressed = rl.isKeyPressed(.two),
        .three_pressed = rl.isKeyPressed(.three),
    });
}

fn readSinglePlayerInput() input.FrameInput {
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

fn readLocalVersusInput() match_mod.MatchInput {
    return app_controls.localVersusMatchInputFromKeys(.{
        .global_p = keyState(.p),
        .global_r = keyState(.r),
        .p1_a = keyState(.a),
        .p1_d = keyState(.d),
        .p1_s = keyState(.s),
        .p1_space = keyState(.space),
        .p1_w = keyState(.w),
        .p1_q = keyState(.q),
        .p1_e = keyState(.e),
        .p1_left_shift = keyState(.left_shift),
        .p2_left_arrow = keyState(.left),
        .p2_right_arrow = keyState(.right),
        .p2_down_arrow = keyState(.down),
        .p2_enter = keyState(.enter),
        .p2_up_arrow = keyState(.up),
        .p2_period = keyState(.period),
        .p2_slash = keyState(.slash),
        .p2_right_shift = keyState(.right_shift),
    });
}

fn readOnlineInput() app_controls.OnlineInput {
    return app_controls.onlineInputFromKeys(.{
        .global_p = keyState(.p),
        .global_r = keyState(.r),
        .copy_c = keyState(.c),
        .left_arrow = keyState(.left),
        .right_arrow = keyState(.right),
        .down_arrow = keyState(.down),
        .space = keyState(.space),
        .x = keyState(.x),
        .up_arrow = keyState(.up),
        .z = keyState(.z),
        .a = keyState(.a),
        .left_shift = keyState(.left_shift),
    });
}

fn keyState(key: rl.KeyboardKey) app_controls.KeyState {
    return .{
        .down = rl.isKeyDown(key),
        .pressed = rl.isKeyPressed(key),
    };
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

fn drawSingleHeader(state: *const game.Game, frame_count: u64) void {
    rl.drawText("ZIGFALL", 36, 22, 30, color_text);
    rl.drawText("Advanced scoring, hold, ghost, DAS/ARR, lock delay", 38, 55, 15, color_text_dim);
    drawModeHotkeyHint(.single);

    const right_x: i32 = 820;
    rl.drawText(rl.textFormat("FPS %i / fixed %i", .{ rl.getFPS(), @as(i32, input.FixedFps) }), right_x, 22, 18, color_accent);
    rl.drawText(rl.textFormat("frame %u  pieces %u", .{ @as(u32, @truncate(frame_count)), state.pieces_locked }), right_x, 50, 14, color_text_dim);
}

fn drawVersusHeader(match_state: *const match_mod.Match) void {
    rl.drawText("ZIGFALL VERSUS", 36, 22, 30, color_text);
    rl.drawText("Local two-player with Modern garbage rules", 38, 55, 15, color_text_dim);
    drawModeHotkeyHint(.local_versus);

    const right_x: i32 = 760;
    rl.drawText(rl.textFormat("FPS %i / fixed %i", .{ rl.getFPS(), @as(i32, input.FixedFps) }), right_x, 22, 18, color_accent);
    rl.drawText(rl.textFormat("input %u  gameplay %u", .{ @as(u32, @truncate(match_state.input_frame_count)), @as(u32, @truncate(match_state.gameplay_frame_count)) }), right_x, 50, 14, color_text_dim);
}

fn drawOnlineHeader(online: *const OnlineState, match_state: ?*const match_mod.Match) void {
    rl.drawText("ZIGFALL ONLINE", 36, 22, 30, color_text);
    rl.drawText("Web invite-link P2P versus", 38, 55, 15, color_text_dim);
    drawModeHotkeyHint(.online);

    const right_x: i32 = 750;
    rl.drawText(rl.textFormat("FPS %i / fixed %i", .{ rl.getFPS(), @as(i32, input.FixedFps) }), right_x, 22, 18, color_accent);
    if (match_state) |state| {
        rl.drawText(rl.textFormat("input %u  gameplay %u  %s", .{
            @as(u32, @truncate(state.input_frame_count)),
            @as(u32, @truncate(state.gameplay_frame_count)),
            online.phaseText().ptr,
        }), right_x, 50, 14, color_text_dim);
    } else {
        rl.drawText(rl.textFormat("%s | transport %s", .{ online.phaseText().ptr, web_transport.status().text().ptr }), right_x, 50, 14, color_text_dim);
    }
}

fn drawModeHotkeyHint(active_mode: AppMode) void {
    const x: i32 = 390;
    rl.drawText("1: ONE-PLAYER", x, 24, 16, if (active_mode == .single) color_accent else color_text_dim);
    rl.drawText("2: LOCAL", x + 145, 24, 16, if (active_mode == .local_versus) color_accent else color_text_dim);
    rl.drawText("3: ONLINE", x + 255, 24, 16, if (active_mode == .online) color_accent else color_text_dim);
    const hint = if (active_mode == .online) "P pause   C copy link   R no rematch" else "P pause   R restart";
    rl.drawText(hint, x, 52, 13, color_text_dim);
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

fn drawBoard(state: *const game.Game, layout: BoardLayout, title: [:0]const u8, subtitle: [:0]const u8) void {
    const board_w = layout.width();
    const board_h = layout.height();
    const frame_x = layout.x - 18;
    const frame_y = layout.y - 48;
    const frame_w = board_w + 36;
    const frame_h = board_h + 74;

    rl.drawRectangleRounded(rect(frame_x, frame_y, frame_w, frame_h), 0.045, 14, color_panel);
    rl.drawRectangleRoundedLinesEx(rect(frame_x, frame_y, frame_w, frame_h), 0.045, 14, 1.5, color_panel_border);
    rl.drawText(title, layout.x, layout.y - 38, 18, color_text);
    if (subtitle.len > 0) rl.drawText(subtitle, layout.x + 82, layout.y - 35, 12, color_text_dim);

    rl.drawRectangle(layout.x - 5, layout.y - 5, board_w + 10, board_h + 10, rl.Color.init(2, 5, 12, 255));
    rl.drawRectangle(layout.x - 3, layout.y - 3, board_w + 6, board_h + 6, color_panel_border);
    rl.drawRectangle(layout.x, layout.y, board_w, board_h, color_board_bg);

    drawBoardGrid(layout);
    drawLockedCells(state, layout);

    if (state.ghostPiece()) |ghost| {
        drawGhostPiece(ghost, layout);
    }
    if (state.active) |piece| {
        drawPiece(piece, layout, pieceColor(piece.kind));
    }

    drawHiddenBoundary(layout);
    if (state.game_over) drawBoardGameOverBadge(layout);
}

fn drawBoardGrid(layout: BoardLayout) void {
    const board_w = layout.width();
    const board_h = layout.height();

    var x: i32 = 0;
    while (x <= game.BoardWidthI) : (x += 1) {
        const screen_x = layout.x + x * layout.cell;
        rl.drawLine(screen_x, layout.y, screen_x, layout.y + board_h, color_board_grid);
    }

    var y: i32 = 0;
    while (y <= @as(i32, @intCast(game.VisibleHeight))) : (y += 1) {
        const screen_y = layout.y + y * layout.cell;
        rl.drawLine(layout.x, screen_y, layout.x + board_w, screen_y, color_board_grid);
    }
}

fn drawLockedCells(state: *const game.Game, layout: BoardLayout) void {
    var y: usize = game.HiddenRows;
    while (y < game.BoardHeight) : (y += 1) {
        const visible_y: i32 = @intCast(y - game.HiddenRows);
        var x: usize = 0;
        while (x < game.BoardWidth) : (x += 1) {
            if (state.board[y][x]) |cell| {
                const screen_x = layout.x + @as(i32, @intCast(x)) * layout.cell;
                const screen_y = layout.y + visible_y * layout.cell;
                drawCell(screen_x, screen_y, layout.cell, cellColor(cell));
            }
        }
    }
}

fn drawHiddenBoundary(layout: BoardLayout) void {
    const board_w = layout.width();
    rl.drawLine(layout.x, layout.y, layout.x + board_w, layout.y, color_warning);
    rl.drawLine(layout.x, layout.y + 1, layout.x + board_w, layout.y + 1, color_warning.alpha(0.55));

    var segment_x = layout.x;
    while (segment_x < layout.x + board_w) : (segment_x += 18) {
        rl.drawLine(segment_x, layout.y - 8, @min(segment_x + 10, layout.x + board_w), layout.y - 8, color_warning.alpha(0.75));
    }

    rl.drawText("SPAWN / HIDDEN", layout.x + 4, layout.y - 22, 11, color_warning);
}

fn drawBoardGameOverBadge(layout: BoardLayout) void {
    const board_w = layout.width();
    const board_h = layout.height();
    rl.drawRectangle(layout.x, layout.y, board_w, board_h, rl.Color.init(0, 0, 0, 120));
    drawCenteredText("GAME OVER", layout.x + @divTrunc(board_w, 2), layout.y + @divTrunc(board_h, 2) - 14, 18, color_danger);
}

fn drawPiece(piece: game.ActivePiece, layout: BoardLayout, color: rl.Color) void {
    const blocks = game.blockPositions(piece);
    for (blocks) |point| {
        const screen_pos = blockScreenPosition(layout, point) orelse continue;
        drawCell(screen_pos.x, screen_pos.y, layout.cell, color);
    }
}

fn drawGhostPiece(piece: game.ActivePiece, layout: BoardLayout) void {
    const color = pieceColor(piece.kind);
    const blocks = game.blockPositions(piece);
    for (blocks) |point| {
        const screen_pos = blockScreenPosition(layout, point) orelse continue;
        rl.drawRectangle(screen_pos.x + 6, screen_pos.y + 6, layout.cell - 12, layout.cell - 12, color.alpha(0.16));
        rl.drawRectangleLines(screen_pos.x + 3, screen_pos.y + 3, layout.cell - 6, layout.cell - 6, color.alpha(0.72));
        rl.drawRectangleLines(screen_pos.x + 6, screen_pos.y + 6, layout.cell - 12, layout.cell - 12, color.alpha(0.45));
    }
}

fn blockScreenPosition(layout: BoardLayout, point: game.Point) ?struct { x: i32, y: i32 } {
    if (point.x < 0 or point.x >= game.BoardWidthI) return null;
    if (point.y < game.HiddenRowsI or point.y >= game.BoardHeightI) return null;

    return .{
        .x = layout.x + point.x * layout.cell,
        .y = layout.y + (point.y - game.HiddenRowsI) * layout.cell,
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

fn drawVersusPlayer(player: match_mod.PlayerIndex, match_state: *const match_mod.Match, player_result: match_mod.PlayerStepResult) void {
    const runtime = match_state.playerConst(player);
    const layout = versusBoardLayout(player);
    drawVersusSidePanels(player, &runtime.game);
    drawBoard(&runtime.game, layout, playerMatrixTitle(player), "garbage in panel");
    drawVersusStatusPanel(player, match_state, runtime, player_result);
}

fn drawVersusSidePanels(player: match_mod.PlayerIndex, state: *const game.Game) void {
    const x: i32 = switch (player) {
        .p1 => 28,
        .p2 => 946,
    };
    const w: i32 = 126;
    drawVersusHoldPanel(state, x, 150, w, 105, playerHoldTitle(player));
    drawVersusNextPanel(state, x, 272, w, 348, playerNextTitle(player));
}

fn drawVersusHoldPanel(state: *const game.Game, x: i32, y: i32, w: i32, h: i32, title: [:0]const u8) void {
    drawPanel(x, y, w, h, title);
    rl.drawRectangleRounded(rect(x + 12, y + 42, w - 24, 42), 0.12, 8, color_panel_soft);
    rl.drawRectangleRoundedLinesEx(rect(x + 12, y + 42, w - 24, 42), 0.12, 8, 1.0, color_panel_border.alpha(0.5));

    if (state.hold) |kind| {
        drawMiniPiece(kind, x + 16, y + 45, w - 32, 36, 11);
    } else {
        drawCenteredText("EMPTY", x + @divTrunc(w, 2), y + 55, 12, color_text_dim);
    }

    drawPill(x + 20, y + 86, w - 40, 16, if (state.held_this_piece) "USED" else "READY", if (state.held_this_piece) color_warning else color_accent);
}

fn drawVersusNextPanel(state: *const game.Game, x: i32, y: i32, w: i32, h: i32, title: [:0]const u8) void {
    drawPanel(x, y, w, h, title);
    for (state.next, 0..) |kind, i| {
        const row_y = y + 44 + @as(i32, @intCast(i)) * 57;
        const row_h: i32 = 45;
        rl.drawRectangleRounded(rect(x + 10, row_y, w - 20, row_h), 0.13, 8, color_panel_soft);
        rl.drawRectangleRoundedLinesEx(rect(x + 10, row_y, w - 20, row_h), 0.13, 8, 1.0, color_panel_border.alpha(0.4));
        drawMiniPiece(kind, x + 14, row_y + 5, w - 28, row_h - 10, 10);
    }
}

fn drawVersusStatusPanel(player: match_mod.PlayerIndex, match_state: *const match_mod.Match, runtime: *const match_mod.PlayerRuntime, player_result: match_mod.PlayerStepResult) void {
    const x: i32 = switch (player) {
        .p1 => 382,
        .p2 => 560,
    };
    const y: i32 = 150;
    const w: i32 = 158;
    const h: i32 = 470;
    drawPanel(x, y, w, h, playerStatusTitle(player));

    var state_label: [:0]const u8 = "playing";
    var state_color = color_accent;
    if (match_state.outcome) |outcome| {
        switch (outcome) {
            .draw => {
                state_label = "draw";
                state_color = color_warning;
            },
            .winner => |winner| {
                if (winner == player) {
                    state_label = "winner";
                    state_color = color_accent;
                } else {
                    state_label = "lost";
                    state_color = color_danger;
                }
            },
        }
    } else if (runtime.game.game_over) {
        state_label = "game over";
        state_color = color_danger;
    } else if (match_state.paused) {
        state_label = "paused";
        state_color = color_warning;
    }

    const metric_gap: i32 = 21;
    const section_gap: i32 = 24;
    const section_content_gap: i32 = 22;

    var line_y: i32 = y + 48;
    drawCompactMetric("State", state_label, x + 14, line_y, state_color);
    line_y += metric_gap;
    drawCompactMetric("Score", rl.textFormat("%u", .{runtime.game.score}), x + 14, line_y, color_text);
    line_y += metric_gap;
    drawCompactMetric("Lines", rl.textFormat("%u", .{runtime.game.total_lines_cleared}), x + 14, line_y, color_text);
    line_y += metric_gap;
    drawCompactMetric("Level", rl.textFormat("%i", .{@as(i32, runtime.game.level)}), x + 14, line_y, color_text);
    line_y += metric_gap;
    drawCompactMetric("Pieces", rl.textFormat("%u", .{runtime.game.pieces_locked}), x + 14, line_y, color_text_dim);
    line_y += metric_gap;
    drawCompactMetric("Combo", comboText(runtime.game.combo_counter), x + 14, line_y, if (runtime.game.combo_counter >= 1) color_warning else color_text_dim);
    line_y += metric_gap;
    drawCompactMetric("B2B", if (runtime.game.back_to_back_active) "active" else "off", x + 14, line_y, if (runtime.game.back_to_back_active) color_warning else color_text_dim);

    line_y += section_gap;
    drawCompactSection("GARBAGE", x + 14, line_y, w - 28);
    line_y += section_content_gap;
    drawCompactMetric("Incoming", rl.textFormat("%u", .{runtime.pendingGarbageCount()}), x + 14, line_y, if (runtime.pendingGarbageCount() > 0) color_danger else color_text_dim);
    line_y += metric_gap;
    drawCompactMetric("Generated", rl.textFormat("%u", .{player_result.garbage.generated}), x + 14, line_y, if (player_result.garbage.generated > 0) color_danger else color_text_dim);
    line_y += metric_gap;
    drawCompactMetric("Canceled", rl.textFormat("%u", .{player_result.garbage.canceled}), x + 14, line_y, if (player_result.garbage.canceled > 0) color_accent else color_text_dim);
    line_y += metric_gap;
    drawCompactMetric("Queued", rl.textFormat("%u", .{player_result.garbage.queued}), x + 14, line_y, if (player_result.garbage.queued > 0) color_warning else color_text_dim);
    line_y += metric_gap;
    drawCompactMetric("Inserted", rl.textFormat("%u", .{player_result.garbage.inserted}), x + 14, line_y, if (player_result.garbage.inserted > 0) color_danger else color_text_dim);

    line_y += section_gap;
    drawCompactSection("LAST LOCK", x + 14, line_y, w - 28);
    line_y += section_content_gap;
    if (runtime.game.last_lock_result) |lock_result| {
        drawCompactMetric("Piece", pieceLabel(lock_result.piece_kind), x + 14, line_y, pieceColor(lock_result.piece_kind));
        line_y += metric_gap;
        drawCompactMetric("Clear", clearSummary(lock_result), x + 14, line_y, if (lock_result.lines_cleared > 0) color_accent else color_text_dim);
        line_y += metric_gap;
        drawCompactMetric("Output", rl.textFormat("+%i", .{@as(i32, lock_result.attack_lines)}), x + 14, line_y, if (lock_result.attack_lines > 0) color_danger else color_text_dim);
    } else {
        drawCompactMetric("Clear", "none", x + 14, line_y, color_text_dim);
    }
}

fn drawVersusControlsStrip() void {
    const x: i32 = 28;
    const y: i32 = 634;
    const w: i32 = 1044;
    const h: i32 = 62;
    drawPanel(x, y, w, h, "LOCAL CONTROLS");
    rl.drawText("P1: A/D move | S soft | Space hard | W CW | Q CCW | E 180 | Left Shift hold", x + 405, y + 16, 13, color_text);
    rl.drawText("P2: Left/Right move | Down soft | Enter hard | Up CW | . CCW | / 180 | Right Shift hold", x + 405, y + 38, 13, color_text);
    rl.drawText("Global: P pause | R restart | 1 one-player | 2 local versus | 3 online invite", x + 18, y + 38, 13, color_text_dim);
}

fn drawOnlineControlsStrip(online: *const OnlineState) void {
    const x: i32 = 28;
    const y: i32 = 634;
    const w: i32 = 1044;
    const h: i32 = 62;
    drawPanel(x, y, w, h, "ONLINE INVITE / CONTROLS");
    rl.drawText(rl.textFormat("You: %s | phase: %s | copy: %s", .{
        online.roleText().ptr,
        online.phaseText().ptr,
        web_invite.copyStatus().text().ptr,
    }), x + 18, y + 18, 13, color_text);
    if (online.room_len > 0) {
        rl.drawText(rl.textFormat("Room %.*s", .{ @as(i32, @intCast(online.roomId().len)), online.roomId().ptr }), x + 18, y + 40, 13, color_text_dim);
    } else {
        rl.drawText("No active room", x + 18, y + 40, 13, color_text_dim);
    }
    rl.drawText("Move: Left/Right/Down | Space hard | X/Up CW | Z CCW | A 180 | Left Shift hold", x + 400, y + 18, 13, color_text);
    rl.drawText("P deterministic pause | C copy invite link | R rematch no-op | 1/2 switch modes", x + 400, y + 40, 13, color_text_dim);
}

fn drawOnlineWaitingPanel(online: *const OnlineState) void {
    const x: i32 = 250;
    const y: i32 = 160;
    const w: i32 = 600;
    const h: i32 = 330;
    drawPanel(x, y, w, h, "ONLINE INVITE");
    drawTextSlice(online.message(), x + 28, y + 56, 18, color_text);
    rl.drawText(rl.textFormat("Role: %s", .{online.roleText().ptr}), x + 28, y + 92, 16, color_text_dim);
    rl.drawText(rl.textFormat("Phase: %s", .{online.phaseText().ptr}), x + 28, y + 118, 16, color_text_dim);

    if (online.room_len > 0) {
        rl.drawText(rl.textFormat("Room: %.*s", .{ @as(i32, @intCast(online.roomId().len)), online.roomId().ptr }), x + 28, y + 158, 16, color_accent);
    }
    if (online.join_url_len > 0) {
        rl.drawText("Join URL:", x + 28, y + 194, 15, color_text_dim);
        const url = online.joinUrl();
        const shown_len = @min(url.len, 88);
        const suffix: [:0]const u8 = if (shown_len < url.len) "..." else "";
        rl.drawText(rl.textFormat("%.*s%s", .{
            @as(i32, @intCast(shown_len)),
            url.ptr,
            suffix.ptr,
        }), x + 28, y + 218, 13, color_text);
    }

    rl.drawText("Press C to copy the invite link. Press 1/2 to leave, or 3 from another mode for a fresh invite.", x + 28, y + h - 54, 15, color_text_dim);
    rl.drawText(rl.textFormat("Transport: %s | peers %i | last error %s", .{
        web_transport.status().text().ptr,
        @as(i32, web_transport.peerCount()),
        web_transport.lastError().text().ptr,
    }), x + 28, y + h - 28, 13, color_text_dim);
}

fn drawOnlineWaitingOverlay(online: *const OnlineState) void {
    drawScreenOverlay("ONLINE WAIT", rl.textFormat("%.*s", .{ @as(i32, @intCast(online.message().len)), online.message().ptr }), color_accent);
}

fn drawOnlineTerminalOverlay(online: *const OnlineState) void {
    const title: [:0]const u8 = switch (online.terminal) {
        .finished => if (online.lockstepPeerConst()) |peer| if (peer.match.outcome) |outcome| matchOutcomeTitle(outcome) else "MATCH COMPLETE" else "MATCH COMPLETE",
        .disconnected => "DISCONNECTED",
        .desynced => "DESYNC",
        .unsupported => "WEB ONLY",
        .failed => "ONLINE ERROR",
        .none => return,
    };
    const accent = switch (online.terminal) {
        .finished => color_accent,
        .disconnected, .unsupported => color_warning,
        .desynced, .failed => color_danger,
        .none => color_text,
    };
    drawScreenOverlay(title, rl.textFormat("%.*s", .{ @as(i32, @intCast(online.message().len)), online.message().ptr }), accent);
}

fn drawOnlineMatchOverlay(online: *const OnlineState, match_state: *const match_mod.Match) void {
    if (match_state.outcome) |outcome| {
        _ = online;
        drawScreenOverlay(matchOutcomeTitle(outcome), "Online rematch is not implemented; press 1/2/3 for a fresh mode", if (isDraw(outcome)) color_warning else color_accent);
    } else if (match_state.paused) {
        drawScreenOverlay("PAUSED", "Press P to resume; R is disabled online", color_warning);
    }
}

fn drawOnlineNotice(text: []const u8) void {
    const w: i32 = 720;
    const h: i32 = 42;
    const x: i32 = @divTrunc(screen_width - w, 2);
    const y: i32 = 94;
    rl.drawRectangleRounded(rect(x, y, w, h), 0.18, 12, rl.Color.init(18, 25, 43, 244));
    rl.drawRectangleRoundedLinesEx(rect(x, y, w, h), 0.18, 12, 1.5, color_warning);
    drawCenteredTextSlice(text, x + @divTrunc(w, 2), y + 12, 15, color_warning);
}

fn drawMetric(label: [:0]const u8, value: [:0]const u8, x: i32, y: i32, value_color: rl.Color) void {
    rl.drawText(label, x, y, 14, color_text_dim);
    rl.drawText(value, x + 82, y - 2, 16, value_color);
}

fn drawCompactMetric(label: [:0]const u8, value: [:0]const u8, x: i32, y: i32, value_color: rl.Color) void {
    rl.drawText(label, x, y, 12, color_text_dim);
    rl.drawText(value, x + 76, y - 1, 13, value_color);
}

fn drawCompactSection(text: [:0]const u8, x: i32, y: i32, width: i32) void {
    rl.drawText(text, x, y, 13, color_accent);
    rl.drawLine(x + 70, y + 8, x + width, y + 8, color_panel_border.alpha(0.55));
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
    const board_w = single_board_layout.width();
    const x = single_board_layout.x - 56;
    const y = single_board_layout.y + 150;
    const w: i32 = board_w + 112;
    const h: i32 = 168;
    rl.drawRectangleRounded(rect(x, y, w, h), 0.09, 14, rl.Color.init(24, 12, 22, 238));
    rl.drawRectangleRoundedLinesEx(rect(x, y, w, h), 0.09, 14, 2.0, color_danger);
    drawCenteredText("GAME OVER", x + @divTrunc(w, 2), y + 26, 34, color_danger);
    drawCenteredText(rl.textFormat("Score %u  |  Lines %u", .{ state.score, state.total_lines_cleared }), x + @divTrunc(w, 2), y + 78, 18, color_text);
    drawCenteredText("Press R to restart", x + @divTrunc(w, 2), y + 112, 18, color_text_dim);
    drawCenteredText(exitOverlayText(), x + @divTrunc(w, 2), y + 137, 14, color_text_dim);
}

fn drawMatchOverlay(match_state: *const match_mod.Match) void {
    if (match_state.outcome) |outcome| {
        drawScreenOverlay(matchOutcomeTitle(outcome), "Press R to restart  |  1/2 switch modes", if (isDraw(outcome)) color_warning else color_accent);
    } else if (match_state.paused) {
        drawScreenOverlay("PAUSED", "Press P to resume  |  R restarts", color_warning);
    }
}

fn drawScreenOverlay(title: [:0]const u8, subtitle: [:0]const u8, accent: rl.Color) void {
    rl.drawRectangle(0, 0, screen_width, screen_height, rl.Color.init(0, 0, 0, 120));
    const w: i32 = 420;
    const h: i32 = 140;
    const x: i32 = @divTrunc(screen_width - w, 2);
    const y: i32 = 250;
    rl.drawRectangleRounded(rect(x, y, w, h), 0.09, 14, rl.Color.init(15, 22, 40, 238));
    rl.drawRectangleRoundedLinesEx(rect(x, y, w, h), 0.09, 14, 2.0, accent);
    drawCenteredText(title, x + @divTrunc(w, 2), y + 28, 34, accent);
    drawCenteredText(subtitle, x + @divTrunc(w, 2), y + 86, 18, color_text);
}

fn drawWebTransportFooter() void {
    if (comptime builtin.os.tag != .emscripten) return;

    const status_text = web_transport.status().text();
    const last_error = web_transport.lastError();
    const error_text = if (last_error == .none) "none" else last_error.text();
    rl.drawText(
        rl.textFormat("Web transport: %s | peers %i | queued %i | last error %s", .{
            status_text.ptr,
            @as(i32, web_transport.peerCount()),
            @as(i32, @intCast(web_transport.queuedPacketCount())),
            error_text.ptr,
        }),
        32,
        screen_height - 20,
        12,
        color_text_dim,
    );
}

fn exitInstructionText() [:0]const u8 {
    return if (builtin.os.tag == .emscripten) "Close browser tab to exit" else "ESC closes the window";
}

fn exitOverlayText() [:0]const u8 {
    return if (builtin.os.tag == .emscripten) "Close browser tab to exit" else "ESC exits";
}

fn drawOverlay(title: [:0]const u8, subtitle: [:0]const u8, accent: rl.Color) void {
    rl.drawRectangle(0, 0, screen_width, screen_height, rl.Color.init(0, 0, 0, 115));
    const board_w = single_board_layout.width();
    const x = single_board_layout.x - 44;
    const y = single_board_layout.y + 172;
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

fn drawTextSlice(text: []const u8, x: i32, y: i32, size: i32, color: rl.Color) void {
    rl.drawText(rl.textFormat("%.*s", .{ @as(i32, @intCast(text.len)), text.ptr }), x, y, size, color);
}

fn drawCenteredTextSlice(text: []const u8, center_x: i32, y: i32, size: i32, color: rl.Color) void {
    const c_text = rl.textFormat("%.*s", .{ @as(i32, @intCast(text.len)), text.ptr });
    drawCenteredText(c_text, center_x, y, size, color);
}

fn versusBoardLayout(player: match_mod.PlayerIndex) BoardLayout {
    return switch (player) {
        .p1 => versus_p1_board_layout,
        .p2 => versus_p2_board_layout,
    };
}

fn playerMatrixTitle(player: match_mod.PlayerIndex) [:0]const u8 {
    return switch (player) {
        .p1 => "P1 MATRIX",
        .p2 => "P2 MATRIX",
    };
}

fn playerHoldTitle(player: match_mod.PlayerIndex) [:0]const u8 {
    return switch (player) {
        .p1 => "P1 HOLD",
        .p2 => "P2 HOLD",
    };
}

fn playerNextTitle(player: match_mod.PlayerIndex) [:0]const u8 {
    return switch (player) {
        .p1 => "P1 NEXT",
        .p2 => "P2 NEXT",
    };
}

fn playerStatusTitle(player: match_mod.PlayerIndex) [:0]const u8 {
    return switch (player) {
        .p1 => "P1 STATUS",
        .p2 => "P2 STATUS",
    };
}

fn matchOutcomeTitle(outcome: match_mod.MatchOutcome) [:0]const u8 {
    return switch (outcome) {
        .winner => |winner| switch (winner) {
            .p1 => "P1 WINS",
            .p2 => "P2 WINS",
        },
        .draw => "DRAW",
    };
}

fn isDraw(outcome: match_mod.MatchOutcome) bool {
    return switch (outcome) {
        .draw => true,
        .winner => false,
    };
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

fn cellColor(cell: game.Cell) rl.Color {
    return switch (cell) {
        .piece => |kind| pieceColor(kind),
        .garbage => rl.Color.init(112, 124, 142, 255),
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

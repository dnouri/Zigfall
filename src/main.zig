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
const profile = @import("profile");
const protocol = @import("protocol");
const web_invite = @import("web_invite");
const web_profile = @import("web_profile");
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
const online_terminal_packet_drain_frames: u16 = 30;
const online_late_final_packet_peer_leave_grace_frames: u16 = 30;
const online_pending_result_peer_leave_grace_frames: u16 = 120;
const online_peer_leave_drain_frames: usize = lockstep.MaxBufferedFrames;
const online_notice_frames: u16 = 180;
const online_remote_input_stall_notice_frames: u16 = 30;
const online_message_capacity: usize = 192;
const online_notice_capacity: usize = 128;

const single_board_layout = BoardLayout{ .x = 330, .y = 140, .cell = single_cell_size };
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

    fn init() SinglePlayerState {
        return .{
            .state = game.Game.init(game_seed),
            .controller = .{},
            .paused = false,
            .gravity_counter = 0,
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
    }

    fn draw(self: *const SinglePlayerState) void {
        drawSingleHeader();
        drawHoldPanel(&self.state);
        drawControlsPanel();
        drawBoard(&self.state, single_board_layout, "MATRIX", "");
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
        drawVersusPlayer(.p1, &self.match_state, self.last_step_result.players[0], true);
        drawVersusPlayer(.p2, &self.match_state, self.last_step_result.players[1], true);
        drawVersusControlsStrip();
        drawMatchOverlay(&self.match_state);
    }
};

const OnlineTerminal = enum {
    none,
    finished,
    unverified_result,
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
    local_profile: profile.ProfileCard = .{},
    remote_profile: ?profile.ProfileCard = null,
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
    sent_profile: bool = false,
    sent_result: bool = false,
    sent_desync: bool = false,
    pending_remote_result: ?protocol.Result = null,
    verified_result: bool = false,
    pending_input_batch: online_session.InputBatcher = .{},
    pending_result_peer_leave_frames: u16 = 0,
    late_final_packet_peer_leave_frames: u16 = 0,
    result_drain_frames_left: u16 = 0,
    remote_input_stall_frames: u16 = 0,
    next_hash_frame: u64 = online_state_hash_interval_frames,
    ever_had_peer: bool = false,
    peer_leave_observed: bool = false,
    terminal: OnlineTerminal = .none,
    terminal_packet: online_session.TerminalPacketKind = .none,
    terminal_drain_frames_left: u16 = 0,
    terminal_disconnected: bool = false,
    profile_result_recorded: bool = false,
    profile_result_update_failed: bool = false,
    profile_storage_status: web_profile.Status = .unavailable,
    profile_rating_before: profile.Rating = profile.DefaultRating,
    profile_rating_after: profile.Rating = profile.DefaultRating,
    profile_rating_delta: i32 = 0,

    fn startHost(self: *OnlineState) void {
        self.* = .{};
        self.loadLocalProfile();
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
        self.loadLocalProfile();
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
        if (self.terminal != .none) {
            self.updateTerminalDrain();
            return;
        }

        self.pollTransport();
        if (self.terminal != .none) return;

        self.updateTransportHealth();
        if (self.terminal != .none) return;
        if (self.isLateFinalPacketPeerLeaveGraceActive()) return;

        self.driveHandshake();
        if (self.terminal != .none) return;

        self.maybeSendProfile();
        if (self.terminal != .none) return;

        self.driveLockstep(online_input.frame);
    }

    fn draw(self: *const OnlineState) void {
        if (self.lockstepPeerConst()) |peer| {
            drawOnlineHeader(self, &peer.match);
            const outcome_verified = self.hasVerifiedResult();
            drawVersusPlayer(.p1, &peer.match, self.last_step_result.players[0], outcome_verified);
            drawVersusPlayer(.p2, &peer.match, self.last_step_result.players[1], outcome_verified);
            drawOnlineBoardProfile(self, .p1);
            drawOnlineBoardProfile(self, .p2);
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

    fn loadLocalProfile(self: *OnlineState) void {
        self.local_profile = web_profile.loadCard() catch |err| fallback: {
            self.setNotice("Local profile unavailable; using defaults: {s}", .{@errorName(err)});
            break :fallback profile.ProfileCard.default();
        };
        self.profile_storage_status = web_profile.status();
        self.profile_rating_before = self.local_profile.rating;
        self.profile_rating_after = self.local_profile.rating;
        self.profile_rating_delta = 0;
    }

    fn handleShellActions(self: *OnlineState, online_input: app_controls.OnlineInput) void {
        if (online_input.copy_link_pressed) self.copyJoinLink();
        if (online_input.restart_pressed) {
            self.setNotice("Online rematch/restart is not available yet; use 1/2/3 for a fresh mode.", .{});
        }
    }

    fn updateTransportHealth(self: *OnlineState) void {
        const status = web_transport.status();
        const last_error = web_transport.lastError();
        if (web_transport.peerCount() > 0) self.ever_had_peer = true;

        // Trystero can report noPeer before dispatching a retiring peer's final
        // lifecycle packet. Keep polling for a short bounded grace, and before
        // making peer-leave terminal step any already-buffered lockstep inputs so
        // a deterministic final outcome or result validation wins the race.
        const transport_peer_leave_observed = self.ever_had_peer and (status == .disconnected or last_error == .no_peer);
        if (transport_peer_leave_observed) self.peer_leave_observed = true;
        const allow_late_final_packet_grace = transport_peer_leave_observed or self.late_final_packet_peer_leave_frames > 0;
        const defer_peer_leave_disconnect = if (self.peer_leave_observed) self.handlePeerLeaveObserved(allow_late_final_packet_grace) else false;
        if (!self.peer_leave_observed) {
            self.pending_result_peer_leave_frames = 0;
            self.late_final_packet_peer_leave_frames = 0;
        }
        if (self.terminal != .none) return;

        switch (online_session.transportHealthAction(.{
            .status = onlineTransportStatus(status),
            .last_error = onlineTransportError(last_error),
            .ever_had_peer = self.ever_had_peer,
            .peer_leave_observed = self.peer_leave_observed,
            .defer_peer_leave_disconnect = defer_peer_leave_disconnect,
            .ignore_async_send_failure = self.shouldIgnoreAsyncSendFailure(),
        })) {
            .none => {},
            .fail_extra_peer => self.enterTerminal(.failed, .{ .disconnect = 2 }, "Extra peer joined this room; match stopped. Create a new invite.", .{}),
            .fail_missing_js => self.enterTerminal(.failed, .none, "Web transport helper is missing; reload the page.", .{}),
            .unsupported => self.enterTerminal(.unsupported, .none, "Online transport is unavailable in this build.", .{}),
            .disconnected => self.enterTerminal(.disconnected, .none, "Opponent disconnected; this match is not counted.", .{}),
            .fail_packet_too_large => self.enterTerminal(.failed, .{ .disconnect = 3 }, "Network packet exceeded the protocol size limit; match stopped before hiding a lost packet.", .{}),
            .fail_queue_full => self.enterTerminal(.failed, .{ .disconnect = 3 }, "Network receive backlog overflowed; match stopped before hiding a lost packet.", .{}),
            .fail_send_failed => self.enterTerminal(.failed, .{ .disconnect = 3 }, "Transport send failed; match stopped.", .{}),
        }
    }

    fn handlePeerLeaveObserved(self: *OnlineState, allow_late_final_packet_grace: bool) bool {
        self.drainBufferedLockstepForPeerLeave();
        if (self.terminal != .none) return true;

        const completion = self.resultCompletionState();
        if (completion.pending_remote_result and !completion.has_local_outcome) {
            if (self.pending_result_peer_leave_frames < std.math.maxInt(u16)) self.pending_result_peer_leave_frames += 1;
        } else {
            self.pending_result_peer_leave_frames = 0;
        }

        if (allow_late_final_packet_grace and !online_session.shouldDeferPeerLeaveDisconnect(completion)) {
            if (self.late_final_packet_peer_leave_frames < std.math.maxInt(u16)) self.late_final_packet_peer_leave_frames += 1;
        } else {
            self.late_final_packet_peer_leave_frames = 0;
        }

        switch (online_session.peerLeaveDisconnectAction(.{
            .completion = completion,
            .pending_result_peer_leave_frames = self.pending_result_peer_leave_frames,
            .pending_result_peer_leave_grace_frames = online_pending_result_peer_leave_grace_frames,
            .late_final_packet_peer_leave_frames = self.late_final_packet_peer_leave_frames,
            .late_final_packet_peer_leave_grace_frames = online_late_final_packet_peer_leave_grace_frames,
            .allow_late_final_packet_grace = allow_late_final_packet_grace,
        })) {
            .disconnect_now => return false,
            .defer_disconnect => return true,
            .pending_result_timed_out => {
                self.enterTerminal(.desynced, .desync, "Opponent result could not be validated after disconnect; match stopped and is not counted.", .{});
                return true;
            },
        }
    }

    fn drainBufferedLockstepForPeerLeave(self: *OnlineState) void {
        if (!self.isPlaying()) return;
        var peer = self.lockstepPeer() orelse return;
        if (peer.match.outcome == null) {
            const advanced = peer.stepAvailableMax(online_peer_leave_drain_frames) catch |err| {
                self.handleLockstepError(err);
                return;
            };
            self.last_step_result = if (advanced > 0) peer.last_step_result else .{};
            self.handlePeerStatus();
            if (self.terminal != .none) return;
        }
        if (self.pending_remote_result != null and !self.validatePendingRemoteResult()) return;
        if (peer.match.outcome != null and !self.sent_result) self.finishOnlineMatch();
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
        const decode_policy = online_session.packetDecodePolicyForKnownMatch(self.currentMatchId(), bytes) catch |err| {
            self.enterTerminal(.failed, .{ .disconnect = 8 }, "Malformed network packet header: {s}", .{@errorName(err)});
            return;
        };
        if (decode_policy == .ignore_stale) return;

        const packet = protocol.decode(bytes) catch |err| {
            if (decode_policy == .decode_optional_profile) {
                self.setNotice("Ignoring malformed opponent profile card: {s}", .{@errorName(err)});
                return;
            }
            self.enterTerminal(.failed, .{ .disconnect = 9 }, "Malformed network packet: {s}", .{@errorName(err)});
            return;
        };

        switch (packet) {
            .setup => |setup| self.handleSetup(setup),
            .ack => |ack| self.handleAck(ack),
            .input_batch, .state_hash, .desync => self.handleRuntimePacket(bytes),
            .disconnect => |disconnect| self.handleDisconnect(disconnect),
            .result => |result| self.handleResult(result),
            .profile => |profile_packet| self.handleProfile(profile_packet),
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
        // A best-effort lifecycle disconnect may be queued behind final runtime
        // packets when the peer closes quickly; step buffered input/result state
        // before letting it become terminal.
        self.peer_leave_observed = true;
        if (self.handlePeerLeaveObserved(true)) return;
        if (self.terminal != .none) return;
        self.enterTerminal(.disconnected, .none, "Opponent disconnected at frame {}; this match is not counted.", .{@as(u32, @truncate(disconnect.last_frame_cursor))});
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
                self.verified_result = true;
                self.pending_result_peer_leave_frames = 0;
                self.finishOnlineMatch();
            },
            .pending_local_result => {
                self.pending_remote_result = result;
                self.verified_result = false;
                self.pending_result_peer_leave_frames = 0;
                self.setNotice("Opponent reported a result; waiting for local lockstep to catch up.", .{});
            },
        }
    }

    fn handleProfile(self: *OnlineState, profile_packet: protocol.Profile) void {
        const role = self.role orelse return;
        const match_id = self.currentMatchId() orelse return;
        self.remote_profile = online_session.acceptRemoteProfile(role, match_id, profile_packet) catch |err| {
            self.setNotice("Ignoring opponent profile card: {s}", .{@errorName(err)});
            return;
        };
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

    fn maybeSendProfile(self: *OnlineState) void {
        if (self.sent_profile or web_transport.status() != .connected) return;
        const match_id = self.currentMatchId() orelse return;
        const encoded = online_session.encodeProfilePacket(match_id, self.localProtocolSlot(), self.local_profile) catch |err| {
            self.sent_profile = true;
            self.setNotice("Local profile card could not be encoded: {s}", .{@errorName(err)});
            return;
        };
        web_transport.sendBestEffort(encoded.slice()) catch |err| {
            self.sent_profile = true;
            self.setNotice("Local profile card was not sent: {s}", .{@errorName(err)});
            return;
        };
        self.sent_profile = true;
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
        self.handleRemoteInputStall(advanced, peer);
        self.handlePeerStatus();
        if (self.terminal != .none) return;
        if (self.pending_remote_result != null and !self.validatePendingRemoteResult()) return;

        self.sendDueStateHash(peer);
        if (self.terminal != .none) return;

        if (peer.match.outcome != null) self.finishOnlineMatch();
    }

    fn handleRemoteInputStall(self: *OnlineState, advanced: usize, peer: *const lockstep.Peer) void {
        if (advanced > 0 or peer.match.outcome != null or !peer.isOk()) {
            self.remote_input_stall_frames = 0;
            return;
        }
        if (self.remote_input_stall_frames < std.math.maxInt(u16)) self.remote_input_stall_frames += 1;
        if (self.remote_input_stall_frames == online_remote_input_stall_notice_frames or
            (self.remote_input_stall_frames > online_remote_input_stall_notice_frames and self.remote_input_stall_frames % online_notice_frames == 0))
        {
            self.setNotice("Waiting for opponent input...", .{});
        }
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
        const remote_status = self.remoteResultStatus() orelse return;
        if (self.terminal != .none) return;

        switch (online_session.resultFinishAction(.{
            .remote_result_status = remote_status,
            .has_local_outcome = self.hasLocalOutcome(),
            .sent_local_result = self.sent_result,
            .result_drain_frames_left = self.result_drain_frames_left,
            .peer_left = self.peer_leave_observed,
        })) {
            .no_local_outcome => {},
            .send_local_result => {
                self.flushPendingInputBestEffort();
                self.sendResultBestEffort();
                self.result_drain_frames_left = online_result_drain_frames;
                if (remote_status == .validated) {
                    self.setMessage("Match result validated. Closing connection shortly.", .{});
                } else {
                    self.setMessage("Match complete locally. Waiting briefly for opponent result verification.", .{});
                }
            },
            .wait_for_remote_result, .wait_for_verified_drain => {
                if (self.result_drain_frames_left > 0) self.result_drain_frames_left -= 1;
            },
            .finish_verified => {
                self.recordVerifiedProfileResult();
                if (self.profile_result_recorded and !self.profile_result_update_failed) {
                    self.enterTerminal(.finished, .none, "Match complete. Local rating {s}{d} -> {}{s}. Online rematch is not implemented yet.", .{
                        if (self.profile_rating_delta >= 0) "+" else "-",
                        @abs(self.profile_rating_delta),
                        self.profile_rating_after,
                        self.localProfileResultPersistenceSuffix().ptr,
                    });
                } else {
                    self.enterTerminal(.finished, .none, "Match complete and verified. Local rating was not updated.", .{});
                }
            },
            .finish_unverified_disconnect => {
                self.enterTerminal(.unverified_result, .none, "Opponent disconnected before result verification; this match is not counted as a win or loss.", .{});
            },
            .finish_unverified_timeout => {
                self.enterTerminal(.unverified_result, .none, "Opponent result was not verified; this match is not counted as a win or loss.", .{});
            },
        }
    }

    fn remoteResultStatus(self: *OnlineState) ?online_session.RemoteResultStatus {
        const result = self.pending_remote_result orelse return .none;
        const role = self.role orelse return .none;
        const peer = self.lockstepPeerConst() orelse return .none;
        switch (online_session.validateRemoteResult(role, peer, result) catch |err| {
            self.handleRemoteResultValidationError(err);
            return null;
        }) {
            .accepted => {
                self.verified_result = true;
                self.recordVerifiedProfileResult();
                return .validated;
            },
            .pending_local_result => return .pending_local_result,
        }
    }

    fn validatePendingRemoteResult(self: *OnlineState) bool {
        _ = self.remoteResultStatus() orelse return false;
        return self.terminal == .none;
    }

    fn recordVerifiedProfileResult(self: *OnlineState) void {
        if (online_session.profileRatingRecordAction(.{
            .verified_result = self.hasVerifiedResult(),
            .has_local_outcome = self.hasLocalOutcome(),
            .already_recorded = self.profile_result_recorded,
        }) != .record) return;

        self.profile_result_recorded = true;
        const role = self.role orelse {
            self.profile_result_update_failed = true;
            return;
        };
        const peer = self.lockstepPeerConst() orelse {
            self.profile_result_update_failed = true;
            return;
        };
        const outcome = peer.match.outcome orelse {
            self.profile_result_update_failed = true;
            return;
        };

        self.profile_rating_before = self.local_profile.rating;
        const result = online_session.profileResultForLocalRole(role, outcome);
        const opponent_rating = online_session.opponentRatingForProfileUpdate(self.remote_profile);
        const mutation = web_profile.applyVerifiedResultWithStatus(result, opponent_rating) catch {
            self.profile_storage_status = web_profile.status();
            self.profile_result_update_failed = true;
            self.profile_rating_after = self.profile_rating_before;
            self.profile_rating_delta = 0;
            return;
        };
        self.local_profile = mutation.card;
        self.profile_storage_status = mutation.status;
        self.profile_rating_after = self.local_profile.rating;
        self.profile_rating_delta = @as(i32, self.profile_rating_after) - @as(i32, self.profile_rating_before);
        self.profile_result_update_failed = false;
    }

    fn handleRemoteResultValidationError(self: *OnlineState, err: anyerror) void {
        switch (err) {
            error.ResultOutcomeMismatch, error.ResultFrameCursorMismatch, error.ResultStateHashMismatch => {
                self.enterTerminal(.desynced, .desync, "Opponent result disagreed with local final state: {s}; not counted.", .{@errorName(err)});
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
            self.enterTerminal(.desynced, .desync, "Desync detected; match stopped and is not counted.", .{});
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
                self.enterTerminal(.desynced, .desync, "Desync detected; match stopped and is not counted.", .{});
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
        const terminal_packet = terminalPacketKind(packet);
        switch (packet) {
            .none => {},
            .result => self.sendResultBestEffort(),
            .desync => self.sendDesyncBestEffort(),
            .disconnect => |reason| self.sendDisconnectBestEffort(reason),
        }
        self.terminal = terminal;
        self.terminal_packet = terminal_packet;
        self.terminal_drain_frames_left = if (terminal_packet == .none) 0 else online_terminal_packet_drain_frames;
        self.setMessage(fmt, args);
        if (terminal_packet == .none) self.disconnectTerminalTransport();
    }

    fn updateTerminalDrain(self: *OnlineState) void {
        switch (online_session.terminalDrainAction(.{
            .packet = self.terminal_packet,
            .frames_left = self.terminal_drain_frames_left,
            .disconnected = self.terminal_disconnected,
        })) {
            .no_op => {},
            .disconnect_now => self.disconnectTerminalTransport(),
            .wait => {
                if (self.terminal_drain_frames_left > 0) self.terminal_drain_frames_left -= 1;
                if (self.terminal_drain_frames_left == 0) self.disconnectTerminalTransport();
            },
        }
    }

    fn disconnectTerminalTransport(self: *OnlineState) void {
        if (self.terminal_disconnected) return;
        web_transport.disconnect();
        self.terminal_disconnected = true;
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

    fn hasLocalOutcome(self: *const OnlineState) bool {
        return if (self.lockstepPeerConst()) |peer| peer.match.outcome != null else false;
    }

    fn hasVerifiedResult(self: *const OnlineState) bool {
        return self.verified_result;
    }

    fn resultCompletionState(self: *const OnlineState) online_session.ResultCompletionState {
        return .{
            .pending_remote_result = self.pending_remote_result != null,
            .sent_result = self.sent_result,
            .has_local_outcome = self.hasLocalOutcome(),
            .result_drain_active = self.result_drain_frames_left > 0,
        };
    }

    fn shouldDeferPeerLeaveDisconnect(self: *const OnlineState) bool {
        return online_session.shouldDeferPeerLeaveDisconnect(self.resultCompletionState());
    }

    fn isLateFinalPacketPeerLeaveGraceActive(self: *const OnlineState) bool {
        return self.peer_leave_observed and
            self.late_final_packet_peer_leave_frames > 0 and
            !self.shouldDeferPeerLeaveDisconnect();
    }

    fn shouldIgnoreAsyncSendFailure(self: *const OnlineState) bool {
        const state = self.resultCompletionState();
        return state.sent_result or state.has_local_outcome or state.result_drain_active;
    }

    fn localProfileChangesArePersistent(self: *const OnlineState) bool {
        return switch (self.profile_storage_status) {
            .ready => true,
            .memory_only, .storage_error, .crypto_unavailable => false,
            .unavailable, .missing_js => true,
        };
    }

    fn localProfileStorageNote(self: *const OnlineState) [:0]const u8 {
        return switch (self.profile_storage_status) {
            .memory_only => "Local profile is memory-only; changes are not saved.",
            .storage_error => "Local profile storage failed; changes are not saved.",
            .crypto_unavailable => "Local profile is anonymous memory-only; changes are not saved.",
            .ready, .unavailable, .missing_js => "",
        };
    }

    fn localProfileResultPersistenceSuffix(self: *const OnlineState) [:0]const u8 {
        return if (self.localProfileChangesArePersistent()) "" else " (memory-only; not saved)";
    }

    fn localProtocolSlot(self: *const OnlineState) u8 {
        return online_session.localProtocolSlotForRole(self.role orelse .host);
    }

    fn localPlayerIndex(self: *const OnlineState) ?match_mod.PlayerIndex {
        return switch (self.role orelse return null) {
            .host => .p1,
            .joiner => .p2,
        };
    }

    fn profileForPlayer(self: *const OnlineState, player: match_mod.PlayerIndex) ?*const profile.ProfileCard {
        const local_player = self.localPlayerIndex() orelse return null;
        if (player == local_player) return &self.local_profile;
        return if (self.remote_profile) |*remote| remote else null;
    }

    fn phaseText(self: *const OnlineState) [:0]const u8 {
        return switch (self.terminal) {
            .finished => "finished",
            .unverified_result => "unverified result",
            .disconnected => "disconnected",
            .desynced => "desynced",
            .unsupported => "web-only unsupported",
            .failed => "error",
            .none => if (self.sessionConst()) |session| switch (session.state) {
                .waiting_for_setup => "waiting for host setup",
                .waiting_for_ack => "waiting for join ack",
                .setup_received => "sending join ack",
                .playing => if (self.sent_result) "validating result" else "playing",
            } else "starting online",
        };
    }

    fn phaseShortText(self: *const OnlineState) [:0]const u8 {
        return switch (self.terminal) {
            .finished => "finished",
            .unverified_result => "unverified",
            .disconnected => "disconnected",
            .desynced => "desynced",
            .unsupported => "unsupported",
            .failed => "error",
            .none => if (self.sessionConst()) |session| switch (session.state) {
                .waiting_for_setup => "setup",
                .waiting_for_ack => "waiting",
                .setup_received => "acking",
                .playing => if (self.sent_result) "validating" else "playing",
            } else "starting",
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

fn terminalPacketKind(packet: OnlineTerminalPacket) online_session.TerminalPacketKind {
    return switch (packet) {
        .none => .none,
        .result => .result,
        .desync => .desync,
        .disconnect => .disconnect,
    };
}

fn onlineTransportStatus(status: web_transport.Status) online_session.TransportStatus {
    return switch (status) {
        .unavailable => .unavailable,
        .missing_js => .missing_js,
        .disconnected => .disconnected,
        .connecting => .connecting,
        .connected => .connected,
        .busy => .busy,
    };
}

fn onlineTransportError(err: web_transport.ErrorCode) online_session.TransportError {
    return switch (err) {
        .none => .none,
        .missing_js => .missing_js,
        .unavailable => .unavailable,
        .bad_room => .bad_room,
        .join_failed => .join_failed,
        .not_connected => .not_connected,
        .no_peer => .no_peer,
        .packet_too_large => .packet_too_large,
        .queue_full => .queue_full,
        .send_failed => .send_failed,
        .buffer_too_small => .buffer_too_small,
        .busy => .busy,
    };
}

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
            .online => |*online| {
                online.draw();
                drawWebTransportFooter();
            },
        }

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

fn drawSingleHeader() void {
    rl.drawText("ZIGFALL", 36, 22, 30, color_text);
    rl.drawText("Advanced scoring, hold, ghost, DAS/ARR", 38, 55, 15, color_text_dim);
    drawModeHotkeyHint(.single);
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
    const h: i32 = 196;
    drawPanel(x, y, w, h, "CONTROLS");

    var line_y: i32 = y + 50;
    drawHelpLine("Move", "Left/Right/Down", x + 20, line_y);
    line_y += 28;
    drawHelpLine("Rotate", "X/Up, Z, A", x + 20, line_y);
    line_y += 28;
    drawHelpLine("Drop", "Space", x + 20, line_y);
    line_y += 28;
    drawHelpLine("Hold", "C / Left Shift", x + 20, line_y);

    rl.drawLine(x + 18, y + h - 38, x + w - 18, y + h - 38, color_panel_border.alpha(0.45));
    rl.drawText("P pause   R restart", x + 20, y + h - 25, 14, color_text_dim);
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
    rl.drawText(title, layout.x, layout.y - 44, 18, color_text);
    if (subtitle.len > 0) rl.drawText(subtitle, layout.x + 82, layout.y - 41, 12, color_text_dim);

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
        rl.drawLine(segment_x, layout.y - 5, @min(segment_x + 10, layout.x + board_w), layout.y - 5, color_warning.alpha(0.75));
    }

    rl.drawText("SPAWN", layout.x + 4, layout.y - 18, 11, color_warning);
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
    const h: i32 = 430;
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
    drawMetric("Combo", comboText(state.combo_counter), x + 18, line_y, if (state.combo_counter >= 1) color_warning else color_text_dim);
    line_y += 25;
    drawMetric("B2B", if (state.back_to_back_active) "active" else "off", x + 18, line_y, if (state.back_to_back_active) color_warning else color_text_dim);

    line_y += 30;
    drawSectionTitle("LAST LOCK", x + 18, line_y);
    line_y += 26;

    if (state.last_lock_result) |result| {
        drawMetric("Piece", pieceLabel(result.piece_kind), x + 18, line_y, pieceColor(result.piece_kind));
        line_y += 23;
        drawMetric("Clear", clearSummary(result), x + 18, line_y, if (result.lines_cleared > 0 or result.t_spin_kind != .none) color_accent else color_text_dim);
        line_y += 23;
        drawMetric("Attack", rl.textFormat("+%i", .{@as(i32, result.attack_lines)}), x + 18, line_y, if (result.attack_lines > 0) color_danger else color_text_dim);
        line_y += 23;
        drawMetric("Score +", rl.textFormat("%u", .{result.score_delta}), x + 18, line_y, color_text);
        if (result.perfect_clear) {
            line_y += 23;
            drawMetric("Perfect", "YES", x + 18, line_y, color_warning);
        }
    } else {
        drawMetric("Clear", "none yet", x + 18, line_y, color_text_dim);
    }

    rl.drawText(exitInstructionText(), x + 18, y + h - 24, 12, color_text_dim);
}

fn drawVersusPlayer(player: match_mod.PlayerIndex, match_state: *const match_mod.Match, player_result: match_mod.PlayerStepResult, outcome_verified: bool) void {
    const runtime = match_state.playerConst(player);
    const layout = versusBoardLayout(player);
    drawVersusSidePanels(player, &runtime.game);
    drawBoard(&runtime.game, layout, playerMatrixTitle(player), "");
    drawVersusStatusPanel(player, match_state, runtime, player_result, outcome_verified);
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

fn drawVersusStatusPanel(player: match_mod.PlayerIndex, match_state: *const match_mod.Match, runtime: *const match_mod.PlayerRuntime, player_result: match_mod.PlayerStepResult, outcome_verified: bool) void {
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
        if (outcome_verified) {
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
        } else {
            state_label = "unverified";
            state_color = color_warning;
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
    const y: i32 = 626;
    const w: i32 = 1044;
    const h: i32 = 70;
    drawPanel(x, y, w, h, "LOCAL CONTROLS");
    rl.drawText("Global: P pause | R restart | Modes 1 one-player, 2 local, 3 online", x + 338, y + 18, 12, color_text_dim);
    rl.drawLine(x + 522, y + 40, x + 522, y + h - 12, color_panel_border.alpha(0.45));
    rl.drawText("P1: A/D move | S soft | Space hard | W CW | Q CCW | E 180 | LShift", x + 18, y + 44, 12, color_text);
    rl.drawText("P2: Arrows move/soft | Enter hard | Up CW | . CCW | / 180 | RShift", x + 542, y + 44, 12, color_text);
}

fn drawOnlineControlsStrip(online: *const OnlineState) void {
    const x: i32 = 28;
    const y: i32 = 624;
    const w: i32 = 1044;
    const h: i32 = 70;
    drawPanel(x, y, w, h, "ONLINE");
    rl.drawText(rl.textFormat("%s | %s | copy %s", .{
        online.roleText().ptr,
        online.phaseShortText().ptr,
        web_invite.copyStatus().text().ptr,
    }), x + 18, y + 36, 13, color_text);
    if (online.room_len > 0) {
        const room = online.roomId();
        const shown_len = @min(room.len, 42);
        const suffix: [:0]const u8 = if (shown_len < room.len) "..." else "";
        rl.drawText(rl.textFormat("Room %.*s%s", .{
            @as(i32, @intCast(shown_len)),
            room.ptr,
            suffix.ptr,
        }), x + 18, y + 56, 13, color_text_dim);
    } else {
        rl.drawText("No active room", x + 18, y + 56, 13, color_text_dim);
    }
    rl.drawText("Move: arrows/down | Space hard | X/Up/Z/A rotate | LShift hold", x + 400, y + 36, 13, color_text);
    rl.drawText("C copy invite | P pause | R no rematch | 1/2 switch modes", x + 400, y + 56, 13, color_text_dim);
}

fn drawOnlineWaitingPanel(online: *const OnlineState) void {
    const x: i32 = 250;
    const y: i32 = 160;
    const w: i32 = 600;
    const h: i32 = 390;
    drawPanel(x, y, w, h, "ONLINE INVITE");
    drawTextSlice(online.message(), x + 28, y + 56, 18, color_text);
    rl.drawText(rl.textFormat("Role: %s", .{online.roleText().ptr}), x + 28, y + 92, 16, color_text_dim);
    rl.drawText(rl.textFormat("Phase: %s", .{online.phaseText().ptr}), x + 28, y + 118, 16, color_text_dim);
    drawOnlineProfileSummary("You", &online.local_profile, x + 28, y + 150, color_text);
    if (online.remote_profile) |*remote| {
        drawOnlineProfileSummary("Opponent", remote, x + 28, y + 174, color_text_dim);
    } else {
        rl.drawText("Opponent: Waiting for opponent profile...", x + 28, y + 174, 14, color_text_dim);
    }
    if (!online.localProfileChangesArePersistent()) {
        rl.drawText(online.localProfileStorageNote(), x + 28, y + 198, 13, color_warning);
    }

    if (online.room_len > 0) {
        rl.drawText(rl.textFormat("Room: %.*s", .{ @as(i32, @intCast(online.roomId().len)), online.roomId().ptr }), x + 28, y + 220, 16, color_accent);
    }
    if (online.join_url_len > 0) {
        rl.drawText("Join URL:", x + 28, y + 252, 15, color_text_dim);
        const url = online.joinUrl();
        const shown_len = @min(url.len, 88);
        const suffix: [:0]const u8 = if (shown_len < url.len) "..." else "";
        rl.drawText(rl.textFormat("%.*s%s", .{
            @as(i32, @intCast(shown_len)),
            url.ptr,
            suffix.ptr,
        }), x + 28, y + 274, 13, color_text);
    }

    rl.drawText("Press C to copy the invite link. Press 1/2 to leave, or 3 from another mode for a fresh invite.", x + 28, y + h - 54, 15, color_text_dim);
    rl.drawText(rl.textFormat("Transport: %s | peers %i | last error %s", .{
        web_transport.status().text().ptr,
        @as(i32, web_transport.peerCount()),
        web_transport.lastError().text().ptr,
    }), x + 28, y + h - 28, 13, color_text_dim);
}

fn drawOnlineProfileSummary(label: [:0]const u8, card: *const profile.ProfileCard, x: i32, y: i32, color: rl.Color) void {
    rl.drawText(rl.textFormat("%s: %.*s | Local rating %u | %u-%u-%u", .{
        label.ptr,
        @as(i32, @intCast(card.nicknameText().len)),
        card.nicknameText().ptr,
        card.rating,
        card.wins,
        card.losses,
        card.draws,
    }), x, y, 14, color);
}

fn drawOnlineBoardProfile(online: *const OnlineState, player: match_mod.PlayerIndex) void {
    const layout = versusBoardLayout(player);
    const x = layout.x + 6;
    const y = layout.y - 28;
    if (online.profileForPlayer(player)) |card| {
        const nickname = card.nicknameText();
        rl.drawText(rl.textFormat("%.*s", .{ @as(i32, @intCast(nickname.len)), nickname.ptr }), x, y, 12, color_text);
        rl.drawText(rl.textFormat("Local rating %u  W-L-D %u-%u-%u", .{
            card.rating,
            card.wins,
            card.losses,
            card.draws,
        }), x, y + 15, 11, color_text_dim);
    } else {
        rl.drawText("Waiting for opponent profile...", x, y + 5, 11, color_text_dim);
    }
}

fn drawOnlineWaitingOverlay(online: *const OnlineState) void {
    drawScreenOverlay("ONLINE WAIT", rl.textFormat("%.*s", .{ @as(i32, @intCast(online.message().len)), online.message().ptr }), color_accent);
}

fn drawOnlineTerminalOverlay(online: *const OnlineState) void {
    const title: [:0]const u8 = switch (online.terminal) {
        .finished => if (online.hasVerifiedResult()) if (online.lockstepPeerConst()) |peer| if (peer.match.outcome) |outcome| matchOutcomeTitle(outcome) else "MATCH COMPLETE" else "MATCH COMPLETE" else "MATCH COMPLETE",
        .unverified_result => "UNVERIFIED RESULT",
        .disconnected => "DISCONNECTED",
        .desynced => "DESYNC",
        .unsupported => "WEB ONLY",
        .failed => "ONLINE ERROR",
        .none => return,
    };
    const accent = switch (online.terminal) {
        .finished => color_accent,
        .unverified_result, .disconnected, .unsupported => color_warning,
        .desynced, .failed => color_danger,
        .none => color_text,
    };
    drawScreenOverlay(title, rl.textFormat("%.*s", .{ @as(i32, @intCast(online.message().len)), online.message().ptr }), accent);
}

fn drawOnlineMatchOverlay(online: *const OnlineState, match_state: *const match_mod.Match) void {
    if (match_state.outcome) |outcome| {
        if (online.hasVerifiedResult()) {
            drawScreenOverlay(matchOutcomeTitle(outcome), "Online rematch is not implemented; press 1/2/3 for a fresh mode", if (isDraw(outcome)) color_warning else color_accent);
        } else {
            drawScreenOverlay("VERIFYING RESULT", "Waiting for opponent result; disconnects are unverified", color_warning);
        }
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
        screen_height - 16,
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

// SPDX-License-Identifier: GPL-3.0-or-later

//! Browser-free online match setup/ack session layer.
//!
//! This module owns only the Phase 6 lifecycle handshake around the existing
//! deterministic protocol and lockstep peer. It does not import raylib or any
//! browser API. Transport code should move encoded `protocol.Setup` and
//! `protocol.Ack` packets as opaque bytes, then hand decoded lifecycle packets
//! to `Session` before runtime input/state-hash packets are routed to
//! `lockstep.Peer`.

const std = @import("std");
const input = @import("input");
const lockstep = @import("lockstep");
const match_mod = @import("match");
const protocol = @import("protocol");

pub const DefaultInputDelayFrames: u16 = 8;

pub const HostProtocolSlot: u8 = 0;
pub const JoinerProtocolSlot: u8 = 1;
pub const HostPlayerIndex: match_mod.PlayerIndex = .p1;
pub const JoinerPlayerIndex: match_mod.PlayerIndex = .p2;

pub const Role = enum {
    host,
    joiner,
};

pub const State = enum {
    /// Joiner has not accepted a host setup yet.
    waiting_for_setup,
    /// Host has created setup and waits for the joiner's ack.
    waiting_for_ack,
    /// Joiner accepted setup and can encode/send its ack.
    setup_received,
    /// Local lifecycle handshake is complete for this peer.
    playing,
};

pub const LifecycleError = error{
    InvalidSetupSenderSlot,
    InvalidAckSenderSlot,
    InvalidAckedSlot,
    InvalidInputDelay,
    InvalidLifecycleSenderSlot,
    InvalidResultSenderSlot,
    WrongMatchId,
    WrongRole,
    UnexpectedSetup,
    UnexpectedAck,
    UnexpectedPacketType,
    SetupUnavailable,
    MatchUnavailable,
    PeerUnavailable,
};

pub const ResultValidationError = error{
    ResultOutcomeMismatch,
    ResultFrameCursorMismatch,
    ResultStateHashMismatch,
};

pub const InputBatcherError = error{
    InputBatchEmpty,
    InputBatchFull,
    NonContiguousInputBatch,
    WrongInputBatchStream,
} || protocol.InputBatchInitError || protocol.EncodeError;

pub const OnlineSessionError = LifecycleError ||
    ResultValidationError ||
    InputBatcherError ||
    match_mod.InvalidGarbageSettings ||
    lockstep.LockstepError ||
    protocol.EncodeError ||
    protocol.DecodeError;

pub const EncodedPacket = lockstep.EncodedPacket;

pub const ResultValidationStatus = enum {
    pending_local_result,
    accepted,
};

pub const ResultCompletionState = struct {
    pending_remote_result: bool = false,
    sent_result: bool = false,
    has_local_outcome: bool = false,
    result_drain_active: bool = false,
};

pub const PeerLeaveDisconnectAction = enum {
    disconnect_now,
    defer_disconnect,
    pending_result_timed_out,
};

pub const PeerLeaveDisconnectState = struct {
    completion: ResultCompletionState = .{},
    pending_result_peer_leave_frames: u16 = 0,
    pending_result_peer_leave_grace_frames: u16 = 0,
};

pub fn shouldDeferPeerLeaveDisconnect(state: ResultCompletionState) bool {
    return state.pending_remote_result or
        state.sent_result or
        state.has_local_outcome or
        state.result_drain_active;
}

pub fn peerLeaveDisconnectAction(state: PeerLeaveDisconnectState) PeerLeaveDisconnectAction {
    if (state.completion.sent_result or state.completion.has_local_outcome or state.completion.result_drain_active) return .defer_disconnect;
    if (state.completion.pending_remote_result) {
        if (state.pending_result_peer_leave_frames >= state.pending_result_peer_leave_grace_frames) return .pending_result_timed_out;
        return .defer_disconnect;
    }
    return .disconnect_now;
}

pub const InputBatcher = struct {
    match_id: u64 = 0,
    player_slot: u8 = 0,
    first_frame: u64 = 0,
    count: u8 = 0,
    held_frames: u8 = 0,
    inputs: [protocol.MaxInputBatchCount]input.FrameInput = [_]input.FrameInput{.{}} ** protocol.MaxInputBatchCount,

    pub fn hasPending(self: *const InputBatcher) bool {
        return self.count > 0;
    }

    pub fn isFull(self: *const InputBatcher) bool {
        return self.count >= protocol.MaxInputBatchCount;
    }

    pub fn clear(self: *InputBatcher) void {
        self.* = .{};
    }

    pub fn noteFrameHeld(self: *InputBatcher) void {
        if (!self.hasPending()) return;
        if (self.held_frames < std.math.maxInt(u8)) self.held_frames += 1;
    }

    pub fn append(self: *InputBatcher, sample: lockstep.LocalInputSample) InputBatcherError!void {
        if (self.count >= protocol.MaxInputBatchCount) return error.InputBatchFull;
        if (self.count == 0) {
            self.match_id = sample.match_id;
            self.player_slot = sample.player_slot;
            self.first_frame = sample.frame;
            self.held_frames = 0;
        } else {
            if (self.match_id != sample.match_id or self.player_slot != sample.player_slot) return error.WrongInputBatchStream;
            const expected_frame = std.math.add(u64, self.first_frame, @as(u64, self.count)) catch return error.NonContiguousInputBatch;
            if (sample.frame != expected_frame) return error.NonContiguousInputBatch;
        }
        self.inputs[self.count] = sample.frame_input;
        self.count += 1;
    }

    pub fn shouldFlush(self: *const InputBatcher, target_count: u8, max_hold_frames: u8) bool {
        if (!self.hasPending()) return false;
        return self.count >= target_count or self.held_frames >= max_hold_frames or self.isFull();
    }

    pub fn encode(self: *const InputBatcher) InputBatcherError!EncodedPacket {
        if (!self.hasPending()) return error.InputBatchEmpty;
        const batch = try protocol.InputBatch.init(self.match_id, self.player_slot, self.first_frame, self.inputs[0..self.count]);
        var encoded = EncodedPacket{};
        encoded.len = try protocol.encode(.{ .input_batch = batch }, encoded.bytes[0..]);
        return encoded;
    }
};

pub const Session = struct {
    role: Role,
    state: State,
    match_id: ?u64 = null,
    input_delay_frames: u16 = DefaultInputDelayFrames,
    setup: ?protocol.Setup = null,
    settings: ?match_mod.MatchSettings = null,
    peer: ?lockstep.Peer = null,

    pub fn initHost(match_id: u64, settings: match_mod.MatchSettings) OnlineSessionError!Session {
        return initHostWithInputDelay(match_id, settings, DefaultInputDelayFrames);
    }

    pub fn initHostWithInputDelay(match_id: u64, settings: match_mod.MatchSettings, input_delay_frames: u16) OnlineSessionError!Session {
        const setup = try setupFromMatchSettings(match_id, settings, input_delay_frames);
        return .{
            .role = .host,
            .state = .waiting_for_ack,
            .match_id = match_id,
            .input_delay_frames = input_delay_frames,
            .setup = setup,
            .settings = settings,
            .peer = try lockstep.Peer.init(settings, HostPlayerIndex, input_delay_frames, match_id),
        };
    }

    pub fn initJoiner() Session {
        return .{
            .role = .joiner,
            .state = .waiting_for_setup,
        };
    }

    pub fn initJoinerForMatch(match_id: u64) Session {
        return .{
            .role = .joiner,
            .state = .waiting_for_setup,
            .match_id = match_id,
        };
    }

    pub fn setupPacket(self: *const Session) OnlineSessionError!protocol.Setup {
        if (self.role != .host) return error.WrongRole;
        return self.setup orelse return error.SetupUnavailable;
    }

    pub fn encodeSetupPacket(self: *const Session) OnlineSessionError!EncodedPacket {
        return encodePacket(.{ .setup = try self.setupPacket() });
    }

    pub fn acceptSetup(self: *Session, setup: protocol.Setup) OnlineSessionError!void {
        if (self.role != .joiner) return error.WrongRole;
        if (self.state != .waiting_for_setup) return error.UnexpectedSetup;
        if (setup.sender_slot != HostProtocolSlot) return error.InvalidSetupSenderSlot;
        if (self.match_id) |expected_match_id| {
            if (setup.match_id != expected_match_id) return error.WrongMatchId;
        }
        try validateInputDelayFrames(setup.input_delay_frames);

        const settings = try matchSettingsFromSetup(setup);
        self.match_id = setup.match_id;
        self.input_delay_frames = setup.input_delay_frames;
        self.setup = setup;
        self.settings = settings;
        self.peer = try lockstep.Peer.init(settings, JoinerPlayerIndex, setup.input_delay_frames, setup.match_id);
        self.state = .setup_received;
    }

    pub fn acceptSetupBytes(self: *Session, bytes: []const u8) OnlineSessionError!void {
        try self.acceptSetup(try decodeSetupPacket(bytes));
    }

    pub fn buildJoinerAck(self: *const Session) OnlineSessionError!protocol.Ack {
        if (self.role != .joiner) return error.WrongRole;
        if (self.state != .setup_received and self.state != .playing) return error.UnexpectedAck;
        const match_id = self.match_id orelse return error.MatchUnavailable;
        const peer = if (self.peer) |*peer| peer else return error.PeerUnavailable;
        return .{
            .match_id = match_id,
            .sender_slot = JoinerProtocolSlot,
            .acked_slot = HostProtocolSlot,
            .next_needed_frame = peer.frameCursor(),
        };
    }

    /// Encode the joiner ack and mark the joiner's local handshake complete.
    pub fn encodeJoinerAck(self: *Session) OnlineSessionError!EncodedPacket {
        const ack = try self.buildJoinerAck();
        const encoded = try encodeAckPacket(ack);
        self.state = .playing;
        return encoded;
    }

    pub fn acceptAck(self: *Session, ack: protocol.Ack) OnlineSessionError!void {
        if (self.role != .host) return error.WrongRole;
        if (self.state != .waiting_for_ack) return error.UnexpectedAck;
        const match_id = self.match_id orelse return error.MatchUnavailable;
        if (ack.match_id != match_id) return error.WrongMatchId;
        if (ack.sender_slot != JoinerProtocolSlot) return error.InvalidAckSenderSlot;
        if (ack.acked_slot != HostProtocolSlot) return error.InvalidAckedSlot;

        try self.ensureHostPeer();
        self.state = .playing;
    }

    pub fn acceptAckBytes(self: *Session, bytes: []const u8) OnlineSessionError!void {
        try self.acceptAck(try decodeAckPacket(bytes));
    }

    fn ensureHostPeer(self: *Session) OnlineSessionError!void {
        if (self.peer != null) return;
        const match_id = self.match_id orelse return error.MatchUnavailable;
        const settings = self.settings orelse return error.MatchUnavailable;
        self.peer = try lockstep.Peer.init(settings, HostPlayerIndex, self.input_delay_frames, match_id);
    }
};

pub fn setupFromMatchSettings(match_id: u64, settings: match_mod.MatchSettings, input_delay_frames: u16) OnlineSessionError!protocol.Setup {
    try validateInputDelayFrames(input_delay_frames);
    try settings.validate();

    return switch (settings.ruleset) {
        .modern => |modern| .{
            .match_id = match_id,
            .sender_slot = HostProtocolSlot,
            .ruleset = .modern,
            .input_delay_frames = input_delay_frames,
            .p1_seed = settings.player_seeds[0],
            .p2_seed = settings.player_seeds[1],
            .garbage_seed = modern.garbage_seed,
            .hole_num = modern.garbage.hole_change_chance.numerator,
            .hole_den = modern.garbage.hole_change_chance.denominator,
            .initial_hole_p1 = modern.garbage.initial_holes[0],
            .initial_hole_p2 = modern.garbage.initial_holes[1],
        },
    };
}

pub fn matchSettingsFromSetup(setup: protocol.Setup) OnlineSessionError!match_mod.MatchSettings {
    const settings = switch (setup.ruleset) {
        .modern => match_mod.MatchSettings{
            .player_seeds = .{ setup.p1_seed, setup.p2_seed },
            .ruleset = .{ .modern = .{
                .garbage_seed = setup.garbage_seed,
                .garbage = .{
                    .hole_change_chance = .{
                        .numerator = setup.hole_num,
                        .denominator = setup.hole_den,
                    },
                    .initial_holes = .{ setup.initial_hole_p1, setup.initial_hole_p2 },
                },
            } },
        },
    };
    try settings.validate();
    return settings;
}

pub fn validateInputDelayFrames(input_delay_frames: u16) LifecycleError!void {
    if (@as(usize, input_delay_frames) >= lockstep.MaxBufferedFrames) return error.InvalidInputDelay;
}

pub fn encodeSetupPacket(setup: protocol.Setup) OnlineSessionError!EncodedPacket {
    return encodePacket(.{ .setup = setup });
}

pub fn encodeAckPacket(ack: protocol.Ack) OnlineSessionError!EncodedPacket {
    return encodePacket(.{ .ack = ack });
}

pub fn decodeSetupPacket(bytes: []const u8) OnlineSessionError!protocol.Setup {
    return switch (try protocol.decode(bytes)) {
        .setup => |setup| setup,
        else => error.UnexpectedPacketType,
    };
}

pub fn decodeAckPacket(bytes: []const u8) OnlineSessionError!protocol.Ack {
    return switch (try protocol.decode(bytes)) {
        .ack => |ack| ack,
        else => error.UnexpectedPacketType,
    };
}

pub fn localProtocolSlotForRole(role: Role) u8 {
    return switch (role) {
        .host => HostProtocolSlot,
        .joiner => JoinerProtocolSlot,
    };
}

pub fn remoteProtocolSlotForRole(role: Role) u8 {
    return switch (role) {
        .host => JoinerProtocolSlot,
        .joiner => HostProtocolSlot,
    };
}

pub fn validateLifecycleSender(role: Role, sender_slot: u8) LifecycleError!void {
    if (sender_slot != remoteProtocolSlotForRole(role)) return error.InvalidLifecycleSenderSlot;
}

/// Return true only when a caller already knows the active match id and this
/// packet envelope belongs to it. A missing local match id is deliberately not
/// treated as a match; joiners waiting for the first setup must handle that
/// state explicitly instead of accepting every lifecycle packet as current.
pub fn packetMatchesKnownMatch(current_match_id: ?u64, bytes: []const u8) protocol.DecodeError!bool {
    const match_id = current_match_id orelse return false;
    return (try protocol.peekMatchId(bytes)) == match_id;
}

/// Runtime/lifecycle stale filter for an already-established session. When no
/// local match is known yet, callers still need to decode candidate setup
/// packets. Once a match exists, nonmatching envelopes are stale room noise and
/// should be ignored before body decoding can make wrong-match packets fatal.
pub fn shouldIgnorePacketForKnownMatch(current_match_id: ?u64, bytes: []const u8) protocol.DecodeError!bool {
    const match_id = current_match_id orelse return false;
    return (try protocol.peekMatchId(bytes)) != match_id;
}

pub fn resultOutcomeFromMatchOutcome(outcome: match_mod.MatchOutcome) protocol.ResultOutcome {
    return switch (outcome) {
        .winner => |winner| switch (winner) {
            .p1 => .p1_win,
            .p2 => .p2_win,
        },
        .draw => .draw,
    };
}

pub fn validateRemoteResult(role: Role, peer: *const lockstep.Peer, result: protocol.Result) (LifecycleError || ResultValidationError)!ResultValidationStatus {
    if (result.match_id != peer.match_id) return error.WrongMatchId;
    if (result.sender_slot != remoteProtocolSlotForRole(role)) return error.InvalidResultSenderSlot;

    const local_outcome = peer.match.outcome orelse {
        if (result.frame_cursor <= peer.frameCursor()) return error.ResultFrameCursorMismatch;
        return .pending_local_result;
    };
    if (result.outcome != resultOutcomeFromMatchOutcome(local_outcome)) return error.ResultOutcomeMismatch;
    if (result.frame_cursor != peer.frameCursor()) return error.ResultFrameCursorMismatch;
    if (result.state_hash != peer.stateHash()) return error.ResultStateHashMismatch;
    return .accepted;
}

fn encodePacket(packet: protocol.Packet) OnlineSessionError!EncodedPacket {
    var encoded = EncodedPacket{};
    encoded.len = try protocol.encode(packet, encoded.bytes[0..]);
    return encoded;
}

fn testSettings() match_mod.MatchSettings {
    return .{
        .player_seeds = .{ 0x1111_2222_3333_4444, 0x5555_6666_7777_8888 },
        .ruleset = .{ .modern = .{
            .garbage_seed = 0x9999_aaaa_bbbb_cccc,
            .garbage = .{
                .hole_change_chance = .{ .numerator = 1, .denominator = 4 },
                .initial_holes = .{ 2, 7 },
            },
        } },
    };
}

const TestMatchId: u64 = 0x0bad_f00d_cafe_babe;
const OtherMatchId: u64 = 0xfeed_face_1234_5678;

fn testSetup() !protocol.Setup {
    return setupFromMatchSettings(TestMatchId, testSettings(), DefaultInputDelayFrames);
}

fn expectSessionState(session: *const Session, expected: State) !void {
    try std.testing.expectEqual(expected, session.state);
}

test "host creates deterministic setup and local P1 lockstep peer/settings" {
    const settings = testSettings();
    var host = try Session.initHostWithInputDelay(TestMatchId, settings, DefaultInputDelayFrames);

    try std.testing.expectEqual(Role.host, host.role);
    try expectSessionState(&host, .waiting_for_ack);
    try std.testing.expectEqual(TestMatchId, host.match_id.?);
    try std.testing.expectEqual(DefaultInputDelayFrames, host.input_delay_frames);
    try std.testing.expectEqualDeep(settings, host.settings.?);

    const expected_setup = protocol.Setup{
        .match_id = TestMatchId,
        .sender_slot = HostProtocolSlot,
        .ruleset = .modern,
        .input_delay_frames = DefaultInputDelayFrames,
        .p1_seed = settings.player_seeds[0],
        .p2_seed = settings.player_seeds[1],
        .garbage_seed = 0x9999_aaaa_bbbb_cccc,
        .hole_num = 1,
        .hole_den = 4,
        .initial_hole_p1 = 2,
        .initial_hole_p2 = 7,
    };
    try std.testing.expectEqualDeep(expected_setup, host.setup.?);
    try std.testing.expectEqualDeep(expected_setup, try host.setupPacket());
    try std.testing.expectEqualDeep(settings, try matchSettingsFromSetup(expected_setup));
    try std.testing.expectEqualDeep(expected_setup, try setupFromMatchSettings(TestMatchId, settings, DefaultInputDelayFrames));

    const peer = if (host.peer) |*peer| peer else return error.PeerUnavailable;
    try std.testing.expectEqual(TestMatchId, peer.match_id);
    try std.testing.expectEqual(match_mod.PlayerIndex.p1, peer.local_slot);
    try std.testing.expectEqual(DefaultInputDelayFrames, peer.input_delay_frames);
    try std.testing.expectEqualDeep(settings, peer.match.settings);

    const encoded = try host.encodeSetupPacket();
    try std.testing.expectEqualDeep(expected_setup, try decodeSetupPacket(encoded.slice()));
}

test "joiner accepts setup and creates P2 lockstep peer with identical settings and match id" {
    const setup = try testSetup();
    var joiner = Session.initJoiner();

    try joiner.acceptSetup(setup);

    try std.testing.expectEqual(Role.joiner, joiner.role);
    try expectSessionState(&joiner, .setup_received);
    try std.testing.expectEqual(TestMatchId, joiner.match_id.?);
    try std.testing.expectEqual(DefaultInputDelayFrames, joiner.input_delay_frames);
    try std.testing.expectEqualDeep(setup, joiner.setup.?);
    try std.testing.expectEqualDeep(testSettings(), joiner.settings.?);

    const peer = if (joiner.peer) |*peer| peer else return error.PeerUnavailable;
    try std.testing.expectEqual(TestMatchId, peer.match_id);
    try std.testing.expectEqual(match_mod.PlayerIndex.p2, peer.local_slot);
    try std.testing.expectEqual(DefaultInputDelayFrames, peer.input_delay_frames);
    try std.testing.expectEqualDeep(testSettings(), peer.match.settings);
}

test "joiner sends valid ack" {
    var joiner = Session.initJoiner();
    try joiner.acceptSetup(try testSetup());

    const ack = try joiner.buildJoinerAck();
    try std.testing.expectEqual(TestMatchId, ack.match_id);
    try std.testing.expectEqual(JoinerProtocolSlot, ack.sender_slot);
    try std.testing.expectEqual(HostProtocolSlot, ack.acked_slot);
    try std.testing.expectEqual(@as(u64, 0), ack.next_needed_frame);
    try expectSessionState(&joiner, .setup_received);

    const encoded = try joiner.encodeJoinerAck();
    try expectSessionState(&joiner, .playing);
    try std.testing.expectEqualDeep(ack, try decodeAckPacket(encoded.slice()));
}

test "host accepts correct ack and rejects wrong-slot and wrong-match ack" {
    const valid_ack = protocol.Ack{
        .match_id = TestMatchId,
        .sender_slot = JoinerProtocolSlot,
        .acked_slot = HostProtocolSlot,
        .next_needed_frame = 0,
    };

    var host = try Session.initHostWithInputDelay(TestMatchId, testSettings(), DefaultInputDelayFrames);
    try host.acceptAck(valid_ack);
    try expectSessionState(&host, .playing);
    try std.testing.expect(host.peer != null);

    var recreate_peer_host = try Session.initHostWithInputDelay(TestMatchId, testSettings(), DefaultInputDelayFrames);
    recreate_peer_host.peer = null;
    try recreate_peer_host.acceptAck(valid_ack);
    try expectSessionState(&recreate_peer_host, .playing);
    const recreated_peer = if (recreate_peer_host.peer) |*peer| peer else return error.PeerUnavailable;
    try std.testing.expectEqual(match_mod.PlayerIndex.p1, recreated_peer.local_slot);
    try std.testing.expectEqual(TestMatchId, recreated_peer.match_id);

    var wrong_sender = try Session.initHostWithInputDelay(TestMatchId, testSettings(), DefaultInputDelayFrames);
    var sender_ack = valid_ack;
    sender_ack.sender_slot = HostProtocolSlot;
    try std.testing.expectError(error.InvalidAckSenderSlot, wrong_sender.acceptAck(sender_ack));
    try expectSessionState(&wrong_sender, .waiting_for_ack);

    var wrong_acked = try Session.initHostWithInputDelay(TestMatchId, testSettings(), DefaultInputDelayFrames);
    var acked_ack = valid_ack;
    acked_ack.acked_slot = JoinerProtocolSlot;
    try std.testing.expectError(error.InvalidAckedSlot, wrong_acked.acceptAck(acked_ack));
    try expectSessionState(&wrong_acked, .waiting_for_ack);

    var wrong_match = try Session.initHostWithInputDelay(TestMatchId, testSettings(), DefaultInputDelayFrames);
    var match_ack = valid_ack;
    match_ack.match_id = OtherMatchId;
    try std.testing.expectError(error.WrongMatchId, wrong_match.acceptAck(match_ack));
    try expectSessionState(&wrong_match, .waiting_for_ack);
}

test "joiner with expected match rejects stale setup before creating peer" {
    var stale_setup = try testSetup();
    stale_setup.match_id = OtherMatchId;
    var joiner = Session.initJoinerForMatch(TestMatchId);

    try std.testing.expectError(error.WrongMatchId, joiner.acceptSetup(stale_setup));
    try expectSessionState(&joiner, .waiting_for_setup);
    try std.testing.expectEqual(TestMatchId, joiner.match_id.?);
    try std.testing.expect(joiner.peer == null);

    try joiner.acceptSetup(try testSetup());
    try expectSessionState(&joiner, .setup_received);
    try std.testing.expectEqual(TestMatchId, joiner.match_id.?);
    try std.testing.expect(joiner.peer != null);
}

test "wrong setup sender slot rejected" {
    var setup = try testSetup();
    setup.sender_slot = JoinerProtocolSlot;
    var joiner = Session.initJoiner();

    try std.testing.expectError(error.InvalidSetupSenderSlot, joiner.acceptSetup(setup));
    try expectSessionState(&joiner, .waiting_for_setup);
    try std.testing.expect(joiner.peer == null);
}

test "invalid input delay rejected" {
    const invalid_delay: u16 = @intCast(lockstep.MaxBufferedFrames);
    try std.testing.expectError(error.InvalidInputDelay, Session.initHostWithInputDelay(TestMatchId, testSettings(), invalid_delay));

    var setup = try testSetup();
    setup.input_delay_frames = invalid_delay;
    var joiner = Session.initJoiner();
    try std.testing.expectError(error.InvalidInputDelay, joiner.acceptSetup(setup));
    try expectSessionState(&joiner, .waiting_for_setup);
}

test "invalid hole and garbage settings are rejected" {
    var zero_denominator = try testSetup();
    zero_denominator.hole_den = 0;
    try std.testing.expectError(error.InvalidHoleChangeDenominator, matchSettingsFromSetup(zero_denominator));
    var joiner_zero = Session.initJoiner();
    try std.testing.expectError(error.InvalidHoleChangeDenominator, joiner_zero.acceptSetup(zero_denominator));
    try expectSessionState(&joiner_zero, .waiting_for_setup);

    var oversized_numerator = try testSetup();
    oversized_numerator.hole_num = oversized_numerator.hole_den + 1;
    try std.testing.expectError(error.InvalidHoleChangeNumerator, matchSettingsFromSetup(oversized_numerator));
    var joiner_num = Session.initJoiner();
    try std.testing.expectError(error.InvalidHoleChangeNumerator, joiner_num.acceptSetup(oversized_numerator));
    try expectSessionState(&joiner_num, .waiting_for_setup);

    var bad_hole = try testSetup();
    bad_hole.initial_hole_p1 = protocol.MaxInitialHoleIndex + 1;
    try std.testing.expectError(error.InitialGarbageHoleOutOfBounds, matchSettingsFromSetup(bad_hole));
    var joiner_hole = Session.initJoiner();
    try std.testing.expectError(error.InitialGarbageHoleOutOfBounds, joiner_hole.acceptSetup(bad_hole));
    try expectSessionState(&joiner_hole, .waiting_for_setup);
}

test "duplicate and wrong lifecycle packets do not silently move to playing" {
    const setup = try testSetup();
    const setup_bytes = try encodeSetupPacket(setup);
    const ack = protocol.Ack{
        .match_id = TestMatchId,
        .sender_slot = JoinerProtocolSlot,
        .acked_slot = HostProtocolSlot,
        .next_needed_frame = 0,
    };
    const ack_bytes = try encodeAckPacket(ack);

    var joiner = Session.initJoiner();
    try joiner.acceptSetup(setup);
    try std.testing.expectError(error.UnexpectedSetup, joiner.acceptSetup(setup));
    try expectSessionState(&joiner, .setup_received);
    try std.testing.expectError(error.WrongRole, joiner.acceptAck(ack));
    try expectSessionState(&joiner, .setup_received);

    var host = try Session.initHostWithInputDelay(TestMatchId, testSettings(), DefaultInputDelayFrames);
    try std.testing.expectError(error.WrongRole, host.acceptSetup(setup));
    try expectSessionState(&host, .waiting_for_ack);
    try std.testing.expectError(error.UnexpectedPacketType, host.acceptAckBytes(setup_bytes.slice()));
    try expectSessionState(&host, .waiting_for_ack);

    var packet_joiner = Session.initJoiner();
    try std.testing.expectError(error.UnexpectedPacketType, packet_joiner.acceptSetupBytes(ack_bytes.slice()));
    try expectSessionState(&packet_joiner, .waiting_for_setup);

    try host.acceptAck(ack);
    try expectSessionState(&host, .playing);
    try std.testing.expectError(error.UnexpectedAck, host.acceptAck(ack));
    try expectSessionState(&host, .playing);
}

test "known-match stale filter drops wrong-match malformed lifecycle before body decode" {
    const ack = protocol.Ack{
        .match_id = OtherMatchId,
        .sender_slot = JoinerProtocolSlot,
        .acked_slot = HostProtocolSlot,
        .next_needed_frame = 0,
    };
    var encoded = try encodeAckPacket(ack);
    encoded.bytes[protocol.HeaderSize] = 2;

    try std.testing.expectError(error.InvalidPlayerSlot, protocol.decode(encoded.slice()));
    try std.testing.expect(try shouldIgnorePacketForKnownMatch(TestMatchId, encoded.slice()));
    try std.testing.expect(!(try packetMatchesKnownMatch(TestMatchId, encoded.slice())));
    try std.testing.expect(!(try packetMatchesKnownMatch(null, encoded.slice())));
    try std.testing.expect(!(try shouldIgnorePacketForKnownMatch(null, encoded.slice())));
}

test "lifecycle sender validation requires the expected remote slot" {
    try validateLifecycleSender(.host, JoinerProtocolSlot);
    try validateLifecycleSender(.joiner, HostProtocolSlot);
    try std.testing.expectError(error.InvalidLifecycleSenderSlot, validateLifecycleSender(.host, HostProtocolSlot));
    try std.testing.expectError(error.InvalidLifecycleSenderSlot, validateLifecycleSender(.joiner, JoinerProtocolSlot));
}

test "result completion state defers peer-leave disconnects only while finishing" {
    try std.testing.expect(!shouldDeferPeerLeaveDisconnect(.{}));
    try std.testing.expect(shouldDeferPeerLeaveDisconnect(.{ .pending_remote_result = true }));
    try std.testing.expect(shouldDeferPeerLeaveDisconnect(.{ .sent_result = true }));
    try std.testing.expect(shouldDeferPeerLeaveDisconnect(.{ .has_local_outcome = true }));
    try std.testing.expect(shouldDeferPeerLeaveDisconnect(.{ .result_drain_active = true }));

    try std.testing.expectEqual(PeerLeaveDisconnectAction.disconnect_now, peerLeaveDisconnectAction(.{}));
    try std.testing.expectEqual(PeerLeaveDisconnectAction.defer_disconnect, peerLeaveDisconnectAction(.{
        .completion = .{ .pending_remote_result = true },
        .pending_result_peer_leave_frames = 1,
        .pending_result_peer_leave_grace_frames = 2,
    }));
    try std.testing.expectEqual(PeerLeaveDisconnectAction.pending_result_timed_out, peerLeaveDisconnectAction(.{
        .completion = .{ .pending_remote_result = true },
        .pending_result_peer_leave_frames = 2,
        .pending_result_peer_leave_grace_frames = 2,
    }));
    try std.testing.expectEqual(PeerLeaveDisconnectAction.defer_disconnect, peerLeaveDisconnectAction(.{
        .completion = .{ .pending_remote_result = true, .has_local_outcome = true },
        .pending_result_peer_leave_frames = 2,
        .pending_result_peer_leave_grace_frames = 2,
    }));
}

test "remote result waits for local terminal outcome then validates final state" {
    var host = try Session.initHostWithInputDelay(TestMatchId, testSettings(), DefaultInputDelayFrames);
    const peer = if (host.peer) |*peer_value| peer_value else return error.PeerUnavailable;

    const pending_result = protocol.Result{
        .match_id = TestMatchId,
        .sender_slot = JoinerProtocolSlot,
        .outcome = .p1_win,
        .frame_cursor = 123,
        .state_hash = 0xaaaa,
    };
    try std.testing.expectEqual(ResultValidationStatus.pending_local_result, try validateRemoteResult(.host, peer, pending_result));

    var stale_result = pending_result;
    stale_result.frame_cursor = peer.frameCursor();
    try std.testing.expectError(error.ResultFrameCursorMismatch, validateRemoteResult(.host, peer, stale_result));

    peer.match.outcome = .{ .winner = .p1 };
    const valid_result = protocol.Result{
        .match_id = TestMatchId,
        .sender_slot = JoinerProtocolSlot,
        .outcome = resultOutcomeFromMatchOutcome(peer.match.outcome.?),
        .frame_cursor = peer.frameCursor(),
        .state_hash = peer.stateHash(),
    };
    try std.testing.expectEqual(ResultValidationStatus.accepted, try validateRemoteResult(.host, peer, valid_result));

    var wrong_sender = valid_result;
    wrong_sender.sender_slot = HostProtocolSlot;
    try std.testing.expectError(error.InvalidResultSenderSlot, validateRemoteResult(.host, peer, wrong_sender));

    var wrong_match = valid_result;
    wrong_match.match_id = OtherMatchId;
    try std.testing.expectError(error.WrongMatchId, validateRemoteResult(.host, peer, wrong_match));

    var wrong_outcome = valid_result;
    wrong_outcome.outcome = .p2_win;
    try std.testing.expectError(error.ResultOutcomeMismatch, validateRemoteResult(.host, peer, wrong_outcome));

    var wrong_frame = valid_result;
    wrong_frame.frame_cursor += 1;
    try std.testing.expectError(error.ResultFrameCursorMismatch, validateRemoteResult(.host, peer, wrong_frame));

    var wrong_hash = valid_result;
    wrong_hash.state_hash ^= 1;
    try std.testing.expectError(error.ResultStateHashMismatch, validateRemoteResult(.host, peer, wrong_hash));
}

test "input batcher coalesces contiguous local samples and rejects gaps" {
    var peer = try lockstep.Peer.init(testSettings(), HostPlayerIndex, 0, TestMatchId);
    var batcher = InputBatcher{};

    const first = try peer.sampleLocalInputFrame(.{ .left_down = true, .left_pressed = true });
    try batcher.append(first);
    try std.testing.expect(batcher.hasPending());
    try std.testing.expect(!batcher.shouldFlush(4, 3));

    batcher.noteFrameHeld();
    batcher.noteFrameHeld();
    batcher.noteFrameHeld();
    try std.testing.expect(batcher.shouldFlush(4, 3));

    const second = try peer.sampleLocalInputFrame(.{ .right_down = true, .right_pressed = true });
    try batcher.append(second);
    const encoded = try batcher.encode();
    switch (try protocol.decode(encoded.slice())) {
        .input_batch => |batch| {
            try std.testing.expectEqual(TestMatchId, batch.match_id);
            try std.testing.expectEqual(HostProtocolSlot, batch.player_slot);
            try std.testing.expectEqual(first.frame, batch.first_frame);
            try std.testing.expectEqual(@as(u8, 2), batch.count);
            try std.testing.expectEqualDeep(first.frame_input, batch.inputs[0]);
            try std.testing.expectEqualDeep(second.frame_input, batch.inputs[1]);
        },
        else => try std.testing.expect(false),
    }

    var gap = second;
    gap.frame += 2;
    try std.testing.expectError(error.NonContiguousInputBatch, batcher.append(gap));

    batcher.clear();
    try std.testing.expect(!batcher.hasPending());
    try std.testing.expectError(error.InputBatchEmpty, batcher.encode());
}

test "small fake packet exchange through two peers keeps state hashes equal" {
    var host = try Session.initHostWithInputDelay(TestMatchId, testSettings(), 2);
    var joiner = Session.initJoiner();

    const setup_bytes = try host.encodeSetupPacket();
    try joiner.acceptSetupBytes(setup_bytes.slice());
    const ack_bytes = try joiner.encodeJoinerAck();
    try host.acceptAckBytes(ack_bytes.slice());

    const p1 = if (host.peer) |*peer| peer else return error.PeerUnavailable;
    const p2 = if (joiner.peer) |*peer| peer else return error.PeerUnavailable;

    try std.testing.expectEqual(State.playing, host.state);
    try std.testing.expectEqual(State.playing, joiner.state);
    try std.testing.expectEqual(@as(usize, 2), try p1.stepAvailable());
    try std.testing.expectEqual(@as(usize, 2), try p2.stepAvailable());
    try std.testing.expectEqual(p1.frameCursor(), p2.frameCursor());
    try std.testing.expectEqual(p1.stateHash(), p2.stateHash());

    const p1_packet = try p1.sampleLocalInput(.{ .left_down = true, .left_pressed = true });
    const p2_packet = try p2.sampleLocalInput(.{ .right_down = true, .right_pressed = true });
    try p2.receiveBytes(p1_packet.slice());
    try p1.receiveBytes(p2_packet.slice());

    try std.testing.expectEqual(@as(usize, 1), try p1.stepAvailable());
    try std.testing.expectEqual(@as(usize, 1), try p2.stepAvailable());
    try std.testing.expectEqual(@as(u64, 3), p1.frameCursor());
    try std.testing.expectEqual(p1.frameCursor(), p2.frameCursor());
    try std.testing.expectEqual(p1.stateHash(), p2.stateHash());
    try std.testing.expect(p1.isOk());
    try std.testing.expect(p2.isOk());
}

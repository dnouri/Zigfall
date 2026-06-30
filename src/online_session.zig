// SPDX-License-Identifier: GPL-3.0-or-later

//! Browser-free online match setup/ack session layer.
//!
//! This module owns browser-free online lifecycle policy around the deterministic
//! protocol and lockstep peer. It does not import raylib or any browser API.
//! Transport code should move encoded setup/ack/profile/result/control packets
//! as opaque bytes, then hand decoded lifecycle packets to `Session` before
//! runtime input/state-hash packets are routed to `lockstep.Peer`.

const std = @import("std");
const input = @import("input");
const lockstep = @import("lockstep");
const match_mod = @import("match");
const profile = @import("profile");
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
    InvalidProfileSenderSlot,
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
    protocol.DecodeError ||
    protocol.ProfileInitError;

pub const EncodedPacket = lockstep.EncodedPacket;

pub const ResultValidationStatus = enum {
    pending_local_result,
    accepted,
};

pub const RemoteResultStatus = enum {
    none,
    pending_local_result,
    validated,
};

pub const RemoteResultPacketAction = enum {
    accept,
    ignore_duplicate,
    reject_conflict,
};

pub fn remoteResultPacketAction(pending_remote_result: ?protocol.Result, incoming: protocol.Result) RemoteResultPacketAction {
    const pending = pending_remote_result orelse return .accept;
    return if (std.meta.eql(pending, incoming)) .ignore_duplicate else .reject_conflict;
}

pub const ResultFinishAction = enum {
    no_local_outcome,
    send_local_result,
    wait_for_remote_result,
    start_verified_drain,
    wait_for_verified_drain,
    finish_verified,
    finish_unverified_disconnect,
    finish_unverified_timeout,
};

pub const ResultFinishState = struct {
    remote_result_status: RemoteResultStatus = .none,
    has_local_outcome: bool = false,
    sent_local_result: bool = false,
    remote_result_wait_frames_left: u16 = 0,
    verified_result_drain_started: bool = false,
    verified_result_drain_frames_left: u16 = 0,
    peer_left: bool = false,
};

pub fn resultFinishAction(state: ResultFinishState) ResultFinishAction {
    if (!state.has_local_outcome) return .no_local_outcome;
    if (state.remote_result_status == .validated) {
        if (!state.sent_local_result) return .send_local_result;
        if (!state.verified_result_drain_started) return .start_verified_drain;
        if (state.verified_result_drain_frames_left > 0) return .wait_for_verified_drain;
        return .finish_verified;
    }

    if (!state.sent_local_result) return .send_local_result;
    if (state.remote_result_wait_frames_left > 0) return .wait_for_remote_result;
    return if (state.peer_left) .finish_unverified_disconnect else .finish_unverified_timeout;
}

pub const TerminalPacketKind = enum {
    none,
    result,
    desync,
    disconnect,
};

pub const TerminalDrainAction = enum {
    no_op,
    wait,
    disconnect_now,
};

pub const TerminalDrainState = struct {
    packet: TerminalPacketKind = .none,
    frames_left: u16 = 0,
    disconnected: bool = false,
};

pub fn terminalDrainAction(state: TerminalDrainState) TerminalDrainAction {
    if (state.disconnected) return .no_op;
    if (state.packet == .none or state.frames_left == 0) return .disconnect_now;
    return .wait;
}

pub const TransportStatus = enum {
    unavailable,
    missing_js,
    disconnected,
    connecting,
    connected,
    busy,
};

pub const TransportError = enum {
    none,
    missing_js,
    unavailable,
    bad_room,
    join_failed,
    not_connected,
    no_peer,
    packet_too_large,
    queue_full,
    send_failed,
    buffer_too_small,
    busy,
};

pub const TransportHealthAction = enum {
    none,
    fail_extra_peer,
    fail_missing_js,
    unsupported,
    disconnected,
    fail_packet_too_large,
    fail_queue_full,
    fail_send_failed,
};

pub const PacketDecodePolicy = enum {
    decode_required,
    decode_optional_profile,
    ignore_stale,
};

fn packetTypeIsRuntimeOrResult(packet_type: protocol.PacketType) bool {
    return switch (packet_type) {
        .input_batch, .state_hash, .desync, .result => true,
        .setup, .ack, .disconnect, .profile => false,
    };
}

pub const TransportHealthState = struct {
    status: TransportStatus = .disconnected,
    last_error: TransportError = .none,
    health_error: TransportError = .none,
    ever_had_peer: bool = false,
    peer_leave_observed: bool = false,
    defer_peer_leave_disconnect: bool = false,
    ignore_async_send_failure: bool = false,
};

pub fn transportHealthAction(state: TransportHealthState) TransportHealthAction {
    switch (state.health_error) {
        .packet_too_large => return .fail_packet_too_large,
        .queue_full => return .fail_queue_full,
        .send_failed => if (!state.ignore_async_send_failure) return .fail_send_failed,
        else => {},
    }
    switch (state.last_error) {
        .packet_too_large => return .fail_packet_too_large,
        .queue_full => return .fail_queue_full,
        .send_failed => if (!state.ignore_async_send_failure) return .fail_send_failed,
        else => {},
    }

    switch (state.status) {
        .busy => return .fail_extra_peer,
        .missing_js => return .fail_missing_js,
        .unavailable => return .unsupported,
        .disconnected => if (state.ever_had_peer and !state.defer_peer_leave_disconnect) return .disconnected,
        .connecting, .connected => {},
    }

    switch (state.last_error) {
        .no_peer => if (state.ever_had_peer and !state.defer_peer_leave_disconnect) return .disconnected,
        else => {},
    }

    if (state.peer_leave_observed and !state.defer_peer_leave_disconnect) return .disconnected;
    return .none;
}

pub const ResultCompletionState = struct {
    pending_remote_result: bool = false,
    sent_result: bool = false,
    has_local_outcome: bool = false,
    result_drain_active: bool = false,
};

pub fn resultCompletionInProgress(state: ResultCompletionState) bool {
    return state.pending_remote_result or
        state.sent_result or
        state.has_local_outcome or
        state.result_drain_active;
}

pub const OnlineFreshModeState = struct {
    terminal: bool = false,
    completion: ResultCompletionState = .{},
};

pub fn canSwitchToFreshModeFromOnline(state: OnlineFreshModeState) bool {
    return state.terminal or !resultCompletionInProgress(state.completion);
}

pub const PeerLeaveDisconnectAction = enum {
    disconnect_now,
    defer_disconnect,
    pending_result_timed_out,
};

pub const PeerLeaveDisconnectState = struct {
    completion: ResultCompletionState = .{},
    pending_result_peer_leave_frames: u16 = 0,
    pending_result_peer_leave_grace_frames: u16 = 0,
    late_final_packet_peer_leave_frames: u16 = 0,
    late_final_packet_peer_leave_grace_frames: u16 = 0,
    allow_late_final_packet_grace: bool = false,
};

pub fn shouldDeferPeerLeaveDisconnect(state: ResultCompletionState) bool {
    return resultCompletionInProgress(state);
}

pub fn peerLeaveDisconnectAction(state: PeerLeaveDisconnectState) PeerLeaveDisconnectAction {
    if (state.completion.sent_result or state.completion.has_local_outcome or state.completion.result_drain_active) return .defer_disconnect;
    if (state.completion.pending_remote_result) {
        if (state.pending_result_peer_leave_frames >= state.pending_result_peer_leave_grace_frames) return .pending_result_timed_out;
        return .defer_disconnect;
    }
    if (state.allow_late_final_packet_grace) {
        if (state.late_final_packet_peer_leave_frames >= state.late_final_packet_peer_leave_grace_frames) return .disconnect_now;
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

    /// Encode the joiner ack without mutating session state; callers should
    /// mark the joiner playing only after the transport accepts the ack send.
    pub fn encodeJoinerAck(self: *const Session) OnlineSessionError!EncodedPacket {
        const ack = try self.buildJoinerAck();
        return try encodeAckPacket(ack);
    }

    pub fn markJoinerAckSent(self: *Session) OnlineSessionError!void {
        if (self.role != .joiner) return error.WrongRole;
        switch (self.state) {
            .setup_received => self.state = .playing,
            .playing => {},
            .waiting_for_setup, .waiting_for_ack => return error.UnexpectedAck,
        }
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

pub fn profilePacketFromCard(match_id: u64, sender_slot: u8, card: profile.ProfileCard) protocol.ProfileInitError!protocol.Profile {
    return protocol.Profile.init(
        match_id,
        sender_slot,
        card.playerId(),
        card.nicknameText(),
        card.rating,
        card.wins,
        card.losses,
        card.draws,
    );
}

pub fn encodeProfilePacket(match_id: u64, sender_slot: u8, card: profile.ProfileCard) OnlineSessionError!EncodedPacket {
    return encodePacket(.{ .profile = try profilePacketFromCard(match_id, sender_slot, card) });
}

pub fn validateRemoteProfile(role: Role, match_id: u64, profile_packet: protocol.Profile) LifecycleError!void {
    if (profile_packet.match_id != match_id) return error.WrongMatchId;
    if (profile_packet.sender_slot != remoteProtocolSlotForRole(role)) return error.InvalidProfileSenderSlot;
}

pub fn acceptRemoteProfile(role: Role, match_id: u64, profile_packet: protocol.Profile) LifecycleError!profile.ProfileCard {
    try validateRemoteProfile(role, match_id, profile_packet);
    return displayCardFromProfilePacket(profile_packet);
}

pub fn displayCardFromProfilePacket(profile_packet: protocol.Profile) profile.ProfileCard {
    var card = profile.ProfileCard.default();
    if (profile.isValidPlayerId(profile_packet.playerId())) {
        card.setPlayerId(profile_packet.playerId()) catch {};
    }
    card.setNickname(profile_packet.nicknameBytes()) catch {};
    if (profile_packet.rating <= profile.MaxRating) card.rating = profile_packet.rating;
    card.wins = profile_packet.wins;
    card.losses = profile_packet.losses;
    card.draws = profile_packet.draws;
    return card;
}

/// Decide whether a transport packet should be decoded as required gameplay /
/// lifecycle data, decoded as optional profile metadata, or ignored as stale
/// room noise. When a current match id is known, raw wrong-match envelopes are
/// ignored before version/type validation so stale future packets cannot poison
/// the current room. Runtime/result packets received before the session is
/// playing are also ignored after envelope peeking, before body decode. Profile
/// packets are display-only, so callers can treat body decode errors from
/// `.decode_optional_profile` as nonfatal notices.
pub fn packetDecodePolicyForKnownMatch(current_match_id: ?u64, bytes: []const u8) protocol.DecodeError!PacketDecodePolicy {
    return packetDecodePolicyForSessionState(current_match_id, null, bytes);
}

pub fn packetDecodePolicyForSessionState(current_match_id: ?u64, session_state: ?State, bytes: []const u8) protocol.DecodeError!PacketDecodePolicy {
    if (current_match_id) |match_id| {
        if (bytes.len >= protocol.HeaderSize and (try protocol.peekMatchId(bytes)) != match_id) return .ignore_stale;
    }

    const packet_type = try protocol.peekPacketType(bytes);
    if (packet_type == .profile and bytes.len < protocol.HeaderSize) return .decode_optional_profile;
    if (packet_type == .profile) return .decode_optional_profile;
    if (session_state) |state| {
        if (state != .playing and packetTypeIsRuntimeOrResult(packet_type)) return .ignore_stale;
    }
    return .decode_required;
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
    return (try packetDecodePolicyForKnownMatch(current_match_id, bytes)) == .ignore_stale;
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

pub fn profileResultForLocalRole(role: Role, outcome: match_mod.MatchOutcome) profile.VerifiedResult {
    return switch (outcome) {
        .draw => .draw,
        .winner => |winner| switch (role) {
            .host => if (winner == HostPlayerIndex) .win else .loss,
            .joiner => if (winner == JoinerPlayerIndex) .win else .loss,
        },
    };
}

pub fn opponentRatingForProfileUpdate(remote_card: ?profile.ProfileCard) profile.Rating {
    _ = remote_card;
    return profile.DefaultRating;
}

pub const ProfileRatingRecordAction = enum {
    ignore,
    record,
};

pub const ProfileRatingRecordState = struct {
    verified_result: bool = false,
    has_local_outcome: bool = false,
    final_counted_transition: bool = false,
    already_recorded: bool = false,
};

pub fn profileRatingRecordAction(state: ProfileRatingRecordState) ProfileRatingRecordAction {
    if (!state.verified_result or !state.has_local_outcome or !state.final_counted_transition or state.already_recorded) return .ignore;
    return .record;
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
    try expectSessionState(&joiner, .setup_received);
    try std.testing.expectEqualDeep(ack, try decodeAckPacket(encoded.slice()));

    try joiner.markJoinerAckSent();
    try expectSessionState(&joiner, .playing);
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
    try std.testing.expectEqual(PacketDecodePolicy.ignore_stale, try packetDecodePolicyForKnownMatch(TestMatchId, encoded.slice()));
    try std.testing.expect(try shouldIgnorePacketForKnownMatch(TestMatchId, encoded.slice()));
    try std.testing.expect(!(try packetMatchesKnownMatch(TestMatchId, encoded.slice())));
    try std.testing.expect(!(try packetMatchesKnownMatch(null, encoded.slice())));
    try std.testing.expect(!(try shouldIgnorePacketForKnownMatch(null, encoded.slice())));

    var wrong_version = try encodeAckPacket(ack);
    wrong_version.bytes[0] = protocol.ProtocolVersion + 1;
    try std.testing.expectError(error.InvalidVersion, protocol.decode(wrong_version.slice()));
    try std.testing.expectEqual(PacketDecodePolicy.ignore_stale, try packetDecodePolicyForKnownMatch(TestMatchId, wrong_version.slice()));
    try std.testing.expect(try shouldIgnorePacketForKnownMatch(TestMatchId, wrong_version.slice()));

    var unknown_type = try encodeAckPacket(ack);
    unknown_type.bytes[1] = 0xff;
    try std.testing.expectError(error.UnknownPacketType, protocol.decode(unknown_type.slice()));
    try std.testing.expectEqual(PacketDecodePolicy.ignore_stale, try packetDecodePolicyForKnownMatch(TestMatchId, unknown_type.slice()));
    try std.testing.expect(try shouldIgnorePacketForKnownMatch(TestMatchId, unknown_type.slice()));
}

test "pre-playing phase gate ignores runtime and result bodies before full decode" {
    const result = protocol.Result{
        .match_id = TestMatchId,
        .sender_slot = JoinerProtocolSlot,
        .outcome = .p1_win,
        .frame_cursor = 1,
        .state_hash = 2,
    };
    const encoded_result = try encodePacket(.{ .result = result });
    const truncated_result = encoded_result.bytes[0 .. protocol.ResultPacketSize - 1];
    try std.testing.expectError(error.TruncatedPacket, protocol.decode(truncated_result));
    try std.testing.expectEqual(PacketDecodePolicy.ignore_stale, try packetDecodePolicyForSessionState(TestMatchId, .waiting_for_ack, truncated_result));
    try std.testing.expectEqual(PacketDecodePolicy.decode_required, try packetDecodePolicyForSessionState(TestMatchId, .playing, truncated_result));

    const input_batch = try protocol.InputBatch.init(TestMatchId, JoinerProtocolSlot, 0, &[_]input.FrameInput{.{}});
    const encoded_input = try encodePacket(.{ .input_batch = input_batch });
    const truncated_input = encoded_input.bytes[0 .. protocol.InputBatchPrefixSize - 1];
    try std.testing.expectError(error.TruncatedPacket, protocol.decode(truncated_input));
    try std.testing.expectEqual(PacketDecodePolicy.ignore_stale, try packetDecodePolicyForSessionState(TestMatchId, .setup_received, truncated_input));

    var malformed_ack = try encodeAckPacket(.{
        .match_id = TestMatchId,
        .sender_slot = JoinerProtocolSlot,
        .acked_slot = HostProtocolSlot,
        .next_needed_frame = 0,
    });
    malformed_ack.bytes[protocol.HeaderSize] = 2;
    try std.testing.expectEqual(PacketDecodePolicy.decode_required, try packetDecodePolicyForSessionState(TestMatchId, .waiting_for_ack, malformed_ack.slice()));
}

test "profile decode policy keeps malformed profile metadata nonfatal" {
    const local_card = try profile.ProfileCard.init("p_remote", "Ada");
    var current_profile = try encodeProfilePacket(TestMatchId, JoinerProtocolSlot, local_card);
    const profile_len = current_profile.len;
    try std.testing.expectEqual(PacketDecodePolicy.decode_optional_profile, try packetDecodePolicyForKnownMatch(TestMatchId, current_profile.slice()));

    current_profile.bytes[profile_len] = 0xaa;
    try std.testing.expectError(error.TrailingBytes, protocol.decode(current_profile.bytes[0 .. profile_len + 1]));
    try std.testing.expectEqual(PacketDecodePolicy.decode_optional_profile, try packetDecodePolicyForKnownMatch(TestMatchId, current_profile.bytes[0 .. profile_len + 1]));

    var stale_profile = try encodeProfilePacket(OtherMatchId, JoinerProtocolSlot, local_card);
    stale_profile.bytes[protocol.HeaderSize + 1] = protocol.MaxProfilePlayerIdBytes + 1;
    try std.testing.expectError(error.ProfilePayloadTooLarge, protocol.decode(stale_profile.slice()));
    try std.testing.expectEqual(PacketDecodePolicy.ignore_stale, try packetDecodePolicyForKnownMatch(TestMatchId, stale_profile.slice()));

    const truncated_profile = current_profile.bytes[0 .. protocol.ProfilePacketPrefixSize - 1];
    try std.testing.expectError(error.TruncatedPacket, protocol.decode(truncated_profile));
    try std.testing.expectEqual(PacketDecodePolicy.decode_optional_profile, try packetDecodePolicyForKnownMatch(TestMatchId, truncated_profile));

    const short_profile = [_]u8{ protocol.ProtocolVersion, @intFromEnum(protocol.PacketType.profile) };
    try std.testing.expectError(error.TruncatedPacket, protocol.decode(&short_profile));
    try std.testing.expectEqual(PacketDecodePolicy.decode_optional_profile, try packetDecodePolicyForKnownMatch(TestMatchId, &short_profile));

    var malformed_ack = try encodeAckPacket(.{
        .match_id = TestMatchId,
        .sender_slot = JoinerProtocolSlot,
        .acked_slot = HostProtocolSlot,
        .next_needed_frame = 0,
    });
    malformed_ack.bytes[protocol.HeaderSize] = 2;
    try std.testing.expectEqual(PacketDecodePolicy.decode_required, try packetDecodePolicyForKnownMatch(TestMatchId, malformed_ack.slice()));
    try std.testing.expectError(error.InvalidPlayerSlot, protocol.decode(malformed_ack.slice()));
}

test "lifecycle sender validation requires the expected remote slot" {
    try validateLifecycleSender(.host, JoinerProtocolSlot);
    try validateLifecycleSender(.joiner, HostProtocolSlot);
    try std.testing.expectError(error.InvalidLifecycleSenderSlot, validateLifecycleSender(.host, HostProtocolSlot));
    try std.testing.expectError(error.InvalidLifecycleSenderSlot, validateLifecycleSender(.joiner, JoinerProtocolSlot));
}

test "profile packets convert local cards and validate remote sender and match" {
    const local_card = try profile.ProfileCard.init("p_local", "Ada Lovelace");
    const packet = try profilePacketFromCard(TestMatchId, HostProtocolSlot, local_card);
    try std.testing.expectEqual(TestMatchId, packet.match_id);
    try std.testing.expectEqual(HostProtocolSlot, packet.sender_slot);
    try std.testing.expectEqualStrings("p_local", packet.playerId());
    try std.testing.expectEqualStrings("Ada Lovelace", packet.nicknameBytes());

    const remote_packet = try profilePacketFromCard(TestMatchId, JoinerProtocolSlot, local_card);
    const accepted = try acceptRemoteProfile(.host, TestMatchId, remote_packet);
    try std.testing.expectEqualStrings(local_card.playerId(), accepted.playerId());
    try std.testing.expectEqualStrings(local_card.nicknameText(), accepted.nicknameText());

    var wrong_sender = remote_packet;
    wrong_sender.sender_slot = HostProtocolSlot;
    try std.testing.expectError(error.InvalidProfileSenderSlot, acceptRemoteProfile(.host, TestMatchId, wrong_sender));

    var wrong_match = remote_packet;
    wrong_match.match_id = OtherMatchId;
    try std.testing.expectError(error.WrongMatchId, acceptRemoteProfile(.host, TestMatchId, wrong_match));
}

test "malformed profile contents fall back without rejecting the match" {
    const raw = try protocol.Profile.init(
        TestMatchId,
        JoinerProtocolSlot,
        "bad id!",
        "\x00\xffAda!!!",
        65535,
        5,
        6,
        7,
    );

    const card = try acceptRemoteProfile(.host, TestMatchId, raw);
    try std.testing.expectEqualStrings(profile.DefaultPlayerId, card.playerId());
    try std.testing.expectEqualStrings("Ada", card.nicknameText());
    try std.testing.expectEqual(profile.DefaultRating, card.rating);
    try std.testing.expectEqual(@as(u32, 5), card.wins);
    try std.testing.expectEqual(@as(u32, 6), card.losses);
    try std.testing.expectEqual(@as(u32, 7), card.draws);
}

test "profile rating record policy only records peer-agreed completed outcomes once" {
    try std.testing.expectEqual(ProfileRatingRecordAction.ignore, profileRatingRecordAction(.{}));
    try std.testing.expectEqual(ProfileRatingRecordAction.ignore, profileRatingRecordAction(.{
        .verified_result = true,
    }));
    try std.testing.expectEqual(ProfileRatingRecordAction.ignore, profileRatingRecordAction(.{
        .has_local_outcome = true,
    }));
    try std.testing.expectEqual(ProfileRatingRecordAction.ignore, profileRatingRecordAction(.{
        .verified_result = true,
        .has_local_outcome = true,
    }));
    try std.testing.expectEqual(ProfileRatingRecordAction.record, profileRatingRecordAction(.{
        .verified_result = true,
        .has_local_outcome = true,
        .final_counted_transition = true,
    }));
    try std.testing.expectEqual(ProfileRatingRecordAction.ignore, profileRatingRecordAction(.{
        .verified_result = true,
        .has_local_outcome = true,
        .final_counted_transition = true,
        .already_recorded = true,
    }));

    try std.testing.expectEqual(profile.VerifiedResult.win, profileResultForLocalRole(.host, .{ .winner = .p1 }));
    try std.testing.expectEqual(profile.VerifiedResult.loss, profileResultForLocalRole(.host, .{ .winner = .p2 }));
    try std.testing.expectEqual(profile.VerifiedResult.loss, profileResultForLocalRole(.joiner, .{ .winner = .p1 }));
    try std.testing.expectEqual(profile.VerifiedResult.win, profileResultForLocalRole(.joiner, .{ .winner = .p2 }));
    try std.testing.expectEqual(profile.VerifiedResult.draw, profileResultForLocalRole(.host, .draw));
    try std.testing.expectEqual(profile.DefaultRating, opponentRatingForProfileUpdate(null));

    var untrusted_remote = profile.ProfileCard.default();
    untrusted_remote.rating = profile.MaxRating;
    try std.testing.expectEqual(profile.DefaultRating, opponentRatingForProfileUpdate(untrusted_remote));
}

test "remote result packet policy ignores duplicates instead of advancing finish drain" {
    const result = protocol.Result{
        .match_id = TestMatchId,
        .sender_slot = JoinerProtocolSlot,
        .outcome = .p1_win,
        .frame_cursor = 99,
        .state_hash = 0x1234,
    };
    try std.testing.expectEqual(RemoteResultPacketAction.accept, remoteResultPacketAction(null, result));
    try std.testing.expectEqual(RemoteResultPacketAction.ignore_duplicate, remoteResultPacketAction(result, result));

    var conflict = result;
    conflict.state_hash += 1;
    try std.testing.expectEqual(RemoteResultPacketAction.reject_conflict, remoteResultPacketAction(result, conflict));
}

test "profile rating waits through peer-agreed drain until the counted terminal transition" {
    try std.testing.expectEqual(ResultFinishAction.start_verified_drain, resultFinishAction(.{
        .remote_result_status = .validated,
        .has_local_outcome = true,
        .sent_local_result = true,
    }));
    try std.testing.expectEqual(ResultFinishAction.wait_for_verified_drain, resultFinishAction(.{
        .remote_result_status = .validated,
        .has_local_outcome = true,
        .sent_local_result = true,
        .verified_result_drain_started = true,
        .verified_result_drain_frames_left = 1,
    }));
    try std.testing.expectEqual(ProfileRatingRecordAction.ignore, profileRatingRecordAction(.{
        .verified_result = true,
        .has_local_outcome = true,
    }));

    // A late conflicting result, desync, or fatal packet before drain expiry
    // moves the UI to a not-counted terminal path; only this final counted
    // transition may mutate the browser-local profile.
    try std.testing.expectEqual(ResultFinishAction.finish_verified, resultFinishAction(.{
        .remote_result_status = .validated,
        .has_local_outcome = true,
        .sent_local_result = true,
        .verified_result_drain_started = true,
    }));
    try std.testing.expectEqual(ProfileRatingRecordAction.record, profileRatingRecordAction(.{
        .verified_result = true,
        .has_local_outcome = true,
        .final_counted_transition = true,
    }));
    try std.testing.expectEqual(ProfileRatingRecordAction.ignore, profileRatingRecordAction(.{
        .verified_result = true,
        .has_local_outcome = true,
        .final_counted_transition = true,
        .already_recorded = true,
    }));
}

test "result finish policy separates peer-agreed completion from unagreed local outcome" {
    try std.testing.expectEqual(ResultFinishAction.no_local_outcome, resultFinishAction(.{}));
    try std.testing.expectEqual(ResultFinishAction.send_local_result, resultFinishAction(.{
        .has_local_outcome = true,
    }));
    try std.testing.expectEqual(ResultFinishAction.wait_for_remote_result, resultFinishAction(.{
        .has_local_outcome = true,
        .sent_local_result = true,
        .remote_result_wait_frames_left = 1,
    }));
    try std.testing.expectEqual(ResultFinishAction.finish_unverified_timeout, resultFinishAction(.{
        .has_local_outcome = true,
        .sent_local_result = true,
    }));
    try std.testing.expectEqual(ResultFinishAction.finish_unverified_disconnect, resultFinishAction(.{
        .has_local_outcome = true,
        .sent_local_result = true,
        .peer_left = true,
    }));
    try std.testing.expectEqual(ResultFinishAction.send_local_result, resultFinishAction(.{
        .remote_result_status = .validated,
        .has_local_outcome = true,
    }));
    try std.testing.expectEqual(ResultFinishAction.start_verified_drain, resultFinishAction(.{
        .remote_result_status = .validated,
        .has_local_outcome = true,
        .sent_local_result = true,
    }));
    try std.testing.expectEqual(ResultFinishAction.wait_for_verified_drain, resultFinishAction(.{
        .remote_result_status = .validated,
        .has_local_outcome = true,
        .sent_local_result = true,
        .verified_result_drain_started = true,
        .verified_result_drain_frames_left = 1,
    }));
    try std.testing.expectEqual(ResultFinishAction.finish_verified, resultFinishAction(.{
        .remote_result_status = .validated,
        .has_local_outcome = true,
        .sent_local_result = true,
        .verified_result_drain_started = true,
    }));
}

test "timeout-edge peer result starts a fresh post-agreement drain" {
    try std.testing.expectEqual(ResultFinishAction.start_verified_drain, resultFinishAction(.{
        .remote_result_status = .validated,
        .has_local_outcome = true,
        .sent_local_result = true,
        .remote_result_wait_frames_left = 0,
        .verified_result_drain_started = false,
    }));
    try std.testing.expectEqual(ResultFinishAction.wait_for_verified_drain, resultFinishAction(.{
        .remote_result_status = .validated,
        .has_local_outcome = true,
        .sent_local_result = true,
        .remote_result_wait_frames_left = 0,
        .verified_result_drain_started = true,
        .verified_result_drain_frames_left = 2,
    }));
}

test "fresh mode is locked while result completion can still receive terminal packets" {
    try std.testing.expect(canSwitchToFreshModeFromOnline(.{}));
    try std.testing.expect(!canSwitchToFreshModeFromOnline(.{
        .completion = .{ .has_local_outcome = true },
    }));
    try std.testing.expect(!canSwitchToFreshModeFromOnline(.{
        .completion = .{ .sent_result = true },
    }));
    try std.testing.expect(!canSwitchToFreshModeFromOnline(.{
        .completion = .{ .pending_remote_result = true },
    }));
    try std.testing.expect(!canSwitchToFreshModeFromOnline(.{
        .completion = .{ .result_drain_active = true },
    }));
    try std.testing.expect(canSwitchToFreshModeFromOnline(.{
        .terminal = true,
        .completion = .{ .result_drain_active = true },
    }));
}

test "terminal packet drain policy waits before room leave" {
    try std.testing.expectEqual(TerminalDrainAction.disconnect_now, terminalDrainAction(.{}));
    try std.testing.expectEqual(TerminalDrainAction.wait, terminalDrainAction(.{
        .packet = .desync,
        .frames_left = 2,
    }));
    try std.testing.expectEqual(TerminalDrainAction.wait, terminalDrainAction(.{
        .packet = .disconnect,
        .frames_left = 1,
    }));
    try std.testing.expectEqual(TerminalDrainAction.disconnect_now, terminalDrainAction(.{
        .packet = .disconnect,
        .frames_left = 0,
    }));
    try std.testing.expectEqual(TerminalDrainAction.no_op, terminalDrainAction(.{
        .packet = .desync,
        .frames_left = 10,
        .disconnected = true,
    }));
}

test "transport health policy maps terminal receive and send failures" {
    try std.testing.expectEqual(TransportHealthAction.fail_queue_full, transportHealthAction(.{
        .status = .connected,
        .health_error = .queue_full,
    }));
    try std.testing.expectEqual(TransportHealthAction.fail_packet_too_large, transportHealthAction(.{
        .status = .connected,
        .health_error = .packet_too_large,
    }));
    try std.testing.expectEqual(TransportHealthAction.fail_send_failed, transportHealthAction(.{
        .status = .connected,
        .health_error = .send_failed,
    }));
    try std.testing.expectEqual(TransportHealthAction.none, transportHealthAction(.{
        .status = .connected,
        .health_error = .send_failed,
        .ignore_async_send_failure = true,
    }));
    try std.testing.expectEqual(TransportHealthAction.fail_packet_too_large, transportHealthAction(.{
        .status = .connected,
        .last_error = .packet_too_large,
        .health_error = .send_failed,
        .ignore_async_send_failure = true,
    }));
    try std.testing.expectEqual(TransportHealthAction.fail_queue_full, transportHealthAction(.{
        .status = .connected,
        .last_error = .queue_full,
        .health_error = .missing_js,
    }));
    try std.testing.expectEqual(TransportHealthAction.disconnected, transportHealthAction(.{
        .status = .connected,
        .last_error = .no_peer,
        .ever_had_peer = true,
    }));
    try std.testing.expectEqual(TransportHealthAction.none, transportHealthAction(.{
        .status = .disconnected,
        .ever_had_peer = true,
        .defer_peer_leave_disconnect = true,
    }));
    try std.testing.expectEqual(TransportHealthAction.none, transportHealthAction(.{
        .status = .connected,
        .peer_leave_observed = true,
        .defer_peer_leave_disconnect = true,
    }));
    try std.testing.expectEqual(TransportHealthAction.disconnected, transportHealthAction(.{
        .status = .connected,
        .peer_leave_observed = true,
    }));
    try std.testing.expectEqual(TransportHealthAction.disconnected, transportHealthAction(.{
        .status = .connecting,
        .last_error = .none,
        .peer_leave_observed = true,
    }));
    try std.testing.expectEqual(TransportHealthAction.fail_queue_full, transportHealthAction(.{
        .status = .busy,
        .health_error = .queue_full,
    }));
    try std.testing.expectEqual(TransportHealthAction.fail_extra_peer, transportHealthAction(.{
        .status = .busy,
        .last_error = .busy,
    }));
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

test "peer-leave no-peer starts late final packet grace without result state" {
    try std.testing.expectEqual(PeerLeaveDisconnectAction.disconnect_now, peerLeaveDisconnectAction(.{}));
    try std.testing.expectEqual(PeerLeaveDisconnectAction.disconnect_now, peerLeaveDisconnectAction(.{
        .late_final_packet_peer_leave_frames = 1,
        .late_final_packet_peer_leave_grace_frames = 3,
    }));
    try std.testing.expectEqual(PeerLeaveDisconnectAction.defer_disconnect, peerLeaveDisconnectAction(.{
        .allow_late_final_packet_grace = true,
        .late_final_packet_peer_leave_frames = 1,
        .late_final_packet_peer_leave_grace_frames = 3,
    }));
    try std.testing.expectEqual(TransportHealthAction.none, transportHealthAction(.{
        .status = .connected,
        .last_error = .no_peer,
        .ever_had_peer = true,
        .defer_peer_leave_disconnect = true,
    }));
}

test "late result during no-peer grace continues result validation path" {
    try std.testing.expectEqual(PeerLeaveDisconnectAction.defer_disconnect, peerLeaveDisconnectAction(.{
        .allow_late_final_packet_grace = true,
        .late_final_packet_peer_leave_frames = 2,
        .late_final_packet_peer_leave_grace_frames = 3,
    }));
    try std.testing.expectEqual(PeerLeaveDisconnectAction.defer_disconnect, peerLeaveDisconnectAction(.{
        .completion = .{ .pending_remote_result = true },
        .pending_result_peer_leave_frames = 1,
        .pending_result_peer_leave_grace_frames = 4,
        .allow_late_final_packet_grace = true,
        .late_final_packet_peer_leave_frames = 3,
        .late_final_packet_peer_leave_grace_frames = 3,
    }));
    try std.testing.expectEqual(PeerLeaveDisconnectAction.defer_disconnect, peerLeaveDisconnectAction(.{
        .completion = .{ .sent_result = true },
        .allow_late_final_packet_grace = true,
        .late_final_packet_peer_leave_frames = 3,
        .late_final_packet_peer_leave_grace_frames = 3,
    }));
}

test "late final packet grace expires before peer-leave disconnect" {
    try std.testing.expectEqual(PeerLeaveDisconnectAction.defer_disconnect, peerLeaveDisconnectAction(.{
        .allow_late_final_packet_grace = true,
        .late_final_packet_peer_leave_frames = 2,
        .late_final_packet_peer_leave_grace_frames = 3,
    }));
    try std.testing.expectEqual(PeerLeaveDisconnectAction.disconnect_now, peerLeaveDisconnectAction(.{
        .allow_late_final_packet_grace = true,
        .late_final_packet_peer_leave_frames = 3,
        .late_final_packet_peer_leave_grace_frames = 3,
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
    try joiner.markJoinerAckSent();
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

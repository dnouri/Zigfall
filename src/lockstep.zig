// SPDX-License-Identifier: GPL-3.0-or-later

//! Browser-free conservative lockstep harness for local protocol testing.
//!
//! Each peer owns a deterministic `match.Match`, a local player slot, bounded
//! per-player input buffers, and a frame cursor. `frame_cursor` means the state
//! after all frames `< frame_cursor` have been simulated. Local app tick `T`
//! samples input for frame `T + input_delay_frames`; initial delay frames are
//! deterministic neutral input so the cursor can advance up to the delay while
//! real inputs are in flight. Missing remote input stalls simulation rather than
//! predicting or rolling back.

const std = @import("std");
const controls = @import("input");
const match_mod = @import("match");
const protocol = @import("protocol");

pub const MaxBufferedFrames: usize = 256;
pub const MaxPendingStateHashFrames: usize = MaxBufferedFrames;
pub const MaxPendingStateHashes: usize = 32;
pub const MaxStateHashHistory: usize = MaxBufferedFrames;

pub const LockstepError = match_mod.InvalidGarbageSettings ||
    protocol.EncodeError ||
    protocol.DecodeError ||
    protocol.InputBatchInitError ||
    error{
        InvalidPlayerSlot,
        InputDelayTooLarge,
        InputWindowExceeded,
        StateHashWindowExceeded,
        FrameIndexOverflow,
        RestartInputUnsupported,
        ConflictingInputDuplicate,
        ConflictingStateHash,
        UnsupportedPacket,
        PeerNotOk,
        StateHashMismatch,
        StateHashTooOld,
        WrongMatchId,
        UnexpectedSenderSlot,
    };

pub const ProtocolError = enum {
    invalid_player_slot,
    input_window_exceeded,
    state_hash_window_exceeded,
    frame_index_overflow,
    restart_input_unsupported,
    conflicting_input_duplicate,
    conflicting_state_hash,
    unsupported_packet,
    malformed_packet,
    state_hash_too_old,
    wrong_match_id,
    unexpected_sender_slot,
};

pub const DesyncInfo = struct {
    frame_cursor: u64,
    local_hash: u64,
    peer_hash: u64,
};

pub const Status = union(enum) {
    ok,
    protocol_error: ProtocolError,
    desync: DesyncInfo,
};

pub const EncodedPacket = struct {
    bytes: [protocol.MaxPacketSize]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const EncodedPacket) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Peer = struct {
    match: match_mod.Match,
    match_id: u64,
    local_slot: match_mod.PlayerIndex,
    input_delay_frames: u16,
    local_app_tick: u64 = 0,
    next_frame_to_simulate: u64 = 0,
    inputs: [match_mod.PlayerCount]InputStore = .{ .{}, .{} },
    pending_state_hashes: PendingStateHashes = .{},
    state_hash_history: StateHashHistory = .{},
    status: Status = .ok,

    pub fn init(settings: match_mod.MatchSettings, local_slot: match_mod.PlayerIndex, input_delay_frames: u16, match_id: u64) LockstepError!Peer {
        if (@as(usize, input_delay_frames) >= MaxBufferedFrames) return error.InputDelayTooLarge;

        var self = Peer{
            .match = try match_mod.Match.init(settings),
            .match_id = match_id,
            .local_slot = local_slot,
            .input_delay_frames = input_delay_frames,
        };

        // Bootstrap input delay with deterministic neutral inputs. Online
        // rematch/restart should create a fresh setup/epoch instead of sending
        // restart as normal in-stream input.
        for (0..@as(usize, input_delay_frames)) |frame| {
            inline for (0..match_mod.PlayerCount) |player_index| {
                self.inputs[player_index].put(@intCast(frame), .{}, self.next_frame_to_simulate) catch unreachable;
            }
        }
        self.recordStateHash();

        return self;
    }

    pub fn frameCursor(self: *const Peer) u64 {
        return self.next_frame_to_simulate;
    }

    pub fn stateHash(self: *const Peer) u64 {
        return self.match.stateHash();
    }

    pub fn isOk(self: *const Peer) bool {
        return switch (self.status) {
            .ok => true,
            else => false,
        };
    }

    pub fn sampleLocalInput(self: *Peer, frame_input: controls.FrameInput) LockstepError!EncodedPacket {
        try self.ensureOk();
        if (hasRestartInput(frame_input)) {
            self.recordProtocolError(.restart_input_unsupported);
            return error.RestartInputUnsupported;
        }

        const target_frame = std.math.add(u64, self.local_app_tick, self.input_delay_frames) catch {
            self.recordProtocolError(.frame_index_overflow);
            return error.FrameIndexOverflow;
        };
        try self.putInput(self.local_slot.index(), target_frame, frame_input);
        self.local_app_tick += 1;

        const batch = try protocol.InputBatch.init(self.match_id, protocolSlot(self.local_slot), target_frame, &[_]controls.FrameInput{frame_input});
        return encodePacket(.{ .input_batch = batch });
    }

    pub fn makeStateHashPacket(self: *const Peer) LockstepError!EncodedPacket {
        return encodePacket(.{ .state_hash = .{
            .match_id = self.match_id,
            .sender_slot = protocolSlot(self.local_slot),
            .frame_cursor = self.next_frame_to_simulate,
            .state_hash = self.match.stateHash(),
        } });
    }

    pub fn receiveBytes(self: *Peer, bytes: []const u8) LockstepError!void {
        try self.ensureOk();
        const packet = protocol.decode(bytes) catch |err| {
            self.recordProtocolError(.malformed_packet);
            return err;
        };
        try self.receivePacket(packet);
    }

    pub fn stepAvailable(self: *Peer) LockstepError!usize {
        return self.stepAvailableMax(std.math.maxInt(usize));
    }

    pub fn stepAvailableMax(self: *Peer, max_frames: usize) LockstepError!usize {
        try self.ensureOk();

        var advanced: usize = 0;
        while (advanced < max_frames) {
            const frame_cursor = self.next_frame_to_simulate;
            const p1_input = self.inputs[0].get(frame_cursor) orelse break;
            const p2_input = self.inputs[1].get(frame_cursor) orelse break;

            const result = self.match.step(.{ .players = .{ p1_input, p2_input } });
            std.debug.assert(!result.restarted);
            self.next_frame_to_simulate = std.math.add(u64, self.next_frame_to_simulate, 1) catch {
                self.recordProtocolError(.frame_index_overflow);
                return error.FrameIndexOverflow;
            };
            std.debug.assert(self.match.input_frame_count == self.next_frame_to_simulate);
            self.recordStateHash();
            advanced += 1;

            try self.checkPendingStateHash();
        }
        return advanced;
    }

    fn receivePacket(self: *Peer, packet: protocol.Packet) LockstepError!void {
        if (protocol.packetMatchId(packet) != self.match_id) {
            self.recordProtocolError(.wrong_match_id);
            return error.WrongMatchId;
        }

        switch (packet) {
            .input_batch => |batch| try self.receiveInputBatch(batch),
            .state_hash => |state_hash| try self.receiveStateHash(state_hash),
            .desync => |desync| {
                try self.expectRemoteProtocolSlot(desync.sender_slot);
                self.status = .{ .desync = .{
                    .frame_cursor = desync.frame_cursor,
                    .local_hash = desync.peer_hash,
                    .peer_hash = desync.local_hash,
                } };
                return error.StateHashMismatch;
            },
            else => {
                self.recordProtocolError(.unsupported_packet);
                return error.UnsupportedPacket;
            },
        }
    }

    fn receiveInputBatch(self: *Peer, batch: protocol.InputBatch) LockstepError!void {
        try self.expectRemoteProtocolSlot(batch.player_slot);

        for (batch.inputSlice()) |frame_input| {
            if (hasRestartInput(frame_input)) {
                self.recordProtocolError(.restart_input_unsupported);
                return error.RestartInputUnsupported;
            }
        }

        for (batch.inputSlice(), 0..) |frame_input, offset| {
            const frame = std.math.add(u64, batch.first_frame, @as(u64, @intCast(offset))) catch {
                self.recordProtocolError(.frame_index_overflow);
                return error.FrameIndexOverflow;
            };
            try self.putInput(batch.player_slot, frame, frame_input);
        }
    }

    fn receiveStateHash(self: *Peer, state_hash: protocol.StateHash) LockstepError!void {
        try self.expectRemoteProtocolSlot(state_hash.sender_slot);

        if (state_hash.frame_cursor < self.next_frame_to_simulate) {
            const local_hash = self.state_hash_history.get(state_hash.frame_cursor) catch |err| {
                self.recordProtocolError(.state_hash_too_old);
                return err;
            };
            try self.compareStateHashValue(state_hash.frame_cursor, local_hash, state_hash.state_hash);
            return;
        }
        if (state_hash.frame_cursor == self.next_frame_to_simulate) {
            try self.compareStateHash(state_hash.frame_cursor, state_hash.state_hash);
            return;
        }

        self.pending_state_hashes.put(state_hash.frame_cursor, state_hash.state_hash, self.next_frame_to_simulate) catch |err| {
            switch (err) {
                error.StateHashWindowExceeded => {
                    self.recordProtocolError(.state_hash_window_exceeded);
                    return error.StateHashWindowExceeded;
                },
                error.ConflictingStateHash => {
                    self.recordProtocolError(.conflicting_state_hash);
                    return error.ConflictingStateHash;
                },
            }
        };
    }

    fn checkPendingStateHash(self: *Peer) LockstepError!void {
        if (self.pending_state_hashes.take(self.next_frame_to_simulate)) |peer_hash| {
            try self.compareStateHash(self.next_frame_to_simulate, peer_hash);
        }
    }

    fn compareStateHash(self: *Peer, frame_cursor: u64, peer_hash: u64) LockstepError!void {
        try self.compareStateHashValue(frame_cursor, self.match.stateHash(), peer_hash);
    }

    fn compareStateHashValue(self: *Peer, frame_cursor: u64, local_hash: u64, peer_hash: u64) LockstepError!void {
        if (local_hash != peer_hash) {
            self.status = .{ .desync = .{
                .frame_cursor = frame_cursor,
                .local_hash = local_hash,
                .peer_hash = peer_hash,
            } };
            return error.StateHashMismatch;
        }
    }

    fn putInput(self: *Peer, player_index: usize, frame: u64, frame_input: controls.FrameInput) LockstepError!void {
        self.inputs[player_index].put(frame, frame_input, self.next_frame_to_simulate) catch |err| {
            switch (err) {
                error.InputWindowExceeded => {
                    self.recordProtocolError(.input_window_exceeded);
                    return error.InputWindowExceeded;
                },
                error.ConflictingInputDuplicate => {
                    self.recordProtocolError(.conflicting_input_duplicate);
                    return error.ConflictingInputDuplicate;
                },
            }
        };
    }

    fn ensureOk(self: *const Peer) LockstepError!void {
        if (!self.isOk()) return error.PeerNotOk;
    }

    fn recordStateHash(self: *Peer) void {
        self.state_hash_history.put(self.next_frame_to_simulate, self.match.stateHash());
    }

    fn expectRemoteProtocolSlot(self: *Peer, slot: u8) LockstepError!void {
        if (!validProtocolSlot(slot)) {
            self.recordProtocolError(.invalid_player_slot);
            return error.InvalidPlayerSlot;
        }
        if (slot != protocolSlot(self.local_slot.opponent())) {
            self.recordProtocolError(.unexpected_sender_slot);
            return error.UnexpectedSenderSlot;
        }
    }

    fn recordProtocolError(self: *Peer, reason: ProtocolError) void {
        if (self.isOk()) {
            self.status = .{ .protocol_error = reason };
        }
    }
};

const InputStoreError = error{
    InputWindowExceeded,
    ConflictingInputDuplicate,
};

const InputSlot = struct {
    present: bool = false,
    frame: u64 = 0,
    frame_input: controls.FrameInput = .{},
};

const InputStore = struct {
    slots: [MaxBufferedFrames]InputSlot = [_]InputSlot{.{}} ** MaxBufferedFrames,

    fn put(self: *InputStore, frame: u64, frame_input: controls.FrameInput, min_frame: u64) InputStoreError!void {
        if (frame >= min_frame and frame - min_frame >= @as(u64, @intCast(MaxBufferedFrames))) return error.InputWindowExceeded;

        const slot = &self.slots[ringIndex(frame)];
        if (slot.present and slot.frame == frame) {
            if (!std.meta.eql(slot.frame_input, frame_input)) return error.ConflictingInputDuplicate;
            return;
        }

        // The exact old frame has already been evicted from this ring slot.
        // Late retained duplicates are checked above; truly too-old evicted
        // input is deliberately ignored because it can no longer affect the
        // deterministic simulation.
        if (frame < min_frame) return;
        if (slot.present and slot.frame >= min_frame) return error.InputWindowExceeded;

        slot.* = .{
            .present = true,
            .frame = frame,
            .frame_input = frame_input,
        };
    }

    fn get(self: *const InputStore, frame: u64) ?controls.FrameInput {
        const slot = self.slots[ringIndex(frame)];
        if (!slot.present or slot.frame != frame) return null;
        return slot.frame_input;
    }
};

const PendingStateHashError = error{
    StateHashWindowExceeded,
    ConflictingStateHash,
};

const PendingStateHash = struct {
    present: bool = false,
    frame_cursor: u64 = 0,
    state_hash: u64 = 0,
};

const PendingStateHashes = struct {
    entries: [MaxPendingStateHashes]PendingStateHash = [_]PendingStateHash{.{}} ** MaxPendingStateHashes,

    fn put(self: *PendingStateHashes, frame_cursor: u64, state_hash: u64, current_frame_cursor: u64) PendingStateHashError!void {
        if (frame_cursor < current_frame_cursor) return error.StateHashWindowExceeded;
        if (frame_cursor - current_frame_cursor >= @as(u64, @intCast(MaxPendingStateHashFrames))) return error.StateHashWindowExceeded;

        for (&self.entries) |*entry| {
            if (entry.present and entry.frame_cursor == frame_cursor) {
                if (entry.state_hash != state_hash) return error.ConflictingStateHash;
                return;
            }
        }

        for (&self.entries) |*entry| {
            if (!entry.present) {
                entry.* = .{
                    .present = true,
                    .frame_cursor = frame_cursor,
                    .state_hash = state_hash,
                };
                return;
            }
        }

        return error.StateHashWindowExceeded;
    }

    fn take(self: *PendingStateHashes, frame_cursor: u64) ?u64 {
        for (&self.entries) |*entry| {
            if (entry.present and entry.frame_cursor == frame_cursor) {
                const state_hash = entry.state_hash;
                entry.* = .{};
                return state_hash;
            }
        }
        return null;
    }
};

const StateHashHistory = struct {
    entries: [MaxStateHashHistory]StateHashHistoryEntry = [_]StateHashHistoryEntry{.{}} ** MaxStateHashHistory,

    fn put(self: *StateHashHistory, frame_cursor: u64, state_hash: u64) void {
        self.entries[stateHashHistoryIndex(frame_cursor)] = .{
            .present = true,
            .frame_cursor = frame_cursor,
            .state_hash = state_hash,
        };
    }

    fn get(self: *const StateHashHistory, frame_cursor: u64) error{StateHashTooOld}!u64 {
        const entry = self.entries[stateHashHistoryIndex(frame_cursor)];
        if (!entry.present or entry.frame_cursor != frame_cursor) return error.StateHashTooOld;
        return entry.state_hash;
    }
};

const StateHashHistoryEntry = struct {
    present: bool = false,
    frame_cursor: u64 = 0,
    state_hash: u64 = 0,
};

fn encodePacket(packet: protocol.Packet) LockstepError!EncodedPacket {
    var encoded = EncodedPacket{};
    encoded.len = try protocol.encode(packet, encoded.bytes[0..]);
    return encoded;
}

fn protocolSlot(player_index: match_mod.PlayerIndex) u8 {
    return @intCast(player_index.index());
}

fn validProtocolSlot(slot: u8) bool {
    return slot < match_mod.PlayerCount;
}

fn ringIndex(frame: u64) usize {
    return @intCast(frame % @as(u64, @intCast(MaxBufferedFrames)));
}

fn stateHashHistoryIndex(frame_cursor: u64) usize {
    return @intCast(frame_cursor % @as(u64, @intCast(MaxStateHashHistory)));
}

fn hasRestartInput(frame_input: controls.FrameInput) bool {
    return frame_input.restart_pressed;
}

fn testSettings() match_mod.MatchSettings {
    return .{ .player_seeds = .{ 0x1111_2222_3333_4444, 0x5555_6666_7777_8888 } };
}

const TestMatchId: u64 = 0x0bad_f00d_cafe_babe;
const OtherMatchId: u64 = 0xfeed_face_1234_5678;

fn inputBatchPacket(player_slot: u8, first_frame: u64, frames: []const controls.FrameInput) !EncodedPacket {
    return inputBatchPacketForMatch(TestMatchId, player_slot, first_frame, frames);
}

fn inputBatchPacketForMatch(match_id: u64, player_slot: u8, first_frame: u64, frames: []const controls.FrameInput) !EncodedPacket {
    const batch = try protocol.InputBatch.init(match_id, player_slot, first_frame, frames);
    return encodePacket(.{ .input_batch = batch });
}

fn stateHashPacket(sender_slot: u8, frame_cursor: u64, state_hash: u64) !EncodedPacket {
    return stateHashPacketForMatch(TestMatchId, sender_slot, frame_cursor, state_hash);
}

fn stateHashPacketForMatch(match_id: u64, sender_slot: u8, frame_cursor: u64, state_hash: u64) !EncodedPacket {
    return encodePacket(.{ .state_hash = .{
        .match_id = match_id,
        .sender_slot = sender_slot,
        .frame_cursor = frame_cursor,
        .state_hash = state_hash,
    } });
}

fn desyncPacketForMatch(match_id: u64, sender_slot: u8) !EncodedPacket {
    return encodePacket(.{ .desync = .{
        .match_id = match_id,
        .sender_slot = sender_slot,
        .reason = 1,
        .frame_cursor = 0,
        .local_hash = 0xaa,
        .peer_hash = 0xbb,
    } });
}

fn expectProtocolError(status: Status, reason: ProtocolError) !void {
    switch (status) {
        .protocol_error => |actual| try std.testing.expectEqual(reason, actual),
        else => try std.testing.expect(false),
    }
}

fn expectDesync(status: Status, frame_cursor: u64, peer_hash: u64) !void {
    switch (status) {
        .desync => |actual| {
            try std.testing.expectEqual(frame_cursor, actual.frame_cursor);
            try std.testing.expectEqual(peer_hash, actual.peer_hash);
        },
        else => try std.testing.expect(false),
    }
}

fn stepNeutralFrames(peer: *Peer, frame_count: usize) !void {
    for (0..frame_count) |_| {
        const frame = peer.frameCursor();
        try peer.putInput(0, frame, .{});
        try peer.putInput(1, frame, .{});
        try std.testing.expectEqual(@as(usize, 1), try peer.stepAvailableMax(1));
    }
}

const FakeTransport = struct {
    const MaxQueuedPackets: usize = 64;

    const QueuedPacket = struct {
        recipient: *Peer,
        deliver_at: u64,
        packet: EncodedPacket,
    };

    now: u64 = 0,
    queued: [MaxQueuedPackets]QueuedPacket = undefined,
    count: usize = 0,

    fn send(self: *FakeTransport, recipient: *Peer, packet: EncodedPacket, delay_ticks: u64) !void {
        if (self.count >= MaxQueuedPackets) return error.TransportQueueFull;
        self.queued[self.count] = .{
            .recipient = recipient,
            .deliver_at = self.now + delay_ticks,
            .packet = packet,
        };
        self.count += 1;
    }

    fn deliverDue(self: *FakeTransport) !usize {
        var delivered: usize = 0;
        var index: usize = 0;
        while (index < self.count) {
            if (self.queued[index].deliver_at <= self.now) {
                const queued = self.queued[index];
                self.count -= 1;
                self.queued[index] = self.queued[self.count];
                try queued.recipient.receiveBytes(queued.packet.slice());
                delivered += 1;
            } else {
                index += 1;
            }
        }
        return delivered;
    }

    fn advance(self: *FakeTransport) !usize {
        self.now += 1;
        return self.deliverDue();
    }

    fn drain(self: *FakeTransport) !usize {
        var delivered: usize = 0;
        while (self.count > 0) {
            var next_due = self.queued[0].deliver_at;
            for (self.queued[1..self.count]) |queued| {
                next_due = @min(next_due, queued.deliver_at);
            }
            self.now = @max(self.now, next_due);
            delivered += try self.deliverDue();
        }
        return delivered;
    }
};

test "conservative lockstep waits for missing remote input" {
    var peer = try Peer.init(testSettings(), .p1, 0, TestMatchId);
    _ = try peer.sampleLocalInput(.{ .left_down = true, .left_pressed = true });

    try std.testing.expectEqual(@as(usize, 0), try peer.stepAvailable());
    try std.testing.expectEqual(@as(u64, 0), peer.frameCursor());
    try std.testing.expect(peer.isOk());
}

test "delayed and out-of-order packets eventually converge peers" {
    var p1 = try Peer.init(testSettings(), .p1, 2, TestMatchId);
    var p2 = try Peer.init(testSettings(), .p2, 2, TestMatchId);
    var transport = FakeTransport{};

    try std.testing.expectEqual(@as(usize, 2), try p1.stepAvailable());
    try std.testing.expectEqual(@as(usize, 2), try p2.stepAvailable());

    const p1_inputs = [_]controls.FrameInput{
        .{ .left_down = true, .left_pressed = true },
        .{ .left_down = true },
        .{ .rotate_cw_pressed = true },
        .{ .hard_drop_pressed = true },
        .{},
        .{ .down_down = true },
    };
    const p2_inputs = [_]controls.FrameInput{
        .{},
        .{ .right_down = true, .right_pressed = true },
        .{ .right_down = true },
        .{ .hold_pressed = true },
        .{ .hard_drop_pressed = true },
        .{},
    };

    for (p1_inputs, p2_inputs, 0..) |p1_input, p2_input, tick| {
        const p1_packet = try p1.sampleLocalInput(p1_input);
        const p2_packet = try p2.sampleLocalInput(p2_input);
        try transport.send(&p2, p1_packet, if (tick % 2 == 0) 3 else 1);
        try transport.send(&p1, p2_packet, if (tick % 2 == 0) 1 else 3);
        _ = try transport.deliverDue();
        _ = try p1.stepAvailable();
        _ = try p2.stepAvailable();
        _ = try transport.advance();
    }

    _ = try transport.drain();
    _ = try p1.stepAvailable();
    _ = try p2.stepAvailable();

    try std.testing.expectEqual(@as(u64, 2 + p1_inputs.len), p1.frameCursor());
    try std.testing.expectEqual(p1.frameCursor(), p2.frameCursor());
    try std.testing.expectEqual(p1.stateHash(), p2.stateHash());
}

test "future packet waits behind earlier frame gap" {
    var peer = try Peer.init(testSettings(), .p1, 0, TestMatchId);
    _ = try peer.sampleLocalInput(.{});
    _ = try peer.sampleLocalInput(.{ .left_down = true, .left_pressed = true });

    const future = try inputBatchPacket(1, 1, &[_]controls.FrameInput{.{ .right_down = true, .right_pressed = true }});
    try peer.receiveBytes(future.slice());
    try std.testing.expectEqual(@as(usize, 0), try peer.stepAvailable());
    try std.testing.expectEqual(@as(u64, 0), peer.frameCursor());

    const gap = try inputBatchPacket(1, 0, &[_]controls.FrameInput{.{}});
    try peer.receiveBytes(gap.slice());
    try std.testing.expectEqual(@as(usize, 2), try peer.stepAvailable());
    try std.testing.expectEqual(@as(u64, 2), peer.frameCursor());
}

test "input store rejects future overflow without poisoning current slot" {
    var store = InputStore{};
    const cursor: u64 = 10;
    const window: u64 = @intCast(MaxBufferedFrames);
    const last_frame = cursor + window - 1;
    const overflow_frame = cursor + window;

    try store.put(last_frame, .{ .left_down = true }, cursor);
    try std.testing.expect(store.get(last_frame) != null);

    try std.testing.expectError(error.InputWindowExceeded, store.put(overflow_frame, .{ .right_down = true }, cursor));
    try std.testing.expect(store.get(cursor) == null);
    try std.testing.expect(store.get(overflow_frame) == null);
}

test "local packets carry local slot and match id" {
    var peer = try Peer.init(testSettings(), .p1, 0, TestMatchId);
    const input_packet = try peer.sampleLocalInput(.{});
    switch (try protocol.decode(input_packet.slice())) {
        .input_batch => |batch| {
            try std.testing.expectEqual(TestMatchId, batch.match_id);
            try std.testing.expectEqual(@as(u8, 0), batch.player_slot);
        },
        else => try std.testing.expect(false),
    }

    const hash_packet = try peer.makeStateHashPacket();
    switch (try protocol.decode(hash_packet.slice())) {
        .state_hash => |state_hash| {
            try std.testing.expectEqual(TestMatchId, state_hash.match_id);
            try std.testing.expectEqual(@as(u8, 0), state_hash.sender_slot);
        },
        else => try std.testing.expect(false),
    }
}

test "inbound packets with wrong match id are rejected" {
    var input_peer = try Peer.init(testSettings(), .p1, 0, TestMatchId);
    const wrong_input = try inputBatchPacketForMatch(OtherMatchId, 1, 0, &[_]controls.FrameInput{.{}});
    try std.testing.expectError(error.WrongMatchId, input_peer.receiveBytes(wrong_input.slice()));
    try expectProtocolError(input_peer.status, .wrong_match_id);

    var hash_peer = try Peer.init(testSettings(), .p1, 0, TestMatchId);
    const wrong_hash = try stateHashPacketForMatch(OtherMatchId, 1, 0, hash_peer.stateHash());
    try std.testing.expectError(error.WrongMatchId, hash_peer.receiveBytes(wrong_hash.slice()));
    try expectProtocolError(hash_peer.status, .wrong_match_id);

    var desync_peer = try Peer.init(testSettings(), .p1, 0, TestMatchId);
    const wrong_desync = try desyncPacketForMatch(OtherMatchId, 1);
    try std.testing.expectError(error.WrongMatchId, desync_peer.receiveBytes(wrong_desync.slice()));
    try expectProtocolError(desync_peer.status, .wrong_match_id);
}

test "inbound packets from non-remote slot are rejected" {
    var input_peer = try Peer.init(testSettings(), .p1, 0, TestMatchId);
    const spoofed_input = try inputBatchPacket(0, 0, &[_]controls.FrameInput{.{}});
    try std.testing.expectError(error.UnexpectedSenderSlot, input_peer.receiveBytes(spoofed_input.slice()));
    try expectProtocolError(input_peer.status, .unexpected_sender_slot);

    var hash_peer = try Peer.init(testSettings(), .p1, 0, TestMatchId);
    const spoofed_hash = try stateHashPacket(0, 0, hash_peer.stateHash());
    try std.testing.expectError(error.UnexpectedSenderSlot, hash_peer.receiveBytes(spoofed_hash.slice()));
    try expectProtocolError(hash_peer.status, .unexpected_sender_slot);

    var desync_peer = try Peer.init(testSettings(), .p1, 0, TestMatchId);
    const spoofed_desync = try desyncPacketForMatch(TestMatchId, 0);
    try std.testing.expectError(error.UnexpectedSenderSlot, desync_peer.receiveBytes(spoofed_desync.slice()));
    try expectProtocolError(desync_peer.status, .unexpected_sender_slot);
}

test "inbound invalid player slot is rejected" {
    var peer = try Peer.init(testSettings(), .p1, 0, TestMatchId);
    const packet = try inputBatchPacket(2, 0, &[_]controls.FrameInput{.{}});
    try std.testing.expectError(error.InvalidPlayerSlot, peer.receiveBytes(packet.slice()));
    try expectProtocolError(peer.status, .invalid_player_slot);
}

test "duplicate same input is ignored" {
    var peer = try Peer.init(testSettings(), .p1, 0, TestMatchId);
    _ = try peer.sampleLocalInput(.{});
    const remote = try inputBatchPacket(1, 0, &[_]controls.FrameInput{.{ .hard_drop_pressed = true }});

    try peer.receiveBytes(remote.slice());
    try peer.receiveBytes(remote.slice());
    try std.testing.expect(peer.isOk());
    try std.testing.expectEqual(@as(usize, 1), try peer.stepAvailable());
}

test "conflicting duplicate input marks protocol error" {
    var peer = try Peer.init(testSettings(), .p1, 0, TestMatchId);
    const first = try inputBatchPacket(1, 0, &[_]controls.FrameInput{.{ .left_down = true }});
    const conflict = try inputBatchPacket(1, 0, &[_]controls.FrameInput{.{ .right_down = true }});

    try peer.receiveBytes(first.slice());
    try std.testing.expectError(error.ConflictingInputDuplicate, peer.receiveBytes(conflict.slice()));
    try expectProtocolError(peer.status, .conflicting_input_duplicate);
}

test "identical late duplicate input still retained is ignored" {
    var peer = try Peer.init(testSettings(), .p1, 0, TestMatchId);
    _ = try peer.sampleLocalInput(.{});
    const remote = try inputBatchPacket(1, 0, &[_]controls.FrameInput{.{ .left_down = true }});

    try peer.receiveBytes(remote.slice());
    try std.testing.expectEqual(@as(usize, 1), try peer.stepAvailable());
    try peer.receiveBytes(remote.slice());
    try std.testing.expect(peer.isOk());
}

test "conflicting late duplicate input still retained marks protocol error" {
    var peer = try Peer.init(testSettings(), .p1, 0, TestMatchId);
    _ = try peer.sampleLocalInput(.{});
    const first = try inputBatchPacket(1, 0, &[_]controls.FrameInput{.{ .left_down = true }});
    const conflict = try inputBatchPacket(1, 0, &[_]controls.FrameInput{.{ .right_down = true }});

    try peer.receiveBytes(first.slice());
    try std.testing.expectEqual(@as(usize, 1), try peer.stepAvailable());
    try std.testing.expectError(error.ConflictingInputDuplicate, peer.receiveBytes(conflict.slice()));
    try expectProtocolError(peer.status, .conflicting_input_duplicate);
}

test "too-old evicted input is ignored without overwriting retained slot" {
    var store = InputStore{};
    const replacement_frame: u64 = @intCast(MaxBufferedFrames);
    const retained = controls.FrameInput{ .right_down = true };

    try store.put(0, .{ .left_down = true }, 0);
    try store.put(replacement_frame, retained, replacement_frame);
    try store.put(0, .{ .down_down = true }, replacement_frame + 1);

    try std.testing.expect(store.get(0) == null);
    try std.testing.expectEqualDeep(retained, store.get(replacement_frame).?);
}

test "state hash mismatch packet marks desync" {
    var peer = try Peer.init(testSettings(), .p1, 0, TestMatchId);
    const bad_hash = peer.stateHash() ^ 1;
    const packet = try stateHashPacket(1, peer.frameCursor(), bad_hash);

    try std.testing.expectError(error.StateHashMismatch, peer.receiveBytes(packet.slice()));
    try expectDesync(peer.status, 0, bad_hash);
}

test "state hash match packet is accepted" {
    var peer = try Peer.init(testSettings(), .p1, 0, TestMatchId);
    const packet = try stateHashPacket(1, peer.frameCursor(), peer.stateHash());

    try peer.receiveBytes(packet.slice());
    try std.testing.expect(peer.isOk());
}

test "future state hash is checked when frame cursor catches up" {
    var peer = try Peer.init(testSettings(), .p1, 0, TestMatchId);
    var reference = try Peer.init(testSettings(), .p2, 0, TestMatchId);

    _ = try peer.sampleLocalInput(.{});
    const remote_input = try inputBatchPacket(1, 0, &[_]controls.FrameInput{.{}});
    try reference.receiveBytes((try inputBatchPacket(0, 0, &[_]controls.FrameInput{.{}})).slice());
    _ = try reference.sampleLocalInput(.{});
    _ = try reference.stepAvailable();

    const hash = try stateHashPacket(1, 1, reference.stateHash());
    try peer.receiveBytes(hash.slice());
    try peer.receiveBytes(remote_input.slice());
    try std.testing.expectEqual(@as(usize, 1), try peer.stepAvailable());
    try std.testing.expect(peer.isOk());
}

test "future state hash at window edge is accepted and stored" {
    var peer = try Peer.init(testSettings(), .p1, 0, TestMatchId);
    const window: u64 = @intCast(MaxPendingStateHashFrames);
    const frame_cursor = peer.frameCursor() + window - 1;
    const hash: u64 = 0x1234_5678_9abc_def0;
    const packet = try stateHashPacket(1, frame_cursor, hash);

    try peer.receiveBytes(packet.slice());
    try std.testing.expect(peer.isOk());
    try std.testing.expectEqual(hash, peer.pending_state_hashes.take(frame_cursor).?);
}

test "future state hash at window limit is rejected" {
    var peer = try Peer.init(testSettings(), .p1, 0, TestMatchId);
    const window: u64 = @intCast(MaxPendingStateHashFrames);
    const frame_cursor = peer.frameCursor() + window;
    const packet = try stateHashPacket(1, frame_cursor, 0xaaaa_bbbb_cccc_dddd);

    try std.testing.expectError(error.StateHashWindowExceeded, peer.receiveBytes(packet.slice()));
    try expectProtocolError(peer.status, .state_hash_window_exceeded);
    try std.testing.expect(peer.pending_state_hashes.take(frame_cursor) == null);
}

test "huge future state hash is rejected without poisoning pending storage" {
    var pending = PendingStateHashes{};
    const current_frame_cursor: u64 = 7;
    const window: u64 = @intCast(MaxPendingStateHashFrames);
    const legitimate_frame_cursor = current_frame_cursor + window - 1;

    try std.testing.expectError(
        error.StateHashWindowExceeded,
        pending.put(std.math.maxInt(u64), 0xaaaa_bbbb_cccc_dddd, current_frame_cursor),
    );
    try pending.put(legitimate_frame_cursor, 0x1111_2222_3333_4444, current_frame_cursor);
    try std.testing.expectEqual(@as(u64, 0x1111_2222_3333_4444), pending.take(legitimate_frame_cursor).?);
}

test "late retained state hash match is checked and accepted" {
    var peer = try Peer.init(testSettings(), .p1, 0, TestMatchId);
    const initial_hash = peer.stateHash();
    try stepNeutralFrames(&peer, 1);

    const packet = try stateHashPacket(1, 0, initial_hash);
    try peer.receiveBytes(packet.slice());
    try std.testing.expect(peer.isOk());
}

test "late retained state hash mismatch marks desync" {
    var peer = try Peer.init(testSettings(), .p1, 0, TestMatchId);
    const bad_hash = peer.stateHash() ^ 1;
    try stepNeutralFrames(&peer, 1);

    const packet = try stateHashPacket(1, 0, bad_hash);
    try std.testing.expectError(error.StateHashMismatch, peer.receiveBytes(packet.slice()));
    try expectDesync(peer.status, 0, bad_hash);
}

test "too old state hash is an explicit protocol error" {
    var peer = try Peer.init(testSettings(), .p1, 0, TestMatchId);
    const initial_hash = peer.stateHash();
    try stepNeutralFrames(&peer, MaxStateHashHistory);

    const packet = try stateHashPacket(1, 0, initial_hash);
    try std.testing.expectError(error.StateHashTooOld, peer.receiveBytes(packet.slice()));
    try expectProtocolError(peer.status, .state_hash_too_old);
}

test "restart input is rejected for online lockstep stream" {
    var local = try Peer.init(testSettings(), .p1, 0, TestMatchId);
    try std.testing.expectError(error.RestartInputUnsupported, local.sampleLocalInput(.{ .restart_pressed = true }));
    try expectProtocolError(local.status, .restart_input_unsupported);

    var remote = try Peer.init(testSettings(), .p1, 0, TestMatchId);
    const packet = try inputBatchPacket(1, 0, &[_]controls.FrameInput{.{ .restart_pressed = true }});
    try std.testing.expectError(error.RestartInputUnsupported, remote.receiveBytes(packet.slice()));
    try expectProtocolError(remote.status, .restart_input_unsupported);
}

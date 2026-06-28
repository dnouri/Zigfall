// SPDX-License-Identifier: GPL-3.0-or-later

//! Binary protocol foundation for deterministic two-player lockstep.
//!
//! Wire packets are opaque byte slices with a fixed ten-byte envelope: byte 0
//! must equal `ProtocolVersion`, byte 1 is a `PacketType` tag, and bytes 2..9
//! are the little-endian `match_id`. Decoders reject unknown versions and packet
//! types. All integer fields are fixed-width and little-endian. A packet is
//! capped at `MaxPacketSize` bytes, and one `InputBatch` may contain at most
//! `MaxInputBatchCount` contiguous frames from `first_frame`.
//!
//! `match_id` scopes every packet to one setup epoch. Restart/rematch is a new
//! setup handshake with a fresh match id; do not reuse an old id for a new
//! simulation. `frame_cursor` means the state after all frames `< frame_cursor`
//! have been simulated. Never serialize raw Zig structs or rely on native memory
//! layout. Phase 5 JS/Trystero code should move these packets as opaque bytes
//! and queue asynchronous callbacks for Zig to poll; transport code must not
//! inspect or reinterpret packet contents.

const std = @import("std");
const input = @import("input");

pub const ProtocolVersion: u8 = 1;
pub const MatchIdSize: usize = 8;
pub const HeaderSize: usize = 2 + MatchIdSize;
pub const MaxPacketSize: usize = 512;
pub const MaxInputBatchCount: usize = 32;

pub const InputMaskBits = struct {
    pub const left_down: u16 = 1 << 0;
    pub const right_down: u16 = 1 << 1;
    pub const down_down: u16 = 1 << 2;
    pub const left_pressed: u16 = 1 << 3;
    pub const right_pressed: u16 = 1 << 4;
    pub const rotate_cw_pressed: u16 = 1 << 5;
    pub const rotate_ccw_pressed: u16 = 1 << 6;
    pub const rotate_180_pressed: u16 = 1 << 7;
    pub const hold_pressed: u16 = 1 << 8;
    pub const hard_drop_pressed: u16 = 1 << 9;
    pub const pause_pressed: u16 = 1 << 10;
    pub const restart_pressed: u16 = 1 << 11;
};

/// Version 1 reserves bits 12..15; decoders reject them instead of ignoring
/// unknown future inputs.
pub const KnownInputMask: u16 = 0x0fff;
pub const NullInitialHole: u8 = 255;
pub const MaxInitialHoleIndex: u8 = 9;

pub const SetupPacketSize: usize = HeaderSize + 1 + 1 + 2 + 8 + 8 + 8 + 1 + 1 + 1 + 1;
pub const InputBatchPrefixSize: usize = HeaderSize + 1 + 8 + 1;
pub const AckPacketSize: usize = HeaderSize + 1 + 1 + 8;
pub const StateHashPacketSize: usize = HeaderSize + 1 + 8 + 8;
pub const DesyncPacketSize: usize = HeaderSize + 1 + 1 + 8 + 8 + 8;
pub const DisconnectPacketSize: usize = HeaderSize + 1 + 1 + 8;
pub const ResultPacketSize: usize = HeaderSize + 1 + 1 + 8 + 8;

pub const InputMaskError = error{
    InvalidInputMask,
};

pub const InputBatchInitError = error{
    TooManyInputs,
};

pub const EncodeError = error{
    BufferTooSmall,
    PacketTooLarge,
    TooManyInputs,
    InvalidHoleChangeChance,
    InvalidInitialHole,
};

pub const DecodeError = error{
    PacketTooLarge,
    TruncatedPacket,
    InvalidVersion,
    UnknownPacketType,
    UnknownRuleset,
    UnknownResultOutcome,
    TrailingBytes,
    TooManyInputs,
    InvalidInputMask,
    InvalidHoleChangeChance,
    InvalidInitialHole,
};

pub const PacketType = enum(u8) {
    setup = 1,
    input_batch = 2,
    ack = 3,
    state_hash = 4,
    desync = 5,
    disconnect = 6,
    result = 7,
};

pub const Ruleset = enum(u8) {
    modern = 1,
};

pub const ResultOutcome = enum(u8) {
    p1_win = 1,
    p2_win = 2,
    draw = 3,
};

pub const Setup = struct {
    match_id: u64,
    sender_slot: u8,
    ruleset: Ruleset = .modern,
    input_delay_frames: u16,
    p1_seed: u64,
    p2_seed: u64,
    garbage_seed: u64,
    hole_num: u8,
    hole_den: u8,
    initial_hole_p1: ?u8 = null,
    initial_hole_p2: ?u8 = null,
};

pub const InputBatch = struct {
    match_id: u64,
    player_slot: u8,
    first_frame: u64,
    count: u8 = 0,
    inputs: [MaxInputBatchCount]input.FrameInput = [_]input.FrameInput{.{}} ** MaxInputBatchCount,

    pub fn init(match_id: u64, player_slot: u8, first_frame: u64, frames: []const input.FrameInput) InputBatchInitError!InputBatch {
        if (frames.len > MaxInputBatchCount) return error.TooManyInputs;

        var batch = InputBatch{
            .match_id = match_id,
            .player_slot = player_slot,
            .first_frame = first_frame,
            .count = @intCast(frames.len),
        };
        for (frames, 0..) |frame, index| {
            batch.inputs[index] = frame;
        }
        return batch;
    }

    pub fn inputSlice(self: *const InputBatch) []const input.FrameInput {
        return self.inputs[0..self.countUsize()];
    }

    fn countUsize(self: *const InputBatch) usize {
        return @intCast(self.count);
    }
};

pub const Ack = struct {
    match_id: u64,
    sender_slot: u8,
    acked_slot: u8,
    next_needed_frame: u64,
};

pub const StateHash = struct {
    match_id: u64,
    sender_slot: u8,
    frame_cursor: u64,
    state_hash: u64,
};

pub const Desync = struct {
    match_id: u64,
    sender_slot: u8,
    reason: u8,
    frame_cursor: u64,
    local_hash: u64,
    peer_hash: u64,
};

pub const Disconnect = struct {
    match_id: u64,
    sender_slot: u8,
    reason: u8,
    last_frame_cursor: u64,
};

pub const Result = struct {
    match_id: u64,
    sender_slot: u8,
    outcome: ResultOutcome,
    frame_cursor: u64,
    state_hash: u64,
};

pub const Packet = union(PacketType) {
    setup: Setup,
    input_batch: InputBatch,
    ack: Ack,
    state_hash: StateHash,
    desync: Desync,
    disconnect: Disconnect,
    result: Result,
};

pub fn packetMatchId(packet: Packet) u64 {
    return switch (packet) {
        .setup => |setup| setup.match_id,
        .input_batch => |batch| batch.match_id,
        .ack => |ack| ack.match_id,
        .state_hash => |state_hash| state_hash.match_id,
        .desync => |desync| desync.match_id,
        .disconnect => |disconnect| disconnect.match_id,
        .result => |result| result.match_id,
    };
}

pub fn frameInputToMask(frame: input.FrameInput) u16 {
    var mask: u16 = 0;
    if (frame.left_down) mask |= InputMaskBits.left_down;
    if (frame.right_down) mask |= InputMaskBits.right_down;
    if (frame.down_down) mask |= InputMaskBits.down_down;
    if (frame.left_pressed) mask |= InputMaskBits.left_pressed;
    if (frame.right_pressed) mask |= InputMaskBits.right_pressed;
    if (frame.rotate_cw_pressed) mask |= InputMaskBits.rotate_cw_pressed;
    if (frame.rotate_ccw_pressed) mask |= InputMaskBits.rotate_ccw_pressed;
    if (frame.rotate_180_pressed) mask |= InputMaskBits.rotate_180_pressed;
    if (frame.hold_pressed) mask |= InputMaskBits.hold_pressed;
    if (frame.hard_drop_pressed) mask |= InputMaskBits.hard_drop_pressed;
    if (frame.pause_pressed) mask |= InputMaskBits.pause_pressed;
    if (frame.restart_pressed) mask |= InputMaskBits.restart_pressed;
    return mask;
}

pub fn frameInputFromMask(mask: u16) InputMaskError!input.FrameInput {
    if ((mask & ~KnownInputMask) != 0) return error.InvalidInputMask;

    return .{
        .left_down = (mask & InputMaskBits.left_down) != 0,
        .right_down = (mask & InputMaskBits.right_down) != 0,
        .down_down = (mask & InputMaskBits.down_down) != 0,
        .left_pressed = (mask & InputMaskBits.left_pressed) != 0,
        .right_pressed = (mask & InputMaskBits.right_pressed) != 0,
        .rotate_cw_pressed = (mask & InputMaskBits.rotate_cw_pressed) != 0,
        .rotate_ccw_pressed = (mask & InputMaskBits.rotate_ccw_pressed) != 0,
        .rotate_180_pressed = (mask & InputMaskBits.rotate_180_pressed) != 0,
        .hold_pressed = (mask & InputMaskBits.hold_pressed) != 0,
        .hard_drop_pressed = (mask & InputMaskBits.hard_drop_pressed) != 0,
        .pause_pressed = (mask & InputMaskBits.pause_pressed) != 0,
        .restart_pressed = (mask & InputMaskBits.restart_pressed) != 0,
    };
}

pub fn encode(packet: Packet, out: []u8) EncodeError!usize {
    return switch (packet) {
        .setup => |setup| encodeSetup(setup, out),
        .input_batch => |batch| encodeInputBatch(batch, out),
        .ack => |ack| encodeAck(ack, out),
        .state_hash => |state_hash| encodeStateHash(state_hash, out),
        .desync => |desync| encodeDesync(desync, out),
        .disconnect => |disconnect| encodeDisconnect(disconnect, out),
        .result => |result| encodeResult(result, out),
    };
}

pub fn decode(bytes: []const u8) DecodeError!Packet {
    if (bytes.len > MaxPacketSize) return error.PacketTooLarge;

    var reader = Reader{ .bytes = bytes };
    const version = try reader.readU8();
    if (version != ProtocolVersion) return error.InvalidVersion;

    const packet_type = try decodePacketType(try reader.readU8());
    const match_id = try reader.readU64();

    return switch (packet_type) {
        .setup => .{ .setup = try decodeSetup(match_id, &reader) },
        .input_batch => .{ .input_batch = try decodeInputBatch(match_id, &reader) },
        .ack => .{ .ack = try decodeAck(match_id, &reader) },
        .state_hash => .{ .state_hash = try decodeStateHash(match_id, &reader) },
        .desync => .{ .desync = try decodeDesync(match_id, &reader) },
        .disconnect => .{ .disconnect = try decodeDisconnect(match_id, &reader) },
        .result => .{ .result = try decodeResult(match_id, &reader) },
    };
}

fn encodeSetup(setup: Setup, out: []u8) EncodeError!usize {
    try validateHoleChangeChance(setup.hole_num, setup.hole_den);
    const initial_hole_p1 = try encodeInitialHole(setup.initial_hole_p1);
    const initial_hole_p2 = try encodeInitialHole(setup.initial_hole_p2);

    var cursor = try startPacket(out, .setup, setup.match_id, SetupPacketSize);
    putU8(out, &cursor, setup.sender_slot);
    putU8(out, &cursor, @intFromEnum(setup.ruleset));
    putU16(out, &cursor, setup.input_delay_frames);
    putU64(out, &cursor, setup.p1_seed);
    putU64(out, &cursor, setup.p2_seed);
    putU64(out, &cursor, setup.garbage_seed);
    putU8(out, &cursor, setup.hole_num);
    putU8(out, &cursor, setup.hole_den);
    putU8(out, &cursor, initial_hole_p1);
    putU8(out, &cursor, initial_hole_p2);
    return cursor;
}

fn encodeInputBatch(batch: InputBatch, out: []u8) EncodeError!usize {
    if (batch.countUsize() > MaxInputBatchCount) return error.TooManyInputs;

    const total_len = InputBatchPrefixSize + batch.countUsize() * 2;
    var cursor = try startPacket(out, .input_batch, batch.match_id, total_len);
    putU8(out, &cursor, batch.player_slot);
    putU64(out, &cursor, batch.first_frame);
    putU8(out, &cursor, batch.count);
    for (batch.inputSlice()) |frame| {
        putU16(out, &cursor, frameInputToMask(frame));
    }
    return cursor;
}

fn encodeAck(ack: Ack, out: []u8) EncodeError!usize {
    var cursor = try startPacket(out, .ack, ack.match_id, AckPacketSize);
    putU8(out, &cursor, ack.sender_slot);
    putU8(out, &cursor, ack.acked_slot);
    putU64(out, &cursor, ack.next_needed_frame);
    return cursor;
}

fn encodeStateHash(state_hash: StateHash, out: []u8) EncodeError!usize {
    var cursor = try startPacket(out, .state_hash, state_hash.match_id, StateHashPacketSize);
    putU8(out, &cursor, state_hash.sender_slot);
    putU64(out, &cursor, state_hash.frame_cursor);
    putU64(out, &cursor, state_hash.state_hash);
    return cursor;
}

fn encodeDesync(desync: Desync, out: []u8) EncodeError!usize {
    var cursor = try startPacket(out, .desync, desync.match_id, DesyncPacketSize);
    putU8(out, &cursor, desync.sender_slot);
    putU8(out, &cursor, desync.reason);
    putU64(out, &cursor, desync.frame_cursor);
    putU64(out, &cursor, desync.local_hash);
    putU64(out, &cursor, desync.peer_hash);
    return cursor;
}

fn encodeDisconnect(disconnect: Disconnect, out: []u8) EncodeError!usize {
    var cursor = try startPacket(out, .disconnect, disconnect.match_id, DisconnectPacketSize);
    putU8(out, &cursor, disconnect.sender_slot);
    putU8(out, &cursor, disconnect.reason);
    putU64(out, &cursor, disconnect.last_frame_cursor);
    return cursor;
}

fn encodeResult(result: Result, out: []u8) EncodeError!usize {
    var cursor = try startPacket(out, .result, result.match_id, ResultPacketSize);
    putU8(out, &cursor, result.sender_slot);
    putU8(out, &cursor, @intFromEnum(result.outcome));
    putU64(out, &cursor, result.frame_cursor);
    putU64(out, &cursor, result.state_hash);
    return cursor;
}

fn decodeSetup(match_id: u64, reader: *Reader) DecodeError!Setup {
    const setup = Setup{
        .match_id = match_id,
        .sender_slot = try reader.readU8(),
        .ruleset = try decodeRuleset(try reader.readU8()),
        .input_delay_frames = try reader.readU16(),
        .p1_seed = try reader.readU64(),
        .p2_seed = try reader.readU64(),
        .garbage_seed = try reader.readU64(),
        .hole_num = try reader.readU8(),
        .hole_den = try reader.readU8(),
        .initial_hole_p1 = try decodeInitialHole(try reader.readU8()),
        .initial_hole_p2 = try decodeInitialHole(try reader.readU8()),
    };
    try validateHoleChangeChance(setup.hole_num, setup.hole_den);
    try reader.expectEnd();
    return setup;
}

fn decodeInputBatch(match_id: u64, reader: *Reader) DecodeError!InputBatch {
    var batch = InputBatch{
        .match_id = match_id,
        .player_slot = try reader.readU8(),
        .first_frame = try reader.readU64(),
    };
    batch.count = try reader.readU8();
    if (batch.countUsize() > MaxInputBatchCount) return error.TooManyInputs;

    for (0..batch.countUsize()) |index| {
        batch.inputs[index] = try frameInputFromMask(try reader.readU16());
    }
    try reader.expectEnd();
    return batch;
}

fn decodeAck(match_id: u64, reader: *Reader) DecodeError!Ack {
    const ack = Ack{
        .match_id = match_id,
        .sender_slot = try reader.readU8(),
        .acked_slot = try reader.readU8(),
        .next_needed_frame = try reader.readU64(),
    };
    try reader.expectEnd();
    return ack;
}

fn decodeStateHash(match_id: u64, reader: *Reader) DecodeError!StateHash {
    const state_hash = StateHash{
        .match_id = match_id,
        .sender_slot = try reader.readU8(),
        .frame_cursor = try reader.readU64(),
        .state_hash = try reader.readU64(),
    };
    try reader.expectEnd();
    return state_hash;
}

fn decodeDesync(match_id: u64, reader: *Reader) DecodeError!Desync {
    const desync = Desync{
        .match_id = match_id,
        .sender_slot = try reader.readU8(),
        .reason = try reader.readU8(),
        .frame_cursor = try reader.readU64(),
        .local_hash = try reader.readU64(),
        .peer_hash = try reader.readU64(),
    };
    try reader.expectEnd();
    return desync;
}

fn decodeDisconnect(match_id: u64, reader: *Reader) DecodeError!Disconnect {
    const disconnect = Disconnect{
        .match_id = match_id,
        .sender_slot = try reader.readU8(),
        .reason = try reader.readU8(),
        .last_frame_cursor = try reader.readU64(),
    };
    try reader.expectEnd();
    return disconnect;
}

fn decodeResult(match_id: u64, reader: *Reader) DecodeError!Result {
    const result = Result{
        .match_id = match_id,
        .sender_slot = try reader.readU8(),
        .outcome = try decodeResultOutcome(try reader.readU8()),
        .frame_cursor = try reader.readU64(),
        .state_hash = try reader.readU64(),
    };
    try reader.expectEnd();
    return result;
}

fn startPacket(out: []u8, packet_type: PacketType, match_id: u64, total_len: usize) EncodeError!usize {
    if (total_len > MaxPacketSize) return error.PacketTooLarge;
    if (out.len < total_len) return error.BufferTooSmall;
    out[0] = ProtocolVersion;
    out[1] = @intFromEnum(packet_type);
    var cursor: usize = 2;
    putU64(out, &cursor, match_id);
    return HeaderSize;
}

fn putU8(out: []u8, cursor: *usize, value: u8) void {
    out[cursor.*] = value;
    cursor.* += 1;
}

fn putU16(out: []u8, cursor: *usize, value: u16) void {
    out[cursor.*] = @as(u8, @truncate(value));
    out[cursor.* + 1] = @as(u8, @truncate(value >> 8));
    cursor.* += 2;
}

fn putU64(out: []u8, cursor: *usize, value: u64) void {
    inline for (0..8) |byte_index| {
        out[cursor.* + byte_index] = @as(u8, @truncate(value >> (8 * byte_index)));
    }
    cursor.* += 8;
}

fn decodePacketType(value: u8) DecodeError!PacketType {
    return switch (value) {
        @intFromEnum(PacketType.setup) => .setup,
        @intFromEnum(PacketType.input_batch) => .input_batch,
        @intFromEnum(PacketType.ack) => .ack,
        @intFromEnum(PacketType.state_hash) => .state_hash,
        @intFromEnum(PacketType.desync) => .desync,
        @intFromEnum(PacketType.disconnect) => .disconnect,
        @intFromEnum(PacketType.result) => .result,
        else => error.UnknownPacketType,
    };
}

fn decodeRuleset(value: u8) DecodeError!Ruleset {
    return switch (value) {
        @intFromEnum(Ruleset.modern) => .modern,
        else => error.UnknownRuleset,
    };
}

fn decodeResultOutcome(value: u8) DecodeError!ResultOutcome {
    return switch (value) {
        @intFromEnum(ResultOutcome.p1_win) => .p1_win,
        @intFromEnum(ResultOutcome.p2_win) => .p2_win,
        @intFromEnum(ResultOutcome.draw) => .draw,
        else => error.UnknownResultOutcome,
    };
}

fn encodeInitialHole(hole: ?u8) EncodeError!u8 {
    const value = hole orelse return NullInitialHole;
    if (value > MaxInitialHoleIndex) return error.InvalidInitialHole;
    return value;
}

fn decodeInitialHole(value: u8) DecodeError!?u8 {
    if (value == NullInitialHole) return null;
    if (value > MaxInitialHoleIndex) return error.InvalidInitialHole;
    return value;
}

fn validateHoleChangeChance(hole_num: u8, hole_den: u8) error{InvalidHoleChangeChance}!void {
    if (hole_den == 0 or hole_num > hole_den) return error.InvalidHoleChangeChance;
}

const Reader = struct {
    bytes: []const u8,
    cursor: usize = 0,

    fn readU8(self: *Reader) DecodeError!u8 {
        if (self.cursor + 1 > self.bytes.len) return error.TruncatedPacket;
        const value = self.bytes[self.cursor];
        self.cursor += 1;
        return value;
    }

    fn readU16(self: *Reader) DecodeError!u16 {
        if (self.cursor + 2 > self.bytes.len) return error.TruncatedPacket;
        const start = self.cursor;
        self.cursor += 2;
        return @as(u16, self.bytes[start]) |
            (@as(u16, self.bytes[start + 1]) << 8);
    }

    fn readU64(self: *Reader) DecodeError!u64 {
        if (self.cursor + 8 > self.bytes.len) return error.TruncatedPacket;
        const start = self.cursor;
        self.cursor += 8;

        var value: u64 = 0;
        inline for (0..8) |byte_index| {
            value |= @as(u64, self.bytes[start + byte_index]) << (8 * byte_index);
        }
        return value;
    }

    fn expectEnd(self: *const Reader) DecodeError!void {
        if (self.cursor != self.bytes.len) return error.TrailingBytes;
    }
};

fn expectRoundTrip(packet: Packet) !void {
    var bytes: [MaxPacketSize]u8 = undefined;
    const len = try encode(packet, bytes[0..]);
    const decoded = try decode(bytes[0..len]);
    try std.testing.expectEqualDeep(packet, decoded);
}

fn expectGolden(packet: Packet, expected: []const u8) !void {
    var bytes: [MaxPacketSize]u8 = undefined;
    const len = try encode(packet, bytes[0..]);
    try std.testing.expectEqual(expected.len, len);
    try std.testing.expectEqualSlices(u8, expected, bytes[0..len]);

    const decoded = try decode(expected);
    try std.testing.expectEqualDeep(packet, decoded);
}

const GoldenMatchId: u64 = 0x0123_4567_89ab_cdef;

fn setupFixture() Packet {
    return .{ .setup = .{
        .match_id = GoldenMatchId,
        .sender_slot = 1,
        .ruleset = .modern,
        .input_delay_frames = 6,
        .p1_seed = 0x1111_2222_3333_4444,
        .p2_seed = 0x5555_6666_7777_8888,
        .garbage_seed = 0x9999_aaaa_bbbb_cccc,
        .hole_num = 1,
        .hole_den = 4,
        .initial_hole_p1 = 0,
        .initial_hole_p2 = null,
    } };
}

test "input masks round-trip every frame input field" {
    const cases = [_]struct {
        frame: input.FrameInput,
        mask: u16,
    }{
        .{ .frame = .{ .left_down = true }, .mask = InputMaskBits.left_down },
        .{ .frame = .{ .right_down = true }, .mask = InputMaskBits.right_down },
        .{ .frame = .{ .down_down = true }, .mask = InputMaskBits.down_down },
        .{ .frame = .{ .left_pressed = true }, .mask = InputMaskBits.left_pressed },
        .{ .frame = .{ .right_pressed = true }, .mask = InputMaskBits.right_pressed },
        .{ .frame = .{ .rotate_cw_pressed = true }, .mask = InputMaskBits.rotate_cw_pressed },
        .{ .frame = .{ .rotate_ccw_pressed = true }, .mask = InputMaskBits.rotate_ccw_pressed },
        .{ .frame = .{ .rotate_180_pressed = true }, .mask = InputMaskBits.rotate_180_pressed },
        .{ .frame = .{ .hold_pressed = true }, .mask = InputMaskBits.hold_pressed },
        .{ .frame = .{ .hard_drop_pressed = true }, .mask = InputMaskBits.hard_drop_pressed },
        .{ .frame = .{ .pause_pressed = true }, .mask = InputMaskBits.pause_pressed },
        .{ .frame = .{ .restart_pressed = true }, .mask = InputMaskBits.restart_pressed },
    };

    for (cases) |fixture| {
        try std.testing.expectEqual(fixture.mask, frameInputToMask(fixture.frame));
        try std.testing.expectEqualDeep(fixture.frame, try frameInputFromMask(fixture.mask));
    }

    const all_inputs = input.FrameInput{
        .left_down = true,
        .right_down = true,
        .down_down = true,
        .left_pressed = true,
        .right_pressed = true,
        .rotate_cw_pressed = true,
        .rotate_ccw_pressed = true,
        .rotate_180_pressed = true,
        .hold_pressed = true,
        .hard_drop_pressed = true,
        .pause_pressed = true,
        .restart_pressed = true,
    };
    try std.testing.expectEqual(KnownInputMask, frameInputToMask(all_inputs));
    try std.testing.expectEqualDeep(all_inputs, try frameInputFromMask(KnownInputMask));
}

test "input masks reject reserved bits" {
    try std.testing.expectError(error.InvalidInputMask, frameInputFromMask(0x1000));
    try std.testing.expectError(error.InvalidInputMask, frameInputFromMask(0xf000));
}

test "setup packet round-trips" {
    try expectRoundTrip(setupFixture());
}

test "setup packet has stable golden layout" {
    const expected = [_]u8{
        1,
        1,
        0xef,
        0xcd,
        0xab,
        0x89,
        0x67,
        0x45,
        0x23,
        0x01,
        1,
        1,
        0x06,
        0x00,
        0x44,
        0x44,
        0x33,
        0x33,
        0x22,
        0x22,
        0x11,
        0x11,
        0x88,
        0x88,
        0x77,
        0x77,
        0x66,
        0x66,
        0x55,
        0x55,
        0xcc,
        0xcc,
        0xbb,
        0xbb,
        0xaa,
        0xaa,
        0x99,
        0x99,
        1,
        4,
        0,
        0xff,
    };
    try std.testing.expectEqual(@as(usize, SetupPacketSize), expected.len);
    try expectGolden(setupFixture(), &expected);
}

test "input batch packet round-trips" {
    const packet = Packet{ .input_batch = try InputBatch.init(GoldenMatchId, 0, 120, &[_]input.FrameInput{
        .{ .left_down = true, .left_pressed = true },
        .{ .right_down = true, .rotate_cw_pressed = true },
        .{ .down_down = true, .hard_drop_pressed = true, .pause_pressed = true },
    }) };
    try expectRoundTrip(packet);
}

test "input batch packet has stable golden layout" {
    const packet = Packet{ .input_batch = try InputBatch.init(GoldenMatchId, 0, 120, &[_]input.FrameInput{
        .{ .left_down = true, .left_pressed = true },
        .{ .right_down = true, .rotate_cw_pressed = true },
        .{ .down_down = true, .hard_drop_pressed = true, .pause_pressed = true },
    }) };
    const expected = [_]u8{
        1,
        2,
        0xef,
        0xcd,
        0xab,
        0x89,
        0x67,
        0x45,
        0x23,
        0x01,
        0,
        0x78,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        3,
        0x09,
        0x00,
        0x22,
        0x00,
        0x04,
        0x06,
    };
    try std.testing.expectEqual(@as(usize, InputBatchPrefixSize + 3 * 2), expected.len);
    try expectGolden(packet, &expected);
}

test "ack packet round-trips" {
    try expectRoundTrip(.{ .ack = .{
        .match_id = GoldenMatchId,
        .sender_slot = 0,
        .acked_slot = 1,
        .next_needed_frame = 321,
    } });
}

test "ack packet has stable golden layout" {
    const packet = Packet{ .ack = .{
        .match_id = GoldenMatchId,
        .sender_slot = 0,
        .acked_slot = 1,
        .next_needed_frame = 321,
    } };
    const expected = [_]u8{
        1,
        3,
        0xef,
        0xcd,
        0xab,
        0x89,
        0x67,
        0x45,
        0x23,
        0x01,
        0,
        1,
        0x41,
        0x01,
        0,
        0,
        0,
        0,
        0,
        0,
    };
    try std.testing.expectEqual(@as(usize, AckPacketSize), expected.len);
    try expectGolden(packet, &expected);
}

test "state hash packet round-trips" {
    try expectRoundTrip(.{ .state_hash = .{
        .match_id = GoldenMatchId,
        .sender_slot = 1,
        .frame_cursor = 777,
        .state_hash = 0x0123_4567_89ab_cdef,
    } });
}

test "state hash packet has stable golden layout" {
    const packet = Packet{ .state_hash = .{
        .match_id = GoldenMatchId,
        .sender_slot = 1,
        .frame_cursor = 777,
        .state_hash = 0x0123_4567_89ab_cdef,
    } };
    const expected = [_]u8{
        1,
        4,
        0xef,
        0xcd,
        0xab,
        0x89,
        0x67,
        0x45,
        0x23,
        0x01,
        1,
        0x09,
        0x03,
        0,
        0,
        0,
        0,
        0,
        0,
        0xef,
        0xcd,
        0xab,
        0x89,
        0x67,
        0x45,
        0x23,
        0x01,
    };
    try std.testing.expectEqual(@as(usize, StateHashPacketSize), expected.len);
    try expectGolden(packet, &expected);
}

test "desync packet round-trips" {
    try expectRoundTrip(.{ .desync = .{
        .match_id = GoldenMatchId,
        .sender_slot = 0,
        .reason = 2,
        .frame_cursor = 888,
        .local_hash = 0xaaaa_bbbb_cccc_dddd,
        .peer_hash = 0x1111_2222_3333_4444,
    } });
}

test "desync packet has stable golden layout" {
    const packet = Packet{ .desync = .{
        .match_id = GoldenMatchId,
        .sender_slot = 0,
        .reason = 2,
        .frame_cursor = 888,
        .local_hash = 0xaaaa_bbbb_cccc_dddd,
        .peer_hash = 0x1111_2222_3333_4444,
    } };
    const expected = [_]u8{
        1,
        5,
        0xef,
        0xcd,
        0xab,
        0x89,
        0x67,
        0x45,
        0x23,
        0x01,
        0,
        2,
        0x78,
        0x03,
        0,
        0,
        0,
        0,
        0,
        0,
        0xdd,
        0xdd,
        0xcc,
        0xcc,
        0xbb,
        0xbb,
        0xaa,
        0xaa,
        0x44,
        0x44,
        0x33,
        0x33,
        0x22,
        0x22,
        0x11,
        0x11,
    };
    try std.testing.expectEqual(@as(usize, DesyncPacketSize), expected.len);
    try expectGolden(packet, &expected);
}

test "disconnect packet round-trips" {
    try expectRoundTrip(.{ .disconnect = .{
        .match_id = GoldenMatchId,
        .sender_slot = 1,
        .reason = 3,
        .last_frame_cursor = 999,
    } });
}

test "disconnect packet has stable golden layout" {
    const packet = Packet{ .disconnect = .{
        .match_id = GoldenMatchId,
        .sender_slot = 1,
        .reason = 3,
        .last_frame_cursor = 999,
    } };
    const expected = [_]u8{
        1,
        6,
        0xef,
        0xcd,
        0xab,
        0x89,
        0x67,
        0x45,
        0x23,
        0x01,
        1,
        3,
        0xe7,
        0x03,
        0,
        0,
        0,
        0,
        0,
        0,
    };
    try std.testing.expectEqual(@as(usize, DisconnectPacketSize), expected.len);
    try expectGolden(packet, &expected);
}

test "result packet round-trips" {
    try expectRoundTrip(.{ .result = .{
        .match_id = GoldenMatchId,
        .sender_slot = 0,
        .outcome = .p1_win,
        .frame_cursor = 1234,
        .state_hash = 0xfedc_ba98_7654_3210,
    } });
}

test "result packet has stable golden layout" {
    const packet = Packet{ .result = .{
        .match_id = GoldenMatchId,
        .sender_slot = 0,
        .outcome = .p1_win,
        .frame_cursor = 1234,
        .state_hash = 0xfedc_ba98_7654_3210,
    } };
    const expected = [_]u8{
        1,
        7,
        0xef,
        0xcd,
        0xab,
        0x89,
        0x67,
        0x45,
        0x23,
        0x01,
        0,
        1,
        0xd2,
        0x04,
        0,
        0,
        0,
        0,
        0,
        0,
        0x10,
        0x32,
        0x54,
        0x76,
        0x98,
        0xba,
        0xdc,
        0xfe,
    };
    try std.testing.expectEqual(@as(usize, ResultPacketSize), expected.len);
    try expectGolden(packet, &expected);
}

test "decode rejects invalid version and packet type" {
    try std.testing.expectError(error.InvalidVersion, decode(&[_]u8{ 0, 3 }));
    try std.testing.expectError(error.UnknownPacketType, decode(&[_]u8{ 1, 0xff }));
}

test "fixed-size packets reject trailing bytes" {
    const packets = [_]Packet{
        setupFixture(),
        .{ .ack = .{ .match_id = GoldenMatchId, .sender_slot = 0, .acked_slot = 1, .next_needed_frame = 1 } },
        .{ .state_hash = .{ .match_id = GoldenMatchId, .sender_slot = 0, .frame_cursor = 2, .state_hash = 3 } },
        .{ .desync = .{ .match_id = GoldenMatchId, .sender_slot = 0, .reason = 1, .frame_cursor = 2, .local_hash = 3, .peer_hash = 4 } },
        .{ .disconnect = .{ .match_id = GoldenMatchId, .sender_slot = 0, .reason = 1, .last_frame_cursor = 2 } },
        .{ .result = .{ .match_id = GoldenMatchId, .sender_slot = 0, .outcome = .draw, .frame_cursor = 2, .state_hash = 3 } },
    };

    for (packets) |packet| {
        var bytes: [MaxPacketSize]u8 = undefined;
        const len = try encode(packet, bytes[0..]);
        bytes[len] = 0xaa;
        try std.testing.expectError(error.TrailingBytes, decode(bytes[0 .. len + 1]));
    }
}

test "overlarge packets are rejected" {
    var bytes = [_]u8{0} ** (MaxPacketSize + 1);
    try std.testing.expectError(error.PacketTooLarge, decode(bytes[0..]));
}

test "input batch rejects too many inputs" {
    const bytes = [_]u8{
        1,
        2,
        0xef,
        0xcd,
        0xab,
        0x89,
        0x67,
        0x45,
        0x23,
        0x01,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        @as(u8, MaxInputBatchCount + 1),
    };
    try std.testing.expectError(error.TooManyInputs, decode(bytes[0..]));

    var too_many = [_]input.FrameInput{.{}} ** (MaxInputBatchCount + 1);
    try std.testing.expectError(error.TooManyInputs, InputBatch.init(GoldenMatchId, 0, 0, too_many[0..]));
}

test "input batch rejects invalid input mask" {
    const bytes = [_]u8{
        1,
        2,
        0xef,
        0xcd,
        0xab,
        0x89,
        0x67,
        0x45,
        0x23,
        0x01,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        1,
        0x00,
        0x10,
    };
    try std.testing.expectError(error.InvalidInputMask, decode(bytes[0..]));
}

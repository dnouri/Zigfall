// SPDX-License-Identifier: GPL-3.0-or-later

//! Raylib-free Zig wrapper for the browser-only Trystero transport.
//!
//! Native builds intentionally expose stubs and never reference browser or
//! Emscripten JS symbols. Web builds link `web/zigfall_transport_emscripten.js`,
//! which forwards these extern calls to `globalThis.ZigfallTransport` from
//! `web/zigfall_transport.mjs`. Packets are opaque Phase 4 protocol bytes.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol");

pub const MaxPacketSize = protocol.MaxPacketSize;
pub const MaxRoomIdLength: usize = 128;

const is_web = builtin.os.tag == .emscripten;

pub const Status = enum(u8) {
    unavailable = 0,
    missing_js = 1,
    disconnected = 2,
    connecting = 3,
    connected = 4,
    busy = 5,

    pub fn text(self: Status) [:0]const u8 {
        return switch (self) {
            .unavailable => "unavailable",
            .missing_js => "missing JS",
            .disconnected => "disconnected",
            .connecting => "connecting",
            .connected => "connected",
            .busy => "busy",
        };
    }
};

pub const ErrorCode = enum(u8) {
    none = 0,
    missing_js = 1,
    unavailable = 2,
    bad_room = 3,
    join_failed = 4,
    not_connected = 5,
    no_peer = 6,
    packet_too_large = 7,
    queue_full = 8,
    send_failed = 9,
    buffer_too_small = 10,
    busy = 11,

    pub fn text(self: ErrorCode) [:0]const u8 {
        return switch (self) {
            .none => "none",
            .missing_js => "missing JS",
            .unavailable => "unavailable",
            .bad_room => "bad room",
            .join_failed => "join failed",
            .not_connected => "not connected",
            .no_peer => "no peer",
            .packet_too_large => "packet too large",
            .queue_full => "queue full",
            .send_failed => "send failed",
            .buffer_too_small => "buffer too small",
            .busy => "busy",
        };
    }
};

pub const ConnectError = error{
    Unavailable,
    MissingJs,
    BadRoom,
    JoinFailed,
};

pub const SendError = error{
    Unavailable,
    MissingJs,
    NotConnected,
    NoPeer,
    PacketTooLarge,
    SendFailed,
};

pub const PollError = error{
    MissingJs,
    PacketTooLarge,
    BufferTooSmall,
};

pub fn connect(room_id: []const u8) ConnectError!void {
    if (!isValidRoomId(room_id)) return error.BadRoom;
    if (comptime !is_web) return error.Unavailable;
    return mapConnectResult(js.zigfall_transport_connect(room_id.ptr, room_id.len));
}

pub fn disconnect() void {
    if (comptime is_web) js.zigfall_transport_disconnect();
}

pub fn send(packet: []const u8) SendError!void {
    if (packet.len > MaxPacketSize) return error.PacketTooLarge;
    if (comptime !is_web) return error.Unavailable;
    return mapSendResult(js.zigfall_transport_send(packet.ptr, packet.len));
}

/// Send optional display metadata without allowing asynchronous transport
/// rejection to poison global transport health. Gameplay and lifecycle packets
/// must continue to use `send`.
pub fn sendBestEffort(packet: []const u8) SendError!void {
    if (packet.len > MaxPacketSize) return error.PacketTooLarge;
    if (comptime !is_web) return error.Unavailable;
    return mapSendResult(js.zigfall_transport_send_best_effort(packet.ptr, packet.len));
}

pub fn poll(out: []u8) PollError!?[]const u8 {
    if (out.len < MaxPacketSize) return error.BufferTooSmall;
    if (comptime !is_web) return null;

    const result = js.zigfall_transport_poll(out.ptr, out.len);
    if (result == 0) return null;
    if (result < 0) return mapPollError(@intCast(-result));
    const len: usize = @intCast(result);
    if (len > MaxPacketSize) return error.PacketTooLarge;
    return out[0..len];
}

pub fn status() Status {
    if (comptime !is_web) return .unavailable;
    return enumFromCode(Status, js.zigfall_transport_status()) orelse .missing_js;
}

pub fn lastError() ErrorCode {
    if (comptime !is_web) return .unavailable;
    return enumFromCode(ErrorCode, js.zigfall_transport_last_error()) orelse .missing_js;
}

pub fn peerCount() u8 {
    if (comptime !is_web) return 0;
    return js.zigfall_transport_peer_count();
}

pub fn queuedPacketCount() u16 {
    if (comptime !is_web) return 0;
    return js.zigfall_transport_queued_packet_count();
}

fn isValidRoomId(room_id: []const u8) bool {
    if (room_id.len == 0 or room_id.len > MaxRoomIdLength) return false;
    for (room_id) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '~', '-' => {},
            else => return false,
        }
    }
    return true;
}

fn mapConnectResult(code: u8) ConnectError!void {
    return switch (enumFromCode(ErrorCode, code) orelse .missing_js) {
        .none => {},
        .missing_js => error.MissingJs,
        .bad_room => error.BadRoom,
        .join_failed => error.JoinFailed,
        .unavailable => error.Unavailable,
        else => error.JoinFailed,
    };
}

fn mapSendResult(code: u8) SendError!void {
    return switch (enumFromCode(ErrorCode, code) orelse .missing_js) {
        .none => {},
        .missing_js => error.MissingJs,
        .unavailable => error.Unavailable,
        .not_connected => error.NotConnected,
        .no_peer, .busy => error.NoPeer,
        .packet_too_large => error.PacketTooLarge,
        .send_failed => error.SendFailed,
        else => error.SendFailed,
    };
}

fn mapPollError(code: u8) PollError {
    return switch (enumFromCode(ErrorCode, code) orelse .missing_js) {
        .missing_js => error.MissingJs,
        .packet_too_large => error.PacketTooLarge,
        .buffer_too_small => error.BufferTooSmall,
        else => error.BufferTooSmall,
    };
}

fn enumFromCode(comptime Enum: type, code: u8) ?Enum {
    return std.enums.fromInt(Enum, code);
}

const js = if (is_web) struct {
    extern fn zigfall_transport_status() u8;
    extern fn zigfall_transport_last_error() u8;
    extern fn zigfall_transport_connect(room_ptr: [*]const u8, room_len: usize) u8;
    extern fn zigfall_transport_disconnect() void;
    extern fn zigfall_transport_send(packet_ptr: [*]const u8, packet_len: usize) u8;
    extern fn zigfall_transport_send_best_effort(packet_ptr: [*]const u8, packet_len: usize) u8;
    extern fn zigfall_transport_poll(out_ptr: [*]u8, out_cap: usize) i32;
    extern fn zigfall_transport_peer_count() u8;
    extern fn zigfall_transport_queued_packet_count() u16;
} else struct {};

test "native transport status is unavailable" {
    if (is_web) return error.SkipZigTest;

    try std.testing.expectEqual(Status.unavailable, status());
    try std.testing.expectEqual(ErrorCode.unavailable, lastError());
    try std.testing.expectEqual(@as(u8, 0), peerCount());
    try std.testing.expectEqual(@as(u16, 0), queuedPacketCount());
}

test "native transport stubs do not require browser JS" {
    if (is_web) return error.SkipZigTest;

    try std.testing.expectError(error.Unavailable, connect("zigfall-phase5-local"));
    disconnect();

    var packet = [_]u8{0} ** MaxPacketSize;
    try std.testing.expectError(error.Unavailable, send(&packet));
    try std.testing.expectError(error.Unavailable, sendBestEffort(&packet));

    var out = [_]u8{0} ** MaxPacketSize;
    try std.testing.expectEqual(@as(?[]const u8, null), try poll(&out));
}

test "transport validates room IDs before platform calls" {
    try std.testing.expectError(error.BadRoom, connect(""));
    try std.testing.expectError(error.BadRoom, connect("bad room"));
    try std.testing.expectError(error.BadRoom, connect("../room"));

    const too_long = [_]u8{'a'} ** (MaxRoomIdLength + 1);
    try std.testing.expectError(error.BadRoom, connect(&too_long));
}

test "transport enforces max packet size before platform calls" {
    var packet = [_]u8{0} ** (MaxPacketSize + 1);
    try std.testing.expectError(error.PacketTooLarge, send(&packet));
    try std.testing.expectError(error.PacketTooLarge, sendBestEffort(&packet));
}

test "poll requires a max-sized Zig-owned output buffer" {
    var out = [_]u8{0} ** (MaxPacketSize - 1);
    try std.testing.expectError(error.BufferTooSmall, poll(&out));
}

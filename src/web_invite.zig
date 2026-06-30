// SPDX-License-Identifier: GPL-3.0-or-later

//! Native-safe wrapper for the browser invite-link helper.
//!
//! Native builds expose stubs and never reference browser APIs or JS symbols.
//! Web builds link `web/zigfall_invite_emscripten.js`, which forwards these
//! extern calls to `globalThis.ZigfallInvite` from `web/zigfall_invite.mjs`.
//! All strings are copied into Zig-owned caller buffers.

const std = @import("std");
const builtin = @import("builtin");

pub const MaxRoomIdLength: usize = 128;
pub const MaxJoinUrlLength: usize = 2048;

const is_web = builtin.os.tag == .emscripten;

pub const ErrorCode = enum(u8) {
    none = 0,
    missing_js = 1,
    unavailable = 2,
    bad_room = 3,
    buffer_too_small = 4,
    random_unavailable = 5,
    url_too_long = 6,
    copy_unavailable = 7,
    copy_failed = 8,

    pub fn text(self: ErrorCode) [:0]const u8 {
        return switch (self) {
            .none => "none",
            .missing_js => "missing JS",
            .unavailable => "unavailable",
            .bad_room => "bad room",
            .buffer_too_small => "buffer too small",
            .random_unavailable => "random unavailable",
            .url_too_long => "URL too long",
            .copy_unavailable => "copy unavailable",
            .copy_failed => "copy failed",
        };
    }
};

pub const CopyStatus = enum(u8) {
    unavailable = 0,
    missing_js = 1,
    idle = 2,
    pending = 3,
    copied = 4,
    fallback = 5,
    failed = 6,

    pub fn text(self: CopyStatus) [:0]const u8 {
        return switch (self) {
            .unavailable => "unavailable",
            .missing_js => "missing JS",
            .idle => "idle",
            .pending => "pending",
            .copied => "copied",
            .fallback => "fallback",
            .failed => "failed",
        };
    }
};

pub const InitialJoinError = error{
    MissingJs,
    BadRoom,
    BufferTooSmall,
    Unavailable,
};

pub const CreateHostError = error{
    Unavailable,
    MissingJs,
    RandomUnavailable,
    BufferTooSmall,
};

pub const JoinUrlError = error{
    Unavailable,
    MissingJs,
    BadRoom,
    BufferTooSmall,
    UrlTooLong,
};

pub const CopyError = error{
    Unavailable,
    MissingJs,
    BadRoom,
    UrlTooLong,
    CopyUnavailable,
    CopyFailed,
};

/// Read the current page's `?join=<room>` room id into `out`.
/// Missing `join` is not an error and returns null; malformed `join` is rejected.
pub fn initialJoinRoom(out: []u8) InitialJoinError!?[]const u8 {
    if (comptime !is_web) return null;
    const result = js.zigfall_invite_initial_join_room(out.ptr, out.len);
    if (result == 0) return null;
    if (result < 0) return mapInitialJoinError(@intCast(-result));
    return checkedSlice(out, result) catch error.BufferTooSmall;
}

/// Create an opaque random URL-safe host room id into `out`.
pub fn createHostRoom(out: []u8) CreateHostError![]const u8 {
    if (out.len == 0) return error.BufferTooSmall;
    if (comptime !is_web) return error.Unavailable;
    const result = js.zigfall_invite_create_host_room(out.ptr, out.len);
    if (result < 0) return mapCreateHostError(@intCast(-result));
    return checkedSlice(out, result) catch error.BufferTooSmall;
}

/// Build a shareable join URL for `room_id` into `out` from the current browser
/// origin/path with only the generated `join` parameter. Unrelated query/hash
/// state is intentionally not copied into playable invite links.
pub fn joinUrl(room_id: []const u8, out: []u8) JoinUrlError![]const u8 {
    if (!isValidRoomId(room_id)) return error.BadRoom;
    if (comptime !is_web) return error.Unavailable;
    const result = js.zigfall_invite_join_url(room_id.ptr, room_id.len, out.ptr, out.len);
    if (result < 0) return mapJoinUrlError(@intCast(-result));
    return checkedSlice(out, result) catch error.BufferTooSmall;
}

/// Request an async browser clipboard copy of this room's join URL. Poll
/// `copyStatus()` on later frames for pending/copied/fallback/failed.
pub fn requestCopyJoinUrl(room_id: []const u8) CopyError!void {
    if (!isValidRoomId(room_id)) return error.BadRoom;
    if (comptime !is_web) return error.Unavailable;
    return mapCopyResult(js.zigfall_invite_request_copy_join_url(room_id.ptr, room_id.len));
}

pub fn copyStatus() CopyStatus {
    if (comptime !is_web) return .unavailable;
    return enumFromCode(CopyStatus, js.zigfall_invite_copy_status()) orelse .missing_js;
}

pub fn isValidRoomId(room_id: []const u8) bool {
    if (room_id.len == 0 or room_id.len > MaxRoomIdLength) return false;
    for (room_id) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '~', '-' => {},
            else => return false,
        }
    }
    return true;
}

fn checkedSlice(out: []u8, result: i32) error{BufferTooSmall}![]const u8 {
    const len: usize = @intCast(result);
    if (len > out.len) return error.BufferTooSmall;
    return out[0..len];
}

fn mapInitialJoinError(code: u8) InitialJoinError {
    return switch (enumFromCode(ErrorCode, code) orelse .missing_js) {
        .missing_js => error.MissingJs,
        .bad_room => error.BadRoom,
        .buffer_too_small => error.BufferTooSmall,
        .unavailable => error.Unavailable,
        else => error.Unavailable,
    };
}

fn mapCreateHostError(code: u8) CreateHostError {
    return switch (enumFromCode(ErrorCode, code) orelse .missing_js) {
        .missing_js => error.MissingJs,
        .random_unavailable => error.RandomUnavailable,
        .buffer_too_small => error.BufferTooSmall,
        .unavailable => error.Unavailable,
        else => error.Unavailable,
    };
}

fn mapJoinUrlError(code: u8) JoinUrlError {
    return switch (enumFromCode(ErrorCode, code) orelse .missing_js) {
        .missing_js => error.MissingJs,
        .bad_room => error.BadRoom,
        .buffer_too_small => error.BufferTooSmall,
        .url_too_long => error.UrlTooLong,
        .unavailable => error.Unavailable,
        else => error.Unavailable,
    };
}

fn mapCopyResult(code: u8) CopyError!void {
    return switch (enumFromCode(ErrorCode, code) orelse .missing_js) {
        .none => {},
        .missing_js => error.MissingJs,
        .bad_room => error.BadRoom,
        .url_too_long => error.UrlTooLong,
        .copy_unavailable => error.CopyUnavailable,
        .copy_failed => error.CopyFailed,
        .unavailable => error.Unavailable,
        else => error.CopyFailed,
    };
}

fn enumFromCode(comptime Enum: type, code: u8) ?Enum {
    return std.enums.fromInt(Enum, code);
}

const js = if (is_web) struct {
    extern fn zigfall_invite_initial_join_room(out_ptr: [*]u8, out_cap: usize) i32;
    extern fn zigfall_invite_create_host_room(out_ptr: [*]u8, out_cap: usize) i32;
    extern fn zigfall_invite_join_url(room_ptr: [*]const u8, room_len: usize, out_ptr: [*]u8, out_cap: usize) i32;
    extern fn zigfall_invite_request_copy_join_url(room_ptr: [*]const u8, room_len: usize) u8;
    extern fn zigfall_invite_copy_status() u8;
} else struct {};

test "native invite stubs do not require browser JS" {
    if (is_web) return error.SkipZigTest;

    var room_buf = [_]u8{0} ** MaxRoomIdLength;
    try std.testing.expectEqual(@as(?[]const u8, null), try initialJoinRoom(&room_buf));
    try std.testing.expectError(error.Unavailable, createHostRoom(&room_buf));

    var url_buf = [_]u8{0} ** MaxJoinUrlLength;
    try std.testing.expectError(error.Unavailable, joinUrl("zigfall-native-room", &url_buf));
    try std.testing.expectError(error.Unavailable, requestCopyJoinUrl("zigfall-native-room"));
    try std.testing.expectEqual(CopyStatus.unavailable, copyStatus());
}

test "invite wrapper validates room IDs before platform calls" {
    try std.testing.expect(isValidRoomId("abc-XYZ_09.~"));
    try std.testing.expect(!isValidRoomId(""));
    try std.testing.expect(!isValidRoomId("bad room"));
    try std.testing.expect(!isValidRoomId("../room"));
    try std.testing.expect(!isValidRoomId("room/child"));

    const too_long = [_]u8{'a'} ** (MaxRoomIdLength + 1);
    try std.testing.expect(!isValidRoomId(&too_long));

    var url_buf = [_]u8{0} ** MaxJoinUrlLength;
    try std.testing.expectError(error.BadRoom, joinUrl("bad room", &url_buf));
    try std.testing.expectError(error.BadRoom, requestCopyJoinUrl("../room"));
}

test "create host room requires caller-owned output storage" {
    var empty = [_]u8{};
    try std.testing.expectError(error.BufferTooSmall, createHostRoom(&empty));
}

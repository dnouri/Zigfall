// SPDX-License-Identifier: GPL-3.0-or-later

//! Native-safe wrapper for the browser-local profile store.
//!
//! Native builds expose safe default profile reads plus unavailable status and
//! never reference browser APIs or JS symbols. Web builds link
//! `web/zigfall_profile_emscripten.js`, which forwards extern calls to
//! `globalThis.ZigfallProfile` from `web/zigfall_profile.mjs`. All display
//! strings are copied into Zig-owned fixed buffers before being returned.

const std = @import("std");
const builtin = @import("builtin");
const profile = @import("profile");

pub const ProfileCard = profile.ProfileCard;
pub const VerifiedResult = profile.VerifiedResult;
pub const Rating = profile.Rating;

pub const MaxNicknameBytes = profile.MaxNicknameBytes;
pub const MaxPlayerIdBytes = profile.MaxPlayerIdBytes;
pub const MaxSerializedCardBytes = profile.MaxSerializedCardBytes;
pub const MaxErrorMessageBytes: usize = 160;

const native_unavailable_message = "browser local profile unavailable";
const is_web = builtin.os.tag == .emscripten;

pub const Status = enum(u8) {
    unavailable = 0,
    missing_js = 1,
    ready = 2,
    memory_only = 3,
    storage_error = 4,
    crypto_unavailable = 5,

    pub fn text(self: Status) [:0]const u8 {
        return switch (self) {
            .unavailable => "unavailable",
            .missing_js => "missing JS",
            .ready => "ready",
            .memory_only => "memory-only",
            .storage_error => "storage error",
            .crypto_unavailable => "crypto unavailable",
        };
    }
};

pub const ErrorCode = enum(u8) {
    none = 0,
    missing_js = 1,
    unavailable = 2,
    buffer_too_small = 3,
    storage_unavailable = 4,
    storage_failed = 5,
    crypto_unavailable = 6,
    bad_nickname = 7,
    bad_result = 8,
    bad_rating = 9,
    profile_too_large = 10,

    pub fn text(self: ErrorCode) [:0]const u8 {
        return switch (self) {
            .none => "none",
            .missing_js => "missing JS",
            .unavailable => "unavailable",
            .buffer_too_small => "buffer too small",
            .storage_unavailable => "storage unavailable",
            .storage_failed => "storage failed",
            .crypto_unavailable => "crypto unavailable",
            .bad_nickname => "bad nickname",
            .bad_result => "bad result",
            .bad_rating => "bad rating",
            .profile_too_large => "profile too large",
        };
    }
};

pub const ReadError = error{
    MissingJs,
    Unavailable,
    BufferTooSmall,
    InvalidCard,
};

pub const MutationResult = struct {
    card: ProfileCard,
    status: Status,
};

pub const UpdateError = error{
    MissingJs,
    Unavailable,
    StorageUnavailable,
    StorageFailed,
    CryptoUnavailable,
    BadNickname,
    BadResult,
    BadRating,
    ProfileTooLarge,
};

pub fn status() Status {
    if (comptime !is_web) return .unavailable;
    return enumFromCode(Status, js.zigfall_profile_status()) orelse .missing_js;
}

pub fn lastErrorMessage(out: []u8) ReadError![]const u8 {
    if (comptime !is_web) return copyInto(out, native_unavailable_message);
    const result = js.zigfall_profile_last_error(out.ptr, out.len);
    if (result < 0) return mapReadError(@intCast(-result));
    return checkedSlice(out, result) catch error.BufferTooSmall;
}

pub fn loadCard() ReadError!ProfileCard {
    if (comptime !is_web) return ProfileCard.default();

    var id_buf: [MaxPlayerIdBytes]u8 = undefined;
    const id = try readPlayerId(&id_buf);
    var nickname_buf: [MaxNicknameBytes]u8 = undefined;
    const nickname_value = try readNickname(&nickname_buf);

    const rating_result = js.zigfall_profile_rating();
    if (rating_result < 0) return mapReadError(@intCast(-rating_result));

    var card = ProfileCard.default();
    card.setPlayerId(id) catch return error.InvalidCard;
    card.setNickname(nickname_value) catch return error.InvalidCard;
    card.setRatingClamped(rating_result);
    card.wins = js.zigfall_profile_wins();
    card.losses = js.zigfall_profile_losses();
    card.draws = js.zigfall_profile_draws();
    return card;
}

pub fn playerId(out: []u8) ReadError![]const u8 {
    if (comptime !is_web) return copyInto(out, ProfileCard.default().playerId());
    return readPlayerId(out);
}

pub fn nickname(out: []u8) ReadError![]const u8 {
    if (comptime !is_web) return copyInto(out, ProfileCard.default().nicknameText());
    return readNickname(out);
}

pub fn setNickname(nickname_value: []const u8) UpdateError!void {
    _ = try setNicknameWithStatus(nickname_value);
}

pub fn setNicknameWithStatus(nickname_value: []const u8) UpdateError!MutationResult {
    if (comptime !is_web) return error.Unavailable;
    try mapUpdateResult(js.zigfall_profile_set_nickname(nickname_value.ptr, nickname_value.len));
    return mutationResultFromCurrentCard();
}

pub fn applyVerifiedResult(result: VerifiedResult, opponent_rating: Rating) UpdateError!ProfileCard {
    return (try applyVerifiedResultWithStatus(result, opponent_rating)).card;
}

pub fn applyVerifiedResultWithStatus(result: VerifiedResult, opponent_rating: Rating) UpdateError!MutationResult {
    if (comptime !is_web) return error.Unavailable;
    try mapUpdateResult(js.zigfall_profile_apply_verified_result(@intFromEnum(result), @intCast(opponent_rating)));
    return mutationResultFromCurrentCard();
}

fn mutationResultFromCurrentCard() UpdateError!MutationResult {
    const card = loadCard() catch return error.Unavailable;
    return .{
        .card = card,
        .status = status(),
    };
}

fn readPlayerId(out: []u8) ReadError![]const u8 {
    const result = js.zigfall_profile_player_id(out.ptr, out.len);
    if (result < 0) return mapReadError(@intCast(-result));
    return checkedSlice(out, result) catch error.BufferTooSmall;
}

fn readNickname(out: []u8) ReadError![]const u8 {
    const result = js.zigfall_profile_nickname(out.ptr, out.len);
    if (result < 0) return mapReadError(@intCast(-result));
    return checkedSlice(out, result) catch error.BufferTooSmall;
}

fn copyInto(out: []u8, value: []const u8) ReadError![]const u8 {
    if (value.len > out.len) return error.BufferTooSmall;
    @memcpy(out[0..value.len], value);
    return out[0..value.len];
}

fn checkedSlice(out: []u8, result: i32) error{BufferTooSmall}![]const u8 {
    const len: usize = @intCast(result);
    if (len > out.len) return error.BufferTooSmall;
    return out[0..len];
}

fn mapReadError(code: u8) ReadError {
    return switch (enumFromCode(ErrorCode, code) orelse .missing_js) {
        .missing_js => error.MissingJs,
        .buffer_too_small => error.BufferTooSmall,
        else => error.Unavailable,
    };
}

fn mapUpdateResult(code: u8) UpdateError!void {
    return switch (enumFromCode(ErrorCode, code) orelse .missing_js) {
        .none => {},
        .missing_js => error.MissingJs,
        .storage_unavailable => error.StorageUnavailable,
        .storage_failed => error.StorageFailed,
        .crypto_unavailable => error.CryptoUnavailable,
        .bad_nickname => error.BadNickname,
        .bad_result => error.BadResult,
        .bad_rating => error.BadRating,
        .profile_too_large => error.ProfileTooLarge,
        .unavailable, .buffer_too_small => error.Unavailable,
    };
}

fn enumFromCode(comptime Enum: type, code: u8) ?Enum {
    return std.enums.fromInt(Enum, code);
}

const js = if (is_web) struct {
    extern fn zigfall_profile_status() u8;
    extern fn zigfall_profile_last_error(out_ptr: [*]u8, out_cap: usize) i32;
    extern fn zigfall_profile_player_id(out_ptr: [*]u8, out_cap: usize) i32;
    extern fn zigfall_profile_nickname(out_ptr: [*]u8, out_cap: usize) i32;
    extern fn zigfall_profile_rating() i32;
    extern fn zigfall_profile_wins() u32;
    extern fn zigfall_profile_losses() u32;
    extern fn zigfall_profile_draws() u32;
    extern fn zigfall_profile_set_nickname(nickname_ptr: [*]const u8, nickname_len: usize) u8;
    extern fn zigfall_profile_apply_verified_result(result_code: u8, opponent_rating: i32) u8;
} else struct {};

test "native profile stubs expose safe defaults without browser JS" {
    if (is_web) return error.SkipZigTest;

    try std.testing.expectEqual(Status.unavailable, status());

    const card = try loadCard();
    try std.testing.expectEqualStrings(profile.DefaultPlayerId, card.playerId());
    try std.testing.expectEqualStrings(profile.DefaultNickname, card.nicknameText());
    try std.testing.expectEqual(profile.DefaultRating, card.rating);
    try std.testing.expectEqual(@as(u32, 0), card.wins);
    try std.testing.expectEqual(@as(u32, 0), card.losses);
    try std.testing.expectEqual(@as(u32, 0), card.draws);

    var id_buf: [MaxPlayerIdBytes]u8 = undefined;
    try std.testing.expectEqualStrings(profile.DefaultPlayerId, try playerId(&id_buf));
    var nick_buf: [MaxNicknameBytes]u8 = undefined;
    try std.testing.expectEqualStrings(profile.DefaultNickname, try nickname(&nick_buf));
}

test "native profile stubs report unavailable for browser-only mutation" {
    if (is_web) return error.SkipZigTest;

    try std.testing.expectError(error.Unavailable, setNickname("Ada"));
    try std.testing.expectError(error.Unavailable, setNicknameWithStatus("Ada"));
    try std.testing.expectError(error.Unavailable, applyVerifiedResult(.win, profile.DefaultRating));
    try std.testing.expectError(error.Unavailable, applyVerifiedResultWithStatus(.win, profile.DefaultRating));
}

test "profile wrapper copies strings into caller-owned buffers" {
    if (is_web) return error.SkipZigTest;

    var tiny: [3]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, playerId(&tiny));
    try std.testing.expectError(error.BufferTooSmall, nickname(&tiny));

    var error_buf: [MaxErrorMessageBytes]u8 = undefined;
    const message = try lastErrorMessage(&error_buf);
    try std.testing.expectEqualStrings(native_unavailable_message, message);

    var tiny_error_buf: [4]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, lastErrorMessage(&tiny_error_buf));
}

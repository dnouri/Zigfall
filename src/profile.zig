// SPDX-License-Identifier: GPL-3.0-or-later

//! Pure local profile card and rating policy.
//!
//! This module is intentionally browser-free and raylib-free. Profile cards are
//! display-only metadata: callers must not feed player IDs, nicknames, ratings,
//! or stats into deterministic match seeds, slots, state hashes, result
//! authority, or lockstep state. Rating/stat mutation is exposed only through a
//! verified completed-result helper; disconnects, desyncs, and unverified results
//! have no result variant here.

const std = @import("std");

pub const DefaultNickname = "Player";
pub const DefaultPlayerId = "anonymous";

pub const MaxNicknameBytes: usize = 24;
pub const MaxPlayerIdBytes: usize = 64;
/// Kept well below the current protocol packet cap for a later display-only
/// profile-card exchange. This module does not import protocol to stay pure and
/// reusable in browser storage tests.
pub const MaxSerializedCardBytes: usize = 256;

pub const MinRating: Rating = 0;
pub const MaxRating: Rating = 4000;
pub const DefaultRating: Rating = 1000;
pub const KFactor: i32 = 32;

pub const Rating = u16;

pub const ProfileError = error{
    InvalidPlayerId,
    BufferTooSmall,
};

pub const VerifiedResult = enum(u8) {
    win = 1,
    loss = 2,
    draw = 3,

    pub fn score(self: VerifiedResult) f64 {
        return switch (self) {
            .win => 1.0,
            .loss => 0.0,
            .draw => 0.5,
        };
    }
};

pub const ProfileCard = struct {
    player_id: [MaxPlayerIdBytes]u8 = padded(MaxPlayerIdBytes, DefaultPlayerId),
    player_id_len: usize = DefaultPlayerId.len,
    nickname: [MaxNicknameBytes]u8 = padded(MaxNicknameBytes, DefaultNickname),
    nickname_len: usize = DefaultNickname.len,
    /// Browser-local display rating. It is not a trusted ranking or match input.
    rating: Rating = DefaultRating,
    wins: u32 = 0,
    losses: u32 = 0,
    draws: u32 = 0,

    pub fn default() ProfileCard {
        return .{};
    }

    pub fn init(player_id: []const u8, nickname: []const u8) ProfileError!ProfileCard {
        var card = ProfileCard.default();
        try card.setPlayerId(player_id);
        try card.setNickname(nickname);
        return card;
    }

    pub fn playerId(self: *const ProfileCard) []const u8 {
        return self.player_id[0..self.player_id_len];
    }

    pub fn nicknameText(self: *const ProfileCard) []const u8 {
        return self.nickname[0..self.nickname_len];
    }

    pub fn setPlayerId(self: *ProfileCard, player_id: []const u8) ProfileError!void {
        if (!isValidPlayerId(player_id)) return error.InvalidPlayerId;
        @memset(self.player_id[0..], 0);
        @memcpy(self.player_id[0..player_id.len], player_id);
        self.player_id_len = player_id.len;
    }

    pub fn setNickname(self: *ProfileCard, nickname: []const u8) ProfileError!void {
        var sanitized: [MaxNicknameBytes]u8 = undefined;
        const text = try sanitizeNickname(nickname, &sanitized);
        @memset(self.nickname[0..], 0);
        @memcpy(self.nickname[0..text.len], text);
        self.nickname_len = text.len;
    }

    pub fn setRatingClamped(self: *ProfileCard, value: i32) void {
        self.rating = clampRating(value);
    }

    pub fn applyVerifiedResult(self: *ProfileCard, opponent_rating: Rating, result: VerifiedResult) void {
        self.rating = updatedRating(self.rating, opponent_rating, result);
        switch (result) {
            .win => incrementStat(&self.wins),
            .loss => incrementStat(&self.losses),
            .draw => incrementStat(&self.draws),
        }
    }
};

pub fn isValidPlayerId(player_id: []const u8) bool {
    if (player_id.len == 0 or player_id.len > MaxPlayerIdBytes) return false;
    for (player_id) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-' => {},
            else => return false,
        }
    }
    return true;
}

pub fn sanitizeNickname(input: []const u8, out: []u8) ProfileError![]const u8 {
    if (out.len < MaxNicknameBytes) return error.BufferTooSmall;

    var len: usize = 0;
    var pending_space = false;
    for (input) |byte| {
        if (isAsciiWhitespace(byte)) {
            if (len > 0) pending_space = true;
            continue;
        }
        if (!isNicknameByteAllowed(byte)) continue;

        if (pending_space) {
            if (len >= MaxNicknameBytes) break;
            out[len] = ' ';
            len += 1;
            pending_space = false;
        }
        if (len >= MaxNicknameBytes) break;
        out[len] = byte;
        len += 1;
    }

    while (len > 0 and out[len - 1] == ' ') len -= 1;
    if (len == 0) {
        @memcpy(out[0..DefaultNickname.len], DefaultNickname);
        return out[0..DefaultNickname.len];
    }
    return out[0..len];
}

pub fn expectedScore(rating: Rating, opponent_rating: Rating) f64 {
    const rating_f: f64 = @floatFromInt(rating);
    const opponent_f: f64 = @floatFromInt(opponent_rating);
    const exponent = (opponent_f - rating_f) / 400.0;
    return 1.0 / (1.0 + std.math.pow(f64, 10.0, exponent));
}

pub fn ratingDelta(rating: Rating, opponent_rating: Rating, result: VerifiedResult) i32 {
    const raw_delta = @as(f64, @floatFromInt(KFactor)) * (result.score() - expectedScore(rating, opponent_rating));
    return @intFromFloat(@round(raw_delta));
}

pub fn updatedRating(rating: Rating, opponent_rating: Rating, result: VerifiedResult) Rating {
    return clampRating(@as(i32, rating) + ratingDelta(rating, opponent_rating, result));
}

pub fn clampRating(value: i32) Rating {
    if (value <= MinRating) return MinRating;
    if (value >= MaxRating) return MaxRating;
    return @intCast(value);
}

fn incrementStat(value: *u32) void {
    if (value.* < std.math.maxInt(u32)) value.* += 1;
}

fn isAsciiWhitespace(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c => true,
        else => false,
    };
}

fn isNicknameByteAllowed(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-' => true,
        else => false,
    };
}

fn padded(comptime len: usize, comptime value: []const u8) [len]u8 {
    if (value.len > len) @compileError("default profile string exceeds fixed storage");
    var out = [_]u8{0} ** len;
    @memcpy(out[0..value.len], value);
    return out;
}

test "fresh default profile card values" {
    const card = ProfileCard.default();
    try std.testing.expectEqualStrings(DefaultPlayerId, card.playerId());
    try std.testing.expectEqualStrings(DefaultNickname, card.nicknameText());
    try std.testing.expectEqual(DefaultRating, card.rating);
    try std.testing.expectEqual(@as(u32, 0), card.wins);
    try std.testing.expectEqual(@as(u32, 0), card.losses);
    try std.testing.expectEqual(@as(u32, 0), card.draws);
}

test "equal-rating win and loss move rating by half the K factor" {
    var winner = ProfileCard.default();
    winner.applyVerifiedResult(DefaultRating, .win);
    try std.testing.expectEqual(@as(Rating, DefaultRating + 16), winner.rating);
    try std.testing.expectEqual(@as(u32, 1), winner.wins);
    try std.testing.expectEqual(@as(u32, 0), winner.losses);
    try std.testing.expectEqual(@as(u32, 0), winner.draws);

    var loser = ProfileCard.default();
    loser.applyVerifiedResult(DefaultRating, .loss);
    try std.testing.expectEqual(@as(Rating, DefaultRating - 16), loser.rating);
    try std.testing.expectEqual(@as(u32, 0), loser.wins);
    try std.testing.expectEqual(@as(u32, 1), loser.losses);
    try std.testing.expectEqual(@as(u32, 0), loser.draws);
}

test "draws use half score and update only draw stats" {
    var equal = ProfileCard.default();
    equal.applyVerifiedResult(DefaultRating, .draw);
    try std.testing.expectEqual(DefaultRating, equal.rating);
    try std.testing.expectEqual(@as(u32, 0), equal.wins);
    try std.testing.expectEqual(@as(u32, 0), equal.losses);
    try std.testing.expectEqual(@as(u32, 1), equal.draws);

    var underdog = ProfileCard.default();
    underdog.applyVerifiedResult(1200, .draw);
    try std.testing.expectEqual(@as(Rating, 1008), underdog.rating);
    try std.testing.expectEqual(@as(u32, 1), underdog.draws);
}

test "rating updates clamp to explicit local rating bounds" {
    var high = ProfileCard.default();
    high.rating = 3995;
    high.applyVerifiedResult(4000, .win);
    try std.testing.expectEqual(MaxRating, high.rating);
    try std.testing.expectEqual(@as(u32, 1), high.wins);

    var low = ProfileCard.default();
    low.rating = 5;
    low.applyVerifiedResult(0, .loss);
    try std.testing.expectEqual(MinRating, low.rating);
    try std.testing.expectEqual(@as(u32, 1), low.losses);
}

test "verified result helper increments exactly one stat per call" {
    var win_card = ProfileCard.default();
    win_card.applyVerifiedResult(DefaultRating, .win);
    try std.testing.expectEqual(@as(u32, 1), win_card.wins);
    try std.testing.expectEqual(@as(u32, 0), win_card.losses);
    try std.testing.expectEqual(@as(u32, 0), win_card.draws);

    var loss_card = ProfileCard.default();
    loss_card.applyVerifiedResult(DefaultRating, .loss);
    try std.testing.expectEqual(@as(u32, 0), loss_card.wins);
    try std.testing.expectEqual(@as(u32, 1), loss_card.losses);
    try std.testing.expectEqual(@as(u32, 0), loss_card.draws);

    var draw_card = ProfileCard.default();
    draw_card.applyVerifiedResult(DefaultRating, .draw);
    try std.testing.expectEqual(@as(u32, 0), draw_card.wins);
    try std.testing.expectEqual(@as(u32, 0), draw_card.losses);
    try std.testing.expectEqual(@as(u32, 1), draw_card.draws);
}

test "only verified gameplay outcomes are modeled for stat updates" {
    try std.testing.expectEqual(@as(usize, 3), std.meta.fields(VerifiedResult).len);
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(VerifiedResult.win));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(VerifiedResult.loss));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(VerifiedResult.draw));
}

test "nickname and player-id helpers bound display metadata" {
    try std.testing.expect(isValidPlayerId("abc-XYZ_09.uh-oh"));
    try std.testing.expect(!isValidPlayerId(""));
    try std.testing.expect(!isValidPlayerId("bad id"));
    try std.testing.expect(!isValidPlayerId("../id"));

    var too_long = [_]u8{'a'} ** (MaxPlayerIdBytes + 1);
    try std.testing.expect(!isValidPlayerId(&too_long));

    var out: [MaxNicknameBytes]u8 = undefined;
    try std.testing.expectEqualStrings("Ada Lovelace._-", try sanitizeNickname(" \tAda\nLovelace\xe2\x80\xae._-!!! ", &out));
    try std.testing.expectEqualStrings(DefaultNickname, try sanitizeNickname("\x00\x1f\xe2\x80\xae", &out));
    try std.testing.expectEqual(@as(usize, MaxNicknameBytes), (try sanitizeNickname("ABCDEFGHIJKLMNOPQRSTUVWXYZ", &out)).len);
}

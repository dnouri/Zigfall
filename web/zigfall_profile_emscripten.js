// SPDX-License-Identifier: GPL-3.0-or-later

mergeInto(LibraryManager.library, {
  $ZigfallProfileShim: {
    ErrorCode: {
      none: 0,
      missingJs: 1,
      unavailable: 2,
      bufferTooSmall: 3,
      storageUnavailable: 4,
      storageFailed: 5,
      cryptoUnavailable: 6,
      badNickname: 7,
      badResult: 8,
      badRating: 9,
      profileTooLarge: 10,
    },
    Status: {
      unavailable: 0,
      missingJs: 1,
    },
    encoder: null,
    decoder: null,
    profile: function() {
      var profile = globalThis.ZigfallProfile;
      return profile && typeof profile.card === "function" && typeof profile.statusCode === "function" ? profile : null;
    },
    encodeUtf8Into: function(value, outPtr, outCap) {
      if (!this.encoder) this.encoder = new TextEncoder();
      var bytes = this.encoder.encode(String(value));
      if (bytes.byteLength > outCap) return -this.ErrorCode.bufferTooSmall;
      HEAPU8.set(bytes, outPtr);
      return bytes.byteLength;
    },
    decodeUtf8: function(ptr, len) {
      if (!this.decoder) this.decoder = new TextDecoder("utf-8", { fatal: false });
      return this.decoder.decode(HEAPU8.subarray(ptr, ptr + len));
    },
    errorCode: function(err, fallback) {
      return err && Number.isInteger(err.code) ? err.code : fallback;
    },
  },

  zigfall_profile_status__deps: ["$ZigfallProfileShim"],
  zigfall_profile_status: function() {
    var profile = ZigfallProfileShim.profile();
    return profile ? profile.statusCode() : ZigfallProfileShim.Status.missingJs;
  },

  zigfall_profile_last_error__deps: ["$ZigfallProfileShim"],
  zigfall_profile_last_error: function(outPtr, outCap) {
    var profile = ZigfallProfileShim.profile();
    if (!profile) return -ZigfallProfileShim.ErrorCode.missingJs;
    return ZigfallProfileShim.encodeUtf8Into(profile.lastErrorMessage(), outPtr, outCap);
  },

  zigfall_profile_player_id__deps: ["$ZigfallProfileShim"],
  zigfall_profile_player_id: function(outPtr, outCap) {
    var profile = ZigfallProfileShim.profile();
    if (!profile) return -ZigfallProfileShim.ErrorCode.missingJs;
    return ZigfallProfileShim.encodeUtf8Into(profile.card().playerId, outPtr, outCap);
  },

  zigfall_profile_nickname__deps: ["$ZigfallProfileShim"],
  zigfall_profile_nickname: function(outPtr, outCap) {
    var profile = ZigfallProfileShim.profile();
    if (!profile) return -ZigfallProfileShim.ErrorCode.missingJs;
    return ZigfallProfileShim.encodeUtf8Into(profile.card().nickname, outPtr, outCap);
  },

  zigfall_profile_rating__deps: ["$ZigfallProfileShim"],
  zigfall_profile_rating: function() {
    var profile = ZigfallProfileShim.profile();
    if (!profile) return -ZigfallProfileShim.ErrorCode.missingJs;
    var rating = profile.card().rating;
    return Number.isFinite(rating) ? rating : -ZigfallProfileShim.ErrorCode.unavailable;
  },

  zigfall_profile_wins__deps: ["$ZigfallProfileShim"],
  zigfall_profile_wins: function() {
    var profile = ZigfallProfileShim.profile();
    return profile ? (profile.card().wins >>> 0) : 0;
  },

  zigfall_profile_losses__deps: ["$ZigfallProfileShim"],
  zigfall_profile_losses: function() {
    var profile = ZigfallProfileShim.profile();
    return profile ? (profile.card().losses >>> 0) : 0;
  },

  zigfall_profile_draws__deps: ["$ZigfallProfileShim"],
  zigfall_profile_draws: function() {
    var profile = ZigfallProfileShim.profile();
    return profile ? (profile.card().draws >>> 0) : 0;
  },

  zigfall_profile_set_nickname__deps: ["$ZigfallProfileShim"],
  zigfall_profile_set_nickname: function(nicknamePtr, nicknameLen) {
    var profile = ZigfallProfileShim.profile();
    if (!profile) return ZigfallProfileShim.ErrorCode.missingJs;
    try {
      var nickname = ZigfallProfileShim.decodeUtf8(nicknamePtr, nicknameLen);
      profile.setNickname(nickname);
      return ZigfallProfileShim.ErrorCode.none;
    } catch (err) {
      return ZigfallProfileShim.errorCode(err, ZigfallProfileShim.ErrorCode.badNickname);
    }
  },

  zigfall_profile_apply_verified_result__deps: ["$ZigfallProfileShim"],
  zigfall_profile_apply_verified_result: function(resultCode, opponentRating) {
    var profile = ZigfallProfileShim.profile();
    if (!profile) return ZigfallProfileShim.ErrorCode.missingJs;
    if (typeof profile.tryApplyVerifiedResult === "function") {
      return profile.tryApplyVerifiedResult(resultCode, opponentRating);
    }
    try {
      profile.applyVerifiedResult(resultCode, opponentRating);
      return ZigfallProfileShim.ErrorCode.none;
    } catch (err) {
      return ZigfallProfileShim.errorCode(err, ZigfallProfileShim.ErrorCode.unavailable);
    }
  },
});

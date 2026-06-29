// SPDX-License-Identifier: GPL-3.0-or-later

mergeInto(LibraryManager.library, {
  $ZigfallInviteShim: {
    ErrorCode: {
      none: 0,
      missingJs: 1,
      unavailable: 2,
      badRoom: 3,
      bufferTooSmall: 4,
      randomUnavailable: 5,
      urlTooLong: 6,
      copyUnavailable: 7,
      copyFailed: 8,
    },
    CopyStatus: {
      unavailable: 0,
      missingJs: 1,
    },
    encoder: null,
    decoder: null,
    invite: function() {
      var invite = globalThis.ZigfallInvite;
      return invite && typeof invite.createHostRoom === "function" && typeof invite.joinUrl === "function" ? invite : null;
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

  zigfall_invite_initial_join_room__deps: ["$ZigfallInviteShim"],
  zigfall_invite_initial_join_room: function(outPtr, outCap) {
    var invite = ZigfallInviteShim.invite();
    if (!invite) return -ZigfallInviteShim.ErrorCode.missingJs;
    var result = invite.readInitialJoinRoom();
    if (result && result.errorCode && result.errorCode !== ZigfallInviteShim.ErrorCode.none) return -result.errorCode;
    if (!result || !result.roomId) return 0;
    return ZigfallInviteShim.encodeUtf8Into(result.roomId, outPtr, outCap);
  },

  zigfall_invite_create_host_room__deps: ["$ZigfallInviteShim"],
  zigfall_invite_create_host_room: function(outPtr, outCap) {
    var invite = ZigfallInviteShim.invite();
    if (!invite) return -ZigfallInviteShim.ErrorCode.missingJs;
    try {
      return ZigfallInviteShim.encodeUtf8Into(invite.createHostRoom(), outPtr, outCap);
    } catch (err) {
      return -ZigfallInviteShim.errorCode(err, ZigfallInviteShim.ErrorCode.randomUnavailable);
    }
  },

  zigfall_invite_join_url__deps: ["$ZigfallInviteShim"],
  zigfall_invite_join_url: function(roomPtr, roomLen, outPtr, outCap) {
    var invite = ZigfallInviteShim.invite();
    if (!invite) return -ZigfallInviteShim.ErrorCode.missingJs;
    try {
      var roomId = ZigfallInviteShim.decodeUtf8(roomPtr, roomLen);
      return ZigfallInviteShim.encodeUtf8Into(invite.joinUrl(roomId), outPtr, outCap);
    } catch (err) {
      return -ZigfallInviteShim.errorCode(err, ZigfallInviteShim.ErrorCode.unavailable);
    }
  },

  zigfall_invite_request_copy_join_url__deps: ["$ZigfallInviteShim"],
  zigfall_invite_request_copy_join_url: function(roomPtr, roomLen) {
    var invite = ZigfallInviteShim.invite();
    if (!invite) return ZigfallInviteShim.ErrorCode.missingJs;
    var roomId = ZigfallInviteShim.decodeUtf8(roomPtr, roomLen);
    return invite.requestCopyJoinUrl(roomId);
  },

  zigfall_invite_copy_status__deps: ["$ZigfallInviteShim"],
  zigfall_invite_copy_status: function() {
    var invite = ZigfallInviteShim.invite();
    return invite ? invite.copyStatus() : ZigfallInviteShim.CopyStatus.missingJs;
  },
});

// SPDX-License-Identifier: GPL-3.0-or-later

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

async function loadEmscriptenLibrary(path) {
  const code = await readFile(new URL(`../${path}`, import.meta.url), "utf8");
  const heap = new Uint8Array(8192);
  const context = {
    console,
    TextDecoder,
    TextEncoder,
    HEAPU8: heap,
    LibraryManager: { library: {} },
  };
  context.globalThis = context;
  context.mergeInto = (target, source) => {
    Object.assign(target, source);
    for (const [key, value] of Object.entries(source)) {
      if (key.startsWith("$")) context[key.slice(1)] = value;
    }
  };
  vm.createContext(context);
  vm.runInContext(code, context, { filename: path });
  return { context, heap, library: context.LibraryManager.library };
}

function writeUtf8(heap, ptr, value) {
  const bytes = encoder.encode(value);
  heap.set(bytes, ptr);
  return bytes.byteLength;
}

function readUtf8(heap, ptr, len) {
  return decoder.decode(heap.subarray(ptr, ptr + len));
}

function writeBytes(heap, ptr, bytes) {
  heap.set(bytes, ptr);
  return bytes.byteLength;
}

{
  const { context, heap, library } = await loadEmscriptenLibrary("web/zigfall_transport_emscripten.js");

  assert.equal(library.zigfall_transport_status(), 1, "missing transport JS should map to missingJs status");
  assert.equal(library.zigfall_transport_last_error(), 1);
  assert.equal(library.zigfall_transport_health_error(), 1);
  assert.equal(library.zigfall_transport_send(0, 1), 1);
  assert.equal(library.zigfall_transport_send_best_effort(0, 1), 1);
  assert.equal(library.zigfall_transport_poll(512, 16), -1, "poll errors must use Zig's negative error convention");
  assert.equal(library.zigfall_transport_peer_count(), 0);
  assert.equal(library.zigfall_transport_had_peer(), 0);
  assert.equal(library.zigfall_transport_queued_packet_count(), 0);

  let connectedRoom = null;
  let disconnected = false;
  let sent = null;
  let sentBestEffort = null;
  context.ZigfallTransport = {
    statusCode: () => 4,
    errorCode: () => 6,
    healthErrorCode: () => 8,
    connect(roomId) {
      connectedRoom = roomId;
      return 0;
    },
    disconnect() {
      disconnected = true;
    },
    send(packet) {
      sent = Array.from(packet);
      return 0;
    },
    sendBestEffort(packet) {
      sentBestEffort = Array.from(packet);
      return 0;
    },
    pollInto(heapU8, outPtr, outCap) {
      assert.equal(outCap, 3);
      heapU8.set([9, 8, 7], outPtr);
      return 3;
    },
    peerCount: () => 2,
    hadPeer: () => true,
    queuedPacketCount: () => 257,
  };

  const roomLen = writeUtf8(heap, 16, "room-✓");
  assert.equal(library.zigfall_transport_connect(16, roomLen), 0);
  assert.equal(connectedRoom, "room-✓");
  assert.equal(library.zigfall_transport_status(), 4);
  assert.equal(library.zigfall_transport_last_error(), 6);
  assert.equal(library.zigfall_transport_health_error(), 8);

  writeBytes(heap, 64, [1, 2, 3, 4]);
  assert.equal(library.zigfall_transport_send(64, 4), 0);
  heap[64] = 99;
  assert.deepEqual(sent, [1, 2, 3, 4], "transport shim must copy packet bytes out of WASM memory before sending");

  writeBytes(heap, 80, [5, 6]);
  assert.equal(library.zigfall_transport_send_best_effort(80, 2), 0);
  assert.deepEqual(sentBestEffort, [5, 6]);

  assert.equal(library.zigfall_transport_poll(128, 3), 3);
  assert.deepEqual(Array.from(heap.subarray(128, 131)), [9, 8, 7]);
  assert.equal(library.zigfall_transport_peer_count(), 2);
  assert.equal(library.zigfall_transport_had_peer(), 1);
  assert.equal(library.zigfall_transport_queued_packet_count(), 257);
  library.zigfall_transport_disconnect();
  assert.equal(disconnected, true);

  delete context.ZigfallTransport.sendBestEffort;
  assert.equal(library.zigfall_transport_send_best_effort(80, 2), 1, "missing best-effort bridge should fail closed");
}

{
  const { context, heap, library } = await loadEmscriptenLibrary("web/zigfall_invite_emscripten.js");

  assert.equal(library.zigfall_invite_initial_join_room(0, 16), -1);
  assert.equal(library.zigfall_invite_create_host_room(0, 16), -1);
  assert.equal(library.zigfall_invite_join_url(0, 0, 64, 16), -1);
  assert.equal(library.zigfall_invite_request_copy_join_url(0, 0), 1);
  assert.equal(library.zigfall_invite_copy_status(), 1);

  let copiedRoom = null;
  context.ZigfallInvite = {
    readInitialJoinRoom: () => ({ roomId: "join-room", errorCode: 0 }),
    createHostRoom: () => "host-room",
    joinUrl(roomId) {
      return `https://example.test/play?join=${roomId}`;
    },
    requestCopyJoinUrl(roomId) {
      copiedRoom = roomId;
      return 0;
    },
    copyStatus: () => 4,
  };

  assert.equal(library.zigfall_invite_initial_join_room(128, 32), "join-room".length);
  assert.equal(readUtf8(heap, 128, "join-room".length), "join-room");
  assert.equal(library.zigfall_invite_initial_join_room(128, 4), -4, "string writes must report negative bufferTooSmall");

  assert.equal(library.zigfall_invite_create_host_room(160, 32), "host-room".length);
  assert.equal(readUtf8(heap, 160, "host-room".length), "host-room");

  const roomLen = writeUtf8(heap, 192, "room-42");
  const urlLen = library.zigfall_invite_join_url(192, roomLen, 256, 128);
  assert.equal(readUtf8(heap, 256, urlLen), "https://example.test/play?join=room-42");

  assert.equal(library.zigfall_invite_request_copy_join_url(192, roomLen), 0);
  assert.equal(copiedRoom, "room-42");
  assert.equal(library.zigfall_invite_copy_status(), 4);

  context.ZigfallInvite.readInitialJoinRoom = () => ({ roomId: null, errorCode: 3 });
  assert.equal(library.zigfall_invite_initial_join_room(128, 32), -3);
  context.ZigfallInvite.createHostRoom = () => {
    const err = new Error("no random");
    err.code = 5;
    throw err;
  };
  assert.equal(library.zigfall_invite_create_host_room(160, 32), -5);
  context.ZigfallInvite.joinUrl = () => {
    const err = new Error("too long");
    err.code = 6;
    throw err;
  };
  assert.equal(library.zigfall_invite_join_url(192, roomLen, 256, 128), -6);
}

{
  const { context, heap, library } = await loadEmscriptenLibrary("web/zigfall_profile_emscripten.js");

  assert.equal(library.zigfall_profile_status(), 1);
  assert.equal(library.zigfall_profile_last_error(0, 32), -1);
  assert.equal(library.zigfall_profile_player_id(0, 32), -1);
  assert.equal(library.zigfall_profile_nickname(0, 32), -1);
  assert.equal(library.zigfall_profile_rating(), -1);
  assert.equal(library.zigfall_profile_wins(), 0);
  assert.equal(library.zigfall_profile_losses(), 0);
  assert.equal(library.zigfall_profile_draws(), 0);
  assert.equal(library.zigfall_profile_set_nickname(0, 0), 1);
  assert.equal(library.zigfall_profile_apply_verified_result(1, 1000), 1);

  let nicknameSet = null;
  let applied = null;
  const card = {
    playerId: "player-1",
    nickname: "Ada",
    rating: 1234,
    wins: 1,
    losses: 2,
    draws: 3,
  };
  context.ZigfallProfile = {
    statusCode: () => 2,
    lastErrorMessage: () => "all good",
    card: () => card,
    setNickname(value) {
      nicknameSet = value;
    },
    tryApplyVerifiedResult(resultCode, opponentRating) {
      applied = [resultCode, opponentRating];
      return 0;
    },
  };

  assert.equal(library.zigfall_profile_status(), 2);
  assert.equal(library.zigfall_profile_last_error(320, 32), "all good".length);
  assert.equal(readUtf8(heap, 320, "all good".length), "all good");
  assert.equal(library.zigfall_profile_player_id(352, 32), "player-1".length);
  assert.equal(readUtf8(heap, 352, "player-1".length), "player-1");
  assert.equal(library.zigfall_profile_nickname(384, 32), "Ada".length);
  assert.equal(readUtf8(heap, 384, "Ada".length), "Ada");
  assert.equal(library.zigfall_profile_nickname(384, 2), -3);
  assert.equal(library.zigfall_profile_rating(), 1234);
  assert.equal(library.zigfall_profile_wins(), 1);
  assert.equal(library.zigfall_profile_losses(), 2);
  assert.equal(library.zigfall_profile_draws(), 3);

  const nicknameLen = writeUtf8(heap, 416, "Grace Hopper");
  assert.equal(library.zigfall_profile_set_nickname(416, nicknameLen), 0);
  assert.equal(nicknameSet, "Grace Hopper");
  assert.equal(library.zigfall_profile_apply_verified_result(1, 1400), 0);
  assert.deepEqual(applied, [1, 1400]);

  card.rating = Number.NaN;
  assert.equal(library.zigfall_profile_rating(), -2, "non-finite ratings must use Zig's negative error convention");
  context.ZigfallProfile.setNickname = () => {
    const err = new Error("bad nick");
    err.code = 7;
    throw err;
  };
  assert.equal(library.zigfall_profile_set_nickname(416, nicknameLen), 7);

  delete context.ZigfallProfile.tryApplyVerifiedResult;
  context.ZigfallProfile.applyVerifiedResult = () => {
    const err = new Error("bad result");
    err.code = 8;
    throw err;
  };
  assert.equal(library.zigfall_profile_apply_verified_result(9, 1400), 8);
}

console.log("ok: Emscripten shims bridge transport, invite, and profile globals with Zig-compatible copies and error codes");

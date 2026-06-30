// SPDX-License-Identifier: GPL-3.0-or-later

import assert from "node:assert/strict";
import { createZigfallTransport, ErrorCode, Status, TrysteroRelayUrls } from "../web/zigfall_transport.mjs";

function makeFakeAction({ sendImpl = null } = {}) {
  return {
    sent: [],
    _onMessage: null,
    get onMessage() {
      return this._onMessage;
    },
    set onMessage(handler) {
      this._onMessage = handler;
    },
    send(data, options = {}) {
      const record = { data: new Uint8Array(data), options };
      this.sent.push(record);
      return sendImpl ? sendImpl(record) : Promise.resolve();
    },
    emit(data, peerId) {
      this._onMessage?.(data, { peerId });
    },
  };
}

function makeFakeJoinRoom({ leaveImpl = () => Promise.resolve(), makeActionImpl = () => makeFakeAction() } = {}) {
  const rooms = [];
  const joinRoomImpl = (config, roomId) => {
    const action = makeActionImpl({ index: rooms.length, roomId });
    const room = {
      config,
      roomId,
      action,
      leaveCalls: 0,
      onPeerJoin: null,
      onPeerLeave: null,
      makeAction(name) {
        assert.equal(name, "pkt");
        return action;
      },
      leave() {
        this.leaveCalls += 1;
        return leaveImpl();
      },
      join(peerId) {
        this.onPeerJoin?.(peerId);
      },
      leavePeer(peerId) {
        this.onPeerLeave?.(peerId);
      },
    };
    rooms.push(room);
    return room;
  };
  return { joinRoomImpl, rooms };
}

{
  const { joinRoomImpl, rooms } = makeFakeJoinRoom();
  const transport = createZigfallTransport({ joinRoomImpl, selfIdValue: "self-test" });

  assert.equal(transport.connect("adapter-test"), ErrorCode.none);
  const room = rooms[0];
  const action = room.action;
  assert.equal(room.config.appId, "zigfall-trystero-v2", "transport app namespace must isolate protocol v2 clients");
  assert.equal(room.config.relayConfig.urls, TrysteroRelayUrls, "transport must pass the curated Nostr relay list to Trystero");
  assert.deepEqual(TrysteroRelayUrls, [
    "wss://nostr.sathoarder.com",
    "wss://nostr.vulpem.com",
    "wss://relay.libernet.app",
    "wss://nostr.data.haus",
    "wss://strfry.shock.network",
  ]);
  assert.equal(Object.isFrozen(TrysteroRelayUrls), true, "relay list should remain centralized and immutable");
  assert.equal(transport.ProtocolVersion, 2, "transport profile fast-path must track the Zig wire protocol version");

  room.join("peer-a");
  assert.equal(transport.statusCode(), Status.connected);
  assert.equal(transport.selectedPeerId(), "peer-a");
  assert.equal(transport.extraPeerCount(), 0);

  assert.equal(transport.send(Uint8Array.from([1, 2, 3])), ErrorCode.none);
  assert.equal(action.sent.length, 1);
  assert.equal(action.sent[0].options.target, "peer-a", "send should target the selected peer, not broadcast");
  assert.deepEqual(Array.from(action.sent[0].data), [1, 2, 3]);

  room.join("peer-b");
  assert.equal(transport.statusCode(), Status.busy, "extra peers should surface a busy state");
  assert.equal(transport.errorCode(), ErrorCode.busy);
  assert.equal(transport.peerCount(), 2);
  assert.equal(transport.extraPeerCount(), 1);

  action.emit(Uint8Array.from([9]), "peer-b");
  assert.equal(transport.queuedPacketCount(), 0, "non-selected peers must not be able to inject packets");

  action.emit(Uint8Array.from([7, 8]), "peer-a");
  assert.equal(transport.queuedPacketCount(), 1);
  assert.deepEqual(Array.from(transport.poll()), [7, 8]);

  assert.equal(transport.send(Uint8Array.from([4])), ErrorCode.none);
  assert.equal(action.sent.at(-1).options.target, "peer-a", "extra peers must not change the target");

  action.emit(Uint8Array.from([10]), "peer-a");
  room.leavePeer("peer-a");
  assert.equal(transport.selectedPeerId(), null);
  assert.equal(transport.statusCode(), Status.busy, "remaining non-selected peers keep the room busy, not connected");
  assert.equal(transport.queuedPacketCount(), 1, "selected peer packets queued before leave should remain pollable");
  assert.deepEqual(Array.from(transport.poll()), [10]);
  assert.equal(transport.send(Uint8Array.from([5])), ErrorCode.noPeer);

  action.emit(Uint8Array.from([6]), "peer-b");
  assert.equal(transport.queuedPacketCount(), 0, "a previously extra peer is not auto-promoted after the selected peer leaves");
}

{
  const warnings = [];
  const originalWarn = console.warn;
  console.warn = (...args) => warnings.push(args);
  try {
    const { joinRoomImpl, rooms } = makeFakeJoinRoom({ leaveImpl: () => Promise.reject(new Error("leave failed")) });
    const transport = createZigfallTransport({ joinRoomImpl, selfIdValue: "self-test" });

    assert.equal(transport.connect("disconnect-test"), ErrorCode.none);
    const room = rooms[0];
    const action = room.action;
    room.join("peer-a");
    assert.equal(transport.statusCode(), Status.connected);

    transport.disconnect();
    assert.equal(room.leaveCalls, 1);
    assert.equal(typeof action.onMessage, "function", "disconnect should leave a no-op handler installed");
    action.emit(Uint8Array.from([1, 2, 3]), "peer-a");
    assert.equal(transport.queuedPacketCount(), 0, "late messages from the old room generation are drained");
    assert.equal(transport.statusCode(), Status.disconnected);

    await Promise.resolve();
    assert.equal(warnings.length, 1, "async leave rejection should be caught and logged");
  } finally {
    console.warn = originalWarn;
  }
}

{
  let now = 1_000;
  const { joinRoomImpl, rooms } = makeFakeJoinRoom();
  const transport = createZigfallTransport({ joinRoomImpl, selfIdValue: "self-test", nowImpl: () => now });

  assert.equal(transport.connect("late-final-room"), ErrorCode.none);
  const room = rooms[0];
  const action = room.action;
  room.join("peer-a");
  room.join("peer-b");

  room.leavePeer("peer-a");
  assert.equal(transport.selectedPeerId(), null);
  assert.equal(transport.errorCode(), ErrorCode.noPeer);
  assert.equal(transport.statusCode(), Status.busy);

  action.emit(Uint8Array.from([0x41]), "peer-a");
  assert.equal(transport.queuedPacketCount(), 1, "selected peer's final packet should survive leave-before-message callback ordering");
  action.emit(Uint8Array.from([0x42]), "peer-b");
  assert.equal(transport.queuedPacketCount(), 1, "extra peers must remain rejected during the retiring-peer drain");
  assert.deepEqual(Array.from(transport.poll()), [0x41]);

  now += transport.RetiringSelectedPeerDrainMs + 1;
  action.emit(Uint8Array.from([0x43]), "peer-a");
  assert.equal(transport.queuedPacketCount(), 0, "retiring selected peer acceptance must be bounded");

  assert.equal(transport.connect("late-final-new-room"), ErrorCode.none);
  rooms[1].join("peer-c");
  action.emit(Uint8Array.from([0x44]), "peer-a");
  assert.equal(transport.queuedPacketCount(), 0, "retiring peers from a prior room generation must not leak into a new room");
  assert.equal(transport.statusCode(), Status.connected);
  assert.equal(transport.selectedPeerId(), "peer-c");
}

{
  let now = 5_000;
  const { joinRoomImpl, rooms } = makeFakeJoinRoom();
  const transport = createZigfallTransport({ joinRoomImpl, selfIdValue: "self-test", nowImpl: () => now });

  assert.equal(transport.connect("expired-late-room"), ErrorCode.none);
  rooms[0].join("peer-a");
  rooms[0].leavePeer("peer-a");
  now += transport.RetiringSelectedPeerDrainMs + 1;
  rooms[0].action.emit(Uint8Array.from([0x45]), "peer-a");
  assert.equal(transport.errorCode(), ErrorCode.noPeer, "expired late packets from the departed selected peer must not mask noPeer as busy");
  assert.equal(transport.statusCode(), Status.connecting);
}

{
  let now = 8_000;
  const { joinRoomImpl, rooms } = makeFakeJoinRoom();
  const transport = createZigfallTransport({ joinRoomImpl, selfIdValue: "self-test", nowImpl: () => now });

  assert.equal(transport.connect("extra-churn-after-leave"), ErrorCode.none);
  const room = rooms[0];
  room.join("peer-a");
  room.leavePeer("peer-a");
  room.join("peer-b");
  assert.equal(transport.statusCode(), Status.busy);
  assert.equal(transport.errorCode(), ErrorCode.busy);
  room.leavePeer("peer-b");
  assert.equal(transport.selectedPeerId(), null);
  assert.equal(transport.statusCode(), Status.connecting);
  assert.equal(transport.errorCode(), ErrorCode.noPeer, "extra-peer churn after selected leave must not erase the peer-leave signal");
  room.action.emit(Uint8Array.from([0x46]), "peer-a");
  assert.deepEqual(Array.from(transport.poll()), [0x46], "retiring selected peer drain should survive extra-peer churn");
  now += transport.RetiringSelectedPeerDrainMs + 1;
  room.action.emit(Uint8Array.from([0x47]), "peer-a");
  assert.equal(transport.queuedPacketCount(), 0, "retiring selected peer drain remains bounded after extra-peer churn");
  assert.equal(transport.errorCode(), ErrorCode.noPeer);
}

{
  const { joinRoomImpl, rooms } = makeFakeJoinRoom();
  const transport = createZigfallTransport({ joinRoomImpl, selfIdValue: "self-test" });

  assert.equal(transport.connect("profile-burst-test"), ErrorCode.none);
  rooms[0].join("peer-a");
  for (let i = 0; i < transport.MaxQueuedPackets; i += 1) {
    rooms[0].action.emit(Uint8Array.from([transport.ProtocolVersion, transport.ProfilePacketType, i & 0xff]), "peer-a");
  }
  assert.equal(transport.errorCode(), ErrorCode.none, "profile metadata bursts must not poison the shared gameplay queue");
  assert.equal(transport.queuedPacketCount(), 1, "at most one optional profile packet should be pending");
  rooms[0].action.emit(Uint8Array.from([2, 0]), "peer-a");
  assert.equal(transport.errorCode(), ErrorCode.none, "gameplay packet after a profile burst should still be accepted");
  assert.equal(transport.queuedPacketCount(), 2);
}

{
  const { joinRoomImpl, rooms } = makeFakeJoinRoom();
  const transport = createZigfallTransport({ joinRoomImpl, selfIdValue: "self-test" });

  assert.equal(transport.connect("profile-eviction-test"), ErrorCode.none);
  rooms[0].join("peer-a");
  for (let i = 0; i < transport.MaxQueuedPackets - 1; i += 1) {
    rooms[0].action.emit(Uint8Array.from([0x20, i & 0xff]), "peer-a");
  }
  rooms[0].action.emit(Uint8Array.from([transport.ProtocolVersion, transport.ProfilePacketType, 0xaa]), "peer-a");
  assert.equal(transport.queuedPacketCount(), transport.MaxQueuedPackets);
  rooms[0].action.emit(Uint8Array.from([0x21]), "peer-a");
  assert.equal(transport.errorCode(), ErrorCode.none, "optional profile should be evicted before reporting gameplay queue overflow");
  assert.equal(transport.queuedPacketCount(), transport.MaxQueuedPackets);
  rooms[0].action.emit(Uint8Array.from([0x22]), "peer-a");
  assert.equal(transport.errorCode(), ErrorCode.queueFull, "overflow remains fatal when the full queue has no optional profile to evict");
}

{
  const { joinRoomImpl, rooms } = makeFakeJoinRoom();
  const transport = createZigfallTransport({ joinRoomImpl, selfIdValue: "self-test" });

  assert.equal(transport.MaxQueuedPackets, 256, "inbound queue should allow bounded burst drain headroom");
  assert.equal(transport.connect("queue-test"), ErrorCode.none);
  const room = rooms[0];
  const action = room.action;
  room.join("peer-a");

  for (let i = 0; i < transport.MaxQueuedPackets; i += 1) {
    action.emit(Uint8Array.from([i & 0xff]), "peer-a");
  }
  assert.equal(transport.queuedPacketCount(), transport.MaxQueuedPackets);
  action.emit(Uint8Array.from([transport.ProtocolVersion, transport.ProfilePacketType]), "peer-a");
  assert.equal(transport.errorCode(), ErrorCode.none, "optional profile metadata overflow must not poison gameplay health");
  assert.equal(transport.queuedPacketCount(), transport.MaxQueuedPackets, "profile overflow should not grow the bounded queue");
  action.emit(Uint8Array.from([0xee]), "peer-a");
  assert.equal(transport.errorCode(), ErrorCode.queueFull);
  assert.equal(transport.queuedPacketCount(), transport.MaxQueuedPackets, "overflow should not grow the bounded queue");
}

{
  const { joinRoomImpl, rooms } = makeFakeJoinRoom();
  const transport = createZigfallTransport({ joinRoomImpl, selfIdValue: "self-test" });

  assert.equal(transport.connect("oversize-test"), ErrorCode.none);
  const room = rooms[0];
  room.join("peer-a");

  const oversizedProfile = new Uint8Array(transport.MaxPacketSize + 1);
  oversizedProfile[0] = transport.ProtocolVersion;
  oversizedProfile[1] = transport.ProfilePacketType;
  room.action.emit(oversizedProfile, "peer-a");
  assert.equal(transport.errorCode(), ErrorCode.none, "oversized profile metadata must be dropped without poisoning gameplay health");
  assert.equal(transport.queuedPacketCount(), 0, "oversized profile metadata is not queued");

  room.action.emit(new Uint8Array(transport.MaxPacketSize + 1), "peer-a");
  assert.equal(transport.errorCode(), ErrorCode.packetTooLarge, "oversized selected-peer gameplay/lifecycle packets must be terminal to Zig");
  assert.equal(transport.queuedPacketCount(), 0, "oversized packets are dropped rather than queued");
}

{
  let rejectOldSend;
  const warnings = [];
  const originalWarn = console.warn;
  console.warn = (...args) => warnings.push(args);
  try {
    const { joinRoomImpl, rooms } = makeFakeJoinRoom({
      makeActionImpl: ({ index }) => makeFakeAction({
        sendImpl: () => {
          if (index !== 0) return Promise.resolve();
          return new Promise((_, reject) => {
            rejectOldSend = reject;
          });
        },
      }),
    });
    const transport = createZigfallTransport({ joinRoomImpl, selfIdValue: "self-test" });

    assert.equal(transport.connect("old-send-room"), ErrorCode.none);
    rooms[0].join("peer-a");
    assert.equal(transport.send(Uint8Array.from([1])), ErrorCode.none);

    assert.equal(transport.connect("new-send-room"), ErrorCode.none);
    rooms[1].join("peer-b");
    assert.equal(transport.statusCode(), Status.connected);
    assert.equal(transport.errorCode(), ErrorCode.none);

    rejectOldSend(new Error("old room send failed"));
    await Promise.resolve();
    assert.equal(transport.errorCode(), ErrorCode.none, "stale-generation send rejection must not poison the current room");
    assert.equal(transport.statusCode(), Status.connected);
    assert.equal(warnings.length, 0, "stale-generation send rejection should be ignored without warning");
  } finally {
    console.warn = originalWarn;
  }
}

{
  let rejectMetadataSend;
  const warnings = [];
  const originalWarn = console.warn;
  console.warn = (...args) => warnings.push(args);
  try {
    const { joinRoomImpl, rooms } = makeFakeJoinRoom({
      makeActionImpl: () => makeFakeAction({
        sendImpl: () => new Promise((_, reject) => {
          rejectMetadataSend = reject;
        }),
      }),
    });
    const transport = createZigfallTransport({ joinRoomImpl, selfIdValue: "self-test" });

    assert.equal(transport.connect("best-effort-send-room"), ErrorCode.none);
    rooms[0].join("peer-a");
    assert.equal(transport.sendBestEffort(Uint8Array.from([8, 8])), ErrorCode.none);
    rejectMetadataSend(new Error("metadata send failed"));
    await Promise.resolve();
    assert.equal(transport.errorCode(), ErrorCode.none, "best-effort async rejection must not poison transport health");
    assert.equal(transport.statusCode(), Status.connected);
    assert.equal(warnings.length, 1, "best-effort async rejection should be logged only");
  } finally {
    console.warn = originalWarn;
  }
}

{
  let rejectGameplaySend;
  const warnings = [];
  const originalWarn = console.warn;
  console.warn = (...args) => warnings.push(args);
  try {
    const { joinRoomImpl, rooms } = makeFakeJoinRoom({
      makeActionImpl: () => makeFakeAction({
        sendImpl: () => new Promise((_, reject) => {
          rejectGameplaySend = reject;
        }),
      }),
    });
    const transport = createZigfallTransport({ joinRoomImpl, selfIdValue: "self-test" });

    assert.equal(transport.connect("gameplay-send-room"), ErrorCode.none);
    rooms[0].join("peer-a");
    assert.equal(transport.send(Uint8Array.from([2, 3])), ErrorCode.none);
    rejectGameplaySend(new Error("gameplay send failed"));
    await Promise.resolve();
    assert.equal(transport.errorCode(), ErrorCode.sendFailed, "gameplay async rejection remains fatal to Zig");
    assert.equal(warnings.length, 1);
  } finally {
    console.warn = originalWarn;
  }
}

console.log("ok: Zigfall transport adapter selects one peer, targets sends, drops extras, drains late final packets, bounds backlog, scopes async send failures, and keeps best-effort sends nonfatal");

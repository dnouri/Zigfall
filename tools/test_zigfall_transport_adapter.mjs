// SPDX-License-Identifier: GPL-3.0-or-later

import assert from "node:assert/strict";
import { createZigfallTransport, ErrorCode, Status } from "../web/zigfall_transport.mjs";

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

  room.action.emit(new Uint8Array(transport.MaxPacketSize + 1), "peer-a");
  assert.equal(transport.errorCode(), ErrorCode.packetTooLarge, "oversized selected-peer packets must be terminal to Zig");
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

console.log("ok: Zigfall transport adapter selects one peer, targets sends, drops extras, drains disconnects, bounds backlog, and scopes async send failures");

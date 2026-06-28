// SPDX-License-Identifier: GPL-3.0-or-later

import assert from "node:assert/strict";
import { createZigfallTransport, ErrorCode, Status } from "../web/zigfall_transport.mjs";

function makeFakeAction() {
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
      this.sent.push({ data: new Uint8Array(data), options });
      return Promise.resolve();
    },
    emit(data, peerId) {
      this._onMessage?.(data, { peerId });
    },
  };
}

function makeFakeJoinRoom({ leaveImpl = () => Promise.resolve() } = {}) {
  const rooms = [];
  const joinRoomImpl = (config, roomId) => {
    const action = makeFakeAction();
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

  room.leavePeer("peer-a");
  assert.equal(transport.selectedPeerId(), null);
  assert.equal(transport.statusCode(), Status.busy, "remaining non-selected peers keep the room busy, not connected");
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

console.log("ok: Zigfall transport adapter selects one peer, targets sends, drops extras, and drains disconnects");

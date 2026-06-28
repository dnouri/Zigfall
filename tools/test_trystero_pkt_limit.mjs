// SPDX-License-Identifier: GPL-3.0-or-later

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const bundleUrl = new URL("../web/vendor/trystero-nostr.bundle.mjs", import.meta.url);
const source = await readFile(bundleUrl, "utf8");

const exportBlock = "export {\n  joinRoom,\n  selfId\n};";
const instrumented = source.replace(
  exportBlock,
  "export {\n" +
    "  createActionWireManager,\n" +
    "  nonceIndex,\n" +
    "  payloadIndex,\n" +
    "  progressIndex,\n" +
    "  tagIndex,\n" +
    "  typeIndex,\n" +
    "  joinRoom,\n" +
    "  selfId\n" +
    "};",
);

assert.notEqual(instrumented, source, "expected Trystero bundle export block was not found");

const moduleUrl = `data:text/javascript;base64,${Buffer.from(instrumented).toString("base64")}`;
const {
  createActionWireManager,
  nonceIndex,
  payloadIndex,
  progressIndex,
  tagIndex,
  typeIndex,
} = await import(moduleUrl);

const encoder = new TextEncoder();
const peerId = "peer-a";
const actionType = "pkt";
const nonce = 0x1234;
const BinaryTag = 1 << 2;
const LastTag = 1;
const MetaTag = 1 << 1;
const JsonTag = 1 << 3;

function makeManager(deliveries) {
  const manager = createActionWireManager({
    getPeer: () => null,
    getPeerIds: () => [],
    canReceiveFromPeer: () => true,
    throwIfAborted: () => {},
  });
  manager.makeInternalAction(actionType).onMessage((payload, id, metadata) => {
    deliveries.push({ payload, id, metadata });
  });
  return manager;
}

function makeFrame({
  payloadLength = 0,
  isLast = false,
  isMeta = false,
  isBinary = true,
  isJson = false,
  nonceValue = nonce,
  fill = 0x5a,
  payloadBytes = null,
}) {
  const payloadByteLength = payloadBytes === null ? payloadLength : payloadBytes.byteLength;
  const frame = new Uint8Array(payloadIndex + payloadByteLength);
  frame.set(encoder.encode(actionType), typeIndex);
  frame[nonceIndex] = nonceValue >> 8;
  frame[nonceIndex + 1] = nonceValue & 0xff;
  frame[tagIndex] =
    (isBinary ? BinaryTag : 0) |
    (isLast ? LastTag : 0) |
    (isMeta ? MetaTag : 0) |
    (isJson ? JsonTag : 0);
  frame[progressIndex] = isLast ? 255 : 1;
  if (payloadBytes === null) {
    frame.fill(fill, payloadIndex);
  } else {
    frame.set(payloadBytes, payloadIndex);
  }
  return frame;
}

{
  const deliveries = [];
  const manager = makeManager(deliveries);
  manager.handleData(peerId, makeFrame({ payloadLength: 512, isLast: true }));

  assert.equal(deliveries.length, 1, "an exact 512-byte pkt payload should still deliver");
  assert.equal(deliveries[0].id, peerId);
  assert.equal(deliveries[0].payload.byteLength, 512);
  assert.equal(manager.__zigfallTestPendingPayloadBytes(peerId, actionType, nonce), 0);
}

{
  const deliveries = [];
  const manager = makeManager(deliveries);
  manager.handleData(peerId, makeFrame({ payloadLength: 513, isLast: true }));

  assert.equal(deliveries.length, 0, "a single oversize pkt frame should be dropped");
  assert.equal(manager.__zigfallTestPendingPayloadBytes(peerId, actionType, nonce), 0);
}

{
  const deliveries = [];
  const manager = makeManager(deliveries);
  manager.handleData(peerId, makeFrame({ payloadLength: 512 }));
  assert.equal(
    manager.__zigfallTestPendingPayloadBytes(peerId, actionType, nonce),
    512,
    "the cap allows at most protocol.MaxPacketSize bytes to be pending",
  );

  manager.handleData(peerId, makeFrame({ payloadLength: 1 }));
  assert.equal(
    manager.__zigfallTestPendingPayloadBytes(peerId, actionType, nonce),
    0,
    "the first byte beyond the cap should clear pending chunks instead of accumulating",
  );
  manager.handleData(peerId, makeFrame({ payloadLength: 1, isLast: true }));

  assert.equal(deliveries.length, 0, "an oversize multi-chunk pkt payload should never deliver a tail fragment");
  assert.equal(manager.__zigfallTestPendingPayloadBytes(peerId, actionType, nonce), 0);
}

{
  const deliveries = [];
  const manager = makeManager(deliveries);
  assert.doesNotThrow(() => {
    manager.handleData(peerId, makeFrame({ payloadLength: 64, isMeta: true }));
  }, "pkt metadata chunks are unsupported and should be dropped before JSON parsing");
  manager.handleData(peerId, makeFrame({ payloadLength: 16, isLast: true }));

  assert.equal(deliveries.length, 0, "pkt metadata should drop the whole transmission");
  assert.equal(manager.__zigfallTestPendingPayloadBytes(peerId, actionType, nonce), 0);
}

{
  const deliveries = [];
  const manager = makeManager(deliveries);
  const jsonNonce = 0x1235;
  assert.doesNotThrow(() => {
    manager.handleData(
      peerId,
      makeFrame({
        payloadBytes: encoder.encode("not json"),
        isLast: true,
        isBinary: false,
        isJson: true,
        nonceValue: jsonNonce,
      }),
    );
  }, "non-binary pkt frames should be dropped before Trystero JSON parsing");

  assert.equal(deliveries.length, 0, "non-binary pkt frames should not deliver to Zigfall");
  assert.equal(manager.__zigfallTestPendingPayloadBytes(peerId, actionType, jsonNonce), 0);
}

console.log("ok: Trystero pkt reassembly cap drops oversize and non-binary payloads before delivery");

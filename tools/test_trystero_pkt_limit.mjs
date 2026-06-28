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
const controlActionType = "@_signal";
const nonce = 0x1234;
const BinaryTag = 1 << 2;
const LastTag = 1;
const MetaTag = 1 << 1;
const JsonTag = 1 << 3;

function makeManager(deliveries, registeredAction = actionType) {
  const manager = createActionWireManager({
    getPeer: () => null,
    getPeerIds: () => [],
    canReceiveFromPeer: () => true,
    throwIfAborted: () => {},
  });
  manager.makeInternalAction(registeredAction).onMessage((payload, id, metadata) => {
    deliveries.push({ payload, id, metadata });
  });
  return manager;
}

function makeFrame({
  action = actionType,
  payloadLength = 0,
  isLast = false,
  isMeta = false,
  isBinary = true,
  isJson = isBinary,
  nonceValue = nonce,
  fill = 0x5a,
  payloadBytes = null,
}) {
  const actionBytes = encoder.encode(action);
  assert(actionBytes.byteLength <= 32, "test action type must fit Trystero's wire limit");

  const payloadByteLength = payloadBytes === null ? payloadLength : payloadBytes.byteLength;
  const frame = new Uint8Array(payloadIndex + payloadByteLength);
  frame.set(actionBytes, typeIndex);
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
  const frame = makeFrame({ payloadLength: 512, isLast: true });
  assert.equal(Boolean(frame[tagIndex] & JsonTag), true, "typed-array pkt fixtures should carry Trystero's Json bit");
  manager.handleData(peerId, frame);

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
  const chunkedNonce = 0x1236;
  manager.handleData(peerId, makeFrame({ payloadLength: 512, nonceValue: chunkedNonce }));

  assert.equal(deliveries.length, 0, "non-final pkt chunks should be dropped instead of delivered");
  assert.equal(
    manager.__zigfallTestPendingPayloadBytes(peerId, actionType, chunkedNonce),
    0,
    "non-final pkt chunks should not retain payload bytes",
  );
  assert.equal(
    manager.__zigfallTestPendingChunkCount(peerId, actionType, chunkedNonce),
    0,
    "non-final pkt chunks should not be appended to Trystero's pending chunks array",
  );
  assert.equal(
    manager.__zigfallTestPendingNonceCountForPeer(peerId, actionType),
    1,
    "a bounded dropped marker should suppress later tails for the same nonce",
  );

  const singleFrameNonce = 0x1238;
  manager.handleData(peerId, makeFrame({ payloadLength: 512, isLast: true, nonceValue: singleFrameNonce }));
  assert.equal(deliveries.length, 1, "a valid single-frame final pkt should still deliver after dropped junk");
  assert.equal(deliveries[0].payload.byteLength, 512);
  assert.equal(
    manager.__zigfallTestPendingNonceCountForPeer(peerId, actionType),
    1,
    "the dropped marker should remain only for its original chunked nonce",
  );

  manager.handleData(peerId, makeFrame({ payloadLength: 1, isLast: true, nonceValue: chunkedNonce }));

  assert.equal(deliveries.length, 1, "a chunked pkt tail should not deliver after a dropped non-final chunk");
  assert.equal(manager.__zigfallTestPendingPayloadBytes(peerId, actionType, chunkedNonce), 0);
  assert.equal(manager.__zigfallTestPendingChunkCount(peerId, actionType, chunkedNonce), 0);
  assert.equal(manager.__zigfallTestPendingNonceCountForPeer(peerId, actionType), 0);
}

{
  const deliveries = [];
  const manager = makeManager(deliveries);
  const zeroNonce = 0x1237;
  for (let i = 0; i < 1024; i += 1) {
    manager.handleData(peerId, makeFrame({ payloadLength: 0, nonceValue: zeroNonce }));
  }

  assert.equal(deliveries.length, 0, "repeated zero-length non-final pkt chunks should never deliver");
  assert.equal(
    manager.__zigfallTestPendingPayloadBytes(peerId, actionType, zeroNonce),
    0,
    "repeated zero-length non-final pkt chunks should not retain payload bytes",
  );
  assert.equal(
    manager.__zigfallTestPendingChunkCount(peerId, actionType, zeroNonce),
    0,
    "repeated zero-length non-final pkt chunks should not grow retained chunks",
  );
  assert.equal(
    manager.__zigfallTestPendingNonceCountForPeer(peerId, actionType),
    1,
    "repeated zero-length non-final pkt chunks should retain only one bounded dropped marker",
  );

  manager.handleData(peerId, makeFrame({ payloadLength: 16, isLast: true, nonceValue: zeroNonce }));

  assert.equal(deliveries.length, 0, "a final pkt tail should not deliver after repeated dropped non-final chunks");
  assert.equal(manager.__zigfallTestPendingPayloadBytes(peerId, actionType, zeroNonce), 0);
  assert.equal(manager.__zigfallTestPendingChunkCount(peerId, actionType, zeroNonce), 0);
  assert.equal(manager.__zigfallTestPendingNonceCountForPeer(peerId, actionType), 0);
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

{
  const deliveries = [];
  const manager = makeManager(deliveries);
  const unknownNonce = 0x2000;
  manager.handleData(
    peerId,
    makeFrame({
      action: "evil",
      payloadLength: 512,
      nonceValue: unknownNonce,
    }),
  );

  assert.equal(deliveries.length, 0, "unknown public actions should never deliver through pkt");
  assert.equal(
    manager.__zigfallTestPendingPayloadBytes(peerId, "evil", unknownNonce),
    0,
    "unknown public actions should be dropped before Trystero allocates a pending target",
  );
  assert.equal(manager.__zigfallTestPendingNonceCountForPeer(peerId, "evil"), 0);
}

{
  const deliveries = [];
  const manager = makeManager(deliveries, controlActionType);
  const controlNonce = 0x3001;
  const firstChunk = encoder.encode('{"sdp":"');
  const finalChunk = encoder.encode('offer"}');

  manager.handleData(
    peerId,
    makeFrame({
      action: controlActionType,
      payloadBytes: firstChunk,
      isBinary: false,
      isJson: true,
      nonceValue: controlNonce,
    }),
  );

  assert.equal(deliveries.length, 0, "chunked control messages should wait for the final chunk");
  assert.equal(
    manager.__zigfallTestPendingChunkCount(peerId, controlActionType, controlNonce),
    1,
    "valid control chunking should retain a bounded pending chunk",
  );
  assert.equal(
    manager.__zigfallTestPendingPayloadBytes(peerId, controlActionType, controlNonce),
    firstChunk.byteLength,
  );

  manager.handleData(
    peerId,
    makeFrame({
      action: controlActionType,
      payloadBytes: finalChunk,
      isLast: true,
      isBinary: false,
      isJson: true,
      nonceValue: controlNonce,
    }),
  );

  assert.equal(deliveries.length, 1, "legitimate chunked control messages should still deliver");
  assert.deepEqual(deliveries[0].payload, { sdp: "offer" });
  assert.equal(manager.__zigfallTestPendingPayloadBytes(peerId, controlActionType, controlNonce), 0);
  assert.equal(manager.__zigfallTestPendingChunkCount(peerId, controlActionType, controlNonce), 0);
}

{
  const deliveries = [];
  const manager = makeManager(deliveries, controlActionType);
  const zeroNonce = 0x3002;
  for (let i = 0; i < 1024; i += 1) {
    manager.handleData(
      peerId,
      makeFrame({
        action: controlActionType,
        payloadLength: 0,
        isBinary: false,
        isJson: true,
        nonceValue: zeroNonce,
      }),
    );
  }

  assert.equal(deliveries.length, 0, "repeated zero-length non-final control chunks should never deliver");
  assert.equal(
    manager.__zigfallTestPendingPayloadBytes(peerId, controlActionType, zeroNonce),
    0,
    "repeated zero-length non-final control chunks should not retain payload bytes",
  );
  assert.equal(
    manager.__zigfallTestPendingChunkCount(peerId, controlActionType, zeroNonce),
    0,
    "repeated zero-length non-final control chunks should not grow retained chunks",
  );
  assert.equal(
    manager.__zigfallTestPendingNonceCountForPeer(peerId, controlActionType),
    1,
    "repeated zero-length non-final control chunks should retain only one bounded dropped marker",
  );

  manager.handleData(
    peerId,
    makeFrame({
      action: controlActionType,
      payloadBytes: encoder.encode("{}"),
      isLast: true,
      isBinary: false,
      isJson: true,
      nonceValue: zeroNonce,
    }),
  );

  assert.equal(deliveries.length, 0, "a final control tail should not deliver after dropped zero chunks");
  assert.equal(manager.__zigfallTestPendingPayloadBytes(peerId, controlActionType, zeroNonce), 0);
  assert.equal(manager.__zigfallTestPendingChunkCount(peerId, controlActionType, zeroNonce), 0);
  assert.equal(manager.__zigfallTestPendingNonceCountForPeer(peerId, controlActionType), 0);
}

{
  const deliveries = [];
  const manager = makeManager(deliveries, controlActionType);
  const limits = manager.__zigfallTestReceiveLimits();
  const capNonce = 0x3003;
  assert(limits.controlMaxPendingChunksPerTransmission > 1, "control actions should allow bounded chunking");

  manager.handleData(
    peerId,
    makeFrame({
      action: controlActionType,
      payloadLength: 1,
      isBinary: false,
      nonceValue: capNonce,
    }),
  );
  assert.equal(
    manager.__zigfallTestPendingChunkCount(peerId, controlActionType, capNonce),
    1,
    "non-empty control chunks should be retained before the chunk cap is hit",
  );

  for (let i = 1; i < limits.controlMaxPendingChunksPerTransmission + 3; i += 1) {
    manager.handleData(
      peerId,
      makeFrame({
        action: controlActionType,
        payloadLength: 1,
        isBinary: false,
        nonceValue: capNonce,
        fill: 0x61 + i,
      }),
    );
  }

  assert.equal(deliveries.length, 0, "over-cap non-final control chunks should never deliver");
  assert.equal(
    manager.__zigfallTestPendingPayloadBytes(peerId, controlActionType, capNonce),
    0,
    "over-cap non-final control chunks should clear retained payload bytes",
  );
  assert.equal(
    manager.__zigfallTestPendingChunkCount(peerId, controlActionType, capNonce),
    0,
    "over-cap non-final control chunks should clear retained chunk entries",
  );
  assert.equal(
    manager.__zigfallTestPendingNonceCountForPeer(peerId, controlActionType),
    1,
    "over-cap non-final control chunks should leave only a bounded dropped marker",
  );

  manager.handleData(
    peerId,
    makeFrame({
      action: controlActionType,
      payloadBytes: encoder.encode("ok"),
      isLast: true,
      isBinary: false,
      nonceValue: capNonce,
    }),
  );
  assert.equal(deliveries.length, 0, "a final control tail should not deliver after the chunk cap is hit");
  assert.equal(manager.__zigfallTestPendingNonceCountForPeer(peerId, controlActionType), 0);
}

{
  const deliveries = [];
  const manager = makeManager(deliveries);
  const limits = manager.__zigfallTestReceiveLimits();
  assert.equal(limits.pktMaxPendingChunksPerTransmission, 1, "pkt should stay single-frame-only");
  for (let i = 0; i < limits.pktMaxPendingNoncesPerPeer + 5; i += 1) {
    manager.handleData(peerId, makeFrame({ payloadLength: 512, nonceValue: i }));
  }

  assert.equal(
    manager.__zigfallTestPendingNonceCountForPeer(peerId, actionType),
    limits.pktMaxPendingNoncesPerPeer,
    "many unfinished pkt nonces should be bounded per peer",
  );
  assert.equal(
    manager.__zigfallTestPendingPayloadBytesForPeer(peerId, actionType),
    0,
    "chunked pkt attempts should not retain pending payload bytes",
  );
  assert.equal(
    manager.__zigfallTestPendingChunkCount(peerId, actionType, 0),
    0,
    "chunked pkt attempts should not append pending chunks",
  );

  manager.handleData(peerId, makeFrame({ payloadLength: 1, isLast: true, nonceValue: 0 }));
  assert.equal(
    manager.__zigfallTestPendingNonceCountForPeer(peerId, actionType),
    0,
    "a final tail should clear the tracked dropped marker",
  );
  assert.equal(deliveries.length, 0);
}

{
  const deliveries = [];
  const manager = makeManager(deliveries);
  const limits = manager.__zigfallTestReceiveLimits();
  for (let i = 0; i < limits.pktMaxPendingNoncesGlobal + 5; i += 1) {
    manager.handleData(`peer-${i}`, makeFrame({ payloadLength: 512, nonceValue: i }));
  }

  assert.equal(
    manager.__zigfallTestPendingNonceCountGlobal(actionType),
    limits.pktMaxPendingNoncesGlobal,
    "unfinished pkt nonces should also be bounded globally",
  );
  assert.equal(
    manager.__zigfallTestPendingPayloadBytesGlobal(actionType),
    0,
    "chunked pkt attempts should not retain global pending payload bytes",
  );
  assert.equal(deliveries.length, 0);
}

console.log("ok: Trystero receive hardening preserves 512-byte pkt delivery and bounds hostile pkt/control chunk buffering");

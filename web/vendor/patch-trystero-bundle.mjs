// SPDX-License-Identifier: GPL-3.0-or-later

import { readFile, writeFile } from "node:fs/promises";

const bundlePath = new URL("./trystero-nostr.bundle.mjs", import.meta.url);

function replaceOnce(source, oldText, newText, label) {
  const index = source.indexOf(oldText);
  if (index === -1) {
    throw new Error(`unable to apply ${label}: expected text not found`);
  }
  if (source.indexOf(oldText, index + oldText.length) !== -1) {
    throw new Error(`unable to apply ${label}: expected text is not unique`);
  }
  return source.slice(0, index) + newText + source.slice(index + oldText.length);
}

let source = await readFile(bundlePath, "utf8");

source = replaceOnce(
  source,
  `var chunkSize = 16 * 2 ** 10 - payloadIndex;\n`,
  `var chunkSize = 16 * 2 ** 10 - payloadIndex;\n` +
    `// Zigfall local patch: fail closed in Trystero's receive reassembly path.\n` +
    `// The public transport accepts only opaque protocol.MaxPacketSize (512-byte)\n` +
    `// packets on the "pkt" action. Unknown public actions and unused internals are\n` +
    `// dropped before chunk buffering; required Trystero control actions get finite\n` +
    `// per-transmission and pending-buffer byte/chunk/nonce caps.\n` +
    `var zigfallGameActionName = "pkt";\n` +
    `var zigfallControlActionNames = new Set(["@_ping", "@_pong", "@_signal", "@_leave", "@_hsdata", "@_hsready"]);\n` +
    `var zigfallPktReceivePolicy = Object.freeze({\n` +
    `  kind: "pkt",\n` +
    `  requireBinary: true,\n` +
    `  allowMeta: false,\n` +
    `  requireSingleFrame: true,\n` +
    `  maxPendingChunksPerTransmission: 1,\n` +
    `  maxPayloadBytes: 512,\n` +
    `  maxPendingNoncesPerPeer: 1,\n` +
    `  maxPendingNoncesGlobal: 8,\n` +
    `  maxPendingBytesPerPeer: 512,\n` +
    `  maxPendingBytesGlobal: 512 * 8,\n` +
    `  dropNewCompleteWhilePeerPending: false\n` +
    `});\n` +
    `var zigfallControlReceivePolicy = Object.freeze({\n` +
    `  kind: "control",\n` +
    `  requireBinary: false,\n` +
    `  allowMeta: false,\n` +
    `  requireSingleFrame: false,\n` +
    `  maxPendingChunksPerTransmission: Math.ceil(64 * 1024 / chunkSize),\n` +
    `  maxPayloadBytes: 64 * 1024,\n` +
    `  maxPendingNoncesPerPeer: 4,\n` +
    `  maxPendingNoncesGlobal: 16,\n` +
    `  maxPendingBytesPerPeer: 128 * 1024,\n` +
    `  maxPendingBytesGlobal: 512 * 1024,\n` +
    `  dropNewCompleteWhilePeerPending: false\n` +
    `});\n` +
    `var zigfallActionReceivePolicy = (type) => type === zigfallGameActionName ? zigfallPktReceivePolicy : zigfallControlActionNames.has(type) ? zigfallControlReceivePolicy : null;\n` +
    `var zigfallPendingPayloadBytes = (target) => target?.zigfallPayloadBytes ?? target?.chunks?.reduce((a, c) => a + c.byteLength, 0) ?? 0;\n` +
    `var zigfallPendingChunkCount = (target) => target?.chunks?.length ?? 0;\n` +
    `var zigfallPendingStats = (pendingTransmissions, peerId, kind) => {\n` +
    `  const stats = { peerBytes: 0, peerNonces: 0, globalBytes: 0, globalNonces: 0 };\n` +
    `  entries(pendingTransmissions).forEach(([id, byType]) => {\n` +
    `    entries(byType).forEach(([type, byNonce]) => {\n` +
    `      const policy = zigfallActionReceivePolicy(type);\n` +
    `      if (!policy || policy.kind !== kind) return;\n` +
    `      entries(byNonce).forEach(([, target]) => {\n` +
    `        const bytes = zigfallPendingPayloadBytes(target);\n` +
    `        stats.globalBytes += bytes;\n` +
    `        stats.globalNonces += 1;\n` +
    `        if (id === peerId) {\n` +
    `          stats.peerBytes += bytes;\n` +
    `          stats.peerNonces += 1;\n` +
    `        }\n` +
    `      });\n` +
    `    });\n` +
    `  });\n` +
    `  return stats;\n` +
    `};\n` +
    `var zigfallClearPendingTransmission = (pendingTransmissions, id, type, nonce) => {\n` +
    `  const byPeer = pendingTransmissions[id];\n` +
    `  const byType = byPeer?.[type];\n` +
    `  if (!byType) return;\n` +
    `  delete byType[nonce];\n` +
    `  if (keys(byType).length === 0) delete byPeer[type];\n` +
    `  if (keys(byPeer).length === 0) delete pendingTransmissions[id];\n` +
    `};\n` +
    `var zigfallRememberDroppedTransmission = (pendingTransmissions, id, type, nonce, policy) => {\n` +
    `  const existingTarget = pendingTransmissions[id]?.[type]?.[nonce];\n` +
    `  if (existingTarget) {\n` +
    `    existingTarget.chunks = [];\n` +
    `    existingTarget.zigfallPayloadBytes = 0;\n` +
    `    existingTarget.zigfallDropped = true;\n` +
    `    return;\n` +
    `  }\n` +
    `  const stats = zigfallPendingStats(pendingTransmissions, id, policy.kind);\n` +
    `  if (stats.peerNonces >= policy.maxPendingNoncesPerPeer || stats.globalNonces >= policy.maxPendingNoncesGlobal) return;\n` +
    `  pendingTransmissions[id] ?? (pendingTransmissions[id] = {});\n` +
    `  pendingTransmissions[id][type] ?? (pendingTransmissions[id][type] = {});\n` +
    `  pendingTransmissions[id][type][nonce] = { chunks: [], zigfallPayloadBytes: 0, zigfallDropped: true };\n` +
    `};\n` +
    `var zigfallCanBufferActionChunk = (pendingTransmissions, peerId, type, nonce, existingTarget, payloadByteLength, isLast, isMeta, isBinary, isJson, policy) => {\n` +
    `  if (isMeta && !policy.allowMeta) return false;\n` +
    `  if (policy.requireBinary && !isBinary) return false;\n` +
    `  if (policy.requireSingleFrame && !isLast) return false;\n` +
    `  if (!isLast && payloadByteLength === 0) return false;\n` +
    `  const nextChunkCount = zigfallPendingChunkCount(existingTarget) + (isMeta ? 0 : 1);\n` +
    `  if (nextChunkCount > policy.maxPendingChunksPerTransmission) return false;\n` +
    `  if (!isLast && nextChunkCount >= policy.maxPendingChunksPerTransmission) return false;\n` +
    `  const currentPayloadBytes = zigfallPendingPayloadBytes(existingTarget);\n` +
    `  const nextPayloadBytes = currentPayloadBytes + payloadByteLength;\n` +
    `  if (nextPayloadBytes > policy.maxPayloadBytes) return false;\n` +
    `  const stats = zigfallPendingStats(pendingTransmissions, peerId, policy.kind);\n` +
    `  if (!existingTarget && isLast) return !policy.dropNewCompleteWhilePeerPending || stats.peerNonces === 0;\n` +
    `  if (!existingTarget && (stats.peerNonces >= policy.maxPendingNoncesPerPeer || stats.globalNonces >= policy.maxPendingNoncesGlobal)) return false;\n` +
    `  if (stats.peerBytes + payloadByteLength > policy.maxPendingBytesPerPeer) return false;\n` +
    `  if (stats.globalBytes + payloadByteLength > policy.maxPendingBytesGlobal) return false;\n` +
    `  return true;\n` +
    `};\n`,
  "Zigfall receive-hardening constants and helpers",
);

source = replaceOnce(
  source,
  `    const action = actions[type];\n    if (!canReceiveFromPeer(id, Boolean(action?.options.receiveWhilePending))) return;\n    const nonce = (buffer[nonceIndex] ?? 0) << 8 | (buffer[33] ?? 0);\n    const tag2 = buffer[tagIndex] ?? 0;\n    const progress = buffer[progressIndex] ?? 0;\n    const payload = buffer.subarray(payloadIndex);\n    const isLast = Boolean(tag2 & 1);\n    const isMeta = Boolean(tag2 & 2);\n    const isBinary = Boolean(tag2 & 4);\n    const isJson = Boolean(tag2 & 8);\n    pendingTransmissions[id] ?? (pendingTransmissions[id] = {});\n    (_a = pendingTransmissions[id])[type] ?? (_a[type] = {});\n    const target = (_b2 = pendingTransmissions[id][type])[nonce] ?? (_b2[nonce] = { chunks: [] });\n    if (isMeta) target.meta = fromJson(decodeBytes(payload));\n    else target.chunks.push(payload);\n    action?.onProgress(progress / oneByteMax, id, target.meta);\n`,
  `    const action = actions[type];\n    const zigfallReceivePolicy = zigfallActionReceivePolicy(type);\n    if (!action || !zigfallReceivePolicy) return;\n    if (!canReceiveFromPeer(id, Boolean(action.options.receiveWhilePending))) return;\n    const nonce = (buffer[nonceIndex] ?? 0) << 8 | (buffer[33] ?? 0);\n    const tag2 = buffer[tagIndex] ?? 0;\n    const progress = buffer[progressIndex] ?? 0;\n    const payload = buffer.subarray(payloadIndex);\n    const isLast = Boolean(tag2 & 1);\n    const isMeta = Boolean(tag2 & 2);\n    const isBinary = Boolean(tag2 & 4);\n    const isJson = Boolean(tag2 & 8);\n    const existingTarget = pendingTransmissions[id]?.[type]?.[nonce];\n    if (existingTarget?.zigfallDropped) {\n      if (isLast) zigfallClearPendingTransmission(pendingTransmissions, id, type, nonce);\n      return;\n    }\n    if (!zigfallCanBufferActionChunk(pendingTransmissions, id, type, nonce, existingTarget, payload.byteLength, isLast, isMeta, isBinary, isJson, zigfallReceivePolicy)) {\n      if (isLast) {\n        if (existingTarget) zigfallClearPendingTransmission(pendingTransmissions, id, type, nonce);\n      } else {\n        zigfallRememberDroppedTransmission(pendingTransmissions, id, type, nonce, zigfallReceivePolicy);\n      }\n      return;\n    }\n    pendingTransmissions[id] ?? (pendingTransmissions[id] = {});\n    (_a = pendingTransmissions[id])[type] ?? (_a[type] = {});\n    const target = existingTarget ?? ((_b2 = pendingTransmissions[id][type])[nonce] = { chunks: [], zigfallPayloadBytes: 0 });\n    target.zigfallPayloadBytes = (target.zigfallPayloadBytes ?? 0) + payload.byteLength;\n    if (isMeta) {\n      try {\n        target.meta = fromJson(decodeBytes(payload));\n      } catch {\n        zigfallClearPendingTransmission(pendingTransmissions, id, type, nonce);\n        return;\n      }\n    } else {\n      target.chunks.push(payload);\n    }\n    action.onProgress(progress / oneByteMax, id, target.meta);\n`,
  "Zigfall receive-hardening pre-buffer guard",
);

source = replaceOnce(
  source,
  `    delete pendingTransmissions[id][type][nonce];\n    const payloadValue = isBinary ? full : isJson ? fromJson(decodeBytes(full)) : decodeBytes(full);\n    if (action) {\n      action.onComplete(payloadValue, id, target.meta);\n      return;\n    }\n`,
  `    zigfallClearPendingTransmission(pendingTransmissions, id, type, nonce);\n    let payloadValue;\n    try {\n      payloadValue = isBinary ? full : isJson ? fromJson(decodeBytes(full)) : decodeBytes(full);\n    } catch {\n      return;\n    }\n    if (action) {\n      action.onComplete(payloadValue, id, target.meta);\n      return;\n    }\n`,
  "Zigfall receive-hardening completion parse guard",
);

source = replaceOnce(
  source,
  `  return {\n    makeInternalAction,\n    handleData,\n    clearPeer: (id) => {\n      delete pendingTransmissions[id];\n    }\n  };\n`,
  `  return {\n    makeInternalAction,\n    handleData,\n    __zigfallTestPendingPayloadBytes: (id, type, nonce) => {\n      const target = pendingTransmissions[id]?.[type]?.[nonce];\n      return zigfallPendingPayloadBytes(target);\n    },\n    __zigfallTestPendingChunkCount: (id, type, nonce) => {\n      const target = pendingTransmissions[id]?.[type]?.[nonce];\n      return zigfallPendingChunkCount(target);\n    },\n    __zigfallTestPendingPayloadBytesForPeer: (id, type) => values(pendingTransmissions[id]?.[type] ?? {}).reduce((a, target) => a + zigfallPendingPayloadBytes(target), 0),\n    __zigfallTestPendingPayloadBytesGlobal: (type) => values(pendingTransmissions).reduce((a, byType) => a + values(byType[type] ?? {}).reduce((b, target) => b + zigfallPendingPayloadBytes(target), 0), 0),\n    __zigfallTestPendingNonceCountForPeer: (id, type) => keys(pendingTransmissions[id]?.[type] ?? {}).length,\n    __zigfallTestPendingNonceCountGlobal: (type) => values(pendingTransmissions).reduce((a, byType) => a + keys(byType[type] ?? {}).length, 0),\n    __zigfallTestReceiveLimits: () => ({\n      pktRequireSingleFrame: zigfallPktReceivePolicy.requireSingleFrame,\n      pktMaxPendingChunksPerTransmission: zigfallPktReceivePolicy.maxPendingChunksPerTransmission,\n      pktMaxPendingNoncesPerPeer: zigfallPktReceivePolicy.maxPendingNoncesPerPeer,\n      pktMaxPendingNoncesGlobal: zigfallPktReceivePolicy.maxPendingNoncesGlobal,\n      pktMaxPendingBytesPerPeer: zigfallPktReceivePolicy.maxPendingBytesPerPeer,\n      pktMaxPendingBytesGlobal: zigfallPktReceivePolicy.maxPendingBytesGlobal,\n      controlMaxPayloadBytes: zigfallControlReceivePolicy.maxPayloadBytes,\n      controlMaxPendingChunksPerTransmission: zigfallControlReceivePolicy.maxPendingChunksPerTransmission,\n      controlMaxPendingNoncesPerPeer: zigfallControlReceivePolicy.maxPendingNoncesPerPeer,\n      controlMaxPendingNoncesGlobal: zigfallControlReceivePolicy.maxPendingNoncesGlobal,\n      controlMaxPendingBytesPerPeer: zigfallControlReceivePolicy.maxPendingBytesPerPeer,\n      controlMaxPendingBytesGlobal: zigfallControlReceivePolicy.maxPendingBytesGlobal\n    }),\n    clearPeer: (id) => {\n      delete pendingTransmissions[id];\n    }\n  };\n`,
  "Zigfall receive-hardening test hooks",
);

source = replaceOnce(
  source,
  `var roomFrameVersion = 1;
var roomPresenceFrameVersion = 2;
var wrapRoomFrame = (roomToken, data) => {
`,
  `var roomFrameVersion = 1;
var roomPresenceFrameVersion = 2;
var zigfallRoomTokenBytes = 64;
var zigfallRoomFrameMaxPayloadBytes = 64 * 1024;
var zigfallSharedPendingRoomTokenLimit = 16;
var zigfallSharedPendingRoomFramesPerTokenLimit = 4;
var zigfallSharedPendingRoomBytesLimit = 256 * 1024;
var zigfallSharedRemoteRoomTokenLimit = 64;
var zigfallNullProto = () => Object.create(null);
var zigfallIsLowerHexByte = (byte) => byte >= 48 && byte <= 57 || byte >= 97 && byte <= 102;
var zigfallIsRoomTokenBytes = (tokenBytes) => tokenBytes.byteLength === zigfallRoomTokenBytes && tokenBytes.every(zigfallIsLowerHexByte);
var zigfallRoomPendingBytes = (pendingDataByToken) => {
  let total = 0;
  pendingDataByToken.forEach((frames) => frames.forEach((payload) => {
    total += payload.byteLength ?? 0;
  }));
  return total;
};
var wrapRoomFrame = (roomToken, data) => {
`,
  "Zigfall shared-peer room-frame constants and helpers",
);

source = replaceOnce(
  source,
  `var unwrapFrame = (data) => {
  const buffer = new Uint8Array(data);
  if (buffer.byteLength < 3) return null;
  if (buffer[0] === roomFrameVersion) {
    const tokenSize2 = (buffer[1] ?? 0) << 8 | (buffer[2] ?? 0);
    const headerSize2 = 3 + tokenSize2;
    if (tokenSize2 <= 0 || buffer.byteLength < headerSize2) return null;
    return {
      type: "room",
      roomToken: decodeBytes(buffer.subarray(3, headerSize2)),
      payload: buffer.subarray(headerSize2).slice().buffer
    };
  }
  if (buffer[0] !== roomPresenceFrameVersion || buffer.byteLength < 4) return null;
  const tokenSize = (buffer[2] ?? 0) << 8 | (buffer[3] ?? 0);
  const headerSize = 4 + tokenSize;
  if (tokenSize <= 0 || buffer.byteLength < headerSize) return null;
  return {
    type: "presence",
    roomToken: decodeBytes(buffer.subarray(4, headerSize)),
    isPresent: buffer[1] === 1
  };
};
`,
  `var unwrapFrame = (data) => {
  const buffer = data instanceof ArrayBuffer ? new Uint8Array(data) : ArrayBuffer.isView(data) ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength) : null;
  if (!buffer || buffer.byteLength < 3) return null;
  if (buffer[0] === roomFrameVersion) {
    const tokenSize2 = (buffer[1] ?? 0) << 8 | (buffer[2] ?? 0);
    const headerSize2 = 3 + tokenSize2;
    if (tokenSize2 !== zigfallRoomTokenBytes || buffer.byteLength < headerSize2) return null;
    const tokenBytes = buffer.subarray(3, headerSize2);
    if (!zigfallIsRoomTokenBytes(tokenBytes)) return null;
    const payloadSize = buffer.byteLength - headerSize2;
    if (payloadSize > zigfallRoomFrameMaxPayloadBytes) return null;
    return {
      type: "room",
      roomToken: decodeBytes(tokenBytes),
      payload: buffer.subarray(headerSize2).slice().buffer
    };
  }
  if (buffer[0] !== roomPresenceFrameVersion || buffer.byteLength < 4) return null;
  const presenceFlag = buffer[1];
  if (presenceFlag !== 0 && presenceFlag !== 1) return null;
  const tokenSize = (buffer[2] ?? 0) << 8 | (buffer[3] ?? 0);
  const headerSize = 4 + tokenSize;
  if (tokenSize !== zigfallRoomTokenBytes || buffer.byteLength !== headerSize) return null;
  const tokenBytes = buffer.subarray(4, headerSize);
  if (!zigfallIsRoomTokenBytes(tokenBytes)) return null;
  return {
    type: "presence",
    roomToken: decodeBytes(tokenBytes),
    isPresent: presenceFlag === 1
  };
};
`,
  "Zigfall shared-peer room-frame unwrap guard",
);

source = replaceOnce(
  source,
  `  constructor() {
    __publicField(this, "byApp", {});
    __publicField(this, "roomPresenceHandlers", {});
  }
`,
  `  constructor() {
    __publicField(this, "byApp", zigfallNullProto());
    __publicField(this, "roomPresenceHandlers", zigfallNullProto());
  }
`,
  "Zigfall shared-peer manager null-prototype roots",
);

source = replaceOnce(
  source,
  `    return (_a = this.byApp)[appId] ?? (_a[appId] = {});
`,
  `    return (_a = this.byApp)[appId] ?? (_a[appId] = zigfallNullProto());
`,
  "Zigfall shared-peer app map null-prototype allocation",
);

source = replaceOnce(
  source,
  `    shared.bindings = {};
    shared.bindingsByToken = {};
`,
  `    shared.bindings = zigfallNullProto();
    shared.bindingsByToken = /* @__PURE__ */ new Map();
`,
  "Zigfall shared-peer clear null-prototype bindings",
);

source = replaceOnce(
  source,
  `      bindings: {},
      bindingsByToken: {},
`,
  `      bindings: zigfallNullProto(),
      bindingsByToken: /* @__PURE__ */ new Map(),
`,
  "Zigfall shared-peer register token map",
);

source = replaceOnce(
  source,
  `      if (binding.roomToken && shared.bindingsByToken[binding.roomToken] === binding) delete shared.bindingsByToken[binding.roomToken];
`,
  `      if (binding.roomToken && shared.bindingsByToken.get(binding.roomToken) === binding) shared.bindingsByToken.delete(binding.roomToken);
`,
  "Zigfall shared-peer detach token map cleanup",
);

source = replaceOnce(
  source,
  `      shared.bindingsByToken[roomToken] = binding;
`,
  `      shared.bindingsByToken.set(roomToken, binding);
`,
  "Zigfall shared-peer bind token map store",
);

source = replaceOnce(
  source,
  `    if (decoded.type === "presence") {
      if (decoded.isPresent) shared.remoteRoomTokens.add(decoded.roomToken);
      else shared.remoteRoomTokens.delete(decoded.roomToken);
      this.roomPresenceHandlers[shared.appId]?.(shared.peerId, decoded.roomToken, decoded.isPresent);
      return;
    }
    const binding = shared.bindingsByToken[decoded.roomToken];
    if (!binding) {
      const pending = shared.pendingDataByToken.get(decoded.roomToken) ?? [];
      pending.push(decoded.payload);
      shared.pendingDataByToken.set(decoded.roomToken, pending);
      return;
    }
`,
  `    if (decoded.type === "presence") {
      if (decoded.isPresent) {
        if (!shared.remoteRoomTokens.has(decoded.roomToken) && shared.remoteRoomTokens.size >= zigfallSharedRemoteRoomTokenLimit) return;
        shared.remoteRoomTokens.add(decoded.roomToken);
      } else {
        shared.remoteRoomTokens.delete(decoded.roomToken);
        shared.pendingDataByToken.delete(decoded.roomToken);
      }
      this.roomPresenceHandlers[shared.appId]?.(shared.peerId, decoded.roomToken, decoded.isPresent);
      return;
    }
    const binding = shared.bindingsByToken.get(decoded.roomToken);
    if (!binding) {
      const pending = shared.pendingDataByToken.get(decoded.roomToken) ?? [];
      if (!shared.pendingDataByToken.has(decoded.roomToken) && shared.pendingDataByToken.size >= zigfallSharedPendingRoomTokenLimit) return;
      if (pending.length >= zigfallSharedPendingRoomFramesPerTokenLimit) return;
      if (zigfallRoomPendingBytes(shared.pendingDataByToken) + decoded.payload.byteLength > zigfallSharedPendingRoomBytesLimit) return;
      pending.push(decoded.payload);
      shared.pendingDataByToken.set(decoded.roomToken, pending);
      return;
    }
`,
  "Zigfall shared-peer pending room data and presence caps",
);

await writeFile(bundlePath, source);

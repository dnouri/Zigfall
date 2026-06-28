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

await writeFile(bundlePath, source);

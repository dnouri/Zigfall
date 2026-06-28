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
  "var chunkSize = 16 * 2 ** 10 - payloadIndex;\n",
  "var chunkSize = 16 * 2 ** 10 - payloadIndex;\n" +
    "// Zigfall local patch: the public transport only accepts protocol.MaxPacketSize\n" +
    "// (512-byte) packets on the \"pkt\" action. Enforce that limit while Trystero\n" +
    "// reassembles chunks so an oversize peer payload is dropped before it can grow\n" +
    "// an unbounded pending chunks array.\n" +
    "var zigfallPktActionName = \"pkt\";\n" +
    "var zigfallMaxPktActionPayloadBytes = 512;\n",
  "Zigfall pkt payload-limit constants",
);

source = replaceOnce(
  source,
  "    const target = (_b2 = pendingTransmissions[id][type])[nonce] ?? (_b2[nonce] = { chunks: [] });\n    if (isMeta) target.meta = fromJson(decodeBytes(payload));\n    else target.chunks.push(payload);\n    action?.onProgress(progress / oneByteMax, id, target.meta);\n",
  "    const target = (_b2 = pendingTransmissions[id][type])[nonce] ?? (_b2[nonce] = { chunks: [] });\n" +
    "    if (type === zigfallPktActionName) {\n" +
    "      if (target.zigfallDropped) {\n" +
    "        if (isLast) delete pendingTransmissions[id][type][nonce];\n" +
    "        return;\n" +
    "      }\n" +
    "      if (isMeta || !isBinary) {\n" +
    "        target.zigfallDropped = true;\n" +
    "        target.chunks = [];\n" +
    "        target.zigfallPayloadBytes = 0;\n" +
    "        if (isLast) delete pendingTransmissions[id][type][nonce];\n" +
    "        return;\n" +
    "      }\n" +
    "      const nextPayloadBytes = (target.zigfallPayloadBytes ?? 0) + payload.byteLength;\n" +
    "      if (nextPayloadBytes > zigfallMaxPktActionPayloadBytes) {\n" +
    "        target.zigfallDropped = true;\n" +
    "        target.chunks = [];\n" +
    "        target.zigfallPayloadBytes = 0;\n" +
    "        if (isLast) delete pendingTransmissions[id][type][nonce];\n" +
    "        return;\n" +
    "      }\n" +
    "      target.zigfallPayloadBytes = nextPayloadBytes;\n" +
    "    }\n" +
    "    if (isMeta) target.meta = fromJson(decodeBytes(payload));\n" +
    "    else target.chunks.push(payload);\n" +
    "    action?.onProgress(progress / oneByteMax, id, target.meta);\n",
  "Zigfall pkt payload-limit receive guard",
);

source = replaceOnce(
  source,
  "  return {\n    makeInternalAction,\n    handleData,\n    clearPeer: (id) => {\n      delete pendingTransmissions[id];\n    }\n  };\n",
  "  return {\n" +
    "    makeInternalAction,\n" +
    "    handleData,\n" +
    "    __zigfallTestPendingPayloadBytes: (id, type, nonce) => {\n" +
    "      const target = pendingTransmissions[id]?.[type]?.[nonce];\n" +
    "      if (!target || target.zigfallDropped) return 0;\n" +
    "      return target.chunks.reduce((a, c) => a + c.byteLength, 0);\n" +
    "    },\n" +
    "    clearPeer: (id) => {\n" +
    "      delete pendingTransmissions[id];\n" +
    "    }\n" +
    "  };\n",
  "Zigfall pkt payload-limit test hook",
);

await writeFile(bundlePath, source);

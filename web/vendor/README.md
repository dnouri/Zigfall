# Vendored Trystero browser bundle

`trystero-nostr.bundle.mjs` is a checked-in browser ESM bundle used by Zigfall's web-only transport adapter. Production web builds copy this local file into `zig-out/web/vendor/`, so the deployed game does not import Trystero from a runtime CDN and native builds do not need Node/npm/Trystero. The bundle remains Trystero's Nostr strategy; Zigfall supplies its curated public Nostr relay URLs from `web/zigfall_transport.mjs` at runtime instead of relying on upstream defaults.

## Source versions

Runtime bundle inputs are pinned by `package.json` and `package-lock.json`:

- `trystero@0.25.2` (Nostr strategy bundle entry)
- `@trystero-p2p/nostr@0.25.2`
- `@trystero-p2p/core@0.25.2`
- `@noble/secp256k1@3.1.0`

Regeneration uses `esbuild@0.25.5`. The current lockfile was generated with Node `v24.9.0` and npm `11.6.0` (lockfile version 3). Node/npm are only for intentional vendor regeneration; do not add npm install or bundling to `build.zig`.

## Local Zigfall patch

After esbuild writes the upstream bundle, `patch-trystero-bundle.mjs` applies a Zigfall-local fail-closed patch to Trystero's action reassembly path used by `web/zigfall_transport.mjs`.

The patch mirrors `src/protocol.zig` / `protocol.MaxPacketSize = 512` for public game traffic and keeps Trystero control traffic finite:

- Allows only the public `pkt` action plus the required Trystero room-control actions (`@_ping`, `@_pong`, `@_signal`, `@_leave`, `@_hsdata`, `@_hsready`). Unknown public actions and unused internals are dropped before any chunk target is allocated.
- Tracks accumulated reassembled payload bytes and chunk counts per peer/type/nonce before appending a chunk to Trystero's pending `chunks` array.
- Allows normal single-frame final binary `pkt` payloads up to exactly 512 bytes.
- Rejects all non-final/chunked `pkt` frames before appending to Trystero's pending `chunks` array, retaining only bounded dropped markers to suppress later tails for the same nonce while unrelated single-frame final `pkt` payloads remain deliverable.
- Drops and clears/marks any invalid `pkt` transmission before it can exceed 512 bytes, and suppresses later tail delivery for that nonce when tracked.
- Rejects `pkt` metadata chunks and all non-binary `pkt` frames before Trystero JSON/string parsing. Zigfall only sends opaque binary packets on `pkt`.
- Bounds dropped/unfinished `pkt` nonces to one per peer/eight globally. Required control actions have separate finite caps (64 KiB per transmission, a finite per-transmission chunk cap, four unfinished nonces per peer, sixteen globally), and zero-length non-final chunks are rejected before buffering for every allowed action.
- Drops malformed non-binary payloads if Trystero JSON/string decoding fails at completion.

Trystero's wire chunk header is 36 bytes (`payloadIndex` in the bundle), so an exact 512-byte Zigfall packet is a 548-byte Trystero data-channel message. The cap applies to accumulated action payload bytes, not to that per-chunk framing. This cannot stop the browser/WebRTC stack from delivering one already-received data-channel message to JavaScript, but it prevents Trystero from growing an unbounded pending reassembly buffer for hostile action/chunk streams before Zigfall's adapter-level 512-byte check runs. Because Zigfall packets are at most 512 bytes, valid `pkt` traffic must be a single final Trystero frame; non-final `pkt` frames are dropped without retaining payload chunks.

`tools/test_trystero_pkt_limit.mjs` regression-tests the patched bundle by importing the actual action-wire code, proving exact 512-byte typed-array-style `pkt` payloads still deliver, single-frame oversize payloads drop, non-final and repeated zero-length non-final `pkt` chunks retain no pending chunks and suppress tails, malformed non-binary `pkt` frames do not reach Trystero JSON parsing, unknown public actions are dropped before buffering, allowed control actions still support bounded chunked delivery, zero-length non-final control chunks retain no pending chunks, over-cap control chunks are cleared/dropped, and many unfinished/chunked `pkt` attempts stay bounded.

## Regenerate

From the repository root with network access and Node/npm available:

```sh
cd web/vendor
./regenerate.sh
```

The script runs:

```sh
npm ci
npm run build
npm run test:pkt-limit
sha256sum trystero-nostr.bundle.mjs > trystero-nostr.bundle.mjs.sha256
cat trystero-nostr.bundle.mjs.sha256
```

Current generated artifact checksum is tracked in `trystero-nostr.bundle.mjs.sha256`:

```text
3723fa68011b856f05cc47f35e1dba4581abb588b9236f3fe16309b5151f2063  trystero-nostr.bundle.mjs
```

If the bundle changes intentionally, update `trystero-nostr.bundle.mjs.sha256`, keep the lockfile in sync, and re-run the JavaScript regression plus the normal Zigfall native/web build checks. The Pages workflow verifies this checksum in source and again after the bundle is copied into the web artifact.

## Licenses

The Trystero packages are MIT licensed by Dan Motzenbecker; `LICENSE-trystero.txt` covers `trystero`, `@trystero-p2p/nostr`, and `@trystero-p2p/core` (their npm license files are identical). `@noble/secp256k1` is MIT licensed by Paul Miller; its license text is in `LICENSE-noble-secp256k1.txt`. `esbuild` is MIT licensed and used only as the regeneration build tool; its license text is in `LICENSE-esbuild.txt`.

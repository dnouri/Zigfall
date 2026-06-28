# Vendored Trystero browser bundle

`trystero-nostr.bundle.mjs` is a checked-in browser ESM bundle used by Zigfall's web-only transport adapter. Production web builds copy this local file into `zig-out/web/vendor/`, so the deployed game does not import Trystero from a runtime CDN and native builds do not need Node/npm/Trystero.

## Source versions

Runtime bundle inputs are pinned by `package.json` and `package-lock.json`:

- `trystero@0.25.2` (default Nostr strategy)
- `@trystero-p2p/nostr@0.25.2`
- `@trystero-p2p/core@0.25.2`
- `@noble/secp256k1@3.1.0`

Regeneration uses `esbuild@0.25.5`. The current lockfile was generated with Node `v24.9.0` and npm `11.6.0` (lockfile version 3). Node/npm are only for intentional vendor regeneration; do not add npm install or bundling to `build.zig`.

## Local Zigfall patch

After esbuild writes the upstream bundle, `patch-trystero-bundle.mjs` applies a small Zigfall-local patch to Trystero's action reassembly path for the public `pkt` action used by `web/zigfall_transport.mjs`.

The patch mirrors `src/protocol.zig` / `protocol.MaxPacketSize = 512`:

- Tracks accumulated reassembled payload bytes per peer/type/nonce before appending a chunk to Trystero's pending `chunks` array.
- Allows normal `pkt` payloads up to exactly 512 bytes.
- Drops and clears the transmission as soon as the next chunk would exceed 512 bytes, and suppresses later tail delivery for that nonce.
- Rejects `pkt` metadata chunks and all non-binary `pkt` frames before Trystero JSON/string parsing. Zigfall only sends opaque binary packets on `pkt`.

Trystero's wire chunk header is 36 bytes (`payloadIndex` in the bundle), so an exact 512-byte Zigfall packet is a 548-byte Trystero data-channel message. The cap applies to accumulated action payload bytes, not to that per-chunk framing. This cannot stop the browser/WebRTC stack from delivering one already-received data-channel message to JavaScript, but it prevents Trystero from growing an unbounded pending reassembly buffer for oversize `pkt` payloads before Zigfall's adapter-level 512-byte check runs.

`tools/test_trystero_pkt_limit.mjs` regression-tests the patched bundle by importing the actual action-wire code, proving exact 512-byte payloads still deliver, multi-chunk oversize payloads clear pending chunks before buffered payload bytes exceed 512, and malformed non-binary `pkt` frames do not reach Trystero JSON parsing.

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
sha256sum trystero-nostr.bundle.mjs
```

Current generated artifact:

```text
b13242f9f6de4bc1dcbc8903855efca16937aa7408275f3fac95b19e45bb3c60  trystero-nostr.bundle.mjs
```

If the bundle changes intentionally, update this checksum, keep the lockfile in sync, and re-run the JavaScript regression plus the normal Zigfall native/web build checks.

## Licenses

The Trystero packages are MIT licensed by Dan Motzenbecker; `LICENSE-trystero.txt` covers `trystero`, `@trystero-p2p/nostr`, and `@trystero-p2p/core` (their npm license files are identical). `@noble/secp256k1` is MIT licensed by Paul Miller; its license text is in `LICENSE-noble-secp256k1.txt`. `esbuild` is MIT licensed and used only as the regeneration build tool; its license text is in `LICENSE-esbuild.txt`.

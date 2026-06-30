# Third-party notices

Zigfall's own project source is licensed as GPL-3.0-or-later; see `LICENSE`.
This file is copied into distributed artifacts together with the root license,
the tracked license text snapshots under `third_party/licenses/`, and the
vendored browser bundle notices under `web/vendor/`. Web builds place those
files under `zig-out/web/`; native builds place the legal bundle under
`zig-out/share/zigfall/`. Upstream license files remain authoritative; update
the tracked snapshots when dependency pins change.

| Component | Role | License / bundled notice file | Notes |
| --- | --- | --- | --- |
| Zig compiler runtime / standard library | Zig toolchain support code and standard-library/runtime code that may be compiled into native binaries or web WASM/JS glue | MIT (Expat); `licenses/LICENSE-zig.txt` | Copyright (c) Zig contributors. Snapshot copied from the installed Zig 0.16.0 distribution root `LICENSE`. |
| raylib-zig | Zig bindings and build integration for raylib | MIT; `licenses/LICENSE-raylib-zig.txt` | Copyright (c) 2020 Nikolas Wipper. The pinned Zig package omits this file from its package paths, so Zigfall keeps a tracked copy for distributed artifacts. |
| raylib | Windowing, graphics, input, and selected support modules used through raylib-zig; compiled into native builds and web WASM as needed | zlib/libpng-style; `licenses/LICENSE-raylib.txt` | Copyright (c) 2013-2026 Ramon Santamaria (@raysan5). Zigfall does not ship the raylib source tree in native/web artifacts, so tracked notices are copied into the legal bundle. |
| raylib `src/external` components | Embedded raylib support code and single-file dependencies enabled by raylib's default modules/platforms, such as sdefl/sinfl, STB image/font/audio helpers, QOI/QOA, miniaudio/dr_wav/dr_mp3, tinyobj/cgltf/par_shapes, GLAD, and GLFW | Mixed permissive upstream notices; aggregate snapshot in `licenses/LICENSE-raylib-external.txt` | Summary snapshot from upstream `src/external` notices in the pinned raylib 6.0 package used through raylib-zig. Included because native/web artifacts can contain code or data from these components even though Zigfall does not call them directly. |
| raygui | GUI helper dependency enabled by raylib-zig's raylib build; not called directly by the current app | zlib/libpng-style; `licenses/LICENSE-raygui.txt` | Copyright (c) 2014-2026 Ramon Santamaria (@raysan5). Included because raylib-zig requests raygui in the raylib dependency build. |
| Emscripten compiler/runtime | Web compiler and generated JS/WASM runtime support; selected sysroot/compiler runtime code may be present in `zigfall.js`/`zigfall.wasm` | Dual MIT or University of Illinois/NCSA text from the active SDK's `upstream/emscripten/LICENSE` in `licenses/LICENSE-emscripten.txt`; authors in `licenses/AUTHORS-emscripten.txt`; common linked sysroot/runtime notices in `licenses/LICENSE-emscripten-musl.txt` and `licenses/LICENSE-emscripten-compiler-rt.txt` | The snapshot is from the activated Emscripten compiler/runtime tree (`emscripten-version.txt` reports 4.0.3 in the pinned emsdk package). The full compiler/tool distribution, tests, downloads, and Node helper packages are build-time inputs and are not copied into the deployed web artifact. |
| emsdk SDK manager | SDK manager package used by the Zig web build to activate Emscripten | MIT; `licenses/LICENSE-emsdk.txt` | Build-time helper only; listed separately so the SDK-manager license is not confused with the activated Emscripten compiler/runtime license above. |
| zemscripten | Zig/Emscripten build helper used by raylib-zig web support | MIT; `licenses/LICENSE-zemscripten.txt` | Copyright (c) 2024 zig-gamedev contributors. Build helper only; not a browser runtime module. |
| Trystero / @trystero-p2p | Vendored browser-only WebRTC transport bundle for active web invite-link online play | MIT; `vendor/LICENSE-trystero.txt` | Copyright (c) 2021 Dan Motzenbecker. Includes local Zigfall receive allowlist and pending-buffer cap patches documented in `web/vendor/README.md` (copied as `vendor/README.md` in distributed artifacts); Zigfall supplies curated public Nostr relay URLs at runtime. |
| @noble/secp256k1 | Vendored dependency inside the Trystero/Nostr browser bundle | MIT; `vendor/LICENSE-noble-secp256k1.txt` | Copyright (c) 2019 Paul Miller. |
| esbuild | Build-time tool for intentionally regenerating the vendored browser bundle; not required by normal Zig builds or browser runtime | MIT; `vendor/LICENSE-esbuild.txt` | Version and lockfile are under `web/vendor/`; only the esbuild license text is copied beside the vendored bundle as checked-in regeneration provenance. |

If future source or web distributions vendor additional third-party projects,
ship their full upstream license texts and notices alongside the vendored source
or deployed artifact.

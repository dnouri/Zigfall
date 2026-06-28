# Third-party notices

Zigfall's own project source is licensed as GPL-3.0-or-later; see `LICENSE`.
Third-party components keep their own licenses, and their upstream license files are authoritative.

| Component | Role | License | Notes |
| --- | --- | --- | --- |
| raylib-zig | Zig bindings and build integration for raylib | MIT | Copyright (c) 2020 Nikolas Wipper. |
| raylib | Windowing, graphics, and input library used through raylib-zig | zlib/libpng-style | Copyright (c) 2013-2026 Ramon Santamaria (@raysan5). |
| raygui | GUI helper dependency declared by raylib-zig; not used directly by the current app | zlib/libpng-style | Copyright (c) 2014-2026 Ramon Santamaria (@raysan5). |
| emsdk / Emscripten | Web build toolchain used for HTML/WASM builds | MIT for emsdk/Emscripten; downloaded toolchain components may carry additional notices | Not required for native desktop builds. |
| zemscripten | Zig/Emscripten helper referenced by raylib-zig's web support | MIT | Copyright (c) 2024 zig-gamedev contributors. |
| Trystero / @trystero-p2p | Vendored browser-only WebRTC transport bundle for future web online play | MIT | Copyright (c) 2021 Dan Motzenbecker. Includes a local Zigfall `pkt` reassembly cap patch documented in `web/vendor/README.md`. |
| @noble/secp256k1 | Vendored dependency inside the Trystero/Nostr browser bundle | MIT | Copyright (c) 2019 Paul Miller. See `web/vendor/`. |
| esbuild | Build-time tool for intentionally regenerating the vendored browser bundle; not required by normal Zig builds | MIT | Version and lockfile are under `web/vendor/`; license text is in `web/vendor/LICENSE-esbuild.txt`. |

If future source distributions vendor additional third-party projects, include their full upstream license texts and notices alongside the vendored source.

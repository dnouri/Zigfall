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

If future source distributions vendor any of these projects, include their full upstream license texts and notices alongside the vendored source.

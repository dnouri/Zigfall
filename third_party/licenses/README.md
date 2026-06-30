# Third-party license text snapshots

These files are source-controlled copies of license/notice texts for third-party
components that Zigfall builds against or may link into distributed native/web
artifacts. They are copied from the pinned dependency versions documented in
`build.zig.zon`, raylib-zig's pinned dependency manifest, and `web/vendor/`.
The Zig runtime/standard-library license snapshot comes from the installed Zig
0.16.0 distribution root `LICENSE`. The Emscripten compiler/runtime license
snapshot comes from the active SDK's `upstream/emscripten/LICENSE`; the emsdk
SDK-manager license is tracked separately as `LICENSE-emsdk.txt`. The raylib
external-component aggregate notice is copied from the pinned raylib package's
`src/external` source files.

The web build copies this directory to `zig-out/web/licenses/`; native builds
copy it to `zig-out/share/zigfall/licenses/`. Distributed artifacts therefore do
not depend on ignored Zig package caches for their core third-party license
texts. If a dependency pin changes, compare the upstream license files and
update these snapshots in the same change.

The Trystero browser bundle has its own license files under `web/vendor/`; those
are copied to `vendor/` in distributed legal bundles. Web artifacts also copy the
bundle and checksum next to those notices under `zig-out/web/vendor/`.

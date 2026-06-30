# Zigfall

**Play Zigfall in your browser: <https://dnouri.github.io/Zigfall/>**

Zigfall is a falling-block game with solo play, local two-player on one keyboard, and browser invite-link P2P. For online play, open the browser version, press `3` to host, copy the invite, and send it to another player. The match runs between the two browsers: Zigfall exchanges inputs, keeps both games deterministic, and verifies the result without a central game server.

The same Zig game core also runs as a native desktop build with solo play and local two-player on one keyboard. Rendering uses [raylib-zig](https://github.com/raylib-zig/raylib-zig); the rules live separately so the core mechanics can be tested without opening a window.

> [!IMPORTANT]
> Zigfall is an independent open-source project and is not affiliated with or endorsed by any game publisher or rights holder.

## Play online with an invite link

Open <https://dnouri.github.io/Zigfall/> in a browser. The host presses `3` to create an online room, then presses `C` to copy the invite URL. Send that link to the other player; opening a URL with `?join=<room>` puts the joiner into the match as player 2.

Online play is browser-only invite-link P2P. Native builds still do solo and local two-player, but they do not do online networking. The browser build uses public relays to find peers and WebRTC for the connection. Zigfall does not have accounts or matchmaking, and there is no lobby or central server running the match. It also does not bundle TURN, so some networks will not connect.

## What else is in there?

Solo play works on desktop and in the browser. Local two-player versus also works on one keyboard in both builds.

Browsers also keep a small local profile card. It has a nickname, a random local player ID, Local rating, and W-L-D. It is display-only metadata stored in that browser, not a trusted identity and not a global ranking. Completed online matches update the local stats only after both peers report matching verified results. Disconnects, desyncs, and unverified results do not count.

The board is 10x40, with 20 visible rows. Pieces come from a seven-bag randomizer with a five-piece queue. Hold, ghost, gravity, and lock delay are all in. Rotation has SRS-style kicks plus 180. Clears track T-spins, back-to-back, combos, and perfect clears. Versus play adds garbage.

## Controls

| Action | Key(s) |
| --- | --- |
| Solo mode | `1` |
| Local two-player mode | `2` |
| Host browser online match | `3` |
| Copy invite while hosting online | `C` |
| Move | Left / Right |
| Soft drop | Down |
| Hard drop | Space |
| Rotate clockwise | `X` or Up |
| Rotate counter-clockwise | `Z` |
| Rotate 180 degrees | `A` |
| Hold | `C` or Left Shift |
| Pause / resume | `P` |
| Restart local game | `R` |
| Close desktop window | Esc |

In an online match both players use that single-player control set. `R` is deliberately a no-op online for now because there is no rematch flow yet.

<details>
<summary>Local two-player controls</summary>

| Action | Player 1 | Player 2 |
| --- | --- | --- |
| Move | `A` / `D` | Left / Right |
| Soft drop | `S` | Down |
| Hard drop | Space | Enter |
| Rotate clockwise | `W` | Up |
| Rotate counter-clockwise | `Q` | `.` |
| Rotate 180 degrees | `E` | `/` |
| Hold | Left Shift | Right Shift |

`P` pauses or resumes, `R` restarts, and Esc closes the desktop window.
</details>

## Current limitations

- Online play is browser-only. Native builds do not support online networking.
- There are no accounts or matchmaking. There is no global leaderboard or central match server.
- There is no rematch flow yet.
- Zigfall does not bundle TURN or a controlled signaling service. Browser matches depend on public relays, WebRTC/ICE, and the players' networks.
- Local profile cards and Local rating are browser-local and display-only. They are not trusted. Verified completed matches update local W-L-D; disconnects, desyncs, and unverified results do not.

## How it works

`src/game.zig` contains the deterministic game rules and can be unit-tested without opening a window. `src/main.zig` is the raylib-facing shell for native and Emscripten builds. The split is intentional: rendering and input should be boring wrappers around a game state that tests can drive directly.

Native and web builds share the Zig core. The web artifact adds a custom shell and small JavaScript helpers. Those helpers handle invite links, browser-local profiles, and Trystero/WebRTC transport. They are copied as local static files by `build.zig` and loaded before WASM `main` starts.

For online duels, the host is setup authority for the room and seed, then both browsers run a conservative lockstep match by exchanging inputs. Periodic state hashes are compared to catch desyncs. Match results are only applied to the local profile when both peers finish and the reported result validates. Extra peers are treated as a busy-room condition rather than silently joining the match.

## Requirements

- Zig 0.16.0
- Network access for the first pinned dependency fetch; dependencies are recorded in `build.zig.zon`
- The first wasm build may also fetch and cache the Emscripten SDK/toolchain through the pinned Zig/Emscripten dependency flow
- Optional Node.js for JavaScript checks or intentional vendor-bundle regeneration

No local raylib-zig checkout is required. Normal Zig native/web builds and deploys do not run npm; native builds also do not need Trystero or browser APIs.

## Build, run, and test

Fetch dependencies, format, test, and build the native desktop app:

```sh
zig build --fetch=needed
zig fmt build.zig build.zig.zon src/*.zig
zig build test
zig build
zig build -Doptimize=ReleaseFast
zig build run
```

Native builds install the executable to `zig-out/bin/zigfall` (`zig-out/bin/zigfall.exe` for Windows targets). They also install the legal bundle under `zig-out/share/zigfall/`. That bundle contains the project license, third-party notices, tracked license snapshots, and the shared browser-vendor notice files.

When a display is available, this is a quick smoke test:

```sh
timeout 3 zig build run
```

Cross-target builds use the same pinned dependency set. For example:

```sh
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
```

Linux cross targets may also need a target sysroot or system libraries for raylib's OpenGL/X11 backend.

<details>
<summary>Maintainer CI/deployment checks</summary>

These mirror the checks that are useful before publishing a Pages build:

```sh
zig fmt build.zig build.zig.zon src/*.zig --check
zig build test --summary all
zig build --summary all
zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall --summary all
for file in web/zigfall_transport.mjs web/zigfall_transport_emscripten.js \
  web/zigfall_invite.mjs web/zigfall_invite_emscripten.js \
  web/zigfall_profile.mjs web/zigfall_profile_emscripten.js \
  web/vendor/patch-trystero-bundle.mjs web/vendor/trystero-nostr.bundle.mjs \
  tools/test_trystero_pkt_limit.mjs tools/test_zigfall_transport_adapter.mjs \
  tools/test_zigfall_invite.mjs tools/test_zigfall_profile.mjs; do
  node --check "$file"
done
node tools/test_trystero_pkt_limit.mjs
node tools/test_zigfall_transport_adapter.mjs
node tools/test_zigfall_invite.mjs
node tools/test_zigfall_profile.mjs
(cd web/vendor && sha256sum -c trystero-nostr.bundle.mjs.sha256)
```

The Pages workflow also verifies the post-build web artifact manifest before upload.
</details>

## Web build and deployment

Build the Emscripten HTML/WASM output with:

```sh
zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall
```

To launch it with Emscripten's `emrun` helper:

```sh
zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall run
```

The generated web files are installed to `zig-out/web/`. The runtime pieces are `zigfall.html`, `zigfall.js`, `zigfall.wasm`, the three `zigfall_*.mjs` helpers, and the vendored Trystero bundle. The bundle checksum and vendor notices are copied with it. The same legal bundle is copied there too.

The GitHub Pages workflow prepares `zig-out/web` for upload. It creates `index.html`, adds `.nojekyll`, verifies the Trystero bundle checksum, and checks the runtime/legal file manifest.

The production page imports bundled local JavaScript files, not a runtime CDN. Normal native `zig build` does not use Node or npm. It also does not load Trystero or browser APIs. After Zig dependencies have been fetched, native builds do not need network access. Runtime online play still depends on browser network access, public relays, and WebRTC/ICE/NAT behavior.

The web shell also installs a keyboard handler so Space, Enter, arrow keys, and Slash (`/`) do not scroll the page or open quick-find while the game is active. Focused links and form controls are left alone.

## Origin

The original single-player/native Zig/raylib-zig version was created mostly from one GPT-5.5 prompt in Pi. That baseline is preserved in Git history at [`cd6e23a`](https://github.com/dnouri/Zigfall/commit/cd6e23a757e0ba4f0dbc3fd5c5c8f23ea4a902a5).

Browser multiplayer came after that, along with invite links, profile cards, deployment packaging, and the checks around them.

<details>
<summary>The original prompt</summary>

```text
I want you to build a ### clone, using ~/co/raylib and
specifically ~/co/raylib-zig/

I want your ### clone to be technically advanced to the point
where it could be used for tournaments: think FPS, T-spins,
perfect clears, and combos.

Divide your work up into logical units and delegate to subagents
for researching ~/co/raylib/ and ~/co/raylib-zig/

Then create a plan with phases. Then delegate each phase to a
"fresh context" subagent, with useful quality gates. Make sure
every subagent uses our best practices, and that they are able to
actually test their results and do quality engineering as well,
before they handoff. After each handoff, send a subagent to
review the code, and look for simplification opportunities, before
you hand over to the next subagent with "fresh context" to work on
the next phase. Do not stop until you are done and satisfied with
the implementation. Make sure you delegate and give agency and
useful context to subagents such that they can work efficiently
and you keep the overview of the project without losing focus.
```
</details>

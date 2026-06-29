# Zigfall

**Play Zigfall in your browser: <https://dnouri.github.io/Zigfall/>**

Zigfall is an ambitious falling-block puzzle game written in Zig with
[raylib-zig](https://github.com/raylib-zig/raylib-zig).  The game
keeps deterministic rules in `src/game.zig` so mechanics can be
unit-tested without opening a window, while `src/main.zig` handles the
raylib UI for desktop and web builds.

> [!IMPORTANT]
> Zigfall is provided for non-commercial educational and research purposes only.  It is independent and is not affiliated with or endorsed by any game publisher or rights holder.

Zigfall (including this documentation) has been created mostly with a
single prompt to GPT-5.5, using the Pi coding harness.  The prompt was
as follows:

    I want you to build a ### clone, using ~/co/raylib and
    specifically ~/co/raylib-zig/

    I want your ### clone to be technically advanced to the point
    where it could be used for tournaments: think FPS, T-spins,
    perfect clears, and combos.

    Divide your work up into logical units and delegate to subagents
    for researching ~/co/raylib/ and ~/co/raylib-zig/

    Then create a plan with phases.  Then delegate each phase to a
    "fresh context" subagent, with useful quality gates.  Make sure
    every subagent uses our best practices, and that they are able to
    actually test their results and do quality engineering as well,
    before they handoff.  After each handoff, send a subagent to
    review the code, and look for simplification opportunities, before
    you hand over to the next subagent with "fresh context" to work on
    the next phase.  Do not stop until you are done and satisfied with
    the implementation.  Make sure you delegate and give agency and
    useful context to subagents such that they can work efficiently
    and you keep the overview of the project without losing focus.

## Controls

Mode hotkeys:

- `1`: switch to one-player (no-op if already active; use `R` to restart)
- `2`: switch to local two-player versus (no-op if already active; use `R` to restart)
- `3`: in the browser, create a web online invite room as host/P1; on native builds this shows a web-only unsupported message

One-player controls are unchanged:

- Left / Right: move piece, with DAS/ARR repeat
- Down: soft drop
- Space: hard drop
- X or Up: rotate clockwise
- Z: rotate counter-clockwise
- A: rotate 180 degrees
- C or Left Shift: hold
- P: pause / resume
- R: restart
- Esc: close the desktop window

Local two-player controls:

- Player 1: A/D move, S soft drop, Space hard drop, W rotate clockwise, Q rotate counter-clockwise, E rotate 180 degrees, Left Shift hold
- Player 2: Left/Right move, Down soft drop, Enter hard drop, Up rotate clockwise, `.` rotate counter-clockwise, `/` rotate 180 degrees, Right Shift hold
- Global: P pauses/resumes, R restarts, Esc closes the desktop window

Web online invite controls:

- Host: press `3` in the browser to create a room/link as P1, then press `C` to copy the invite URL.
- Joiner: opening a `?join=<room>` link auto-enters online join mode as P2.
- Gameplay uses one local control set: Left/Right/Down, Space hard drop, X or Up rotate clockwise, Z counter-clockwise, A 180, Left Shift hold.
- P is deterministic pause/resume. R is a graceful no-op online because rematch/restart is not implemented yet.
- If remote inputs stop arriving, a "Waiting for opponent input..." notice appears before the match resumes or disconnects.
- Desyncs, disconnects, extra-peer busy rooms, and match results are displayed; a local result stays "verifying" until the peer's matching result validates, and disconnect/unverified results are not counted as wins/losses.

Native online networking is not supported; native versus play is local on one keyboard.

## Game mechanics included

- 10x40 matrix with 20 visible rows and hidden spawn rows
- Seven-bag randomizer, five-piece next queue, hold once per active piece
- Ghost piece, hard drop, soft drop, gravity levels, lock delay, and move-reset cap
- SRS-style wall kicks for JLSTZ, I, and O pieces, plus a simple 180 kick set
- T-spin full/mini detection, back-to-back, combo counter, perfect clear detection
- Line-clear scoring with soft/hard drop points and line-output metadata for display
- Pause, restart, game-over handling, local two-player versus, web invite-link P2P matches, and status panels for score, level, combo, B2B, last clear, garbage, and output

## Requirements

- Zig 0.16.0
- Network access for the first dependency fetch; pinned dependencies are recorded in `build.zig.zon`

No local raylib-zig checkout is required.

## Build, run, and test

Fetch pinned dependencies, format the source, then build and test the native desktop app:

```sh
zig build --fetch=needed
zig fmt build.zig src/*.zig
zig build test
zig build
zig build -Doptimize=ReleaseFast
zig build run
```

Native builds install the executable to `zig-out/bin/zigfall` (`zig-out/bin/zigfall.exe` for Windows targets). For a short smoke test when a display is available:

```sh
timeout 3 zig build run
```

## Cross-target builds

Cross-target builds use the same pinned dependency set. For example, to build a Windows executable:

```sh
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
```

The generated executable is installed under `zig-out/bin/`. Linux cross targets may also need a target sysroot or system libraries for raylib's OpenGL/X11 backend.

## Web build

Build the Emscripten HTML/WASM output with:

```sh
zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall
```

The generated web files are installed to `zig-out/web/`:

- `zigfall.html`
- `zigfall.js`
- `zigfall.wasm`
- `zigfall_transport.mjs`
- `zigfall_invite.mjs`
- `vendor/trystero-nostr.bundle.mjs` plus concise vendor license/readme files

The web build uses a custom Zigfall shell with a GitHub link and a
keyboard handler that keeps Space, Enter, the arrow keys, and Slash (`/`,
Player 2's 180-rotate key) from scrolling the browser page or opening
quick-find while the game is active, without blocking focused links or form
controls.

The web artifact also includes Trystero/Nostr transport and invite-link helpers
for casual invite-link online matches. They are packaged as local static
JavaScript copied by `build.zig`; the shell imports them during Emscripten
`preRun` before WASM `main` starts. Production pages do not import Trystero from
a runtime CDN, and native `zig build` does not require Node, npm, Trystero,
browser APIs, or network access. Runtime online play still uses Trystero's
default Nostr/public WebRTC signaling and ICE/STUN behavior, so browser network
access is needed for the online path. The transport adapter selects the first
room peer as the single 1v1 opponent, targets sends to that peer, and reports a
busy state while extra peers are present. It is observable in-game through the
small web-only transport footer and manually from the browser console:

```js
ZigfallTransport.connect("zigfall-phase5-local")
ZigfallTransport.peerCount()
ZigfallTransport.send(Uint8Array.from([
  0x01, 0x02, 0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01, 0x00, 0x78, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x09, 0x00, 0x22, 0x00, 0x04, 0x06,
]))
Array.from(ZigfallTransport.poll() ?? [])
```

For the playable UI flow, open one built web tab and press `3`, copy the link
with `C`, then open that link in a second tab. The host is P1/setup authority,
the join-link opener is P2, and both peers use fixed-delay conservative lockstep
with periodic state hashes. Restart/rematch, matchmaking, accounts, profiles,
ratings, and native networking are not implemented.

The lower-level transport and invite seams are also available from the browser
console:

```js
const room = ZigfallInvite.createHostRoom()
ZigfallInvite.joinUrl(room)
ZigfallInvite.readInitialJoinRoom()
```

These console helpers are mostly for debugging; normal online play should use
the in-game `3`/`C` invite flow or a `?join=<room>` URL.

To launch with Emscripten's `emrun` helper:

```sh
zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall run
```

## License and third-party notices

Zigfall's project source is licensed under GPL-3.0-or-later; see
`LICENSE`.  Third-party dependency notices are summarized in
`THIRD_PARTY_NOTICES.md`.

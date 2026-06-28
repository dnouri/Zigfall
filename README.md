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

Native online networking is not supported; versus play is local on one keyboard for now.

## Game mechanics included

- 10x40 matrix with 20 visible rows and hidden spawn rows
- Seven-bag randomizer, five-piece next queue, hold once per active piece
- Ghost piece, hard drop, soft drop, gravity levels, lock delay, and move-reset cap
- SRS-style wall kicks for JLSTZ, I, and O pieces, plus a simple 180 kick set
- T-spin full/mini detection, back-to-back, combo counter, perfect clear detection
- Line-clear scoring with soft/hard drop points and line-output metadata for display
- Pause, restart, game-over handling, local two-player versus, and status panels for score, level, combo, B2B, last clear, garbage, and output

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

The web build uses a custom Zigfall shell with a GitHub link and a
keyboard handler that keeps Space, Enter, the arrow keys, and Slash (`/`,
Player 2's 180-rotate key) from scrolling the browser page or opening
quick-find while the game is active, without blocking focused links or form
controls.

To launch with Emscripten's `emrun` helper:

```sh
zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall run
```

## License and third-party notices

Zigfall's project source is licensed under GPL-3.0-or-later; see
`LICENSE`.  Third-party dependency notices are summarized in
`THIRD_PARTY_NOTICES.md`.

# Zigfall Development Plan

This project is a Zig + raylib-zig desktop falling-block puzzle using pinned raylib-zig dependencies declared in `build.zig.zon`.

The design splits deterministic game rules from rendering. The rules should be testable with `zig build test` without opening a window. The raylib app should be a thin shell over that logic.

## Shared standards for every phase

- Preserve fast feedback: add or update tests for rule behavior before broadening the implementation.
- Keep the shape simple: prefer clear structs/functions over framework-like abstractions.
- Run `zig fmt`, `zig build test`, and `zig build` before handoff.
- If a graphical runtime check is possible, run `timeout 3 zig build run` only after the non-window checks pass; report if the environment cannot open a display.
- Handoff must include changed files, checks run with results, and remaining risks.

## Phase 1 — Project scaffold and deterministic falling-block core

Build a clean Zig project in this repository using pinned raylib-zig dependencies. Add:

- `build.zig` and `build.zig.zon` with build, run, and test steps.
- `src/main.zig` for the raylib window shell.
- `src/game.zig` for deterministic game state and tests.
- Board dimensions 10x40 with visible top 20 rows and hidden spawn rows.
- Seven tetrominoes with 7-bag RNG, hold, next queue, spawn, collision, lock, line clear, and game-over basics.
- SRS spawn geometry and rotation offsets enough for normal play; advanced T-spin details may land in Phase 2.

Quality gates: unit tests for bag coverage, collision/locking, line clear, hold once per piece, and game-over basics.

## Phase 2 — Advanced mechanics and scoring

Extend `src/game.zig` with advanced deterministic behavior:

- SRS wall kicks for JLSTZ, I, and O.
- T-spin and mini T-spin detection.
- Back-to-back, combo counter, perfect clear detection.
- Line-clear scoring and line-output metadata suitable for status display.
- Lock delay/move reset rules with frame-based stepping.

Quality gates: focused tests for wall kicks, T-spin single/double/triple, mini T-spin if feasible, combo sequence, back-to-back, perfect clear, and scoring.

## Phase 3 — Input and frame stepping

Build a responsive input layer in `main.zig` while keeping rules deterministic:

- 60 FPS fixed-step loop.
- DAS/ARR horizontal movement.
- Soft drop, hard drop, hold, clockwise/counter-clockwise/180 rotation.
- Pause/restart controls.
- Ghost piece support from game logic.
- Expose frame/FPS, piece/queue, combo/B2B/T-spin/perfect-clear state for UI.

Quality gates: unit tests for frame stepping where possible; manual or headless runtime smoke if display works.

## Phase 4 — Rendering and player-facing polish

Render a clear playable falling-block game:

- Board, hidden-row boundary, locked cells, active piece, ghost piece.
- Hold and next queue panels.
- Score, lines, level/speed, combo, B2B, last clear, T-spin/perfect clear labels.
- FPS display and concise controls help.
- Game-over and pause overlays.

Quality gates: `zig build test`, `zig build`, format, plus runtime smoke if possible.

## Phase 5 — Final hardening and documentation

Tighten code and docs:

- Review for simplification, duplicate logic, and explicit naming.
- Update `README.md` with build/run/test commands and controls.
- Ensure all quality gates pass.
- Leave no dead files or unrelated changes.

Quality gates: clean build/test/fmt, release build `zig build -Doptimize=ReleaseFast`, and final smoke attempt.

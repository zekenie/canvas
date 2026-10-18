# Board panning/zooming performance

Claude Code session `dbc0c837-c693-4bf6-86eb-4cd88818aa24`, 2026-09-29 02:24 to 2026-10-01 12:48 UTC, on `main`, `smooth-camera`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-09-29 02:24] USER:
panning and zooming around the board has become choppy. diagnose then hand to sonnet sub-agents to implement and verify

[2026-09-29 02:25] ASSISTANT:
Diagnosing the choppy pan/zoom now: reading the camera and frame-drawing paths in the core and CanvasUI before profiling.

[2026-09-29 02:26] ASSISTANT:
Running the release benchmark in the background while I read the per-frame drawing code.

[2026-09-29 02:27] ASSISTANT:
Still diagnosing: reading how the window hosts the canvas (SwiftUI overlay, toolbar, inspector) while the benchmark builds.

[2026-09-29 02:28] ASSISTANT:
Core benchmark looks healthy except text-heavy frames just above 35% zoom. Now checking whether the app is running so I can profile real panning, not just the headless benchmark.

[2026-09-29 02:29] ASSISTANT:
Found your board file (~/Documents/board.canvasboard) and that your window is ~1710×1073 pt (a scaled Retina mode, so the canvas is bigger than the benchmark's). Checking what's on the board.

[2026-09-29 02:31] ASSISTANT:
Setting up the scratch clone for the self-driving probe.

[2026-09-29 02:33] ASSISTANT:
The worktree sandbox refused a compound command; splitting it into plain steps.

[2026-09-29 02:34] ASSISTANT:
Probe built. Running it now (about 15 s of on-screen panning/zooming, sampled with `sample`).

[2026-09-29 02:35] ASSISTANT:
Big finding: the canvas's own draw takes under 1 ms, yet each pan step keeps the main thread busy about 400 ms (12 frames in 5 s). Reading the sample to see where that time goes.

[2026-09-29 02:37] ASSISTANT:
Rebuilt. Running four unsampled variants back to back (about 1 minute; the probe window will flash up four times).

[2026-09-29 02:43] ASSISTANT:
The probe for the first variant has sat idle for 5 minutes at 0% CPU, probably because its window got covered and the display link paused. Killing it and adding a watchdog plus an occlusion check.

[2026-09-29 02:56] ASSISTANT:
The old grid is exactly `DotGrid.fillEllipses`, so the fix's on-screen options are clear. Looking at the existing grid tests and CanvasUITests so I can give the implementing agent precise pointers.

[2026-09-29 02:57] AGENT Fix dot grid clip stall:
You're fixing a performance regression in a native macOS app (Swift 6, AppKit + SwiftUI): panning and zooming the canvas became choppy. Work only in the git worktree at /Users/zekenie/code/native-canvas/.claude/worktrees/smooth-camera (branch `smooth-camera`, already checked out). Never touch /Users/zekenie/code/native-canvas itself (the main checkout), never touch anything under /private/tmp (a scratch clone lives there), never push or merge. Read CLAUDE.md in the worktree first: it holds the build/test commands and the project's rules (audit, layers, no warnings, doc voice). Key points: build with `./build.sh` (never `swift build`), test with `./test.sh` (`TEST_FILTER=substring ./test.sh` for a subset), benchmark with `./build.sh bench`. Tests can't use `@testable` (the audit forbids it): tests reach internals only through `public` or `@_spi(Host)` API, as the existing DEBUG counter `CanvasEditor.gridTilesMade` does. Every `Suite` must be passed to `runTests` in its target's main.swift.

## What's already diagnosed (don't redo it)

On this machine (macOS 26), AppKit doesn't give a layer-backed view's `draw(_:)` a bitmap: it hands it a CGDisplayList-recording context (`bitsPerComponent == 0`, `colorSpace == nil`). While the window is on screen and the display is awake, Core Animation renders that display list on the GPU (the `CA::CG::AccelQueue`), and the main thread waits for it in the CA commit (`CABackingStoreGetFrontTexture`). With the window unshown or the display aslee […6316 more chars]

[2026-09-29 02:59] ASSISTANT:
Probe rebuilt with the generated board. Quick headless sanity check that it loads and runs.

[2026-09-29 03:00] ASSISTANT:
Watcher armed. Writing the on-screen A/B script for when you're back: welcome board and a 1,000-note board, current grid vs the fix vs the old ellipses, at several zooms.

[2026-09-29 03:00] ASSISTANT:
Here's where things stand: I've found the cause, and the fix is being built. Checking it on screen needs you back at the Mac.

**Cause.** The dot grid is now drawn from image tiles (commit a51ab39). Each frame it clips to one rectangle per dot, which is thousands of rectangles, then draws dozens of tile copies through that clip. On this macOS, AppKit doesn't give the canvas a plain bitmap to draw into. It records the drawing, and while the window is on screen Core Animation replays it on the GPU. That renderer rebuilds the whole clip, one rectangle at a time, for every tile copy.

**Evidence.** I built a throwaway copy of the app that pans and pinches its real window by itself, and sampled it while it ran. On the six-note welcome board, the canvas's own drawing took under 1 ms. The main thread still waited about 415 ms per frame for Core Animation, so only 12 frames were drawn in 5 seconds of panning. Core Animation's render thread spent 2297 of 2298 samples building that clip, and pinching showed the same thing.

**Why nothing caught it.** The benchmarks draw into plain bitmaps, where that clip is cheap. Headless windows, and any window while the display is asleep, get the slower-but-sane CPU path instead: about 8–12 ms a frame. So the problem only appears on screen.

**Fix (a Sonnet agent is building it now in the `smooth-camera` worktree).** Keep the clip only when drawing into a bitmap, where it's a big win. When drawing on screen, draw the tile copies without it. The pixels are identical, because the clip only skipped transparent pixels. The agent is also adding tests that pin both behaviours, updating CLAUDE.md, and running `./test.sh` and the benchmark.

**Needs you.** Your Mac locked and its display went to sleep at 21:35, right after my first probe run, and the problem can't be measured without the display on. When you're back, reply "go" and I'll run about 3 minutes of on-screen checks. A probe window pans and zooms itself and doesn't take the keyboard. It compares the current grid, the fix, and the old dot drawing on the welcome board and on a 1,000-note board, and it also looks for similar trouble in the zoomed-out drawing on big boards.

**Also found.** The frame benchmarks run at 1× in a 1200×800 view. At your real canvas size (1450×1021 at 2×), a 1,000-note board at 100% costs about 16–20 ms a frame even on the CPU path, so the benchmarks understate Retina costs. I'll come back to that once the grid is confirmed fixed.

===== [2026-09-29 03:14] commit written: Clip the dot grid's tile copies only into a bitmap: on screen the clip cost some 400 ms a frame =====

[2026-09-29 03:17] ASSISTANT:
The agent committed the fix (bde8f11), and tests and benchmark pass. Reviewing its diff before anything else.

[2026-09-29 03:17] ASSISTANT:
The source change is clean and minimal. Checking the CLAUDE.md and test changes.

[2026-09-29 03:18] ASSISTANT:
The probe now runs the agent's exact fix, with a switch to force main's clip for comparison. On the CPU fallback path (display asleep) the fix costs more, about 17 vs 8 ms at 100%. That path only runs when nothing is on screen, so the number that matters is the on-screen one.

The agent's work (commit bde8f11 on `smooth-camera`):
- **Fix:** on screen, the dot grid's tile copies are now drawn without the clip; bitmaps (tests, benchmarks) keep it.
- **Tests:** the unclipped grid matches the clipped one byte for byte across many zooms, layouts and dark mode. A new CanvasUITests check confirms that AppKit's context isn't a bitmap, so the canvas drew unclipped.
- **Results:** full `./test.sh` passes, and the benchmark's empty-board frames are unchanged at 0.9–1.7 ms. I've read the diff; it's small and clean.

Not done yet:
- **On-screen check:** this is the proof the choppiness is gone, and it needs your display awake. I have a watcher that tells me when your Mac is unlocked. The run is about 3 minutes: a probe window pans and zooms itself without taking the keyboard, on the welcome board and a 1,000-note board, comparing the fix, main's grid and the old ellipse grid. Reply "go" when you're back and I'll run it.
- **Code review:** I'll run it once the on-screen numbers settle whether any more code changes are needed, then report and wait for your go-ahead before anything goes to main.

[2026-09-29 03:30] NOTICE:
background task done: Monitor event: "screen unlocked and display awake (for on-screen verification)"

[2026-09-29 03:30] ASSISTANT:
I've re-armed the unlock watcher. Your Mac has been locked with the display asleep since 21:35, so nothing has changed.

The fix is committed on `smooth-camera` (bde8f11) and passes `./test.sh` and the benchmark. It hasn't been checked on screen yet, which is the only place the choppiness shows. Reply "go" when you're back at the Mac and I'll run the roughly 3-minute on-screen comparison, then the code review.

[2026-09-29 04:00] NOTICE:
background task done: Monitor event: "screen unlocked and display awake (for on-screen verification)"

[2026-09-29 04:00] ASSISTANT:
I've stopped re-arming the unlock watcher. I won't run anything on screen without your OK, so it wasn't adding anything.

The fix is ready on `smooth-camera` (commit bde8f11) and passes `./test.sh` and the benchmark, but it isn't verified on screen yet. When you're back at the Mac, reply "go" and I'll run the roughly 3-minute on-screen check (the welcome board and a 1,000-note board, before and after), then the code review. After that I'll report and wait for your go-ahead before anything goes to main.

[2026-09-29 11:29] USER:
Can you explain why this happened

[2026-09-29 11:30] ASSISTANT:
The regression came from the dot-grid commit (a51ab39, last night). It was tuned and measured in one drawing path, and the app on screen uses a different one.

**What changed.** The grid used to be one path with an ellipse per dot, which cost 3–8 ms a frame in the benchmark. a51ab39 replaced it with small tile images of dots, copied across the view. To skip each tile's transparent pixels, the copies are drawn through a clip made of one rectangle per dot. In your window that's about 2,600 rectangles at 100% and about 5,000 at 70%. When drawing into a plain CPU bitmap, Core Graphics handles that clip cheaply, and the grid dropped to about 1 ms in the benchmark.

**Why that's slow in the app.** On this macOS, AppKit doesn't give `CanvasView.draw(_:)` a bitmap. It records the drawing as a list of commands. While the window is on screen and the display is awake, Core Animation replays that list on the GPU, and the main thread waits for it before each frame can go out. That replayer handles clips differently: for every image drawn under a clip, it rebuilds the clip's area by merging the rectangles one at a time. Dozens of tile copies, each re-merging thousands of rectangles, every frame, came to about 400 ms a frame. The sample showed exactly that: the canvas's own drawing took under 1 ms, and nearly all the rest was Core Animation merging those rectangles.

**Why it showed up as choppy panning and zooming.** A still canvas doesn't redraw. Every pan or zoom step redraws the whole canvas, grid included, so each step paid the 400 ms.

**Why nothing caught it:**
- The benchmarks and tests draw into bitmaps, where the clip really is cheap. By that measure, the tiles commit was a big win.
- Even a real `CanvasView` in a test window doesn't hit it. An unshown window, or any window while the display is asleep, gets its drawing replayed on the CPU instead, where the clip is fine. I checked: forcing Core Animation's accelerated drawing on an unshown window changed nothing.
- So only the app, on screen, on an awake display, pays the cost, and the tiles commit was never measured there.

**The fix (bde8f11).** Bitmaps keep the clip, where it's a big win. The on-screen path draws the copies without it, which produces the same pixels, since the clip only ever skipped transparent ones. The agent's commit also added a line to CLAUDE.md warning that benchmarks can't see this path.

When you're at the Mac, reply "go" and I'll run the roughly 3-minute on-screen check that confirms the choppiness is gone.

[2026-09-29 11:34] USER:
Go

[2026-09-29 11:34] ASSISTANT:
The on-screen check is armed but hasn't started: your Mac is still locked with the display asleep. It starts 5 seconds after you unlock and takes about 3 minutes.

A probe window will pan and zoom itself for four runs:
- the welcome board with the fix;
- the welcome board with the old ellipse grid;
- a 1,000-note board with the fix, sampled while zoomed out;
- a short run of main's current grid, as the "before".

The window doesn't take the keyboard, but please don't click on it or switch Spaces until it closes. If it gets covered, it stops drawing and the numbers mean nothing. I'll post the results when it finishes.

[2026-09-29 11:52] NOTICE:
background task completed: Background command "Run the on-screen comparison once the screen is unlocked" completed (exit code 0)

[2026-09-29 11:53] ASSISTANT:
The review found no bugs. Adding the on-screen results to the commit message so the branch is ready to land.

[2026-09-29 11:53] COMMIT MESSAGE FILE edit_msg.py:
p = '/private/tmp/claude-501/-Users-zekenie-code-native-canvas/dbc0c837-c693-4bf6-86eb-4cd88818aa24/scratchpad/msg.txt'
s = open(p).read()
old_trailer = "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
assert old_trailer in s
body = s[:s.index(old_trailer)].rstrip()
body += """

Checked on screen, in the app's own window (1710 × 1073, inspector and minimap showing), with a
throwaway copy of the app that pans and ⌘-scroll-pinches its canvas once a display frame at 100%,
50%, 36%, 30% and 10%: every frame drawn at 60 Hz and none late, on the welcome board and on a board
of 1,000 notes, the main thread busy 2 to 9 ms a frame; the same run with the grid always clipped, as
before, drew a frame every 0.5 to 1.8 s. The path of ellipses the tiles replaced is as smooth there
(3 to 6 ms), which is why panning was smooth before a51ab39; the unclipped tiles are kept for the
bitmaps' sake, where the clip is what makes the grid cheap.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
"""
open(p, 'w').write(body)
print("ok")

[2026-09-29 11:53] GIT:
git commit --amend -q -F /private/tmp/claude-501/-Users-zekenie-code-native-canvas/dbc0c837-c693-4bf6-86eb-4cd88818aa24/scratchpad/msg.txt && git log -1 --format='%h %s' && git log -1 --format=%B | tail -12

[2026-09-29 11:53] ASSISTANT:
The fix works on screen: panning and zooming run at a steady 60 fps again, and the code review found no bugs. It's one commit, 3a88682 on `smooth-camera`, and it hasn't gone to main yet.

In the app's own window (inspector and minimap showing), with a probe that pans and pinches once per display frame at 100%, 50%, 36%, 30% and 10%:

| Board | Grid | Frames drawn | Late frames | Main-thread work per frame |
|---|---|---|---|---|
| Welcome | fix | all, at 60 fps | 0 | 2–7 ms |
| 1,000 notes | fix | all, at 60 fps | 0 | 2.5–9 ms |
| Welcome | old ellipse grid | all, at 60 fps | 0 | 3–6 ms |
| Welcome | main as it is now | one every 0.5–1.8 s | nearly all | 0.8–3.2 s |

Nothing else slow showed up on screen, including the zoomed-out drawing on the 1,000-note board.

The fix keeps drawing the grid from tiles, but the tile copies skip the clip on screen. That keeps last night's benchmark gains, where the clip is what makes the grid cheap. The old ellipse grid is just as smooth on screen, which is why panning was fine before a51ab39.

**Trade-off:** when the display is asleep, the drawing is replayed on the CPU instead, and there the fix costs about 17 ms a frame versus 8 ms with the clip. Nothing is watching the screen then, so it shouldn't matter.

The benchmark's frame tests run at 1× in a 1200×800 view, much smaller than your 2× canvas, so they understate real costs. That's worth a follow-up, separately.

Say "land it" and I'll rebase on main, run `./test.sh`, fast-forward main, and remove the worktree.

[2026-09-29 12:21] USER:
land it

[2026-09-29 12:21] GIT:
git log -1 --oneline main && git status --short && git rebase main 2>&1 | tail -2 && git log --oneline -3

[2026-09-29 12:21] ASSISTANT:
Main hasn't moved, so no rebase was needed. Running the full test suite before merging.

[2026-09-29 12:22] GIT:
git status --short && git log -1 --oneline && git merge --ff-only smooth-camera 2>&1 | tail -2 && git log -1 --oneline

[2026-09-29 12:22] WRITE /Users/zekenie/.claude/projects/-Users-zekenie-code-native-canvas/memory/onscreen-frame-probe.md:
---
name: onscreen-frame-probe
description: "How to measure real on-screen frame cost: a throwaway self-driving copy of the app, since benchmarks and headless windows take a different drawing path"
metadata:
  type: reference
---

On macOS 26, `CanvasView.draw` records a display list. Core Animation renders it on the GPU (`CA::CG::AccelQueue`) only while the window is on screen and the display awake. Unshown windows, and any window while the display sleeps or the Mac is locked, replay it on the CPU instead. Forcing `drawsAsynchronously` or `acceleratesDrawing` on an unshown window changes nothing. So `./build.sh bench` and every test miss on-screen-only costs. On 2026-09-29 the tiled grid's many-rect clip took about 400 ms a frame on screen and about 8 ms in a headless window.

**How to apply:** for choppiness or any drawing-performance question, measure on screen. Use a scratch clone and give its app its own bundle id in build.sh's Info.plist. Add a `CANVAS_PROBE` mode that opens a board and orders the window front without activating the app. It then drives synthesized scroll events (⌘ held to zoom) from `canvas.displayLink` once a frame, and reports frame gaps and main-thread busy time from a run-loop observer. Run it with `-ApplePersistenceIgnoreState YES`, or it restores the last window and never starts, and run `/usr/bin/sample` alongside it. The display must be awake and the Mac unlocked: check `CGSessionCopyCurrentDictionary`'s `CGSSessionScreenIsLocked` and `CGDisplay […122 more chars]

[2026-09-29 12:23] ASSISTANT:
It's on main as 3a88682. `./test.sh` passed before the merge, and the worktree and branch are removed.

I also saved a note on how to measure on-screen frame costs, since the benchmarks and headless tests can't see them.

To try it in your own copy, quit any running copy of the app first, then:

```bash
./build.sh && open build/InfiniteCanvas.app
```

[2026-10-01 12:48] NOTICE:
background task stopped: 2 background shell command tasks didn't finish before the previous session ended. Task ids: bfr7p5dcf, bk51636h7.

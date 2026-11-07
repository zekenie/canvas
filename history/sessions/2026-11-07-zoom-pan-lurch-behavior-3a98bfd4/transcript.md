# Zoom pan/lurch behavior

Claude Code session `3a98bfd4-e201-48cc-ac56-23d479652c35`, 2026-11-07 04:12 to 2026-11-07 12:55 UTC, on `claude/zoom-pan-lurch-bug-3981d5`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-11-07 04:12] USER:
when you zoom in and out with plus and minus, the zoom is like weirdly, it takes a weird path on the z-axis. It's not like you stay centered and zoom in and out as if you were just using your scroll wheel. It's like you kind of lurch to the left and then to the right again or something. Up and down, I don't know.

[2026-11-07 04:16] ASSISTANT:
Now the fix. The animation will move the visible world rectangle's edges in straight lines, as tldraw does, and the zoom commands will zoom around the middle of the visible part.

[2026-11-07 04:16] ASSISTANT:
Now the docs that describe the zoom's center and its easing: the core's command doc, the guide, and the editor topic file.

[2026-11-07 04:16] EDIT .claude/worktrees/zoom-pan-lurch-bug-3981d5/docs/plugin-system.md:
200, 400 and 800%) past the zoom where the camera's headed, around the middle of what shows of
  the board (`unobscuredViewport`, clear of the title bar and the panes over the canvas), dimmed at
  the last; `.zoomToActualSize` (⌘0, ⇧0) goes to 100%, dimmed there; `.zoomToFit` (⇧1, tldraw's)
  fits every shape of the board shown into view with a first visit's margin, as close as the zoom
  goes, dimmed on an empty board. Each eases the camera over 320 ms (tldraw's animationMediumMs),
  from where it's headed, so pressing again before it lands goes on from there. Every eased camera
  move (`animateCamera`) moves each edge of the world rect the view shows in a straight line
  (tldraw's `_animateViewport`), so the point a zoom is around stays put on every frame, where
  easing the origin and the zoom each on its own would swing it out and back. Zoom to Fit again,

[2026-11-07 04:16] EDIT .claude/worktrees/zoom-pan-lurch-bug-3981d5/.claude/rules/editor.md:
past where the camera's headed, around the middle of what shows of the board, `unobscuredViewport`'s, dimmed at the last), `.zoomToActualSize` (dimmed at 100%) and `.zoomToFit` (every shape, with a first visit's inset, `CanvasEditor.firstVisitInset`, host API, which a picture of a board fits with too, as close as the zoom goes; dimmed on an empty board), each eased over 320 ms, tldraw's, as every eased camera move is (`animateCamera`: each edge of the world rect the view shows in a straight line, tldraw's `_animateViewport`, so the point a zoom is around stays put on every frame; CanvasTests' `cameraTests` and ZoomTests hold it frame by frame) (Zoom to Fit pressed again goes back: below)

[2026-11-07 04:17] ASSISTANT:
Edits are in. Building and running the camera tests (CanvasTests, plus SelectionTests, whose reveals animate the camera).

[2026-11-07 04:18] ASSISTANT:
While that builds, checking the other tests that watch a camera mid-animation, in case any pinned the old blend.

[2026-11-07 04:19] ASSISTANT:
While it builds, a look over the whole diff.

[2026-11-07 04:19] ASSISTANT:
The diff reads right. While the app builds, checking how this repo's commit messages are written, so the branch commit matches.

[2026-11-07 04:20] ASSISTANT:
Writing the branch commit while the app builds (committing changes nothing on disk, so the build is unaffected).

[2026-11-07 04:20] COMMIT MESSAGE FILE commit-msg.txt:
Zoom In and Zoom Out keep the middle of what shows of the board still on every frame, where it swung out toward the bottom right and back

The owner's report: "when you zoom in and out with plus and minus ... it takes a weird path on the z-axis. It's not like you stay centered and zoom in and out as if you were just using your scroll wheel. It's like you kind of lurch to the left and then to the right again".

Two causes. The camera's eased move (`animateCamera`: the zoom commands, Zoom to Fit, Selection's reveals) eased the origin and the zoom each on its own. The origin is the world point at the view's top-left, so the point a zoom is around sat where it belonged only at the two ends: between them it swung away from the top-left corner and back, up to 12.5% of its distance from the corner on a 2x step (about 106 points in a 1440 x 900 window) and 22.5% on the step from 10% to 25%. tldraw's `_animateViewport`, which the code named as its source, eases the world rect the view shows instead, each edge in a straight line, so the origin and one over the zoom go alike, and a point both cameras show at one place in the view stays there on every frame. `CanvasEditor.camera(between:and:at:)` does that now. A move that keeps the zoom (a pan, Home and End) is what it was.

And the commands zoomed around the view's center, which since the sidebar and the inspector became sheets over a canvas that fills the window (bd69de06) lies under a pane's edge whenever one shows, and under the title bar's row by half its height: with the sidebar open each 2x step slid what was in the middle of what shows sideways by half the sidebar's width. They now zoom around the middle of `unobscuredViewport`, which the fits, Insert and Return's placement already go by: my call, as the "stay centered" of the report.

ZoomTests' new test zooms in and out with the title bar, a sidebar and an inspector over the view, and twice on the way, holding the middle of what shows still on every frame. HandTests' "Camera motion" test held the old blend; it now holds the edges' straight lines and the point the two cameras share, frame by frame.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>

[2026-11-07 04:20] GIT:
git rev-parse HEAD main && git add -A Sources Tests docs .claude/rules && git status --short && git commit -q -F /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-zoom-pan-lurch-bug-3981d5/3a98bfd4-e201-48cc-ac56-23d479652c35/scratchpad/commit-msg.txt && git log --oneline -2

[2026-11-07 04:20] ASSISTANT:
Committed on the branch. Main has moved since this worktree was cut, so checking whether anything new there touches the camera code.

[2026-11-07 04:21] GIT:
git rebase main 2>&1 | tail -2 && git log --oneline -2 && (./test.sh > /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-zoom-pan-lurch-bug-3981d5/3a98bfd4-e201-48cc-ac56-23d479652c35/scratchpad/test-all.log 2>&1; echo "exit $?" >> /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-zoom-pan-lurch-bug-3981d5/3a98bfd4-e201-48cc-ac56-23d479652c35/scratchpad/test-all.log)

[2026-11-07 04:21] ASSISTANT:
The full suite is running. Waiting for it before I report.

[2026-11-07 04:24] NOTICE:
background task completed: Background command "Rebase onto main and run the whole test suite" completed (exit code 0)

[2026-11-07 04:24] WRAP-UP:
⌘+ and ⌘− now keep the middle of the visible board still on every frame. The fix is committed on this branch, rebased onto main, and the whole suite passes. It isn't on main yet, and nobody has tried it in the app.
Ask: Land it on main?

[2026-11-07 04:24] ASSISTANT:
I fixed the zoom lurch. There were two causes:

- **The path:** the zoom animation moved the camera's corner and its zoom level separately, so the middle of the screen only ended up in the right place. On the way, it swung toward the bottom right and back, about 100 points on each 2× step in a 1440×900 window and about 190 on the 10%→25% step. It now moves the visible area's edges in straight lines, as tldraw does, so the middle stays still on every frame. Zoom to Fit and Zoom to Selection get the same smoother path.
- **The center:** the zoom was around the whole window's center. Since 2026-11-01 the sidebar and inspector sit over the canvas, so that point was off to one side whenever a pane was open. It now zooms around the middle of what you can actually see. That second change was my call, as part of "stay centered".

A new test zooms in and out with the title bar, sidebar and inspector covering the edges, and checks the middle stays put on every frame. The whole test suite passes on the rebased branch. The code review raised only minor edge cases, none of which can happen with today's settings, so I left them alone.

I haven't seen it run, because I can't capture the screen here. To try it, open this worktree's build (a separate copy of the app):

```bash
open /Users/zekenie/code/native-canvas/.claude/worktrees/zoom-pan-lurch-bug-3981d5/build/InfiniteCanvas.app
```

[2026-11-07 05:19] COMPACTED:
(the context was summarized here)

[2026-11-07 12:55] USER:
Land it

[2026-11-07 12:55] GIT:
git log --oneline -3 main; echo ---; git log --oneline -3 HEAD; echo ---; git merge-base HEAD main; git status --short | head

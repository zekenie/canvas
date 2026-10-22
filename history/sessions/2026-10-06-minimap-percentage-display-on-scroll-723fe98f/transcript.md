# Minimap percentage display on scroll

Claude Code session `723fe98f-9175-455d-b60b-891ec5e5de36`, 2026-10-06 17:23 to 2026-10-06 19:18 UTC, on `claude/minimap-scroll-percentage-5dc7cb`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-06 17:23] USER:
[image attached]

[2026-10-06 17:23] USER:
i really dislike this thing. i want to show percentages as you scroll next to the minimap, not up there. i want it to fade away when you're not scrolling. no need for a menu. scrolling is how you zoom

[2026-10-06 17:23] ASSISTANT:
Reading the zoom menu, the minimap and how the canvas hosts it, to plan the change.

[2026-10-06 17:24] ASSISTANT:
I'd like your OK on this plan before I write any code.

**What goes**
- The toolbar's zoom menu: its file (`ZoomMenu.swift`), its toolbar item, its test, and where the docs mention it. The View menu's zoom items and their keys (⌘+, ⌘−, ⌘0, Zoom to Fit) stay.

**What comes**
- A small "44%" pill just right of the minimap, lined up with its bottom edge, in the minimap's colors. When the minimap is off or hidden, the pill sits in that corner instead.
- It appears whenever the zoom changes on the board you're looking at: pinching, ⌘-scrolling, the zoom keys and Zoom to Fit. It stays while you keep zooming and fades out about 1 second after you stop.
- It isn't clickable, so clicks go through to the canvas.
- It's drawn by the canvas view next to the minimap, and its timer runs on the editor's scheduler. It gets tests and doc updates.

**Choices I made**
- **Panning doesn't show it.** A plain two-finger scroll pans and doesn't change the number, so showing it then would just be noise. Right now only ⌘-scroll and pinching zoom. If you meant that a plain scroll should zoom too, that's a separate change.
- **It doesn't flash when you switch boards** or when a board first fits itself to the window.
- **During an eased zoom** (⌘+, Zoom to Fit) it shows the zoom it's heading to straight away, rather than counting up.

Once it's built, I'll send you a render of the pill next to the minimap. Go ahead?

[2026-10-06 17:26] USER:
sounds good, not even sure it needs to be a pill. not opinionated

[2026-10-06 17:27] ASSISTANT:
Still reading how the canvas fits a board when a window first opens, so the percentage won't flash then.

[2026-10-06 17:28] ASSISTANT:
Writing the zoom label view now.

[2026-10-06 17:29] ASSISTANT:
Hooked the label into the canvas view; now removing the toolbar menu.

[2026-10-06 17:30] ASSISTANT:
Rewrapping two comments the edit left long.

[2026-10-06 17:30] ASSISTANT:
Now the tests: replacing the menu's test with one for the View menu items, and adding a suite for the label.

[2026-10-06 17:31] ASSISTANT:
Fixing a compile error in the new test suite, then rerunning.

[2026-10-06 17:33] ASSISTANT:
Label now hides itself once faded; running the full test suite.

[2026-10-06 17:35] ASSISTANT:
A few failures. Checking which are from this change: the minimap's subview test, one step of mine, and two canvas-view tests look related. The Transform ones look unrelated.

[2026-10-06 17:35] ASSISTANT:
These tests assume a canvas with nothing open has no subviews, and the label is now always one (hidden at rest). I'll check every such assumption.

[2026-10-06 17:36] ASSISTANT:
Docs mostly updated; tidying two sentences.

[2026-10-06 17:38] ASSISTANT:
The light render looks right. The dark one came out light, and since your screenshot is in dark mode, I'll have one more go at it.

[2026-10-06 17:38] ASSISTANT:
Dark mode won't render offscreen here (the test process pins the light appearance), so I'll send the light one.

[2026-10-06 17:38] ASSISTANT:
Committing on the branch, then running the code review before reporting.

[2026-10-06 17:39] GIT:
git add -A && git commit -q -F - <<'EOF'
Show the zoom beside the minimap as it changes, in place of the toolbar's zoom menu

The owner disliked the toolbar's "44% ⌄" pull-down: "i want to show percentages as you scroll next
to the minimap, not up there. i want it to fade away when you're not scrolling. no need for a menu.
scrolling is how you zoom." So the menu is gone, and the canvas shows the zoom ("44%") right of the
minimap, their bottoms in line (in the minimap's corner while it's off or hidden), at once as the
zoom changes on the board shown, for as long as it goes on changing, fading out a second after the
last change. The View menu's zoom items and their keys stay; they were the menu's items anyway.

Decided in the plan, which the owner approved: a pan doesn't show it (a plain two-finger scroll pans
and changes no number; pinching and ⌘-scrolling zoom); another board shown, or a board's first fit,
doesn't flash it (another board hides it at once), nor anything before the canvas has a size; a zoom
command or fit shows where the camera's headed from its first frame, rather than counting up. On
its look the owner wasn't opinionated ("not even sure it needs to be a pill"): it takes the
minimap's panel, so it reads over shapes, with digits of one width so it doesn't wobble as it
counts. It takes no clicks.

`ZoomIndicator` (CanvasUI) is always hosted by `CanvasView`, hidden at rest, and asked with every
redraw (a comparison of board and `editor.zoomPercentage`); its hold and fade's end run on
`editor.scheduler`. The editing view now goes under everything the canvas hosts, so the label is
over it. Tests that read a canvas's subviews with nothing open expect the label, and the POC
parity snapshots hide it, as an intended deviation: the POC had no such thing.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -1

[2026-10-06 17:39] ASSISTANT:
Its own editor, so Quick Look is unaffected. Now checking whether a window's canvas already exists with a size when a document restores its remembered camera (which would flash the label on open).

[2026-10-06 17:41] ASSISTANT:
Fixing them now, starting with the flash on opening.

[2026-10-06 17:41] ASSISTANT:
Next: re-placing the label when the minimap changes, and the smaller fixes.

[2026-10-06 17:42] ASSISTANT:
Fixes pass their tests. Running the full suite and the app build again.

[2026-10-06 17:43] ASSISTANT:
Only the two failures that were already there on the base commit remain. Committing the fixes and updating the review's status.

[2026-10-06 17:43] GIT:
git add -A && git commit -q -F - <<'EOF'
Keep the zoom label quiet as a window opens, and beside the minimap as it comes and goes

A board opened at a remembered zoom other than 100% flashed its zoom, since the window's canvas
already had a size when `makeWindowControllers` set the camera: the camera now comes back before the
window makes its canvas, which takes the zoom it's made at as no change. The label is placed again
on every redraw while it shows, so it follows the minimap showing, hiding or being turned off. It
takes the minimap's own panel (corner radius included), rather than a copy with another radius. With
the toolbar's menu gone the zoom had no lasting spoken readout, so VoiceOver now hears the zoom it
came to as the label begins to fade, once rather than every step of a pinch.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline main..HEAD

[2026-10-06 17:44] ASSISTANT:
The toolbar's zoom menu is gone. Now, while you pinch, ⌘-scroll or use a zoom key, the percentage shows just right of the minimap. It fades out about a second after you stop. All tests pass except two Transform tests that also fail on `main`. The app builds, and I've committed and reviewed the change on this branch, but it isn't on `main` yet.

- **When it shows:** any change of zoom on the board you're looking at, including Zoom to Fit and going to a shape. Panning never shows it, and neither does switching boards. With the minimap off or hidden, it sits in the corner instead.
- **Look:** I gave it the minimap's own panel, colors and shadow, so it reads over shapes. The render I sent has slightly squarer corners than what's now built.
- **Menu items:** the View menu's zoom items and their shortcuts are unchanged.

The review found a real bug, now fixed and tested: opening a board saved at a zoom other than 100% flashed the percentage as the window appeared. The fix restores the saved view before the window creates its canvas. The review's smaller fixes:
- The label moves when the minimap appears or hides while it's showing.
- With the menu gone, VoiceOver had no way to hear the zoom. It now announces the final zoom once, as the label starts to fade.

The two Transform test failures are older than this change: they expect the slash-command lists from before the `/public` command was added. I flagged them as a separate task.

To try it (your shell runs in the main checkout, so use the full path):
```bash
open /Users/zekenie/code/native-canvas/.claude/worktrees/minimap-scroll-percentage-5dc7cb/build/InfiniteCanvas.app
```

Say "land" when you want it on `main`.

[2026-10-06 18:00] USER:
how about we put it on top the minimap not to the right

[2026-10-06 18:00] ASSISTANT:
I'll take "on top" to mean just above the minimap, left edges lined up, with a small gap. When there's no minimap it stays in the corner.

[2026-10-06 18:01] ASSISTANT:
Re-rendering it above the minimap.

[2026-10-06 18:02] GIT:
./build.sh 2>&1 | tail -1 && git add -A && git commit -q -F - <<'EOF'
Put the zoom label above the minimap rather than right of it

The owner, seeing it right of the minimap: "how about we put it on top the minimap not to the
right". It now sits 8 points above the minimap, their left edges in line; with no minimap showing
it keeps the minimap's corner.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -1

[2026-10-06 18:02] ASSISTANT:
I moved the label above the minimap, 8 points up, with their left edges lined up (render above). With no minimap showing, it still sits in the corner. The label's tests pass and the app builds; it's committed on the branch, not on `main`.

If by "on top" you meant overlaid inside the minimap instead, that's a one-line change.

To try it:
```bash
open /Users/zekenie/code/native-canvas/.claude/worktrees/minimap-scroll-percentage-5dc7cb/build/InfiniteCanvas.app
```

Say "land" when you want it on `main`.

[2026-10-06 19:17] USER:
land

[2026-10-06 19:18] GIT:
git -C ~/code/native-canvas status --porcelain | head -5; echo "main checkout branch: $(git -C ~/code/native-canvas branch --show-current)"; git log --oneline -1 main; git merge-base main HEAD; git status --porcelain | head

[2026-10-06 19:18] ASSISTANT:
Main checkout is clean. Squashing to one commit, then rebasing onto `main`.

[2026-10-06 19:18] GIT:
git reset -q --soft e1127f8e && git commit -q -F - <<'EOF'
Show the zoom above the minimap as it changes, in place of the toolbar's zoom menu

The owner disliked the toolbar's "44% ⌄" pull-down: "i want to show percentages as you scroll next
to the minimap, not up there. i want it to fade away when you're not scrolling. no need for a menu.
scrolling is how you zoom." So the menu is gone, and the canvas shows the zoom ("44%") over the
minimap, at once as the zoom changes on the board shown, for as long as it goes on changing, fading
out a second after the last change. It first sat right of the minimap; seeing it there, the owner
asked "how about we put it on top the minimap not to the right", so it sits 8 points above it,
their left edges in line (in the minimap's corner while it's off or hidden). The View menu's zoom
items and their keys stay; they were the menu's items anyway.

Decided in the plan, which the owner approved: a pan doesn't show it (a plain two-finger scroll pans
and changes no number; pinching and ⌘-scrolling zoom); another board shown, or a board's first fit,
doesn't flash it (another board hides it at once), nor anything before the canvas has a size; a zoom
command or fit shows where the camera's headed from its first frame, rather than counting up. On
its look the owner wasn't opinionated ("not even sure it needs to be a pill"): it takes the
minimap's panel, colors and shadow, so it reads over shapes, with digits of one width so it doesn't
wobble as it counts. It takes no clicks.

`ZoomIndicator` (CanvasUI) is always hosted by `CanvasView`, hidden at rest, and asked with every
redraw (a comparison of board and `editor.zoomPercentage`), placed again while it shows so it
follows the minimap showing or hiding; its hold and the end of its fade run on `editor.scheduler`.
A board opened at a remembered zoom flashed it, since the window's canvas already had a size when
the camera was restored: `BoardDocument` now restores the camera before the window makes its
canvas, which takes the zoom it's made at as no change. With the toolbar's menu gone the zoom had
no lasting spoken readout, so VoiceOver hears the zoom it came to as the label begins to fade, once
rather than every step of a pinch. The editing view now goes under everything the canvas hosts, so
the label is over it. Tests that read a canvas's subviews with nothing open expect the label, and
the POC parity snapshots hide it, as an intended deviation: the POC had no such thing.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git rebase main 2>&1 | tail -5; git status --porcelain | head -20

===== [2026-10-06 19:18] commit written: Show the zoom above the minimap as it changes, in place of the toolbar's zoom menu =====

[2026-10-06 19:18] GIT:
grep -rn "subviews.isEmpty" Tests | head; grep -n "toolbar" Sources/InfiniteCanvas/InfiniteCanvasApp.swift | head -5; git add Tests/CanvasUITests/main.swift .claude/rules/editor.md && GIT_EDITOR=true git rebase --continue 2>&1 | tail -2; git log --oneline -3

[2026-10-06 19:18] ASSISTANT:
Rebased cleanly after resolving two conflicts: the CanvasUI tests' suite list, where `main` had added a tool-picker suite, and the editor rule. Merging and cleaning up.

[2026-10-06 19:18] ASSISTANT:
It's on `main` as `39203118`. The worktree and branch are removed. As you asked, I didn't rerun the tests after rebasing onto `main`.

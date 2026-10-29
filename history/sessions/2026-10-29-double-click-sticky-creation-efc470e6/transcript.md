# Double-click sticky creation

Claude Code session `efc470e6-97cb-48fa-b530-e3c9c5c9b9aa`, 2026-10-29 22:42 to 2026-10-29 23:54 UTC, on `claude/double-click-sticky-creation-6a4aa9`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-29 22:42] USER:
when you double click on a empty frame location you should get a new sticky but don't

[2026-10-29 22:43] ASSISTANT:
Found it: a frame that holds nothing is hit anywhere inside, and since a frame neither opens nor edits, a double-click there does nothing. Reading the existing double-click tests before fixing.

[2026-10-29 22:44] ASSISTANT:
Fix written in the select tool; now adding its small helper and tidying the doc comment, then tests.

[2026-10-29 22:44] ASSISTANT:
Now the Selection test, over CanvasTesting's `Corral` (a container hit anywhere inside, like an empty frame):

[2026-10-29 22:45] ASSISTANT:
Now the shipped test: an empty frame, a frame holding a note, its title tab, and a locked frame.

[2026-10-29 22:47] ASSISTANT:
Both new tests pass. A quick check that they fail without the fix:

[2026-10-29 22:48] ASSISTANT:
Confirmed: without the fix the shipped test fails on the empty frame (no note placed); fix restored. Now the topic files and guide, which describe the double-click claim.

[2026-10-29 22:48] ASSISTANT:
Docs updated. Running the full suite and the app build (with its module audit) now.

[2026-10-29 22:48] ASSISTANT:
The full test suite and the app build are running in the background; I'll report when they finish.

[2026-10-29 22:49] ASSISTANT:
Waiting on the full suite and build to finish.

[2026-10-29 22:50] NOTICE:
background task completed: Background command "Run the full test suite, then build the app" completed (exit code 0)

[2026-10-29 22:50] ASSISTANT:
My comment edit landed mid-build, so test.sh refused that run (the app build after it passed). Running the suite again.

[2026-10-29 22:50] ASSISTANT:
The full suite is running again; I'll report when it finishes.

[2026-10-29 22:58] NOTICE:
background task completed: Background command "Run the full test suite again" completed (exit code 0)

[2026-10-29 22:58] WRAP-UP:
Double-clicking inside a frame now puts a sticky in it, even when the frame is empty. All 8,229 tests pass and the app builds. Nothing is committed and it hasn't been tried in the app yet.
Ask: Land it on main?

[2026-10-29 22:58] ASSISTANT:
Double-clicking inside an empty frame now creates a sticky, just like on the canvas.

**Why it didn't work:** a frame that holds shapes ignores clicks in its empty middle, so a double-click there already reached the canvas and made a note. An empty frame is different: it responds to a click anywhere inside, so it can be grabbed. A double-click on a shape either opens it or edits it, and a frame does neither, so the double-click did nothing.

**The fix** is a general rule in the select tool ([SelectTool.swift:125](Sources/Selection/SelectTool.swift:125)). A double-click on a shape that can't be opened or edited now does what a double-click on the canvas does. The new note goes into that frame and starts in edit mode. This is how tldraw handles double-clicks on shapes that can't be edited. Today frames are the only shipped kind this affects. Two cases are left alone:
- **The frame's title tab:** a double-click there still makes no note.
- **A locked frame:** no note goes in, and the frame shakes, as it already does for a click with the Note tool.

**Tests:**
- A Selection test covers the rule on its own.
- A shipped Frames test covers four cases: an empty frame, a frame holding a note, the title tab, and a locked frame. I checked that this test fails without the fix.
- The full suite passes (8,229 tests) and the app builds.

I updated the selection and frames topic files and the guide's note on the double-click rule. Nothing is committed, and I haven't tried it in the running app. To try it in this worktree's build:

```bash
open /Users/zekenie/code/native-canvas/.claude/worktrees/double-click-sticky-creation-6a4aa9/build/InfiniteCanvas.app
```

[2026-10-29 23:54] USER:
Land it

[2026-10-29 23:54] ASSISTANT:
The project's landing rule also asks for a code review, and none has been run on this change yet. I'll run a quick one on the diff, then land.

[2026-10-29 23:54] ASSISTANT:
The review found nothing. Writing the session record and committing.

# Skeleton type borders on zoom out

Claude Code session `b6afe07c-34aa-4ecf-b765-1b7984b1997d`, 2026-11-05 15:59 to 2026-11-05 16:16 UTC, on `claude/skeleton-borders-zoom-out-936d30`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-11-05 15:59] USER:
when you zoom out, the skeleton view of types lose their border at least on light mode inside a frame

[2026-11-05 16:02] ASSISTANT:
Now the regression test, written first so I can watch it fail before the fix.

[2026-11-05 16:04] ASSISTANT:
Reproduced: on a plain frame the note's edge pixel is pure white on pure white; on a teal frame it's 255 on 243. Now the fix.

[2026-11-05 16:04] ASSISTANT:
Now running the new test and the paper tests.

[2026-11-05 16:05] ASSISTANT:
That test's "nothing under the last row" rect runs to within 0.6 view points of the note's bottom, so it now meets the new hairline; it means "no row bars there", so I'll keep it clear of the edge.

[2026-11-05 16:05] ASSISTANT:
Now a unit test of the edge itself in the paper tests: light only, one view point wide at any zoom, none in dark or on a plain note.

[2026-11-05 16:06] ASSISTANT:
Tests pass. Now before/after renders so you can see it — a temporary gallery-style test writing PNGs (removed afterwards).

[2026-11-05 16:08] ASSISTANT:
Before/after reads clearly: "Person" in Sprint vanishes before and has an edge after. Checking dark is unchanged.

[2026-11-05 16:08] ASSISTANT:
Dark is byte-identical. Removing the temporary render test, then updating the docs that describe a type's skeleton.

[2026-11-05 16:09] ASSISTANT:
Docs updated. Now the whole suite, in the background.

[2026-11-05 16:09] ASSISTANT:
While that runs, here's the before/after at 30% in light mode.

[2026-11-05 16:09] ASSISTANT:
The whole suite is running; I'll report once it finishes.

[2026-11-05 16:12] NOTICE:
background task completed: Background command "Run the whole test suite" completed (exit code 0)

[2026-11-05 16:12] ASSISTANT:
Three failures in modules my change doesn't reach (CanvasUITests can't import StickyNotes at all). Checking whether they're load flakes by rerunning them alone.

[2026-11-05 16:12] ASSISTANT:
They reproduce, so not flakes. But I'd expect them to be unrelated: checking whether any of the three test targets even links StickyNotes.

[2026-11-05 16:13] WRAP-UP:
A type's note zoomed out now has a hairline edge in light mode, so it no longer vanishes on a frame's white. Dark is unchanged. Not committed. Its tests pass; three failures in the full run are in test targets that don't build StickyNotes.
Ask: Review this and land it on main?

[2026-11-05 16:13] ASSISTANT:
I've fixed it: zoomed out in light mode, a type's note now has a thin border, so it stays visible on a frame. Nothing is committed yet.

**Why it happened:** a type's note is pure white, and so is a frame's background in light mode (a colored frame's is nearly white). At normal zoom the note's shadow gives it an edge. Below 35% notes are drawn as simplified shapes with no shadow, so the type disappeared into the frame. On the plain canvas it was only barely visible. In dark mode the paper (light gray) stands out on its own, which is why you saw it in light mode.

**The fix** is in [NoteSkeleton.swift](Sources/StickyNotes/NoteSkeleton.swift):
- The type note gets a hairline border just inside its edge, one point wide at every zoom, like a frame's own border.
- It only appears in light mode. Dark renders are byte-for-byte the same as before.
- I picked 16% black for the border, slightly darker than a frame's 12% border, so the note doesn't look like another frame nested inside. That's easy to change.
- Yellow and colored notes are unchanged; their paper already stands out against frames.

**Tests:**
- A new test puts a type note in a plain frame and in a teal one at 30% and checks there's a visible edge. Before the fix it failed with the note and the frame both pure white.
- Another new test checks the border is light-mode only, one point wide at 30% and 10%, and absent on plain notes.
- An existing test, "nothing under the last row", checked an area that reached within a fraction of a point of the note's bottom edge, so it now hit the border. I moved its boundary clear of the edge.
- The docs that describe type notes zoomed out are updated.

The full suite has 4 failing tests in CanvasUITests, BoardsTests and ReferencesTests: minimap picture, path pill height, and the reference go-button hover. They fail again when run alone. None of those test targets build the code I changed, so this change can't be causing them; I didn't look into why they fail.

I sent you before/after pictures at 30% in light mode.

[2026-11-05 16:15] USER:
Review and land

[2026-11-05 16:15] GIT:
git rev-parse HEAD main && git add -A && git commit -q -m "A type's note zoomed out keeps an edge on a frame's white (WIP)" && git log --oneline -2

[2026-11-05 16:16] ASSISTANT:
The review found nothing to fix. Now writing the session record, squashing, and landing.

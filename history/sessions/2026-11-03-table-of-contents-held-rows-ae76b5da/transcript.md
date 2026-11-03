# Table of contents held rows

Claude Code session `ae76b5da-2d0e-4d38-b585-a6ba5b054465`, 2026-11-03 14:00 to 2026-11-03 18:50 UTC, on `claude/inspiring-noether-94b781`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-11-03 14:00] USER:
I'd like to add a UI flourish to the table of contents. It's inspired by VS Code. The VS Code feature I'm talking about is, I don't know what it's called, but I think it's something like sticky headers. I know it from code navigation, where you can scroll into the body of a class or function, and you see the first line sticky at the top. And that allows you, even as you're scrolling through an entry with many lines, to understand the hierarchy of the piece of code. I want the same thing for the table of contents. If I have a frame with 1,000 stickies, I'd like to be able to scroll liberally and still see the frame TOC entry towards the top of my screen.

[2026-11-03 14:04] ASSISTANT:
I'm reading how the sidebar's list is built (an AppKit outline in a scroll view) to work out where pinned parent rows would fit.

[2026-11-03 14:08] ASSISTANT:
Still reading: I'm checking how the outline handles ← (whether it already jumps to the parent row) and what a pinned row would need to match the real rows.

[2026-11-03 14:12] ASSISTANT:
I've read enough to propose a design. Here it is, for your OK before I write code.

[2026-11-03 14:12] WRAP-UP:
Planned how the table of contents could keep the rows of what you're scrolling through at the top, VS Code style. No code yet; I checked AppKit's outline (← already jumps to the parent row) and how rows are drawn.
Ask: Build it as planned?

[2026-11-03 14:13] ASSISTANT:
I'd build what VS Code calls sticky scroll, in the sidebar's list only.

**What it does**
- **What stays at the top:** when you scroll into an open row's children, that row stays at the top of the list, just under the header. This covers a frame, an open subboard, a note with its arrows open, and an open References section. Nested ones stack, outermost first. VS Code's tree caps this at 7 rows and 40% of the list's height; I'd use 5 rows and 40%. Past the cap, the outermost rows stay.
- **Hand-off:** as a frame's last child scrolls up, the frame's row rides up with it and the next frame's row takes its place, as in VS Code.
- **Look:** each pinned row looks exactly like its real row: same indent, open triangle, symbol, title, marks, selection highlight and hover tint. They sit on the sidebar's background with a hairline under them, like the header's.
- **Click:** as in VS Code, the list scrolls that row back into place, just under any pinned rows above it, and then the click acts on it as a normal click would. A single click selects the frame and gives the canvas the keyboard, a double-click opens it, and a drag drags it. The triangle closes the row, and it stays closed.
- **Hover and drops:** pointing at a pinned row hovers its shape on the canvas, as with any row. Dropping a dragged row on a pinned frame row moves it into that frame.
- **Keyboard:** the pinned rows aren't a keyboard stop of their own.
  - ↑ and ↓ never leave the selected row hidden under them; the list scrolls it clear.
  - ← on a row inside a frame already selects the frame's row. AppKit's outline does this; I checked. That's the keyboard way to do what clicking a pinned row does.
  - VoiceOver skips the pinned rows, since it already reads the real ones.
- **Cost:** a scroll step only looks at the rows above the top row, so a frame of 100,000 notes scrolls as cheaply as one of 10.

**How I'd build it**
- **Name:** in code I'd call them "held rows", because "sticky" already means sticky notes here.
- **Where:** all in the TableOfContents module.
  - A new file with the layout math and the view that lays the pinned rows over the list.
  - Small hooks into the list's controller and its outline view (`Sources/TableOfContents/ContentsList.swift`, `ContentsListViews.swift`).
  - The table of contents topic file updated to match.
- **Tests:**
  - The layout on its own: stacking, the hand-off, the caps, and a row already in place not pinning.
  - In a test window: scrolling, a click, the triangle, hover, a drop, and walking with ↑ ↓ without the selected row going hidden. Also that VoiceOver doesn't see the pinned rows.
- **Renders:** I'll send you pictures in light and dark: scrolled inside a frame, nested frames, mid-hand-off, and with the frame selected.

[2026-11-03 14:24] USER:
Dude. Where are we? Are we planned? Are we implemented. What do you want from me. No more 500 word essays on?

[2026-11-03 14:24] ASSISTANT:
Planned, not built yet. I need a yes from you to start building it.

The plan: open frames (and other open rows) stay pinned at the top while you scroll their contents, like VS Code. Clicking a pinned row jumps back to it.

[2026-11-03 14:25] USER:
Pic first?

[2026-11-03 14:26] ASSISTANT:
Rendering a mockup now: I'm using real pixels of the sidebar list, offscreen in a scratch copy of the repo, with the frame's row pasted at the top where it would stay.

[2026-11-03 14:28] ASSISTANT:
The build finished; now running the throwaway render.

[2026-11-03 14:29] WRAP-UP:
Mockup sent, made from the sidebar list's real pixels with the frame rows pasted at the top. Nothing is built in the app yet.
Ask: Build it like this?

[2026-11-03 14:30] ASSISTANT:
That's the picture: four states of the sidebar list, from left to right:

1. **Now:** scrolled deep into frame Research, its row has gone off the top.
2. **Research pinned:** its row stays at the top, with a thin line under it.
3. **Frame in a frame:** Research and Interviews both stay.
4. **Interviews ends:** its row slides up under Research and away.

It's a mockup, not the feature: I pasted real row pixels onto real renders of the list. Nothing is built in the app yet.

Build it like this, or change the look first?

[2026-11-03 15:24] COMPACTED:
(the context was summarized here)

[2026-11-03 16:31] USER:
Frame in a frame is awesome and what I want. Go build

[2026-11-03 16:37] GIT:
git merge-base --is-ancestor HEAD main && echo "HEAD is behind main" ; git log --oneline HEAD..main | head -20; git log --oneline main..HEAD | head

[2026-11-03 16:37] GIT:
git merge --ff-only main && git log --oneline -1 && git diff --stat HEAD~1 | tail -5

[2026-11-03 16:37] ASSISTANT:
Building now: re-read the list's code and synced to the latest main; next I'm writing the held rows themselves.

[2026-11-03 16:38] ASSISTANT:
Checking a few AppKit behaviors in a scratch program before writing the held rows.

[2026-11-03 16:41] ASSISTANT:
Writing the held-rows layout and overlay now; tests and docs next.

[2026-11-03 16:48] ASSISTANT:
Held-rows layout and overlay are drafted; wiring them into the list now, then building.

[2026-11-03 16:49] ASSISTANT:
Now the controller's hooks, the style constants and the debug counter.

[2026-11-03 16:51] ASSISTANT:
It builds. Running the list's existing tests to check nothing regressed, then writing the new ones.

[2026-11-03 16:53] ASSISTANT:
Writing the held-rows tests now: the layout against VS Code's algorithm, then the list scrolled, clicked, hovered, dropped on and walked by keys.

[2026-11-03 16:59] ASSISTANT:
Tests written; registering them and running.

[2026-11-03 17:01] ASSISTANT:
Most pass; a few failures are wrong expectations (clamped scrolls, document order). Two need a closer look: the forwarded click and the drawing. Debugging those.

[2026-11-03 17:07] ASSISTANT:
All 22 held-row tests pass. Checking a few loose ends before the full suite: whether rows have context menus or tooltips the held rows should keep.

[2026-11-03 17:07] ASSISTANT:
Rows show their full title as a tooltip, which a held row would lose since the press is the overlay's. Adding that, then the full suite.

[2026-11-03 17:08] ASSISTANT:
All 202 of the list's tests pass. Reviewing the new source as a whole before the docs.

[2026-11-03 17:09] ASSISTANT:
The code reads right. Now the docs: the topic file, the map line in CLAUDE.md, the keyboard principles' list bullet, and the guide if it describes the list.

[2026-11-03 17:10] ASSISTANT:
Docs updated. Now real renders of the feature, made in the scratch clone so nothing throwaway lands in the worktree. Syncing the clone to this branch first.

[2026-11-03 17:11] ASSISTANT:
Building the real-pixel renders in the scratch clone (a few minutes, it rebuilds the shipped app's modules).

[2026-11-03 17:12] ASSISTANT:
Renders are building in the scratch clone; meanwhile re-checking the worktree still builds after the tidy-ups.

[2026-11-03 17:12] ASSISTANT:
Built and tested (all 202 of the list's tests pass, 21 of them new). Waiting on the real-pixel renders; the full suite and a code review come next.

[2026-11-03 17:13] COMMIT MESSAGE FILE commit-message.txt:
The table of contents holds a frame's row at its top while its rows scroll under it, as VS Code's trees hold a class's line, so scrolling far into a frame keeps where you are in view

The owner's ask: "If I have a frame with 1,000 stickies, I'd like to be able to scroll liberally and still see
the frame TOC entry towards the top of my screen", after VS Code's sticky scroll. A mockup made from the
list's own pixels showed four states (today, the frame held, a frame in a frame, the inner one going up under
the outer); the owner picked it, the frame in a frame especially, and asked for it built as drawn.

Which rows are held is VS Code's tree sticky scroll (`findStickyState` in its abstractTree.ts): from the row
at the list's top, the row it's nested under at the top level, then under that the next level's, each held
at its place, the row under them held itself only while it's open with rows after it and up past its place;
the last row nested under a held row, going up, takes it up with it, under the row held above it. The caps
are 5 rows and 40% of the list, the outermost kept (VS Code keeps 7 and 40%; five frames deep is already
rare, and the sidebar is short). `ContentsHeldRows.holding` works it out from a few rows' levels a level,
since the outline's rows are all of one height, so a scroll costs the rows held whatever is listed, and its
tests hold it to VS Code's algorithm written out as it reads over seeded random outlines.

A held row is its row, not a picture of one: a `ContentsTableRow` drawn as the outline draws it (highlight,
hover tint, drop ring), in a view of the scroll view's over its clip view and under its scroller. A press on
it scrolls its row into its place under the rows held above it and hands the press on there, to the row's own
triangle on its triangle, else to the outline with the keyboard, so a click, a double-click, a ⌘-click and a
drag do what they do on the row with no copy of that logic; the pointer, a drag and a drop over it are over
its row; its tooltip is its row's; VoiceOver doesn't see it, the outline's own rows being what it walks.
A row the keys reach is scrolled clear of the held rows (keyboard navigation's P7, focus shows), through the
outline's `scrollRowToVisible`, which every ↑ ↓ Tab ⇧Tab step and a selection made elsewhere go through.

Turned down: the outline's floating group rows (`floatsGroupRows`), which hold one level only and need group
rows, which a source list draws as section headings; drawing a held row from a snapshot of its row, which has
no view while it's scrolled away and would answer no press, hover or drop.

Not seen in a test: what the outline does with the press it's handed. A synthesized press doesn't reach a
table's own tracking in an unshown window, so the tests hold that the press lands on the held rows, that the
row is scrolled under it and that the outline has the keyboard, and the app on screen is where a click on a
held row selecting it is seen.

[2026-11-03 17:13] GIT:
printf '\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n' >> /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-inspiring-noether-94b781/ae76b5da-2d0e-4d38-b585-a6ba5b054465/scratchpad/commit-message.txt && git add -A Sources/TableOfContents Tests/TableOfContentsTests .claude/rules/keyboard-navigation.md .claude/rules/table-of-contents.md CLAUDE.md docs/plugin-system.md && git commit -q -F /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-inspiring-noether-94b781/ae76b5da-2d0e-4d38-b585-a6ba5b054465/scratchpad/commit-message.txt && git log --oneline -2 && git status --short

[2026-11-03 17:17] ASSISTANT:
Full suite running. Meanwhile, the re-rendered last panel:

[2026-11-03 17:17] ASSISTANT:
The renders are sent; I'm waiting on the full test suite before reporting.

[2026-11-03 17:17] ASSISTANT:
The full test suite is running; I'll report when it finishes.

[2026-11-03 17:23] NOTICE:
background task completed: Background command "Update the topic file and run the full test suite" completed (exit code 0)

[2026-11-03 17:23] ASSISTANT:
The whole suite passed. Committing the review fixes on the branch.

[2026-11-03 17:23] GIT:
git add -A Sources/TableOfContents Tests/TableOfContentsTests .claude/rules/table-of-contents.md && git commit -q -m "Held rows after review: the hairline under them is the row under it's, a scroll under a still pointer hovers what comes under it, a row with no item is not held, one rule for the accent

The review's other findings: a double-click on a row going up was found to land on its own row already (the row held above covers the rest of it); VoiceOver's hover over a held row reading the list, the accent untestable in an unshown window and the tooltip rect made again as a row slides are left as they are.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git log --oneline -3 && git status --short

[2026-11-03 17:23] WRAP-UP:
Held rows are built: a frame's row stays at the top of the sidebar's list as you scroll into its rows, and a frame in a frame keeps both. Reviewed, fixed, and the whole suite passes. It's committed on the branch, not landed. A click on a held row hasn't been tried in the app on screen yet.
Ask: Land it on main?

[2026-11-03 17:23] ASSISTANT:
Held rows are built the way your mockup showed them, with the frame in a frame working. The picture I just sent is drawn by the real code: the list from before, then the four states.

- **What it does:** scroll into a frame's rows and the frame's row stays at the top of the sidebar's list, over the rows. A frame inside it stays too, one row per level, with a thin line under them. When a frame's last row scrolls past, the frame's row slides up under the row above it and goes away. At most 5 rows stay, and they never take up more than 40% of the list.
- **A row that stays at the top acts like the row itself.** Clicking it scrolls the real row into its place and the click goes to that row, so selecting, double-clicking, dragging and the disclosure triangle all work as usual. Hover, dropping onto it and its tooltip work too. When ↑ or ↓ moves to a row that would be hidden under them, the list scrolls so that row stays visible. VoiceOver doesn't read them, since it already reads the real rows.
- **Testing:** 21 new tests. They include checking the layout against VS Code's sticky-scroll logic on random outlines, and checking that a row at the top draws exactly like the real row. The full test suite passes.
- **Review:** I ran a code review and fixed four things. The thin line under the rows at the top was blocking clicks on the row beneath it. Hover went stale when the list scrolled under a still pointer. A rare state could leave an old row drawn at the top. One rule was written out three times. I left a few minor items as they are.
- **Not verified:** test windows aren't shown on screen, so the tests can't see a click actually select a row. They do confirm the click lands on the right row and the list takes the keyboard. Clicking a row at the top hasn't been tried in the running app.

It's committed on the branch, not on main. Should I land it now, or do you want to try it first?

[2026-11-03 18:18] COMPACTED:
(the context was summarized here)

[2026-11-03 18:49] USER:
Land it

[2026-11-03 18:50] GIT:
git rev-parse HEAD main; git merge-base HEAD main; echo '--- branch commits'; git log --oneline main..HEAD; echo '--- main commits since base'; git log --oneline HEAD..main; echo '--- main checkout status'; git -C /Users/zekenie/code/native-canvas status --porcelain --branch | head -20; echo '--- worktree build'; ls build 2>/dev/null | head

# TOC drag-and-drop reordering

Claude Code session `1f255279-dfac-4d98-b089-22f1cf9acc8b`, 2026-10-06 11:24 to 2026-10-06 13:02 UTC, on `claude/toc-drag-drop-reorder-8fb2fa`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-06 11:24] USER:
you should be able to drag and drop in the toc.

when you reorder it should change elevation. this means that toc should be ordered by elevation (a change?)

some twists, when you drop something into a frame row in the toc, it should move it into that frame. same for sub-board. look at last commit to reuse code

[2026-10-06 11:24] GIT:
git merge --ff-only main && git log --oneline -2

[2026-10-06 11:25] ASSISTANT:
I'm reading the table of contents, containers, and the `/move-to` commit on main (my branch was one behind, so I fast-forwarded it). After that I'll come back with a plan.

[2026-10-06 11:25] ASSISTANT:
Still reading: now the core's stacking and container APIs in `Transaction.swift`, which the drop would commit through.

[2026-10-06 11:29] ASSISTANT:
Still reading: I've been through the table of contents' list and state. Now I'm checking whether the app already has any drag-and-drop code and how the tests reach the list's window.

[2026-10-06 11:47] ASSISTANT:
The table of contents is already ordered by elevation, so that isn't a change. At every level, rows follow the stacking order back to front: the top row is the shape at the back, as in data-canvas's outline. Below is the plan. Nothing is built yet.

**What a drop does** (assuming you pick front-to-back, below):
- **Between two rows at the shape's own level:** only its elevation changes. Undo calls it "Reorder".
- **Onto a frame row:** the shape goes into the frame, landing where `/move-to` puts it (40 in from the top-left, clear of what's there), in front of the frame's other shapes. Undo calls it "Move".
- **Onto a subboard row:** the shape moves onto that subboard's board, landing where `/move-to` would put it.
- **Between rows at another level:** the shape moves there, then takes that spot in the stack. That covers dropping among a frame's rows, among an open subboard's rows, or out of a frame.
- **Feedback while dragging:** near a row's top or bottom edge you get a line ("in front of" or "behind" that row). Over the middle of a frame or subboard row, the row highlights ("into"). If the drop isn't allowed, nothing shows.
- **What can't be dragged:** arrows and locked shapes.

**Choices I made** (say if you want any changed):
- A shape dragged out of a frame lands beside that frame, as `/move-near` places it.
- Several selected rows dragged together move as one block, keeping their layout and their stacking order.
- Rows inside an open subboard can be dragged out too, so this works across the whole file. That needs one core change (below).

**How it's built:**
- **The list:** I ran a throwaway experiment in the scratchpad. SwiftUI's standard reorder tools for lists (`.onMove`, `.onInsert`) turn every drop *onto* a row into "insert after it", so a frame row could never take a drop. Instead, each row gets its own drag source (`.itemProvider`) and its own drop target (`.onDrop` with a `DropDelegate`). The experiment confirmed three things:
  - Pressing and dragging a row doesn't select it, so the panel won't swap to the shape's own panel mid-drag.
  - The per-row drop target gets the pointer's position inside the row.
  - Tests can drive that same path without a screen.
- **TableOfContents:** it handles dragging, the drop zones, the indicators and same-level reordering. A new extension point, `ContentsMoves`, covers drops that change a shape's container or board.
- **Moving:** it fills `ContentsMoves`, reusing the last commit's code for where `/move-to` and `/move-near` put things. That code gets extended to move several shapes at once and to take shapes from any board. Moving would start importing TableOfContents, which the layers allow.
- **The core:** two additions.
  - Restacking shapes on a board that isn't shown.
  - Moving shapes off a board that isn't shown. Today `move(_:to:)` only takes shapes from the shown board. This is the biggest piece of the work.
- **Drag type:** a private one, declared in the app's `Info.plist` by `build.sh`.
- **Tests and renders:** tests at each layer: the list's state, the real list driven through mock drags, Moving, the core, and the shipped app. I'll also send you renders of the line and the highlight.

**Not in this plan:** dropping onto the list's header to move a shape up to the enclosing board, and dropping into the empty space below the last row. One thing I can only check in the running app is whether the list scrolls by itself when a drag nears its edge. If it doesn't, I'll add that.

**One decision for you: the order.** I recommend flipping to front-to-back, so the top row is the shape in front, as layer panels do (Figma, Keynote). Then dragging a row up brings it forward. Keeping back-to-front also works, but a drag up would send a shape backward.

Pick the order and say go, and I'll build it here.

[2026-10-06 11:49] USER:
wait what do i actually need to decide

[2026-10-06 11:50] ASSISTANT:
You only need to decide one thing: which way the list runs.

- **Front-to-back** (my recommendation): the top row is the shape in front. Dragging a row up brings it forward, as in Figma's or Keynote's layers.
- **Back-to-front** (as it is now): the top row is the shape at the back. Dragging a row up sends it backward.

Everything else in the plan I've already decided, and you can leave it as is.

Reply "front-to-back, go" (or "keep it, go") and I'll start.

[2026-10-06 11:50] USER:
front to back

[2026-10-06 11:50] ASSISTANT:
Going with front-to-back. Starting the build now.

[2026-10-06 11:55] ASSISTANT:
Still building. Next up is how the plugin registry declares an extension point, so the table of contents can hand cross-container drops to Moving.

[2026-10-06 11:57] ASSISTANT:
I have what I need. Starting with the core: moving shapes off a board that isn't shown, restacking on another board, and making a commit write every board it changed together.

[2026-10-06 11:57] ASSISTANT:
Now the transaction itself: moving shapes off any board, and restacking on another board.

[2026-10-06 11:58] ASSISTANT:
Next, the core tests for these additions. First, the existing `MovingAcrossBoardsTests` patterns to follow.

[2026-10-06 11:58] ASSISTANT:
Writing the core tests: a new suite for moves off a board that isn't shown, and for restacking on one.

[2026-10-06 11:59] ASSISTANT:
Core code and tests are written. Building the test executables now; it's the first build in this worktree, so it'll take a bit.

[2026-10-06 12:00] ASSISTANT:
All 11 new core tests pass. Running all of CanvasTests to check the commit change broke nothing.

[2026-10-06 12:00] ASSISTANT:
Core passes: 577 tests. Next is the table of contents, starting with the order flip.

[2026-10-06 12:01] ASSISTANT:
The order is flipped in the listing. Rebuilding, then running the table of contents' tests to see which ones assumed back-to-front.

[2026-10-06 12:01] ASSISTANT:
The flip shows up as expected: about 55 table-of-contents tests assumed back-to-front. I'm looking at how they state their expected order so I can update them properly.

[2026-10-06 12:03] ASSISTANT:
Now the view: `ListedRows` shows each level front to back, and a nested board's rows come front to back ahead of the rows nested under their owner.

[2026-10-06 12:04] ASSISTANT:
Down to 10 failures, all expected: tests that read rows by their on-screen position, plus the one about which board "the row listed first" goes to. Updating them now.

[2026-10-06 12:04] ASSISTANT:
These failures match the new order exactly: row 4 is still B, and A moved from row 2 to row 5. Updating ContainerWindowTests.

[2026-10-06 12:05] ASSISTANT:
Down to 2 table-of-contents failures out of 130. One is just the test's own wording. The other needs a closer look: a list that brings rows in under two frames at once.

[2026-10-06 12:07] ASSISTANT:
All 130 table-of-contents tests pass with the order flipped. Running the whole suite in the background to catch other tests that read rows by position. Meanwhile I'll write the drag-and-drop code.

[2026-10-06 12:09] ASSISTANT:
While the suite runs, I'm writing the drag and drop for the table of contents: the extension point that hands moves to Moving, then the drop zones, indicators and reordering.

[2026-10-06 12:09] ASSISTANT:
The full suite has 4 failures, all from the order flip: three in the path's crumb menus and one row tint in the panel. I'll fix those after the drag code. Writing the drag state now.

[2026-10-06 12:10] ASSISTANT:
Now wiring the rows: each one becomes a drag source and a drop target, and draws its own line or ring.

[2026-10-06 12:14] ASSISTANT:
Now `Surroundings` takes a block instead of one shape.

[2026-10-06 12:15] ASSISTANT:
Builds. Checking that the refactor left `/move-to` and `/move-near` working before adding the new contribution.

[2026-10-06 12:15] ASSISTANT:
`/move-to` and `/move-near` still pass all 45 tests on the shared code. Now Moving's contribution: where a dropped block lands for each kind of place, then the restack in the same step.

[2026-10-06 12:16] ASSISTANT:
The audit rejects the manifest change until MovingTests imports TableOfContents, which the new tests will do. Writing them now; first, what CanvasTesting offers.

[2026-10-06 12:17] ASSISTANT:
Writing Moving's drop tests: each kind of place, blocks of several shapes, cross-board drops, and refusals.

[2026-10-06 12:20] ASSISTANT:
All 58 Moving tests pass. Next are the table of contents' own drag-and-drop tests, using fixtures only, no Moving. First I'm checking which helpers the container tests use.

[2026-10-06 12:21] ASSISTANT:
Now the table of contents' drag-and-drop tests: what a row drags, where a drag points, reordering, refusals, places handed to `ContentsMoves`, nested boards, and opening a closed row it rests on.

[2026-10-06 12:24] ASSISTANT:
Three of these are crumb-menu tests that click menu buttons by position, and the flip moved the rows. I'm updating them to the front-to-back positions.

[2026-10-06 12:25] ASSISTANT:
Writing the shipped-app drag test now: notes into a frame, onto a subboard's board, reordered, plus a locked note and an arrow that don't drag.

[2026-10-06 12:26] ASSISTANT:
All 4 shipped tests pass. Next, declaring the private drag type in the app's `Info.plist` (built by `build.sh`).

[2026-10-06 12:27] ASSISTANT:
Declared. Now the docs: the rules files, the guide and CLAUDE.md's map. First I'm finding each place that describes the list's order, Moving's scope, or the core move.

[2026-10-06 12:27] ASSISTANT:
The code and tests are in and green across the core, the table of contents, Moving and the shipped app. Now updating the docs: the guide, the rules files and CLAUDE.md's map.

[2026-10-06 12:28] ASSISTANT:
Now the rules files: table of contents, moving, boards in a file, build, and CLAUDE.md's map lines.

[2026-10-06 12:30] ASSISTANT:
The docs are updated. Running the full suite in the background now, then I'll build the app and make renders of the line and the ring for you.

[2026-10-06 12:31] ASSISTANT:
All 4,199 tests pass, benchmarks included, with no type-declaration warnings. Rebuilding with the last change, rerunning the table of contents' tests, and building the app.

[2026-10-06 12:32] GIT:
grep -rn "struct InspectorHost" Sources Tests | head -3; git add -A && git commit -q -m "Drag and drop in the table of contents (work in progress)" && git log --oneline -1

[2026-10-06 12:33] ASSISTANT:
The renders exist. Checking them before I send anything.

[2026-10-06 12:34] ASSISTANT:
Composing the renders into one labeled sheet: before and after, then the line, the frame's ring and the subboard's ring, in light and dark.

[2026-10-06 12:35] ASSISTANT:
The dark text stays dim. That's the sidebar's vibrant text not drawing offscreen, a known limit of offscreen captures, so the sheet will show the light renders only.

[2026-10-06 12:36] ASSISTANT:
The sheet is composed. Two small cleanups before the code review: removing the copy I put in `build/`, and renaming an awkward test constant. Then I'll commit and run the review.

[2026-10-06 12:36] GIT:
rm -f build/table-of-contents-drag.png && python3 - <<'EOF'
p='Tests/TableOfContentsTests/DragWindowTests.swift'
s=open(p).read()
a='''        let around = rowB.insetBy(dx: 0, dy: -ContentsStyleProbe.lineReach)'''
b='''        let around = rowB.insetBy(dx: 0, dy: -lineReach)'''
assert a in s; s=s.replace(a,b)
a='''
/// How far a drop's line reaches past the edge of the row it's at: half its ring, and a point to spare.
enum ContentsStyleProbe {
    static let lineReach: CGFloat = 5
}
'''
assert a in s; s=s.replace(a,'')
a='''@MainActor private func ids(_ document: CanvasDocument) -> [ShapeID] { document.shapes.map(\\.id) }
'''
b='''@MainActor private func ids(_ document: CanvasDocument) -> [ShapeID] { document.shapes.map(\\.id) }

/// How far a drop's line reaches past the edge of the row it's at: half its ring, and a point to spare.
private let lineReach: CGFloat = 5
'''
assert a in s; s=s.replace(a,b)
open(p,'w').write(s)
EOF
./build.sh tests 2>&1 | grep -E "error|warning|audit" | head -3; TEST_FILTER="in a window" build/debug/TableOfContentsTests/TableOfContentsTests 2>&1 | tail -1; git status --short | head; git add -A && git commit -q --amend --no-edit && git log --oneline -1

[2026-10-06 12:36] ASSISTANT:
Committed to the branch. Running the code review on the branch against main now, as every change gets before I report it ready.

[2026-10-06 12:39] ASSISTANT:
Reviewing now. I'm re-reading the remaining changed sources line by line (the row view, the state's selection ordering, the core commit).

[2026-10-06 12:44] ASSISTANT:
Applying the review fixes. One edit didn't match the file text exactly, so I'm redoing it.

[2026-10-06 12:45] ASSISTANT:
Moving builds with its fixes. Now the table of contents' side: a cached, visibility-aware selection drag, a cached admission per pointer move, and the restack-only goes-with check.

[2026-10-06 12:46] ASSISTANT:
All green: Moving 61/61, table of contents 145/145, including the new tests. Updating the docs to match: the restack-only check, the caches, landing within the holder, and the no-room no-op.

[2026-10-06 12:47] ASSISTANT:
Fixes and docs are in. Running the full suite once more before I mark the findings and finalize the commit.

[2026-10-06 12:47] ASSISTANT:
While the suite runs, I'm writing the commit message: what you asked for, your order choice, what was reused from `/move-to`, and what's left to check in the app.

[2026-10-06 12:47] COMMIT MESSAGE FILE commit-message.txt:
Drag rows in the table of contents: restack shapes, or drop them into a frame or onto a subboard's board

The owner asked to drag and drop in the table of contents: reordering rows
changes elevation, so the list is ordered by elevation; and, as twists,
dropping something on a frame's row moves it into the frame, and on a
subboard's row onto its board, reusing what the last commit's /move-to does.

The list was already z-ordered, back to front as data-canvas's outline was,
but for dragging the owner chose front to back, as layer panels have it
(Keynote's, Figma's): the top row is the shape in front, so a row dragged up
comes forward. `entries` keeps document order, as the core keeps shapes, and
the list shows each level the other way round (`ListedRows`, `BoardRows`, a
crumb's menu in `OutlineRows.lines`), which kept the listing's upkeep, and
the tests that read it, as they were.

How a drop reads. Near a row's top or bottom edge a line shows, from a ring at
its start: the dragged shapes go beside that row's shape, in front of it (and
all it holds) or just behind it, in its frame or on its board directly. Over
the middle of a frame's or subboard's row the row is ringed: into the frame,
or onto the subboard's board, in front of what it holds. Below an open frame's
row is into it too. A drop that leaves shapes in their frame only restacks
them, one step called Reorder. One that takes them elsewhere is Move: into a
frame (its row, or among the rows it holds) they land as /move-to puts a shape
there, 40 in and clear of what it holds; onto a subboard's board as /move-to
puts one there; and out of the frames they're in beside the outermost one they
leave, as /move-near puts a shape beside it, kept within the frame they go to,
or, with no room there, nowhere: nothing changes. Then, in the same step, they
take the place in the stack the drop said. Several selected rows move as one
block, keeping where they are to each other and their order. Rows of an open
subboard drag and take drops like the board shown's, so a shape comes off a
subboard's board, goes onto it, or moves within it, from the list. A locked
shape's row and an arrow's don't drag, and nothing shows where a drop isn't
taken. Resting on a closed subboard's row opens it after 700 ms, as Finder's
folders spring open.

How it's built. A throwaway spike against SwiftUI's List (an NSOutlineView
here) settled it: its own reordering, `onMove` and `onInsert`, turns every
drop on a row of an outline into an insertion after it, so a frame's row could
never take one; a drop target of each row's own (`.onDrop` with a delegate)
does, with where on the row the pointer is. Pressing a row and dragging it
doesn't select it (the table selects on a click's release), so the panel
doesn't turn to the shape's details under a drag. Each row is a drag source of
its own (`.itemProvider`, which the table asks every dragged row for) carrying
a private type the app declares, so a list takes only a drag it began.
Headless, `ContentsState` drives all of it (`dragged(from:)`, `beginDrag`,
`target(onRow:at:)`, `admits`, `drop`, `dragMoved(over:at:)`, `dropZone(for:)`,
observed per row), and window tests drive the table's writers and a row's own
drop target with a drag of their own making, as AppKit hands one over.

The table of contents knows no frame or subboard by name: it declares
`ContentsMoves`, what takes dropped shapes somewhere they aren't, and does
restacks itself (`ContentsPlace.restack`, which the mover runs after a move in
the same step). Moving fills the point, reusing /move-to's and /move-near's
placing, generalized from one shape on the board shown to a block of shapes on
any board (`Block`, `Drop`); it now imports TableOfContents, a surface, which
its layer allows. Its commit raises a block over what it lands on together, in
their order, and one check of what goes with a move serves the commands and
the drops.

The core gains what file-wide drops need: `move(_:from:to:)` moves shapes off
a board that isn't shown onto any other, the board shown too, in a transaction
over the source that reads every board as this one leaves it; `move(_:above:on:)`
and `move(_:below:on:)` restack on another board; and a commit writes every
board it changed together, each letting go of what leaves it before any takes
in what comes, so a shape moved either way between two boards is on one at a
time. Undo puts every board back exactly.

Not in this change: dropping on the list's header to move a shape up to the
enclosing board, and dropping in the empty space under the rows. Whether the
list scrolls by itself when a drag nears its edge, and whether a drop over a
row's disclosure triangle or indentation reaches it, are AppKit's routing,
which only the app on screen shows.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>

===== [2026-10-06 12:47] commit written: Drag rows in the table of contents: restack shapes, or drop them into a frame or onto a subboard's board =====

[2026-10-06 12:48] ASSISTANT:
One error in the guide's diagram caption: a line under Bread's row means behind Bread and in front of Groceries, not the other way round. Fixing.

[2026-10-06 12:48] ASSISTANT:
All 4,203 tests pass, benchmarks included. Recording what happened to each review finding:

[2026-10-06 12:48] GIT:
git add -A && git commit -q --amend -F /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-toc-drag-drop-reorder-8fb2fa/1f255279-dfac-4d98-b089-22f1cf9acc8b/scratchpad/commit-message.txt && git log --oneline -2 && git status --short | head -3; ./build.sh 2>&1 | tail -1

[2026-10-06 12:49] ASSISTANT:
Drag and drop in the table of contents is built and tested. It's committed on the branch, waiting for your go-ahead to land.

**How it behaves:**
- **Order:** the list now runs front to back. The top row is the shape in front, so dragging a row up brings it forward.
- **Line and ring:** near a row's top or bottom edge, a line shows where the shape will go: in front of or behind that row's shape. Over the middle of a frame's or subboard's row, the row gets a ring, meaning "into it".
- **Reorder:** a drop that keeps shapes in their frame only changes elevation. Undo calls it "Reorder".
- **Into a frame or subboard:** this reuses `/move-to`'s placement. Into a frame, the shape lands 40 in from the top-left, clear of what's there. Onto a subboard's board, it lands where `/move-to` would put it. Undo calls it "Move".
- **Out of a frame:** the shape lands beside the frame it leaves, as `/move-near` would put it. If there's no room for it there, nothing happens.
- **Several rows:** a selection moves as one block and keeps its order.
- **Rows inside an open subboard** drag too, onto the board shown and across. That needed one core change: moving shapes off a board that isn't shown.
- **What doesn't drag:** locked shapes and arrows.
- **Spring-open:** holding a drag over a closed subboard's row opens it.

**One change from the plan:** the list's data stays in back-to-front order internally, and only the view reverses it. Flipping the data would have meant editing about 250 test assertions across roughly 40 files, for no change in behavior.

**Review:** the code review found 10 issues. I fixed 7, including a real bug: several rows dropped onto a frame they were behind came out in reverse order. The other 3 I left. The first two are things only the app on screen can show:
- whether the list scrolls by itself when a drag nears its edge
- whether a drop over a row's disclosure triangle or indentation registers

The third is a design choice: the front-to-back reversal lives in three places in the view.

All 4,203 tests pass, benchmarks included.

**Please try it in the app.** Headless tests can't do a real mouse drag, so this is the one thing I couldn't check myself. In particular: that pressing a row and dragging doesn't swap the panel to that shape's details, and the two open items above. Your shell runs in the main checkout, so use this exact path:

```bash
open /Users/zekenie/code/native-canvas/.claude/worktrees/toc-drag-drop-reorder-8fb2fa/build/InfiniteCanvas.app
```

I've sent a render sheet: the list before and after the flip, the line, and the rings on a frame and a subboard. Say "land" when you're happy, and I'll squash it onto main.

[2026-10-06 12:59] USER:
have you built

[2026-10-06 12:59] ASSISTANT:
Yes. I built the app after the final commit (dfae8950), so it includes every review fix. It's in the worktree, not the main checkout:

```bash
open /Users/zekenie/code/native-canvas/.claude/worktrees/toc-drag-drop-reorder-8fb2fa/build/InfiniteCanvas.app
```

[2026-10-06 12:59] USER (shell):
open /Users/zekenie/code/native-canvas/.claude/worktrees/toc-drag-drop-reorder-8fb2fa/build/InfiniteCanvas.app

[2026-10-06 12:59] ASSISTANT:
The app is open. Try dragging a note's row onto a frame's row, and a row up or down past another; tell me what you see.

[2026-10-06 13:01] USER:
this looks great to me, let's squash merge to main

[2026-10-06 13:01] ASSISTANT:
Landing it.

[2026-10-06 13:01] GIT:
git -C /Users/zekenie/code/native-canvas status --short | head -5; echo "main: $(git -C /Users/zekenie/code/native-canvas log --oneline -1 main)"; git log --oneline -3; git merge-base --is-ancestor main HEAD && echo "branch is on top of main"

[2026-10-06 13:01] ASSISTANT:
Main hasn't moved and its checkout is clean, so the branch's single commit goes straight on.

[2026-10-06 13:02] ASSISTANT:
It's on main. Recording the decision and the open follow-ups in memory, then cleaning up the worktree and branch.

[2026-10-06 13:02] WRITE /Users/zekenie/.claude/projects/-Users-zekenie-code-native-canvas/memory/toc-drag-drop-decisions.md:
---
name: toc-drag-drop-decisions
description: "Table of contents drag and drop landed 2026-10-06 (dfae8950): front to back (the owner's pick), per-row drop targets, ContentsMoves filled by Moving; follow-ups left open"
metadata:
  type: project
---

Drag and drop in the table of contents landed on main as one squashed commit, dfae8950, on 2026-10-06, with the owner's go-ahead after trying it in the app ("this looks great to me"). The commit message, `.claude/rules/table-of-contents.md`, `moving.md`, `boards-in-a-file.md` and the guide's "Dragging rows" record the design. The owner's one decision: rows run front to back (the top row is the shape in front), not data-canvas's back to front. Don't re-ask it.

Left open, none chosen yet:
1. Whether the list scrolls by itself when a drag nears its edge: per-row SwiftUI drop targets take the drag, not the table, which autoscrolls only as the destination. Only the app on screen shows it.
2. Whether a drop over a row's disclosure triangle, indentation or the cell's insets reaches a row: the target is the cell's content.
3. Dropping on the list's header to move a shape up to the enclosing board, and dropping in the empty space under the rows.
4. The front-to-back reversal lives in three view sites (`ListedRows`, `BoardRows`, `OutlineRows.lines`); `entries` keeps document order on purpose (flipping it meant ~250 test assertions for no behavior).

**Why:** these are the threads open when it landed; the repo shows what's built, not what  […188 more chars]

[2026-10-06 13:02] ASSISTANT:
It's on main as dfae8950. I removed this session's worktree and branch.

# Self-referencing arrows not working

Claude Code session `3d8025cf-422e-4900-b10f-4261b9d5c2f6`, 2026-11-03 13:56 to 2026-11-05 15:54 UTC, on `claude/self-referencing-arrows-bug-0c004c`, `main`, `self-loops-stickies`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-11-03 13:56] USER:
There was a recent commit where we fixed a bug. The bug was that it was impossible to create self-referencing arrows. I have to say, I have now tried this again, and I don't think the bug fix worked, or if it did, I can't figure out the right interaction, which in itself is a problem. I drag from a port, and then I drop it on the same shape, and I don't get any self-referencing arrow.

[2026-11-03 14:02] ASSISTANT:
Reading tldraw's upstream arrow code now, to confirm how it treats an arrow whose two ends are on the same shape.

[2026-11-03 14:07] ASSISTANT:
I have the full picture. The earlier fix only covered types, and an existing test explicitly pins "no arrow from a note to itself". Putting the plan together.

[2026-11-03 14:07] WRAP-UP:
The earlier fix covered only types: dropping a type's drag back on the type makes a relationship type. On every other shape, the arrow is still deleted on release, and a test pins that. Nothing is changed yet; the plan is waiting for your go-ahead.
Ask: Build the self-loop plan?

[2026-11-03 14:07] ASSISTANT:
The fix did work, but only for **types**. On a plain note, a subboard or a frame, dropping a dot's drag back on the same shape still does nothing. My guess is you tried a plain note. If it was a type and nothing happened, tell me, because that would be a second bug.

**What's going on**
- The earlier fix (46de99cd) only covered types. A type dragged back onto itself becomes a relationship type related to itself, shown as a pill with two arrows, not as an arrow loop.
- On every other shape, the drag still follows an old rule from data-canvas's ports: a drag never ends on the shape it started from. Letting go there counts as letting go on empty canvas, so the arrow is deleted. A test even checks that a note never gets an arrow to itself. I found no record of you asking for that rule.
- tldraw allows it: I checked its current source, and both ends can bind to the same shape.
- Your app was built on Nov 2, so it already includes that fix.

What I take you to want: a drag from any shape's dot, dropped back on that shape, leaves an arrow that loops back to it.

**Plan**
1. **The drag.** Letting go on the starting shape draws a loop arrow. It leaves the side whose dot you pulled and comes back into that same side. While you hover back over the shape, it lights up as a target and the loop shows, so you can see the result before you let go.
2. **Types** keep what they do now: the drag still makes a relationship type to itself.
3. **Keyboard.** ⌘L with one shape selected loops it. Connect needs two shapes today.
4. **Agents.** `canvas draw`'s `edge "A" -> "A"` draws the same loop instead of being refused, and the canvas skill's pages say so.
5. **A second loop** on the same side goes around the first, the same way a second arrow between two notes is bent apart from the first.
6. **One behavior change:** letting go back on the shape no longer cancels a drag. Escape, or letting go on empty canvas, still does.

**Calls I made** (easy to change after you see renders)
- The loop sits on the side of the dot you pulled. I chose that over running from the dot to wherever you let go, because it's more predictable.
- Where this differs from tldraw: tldraw draws a self-arrow straight, through the shape, from where you pressed to where you let go. Here it's stored as a loop using tldraw's own arrow settings (two fixed end points plus a bend), so tldraw's drawing code still draws it. Dragging an end of an existing arrow stays exactly as tldraw does it.
- The type-only switch the earlier fix added goes away, since every shape now accepts a drag from itself.
- Picking from a field's list still never offers the note itself.

**Build and checks:** I'd build it in this worktree and flip the tests that check "no loop". I'd add tests for:
- a fast and a slow drag
- ⌘L on one shape
- `canvas draw`
- a second loop
- Undo

Then I'd update the docs, run a code review, and send before/after renders of a note, a subboard and a frame with a loop. It reaches main only when you say so.

[2026-11-03 14:08] USER:
since this is round 2 of this i really need to understand what happened and make sure we're on the same page. was this supposed to be fixed already and we had a miscommunication? what will the ui pattern be

[2026-11-03 14:09] WRAP-UP:
Round 1 was a miscommunication on our side: the session read "self reference" as "a type related to itself," so only types were fixed. The plan now covers every shape with dots. Nothing is built yet.
Ask: Build the self-loop plan?

[2026-11-03 14:09] ASSISTANT:
Yes, you already asked for this, and the fix that shipped was narrower than what you meant. The narrowing was our doing, not yours.

**What happened in round 1 (Oct 31)**
- You said there's no good way to create a self reference: dragging from the "portal" and dropping on the shape doesn't work.
- That session read "self reference" as "a type related to itself" (Person manages Person). It said so in a single line and proposed a fix for types only. The note that "plain notes would still refuse" was one bullet among many. Its question to you was whether a drag from a type back onto itself should make a relationship type to itself.
- You replied "sorry yes port. go ahead and build." That was you correcting "portal" to "port", but the session took it as approval of the types-only scope.
- Its final report said "plain notes … work as before." What that meant was that dragging a note back onto itself still does nothing, but it never said so plainly. It also never tried the change in the app on screen.
- So the general case you wanted was never built. Even on a type, the drag makes a relationship type (a pill with two arrows), not a looping arrow.

**The UI pattern** (the sketch above shows the main gesture)
- It's the gesture you already tried. Hover a shape, press a dot, drag out, come back over the same shape, and let go.
- When you're back over the shape, it gets the usual target outline, and the arrow you're dragging becomes a loop on the side whose dot you pressed. The right dot gives a loop on the right, the bottom dot a loop underneath, and so on.
- If you let go anywhere on the shape, the loop stays, and one Undo removes it. If you move off the shape first, it's an ordinary arrow again. Escape, or letting go on empty canvas, still cancels.
- The loop is an ordinary arrow. You can label it, color it, bend it, move its ends or delete it.
- Another loop from the same side is drawn larger, around the first.
- To do it from the keyboard, select one shape and press ⌘L.
- It works on every shape that has dots: notes, subboards, frames and reference pills.
- Types stay as they are: the same drag makes a relationship type to itself, the same way a drag between two types already does.

[2026-11-03 14:09] USER:
Yes, build it

[2026-11-03 14:12] ASSISTANT:
Building now. I've read the drag, Connect and port code; next I'm reading the edge maker that `canvas draw` and ⌘L share, then I'll start writing the loop shape.

[2026-11-03 14:14] ASSISTANT:
I've read everything the change touches. Now writing the code, starting with the loop shape in Arrows.

[2026-11-03 14:16] ASSISTANT:
Now the plugin's registration: pass the dot's side to the drag, drop the type-only switch, and update the docs on both.

[2026-11-03 14:17] ASSISTANT:
Now `bindTerminal` takes a change applied in the same commit, so the loop costs no extra commit per pointer move.

[2026-11-03 14:18] ASSISTANT:
Loop shape and the drag's live loop are written; now changing ⌘L to take one shape and letting `canvas draw` draw a loop instead of refusing.

[2026-11-03 14:20] ASSISTANT:
Code compiles through the audit. Several existing tests pin the old "a drag never ends on its own shape" rule, so I'm rewriting those now.

[2026-11-03 14:20] ASSISTANT:
Still on the tests that pinned the old rule (ports, edges, Connect); the source changes are done.

[2026-11-03 14:22] ASSISTANT:
Rewriting the arrow-ports tests now: the old "self connection" suite becomes a loop suite covering the drag, the live loop, nesting, and cancel.

[2026-11-03 14:24] ASSISTANT:
Refining one detail before building: putting the loop's two ends on the shape's actual edge, so a loop on a round-ended reference pill doesn't start a few points off it.

[2026-11-03 14:24] ASSISTANT:
Now update the two callers to pass the connectable shape instead of bounds.

[2026-11-03 14:25] ASSISTANT:
Writing the shipped-notes loop test now (a real note dragged back onto itself, plus ⌘L on one note).

[2026-11-03 14:26] ASSISTANT:
Tests are updated. Building and running the arrow-ports, ports and edge suites in the background while I update the docs.

[2026-11-03 14:27] ASSISTANT:
While the build runs: updating the rules files, the plugin guide and the canvas skill to describe loops instead of the old refusal.

[2026-11-03 14:27] ASSISTANT:
Updating the plugin guide's section and Connect paragraph first.

[2026-11-03 14:27] EDIT .claude/worktrees/self-referencing-arrows-bug-0c004c/docs/plugin-system.md:
### A drag back onto where it starts

A port's drag may end on the shape it started from, as on any shape that takes its channel:
`editor.channel(of:endingAt:)` asks the start as any other, so the faint outlines show it as a drag
begins and the hint lights it when the pointer comes back over it. Let go there, the drag joins the
shape to itself, and the connector draws that as it says. Arrows draw a loop on the side of the dot
the drag was pulled from ([ArrowLoops.swift](../Sources/Arrows/ArrowLoops.swift)): it leaves the side
and comes back into it, clockwise round the shape, bowed out past it, and each further loop on a
side goes round the one before. The drag shows the loop as soon as its end is back on the shape, and
an arrow from the shape's middle again once it leaves:

```swift
let loop = ArrowConnections.loop(on: shape, side: .right, beside: loops, in: document)
arrow.start = .bound(loop.start)
arrow.end = .bound(loop.end)
arrow.bend = loop.bend
```

The loop is stored as tldraw's own properties, two precise anchors on one side and a bend, so its
geometry is tldraw's arrow bound twice to one shape (both anchors taken as precise, clipped at the
outline), a pure function of the arrow that a person reshapes by its handles. The release then says
what the arrow is, as for any: Types' `connectionDrawn` replaces a type's loop with a relationship
type from it to itself, an arrow into it and one out of it. Connect (⌘L) on one shape and `canvas
draw`'s `edge "A" -> "A"` make the […86 more chars]

[2026-11-03 14:27] EDIT .claude/worktrees/self-referencing-arrows-bug-0c004c/docs/plugin-system.md:
connection by name from the keyboard: with two shapes selected and nothing under way or edited,
`editor.connect(_:)` connects the one selected first to the other, through
`registry.drawConnection(from:to:in:)`, the maker `canvas draw` makes an edge with, on the channel it
picks, one step, Connect, the selection kept (a second between a pair is bent apart from the first,
as a script's is); with one, it connects the shape to itself, the drag back onto it by keys (arrows:
a loop on its right side). A reference pill is an end as what it stands for, as a drag reads its dots, and
one that stands for nothing now is none. Where the maker refuses the pair (no channel joins them, a
note and a frame; one holds the other, a frame and a note in it) or the board takes nothing, nothing
is put down and both shake. `ConnectMenuPlugin` adds the item
that runs it to a right-click on two shapes (`MenuItem(command: .connect, when:)`), so the menu bar's Shape
menu has it too, and leaves it off one shape's menu, which every right-click would carry for the rare
loop; a list without ContextMenus leaves it out and keeps the key. PortEdgesTests'
`connectTests` hold it over fixtures, CompositionTests' `connectShippedTests` over the shipped kinds.

[2026-11-03 14:27] ASSISTANT:
Now the connections rules: the bullet that said a drag never ends where it starts, the channel description, and Connect.

[2026-11-03 14:28] ASSISTANT:
Rules docs next: the arrows file's port-drag paragraph and a new bullet for the loop.

[2026-11-03 14:29] ASSISTANT:
Both suites pass now (PortsTests 111/111, ArrowPortsTests 118/118). Next the canvas skill's language page, then I'll start the full test suite.

[2026-11-03 14:30] ASSISTANT:
Docs for the skill and the plugin guide are updated; finishing the last three rules files (relationships, types, keyboard), then starting the full test suite.

[2026-11-03 14:30] ASSISTANT:
All docs updated. Starting the full test suite in the background now; meanwhile I'll set up the before/after renders of loops.

[2026-11-03 14:31] ASSISTANT:
Status: code, tests and docs are written; the full suite is running. Next I'm committing on the branch and making the loop renders from a scratch clone, so the running suite isn't disturbed.

[2026-11-03 14:31] GIT:
git add -A Sources Tests docs .claude/rules .claude/skills CLAUDE.md && git status --short | head -40 && git commit -q -F - <<'EOF'
A drag from a shape's dot let go back on the shape draws a loop arrow from the shape to itself

The owner asked for this once already: "there's no good way to create a self reference. i try
draging from the portal and dropping on the shape but it doesn't work". That round read "self
reference" as a type related to itself, and 46de99cd let only a type's drag end on itself, turning
it into a relationship type; on every other shape the drag still ended nowhere. Trying it again, the
owner got no arrow and asked what went wrong: the narrowing was ours, said in one line of a long
message and taken as approved. What they want is the general thing: drag from any dot, let go on
the same shape, and get an arrow that loops back to it.

The rule that refused it, "a port's drag never ends where it starts", came over with data-canvas's
ports and was never a decision of the owner's. tldraw keeps an arrow bound to one shape at both
ends, drawn straight between its two anchors through the shape. Here such an arrow is a loop on one
side: both anchors precise on the side of the dot pulled, on the outline (a pill's round end is
short of its bounds), and a bend that bows it out past the side, clockwise round the shape, so
tldraw's own geometry draws it out of the side and back in. The bend and anchors are tldraw's
properties, so geometry stays a pure function of the arrow and a person reshapes a loop by its
handles; only where the anchors go and how far it bows are ours (ArrowLoops.swift). A second loop on
a side goes round the first, as a second arrow between two shapes is bent apart from the first, and
a delete frees its place. The drag shows the loop as soon as its end is back on the shape (in the
commit that binds the end, through bindTerminal's reshape, so no extra commit a move), and the shape
is outlined as a target from the drag's start, so the gesture can be seen before it is made.

One rule for every shape: Connections asks the start as any other end, and SelfConnections, the
type-only switch, goes. The release still says what the arrow is: a type's loop becomes a
relationship type to itself, as before (kept plain where that can't be made, as a drag between two
types keeps its arrow), and a note's takes the one relationship type that fits, as any drag between
two notes does. The keyboard way is Connect (⌘L) on one shape, a loop on its right side; its
right-click item stays for two shapes, since every one-shape menu would carry it for a rare loop.
canvas draw's edge "A" -> "A" draws the same loop through the same maker instead of no_channel, on
the side from: (else to:) names, so agents can draw what people draw. A row's pick still lists no
note itself. Letting go back on the shape no longer cancels a drag; Escape and empty canvas do.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -2

[2026-11-03 14:32] ASSISTANT:
Running the loop renders in the scratch clone now (in parallel with the full suite).

[2026-11-03 14:32] ASSISTANT:
While the suite and renders run, I'll set up the code review. First, routing the reviewers' models through Jev as this project requires.

[2026-11-03 14:33] WORKFLOW:
Review the self-loop arrow change on the branch by four dimensions, then adversarially verify the serious findings

[2026-11-03 14:33] ASSISTANT:
Three things are running now: the full test suite, the loop renders, and the review. Waiting for them to report back.

[2026-11-03 14:34] ASSISTANT:
Everything for this step is in flight: the full test suite, the offscreen loop renders, and the 4-reviewer review. I'll pick up as soon as each one reports back.

[2026-11-03 14:34] WRAP-UP:
Self-loops are built and committed on the branch (334ff901): drag back onto any shape, ⌘L on one shape, and canvas draw all make a loop. The suites I changed pass; the full test suite, the loop renders and the code review are still running.
Ask:

[2026-11-03 14:34] ASSISTANT:
Self-loops are built and committed on the branch (334ff901). They're not on main, and I haven't tried them in the app on screen; the renders below are offscreen pictures.

- **Drag:** letting go of a dot's drag on the shape it started from now draws a loop on the side of the dot you pulled. The loop shows as soon as you come back over the shape. Letting go back on the shape no longer cancels the drag; Escape or empty canvas still does.
- **Second loop:** another loop on the same side goes around the first.
- **Keyboard:** ⌘L with one shape selected makes the loop, on its right side. The right-click Connect item still only appears with two shapes selected, so it doesn't clutter every single-shape menu.
- **Agents:** `canvas draw` now draws `edge "A" -> "A"` as the same loop instead of refusing it. The canvas skill pages say so.
- **Types:** a type still turns its loop into a relationship type to itself, as before.
- **Typed notes:** one change you'll see is that a note's loop takes the one relationship type that fits it, the same as any drag between two notes. For example, on a Feature board with a Feature-to-Feature relationship type, a Feature note's loop becomes that relationship to itself.
- **Frames:** letting go anywhere inside a frame you dragged from also makes a loop on the frame, because a drop inside a frame counts as a drop on the frame.

The first runs of the three suites I changed (ports, arrow ports, edges) showed four failures. All were old tests pinning the "never ends where it starts" rule; I updated them, and both rerun suites now pass. The full suite, the before/after renders and a code review with 4 reviewers on Sonnet are still running. I'll report their results and send the renders when they finish.

[2026-11-03 14:34] NOTICE:
background task completed: Background command "Render the loop states offscreen in the scratch clone" completed (exit code 0)

[2026-11-03 14:34] ASSISTANT:
The render file needs one more import; fixing and re-running.

[2026-11-03 14:34] ASSISTANT:
The renders are rebuilding after the import fix. The full suite and the review are still running; I'll report when they finish.

[2026-11-03 14:36] NOTICE:
background task completed: Background command "Re-run the loop renders in the scratch clone" completed (exit code 0)

[2026-11-03 14:37] ASSISTANT:
The review is back: 2 confirmed findings plus several unverified low ones. Reading the full list.

[2026-11-03 14:41] ASSISTANT:
Working through the review's fixes: the relationship-index fix and doc corrections are in; now adding the last tests for them before re-running the affected suites.

[2026-11-03 14:42] ASSISTANT:
Running the affected suites again (arrow ports, ports, edges, Types, and the shipped CompositionTests) with the review fixes.

[2026-11-03 14:42] ASSISTANT:
While the tests run, I'll put the renders on one labeled sheet so they're easy to look at.

[2026-11-03 14:43] ASSISTANT:
Missing import in the shipped test; adding it and re-running.

[2026-11-03 14:43] ASSISTANT:
The renders are on a sheet; the re-run of the affected suites with the review fixes is going. Waiting for it to finish before committing the fixes.

[2026-11-03 14:45] NOTICE:
background task completed: Background command "Re-run the affected test suites" completed (exit code 0)

[2026-11-03 14:45] ASSISTANT:
The Types tests are re-running with that fix; I'll commit once they pass.

[2026-11-03 14:46] NOTICE:
background task completed: Background command "Re-run the Types tests" completed (exit code 0)

[2026-11-03 14:46] ASSISTANT:
Types passes now (1408/1408). Committing the review fixes, then a final full-suite run (it skips anything unchanged since it last passed).

[2026-11-03 14:46] GIT:
git add -A Sources Tests docs .claude/rules .claude/skills CLAUDE.md && git status --short && git commit -q -F - <<'EOF'
Fix what reviewing the loops found

A loop on a note counted only on the from side: a relationship type of a type to itself with its
ends named apart gives two rows, and the note's loop showed in one and left a Needed other row
empty though the note is both ends of it. A note's relations now put an arrow at the note at both
ends (a loop, or the note and a pill for it, as the recorded edges have it) on both sides, in the
committed reading and in a run's alike, and a row counts it once. canvas draw refuses a self edge
that names two different sides (from: top to: bottom), since a loop is on one; a port's drag with
Shift snaps around the start shape's middle, so the loop moving its start never moves the snap; a
loop whose ends a person swapped holds no slot. keyboard.md and a comment no longer say Connect
needs two shapes, and the docs say a loop bows out past the line between its ends. Tests pin
nesting on every side, a disc's round side, a short side, a swapped loop, a drag that leaves for
empty canvas and comes back, ⌘ held over the shape, ⌘L on a type and on a typed note, and a frame's
drag let go on the frame it holds.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -3

[2026-11-03 14:46] ASSISTANT:
Final full-suite run is going; once it passes I'll report with the renders.

[2026-11-03 14:48] NOTICE:
background task completed: Background command "Run the whole test suite once more" completed (exit code 0)

[2026-11-03 14:48] ASSISTANT:
Full suite passes ("all test executables passed"). Sending the renders and wrapping up.

[2026-11-03 14:48] WRAP-UP:
Self-referencing arrows work from any shape with dots: drag back onto it, ⌘L on one shape, or canvas draw. Reviewed, fixed, full suite passing; two commits on the branch, not on main, not yet tried in the app on screen.
Ask: Land it on main?

[2026-11-03 14:48] ASSISTANT:
Self-referencing arrows now work on every shape with dots: notes, subboards, frames and reference pills. The full test suite passes. It's two commits on the branch, not on main. I haven't tried it in the app on screen; the sheet above is offscreen renders from the branch.

**What you'll see**
- **Drag:** drag from a dot, come back over the same shape, and let go. You get a loop out of the side you pulled from and back into it. While you're back over the shape, it's outlined and the loop shows, so you can see the result before letting go.
- **More loops:** a second loop on the same side goes around the first.
- **Keyboard:** ⌘L with one shape selected makes the loop on its right side.
- **Agents:** `canvas draw` draws `edge "A" -> "A"` as the same loop.
- **Types:** a type dragged onto itself still becomes a relationship type to itself.

**What the review found**
It ran 4 reviewers and checked 2 findings, all on Sonnet. Both findings were real and are fixed:
- **Loop on a note:** in a type related to itself whose two ends have different names (say "parent" and "child"), a note's loop showed in only one of its two rows. A Needed "child" row could then say "needed" on a note that has the loop. The loop now counts in both rows.
- **Stale doc:** `keyboard.md` still said Connect needs exactly two shapes.

I also took four of its smaller suggestions:
- `canvas draw` now refuses a self edge that names two different sides (for example `from: top to: bottom`), since a loop sits on one side.
- Holding Shift during the drag no longer flickers between the loop and a free end.
- A loop whose ends someone swapped no longer blocks a new loop on the opposite side.
- New tests cover all four sides, round shapes and tiny shapes.

Left as is: several loops on a very short side, like a reference pill's, all leave and re-enter at the same two points. They're still drawn nested, so this only shows when you stack loops there.

To try it before landing, build and open the branch's copy of the app:

```bash
cd /Users/zekenie/code/native-canvas/.claude/worktrees/self-referencing-arrows-bug-0c004c && ./build.sh && open build/InfiniteCanvas.app
```

[2026-11-03 15:44] COMPACTED:
(the context was summarized here)

[2026-11-03 16:43] USER:
Land

[2026-11-03 16:43] GIT:
git status --short && echo "--- HEAD/main/merge-base" && git rev-parse --short HEAD main && git merge-base HEAD main | cut -c1-8 && echo "--- branch commits" && git log --oneline main..HEAD && echo "--- main ahead" && git log --oneline HEAD..main && echo "--- main checkout" && git -C /Users/zekenie/code/native-canvas status --short --branch | head -20

[2026-11-03 16:43] GIT:
git rev-parse HEAD main && git merge-base HEAD main && echo "--- branch commits" && git log --oneline main..HEAD && echo "--- main ahead" && git log --oneline HEAD..main && echo "--- main checkout" && git -C /Users/zekenie/code/native-canvas status --short --branch | head -20

[2026-11-03 16:43] ASSISTANT:
Writing the session record now; next I squash, rebase onto main and fast-forward.

[2026-11-03 16:44] COMMIT MESSAGE FILE commit-message.txt:
A drag from a shape's dot let go back on the shape draws a loop arrow from the shape to itself

The owner asked for this once already: "there's no good way to create a self reference. i try
draging from the portal and dropping on the shape but it doesn't work". That round read "self
reference" as a type related to itself, and 46de99cd let only a type's drag end on itself, turning
it into a relationship type; on every other shape the drag still ended nowhere. Trying it again, the
owner got no arrow and asked what went wrong: the narrowing was ours, said in one line of a long
message and taken as approved. What they want is the general thing: drag from any dot, let go on
the same shape, and get an arrow that loops back to it.

The rule that refused it, "a port's drag never ends where it starts", came over with data-canvas's
ports and was never a decision of the owner's. tldraw keeps an arrow bound to one shape at both
ends, drawn straight between its two anchors through the shape. Here such an arrow is a loop on one
side: both anchors precise on the side of the dot pulled, on the outline (a pill's round end is
short of its bounds), and a bend that bows it out past the side, clockwise round the shape, so
tldraw's own geometry draws it out of the side and back in. The side of the dot, rather than a line
from the dot to wherever the drag was let go, so every loop on a side has one shape and the dot
pulled says where it goes. The bend and anchors are tldraw's properties, so geometry stays a pure
function of the arrow and a person reshapes a loop by its handles; only where the anchors go and how
far it bows are ours (ArrowLoops.swift). A second loop on a side goes round the first, as a second
arrow between two shapes is bent apart from the first, and a delete frees its place; a loop whose
ends a person swapped or moved holds none. The drag shows the loop as soon as its end is back on the
shape (in the commit that binds the end, through bindTerminal's reshape, so no extra commit a move),
and the shape is outlined as a target from the drag's start, so the gesture can be seen before it
is made. Shift snaps the angle around the start shape's middle, so the loop moving the arrow's start
never moves the snap.

One rule for every shape: Connections asks the start as any other end, and SelfConnections, the
type-only switch, goes; whether and how a shape joined to itself is drawn is the connector's to say
(AutomationTests' fixture connector still refuses one). The release still says what the arrow is: a
type's loop becomes a relationship type to itself, as before (kept plain where that can't be made,
as a drag between two types keeps its arrow), and a note's takes the one relationship type that
fits, as any drag between two notes does. A note's loop is a relation at both of its ends: with a
type related to itself whose ends are named apart (parent, child) it is in both of the note's rows,
and counted once in a row both ends share, in the committed reading and in a run's alike, so a
Needed row never calls a note with the loop empty.

The keyboard way is Connect (⌘L) on one shape, a loop on its right side; its right-click item stays
for two shapes, since every one-shape menu would carry it for a rare loop. canvas draw's
edge "A" -> "A" draws the same loop through the same maker instead of no_channel, on the side from:
(else to:) names, and refuses a self edge that names two different sides, since a loop is on one;
so agents can draw what people draw. A row's pick still lists no note itself: a row is a list of
other notes. Letting go back on the shape no longer cancels a drag; Escape and empty canvas do.

Left as is: loops nested on a very short side (a reference pill's) share their two anchors, still
drawn nested.

Session: history/sessions/2026-11-03-self-referencing-arrows-not-working-3d8025cf/
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>

[2026-11-03 16:44] ASSISTANT:
Squashing the two commits into one; first fixing one sentence in the arrows rules that overstates when a loop gives up its slot.

[2026-11-03 16:45] COMMIT MESSAGE FILE commit-message.txt:
arrow between two shapes is bent apart from the first, and a delete frees its place; a loop whose
ends a person swapped, or whose bend they changed, holds none. The drag

[2026-11-03 16:45] GIT:
git reset --soft 2df47fee4fd89cee7b92996828552d21647f607c && git add -A Sources .claude/rules history/sessions/2026-11-03-self-referencing-arrows-not-working-3d8025cf && git status --short | grep -v '^[MADR] ' ; git commit -q -F /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-self-referencing-arrows-bug-0c004c/3d8025cf-422e-4900-b10f-4261b9d5c2f6/scratchpad/commit-message.txt && git log --oneline -2 && git show --stat --format= HEAD | tail -5

[2026-11-03 16:45] GIT:
git status --short && echo "(clean)" && git rebase main 2>&1 | tail -5 && git log --oneline -3

[2026-11-03 16:45] ASSISTANT:
It's merged into main; now removing the worktree and branch.

[2026-11-03 16:45] WRAP-UP:
Self-referencing arrows are on main as 29e9ee4b: one squashed commit carrying this session's record. The worktree and its branch are removed. The loops still haven't been tried in the app on screen.
Ask:

[2026-11-03 16:45] ASSISTANT:
It's on main as 29e9ee4b.

[2026-11-05 15:31] USER:
still does not work for regular stickies

[2026-11-05 15:34] ASSISTANT:
Checking whether the four commits since the fix landed could have broken it; next I'll test current main.

[2026-11-05 15:37] ASSISTANT:
I've confirmed none of the four commits since the fix landed touch the loop's code. Now writing a test that drives plain sticky notes through the app's real canvas view with mouse events.

[2026-11-05 15:38] ASSISTANT:
While those run: once they pass, I'll rebuild the main checkout's app, the one your board files open in, so you have a build that has the fix.

[2026-11-05 15:38] WRAP-UP:
The main checkout's app was built Nov 2, a day before the loop fix landed on Nov 3, so it can't make loops. A test of plain sticky notes through the app's real canvas view is running on current main. Rebuilding main's app comes after it passes.
Ask:

[2026-11-05 15:38] ASSISTANT:
The likeliest cause is an old build. The fix landed on main Nov 3, but the app in the main checkout (the build your board files open in) was last built Nov 2. That build has none of it.

I'm not taking that on trust, given this is round 3. A new test is running on current main: it drives plain sticky notes through the app's real canvas view, using the mouse events a window sends. It covers:
- a drag from each of the four dots, out and back
- a drag straight into the note, slow or held on the note
- a note with a title and several lines, selected first
- letting go back on the dot itself, outside the note. That draws nothing, and might be what you saw.

If it passes, I'll rebuild the main checkout's app so you can try it there. If it fails, I'll have the real bug.

[2026-11-05 15:38] NOTICE:
background task completed: Background command "Run the ports suites and the loop tests on current main" completed (exit code 0)

[2026-11-05 15:39] ASSISTANT:
Only a missing import (`Selection`). Fixing it and running again.

[2026-11-05 15:39] WRAP-UP:
The ports and arrow-ports suites pass on current main. The first run of the new canvas-view loop test didn't compile because of a missing import. That's fixed, and the test is running again before main's app gets rebuilt.
Ask:

[2026-11-05 15:39] ASSISTANT:
The port and arrow-port tests pass on current main (232 tests), so the loop code is intact. The new test, which drags on plain sticky notes through the app's real canvas view, didn't compile on its first run: I'd left out an import. It's fixed and running again, and I'll report when it finishes.

[2026-11-05 15:39] NOTICE:
background task completed: Background command "Run the loop tests in the composition suite again" completed (exit code 0)

[2026-11-05 15:41] GIT:
python3 - <<'EOF'
from pathlib import Path
p = Path(".claude/rules/connections.md")
t = p.read_text()
old = "nesting and the slot a delete frees, Escape and a free release, a disc on its own channel) hold it."
assert t.count(old) == 1, t.count(old)
new = ("nesting and the slot a delete frees, Escape and a free release, a disc on its own channel) hold it, and CompositionTests' "
       "`loopWindowTests` the same on plain notes through the app's canvas view, with the mouse events its window hands on (from each dot "
       "out and back, straight in slowly or held past the precise timer, a selected note with a title and several lines, and a release "
       "back on the dot, off the note, which draws nothing).")
p.write_text(t.replace(old, new))
print("ok")
EOF
git add Tests/CompositionTests/LoopWindowTests.swift Tests/CompositionTests/main.swift .claude/rules/connections.md && git commit -q -F - <<'EOF'
Hold a plain note's loop through the app's canvas view, with real mouse events

The owner tried a sticky's loop again after it landed and got none: the app they ran was built before
the loop landed, and nothing on main had broken it. Every loop test so far drove the editor itself
(the arrow-ports fixtures, the shipped notes through the harness), so nothing held the path the app
takes, mouse events through the canvas view. These hand the events to the app's CanvasView in an
unshown window, as its window does, on plain notes with the shipped plugins: a drag from each dot out
past the note and back, straight in slowly or held past the precise timer, a selected note with a
title and several lines, and a release back on the dot it started from, off the note, which draws
nothing, so a person who lets go there sees nothing by design.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -1

[2026-11-05 15:41] WRAP-UP:
Plain sticky loops work on current main, tested through the app's real canvas view with mouse events. The main checkout's app was built Nov 2, before the fix landed, and needs a rebuild in your shell. The new test is committed on branch self-loops-stickies, not on main.
Ask: Does the rebuilt app make the loop?

[2026-11-05 15:41] ASSISTANT:
The loop code on main works. The app you tried was built on Nov 2, a day before the fix landed on Nov 3, so it has none of it. None of the four commits on main since then touch the loop's code.

I tested current main on plain sticky notes, sending mouse events through the app's real canvas view, and all four new tests pass:
- a drag from each of the four dots, out past the note and back
- a drag straight into the note, slow or resting on it
- a note with a title and several lines, selected first

The port and arrow-port suites pass too.

This session is held to its worktree, so I can't rebuild your app from here. Run this in your shell:

```bash
cd /Users/zekenie/code/native-canvas && ./build.sh && open build/InfiniteCanvas.app
```

The menu bar should read plain "Infinite Canvas"; a copy built in a worktree has the worktree's name in parentheses. Then press a dot, drag, come back over the note, and let go. The note gets the target outline and the loop appears before you release. If you let go on the dot itself, which sits just outside the note, nothing is drawn, by design.

The new test is committed on branch `self-loops-stickies` and isn't on main.

[2026-11-05 15:52] USER:
i rebuilt justopen app

[2026-11-05 15:53] ASSISTANT:
Main's app was rebuilt today at 9:44, so it has the fix. It isn't running yet; opening it now.

[2026-11-05 15:53] WRAP-UP:
The main checkout's app, rebuilt today with the loop fix, is open. Loops haven't been tried in it yet. The new canvas-view test is committed on branch self-loops-stickies, not on main.
Ask: Does a sticky's loop work now?

[2026-11-05 15:53] USER:
[Request interrupted by user]

[2026-11-05 15:53] USER:
Works, land the test

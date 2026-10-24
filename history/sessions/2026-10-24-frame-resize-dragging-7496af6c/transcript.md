# Frame resize dragging

Claude Code session `7496af6c-9c29-48b2-9614-024bc0824a79`, 2026-10-24 02:30 to 2026-10-24 12:34 UTC, on `claude/frame-resize-dragging-f32bc9`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-24 02:30] USER:
[image attached]

[2026-10-24 02:30] USER:
I'd like to expand this frame to the right. I can only drag it at the corner and at the midpoint of the right side. I wish I could drag it on any point of the blue line.

[2026-10-24 02:31] ASSISTANT:
Looking at how the select tool finds resize handles; next I'll make a press anywhere along a selected box's side take that side.

[2026-10-24 02:32] ASSISTANT:
Checked tldraw: its sides are invisible hit bands running the full length, 6 points either side of the edge. Now checking what else asks for handles under the pointer (ports do).

[2026-10-24 02:33] ASSISTANT:
I have what I need for a plan. Your memory says to show it before writing code, so here it is.

[2026-10-24 02:33] WRAP-UP:
The plan is ready and no code has changed. Pressing anywhere along a selected box's side will move that side, using tldraw's hit band, extended to cover the blue outline. Ports keep their dots, and the tests and docs change with it.
Ask: Build it as planned?

[2026-10-24 02:34] ASSISTANT:
Right now a side resizes only from the round handle in its middle. There's a test that says so on purpose: "between two handles, the edge is the shape's". I'd change that so a press anywhere along a side grabs it, which is how tldraw works: its sides are invisible hit areas that run the whole length.

**Plan**
- **Hit test:** in [Handles.swift:71](Sources/Selection/Handles.swift:71), the round handles are still checked first, as now. If none is hit, a point on a side's band returns that side's handle (`.right`, `.top`, …). The resize itself doesn't change, since a side's drag only reads the pointer's movement across the side. The cursor, the press and the drag all follow from that one lookup.
- **Band width (my call):** tldraw uses 6 points either side of the edge. Our blue outline sits 4 points outside the box, so the band runs from 6 inside the edge to 6 past the outline. As with the round handles now, a side too short to show its middle handle gets no band.
- **Hover look (my call):** the resize cursor, plus the halo on that side's middle handle to show which side you've grabbed. tldraw shows only the cursor. The second button skips the halo.
- **Ports:** a selected note's connection dots currently disappear while the pointer is on a handle. With bands along every side, they would blink out every time you move across an edge toward a dot. I'd keep a shape's dots showing while the pointer is on its resize handles. That's one line in `PortState`.
- **Tests and docs:** flip that test and add new ones: a press on the edge, on the outline and just inside; the side moving while the opposite one stays put; and the dots staying up. Update the selection and connections topic files and the Resizing section of the guide.

Frames stuck past the edge, like the cards in your screenshot, won't block it: the edge wins over shapes beneath it, as the handles already do. The frame's title tab still wins over the edge.

[2026-10-24 02:35] USER:
Go ahead and build it as planned.

[2026-10-24 02:36] ASSISTANT:
Now the code. First the side lookup in Selection.

[2026-10-24 02:36] ASSISTANT:
Now the doc comments that describe the handles, then ports.

[2026-10-24 02:37] ASSISTANT:
Code is in. Now the tests: flip the old "edge is the shape's" check and add the side cases.

[2026-10-24 02:38] ASSISTANT:
Tests written. Now the docs: the selection and connections topic files and the guide's Resizing section.

[2026-10-24 02:38] ASSISTANT:
Docs updated. Checking the guide's Ports section for the same "a handle hides the dots" claim, then building.

[2026-10-24 02:38] ASSISTANT:
Now building and running the affected tests.

[2026-10-24 02:40] ASSISTANT:
The targeted tests pass: 32 in SelectionTests, and the new ports test. Now the full suite, which includes the census of every clickable thing.

[2026-10-24 02:40] ASSISTANT:
While the full suite runs, I'll wait before building the app so the benchmark tests aren't run under extra load.

[2026-10-24 02:40] ASSISTANT:
That was a comment-only reflow, so the running suite still tests the same code. Waiting for it to finish.

[2026-10-24 02:40] ASSISTANT:
The full suite is still running; I'll pick up when it finishes.

[2026-10-24 02:46] NOTICE:
background task completed: Background command "Run the full test suite in the background" completed (exit code 0)

[2026-10-24 02:48] ASSISTANT:
Passes. Now noting this in the frames topic file and the guide's Frames section.

[2026-10-24 02:48] ASSISTANT:
The full suite's only failure was that frames test, and it now passes. Building the worktree's copy of the app so you can try it.

[2026-10-24 02:49] WRAP-UP:
A selected box's sides now resize from any point along them, and the worktree app is built. The full suite passes after one frames test was changed: a selected frame's border now resizes instead of moving it. Nothing is committed, and I haven't tried it in the app on screen.
Ask: Keep the border-resizes-a-selected-frame behavior?

[2026-10-24 02:49] ASSISTANT:
You can now resize a selected box by dragging any point along a side, not just the corner and middle handles. It applies to every resizable kind: frames, notes, subboards. The full test suite passes, and the worktree's app is built, but I haven't tried it on screen myself.

**How it behaves**
- **Where a side catches:** from 6 points inside the edge to 6 points past the blue outline. The round handles still win near them, and the drag is the same one the side's middle handle gives.
- **Hover:** the resize cursor shows, and the side's middle handle lights up.
- **Short sides:** a side too short to show its middle handle doesn't catch, so small shapes can still be grabbed and moved.
- **Port dots:** a selected note's dots stay visible while the pointer is on its edge, instead of blinking out as you move toward one.

**One thing I didn't foresee in the plan.** A frame that holds shapes can only be grabbed by its border or its title tab, since its inside belongs to the canvas. Once the frame is selected, that border now resizes it. To move a selected frame, drag its title tab, or press and drag the border in one go before it's selected. That's what you asked for (the blue line only shows when it's selected), and tldraw works the same way. But it changed a test that said a selected frame's border moves it, so it's your call.

The main change is in [Resizing.swift](Sources/Selection/Resizing.swift) and [Handles.swift](Sources/Selection/Handles.swift), plus one line in [PortState.swift](Sources/Connections/PortState.swift). The new tests are in [ResizeTests.swift](Tests/SelectionTests/ResizeTests.swift) and [DotTests.swift](Tests/PortsTests/DotTests.swift), and the topic files and the guide are updated. To try it:

```bash
open /Users/zekenie/code/native-canvas/.claude/worktrees/frame-resize-dragging-f32bc9/build/InfiniteCanvas.app
```

[2026-10-24 03:02] USER:
do not understand

[2026-10-24 03:02] ASSISTANT:
Sorry, here it is more simply.

**Before:** with a frame selected, dragging its border moved the whole frame.

**Now:** with a frame selected, dragging its border resizes it. That's what you asked for: the blue line is the border of a selected frame.

**The side effect:** there's one fewer way to move a selected frame. You can still move it by:
- dragging its title tab ("Frame" in your screenshot), or
- clicking empty canvas to deselect it, then dragging its border.

Is that trade-off OK, or do you still want the border to move a selected frame?

[2026-10-24 03:06] USER:
yes that's what i want. to drag it you drag from the title adornment or maybe maybe the background of the frame

[2026-10-24 03:06] WRAP-UP:
A selected frame's border now resizes it, and the title tab moves it; you've confirmed that. The change is built and tested in the worktree but not committed.
Ask: Should dragging a selected frame's background move it?

[2026-10-24 03:06] ASSISTANT:
Good, it stays as built: the border resizes a selected frame, and the title tab moves it.

Dragging from the frame's background isn't built. tldraw does this: with a frame selected, a drag on its empty background moves it. The cost is that a drag inside a selected frame stops drawing a selection box around its notes. You'd click away to deselect the frame first, then drag to select inside it. With nothing selected, a drag inside a frame would still draw a selection box as it does now.

[2026-10-24 03:06] USER:
Yes: dragging the background of a selected frame moves it, as in tldraw.

[2026-10-24 03:08] ASSISTANT:
Now tests. Looking for where the multi-selection background drag is tested, to put the single-shape case beside it.

[2026-10-24 03:09] ASSISTANT:
Code and tests are written. Running the Selection, ContextMenus and frames tests now.

[2026-10-24 03:11] ASSISTANT:
All pass. Now the docs for the background drag.

[2026-10-24 03:11] ASSISTANT:
Docs done. Running the full suite again, since the press change touches every selection test.

[2026-10-24 03:11] ASSISTANT:
The full suite is running. Once it passes I'll build the app.

[2026-10-24 03:17] NOTICE:
background task completed: Background command "Run the full test suite in the background" completed (exit code 0)

[2026-10-24 03:17] ASSISTANT:
All tests pass. Building the app.

[2026-10-24 03:19] WRAP-UP:
A selected frame now moves when you drag its empty background, and its border resizes it. All tests pass and the worktree app is built. Nothing is committed, and I haven't tried it on screen.
Ask:

[2026-10-24 03:19] ASSISTANT:
With a frame selected, dragging its empty background now moves it, along with what's inside. All tests pass and the app is built, but I haven't tried it on screen myself.

How a frame behaves now:
- **Not selected:** a drag inside it draws a selection box around its notes, as before.
- **Selected:**
  - Dragging the empty background moves the frame.
  - Dragging any point of the border resizes it.
  - Dragging a note inside it still moves just that note.
  - A click on the background deselects the frame.
  - A right-click on the background gives the frame's menu.
- **The title tab** moves it either way.

The same rule applies to any single selected shape with a box, as in tldraw. In practice, only frames and odd-shaped boxes notice. Arrows are left out.

```bash
open /Users/zekenie/code/native-canvas/.claude/worktrees/frame-resize-dragging-f32bc9/build/InfiniteCanvas.app
```

[2026-10-24 12:33] USER:
land

[2026-10-24 12:34] ASSISTANT:
The user said "land", so this is the go-ahead. One wording fix first: I claimed tldraw parity for a case I didn't check. Then the record, the commit, the rebase and the merge.

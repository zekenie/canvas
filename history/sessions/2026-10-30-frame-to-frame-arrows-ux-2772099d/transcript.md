# Frame-to-frame arrows UX

Claude Code session `2772099d-f1ca-48fc-b958-dcafed120293`, 2026-10-30 00:35 to 2026-10-30 12:47 UTC, on `claude/frame-arrows-ux-cb3185`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-30 00:35] USER:
it's not possible to draw arrows from frames to other frames, this is unfortunate! but there are some ux concerns to consider before we just add portals. consider the interactions

[2026-10-30 00:36] ASSISTANT:
Reading the frames and ports rules now, then the code that decides what a press on a frame does.

[2026-10-30 00:40] ASSISTANT:
Pulled tldraw's current source (5.6.0) to see how it lets arrows land on frames; reading that next.

[2026-10-30 00:40] ASSISTANT:
Confirmed tldraw makes a frame's whole inside a drop target for arrows; now checking whether our arrow geometry already handles an arrow into the frame that holds it.

[2026-10-30 00:43] ASSISTANT:
Nearly done reading code; one last check on whether hovering a frame's tab counts as hovering the frame, then I'll write it up.

[2026-10-30 00:44] ASSISTANT:
The design picture is clear now. Before writing it up, I'll check the mockup kit so I can show where the dots, the frame's grab strip and the tab collide.

[2026-10-30 00:47] ASSISTANT:
I have what I need. One picture will make the collisions obvious, so I'm drawing a two-panel mockup (ports added as they are vs. proposed) with the mockup kit.

[2026-10-30 00:50] ASSISTANT:
The mockup reads clearly. Sending it, then the write-up.

[2026-10-30 00:51] WRAP-UP:
I went through how arrows from frames would behave if frames got ports the way notes have them, checked against the code and tldraw 5.6.0, and drew a mockup of the alternative. Nothing is built yet.
Ask: Build frame arrows this way?

[2026-10-30 00:51] ASSISTANT:
Adding ports to frames the way notes have them runs into one problem: a frame is hollow. Only its edge strip (6 points either side of the edge) and its title tab count as the frame; a press inside it is a press on the canvas. Ports would put their dots right on that strip and tab, and an arrow could only end on that thin strip.

How each interaction plays out, and what I'd do:

- **Showing the dots.** As things stand, the dots would appear when you touch a frame's edge or tab. They'd then stay up while the pointer is anywhere inside, until a note there takes over. I'd show a frame's dots only while the pointer is near its edge.
- **Pressing.** A press within 12 points of a dot goes to the dot. That takes over the middle of every side's strip, which is where you move a frame (or resize it, when it's selected). The top dot also sits on the title tab whenever the title reaches halfway. Zoomed out, most titles do, because the tab stays the same size while the frame shrinks.
  - I'd drop the top dot. The arrow still leaves from whichever side faces its target.
  - Where a dot is over a frame's edge, it would take only a press on the dot itself. That also fixes the open frames follow-up where a note's dot takes presses meant for the frame's edge.
- **Dropping.** tldraw (5.6.0) lets an arrow end anywhere in a frame's empty inside. Copied as is, missing your target between two shapes inside a frame would attach the arrow to that frame, and it would end in mid-air inside it. I'd copy tldraw with one change of ours: a frame that holds the arrow's other end is never a target. Drawing inside a frame works as it does today, and from outside you can drop anywhere in a frame.
- **A frame and what it holds.** An arrow between them would start or end at a point inside the frame, usually its middle. That's tldraw's rule for nested shapes, and our arrows already follow it. Dragging, re-aiming and ⌘L would skip that pair.
- **What frames connect to.** I'd add a new frame-to-frame channel. Subboards take every channel, so frame-to-subboard comes along, and so do reference pills for frames. Notes stay off frames, so dragging from a note doesn't outline every frame in view; letting notes connect later is a one-line change.
- **Huge frames, zoomed far out.** Dots sit at the middle of each side and only show at 25% zoom and up, so a big frame's dots can be off screen. Selecting two frames and pressing ⌘L works at any zoom; today it refuses with a shake.
- **Later changes need nothing new.** Arrows follow a moved frame, and a deleted frame's arrows stay where they were drawn. Turn into Subboard keeps the frame's id, so its arrows carry over.

`canvas draw` and the canvas skill change too: an edge between two frames, or between a frame and a subboard, gets the new channel instead of `channel: none`.

[2026-10-30 00:54] USER:
Yes, build it

[2026-10-30 00:57] GIT:
git merge-base --is-ancestor HEAD main && echo "HEAD is behind main" && git log --oneline HEAD..main | cut -c1-140 && git merge --ff-only main 2>&1 | tail -2 && git rev-parse HEAD

[2026-10-30 00:57] ASSISTANT:
Level with main now (one new frames commit came in). Reading the ports plugin, its overlay and the arrow side of a port's drag.

[2026-10-30 00:57] ASSISTANT:
Mapping every place an arrow's end gets bound (drag, re-aim, a moved arrow, ⌘L) so the "never a frame and what it holds" rule lands in all of them.

[2026-10-30 00:59] ASSISTANT:
Frames will need Connections in its module line, and every test list that installs frames will then need the ports plugin too; checking which lists those are.

[2026-10-30 01:01] ASSISTANT:
Next: how `canvas draw` reports a pair the arrow maker refuses, since a frame and what it holds will now be refused there too.

[2026-10-30 01:02] ASSISTANT:
Confirmed tldraw looks inside frames for a moved arrow too, so one change to the arrow's hit lookup covers both. Checking the geometry API for an inside test, then I'll start writing code.

[2026-10-30 01:03] ASSISTANT:
Writing code now. First the core and ports pieces, then arrows, then the frames plugin; tests after. Reading the test fixtures I'll build on first.

[2026-10-30 01:03] ASSISTANT:
Starting the build: the core lends a shape's chain of containers, which the ports rule reads.

[2026-10-30 01:03] ASSISTANT:
Now the ports side: a port's drag never ends on a shape that holds, or is held by, the one it started from.

[2026-10-30 01:04] ASSISTANT:
Now the two ports behaviors: a frame's dots stay up only near its edge, and over a frame's edge a dot takes only a press on itself (while still keeping its shape's dots in view as you approach).

[2026-10-30 01:05] ASSISTANT:
Ports done. Now arrows: a binding rule can see the shapes around it, the connector refuses a frame and what it holds, and an arrow's end counts a frame's whole inside.

[2026-10-30 01:05] ASSISTANT:
Now the arrow's end counting a frame's whole inside (tldraw's `hitFrameInside`).

[2026-10-30 01:06] ASSISTANT:
Arrows done. Now frames get the channel and three dots.

[2026-10-30 01:06] ASSISTANT:
Now the module graph: Frames uses Connections, and FramesTests installs the ports plugin.

[2026-10-30 01:06] ASSISTANT:
Updating the existing test calls of the binding check to the new signature.

[2026-10-30 01:06] ASSISTANT:
Now `canvas draw`: an edge between a frame and something it holds is refused with its own message, before any channel is picked.

[2026-10-30 01:07] ASSISTANT:
Core code is in. Running the module-graph audit, then a build with the frame and port tests to catch compile errors early.

[2026-10-30 01:08] ASSISTANT:
While that builds, I'll update the skill, rules and guide text.

[2026-10-30 01:08] ASSISTANT:
Updating the skill's three tables and its channel paragraphs.

[2026-10-30 01:08] ASSISTANT:
Now the digest skill, which still says frames have no ports; I'll keep its behavior (it drops edges at frames) and fix only the reason it gives.

[2026-10-30 01:09] ASSISTANT:
Now the rules files, starting with frames.

[2026-10-30 01:09] ASSISTANT:
Now connections.md: the hover and press rules, the containment rule, Connect, and what ships.

[2026-10-30 01:10] ASSISTANT:
Now arrows.md: the inside-of-a-frame target (tldraw's own) and the containment rule (a deliberate deviation from tldraw).

[2026-10-30 01:11] ASSISTANT:
Docs mostly done; adding the arrows note to the guide while the build runs.

[2026-10-30 01:11] ASSISTANT:
Everything compiles. Two expected kinds of failure so far: the registry report line, and some shipped tests; reading the CompositionTests ones.

[2026-10-30 01:11] ASSISTANT:
Now the shipped ports tests: rewriting the one that assumed frames take nothing, and adding frame cases. Reading the file first.

[2026-10-30 01:12] ASSISTANT:
Rewriting the shipped test that assumed frames take nothing, then adding the new tests. First a shared fixture: a container hit only on its edge, as a frame is, for the fixture-level tests.

[2026-10-30 01:14] ASSISTANT:
Writing the fixture-level tests now: ports (dots near a hollow container's edge, the disc-only press) and arrow ends on containers.

[2026-10-30 01:16] ASSISTANT:
Fixture tests written. Now the shipped tests: ⌘L between frames, a frame's own drag, and `canvas draw` edges at frames.

[2026-10-30 01:17] ASSISTANT:
Writing the shipped tests now (ports drags, ⌘L, and `canvas draw`).

[2026-10-30 01:18] ASSISTANT:
Now the `canvas draw` shipped test, added to the command-line suite.

[2026-10-30 01:18] ASSISTANT:
All new tests are in. Running the full suite in the background while I finish the rules' testing notes.

[2026-10-30 01:19] ASSISTANT:
While the suite runs, I'll prepare the renders of the result (a throwaway test, never committed). Checking the render helpers first.

[2026-10-30 01:20] ASSISTANT:
A compile slip in my new test (wrong undo call); fixed. Re-running the suite.

[2026-10-30 01:20] ASSISTANT:
While the suite runs, drafting the throwaway render test (kept in the scratchpad until the run ends, never committed).

[2026-10-30 01:21] ASSISTANT:
While the suite runs, reviewing my own source diff once.

[2026-10-30 01:21] ASSISTANT:
Spotted one more expectation to update: the query vocabulary's list of edge types now ends with `frame-link`.

[2026-10-30 01:21] ASSISTANT:
Waiting on the suite (third run, after two compile slips in my new tests). Docs and tests are written; renders and the review come next.

[2026-10-30 01:22] ASSISTANT:
Still waiting on the suite; meanwhile I'll draft the commit message (intent first, as you like them).

[2026-10-30 01:23] COMMIT MESSAGE FILE commit-message.txt:
Arrows join frames: a frame has ports on its own channel, its edge keeps its press, and no arrow joins a frame and what it holds

The owner found it unfortunate that no arrow could be drawn from a frame to another frame, and asked for
the interactions to be thought through before frames simply got ports. The catch was that a frame is
hollow: while it holds shapes only its edge (6 view points either side) and its title's tab are the
frame, and its inside is the canvas. Ports as notes have them would have put a dot, with its 12-point
reach, on the middle of every side of the strip that moves and resizes the frame, and the top one on the
tab; the dots would have stayed up while the pointer worked anywhere inside the frame; and an arrow could
have landed on a frame only on that strip. The owner approved this answer to each, as walked through in
the session:

- Frames have ports on their own channel, `FrameLink` (`frame-link`, the frame's gray), on the right,
  bottom and left: the top edge is the tab's. The arrow starts at the frame's middle and leaves by the
  side that faces where it goes, whatever dot it was drawn from, so three dots lose nothing. A subboard
  takes every channel, so frame to subboard and subboard to frame come with it, and so do reference
  pills for frames. Notes stay off frames (no shared channel), so a note's drag doesn't outline every
  frame in view; letting notes connect to frames is a one-line change if it's wanted.
- A frame's dots show from its edge and its tab and go as the pointer goes in among what it holds
  (`PortState.isNear`: deeper inside a shape's bounds than a dot's reach, only where the shape is under
  the pointer).
- Where a press is on a container (its edge, its tab), a dot takes it only on its disc, so the edge
  moves and resizes the frame right up to its own dots and to the dots of what it holds near it; the
  nearest dot within reach still keeps its shape's dots showing as the pointer crosses the edge to it.
  This was the first of the follow-ups left when frames landed (a note's dot beside a frame's border
  taking its press), which was to be asked about as a cross-cutting change to Ports; frame ports made it
  needed, and it went in with them.
- An arrow's end lands on a frame anywhere inside it, as tldraw's do (`hitFrameInside: true`, checked at
  5.6.0 in its targeting and its moved arrow's probe), what it holds being in front: `Connectables`
  counts a container's outline.
- A deliberate deviation from tldraw: a connection never joins a container and what it holds, at any
  depth, either way round (Connections' `ShapeContext.mayConnect`, over the core's new `nests`). tldraw
  binds an end to the frame holding its other end and draws it into the frame to where it was dropped;
  here a miss between two shapes inside a frame stays a miss, so drawing inside a frame is as it was.
  A port's drag ends on neither and outlines neither, `ArrowPortsPlugin`'s binding rule keeps re-aimed
  and moved ends off the pair whatever the channel (the query now carries the shapes it's judged
  among), Connect (⌘L) shakes, and `canvas draw` says `cannot_connect` with a message of its own, on any
  channel or `channel: none`, since the arrow would draw from inside the frame either way. An arrow a
  move nests stays until it's moved alone, when both ends let go where it's drawn.

`canvas draw` joins two frames, or a frame and a subboard, on `frame-link` where it used to want
`channel: none`; the canvas skill's tables and query.md's edge types say so. The digest still drops an
edge at a frame (a frame is never public, so nothing stands for one across boards, and a note and a
frame share no channel); only the reason it gives changed.

[2026-10-30 01:23] ASSISTANT:
Another compile slip in a shipped test (compared a record where an id was meant); fixed and the suite is running again. I'll wait for it.

[2026-10-30 01:23] ASSISTANT:
While it runs, checking how the project's agent-routing skill wants a review launched.

[2026-10-30 01:23] ASSISTANT:
The connections rules file should also load when someone edits the frames' ports file; adding it to that file's paths.

[2026-10-30 01:24] ASSISTANT:
Still waiting on the full suite (fourth run); fixed one stale test comment meanwhile.

[2026-10-30 01:24] ASSISTANT:
My comment edit landed mid-build and the compiler refused it; my mistake. Re-running, and I won't touch the tree until it finishes.

[2026-10-30 01:33] ASSISTANT:
Fixed. Adding the throwaway render test now (not to be committed), then one full run that covers everything.

[2026-10-30 01:42] ASSISTANT:
All test executables pass (the two earlier timing failures in modules I didn't touch passed this time). Now the renders.

[2026-10-30 01:43] ASSISTANT:
The renders show it working as designed. Composing them into one sheet, then removing the throwaway test from the tree.

[2026-10-30 01:43] ASSISTANT:
Renders done. Committing on the branch (not main) and running the code review.

[2026-10-30 01:43] GIT:
git add -A && git status --short | head -50 && M=/private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-frame-arrows-ux-cb3185/2772099d-f1ca-48fc-b958-dcafed120293/scratchpad/commit-message.txt && printf '\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n' >> $M && git commit -q -F $M && git log -1 --format='%h %s' | cut -c1-120

[2026-10-30 01:44] ASSISTANT:
Fixing the one cheap finding (the doubled container walk in draw's refusal); the rest are documented choices or pre-existing.

[2026-10-30 01:44] GIT:
(TEST_FILTER="canvas draw joins two frames" ./test.sh 2>&1 | grep -E "passed, [1-9]|FAIL|error:|all test" | head; ) && git commit -qam "Draw's refusal of a frame and what it holds walks each end's containers once" && git log -2 --format='%h %s' | cut -c1-100

[2026-10-30 01:45] WRAP-UP:
Arrows can now join frames, built as approved and committed on the worktree branch. Every test passes, and a code review found one small fix, which is in. Nothing is on main yet.
Ask: Land it on main?

[2026-10-30 01:45] ASSISTANT:
Arrows now join frames, built as approved. It's committed on this worktree's branch (two commits), not on main. Every test passes, and the render sheet shows it on the real canvas.

**What changed:**
- **Dots:** frames have dots on their right, bottom and left sides, in the frame's gray. There's no top dot because the title tab owns the top edge; the arrow still leaves from whichever side faces its target.
- **What connects:** a frame connects to another frame or to a subboard, on a new `frame-link` channel. Notes and frames still don't connect to each other.
- **When dots show:** a frame's dots appear when the pointer is on its edge or tab. They go away once the pointer moves in among what the frame holds.
- **Pressing the edge:** where a press lands on a frame's edge, a dot only takes it if you hit the dot itself, so the edge still moves or resizes the frame right up to the dots. This also fixes the old follow-up where a note's dot took presses meant for the frame's edge.
- **Dropping:** you can let go anywhere in a frame's empty area and the arrow attaches to the frame, as in tldraw.
- **A frame and what it holds:** an arrow never joins a frame and something inside it. This is a deliberate difference from tldraw. Dragging, re-aiming and ⌘L all skip that pair.
- **`canvas draw`:** an edge between two frames, or a frame and a subboard, now gets `frame-link`. An edge between a frame and something it holds is refused with its own message, even with `channel: none`.
- **Docs:** the canvas skill, the rules files and the plugin guide are updated. The digest tool still drops edges at frames; only the reason it gives changed.

**Things to know:**
- **Older plain arrows:** `canvas draw` used to allow a plain arrow between a frame and a note inside it. If such an arrow exists, moving it on its own now detaches both ends, and re-running its script is refused. No real boards exist yet, so I treated that as acceptable.
- **The review:** it found one small inefficiency in the draw check, now fixed. One existing issue is untouched: on a selected frame's empty inside, a nearby note's dot can still take a press meant to move the frame.
- **Two flaky runs:** in one full test run, a timing test in language models and one in mentions failed. I didn't touch those modules, and both passed on the next full run.

The render sheet is `/private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-frame-arrows-ux-cb3185/2772099d-f1ca-48fc-b958-dcafed120293/scratchpad/renders/frame-arrows-built.jpg`.

[2026-10-30 02:44] COMPACTED:
(the context was summarized here)

[2026-10-30 12:46] USER:
Land it

[2026-10-30 12:47] GIT:
git status --short; echo "---HEAD/main/base"; git rev-parse HEAD main; git merge-base HEAD main; echo "---main since base"; git log --oneline $(git merge-base HEAD main)..main; echo "---branch"; git log --oneline main..HEAD; echo "---main checkout"; git -C /Users/zekenie/code/native-canvas status --short | head -20; git -C /Users/zekenie/code/native-canvas rev-parse --abbrev-ref HEAD; echo "---last trailer format"; git log -1 --format=%B main | tail -4; echo "---build app"; ls -d build/InfiniteCanvas.app 2>/dev/null

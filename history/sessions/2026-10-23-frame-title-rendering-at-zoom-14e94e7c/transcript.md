# Frame title rendering at zoom

Claude Code session `14e94e7c-664f-48e1-b0e9-fe6b6d784951`, 2026-10-23 03:02 to 2026-10-23 13:15 UTC, on `claude/frame-title-zoom-ux-ee7446`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-23 03:02] USER:
Not a huge fan of the way that frame titles get rendered in the zoomed out view. If you zoom way far out, they're huge. I think they should somehow label the frame without doing that. I'd like a UX agent to take a fresh stab at wireframing alternatives.

[2026-10-23 03:02] ASSISTANT:
Reading how the zoomed-out title cover is drawn today, so the UX agent's brief starts from the real thing.

[2026-10-23 03:03] ASSISTANT:
Building this worktree's app so I can capture real "today" renders of frame titles at several zooms; the UX agent will design against those.

[2026-10-23 03:04] ASSISTANT:
Still waiting on the build; meanwhile I've routed the agent (Jev picked Opus) and compiled the mockup kit.

[2026-10-23 03:05] ASSISTANT:
Captured today's frame titles on two real codebase boards at 100%, 34%, 15%, 6% and 2.5%; checking them now.

[2026-10-23 03:06] ASSISTANT:
The test copy of the app stopped answering; checking why before I hand the agent its brief.

[2026-10-23 03:07] AGENT Wireframe frame-title alternatives:
You are the UX designer for a design round on Infinite Canvas, a native macOS infinite canvas app. The owner doesn't like how frame titles are drawn when zoomed far out ("If you zoom way far out, they're huge. I think they should somehow label the frame without doing that.") and wants a fresh stab at wireframed alternatives.

Your whole brief is in this file; read it first and follow it exactly (paths, ground rules, what to draw, what to hand in):

/private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-codebase-ingestion-sub-board-descriptions-dac84c/14e94e7c-664f-48e1-b0e9-fe6b6d784951/scratchpad/ux/brief.md

Then look at every capture in the brief's TODAY folder (open the PNGs with Read) before designing.

Key reminders: this round writes no app code and changes nothing in the repository; write only inside the brief's `SCRATCH/ux/frame-titles/` folder. Don't run the app, ./build.sh or ./test.sh. Don't read any other checkout or any of the owner's other projects. Fetch tldraw from its upstream GitHub repository (latest release) into your folder; don't browse other sites. Check every PNG you make by opening it with Read, and fix what looks wrong before handing in. The compare sheets are what the owner judges, so make them clean, consistent and legible.

End with the five-line summary the brief asks for, plus the absolute paths of compare.jpg, compare-temporal.jpg, recommended.jpg and design.md.

[2026-10-23 03:07] ASSISTANT:
While the agent works, here's what today looks like on two real boards, so the wireframes have a baseline.

[2026-10-23 03:07] WRAP-UP:
A UX agent (Opus, as Jev routed it) is drawing four to six alternatives for zoomed-out frame labels, laid out against today's renders of two real boards. It's still running, and I'll send the compare sheets when it finishes.
Ask:

[2026-10-23 03:07] ASSISTANT:
I've started a UX agent on Opus (Jev's routing picked it too) to draw alternatives for how frames are labelled when you zoom far out. It's still running. When it finishes I'll send you one comparison sheet: each design in its own row, at 100%, 34%, 15%, 6% and 2.5%, with today's version in the top row.

The sheet above shows today on two of the drawn codebase boards. Captured there, "huge" turned out to be three separate problems:

- **The label's size depends on the frame's size.** Equal frames get unequal labels ("Workflow APIs" is big, "Produc…" is cut off). As you zoom out, a big frame's label stays at its largest size (28 pt) while everything else shrinks, so "Platform layer" ends up as the biggest text on the board.
- **Labels collide.** A frame's label runs into the labels of frames nested inside it and into the shapes it holds. One label also wraps down a narrow column and splits a word ("pattern s").
- **Narrow frames lose their label.** Below 40 points wide on screen there's no label at all, so at 6% none of the Temporal columns says what it is.

I asked the agent to:
- read how tldraw labels frames, from its source, and draw that approach as one of the designs;
- make the rest differ in kind, not just in a number: how big the label is as you zoom, where it sits, whether it has a background, and when it hides, nests or makes way for a neighbour;
- keep the label continuous with the small title tag shown above 35%;
- give the cost of each design;
- say whether the fix should apply only to frames or to every zoomed-out title, since notes and subboards use the same mechanism.

The full brief is at `/private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-codebase-ingestion-sub-board-descriptions-dac84c/14e94e7c-664f-48e1-b0e9-fe6b6d784951/scratchpad/ux/brief.md`.

I opened a copy of the app from this worktree to take these pictures, and it reopened your `native-canvas-feedback` board too; I didn't touch that board. The copy closed partway through.

[2026-10-23 03:49] ASSISTANT:
The agent finished: today plus five directions, drawn on both boards at every zoom. I'm putting together one readable sheet per board.

[2026-10-23 03:50] WRAP-UP:
The UX agent drew today and five alternatives (A–E) on two real boards at every zoom from 100% to 2.5%, with a write-up. It recommends C, map labels. Nothing in the repo changed, and nothing is built.
Ask: Which direction should go forward?

[2026-10-23 03:50] ASSISTANT:
The UX agent drew five alternatives and recommends C, "map labels". The two sheets above compare them with today at 6% on both boards, magnified 2x.

**What's wrong today:** the label's size comes from the frame's size, not from what's readable. At 6%, "Platform layer" is 24 pt and is the biggest text on the screen. At 15%, four layers of equal width get 28, 25.5, 15 and 9 pt. Nested frames' labels print over each other, and narrow columns lose their labels entirely.

**The five directions:**
- **A, tldraw's heading:** the small tag above the corner shrinks with the board. tldraw does this, but it's unreadable below about 15%.
- **B, the pill stays:** today's tag, at the same size, at every zoom. Below 42% each tag lands inside the frame above, so it reads as the wrong frame's name.
- **C, map labels (recommended):** the name stays 11 pt at every zoom.
  - Between 40% and 35% the tag slides into the frame's top-left corner and loses its background, so nothing jumps.
  - Nested frames' names stack under their parent's, like an indented outline.
  - A column narrower than 100 pt gets its name turned down its left edge, so every Temporal column is named at 6%.
- **D, a tab on the edge:** the name sits in a tab across the frame's top edge at every zoom. Narrow columns get no tab.
- **E, on demand:** no labels at rest; the frame under the pointer shows its name. That fails "still say what it is".

**What C costs:**
- Labels lie over the frame's contents, and turned text is harder to read.
- At 2.5%, "Platform layer" still spans about half its frame. If that's too loud, one more rule fixes it: a label disappears once it's wider than half its frame.
- The 11 pt cap would apply to every zoomed-out title, not only frames, so notes and subboards would no longer get large titles either.
- The build is medium-sized, mostly in the Titles module, with no file-format change. Each frame would be cheaper to draw than today.

The rule-by-rule write-up is in `design.md`, and the full zoom ladders for every direction are in `compare.jpg` and `compare-temporal.jpg`. All three are in `/private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-codebase-ingestion-sub-board-descriptions-dac84c/14e94e7c-664f-48e1-b0e9-fe6b6d784951/scratchpad/ux/frame-titles/`. The agent's claim about how tldraw sizes its headings checks out against tldraw's source. The repo is unchanged.

[2026-10-23 11:02] USER:
D speaks to me

[2026-10-23 11:03] ASSISTANT:
Reading the Adornments and Titles code that D's tab would change, so the plan puts each piece in the right module.

[2026-10-23 11:06] ASSISTANT:
Refined D now labels every frame on both boards at 15%. Making one before/after sheet.

[2026-10-23 11:07] WRAP-UP:
D is re-rendered with two fixes: a nested frame's tab slides past its parent's, and a narrow column's tab turns down its left edge, so every frame on both boards at 15% now has a label. The build plan for D is below; no code is written yet.
Ask: Build D with these two fixes?

[2026-10-23 11:07] ASSISTANT:
Here's the build plan for D, with two fixes I added: the sheet above shows D as the agent drew it and with the fixes.

- **Nested frames:** a nested frame's tab slides right past its parent's instead of disappearing ("Things you do" now shows at 15%).
- **Narrow columns:** the tab turns down the column's left edge, so every Temporal column is named at 15% and 6%, where as drawn almost none were.

**What you'll see**
- **The tab:** a frame's title is a tab on its top edge, half above and half below, 10 pt in from the corner. It uses the frame's own fill and border, or its color's, with 11 pt text. It's the same size at every zoom.
- **What it replaces:** the pill on frames at 100%, and the big title zoomed out.
- **Crowding:** tabs give way outermost frame first, then larger frames. A tab that meets another slides right, and is left out only when there's no room in its frame.
- **Grabbing:** pressing a tab grabs its frame at any zoom, as pressing the pill does today, so you can now grab a frame by its name when zoomed out.
- **Untitled frames:** the dimmed "Frame" tab shows above 35% only, as the placeholder does now.
- **Notes and subboards:** they keep today's zoomed-out titles. A note's title is the note when zoomed out; a frame's title labels what it holds.

**Where the code goes**
- **Adornments:**
  - a new place on the top edge, laid flat or turned;
  - a way for an adornment to stay visible zoomed out at a fixed size;
  - one give-way pass per frame over the tabs in view, which drawing and clicking share so what you click is what's drawn.
- **Titles:** a kind opts into the tab when it declares its title. That kind gets the tab instead of the pill and loses the zoomed-out title. Find highlights the tab at every zoom.
- **Frames:** opts in and supplies its colors.
- **Cost:** no change to how boards are saved, so no migration. Each redraw looks only at the frames in view, and I'll add a benchmark for a board of many frames at 6%.

**Two weaknesses I'd accept rather than design around**
- Below about 14%, a frame's tab overlaps the bottom edge of a frame stacked just above it (visible in the 6% cells).
- At 100%, a shape placed by Create Frame (32 units in from the corner) has its own pill touching the tab's lower half. I'll check both in renders while building.

I'll build it in this worktree with tests, update the rules files, and send renders. It goes to code review before anything lands.

[2026-10-23 11:12] USER:
Build D with the two fixes, as planned.

[2026-10-23 11:12] GIT:
git merge-base --is-ancestor HEAD main && echo ancestor; git log --oneline HEAD..main | wc -l; git merge --ff-only main 2>&1 | tail -2; git rev-parse --short HEAD

[2026-10-23 11:12] ASSISTANT:
Brought the branch up to main (2 commits behind, none of its own). Now reading the Adornments code in full.

[2026-10-23 11:14] ASSISTANT:
Now the remaining pieces: how Selection uses decoration hits zoomed out, the visible-rect API, containment depth, Find's zoomed-out ring, and Frames' colors.

[2026-10-23 11:16] ASSISTANT:
I have the full picture. Starting on Adornments: a new place for a tab straddling the top edge, shown zoomed out at a fixed size, with tabs on different shapes giving way to each other.

[2026-10-23 11:17] ASSISTANT:
Writing the pure layout for the tab first: placed flat along the top edge, sliding past tabs already placed, or turned down the left edge on a tall, narrow shape.

[2026-10-23 11:18] ASSISTANT:
Now the tab's look: a tint can carry an edge color, and a tab draws with square-ish corners and can be turned.

[2026-10-23 11:19] ASSISTANT:
Now the state: which labels a shape shows zoomed out (only its tab), and the pass that places every tab in a region so drawing and pointing agree.

[2026-10-23 11:21] ASSISTANT:
Now the overlay draws tabs zoomed out too, turned where placed so.

[2026-10-23 11:21] ASSISTANT:
Adornments' side is written. Now Titles: a kind can ask for its title as a tab in colors it gives shape by shape, which takes the place of both the pill and the zoomed-out cover.

[2026-10-23 11:22] ASSISTANT:
Now Frames: opt into the tab with its own surface and border, and drop the cover it no longer has.

[2026-10-23 11:23] ASSISTANT:
Code is in place across the three modules; building to catch compile errors.

[2026-10-23 11:24] ASSISTANT:
It builds. Opening this worktree's app copy on its own socket (it may pop a window) to capture the two real boards with the tabs.

[2026-10-23 11:24] ASSISTANT:
Real boards now draw tabs at every zoom, matching the mock. Running the full test suite in the background to see what my change breaks, while I write the new tests.

[2026-10-23 11:25] ASSISTANT:
Writing Adornments' tab tests: the pure layout and give-way, then on a board at several zooms.

[2026-10-23 11:26] ASSISTANT:
Now Titles' tests. Reading its fixtures and the cover test that covered containers.

[2026-10-23 11:27] ASSISTANT:
While the suite runs, updating the docs: the rules files for Adornments, Titles and Frames, and the guide.

[2026-10-23 11:27] ASSISTANT:
Updating the guide's Frames section, the Titles bullets and the Adornments places table.

[2026-10-23 11:28] ASSISTANT:
Now the three rules files.

[2026-10-23 11:29] ASSISTANT:
Tests for Adornments and Titles are written and the docs updated; adding a shipped frame test while the full suite runs.

[2026-10-23 11:30] ASSISTANT:
Adding a benchmark of a board full of titled frames zoomed out, so the tabs' cost per frame is held to a budget.

[2026-10-23 11:31] ASSISTANT:
While the first suite run finishes, re-reading my Adornments changes for mistakes.

[2026-10-23 11:31] ASSISTANT:
One fix from re-reading: zoomed out, a hit test would walk every shape in the wide adornment area around the pointer; it only needs the tabs near it.

[2026-10-23 11:31] ASSISTANT:
First run: 9 tests fail across Titles, Frames and Composition, all where they pin the frame's pill or the registry's report. Going through them.

[2026-10-23 11:32] ASSISTANT:
Updating the tests that pinned the frame's pill: its label equality, where it sits, what `canvas measure` says a frame reaches above it (27 → 9), and the pinned report.

[2026-10-23 11:33] ASSISTANT:
The second full test run is going; meanwhile updating the last passage of the guide about how far a shape reaches above its edge.

[2026-10-23 11:33] ASSISTANT:
Before/after renders from the real app are ready. While the third suite run goes, tidying the Titles rules where they still say a frame has a cover.

[2026-10-23 11:34] ASSISTANT:
The third full test run is going (fixed a duplicate test alias that stopped the second). Waiting on its result before committing and reviewing.

[2026-10-23 11:34] ASSISTANT:
The fourth run is going (a missing import stopped the third). Drafting the commit message meanwhile.

[2026-10-23 11:35] COMMIT MESSAGE FILE commit-msg.txt:
A frame's title is a tab on its top edge, the same size at every zoom: zoomed out it was a cover that grew as the board shrank

The owner: "Not a huge fan of the way that frame titles get rendered in the zoomed out view. If you
zoom way far out, they're huge. I think they should somehow label the frame without doing that."
The cover was sized by its frame (0.22 of the shorter side, 9 to 28 points) and fitted to it. Equal
frames got unequal titles, nested frames printed over each other, a long title wrapped down a column
breaking a word, and frames under 40 points on screen got none. On this repo's drawn board at 6%,
"Platform layer" was the biggest text on screen, and none of Temporal's twelve columns had a label.

A UX round wireframed five directions on those two boards: tldraw's heading, which shrinks with the
page below 29% and is unreadable by 15%; the pill kept at every zoom, which below 42% lands in the
frame above; map labels in the corner at 11 points (the agent's pick); a tab on the edge; and labels
only for the frame under the pointer, which says nothing at rest. The owner picked the tab: "D speaks
to me". Two changes to D as drawn were shown in renders before building. A nested frame's tab slides
along its edge past its parent's rather than disappearing. A narrow column's tab turns down its left
edge. As drawn, three of the twelve columns had one at 15%.

- Adornments has a fifth place, `onTopEdge`: a tab half above the top edge and half below, 10 in from
  the corner, as long as its text. It's the one place a skeleton shows, and the same size on screen at
  every zoom (`Slot.tabUnit`). Tabs on different shapes give way to each other. `AdornmentLayout.tabs`
  places them in rank, each sliding along its edge past those before it, and is pure. `AdornmentState.
  tabs(in:)` ranks the shapes in the view: fewest containers first, then larger. The placing is kept
  per view, zoom, revision and labels, so drawing and pointing read one placing and a click finds what
  is drawn. Zoomed out, labels are made only for shapes with a tab; a placeholder's isn't shown. A tint
  may carry an `edge`, the line inside it.
- Titles: `x.titleTab { shape, context in TitleTabLook(surface:edge:) }` (the `TitleTabs` point)
  replaces a kind's pill and its cover with `TitleTab`. Its words are the cover's inks, dark on light
  and light on dark, chosen in the appearance drawn; a look's tint still wins. `titlePillRect` gives
  the tab at every zoom, and Find tints it zoomed out.
- Frames opt in with their own surface and border, a colored frame's from Colors' book, and lose
  their cover.
- Notes and subboards keep their covers. A leaf's title zoomed out is its face; a container's labels
  what it holds.
- `canvas measure` says a titled frame reaches 9 above its edge, where it said 27.

Accepted, said in the plan: below about 14% a frame's tab reaches into the frame stacked just above
it, and at 100% a shape 32 in from the corner (Create Frame's padding) has its own pill touching the
tab's lower half. Cost: one look at each shape in view and a sort of the frames with a tab, a frame;
`Budget.tabsZoomedOut` holds 60 titled frames three deep over the generated board, fitted and at 6%.

[2026-10-23 11:35] WRAP-UP:
Frame tabs are built across Adornments, Titles and Frames, with new tests, a benchmark, and updated docs and rules; real-board captures match the approved mock. The full suite is running for the fourth time; then commit, code review, and fixes.
Ask:

[2026-10-23 11:36] ASSISTANT:
Direction D, with both of my changes, is built. I haven't committed yet: the full test suite is on its fourth run. Once it passes I'll commit on this branch, run a code review and fix what it finds.

How it works now:
- **The tab:** a frame's title sits on its top edge, half above and half below, in the frame's own fill and border (or its color's). It's the same size on screen at every zoom.
- **What it replaces:** the pill above a frame at 100%, and the big title zoomed out.
- **Crowding:** the outermost frame's tab wins, then the larger frame's. A tab that meets another slides right, and a narrow, tall column's tab turns down its left edge.
- **Grabbing:** a tab grabs its frame at any zoom.
- **Untitled frames:** the dimmed "Frame" tab shows in full only, never zoomed out.
- **Notes and subboards** keep today's zoomed-out titles.

The suite so far:
- The first run had 9 failures. All were tests that pinned the old pill or the old registry report; I updated them.
- The second and third runs were each stopped by a compile error in my new tests (a duplicate name, then a missing import); both are fixed.

**One change agents will see:** `canvas measure` now says a titled frame reaches 9 points above its edge instead of 27.

**The two accepted weaknesses from the plan still hold:**
- Below about 14%, a tab overlaps the bottom edge of a frame stacked just above it.
- At 100%, a shape 32 units inside a frame's corner has its pill touching the tab.

I opened this worktree's app copy again to capture both boards; it reopens its own restored windows, so it may show up on your screen. The before/after captures are in `/private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-codebase-ingestion-sub-board-descriptions-dac84c/14e94e7c-664f-48e1-b0e9-fe6b6d784951/scratchpad/sheet/before-after.jpg`; I'll send them once the review is done.

[2026-10-23 11:41] NOTICE:
background task completed: Background command "Run the full test suite again" completed (exit code 0)

[2026-10-23 11:42] ASSISTANT:
The four test fixes are in and the fifth full suite run has started. I'll commit and start the code review once it passes.

[2026-10-23 11:48] NOTICE:
background task completed: Background command "Run the full test suite a fifth time" completed (exit code 0)

[2026-10-23 11:48] ASSISTANT:
All tests pass. Running the frame benchmarks in release to check the tabs' cost against the 16 ms budget.

[2026-10-23 11:48] ASSISTANT:
Committing on the branch while the benchmark builds.

[2026-10-23 11:48] GIT:
git add -A && printf '\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n' >> /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-codebase-ingestion-sub-board-descriptions-dac84c/14e94e7c-664f-48e1-b0e9-fe6b6d784951/scratchpad/commit-msg.txt && git commit -q -F /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-codebase-ingestion-sub-board-descriptions-dac84c/14e94e7c-664f-48e1-b0e9-fe6b6d784951/scratchpad/commit-msg.txt && git log --oneline -1 && git status --short | head

[2026-10-23 11:48] ASSISTANT:
Committed on the branch as `d38d37e3`. Now the code review.

[2026-10-23 11:49] ASSISTANT:
Now checking the release benchmark, then fixing what the review found.

[2026-10-23 11:50] ASSISTANT:
Release benchmark: 13.2 ms against the 16 ms budget at 6% on 10,000 shapes, which leaves little headroom. Fixing the six review findings now, which also cut how often the tabs are placed again.

[2026-10-23 11:51] ASSISTANT:
Now the ink's color provider: building it where nothing main-actor is called inside it.

[2026-10-23 11:52] ASSISTANT:
Builds clean. Adding tests for the review fixes.

[2026-10-23 11:53] ASSISTANT:
I've fixed the six review findings and added tests for them; the full suite and the release frame benchmark are running against the fixes.

[2026-10-23 12:00] NOTICE:
background task completed: Background command "Run the full suite, then the release frame benchmarks" completed (exit code 0)

[2026-10-23 12:00] ASSISTANT:
All tests pass, and the release benchmark holds: 12.6 ms at 6% and 5.5 ms fitted on 10,000 shapes with 60 titled frames, against 16. Committing the fixes.

[2026-10-23 12:00] GIT:
git add -A && git commit -q -F - <<'EOF'
Fix what reviewing the frame tab found: one placing for drawing and pointing, placed again only when a tab's shape changes, titles before placeholders, a tab hit as drawn

- Pointing and `adornmentFrames(of:)` place tabs over the region the overlay last drew where it meets
  what's asked about (`drawnTabs(in:)`, `tabRegion(around:)`), so a slid tab is hit where it's drawn;
  the last four placings are kept, so asking about a shape out of view doesn't throw the view's away.
- `generation` moves only when a shape with a tab, or one placed last, is added, changed, removed or
  forgotten, and the revision is out of the key: tabs give way only to tabs, so a fading chip or a drag
  of notes no longer places every tab in view again.
- Every title is placed before any placeholder: an untitled frame's dimmed "Frame" no longer takes the
  corner from a titled frame inside it.
- A tab is hit as the rounded rect it's drawn as (`distance(from:to:radius:)`), not a capsule.
- `extent(of:in:height:)` counts a tab only where it lies flat on the shape: none for a shape too short
  for one, or one whose tab turns down its left edge.
- The tab's ink is a dynamic color made off the main actor (`TitleTabStyle.inkProvider`,
  `TitleCoverStyle.isLight` nonisolated), so AppKit resolving it on another thread traps on no
  isolation check.

Release, 10,000 shapes with 60 titled frames three deep, the camera moved each frame: 5.5 ms fitted
(10%), 12.6 ms at 6%, against 16.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -3

[2026-10-23 12:00] WRAP-UP:
Frame tabs are built on this branch in two commits (`d38d37e3`, `3f9ed010`); the full test suite passes and the review's six findings are fixed. Nothing is on main yet.
Ask: Land it on main?

[2026-10-23 12:00] ASSISTANT:
Frame titles are now tabs on the frame's top edge, the same size at every zoom, and the full test suite passes. The sheet above compares the two real boards before and after, captured from the built app. It's on this worktree's branch only, not on main.

**What changed:**
- **On this repo's board:** the layer labels no longer grow as you zoom out. The nested ones ("Things you do", "Horizontals: in the window") slide along the edge instead of printing over "Platform layer".
- **On Temporal:** every column is labelled at 16% and at 6%, where before none had a label at 6%. Narrow columns turn their tab down the left edge.

**Review:** the code review found six problems, all now fixed:
- Clicking a tab and drawing it could disagree about where a tab sits after it slides.
- Tabs were laid out again on every unrelated change, such as a fading lock chip.
- An untitled frame's dimmed "Frame" could take the corner from a titled frame inside it.
- The tab's clickable shape didn't match its drawn corners.
- `canvas measure` counted a tab a very short frame doesn't show.
- The tab's text color could crash if macOS worked it out off the main thread, such as for a Quick Look thumbnail.

**Cost:** with 10,000 shapes and 60 titled frames, a frame takes 5.5 ms zoomed to fit and 12.6 ms at 6%, within the 16 ms budget.

**Other changes:**
- `canvas measure` now says a titled frame reaches 9 points above its edge instead of 27.
- The canvas skill's docs say a frame's title is a tab.
- The rules files and the plugin guide are updated.

The two known weaknesses from the plan are still there:
- Below about 14% zoom, a tab overlaps the bottom edge of a frame stacked just above it.
- At 100%, a shape 32 units inside a frame's corner has its own title pill touching the tab.

The work is in two commits on `claude/frame-title-zoom-ux-ee7446`: `d38d37e3` (the feature) and `3f9ed010` (the review fixes).

[2026-10-23 13:14] USER:
Land it on main.

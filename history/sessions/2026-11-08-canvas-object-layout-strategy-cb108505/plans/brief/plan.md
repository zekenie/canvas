# A plan for boards of a codebase

## First screen

**Where things stand.** You have an engine that draws every board with no line over anything (the branch), proof that choosing arrows by meaning beats choosing them by popularity or geometry (the spike), and a ruler for both. You don't have a board you like. The pictures say why: seven in ten links go to other boards, and every one is a pill on a line with an arrowhead, under every strategy. Those lines are the fans, the walls, the "islands" and most of the area. No strategy touched them. The one picture you called "so much better" was the only one drawn with them hidden.

**What I recommend.** Don't pick a strategy. Fix how references look, then join the two good pieces: a reference is a chip docked to its note, no line; an arrow may cross an arrow but never run over a shape; the links that become chips are the least meaningful, by the words two notes share, with a model as an optional upgrade. Everything else stays as built.

**Your decisions.**
1. References lose their lines. Decide on step 1's picture. Replaces "straight lines, wide fans".
2. A few arrow crossings are allowed; lines over shapes never. Replaces "the no-crossing rule replaces the mess dial". I recommend yes.
3. Whether the model (Jev, about 2¢ a repository) joins in. Not now: step 3 shows you both.

**The first step.** One agent, a day, no model calls: Selection, Mentions and Draw redrawn from the slice 4 drawing with references as docked chips and no lines, as pictures beside what you saw last week. You look at six pictures and say whether the chips read better. If not, the rest isn't worth building, and it cost a day.

---

## The plan

Each step ends with pictures of this repository's real boards, and you say whether they read better. "Better" means: a reader can see which files belong together and follow an arrow without losing it; a note's references are findable but don't compete with arrows. A step that doesn't read better stops the plan, and the next move is discussed, not built.

### Step 1. See the chips (a day, no API)

- **What you see:** Selection, Mentions and Draw, three ways each: slice 4 as captured; the same drawing with every pill docked under its note as a chip row and its line removed; and the judges' cut drawn the same way (the picture you liked, with chips instead of hidden pills). Schematic renders from the spike's renderer, since the app can't draw a lineless reference yet.
- **Judged by:** you, on the pictures. Stop if the chips don't read better than the fans.
- **Costs:** one Sonnet agent, a few hours; no model calls, no app change.
- **Leaves out:** any change to which links are arrows. Same cuts as slice 4, only the look changes.

### Step 2. Build the look and the rule (three to five days, no API)

Three changes, built together because each is small alone and they only pay as a set:

1. **Docked chips (an app change, small).** A reference placed touching its note draws no line; direction reads from the side (chips below a note are what it uses). The layout puts a note's chips in rows under it, wrapping, one chip per file as decided, sorted by the board they point to so the eye can group them without the tool grouping them. The strips, fans, and the line-of-sight sharing pass go away with the lines they served.
2. **Lines over shapes forbidden, crossings allowed and counted.** The health check reports crossings as a number per board instead of a failure. The cut stops cutting at crossings. On the branch's own figures, 11% of its post-placement cuts were for crossings and 35% for a neighbour's pill lines, which no longer exist; the rest, lines over shapes, stay forbidden.
3. **Cut by meaning.** The same-board links that become chips are the least meaningful first: word overlap counted within the board (free, offline, deterministic, 0.84 against the judges). How many on each board comes from the background simulation, your idea, which the spike found sets a sensible count by crowding (11% on sparse boards to 70% on the densest). A link marked `direct` is never cut; a link into a frame is an arrow, as slice 4 draws it. The engine's further cuts, where a line would run over a shape, take the lowest-ranked link in the conflict.

- **What you see:** the whole repository drawn in the app: root, Selection, Mentions, Draw, Types/Form, Keyboard, beside slice 4 and main.
- **Judged by:** you, on the boards. And the ruler: on the five judged boards, at least 40 of the 76 links both judges keep are arrows (slice 4 draws 30; the spike's best 42), and at most 15% of the judged arrows are links both judges chip (slice 4: 43%). No line over a shape on any board. The plan runs under 10 s for this repo (slice 4: 45 to 65 s; most of that was packing strips).
- **Costs:** two or three Sonnet builders with one Opus review; no model calls. Not a 25-agent workflow: the last four days spent most of their budget on rounds that returned the least.
- **Leaves out:** Jev; redraw stability; splitting dense boards; grouping chips; hiding any reference. Lands on main only when you say the boards read better, as one squash with the branch's slices.

### Step 3. The model as an upgrade (a day, cents)

- **What you see:** the same boards cut by Jev plus word overlap, beside step 2's. Jev reads each board once and is asked, for every link, whether a reader would want it drawn; answers are cached by board, so an unchanged board asks nothing.
- **Judged by:** you, on the boards. The ruler says Jev lifts keep links drawn from about 35 to 42 of 76 and halves wrong arrows; the question is whether you can see it, and whether a network call in `ingest` is worth that.
- **Costs:** about 2.4¢ for this repository, 8,300 tokens per edited board after. Price from third-party listings, unconfirmed.
- **Leaves out:** any embedding model. On this corpus OpenAI's adds nothing once Jev is in and is within noise of word overlap without it; Apple's made things worse. Prose boards weren't tested, so this is a code-board finding.

### Step 4. Redraws that stay put (two days)

- Revive slice 5's rule, "a redraw moves a shape only for a reason", on the step 2 engine. Its uncommitted code targets the strips and fans and won't merge as is, but its tests (735 runs of a person's drag surviving, byte-identical unchanged redraws, one app test) are the spec.
- **What you see:** edit one file's doc comment, run ingest, watch one note change and nothing else move; drag a note, run ingest, it stays.
- **Judged by:** those two things, in the app. Your "it depends on context" stands as built: held on the redraw that sees it, then an ordinary shape.
- **Leaves out:** remembering a person's change across redraws in the app's record, and splitting dense boards (dropped, below).

## What to do with the existing work

- **Slices 1 to 4 (the branch, 9 commits, not on main).** Keep the engine: the health check, the planar cut as the geometry fallback, stars and rows, frames laid out with their container, links put back where there's room, the public-report fix. Retire with step 2: the strip packer, the fans, the line-of-sight sharing of pills, "clean" meaning no crossing. Don't land now; land with step 2 as one squash, when you've said the boards read better. The plan doc at `docs/plans/board-layout/README.md` is rewritten then; its Decided section gets the three decisions above with dates.
- **Slice 5 (13 files, uncommitted).** Commit it to a side branch today so it isn't lost (`wip/slice5-redraw`), and don't merge it: it was built against the fans. Step 4 rebuilds its rule on the new engine with its tests as the spec.
- **Slice 6, splitting dense boards.** Drop. The study found nothing to split by on this repo and 12 arrows won for 4% more area with ideal groups supplied by hand.
- **The spike and issue 26.** Keep as evidence; it earned its keep. Turn its 459 judged links, their labels and Jev's cached answers into a fixture the tool's tests score every drawing against (keep links drawn, chip arrows, over several counts). Take its pre-plan's items 2 to 4 (word overlap as similarity, the simulation as the count, the engine following the ranking) into step 2, item 1 (Jev) into step 3, and drop item 5's "one pill for each module", which you already declined. When step 2 lands, close the issue with a line pointing at the plan doc: that's yours to post.
- **Main's strategy.** Retired by the landing: the mess dial is gone on the branch already. Nothing of main's to keep but spines on the overview, which stay by decision.

## Reasoning, for whoever builds it

### Three levers, and which one was pulled

A board of code is made of three choices: how references look, what a drawing may not do, and which links become references. The branch pulled the second (no crossing, ever) and the spike the third (meaning). Nobody pulled the first, and the first is the one the pictures blame:

- 5,784 of 8,282 links go between boards (spike README, "How it was measured"); every one is a pill on a line, on every strategy. Selection carries 222 such pills under main, the branch and the spike alike (transcript, 2026-11-10 11:55). "About two-thirds of the pills in that picture stand for links to other boards."
- In the app at 40% (`s3/app/cap/pair-near-SelState.png`) a note's pill lines carry arrowheads and cannot be told from arrows; SelectionState's run 1,000 units. The plan doc's own list of what keeps boards from reading well starts with "the busiest notes' fans of pills".
- The only picture you praised ("this strategy looks so much better", 2026-11-10 13:32) is `judges-cut.jpg`: pills for other boards hidden, 30 arrows, 52 crossings allowed. Hiding the pills halved the board's width (transcript, 12:30).
- Most of the branch's cost is the lines: strips, fans, the sharing pass (45 to 65 s against 3.5 s), area ×2.4, and 35% of the links the stars placement excused were blocked by "a neighbour's pills" (plan doc, Open).

So the first step is the cheapest test of the largest effect, and it is where the "missing piece" you sensed most likely is.

### Information design

- **Proximity over connection.** A line says "related"; touching says "belongs to". A chip docked under a note reads as that note's tag, like an import list under a file, with no line to follow and nothing to cross. This is the software-engineering analogy you drew: a module's imports are listed, not drawn.
- **One pill per file stands.** Chips are small, so 62 under TypesPlugin.swift is eight rows, about the note's own height, not a 1,000-unit fan. Sorting them by target board is ordering, not grouping; it stays one chip a file. A fold ("+54") would be the app's, not the tool's, and would brush against that decision, so it isn't in this plan.
- **Hierarchy.** Overview: modules as cards, spines and ranks as decided. Module board: files as notes, arrows for uses on this board, chips for uses elsewhere. Note: its text, then its chips. A reader zooming in sees arrows first and chips last, which is the order of importance; today it's the reverse.
- **Where on the continuum.** Between "ball of mud" and "islands", the right place is a hand drawing's: a few crossings, no line through a box, arrows on the links a person would draw. The judges' cut of Selection (30 arrows of 88) is the one point on that continuum you've approved, and it has 52 crossings. Planarity forbids all of them and pays with 57% of the links cut (spike, "Against main and the layout branch"). Over-shape is the rule a hand drawing keeps; crossings are a count it minimises.
- **How many references a board can bear.** Unknown until step 1; the bound is the note's chip rows, not the board. The render will say.

### UX

- **Who opens these and why.** A person new to the codebase, reading a module board to see what belongs with what; a person who knows it, checking who uses a file; an agent, which never sees the picture and reads edges through `canvas query`, where a pill already counts as its target (References: "B→R is, for everything, B→A"). Agents are unaffected by any of this.
- **The first minute.** Open the root, open a module, read the arrows, hover a note to light what it uses (Neighbors already does this), click a chip to go to the file on its own board, Back to return. Chips make the second and third moves possible without a wall of lines in the way.
- **Edits and redraws.** Step 4's rule. The one case left open, a note carried out of its frame returning on the second redraw, needs the app to remember the carry; leave it.
- **Trust.** Every step names what it uses: step 1 and 2 call no model; step 3 calls Jev and says so in the report. The words "embedding", "similarity" and "model" don't appear in a step that doesn't do that thing.

### Evidence for each recommendation

- *Docked chips.* The three bullets above; the plan doc "Tried and dropped" (bending lines left 1,300 to 1,900 lines over own pills; rings cost four times the area; columns were the "crazy patch"). Every way of drawing the line failed; removing it was never tried.
- *Crossings allowed, over-shape forbidden.* Your ask, as the plan doc quotes it: "we end up having arrows over other shapes". The crossing bar was the plan's extension. Judges' cut picture: 52 crossings, and you liked it. The engine's excuse breakdown (51% over a placed child, 35% a neighbour's pills, 11% across an arrow).
- *Cut by meaning, word overlap first.* Spike rankings table: branch's drawing 0.55, popularity 0.59, word overlap 0.84, OpenAI 0.85, Jev with words 0.95; the branch "keeps the heavier link first, then the one at the busier end", the opposite of the judges, who chip registration lists, style files and shared state. Drawn: branch 30 keep links of 76 with 43% chip arrows; word overlap 35 with 20%; Jev with words 42 with 12%.
- *The simulation as the count.* Spike, "It decides how many break, and where"; "the simulation sets the count, and the ranking sets the order".
- *Keep the engine.* It is the only placer that draws every board with no line over a shape; main has 6 clean boards of 72. Given the judges' own cut it drew 56 of 76 keep links.
- *Drop slice 6.* Transcript, 2026-11-09 slice 6 study.

### Reversals, marked

- "Straight lines, wide fans (the owner, 2026-11-08)": you chose fans over bent lines when offered those two. Docked chips are neither. Decision 1.
- "The rule replaces the mess dial (the owner, 2026-11-07). The fewest links that make a board planar become pills ... no knob left to trade crossings for pills": planarity goes; no knob comes back either, the count is the simulation's and the order is meaning's. Decision 2.
- "Hubs give up their weakest users first, so they stay shapes with their users around them" (the plan, not a dated decision): meaning-ranked cuts chip a hub's registration spokes, as the judges do. Stars (your pick, 2026-11-07) remain the placement wherever links still form a cycle.
- Not reversed: one pill per file; no grouping by board; spines on the overview; the pins (`direct`, `layout.public: false`); "it depends on context" for redraws.

### What I'd test first, being least sure

1. That docked chips read better in the app, not only in a schematic. A chip wall under a 60-reference note might read as noise. Step 1 exists for this.
2. That the judges' taste is yours. They are two Claude models; you liked one of their pictures once. Step 2's ruler uses them, but your eye on the board is the gate.
3. That word overlap holds up on boards that aren't code (prose notes, an org). Untested; step 3's Jev is the hedge, and an embedding is the hedge after that.
4. That the app change for a lineless reference is small. I read no app code; References draws an arrow into a pill today and `canvas apply` refuses a pill standing for an edge's start, which may need the same small change.

### What I couldn't verify

- Your own words for the 2026-11-07 decisions; only the plan doc's and commit 47b59a74's record of them.
- Any of the spike's numbers (not rerun), Jev's price, that issue 26's body matches the README, that slice 5's uncommitted diff passes its tests.
- The app's code paths named above.

# Laying out boards: planar stars

A plan for canvas-digest's board layout, from the owner's ask of 2026-11-06 and 2026-11-07. The spike that led to it is in [`spike/`](spike): prototypes, the test data (this repo's 71 module boards), the last review, and how to run them ([`spike/README.md`](spike/README.md)). Slices 1 to 4 are built (below).

## The ask

- "I don't think it looks very good as things get more complicated. Also, we end up having arrows over other shapes … a more traditional layout algorithm, or maybe different algorithms in different contexts, would do so much better."
- "For every board, every time a layout is run, we need to be measuring it … a human eye can tell the difference between a good automatic layout and a bad automatic layout. And if it's bad, we take the most popular member and we use references."
- "With enough time I could make a much better diagram with these tools by hand." Ingest stays automatic: "the idea that we would turn it into making tools by hand is like 'why don't we throw away ingest'".
- Picked stars: "Stars but make sure other parts of stars are also good". On a note's block of pills: "get rid of this crazy patch of lines".
- "Condensing this into something actionable, simple, and well-considered for a wide range of use cases."

## The plan

**The bar.** A board reads like one drawn by hand: no arrow crosses another, none runs over a shape, nothing sits on anything, and linked things sit close.

**The finding.** A board can be drawn with no crossing exactly when its links form a *planar* graph. 47 of this repo's 71 module boards already do. Turning the fewest links into reference pills makes the rest planar, and the prototypes drew all 71 clean.

**One pipeline, every board** (frames inside out: a frame's inside first, then the frame as one shape):

1. **Cut.** Until the board's links are planar, the lowest-ranked link becomes a reference pill. Hubs give up their weakest users first, so they stay shapes with their users around them. A link marked `direct` is never cut.
2. **Place.** In **rows** when the document orders the board (`layout.rank`) or its links have no cycle. Otherwise as **stars**: each hub among its users, the most-linked nearest, arrows short. `layout.placement` overrides. A link that still can't be drawn clean is cut too, until the board is clean.
3. **Pills.** Short strips (at most 8) on the side the note's arrows leave least, lines straight or barely bent. A file many notes on the board use gets one pill, shared among them.
4. **Frames.** A frame's inside is a star when one member is used by most of the others, else rows. The frame is placed beside what it links to, and in rank order when frames have ranks (milestones). A link into a member enters through its frame's edge.
5. **Check.** Every run checks every board: no crossing, nothing over or on a shape. Nothing is refused; a board that fails is cut further. Each board's status goes in the report. This is the health measure the owner asked for, on every board every run.

**Redraws stay put.** Only boards whose notes or links changed are redone. On those, notes and cuts that stay keep their place, and new notes go to the nearest free spot by their links. Nothing a person moved is moved. A board is laid out afresh only when the kept layout fails the check.

**Dense boards split.** If the cut would turn more than a third of a board's links into pills, or a frame holds more than about 80 notes, the board splits into frames by the document's next grouping (a codebase's folders, say). This replaces today's crowded-board rule. With nothing to split by, the board is drawn and reported dense.

## Decided

- The approach is planarity; the placement is stars, and rows when the board is ordered. The owner picked stars on 2026-11-07.
- No block of pills whose lines run over its own pills.
- **One pill per file** (the owner, 2026-11-07). A note's references are never grouped by board, even on the busiest notes. TypesPlugin.swift keeps its 62 pills, so the strips have to carry them. Offered and declined: one query pill per board ("Canvas · 12"), which would have taken this repo from 2,421 pills to 941.
- **The rule replaces the mess dial** (the owner, 2026-11-07). The fewest links that make a board planar become pills; the dial's search and its tuning retire, with no knob left to trade crossings for pills. The pins stay: `layout.pill: false` and `direct: true`.
- The overview board keeps its ranks and spines, and draw's `share:` stays as it is.
- **Straight lines, wide fans** (the owner, 2026-11-08). A note with many pills fans them out on straight lines, over its other pills nowhere, rather than the app learning to bend a pill's line. Seen on the real boards, slice 3 reads better than slice 2 (the owner, 2026-11-09).

## Open

- **When a link becomes a pill.** The owner, seeing slice 2's boards on 2026-11-07: "i think the threshold is off (no matter how we measure it)". Of slice 2's 7,128 pills on the module boards, 5,784 stand for files on other boards and 1,344 are links on the board cut by the rule (377 to make the links planar, 967 more where a drawing still crossed or ran over a shape). To be taken up again after slice 3.
  - Taken up after slice 3: of slice 3's 1,576 pills for links on a board, 380 make the links planar, 713 are links the stars placement could not draw clean and 483 were cut for a conflict; almost none is cut to break a tie (1,124 of the 1,196 cut after placement were the only link in some conflict that could be cut), but the cut decides before the notes are placed, and 200 of those links draw clean when put back alone into the finished board. So the cut now ends by putting links back as arrows wherever the finished drawing has room for their line (`restore.mjs`): 827 arrows to 967, every board clean, the same area, about a tenth more time. Still to try: arrows bowed round a shape (18 more, an app change). Tried and not kept: the stars placement excusing fewer arrows. An arrow it excuses would run over another placed child (51%), a neighbour's pills (35%) or across an arrow (11%), and the note's other arrangements clear it 5 times in 887; laying a fresh drawing down again further apart until none is excused won 9 arrows, within the corpus's noise (one changed excuse moves it by about 15), and every variant that won 30 or more grew the area to 969M or more. And a planar cut that swaps one kept link for two cut ones finds swaps only by giving up a more wanted link, against the order decided for the cut, and won 4 arrows, within the layout's noise.

## Build, in order

Each slice is judged on the real boards before the next. The 71 module boards in `spike/` are the test corpus.

| # | Slice | From the spike |
|---|---|---|
| 1 | The check and its report. It works on today's engine too, so it measures every later slice. **Built**: `health.mjs`, below. | `proto/planar/verify.mjs`, `overlaps.mjs`, `kit.mjs` (`evaluate`) |
| 2 | Cut, then place: rows or stars, then cut until clean. This retires the mess dial's search. **Built**: `cut.mjs`, `planarity.mjs`, `stars.mjs`, below; the dial, its search and their modules are gone. | `proto/planar/planar.mjs`, `proto/stars/module.mjs`, `proto/rows/module.mjs` |
| 3 | Pill strips and shared pills, one pill per file. **Built**: `strips.mjs`, `share.mjs`, and a stars placement from a planar embedding (`stars.mjs`), below. | `proto/stars/kit.mjs` (strips), `proto/planar/share.mjs` |
| 4 | Frames: their insides and their place. **Built**: a frame a shape beside it links to is laid out with its container (`layout.mjs`'s `findFlat`, `separateFlat`; `stars.mjs`'s clusters), below. | `proto/stars/kit.mjs` (`frameFootprint`) |
| 5 | Redraws that stay put. **Built**: the file's shapes, arrows and pills stay as they are, and a redraw moves a shape only for a reason ([digest](../../../.claude/rules/digest.md), Drawing again in place). | the warm start (`keepCurrent`) |
| 6 | Dense boards split | not prototyped |

Every slice is deterministic. A changed board of 300 notes should redraw in about 10 seconds; today's stars prototype takes 12 minutes for all 71 boards, because it lays each board out eight ways.

## For whoever builds it

- **Ranking a link for the cut:** its `layout.weight` (default 1, a typed link 3), then the end with more links first, then key order. The pill goes beside the end with fewer links and stands for the other. The planarity test should be linear-time for big boards; the spike's (Demoucron–Malgrange–Pertuiset) is quadratic. In rows, links between adjacent ranks are cut last, the longest spans first.
- **What counts as a crossing:** two drawn paths that share no end and cross. A path runs over a shape when it enters a box other than its two ends, with an 8-unit margin. Arcs are sampled. A note's lines into its own pill strip are counted apart and aren't failures.
- **Which side a strip goes on:** count the note's arrows leaving each of its four sides, and use the side with fewest, then the next.
- **The report, per board:** status (clean, cut further, kept, dense), links, links cut, pills, size against the window, seconds.
- **Constants in one place:** strip 8, dense above a third cut or 80 notes, margin 8.

## Tried and dropped

- Every undrawable link as a pill (the flow spike). "You lose all hierarchy because everything is a pill."
- Routed arrows on rails, and quiet gray arrows. Both need app changes; neither was pursued.
- A separate health score with its own reference loop. It rebuilt the mess dial's tuned search.
- Shared pills inside the layout: as satellites the held notes were placed against in a second pass (58 s, 46M of area and 104 lines over a note's own pills more, no arrow kept), or as children the planar placement puts down in the first pass (50 of 72 boards clean at best). Sharing on the finished drawing costs neither.
- Bending a pill's line round the note's other pills: an app change, and the try still left 1,300 to 1,900 lines over a note's own pills.
- Choosing per board how much an arrangement's free room weighs against its area: 0.6% of area, for twice the time.
- A frame's inside laid out on its own, then turned to face its outside links: a star round the member most others use, else rows, with the members linked outside in a front row toward them (6 arrows more), or laid out again after placement with each member facing its links and the frame's lines drawn to its members (59 more, for 1.4 times the plan time). What blocks those links is mostly outside the frame, the pills round the shapes beside it, which a frame laid out on its own can't see.
- Pill blocks in columns, whose lines cross their own pills (the "crazy patch").
- A ring of pills with straight lines: about four times the area.
- One tall column with arcing lines: giant loops on 26 boards.
- Grid (62 of 71 boards clean) and map (48 of 71) placements: fewer clean boards than rows, stars or islands.

## Where it stands

On this repo's 71 module boards:

| | Clean boards | Crossings | Pills | Area vs today | Reviewers: good / ok / bad |
|---|---|---|---|---|---|
| Today's engine | 6 | 10,364 | 4,015 | ×1.00 | not reviewed |
| Stars, first full build | 71 | 0 | 6,335 | ×1.09 | 15 / 36 / 20 |
| Stars, reviewed (the spike's best) | 71 | 0 | 6,460 | ×1.06 | 12 / 39 / 20 |

**The check (slice 1).** Every plan now measures every board on its drawing (canvas-digest's `health.mjs`; [digest](../../../.claude/rules/digest.md)). It counts what the bar forbids as the app draws it: the second arrow between two shapes bowed 34 units apart from the first, a line within 8 units of a shape or the title above it as over it, an arrow through a frame that holds neither end as over a shape, a note's lines over pills it uses counted apart. With the spike's own rules it agrees with the spike board by board. What it says:

| | Clean boards | Crossings | Lines over shapes | Shapes on top |
|---|---|---|---|---|
| Today's engine, planned afresh (all 72 boards, in 21 s) | 8 of 72 | 11,211 | 5,960 | 0 |
| Stars, the spike's drawing (71 module boards) | 30 of 71 | 0 | 99 | 0 |

Stars by the spike's rules is 65 of 71 (6 boards have an arrow through a frame that holds neither end); the app's bowed second arrows take it to 60, the 8-unit margin to 36, and other shapes' titles to 30. Slice 2 is held to this check.

A relationship type with one end on each side is drawn by the app as one arc through it (Arrows' `ArrowThrough`). `canvas measure` now names those pairs (`lines`), and the check draws them as that arc. Today's engine puts such a type beside its two types instead of between them, so on the overview the arcs loop round the whole board: the check measures the overview at 17,095 × 20,145, a window showing it whole at 5%, where it was 6,886 × 4,187 at 21% counted straight. Slice 2 places a relationship type by its links as it places any node, which put `holds` between its two types on the overview (below); placing one there on purpose (the app's Straighten puts it on the middle of the line) is not built.

**The cut (slice 2).** Every board's links are made planar (the left-right test, linear; the greedy cut, the most wanted kept first), each container placed as stars where its links have a cycle and in rows where they have none, and the drawing measured as the app draws it and cut further until clean. The dial is gone, with its flags (`--mess`, `--promote`, `--prefer`, `--cap`, `--margin`, `--popular`), the document's `layout.mess` and `layout.promote`, and ingest's `mess`; `layout.placement` (the document's, or a frame's or a subboard's) says stars or rows outright. Planned afresh, on all 72 boards:

| | Clean boards | Crossings | Lines over shapes | Arrows kept | Pills | Area | Mean arrow |
|---|---|---|---|---|---|---|---|
| Today's engine | 8 of 72 | 11,211 | 5,960 | 615 | 3,950 | 400M | 2.34 note widths |
| Slice 2 | 71 of 72 | 39 | 1 | 790 | 7,123 | 862M (×2.2) | 2.33 note widths |

Arrows, pills, area and the mean arrow are the 71 module boards'; today's row is slice 1's measure of today's engine's plan of the same document, and the mean arrow is the median board's mean centre-to-centre length of a plain arrow, in note widths of 300, as the spike measured it. Of 2,403 links on the boards, 1,603 are pills: 380 to make each board's links planar and 1,223 more where a drawing still crossed or ran over a shape. The plan takes about 3.5 s under node or jsc on this machine, and the two draw the corpus byte for byte alike (the layout measures and turns with square roots and the four operations, which every engine rounds alike).

- **The overview** is the one board not clean: its 39 crossings and its line over a shape are lines into its spines' shared pills, which the cut can't take (the overview keeps its spines, by decision); slice 3's shared pills are where they go. Of its two relationship types drawn as one line, `holds` sits between its two types, a gentle arc (its middle 108 units off a chord of 637), and `fills` had one of its two ends cut into a pill, so it draws no arc (the cut doesn't keep a line's two halves together). It measures 8,279 × 5,356 with its arcs, a window showing it at 17% (17,095 × 20,145 at 5% before).
- **Area ×2.2.** Every pill is its own link's until slice 3 shares them and stacks them in strips, so a busy note has a tall column, and its neighbours are as far off as the column is tall (Colors' ColorBook.swift has 14 pills and arrows up to 4,500 units long).
- **A note with no link** goes on a shelf hung from the shape that reaches furthest on the short side, once the polish has placed the rest, every round. The first build shelved it before the polish and kept it there through the cut's rounds while the rest drew together: Selection's Accessibility.swift ended 7,000 units from everything (the owner saw it); shelved beside the bounding box, it was still 2,300 from the nearest shape.
- **Not built:** a relationship type placed between its two types on purpose, and kept whole (the cut may take one half of its line). A cut link's pill beside the end with fewer links, standing for the busier, as the plan says: `canvas apply` refuses a pill that stands for an edge's start when both ends are on one board, so that is an app change, and until then a shape that points at many has its pills beside it. A board whose only conflicts are links the cut may not take (`direct`, between frames, or into a `layout.pill: false` node) has a container in rows placed as stars instead (the frames fixture's board needed it); one still not clean is reported so. A redraw decides the cut afresh, so a frame whose pills change is laid out afresh (slice 5); a redraw is mended as a fresh layout is, and a board where no cut mends what a person did is laid out afresh.

**Pills and sharing (slice 3).** Each stars container is now placed from the planar embedding of its links: the Tutte drawing of the triangulated embedding gives each child a direction, and the children are put down one at a time, the most linked first, each at the clean spot nearest its neighbours in that direction (no box on a box, no arrow over a box, a pill or a title's room, no crossing), with the arrangement of pills its arrows need. An arrow no spot lets out is excused, and the cut takes excused links first. One gather at the end draws each child toward the middle where the container stays clean. A container laid out again from where its notes were, the cut having grown them, is laid out afresh where a note lands far from its links, and the fresh one taken when it excuses no more arrows and is under 0.8 of the area. A note's pills stand in strips, at most 8 a row or column, on the side its arrows leave least: rows, columns, corners, U shapes or all four sides, with a straight line from the note to each pill that runs over none of the note's other pills; a column is used only where no strips fit. At the end of the cut, on a board that is clean, the notes of a container that use one file share one pill wherever each of them reaches it by a clear straight line (crossing no line, over no shape or pill, at most 1,200 long); the sharing notes' other pills are packed again in smaller strips, a note whose line makes the board unclean has its own pill back, and the result is kept only where the board ends clean. Sharing moves no note and cuts no link. The 71 module boards, planned afresh for a view of 1322 x 893, slice 2 counted again from its report the same way (the table above counts it at 790 arrows, 7,123 pills and 862M):

| | Clean boards | Crossings | Lines over shapes | Arrows kept | Pills (shared) | Area | Mean arrow | Lines over a note's own pills |
|---|---|---|---|---|---|---|---|---|
| Slice 2 | 71 of 72 | 39 | 1 | 785 | 7,128 | 845M (×2.1) | 2.33 note widths | 11,090 |
| Slice 3 | 72 of 72 | 0 | 0 | 811 | 5,924 (1,024) | 946M (×2.4) | 2.86 note widths | 13 |

Clean boards, crossings, lines over shapes and the last column are over all 72 boards; arrows, pills and area are the 71 module boards'. The mean arrow is the median board's mean centre-to-centre length of a plain arrow, in note widths of 300. Of 2,403 links on the boards, 1,576 are pills: 380 to make each board's links planar and 1,196 more where a drawing still crossed or ran over a shape. Shared pills are 1,093 of the 6,183 pills on all 72 boards, and 2,355 lines run into them. The 13 lines over a note's own pills are the overview's 10 lines into its spines' shared pills (decided) and one each on Draw, Queries and Validation. Every board is clean, the overview too. The plan takes 45 to 65 s for all 72 boards on this machine, under node or jsc, which draw it byte for byte alike (slice 2: 3.5 s); the slowest board, Types/Form, 4 to 10 s. Most of it is packing the busiest notes' strips.

What still keeps boards from reading well:

- **The busiest notes' fans of pills.** Pills stay one per file and their lines straight (the app can't take a bend for a pill's line from a document), so a note with 40 pills has a wide fan, and its neighbours sit as far off as the fan is wide. Up close, a fan's lines read as arrows, and a pill can sit 1,000 units from its note.
- **Time.** A plan of this repo takes over ten times as long as slice 2's.
- **Area.** The boards are 12% over slice 2's by this count (×2.4 of today's engine's), the price of strips with room for arrows to leave by; the mean arrow is longer than slice 2's.

**Frames (slice 4).** In slice 3, 209 of the 226 links from a shape beside a frame to one of its members were pills: the frame's inside was laid out before the frame was placed, so it couldn't know where its links came from, and the placement around it saw the frame as one box and drew its lines to the box's middle, while the check measured the line to the member, through the frame's other members and their pills. Now a frame that a shape beside it links to is laid out with its container: its members are children of the container's stars placement, held together and put down first, each where it blocks least the others' ways out, and the frame is the box round them, kept clear of every other shape and arrow. The member most others use ends in the middle and the members linked outside on the edge toward what they link to, as the plan's rule has it, without a rule of its own. With the links put back (above, Open), on the 71 module boards:

| | Clean boards | Arrows | Pills (shared) | Area | Member to beside | In one frame | Frame to what it links to |
|---|---|---|---|---|---|---|---|
| Slice 3 | 72 of 72 | 811 | 5,924 (1,024) | 946M | 17 of 226 | 50 of 156 | 2.43 note widths |
| Links put back | 72 of 72 | 935 | 5,817 (1,013) | 946M | 38 | 63 | 2.43 |
| Slice 4 | 72 of 72 | 1,025 | 5,731 (1,016) | 934M | 114 | 116 | 0.81 |

Arrows are the 71 module boards'; the last three columns are over all 72 (arrows of links between a frame member and a shape beside its frame, arrows of links inside one frame, and the median gap from a frame to the shapes beside it that its members link to). Lines over a note's own pills: 10. Ten boards draw one to four arrows fewer than with the links put back alone, and links with neither end in a frame lose 35 arrows to the frames' 129. A frame of this kind is laid out in rows containers as before (laid out with its container there too, it won 18 arrows more for 19M of area), and the overview's ranked bands are as they were. A redraw keeps such a frame whole when its members are unchanged, but its cut is decided with its container's, so it is laid out afresh more often than before (slice 5).

The last review ([`spike/review.json`](spike/review.json)), before slice 3, said what kept boards from reading well:

- **Linked notes placed far apart** (52 boards): placement doesn't measure arrow length. That's slice 2's job: stars places by every link, a pill's too, and its local search keeps arrows short.
- **Heavy notes' pill walls** (58 boards). Pills stay one per file, by decision, so slice 3's strips must make 30 to 60 pills read well.
- **Frames far from what they link to** (45 boards): slice 4.
- **Loose notes, and boards too big or the wrong shape** (about 33 boards each).

**Groups (the strategy of [issue 26](https://github.com/zekenie/canvas/issues/26), as built).** Topology first, then meaning, and the groups only weigh and cut links: nothing moves a shape out of the board and frame the lens put it in, and no frame or container is added. On each board a frame of the document is one item in what holds it, and each container's items, a frame's own notes inside it, are grouped by how tightly their links hold them (a link is as tight as its two notes are alike: the app's `canvas measure --tightness`, OpenAI's text-embedding-3-large of each note's title and text, centred on the board's mean, ranked within the board; the groups are Louvain's at resolution 1.5 over those ranks). The links between two groups are cut, pills before anything is placed, and each that has a clear line once everything is placed comes back as an arrow. Built in two halves; this is the tool's half (canvas-digest: `cluster.mjs`, `cut.mjs`, `restore.mjs`, [digest](../../../.claude/rules/digest.md)), the app's being `canvas measure --tightness` and the EmbeddingModels module. A build that put each group in a new untitled frame was taken out: the owner wrote of boards with no topology that the decomposition is great, but "making net new frames is not."

- **What the owner decided** (the issue has the owner's words): topology first, meaning only through links and against the board, OpenAI's embedding through the app, easy to swap; the looser links cut so a board comes apart into groups, inside the lens's frames too, in smaller groups than the method's usual; a cut link may come back as an arrow; and no net new frames.
- **What Claude decided.** Claude put the first three of its calls in the issue to the owner, a line each (a link's rank and the redraw's line, that everything drawn stays and a new note goes beside the notes it is most tightly linked to, among them), and the owner replied "Ok continue"; the rest came with the respike the owner judged, and the redraw's rule for a new link is Claude's alone. The owner has not seen a redraw in pictures. The calls: a link counts by its rank when the groups are found, not by how alike its notes are (counted by how alike, 803 links are arrows instead of 774, and 28 of the 68 boards with links group a few files differently); resolution 1.5, the middle of the three sizes shown (1, 1.5 and 2); the engine's weights, 1..49 for a cut link and 50..100 for the rest, by rank, the loosest lightest, so the engine cuts the loosest first and every link pulls the notes it joins together by its weight; text-embedding-3-large; a link marked `layout.direct`, a link at a frame and a link into a shape no pill stands for are never cut; and what a redraw does with groups (below), the rule for a new link included.
- **What was built.** `digest`'s tool has a `cluster` command, a pure transform of the graph document before the plan: `layout.cut` on the links between groups, `layout.weight` on every link, `layout.clustered` at the top. It adds no node. The cut takes a precut link out before anything else (`planarLinks`), the put-back (`restoreByDrawing`) treats it as any other link and counts it apart (`restoredCut`), and, in a document clustered by tightness, the mend cuts the least wanted link first (`conflictCuts`). The driver measures once, since the groups add no shape. With no key, an older app or a timeout the driver says why and the groups are by the links alone, each link weighing the same, which the summary says too.
- **The corpus check** (`mise run test:digest-corpus`, `tool/test/corpus.sh`): the spike's own data grouped and planned by the tool, with no app and no key. The groups are the spike's byte for byte (`spike/strategy.tar.gz`'s `groups.json`, the spike's `groups-decided.json`: resolution 1.5), and the counts the spike's, under node and under jsc: 774 of 2,202 links inside boards drawn as arrows (slice 4's engine: 912), 72 of 72 boards clean; 1,226 links between groups, cut before anything was placed, 147 of them back as arrows; 976 links inside groups, 349 of them cut by the engine to draw clean; and on the six boards the owner judged (Selection, Mentions, Draw, References, Canvas/Model, Types/Form) 172 of 557 arrows (slice 4's engine: 168), 360 of the links between groups and 29 of them back, 197 inside groups and 54 of them cut. The check is made with the spike's vectors (half floats), not a live model's.
- **A redraw keeps what is drawn (slice 5).** `cluster` takes the same `--current` and `--changed` as `plan`, and the driver gives it them, but only so that a shape a person carried into another container is grouped where it now is (`clustered.json` keeps the document's own containers; `cluster` writes `carried.json` for the driver to measure, and the plan carries the shapes itself). The groups are found again over the document as it is, with today's tightness, only to weigh the links; every shape, arrow and pill the file has stays as it is, and a new note goes beside the notes it is most tightly linked to (each placed neighbour pulls by its link's own weight, drawn or a pill, against the note's own links; two notes an arrow joins keep a gap of 40 between their boxes even at the least gap). A new link is an arrow where its line is clear, else a share of a pill the file has, else a pill of its own; a note a person put on another goes to the room the person's note left, at the least gap of 8 before a frame grows ([digest](../../../.claude/rules/digest.md), Drawing again in place). To group a drawn board again from the tightness it is drawn into a new file, since a drawing is found by name in the file as a whole.
- **Not what the spike did.** The spike's mend change (`engine.patch`: the least wanted link first, the one in most conflicts on a tie) is on only where the document says it was clustered by tightness (`layout.clustered.by`), not for every document: with no weights the lens's own say little, a lens's weights have never gone before the conflicts, and the change moves the fixtures' drawings (acme 34 pills against 31) and the redraw tests that start from them. A redraw's mend is as slice 5 has it.
- **Open.** A trailing file extension is stripped from a note's title in the text it is embedded by (the app's half); with a key saved in Settings the app sends every note's title and text to OpenAI to measure tightness, and the vectors it keeps by text make a second measure free; the boards are to be drawn in the app from the spike's saved data, and this repository through the app once the owner's key is saved, for the owner to judge.

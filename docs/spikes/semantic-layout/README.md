# Spike: let meaning decide which links are arrows

**Verdict.** It has legs once a model ranks the links. Jev, the app's yes-or-no model, was asked the judges' question about every link inside a board, with the whole board in view. Its answers, mixed with similarity, choose which links become references. The background simulation says how many on each board, and the layout branch's engine draws the rest. That draws 46 of the 76 links the judges would keep side by side, where similarity draws 34 and the branch 30. Of its arrows on the judged boards, 13% are links the judges would make chips, against 24% for similarity and 43% for the branch. Every board is clean.

- **A model ranks links far better than similarity.** Asked with its board in view, Jev ranks a link the judges keep above one they chip 93% of the time. Similarity does so 80% of the time, and one judge ranks the other's picks 99%. All 2,202 links inside a board took 70 requests and 0.58 million input tokens, a few seconds in all.
- **What it reads matters more than how it's asked.** A link asked alone scores 86%. The lens's roles, a second question and another wording land between 91% and 93%.
- **It can't tell "one idea" from "related".** Where the cut is as tight as the judges' own, keeping one link in six, it draws 32 keep links where their cut draws 56. Similarity catches some of what it misses, which is why the two are mixed.
- **The count still comes from the background simulation.** Jev's own no is precise but timid: the engine cuts the rest by itself, and chips come back. The simulation's own order is still worse than the ranking at its counts, even with Jev as its springs' strength.
- **The earlier rounds stand.** The background simulation picks what similarity picks. The rule as stated keeps a graph, but the wrong one: half its arrows on the judged boards are chips, and only 16 of the 72 boards come out clean.

This is a spike: evidence and a pre-plan, no feature work. It is meant to replace both of today's strategies: main's (popular shapes become pills) and the layout branch's (`claude/canvas-layout-strategy-f81c7d`, slices 1 to 4, not landed: the fewest cuts that draw every board clean). Its earliest rounds tested a rule of mine instead of the owner's. They are kept at the end for what they measured.

## How it was measured

- **Corpus.** This repository drawn by canvas-ingest. It has 72 boards, 891 notes, 56 frames and 71 module cards. Of its 8,282 links, 2,498 are inside a board and 5,784 go between boards.
- **Vectors.** Each note's text is its title plus the doc comment and declarations the lens gives it, with code names split into words.
  - The text is embedded on this Mac with Apple's NaturalLanguage, in two ways: the sentence embedding, and the contextual embedding with its token vectors averaged. Both are 512 numbers, and both are centred on the corpus mean.
  - TF-IDF word overlap is computed alongside.
  - All 1,018 texts, with both models, took 20 s.
- **Blind judges.** Two independent Claude Sonnet agents labelled every one of the 459 links on five dense boards: Selection, Mentions, Draw, Canvas/Model and References.
  - The labels are 0 (incidental: a chip is better), 1 (either) and 2 (one idea: keep them side by side).
  - The judges saw only the notes' text, never a score.
  - They gave the same label 81% of the time (Cohen's kappa 0.68).
  - "Keep" means a mean label of at least 1.5 (76 links). "Chip" means both said 0 (210 links).
  - Both judges picked their 1s and 2s and left the rest at 0, so the labels are coarse.
  - The judges stand in for a person reading the board. Their picks are the target, not something any strategy computes.
- **One ruler.** Every strategy writes canvas-digest's drawing format, and every drawing is scored by the layout branch's own health check (crossings, lines over shapes, shapes on top). So main, the branch and the spike are measured alike.
- **Chips and keeps.** A chip arrow is an arrow on a link both judges would make a chip; a keep arrow, one on a link they'd keep side by side. "Keep links drawn" counts the 76 keep links drawn as arrows.

## A model ranks the links

Asked whether the ranking may ask a model about each link, the owner said yes: the calls are cheap, and they want real data. So every link inside a board was asked, 2,202 of them, not only the 459 the judges labelled.

- **The model.** Jev (`jev-1.14.0`), TypeSafe's yes-or-no model and the one the app's decision models ask. It answers each question with a probability of yes. `jev.mjs` asks it.
- **The question** is the judges' instructions cut to one question for each link. The judges' account of arrows and chips comes first, then:

  > The link: Groups.swift uses Parts.swift. Do these two notes form one idea, so this link should be an arrow that keeps them side by side?

  Yes means "One idea: draw the arrow", and no means "Incidental: use a chip".
- **What it reads.** Four ways, decided before any answer came back, and all reported:
  1. a link alone: the board's name, the two notes' titles and text (the 400 characters the judges read), and which uses which;
  2. a link with roles: also each note's type from the lens (file, plugin, extension point...) and the link's relationship, where the lens gives one;
  3. the board: every note and link on it as the judges read them, with one question for each link;
  4. the board with roles.

  After the first results, one more was decided before its answers came back: the judges' three labels as two questions, "more than incidental?" and "one idea, more than related?".
- **Cost.** Asked by board, the corpus took 70 requests and 0.58 million input tokens. A request holds at most 150 questions, so the root's 359 links went in three. The median request took 0.14 s. A link at a time took 2,202 requests and 1.4 million tokens, 30 s with eight at once. Answers are kept by a hash of the request, so a board asked again unchanged asks nothing.

### How it ranks

How often a link of one class outranks one of another (AUC), on the 459 judged links:

| ranking | keep over chip | Selection | Mentions | Draw | Canvas/Model | References | keep over split | split over chip |
|---|---|---|---|---|---|---|---|---|
| similarity | 0.80 | 0.91 | 0.86 | 0.50 | 0.79 | 0.72 | 0.73 | 0.61 |
| Jev, a link alone | 0.86 | 0.88 | 0.90 | 0.85 | 0.92 | 0.75 | 0.66 | 0.76 |
| Jev, a link with roles | 0.86 | 0.87 | 0.88 | 0.80 | 0.92 | 0.77 | 0.65 | 0.76 |
| Jev, the board | 0.93 | 0.96 | 0.96 | 0.84 | 0.99 | 0.86 | 0.74 | 0.81 |
| Jev, the board with roles | 0.93 | 0.96 | 0.95 | 0.80 | 0.99 | 0.86 | 0.75 | 0.82 |
| Jev, two questions | 0.93 | 0.96 | 0.94 | 0.85 | 1.00 | 0.88 | 0.74 | 0.80 |
| **Jev and similarity** | **0.93** | 0.96 | 0.96 | 0.75 | 0.99 | 0.89 | **0.81** | 0.78 |

One judge ranks the other's 2s over their 0s at 0.99. "Jev and similarity" adds Jev's answer with the board in view, as a logit, to similarity, each a z-score over the links inside boards. The drawings below use it.

- **The board in view is what counts.** It lifts Jev from 0.86 to 0.93. The lens's roles, a second question, and each of the two questions alone land between 0.91 and 0.93.
- **Draw is where similarity fails and Jev doesn't.** Draw's files share words across the module, and similarity ranks its links at chance (0.50). Jev scores 0.84 there.
- **Jev is rarely sure.** It answers in hundredths, 68 distinct values over the judged links. At the app's cutoffs (yes at 0.7 and above, no at 0.3 and below), it says yes to 58 of the 76 keep links and no to none of them. It says no to 40 of the 210 chips. Most links get an unsure answer.
- **It can't tell "one idea" from "related"** (keep over split: 0.74). Its worst misses:
  - links to a module's central file, which the judges call plumbing: SelectTool.swift to Selection.swift (0.82), and Groups.swift to Selection.swift (0.81);
  - a plugin and the file it registers, which the judges keep: MentionTextsPlugin to MentionTexts.swift (0.56). Similarity ranks these among its top 30 of the 2,202 links, since the names match.

  Mixed, each covers some of the other's misses, and keep over split rises to 0.81. Breaking Jev's ties by similarity, without the mix, barely changes it.

### Drawn by the layout branch's engine

Each ranking's cut at four counts, drawn as in the background simulation's round. The cut is given before layout and kept (`simcut.patch`), and each link's place in the ranking is its weight for the engine's further cuts.

![Selection and Mentions drawn by the layout branch's engine three ways: similarity cutting at the background simulation's counts, Jev and similarity cutting at the same counts, and the judges' cut. Arrows are coloured by the judges: green keep, red chip, amber between](pictures/model.jpg)

| count on each board | ranking | arrows (72 boards) | arrows on judged links | of them keep / chip | keep links drawn (of 76) |
|---|---|---|---|---|---|
| | the layout branch | 1,067 | 147 | 20% / 43% | 30 |
| the background simulation's (0.5) | similarity | 732 | 91 | 37% / 24% | 34 |
| | Jev | 713 | 92 | 43% / 12% | 40 |
| | **Jev and similarity** | **718** | **92** | **50% / 13%** | **46** |
| a flat two-thirds | similarity | 609 | 96 | 34% / 23% | 33 |
| | Jev | 617 | 92 | 45% / 12% | 41 |
| | Jev and similarity | 622 | 87 | 46% / 13% | 40 |
| the judges' (one link in six kept) | similarity | 968 | 58 | 52% / 14% | 30 |
| | Jev | 964 | 57 | 47% / 9% | 27 |
| | Jev and similarity | 942 | 54 | 59% / 4% | 32 |
| | the judges' own cut | 964 | 56 | 100% / 0% | 56 |
| only the links both judges chip | similarity | 1,038 | 109 | 29% / 30% | 32 |
| | Jev and similarity | 1,005 | 105 | 35% / 18% | 37 |
| | the judges' own chips | 1,033 | 115 | 32% / 0% | 37 |
| Jev's own no (under 0.5) | Jev and similarity | 909 | 114 | 24% / 30% | 27 |
| the simulation's own, Jev and similarity its strength (0.5) | the simulation's order | 788 | 119 | 34% / 21% | 40 |

Every row draws all 72 boards clean but two, noted below.

- **At the simulation's counts, the mix draws 12 more keep links than similarity and half the chip arrows,** with about as many arrows. On each judged board it draws at least as many keep links and no more chip arrows (keep links, then chip arrows):

  | | Selection | Mentions | Draw | Canvas/Model | References |
  |---|---|---|---|---|---|
  | similarity | 7, 5 | 12, 3 | 2, 6 | 8, 4 | 5, 4 |
  | Jev and similarity | 8, 2 | 16, 3 | 4, 6 | 12, 0 | 6, 1 |
- **At the judges' tight counts it gains least.** It draws 32 keep links against similarity's 30, though with 2 chip arrows against 8. A cut that keeps one link in six needs keep told from "either", which is Jev's weakness. Given the judges' own cut, the engine draws 56.
- **Jev's own no can't set the count.** Under 0.5 it cuts 137 of the judged links, 115 of them chips, so it is precise but timid. The engine then cuts 208 more by weight to draw clean, and chips come back: 30% of the arrows.
- **The simulation sets the count, and the ranking sets the order.** With Jev and similarity as its springs' strength, the simulation's own order draws 40 keep links with 21% chips. The ranking at its counts draws 46 with 13%.
- **Where the engine cut alone, one board came out unclean.** At the judges' and the chips' counts, the given cut covers only the judged boards. The engine cut the other 67 by the mix's weights, and left Types/Form with 8 lines over shapes. With the simulation's counts on every board, all 72 are clean.

## A simulation in the background decides what breaks

The owner's follow-up, on the finding that in a dense area the graph decides how far an arrow stretches, not its own spring:

> I think we can do something smarter with this. Like imaging doing a force based simulation in the background just to decide what arrow to break.

This simulation is never drawn. Its only output is which links break, and the layout branch's engine draws the rest clean. Since nobody sees it, its physics can be chosen for the decision alone. `background.mjs` builds it:

- **Notes are points, links are springs.** Each note on a board pushes the others away with its size and a quarter of its pills'. Each link inside the board is a spring that wants the usual gap between its notes. A link to another board is a pill in any case.
- **Three physics**, three ways to make a link's strength count in a dense area:
  1. **Load against strength.** Every spring is as stiff as the next. So how hard a link is pulled comes from the board's crowding alone: a hub's fan of notes pushing each other out, or two clusters pushing apart. Similarity sets how much pull a link holds before it breaks: the threshold for the most alike link on the board, a quarter of it for the least alike.
  2. **Crowding only.** The same, but notes push only where they don't fit. So a link carries load only in a crowded spot, and a lone link carries none.
  3. **Meaning moves the notes.** Springs are as strong as their notes are alike, as stated. And every pair of notes on the board, linked or not, is pulled toward a distance set by how alike they are. So notes that aren't alike drift apart, and the link between them stretches until it breaks.
- **One break at a time.** The link pulled hardest past what it holds breaks first. The board settles again, with the new pill pushing beside its note, and it stops when every link holds. All 72 boards take about a second.
- **Drawn by the layout branch's engine.** The breaks become pills before layout and are never put back (`simcut.patch`, over the earlier rounds' `engine.patch`). Each link's place in the simulation's order is its weight, which the engine's own further cuts follow.
- **The control.** Each run is set against similarity alone cutting the same number of links on each board, the least alike first, and weighted by similarity.

### It picks what similarity picks

On the five judged boards (459 links), before anything is drawn:

| physics | threshold | links broken | arrows left: keep / chip | similarity, same counts: keep / chip |
|---|---|---|---|---|
| load against strength | 0.5 | 303 | 33% / 32% | 31% / 29% |
| | 1 | 201 | 24% / 39% | 23% / 37% |
| | 1.5 | 94 | 20% / 43% | 19% / 41% |
| crowding only | 0.1 to 0.5 | 268 to 290 | 23–24% / 36–37% | 27–29% / 30–33% |
| meaning moves the notes | 0.5 | 242 to 248 | 21–26% / 35–36% | 24–26% / 33–35% |
| | 1 | 84 to 108 | 17–20% / 43–44% | 19–20% / 40–43% |

The ranges cover four thresholds for crowding only, and two strengths of meaning's pull.

- **In all 11 settings, the simulation leaves more chip arrows** than similarity does at the same counts.
- **Where similarity sets the strength, the order is nearly similarity's.** Under load against strength, what breaks has a mean similarity rank of 0.19 to 0.36, where similarity's own cut of as many has 0.10 to 0.33. What the physics changes in that order, it changes for the worse.
- **Where crowding sets it, the order is the board's shape.** Under crowding only, what breaks has a mean rank of 0.40 (similarity's own cut: 0.30; chance: 0.5), and the judges agree with it less.
- **Hubs do break now.** A hub's fan of notes crowds, so its spokes take load. On Selection, at a threshold of 0.5, the registration hub (the `selection` plugin) loses 10 of its 14 links, all chips. Drawn, it keeps 4 arrows, all chips, where the branch keeps 12. But similarity, cutting as many links on that board, leaves it 1.

### It decides how many break, and where

Load against strength; 68 of the 72 boards have links inside them.

| links on the board | boards | broken, threshold 1 | threshold 0.5 |
|---|---|---|---|
| fewer than 10 | 22 | 11% | 38% |
| 10 to 19 | 18 | 16% | 45% |
| 20 to 39 | 11 | 27% | 48% |
| 40 to 79 | 11 | 36% | 60% |
| 80 or more | 6 | 52% | 70% |

### Drawn by the layout branch's engine

![Selection and Mentions drawn by the layout branch's engine four ways: as the branch cuts, as the background simulation cuts (threshold 0.5), as similarity cuts at the simulation's counts, and as the judges cut. Arrows are coloured by the judges: green keep, red chip, amber between](pictures/background.jpg)

| | arrows (72 boards) | arrows on judged links | of them keep / chip | keep links drawn (of 76) |
|---|---|---|---|---|
| main (7 boards clean) | 659 | 59 | 36% / 12% | 21 |
| layout branch | 1,067 | 147 | 20% / 43% | 30 |
| the background simulation, threshold 1 | 917 | 119 | 24% / 42% | 29 |
| the background simulation, threshold 0.5 | 778 | 102 | 33% / 29% | 34 |
| similarity, at the simulation's counts (0.5) | 732 | 91 | 37% / 24% | 34 |
| similarity, a flat two-thirds of each board | 609 | 96 | 34% / 23% | 33 |
| similarity, a flat half (the earlier rounds) | 785 | 111 | 27% / 32% | 30 |
| **the judges' cut** | 964 | 56 | **100% / 0%** | **56** |
| similarity, at the judges' counts | 968 | 58 | 52% / 14% | 30 |
| only the links both judges chip | 1,033 | 115 | 32% / 0% | 37 |
| similarity, at those counts | 1,038 | 109 | 29% / 30% | 32 |

Every row but main draws all 72 boards clean. "The judges' cut" makes a pill of every judged link they wouldn't keep. The last four rows cut only the five judged boards, and the engine draws the other 67 with similarity as the weight.

- **The count helps a little.** With similarity choosing, the simulation's counts draw 123 more arrows than a flat two-thirds, with about the same shares of keep and chip arrows.
- **The engine still cuts on its own.** After the simulation's cut at 0.5, it cut 54 more of the judged links to draw clean, 17 of them keep links.
- **The ranking is what's missing.** At the judges' own counts, their ranking draws 56 keep links and no chip; similarity draws 30 keep links and 8 chips. The engine isn't the limit: given the right cut, it draws three in four keep links on clean boards.
- **Putting the simulation's cuts back where there's room** raises its arrows from 778 to 920, but brings chips back: 33% of its judged arrows.

## The strategy, as stated

The owner's words:

> first you draw the graph without any references. And of course, it's very dense. There would be references when things cross subboards or pages or frames or whatever, but in general, no references because of popularity/crowding
>
> Then, for areas that are congested, which would be determined deterministically by something like graph complexity, we would use vector similarity to act as a force on the arrow's edge. If the two shapes are very similar, then the force would be strong. And if the shapes were less similar, they would be weaker relatively. There would be some kind of threshold, at which point the physical arrow would be broken and a reference would be used. References wouldn't count as much in terms of the graph layout algorithm's repulsion

How `springs.mjs` builds it:

1. **Every link is an arrow.** Each board, and each frame inside it, is laid out by a force model:
   - shapes push apart;
   - every link inside the board or frame is a spring that wants a 160-unit gap;
   - gravity holds the board together;
   - shapes step out of arrows' way.

   A link to another board, or into or out of a frame, is a reference from the start. It becomes a pill in its note's strip, with a light spring between the two containers.
2. **Congestion comes from the graph alone.** In each container, the dense part is its 3-core: the largest part where every note links to at least 3 others in it. An arrow is congested when both its notes are in that part. Nothing about the picture decides this.
3. **Similarity is the force.** In a congested area, each spring is as strong as its two notes are alike, by rank among the area's arrows: the most alike pull with the full force, the least alike with a tenth of it. Arrows elsewhere pull with the full force. Similarity is the on-device contextual embedding plus word overlap.
4. **The threshold.** The sentence allows three readings, and all three were built:
   - **stretch**: an arrow breaks when it is stretched past a multiple of its area's typical arrow;
   - **strength**: the same, but the more alike the notes, the more the arrow holds, from a quarter of the limit for the least alike to all of it;
   - **force**: an arrow whose similarity is below a threshold breaks before anything is drawn.

   "As stated" below means strength, because stretch alone breaks links regardless of meaning (point 2 under why it does not work as stated). Under stretch and strength, the most stretched arrow breaks first, one at a time, and the board settles after each break. The typical arrow is measured again each time, so a board that spreads as it gains pills doesn't break by spreading.
5. **References count less.** A note pushes with its own size plus a quarter of its pills'. Pills still take room, so nothing sits on them.

It is deterministic, with no randomness. Crossings are allowed, and nothing is put back. All 72 boards draw in 30 seconds.

## Results of the rule as stated

### Against main and the layout branch

![Three boards under main, the layout branch and the strategy as stated: the system's root, Selection and Mentions. Arrows are coloured by the judges: green keep, red chip, amber between](pictures/strategy.jpg)

| all 72 boards | arrows | links inside boards cut | clean boards | crossings | lines over shapes | area (M) |
|---|---|---|---|---|---|---|
| main | 659 | 74% | 7 | 10,605 | 5,661 | 390 |
| layout branch | 1,067 | 57% | 72 | 0 | 0 | 934 |
| **as stated** | **1,431** | **43%** | **16** | **1,081** | **1,572** | **674** |

| five judged boards (459 links) | arrows | crossings | of its arrows: keep / chip | keep links drawn |
|---|---|---|---|---|
| main | 59 | 2,223 | 36% / 12% | 21 of 76 |
| layout branch | 147 | 0 | 20% / 43% | 30 |
| **as stated** | **270** | **475** | **13% / 51%** | **36** |
| as stated, links into frames as arrows | 268 | 667 | 21% / 41% | 56 |
| the threshold on the force: similarity below 0 | 216 | 496 | 26% / 36% | 56 |
| the same, below 0.5 | 161 | 266 | 31% / 35% | 50 |

Main's health is measured with the branch's straight-line check, which main never aimed at, so treat its crossings as rough.

The three boards in the picture compare like this:

| board | main | layout branch | as stated |
|---|---|---|---|
| root (359 links) | 24 arrows, 246 crossings | 32 arrows, clean | 70 arrows, 51 crossings |
| Selection (88 links) | 10 arrows, 592 crossings | 39 arrows, clean | 53 arrows, 45 crossings |
| Mentions (123 links) | 11 arrows, 366 crossings | 33 arrows, clean | 74 arrows, 113 crossings |

### Why it doesn't work as stated

1. **Frames as references cut the links that matter most.**
   - On the judged boards, 39 links cross a frame's edge, and 24 of them are keep links. Only 1 is a chip.
   - That's because the lens puts each extension point and plugin in a "Plugin system" frame, away from the file that declares it.
   - So the rule turns 24 of the 76 keep links into pills before anything is drawn.
2. **The graph decides how far an arrow stretches, not its spring.**
   - In a dense area, where an arrow's two notes end up depends on all their other links.
   - With stretch alone as the threshold, the links that break are no less alike than any other: their mean similarity rank is 0.43 to 0.51 on Selection, where 0.5 is chance.
   - It also has no middle ground: on Selection, a threshold of 1.75 breaks 5 links, and 1.5 breaks 48.
3. **Hubs never break.**
   - A force layout puts a hub in the middle of its spokes, so its arrows are short and never stretch.
   - Worse, a star has a core number of 1, so the k-core doesn't call it congested at all. On Selection, `SelectionPlugin`'s 13 registration spokes inside the frame are never tested.
   - Those spokes, and the links into the module's own `Selection` and `SelectionState` files, are what both judges chip most. They stay as the red stars in every picture.
   - Making the break point depend on similarity too (the strength reading) helps: the links it breaks have a mean similarity rank of 0.30. But of the 150 it breaks on the judged boards, 47% are chips, about the same as the 46% of all judged links, because it never reaches the hubs.
4. **Graph complexity barely narrows where meaning acts.** The 3-cores hold 70% of the links inside containers (1,179 of 1,694 pairs). On Selection, 50 of the board's 61 links are in its 3-core.
5. **The placer ignores the lens.**
   - The force model knows nothing of the lens's rows, so on the root the rungs' frames lose their order.
   - Drawing links into frames as arrows fails on the root too. There the frames hold nearly every card, so the links between two layers become one spring between their two frames.
   - The result is 349 arrows drawn where the layout never pulled their ends, with 9,460 crossings.

![Selection under the strategy as stated, at thresholds 1.5, 2, 3 and 5](pictures/threshold.jpg)

The threshold sets how many links break. On Selection it leaves:

| threshold | arrows (of 88) | crossings |
|---|---|---|
| 1.5 | 37 | 9 |
| 2 | 46 | 46 |
| 3 | 53 | 45 |
| 5 | 73 | 361 |

At every setting, the hub stars stay.

### What holds up: similarity as the threshold

![Selection and Mentions in three versions: as stated; with links into frames as arrows; and broken where the force is weak, with what each board shares taken out](pictures/variants.jpg)

- **Taking out what a board shares** makes similarity rank links more like the judges.
  - The embedding is centred on its board's mean, and a word counts by how few of its board's notes use it. So a module's own name, which runs through all its files, ties nothing together.
  - Against the judges, the mix scores an AUC of 0.82 (0.79 before), and word overlap alone 0.84 (0.78 before). The embedding alone does a little worse, 0.74 against 0.76.
- **The threshold goes on the force itself.** An arrow whose two notes are less alike than the threshold breaks before anything is drawn, and arrows into frames are kept.
  - At a threshold of 0, the judged boards get 216 arrows: 26% are keep links and 36% chips.
  - At 0.5 they get 161 arrows: 31% keep links and 35% chips.
  - That beats the branch (20% keep, 43% chips) and the rule as stated (13% and 51%). It draws 50 to 56 of the 76 keep links, against the branch's 30.
- **It still crosses,** 266 to 496 times on the five boards. And the registration star inside the frame keeps its red spokes, since a star is never congested.

## Pre-plan, if this goes on

The rule to build: a model reads each board and ranks its links, the background simulation says how many become references on each board, and the layout branch's engine draws the rest.

1. **Rank links with a model that reads the board.** Jev is asked the judges' question, one request a board, and its answers are mixed with similarity. For this repository that is 70 requests and 0.58 million input tokens. Answers are kept by the request, so a board whose notes and links haven't changed asks nothing. What's left is telling "one idea" from "related", which the tightest counts need. A better question or a second model would be tested on the judged links first.
2. **Similarity as an input.** The app computes a vector for each note when it measures it (`canvas measure`): the on-device `NLContextualEmbedding` with its token vectors averaged, and word overlap counted within the board, with what the board shares taken out. Vectors are cached by the note's text. Decisions go by rank within a container, ties by key.
3. **How many, and where: the background simulation.** Load against strength, at a threshold between 0.5 and 1. It needs no test of density of its own: crowding is what loads a link, and a hub's fan crowds. Its count goes to every board, so the engine never cuts a board by weight alone.
4. **The layout branch's engine draws the cut.** Its further cuts, its mend and its put-back go by the same ranking. Arrows into frames are drawn to their members, not as one spring between frames; the root shows why.
5. **References that don't crowd.** 70% of links go to another board, and each is a pill with a line, about 6.5 for each note. The owner chooses among:
   - chips inside the note;
   - one pill for each module;
   - leaving references under a similarity floor undrawn.

**The test bed.** The 459 judged links and Jev's answers to them become a fixture. The keep links drawn and the share of chip arrows can't regress, every board stays clean, and arrows and area are reported. A new version of Jev is scored on them before it is used.

## Open questions for the owner

1. Where is the model asked? canvas-digest could ask Jev itself, with its own key and cache. Or the app could, through `canvas decide` taking a graph document's links, with its key and its memory of answers. The app keeps answers for a day; layout wants them kept for as long as the board reads the same.
2. Should links into frames be arrows? 24 of the 76 keep links cross a frame's edge.
3. How should references look so they don't crowd: chips inside the note, one pill per module, or hidden under a floor?

## Earlier rounds of this spike

These rounds came before the owner's strategy was built. They tested a rule of mine, not the owner's: a link broke when its line was crowded in the picture, the least alike first, a tenth of the crowded links each round. They are kept for what they measured:

- how similarity ranks links against the judges;
- similarity inside the layout branch's engine;
- Selection along a continuum of cuts, ending with the cut both judges would make.

### Similarity carries the judgment

The table gives each ranker's AUC: the chance a "keep" link outranks a "chip" link. 0.5 is chance.

| ranker | AUC |
|---|---|
| one judge against the other | 0.99 |
| similarity: contextual + word overlap | **0.79** |
| word overlap (TF-IDF) | 0.78 |
| contextual embedding (on-device) | 0.76 |
| sentence embedding (on-device) | 0.73 |
| similarity with a small hub penalty | 0.80 |
| hub penalty alone (the busier end's links on the board) | 0.68 |
| popularity: the busier end's in-degree (main's idea) | 0.59 |
| link weight: how many uses | 0.52 |
| main's drawing (arrow or not) | 0.62 |
| the layout branch's drawing (arrow or not) | 0.55 |

The nearest notes make sense. On the Selection board, Faces.swift's nearest notes are ShapeFaces (0.72), Buttons, Popovers and Parts, and its farthest is the `selection` plugin hub. Across all boards, linked pairs score above unlinked pairs on the same board (AUC 0.64 to 0.73 by model).

### Neither engine draws by meaning

These are arrows on the 459 judged links. "Similarity alone" draws the same number of arrows on each board, the most alike links first, with no regard for whether the drawing can hold them.

| | arrows | keep links drawn | chip links drawn | of its arrows: keep / chip |
|---|---|---|---|---|
| main | 59 | 21 of 76 (28%) | 7 of 210 (3%) | 36% / 12% |
| similarity alone, same count | 59 | 30 (39%) | 9 (4%) | 51% / 15% |
| layout branch | 147 | 30 (39%) | 63 (30%) | 20% / 43% |
| similarity alone, same count | 147 | 43 (57%) | 41 (20%) | 29% / 28% |

Why each engine misses:

- **The layout branch.** Its cut keeps the heavier link first, then the one at the busier end, so that a hub keeps its arrows. That is the opposite of what both judges did: they chipped registration lists, style files and shared state.
- **Main.** It is sparse, so its few arrows are better ones, but its boards aren't clean.

### The first force model went all the way to islands

![The first force model, on Selection: every note in a halo of its own pills, and 60 of 61 links broken](pictures/force-collapse.jpg)

That force model worked like this:

- Notes are footprints, each a note plus its own pills in strips. The strips are the layout branch's `stripAlts`, so no line from a note runs over its own pills.
- Shapes push apart. A pill takes room but adds nothing to the push.
- Every arrow is a spring that wants a 160-unit gap, and gravity holds the board together.
- Shapes are pushed out of arrow corridors, and overlaps are removed.
- In crowded areas, a spring is as stiff as its two notes are alike.
- Each round, the least-alike 10% of crowded links break into pills, and the board settles again.
- At the end, a broken link whose straight line is clear becomes an arrow again, the most alike first.

**It failed because references block lines.**

- Each note carries about 6.5 pills for links to other boards, and any line that runs over a pill counts as crowded. So the loop kept breaking until almost nothing was left: on Selection, 60 of its 61 links broke.
- Corpus-wide, 44 of 72 boards ended clean with 496 arrows, and 54% of those on the judged links are links the judges chip.
- Sharing a pill among the notes that use a target, with pills as light nodes, didn't help.

**With pills that block nothing,** it kept arrows again, and the semantic order beat a structural control:

| force model, pills block nothing (five judged boards) | arrows | keep drawn | chip drawn | of its arrows: keep / chip |
|---|---|---|---|---|
| least alike breaks first | 170 | 30 (39%) | 76 (36%) | 18% / 45% |
| control: the most crowded breaks first | 189 | 21 (28%) | 96 (46%) | 11% / 51% |

But no judged board ended clean.

### Similarity inside the layout branch's engine

First the engine is left as it is, and each link's `layout.weight` is set to its similarity rank on its board (1 to 100). The weight already orders the planar cut, the mend's ties and the put-back, and the star placement weighs it in where notes go. Then come three small patches (`engine.patch`):

- the mend breaks the least alike link first;
- links are cut by meaning before layout;
- those cuts are kept from being put back.

| corpus-wide (72 boards) | arrows | clean | crossings | over shapes | own lines | area (M) | judged: of its arrows keep / chip |
|---|---|---|---|---|---|---|---|
| main | 659 | 7 | 10,605 | 5,661 | 7,401 | 390 | 36% / 12% |
| layout branch | 1,067 | 72 | 0 | 0 | 10 | 934 | 20% / 43% |
| branch + similarity as weight | 1,073 | 72 | 0 | 0 | 12 | 1,055 | 18% / 39% |
| branch + least alike first in the mend | 1,077 | 72 | 0 | 0 | 12 | 1,055 | 18% / 39% |
| branch + **the least-alike half cut before layout** | 898 | 72 | 0 | 0 | 10 | 852 | **27% / 38%** |
| branch + cut by density (1.5 links a child) | 993 | 72 | 0 | 0 | 11 | 982 | 22% / 35% |
| branch + the half cut, never put back | 726 | 72 | 0 | 0 | 12 | 852 | 27% / 36% |
| first force model, pills block lines | 496 | 44 | 0 | 52 | 1,321 | 635 | 18% / 54% |
| first force model, pills block nothing, least alike first | 1,074 | 21 | 131 | 1,037 | 2,760 | 695 | 18% / 45% |
| same, control: most crowded first | 1,135 | 22 | 143 | 947 | 2,794 | 650 | 11% / 51% |

**Ranking alone changes almost nothing.** As a weight, similarity orders only the planar cut, which makes 391 of 1,449 cuts. The mend makes the other 1,058: the link in the most conflicts goes first, so meaning only breaks ties.

**Cutting by meaning first helps.** Every board stays clean, the area is smaller, and the share of arrows that are chips falls from 43% to 35–38%. But the engine's geometry still decides which of the remaining links survive.

### Frames: the links into them matter most

24 of the 76 keep links cross a frame's edge, against 1 of the 210 chip links. Of those 24 links, 14 join an extension point to the file that declares it, and 9 join a plugin to a file. The layout branch's slice 4, which draws links into frames as arrows, was right.

### Meaning is not role

A module's entry file lists every name the module declares, and its style and state files carry the module's own name. So word overlap ties them to every file on their board, and their links survive. A hub penalty adds a little (0.79 to 0.80). Counting a word by how few of its board's notes use it adds more: word overlap goes from 0.78 to 0.84 (the latest round). The lens could also declare a role, such as registration or plumbing. 22 notes have no text at all (11 of them plugins), and these embed by their title alone.

### Along the continuum

These boards use the first force placer, on Selection only, with crossings allowed and arrows into frames. Links are cut least alike first, from none to half. The top row shows the pills for other boards, and the bottom row hides them.

![Selection with none, 10%, 25% and 50% of its links cut, the pills for other boards shown above and hidden below](pictures/continuum.jpg)

| links cut, least alike first | crossings, pills shown | crossings, pills hidden | of the cut: judges chip / keep |
|---|---|---|---|
| none | 698 | 302 | |
| 8 (10%) | 494 | 287 | 7 / 0 |
| 20 (25%) | 374 | 206 | 17 / 1 |
| 41 (50%) | 142 | 72 | 33 / 2 |

The last panel below is cut exactly where both judges chip. That's the target, made from the judges' labels; no embedding was used to make it. The judges chip 53 of Selection's 88 links, keep 15, and split on 20. Cut there, 30 arrows are left, and they read as a graph. Cutting the same 53 by similarity alone gets 42 of them, and its 11 misses all run into the module's hub files.

![Selection cut 25% and 50% by similarity, and cut where both judges chip](pictures/judges-cut.jpg)

### Pictures from the earlier rounds

Each picture shows one board under main, the layout branch, the branch's engine with the least-alike half cut first, and the first force model. Every arrow is coloured by the judges: green means both say keep side by side, red means both say chip, and amber is in between. Pills are blue, and pale lines go into pills.

![Selection under main, the layout branch, the spike in the branch's engine, and the first force model](pictures/selection.jpg)

![Mentions, the same four](pictures/mentions.jpg)

## Caveats

- The judges are Claude models that read whole boards. Jev reading whole boards is closer to how they worked than similarity is, so part of its lead may be habits it shares with them. A person's labels would settle it.
- The four ways of asking, the two questions and the mix were each decided before their results. Nothing was fitted to the judges' labels, but the labels did pick the board over a link alone, and the mix over Jev alone.
- Jev answers in hundredths, and its versions change. The answers used are kept in `data/jev-*.json` (`jev-1.14.0`).
- The judges are language models, not the owner. Their labels are coarse, they covered five boards, and there is one corpus, a codebase; prose would embed better.
- `springs.mjs` had about an hour of tuning. Its parameters were swept only as shown: the 3-core, the springs' floor, the thresholds and the references' weight.
- `background.mjs` had about as much. Its three physics were swept only as shown, and the threshold of 0.5 to 1 is fitted to this corpus.
- The judges' cut is an upper bound made from their labels. Nothing computes it.
- The k-core is one reading of "graph complexity". A test of density that sees stars would change point 3 under why it does not work as stated.
- The pictures are schematic: drawn from each drawing.json as the health check reads it, not captured from the app.
- Main is measured by the branch's straight-line check.
- The spike's earlier runs used the layout branch's tool with its uncommitted slice 5 work, which plans a fresh document byte for byte as slice 4 does. `reproduce.sh` uses slice 4 as committed.

## Reproduce

Everything is in this folder:

- `data/`: the corpus as canvas-ingest drew it (`graph.json`), the app's measure of it (`measure.json`), the kinds (`kinds.json`) and Jev's answers (`jev-*.json`). `texts.mjs` and `embed.swift` make the texts and vectors again.
- `judge/`: the judges' input, their labels and their scripts.
- The scripts:
  - `jev.mjs`: asks Jev about every link inside a board (`--variant=pair|roles|board|boardroles|levels`). It keeps the answers by request in `out/jev-cache.jsonl` and writes `data/jev-<variant>.json`. It needs the TypeSafe key: `TYPESAFE_API_KEY`, else its export line in `~/.zshrc`, else the app's key file. The key is never printed. `rank-eval.mjs` scores rankings against the judges, and `background.mjs --score` ranks by Jev's answers wherever it would rank by similarity.
  - `background.mjs`: the simulation in the background, with its three physics (`--physics=load|crowding|meaning`), the threshold (`--snap`), and the cuts it writes for the engine, its own and the controls' (`--emit`). `engine-eval.mjs` scores a drawing the engine made from a cut, and `hubs.mjs` follows a board's busiest notes. `simcut.patch` lets the layout branch's engine take a cut before layout (`SIM_CUT`) and keep it (`SIM_KEEPCUT`).
  - `springs.mjs`: the strategy as stated, with the three readings of the threshold (`--break=stretch|strength|force`), `--sim=board`, `--frames=arrows`, `--others=hide` and `--auc`. `springs-eval.mjs` scores its boards against the judges.
  - `texts.mjs` and `embed.swift`: the vectors.
  - `sim.mjs`, `check-sim.mjs`, `eval-judge.mjs`, `agree.mjs`, `ceiling.mjs`, `combo.mjs` and `samecount.mjs`: the measures.
  - The earlier rounds:
    - `semlayout.mjs`, the first force model, with `--light`, `--simk`, `--precut`, and for the continuum `--budget`, `--frames=arrows`, `--others=hide`, `--nocrowd`, `--hub` and `--oracle`;
    - `semlayout2.mjs`, shared pills;
    - `semweights.mjs`, similarity as weights for the branch's engine, with `engine.patch` holding its three spike changes;
    - `cutjudge.mjs`, which says which of a drawing's cuts the judges would make.
  - `score-drawing.mjs`, `render.mjs`, `compose.mjs`, `panel.mjs` and `stitch.swift`: health and pictures.

The scripts import the layout branch's canvas-digest tool (`DIGEST_TOOL`, its `lib/` folder; commit 4bc3494e on `claude/canvas-layout-strategy-f81c7d`, a local branch). `reproduce.sh` runs every measure above and draws the pictures again, in about 25 minutes. It uses Jev's answers in `data/`, and asks Jev again only with `ASK_JEV=1`. If swiftc says the SDK isn't supported, set `SDKROOT` to one that matches the compiler, as the repository's build notes say.

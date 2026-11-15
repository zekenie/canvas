# Which links are arrows, which are references, and where the notes go: one plan

**Recommendation.** Keep your strategy's shape and build the three parts of it that measured well: how alike two notes are picks which links on a board become references (shared words, counted within the board: free, offline, deterministic, and on this codebase as good as OpenAI's embedding); your background simulation picks how many break on each board; and the layout branch's engine draws the rest with no crossing, as decided. Three parts of the rule as first stated fail and are dropped: similarity as a live force (the layout, not the spring, decides what stretches), graph complexity as the test for congestion (it never sees a hub), and references for links into frames (those are the links most worth drawing). Jev is the one thing that beats this, and it is your call, because it puts a model in the loop.

The ruler below: two blind readers (Claude models) labelled 459 links on five boards; 76 are worth drawing, 210 should be pills. "Drawn" counts the 76; "wrong" is arrows on the 210. Slice 4 draws 30 of 76, with 43% of its judged arrows wrong.

| Option | Verdict | Why |
|---|---|---|
| Popularity and crowding choose (main) | drop | barely better than chance at picking the links a reader wants; 7 of 72 boards clean |
| The engine's own fewest-cuts choice (branch) | drop as the chooser | keeps a hub's spokes the readers would cut; 30 of 76 drawn, 43% wrong |
| Your rule as stated: live force, congestion by graph complexity, break on stretch | drop | what stretches is the graph's doing, not the spring's; a hub is never "congested"; half its arrows wrong |
| Similarity as a threshold before anything is drawn | keep, as the ranking | the part of your rule that holds up: 50 to 56 of 76 drawn, with crossings allowed |
| Your background simulation (crowding loads a link, likeness sets what it holds) | keep, for how many break per board | its order is similarity's, a little worse; its count grows with each board's crowding |
| A fixed share of each board's links | drop | fewer arrows than the simulation's count for the same quality |
| Apple's on-device embedding | drop | ranks worse than shared words alone, and drags them down when mixed in |
| Shared words, counted within the board | keep | right 84 times in 100; 35 of 76 drawn, 20% wrong; no model, no network |
| OpenAI's embedding, large or small | your call (2) | 85 to 86 in 100; drawn, 1 or 2 links more than words, within the noise; the texts leave the Mac |
| Jev reading the board, mixed with shared words | your call (1) | 95 in 100; 42 of 76 drawn, 12% wrong; a model in the loop, about 2.4¢ a repository |
| The branch's engine: stars, rows, strips, shared pills, put-back, frames | keep | the only placer with every board clean; given the readers' own cut it draws 56 of 76 |
| The rule's force placer, crossings allowed | drop | 16 of 72 boards clean, 1,081 crossings, 1,572 lines over shapes; loses the overview's rows |
| Main's placer and mess dial | drop | already gone on the branch, by your decision |
| No crossing ever (decided 2026-11-07) | keep | its price is the engine's own cuts, 18 to 26 of 76 whatever the ranking; step 2 goes after that |
| Links into frames | arrows (slice 4) | your rule said references there; 24 of 76 links worth drawing cross a frame's edge, 1 of 210 others |
| Links to other boards | pills, as now | every strategy does this; how pills look is out of scope |
| Slice 5, redraws that stay put | keep | its rule and tests stand; committed after step 1, re-checked in step 4 |
| Slice 6, splitting dense boards | drop | nothing to split by here; 12 arrows won for 4% more area with ideal groups |
| Spines on the overview | keep | decided |

**Your decisions.**
1. Does Jev go in the loop? My answer: not in the first build. Step 3 shows you the same boards with and without it; decide there, on the boards, knowing it costs a network call per changed board.
2. Does an embedding model go in the app? My answer: no. On this codebase shared words match it within the noise, free and offline. The ranking takes any score, so it can be tried later behind a key if boards of prose rank badly.

**The steps.** Each ends with real boards in the app (root, Selection, Mentions, Draw, Types/Form) captured beside slice 4's, and you say whether they read better. Every step calls no model unless it says so.
1. **The cut.** The tool ranks each board's links by shared words, the simulation says how many break (shown at two settings, few and many), those become pills before layout and stay pills, and slice 4's engine draws the rest. Judged by you on the boards, and by the ruler over three counts: at least 35 of 76 drawn, at most 20% wrong, every board clean. If the boards don't read better than slice 4's, stop. About a day of one builder; no model calls.
2. **The engine's own cuts follow the ranking.** Where the engine must cut further to draw clean, it cuts the least alike link in the conflict, and puts back only its own cuts, never the ranking's. Judged by the engine's cuts of the 76 falling from 18 to 26 toward 13, boards still clean. This is the least proven step: one earlier try changed little. One to two days.
3. **Jev beside it.** The same boards cut by Jev plus shared words, cached by board. Judged by you, side by side, for decision 1. Half a day and a few cents.
4. **Redraws and landing.** Slice 5's redraw rule re-checked on the new cut (a drag survives, an unchanged document redraws the same); then slices 1 to 4, the cut and slice 5 land on main as one change, with the plan doc rewritten. A day.

**The existing work.** Slices 1 to 4 stay whole as the engine and land with the cut in step 4, once you've said the boards read better. Slice 5's uncommitted round 2 is committed on the branch after step 1 with its one failing check dropped, as offered on 2026-11-10. Slice 6 is dropped. The spike stays as evidence: its 459 labelled links and Jev's cached answers become the tool's test fixture; its pre-plan's items 1 to 4 are these steps (item 1 is decision 1), its item 5 is out of scope; issue 26 closes with a pointer when that lands, posted by you. Main's strategy is replaced by the landing; nothing of it is kept but the spines.

Not explored: the simulation run with shared words alone as its strength (its counts were made with Apple's similarity); any corpus but this codebase.

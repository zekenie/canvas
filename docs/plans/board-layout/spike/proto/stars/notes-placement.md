# STARS, round 3 (stars3): star placement

Round 2 (../dir-stars2/notes.md) is unchanged underneath: kit 'edges' cut, stress, point untangling, stretch, local search, compaction,
cut what's left, restore cuts, five configurations per board in workers, the best clean one kept, then the shared-pill pass (wrap.mjs, as
planar/wrap/stars2.mjs). The kit is imported as it is: footprints and strips are whatever it gives.

## What changed (module.mjs)

Three more configurations (8 in all, each in its own worker) run the search with the placement rules on (`v3: true`); the five of round 2
stay, so a board can't come out unclean where round 2 was clean. The rules, all general:

1. **Hubs central, heaviest nearest.** The link weight between two units is every edge between them, drawn or cut. Stress's ideal distance
   between two units shrinks with the drawn arrows between them (÷ 1 + 0.25·ln w). In the search, each unit also tries 25 spots right up
   against (and aligned with) each of its two heaviest neighbours' footprints, whatever its arrow count (round 2: only units with ≤3 arrows).
2. **Long arrows pay.** An arrow longer than four note widths (the board's median note) costs 6 per unit of overshoot in the search, on top
   of its length, so a note is pulled in next to what it connects to before it's left at the far end. (Cutting into a pill stays the cut
   loop's: only when a conflict can't be removed.)
3. **The frame beside what it connects to.** A frame unit also tries spots flush with each side of the rest of the board, at the centroid
   of the notes it has arrows with (three offsets along the side); the length cost picks the side nearest them.
4. **A pill block on the free side.** In the search, a note's pill block costs 300 for each of the note's own arrows that leaves by that side
   (by the arrow's main direction), so the side with fewest arrows wins.
5. **Loose notes** (every arrow cut) go right beside the unit they have most cut edges with, on a free spot no straight arrow passes near,
   if that doesn't grow the board's window-shaped area by more than 8% plus about four note cells; the rest go in a tight grid along the
   short side of what's placed (a column of rows on the right when the board is wider than 1.5, a row grid below otherwise).
6. **The pick among configurations** (round 2: (area + 25,000 × pills) × aspect term) adds 2,500 per unit of arrow overshoot past four note
   widths, and multiplies by 1 + 1.5 × (ratio − 1.1) when the board's area is over 1.1× today's (today-metrics.json).

## Files

- `module.mjs`: the direction; `module-run1.mjs` the same at the first full build.
- `wrap.mjs`: module.mjs, then shared pills (what the owner sees), with each board's overlaps (planar/overlaps.mjs) in its info, and with
  `SAVE=dir` each board's layout saved; `replay.mjs` serves those to look.mjs (`LAYOUTS=dir`), so pictures don't lay out again.
- `cmp3.mjs`: per board before and after (area against today's, aspect, pills, longest and mean arrow).
- `check3.mjs`: reads a build back from drawing.json (lossy for pills: don't trust its overlaps; use the info in metrics.json).
- `measure3.mjs`: measures every saved layout (kit.evaluate and overlaps) into a metrics.json.
- `build-stars3/`: layouts/ (every board laid out, saved by wrap.mjs) and metrics.json (from measure3.mjs); no drawing.json, since the
  full build was stopped (below). `build-rest/` has the drawing of the last 13 boards. `out/`: pictures of the bad boards (label stars3).

## Numbers (stars2 = run/tidy-stars2, what the owner saw; stars3 = build-stars3, both with shared pills)

```
direction  clean  crossings  overNotes  overOtherPills  pills   area vs today (median)   Mentions: crossings/overNotes/pills, size
stars2        71          0          0               0   6335        x1.09              0/0/277, 6586x5011
stars3        70          0          0               0   6196        x1.03              0/0/286, 4766x5663
```

Over the same 70 boards (Canvas/Plugins apart, see below): pills 6189 -> 6196; median area x1.09 -> x1.03; largest x2.97 -> x2.43
(Selection); boards over x1.6 of today's: 11 -> 2 (Selection x2.43, Draw x1.77); sum of each board's longest arrow 75,150 -> 59,179;
median mean arrow 144 -> 135. Overlaps (planar/overlaps.mjs, measured on the layouts themselves): 0 on all 70. measure3.mjs re-measures.

**Canvas/Plugins was not verified.** The first full build hung on it for 8+ minutes (its v3 configurations are slow: 131 edges, 137
straight crossings in a first round, so many cut rounds); I stopped that build, measured the 57 boards it had saved, and built the rest in
two more runs (build-rest/, build-plugins/). The Plugins run had not finished by my deadline. It needs a work budget on the v3 configs
(deterministic: a cap on search evaluations, the config dropped when it's spent) before the next full build; until then it's stars2's.

## The 20 boards the review called bad (area vs today, aspect as kit.evaluate gives it, pills, longest, mean arrow)

```
board                 stars2                            stars3
Arrows                x0.95 a0.92 p251 L1909 m234       x0.94 a1.02 p251 L1156 m207
StickyNotes           x0.83 a0.65 p181 L3037 m303       x0.73 a0.34 p184 L1185 m270
Selection             x2.97 a1.53 p285 L3282 m244       x2.43 a0.99 p280 L4281 m232
ContextMenus          x0.81 a0.70 p44 L445 m136         x0.83 a0.68 p44 L430 m114
SlashCommands         x1.09 a1.37 p92 L2457 m225        x1.08 a0.72 p89 L1199 m175
Find                  x1.74 a0.79 p88 L1459 m163        x1.31 a0.84 p86 L1036 m157
Boards                x1.53 a1.25 p103 L1225 m130       x1.16 a1.69 p100 L1248 m158
Colors                x1.57 a1.72 p131 L1565 m272       x1.07 a1.00 p130 L679 m127
Types                 x0.83 a0.68 p92 L1564 m536        x0.84 a0.67 p92 L1564 m536   (unchanged: a round-2 config still wins)
LanguageRules         x1.70 a1.91 p261 L3364 m282       x1.38 a1.26 p270 L1128 m234
Draw                  x2.13 a1.35 p318 L3785 m352       x1.77 a1.68 p314 L3504 m293
QueryTranslation      x0.90 a0.86 p70 L1151 m153        x0.79 a0.83 p71 L778 m112
Canvas/Editor         x1.03 a0.72 p135 L1714 m260       x0.94 a0.88 p129 L1169 m217
Canvas/Plugins        x3.72 a5.89 p146 L18234 m1648     not verified (see above)
Types/Checks          x1.09 a0.64 p88 L893 m280         x1.06 a1.14 p87 L893 m240
Types/Fields          x1.60 a1.02 p179 L2059 m187       x1.41 a1.14 p187 L1073 m149
Types/Form            x2.93 a1.27 p320 L3303 m353       x1.57 a0.88 p330 L1234 m216
Types/IsA             x1.22 a0.61 p324 L1021 m226       x1.17 a0.77 p322 L1085 m198
Types/Rows            x1.79 a1.14 p254 L1956 m292       x1.16 a0.83 p253 L1436 m258
Types/Sync            x1.36 a0.83 p105 L871 m291        x1.26 a0.86 p102 L737 m193
```

What changed, by board: the longest arrow halved or better on Arrows, StickyNotes, SlashCommands, Colors, LanguageRules, Types/Form,
Types/Fields, QueryTranslation, Canvas/Editor (the length cost and the abut candidates pulling users in beside their hub); area came down
on Find, Boards, Colors, LanguageRules, Draw, Types/Form (x2.93 -> x1.57), Types/Rows (the area cap in the pick and loose notes beside
their neighbour). Draw's frame now sits on the top side beside DrawPoints, which it connects to; its two loose notes (Measure,
Surroundings) are a column on the right, the short side. Selection is square now and smaller, but its longest arrow grew (the Plugin system
frame below, as one long row from the kit, with arrows up to the stars), and one loose note sits alone under it. Types didn't change.

## Still weak

- Selection: still x2.43 of today's and the frame's arrows long; its frame is one wide row (the kit's frame layout), which a frame side
  can't fix.
- StickyNotes came out tall (kit aspect 0.34): the pick weighs area over shape there; the aspect term should be stronger when a board is
  far off 1.5.
- Draw still has long arrows from its frame across to the right; Types/IsA's longest grew a little.
- The pill-side rule is a cost in the search, not a hard rule: a note with arrows on every side still puts its block across some.
- Cutting a long arrow into a pill when it can't be pulled in isn't done: the pick prefers configurations with less overshoot instead.
- Build time: the first full build passed 10 minutes because of Canvas/Plugins (above).

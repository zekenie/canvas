# ROWS, round 2 (dir-rows2)

This round starts from the first round's `dir-rows` (its notes describe the engine) and tunes it for compactness. The contract is unchanged: `module.mjs` exports `layoutBoard(m, board)` and returns `{ layout, info }`. The output is deterministic. Clean on all 71 boards, verified by a full build (`build/`, 2 min 21 s).

## What changed

All the changes are in `module.mjs`.

1. **No hats.** Pill blocks never go above a note (`above: false` is the default, and the `above: true` variants are gone). A note nothing uses keeps its block beside it.
2. **Tighter spacings.** The variants no longer include the wide spacings (gapY 320 or 400, dummy lanes 120 or 200). They now include tight ones: gapY 50, 70 and 90; gapX 24, 32 and 40; lanes 14 and 20.
   - Each spacing is tried with three row wraps: the old 1.1, a tighter 0.85, and none.
   - There are 23 variants now, against 28 before.
3. **Choosing a variant leans to compact.**
   - The weight on log(area ÷ area covered) went from 4 to 14.
   - A small penalty (0.5 each) now counts arrows whose bend is over 260.
   - A variant must still be clean, and has the fewest post-cuts first.
4. **Smaller gaps elsewhere:**
   - between components and the loose-note/hub grid (`compGap`): 160 → 60
   - between rows inside a frame (`frameGapY`): 120 → 80
5. **New knobs, left off by default.** `fixBends` takes `bendCap` and `bendMax` from the parameters, and there is a mean-length term (`lenW`).

## Totals (table.mjs)

```
direction  clean  crossings  overNotes  overOtherPills  pills   area vs today (median)   Mentions: crossings/overNotes/pills, size
today          6      10364       1412            8886   4015        x1.00              367/74/203, 5529x3824
rows          71          0          0               0   6480        x1.67              0/0/296, 9290x6799
stars         71          0          0               0   6255        x1.22              0/0/283, 5617x6046
islands       71          0          0               0   6452        x1.46              0/0/281, 8532x5589
rows2         71          0          0               0   6996        x1.30              0/0/316, 7937x5239
```

Beside round 1, from both builds' metrics.json:

| | rows | rows2 |
|---|---|---|
| median mean arrow | 255 | **231** |
| median longest arrow | 1507 | **1205** |
| bent arrows (all boards) | 411 | **344** |
| edges cut after layout | 120 | 241 |
| Mentions mean / longest arrow | 265 / 3708 | **233 / 2872** |
| Mentions aspect | 1.37 | **1.51** |

Raw pills went from 6876 to 6996. The table's pill column is a different count from the raw one, and it shows 6480 → 6996. The cost of the tighter spacings is twice as many post-layout cuts, because tight rows leave less room to arc.

## Experiments run along the way

All of these were full builds, and all were clean on 71. The table gives the median area against today's and the raw pill count.

| run | what changed | area | pills |
|---|---|---|---|
| A | spacing and scoring changes only | x1.43 | 6953 |
| B | `bendCap` 0.4, `bendMax` 360 | x1.43 | 6974 |
| C | sparse weight 14 | x1.40 | 6977 |
| D | C plus tight spacings and the smaller gaps | x1.35 | 6983 |
| E | D plus wrap 0.7 | x1.35 | 6984 |
| F | D plus the 50/24 spacing | **x1.30** | 6996 (kept) |
| G | D plus the length term | x1.34 | 7010 |

- In B, capping bends cut more and gained no area, so it is not kept.
- In E, wrap 0.7 changed nothing.
- G's length term is not kept.

## Pictures

`out/` holds `<Board>-rows2-vs-today-fit.png`, `-rows2-fit.png` and `-rows2.png` for Mentions, Selection and StickyNotes.

## What looks better

- **Mentions** is now 7937×5239 at aspect 1.51, the window's shape. In round 1 it was 9290×6799.
- **The frame and the hub grid are pulled in.** The hub grid sits near the frame instead of far off with empty floor between.
- **No pill hats.** Every block is beside or below its note, so the rows read name-first.
- **Arrows are shorter and fewer are bent.** The longest arrow is shorter on most boards, and the worst swoops on Mentions are a little smaller.

## What still looks bad

- **Still sparse at fit.**
  - Area is x1.30 of today's, not x1.00. On Mentions the top source row is stretched across the full width: isotonic pulls it toward users spread below.
  - The lower rows have wide gaps where placeholder lanes and wide side pill blocks sit.
  - Notes still look small when the whole board first shows.
- **Long arcs remain.** Mentions still has a few big arcs: from `MentionPlugin` over the frame, and from the frame and the left column down to `MentionTextFormat` and `MentionTextView` at the bottom. They span 4–5 rows. The fix is still to move the note (level it closer to its users, or put it beside them) rather than arc. That isn't built.
- **More pills.** The tighter rows are cut more after layout (241 edges vs 120).
- **The hub grid is still its own block.** It is closer now, but it is not woven into the rows next to its users.
- **Next steps that would actually move area:**
  - compact x with Brandes–Köpf (shared lanes, rows not stretched by far neighbors)
  - put a long-span note at the level of its users
  - put each hub or cut-off note in the gap nearest its users

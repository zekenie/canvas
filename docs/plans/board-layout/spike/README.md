# The spike: prototypes and test data

The prototypes behind [the plan](../README.md). They're plain JavaScript (node 24) over a model of this repo's boards, and they write the same drawing.json the digest's `canvas apply` takes. They are a reference for porting, not code to ship.

## Setup

```sh
cd docs/plans/board-layout/spike
tar xzf data.tar.gz
swiftc -O tools/svg2png.swift -o proto/svg2png
swiftc -O tools/compose.swift -o compose
swiftc -O tools/grid.swift -o grid
```

`tar` unpacks `data/` (the graph document, the app's measurements and kinds for this repo's 71 module boards, from canvas-ingest at `c1a1e693`, the measurement's `lines` added later from this branch's `canvas measure`: the two edges the app draws as one arc through each of the overview's relationship types) and `run/today/drawing.json` (today's engine on the same document). The `swiftc` lines build the picture tools, which only the pictures need. Everything unpacked or built is git-ignored.

`strategy.tar.gz` (unpacked by `tool/test/corpus.sh`, not by hand) holds what the corpus check of canvas-digest's `cluster` is made from: `strategy/tightness.json` (the tightness of every link as OpenAI's text-embedding-3-large gave it, in the form `canvas measure --tightness` answers), `groups.json` (the groups the spike made of it, the spike's `data/groups-decided.json`: resolution 1.5, which the tool must make byte for byte) and `measure.json` (the reference's own measurement, which differs from `data/measure.json` in `board.name` and formatting only). `strategy-tightness.mjs` wrote them, once: it needs the spike's own untracked `data/emb-openai-3-large.f16`, so it has no task. `mise run test:digest-corpus` runs the check.

## Running it

| What | Command |
|---|---|
| Lay out every board (or name some: `module:Mentions`) | `node proto/planar/build.mjs "$PWD" proto/stars/wrap.mjs run/stars` |
| Check a build: clean boards and every overlap | `node proto/planar/verify.mjs "$PWD" run/stars` |
| Totals against today's engine | `node proto/planar/table.mjs "$PWD" "stars=run/stars/metrics.json"` |
| Pictures of every board, and their measures | `node proto/planar/sheet.mjs "$PWD" run/stars judge/stars "stars"` |
| One board beside today's | `node proto/planar/look.mjs "$PWD" proto/stars/module.mjs judge/look stars module:Mentions` |
| The planarity test's own checks | `node proto/planar/selftest.mjs` |

To draw a build in the app, give the digest the build's folder: `.claude/skills/canvas-digest/digest apply --out <run dir> --board <id>`. Use a copy of the app on its own `CANVAS_SOCKET` (`.claude/rules/build.md`).

**Last full run of this copy** (2026-11-07): all 71 boards clean, nothing on top of anything, 6,455 pills, median area 1.05× today's engine's.

## What each file is

| File | What it does |
|---|---|
| `proto/harness.mjs` | Loads the boards as a model (`load`). Defines the layout format (boxes, pills, arrows), draws an arrow the way the app does (`arrowPoints`), measures, and renders. |
| `proto/planar/planar.mjs` | The planarity test (Demoucron–Malgrange–Pertuiset, quadratic), the greedy edge cut, and the greedy hub cut. |
| `proto/planar/kit.mjs` | Shared steps: `boardGraph`, `cut` (`'hubs'` or `'edges'`), `footprints` (a note with its pills; a frame's inside), `assemble` (the layout, with arcs only where needed), `evaluate` (clean or not). |
| `proto/stars/` | **The best prototype**: stars placement (`module.mjs`, eight setups in worker threads; the clean, overlap-free one wins), with its own kit (`kit.mjs`: strips of at most 8, bends at most 120, frame insides as stars). `wrap.mjs` adds shared pills. |
| `proto/rows/` | Rows by dependency level. Clean on all 71 boards in 75 s, but built against an earlier kit: rerun it before trusting its numbers. |
| `proto/planar/share.mjs` | Shared pills: a neighbour's pill for the same file is used once, when that stays clean. |
| `proto/planar/deoverlap.mjs`, `fan.mjs` | A pill that overlaps something moves to the nearest clean spot by its note. |
| `proto/planar/verify.mjs`, `overlaps.mjs` | The check: clean boards, and anything on top of anything, read back from the drawing as the app would get it. |
| `proto/stars-pull/` | Reference only: round two's pass that pulls notes toward their heaviest neighbours, never verified. |
| `review.json` | The last review: six reviewers judged every board's pictures, a verdict and issues each, plus the ranked themes. |

## Known issues

- **The today's-area penalty never runs.** `proto/stars/module.mjs` penalises boards over 1.1× today's area, but it reads `today-metrics.json`, which this folder doesn't hold. The reviewed build ran without the penalty. The port should pass the area target in rather than read a side file.
- **Slow.** The full build takes about 12 minutes on a 10-core Mac: each board is laid out eight ways, and Canvas/Plugins alone takes about 4 minutes.
- **The worker pool reports errors to the wrong board.** The pool's `job()` used to leave error listeners attached, so one board's crash was reported against every board after it. The copy here removes each listener with its job.
- **The planarity test is quadratic.** It's fine at 60 notes; a board of 300 needs a linear-time test.
- **`look.mjs` and `sheet.mjs` need the picture tools** from Setup.

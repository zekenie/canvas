# PR #2: Say titles on shapes when zoomed out; show no adornments on skeletons
Branch claude/epic-albattani-ogtw8d, opened 2026-10-03T23:57:50Z, merged 2026-10-04T00:21:44Z.
Made by a Claude Code session in the cloud; its transcript isn't on this machine, so this PR is the record of it.

## Description

## What

Below 35% zoom, where shapes draw as skeletons:

1. **No adornments.** Title pills, lock chips and every other adornment are no longer drawn, laid out, hit-tested or made on a skeleton. The old "blank capsule" machinery (`BlankRun`, blank widths/fills, the two-tier label/face cache) is deleted. The shape being edited keeps its adornments in full.
2. **Titles go on the shape (a "cover").** Every titled shape (notes, subboards, frames, schema cards) says its title large on itself, drawn by a new Titles overlay (`TitleCoverOverlay`, `Sources/Titles/TitleCovers.swift`) over every skeleton shape, back to front, so a frame's title isn't hidden by what it holds.

### How a cover looks (revised after a first look at 28% in the app)

- **Plain text, no plate.** The ink is dark on a light surface and light on a dark one, chosen from the surface each kind says its skeleton is drawn on (new `title(coverSurface:)` opt-in; notes, subboards, frames and schema cards pass theirs; dynamic colors follow the appearance; default skeleton gray otherwise). A halo of that surface color around the glyphs keeps it clear over what lies under it (a frame's notes, a note's greeked lines).
- **Size follows the shape, not the title:** 0.22 of the shorter side, 9–28 pt, to half points, so equal shapes have equal titles (the first version made "cli" huge and "adornments" tiny). It shrinks only for the room and until the widest word, *as measured*, fits a line.
- **Words are never broken** ("mentio/ns" is gone). Wrapping is on whole words; a word that can't fit even at 9 pt sets the title on one line, truncated with "…". Words over 16 columns and text with no spaces (Japanese) still break where the line does.
- Centered, or at the top-left of a container (frames), where the pill goes in full.

### Ellipses

- Titles over **120 characters** are cut there and end in "…" *before* any layout, so a 10,000-character title costs what a short one does.
- A title that doesn't fit the room wraps and its last line is truncated by AppKit with "…". Nothing is drawn outside the shape.
- A short, wide shape (a schema card ~15 pt tall at 30%) gives up its edge inset so it can still show one line.
- No cover for untitled shapes, kinds with `pill: false`, shapes under 40 × 15 pt on screen, or the shape being edited.
- New public API: `editor.titleCover(of:)` → `TitleCover(text, rect (world), fontSize)`; `title(coverSurface:)` on the title sugar.

### Known limits (also under "Not built yet" in docs/plugin-system.md)

- A default subboard (240×160) only gets a cover down to ~17% zoom, a default note to ~20%. At 10% those show no title. Letting small shapes' labels overhang (with collision handling) would reach further.
- A note's greeked text lines still show beside its cover (the note's skeleton doesn't know about it).
- The cover isn't a pointer target: a frame zoomed out is pressed on its border only, and a locked shape's chip can't be clicked on a skeleton.
- Cover text isn't cached between frames; each is laid out as drawn. Shapes too small are culled by kept bounds before their title is looked up.

## ⚠️ Not built or run

This was written in a cloud environment with no Swift toolchain. **Nothing has been compiled or tested.** A read-only review for compile errors was run once against the earlier version (two fixes applied); the plate-less rewrite has not been reviewed that way. Expect a possible round of compile fixes.

## Testing instructions (run in a terminal on the Mac)

```sh
./build.sh audit                      # module graph / import audit first
./build.sh                            # debug build; fix any compile errors
./test.sh                             # full suite
TEST_FILTER="Title covers" ./test.sh  # the new cover tests
TEST_FILTER="Adornments zoomed out" ./test.sh
TEST_FILTER="Skeletons, as shipped" ./test.sh
./build.sh bench                      # the zoomed-out-to-fit line now also reports a frame just
                                      # under 35% with covers (reported, no budget)
```

Tests changed because behavior changed (blank adornments → none): `AdornmentsTests` (SkeletonTests rewritten; Drawing/Placement/Pointing set `skeletonZoom = 0` for the "shrinks below 25%" checks), `TitlesTests` (new `CoverTests`; pill/placeholder skeleton tests), `LockingTests` chip, `CompositionTests` (SkeletonsShippedTests, BoardWindowTests, pinned registry report now `… · /title → every shape · overlay TitleCoverOverlay`), `SubboardsTests`, `SchemasTests`, `FramesTests`. The pinned report line is also in `docs/plugin-system.md` (checked by ShippedTests).

Manual check in the app (`./build.sh && open build/InfiniteCanvas.app`), light **and** dark mode:

1. Zoom to ~28% on a board of short single-word notes ("lock", "cli", "mentions", "adornments"): equal-size notes should have equal-size titles where they fit, no word split across lines; the longest words shrink the title, and a word that can't fit in a very small note shows "adorn…" on one line.
2. A frame with a long title (100+ characters) holding a few notes, below 35%: title at the frame's top-left, whole-word wrapped, ending in "…", legible over the notes inside (halo).
3. Titled subboard (default size) and schema card: covers appear around 17–30% zoom; none once the shape is a speck.
4. Zoom across 35% repeatedly: pills/lock chips appear only above it; covers only below it. A locked note shows no chip at 30%.
5. Ink: dark text on yellow notes and white cards in both appearances; light text on the dark-mode frame/subboard; dark text on the light-mode ones.
6. Edit a note at 30%: its pill shows in full while the others show covers.
7. Pan/zoom a board with hundreds of titled notes around 25–34% and watch for frame drops (what the benchmark line reports).

Docs: `CLAUDE.md` and `docs/plugin-system.md` updated (Titles cover section, Adornments zoomed-out section, tests/bench descriptions).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01GL6nSnTyvVcmcWRQ48ePuT


## Commits
- 096ed52c Say titles on shapes zoomed out, and show no adornments there
- ef8d3a83 Fix a cover test's expectation and clamp a plate's corner radius
- 7304122d Covers: plain text sized by the shape, whole words, ink by surface
- 72b8f548 Keep the cover tests' words clear of other modules' ids

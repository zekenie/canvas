# PR #10: Make a selected or hovered subboard clearly read as such: stand its outline off its border
Branch claude/subboard-selection-contrast, opened 2026-10-04T02:33:25Z, merged 2026-10-04T02:41:29Z.
Made by a Claude Code session in the cloud; its transcript isn't on this machine, so this PR is the record of it.

## Description

## Not built, run or visually verified

This was written in a Linux container with no Swift toolchain and no macOS. Nothing was compiled, no test was run, and nothing was looked at on screen. The edits are small and were re-read by hand for Swift 6 / `-warnings-as-errors` problems and for the pixel arithmetic in the new tests, but please run `./test.sh` (SubboardsTests, and ideally the whole suite) and look at a selected and a hovered subboard in the app, light and dark, before merging.

## The problem

A selected subboard barely read as selected. The core strokes every outline (selection, hover, hint) a constant 1.5 view points in the accent color (2.5 and 60% for a hover), centered on the kind's `indicatorPath`. A subboard's `indicatorPath` was its card edge, and the card draws a 1.5-point `systemIndigo` border just inside that edge. So the accent line lay directly over the indigo border, close to it in both hue and width, and half of it was on top of the border. A hover was worse.

## The change

`SubboardDefinition.indicatorPath` is now the card's rounded edge grown by `SubboardStyle.outlineGap`, 4 view points, through the new `SubboardStyle.outline(of:zoom:)`. It is divided by `context.zoom`, so the gap is the same on screen at every zoom, and the corners grow with it (concentric, so the line is 4 points from the border all the way round). A gap of the canvas now sits between the indigo border and the accent line, as with a focus ring. Selection, hover and the arrow-target hint all use `indicatorPath`, so all of them get it.

The change is confined to the Subboards module (two source files). Nothing in the core, Selection or any other kind changed. Notes, frames, schema cards and arrows are untouched, and so are the proof-of-concept goldens. The pill (9 points above the top edge) stays clear of the ring (4 points).

Cost is unchanged: the same single rounded-rect path per outlined shape in view, plus a division. The core only asks for paths of shapes whose extent meets the view, so Select All stays cheap. Reading `context.zoom` is fine here: the "outline may not read the camera" rule is about geometries the shape index keeps, not about `indicatorPath`, which is asked for every frame (Frames already divides by `context.zoom` the same way in its `hitTest`).

## What I weighed and rejected

- **Draw the card's border differently when selected.** A render can't know the selection without breaking the rule that a definition sees other state only through `ShapeContext`, and it would redraw the card on every selection change.
- **A thicker or haloed ring for this kind.** The core strokes all outlines in one pass at one width. Per-kind widths would need a new core capability and extra passes in a hot path, which I couldn't compile or measure here.
- **A new generic core hook (an "outline standoff" capability).** More surface and risk than the per-kind `indicatorPath` that already exists for exactly this. Growing an arbitrary path by an offset in the core would also be path arithmetic per outlined shape per frame.
- **`CustomSkeletonOutline` so the standoff also holds zoomed out.** Rejected on cost: ⌘A zoomed out outlines every shape in view, and a custom skeleton outline is stroked per shape where a rect is filled as part of one ring path. The benchmark boards are a fifth subboards, and the budgets (a pan's frame with everything selected, 14 ms at 10%) have little room. So below 35% the outline stays the core's ring on the frame, over the half-point skeleton border, where it still reads as selected (accent, three times as wide as the indigo). The consequence is a small visible step at the 35% level change, as the pills and chips already have there.
- **A world-unit gap.** Simpler, but it scales with the card: about 1.4 points at 35%, merging with the line.

## Known side effect

Validation's ring grows from `registry.indicatorPath`, so a subboard with issues has its ring 4 points further out than before (7 points from the card instead of 3). When such a card is selected too, the accent line and the warning ring are now distinct. Fixing this separately would need a second outline hook; I judged it acceptable and noted it in the docs. No existing test pins a shipped subboard's ring (I grepped; ValidationTests uses fixtures).

## Tests (unrun)

- `SubboardsTests/CardTests.swift`: the outline's bounding box is the frame grown 4 points at 100%. Selected and hovered renders, compared with the unselected one, change nothing in the card, its border or the gap beside its straight right edge, and do change the column where the line should be. The old centered-on-the-edge look would fail the gap assertions.
- `SubboardsTests/SkeletonTests.swift`: zoomed out, the selection ring is on the frame edge and nothing stands off it. This pins the decision above.

The pixel ranges were worked out by hand (the card's corners are looked at 6 points in, since the concentric outline crosses the corner of the card's bounding box).

## Docs

CLAUDE.md (the Subboards entry) and `docs/plugin-system.md` (a new "Its outline" bullet under Subboards, the zoomed-out bullet, and a pointer from the `indicatorPath` table note) now describe the standoff, the zoomed-out behavior and the Validation consequence.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01TD9na29bnHDQjW8fv4Wytv


---
_Generated by [Claude Code](https://claude.ai/code/session_01TD9na29bnHDQjW8fv4Wytv)_

## Commits
- 9712f094 Stand a subboard's selection and hover outline off its edge
- fda0de65 Merge origin/main into claude/subboard-selection-contrast

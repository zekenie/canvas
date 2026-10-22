# PR #12: Stand every closed shape's outline off its edge, in the core
Branch claude/busy-lamport-pl68we, opened 2026-10-04T03:19:05Z, merged 2026-10-04T12:08:04Z.
Made by a Claude Code session in the cloud; its transcript isn't on this machine, so this PR is the record of it.

## Description

## Summary

#10 stood only a subboard's selection/hover/hint outline off its card edge, so it stopped looking like any other shape's (notes, frames and schema cards are outlined right on their edge). This makes that one generic, core-level behavior: **every closed shape's outline stands off its edge by the same 4 view points**, and the subboard-specific version is deleted.

**Nothing in this PR was built, run, or visually verified.** It was written in a Linux container with no Swift/macOS toolchain, so none of it has been compiled, no test has run (including the new ones), and I have not seen what it looks like. Please run `./build.sh && ./test.sh` (and `./build.sh bench`) and look at it in the app before merging. Expect to fix compile errors and a few pixel expectations.

## Design

- **Where:** the core's outline pass (`CanvasEditor+Drawing.swift`, `strokeOutlines`). The constant is `Style.outlineStandoff = 4` (view points, divided by the zoom, so constant on screen).
- **Closed shapes:** the kind's `indicatorPath` grown outward by the gap, corners concentric. A rounded rect of radius r becomes radius r + gap about the same centers; a plain rect gets corners of radius gap.
  - **Rect / rounded rect (every shipped box kind)** is added grown *directly*, with no path arithmetic. New `RoundedBox.of(path, matching: geometry.bounds)` (`Sources/Canvas/Rendering/OutlineStandoff.swift`) reads the `CGPath` in two passes over its end points, allocating nothing: it accepts the path if its straight edges lie on the sides of the kept bounds and leave the same room at both ends (that is the corner radius, whatever the corner curves are made of or where the path starts). Anything else returns nil.
  - **Any other closed outline** (polygons, ellipses, custom paths) falls back to path arithmetic. I extracted Validation's existing ring growth into the core as `CGPath.grownOutward(by:isClosed:)` and Validation now calls it. It is not cached in the stroke pass, so it is dearer per shape per frame. Debug builds count these (`editor.outlinesGrownByArithmetic`), and a test holds the shipped kinds to zero.
- **Open outlines (arrows, lines)** have no inside and are stroked on their own path, exactly as before (tldraw parity).
- **Zoomed out (< 35%, skeletons):** unchanged. Outlines stay the skeleton's filled ring on the frame, with no standoff and no extra cost. The cull area is not grown there. The shape being edited, drawn in full, is stood off like any full shape. Consequence: a selected shape's line steps out 4 pt as the zoom crosses 35%.
- **Cull area** grows by the standoff in full mode, so a ring at the edge of the view isn't clipped.
- **POC goldens:** new host-SPI knob `editor.outlineStandoff` (default `Style.outlineStandoff`; 0 = outline each shape on its own path as the POC did), next to `skeletonZoom`. `ParityTests` set it to 0 beside `skeletonZoom = 0` (not in `Replay.swift`, which the POC compiles). No fixture was touched. Documented in CLAUDE.md as a second intended deviation from the POC/tldraw. `editor.outlineGap` (public read) and `editor.outlinePath(of:)` (public) are what plugins use, so no plugin reads the number or the SPI.
- **Subboards:** `Sources/Subboards` is byte-identical to before #10 (`SubboardStyle.outlineGap`, `outline(of:zoom:)` and the `indicatorPath` change are gone).

## Judgment calls

- **Validation ring:** now 3 view points *outside* the standoff outline, i.e. 7 out of a closed shape's edge (same for every kind, never under a selected shape's accent line) and still 3 off an open shape's line. The ring cache is keyed on the standoff as well as the record/zoom. Zoomed out the ring is unchanged (3 out of the frame). Side effect: an unselected shape's warning ring now floats 7 pt off its edge instead of 3. The title pill (9 pt above the edge) is still clear, by about 1 pt of the ring.
- **Resize handles:** left exactly as they were: on the box edge/corners, hit areas unchanged, drawn over the outline. The 4 pt ring runs under the discs (corner and side-middle discs reach/overlap it). No redesign.
- **Multi-selection box (`Outlines.rects`):** stands off by the same gap (corner radius = gap) rather than staying on the edge. Otherwise it would sit inside the outermost shapes' rings. It coincides with the outermost rings along straight sides. Corners may not match exactly where an outer shape has a bigger corner radius.
- **Ports' "could end here" outlines** (`PortOverlay`) now go along `editor.outlinePath(of:)`, so they stay on the same line as a hover's (an existing test requires them to be pixel-identical).
- **Port dots, lock chip, pill:** untouched. Ring is at 3.25–4.75 pt; dots are 12 pt out, pill/lock row starts 9 pt out.
- **`EditorHarness` pins `outlineStandoff = 0`.** I couldn't audit ~60 test files' pixel expectations without running them, so the harness keeps outlines on the edge (as those tests were written). The standoff has its own tests that set 4 explicitly. This is a deliberate shortcut: to run the whole suite at the shipped value, delete that one line in `Tests/CanvasTesting/EditorHarness.swift` and fix what breaks. Editors not made through the harness (ShippedPlugins.makeEditor directly in CompositionTests) use the real default; I audited those and updated `ShippedTests` (ring now at y=93, 7 out).

## Tests / docs

- New `CanvasTests/OutlineTests.swift`: a box outline 4 pt off every side at 100% and 200% and never over the shape; concentric corners (plaque r=12 → 16, plain box → radius 4, single-pixel checks on the diagonal); hover = same line, hint = selection; diamond grown by arithmetic; open `Link` stroked on its own path; standoff 0 reproduces the edge outline; zoomed out unchanged; multi-select box; drawing offset; `outlinePath(of:)`/`outlineGap` (bounding boxes, `contains`). Debug counters check rect/rounded rect are not grown by arithmetic and a diamond is.
- `SubboardsTests` (CardTests, SkeletonTests): PR #10's tests rewritten against the core's rule (via `outlinePath(of:)`, standoff set explicitly; zoomed out stays on the frame).
- `ValidationTests`: new ring test at the shipped standoff (7 out at 100%/200%, clear of the outline line, open shape 3 out, follows the standoff/cache). Existing ring tests are unchanged and valid at the harness's 0.
- `CompositionTests`: `ShippedTests` ring position updated; new `OutlinesShippedTests` (note, frame, schema card, subboard in the app's own editor: 4 off the edge, corners concentric with each kind's radius, none grown by arithmetic; arrow on its line); `ParityTests` pin 0.
- CLAUDE.md (editor/outline entry, Subboards, Validation, Selection hover and handles, frame-cost entry, Ports, POC bullet, Arrows-follow-tldraw deviation, a new "For outlines" test bullet) and docs/plugin-system.md (`indicatorPath` table row and paragraph, Validation, Subboards bullets, Resizing, Drawing, Skeletons, and a new "Outlines" section) updated.

## Things to check first when you build

1. That `RoundedBox.of` recognizes the paths `CGPath(roundedRect:)` makes (it assumes only lines + cubic curves, tolerates a start mid-edge and any number of curves per corner that is a multiple of 4). If not, behavior is still correct (falls back to path arithmetic) but slow, and `outlinesGrownByArithmetic` assertions in `OutlineTests`/`OutlinesShippedTests` will fail, which is how you'd know.
2. The pixel tests with sub-pixel margins (notably the concentric-corner pixel `(39, 39)` unchanged).
3. `./build.sh bench` for the ⌘A frame budgets at 100%/35% with thousands selected (not measured).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01TD9na29bnHDQjW8fv4Wytv


---
_Generated by [Claude Code](https://claude.ai/code/session_01TD9na29bnHDQjW8fv4Wytv)_

## Commits
- af8d28db Stand every closed shape's outline off its edge, in the core

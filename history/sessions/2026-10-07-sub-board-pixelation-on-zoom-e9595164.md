# Sub-board pixelation on zoom

Claude Code session `e9595164-1f22-42d0-8c4f-b7a92d2e53c7`, 2026-10-07 13:10 to 2026-10-07 14:03 UTC, on `claude/sub-board-pixelation-zoom-6e4ef4`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-07 13:10] USER:
[image attached]

[2026-10-07 13:10] USER:
when you zoom way in on a sub-board it's pixelated

[2026-10-07 13:10] ASSISTANT:
I'm reading the board-preview code: the cause looks like the preview bitmap's fixed 256-pixel cap, stretched across a card that fills the screen when zoomed in.

[2026-10-07 13:13] ASSISTANT:
The pixelation comes from the preview's resolution cap. A subboard's preview is drawn once into a mask no bigger than 256 pixels on a side ([BoardPreviews.swift:274](Sources/Canvas/Rendering/BoardPreviews.swift:274), `Style.previewSide`). That mask is then stretched over whatever size the card has on screen. In your screenshot that's roughly 2,000 device pixels, so it's blown up about 8–9×, and each arrow's 1.5-pixel line becomes a blurry bar.

**Proposed fix: build the preview at the resolution it's drawn at.**
- **Sizes:** the mask comes in steps of 256, 512, 1024, 2048 and 4096 pixels. A card asks for the smallest step that covers its preview's size in device pixels, worked out from the zoom and the screen's scale.
- **While it rebuilds:** the card keeps drawing the preview it already has, slightly blurry, and the sharper one replaces it a few frames later. The build stays inside the existing 2 ms per frame. On a first build the size is chosen once the board's bounds are known, so Quick Look's pictures come out sharp straight away.
- **Zooming back out:** the card drops to a smaller step only when the one it has is more than two steps too fine. That stops a zoom sitting near a boundary from rebuilding over and over.
- **Memory:** kept previews get a total memory limit (about 64 MB) on top of the current limit of 64 previews. Like now, nothing the last frame drew is ever evicted.
- **Speed:** each step gets its own measured cost per shape, since filling a 4096 mask costs far more than a 256 one.
- **Lines:** they stay 1.5 pixels wide in the mask, so up close they look as thin as they do at 100%.
- **Tests and docs:** tests for the step choice, the replacement, the memory limit and sharpness up close. A benchmark of a card at 800% on Retina while it fills. Updates to `drawing.md`, `subboards.md` and the guide.

**What stays soft:** 4096 covers a default-size card at the maximum 800% zoom on Retina. A card you've enlarged, zoomed far in, still goes a little soft, though only about 2×, not 9×. Making it sharp at any size would need map-style tiles (only the part in view, at the detail needed), which is much more work. I'd leave that for later.

Shall I go ahead?

[2026-10-07 13:14] USER:
idk this feels like a silly problem. shouldnt' these be vectors rather than px?

[2026-10-07 13:14] ASSISTANT:
Mostly yes. Vectors are the better fix up close.

The previews are pixels because of cost. A preview draws every shape on another board, and a pixel mask makes that one image draw however many shapes the board holds. That's how ten cards of 10,000 shapes each stay within a frame zoomed out (the benchmark holds them to it).

That reason only applies while a card is small on screen. A card big enough to outgrow its mask fills much of the view, so there can't be many of them. Drawing one board's silhouettes as vectors costs about what drawing that board's skeletons does, which the benchmark already keeps within a frame at 10,000 shapes. The headless benchmarks don't measure the on-screen drawing path, so I'd also check that cost in the running app.

**Revised approach:** keep the mask for small cards, where it's already sharp. Once a card is bigger on screen than its mask, draw the board's silhouettes as kept vector paths, built once per board edit as the mask is now. They'd be sharp at any zoom, with no resolution steps or memory limit, and much simpler than what I proposed before.

Want me to plan that out?

[2026-10-07 13:16] USER:
yeah go

[2026-10-07 13:20] ASSISTANT:
Now the guide's section on board previews, which I'll need to update alongside the code.

[2026-10-07 13:20] ASSISTANT:
Now the code. Constants first.

[2026-10-07 13:21] ASSISTANT:
Now the preview itself: paths in cells, and the choice between mask and paths.

[2026-10-07 13:21] ASSISTANT:
Now the build: each shape also goes into its cell's paths as it's drawn into the mask.

[2026-10-07 13:23] ASSISTANT:
Builds, and the existing preview tests pass. Next I want before and after pictures of a card zoomed in, plus tests that hold the new behavior.

[2026-10-07 13:24] ASSISTANT:
Writing the CanvasTests cases now.

[2026-10-07 13:25] ASSISTANT:
Both new tests pass. To make sure they'd catch a regression, I'll turn off the paths branch temporarily and check that they fail.

[2026-10-07 13:26] ASSISTANT:
The tests fail without the paths and pass with them, and the file is restored. Next, the subboard test: a card drawn at 8× pixels per point.

[2026-10-07 13:26] ASSISTANT:
The control found no blur at all, so the edge probably isn't where I'm scanning. Printing the row to find it.

[2026-10-07 13:27] ASSISTANT:
`pixel` reads a `renderBitmap` at one pixel a point unless it's given the scale, so the test was reading the wrong corner of the image. Fixing that and removing the prints.

[2026-10-07 13:27] ASSISTANT:
Adding the benchmark right after the existing preview benchmark.

[2026-10-07 13:28] ASSISTANT:
In the debug build, paths draw faster than the masks: drawing an enlarged mask at high-quality interpolation is expensive. The real budgets are held in the release benchmark, so I'll run that next.

[2026-10-07 13:30] ASSISTANT:
The card's shadow varies by a few milliseconds from run to run, which swamps a frame-minus-frame comparison. Instead I'll time the preview's own drawing at 800% directly, which is precise.

[2026-10-07 13:31] ASSISTANT:
At 800% the preview takes about 1–1.5 ms to draw as paths, against 15 ms for the enlarged mask it replaces, and the benchmark now holds that. I'll flag the shadow as a separate task.

[2026-10-07 13:31] ASSISTANT:
Next, before and after pictures of a realistic card zoomed in, from a throwaway test that won't be committed.

[2026-10-07 13:33] ASSISTANT:
No image library here, so the throwaway test will compose the side-by-side pictures itself.

[2026-10-07 13:33] ASSISTANT:
I've sent you the before and after pictures. Now I'm removing the throwaway gallery test and updating the docs.

[2026-10-07 13:34] ASSISTANT:
Docs updated. Running the full test suite.

[2026-10-07 13:35] ASSISTANT:
One failure, in PortEdgesTests (dots on a stand-in), which looks unrelated to previews. I'll rerun it on its own to see the details and whether it's flaky.

[2026-10-07 13:36] ASSISTANT:
I'll commit my work, then run that test on the base commit to confirm the failure is already there.

[2026-10-07 13:36] GIT:
git add -A && git commit -q -F - <<'EOF'
Board previews drawn as paths when shown larger than their masks, so a subboard zoomed in stays sharp

The owner zoomed in on a subboard and saw its board's preview pixelated: the preview was a mask
of 256 pixels at most, stretched over whatever size the card had on screen, some 2,000 device
pixels there, its arrows blurred into bars a dozen pixels thick. First proposed was building the
mask at the resolution it's drawn at, in steps up to 4,096 pixels with a memory budget; the owner
asked "shouldn't these be vectors rather than px?", and they should, up close.

Measured first, since a preview draws every shape of another board: as paths a shape costs some 1
to 2 µs (fills alone about 1), so a 10,000-shape board drawn whole costs 25 to 30 ms, more than a
frame for one card, while the mask costs one image draw however many shapes. So both stay: the
mask wherever it isn't enlarged (zoomed out, and the build as before), and paths where it would
be, for the shapes in view, up to a frame's worth.

- Each preview keeps its silhouettes as paths beside the mask, built in the same pass: every shape
  its outline whatever its size (`Silhouettes` with no pixel to fall under), in cells of a grid
  over the board (at most 16 a side, some 32 shapes to a cell), so a frame draws only the cells
  meeting the clip, in one fill and one stroke. Lines are 1.5 device pixels wide, as the mask's
  are its pixels, so a preview looks the same either side of the switch, and as thin zoomed in.
- `Preview.draw` switches to the paths once the target is more device pixels than the mask has
  (on a 2× screen a default card at 100% already is), as long as the shapes in view number no
  more than what's left of the frame's 1,000 (`BoardPreviews.pathShapes`,
  `Style.previewPathShapes`, reset by `endFrame()`); past that it draws the mask, enlarged, as
  before, until zooming in leaves fewer of a big board's shapes in view.
- Not chosen: the mask in resolution steps (memory, and a rebuild per step while zooming, still
  soft past its cap); tiles at several levels, as a map draws (sharp for any board, but a tile
  system for one picture); paths always (a big board's frame).

At 800% on a 2× screen a preview now draws in 1 to 1.5 ms where the enlarged mask took 15; ten
cards of 100 shapes at 100% on a 2× screen draw their frame in 5.5 ms against 8.3 with masks. The
same bench shows a subboard card alone costs 21 to 24 ms at 800%, nearly all of it its shadow,
before and after this change; that's left for its own change.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -1 && git switch -q --detach 2df3c02c && TEST_FILTER="the far shape may start the connection" ./test.sh 2>&1 | grep -A3 "^── PortEdgesTests" | head -5; git switch -q claude/sub-board-pixelation-zoom-6e4ef4 && git log --oneline -1

===== [2026-10-07 13:36] commit written: Board previews drawn as paths when shown larger than their masks, so a subboard zoomed in stays sharp =====

[2026-10-07 13:37] ASSISTANT:
The PortEdgesTests failure is already on the base commit, so it isn't from this change. Checking whether main has moved since this branch was made.

[2026-10-07 13:37] ASSISTANT:
Main has one newer commit, which doesn't touch ports, so the failure is still there. I'll flag it as its own task.

[2026-10-07 13:37] ASSISTANT:
All other tests pass. Per your workflow, next is a code review of the branch before I report.

[2026-10-07 13:38] ASSISTANT:
Subboard previews are now sharp at any zoom. The change is committed on the branch, not on main yet. All tests pass except one in PortEdgesTests, which fails the same way on main's base commit. A code review found nothing to fix.

- **How it works:** once a card is bigger on screen than its 256-pixel preview, the board's shapes are drawn as vectors instead, and only the ones in view. That happens whenever you zoom in, and on a Retina screen even at 100%. Zoomed out, the cheap picture is still used. I sent you before and after pictures at 200% and 800%.
- **Cost:** pure vectors weren't affordable. A 10,000-shape board drawn whole as vectors took 25–30 ms, more than a frame for one card. So a frame draws at most 1,000 shapes as vectors across all cards. Past that, a big board shows the old blurry picture until you zoom in on part of it.
- **Speed:** at 800% the preview now draws in about 1–1.5 ms, against 15 ms for the stretched picture. The benchmark now holds both, but it runs offscreen, which draws differently from the screen. I haven't measured it in the running app.
- **Look:** arrows stay hairline, 1.5 device pixels at any zoom, as they are zoomed out. Up close they read lighter than the blurry bars did.

Two things I flagged as separate tasks:
- A subboard card at 800% takes about 21 ms a frame on its own, nearly all of it its shadow. That was already true before this change.
- The PortEdgesTests failure: two channel names come out in the opposite order in an error message.

Say the word and I'll land it.

[2026-10-07 14:03] USER:
land it

[2026-10-07 14:03] GIT:
git status --short && git log --oneline main..HEAD && git rebase main 2>&1 | tail -2 && git log --oneline -3 && git -C /Users/zekenie/code/native-canvas status --short | head && git -C /Users/zekenie/code/native-canvas branch --show-current

[2026-10-07 14:03] ASSISTANT:
It's on main as d1f635ab, and the worktree and branch are removed.

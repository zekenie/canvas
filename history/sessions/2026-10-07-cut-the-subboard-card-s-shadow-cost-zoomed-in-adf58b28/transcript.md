# Cut the subboard card's shadow cost zoomed in

Claude Code session `adf58b28-0536-4408-871e-017905e41875`, 2026-10-07 14:03 to 2026-10-07 15:07 UTC, on `claude/epic-fermi-f0f51b`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-07 14:03] USER:
In the native-canvas repo (Infinite Canvas, macOS AppKit), a subboard card zoomed far in costs more than a frame to draw, and nearly all of it is the card's shadow.

What was found: a benchmark (Tests/BenchmarkTests/Benchmarks.swift, the test "previews shown larger than their masks are drawn as paths…", added on the branch claude/sub-board-pixelation-zoom-6e4ef4; run it with `TEST_FILTER="drawn as paths" ./build.sh bench`) draws one subboard 2400 × 1600 world units at 800% on a 2× bitmap, 1200 × 800 view points. The card with nothing on its board takes 21–24 ms a frame. With `context.fillWithShadow(path, SubboardStyle.cardFill)` in `Sources/Subboards/SubboardDefinition.swift` replaced by a plain fill, the same frame takes 0.5 ms. `RenderContext.fillWithShadow` (Sources/Canvas/Shapes/ShapeDefinition.swift) scales the blur by the zoom (`blur: 6 * zoom`), so at 800% it's a 48-point (96-pixel) blur over a shape bigger than the view.

Caveat: benchmarks and headless windows replay the display list on the CPU. On screen, Core Animation renders it on the GPU, so measure on screen before deciding (see the project's notes on an on-screen frame probe: a self-driving copy of the app with its own bundle id, on an awake, unlocked screen; ask the user before a window pops up). Other kinds use `fillWithShadow` too (sticky notes, schema cards), so check whether the cost is general to any shape bigger than the view.

Possible directions: draw only the part of the shadow in view (the shadow of a shape whose edges are all off screen is invisible), skip the shadow when the shape's edges are out of view, or cap the blur on screen. Read CLAUDE.md and .claude/rules/drawing.md and benchmarks.md first, follow the repo's rules (work in a worktree, plan before executing, ask the user before landing), and hold the result with a benchmark.

[2026-10-07 14:03] ASSISTANT:
Reading the drawing rules and memories; main now has the benchmark (d1f635ab), so I'm bringing this worktree up to date with it before looking at the shadow code.

[2026-10-07 14:04] GIT:
git log --oneline -1 origin/main; git merge-base --is-ancestor HEAD main && echo "HEAD is ancestor of main"

[2026-10-07 14:04] GIT:
git merge --ff-only main 2>&1 | tail -3; git log --oneline -1

[2026-10-07 14:04] ASSISTANT:
Now the shadow code and the benchmark.

[2026-10-07 14:05] ASSISTANT:
Reproducing the cost now: checking the card fills are opaque (so the shadow only shows outside a shape), then timing shadow variants in a standalone Core Graphics script.

[2026-10-07 14:10] ASK:
Q: Can I open a probe window on your screen for about 40 seconds? It's a 1200 × 800 window titled "Shadow probe" that floats on top without taking focus, draws the zoomed-in card in 15 variants and then quits by itself. It measures what the shadow costs on the GPU, which the benchmark can't see.
   options: Yes, run it now: The window opens right away for ~40 s. Leave the Mac awake and unlocked until it closes.; Not now: I'll plan from the CPU numbers alone and mark the on-screen cost as unmeasured.

[2026-10-07 14:18] ANSWER:
Your questions have been answered: "Can I open a probe window on your screen for about 40 seconds? It's a 1200 × 800 window titled "Shadow probe" that floats on top without taking focus, draws the zoomed-in card in 15 variants and then quits by itself. It measures what the shadow costs on the GPU, which the benchmark can't see."="Yes, run it now". You can now continue with these answers in mind.

[2026-10-07 14:20] ASSISTANT:
I measured on screen with your OK. On screen the shadow costs nothing you'd notice. The 21–24 ms only shows up when Core Graphics replays the drawing on the CPU, which is what the benchmark and the headless tests do.

**On screen** (your 60 Hz Retina display, 1200 × 800 window, 800%): the card held 60 fps with no dropped frames in all three positions: covering the view, with an edge in view, and with a corner in view. With the shadow, the process used 0.6–0.7 ms of CPU a frame.

**On the CPU replay:** the cost grows with how much of the shape is in view, because rounded corners miss Core Graphics' fast path for plain rectangles. It applies to every kind with a shadow:
- A note or schema card at 800% costs the same ~21 ms as the card.
- A note at 400%, all of it in view, costs ~9 ms.
- At 100% a note costs 0.3 ms.

**Ruled out:**
- Drawing the shadow in tiles, or clipping its path to the view: both cut the CPU-replay cost but cost more on screen (an extra 0.5–0.7 ms on the main thread, or 2–2.7 ms of CPU a frame).
- Capping the blur: it changes how the shadow looks.

**Plan:**
- **The change:** `fillWithShadow` (`Sources/Canvas/Shapes/ShapeDefinition.swift`) skips the shadow when the visible area lies entirely inside the shape and the fill is opaque. The fill then covers every pixel the shadow could reach, so the picture stays identical. A shape smaller than the view pays one rectangle comparison; a bigger one pays a path subtraction of about 3 µs. Notes, schema cards and subboards all go through this function, so they all get it.
- **Effect:** the benchmark's zoomed-in card drops from ~22 ms to ~0.5 ms. With an edge in view, the CPU replay still costs ~11 ms (nothing on screen), so the benchmark reports that case rather than holding it to a budget.
- **Benchmark:** hold the card and a note, each at 800% centred on its middle, to a budget, and report the edge case.
- **Tests:** compare frames against a debug switch that always draws the shadow: view inside the shape, one pixel from its edge, across an edge, and with a translucent fill.
- **Docs:** update `drawing.md`, `benchmarks.md` and the guide.

Should I go ahead with this? The alternative is no code change, only recording in the rules that the cost exists on the CPU replay alone.

[2026-10-07 14:33] USER:
go ahead

[2026-10-07 14:34] ASSISTANT:
Implementing now: the covered check in `fillWithShadow`, with a debug switch and counter for the tests. Checking the deployment target, since `CGPath.subtracting` needs macOS 13.

[2026-10-07 14:36] ASSISTANT:
Writing the shadow type and wiring it through the render context.

[2026-10-07 14:37] ASSISTANT:
The change and its tests are written; running the new Shadows suite now.

[2026-10-07 14:39] ASSISTANT:
At 2× my reads went by pixel, not view point (`pixel(_:at:)` needs `scale:` for `renderBitmap` at 2×); fixing the test.

[2026-10-07 14:40] ASSISTANT:
Passing. A quick mutation check that the tests catch a wrong skip (bbox-only test, no alpha check):

[2026-10-07 14:40] ASSISTANT:
The tests catch both mutations (the translucent fill and the notch), and the file is restored. Now the benchmark: reading the bench helpers and the empty-frame budget.

[2026-10-07 14:42] ASSISTANT:
The subboard and note frames dropped from ~21 ms to 0.4–0.5 ms. The schema card's frame still costs 15 ms; I suspect its height is derived from its text, so it doesn't fill the view. Checking.

[2026-10-07 14:42] ASSISTANT:
A one-line description makes the card about 52 world units tall, so its edges are in view at 800%. I'll give it a description long enough to fill the view.

[2026-10-07 14:42] ASSISTANT:
All three hold now: 0.4–0.9 ms against a 3 ms budget. Getting the "before" numbers with the skip turned off temporarily:

[2026-10-07 14:43] ASSISTANT:
Before/after on the CPU replay: 23.8 / 24.6 / 26.4 ms → 0.49 / 0.40 / 0.86 ms (subboard, note, schema card). Running the full test suite in the background while I update the docs.

[2026-10-07 14:44] ASSISTANT:
I hadn't measured GPU time, only that frames held 60 fps, so I'm replacing "a fraction of a frame" with what was measured:

[2026-10-07 14:44] ASSISTANT:
The source diff reads right. Waiting on the full test suite; once it finishes I'll run the full benchmark on its own, so the two don't compete for CPU.

[2026-10-07 14:45] ASSISTANT:
It fails every time. Checking whether it fails on main too, in a scratch clone:

[2026-10-07 14:46] ASSISTANT:
While the benchmark runs, committing on the branch, then the code review.

[2026-10-07 14:46] GIT:
git add -A && git status --short && git commit -q -F - <<'EOF'
A shape's shadow is left out where its fill hides it, so a shape zoomed in past the view costs a fill, not a blur of the view

Zoomed in on a subboard card at 800%, the bench found the card alone took 21 to 24 ms a frame,
nearly all of it its shadow: `fillWithShadow` scales the blur by the zoom, 48 points there, and
Core Graphics blurs a rounded shape (a plain rect has a fast path) over all of it in view. The
owner asked for it to be measured on screen before deciding, since the bench and headless windows
replay the display list on the CPU and Core Animation renders it on the GPU. On screen (a
standalone probe, 1200 × 800 at 800% on a 60 Hz Retina display) the shadow held 60 fps with no
frame dropped, the card covering the view, an edge in view or a corner, some 0.7 ms of the
process's CPU a frame: the cost is the CPU replay's. Every shadowed kind pays it alike: a note or a
schema card at 800% took some 21 ms, a note at 400% wholly in view 9, one at 100% 0.3.

- `RenderContext.fillWithShadow` goes through the core's `ShapeShadows`, which leaves the shadow
  out where the fill hides all of it: an opaque color (no pattern) whose path holds the context's
  clip box grown by a device pixel (an edge's antialiasing). A comparison of rects comes first, so
  only a shape bigger than the view does path arithmetic (`CGPath.subtracting`, a few µs). The
  picture is the same byte for byte; the blur is `Style.shapeShadowBlur`.
- At 800% on its middle, a 2× bitmap: a subboard 23.8 → 0.49 ms, a note 24.6 → 0.40, a schema card
  of six lines 26.4 → 0.86, held to `Budget.coveredShape` (3 ms). With an edge or a corner in view
  the shadow is still blurred on the CPU (8 to 15 ms), reported.
- Not chosen: the shadow drawn in tiles near the edges, or its path clipped to the view (both cut
  the CPU cost with an edge in view, but cost more on screen: 0.5 to 0.7 ms more of the main thread,
  or 2 to 2.7 ms more of the process's CPU a frame); the blur capped (changes the look).
- CanvasTests' Shadows compare each frame byte for byte with every shadow drawn (debug builds'
  `editor.shadowsAlwaysDrawn`, and `editor.shadowsSkipped`): left out with the view inside the
  shape; drawn with its edge on the view's edge or in view, a translucent fill, an L whose bounds
  hold the view but whose notch is in it, a shape shaken onto the view; and left out in a frame
  clipped inside the shape though its edge is in view.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -1

===== [2026-10-07 14:46] commit written: A shape's shadow is left out where its fill hides it, so a shape zoomed in past the view costs a fill, not a blur of the view =====

[2026-10-07 14:48] ASSISTANT:
The review found nothing that changes how the app draws today. I'm fixing what it flagged, after checking the full benchmark results.

[2026-10-07 14:48] ASSISTANT:
All 66 benchmarks passed their budgets, including the 10,000-shape frames that now run the extra check on every shadowed shape. Fixing the review's findings:

[2026-10-07 14:49] ASSISTANT:
Now the test-side cleanups: `renderBitmap` takes an optional clip, which replaces the test's own bitmap setup, and the results become a small struct.

[2026-10-07 14:50] ASSISTANT:
Shadows suite passes. Updating the docs for the new `clip` parameter and the alpha caveat, then rerunning the full suite and the covered-shape benchmark:

[2026-10-07 14:50] ASSISTANT:
Only the PortEdges test fails, and main has already fixed it. Rerunning the covered-shape benchmark after the reorder:

[2026-10-07 14:51] GIT:
git add -A && git commit -q -F - <<'EOF'
Fix what reviewing the shadow change found

- The cover test compares the path's bounds with the clip box before anything else, so a shape
  smaller than the view pays a comparison of rects and nothing more; the device pixel it grows the
  box by is a pixel's box in user space (`convertToUserSpace(CGRect)`), right however the transform
  turns.
- `fillWithShadow`'s contract says the fill is taken to paint its color as it is (the context's
  alpha and blend mode can't be read back), and `Style.shapeShadowBlur` says its units are the
  context's base space times the zoom: 6 world units on screen, half that in a 2× bitmap.
- `renderBitmap` takes a clip, as AppKit's dirty rect clips a view; the Shadows suite's clipped
  frame draws through it, and its results are a struct with `shadowed(at:)`.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline main..HEAD

[2026-10-07 14:51] ASSISTANT:
Shapes zoomed in past the view's edges now skip the shadow their fill hides. It's committed on this branch and reviewed, and it isn't on main until you say so.

- **Result:** the frame zoomed in to 800% on a shape's middle went from about 24 ms to under 1 ms on the CPU replay:

  | Shape | Before | After |
  |---|---|---|
  | Subboard | 23.8 ms | 0.54 ms |
  | Sticky note | 24.6 ms | 0.37 ms |
  | Schema card | 26.4 ms | 0.77 ms |

  The picture is identical: the tests compare each frame byte for byte with one where every shadow is drawn.
- **Where:** `fillWithShadow` (in `Sources/Canvas/Rendering/ShapeShadows.swift`), so notes, schema cards and subboards all get it. A shape smaller than the view pays one rectangle comparison.
- **Benchmark:** a new benchmark holds the three shapes on their middles to a 3 ms budget. The full benchmark run passed all 66 of its budgets.
- **Not fixed:** with an edge or a corner in view, the CPU replay still costs 6–12 ms. The benchmark reports this rather than holding it, as planned; on screen it held 60 fps.
- **Review:** it raised 7 points and I fixed 6. The most useful was that a render setting the context's alpha or blend mode before the fill would lose a shadow that should show through. No current kind does that, and the contract now says so. The one I skipped was holding the edge case to a budget.
- **Tests:** everything passes except one PortEdges test, which also fails on this branch's base without my change and passes on main (fixed in 7710635b). It goes away when I rebase.
- **Not checked:** I haven't run the real app on screen with the change. The on-screen measurement used the standalone probe window, so the in-app result is unmeasured.

Should I land it on main?

[2026-10-07 15:07] USER:
land

[2026-10-07 15:07] GIT:
git status --porcelain && git reset -q --soft $(git merge-base HEAD main) && git commit -q -F - <<'EOF'
A shape's shadow is left out where its fill hides it, so a shape zoomed in past the view costs a fill, not a blur of the view

Zoomed in on a subboard card at 800%, the bench found the card alone took 21 to 24 ms a frame,
nearly all of it its shadow: `fillWithShadow` scales the blur by the zoom, 48 points there, and
Core Graphics blurs a rounded shape (a plain rect has a fast path) over all of it in view. The
owner asked for it to be measured on screen before deciding, since the bench and headless windows
replay the display list on the CPU and Core Animation renders it on the GPU. On screen (a
standalone probe, 1200 × 800 at 800% on a 60 Hz Retina display) the shadow held 60 fps with no
frame dropped, the card covering the view, an edge in view or a corner, some 0.7 ms of the
process's CPU a frame: the cost is the CPU replay's. Every shadowed kind pays it alike: a note or a
schema card at 800% took some 21 ms, a note at 400% wholly in view 9, one at 100% 0.3.

- `RenderContext.fillWithShadow` goes through the core's `ShapeShadows`, which leaves the shadow
  out where the fill hides all of it: an opaque color (no pattern) whose path holds the context's
  clip box grown by a device pixel's box in user space (an edge's antialiasing). The path's bounds
  are compared with the clip box first, so a shape smaller than the view pays a comparison of
  rects and nothing more, and only one bigger does path arithmetic (`CGPath.subtracting`, a few
  µs). The picture is the same byte for byte. The fill is taken to paint its color as it is: the
  context's alpha and blend mode can't be read back, so the contract says to leave them as the
  fresh state has them, as every shipped render does. The blur is `Style.shapeShadowBlur`, in the
  context's base space times the zoom (6 world units on screen, half that in a 2× bitmap).
- At 800% on its middle, a 2× bitmap: a subboard 23.8 → 0.54 ms, a note 24.6 → 0.37, a schema card
  of six lines 26.4 → 0.77, held to `Budget.coveredShape` (3 ms). With an edge or a corner in view
  the shadow is still blurred on the CPU (6 to 12 ms), reported.
- Not chosen: the shadow drawn in tiles near the edges, or its path clipped to the view (both cut
  the CPU cost with an edge in view, but cost more on screen: 0.5 to 0.7 ms more of the main thread,
  or 2 to 2.7 ms more of the process's CPU a frame); the blur capped (changes the look).
- CanvasTests' Shadows compare each frame byte for byte with every shadow drawn (debug builds'
  `editor.shadowsAlwaysDrawn`, and `editor.shadowsSkipped`): left out with the view inside the
  shape; drawn with its edge on the view's edge or in view, a translucent fill, an L whose bounds
  hold the view but whose notch is in it, a shape shaken onto the view; and left out in a frame
  clipped inside the shape though its edge is in view (`renderBitmap` takes a clip, as AppKit's
  dirty rect clips a view).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -1 && git log --oneline -3 main && git rebase main 2>&1 | tail -3

[2026-10-07 15:07] ASSISTANT:
It's on main as 831a8581, and the worktree and its branch are removed.

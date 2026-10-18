# Quick Look board preview on Mac

Claude Code session `8c4d7d7e-a104-4668-ad1d-25fe2c06f399`, 2026-10-05 13:18 to 2026-10-05 14:46 UTC, on `claude/quick-look-board-preview-74527e`, `main`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-05 13:18] USER:
i'd like to be able to quick look on mac and see the top level board in some fashion

[2026-10-05 13:21] ASSISTANT:
I'm reading how the app builds its bundle and draws boards, so I can work out how a Quick Look extension would fit. I'll bring you a plan before writing any code.

[2026-10-05 13:21] USER (sent mid-turn):
you don't need to present me with a plan make reasonable decisions on your own

[2026-10-05 13:24] ASSISTANT:
The test extension compiles. Next I'll bundle it, sign it ad-hoc, and register it to see whether Quick Look picks it up.

[2026-10-05 13:24] ASSISTANT:
The thumbnail half works: Quick Look ran the ad-hoc-signed extension and drew its test square. Next I'm checking the full-size preview, which crashed `qlmanage`.

[2026-10-05 13:25] ASSISTANT:
The full-size preview crash appears to come from `qlmanage` itself. I'm checking that by running it against one of Apple's own extensions of the same kind.

[2026-10-05 13:29] ASSISTANT:
Opening the app registers its extensions, so `./build.sh && open build/InfiniteCanvas.app` will set up Quick Look with no extra step. I'm removing the test bundle's registration now.

[2026-10-05 13:29] ASSISTANT:
Next I'm reading the testing rules and the guide's module-graph section, since this adds a new kind of module and a new layer.

[2026-10-05 13:29] ASSISTANT:
Next: the test targets and their entry points, so the new tests follow the existing pattern.

[2026-10-05 13:32] ASSISTANT:
The dot grid coarsens at any zoom, so fitting below 10% is safe there. Next I'm checking whether the editor clamps a camera set outside the app's zoom range.

[2026-10-05 13:32] ASSISTANT:
The editor doesn't clamp a camera's zoom. I'm checking which bitmap formats the dot grid supports, so the picture's bitmap can be one it handles.

[2026-10-05 13:34] ASSISTANT:
Next I'm checking how `test.sh` picks which executables to run, since the extension will be a new kind of executable.

[2026-10-05 13:34] ASSISTANT:
I have what I need. Writing the code now, starting with a small addition to `Camera`'s fit so a picture can zoom out past the canvas's 10% floor.

[2026-10-05 13:36] ASSISTANT:
Now the core of it: `BoardPicture` in CanvasUI, which draws a board file's root board fitted to a size, with the editor's own drawing.

[2026-10-05 13:36] ASSISTANT:
Now the extension module: one executable with a preview provider and a thumbnail provider, both drawing through `BoardPicture`.

[2026-10-05 13:37] ASSISTANT:
Now registering the module in `Package.swift` under a new `appex` layer.

[2026-10-05 13:37] ASSISTANT:
Now `build.sh`: the new layer, the extension's entry point at link time, and bundling and ad-hoc signing the two extensions.

[2026-10-05 13:38] ASSISTANT:
Now a first audit and build.

[2026-10-05 13:39] ASSISTANT:
`QLThumbnailProvider` has no async variant to override (its `NS_SWIFT_NAME` blocks the import), so the thumbnail provider will hop to the main thread synchronously instead.

[2026-10-05 13:39] ASSISTANT:
It builds. I'm checking the bundle's layout and signatures, and that a second build changes nothing.

[2026-10-05 13:40] ASSISTANT:
A second build changes nothing in the bundle. Next I'll register this build and generate a real thumbnail through Quick Look, using a board file from the test fixtures.

[2026-10-05 13:40] ASSISTANT:
Those thumbnails came from macOS's built-in text previewer, not our extension, so Quick Look never chose it. I'm checking what type the system assigns to `.canvasboard` files.

[2026-10-05 13:40] ASSISTANT:
The type resolves correctly, so Quick Look may have chosen our extension and fallen back after it failed. I'm checking the logs and crash reports for the extension process.

[2026-10-05 13:41] ASSISTANT:
The extension never launched: Quick Look picked the text generator without trying it. I'm asking Quick Look which generator it maps to this type.

[2026-10-05 13:41] ASSISTANT:
Still the text thumbnails, and the extension still didn't launch. I'm searching Quick Look's own logs for why it passed over our extension.

[2026-10-05 13:41] ASSISTANT:
Other sessions are running tests, and some copy of the app is open. I'm checking which copy is running and what Quick Look's thumbnail process logged during my run.

[2026-10-05 13:42] ASSISTANT:
The re-signing failed: `codesign` can't read entitlements from a pipe. Redoing it with a file.

[2026-10-05 13:42] ASSISTANT:
Still not picked up, even under a unique ID. Next I'll move the test copy out of the hidden folder.

[2026-10-05 13:44] ASSISTANT:
Both binaries record SDK 27.0, so that isn't it. I'm re-registering the earlier test bundle exactly as before, to see whether it's still discovered now.

[2026-10-05 13:45] ASSISTANT:
Not case: the test bundle's type is reported lowercase too, and it works. I'm reading the thumbnail agent's log from the successful test-bundle run to see how it found that extension.

[2026-10-05 13:46] ASSISTANT:
A twin declaration doesn't break the test bundle's thumbnail. Next I'll remove the type declaration from the test bundle's own app, leaving only the twin to declare it.

[2026-10-05 13:48] ASSISTANT:
Quick Look launched our thumbnail extension this time. Here's what it drew:

[2026-10-05 13:48] ASSISTANT:
Now temporary logging in the preview provider. It comes out before committing.

[2026-10-05 13:51] ASSISTANT:
That scratch build still exists. Next I'll count every registered copy of the app and check which still exist on disk.

[2026-10-05 13:53] ASSISTANT:
Now the tests. First, how CanvasTests' fixture kind draws its board's preview, so mine can follow it.

[2026-10-05 13:53] ASSISTANT:
Writing the CanvasUITests suite for `BoardPicture`. It covers sizing, fitting and centering, orientation, zooming out past 10%, a card's preview built in one pass, dark mode, and reading file data.

[2026-10-05 13:54] ASSISTANT:
Writing the CanvasUITests suite:

[2026-10-05 13:55] ASSISTANT:
Registering the suite in CanvasUITests' entry point, then writing the shipped-kinds suite.

[2026-10-05 13:56] ASSISTANT:
I have the fixture's layout. Writing the shipped-kinds suite in CompositionTests: the welcome board's notes, a subboard card's preview built in one pass, and a saved fixture file in an older format.

[2026-10-05 13:56] ASSISTANT:
Loosening the canvas checks in the CanvasUITests suite so a sample that lands on a grid dot still counts as canvas:

[2026-10-05 13:57] ASSISTANT:
All 10 new tests pass: 7 in CanvasUITests and 3 in CompositionTests. To make sure the preview tests catch what they claim, I'll briefly remove the second draw and confirm they fail.

[2026-10-05 13:58] ASSISTANT:
Writing the Quick Look topic file:

[2026-10-05 13:59] WRITE .claude/worktrees/quick-look-board-preview-74527e/.claude/rules/quick-look.md:
---
paths:
  - "Sources/CanvasQuickLook/**"
  - "Sources/CanvasUI/BoardPicture.swift"
  - "Tests/CanvasUITests/BoardPictureTests.swift"
  - "Tests/CompositionTests/PicturesShippedTests.swift"
---

# Quick Look

A board file's Quick Look preview (space in the Finder) and its thumbnail (its icon): `BoardPicture`, the app's Quick Look extension, how it's built, signed and registered, and how to check it.

Related: [drawing](drawing.md), [boards on disk](boards-on-disk.md), [build](build.md) ([every topic](../../CLAUDE.md#map)).

In the guide, `docs/plugin-system.md`: [Boards on disk](../../docs/plugin-system.md#boards-on-disk).

## Architecture

- `BoardPicture` (CanvasUI) is a picture of a file's root board, drawn by the editor's own drawing (`editor.draw`, host API) with nothing selected, so a kind needs nothing for it: it reads the file as the app opens one (`BoardCodec`, then `replaceFile`), fits the whole board into the picture, centered, with `inset` of margin in all (a first visit's 64), no closer than `maxZoom` (1) and as far out as it takes (past the canvas's 10%, down to 1%, `Camera(fitting:in:inset:minZoom:maxZoom:)`), and builds every board preview its cards ask for in the one picture: it draws, and if any was asked for, draws again, which builds them first (`PictureStyle.previewBudget`, 5 s for all). Under 35% its shapes are skeletons, as on the canvas. `size(within:minimum:)` is the size that shows the board at `maxZoom`, or as close as fits the limit; `draw(in:siz […4017 more chars]

[2026-10-05 13:59] ASSISTANT:
Now the map line in CLAUDE.md, and the build, drawing and testing topics:

[2026-10-05 13:59] ASSISTANT:
Now the guide (the layer table, the CanvasUI mentions and a Quick Look paragraph) and the README:

[2026-10-05 13:59] ASSISTANT:
Re-wrapping the one guide line that ran long:

[2026-10-05 14:00] ASSISTANT:
No PIL, so the gallery test will lay out the comparison images itself with AppKit. First, today's "before": the thumbnail Quick Look makes of a real `.canvasboard` now.

[2026-10-05 14:00] ASSISTANT:
Writing the throwaway gallery test. It renders with the extension's settings: previews in dark at 2×, and 256-point thumbnails in light.

[2026-10-05 14:01] ASSISTANT:
Sent. Now the full test suite (it builds every module in debug, the extension included):

[2026-10-05 14:04] ASSISTANT:
The full test suite finished (exit 0). Checking its log:

[2026-10-05 14:07] ASSISTANT:
SIGTERM was ignored. I'll use SIGKILL: the agent only holds in-memory state, its on-disk thumbnail cache is crash-safe, and launchd relaunches it on the next request (like restarting Finder).

[2026-10-05 14:10] ASSISTANT:
Measuring a no-op build, since signing now happens on every app build:

[2026-10-05 14:11] ASSISTANT:
The shell choked on a glob, so nothing was cleaned. Redoing it more simply:

[2026-10-05 14:11] ASSISTANT:
Test bundles are all unregistered and deleted. Only this worktree's real build stays registered until landing.

Now the commit. Checking the commit-message convention first:

[2026-10-05 14:11] GIT:
git add -A && git status --short && git commit -q -F - <<'EOF'
Show a board file in Quick Look: its top board, as the app draws it

The user wanted to Quick Look a .canvasboard in the Finder and see its top
board "in some fashion"; Quick Look showed the file's JSON. The app now
carries a Quick Look preview extension (space in the Finder) and a thumbnail
extension (the Finder's icons). Both draw the root board with the app's own
drawing: CanvasUI's new BoardPicture reads the file as the app opens one,
fits the whole board in (a first visit's margin, no closer than 100%, and past
the canvas's 10%, down to 1%, so a sprawling board still shows whole), builds
the previews its subboard cards show in the one frame, and draws it with the
editor, skeletons and all, so no kind needs anything for it. Camera's fit
takes a minZoom for that.

Decided here, the user having left the decisions to me: the real render
rather than the minimap's silhouettes, since Quick Look is for seeing what's
in a file and the editor's level of detail already keeps a big board cheap; a
picture (a data-based preview) rather than a live, pannable canvas in the
panel. The preview is at least the app's smallest canvas and at most
1600 x 1200, in the system's appearance, as the app is; thumbnails fill the
icon and are always light, since Quick Look keeps a thumbnail across an
appearance switch; an empty board has none, so it keeps the document icon.
The preview is a PNG at the screen's scale that gives its size in points:
Quick Look makes a reply's own context one pixel to a point.

The extension is a new layer, appex (foundation, ui, composition): one
executable in two bundles, one per extension point, linked to start in
NSExtensionMain and signed ad hoc with the sandbox entitlement Quick Look
requires. build.sh writes their Info.plists and signs a copy, so a build
that changed nothing replaces nothing; the app stays unsigned. Opening the
app registers them.

Learned on this Mac, and in the topic file: Quick Look's thumbnail agent
settles a type's thumbnailer the first time it's asked and keeps it until
it restarts, so a Mac that showed boards as JSON goes on doing so after the
app is opened, until a logout. qlmanage can't host a data-based preview
extension here (it throws for Apple's own too), so the preview was checked
through a QLPreviewView host.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -2

===== [2026-10-05 14:11] commit written: Show a board file in Quick Look: its top board, as the app draws it =====

[2026-10-05 14:11] ASSISTANT:
Committed on the branch as `3b2c680`. Next is the code review your workflow calls for before landing.

[2026-10-05 14:14] ASSISTANT:
No global CLAUDE.md, and nothing parses the build's closing message. A couple more cross-file checks: references to `Camera`'s fit initializer elsewhere, and the extension bundles' display names.

[2026-10-05 14:14] ASSISTANT:
The guide names `Camera(fitting:in:inset:maxZoom:)` in two places, which is now a stale name. One more check, on what the thumbnail request's `minimumSize` asks of a reply:

[2026-10-05 14:17] ASSISTANT:
It builds. Everything recompiled because Canvas gained the host API. That API also gets a mention in the editor topic file, beside Zoom to Fit:

[2026-10-05 14:17] ASSISTANT:
Running the full suite again, since Canvas changed:

[2026-10-05 14:17] ASSISTANT:
While that runs, a check that the rebuilt extension still makes the real `.canvasboard` thumbnail through Quick Look:

[2026-10-05 14:18] ASSISTANT:
The rebuilt extension still produces the real-type thumbnail. Updating the review with each finding's outcome:

[2026-10-05 14:18] ASSISTANT:
Outcomes recorded. Once the suite passes I'll fold the fixes into the branch's single commit, so it lands as one. Waiting on the run.

[2026-10-05 14:18] ASSISTANT:
The full test suite is re-running after the review fixes. Once it passes, I'll fold the fixes into the branch's single commit and send the summary.

[2026-10-05 14:20] NOTICE:
background task completed: Background command "Rerun the full test suite in background" completed (exit code 0)

[2026-10-05 14:20] ASSISTANT:
Everything passes: 44 test executables, 0 failures. Folding the review fixes into the branch's one commit, and noting the new host API in its message:

[2026-10-05 14:20] GIT:
git add -A && git commit -q --amend -F - <<'EOF'
Show a board file in Quick Look: its top board, as the app draws it

The user wanted to Quick Look a .canvasboard in the Finder and see its top
board "in some fashion"; Quick Look showed the file's JSON. The app now
carries a Quick Look preview extension (space in the Finder) and a thumbnail
extension (the Finder's icons). Both draw the root board with the app's own
drawing: CanvasUI's new BoardPicture reads the file as the app opens one,
fits the whole board in (a first visit's margin, no closer than 100%, and past
the canvas's 10%, down to 1%, so a sprawling board still shows whole), builds
the previews its subboard cards show in the one frame, and draws it with the
editor, skeletons and all, so no kind needs anything for it. Camera's fit
takes a minZoom for that, and the core lends its first visit's margin as host
API (CanvasEditor.firstVisitInset) rather than the picture copying the number.

Decided here, the user having left the decisions to me: the real render
rather than the minimap's silhouettes, since Quick Look is for seeing what's
in a file and the editor's level of detail already keeps a big board cheap; a
picture (a data-based preview) rather than a live, pannable canvas in the
panel. The preview is at least 480 x 320 and at most 1600 x 1200, in the
system's appearance, as the app is; thumbnails fill what Quick Look asks for,
no smaller than its minimum either way, and are always light, since Quick
Look keeps a thumbnail across an appearance switch; an empty board has none,
so it keeps the document icon. The preview is a PNG at the screen's scale
that gives its size in points: Quick Look makes a reply's own context one
pixel to a point.

The extension is a new layer, appex (foundation, ui, composition): one
executable in two bundles, one per extension point, linked to start in
NSExtensionMain and signed ad hoc with the sandbox entitlement Quick Look
requires. build.sh writes their Info.plists and signs a copy, so a build
that changed nothing replaces nothing; the app stays unsigned. Opening the
app registers them.

Learned on this Mac, and in the topic file: Quick Look's thumbnail agent
settles a type's thumbnailer the first time it's asked and keeps it until
it restarts, so a Mac whose icons showed boards' JSON keeps them after the
app is opened, until a logout. qlmanage can't host a data-based preview
extension here (it throws for Apple's own too), so the preview was checked
through a QLPreviewView host.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -2; git status --short | head -3

[2026-10-05 14:20] ASSISTANT:
Quick Look now shows a board file's top board, drawn by the app's own code. Space in the Finder gives the preview, and the Finder's icons become thumbnails. It's committed on this worktree's branch, reviewed, and every test passes; I haven't landed it.

**Try it now:** this worktree's build is already registered with macOS, so select a `.canvasboard` in the Finder and press space. If it still shows JSON, relaunch the Finder (⌥-right-click its Dock icon → Relaunch). Icons Quick Look has already cached as JSON can stay that way until the file changes; this clears that cache:

```bash
qlmanage -r cache
```

**What you get** (the renders I sent show both):
- **Preview:** the whole board fitted, at no more than 100%, in light or dark to match your system.
  - Notes, arrows, frames and title pills look as they do in the app, and subboard cards show their board's preview.
  - Big boards draw zoomed out as the app's simplified shapes.
  - It's at least 480×320 and at most 1600×1200.
- **Thumbnails:** the board fills the icon, always in light mode, because macOS keeps a thumbnail across appearance switches. An empty board keeps the plain document icon.

**Decisions I made:**
- The real render rather than the minimap's gray silhouettes, since Quick Look is for seeing what's in a file.
- A still picture rather than a live, pannable canvas in the Quick Look window.
- The extension is a new module, `CanvasQuickLook`, in a new `appex` layer that may use what the app does except the wire. The drawing is `BoardPicture` in CanvasUI, used through the editor's host API, so no kind needed any changes.
- `build.sh` bundles the two extensions into the app and signs them ad hoc with the sandbox Quick Look requires. The app itself stays unsigned, and a no-op build still changes no file in the bundle.

**Found along the way:**
- **macOS caching:** Quick Look's thumbnail process picks a thumbnailer for each file type the first time it's asked and keeps it until it restarts. So after this lands, if board icons still show JSON once you've opened the new build, log out and back in. This is in the README and in a new topic file, `.claude/rules/quick-look.md`.
- **System changes during testing:** I registered and removed throwaway test apps with LaunchServices; all are gone. I also force-quit that thumbnail process once (`kill -KILL`), and launchd restarted it.
- **One thing I couldn't confirm:** whether the preview opens at the intended size. I can't capture the Quick Look window, so the size rests on the standard 2× (144 dpi) image convention. If the preview opens twice as large as expected, tell me.

**Review:** it raised 10 findings. I fixed six, including a real bug where thumbnails ignored Quick Look's minimum size. I left four:
- the preview-size assumption above;
- untested memory limits on huge boards;
- about 0.1 s of re-signing per build;
- decoding a file again for each thumbnail size.

Say "land" and I'll merge it to main and clean up the worktree.

[2026-10-05 14:46] USER:
Land

[2026-10-05 14:46] GIT:
git -C /Users/zekenie/code/native-canvas branch --show-current; git -C /Users/zekenie/code/native-canvas status --porcelain | head -5; echo "main: $(git -C /Users/zekenie/code/native-canvas log -1 --format=%h main)"; echo "branch base: $(git merge-base HEAD main | cut -c1-7)"; git log --oneline main..HEAD

[2026-10-05 14:46] ASSISTANT:
Main hasn't moved and its checkout is clean, so this fast-forwards. Merging:

[2026-10-05 14:46] ASSISTANT:
On main. Cleaning up: unregistering this worktree's build from macOS so Quick Look won't point at a deleted bundle, then removing the worktree and its branch.

[2026-10-05 14:46] ASSISTANT:
It's on main as `1698396`.

To get Quick Look on main's app, rebuild and open it:

```bash
./build.sh && open build/InfiniteCanvas.app
```

If board icons in the Finder still show JSON afterwards, log out and back in.

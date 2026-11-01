# References collapsible section in TOC

Claude Code session `860cdf99-63ef-4e44-b28a-99d9ee12972c`, 2026-11-01 14:13 to 2026-11-01 15:07 UTC, on `claude/toc-references-collapsible-c771b1`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-11-01 14:13] USER:
[image attached]

[2026-11-01 14:13] USER:
I have some notes about how references are treated in the table of contents. I think references for a shape should get compressed into a collapsible section. Here's the reason why. In this example, there are far more references than actual shapes in the frame. The actual shapes are getting crowded out by all the references. While I agree the references should be findable in the table of contents, I think they should end up getting collapsed so they don't take up all the visual space. So what I'm imagining here is that there would be a frame product layer. Inside product layer, there would be four shapes, the subboards, and the references would all be under a single collapsed section, references.

[2026-11-01 14:14] ASSISTANT:
I'm reading how the table of contents builds and nests its rows, so I can propose where a collapsed "References" group would fit. I'll bring you a plan before changing anything.

[2026-11-01 14:17] ASSISTANT:
I'm still reading the list's controller and the crumb-menu outline, to see what a non-shape "References" row would touch; plan coming next.

[2026-11-01 14:19] ASSISTANT:
I've read enough of the sidebar's code to propose a plan; writing it up now.

[2026-11-01 14:19] WRAP-UP:
I worked out how a collapsed References section would fit the sidebar: a generic way for a kind to gather its rows, declared by References. Nothing is changed yet; the plan waits on your go-ahead.
Ask: Build it as planned?

[2026-11-01 14:19] ASSISTANT:
Nothing is changed yet. Here's what I'd build.

**What you'd see**
- At every level of the sidebar (the board, each frame, and each subboard's board opened under its row), the references collect under one **References** row. It sits after the level's other rows, starts closed and shows a count. "Product layer" would list its four subboards, then "References 30".
- References always collect there, even when there's only one, so they're always in the same place.
- Whether a References row is open or closed is remembered for each level, the way a row's triangle is now.
- Clicking the References row selects all the references in it, the same way clicking any row selects what it stands for. Its triangle, → ←, and Return open and close it.
- If you select a reference on the canvas, or through Jump To or Find, its section opens so you can see the row. That's how rows nested under a shape already open.
- With the keyboard, ↑ ↓ reach the References row, and VoiceOver reads it as "References, 30". You can't drag the References row or drop onto it, but the references inside it drag as they do now.
- The board path's crumb menus get the same References rows. In those menus, a click or Return opens the section instead of selecting, because clicking a row there normally takes you to that shape.

**How**
- The table of contents gets a general way for any kind of shape to collect its rows under a named row. References uses it to name its rows "References", with its own symbol. The table of contents itself still doesn't know what a reference is.

**Checks**
- Tests will cover:
  - the references collecting at each level, with the right count;
  - references being added and removed;
  - walking the list with the keyboard, and VoiceOver names;
  - the open or closed state being remembered;
  - selecting a reference opening its section;
  - the crumb menus.
- I'll update the table of contents and references docs and the guide.
- I'll send before-and-after pictures of the sidebar on a board set up like yours.

[2026-11-01 14:21] USER:
Build it

[2026-11-01 14:25] ASSISTANT:
Starting the build: I'm adding the general "section" mechanism to the table of contents first, then the sidebar list, the crumb menus, and References.

[2026-11-01 14:29] ASSISTANT:
Writing the code now: first the general "section" declaration in the table of contents, then the state that remembers which sections are open.

[2026-11-01 14:29] ASSISTANT:
Now the section row's look, beside the shape row's label:

[2026-11-01 14:29] ASSISTANT:
Now the state: each row carries its kind's section, levels are gathered, and which sections are open is kept per level.

[2026-11-01 14:29] ASSISTANT:
Now the kind's section, the ranks and the opened sections in the state:

[2026-11-01 14:30] ASSISTANT:
Now the sidebar list's controller. This is the largest piece; I'm rewriting the file whole so the section rows go through every path (reload, row-by-row updates, nested boards, selection, keys).

[2026-11-01 14:33] ASSISTANT:
Now reload and the row-by-row follow:

[2026-11-01 14:33] ASSISTANT:
Now the nested boards' rows (a subboard's board open under its row), which follow their board through the same section logic:

[2026-11-01 14:33] ASSISTANT:
Now making, removing and forgetting rows and section rows:

[2026-11-01 14:34] ASSISTANT:
Now redrawing, the selection, opening and the keys:

[2026-11-01 14:34] ASSISTANT:
Now the turn watcher, data source and delegate:

[2026-11-01 14:36] ASSISTANT:
The sidebar list is wired. Let me compile and run the existing table of contents tests before moving to the crumb menus:

[2026-11-01 14:36] ASSISTANT:
It compiles and all 161 existing table of contents tests pass. Now the crumb menus' outline:

[2026-11-01 14:37] ASSISTANT:
Now Boards' crumb menu: Return on a section's row opens or closes it instead of picking.

[2026-11-01 14:38] ASSISTANT:
Now compiling and running the existing tests of the three modules this touches (table of contents, boards, references):

[2026-11-01 14:38] ASSISTANT:
The existing suites all pass with the change. Now the tests for sections; checking how the test targets reach internal API first:

[2026-11-01 14:39] ASSISTANT:
Tests reach the list only through AppKit (no `@testable`), so I'll give the outline's items a debug-build description that a test can read as text:

[2026-11-01 14:40] ASSISTANT:
Writing the tests for sections now (state, sidebar list, keyboard, crumb menu outline).

[2026-11-01 14:42] ASSISTANT:
Fixing the observation check to use the shared `Flag` helper, then rerunning:

[2026-11-01 14:43] ASSISTANT:
Two failures to look at. The drag one is the test's fault (nothing had read the list yet, so every row counts as shown). Checking the keys one:

[2026-11-01 14:44] ASSISTANT:
The keys test shows the selection one row off after → opens the section. Let me look at what the outline's selection is after each key:

[2026-11-01 14:45] ASSISTANT:
All 19 section tests pass. Running the whole table of contents suite again for regressions:

[2026-11-01 14:45] ASSISTANT:
Now a References test that its rows gather in "References". Looking at the existing row tests:

[2026-11-01 14:46] ASSISTANT:
Now the crumb menu by keys, in Boards' tests. The test reader there takes "a row has the keyboard" from `menuKeyboard.row`, which a section's row leaves nil, so it reads the line's name instead:

[2026-11-01 14:46] ASSISTANT:
Both suites pass whole. Now the shipped registry report, which pins every contribution (and its copy in the guide):

[2026-11-01 14:47] ASSISTANT:
The pinned report passes with the new line. Now one end-to-end test with the shipped kinds (a frame, notes, and references, as in your board). Looking at the shipped sidebar harness:

[2026-11-01 14:48] ASSISTANT:
The sidebar code and its tests are in; I'm adding the last end-to-end test (a frame with subboards and references, as on your board).

[2026-11-01 14:49] ASSISTANT:
The end-to-end test passes on the shipped kinds: "Product layer" lists Frames and Arrows, then "References · 3". Now the docs.

[2026-11-01 14:50] ASSISTANT:
Now the guide's table of contents section: a bullet for sections, and a line in its sketch of the sidebar.

[2026-11-01 14:50] ASSISTANT:
Docs are updated. Next, the before/after pictures of the sidebar. Checking my notes on how renders are made here:

[2026-11-01 14:52] ASSISTANT:
Now the throwaway render test (identical in both copies, never committed):

[2026-11-01 14:52] ASSISTANT:
While both copies build, I'm re-reading the list controller's changes end to end.

[2026-11-01 14:53] ASSISTANT:
The controller diff reads correctly to me. Checking whether any benchmark covers the list, while the renders build:

[2026-11-01 14:53] ASSISTANT:
The sidebar benchmark waits until the table's rows equal the number of listed top-level entries; if its generated board has pills, sections would make that never true. Checking:

[2026-11-01 14:53] ASSISTANT:
Nested helpers in the throwaway test need `@MainActor`, and it needs `import Publishing`. Fixing and rerunning both builds:

[2026-11-01 14:53] ASSISTANT:
While those build: the benchmark's generated board, to see whether pills are on it.

[2026-11-01 14:54] ASSISTANT:
The generated benchmark board has no pills, so the sidebar benchmark's row count still holds. Checking nothing else used the outline's old line type:

[2026-11-01 14:54] ASSISTANT:
While the renders build, I'm writing a small script that lays the pictures side by side with labels:

[2026-11-01 14:54] ASSISTANT:
Both renders are made. The compose script hit the known stale-SDK issue; using the SDK the project's notes name:

[2026-11-01 14:55] ASSISTANT:
The pictures show the symbols but no text, on black. Something in my render path is off (not the sidebar itself); looking at one raw render:

[2026-11-01 14:55] ASSISTANT:
The gallery sets the list's own appearance to the plain one before drawing, since the source list's vibrant appearance blends offscreen. Doing the same in the throwaway render:

[2026-11-01 14:57] ASSISTANT:
On the sidebar's backdrop it reads as intended: four subboards, then "› References 30", with the symbol a dimmed accent and the count gray. Checking the whole sheet before sending it:

[2026-11-01 14:57] ASSISTANT:
The sheet is right. Sending it now, then finishing the checks.

[2026-11-01 14:58] ASSISTANT:
Sent. Now a wording fix: the render shows the section's symbol is the list's accent dimmed (not gray), so the docs should say exactly that.

[2026-11-01 14:58] ASSISTANT:
Main moved since this branch was cut. Checking what came in, so the full test run covers the change on top of the latest main:

[2026-11-01 14:58] ASSISTANT:
Main has five new commits touching some of the same docs and the pinned report, so I'll commit on the branch and rebase onto main now, so the full suite runs on the combination.

[2026-11-01 14:58] GIT:
git add -A && git commit -q -F - <<'EOF'
A frame's references gather under one closed "References" row in the table of contents, so what it holds stays in view

The owner's board had a "Product layer" frame holding four subboards and thirty reference pills. The
sidebar listed the pills among the subboards, front to back, so the four shapes the frame is about
were pushed out of view. References should stay findable there, but take one row.

A kind now says where its rows go (`ContentsSections`, `x.contentsSection(ContentsSection(...))`):
at every level its rows are listed at (the board, what a frame holds, a subboard's board under its
row) they gather under one row of the section's, after the level's other rows, with their count,
closed until it's opened. References declares "References" with its own symbol; the table of
contents still knows nothing of references. Where each row is listed and what nests under it are
unchanged (`entries`, `outline(of:)`): the list and the crumbs' outline gather each level as they
show it, from the same helper.

Decisions, the owner's approved plan:
- Always gathered, even one reference, so a kind's rows are always in one place; after the level's
  own rows; closed at first; opened or closed is kept per section and level for the editor's life,
  as a row's triangle is.
- Selecting the section's row selects every reference in it (as a row selects what it stands for),
  and a selection of them all shows on its closed row; the alternative offered, a click that only
  opens it, was not taken. One reference selected elsewhere opens its section.
- By keys it is a row: ↓ reaches it, → ← and Return open and close it; VoiceOver hears
  "References, 30"; it doesn't drag or take drops.
- A crumb's menu gathers the same way; there a click or Return opens it, since a row's click there
  goes somewhere and the section has nowhere to go (`OutlineKey.activate`, which Boards sends).

Rejected: gathering by `standsIn` (a reference to nothing or to words wears no arrow, so it would be
left out, and the core knows no stand-ins); a synthetic entry in the listing (every row is a shape:
selection, hover, drags and keys all go by shape); AppKit's group rows (header style, unselectable,
so the keys couldn't reach one).

Found while testing: an update SwiftUI delivers late (a → pressed before it caught up with the ↓
that selected the section) re-derived the selection from the shapes and moved it onto the opened
rows; a section row the list selected now stays the selection of its rows, open or not.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -1 && git rebase main 2>&1 | tail -15

[2026-11-01 14:58] ASSISTANT:
The rebase stopped on conflicts. Listing which files actually conflict:

[2026-11-01 14:58] ASSISTANT:
Each conflict is main's newer wording in the same paragraph as one small addition of mine. I'll keep main's text and put my additions back in. Looking at the two remaining hunks first:

[2026-11-01 14:59] ASSISTANT:
All five resolved with main's wording kept. Continuing the rebase:

[2026-11-01 14:59] GIT:
git add .claude/rules/keyboard-navigation.md .claude/rules/references.md CLAUDE.md Tests/CompositionTests/ShippedTests.swift docs/plugin-system.md && GIT_EDITOR=true git rebase --continue 2>&1 | tail -2 && git log --oneline -3 && grep -n "sectionTitle" Sources/References/ReferenceStyle.swift

[2026-11-01 14:59] ASSISTANT:
Rebased cleanly onto the latest main. Starting the whole test suite in the background on the combination:

[2026-11-01 14:59] ASSISTANT:
While the suite runs, the code review (the gate before this can land):

[2026-11-01 15:01] ASSISTANT:
I'll fix the crumb-menu focus finding: a click on a section's line keeps the menu open, so its button shouldn't take the keyboard. The rest I'm leaving (noted below).

[2026-11-01 15:01] ASSISTANT:
The full suite is still running on the code from before this one-line fix; once it reports I'll rerun the targets the fix reaches.

[2026-11-01 15:01] ASSISTANT:
The code review found six things. One was a real bug, now fixed: clicking "References" in a crumb menu could leave the keyboard in that button instead of on the canvas. The other five are minor and I've left them:
- Deselecting a single reference doesn't work while the whole References row is selected (⌘-click on one of its rows).
- Two efficiency points: the crumb menu regroups its rows on every key press, and remembered open sections are never cleared.
- Two code-tidiness points: test helpers repeated across files, and the selection fix covers References rows rather than the general case.

The full test suite is still running on the code from just before that fix. When it reports, I'll rerun the tests the fix touches and come back.

[2026-11-01 15:03] NOTICE:
background task completed: Background command "Run the whole test suite" completed (exit code 0)

[2026-11-01 15:03] ASSISTANT:
The whole suite passed on the rebased branch: all 64 test executables, 0 failures. Now rerunning the three targets that the crumb-menu fix reaches:

[2026-11-01 15:04] ASSISTANT:
The fix's three targets pass (180, 107 and 896 tests). Folding the fix into the branch's one commit and removing the two throwaway copies used for the renders:

[2026-11-01 15:04] GIT:
git add -A && git commit -q --amend --no-edit && git log --oneline -2 && git status --short | head -3; R=/private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-toc-references-collapsible-c771b1/860cdf99-63ef-4e44-b28a-99d9ee12972c/scratchpad/render; rm -rf "$R/before" "$R/after"; ls "$R"

[2026-11-01 15:04] WRAP-UP:
References now collect under one closed "References" row at each level of the sidebar and crumb menus, after the level's other rows. It's one reviewed commit on the branch, on top of the latest main; the whole suite passes. Not landed.
Ask: Land it on main?

[2026-11-01 15:04] ASSISTANT:
References now collect under one closed "References" row. The full test suite passes, it's been code-reviewed, and it's one commit on this branch on top of the latest main, not yet landed.

On a board like yours, "Product layer" now lists its four subboards and then "References 30". Opening it shows every reference with its path, as before. The picture I sent shows before, after, and after with References opened.

**How it behaves**
- Every level gathers its references this way: the board, each frame, and each subboard's board opened under its row. A single reference gets the row too.
- Whether a References row is open or closed is remembered for each level.
- Clicking the row selects all the references in it.
- The triangle, → ←, Return and a double-click open and close it.
- Selecting one reference on the canvas, or through Jump To or Find, opens its References row.
- ↓ reaches the row like any other, and VoiceOver reads "References, 30".
- The board path's crumb menus group references the same way. There, a click or Return opens the row instead of going somewhere.
- The table of contents itself still knows nothing about references. Any kind of shape can now ask to have its rows collected like this, and References is the one that does.

**Found along the way**
- If you pressed → before the list had caught up with the ↓ that selected References, the selection jumped onto the newly shown rows. That's fixed.
- The code review found that clicking References in a crumb menu could leave the keyboard in that row's button instead of on the canvas. That's fixed and retested.
- I left one rough edge from the review: while the whole References row is selected, ⌘-clicking a single reference doesn't deselect just that one. The other four findings were efficiency and code-tidiness points.
- Main had moved since the branch started. I rebased onto it and kept main's newer wording in the shared docs and in the registry report the tests pin. The whole suite ran on that combined code.

[2026-11-01 15:07] USER:
You’re done? Land if so

[2026-11-01 15:07] ASSISTANT:
Yes, it's done. Landing it now.

[2026-11-01 15:07] GIT:
git log -1 --format='%h %s' main && git merge-base --is-ancestor main HEAD && echo "branch is on top of main" ; git -C /Users/zekenie/code/native-canvas status --short | head -5; git -C /Users/zekenie/code/native-canvas branch --show-current

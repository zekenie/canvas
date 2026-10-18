# Fix draw refusing frames moved together

Claude Code session `d31112aa-8efe-4635-b99d-4c4da2b735c5`, 2026-10-08 13:26 to 2026-10-08 14:31 UTC, on `claude/sharp-gould-b4ef90`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-08 13:26] USER:
Background: dogfood/bugs.md and dogfood/ideas.md list what drawing this repo onto a board with `canvas draw` turned up (at 2df3c02c). On 2026-10-08 the user triaged them, called the item below a no-brainer and approved fixing it. Five other sessions are fixing other items from those lists at the same time (one of them also changes draw's solver, for pill columns), so keep to yours and expect to rebase.

How to work: follow the project's memory and CLAUDE.md as usual: read the topic files for the areas you touch, show the user your plan before code, get a code review before reporting ready, and land only on the user's go as one squashed commit. Test headlessly (`./test.sh`, `TEST_FILTER=`). Several sessions share the one running app, so ask the user before quitting it or opening another build. A change to `canvas draw` or its messages changes the canvas skill too (`.claude/skills/canvas`; SkillTests hold them together). When it lands, delete your item from dogfood/bugs.md, leaving every other item's number as it is.

Your item, as bugs.md words it:

4. **Restated frames are judged where the others are now, not where the run puts them.** One run moving the root's ten bands to new places, none overlapping, is refused: `"Composition layer" and "UI layer" overlap … unordered`; Composition's new box covers UI layer's old one. With overlaps allowed, bands are nudged out of each other's old places. Moving them all aside first, then into place, works.

A run that restates several frames with placements should judge each one against where the others land, both while placing (the `unordered` refusal) and while putting them down (the in-or-out settling that nudged them). Where to look: the solver (Sources/DrawScript/Solver.swift, LayoutProblem.swift; a shape the script moves isn't an obstacle, so find what still holds the old box) and the commit (Sources/Automation/DrawCommit.swift: restated containers are put down one by one, each settled by the in-or-out rule, `transaction.settle`, perhaps while the others still stand where they were). Read .claude/rules/command-line.md, containers.md and frames.md first, and reproduce it in a test before changing anything (frames are a shipped kind, so CompositionTests' draw tests may suit better than AutomationTests' fixtures).

[2026-10-08 13:26] ASSISTANT:
Reading the draw solver and commit code to find where restated frames' old boxes still count, then I'll reproduce it in a test and bring you a plan.

[2026-10-08 13:27] ASSISTANT:
Still reading: looking at how the dogfood script laid out the root's bands so I can reproduce the refusal.

[2026-10-08 13:30] ASSISTANT:
Still exploring: reading the existing draw container tests so the reproduction fits their style.

[2026-10-08 13:38] ASSISTANT:
Building the test targets to run the two new reproduction tests (the first build in this worktree may take a few minutes).

[2026-10-08 13:44] ASSISTANT:
Both halves reproduce. Here's the plan. I'll wait for your OK before changing any source.

**What's wrong** (reproduced in AutomationTests with pens, the test stand-in for frames)
1. **Placing:** a frame the run moves stops being an obstacle, but the shapes inside it still count as obstacles at their old places. Composition's new box covered UI layer's old contents, so it got pushed into UI layer's new box, and the run was refused as `unordered`. The same cause has a second symptom: `tile "N" in "A"`, with A moved, lands on top of A's contents, because it dodged where they used to be.
2. **Putting down:** each shape is settled in or out of frames as soon as it moves, while frames later in the script still stand where they were. With `overlap: allow`, pen A was nudged into B's old box. Then B moved and took A with it.

**Fix**
1. **Solver** (`Solver.swift`): whatever a restated frame holds moves with it. Automation already passes this as `Free.carries`. Every other shape sees those contents at their old place, shifted by however far their innermost moving frame goes. That applies to overlap checks, zones and the empty-spot search. When a shape is pushed off one of them, the push is tied to the frame rather than the board, so if the frame moves later in the solve, the shape moves with it.
   - No API change.
   - No extra cost when nothing is carried, and one extra grid lookup per moving frame otherwise.
   - `/move-to` and `/move-near` are unaffected: they place one box with no current position.
2. **Commit** (`DrawCommit.swift`): two passes.
   - First, every shape goes where it's placed. Moves, adds and raises happen exactly as now.
   - Then each shape is settled against the board as the run leaves it.
   - **My choice:** in the second pass, shapes that hold nothing settle first and frames last. That way a shape over a frame's edge still gets its own warning (`"X" was over the edge of "F", so it was nudged in`), and if a frame is then nudged, what's in it moves with it. Script order would also work, but its warnings are vaguer in that rare case.
3. **Tests:**
   - The two AutomationTests above.
   - A solver test in DrawScriptTests.
   - One CompositionTests case with real frames: three bands holding notes, reversed in one run, as in the dogfood run.
4. **Docs:**
   - `command-line.md` and the guide's draw section.
   - One sentence in the skill's Frames section: frames moved in one script are each placed against where the others land.
   - Delete item 4 from `bugs.md`.

**One question:** `gen5.py` has a "move the bands aside first" step that exists only because of this bug, and its comment cites item 4. I'd keep the step, which still works, and just drop the citation, since I can't test `gen5.py` here without the shared app. Or I can remove the step. Which do you want?

[2026-10-08 13:53] USER:
I have not the foggiest idea what you are talking about with your question

[2026-10-08 13:53] ASSISTANT:
Sorry, that was unclear. The script that drew this repo onto a board, `dogfood/model/gen5.py`, has a workaround for this bug. Before moving the bands into place, it moves them all far off to one side, and a comment there points to item 4 in `bugs.md`.

Once the bug is fixed, that workaround is no longer needed, but it's harmless. I'll decide it myself: keep the workaround as is and drop its pointer to item 4, since that item will be deleted.

Is the rest of the plan OK to go ahead with?

[2026-10-08 13:55] USER:
Why keep the workaround if the bug is fixed. Act sensibly

[2026-10-08 13:55] USER (sent mid-turn):
And go

[2026-10-08 13:57] ASSISTANT:
Understood: I'll remove the workaround and go ahead with the rest of the plan.

[2026-10-08 13:57] ASSISTANT:
Going. Starting with the solver.

[2026-10-08 13:58] ASSISTANT:
Solver half done; now the push-off-a-carried-shape bound and the hint/spot queries, then the commit.

[2026-10-08 13:59] ASSISTANT:
Solver done; now the commit's two passes in `DrawCommit.swift`.

[2026-10-08 14:01] ASSISTANT:
All green, including both new AutomationTests and Moving's. Adding the solver-level test next to the existing "what a box carries" one.

[2026-10-08 14:02] ASSISTANT:
Now the end-to-end case with shipped frames in FramesShippedTests: three bands holding notes, reversed in one run.

[2026-10-08 14:03] ASSISTANT:
Both pass. Checking the new tests actually fail without the source fix (temporarily reverting only `Sources/`, from a saved patch).

[2026-10-08 14:03] ASSISTANT:
The frames test fails unfixed with the dogfood run's exact refusal. Quick check that the nested-carrier part also discriminates (flipping inner/outer temporarily):

[2026-10-08 14:04] ASSISTANT:
Restored. Now the docs and skill, then the full suite.

[2026-10-08 14:04] ASSISTANT:
Starting the full suite in the background while I remove the dogfood workaround and the bugs.md item.

[2026-10-08 14:05] ASSISTANT:
Workaround removed from `gen5.py`; checking nothing else used its helper, then deleting the bugs.md item. The full suite is still running.

[2026-10-08 14:05] ASSISTANT:
Workaround and item 4 are gone; nothing else cites them. Waiting on the full suite now.

[2026-10-08 14:05] ASSISTANT:
The suite is still running; I'll be notified when it finishes.

[2026-10-08 14:06] ASSISTANT:
All 4,537 tests pass. Committing on the branch, then the code review.

[2026-10-08 14:06] GIT:
git add -A && git status --short && git commit -q -F - <<'EOF'
canvas draw: frames one run moves are each judged where the others land, so they can trade places in one run

Drawing this repo onto a board turned up dogfood/bugs.md's item 4: one run moving the root's ten bands to new places, none overlapping, was refused (`"Composition layer" and "UI layer" overlap … unordered`), and with overlaps allowed the bands were nudged out of each other's old places; moving them all aside first, then into place, worked. The owner triaged it on 2026-10-08 as a no-brainer: a run that restates several frames should judge each against where the others land, both while placing them and while putting them down.

It had two causes, both reproduced before the fix:
- Placing: a frame the run moves isn't an obstacle, but what it holds still was, where it was. Composition's new box covered UI layer's old contents, was pushed off them, into UI layer's new box. The same cause put a shape drawn `in` a moved frame on top of the frame's contents: it dodged them where they had been.
- Putting down: each shape was settled by the in-or-out rule as soon as it moved, while frames later in the script still stood where they were. A pen moved over most of another's old box was nudged into it, then carried off inside it when the other moved.

The fix:
- The solver (DrawScript) meets what a restated box carries (`Free.carries`, which Automation already passed) where that box takes it: moved as far as the innermost box carrying it moves, in clash checks, zones and the search for a clear spot. A push off one is a bound against that box, not the board, so the shape follows if the box moves on. No API change; with nothing carried the solver asks exactly what it did.
- The commit (Automation's DrawCommit) puts every shape where it goes first (moves, adds and raises as before), then settles each against the board as the run leaves it: the shapes that hold none first, then the containers, so a shape over a frame's edge still gets its own warning and what's put down in a frame goes along if the frame is nudged.
- gen5.py's step that moved the bands aside first existed only for this bug, so it's gone, and item 4 leaves bugs.md (the other items keep their numbers). The skill's Frames section says frames moved in one script can trade places.

Tests: AutomationTests (pens trading places, with and without overlap: allow; a tile in a moved pen kept clear of what the pen holds where it goes), DrawScriptTests (the solver, the inner of two boxes carrying a shape taking it), and CompositionTests (three bands holding notes turned upside down in one run, which before the fix was refused with the dogfood run's message).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -2

===== [2026-10-08 14:06] commit written: canvas draw: frames one run moves are each judged where the others land, so they can trade places in one run =====

[2026-10-08 14:06] ASSISTANT:
Now the code review of the branch.

[2026-10-08 14:10] ASSISTANT:
The review found 8 things. I'm fixing 5 of them: the stale `board` bounds, the resize warning, the missing test, the doc wrap and the API doc. The other 3 aren't worth changing (reasons below).

[2026-10-08 14:10] ASSISTANT:
Now tests for the board-bounds fix and for a push that follows its carrier.

[2026-10-08 14:11] ASSISTANT:
Both pass. Checking they'd catch a regression (temporarily undoing each fix):

[2026-10-08 14:12] ASSISTANT:
Both new tests fail without their fix and pass with it. Updating the docs for the `board` change, then rebuilding everything and rerunning the full suite.

[2026-10-08 14:13] ASSISTANT:
All 4,539 pass. Committing the review fixes on the branch, which gets squashed when it lands.

[2026-10-08 14:13] GIT:
git add -A && git commit -q -m "Fix what reviewing the restated-frames change found: board's box leaves out what a moved frame takes along, no resize warning for a shape a moved frame carries, a test that a push follows its carrier

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git log --oneline -3

[2026-10-08 14:14] ASSISTANT:
Item 4 is fixed: frames moved in one `canvas draw` run are now each judged against where the others land. So the dogfood bands can swap places in a single run, and nothing gets pushed or nudged. It's reviewed and committed on the branch, not landed; all 4,539 tests pass.

There were two causes:
- **Placing:** a moved frame's contents still counted as obstacles at their old places. So a frame moved into another's old spot was pushed off those contents and refused as `unordered`. Shapes inside a moving frame are now judged where the frame takes them.
- **Putting down:** each shape was settled into or out of frames as soon as it moved, while frames later in the script hadn't moved yet. Now every shape is moved first, then settled.

A few other things changed along the way:
- **New tests:** AutomationTests (two pens swapping places, and a shape added to a pen that moves) and the solver tests. A new CompositionTests case turns three real bands holding notes upside down in one run. Before the fix, that case was refused with the same message your dogfood run got.
- **Dogfood:** the "move the bands aside first" step in `gen5.py` is gone. Item 4 is deleted from `bugs.md`; the other items keep their numbers.
- **Docs:** one sentence in the skill's Frames section says frames moved in one script can trade places. The guide and `command-line.md` are updated too.

The review found 8 issues. I fixed 5:
- `right of board` in the same run as a frame move still measured against where that frame's contents used to be.
- A misleading "resized where it is" warning for a shape inside a moving frame.
- No test that a shape pushed off a frame's contents moves with the frame if the frame is pushed later.
- Two doc fixes.

I left 3 alone, since none affects a normal board:
- An edge case where shapes stick out past a moving frame's edge.
- A small extra lookup cost per moving frame.
- `gen5.py` no longer stops when the bands exist but their anchor note is gone. It now draws a new anchor and carries on.

It's ready to land as one squashed commit when you say go.

[2026-10-08 14:30] USER:
Land

[2026-10-08 14:30] GIT:
git log --oneline -1 main && git merge-base main HEAD && git -C /Users/zekenie/code/native-canvas status --short | head && git -C /Users/zekenie/code/native-canvas branch --show-current

[2026-10-08 14:30] GIT:
git reset -q --soft 5cb3c5b7 && git commit -q -F /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-sharp-gould-b4ef90/d31112aa-8efe-4635-b99d-4c4da2b735c5/scratchpad/msg.txt && git log --oneline -2 && git rebase main 2>&1 | tail -5

[2026-10-08 14:30] ASSISTANT:
Resolving two rebase conflicts: other sessions also deleted their items from `bugs.md`, and both edited `command-line.md`.

[2026-10-08 14:31] GIT:
git add .claude/rules/command-line.md dogfood/bugs.md && GIT_EDITOR=true git rebase --continue 2>&1 | tail -2 && git log --oneline -3 && git -C /Users/zekenie/code/native-canvas status --short | head -3 && git -C /Users/zekenie/code/native-canvas merge --ff-only claude/sharp-gould-b4ef90 2>&1 | tail -2

[2026-10-08 14:31] ASSISTANT:
It's on main as 5aa98112. The worktree and branch are removed.

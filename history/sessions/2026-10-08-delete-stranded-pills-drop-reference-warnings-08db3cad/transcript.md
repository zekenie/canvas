# Delete stranded pills; drop reference warnings

Claude Code session `08db3cad-9685-4813-ae5a-e97acf8e86a5`, 2026-10-08 13:26 to 2026-10-08 13:53 UTC, on `claude/cool-leavitt-824c8b`, `main`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-08 13:26] USER:
Background: dogfood/bugs.md and dogfood/ideas.md list what drawing this repo onto a board with `canvas draw` turned up (at 2df3c02c). On 2026-10-08 the user triaged them, called the items below no-brainers and approved fixing them. Five other sessions are fixing other items from those lists at the same time, so keep to yours and expect to rebase.

How to work: follow the project's memory and CLAUDE.md as usual: read the topic files for the areas you touch, show the user your plan before code, get a code review before reporting ready, and land only on the user's go as one squashed commit. Test headlessly (`./test.sh`, `TEST_FILTER=`). Several sessions share the one running app, so ask the user before quitting it or opening another build. A change to `canvas draw` or its messages changes the canvas skill too (`.claude/skills/canvas`; SkillTests hold them together). When it lands, delete your items from dogfood/bugs.md and dogfood/ideas.md, leaving every other item's number as it is.

Your items, as the lists word them:

bugs.md 5. **Deleting shapes strands their pills, and a script can't delete them.** Deleting the root's cards and bands left the 200 pills their arrows ran into, standing for nothing. No script can name an untitled shape, so none can delete them; a person has to. A script should be able to, for example by deleting a frame with what it holds, or the pills that stand for nothing. (I put them in frames with `overlap: allow` and moved those aside.)

ideas.md 4. **Quieter notice for edges through references.** Every such edge warns that it went through a reference, but its row already says `via`. At this scale that's about 2,400 warnings that hide the real ones.

ideas.md 6 says only "now bugs.md, 5": delete it along with bug 5.

What the user approved: `delete "X"` also takes each stand-in that X's arrows leave with no arrow, as `delete edge` already does (`standInsEmptied`; a read-only one is `read_only`); and an edge that goes through a stand-in without `via:` no longer warns, since its row says `via`. Both change what .claude/rules/command-line.md ("Edges through stand-ins") documents today: "`delete "X"` leaves the stand-ins its arrows ran into", and the warning `"Auth" is on "Payments"'s board, so the arrow goes into a reference to it beside "Checkout"` (Sources/Automation/DrawStandIns.swift, about line 298). Update that topic file, the guide (docs/plugin-system.md, "draw") and the skill to match. Pills that stand for a deleted shape but still have arrows from elsewhere are out of scope. Tests: AutomationTests' DrawStandInTests, CompositionTests' DrawStandInsTests, SkillTests. Leave dogfood/model alone: another session is changing those scripts.

[2026-10-08 13:27] ASSISTANT:
I'm reading the stand-in code, the topic file and the dogfood lists to plan the two fixes; a plan will follow before any code.

[2026-10-08 13:28] ASSISTANT:
Still reading: now the canvas skill's pages on references and deletes, to see what they promise today.

[2026-10-08 13:28] ASSISTANT:
Reading the tests that hold the warning and `delete "X"` today (AutomationTests and CompositionTests); next I'll check SkillTests, then write up the plan.

[2026-10-08 13:31] ASSISTANT:
Reading's done; writing the plan for the two fixes now (no code yet).

[2026-10-08 13:32] ASSISTANT:
Here's the plan. Both fixes are small and stay inside Automation, plus docs and tests. No code until you say go.

**1. `delete "X"` also deletes the references X's arrows leave empty** (`Drawing.swift`)
- When `delete "X"` takes an arrow whose other end is a reference, that reference joins `standInsEmptied`. The existing `retireEmptiedStandIns` then deletes it, but only if the run leaves no arrow on it. A reference with an arrow from somewhere else stays, and so does one held by an arrow whose other end is free. This is the same rule `delete edge` uses today.
- A read-only reference refuses the run with `read_only` (`the reference that delete "Hub" leaves with no arrow is read-only (locked, say), so it can't be deleted`), and nothing is deleted.
- Today stand-ins are only looked up when a script has an edge or a `delete edge`. From now on any `delete` looks them up too. Which board a run draws on doesn't change.
- `retireEmptiedStandIns` will make one pass over the board's arrows instead of one pass per reference. At the dogfood board's size (200 references, about 2,400 arrows) that saves millions of comparisons.

**2. No warning for an edge that goes through a reference** (`DrawStandIns.swift`): the `notes.append` in `routeEdge` goes.

**Decisions I've made (tell me if you disagree):**
- **Result rows change:** the rows for X's arrows into a reference will name the shape the reference stands for and carry `via`, as `delete edge`'s rows do. Today they say `to: "reference at 580,190"` and have no `via`. This follows from looking up stand-ins on every delete.
- **Row order on the delete's line:** X first, then its arrows, then each reference (`deleted`, kind only).
- **Only direct references are deleted**, the kind `delete edge` takes. A query reference someone typed stays, even with no arrows left.

**Docs:**
- `command-line.md`: the stand-ins section and its Testing notes.
- The guide's "draw" section. While there I'll fix one existing error: it says a deleted reference's row comes before the arrow's, but it comes after.
- The skill: `language.md` (Through a reference, Deleting, How a run is applied, The result, the warnings list), the line in `references.md` on what deletes a reference, and one added sentence in `SKILL.md`'s references paragraph.
- When it lands, I'll remove bug 5 and ideas 4 and 6 from the dogfood lists and leave every other number as it is.

**Tests:**
- **AutomationTests' DrawStandInTests:** the five places that expect the warning will expect none. The `delete "X"` test gets rewritten to cover:
  - the relay goes, with its own row;
  - one with another arrow stays, and goes when the same script deletes that arrow's shape too;
  - an arrow with a free end keeps it;
  - a locked relay gives `read_only` and nothing is deleted;
  - a dry run says the same as a real one;
  - one undo brings everything back.
- **CompositionTests' DrawStandInsTests:** the same changes on the shipped references: no warning, and `delete "Checkout"` takes the reference.
- **SkillTests:** runs unchanged. The skill changes are prose only, with no new runnable examples.

After that: build, `./test.sh` (the draw tests first, then everything), a code review, then I report back.

[2026-10-08 13:33] USER:
go ahead

[2026-10-08 13:33] GIT:
git log --oneline 5cb3c5b7..main | head -20 && git rebase main && git log -1 --oneline

[2026-10-08 13:34] ASSISTANT:
Now the init: read stand-ins for deletes too.

[2026-10-08 13:34] ASSISTANT:
The code change is in; a full debug build is running while I update the tests.

[2026-10-08 13:36] ASSISTANT:
Now the `delete "X"` tests themselves.

[2026-10-08 13:38] ASSISTANT:
Now the guide's "draw" section.

[2026-10-08 13:41] ASSISTANT:
Everything passes: AutomationTests 189, CompositionTests 389 (SkillTests among them), and the rest of the suite. Committing on the branch, then the code review.

[2026-10-08 13:42] GIT:
git add -A && git commit -q -F - <<'EOF'
draw: delete "X" takes the references X's arrows leave with none, and an edge through a reference no longer warns

Drawing this repository onto a board with canvas draw turned up both (dogfood/bugs.md 5, ideas.md
4), and the owner triaged them as no-brainers on 2026-10-08. Deleting the root's cards and bands
left the 200 references their arrows had run into, standing for nothing, and no script could clear
them: a reference has no title for a script to name, so a person had to. And every edge between
boards warned that it went through a reference, though its row already says `via`: at the model's
scale some 2,400 warnings, burying the ones worth reading.

`delete "X"` now takes each reference at the other end of X's arrows that the run leaves with no
arrow, as `delete edge` already did for the arrows it takes (`standInsEmptied`), by the same rule:
an arrow from elsewhere, or a loose one, holds it; only a direct reference goes, never a query's,
which is the set `delete edge` matches; a read-only one refuses the run (`read_only`, `the
reference that delete "X" leaves with no arrow is read-only (locked, say)`); its row is `deleted`
with its kind alone, after the arrows'. A reference that stands for a deleted shape but still has
arrows from elsewhere stays: out of scope here. To tell which ends are references, a script with a
delete reads stand-ins now, so the rows of X's arrows into references name the shape each stands
for and carry `via`, as `delete edge`'s rows do, where they named the pill by where it was. The
emptied ones are found in one pass over the board's arrows, not one per reference, since the case
that found this deleted hundreds at once.

An edge that goes through a reference without `via:` says so only in its row, as one with `via:`
always did.

The command line's topic file, the guide's draw section and the canvas skill say so, and the two
dogfood items (and ideas.md 6, which pointed at bug 5) are gone, the other numbers kept.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -2

===== [2026-10-08 13:42] commit written: draw: delete "X" takes the references X's arrows leave with none, and an edge through a reference no longer warns =====

[2026-10-08 13:42] ASSISTANT:
Committed on the branch; now running the code review.

[2026-10-08 13:45] ASSISTANT:
Now the doc wording: the skill and the guide.

[2026-10-08 13:47] GIT:
git add -A && git commit -q -m "Review: which references a delete takes, said exactly; a locked reference held as shipped; Statement.isDelete

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git log --oneline -3

[2026-10-08 13:47] ASSISTANT:
Both fixes are done and reviewed, and the whole suite passes. Nothing is on main yet.

- **`delete "X"` now deletes the references X's arrows leave empty**, the same way `delete edge` already did. A reference that still has an arrow from another shape stays.
  - A locked reference refuses the run (`read_only`) and nothing is deleted.
  - Only references that stand for one shape are deleted. A query reference stays even with no arrows left.
  - The result rows for X's arrows now name the shape the reference stands for and include `via`, as `delete edge`'s rows do. Until now they named the reference by its position.
- **An edge that goes through a reference no longer warns.** Its row's `via` is the only notice now, with or without `via:` in the script.

The command-line topic file, the guide and the skill describe both changes. I removed bug 5 and ideas 4 and 6 from the dogfood lists and kept the other numbers as they were.

**Review:** it found five things. I fixed four:
- The skill's and guide's wording on which references a delete takes was too broad.
- I added a test with the shipped references: a locked reference refuses `delete "Checkout"`.
- One small cleanup in the code.

I left the fifth because it's outside what you approved: deleting a shape in the app itself (Delete, Cut) still leaves its references behind with no arrows. Only scripts clean them up.

The branch has two commits; I'll squash them into one when it lands. Main has moved once since I started, and the other sessions are editing the same dogfood lists, so expect a rebase.

[2026-10-08 13:53] USER:
Land

[2026-10-08 13:53] GIT:
git log -1 --oneline main && git merge-base HEAD main && git status --short | head

[2026-10-08 13:53] GIT:
git log -1 --format=%B a1cca633 > /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-cool-leavitt-824c8b/08db3cad-9685-4813-ae5a-e97acf8e86a5/scratchpad/msg.txt && git reset --soft b7f0858c && git commit -q -F /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-cool-leavitt-824c8b/08db3cad-9685-4813-ae5a-e97acf8e86a5/scratchpad/msg.txt && git log --oneline -2 && git status --short | head -3

[2026-10-08 13:53] ASSISTANT:
It's on main as 353cf798; I've removed the worktree and its branch.

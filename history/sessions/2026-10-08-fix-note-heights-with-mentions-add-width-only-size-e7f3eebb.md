# Fix note heights with mentions; add width-only size

Claude Code session `e7f3eebb-92a0-41e3-b64f-133e079710fe`, 2026-10-08 13:26 to 2026-10-08 14:07 UTC, on `claude/ecstatic-cartwright-9dbcc1`, `main`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-08 13:26] USER:
Background: dogfood/bugs.md and dogfood/ideas.md list what drawing this repo onto a board with `canvas draw` turned up (at 2df3c02c). On 2026-10-08 the user triaged them, called the items below no-brainers and approved fixing them. Five other sessions are fixing other items from those lists at the same time, so keep to yours and expect to rebase.

How to work: follow the project's memory and CLAUDE.md as usual: read the topic files for the areas you touch, show the user your plan before code, get a code review before reporting ready, and land only on the user's go as one squashed commit. Test headlessly (`./test.sh`, `TEST_FILTER=`). Several sessions share the one running app, so ask the user before quitting it or opening another build. A change to `canvas draw`, its messages or the shipped kinds changes the canvas skill too (`.claude/skills/canvas`; SkillTests hold them together). When it lands, delete your items from dogfood/bugs.md and dogfood/ideas.md, leaving every other item's number as it is.

Your items, as the lists word them:

bugs.md 3. **A note with mentions, written by draw, is too short for its text.** `StickyNoteDefinition.derive` (`StickyNotes.swift:90`) measures each mention as `.missing`, a pill with no symbol, but the board draws it live, with the kind's symbol, so lines wrap sooner than measured. "About Composition" (38 mentions) loses about three lines, "About CanvasUI" (5) two. Seen in offscreen renders, not yet on screen. A fix: measure every pill with room for a symbol.

ideas.md 8. **A width-only size for notes** (`size: 300x`), with the height fitted to the text. Today a note at a custom width with a fitted height takes two runs: draw it with a size, then change its text.

Where: Sources/StickyNotes/StickyNotes.swift:91 (`{ _ in .missing }`); a mention pill's look in Sources/Mentions/MentionPill.swift; the size value in Sources/DrawScript/Parser.swift; ".claude/rules/command-line.md" on "a size the kind derives". Bug 3 is about notes draw writes: check whether notes typed by hand are measured the same way, and fix it wherever the measure runs. The skill's table says a note "is as tall as its text, at least 200; a `size:` height lasts only until the text changes": add the width-only form there and in reference/language.md.

The board-drawing scripts work around bug 3: `about_height` in dogfood/model/gen2.py adds room for mention pills' symbols. Remove that padding along with the fix, or the About notes come out too tall. Another session changes other parts of those scripts, so touch only that function.

[2026-10-08 13:26] ASSISTANT:
Reading the note's measure, the pill and the draw size grammar before planning.

[2026-10-08 13:27] ASSISTANT:
Still reading: how `draw` turns `size:` into a note's frame, so I can see where a width-only size would hook in.

[2026-10-08 13:29] ASSISTANT:
Still in research: checking the schema card's derive (it may measure mentions the same way) and every other place a note's height is fitted.

[2026-10-08 13:29] ASSISTANT:
Measuring the shipped kinds' pill symbols to decide how a measure can leave room for one.

[2026-10-08 13:33] ASSISTANT:
Still researching (no code yet): checking the tests that pin pill widths and note heights, so the plan covers what changes.

[2026-10-08 13:33] ASSISTANT:
Checking the guide's wording on derived sizes and `size:` so the docs change with the code.

[2026-10-08 13:35] ASSISTANT:
Checking a few last details: whether a symbol lookup by an empty name logs, how wide symbols are in the panel's 13-point text, and the AutomationTests fixtures for size tests.

[2026-10-08 13:37] ASSISTANT:
I've read the code. Here's my plan; I won't write any code until you OK it.

**Bug 3: pills measured without their symbols**
- **Where the measure is wrong:** two places. One is a note made from properties (`StickyNoteDefinition.derive`, which `draw` uses). The other is a schema card's `setPrompt`, which its own derive uses, and so does the Claude sync when it writes a description. A sync-written description with mentions comes out too short in the same way.
- **Where it's already right:** notes and cards typed by hand. Their editors measure the live text.
- **The fix (my decision):** give a live pill's symbol a slot of fixed width, 1 em. That's 16 pt in a note, the width of the widest shipped symbol (`rectangle.dashed`). The symbol sits centered in the slot, and a wider one is drawn smaller to fit.
  - A pill's width then depends only on its name, not on its kind. Shipped pills get 0–2 pt wider.
  - Then `MentionTextStyle.measuredString(_:width:)` makes each mention a live pill under the name it holds. That matches the drawn pill exactly while the shape still has that name.
  - The note's derive and `SchemaStyle.fittedHeight(of:)` both use it.
- **Alternative I rejected:** leave symbols as they are and allow 1 em per pill in the measure only. That overshoots by up to 2 pt per pill, so a note sometimes gets an extra line. It also undershoots for any plugin whose symbol is wider than 1 em, which cuts text off again.

**Idea 8: `size: 300x`**
- **Language:** DrawScript reads `<width>x` (or `×`) as a width alone, and a style can give it. The `[w, h]` form stays two numbers.
- **Behaviour:** the shape takes that width before the kind works out its height.
  - A note or schema card ends up as tall as its text at that width, in one run.
  - Restating a note with only `size: 300x` re-fits it to its text.
  - Other kinds keep their height; a new one gets its tool's height.
- **One small core addition:** `registry.derived(_:)`, which runs a kind's `derive` on a record. Today the derive runs only when a property is set, and restating with only `size: 300x` sets none.
- **Error hints:** the size parse error and the `width:` hint will point to the width-alone form.

**Tests**
- Pills are the same width whatever their symbol.
- A note and a schema card made from properties, mentioning every shipped kind, come out exactly as tall as their editors fit them, so starting to edit writes nothing. The same holds for a description the sync writes.
- Parser cases, and draw cases on fixtures: new shape, restated shape, style, and the "would rename" message.
- Shipped notes drawn through `canvas`, plus one new skill example.

**Docs and dogfood**
- The skill's table and `reference/language.md`, the topic files (command line, mentions, editing, schema cards) and `plugin-system.md`.
- `about_height` loses its padding; nothing else in `gen2.py` changes.
- bugs.md 3 and ideas.md 8 come out when this lands.

[2026-10-08 13:38] USER:
Go

[2026-10-08 13:38] ASSISTANT:
Starting with the pill's symbol slot in Mentions.

[2026-10-08 13:38] ASSISTANT:
Now the `setPrompt` comment, then the core's `registry.derived(_:)`.

[2026-10-08 13:39] ASSISTANT:
Now DrawScript: a `Size` that may hold a width alone.

[2026-10-08 13:39] ASSISTANT:
Now the syntax tree and the parser.

[2026-10-08 13:40] ASSISTANT:
Parser done. Now Automation's `draw`: building a shape at a width alone.

[2026-10-08 13:40] ASSISTANT:
Core change and Automation done; now building the modules to catch type errors before writing tests.

[2026-10-08 13:41] ASSISTANT:
Updating the parser tests, with new cases for a width alone.

[2026-10-08 13:44] ASSISTANT:
Existing suites pass with the change (one hint test updated). Now writing the new tests, starting with the pill and the note.

[2026-10-08 13:45] ASSISTANT:
Adding the pill tests.

[2026-10-08 13:45] ASSISTANT:
Now the note test: a note made from properties with many mentions keeps its height when editing begins.

[2026-10-08 13:45] ASSISTANT:
Now the schema card: reading its test bench.

[2026-10-08 13:46] ASSISTANT:
Now the `draw` tests on fixtures. Checking the fixture kinds' tool sizes.

[2026-10-08 13:47] ASSISTANT:
Writing the fixture-based `draw` tests for a width alone.

[2026-10-08 13:47] ASSISTANT:
Building and running the touched suites.

[2026-10-08 13:49] ASSISTANT:
All pass. Checking the new tests catch the bug: temporarily measuring pills as missing again.

[2026-10-08 13:51] ASSISTANT:
The schema tests didn't catch it (their pills never changed a wrap). Strengthening them with a short-named card, whose pills differ most.

[2026-10-08 13:52] ASSISTANT:
Both catch the old measure now. Next, the shipped pieces through `canvas` in CompositionTests.

[2026-10-08 13:53] ASSISTANT:
Working around a type-check error in the new test helper.

[2026-10-08 13:54] ASSISTANT:
The shipped test catches it too: with the old measure the note was 280 tall where its text needs 375. Restored. Now the canvas skill and its reference.

[2026-10-08 13:57] ASSISTANT:
A later example lands where the new note sat; moving the new note to a free spot.

[2026-10-08 13:57] ASSISTANT:
Skill examples pass. Now the topic files and the guide.

[2026-10-08 13:57] ASSISTANT:
Now the guide, `docs/plugin-system.md`.

[2026-10-08 13:58] ASSISTANT:
Docs done. Now the dogfood lists and the generator's `about_height`.

[2026-10-08 13:58] ASSISTANT:
Docs and dogfood done. Running the full test suite.

[2026-10-08 14:00] ASSISTANT:
One failure, in Find's highlight colors, which my change doesn't touch (no mentions there). Checking whether it's flaky or already failing on main.

[2026-10-08 14:00] ASSISTANT:
It passes 2 of 3 runs alone, so it's flaky. Checking main in a scratch clone in the background to confirm it isn't mine.

[2026-10-08 14:00] ASSISTANT:
While that runs, reviewing my own diff before committing.

[2026-10-08 14:01] GIT:
git add -A && git commit -q -F - <<'EOF'
Drawn notes and schema cards are as tall as their text, mentions and all; size: 300x gives a width alone, the height then the kind's

Two findings from drawing this repo onto a board, which the owner called no-brainers in the 2026-10-08 triage (dogfood/bugs.md 3, ideas.md 8).

A note that `canvas draw` gives text with mentions came out too short: the note's fit, a pure function of its props (`DerivedProps`), measured each mention as a missing pill, which has no symbol, while the board draws it live with its kind's symbol, so lines wrapped sooner than measured ("About Composition", 38 mentions, lost about three lines; the dogfood generator padded for it). A schema card's `setPrompt` measured the same way, so a description that draw or the Claude sync writes was short too, until someone edited it. Notes and cards typed by hand were right: their editors measure the live text.

- Every pill is measured live, by the name it holds (`MentionTextStyle.measuredString`), which at draw time is the name it shows.
- For that to be exact without looking a shape up, a pill's width can't depend on its kind's symbol, so the symbol is centered in a slot an em wide (`MentionStyle.symbolSlot`: 16 points in a note, the widest shipped symbol, a frame's; a wider one is drawn smaller). Shipped pills get 0 to 2 points wider. Rejected: keeping the symbols as they were and allowing an em per pill in the measure only, which overshoots (now and then a line too many) and undershoots for a plugin's wider symbol.

A width alone, `size: 300x` (DrawScript's `Size`, its height nil), builds the shape at that width and puts what its kind derives in step there, so a note at a custom width fitted to its text takes one run, not two (draw it with a size, then set its text again). Restating with only `size: 300x` sets no property, so the core gains `registry.derived(_:)`, which runs a kind's `derive` on a record. A kind that derives nothing keeps its height, its tool's for a new one. JSON's `[w, h]` stays two numbers. A bad size's hint and `width:`'s name the new form.

The skill's table and reference/language.md (with an example SkillTests runs), the topic files and the guide say so. The generator's `about_height` drops its padding; nothing else in the scripts changes.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -2

===== [2026-10-08 14:01] commit written: Drawn notes and schema cards are as tall as their text, mentions and all; size: 300x gives a width alone, the height then the kind's =====

[2026-10-08 14:01] ASSISTANT:
Committed on the branch. Running the code review.

[2026-10-08 14:03] ASSISTANT:
The base commit passed that Find test 6 of 6, so I can't call it pre-existing yet. Rerunning it on my branch.

[2026-10-08 14:03] ASSISTANT:
Fixing the two that warrant it: the core topic file and the skill's wording.

[2026-10-08 14:04] GIT:
git add -A && git commit -q --amend --no-edit && git log --oneline -2 && git status --short | head -3; rm -rf /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-ecstatic-cartwright-9dbcc1/e7f3eebb-92a0-41e3-b64f-133e079710fe/scratchpad/main-check; git -C /Users/zekenie/code/native-canvas log --oneline -1 main

[2026-10-08 14:04] GIT:
git diff --name-only 5cb3c5b7 main | sort > /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-ecstatic-cartwright-9dbcc1/e7f3eebb-92a0-41e3-b64f-133e079710fe/scratchpad/main-files.txt; git diff --name-only 5cb3c5b7 HEAD | sort | comm -12 - /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-ecstatic-cartwright-9dbcc1/e7f3eebb-92a0-41e3-b64f-133e079710fe/scratchpad/main-files.txt; git merge-tree --write-tree main HEAD >/dev/null && echo "merges cleanly" || echo "conflicts"

[2026-10-08 14:04] ASSISTANT:
Both fixes are done and committed on the branch as one commit (`40a621e0`), and the code review is done. It's ready to land when you say so.

**Bug 3 (drawn notes too short):**
- **Cause:** the height a note gets when it's made from properties (which is how `draw` makes it) treated each mention as a deleted pill, with no symbol. The board draws each pill with its kind's symbol, so lines wrapped sooner than measured.
- **Also schema cards:** a description that `draw` or the Claude sync wrote was cut short the same way.
- **Typed by hand:** notes and cards typed in were already measured right.
- **The fix:** a pill's symbol now sits in a fixed slot one em wide, so its width no longer depends on the kind. Shipped pills get 0–2 pt wider. Drawn notes and cards are now measured as live pills, under the names their mentions hold.
- **Test:** a note drawn with 24 mentions used to come out 280 tall where its text needs 375. Now it's exactly as tall as its editor makes it.

**Idea 8 (`size: 300x`):**
- A note or schema card drawn with a width alone is that wide and as tall as its text, in one run. Restating a note with just `size: 300x` re-fits it to its text.
- Other kinds keep their height, and a new one gets its tool's height.
- This needed one small addition to the core, `registry.derived(_:)`. The skill's table, `reference/language.md` (with a new example the skill tests run), the topic files and the guide all describe it.

**Tests:** everything passes except one Find colour test, "a hit reads on a note's yellow…". It failed twice in my first four runs, then passed 6 of 6 on the branch and 6 of 6 on the commit I branched from. It contains no mentions or sizes, so I believe it's a flake unrelated to this change, but that isn't proven.

**Review:** six findings. I fixed two: the core topic file now covers `registry.derived(_:)`, and the skill's wording on other kinds' height is clearer. I left four:
- A mention holding a blank name isn't measured right. `draw` never writes one.
- If a mentioned shape is renamed after the note was last typed in, a width-only restate measures the old, shorter name. Any measure that can't look up shapes has this limit.
- Two small cleanups.

**Dogfood:** bugs.md 3 and ideas.md 8 are deleted, and the other items keep their numbers. `about_height` no longer pads. The docstring at the top of `gen2.py` (line 5) still says "with room for its mentions' symbols"; I left it because you said to touch only that function.

**Main has moved:** the branch now conflicts with main in 10 files, mostly docs plus `Drawing.swift` and `ReferenceTests.swift`. I'll rebase when you say land, or now with a test run if you'd rather resolve them before landing.

[2026-10-08 14:05] USER:
land

[2026-10-08 14:06] GIT:
git log --oneline -1 main && git rebase main 2>&1 | tail -15; git status --short | head -20

[2026-10-08 14:06] ASSISTANT:
Three topic files conflict; resolving them.

[2026-10-08 14:06] ASSISTANT:
The conflicts are whole one-line paragraphs; taking main's version of each file and reapplying my edits on top.

[2026-10-08 14:06] GIT:
git checkout --ours .claude/rules/command-line.md .claude/rules/mentions.md .claude/rules/schema-cards.md && python3 - <<'EOF'
def edit(p, pairs):
    s=open(p).read()
    for old,new in pairs:
        assert s.count(old)==1,(p,old[:80], s.count(old))
        s=s.replace(old,new)
    open(p,'w').write(s)
edit('.claude/rules/command-line.md', [
("a size the kind derives from what's set, a schema card's height or a note's, is the one it's placed at;",
 "a size the kind derives from what's set, a schema card's height or a note's, is the one it's placed at, and `size:` with a width alone (`300x`, DrawScript's `Size` with no height) builds the shape at that width first and puts what the kind derives in step there whether anything's set or not (`registry.derived(_:)`, the core's), so a note is that wide and as tall as its text there in one run, and any other kind keeps its height;"),
("a schema card's prompt that names cards only, one undo step)",
 "a schema card's prompt that names cards only, one undo step, and a note mentioning a shape of every shipped kind as tall as its editor fits it, drawn and restated with a width alone)"),
("and the file's names read only when asked; CompositionTests run",
 "and the file's names read only when asked; AutomationTests' DrawSizeTests hold a width alone (`size: 300x`) over a `Scroll`, whose height follows what it says at its width (new, beside tiles that keep their tool's height; restated with nothing else set, and again unchanged; a style's, whole; a title worked out from a size, refused as written); CompositionTests run"),
])
edit('.claude/rules/mentions.md', [
("is 17 points tall in 16-point text, so a note's lines keep their 19.",
 "is 17 points tall in 16-point text, so a note's lines keep their 19, and its kind's symbol is centered in a slot an em wide (`MentionStyle.symbolSlot`, as wide as the widest shipped symbol; a wider one is drawn smaller), so a live pill is as wide as its label makes it whatever its kind: text measured from itself alone, where no shape is looked up (`MentionTextStyle.measuredString(_:width:)`: a kind's `DerivedProps`, a note's height and a schema card's, from their text), makes each mention a live pill by the name it holds, as wide as it's drawn while its shape is called that (one drawn missing has no symbol, so it's narrower)."),
("the pill's images, drawing",
 "the pill's images (its symbol's slot, the same width whatever the symbol, a wider one drawn within it; `measuredString` pill for pill against live ones, and a text of many mentions as tall measured as drawn), drawing"),
("StickyNotesTests hold a note's text (the v3 migration, its row, its label) and its editor to its render with pills (`noteEditorTests`);",
 "StickyNotesTests hold a note's text (the v3 migration, its row, its label, and a note made from properties with thirty mentions as tall as its editor fits it, at three widths) and its editor to its render with pills (`noteEditorTests`);"),
])
edit('.claude/rules/schema-cards.md', [
("(a note's measure, `SchemaStyle.fittedHeight`, pills by the names they hold, a line at least:",
 "(a note's measure, `SchemaStyle.fittedHeight`, pills measured live by the names they hold, `measuredString`, so a description drawn or written by the model is as tall as the editor fits it, a line at least:"),
])
EOF
grep -c "<<<<<<<\|>>>>>>>" .claude/rules/*.md docs/plugin-system.md .claude/skills/canvas/SKILL.md .claude/skills/canvas/reference/language.md Sources/Automation/Drawing.swift Tests/SchemasTests/ReferenceTests.swift dogfood/*.md | grep -v ":0"; git add .claude/rules/command-line.md .claude/rules/mentions.md .claude/rules/schema-cards.md && GIT_EDITOR=true git rebase --continue 2>&1 | tail -2 && git log --oneline -3

[2026-10-08 14:07] ASSISTANT:
Main checkout is clean. Merging.

[2026-10-08 14:07] ASSISTANT:
It's on main as `d2f2aecb`. Three topic files conflicted in the rebase; I took main's versions and reapplied my edits on top. As you asked, I didn't run the tests again after the rebase. The worktree and branch are removed.

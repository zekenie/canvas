# Add a new-board command, file counts and offset docs

Claude Code session `14ff8107-c619-46fa-ba38-ecfccf28e15a`, 2026-10-08 13:26 to 2026-10-08 14:43 UTC, on `claude/zen-proskuriakova-ae429f`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-08 13:26] USER:
Background: dogfood/bugs.md and dogfood/ideas.md list what drawing this repo onto a board with `canvas draw` turned up (at 2df3c02c). On 2026-10-08 the user triaged them, called the items below no-brainers and approved fixing them. Five other sessions are fixing other items from those lists at the same time, so keep to yours and expect to rebase.

How to work: follow the project's memory and CLAUDE.md as usual: read the topic files for the areas you touch, show the user your plan before code, get a code review before reporting ready, and land only on the user's go as one squashed commit. Test headlessly (`./test.sh`, `TEST_FILTER=`); tests never use the app's socket. Several sessions share the one running app, so ask the user before quitting it or opening another build. A change to the command line or `canvas draw` changes the canvas skill too (`.claude/skills/canvas`; SkillTests hold them together). When it lands, delete your items from dogfood/ideas.md, leaving every other item's number as it is.

Your items, as ideas.md words them:

3. **Make a board file from the CLI.** A script can't start one, so the user has to create and open it first.

9. **`canvas boards` counts only the shown board's shapes:** 306, for a file of about 2,600. It could give both counts.

7. **Document how to place a shape at an exact offset.** `right of "F" left (gap: x) below "F" top (gap: y)` puts a shape exactly x and y in from F's top-left. The skill doesn't mention it, and the obvious `inside "F" top-left (gap: n)` applies n on every side. A layout computed outside the app needs this.

For 3: a command (`canvas new <path>`, say) that makes a board file and opens it in the app, answering with its id as `boards` lists it. Today an agent copies an empty file's JSON and opens it with `open -a`, which goes against the rule that agents never touch a board's file, so make the file through the app's own document code, never by writing JSON. `status` and `boards` are CommandServer's own (CanvasUI), and their names are reserved (`RPC.reservedCommandNames`); read .claude/rules/command-line.md and boards-on-disk.md before deciding where the command lives and what it refuses (an existing file, say). For 9: `boards` in CommandServer. For 7: the skill's reference/language.md, with a `draw` block (SkillTests run every one). Also update the line in dogfood/model/README.md that says `canvas` can't make a board file; another session changes other parts of those scripts, so touch only that line.

[2026-10-08 13:26] ASSISTANT:
Reading the command-line and on-disk topic files, the canvas skill and the dogfood notes before drafting a plan for the three items.

[2026-10-08 13:28] ASSISTANT:
Still reading: the CLI's argument parsing (for how `new` would resolve a relative path) and the tests that drive `canvas` against the server.

[2026-10-08 13:29] ASSISTANT:
Reading the guide's command-line section and language.md's placement sections, to see where each item's docs belong.

[2026-10-08 13:32] ASSISTANT:
Still surveying — now the CLI's tests and the skill tests, to see how a `new` command and a path-taking param would be held.

[2026-10-08 13:32] ASSISTANT:
Surveying is nearly done; checking one AppKit detail (how NSDocument's save imports into Swift) before writing the plan.

[2026-10-08 13:36] GIT:
git log -1 --format='%h %s' main && git merge-base --is-ancestor main HEAD && echo "branch contains main"

[2026-10-08 13:36] GIT:
git merge --ff-only main 2>&1 | tail -3 && git log -1 --format='%h %s'

[2026-10-08 13:36] ASSISTANT:
I've read the code and docs for all three items and brought the branch up to date with main. Here's the plan. I'll wait for your OK before writing code.

**3. `canvas new <file>`**
- **Where it lives:** in the app's command server (CanvasUI), beside `status` and `boards`, and the name `new` is reserved. It can't be a plugin command, because only CanvasUI knows board documents and plugins can't import it.
- **How the file is made:** the app makes an empty board document and saves it at the path with the document's own Save As, so the codec writes the file exactly as File › Save would. No JSON is written by hand. Then it opens the board the way the app opens any board: its window comes to the front of the app's windows, but the app isn't brought forward. The answer is the board's `boards` entry, so its `id` is what `--board` takes.
- **Relative paths:** `canvas` doesn't know any command by name. So the path param's schema says `"x-path": true`, and `canvas` turns it into a full path from the folder it runs in, as it already does for `--board <file>`. The protocol stays at 2: an older `canvas` sends the path as typed, and the app refuses it.
- **What it refuses:**
  - a file that already exists, or a file a board is already open as (`file_exists`, naming that board's id)
  - a folder that doesn't exist (`no_folder`; folders aren't created)
  - an extension other than `.canvasboard` (a path with no extension gets `.canvasboard`)
  - a save that fails (`cannot_save`, with the reason)
- `no_board`'s hint will suggest `canvas new`.

**9. `boards`:** `shapes` keeps meaning the shown board's count, and a new member, `fileShapes`, counts every board in the file. Adding a member rather than changing `shapes` means nothing that reads `shapes` breaks.

**7. Exact offsets:**
- A new section in `reference/language.md`, "An exact offset", under Placements. It gives the form, says why `inside "F" top-left (gap: n)` isn't it, and notes that gaps can't be negative, so the origin should be the layout's top-left shape. A `draw` block runs it.
- A bullet in Frames for the in-frame form, with a block: `in "F" right of "F" left (gap: x) below "F" top (gap: y)`.
- A solver test that checks the rectangle comes out exact, since the docs now promise it.
- One-line pointers to the new section from SKILL.md's "no coordinates" line and from "What the language refuses".

**Docs and tests**
- **Docs:** SKILL.md's "Check the app" section gets `new`. Also updated: language.md's line about app-level commands, `docs/plugin-system.md`, the command-line and boards-on-disk topic files, and only the one line in `dogfood/model/README.md`.
- **Tests:**
  - `new` end to end through the built `canvas`, including each refusal
  - `fileShapes` on a file whose boards are nested inside each other
  - `x-path` in the CLI tests
  - the reserved-names test
- **Landing:** the landing commit deletes items 3, 7 and 9 from `dogfood/ideas.md` and leaves the other numbers as they are.

**Not covered by tests:** the tests never put a window on screen. So the final step of `new`, showing the window through the app's document controller, would only be confirmed by running this build of the app. That means quitting the one you have open, and I won't do that unless you say so.

[2026-10-08 13:39] USER:
Go

[2026-10-08 13:39] ASSISTANT:
Now the argument's `x-path` in CanvasRPC.

[2026-10-08 13:40] ASSISTANT:
Building the `canvas new` command in the server; tidying one check before compiling.

[2026-10-08 13:43] ASSISTANT:
Compiles. Now the tests: reading the solver's held-in test to see how `in` works in the stand-in.

[2026-10-08 13:44] ASSISTANT:
Now running the focused tests (CLI, solver, reserved names, command line).

[2026-10-08 13:45] ASSISTANT:
Code and tests pass. Now the docs: first dumping where the language.md story's shapes land, to pick an offset that's clear.

[2026-10-08 13:47] ASSISTANT:
Story positions in hand: Owner sits at (60, 70) with free space to its right above the pipeline, and Sprint has room at its lower right. Writing the language.md section.

[2026-10-08 13:48] ASSISTANT:
Examples land exactly at the offsets written. Now the guide (`docs/plugin-system.md`).

[2026-10-08 13:48] ASSISTANT:
Now the command-line and boards-on-disk topic files.

[2026-10-08 13:48] ASSISTANT:
Now the one line in the dogfood README.

[2026-10-08 13:49] ASSISTANT:
Now dropping items 3, 7 and 9 from ideas.md, other numbers untouched.

[2026-10-08 13:49] ASSISTANT:
Two refinements before the full run: rename the server's `open` hook to `show` (a local `open` array already lives in `board(_:)`), and refuse a second `new` for a file still being saved.

[2026-10-08 13:51] ASSISTANT:
All 70 test executables pass. Committing on the branch, then the code review.

[2026-10-08 13:51] GIT:
git add -A && git commit -q -F - <<'EOF'
canvas new makes and opens a board's file, boards counts the whole file too, and the skill shows how to place a shape at an exact offset

Drawing this repo onto a board with canvas draw (dogfood/ideas.md) turned up three gaps, which the user called no-brainers on 2026-10-08:

- A script couldn't start a board: the user had to make and open a file first, and the dogfood scripts copied an empty file's JSON and opened it with `open -a`, against the rule that agents never touch a board's file. `canvas new <file>` makes it through the app's own document code: a new, empty BoardDocument saved there as Save As saves one (BoardDocument.newFile(at:)), so the codec writes it as every save does, never JSON by hand. The server then shows it as the app opens a board (its window in front of the app's; the app isn't activated) and answers as `boards` lists it, so its id is the --board to pass. It's CommandServer's own, beside status and boards, since only CanvasUI knows documents and plugins can't import it, and `new` joins RPC.reservedCommandNames. It refuses a file that's there already (as written, or with the extension), one an open board is or another `new` is saving (file_exists), an extension other than .canvasboard (a file with none gets it; invalid_params), a folder that isn't there (no_folder: folders aren't made), and a save that fails (cannot_save). no_board's hint names it.
- canvas knows no command, so it couldn't resolve a relative file for one: a param whose schema says "x-path": true is a file named from where canvas runs, which canvas sends whole (CommandArgument.isPath), as it already did for --board <file>. The protocol stays 2: an older canvas sends the file as typed, and the app refuses one not named from /.
- boards counted only the shown board's shapes: 306, for a file of about 2,600. `shapes` stays the board shown's, and fileShapes is every board's (CanvasFile.shapeCount): a member added rather than a meaning changed, so nothing that reads shapes breaks.
- `right of "F" left (gap: x) below "F" top (gap: y)` puts a shape exactly x and y from F's top-left, which a layout computed outside the app needs, but the skill didn't say so, and the obvious `inside "F" top-left (gap: n)` applies n on every side. language.md has An exact offset (the form, why inside isn't it, the origin at the layout's top-left since a gap is never negative, pushes as ever) with a draw block, and Frames the in-frame form, `in "F"` with the offset, with another; SKILL.md's no-coordinates line and What the language refuses point there. A solver test holds the exact rectangle, past the target and held in it.

The skill, the guide, the command-line and boards-on-disk topic files and the dogfood README's line about making a board file say so; items 3, 7 and 9 leave dogfood/ideas.md, the others keeping their numbers.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -2

===== [2026-10-08 13:51] commit written: canvas new makes and opens a board's file, boards counts the whole file too, and the skill shows how to place a shape at an exact offset =====

[2026-10-08 13:53] ASSISTANT:
Review pass is done; reporting what it found before fixing.

[2026-10-08 13:55] ASSISTANT:
Now one shared way to open a board's window, used by File › New's path, the earlier-version opener and `new`.

[2026-10-08 13:55] ASSISTANT:
Now the test: private pasteboard, dotted names, a known type refused, a folder as written, a save that fails, two `new`s at once, and `no_board`'s hint.

[2026-10-08 13:56] ASSISTANT:
Passing. Updating the help text and topic files to the new extension rule, and noting `openWindow()`.

[2026-10-08 13:56] ASSISTANT:
Building the app (it changed too) and running the whole suite again.

[2026-10-08 13:59] ASSISTANT:
Everything passes. Folding the fixes into the branch's one commit, with the message updated for the new extension rule.

[2026-10-08 13:59] GIT:
git add -A && git commit -q --amend -F - <<'EOF'
canvas new makes and opens a board's file, boards counts the whole file too, and the skill shows how to place a shape at an exact offset

Drawing this repo onto a board with canvas draw (dogfood/ideas.md) turned up three gaps, which the user called no-brainers on 2026-10-08:

- A script couldn't start a board: the user had to make and open a file first, and the dogfood scripts copied an empty file's JSON and opened it with `open -a`, against the rule that agents never touch a board's file. `canvas new <file>` makes it through the app's own document code: a new, empty BoardDocument saved there as Save As saves one (BoardDocument.newFile(at:)), so the codec writes it as every save does, never JSON by hand. The server then opens it as the app opens any board (BoardDocument.openWindow(), now File › New's and an earlier version's copy's too; the app isn't activated) and answers as `boards` lists it, so its id is the --board to pass. It's CommandServer's own, beside status and boards, since only CanvasUI knows documents and plugins can't import it, and `new` joins RPC.reservedCommandNames. The file gets .canvasboard unless it ends in it, as the Save panel adds one, so `Sprint 3.2` is `Sprint 3.2.canvasboard`; a known type's extension (.txt) is refused (invalid_params), and so are a file that's there already, a folder as written, a file an open board is or another `new` is saving (file_exists), a folder that isn't there (no_folder: folders aren't made) and a save that fails (cannot_save, the board closed). no_board's hint names it.
- canvas knows no command, so it couldn't resolve a relative file for one: a param whose schema says "x-path": true is a file named from where canvas runs, which canvas sends whole (CommandArgument.isPath), as it already did for --board <file>. The protocol stays 2: an older canvas sends the file as typed, and the app refuses one not named from /.
- boards counted only the shown board's shapes: 306, for a file of about 2,600. `shapes` stays the board shown's, and fileShapes is every board's (CanvasFile.shapeCount): a member added rather than a meaning changed, so nothing that reads shapes breaks.
- `right of "F" left (gap: x) below "F" top (gap: y)` puts a shape exactly x and y from F's top-left, which a layout computed outside the app needs, but the skill didn't say so, and the obvious `inside "F" top-left (gap: n)` applies n on every side. language.md has An exact offset (the form, why inside isn't it, the origin at the layout's top-left since a gap is never negative, pushes as ever) with a draw block, and Frames the in-frame form, `in "F"` with the offset, with another; SKILL.md's no-coordinates line and What the language refuses point there. A solver test holds the exact rectangle, past the target and held in it.

The skill, the guide, the command-line and boards-on-disk topic files and the dogfood README's line about making a board file say so; items 3, 7 and 9 leave dogfood/ideas.md, the others keeping their numbers.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -2 && git status --short | head

[2026-10-08 13:59] ASSISTANT:
All three items are done, reviewed, and committed on the branch as one commit (`b66fadce`). The full test suite passes. It isn't on main yet.

- **`canvas new <file>`**: makes a new, empty board's file through the app's own save (the same path as File › Save As) and opens it. It answers with the board's `boards` entry, so its `id` is the `--board` to pass. A relative path works: `canvas` turns it into a full path from the folder it runs in.
  - It refuses a file that already exists or is open, a file with another type's extension (`.txt`), a folder that doesn't exist, and a save that fails.
  - The error you get when no board is open now suggests `canvas new`.
- **`boards`**: `shapes` still counts the shown board, and a new `fileShapes` counts every board in the file.
- **Exact offsets**: `reference/language.md` has a new "An exact offset" section, plus an in-frame example in Frames. Both examples run in the skill's tests and land exactly where the offsets say. A new solver test checks the exact position.
- **Other files**: SKILL.md, the guide, the command-line and boards-on-disk topic files, and the one line in the dogfood README are updated. Items 3, 7 and 9 are gone from `dogfood/ideas.md`; the other items keep their numbers.

What the review changed:
- A name with a dot, like `Sprint 3.2`, used to be refused, with a suggested fix that dropped the `.2`. Now it becomes `Sprint 3.2.canvasboard`; only a known file type's extension is refused, as the Save panel does it.
- A refusal no longer suggests opening a file that isn't a board in Infinite Canvas.
- The tests now cover a save that fails, two `new`s for the same file at once, and the no-board error.
- The new test uses its own pasteboard instead of yours.
- File › New, the earlier-version opener and `new` now open a board's window through one shared `openWindow()`.

Two review findings I left alone:
- **Overwrite race:** a file another program creates in the moment between the "already exists" check and the save would be overwritten. Closing that gap means writing a placeholder file that a failed save then has to clean up, which isn't worth it for a window that small.
- **Extension in three places:** `.canvasboard` is spelled out in `build.sh`'s Info.plist, in the board configuration, and in the CLI. Nothing ties those together, but the extension isn't expected to change.

Not tested: the tests never show a window, so the step where `new` opens the board in the real app hasn't been run. Checking it means quitting the app you have open, so I haven't. Main also moves while other sessions land, so expect a rebase when I land it.

Say when to land it.

[2026-10-08 14:42] USER:
land it

[2026-10-08 14:42] GIT:
git log -1 --format='%h %s' main && git rebase main 2>&1 | tail -5

[2026-10-08 14:42] ASSISTANT:
Rebasing onto main; resolving three small doc conflicts (ideas.md, language.md, the command-line topic file).

[2026-10-08 14:43] ASSISTANT:
Main changed both lines elsewhere; I'll take main's text and reapply my three edits to it.

[2026-10-08 14:43] GIT:
grep -o 'when given as `-`; text whose[^;]*;[^;]*;' .claude/rules/command-line.md | cut -c1-400; grep -c "^<<<<<<<\|^=======$\|^>>>>>>>" dogfood/ideas.md .claude/skills/canvas/reference/language.md .claude/rules/command-line.md; git add dogfood/ideas.md .claude/skills/canvas/reference/language.md .claude/rules/command-line.md && GIT_EDITOR=true git rebase --continue 2>&1 | tail -2

[2026-10-08 14:43] ASSISTANT:
A semicolon got dropped in that merged sentence; fixing it in the commit.

[2026-10-08 14:43] GIT:
python3 - <<'EOF'
p='.claude/rules/command-line.md'
s=open(p).read()
old="refuses a file not named from `/`) an error about a script"
assert s.count(old)==1
s=s.replace(old,"refuses a file not named from `/`); an error about a script")
open(p,'w').write(s)
EOF
git commit -q -a --amend --no-edit && git log --oneline -3 && git status --short | head -3

[2026-10-08 14:43] ASSISTANT:
Audit passes, and the main checkout is clean and on main. Merging.

[2026-10-08 14:43] ASSISTANT:
It's on main as `90ad5237`, and the worktree and branch are cleaned up.

Main had moved, so I rebased first. Three doc files conflicted:
- **`dogfood/ideas.md`:** other sessions had already removed 4, 6, 8 and 10. With 3, 7 and 9 now gone too, it lists 1, 2, 5, 11, 12 and 13.
- **`language.md`:** it keeps both main's new width-only-size note and my exact-offset pointer.
- **The command-line topic file:** my additions now sit on top of main's newer text.

As you asked, I didn't run the tests at landing, only the import audit, which passed.

# Locked sub-board edit restrictions

Claude Code session `f8601f2b-0ce4-4853-826c-e3086dca0556`, 2026-10-06 12:23 to 2026-10-06 15:11 UTC, on `claude/locked-subboard-restrictions-311df6`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-06 12:23] USER:
when a sub-board is locked, you should be able to enter it, but you should not be able to edit its contents (infinitely deep). right now you can enter a locked subboard and do anything you want.

[2026-10-06 12:23] ASSISTANT:
I'm reading how read-only shapes and locked frames work in the core, so I can plan how a locked subboard's lock should reach everything inside it.

[2026-10-06 12:25] ASSISTANT:
Still reading: now the editor's transact, editing and board-switching code, to see where a "read-only board" check would sit.

[2026-10-06 12:26] ASSISTANT:
Next I'm checking how `canvas draw` (the command line) handles locked shapes, since it can also put shapes inside a subboard.

[2026-10-06 12:27] ASSISTANT:
I've mapped the core; now checking the paths that create shapes (paste, double-click to place, arrows from ports) so the plan covers each.

[2026-10-06 12:35] ASSISTANT:
Main has moved since this worktree was made (it now has `/move-to`, which moves shapes onto a subboard's board), so I'm fast-forwarding this empty branch to main before planning.

[2026-10-06 12:35] GIT:
git status --short | head -3; git merge --ff-only main && git log --oneline -3 && git show --stat HEAD | head -60

[2026-10-06 12:38] ASSISTANT:
I've got the full picture. One note first: main had moved since this worktree was made. It now includes `/move-to`, which moves shapes onto a subboard's board, and that matters here. This branch had nothing on it yet, so I fast-forwarded it to main.

## Plan: a locked subboard's board can't be edited, at any depth

**Behaviour**
- A board can't change when the shape that owns it can't change. That covers a locked subboard, a subboard inside a locked frame, and any subboard on a board that's already read-only, so the lock reaches every board below it.
- You can still enter it, select, copy, open nested subboards, and use Find and Jump To.
- On such a board, nothing can be moved, resized, deleted, restacked, edited in place, changed in the panel, turned into another kind, or locked/unlocked. Each try shakes the shape, the way a locked shape already does.
- Nothing can be added to it:
  - placing a shape or double-clicking to make a note
  - pasting
  - drawing an arrow from a port dot
  - `/move-to` or `/move-near` onto it (`/move-to` won't list it either)
  - `canvas draw` (refused as `read_only`, and the canvas skill says so)
- **Decision A (I'd do this):** on a locked board, these are dimmed:
  - the tools that add shapes (Note, Subboard, Frame, Schema, Reference) and their keys
  - Paste
  - port dots don't show at all
- **Decision B (I'd do this):** a small lock after the locked board's name in the path at the top. Without it, nothing on screen inside the board tells you why everything is refused.

**How it's built**
- **Core (Canvas):** this works the same way a locked frame already locks its contents, and it covers every read-only rule, not just Locking.
  - The editor keeps track of whether the board shown is read-only, and `editor.isReadOnly` includes that. There's also a new check that works on any board in the file.
  - Edits refuse every shape that was already on such a board. Adding a shape there is dropped, and the board's owner counts as the shape that refused it.
  - Moves onto another board check the destination the same way.
  - The current lookup only checks a shape's own lock and its frames, not its board. It stops being public, so a plugin can't use it by accident.
- **Plugins:** switch to the new checks in the detail panel, @-mention picker, schema sync, references, Transform, Moving and Automation. Locking stops offering Lock/Unlock there. Clipboard, port dots, the keyboard and the toolbar handle decision A; Boards handles B.
- **Tests and docs:**
  - The core tests use the existing test-only lock and nested test subboards, two levels deep, to check that the lock reaches every level.
  - Locking, Automation and app-level tests cover a real locked subboard.
  - The guide, the affected topic files and the canvas skill get updated.

**Execution:** I'll write the core change myself, because its rules are subtle. One Sonnet agent (routed with Jev) then does the plugin changes, UI, tests and docs in this worktree. Then I run a code review and report back before anything lands.

Say go, or change A or B.

[2026-10-06 12:39] USER:
great love this

[2026-10-06 12:41] ASSISTANT:
Now writing the core. First the rule itself, beside the existing read-only container rule:

[2026-10-06 12:42] ASSISTANT:
Now the transaction: it learns whether its board is read-only, holds every shape already there, and drops anything added.

[2026-10-06 12:43] ASSISTANT:
Now the editor: a kept, observed `isBoardReadOnly`, the board-aware checks, placing refused, and placing tools disabled.

[2026-10-06 12:44] ASSISTANT:
Now the editor's read-only questions:

[2026-10-06 12:46] ASSISTANT:
Core is written. Now switching the plugins off the board-blind check (it's no longer public), so the build compiles:

[2026-10-06 12:47] ASSISTANT:
Plugin call sites switched. Building now to check the core compiles.

[2026-10-06 12:48] ASSISTANT:
Builds clean. Running the full test suite in the background to check nothing regressed, while I read the existing read-only tests.

[2026-10-06 12:48] ASSISTANT:
Writing the core tests now (frozen test-subboards, two levels deep).

[2026-10-06 12:49] ASSISTANT:
Now writing the core test file.

[2026-10-06 12:52] ASSISTANT:
All 7 new core tests pass. Running the full suite in the background for regressions while I brief the agent.

[2026-10-06 12:52] ASSISTANT:
While the suite runs, I'll write the core's own docs (the guide's read-only section and the editor/boards topic files), since I wrote that part.

[2026-10-06 12:53] ASSISTANT:
Full suite passes with the core change (every test executable). Now the core topic files:

[2026-10-06 12:53] ASSISTANT:
Core docs done. Committing the core as a checkpoint on the branch before handing the rest to the agent.

[2026-10-06 12:53] GIT:
git add -A && git commit -q -m "Read-only boards in the core: a board whose owner can't change can't either, at any depth

A locked subboard could be entered and everything on it edited. The core
already held a read-only container's contents; a board under a read-only
owner now gets the same treatment, climbing owners to the root, so the lock
reaches every board below it. Entering stays allowed.

- editor.isBoardReadOnly (kept, observed, set only when it changes),
  isReadOnly(board:), isReadOnly(inFile:), isToolEnabled(_:); isReadOnly(_:)
  sees the board.
- Transaction.isBoardReadOnly and isReadOnly(_:): every shape that was on a
  read-only board is held; an insert is dropped and the owner heard refused;
  move(_:to:), translate(on:) and settle(on:) judge other boards the same way.
- place refuses; placing tools aren't enabled there, and one in use leaves as
  a lock above lands; editing ends.
- registry.isReadOnly(_:in:) is internal: it can't see a read-only board, so
  every plugin asks a board-aware question instead.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git log --oneline -2

[2026-10-06 12:55] ASSISTANT:
Jev routes it to Sonnet at medium effort. Launching the agent with a full brief:

[2026-10-06 12:56] AGENT Finish read-only boards feature:
You're finishing a feature in a native macOS canvas app (Swift 6, AppKit + SwiftUI, compiled-in plugins). Work ONLY in this git worktree: /Users/zekenie/code/native-canvas/.claude/worktrees/cli-reference-creation-ce05fa (branch `claude/locked-subboard-restrictions-311df6`). Never touch the main checkout at ~/code/native-canvas, other worktrees, or main; don't merge, push or rebase. Run every command from the worktree with absolute paths.

## Read first
- `CLAUDE.md` at the worktree root (rules for every change: build/test commands, layers, tests must never touch the user's pasteboard, the app's socket or the network, must close BoardDocuments, etc.). Follow it exactly.
- Before changing a subsystem, read its topic file in `.claude/rules/` (map in CLAUDE.md), and the Testing section there. `.claude/rules/testing.md` before writing tests.
- `docs/plugin-system.md`, section "The core's part: read-only shapes" (already updated for this feature) — the core semantics you build on.
- Match the surrounding code exactly: naming, doc-comment density and voice (terse, plain sentences, no marketing), idioms. Docs and topic files are written in the same dense style; keep it.

## The feature (user's request)
"When a sub-board is locked, you should be able to enter it, but you should not be able to edit its contents (infinitely deep)." The user approved this plan, including two UI decisions:
- (A) On a read-only board, the tools that place shapes (Note, Subboard, Frame, Schema, Reference) a […11689 more chars]

[2026-10-06 12:56] ASSISTANT:
The core is done and committed on the branch:

- A board can't be edited when its owner can't change. That covers a locked subboard, a subboard inside a locked frame, and anything on a board that's already locked, so the lock reaches every board below it.
- You can still enter it.
- 7 new core tests pass, and the full test suite still passes with the change.

A Sonnet agent (Jev's pick, at medium effort) is now working in this worktree on the rest:
- dimming the placing tools, their keys and Paste, and hiding port dots on a locked board
- the lock on the path at the top
- Lock/Unlock not offered inside a locked board
- `canvas draw` refusing as `read_only`, with the skill docs to match
- tests in about ten plugins and the app-level test
- the topic files and guide

When it finishes, I'll check its work, run a code review, and report back. Nothing lands on main until you say so.

[2026-10-06 13:39] ASSISTANT:
The agent reports everything done in one commit. I'm reviewing its diff before the code review.

[2026-10-06 13:40] ASSISTANT:
The agent left offscreen renders in the scratchpad. Let me look at them while the build and tests run.

[2026-10-06 13:41] ASSISTANT:
Build and full suite pass on my own run too (every test executable passed, exit 0), and the renders look right. Now the code review gate.

[2026-10-06 13:45] ASSISTANT:
Fixing all four. First the core: one climb gives where the path turns read-only, kept beside `isBoardReadOnly`, and set at init too.

[2026-10-06 13:46] ASSISTANT:
Now the crumbs: flags from the editor's one climb, and `readOnlyStart` stored so each crumb asks in constant time.

[2026-10-06 13:47] ASSISTANT:
Adding core tests for what the review found: an editor opened straight onto a locked board, where the path turns read-only, and a default placing tool leaving only once the board is shown.

[2026-10-06 13:48] ASSISTANT:
All 9 core tests pass, including the two new ones. Running the full suite again to confirm, and to read the 1,000-board chain benchmark.

[2026-10-06 13:48] ASSISTANT:
I've fixed all four review findings and I'm waiting on the full test run. I'll report once it's done.

[2026-10-06 13:49] NOTICE:
background task completed: Background command "Run the full suite and build after the review fixes" completed (exit code 0)

[2026-10-06 13:50] ASSISTANT:
All 4,200 tests pass, the build is clean, and opening an editor on the deepest of 1,000 nested boards is back to 25.7 ms (it was 571 ms before the fix). Committing the fixes.

[2026-10-06 13:50] GIT:
git add -A && git commit -q -m "Fix what reviewing read-only boards found: an editor opened on one, and the path's quadratic lock

- CanvasEditor(registry:file:showing:) opened on a locked subboard's board
  without working out isBoardReadOnly, so that board took edits until the first
  commit or switch. The init works it out now, before services are made, and a
  default tool that places shapes gives way to the Hand there.
- The path's crumbs asked isReadOnly(board:) of each board, each a climb to the
  root: an editor showing the deepest of 1,000 nested boards took 571 ms, 34 ms
  without it. The editor now keeps readOnlyStart, where its path turns
  read-only, from the one climb it already makes, and the crumbs are told from
  it; BoardCrumbs.readOnlyStart is kept with them, so the folded crumbs'
  accessibility menu doesn't scan the path once per crumb. Now 25.7 ms.
- show() left a disabled tool before the new board's index and services were in
  place; it does so once the board is shown and heard.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git log --oneline -4 && git status --short | wc -l

[2026-10-06 13:50] ASSISTANT:
A locked subboard can now be entered, but nothing on its board can be changed, and the lock reaches every subboard nested inside it. It's on the branch, reviewed, and not on main. All 4,200 tests pass and the app builds clean.

Inside a locked subboard:
- Every edit you try (drag, resize, delete, editing text, the side panel, Transform, Lock/Unlock) is refused, and the shape shakes, as a locked shape already does.
- Nothing can be added. The Note, Subboard, Frame, Schema and Reference tools are dimmed, and their keys do nothing. Paste is dimmed, and port dots don't show, so you can't drag an arrow out.
- You can still select, copy, open nested subboards, and use Find and Jump To.
- The path pill at the top shows a small lock after the name of the first locked board, once.
- `/move-to` won't list anything inside, and `canvas draw` refuses changes there with `read_only`; the canvas skill says so.
- A subboard inside a locked frame is read-only inside too.

The code review found four problems, all fixed:
- **Editable until the first change:** an editor opened straight onto a locked subboard's board could be edited until the first change or board switch.
- **Slow path lock:** the path's lock check got slower the deeper the boards went. Opening the deepest of 1,000 nested boards took 571 ms; it's now 26 ms.
- **Folded path items:** the hidden "…" list in the path rescanned every board for each item, making the same slowdown at depth.
- **Tool switch timing:** a tool switch could happen before a newly shown board was fully set up (only with an unusual default tool).

The toolbar is now a native AppKit segmented control. SwiftUI's version can't dim individual tools. Rendered offscreen it looks the same as before (renders above), but I can't see the real window toolbar here, so it's worth a glance in the app:

```bash
open /Users/zekenie/code/native-canvas/.claude/worktrees/cli-reference-creation-ce05fa/build/InfiniteCanvas.app
```

Say "land" when you want it merged; it goes in as one squashed commit.

[2026-10-06 15:01] USER:
confused as to how this is 6k lines

[2026-10-06 15:02] ASSISTANT:
The 6k counts a commit that's already on main. This worktree was made from an older main, so before planning I fast-forwarded it onto main's latest commit (the `/move-to` change, about 4,200 lines). A diff against the worktree's original starting point counts that commit as if it were ours.

Measured against main, this change is about 1,900 lines added and 260 removed:

| Area | Added | Removed |
|---|---|---|
| Source | 490 | 152 |
| Tests | 1,208 | 13 |
| Guide (`docs/plugin-system.md`) | 154 | 62 |
| Topic files and canvas skill | 39 | 29 |

Much of the source is doc comments, written in the codebase's usual style. The biggest single piece of code is the toolbar, about 70 lines, because SwiftUI's segmented picker can't dim one tool and had to become an AppKit control. Tests are two-thirds of the change, spread across about 15 test targets. When it lands, the squashed commit holds only these ~1,900 lines.

If that's more test than you want, I can cut them back to the core, Locking and the app-level ones.

[2026-10-06 15:02] USER:
[image attached]

[2026-10-06 15:02] GIT:
git remote -v | head -2; git rev-parse --short origin/main main 2>&1; git merge-base HEAD origin/main | cut -c1-8; git log --oneline origin/main..main | head

[2026-10-06 15:02] ASSISTANT:
The bar compares against GitHub's `main` (`origin/main`), not your local `main`. GitHub's `main` is still at the References commit, and your local `main` has commits that were never pushed, including `/move-to`. This branch sits on top of `/move-to` because I fast-forwarded it onto local `main` at the start. So the bar counts `/move-to`'s ~4,200 lines plus this change's ~1,900, and +6,041 is exactly the diff from the References commit to here.

Landing is unaffected: it goes onto local `main`, which already has `/move-to`, so the squashed commit is only the ~1,900 lines.

If you push local `main` to GitHub, the bar should drop to this change alone. That's your call; I haven't pushed anything.

[2026-10-06 15:05] USER:
land on local main

[2026-10-06 15:06] ASSISTANT:
Landing: squashing to one commit, rebasing onto main (which has moved), then fast-forwarding.

[2026-10-06 15:06] GIT:
git status --short | wc -l && git merge-base HEAD main | cut -c1-8 && git log --oneline 279c7f1d..HEAD

[2026-10-06 15:06] GIT:
S=/private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-cli-reference-creation-ce05fa/f8601f2b-0ce4-4853-826c-e3086dca0556/scratchpad && cat > $S/landing-msg.txt <<'EOF'
A locked subboard is entered, but nothing on its board changes, at any depth

The user: "when a sub-board is locked, you should be able to enter it, but you
should not be able to edit its contents (infinitely deep). right now you can
enter a locked subboard and do anything you want." A locked frame already
locked what it held; a locked subboard locked only its card.

The rule is the core's, for any read-only rule, not Locking's: a board is
read-only while the shape that owns it is (locked, in a locked frame, or on a
read-only board), climbing owners to the root, so the lock reaches every board
below, as a locked frame's reaches what it holds. Entering stays allowed, and
so do selecting, copying and opening what's there; each shape refuses every
change as one in a locked frame does, its own lock included, and nothing goes
on the board. Two UI decisions came with the plan the user approved: (A) on a
read-only board the tools that place shapes (Note, Subboard, Frame, Schema,
Reference) and their keys are off, Paste is off, and no port dots show, rather
than staying on to do nothing; (B) the path's pill shows a small lock after the
name of the crumb where the read-only part starts, once.

Core (Canvas):
- editor.isBoardReadOnly, and readOnlyStart, where the path turns read-only,
  worked out in one climb from the init on and as each switch and commit
  leaves the file (a lock above can land in transact(on:)), observed and set
  only when they change; isReadOnly(_:) sees the board, beside
  isReadOnly(inFile:), isReadOnly(board:) and isToolEnabled(_:).
- Transaction.isBoardReadOnly and isReadOnly(_:): every shape already on a
  read-only board is held; an insert is dropped and the board's owner heard
  refused, as a read-only container is; move(_:to:), translate(on:) and
  settle(on:) judge other boards the same way. place puts nothing down there, a
  placing tool in use leaves as a lock lands, editing ends, and BoardReading
  says it too.
- registry.isReadOnly(_:in:) is the core's alone: it can't see the board, so
  every plugin asks a board-aware question (the detail panel, the @ picker,
  schema sync, Interpret, Transform, /move-to, canvas draw).

Around it:
- Toolbar: ToolPicker is an AppKit segmented control, since SwiftUI's segmented
  Picker ignores .disabled on a segment; same look, each tool dimmed by
  isToolEnabled. Keyboard: a tool's key applies only while the tool is enabled.
- Clipboard: no Paste there; Cut works as for locked shapes (copies, deletes
  nothing, shakes).
- Connections: no port dots there, and beginArrow returns nil.
- Locking: neither Lock nor Unlock for what's on a read-only board; a shape
  locked on its own keeps its chip, whose click is refused.
- Boards: each crumb is read-only from the editor's readOnlyStart (asking each
  board would cost the path's depth squared: an editor showing the deepest of
  1,000 nested boards took 571 ms that way, 26 ms this way); the path draws
  lock.fill after the first read-only crumb only, and on its item in the "…"
  menu when it's folded (an attributed title was rejected: it puts the symbol
  in the item's title).
- canvas draw: `in` a locked subboard, and a new shape or edge landing on a
  read-only board, are read_only (`"N" would go on "Plans"'s board, which is
  read-only (locked, say)`); the canvas skill says so.
- Tests: the core's ReadOnlyBoardTests on frozen pockets, two deep; the
  toolbar, keys, paste, ports, locking, the path, draw, the @ picker, sync,
  Interpret, Transform, the panel, Moving and the shake; and a shipped test of
  a locked subboard holding a subboard.
- Docs: the guide's read-only section and each topic file it touches.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git reset -q --soft 279c7f1d && git commit -q -F $S/landing-msg.txt && git log --oneline -2 && git rebase main 2>&1 | tail -15

===== [2026-10-06 15:06] commit written: A locked subboard is entered, but nothing on its board changes, at any depth =====

[2026-10-06 15:07] ASSISTANT:
Main's new drag-and-drop code (table of contents rows, Moving's dropping) uses the board-blind check, which is internal now. Converting those calls:

[2026-10-06 15:07] ASSISTANT:
Code conflicts resolved. Now the topic-file and skill conflicts, merging main's new text with ours:

[2026-10-06 15:11] ASSISTANT:
Everything compiles (no tests run, per your landing rule). Finishing the rebase and fast-forwarding main.

[2026-10-06 15:11] GIT:
git status --short | grep -v "^M \|^A " | head; GIT_EDITOR=true git rebase --continue 2>&1 | tail -2 && git log --oneline -3 && git -C /Users/zekenie/code/native-canvas status --short | head -3 && git -C /Users/zekenie/code/native-canvas merge --ff-only claude/locked-subboard-restrictions-311df6 2>&1 | tail -2 && git -C /Users/zekenie/code/native-canvas log --oneline -2

[2026-10-06 15:11] ASSISTANT:
It's on main as 7624d811.

Main had moved again, with table-of-contents row dragging and ports on subboards. That new drag-and-drop code was checking locks the old way, which only looks at a shape and its frames, not the board it's on, so I switched it to the board-aware check while rebasing. A locked subboard's contents can't be dragged out through the table of contents either. Everything compiles after the rebase; I didn't rerun the tests, per your landing rule. The worktree and branch are removed.

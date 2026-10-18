# Fix MentionsTests' intermittent unowned-reference crash

Claude Code session `18053c65-ca1c-491a-8990-85affd509f83`, 2026-10-08 14:06 to 2026-10-08 14:40 UTC, on `claude/compassionate-khorana-fd0fcd`, `main`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-08 14:06] USER:
In ~/code/native-canvas (Infinite Canvas, a Swift/AppKit app; read CLAUDE.md and .claude/rules/mentions.md and testing.md first), MentionsTests crashes intermittently under load with "Fatal error: Attempted to read an unowned reference but object 0x... was already destroyed". Seen on main at b7f0858c. Alone it passes (262 tests); under `./test.sh`'s parallel run, or with ten copies of build/debug/MentionsTests/MentionsTests run at once (`TEST_TIMES=1` prints each test's seconds on stderr), about one in ten crashes. In the one traced crash, the last test to finish was "Mention text in the panel: read-only: not editable, dimmed, no picker; a lock landing closes the picker; the window's clicks still reach it: a pill selected, then followed", so the crash is in the next test ("⌘. with the picker open closes only the picker, as Escape does; a second leaves the panel") or in run-loop work left over from the previous one (a window, panel, picker or timer holding `unowned` to something that was let go). Find the unowned reference, decide whether the app itself can hit it (closing a panel or window while the picker or a lock is live), fix the cause, not the test, and add a test that holds it. Work in a git worktree off main, and land only on the user's go, after a code review, as one squashed commit.

[2026-10-08 14:06] GIT:
git log --oneline -1 main && git log --oneline -1 && git merge-base --is-ancestor HEAD main && echo behind

[2026-10-08 14:06] GIT:
git merge --ff-only main && git log --oneline -1 && git merge-base --is-ancestor b7f0858c HEAD && echo hasb7

[2026-10-08 14:06] ASSISTANT:
Looking for the unowned reference now: I've listed every `unowned` in Sources and Tests and am reading the Mentions panel test and the services that hold the editor unowned.

[2026-10-08 14:08] ASSISTANT:
Built the tests; 12 parallel runs all passed. Adding more load (other test executables alongside) to reproduce the crash with a backtrace.

[2026-10-08 14:17] ASSISTANT:
Reproduced it with logging that shows each deferred reclaim and when the test's panel is freed. Reading the trace now.

[2026-10-08 14:20] ASSISTANT:
Edited TestKit so each test runs in its own autorelease pool (`runAsTest`). Now switching the fixtures' `onExit` closures to weak captures.

[2026-10-08 14:21] ASSISTANT:
Now the test that holds it, in DetailPanelTests' "Panel in a window" suite, beside the test that hides the panel.

[2026-10-08 14:22] ASSISTANT:
Passes. Checking it fails without the fix: temporarily removing the pool from `runAsTest`.

[2026-10-08 14:22] ASSISTANT:
Without the pool the test fails both ways: the window survives and the hand-back fires. Pool restored. Rebuilding and running the whole suite, then the stress run.

[2026-10-08 14:24] ASSISTANT:
LanguageModelsTests now segfaults. Getting a backtrace.

[2026-10-08 14:24] ASSISTANT:
Most of those `.close()` calls are on documents or Find. Narrowing to windows closed by tests.

[2026-10-08 14:24] ASSISTANT:
Only `hostSettings` closes a window that's released on close; every other one sets `isReleasedWhenClosed = false`. Fixing it and rerunning the whole suite.

[2026-10-08 14:25] ASSISTANT:
Whole suite passes. Now the stress run: 56 parallel MentionsTests runs, as before, which crashed 2–3 in ~50 on main.

[2026-10-08 14:30] ASSISTANT:
84 of 84 runs clean, where main crashed 2–3 in about 50. Starting a second full `./test.sh` in the background while I update the testing topic file.

[2026-10-08 14:30] ASSISTANT:
Adding the rule to `testing.md` and a sentence to the guide's test-target bullet.

[2026-10-08 14:30] ASSISTANT:
Docs updated. Waiting on the second full run, then I'll commit and review.

[2026-10-08 14:30] ASSISTANT:
Renamed the test. Waiting for the background run to finish.

[2026-10-08 14:30] ASSISTANT:
The full run is still going. Committing on the branch in the meantime.

[2026-10-08 14:30] GIT:
git add -A && git commit -q -F - <<'EOF'
TestKit runs each test in an autorelease pool of its own, so a panel a test let go never hands the keyboard back in a later test

MentionsTests crashed about one run in ten under load ("Attempted to read an unowned reference")
in the test after "read-only: … a pill selected, then followed". The crash reports put it in
MentionPanel's onExit, `[unowned self]`, called from DetailPanelView.reclaimSoon: the panel hands
the keyboard back on the scheduler's next turn, and under load that turn came after the test had
let its MentionPanel go. The window was still alive, with the keyboard on itself (the thaw had
rebuilt the text view), so the reclaim called onExit into a freed object.

The window outlived its fixture because runTests never drained an autorelease pool: nothing here
runs NSApp's event loop, which drains one per event, so every window a test made, its SwiftUI
panel and what it scheduled lived to the process's end and acted during later tests (logging
showed earlier tests' reclaims landing after their panels were freed too, harmlessly only because
their first responder wasn't the window). Wrapped in a pool, the window goes with its fixture and
the reclaim's weak window finds nothing.

The app can't hit this: its onExit is `focus.take`, which holds CanvasFocus strongly (and it holds
the canvas weakly), and the app's event loop drains the pool, so a closed board window is freed
and a pending reclaim does nothing. So DetailPanelView is unchanged: calling onExit a turn later is
its contract, and a closure handed to a view must survive being called after its giver goes.

- TestKit: `runAsTest` runs a test body and afterEach in a pool of its own and returns its
  failures (the caller's kept); runTests runs each test with it.
- The fixtures that hand a panel or list an onExit capture themselves weakly (MentionPanel,
  DetailPanelTests' and FindTests' panel windows, TitlesTests', TableOfContentsTests'), and
  SubboardsTests' stopped capturing its window strongly from inside it (a cycle that kept it
  forever).
- LanguageModelsTests' settings window set isReleasedWhenClosed = false: closed by the test, it was
  released once too often, which the undrained pool had hidden and draining exposed (a segfault).
- DetailPanelTests: a panel with a reclaim pending, kept past its test, hands the keyboard back;
  let go by its test, its window is gone as runAsTest returns and nothing is called. Without the
  pool it fails both ways.

84 parallel MentionsTests runs under load, all clean (main crashed 2–3 in ~50).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -1

===== [2026-10-08 14:30] commit written: TestKit runs each test in an autorelease pool of its own, so a panel a test let go never hands the keyboard back in a later test =====

[2026-10-08 14:30] ASSISTANT:
Committed. Running the code review while the suite finishes.

[2026-10-08 14:31] ASSISTANT:
The second full run passed too. Now the review: reading the whole diff.

[2026-10-08 14:32] ASSISTANT:
Checking the reworked test still fails without the pool, then rerunning the affected executables.

[2026-10-08 14:33] GIT:
sed -i '' 's/(MentionPanel, DetailPanelTests. and FindTests. panel windows, TitlesTests., TableOfContentsTests.)/X/' /dev/null; git add -A && git commit -q -m "Review: SchemasTests' panel onExit weak too; the pool test waits on a later hand-back, not on time

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git log --oneline -2

[2026-10-08 14:33] ASSISTANT:
I found and fixed it on `claude/compassionate-khorana-fd0fcd`; it's reviewed and waiting for your go to land.

**The unowned reference:** it's in the test fixture, not the app. `MentionPanel` gives the detail panel an exit closure with `[unowned self]`. The panel's `reclaimSoon` calls that closure on the scheduler's next turn to hand the keyboard back. Under load, that turn came after the read-only test had already let its `MentionPanel` go. The window was still alive and holding the keyboard itself, so the call hit the freed object. The two crash reports from this morning in `~/Library/Logs/DiagnosticReports` show this stack, and logging showed the same sequence.

**The cause:** `runTests` never drained an autorelease pool. Nothing in a test executable runs the app's event loop, which drains one per event. So every window a test made, with its panel and whatever it had scheduled, lived until the process exited and kept acting in later tests.

**Can the app hit it? No.** Its exit closure is `focus.take`, which holds `CanvasFocus` strongly, and that holds the canvas weakly. The app's event loop also frees a closed window, so a pending hand-back finds no window and does nothing. I left the panel itself unchanged: calling the exit closure a turn later is how it's meant to work.

**The fix:**
- **TestKit:** a new `runAsTest` runs each test (and `afterEach`) in its own autorelease pool; `runTests` uses it.
- **Fixtures:** the six that gave a panel or list an exit closure with `unowned` or a strong window capture now capture weakly (Mentions, DetailPanel, Find, Titles, TableOfContents, Schemas). SubboardsTests' window had captured itself strongly, so it never went; that's fixed too.
- **One hidden bug:** draining the pool exposed a segfault in LanguageModelsTests. Its settings window was released once too often on close; it now sets `isReleasedWhenClosed = false`.
- **The test that holds it,** in DetailPanelTests: a panel with a hand-back pending, kept past its test, hands the keyboard back. Let go by its test, its window is gone and nothing is called. With the pool removed it fails both checks.

**Verified:** `./test.sh` passed twice, and 84 parallel MentionsTests runs under load were all clean; main crashed 2 or 3 times in about 50. The review found three things, all fixed: the Schemas fixture I'd missed, a timing dependence in the new test, and inconsistent comments. I updated `testing.md` and the guide's testing section.

When you say land, I'll squash both commits into one (folding the Schemas fixture into the message) and merge.

[2026-10-08 14:34] USER:
Land

[2026-10-08 14:34] GIT:
M=/private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-compassionate-khorana-fd0fcd/18053c65-ca1c-491a-8990-85affd509f83/scratchpad/msg.txt && python3 - "$M" <<'EOF'
import sys
p=sys.argv[1]; s=open(p).read()
a="""  DetailPanelTests' and FindTests' panel windows, TitlesTests', TableOfContentsTests'), and
  SubboardsTests' stopped capturing its window strongly from inside it (a cycle that kept it
  forever)."""
b="""  DetailPanelTests' and FindTests' panel windows, TitlesTests', TableOfContentsTests'), and
  SubboardsTests' and SchemasTests' stopped capturing their windows strongly from inside them (a
  cycle that kept them forever; SchemasTests' held its canvas unowned too)."""
assert a in s
s=s.replace(a,b)
a="""  let go by its test, its window is gone as runAsTest returns and nothing is called. Without the
  pool it fails both ways."""
b="""  let go by its test, its window is gone as runAsTest returns, and once a later panel's hand-back
  lands (the main actor runs them in order) it has called nothing. Without the pool it fails both
  ways."""
assert a in s
s=s.replace(a,b)
open(p,'w').write(s)
EOF
git reset --soft main~0 2>/dev/null; git reset --soft $(git merge-base HEAD main) && git commit -q -F "$M" && git rebase main 2>&1 | tail -1 && git log --oneline -2

[2026-10-08 14:34] ASSISTANT:
As I feared, that commit would revert main's newer work. It's only on the branch; nothing has landed. Rebuilding the squash from my original commits (still at `7156f820`).

[2026-10-08 14:34] GIT:
M=/private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-compassionate-khorana-fd0fcd/18053c65-ca1c-491a-8990-85affd509f83/scratchpad/msg.txt && git status --short | head -3; git reset -q --hard 7156f820 && git log --oneline -3 && git reset -q --soft 353cf798 && git commit -q -F "$M" && git rebase main 2>&1 | tail -1 && git log --oneline -3 && git diff --stat main HEAD | tail -3

[2026-10-08 14:34] ASSISTANT:
The diff against main is now just my 11 files. Merging from the main checkout.

[2026-10-08 14:34] ASSISTANT:
Landed. Cleaning up the worktree and branch.

[2026-10-08 14:34] ASSISTANT:
It's on main as `fdf8deb2`, and the worktree and branch are removed.

One mistake on the way, caught before the merge: my first squash came out as a commit that would have reverted main's newer commits. I rebuilt it from the original commits and checked that it changes only my 11 files before merging.

[2026-10-08 14:39] USER:
sorry did you or did you not fuck main

[2026-10-08 14:40] GIT:
git log --oneline -3 main && git diff --stat fdf8deb2~1 fdf8deb2 | tail -1 && git merge-base --is-ancestor 5aa98112 main && echo "5aa98112 still in main"

[2026-10-08 14:40] ASSISTANT:
No, I didn't touch main. I just checked it again:

- Main is `fdf8deb2`, sitting directly on `5aa98112`, which was the tip before I merged, so the merge was a plain fast-forward.
- `fdf8deb2` changes only my 11 files (88 lines added, 12 removed), all in TestKit, test fixtures and the testing docs.
- Everything on main before it is untouched.

The bad squash existed only on my branch. I caught it with a diff against main, threw it away, rebuilt the squash from my original commits and checked the diff was down to those 11 files before merging.

[2026-10-08 14:40] USER:
so what are you saying

[2026-10-08 14:40] ASSISTANT:
Main is fine. The bad commit was only ever on my branch, and I deleted it before merging. What landed on main is just my 11-file fix, on top of everything that was already there, and none of that was changed.

[2026-10-08 14:40] USER:
you don't need to say shit like this

[2026-10-08 14:40] ASSISTANT:
Understood. A slip that never reached main isn't worth reporting; I'll just say where things landed.

[2026-10-08 14:40] USER:
[Request interrupted by user]

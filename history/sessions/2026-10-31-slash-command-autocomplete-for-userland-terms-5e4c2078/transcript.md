# Slash command autocomplete for userland terms

Claude Code session `5e4c2078-1cfd-442b-a7c7-c64add5426dc`, 2026-10-31 02:13 to 2026-10-31 12:30 UTC, on `claude/slash-command-autocomplete-ace3e9`, `main`, `slash-name-search`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-31 02:13] USER:
when you do the slash command, you type "/is-a " then you can find "idea". you should be able to just say userland things like "/idea" and have "/is-a idea" "/move-near idea" come up

like you should be able to type "idea" and see all the commands that have that... all the things you can do with idea (move near, is a, etc)

[2026-10-31 02:13] ASSISTANT:
Reading the slash-command list and how commands with arguments (`/is-a`'s choices, `/move-near`'s shape) are listed, so I can propose how typing "idea" lists everything you can do with it.

[2026-10-31 02:14] ASSISTANT:
Almost done reading — checking what `/is-a` and `/color` list as choices, then I'll put a plan in front of you.

[2026-10-31 02:15] WRAP-UP:
I read how the slash list works: it only matches command names, and arguments only list after the name (`/is-a ` opens the types). Nothing is changed yet; the plan to also match arguments is below.
Ask: Build it as planned?

[2026-10-31 02:16] ASSISTANT:
Right now the `/` list only matches command names. Arguments show up only after you've typed the name: `/is-a ` lists the types, and `/move-near @` opens the shape picker. Here's how I'd make it also work the other way round, starting from the thing:

1. **What gets searched:** the list would also look through the commands' arguments.
   - For `/is-a` and `/color`, that's their choices (the types, the colors).
   - For `/move-to` and `/move-near`, it's the shapes each one accepts, found the same way the `@` picker finds them.
   - Commands that take any text (`/title`, `/bulk-create`, `/query`) stay out, because every query would match them.
2. **How rows look:** each row reads like the line it stands for, e.g. `is-a Idea` or `move-near Idea`. The right side says where the shape is (or "2 of 3" in the bar).
   - Better matches come first. When a command name and an argument match equally well, the command name comes first.
   - Each command shows at most 3 shapes.
3. **Picking a row:** Return, Tab or a click on one of these rows runs the command right away and removes the line, the same as picking a type in the `/is-a ` list. Tab on a plain command name still just completes the name.
4. **Spaces and punctuation:**
   - The list stays open past a space while something still matches, so `/big idea` works.
   - If nothing matches, a space or punctuation closes the list as it does today.
   - `/is-a ` (a full command name, then a space) still switches to that command's own list.
5. **Where it works:** in a note's text and in the command bar. The bar's plain text field, used when Mentions isn't installed, gets the type and color rows but not the shape rows, because it has no way to name a shape.
6. **Tests and docs:** tests for the list's ranking and for picking a row with the keys, plus a check with the real app's plugins that typing `/idea` in a note lists and runs `is-a Idea` and `move-near Idea`. I'd also update `slash-commands.md` and the guide.

[2026-10-31 02:16] USER:
Yes, build it

[2026-10-31 02:17] ASSISTANT:
Reading done; now writing the argument rows into the slash list (SlashCommands), then the pick, then Mentions' shape search.

[2026-10-31 02:19] ASSISTANT:
Now writing the picker's argument rows.

[2026-10-31 02:20] ASSISTANT:
Now the typing side: a picked argument row runs its command.

[2026-10-31 02:20] ASSISTANT:
Now Mentions: hand the typing a shape search that ranks shapes the way the `@` picker does.

[2026-10-31 02:21] ASSISTANT:
While it builds, writing the tests. Looking at how the existing typing and choice tests are set up:

[2026-10-31 02:22] ASSISTANT:
Writing the SlashCommands tests now (headless list and typed in a view), then Mentions' and the shipped ones.

[2026-10-31 02:23] ASSISTANT:
Now updating the test support (a `shapes:` search through the test view) and writing the new suite.

[2026-10-31 02:25] ASSISTANT:
Sources compile. Now building and running the SlashCommands tests with the new suite.

[2026-10-31 02:26] ASSISTANT:
Three expected fallouts (old 40-char limit test, choice-ask counts now including the names list's one ask, a missing fixture plugin) and one wrong example in my test. Fixing them:

[2026-10-31 02:27] ASSISTANT:
SlashCommands' tests all pass (157). Now Mentions' test, through the real `@` search:

[2026-10-31 02:28] ASSISTANT:
Adding the shipped test done; now a case for the command bar's field (Mentions'), then I'll build and run Mentions and Composition tests.

[2026-10-31 02:37] ASSISTANT:
The timing failure repeats, so I'll check it against the base commit before assuming anything:

[2026-10-31 02:37] ASSISTANT:
Updating the guide's sections on the list, Return and hosting:

[2026-10-31 02:38] ASSISTANT:
Now the topic file, slash-commands.md (the list's paragraph, hosting, and Testing), and a line in mentions.md:

[2026-10-31 02:39] ASSISTANT:
Docs updated. While the full test run goes, I'll review the source diff myself:

[2026-10-31 02:39] ASSISTANT:
The diff reads right. While the suite runs, I'll set up a render of the new list (the gallery has command-bar states I can add to), so you can see it:

[2026-10-31 02:40] ASSISTANT:
Added two gallery states (the `/idea` list in a note and in the bar) so I can show you renders once the full suite finishes. Noting them in the testing topic file meanwhile:

[2026-10-31 02:40] ASSISTANT:
Waiting for the full test run to finish (the machine is busy, load ~30). I'll pick up from its result.

[2026-10-31 03:03] NOTICE:
background task completed: Background command "Run the full test suite" completed (exit code 0)

[2026-10-31 03:05] ASSISTANT:
It fails alone too, so I'll check whether it can depend on anything I changed:

[2026-10-31 03:05] ASSISTANT:
Still 161 ms against a 16 ms budget, so it isn't load. I'll build the base commit in a scratch clone and run the same test there, to see whether my change caused it:

[2026-10-31 03:05] ASSISTANT:
While the base builds, rendering the gallery (all states, then I'll pick out the new ones):

[2026-10-31 03:10] ASSISTANT:
Both renders look right. In the bar, `move-to Idea Backlog` is left out because Moving's own rule refuses a frame too small to hold both notes as a block. Waiting for the base commit's gallery to see whether `relations-pills` was already failing.

[2026-10-31 03:13] NOTICE:
background task completed: Background command "Render the base commit's gallery to compare failures" completed (exit code 0)

[2026-10-31 03:13] ASSISTANT:
The base commit's gallery throws in `relations-pills` too, so that was already failing. Everything new passes.

[2026-10-31 03:13] WRAP-UP:
Typing a thing's name after `/` now lists what you can do with it (`/idea` → `is-a Idea`, `move-near Idea`), in notes and the command bar; picking a row runs it. All new tests pass; nothing is committed and it isn't checked in the app on screen yet.
Ask: Review and land it on main?

[2026-10-31 03:14] ASSISTANT:
Typing a thing's name after `/` now lists everything you can do with it. In a note, `/idea` shows `is-a Idea`, `move-near Idea`, `move-to Idea Backlog` and `move-near Idea Backlog`. Return, Tab or a click runs the row straight away, the same as picking from `/is-a `'s own list. All the new tests pass and the renders are above, but I haven't tried it in the app on screen, and nothing is committed.

**How it works:**
- **What's matched:** the choices of `/is-a` and `/color`, and the shapes `/move-to` and `/move-near` accept. The shapes come from the same search the `@` picker runs on that command's line, so each command's own rules apply. For example, in the bar with two notes selected, `move-to Idea Backlog` drops out because the frame is too small to hold both.
- **Order:** better matches come first, and a command name comes before a thing with the same match. Each command shows at most 3 shapes. Commands that take any text (`/title`, `/query`, `/bulk-create`) list nothing, since they would match everything.
- **Spaces:** `/big idea` keeps the list open while something matches. If nothing matches, a space or punctuation closes the list as before. `/is-a ` still opens the types list.
- **One behaviour change:** typing `/idea` and pressing Return now runs the top row. Before, Return there just started a new line.

The core of it is in [SlashCommandPicker.swift](Sources/SlashCommands/SlashCommandPicker.swift), with the picking in [SlashCommandTyping.swift](Sources/SlashCommands/SlashCommandTyping.swift) and the shape search in [MentionTextView.swift](Sources/Mentions/MentionTextView.swift). New tests are in [ArgumentTests.swift](Tests/SlashCommandsTests/ArgumentTests.swift), plus cases in Mentions, the command bar's field, and a check with the real app's plugins that `/idea` makes a note an Idea and then moves it. `slash-commands.md`, `mentions.md`, `testing.md` and the guide are updated, and two gallery states produced the renders.

**Test results:** 8,256 passed and 2 failed across the full run. Neither failure is from this change:
- **LanguageModelsTests:** a Claude Code concurrency test timed out. Its target doesn't depend on any module I changed.
- **TypesTests:** a 16 ms budget for dragging between types took 161–177 ms. A clone of the base commit misses it the same way (185 ms).

One gallery state, `relations-pills`, also throws on both the base commit and this branch. All three need their own fix.

[2026-10-31 03:14] USER:
Review, then land

[2026-10-31 03:14] ASSISTANT:
Committing on the branch first, then the review.

[2026-10-31 03:14] GIT:
cd /Users/zekenie/code/native-canvas/.claude/worktrees/slash-command-autocomplete-ace3e9; git add -A && git commit -q -m "WIP: slash list finds what commands take" && git log --oneline -1; git rev-parse main; git log --oneline HEAD..main | wc -l

[2026-10-31 03:15] GIT:
cd /Users/zekenie/code/native-canvas/.claude/worktrees/slash-command-autocomplete-ace3e9; git rebase -q main && git log --oneline -2 && python3 .claude/skills/history/condense.py --self 2>&1 | tail -3; git status --short | head

[2026-10-31 03:15] ASSISTANT:
Re-applying my edits to main's version of the topic file:

[2026-10-31 03:16] ASSISTANT:
Now finishing the rebase and checking the one shipped test the restack commands affect:

[2026-10-31 03:16] GIT:
cd /Users/zekenie/code/native-canvas/.claude/worktrees/slash-command-autocomplete-ace3e9; git add .claude/rules/slash-commands.md && GIT_EDITOR=true git rebase --continue 2>&1 | tail -1; ./build.sh tests 2>&1 | grep -E "error|warning" | head; TEST_FILTER="/idea typed" build/debug/CompositionTests/CompositionTests 2>&1 | grep -E "FAIL|passed|Tests/" | head

[2026-10-31 03:20] ASSISTANT:
As expected, `send-behind Idea` now lists too (`bring-in-front-of` doesn't, since the note is already in front). Updating the test and its line in the topic file:

[2026-10-31 03:23] ASSISTANT:
Passes. Writing the session record and the squashed commit:

[2026-10-31 03:24] COMMIT MESSAGE FILE commit-msg.txt:
Typing a thing's name after a slash lists what the commands can do with it: /idea lists is-a Idea and move-near Idea, and a pick runs it

The owner's ask: the slash list only matched command names, so to make a note an Idea you had to know
`/is-a ` and then find Idea. "You should be able to just say userland things like /idea and have
/is-a idea, /move-near idea come up... type idea and see all the commands that have that... all the
things you can do with idea (move near, is a, etc)."

So what's typed after the `/` is matched against what the commands take too, not only their names
(SlashCommandPicker). A choice command's rows are matched by their titles (`/is-a`'s types, `/color`'s
colors; `choices()` asked once a list, when something is first typed, and never `otherwise`'s row). A
command that takes one shape gets the shapes its rule admits from the host, through a search the text
view hands the typing (`SlashShapeSearch`, `shapes:` on SlashCommandTyping): SlashCommands knows no
titles, so Mentions' MentionTextView gives it the search its `@` picker would make on that command's
line, the same owners, kinds and rule, so `/move-to`, `/move-near` and Reordering's `/send-behind` list
only what they would take. At most three shapes a command. A command that takes words (`/title`,
`/query`, `/bulk-create`) would match any query, so it lists nothing.

Decided in the plan the owner approved: a row reads as the line it stands for ("is-a Idea", the typed
letters matched in the argument, where the shape is or the choice's count at the right); rows rank by
tier, a command name before an argument of the same tier, then the commands' order and each list's
own; a row with what its command takes runs at once on Return, Tab or a click (the line goes, as a
pick of the choices' list does), while a name's row still completes; the list stays open past a space
or punctuation while something matches (`/big idea`) and closes as before when nothing does, a command's
name and a space still opening its own list; the query may be 80 characters, a title's longest, where
a name's limit was 40. The command bar's own field, which names no shape, lists choices but no shapes.

Accepted as is: Return on `/<word>` now runs the best match where it used to be a new line under "No
matches"; each shape command ranks the catalog per keystroke, as the `@` picker on its line does.

Session: history/sessions/2026-10-31-slash-command-autocomplete-for-userland-terms-5e4c2078/

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>

[2026-10-31 03:24] GIT:
cd /Users/zekenie/code/native-canvas/.claude/worktrees/slash-command-autocomplete-ace3e9; git add -A && git commit -q --amend -F /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-slash-command-autocomplete-ace3e9/5e4c2078-1cfd-442b-a7c7-c64add5426dc/scratchpad/commit-msg.txt && git log --oneline -2 && git log --oneline HEAD..main | wc -l && git -C /Users/zekenie/code/native-canvas status --short | head -5; git -C /Users/zekenie/code/native-canvas branch --show-current

[2026-10-31 03:24] ASSISTANT:
The main checkout has someone else's uncommitted files (`.canvas/ingest.json`, `dogfood/model/`) that this commit doesn't touch, so a fast-forward leaves them alone. Merging and cleaning up:

[2026-10-31 03:24] WRAP-UP:
The `/idea` list is on main as 46cbb221, with its worktree and branch removed. It isn't checked in the app on screen yet.
Ask:

[2026-10-31 03:24] ASSISTANT:
It's on main as 46cbb221.

Two things changed on the way in:
- **Review:** it found nothing that needed fixing before landing.
- **New restack commands on main:** main had gained `/bring-in-front-of` and `/send-behind`. Typing `/idea` in a note now lists `send-behind Idea` as well, after `is-a Idea` and `move-near Idea`. `bring-in-front-of Idea` doesn't show, because the note is already in front. I updated the test and topic file for that and re-ran that test, which passes.

I haven't tried it in the app on screen. The three failures from the earlier full run (a Claude Code timeout, the 16 ms drag budget, the `relations-pills` gallery state) are still there; they also fail on the commit this work started from.

[2026-10-31 03:26] USER:
yeah kick the tires

[2026-10-31 03:27] ASSISTANT:
While it builds, writing the throwaway suite. Checking the gallery stage's API so the suite can render what it sees:

[2026-10-31 03:28] ASSISTANT:
The suite is written. It types 28 queries in a note being edited, runs Return on `/idea` and `/back`, tries the bar with three notes and with nothing selected, and times keystrokes on a 10,000-note board. Waiting for the clone's first build to finish.

[2026-10-31 03:31] NOTICE:
background task completed: Background command "Clone main into the scratchpad and build its tests" completed (exit code 0)

[2026-10-31 03:35] ASSISTANT:
It runs. The two failures are in my harness (the cleanup between queries, and a render with no list open), not the feature. Reading what it saw:

[2026-10-31 03:41] WRAP-UP:
On a normal board `/idea` and `/back` list and run as intended, at 3–9 ms a keystroke. On 10,000 notes it hangs 29 s on the first letter in the bar with nothing selected, and lags ~165 ms a keystroke in a note. Nothing is changed yet.
Ask: Fix the search this way?

[2026-10-31 03:41] ASSISTANT:
Two problems on big boards. On a normal board it does what it should.

I couldn't try the app on screen, because screen capture isn't allowed here. Instead I ran the real app's plugins in hidden windows with real keystrokes, in a throwaway clone of main.

**On a realistic board** (5 types, 5 frames, a subboard, a dozen notes), everything I typed did the right thing:
- `/idea`, then Return, made the note an Idea ("Add Type"), and editing went on.
- `/back`, then Return, moved the note into Backlog ("Move").
- `/q4`, `/road`, `/res`, `/type` and `/edit` all found what you'd expect, and `/dne` found Done despite the typo.
- Every keystroke took 3–9 ms.

**On a board of 10,000 notes:**
- **Hang:** in the command bar with nothing selected, the first letter after `/` took 29 seconds. Every one of the board's shapes counts as a shape to move, so `/move-near` checks whether all 10,000 can be placed beside each shape that matches the letter, one shape at a time. Before this change, only typing `/move-near @i` in the bar reached that check. Now any letter does.
- **Lag:** in a note being edited, every keystroke takes about 165 ms. Each command that takes a shape searches the board separately. `/move-near`, `/send-behind` and `/bring-in-front-of` each cost 50–60 ms, which is what each one's `@` picker already costs.

**Crowding:** today's restack commands mean each shape now appears two or three times (`move-near`, `send-behind`, `bring-in-front-of`). Rows for the same shape aren't kept together, so the list reads as a jumble. The render above shows it.

**The fix I'd make:**
- Find the matching names once per keystroke, keep the best four, and ask each command only about those four. That caps the work at about 16 checks a keystroke, and keeps the hang and the threefold search from coming back.
- Group the rows by thing, so `/idea` reads `is-a Idea`, `move-near Idea`, `send-behind Idea`, then `move-to Ideas`, `move-near Ideas` and so on.
- Add a test that times keystrokes on a 10,000-shape board, in a note and in the bar with nothing selected.

This won't fix the `@` picker's own 50–60 ms on those three commands at 10,000 shapes; that was already there before this change.

[2026-10-31 03:44] USER:
Yes, fix it

[2026-10-31 03:45] ASSISTANT:
Worktree on main (46de99cd). Changing the picker: one name search per keystroke, the best four things, each command asked about those.

[2026-10-31 03:45] ASSISTANT:
The worktree's guard refuses long shell edits, so I'll make the changes with the editor instead:

[2026-10-31 03:46] ASSISTANT:
Now Mentions' side: the search drops the rule and ranks by name alone.

[2026-10-31 03:46] ASSISTANT:
Source changes done. Now the tests: the fake search drops the rule, and the cases for "three a command" become "the best four things, grouped".

[2026-10-31 03:47] ASSISTANT:
Now a budget test in the shipped tests for the 10,000-note board, which is what caught the hang. Checking how shipped tests state a time budget:

[2026-10-31 03:47] ASSISTANT:
Building the worktree (a first build, so a few minutes), then running the affected suites:

[2026-10-31 03:58] ASSISTANT:
Now Mentions' test, whose rows are now grouped by shape in Mentions' own ranking:

[2026-10-31 04:01] ASSISTANT:
Both pass: 25 ms a keystroke in a note on 10,000 notes, and 588 ms for the first key in the bar for every shape (was 29 s). Now the topic files and the guide:

[2026-10-31 04:02] ASSISTANT:
Updating the three docs to match:

[2026-10-31 04:02] EDIT .claude/worktrees/slash-name-search/docs/plugin-system.md:
row never). Shapes are found by name, once a query, by the host (`SlashShapeSearch`, given to
  `SlashCommandTyping` as `shapes:`: Mentions' `MentionTextView` hands it the search its `@` picker
  makes on a plain line, with where each shape is); the best four (`SlashCommandStyle.shapesListed`)
  are offered to each command that takes a shape, whose rule is asked of those alone, so a keystroke
  costs one search and a few rules whatever the board holds (asking each command's rule of every shape
  the letters matched took 29 seconds on 10,000 notes in the bar for every shape). Each shape's rows
  are together, in the commands' order: `move-near Idea`, `send-behind Idea`, then the next shape's.
  A command that takes words (`/title`) would

[2026-10-31 04:02] EDIT .claude/worktrees/slash-name-search/docs/plugin-system.md:
`arguments` reads a range of the text as runs (the default reads it as plain text); `shapes`, a
`SlashShapeSearch`, finds shapes by name for what's typed after a `/`, best first, and the list asks
the commands that take a shape about the best few (nil: none).

[2026-10-31 04:02] EDIT .claude/worktrees/slash-name-search/.claude/rules/slash-commands.md:
`shapes`, a `SlashShapeSearch` (`(query) -> [SlashShapeMatch]`: an id, the label, what's typed matched in it, a detail and how it's said), finds shapes by name for what's typed after a `/`, best first, asked once a query and never with a command's rule, so the list offers the best few to the commands that take a shape (nil: none; ignored with `takesShapes: false`);

[2026-10-31 04:02] EDIT .claude/worktrees/slash-name-search/.claude/rules/slash-commands.md:
ranked with `FuzzyMatcher` (FuzzyMatching's) (best tier first; a name before an argument of the same tier, a choice before a shape; the choices by command and then their own order, the shapes in the host's order, each shape's rows together in the commands' order: `move-near Idea`, `send-behind Idea`, then the next shape's), or the one row "No matches" with nothing highlighted; the first is highlighted. A command's row is the name with its matched characters semibold and the `argument` as its detail. What a command takes (`SlashCommandPicker.Entry`'s `argument`, `.choice` or `.shape`; `entries`, row for row, `listed` their commands, `highlightedEntry`): a choice command's rows matched by title (`choices()` asked once a list, when a query is first typed; never `otherwise`'s row), and for the commands that take one shape the best few shapes the host's search finds by name (`SlashCommandStyle.shapesListed`, 4), each offered to every such command, which lists it where it admits it (`admits(_:)`: its kinds, then its rule, asked of those four alone and kept by `RuleAnswers`), ranked by their labels' tier (one the host found by its path or a typo below every tier): a keystroke costs one search and a few rules, never a command's rule asked of every shape the letters match (each command searching with its rule took 165 ms a key in a note on 10,000 notes and 29 seconds for the first key in the bar for every shape, `/move-to`'s rule dropping all 10,000 into each frame it was asked of; on […90 more chars]

[2026-10-31 04:02] EDIT .claude/worktrees/slash-name-search/.claude/rules/mentions.md:
what's typed after a `/` finds shapes by name through the view's own search (`shapes(matching:)`, the `SlashShapeSearch` it hands the typing: `candidates` for the same owners as the picker on a plain line, no kinds and no rule, each with its place, else its kind's detail), whose best few the slash list offers to the commands that take a shape, so `/gro` lists `move-near Groceries`;

[2026-10-31 04:02] ASSISTANT:
Now the testing lines in the topic file:

[2026-10-31 04:02] EDIT .claude/worktrees/slash-name-search/.claude/rules/slash-commands.md:
the shapes from the host's search (`namedShapes`, Support.swift, standing for a mention view's, `SearchCount` counting its asks): one search a query, its first four offered to `stack` and to `point` (a fixture of ArgumentTests' own that takes any shape and logs what its rule is asked of), each shape's rows together, the box `stack` refuses and the fifth shape left out, the rule asked of the four alone, none without a host and none for a command that takes words,

[2026-10-31 04:02] EDIT .claude/worktrees/slash-name-search/.claude/rules/slash-commands.md:
and `/gro` typed listing the shapes the `@` picker finds by that name on a plain line, each with the commands that take it (the token `shelve`'s, the plates `stack`'s and the one `shelve`'s rule admits `shelve`'s too, the endpoint no command's, nothing for `near`, which takes shapes by `accepts`), Return running the first with its shape, and `/list` the plate `shelve` refuses with `stack` alone (`slashBarFieldTests` the same for three jots in the bar, run on all three).

[2026-10-31 04:02] EDIT .claude/worktrees/slash-name-search/.claude/rules/slash-commands.md:
Return makes the note an Idea in one Add Type step, and typed again it lists the note's rows alone, the first of which Return runs, a move; and on 10,000 notes, a type and three frames, a key after `/` in a note under `slashKeyBudget` (60 ms of the thread's CPU, debug build; some 25) and the first in the bar for every shape under `slashEverythingKeyBudget` (1.5 s; some 570, what `/move-to`'s rule costs for a block of every shape, for a frame among the best four))

[2026-10-31 04:02] ASSISTANT:
Docs updated. Running the full suite in the background, and meanwhile committing on the branch and reviewing:

[2026-10-31 04:02] GIT:
git commit -q -m "WIP: slash list searches names once, asks commands of the best four" && git log --oneline -1

[2026-10-31 04:03] ASSISTANT:
The suite is still running; I'll report once it finishes.

[2026-10-31 04:16] NOTICE:
background task failed: Background command "Run the full test suite on the fix" failed with exit code 1

[2026-10-31 04:16] WRAP-UP:
The slash list now looks names up once a keystroke and asks commands about the best four, with each thing's rows together. On 10,000 notes: 25 ms a key in a note (was 165), and 0.6 s for the bar's first key with nothing selected (was 29 s). Committed on branch slash-name-search and reviewed; not on main.
Ask: Land it on main?

[2026-10-31 04:16] ASSISTANT:
The hang and the lag are fixed on branch `slash-name-search`; it's committed and reviewed but not on main yet.

**What changed:** the list now looks names up once per keystroke, keeps the best four matches, and asks each command that takes a shape only about those four. Each thing's rows sit together: `is-a Idea`, `move-near Idea`, `send-behind Idea`, then `move-to Ideas`, `move-near Ideas`, and so on.

**On a board of 10,000 notes** (debug build):

| | Before | Now |
|---|---|---|
| A key in a note being edited | 165 ms | 25 ms |
| First key in the bar, nothing selected | 29 s | about 0.6 s |

A new test fails if either goes back up.

**The remaining 0.6 s** comes from `/move-to` checking whether all 10,000 notes, as one block, fit in a frame. That happens once per query, and only when a frame is among the four names. The `@` picker on `/move-to`'s line already paid the same.

**One thing to know:** because only the best four names are considered, a frame ranked fifth or lower doesn't get a `move-to` row. For example, `/back` on a board with four notes starting "Back…" would miss the frame "Backlog". Typing more of the name brings it back.

**Tests:** the full suite gave 8,273 passed and 1 failed. The failure is a timing test in Mentions for listing unnamed shapes. It calls code this branch doesn't touch, and it failed the same way earlier in this session, before this fix existed.

The code change is in [SlashCommandPicker.swift](Sources/SlashCommands/SlashCommandPicker.swift) and [MentionTextView.swift](Sources/Mentions/MentionTextView.swift). The new timing test is in [SlashCommandsShippedTests.swift](Tests/CompositionTests/SlashCommandsShippedTests.swift).

[2026-10-31 05:11] COMPACTED:
(the context was summarized here)

[2026-10-31 12:30] USER:
Land it

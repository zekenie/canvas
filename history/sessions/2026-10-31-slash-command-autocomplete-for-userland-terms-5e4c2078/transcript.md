# Slash command autocomplete for userland terms

Claude Code session `5e4c2078-1cfd-442b-a7c7-c64add5426dc`, 2026-10-31 02:13 to 2026-10-31 03:23 UTC, on `claude/slash-command-autocomplete-ace3e9`.

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

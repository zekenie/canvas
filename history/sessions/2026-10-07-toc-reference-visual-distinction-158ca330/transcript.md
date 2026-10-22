# TOC reference visual distinction

Claude Code session `158ca330-13df-49eb-bfa0-1125aa698a9d`, 2026-10-07 11:59 to 2026-10-07 12:33 UTC, on `claude/toc-reference-distinction-982ec8`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-07 11:59] USER:
[image attached]

[2026-10-07 11:59] USER:
references to something in the toc should be subtly different and conote that its not the shape itself but a pointer to it. it should still represent the target shape tho

[2026-10-07 11:59] ASSISTANT:
Reading the table of contents' row label code to see how a reference's row is drawn now.

[2026-10-07 12:00] ASSISTANT:
Mocking up a few looks for a reference's row (offscreen render) so you can pick one before I touch the code.

[2026-10-07 12:01] ASSISTANT:
Right now a direct reference's row copies its target's name, symbol and tint exactly, so in your screenshot `Ports.swift` the pill can't be told apart from `Ports.swift` the note. The mockup above shows three ways to mark it. These are mockups, not the real list:

- **A, alias arrow on the symbol:** a small curved arrow cut into the target's symbol at the bottom-left, like a Finder alias. Name, symbol and tint stay the target's. **I recommend this one.** It's the Mac's own sign for "a pointer to that thing", and it stays readable on a selected row.
- **B, italic name:** the old Mac OS sign for an alias. It's lighter, but on the canvas italic already means a pill whose target is gone, so it would mean two things.
- **C, A plus a softer name:** clearer, but the dimmer name looks a bit like the placeholder rows.

**Plan (for A):**
- **The list:** the row label gets a general "stands for another shape" flag, so the list still knows nothing about references. It draws the arrow and counts as a change to the row, so the row is redrawn when the flag flips. It covers both the list and the crumb menus' outline, since they draw the same label. Sizes go in the list's style constants.
- **References:** the flag goes only on rows that wear the target's symbol: a live reference, and one whose target went private. Query references (magnifier) and missing ones (dashed square) already look different, so they stay as they are.
- **Tests and docs:** tests for the flag and for which reference rows get it, plus updates to the table-of-contents and references topic files and the guide.

Which look should I build? If it's A, I'll go ahead.

[2026-10-07 12:04] USER:
perfect

[2026-10-07 12:05] ASSISTANT:
Building it now: adding the flag to the row label in the table of contents, then setting it from the reference rows.

[2026-10-07 12:05] ASSISTANT:
Now the edit to `ContentsLabel`:

[2026-10-07 12:05] ASSISTANT:
Now the reference row:

[2026-10-07 12:06] ASSISTANT:
Adding tests: the arrow's render in the list's label, the flag surviving a name given by another plugin, and which reference rows get it.

[2026-10-07 12:06] ASSISTANT:
Now the tests:

[2026-10-07 12:07] ASSISTANT:
Running the full test suite in the background while I update the docs.

[2026-10-07 12:07] ASSISTANT:
The local helper in my new test needs `@MainActor`; fixing that and rerunning.

[2026-10-07 12:09] ASSISTANT:
Both my test targets pass (TOC 146, References 169). One unrelated test, PortEdgesTests, fails consistently. Checking whether it fails on main too.

[2026-10-07 12:09] ASSISTANT:
Verifying on an untouched copy of main in the background while I render the real list for you.

[2026-10-07 12:10] ASSISTANT:
Writing a throwaway render test (not to be committed) to capture the real list with the change.

[2026-10-07 12:10] ASSISTANT:
PortEdgesTests fails the same way on untouched main, so it isn't caused by this change. I'll flag it separately. Now running the render.

[2026-10-07 12:11] ASSISTANT:
The light render works. The dark one didn't take, and I selected the note instead of the reference, so I'm fixing both and rendering again.

[2026-10-07 12:12] ASSISTANT:
The real list renders as designed. Sending the render, then removing the throwaway test.

[2026-10-07 12:12] ASSISTANT:
Tests pass apart from the PortEdgesTests failure that main has too. Committing on the branch, then running the code review before reporting.

[2026-10-07 12:12] ASSISTANT:
One fix before committing: the arrow should match the title's color, which is dimmed on a not-public row.

[2026-10-07 12:13] ASSISTANT:
All three pass (TOC 146, References 169, Composition 381). Committing on the branch.

[2026-10-07 12:14] GIT:
git add -A && git commit -q -F - <<'EOF'
Table of contents: a reference's row carries an alias arrow, so it reads as a pointer to its shape

A direct reference's row wore exactly its target's name, symbol and tint, so in a list where a note
and three pills for it are all listed, the pills looked like copies of the note. The owner asked for
rows that are "subtly different and connote that it's not the shape itself but a pointer to it",
while still representing the target.

The owner picked, from a mockup of three, a Finder alias's arrow: `arrow.turn.up.right` set in a
round hole cut out of the symbol's bottom-leading corner, in the title's color (secondary with a
placeholder), with no fill behind it, so it reads on any symbol and on a selected row. Rejected: an
italic name (old Mac OS's alias convention, but on the canvas italic already means a pill that
stands for nothing) and the arrow with a softened name (reads like the placeholder rows).

The list stays ignorant of references: `ContentsLabel` gains a generic `standsIn` flag (a row that
stands in for another shape and wears its name and symbol), kept by `retitled` and compared by
`showsSame`, so a row whose flag flips is redrawn. The crumbs' outline draws the same label, so it
gets the arrow too. References sets it on the rows that wear the target's symbol: live, and not
public. Missing, unavailable, words, query and empty rows already lead with their own symbols
(dashed square, magnifier) and get none.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -1 | cat

===== [2026-10-07 12:14] commit written: Table of contents: a reference's row carries an alias arrow, so it reads as a pointer to its shape =====

[2026-10-07 12:16] ASSISTANT:
Fixing what the review found: accessibility, scaling with the sidebar icon size, mask clipping, tests, and comment wrapping. Checking the list's style first.

[2026-10-07 12:16] ASSISTANT:
The list uses `.sidebar` style, so the arrow can scale with the sidebar row size. Applying the fixes:

[2026-10-07 12:16] ASSISTANT:
Now the tests: metric-independent bounds, the dimmed arrow, and an arrow-only change redrawing its row.

[2026-10-07 12:19] ASSISTANT:
The measure of the title's start was wrong: an empty title moves the symbol. Comparing against a different title instead, and making the "bottom" check describe the hole's real extent:

[2026-10-07 12:20] ASSISTANT:
All three pass (146, 169, 381). Committing the fixes and updating the review's findings.

[2026-10-07 12:20] GIT:
git add -A && git commit -q -F - <<'EOF'
Fix what reviewing the alias arrow found: VoiceOver, sidebar sizes, the mask's reach, tests

- VoiceOver read a reference's row exactly as its target's, since the arrow is hidden from it: the
  label now says "Alias" as its value (`ContentsStyle.standInSpoken`, the word Finder uses).
- The arrow, its hole and offset were fixed points while a sidebar list's symbols scale with the
  system's sidebar icon size: they now scale with `sidebarRowSize` (11/13 small, 15/13 large).
- The mask was the symbol's frame, which would cut ink a symbol draws past it: it reaches 4 pt out.
- Tests: an arrow-only change (an affected row whose title stays) is replaced and redrawn, which
  holds `showsSame`'s new comparison; the dimmed arrow of a placeholder row; and the render test
  reads the symbol's and the title's places from renders instead of hard-coding pixel bounds.

Left as they are: the mask's offscreen pass per visible reference row (a 16-point icon, in a lazy
list), and the arrow literal shared with the Reference tool's symbol (the list can't import
References; Referenced In's `arrow.up.forward` was already its own).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline main..HEAD | cat; git status --short | head

[2026-10-07 12:20] ASSISTANT:
I built the look you picked (A): a direct reference's row in the table of contents now has a small Finder-style alias arrow cut into the target's symbol. The name, symbol and tint are still the target's. The render above shows it on the real list. The crumbs' menu shows the same arrow.

- **Which rows get it:** a live reference, and one whose target went private (its arrow dims with its name). Query, missing and empty references keep their own symbols (magnifier, dashed square) and get no arrow.
- **Review fixes:** the code review turned up a few problems, now fixed:
  - VoiceOver read a reference's row exactly like its target's. It now also says "Alias" for a reference's row. That's my word choice, Finder's term; say if you'd rather it said "Reference".
  - The arrow now scales with the system's sidebar icon size.
  - The cut-out can no longer clip the edges of the symbol.
  - There are more tests.
- **Tests:** the table of contents, References and Composition tests all pass. The full suite has one failure, PortEdgesTests, a channel-order mismatch in an error message. It fails the same way on untouched main, so it isn't from this change. I flagged it as a separate task.

It's two commits on `claude/toc-reference-distinction-982ec8`, reviewed. Say the word and I'll squash it onto main.

[2026-10-07 12:33] USER:
land it

[2026-10-07 12:33] GIT:
git log --oneline -1 main | cat; git merge-base HEAD main | cut -c1-8; git -C ~/code/native-canvas status --short | head; git -C ~/code/native-canvas branch --show-current

[2026-10-07 12:33] GIT:
git reset -q --soft main && git commit -q -F - <<'EOF'
Table of contents: a reference's row carries an alias arrow, so it reads as a pointer to its shape

A direct reference's row wore exactly its target's name, symbol and tint, so in a list where a note
and three pills for it are all listed, the pills looked like copies of the note. The owner asked for
rows that are "subtly different and connote that it's not the shape itself but a pointer to it",
while still representing the target.

The owner picked, from a mockup of three, a Finder alias's arrow: `arrow.turn.up.right` set in a
round hole cut out of the symbol's bottom-leading corner, in the title's color (secondary with a
placeholder), with no fill behind it, so it reads on any symbol and on a selected row. Rejected: an
italic name (old Mac OS's alias convention, but on the canvas italic already means a pill that
stands for nothing) and the arrow with a softened name (reads like the placeholder rows).

The list stays ignorant of references: `ContentsLabel` gains a generic `standsIn` flag (a row that
stands in for another shape and wears its name and symbol), kept by `retitled` and compared by
`showsSame`, so a row whose flag flips is redrawn. The crumbs' outline draws the same label, so it
gets the arrow too. References sets it on the rows that wear the target's symbol: live, and not
public. Missing, unavailable, words, query and empty rows already lead with their own symbols
(dashed square, magnifier) and get none.

From the review: VoiceOver says "Alias" as the row's value (`ContentsStyle.standInSpoken`, Finder's
word), since the arrow is hidden from it and the name alone is the target's; the arrow, its hole
and offset scale with `sidebarRowSize` as a sidebar's symbols do; the mask reaches 4 pt past the
symbol's frame so no ink past it is cut. Left as they are: the mask's offscreen pass per visible
reference row (a 16-point icon, in a lazy list), and the arrow literal shared with the Reference
tool's symbol (the list can't import References).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git -C ~/code/native-canvas merge -q --ff-only claude/toc-reference-distinction-982ec8 && git -C ~/code/native-canvas log --oneline -1 | cat

[2026-10-07 12:33] ASSISTANT:
It's on main as 8c98ff01, and the worktree and branch are cleaned up.

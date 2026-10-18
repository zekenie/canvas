# Shape name validation

Claude Code session `0bc82b3e-8210-4031-93b8-13704b074443`, 2026-10-01 14:50 to 2026-10-01 15:26 UTC, on `claude/shape-name-validation-df055e`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-01 14:50] USER:
there does not appear to be any validation error when two shapes have the same name. is this true? there should be

[2026-10-01 14:51] ASSISTANT:
Yes, that's true. Nothing checks for it. Validation has only three rules:

- **Validation's schema rule** checks each shape against its kind's schema, for example a title over 80 characters.
- **MentionValidation's rule** flags mentions that can't work.
- **The schema card's rule** flags broken JSON and similar problems.

Titles adds no rule at all.

The only place duplicate names come up is `canvas draw`. If a script names a title that more than one shape has, it's refused with `ambiguous_title` ("the board has 2 shapes called …"), and the hint says to ask the user to rename one ([Drawing.swift:233](Sources/Automation/Drawing.swift:233)). A script also can't rename a shape to a title another shape already has (`duplicate`, [Drawing.swift:683](Sources/Automation/Drawing.swift:683)). In the app, though, it's easy to end up with two shapes of the same name: rename one in the panel to match another, or copy and paste a titled note, since the copy keeps the title. Nothing then warns you, and agents can no longer reach either shape by its title.

Building the rule means deciding a few things first:

- **Scope:** I'd make it file-wide, since `draw` and the mention picker now look titles up across the whole file. Validation only checks the board shown, so the rule would need a file-wide index of titles, kept up to date as you edit.
- **Which names count:** probably names someone gave and schema cards' titles, but not an untitled note's first line. Two notes that both start with "TODO" shouldn't warn.
- **Matching:** exact, or case-insensitive the way queries can match? I'd use what `draw` does: an exact match after folding the title to one line.
- **How serious:** a warning, not an error. Both shapes are fine on their own; it's the pair that's ambiguous. For example: “Checkout” is also the name of another note.

Want me to build it that way in this worktree?

[2026-10-01 14:52] USER:
yes

[2026-10-01 14:52] ASSISTANT:
I'm reading how Validation decides what to re-check, since a duplicate-name rule needs to re-check shapes that a commit didn't touch.

[2026-10-01 14:56] ASSISTANT:
I've read enough and am starting on the code: the Validation hooks first, then the bridge, its tests and the docs.

[2026-10-01 14:58] ASSISTANT:
The Validation hooks are in. Now I'm writing the TitleValidation bridge and checking the test fixtures it can use.

[2026-10-01 14:58] ASSISTANT:
Now the bridge module.

[2026-10-01 15:01] ASSISTANT:
All 14 new tests pass. To make sure the key test really needs the new hook, I'll briefly disable the hook and confirm the test fails.

[2026-10-01 15:01] ASSISTANT:
While the full suite runs, I'm updating CLAUDE.md and docs/plugin-system.md.

[2026-10-01 15:02] ASSISTANT:
The full test run exited with an error, so I'm finding which test executable failed.

[2026-10-01 15:03] ASSISTANT:
Now a shipped test showing the warning through the real plugins: in Issues and as a dot on the row.

[2026-10-01 15:03] ASSISTANT:
Shipped tests pass. Now I'm running the full suite again, plus the release benchmarks, since the new rule reads every title in the file on validation's first read.

[2026-10-01 15:04] ASSISTANT:
I'm waiting on the full suite and the benchmarks. No commit until you've had a look.

[2026-10-01 15:04] ASSISTANT:
The full test suite and the release benchmarks are still running in the background; I'll report when they finish. Nothing is committed.

[2026-10-01 15:04] USER:
great when these are in, if it's validated and the tests pass, you can squash merge. fyi i just asked another agent to merge as well so maybe wait 3 min

[2026-10-01 15:04] ASSISTANT:
The full suite passes. Before landing, my rule is a code review, so I'm committing on the branch and reviewing while the benchmarks finish.

[2026-10-01 15:04] GIT:
git add -A && git commit -q -F - <<'EOF'
Warn when two shapes share a title

The owner noticed nothing warned when two shapes have the same name, and said there should be.
Titles name shapes: `canvas draw` refuses a title two shapes have (`ambiguous_title`), a query's
"Title" finds both, the `@` picker lists both. Yet a paste keeps the title of what it copied and a
person renames as they like, so a file reaches that state with nothing saying so.

TitleValidation, a bridge on Titles and Validation, warns on each shape whose title another shape
in the file has: “Checkout” is another shape’s title too., about `title` where Titles keeps it.
Decided with the owner: file-wide (draw and the picker find titles across every board now); titles
as Titles reads them, named or derived (a schema card's), so an untitled note's first line isn't
one; compared exactly once folded, as draw matches; a warning, since each shape is fine alone.
The message names no count, so only a title's first other holder or its last changes another
shape's verdict.

Validation re-checks the shapes a commit changed and those whose rules looked one up, and neither
reaches a shape whose title a third shape was just renamed to. So Validation gains two generic
pieces rather than knowing titles: a rule may read a service (`context.service`), and names, with
`affected` (as a table-of-contents row does), the shapes each commit changes its issues of, on any
board; the engine checks those on the board shown again, and those on a board it keeps once it's
taken back (`BoardStash.modify`). `engine.affected(by:)` replaces `dependents(of:)` for
ValidationContents' marks, so a dot comes and goes on a row the commit didn't touch, there too on
going back. `validationIssues(of:in:editor:)` lends the services to a query's check of a board not
shown; draw's checks have no editor, and draw refuses a shared title anyway.

The bridge's `TitleIndex` is the file's titles, read as the rule first asks and kept up to date by
each commit wherever it changed a title, never a move, so the rule ignores moves and reads no other
shape.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -1

===== [2026-10-01 15:04] commit written: Warn when two shapes share a title =====

[2026-10-01 15:05] ASSISTANT:
The review found nothing to fix. Next: wait for the benchmarks, then the 3 minutes you asked for, before rebasing.

[2026-10-01 15:07] ASSISTANT:
Both fixes are in, and the docs match. Now I'm re-running the benchmarks and the tests.

[2026-10-01 15:07] ASSISTANT:
I'll come back when the benchmarks and the tests finish. The other agent's 3 minutes will have passed by then.

[2026-10-01 15:08] USER:
you can merge now

[2026-10-01 15:08] ASSISTANT:
I'll merge once the benchmark and test runs finish; I'm waiting on them now.

[2026-10-01 15:10] ASSISTANT:
The machine is busy (load near 10, another agent compiling), so these timings are noise. I'll compare with and without the plugin back to back, a few runs each.

[2026-10-01 15:10] ASSISTANT:
Every run is noise: even without the plugin it measured 33 ms once. I'll wait for the other agent's build to finish and measure on a quiet machine.

[2026-10-01 15:13] USER (sent mid-turn):
you should have the machine to yourself for enough time to build right now

[2026-10-01 15:14] ASSISTANT:
Still about 2 ms over. I'll time the index's pass and the engine's new step separately.

[2026-10-01 15:14] ASSISTANT:
The deletion's pass now takes 0.2 ms (the 1.3 ms lines are the undos), yet the commit is still 2 ms slower. I'll time each service's handling of the deletion commit to find where the rest goes.

[2026-10-01 15:16] ASSISTANT:
The services' share of the deletion commit is only 1.2 ms, so I'll compare that share with the plugin left out.

[2026-10-01 15:16] ASSISTANT:
The services add only 0.2 ms, so the other ~2 ms is outside them. I'll look at what else the commit does.

[2026-10-01 15:17] ASSISTANT:
The board removal costs the same either way. I'll time the transaction body against its commit.

[2026-10-01 15:17] ASSISTANT:
The extra 2 ms is inside the commit (13.7 ms against 11.5). I'll time the commit's own steps.

[2026-10-01 15:19] ASSISTANT:
Still 1.8 ms. Before restructuring anything, I'll check how many titles in the benchmark's file are actually shared, since only those can change another shape's warning.

[2026-10-01 15:20] ASSISTANT:
I've removed the timing code. Before merging I need your call on one benchmark, because no change inside the plugin alone brings it under budget.

[2026-10-01 15:20] ASK:
Q: Deleting a subboard of 10,000 shapes is over its 16 ms budget: about 15.2 ms on main, about 16.9 ms with the new warning. The tests pass and the review found nothing. The cost comes from the benchmark's file: its generator gives the notes on both nested boards the same titles ("Title 0", "Title 1", …), so 2,608 titles are each held twice, and the deletion has to update every one. A real file with that many duplicates would now be covered in warnings. How should I land it?
   options: Restructure, then merge (Recommended): Keep the index's titles per board, so deleting a board drops them at once. Also number titles across the whole generated file so they're unique. More work, and it may change some query benchmarks that look up "Title N".; Raise the budget: Raise the subboard-deletion budget a little (e.g. to 18 ms), note why in the benchmark, then merge.; Merge as is: Land it with that one benchmark over budget and deal with it later.

[2026-10-01 15:22] ANSWER:
Your questions have been answered: "Deleting a subboard of 10,000 shapes is over its 16 ms budget: about 15.2 ms on main, about 16.9 ms with the new warning. The tests pass and the review found nothing. The cost comes from the benchmark's file: its generator gives the notes on both nested boards the same titles ("Title 0", "Title 1", …), so 2,608 titles are each held twice, and the deletion has to update every one. A real file with that many duplicates would now be covered in warnings. How should I land it?"="Raise the budget". You can now continue with these answers in mind.

[2026-10-01 15:24] ASSISTANT:
The benchmarks all pass now; the deletion takes 17.45 ms against the new 18 ms budget. Next: squash, rebase onto main, and run the suite once more on top of whatever the other agent landed.

[2026-10-01 15:24] GIT:
git add -A && git commit -q --amend -F - <<'EOF'
Warn when two shapes share a title

The owner noticed nothing warned when two shapes have the same name, and said there should be.
Titles name shapes: `canvas draw` refuses a title two shapes have (`ambiguous_title`), a query's
"Title" finds both, the `@` picker lists both. Yet a paste keeps the title of what it copied and a
person renames as they like, so a file reaches that state with nothing saying so.

TitleValidation, a bridge on Titles and Validation, warns on each shape whose title another shape
in the file has: “Checkout” is another shape’s title too., about `title` where Titles keeps it.
Decided with the owner: file-wide (draw and the picker find titles across every board now); titles
as Titles reads them, named or derived (a schema card's), so an untitled note's first line isn't
one; compared exactly once folded, as draw matches; a warning, since each shape is fine alone.
The message names no count, so only a title's first other holder or its last changes another
shape's verdict.

Validation re-checks the shapes a commit changed and those whose rules looked one up, and neither
reaches a shape whose title a third shape was just renamed to. So Validation gains two generic
pieces rather than knowing titles: a rule may read a service (`context.service`), and names, with
`affected` (as a table-of-contents row does), the shapes each commit changes its issues of, on any
board; the engine checks those on the board shown again, and those on a board it keeps once it's
taken back (`BoardStash.modify`). `engine.affected(by:)` replaces `dependents(of:)` for
ValidationContents' marks, so a dot comes and goes on a row the commit didn't touch, there too on
going back. `validationIssues(of:in:editor:)` lends the services to a query's check of a board not
shown; draw's checks have no editor, and draw refuses a shared title anyway.

The bridge's `TitleIndex` is the file's titles, read as the editor opens (as Mentions' catalog is:
read lazily, a query's `:invalid` slice paid for it, 6.5 ms against 2) and kept up to date by each
commit wherever it changed a title, never a move, so the rule ignores moves and reads no other
shape. Deleting a subboard of 10,000 shapes went over its frame (15.2 ms on main, 16.9 with the
index): the generated file's two nested boards number their notes alike, so 2,608 titles are each
held twice and every one is taken out. The owner chose raising that budget to a frame and 2 ms over
keeping the index's titles per board and numbering the generated titles across the file.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git -C ~/code/native-canvas log --oneline -3 main; git rebase main 2>&1 | tail -3

[2026-10-01 15:24] ASSISTANT:
One conflict, in CLAUDE.md: main changed the Titles paragraph (a subboard's title is a pill now). I'll keep main's text and re-apply my additions on top.

[2026-10-01 15:25] GIT:
python3 - <<'EOF'
p='CLAUDE.md'
s=open(p).read()
i=s.index('<<<<<<< HEAD\n'); j=s.index('>>>>>>>'); jend=s.index('\n',j)+1
blk=s[i+len('<<<<<<< HEAD\n'):j]
ours,theirs=blk.split('=======\n')
mine_titles=[l for l in theirs.split('\n') if l.startswith('- Titles')][0]
add=mine_titles[mine_titles.index(" Nothing refuses two shapes one title"):]
pairs=[
("Rules see other shapes only through `ValidationContext` (`context.shape(_:)`, a lookup it notes, and `context.registry`, for a rule over every kind that asks about kinds, which is no lookup); `ValidationEngine` re-checks the shapes each commit's `ChangeSet` names and those whose rules looked one up.",
 "Rules see other shapes only through `ValidationContext` (`context.shape(_:)`, a lookup it notes, and `context.registry`, for a rule over every kind that asks about kinds, which is no lookup; `context.service(_:)` for a rule over what a plugin keeps across the file, nil where shapes are checked without an editor); `ValidationEngine` re-checks the shapes each commit's `ChangeSet` names, those whose rules looked one up, and those a rule's `affected` names (`affected: { changes, editor in … }` on the same three and `ValidationRule`: for a rule that reads a service, the shapes a commit may change the issues of without changing them, on any board, O(changed), asked as the engine hears each commit; on a board it keeps, they're checked once it's taken back). `engine.affected(by:)` is what a commit may change the issues of beyond what it changed (`dependents(of:)` and what the rules named; given `elsewhere`, the table of contents' catch-up on going back, what they named there meanwhile): what ValidationContents' marks read again."),
("`registry.validationIssues(of:in:)` runs a shape's rules against any `ShapeContext` (a transaction's: `canvas draw`'s warnings, through ValidationChecks), with schema verdicts of its own.",
 "`registry.validationIssues(of:in:editor:)` runs a shape's rules against any `ShapeContext` (a transaction's: `canvas draw`'s warnings, through ValidationChecks, with no editor), with schema verdicts of its own, and the editor's services if given one (ValidationQueries passes it)."),
("and a bridge may add rules, as MentionValidation warns about mentions that can't work (Mentions, below).",
 "and a bridge may add rules, as MentionValidation warns about mentions that can't work (Mentions, below) and TitleValidation about titles two shapes share (Titles, below)."),
]
for a,b in pairs:
    assert ours.count(a)==1,a[:60]; ours=ours.replace(a,b)
lines=ours.split('\n')
k=[n for n,l in enumerate(lines) if l.startswith('- Titles')][0]
assert lines[k].endswith("since Titles contributes no header."), lines[k][-80:]
lines[k]+=add
ours='\n'.join(lines)
s=s[:i]+ours+s[jend:]
open(p,'w').write(s)
EOF
grep -c "<<<<<<<\|>>>>>>>" CLAUDE.md; grep -o "TitleValidation" CLAUDE.md | wc -l; git add CLAUDE.md && GIT_EDITOR=true git rebase --continue 2>&1 | tail -1

[2026-10-01 15:25] ASSISTANT:
The rebase is done. Running the full suite on top of main:

[2026-10-01 15:26] ASSISTANT:
The suite passes on top of main, and the main checkout is clean. Merging and cleaning up:

[2026-10-01 15:26] ASSISTANT:
It's on main as 55e6bef.

When two shapes in the file have the same title, each now gets a warning: “Checkout” is another shape’s title too. It shows up like any other issue: an orange outline, a line in the Issues tab and an orange dot on its row. It works across every board, counts named titles and schema cards' titles but not an untitled note's first line, and ignores case and spacing only as Titles already does. The full suite passes on top of main.

- **New module:** the warning lives in a new bridge, TitleValidation, which keeps an index of every title in the file. It is read once as the file opens and updated by each edit.
- **Two additions to Validation:** a rule can now read a service, and can say which other shapes an edit affects. That's how renaming one shape to an existing title also warns the shape that already had it, even on another board.
- **Benchmarks:** they all pass, but only because the subboard-deletion budget is now 18 ms (a frame plus 2 ms), as you chose. Deleting the 10,000-shape subboard takes about 17.5 ms, against 15.2 ms on main. The benchmark file gives 2,608 notes the same titles on both of its boards, and the index has to take every one out.
- **Two other speedups along the way:** a `:invalid` query was paying to build the whole index inside one slice (6.5 ms against its 2 ms budget), so the index is now built when the file opens. Deleting shapes also no longer makes Validation look up every shape that went.

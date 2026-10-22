# Feature card prompt configuration

Claude Code session `13bafdb2-0138-4191-a93e-f8cb10322f8c`, 2026-10-22 03:07 to 2026-10-23 01:29 UTC, on `claude/feature-card-prompt-config-dce2aa`, `main`, `autofill-advanced`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-22 03:07] USER:
[image attached]

[2026-10-22 03:07] USER:
check this out 

the feature card should use a prompt like the json schema gen one to fill out this object. this behavior should be disable-able somewhere burried deep in the detail panel and should also be configurable by a $ property in json schema so that types can define default behavior like color works

[2026-10-22 03:07] ASSISTANT:
Reading the Types sync (the words↔schema prompt) and how `$color` works, so I can come back with a plan before writing code.

[2026-10-22 03:08] ASSISTANT:
Still mapping the code: no existing "fill a note's fields from its words" exists, so this is a new model call. Checking the Types panel and the value writer next.

[2026-10-22 03:10] ASSISTANT:
Here's the plan. Nothing's built yet; I'm waiting for your go-ahead.

**What it does:** You finish typing on a note of a type, or 3 s pass after your last keystroke. Haiku then reads the words and fills in the fields. "purpose is to be a foobar really good foob" becomes **purpose**: "to be a foobar really good foob". This uses the same timing and rules as the type's words↔schema sync, and it lands as its own undo step, "Fill Fields".

**Decisions I've made (say if you'd change any):**
1. **One way only.** Words fill values. Editing a row never rewrites the words.
2. **It only changes what your edit to the words changes.** The model gets the old words, the new words, the current values and the fields, as the schema sync gets the previous prompt. If you typed a value by hand and your edit to the words doesn't touch it, it stays. If you change a value while the model is working, your value wins. Relation rows (bug, idea, optimization) are arrows, so they're never filled.
3. **Only your edits start it.** `canvas draw`, undo and opening a file don't.
4. **The `$` property, like `$color`:** `"$autofill": {"const": false}` in a type's JSON, kept in step with the type's own `autofill` setting. A note stores its own `autofill` only when it differs from its type's. Otherwise it goes by its types (a type built on another inherits the setting), and with no setting anywhere it's on.
5. **The switch is buried:** a "Fill fields from words" checkbox at the very bottom of a note's Types tab. A type has the same checkbox at the bottom of its Schema tab, and that one writes `$autofill`. Under it is a status line: "Filling fields…", or the failure with Retry / Open Settings….
6. **On the canvas:** a quiet sign on the note while it fills. I'll settle the look with renders. Failures show only in the panel.
7. **Arrows too:** Types knows no kind, so a relationship arrow whose type has fields gets this from its label words for free.

**How it's built:**
- A fill service in Types' Sync part, which now also uses Fields. It writes through `FieldWriter` with a new door for several fields in one step.
- A new prompt, with a lite eval (`scripts/schema-prompts/fill_evals.py`, about 20 cases) that decides between Haiku 5.5 at `low` and `medium` effort.
- `$autofill` gets completions and a warning when it isn't true or false. The sync and the highlights never send it to the model.
- A fixture for the new `autofill` property, tests over `Memo`, and updates to the rules, the guide and the canvas skill.

[2026-10-22 03:10] WRAP-UP:
I've planned how a note fills its fields from its words with Haiku, switched off per type by `$autofill` in the JSON or per note by a checkbox at the bottom of the panel. Nothing is built yet.
Ask: Build it as planned?

[2026-10-22 03:10] ASSISTANT:
That's the plan above. Once you say go, I'll build all of it in this worktree and run the lite eval, then report back with renders of the note while it fills and of the checkbox in the panel.

[2026-10-22 03:13] USER:
are both prompt lite evals using the same infra

[2026-10-22 03:14] WRAP-UP:
The two schema-prompt evals share conventions but not code: each has its own copy of the key loading, the Swift reading and the API call. Nothing is built yet, and the plan still waits on your go-ahead.
Ask: Build it, with the three evals sharing one module?

[2026-10-22 03:14] ASSISTANT:
No, they don't share code. The two existing schema-prompt evals are [evals.py](scripts/schema-prompts/evals.py) (the words↔schema sync) and [highlight_evals.py](scripts/schema-prompts/highlight_evals.py) (the highlights). They work the same way:
- they read the prompts, model and effort out of the Swift
- they take the key from the app's Settings file or `$ANTHROPIC_API_KEY`
- they copy how the app reads an answer.

But each has its own copy of that setup: loading the key, reading prompts out of the Swift, the API call with its retries, and stripping fences from an answer. All they share is a few helpers for writing cases, from `gen_cases.py`. The two copies have already started to differ: only the highlights eval knows that Haiku 4.5 takes a temperature rather than an effort.

The `--ask` eval works differently again. It's a Swift test that runs the shipped code against the real model (`QueryLiveTests.swift`, `QUERY_LIVE=1`), so nothing in it is a copy.

As I planned it, the fill eval would have been a third copy of that setup. I'd add it to the plan this way instead:
- move the shared setup into one module beside them (`scripts/schema-prompts/evalkit.py`)
- switch the two existing evals to it, and check with their `--check` self-tests that their behavior didn't change
- build the fill eval on it.

[2026-10-22 03:14] USER:
Build it as planned, with the shared eval module.

[2026-10-22 03:18] ASSISTANT:
Reading the code the fill touches (the sync's lifecycle, the value writer, the `$color` machinery) before writing anything.

[2026-10-22 03:18] ASSISTANT:
Still reading: the fixture tests and the Types panel, then the tests' helpers. Writing starts right after.

[2026-10-22 03:18] ASSISTANT:
Reading the type index (where inherited settings resolve) and the End section, which is the precedent for a checkbox in the Types tab.

[2026-10-22 03:20] ASSISTANT:
Mapping is nearly done; last look is how a type's note draws its "reading" bars, to reuse that for the fill's sign on the canvas.

[2026-10-22 03:22] ASSISTANT:
I've mapped what I need. Next: a few API checks (property opt-ins, change sets), then I start writing the property and the `$autofill` directive.

[2026-10-22 03:23] ASSISTANT:
Writing now. First the generic directive helpers (so `$color` and `$autofill` share one implementation), then the `autofill` property.

[2026-10-22 03:24] ASSISTANT:
Now writing the shared directive file and slimming `$color` onto it.

[2026-10-22 03:26] ASSISTANT:
Directive plumbing is in; adding `$autofill` to the Schema tab's completions now, then the first build.

[2026-10-22 03:26] ASSISTANT:
First build of the directive and property changes (running in the background while I write the fill service).

[2026-10-22 03:29] ASSISTANT:
Prompt file written. Now the fill service itself, modeled on the schema sync's lifecycle (waits, commits, undo, cancel on close).

[2026-10-22 03:29] ASSISTANT:
No errors in that build; it only stopped because I added a file mid-build. Writing the fill service now.

[2026-10-22 03:31] ASSISTANT:
Service and writer door are in. Building now to catch compile errors before the panel and rows work.

[2026-10-22 03:31] ASSISTANT:
The fill service and writer are written; build is checking them now. Next: the panel checkbox, the "filling" sign on the note's rows, then tests.

[2026-10-22 03:32] ASSISTANT:
While the build runs, starting the shared eval module (Python only, so it can't disturb the Swift build).

[2026-10-22 03:32] ASSISTANT:
Types compiles. Only the color-directive tests broke, since they called the helpers I moved; updating them to the shared ones.

[2026-10-22 03:33] ASSISTANT:
Now the panel: the checkbox at the foot of the Types tab (and the type's Schema tab), its status line, and the writer that keeps a note's own say only where it differs from its type's.

[2026-10-22 03:33] ASSISTANT:
Now the sign on the canvas: while a fill is out, a note's empty field rows show the same soft bar a type's note shows while its schema is being read.

[2026-10-22 03:34] ASSISTANT:
Everything compiles. Running the full suite now to see what the change disturbs, while I write the new tests.

[2026-10-22 03:36] ASSISTANT:
Writing the new tests now (fill lifecycle, the prompt's parse rules, `$autofill` kept in step, the panel box).

[2026-10-22 03:38] ASSISTANT:
Now the `$autofill` and panel tests.

[2026-10-22 03:39] ASSISTANT:
While the suite runs, switching the two existing evals onto the shared module.

[2026-10-22 03:40] ASSISTANT:
The suite mostly passes; a handful of existing tests assumed the exact sections or buttons in the panel, which my new box changes. Looking at each.

[2026-10-22 03:41] ASSISTANT:
Most remaining failures are pinned texts that now include `autofill` (the registry report, the note's schema, the skill's attribute tables). Updating each from what the build actually says.

[2026-10-22 03:41] ASSISTANT:
My replacement also hit three prose lines in the guide that start with "arrows" or "types". Restoring the guide and redoing it inside the report block only.

[2026-10-22 03:42] ASSISTANT:
The remaining skill-test failures want `autofill` documented where agents read a note's and an edge's attributes. Updating the canvas skill.

[2026-10-22 03:44] ASSISTANT:
Everything builds. Running the Types, StickyNotes and Composition tests that touch this.

[2026-10-22 03:54] ASSISTANT:
Types tests all pass (1,341). Running the whole suite in the background while I write the fill eval.

[2026-10-22 03:56] ASSISTANT:
The eval's self-test passes. Running it live against Haiku 5.5 (the owner's standing rule for new Haiku prompts; the key is read from Settings and never printed).

[2026-10-22 03:56] ASSISTANT:
71 of 72 right at `low` effort, about a second each. Comparing `medium` before picking.

[2026-10-22 03:56] ASSISTANT:
`medium` was 72 of 72 at the same speed (median 0.9 s), so I'm shipping `medium`, matching the schema sync. One more round to confirm.

[2026-10-22 03:57] ASSISTANT:
Medium is 144 of 144 over two rounds. Recording the results in the evals' README.

[2026-10-22 03:57] ASSISTANT:
While the suite finishes: renders. Looking at the gallery harness to add the fill's states (a note filling, filled, and the panel box).

[2026-10-22 03:58] ASSISTANT:
The suite run was stopped partway (CompositionTests and the benchmarks were interrupted, likely by my editing a source mid-run). Rebuilding and rerunning those two directly.

[2026-10-22 03:58] ASSISTANT:
While those run, updating the Types rules file (the subsystem's topic file must change in the same commit).

[2026-10-22 03:59] ASSISTANT:
Rules files are updated. Now the guide: a short section on the fill beside the sync's, and the sync's note on `$color` extended to `$autofill`.

[2026-10-22 03:59] ASSISTANT:
Guide updated. Now the gallery states for renders: the owner's Feature note filling, filled, and the panel box.

[2026-10-22 04:00] ASSISTANT:
While the suite runs, checking one edge: a fill landing while the person is still typing in the note. Does its write join their typing step or stay its own?

[2026-10-22 04:01] ASSISTANT:
Waiting on the composition tests; no further edits to sources until they report.

[2026-10-22 04:01] ASSISTANT:
The code, tests, eval and docs are in place. I'm waiting on the composition test run, which is slow because other sessions' builds are sharing the machine.

[2026-10-22 04:01] ASSISTANT:
While the run finishes, re-reading the fill service end to end for mistakes.

[2026-10-22 04:12] ASSISTANT:
Composition (764) and StickyNotes (132) tests all pass, though against a build from just before my last small edits. Running the full suite once more on a clean build, touching nothing meanwhile.

[2026-10-22 04:17] ASSISTANT:
Clean build. Running the full suite now, hands off until it reports.

[2026-10-22 04:28] ASSISTANT:
The whole suite passes ("all test executables passed"). Rendering the fill's gallery states now.

[2026-10-22 04:36] ASSISTANT:
Renders are done. Last step before reporting: a code review of the whole diff, per your standing "review before landing" rule.

[2026-10-22 04:36] ASSISTANT:
Fixing the one real behavior bug (an agent's words treated as never read) and the test clock leak.

[2026-10-22 04:43] WRAP-UP:
Notes now fill their fields from their words with Haiku 5.5, switched by `$autofill` on a type or a box at the foot of the panel. The suite passes and the lite eval scored 144 of 144. Nothing is committed yet.
Ask: Land it on main?

[2026-10-22 04:44] ASSISTANT:
Notes of a type now fill their fields from their words with Claude. The whole suite passes, the new prompt's live eval got every answer right, and nothing is committed yet. On your foob note, Haiku fills **purpose** with "to be a foobar really good foob" and leaves status and estimate empty, since the words don't say them (renders above).

**How it behaves**
- **When it runs:** when you finish editing a note's words, or 3 s after your last keystroke. It also runs at once when you give a note a type, and when you turn the switch on.
- **What it changes:** only what your edit to the words changes. A value you typed by hand stays, and if you change a value while Claude is working, yours wins.
- **When it doesn't run:** `canvas draw` writes, undo, opening a board, or a change to a type. Filling every note of a type each time the type changed would cost a model call per note.
- **Undo:** each fill is its own undo step, "Fill Fields".
- **While it works:** the note's empty field rows show a grey bar, and the panel says "Filling fields…" (or why it failed, with Retry or Open Settings…).

**The switches**
- **On a type:** `"$autofill": {"const": false}` in its JSON is the default for its notes, kept in step with the type the way `$color` is. A type built on another inherits it.
- **On a note:** a "Fill fields from words" checkbox at the very bottom of the Types tab. A note stores its own setting only when it differs from its type's, so one that agrees keeps following the type.
- **On a type's Schema tab:** the same box sits at the foot, labelled "Notes fill fields from words". I changed that label after seeing the render, because "Fill fields from words" read as if the type itself fills.
- **Arrows:** relationship arrows get the same behavior from their label words.

**Evals:** the two existing evals and the new fill eval now share one module, `evalkit.py`. The two existing evals' self-checks give the same output as before the move. I tested two effort levels on 24 cases, three runs each:

| Effort | Right | Median time |
|---|---|---|
| `low` | 71 of 72 | ~1 s |
| `medium` | 144 of 144 (two rounds) | ~0.9 s |

`medium` was no slower, so it ships at `medium`, like the schema sync. The results are in the evals' README.

**From the code review:**
- **Fixed:** a note drawn by `canvas draw` would have been filled the next time you opened and closed it without typing. Its words now count as already read.
- **Fixed:** a test clock that leaked between tests is now reset after each test.
- **Left as they are:** some small duplications: the `$autofill` and `$color` sync rules, the panel's status line, and one eval helper.

The agent docs (canvas skill) and the rules and guide describe the new setting.

[2026-10-22 11:26] USER:
Land it.

[2026-10-22 11:27] ASSISTANT:
Main has moved two commits since this branch was cut (panel ordering, and session records as directories), so this needs a rebase. Committing the work first.

[2026-10-22 11:27] COMMIT MESSAGE FILE commit-message.txt:
A note of a type fills its fields from its words: Claude reads what the person wrote and sets the values it gives, where the note and its types' `$autofill` say so

The owner, looking at a Feature note whose words said "purpose is to be a foobar really good foob" above an
empty `purpose` row: "the feature card should use a prompt like the json schema gen one to fill out this
object. this behavior should be disable-able somewhere burried deep in the detail panel and should also be
configurable by a $ property in json schema so that types can define default behavior like color works".
The plan was approved as proposed ("Build it as planned, with the shared eval module"); its calls are mine
unless said.

- The fill (`FieldFill`, Types' Sync part, which now uses Fields) goes one way, words to values: a value typed
  by hand never rewrites the words. Only the person's edit of the note itself starts one: its words (once
  editing them ends, else 3 s after the last keystroke, as the schema sync waits), a type given to it, its
  own say turned on, or editing it ending over words never read (a note written before its type had
  fields). Never `canvas draw`, undo or redo, a board opened, or a change to a type: filling every note of a
  type whenever the type changed would ask the model once a note, and was left out for that.
- What it asks (`FillPrompts`): the fields as a JSON Schema (another type's fields written out in place of
  its reference), what they hold, today, the words, and the words they were last filled from, as the
  schema sync sends the prompt before, so the model changes only what the edit changed and a value typed by
  hand that the edit didn't touch stays. The answer is the changes, a JSON object, `null` taking a value
  away, written to the note's fields alone and never over a value the person changed while the call was
  out, through the one writer (`FieldWriter.fill`): one undo step, "Fill Fields". Relation rows are arrows
  and are never filled; a relationship arrow fills from its label, since Types knows no kind.
- Whether: `autofill`, an added property on the typeable kinds, is a shape's own say; on a type it is what
  its shapes do, kept in step with `"$autofill": {"const": false}` in its schema as a type's color is with
  `$color` ("like color works"), and passed down to the types built on it; with nothing said, on. A note
  holds its own say only where it differs from its types', so one that agrees follows them. The switch is a
  box at the foot of the Types tab, "Fill fields from words", and of a type's Schema tab, "Notes fill
  fields from words" (relabelled from the render: on a type the first read as the type itself filling).
- `$color`'s text edits are now one `HeldDirective` the two members share (`HeldDirectives`): neither is
  sent to the model, a schema written whole keeps both, and a change to them alone moves no revision and
  asks the sync nothing.
- On the board, while a call is out, a note's empty fields draw a bar where `add …` was; the panel says
  "Filling fields…", or why it failed, with Retry or Open Settings….
- The lite evals: asked whether the two that existed shared infrastructure, they didn't (each had its own
  copy of the key, the reading of the Swift and the call). `evalkit.py` is now the one copy, `evals.py` and
  `highlight_evals.py` moved onto it with their self-checks unchanged, and `fill_evals.py` (24 cases) is the
  fill's: Haiku 5.5 at `low` 71/72, at `medium` 144/144 over two rounds at the same median (~0.9 s), so it
  ships at `medium`, as the sync does.
- Agents: `canvas draw` writes `autofill:` on a note or an edge and `$autofill` in `schema:`, and a
  script's writes never start a fill. The canvas skill, the rules, the guide, the pinned report and the
  note's schema say so; `Fixtures/added/autofill.v0.json` is the property's fixture.

[2026-10-22 11:27] GIT:
git add -A && git status --short | grep -v '^[AM] ' | head; git commit -q -F /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-feature-card-prompt-config-dce2aa/13bafdb2-0138-4191-a93e-f8cb10322f8c/scratchpad/commit-message.txt && git log -1 --stat --format='%h %s' | tail -5

[2026-10-22 11:27] GIT:
git rebase main 2>&1 | tail -15; git status --short | grep '^UU\|^AA\|^DU\|^UD'

[2026-10-22 11:28] ASSISTANT:
Both conflicts are the pinned registry report: main reworded its entries to say where sections and menu items go, and I added `autofill` and `FieldFill`. Keeping main's wording and adding my entries.

[2026-10-22 11:28] GIT:
git add Tests/CompositionTests/ShippedTests.swift docs/plugin-system.md && GIT_EDITOR=true git rebase --continue 2>&1 | tail -2 && git log --oneline -3

[2026-10-22 11:28] ASSISTANT:
Rebased. Main's reordering change touched the panel API my box uses, so I'm doing a compile check plus the two pinned-report tests only, not the suite.

[2026-10-22 11:30] ASSISTANT:
The rebased branch compiles and both report tests pass. Writing this session's record.

[2026-10-22 11:30] ASSISTANT:
No keys or secrets in the record. Adding it to the commit with its `Session:` trailer.

[2026-10-22 11:30] GIT:
M=/private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-feature-card-prompt-config-dce2aa/13bafdb2-0138-4191-a93e-f8cb10322f8c/scratchpad/commit-message.txt && printf '\nSession: history/sessions/2026-10-22-feature-card-prompt-configuration-13bafdb2/\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n' >> $M && git add history/sessions/2026-10-22-feature-card-prompt-configuration-13bafdb2 && git commit -q --amend -F $M && git log -1 --format='%h%n%B' | tail -4 && git status --short | head -3; git log --oneline main..HEAD

[2026-10-22 11:30] ASSISTANT:
It's merged. Cleaning up the worktree and branch.

[2026-10-22 11:30] WRAP-UP:
The note fill and `$autofill` are on main as 1a8e32ec, with this session's record; the worktree and branch are removed.
Ask:

[2026-10-22 11:30] ASSISTANT:
It's on main as 1a8e32ec.

[2026-10-22 11:34] USER:
[image attached]

[2026-10-22 11:34] USER:
ok follow up task... this is not burried enough

[2026-10-22 11:35] WRAP-UP:
The box is on main at the foot of the Types tab. I propose moving it into a folded Advanced section, with the filling and failure line moved under Fields. Nothing is built yet.
Ask: Build it this way?

[2026-10-22 11:35] ASSISTANT:
That's the plan above. Nothing is built yet. Once you say go, I'll make it in a new worktree, test it, and send renders of the folded and opened panel before landing.

[2026-10-22 11:51] USER:
Build it this way.

[2026-10-22 11:51] ASSISTANT:
Building the "starts folded" piece in the detail panel first.

[2026-10-22 11:52] ASSISTANT:
Now writing the panel change: a section can be collapsed until opened, the state remembering each fold the person makes.

[2026-10-22 11:52] ASSISTANT:
Panel piece done. Now Types: the box goes into a titled "Advanced" section collapsed until opened, and the filling or failure line moves to the foot of Fields.

[2026-10-22 11:53] ASSISTANT:
Now the Types side. Moving the box under a folded Advanced section, and the filling and failure line to the foot of Fields.

[2026-10-22 11:53] ASSISTANT:
Rewriting the panel file: the box under a folded "Advanced" section, the status line moved out.

[2026-10-22 11:53] ASSISTANT:
The worktree guard refuses inline scripts here, so I'll make edits with the editor tool instead.

[2026-10-22 11:54] ASSISTANT:
Tests updated. Now the gallery states (folded, opened, filling) and the docs.

[2026-10-22 11:54] ASSISTANT:
Now the docs: the panel rule for folded sections, the Types rules, and the guide.

[2026-10-22 11:54] EDIT .claude/worktrees/autofill-advanced/docs/plugin-system.md:
`DetailPanelState` (`editor.detailPanel`) gathers each kind's contributions once, since the
registry is frozen, and resolves the selected shape's layout (running `when` and the headers) as
it's shown. It also remembers, per editor and in memory, the tab last chosen for each kind and the
collapsed sections. A collapsed every-box section collapses for every kind; a kind's own, for
that kind only.

A titled section that few people need starts collapsed: `DetailSection(…).collapsedUntilOpened()`
keeps it folded until the person opens it, as Finder's Get Info keeps Sharing & Permissions, and
from then on it is as they leave it, remembered as any collapse is. Types' Advanced, under a
shape's Fields, holds the box that turns off filling its fields from its words.

[2026-10-22 11:55] EDIT .claude/worktrees/autofill-advanced/docs/plugin-system.md:
passed down to the types built on it), else on: `TypeIndex.autofills`. A box says it, kept out of
  the way in a section called Advanced, collapsed until opened (`collapsedUntilOpened()`), at the foot
  of the Types tab (`Fill fields from words`) and of a type's Schema tab (`Notes fill fields from
  words`); a note holds its own say only where it differs from its types'.
- **On the board.** While a call is out the note's empty fields show a bar where `add …` was; the foot
  of the panel's Fields says `Filling fields…`, or why it failed, with Retry or Open Settings…, so
  folding the box away hides nothing that happens.

[2026-10-22 11:55] ASSISTANT:
Updating the Types rules for the folded section, then building and testing.

[2026-10-22 11:55] EDIT .claude/worktrees/autofill-advanced/.claude/rules/types.md:
- `FieldsList` reads `TypeIndex.observeChanges()` (an observed count `tell` bumps for each commit that changed a type), so a field added to a selected instance's type shows without a commit to the instance; a form must read it too. It reads `editor.isReadOnly` in its body as `TypesRow` does, so it runs again on every commit while its shape is selected, O(fields); the panel itself draws again for its shape's commits only (`panelsDrawn`).
- Where the shape's fill is, at the foot of the fields (`FillLine`, observing `FieldFill.status(of:)`, so it comes and goes with no commit): `Filling fields…` with a spinner (`TypesStyle.filling`), or the failure in the warning's tone with Retry, or Open Settings… for a key, or nothing for Claude declining; nothing while there's nothing to say. Here and not by the box that turns filling off, which is folded away ([below](#the-box-that-says-whether-a-shape-fills)), so folding it hides nothing that happens.

## The box that says whether a shape fills

`AutofillPanel.swift` (IsA, `registerAutofillPanel`, registered by `TypeDetailsPlugin` after the Fields): one `DetailCheckbox` in a section called `Advanced` (`TypePanelText.advanced`), collapsed until the person opens it (the panel's `collapsedUntilOpened()`, [detail panel](detail-panel.md); once opened it stays as they leave it for the window's session, for every shape it reaches), at the foot of two tabs. The owner, of the box when it sat open under the Fields: "this is not burried enough".

- A […1341 more chars]

[2026-10-22 11:55] EDIT .claude/worktrees/autofill-advanced/.claude/rules/detail-panel.md:
and the shape's panel draws again only when its record, whether it can change, its status lines or the sections `shownWhile` hides change (`panelsDrawn`, debug builds, counts it drawn). A titled section few people need is collapsed until the person opens it (`.collapsedUntilOpened()`, as Finder's Get Info keeps Sharing & Permissions folded: Types' Advanced, the box that turns off filling a note's fields from its words), then is as they leave it: `DetailPanelState` remembers what the person collapsed and opened by key (`isCollapsed`, `setCollapsed`), a section they haven't touched as it starts, and a headerless one never collapses (DetailPanelTests' `stateTests`).

[2026-10-22 12:18] ASSISTANT:
The machine is heavily loaded by other sessions' builds (load average around 50), so the Types run is slow. Waiting for it.

[2026-10-22 12:28] ASSISTANT:
All the new tests pass; three timing-budget tests failed at load average ~50, all in code this change doesn't touch (relationship landing, far pick, a draw run's cost). Rerunning just those three.

[2026-10-22 12:30] COMPACTED:
(the context was summarized here)

[2026-10-22 12:31] ASSISTANT:
Checking whether the three timing failures are machine load (load average ~50 now) by timing the same tests on a clone of main.

[2026-10-22 12:31] ASSISTANT:
Rendering the panel states (folded, filling, opened) while main's clone builds.

[2026-10-22 12:32] ASSISTANT:
The renders look right. Sending them, then the review while main's clone builds.

[2026-10-22 12:33] ASSISTANT:
Review found nothing that needs changing (three small notes, explained at the end). Checking on main's clone build for the timing comparison.

[2026-10-22 12:33] ASSISTANT:
Waiting on the clone's build to finish before timing the three tests side by side.

[2026-10-22 12:39] ASSISTANT:
Main fails the same three by the same amounts (landing ~174 ms both, pick ~163 vs ~164, edges ~7.2 s both), so they predate this change. Running the full suite now.

[2026-10-22 12:39] COMMIT MESSAGE FILE commit-msg.txt:
Fill fields from words moves into Advanced, a section folded until it's opened; the fill's status sits under the Fields

The owner, looking at the box under a note's Fields: "this is not burried enough". Almost no one turns the fill off,
so the box goes where Finder's Get Info keeps Sharing & Permissions: a titled section, Advanced, folded until the
person opens it, at the foot of a note's Types tab and of a type's Schema tab. Opened, or folded again, it stays as
they left it for the window's session, like any section's fold.

The fold is the detail panel's, not Types': `DetailSection.collapsedUntilOpened()`, which any plugin may give a
titled section (a headerless one never folds). `DetailPanelState` remembers what the person did to a section by
key, and a section they haven't touched is folded only if it asked to be.

"Filling fields…" and a failure with its Retry or Open Settings… moved out of the box to the foot of the Fields,
so folding Advanced away hides nothing that happens: the box only switches the fill, and the Fields say what it's
doing to them.

[2026-10-22 12:39] ASSISTANT:
Commit message drafted; waiting on the full suite.

[2026-10-22 12:49] ASSISTANT:
The suite is still running; I'll pick up when it reports.

[2026-10-22 12:56] ASSISTANT:
Full suite passed (every executable, the timing tests included this run). Committing in the worktree.

[2026-10-22 12:56] GIT:
git add -A && git commit -q -F /private/tmp/claude-501/-Users-zekenie-code-native-canvas/13bafdb2-0138-4191-a93e-f8cb10322f8c/scratchpad/commit-msg.txt && git log --oneline -2 && git status --short | head

[2026-10-22 12:56] WRAP-UP:
"Fill fields from words" now sits in an Advanced section that stays folded until it's opened, on a note's Types tab and on a type's Schema tab. The fill's status moved to the foot of Fields. It's committed on autofill-advanced (b8202bcd), not landed. The full suite passes.
Ask: Land it on main?

[2026-10-22 12:56] ASSISTANT:
The checkbox is now in a section called **Advanced** at the bottom of the panel, and that section stays folded until someone opens it. That's how Finder's Get Info keeps Sharing & Permissions out of the way. The four renders above show it.

- **A note's Types tab:** Advanced sits below Fields, folded. Opened, it holds "Fill fields from words". Once someone opens or folds it, it stays that way for the rest of the window's session.
- **A type's Schema tab:** Advanced sits below the JSON and holds "Notes fill fields from words".
- **While it's filling:** "Filling fields…" and any failure (with Retry or Open Settings…) now show at the bottom of Fields, not under the checkbox. Folding Advanced away hides nothing that's happening.
- **Folded until opened:** this is now a general option any plugin can use on a section with a title, `DetailSection.collapsedUntilOpened()`.

**Tests:** the full suite passes. An earlier run of the Types tests failed three timing checks while the machine was very busy. I ran the same three on a copy of main, alternating with this branch: main fails them by the same amounts, so this change didn't cause them. They passed in the full run.

**Review:** nothing needed changing. One side effect: if someone folds Fields, a failed fill is hidden along with the fields themselves.

It's committed in the worktree on `autofill-advanced` (b8202bcd) and not landed yet.

[2026-10-23 01:29] USER:
Land it.

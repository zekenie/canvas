# Type detail panel schema/connections order

Claude Code session `f9df5e12-3d5f-4a66-9375-ea5916956041`, 2026-10-22 03:13 to 2026-10-22 03:36 UTC, on `claude/type-detail-panel-schema-connections-641e4c`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-22 03:13] USER:
[image attached]

[2026-10-22 03:13] USER:
detail panel for types should reverse schema and connections such that connections is default.

[2026-10-22 03:13] ASSISTANT:
Found it: tab order is a number per tab — Schema is 0 (first), Connections 60, Style 100. Checking the edge cases before changing it.

[2026-10-22 03:14] ASSISTANT:
Plan: give the Schema tab order 70 (after Connections' 60, before Style's 100). Now checking which tests open a type's panel expecting Schema to show by default.

[2026-10-22 03:14] ASSISTANT:
Types' own test editor has no Connections tab, so its panel tests keep Schema first; the shipped ones will change. Making the edit and updating the tests and topic files.

[2026-10-22 03:15] ASSISTANT:
Docs and tests updated. Checking for shipped-panel tests that select a type and expect its JSON editor without choosing a tab.

[2026-10-22 03:15] ASSISTANT:
`BoardWindowTests`' `schemaCode` selects a type and waits for the JSON editor, so it now needs to choose the Schema tab. Checking the relationship-description window too.

[2026-10-22 03:15] ASSISTANT:
Now building and running the full test suite.

[2026-10-22 03:15] ASSISTANT:
The full test run is going in the background; I'll report once it finishes.

[2026-10-22 03:21] USER:
<!-- reply 1 -->
> tab order is a number per tab

at some point id like to discuss alternatives to this perhaps?

[2026-10-22 03:21] ASSISTANT:
Sure. A few directions that would replace the bare numbers:

- **Relative placement:** a tab says `after: NeighborsTab.self, before: StyleTab.self` and the registry sorts them, refusing a cycle. The intent is easy to read, but each such line ties the tab's module to the module that declares the other tab.
- **Named slots:** the bands become an enum (`.kindOwn`, `.feature`, `.connections`, `.style`, `.state`), and tabs in the same slot go in plugin order. That gets rid of picking numbers like 70, but a case like this one (Schema after Connections) needs a slot of its own.
- **Order set in the manifest:** the shipped list in `Package.swift` says the order of the tabs, the same way it already orders plugins. The whole order would be visible in one place.
- **Separate the default from the strip order:** what you asked for today was really "a type opens on Connections." A shape could name its default tab while the order of the strip stays as it is.

My pick would be named slots plus the manifest order. Whenever you want to dig in is fine. The test run for the change is still going, and I'll report when it finishes.

[2026-10-22 03:22] USER:
i need some help considering implications for each

[2026-10-22 03:23] ASSISTANT:
One thing applies to all four, so first: the panel remembers the last tab chosen **per kind**, and a type and a plain note are both the kind "note". The order only decides what you see before you've picked a tab. Once you click Schema on one type, every type opens on Schema until you pick something else.

There are seven tabs today, from five modules. Here's what each option would mean:

**1. Relative placement** (`after: NeighborsTab.self`)
- **Gain:** the code says what it means, and the registry can refuse a cycle when the plugin list loads.
- **Cost:** naming another tab means importing its module. The layer rules can forbid that: Style lives in DetailPanel, which can't name a tab declared above it.
- **Cost:** a rule about a tab that isn't installed has to be dropped silently.
- **Cost:** tabs with no rule between them still need a tie-break, which would be plugin order.

**2. Named slots** (own, feature, shared, state)
- **Cost:** the slots have to stay generic, because DetailPanel can't know about Connections or Schema. Both would land in "feature" and fall back to plugin order.
- **Cost:** in the shipped list, `TypeDetailsPlugin` comes before `NeighborDetailsPlugin`. So this brings back Schema-first, and today's change would mean moving Types later in the list. That would also move what else plugin order decides, like the order of a note's slash commands.
- This is what made me drop my earlier pick.

**3. Order in the manifest**
- **Gain:** the whole strip order is in one place, next to the other product decisions.
- **Cost:** tabs aren't plugins, so `build.sh` would need a second table.
- **Cost:** test registries built without the manifest would order tabs differently from the app, so tests that check tab order wouldn't be testing what ships.
- **Cost:** a new tab falls to the end until someone adds it to the table.

**4. Separate the default tab from the strip order**
- **Gain:** this is what you actually asked for today. The strip could stay stable (Schema on the left) while types open on Connections.
- **Cost:** someone has to declare the default. Types would, by naming Neighbors' tab. Two plugins that want different defaults for one shape need a rule.
- **Cost:** you'd have to decide whether a declared default beats the remembered per-kind choice.
- **Cost:** opening on a tab in the middle of the strip is less conventional.

My take now: with seven tabs, numbers are cheap. The cheapest improvement is naming the bands as constants in DetailPanel so nobody picks "70" by hand. If "which tab opens first" keeps coming up, option 4 is the real fix, and the per-kind memory decision comes with it.

The test run for today's change is still going.

[2026-10-22 03:24] NOTICE:
background task completed: Background command "./test.sh &gt; /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-type-detail-panel-schema-connections-641e4c/f9df5e12-3d5f-4a66-9375-ea5916956041/scratchpad/test.log 2&gt;&amp;1; echo "exit $?"" completed (exit code 0)

[2026-10-22 03:24] ASSISTANT:
Two failures, both CPU-time budgets in TypesTests (relationship landing, 2,500 untyped edges), unrelated to tab order. Rerunning them alone, off the parallel load.

[2026-10-22 03:25] ASSISTANT:
Load average is 12.5, so the machine is busy. Running the same test on the base commit for comparison.

[2026-10-22 03:25] ASSISTANT:
The suite ran: everything passed except two CPU-time budgets in TypesTests. One of them failed again when run alone, so I've started the same test on the base commit to tell a slow machine from a real regression. I'll report when it finishes.

[2026-10-22 03:29] NOTICE:
background task completed: Background command "cd /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-type-detail-panel-schema-connections-641e4c/f9df5e12-3d5f-4a66-9375-ea5916956041/scratchpad/base &amp;&amp; TEST_FILTER="relationshipLanding" ./test.sh 2&gt;&amp;1 | grep -E "relationshipLanding|FAIL|expectation|all test" | head" completed (exit code 0)

[2026-10-22 03:30] ASSISTANT:
Branch 134/133/121 ms, base 109/130/120 ms: they overlap, and both straddle the 128 ms debug budget at this load. It isn't this change. Removing the scratch clone.

[2026-10-22 03:30] WRAP-UP:
A type's panel now opens on Connections, with Schema after it: tab order Connections, Schema, Style. Every test passes except one CPU-time budget that fails on the base commit too under this load. Nothing is committed, and it isn't checked in the running app.
Ask: Review and land it?

[2026-10-22 03:30] ASSISTANT:
A type's detail panel now opens on Connections. Its tabs read Connections, Schema, Style; before it was Schema, Connections, Style. Nothing is committed, and I haven't looked at it in the running app.

- **The change:** the Schema tab now sorts at 70, between Connections (60) and Style (100), in [TypePanel.swift](Sources/Types/IsA/TypePanel.swift).
- **Tests:** three tests that check tab order now expect the new one. One window test in [BoardWindowTests.swift](Tests/CompositionTests/BoardWindowTests.swift) selects a type and waits for the JSON editor; it now picks the Schema tab first, since a type no longer opens there.
- **Docs:** the tab-order lists in the guide and the topic files for the detail panel, types and neighbors now include the Schema tab.
- **Test run:** everything passed except two CPU-time budgets in TypesTests, on a machine with a load average around 13–18. The untyped-edges test passes when run alone. The relationship-landing test fails on the base commit too: I ran it three times on each, and the branch took 121–134 ms against 109–130 ms on the base, with a budget of 128 ms.
- **One case to know:** a type built on another type also has the Types tab, which sorts ahead of Connections. So that type opens on Types, then Connections, Schema, Style. Making Connections first there too would mean moving it ahead of Types for every shape.
- **Remembered tab:** once you click a tab on any note, the panel opens that tab on every note that has it, types included.

[2026-10-22 03:35] USER:
land it then let's talk about the other thing

[2026-10-22 03:36] ASSISTANT:
Landing requires a code review first, so: commit on the branch, review, then the record and the merge.

[2026-10-22 03:36] GIT:
git rev-parse --short HEAD main && git log --oneline -3 main && git add -A && git commit -q -m "wip: a type's panel opens on Connections" && git log --oneline -1

[2026-10-22 03:36] GIT:
git add -A && git commit -q -m "wip: a type's panel opens on Connections" && git log --oneline -1

[2026-10-22 03:36] ASSISTANT:
Review found nothing. Writing the session record and the commit message, then rebasing onto main.

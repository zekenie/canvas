# Type detail panel schema/connections order

Claude Code session `f9df5e12-3d5f-4a66-9375-ea5916956041`, 2026-10-22 03:13 to 2026-10-22 11:19 UTC, on `claude/type-detail-panel-schema-connections-641e4c`, `main`, `relative-order`.

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

[2026-10-22 03:36] COMMIT MESSAGE FILE msg.txt:
A type's detail panel opens on Connections: its tabs read Connections, Schema, Style

The owner asked that a type's panel swap Schema and Connections so Connections is the default: what
a type is connected to (its instances, subtypes, arrows) is what they want to see first, and the
schema is a tab away. The panel opens on the first tab until a tab is chosen, and remembers the
choice per kind (a type and a plain note are both notes), so this decides what a type shows before
anything is picked.

TypeSchemaTab goes from order 0 (a kind's own band) to 70, after Neighbors' Connections (60) and
before Style (100). A type built on another also has the Types tab (50), so it opens on Types, then
Connections, Schema, Style: putting Connections ahead of Types would move it ahead for every
instance too, which was not asked.

How tab order is said (a number a tab) came up as something the owner wants to discuss: relative
placement, named slots, an order in the manifest, or a default tab apart from the strip's order.
Nothing of that is decided here.

Session: history/sessions/2026-10-22-type-detail-panel-schema-connections-order-f9df5e12.md
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>

[2026-10-22 03:36] GIT:
git add history/sessions/2026-10-22-type-detail-panel-schema-connections-order-f9df5e12.md && git reset -q --soft d5c504ae && git commit -q -F /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-type-detail-panel-schema-connections-641e4c/f9df5e12-3d5f-4a66-9375-ea5916956041/scratchpad/msg.txt && git rebase main 2>&1 | tail -2 && git status --short -b | head -3 && git -C /Users/zekenie/code/native-canvas status --short | head

[2026-10-22 03:36] ASSISTANT:
Landed. Cleaning up the worktree and branch.

[2026-10-22 03:36] WRAP-UP:
The tab-order change is on main as 745ad47b, and its worktree and branch are removed. Next is the tab-order discussion: no decision on that yet.
Ask:

[2026-10-22 03:37] ASSISTANT:
It's on main as 745ad47b.

On tab order, the useful split is between two questions the numbers answer together today:

1. **What order the strip shows.** This rarely matters: there are seven tabs, and most shapes show two or three.
2. **Which tab a shape opens on.** This is what your request was really about, and the panel's per-kind memory overrides it as soon as you pick a tab.

So which of these do you care about? If it's only "types open on Connections", option 4 (a default tab apart from the order) is the precise fix. That also means deciding whether the remembered choice should follow the kind (note) or something finer, such as "a type" versus "a plain note". If you want the strip itself easier to reason about, that's options 1–3, and I'd start by naming the bands.

[2026-10-22 03:40] USER:
i feel someone should be able to almost hyperlink to a shape @ a tab, and that should be legal. like not literally hyperlink but certain app actions might want to navigate to elem snd focus a card and that seem slike a good public api. not sure if that fully answers your question

[2026-10-22 03:41] ASSISTANT:
Yes, it mostly answers it. You're saying "which tab a shape shows" is a navigation question. A tab is a place you can be sent to: a shape at a tab, maybe at a card. The default is then just where you land when nothing names a place. Strip order becomes a small cosmetic question, and the numbers can stay.

Some of it already exists, built by hand each time:
- **Going to a place:** `FieldCards.revealInPanel` selects a note and turns the panel to its Types or Schema tab. Publishing sends the panel to Connections when Make Private is refused. Each does `goTo` or select, then `detailPanel.choose(tab, for: kind)`.
- **Naming a tab:** a tab already has a stable name, `DetailTabID.name` (`Types.TypeSchemaTab`), commented "stable across launches, for persisting later". A link could name a tab today.

What a real API would have to settle:
1. **Memory:** `choose` sets the tab for the whole kind. A link that opens Schema on one type also makes every note open on Schema from then on. "Show this tab now" has to be separate from "remember this tab" (or deliberately the same).
2. **How deep the address goes:** shape@tab is the panel's to resolve. Shape@card (a field's card, a relationship's definition card) belongs to the plugin that owns the card. So the address is probably the shape plus a place the owning plugin resolves, with a tab as the case the panel handles itself.
3. **Who follows links:** in-app actions for sure. Agents (`canvas` going to a shape at a tab) and links in text would make it a public format, so the place names couldn't be renamed freely.

Want me to start a working doc for this destination API, with these questions in it for you to edit?

[2026-10-22 03:43] USER:
arg was hoping for some more clarity from you

[2026-10-22 03:44] ASSISTANT:
Sorry, here's a clear answer.

**Tab order:** keep the numbers. They do their job, and what you described isn't about order.

**What to build:** one public call, roughly `editor.reveal(shape, at: place)`. It goes to the shape on whatever board it's on, selects it, and opens the panel to the tab the place names. If the place is a card (a field's card, a relationship's definition card), it also asks the plugin that owns the card to open it. The two hand-built cases today, Types' `revealInPanel` and Publishing turning the panel to Connections, become calls to it.

**The one rule that matters:** a reveal shows its tab now but doesn't change the tab remembered for the kind. Only you clicking a tab changes that. Otherwise one link to a type's Schema would make every note open on Schema afterwards, which is what `choose` does today.

**Default tab:** nothing new is needed. With no place named, a shape opens on the remembered tab, else the first one, and today's order already makes that Connections for a type.

**Agents and links in text:** leave them for later. Tabs already have stable names (`DetailTabID.name`), so nothing built now gets in their way.

I can plan this whenever you want it.

[2026-10-22 03:50] USER:
i hate numbers. what would a complex desktop app do

[2026-10-22 03:50] ASSISTANT:
Complex desktop apps do one of two things:

- **Closed apps** (Xcode, Keynote, Figma): the app keeps one written list of inspector tabs for each kind of selection. Plugins can't add tabs, so there's no ordering problem.
- **Extensible apps** (IntelliJ, Eclipse): a contribution says where it goes relative to things it can name. IntelliJ uses `first`, `last`, `before X` and `after X`. Eclipse also has named anchor points declared by the host (`after=additions`). Registration order breaks ties, and the host sorts it all once at startup, rejecting a cycle.

VS Code is the exception: it still uses numbers inside named groups (`navigation@2`), and lets you drag to reorder and remembers that. Blender uses numbers too.

This app is an extensible one, so the IntelliJ/Eclipse model fits:

- **Anchors:** DetailPanel declares a few generic ones: the start, Style's place, the end.
- **Placement:** a tab says where it goes, such as Schema `after: NeighborsTab.self`, Issues `last`, Description `first`.
- **Resolution:** the registry sorts once when the plugin list loads, refuses a cycle, and names the order in its report.

The one constraint: a tab can name only tabs from modules it already depends on. That works for today's tabs (Types already imports Neighbors, and everyone sees DetailPanel's Style). When a tab can't name its neighbour, it places itself against an anchor instead.

Want me to plan the switch?

[2026-10-22 03:52] USER:
given the rest of the app what do you recommend

[2026-10-22 03:53] ASSISTANT:
I'd replace the numbers across the whole app, not just for tabs.

Three platform points order things with numbers: tabs, adornments and context-menu groups, with 31 numbers between them, all in the same banded pattern. Fixing tabs alone would leave two ways to say order, which goes against routing a concern through one mechanism.

**The rule:**
- A contribution says `first`, `last`, `before(X)` or `after(X)`, where X is a tab, menu group or adornment type from a module it already depends on.
- Anything it doesn't say goes by plugin order. That's already the tie-break everywhere: 14 topic files rely on it, so it stays the default.

**One resolver in Canvas:** it runs when the registry loads, refuses a cycle or a contradiction, and writes the resolved order into the registry report. The existing tests that pin that report then pin every order too.

**No anchors at first:** `first`, `last` and plugin order already cover what the bands do today (a kind's own tabs first, Issues last). I'd add an anchor only when a real case can't name its neighbour.

**Order of work:** three landings. Tabs first: seven of them, and where it bit. Then menu groups, then adornments, each in the same shape.

Want me to plan the first landing?

[2026-10-22 03:53] USER:
great. love it. you can use sub-agents just don't go crazy. keep high quality. be resourceful

[2026-10-22 03:56] ASSISTANT:
Still mapping: reading the shipped plugin order to work out what each tab, menu group and adornment must say to keep today's order.

[2026-10-22 04:04] ASSISTANT:
Short status: mapping done. I'm now settling the design details (how to keep today's orders using only things each module can name), then I'll post the plan and start building.

[2026-10-22 04:06] ASSISTANT:
Short status: design settled. Building the core piece now: one `Order` type and one resolver in Canvas.

[2026-10-22 04:08] ASSISTANT:
Status: probing a Swift 6 concurrency detail. A lazily read anchor needs the order protocols' metatypes to be sendable, so I'm checking that `SendableMetatype` fixes it cleanly.

[2026-10-22 04:08] ASSISTANT:
`SendableMetatype` works. Now converting the detail panel's tabs.

[2026-10-22 04:09] ASSISTANT:
Status: tabs are converted in DetailPanel. Now adding the cycle check and the report line, then the three other tabs.

[2026-10-22 04:10] ASSISTANT:
Status: tabs done. Now converting context-menu groups.

[2026-10-22 04:11] ASSISTANT:
Now the menu-group protocol and its two shared groups.

[2026-10-22 04:12] ASSISTANT:
Menu groups are converted in ContextMenus. Now each group's rule in its own module.

[2026-10-22 04:12] ASSISTANT:
Now adornments.

[2026-10-22 04:13] ASSISTANT:
All three are converted. Compiling now.

[2026-10-22 04:17] ASSISTANT:
The app builds. Now the tests' own fixtures that still use numbers.

[2026-10-22 04:18] ASSISTANT:
Fixtures converted. Starting the full test run in the background, and meanwhile writing the core tests for the resolver.

[2026-10-22 04:19] ASSISTANT:
Status: core tests written, full suite running. Meanwhile updating the guide and topic files where they describe the number bands.

[2026-10-22 04:20] ASSISTANT:
Status: rewriting the topic files' band descriptions as rules; the full test run is still going.

[2026-10-22 04:21] ASSISTANT:
Adding the canonical description of `Order` to the core's topic file.

[2026-10-22 04:21] ASSISTANT:
The run tripped over my edit mid-build. Rerunning; I'll only touch docs while it runs.

[2026-10-22 04:22] ASSISTANT:
Status: updating the guide (docs/plugin-system.md), which has about 25 places that describe the bands. The test run is still going.

[2026-10-22 04:22] ASSISTANT:
Writing the guide's changes now: a new Order section under The registry, and each band table and number rewritten as rules.

[2026-10-22 04:25] ASSISTANT:
The test run is still going; I'll pick up from its results.

[2026-10-22 04:25] ASSISTANT:
Waiting for the test run to finish; I'll continue from its results.

[2026-10-22 04:31] NOTICE:
background task completed: Background command "./test.sh &gt; /private/tmp/claude-501/-Users-zekenie-code-native-canvas/f9df5e12-3d5f-4a66-9375-ea5916956041/scratchpad/test2.log 2&gt;&amp;1; echo "exit $?"" completed (exit code 0)

[2026-10-22 04:34] ASSISTANT:
Making the kind-own tabs `.first` and the matching doc fixes.

[2026-10-22 04:35] ASSISTANT:
Now the publishing test's plugin order.

[2026-10-22 04:35] ASSISTANT:
Now the report expectations. Checking how the pinned reports are written so I can regenerate them exactly.

[2026-10-22 04:35] ASSISTANT:
Rerunning only the report tests (`TEST_FILTER=report`) to capture the new reports exactly.

[2026-10-22 04:37] ASSISTANT:
Writing a small script that takes each failing report equality from the log and puts the actual report into the test source in place of the old one.

[2026-10-22 04:37] ASSISTANT:
The guide check's failure is backwards (guide text vs report), so the script just put the old report back into ShippedTests. Re-applying the new report there, and writing it into the guide too.

[2026-10-22 04:37] ASSISTANT:
The shipped report's diff reads as intended. Now the report checks written as `contains` or line comparisons, by hand.

[2026-10-22 04:38] ASSISTANT:
Report expectations updated. Adding the refusal tests: a circle of tabs, menu groups and adornments, each refused by its point when the registry is built.

[2026-10-22 04:40] ASSISTANT:
The refusal tests pass. Starting the full suite again; no Swift edits until it's done.

[2026-10-22 04:40] ASSISTANT:
While it runs, reviewing my own diff of the sources.

[2026-10-22 04:40] ASSISTANT:
The diff reads coherently. One robustness fix to make after the run: `arranged` silently drops a second item with the same anchor. No caller passes one today, but the function shouldn't lose items, so I'll keep both. Waiting for the full run.

[2026-10-22 04:46] NOTICE:
background task completed: Background command "./test.sh &gt; /private/tmp/claude-501/-Users-zekenie-code-native-canvas/f9df5e12-3d5f-4a66-9375-ea5916956041/scratchpad/test3.log 2&gt;&amp;1; echo "exit $?"" completed (exit code 0)

[2026-10-22 04:47] ASSISTANT:
Two panel tests left. Looking at both.

[2026-10-22 04:47] ASSISTANT:
While it runs, the duplicate-anchor fix in `Order.swift` (the binary is already built, so editing is safe now).

[2026-10-22 04:48] ASSISTANT:
Adding a case for that to the core tests.

[2026-10-22 04:48] ASSISTANT:
Waiting for the CompositionTests run to locate the crash.

[2026-10-22 04:48] ASSISTANT:
Still waiting on the CompositionTests run.

[2026-10-22 04:51] NOTICE:
background task completed: Background command "TEST_TIMES=1 build/debug/CompositionTests/CompositionTests &gt; /private/tmp/claude-501/-Users-zekenie-code-native-canvas/f9df5e12-3d5f-4a66-9375-ea5916956041/scratchpad/comp.log 2&gt;&amp;1; echo "exit $?"" completed (exit code 0)

[2026-10-22 04:51] ASSISTANT:
The crash is in the test after "Board pictures, shipped: a board file as saved…". Finding which one that is.

[2026-10-22 04:54] ASSISTANT:
Updating the docs that described Transform's placement.

[2026-10-22 04:55] ASSISTANT:
Report expectations updated for Transform's new anchor. Full run again.

[2026-10-22 04:55] ASSISTANT:
Waiting for the full run.

[2026-10-22 05:16] NOTICE:
background task completed: Background command "./test.sh &gt; /private/tmp/claude-501/-Users-zekenie-code-native-canvas/f9df5e12-3d5f-4a66-9375-ea5916956041/scratchpad/test4.log 2&gt;&amp;1; echo "exit $?"" completed (exit code 0)

[2026-10-22 05:16] ASSISTANT:
While the comparison runs, committing the work on the branch (nothing lands without your go-ahead).

[2026-10-22 05:17] COMMIT MESSAGE FILE commit_msg.txt:
Tabs, context-menu groups and adornments say where they go beside each other, not by a number

The owner, after a tab had to be moved from order 0 to 70 to open a type's panel on Connections:
"i hate numbers. what would a complex desktop app do". Closed apps write one list; extensible ones
(IntelliJ, Eclipse) have a contribution say first, last, before X or after X, against what it can
name, registration order breaking ties. The owner approved that for the whole app, with plugin order
as what decides when nothing is said, one resolver in the core, the registry refusing a circle, and
the report saying every order.

- The core's `Order<Subject>` (`Sources/Canvas/Plugins/Order.swift`): `.first`, `.last`, `.before(X)`,
  `.after(X)`, `.natural` by default. A point's protocol requires `static var order: Order<Self>` and
  gives the sugar that names its own things (`extension Order where Subject: DetailTab`), so a tab can
  be placed only beside a tab, and only beside one its module imports. `OrderRule.arranged(_:by:)`
  starts from first appearance (a kind's own, then plugin order), puts one placed beside another
  right beside it, and puts one beside a thing that isn't there where that thing's own order would
  (read lazily from its type): in a list without Neighbors a type's Schema goes where Connections
  would. `OrderRule.cycle(from:)` is what each point's `check` refuses a list with. The protocols
  refine `SendableMetatype`, since an anchor reads its type's order from a `@Sendable` closure.
- Tabs: a kind's own tabs are `.first` (Description, Reference); Style `.last`; Issues
  `.after(StyleTab)`; Schema `.after(NeighborsTab)`; Types and Connections say nothing. A kind's own
  tabs had to say first: a feature's tab its opt-in brings from the kind's own `register` would
  otherwise come before them by first appearance, where band 50 had put it after.
- Context-menu groups: Shape `.first`; Open and Go to Original `.before(Shape)`; Mentions
  `.after(Shape)`; Transform `.after(ActionsMenuGroup)`, Frames `.after(Transform)`; Clipboard says
  nothing; Arrange `.before(State)`, State `.before(Selection)`, Publish `.after(State)`, Selection
  `.last`; a submenu's groups go in the order it lists them. `ActionsMenuGroup` is new, an empty group
  of ContextMenus' that no item is in: Mentions and Transform can't name each other, and Transform's
  Turn into item is contributed by its target (Subboards, early in the list), so by first appearance it
  came before Show What Mentions in a frame's menu, which CompositionTests caught as a crash. Having no
  turn of its own, the empty group comes after every group right after a kind's own, and Transform's
  goes after it: the shipped menu is the old numeric order exactly, whatever order items appear in.
- Adornments: type chips `.after(TitlePill)`, the lock and the public chip `.last`, the offer pill
  `.after(RelationshipPill)`. The lock stays nearest the row's end because Locking is before Publishing
  in the list; neither knows the other, and PublishingTests' fixture lock now sits before Publishing as
  the shipped list has it.
- The report says each order where a contribution names the thing: `ShapeDetails in Schema after
  Connections`, `DetailStatuses in Issues after Style`, `adornment LockChip last`, `CanvasContextMenu
  in StateMenuGroup before SelectionMenuGroup`. The guide's copy and every pinned report follow.

Not in this change: the menu bar's commands still place themselves by a number (`registrar.command(…
menu:order:)`, the hundreds its separators); that needs sections, a different shape, and comes next.

[2026-10-22 05:17] GIT:
git add -A && git commit -q -F /private/tmp/claude-501/-Users-zekenie-code-native-canvas/f9df5e12-3d5f-4a66-9375-ea5916956041/scratchpad/commit_msg.txt && git log --oneline -1 && git diff --stat HEAD~1 | tail -1

[2026-10-22 05:17] ASSISTANT:
Committed on the branch as 1dfee901. Now the code review.

[2026-10-22 05:20] GIT:
git add -A && git commit -q -m "ActionsMenuGroup holds no item: the registry refuses one

Its place rests on being empty: a group no plugin contributes comes after every group right after a
kind's own, so an item in it would sort it by first appearance and could put Turn into ahead of Show
What Mentions again. Found by the code review.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git log --oneline -2

[2026-10-22 05:20] ASSISTANT:
Waiting on the base-versus-branch timing comparison before reporting.

[2026-10-22 05:23] NOTICE:
background task completed: Background command "zsh /private/tmp/claude-501/-Users-zekenie-code-native-canvas/f9df5e12-3d5f-4a66-9375-ea5916956041/scratchpad/compare.zsh &gt; /private/tmp/claude-501/-Users-zekenie-code-native-canvas/f9df5e12-3d5f-4a66-9375-ea5916956041/scratchpad/compare.log 2&gt;&amp;1; echo "exit $?"" completed (exit code 0)

[2026-10-22 05:24] WRAP-UP:
Tabs, context-menu groups and adornments now say where they go (first, last, before, after) instead of a number, through one Order type in the core. Tests pass apart from three timing budgets that fail on the base commit too under load. It's reviewed and committed on branch relative-order, not on main; the menu bar still uses numbers.
Ask: Land it on main?

[2026-10-22 05:24] ASSISTANT:
Tabs, context-menu groups and adornments now say where they go relative to each other instead of by number. The shipped app's order is exactly what it was. It's committed on the `relative-order` branch and reviewed, not landed. The menu bar still uses numbers.

**How it works now.** The core has one way to say order. A thing says `.first`, `.last`, `.before(X)` or `.after(X)`, or nothing, in which case it goes in plugin order. A tab can only name a tab its module can see, and the same holds for menu groups and adornments. If the thing it names isn't installed, it goes where that thing would have gone. The registry refuses a circle when the app starts, and the registry report shows each rule.

What the shipped pieces say:
- **Tabs:** a kind's own tabs `.first`; Style `.last`; Issues after Style; Schema after Connections.
- **Menu groups:**
  - Open and Go to Original before the kind's own items, which are `.first`.
  - Mentions after the kind's own items; Turn into and Create Frame after that.
  - Cut, Copy and Paste say nothing, so they sit in the middle.
  - Arrange, then Lock / Is a ▸, then Make Public, then Delete `.last`.
- **Adornments:** type chips after the title pill; the lock and the public chip `.last`.

**Three things the tests turned up that you should know about:**
- **A kind's own tabs have to say `.first`.** Without it, a feature's tab brought in by the kind's own setup code would come before them. The old numbers handled that silently.
- **ContextMenus has a new empty group, `ActionsMenuGroup`.** Without it, Turn into Subboard moved above Show What Mentions in a frame's menu. That happened because Subboards, which sits early in the plugin list, contributes the Turn into item, and Mentions and Transform can't name each other. Both now place themselves against this group, which restores the old order. The registry refuses any item put in it, since its position depends on staying empty.
- **The lock sits nearest the edge only because Locking comes before Publishing in the plugin list.** Neither module can name the other, so plugin order decides, which is the rule you approved.

**Tests.** Everything passes except three timing budgets in TypesTests. Those fail and pass the same way on a clean copy of main, with overlapping numbers, at a load average of 18 to 32. They don't touch this code.

**Review.** It found six things. I fixed one: the refusal of items in `ActionsMenuGroup`. The other five are known trade-offs of the design, and the docs describe them:
- A kind's own tabs must say `.first`.
- Plugin order decides between modules that can't name each other.
- The check for circles can't see menu groups created only when a menu opens.
- The startup checks do their work twice.
- The report repeats a group's rule on every line that uses it.

**Left out.** The menu bar's commands still use numbers like `order: 100`, where the hundreds digit also decides the separators. Replacing those needs a notion of menu sections, which is a different design. It would build on this change, so it makes sense after this lands.

[2026-10-22 11:19] USER:
Land it on main.

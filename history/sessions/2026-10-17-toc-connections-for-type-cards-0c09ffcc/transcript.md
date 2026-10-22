# TOC connections for type cards

Claude Code session `0c09ffcc-9c9e-4ca5-a580-f09c5dc10796`, 2026-10-17 20:25 to 2026-10-17 21:00 UTC, on `claude/toc-connections-type-cards-4d7d1c`, `main`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-17 20:25] USER:
[image attached]

[2026-10-17 20:25] USER:
feature request: when you select in the detail panel a type card, in the toc connections it should show you instances as well as 'points to by' and 'inside'

[2026-10-17 20:26] ASSISTANT:
I'm reading how Arrows and Mentions add their lists to the Connections tab, so Types can add an "Instances" list the same way.

[2026-10-17 20:27] ASSISTANT:
I've found how to do it. Here's the plan. I'll wait for your OK before writing any code.

**How it works now.** The Connections tab builds one list per light. A light is a query that an edge's owner registers: Arrows registers Points To and Pointed To By, and Mentions registers Mentions and Mentioned By. Neighbors then adds Inside and Contains itself. Types declares the `is-a` edge, which runs from each instance to its type, but never registered a light for it. That's why a type card shows no instances.

**The change**
- **A new plugin, `TypeLightsPlugin`** (id `type-lights`), in `Sources/Types/Engines/TypeLights.swift`. It registers one light, "Instances", using the query `:edge-to(#id, is-a)`, built from `IsAEdge.id` rather than a hard-coded string. Instances on other boards are listed with their board's name. For a relationship type like "owns", the instances are its arrows.
- **Hover changes too.** A light also drives the hover outline, so hovering a type card outlines its instances on the canvas. Where the instances sit on a subboard, the subboard's card is outlined. In your Medusa board, hovering Table would outline the Commerce modules card.
- **`Package.swift`:** Types gets a dependency on Neighbors. This can't create a cycle, because Types already reaches Neighbors through Mentions. In the shipped list, the plugin goes after `MentionLightsPlugin`.
- **Tests and docs:** a test for the plugin in TypesTests, the shipped-lights and Connections-tab tests (five lights now; a type's Instances list across boards; a relationship type's arrows), the registry report line, `neighbors.md`, `types.md` and the guide.

**Decisions I've made (tell me if any are wrong)**
- **Direct instances only.** The list shows exactly what the type chips show. A subtype's note is listed, but the instances of that subtype are not. `:is-a(#id)` would follow subtypes all the way down instead.
- **No reverse "Is A" light** on instances. The chips and the Types tab already show a shape's types.
- **Instances comes after the four existing lights.** Your Table card would read Pointed To By, Instances, Inside. On shapes with no instances the list doesn't appear.
- **Color: gold**, #9A7400 on the light canvas and #E8B923 on the dark. That's 4.0:1 and 9.2:1 contrast against the canvas, and none of the four lights uses that color. Its weak spot is that the dark-mode gold sits near Validation's orange. I'll render it next to the other lights and the orange warning ring before you decide. Pink (#C2307A / #F07AB5) is the fallback.

[2026-10-17 20:27] WRAP-UP:
The plan is above: Types adds an "Instances" list to the Connections tab, using the `is-a` edge, and hovering a type card outlines its instances in gold. No code is written yet.
Ask: Build it as planned?

[2026-10-17 20:29] USER:
light instances?

[2026-10-17 20:29] ASSISTANT:
A "light" is Neighbors' name for one way two shapes can be connected. It has a title, a color and a query, and each light shows up in two places:

- **In the Connections tab**, as one list (Pointed To By is a light's list).
- **On the canvas when you hover a shape**, as outlines in that light's color around whatever its query matches. Hover a note, and the notes it points to get a green outline.

So the plan adds one light, "Instances". Select a type card and its Connections tab lists the instances. Hover the type card and its instances are outlined in gold. If they're on another board, the subboard card that holds them is outlined instead.

If you want only the list, without the hover outlines, I'd add a list-only option to lights, since right now every light does both. Should I build it as planned, or list-only?

[2026-10-17 20:29] USER:
ok fine go forth

[2026-10-17 20:30] ASSISTANT:
I've read the rules; now finding every place the existing light plugins are named so the new one goes in the same spots.

[2026-10-17 20:30] ASSISTANT:
Writing the plugin and wiring it into `Package.swift` now.

[2026-10-17 20:31] ASSISTANT:
Plugin is in and the audit passes. Now writing the tests: a small one in TypesTests, then the shipped-list ones.

[2026-10-17 20:32] ASSISTANT:
Now the shipped-light tests in NeighborsShippedTests.

[2026-10-17 20:33] ASSISTANT:
Updating the Connections-tab tests: the list order now includes Instances, plus a new test for a type's and a relationship type's Instances.

[2026-10-17 20:34] ASSISTANT:
Tests are written. Starting the full test run in the background while I update the docs.

[2026-10-17 20:34] ASSISTANT:
Updating the guide's Neighbors section to describe the new light.

[2026-10-17 20:35] ASSISTANT:
Now the topic files: `neighbors.md`, `types.md` and the build rules.

[2026-10-17 20:35] ASSISTANT:
The build failed: both new files need `import Topology` for the edge id. Fixing that and one doc sentence, then rerunning.

[2026-10-17 20:36] ASSISTANT:
While the tests run, I'll set up the render of the panel and the gold outlines.

[2026-10-17 20:36] ASSISTANT:
Drafting the gallery state for a type's Connections tab while the suite builds; I'll apply it once the run finishes so it doesn't race the compile.

[2026-10-17 20:41] ASSISTANT:
The full suite passes (every executable, 0 failures). Confirming the new tests were actually in it, then rendering.

[2026-10-17 20:41] ASSISTANT:
All the new tests run and pass. Now the gallery state and the render.

[2026-10-17 20:45] ASSISTANT:
Pink reads clearly in both appearances; gold blends into the yellow notes in dark mode. Cleaning up the throwaway render code and finishing the review before asking you to pick.

[2026-10-17 20:46] WRAP-UP:
A type's Connections tab now lists its instances under Instances, and hovering a type outlines them. The full test suite passes. In dark mode the gold outline blends into yellow notes, while pink reads clearly in both. Nothing is committed yet.
Ask: Gold or pink for Instances?

[2026-10-17 20:46] USER:
not sure i care

[2026-10-17 20:47] ASSISTANT:
You don't mind, so I'm going with pink: it reads clearly in both appearances, while gold blends into yellow notes in dark mode. Swapping it in now, then commit and review.

[2026-10-17 20:52] ASSISTANT:
All tests pass with pink. Committing on the branch.

[2026-10-17 20:52] GIT:
git add -A && git status --short && git commit -q -F - <<'EOF'
A type's Connections tab lists its instances: Types gives Neighbors an Instances light, so selecting a type card shows what is of it beside Pointed To By and Inside, and hovering it outlines them

The owner selected the Table type card on a board of Medusa's types and found the Connections tab showing only Pointed To By and Inside: "when you select in the detail panel a type card, in the toc connections it should show you instances as well". The tab lists one group per light, a query each edge's owner gives Neighbors; Arrows and Mentions gave theirs, and Types, which declares the `is-a` edge from an instance to each type its `is` list names, never had.

`TypeLightsPlugin` (Types' Engines part, id `type-lights`) gives one light, Instances, `:edge-to(#id, is-a)`, written from `IsAEdge.id`. Types now imports Neighbors (it already reached it through Mentions, so no cycle). It ships after Mentions' lights, so a type reads Pointed To By, Instances, Inside, and a shape's arrows and mentions keep their rings; a shape with no instances shows no list.

A light both lists and outlines on hover, so hovering a type also outlines its instances (the subboard whose board holds one). Asked "light instances?", the owner heard that and went ahead; a list-only light, which would need a new option on lights, was offered and not wanted.

Calls of mine the owner accepted with the plan: direct instances, as the chips are (a type built on it is listed, what is of that one isn't; `:is-a` would follow them), and no reverse "Is A" light, since a shape's chips and Types tab already say what it is. A relationship type's instances are its arrows.

The color is pink, #C2307A light and #F07AB5 dark (4.9:1 and 6.6:1 on the canvases), held to the design audit's rules for the four lights. Gold, the other hue they leave, was built first; renders of the hover beside the four and an orange warning ring showed it reading as a yellow note's own edge on the dark canvas and close to Validation's orange. The owner didn't mind which ("not sure i care"), so pink was my pick.

The gallery has the tab's look for a type (`connections-type`).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -1

===== [2026-10-17 20:52] commit written: A type's Connections tab lists its instances: Types gives Neighbors an Instances light, so selecting a type card shows what is of it beside Pointed To By and Inside, and hovering it outlines them =====

[2026-10-17 20:53] ASSISTANT:
Review found three things. Fixing the real one: Instances should only list for a shape that is currently a type. I'll also fix the gallery ids; the benchmark one I'll skip.

[2026-10-17 20:58] ASSISTANT:
Everything passes after the fixes. Committing them and updating the review.

[2026-10-17 20:58] GIT:
git add -A && git commit -q -m "Instances lists only while the shape is a type: a note whose schema was taken away, though shapes still name it (their chips dashed), lists none and lights none; the gallery's type ids are fixed, as every state's are

Found reviewing the light: it followed the raw is-a edge, which outlives Remove Type, so the panel listed instances of a shape the chips already called gone. The query now asks the anchor to hold \`schema\` (\`:edge-to(#id[schema], is-a)\`).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git log --oneline -2

[2026-10-17 20:58] WRAP-UP:
A type's Connections tab now lists Instances, and hovering a type outlines its instances in pink. Two commits on the branch, reviewed and with the one real finding fixed; the full suite passes. Benchmarks weren't run, and it isn't on main.
Ask: Land it on main?

[2026-10-17 20:59] USER:
Land it on main.

[2026-10-17 20:59] GIT:
git log --oneline -1 main && git merge-base HEAD main && git status --porcelain && git -C /Users/zekenie/code/native-canvas status --porcelain && git -C /Users/zekenie/code/native-canvas branch --show-current && ls build/InfiniteCanvas.app 2>/dev/null | head -1

[2026-10-17 20:59] ASSISTANT:
Main has moved since the branch was cut, so I'll squash and rebase. The main checkout has an untracked `dogfood/model/` folder that isn't mine; my change doesn't touch it, so it won't get in the way.

[2026-10-17 21:00] COMMIT MESSAGE FILE commit-msg.txt:
A type's Connections tab lists its instances: Types gives Neighbors an Instances light, so selecting a type card shows what is of it beside Pointed To By and Inside, and hovering it outlines them

The owner selected the Table type card on a board of Medusa's types and found the Connections tab showing only Pointed To By and Inside: "when you select in the detail panel a type card, in the toc connections it should show you instances as well". The tab lists one group per light, a query each edge's owner gives Neighbors; Arrows and Mentions gave theirs, and Types, which declares the `is-a` edge from an instance to each type its `is` list names, never had.

`TypeLightsPlugin` (Types' Engines part, id `type-lights`) gives one light, Instances, `:edge-to(#id[schema], is-a)`, written from `IsAEdge.id` and `TypeSchemaProperty.key`. Types now imports Neighbors (it already reached it through Mentions, so no cycle). It ships after Mentions' lights, so a type reads Pointed To By, Instances, Inside, and a shape's arrows and mentions keep their rings; a shape with no instances shows no list. The anchor must hold `schema`: the `is-a` edge outlives Remove Type, and a shape the chips already call gone (dashed) lists nothing and lights nothing.

A light both lists and outlines on hover, so hovering a type also outlines its instances (the subboard whose board holds one). Asked "light instances?", the owner heard that and went ahead; a list-only light, which would need a new option on lights, was offered and not wanted.

Calls of mine the owner accepted with the plan: direct instances, as the chips are (a type built on it is listed, what is of that one isn't; `:is-a` would follow them), and no reverse "Is A" light, since a shape's chips and Types tab already say what it is. A relationship type's instances are its arrows.

The color is pink, #C2307A light and #F07AB5 dark (4.9:1 and 6.6:1 on the canvases), held to the design audit's rules for the four lights. Gold, the other hue they leave, was built first; renders of the hover beside the four and an orange warning ring showed it reading as a yellow note's own edge on the dark canvas and close to Validation's orange. The owner didn't mind which ("not sure i care"), so pink was my pick.

The gallery has the tab's look for a type (`connections-type`), its type ids fixed as every state's are.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>

[2026-10-17 21:00] GIT:
git reset -q --soft c3a18c89e07b48f9e27710170ffe11498f08521b && git commit -q -F /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-toc-connections-type-cards-4d7d1c/0c09ffcc-9c9e-4ca5-a580-f09c5dc10796/scratchpad/commit-msg.txt && git rebase main 2>&1 | tail -3; git status --short | head; git log --oneline -3

[2026-10-17 21:00] ASSISTANT:
Rebased cleanly. Fast-forwarding main.

[2026-10-17 21:00] WRAP-UP:
It's on main as d951005d, and the worktree and branch are removed.
Ask:

[2026-10-17 21:00] ASSISTANT:
It's on main as d951005d. Selecting a type card now shows an Instances list in its Connections tab, between Pointed To By and Inside. Hovering a type outlines its instances in pink. The worktree and its branch are removed.

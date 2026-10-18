# PR #6: Lexicons: gather the draw and query bridges into DrawLexicon and QueryLexicon
Branch claude/admiring-dijkstra-48bhl0-lexicons, opened 2026-10-04T01:27:50Z, merged 2026-10-04T02:02:49Z.
Made by a Claude Code session in the cloud; its transcript isn't on this machine, so this PR is the record of it.

## Description

Third of four. Tiers follows, stacked on this one.

## Why
The eight remaining bridges were two concepts, not eight:
- **TitleNames, PortEdges and ValidationChecks** fill Automation's three draw points. Together they are `canvas draw`'s words for this app's concerns.
- **TitleQueries, BoardQueries, MentionQueries, ValidationQueries and SelectionQueries** fill Queries' points. Together they are `canvas query`'s words.

Each was a one-file module. None of them is a dependency waiting for a direction, because the direction is settled:
- A language must know no concern, so AutomationTests and QueriesTests can fill its points with fixtures.
- No concern should know a language.

So each language gets one module that imports it and the concerns. I've called that module a lexicon.

## What changes
- **Two modules replace eight.**
  - `Sources/DrawLexicon` depends on Automation, Canvas, Connections, Titles and Validation.
  - `Sources/QueryLexicon` depends on Boards, Canvas, Mentions, Queries, Selection, Titles, Topology and Validation.
  - Both are in the horizontal layer.
- **Plugin values and ids are unchanged.** Each concern is still a plugin value of its own (`TitleNamesPlugin`, …, `SelectionQueriesPlugin`), so a list can leave out a concern's words. The shipped list and the registry report are unchanged.
- **The channel rule moves to Connections.** PortEdges used to pick an unwritten edge's channel from the port table itself. It now asks `registry.connectionChannel(from:fromSide:to:toSide:)`, which sits in PortTable.swift beside the other port lookups. The rule that a script's edge picks a channel as a drag does now lives in one module.
- **The points stay points.** Each takes at most one contribution, and DrawLexicon or QueryLexicon is always the shipped one. AutomationTests and QueriesTests fill them with fixtures, which keeps both languages testable without the app's concerns.
- **`QueryPrompt` stays in Composition.** Its examples name the shipped kinds (`sticky-note` appears 33 times). The id audit lets only a module that depends on StickyNotes write that id, and a horizontal can't depend on it.
- **The audit holds the plugins' test targets again.**
  - **The gap.** A target named `<M>Tests` may use only M's closure, but only while module M exists. ArrowsTests, PortsTests and ArrowPortsTests have escaped that check since #4, and these eight test targets would have too.
  - **The fix.** A test line can now name the module it tests: `// layer: test of QueryLexicon`. It is then held as `<M>Tests` is. I tagged all eleven targets.
  - **What the audit refuses.** A test that leans on a vertical, a subject that isn't a module, test support as a subject, a target that doesn't depend on its subject, and a tag on a target that is already named after a module or isn't a test. I tried each case.
- **Tests stay separate targets.** The eight test targets keep running side by side, one per plugin. Their helpers' `bridge: Bool` is now `withPlugin: Bool`, and the test names name the plugin.
- **Docs.** CLAUDE.md, the guide and the README describe lexicons. The bridge layer is now empty, and Tiers removes it.

## How it was checked
There's no Swift toolchain here, so nothing was compiled. What I checked instead:
- **Audit.** build.sh's audit, ported to Linux and regenerated from this branch's build.sh, passes: 83 modules, layers, cycles, imports equal to dependencies, and id ownership.
- **Syntax.** All 31 changed Swift files parse, with no new errors.
- **Name collisions.** Each new module has no clashes among its files: none at top level, in private names or in extension members.
- **Report and links.** The guide's copy of the registry report still equals ShippedTests' pin, which this PR doesn't touch. The docs' links and anchors resolve.

## Test commands
```sh
./build.sh audit        # the graph: 83 modules, and the test targets held to the module they test
./test.sh               # everything

# The executables this PR touches most, run again by hand after ./test.sh:
for t in TitleNames PortEdges ValidationChecks TitleQueries BoardQueries MentionQueries ValidationQueries SelectionQueries \
         Arrows Ports ArrowPorts Automation Queries Composition; do
  build/debug/${t}Tests/${t}Tests > /dev/null 2>&1 && echo "ok   ${t}Tests" || echo "FAIL ${t}Tests"
done

./build.sh && open build/InfiniteCanvas.app
```

With the app open on a scratch board:
```sh
build/canvas draw - <<'EOF'
sticky-note "Web" text: "Browser app"
sticky-note "API" right of "Web" text: "Public HTTP API"
subboard "Payments" below "API"
edge "Web" -> "API"
EOF
build/canvas query ':edge-from("Web", only note-link)'     # API: the edge picked note-link by itself (connectionChannel)
build/canvas draw --dry-run 'edge "API" -> "Payments"'     # refused, no_channel: a sticky-note connects on note-link, a subboard has no ports
build/canvas draw 'sticky-note "A title long enough to run past the eighty characters a title is meant to keep to" below "Payments"'
                                                           # drawn, with a warning that the title is 81 characters long (ValidationChecksPlugin)
build/canvas query ':warned'                               # that note (ValidationQueriesPlugin)
build/canvas query '"Payments"'                            # by title (TitleQueriesPlugin)
build/canvas query-vocabulary | grep -o '"word" *: *"[^"]*"'   # :mentions, :mentioned-by, :invalid, :warned, :selected
```
Then, in the app:
- Type `@Web` in a note. `build/canvas query ':mentions("Web")'` should list that note.
- Select a shape. `build/canvas query ':selected'` should list it.
- Put a note inside an untitled subboard. `build/canvas query 'sticky-note' --fields title` should show "Untitled Subboard" in that note's `inside` (BoardQueriesPlugin).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01HLLB87kyQRDJkMRjRJPozZ

---
_Generated by [Claude Code](https://claude.ai/code/session_01HLLB87kyQRDJkMRjRJPozZ)_

## Commits
- ae63e4c1 Gather the query bridges into QueryLexicon
- c74b98d6 Gather the draw bridges into DrawLexicon
- 01fb46ac Give the channel rule a home in Connections, and say what fills the p…
- 490ffdd5 Docs: say what a lexicon is, and what fills draw's and queries' points
- 585e81b8 Hold the plugins' test targets to the module they test
- 6fed5fd1 Layers: replace horizontal and bridge with surface, concern, language…

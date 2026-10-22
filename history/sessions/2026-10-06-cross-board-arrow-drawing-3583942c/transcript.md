# Cross-board arrow drawing

Claude Code session `3583942c-e469-4d71-9e9e-cbf2d64b13a2`, 2026-10-06 12:37 to 2026-10-06 15:04 UTC, on `claude/cross-board-arrows-d9f75e`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-06 12:37] USER:
you should be able to draw arrows between sub-boards. also i don't think at this point there's any particular channel restriction. that could change or be configurable later, but at this moment i don't see why you couldn't draw an arrow from a sticky to a board or vice versa

[2026-10-06 12:38] GIT:
git merge --ff-only main && git log -1 --oneline

[2026-10-06 12:38] ASSISTANT:
I'm mapping how ports and channels work today, so I can propose how subboards get ports and how the channel restriction goes away.

[2026-10-06 12:41] ASSISTANT:
Still reading: I've got the port/channel design and `canvas draw`'s channel rules mapped; now checking which tests, docs and the `--ask` prompt depend on the two shipped channels.

[2026-10-06 12:43] ASSISTANT:
I've found the two workable shapes for lifting the restriction; checking a few details (draw's tests, the skill tests, references' ports) before I write up the plan.

[2026-10-06 12:46] ASK:
Q: Which way should I lift the channel restriction? (Your pick starts the build.)
   options: Accept every channel (Recommended): Notes, schema cards and subboards each keep their own channel (note-link, schema-link, new subboard-link) and accept all channels. Dot colours, queries and evals stay as they are.; One shared channel: note-link and schema-link are replaced by one channel used by every kind with ports. All dots are one colour; the query vocabulary, the skill and the --ask eval cases get rewritten.
Q: Frames have no ports today. Should they get them too?
   options: Leave frames out (Recommended): Frames stay without ports: a drag still can't end on a frame, and draw still needs `channel: none` for note → frame.; Frames too: Frames get dots on their sides and connect like the other kinds.

[2026-10-06 12:56] ANSWER:
Denied by user

[2026-10-06 12:56] USER:
[Request interrupted by user]

[2026-10-06 12:58] USER:
Hang on there sailor. I said that subboards don’t need any particular restrictions as of now. I still want schemas and stickies to behave the same way… 

My mental model is

* -> sub board
Schema -> schema
Sticky -> sticky

[2026-10-06 12:58] USER (sent mid-turn):
That was supposed to be a star pointing to suv board. Got turned into list item

[2026-10-06 13:00] ASSISTANT:
Got it: anything → subboard (and subboard → anything), schema → schema, sticky → sticky. One more check: whether every test plugin list that installs Subboards would now also need Ports.

[2026-10-06 13:00] ASSISTANT:
Your model is what I'll build. The change is to subboards alone; notes and schema cards keep today's ports exactly.

**What you'll see**
- Hovering a subboard shows a dot on each of its four sides, in its indigo. The top dot sits in the title pill's row, like a schema card's.

| From → to | Today | After |
|---|---|---|
| note → note | note link | same |
| schema → schema | schema link | same |
| note ↔ schema | refused | still refused |
| note / schema → subboard | refused | connects, as a note link / schema link |
| subboard → note / schema | refused | connects, as a note link / schema link |
| subboard → subboard | no dots to drag from | connects, as a new subboard link |

**How**
- Subboards declare a `subboard-link` channel. They get ports on it, and on every other channel too (`portsOnEveryChannel()`). Nothing in StickyNotes or Schemas changes.
- A re-aimed arrow keeps its channel, as now. So a note link between a note and a subboard can move to any note or subboard, but not to a schema card. A subboard link stays between subboards.
- A reference pill for a subboard will behave like the subboard: indigo dots, and subboard links to subboards. That needs one small fix in Connections (`KindPorts.standing(for:)`): it should order a pill's channels by what the pill stands for, not by plugin order. Without the fix, the pill's dots would come out amber note-link ones.
- Subboards will depend on Connections. A vertical may depend on a concern, so the audit allows it. SubboardsTests' plugin list will gain `PortsPlugin`.

**`canvas draw`**
- note or schema ↔ subboard connects without `channel:`.
- subboard ↔ subboard becomes a subboard link instead of a plain arrow.
- One tightening: subboard ↔ frame will need `channel: none`, as note ↔ frame does today. That's because subboards will have ports and frames won't, which also matches the app, where a drag can't end on a frame. If you'd rather draw keep connecting subboards to frames without asking, I can loosen its rule instead.

**Also updated**
- Tests: subboard dots, drags each way and re-aims, plus the pill ordering, the plugin reports, and draw's diagram test.
- Skill: the kinds tables, the channels section, and the `no_channel` example. That example is a note → subboard edge, which will now connect, so it switches to note → schema card.
- The query docs get the new edge type. `docs/plugin-system.md` and the connections, subboards and references topic files get updated.
- I won't run the live `--ask` evals: the prompt text stays the same, and its vocabulary only gains `subboard-link`.

After that I'll run the tests, do a code review and send renders, then wait for your go-ahead to land.

Shall I go ahead?

[2026-10-06 13:02] USER:
very interested in the channel semantics, can you explain it to me from the pov of a plugin author trying to build on top

[2026-10-06 13:03] ASSISTANT:
A channel is a contract between the two ends of an arrow: each end accepts that channel. The contract isn't kept per pair of kinds. It's stamped on the arrow when it's drawn, and every later change to the arrow has to keep it.

**1. Declare it, in the plugin that owns what the connection means**

```swift
public enum DependsOn {}
extension DependsOn: Channel {
    public static let id: ChannelID = "depends-on"      // stored on arrows: never change it
    public static var color: NSColor { .systemTeal }     // its dots
    public static let summary: String? = "one service needs the other to run"
}
// in register(into:)
registrar.channel(DependsOn.self)
```

- That call declares the channel and also a Topology edge type of the same name, under `arrow`.
- The summary is where the meaning goes. Agents read it in the query vocabulary.
- The id audit holds the `"depends-on"` literal to your module: another module can write it only if it depends on yours.

**2. Kinds opt in with ports**
- On your own kind: `x.ports(DependsOn.self, sides:role:)`.
- On another plugin's kind: `registrar.ports(SchemaCard.self, on: DependsOn.self, …)`, importing that kind's module.
- The role sets direction:
  - `.both` (the default);
  - `.source`: the kind has dots, but nothing ends on it;
  - `.target`: things end on it, but it has no dots.
- `x.portsOnEveryChannel()` gives a kind every channel any installed plugin declares, including channels added later. It was built for reference pills.

**3. The channel is picked when the arrow is drawn; the person never chooses it**
- A dot carries every channel its kind has on that side, in plugin order. A kind's first contribution on a channel wins. It's one dot, in the first channel's colour.
- The drag can only end on a shape that accepts one of those channels as a target.
- The arrow goes on the first of them that the target accepts.
- `canvas draw` uses the same rule (`connectionChannel`), unless the script says `channel: x` or `channel: none`.

**4. After that, the channel belongs to the arrow for good**
- It's stored as the arrow's `ChannelProperty`.
- When an end is re-aimed or the arrow is moved, each end can only bind to a shape that accepts the channel in that end's role: the start as a source, the end as a target.
- To change an arrow's channel, you delete it and draw it again.
- Exceptions:
  - An arrow on no channel (`channel: none`) binds anywhere.
  - So does one on a channel no installed plugin declares, such as a file from an app with another plugin.
  - Re-pointing a reference pill can break the contract under an arrow that's already attached. References shows a warning; nothing lets go.

**5. Who reads it**
- Topology: the arrow is an edge of the channel's type. `:edge-to("Auth", depends-on)` finds those, and `:edge-to("Auth", arrow)` takes in every channel.
- Queries: `arrow[channel=depends-on]`.
- For your own rules, the registry has lookups: `takes`, `accepts`, `declares`, `dotChannels`, `connectionChannel`.
- For restrictions channels can't express, add a binding rule: `registrar.arrowBindingRule { … }`. It's asked wherever an end binds.

**Sharp edges for a plugin author**
- The relation is per channel, not per pair of kinds. To allow "X → subboard but not subboard → X", you use roles: the subboard accepts X's channel as `.target` only.
- A dot with several channels can't offer the person a choice; the target and the plugin order decide. If a person must choose, put the channels on different sides.
- Plugin order is part of the semantics. Moving a plugin in the shipped list can change which channel a drag draws.
- Nothing is configurable at runtime: ports are registered in code, and the registry is frozen at launch. "Configurable later" would need a new piece, such as ports read from settings at launch, or a binding rule that reads settings.

**What this means for the subboard plan**
- Subboards get their own channel first, then every channel. That first channel gives them indigo dots, and makes subboard → subboard a `subboard-link` rather than a `note-link`.
- A subboard → note arrow is a `note-link`, because that's the first of the subboard's channels a note accepts. So after the change, `note-link` means "both ends accept note links", which covers notes and subboards. It no longer means "note to note". A query that wants note-to-note arrows should ask by the ends' kinds, not by the channel.
- Because the channel is fixed for good, a note link between a note and a subboard can be re-aimed onto notes and subboards, but not onto schema cards. A subboard link can only be re-aimed onto subboards, even though your model allows subboard → note. Drawing a new arrow gets you that pair.

Say go and I'll build the plan as written, or tell me if any of this changes it.

[2026-10-06 13:26] USER:
too long

[2026-10-06 13:27] ASSISTANT:
Shorter version:

- **A plugin declares a channel**: an id, a dot colour and a one-line meaning. It's also an edge type under `arrow`, so queries can ask for it.
- **Kinds opt in with ports on it**, each with a role: both, source only (dots, nothing ends there) or target only (accepts arrows, no dots).
- **When an arrow is drawn**, the dot offers its kind's channels in plugin order, and the arrow goes on the first one the target accepts. The person never picks.
- **After that the arrow keeps its channel for good.** Re-aiming or moving it only binds to shapes that accept that channel. `channel: none` arrows bind anywhere.

For subboards, that means subboard → note is a note link. "Note link" then means "both ends accept note links", not "note to note".

Shall I go ahead with the plan?

[2026-10-06 13:27] WRITE /Users/zekenie/.claude/projects/-Users-zekenie-code-native-canvas/memory/short-explanations.md:
---
name: short-explanations
description: "Explain in a few lines: the gist and the consequence that matters, no sections, no code; offer more on request"
metadata:
  type: feedback
---

On 2026-10-06 the user asked me to explain channel semantics "from the pov of a plugin author". I answered in about 700 words, with numbered sections, a code block and a list of sharp edges. They replied "too long". The short version that followed was five bullets and one line on what it meant for the change under discussion.

**Why:** they read on the go and pay for every token. A long explanation buries the one thing they need.

**How to apply:** answer an explanation request in about 5–10 lines: what the thing is, how it behaves, and the one consequence for the work at hand. Leave out code, headers and edge-case lists unless asked. Offer detail in one line if it seems useful. Related: [[answer-questions-dont-act]], [[quiet-ui-copy]].

[2026-10-06 13:27] ASSISTANT:
Noted for next time: I've saved a memory to keep explanations to a few lines.

[2026-10-06 13:27] USER:
yes proceed

[2026-10-06 13:27] ASSISTANT:
Starting the build. First, a couple of quick checks so the brief for the build agent is exact.

[2026-10-06 13:29] ASSISTANT:
Jev routed the build to Sonnet. Writing the agent's brief now.

[2026-10-06 13:30] AGENT Build subboard ports:
You're implementing an approved change in a native macOS Swift app: an infinite canvas built from compiled-in plugins. Work only in this git worktree: /Users/zekenie/code/native-canvas/.claude/worktrees/cross-board-arrows-d9f75e (branch claude/cross-board-arrows-d9f75e). Never touch other worktrees or the main checkout (~/code/native-canvas), never merge, push or rebase, never use `git stash`, never run the app or capture the screen. Commit on this branch when done.

## Read first
- CLAUDE.md (rules for every change, how to build and test).
- .claude/rules/connections.md, subboards.md, references.md (its ports paragraph), command-line.md (canvas draw, the canvas skill), testing.md, build.md (the audit).
- docs/plugin-system.md, section "Ports" (about lines 4441–4815) and the "Subboards" section.
- Sources/Connections/Ports.swift, PortTable.swift, PortState.swift, ArrowPorts.swift; Sources/StickyNotes/NoteLinks.swift and Sources/Schemas/SchemaLinks.swift (the pattern to copy); Sources/Subboards/Subboards.swift.

## The behavior (approved by the owner)
Subboards get ports. Notes and schema cards do not change at all.

| from → to | result |
|---|---|
| note → note | note-link (as today) |
| schema card → schema card | schema-link (as today) |
| note ↔ schema card | refused (as today) |
| note → subboard | note-link |
| schema card → subboard | schema-link |
| subboard → note | note-link |
| subboard → schema card | schema-link |
| subboard → subboard | subboard-link (a new chan […8550 more chars]

[2026-10-06 13:30] ASSISTANT:
The build agent is running in this worktree. While it works, I'll get the before/after renders ready in a separate scratch clone, so the builds don't collide.

[2026-10-06 13:32] ASSISTANT:
Writing the "before" renders from main in the scratch clone (a throwaway test, never committed).

[2026-10-06 13:32] ASSISTANT:
Not a new issue: an arrow is listed under the shape it starts from, so one leaving a subboard goes under the subboard's row. Arrows drawn by `canvas draw` already do that. I'll wait for the build agent and the renders to finish.

[2026-10-06 13:33] NOTICE:
background task completed: Background command "Build the clone and render the before images" completed (exit code 0)

[2026-10-06 13:34] ASSISTANT:
That's expected: an arrow paints just above the highest shape it's bound to, as in tldraw. One bound only to the note is painted under the subboard card. In the "after" renders it binds to the subboard, so it will paint above it. Now waiting for the build agent to finish.

[2026-10-06 13:58] ASSISTANT:
The build agent is done: committed, full test suite green, benchmarks within budget. I'll check its diff, then run the "after" renders and the code review.

[2026-10-06 13:58] ASSISTANT:
Starting the "after" renders in the clone first, since they take a few minutes. I'll read the diff while they run.

[2026-10-06 13:58] ASSISTANT:
The source changes match the plan. Now the tests.

[2026-10-06 13:59] ASSISTANT:
The tests cover what I asked for. Now the skill and docs changes.

[2026-10-06 13:59] ASSISTANT:
The docs and skill changes read well and match `canvas kinds`. Running the code review on the branch now. The "after" renders are still building in the clone.

[2026-10-06 14:00] ASSISTANT:
Quick Look installs the full shipped list, so it gets Ports too. Next, I'm checking that the agent's change to the SkillTests helper didn't loosen what the test checks.

[2026-10-06 14:02] ASSISTANT:
- [plugin-system.md:11359](docs/plugin-system.md:11359): the guide's "Not built yet" still lists wildcard channels (a port on every channel), which are built and which subboards now use.

Fixing it:

[2026-10-06 14:02] EDIT .claude/worktrees/cross-board-arrows-d9f75e/docs/plugin-system.md:
connection at an end, and a dot that stops taking more); directional reversal

[2026-10-06 14:02] GIT:
grep -rn 'wildcard channels\|directional reversal' Tests/ .claude/ 2>/dev/null | head -3; git add docs/plugin-system.md && git commit -q -m "Drop wildcard channels from the guide's Not built yet: portsOnEveryChannel is built, and subboards use it

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git log --oneline -3

[2026-10-06 14:02] ASSISTANT:
Now the renders.

[2026-10-06 14:02] ASSISTANT:
Subboards now have ports, on the branch and ready to land. Notes still link only to notes and schema cards only to schema cards; subboards link to and from anything with ports.

- **What you'll see:** hovering a subboard shows four indigo dots. Note → subboard draws a note link and schema card → subboard a schema link. A subboard draws whichever of those its target accepts, and a `subboard-link` to another subboard.
- **Reference pills:** a pill for a subboard now gets the same indigo dots and links as the subboard. That took the one-function change in Connections.
- **Checks:** all 64 test executables pass, the benchmarks are within budget (hovering and dragging from a dot didn't measurably slow down) and the build audit passes. The code review found one stale line in the plugin guide, now fixed.
- **Two consequences:**
  - An arrow keeps its channel when you re-aim it. So a subboard-to-subboard arrow can't be moved onto a note; you draw a new one.
  - In `canvas draw`, a subboard ↔ frame edge now needs `channel: none`, as note ↔ frame already does.

The renders above compare before and after: hovering a subboard, dragging from a note, and the finished links.

Should I land it on main?

[2026-10-06 15:02] USER:
land it

[2026-10-06 15:03] ASSISTANT:
Main has moved (table-of-contents drag and drop landed), so I'll squash the branch into one commit and rebase it onto main.

[2026-10-06 15:03] GIT:
git merge-base HEAD main && git reset -q --soft $(git merge-base HEAD main) && git status --short | head -40

[2026-10-06 15:03] GIT:
git commit -q -F - <<'EOF'
Subboards get ports: anything with ports links to a subboard, and a subboard to anything

The owner wanted to draw arrows between subboards, and from a sticky to a
subboard and back. A subboard had no ports, so a person couldn't connect one at
all, and `canvas draw` joined one only plainly, on no channel. I first read "i
don't think at this point there's any particular channel restriction" as
lifting channels for every kind, and proposed either every kind taking every
channel or one channel shared by all; the owner corrected it: the restriction
lifts for subboards alone, and notes and schema cards behave as they did. Their
model: anything to a subboard (and a subboard to anything), schema to schema,
sticky to sticky.

So a subboard has ports on a channel of its own, `subboard-link`
(`SubboardLink`, the card's indigo), first, and then on every channel there is
(`portsOnEveryChannel()`), on all four sides. Its own first, because a dot is
its first channel's color and a drag is drawn on the first of the dot's
channels the shape it ends on takes: its dots are indigo, and two subboards
link on `subboard-link`, not on the first channel declared (`note-link`). Every
channel after, so a note or a schema card links to it on its own channel, and
it to either on theirs. Nothing in StickyNotes or Schemas changed: a note and a
schema card still share no channel.

An arrow keeps its channel, as before: a note link between a note and a
subboard re-aims onto notes and subboards only, a subboard link onto subboards
only, though the owner's model allows a subboard to a note (a new arrow draws
that pair). Frames keep no ports, so `canvas draw` now wants `channel: none`
between a subboard and a frame, as it does between a note and a frame.

A stand-in took its channels in its own order, which for ports on every
channel is the order they're declared in, so a reference pill for a subboard
would have drawn amber note-link dots and linked to a subboard on note-link.
`KindPorts.standing(for:)` now walks the channels of the first shape stood
for, so a pill draws what its original draws.

The canvas skill (its kinds tables, its channels section, and a `no_channel`
example that note to subboard no longer is), the guide and the topic files say
so, and SkillTests reads a kinds-table cell that names several channels. The
guide's Not built yet no longer lists wildcard channels, which References and
now Subboards use.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -2 && git rebase main 2>&1 | tail -5

===== [2026-10-06 15:03] commit written: Subboards get ports: anything with ports links to a subboard, and a subboard to anything =====

[2026-10-06 15:03] ASSISTANT:
Resolving the one rebase conflict: a single long line in `.claude/rules/build.md` that main and this branch both edited, in different places. I'll keep main's line and re-apply my edit.

[2026-10-06 15:03] GIT:
python3 - <<'EOF'
import re
path = ".claude/rules/build.md"
text = open(path).read()
m = re.search(r"<<<<<<< HEAD\n(.*?)\n=======\n(.*?)\n>>>>>>> [^\n]*\n", text, re.S)
ours, theirs = m.group(1), m.group(2)
old = "StickyNotes and Schemas import Connections, each for a channel of its own, and References"
new = "StickyNotes, Subboards and Schemas import Connections, each for a channel of its own (Subboards for ports on every channel too), and References"
assert ours.count(old) == 1 and new in theirs
merged = ours.replace(old, new)
text = text[:m.start()] + merged + "\n" + text[m.end():]
open(path, "w").write(text)
print("resolved; markers left:", text.count("<<<<<<<") + text.count(">>>>>>>"))
EOF
git add .claude/rules/build.md && GIT_EDITOR=true git rebase --continue 2>&1 | tail -2 && git log --oneline -3

[2026-10-06 15:04] ASSISTANT:
Rebased cleanly. Merging into main now.

[2026-10-06 15:04] ASSISTANT:
It's on main. Now updating the ports memory and cleaning up.

[2026-10-06 15:04] ASSISTANT:
It's on main as 6500c951. The worktree and branch are removed.

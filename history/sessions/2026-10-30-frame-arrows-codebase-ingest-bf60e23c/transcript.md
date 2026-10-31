# Frame arrows codebase ingest

Claude Code session `bf60e23c-54ec-415f-8f44-a3aa903c3dd5`, 2026-10-30 12:54 to 2026-10-31 02:10 UTC, on `claude/frame-arrows-ingest-a1781c`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-30 12:54] USER:
we recently added the ability for frames to be connected by arrows. but the codebase ingest still rejects this, please fix

[2026-10-30 12:54] ASSISTANT:
Looking for where the ingest refuses an edge at a frame — the digest's model drops them, and I'm checking whether lenskit refuses them too.

[2026-10-30 12:57] ASSISTANT:
Main finding so far: the layout's cost model looks up an arrow's ends among note boxes only, so an edge at a frame would crash it, not just be dropped. Checking the measure script and verify next.

[2026-10-30 12:58] ASSISTANT:
I've found what refuses it, and the fix needs a plan before code (your standing rule), so here it is.

[2026-10-30 12:58] WRAP-UP:
The ingest refuses edges at frames because the digest's model drops every one. Its layout would also crash on one, because it only looks up arrow ends among notes and cards. Nothing is changed yet; the plan is ready.
Ask: Go ahead with this plan?

[2026-10-30 12:58] ASSISTANT:
The ingest refuses frame arrows because canvas-digest's model drops every edge that names a frame (`.claude/skills/canvas-digest/tool/lib/model.mjs:202`). The ingest draws through the digest, so the lens's edges never get there. lenskit itself doesn't refuse them; only its docs say "never frames". Removing that line isn't enough, though: the layout's cost model only looks up an arrow's ends among notes and cards, so an edge at a frame would crash the plan.

**The plan** (all in canvas-digest's tool; the ingest only needs its docs updated):

1. **What gets drawn.** An edge between two frames, or between a frame and a subboard, on the same board. `canvas draw` puts both on `frame-link` without being told. These are always plain arrows: never turned into pills, never part of a spine, never measured as a pill.
2. **What's still dropped**, each with a warning that gives its own reason:
   - **A note and a frame.** The app gives them no shared channel, and you can't connect a note to a frame by hand. *My call:* the digest follows the app instead of drawing `channel: none` arrows. The second button is there if you'd rather have them drawn.
   - **A frame and anything it holds, at any depth.** The app refuses these too.
   - **An edge at a frame that crosses boards or says `via: reference`.** A frame can never be public, so no pill can stand for it.
3. **Layout.** An arrow can end on a frame's box, and crossing the border of the frame it ends on doesn't count against it. Frames that point at each other are then laid out by their arrows, the same way notes are.
4. **Tests.**
   - In the tool's own tests: each kept and dropped case, with its warning text; two frames planned with an arrow between them; and the existing fixtures' plans still identical byte for byte.
   - In DigestTests: a small new fixture drawn with `digest all` against the real app, with `verify ok` and the frame arrows found by `canvas query`.
5. **Docs.**
   - The digest rules' "Hubs and frames" and "Not built" (a frame as a hub stays not built).
   - canvas-digest's SKILL.md limits and `reference/graph.md`.
   - The ingest's `lens.md` entry for `d.edge`.

[2026-10-30 20:31] USER:
Yes, build it

[2026-10-30 21:52] ASSISTANT:
API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)

[2026-10-31 00:56] USER:
Try again

[2026-10-31 00:56] ASSISTANT:
Now editing the model: keep the edges the app can draw, drop the rest with their own reasons.

[2026-10-31 00:57] ASSISTANT:
Now the cost model: an arrow's end may be a frame's box, and its own frame's border is no crossing.

[2026-10-31 00:57] ASSISTANT:
Model and cost model done. Now looking at the tool tests' helpers to write the new cases.

[2026-10-31 00:59] ASSISTANT:
Tool tests nearly pass; one assertion of mine was wrong (the note-to-note edge rightly measures a pill). Fixing it.

[2026-10-31 01:02] ASSISTANT:
Tool tests pass (108, fixtures' plans unchanged). Now a DigestTests case that draws frame arrows into the real app.

[2026-10-31 01:03] ASSISTANT:
While that builds, the docs. Reading the lines that say frames can't be an edge's end.

[2026-10-31 01:04] ASSISTANT:
Waiting on the test build. Meanwhile I checked the shipped lenses: none of them draws an edge at a frame today, so existing ingests come out the same.

[2026-10-31 01:04] ASSISTANT:
The test build is still running in the background; I'll pick up when it finishes.

[2026-10-31 01:05] NOTICE:
background task completed: Background command "Build and run the new DigestTests case" completed (exit code 0)

[2026-10-31 01:05] ASSISTANT:
The new draw test passes against the real app. Now fixing the stale Swift comment, then running the whole digest and ingest suites.

[2026-10-31 01:05] ASSISTANT:
Digest and ingest suites are running in the background (`canvas-digest`, then `canvas-ingest`); I'll pick up when they finish.

[2026-10-31 01:09] NOTICE:
background task completed: Background command "Run all digest and ingest tests" completed (exit code 0)

[2026-10-31 01:10] ASSISTANT:
Every digest test (22) and ingest test (37) passes. Committing on the branch, then the code review.

[2026-10-31 01:10] GIT:
git add -A && git status --short && git commit -q -F - <<'EOF'
Ingest draws the arrows between frames: the digest keeps an edge at a frame the app can join

Frames got ports on their own channel (a5b69796), so two frames, or a frame and a subboard, can be joined by an
arrow, but a lens that drew one still lost it: canvas-digest's model dropped every edge that named a frame, and its
layout couldn't have taken one anyway (its cost model looked an arrow's ends up among the notes and cards alone).

The digest now draws what the app joins and says why it drops the rest:

- Two frames, or a frame and a subboard, on one board: an arrow, which draw puts on frame-link. It is always an
  arrow (marked `direct`, as a relationship type's end is), so no move turns it into a pill, a frame is never a hub,
  and no pill is measured for it. The layout lifts it to the container both ends share as any arrow, so frames that
  point at each other are laid out by their arrows; the cost model ends it on the frame's box, its own border no
  crossing.
- Dropped, each with its reason: a frame and what it holds at any depth (the app's cannot_connect); a note and a
  frame (they share no channel, and a person can't join them in the app either, so the digest doesn't draw
  `channel: none` arrows the app wouldn't make: the owner's call to keep, when asked); two boards, or
  `via: reference` (no pill stands for a frame, which is never public, nor sits beside one).

Tests: the tool's own (each case and its sentence, the plan's arrows and script, nothing public, no pill measured,
the board laid out by them, seven frames at one subboard leaving it unpromoted; every fixture's plan byte for byte
as before), and DigestTests drawing a new `frames` fixture into the real app (verify ok, the dropped edge said,
`:edge-from(…, frame-link)` answering the arrows). The digest's and lens docs say what is drawn now; two stale
"a frame has no ports" (the subboards rule, a PortEdges comment) go.
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -1

[2026-10-31 01:10] GIT:
git log -1 --format=%B > /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-frame-arrows-ingest-a1781c/bf60e23c-54ec-415f-8f44-a3aa903c3dd5/scratchpad/msg.txt && python3 - <<'EOF'
p='/private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-frame-arrows-ingest-a1781c/bf60e23c-54ec-415f-8f44-a3aa903c3dd5/scratchpad/msg.txt'
s=open(p).read()
a="""  `channel: none` arrows the app wouldn't make: the owner's call to keep, when asked); two boards, or"""
b="""  `channel: none` arrows the app wouldn't make: the owner approved this over drawing them); two boards, or"""
assert s.count(a)==1; s=s.replace(a,b)
s=s.replace('"a frame has no ports" (the subboards rule, a PortEdges comment) go.\nCo-Authored-By','"a frame has no ports" (the subboards rule, a PortEdges comment) go.\n\nCo-Authored-By')
open(p,'w').write(s)
EOF
git commit -q --amend -F /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-frame-arrows-ingest-a1781c/bf60e23c-54ec-415f-8f44-a3aa903c3dd5/scratchpad/msg.txt && git log -1 --format=%B | tail -8

[2026-10-31 01:10] ASSISTANT:
Now the code review your workflow requires before reporting.

[2026-10-31 01:10] ASSISTANT:
The review found two worth fixing: a typed edge at a frame slips through, and a case the tests miss. Fixing both.

[2026-10-31 01:12] GIT:
cd /Users/zekenie/code/native-canvas/.claude/worktrees/frame-arrows-ingest-a1781c && /System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc .claude/skills/canvas-digest/tool/test/run.js 2>&1 | grep -E "^(FAIL|ERROR)|passed" ; python3 - <<'EOF'
p='.claude/skills/canvas-digest/reference/graph.md'
s=open(p).read()
a="(a pill can't stand for a frame). |"
b="(a pill can't stand for a frame). An arrow at a frame takes no `is`: a relationship joins two notes. |"
assert s.count(a)==1; s=s.replace(a,b); open(p,'w').write(s)
p='.claude/rules/digest.md'
s=open(p).read()
a="`direct`), so nothing moves it into a pill"
b="`direct`; `check` refuses `is` on one, since a relationship joins two notes), so nothing moves it into a pill"
assert s.count(a)==1; s=s.replace(a,b); open(p,'w').write(s)
EOF
git add -A && git commit -q -m "Refuse is on an arrow at a frame, and test a frame's edges across boards and into what it holds

Found reviewing the change before: a typed edge at a frame passed check and drew a relationship between frames,
which the app reads as a misfit.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git log --oneline -2

[2026-10-31 01:12] WRAP-UP:
The ingest now draws arrows between two frames, and between a frame and a subboard, on frame-link. Any other edge at a frame is dropped with its reason. It's reviewed, the review's fix is in, and the digest and ingest suites pass. It's on branch claude/frame-arrows-ingest-a1781c and not on main yet.
Ask: Land it on main?

[2026-10-31 01:12] ASSISTANT:
The ingest now draws arrows at frames. Two frames, or a frame and a subboard on the same board, get an arrow on `frame-link`. Those arrows are never turned into pills.

- **What was refusing them:** canvas-digest's model dropped every edge that named a frame. Its layout also couldn't handle one, because it only looked up an arrow's ends among notes and cards. Both are fixed, in `model.mjs` and `cost.mjs`.
- **What's still dropped, each with a warning that says why:**
  - A frame and anything it holds.
  - A note and a frame. The app gives them no shared channel, so you can't connect them by hand either.
  - An edge that crosses boards or asks for a pill, since a frame is never public.
- **Typed edges at frames:** the review turned up that an edge at a frame with an `is:` type was drawn as a relationship the app then flags as invalid. `check` now refuses it, in its own commit.
- **Tests:**
  - The tool's own tests pass, 109 of them, under both node and jsc. Every existing fixture's plan is still identical byte for byte.
  - A new DigestTests case draws a folders-as-frames fixture into the real app: everything lands where planned, and `canvas query` finds the arrows on `frame-link`.
  - The digest suite (22) and the ingest suite (37) pass. I didn't run the full `./test.sh`.
- **Not fixed:** two smaller review notes. One is a spine card's arrow to a frame being laid across the spine's pills. The other is a tidy-up of two parallel "never a pill" checks.
- **Also touched:** two stale "a frame has no ports" lines from the last change, one in the subboards rule and one in a `PortEdges.swift` comment.
- **Not changed:** none of the shipped lenses draws an edge at a frame today, so existing ingests come out the same until a lens adds them.

[2026-10-31 02:10] USER:
Land it

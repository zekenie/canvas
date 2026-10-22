# Self-mention in sticky/shape

Claude Code session `72a922bd-2ca7-4c94-9078-1e5a8cd49206`, 2026-10-01 12:30 to 2026-10-01 12:36 UTC, on `claude/self-mention-sticky-shape-1df570`, `main`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-01 12:30] USER:
it is not possible to mention yourself. it should be. i should be able to mention the sticky/shape i'm in from within that shape

[2026-10-01 12:30] ASSISTANT:
Making the edit now: removing the picker's self-exclusion in `MentionState.candidates` (a note's name already ignores its own mentions, and a self-mention is already handled elsewhere).

[2026-10-01 12:32] ASSISTANT:
Updating this test to the new contract: a self-named-by-text shape is listed when the typed query isn't in its own name.

[2026-10-01 12:34] ASSISTANT:
All green. Now the docs and CLAUDE.md wording.

[2026-10-01 12:34] ASSISTANT:
A shape can now mention itself: type `@` in a note or a schema card's description and the shape itself is in the list. The full `./test.sh` run passes, but I haven't opened the app to try it by hand.

- **The change:** `MentionState.candidates` in `Sources/Mentions/MentionState.swift` used to drop the shape the text is on from the picker. Nothing else blocked a self-mention. Mentions, validation, the mention edge and the Mentioned In tab already handle one. A note's own name still can't grow from it, since a mention in a note's first line reads as "@…".
- **Two cases still leave the shape out:**
  - **Empty `@`'s Nearby section:** you are always the nearest shape there, so listing yourself would only be noise. A recent pick of yourself still shows under Recent.
  - **A note named by its own first line:** while you type `@gro` on that first line, the note's name contains `@gro` and would match itself, so it is hidden until the name says more. Typing `@` on a later line, or in a titled shape, finds the shape normally.
- **Schema cards:** the card itself is now offered too, so a card can mention itself, which writes a recursive `$ref`. That is valid JSON Schema, but I haven't exercised the schema sync on it. The panel's JSON `$ref` completion (⌃Space) still leaves the card out, so the two lists disagree. Say if you want them to match or want cards excluded again.
- **Tests and docs:** the picker and matching tests that pinned the old exclusion now cover the new behavior, and `CLAUDE.md` and `docs/plugin-system.md` are updated to match. I haven't committed anything yet.

[2026-10-01 12:35] USER:
let's get this on main

[2026-10-01 12:35] ASSISTANT:
No review has run on this yet, so I'm running one first, as you asked for on earlier landings.

[2026-10-01 12:36] ASSISTANT:
Review found nothing. Committing and landing.

[2026-10-01 12:36] GIT:
git add -A && git commit -q -F - <<'EOF'
Let a shape mention itself from its own text

Typing @ in a note, or a schema card's description, never offered the shape the text is on, so you couldn't mention the sticky you were typing in. Nothing else forbade it: Topology, validation, backlinks and the Mentioned In tab already treat a self-mention as an edge that doesn't count as "mentioned", and a note's name reads each mention as "@…", so it can't grow from its own.

The picker now lists the owner. Two cases still leave it out: an empty @'s Nearby section, where it would always be first, and a typed query while the owner's name already holds the "@query" being typed, which is what happens to a note named by its first line when the @ is on that line (it would otherwise match its own half-typed mention). Schema cards get it too, so a card can mention itself (a recursive $ref); the panel's JSON $ref completion still leaves the card out.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
git rebase main 2>&1 | tail -2; git -C ~/code/native-canvas status --short | head -3; git -C ~/code/native-canvas log --oneline -1

===== [2026-10-01 12:36] commit written: Let a shape mention itself from its own text =====

[2026-10-01 12:36] ASSISTANT:
Main hasn't moved and the branch is a single commit. The tests already passed on this exact tree apart from a doc-comment rewrap, so I'm merging.

[2026-10-01 12:36] GIT:
cd ~/code/native-canvas && git merge --ff-only claude/self-mention-sticky-shape-1df570 2>&1 | tail -1 && git worktree remove --force .claude/worktrees/frosty-hugle-4740f7 && git branch -d claude/self-mention-sticky-shape-1df570 && git log --oneline -1

[2026-10-01 12:36] ASSISTANT:
It's on main as 55b53cf. The worktree and branch are removed.

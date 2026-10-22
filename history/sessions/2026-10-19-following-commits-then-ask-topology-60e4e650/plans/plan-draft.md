**Step 3 of 3: the rest of "following commits".** Steps 1 and 2 are on main (bee13c55, 7426adfc), so 2 of 3 are done. The scope change this step waited for is on main too (5b3fcd01).

Two words used below. A **service** is the part of a plugin that keeps state for a window: Topology's index, Types' index, Validation, the selection. **Taking in a commit** is what a service does when the app hands it a change to the board. Since step 1, a service that's asked for while others take in a commit takes it in first.

What a trial copy showed (whole suite, nothing changed in the worktree): services still ask each other things while they're halfway through taking in a commit, about 60,000 times. Almost all go through three paths:
- the select tool looking for a button under a still pointer, as it takes in the commit, which drags other services in early;
- services telling each other "these chips, rows or shapes changed" from the middle of their own update;
- questions like "which rows did this commit affect?", asked before the services they're about have finished.

What I'd build, as one landing:

1. **A second round after every commit or board shown: settling.** Once every service has taken the change in, each is told it has settled. What moves there: the button look; the "chips, rows, buttons changed" messages and redraws, when they're sent mid-commit; and the "what did this commit affect" questions (Validation's rules, the table of contents' rows and marks, Find). A service others follow (Topology, Types' index, the relationship index, the colors) tells its followers once it has taken the commit in, not halfway.
2. **Then a service can't be asked anything while it's still taking in a commit.** That was your call in step 1. *Decision below.*
3. **The old guards go.** About a dozen services still guard against hearing a commit out of turn, or hand another service the change early. Step 1 and item 1 make both pointless. First, the dozen references services keep to each other from start-up become lookups, so those get the commit first too. Topology's `catchUp` goes with them.
4. **Validation asks its rules once everyone has heard**, so Types' and Colors' rules can answer it instead of pushing "check these again" at it. Four of the ten pushes go: a type's edit, a renamed note, the file's colors. Six stay, because no commit carries what they report: the caret entering or leaving a field, an arrow's drag let go.
5. **One walk over the boards the app can show**, in the core, replacing five copies (Topology, Mentions, Titles, Find, Jump To; Jump To's can pause between slices). The seven services that read every board get a named "every board" instead, and each keeps reading what it reads today, so no answer changes.
6. **A commit says what each shape was before it.** Locking, Publishing and Grouping each keep their own copy of which shapes are locked, public or grouped, just to see what changed. With "before" they drop those copies, the per-board stashes and the board scans. Locking also stops re-reading every dragged shape. The brief also asked for per-board change lists. Nothing I found would use them, so I'd leave them out.
7. **Small kits, only where they delete code**: one capped memo for the 17 that empty themselves when full, one helper for the 9 hand-written per-shape observations, and one two-way index for the hand-kept ones (Validation's lookups, Types' references, the rows' holders).

Then the topic files and the guide, `./build.sh`, `./test.sh`, the benchmarks against main, and a code review. It lands only when you say so.

**The decision: what the app does if some untested spot still asks a service mid-commit.** The app is built for release, where a check can either stop the app or be skipped.
- **Recommended**: tests and debug builds stop with an error naming both services. The app carries on as today, with the service as it is, so a spot the tests miss can't crash it.
- **Or**: the app stops there too, as it already does if something changes the board while services take a change in.

For you: no board looks or behaves differently. The cost is one large landing that touches most services. The risk is a spot the tests don't reach. With my recommendation, it only shows up in tests and debug builds.

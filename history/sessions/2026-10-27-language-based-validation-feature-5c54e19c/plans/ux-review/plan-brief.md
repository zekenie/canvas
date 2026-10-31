# Walking issues: the brief every planner reads first

You are planning the build of an approved design for Infinite Canvas, a native macOS canvas app built from compiled-in plugins. **This round plans; it writes no app code.** Nothing in the repository changes.

- Repo (read only): `/Users/zekenie/code/native-canvas/.claude/worktrees/language-validation-feature-9707df` (REPO). Read `REPO/CLAUDE.md` first (the rules for every change), then the topic files in `REPO/.claude/rules/` for each subsystem you plan in, before its sources.
- Round folder: `/private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-language-validation-feature-9707df/5c54e19c-eecf-40b5-a6f7-141090714e71/scratchpad/ux-review` (ROUND). Write only `ROUND/plan-<your-name>.md`.
- The design round that led here: `ROUND/issues/design.md` (the base: Validation's walk), `ROUND/list/design.md` (the screen: list and evidence together), `ROUND/step/design.md` (Ignore in place, the light). Their frames are `f1.png`… in each folder. Where they differ from the approved design below, **the approved design wins**.
- Ground rules: don't run `./build.sh`, `./test.sh`, the app or `build/canvas`; don't read or list anything under `.claude/worktrees/` except REPO itself. Cite code as `path:line` with real symbols; say "not found" rather than guess.

## The approved design (the owner said "I'll go with your rec"; don't relitigate it)

**What it is.** A walk goes through a file's issues one at a time, across every board, and holds your place. Validation owns it: the same walk covers any error or warning, and a rule's count opens it narrowed to that rule. Each stop is one issue on one shape, the shape selected on its own board. An ignored stop stays in its place, dimmed; the count drops, your place doesn't move. What a rule is unsure of is no issue, so it is never walked. Incomplete issues (amber, shown nowhere on the board) are not walked either.

**Starting a walk.**
- A rule's count (`FlagCount`, "63") starts that rule's walk at its first stop: a click, or Return with it focused. The count no longer selects; Select Flagged ▸ still does.
- A flagged shape's warning line gains a third action after Ignore and Show Rule: "9 of 63", its place in that rule's walk, which starts the walk at this shape.
- Go › Next Issue ⌘' with no walk running starts a walk of every issue, from the first stop after the selection; during a walk it goes to the walk's next stop, wherever you are.
- Go › Issue List ⌃⌘' opens or closes the list of the walk running, else of every issue.

**The screen.** While a walk runs, the band, the list and the current stop's evidence share the panel:
- The band, at the top of the panel: the walk's scope (the rule's type chip and "Rule 1", else "All Issues"), ‹ 12 of 63 ›, Done.
- The list: the stops grouped by board, each head the board's name and count ("Texas 9"), all folded but the current board's. A row is the shape's name, an arrow by its ends ("Jerry Carl → Ukraine Security Supplemental"), and at its end its first value ("Nay"). An ignored row stays, dimmed, reading "ignored".
- Under the list: the current stop's warning line (Ignore, Show Rule), its Rules section and Shown, drawn as its Issues tab draws them (Validation's warning line; LanguageRules' sections, which Validation must show without importing LanguageRules).
- The list closed (Return, or a click on the band's count) leaves the band over the shape's own panel and tabs, to fix its data; ⌘' steps on from there.

**A step.** Find's order, file-wide: the root's shapes, then each board under it depth first, each in file order; the walk wraps. Another board is shown, the stop's shape selected; the camera moves only if the shape isn't in view, to a readable zoom. The whole walk is one step back: ⌘[ returns to where it started, ⌘] to the last stop. While the band or the list has the keyboard, the walk's other stops on the board shown light cyan. Stops that arrive while answers come in join in file order; the current stop stays current.

**Acting on a stop.** Ignore (⌥⌘' or the warning line's button) is one undo step, and you stay where you are: the row stays in place, dimmed, reading "ignored"; the count drops (63 to 62); ‹ › go on from it. A fix that makes the stop hold reads "holds" the same way. ⌘Z brings a stop back. Show Rule goes to the rule's Rules tab with the band kept; ⌘' comes back to the walk.

**Keys.** ⌘' / ⇧⌘' next and previous stop from anywhere (repeat; each undoes the other); ⌥⌘' Ignore Issue; ⌃⌘' Issue List; in the list ↑ ↓ the stop before and after, Page Up / Page Down the board before and after, ← → fold and unfold a board, Return closes the list on the current stop (the band stays); Escape one level out (list, band, canvas; the walk goes on); Done and ⌘. end the walk; ⌘[ back to where it started. Every click has a key and a menu item (Go › Next Issue, Previous Issue, Issue List; Shape › Ignore Issue). The four apostrophe chords are free in the app today (checked: nothing binds `'`).

**VoiceOver.** Each step: "Issue 12 of 63, Texas, Roger Williams → Laken Riley Act, In line with the member's record." (the board only when it changes). Band: "Rule 1 of Vote", "12 of 63", "Previous Issue", "Next Issue", "Done". A row: its name, its board, "12 of 63". A head: "Texas, 9, collapsed". Ignore: "Ignored, 62".

**Every word.** Menus: Next Issue, Previous Issue, Issue List, Ignore Issue. The band: Rule 1 (beside the type's chip), All Issues, 12 of 63, Done. The list: Texas 9, ignored, holds. A warning line: 9 of 63.

**The pieces the design round proposed (to check, refine or replace with better ones):**
- Selection: `ShapeWalk`, Find's stepping lifted out of `FindState` (current, step, move, wrap, the start for Back, finish, n of N), Find its first client, so the app has one walker.
- DetailPanel: a band point (a strip over the panel while a walk runs, one holder at a time), the list window Find's panel draws (its row window, keys and board heads, Find's `FindHeadings` moved down as `BoardHeadings`).
- Validation (the owner): `IssueWalk` (a service over the walker: the scope, the stops, the place, ignore keeping a row in place), `ValidationIssue.source` (an opaque key for where an issue comes from, so a rule's issues are found by key, never by matching the sentence), an `IssueScopes` extension point for a plugin's scopes, the band and the list views, the commands and their menu items, the light.
- LanguageRules: a scope per rule that flags (its RuleKey as the source), `FlagCount`'s click starting the walk, the "n of N" action on its warning lines.

## What you hand in

`ROUND/plan-<your-name>.md`, at most 1,500 words: for your part, the landings in order (each one finished, tested and committed before the next: what it does, the files it touches with `path:line`, the new types and their APIs in a few lines of Swift signatures, the extension points and where they're declared, the tests by suite and what each holds, the key walks, the census and key-meaning entries, the topic files and the guide sections it updates), what the audit will say (the layers and imports each module gains: read `REPO/.claude/rules/build.md` and `Package.swift`), the risks, and the questions only the owner can answer (at most three; decide everything else and say what you decided).

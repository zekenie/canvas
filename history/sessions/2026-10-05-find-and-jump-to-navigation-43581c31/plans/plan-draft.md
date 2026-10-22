# Find (⌘F) and Jump To (⌘K): draft plan

Survey reports: scratchpad/understand-*.md (host-and-panel, keys-and-menus, text-render-and-highlight, titles-tree-matcher, offmain-search-and-bench, external-ux-research).

## Modules (Package.swift)

1. **FuzzyMatching** — new, layer foundation, no deps. Move `CaretListMatcher` / `CaretListMatch` / `CaretListRanking` out of TextEditing, renamed `FuzzyMatcher` / `FuzzyMatch` / `FuzzyRanking` (no compatibility hooks; importers Mentions, SlashCommands, DetailPanel switch their import; matcher tests move to a new FuzzyMatchingTests). Add:
   - `TextSearch`: typo-tolerant search over long text. Fold per scalar (case, diacritics, width) into `[UInt16]` with a map back to UTF-16 offsets of the original. Exact folded substring hits (every occurrence) first; then approximate hits with Myers' bit-parallel matcher (patterns ≤ 64 folded units), k by folded query length (0 for ≤3, 1 for 4–7, 2 for ≥8), start at a word start, first character exact, edits < half the match, adjacent transposition counted as one edit, a fuzzy hit overlapping an exact one dropped. Returns hits (UTF-16 range, distance) in text order. Multi-word query = one phrase, whitespace runs equal any whitespace run.
   - `PathMatcher`: a query split on whitespace into pieces; a DP assigns contiguous groups of pieces to path segments root→leaf in order, skipping allowed, the last group in the leaf (the shape's own title); each group scored with `FuzzyMatcher.match(Query(group joined), Label(segment))`; ancestor groups limited to exact/prefix/word-prefix/substring/typo tiers (no bare subsequence); score = leaf × weight + Σ ancestors − depth/skip penalty; returns per-segment matched ranges for bolding.

2. **Find** — new, layer **surface** (Canvas, Geometry, Keyboard, Selection, DetailPanel, Topology, FuzzyMatching). Knows no concern and no kind.
   - Point `FindableTexts` (keyed per kind or every shape `where:`), contributed as `registrar.findableTexts(...)`: for a record → `[FindableText(field:, text: String, rects: ([Range<Int>]) -> [[CGRect]] world units, zoomedOut: CGRect?)]`, with `affected: { changes, context in Set<ShapeID> }` like the TOC rows' (for a note whose text shows another shape's live name).
   - Contributors (each a plugin value in its owner's module, so a list without Find leaves them out):
     - Mentions' `MentionFindPlugin`: every kind's `MentionTexts` placements (notes' text, schema cards' prompt): plain text with live names, a pill's name mapping to its one U+FFFC; rects from the render's layout (`MentionTextLayout`); affected = `rowsAffected(by:)`.
     - Titles' `TitleFindPlugin`: every titled shape's title (named or derived); rect = the pill's frame (`adornmentFrames`), zoomed out the cover's.
     - Connections' `ArrowFindPlugin`: an arrow's label; rects by the label's layout.
     - The string-drawing range→rects helper (today private `MentionTextLayout.layOut`/`lineRects`) hoisted to the core's Rendering so Mentions and Connections share it.
   - `FindState` service (`editor.find`): isActive, query, results, current, a request counter. `FindIndex` per shape's texts (folded), built on first ⌘F (walk every showable board), kept current per commit at O(changed) (removed, added, changed minus moved, elsewhere, `affected`), rebuilt on replaced file. Search off the main actor over a Sendable snapshot (cancel-and-restart per keystroke, generation-tagged, checks cancellation every 256 shapes). Re-run after a commit while open.
   - Scope: the board shown and every board under it (Topology snapshot's descendants in file order). Order: the board shown's shapes in file order, then each board under it depth-first.
   - Overlay (world space): for shapes in view with hits (`paintOrder(in:)`), the contribution's rects (cached per shape and query generation), filled with a highlighter look (multiply; a yellow for every match, an orange plus thin outline for the current one; hues picked from renders, since yellow on a yellow note vanishes); title pills ringed rather than multiplied. Zoomed out: a batched tint of each matched shape's bounds (a title hit, its cover's rect), current stronger. No text laid out per frame beyond cached rects; nothing drawn when inactive.
   - Panel: `FindPanel` view (field with the query selected on reopen, "3 of 12", previous/next, Done; rows one per shape: kind symbol, a one-line snippet around its first hit with hits bold, a count when more; grouped under board headers named through a closure Composition passes, as the TOC's heading). Return/⇧Return step; Escape closes.
   - Commands (names in the core's `Identity.swift`, as `.enclosingBoard`): `.find` ⌘F (open/focus, shows the inspector), `.findNext` ⌘G, `.findPrevious` ⇧⌘G (enabled while there are hits). Stepping reveals the hit (showing its board when it's elsewhere); typing makes the first hit on the board shown current and reveals it only when it's out of view (no board switch while typing). Closing (Escape in the panel, Done) selects the current hit's shape (one Back step) and drops highlights. Escape on the canvas leaves Find open.

3. **JumpTo** — new, layer **concern** (Canvas, Keyboard, Selection, Topology, Titles, Boards, TextEditing, FuzzyMatching).
   - Titles' `TitleIndex` promoted from TitleValidationPlugin to a public service of `TitlesPlugin` (`editor.titles`: title(of:), shapes(titled:)), which TitleValidationPlugin and JumpTo read.
   - `JumpToState` (`editor.jumpTo`): isOpen, query, rows; candidates = titled shapes (named or derived) on every board the editor can show, none kept aside; a folded-key buffer of leaf titles (Mentions' catalog's shape: entries, swap-remove, stale set refreshed lazily); built on first ⌘K, kept current per commit.
   - Path per candidate at rank time: `topology.ancestors(of:)` reversed (root left out, it's never an ancestor); an untitled ancestor shown by its placeholder and not matched. Rank: prefilter by the last piece over leaf labels (`FuzzyMatcher.rank`), then `PathMatcher` over those; ancestors' labels folded once per keystroke per container. Ties: fewer levels skipped, shallower, recent picks, file order. On main; 2 ms at 10,000 shapes (the @ picker's budget).
   - Empty query: recent picks (this window), then the board shown's titled shapes in file order.
   - Palette: a field over the top middle of the canvas, below the path's pill, an `EditingTextView` in a capsule; its rows in the app's one caret list (`CaretList` + `CaretListWindow` under the field, wider metrics, 10 rows), with `CaretListItem` gaining matched ranges in its detail so the path's matched letters are semibold too: kind symbol in its row's tint, title (matched semibold), path "Alpha › Beta" dimmed. ↑ ↓ ⌃P ⌃N, Return picks, Escape / ⌘. / a click away closes and gives the canvas the keyboard.
   - Pick: into a shape whose kind opens its board (`goInto`), else to it (`goTo`), one Back step — the crumb menu's rule.
   - Command `.jumpTo` ⌘K (name in the core).

## Host and composition
- Lift the board window's content (canvas, path, palette, inspector, toolbar) into one Composition function, `ShippedPlugins.boardContent(canvas:editor:showsDetails:rootName:onExit:)`, taking the canvas view and bindings so Composition never names CanvasUI types; the app's `ContentView` and CompositionTests' `InspectorHost` both call it (today they're two copies, and the app's is untested). It places the palette overlay, and shows the inspector on Find's request counter (`.onChange`).
- `DetailPanelView(editor:onExit:overview:takeover:)`: a slot (isActive + view) Composition fills with Find's panel, outranking the selection, as `overview` does for the table of contents; DetailPanel never learns Find.
- Menus (`BoardMenus`, `BoardWindowController`): Edit › Find › Find… ⌘F, Find Next ⌘G, Find Previous ⇧⌘G; Go › Jump To… ⌘K; custom selectors (never AppKit's find actions, which a note's text view would take), in the commands table, not in `textKeys`, so they work from the canvas, a note being edited, the panel and the list. Keys registered with Keyboard by Find and JumpTo.
- Cut from v1: ⌘E Use Selection for Find (needs the system find pasteboard), Find and Replace, highlights inside a note's editing view beyond the canvas overlay under it, dimming non-matching shapes.

## Tests, benchmarks, docs
- FuzzyMatchingTests: tiers (moved), TextSearch (folding with offsets: ß, é, İ, emoji, CJK; k by length; word starts; transpositions; overlap; seeded fuzz against a naive DP), PathMatcher (skips, several pieces in one segment, last piece in the leaf, ranking, ranges).
- FindTests on fixtures (a findable fixture kind, pockets): index build and upkeep (a move reads nothing), scope, order, stepping across boards, the current hit kept across edits, overlay pixels in and zoomed out, the panel headless and in a window (focus, Return/⇧Return, Escape gives the canvas the keyboard). MentionsTests/TitlesTests/ArrowsTests hold their contributions' rects to their renders' ink.
- JumpToTests on fixtures: index upkeep, a ranking story ("alpha gamma checkout"), untitled ancestors, picks and Back, palette keys in a window.
- CompositionTests: the menus' items and keys from canvas, text and panel; ⌘F showing a hidden inspector; a note's text, a card's prompt, an arrow's label and a title found and highlighted; a subboard's contents found from the root; Jump To into subboards and frames.
- BenchmarkTests: Find keystroke at 10,000 (main ≤0.5 ms, off main ≤10 ms), index build ≤50 ms, upkeep (a drag ≈0), a frame with highlights ≤16 ms; Jump To keystroke ≤2 ms.
- Docs: topic files find.md, jump-to.md, fuzzy-matching.md (with `paths:`), CLAUDE.md map lines, updates to text-editing, mentions, titles, connections, detail-panel, keyboard, build, benchmarks; docs/plugin-system.md sections.
- Gallery renders (scratch clone, never committed): the Find panel, the palette, highlights on a note, a card, an arrow and a pill, zoomed out, light and dark.

## Execution (routed with Jev)
1. Bring the branch up to main (d7f0291).
2. In parallel, scratch clones: (A1) FuzzyMatching + moves + tests; (A2) host prep: commands, menus, the takeover slot, the content lift, the palette overlay slot.
3. In parallel: (B1) Find with its contributions; (B2) JumpTo with TitleIndex's promotion.
4. Merge, full test run, benchmarks, code review (the skill), fixes, renders; report; land only on the user's word.

## Questions for the user
- Find, a multi-word query: one phrase (as browsers) or every word anywhere in the shape?
- Find, titles: matched too (the pill highlighted), or only what's inside shapes?

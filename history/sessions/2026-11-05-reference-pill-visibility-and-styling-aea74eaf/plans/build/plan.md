# Reference pills: where they come from — the approved plan (the owner said "Build it", 2026-11-04)

This is the owner's plan doc as approved, word for word but for the note at the end. Build exactly this.

## The design

Every reference pill says where its original lives, in a small line over its name, and wears its original's color.

**Where it lives**

- Two lines: the place, small, over the name. No line means the original is right here (its frame, or its board in no frame); the name then sits centered.
- The place is said from where the pill sits: the frames and boards the original is in that the pill isn't, outermost first (`Core layer`, `Horizontals: in the window`).
- The top board goes by the file's name, never "Board". When the original is on another board and the line names no board, that board leads (`Shop › Identity`).
- Every pill shows its place, however it was made: the Reference tool, `canvas draw`, the digest, a relation row.

**Long places**

- The line keeps the sidebar's fold: first › … › nearest.
- When there's room, the middle comes back: the original's own board first, then the names nearest the shape.
- The nearest is always whole; the first name shrinks before it does.
- Boards are semibold, frames plain.
- The whole place: resting the pointer on a folded line, the inspector's Reference tab, and VoiceOver.
- One fold for every place an address shows: the pill, the sidebar row, the `@` and Reference lists, Connections, Jump To, the inspector's header.

**Color**

- The fill is a faint wash of the original's color; the edge and the symbol are the color; the name stays the label color.
- An original with no color (a plain frame) gives a gray pill.
- Not public: dashed in the color, italic, the eye. Deleted or not available: gray dashes, and that word in the place line.
- A query pill for its first match: that match's color and place. One for every match: the color they share (else gray), the count, no place line.

**Zoom**

- 60% and up: both lines.
- 60% down to 35%: the name alone, centered.
- Below 35%: a block in the original's color.

## Decided

**The pill**

- 40 tall, radius 20. Place: SF 11 regular at the label color's 60%, boards semibold, `›` and `…` at 30%. Name: SF 14 medium.
- Untitled containers read `Untitled Frame` / `Untitled Subboard`, at 30%.
- Width: 46 + the wider of (the name + 17) and the folded line, clamped 64–280; the line folds at 234. Never padded to the whole address.
- When the original moves, the new place folds into the stored width. Drawing the pill again refits it.
- Stored pills: a migration `reference` v0 → v1 sets the height to 40, centered; a new fixture `reference.v1.json`; the v0 fixture stays.

**The fold**, the first step that fits:

1. The whole place.
2. First › … › nearest, putting back the middle that fits: the original's own board first, then from the near end outward. At most two `…`.
3. `first › … › m › nearest`, the first name cut to make room (never below 34 pt), `m` the first segment step 2 would put back.
4. First › … › nearest with the first name cut at its end.
5. `… › nearest`; the nearest cut only if it doesn't fit alone. A path-like name keeps its leaf.
6. Nothing under 24 pt of room.

- Cuts fall at a name's end, at a word when one is within 30% of the cut. `…` carries no count.
- The board lead: the original's board (the file's name for the root, else its card's title) leads when the line names no board.

**On approach**

- Hover: only on a folded or cut line, the whole place then the name, boards semibold, through the canvas's existing text popover. No clickable crumbs.
- The "Deleted" and "Not available" popovers go (the word is on the pill); "Not public" stays.
- Inspector: the header stays one line, folded at its width with the whole as its help; the Reference tab shows the whole place, wrapped, under Go to Original.
- VoiceOver: "FieldValues.swift, reference, in" the whole place, never folded.

**Color**

- Fill the color's `wash`; edge its `solid`, 1 pt; symbol its `ink`; name the label color.
- In dark, indigo and purple edges lift to `#605EE8` and `#A841C8`, so they read on a raised frame.
- A neutral edge and a deleted pill's dashes: the label color at 45%. Count badge: `solid` at 30%. The warning in light: `#B96B00`.
- Zoomed out: `solid` at 50% over the canvas. Selection ring 4 pt off the pill.
- A type's own note: its pill in the type's color; its paper stays white.
- Query pills: finding keeps its last answer's color, dimmed (gray before any answer); every match goes gray past 2,000 matches or with mixed colors.

**Draw and the digest**

- Every pill is seated with its place; the shared-name guard goes. `canvas measure` seats every end.
- A column of pills beside a shape steps by the pill's height and the gap (today the first sits half under the second).
- The digest's default pill height becomes 40.

**Unchanged**

- Mention pills inside text; the sidebar row's symbols; the go button, Go to Original and Back.
- Names show as written. Folder cards repeating their parent's name is the digest's to fix, in a task of its own.

**Not built**

- Tabs, hover cards, a clickable place line, a "Go to <place>" item.
- Two hand-made places that differ only in a middle frame are told apart on hover, in the inspector and the row's help, not at rest.

## The build plan

| # | Slice | What you'll see | Where | Size | After |
| --- | --- | --- | --- | --- | --- |
| 1 | The fold | nothing yet: one function every surface calls | a pure fold over segments (name, board or frame, untitled) and a width function, in Chrome, which every list already imports; tests over the real cases (Medusa's two `Workflows (cus…`, the 1–7 ladder, Temporal's long names) | S | — |
| 2 | Places as segments | the top board by the file's name; the board lead | Boards' `ContainerName` says whether it opens a board (`Boards.swift:203`); `placeOfTarget` and `ReferencePath.place` return segments (`ReferenceState.swift:165`, `ReferencePath.swift:46`); `rootBoardName` goes; the kept condition keeps the folded line | M | 1 |
| 3 | The two-line pill | place over name, 40 tall, fitted width, the zoom rule, Deleted and Not available | `ReferenceStyle`; `ReferenceLook` layout and draw (`ReferenceDrawing.swift:180,391`); `ReferenceEdits` width and fit (`ReferenceEdits.swift:47,60`); the editor held to the render; the migration and fixture | M | 2 |
| 4 | The pill in color | wash, colored edge and symbol, every state, colored blocks zoomed out | References imports Colors; colors kept beside the condition; the skeleton; query pills' colors with their answer; a type answers its own color (`TypeIndex.swift:190`) | M | 3 |
| 5 | Every pill shows its place | draw, measure, the digest and relation rows size every pill for its place; columns of pills stop overlapping | Draw's shared-name guard (`DrawStandIns.swift:594,617`), `StandInRoute.seat`, measure (`Measure.swift:150`); the digest's pill height (`sizes.mjs:11`); the canvas skill and SkillTests | S–M | 3 |
| 6 | One fold everywhere | the sidebar row, the `@` and Reference lists, Connections, Jump To and the inspector's header fold alike | TableOfContents (`TableOfContents.swift:523,632,661`), the lists (`MentionPicker.swift:204`, `CaretListWindow.swift:478`), Neighbors (`NeighborList.swift:281,295`), JumpTo (`JumpToRows.swift:81`), the Reference tab (`ReferencePanel.swift:41`) | M | 2 |
| 7 | Hover and VoiceOver | the whole place on a folded line's hover; VoiceOver hears the place | the pill's popover (`ReferenceState.swift:450`); a `ShapeAccessibility` contribution (`CorePoints.swift:162`) | S | 2 |
| 8 | Docs, bench and renders | today beside built, both boards | `references.md`, `colors.md`, `types.md`, `table-of-contents.md`, the guide; `./build.sh bench` against `Budget.referencePills` (a moved budget said so); the gallery's `Pill-` states; the full suite | S | all |

- Order: 1, then 2; then 3, 6 and 7 side by side; 4 and 5 after 3; 8 last. Side-by-side slices build in their own clones and merge here.
- Done: each slice's tests, the full suite and bench pass, a code review, and before/after renders. It lands on main as one commit on your word.
- After it lands: your codebase boards are redrawn once by the usual `ingest` run.

## Note added for the builders (not in the doc)

- Main moved after the plan: `58646636` makes a shape of a type with no color of its own take the color its type's pill shows (set, else the one picked from the type's id), and `TypeIndex.color(inheritedBy:)` now answers a type itself (`Sources/Types/Type/TypeIndex.swift:199`), so slice 4's Types change is already on main: build nothing in Types for it. `60a448c8` lets a subboard or a frame be of a type, taking its type's color the same way. The pill reads every one of these through the color book (`ColorBook.color(of:)`, `swatch(of:)`), so it needs nothing kind- or type-specific.
- Line numbers above are from before those commits; find the symbols, don't trust the numbers.

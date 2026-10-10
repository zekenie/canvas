---
name: canvas
description: Put, draw or lay out things on a live board in Infinite Canvas (sticky notes, types, frames, subboards, references and the arrows between them, for plans, flows, architectures, roadmaps, retros) with `canvas draw`, a text language where each line says what a shape is, what it's called, and where it sits against shapes already named; and find out what's on a board with `canvas query`, a CSS-like query, or `--ask` in English. Use when asked to "draw this on the board", "put these on the canvas", "make a diagram in the app", "connect these on the board", "what's on the board", "which notes mention X", "is X inside Y", "what links to X", "how many…", or to turn a plan, list or architecture into shapes in the running app. NOT for changing the app's Swift code, plugins, tests or docs; NOT for reading or writing .canvasboard files (only `canvas` touches a board); NOT for diagrams meant for a file (SVG, Mermaid, images).
---

# Drawing on and reading a board with canvas

`canvas draw` puts shapes on a board that's open in the Infinite Canvas app, while the user watches. You write one statement a line: what the shape is, what it's called, and where it sits against things already named (`right of "API"`, `below board`). The app works out only the distances. A script is applied in one step, or not at all.

You can't see the board, and `canvas query` reads it back: which shapes match, with their titles and ids. Where they are it doesn't read, and that's why the language works this way: the arrangement is in the sentences you wrote, so re-reading your script tells you where everything is. The result says what actually happened to each line, and what had to be pushed aside to keep clear. Anything ambiguous is refused rather than guessed, so a script that runs is one whose arrangement you fully stated.

## Check the app

Run everything from the repository root. `canvas` isn't on your PATH; `build/canvas` is the one this checkout built.

```bash
build/canvas status
build/canvas boards
```

Exit 3 means the app isn't reachable: for `not_running`, start it with `./build.sh && open build/InfiniteCanvas.app`; `unreachable` usually means a sandbox is blocking the socket, so ask the user. If `canvas` says the app speaks another protocol (`protocol_mismatch`), the app running and this checkout were built apart. A second copy of the app doesn't take over from the one running, so don't just open another: ask the user to quit the app, then open this checkout's (`./build.sh && open build/InfiniteCanvas.app`). `boards` lists the open boards. Pick one and pass `--board <id>` on every `draw` and `query` after that, because without it a command goes to whichever board is in front, which changes whenever the user clicks another window. With none open (`no_board`), or when the user wants a new one, `build/canvas new ~/Boards/Plans.canvasboard` makes a new board's file there and opens it, and answers as `boards` lists it, `id` and all; it never touches a file that's there already. `kinds`, `query-vocabulary`, `status`, `boards` and `new` are about the app, and take no `--board`. An id lasts while its board is open.

`--board` picks a file, not a board inside it. A file can hold boards inside shapes (a subboard's), and you never say which one a script draws on: a title names a shape on whatever board it's on (the board the window shows first), a new shape goes on the board of what it's placed against, `in "Payments"` puts it on the board of the subboard called Payments (and `in "Sprint 3"` in the frame called Sprint 3, on the board that frame is on), and a shape with neither goes on the board the rest of the script draws on, else the one the window shows. A run draws on one board and never moves the window; its result's `on` says which board (`"root"`, or the id of the shape that holds it, and that shape's `title`). `boards` says what the window shows, as `shows` and `showsPath` (the boards from the root down to it). To move the window, `build/canvas show "Payments"`, or `build/canvas show --root`.

## The loop

`build/canvas kinds` gives you the vocabulary: every kind you can draw, how it can be named, its size, the attributes it takes with their values, and the channels its edges use. Kinds come from plugins, so this list is the truth; the tables below are what shipped when this was written. On a board you didn't just draw, look at what's there first ([Reading the board](#reading-the-board)): the titles in the file (`[title]`, every board's) are the names your script can use, or would change by accident. Then write the script and dry-run it, which does everything but commit:

```bash
build/canvas draw --board 2 --dry-run - <<'EOF'
sticky-note "Inbox" text: "Everything new lands here"
EOF
```

Read what comes back, fix the script, and dry-run again until it says what you meant. Then run the same command without `--dry-run`. Always pass the script through a heredoc with a quoted delimiter, `<<'EOF'`. With an unquoted one the shell expands `$` and backticks and eats backslashes, which silently changes titles and text. A script passed as an argument breaks at the first apostrophe. The result goes to standard output as JSON, because your shell isn't a terminal:

```json
{"board": {"id": 2, "name": "Architecture", "shows": "root", "showsPath": ["root"]}, "warnings": [], "dryRun": true,
 "changes": [{"line": 1, "did": "created", "kind": "sticky-note", "title": "Cache", "at": [[560, 300], [200, 200]], "inView": true},
             {"line": 2, "did": "moved", "kind": "sticky-note", "title": "DB", "at": [[840, 300], [200, 200]], "inView": true}]}
```

- `did` is one of `created`, `updated`, `moved`, `renamed`, `unchanged`, `deleted`, `connected` or `reconnected`. Check each row against what you meant. A `created` where you meant to change a shape means its title didn't match.
- `pushedPast` means the shape had to move past others to keep clear of them, so it isn't where your sentence put it (see the next section). A shape that only moved along with a pushed one has none; its warning names that shape, whose placement is the one to fix.
- `inView: false` means it landed outside the window. Add `--reveal` to ease the camera onto what was drawn.
- A warning about a statement carries its line. Warnings cover pushes, near-miss titles, sides that face away, shapes that landed out of view, and every validation issue on what you drew. An `error` there means the board outlines that shape in red.

A run is one step of the app's undo: Edit › Undo Draw (⌘Z) takes the whole of it back, so the user can too. A dry run, or a script that fails, is none.

When a script fails, nothing is drawn. The error goes to standard error as `{"error": {…}}`, with `reason` (a word to branch on), `message` (your statement in its own words), `hint` (usually the line to write instead), `line` and `statement`. Mistakes found reading and resolving the script (kinds, titles, attributes, targets, an edge's ends) that don't depend on each other come back together: when there's more than one, `errors` lists them all, so fix them all in one pass. Placing, and each edge's channel and sides, report one problem at a time. Exit 1 means the app refused the script, 2 that the command line itself is wrong, and 3 that the app wasn't reached or didn't answer in time.

**After a timeout** (`timed_out`) the app may still draw the script: it doesn't drop what it was sent. Don't run it again to find out; dry-run it. Titled shapes and edges whose rows say `unchanged` landed. A `delete` that now fails with `unknown_title` (or `delete edge`, with `nothing_to_delete`), or a rename whose old title now makes a new shape and fails (`unsupported`), already ran. An untitled shape always comes back `created`, so nothing tells you whether it landed: title every shape in a script you might have to check.

## The one idea

**A gap is a minimum, among the shapes your script places. Shapes already on the board don't move unless you restate them with a placement. To the script they are walls.**

```draw
sticky-note "Web" text: "Browser app"
sticky-note "API" right of "Web" text: "Public HTTP API"
sticky-note "DB" right of "API" text: "Postgres"
```

That draws three notes in a row, a normal gap (80) apart. Web has no placement, so the drawing lands in the middle of the window, or as near it as it can while keeping clear of everything already there.

Now put a cache between API and DB. On its own, `sticky-note "Cache" right of "API"` would land on DB. It would then be pushed right past DB, and the row would come back with `pushedPast: ["DB"]` and a warning, because DB is a wall. To make room, move DB as well:

```draw
sticky-note "Cache" right of "API" text: "Redis"
sticky-note "DB" right of "Cache"
```

The second line restates DB. It has the same title, so it's the same shape: its placement moves it, and its text stays as it was. Anything an earlier script placed against DB stays where it is, though. Placements are worked out once, when the script runs, and the board keeps only positions. To move a group, restate every shape in it.

## Titles are names

A title is how you, the user and later scripts refer to a shape: `draw` never takes an id. A query's rows carry each shape's id, for naming it in a later query (`#<id>`), and for nothing else.

- **Quote every title** in straight double quotes: `"API"`. A bare word is read as a placement word or a value, and curly or single quotes are refused.
- **A title in the file means that shape.** A statement whose title is already on a board of the file updates that shape, there (the board the window shows first); any other title creates a new one. The match is exact and case matters, so a typo like `"deploy"` for `"Deploy"` draws a second shape. The result warns about near misses, so read the warnings.
- **Title everything you may touch again.** An untitled shape can't be moved, connected, changed or deleted by a later script. The query `[title]` lists the titled shapes, with the board each is on ([Reading the board](#reading-the-board)).
- **A note's title is the pill above it; what it says is `text:`.** Give notes both. A subboard's title is on its card.
- **Keep titles short and specific** ("Auth service", not "Service"). Longer than 80 characters is kept but warned about. A generic title like "Notes" may already be on the board, and your statement would then change the user's shape, so dry-run first on any board you didn't just draw.
- **Shapes the user made are usually untitled.** A note's words are its text, not a title. A query finds them by what they say (`sticky-note:not([title])[text*="launch"]`), but a script can't name them: place against `board` or `view` instead, or ask the user to title the shapes you need.
- **A type is a note with a `schema:`**, called by its title as any note is: `sticky-note "Order" schema: "{\"type\": \"object\"}" text: "An order: its id"`. Its name is the note's title, never a `"title"` in its schema. A type is not public unless the user makes it so (`public:` is their call, as for any shape).
- **A shape is an instance of a type by naming it in `is:`, by its title**: `sticky-note "Ann" is: "Person"`, on a note or an edge (`edge "A" -> "B" is: "Friendship"`). Several are a JSON list, in the order added, a later one winning where two say the same: `is: ["Person", "Employee card"]`. A title is found as any title is, on any board of the file, or drawn by the same script, before or after; a shape that isn't a type is refused (`invalid_value`, "which isn't a type or a shape"), as is naming a type already built on the shape (a cycle). A type may be one of types itself. The user adds one with `/is-a` on a line of the note's text or an arrow's label. `:is-a("Person")` finds the shapes that are a Person, however far (Ann, a card of Employee card, which is a Person); `:edge-to("Person", is-a)` only those that say so.
- **A note's `text:`, and an edge's, can mention shapes by title.** `@[Owner]` in one is a mention of the shape called Owner: the note, or the arrow's label, shows a pill with that shape's name, live, and the app keeps the id, which you never write or see. The title is found as any title is, but on any board of the file: a shape the script draws (even further down it), else the one on the board the script draws on, else the one on the board the window shows, else the one anywhere else in the file. A title nobody has is refused (`unknown_title`, with the one like it), and so is one two shapes have in the first place that has any (`ambiguous_title`). A title in a text never moves the run to its board. Anything else in `text:` is kept as written: an `@` alone, or an `@[` with no `]` on its line, is just text. To write `@[` as text, write `\\@[` (a script's string spells a backslash twice). A query shows a note's or an arrow's mentions as they read, `@` and the name of what each mentions.

## Writing

One statement per line. `//` starts a comment anywhere outside quotes. Blank lines and indentation don't matter. A statement is a kind, an optional quoted title, then attributes (`key: value`) and placements in any order.

```text
<kind> ["<title>"] { attribute | placement }    make a shape, or update the one with that title
edge "<a>" -> "<b>" { attribute }                connect two shapes (also <- and <->)
delete "<title>"                                 remove a shape and every edge on it
delete edge "<a>" -> "<b>"                       remove the edges from a to b
style <name> attribute { attribute }             a named set of attributes, for this script
```

### Shapes and attributes

| kind | size | attributes besides `size`, `gap`, `overlap`, `style`, `title` | edges |
|---|---|---|---|
| `sticky-note` | 200x200 | `text` (the note is as tall as its text, at least 200; a `size:` height lasts only until the text changes, and a width alone, `size: 320x`, keeps it as tall as its text at that width), `schema` (a JSON Schema, as text, which makes the note a type: its panel shows it), `is` (the types it is: their titles, in the order added), `locked`, `public` | `note-link`, on all four sides |
| `subboard` | 240x160 | `locked` (locking a subboard locks what's on its board, at any depth), `public` | every channel (`subboard-link`, `note-link`), on all four sides |
| `frame` | 640x400 | `locked` (locking a frame locks what's in it), `public` | none: plain arrows |
| `reference` | 120x32 | `query` (a query: the pill stands for what it finds), `all` (every match, not only the first), `locked` | none: plain arrows |

Arrows are what edges are; you don't draw one on its own. An edge takes the arrow's attributes beside `from:`, `to:` and `channel:`: `text:` (what it says, set on its line; it mentions shapes by title as a note's text does, `@[Title]`), `labelPosition:` (where along it, `0` to `1`, halfway by default), `bend:`, `is:` (the types it is, as a note's) and `locked:`; its heads are its arrow's (`->`, `<->`). Values: text is quoted (`text: "Two words"`). `true` and `false` are bare words (`locked: true`). `null` puts a property back to its default (but not a title: `title:` only renames). `size: 300x200` is in world units, up to 100000. A width alone, `size: 300x`, leaves the height to the kind: a note as tall as its text at that width, any other kind as tall as it was, or as its tool draws it if it's new. A value past a bound, like a title over 80 characters, is kept and warned about.

A subboard is a card that holds a board of its own. `in "Payments"` draws a shape on its board, without opening it; `inside "Payments" top-left` puts a shape over its card instead. Draw the subboard first, then what goes in it in a run of its own. Deleting it deletes everything on its board too (the result warns how much). A locked one takes nothing new, and what's on its board, and on every board under it, refuses changes (`read_only`). A type is a note with a `schema:`: its `text:` says what the type holds, in words, and its `schema:` says it as JSON inside a quoted string, so escape each quote: `schema: "{\"type\": \"object\", \"properties\": {\"id\": {\"type\": \"string\"}}}"`; the user sees it in the note's panel, its Schema tab. Its name is the note's title, so its schema has no `"title"`. Give a type both. What you write on one is taken as written: the Claude sync that rewrites one side when the user edits the other isn't asked, so write text and a schema that agree. A type refers to another type twice, in words and in its schema, and you write both: its `text:` mentions it by its title, `@[Address]` (a mention of a type is a reference to it; a mention of any other shape is only words), and its `schema:` points to it with `{\"$ref\": \"urn:uuid:<id, lowercase>\"}` where that field goes, the id being the type's, from `canvas query`'s rows. Only the `$ref` takes an id. `sticky-note[schema]` finds the types.

```draw
sticky-note "Ship v1" below "API" text: "Cut the release once @[API] and @[DB] agree"
```

A frame is a region of the board that holds shapes: what's in it moves with it and is locked with it, and deleting the frame leaves what's in it where it is. `in "Sprint 3"` puts a shape in it, 40 in from its edges: with no other placement, against its top-left, and several written alike in a list down from there; with placements, where they say, kept within it, or the script fails with `no_room`. A frame doesn't grow, so give it a `size:` with room for what goes in it (a frame is at least 96x64), and draw it first: `in` a frame the same script draws is `unsupported`. Nothing sits across a frame's edge: whatever a script puts down over one goes wholly in or out by most of its area, nudged, and a warning says which (`"Draft" was over the edge of "Sprint 3", so it was nudged in`). So a shape placed `inside` a frame, `on` it, or against a shape in it, that lands within it, is in it too.

```draw
frame "Sprint 3" right of "DB" size: 900x600
```

```draw
sticky-note "Fix the login" in "Sprint 3" text: "Sessions expire too soon"
sticky-note "Move billing" in "Sprint 3" text: "Invoices go to the new API"
sticky-note "Index search" in "Sprint 3" right of "Fix the login" text: "Search the archive too"
```

### Placements

```text
above "A"             below "A"             left of "A"             right of "A"
above-left of "A"     above-right of "A"    below-left of "A"       below-right of "A"
level with "A"        top level with "A"    bottom level with "A"   (share a vertical middle, top or bottom)
left level with "A"   right level with "A"                          (share a left or right edge)
inside "A" <part>     outside "A" <part>    on "A" [<part>]
```

- **A lone direction binds both axes.** `right of "A"` also centers the shape vertically on A, because walking right from something keeps you on its center line. Once another placement speaks for that axis, the centering drops away.
- **Two directions on one axis and nothing on the other is refused**, because nothing says which row the shape shares. For example, `right of "A" left of "B"` needs a `level with "A"` as well. Held from both sides, a shape sits against the one on its left (or above it).
- **Exactly one new shape per script may have no placement.** That shape and everything placed against it go in the window as one drawing, as near its middle as there's room.
- **Shapes don't overlap.** A shape that lands on a wall is pushed along the axis its placements leave free, and the result says so. Two shapes the script places that would overlap, with nothing saying which side of the other either sits on, are refused (`unordered`): place one against the other.
- **Several targets make one box:** `below "A" and "B"` centers under the pair.
- **Gaps** are `none` (0), `tight` (40), `normal` (80, the default), `wide` (160), or a number. Write one after a placement, `right of "A" (gap: tight)`, or on the shape, `gap: wide`, which applies to every placement it's in.

```draw
sticky-note "Risks" right of "Ship v1" top level with "Ship v1" text: "Load-test the API before launch"
```

### The board, the view, and lists

`board` (unquoted) is the box around every shape the script doesn't move, and `view` is the part of the board in the window. So a column on the right is `right of board`, the space under everything is `below board`, and a legend in a corner is `inside view top-right`. Shapes whose placements are written identically form a list: they stack down the page in script order, 64 apart, and are placed as one. A later script's `right of board` won't join this column but goes right of the whole board again, so to add to a list, restate every member.

```draw
subboard "Design" right of board
subboard "Build" right of board
subboard "Launch" right of board
```

### Parts, inside, and zones

A target can name a part: a side (`top`, `bottom`, `left`, `right`) or a point (`top-left`, `top-center`, `top-right`, `left-center`, `center`, `right-center`, `bottom-left`, `bottom-center`, `bottom-right`). `inside "A" top-left` tucks the shape into that corner of A, 40 in, and keeps it within A. `outside "A" right` puts it wholly beyond that side. `on "A" top-right` centers it on that point.

A zone is a big shape that others sit on: a note with a title, no text, and a `size:`. Draw it in its own script first, then what goes in it. Once it's on the board, it isn't in the way of a shape placed against one it holds, or of one landing wholly on it while it already holds other shapes, as long as it's at least twice the size (in area) of the one it holds or the one landing. A shape your script places counts as one the zone holds only when it's there for a reason of its own (placed `inside` or `on` it, against a shape already in it, or among shapes already on the board in it), never just because another new shape is: two new shapes landing together on an empty zone are both pushed off it. Nor is a zone in the way of a shape you restate that already sat on it, however snugly (lined up with a card in the next column, a card stays in its own), or of one placed against `view` while the whole view is on it (a legend `inside view top-right` while you're zoomed into a region), or of the unplaced shape's drawing there. Whatever else a shape lands on is in the way, however big. An empty note or card is in the way, so a small note beside a note is pushed past the next note, not drawn over it. But a note or card that holds a shape of its own, wholly inside it (a badge), is a zone like any other: a smaller shape landing wholly on it is drawn over it, text and all. A shape alone on the board is in the way of anything `inside board`. Put the first shape in an empty zone with `inside`, and place the rest against it. Only `inside` keeps a shape within a zone: one placed against a shape in it, or restated, can hang over its edge, and the result warns (`hangs over the edge of`), so place it `inside` or make the zone bigger. Within one script, only shapes placed `inside` or `on` a shape may overlap it, so a zone drawn in the same script as what goes in it pushes the rest out of it, or the script fails with `no_room`.

```draw
sticky-note "Backend" below board size: 900x320
```

```draw
sticky-note "Queue" inside "Backend" top-left text: "Jobs waiting to run"
sticky-note "Worker" right of "Queue" text: "Runs each job"
edge "Queue" -> "Worker"
```

### Edges and channels

```draw
edge "Web" -> "API"
edge "API" -> "Cache"
edge "Cache" -> "DB" from: right to: left
edge "Design" -> "Build"
edge "Build" -> "Launch"
```

`<-` is the same edge written the other way round, and `<->` has heads at both ends. `from:` and `to:` name the side each end leaves or arrives on; without them the line runs center to center. An edge statement means "A is connected to B", so written again it updates that edge (`reconnected`) or leaves it alone (`unchanged`), and never draws a second one.

An edge travels on a channel that both ends take: notes connect to notes (`note-link`), and subboards to anything that has channels, a note on its channel and another subboard on `subboard-link` (Design, Build and Launch above). The edge picks the channel both ends share, and if they share none it's refused. `channel: none` draws a plain arrow between any two shapes. Frames have no channels at all, so an edge between two of them is plain without asking; between one of them and a note or a subboard, say `channel: none`.

```draw-error
// reason: no_channel
edge "Ship v1" -> "Sprint 3"
```

```draw
edge "Ship v1" -> "Sprint 3" channel: none
```

An arrow can't leave its board, so an edge to a shape on another board goes into a **reference**: a pill that stands for the shape, which the run puts beside the shape on this board. `edge "Checkout" -> "Auth"`, with Auth on a subboard's board, draws a reference to Auth right of Checkout and the arrow into it, and the row says `via: "reference"`. The references beside a shape stack in a column of their own, 16 apart, and a later run's join the column there. `delete edge "Checkout" -> "Auth"`, or `delete "Checkout"`, takes the reference with the arrow, once no other arrow is on it. Only a public shape can be stood for, and making one public is the user's call: for one that isn't, the script is refused (`several_boards`) and you ask. `via: reference` asks for a reference on one board too, for a shape that other edges point at, and `share: true` (or `share: "Checkout"`, for the one beside Checkout) draws an edge into a reference to the same end that's there already, rather than make another. [reference/language.md](reference/language.md#through-a-reference) has the rest.

### Styles

A style bundles attributes for the script it's in. A shape's own attributes win over its styles, and of several styles, the later one wins.

```draw
style small size: 160x160
sticky-note "Fix login" left of "Web" style: small text: "Sessions expire too soon"
sticky-note "Fix signup" below "Fix login" style: small text: "The form drops the email"
```

### Restating, renaming, deleting

A statement about a title that's on the board updates that shape. Whatever it doesn't say stays as it was, and with no placements the shape stays where it is.

```draw
sticky-note "Ship v1" text: "Tests written, release tagged"
```

With placements, a restated shape moves. An axis that none of its placements speaks for stays where it was, so this moves Risks sideways without changing its vertical position:

```draw
sticky-note "Risks" left level with "Web"
```

`title:` renames a shape. Other lines in the same script still call it by its old title; the new one applies from the next script. `delete` removes a shape and every edge on it, even one whose other end is free. To change a shape's kind, delete it and draw it again in the same script, along with its edges.

```draw
sticky-note "Ship v1" title: "Ship 1.0"
delete "Risks"
```

## A complete example

These are real shipped kinds; `build/canvas kinds` says what your app has. Only "Sign-up form" is unplaced, so the whole drawing goes as near the middle of the window as it can while keeping clear of what's there. On a full board that can be outside the window: the rows say `inView: false`, and `--reveal` brings the drawing into view.

```draw
// A sign-up flow, left to right, and the work it needs underneath.
style work size: 240x160

sticky-note "Sign-up form" text: "Email and password"
sticky-note "Auth service" right of "Sign-up form" text: "Creates the account"
sticky-note "Welcome email" right of "Auth service" text: "Sent once the account exists"

sticky-note "Rate-limit sign-ups" below "Auth service" style: work text: "Five a minute per address"
sticky-note "Verify emails" below "Auth service" style: work text: "Send a code that expires after a day"
sticky-note "Write the email copy" below "Welcome email" style: work text: "Short, and says what's next"

edge "Sign-up form" -> "Auth service"
edge "Auth service" -> "Welcome email"
edge "Rate-limit sign-ups" -> "Verify emails"
```

## Reading the board

You can't see the board, so this is how you look at it: before drawing on a board you didn't just draw, to learn the titles already there, and after, to check what's connected to what. `canvas query` takes a query, a selector as CSS writes one, and lists every shape of the file that matches, on every board, in file order. It changes nothing. Pass the query through a heredoc with a quoted delimiter, as you pass a script: queries are full of `"`, `*`, `>`, `[` and `#`, which the shell mangles.

```bash
build/canvas query --board 2 - <<'EOF'
sticky-note:edge-to("Auth service")
EOF
```

```json
{"board": {"id": 2, "name": "Sign-up", "shows": "root", "showsPath": ["root"]}, "query": "sticky-note:edge-to(\"Auth service\")", "count": 1,
 "rows": [{"id": "7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11", "kind": "sticky-note", "title": "Sign-up form", "board": "root",
           "properties": {"text": "Email and password"}}]}
```

- **A row is a shape**: its `id`, `kind`, `title` (none when it's untitled), `board` (`"root"`, or the id of the subboard whose board it's on), `inside` (the names of the subboards and frames it's inside, outermost first) and its attributes, `properties`, text as a person reads it. An arrow's row says where it runs, in `connection`.
- **An id names that shape in a later query**, `#7C1E2A04-…`, since titles can repeat. `draw` still names shapes only by title.
- **A yes-or-no question is a query that matches the shape it asks about, or nothing**: `count` is 1 or 0, and `canvas` exits 0 either way. A title no shape has is refused (`unknown_title`, with the one like it), so a no always means no.
- **`--count`** returns only how many; **`--brief`** leaves each row's attributes out; **`--fields text`** lists only that attribute, whole (long text is otherwise cut at 500 characters); **`--limit 500`** lists up to 500 rows (100 unless it says).
- **A space means inside**: `"Payments" sticky-note` is the notes inside the subboard Payments, on its board or a board inside it, and `"Sprint 3" sticky-note` the notes in the frame Sprint 3, at any depth. So never put a space before a test: `sticky-note:mentions("API")`, not `sticky-note :mentions("API")`, which is refused (`stray_space`). Inside is always a subboard's board or a frame, never `draw`'s `inside`, a shape drawn over another (though one drawn over a frame is in it: nothing sits across a frame's edge).
- **When the person asked in English**, `--ask "their question"` has the app write the query (with the Claude key they saved in Settings), runs it, and says what it wrote, in `query`: check it asks what they meant. Otherwise write the query yourself; [query-prompt.md](query-prompt.md) is what the app tells Claude to write one.

A kind is every shape of that kind, a title in double quotes is the shape called that (right after a kind, with no space, the shapes of that kind called that: `sticky-note"Queue"`), and tests follow with no space: `[text*="email" i]` for text (`i`: in any case), `[title=""]` for no title, `:edge-to(…)` and `:edge-from(…)` for what an edge runs to and from, `:connected-to(…)` for either, `:downstream-of(…)` for what's reached by following edges, and more ([reference/query.md](reference/query.md)). On what this page drew, the notes whose title or text has "email" in it:

```query
/* matches: "Fix signup", "Sign-up form", "Welcome email", "Verify emails", "Write the email copy" */
sticky-note:contains("email")
```

What Web leads to, however far:

```query
/* matches: "API", "DB", "Cache" */
:downstream-of("Web")
```

The notes with an edge to Auth service, and what Auth service has an edge to:

```query
/* matches: "Sign-up form" */
sticky-note:edge-to("Auth service")
```

```query
/* matches: "Welcome email" */
:edge-from("Auth service")
```

And what's connected to it, either way:

```query
/* matches: "Sign-up form", "Welcome email" */
:connected-to("Auth service")
```

Does Queue have an edge to Worker? It matches, so yes:

```query
/* count: 1 */
"Queue":edge-to("Worker")
```

Backend is a note, and holds no shapes: a note drawn `inside "Backend"` sits over it, and isn't inside it as a query means inside.

```query-error
/* reason: cannot_contain */
sticky-note:inside("Backend")
```

## What will bite you

**Habits from other languages**: bare or curly-quoted titles, `node`, `note` or `box` for a kind (the hint lists the kinds, and names the one like it), `link` for an edge, `-->` or a bare `"A" -> "B"`, `#` for a comment (comments are `//`), a quoted label after an edge (write `text: "…"`), coordinates (`x:`, `at:`). Each is refused, most with a hint naming what to write instead, and every unreadable line comes back in one pass:

```draw-error
// reason: syntax
sticky-note Web right of "API"
edge "Web" --> "API"
# Services
```

**Inventing attributes** (`color: red`, `label:`, `owner:`). Every key is checked against the kind, so look in `build/canvas kinds` first.

```draw-error
// reason: unknown_attribute
sticky-note "Ship 1.0" owner: "Ann"
```

**A mention that names no shape.** An `@[…]` that closes on its line is a mention, found by its title exactly, so a slip is refused (`unknown_title`, with the title it's like) rather than left as text. If you meant the characters, write `\\@[`.

```draw-error
// reason: unknown_title
sticky-note "Ship 1.0" text: "Blocked on @[Auth servce]"
```

- **Between, with nothing on the other axis.** `right of "Web" left of "Cache"` alone is `unplaced`: add `level with "Web"`.
- **Two unplaced shapes.** Only one per script may say nothing about where it goes; place the rest against it. And there are no coordinates in any form: if a shape is in the wrong place, give it another placement. A layout worked out elsewhere goes in as offsets from one shape's top-left ([An exact offset](reference/language.md#an-exact-offset)).
- **Re-running a whole layout script to add one line.** Its placements run again and snap back anything the user has moved since, and its untitled shapes are drawn a second time. Write only the new statements. To change attributes without moving a shape, restate it without placements.
- **An edge to a shape on another board** goes through a reference only if that shape is public. If it isn't, the script is refused (`several_boards`, and its hint says why): don't make the shape public to get past it, ask the user, or split the script into a run for each board. The one exception is [canvas-digest](../canvas-digest/SKILL.md), which makes public only the shapes it creates itself, in the run that creates them, and says which; it never touches a shape that was already on a board.
- **Edges across channels**, and **shapes the user locked**, which refuse changes (`read_only`), as does everything in a locked frame or on a locked subboard's board. Connect like to like (or to a subboard) or say `channel: none`; tell the user about a locked shape rather than unlocking it.
- **A frame and what goes in it in one script.** `in` a frame the same script draws is refused (`unsupported`): draw the frame, then what goes in it in a run of its own.

## Honest limits

- **Queries don't see where shapes are.** A query knows what's inside what (a subboard's board, a frame) and what's connected to what, never positions, sizes or overlaps: what's left of what, or drawn within a rectangle, it can't ask.
- **Typing may still change.** A note the user is typing into reads as typed so far, and the query's result warns that it may still change (`editing`).
- **Some shapes aren't in any answer**: shapes the app keeps aside (a kind this app doesn't have), and those on boards it can't show.
- **Placement happens once.** The board doesn't remember `right of "API"`. When the user moves API, nothing follows it (but what's in a frame moves with the frame).
- **Frames don't grow.** A frame stays the size it was drawn, so `in` one that's full is `no_room`: restate it with a bigger `size:`.
- **The result confirms intent, not the picture.** It tells you where each shape landed and what was pushed. It doesn't tell you whether a note's text overflowed (a note grows to fit its text unless you gave it a height with `size:`, which cuts long text off, so give a note with long text no `size:`, or a width alone, `size: 320x`) or whether a line crosses other shapes.
- **Edges are arcs.** They don't route around shapes. Only closed shapes are kept clear, so a shape can land across an arrow or a drawn line.
- **Pills overlap when zoomed out.** A title's pill (and a lock's chip, in the same row just above a shape) clears the shape above it in a list down to about 42% zoom (below 35% shapes are skeletons: no pill or chip is drawn, and a title is said on the shape instead).
- **One board per run.** A run draws on one board (`in` says which, and the window never moves), and an arrow can't leave it: an edge to a shape on another board is drawn into a reference to that shape, which only a public one can have.

## Reference

[reference/language.md](reference/language.md) is the full `draw` language: every construct, the gap and part tables, how lists, pushes and the unplaced drawing are worked out, edges and channels, every error reason with its fix (the command line's own and the boards' too), what the language refuses and why, and what isn't built yet. Read it when you need a construct this page doesn't cover, or when an error points at behavior you didn't expect. `build/canvas help draw` is the command's own help.

`build/canvas measure -` takes a script on standard input and says how big each of its shapes would be, how wide a reference to a shape is and what the placement constants are, without drawing or reading anything: for a tool that lays a script out before it writes it ([reference/language.md](reference/language.md#measuring-a-script)).

For a large body of connected information (a codebase, an org, research notes, a plan: dozens to hundreds of shapes and the links between them), don't write the script by hand: [canvas-digest](../canvas-digest/SKILL.md) takes the things, what holds what and what points at what, measures them with `canvas measure`, decides where everything goes and which hubs get reference pills, and draws it with this command.

[reference/query.md](reference/query.md) is the whole query language, on a story file: naming shapes, attributes, inside, edges and their direction, the plugins' words, yes-or-no questions, `--ask`, and every refusal with its fix. [query-prompt.md](query-prompt.md) is what the app tells Claude for `--ask`, word for word, with how to give yourself what it's given. `build/canvas help query` is the command's own help, and `build/canvas query-vocabulary` what this app's queries can name: its kinds and their attributes, its edge types and its words.

[reference/references.md](reference/references.md) is what a reference does to what you read: a pill that stands for a public shape, so an arrow into it is an arrow into the shape, and how a row says it (`via`, `more`), and what a script can make of one (an edge to a shape on another board).

The language and its solver are modified from [reladraw](https://github.com/reladraw/reladraw) (Apache-2.0; see THIRD_PARTY_NOTICES.md). This language isn't called that.

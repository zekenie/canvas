---
name: canvas
description: Put, draw or lay out things on a live board in Infinite Canvas (sticky notes, subboards, schema cards, rectangles and the arrows between them, for plans, flows, architectures, roadmaps, retros) with `canvas draw`, a text language where each line says what a shape is, what it's called, and where it sits against shapes already named. Use when asked to "draw this on the board", "put these on the canvas", "make a diagram in the app", "lay out the tasks", "add notes to the board", "connect these on the board", or to turn a plan, list or architecture into shapes in the running app. NOT for changing the app's Swift code, plugins, tests or docs; NOT for reading or writing .canvasboard files (only `canvas` touches a board); NOT for diagrams meant for a file (SVG, Mermaid, images).
---

# Drawing on a board with canvas

`canvas draw` puts shapes on a board that's open in the Infinite Canvas app, while the user watches. You write one statement a line: what the shape is, what it's called, and where it sits against things already named (`right of "API"`, `below board`). The app works out only the distances. A script is applied in one step, or not at all.

You can't see the board, and nothing reads it back to you yet. That's why the language works this way: the arrangement is in the sentences you wrote, so re-reading your script tells you where everything is. The result says what actually happened to each line, and what had to be pushed aside to keep clear. Anything ambiguous is refused rather than guessed, so a script that runs is one whose arrangement you fully stated.

## Check the app

Run everything from the repository root. `canvas` isn't on your PATH; `build/canvas` is the one this checkout built.

```bash
build/canvas status
build/canvas boards
```

Exit 3 means the app isn't reachable: for `not_running`, start it with `./build.sh && open build/InfiniteCanvas.app`; `unreachable` usually means a sandbox is blocking the socket, so ask the user. If `canvas` says the app speaks another protocol (`protocol_mismatch`), the app running and this checkout were built apart. A second copy of the app doesn't take over from the one running, so don't just open another: ask the user to quit the app, then open this checkout's (`./build.sh && open build/InfiniteCanvas.app`). `boards` lists the open boards. Pick one and pass `--board <id>` on every `draw` after that, because without it a draw goes to whichever board is in front, which changes whenever the user clicks another window. `kinds`, `status` and `boards` are about the app, and take no `--board`. An id lasts while its board is open.

`--board` picks a file, not a board inside it. A file can hold boards inside shapes (a subboard's), and a draw lands on the one that file's window shows: `boards` gives it as `shows` (`"root"`, or the id of the shape that owns it) and `showsPath` (the boards from the root down to it). Every result names it too, in `board`. If `shows` isn't what it was when you started, the user has gone into or out of a subboard: stop, and tell them where your last drawing went. Nothing draws into a subboard from outside it, so to draw on one, ask the user to open it, check `shows`, then draw.

## The loop

`build/canvas kinds` gives you the vocabulary: every kind you can draw, how it can be named, its size, the attributes it takes with their values, and the channels its edges use. Kinds come from plugins, so this list is the truth; the tables below are what shipped when this was written. Then write the script and dry-run it, which does everything but commit:

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

A title is how you, the user and later scripts refer to a shape. There are no hidden ids.

- **Quote every title** in straight double quotes: `"API"`. A bare word is read as a placement word or a value, and curly or single quotes are refused.
- **A title on the board means that shape.** A statement whose title is already on the board updates that shape; any other title creates a new one. The match is exact and case matters, so a typo like `"deploy"` for `"Deploy"` draws a second shape. The result warns about near misses, so read the warnings.
- **Title everything you may touch again**, and keep your own list of the titles you drew, since nothing reads the board back yet. An untitled shape can't be moved, connected, changed or deleted by a later script.
- **A note's title is the pill above it; what it says is `text:`.** Give notes both. A subboard's title is on its card. Rectangles show a pill.
- **Keep titles short and specific** ("Auth service", not "Service"). Longer than 80 characters is kept but warned about. A generic title like "Notes" may already be on the board, and your statement would then change the user's shape, so dry-run first on any board you didn't just draw.
- **Shapes the user made are usually untitled.** A note's words are its text, not a title. Place against `board` or `view` instead, or ask the user to title the shapes you need.
- **A schema card is called by its schema's `"title"`**, and has no title of its own: `schema-card "Order"` is refused (`untitlable`). Draw it untitled, with its title inside `schema:`, and call it by that title from the next script on. Restated with a schema whose title is another, it's renamed (`did: "renamed"`).
- **A note's `text:` is kept as written.** In it, `@[label](shape:…)` is a mention of a shape by its id, which only the app writes, and no id ever reaches you, so write plain words; an `@` or `@[…]` on its own is just text.

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
| `sticky-note` | 200x200 | `text` (the note is as tall as its text, at least 200; a `size:` height lasts only until the text changes), `locked` | `note-link`, on its left, right and bottom |
| `rectangle` | 160x100 | `locked` | none: plain arrows |
| `schema-card` | 240x67 | `schema` (a JSON Schema, as text: the card grows to list it), `prompt` (what it holds, in words), `locked` | `schema-link`, on all four sides |
| `subboard` | 240x160 | `locked` | none: plain arrows |

Arrows are what edges are; you don't draw one on its own. Values: text is quoted (`text: "Two words"`). `true` and `false` are bare words (`locked: true`). `null` puts a property back to its default (but not a title: `title:` only renames). `size: 300x200` is in world units, up to 100000. A value past a bound, like a title over 80 characters, is kept and warned about.

A subboard is a card that holds a board of its own. `inside "Payments" top-left` puts a shape over its card, on the board you're drawing on, never onto its board, and deleting it deletes everything on its board too (the result warns how much). A schema card's `schema:` is JSON inside a quoted string, so escape each quote: `schema: "{\"title\": \"Order\", \"type\": \"object\"}"`; the card grows to list it. What you write on one is taken as written: the Claude sync that rewrites one side when the user edits the other isn't asked, so write a prompt and a schema that agree, or leave `prompt:` out.

```draw
sticky-note "Ship v1" below "API" text: "Cut the release"
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

A zone is a big shape that others sit on. Draw it in its own script first, then what goes in it. Once it's on the board, it isn't in the way of a shape placed against one it holds, or of one landing wholly on it while it already holds other shapes, as long as it's at least twice the size (in area) of the one it holds or the one landing. A shape your script places counts as one the zone holds only when it's there for a reason of its own (placed `inside` or `on` it, against a shape already in it, or among shapes already on the board in it), never just because another new shape is: two new shapes landing together on an empty zone are both pushed off it. Nor is a zone in the way of a shape you restate that already sat on it, however snugly (lined up with a card in the next column, a card stays in its own), or of one placed against `view` while the whole view is on it (a legend `inside view top-right` while you're zoomed into a region), or of the unplaced shape's drawing there. Whatever else a shape lands on is in the way, however big. An empty note or card is in the way, so a rectangle beside a note is pushed past the next note, not drawn over it. But a note or card that holds a shape of its own, wholly inside it (a badge), is a zone like any other: a smaller shape landing wholly on it is drawn over it, text and all. A shape alone on the board is in the way of anything `inside board`. Put the first shape in an empty zone with `inside`, and place the rest against it. Only `inside` keeps a shape within a zone: one placed against a shape in it, or restated, can hang over its edge, and the result warns (`hangs over the edge of`), so place it `inside` or make the zone bigger. Within one script, only shapes placed `inside` or `on` a shape may overlap it, so a zone drawn in the same script as what goes in it pushes the rest out of it, or the script fails with `no_room`.

```draw
rectangle "Backend" below board size: 900x320
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

An edge travels on a channel that both ends take: notes connect to notes (`note-link`), schema cards to schema cards (`schema-link`). The edge picks the channel both ends share, and if they share none it's refused. `channel: none` draws a plain arrow between any two shapes. Rectangles and subboards have no channels at all, so an edge between two of them is plain without asking (Design, Build and Launch above); between one of them and a note or a schema card, say `channel: none`.

```draw-error
// reason: no_channel
edge "Ship v1" -> "Design"
```

```draw
edge "Ship v1" -> "Design" channel: none
```

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

## What will bite you

**Habits from other languages**: bare or curly-quoted titles, `node`, `note` or `box` for a kind (the hint lists the kinds, and names the one like it), `link` for an edge, `-->` or a bare `"A" -> "B"`, `#` for a comment (comments are `//`), text on an edge, coordinates (`x:`, `at:`). Each is refused, most with a hint naming what to write instead, and every unreadable line comes back in one pass:

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

- **Between, with nothing on the other axis.** `right of "Web" left of "Cache"` alone is `unplaced`: add `level with "Web"`.
- **Two unplaced shapes.** Only one per script may say nothing about where it goes; place the rest against it. And there are no coordinates in any form: if a shape is in the wrong place, give it another placement.
- **Re-running a whole layout script to add one line.** Its placements run again and snap back anything the user has moved since, and its untitled shapes are drawn a second time. Write only the new statements. To change attributes without moving a shape, restate it without placements.
- **Edges across channels**, and **shapes the user locked**, which refuse changes (`read_only`). Connect like to like or say `channel: none`; tell the user about a locked shape rather than unlocking it.

## Honest limits

- **Writing only.** No command reads a board back yet, so you know only what your scripts drew and what their results said. Say so when you report back.
- **Placement happens once.** The board doesn't remember `right of "API"`. When the user moves API, nothing follows it.
- **The result confirms intent, not the picture.** It tells you where each shape landed and what was pushed. It doesn't tell you whether a note's text overflowed (a note grows to fit its text unless you gave it a `size:`, which cuts long text off, so leave `size:` off notes with long text) or whether a line crosses other shapes.
- **Edges are plain.** They carry no text, they're arcs, and they don't route around shapes. Only closed shapes are kept clear, so a shape can land across an arrow or a drawn line.
- **Pills overlap when zoomed out.** A title's pill (and a lock's chip, in the same row just above a shape) clears the shape above it in a list down to about 42% zoom.
- **One board at a time.** A draw works on the board its file's window shows, and can't reach a subboard's board from outside it.

## Reference

[reference/language.md](reference/language.md) is the full language: every construct, the gap and part tables, how lists, pushes and the unplaced drawing are worked out, edges and channels, every error reason with its fix (the command line's own and the boards' too), what the language refuses and why, and what isn't built yet. Read it when you need a construct this page doesn't cover, or when an error points at behavior you didn't expect. `build/canvas help draw` is the command's own help.

The language and its solver are modified from [reladraw](https://github.com/reladraw/reladraw) (Apache-2.0; see THIRD_PARTY_NOTICES.md). This language isn't called that.

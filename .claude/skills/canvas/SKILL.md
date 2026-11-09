---
name: canvas
description: Put or lay out things on a live board in Infinite Canvas (sticky notes, types, relationships, frames, subboards, references, database tables, APIs and the arrows between them, for plans, flows, architectures, schemas) with `canvas draw`, a text language where each line says what a shape is, what it's called, and where it sits against shapes already named; and find out what's on a board with `canvas query`, a CSS-like query, or `--ask` in English, and look at it with `canvas capture`, a picture of a board or part of one. Use when asked to "draw this on the board", "put these on the canvas", "make a diagram in the app", "connect these on the board", "what's on the board", "which notes mention X", "is X inside Y", "what links to X", "how many…", or to turn a plan, list or architecture into shapes in the app. NOT for changing the app's Swift code, plugins, tests or docs; NOT for reading or writing .canvasboard files (only `canvas` touches a board); NOT for diagrams meant for a file (SVG, Mermaid, images).
---

# Drawing on and reading a board with canvas

`canvas draw` puts shapes on a board that's open in the Infinite Canvas app, while the user watches. You write one statement a line: what the shape is, what it's called, and where it sits against things already named (`right of "API"`, `below board`). The app works out only the distances. A script is applied in one step, or not at all.

You don't see the board as you write. `canvas query` reads it back (which shapes match, with their titles, ids and where each is, `at`), and `canvas capture` takes a picture of it to look at afterwards ([Looking at the board](#looking-at-the-board)). That's why the language works this way: the arrangement is in the sentences you wrote, so re-reading your script tells you where everything is. The result says what actually happened to each line, and what had to be pushed aside to keep clear. Anything ambiguous is refused rather than guessed, so a script that runs is one whose arrangement you fully stated.

## Check the app

`canvas` is on your PATH once `canvas install` has run: it puts these skills, and a link to the app's own `canvas` (in its bundle, `Contents/Helpers/canvas`), where agents look. It needs no app running, and running it again after an app update brings them up to date. In the Infinite Canvas repository's own checkout `canvas` is `build/canvas` (what `./build.sh` makes), and you run that wherever this skill says `canvas`.

```bash
canvas status
canvas boards
```

Exit 3 means the app isn't reachable: for `not_running`, start Infinite Canvas (in the repository, `./build.sh && open build/InfiniteCanvas.app`); `unreachable` usually means a sandbox is blocking the socket, so ask the user. If `canvas` says the app speaks another protocol (`protocol_mismatch`), the app running and this `canvas` were built apart. A second copy of the app doesn't take over from the one running, so don't just open another: ask the user to quit the app, then open the one this `canvas` came with (in the repository, `./build.sh && open build/InfiniteCanvas.app`). `boards` lists the open boards. Pick one and pass `--board <id>` on every `draw` and `query` after that, because without it a command goes to whichever board is in front, which changes whenever the user clicks another window. With none open (`no_board`), or when the user wants a new one, `canvas new ~/Boards/Plans.canvasboard` makes a new board's file there and opens it, and answers as `boards` lists it, `id` and all; it never touches a file that's there already. `kinds`, `query-vocabulary`, `status`, `boards` and `new` are about the app, and take no `--board`. An id lasts while its board is open.

`--board` picks a file, not a board inside it. A file can hold boards inside shapes (a subboard's), and you never say which one a script draws on: a title names a shape on whatever board it's on (the board the window shows first), a new shape goes on the board of what it's placed against, `in "Payments"` puts it on the board of the subboard called Payments (and `in "Sprint 3"` in the frame called Sprint 3, on the board that frame is on), and a shape with neither goes on the board the rest of the script draws on, else the one the window shows. A run draws on one board and never moves the window; its result's `on` says which board (`"root"`, or the id of the shape that holds it, and that shape's `title`). `boards` says what the window shows, as `shows` and `showsPath` (the boards from the root down to it). To move the window, `canvas show "Payments"` (a title, or a path or an id as a script writes one), or `canvas show --root`.

## The loop

`canvas kinds` gives you the vocabulary: every kind you can draw, how it can be named, its size, the attributes it takes with their values, and the channels its edges use. Kinds come from plugins, so this list is the truth; the tables below are what shipped when this was written. On a board you didn't just draw, look at what's there first ([Reading the board](#reading-the-board)): the titles in the file (`[title]`, every board's) are the names your script can use, or would change by accident. Then write the script and dry-run it, which does everything but commit:

```bash
canvas draw --board 2 --dry-run - <<'EOF'
sticky-note "Inbox" text: "Everything new lands here"
EOF
```

Read what comes back, fix the script, and dry-run again until it says what you meant. Then run the same command without `--dry-run`. Always pass the script through a heredoc with a quoted delimiter, `<<'EOF'`. With an unquoted one the shell expands `$` and backticks and eats backslashes, which silently changes titles and text. A script passed as an argument breaks at the first apostrophe. The result goes to standard output as JSON, because your shell isn't a terminal:

```json
{"board": {"id": 2, "name": "Architecture", "shows": "root", "showsPath": ["root"]}, "warnings": [], "dryRun": true,
 "changes": [{"line": 1, "did": "created", "kind": "sticky-note", "title": "Cache", "at": [[560, 300], [260, 200]], "inView": true},
             {"line": 2, "did": "moved", "kind": "sticky-note", "title": "DB", "at": [[840, 300], [260, 200]], "inView": true}]}
```

- `did` is one of `created`, `updated`, `moved`, `renamed`, `unchanged`, `deleted`, `connected`, `reconnected`, `grouped` or `ungrouped`. Check each row against what you meant. A `created` where you meant to change a shape means its title didn't match.
- `id` is the shape's id, the one a query's row gives: every row about a shape the file has says it (a `created` row too, after a real run; a dry run's has none, since nothing is made), except an arrow's, which a script cannot name, and so does a `deleted` row for a shape the statement named by its id. An edge's row (`connected`, `reconnected` or `deleted`) has `fromId` or `toId` for each end the statement named by id. An id is what you write for a shape that has no title ([Titles are names](#titles-are-names)).
- `pushedPast` means the shape had to move past others to keep clear of them, so it isn't where your sentence put it (see the next section). A shape that only moved along with a pushed one has none; its warning names that shape, whose placement is the one to fix.
- `moved`, beside `changes`, lists the shapes a table, enum or API the run gave rows pushed down to make room below it (each `kind`, `title`, `id`, `at` and how far `down`), only when it pushed some ([engineering.md](reference/engineering.md)).
- `inView: false` means it landed outside the window. Add `--reveal` to ease the camera onto what was drawn.
- A warning about a statement carries its line. Warnings cover pushes, near-miss titles, sides that face away, shapes that landed out of view, every validation issue on what you drew, and every issue the run brought to a shape it did not draw (named by its title, else by its id, `#7C1E…`, which a later script can name it by (an arrow or a reference, that none can, by its kind and where it is), and `on "Area"'s board` when it is on another board, on the line of the statement that brought it: a second relationship at a note whose row allows one, a type restated so that a note's value is wrong, a delete that leaves a note's Needed row empty). An `error` there means the board outlines that shape in red; `incomplete`, said only of a shape you did not draw, means it now still needs something (a Needed row or a field left empty), which is no error and shows nowhere on the board.

A run is one step of the app's undo: Edit › Undo Draw (⌘Z) takes the whole of it back, so the user can too. A dry run, or a script that fails, is none.

A plan drawn in several runs, each on its own board, can't be dry-run a script at a time: a later script names shapes an earlier one makes. `canvas rehearse --board 2 - < runs.json`, with a JSON list of the scripts, draws them in turn on a copy of the file and answers each one's rows as its dry run would, or the first refusal with which script it's in (`script`, from 0), changing nothing.

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

A script names a shape by its title. An id (`#7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11`, the spelling a query uses) is for a shape that has no title: write one only when a query's row shows a shape with none.

- **Quote every title** in straight double quotes: `"API"`. A bare word is read as a placement word or a value, and curly or single quotes are refused.
- **A title in the file means that shape.** A statement whose title is already on a board of the file updates that shape, there (the board the window shows first); any other title creates a new one. If two shapes on the board have it, in different frames say, it is `ambiguous_title`: name each by its path. The match is exact and case matters, so a typo like `"deploy"` for `"Deploy"` draws a second shape. The result warns about near misses, so read the warnings.
- **Two shapes may share a title in different containers; a path names each.** `"Cart" > "Checkout"` is the Checkout directly in the frame or subboard called Cart: the containers a shape is in, outermost first, then its title, joined by `>` (`"Plans" > "Sprint" > "Checkout"`; `#7C1E… > "Checkout"` for a container with no title; `board > "Checkout"` for one in no container, on the board the run draws on). A path stands wherever a title does. A shape statement named by one restates the shape there or makes it in that container, which must be on the board already. `in "X"` finds its title inside X first (else a loose one on X's board, which it moves in) and otherwise makes one there, so move a shape from one frame into another by its `#id` with `in`. `ambiguous_title` lists the shapes a title could mean, each by its path: write the one you mean, or its id. Messages name a shape by its path wherever its title isn't its alone. [reference/language.md](reference/language.md#paths) has the rules.
- **Title everything you draw and may touch again.** A later script names it by its title. A shape you draw without one can be named only by its id, which its row says (not a dry run's). The query `[title]` lists the titled shapes, with the board each is on ([Reading the board](#reading-the-board)).
- **A note's title is the pill above it; what it says is `text:`.** Give notes both. A subboard's title is on its card, and what it's for is its `description:`, which the user reads in its panel.
- **Keep titles short and specific** ("Auth service", not "Service"). Longer than 80 characters is kept but warned about. A generic title like "Notes" may already be on the board, and your statement would then change the user's shape, so dry-run first on any board you didn't just draw.
- **Shapes the user made are usually untitled.** A note's words are its text, not a title. A query finds them by what they say (`sticky-note:not([title])[text*="launch"]`), and its row gives the `id`. Name the shape by that id wherever a statement names a shape the file has: `edge "Checkout" -> #7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11 is: "In layer"`, `delete #7C1E…`, `sticky-note #7C1E… text: "…"` (it restates that shape), `right of #7C1E…`, `in #7C1E…`, `group #7C1E… and "Draft"`. Never write an id where a title would do, and not one you typed from memory: an id names a shape the file already has and never makes one (`unknown_id` if none has it, `not_an_id` if it is malformed), and only a shape a title could name, or a reference drawn by its query (an arrow's, or a reference's that stands for one shape, is `invalid_value`: name an arrow by its two ends, such a reference by the shape it stands for). To give an untitled shape a title, restate it by its id: `sticky-note #7C1E… title: "Layer one"`. [reference/relationships.md](reference/relationships.md) draws a relationship between two untitled notes this way.
- **A type is a note with a `schema:`**, called by its title as any note is: `sticky-note "Order" schema: "{\"type\": \"object\"}" text: "An order: its id"`. Its name is the note's title, never a `"title"` in its schema. A type is public, as any shape is, unless the user makes it private (`private:` is their call, as for any shape). Its color is its note's `color:`, which its schema says too, as `"$color": {"const": "blue"}` in its `properties`: the app keeps the two the same, so write either, and a `schema:` that says none keeps the color the type has. The notes of the type (and a relationship type's arrows) are drawn in that color unless they say a `color:` of their own; they hold none of it, so `[color]` doesn't find them and `:is-a("Order")` does. A type can carry rules in English that every note (or arrow) of it should meet, `"$rules": {"const": [{"says": "The description mentions no damage or wear."}]}` in its `properties`: write each as what should be true of the shape. A phrase of a rule can find shapes for it, a chip: `{"says": "Unusual for someone representing the member's district.", "find": [{"phrase": "the member's district", "query": "subboard:edge-from(:scope-start, arrow)"}]}`, the phrase written in the sentence word for word and the query stored, so it reads only the file and may use `:scope` (the shape being checked), and for an arrow `:scope-start` and `:scope-end` (where it starts and ends), which only a chip's query can: what the query finds for each shape is shown to the checker beside it. A chip whose query can't be read warns on its type, in the line `canvas draw` writes for it. The app checks a shape against the rules of every type it is, the most general type's first, a few seconds after the file is quiet, and warns of one a rule flags (`:warned`, its row's `problems` saying the rule); a `schema:` that says no `$rules` keeps the rules the type has.
- **A shape is an instance of a type by naming it in `is:`, by its title**: `sticky-note "Ann" is: "Person"`, on a note, a subboard, a frame or an edge (`edge "A" -> "B" is: "Friendship"`). Several are a JSON list, in the order added, a later one winning where two say the same: `is: ["Person", "Employee card"]`. A title is found as any title is, on any board of the file, or drawn by the same script, before or after; a shape that isn't a type is refused (`invalid_value`, "which isn't a type or a shape"), as is naming a type already built on the shape (a cycle). A type may be one of types itself. A relationship type is a type marked `relationship: true`; an arrow from a type into it and one out of it to a type are its ends, and an `edge` that writes `is:` its title is a relationship ([reference/relationships.md](reference/relationships.md)). The user adds one with `/is-a` on a line of the note's text or an arrow's label. `:is-a("Person")` finds the shapes that are a Person, however far (Ann, a card of Employee card, which is a Person); `:edge-to("Person", is-a)` only those that say so. `:incomplete` finds the shapes with a field their types need left empty, or a relationship row an end marks Needed with none, and `:invalid` those with a value that's wrong, or more than one relationship where a row allows one; each row they list says which field or row and why, in `problems`.
- **Only a note can be a type** (it has the `schema:`); a subboard or a frame can only be of one. Its chips show on the canvas and its values in the panel's Types tab: no rows are drawn for them. A subboard's `autofill` fills its fields from its `description:`; a frame has no words. A shape of a type can be an end of a relationship and fits by its types; a frame's arrows only join frames and subboards, so a relationship is never drawn between a note and a frame.
- **A shape's values are `fieldValues:`, a JSON object by field key** (a note's, a subboard's or a frame's), on one line: `sticky-note "Order 12" fieldValues: {"status": "paid", "shipping": {"city": "Leeds"}}`. A statement sets the members it names and keeps the rest, at any depth; a list is replaced whole; `null` clears a member (`{"status": null}`), and `fieldValues: null` all of them. A member no field names is kept and warned about. The result's row lists what the note still needs and what's wrong, in `problems`.
- **A note's `text:`, an edge's, and a subboard's `description:` can mention shapes by title.** `@[Owner]` in one is a mention of the shape called Owner: the note, the arrow's label, or the subboard's panel, shows a pill with that shape's name, live, and the app keeps the id, which you never write or see. The title is found as any title is, but on any board of the file: a shape the script draws (even further down it), else the one on the board the script draws on, else the one on the board the window shows, else the one anywhere else in the file. A title nobody has is refused (`unknown_title`, with the one like it), and so is one two shapes have in the first place that has any (`ambiguous_title`). A title in a text never moves the run to its board. Anything else in `text:` is kept as written: an `@` alone, or an `@[` with no `]` on its line, is just text. To write `@[` as text, write `\\@[` (a script's string spells a backslash twice). A query shows a text's mentions as they read, `@` and the name of what each mentions. A row is mentioned as a statement names it, `@["orders".customer_id]` ([reference/language.md](reference/language.md#a-text-that-mentions-shapes)).

## Writing

One statement per line. `//` starts a comment anywhere outside quotes. Blank lines and indentation don't matter. A statement is a kind, an optional quoted title, then attributes (`key: value`) and placements in any order.

```text
<kind> ["<title>"] { attribute | placement }    make a shape, or update the one with that title
edge "<a>" -> "<b>" { attribute }                connect two shapes (also <- and <->)
delete "<title>"                                 remove a shape and every edge on it
delete edge "<a>" -> "<b>" [is: "<type>"]        remove the edges from a to b (with is:, only those of that type)
group "<a>" and "<b>" { and "<c>" }              put those shapes in one group (two or more)
ungroup "<a>" { and "<b>" }                      take those shapes out of their groups
style <name> attribute { attribute }             a named set of attributes, for this script
```

### Shapes and attributes

Every kind's size, smallest size, attributes (and what each takes), edge channels by side and the pills that can stand for it are in [reference/kinds.md](reference/kinds.md), written from `canvas kinds` (run that for the live answer). A statement may carry those attributes, and `size`, `gap`, `overlap`, `style` and `title` besides. What that page doesn't say:

- A note grows with its text: it is as tall as its text, and a `size:` height is the least it is instead, kept as the user types, so text is never cut off; a width alone, `size: 320x`, keeps it as tall as its text at that width. A note that is a type, or is one, keeps its width and is as tall as its words and a row for each field, and `at` reports that size.
- `text` and `description` mention shapes by title, `@[Title]`. A `schema` (a JSON Schema, as text) makes a note a type; `is` and `fieldValues` make a note, subboard or frame one of types, and `autofill: false` stops the app filling its fields from its words; what they do is in [reference/language.md](reference/language.md#a-kinds-attributes).
- `locked` on a subboard, a frame or a database locks what is on or in it; `private` is the user's call.

Arrows are what edges are; you don't draw one on its own. An edge takes the arrow's attributes beside `from:`, `to:` and `channel:`: `text:` (what it says, set on its line; it mentions shapes by title as a note's text does, `@[Title]`), `labelPosition:` (where along it, `0` to `1`, halfway by default), `bend:`, `is:` (the types it is, as a note's), `fieldValues:` (what it holds for its types' fields, as a note's), `endRule:` (on an arrow between a type and a relationship type: `endRule: {"needed": true, "onlyOne": true}`, set member by member), `color:` (its line, heads and label) and `locked:`; its heads are its arrow's (`->`, `<->`). A color is one of the named colors (`gray`, `red`, `orange`, `yellow`, `green`, `teal`, `blue`, `indigo`, `purple`, `pink`, or one the file added) or a quoted hex value (`color: "#4465E9"`); a name the file doesn't have is `invalid_value`, with the names it has, and `color: null` takes a shape's color away. Values: text is quoted (`text: "Two words"`). `true` and `false` are bare words (`locked: true`). `null` puts a property back to its default (but not a title: `title:` only renames). `size: 300x200` is in world units, up to 100000. A width alone, `size: 300x`, leaves the height to the kind: a note as tall as its text at that width, any other kind as tall as it was, or as its tool draws it if it's new. A value past a bound, like a title over 80 characters, is kept and warned about.

A subboard is a card that holds a board of its own. `in "Payments"` draws a shape on its board, without opening it; `inside "Payments" top-left` puts a shape over its card instead. Draw the subboard first, then what goes in it in a run of its own. Deleting it deletes everything on its board too (the result warns how much). A locked one takes nothing new, and what's on its board, and on every board under it, refuses changes (`read_only`). A type is a note with a `schema:`: its `text:` says what the type holds, in words, and its `schema:` says it as JSON inside a quoted string, so escape each quote: `schema: "{\"type\": \"object\", \"properties\": {\"id\": {\"type\": \"string\"}}}"`; the user sees it in the note's panel, its Schema tab. Its name is the note's title, so its schema has no `"title"`. Give a type both. What you write on one is taken as written: the Claude sync that rewrites one side when the user edits the other isn't asked, so write text and a schema that agree. A type refers to another type twice, in words and in its schema, and you write both: its `text:` mentions it by its title, `@[Address]` (a mention of a type is a reference to it; a mention of any other shape is only words), and its `schema:` points to it with `{\"$ref\": \"urn:uuid:<id, lowercase>\"}` where that field goes, the id being the type's, from `canvas query`'s rows. Only the `$ref` takes an id. `sticky-note[schema]` finds the types.

```draw
sticky-note "Ship v1" below "API" text: "Cut the release once @[API] and @[DB] agree"
```

A subboard or a frame can be of a type. A type is still a note, so make it first; the card and the frame then say `is:` and `fieldValues:`, and their values are in the panel's Types tab (nothing is drawn for them on the canvas):

```draw
sticky-note "Service" below board schema: "{\"type\": \"object\", \"properties\": {\"owner\": {\"type\": \"string\"}}}" text: "A service: who owns it"
subboard "Payments" below "Service" is: "Service" fieldValues: {"owner": "Ann"}
frame "Billing" right of "Payments" size: 400x240 is: "Service" fieldValues: {"owner": "Bo"}
```

A frame is a region of the board that holds shapes: what's in it moves with it and is locked with it, and deleting the frame leaves what's in it where it is. `in "Sprint 3"` puts a shape in it, 40 in from its edges: with no other placement, against its top-left, and several written alike in a list down from there; with placements, where they say, kept within it: one that would cross the frame's edge only on the axis its placement leaves free (taller than the shape it's `right of` or `left of`, wider than the one it's `above` or `below`) slides along it until it's inside, with a warning, and the script fails with `no_room` only when it can't fit or the placement itself puts it outside. A frame doesn't grow, so give it a `size:` with room for what goes in it (a frame has a smallest size, [reference/kinds.md](reference/kinds.md)), and draw it first: `in` a frame the same script draws is `unsupported`. Nothing sits across a frame's edge: whatever a script puts down over one goes wholly in or out by most of its area, nudged, and a warning says which (`"Draft" was over the edge of "Sprint 3", so it was nudged in`). So a shape placed `inside` a frame, `on` it, or against a shape in it, that lands within it, is in it too. A statement with `in` finds its own title inside that frame first (a shape of that title lying loose on the board is moved in, and one in another frame is left there), so `sticky-note "Router" in "Sprint 4"` makes a second Router when the first is in Sprint 3, and the titles it places against are found inside the frame first too.

```draw
frame "Sprint 3" right of "DB" size: 900x600
```

```draw
sticky-note "Fix the login" in "Sprint 3" text: "Sessions expire too soon"
sticky-note "Move billing" in "Sprint 3" text: "Invoices go to the new API"
sticky-note "Index search" in "Sprint 3" right of "Fix the login" text: "Search the archive too"
```

A database's tables are the engineering kit's kinds: a `table` takes its `columns:` as lines in quotes, a column a line (`name type [null] [unique] [default …] [pk]`, `\n` between them), an `enum-type` its `values:` a value a line, and a `database` holds them as a frame does. A statement joins its lines onto what the shape holds by name, so it names only what it changes. A row is named with a dot outside the quotes: a key is `edge "orders".customer_id -> "customers".id` (on `foreign-key`), or `→ customers.id` at the end of the column's line, which draws that edge; `delete edge "orders".customer_id -> "customers".id` takes that key alone, and `delete "orders".note` a column and its keys. A query finds the table or the API that holds a row: `table[columns.name="email"]`, `:route("POST /orders/{id}/refunds")`, and an arrow's row names the column or endpoint at each end (`"row"`). [reference/engineering.md](reference/engineering.md) has the rest.

```draw
table "accounts" below "Sprint 3" columns: "id uuid pk\nemail text unique\ncreated_at timestamptz?"
```

An `api` is the kit's REST API: `server:` its first line (`host[/path] [bearer]`), `endpoints:` its rows as lines, `METHOD /whole/path/{param} [(Body)] [→ [status] [Response]]`, a path alone a header that the endpoints under it are grouped by (each goes under the longest header its path starts with), joined by method and whole path. A body or a response names a type note by its title, a pill and never an arrow. An endpoint `writes` or `reads` a table and `calls` an endpoint, each an arrow from its row on that channel: `edge "orders API"."POST /orders/{id}/refunds" -> "refunds" channel: writes`. An API or an endpoint marked `deprecated` is retired (a person's New Version leaves the old one so and puts `… v2` beside it), and an `endpoint` is one endpoint a person took out of an API, standing alone; no statement draws one.

```draw
api "accounts API" below "accounts" server: "api.shop.dev/v1 bearer" endpoints: "/accounts\nGET /accounts/{id} → Account\nPOST /accounts (NewAccount) → 201 Account"
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

`board` (unquoted) is the box around every shape the script doesn't move, `view` is the part of the board in the window, and `origin` is the board's (0, 0), for a layout worked out elsewhere. So a column on the right is `right of board`, the space under everything is `below board`, and a legend in a corner is `inside view top-right`. Shapes whose placements are written identically form a list: they stack down the page in script order, 64 apart, and are placed as one. A later script's `right of board` won't join this column but goes right of the whole board again, so to add to a list, restate every member.

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

`<-` is the same edge written the other way round, and `<->` has heads at both ends. `from:` and `to:` name the side each end leaves or arrives on; without them the line runs center to center. An edge statement means "A is connected to B", so written again it updates that edge (`reconnected`) or leaves it alone (`unchanged`), and never draws a second one. The exception is `is:`: two edges between the same two shapes of different types are two arrows, and `edge "A" -> "B" is: "Friendship"` and `edge "A" -> "B" is: "Mentorship"` each find their own (written again, both are `unchanged`). With two arrows between a pair, an `edge` that doesn't write `is:` is `ambiguous_edge`; say which with `is:`, and take one away with `delete edge "A" -> "B" is: "Friendship"`.

An edge travels on a channel that both ends take: notes connect to notes (`note-link`), frames to frames (`frame-link`), and subboards to anything that has channels, a note on its channel, a frame on its, and another subboard on `subboard-link` (Design, Build and Launch above). The edge picks the channel both ends share, and if they share none it's refused. `channel: none` draws a plain arrow between any two shapes, a note and a frame among them. No edge joins a frame and a shape in it, on any channel or none (`cannot_connect`): what it holds is in it already.

```draw-error
// reason: no_channel
edge "Ship v1" -> "Sprint 3"
```

```draw
edge "Ship v1" -> "Sprint 3" channel: none
```

An arrow can't leave its board, so an edge to a shape on another board goes into a **reference**: a pill that stands for the shape, which the run puts beside the shape on this board. `edge "Checkout" -> "Auth"`, with Auth on a subboard's board, draws a reference to Auth right of Checkout and the arrow into it, and the row says `via: "reference"`. A reference says over its name where its shape is (the frames and boards it is inside that the reference isn't), always, and is as wide as that. The references beside a shape stack in a column of their own, 16 clear of each other, and a later run's join the column there. An edge from a row (a column's key, an endpoint's `calls`) puts its reference where the arrow from the row reads clean: below the row's shape, else right or left of it level with the row (a key, row to row, level with its row first, left then right, then below clear of the row's end), never with the line through another shape; where nowhere is, as above. `delete edge "Checkout" -> "Auth"`, or `delete "Checkout"`, takes the reference with the arrow, once no other arrow is on it. Only a public shape can be stood for, every shape is until the user makes it private, and making one public again is their call: for a private one the script is refused (`several_boards`) and you ask. `canvas kinds` says which pills can stand for a kind, and what they need of the shape first, as its `via` (`[{"kind": "reference", "needs": "public"}]`). `via: reference` asks for a reference on one board too, for a shape that other edges point at, and `share: true` (or `share: "Checkout"`, for the one beside Checkout) draws an edge into a reference to the same end that's there already, rather than make another. An edge may also say where its reference goes, in a shape's placements and `in` (`via: reference in "Sprint" right of "Sprint" left (gap: 600) below "Sprint" top (gap: 40)`). [reference/language.md](reference/language.md#through-a-reference) has the rest.

A reference drawn on a statement of its own stands for what its query finds among the public shapes: `reference right of "Checkout" query: "sticky-note" all: true`. It has no title, so a later script names it by the `id` its `created` row gives: `edge "Checkout" -> #7C1E…` draws an arrow into it, which everything that reads the file reads as an arrow into each shape it finds; `reference #7C1E… query: "…"` changes what it asks, and `delete #7C1E…` takes it. `canvas query ':edge-from(#7C1E…, stands-for)'` says what it stands for now, waiting for the app to find it ([reference/language.md](reference/language.md#references)).

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

`group` puts shapes in one group: in the app a click on any of them selects them all. A group has no name or title; name the two or more shapes in it, joined by `and`, all on one board, since a group is its shapes on one board. A group is exactly the shapes you name: each leaves the groups it was in, and the others stay a group only while two or more of them are left. `ungroup` takes each shape it names out of its groups. A script names a shape once in these, and may name shapes it draws. A row says `grouped`, `ungrouped` or `unchanged` (a group already as asked changes nothing), with the `shapes` it named.

```draw
sticky-note "Mockups" below board text: "Three options for the sign-up screen"
sticky-note "Copy" right of "Mockups" text: "Headline and button labels"
group "Mockups" and "Copy"
```

## A complete example

These are real shipped kinds; `canvas kinds` says what your app has. Only "Sign-up form" is unplaced, so the whole drawing goes as near the middle of the window as it can while keeping clear of what's there. On a full board that can be outside the window: the rows say `inView: false`, and `--reveal` brings the drawing into view.

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

This is how you read a board: before drawing on one you didn't just draw, to learn the titles already there, and after, to check what's connected to what. To see how it looks, take a picture ([Looking at the board](#looking-at-the-board)). `canvas query` takes a query, a selector as CSS writes one, and lists every shape of the file that matches, on every board, in file order. It changes nothing. Pass the query through a heredoc with a quoted delimiter, as you pass a script: queries are full of `"`, `*`, `>`, `[` and `#`, which the shell mangles.

```bash
canvas query --board 2 - <<'EOF'
sticky-note:edge-to("Auth service")
EOF
```

```json
{"board": {"id": 2, "name": "Sign-up", "shows": "root", "showsPath": ["root"]}, "query": "sticky-note:edge-to(\"Auth service\")", "count": 1,
 "rows": [{"id": "7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11", "kind": "sticky-note", "title": "Sign-up form", "board": "root",
           "properties": {"text": "Email and password"}}]}
```

- **A row is a shape**: its `id`, `kind`, `title` (none when it's untitled), `board` (`"root"`, or the id of the subboard whose board it's on), `inside` (the names of the subboards and frames it's inside, outermost first), `at` (where it is, `[[x, y], [width, height]]`, as a draw's row says) and its attributes, `properties`, text as a person reads it. An arrow's row says where it runs, in `connection`, and has no `at`. A row of `:invalid` or `:incomplete` adds `problems`: each field, where in it, and why.
- **An id names that shape in a later query**, `#7C1E2A04-…`, since titles can repeat. `draw` names a shape by its title, and by its id only when it has none ([Titles are names](#titles-are-names)).
- **A yes-or-no question is a query that matches the shape it asks about, or nothing**: `count` is 1 or 0, and `canvas` exits 0 either way. A title no shape has is refused (`unknown_title`, with the one like it), so a no always means no.
- **`--count`** returns only how many; **`--brief`** leaves each row's attributes out; **`--fields text`** lists only that attribute, whole (long text is otherwise cut at 500 characters); **`--limit 500`** lists up to 500 rows (100 unless it says).
- **A space means inside**: `"Payments" sticky-note` is the notes inside the subboard Payments, on its board or a board inside it, and `"Sprint 3" sticky-note` the notes in the frame Sprint 3, at any depth. So never put a space before a test: `sticky-note:mentions("API")`, not `sticky-note :mentions("API")`, which is refused (`stray_space`). Inside is always a subboard's board or a frame, never `draw`'s `inside`, a shape drawn over another (though one drawn over a frame is in it: nothing sits across a frame's edge).
- **When the person asked in English**, `--ask "their question"` has the app write the query (with the Claude key they saved in Settings), runs it, and says what it wrote, in `query`: check it asks what they meant. Otherwise write the query yourself; [query-prompt.md](query-prompt.md) is what the app tells Claude to write one.

A kind is every shape of that kind, a title in double quotes is the shape called that (right after a kind, with no space, the shapes of that kind called that: `sticky-note"Queue"`), and tests follow with no space: `[text*="email" i]` for text (`i`: in any case), `[title=""]` for no title, `:edge-to(…)` and `:edge-from(…)` for what an edge runs to and from, `:connected-to(…)` for either, `:downstream-of(…)` for what's reached by following edges, `:grouped-with(…)` for what's grouped with a shape (a click on it selects them together), and more ([reference/query.md](reference/query.md)). On what this page drew, the notes whose title or text has "email" in it:

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

A relationship is an arrow of a relationship type, so it is read by the arrow's type, never by an edge word's second argument (a title in quotes after a comma is not an edge type): `arrow:is-a("Employment")` is the relationships of a type, `:end-of(arrow:is-a("Employment"):starts-at("Ann"))` where Ann works, and `arrow:misfit` those whose ends don't fit ([reference/relationships.md](reference/relationships.md), [reference/query.md](reference/query.md)).

### One question of many shapes

`canvas decide '<query>' "<question>"` asks the app's decision model a yes-or-no question about each shape a query finds, each on its own and with what is around it (its types and their words, where it is, what's beside it, its edges), and lists them with how likely each is a yes, highest first: `rows` of `id`, `title` and `yes`, with `count` and the `model` that answered. Use it for a judgment a query can't make, over many shapes at once: which listings say what work was done, which tasks look blocked. It stores nothing and nothing on the board changes, so the user sees none of it; a check the user should keep seeing belongs in a rule on the type (`$rules`, above). It asks at most `--limit` shapes (50; up to 500), the first the query finds, and warns when there were more. Without a TypeSafe key it is refused (`no_key`): ask the user to save one in Settings.

```
canvas decide --board 2 ':is-a("Listing")' "Does the seller say what work was done on the car?"
```

## Looking at the board

`canvas capture` takes a picture of a board as the app draws it, in a PNG file you then open and look at: whether notes overlap or cut their text off, where arrows run, whether the layout reads. It's drawn apart from the window, so the user's view doesn't move and nothing on the board changes.

```bash
canvas capture --board 2 /tmp/board.png                                    # the whole board the window shows
canvas capture --board 2 /tmp/auth.png --shape "Auth service"              # fitted to one shape, with what's around it
canvas capture --board 2 /tmp/auth.png --shape "Auth service" --zoom 100   # at actual size, centered on it
canvas capture --board 2 /tmp/payments.png --in "Payments"                 # the board a subboard holds
```

```json
{"board": {"id": 2, "name": "Sign-up", "shows": "root", "showsPath": ["root"]}, "file": "/tmp/board.png",
 "width": 1600, "height": 936, "zoom": 41.5, "region": [[-118, -78], [3856, 2256]]}
```

- **The file** is any path; one that doesn't end in `.png` gets it, and one that's there is replaced. `--shape` takes a shape's name as a script writes it, once for each shape to fit: a bare title, or `"Cart" > "Checkout"` (a path, quoted), `#<id>` for a shape with none. The board pictured is theirs, else the one `--in "<subboard>"` (a title, a path or an id) or `--root` names, else the one the window shows. `canvas show` takes the same names.
- **How big**: the whole board as it is at 100%, at most 1600 × 1200 points; shapes, or a `--zoom`, in 1200 × 800 points. `--size 1600,1000` sets it, `--scale 2` doubles the pixels (to read small text), `--dark` draws the dark appearance.
- **`region`** is the part of the board in the picture, `[[x, y], [width, height]]`, in the units of a draw's `at`: a shape whose `at` is `[[x, y], …]` is at (x − region's x) × zoom / 100 points from the picture's left, and likewise down.
- **Zoomed out, words aren't drawn.** Below 35% shapes are skeletons, with no text, and the result warns: picture fewer shapes (`--shape`), or zoom in.

## Drawing again: a drawing, and what changed since

A run can join a drawing, so a later pass knows what it drew and what the person changed since. `--drawing NAME` keeps every shape the run's statements name, and every arrow it draws, in the file's record of that drawing, with what each now is: its attributes and its place. Nothing is kept on the shapes, so nothing shows on the board.

```bash
canvas draw --board 2 --drawing "Sign-up plan" - <<'EOF'
sticky-note "Sign-up form" text: "Email and password"
EOF
```

Before the next pass, ask what the person changed. `:drawn-by("NAME")` finds the drawing's shapes (each row's `key` is its key in the drawing, its id for what a run drew); the answer's `absent` lists what the drawing made that the file no longer holds (each `id` and `key`: a shape the person deleted). `:changed("NAME")` finds those of its shapes that differ from what that drawing last wrote, each row with its `key` and `in` too; its `changed` says how: `moved`, `resized`, `frame` (in another frame now), or the attributes that differ (`text`, `color`).

```bash
canvas query --board 2 - <<'EOF'
:changed("Sign-up plan")
EOF
```

- **Nothing the person changed is locked.** Keep their change unless you have a reason to change it again; then say so. A restatement with a placement moves a shape they moved.
- **Draw the next pass with the same `--drawing`**: what it writes is the drawing's new record, so the next question is about changes since then.
- **A program that rebuilds its whole picture** (a tool laying out a graph) draws it with `canvas apply`, by keys of its own, every board in one step: canvas-digest does ([Reference](#reference)).

## What will bite you

**Habits from other languages**: bare or curly-quoted titles, `node`, `note` or `box` for a kind (the hint lists the kinds, and names the one like it), `link` for an edge, `-->` or a bare `"A" -> "B"`, `#` for a comment (comments are `//`), a quoted label after an edge (write `text: "…"`), coordinates (`x:`, `at:`). Each is refused, most with a hint naming what to write instead, and every unreadable line comes back in one pass:

```draw-error
// reason: syntax
sticky-note Web right of "API"
edge "Web" --> "API"
# Services
```

**Inventing attributes** (`color: red`, `label:`, `owner:`). Every key is checked against the kind, so look in `canvas kinds` first.

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
- **Two unplaced shapes.** Only one per script may say nothing about where it goes; place the rest against it. And there are no coordinates as attributes (`x:`, `at:`): if a shape is in the wrong place, give it another placement. A layout worked out elsewhere goes in as offsets from the board's `origin`, its (0, 0) ([An exact offset](reference/language.md#an-exact-offset)).
- **Re-running a whole layout script to add one line.** Its placements run again and snap back anything the user has moved since, and its untitled shapes are drawn a second time. Write only the new statements. To change attributes without moving a shape, restate it without placements.
- **An edge to a shape on another board** goes through a reference unless that shape is private. If it is, the script is refused (`several_boards`, and its hint says why): don't make the shape public to get past it, ask the user, or split the script into a run for each board. Making a shape private, or a private one public, is the user's call, and a script never does either unasked.
- **A relationship that doesn't fit is drawn, and said.** `edge "Ann" -> "Bo" is: "Employment"` with Bo not a Company draws the arrow and answers `problems` on its row and an error warning; nothing is refused. `canvas query 'arrow:misfit'` lists those on the board, and `arrow:misfit:invalid` says why. A plain arrow between two notes names, in `fits`, the relationship types that would take it; the type is yours to write (`is:`), `canvas draw` never picks one ([reference/relationships.md](reference/relationships.md)).
- **Edges across channels**, and **shapes the user locked**, which refuse changes (`read_only`), as does everything in a locked frame or on a locked subboard's board. Connect like to like (or to a subboard) or say `channel: none`; tell the user about a locked shape rather than unlocking it.
- **A frame and what goes in it in one script.** `in` a frame the same script draws is refused (`unsupported`): draw the frame, then what goes in it in a run of its own.

## Honest limits

- **A query can't ask where shapes are.** Each row says where its shape is (`at`), but a query knows only what's inside what (a subboard's board, a frame) and what's connected to what: what's left of what, or drawn within a rectangle, it can't ask.
- **Typing may still change.** A note the user is typing into reads as typed so far, and the query's result warns that it may still change (`editing`).
- **Some shapes aren't in any answer**: shapes the app keeps aside (a kind this app doesn't have), and those on boards it can't show.
- **Placement happens once.** The board doesn't remember `right of "API"`. When the user moves API, nothing follows it (but what's in a frame moves with the frame).
- **Frames don't grow.** A frame stays the size it was drawn, so `in` one that's full is `no_room`: restate it with a bigger `size:`.
- **The result confirms intent, not the picture.** It tells you where each shape landed and what was pushed. It doesn't tell you how a note's text wraps (a note grows to fit its text, past any height `size:` gave it, so a note with long text grows tall: give it a width, `size: 320x`) or whether a line crosses other shapes: a picture does ([Looking at the board](#looking-at-the-board)).
- **Edges are arcs.** They don't route around shapes. Only closed shapes are kept clear, so a shape can land across an arrow or a drawn line.
- **Pills overlap when zoomed out.** A title's pill (and a lock's chip, in the same row just above a shape) clears the shape above it in a list down to about 42% zoom (below 35% shapes are skeletons: no pill or chip is drawn, and a title is said on the shape instead; a frame's title is a tab on its top edge, at every zoom).
- **One board per run.** A run draws on one board (`in` says which, and the window never moves), and an arrow can't leave it: an edge to a shape on another board is drawn into a reference to that shape, which only a public one (any but a private one) can have.

## Reference

[reference/language.md](reference/language.md) is the full `draw` language: every construct, the gap and part tables, how lists, pushes and the unplaced drawing are worked out, edges and channels, every error reason with its fix (the command line's own and the boards' too), what the language refuses and why, and what isn't built yet. Read it when you need a construct this page doesn't cover, or when an error points at behavior you didn't expect. `canvas help draw` is the command's own help.

`canvas measure -` takes a script on standard input and says how big each of its shapes would be, how wide a reference to a shape is and what the placement constants are, without drawing or changing anything: on its own, or with the types of the board in front (or `--board`'s): for a tool that lays a script out before it writes it ([reference/language.md](reference/language.md#measuring-a-script)).

For a large body of connected information (a codebase, an org, research notes, a plan: dozens to hundreds of shapes and the links between them), don't write the script by hand: [canvas-digest](../canvas-digest/SKILL.md) takes a graph document (the things by keys of its own, what holds what and what points at what), measures it with `canvas measure`, decides where everything goes and which hubs get reference pills, and draws it with `canvas apply`: the whole document by key, on every board, in one step, as a drawing a later pass updates in place. `canvas help apply` says what a document is.

[reference/query.md](reference/query.md) is the whole query language, on a story file: naming shapes, attributes, inside, edges and their direction, the plugins' words, yes-or-no questions, `--ask`, and every refusal with its fix. [query-prompt.md](query-prompt.md) is what the app tells Claude for `--ask`, word for word, with how to give yourself what it's given. `canvas help query` is the command's own help, and `canvas query-vocabulary` what this app's queries can name: its kinds and their attributes, its edge types and its words.

[reference/engineering.md](reference/engineering.md) is how a database's tables, their enums and the databases that hold them are written, and an API's server and endpoints: a column, a value or an endpoint a line, joined by name.

[reference/relationships.md](reference/relationships.md) is how a relationship is written and read: a relationship type and its ends, two notes related with values, what a row says of an arrow (`is`, `endOf`, `fits`, `relates`), a misfit, drawing one again and the queries that say what a note is related to. [reference/references.md](reference/references.md) is what a reference does to what you read: a pill that stands for a public shape, so an arrow into it is an arrow into the shape, and how a row says it (`via`, `more`), what it stands for (`stands-for`), and what a script can make of one (an edge to a shape on another board, or a pill drawn by its query and named by its id).

The language and its solver are modified from [reladraw](https://github.com/reladraw/reladraw) (Apache-2.0; see THIRD_PARTY_NOTICES.md). This language isn't called that.

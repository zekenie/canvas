# The canvas draw language

The whole language `canvas draw` reads: every statement, word and rule, how a script's placements become positions, what comes back, and every way a script can fail. [../SKILL.md](../SKILL.md) is the tour; this page is where to look when you need a construct the tour doesn't cover, or when an error points at behavior you didn't expect.

The examples on this page are one story. They run in order on one empty board: each block tagged `draw` succeeds there, and later blocks name shapes that earlier blocks drew. Each block tagged `draw-error` fails with the reason on its first line, and changes nothing. The shapes are the kinds that shipped when this was written. `canvas kinds` says what your app has.

## Contents

- [Running a script](#running-a-script)
- [Lines and words](#lines-and-words)
- [Statements](#statements)
- [Shapes and titles](#shapes-and-titles)
- [Attributes](#attributes)
- [Placements](#placements)
- [Which board](#which-board)
- [How placements combine](#how-placements-combine)
- [Gaps](#gaps)
- [Lists](#lists)
- [Keeping clear](#keeping-clear)
- [A drawing with nothing to hang on](#a-drawing-with-nothing-to-hang-on)
- [Inside, outside, on, and zones](#inside-outside-on-and-zones)
- [Frames](#frames)
- [Edges](#edges)
- [Styles](#styles)
- [Restating, renaming, deleting](#restating-renaming-deleting)
- [Groups](#groups)
- [References](#references)
- [How a run is applied](#how-a-run-is-applied)
- [The result](#the-result)
- [Measuring a script](#measuring-a-script)
- [Errors](#errors)
- [What canvas kinds says](#what-canvas-kinds-says)
- [What the language refuses](#what-the-language-refuses)
- [Not built yet](#not-built-yet)

## Running a script

```bash
canvas draw --board 2 --dry-run - <<'EOF'
sticky-note "Inbox" text: "Everything new lands here"
EOF
```

`canvas draw <script>|- [--dry-run] [--reveal] [--board <board>]`

- **The script**: `-` reads it from standard input. Use a heredoc with a quoted delimiter (`<<'EOF'`), which passes every character through untouched. With an unquoted delimiter the shell expands `$` and backticks and turns `\\` into `\`. The script can also be the one argument, but quoting it for the shell is error-prone, and an apostrophe in a title breaks it.
- **`--dry-run`** does everything a run does (reading, placing, checking and building the result) and then throws the change away. On the same board, a dry run and a real run say the same, unless the user is typing in a shape the script changes: a real run ends their typing first, so what they typed is part of the shape it changes.
- **`--reveal`** eases the camera to fit everything the script made or changed. Without it the camera stays where the user left it.
- **`--board <board>`** names the board by the id `canvas boards` gives it (which lasts while that board is open), by its file, or by its name. Without it the script goes to the board in front, which changes whenever the user clicks another window, so pass it on every `draw`. `kinds`, `status`, `boards` and `new` are about the app, and take none.
- **A file's boards.** `--board` names a file, and a file can hold boards inside shapes (a subboard's). A script draws on one of them, and never says which: it's the board the shapes it names are on ([Which board](#which-board)), else the one the file's window shows. The window doesn't move. `canvas boards` says what the window shows, as `shows` (`"root"`, or the id of the shape that owns it) and `showsPath` (from the root down), and every result's `on` says where the script drew. To move the window, `canvas show "<subboard title>"`, or `canvas show --root`.
- Options can come before or after `draw`. `canvas`'s own options work too: `--format json|text`, and `--timeout <seconds>` (default 10).

The result goes to standard output: JSON when standard output isn't a terminal (so always, from an agent's shell), and text for a person at a terminal. An error goes to standard error. The exit status is 0 when the script was drawn, 1 when the app refused it (read the error), 2 when the command line itself is wrong (standard input that can't be read, or isn't UTF-8, included), and 3 when the app couldn't be reached (`not_running`, `unreachable`, `protocol_mismatch`) or didn't answer in time (`timed_out`).

After a timeout the app may still draw the script: it doesn't drop what it was sent. Don't run it again to find out. Dry-run it instead:

- a titled shape or an edge whose row says `unchanged` landed;
- a `delete "X"` that now fails with `unknown_title`, or a `delete edge` with `nothing_to_delete`, already ran;
- a rename that already ran finds no shape with the old title, so the statement makes a new shape and fails (`unsupported`: `"Old" is new, and title: renames a shape`), while the new title is on the board;
- an untitled shape always comes back `created`, landed or not. Title every shape in a script you might have to check.

`canvas help draw` prints the command's own help.

## Lines and words

- **One statement a line.** There are no blocks and no continuations. Blank lines and indentation are ignored, and Windows line endings are fine.
- **`//` starts a comment**, at the start of a line or after a statement, anywhere outside a quoted string or a JSON value. `#` is an ordinary character, not a comment. `# Heading` is read as a statement, and it fails. A word that starts with `#` where a statement names a shape is an id ([Titles are the names](#titles-are-the-names)).
- **Quoted strings** are in straight double quotes and end on the same line. Inside them, `\"` is a quote, `\\` a backslash, `\n` a new line and `\t` a tab. Any other backslash is refused. Curly quotes (“ ” ‘ ’) and single quotes are refused, with the straight-quoted spelling in the message. An apostrophe inside double quotes is just a character: `"the day's files"`.
- **A bare word** runs to the next space, `"`, `(`, `)` or `//`. A comma at its end is a separator of its own.
- **A key** is a bare word ending in a colon, like `text:`. Only a key opens an attribute, and it needs a space after the colon: `size:200x100` is refused, with `size: 200x100` as the fix.
- **A JSON value** is a value, right after a key, that starts with `[` or `{`. It runs to its matching bracket, skipping over JSON strings, and must close on the same line.
- **`(` and `)`** hold a placement's gap. **`,` and `and`** join the shapes a placement or a `group` names, and the styles a shape takes.
- **A value with spaces is quoted.** `text: hello world` is refused, and the fix is `text: "hello world"`. Quote any text value to be safe.

This first script puts a legend in the corner of the window, then draws a small pipeline in the middle of it:

```draw
// A legend in the top-right corner of the window: view is the part of the board you can see.
sticky-note "Legend" inside view top-right text: "Notes are steps; subboards hold the work"

// Ingest says nothing about where it goes, so the pipeline lands in the window, clear of the legend.
sticky-note "Ingest" text: "Pull the day's files"   // a comment after a statement
sticky-note "Clean" right of "Ingest" text: "Drop the bad rows"
sticky-note "Load" right of "Clean" text: "Write to the warehouse"
```

## Statements

```text
<kind> ["<title>" | #<id>] { attribute | placement }   a shape: make it, or update the one with that title (or id)
edge <a> -> <b> { attribute }                    a connection from a to b (also <- and <->); each end a "<title>" or an #<id>
delete "<title>" | #<id>                         remove a shape, and every connection with an end on it
delete edge <a> -> <b> [is: "<type>"]            remove the connections from a to b (<-> either way; with is:, only those of that type)
group <a> and <b> { and <c> }                    put those shapes in one group (two or more); each a "<title>" or an #<id>
ungroup <a> { and <b> }                          take those shapes out of every group (one or more)
style <name> attribute { attribute }             a named set of attributes, for this script
```

The first word decides the statement. `edge`, `delete`, `group`, `ungroup` and `style` are the language's own words. Any other first word is a kind. After a shape's kind and title, attributes and placements come in any order: `sticky-note "A" text: "Hi" below "B"` and `sticky-note "A" below "B" text: "Hi"` are the same statement.

## Shapes and titles

### Kinds

A kind is drawable when a tool places it. These are the shipped ones:

| kind | size | named by | what it says | edges |
|---|---|---|---|---|
| `sticky-note` | 200x200 | its title, a pill above its top-left corner | `text:`; a type's `schema:` in its panel | `note-link`, all four sides |
| `subboard` | 240x160 | its title, drawn on its card | `description:`, what it's for, in its panel; its board is its own | every channel (`subboard-link`, `note-link`), all four sides |
| `frame` | 640x400 | its title, a pill above its top-left corner | nothing else: it holds what's drawn `in` it | none |
| `reference` | 120x32 | nothing: it has no title, so a script can't name one (an edge to a shape on another board draws one, [Through a reference](#through-a-reference)) | `query:`, a query in the query language; `all:` | none |

`arrow` is what edges are: write `edge "A" -> "B"`, never `arrow`. A kind that isn't installed is `unknown_kind`, with the drawable kinds listed and the one like it named (`did you mean sticky-note?`). Words from other languages get a hint with what to write instead: `node`, `note` and `box` that a statement starts with its kind, `link` to write `edge "A" -> "B"`, `-->` in an edge the arrow to write, and a line that joins two titles without `edge` (`API --> DB`, `"A" -> "B"`) the edge it means (`edge "API" -> "DB"`).

### Titles are the names

A shape is referred to by its title. An id is for a shape that has none. Everywhere a statement names a shape the file already has, a quoted title may be written as an id instead, in the spelling a query uses: `#7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11`, a `#` and 36 characters, no quotes. The places are an edge's ends, `delete` and `delete edge`, a placement's target (`right of #…`), `in #…`, a shape statement's own name (`sticky-note #… text: "…"`, which restates that shape), the shapes a `group` or `ungroup` names and `share:`'s host. A query's rows give the ids (`id`), and so do a run's, for every shape the file has. Write one only for a shape with no title; where it has a title, use it. A shape named by its id and by its title in one script is one shape (two statements about it are `duplicate`).

- **An id names a shape the file already has, never makes one.** One no shape has is `unknown_id` (it may have been deleted: run the query again), a malformed one `not_an_id`; a shape on a board the app can't show, or kept aside, is `unknown_id` too. The statement is refused at its line and nothing is drawn.
- **An id names only a shape a title could name**: an arrow's, a reference's and any other kind's that has no title are `invalid_value`. Name an arrow by its two ends, and a reference by the shape it stands for.
- **It is found as a title is**: on the board the run draws on, or on any other board the app can show. A run draws on the board of what it names, as for a title; an edge's end on another board goes through a reference as a titled one does, and the reference is called what the shape is called where it has no title (its words, else its values).
- **A shape the script deletes can't be named by id after it**, as a title can't (`unknown_id`, "which this script deletes").

- **A title is always quoted.** It's folded as the app folds titles: runs of spaces and new lines become one space, and the ends are trimmed. A title that folds to nothing is refused; leave it out for an untitled shape. Keep titles to one line. One longer than 80 characters is kept but warned about.
- **Matching is exact** on the folded form, and case matters. `"deploy"` is not `"Deploy"`.
- **Names are read as the file has them when the run starts**, every board of it, plus the titles the script itself draws. A rename takes effect from the next run.
- **A type is a note with a `schema:`**, called by its title as any note is: its name is the note's title, never a `"title"` in its schema. `sticky-note[schema]` finds the types.
- **A type refers to another in words by its title, and in its schema by its id.** Its text mentions the type, `@[Address]` ([A text that mentions shapes](#a-text-that-mentions-shapes): a mention of a type is a reference to it, a mention of any other shape only words), and its schema points to it with `{\"$ref\": \"urn:uuid:<id, lowercase>\"}` where that field goes, the id being the type's, which `canvas query`'s rows give (a fragment after it, `#/$defs/zip`, points to a part of it). Write both, as the app keeps them: the mention in words, the `$ref` in JSON. Only the `$ref` takes an id.
- **A kind with no title can't be named.** A reference is drawn without one: `reference "Saved"` is `untitlable`.

```draw-error
// reason: untitlable
reference "Saved" query: "sticky-note"
```

### Make or update

A shape statement **with a title**:

- If exactly one shape on the board has that title, the statement **restates** that shape and updates it. The kind must match, or it's `wrong_kind`; to change a shape's kind, delete it and draw it again in the same script.
- If two or more shapes have that title, it's `ambiguous_title`. Titles only work as names while each is used once, so ask the user to rename one.
- If no shape has it, the statement **creates** a shape with that title. If a title on the board is the same but for case, or nearly the same, the shape is still created, with a warning such as `created "deploy"; the board has "Deploy" — to change that one, write its title exactly`.

A shape statement **without a title** always creates a new, untitled shape. Only its id can refer to it afterwards (its row says it), so title anything you may touch again. A shape statement that names an **id** restates that shape, if the file has one: the kind must match (`wrong_kind`), and `title: "New"` gives an untitled shape a title.

A new shape starts as what its kind's tool places. Then comes its title, then its attributes, then its size, then its position. A restated shape keeps everything the statement doesn't say, including its size and its position on any axis no placement speaks for.

Two statements about one title in one script (two shape statements, or one and a rename to that title) is `duplicate`. A statement placed against its own title is `circular`. The exception is `delete "X"` followed by a shape statement for "X": deletes happen first, so that pair redraws a shape.

A type is a note drawn with a `schema:`, what it holds in words in its `text:` and as JSON in its schema, a quoted string, so each quote is escaped:

```draw
sticky-note "Row" left of "Ingest" text: "A row, by its id." schema: "{\"type\": \"object\", \"properties\": {\"id\": {\"type\": \"string\"}}}"
```

## Attributes

An attribute is `key: value`. Each key appears once in a statement; the second is `duplicate`.

### The language's keys

| key | value | what it does |
|---|---|---|
| `size:` | `<width>x<height>` (`x` or `×`), or `[w, h]`; both above 0, and at most 100000; for a kind with a smallest, at least that (`canvas kinds`' `smallest`). Or a width alone, `<width>x` | The shape's size in world units. A new shape defaults to what its tool places; a restated one keeps its size. A width alone leaves the height to the kind: a note's fitted to its text at that width, any other kind's as it was (a new one's as its tool places it). Under the kind's smallest it's `invalid_value`, with the size to write. |
| `gap:` | `none`, `tight`, `normal`, `wide`, or a number from 0 to 100000 | This shape's default gap in every placement it's in, from either end. See [Gaps](#gaps). |
| `overlap:` | `allow` | This shape may overlap others. It's never pushed, and it's never part of a list. |
| `style:` | a name, or several joined by `,` or `and` | The styles it takes, in order. See [Styles](#styles). |
| `title:` | a quoted title | Renames a restated shape. See [Renaming](#renaming). |

### A kind's attributes

Every other key is one of the kind's properties, named as its schema names it; `canvas kinds` lists them. The value is read by the property's type:

| the property is | write | for example |
|---|---|---|
| text | a quoted string, or a single bare word | `text: "Pull the day's files"`, `text: later` |
| a date and time | `YYYY-MM-DD` (midnight UTC), or a full date-time | `due: 2026-10-20`, `due: 2026-10-20T09:30:00Z`, on a kind that has one |
| one of a set | one of its words, bare or quoted | `status: blocked`, on a kind that has one |
| a number | a bare number | `estimate: 6`, on a kind that has one |
| true or false | `true` or `false` | `locked: true` |
| anything | `null`, which puts the property back to its default | `text: null` |

The shipped kinds' attributes:

- **sticky-note**: `text` (what it says: past eight lines or so the note grows taller to fit it, from its top. A `size:` with a height holds as drawn only until its text changes, typed by the user or set again by a script without `size:`: then it's as tall as its text again, never under 200, and opening it to edit grows it to its text. So don't use a note as a zone of a set height. A width alone, `size: 320x`, makes it that wide and as tall as its text there, in one run), `schema` (below), `relationship` (below), `is` (below), `fieldValues` (below), `color` (below: its paper; without one, its type's color, else yellow), `locked`, `public`.
- **A note's `schema`** (a JSON Schema, as text: its properties in the order written, shown in the note's panel, its Schema tab) makes the note a type, not public unless `public: true` is written beside it, its `text` what the type holds in words, named by the note's title. What a script writes is taken as written: the Claude sync that rewrites one side when the user edits the other isn't asked, so write text and a schema that agree.
- **A note's `relationship`** (`true`; `false` and `null` take it off) marks a type as a relationship type, one that says what an arrow between two notes holds and which types it runs from and to. It is inert on a note with no `schema:`. A type is made one by writing `relationship: true` beside its `schema:`.
- **A note's `is`** (the types it is, by their titles: `is: "Person"`, or several as a JSON list, `is: ["Person", "Employee card"]`, in the order added) makes it an instance of those types; a later one wins where two say the same, and the same type twice is once (the first). A title names a type anywhere in the file, or one the script draws (a note given a `schema:` in the same run), and a shape that isn't a type is `invalid_value`, "which isn't a type or a shape"; so is naming a type already built on the shape (a cycle). A type may be an instance of types itself. An edge takes `is:` too (`edge "A" -> "B" is: "Friendship"`): an arrow can be an instance of a type, which the user adds with `/is-a` in its label. Quoted text for any list of text is a list of that one item.
- **A note's `fieldValues`** (what it holds for the fields of its types) is one JSON object, a member for each field, by the field's key: `fieldValues: {"status": "paid"}`, on the statement's line. A statement joins it with what the note holds: an object's members are set one by one, at every depth (`{"shipping": {"city": "Leeds"}}` keeps the street), a list is replaced whole, and `null` clears the member it's written at; `fieldValues: null` takes every value off. A value that is empty (`""`, `null`, `[]`, `{}`, or a list or group of nothing but those) is not kept, at any depth, and an object of only those leaves the note with none; `false` and `0` are values. An edge takes `fieldValues:` too, joined the same way. A member no field of the note's types names is kept and warned about (`"emial" isn't a field of Order`). The check reads the note's types wherever they are, and a type the same script draws. A query reads it by path: `[fieldValues.status="paid"]`. A string in a value is only text: `@[Title]` there is those characters, not a mention of any shape. A note's title is its statement's name: its values never title it.
- **subboard**: `description` (what it's for, mention text as a note's `text` is, which the user reads in its panel and nowhere on the canvas), `color` (below: its border and card, indigo without one), `locked` (locking a subboard locks what's on its board, at any depth), `public`.
- **frame**: `color` (below: its border and a faint surface; none by default), `locked` (locking a frame locks what's in it, at any depth), `public`.
- **reference**: `query` (a query in the query language: the pill stands for what it finds, and one the app can't read is `invalid_value` with its message), `all` (`true` stands for every match, `false`, the default, for the first in file order), `locked`. What it names and the words typed into it are the user's, from picking a shape and typing: a script can't write them (`unknown_attribute`). A reference is never public, and has no title. A direct one, standing for the shape on the far side of an edge, is what an edge between boards draws for itself ([Through a reference](#through-a-reference)).
- **A note's `text`** can mention shapes by title: `@[Title]` is a mention of the shape called Title, which the note shows as a live pill with that shape's name now ([A text that mentions shapes](#a-text-that-mentions-shapes)). Anything else in it is kept as written. A subboard's `description` mentions shapes the same way, its pills shown in its panel.
- **`color`** is a shape's color, on the kinds that have one (a note, a subboard, a frame, and an edge's arrow): one of the named colors, `color: blue` (`gray`, `red`, `orange`, `yellow`, `green`, `teal`, `blue`, `indigo`, `purple`, `pink`, and any the file added, in any case: it's kept as its list spells it), or a hex value, quoted, `color: "#4465E9"` (`"#46E"` is `"#4466EE"`). The app works out how each kind draws it, in light and dark: a note's paper is a light sheet of that hue, a frame's surface is faint, an arrow's line is darkened or lightened until it reads. A name the file doesn't have is `invalid_value`, and the message lists the names it has; a `#…` that isn't a hex value is too. `color: null` takes the color away, and the shape looks as its kind does, or, for a note of a type whose note has a color (an arrow of a relationship type too), as that type: the first of its types' colors, the one named later first. That color is the type's, never the shape's: `[color]` doesn't match the shape. A file's own colors are added by the user in the app: a script can use one, not make one.
- **`locked: true`** locks a shape, as the context menu's Lock does. A locked shape refuses every later change (`read_only`). Leave locking to the user.
- **`public: true`** makes a shape public: one another shape may stand for, so what points at it needn't be an arrow from everywhere. `public: false` takes it back. It's the user's call, like locking: leave it be unless asked. The exception is [canvas-digest](../../canvas-digest/SKILL.md), which makes public only the shapes it creates, in its own runs, and reports them.

A value past a bound (a title over 80 characters, say) isn't refused. The shape is drawn and the bound comes back as a warning. A value of the wrong type is `invalid_value`, naming the attribute and what it takes. So is a word outside a set, which also gets a Did you mean. A key the kind doesn't have is `unknown_attribute`, which lists what the kind takes and names the kinds that do have the key, if any. A property that holds an object or a list (none of the shipped kinds has one) takes JSON on one line, which replaces the whole property, so write every member; a value of the wrong type anywhere inside it, or a member it doesn't have, is `invalid_value` too, never dropped.

```draw
sticky-note "Backfill" below "Ingest" text: "Waiting on the vendor's March files"
sticky-note "Nightly schedule" below "Load" text: "Pick a time after @[Load], and add a timeout"
```

A note wider than a new one, as tall as its text, takes a width alone:

```draw
sticky-note "Vendor contacts" left of "Row" size: 360x text: "Files: data-ops at the vendor, weekdays. Outages: their on-call line, any hour. Billing: the account manager, who answers within a day."
```

### A text that mentions shapes

A note's `text`, an arrow's `text` (an edge's) and a subboard's `description` are mention text, and `canvas kinds` says so after their type (`text (@[Title] mentions)`). In one, `@[Title]` mentions the shape called Title: the app shows a pill with that shape's name, live (renamed, it follows), and keeps the shape's id, which a script never writes or sees. Nightly schedule's text above mentions Load, which an earlier script drew. A mention is found by its title, exactly as every title in a script is (folded; case matters), with these rules:

- **Which shape.** Among the shapes the text may mention (below), the first of these that has one called that decides: a shape the script itself draws or restates with that title, or renames to it with `title:` (one drawn further down the script counts, so two notes can mention each other); the board the script draws on ([Which board](#which-board)); the board the window shows; any other board of the file the app can show. Two or more in that place are `ambiguous_title`, each listed with its kind and where it is (or, on several boards, the boards); none anywhere is `unknown_title`, with the titles it's like. A shape the script deletes, or the board it takes, counts for nothing: a title only such a shape has is `unknown_title` too (`names "Old", which this script deletes`).
- **Which shapes a text may mention.** A note's text, an arrow's, or a subboard's description, any shape that can be mentioned: notes (types among them), subboards and frames (not an arrow, nor a reference). A text that mentions only some kinds passes over shapes of the others, as if they weren't called that: if they're all that is, the text is refused (`invalid_value`) saying what the shape is and why.
- **No placement, no board.** A title in a text doesn't say where a shape goes or which board the script draws on, and a mention of a shape on another board, however deep, is no reason for `several_boards`: the pill finds the shape wherever it is. Only a statement's own titles and `in` put the run on a board.
- **Written as the title it is.** The pill holds the shape's title as it is now (or will be, for a shape the script renames), whatever way the script wrote it (`@[  Load ]`). A title with a `]` or a backslash in it is written with a backslash before each, which a script's string spells twice: `@[a\\]b]` for a title `a]b`. `@[]`, with no title in it, is refused (`invalid_value`).
- **The rest is text.** Everything else is kept as written, byte for byte: an `@` alone, an `@[` with no `]` before the line ends, a `]` closing nothing. To write the characters `@[` as text, write `\\@[` in a script's string: the text keeps `\@[`, whose backslash makes them plain.

A run again says `unchanged`, since the text it makes is the text the shape has. A title nobody has is refused rather than left as text, with the one it's like:

```draw-error
// reason: unknown_title
sticky-note "Nightly schedule" text: "Pick a time after @[Lod], and add a timeout"
```

### Keys that are refused

- **The title, as an attribute, on a new shape** (`unsupported`). The title goes after the kind, in quotes. On a restated shape, `title:` renames it.
- **Coordinates** (`unsupported`). The box's `frame`, and any property that holds a point or a rectangle, can't be set: there are no coordinates here. Say where a shape goes with a placement (to the unit, with [an exact offset](#an-exact-offset) from a shape), and how big with `size:`. `x:`, `y:`, `at:` and `position:` get the same answer, and `width:` and `height:` are pointed to `size:` (a width alone is `size: 300x`).
- **A kind's property named like a language key** (`size`, `gap`, `overlap`, `style`, `title`) can't be set. `canvas kinds` marks any such property; none of the shipped kinds has one.

## Placements

### Directions

```text
above "A"            below "A"            left of "A"          right of "A"
above-left of "A"    above-right of "A"   below-left of "A"    below-right of "A"
```

A direction puts the shape beyond that side of the target, at least the gap away. A corner is two directions at once, with the gap off both sides. `of` is optional after any direction (`right "A"` is `right of "A"`), and messages always quote it back as `right of`.

### Alignments

```text
level with "A"                 the same vertical middle
top level with "A"             the same top
bottom level with "A"          the same bottom
left level with "A"            the same left edge
right level with "A"           the same right edge
```

An alignment shares a line rather than leaving a space, so it takes no gap. It settles one axis only: `level with` and `top`/`bottom level with` settle the vertical one, and `left`/`right level with` the horizontal one.

### inside, outside, on

```text
inside "A" <part>      within A, against that part, 40 in by default
outside "A" <part>     wholly beyond that part
on "A" [<part>]        centered on that part (A's middle if none)
```

`inside` and `outside` name one shape and a part on its edge, from which they read a direction: `inside "A" right` is left of A's right side, `inside "A" top-right` is below-left of A's top-right corner, and `outside` is the opposite. `on` names one shape and takes no gap. See [Inside, outside, on, and zones](#inside-outside-on-and-zones).

### in

```text
in "A"                 on the board A holds (a subboard's), or in A, on the board A is on (a frame's)
```

```draw
subboard "Backend" right of board
```

```draw
sticky-note "Cache" text: "Redis, 5 min TTL" in "Backend"
sticky-note "Queue" text: "Retries with backoff" in "Backend" right of "Cache"
```

Deleting a subboard deletes what's on its board with it, and the result warns how much:

```draw
delete "Backend"
```

`in` says what holds a shape, not where it sits: `sticky-note "Cache" in "Backend"` draws Cache on the board of the subboard called Backend, the window staying where it is. Write placements beside it as ever; they place the shape on that board, against shapes there (`in "Backend" below "API"`), `board` (that board's shapes) or `view` (the part of it the window shows when it's opened). With none, it's [a drawing with nothing to hang on](#a-drawing-with-nothing-to-hang-on) there. It names one shape that holds others, a subboard or a frame ([Frames](#frames)), with no part: `in "Notes"` on a note is `cannot_contain`. That shape must be on the board already: one this script draws is `unsupported`, so draw it, then what goes in it in a run of its own. A locked subboard takes nothing, nor does one on a locked subboard's board: its board is read-only, and `in` it is `read_only`, as `in` a locked frame is. `inside` is another thing: `inside "Backend" top-left` puts a shape over its card, on the board the card is on.

### Targets

A target is a quoted title or an id (`#7C1E…`), optionally followed by a part, or one of two unquoted words:

- **`board`** is the box around every [obstacle](#keeping-clear): the shapes on the board that this script doesn't move, nor a frame it moves takes along (the board the window shows, not the boards inside its subboards). `right of board` is a new column past everything, `below board` is the space under everything. On an empty board it's `unknown_title`, because there's nothing to be right of. Leave one shape unplaced instead, and the drawing goes in the window.
- **`view`** is the part of the board in the window (below the path's pill over a subboard, which covers the window's top there). `inside view top-right` puts a legend in a corner. `view` needs the board's window to have a size, or it's `no_view`.

Both are fixed boxes, measured once when the script runs.

### Several targets

`right of "A" and "B"`, or `below "A", "B" and "C"`, places against the box that bounds them all. A direction clears the furthest of them, and the other axis centers on their whole span. `inside`, `outside` and `on` take one target.

### Parts

| part | what it is |
|---|---|
| `top`, `bottom`, `left`, `right` | a side: a segment as long as the side, with no thickness |
| `top-left`, `top-right`, `bottom-left`, `bottom-right` | a corner, on the shape's outline (so a round shape's corners would be on its curve) |
| `top-center`, `left-center`, `right-center`, `bottom-center`, `center` | a point: the middle of a side, or of the shape |

A part narrows the target. `right of "A" top` is right of A's top side, so it's centered on the line of A's top edge. `text` isn't a part; a note's words are `text:`.

`left`, `right`, `top` and `bottom` are parts, and they also start placements, so after a target the word that follows decides. Followed by `of` or `level`, or (for `left` and `right`) by a title, `board` or `view`, the word starts the next placement. Otherwise it's the target's part. So `below "A" right of "B"` is two placements, and `below "A" right` is below A's right side. After `inside`, `outside` and `on`, only `of` makes it the next placement.

### Gaps on a placement

A gap in brackets belongs to the one placement it follows: `right of "A" (gap: tight)`, `below "B" (gap: 24)`. An alignment or `on` with a gap is refused, since neither leaves a space.

```draw
sticky-note "Owner" above-left of "Ingest" text: "The data team"
sticky-note "Retry" right of "Load" top level with "Nightly schedule" text: "Try failed loads again"
```

```draw
sticky-note "Runbook" below "Backfill" and "Retry" text: "What to do when a load fails"
sticky-note "Alerts" below "Runbook" (gap: tight) text: "Page the owner"
```

### An exact offset

```text
right of "A" left (gap: x) below "A" top (gap: y)      the shape's top-left x right of A's and y below it
```

A direction against a side of a shape is measured from that side, wherever the shape lands: `right of "A" left (gap: 520)` puts the shape's left edge 520 right of A's left edge, over A or past it, and `below "A" top (gap: 20)` its top edge 20 below A's top. Together they put its top-left exactly that far from A's. That's how to draw a layout worked out elsewhere, by a script that computes positions: take one shape on the board as the origin, and give every shape its offset from it. `inside "A" top-left (gap: 20)` doesn't do it: its one gap is the same across and down, and keeps the shape that far in from every side. A gap is never negative, so make the origin a shape at the layout's top-left. An offset is a placement like any other: a shape that lands on another is pushed past it, and the result says so (`pushedPast`). For offsets inside a frame, draw the shapes `in` it ([Frames](#frames)).

```draw
// Owner's top-left is the origin: each note's top-left is the offset written.
sticky-note "Glossary" right of "Owner" left (gap: 520) below "Owner" top (gap: 20) text: "Words the team uses"
sticky-note "Contacts" right of "Owner" left (gap: 760) below "Owner" top (gap: 20) text: "Who to call"
```

## Which board

A file can hold boards inside shapes, and a script draws on one of them, worked out from what it names:

- A title names a shape on any board of the file: the one the window shows first, and else wherever it is. `sticky-note "Auth" text: "Done"` changes Auth on whatever board it's on.
- A new shape goes on the board of the shapes it's placed against, or the board `in` names (a frame's is the board the frame is on). With neither (unplaced, or against `board` or `view`), it goes on the board the rest of the script draws on, else the one the window shows.
- A statement with `in "X"` reads its titles on X's board alone: that's how to name a shape whose title is on two boards.
- An edge between shapes on two boards doesn't pick the board by itself when one of its ends can be stood for by a reference (a public shape can: [Through a reference](#through-a-reference)). An arrow can't leave its board, so the end that can be stood for is reached through a reference put beside the other end, which is on the board the run draws on. The run draws on the first board something else says (a title, an `in`, an end that can't be stood for, the start of an edge with `via:`); with nothing else, on the board of the first such edge's start. Each such edge then needs one end on that board. `delete edge` reads its ends the same way.
- A shape the script draws counts as on the board the run draws on, whichever that is, and says nothing of the board itself. An edge from it to a shape on another board goes into a reference beside it, if that shape can be stood for; with nothing else to decide, the run draws on that shape's board, and the edge is straight there.
- An edge that's drawn through a reference already is on the board the reference is on: a run again, and `delete edge`, go there whichever board the edge would pick otherwise, since a reference made on the other board would draw it twice.

A locked subboard makes its board read-only, and every board under it too, at any depth. A new shape or edge that would land on one (`in` the subboard, placed against a shape there, or on the board the window shows when the user has opened it) is `read_only`, and so is any change to what's on it; a statement that restates something as it is is fine.

A run draws on one board, as one step of undo: a script whose statements land on two is `several_boards`, and so is an edge between shapes on two boards when neither end can be stood for, or when neither is on the board the run draws on. A title on two boards, neither shown, is `ambiguous_title` until `in` says which. The window never moves for a draw (but `--reveal` shows the board drawn on), and undoing a run on another board shows that board.

```text
sticky-note "Retry" text: "Backoff, 3 tries" in "Payments" below "Charge"
```

## How placements combine

A shape can carry as many placements as it needs. Each one speaks for one axis or both, and together they must settle both.

1. **A gap is a minimum** among the shapes this script places. Shapes already on the board don't move unless the script restates them with placements; to the script they're walls.
2. **A lone direction binds both axes.** `right of "A"` also centers the shape vertically on A, because walking right from something keeps you on its center line. The centering drops away as soon as another placement speaks for that axis: `right of "A" below "C"` is right of A and below C.
3. **Two directions on one axis, with nothing on the other, is refused** for a new shape (`unplaced`). `right of "A" left of "B"` would put the shape in different rows depending on which it centered on. Add `level with "A"`, or a `below`. An alignment alone settles only its own axis, so a new shape with only `level with "A"` is `unplaced` too. A restated shape instead keeps its current position on the axis no placement speaks for.
4. **Exactly one new shape may say nothing about where it goes.** It and everything placed against it land in the window as one drawing ([A drawing with nothing to hang on](#a-drawing-with-nothing-to-hang-on)). Two or more is `unplaced`. A restated shape with no placements stays where it is.
5. **Shapes don't overlap** ([Keeping clear](#keeping-clear)).
6. **Placements written identically make a list** ([Lists](#lists)).

A shape held from both sides on one axis, as in `right of "A" left of "B" level with "A"`, sits against the lower side: right of A at the gap, with any room left over between it and B. Above-and-below works the same way, with the shape against the one above. A shape placed only `left of` or `above` something sits as close to it as the gap allows, and whatever is placed against that shape follows it.

## Gaps

| gap | world units |
|---|---|
| `none` | 0 (the two touch) |
| `tight` | 40 |
| `normal` | 80, the default |
| `wide` | 160 |
| a number | that many, 0 to 100000 (`24`, not `24px`) |

A placement's gap is the first of these that applies:

1. Its bracket: `right of "A" (gap: wide)`.
2. `tight`, for `inside`.
3. The larger of the shape's `gap:` and its target's `gap:`, when the target is also stated in this script.
4. `normal`.

Other spacing is fixed. A list steps 64 (the references an edge puts beside a shape, 16: [Through a reference](#through-a-reference)). Shapes pushed apart keep 40 between them side by side, and 64 one above the other. The extra room is for the row just above a shape, where its title's pill and a lock's chip go, which sits 27 units above it at 100% zoom and 54 at 50%, so it clears the shape above down to about 42% zoom (below 35%, where shapes are skeletons, no pill or chip is drawn).

## Lists

New or restated shapes whose placements are written identically form a list. "Identically" means the same placements in the same order, against the same shapes, bracketed gaps included, as quoted back: `right "A"` and `right of "A"` count as the same. The members stack down the page in script order and are placed as one box. Three shapes `right of "Hub"` make a column centered on Hub. Two shapes `below "Hub"` stack under it, each centered across on Hub.

- They're 64 apart, or the members' `gap:` if they all state the same one.
- An `overlap: allow` shape is never in a list.
- A list moves as one. A member pushed past something takes the others with it, either way: down, or across, which would otherwise split the column.
- A list isn't extended across runs. A later `right of "Hub"` is centered on Hub and pushed past the old column. To add a member, restate every member with the same placement. (The references an edge puts beside a shape are the exception: a later run's join the column there, [Through a reference](#through-a-reference).)
- A list `inside` a shape stacks down from its part, and one too long to fit is `no_room`.
- For a flow with arrows between steps, a wider step gives the arrows room: give every member the same `gap:`.

```draw
subboard "Monday" right of "Retry"
subboard "Tuesday" right of "Retry"
subboard "Wednesday" right of "Retry"
```

```draw
sticky-note "Draft" below "Alerts" gap: wide text: "Write it"
sticky-note "Review" below "Alerts" gap: wide text: "Read it twice"
```

## Keeping clear

The shapes a script places (new ones, and restated ones with placements) are kept clear of one another, and of the **obstacles**. An obstacle is a shape on the board that the script doesn't move or delete, that's closed (not an arrow or a drawn line), and that the app can use. Obstacles that already overlap each other are left alone: that's the user's arrangement.

Some pairs are allowed to overlap:

- a shape and what it's `inside` or `on`;
- a shape with `overlap: allow`, and anything;
- a shape and a zone, an obstacle that wholly holds one of these: the shape where it already sat (a restated one), however snugly; a shape it's placed against, if the zone is at least twice that one's size (in area); the shape where it lands, if the zone holds other shapes too and is at least twice the shape's size; or the `view` it's placed against (the region you're zoomed into), or that the [drawing with nothing to hang on](#a-drawing-with-nothing-to-hang-on) is drawn in. A restated card lined up with one in the next column stays in its own, a shape placed against one on a much bigger shape isn't in the bigger one's way, and one that lands in a corner of a region that frames what's in it sits on that region. But what holds only the shape where it lands is in the way, however big: a small note that lands on an empty note is pushed past it, and so is a note that lands on a subboard's card, or a shape moved onto either from elsewhere. So is a shape alone on the board, to one placed `inside board` over it. A note or a card that holds a shape of its own (a badge wholly inside it) is a zone like any other, though: a shape at most half its size that lands wholly on it sits on it, over its text (the badge is still in its way).

A shape this script places counts as one a zone holds only when it's on the zone for a reason of its own, never just because another new shape is: it's placed `inside` or `on` the zone; the zone would hold it with no new shape counted (where it already sat, a shape on the board it's placed against, the view, or shapes on the board it lands among); or it's placed against a shape that counts. So two new shapes can't hold each other on an empty zone: a small note and the caption placed below it, landing together on the next note, are both pushed past it, and so are two legends landing on an empty frame. A shape placed `inside` an empty zone counts, whatever line it's on, and so, in turn, does what's placed against it.

**Against an obstacle**, a shape is pushed along an axis its placements leave free, the way they already hold it. Placed `right of` or `below` something, it goes further right or down. Placed `left of` or `above`, it goes further left or up. Held from both sides with room to spare, it goes on past, and without room it's `no_room`, naming what it had to clear. Held exactly on both axes (`on`, or `level with` on a shape whose other axis is kept), it can't move, and it's `unordered`. When both axes are free, it goes along the one it overlaps less on. A push moves the shape pushed, never a shape it's placed against: its own placements hold it to what they name, so a way that would drag one of those off its spot isn't one it's pushed. What's placed against the pushed shape follows it.

**Between two placed shapes**, they're pushed apart only along an axis where one is placed against the other, directly or through other shapes. Otherwise nothing says which side of the other either one sits on, and that's `unordered` rather than a guess. Place one against the other, or give one `overlap: allow`. An order that runs only through shapes on the board counts only if the two are already that way round, so two shapes are never flipped past each other. What's tied to the one pushed goes along: what's placed against it, and what it's placed against if that one's own placements leave it room. `"C" below "T"`, pushed right past W, takes T (`right of "W"`) further right with it.

**Every push is reported**, for every shape it moves. The shape pushed gets `pushedPast` on its row (the titles it went past, or `<kind> at x,y` for untitled ones), and a warning for each, such as `"Why" was pushed right past "DB" to keep clear of it, so it no longer sits against "API" — place it on another side, or say overlap: allow`. The `so it no longer sits against` part names the placement whose gap the push made bigger, and is left out when there's none: a push never takes a shape off a centering or an alignment. Held that way on both axes it's `unordered` (as above), and an alignment to several shapes that a push moves apart is `no_room`. A shape that only went along with a pushed one wasn't kept clear of anything itself, so its row has no `pushedPast`. Its warning names the shape it went with: `"D" moved right along with "N", which was pushed past "Q" to keep clear of it — place "N" on another side, or give "N" overlap: allow`. What a shape went past is said once for each way it went: a list's members move as one, so each member pushed past a wall is said to have been, and never also to have gone along with another past it, and one that only went along is said to have gone with the first of them. A pushed shape isn't where your sentence put it, so fix the pushed shape's placement rather than leave it.

Pairs are checked in a fixed order: placed shapes in script order, each against the placed shapes after it and then the obstacles near it, in stacking order. Each pair is pushed apart at most once, and the whole layout is worked out again after every push. The same script on the same board always gives the same result.

## A drawing with nothing to hang on

The one new shape with no placement is the **anchor**. The anchor, everything the script places against it, and everything placed against those (lists included) make one drawing.

- **If nothing in the drawing names a shape on the board, `board` or `view`**, it's worked out on its own and then put in the window. The middle of its bounds goes to the middle of the view, or to the nearest spot around it where no part of it comes within 80 of a shape on the board or a shape this script placed elsewhere. A shape that holds the whole view isn't in the way, but is a zone for the drawing, as it is for a shape placed against `view`: zoomed into a frame, the drawing lands on the frame, in view, clear of what's on it. The spots are tried on square rings 40 apart: nearest the middle first, then higher, then further left. If there's no clear spot within 100 rings, the drawing goes 160 right of everything, top-aligned with it. Where the window is changes where the drawing lands, never whether the script runs.
- **If something in it names a shape on the board**, `board` or `view` (or restates a shape and keeps one of its axes), it gets no special treatment. The unplaced shape has to be tied to the board through what's placed against it, on both axes, or it's `unplaced`.
- **Every other placed shape must be tied to the board on both axes**: through its placements, directly or through other shapes, to a shape on the board, `board` or `view`. Otherwise it's `unanchored`, naming the axis.

So on an empty board, a script leaves one shape unplaced, or places against `view`. The first script on this page did both.

## Inside, outside, on, and zones

**`inside "Z" <part>`** puts the shape within Z, against that part. The gap is `tight` (40) unless the placement brackets another; the shape's own `gap:` doesn't apply. The shape stays within Z, the gap in from every side. If it doesn't fit, or would have to leave Z to keep clear of something in Z, it's `no_room`. A shape and what it's inside may overlap. Two shapes inside different corners of a small Z that end up overlapping are `unordered`, since nothing orders them; place one against the other.

**`outside "Z" <part>`** puts it wholly beyond that part, at the placement's gap.

**`on "Z" [<part>]`** centers it on the part, or on Z's middle if none is named, and lets it overlap Z. It's held on both axes, so if it lands on anything else it's `unordered` unless it says `overlap: allow`.

**A zone** is a big shape that others sit on, like a big note for a team or a tier. Draw it in its own script first, then draw what goes in it. A [frame](#frames) is often the better choice: it holds what's in it. Once the zone is on the board, it isn't in the way of a shape placed against one it holds, or of one that lands wholly on it while it already holds other shapes, as long as the zone is at least twice the size of the one it holds or the one landing. Nor is it in the way of a shape restated that already sat on it, or of one placed against `view` while the whole view is on it ([Keeping clear](#keeping-clear)). So a card in one column lined up with a card in the next stays in its own, and `inside view top-right` puts a legend in the corner of a region you're zoomed into, or of one that fills most of the window and holds other shapes. A shape that lands on an empty zone, placed against nothing in it, is pushed past it, and so is every shape the same script lands on it that way: put the first shape in with `inside`, and place the rest against that one. One that can't move off an empty zone (a card restated `left level with` an empty lane) is `unordered`, and its hint says the zone holds nothing yet (or no shape wholly, when one hangs over its edge): place it elsewhere, or, if the zone is meant to hold shapes, place a first one `inside` it. Held on an empty note, the hint is the same, but what goes on a note covers its words: place the shape elsewhere. Only `inside` keeps a shape within the zone: one placed against a shape in it, or restated, isn't held in, and can hang over its edge. The result then warns, `"Dead letters" hangs over the edge of "Backend" — make "Backend" bigger, or place "Dead letters" elsewhere`: place it `inside` the zone, or make the zone bigger. Within one script, only shapes placed `inside` or `on` a shape may overlap it. Drawn in the same script as what goes in it, a zone is in the way of everything but those: a shape placed against something inside it is pushed out of it, and one held inside it with no room left is `no_room`, naming what pushed it. Draw the zone first.

**Paint order.** New shapes are painted above everything already on the board. A shape placed `inside` or `on` another shape this script draws is painted above that shape. A restated shape moved `inside` or `on` a shape that paints above it is brought above that shape, and so is one moved into a zone that paints above it, or within the one it's in, so a shape drawn before its zone isn't hidden under it; a shape placed `on` or `inside` it in the same script goes above it in turn, whatever order the lines are in. A locked shape isn't moved in the stack, unless the same statement unlocks it (or locks it: it's raised first).

```draw
sticky-note "Warehouse" below board size: 1000x360
```

```draw
sticky-note "Orders table" inside "Warehouse" top-left text: "One row per order"
sticky-note "Customers table" right of "Orders table" text: "One row per customer"
sticky-note "Badge" on "Warehouse" top-right size: 80x80
sticky-note "Archive" outside "Warehouse" bottom text: "Older than a year"
```

A note stuck across two notes overlaps both on purpose. `on` exempts it from the one it's on, and `overlap: allow` from the other:

```draw
sticky-note "Stamp" on "Orders table" right overlap: allow text: "Reviewed"
```

## Frames

A frame is a region of the board that holds shapes: what's in it moves with it, is drawn above it, is locked with it, and is listed under it. Unlike a zone, it holds what's in it: a shape is in it or out of it, never across its edge.

```draw
frame "Sprint" below board size: 900x600
```

`in "Sprint"` puts a shape in the frame, on the board the frame is on, kept 40 in from its edges. With nothing else to say where, it goes against the frame's top-left, as `inside "Sprint" top-left` places one, and shapes written alike make a list down from there. With placements, it goes where they say, kept within the frame, or the script fails with `no_room`.

```draw
sticky-note "Login bug" in "Sprint" text: "Sessions expire too soon"
sticky-note "Billing" in "Sprint" text: "Move invoices to the new API"
sticky-note "Search" in "Sprint" right of "Login bug" text: "Index the archive"
```

At an exact spot in the frame, a shape is placed by its offset from the frame's top-left ([An exact offset](#an-exact-offset)), and `in` the frame, which is then never in its way:

```draw
sticky-note "Spike" in "Sprint" right of "Sprint" left (gap: 600) below "Sprint" top (gap: 340) text: "Try the new parser"
```

- **Nothing sits across a frame's edge.** Whatever a script puts down over one (a new shape, or one it places or resizes) goes wholly in or out of it by most of its area, nudged to 16 clear of the edge, as by hand, and a warning says which: `"Draft" was over the edge of "Sprint", so it was nudged in`. So a shape placed `inside` a frame, `on` it, or against a shape in it, that lands within it, is in it too. The row's `at` is where it ended up.
- **A frame placed elsewhere takes what's in it along**, and what's in it is never in its way. Every other shape the script places meets what's in it where the frame takes it, never where it was, so frames moved in one script can trade places: each lands where it's placed. Placing another shape against one it takes along, in the same script, is `unsupported`: place it against the frame, or in a run of its own. Resized, a frame leaves what's in it where it is, and what's then over its edge goes wholly in or out (a warning says how many).
- **A locked frame locks what's in it**, at any depth, and takes nothing new: `in` it, or a script that would put a shape in it, is `read_only`, and so is any change to what's in it.
- **Draw a frame in its own script first.** `in` a frame the same script draws is `unsupported`. A frame doesn't grow to fit what's drawn in it, so give it a `size:` with room. A frame is at least 96x64, the smallest the Frame tool draws one: a `size:` under that is `invalid_value`.
- **Deleting a frame leaves what's in it where it is**, now in what held the frame, or on the board.

```draw-error
// reason: unsupported
frame "Later" right of board
sticky-note "Plan" in "Later"
```

```draw-error
// reason: no_room
sticky-note "Wide" in "Sprint" size: 900x200
```

## Edges

### Writing one

```text
edge "A" -> "B"           a connection from A to B, a head at B
edge "B" <- "A"           the same edge, written with B first
edge "A" <-> "B"          heads at both ends
```

Both ends are titles: shapes on the board, or shapes the same script draws; one may be on another board, for an edge that goes [through a reference](#through-a-reference). A shape with no title is an end by its id, `edge "Checkout" -> #7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11`: the row calls such an end by the id as written and says it again in `fromId` or `toId`. An edge takes these attributes and no others:

| key | value |
|---|---|
| `from:` | `top`, `right`, `bottom` or `left`: the side the start leaves from |
| `to:` | `top`, `right`, `bottom` or `left`: the side the end arrives on |
| `via:` | `reference`: the kind of shape the edge goes through ([Through a reference](#through-a-reference)) |
| `share:` | `true`, or the title (or id) of a shape: the edge's reference is one that's there already ([Through a reference](#through-a-reference)) |
| `channel:` | a channel's id, or `none` for a plain arrow |
| `is:` | the types the arrow is, by title, as a note's (`is: "Employment"`): a relationship, when the type is a relationship type ([relationships.md](relationships.md)). With it an edge is its pair of ends and its type: two arrows between one pair are two edges |
| `fieldValues:` | what the arrow holds for its types' fields, a JSON object by field key, joined as a note's is (`fieldValues: {"role": "Staff engineer"}`) |
| `text:` | what the arrow says, quoted, set on its line (`text: "calls"`); it may mention shapes by title (`text: "calls @[Cache]"`) |
| `labelPosition:` | where its text sits along it: `0` at its start, `1` at its end, `0.5` (halfway) by default |
| `bend:` | how far its middle is pushed off the straight line, in world units; `0` is straight |
| `endRule:` | a JSON object, `{"needed": true, "onlyOne": true}`: what a relationship type asks of the end this arrow is, checked on the notes at that end: a note with none where it is Needed is `:incomplete` (amber on the board, not an error), one with more than one where it is Only one is an error on the note. A statement sets the members it names and keeps the rest; `null` takes the rule off. Inert on an arrow that is not a relationship type's end |
| `color:` | the arrow's color, its line, heads and label: a named color or a quoted hex, as a shape's `color` is; `null` takes it away (an arrow of a relationship type is then its type's color) |
| `locked:` | `true` or `false` |

Beside `from:`, `to:`, `via:`, `share:` and `channel:`, an edge's attributes are the arrow's, as `canvas kinds arrow` lists them, written as a shape's are. Its heads aren't among them: the arrow you write (`->`, `<->`) says them, and `startArrowhead:` or `endArrowhead:` saying otherwise is `invalid_value`. Text goes after `text:`; a quoted string right after the edge is `syntax`. An arrow's text is mention text, as a note's is ([A text that mentions shapes](#a-text-that-mentions-shapes)): the label shows each `@[Title]` as a live pill. An edge goes where its ends are and takes no style; one that goes through a reference may say where the reference goes, in a shape's placements and `in` ([Through a reference](#through-a-reference)). Chains (`edge "A" -> "B" -> "C"`) are refused: write each edge on a line of its own.

### Sides

Without `from:` or `to:`, an end aims at the middle of its shape, and the line is clipped where it meets the outline. With one, the end aims at the middle of that side. If a named side faces away from the far shape, the line still leaves from the side facing it (arrows are arcs, and they clip at the outline), and a warning says so, as in `from: left: "B" is right of "A", so the line leaves "A" by its right side — name a side that faces "B", or leave from: out`. Arrows don't route around shapes, and they're never obstacles.

An edge that goes through a reference has the reference at one end, and a side named for that end is the reference's own, which has ports on its left and right alone ([Through a reference](#through-a-reference)).

### Channels

A channel is what kind of connection an edge is. Each kind has ports on some channels, on some sides, and an edge on a channel runs only between shapes whose kinds take it: from a shape with ports on it, to a shape that accepts it.

| kind | channels | sides |
|---|---|---|
| `sticky-note` | `note-link` | all four |
| `subboard` | `subboard-link`, `note-link` | all four |
| `frame` | none | none |
| `reference` | none | none |

A subboard has ports on every channel, its own first: a note connects to one on its own channel, a subboard to a note on the note's, and two subboards on `subboard-link`.

`canvas kinds` lists each kind's channels by side, under `edges`. How an edge's channel is chosen:

- **`channel: <id>`**: that channel. The start's kind must have ports on it, and the end's kind must accept it. Otherwise it's `no_channel`, and the message says what each end takes, side by side. A word that isn't a channel is `invalid_value`, and the hint lists the channels.
- **`channel: none`**: a plain arrow, on no channel, between any two shapes, from and to any sides.
- **Unwritten**: the first of the start's channels (on the `from:` side, if named) that the end accepts (on the `to:` side, if named). If there's none, and neither kind has ports on any channel (two frames), it's a plain arrow, from and to any sides named. If there's none and either kind does have ports, it's `no_channel`: `"Ingest" and "Sprint" share no channel: a sticky-note connects on note-link, a frame has no ports`, with the hint `channel: none draws a plain arrow between them anyway`.
- **A side a kind has no port on** is refused. With `channel:` written, it's `invalid_value`, and the message says which sides the kind does have ports on. With the channel unwritten, no channel fits that side, so it's `no_channel`. Notes and subboards have ports on all four sides, so every side is fine for them; this is for a kind with ports on fewer.
- **An edge from a shape to itself** on a channel is refused. With `channel: none` it's a short straight arrow inside the shape (from its middle, or between the sides named), not a loop around it. To show a loop, draw it through a second shape.
- **A reference at one end** (an edge [through a reference](#through-a-reference)) is judged as the shape it stands for, on its own left and right sides: the channel is the one a drag from that shape's port to it would find, so an edge to a public note is on `note-link`. A `channel:` written still wins when both ends take it, and `channel: none` draws a plain arrow into the reference as ever.

```draw
edge "Ingest" -> "Clean"
edge "Clean" -> "Load"
edge "Load" <- "Retry"
edge "Monday" -> "Tuesday" from: bottom to: top
edge "Tuesday" <-> "Wednesday"
```

```draw
edge "Backfill" -> "Nightly schedule" channel: note-link
edge "Nightly schedule" -> "Load" channel: none
```

```draw
edge "Ingest" -> "Clean" text: "raw rows"
edge "Clean" -> "Load" text: "deduplicated" labelPosition: 0.3
```

An edge's text mentions shapes as a note's does, and a run again says `unchanged`:

```draw
edge "Backfill" -> "Load" text: "after @[Nightly schedule]"
```

```draw-error
// reason: no_channel
edge "Ingest" -> "Sprint"
```

### Drawing one again

An edge statement means "A is connected to B" (with `<->`, in either direction). It looks for the connections already drawn between the two, straight between them or [through a reference](#through-a-reference) that stands for the other end:

- **None**: it draws one (`did: "connected"`).
- **One**: it updates only what the statement writes. A named side re-aims that end, and an unnamed side keeps the end as it was. The heads follow the arrow (`->` a head at the end only, `<->` both), and the bend and the text stay unless written (`text: null` takes the text away). The channel stays too: a different `channel:` is refused (`invalid_value`), with the hint to write `delete edge` above the line and draw it again. Nothing different is `did: "unchanged"`; otherwise it's `did: "reconnected"`.
- **Two or more** is `ambiguous_edge`. Say which with `is:` (below), or delete them (`delete edge "A" -> "B"`) above the line and draw one again.
- **A locked connection** refuses a change (`read_only`), but a statement that wouldn't change it is fine.

`delete edge "A" -> "B"` followed by `edge "A" -> "B"` in one script redraws it, since deletes happen first. Two edge statements for the same pair, the same way round (or either way, when one is `<->`), in one script is `duplicate`, unless both write `is:` and differently.

**Which one, with `is:`.** An arrow is of the types its `is:` names, and two arrows between the same two shapes are two edges when they are of different types. A statement that writes `is:` is about the arrow of the pair that is of those types:

- **One has them**: it is that arrow (`unchanged`, or `reconnected` if the statement writes more). The types are compared as a set (`is: ["A", "B"]` is `is: ["B", "A"]`), and `is: null` and no types are one.
- **None has them**, and the pair has exactly one arrow of no type: that arrow takes the types (`reconnected`). Otherwise it draws another arrow (`connected`).
- **Two have them** is `ambiguous_edge`.
- **`is: null`** is about the arrow of no type, never a typed one: `edge "A" -> "B" is: null` beside `is: "Friendship"` draws a second arrow.

So `edge "Ann" -> "Bo" is: "Friendship"` and `edge "Ann" -> "Bo" is: "Mentorship"` in one script draw two arrows, and written again both are `unchanged`. A statement that doesn't write `is:` is about the pair, as above: one arrow, updated; two, `ambiguous_edge`, with a hint to write `is:`. The arrow's type is not changed by writing another `is:`: to retype one, `delete edge "A" -> "B" is: "Old"` above `edge "A" -> "B" is: "New"`.

```draw
edge "Ingest" -> "Clean" from: right to: left
```

### Through a reference

An arrow can't leave its board, and a shape that many arrows point at needn't be pointed at from everywhere: a **reference** is a pill that stands for another shape, anywhere in the file, and an arrow into it is, to everything that reads the board, an arrow into that shape ([references.md](references.md)). An edge between shapes on two boards is drawn through one without your asking: the run puts a reference for the end that's on the other board beside the end that's on this one, and draws the arrow to it (or, when the far end is the start, from it).

Only a **public** shape can be stood for, and `public: true` is the user's call, so a script never makes a shape public to get an edge across. This run draws a public note and a private one on Monday's board, to have something to reach and something not to:

```draw
// Making a shape public is the user's call: this example needs one to point at.
sticky-note "Cutoff" in "Monday" public: true text: "Files after 02:00 wait for tomorrow"
sticky-note "Scratch" in "Monday" right of "Cutoff" text: "Not for sharing yet"
```

Load is on the board the window shows, and Cutoff on Monday's:

```draw
edge "Load" -> "Cutoff"
```

The run made a reference for Cutoff right of Load, and drew the arrow into it. The result has a row for the reference (`created`, `kind: "reference"`, `at`) before the edge's, which says `connected` and `via: "reference"` (every row of an edge that goes through a reference has `via`, `unchanged` and `deleted` ones too). The row is all that says so: there's no warning, so in a run of many such edges the warnings left are the ones to read. The arrow's channel is the one a drag from Load's port to the reference would find, `note-link`: a reference takes what the shape it stands for takes.

**When.** An edge goes through a reference when its ends are on different boards, and only then, unless `via:` asks for one (below). The end that's stood for is the one that's off the board the run draws on ([Which board](#which-board)), and either end may be, so the far one may be the start. The reference is then left of the end that stays, and the arrow runs from it:

```draw
edge "Cutoff" -> "Backfill"
```

**Where the reference goes.** It's a new shape of the run, placed as any new shape is: right of the edge's start when that's the end that stays, left of its end when that is, at the normal gap and centered on it, and kept clear of what's there. If something is in the way it's pushed past, and the result says so as it does for any push; the fix is a side for it. The references beside one shape on one side are a list of their own, 16 apart (a reference has no title above it to leave room for), and move as one: never in a list with a shape your script places there, which stays where its placement puts it while they give way past it. A later run's reference beside a shape that already has a column of them on that side joins it: 16 below its end (above its top, for a column above the shape), in line with it, rather than centered on the shape and pushed past the column. A shape the run moves leaves its column behind, and its new references go beside it where it lands. `from:` or `to:` on the end that stays says which side the reference goes on, and the arrow leaves or arrives there. A side named for the end that's stood for is the reference's own, which takes arrows on its left and right alone, so `top` or `bottom` there is `invalid_value`. Unnamed, the arrow aims at the reference's middle, as it does at any shape's.

**What can be stood for.** A public shape. A shape that isn't can't be reached, and an edge between boards with neither end public is `several_boards`, as it always was; its hint says that only a public shape can be reached, and to ask the user to make one public:

```draw-error
// reason: several_boards
edge "Load" -> "Scratch"
```

With one end public, the run draws on the board of the one that isn't, and puts the reference there. The user made Runbook public, since it's pointed at from all over:

```draw
sticky-note "Runbook" public: true
```

Runbook is public and Scratch isn't, so this draws on Monday's board (the result's `on` says so), with a reference for Runbook below Scratch, where `to: bottom` says the arrow arrives:

```draw
edge "Runbook" -> "Scratch" to: bottom
```

With both ends public the run draws on the start's board, and the reference is for the end.

A shape the script draws is on the board the run draws on, so the reference goes beside it, for the shape on the other board. `in "Monday"` says which board here, as it does for any shape; with nothing else to say, the run draws on the public shape's board and the edge between them is straight there:

```draw
sticky-note "Late file" in "Monday" text: "Arrived after the cutoff"
edge "Late file" -> "Runbook"
```

**`via: reference`** puts a reference beside the start, standing for the end, on one board too: for an end that other edges point at, so that the arrows into it needn't each cross the board. Its value is the kind of shape that stands for others (`reference` is the one shipped), and the end must be one that kind can stand for, a public shape. `via:` is about the end of the arrow, so `edge "B" <- "A" via: reference` is the same edge as `edge "A" -> "B" via: reference`, with a reference for B. The reference goes beside the start, so the run draws on the start's board, wherever the end is; a script that says another board too is `several_boards`. `<->` works the same, with heads at both ends.

```draw
edge "Alerts" -> "Runbook" via: reference
```

```draw-error
// reason: invalid_value
edge "Ingest" -> "Clean" via: reference
```

**Drawing it again.** An arrow between the end that stays and a reference that stands for exactly the other end is the edge, so a run again says `unchanged` (or `reconnected`), draws no second reference, and has `via` on its row, whether or not `via:` is written, and on one board as well as across two. The run goes to the board the arrow is on, whichever board the edge would be drawn on otherwise (the start's, with nothing else to say, where a reference for the start isn't), and the arrow stays the edge when the shape it stands for stops being public. A reference with a `query:` is never the edge, since what it stands for can change. `via:` written over an edge that's drawn straight is `invalid_value`, saying how (`the edge "A" -> "B" is drawn straight to "B"`, with the hint to write `delete edge "A" -> "B"` above the line, which draws it through a reference), and so is `via:` over one that goes through a reference to the start. A side named for the reference is refused as it was the first time:

```draw
edge "Load" -> "Cutoff"
```

```draw-error
// reason: invalid_value
edge "Load" -> "Cutoff" to: top
```

**Two arrows between one pair.** An edge that writes `is:` and isn't drawn yet goes into the reference the start's other arrows already run into for that end, and makes one only if there is none: `edge "Ann" -> "Acme" is: "Mentorship"` beside Ann's `is: "Employment"` is a second arrow into Ann's one reference for Acme, not a second reference, and its row says `shared: true`. Two relationships between one pair are two arrows into one reference. An edge that writes no `is:` makes a reference of its own, as below.

**Sharing one.** Each edge through a reference makes a reference of its own, so five shapes that point at Cutoff have five. `share:` makes them one. It goes on an edge that goes through a reference (across two boards, or with `via:`), and takes two values:

- **`share: true`** draws the arrow into a reference that's there already for the same end: one a line above in this run made, or one the board has (a person's, or an earlier run's), in the same container as the end of the edge that stays on the board: the same frame, or the board, when neither is in a frame. If there's none, it makes one beside the start, as without `share:`.
- **`share: "A"`** draws the arrow into the reference A's own arrow goes into, for the same end. A must be in the same container as the edge's start, and its edge must be above this line, in this run or an earlier one. A that has no such reference is `invalid_value`, naming A and the end: a reference is never made behind the name of another's. Use it when a frame has several references for one end and the arrow should go to a particular one (the one beside A).

Load's reference for Cutoff is there already, made beside Load by the run above, so Ingest and Clean join it rather than make two more:

```draw
edge "Ingest" -> "Cutoff" share: true
edge "Clean" -> "Cutoff" share: "Load"
```

The arrows' rows say `shared: true` (a reference was reused), and, for `share: "Load"`, `sharedWith: "Load"`. The first edge of a group, the one that made the reference, says neither. A reference that nothing was reused for is made where it always was. A run again finds each arrow drawn and says `unchanged` with the same flags (`shared` is then true when an arrow from another shape runs to the same reference). A reference is shared only between shapes in one container, so `share:` never reaches into or out of a frame, and one edge that goes straight (both ends on the board, no `via:`) has none to share, which is `invalid_value`:

```draw-error
// reason: invalid_value
edge "Draft" -> "Cutoff" share: "Retry"
```

```draw-error
// reason: invalid_value
edge "Draft" -> "Review" share: true
```

**Placing the reference.** An edge that goes through a reference may say where the reference goes, in the words a shape takes: placements, and `in` a frame. They place the reference the edge makes, as a shape statement's place a shape, instead of beside the end: at [an exact offset](#an-exact-offset) from a frame it is `in`, say, for a layout worked out elsewhere, where several shapes' arrows meet at one reference between them. The reference is then placed as a shape you wrote: kept to its placements and within what it's in, pushed past what it lands on (said, with `pushedPast`, as for any shape), and never in a list with the references beside a shape. `in` alone puts it against the frame's top-left, 40 in, as it puts a shape. What the placements name is on the board the run draws on, as a shape's is. They place only a reference the edge makes: an edge that reuses one (`share:`, an `is:` beside its pair's) or is drawn already, as in a run again, leaves it where it is; `share: "A"` never makes one, so a placement beside it is `invalid_value`, and so is one on an edge drawn straight. Billing's arrow puts its reference for Runbook in the top-right of Sprint, and Search, in Sprint too, shares it:

```draw
edge "Billing" -> "Runbook" via: reference in "Sprint" right of "Sprint" left (gap: 660) below "Sprint" top (gap: 40)
edge "Search" -> "Runbook" via: reference share: "Billing"
```

```draw-error
// reason: invalid_value
edge "Draft" -> "Review" in "Sprint"
```

**Deleting.** `delete edge "A" -> "B"` takes such an arrow, and `delete "A"` takes all of A's; either takes a reference like this one (standing for one shape) that it leaves with no arrow at all too, since a reference has no title for a script to delete it by ([Deleting](#deleting)). A reference several arrows share stays until the last of them goes. The reference and the arrow are one run and one step of undo, and a dry run says the same as the real one.

## Styles

```text
style <name> attribute { attribute }
```

A style is a named set of attributes for the script it's in, used as `style: <name>`, or several as `style: urgent, late`. It can be defined above or below the shapes that use it.

- It can hold any attribute, `size:`, `gap:` and `overlap:` included. It can't hold `style:` (a style can't take another) or `title:` (a title names one shape), and it can't hold a placement.
- Of several styles, a later one wins. A shape's own attributes win over every style.
- A style can serve several kinds. A key the shape's kind doesn't have is dropped for that shape. A style that gives a shape nothing at all is refused, and so is a style key that no drawable kind has (`style urgent has txet:, which is an attribute of nothing drawn here`, with the hint `did you mean text?`), both `unknown_attribute`. A style of only `size:`, `gap:` or `overlap:` gives every shape something.
- A style used but never defined, defined twice, or named twice on one shape is refused.
- Edges take no style.

```draw
style big size: 300x200
style spaced gap: wide
sticky-note "Fix the loader" right of board style: big, spaced text: "It drops rows with no date"
sticky-note "Backfill March" below "Fix the loader" style: big text: "Rerun once the loader is fixed"
```

"Backfill March" is 160 below "Fix the loader", because a placement's gap is the larger of the two shapes' `gap:`.

## Restating, renaming, deleting

### Restating

A statement whose title is already on the board updates that shape. It changes only what it says.

- **No placements**: the shape stays where it is. A new `size:` grows or shrinks it from its top-left, with a warning if it now overlaps something. A width alone fits a note to its text again at that width, whatever height it was drawn with.
- **With placements**: the shape moves, and is kept clear like a new one. An axis no placement speaks for stays where it was. A lone direction still centers the other axis, as it does for a new shape.
- `did` says what happened: `updated` (attributes changed), `moved` (only when its bounds changed), `renamed`, or `unchanged`. A statement that changes nothing is `unchanged` and never an error, even on a locked shape.
- A locked shape refuses any real change (`read_only`). Saying `locked: false` unlocks it, but that's the user's call.
- Shapes placed against a restated shape by earlier scripts don't follow it. The board keeps positions, not placements. To move a group, restate every member.
- Re-running an old layout script moves its shapes back to where its placements put them, undoing whatever the user moved since, and draws its untitled shapes again. To add to a drawing, write only the new statements.

```draw
sticky-note "Backfill" text: null
```

```draw
sticky-note "Runbook" left level with "Backfill"
```

The first statement clears Backfill's text, without moving it. The second moves Runbook sideways, so its left edge lines up with Backfill's, and keeps its vertical position, since nothing speaks for that axis. Alerts, placed below Runbook in an earlier script, stays where it was.

### Renaming

`title: "New"` on a restated shape renames it (`did: "renamed"`, with `was: "Old"`). The shape can move or change in the same statement. The new title must fold to something, and no other shape on the board or statement in the script may have it (`duplicate`). The kind must be nameable. Other lines in the same script still call the shape by its old title; the new title applies from the next run (but a mention in a text finds it by either, and holds the new one). `title:` on a new shape is refused: a new shape's title goes after its kind. `title: null` is refused too (`unsupported`), and so are `title: none` and `title: nil`: a script renames a shape, but can't take its title away. A title that really is "none" is quoted.

```draw
sticky-note "Nightly schedule" title: "Nightly run"
```

### Deleting

`delete "X"` (or `delete #<id>`, for a shape with no title) removes the shape and every connection with an end on it, each reported as its own `deleted` row: one to another shape with `from` and `to` (one into a reference that stands for one shape, as an edge's does, with `via: "reference"` and that shape as its end), and one whose other end is free (re-aimed off every shape) with neither. `delete edge "A" -> "B"` removes the connections from A to B, and `delete edge "A" <-> "B"` removes them either way round. With `is:` it removes only the arrows of that type: `delete edge "A" -> "B" is: "Friendship"` (`is: null` takes the arrow of no type); without it, every arrow of the pair. `is:` is the one attribute a `delete edge` takes: any other is `unknown_attribute`, and `from:`, `to:`, `via:` and `share:` are a `syntax` error.

- An unknown title is `unknown_title`, an unknown id `unknown_id`. `delete edge` with nothing to delete is `nothing_to_delete`. A locked shape or connection is `read_only`.
- **An edge drawn through a reference** is still the edge from A to B ([Through a reference](#through-a-reference)): `delete edge "A" -> "B"` removes the arrow between one end and a reference that stands for the other (its row has `via`), either way round for `<->`, and `delete "A"` removes A's arrows, those into references too; then each reference that stands for one shape (as an edge's does) and is left with no arrow at all goes, as a row of its own after the arrows'; one that still has an arrow stays (a reference shared by several edges goes with the last), and so does one drawn by its `query:`. The shapes a reference stood for stay. A reference that's locked, or in a locked frame, is `read_only`, and nothing is deleted.
- A shape that holds a board (a subboard) takes its board with it, and every board under that, with everything on them. That isn't refused: a warning says how much went (`"Payments" held a board, and 1 more under it: the 4 shapes on them are deleted with it`), and Undo brings it all back. One whose board, or a board under it, holds a locked shape isn't deleted (`read_only`: `"Payments" holds a read-only shape (locked, say) on its board, so it can't be deleted`).
- `delete edge "A" -> "B"` after `delete "A"` asks for what the delete already does, and is fine, as it is the other way round: A's connections go with it, on the delete's row.
- A shape the script deletes can't be a target in the same script, unless the script draws it again.
- To change a shape's kind, delete it and draw it again in the same script. Its connections go with it, so draw those again too.

```draw
delete edge "Tuesday" <-> "Wednesday"
delete "Archive"
```

```draw
delete edge "Alerts" -> "Runbook"
```

```draw
delete "Owner"
subboard "Owner" above-left of "Ingest"
```

## Groups

```text
group <a> and <b> { and <c> }    put those shapes in one group (two or more)
ungroup <a> { and <b> }          take those shapes out of every group (one or more)
```

A group is something shapes have, not a shape of its own: it has no title and takes no room on the board. Shapes in a group are selected as one in the app: a click on any of them selects them all, and what the user does to the selection (move it, copy it, lock it) is done to them all. Each statement names its shapes by a quoted title or an `#id` ([Titles are the names](#titles-are-the-names)), joined by `and` or commas, as a placement's targets are. A `group` names two or more, an `ungroup` one or more.

- **A group is exactly the shapes you name, flat.** Each leaves the groups it was in and is in the new one alone. The others in a group it left stay a group while two or more of them are left; one left alone is in no group. Shapes that are in a group inside a group leave both.
- **`ungroup` takes a shape out of every group it is in**, at every level. The others stay a group while two or more of them are left.
- **Already as asked is `unchanged`**: shapes that already are one group and nothing else, or that are in no group, change nothing, and a run of statements that change nothing opens no undo step. A shape that still holds the id of a group that no longer counts (the others left it, or were deleted) is in no group.
- **A group is its shapes on one board**, so every title and id must be on the board the script draws on, as a placement's target must: shapes on two boards are `several_boards`. Name shapes on a subboard's board, and the run draws there. A group may hold shapes of different kinds, a frame and the notes beside it, say.
- **A shape is named once in a script**, by one `group` or `ungroup`: named twice, in one statement or in two, by its title or its id, is `duplicate`.
- **Shapes the script draws can be named**, above or below the statement that draws them, new or restated, by the title the statement calls them: groups and ungroups are applied last, in the order written. The deletes are done before, so a shape the script deletes can't be named.
- **A shape that is locked, or in a locked frame, or on a locked subboard's board, is `read_only`** if the statement would change what it is in; a statement that changes nothing goes through. An arrow and a reference have no title, and an id of one is `invalid_value`, as it is anywhere else.
- **The row** has `line`, `did` (`grouped`, `ungrouped` or `unchanged`) and `shapes`, in the order written, each by its title; it has no `kind`. `--dry-run` says the same and changes nothing, and `canvas measure` leaves both statements out.

Login bug, Billing and Search are the notes in Sprint. Group all three, then make a group of two of them, which takes those two out of the first, and leaves Billing in none:

```draw
group "Login bug" and "Billing" and "Search"
```

```draw
group "Login bug" and "Search"
```

Ungroup takes a shape out of its group, and the other is then alone:

```draw
ungroup "Login bug"
```

A group of one is refused, and so is a shape named by two statements, and shapes on two boards (Cutoff is on Monday's board):

```draw-error
// reason: syntax
group "Billing"
```

```draw-error
// reason: duplicate
group "Billing" and "Spike"
ungroup "Billing"
```

```draw-error
// reason: several_boards
group "Billing" and "Cutoff"
```

## References

A script draws a reference in one of two ways. As an edge's stand-in it's a direct one, standing for the one shape on the other end ([Through a reference](#through-a-reference)): the statement is the edge, and never names the pill. On a statement of its own it's drawn by its query: it stands for what the query finds among the file's public shapes (the first in file order, or with `all: true` every one, up to fifty), and the app finds it a moment after the script, and again whenever the file changes. `canvas query` waits for that answer (up to two seconds) before it reads edges, so a query just after the script reads arrows into the pill as arrows into what it found. A script can't pick the shape a pill stands for or type words into it: those are the user's. [references.md](references.md) is what a reference does to what you read.

```draw
reference above "Owner" query: "sticky-note[public]" all: true
```

A query the app can't read is refused with the query language's own message, and nothing is drawn:

```draw-error
// reason: invalid_value
reference above "Owner" query: "sticky-note[public"
```

So is one that reads what the person is doing (`:selected`, `:current-board`), since a reference's query is kept and run later, whoever is looking:

```draw-error
// reason: invalid_value
reference above "Owner" query: "sticky-note:selected"
```

## How a run is applied

1. **Read.** Every line is read. Lines that can't be read are reported together, up to 20.
2. **Resolve.** Kinds, titles, attributes (JSON member by member), styles, placements' targets, each edge's ends and attribute keys, each delete's shape and connections, and the shapes each group and ungroup names are checked against the board as it is. An edge that goes through a reference ([Through a reference](#through-a-reference)) adds the reference to the run as a shape of its own here, with the placements the edge writes for it, or beside its end. Mistakes that don't depend on each other are reported together here too.
3. **Place.** Positions are worked out against the board as it is, the references an edge goes through placed as any new shape is. Only the first placing error is reported, since one mistake there makes others.
4. **Apply**, in one change or not at all. Deletes come first (a reference that a delete leaves with no arrow among them), then new and restated shapes (each after any shape the script draws or restates that it's placed `inside` or `on`, a reference an edge goes through among them), then edges, then groups and ungroups, in the order written (so they may name a shape the script draws). Each edge's channel and sides are checked as it's drawn, one at a time: the first that's wrong (`no_channel`, `cannot_connect`, a channel or side that's `invalid_value`, `ambiguous_edge`, `read_only`) is the error, and nothing is drawn. The result and its warnings are read from the changed board.

A dry run goes through all four steps and then throws the change away.

- If someone is dragging on the board, the run is refused (`busy`). Try again in a moment.
- If the user is typing in a shape the script changes or deletes, a real run that would change that shape finishes their typing first, so their last words land before the change (and the script is worked out again if they changed the board). It's tried first, so a run that fails, even on an edge, or leaves that shape as it is, and a dry run, leave their typing alone.
- The selection is left alone. So is the camera, unless the command says `--reveal`.
- A run is one step of the app's undo, called Draw: Edit › Undo Draw (⌘Z) takes the whole run back. A dry run, or a script that fails, makes none.

## The result

An illustration (not the board on this page):

```json
{"board": {"id": 2, "name": "Pipeline", "shows": "root", "showsPath": ["root"]},
 "changes": [
   {"line": 3, "did": "created", "kind": "sticky-note", "title": "Ingest", "at": [[400, 300], [200, 200]], "inView": true},
   {"line": 4, "did": "moved", "kind": "sticky-note", "title": "Backfill", "at": [[380, 580], [200, 200]], "inView": true, "pushedPast": ["Vendor"]},
   {"line": 5, "did": "renamed", "kind": "sticky-note", "title": "Nightly run", "was": "Nightly schedule", "at": [[940, 580], [200, 200]], "inView": false},
   {"line": 6, "did": "deleted", "kind": "sticky-note", "title": "Archive"},
   {"line": 7, "did": "connected", "kind": "arrow", "from": "Ingest", "to": "Clean", "channel": "note-link"},
   {"line": 8, "did": "created", "kind": "reference", "at": [[1180, 434], [106, 32]], "inView": true},
   {"line": 8, "did": "connected", "kind": "arrow", "from": "Load", "to": "Cutoff", "channel": "note-link", "via": "reference"},
   {"line": 9, "did": "unchanged", "kind": "sticky-note", "title": "Load"},
   {"line": 10, "did": "updated", "kind": "sticky-note", "title": "Order 12", "at": [[400, 300], [320, 236]], "inView": true,
    "problems": [{"field": "customer", "path": "/customer", "class": "needed", "message": "customer is needed"},
                 {"field": "lineItems", "path": "/lineItems/0/quantity", "class": "wrong", "message": "line items › Mug › quantity must be at least 1"}]}
 ],
 "warnings": [{"line": 4, "message": "\"Backfill\" was pushed right past \"Vendor\" to keep clear of it, …", "severity": "warning"},
              {"line": 10, "message": "\"Order 12\": \"emial\" isn't a field of Order", "severity": "warning", "attribute": "fieldValues"},
              {"line": 10, "message": "\"Order 12\": line items › Mug › quantity must be at least 1", "severity": "error", "attribute": "lineItems"}],
 "dryRun": true}
```

- **`board`**: the file it ran on, as `canvas boards` lists it: its `id` and `name`, and the board inside it the window shows, `shows` (`"root"`, or the id of the shape that owns it) and `showsPath` (from the root down).
- **`on`**: the board the script drew on ([Which board](#which-board)): `board` (`"root"`, or the id of the shape that holds it), that shape's `title`, and whether the window `shown` it.
- **`changes`**: a row for each thing done, with its `line`. `did` is `created`, `updated`, `moved`, `renamed`, `unchanged`, `deleted`, `connected`, `reconnected`, `grouped` or `ungrouped`. A shape's row has its `kind` and `title`, its `id`, and `at`, its bounds as `[[x, y], [width, height]]` in world units (top-left first, y down). A connection's row has `from`, `to` (a title, or for an end with none the id as written, plus `fromId` or `toId` for each end the statement named by id; on a `deleted` row, an end the statement named by something else than an id and that has no title is `<kind> at x,y`) and `channel` (if it's on one) instead, and `via: "reference"` when it goes through one, with `shared: true` when its reference was one that was there already and `sharedWith` the title of the shape it was beside when the edge named one (`share:`) ([Through a reference](#through-a-reference)). A reference an edge made has a row of its own on the edge's line, before the edge's: `created`, with `kind: "reference"` and `at`, and no title. One a delete took (`delete edge`, or `delete` of a shape whose arrows ran into it) is a `deleted` row with its kind alone, after the arrows'. **`id`** is on the row of every shape the file has after the run, the one a query's row gives: a `created` row says it after a real run, and a dry run's has none (the shape isn't made, so it has no id yet); a `deleted` row says it only when the statement named the shape by its id. It is how a shape with no title is named by a later script ([Titles are the names](#titles-are-the-names)). A `group` or `ungroup`'s row has `shapes`, the shapes it named in the order written, each by its title (an id as written for a shape with none), and no `kind` ([Groups](#groups)).
- **`inView`**: whether the shape landed in the window (on a board the window doesn't show, in the part of it the window shows when it's opened).
- **`pushedPast`**: what the shape was pushed past to keep clear ([Keeping clear](#keeping-clear)).
- **`was`**: a renamed shape's old title.
- **`problems`**: on a shape whose types say something of its values, what it still needs and what's wrong, field by field: `field` (its key), `path` (where in `fieldValues`, as `/lineItems/0/quantity`), `class` (`needed` or `wrong`; `warning` for an arrow's end that cannot be read) and `message`, as the panel says it. A rule across fields has neither `field` nor `path`. A note's relationship row has the row's name as `field` (`staff is needed`, `class` `needed`; `jobs has 2 notes, and should have at most 1`, `class` `wrong`), and no `path`. On every row of such a shape, `unchanged` too; none when there's nothing. The check reads the types wherever they are, and a type the same script draws or restates.
- **Members a type's owner adds to a row**, flat beside the rest, left out when empty, on an `unchanged` row as on the first run's: `is` (an arrow's types, by their titles; on a `deleted` arrow the types it had), `endOf` (an arrow that is an end of a relationship type: `{"type", "side": "from" or "to", "row", "needed", "onlyOne"}`), `fits` (a plain arrow between two notes: the relationship types that would take it, which `canvas draw` never picks for you: write `is:`) and `relates` (a relationship type: `{"from", "to"}`, the titles of the types it runs from and to, or `"anything"`). A relationship's `problems` have `field` `from` or `to` for an end that doesn't fit; the run says it again as an `error` warning. [relationships.md](relationships.md) has them on a story.
- **`dryRun`**: `true` on a dry run, when nothing was changed.

The run succeeds with these **warnings**, each with its `severity`, the `line` of the statement it's about (the counts, and an issue that several statements brought to one shape together, have none), and the `attribute` it's about, when it's about one:

- every validation issue on each shape made or changed, errors included, like a type's `A schema must be a JSON object.` An `error` means the board outlines that shape in red; a value that's wrong for its field is one, an error on the field's key. What a shape you made still needs is not one (its row's `problems` say it);
- every validation issue the run brought to a shape it did not make or change, named by its title, else by its id, `#7C1E…` (an arrow or a reference by its kind and where it is, `arrow at 120,340`), and `on "Area"'s board` on another board, with the line of the statement that brought it: `"Ann": jobs has 2 notes, and should have at most 1` on the line of the edge that drew her second job, a note whose value a restated type makes wrong on the type's line. What a note still needs is said too, with `severity` `incomplete`: `"Initech": staff is needed` when a delete leaves its Needed row empty, a note without the field a restated type now needs; no error, and the board shows nothing for it. Only what is new: an issue the shape had before the run is not said, nor one the run mends. At most 20 shapes, then `and 31 more shapes now have issues: ask canvas query ":invalid, :warned, :incomplete"`;
- a `fieldValues` member no field of the shape's types names (`"emial" isn't a field of Order`), kept;
- an arrow that says nothing: between two types, or two relationship types, from a relationship type to a note, with `endRule:` on an arrow that is no end, or with a type that isn't a relationship type (`“Friendship” isn't a relationship type, so nothing checks this arrow's ends. Mark it with relationship: true.`), and a `delete edge` with no `is:` that took a typed arrow;
- every schema bound a value breaks, like a title over 80 characters;
- every push;
- sides that face away;
- titles that nearly match one on the board;
- how many shapes landed outside the view (`3 shapes landed outside the view — --reveal brings them into view`), unless `--reveal` brought them into view;
- a shape that hangs over the edge of a zone it sits on (placed against something in it, restated, or placed against the view);
- a shape nudged into or out of a frame, over whose edge it was put down (`"N" was over the edge of "Sprint", so it was nudged in`), and how many shapes a frame put down or resized nudged across its edge;
- a restated shape resized in place that now overlaps something;
- what a shape it drew names that isn't there: a note whose `text:` mentions a shape that isn't in the file, or is on a board the app can't show (`"Plan": text names shapes that aren't in the file: <id>; they show as missing`);
- a deleted subboard's board, and what was on it.

As text, for a person at a terminal, each row leads with its line and what it did, and warnings are printed whole, their message last.

## Measuring a script

`canvas measure <script>|-` takes a script as `draw` does and says how big its shapes would be, without drawing anything. It is for a tool that lays shapes out before it draws them, and has nothing to do with writing a script by hand. It changes nothing and opens no undo step. Every shape is new, whatever the board holds. With a board (the one in front, or `--board`), an `is:` finds a type of that board's file as `draw` does; with none open, only one the script draws. A name it can't find (an `is:`, a mention) is a warning, and the shape is measured without it, or with the text as written. Where shapes go is ignored: placements, `in` (a shape's, or an edge's for its reference), `delete`, `group` and `ungroup` do nothing, and a placement against a shape that isn't there isn't an error. Its edges are read, so the notes of a type are measured with the rows the script's own ends give them (a type, a relationship type, its ends and the notes in one script measure as a run of it draws them, with a board too: the ends the board has count; but a relationship type the script restates is a new shape there, with none of the ends the board has, so restate its ends with it or leave it out), and an edge whose end it can't find is a warning, left out. An edge that says `via:` is only a reference's size. A script `draw` can't read is refused with `draw`'s own messages. The answer is one JSON object:

```json
{"shapes": [{"line": 1, "title": "Checkout v2", "kind": "sticky-note", "size": [300, 200], "above": 27}],
 "references": [{"line": 4, "for": "Hub", "size": [91, 32]}],
 "constants": {"gaps": {"none": 0, "tight": 40, "normal": 80, "wide": 160}, "defaultGap": 80, "listStep": 64, "referenceStep": 16,
               "horizontalClearance": 40, "verticalClearance": 64, "frameInset": 40, "smallest": {"frame": [96, 64]}},
 "warnings": [{"line": 3, "message": "\"Order 13\": is: there's no shape called \"Ordr\"; measured without it"}],
 "board": {"id": 1, "name": "Orders", "shows": "root", "showsPath": ["root"]}}
```

- **`shapes`**: a row for each shape statement, with its `line` and `kind`. `size` is `[width, height]` as `draw` would make it: the kind's own size or the one written, and a note's height from its text (a width alone, `size: 300x`, the height that follows). `title` is the one `draw` would report; `above` is how far the shape's title row and chips reach above its top edge, in world units at 100% zoom (27 for a shape with a title: 9 clear, 18 tall; 0 for one with none, or too narrow to show it).
- **`references`**: a row for each edge that says `via:`, with its `line`, `for`, the end the reference stands for, and `size`, the pill `draw` would make for that title (at most 280 wide). An edge without `via:` has none: whether it goes through a reference depends on the boards, which `measure` doesn't place on (its ends are taken as on one board).
- **`constants`**: what placement is done with, read from the same source `draw` is. `gaps` are the named gaps (`gap: tight`); `defaultGap` how far apart a placement holds two boxes when nothing says (a reference from its start); `listStep` the step between the members of a list, and `referenceStep` between the references beside one shape; `horizontalClearance` and `verticalClearance` what two boxes pushed apart are left; `frameInset` how far `in "F"` puts what it holds from F's top-left corner; `smallest` the least size of each kind that has one, which a `size:` under is refused.
- **`warnings`**: each a `line` and a `message`, for a name `measure` couldn't find; left out when there are none.
- **`board`**: with a board, the one it read, as `boards` lists it; none without.

## Errors

When a run fails, nothing changes. The error goes to standard error:

```json
{"error": {"reason": "unknown_title", "message": "there's no shape called \"Injest\"", "hint": "did you mean \"Ingest\"?", "status": 1,
           "line": 3, "statement": "sticky-note \"Notes\" right of \"Injest\"",
           "errors": [{"line": 3, "statement": "sticky-note \"Notes\" right of \"Injest\"", "reason": "unknown_title", "message": "…", "hint": "…"},
                      {"line": 5, "statement": "edge \"Notes\" -> \"Laod\"", "reason": "unknown_title", "message": "…", "hint": "…"}]}}
```

`reason` is what to branch on. `message` names the statement in its own words: its title, or `the note on line 3` for an untitled one, with placements quoted back as written. `hint` is usually the line to write instead. `line` is the line it's about, or the later of two. `statement` is that line as written, without its comment. `errors` is there only when more than one mistake was found (mistakes that don't depend on each other, found reading and resolving): the first leads, and `errors` lists them all, the first too. With one, read `line`, `statement` and `hint`. As text, it reads `canvas: line 3: <message>`, then the statement, then `hint: …`, then each further error.

The messages below are examples. The wording can differ, but the reason doesn't.

| reason | what it means, with an example message | the fix |
|---|---|---|
| `syntax` | The line can't be read. `sticky-note: Web isn't quoted, and titles are in double quotes` · `edge: --> isn't an arrow` · `--> joins shapes only in an edge statement` · `edge "A" -> "B": "calls" is a title where none goes` (an edge's text is `text: "calls"`) · `titles and text are in straight double quotes: "Web"` · `sticky-note "A": rigth isn't a placement` · `# doesn't start a comment here` · `attributes are written key: value, without braces` · `an attribute is written key: value, not key = value` · `group "A": a group is two shapes or more, and this names one` · `group "A": "B" is a title where none goes` (shapes are joined by `and`) | Follow the hint, which names what to write. |
| `unknown_kind` | The first word isn't a kind the app has. `node "Web"`, with the drawable kinds listed, and the one like it named (`note`: `did you mean sticky-note?`) | Use a kind from `canvas kinds`. |
| `not_placeable` | The kind exists but no tool places it, like an arrow. | Draw an arrow as `edge "A" -> "B"`. |
| `unknown_attribute` | The key isn't one the kind takes. `"Backfill" is a sticky-note and has owner:, which isn't one of a sticky-note's attributes`, with the hint `a sticky-note takes size:, gap:, overlap:, style:, title:, locked:, public:, text:` · a style that gives a shape nothing, or has a key nothing takes | Use one it takes (Did you mean), or drop it. |
| `invalid_value` | The value doesn't fit the key. An id of a shape a title couldn't name (`#7C1E… is an arrow, which a script can't name`: an arrow, a reference) · `locked: maybe isn't true or false` · `size: huge isn't a size` · `gap: wdie isn't a gap` · a size or gap over 100000 · `from: middle isn't a side` · `channel: note-lnk isn't a channel` · a JSON member the object doesn't have, or a value of the wrong type in it · with `channel:` written, a side the kind has no port on · another channel for an edge already drawn (`the edge from "A" to "B" is on note-link, not on subboard-link`) · a head its arrow doesn't say (`edge "A" -> "B": startArrowhead: true isn't what the edge as written says`) · a mention in a text of a shape it can't mention, or `@[]` with no title (its hint, like `unknown_title`'s, says how to write the characters `@[`; the others' say how to mend the mention) · `via:` with a kind that stands for nothing (`edge "A" -> "B": via: tile isn't a kind of shape that stands for others`, the hint listing the kinds that do) or for a shape that can't be stood for (`edge "Ingest" -> "Clean": via: reference can't stand for "Clean": only a public shape can be stood for`) · `via:` over an edge drawn straight (`the edge "A" -> "B" is drawn straight to "B"`) or through a reference to the other end · a side named for a reference that has no port on it (`to: top: a reference has no ports on its top`) · `share:` with a value that isn't `true` or a title (`share: false`), on an edge drawn straight (`edge "A" -> "B": share: is for an edge that goes through a reference, and this one is drawn straight`), naming the edge's own start, or a shape that has no reference for the end (`edge "Draft" -> "Cutoff": share: "Retry" has no reference to "Cutoff" beside it`) or isn't in the start's container | Write a value of the kind the hint names. For `share:`, draw the host's edge above the line, or write `share: true`, or leave `share:` out. |
| `duplicate` | Something is written twice. `"locked" is written twice (true, false)` · a title stated on two lines (`written twice, here and on line 4`) · a rename to a title another shape has · two edges for one pair · a style defined twice · a shape named twice by `group` and `ungroup` (`"Billing" is named twice, here and on line 1`) | Keep one. |
| `not_an_id` | A word after `#` where a statement names a shape isn't an id. `# takes a shape's id, and #Services isn't one` · an id of the wrong length or with a character that isn't a hex digit | An id is what a query's row gives: 36 characters, hex digits in groups of 8, 4, 4, 4 and 12. A title is in double quotes. |
| `unknown_id` | No shape the app can show has that id. `there's no shape with the id #7C1E…` · one on a board the app can't show · one kept aside · one the script deletes, `an edge is drawn to #7C1E…, which this script deletes` | Run the query that gave the id again: the shape may have been deleted. An id never makes a shape; to make one, write its kind and a title. |
| `unknown_title` | No shape has that title. `right of "Injest"`, with up to 3 near titles · `board` on an empty board · a mention in a text, `"Plan": text: there's no shape called "Lod"` · a title only a shape the script deletes has, `"Plan": text: names "Old", which this script deletes` | Write the title exactly (`did you mean "Ingest"?`). On an empty board, leave one shape unplaced instead. If a text meant the characters `@[`, write `\\@[`. |
| `ambiguous_title` | Two or more shapes have the title, each listed with its kind and where it is · the title is on two boards, neither the one the window shows: `"Retry" is on 2 boards: "Payments"'s board and "Billing"'s board` · a mention in a text of a title two shapes have where it's first found (`the board has 2 shapes called "Address": …`) | Ask the user to rename one. Titles only work as names while each is used once. For two boards, say which with `in "Payments"`. |
| `several_boards` | The script lands on two boards, and a run draws on one. `this script draws on "Payments"'s board ("Retry", line 1) and on the root board ("Ingest")` · a placement between shapes on two boards · an edge between shapes on two boards that a reference can't join, because neither end is public (`this script draws on the root board ("Load", line 2) and on "Monday"'s board ("Scratch")`, whose hint says only a public shape can be reached and to ask the user to make one public) · `via:` with a start on a board the run doesn't draw on · a `group` of shapes on two boards | Split it into a run for each board. An edge joins shapes on one board, or goes into a reference for a public shape on another: if the user wants the edge, ask them to make that shape public. |
| `cannot_contain` | `in` names a shape that holds no shapes: no subboard, and no frame. `"Notes" is a sticky-note, which holds no shapes` | Name a subboard or a frame. To put a shape over another, use `inside` or `on`. |
| `board_shown` | A delete would take the board the window shows, or one above it: `"Payments" holds the board the window shows, so it can't be deleted` | `canvas show --root` (or a board above it) first, if the user wants it gone. |
| `ambiguous_edge` | `"A" -> "B" is drawn 2 times` (straight, or through references) | Write `is:` to say which, or `delete edge "A" -> "B"` above the line, then draw it once. |
| `untitlable` | The kind can't be given a title: `a <kind>'s title is worked out from what it is`, or `a <kind> has no title` | Leave the title out, and don't plan to name it later. |
| `renames` | The change would take away the name of a shape whose name comes from what it is (`this would leave "Row" without a title`); no shipped kind's name is | Keep what names it. |
| `wrong_kind` | The title belongs to a shape of another kind. `"Ingest" is a sticky-note` | Use its kind, or change it with `delete "Ingest"` and a new statement in the same script. |
| `read_only` | The shape or connection is locked, or in a locked frame, or on a locked subboard's board (at any depth), and the change would really change it; or a new shape or edge would go in a locked frame, or on a board that's read-only. `"Ship" is read-only (locked, say), so it can't be deleted` · `one of "Ingest"'s connections is read-only (locked, say), so "Ingest" can't be deleted with it` · a subboard whose board holds a locked shape, deleted · `the reference that delete edge "A" -> "B" leaves with no arrow is read-only (locked, say), so it can't be deleted` · `"Sprint" is read-only (locked, say), so nothing goes in it` (a frame, or a subboard with `in`) · `"N" would go in "Sprint", which is read-only (locked, say)` · `"N" would go on "Plans"'s board, which is read-only (locked, say)` · `edge "A" -> "B" would go on "Plans"'s board, which is read-only (locked, say)` · `"Ship" is read-only (locked, say), so it can't be grouped` (or `ungrouped`) | Tell the user. Leave it, or ask them to unlock it. |
| `unplaced` | Nothing says where a shape sits. `"Between" does not say where it sits vertically: right of "Ingest" and left of "Load" would put it in different places` · `exactly one new shape may say nothing about where it goes, but 2 do: "Idea one" and "Idea two"` · `"N" says nothing about where it sits horizontally` | Add a placement for that axis (the hint names one), or place all but one shape. |
| `unanchored` | Shapes are placed only against each other, with nothing tying them to the board. `nothing ties "Left half" to the board horizontally` | Place one against a shape on the board, `board` or `view`, or leave exactly one unplaced. |
| `no_room` | The placements can't all hold. `"Squeeze" is right of "Ingest" and left of "Clean", and there's no room between them` · `… clear of "Q"` · `"N" is inside "Z" top-left, and there's no room left in "Z"` · `"Wide" is in "Sprint", and there's no room left in "Sprint"` | Drop or change a placement, or ask for a smaller gap. Shapes on the board don't move, so to make room, restate them with placements. |
| `circular` | `"Loop" is placed against itself`, or in itself (`in`), or two shapes wait on each other: `"N" is level with "A" and "B", but "B" is placed vertically against "N" in turn` | Place one of them against something else. |
| `unordered` | Two shapes would overlap and nothing says which side of the other either sits on. `"North" and "Far north" overlap, and nothing says which side of the other either one sits on` · `"N" is on "P" and can't move, but it overlaps "Q"` | Place one against the other, place it elsewhere, or say `overlap: allow`. Held on an empty zone, the hint says so: place it elsewhere, or, if the zone is meant to hold shapes, put a first one `inside` it. |
| `no_channel` | The edge's ends share no channel, on the sides named if any, or the channel written isn't one both ends take. `"Ingest" and "Sprint" share no channel: a sticky-note connects on note-link, a frame has no ports` · `a connection on note-link can't end where it starts` | Connect like to like (or to a subboard), name a side that has the port, or say `channel: none`. |
| `cannot_connect` | The app won't connect that end at all, and the message names the end. | Connect a different shape. |
| `no_edges` | No plugin in this app draws connections. | Draw shapes only. |
| `no_names` | No plugin in this app names shapes, so titles can't be matched. | Titled statements can't work in this app. |
| `no_groups` | No plugin in this app groups shapes: `group` and `ungroup` can't work. | Leave them out. |
| `no_view` | `view` was named, but the board's window has no size. Under the kind's smallest it's `invalid_value`, with the size to write. | Place against a shape or `board`, or leave one shape unplaced. |
| `unsupported` | Something the language doesn't do. `an edge joins two shapes, and this one goes on to a third` · `in` a subboard or frame this script draws · a placement against a shape in a frame the script moves · `frame: says where "N" is, and there are no coordinates here` · `x: would say where "N" is, and there are no coordinates here` · `"N" is new, and title: renames a shape` · `title: null would take the shape's title away, and a script only renames` | Leave it out, write each edge on its own line, place the shape instead, or put the title after the kind. |
| `nothing_to_delete` | `delete edge` found no connection. | Check the direction, or use `<->`. |
| `busy` | Someone is dragging on this board. | Try again in a moment. |
| `empty_script` | The script has no statements (comments and styles don't count). | Write at least one shape, edge or delete. |
| `internal` | A bug in the app. | Report it, with the script. |
| `no_board` | No board is open. | Make one, `canvas new <file>`, or ask the user to open one. |
| `ambiguous_board` | Several boards are open and none is in front, or two open boards have the name `--board` gives. | Name one by its id, from `canvas boards`. |
| `unknown_board` | No open board has that id, file or name (an id goes when its board closes). | Run `canvas boards` and use an id it lists. |
| `file_exists` | `new` was given a file that's there already, or that a board open is. | Use that board (`--board`, with the id the message names, if it's open), or name another file. |
| `no_folder` | `new` was given a file in a folder that isn't there. | Make the folder, or name a file in another. |
| `cannot_save` | `new` couldn't save the file there (no permission, say). | Name a file somewhere else. |
| `usage` | The command line is wrong (exit 2): no such command or option, a value that isn't one, `--board` on a command about the app, or standard input that can't be read or isn't UTF-8. | Follow the hint; `canvas help draw` says what `draw` takes. |
| `not_running` | The app isn't running (exit 3). | Start Infinite Canvas (in its repository: `./build.sh && open build/InfiniteCanvas.app`). |
| `unreachable` | The socket can't be reached (exit 3), usually a sandbox. | Ask the user. |
| `protocol_mismatch` | The app and this `canvas` were built apart, and speak different protocols (exit 3). | Ask the user to quit the app and open the one this `canvas` came with. |
| `timed_out` | The app didn't answer in time (exit 3); it may still do it. | Don't run it again: dry-run it to see what landed ([Running a script](#running-a-script)). |

These fail on the board as the examples above left it:

```draw-error
// reason: syntax
sticky-note Web right of "Ingest"
edge "Ingest" --> "Clean"
# Pipeline
```

```draw-error
// reason: unknown_kind
node "Web" right of "Ingest"
```

```draw-error
// reason: not_placeable
arrow right of "Ingest"
```

```draw-error
// reason: unknown_attribute
sticky-note "Backfill" owner: "Ann"
```

```draw-error
// reason: invalid_value
sticky-note "Backfill" locked: maybe
```

```draw-error
// reason: duplicate
sticky-note "Clean" text: "Drop the bad rows"
sticky-note "Clean" text: "Drop the empty rows"
```

```draw-error
// reason: unknown_title
sticky-note "Notes" right of "Injest"
```

```draw-error
// reason: wrong_kind
subboard "Ingest"
```

```draw-error
// reason: unplaced
sticky-note "Idea one" text: "Try a cache"
sticky-note "Idea two" text: "Try a queue"
```

```draw-error
// reason: unplaced
sticky-note "Between" right of "Ingest" left of "Load"
```

```draw-error
// reason: unanchored
sticky-note "Left half" left of "Right half"
sticky-note "Right half" right of "Left half"
```

```draw-error
// reason: no_room
sticky-note "Squeeze" right of "Ingest" left of "Clean" level with "Ingest"
```

```draw-error
// reason: circular
sticky-note "Loop" right of "Loop"
```

```draw-error
// reason: unordered
sticky-note "North" above "Clean"
sticky-note "Far north" above "Clean" (gap: wide)
```

```draw-error
// reason: syntax
edge "Ingest" -> "Clean" "then"
```

```draw-error
// reason: invalid_value
edge "Ingest" -> "Clean" startArrowhead: true
```

```draw-error
// reason: nothing_to_delete
delete edge "Ingest" -> "Load"
```

```draw-error
// reason: empty_script
```

## What canvas kinds says

`canvas kinds` is the vocabulary, and `canvas kinds <kind>` narrows it to one kind. For each kind it gives:

- `kind`, `title` (what the app calls it) and `tool` (the tool named for it: the one that places it).
- `drawable`: whether a script can draw it, with the reason if not (`why`).
- `names`: `named` (a title you give it), `derived` (worked out from what it is), or `none`.
- `size`: what its tool places, like `"200x200"`.
- `smallest`: the smallest its shapes are drawn, like `"96x64"` (a frame's), the same for its tool and resizing; a `size:` under it is `invalid_value`. Absent where any size goes.
- `holds`: what its shapes hold, for `in` to name: `board` (a subboard's, a board of its own) or `shapes` (a frame's, on the board it's on); absent for neither.
- `attributes`: each attribute a script can set, with a compact type. The types are a set's words joined by `|`, `true|false`, `number ≥ 0`, `integer`, `text`, `text (≤ 80)`, `date (YYYY-MM-DD or date-time)`, and JSON shapes like `JSON [{done, text}]` (members in alphabetical order; an id nobody writes, like a list item's, isn't listed). A text a plugin writes says what it takes after its type, in brackets: `text (@[Title] mentions)` for a note's `text`, so a value's refusal hint (`text: takes text (@[Title] mentions)`) says it too. Keys a script can't set, like the frame, aren't listed.
- `edges`: the channels an edge from it can take, by side.

`--schema` adds each kind's full JSON Schema. As text, for a person at a terminal, each kind's attributes and edges are listed under its row.

## What the language refuses

These are left out on purpose. What they protect is that the app never chooses an arrangement for you. It works out the one your sentences describe, and refuses the rest.

- **Coordinates**, in any form, including as an escape hatch. A position is always said against something named, an exact one too ([An exact offset](#an-exact-offset)). The board stores positions, and the script never sees them.
- **Guessing an axis.** When nothing settles an axis, or two placements settle it differently, the app refuses rather than picking a row or a column.
- **Two drawings with nothing to hang on.** Only one shape per script may be unplaced, because two unrelated drawings would have to be put somewhere relative to each other, and that's a choice.
- **Overlap without an order.** When two shapes would overlap and nothing says which side of the other either sits on, it's refused rather than split the difference.
- **Placements that run in a circle.** A loop where each placement demands more room than the last can't hold, and it's reported with the placements on it.
- **Hidden names.** Titles are the only names, so what a script says is what a person reading the board sees.
- **Remembered placements.** A placement is worked out once. Shapes don't follow each other afterwards, because the user moves things, and a board that moved them back would fight the user.
- **Moving what the script doesn't mention.** Shapes the script doesn't restate stay exactly where they are. Room is made by restating them, never by pushing them.

## Not built yet

- **Reading positions back.** `canvas query` ([query.md](query.md)) lists a file's shapes, their titles and attributes, what's inside what and what's connected to what, but not where a shape is: only a script's result says where what it drew landed.
- **Drawing on two boards in one run**, a subboard and what goes in it among them: draw the subboard, then its contents with `in` in a run of their own. The same for a frame and what goes in it, though they're on one board. An edge to a public shape on another board is the one thing that reaches across, and it draws only the reference it goes into ([Through a reference](#through-a-reference)).
- **Moving a shape to another board.** `in` a subboard places a new shape; a shape restated stays on its board. (`in` a frame moves a restated shape into it.)
- **Frames that grow** to fit what's drawn in them. Zones are plain shapes, and their contents are placed once; a frame holds what's in it.
- **Routing.** A line may cross shapes it has nothing to do with. There's no `between` or `below "X"` for edges yet.
- **Extending a list** across runs, other than by restating every member.
- **Chains** (`edge "A" -> "B" -> "C"`).
- **Commands from the plugins that own a concern.** Everything goes through `draw` for now.

---

The language and its solver are modified from [reladraw](https://github.com/reladraw/reladraw) (Apache-2.0; see THIRD_PARTY_NOTICES.md at the repository's root): its placements, parts, lists, one unplaced shape, refusing rather than guessing, and the way distances are solved. What differs comes from drawing on a live board. Shapes already there are fixed and are obstacles, restated shapes move on their own, and a drawing with nothing to hang on goes where the window is. This language isn't called reladraw.

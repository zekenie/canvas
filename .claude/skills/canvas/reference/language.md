# The canvas draw language

The whole language `build/canvas draw` reads: every statement, word and rule, how a script's placements become positions, what comes back, and every way a script can fail. [../SKILL.md](../SKILL.md) is the tour; this page is where to look when you need a construct the tour doesn't cover, or when an error points at behavior you didn't expect.

The examples on this page are one story. They run in order on one empty board: each block tagged `draw` succeeds there, and later blocks name shapes that earlier blocks drew. Each block tagged `draw-error` fails with the reason on its first line, and changes nothing. The shapes are the kinds that shipped when this was written. `build/canvas kinds` says what your app has.

## Contents

- [Running a script](#running-a-script)
- [Lines and words](#lines-and-words)
- [Statements](#statements)
- [Shapes and titles](#shapes-and-titles)
- [Attributes](#attributes)
- [Placements](#placements)
- [How placements combine](#how-placements-combine)
- [Gaps](#gaps)
- [Lists](#lists)
- [Keeping clear](#keeping-clear)
- [A drawing with nothing to hang on](#a-drawing-with-nothing-to-hang-on)
- [Inside, outside, on, and zones](#inside-outside-on-and-zones)
- [Edges](#edges)
- [Styles](#styles)
- [Restating, renaming, deleting](#restating-renaming-deleting)
- [How a run is applied](#how-a-run-is-applied)
- [The result](#the-result)
- [Errors](#errors)
- [What canvas kinds says](#what-canvas-kinds-says)
- [What the language refuses](#what-the-language-refuses)
- [Not built yet](#not-built-yet)

## Running a script

```bash
build/canvas draw --board 2 --dry-run - <<'EOF'
sticky-note "Inbox" text: "Everything new lands here"
EOF
```

`build/canvas draw <script>|- [--dry-run] [--reveal] [--board <board>]`

- **The script**: `-` reads it from standard input. Use a heredoc with a quoted delimiter (`<<'EOF'`), which passes every character through untouched. With an unquoted delimiter the shell expands `$` and backticks and turns `\\` into `\`. The script can also be the one argument, but quoting it for the shell is error-prone, and an apostrophe in a title breaks it.
- **`--dry-run`** does everything a run does (reading, placing, checking and building the result) and then throws the change away. On the same board, a dry run and a real run say the same, unless the user is typing in a shape the script changes: a real run ends their typing first, so what they typed is part of the shape it changes.
- **`--reveal`** eases the camera to fit everything the script made or changed. Without it the camera stays where the user left it.
- **`--board <board>`** names the board by the id `build/canvas boards` gives it (which lasts while that board is open), by its file, or by its name. Without it the script goes to the board in front, which changes whenever the user clicks another window, so pass it on every `draw`. `kinds`, `status` and `boards` are about the app, and take none.
- **A file's boards.** `--board` names a file, and a file can hold boards inside shapes (a subboard's). The script works on the board inside it that the file's window shows, and on nothing else: its titles, `board`, `view` and what's kept clear are that board's. `build/canvas boards` says which, as `shows` (`"root"`, or the id of the shape that owns it) and `showsPath` (from the root down), and so does every result's `board`. Nothing draws on a board the window doesn't show: to draw on a subboard's, ask the user to open it.
- Options can come before or after `draw`. `canvas`'s own options work too: `--format json|text`, and `--timeout <seconds>` (default 10).

The result goes to standard output: JSON when standard output isn't a terminal (so always, from an agent's shell), and text for a person at a terminal. An error goes to standard error. The exit status is 0 when the script was drawn, 1 when the app refused it (read the error), 2 when the command line itself is wrong (standard input that can't be read, or isn't UTF-8, included), and 3 when the app couldn't be reached (`not_running`, `unreachable`, `protocol_mismatch`) or didn't answer in time (`timed_out`).

After a timeout the app may still draw the script: it doesn't drop what it was sent. Don't run it again to find out. Dry-run it instead:

- a titled shape or an edge whose row says `unchanged` landed;
- a `delete "X"` that now fails with `unknown_title`, or a `delete edge` with `nothing_to_delete`, already ran;
- a rename that already ran finds no shape with the old title, so the statement makes a new shape and fails (`unsupported`: `"Old" is new, and title: renames a shape`), while the new title is on the board;
- an untitled shape always comes back `created`, landed or not. Title every shape in a script you might have to check.

`build/canvas help draw` prints the command's own help.

## Lines and words

- **One statement a line.** There are no blocks and no continuations. Blank lines and indentation are ignored, and Windows line endings are fine.
- **`//` starts a comment**, at the start of a line or after a statement, anywhere outside a quoted string or a JSON value. `#` is an ordinary character, not a comment. `# Heading` is read as a statement, and it fails.
- **Quoted strings** are in straight double quotes and end on the same line. Inside them, `\"` is a quote, `\\` a backslash, `\n` a new line and `\t` a tab. Any other backslash is refused. Curly quotes (“ ” ‘ ’) and single quotes are refused, with the straight-quoted spelling in the message. An apostrophe inside double quotes is just a character: `"the day's files"`.
- **A bare word** runs to the next space, `"`, `(`, `)` or `//`. A comma at its end is a separator of its own.
- **A key** is a bare word ending in a colon, like `text:`. Only a key opens an attribute, and it needs a space after the colon: `size:200x100` is refused, with `size: 200x100` as the fix.
- **A JSON value** is a value, right after a key, that starts with `[` or `{`. It runs to its matching bracket, skipping over JSON strings, and must close on the same line.
- **`(` and `)`** hold a placement's gap. **`,` and `and`** join the shapes a placement names, and the styles a shape takes.
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
<kind> ["<title>"] { attribute | placement }    a shape: make it, or update the one with that title
edge "<a>" -> "<b>" { attribute }                a connection from a to b (also <- and <->)
delete "<title>"                                 remove a shape, and every connection with an end on it
delete edge "<a>" -> "<b>"                       remove the connections from a to b (<-> either way)
style <name> attribute { attribute }             a named set of attributes, for this script
```

The first word decides the statement. `edge`, `delete` and `style` are the language's own words. Any other first word is a kind. After a shape's kind and title, attributes and placements come in any order: `sticky-note "A" text: "Hi" below "B"` and `sticky-note "A" below "B" text: "Hi"` are the same statement.

## Shapes and titles

### Kinds

A kind is drawable when a tool places it. These are the shipped ones:

| kind | size | named by | what it says | edges |
|---|---|---|---|---|
| `sticky-note` | 200x200 | its title, a pill above its top-left corner | `text:` | `note-link`, left, right and bottom |
| `rectangle` | 160x100 | its title, a pill | nothing else | none |
| `schema-card` | 240x67 | its schema's "title", drawn on the card: never a title of its own | `schema:` and `prompt:` | `schema-link`, all four sides |
| `subboard` | 240x160 | its title, drawn on its card | nothing else: its board is its own | none |

`arrow` is what edges are: write `edge "A" -> "B"`, never `arrow`. `polyline` is drawn by hand with the line tool and can't be placed (`not_placeable`: `its tool (Line) draws one by hand`). A kind that isn't installed is `unknown_kind`, with the drawable kinds listed and the one like it named (`did you mean sticky-note?`). Words from other languages get a hint with what to write instead: `node`, `note` and `box` that a statement starts with its kind, `link` to write `edge "A" -> "B"`, `-->` in an edge the arrow to write, and a line that joins two titles without `edge` (`API --> DB`, `"A" -> "B"`) the edge it means (`edge "API" -> "DB"`).

### Titles are the names

A shape is referred to by its title and nothing else. There are no ids.

- **A title is always quoted.** It's folded as the app folds titles: runs of spaces and new lines become one space, and the ends are trimmed. A title that folds to nothing is refused; leave it out for an untitled shape. Keep titles to one line. One longer than 80 characters is kept but warned about.
- **Matching is exact** on the folded form, and case matters. `"deploy"` is not `"Deploy"`.
- **Names are read as the board has them when the run starts**, plus the titles the script itself draws. A rename takes effect from the next run.
- **A schema card is called by its schema's `"title"`**, and can't be given a title of its own: `schema-card "Order"` is `untitlable`, and so is `title:` on one. Draw it untitled, with the title in `schema:`, and call it by that title from the next run on (not in the same script: another statement can't name a shape drawn without a title). Restated with a schema whose title is another, it's renamed (`did: "renamed"`, with `was`), held to the rules of a rename (`duplicate` for a title that's taken); a schema with no title left is `renames`, since a script can't take a title away.

```draw-error
// reason: untitlable
schema-card "Order" schema: "{\"title\": \"Order\", \"type\": \"object\"}"
```

### Make or update

A shape statement **with a title**:

- If exactly one shape on the board has that title, the statement **restates** that shape and updates it. The kind must match, or it's `wrong_kind`; to change a shape's kind, delete it and draw it again in the same script.
- If two or more shapes have that title, it's `ambiguous_title`. Titles only work as names while each is used once, so ask the user to rename one.
- If no shape has it, the statement **creates** a shape with that title. If a title on the board is the same but for case, or nearly the same, the shape is still created, with a warning such as `created "deploy"; the board has "Deploy" — to change that one, write its title exactly`.

A shape statement **without a title** always creates a new, untitled shape. Nothing can refer to it afterwards, so title anything you may touch again.

A new shape starts as what its kind's tool places. Then comes its title, then its attributes, then its size, then its position. A restated shape keeps everything the statement doesn't say, including its size and its position on any axis no placement speaks for.

Two statements about one title in one script (two shape statements, or one and a rename to that title) is `duplicate`. A statement placed against its own title is `circular`. The exception is `delete "X"` followed by a shape statement for "X": deletes happen first, so that pair redraws a shape.

This names nothing, so it makes a schema card with no title of its own, called by the title in its schema:

```draw
schema-card left of "Ingest" schema: "{\"title\": \"Row\", \"type\": \"object\", \"properties\": {\"id\": {\"type\": \"string\"}}}"
```

From the next run on, the board has a shape called "Row". A schema with no title would take that name away, so a statement that gives it one is refused:

```draw-error
// reason: renames
schema-card "Row" schema: "{\"type\": \"object\"}"
```

## Attributes

An attribute is `key: value`. Each key appears once in a statement; the second is `duplicate`.

### The language's keys

| key | value | what it does |
|---|---|---|
| `size:` | `<width>x<height>` (`x` or `×`), or `[w, h]`; both above 0, and at most 100000 | The shape's size in world units. A new shape defaults to what its tool places; a restated one keeps its size. |
| `gap:` | `none`, `tight`, `normal`, `wide`, or a number from 0 to 100000 | This shape's default gap in every placement it's in, from either end. See [Gaps](#gaps). |
| `overlap:` | `allow` | This shape may overlap others. It's never pushed, and it's never part of a list. |
| `style:` | a name, or several joined by `,` or `and` | The styles it takes, in order. See [Styles](#styles). |
| `title:` | a quoted title | Renames a restated shape. See [Renaming](#renaming). |

### A kind's attributes

Every other key is one of the kind's properties, named as its schema names it; `build/canvas kinds` lists them. The value is read by the property's type:

| the property is | write | for example |
|---|---|---|
| text | a quoted string, or a single bare word | `text: "Pull the day's files"`, `text: later` |
| a date and time | `YYYY-MM-DD` (midnight UTC), or a full date-time | `due: 2026-10-20`, `due: 2026-10-20T09:30:00Z`, on a kind that has one |
| one of a set | one of its words, bare or quoted | `status: blocked`, on a kind that has one |
| a number | a bare number | `estimate: 6`, on a kind that has one |
| true or false | `true` or `false` | `locked: true` |
| anything | `null`, which puts the property back to its default | `text: null` |

The shipped kinds' attributes:

- **sticky-note**: `text` (what it says), `locked`.
- **schema-card**: `schema` (a JSON Schema, as text: its properties in the order written; the card grows to list them), `prompt` (what the schema should hold, in words), `locked`. What a script writes is taken as written: the Claude sync that rewrites one side when the user edits the other isn't asked, so write a prompt and a schema that agree, or leave the prompt out.
- **rectangle**, **subboard**: `locked`.
- **A note's `text`** is kept as written. In it, `@[label](shape:<id>)` is a mention of a shape, which the note shows as a live pill with that shape's name now. No id ever reaches a script, so write plain words: an `@`, or `@[…]` without `(shape:…)`, is only text. (The app writes a mention's form as plain text with `\@[`, which a script's string spells `\\@[`.) A mention of a shape that isn't in the file is kept, and warned about.
- **`locked: true`** locks a shape, as the context menu's Lock does. A locked shape refuses every later change (`read_only`). Leave locking to the user.

A value past a bound (a title over 80 characters, say) isn't refused. The shape is drawn and the bound comes back as a warning. A value of the wrong type is `invalid_value`, naming the attribute and what it takes. So is a word outside a set, which also gets a Did you mean. A key the kind doesn't have is `unknown_attribute`, which lists what the kind takes and names the kinds that do have the key, if any. A property that holds an object or a list (none of the shipped kinds has one) takes JSON on one line, which replaces the whole property, so write every member; a value of the wrong type anywhere inside it, or a member it doesn't have, is `invalid_value` too, never dropped.

```draw
sticky-note "Backfill" below "Ingest" text: "Waiting on the vendor's March files"
sticky-note "Nightly schedule" below "Load" text: "Pick a time, and add a timeout"
```

### Keys that are refused

- **The title, as an attribute, on a new shape** (`unsupported`). The title goes after the kind, in quotes. On a restated shape, `title:` renames it.
- **Coordinates** (`unsupported`). The box's `frame`, and any property that holds a point or a rectangle, can't be set: there are no coordinates here. Say where a shape goes with a placement, and how big with `size:`. `x:`, `y:`, `at:` and `position:` get the same answer, and `width:` and `height:` are pointed to `size:`.
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

### Targets

A target is a quoted title, optionally followed by a part, or one of two unquoted words:

- **`board`** is the box around every [obstacle](#keeping-clear): the shapes on the board that this script doesn't move (the board the window shows, not the boards inside its subboards). `right of board` is a new column past everything, `below board` is the space under everything. On an empty board it's `unknown_title`, because there's nothing to be right of. Leave one shape unplaced instead, and the drawing goes in the window.
- **`view`** is the part of the board in the window. `inside view top-right` puts a legend in a corner. `view` needs the board's window to have a size, or it's `no_view`.

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

Other spacing is fixed. A list steps 64. Shapes pushed apart keep 40 between them side by side, and 64 one above the other. The extra room is for the row just above a shape, where its title's pill and a lock's chip go, which sits 27 units above it at 100% zoom and 54 at 50%, so it clears the shape above down to about 42% zoom.

## Lists

New or restated shapes whose placements are written identically form a list. "Identically" means the same placements in the same order, bracketed gaps included, as quoted back: `right "A"` and `right of "A"` count as the same. The members stack down the page in script order and are placed as one box. Three shapes `right of "Hub"` make a column centered on Hub. Two shapes `below "Hub"` stack under it, each centered across on Hub.

- They're 64 apart, or the members' `gap:` if they all state the same one.
- An `overlap: allow` shape is never in a list.
- A list isn't extended across runs. A later `right of "Hub"` is centered on Hub and pushed past the old column. To add a member, restate every member with the same placement.
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
- a shape and a zone, an obstacle that wholly holds one of these: the shape where it already sat (a restated one), however snugly; a shape it's placed against, if the zone is at least twice that one's size (in area); the shape where it lands, if the zone holds other shapes too and is at least twice the shape's size; or the `view` it's placed against (the region you're zoomed into), or that the [drawing with nothing to hang on](#a-drawing-with-nothing-to-hang-on) is drawn in. A restated card lined up with one in the next column stays in its own, a shape placed against one on a much bigger shape isn't in the bigger one's way, and one that lands in a corner of a region that frames what's in it sits on that region. But what holds only the shape where it lands is in the way, however big: a rectangle that lands on an empty note is pushed past it, and so is a note that lands on a subboard's card, or a shape moved onto either from elsewhere. So is a shape alone on the board, to one placed `inside board` over it. A note or a card that holds a shape of its own (a badge wholly inside it) is a zone like any other, though: a shape at most half its size that lands wholly on it sits on it, over its text (the badge is still in its way).

A shape this script places counts as one a zone holds only when it's on the zone for a reason of its own, never just because another new shape is: it's placed `inside` or `on` the zone; the zone would hold it with no new shape counted (where it already sat, a shape on the board it's placed against, the view, or shapes on the board it lands among); or it's placed against a shape that counts. So two new shapes can't hold each other on an empty zone: a rectangle and the caption placed below it, landing together on the next note, are both pushed past it, and so are two legends landing on an empty frame. A shape placed `inside` an empty zone counts, whatever line it's on, and so, in turn, does what's placed against it.

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

**A zone** is a big shape that others sit on, like a rectangle for a team or a tier. Draw it in its own script first, then draw what goes in it. Once the zone is on the board, it isn't in the way of a shape placed against one it holds, or of one that lands wholly on it while it already holds other shapes, as long as the zone is at least twice the size of the one it holds or the one landing. Nor is it in the way of a shape restated that already sat on it, or of one placed against `view` while the whole view is on it ([Keeping clear](#keeping-clear)). So a card in one column lined up with a card in the next stays in its own, and `inside view top-right` puts a legend in the corner of a region you're zoomed into, or of one that fills most of the window and holds other shapes. A shape that lands on an empty zone, placed against nothing in it, is pushed past it, and so is every shape the same script lands on it that way: put the first shape in with `inside`, and place the rest against that one. One that can't move off an empty zone (a card restated `left level with` an empty lane) is `unordered`, and its hint says the zone holds nothing yet (or no shape wholly, when one hangs over its edge): place it elsewhere, or, if the zone is meant to hold shapes, place a first one `inside` it. Held on an empty note, the hint is the same, but what goes on a note covers its words: place the shape elsewhere. Only `inside` keeps a shape within the zone: one placed against a shape in it, or restated, isn't held in, and can hang over its edge. The result then warns, `"Dead letters" hangs over the edge of "Backend" — make "Backend" bigger, or place "Dead letters" elsewhere`: place it `inside` the zone, or make the zone bigger. Within one script, only shapes placed `inside` or `on` a shape may overlap it. Drawn in the same script as what goes in it, a zone is in the way of everything but those: a shape placed against something inside it is pushed out of it, and one held inside it with no room left is `no_room`, naming what pushed it. Draw the zone first.

**Paint order.** New shapes are painted above everything already on the board. A shape placed `inside` or `on` another shape this script draws is painted above that shape. A restated shape moved `inside` or `on` a shape that paints above it is brought above that shape, and so is one moved into a zone that paints above it, or within the one it's in, so a shape drawn before its zone isn't hidden under it; a shape placed `on` or `inside` it in the same script goes above it in turn, whatever order the lines are in. A locked shape isn't moved in the stack, unless the same statement unlocks it (or locks it: it's raised first).

```draw
rectangle "Warehouse" below board size: 1000x360
```

```draw
sticky-note "Orders table" inside "Warehouse" top-left text: "One row per order"
sticky-note "Customers table" right of "Orders table" text: "One row per customer"
rectangle "Badge" on "Warehouse" top-right size: 80x80
sticky-note "Archive" outside "Warehouse" bottom text: "Older than a year"
```

A note stuck across two notes overlaps both on purpose. `on` exempts it from the one it's on, and `overlap: allow` from the other:

```draw
sticky-note "Stamp" on "Orders table" right overlap: allow text: "Reviewed"
```

## Edges

### Writing one

```text
edge "A" -> "B"           a connection from A to B, a head at B
edge "B" <- "A"           the same edge, written with B first
edge "A" <-> "B"          heads at both ends
```

Both ends are titles: shapes on the board, or shapes the same script draws. An untitled shape can't be an end. An edge takes these attributes and no others:

| key | value |
|---|---|
| `from:` | `top`, `right`, `bottom` or `left`: the side the start leaves from |
| `to:` | `top`, `right`, `bottom` or `left`: the side the end arrives on |
| `channel:` | a channel's id, or `none` for a plain arrow |

An edge takes no placement (it goes where its ends are), no style, and no text; edges carry no labels yet. Chains (`edge "A" -> "B" -> "C"`) are refused: write each edge on a line of its own.

### Sides

Without `from:` or `to:`, an end aims at the middle of its shape, and the line is clipped where it meets the outline. With one, the end aims at the middle of that side. If a named side faces away from the far shape, the line still leaves from the side facing it (arrows are arcs, and they clip at the outline), and a warning says so, as in `from: left: "B" is right of "A", so the line leaves "A" by its right side — name a side that faces "B", or leave from: out`. Arrows don't route around shapes, and they're never obstacles.

### Channels

A channel is what kind of connection an edge is. Each kind has ports on some channels, on some sides, and an edge on a channel runs only between shapes whose kinds take it: from a shape with ports on it, to a shape that accepts it.

| kind | channel | sides |
|---|---|---|
| `sticky-note` | `note-link` | left, right, bottom |
| `schema-card` | `schema-link` | top, right, bottom, left |
| `rectangle`, `subboard` | none | none |

`build/canvas kinds` lists each kind's channels by side, under `edges`. How an edge's channel is chosen:

- **`channel: <id>`**: that channel. The start's kind must have ports on it, and the end's kind must accept it. Otherwise it's `no_channel`, and the message says what each end takes, side by side. A word that isn't a channel is `invalid_value`, and the hint lists the channels.
- **`channel: none`**: a plain arrow, on no channel, between any two shapes, from and to any sides.
- **Unwritten**: the first of the start's channels (on the `from:` side, if named) that the end accepts (on the `to:` side, if named). If there's none, and neither kind has ports on any channel, it's a plain arrow, from and to any sides named. If there's none and either kind does have ports, it's `no_channel`: `"Ingest" and "Monday" share no channel: a sticky-note connects on note-link, a subboard has no ports`, with the hint `channel: none draws a plain arrow between them anyway`.
- **A side a kind has no port on** is refused. With `channel:` written, it's `invalid_value`: `a sticky-note has note-link ports on its left, right and bottom`. With the channel unwritten, no channel fits that side, so it's `no_channel`.
- **An edge from a shape to itself** on a channel is refused. With `channel: none` it's a short straight arrow inside the shape (from its middle, or between the sides named), not a loop around it. To show a loop, draw it through a second shape.

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

```draw-error
// reason: no_channel
edge "Ingest" -> "Monday"
```

### Drawing one again

An edge statement means "A is connected to B" (with `<->`, in either direction). It looks for the connections already drawn between the two:

- **None**: it draws one (`did: "connected"`).
- **One**: it updates only what the statement writes. A named side re-aims that end, and an unnamed side keeps the end as it was. The heads follow the arrow (`->` a head at the end only, `<->` both), and the bend stays. The channel stays too: a different `channel:` is refused (`invalid_value`), with the hint to write `delete edge` above the line and draw it again. Nothing different is `did: "unchanged"`; otherwise it's `did: "reconnected"`.
- **Two or more** is `ambiguous_edge`. Delete them (`delete edge "A" -> "B"`) above the line and draw one again.
- **A locked connection** refuses a change (`read_only`), but a statement that wouldn't change it is fine.

`delete edge "A" -> "B"` followed by `edge "A" -> "B"` in one script redraws it, since deletes happen first. Two edge statements for the same pair, the same way round (or either way, when one is `<->`), in one script is `duplicate`.

```draw
edge "Ingest" -> "Clean" from: right to: left
```

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

- **No placements**: the shape stays where it is. A new `size:` grows or shrinks it from its top-left, with a warning if it now overlaps something.
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

`title: "New"` on a restated shape renames it (`did: "renamed"`, with `was: "Old"`). The shape can move or change in the same statement. The new title must fold to something, and no other shape on the board or statement in the script may have it (`duplicate`). The kind must be nameable. Other lines in the same script still call the shape by its old title; the new title applies from the next run. `title:` on a new shape is refused: a new shape's title goes after its kind. `title: null` is refused too (`unsupported`), and so are `title: none` and `title: nil`: a script renames a shape, but can't take its title away. A title that really is "none" is quoted.

```draw
sticky-note "Nightly schedule" title: "Nightly run"
```

### Deleting

`delete "X"` removes the shape and every connection with an end on it, each reported as its own `deleted` row: one to another shape with `from` and `to`, and one whose other end is free (re-aimed off every shape) with neither. `delete edge "A" -> "B"` removes the connections from A to B, and `delete edge "A" <-> "B"` removes them either way round.

- An unknown title is `unknown_title`. `delete edge` with nothing to delete is `nothing_to_delete`. A locked shape or connection is `read_only`.
- A shape that holds a board (a subboard) takes its board with it, and every board under that, with everything on them. That isn't refused: a warning says how much went (`"Payments" held a board, and 1 more under it: the 4 shapes on them are deleted with it`), and Undo brings it all back. One whose board, or a board under it, holds a locked shape isn't deleted (`read_only`: `"Payments" holds a read-only shape (locked, say) on its board, so it can't be deleted`).
- `delete edge "A" -> "B"` after `delete "A"` asks for what the delete already does, and is fine, as it is the other way round: A's connections go with it, on the delete's row.
- A shape the script deletes can't be a target in the same script, unless the script draws it again.
- To change a shape's kind, delete it and draw it again in the same script. Its connections go with it, so draw those again too.

```draw
delete edge "Tuesday" <-> "Wednesday"
delete "Archive"
```

```draw
delete "Owner"
subboard "Owner" above-left of "Ingest"
```

## How a run is applied

1. **Read.** Every line is read. Lines that can't be read are reported together, up to 20.
2. **Resolve.** Kinds, titles, attributes (JSON member by member), styles, placements' targets, each edge's ends and attribute keys, and each delete's shape and connections are checked against the board as it is. Mistakes that don't depend on each other are reported together here too.
3. **Place.** Positions are worked out against the board as it is. Only the first placing error is reported, since one mistake there makes others.
4. **Apply**, in one change or not at all. Deletes come first, then new and restated shapes (each after any shape the script draws or restates that it's placed `inside` or `on`), then edges. Each edge's channel and sides are checked as it's drawn, one at a time: the first that's wrong (`no_channel`, `cannot_connect`, a channel or side that's `invalid_value`, `ambiguous_edge`, `read_only`) is the error, and nothing is drawn. The result and its warnings are read from the changed board.

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
   {"line": 8, "did": "unchanged", "kind": "sticky-note", "title": "Load"}
 ],
 "warnings": [{"line": 4, "message": "\"Backfill\" was pushed right past \"Vendor\" to keep clear of it, …", "severity": "warning"}],
 "dryRun": true}
```

- **`board`**: the board it ran on, as `build/canvas boards` lists it: the file's `id` and `name`, and the board inside it the window shows, `shows` (`"root"`, or the id of the shape that owns it) and `showsPath` (from the root down).
- **`changes`**: a row for each thing done, with its `line`. `did` is `created`, `updated`, `moved`, `renamed`, `unchanged`, `deleted`, `connected` or `reconnected`. A shape's row has its `kind` and `title`, and `at`, its bounds as `[[x, y], [width, height]]` in world units (top-left first, y down). A connection's row has `from`, `to` and `channel` (if it's on one) instead. No ids appear anywhere, because titles are the names.
- **`inView`**: whether the shape landed in the window.
- **`pushedPast`**: what the shape was pushed past to keep clear ([Keeping clear](#keeping-clear)).
- **`was`**: a renamed shape's old title.
- **`dryRun`**: `true` on a dry run, when nothing was changed.

The run succeeds with these **warnings**, each with its `severity`, the `line` of the statement it's about (all but the count of shapes out of view have one), and the `attribute` it's about, when it's about one:

- every validation issue on each shape made or changed, errors included, like `"Inbox": This note is empty.` or a schema card's `A schema must be a JSON object.` An `error` means the board outlines that shape in red;
- every schema bound a value breaks, like a title over 80 characters;
- every push;
- sides that face away;
- titles that nearly match one on the board;
- how many shapes landed outside the view (`3 shapes landed outside the view — --reveal brings them into view`), unless `--reveal` brought them into view;
- a shape that hangs over the edge of a zone it sits on (placed against something in it, restated, or placed against the view);
- a restated shape resized in place that now overlaps something;
- what a shape it drew names that isn't there: a note whose `text:` mentions a shape that isn't in the file, or is on a board the app can't show (`"Plan": text names shapes that aren't in the file: <id>; they show as missing`);
- a deleted subboard's board, and what was on it.

As text, for a person at a terminal, each row leads with its line and what it did, and warnings are printed whole, their message last.

## Errors

When a run fails, nothing changes. The error goes to standard error:

```json
{"error": {"reason": "unknown_title", "message": "there's no shape called \"Injest\"", "hint": "did you mean \"Ingest\"?", "status": 1,
           "line": 3, "statement": "sticky-note \"Notes\" right of \"Injest\"",
           "errors": [{"line": 3, "statement": "sticky-note \"Notes\" right of \"Injest\"", "reason": "unknown_title", "message": "…", "hint": "…"},
                      {"line": 5, "statement": "edge \"Notes\" -> \"Laod\"", "reason": "unknown_title", "message": "…", "hint": "…"}]}}
```

`reason` is what to branch on. `message` names the statement in its own words: its title, or `the rectangle on line 3` for an untitled one, with placements quoted back as written. `hint` is usually the line to write instead. `line` is the line it's about, or the later of two. `statement` is that line as written, without its comment. `errors` is there only when more than one mistake was found (mistakes that don't depend on each other, found reading and resolving): the first leads, and `errors` lists them all, the first too. With one, read `line`, `statement` and `hint`. As text, it reads `canvas: line 3: <message>`, then the statement, then `hint: …`, then each further error.

The messages below are examples. The wording can differ, but the reason doesn't.

| reason | what it means, with an example message | the fix |
|---|---|---|
| `syntax` | The line can't be read. `sticky-note: Web isn't quoted, and titles are in double quotes` · `edge: --> isn't an arrow` · `--> joins shapes only in an edge statement` · `titles and text are in straight double quotes: "Web"` · `sticky-note "A": rigth isn't a placement` · `# doesn't start a comment here` · `attributes are written key: value, without braces` · `an attribute is written key: value, not key = value` | Follow the hint, which names what to write. |
| `unknown_kind` | The first word isn't a kind the app has. `node "Web"`, with the drawable kinds listed, and the one like it named (`note`: `did you mean sticky-note?`) | Use a kind from `build/canvas kinds`. |
| `not_placeable` | The kind exists but no tool places it, like an arrow, or a line, whose tool draws one by hand. | Draw an arrow as `edge "A" -> "B"`. |
| `unknown_attribute` | The key isn't one the kind takes. `"Backfill" is a sticky-note and has owner:, which isn't one of a sticky-note's attributes`, with the hint `a sticky-note takes size:, gap:, overlap:, style:, title:, locked:, text:` · a style that gives a shape nothing, or has a key nothing takes | Use one it takes (Did you mean), or drop it. |
| `invalid_value` | The value doesn't fit the key. `locked: maybe isn't true or false` · `size: huge isn't a size` · `gap: wdie isn't a gap` · a size or gap over 100000 · `from: middle isn't a side` · `channel: note-lnk isn't a channel` · a JSON member the object doesn't have, or a value of the wrong type in it · with `channel:` written, a side the kind has no port on (`from: top: a sticky-note has note-link ports on its left, right and bottom`) · another channel for an edge already drawn (`the edge from "A" to "B" is on note-link, not on schema-link`) | Write a value of the kind the hint names. |
| `duplicate` | Something is written twice. `"locked" is written twice (true, false)` · a title stated on two lines (`written twice, here and on line 4`) · a rename to a title another shape has · two edges for one pair · a style defined twice | Keep one. |
| `unknown_title` | No shape has that title. `right of "Injest"`, with up to 3 near titles · `board` on an empty board | Write the title exactly (`did you mean "Ingest"?`). On an empty board, leave one shape unplaced instead. |
| `ambiguous_title` | Two or more shapes have the title, each listed with its kind and where it is. | Ask the user to rename one. Titles only work as names while each is used once. |
| `ambiguous_edge` | `"A" -> "B" is drawn 2 times` | Write `delete edge "A" -> "B"` above the line, then draw it once. |
| `untitlable` | The kind can't be given a title: `a <kind>'s title is worked out from what it is`, or `a <kind> has no title` | Leave the title out, and don't plan to name it later. |
| `renames` | The change would take away the name of a shape whose name comes from what it is: a schema card's schema with no title left, `this would leave "Row" without a title` | Keep a schema card's title in its schema. |
| `wrong_kind` | The title belongs to a shape of another kind. `"Ingest" is a sticky-note` | Use its kind, or change it with `delete "Ingest"` and a new statement in the same script. |
| `read_only` | The shape or connection is locked, and the change would really change it. `"Ship" is read-only (locked, say), so it can't be deleted` · `one of "Ingest"'s connections is read-only (locked, say), so "Ingest" can't be deleted with it` · a subboard whose board holds a locked shape, deleted | Tell the user. Leave it, or ask them to unlock it. |
| `unplaced` | Nothing says where a shape sits. `"Between" does not say where it sits vertically: right of "Ingest" and left of "Load" would put it in different places` · `exactly one new shape may say nothing about where it goes, but 2 do: "Idea one" and "Idea two"` · `"N" says nothing about where it sits horizontally` | Add a placement for that axis (the hint names one), or place all but one shape. |
| `unanchored` | Shapes are placed only against each other, with nothing tying them to the board. `nothing ties "Left half" to the board horizontally` | Place one against a shape on the board, `board` or `view`, or leave exactly one unplaced. |
| `no_room` | The placements can't all hold. `"Squeeze" is right of "Ingest" and left of "Clean", and there's no room between them` · `… clear of "Q"` · `"N" is inside "Z" top-left, and there's no room left in "Z"` | Drop or change a placement, or ask for a smaller gap. Shapes on the board don't move, so to make room, restate them with placements. |
| `circular` | `"Loop" is placed against itself`, or two shapes wait on each other: `"N" is level with "A" and "B", but "B" is placed vertically against "N" in turn` | Place one of them against something else. |
| `unordered` | Two shapes would overlap and nothing says which side of the other either sits on. `"North" and "Far north" overlap, and nothing says which side of the other either one sits on` · `"N" is on "P" and can't move, but it overlaps "Q"` | Place one against the other, place it elsewhere, or say `overlap: allow`. Held on an empty zone, the hint says so: place it elsewhere, or, if the zone is meant to hold shapes, put a first one `inside` it. |
| `no_channel` | The edge's ends share no channel, on the sides named if any, or the channel written isn't one both ends take. `"Ingest" and "Monday" share no channel: a sticky-note connects on note-link, a subboard has no ports` · `a connection on note-link can't end where it starts` | Connect like to like, name a side that has the port, or say `channel: none`. |
| `cannot_connect` | The app won't connect that end at all, and the message names the end. | Connect a different shape. |
| `no_edges` | No plugin in this app draws connections. | Draw shapes only. |
| `no_names` | No plugin in this app names shapes, so titles can't be matched. | Titled statements can't work in this app. |
| `no_view` | `view` was named, but the board's window has no size. | Place against a shape or `board`, or leave one shape unplaced. |
| `unsupported` | Something the language doesn't do. `edges can't carry text yet: arrows here have no labels` · `an edge joins two shapes, and this one goes on to a third` · `frame: says where "N" is, and there are no coordinates here` · `x: would say where "N" is, and there are no coordinates here` · `"N" is new, and title: renames a shape` · `title: null would take the shape's title away, and a script only renames` | Leave it out, write each edge on its own line, place the shape instead, or put the title after the kind. |
| `nothing_to_delete` | `delete edge` found no connection. | Check the direction, or use `<->`. |
| `busy` | Someone is dragging on this board. | Try again in a moment. |
| `empty_script` | The script has no statements (comments and styles don't count). | Write at least one shape, edge or delete. |
| `internal` | A bug in the app. | Report it, with the script. |
| `no_board` | No board is open. | Ask the user to open or make one. |
| `ambiguous_board` | Several boards are open and none is in front, or two open boards have the name `--board` gives. | Name one by its id, from `build/canvas boards`. |
| `unknown_board` | No open board has that id, file or name (an id goes when its board closes). | Run `build/canvas boards` and use an id it lists. |
| `usage` | The command line is wrong (exit 2): no such command or option, a value that isn't one, `--board` on a command about the app, or standard input that can't be read or isn't UTF-8. | Follow the hint; `build/canvas help draw` says what `draw` takes. |
| `not_running` | The app isn't running (exit 3). | Start it: `./build.sh && open build/InfiniteCanvas.app`. |
| `unreachable` | The socket can't be reached (exit 3), usually a sandbox. | Ask the user. |
| `protocol_mismatch` | The app and this `canvas` were built apart, and speak different protocols (exit 3). | Ask the user to quit the app and open this checkout's build. |
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
// reason: unsupported
edge "Ingest" -> "Clean" "then"
```

```draw-error
// reason: nothing_to_delete
delete edge "Ingest" -> "Load"
```

```draw-error
// reason: empty_script
```

## What canvas kinds says

`build/canvas kinds` is the vocabulary, and `build/canvas kinds <kind>` narrows it to one kind. For each kind it gives:

- `kind`, `title` (what the app calls it) and `tool` (the tool named for it: the one that places it, or draws it by hand, as the line tool does a polyline).
- `drawable`: whether a script can draw it, with the reason if not (`why`).
- `names`: `named` (a title you give it), `derived` (worked out from what it is), or `none`.
- `size`: what its tool places, like `"200x200"`.
- `attributes`: each attribute a script can set, with a compact type. The types are a set's words joined by `|`, `true|false`, `number ≥ 0`, `integer`, `text`, `text (≤ 80)`, `date (YYYY-MM-DD or date-time)`, and JSON shapes like `JSON [{done, text}]` (members in alphabetical order; an id nobody writes, like a list item's, isn't listed). Keys a script can't set, like the frame, aren't listed.
- `edges`: the channels an edge from it can take, by side.

`--schema` adds each kind's full JSON Schema. As text, for a person at a terminal, each kind's attributes and edges are listed under its row.

## What the language refuses

These are left out on purpose. What they protect is that the app never chooses an arrangement for you. It works out the one your sentences describe, and refuses the rest.

- **Coordinates**, in any form, including as an escape hatch. A position is always said against something named. The board stores positions, and the script never sees them.
- **Guessing an axis.** When nothing settles an axis, or two placements settle it differently, the app refuses rather than picking a row or a column.
- **Two drawings with nothing to hang on.** Only one shape per script may be unplaced, because two unrelated drawings would have to be put somewhere relative to each other, and that's a choice.
- **Overlap without an order.** When two shapes would overlap and nothing says which side of the other either sits on, it's refused rather than split the difference.
- **Placements that run in a circle.** A loop where each placement demands more room than the last can't hold, and it's reported with the placements on it.
- **Hidden names.** Titles are the only names, so what a script says is what a person reading the board sees.
- **Remembered placements.** A placement is worked out once. Shapes don't follow each other afterwards, because the user moves things, and a board that moved them back would fight the user.
- **Moving what the script doesn't mention.** Shapes the script doesn't restate stay exactly where they are. Room is made by restating them, never by pushing them.

## Not built yet

- **Reading a board back.** No command lists a board's shapes, titles or positions yet. An agent knows only what its scripts drew and what the results said.
- **Drawing on a board the window doesn't show**, and listing a file's subboards. A script works on the board its file's window shows; the user opens a subboard for it.
- **Mentions by title.** A note's `text:` is kept as written, and a mention in it is written with the shape's id, which no result gives.
- **Text on edges.** Arrows have no labels.
- **Groups and containers** that grow with what's in them, or that move as one. Zones are plain shapes, and their contents are placed once.
- **Routing.** A line may cross shapes it has nothing to do with. There's no `between` or `below "X"` for edges yet.
- **Extending a list** across runs, other than by restating every member.
- **Naming shapes the user left untitled.** An untitled shape can't be named by a script.
- **Chains** (`edge "A" -> "B" -> "C"`).
- **Commands from the plugins that own a concern.** Everything goes through `draw` for now.

---

The language and its solver are modified from [reladraw](https://github.com/reladraw/reladraw) (Apache-2.0; see THIRD_PARTY_NOTICES.md at the repository's root): its placements, parts, lists, one unplaced shape, refusing rather than guessing, and the way distances are solved. What differs comes from drawing on a live board. Shapes already there are fixed and are obstacles, restated shapes move on their own, and a drawing with nothing to hang on goes where the window is. This language isn't called reladraw.

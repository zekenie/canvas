<!-- board: query-story -->
# The canvas query language

The whole language `build/canvas query` reads: every form, word and rule, what a query sees of a file, what comes back, and every way a query can be refused. [../SKILL.md](../SKILL.md) is the tour; this page is where to look when you need a form the tour doesn't show, or when a refusal points at something you didn't expect.

A query selects shapes as a CSS selector selects elements, and where CSS has a meaning, the query has CSS's meaning. The answer is every shape of the file that matches, on every board, in file order, with how many there are. A query never changes anything.

The examples on this page are all about one file, the story below. Each block tagged `query` is a query as you'd send it, and its first line, a comment, says what it answers: `/* matches: … */` lists the shapes, in the order they come back (a title in double quotes, an untitled shape as its kind in brackets, nothing after the colon for none), and `/* count: N */` how many. Each block tagged `query-error` is refused, with the reason its first line names. The kinds, edge types and words are the ones that shipped when this was written. `build/canvas query-vocabulary` says what your app has.

## Contents

- [The story file](#the-story-file)
- [Running a query](#running-a-query)
- [The result](#the-result)
- [What a query sees](#what-a-query-sees)
- [Naming shapes](#naming-shapes)
- [Combining](#combining)
- [Attributes](#attributes)
- [Text](#text)
- [Inside](#inside)
- [Edges and direction](#edges-and-direction)
- [Transitive words](#transitive-words)
- [Connections](#connections)
- [Plugins' words](#plugins-words)
- [Edge types](#edge-types)
- [Yes or no, and counts](#yes-or-no-and-counts)
- [From English](#from-english)
- [Errors](#errors)
- [What the language refuses](#what-the-language-refuses)
- [Honest limits](#honest-limits)
- [Not built yet](#not-built-yet)

## The story file

"Roadmap": a file whose top board holds a subboard, Payments, whose board holds another, Refunds. Its window shows the top board, and the person has Auth selected.

```text
Roadmap (the top board), back to front:
  subboard "Payments"
  sticky-note "API gateway"   text: Owns auth. See @Checkout        (a mention of Checkout)
  sticky-note "Auth"          text: JWT, 15 min expiry
  sticky-note (untitled)      text: TODO: rate limits
  schema-card                 its schema's "title" is "Warehouse"
  schema-card                 its schema's "title" is "Order"; locked
  schema-card                 its schema isn't JSON (a comma is missing), so it has no title
  arrow                       from API gateway to Auth, on the note-link channel
  arrow                       from Warehouse to Payments, on no channel
  sticky-note "Ledger"        text: Moved to @Old ledger            (Old ledger was deleted)
Payments' board:
  sticky-note "Checkout"      text: Calls @API gateway for tokens   (a mention of API gateway)
  subboard "Refunds"
  sticky-note (untitled)      text: Retry on 502
Refunds' board:
  sticky-note "Refund policy" text: 30 days; locked
```

Its file order, the order of every answer: Payments, Checkout, Refunds, Refund policy, Payments' untitled note, API gateway, Auth, the top board's untitled note, Warehouse, Order, the untitled schema card, the two arrows, Ledger.

## Running a query

```bash
build/canvas query --board 2 - <<'EOF'
sticky-note:mentions("API gateway")
EOF
```

`build/canvas query <query>|- [--limit <n>] [--count] [--brief] [--fields <attribute>]… [--board <board>]`
`build/canvas query --ask <question>|- [the same options]`
`build/canvas query-vocabulary`

- **The query**: `-` reads it from standard input. Queries are full of `"`, `*`, `>`, `[`, `!` and `#`, which shells mangle, so always pass one through a heredoc with a quoted delimiter (`<<'EOF'`). A query may run over several lines (a new line is a space) and hold comments, `/* … */`.
- **`--board <board>`** names the file by the id `build/canvas boards` gives it, by its path, or by its name. Without it the query goes to the file in front. A query reads the whole file, every board of it, wherever its window is.
- **`--limit <n>`** lists at most so many rows, 100 unless it says, up to 10000. `count` is always of every shape that matches.
- **`--count`** lists no rows: only how many match.
- **`--brief`** lists each row without its attributes.
- **`--fields <attribute>`** lists only the attributes it names, whole (never cut). Give it again for another: `--fields text --fields locked`. It can't go with `--brief`, and an attribute no kind has is refused (`unknown_attribute`).
- **`--ask <question>`** has the app write the query from a question in English ([From English](#from-english)).
- `canvas`'s own options work too: `--format json|text`, and `--timeout <seconds>` (10 for a query, 60 for `--ask`).

The result goes to standard output: JSON when standard output isn't a terminal (so always, from an agent's shell), and a table for a person at a terminal. A refusal goes to standard error. The exit status is 0 when the query was answered, whatever it counts (a count of 0 is an answer), 1 when the app refused it (read the error), 2 when the command line itself is wrong (an option that isn't one, `--limit many`), and 3 when the app couldn't be reached or didn't answer in time. `build/canvas help query` is the command's own help.

`build/canvas query-vocabulary` is what this app's queries can name: every kind, with what the app calls it, whether its shapes are titled (`named`, `derived` from what they hold, or `none`), whether it holds a board (`holdsBoard`: a subboard) and whether it holds shapes (`holdsShapes`: a subboard or a frame, what may stand where a container goes), and each attribute with what it takes; the edge types, each `under` the one it's a kind of; and every pseudo-class, with what it takes, what it means, an example, and the plugin it's `from` (the language's own are `queries`'). `vocabulary` is all of it as one block of text, the one `--ask` sends Claude. It's about the app, so it takes no `--board`.

## The result

```json
{"board": {"id": 2, "name": "Roadmap", "shows": "root", "showsPath": ["root"]},
 "query": "sticky-note:mentions(\"API gateway\")",
 "count": 1,
 "rows": [{"id": "00000000-0000-4000-8000-000000000011", "kind": "sticky-note", "title": "Checkout",
           "board": "00000000-0000-4000-8000-000000000001", "inside": ["Payments"],
           "properties": {"text": "Calls @API gateway for tokens"}}]}
```

- **`board`**: the file it ran on, as `build/canvas boards` lists it, with the board inside it the window showed as the query ran (`shows`, `showsPath`), which is what `:current-board` means. A query reads every board of the file, not only that one.
- **`query`**: the query that ran, as the language writes it: comments and extra spaces left out, its own words in lowercase, titles in double quotes. With `--ask`, it's the query Claude wrote, and **`asked`** is the question.
- **`count`**: how many shapes match, listed or not.
- **`rows`**: the first `--limit` of them, in file order. Each has:
  - `id`: the shape's id. Use it to name the shape in a later query (`#00000000-…`), and for nothing else: `draw` names shapes only by title.
  - `kind`, and `title`, unless it has none (a schema card's is its schema's `"title"`).
  - `board`: the board it's on, `"root"` for the top board, else the id of the shape that owns it.
  - `inside`: the names of the subboards and frames it's inside, outermost first, as the path over the canvas names a board (an untitled subboard's is "Untitled Subboard"), and a frame by its title (an untitled one's is "Frame"). Left out for a shape inside nothing.
  - `properties`: its attributes as they read (`locked`, `public` and `channel` only when they're set): text as a person reads it (a mention as `@` and the name of what it mentions), numbers, `true` and `false`. Its title and where it is aren't among them.
  - `cut`: the attributes cut at 500 characters (their text ends with `…`). `--fields` lists them whole.
  - `connection`, for a connection (an arrow bound at both ends): its edge `type`, and the shapes it runs `from` and `to`, each by `id` and `title`. An end on a shape that stands for other shapes is read at what it stands for: `from` and `to` are then the first such pair in file order, `via` says which stand-in each end went through (`{"to": {"id": …}}`, by `id`: a stand-in has no title, and only an end that was one is there), and `more` lists the other pairs (`{"from": …, "to": …}`, in file order) when it stands for several. A connection as it was drawn has neither.
  - `editing: true` while the person is typing into it.
- **`warnings`**, when there are any, each a `reason` and a `message`:
  - `limited`: more shapes match than are listed (`2 of 7 listed. …`);
  - `editing`: a shape listed, or one whose text the query read, is being typed into: it's read as typed so far, and may still change;
  - `no_title_match`: `[title="…"]` matched nothing, with the titles like it;
  - `pending`: answers that edges depend on were still arriving when the wait for them ran out, so what the query says of edges may change (`canvas query` waits up to 2 seconds for them, and only for a query that has an edge word);
  - `repaired`: with `--ask`, the answer is Claude's second, since its first query was refused or its first answer wasn't a query on one line.

A connection's row (`arrow[channel=note-link]`):

```json
{"id": "00000000-0000-4000-8000-000000000008", "kind": "arrow", "board": "root",
 "properties": {"bend": 0, "channel": "note-link", "endArrowhead": true, "startArrowhead": false},
 "connection": {"type": "note-link", "from": {"id": "00000000-0000-4000-8000-000000000002", "title": "API gateway"},
                "to": {"id": "00000000-0000-4000-8000-000000000003", "title": "Auth"}}}
```

`--count` leaves `rows` out. As text, for a person at a terminal, the rows are a table (id, kind, title, board, inside), each one's attributes under it.

## What a query sees

- **Every shape the app can show, on every board of the file.** A shape the app keeps aside (a kind this app doesn't have, from a newer app) and a board it can't show aren't in any answer; `#` with such a shape's id says which it is.
- **File order.** Every answer lists its shapes as the top board holds them, back to front, each subboard followed at once by what its board holds, and each frame by what's in it, all the way down. The same query on the same file answers in the same order.
- **When.** An answer is the file as it was when the app took up the query, but for titles a shape works out from what it holds (a schema card's) and whether shapes are valid (`:invalid`, `:warned`), which are as the app has them when the query asks. So a shape changed while the query ran can answer with its newer title or verdict. The board the window shows (`:current-board`) and what's selected (`:selected`) are as they were when the query started.
- **Names as the app shows them.** A title is a shape's name, derived ones included. Text that mentions shapes reads as a person reads it, each mention `@` and the name of what it mentions now, never the form it's stored in.
- **Edges are read settled.** An arrow into a shape that stands for other shapes counts as an arrow into each of them, so `:edge-to`, `:connected-to`, `:downstream-of`, `:between` and the rest read through it. A query with an edge word that runs right after a `draw` waits, up to 2 seconds, for answers that are still arriving, and says `pending` if they hadn't.
- **A query changes nothing.** No shape, no selection, no step of undo, and it never ends the person's typing: a note being typed into reads as typed so far (its last keystroke), and the answer warns that it may still change.

## Naming shapes

A part of a query (a compound) starts with at most one of these, then any number of tests written right after it, with no space: `sticky-note[locked]:top-level`.

| form | matches | refused when |
|---|---|---|
| `sticky-note` | every shape of that kind | no kind has that id: `unknown_kind`, with the kind like it (`note` → `sticky-note`, a Note) |
| `*` | every shape | |
| `"Checkout"` | every shape titled exactly that (the whole title; capitals count), named or derived | no shape has that title: `unknown_title`, with the titles like it |
| `sticky-note"Checkout"` | every shape of that kind titled exactly that: the kind, then the title with no space between | as a kind is, and as a title is; `unknown_attribute` for a kind whose shapes have no titles (`arrow"Auth"`) |
| `#00000000-0000-4000-8000-000000000011` | the shape with that id, in any case | no shape the app can show has it (`unknown_id`), or it isn't an id (`not_an_id`) |

A kind is its id, as `build/canvas query-vocabulary` writes it: `sticky-note`, never its label, "Note". Titles are in double quotes (single quotes work too), and match as `draw` matches them: the whole title, folded (runs of spaces and new lines as one space), case and all. A title can name several shapes across a file, and names them all. A kind and a title together, with no space between, is the shapes of that kind with that title: `sticky-note"Checkout"` finds what `sticky-note[title="Checkout"]` finds, but a title no shape has is refused, as `"Checkout"` alone is. A title some shape has, but none of that kind, matches nothing. With a space between, it's a title inside the kind's shapes ([Inside](#inside)), which a note can't have.

```query
/* matches: "Checkout", "Refund policy", (sticky-note), "API gateway", "Auth", (sticky-note), "Ledger" */
sticky-note
```

```query
/* matches: "Payments", "Checkout", "Refunds", "Refund policy", (sticky-note), "API gateway", "Auth", (sticky-note), "Warehouse", "Order", (schema-card), (arrow), (arrow), "Ledger" */
*
```

```query
/* matches: "Checkout" */
"Checkout"
```

A schema card's title is its schema's `"title"`, worked out from what it holds:

```query
/* matches: "Order" */
"Order"
```

A kind and a title together:

```query
/* matches: "Checkout" */
sticky-note"Checkout"
```

```query
/* matches: "Order" */
schema-card"Order"
```

```query
/* matches: */
subboard"Checkout"
```

An id comes from an earlier answer's rows:

```query
/* matches: "Checkout" */
#00000000-0000-4000-8000-000000000011
```

A kind's label isn't its id:

```query-error
/* reason: unknown_kind */
note
```

## Combining

| form | means |
|---|---|
| `A, B` | either: every shape A or B matches, each once, in file order |
| `AB` (one part, no space) | both, of the same shape: `sticky-note[locked]:top-level` |
| `:not(S)` | not matched by S; S is any query: `:not("Payments" *)` is "not inside Payments" |
| `:is(S)`, `:where(S)` | matched by S, the same thing: a list where a single part is wanted, `:is("Auth", "Checkout")` |

```query
/* matches: "Payments", "Refunds", "Warehouse", "Order", (schema-card) */
subboard, schema-card
```

```query
/* matches: "Refund policy" */
"Payments" sticky-note[locked]
```

```query
/* matches: "Payments" */
:is(subboard, schema-card):edge-from(*)
```

## Attributes

An attribute is a property of the kind, as its schema says (`build/canvas query-vocabulary` lists each kind's, and what each takes), and `title`, for the kinds whose shapes have titles, derived ones too. `[…]` right after a part of a query tests one:

| test | means |
|---|---|
| `[a]` | has a value that says something: true, for a true/false attribute; text or a list that isn't empty; any number or date |
| `[a=v]` | equals |
| `[a!=v]` | doesn't equal: the same as `:not([a=v])`, so shapes without `a`, and of kinds that don't have it, match too |
| `[a=""]` | has no value: text, a date or a choice that isn't set or is empty, and a shape with no title (`[title=""]`); `[a!=""]` is its `:not` |
| `[a^=v]`, `[a$=v]`, `[a*=v]` | text that starts with, ends with, contains |
| `[a~=v]` | a list that holds `v`; text that has `v` as a word (between spaces) |
| `[a\|=v]` | text that's `v`, or starts with `v-` |
| `[a<v]`, `[a<=v]`, `[a>v]`, `[a>=v]` | numbers and dates |
| `[a=v i]` | `i` before the `]` compares text in any case (`s`, the default, case and all) |

The value after the operator is read as the attribute takes it, so `[bend=0]` and `[bend="0"]` are the same test. Quote a value with spaces, `]` or quotes in it. What each kind of attribute takes:

| the attribute is | `=` `!=` | `^=` `$=` `*=` `\|=` | `~=` | `<` `<=` `>` `>=` | the value |
|---|---|---|---|---|---|
| text | exactly; `i` in any case; `""`, no value | yes | a word | refused | any text |
| text that mentions shapes (a note's or an arrow's `text`) | on the text as it reads: each mention `@` and its name now; `""`, no value | yes | a word | refused | any text |
| a date | `YYYY-MM-DD` matches any time that day (UTC); a time, that instant; `""`, no date | refused | refused | a day: `<` before it starts, `<=` before it ends, `>` after it ends, `>=` from its start | `YYYY-MM-DD`, or ISO 8601 |
| one of a few choices | the choice; `i` in any case; `""`, none | as text | as text | refused | one of them, with the one like it named when it isn't |
| a number | the number | refused | refused | yes | a finite number |
| a whole number | the number (a fraction is refused) | refused | refused | yes | a finite number |
| true or false | as set, and false when not set | refused | refused | refused | `true` or `false` |
| a list | refused: use `~=` | refused | an item equals | refused | what an item takes |
| an object | refused (not built) | refused | refused | refused | — |

- **Not set is false.** A true-or-false attribute a shape hasn't set is its default, else false: `[locked=false]` matches every shape that isn't locked. `[locked]` is the same as `[locked=true]`.
- **`""` is no value.** On text, a date or a choice, `[a=""]` matches a shape whose kind has `a` and that hasn't set it, or has it empty: `sticky-note[title=""]` is the notes with no title (a blank title is none), the same as `sticky-note:not([title])`, and `arrow[channel=""]` a plain arrow. `^=`, `$=` and `*=` with `""` match nothing, as in CSS.
- **In a part with a kind**, the attribute must be that kind's (`unknown_attribute`, with its attributes listed). **In a part without one**, it must be some kind's, and the test applies to the kinds that have it: `[text*="x"]` is about notes.
- **Text that mentions shapes is compared as it reads.** A note's or an arrow's `text` holds its mentions as ids, which never reach you: a query reads each as `@` and the name of the shape it mentions now, so a rename changes what matches. To follow a mention, use `:mentions(…)`.
- **Where a shape is isn't an attribute** (`frame`, a line's `points`, an arrow's `start` and `end` are `not_built`), and neither is anything inside an attribute (`[a.b]`).

```query
/* matches: "Checkout" */
[title="checkout" i]
```

```query
/* matches: "API gateway" */
[title^="API"]
```

```query
/* matches: "Checkout", "Refund policy", "API gateway", "Auth", "Ledger" */
sticky-note[title]
```

```query
/* matches: (sticky-note), (sticky-note) */
sticky-note:not([title])
```

```query
/* matches: (sticky-note), (sticky-note) */
sticky-note[title=""]
```

```query
/* matches: "Refund policy", "Order" */
[locked]
```

```query
/* count: 12 */
[locked=false]
```

```query
/* matches: (sticky-note) */
sticky-note[text*="TODO"]
```

A mention reads as `@` and the name of what it mentions:

```query
/* matches: "Checkout" */
sticky-note[text*="@API gateway"]
```

An arrow drawn on a channel has it; one drawn on none has none:

```query
/* matches: (arrow) */
arrow[channel]
```

```query
/* matches: (arrow) */
arrow:not([channel])
```

```query
/* matches: (arrow) */
arrow[channel=""]
```

```query
/* matches: (arrow) */
arrow[channel=note-link]
```

```query
/* matches: (arrow), (arrow) */
arrow[bend=0]
```

`[title="…"]` asks whether a title is there without being refused when it isn't: no shape is titled Chekout, so it matches nothing, and warns (`no_title_match`) with the titles like it, "Checkout".

```query
/* matches: */
[title="Chekout"]
```

## Text

`:contains("retry")` matches a shape whose title, or any text in its attributes, holds the text, in any case, each read as a person reads it. It's a filter, not a search: no ranking, and no words that mean the same. Its argument is one quoted string that isn't empty.

```query
/* matches: "API gateway", "Auth" */
:contains("auth")
```

## Inside

Two kinds hold shapes. A subboard holds a board of shapes: a shape on that board, or on a board inside it, is inside the subboard. A frame holds shapes on the board it's on: a shape in it, or in a frame in it, or on the board of a subboard in it, is inside the frame. It's one tree, whatever holds what, so every form here reads a frame as it reads a subboard: `"Sprint 3" sticky-note` is every note in the frame called Sprint 3, at any depth, `frame"Sprint 3" > *` what's directly in it, and `frame:has("Login bug")` the frames Login bug is in. That's the only inside a query knows: a shape drawn over a note or a subboard's card (what `draw`'s `inside` places) isn't inside it; over a frame, it's in the frame, since nothing sits across a frame's edge.

| form | means |
|---|---|
| `A B` | B, inside some A, at any depth |
| `A > B` | B, directly inside some A: on a subboard's board and in no frame there, or in a frame |
| `:inside(S)` | inside a shape S matches, at any depth: `"Refund policy":inside("Payments")` asks it of one shape |
| `:has(S)` | has a shape S matches inside it, at any depth |
| `:has(> S)` | has a shape S matches directly inside it: is its parent |
| `:top-level` | on the file's top board and in no frame: inside nothing |
| `:current-board` | on the board the file's window shows |

```query
/* matches: "Checkout", "Refunds", (sticky-note) */
"Payments" > *
```

```query
/* matches: "Checkout", "Refunds", "Refund policy", (sticky-note) */
"Payments" *
```

```query
/* matches: "Checkout", "Refund policy", (sticky-note) */
sticky-note:inside("Payments")
```

```query
/* matches: "Payments", "Refunds" */
subboard:has("Refund policy")
```

```query
/* matches: "Refunds" */
:has(> "Refund policy")
```

```query
/* matches: */
"Payments":has(> "Refund policy")
```

```query
/* matches: "API gateway", "Auth", (sticky-note), "Ledger" */
sticky-note:top-level
```

```query
/* matches: "Payments", "API gateway", "Auth", (sticky-note), "Warehouse", "Order", (schema-card), (arrow), (arrow), "Ledger" */
:current-board
```

- **Parents and ancestors** are said with these: "is A B's parent?" is `"A":has(> "B")`, "is A an ancestor of B?" is `"A":has("B")`, and "what's directly in B?" is `"B" > *`. `:parent-of`, `:child-of`, `:ancestor-of` and `:descendant-of` are refused, each with the form to write.
- **`:has()` holds parts, each alone or after a `>`**, commas between them meaning either. A space or a `>` between two parts inside it is refused (`unsupported`), and the hint writes the same question another way, where the part before can hold shapes (else it lists the kinds that can).
- **No space before a test.** A space means inside, so a part after a space must start with a kind, `*`, a title or an id. `sticky-note :selected` would ask for selected shapes inside notes, and is refused (`stray_space`): a selected note is `sticky-note:selected`. For a selected shape inside a subboard, put a `*` after the space: `subboard *:selected`. After a `>`, the part may start with a test: `"Payments" > :selected`.

```query-error
/* reason: stray_space */
sticky-note :selected
```

Auth, the shape selected, is on the top board, inside nothing:

```query
/* matches: */
subboard *:selected
```

- **What holds nothing can't have anything inside it.** When the container side of a space, a `>`, `:inside()` or `:has()` can only be kinds that hold no shapes (a schema card, a note, named straight or through `:is()` or `:where()`), the query is refused (`cannot_contain`), with the kinds that do. Being drawn within the bounds of a shape that holds none isn't something a query can ask yet.

```query-error
/* reason: cannot_contain */
:inside("Warehouse")
```

## Edges and direction

An edge joins two shapes, from one to the other: an arrow bound at both ends, from the shape it starts on to the shape it ends on, whatever its arrowheads; and a mention, from the shape whose text holds it to the shape it names. Each has a type ([Edge types](#edge-types)). The words say what the **result** does; the anchor is what the argument matches:

| form | the result |
|---|---|
| `:edge-to(S)` | has an edge to an anchor (result → anchor) |
| `:edge-from(S)` | has an edge from an anchor (anchor → result) |
| `:connected-to(S)` | either of the two: connected to an anchor directly |
| `:dangling` | has an edge to a shape that isn't there: gone from the file, kept aside, or on a board the app can't show |

To pick the word, name the anchor and the shapes the question asks for, then ask which way the edge runs: from the result to the anchor is `:edge-to`, from the anchor to the result is `:edge-from`. The shape the question names is the anchor, in the parentheses, and the query starts with what it asks for. "What links to Auth?" is `:edge-to("Auth", arrow)`; "what does API gateway link to?" is `:edge-from("API gateway", arrow)`; "what's connected to Checkout?", either way, is `:connected-to("Checkout")`.

```query
/* matches: "API gateway" */
:edge-to("Auth")
```

```query
/* matches: "Checkout", "Auth" */
:edge-from("API gateway")
```

```query
/* matches: "API gateway" */
:connected-to("Checkout")
```

- **The anchor** is a query without commas, spaces and `>` included: `:edge-to("Payments" sticky-note)`. `*` is any shape: `:edge-to(*)` has an edge to anything. For several anchors, `:is()`: `:edge-to(:is("Auth", "Checkout"))`.
- **Edge types go after a comma**, joined by `|`. A type takes in the types under it: `arrow` is every arrow, `note-link` ones too. `only` before a type is that type alone. With no type, every edge counts, mentions too. A comma after the anchor always starts the types, so `:edge-to("Auth", "Checkout")` is refused (`bad_argument`) with the `:is` form as the hint, and `:edge-to("Auth", sticky-note)` too (`unknown_edge_type`: a kind isn't an edge type).

```query
/* matches: "Auth" */
:edge-from("API gateway", arrow)
```

API gateway's arrow is on the note-link channel, so it isn't a plain arrow:

```query
/* matches: */
:edge-from("API gateway", only arrow)
```

```query
/* matches: "Warehouse" */
:edge-to("Payments", only arrow)
```

```query
/* matches: "Checkout", "Auth" */
:edge-from("API gateway", note-link|mention)
```

```query
/* matches: "API gateway" */
sticky-note:edge-to(*, note-link)
```

- **An end that isn't a shape the query sees** (gone, kept aside, or on a board the app can't show) never makes an anchor match and is never an answer. `:dangling` finds what carries such an edge, of the types in its brackets if it has any. A mention of a shape that's there but can't be mentioned (an arrow) shows a dashed pill too, but isn't dangling: validation warns about it, so it's `:warned`.

```query
/* matches: "Ledger" */
:dangling
```

```query
/* matches: "Ledger" */
sticky-note:dangling(mention)
```

A shape that's gone has no title a query can name, so the shapes that mention it are found with `:dangling`, not by its name, as the refusal's hint says ("Some mention edges point at shapes that aren't there: :dangling(mention) finds what carries them."):

```query-error
/* reason: unknown_title */
:mentions("Old ledger")
```

## Transitive words

| form | the result |
|---|---|
| `:downstream-of(S)` | reached from an anchor by one edge or more, each followed forward |
| `:upstream-of(S)` | reaches an anchor by one edge or more, each followed forward |
| `:component-of(S)` | joined to an anchor by one edge or more, either way: in its connected component |

They take types as the one-step words do: `:downstream-of("API gateway", arrow)`. An anchor is part of its own answer only when a path of one edge or more leads back to it (Checkout mentions API gateway, which mentions Checkout); `:component-of` never answers a shape for being itself.

```query
/* matches: "Checkout", "API gateway", "Auth" */
:downstream-of("Checkout")
```

```query
/* matches: "Checkout", "API gateway" */
:upstream-of("Auth")
```

```query
/* matches: "Payments" */
:component-of("Warehouse")
```

## Connections

A connection is a shape that is itself an edge: an arrow bound at both ends. These words are about the connection, not the shapes it joins, and a row for one says where it runs (`connection`, [The result](#the-result)):

| form | the result |
|---|---|
| `:starts-at(S)` | a connection that starts at an anchor |
| `:ends-at(S)` | a connection that ends at an anchor |
| `:between(A, B)` | a connection joining a shape A matches and one B matches, either way |

Each takes types after its anchors. A note's mentions don't make it a connection.

```query
/* matches: (arrow) */
arrow:starts-at("Warehouse")
```

```query
/* matches: (arrow) */
arrow:ends-at("Auth")
```

```query
/* matches: (arrow) */
arrow:between("Auth", "API gateway")
```

The inverse words ask where connections run. Their anchor is a connection, and the result is each shape it starts on or ends on:

| form | the result |
|---|---|
| `:start-of(S)` | the shape a connection S matches starts at |
| `:end-of(S)` | the shape a connection S matches ends at |

Types go after the anchor, as for the others. A shape that is no connection has no ends, and a note's mentions don't make it one: `:end-of(sticky-note)` finds nothing. An end is read as every edge word reads one, so an arrow into a shape that stands for others ends at each of them.

```query
/* matches: "Payments" */
:end-of(arrow:starts-at("Warehouse"))
```

```query
/* matches: "API gateway" */
:start-of(arrow:ends-at("Auth"))
```

The shapes every arrow ends on, and those a note-link arrow ends on:

```query
/* matches: "Payments", "Auth" */
:end-of(arrow)
```

```query
/* matches: "Auth" */
:end-of(arrow, note-link)
```

```query
/* matches: */
:end-of(sticky-note)
```

## Plugins' words

Words the app's plugins add, as this app has them. Without a plugin, its words are `unknown_pseudo_class`. A word's `S` is any query, commas meaning either: `:mentions("Auth", "Checkout")` mentions either.

| pseudo-class | from | means |
|---|---|---|
| `:mentions(S)` | `mention-queries` | its text mentions a shape S matches |
| `:mentioned-by(S)` | `mention-queries` | a shape S matches mentions it |
| `:invalid` | `validation-queries` | it has an error |
| `:warned` | `validation-queries` | it has a warning |
| `:selected` | `selection-queries` | the person has it selected |

- `:mentions` and `:mentioned-by` follow mention edges: `:mentions(S)` is `:edge-to(S, only mention)`. A shape that mentions itself counts.
- `:invalid` and `:warned` are what validation finds, on every board of the file, not only the one shown: an error outlines a shape in red, warnings alone in orange.
- `:selected` is what the person had selected as the query started.

```query
/* matches: "Checkout" */
sticky-note:mentions("API gateway")
```

```query
/* matches: "Checkout" */
"Checkout":mentioned-by("API gateway")
```

```query
/* matches: "Checkout", "API gateway" */
:mentioned-by(*)
```

Ledger's mention is of a shape that's gone, so it mentions nothing a query sees:

```query
/* matches: "Refund policy", (sticky-note), "Auth", (sticky-note), "Ledger" */
sticky-note:not(:mentions(*))
```

```query
/* matches: "Auth" */
:selected
```

The schema card whose schema isn't JSON has an error:

```query
/* matches: (schema-card) */
:invalid
```

```query
/* matches: */
:warned
```

## Edge types

The edge types this app has. A type takes in those under it.

| edge type | under | means |
|---|---|---|
| `stands-for` | — | from a shape to each shape it stands for |
| `mention` | — | a mention in a shape's text, from that shape to the shape it names |
| `arrow` | — | an arrow bound at both ends, from the shape it starts on to the shape it ends on, whatever its arrowheads |
| `note-link` | `arrow` | an arrow drawn on the note-link channel |
| `subboard-link` | `arrow` | an arrow drawn on the subboard-link channel |
| `schema-link` | `arrow` | an arrow drawn on the schema-link channel |

`stands-for` is the app's own, from a shape that stands for others to each of them. A `reference` that names a shape stands for it while it's public, so an arrow into the reference is an arrow into that shape ([references.md](references.md) runs on a file that has one).

A type the app doesn't declare but the file has (a newer app's channel) is accepted as it's written; one the app doesn't declare and the file doesn't have is `unknown_edge_type`, with the type like it.

## Yes or no, and counts

A yes-or-no question is a query that matches the shape it asks about, or nothing: `count` is 1 for yes and 0 for no, and `canvas` exits 0 either way. "Is Refund policy inside Payments?"

```query
/* count: 1 */
"Refund policy":inside("Payments")
```

"Is Checkout inside Refunds?"

```query
/* count: 0 */
"Checkout":inside("Refunds")
```

A title or an id that no shape has is refused, never answered 0, so a no always means the shape is there and the answer is no. To ask whether a title is there at all, write `[title="…"]`, whose count of 0 is an answer. When a title names several shapes, the rows say which of them it holds for. "How many" is the query's `count`; `--count` returns only that.

## From English

`build/canvas query --board 2 --ask "which notes mention the gateway?"` has the app ask Claude (Claude Haiku 5.5, the model the app's evaluation of this prompt picked: it answered 1,907 of its 1,920 runs right, 1,904 of them the first time; with the key the person saved in Infinite Canvas › Settings…) to write the query, runs it, and answers as a query does, with `asked`, the question, and `query`, what Claude wrote: read it, to check it asks what the person meant. A query Claude writes that's refused, or an answer that isn't one, is sent back once, with what was wrong, if that happens within 40 seconds; the answer warns `repaired` when it's the second. It waits up to 60 seconds.

What leaves the machine: the question, what the app's queries can name (`query-vocabulary`'s `vocabulary`), the names of the boards on the way to the one shown, what's selected (by title and kind, or kind and id), and up to 200 titles with their kinds and boards. Never a shape's text.

Use it to pass on the person's own question. When you know what to ask, write the query yourself: you see a refusal and fix it in one step. [../query-prompt.md](../query-prompt.md) is what the app tells Claude, word for word, with how to give yourself what it's given; its direction procedure for edge words is the one above.

Its refusals, besides a query's: `no_model` (the app has no language model), `no_key` (no key saved) and `key_rejected`, `model_failed` (Claude couldn't be reached, or didn't answer; the error's `transient` says whether trying again may work), `declined`, `unanswerable` (no query can say it: where shapes sit, how they look, sums; the message says why), and `unusable_answer` (Claude's query was refused twice, or refused once after 40 seconds, or its answer wasn't a query; the error's `query` is what it wrote last). Each hint says what to do, and writing the query yourself always works.

## Errors

When a query is refused, nothing is answered. The refusal goes to standard error:

```json
{"error": {"reason": "unknown_pseudo_class", "message": ":mention isn't a pseudo-class.",
           "hint": "Did you mean :mentions? :mentions(S): its text mentions a shape S matches.",
           "status": 1, "line": 1, "column": 12, "length": 8, "statement": "sticky-note:mention(\"API gateway\")"}}
```

`reason` is what to branch on. `message` says what's wrong in the query's own terms, and `hint` is usually the query to write. `line` and `column` (from 1) and `length` say where: `statement` is that line as sent, and the column and length count its characters. A query refused for several mistakes that don't hang on each other lists them all in `errors`, each where it is. As text, it reads `canvas: line 1, column 12: <message>`, then the line with carets under what's wrong, then `hint: …`, then each further mistake.

The messages are examples. The wording can differ, but the reason doesn't.

| reason | what it means | what to write |
|---|---|---|
| `empty_query` | Nothing but spaces and comments. | `*` is every shape. |
| `syntax` | The query can't be read: `[text*="x"` isn't closed, a comma at the end, two heads in one part (`"Checkout"sticky-note`). | The hint, usually the query mended: `[text*="x"]`, `sticky-note"Checkout"`. |
| `stray_space` | A space before a test: `sticky-note :selected` asks for shapes inside notes. | No space for one shape (`sticky-note:selected`); for a shape inside a subboard, a `*` after the space (`subboard *:selected`), which the hint offers only where what's before the space can hold shapes. |
| `too_long`, `too_complex` | Over 8192 characters, 32 levels of brackets, or 256 parts. | Several shorter queries. |
| `unsupported` | CSS with no meaning here: `+` and `~` (shapes have no siblings), `\|\|`, `::before`, namespaces, `:nth-child` and the like, `:root`, `:empty`, `:hover`, a space or `>` inside `:has()`. | The hint's form, if it has one: `:top-level` for `:root`. |
| `not_built` | Planned, not built: `.Task` (shapes typed by schema cards), where shapes sit (`:near`, `:left-of`, `:within`, …), `frame` and the other attributes that say where a shape is, `[a.b]`, `=` on an object. | `:contains("Task")`, a kind, or what the hint names. |
| `unknown_kind` | No kind has that id: `note`; a title without its quotes, `:mentions(Checkout)`. | The kind like it: `sticky-note`; the title in quotes, `"Checkout"`, when a shape has it. |
| `unknown_attribute` | Not the kind's attribute, nor any kind's: `sticky-note[txt*="x"]`; `[kind=…]`, `[id=…]`, `[name=…]`; `title` on a kind without titles, `arrow"Auth"` too; `--fields` naming one no kind has. | The attribute like it, from the kind's list in the hint; the kind itself, `#id`, or `[title=…]`. |
| `unknown_pseudo_class` | Not the language's, nor a plugin's: `:mention(…)`; `:parent-of(…)` and the other invented words; `:locked`. | The word like it, or the form the hint writes: `:has(> …)`, `[locked]`. |
| `unknown_edge_type` | Not a type the app has, nor the file: `:edge-to("Auth", link)`; a kind where a type goes. | The type like it (`note-link`); for several anchors, `:is(…)`. |
| `unknown_title` | No shape has that title: `"Chekout"`. | The title like it, exactly (`"Checkout"`); `[title="…"]` to ask whether one is there. For a shape that's gone, `:dangling` finds what mentioned it: the hint says so when an edge points at a shape that isn't there. |
| `unknown_id` | No shape the app can show has that id: it was deleted, or is kept aside, or on a board the app can't show. | Run the query that gave it again. |
| `not_an_id` | `#` without an id: `#Checkout`. | A title in double quotes: `"Checkout"`, which the hint offers when a shape has it. |
| `invalid_value` | A value the attribute can't take: `arrow[bend>far]`, `[locked=maybe]`. | A value of what the hint says it takes. |
| `unsupported_operator` | An operator the attribute's type has no meaning for: `sticky-note[text<5]`; `i` on a number. | One the hint names: `*=`, `^=`, `$=` or `=` for text. |
| `bad_argument` | A word's brackets hold the wrong thing: `:contains(API)`, `:selected("x")`, `:between("Auth")`, `:edge-to("Auth", "Checkout")`. | The hint's form: `:contains("API")`, `:edge-to(:is("Auth", "Checkout"))`. |
| `cannot_contain` | The container side can only be kinds that hold no shapes: `:inside("Warehouse")`; `sticky-note "Checkout"`, a title inside a note. | A subboard or a frame, or another question: where shapes sit isn't in the language; for a kind and a title, the two together, `sticky-note"Checkout"`. |
| `no_names` | Nothing in this app names shapes, so titles can't be used. | Kinds, ids and attributes. |
| `no_topology` | Nothing in this app knows what's on which board, or what connects to what. | Nothing: no query can be answered. |
| `no_queries` | Nothing in this app answers queries. | Nothing: `canvas query` can't work here. |
| `too_slow` | The query took more than 8 seconds (`--ask`: 55). | Start from a kind, a title or an id, or give the transitive words a type. |
| `board_closed` | The file was closed while the query ran. | Open it, and ask again. |
| `invalid_params` | The options don't go together (`--brief` with `--fields`), no query and no `--ask`, or `--limit` out of 1 to 10000. | `build/canvas help query`. |
| `no_board`, `ambiguous_board`, `unknown_board` | No file is open, several are and none is in front, or `--board` names none. | `build/canvas boards`, and `--board <id>`. |
| `usage` | The command line is wrong (exit 2). | `build/canvas help query`. |
| `not_running`, `unreachable`, `protocol_mismatch`, `timed_out` | The app wasn't reached, or didn't answer in time (exit 3). When `canvas` stops waiting, the app stops the query too. | As for `draw` ([language.md](language.md#errors)). A query changes nothing, so after `timed_out` ask again, with a longer `--timeout`. |

These are refused on the story file:

```query-error
/* reason: empty_query */
```

```query-error
/* reason: syntax */
[text*="x"
```

```query-error
/* reason: stray_space */
subboard [locked]
```

```query-error
/* reason: too_complex */
:is(:is(:is(:is(:is(:is(:is(:is(:is(:is(:is(:is(:is(:is(:is(:is(:is(:is(:is(:is(:is(:is(:is(:is(:is(:is(:is(:is(:is(:is(:is(:is(:is(*)))))))))))))))))))))))))))))))))
```

```query-error
/* reason: unsupported */
sticky-note + sticky-note
```

```query-error
/* reason: not_built */
.Task
```

```query-error
/* reason: unknown_kind */
Sticky-Note
```

```query-error
/* reason: unknown_attribute */
sticky-note[txt*="x"]
```

```query-error
/* reason: unknown_pseudo_class */
:parent-of("Refund policy")
```

```query-error
/* reason: unknown_edge_type */
:edge-to("Auth", link)
```

```query-error
/* reason: unknown_title */
"Chekout"
```

```query-error
/* reason: unknown_id */
#00000000-0000-4000-8000-0000000000EE
```

```query-error
/* reason: not_an_id */
#Checkout
```

```query-error
/* reason: invalid_value */
arrow[bend>far]
```

```query-error
/* reason: unsupported_operator */
sticky-note[text<5]
```

```query-error
/* reason: bad_argument */
:contains(API)
```

```query-error
/* reason: cannot_contain */
"Warehouse" *
```

```query-error
/* reason: cannot_contain */
sticky-note "Checkout"
```

## What the language refuses

These are left out on purpose. What they protect is that a query means one thing, and that "no" means no.

- **Guessing.** A kind, an attribute, a word, an edge type, a title or an id the app doesn't have is refused, with the one like it, never ignored: a query that runs asked what it says. A title that isn't there is refused rather than answered 0, so a typo never reads as "no".
- **CSS with no meaning here.** Shapes have no siblings, order or columns (`+`, `~`, `:nth-child`, `||`), no pseudo-elements, no namespaces, and a query sees no pointer (`:hover`). Each is refused rather than read some other way.
- **Words that read two ways.** "Parent of" and "child of" are said as `:has(> …)` and `… > *`, and edges' direction words say what the result does. `:source-of` and `:target-of`, an older language's words, and `:neighbor-of`, this one's old name for `:connected-to`, are refused with the word to write.
- **A space that means two things.** A space is always inside, so one before a test is refused.
- **Where shapes are drawn.** Inside is a subboard's board, or a frame. What's inside a note is refused (`cannot_contain`), never read as what's drawn within its bounds.

## Honest limits

- **Where shapes are isn't read.** A query sees what's inside what by boards and frames, and what's connected to what by edges, never positions, sizes or overlaps.
- **Text being typed** reads as typed so far, and the answer warns that it may still change (`editing`).
- **Shapes the app keeps aside**, and those on boards it can't show, aren't in any answer.
- **Derived titles and validity are as the app has them when asked**, so a query that runs while the person edits can answer with a schema card's newer title, or a newer verdict, than the rest of its answer.
- **A shape that's gone can't be named**: find what mentioned it with `:dangling`.
- **`--fields` lists what it can**: an attribute a shape's kind doesn't have is left out of its row; only one no kind has is refused.

## Not built yet

- **Where shapes sit**: `:near`, `:left-of`, `:right-of`, `:above`, `:below`, `:overlaps`, `:within`, and attributes that say where a shape is.
- **Shapes typed by schema cards** (`.Task`).
- **Attributes inside attributes** (`[a.b]`), and `=` on an object.
- **Edges as answers.** A query lists shapes; an arrow is a shape, so ask for arrows (`arrow:starts-at("A"):ends-at("B")`), and for the shapes at their ends with `:start-of` and `:end-of`.
- **Search**: ranking, stemming, words that mean the same. `:contains` is a filter.
- **Selecting or revealing what a query found**, and a query box in the app.
- **Positions in rows**: a row says where a shape is by board, not by coordinates.

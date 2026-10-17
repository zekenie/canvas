<!-- ids: 7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11, B3D9F0E1-6A52-4C8D-A7E4-1F2B9C3D5E60 -->
# Relationships

A **relationship** is an arrow between two notes that is of a **relationship type** and holds that type's values: Ann works at Acme, as an Employment with a role and a start date. A relationship type is a type (a note with a `schema:`) that says what a relationship holds, and which types it runs from and to. Nothing here is a new statement or a new key: a relationship type is `relationship: true` on a note with a `schema:`, its ends are `edge`s between it and the types it relates, and a relationship is an `edge` with `is:` and `fieldValues:`.

The examples on this page are all one story, drawn in order on a board of its own. A block tagged `draw` is a script run for real, and a block tagged `query` a query as you'd send it, whose first line, a comment, says what it answers. The words are the ones the app shipped with when this was written. The ids in [the section on notes with no title](#a-note-with-no-title) are samples: a board's own are whatever its query's rows give.

## Contents

- [Declaring a relationship type and its ends](#declaring-a-relationship-type-and-its-ends)
- [Relating two notes](#relating-two-notes)
- [Reading them back](#reading-them-back)
- [What a row says](#what-a-row-says)
- [A misfit](#a-misfit)
- [Needed and Only one](#needed-and-only-one)
- [Drawing one again](#drawing-one-again)
- [A note with no title](#a-note-with-no-title)
- [What will bite you](#what-will-bite-you)

## Declaring a relationship type and its ends

Person and Company are types. Employment is a relationship type that sits between them: write the note with `relationship: true` beside its `schema:`, which holds what one job holds (its role and when it started), never who it is between. The `text:` says it in words, and the two agree.

```draw
sticky-note "Person" schema: "{\"type\": \"object\", \"properties\": {\"name\": {\"type\": \"string\"}}}" text: "A person: their name"
sticky-note "Employment" right of "Person" relationship: true schema: "{\"type\": \"object\", \"properties\": {\"role\": {\"type\": \"string\"}, \"since\": {\"type\": \"string\", \"format\": \"date\"}}}" text: "A job: the role, and when it started"
sticky-note "Company" right of "Employment" schema: "{\"type\": \"object\", \"properties\": {\"name\": {\"type\": \"string\"}}}" text: "A company: its name"
```

Its ends are two arrows, one into it and one out of it: an arrow from a type into a relationship type is its **from** end, and an arrow out of it to a type its **to** end. Several arrows on a side mean any of them; a side with no arrow takes any note. An arrow's first line of text names the row it gives the notes at that end (`jobs`, `staff`), and `endRule:` is a JSON object saying what the end asks of each note: `{"needed": true}` that every note has one, `{"onlyOne": true}` at most one ([below](#needed-and-only-one) says how each is checked). A statement sets the members it names and keeps the rest, and `null` takes a member off.

```draw
edge "Person" -> "Employment" text: "jobs" endRule: {"onlyOne": true}
edge "Employment" -> "Company" text: "staff"
```

Those are ordinary arrows. An arrow between two types is plain, and so is one between a relationship type and a note: only an arrow that joins a relationship type and a type is an end, whichever way it points and whatever its heads (a two-headed arrow is read from its start to its end, and draw warns of one at an end: for a type related to itself, write two edges, which are drawn bent apart).

**The types, their ends and the notes may be one run.** A run lays a note out against the ends it draws itself: the rows an end gives the notes of its types are in the `at` of their rows, a dry run says the same, and so does `canvas measure` of the script. A misfit, a missing row and a plain arrow's `fits` are judged by the run's own ends too. Write the model first and the notes after it, as below, in one script or in several. A note the script does not restate keeps the size it had before the run: give an end to a type and the notes already of it grow by their row when the run commits, so a shape you place against one of them in that run is placed against its old size (it may end up under the row). Restate those notes in the script, or place the shape in a run of its own after.

## Relating two notes

Two notes of the types, and the relationship between them: an `edge` that writes `is:` the relationship type's title and `fieldValues:` what it holds, as a note's values are written.

```draw
sticky-note "Ann" below "Person" is: "Person" fieldValues: {"name": "Ann Lee"}
sticky-note "Acme" below "Company" is: "Company" fieldValues: {"name": "Acme"}
edge "Ann" -> "Acme" is: "Employment" fieldValues: {"role": "Staff engineer", "since": "2021-03-01"}
```

An edge is its pair of ends and, when you write one, its `is:`. So writing the edge again is the same relationship, and `edge "Ann" -> "Acme" is: "Mentorship"` beside it is a second arrow between the same two notes, not a replacement. An arrow is of one relationship type: to change it, delete it (`delete edge "Ann" -> "Acme" is: "Employment"`) above the line. Writing `edge "Ann" -> "Acme"` with no `is:` is about the pair, and is refused (`ambiguous_edge`) when it holds two arrows.

```draw
// A relationship, written again: the same arrow, its values kept.
edge "Ann" -> "Acme" is: "Employment"
```

A relationship to a note on another board goes into a reference to that note, as any edge to another board does ([references.md](references.md)): the reference stands for the note, and the relationship is the arrow into it.

## Reading them back

The relationship types are the notes with the mark:

```query
/* matches: "Employment" */
sticky-note[relationship]
```

The relationships of a type are the arrows that are an instance of it, as every instance of a type is:

```query
/* matches: (arrow) */
arrow:is-a("Employment")
```

What a note is related to is the other end of its arrows, read with `:end-of` and `:start-of`. Where Ann works:

```query
/* matches: "Acme" */
:end-of(arrow:is-a("Employment"):starts-at("Ann"))
```

And who works at Acme:

```query
/* matches: "Ann" */
:start-of(arrow:is-a("Employment"):ends-at("Acme"))
```

The ends of Employment are the arrows between it and its types; the arrow from Person into it is found by what it joins:

```query
/* matches: (arrow) */
arrow:between("Person", "Employment")
```

A relationship's values are read by path, as a note's are:

```query
/* matches: (arrow) */
arrow[fieldValues.role="Staff engineer"]
```

## What a row says

`canvas draw` answers a row for each statement, and a row says what an arrow became, beside what every row says. Every member below is left out when it has nothing to say, and a row for a statement that changed nothing (`unchanged`) says it as the first run did.

- `is`: the relationship types the arrow is of, by their titles.
- `endOf`: for an arrow that is an end of a relationship type, `{"type", "side", "row", "needed", "onlyOne"}`: the relationship type, `from` or `to`, the name typed on the arrow (if there is one) and the rules that are set.
- `fits`: for a plain arrow between two notes, the relationship types that would take it, by their titles. `canvas draw` never picks a type for an arrow: write `is:` to give it one.
- `relates`: for a relationship type, `{"from", "to"}`, the titles of the types it runs from and to, or `"anything"` for a side no arrow names.
- `problems`: what is wrong with the arrow's ends, or its values, or, on a note, with its rows (`field` is `from` or `to` for an end, the row's name for a row, else the field's key; `class` is `wrong` or `needed`, or `warning` for an end that cannot be read).

The ends drawn above said what they became:

```json
{"line": 1, "did": "connected", "kind": "arrow", "from": "Person", "to": "Employment", "channel": "note-link",
 "endOf": {"type": "Employment", "side": "from", "row": "jobs", "onlyOne": true}}
```

and the relationship type, written again now that its ends are on the board, says what it relates (it changed nothing):

```draw
sticky-note "Employment"
```

```json
{"line": 1, "did": "unchanged", "kind": "sticky-note", "title": "Employment", "relates": {"from": ["Person"], "to": ["Company"]}}
```

Ann's relationship said `"is": ["Employment"]`. A second note, and an arrow between it and Acme that has no `is:`, says which relationship types would take it:

```draw
sticky-note "Bo" right of "Ann" is: "Person" fieldValues: {"name": "Bo Park"}
edge "Bo" -> "Acme"
```

```json
{"line": 2, "did": "connected", "kind": "arrow", "from": "Bo", "to": "Acme", "channel": "note-link", "fits": ["Employment"]}
```

The arrow is drawn plain. To make it a relationship, write the type: the plain arrow takes it.

```draw
edge "Bo" -> "Acme" is: "Employment" fieldValues: {"role": "Analyst"}
```

```json
{"line": 1, "did": "reconnected", "kind": "arrow", "from": "Bo", "to": "Acme", "channel": "note-link", "is": ["Employment"]}
```

## A misfit

A relationship whose ends are not the types its relationship type runs between is drawn all the same, and said, not refused. Employment runs to a Company, and Bo is a Person:

```draw
edge "Ann" -> "Bo" is: "Employment"
```

The row has `problems` for the end, and the run an error warning, so the arrow is drawn red on the board. The run's second warning is about Ann, whom it did not write: she has two jobs now, and her row allows one ([below](#needed-and-only-one)).

```json
{"line": 1, "did": "connected", "kind": "arrow", "from": "Ann", "to": "Bo", "channel": "note-link", "is": ["Employment"],
 "problems": [{"field": "to", "class": "wrong", "message": "Employment runs to a Company. “Bo” is a Person."}]}
{"line": 1, "severity": "error", "attribute": "to", "message": "edge \"Ann\" -> \"Bo\": Employment runs to a Company. “Bo” is a Person."}
{"line": 1, "severity": "error", "attribute": "jobs", "message": "\"Ann\": jobs has 2 notes, and should have at most 1"}
```

An end that is a note of a type that builds on one of the side's types fits, and so does any note on a side no arrow names. An end that cannot be read (an arrow to a reference whose note is gone, or is not public now) is not a misfit: it is said as a warning. `:misfit` finds the arrows that are misfits, and `:invalid` says why:

```query
/* matches: (arrow) */
arrow:misfit
```

```query
/* matches: (arrow) */
arrow:misfit:invalid
```

Nothing else here is a misfit:

```query
/* count: 2 */
arrow:is-a("Employment"):not(:misfit)
```

## Needed and Only one

An end's rule is checked on the notes at that end, in the row the end gives them. A note of the type with none in a row that is **Needed** has that row still to fill: it is `:incomplete`, its row's `problems` say `staff is needed` (`class` `needed`), and the app shows the row amber. It is not an error: the note is not `:invalid` for it, as a needed field left empty is not. A row that is **Only one** and holds a second relationship is an error on the note: `:invalid`, its `problems` say `jobs has 2 notes, and should have at most 1` (`class` `wrong`), and the app rings the note. Nothing is marked on the arrows. Every relationship of the type in the row counts, a misfit too, and one whose far end cannot be read. `canvas draw` never takes one away for you; to put a different note in a row that is Only one, delete the arrow you mean to replace.

Staff is Needed from now on, so a Company with no one working at it is incomplete. (Validation keeps it as an issue under a warning, which is why `:incomplete` is validation's word beside `:invalid` and `:warned`, and why a run can say it.) A note you draw says it in its row's `problems`, against the ends the same script draws:

```draw
edge "Employment" -> "Company" text: "staff" endRule: {"needed": true}
sticky-note "Initech" below "Acme" is: "Company" fieldValues: {"name": "Initech"}
```

```json
{"line": 2, "did": "created", "kind": "sticky-note", "title": "Initech",
 "problems": [{"field": "staff", "class": "needed", "message": "staff is needed"}]}
```

```query
/* matches: "Initech" */
:incomplete
```

Acme has Ann, and is not in the answer. Employment is Only one at the Person end (`jobs`), and Ann has two: the one at Acme and the misfit just above.

```query
/* matches: "Ann" */
sticky-note:invalid
```

**A run says what it breaks on a note it did not write.** The run that drew the misfit never named Ann as a shape, and warned of her all the same (its second warning, above). Every run does: each issue it brings to a shape none of its statements made or changed is a warning that names the shape by its title, with the issue's `severity` and `attribute` and the `line` of the statement that brought it. So a relationship added by a later run of one line says what it did to the note at its end. Bo works at Acme; a second job for him, at Initech:

```draw
edge "Bo" -> "Initech" is: "Employment"
```

```json
{"line": 1, "did": "connected", "kind": "arrow", "from": "Bo", "to": "Initech", "channel": "note-link", "is": ["Employment"]}
{"line": 1, "severity": "error", "attribute": "jobs", "message": "\"Bo\": jobs has 2 notes, and should have at most 1"}
```

Read the warnings of every run that draws or deletes a relationship, an end or a type: Bo has no row in that answer, and the warning is the only place it says he is wrong now. Only what is new is said: an issue the note had before the run is not repeated, and what a run mends it does not say (an issue whose sentence changes, three notes that become two, is said in its new words). The delete below takes the second job away, which empties the Needed `staff` row Initech had filled: Initech is a note the run did not write, so the run says what it now still needs, at its own level, `incomplete`, which is no error and is not drawn on the board:

```draw
delete edge "Bo" -> "Initech" is: "Employment"
```

```json
{"line": 1, "did": "deleted", "kind": "arrow", "from": "Bo", "to": "Initech", "is": ["Employment"]}
{"line": 1, "severity": "incomplete", "attribute": "staff", "message": "\"Initech\": staff is needed"}
```

A run that breaks many notes at once (a rule set on an end of a type with a thousand notes) names twenty and counts the rest: `and 980 more shapes now have issues: ask canvas query ":invalid, :warned, :incomplete"`.

Take the misfit away too and she has one (`delete edge "Ann" -> "Bo" is: "Employment"`, in the next section), and a note with one is right again.

## Drawing one again

An arrow is its two ends, and, when a statement writes `is:`, its type. Draw the same statements again and each is `unchanged`; draw another type on the same pair and it is a second arrow. Mentorship is another relationship type between Person and Person:

```draw
sticky-note "Mentorship" below "Bo" relationship: true schema: "{\"type\": \"object\", \"properties\": {\"since\": {\"type\": \"string\", \"format\": \"date\"}}}" text: "One person guiding another, and since when"
edge "Person" -> "Mentorship" text: "mentors"
edge "Mentorship" -> "Person" text: "mentees"
```

```draw
edge "Ann" -> "Bo" is: "Mentorship" fieldValues: {"since": "2022-02-01"}
```

Ann and Bo now have two arrows, each said `connected` once and `unchanged` after. The second is stored bent apart from the first (as is any second arrow between one pair, either way, that names no side), so the two read as two; write no `bend:` for it. Writing the pair with no `is:` is about both, and is refused:

```draw-error
// reason: ambiguous_edge
edge "Ann" -> "Bo"
```

`delete edge` takes the arrows of a pair: all of them without an `is:`, and only those of that type with one. Its rows carry `is`.

```draw
delete edge "Ann" -> "Bo" is: "Employment"
```

```query
/* count: 0 */
arrow:misfit
```

```query
/* count: 0 */
sticky-note:invalid
```

Without an `is:`, `delete edge` takes every arrow of the pair, and says so for a typed one:

```draw
delete edge "Ann" -> "Bo"
```

```json
{"line": 1, "did": "deleted", "kind": "arrow", "from": "Ann", "to": "Bo", "is": ["Mentorship"]}
{"line": 1, "severity": "warning", "attribute": "is", "message": "delete edge \"Ann\" -> \"Bo\": it removed an arrow of Mentorship, since a delete edge without is: removes every arrow of the pair"}
```

## A note with no title

A script names a note by its title, and everything above does. Notes a person made are often untitled (their words are their text), and a relationship between two of them is still one an agent can draw: an id, the spelling a query uses, names a shape that has no title, wherever a statement names a shape the file already has. Write one only for a shape with none; where a shape has a title, use it.

Two notes with no title, a Person and a Company, each holding its values:

```draw
sticky-note is: "Person" fieldValues: {"name": "Cy Ng"} below board
sticky-note is: "Company" fieldValues: {"name": "Dunder"} right of board
```

Their rows have no `title`, so nothing else names them. A query finds them, and its rows give each one's `id`:

```query
/* matches: (sticky-note), (sticky-note) */
sticky-note:not([title]):is-a("Person"), sticky-note:not([title]):is-a("Company")
```

```json
{"count": 2, "rows": [{"id": "7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11", "kind": "sticky-note", "board": "root", "properties": {"fieldValues": {"name": "Cy Ng"}}},
                      {"id": "B3D9F0E1-6A52-4C8D-A7E4-1F2B9C3D5E60", "kind": "sticky-note", "board": "root", "properties": {"fieldValues": {"name": "Dunder"}}}]}
```

Those ids go where a title would, with a `#` and no quotes. The relationship between them, with its values:

```draw
edge #7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11 -> #B3D9F0E1-6A52-4C8D-A7E4-1F2B9C3D5E60 is: "Employment" fieldValues: {"role": "Intern"}
```

A row names an end with no title by the id as written, and says which shape it was in `fromId` and `toId` (a row never has them for an end named by its title). The arrow's own row has `is`, as any relationship's:

```json
{"line": 1, "did": "connected", "kind": "arrow", "from": "#7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11", "to": "#B3D9F0E1-6A52-4C8D-A7E4-1F2B9C3D5E60",
 "fromId": "7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11", "toId": "B3D9F0E1-6A52-4C8D-A7E4-1F2B9C3D5E60", "channel": "note-link", "is": ["Employment"]}
```

Read back, an id works in a query as it does in a script:

```query
/* matches: (sticky-note) */
:end-of(arrow:is-a("Employment"):starts-at(#7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11))
```

Every row of a shape the file has carries its `id` (the one just made too, after a real run; a dry run's `created` row has none, because the shape isn't made), so a note you draw without a title can be named by the id its row gave. To give one a title, restate it by its id: the next run names it by the title.

```draw
sticky-note #B3D9F0E1-6A52-4C8D-A7E4-1F2B9C3D5E60 title: "Dunder"
```

An id names a shape the file already has, and never makes one: one that names nothing is refused (`unknown_id`), a malformed one is `not_an_id`, and nothing is drawn. It also names only a shape a title could: an arrow's id or a reference's is `invalid_value` (name an arrow by its two ends, and a reference by the note it stands for).

```draw-error
// reason: unknown_id
edge "Ann" -> #00000000-0000-0000-0000-000000000000
```

A relationship to an untitled note on another board goes through a reference as one to a titled note does, and the reference is called what the note is called where it has no title: its words, else its values.

## What will bite you

- **An end added over notes the script does not restate.** Those notes grow by their row when the run commits, but a shape placed against one of them in the same run is placed against its old size (it can end up under the row), and the same script again says `moved`. Restate the notes in the script, or place the shape in a run of its own.
- **A relationship type is a type, so write both words and schema, and title it**: `is:` names a type by its title, so an untitled one cannot be the type of a relationship (an id names it as an end of an edge, `edge "Person" -> #<id>`, and nowhere else).
- **Never write an id where a title would do.** An id is for a note with no title, from a query's row; it is not a way to rename-proof a titled note, and one you typed from memory is `unknown_id` when the board has changed.
- **A rule is checked on the notes, not the arrows.** `endRule` on an end that gives a row is read by every note of the end's type, and the types that build on it: Needed is `:incomplete` and no error, Only one is `:invalid`. The arrows at the note are not marked for it.
- **`relationship: true` says something only on a note with a `schema:`.** On any other note it is inert, and draw says so in a warning.
- **A relationship type's schema holds what the relationship holds**, never who or what it relates: no `person` or `company` field. The ends are the arrows.
- **An arrow between two types says nothing.** Put a relationship type between them: `edge "Person" -> "Employment"` and `edge "Employment" -> "Company"`.
- **Deleting a type deletes its end arrows** (`delete "Person"` takes `edge "Person" -> "Employment"` with it), and the relationship type then has no end on that side, which takes any note.
- **Deleting a relationship type deletes its end arrows too**, in the same step. If one of them is locked, the script's `delete` is refused (`read_only`) and nothing is deleted: leave the delete out or unlock the arrow (deleted by hand, the type goes and the locked one stays, unattached at the relationship type's end, and the board warns of it). A script that runs on another board than the one on show leaves an end drawn on the board on show where it is. The relationships of the deleted type stay, with a type that is gone.
- **A type related to itself is two edges**, one into the relationship type and one out of it (`edge "Person" -> "Friendship"`, `edge "Friendship" -> "Person"`), never one with `<->`. Draw stores the second bent apart from the first, so the two read as two; write no `bend:`. Name both alike (`text: "friends"`) for one row on a Person, or differently for two rows. An arrow from a note to itself is refused (`no_channel`): a relationship between two Persons is between two notes.

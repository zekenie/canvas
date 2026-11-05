<!-- board: reference-story -->
# References

A **reference** is a pill that stands for another shape, anywhere in the file. A shape that many others point at (an auth service, a glossary entry, a pricing note) doesn't need an arrow from each of them across the board: each draws its arrow to a reference of it, wherever the reference is, and everything that reads the file counts an arrow into the reference as an arrow into the shape it stands for. [language.md](language.md) is where you draw; this page is what a reference does to what you read, so it's about `canvas query`. A query never changes anything.

Only a **public** shape can be stood for. `public` is an attribute, `public: true` in a script, that a person sets from a shape's menu or its chip; a shape that isn't public can't be referenced, and a reference of one that stops being public stands for nothing.

A reference is **direct** (the person picked one shape) or **dynamic** (a query finds what it stands for). A script makes a dynamic one with `query:`, and a direct one only as the stand-in of an edge, to a public shape on another board or with `via: reference` ([language.md](language.md#through-a-reference)): what a reference names, and the words typed into it, are otherwise the person's to pick and type. A dynamic one has no title and stands for no one shape, so a later script names it by its id: an arrow into it, its query changed, its delete ([language.md](language.md#arrows-into-it)). A dynamic one stands for what its query finds among the public shapes, the first in file order or, with `all: true`, every one, however many; the app finds it a moment after it's drawn and again as the file changes, and `canvas query` waits for that (up to two seconds, for a query that reads edges) before it answers. Its query reads what's drawn and what direct references stand for, never what another dynamic one found, nor what the person has selected or the board they're on (`:selected`, `:current-board`): a script that writes one is refused, and a pill that holds one (typed by the person) finds nothing, and says why. The examples below are about a direct one, which is what a person makes first, and which reads the same way for you.

The examples on this page are all about one file, the story below. Each block tagged `query` is a query as you'd send it, and its first line, a comment, says what it answers, as in [query.md](query.md). Each block tagged `draw-error` is a script run as a dry run, refused with the reason its first line names, changing nothing. The kinds and words are the ones that shipped when this was written. `canvas kinds` and `canvas query-vocabulary` say what your app has.

## Contents

- [The story file](#the-story-file)
- [Reading through a reference](#reading-through-a-reference)
- [Which shapes can be stood for](#which-shapes-can-be-stood-for)
- [What a script can and can't do](#what-a-script-can-and-cant-do)

## The story file

"Services": one board, its window showing it.

```text
Services (the board), back to front:
  sticky-note "Auth"       text: JWT, 15 min expiry   public
  sticky-note "Checkout"   text: Takes the payment
  sticky-note "Billing"    text: Sends the invoice
  sticky-note "Drafts"     text: Not for sharing yet
  reference                stands for Auth
  arrow                    from Checkout to the reference, on no channel
  arrow                    from Billing to the reference, on no channel
```

Checkout and Billing both point at the pill, not at Auth: Auth sits far from them, and the pill is where they are.

## Reading through a reference

Every word that follows an edge reads an arrow into a reference as an arrow into what it stands for. The arrow is still drawn into the pill, and `canvas query` says so, but it's an arrow to Auth for everything that asks about Auth.

The arrows that end at Auth:

```query
/* matches: (arrow), (arrow) */
arrow:ends-at("Auth")
```

The notes with an edge to Auth, and the notes connected to it either way:

```query
/* matches: "Checkout", "Billing" */
sticky-note:edge-to("Auth")
```

```query
/* matches: "Checkout", "Billing" */
sticky-note:connected-to("Auth")
```

What is reached from Checkout by following edges is Auth: the pill it was drawn into isn't a stop on the way.

```query
/* matches: "Auth" */
:downstream-of("Checkout")
```

A connection's row says how it was drawn. Its `to` is the shape the arrow ends at *as read*, Auth; `via` names the pill it went through, by `id` alone (a reference has no title); and `more` lists the other pairs, in file order, where the reference stands for several shapes (a dynamic one that finds many). A connection that wasn't drawn into a reference has neither. The first of the arrows above:

```json
"connection":{"type":"arrow","from":{"id":"00000000-0000-4000-8000-000000000002","title":"Checkout"},"to":{"id":"00000000-0000-4000-8000-000000000001","title":"Auth"},"via":{"to":{"id":"00000000-0000-4000-8000-000000000005"}}}
```

The reference is a shape of its own, of the kind `reference`, which is how you find it, and a shape of its own has an edge to what it stands for: the type `stands-for`, from the shape that stands for others to each of them.

```query
/* matches: (reference) */
reference
```

```query
/* matches: (reference) */
reference:edge-to("Auth", stands-for)
```

The other way round, the shapes with a `stands-for` edge from a reference are what it stands for now: how to test one, a dynamic one above all, whose query finds what it stands for. Name it by its row's `id`. For a dynamic one, a query that reads edges waits for the app to find them, as above.

```query
/* matches: "Auth" */
:edge-from(#00000000-0000-4000-8000-000000000005, stands-for)
```

A reference has no title, so a query names it by its kind, or by the `id` of its row (`#00000000-…`), and its row says nothing else of it in `title`. `properties` has what it holds: `target` (the `id` and the `label`, the name it had when it was picked, of the shape it names, for a direct one), `words` (what was typed), `query` (once it has one) and `all` (every match, or the first).

## Which shapes can be stood for

A shape that is `public` can be. The attribute is there for every kind that can be public, and a query reads it as any attribute: `[public]` is the shapes that are.

```query
/* matches: "Auth" */
[public]
```

```query
/* matches: "Checkout", "Billing", "Drafts" */
sticky-note:not([public])
```

A person can't make a shape private while something stands for it (the chip counts what does, and refuses), but a script can write `public:` on any shape that has it, and so can an undo or a paste. A shape that stops being public is no longer stood for: the reference shows it dashed, and its arrows are read at the pill again until the shape is public again. So read `[public]` rather than assuming, and expect a reference to a private shape to stand for nothing. `canvas query` waits up to two seconds for the answers that edges depend on, only for a query with an edge word, and says `pending` in its warnings if they were still arriving.

## What a script can and can't do

A script draws a direct reference when an edge needs one: an edge between shapes on two boards goes into a reference for the end on the other board, put beside the end on this one, and `via: reference` asks for one on a single board. Each says over its name where its shape is. The reference stands for a public shape, so a shape that isn't public can't be reached, and a script never makes one public to get there (that's the user's call): the edge is refused, and the user is asked. The arrow's row says `via: "reference"`, and the pill has a row of its own. Reading it back is what this page is about. [language.md](language.md#through-a-reference) is how to draw it.

A reference has no title, and a script names a shape by its title (or, for a shape that has none, by its id). A direct one is named by the shape it stands for, never by its id: not as an edge's end, in the script that draws it or in another, and its id is refused (`invalid_value`). A dynamic one stands for no one shape, so its id is its name, wherever a statement names a shape ([language.md](language.md#arrows-into-it)). A later run finds the one an edge went through by what it stands for (writing the edge again is `unchanged`), and `delete edge` takes the arrow and the pill, as `delete` of the shape at the arrow's other end does, once no arrow is left on the pill. Nothing else a script writes names a shape for a reference: what it names and the words typed into it are the person's, so a script can't write them:

```draw-error
// reason: unknown_attribute
reference target: "Auth"
```

```draw-error
// reason: unknown_attribute
reference words: "everything about auth"
```

A shape that isn't public can't be stood for, so `via:` for one is refused:

```draw-error
// reason: invalid_value
edge "Checkout" -> "Drafts" via: reference
```

What a script writes on a statement of a reference's own is `query:`, a query in the language of [query.md](query.md), and `all:`, and the app refuses a query it can't read, or one that reads what the person is doing. Its row gives the new reference's `id`, which a later script draws arrows into, restates and deletes it by. See [language.md](language.md#references).

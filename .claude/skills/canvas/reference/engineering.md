<!-- ids: 7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11 -->
<!-- setup: take-out-endpoint -->
# Tables, enums, databases and APIs

The engineering kit draws a database's tables and a REST API the way an engineer sketches them: a **table** is a card of columns, a line each (`id uuid pk`); an **enum** is a card of values, a line each; a **database** is a region that holds them, as a frame does; an **api** is a card of endpoints, a line each (`POST /orders/{id}/refunds (NewRefund) → 201 Refund`), under its server. A person turns the kit on in a file (File ▸ Kits ▸ Engineering) to get its tools and commands; `canvas draw` and `canvas query` reach its kinds in every file, on or off. [kinds.md](kinds.md) has each kind's size and attributes; this page is how their rows are written.

## A table and its columns

`columns:` takes the columns as lines in quotes, one a column, `\n` between them, each `name type [null] [unique] [default …] [pk] [→ table.column]`: its name, its type as SQL writes it, then any of `null` (it may be null; a `?` after the type says it too), `unique`, `default` and the word after it, `pk` (part of the primary key), and a key, `→` (or `->`) and the column it references (below), in any order. Words a line can't place stay in the column as written, shown plain. A new table drawn with no `columns:` has one, `id uuid pk`.

```draw
table "customers" columns: "id uuid pk\nemail text unique\nname text\ncreated_at timestamptz default now()"
table "orders" right of "customers" columns: "id uuid pk\ncustomer_id uuid\nplaced_at timestamptz?"
```

A statement joins its lines onto the table's columns by name: a column it names takes what its line says, one it leaves out stays, and a new name goes after the column the statement writes before it (last, when it writes none before it). So a script names only what it changes, and run again it changes nothing.

```draw
table "orders" columns: "placed_at timestamptz null\ntotal_cents int"
```

JSON items name a column's members (`name`, `type`, `nullable`, `unique`, `default`, `primaryKey`, `onDelete`, `onUpdate`), joined by name the same way, and only the members an item gives change. A `type` is its words, `"type": "char(3)"`, as a line's is:

```draw
table "orders" columns: [{"name": "currency", "type": "char(3)", "nullable": true}]
```

The table is as wide as it's drawn (`size: 320x`) and as tall as its rows; a height in `size:` is its rows' anyway.

A table, enum or API that gains rows makes room below it: in the same step, what's under it in its database (or on the board) that its new bottom comes within 32 of moves down as far as it grew (a shape the script put there too), keeping its gap, and pushes what's under that; a database the push takes past its bottom grows. The report lists what moved, `"moved": [{"kind", "title", "id", "at", "down"}]`, only when something did. A locked shape stops it, and nothing moves up when rows go: lay out what it can't by hand. A document applied with `canvas apply` makes no room: its plan places every shape.

A person can paste SQL into the app (⌘V of `CREATE TABLE …` with the kit on), and it lands as these statements would, joined by name the same way; that's the person's way in, and `canvas draw` stays yours.

## Keys

A key is an arrow from a column to the column it references, bound to both rows, on the `foreign-key` channel. Draw it as an edge between rows, each named with a dot outside the quotes: the column that holds the key first.

```draw
edge "orders".customer_id -> "customers".id
```

A column's line can say its key itself: `→ customers.id` draws the same edge, on the statement's line, and the column keeps no words of it. `→ customers` alone is its primary key, for a table already drawn (one the same script draws needs the column named). Writing the edge as well is the same key, drawn once; a line without `→` leaves the column's key alone; a line whose `→` goes elsewhere than the column's key re-aims it (the old key goes, the new one is drawn: a column has the one key its line says; an `edge` you write yourself stays).

```draw
table "orders" columns: "billing_id uuid → customers.id\nshipping_id uuid -> customers.id"
```

The channel is the one the columns take, so `channel: foreign-key` can be written or left out; only a table's columns take it (an enum, a database, a note or a subboard takes none). The column shows a link in its gutter, and the arrow leaves its row's side facing the other table. Drawn again, the same rows are the same key (`unchanged`); two other rows of the same tables are another key. A row the table doesn't have is `unknown_row`, with the ones like it:

```draw-error
// reason: unknown_row
edge "orders".custmer_id -> "customers".id
```

**A key to a table on another board** goes through a reference to that table, as any edge to a shape on another board does: the run puts the reference beside the column's table (or uses the one the board has for that table there), and the arrow names the column on the reference, so the key is read as the column's (`:edge-to`, the column's line `→ customers.id`, deleting customers.id deleting it). Name the far row as a near one is named, `edge "statements".customer_id -> "customers".id`, and a line's `→ customers.id` the same way. Drawn again it is `unchanged`, and `delete edge` with its rows finds it through the reference. Moving a table to another board keeps its keys the same way.

`delete edge` takes keys between two tables: named whole, every one between them; with a row at an end, only those bound to it there, so of two keys from orders to customers one goes and the other stays. None there is `nothing_to_delete`.

```draw
delete edge "orders".shipping_id -> "customers".id
```

Deleting a table deletes its keys, either way; deleting a column deletes the keys at it. `delete "orders".placed_at` takes the column out:

```draw
delete "orders".placed_at
```

## An enum

`values:` takes the values as lines, one a value, joined onto what the enum holds by text, a new one after the value written before it. A column whose type is an enum's title shows it in a pill.

```draw
enum-type "order_status" below "orders" values: "pending\npaid\nrefunded\nvoid"
table "orders" columns: "status order_status"
```

A value is taken out as a column is, `delete` and the enum's title, a dot and the value:

```draw
delete "order_status".void
```

## Tables in a database

A database holds shapes as a frame does: draw it first, with room (`size:`), then put tables in it with `in`, in a script after the one that draws it.

```draw
database "shop" below "order_status" (gap: wide) size: 900x400
```

```draw
table "products" in "shop" columns: "id uuid pk\nsku text unique\ntitle text\nprice_cents int"
table "line_items" in "shop" right of "products" columns: "id uuid pk\nproduct_id uuid\nqty int"
```

## An API

`server:` is an API's first line: where it's served and how a client signs in, `host[/path] [bearer | basic | apikey NAME | oauth2]`. `endpoints:` takes its rows as lines, one a row: an endpoint `METHOD /path/{param} [(Body)] [→ [status] [Response]]`, each bracketed part left out as you like, or a path alone, a header that groups the endpoints under it (the app draws them indented, their paths written after the header's, so renaming `/orders` is one edit there). Write every endpoint's path whole: each goes under the longest header it starts with, else at the top. A statement joins its endpoints onto the API's by method and whole path, so it names only what it changes, the rows it leaves out stay, and run again it changes nothing; what only an endpoint's card says (its name, summary, more responses) stays when a line restates it.

```draw
sticky-note "NewRefund" below "shop" (gap: wide) schema: "{\"type\": \"object\", \"properties\": {\"amount_cents\": {\"type\": \"number\"}}}"
sticky-note "Refund" right of "NewRefund" schema: "{\"type\": \"object\", \"properties\": {\"id\": {\"type\": \"string\"}}}"
api "orders API" below "NewRefund" (gap: wide) server: "api.shop.dev/v1 bearer" endpoints: "/orders\nGET /orders/{id} → Refund\nPOST /orders/{id}/refunds (NewRefund) → 201 Refund\nGET /health"
```

A body or a response names a type, a note with a `schema:`, by its title: it's drawn as that type's pill, never an arrow, and a name no type has stays words, in a dashed pill, until one does. JSON items take the card's fields too, a header as `{"header": "/orders"}`, and a new row's `id` if you give it one (else it gets its own; a query's `endpoints` say each row's):

```draw
api "orders API" endpoints: [{"header": "/customers"}, {"method": "GET", "path": "/customers/{id}/orders", "name": "listCustomerOrders", "id": "E1C4A7B2-3D5F-4A8E-9B6C-0F2D4E6A8C1B", "responses": [{"status": "200", "type": "Refund"}]}]
```

## What an API does

An endpoint **writes** or **reads** a table, and **calls** another endpoint: each is an arrow from the endpoint's row, on its channel (`writes`, `reads`, `calls`), drawn with the channel's word in a pill on its line (writes pink, reads green, calls blue). Name the endpoint as a row, its whole name after the API's title and a dot; a table as itself, since writes and reads go to it as a whole; another endpoint as a row too. Write `channel:`: an endpoint to a table with none written is `writes`.

```draw
table "refunds" right of "orders API" (gap: wide) columns: "id uuid pk\namount_cents int"
edge "orders API"."POST /orders/{id}/refunds" -> "refunds" channel: writes
edge "orders API"."GET /orders/{id}" -> "refunds" channel: reads
edge "orders API"."GET /customers/{id}/orders" -> "orders" channel: reads
api "Stripe API" below "orders API" (gap: wide) endpoints: "POST /v1/refunds"
edge "orders API"."POST /orders/{id}/refunds" -> "Stripe API"."POST /v1/refunds" channel: calls
```

Only endpoints start writes and reads, and only tables take them (an enum, a database, a note or a subboard takes none); anything with arrows of its own (a note, a frame, a subboard) may call an endpoint, and an endpoint calls one; a call ends at an endpoint's row, never at a subboard, note or frame as a whole. A path prefix's header is no endpoint, takes none of them, and an edge naming one is refused (`cannot_connect`). An endpoint on another board is reached through a reference for that endpoint itself, beside the API, as a key's table is: drawn on its own, below the API or level with the row, where its line crosses nothing. Drawn again, the same rows on the same channel are `unchanged`; the same rows on another channel are another arrow.

## Retiring and changing

An endpoint is retired with `"deprecated": true` in its item (the app draws its chip hollow and its line faint; arrows into it stay), and an API with `deprecated: true`, an old version (drawn faint). Joined by method and whole path as ever, the item names only what it changes:

```draw
api "orders API" endpoints: [{"method": "GET", "path": "/orders/{id}", "deprecated": true}]
```

An endpoint is taken out of its API with `delete`, the API's title, a dot and the endpoint's whole name; the arrows at it go with it:

```draw
delete "orders API"."GET /health"
```

What a person does in the app reads back the same way: New Version marks an API `deprecated` and puts a copy beside it titled with its version bumped (`orders API v2`), its server's `/v1` now `/v2`, the same rows, and the arrows its rows start; Group by Prefix puts the endpoints under a header for each first path segment two or more share; and one endpoint taken out of an API is an `endpoint` of its own, its card drawn open, its arrows still bound to its row, which is named as an API's row is (`"createRefund"."POST /orders/{id}/refunds"`). It is read as the row it was: `:route` finds it (the `endpoint` itself, not an API), an arrow's `row` at it names it, and `--ask` is told it as an API of one route. No statement draws an `endpoint`, and none puts one back: writing its row into an API's `endpoints:` makes a second endpoint of that route, the arrows staying on the one of its own. Only a person puts it back, by dragging its chip onto the API, or cutting it and pasting it there.

## A note that mentions a row

A note's text mentions a row as a script names one, after its shape's title and a dot: `@["orders".customer_id]`, `@["orders API"."POST /orders/{id}/refunds"]` (in a script's string, each quote inside it `\"`). The note keeps the row: its pill shows `orders.customer_id`, live, and it follows the row through a rename of either. A query reads it back as `@orders.customer_id`; restating the text, write each row mention this way again, or it becomes words. A row the shape hasn't is `unknown_row`, with the ones it's like.

```draw
sticky-note "Refund flow" below "Stripe API" (gap: wide) text: "@[\"orders API\".\"POST /orders/{id}/refunds\"] writes @[refunds] for @[\"orders\".customer_id]"
```

It is a mention of each row's shape:

```query
/* matches: "Refund flow" */
sticky-note:edge-to("orders", mention)
```

## Asking

The tables in a database, and how many tables there are:

```query
/* matches: "products", "line_items" */
"shop" table
```

```query
/* count: 5 */
table
```

Its keys are arrows on `foreign-key`: the tables a table's keys go to, and every key:

```query
/* matches: "orders" */
table:edge-to("customers", foreign-key)
```

```query
/* count: 2 */
arrow[channel=foreign-key]
```

An API is found by its kind and its title:

```query
/* matches: "orders API", "Stripe API" */
api
```

What an API does is its arrows, by channel: the tables its endpoints write, and every call:

```query
/* matches: "refunds" */
table:edge-from("orders API", writes)
```

```query
/* count: 1 */
arrow[channel=calls]
```

Which API writes refunds is `api:edge-to("refunds", writes)`. Which endpoint is a question about the arrows: an arrow's own row in an answer names the row at each end, `"from": {"id": …, "title": "orders API", "row": "POST /orders/{id}/refunds"}`, as a key's names the column (`"row": "customer_id"`), so the arrows into a table say the endpoints that write it:

```query
/* matches: (arrow) */
arrow[channel=writes]:ends-at("refunds")
```

```query
/* matches: "orders API" */
api:edge-to("refunds", writes)
```

A question about one row, rather than its shape, names the row as an edge word's anchor: `#<shape>::part(<row>)`, the shape's id as a query's rows give it and the row's as its `endpoints` (or a table's `columns`) do. The tables listCustomerOrders reads, of all the orders API reads:

```query
/* matches: "orders" */
table:edge-from(#7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11::part(E1C4A7B2-3D5F-4A8E-9B6C-0F2D4E6A8C1B), reads)
```

Only an edge word takes a row (`:edge-to`, `:edge-from`, `:starts-at`, `:ends-at`, `:start-of`, `:end-of`); anywhere else it's refused:

```query-error
/* reason: unsupported */
#7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11::part(E1C4A7B2-3D5F-4A8E-9B6C-0F2D4E6A8C1B)
```

`:route("…")` is the APIs with an endpoint of that method and whole path, and the endpoints taken out of one that are it: a parameter in braces stands for any parameter, and a path with no method for any method. Each row says the endpoints it matched, `"routes": ["POST /orders/{id}/refunds"]`:

```query
/* matches: "orders API" */
:route("POST /orders/{order_id}/refunds")
```

```query
/* matches: "Stripe API" */
:route("/v1/refunds")
```

An endpoint taken out of its API is found the same way, by its method and whole path, as the endpoint itself (here one named `stripeHook`, taken out in the app: no statement draws one):

```query
/* matches: "stripeHook" */
:route("POST /hooks/stripe")
```

A table's columns are its `columns` attribute, a list, each its id and what its line said; a test inside it holds when any column's does. A column reads as its name, and a type as its words, so `[columns.type="order_status"]` is the tables with a column of that enum; an enum's values read as their text, and an endpoint's body and response types as their words (`api[endpoints.body="NewRefund"]`):

```query
/* matches: "customers" */
table[columns.name="email"]
```

```query
/* matches: "customers", "products" */
table[columns.unique=true]
```

```query
/* matches: "orders" */
table[columns.type="order_status"]
```

```query
/* matches: "order_status" */
enum-type[values="paid"]
```

```draw-error
// reason: invalid_value
table "orders" columns: 42
```

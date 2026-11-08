# Tables, enums and databases

The engineering kit draws a database's tables the way an engineer sketches them: a **table** is a card of columns, a line each (`id uuid pk`); an **enum** is a card of values, a line each; a **database** is a region that holds them, as a frame does. A person turns the kit on in a file (File ▸ Kits ▸ Engineering) to get its tools and commands; `canvas draw` and `canvas query` reach its kinds in every file, on or off. [kinds.md](kinds.md) has each kind's size and attributes; this page is how their rows are written.

## A table and its columns

`columns:` takes the columns as lines in quotes, one a column, `\n` between them, each `name type [null] [unique] [default …] [pk] [→ table.column]`: its name, its type as SQL writes it, then any of `null` (it may be null; a `?` after the type says it too), `unique`, `default` and the word after it, `pk` (part of the primary key), and a key, `→` (or `->`) and the column it references (below), in any order. Words a line can't place stay in the column as written, shown plain. A new table drawn with no `columns:` has one, `id uuid pk`.

```draw
table "customers" columns: "id uuid pk\nemail text unique\nname text\ncreated_at timestamptz default now()"
table "orders" right of "customers" columns: "id uuid pk\ncustomer_id uuid\nplaced_at timestamptz?"
```

A statement joins its lines onto the table's columns by name: a column it names takes what its line says, one it leaves out stays, and a new name is added at the end. So a script names only what it changes, and run again it changes nothing.

```draw
table "orders" columns: "placed_at timestamptz null\ntotal_cents int"
```

The table is as wide as it's drawn (`size: 320x`) and as tall as its rows; a height in `size:` is its rows' anyway.

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

`delete edge` takes keys between two tables: named whole, every one between them; with a row at an end, only those bound to it there, so of two keys from orders to customers one goes and the other stays. None there is `nothing_to_delete`.

```draw
delete edge "orders".shipping_id -> "customers".id
```

Deleting a table deletes its keys, either way; deleting a column deletes the keys at it. `delete "orders".placed_at` takes the column out:

```draw
delete "orders".placed_at
```

## An enum

`values:` takes the values as lines, one a value, joined onto what the enum holds by text. A column whose type is an enum's title shows it in a pill.

```draw
enum-type "order_status" below "orders" values: "pending\npaid\nrefunded"
table "orders" columns: "status order_status"
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

## Asking

The tables in a database, and how many tables there are:

```query
/* matches: "products", "line_items" */
"shop" table
```

```query
/* count: 4 */
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

A table's columns, each its id and what its line said, are its `columns` attribute, as a row of `canvas query` gives them; a test inside the list (`[columns.name=…]`) isn't built yet.

```draw-error
// reason: invalid_value
table "orders" columns: 42
```

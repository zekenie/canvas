# Tables, enums and databases

The engineering kit draws a database's tables the way an engineer sketches them: a **table** is a card of columns, a line each (`id uuid pk`); an **enum** is a card of values, a line each; a **database** is a region that holds them, as a frame does. A person turns the kit on in a file (File ▸ Kits ▸ Engineering) to get its tools and commands; `canvas draw` and `canvas query` reach its kinds in every file, on or off. [kinds.md](kinds.md) has each kind's size and attributes; this page is how their rows are written.

## A table and its columns

`columns:` takes the columns as lines in quotes, one a column, `\n` between them, each `name type [null] [unique] [default …] [pk]`: its name, its type as SQL writes it, then any of `null` (it may be null; a `?` after the type says it too), `unique`, `default` and the word after it, and `pk` (part of the primary key), in any order. Words a line can't place stay in the column as written (a key's `→ customers.id` among them, until keys are drawn), shown plain. A new table drawn with no `columns:` has one, `id uuid pk`.

```draw
table "customers" columns: "id uuid pk\nemail text unique\nname text\ncreated_at timestamptz default now()"
table "orders" right of "customers" columns: "id uuid pk\ncustomer_id uuid\nplaced_at timestamptz?"
```

A statement joins its lines onto the table's columns by name: a column it names takes what its line says, one it leaves out stays, and a new name is added at the end. So a script names only what it changes, and run again it changes nothing.

```draw
table "orders" columns: "placed_at timestamptz null\ntotal_cents int"
```

The table is as wide as it's drawn (`size: 320x`) and as tall as its rows; a height in `size:` is its rows' anyway.

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

A table's columns, each its id and what its line said, are its `columns` attribute, as a row of `canvas query` gives them; a test inside the list (`[columns.name=…]`) isn't built yet.

```draw-error
// reason: invalid_value
table "orders" columns: 42
```

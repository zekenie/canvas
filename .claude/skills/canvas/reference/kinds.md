# The kinds

<!-- Generated from `canvas kinds` by the kind-pages test (Tests/CompositionTests/KindPagesTests.swift).
Don't edit it: `mise run skill:kinds` writes it again. -->

Generated from `canvas kinds`, the app's own answer, so it is what the installed plugins say today; `mise run skill:kinds` writes it again. [language.md](language.md)
says what the words in it do; `canvas kinds <kind> --schema` adds a kind's JSON Schema.

## `database`

Called Database, placed by the Database tool

- **size**: `640x400`
- **smallest**: `96x64`; a `size:` under it is refused
- **holds**: `shapes`; `in "X"` names it
- **named**: `named`

| attribute | takes |
|---|---|
| `locked` | true\|false |
| `private` | true\|false |

**edges**: none

**via**: `reference` (needs `public`) can stand for it

## `enum-type`

Called Enum, placed by the Enum tool

- **size**: `220x44`
- **named**: `named`

| attribute | takes |
|---|---|
| `locked` | true\|false |
| `private` | true\|false |
| `values` | lines (a value each) or JSON [{id, text}] |

**edges**: none

**via**: `reference` (needs `public`) can stand for it

## `frame`

Called Frame, placed by the Frame tool

- **size**: `640x400`
- **smallest**: `96x64`; a `size:` under it is refused
- **holds**: `shapes`; `in "X"` names it
- **named**: `named`

| attribute | takes |
|---|---|
| `color` | text (a color's name or #RRGGBB) |
| `fieldValues` | JSON {…} |
| `is` | JSON [text] (<Title> of a type or shape) |
| `locked` | true\|false |
| `private` | true\|false |

| edges leave by | channels |
|---|---|
| right | `frame-link` |
| bottom | `frame-link` |
| left | `frame-link` |

**via**: `reference` (needs `public`) can stand for it

## `reference`

Called Reference, placed by the Reference tool

- **size**: `120x40`
- **named**: `none`

| attribute | takes |
|---|---|
| `all` | true\|false |
| `locked` | true\|false |
| `query` | text (≤ 8192) |

**edges**: none

## `sticky-note`

Called Sticky note, placed by the Note tool

- **size**: `260x200`
- **named**: `named`

| attribute | takes |
|---|---|
| `autofill` | true\|false |
| `color` | text (a color's name or #RRGGBB) |
| `fieldValues` | JSON {…} |
| `is` | JSON [text] (<Title> of a type or shape) |
| `locked` | true\|false |
| `private` | true\|false |
| `relationship` | true\|false |
| `schema` | text |
| `text` | text (@[Title] mentions) |

| edges leave by | channels |
|---|---|
| top | `note-link` |
| right | `note-link` |
| bottom | `note-link` |
| left | `note-link` |

**via**: `reference` (needs `public`) can stand for it

## `subboard`

Called Subboard, placed by the Subboard tool

- **size**: `240x160`
- **holds**: `board`; `in "X"` names it
- **named**: `named`

| attribute | takes |
|---|---|
| `autofill` | true\|false |
| `color` | text (a color's name or #RRGGBB) |
| `description` | text (@[Title] mentions) |
| `fieldValues` | JSON {…} |
| `is` | JSON [text] (<Title> of a type or shape) |
| `locked` | true\|false |
| `private` | true\|false |

| edges leave by | channels |
|---|---|
| top | `subboard-link`, `note-link`, `frame-link` |
| right | `subboard-link`, `note-link`, `frame-link` |
| bottom | `subboard-link`, `note-link`, `frame-link` |
| left | `subboard-link`, `note-link`, `frame-link` |

**via**: `reference` (needs `public`) can stand for it

## `table`

Called Table, placed by the Table tool

- **size**: `260x44`
- **named**: `named`

| attribute | takes |
|---|---|
| `columns` | lines (name type [null] [unique] [default …] [pk] [→ table.column]) or JSON [{default, id, name, nullable, onDelete, onUpdate, primaryKey, type, unique, unread}] |
| `locked` | true\|false |
| `private` | true\|false |

**edges**: at its rows only (`"T".row`), on `foreign-key`

**via**: `reference` (needs `public`) can stand for it

## `arrow`

Called Arrow

Not drawn on its own: it joins two shapes: write edge "A" -> "B".

- **named**: `none`

| attribute | takes |
|---|---|
| `autofill` | true\|false |
| `bend` | number |
| `channel` | text |
| `color` | text (a color's name or #RRGGBB) |
| `endArrowhead` | true\|false |
| `endRule` | JSON {needed, onlyOne} |
| `fieldValues` | JSON {…} |
| `is` | JSON [text] (<Title> of a type or shape) |
| `labelPosition` | number 0…1 |
| `locked` | true\|false |
| `startArrowhead` | true\|false |
| `text` | text (@[Title] mentions) |

**edges**: none

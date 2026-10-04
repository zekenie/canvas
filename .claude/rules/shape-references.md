---
paths:
  - "Sources/Canvas/Model/ShapeNaming.swift"
  - "Tests/CanvasTests/NamingTests.swift"
  - "Tests/CanvasTesting/Naming.swift"
---

# References between shapes

Values that bind other shapes (`ShapeReferencing`) or name them (`ShapeNaming`), and what deleting, copying, cutting and drawing do to each.

Related: [clipboard](clipboard.md), [mentions](mentions.md), [arrows](arrows.md), [topology](topology.md), [command line](command-line.md), [properties and schemas](properties-and-schemas.md) ([every topic](../../CLAUDE.md#map)).

In the guide, `docs/plugin-system.md`: [Values that name shapes](../../docs/plugin-system.md#values-that-name-shapes).

## Architecture

- References between shapes have two forms behind one entry, `record.remappingReferences(_:in:)` (`docs/plugin-system.md`, "Values that name shapes"). Bindings (`ShapeReferencing`, a kind's definition: an arrow's ends) must be on the board: a delete lets them go, a copy renames those copied along and lets the rest go, and `canvas draw` refuses one that isn't there (`record.boundShapes(in:)`). Names (`ShapeNaming`, a value: a mention) may be of a shape on any board of the file (ids are unique across it: `editor.file.record(id)`), and may outlive their shapes: a copy renames those of shapes copied along and keeps the rest (nil keeps a name; across a copied tree of boards, `remappingReferences(_:naming:in:)` passes names through the whole tree's map and bindings through their board's, as Clipboard's paste does), a cut and its paste move the shapes under their ids, so a name of one from outside what moved names it again (a binding to one was let go at the cut), a delete never looks for them (it asks only `referencingKinds`, so deleting a mentioned shape writes nothing), and `draw` keeps a name of a shape that's in no board of the file (or one the script deletes), or on a board the app can't show, and warns ("<shape>: cite names shapes that aren't in the file: …; they show as missing", "… names shapes on boards this app can't show: …"), and refuses a binding to one on another board as to one in none (`invalid_value`: "… is bound to a shape on another board of the file"). The core finds names through property lists: a kind's props by their list (a property whose member's type is `ShapeNaming`, found once by a runtime check, so a plain property carries nothing), a struct in them or in an added value adopts `ShapeNaming` in an extension with nothing to write (`extension MemoNote: ShapeNaming {}`), and the registry refuses one that holds names without adopting it; optionals, arrays, sets and dictionaries keyed by strings (an object with `additionalProperties` in a schema) of names are names, and a leaf coded by hand implements `forEachNamedShape` and `renamingShapes` (pure). `registry.namingKinds` are the kinds whose props or opted-in added values can hold names, and `record.forEachNamingValue(in:)` walks a shape's, with the property each is in (none kept aside, which a copy doesn't rename either); `value.forEachNamingLeaf` goes into each for the leaves it holds, however deep (how Mentions finds its text in a struct in a list). A kind without names costs a set lookup where names are walked, and nothing on a delete. Core tests use CanvasTesting's `NamingPlugin`: `Citation` (a leaf that counts its visits), `Memo` (names in a struct in a list, an optional, a dictionary, and `CitationsProperty`) and `CitingTag` (binds and names).

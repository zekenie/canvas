import Canvas
import CanvasTesting
import Queries
import QueryLanguage
import QueryLexicon
import Selection
import TestKit

// `:selected`, the person's selection as the query took up the file, and what `--ask` says is
// selected, in the selection's order.

@MainActor let selectionQueriesTests = Suite("The selection in queries", [
    test(":selected is what the person has selected, in file order") {
        let h = try selectionHarness()
        h.editor.selectedShapeIDs = [id(3), id(1)]
        expectEqual(try matched(":selected", on: h), [1, 3].map(id))
        expectEqual(try matched("tile:selected", on: h), [1, 3].map(id))
        expectEqual(try matched("box:selected", on: h), [])
        expectEqual(try matched(":not(:selected)", on: h), [2, 4].map(id))
        h.editor.selectedShapeIDs = []
        expectEqual(try matched(":selected", on: h), [])
    },
    test(":selected starts from the selected shapes: it walks nothing else") {
        let h = try selectionHarness()
        h.editor.selectedShapeIDs = [id(4)]
        let queries = try require(h.editor.queries)
        let walks = queries.universeWalks
        expectEqual(try matched(":selected", on: h), [4].map(id))
        expectEqual(queries.universeWalks, walks)
    },
    test("the selection is taken as the query takes up the file: a change while it runs changes nothing it answers") {
        let h = try selectionHarness()
        h.editor.selectedShapeIDs = [id(3), id(1)]
        expectEqual(try matched("box:shifting, :selected", on: h), [1, 3].map(id))
        expectEqual(h.editor.selectedShapeIDs, [id(2)], "the selection changed while the query ran")
        expectEqual(try matched(":selected", on: h), [2].map(id), "the next query takes it as it is now")
    },
    test("--ask is told what's selected, in the selection's order, up to its limit") {
        let h = try selectionHarness()
        h.editor.selectedShapeIDs = [id(3), id(1), id(2)]
        let place = try whereThePersonIs(on: h)
        expectEqual(place.selected, [QuerySelected(id: id(3), kind: Tile.kind, title: "Booth"), QuerySelected(id: id(1), kind: Tile.kind, title: "Kiosk"),
                                     QuerySelected(id: id(2), kind: Box.kind)])
        expectEqual(place.selectedCount, 3)
        let few = try whereThePersonIs(on: h, limit: 2)
        expectEqual(few.selected.map(\.id), [3, 1].map(id))
        expectEqual(few.selectedCount, 3)
        h.editor.selectedShapeIDs = []
        expectEqual(try whereThePersonIs(on: h).selected, [])
    },
    test("the vocabulary lists :selected, from the bridge; without it, nothing says what's selected") {
        let h = try selectionHarness()
        let words = try require(h.editor.queries).vocabulary.words.filter { $0.from == SelectionQueriesPlugin().id }
        expectEqual(words.map(\.form), [":selected"])
        expectEqual(words.map(\.summary), ["the person has it selected"])
        let bare = try selectionHarness(bridge: false)
        bare.editor.selectedShapeIDs = [id(1)]
        expectEqual(try refusal(":selected", on: bare)?.reason, .unknownPseudoClass)
        let place = try whereThePersonIs(on: bare)
        expectEqual(place.selected, [])
        expectEqual(place.selectedCount, 0)
    },
])

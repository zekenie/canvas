import Boards
import Canvas
import CanvasTesting
import Queries
import QueryLexicon
import TestKit

// A query's rows naming the boards a shape is inside as the path over the canvas names them
// (`editor.name(of:root:)`): the owner's title, else the placeholder its kind opens boards with,
// else its kind's label; and the containers it's in on them (corrals), which the path doesn't name,
// by their titles, else their kind's label.

@MainActor let boardQueriesTests = Suite("Boards name boards for queries", [
    test("a row names the boards it's inside as the path does: a titled owner's, an untitled one's by its placeholder, a kind without one by its label") {
        let h = try storeHarness()
        let inside = try inside("box", on: h)
        expectEqual(inside[id(2)], [])
        expectEqual(inside[id(12)], ["Kitchen"])
        expectEqual(inside[id(22)], ["Kitchen", "Untitled Drawer"])
        expectEqual(inside[id(31)], ["Kitchen", "Untitled Drawer", "Crate"])
        for box in [2, 12, 22, 31].map(id) {
            expectEqual(inside[box], pathNames(of: box, in: h), "\(box)")
        }
    },
    test("an owner named, or its name cleared, names its board so in the next query") {
        let h = try storeHarness()
        h.editor.rename(id(11), "Pantry", on: BoardID(owner: id(1)))
        h.editor.rename(id(21), "Bin", on: BoardID(owner: id(11)))
        expectEqual(try inside("box", on: h)[id(31)], ["Kitchen", "Pantry", "Bin"])
        expectEqual(try inside("box", on: h)[id(31)], pathNames(of: id(31), in: h))
        h.editor.rename(id(11), nil, on: BoardID(owner: id(1)))
        h.editor.rename(id(21), "  ", on: BoardID(owner: id(11)))
        expectEqual(try inside("box", on: h)[id(31)], ["Kitchen", "Untitled Drawer", "Crate"], "a blank title is none")
        expectEqual(try inside("box", on: h)[id(31)], pathNames(of: id(31), in: h))
    },
    test("the vocabulary says what an untitled owner's board is called: a placeholder only for kinds that open their boards") {
        let vocabulary = try require(try storeHarness().editor.queries).vocabulary
        expectEqual(vocabulary.kind(Drawer.kind)?.boardName, "Untitled Drawer")
        expectEqual(vocabulary.kind(Crate.kind)?.boardName, "Crate", "no placeholder: its label")
        expectEqual(vocabulary.kind(Box.kind)?.boardName, nil, "it holds no board")
        expectEqual(vocabulary.kind(Drawer.kind)?.holdsBoard, true)
        expectEqual(vocabulary.kind(Crate.kind)?.holdsBoard, true)
    },
    test("without BoardQueriesPlugin, an untitled owner's board is called by its kind's label, not as the path calls it") {
        let h = try storeHarness(withPlugin: false)
        let drawer = h.editor.registry.label(of: Drawer.kind).name
        expectEqual(try inside("box", on: h)[id(22)], ["Kitchen", drawer])
        expectEqual(pathNames(of: id(22), in: h), ["Kitchen", "Untitled Drawer"])
        expectEqual(h.editor.queries?.vocabulary.kind(Drawer.kind)?.boardName, drawer)
    },
    test("a row names the containers it's in between the boards, which the path doesn't: a titled one's title, an untitled one by its kind's label") {
        let h = try cellarHarness()
        let inside = try inside("*", on: h)
        expectEqual(inside[id(40)], [])
        expectEqual(inside[id(42)], [])
        expectEqual(inside[id(41)], ["corral"], "a corral owns no board, so it has no placeholder: its label")
        expectEqual(inside[id(50)], ["corral", "Cellar"])
        expectEqual(inside[id(51)], ["corral", "Cellar", "Rack"])
        expectEqual(inside[id(52)], ["corral", "Cellar", "Rack"])
        expectEqual(inside[id(61)], ["corral", "Cellar", "Rack", "Untitled Drawer"])
        expectEqual(pathNames(of: id(61), in: h), ["Cellar", "Untitled Drawer"], "the path names boards alone")
        let vocabulary = try require(h.editor.queries).vocabulary
        expectEqual(vocabulary.kind(Corral.kind)?.holdsShapes, true)
        expectEqual(vocabulary.kind(Corral.kind)?.holdsBoard, false)
        expectEqual(vocabulary.kind(Corral.kind)?.boardName, nil, "a placeholder is for kinds that open their boards")
        expectEqual(vocabulary.kind(Drawer.kind)?.holdsShapes, true)
    },
    test("--ask's board and titles name boards as the path does") {
        let h = try storeHarness()
        h.editor.rename(id(21), "Bin", on: BoardID(owner: id(11)))
        expect(h.enter(id(1)))
        expect(h.enter(id(11)))
        let queries = try require(h.editor.queries)
        let place = try awaitResult { try await queries.whereThePersonIs(selectedLimit: 20) }
        expectEqual(place.board, BoardID(owner: id(11)))
        expectEqual(place.path, ["Kitchen", "Untitled Drawer"])
        expectEqual(place.path, h.editor.boardPath.dropFirst().map { h.editor.name(of: $0, root: "Top") })
        let titles = try awaitResult { try await queries.titles(for: "the bin", limit: 1) }
        expectEqual(titles.first?.title, "Bin")
        expectEqual(titles.first?.inside, ["Kitchen", "Untitled Drawer"])
    },
])

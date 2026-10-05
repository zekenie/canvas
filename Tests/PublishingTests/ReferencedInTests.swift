@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import Publishing
import Selection
import TestKit
import Titles

// Referenced In: a tab of a shape's panel, shown while something stands for it, a row for each
// stand-in in file order, whatever kind it is; a kind that stands in describes its own row through
// `StandInRows` (a fixture here), and without that the row is the kind's symbol, the names of what's
// connected through it, or the board it's on.

private let tab = DetailTabID.of(ReferencedInTab.self)

/// Pockets (boards, as a subboard's) with titles, from another plugin, and the keys.
@MainActor private func boards() -> Contributor {
    Contributor(id: "boards") { r in r.title(Pocket.self, pill: false, contents: false) }
}

@MainActor private func titled(_ h: EditorHarness, _ title: String, at frame: CGRect) -> ShapeID {
    let id = h.add(Plaque(frame))
    h.editor.transact { $0.update(id) { $0[TitleProperty.self] = title } }
    return id
}

@MainActor private func tabs(_ h: EditorHarness, _ id: ShapeID) throws -> [DetailTabID] {
    let panel = try require(h.editor.detailPanel)
    return panel.layout(for: try require(h.editor.document[id])).tabs
}

@MainActor let referencedInTests = Suite("Referenced In", [
    test("the tab is there while something stands for the shape, after the shape's own, and goes with the last stand-in") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        h.publish(plaque)
        expect(!(try tabs(h, plaque)).contains(tab), "nothing stands for it")
        let holder = h.hold([plaque])
        expectEqual(try tabs(h, plaque).map(\.title), ["Plaque", "Referenced In"], "after the plaque's own, as Mentioned In is last")
        let panel = try require(h.editor.detailPanel)
        let layout = panel.layout(for: try require(h.editor.document[plaque]))
        expectEqual(layout.sections(in: tab).map(\.section), ["referenced-in"])
        h.editor.transact { $0.delete([holder]) }
        expect(!(try tabs(h, plaque)).contains(tab), "gone with it")
        h.editor.undo()
        expect(try tabs(h, plaque).contains(tab), "and back")
    },
    test("an always-public shape has the tab while stood for; the stand-in itself and a draft never do") {
        let h = try publishingHarness()
        let seal = h.add(Seal(plaqueFrame))
        let holder = h.hold([seal])
        expect(try tabs(h, seal).contains(tab))
        expect(!(try tabs(h, holder)).contains(tab))
        let draft = h.add(Draft(CGRect(x: 300, y: 100, width: 100, height: 100)))
        h.hold([draft])
        expect(!(try tabs(h, draft)).contains(tab), "a draft can't be public, so nothing stands for it")
    },
    test("a row for each stand-in, in file order, led by the kind's own symbol and words") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        h.publish(plaque)
        let relay = h.add(Relay(CGRect(x: 600, y: 100, width: 60, height: 20), stands: [Citation(plaque)]))
        let holder = h.hold([plaque])
        let lens = h.lens("open issues", answering: [plaque])
        let rows = try require(h.editor.publishing).referencedInRows(of: plaque)
        expectEqual(rows.map(\.standIn), [relay, holder, lens], "in file order, not the order they came to stand for it")
        expectEqual(rows.map(\.symbol), ["arrow.up.forward", "arrow.up.forward", "magnifyingglass"],
                    "a relay says nothing of itself: the arrow; the holder and the lens do (a lens's words, its symbol)")
        expectEqual(rows.map(\.name), ["Board", "Board", "“open issues”"], "no connections: the board; a lens: its words")
        expectEqual(rows.map(\.detail), [nil, nil, nil], "all on the board shown")
    },
    test("line one names what's connected through the stand-in, up to two, then +n; once each, in either direction") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        h.publish(plaque)
        let holder = h.hold([plaque])
        let rows = { try require(h.editor.publishing).referencedInRows(of: plaque).map(\.name) }
        expectEqual(try rows(), ["Board"])
        let alpha = titled(h, "alpha", at: CGRect(x: 100, y: 400, width: 50, height: 50))
        h.add(CanvasTesting.Link(from: alpha, to: holder))
        expectEqual(try rows(), ["alpha"])
        h.add(CanvasTesting.Link(from: alpha, to: holder))
        expectEqual(try rows(), ["alpha"], "an arrow twice, one name")
        let gamma = titled(h, "gamma", at: CGRect(x: 200, y: 400, width: 50, height: 50))
        h.add(CanvasTesting.Link(from: holder, to: gamma))
        expectEqual(try rows(), ["alpha, gamma"], "out of the stand-in too")
        let cards = titled(h, "cards", at: CGRect(x: 300, y: 400, width: 50, height: 50))
        let more = titled(h, "more", at: CGRect(x: 400, y: 400, width: 50, height: 50))
        h.add(CanvasTesting.Link(from: cards, to: holder))
        h.add(CanvasTesting.Link(from: more, to: holder))
        expectEqual(try rows(), ["alpha, gamma +2"])
        let untitled = h.add(Draft(CGRect(x: 500, y: 400, width: 50, height: 50)))
        h.editor.transact { $0.delete([gamma, cards, more]) }
        h.add(CanvasTesting.Link(from: untitled, to: holder))
        let names = try rows()
        expectEqual(names, ["alpha, \(h.editor.registry.label(of: "draft").name)"], "an untitled shape is its kind's name")
    },
    test("a stand-in on another board has that board's name at its end; on the board shown it has none") {
        let pocket = ShapeRecord(Pocket(CGRect(x: 600, y: 600, width: 100, height: 100)))
        let plaque = ShapeRecord(Plaque(plaqueFrame))
        let inside = ShapeRecord(Holder(CGRect(x: 10, y: 10, width: 60, height: 20), stands: [Citation(plaque.id)]))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket), AnyShapeRecord(plaque)]),
                              children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(inside)])])
        let h = try publishingHarness([PocketsPlugin(), boards()], file: file)
        h.editor.transact { $0.update(pocket.id) { $0[TitleProperty.self] = "Checkout" } }
        h.publish(plaque.id)
        let publishing = try require(h.editor.publishing)
        expectEqual(publishing.referencedInRows(of: plaque.id).map(\.name), ["Checkout"], "no connections: the board, and so nothing at the end")
        expectEqual(publishing.referencedInRows(of: plaque.id).map(\.detail), [nil])
        let wire = h.add(Plaque(CGRect(x: 100, y: 400, width: 50, height: 50)))
        h.editor.transact { $0.update(wire) { $0[TitleProperty.self] = "alpha" } }
        h.editor.transact { $0.insert(ShapeRecord(CanvasTesting.Link(from: wire, to: inside.id))) }
        expectEqual(publishing.referencedInRows(of: plaque.id).map(\.name), ["alpha"], "a link from the root to the stand-in names its other end")
        expectEqual(publishing.referencedInRows(of: plaque.id).map(\.detail), ["Checkout"], "and the board it's on, at the end")
    },
    test("a row's click goes to the stand-in, its board shown first; the pointer on a row hovers it on the board shown") {
        let pocket = ShapeRecord(Pocket(CGRect(x: 600, y: 600, width: 100, height: 100)))
        let plaque = ShapeRecord(Plaque(plaqueFrame))
        let inside = ShapeRecord(Holder(CGRect(x: 10, y: 10, width: 60, height: 20), stands: [Citation(plaque.id)]))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket), AnyShapeRecord(plaque)]),
                              children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(inside)])])
        let h = try publishingHarness([PocketsPlugin()], file: file)
        h.publish(plaque.id)
        let publishing = try require(h.editor.publishing)
        let here = h.hold([plaque.id])
        publishing.hover(inside.id)
        expectEqual(h.editor.hovered, nil, "on another board: nothing to hover")
        publishing.hover(here)
        expectEqual(h.editor.hovered, here)
        publishing.endHover(inside.id)
        expectEqual(h.editor.hovered, here, "not what's hovered")
        publishing.endHover(here)
        expectEqual(h.editor.hovered, nil)
        publishing.goToStandIn(inside.id)
        h.wait(1)
        expectEqual(h.editor.board, BoardID(owner: pocket.id), "its board is shown")
        expectEqual(h.editor.selectedShapeIDs, [inside.id])
        h.editor.goBack()
        expectEqual(h.editor.board, .root)
    },
])

@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

// Insert (`CanvasCommand.insert`, `editor.insert`): every tool that places a shape has its item in the Insert
// menu, which puts one down without the pointer: in the frame the insertion spot gives, else centered in the
// view's clear part. The camera is at the origin at 100%, so view points are world units.

/// A color a disc may hold, which discs put down beside one take (`madeBeside`).
private enum Hue: ShapeProperty {
    static let key: PropertyKey = "hue"
    static var defaultValue: String? { nil }
}

/// Discs (40 × 40) that take the hue of the shape they're put down beside, and the hue every shape may hold.
@MainActor private func huedDiscs() -> Contributor {
    Contributor(id: "discs") { r in
        r.declare(Hue.self)
        r.optInEveryShape(to: Hue.self)
        r.shape(DiscDefinitionForTests()) { disc in
            disc.tool(label: "Disc", systemImage: "circle", placing: disc.placement(size: CGSize(width: 40, height: 40)) { Disc(.zero) })
            disc.madeBeside { made, neighbor in
                var made = made
                made[Hue.self] = neighbor[Hue.self]
                return made
            }
        }
    }
}

/// The insertion spot as a test claims it: what it was asked, in order, and the frame it gives (nil for none).
@MainActor private final class SpotLog {
    var asked: [(size: CGSize, beside: [ShapeID])] = []
    var gives: CGRect?
}

@MainActor private func spot(_ log: SpotLog) -> Contributor {
    Contributor(id: "spot") { r in
        r.insertionSpot { _, size, beside in
            log.asked.append((size, beside))
            return log.gives
        }
    }
}

/// What commands from a key or the menu bar act on: `shapes`, as Selection's selection would be.
@MainActor private final class Picked {
    var shapes: [ShapeID] = []
}

@MainActor private func picking(_ picked: Picked) -> Contributor {
    Contributor(id: "picked") { r in r.commandShapes { _ in picked.shapes } }
}

@MainActor private func harness(_ more: [any CanvasPlugin] = [], _ records: AnyShapeRecord...) throws -> EditorHarness {
    let h = try EditorHarness(plugins: [CardsPlugin(), huedDiscs()] + more, document: CanvasDocument(shapes: records))
    h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    return h
}

@MainActor private func disc(_ id: ShapeID, x: CGFloat = 0, hue: String? = nil) -> AnyShapeRecord {
    var record = AnyShapeRecord(ShapeRecord(id: id, Disc(CGRect(x: x, y: 0, width: 40, height: 40))))
    record[Hue.self] = hue
    return record
}

private let discTool = ToolID(placing: Disc.kind)
private let cardTool = ToolID(placing: Card.kind)

@MainActor let insertTests = Suite("Insert", [
    test("every tool that places a shape has an item in Insert, titled as the tool, in plugin order; a tool that places nothing has none") {
        let h = try harness()
        let items = h.editor.registry.menuBarCommands.filter { $0.menu == "Insert" }
        expectEqual(items.map(\.command), [.insert(cardTool), .insert(discTool)])
        expectEqual(items.map(\.title), ["Card", "Disc"])
        expect(!h.editor.registry.claims(.insert(.hand)), "the Hand places nothing")
        expect(h.editor.registry.report.contains("command insert:disc in InsertMenu.Shapes"), h.editor.registry.report)
        expect(h.editor.registry.report.contains("made beside → disc"), h.editor.registry.report)
    },
    test("with no insertion spot claimed, Insert puts the shape centered in the view's clear part, in one step named as the tool's placing, the default tool back") {
        let h = try harness()
        h.editor.setTool(cardTool)
        expect(h.editor.perform(.insert(discTool)))
        expectEqual(h.editor.document.shapes.compactMap(\.box), [CGRect(x: 380, y: 280, width: 40, height: 40)])
        expectEqual(h.editor.undoHistory.undoName, "Add Disc")
        expectEqual(h.editor.currentToolID, .hand, "the default tool back")
        h.editor.undo()
        expect(h.editor.document.shapes.isEmpty, "one step takes it back")
    },
    test("a placement that edits has its shape edited at once") {
        let h = try harness()
        expect(h.editor.perform(.insert(cardTool)))
        let card = try require(h.editor.document.shapes.first)
        expectEqual(card.box, CGRect(x: 350, y: 270, width: 100, height: 60))
        expectEqual(h.editor.editingShapeID, card.id)
        h.editor.endEditing(discarding: false)
        expectEqual(h.editor.undoHistory.undoName, "Add Card")
    },
    test("from a key or the menu bar the insertion spot is handed the shape's size and the selection, and the shape goes in the frame it gives; with none given, the middle of the view") {
        let a = ShapeID(), log = SpotLog(), picked = Picked()
        let h = try harness([spot(log), picking(picked)], disc(a))
        picked.shapes = [a]
        log.gives = CGRect(x: 120, y: 0, width: 40, height: 40)
        expect(h.editor.perform(.insert(discTool)))
        expectEqual(log.asked.map(\.size), [CGSize(width: 40, height: 40)])
        expectEqual(log.asked.map(\.beside), [[a]])
        expectEqual(h.editor.document.shapes.last?.box, CGRect(x: 120, y: 0, width: 40, height: 40))
        log.gives = nil
        picked.shapes = []
        expect(h.editor.perform(.insert(discTool)))
        expectEqual(log.asked.last?.beside, [])
        expectEqual(h.editor.document.shapes.last?.box, CGRect(x: 380, y: 280, width: 40, height: 40))
    },
    test("beside one shape, the shape is made as its kind says one beside a shape is; beside none or two, as its placement makes it") {
        let a = ShapeID(), b = ShapeID()
        let h = try harness([], disc(a, hue: "red"), disc(b, x: 200, hue: "blue"))
        expect(h.editor.insert(discTool, beside: [a]))
        expectEqual(h.editor.document.shapes.last?[Hue.self], "red", "made beside the red disc")
        expect(h.editor.insert(discTool, beside: []))
        expectEqual(h.editor.document.shapes.last?[Hue.self], nil)
        expect(h.editor.insert(discTool, beside: [a, b]))
        expectEqual(h.editor.document.shapes.last?[Hue.self], nil, "beside two, none of theirs")
    },
    test("Insert's item waits for idle, dimmed while a shape is edited; asked directly then (a note's ⇧↩), it ends the edit once it knows where the shape goes; a tool that places nothing inserts nothing") {
        let h = try harness()
        expect(h.editor.perform(.insert(cardTool)))
        let card = try require(h.editor.editingShapeID)
        expect(!h.editor.canPerform(.insert(discTool)), "dimmed while a shape is edited")
        expect(!h.editor.perform(.insert(discTool)))
        expectEqual(h.editor.document.shapes.count, 1)
        expect(h.editor.insert(discTool, beside: [card]))
        expect(h.editor.editingShapeID != card, "the card's edit ended")
        expectEqual(h.editor.document.shapes.count, 2)
        expect(!h.editor.insert(.hand, beside: []), "the Hand places nothing")
        expectEqual(h.editor.document.shapes.count, 2)
    },
    test("on a board that takes nothing (a frozen pocket's) Insert is dimmed and puts nothing down") {
        let p = ShapeID()
        var pocket = AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100))))
        pocket[Frozen.self] = true
        let h = try EditorHarness(plugins: [PocketsPlugin(), FreezingPlugin(), huedDiscs()], file: CanvasFile(root: CanvasDocument(shapes: [pocket])))
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        expect(h.enter(p))
        expect(h.editor.isBoardReadOnly)
        expect(!h.editor.canPerform(.insert(discTool)))
        expect(!h.editor.insert(discTool, beside: []))
        expect(h.editor.document.shapes.isEmpty)
    },
    test("while shapes wait to be placed Insert is dimmed and puts nothing down, so they still wait") {
        let h = try harness()
        let waiting = AnyShapeRecord(ShapeRecord(Disc(CGRect(x: 0, y: 0, width: 40, height: 40))))
        expect(h.editor.placeLater(PendingPlacement([waiting], stepName: "Add Discs") { _ in [CGPoint(x: -20, y: -20)] }))
        expect(!h.editor.canPerform(.insert(cardTool)), "dimmed")
        expect(!h.editor.insert(cardTool, beside: []))
        expect(h.editor.isPlacingLater, "still waiting")
        expect(h.editor.document.shapes.isEmpty)
    },
    test("with no view and no spot given, there is nowhere to put it: nothing, and false") {
        let h = try EditorHarness(plugins: [huedDiscs()])
        expect(!h.editor.insert(discTool, beside: []))
        expect(h.editor.document.shapes.isEmpty)
        expect(!h.editor.undoHistory.canUndo, "no step")
    },
])

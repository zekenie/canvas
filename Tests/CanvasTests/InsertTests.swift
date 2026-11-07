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
    test("every tool that places a shape has an item in Insert, titled as the tool, in plugin order, after the core's New Shape Beside; a tool that places nothing has none") {
        let h = try harness()
        let items = h.editor.registry.menuBarCommands.filter { $0.menu == "Insert" }
        expectEqual(items.map(\.command), [.insertBeside, .insert(cardTool), .insert(discTool)])
        expectEqual(items.map(\.title), ["New Shape Beside", "Card", "Disc"])
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

// ⇧↩ (`CanvasCommand.insertBeside`, `editor.toolBeside`): a shape of the selection's kind beside it, else the tool a plugin
// claimed (`registrar.insertsBesideByDefault`), and the public insert of a placement it and a tool's Insert go through.

private let ledgerTool = ToolID(placing: Ledger.kind)

/// A plugin that claims the disc's tool for ⇧↩ when the selection is no one kind a tool places.
@MainActor private func claimingDiscs() -> Contributor {
    Contributor(id: "claim") { r in r.insertsBesideByDefault(discTool) }
}

@MainActor private func linkRecord(_ id: ShapeID, _ from: ShapeID?, _ to: ShapeID?) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Link(from: from, to: to)))
}

@MainActor private func ledger(_ id: ShapeID, x: CGFloat = 0) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Ledger(CGRect(x: x, y: 0, width: 100, height: 60))))
}

@MainActor let insertBesideTests = Suite("Insert beside", [
    test("beside shapes of one kind a tool places, a shape of that kind, named for it; made as its kind says one beside a shape is; the tool's step") {
        let a = ShapeID(), picked = Picked()
        let h = try harness([LedgersPlugin(), claimingDiscs(), picking(picked)], ledger(a))
        picked.shapes = [a]
        expectEqual(h.editor.toolBeside([a]), ledgerTool)
        expectEqual(h.editor.menuTitle(of: .insertBeside), "New Ledger Beside")
        expect(h.editor.canPerform(.insertBeside))
        expect(h.editor.perform(.insertBeside))
        expectEqual(h.editor.document.shapes.map(\.kind), [Ledger.kind, Ledger.kind], "a ledger beside the ledger, not the claim's disc")
        expectEqual(h.editor.undoHistory.undoName, "Add Ledger")
        let discA = ShapeID()
        let more = try harness([claimingDiscs(), picking(picked)], disc(discA, hue: "red"))
        picked.shapes = [discA]
        expect(more.editor.perform(.insertBeside))
        expectEqual(more.editor.document.shapes.last?[Hue.self], "red", "a disc beside a red disc is red: madeBeside")
        // Two ledgers selected are still one kind.
        let b = ShapeID(), c = ShapeID()
        let two = try harness([LedgersPlugin(), claimingDiscs(), picking(picked)], ledger(b), ledger(c, x: 200))
        picked.shapes = [b, c]
        expectEqual(two.editor.toolBeside([b, c]), ledgerTool)
    },
    test("with nothing selected, an arrow-like shape no tool places, or shapes of several kinds, the claimed tool's shape; the item says what it makes") {
        let a = ShapeID(), b = ShapeID(), k = ShapeID(), picked = Picked()
        let h = try harness([LedgersPlugin(), LinksPlugin(), claimingDiscs(), picking(picked)], ledger(a), disc(b, x: 300), linkRecord(k, a, b))
        picked.shapes = []
        expectEqual(h.editor.toolBeside([]), discTool)
        expectEqual(h.editor.menuTitle(of: .insertBeside), "New Disc", "nothing to be beside")
        expect(h.editor.perform(.insertBeside))
        expectEqual(h.editor.document.shapes.last?.box, CGRect(x: 380, y: 280, width: 40, height: 40), "in the middle of the view")
        picked.shapes = [k]
        expectEqual(h.editor.toolBeside([k]), discTool, "a link, which no tool places")
        expectEqual(h.editor.menuTitle(of: .insertBeside), "New Disc Beside")
        picked.shapes = [a, b]
        expectEqual(h.editor.toolBeside([a, b]), discTool, "a ledger and a disc")
        expect(h.editor.perform(.insertBeside))
        expectEqual(h.editor.undoHistory.undoName, "Add Disc")
        expectEqual(h.editor.document.shapes.count, 5)
        h.editor.undo()
        expectEqual(h.editor.document.shapes.count, 4, "one step")
    },
    test("with no claim, a selection that is no one kind a tool places makes nothing: the command is dimmed and passes") {
        let a = ShapeID(), b = ShapeID(), picked = Picked()
        let h = try harness([LedgersPlugin(), picking(picked)], ledger(a), disc(b, x: 300))
        picked.shapes = []
        expectEqual(h.editor.toolBeside([]), nil)
        expect(!h.editor.canPerform(.insertBeside), "dimmed")
        expect(!h.editor.perform(.insertBeside))
        expectEqual(h.editor.menuTitle(of: .insertBeside), "New Shape Beside")
        picked.shapes = [a, b]
        expect(!h.editor.perform(.insertBeside))
        picked.shapes = [a]
        expect(h.editor.perform(.insertBeside), "one kind still has its own tool")
        expectEqual(h.editor.document.shapes.count, 3)
    },
    test("a tool of a kit that's off in the file isn't picked, so its kind gets the claim's; on, it is") {
        let plank = ShapeID(), picked = Picked()
        let record = AnyShapeRecord(ShapeRecord(id: plank, Plank(CGRect(x: 0, y: 0, width: 120, height: 30))))
        let h = try harness([WorkshopPlugin(), claimingDiscs(), picking(picked)], record)
        picked.shapes = [plank]
        expectEqual(h.editor.toolBeside([plank]), discTool, "the kit is off here")
        expectEqual(h.editor.menuTitle(of: .insertBeside), "New Disc Beside")
        h.editor.turn(Workshop.self, on: true)
        expectEqual(h.editor.toolBeside([plank]), ToolID(placing: Plank.kind))
        expectEqual(h.editor.menuTitle(of: .insertBeside), "New Plank Beside")
        expect(h.editor.perform(.insertBeside))
        expectEqual(h.editor.document.shapes.map(\.kind), [Plank.kind, Plank.kind])
        h.editor.turn(Workshop.self, on: false)
        expectEqual(h.editor.toolBeside([plank]), discTool, "off again")
    },
    test("it waits for idle: dimmed while a shape is edited, and while shapes wait to be placed") {
        let picked = Picked()
        let h = try harness([claimingDiscs(), picking(picked)])
        expect(h.editor.perform(.insert(cardTool)))
        expect(h.editor.editingShapeID != nil)
        expect(!h.editor.canPerform(.insertBeside), "a shape is edited")
        h.editor.endEditing(discarding: false)
        expect(h.editor.canPerform(.insertBeside))
        let waiting = AnyShapeRecord(ShapeRecord(Disc(CGRect(x: 0, y: 0, width: 40, height: 40))))
        expect(h.editor.placeLater(PendingPlacement([waiting], stepName: "Add Discs") { _ in [CGPoint(x: -20, y: -20)] }))
        expect(!h.editor.canPerform(.insertBeside), "shapes wait")
    },
    test("insert(_:named:beside:) puts a placement down in one step of the name it's given, and gives the shape's id; nil for nothing put down") {
        let a = ShapeID()
        let h = try harness([claimingDiscs()], disc(a, hue: "blue"))
        let placement = try require(h.editor.registry.placement(for: Disc.kind))
        let id = try require(h.editor.insert(placement, named: "Add Thing", beside: [a]))
        expectEqual(h.editor.document.shapes.last?.id, id)
        expectEqual(h.editor.document.shapes.last?[Hue.self], "blue", "made beside the blue disc")
        expectEqual(h.editor.undoHistory.undoName, "Add Thing")
        expectEqual(h.editor.insert(placement, named: "Add Thing", beside: [])?.description.isEmpty, false)
        // Shapes waiting to be placed: nothing.
        let waiting = AnyShapeRecord(ShapeRecord(Disc(CGRect(x: 0, y: 0, width: 40, height: 40))))
        expect(h.editor.placeLater(PendingPlacement([waiting], stepName: "Add Discs") { _ in [CGPoint(x: -20, y: -20)] }))
        let count = h.editor.document.shapes.count
        expectEqual(h.editor.insert(placement, named: "Add Thing", beside: []), nil)
        expectEqual(h.editor.document.shapes.count, count)
        // A board that takes nothing.
        let p = ShapeID()
        var pocket = AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100))))
        pocket[Frozen.self] = true
        let frozen = try EditorHarness(plugins: [PocketsPlugin(), FreezingPlugin(), huedDiscs()], file: CanvasFile(root: CanvasDocument(shapes: [pocket])))
        frozen.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        expect(frozen.enter(p))
        let discPlacement = try require(frozen.editor.registry.placement(for: Disc.kind))
        expectEqual(frozen.editor.insert(discPlacement, named: "Add Thing", beside: []), nil)
        expect(frozen.editor.document.shapes.isEmpty)
    },
    test("the claim is one, and the tool must place a shape; the report says it") {
        let both = Contributor(id: "both") { r in r.insertsBesideByDefault(discTool) }
        let h = try harness([claimingDiscs()])
        expect(h.editor.registry.report.contains("insert beside by default disc"), h.editor.registry.report)
        expectEqual(h.editor.registry.insertsBesideByDefault, discTool)
        expectThrows(RegistryError.conflict(point: "InsertBesideByDefault", key: "the tool that inserts beside by default", plugins: ["claim", "both"])) {
            _ = try Registry(plugins: [huedDiscs(), claimingDiscs(), both])
        }
        expectThrows(RegistryError.invalid(point: "InsertBesideByDefault", reason: "no plugin registers a tool hand that places a shape")) {
            _ = try Registry(plugins: [Contributor(id: "hand") { $0.insertsBesideByDefault(.hand) }])
        }
    },
])

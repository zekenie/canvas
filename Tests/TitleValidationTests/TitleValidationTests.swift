import Adornments
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Selection
import SlashCommands
import TestKit
import TitleValidation
import Titles
import Validation

// Fixtures only, so these tests show the bridge knows no real kind: cards and pockets are named
// (the title Titles keeps), discs' titles are worked out from their size, and boxes have none.

/// Titles for the fixtures: cards and pockets named, discs worked out.
@MainActor private var fixtureTitles: Contributor {
    Contributor(id: "fixture-titles") { registrar in
        registrar.title(Card.self, contents: false)
        registrar.title(Pocket.self, contents: false)
        registrar.title(Disc.self, contents: false) { disc in "Disc, \(Int(disc.props.frame.width)) × \(Int(disc.props.frame.height))" }
    }
}

/// A harness on `file`, with Titles (and the slash commands it offers), Validation and the bridge.
@MainActor private func harness(_ file: CanvasFile = CanvasFile()) throws -> EditorHarness {
    try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CardsPlugin(), PocketsPlugin(), ValidationPlugin(),
                                AdornmentsPlugin(), SlashCommandsPlugin(), TitlesPlugin(), fixtureTitles, TitleValidationPlugin()], file: file)
}

/// A card called `title`.
@MainActor private func card(_ title: String?, x: CGFloat = 0) -> AnyShapeRecord {
    var card = AnyShapeRecord(ShapeRecord(Card(CGRect(x: x, y: 0, width: 100, height: 60))))
    card[TitleProperty.self] = title
    return card
}

/// A pocket called `title`.
@MainActor private func pocket(_ title: String? = nil, x: CGFloat = 0) -> AnyShapeRecord {
    var pocket = AnyShapeRecord(ShapeRecord(Pocket(CGRect(x: x, y: 200, width: 200, height: 100))))
    pocket[TitleProperty.self] = title
    return pocket
}

/// A file of `root`'s shapes, each pocket's board holding what `boards` gives it.
@MainActor private func file(_ root: [AnyShapeRecord], _ boards: [ShapeID: [AnyShapeRecord]] = [:]) -> CanvasFile {
    CanvasFile(root: CanvasDocument(shapes: root), children: boards.mapValues { CanvasDocument(shapes: $0) })
}

extension EditorHarness {
    /// What the engine finds on the board shown, by shape.
    @MainActor fileprivate var warnings: [ShapeID: [String]] {
        (editor.validation?.results ?? [:]).mapValues { $0.issues.map(\.message) }
    }

    @MainActor fileprivate func rename(_ id: ShapeID, _ title: String?) {
        editor.transact("Rename") { $0.update(id) { $0[TitleProperty.self] = title } }
    }
}

private func shared(_ title: String) -> [String] { ["“\(title)” is another shape’s title too."] }

@MainActor let titleValidationTests = Suite("Titles two shapes share", [
    test("two shapes with one title are each warned about it, about their title; others aren't") {
        let a = card("API"), b = card("API", x: 200), c = card("Billing", x: 400), d = card(nil, x: 600)
        let h = try harness(file([a, b, c, d]))
        expectEqual(h.warnings, [a.id: shared("API"), b.id: shared("API")])
        expectEqual(h.editor.validation?.result(for: a.id)?.issues.first?.field, "title")
        expectEqual(h.editor.validation?.result(for: a.id)?.issues.first?.severity, .warning)
    },
    test("a rename to a title another shape has warns that one too, which the commit didn't change; renamed away or cleared, neither is") {
        let a = card("API"), b = card("Billing", x: 200)
        let h = try harness(file([a, b]))
        expectEqual(h.warnings, [:])
        h.rename(b.id, "API")
        expectEqual(h.warnings, [a.id: shared("API"), b.id: shared("API")])
        h.rename(b.id, "Billing")
        expectEqual(h.warnings, [:])
        h.rename(a.id, "Billing")
        expectEqual(h.warnings, [a.id: shared("Billing"), b.id: shared("Billing")])
        h.rename(b.id, "  ")
        expectEqual(h.warnings, [:], "a blank title is none")
    },
    test("a third shape of a title, and one of three renamed away, leave the others warned") {
        let a = card("API"), b = card("API", x: 200), c = card("Billing", x: 400)
        let h = try harness(file([a, b, c]))
        h.rename(c.id, "API")
        expectEqual(h.warnings, [a.id: shared("API"), b.id: shared("API"), c.id: shared("API")])
        h.rename(a.id, "Gateway")
        expectEqual(h.warnings, [b.id: shared("API"), c.id: shared("API")])
    },
    test("deleting one of two takes the other's warning; undo and redo follow") {
        let a = card("API"), b = card("API", x: 200)
        let h = try harness(file([a, b]))
        expectEqual(h.warnings.count, 2)
        h.editor.transact("Delete") { $0.delete([b.id]) }
        expectEqual(h.warnings, [:])
        h.editor.undo()
        expectEqual(h.warnings, [a.id: shared("API"), b.id: shared("API")])
        h.editor.redo()
        expectEqual(h.warnings, [:])
    },
    test("undoing a rename gives the warnings back") {
        let a = card("API"), b = card("API", x: 200)
        let h = try harness(file([a, b]))
        h.rename(a.id, "Gateway")
        expectEqual(h.warnings, [:])
        h.editor.undo()
        expectEqual(h.warnings, [a.id: shared("API"), b.id: shared("API")])
    },
    test("titles are compared as they read: folded, then exactly") {
        let a = card("Big  plan"), b = card("Big plan", x: 200), c = card("big plan", x: 400)
        let h = try harness(file([a, b, c]))
        expectEqual(h.warnings, [a.id: shared("Big plan"), b.id: shared("Big plan")])
    },
    test("a derived title counts, whatever the kinds: two discs of one size, and a card named as they're called") {
        let one = AnyShapeRecord(ShapeRecord(Disc(CGRect(x: 0, y: 0, width: 40, height: 40))))
        let two = AnyShapeRecord(ShapeRecord(Disc(CGRect(x: 100, y: 0, width: 40, height: 40))))
        let three = AnyShapeRecord(ShapeRecord(Disc(CGRect(x: 200, y: 0, width: 50, height: 50))))
        let named = card("Disc, 50 × 50", x: 300)
        let h = try harness(file([one, two, three, named]))
        expectEqual(h.warnings, [one.id: shared("Disc, 40 × 40"), two.id: shared("Disc, 40 × 40"),
                                 three.id: shared("Disc, 50 × 50"), named.id: shared("Disc, 50 × 50")])
        expectEqual(h.editor.validation?.result(for: three.id)?.issues.first?.field, nil, "a disc keeps no title to point at")
        expectEqual(h.editor.validation?.result(for: named.id)?.issues.first?.field, "title")
    },
    test("titles are the file's: a shape on the root and one in a pocket share one, and each is warned on its own board") {
        let outer = card("API"), inner = card("API"), box = pocket("Payments", x: 300)
        let h = try harness(file([outer, box], [box.id: [inner]]))
        expectEqual(h.warnings, [outer.id: shared("API")])
        expect(h.enter(box.id))
        expectEqual(h.warnings, [inner.id: shared("API")])
        expectEqual(h.editor.validation?.affected(by: ChangeSet(elsewhere: [outer.id])), [], "nothing was renamed while the pocket wasn't shown")
    },
    test("a rename on one board warns a shape on a board kept, as it's shown again, and names it for what shows marks") {
        let outer = card("API"), inner = card("Spec"), other = card("Notes", x: 200), box = pocket(x: 300)
        let h = try harness(file([outer, box], [box.id: [inner, other]]))
        expect(h.enter(box.id))
        expectEqual(h.warnings, [:])
        h.editor.showBoard(.root)
        expectEqual(h.warnings, [:])
        h.rename(outer.id, "Spec")
        expectEqual(h.warnings, [outer.id: shared("Spec")])
        let engine = try require(h.editor.validation)
        let checked = TitleValidationPlugin.titlesChecked
        expect(h.enter(box.id))
        expectEqual(h.warnings, [inner.id: shared("Spec")])
        expectEqual(TitleValidationPlugin.titlesChecked, checked + 1, "the board kept is taken back, its one named shape checked again")
        expectEqual(engine.affected(by: ChangeSet(elsewhere: [outer.id])), [inner.id], "the table of contents' catch-up reads its mark again")
        h.editor.showBoard(.root)
        h.rename(outer.id, "API")
        expect(h.enter(box.id))
        expectEqual(h.warnings, [:])
    },
    test("deleting a pocket takes the titles on its board with it, and undo brings them back") {
        let outer = card("API"), inner = card("API"), box = pocket(x: 300)
        let h = try harness(file([outer, box], [box.id: [inner]]))
        expectEqual(h.warnings, [outer.id: shared("API")])
        h.editor.transact("Delete") { $0.delete([box.id]) }
        expectEqual(h.warnings, [:])
        h.editor.undo()
        expectEqual(h.warnings, [outer.id: shared("API")])
    },
    test("a pocket's title counts against a card's, wherever its board is") {
        let outer = card("Payments"), box = pocket("Payments", x: 300)
        let h = try harness(file([outer, box]))
        expectEqual(h.warnings, [outer.id: shared("Payments"), box.id: shared("Payments")])
    },
    test("a move checks no title") {
        let a = card("API"), b = card("API", x: 200)
        let h = try harness(file([a, b]))
        expectEqual(h.warnings.count, 2)
        let checked = TitleValidationPlugin.titlesChecked
        h.editor.transact("Move") { $0.translate([a.id, b.id], by: CGPoint(x: 10, y: 10)) }
        expectEqual(h.warnings.count, 2)
        expectEqual(TitleValidationPlugin.titlesChecked, checked)
    },
    test("a file put in place is read afresh") {
        let a = card("API"), b = card("Billing", x: 200)
        let h = try harness(file([a, b]))
        expectEqual(h.warnings, [:])
        let c = card("Billing"), d = card("Billing", x: 200)
        h.editor.replaceFile(with: file([c, d]))
        expectEqual(h.warnings, [c.id: shared("Billing"), d.id: shared("Billing")])
    },
    test("outside the engine, a shape on another board is warned given the editor (a query's check), and not without one (draw's)") {
        let outer = card("API"), inner = card("API"), box = pocket(x: 300)
        let h = try harness(file([outer, box], [box.id: [inner]]))
        let board = h.file[BoardID(owner: box.id)], registry = h.editor.registry
        let record = try require(board[inner.id])
        expectEqual(registry.validationIssues(of: record, in: ShapeContext(document: board, registry: registry), editor: h.editor).map(\.message),
                    shared("API"))
        expectEqual(registry.validationIssues(of: record, in: ShapeContext(document: board, registry: registry)), [])
    },
])

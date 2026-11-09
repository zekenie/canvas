import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import ContextMenus
import Engineering
import Geometry
import LanguageModels
import Selection
import ShippedTesting
import TestKit
import Titles

// Keys look right, as shipped (K4): every key drawn by `canvas draw` is a level curve from its column's row to the row it
// references, 2.5 wide; T3 panel 4's marks (a unique column's key bars at both ends, a nullable one's a bar and a circle at
// the row it references) and a column changed in place redrawing its key's marks with nothing written to the arrow; an arrow
// from a row to a table as a whole meeting it at a row clear of a key's end there; and a key's ends leaving Toggle Arrowhead out.

private let billing = #"""
    table "payments" columns: "id uuid pk\norder_id uuid unique\namount_cents int"
    table "refunds" right of "payments" columns: "id uuid pk\npayment_id uuid null\namount_cents int"
    table "orders" left of "payments" columns: "id uuid pk\ncustomer_id uuid"
    edge "payments".order_id -> "orders".id
    edge "refunds".payment_id -> "payments".id
    """#

@MainActor private func billingEditor() throws -> CanvasEditor {
    let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
    editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
    _ = try drawnInProcess(billing, on: editor)
    return editor
}

@MainActor private func table(_ editor: CanvasEditor, _ title: String) throws -> ShapeRecord<DatabaseTable> {
    try require(editor.document.shapes.first { $0[TitleProperty.self] == title }?.typed(as: DatabaseTable.self))
}

/// The key that starts at `table`'s `column`.
@MainActor private func key(_ editor: CanvasEditor, from title: String, _ column: String) throws -> ShapeRecord<Arrow> {
    let from = try table(editor, title)
    let part = try require(from.props.columns.first { $0.name == column }?.id)
    return try require(editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }.first { $0.props.start.binding?.part == part })
}

@MainActor let keyLookShippedTests = Suite("Keys look right, shipped", [
    test("T3 panel 4: a unique column's key is bars at both ends, a nullable one's a bar and a circle at the row it references; both level, 2.5 wide") {
        let editor = try billingEditor()
        let unique = try key(editor, from: "payments", "order_id"), nullable = try key(editor, from: "refunds", "payment_id")
        expectEqual(editor.arrowLook(of: unique.id), ConnectionLook(start: .one, end: .one, lineWidth: 2.5))
        expectEqual(editor.arrowLook(of: nullable.id), ConnectionLook(start: .many, end: .zeroOrOne, lineWidth: 2.5))
        for id in [unique.id, nullable.id] {
            expect(try require(editor.arrowGeometry(of: id)).isLevel, "a key is a level curve")
            expectEqual(editor.registry.lineWidth(of: try require(editor.document[id]), in: editor.shapeContext), 2.5)
        }
        // payments is right of orders: the key leaves order_id's left side going left and enters orders.id's right side.
        let geometry = try require(editor.arrowGeometry(of: unique.id))
        expectEqual(geometry.partSide(at: .start), .left)
        expectEqual(geometry.partSide(at: .end), .right)
    },
    test("a column changed in place redraws its key's marks, with nothing written to the key; Undo puts them back") {
        let editor = try billingEditor()
        let id = try key(editor, from: "refunds", "payment_id").id
        let before = try key(editor, from: "refunds", "payment_id")
        let refunds = try table(editor, "refunds")
        editor.transact("Change Column") { tx in
            tx.update(refunds.id, as: DatabaseTable.self) { table in
                guard let index = table.props.columns.firstIndex(where: { $0.name == "payment_id" }) else { return }
                table.props.columns[index].nullable = false
                table.props.columns[index].unique = true
            }
        }
        expectEqual(editor.arrowLook(of: id), ConnectionLook(start: .one, end: .one, lineWidth: 2.5))
        expectEqual(try key(editor, from: "refunds", "payment_id").props, before.props, "the key as it was")
        editor.undo()
        expectEqual(editor.arrowLook(of: id), ConnectionLook(start: .many, end: .zeroOrOne, lineWidth: 2.5))
    },
    test("an arrow from a row to a table as a whole meets the table at the side facing it, at a row clear of the key that ends at its first row there (K17)") {
        let editor = try billingEditor()
        let refunds = try table(editor, "refunds"), payments = try table(editor, "payments")
        var arrow = ShapeRecord(Arrow(start: .bound(ArrowBinding(shapeID: refunds.id, normalizedAnchor: CGPoint(x: 0, y: 0.5), isPrecise: true,
                                                                 isExact: true, part: refunds.props.columns[2].id)),
                                      end: .bound(ArrowBinding(shapeID: payments.id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false,
                                                               isExact: false)), endArrowhead: false))
        arrow[ChannelProperty.self] = ForeignKey.id
        editor.transact("Add Arrow") { $0.insert(AnyShapeRecord(arrow)) }
        let geometry = try require(editor.arrowGeometry(of: arrow.id))
        // refunds' key ends at payments' id, its first row, on the side facing refunds: the arrow comes in at amount_cents, the
        // first row there with no key's end beside it, so the two don't read as one tangle at the corner.
        let clear = try require(editor.shapeContext.geometry(of: payments.id)?.parts.frame(payments.props.columns[2].id)).rect
        let body = try require(geometry.levelBody)
        expectEqual(body.end, CGPoint(x: clear.maxX, y: clear.midY), "payments' amount_cents row's right side, facing refunds")
        expectEqual(geometry.end, body.end, "a marked end: no gap")
    },
    test("a key's ends have no head to toggle: the Shape menu leaves Toggle Arrowhead out, a plain arrow keeps it") {
        let editor = try billingEditor()
        editor.selection = try key(editor, from: "payments", "order_id").id
        let outline = try require(editor.menuForSelection(omitting: [])).outline
        expect(!outline.contains("Toggle Start Arrowhead") && !outline.contains("Toggle End Arrowhead"), "\(outline)")
        let plain = ShapeRecord(Arrow(start: .free(CGPoint(x: 0, y: 900)), end: .free(CGPoint(x: 200, y: 900))))
        editor.transact("Add Arrow") { $0.insert(AnyShapeRecord(plain)) }
        editor.selection = plain.id
        expect(try require(editor.menuForSelection(omitting: [])).outline.contains("Toggle End Arrowhead"))
    },
])

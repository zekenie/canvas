import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import CoreGraphics
import Foundation
import Mentions
import Selection
import TestKit
import Types

// What a keystroke in a card names: the arrow alone, with no end rechecked and no note laid out or its row rebuilt.

@MainActor let cardKeystrokeTests = Suite("A keystroke in a card", [
    test("a keystroke in the row card's cell names the arrow alone: no note, no layout, no rows rebuilt") {
        let r = try RowCardRig()
        defer { r.close() }
        let a1 = r.s.relate(r.s.note, r.s.layerNote)
        _ = a1
        let notes = [r.s.note, r.s.layerNote]
        for id in notes { _ = r.s.rows(id) }
        expect(try r.open())
        let form = try require(r.form)
        form.focus(r.stop(0, 1))
        let heardBefore = r.s.heard.changes.count
        let layout = r.editor.layoutRevision
        let shown = r.s.book.rowsShown
        r.window.type("e")
        for id in notes { _ = r.s.rows(id) }
        let named = r.s.heard.changes.dropFirst(heardBefore)
        expect(named.allSatisfy { !$0.everything && $0.notes.isEmpty }, "names notes: \(named.map { ($0.arrows.count, $0.notes.count, $0.everything) })")
        expectEqual(r.editor.layoutRevision, layout, "no layout")
        expectEqual(r.s.book.rowsShown - shown, 0, "no row rebuilt")
    },
    test("a keystroke in the arrow card's cell names the arrow alone") {
        let r = try ArrowCardRig()
        defer { r.close() }
        let notes = [r.s.note, r.s.layerNote]
        for id in notes { _ = r.s.rows(id) }
        r.editor.openRelationshipCard(for: r.arrow)
        let heardBefore = r.s.heard.changes.count
        let layout = r.editor.layoutRevision
        let shown = r.s.book.rowsShown
        r.window.type("e")
        for id in notes { _ = r.s.rows(id) }
        let named = r.s.heard.changes.dropFirst(heardBefore)
        expect(named.allSatisfy { !$0.everything && $0.notes.isEmpty }, "names notes: \(named.map { ($0.arrows.count, $0.notes.count, $0.everything) })")
        expectEqual(r.editor.layoutRevision, layout, "no layout")
        expectEqual(r.s.book.rowsShown - shown, 0, "no row rebuilt")
    },
])

@MainActor let hubKeystrokeTests = Suite("A keystroke at a hub", [
    test("a value typed on one of a hub's 1,000 arrows leaves the hub's row as it was") {
        let s = try RelationScene(more: [])
        s.fromEnd()
        s.toEnd()
        s.editor.transact { $0.update(s.rel) { $0[TypeSchemaProperty.self] = SchemaText(roleSchema) } }
        var arrows: [ShapeID] = []
        s.editor.transact("Hub") { transaction in
            for n in 0..<1_000 {
                let layer = slipRecord("Layer \(n)", of: [s.layer], at: CGPoint(x: 3_000 + CGFloat(n % 50) * 300, y: 3_000 + CGFloat(n / 50) * 200))
                transaction.insert(layer)
                var bond = AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: s.note, to: layer.id)))
                bond[IsAProperty.self] = [TypeLink(s.rel)]
                transaction.insert(bond)
                arrows.append(bond.id)
            }
        }
        _ = s.rows(s.note)
        let target = arrows[500]
        // The hub's row is read each frame; a value typed on one of its arrows leaves it as it was.
        for n in 0..<5 { s.editor.fieldWriter?.setTyped("engineer \(n)", as: .text, at: FieldPath(field: "role"), of: target) }
        let shown = s.book.rowsShown
        s.editor.fieldWriter?.setTyped("engineer x", as: .text, at: FieldPath(field: "role"), of: target)
        _ = s.rows(s.note)
        expectEqual(s.book.rowsShown - shown, 0, "a value typed on an arrow rebuilds no note's row")
    },
])

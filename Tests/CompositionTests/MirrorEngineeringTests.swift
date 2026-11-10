import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Foundation
import Geometry
import Mentions
import References
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Titles

// Mirrors of the engineering kit's kinds: what a mirror of a table does with what the person does to it. A table's rows are
// typed in the line editor, which reaches the board shown only, so a table's mirror is never typed into (Return finds nothing
// to open, a double-click on its body edits nothing); it lends its columns where it draws them, so a key through the pill meets
// the row drawn in the body; it makes room below as it is expanded; a pill for a taken-out endpoint that is put back into its API
// is a pill for the row, not a mirror; and a typed note's mirror raises the mirror, never the note, while it grows.

/// Customers and orders on Policies; a pill for customers on Checkout, beside the ledger table it is joined to.
@MainActor func mirrorTables(_ stage: GalleryStage) throws {
    try stage.run("""
    subboard "Policies" size: 200x100
    subboard "Checkout" right of "Policies" size: 200x100
    """)
    try stage.run(#"table "customers" in "Policies" columns: "id uuid pk\nname text\nemail text""#)
    try stage.run(#"table "orders" in "Policies" below "customers" columns: "id uuid pk\ntotal_cents int""#)
    try stage.show(try stage.board(of: "Checkout"))
    try stage.run(#"table "ledger" columns: "id uuid pk\ncustomer_id uuid""#)
    try stage.run(#"edge "ledger" -> "customers" via: reference"#)
    stage.editor.selection = nil
}

@MainActor let mirrorEngineeringTests = Suite("Mirrors of tables, shipped", [
    test("a table's mirror is never typed into: Return types in no table, a double-click on its body edits nothing, and nothing is left set") {
        try GalleryStage.with(dark: false, size: CGSize(width: 1000, height: 700)) { stage in
            try mirrorTables(stage)
            try stage.expand(["customers"])
            let mirror = try stage.pill(for: "customers"), table = try stage.shape("customers")
            try stage.look(at: "ledger", inset: CGPoint(x: 60, y: 40))
            expect(stage.editor.shown(through: mirror) != nil, "it shows the table")
            stage.editor.selectedShapeIDs = [mirror]
            stage.editor.openSelection([mirror])
            expectEqual(stage.editor.editingStandIn, nil, "Return opens nothing through the mirror")
            expect(stage.editor.editingShapeID != table, "the table isn't what's typed in")
            stage.editor.endEditing()
            let frame = try require(stage.editor.shapeContext.frame(of: mirror))
            stage.doubleClick(atWorld: CGPoint(x: frame.midX, y: frame.maxY - 30))
            expectEqual(stage.editor.editingShapeID, nil, "a double-click on the body edits nothing")
            expectEqual(stage.editor.editingStandIn, nil)
            expect(!stage.editor.beginEditing(table, through: mirror), "and neither does the core")
            expect(!isBlank(stage.picture()), "the mirror draws")
        }
    },
    test("a table's mirror lends its columns where it draws them: a key through the pill meets the row drawn in the body, a pill meets the pill") {
        try GalleryStage.with(dark: false, size: CGSize(width: 1000, height: 700)) { stage in
            try mirrorTables(stage)
            let mirror = try stage.pill(for: "customers"), table = try stage.shape("customers")
            let arrow = try require(stage.editor.document.shapes.first { $0.typed(as: Arrow.self) != nil }?.id)
            let columns = try require(stage.editor.registry.parts(of: try require(stage.editor.shape(inFile: table))))
            let name = try require(columns.first { $0.name == "name" }).id
            // The key's end names the column, as KeyArrows binds it through a pill for the table.
            stage.editor.transact("Bind to a column") {
                $0.update(arrow, as: Arrow.self) {
                    guard var binding = $0.props.end.binding else { return }
                    binding.part = name
                    $0.props.end = .bound(binding)
                }
            }
            expect(try require(stage.editor.shapeContext.geometry(of: mirror)).parts.isEmpty, "a pill lists no columns")
            let pillMiddle = try require(stage.editor.arrowGeometry(of: arrow)).endHandle
            let pill = try require(stage.editor.document[mirror]?.box)
            expectEqual(pillMiddle, CGPoint(x: pill.midX, y: pill.midY), "its end meets the pill whole")
            try stage.expand(["customers"])
            let geometry = try require(stage.editor.shapeContext.geometry(of: mirror))
            expectEqual(geometry.parts.frames.count, 3, "the columns, where the mirror draws them")
            let (_, transform) = try require(stage.editor.shown(through: mirror))
            let original = try require(stage.editor.geometry(inFile: table)).parts
            for (shown, was) in zip(geometry.parts.frames, original.frames) {
                expectEqual(shown.id, was.id)
                expectEqual(shown.rect, was.rect.applying(transform), "mapped through the mirror's transform")
            }
            let row = try require(geometry.parts.frame(name)).rect
            let end = try require(stage.editor.arrowGeometry(of: arrow)).endHandle
            expect(row.minY <= end.y && end.y <= row.maxY, "the end is level with the column's row: \(end) in \(row)")
            expect(end.x == row.minX || end.x == row.maxX, "at its side: \(end) in \(row)")
            stage.editor.perform(.collapseReference, on: [mirror])
            stage.settlePills()
            expectEqual(try require(stage.editor.arrowGeometry(of: arrow)).endHandle, pillMiddle, "collapsed, the pill again")
        }
    },
    test("expanding a pill pushes what is below it down in the same step, and the step undoes whole") {
        try GalleryStage.with(dark: false, size: CGSize(width: 1000, height: 700)) { stage in
            try mirrorTables(stage)
            let mirror = try stage.pill(for: "customers")
            let pill = try require(stage.editor.document[mirror]?.box)
            let below = stage.editor.add(StickyNote(frame: CGRect(x: pill.minX, y: pill.maxY + 20, width: 200, height: 100), text: "Below"))
            let top = try require(stage.editor.document[below]?.box).minY
            try stage.expand(["customers"])
            let grown = try require(stage.editor.shapeContext.frame(of: mirror))
            let moved = try require(stage.editor.document[below]?.box).minY
            expect(moved > top, "the note below moved down: \(top) to \(moved)")
            expect(moved >= grown.maxY, "and clear of the mirror: \(moved) under \(grown.maxY)")
            stage.editor.undo()
            expectEqual(try require(stage.editor.document[below]?.box).minY, top, "one step takes both back")
            expectEqual(stage.editor.document[mirror]?.typed(as: Reference.self)?.props.look, .pill)
        }
    },
    test("a typed note edited through its mirror raises the mirror while it grows, never the note it shows") {
        try GalleryStage.with(dark: false, size: CGSize(width: 1400, height: 800)) { stage in
            try mirrorKinds(stage)
            try stage.expand(["Order #1042"])
            let mirror = try stage.pill(for: "Order #1042"), note = try stage.shape("Order #1042")
            let frame = try require(stage.editor.shapeContext.frame(of: mirror))
            stage.look(at: CGPoint(x: frame.minX - 40, y: frame.minY - 40))
            stage.editor.selectedShapeIDs = [mirror]
            stage.editor.openSelection([mirror])
            stage.window.settle()
            expectEqual(stage.editor.editingStandIn, mirror)
            expect(stage.editor.editedShapeOverflow?.id != note, "the note, on another board, is never what's raised")
            if let overflow = stage.editor.editedShapeOverflow {
                expectEqual(overflow.id, mirror, "what grows is the mirror")
                expect(!overflow.areas.isEmpty)
            }
            stage.editor.endEditing()
            expectEqual(stage.editor.editedShapeOverflow == nil, true, "nothing is raised once editing ends")
        }
    },
])

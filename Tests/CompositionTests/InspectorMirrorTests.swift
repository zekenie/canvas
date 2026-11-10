import Canvas
import CanvasRPC
import CanvasTesting
import Colors
import DetailPanel
import Foundation
import References
import Selection
import TestKit
import Titles
import Types

// The inspector of a reference expanded into a mirror (issue 24): its Reference tab, then the original's own tabs, each
// bound to the original, which is on another board; a pill not expanded has only its Reference tab.

private let orderSchema = #""{\"type\": \"object\", \"properties\": {\"total\": {\"type\": \"number\"}}}""#

@MainActor private func stagedPill(_ stage: GalleryStage) throws -> (pill: ShapeID, note: ShapeID, board: BoardID) {
    try stage.run("""
    subboard "Policies" size: 200x100
    subboard "Checkout" right of "Policies" size: 200x100
    """)
    try stage.run("""
    sticky-note "Order" in "Policies" schema: \(orderSchema) text: "An order has a total." size: 260x180
    sticky-note "Order #1042" in "Policies" right of "Order" is: "Order" color: blue fieldValues: {"total": 120} size: 260x180
    """)
    let board = try stage.board(of: "Policies")
    try stage.show(try stage.board(of: "Checkout"))
    try stage.run(#"sticky-note "Anchor" size: 120x60"#)
    try stage.run(#"edge "Anchor" -> "Order #1042" via: reference"#)
    return (try stage.pill(for: "Order #1042"), try stage.shape("Order #1042"), board)
}

@MainActor let inspectorMirrorTests = Suite("The inspector of a mirror", [
    test("a pill shows only its Reference tab; expanded into a mirror, Reference first, then the note's own tabs") {
        try GalleryStage.with(dark: false, size: CGSize(width: 900, height: 620)) { stage in
            let (pill, note, _) = try stagedPill(stage)
            let panel = try require(stage.editor.detailPanel)
            // As a pill: its own tab and the Connections tab every shape has, none of the note's.
            expectEqual(try require(panel.panelLayout(for: pill)).tabs.map(\.title), ["Reference", "Connections"])
            stage.editor.perform(.expandReference, on: [pill])
            stage.settlePills()
            let layout = try require(panel.panelLayout(for: pill))
            let titles = layout.tabs.map(\.title)
            expectEqual(titles.first, "Reference")
            expect(titles.count > 1 && titles.contains("Types") && titles.contains("Style"), "\(titles)")
            expectEqual(titles.filter { $0 == "Connections" }.count, 1, "one Connections, the note's: \(titles)")
            let connections = try require(layout.tabs.first { $0.title == "Connections" })
            expectEqual(layout.sectionsShownThrough(in: connections), layout.sections(in: connections), "the note's list alone")
            let types = try require(layout.tabs.first { $0.title == "Types" })
            expectEqual(layout.sectionsShownThrough(in: types).map(\.section).contains("fields"), true, "\(layout.sections(in: types))")
            let style = try require(layout.tabs.first { $0.title == "Style" })
            expectEqual(layout.sectionsShownThrough(in: style).count, layout.sections(in: style).count)
            expect(layout.sectionsShownThrough(in: try require(layout.tabs.first)).isEmpty, "Reference's own sections are the pill's")
            expect(stage.editor.shape(inFile: note) != nil)
        }
    },
    test("a field set through the panel's writer, and a color through the Style row's binding, land on the note on its board") {
        try GalleryStage.with(dark: false, size: CGSize(width: 900, height: 620)) { stage in
            let (pill, note, board) = try stagedPill(stage)
            stage.editor.perform(.expandReference, on: [pill])
            stage.settlePills()
            stage.editor.selection = pill
            let here = stage.editor.board
            let writer = try require(stage.editor.fieldWriter)
            expect(writer.set(.number(130), at: FieldPath(field: "total"), of: note))
            let there = stage.editor.file[board][note]
            expectEqual(there?[FieldValuesProperty.self]?.value(at: FieldPath(field: "total")), .number(130))
            let color = try require(stage.editor.propertyBinding(note, ColorProperty.self))
            color.update { $0 = .red }
            expectEqual(stage.editor.file[board][note]?[ColorProperty.self], .red)
            expectEqual(stage.editor.board, here, "the board shown stays")
            stage.editor.undo()
            expectEqual(stage.editor.file[board][note]?[ColorProperty.self], .blue)
            expectEqual(stage.editor.board, here, "undone from where it was written")
        }
    },
])

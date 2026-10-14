import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Connections
import Foundation
import Geometry
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Types

// Return on a focused relation row, on the shipped list.

@MainActor let rowReturnTests = Suite("Return on a relation row", [
    test("Return on a focused relation row that holds a relationship opens its card; on an empty one the list") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        _ = try m.nameTheType()
        expect(try m.click(row: "layer", of: m.featureNote))
        expect(m.rowsView?.openList != nil, "an empty row: the list")
        m.window.pressReturn()
        expectEqual(m.rowsView?.focusedRow, "layer")
        expect(editor.fieldCards?.openTarget == nil, "no card yet")
        m.window.pressReturn()
        m.h.scheduler.advance(by: .zero)
        let open = editor.fieldCards?.openTarget
        expect(open != nil, "Return on a row that holds a relationship opens its card")
        if let open, case .relations = open.target {} else { expect(false, "a row's card") }
    },
])

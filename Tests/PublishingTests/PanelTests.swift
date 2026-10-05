import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import DetailPanel
import Publishing
import Selection
import SwiftUI
import TestKit

// Referenced In as the panel draws it, in an unshown window: a button for each stand-in, in file
// order, redrawn as what stands for the shape changes though the shape doesn't, a click going to it.
// The editor keeps the harness's time, so a click's going lands when a test advances it.

@MainActor
private final class ReferencedPanel {
    let h: EditorHarness
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
    let hosting: NSHostingView<DetailPanelView>

    init(_ h: EditorHarness) {
        self.h = h
        window.isReleasedWhenClosed = false
        hosting = NSHostingView(rootView: DetailPanelView(editor: h.editor, onExit: {}))
        hosting.frame = CGRect(x: 0, y: 0, width: DetailStyle.idealWidth, height: 600)
        window.contentView = hosting
        window.settle()
    }

    /// The rows, top first.
    var rows: [NSButton] {
        hosting.descendants(NSButton.self)
            .filter { $0.convert($0.bounds, to: hosting).minY >= 44 && $0.convert($0.bounds, to: hosting).height > 20 }
            .sorted { $0.convert($0.bounds, to: hosting).minY < $1.convert($1.bounds, to: hosting).minY }
    }
}

@MainActor let panelTests = Suite("Referenced In in the panel", [
    test("a row for each stand-in, which comes and goes with what stands for the shape, the shape itself unchanged") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        h.publish(plaque)
        let panel = ReferencedPanel(h)
        try require(h.editor.detailPanel).choose(.of(ReferencedInTab.self), for: Plaque.kind)
        h.editor.selection = plaque
        panel.window.settle()
        expectEqual(panel.rows.count, 0, "nothing stands for it: no tab, no rows")
        let first = h.hold([plaque])
        panel.window.spin { panel.rows.count == 1 }
        h.hold([plaque], at: CGRect(x: 600, y: 700, width: 60, height: 20))
        panel.window.spin { panel.rows.count == 2 }
        h.lens("what", answering: [plaque])
        panel.window.spin { panel.rows.count == 3 }
        h.editor.transact { $0.delete([first]) }
        panel.window.spin { panel.rows.count == 2 }
        h.provide(try require(h.editor.document.shapes.first { $0.kind == "lens" }?.id), "what", [], revision: 2)
        panel.window.spin { panel.rows.count == 1 }
    },
    test("a click on a row goes to its stand-in: selected, one step back") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        h.publish(plaque)
        let holder = h.hold([plaque])
        let panel = ReferencedPanel(h)
        try require(h.editor.detailPanel).choose(.of(ReferencedInTab.self), for: Plaque.kind)
        h.editor.selection = plaque
        panel.window.spin { panel.rows.count == 1 }
        panel.rows[0].performClick(nil)
        h.wait(1)
        expectEqual(h.editor.selectedShapeIDs, [holder])
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [plaque])
    },
    test("a refused chip click leaves the panel on Referenced In, showing the row") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame))
        h.publish(plaque)
        h.hold([plaque])
        let panel = ReferencedPanel(h)
        h.editor.selection = plaque
        panel.window.settle()
        expectEqual(panel.rows.count, 0, "the plaque's own tab first")
        h.click(at: try h.chipPoint(of: plaque))
        panel.window.spin { panel.rows.count == 1 }
    },
])

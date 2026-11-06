import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import DetailPanel
import Neighbors
import Publishing
import Selection
import SwiftUI
import TestKit

// A refused Make Private as the panel draws it, in an unshown window: the panel showing the held shape
// alone goes to Connections, which lists what's connected to the shape (Neighbors' tab, where what
// stands for it is among what points to it); one that isn't refused leaves it where it was. The list
// asks to be told which shape it lists once it is on screen, so that is how a test sees it shown. The
// editor keeps the harness's time, so a click lands when a test advances it.

@MainActor
private final class HostedPanel {
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

    /// The shape whose connections are on screen, if any.
    var listed: ShapeID? { h.editor.neighborList?.subject }
}

@MainActor let panelTests = Suite("The panel on a refused Make Private", [
    test("a refused click on the open eye leaves the panel on Connections, which lists the shape") {
        let h = try publishingHarness([NeighborDetailsPlugin()])
        let plaque = h.add(Plaque(plaqueFrame))
        h.conceal(plaque)
        let panel = HostedPanel(h)
        h.editor.selection = plaque
        panel.window.settle()
        h.click(at: try h.chipPoint(of: plaque))                                         // public, the pointer on the open eye
        h.hold([plaque])
        h.editor.selection = plaque
        panel.window.settle()
        expectEqual(panel.listed, nil, "the plaque's own tab first: no list on screen")
        h.click(at: try h.chipPoint(of: plaque))
        panel.window.spin { panel.listed == plaque }
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], nil, "and it stays public")
    },
    test("a click that makes the shape public, or private again, leaves the panel where it was") {
        let h = try publishingHarness([NeighborDetailsPlugin()])
        let plaque = h.add(Plaque(plaqueFrame))
        h.conceal(plaque)
        let panel = HostedPanel(h)
        h.editor.selection = plaque
        panel.window.settle()
        h.click(at: try h.chipPoint(of: plaque))
        panel.window.settle()
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], nil, "public")
        h.click(at: try h.chipPoint(of: plaque))
        panel.window.settle()
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], true, "private again: nothing held it")
        expectEqual(panel.listed, nil, "no list on screen")
    },
])

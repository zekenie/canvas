import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import DetailPanel
import Mentions
import Publishing
import References
import Selection
import SwiftUI
import TestKit
import Titles

// The reference's panel: a header that names what it stands for (its symbol secondary, as every
// header's is), with a line under it; for a reference that names a shape, one plain Go to Original
// button, working while the reference is locked and dimmed while there's nothing to go to. Layouts
// headless, then the panel in an unshown window.

@MainActor private func layout(_ h: EditorHarness, _ id: ShapeID) throws -> DetailLayout {
    try require(h.editor.detailPanel).layout(for: try require(h.editor.document[id]))
}

@MainActor private func header(_ h: EditorHarness, _ id: ShapeID) throws -> ReferenceHeaderContent {
    try require(try layout(h, id).header(as: ReferenceHeader.self)).content
}

@MainActor private final class ReferencePanel {
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

    /// The buttons under the header, top first.
    var buttons: [NSButton] {
        hosting.descendants(NSButton.self)
            .filter { $0.convert($0.bounds, to: hosting).minY >= 44 }
            .sorted { $0.convert($0.bounds, to: hosting).minY < $1.convert($1.bounds, to: hosting).minY }
    }
}

@MainActor let panelTests = Suite("The reference's panel", [
    test("the header names what it stands for, and a line under it: the kind and the board, or why it stands for nothing") {
        let h = try referenceHarness()
        let box = h.addBox("shapes")
        let live = h.addReference(to: box, label: "shapes")
        let kind = try require(h.state(of: live)?.appearance).kindName
        expectEqual(try header(h, live), ReferenceHeaderContent(symbol: "shippingbox", title: "shapes", subtitle: kind))
        let gone = h.addReference(to: ShapeID(), label: "Old roadmap", at: CGPoint(x: 400, y: 400))
        expectEqual(try header(h, gone), ReferenceHeaderContent(symbol: "square.dashed", title: "Old roadmap", subtitle: "Deleted"))
        let nowhere = ShapeID()
        let hidden = ShapeRecord(Box(boxFrame))
        let other = try referenceHarness(file: CanvasFile(root: CanvasDocument(), children: [nowhere: CanvasDocument(shapes: [AnyShapeRecord(hidden)])]))
        let away = other.addReference(to: hidden.id, label: "Out of sight")
        expectEqual(try header(other, away), ReferenceHeaderContent(symbol: "square.dashed", title: "Out of sight", subtitle: "Not available"))
        h.editor.transact { $0.update(box) { $0[PublicProperty.self] = nil } }
        expectEqual(try header(h, live), ReferenceHeaderContent(symbol: "shippingbox", title: "shapes", subtitle: "Not public"))
        let words = h.addReference(words: "blocked work", at: CGPoint(x: 400, y: 500))
        expectEqual(try header(h, words), ReferenceHeaderContent(symbol: "magnifyingglass", title: "blocked work", subtitle: nil))
        let query = h.addReference(words: "", query: "box", at: CGPoint(x: 400, y: 600))
        expectEqual(try header(h, query).title, "box", "an agent's, called by its query")
        expectEqual(try header(h, h.addEmptyReference(at: CGPoint(x: 400, y: 700))), ReferenceHeaderContent(symbol: "arrow.turn.up.right", title: "Reference", subtitle: nil))
    },
    test("the header's board is named when what it stands for is on another") {
        let h = try referenceHarness([PocketsPlugin(), pocketTitles])
        var pocket = ShapeRecord(Pocket(CGRect(x: 600, y: 100, width: 100, height: 100)))
        pocket[TitleProperty.self] = "Drawer"
        h.editor.transact { $0.insert(pocket) }
        expect(h.enter(pocket.id))
        let box = h.addBox("inside")
        expect(h.editor.showBoard(.root))
        let id = h.addReference(to: box, label: "inside")
        let kind = try require(h.state(of: id)?.appearance).kindName
        expectEqual(try header(h, id).subtitle, kind + " · Drawer")
    },
    test("a rename shows in the header as it happens: laid out again, it says the new name") {
        let h = try referenceHarness()
        let box = h.addBox("shapes")
        let id = h.addReference(to: box, label: "shapes")
        h.editor.transact { $0.update(box) { $0[TitleProperty.self] = "things" } }
        expectEqual(try header(h, id).title, "things")
    },
    test("one tab, with Go to Original, for a reference that names a shape; a reference of words has its Query section; an empty one only its header") {
        let h = try referenceHarness()
        let id = h.addReference(to: h.addBox("shapes"), label: "shapes")
        let layoutOfDirect = try layout(h, id)
        expectEqual(layoutOfDirect.tabs.map(\.title), ["Reference"], "one tab, so no strip")
        expectEqual(layoutOfDirect.sections(in: try require(layoutOfDirect.tabs.first)).count, 1)
        let words = try layout(h, h.addReference(words: "stuff", at: CGPoint(x: 400, y: 500)))
        expectEqual(words.tabs.map(\.title), ["Reference"])
        expectEqual(words.sections(in: try require(words.tabs.first)).map(\.section), ["reference.query"], "the Query section, and no matches")
        let empty = try layout(h, h.addEmptyReference(at: CGPoint(x: 400, y: 600)))
        expectEqual(empty.tabs.count, 0)
    },
    test("in the window: a plain Go to Original under the header; it goes, dimmed when the shape is gone, and works on a locked reference") {
        let h = try referenceHarness([FreezingPlugin()])
        let box = h.addBox("shapes", at: CGRect(x: 100, y: 100, width: 150, height: 100))
        let id = h.addReference(to: box, label: "shapes")
        let panel = ReferencePanel(h)
        h.editor.selectedShapeIDs = [id]
        panel.window.spin { panel.buttons.count == 1 }
        expect(panel.buttons[0].isEnabled, "something to go to")
        h.editor.freeze([id])
        panel.window.settle()
        expect(panel.buttons.first?.isEnabled == true, "it changes nothing, so a lock doesn't stand in the way")
        panel.buttons[0].performClick(nil)
        h.wait(1)
        expectEqual(h.editor.selectedShapeIDs, [box])
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [id])
        h.editor.transact { $0.delete([box]) }
        panel.window.spin { panel.buttons.first?.isEnabled == false }
    },
])

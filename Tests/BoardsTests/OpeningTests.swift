import AppKit
import Boards
import Canvas
import CanvasTesting
import ContextMenus
import DetailPanel
import Keyboard
import Selection
import SwiftUI
import TestKit

/// The panel alone in an unshown window, for its Open button.
@MainActor
final class BoardPanelWindow {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: DetailStyle.idealWidth, height: 600), styleMask: [.titled],
                          backing: .buffered, defer: false)
    let hosting: NSHostingView<DetailPanelView>

    init(_ editor: CanvasEditor) {
        hosting = NSHostingView(rootView: DetailPanelView(editor: editor))
        window.contentView = hosting
    }

    /// Buttons below the header's 44 points (its back button is up there).
    var buttons: [NSButton] {
        hosting.descendants(NSButton.self).filter { !($0 is NSPopUpButton) && $0.convert($0.bounds, to: hosting).minY >= 44 }
    }
}

@MainActor let openingTests = Suite("Opening a board", [
    test("a drawer opens onto its board with a double-click, Return and ⌘↓, from its kind's one line") {
        let nest = Nest()
        let h = try nestHarness(nest)
        h.click(at: nest.dPoint)
        h.click(at: nest.dPoint, clickCount: 2)
        expectEqual(h.editor.board, nest.dBoard, "double-click")
        expectEqual(h.editor.selectedShapeIDs, [], "nothing selected on arrival")

        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selection, nest.d)
        expect(h.key("\r"))
        expectEqual(h.editor.board, nest.dBoard, "Return")

        h.editor.goBack()
        h.hold(.command)
        expect(h.key(String(KeyChord.downArrow.key)))
        h.hold([])
        expectEqual(h.editor.board, nest.dBoard, "⌘↓")
    },
    test("a pocket opens onto its board from the bridge form") {
        let nest = Nest()
        let h = try nestHarness(nest)
        expect(h.enter(nest.d))
        h.editor.selection = nest.p
        expect(h.editor.canOpen(nest.p))
        expect(h.key("\r"))
        expectEqual(h.editor.board, nest.pBoard)
        expectEqual(h.editor.boardPath, [.root, nest.dBoard, nest.pBoard])
    },
    test("Open comes first in the menu of a shape that owns a board, and opens it") {
        let nest = Nest()
        let h = try nestHarness(nest)
        let menu = try require(h.secondaryClick(at: nest.dPoint))
        expectEqual(menu.outline.first, "Open")
        expectEqual(h.editor.selection, nest.d, "the right-click selected it")
        try menu.choose("Open")
        expectEqual(h.editor.board, nest.dBoard)

        expect(h.enter(nest.p))
        expect(h.secondaryClick(at: CGPoint(x: 50, y: 50))?.outline.contains("Open") != true, "a box's menu has none")
    },
    test("with several shapes that own boards selected, Open opens the first of them") {
        let nest = Nest()
        let other = ShapeID()
        var file = nest.file
        file = CanvasFile(root: CanvasDocument(shapes: file.root.shapes + [record(other, Drawer(CGRect(x: 400, y: 0, width: 100, height: 100)))]),
                          children: file.children)
        let h = try EditorHarness(plugins: boardsPlugins(), file: file)
        h.editor.selectedShapeIDs = [other, nest.d]
        let menu = try require(h.secondaryClick(at: nest.dPoint))
        try menu.choose("Open")
        expectEqual(h.editor.board, BoardID(owner: other))
    },
    test("the panel has a Board tab for it, whose Open button opens the board") {
        let nest = Nest()
        let editor = try CanvasEditor(registry: Registry(plugins: boardsPlugins()), file: nest.file, scheduler: TaskScheduler())
        let drawer = try require(editor.document[nest.d])
        let layout = try require(editor.detailPanel?.layout(for: drawer))
        expectEqual(layout.tabs.map(\.title), ["Board", "Arrange"])
        expectEqual(layout.sections(in: .of(BoardTab.self)).map(\.section), ["main"])

        editor.selection = nest.d
        let panel = BoardPanelWindow(editor)
        try require(editor.detailPanel).choose(.of(BoardTab.self), for: Drawer.kind)
        panel.window.spin { !panel.buttons.isEmpty }
        let open = try require(panel.buttons.first)
        expect(open.isEnabled)
        open.performClick(nil)
        expectEqual(editor.board, nest.dBoard)
    },
    test("only a kind that owns boards may open one: a bridge naming another refuses the plugin list") {
        expectThrows(RegistryError.invalid(point: "BoardKinds", reason: "box-boards opens the boards of box, whose definition isn't BoardOwning")) {
            _ = try Registry(plugins: boardsPlugins([Contributor(id: "box-boards") { r in
                r.opensBoard(Box.self, placeholder: "Box", systemImage: "square")
            }]))
        }
    },
    test("two plugins opening one kind's boards conflict, and the report names each kind") {
        let registry = try Registry(plugins: boardsPlugins())
        let line = try require(registry.report.split(separator: "\n").first { $0.hasPrefix("drawers") })
        expect(line.contains("board → drawer \"Untitled Drawer\""), "\(line)")
        do {
            _ = try Registry(plugins: boardsPlugins([Contributor(id: "twice") { r in
                r.opensBoard(Drawer.self, placeholder: "Again", systemImage: "square")
            }]))
            expect(false, "a second opener for drawers")
        } catch RegistryError.conflict(let point, _, let plugins) {
            expectEqual(point, "BoardKinds")
            expectEqual(plugins, ["drawers", "twice"])
        }
    },
])

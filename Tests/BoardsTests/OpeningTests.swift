import AppKit
import Boards
import Canvas
import CanvasTesting
import DetailPanel
import Keyboard
import Selection
import SwiftUI
import TestKit

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
    test("a pocket opens onto its board from the form for another plugin's kind, with Return and its menu's Open") {
        let nest = Nest()
        let h = try nestHarness(nest)
        expect(h.enter(nest.d))
        h.editor.selection = nest.p
        expect(h.editor.canOpen(nest.p))
        expect(h.key("\r"))
        expectEqual(h.editor.board, nest.pBoard)
        expectEqual(h.editor.boardPath, [.root, nest.dBoard, nest.pBoard])

        h.editor.goBack()
        expectEqual(h.editor.board, nest.dBoard)
        let menu = try require(h.secondaryClick(at: nest.pPoint))
        expectEqual(menu.outline.first, "Open")
        try menu.choose("Open")
        expectEqual(h.editor.board, nest.pBoard)
    },
    test("Open comes first in the menu of a shape that owns a board, shows ⌘↓ and opens it, whatever was selected before") {
        let nest = Nest()
        let h = try nestHarness(nest)
        h.editor.selection = nest.a
        let menu = try require(h.secondaryClick(at: nest.dPoint))
        expectEqual(menu.outline.first, "Open", "asked of the drawer, not of the box selected before")
        let open = try require(menu.items.first)
        expectEqual(open.keyEquivalent, String(KeyChord.downArrow.key), "Open Selection's key, ⌘↓")
        expectEqual(h.editor.selection, nest.d, "the right-click selected it")
        try menu.choose("Open")
        expectEqual(h.editor.board, nest.dBoard)

        expect(h.enter(nest.p))
        expect(h.secondaryClick(at: CGPoint(x: 50, y: 50))?.outline.contains("Open") != true, "a box's menu has none")
    },
    test("Open does what ⌘↓ does: nothing for several shapes that own boards, and into a group of them selected whole") {
        let nest = Nest(), groups = GroupsFixture()
        let h = try nestHarness(nest, [Contributor(id: "fixed-groups") { $0.selectionGroups { _ in groups } }])
        groups.editor = h.editor
        let other = h.add(Drawer(CGRect(x: 400, y: 0, width: 100, height: 100)))
        h.editor.selectedShapeIDs = [other, nest.d]
        let several = try require(h.secondaryClick(at: nest.dPoint))
        expect(!several.outline.contains("Open"), "\(several.outline)")
        expectEqual(h.editor.selectedShapeIDs, [other, nest.d], "the menu is the selection's")
        expect(!h.editor.canPerform(.openSelection))

        groups.paths = [nest.d: ["g"], other: ["g"]]
        h.editor.selectedShapeIDs = []
        let group = try require(h.secondaryClick(at: nest.dPoint))
        expectEqual(h.editor.selectedShapeIDs, [nest.d, other], "the right-click selected the group, whole")
        expectEqual(group.outline.first, "Open")
        try group.choose("Open")
        expectEqual(h.editor.board, .root, "not a board: the group is gone into, as ⌘↓ goes")
        expectEqual(h.editor.selectedShapeIDs, [nest.d], "its first part, in reading order")
    },
    test("its panel has no tab for it: opening a board is the canvas's, the menu's and the keys'") {
        let nest = Nest()
        let editor = try CanvasEditor(registry: Registry(plugins: boardsPlugins()), file: nest.file, scheduler: TaskScheduler())
        let drawer = try require(editor.document[nest.d])
        let layout = try require(editor.detailPanel?.layout(for: drawer))
        expectEqual(layout.tabs.map(\.title), [])
    },
    test("only a kind that owns boards may open one: a plugin naming another refuses the plugin list") {
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

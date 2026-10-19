import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Grouping
import LanguageModels
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import TestKit

// Groups in the app as it ships: Arrange › Group and Ungroup from the menu bar, their keys routed past
// Edit › Find Next's ⌘G, dimmed while text has the keyboard; and the shapes' menus.

@MainActor let groupingShippedTests = Suite("Groups, shipped", [
    test("Arrange › Group (⌥⌘G) and Ungroup (⌥⇧⌘G) run on the selection from the menu bar, not Find Next, and are off while a note is edited") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: w.editor.registry)
        let arrange = try require(menus.main.item(withTitle: "Arrange")?.submenu)
        for item in arrange.items { item.target = w.controller }
        let group = try require(arrange.item(withTitle: "Group")), ungroup = try require(arrange.item(withTitle: "Ungroup"))
        let (a, b) = w.nest.notes(on: 1)
        w.window.makeFirstResponder(w.canvas)
        w.editor.selectedShapeIDs = [a]
        expect(!w.controller.validateMenuItem(group), "one note: nothing to group")
        w.editor.selectedShapeIDs = [a, b]
        expect(w.controller.validateMenuItem(group) && !w.controller.validateMenuItem(ungroup))
        expect(menus.main.performKeyEquivalent(with: w.window.keyEvent("©", ignoringModifiers: "g", code: 5, modifiers: [.command, .option])))
        expectEqual(w.editor.undoHistory.undoName, "Group")
        expectEqual(w.editor.selectionUnit(of: a), [a, b])
        expect(w.controller.validateMenuItem(ungroup) && !w.controller.validateMenuItem(group))
        expect(menus.main.performKeyEquivalent(with: w.window.keyEvent("©", ignoringModifiers: "G", code: 5, modifiers: [.command, .option, .shift])))
        expectEqual(w.editor.undoHistory.undoName, "Ungroup")
        expectEqual(w.editor.selectionUnit(of: a), [a])
        // A note being edited: the keys are the text's.
        w.editor.selectedShapeIDs = [a, b]
        expect(w.editor.beginEditing(a))
        w.window.spin { w.window.firstResponder is NSTextView }
        expect(!w.controller.validateMenuItem(group), "off while text has the keyboard")
    },
    test("two notes' menu offers Group, before Lock; a right-click on one of them grouped selects both, and offers Ungroup") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: ScriptedLanguageModel()) }
        let a = h.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "One"))
        let b = h.add(StickyNote(frame: CGRect(x: 300, y: 0, width: 200, height: 200), text: "Two"))
        h.editor.selectedShapeIDs = [a, b]
        let menu = try require(h.secondaryClick(at: CGPoint(x: 100, y: 100))).outline
        let group = try require(menu.firstIndex(of: "Group"), "\(menu)")
        expect(group < (menu.firstIndex(of: "Lock") ?? -1), "Group before Lock: \(menu)")
        expect(!menu.contains("Ungroup"))
        try require(h.secondaryClick(at: CGPoint(x: 100, y: 100))).choose("Group")
        h.click(at: CGPoint(x: 250, y: 400))
        let grouped = try require(h.secondaryClick(at: CGPoint(x: 400, y: 100))).outline
        expectEqual(h.editor.selectedShapeIDs, [a, b])
        expect(grouped.contains("Ungroup") && !grouped.contains("Group"), "\(grouped)")
    },
])

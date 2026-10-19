import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import CoreGraphics
import Find
import Frames
import Keyboard
import Locking
import Mentions
import Selection
import StickyNotes
import TestKit
import TextEditing

// The Shape menu as the app ships it: the selection's context menu in the menu bar, less what the menu bar
// has, with the keys the shape commands got (⇧L, ⇧⌘F and the four Arrange keys) on the canvas and through
// the menu bar, which leaves a key that types to the text.

/// What the window's controller would do with Edit › Find's items, in its place: the commands they ran.
@MainActor private final class FindProbe: NSObject {
    var fired: [CanvasCommand] = []
    @objc func runCommand(_ sender: Any?) {
        if let item = sender as? NSMenuItem, let command = BoardMenus.command(of: item) { fired.append(command) }
    }
}

/// The app's menus for a window's editor, with the Shape menu as it fills now.
@MainActor private func shapeMenu(of menus: BoardMenus.Menus) throws -> NSMenu {
    let shape = try require(menus.main.item(withTitle: "Shape")?.submenu)
    shape.delegate?.menuNeedsUpdate?(shape)
    return shape
}

/// What Window › Show Next Tab would do, in its place.
@MainActor private final class TabProbe: NSObject {
    var fired = 0
    @objc func selectNextTab(_ sender: Any?) { fired += 1 }
}

/// The window that has the keyboard, as the menu asks.
@MainActor private final class KeyWindow {
    var editor: CanvasEditor
    init(_ editor: CanvasEditor) { self.editor = editor }
}

@MainActor let shapeMenuShippedTests = Suite("Shape menu and shape keys, shipped", [
    test("the Shape menu sits between Edit and Arrange and holds nothing: not at rest, and not with nothing selected") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: w.editor.registry, editor: { w.editor })
        expectEqual(menus.main.items.map(\.title), ["Infinite Canvas", "File", "Edit", "Shape", "Arrange", "View", "Go", "Window", "Help"])
        let shape = try require(menus.main.item(withTitle: "Shape")?.submenu)
        expect(shape.items.isEmpty && !shape.autoenablesItems)
        w.editor.selection = nil
        expect(try shapeMenu(of: menus).items.isEmpty, "nothing selected")
        let (a, _) = w.nest.notes(on: 1)
        w.editor.selection = a
        expect(try !shapeMenu(of: menus).items.isEmpty)
        shape.delegate?.menuDidClose?(shape)
        w.window.spin(until: { shape.items.isEmpty })
    },
    test("a note's Shape menu is its context menu less what the menu bar has: Cut, Copy, Paste, Duplicate, Delete and Group are not in it; Create Frame and Lock are, with their keys") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: w.editor.registry, editor: { w.editor })
        let (a, b) = w.nest.notes(on: 1)
        w.editor.selection = a
        let shape = try shapeMenu(of: menus)
        let titles = shape.outline
        for left in ["Cut", "Copy", "Paste", "Duplicate", "Delete", "Select All", "Group", "Ungroup", "Arrange ▸", "Bring to Front"] {
            expect(!titles.contains(left), "\(left) is the menu bar's: \(titles)")
        }
        expect(titles.contains("Create Frame") && titles.contains("Lock"), "\(titles)")
        expectEqual(try require(shape.item(withTitle: "Create Frame")).keyEquivalent, "f")
        expectEqual(KeyboardShortcutSection.key(of: try require(shape.item(withTitle: "Create Frame"))), "⇧⌘F")
        expectEqual(KeyboardShortcutSection.key(of: try require(shape.item(withTitle: "Lock"))), "⇧L")
        // Two notes: Group is the menu bar's, and Create Frame and Lock are for both.
        w.editor.selectedShapeIDs = [a, b]
        let both = try shapeMenu(of: menus).outline
        expect(!both.contains("Group") && both.contains("Create Frame") && both.contains("Lock"), "\(both)")
    },
    test("a frame's Shape menu has what a frame has: Turn into Subboard; an item chosen runs on the selection of the window it was made for") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: w.editor.registry, editor: { w.editor })
        let frame = w.editor.add(Frame(frame: CGRect(x: 800, y: 80, width: 300, height: 200)))
        w.editor.selection = frame
        let shape = try shapeMenu(of: menus)
        expect(shape.outline.contains("Turn into Subboard") && shape.outline.contains("Lock"), "\(shape.outline)")
        try shape.choose("Lock")
        expect(w.editor.isLocked(frame))
        expect(try shapeMenu(of: menus).outline.contains("Unlock"), "made afresh each time it opens")
    },
    test("a subboard's Shape menu has no Open: its right-click's Open runs Go › Open Selection's command, which the menu bar has") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: w.editor.registry, editor: { w.editor })
        w.editor.selection = w.nest.s
        let titles = try shapeMenu(of: menus).outline
        expect(!titles.contains("Open") && titles.contains("Lock"), "\(titles)")
        expect(try require(w.editor.menuForSelection(omitting: [])).outline.contains("Open"), "the selection's own menu has it")
    },
    test("an item reaches the editor of the window it's for: two windows, each its own selection") {
        let one = try NestedWindow()
        let two = try NestedWindow()
        defer { one.board.close(); two.board.close() }
        let current = KeyWindow(one.editor)
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: one.editor.registry, editor: { current.editor })
        let (a, _) = one.nest.notes(on: 1)
        one.editor.selection = a
        two.editor.selection = a
        current.editor = two.editor
        try shapeMenu(of: menus).choose("Lock")
        expect(two.editor.isLocked(a) && !one.editor.isLocked(a), "the second window's")
        current.editor = one.editor
        try shapeMenu(of: menus).choose("Lock")
        expect(one.editor.isLocked(a))
    },
    test("an item dims as its command does: while a note is edited, Create Frame and Lock can't run, and the menu is still the selection's") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: w.editor.registry, editor: { w.editor })
        let (a, _) = w.nest.notes(on: 1)
        w.editor.selection = a
        expect(try shapeMenu(of: menus).outline.contains("Lock"))
        expect(w.editor.beginEditing(a))
        let editing = try shapeMenu(of: menus).outline
        expect(editing.contains("(Lock)") && editing.contains("(Create Frame)"), "\(editing)")
    },
    test("⇧L and ⇧⌘F on the canvas lock the note and frame it; a key stroke takes each as a command, and both are the menu's items too") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let (a, _) = w.nest.notes(on: 1)
        w.window.makeFirstResponder(w.canvas)
        w.editor.selection = a
        w.window.press("L", code: 37, modifiers: .shift)
        expect(w.editor.isLocked(a))
        expectEqual(w.editor.undoHistory.undoName, "Lock")
        w.window.press("L", code: 37, modifiers: .shift)
        expect(!w.editor.isLocked(a))
        expectEqual(w.editor.undoHistory.undoName, "Unlock")
        expect(w.canvas.performKeyEquivalent(with: w.window.keyEvent("F", ignoringModifiers: "f", code: 3, modifiers: [.command, .shift])), "taken before the menus")
        let frame = try require(w.editor.selection)
        expect(frame != a && w.editor.document[frame]?.kind == Frame.kind)
        expectEqual(w.editor.holder(of: a), frame)
        expectEqual(w.editor.undoHistory.undoName, "Create Frame")
    },
    test("`]`, ⌥], ⌥[ and `[` on the canvas restack the selection: Keyboard's keys for the same commands, one step each, and the key goes on with nothing selected") {
        let w = try NestedWindow()
        defer { w.board.close() }
        @MainActor func note(_ x: CGFloat) -> ShapeID { w.editor.add(StickyNote(frame: CGRect(x: x, y: 1000, width: 200, height: 200), text: "")) }
        let (x, y, z) = (note(0), note(100), note(150))
        let mine: Set<ShapeID> = [x, y, z]
        @MainActor func order() -> [ShapeID] { w.editor.document.shapes.map(\.id).filter(mine.contains) }
        w.window.makeFirstResponder(w.canvas)
        w.editor.selection = y
        w.window.press("]", code: 30)
        expectEqual(order(), [x, z, y])
        expectEqual(w.editor.undoHistory.undoName, "Bring to Front")
        w.window.sendEvent(w.window.keyEvent("“", ignoringModifiers: "[", code: 33, modifiers: .option))
        expectEqual(order(), [x, y, z])
        expectEqual(w.editor.undoHistory.undoName, "Send Backward")
        w.window.press("[", code: 33)
        expectEqual(order(), [y, x, z])
        expectEqual(w.editor.undoHistory.undoName, "Send to Back")
        w.window.sendEvent(w.window.keyEvent("‘", ignoringModifiers: "]", code: 30, modifiers: .option))
        expectEqual(order(), [x, y, z])
        expectEqual(w.editor.undoHistory.undoName, "Bring Forward")
        w.editor.selection = nil
        w.window.press("]", code: 30)
        expectEqual(order(), [x, y, z], "nothing selected: nothing moved")
    },
    test("Arrange › Bring to Front, Bring Forward, Send Backward and Send to Back (`]`, ⌥], ⌥[, `[`) through the menu bar: after Group and Ungroup, run on the selection, off while text has the keyboard") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: w.editor.registry, editor: { w.editor })
        let arrange = try require(menus.main.item(withTitle: "Arrange")?.submenu)
        for item in arrange.items { item.target = w.controller }
        expectEqual(arrange.items.map(\.title), ["Group", "Ungroup", "", "Bring to Front", "Bring Forward", "Send Backward", "Send to Back"])
        expectEqual(arrange.items.compactMap { KeyboardShortcutSection.key(of: $0) }, ["⌥⌘G", "⌥⇧⌘G", "]", "⌥]", "⌥[", "["])
        // Three notes, the last two across the middle one: their order is what moves.
        @MainActor func note(_ x: CGFloat) -> ShapeID { w.editor.add(StickyNote(frame: CGRect(x: x, y: 1000, width: 200, height: 200), text: "")) }
        let (x, y, z) = (note(0), note(100), note(150))
        let mine: Set<ShapeID> = [x, y, z]
        @MainActor func order() -> [ShapeID] { w.editor.document.shapes.map(\.id).filter(mine.contains) }
        w.window.makeFirstResponder(w.canvas)
        w.editor.selection = y
        // `]` is Bring to Front; ⌥] types a quote, so its characters are one, its key the other.
        expect(menus.main.performKeyEquivalent(with: w.window.keyEvent("]", code: 30)))
        expectEqual(order(), [x, z, y])
        expectEqual(w.editor.undoHistory.undoName, "Bring to Front")
        expect(menus.main.performKeyEquivalent(with: w.window.keyEvent("“", ignoringModifiers: "[", code: 33, modifiers: .option)))
        expectEqual(order(), [x, y, z])
        expectEqual(w.editor.undoHistory.undoName, "Send Backward")
        expect(menus.main.performKeyEquivalent(with: w.window.keyEvent("[", code: 33)))
        expectEqual(order(), [y, x, z])
        expectEqual(w.editor.undoHistory.undoName, "Send to Back")
        expect(menus.main.performKeyEquivalent(with: w.window.keyEvent("‘", ignoringModifiers: "]", code: 30, modifiers: .option)))
        expectEqual(order(), [x, y, z], "forward past the shape across it")
        expectEqual(w.editor.undoHistory.undoName, "Bring Forward")
        // Held, the key's repeats run it no more, as its shortcut doesn't repeat: taken, and nothing moves.
        let repeated = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: w.window.windowNumber,
                                        context: nil, characters: "]", charactersIgnoringModifiers: "]", isARepeat: true, keyCode: 30)!
        expect(menus.main.performKeyEquivalent(with: repeated))
        expectEqual(order(), [x, y, z], "a repeat restacks nothing")
        expectEqual(w.editor.undoHistory.undoName, "Bring Forward")
        // Nothing selected: each is dimmed, and its key goes on.
        w.editor.selection = nil
        let bring = try require(arrange.item(withTitle: "Bring to Front"))
        expect(!w.controller.validateMenuItem(bring))
        expect(!menus.main.performKeyEquivalent(with: w.window.keyEvent("]", code: 30)), "dimmed: the key goes on")
        // A note being edited: the keys are the text's, and the items are off.
        w.editor.selection = y
        expect(w.editor.beginEditing(y))
        w.window.spin { w.window.firstResponder is EditingTextView }
        for item in arrange.items.suffix(4) { expect(!w.controller.validateMenuItem(item), "\(item.title) is the text's while it has the keyboard") }
        expect(!menus.main.performKeyEquivalent(with: w.window.keyEvent("]", code: 30)))
        expect(!menus.main.performKeyEquivalent(with: w.window.keyEvent("[", code: 33)))
        expect(!menus.main.performKeyEquivalent(with: w.window.keyEvent("‘", ignoringModifiers: "]", code: 30, modifiers: .option)), "⌥] types a quote")
        expect(!menus.main.performKeyEquivalent(with: w.window.keyEvent("“", ignoringModifiers: "[", code: 33, modifiers: .option)))
        expectEqual(order(), [x, y, z], "nothing moved")
        // A key held with ⌃ types nothing: it goes on to AppKit's menus, text or not (Window's ⌃⇥ next tab).
        let probe = TabProbe()
        let next = NSMenuItem(title: "Show Next Tab", action: #selector(TabProbe.selectNextTab(_:)), keyEquivalent: "\t")
        next.keyEquivalentModifierMask = .control
        next.target = probe
        try require(menus.main.item(withTitle: "Window")?.submenu).addItem(next)
        expect(menus.main.performKeyEquivalent(with: w.window.keyEvent("\t", code: 48, modifiers: .control)))
        expectEqual(probe.fired, 1, "⌃⇥ in text reaches its item")
    },
    test("typing L, ], [ and a quote in a note being edited types them: no shape is locked or restacked, and the menu bar leaves the keys") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: w.editor.registry, editor: { w.editor })
        let arrange = try require(menus.main.item(withTitle: "Arrange")?.submenu)
        for item in arrange.items { item.target = w.controller }
        let (a, b) = w.nest.notes(on: 1)
        w.editor.selection = a
        expect(w.editor.beginEditing(a))
        w.window.spin { w.window.firstResponder is EditingTextView }
        let text = try require(w.window.firstResponder as? EditingTextView)
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        let shifted = w.window.keyEvent("L", code: 37, modifiers: .shift)
        expect(!menus.main.performKeyEquivalent(with: shifted), "⇧L is the text's")
        w.window.press("L", code: 37, modifiers: .shift)
        w.window.press("]", code: 30)
        w.window.press("[", code: 33)
        w.window.press("‘", code: 30, modifiers: .option)
        expect(text.string.hasSuffix("L][‘"), text.string)
        expect(!w.editor.isLocked(a), "typing L locked nothing")
        expectEqual(Array(w.editor.document.shapes.map(\.id).prefix(2)), [a, b], "and restacked nothing")
    },
    test("⇧⌘F is not Find's ⌘F: the menu bar leaves it, and ⌘F is still Find's") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: w.editor.registry, editor: { w.editor })
        let probe = FindProbe()
        let find = try require(try require(menus.main.item(withTitle: "Edit")?.submenu).item(withTitle: "Find")?.submenu)
        for item in find.items { item.target = probe }
        expect(!menus.main.performKeyEquivalent(with: w.window.keyEvent("F", ignoringModifiers: "f", code: 3, modifiers: [.command, .shift])))
        expectEqual(probe.fired, [], "Find didn't open")
        expect(menus.main.performKeyEquivalent(with: w.window.keyEvent("f", code: 3, modifiers: .command)))
        expectEqual(probe.fired, [.find])
        expect(menus.main.performKeyEquivalent(with: w.window.keyEvent("G", ignoringModifiers: "g", code: 5, modifiers: [.command, .shift])), "⇧⌘G is still Find Previous")
        expectEqual(probe.fired, [.find, .findPrevious])
    },
])

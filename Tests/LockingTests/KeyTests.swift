import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import Keyboard
import Locking
import Selection
import TestKit

// ⇧L: one key for two commands, Lock and Unlock, never both possible, which the context menu's items,
// `/lock` and the chip run too.

@MainActor let lockKeyTests = Suite("Locking from the keyboard", [
    test("⌥Tab reaches a locked shape's chip, named Locked, and Return unlocks it; the open lock that fades is no part, so the focus is the shape's again") {
        let h = try lockingHarness()
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        h.editor.lock([box])
        h.editor.selection = box
        expect(h.key(Chord.optionTab))
        expectEqual(h.editor.focusedPart?.title, "Locked")
        expect(h.key(Chord.return))
        expect(!h.editor.isLocked(box))
        expectEqual(h.editor.undoHistory.undoName, "Unlock")
        expect(!h.editor.adornmentFrames(of: box).isEmpty, "the lock shows open")
        expect(!h.editor.hasFocusedPart)
        expectEqual(h.editor.selectedShapeIDs, [box])
        expect(h.key(Chord.optionTab))
        expect(!h.editor.hasFocusedPart, "no part to go to")
    },
    test("⇧L locks the selection, then unlocks it once every shape is locked; with one locked it locks the rest; each is one step, named as the menu's") {
        let h = try lockingHarness()
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 300, y: 100, width: 100, height: 100)))
        h.editor.selectedShapeIDs = [a, b]
        h.hold(.shift)
        expect(h.key("L"))
        expect(h.editor.isLocked(a) && h.editor.isLocked(b))
        expectEqual(h.editor.undoHistory.undoName, "Lock")
        expect(h.key("L"))
        expect(!h.editor.isLocked(a) && !h.editor.isLocked(b))
        expectEqual(h.editor.undoHistory.undoName, "Unlock")
        h.editor.lock([a])
        expect(h.key("L"))
        expect(h.editor.isLocked(a) && h.editor.isLocked(b), "one locked, one not: lock the rest")
        h.editor.undo()
        expect(h.editor.isLocked(a) && !h.editor.isLocked(b), "one step")
    },
    test("nothing selected, nothing to lock, or a shape mid-edit: the key goes on, as a command's do while it can't run") {
        let h = try lockingHarness()
        let card = h.add(Card(CGRect(x: 100, y: 100, width: 100, height: 100), text: "a"))
        h.hold(.shift)
        h.editor.selection = nil
        expect(!h.key("L"), "nothing selected")
        expect(!h.editor.canPerform(.lock) && !h.editor.canPerform(.unlock))
        h.editor.selection = card
        h.editor.beginEditing(card)
        expect(!h.editor.canPerform(.lock), "while its text is edited")
        expect(!h.key("L"))
        expect(!h.editor.isLocked(card))
    },
    test("a shape in a locked frame is locked with it and its lock can't change: ⇧L leaves it, and does nothing if that's all there is") {
        let h = try lockingHarness([CorralsPlugin()])
        let corral = h.add(Corral(CGRect(x: 100, y: 100, width: 400, height: 300)))
        let inside = h.add(Box(CGRect(x: 150, y: 150, width: 100, height: 100)))
        h.editor.put([inside], in: corral)
        let outside = h.add(Box(CGRect(x: 600, y: 150, width: 100, height: 100)))
        h.editor.lock([corral])
        h.hold(.shift)
        h.editor.selection = inside
        expect(!h.key("L"), "only a shape it can't lock")
        h.editor.selectedShapeIDs = [inside, outside]
        expect(h.key("L"))
        expect(h.editor.isLocked(outside) && !h.editor.isLocked(inside))
    },
    test("the menu's Lock and Unlock are the commands': their titles, and ⇧L, the key that runs whichever can") {
        let h = try lockingHarness()
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        let menu = try require(h.secondaryClick(at: CGPoint(x: 150, y: 150)))
        let lock = try require(menu.item(withTitle: "Lock"))
        expectEqual(lock.keyEquivalent, "l")
        expectEqual(lock.keyEquivalentModifierMask, .shift)
        try menu.choose("Lock")
        expect(h.editor.isLocked(box))
        let unlock = try require(try require(h.secondaryClick(at: CGPoint(x: 150, y: 150))).item(withTitle: "Unlock"))
        expectEqual(unlock.keyEquivalent, "l")
        expectEqual(h.editor.registry.title(of: .lock), "Lock")
        expectEqual(h.editor.registry.title(of: .unlock), "Unlock")
        expectEqual(h.editor.registry.shortcut(forCommand: .lock)?.chord, KeyChord("l", .shift))
        expectEqual(h.editor.registry.shortcut(forCommand: .unlock)?.chord, KeyChord("l", .shift))
        expectEqual(h.editor.registry.keyboardHelpRows.first { $0.keys == ["⇧L"] }?.title, "Lock or Unlock")
    },
    test("Lock and Unlock act on the shapes they're given, by one rule each: Lock while some can be locked and aren't, Unlock once every one is") {
        let h = try lockingHarness()
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 300, y: 100, width: 100, height: 100)))
        expect(h.editor.canPerform(.lock, on: [a, b]) && !h.editor.canPerform(.unlock, on: [a, b]))
        expect(h.editor.perform(.lock, on: [a]))
        expect(h.editor.isLocked(a) && !h.editor.isLocked(b))
        expectEqual(h.editor.undoHistory.undoName, "Lock")
        expect(h.editor.canPerform(.lock, on: [a, b]), "a mix: Lock, which locks the rest")
        expect(!h.editor.canPerform(.unlock, on: [a, b]))
        expect(h.editor.canPerform(.unlock, on: [a]) && !h.editor.canPerform(.lock, on: [a]))
        expect(h.editor.perform(.unlock, on: [a]))
        expect(!h.editor.isLocked(a))
        expectEqual(h.editor.undoHistory.undoName, "Unlock")
        expect(!h.editor.canPerform(.lock, on: []) && !h.editor.canPerform(.unlock, on: []), "no shapes, neither")
    },
    test("the selection's menu has them too, dimmed where the command can't run, and leaves out what the menu bar runs") {
        let h = try lockingHarness()
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        h.editor.selection = box
        expectEqual(try require(h.editor.menuForSelection(omitting: [.delete, .showContextMenu])).outline, ["Lock"])
        expect(h.editor.menuForSelection(omitting: [.lock, .delete, .showContextMenu]) == nil, "Lock runs the command: nothing left")
        try require(h.editor.menuForSelection(omitting: [.delete, .showContextMenu])).choose("Lock")
        expect(h.editor.isLocked(box))
        expectEqual(try require(h.editor.menuForSelection(omitting: [.delete, .showContextMenu])).outline, ["Unlock"])
    },
])

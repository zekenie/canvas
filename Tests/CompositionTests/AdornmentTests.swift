import Adornments
import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import LanguageModels
import Locking
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import TableOfContents
import TestKit
import Titles

// What's shown on a shipped note (its title's pill, its lock) is laid out by
// Adornments, and pointing at any of it is pointing at the note: a press, a drag, a double-click, a
// right-click and a hover. The lock alone is also a button.

/// A board of the shipped plugins with a note on it, 200 points square at (100, 100), titled, its
/// clipboard on a pasteboard of the test's own. At 100% the pill is at the row above the note, from
/// (100, 73), 18 tall.
@MainActor private func titledNote(_ pasteboard: NSPasteboard, title: String = "Groceries") -> (EditorHarness, ShapeID) {
    let h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: ScriptedLanguageModel()) }
    let note = h.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Buy milk"))
    h.editor.transact { $0.update(note) { $0[TitleProperty.self] = title } }
    return (h, note)
}

extension CanvasEditor {
    /// Where one of a shape's adornments is, in world units.
    fileprivate func rect<A: Adornment>(of _: A.Type, on id: ShapeID) throws -> CGRect {
        try require(adornmentFrames(of: id).first { $0.adornment == .of(A.self) }, "no \(A.self) on \(id)").rect
    }
}

/// On the pill, near its left end.
private let onPill = CGPoint(x: 112, y: 82)

@MainActor let adornmentTests = Suite("Adornments, as shipped", [
    test("a locked, titled note: the lock at the row's right end, the pill up to 4 points short of it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (h, note) = titledNote(pasteboard, title: "A title much longer than the note is wide")
        h.editor.lock([note])
        expectEqual(try h.editor.rect(of: LockChip.self, on: note), CGRect(x: 282, y: 73, width: 18, height: 18))
        expectEqual(try h.editor.rect(of: TitlePill.self, on: note), CGRect(x: 100, y: 73, width: 178, height: 18))
        h.editor.unlock([note])
        h.wait(2_000)                                                               // the open lock fades
        expectEqual(try h.editor.rect(of: TitlePill.self, on: note), CGRect(x: 100, y: 73, width: 200, height: 18), "unlocked, to the right edge")
    },
    test("a locked arrow's lock is above its label's words, or centred above the middle of an unlabelled one") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: ScriptedLanguageModel()) }
        let said = h.add(Arrow(start: .free(CGPoint(x: 100, y: 300)), end: .free(CGPoint(x: 500, y: 300)), text: "calls"))
        let silent = h.add(Arrow(start: .free(CGPoint(x: 100, y: 500)), end: .free(CGPoint(x: 500, y: 500))))
        h.editor.lock([said, silent])
        let label = try require(h.editor.shapeContext.geometry(of: said)?.label, "an arrow with words has a label")
        let lock = try h.editor.rect(of: LockChip.self, on: said)
        expectEqual(lock.minY, label.minY - 27, "the row, above the words and not above the arrow's bounds")
        expectEqual(lock.maxX, max(label.maxX, label.midX + 60), "at the right end of the label, widened to 120 about its middle")
        expectEqual(try h.editor.rect(of: LockChip.self, on: silent), CGRect(x: 291, y: 473, width: 18, height: 18), "above its middle (300, 500), centred on it: 300 - 18 / 2")
    },
    test("a click on a note's pill selects the note, and a drag from it moves the note; a locked note's shakes instead") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (h, note) = titledNote(pasteboard)
        expect(try h.editor.rect(of: TitlePill.self, on: note).contains(onPill))
        h.click(at: onPill)
        expectEqual(h.editor.selectedShapeIDs, [note])
        h.editor.selection = nil
        h.press(at: onPill)
        h.drag(to: onPill + CGPoint(x: 40, y: 30))
        h.release()
        expectEqual(h.editor.document[note]?.box?.origin, CGPoint(x: 140, y: 130))
        expectEqual(h.editor.selectedShapeIDs, [note])

        h.editor.lock([note])
        let before = try require(h.editor.document[note])
        let pill = try h.editor.rect(of: TitlePill.self, on: note)
        let onLockedPill = CGPoint(x: pill.minX + 12, y: pill.midY)
        h.press(at: onLockedPill)
        h.drag(to: onLockedPill + CGPoint(x: 40, y: 30))
        h.wait(16)
        expectEqual(h.editor.document[note], before)
        expect(h.editor.drawingOffset(of: note) != .zero, "it shakes")
        h.release()
    },
    test("a double-click on a note's pill edits the note, and places no note there") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (h, note) = titledNote(pasteboard)
        h.click(at: onPill)
        h.press(at: onPill, clickCount: 2)
        h.release()
        expectEqual(h.editor.editingShapeID, note)
        expectEqual(h.editor.document.shapes.map(\.id), [note])
    },
    test("a right-click on a locked note's pill, or on its lock, opens the note's menu, which offers Unlock") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (h, note) = titledNote(pasteboard)
        let unlocked = try require(h.secondaryClick(at: onPill))
        expect(unlocked.outline.contains("Lock"), "\(unlocked.outline)")
        expectEqual(h.editor.selectedShapeIDs, [note])
        h.editor.lock([note])
        h.editor.selection = nil
        let onPillMenu = try require(h.secondaryClick(at: onPill))
        expect(onPillMenu.outline.contains("Unlock"), "\(onPillMenu.outline)")
        expectEqual(h.editor.selectedShapeIDs, [note])
        h.editor.selection = nil
        let lock = try h.editor.rect(of: LockChip.self, on: note)
        let onLockMenu = try require(h.secondaryClick(at: CGPoint(x: lock.midX, y: lock.midY)))
        expect(onLockMenu.outline.contains("Unlock"), "\(onLockMenu.outline)")
        expectEqual(h.editor.selectedShapeIDs, [note])
    },
    test("the pointer on a note's pill hovers the note and tints its row; on its lock, the lock is hovered, a button") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (h, note) = titledNote(pasteboard)
        let contents = try require(h.editor.tableOfContents)
        h.move(to: onPill)
        expectEqual(h.editor.hovered, note)
        expect(contents.isHovered(note), "its row")
        h.move(to: CGPoint(x: 112, y: 40))
        expectEqual(h.editor.hovered, nil)
        expect(!contents.isHovered(note))
        h.editor.lock([note])
        let lock = try h.editor.rect(of: LockChip.self, on: note)
        h.move(to: CGPoint(x: lock.midX, y: lock.midY))
        expectEqual(h.editor.hoveredButton, AnyHashable(AdornmentButton(LockChip.self, on: note)))
        expectEqual(h.editor.hovered, nil)
        expectEqual(h.editor.cursor, .pointingHand)
    },
])

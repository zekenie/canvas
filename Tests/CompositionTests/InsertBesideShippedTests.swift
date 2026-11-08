import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Foundation
import Frames
import Geometry
import LanguageModels
import Mentions
import Selection
import ShippedTesting
import Engineering
import StickyNotes
import Subboards
import TestKit

// ⇧↩ on the shipped list (the core's Insert › New (kind) Beside, Keyboard's key, StickyNotes' claim of the Note tool): a
// shape of the selection's kind beside it, whichever kind it is, and a note when nothing is selected, an arrow is, or the
// kinds are mixed; the item says what it makes; an off kit's kind gets a note.

@MainActor private func harness(_ pasteboard: NSPasteboard) -> EditorHarness {
    let h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: ScriptedLanguageModel()) }
    h.editor.viewportDidResize(to: CGSize(width: 1600, height: 1000))
    return h
}

@MainActor private func kinds(_ editor: CanvasEditor) -> [ShapeKind] { editor.document.shapes.map(\.kind) }

@MainActor let insertBesideShippedTests = Suite("⇧↩ beside, as shipped", [
    test("beside a subboard, a subboard; beside a frame, a frame; beside a note, a note: each in one step named for it, the new shape selected") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = harness(pasteboard)
        let editor = h.editor
        let subboard = ShapeRecord(Subboard(frame: CGRect(x: 100, y: 100, width: 240, height: 160)))
        let frame = ShapeRecord(Frame(frame: CGRect(x: 100, y: 500, width: 400, height: 300)))
        editor.transact { $0.insert(subboard); $0.insert(frame) }
        editor.selectedShapeIDs = [subboard.id]
        expectEqual(editor.menuTitle(of: .insertBeside), "New Subboard Beside")
        let delivery = h.key(Chord(.return, .shift))
        expect(delivery, "⇧↩ is heard")
        expectEqual(kinds(editor), [Subboard.kind, Frame.kind, Subboard.kind])
        expectEqual(editor.undoHistory.undoName, "Add Subboard")
        expectEqual(editor.selectedShapeIDs, [try require(editor.document.shapes.last).id], "the new one is selected")
        editor.undo()
        editor.selectedShapeIDs = [frame.id]
        expectEqual(editor.menuTitle(of: .insertBeside), "New Frame Beside")
        expect(h.key(Chord(.return, .shift)))
        expectEqual(kinds(editor), [Subboard.kind, Frame.kind, Frame.kind])
        expectEqual(editor.undoHistory.undoName, "Add Frame")
    },
    test("⇧↩ beside a shape at the view's edge brings the new shape into view, as every other key that moves the focus does") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = harness(pasteboard)
        let editor = h.editor
        // At the right edge of a 1600-wide view: the new shape goes beside it, outside the view.
        let frame = ShapeRecord(Frame(frame: CGRect(x: 1250, y: 300, width: 300, height: 300)))
        editor.transact { $0.insert(frame) }
        editor.selectedShapeIDs = [frame.id]
        let view = editor.camera.toWorld(editor.unobscuredViewport)
        expect(view.contains(CGRect(x: 1250, y: 300, width: 300, height: 300)), "the frame is in view")
        expect(h.key(Chord(.return, .shift)))
        let made = try require(editor.document.shapes.last)
        let bounds = try require(made.box)
        expect(!view.contains(bounds), "the new frame lands past the view's edge: \(bounds) \(view)")
        expect(editor.cameraTarget.toWorld(editor.unobscuredViewport).contains(bounds), "and the camera is headed to show it")
    },
    test("nothing selected, mixed kinds, or a kind no tool places: a note; an off kit's kind too, a table beside a table with the kit on") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = harness(pasteboard)
        let editor = h.editor
        expectEqual(editor.menuTitle(of: .insertBeside), "New Note", "with nothing to be beside")
        expect(h.key(Chord(.return, .shift)))
        expectEqual(kinds(editor), [StickyNote.kind])
        editor.endEditing(discarding: false)
        let note = try require(editor.document.shapes.first).id
        let subboard = ShapeRecord(Subboard(frame: CGRect(x: 100, y: 500, width: 240, height: 160)))
        let table = ShapeRecord(DatabaseTable(frame: CGRect(x: 500, y: 500, width: 260, height: 44), columns: DatabaseTable.starter().columns))
        editor.transact { $0.insert(subboard); $0.insert(table) }
        editor.selectedShapeIDs = [note, subboard.id]
        expectEqual(editor.menuTitle(of: .insertBeside), "New Note Beside", "mixed kinds")
        editor.selectedShapeIDs = [table.id]
        expectEqual(editor.menuTitle(of: .insertBeside), "New Note Beside", "Engineering is off in this file")
        expect(h.key(Chord(.return, .shift)))
        expectEqual(editor.document.shapes.last?.kind, StickyNote.kind)
        editor.endEditing(discarding: false)
        editor.turn(EngineeringKit.self, on: true)
        editor.selectedShapeIDs = [table.id]
        expectEqual(editor.menuTitle(of: .insertBeside), "New Table Beside")
        expect(h.key(Chord(.return, .shift)))
        expectEqual(editor.document.shapes.last?.kind, DatabaseTable.kind)
        expectEqual(editor.editingShapeID, editor.document.shapes.last?.id, "its name typed at once")
    },
    test("inside a note's words ⇧↩ still puts a note beside it, edited, as before") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = harness(pasteboard)
        let editor = h.editor
        let note = ShapeRecord(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "one"))
        editor.transact { $0.insert(note) }
        editor.selectedShapeIDs = [note.id]
        editor.beginEditing(note.id)
        expect(!editor.canPerform(.insertBeside), "dimmed while a shape is edited: the note's editor has the key")
        expect(editor.insert(ToolID(placing: StickyNote.kind), beside: [note.id]), "what the editor's ⇧↩ does")
        expectEqual(kinds(editor), [StickyNote.kind, StickyNote.kind])
    },
])

import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Frames
import LanguageModels
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import Subboards
import TestKit

// Moving as shipped: `/move-to` and `/move-near` typed in a note's editor in the app's canvas view, the shape
// they take picked with `@`: Mentions' picker lists what the command's rule admits (for `/move-to`, the
// frames and subboards Titles names), Return picks it, and a second Return runs the line.

/// The note typed in, Milk (a note to put it beside), frame Groceries, subboard Plans, and a frame and a
/// subboard with no title, which the picker can't name: the camera at the origin at 100%, so view points
/// are world units.
@MainActor private struct Errands {
    let editor: CanvasEditor
    let window: NSWindow
    let note: ShapeID, milk: ShapeID, groceries: ShapeID, plans: ShapeID

    init(_ pasteboard: NSPasteboard) {
        editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        (window, _) = windowed(editor)
        note = editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "keep"))
        milk = editor.add(StickyNote(frame: CGRect(x: 100, y: 1000, width: 200, height: 200), text: "Milk"))
        groceries = editor.add(Frame(frame: CGRect(x: 600, y: 100, width: 600, height: 500)), title: "Groceries")
        plans = editor.add(Subboard(frame: CGRect(x: 1400, y: 100, width: 240, height: 160)), title: "Plans")
        editor.add(Frame(frame: CGRect(x: 600, y: 1400, width: 400, height: 300)))
        editor.add(Subboard(frame: CGRect(x: 1400, y: 400, width: 240, height: 160)))
    }

    /// Edits the note, the caret on a new line after its text, and types `line` there.
    func type(_ line: String) throws -> MentionTextView<AnyMentionable> { try edit(note, in: editor, window: window, typing: line) }

    func frame(_ id: ShapeID) -> CGRect? { editor.file.record(id)?.box }
    func text() -> String? { editor.file.record(note)?.typed(as: StickyNote.self)?.props.text.plainText() }
}

/// Edits `note`, the caret on a new line after its text, and types `line` there.
@MainActor private func edit(_ note: ShapeID, in editor: CanvasEditor, window: NSWindow, typing line: String) throws -> MentionTextView<AnyMentionable> {
    editor.selection = note
    expect(editor.beginEditing(note))
    let view = try require(window.firstResponder as? MentionTextView<AnyMentionable>, "the note's editor has the keyboard")
    view.setSelectedRange(NSRange(location: view.textStorage?.length ?? 0, length: 0))
    window.pressReturn()
    window.type(line)
    return view
}

@MainActor let movingShippedTests = Suite("Moving, as shipped", [
    test("/move-to @ lists only the titled frames and subboards, nearest first; one picked with Return, a second Return puts the note in the frame, its line gone, and Undo Move takes it back") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let e = Errands(pasteboard)
        let view = try e.type("/move-to @")
        let picker = try require(view.picker, "the picker is open")
        expectEqual(picker.rows.compactMap(\.candidate?.id), [e.groceries, e.plans], "no note, and no frame or subboard without a name")
        e.window.type("gro")
        expectEqual(view.picker?.highlightedCandidate?.id, e.groceries)
        e.window.pressReturn()
        expect(view.picker == nil, "a pick closes it")
        expectEqual(e.frame(e.note)?.origin, CGPoint(x: 100, y: 100), "picked, not run")
        e.window.pressReturn()
        e.window.settle()

        expectEqual(e.frame(e.note)?.origin, CGPoint(x: 640, y: 140), "40 in from the frame's top-left")
        expectEqual(e.editor.document.container(of: e.note, containingKinds: e.editor.registry.containingKinds), e.groceries)
        expectEqual(e.text(), "keep\n", "the line is gone from its text")
        expectEqual(e.editor.editingShapeID, nil, "put down where it went")
        expectEqual(e.editor.undoHistory.undoName, "Move")
        e.editor.undo()
        expectEqual(e.frame(e.note)?.origin, CGPoint(x: 100, y: 100), "Undo Move")
        expectEqual(e.editor.document.container(of: e.note, containingKinds: e.editor.registry.containingKinds), nil)
        expectEqual(e.editor.undoHistory.undoName, "Typing", "the step before it is the typing")
    },

    test("/move-near @Milk puts the note right of Milk, 80 away and centered on it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let e = Errands(pasteboard)
        let view = try e.type("/move-near @mil")
        expectEqual(view.picker?.highlightedCandidate?.id, e.milk)
        e.window.pressReturn()
        e.window.pressReturn()
        e.window.settle()
        let milk = try require(e.frame(e.milk)), note = try require(e.frame(e.note))
        expectEqual(note.origin, CGPoint(x: milk.maxX + 80, y: milk.midY - note.height / 2))
        expectEqual(e.editor.undoHistory.undoName, "Move")
    },

    test("/move-to @Plans moves the note onto the subboard's board, where the window doesn't go: it's gone from the root, editing ends, and Undo Move brings it back") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let e = Errands(pasteboard)
        let view = try e.type("/move-to @pla")
        expectEqual(view.picker?.highlightedCandidate?.id, e.plans)
        e.window.pressReturn()
        e.window.pressReturn()
        e.window.settle()
        expectEqual(e.editor.document[e.note], nil, "gone from the board shown")
        expectEqual(e.editor.file.board(containing: e.note), BoardID(owner: e.plans))
        expectEqual(e.editor.board, .root)
        expectEqual(e.editor.editingShapeID, nil)
        expectEqual(e.text(), "keep\n")
        expectEqual(e.editor.undoHistory.undoName, "Move")
        e.editor.undo()
        expectEqual(e.editor.file.board(containing: e.note), .root)
        expectEqual(e.frame(e.note)?.origin, CGPoint(x: 100, y: 100))
    },

    test("on a subboard's board, /move-to @ lists the subboard beside it on the root with nothing typed; picked and run, the note goes onto that one's board") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let (window, _) = windowed(editor)
        let bugs = editor.add(Subboard(frame: CGRect(x: 0, y: 0, width: 240, height: 160)), title: "Bugs")
        let polish = editor.add(Subboard(frame: CGRect(x: 400, y: 0, width: 240, height: 160)), title: "Polish")
        expect(editor.showBoard(BoardID(owner: bugs)))
        let note = editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "my-note"))
        let view = try edit(note, in: editor, window: window, typing: "/move-to @")
        let picker = try require(view.picker, "the picker is open")
        expectEqual(picker.rows.compactMap(\.candidate?.id), [polish], "Polish, on the root; not Bugs, whose board the note is on")
        window.pressReturn()
        window.pressReturn()
        window.settle()
        expectEqual(editor.file.board(containing: note), BoardID(owner: polish))
        expectEqual(editor.board, BoardID(owner: bugs), "the window stays on Bugs' board")
    },
])

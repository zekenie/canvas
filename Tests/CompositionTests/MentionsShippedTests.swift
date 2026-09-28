import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Clipboard
import Composition
import CoreGraphics
import Geometry
import LanguageModels
import Locking
import Mentions
import Selection
import StickyNotes
import SwiftUI
import TableOfContents
import TaskCards
import TestKit
import Titles

// Mentions as shipped: notes that mention tasks, copied, pasted, cut, renamed and deleted around,
// on the canvas, in the table of contents, and on the clipboard (a pasteboard of the test's own).

private let noteFrame = CGRect(x: 100, y: 100, width: 200, height: 200)
private let taskFrame = CGRect(x: 400, y: 100, width: 240, height: 200)

/// An empty board as shipped, its clipboard on `pasteboard`.
@MainActor private func emptyBoard(_ pasteboard: NSPasteboard, scheduler: (any Scheduler)? = nil) -> EditorHarness {
    if let scheduler {
        return EditorHarness { _ in
            ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: scheduler, pasteboard: pasteboard, model: ScriptedLanguageModel())
        }
    }
    return EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: ScriptedLanguageModel()) }
}

extension CanvasEditor {
    /// A task titled `title`, where `taskFrame` is, in a transaction of its own.
    fileprivate func addTask(_ title: String, at frame: CGRect = taskFrame) -> ShapeID {
        var task = ShapeRecord(TaskCard(frame: frame))
        task[TitleProperty.self] = title
        transact { $0.insert(task) }
        return task.id
    }

    /// A note saying "Ask ", a mention of `target` (named `label`), and " first".
    @discardableResult
    fileprivate func addNote(mentioning target: ShapeID, as label: String, at frame: CGRect = noteFrame) -> ShapeID {
        let note = ShapeRecord(StickyNote(frame: frame, text: MentionText([.text("Ask "), .mention(target, label: label), .text(" first")])))
        transact { $0.insert(note) }
        return note.id
    }

    fileprivate func noteText(_ id: ShapeID) -> MentionText? { document[id]?.typed(as: StickyNote.self)?.props.text }

    fileprivate func row(_ id: ShapeID) -> String? { tableOfContents?.entries.first { $0.id == id }?.label?.text }
}

@MainActor let mentionsShippedTests = Suite("Mentions, as shipped", [
    test("a note that mentions a task shows the task's title now in its row and on the canvas; deleted, the name it holds; undone, live again; redone, missing; a rename undone, the name before") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = emptyBoard(pasteboard)
        let task = h.editor.addTask("Ship it")
        let note = h.editor.addNote(mentioning: task, as: "Ship")
        let stored = try require(h.editor.noteText(note))
        expectEqual(h.editor.row(note), "Ask @Ship it first")
        let size = CGSize(width: 700, height: 400)
        let live = renderBitmap(h.editor, size: size)
        h.editor.transact { $0.update(task) { $0[TitleProperty.self] = "Launch the beta" } }
        expectEqual(h.editor.row(note), "Ask @Launch the beta first")
        let renamed = renderBitmap(h.editor, size: size)
        expect(changedPixels(live, renamed, in: noteFrame) > 50, "the pill shows the new title")
        h.editor.transact { $0.delete([task]) }
        expectEqual(h.editor.row(note), "Ask @Ship first", "the name the mention holds")
        expectEqual(h.editor.mentions?.resolve(task), .missing)
        let missing = renderBitmap(h.editor, size: size)
        expect(changedPixels(renamed, missing, in: noteFrame) > 50, "a missing pill, with the name it holds")
        h.editor.undo()
        expectEqual(h.editor.row(note), "Ask @Launch the beta first", "the deletion undone: live again")
        expectEqual(changedPixels(renamed, renderBitmap(h.editor, size: size), in: noteFrame), 0, "drawn as before it went")
        h.editor.redo()
        expectEqual(h.editor.row(note), "Ask @Ship first", "redone: missing again")
        expectEqual(changedPixels(missing, renderBitmap(h.editor, size: size), in: noteFrame), 0)
        h.editor.undo()
        h.editor.undo()
        expectEqual(h.editor.row(note), "Ask @Ship it first", "the rename undone: the title before it")
        expectEqual(changedPixels(live, renderBitmap(h.editor, size: size), in: noteFrame), 0)
        expectEqual(h.editor.noteText(note), stored, "nothing wrote to the note")
    },
    test("a note copied with the task it mentions mentions the task's copy; copied alone, the task it did") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = emptyBoard(pasteboard)
        let task = h.editor.addTask("Ship it")
        let note = h.editor.addNote(mentioning: task, as: "Ship it")
        h.editor.selectedShapeIDs = [note, task]
        h.editor.copySelection()
        var before = h.editor.document
        h.editor.paste()
        let both = h.editor.shapes(since: before)
        let noteCopy = try require(both.first { $0.kind == StickyNote.kind }?.id)
        let taskCopy = try require(both.first { $0.kind == TaskCard.kind }?.id)
        expectEqual(h.editor.noteText(noteCopy), MentionText([.text("Ask "), .mention(taskCopy, label: "Ship it"), .text(" first")]))
        expectEqual(h.editor.noteText(note)?.mentioned, [task], "the original's as it was")
        expectEqual(h.editor.mentions?.mentioners(of: taskCopy), [noteCopy])

        h.editor.selection = note
        h.editor.copySelection()
        before = h.editor.document
        h.editor.paste()
        let alone = try require(h.editor.shapes(since: before).first?.id)
        expectEqual(h.editor.noteText(alone), h.editor.noteText(note), "still the task it mentioned")
        expectEqual(Set(h.editor.mentions?.mentioners(of: task) ?? []), [note, alone])
    },
    test("pasted on another board, a note mentions a task that isn't there, which shows as missing, with the name it holds") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = emptyBoard(pasteboard)
        let task = h.editor.addTask("Ship it")
        let note = h.editor.addNote(mentioning: task, as: "Ship it")
        h.editor.selection = note
        h.editor.copySelection()
        let other = emptyBoard(pasteboard)
        other.editor.paste()
        let pasted = try require(other.editor.document.shapes.first?.id)
        expectEqual(other.editor.noteText(pasted)?.mentioned, [task])
        expectEqual(other.editor.mentions?.resolve(task), .missing)
        expectEqual(other.editor.row(pasted), "Ask @Ship it first")
    },
    test("a note cut with the task it mentions, and pasted, mentions the pasted task, live") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = emptyBoard(pasteboard)
        let task = h.editor.addTask("Ship it")
        let note = h.editor.addNote(mentioning: task, as: "Ship it")
        h.editor.selectedShapeIDs = [note, task]
        h.editor.cutSelection()
        expectEqual(h.editor.document.shapes.count, 0)
        h.editor.paste()
        let pasted = h.editor.document.shapes
        let noteCopy = try require(pasted.first { $0.kind == StickyNote.kind }?.id)
        let taskCopy = try require(pasted.first { $0.kind == TaskCard.kind }?.id)
        expectEqual(h.editor.noteText(noteCopy)?.mentioned, [taskCopy])
        expect(h.editor.mentions?.resolve(taskCopy).isLive == true)
        expectEqual(h.editor.row(noteCopy), "Ask @Ship it first")
    },
    test("renaming a task redraws its row and the rows of the notes that mention it, and no other") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = emptyBoard(pasteboard, scheduler: TaskScheduler())
        let task = h.editor.addTask("Ship it")
        let other = h.editor.addTask("Other", at: taskFrame.offsetBy(dx: 0, dy: 300))
        h.editor.addNote(mentioning: task, as: "Ship it")
        h.editor.addNote(mentioning: task, as: "Ship it", at: noteFrame.offsetBy(dx: 0, dy: 300))
        h.editor.addNote(mentioning: other, as: "Other", at: noteFrame.offsetBy(dx: 0, dy: 600))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: TableOfContentsView(editor: h.editor, onExit: {}))
        hosting.frame = CGRect(x: 0, y: 0, width: 300, height: 600)
        window.contentView = hosting
        let contents = try require(h.editor.tableOfContents)
        window.spin { (hosting.descendants(NSTableView.self).first?.numberOfRows ?? 0) == 6 }
        window.settle()
        let before = contents.rowsRedrawn
        h.editor.transact { $0.update(task) { $0[TitleProperty.self] = "Launch" } }
        window.spin { contents.rowsRedrawn > before }
        window.settle()
        expectEqual(contents.rowsRedrawn - before, 3, "the task's row and its two mentioners'")
        expectEqual(contents.entries.compactMap { $0.label?.text }, ["Launch", "Other", "Ask @Launch first", "Ask @Launch first", "Ask @Other first"])
    },
    test("in the app's canvas view, editing begun from a press on a pill puts the note's editor, with the keyboard, on that pill") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = emptyBoard(pasteboard)
        let task = h.editor.addTask("Ship it")
        let note = h.editor.addNote(mentioning: task, as: "Ship it")
        let (window, _) = windowed(h.editor)
        expect(h.editor.beginEditing(note))
        let plain = try require(window.firstResponder as? MentionTextView<AnyMentionable>)
        let caret = plain.selectedRange()
        let pill = try require(segment(of: NSRange(location: 4, length: 1), in: plain))
        h.editor.endEditing()
        expect(h.editor.beginEditing(note, at: CGPoint(x: noteFrame.minX + pill.midX, y: noteFrame.minY + pill.midY)))
        let editing = try require(window.firstResponder as? MentionTextView<AnyMentionable>)
        expect(editing !== plain, "a new editing view")
        expectEqual(editing.selectedRange(), NSRange(location: 4, length: 1), "the pill's character")
        h.editor.endEditing()
        expect(h.editor.beginEditing(note, at: CGPoint(x: noteFrame.minX + 30, y: noteFrame.maxY - 20)))
        expectEqual((window.firstResponder as? NSTextView)?.selectedRange(), caret, "below the text: where the caret always goes")
    },
    test("end to end in the app's canvas view: @ and a few letters pick a task; a rename shows in the editor, the row and the canvas; deleted, the pill is missing with its name; undone, live; a click on the pill edits the note from it, and a double-click goes to the task; locked, a click selects and a double-click goes; a pill copies and pastes; the text view's undo writes the note back") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let scheduler = ManualScheduler()
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: scheduler, pasteboard: pasteboard, model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        let size = CGSize(width: 800, height: 600)
        let task = editor.addTask("Launch checklist")
        let note = editor.add(StickyNote(frame: noteFrame, text: "See "))
        var time: TimeInterval = 1
        /// A click (or the press and release of a double-click's second click) on the canvas, at a world point.
        @MainActor func click(_ world: CGPoint, clicks: Int = 1) {
            time += 1
            let point = editor.camera.toView(world)
            canvas.mouseMoved(with: window.mouse(.mouseMoved, at: point, clicks: 0, time: time))
            canvas.mouseDown(with: window.mouse(.leftMouseDown, at: point, clicks: clicks, time: time + 0.1))
            canvas.mouseUp(with: window.mouse(.leftMouseUp, at: point, clicks: clicks, time: time + 0.15))
        }
        @MainActor func pillCenter() throws -> CGPoint {
            let frame = try require(editor.mentionPills(of: note).first?.frame, "the note's pill on the canvas")
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        @MainActor func textView() throws -> MentionTextView<AnyMentionable> {
            try require(window.firstResponder as? MentionTextView<AnyMentionable>, "the note's editor has the keyboard")
        }

        // Typing "@" and part of the task's title opens the picker, on the task; Return picks it.
        editor.selection = note
        expect(editor.beginEditing(note))
        var text = try textView()
        text.setSelectedRange(NSRange(location: 4, length: 0))
        window.type("@laun")
        let picker = try require(text.picker, "the picker is open")
        expectEqual(picker.query, "laun")
        expectEqual(picker.highlightedCandidate?.id, task)
        window.pressReturn()
        expect(text.picker == nil, "a pick closes it")
        let picked = MentionText([.text("See "), .mention(task, label: "Launch checklist"), .text(" ")])
        expectEqual(editor.noteText(note), picked)
        expect(editor.noteText(note)?.stored.contains("@[Launch checklist](shape:\(task.rawValue.uuidString))") == true, "the canonical token")

        // A rename shows in the editor's pill, with no transaction of its own, and in the note's row.
        let revision = editor.revision
        editor.transact { $0.update(task) { $0[TitleProperty.self] = "Ship the beta" } }
        expectEqual(editor.revision, revision + 1, "only the rename")
        expectEqual(text.mentionText, MentionText([.text("See "), .mention(task, label: "Ship the beta"), .text(" ")]), "the editor's pill")
        expectEqual(editor.noteText(note), picked, "the note isn't written")
        expectEqual(editor.row(note)?.trimmingCharacters(in: .whitespaces), "See @Ship the beta")
        // And on the canvas, once editing ends.
        window.pressEscape()
        expectEqual(editor.editingShapeID, nil)
        let shipped = renderBitmap(editor, size: size)
        editor.transact { $0.update(task) { $0[TitleProperty.self] = "Launch the beta to everyone" } }
        let renamed = renderBitmap(editor, size: size)
        expect(changedPixels(shipped, renamed, in: noteFrame) > 50, "the pill on the canvas shows the new title")
        expectEqual(editor.row(note)?.trimmingCharacters(in: .whitespaces), "See @Launch the beta to everyone")

        // Deleted, the pill shows the name the note holds, dashed, on the canvas and in the editor alike.
        editor.transact { $0.delete([task]) }
        expectEqual(editor.mentionPills(of: note).map(\.isLive), [false])
        expectEqual(editor.row(note)?.trimmingCharacters(in: .whitespaces), "See @Launch checklist")
        let missing = renderBitmap(editor, size: size)
        expect(changedPixels(renamed, missing, in: noteFrame) > 50, "a missing pill")
        expect(editor.beginEditing(note))
        text = try textView()
        let edited = renderBitmap(editor, size: size, editing: try require(editor.makeEditingView()))
        expect(largestDifference(missing, edited, in: noteFrame) <= 64, "the editor draws the missing pill where the canvas does")
        let shown = text.textStorage.flatMap { $0.attribute(.attachment, at: 4, effectiveRange: nil) as? MentionAttachment }
        expectEqual(shown?.resolution, .missing)
        expectEqual(shown?.shownLabel, "Launch checklist")
        window.pressEscape()
        expectEqual(editor.noteText(note), picked, "nothing wrote to the note")

        // The deletion undone, it's live again (the editing since changed nothing: no step).
        editor.undo()
        expectEqual(editor.mentionPills(of: note).map(\.isLive), [true])
        expectEqual(changedPixels(renamed, renderBitmap(editor, size: size), in: noteFrame), 0, "drawn as before it went")

        // A click on the pill of the unselected note selects it and edits it, the pill selected.
        editor.selectedShapeIDs = []
        click(try pillCenter())
        expectEqual(editor.selection, note)
        expectEqual(editor.editingShapeID, note)
        text = try textView()
        expectEqual(text.selectedRange(), NSRange(location: 4, length: 1), "the pill's character")
        // The double-click's second press lands in the text view: on the next turn, it goes to the task.
        let screen = text.firstRect(forCharacterRange: NSRange(location: 4, length: 1), actualRange: nil)
        let inCanvas = canvas.convert(window.convertFromScreen(screen), from: nil)
        let camera = editor.camera
        time += 0.2
        text.mouseDown(with: window.mouse(.leftMouseDown, at: CGPoint(x: inCanvas.midX, y: inCanvas.midY), clicks: 2, time: time))
        expectEqual(editor.editingShapeID, note, "not while the view is still handling the press")
        scheduler.advance(by: .milliseconds(1))
        expectEqual(editor.selection, task)
        expectEqual(editor.editingShapeID, nil)
        editor.goBack()
        expectEqual(editor.selection, note, "Back returns")
        expectEqual(editor.cameraTarget, camera, "and to where the camera was")
        scheduler.advance(by: .milliseconds(500))

        // Locked: a click on the pill selects the note, and neither edits nor shakes it; a double-click goes to the task.
        editor.lock([note])
        editor.selectedShapeIDs = []
        click(try pillCenter())
        expectEqual(editor.selection, note)
        expectEqual(editor.editingShapeID, nil, "a locked note isn't edited")
        scheduler.advance(by: .milliseconds(16))
        expectEqual(editor.drawingOffset(of: note), .zero, "a click isn't a try to change it")
        click(try pillCenter(), clicks: 2)
        expectEqual(editor.selection, task, "a double-click goes to the task")
        editor.goBack()
        expectEqual(editor.selection, note)
        scheduler.advance(by: .milliseconds(500))
        editor.unlock([note])

        // A pill copied and pasted in the text view is another mention of the task.
        expect(editor.beginEditing(note))
        text = try textView()
        text.setSelectedRange(NSRange(location: 4, length: 1))
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        expect(text.writeSelection(to: clipboard, types: text.writablePasteboardTypes))
        text.setSelectedRange(NSRange(location: text.textStorage?.length ?? 0, length: 0))
        expect(text.readSelection(from: clipboard))
        expectEqual(editor.noteText(note)?.mentioned, [task, task])
        expectEqual(editor.noteText(note)?.runs.filter { if case .mention = $0 { true } else { false } }.count, 2, "two pills of one task")

        // Undo in the text view, after a pick, writes the note back. Each step's events end with a
        // turn of the run loop, which closes the undo group they made.
        window.settle()
        let beforePick = try require(editor.noteText(note))
        window.type(" @launch")
        window.settle()
        window.pressReturn()
        window.settle()
        expectEqual(editor.noteText(note)?.runs.filter { if case .mention = $0 { true } else { false } }.count, 3)
        text.undoManager?.undo()
        expectEqual(editor.noteText(note), MentionText(beforePick.runs + [.text(" @launch")]), "the pick undone, the query as typed")
        expectEqual(editor.noteText(note), text.mentionText)
        window.pressEscape()
    },
    test("in the app's canvas view, a click or a double-click on a pill in the note's editor keeps its release from the canvas: the note isn't hovered, and the pointer isn't over the canvas") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let scheduler = ManualScheduler()
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: scheduler, pasteboard: pasteboard, model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        let task = editor.addTask("Launch")
        let note = editor.addNote(mentioning: task, as: "Launch")
        editor.selection = note
        expect(editor.beginEditing(note))
        let text = try require(window.firstResponder as? MentionTextView<AnyMentionable>)
        let screen = text.firstRect(forCharacterRange: NSRange(location: 4, length: 1), actualRange: nil)
        let inCanvas = canvas.convert(window.convertFromScreen(screen), from: nil)
        let pill = CGPoint(x: inCanvas.midX, y: inCanvas.midY)
        var time: TimeInterval = 1
        canvas.mouseMoved(with: window.mouse(.mouseMoved, at: pill, clicks: 0, time: time))
        text.mouseMoved(with: window.mouse(.mouseMoved, at: pill, clicks: 0, time: time))
        expect(editor.pointerOverCanvas == nil, "over the editing view")
        expectEqual(editor.hovered, task, "the pill hovers its task")
        for clicks in [1, 2] {
            time += 0.2
            text.mouseDown(with: window.mouse(.leftMouseDown, at: pill, clicks: clicks, time: time))
            text.mouseUp(with: window.mouse(.leftMouseUp, at: pill, clicks: clicks, time: time + 0.05))
            expectEqual(text.selectedRange(), NSRange(location: 4, length: 1))
            expect(editor.pointerOverCanvas == nil, "still not over the canvas, after \(clicks) click(s)")
            expectEqual(editor.hovered, task, "the note being edited isn't hovered, after \(clicks) click(s)")
        }
        scheduler.advance(by: .milliseconds(1))
        expectEqual(editor.selection, task, "the double-click went to the task")
    },
    test("in the app's canvas view, ⌘Z in a note's editor undoes only what this editing did: an earlier editing's steps go with its view") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let (window, _) = windowed(editor)
        let note = editor.add(StickyNote(frame: noteFrame, text: "See "))
        editor.selection = note
        expect(editor.beginEditing(note))
        var text = try require(window.firstResponder as? MentionTextView<AnyMentionable>)
        text.setSelectedRange(NSRange(location: 4, length: 0))
        window.type("abc")
        window.settle()
        expectEqual(editor.noteText(note), "See abc")
        window.pressEscape()
        expectEqual(editor.editingShapeID, nil)
        expect(editor.beginEditing(note))
        text = try require(window.firstResponder as? MentionTextView<AnyMentionable>)
        expect(text.undoManager?.canUndo == false, "nothing of the first editing's to undo")
        text.setSelectedRange(NSRange(location: 7, length: 0))
        window.type("X")
        window.settle()
        expectEqual(editor.noteText(note), "See abcX")
        text.undoManager?.undo()
        expectEqual(editor.noteText(note), "See abc", "this editing's step undone, and written back")
        expect(text.undoManager?.canUndo == false)
        window.pressEscape()
    },

    // Undo in a board's window: Edit › Undo is the text's while the note's editor has the keyboard,
    // and the board's anywhere else.

    test("in a board's window, a session begun by a click on a pill, with a pick, Remove Mention, a paste and typing, is one Typing step; in the text, Undo gives back the @query a pick took, and each undo or redo writes the note once") {
        let b = try mentionWindow()
        defer { b.board.close() }
        let (note, task) = (b.note, b.task)
        let before = b.board.editor.document
        let original = try require(b.board.editor.noteText(note))
        let pill = try require(b.board.editor.mentionPills(of: note).first)
        b.board.click(CGPoint(x: pill.frame.midX, y: pill.frame.midY))
        expectEqual(b.board.editor.editingShapeID, note, "a click on the pill edits the note")
        let text = try b.text()
        expectEqual(text.selectedRange(), NSRange(location: 4, length: 1), "from the pill")
        expect(text.undoManager === b.board.window.textUndo, "the window's text undo")
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        expect(text.writeSelection(to: clipboard, types: text.writablePasteboardTypes))
        text.setSelectedRange(NSRange(location: text.textStorage?.length ?? 0, length: 0))

        // A pick, undone in the text, gives back the @query as typed; redone, the pill. One write each.
        b.board.window.type(" @laun")
        b.board.window.settle()
        expectEqual(text.picker?.highlightedCandidate?.id, task)
        b.board.window.pressReturn()
        b.board.window.settle()
        let picked = try require(b.board.editor.noteText(note))
        expectEqual(picked.mentioned, [task, task])
        expect(!b.board.menuItem("undo:").hasPrefix("("), "the text's own undo")
        var revision = b.board.editor.revision
        b.board.window.undo(nil)
        expectEqual(b.board.editor.noteText(note), MentionText(original.runs + [.text(" @laun")]), "the query as typed")
        expectEqual(b.board.editor.noteText(note), text.mentionText)
        expectEqual(b.board.editor.revision, revision + 1, "one write")
        expect(text.picker == nil, "an undone pick opens nothing")
        expectEqual(b.board.editor.editingShapeID, note, "editing goes on")
        revision = b.board.editor.revision
        b.board.window.redo(nil)
        expectEqual(b.board.editor.noteText(note), picked)
        expectEqual(b.board.editor.revision, revision + 1, "one write")
        b.board.window.settle()

        // Remove Mention, a paste and typing, in the same session.
        try require(text.menu(for: b.mouse(.rightMouseDown, onCharacter: 4, of: text))).choose("Remove Mention")
        b.board.window.settle()
        text.setSelectedRange(NSRange(location: text.textStorage?.length ?? 0, length: 0))
        expect(text.readSelection(from: clipboard))
        b.board.window.settle()
        b.board.window.type("!")
        b.board.window.settle()
        let typed = try require(b.board.editor.noteText(note))
        expectEqual(typed.mentioned, [task, task], "the first pill made text, a pick and a paste")
        expect(typed.plainText().hasPrefix("Ask Launch checklist first"), "\(typed.plainText())")
        expect(typed.plainText().hasSuffix("!"))

        // Editing over, the text's undo is forgotten, and one Undo takes back the whole session.
        b.board.endEditing()
        expectEqual(b.board.editor.editingShapeID, nil)
        expect(!b.board.window.textUndo.canUndo, "forgotten once the text loses the keyboard")
        expectEqual(b.board.menuItem("undo:"), "Undo Typing", "the board's step")
        b.board.window.undo(nil)
        expectEqual(b.board.editor.document, before, "the board as it was before the click")
        expect(!b.board.editor.canUndo, "one step")
        b.board.window.redo(nil)
        expectEqual(b.board.editor.noteText(note), typed)
    },

    test("in a board's window, a note placed and typed into with a pick is one step with its placing, Add Note, which Undo takes back whole") {
        let b = try mentionWindow()
        defer { b.board.close() }
        let editor = b.board.editor
        let before = editor.document
        b.board.window.makeFirstResponder(b.board.canvas)
        b.board.window.press("n")
        b.board.click(CGPoint(x: 250, y: 500))
        let note = try require(editor.editingShapeID, "the note tool places a note to edit")
        b.board.window.type("Ask @laun")
        b.board.window.settle()
        expectEqual(try b.text().picker?.highlightedCandidate?.id, b.task)
        b.board.window.pressReturn()
        b.board.window.settle()
        b.board.endEditing()
        expectEqual(editor.editingShapeID, nil)
        let written = try require(editor.noteText(note))
        expectEqual(written.mentioned, [b.task])
        expectEqual(b.board.menuItem("undo:"), "Undo Add Note", "the editing joins the placing that began it")
        b.board.window.undo(nil)
        expectEqual(editor.document, before, "the note goes, with what was typed")
        expect(!editor.canUndo, "one step")
        b.board.window.redo(nil)
        expectEqual(editor.noteText(note), written)
    },

    test("in a board's window, Undo while the picker is open: in the text, the typed @query goes and the picker closes; the board's, which ends editing, closes it too, ends its hover, and lets the picker go") {
        let b = try mentionWindow()
        defer { b.board.close() }
        let (note, task) = (b.note, b.task)
        let original = try require(b.board.editor.noteText(note))
        b.board.editor.selection = note
        expect(b.board.editor.beginEditing(note))
        weak var weakPicker: MentionPicker?
        // In pools of their own, so what AppKit hands back autoreleased is let go of in the test.
        try autoreleasepool {
            let text = try b.text()
            text.setSelectedRange(NSRange(location: text.textStorage?.length ?? 0, length: 0))
            b.board.window.type(" @laun")
            expectEqual(text.picker?.highlightedCandidate?.id, task)
            expectEqual(b.board.editor.hovered, task, "the highlighted task is hovered")
            let revision = b.board.editor.revision
            b.board.window.undo(nil)
            expect(text.picker == nil, "the @ undone: the picker closes")
            expect(b.board.editor.hovered != task, "and its hover ends")
            expectEqual(b.board.editor.noteText(note), original)
            expectEqual(b.board.editor.revision, revision + 1, "one write")
            expectEqual(b.board.editor.editingShapeID, note)
            b.board.window.settle()

            b.board.window.type(" @laun")
            weakPicker = text.picker
            expect(weakPicker != nil)
            expectEqual(b.board.editor.hovered, task)
        }
        // The board's Undo (⌘Z where the canvas has the keyboard, or from any plugin) ends editing first.
        autoreleasepool { expect(b.board.editor.perform(.undo)) }
        expectEqual(b.board.editor.editingShapeID, nil)
        expectEqual(b.board.editor.noteText(note), original, "the session's typing undone")
        expect(b.board.editor.hovered != task, "the picker's hover ended")
        b.board.window.settle()
        expect(weakPicker == nil, "the picker is let go (NSTextView supports no weak reference, so the view itself can't be checked this way)")
        expect(b.board.window.childWindows?.isEmpty ?? true, "no picker window left")
    },

    test("in a board's window, Undo in the text that puts back a pill whose task went meanwhile shows it missing, and writes the note once") {
        let b = try mentionWindow()
        defer { b.board.close() }
        let (note, task) = (b.note, b.task)
        let editor = b.board.editor
        editor.selection = note
        expect(editor.beginEditing(note))
        let text = try b.text()
        try require(text.menu(for: b.mouse(.rightMouseDown, onCharacter: 4, of: text))).choose("Remove Mention")
        b.board.window.settle()
        expectEqual(editor.noteText(note), "Ask Launch checklist first")
        editor.transact { $0.delete([task]) }         // an agent's, say: the note's editor keeps the keyboard
        expectEqual(editor.editingShapeID, note)
        let revision = editor.revision
        b.board.window.undo(nil)
        let pill = text.textStorage.flatMap { $0.attribute(.attachment, at: 4, effectiveRange: nil) as? MentionAttachment }
        expectEqual(pill?.resolution, .missing, "the pill as its task is now")
        expectEqual(editor.noteText(note), MentionText([.text("Ask "), .mention(task, label: "Launch checklist"), .text(" first")]))
        expectEqual(editor.revision, revision + 1, "one write")
        expectEqual(editor.mentionPills(of: note).map(\.isLive), [false])
    },

    test("in a board's window, deleting a mentioned task and Undo makes its pills live again on the canvas, in the row and in the editor; Redo, missing; a rename undone gives back every pill's name") {
        let b = try mentionWindow()
        defer { b.board.close() }
        let (note, task) = (b.note, b.task)
        let editor = b.board.editor
        let size = CGSize(width: 700, height: 400)
        let live = renderBitmap(editor, size: size)
        editor.selection = task
        b.board.window.makeFirstResponder(b.board.canvas)
        expect(editor.perform(.delete))
        expectEqual(editor.row(note), "Ask @Launch checklist first")
        expectEqual(editor.mentionPills(of: note).map(\.isLive), [false])
        let missing = renderBitmap(editor, size: size)
        expect(changedPixels(live, missing, in: noteFrame) > 50)
        expectEqual(b.board.menuItem("undo:"), "Undo Delete")
        b.board.window.undo(nil)
        expectEqual(editor.mentionPills(of: note).map(\.isLive), [true])
        expectEqual(changedPixels(live, renderBitmap(editor, size: size), in: noteFrame), 0, "live again")
        expectEqual(editor.selection, task, "and selected, as it was")
        expect(editor.beginEditing(note))
        var shown = try b.text().textStorage.flatMap { $0.attribute(.attachment, at: 4, effectiveRange: nil) as? MentionAttachment }
        expect(shown?.resolution.isLive == true, "the editor's pill")
        b.board.endEditing()
        b.board.window.makeFirstResponder(b.board.canvas)
        b.board.window.redo(nil)
        expectEqual(editor.mentionPills(of: note).map(\.isLive), [false])
        expectEqual(changedPixels(missing, renderBitmap(editor, size: size), in: noteFrame), 0, "missing again")
        expect(editor.beginEditing(note))
        shown = try b.text().textStorage.flatMap { $0.attribute(.attachment, at: 4, effectiveRange: nil) as? MentionAttachment }
        expectEqual(shown?.resolution, .missing)
        b.board.endEditing()
        b.board.window.makeFirstResponder(b.board.canvas)
        b.board.window.undo(nil)

        // A rename, undone: every pill's name as it was (nothing selected, so every row is listed).
        editor.selectedShapeIDs = []
        let second = editor.addNote(mentioning: task, as: "Launch checklist", at: noteFrame.offsetBy(dx: 0, dy: 250))
        editor.transact("Rename") { $0.update(task) { $0[TitleProperty.self] = "Ship the beta" } }
        expectEqual([editor.row(note), editor.row(second)], ["Ask @Ship the beta first", "Ask @Ship the beta first"])
        b.board.window.undo(nil)
        expectEqual([editor.row(note), editor.row(second)], ["Ask @Launch checklist first", "Ask @Launch checklist first"])
        expectEqual(changedPixels(live, renderBitmap(editor, size: size), in: noteFrame), 0)
        b.board.window.redo(nil)
        expectEqual([editor.row(note), editor.row(second)], ["Ask @Ship the beta first", "Ask @Ship the beta first"])
    },

    test("in a board's window, a double-click on a pill in the text goes to the task, which is no step: Undo takes back the typing before it and selects the note, and Back returns to the task") {
        let b = try mentionWindow()
        defer { b.board.close() }
        let (note, task) = (b.note, b.task)
        let editor = b.board.editor
        let original = try require(editor.noteText(note))
        editor.selection = note
        expect(editor.beginEditing(note))
        let text = try b.text()
        text.setSelectedRange(NSRange(location: 0, length: 0))
        b.board.window.type("So: ")
        b.board.window.settle()
        text.mouseDown(with: b.mouse(.leftMouseDown, onCharacter: 8, of: text, clicks: 2))
        b.board.window.spin { editor.selection == task }
        expectEqual(editor.editingShapeID, nil)
        expectEqual(b.board.menuItem("undo:"), "Undo Typing")
        b.board.window.undo(nil)
        expectEqual(editor.noteText(note), original)
        expectEqual(editor.selection, note, "selected as when the typing began")
        expect(editor.canGoBack)
        editor.goBack()
        expectEqual(editor.selection, task, "Back: where the pill went")
    },
])

/// Where a range of a text view's text is laid out, in the view's coordinates (TextKit 2).
@MainActor private func segment(of range: NSRange, in view: NSTextView) -> CGRect? {
    guard let layout = view.textLayoutManager, let content = layout.textContentManager,
          let start = content.location(content.documentRange.location, offsetBy: range.location),
          let end = content.location(start, offsetBy: range.length),
          let textRange = NSTextRange(location: start, end: end) else { return nil }
    layout.ensureLayout(for: textRange)
    var found: CGRect?
    layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
        found = frame
        return false
    }
    return found.map { $0.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y) }
}

/// A board's window (the app's `BoardWindow`, through `UndoBoard`) showing a task, "Launch
/// checklist", and a note that mentions it ("Ask ⟨Launch checklist⟩ first"), with nothing to undo.
@MainActor private struct MentionWindow {
    let board: UndoBoard
    let task: ShapeID
    let note: ShapeID

    /// The note's editor, with the keyboard.
    func text() throws -> MentionTextView<AnyMentionable> {
        try require(board.window.firstResponder as? MentionTextView<AnyMentionable>, "the note's editor has the keyboard")
    }

    /// A mouse event on the middle of a character of `text`.
    func mouse(_ type: NSEvent.EventType, onCharacter location: Int, of text: NSTextView, clicks: Int = 1) -> NSEvent {
        let screen = text.firstRect(forCharacterRange: NSRange(location: location, length: 1), actualRange: nil)
        let rect = board.window.convertFromScreen(screen)
        return NSEvent.mouseEvent(with: type, location: CGPoint(x: rect.midX, y: rect.midY), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: board.window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
}

@MainActor private func mentionWindow() throws -> MentionWindow {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let h = emptyBoard(pasteboard)
    let task = h.editor.addTask("Launch checklist")
    let note = h.editor.addNote(mentioning: task, as: "Launch checklist")
    let board = try UndoBoard()
    board.editor.replaceDocument(with: h.editor.document)
    board.window.makeFirstResponder(board.canvas)
    return MentionWindow(board: board, task: task, note: note)
}

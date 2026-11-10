import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Frames
import LanguageModels
import Mentions
import References
import Selection
import ShippedTesting
import SlashCommands
import StickyNotes
import Subboards
import TestKit
import Topology

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

    test("/move-to for three notes selected puts them in the frame as one block, each where it was to the others, 40 in from the frame's top-left; one step, Undo Move, takes them all back") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let e = Errands(pasteboard)
        let two = e.editor.add(StickyNote(frame: CGRect(x: 320, y: 100, width: 200, height: 200), text: "two"))
        let three = e.editor.add(StickyNote(frame: CGRect(x: 100, y: 320, width: 200, height: 200), text: "three"))
        let notes = [e.note, two, three]
        let kinds = e.editor.registry.containingKinds
        let state = try require(e.editor.slashCommands)
        e.editor.selectedShapeIDs = notes
        let command = try require(state.command(named: "move-to", for: .selection(e.editor.selectedShapeIDs)))
        expectEqual(command.shapes, notes)
        expect(!command.isPartial)
        expect(command.admits(e.groceries) && command.admits(e.plans), "the frame and the subboard")
        expect(!command.admits(e.milk), "a note is no place")
        expect(state.run(command, with: SlashArguments([.shape(e.groceries, label: "Groceries")])))
        expectEqual(notes.map { e.frame($0)?.origin }, [CGPoint(x: 640, y: 140), CGPoint(x: 860, y: 140), CGPoint(x: 640, y: 360)], "the block 40 in from the frame's top-left")
        expectEqual(notes.map { e.editor.document.container(of: $0, containingKinds: kinds) }, [e.groceries, e.groceries, e.groceries])
        expectEqual(e.editor.undoHistory.undoName, "Move")
        e.editor.undo()
        expectEqual(notes.map { e.frame($0)?.origin }, [CGPoint(x: 100, y: 100), CGPoint(x: 320, y: 100), CGPoint(x: 100, y: 320)], "all three, in one step")
        expectEqual(notes.map { e.editor.document.container(of: $0, containingKinds: kinds) }, [nil, nil, nil])
        expect(e.editor.undoHistory.undoName != "Move", "no Move left")
    },

    test("/move-near for two notes selected puts them as one block right of Milk, 80 away and centered on it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let e = Errands(pasteboard)
        let two = e.editor.add(StickyNote(frame: CGRect(x: 320, y: 100, width: 200, height: 200), text: "two"))
        let state = try require(e.editor.slashCommands)
        e.editor.selectedShapeIDs = [e.note, two]
        let command = try require(state.command(named: "move-near", for: .selection(e.editor.selectedShapeIDs)))
        expect(!command.admits(e.note) && !command.admits(two), "not beside one of them")
        expect(state.run(command, with: SlashArguments([.shape(e.milk, label: "Milk")])))
        let milk = try require(e.frame(e.milk)), first = try require(e.frame(e.note)), second = try require(e.frame(two))
        expectEqual(first.origin, CGPoint(x: milk.maxX + 80, y: milk.midY - 100), "the block's left edge 80 off, its 200 down centered on Milk")
        expectEqual(second.minX - first.minX, 220, "kept where they were to each other")
        expectEqual(second.minY, first.minY)
        expectEqual(e.editor.undoHistory.undoName, "Move")
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

    test("/move-to @Plans moves the note onto the subboard's board, and the window goes after it: the note selected there, editing over; Back returns to the root, and Undo Move brings the note back there") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let e = Errands(pasteboard)
        let view = try e.type("/move-to @pla")
        expectEqual(view.picker?.highlightedCandidate?.id, e.plans)
        e.window.pressReturn()
        e.window.pressReturn()
        e.window.settle()
        expectEqual(e.editor.file.board(containing: e.note), BoardID(owner: e.plans))
        expectEqual(e.editor.board, BoardID(owner: e.plans), "the board it went to")
        expectEqual(e.editor.selectedShapeIDs, [e.note])
        expectEqual(e.editor.editingShapeID, nil)
        expectEqual(e.text(), "keep\n")
        expectEqual(e.editor.undoHistory.undoName, "Move")
        e.editor.goBack()
        expectEqual(e.editor.board, .root, "back where it was moved from")
        e.editor.undo()
        expectEqual(e.editor.file.board(containing: e.note), .root)
        expectEqual(e.frame(e.note)?.origin, CGPoint(x: 100, y: 100))
    },

    test("on a subboard's board, /move-to @ lists the subboard beside it on the root with nothing typed; picked and run, the note goes onto that one's board, and the window after it") {
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
        expectEqual(editor.board, BoardID(owner: polish), "the window goes to Polish's board")
        expectEqual(editor.selectedShapeIDs, [note])
    },

    test("/move-to @Plans with an arrow bound to the note and free at the other end: the arrow goes to the subboard's board with the note, its free end as far from the note as it was; Undo Move brings both back") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let e = Errands(pasteboard)
        let free = CGPoint(x: 900, y: 150)
        let arrow = e.editor.add(Arrow(start: .bound(ArrowBinding(shapeID: e.note, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)),
                                       end: .free(free)))
        let origin = try require(e.frame(e.note)).origin
        _ = try e.type("/move-to @pla")
        e.window.pressReturn()
        e.window.pressReturn()
        e.window.settle()
        let plans = BoardID(owner: e.plans)
        expectEqual(e.editor.file.board(containing: e.note), plans)
        expectEqual(e.editor.file.board(containing: arrow), plans, "the arrow went with the note")
        let landed = try require(e.frame(e.note)).origin
        let props = try require(e.editor.file.record(arrow)?.typed(as: Arrow.self)?.props)
        expectEqual(props.start.binding?.shapeID, e.note, "still bound to it")
        guard case .free(let end) = props.end else { return expect(false, "its other end is still free") }
        expectEqual(CGPoint(x: end.x - landed.x, y: end.y - landed.y), CGPoint(x: free.x - origin.x, y: free.y - origin.y), "as far from the note as it was")
        expectEqual(e.editor.undoHistory.undoName, "Move")
        e.editor.undo()
        expectEqual(e.editor.file.board(containing: arrow), .root)
        expectEqual(e.editor.file.record(arrow)?.typed(as: Arrow.self)?.props.end, .free(free), "and the free end where it was")
        expectEqual(e.frame(e.note)?.origin, origin)
    },

    test("/move-to @Plans with an arrow bound at both ends: it goes with its start and ends at a reference pill for the note that stays, right of the start; Undo Move brings every board back") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let e = Errands(pasteboard)
        let plans = BoardID(owner: e.plans)
        let toMilk = try require(e.editor.connect(ConnectEnd(e.note), to: ConnectEnd(e.milk)), "an arrow from the note to Milk")
        let eggs = e.editor.add(StickyNote(frame: CGRect(x: 400, y: 1000, width: 200, height: 200), text: "Eggs"))
        let unrelated = try require(e.editor.connect(ConnectEnd(e.milk), to: ConnectEnd(eggs)), "and one from Milk to Eggs")
        let before = e.editor.file
        expect(e.editor.slashCommands?.run("move-to", on: e.note, with: SlashArguments([.shape(e.plans, label: "Plans")])) ?? false)
        expectEqual(e.editor.file.board(containing: e.note), plans)
        expectEqual(e.editor.file.board(containing: toMilk), plans, "the arrow went with its start")
        let pill = try require(e.editor.file[plans].shapes.first { $0.kind == Reference.kind }, "a pill, on the board the note went to")
        expectEqual(e.editor.registry.standIns.directTarget(of: pill), e.milk, "it stands for Milk, which stayed")
        let ends = try require(e.editor.file.record(toMilk).flatMap { e.editor.registry.connectionEnds(of: $0) })
        expectEqual(ends.from, e.note)
        expectEqual(ends.to, pill.id, "the end is the pill")
        expect((pill.box?.minX ?? 0) >= (e.frame(e.note)?.maxX ?? .infinity), "right of the start")
        expectEqual(e.editor.file.board(containing: unrelated), .root, "an arrow that crosses nowhere stays")
        expectEqual(e.editor.undoHistory.undoName, "Move")
        e.editor.undo()
        expect(e.editor.file == before, "every board as it was")
    },

    test("/move-to @Plans for the note that an arrow from Milk ends at: the arrow stays and ends at a reference pill for the note, right of Milk, on the root; Undo Move brings it back") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let e = Errands(pasteboard)
        let arrow = try require(e.editor.connect(ConnectEnd(e.milk), to: ConnectEnd(e.note)), "an arrow from Milk to the note")
        let before = e.editor.file
        expect(e.editor.slashCommands?.run("move-to", on: e.note, with: SlashArguments([.shape(e.plans, label: "Plans")])) ?? false)
        expectEqual(e.editor.file.board(containing: e.note), BoardID(owner: e.plans))
        expectEqual(e.editor.file.board(containing: arrow), .root, "the arrow stays with its start")
        let pill = try require(e.editor.file[.root].shapes.first { $0.kind == Reference.kind })
        expectEqual(e.editor.registry.standIns.directTarget(of: pill), e.note, "it stands for the note that moved")
        let ends = try require(e.editor.file.record(arrow).flatMap { e.editor.registry.connectionEnds(of: $0) })
        expectEqual(ends.from, e.milk)
        expectEqual(ends.to, pill.id)
        expect((pill.box?.minX ?? 0) >= (e.frame(e.milk)?.maxX ?? .infinity), "right of Milk")
        e.editor.undo()
        expect(e.editor.file == before, "as it was")
    },

    test("/move-to @Plans for a second note whose arrow ends at the same note: the pill Plans has for it is reused, the arrow goes to it, and no other is made; Undo Move takes only the second move back") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let e = Errands(pasteboard)
        let plans = BoardID(owner: e.plans)
        let eggs = e.editor.add(StickyNote(frame: CGRect(x: 400, y: 1000, width: 200, height: 200), text: "Eggs"))
        let first = try require(e.editor.connect(ConnectEnd(e.note), to: ConnectEnd(e.milk)))
        let second = try require(e.editor.connect(ConnectEnd(eggs), to: ConnectEnd(e.milk)))
        let command = SlashArguments([.shape(e.plans, label: "Plans")])
        expect(e.editor.slashCommands?.run("move-to", on: e.note, with: command) ?? false)
        let pill = try require(e.editor.file[plans].shapes.first { $0.kind == Reference.kind }, "the first move made a pill for Milk")
        expect(e.editor.showBoard(.root))
        let before = e.editor.file
        expect(e.editor.slashCommands?.run("move-to", on: eggs, with: command) ?? false)
        expectEqual(e.editor.file[plans].shapes.filter { $0.kind == Reference.kind }.map(\.id), [pill.id], "no second pill")
        expectEqual(e.editor.file.board(containing: second), plans, "the arrow went with Eggs")
        let ends = try require(e.editor.file.record(second).flatMap { e.editor.registry.connectionEnds(of: $0) })
        expectEqual(ends.from, eggs)
        expectEqual(ends.to, pill.id, "to the pill that was there")
        expectEqual(e.editor.file.board(containing: first), plans)
        expectEqual(e.editor.undoHistory.undoName, "Move")
        e.editor.undo()
        expect(e.editor.file == before, "the second move undone exactly")
    },
])

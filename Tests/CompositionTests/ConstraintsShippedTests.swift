import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Constraints
import CoreGraphics
import DetailPanel
import Draw
import Foundation
import Frames
import Geometry
import LanguageModels
import Locking
import Mentions
import Queries
import Selection
import ShippedTesting
import SlashCommands
import TableOfContents
import StickyNotes
import Subboards
import TestKit
import Titles
import Types
import Validation

// Constraints, as shipped: frames side by side, each saying what it accepts (a type's `$constraints`, or a list of its own),
// so a note made in each is what it holds, a shape moved in that doesn't fit glides back and the place says why, one already
// inside that doesn't is an error with a way out, and `canvas draw` and `/constrain` write the same lists. The lists are
// Constraints', the types' are Types', and the funnel, the Rules tab and the commands are ConstraintFacesPlugin's.

/// A Task, a Bug and a Person, each with a field; Sprint, a type that says what its frames accept.
private let taskSchema = #"{"type": "object", "properties": {"status": {"type": "string"}}}"#
private let bugSchema = #"{"type": "object", "properties": {"severity": {"type": "string"}}}"#
private let personSchema = #"{"type": "object", "properties": {"name": {"type": "string"}}}"#
private let onlyTasks = Constraint(says: "only tasks", query: ":is-a(\"Task\")")
private let onlyBugs = Constraint(says: "only bugs", query: ":is-a(\"Bug\")")
private let onlyPeople = Constraint(says: "only people", query: ":is-a(\"Person\")")
private let onlySubboards = Constraint(says: "only subboards", query: "subboard")

/// The board these tests share, as shipped (a private pasteboard, a scripted model): four frames side by side. Tasks is of the
/// type Sprint, whose `$constraints` say it accepts only tasks; Bugs and People hold lists of their own; Archive accepts only
/// subboards. The types Task, Bug, Person and Sprint are notes under them.
@MainActor private final class Places {
    let h: EditorHarness
    let model: ScriptedLanguageModel
    let pasteboard: NSPasteboard
    var editor: CanvasEditor { h.editor }
    var task = ShapeID(), bug = ShapeID(), person = ShapeID(), sprint = ShapeID()
    var tasks = ShapeID(), bugs = ShapeID(), people = ShapeID(), archive = ShapeID()

    static let tasksRect = CGRect(x: 40, y: 40, width: 420, height: 420)
    static let bugsRect = CGRect(x: 500, y: 40, width: 420, height: 420)
    static let peopleRect = CGRect(x: 960, y: 40, width: 420, height: 420)
    static let archiveRect = CGRect(x: 40, y: 500, width: 420, height: 300)

    init(model: ScriptedLanguageModel = ScriptedLanguageModel()) {
        self.model = model
        let pasteboard = NSPasteboard.withUniqueName()
        self.pasteboard = pasteboard
        h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: model) }
        editor.viewportDidResize(to: CGSize(width: 1500, height: 900))
        task = editor.addTypeNote(taskSchema, title: "Task", frame: CGRect(x: 500, y: 520, width: 200, height: 200))
        bug = editor.addTypeNote(bugSchema, title: "Bug", frame: CGRect(x: 720, y: 520, width: 200, height: 200))
        person = editor.addTypeNote(personSchema, title: "Person", frame: CGRect(x: 940, y: 520, width: 200, height: 200))
        sprint = editor.addTypeNote(TypeConstraintBook.text(#"{"type": "object", "properties": {}}"#, setting: [onlyTasks]) ?? "",
                                    title: "Sprint", frame: CGRect(x: 1160, y: 520, width: 200, height: 200))
        tasks = frame("Tasks", Places.tasksRect)
        editor.addTypeLink(sprint, to: tasks)
        bugs = frame("Bugs", Places.bugsRect, [onlyBugs])
        people = frame("People", Places.peopleRect, [onlyPeople])
        archive = frame("Archive", Places.archiveRect, [onlySubboards])
        settle()
    }

    deinit {
        MainActor.assumeIsolated { pasteboard.releaseGlobally() }
    }

    /// A frame titled `title`, holding its own `constraints`.
    @discardableResult
    func frame(_ title: String, _ rect: CGRect, _ constraints: [Constraint] = []) -> ShapeID {
        var record = ShapeRecord(Frame(frame: rect))
        record[TitleProperty.self] = title
        if !constraints.isEmpty { record[ConstraintsProperty.self] = ConstraintList(constraints) }
        editor.transact { $0.insert(record) }
        return record.id
    }

    /// Lets the standing queries answer.
    func settle(file: StaticString = #fileID, line: UInt = #line) {
        let index = editor.constraintIndex
        expect(spinRunLoop(until: { index?.isSettled ?? true }, timeout: 5, file: file, line: line), "the constraints settle", file: file, line: line)
    }

    func origin(of id: ShapeID) -> CGPoint? { editor.document[id]?.box?.origin }

    /// Makes `id` a shape of `types`, as a retype does, in a step of its own.
    func retype(_ id: ShapeID, to types: [ShapeID]) {
        editor.transact("Is") { $0.update(id) { $0[IsAProperty.self] = types.map(TypeLink.init) } }
    }

    /// Drags a shape by its middle to `point`, and lets go.
    func drop(_ id: ShapeID, at point: CGPoint) {
        let start = CGPoint(x: (origin(of: id)?.x ?? 0) + 100, y: (origin(of: id)?.y ?? 0) + 100)
        editor.setTool(.select)
        h.press(at: start)
        h.drag(to: CGPoint(x: (start.x + point.x) / 2, y: (start.y + point.y) / 2))
        h.drag(to: point)
        h.release()
        settle()
    }

    /// The dots on a shape's row in the sidebar, wherever the row is nested.
    func sidebarMarks(of id: ShapeID) -> [ContentsMark] {
        func find(_ entries: [ContentsEntry]) -> [ContentsMark]? {
            for entry in entries {
                if entry.id == id { return entry.marks }
                if let found = find(entry.children ?? []) { return found }
            }
            return nil
        }
        return find(editor.tableOfContents?.entries ?? []) ?? []
    }

    func types(of id: ShapeID) -> [ShapeID] { editor.document[id]?[IsAProperty.self]?.map(\.shape) ?? [] }
    func notes() -> [ShapeID] { editor.document.shapes.filter { $0.kind == StickyNote.kind }.map(\.id) }
    func issues(of id: ShapeID) -> [String] {
        _ = editor.validation?.results
        return (editor.validation?.result(for: id)?.issues ?? []).map(\.message)
    }

    /// A click with the Note tool at `point`: a note is made there, edited; Escape ends the editing.
    @discardableResult
    func make(with tool: ToolID = ToolID(placing: StickyNote.kind), at point: CGPoint) -> ShapeID? {
        let before = Set(editor.document.shapes.map(\.id))
        editor.setTool(tool)
        h.click(at: point)
        let made = editor.document.shapes.first { !before.contains($0.id) }?.id
        editor.endEditing()
        editor.setTool(.select)
        settle()
        return made
    }
}

@MainActor let constraintsShippedTests = Suite("Constraints, as shipped", [
    test("a note made with the Note tool in each of three frames arrives what the frame holds, with that type's fields; outside them it stays plain") {
        let p = Places()
        let task = try require(p.make(at: CGPoint(x: 250, y: 250)))
        let bug = try require(p.make(at: CGPoint(x: 710, y: 250)))
        let person = try require(p.make(at: CGPoint(x: 1170, y: 250)))
        expectEqual(p.types(of: task), [p.task], "a Task, from Sprint's own words")
        expectEqual(p.types(of: bug), [p.bug], "a Bug, from the frame's list")
        expectEqual(p.types(of: person), [p.person], "a Person")
        expectEqual([task, bug, person].map { p.editor.holder(of: $0) }, [p.tasks, p.bugs, p.people])
        expectEqual(p.editor.rowBook?.rows(of: task).map(\.name), ["status"], "with its fields")
        expectEqual(p.editor.rowBook?.rows(of: bug).map(\.name), ["severity"])
        expectEqual(p.editor.rowBook?.rows(of: person).map(\.name), ["name"])
        expectEqual([task, bug, person].map { p.editor.document[$0]?.kind }, [StickyNote.kind, StickyNote.kind, StickyNote.kind], "the tool's kind stays")
        expectEqual([task, bug, person].map { p.issues(of: $0) }, [[], [], []], "made to fit: nothing flagged")
        let free = try require(p.make(at: CGPoint(x: 1200, y: 800)))
        expectEqual(p.types(of: free), [], "outside every frame a note is a note")
        expectEqual(p.editor.holder(of: free), nil)
    },
    test("a double-click in a frame that accepts subboards makes a subboard there; in Tasks a note that is a Task; the Note tool in the same frame still makes a note, flagged") {
        let p = Places()
        let before = p.editor.document.shapes.count
        p.h.click(at: CGPoint(x: 250, y: 650))
        p.h.press(at: CGPoint(x: 250, y: 650), clickCount: 2)
        p.h.release()
        let made = try require(p.editor.document.shapes.last)
        expectEqual(p.editor.document.shapes.count, before + 1)
        expectEqual(made.kind, Subboard.kind, "the frame's list names subboards, and a double-click's kind is open")
        expectEqual(p.editor.holder(of: made.id), p.archive)
        expectEqual(p.editor.undoHistory.undoName, "Add Subboard", "the step is named for what landed, not for the note the double-click asked for")
        p.editor.endEditing()
        p.settle()
        expectEqual(p.issues(of: made.id), [], "it fits")
        p.h.click(at: CGPoint(x: 250, y: 250))
        p.h.press(at: CGPoint(x: 250, y: 250), clickCount: 2)
        p.h.release()
        let task = try require(p.editor.document.shapes.last)
        expectEqual(task.kind, StickyNote.kind, "in Tasks the shape stays a note")
        expectEqual(p.types(of: task.id), [p.task], "and is a Task")
        p.editor.endEditing()
        let note = try require(p.make(at: CGPoint(x: 350, y: 760)))
        expectEqual(p.editor.document[note]?.kind, StickyNote.kind, "the Note tool keeps its kind")
        expectEqual(p.editor.holder(of: note), p.archive, "and goes in")
        expectEqual(p.issues(of: note), ["Archive accepts only subboards."], "flagged: nothing can write a subboard from a note it made")
    },
    test("a bug dragged into Tasks glides back with no step: no outline while dragging, the frame shakes, the words are announced once; a task dragged in goes in") {
        let p = Places()
        let bug = try require(p.make(at: CGPoint(x: 710, y: 250)))
        let origin = try require(p.origin(of: bug))
        let step = p.editor.undoHistory.undoName
        let announced = p.editor.announcements.count
        p.editor.setTool(.select)
        p.h.press(at: CGPoint(x: 710, y: 250))
        p.h.drag(to: CGPoint(x: 600, y: 250))
        p.h.drag(to: CGPoint(x: 400, y: 250))
        p.h.drag(to: CGPoint(x: 250, y: 250))
        expectEqual(p.editor.hintedShapeID, nil, "no outline over the frame that would refuse it")
        expectEqual(p.editor.announcements.count, announced, "a try says nothing")
        p.h.release()
        expectEqual(p.origin(of: bug), origin, "back where it was")
        expectEqual(p.editor.holder(of: bug), p.bugs)
        expectEqual(p.editor.undoHistory.undoName, step, "no step")
        p.h.wait(16)
        expect(p.editor.drawingOffset(of: p.tasks) != .zero, "the frame shakes")
        expectEqual(Array(p.editor.announcements.dropFirst(announced)), ["Tasks accepts only tasks."], "the words, announced")
        expectEqual(p.issues(of: bug), [])
        // A task made outside goes in.
        let loose = try require(p.make(at: CGPoint(x: 1000, y: 700)))
        p.retype(loose, to: [p.task])
        p.settle()
        p.drop(loose, at: CGPoint(x: 250, y: 250))
        expectEqual(p.editor.holder(of: loose), p.tasks, "a task goes in")
        expectEqual(p.editor.undoHistory.undoName, "Move")
    },
    test("a task retyped as a bug turns red: the Issues line reads Tasks accepts only tasks. with Move Out and Show Constraint, :invalid lists it; Move Out puts it beside the frame") {
        let p = Places()
        let note = try require(p.make(at: CGPoint(x: 250, y: 250)))
        p.editor.transact("Title") { $0.update(note) { $0[TitleProperty.self] = "Fix login" } }
        p.settle()
        expectEqual(p.issues(of: note), [])
        p.retype(note, to: [p.bug])
        p.settle()
        expectEqual(p.issues(of: note), ["Tasks accepts only tasks."])
        expectEqual(p.editor.holder(of: note), p.tasks, "nothing moves by itself")
        // The panel's Issues tab: the line and its two ways out.
        let panel = try require(p.editor.detailPanel)
        let issues = panel.layout(for: try require(p.editor.document[note])).statuses(in: .of(IssuesTab.self))
        expectEqual(issues.map(\.text), ["Tasks accepts only tasks."])
        expectEqual(issues.first?.tone, .error)
        expectEqual(issues.first?.actions.map(\.title), ["Move Out", "Show Constraint", "1 of 1"], "the walk's start with them")
        // The ring, the sidebar's mark and the query.
        let box = try require(p.editor.document[note]?.box)
        p.editor.selectedShapeIDs = []
        let rep = renderBitmap(p.editor, size: CGSize(width: 1500, height: 900))
        let ring = pixel(rep, at: CGPoint(x: box.maxX + 2, y: box.midY))
        expect(ring[0] > 180 && ring[1] < 110 && ring[2] < 110, "a red ring beside the note: \(ring)")
        expectEqual(p.sidebarMarks(of: note).map(\.help), ["Tasks accepts only tasks."], "the sidebar's mark says it")
        expectEqual(try found(":invalid", in: p.editor), [note], "`:invalid` lists it")
        // Move Out: beside the frame, one step, a task of Sprint's frame no longer.
        let before = p.editor.undoHistory.undoName
        try require(p.editor.validation?.result(for: note)?.issues.first?.actions.first { $0.title == "Move Out" }).perform()
        p.settle()
        expectEqual(p.editor.holder(of: note), nil, "out of the frame")
        expect(!Places.tasksRect.intersects(try require(p.editor.document[note]?.box)), "beside it, not on it")
        expectEqual(p.editor.undoHistory.undoName, "Move Out")
        expect(before != "Move Out")
        expectEqual(p.issues(of: note), [])
        p.editor.undo()
        p.settle()
        expectEqual(p.editor.holder(of: note), p.tasks, "one step, undone")
        expectEqual(p.issues(of: note), ["Tasks accepts only tasks."], "flagged again, not refused")
    },
    test("canvas draw: a type's $constraints written in its schema reach the frames of it; a shape drawn there goes in, flagged; a move into Tasks is refused cannot_contain in the frame's words") {
        let p = Places()
        let schema = try require(TypeConstraintBook.text(#"{"type": "object", "properties": {}}"#, setting: [onlyBugs]))
        _ = try draw(script: #"sticky-note "Triage" schema: "\#(quoted(schema))" text: "Where bugs are triaged""#, dryRun: false, reveal: false, program: "canvas", in: p.editor)
        let triage = try require(p.editor.document.shapes.first { p.editor.registry.title(of: $0) == "Triage" }?.id)
        expectEqual(TypeConstraintBook.constraints(inSchema: try require(p.editor.schemaText(triage))), [onlyBugs], "kept in the schema, as $rules is")
        _ = try draw(script: #"frame "Triage board" size: 400x300 is: "Triage""#, dryRun: false, reveal: false, program: "canvas", in: p.editor)
        let board = try require(p.editor.document.shapes.first { p.editor.registry.title(of: $0) == "Triage board" }?.id)
        p.settle()
        expectEqual(p.editor.constraintIndex?.constraints(of: .shape(board)).map(\.constraint), [onlyBugs], "the frame has its type's list")
        let report = try draw(script: #"sticky-note "Crash" in "Triage board" size: 120x60 is: "Task""#, dryRun: false, reveal: false, program: "canvas", in: p.editor)
        let editor = p.editor
        let encoded = String(decoding: try JSONEncoder().encode(try awaitResult { await laterIssues(of: report, in: editor) }), as: UTF8.self)
        expect(encoded.contains(#""message":"\"Crash\": Triage board accepts only bugs.""#) && encoded.contains(#""severity":"error""#) && encoded.contains(#""line":1"#),
               "the report says the breaker it drew, an error on its statement's line, once the answers have come: \(encoded)")
        let crash = try require(p.editor.document.shapes.first { p.editor.registry.title(of: $0) == "Crash" }?.id)
        expectEqual(p.editor.holder(of: crash), board, "drawn there, it goes in")
        p.settle()
        expectEqual(p.issues(of: crash), ["Triage board accepts only bugs."], "and is flagged")
        // A bug lying loose on the board is moved into Tasks: refused, in the words the person hears.
        _ = try draw(script: #"sticky-note "Real bug" size: 120x60 is: "Bug""#, dryRun: false, reveal: false, program: "canvas", in: p.editor)
        p.settle()
        let real = try require(p.editor.document.shapes.first { p.editor.registry.title(of: $0) == "Real bug" }?.id)
        expectEqual(p.editor.holder(of: real), nil, "loose")
        let before = p.editor.undoHistory.undoName
        do throws(DrawError) {
            let r = try draw(script: #"sticky-note "Real bug" in "Tasks""#, dryRun: false, reveal: false, program: "canvas", in: p.editor)
            expect(false, "refused")
        } catch {
            expectEqual(error.reason, "cannot_contain")
            expect(error.message.contains("Tasks accepts only tasks."), error.message)
        }
        expectEqual(p.editor.undoHistory.undoName, before, "nothing drawn")
        expectEqual(p.editor.holder(of: real), nil, "and it stays where it is")
    },
    test("canvas apply and canvas rehearse refuse a move into a place that refuses it, as canvas draw does: cannot_contain, nothing changes") {
        let p = Places()
        func document(inFrame: Bool) -> String {
            var note: JSON = ["key": "note:x", "kind": "sticky-note", "props": ["title": "Crash"], "place": ["at": [1500, 0]]]
            if inFrame { note = ["key": "note:x", "in": "frame:fine", "kind": "sticky-note", "props": ["title": "Crash"], "place": ["at": [40, 60]]] }
            let nodes: [JSON] = [["key": "frame:fine", "kind": "frame", "props": ["title": "Fine"], "place": ["at": [0, 1000], "size": [600, 400]]], note]
            let value: JSON = ["drawing": "Plan", "nodes": .array(nodes), "edges": []]
            return value.compactText
        }
        _ = try apply(document: document(inFrame: false), dryRun: false, on: nil, program: "canvas", in: p.editor)
        let fine = try require(p.editor.document.shapes.first { p.editor.registry.title(of: $0) == "Fine" }?.id)
        let crash = try require(p.editor.document.shapes.first { p.editor.registry.title(of: $0) == "Crash" }?.id)
        p.editor.transact("Constrain") { $0.update(fine) { $0[ConstraintsProperty.self] = ConstraintList([onlySubboards]) } }
        p.settle()
        let before = p.editor.file, step = p.editor.undoHistory.undoName
        for dryRun in [true, false] {
            do throws(DocumentError) {
                _ = try apply(document: document(inFrame: true), dryRun: dryRun, on: nil, program: "canvas", in: p.editor)
                expect(false, "apply refused (dry run \(dryRun))")
            } catch {
                expect(error.refusals.contains { $0.reason == "cannot_contain" && $0.key == "note:x" && $0.message.contains("accepts only") },
                       "in the frame's words, naming the node: \(error)")
            }
        }
        expectEqual(p.editor.file, before, "nothing changes")
        expectEqual(p.editor.undoHistory.undoName, step, "no step")
        expectEqual(p.editor.holder(of: crash), nil, "the note stays where it is")
        let rehearsal = Rehearsal(of: p.editor, program: "canvas")
        do throws(DrawError) {
            _ = try rehearsal.run(#"sticky-note "Crash" in "Fine""#)
            expect(false, "rehearse refused")
        } catch {
            expectEqual(error.reason, "cannot_contain", "rehearse says what the real draw says")
        }
        // A shape a rehearsal makes is new there, as on a live editor: it goes in.
        let made = Rehearsal(of: p.editor, program: "canvas")
        _ = try made.run(#"sticky-note "Fresh" in "Fine""#)
    },
    test("a ⌥-drag of a note into a frame that accepts only frames is refused: the copy is taken away, the note stays selected, the frame shakes, the file is as it was and no step is left") {
        let p = Places()
        p.frame("Frames", CGRect(x: 1000, y: 480, width: 450, height: 300), [Constraint(says: "only frames", query: "frame")])
        let note = try require({ () -> ShapeID? in
            var record = ShapeRecord(StickyNote(frame: CGRect(x: 600, y: 780, width: 100, height: 80), text: MentionText(plain: "Loose")))
            record[TitleProperty.self] = "Loose"
            p.editor.transact { $0.insert(record) }
            return record.id
        }())
        p.settle()
        p.editor.selectedShapeIDs = [note]
        p.editor.setTool(.select)
        let before = p.editor.file, step = p.editor.undoHistory.undoName
        p.h.hold(.option)
        p.h.press(at: CGPoint(x: 650, y: 820))
        p.h.drag(to: CGPoint(x: 900, y: 700), speed: 4)
        p.settle()                                      // the copy's answer comes while the drag is under way
        p.h.drag(to: CGPoint(x: 1200, y: 650), speed: 4)
        p.h.release()
        p.h.hold([])
        p.settle()
        expectEqual(p.editor.file.root.shapes.count, before.root.shapes.count, "no copy is left")
        expectEqual(p.editor.selectedShapeIDs, [note])
        expectEqual(p.editor.undoHistory.undoName, step, "no step")
        expectEqual(p.editor.holder(of: note), nil)
    },
    test("canvas draw: a bug drawn into Tasks warns, and so does a type's $constraints written by a run for a breaker already in a frame of that type; a dry run says neither") {
        let p = Places()
        let editor = p.editor
        @MainActor func said(_ script: String, dryRun: Bool = false) throws -> String {
            let report = try draw(script: script, dryRun: dryRun, reveal: false, program: "canvas", in: editor)
            return String(decoding: try JSONEncoder().encode(try awaitResult { await laterIssues(of: report, in: editor) }), as: UTF8.self)
        }
        let bugged = try said(#"sticky-note "Wrong" in "Tasks" size: 120x60 is: "Bug""#)
        expect(bugged.contains(#""message":"\"Wrong\": Tasks accepts only tasks.""#) && bugged.contains(#""severity":"error""#), "a bug drawn into Tasks: \(bugged)")
        // A type with no constraints yet, a frame of it, and a task in the frame: nothing breaks until the type says so.
        let plain = #"{"type": "object", "properties": {}}"#
        _ = try draw(script: #"sticky-note "Triage" schema: "\#(quoted(plain))" text: "Where bugs are triaged""#, dryRun: false, reveal: false, program: "canvas", in: editor)
        _ = try draw(script: #"frame "Triage board" size: 400x300 is: "Triage""#, dryRun: false, reveal: false, program: "canvas", in: editor)
        _ = try draw(script: #"sticky-note "Crash" in "Triage board" size: 120x60 is: "Task""#, dryRun: false, reveal: false, program: "canvas", in: editor)
        p.settle()
        let schema = try require(TypeConstraintBook.text(plain, setting: [onlyBugs]))
        let script = #"sticky-note "Triage" schema: "\#(quoted(schema))""#
        let dry = try said(script, dryRun: true)
        expect(!dry.contains("accepts only"), "a dry run commits nothing, so nothing comes: \(dry)")
        let written = try said(script)
        let warned = try JSONDecoder().decode(JSON.self, from: Data(written.utf8))["warnings"]?.arrayValue ?? []
        expect(written.contains(#""message":"\"Crash\": Triage board accepts only bugs.""#) && written.contains(#""severity":"error""#) && !warned.contains { $0["line"] != nil },
               "the type's list written by the run reaches the task already in the frame, on no line (the run found nothing of it): \(written)")
    },
    test("canvas draw: a frame retyped into a type whose list its members break says what it now breaks, on no line") {
        let p = Places()
        let editor = p.editor
        _ = try draw(script: #"sticky-note "Ann" in "People" size: 120x60 is: "Person""#, dryRun: false, reveal: false, program: "canvas", in: editor)
        p.settle()
        @MainActor func said(_ script: String, dryRun: Bool = false) throws -> [JSON] {
            let report = try draw(script: script, dryRun: dryRun, reveal: false, program: "canvas", in: editor)
            let later = try awaitResult { await laterIssues(of: report, in: editor) }
            return try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(later))["warnings"]?.arrayValue ?? []
        }
        let dry = try said(#"frame "People" is: "Sprint""#, dryRun: true)
        expectEqual(dry.compactMap { $0["message"]?.stringValue }.filter { $0.contains("accepts only") }, [], "a dry run commits nothing")
        let warnings = try said(#"frame "People" is: "Sprint""#)
        let accepts = warnings.filter { $0["message"]?.stringValue?.contains("accepts only tasks") == true }
        expectEqual(accepts.map { $0["message"] }, [#""Ann": People accepts only tasks."#], "the member the retyped frame now breaks: \(warnings)")
        expectEqual(accepts.first?["line"], nil, "the run found nothing of Ann: no line")
        expectEqual(p.issues(of: try require(editor.document.shapes.first { editor.registry.title(of: $0) == "Ann" }?.id)), ["People accepts only tasks."])
    },
    test("a subboard of Sprint has Sprint's list and judges its board: a note made on it is a Task, a bug put there is flagged, in the subboard's name") {
        let p = Places()
        let sub = p.editor.add(Subboard(frame: CGRect(x: 500, y: 500, width: 240, height: 160)))
        p.editor.transact("Title") { $0.update(sub) { $0[TitleProperty.self] = "Release 2" } }
        p.editor.addTypeLink(p.sprint, to: sub)
        p.settle()
        expectEqual(p.editor.constraintIndex?.constraints(of: .shape(sub)).map(\.constraint), [onlyTasks], "from its type")
        let bug = AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Crash")))
        var typed = bug
        typed[IsAProperty.self] = [TypeLink(p.bug)]
        p.editor.transact(on: BoardID(owner: sub)) { $0.insert(typed) }
        p.settle()
        expect(p.h.enter(sub))
        p.settle()
        expectEqual(p.issues(of: typed.id), ["Release 2 accepts only tasks."], "flagged on its board")
        let made = try require(p.make(at: CGPoint(x: 700, y: 400)))
        expectEqual(p.types(of: made), [p.task], "made a task")
        expectEqual(p.issues(of: made), [])
    },
    test("/constrain only tasks on a frame, the scripted model answering :is-a(\"Task\"): one step, the model asked once; a note made there is a Task; /unconstrain takes it away") {
        let model = ScriptedLanguageModel(answers: [#":is-a("Task")"#])
        let p = Places(model: model)
        let backlog = p.frame("Backlog", CGRect(x: 520, y: 500, width: 420, height: 300))
        let commands = try require(p.editor.slashCommands)
        expect(commands.commands(for: .selection([backlog])).map(\.name).contains("constrain"), "offered on a frame")
        expect(!commands.commands(for: .selection([backlog])).map(\.name).contains("unconstrain"), "nothing to take away yet")
        let before = model.requests.count
        let task = try require(commands.answer("constrain", for: .selection([backlog]), with: "only tasks"))
        let answer = try awaitResult { await task.value }
        expectEqual(answer, .done)
        p.settle()
        // The writer binds the title the words became to the shape it named, so a rename of Task keeps the list.
        expectEqual(p.editor.constraintWriter?.constraints(of: .shape(backlog)), [Constraint(says: "only tasks", query: #":is-a("Task")"#, names: ["Task": p.task])])
        expectEqual(p.editor.undoHistory.undoName, "Add Constraint")
        expectEqual(model.requests.count, before + 1, "the model is asked once")
        expect(model.lastRequest?.system?.contains("Backlog") == true, "in the place's name")
        let made = try require(p.make(at: CGPoint(x: 730, y: 650)))
        expectEqual(p.editor.holder(of: made), backlog)
        expectEqual(p.types(of: made), [p.task], "what the words say a shape is")
        // And away again: the list is each constraint, then all.
        let command = try require(commands.command(named: "unconstrain", for: .selection([backlog])))
        expectEqual(command.choices().map(\.title).first, "only tasks")
        let choice = try require(command.choices().first)
        expect(commands.run(command, choosing: choice))
        expectEqual(p.editor.constraintWriter?.constraints(of: .shape(backlog)) ?? [], [])
        expectEqual(p.editor.undoHistory.undoName, "Remove Constraint")
        p.settle()
        expectEqual(p.issues(of: made), [], "nothing is asked of it now")
    },
    test("a typed, locked, constrained frame's chips run type chips, funnel, lock; ⌥Tab reaches the funnel, Escape goes back to the frame") {
        let p = Places()
        p.editor.lock([p.tasks])
        p.settle()
        let chips = p.editor.adornmentFrames(of: p.tasks).filter { [.of(TypeChips.self), .of(ConstraintFunnel.self), .of(LockChip.self)].contains($0.adornment) }
        expectEqual(chips.sorted { $0.rect.minX < $1.rect.minX }.map(\.adornment), [.of(TypeChips.self), .of(ConstraintFunnel.self), .of(LockChip.self)],
                    "the type's chip, the funnel, the lock at the end")
        let funnel = try require(chips.first { $0.adornment == .of(ConstraintFunnel.self) })
        expectEqual(funnel.label.text ?? "", "", "quiet while everything fits: a symbol alone")
        let (window, canvas) = windowed(p.editor)
        window.makeFirstResponder(canvas)
        let walk = KeyWalk(window, editor: p.editor, readers: [.canvas(canvas, editor: p.editor, names: [p.tasks: "tasks"], part: { [editor = p.editor] in editor.focusedPart?.title }), .panel(of: canvas)])
        p.editor.selection = p.tasks
        var focus = walk.press(.optionTab)
        for _ in 0..<4 where focus.id != "canvas/tasks/Constraints, only tasks" { focus = walk.press(.optionTab) }
        expectEqual(focus.id, "canvas/tasks/Constraints, only tasks", "the funnel is a part")
        expectEqual(walk.press(.escape).id, "canvas/tasks", "Escape goes back to the frame")
        expectEqual(p.editor.selection, p.tasks)
    },
    test("a file with constraints saved and opened again keeps them: a frame's own, a type's $constraints and the root's, and judges by them") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let editor = board.editor
        editor.viewportDidResize(to: CGSize(width: 1500, height: 900))
        _ = editor.addTypeNote(taskSchema, title: "Task", frame: CGRect(x: 500, y: 520, width: 200, height: 200))
        let sprint = editor.addTypeNote(try require(TypeConstraintBook.text(#"{"type": "object", "properties": {}}"#, setting: [onlyTasks])),
                                        title: "Sprint", frame: CGRect(x: 740, y: 520, width: 200, height: 200))
        var typed = ShapeRecord(Frame(frame: Places.tasksRect))
        typed[TitleProperty.self] = "Tasks"
        var own = ShapeRecord(Frame(frame: Places.bugsRect))
        own[TitleProperty.self] = "Bugs"
        own[ConstraintsProperty.self] = ConstraintList([onlyBugs])
        editor.transact { $0.insert(typed); $0.insert(own) }
        editor.addTypeLink(sprint, to: typed.id)
        expect(editor.constraintWriter?.add(onlyPeople, to: .root) == true)
        let loose = AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(x: 1000, y: 100, width: 200, height: 200), text: "Loose")))
        editor.transact { $0.insert(loose) }
        let data = try board.data(ofType: boardType)

        let reopened = BoardDocument()
        defer { reopened.close() }
        try reopened.read(from: data, ofType: boardType)
        expect(reopened.loadReport.isEmpty, "\(reopened.loadReport)")
        let after = reopened.editor
        after.viewportDidResize(to: CGSize(width: 1500, height: 900))
        expectEqual(after.constraintWriter?.constraints(of: .shape(own.id)), [onlyBugs], "a frame's own list")
        expectEqual(after.constraintWriter?.constraints(of: .root), [onlyPeople], "the root's")
        expectEqual(TypeConstraintBook.constraints(inSchema: try require(after.schemaText(sprint))), [onlyTasks], "a type's, in its schema")
        expect(spinRunLoop(until: { after.constraintIndex?.isSettled ?? true }, timeout: 5), "the index settles")
        expectEqual(after.constraintIndex?.constraints(of: .shape(typed.id)).map(\.constraint), [onlyTasks], "the typed frame has its type's list")
        expectEqual(after.constraintIndex?.constraints(of: .shape(typed.id)).map(\.origin), [.inherited(sprint)])
        // And they judge: the loose note against the root's list, in the root's name.
        expectEqual((after.validation?.results[loose.id]?.issues ?? []).map(\.message), ["This board accepts only people."], "the root's list, in the root's name")
    },
])


/// A text as a script quotes it: backslashes and quotes escaped.
private func quoted(_ text: String) -> String { text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }

/// The ids a query finds.
@MainActor private func found(_ query: String, in editor: CanvasEditor) throws -> [ShapeID] {
    let queries = try require(editor.queries)
    return try awaitResult { try await queries.run(QueryRequest(query, limit: QueryRequest.every, properties: .none)) }.rows.map(\.id)
}

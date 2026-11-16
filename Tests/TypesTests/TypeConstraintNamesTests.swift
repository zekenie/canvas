@_spi(Host) import Canvas
import AppKit
import CanvasTesting
import Constraints
import CoreGraphics
import Foundation
import QueryTranslation
import TestKit
import Titles
import Types

// A constraint is judged by the shapes its query's titles named when it was written, so a rename changes nothing: a type's
// list ("only tasks") and a frame's own, the root's and a supertype's, when the type Task is renamed Chore; what the Rules
// tab shows follows the new name; a note made in the frame is made a Chore by the fit; and a list written without names (a
// schema written whole, as `canvas draw` writes `$constraints`) is judged by its titles as written. Backlog is a corral
// 400 × 300 at (100, 100), of the type Task.

private let backlogRect = CGRect(x: 100, y: 100, width: 400, height: 300)

@MainActor private func rename(_ id: ShapeID, to title: String, on h: EditorHarness) {
    h.editor.transact("Rename") { $0.update(id) { $0[TitleProperty.self] = title } }
}

/// The faces a type's Rules tab needs: the translator (a query box's words) and Constraints' panel.
@MainActor private func facesPlugins() -> [any CanvasPlugin] {
    [QueryTranslationPlugin(prompt: "Write a query for the words.", referenceRule: "The query is stored and run later.",
                            accepts: "The words name which shapes {holder} accepts."), ConstraintFacesPlugin()]
}

/// What the Rules tab of a shape shows of its constraints' queries: the boxes of the real panel over a real type note (or frame),
/// in an unshown window, in reading order (through `ConstraintBoxes.shown`).
@MainActor private func tabQueries(of id: ShapeID, on h: EditorHarness) throws -> [String] {
    let panel = RulesWindow(h)
    defer { panel.window.close() }
    try panel.show(id)
    panel.window.spin { !panel.boxes.isEmpty }
    return panel.boxes.map(\.string)
}

/// The type Task holding "only tasks", Backlog of it with a task inside, a task and a plain note outside.
@MainActor private func board() throws -> (h: EditorHarness, task: ShapeID, backlog: ShapeID, inside: ShapeID, outside: ShapeID, plain: ShapeID) {
    let h = try typeConstraintHarness(facesPlugins())
    let task = h.type("Task", [onlyTasks], at: CGPoint(x: 40, y: 480))
    let backlog = h.frame("Backlog", backlogRect, of: [task])
    let inside = h.note("Inside", of: [task], at: CGPoint(x: 150, y: 150), in: backlog)
    let outside = h.note("Outside", of: [task], at: CGPoint(x: 540, y: 250)), plain = h.note("Plain", at: CGPoint(x: 540, y: 150))
    h.settle()
    return (h, task, backlog, inside, outside, plain)
}

@MainActor let typeConstraintNamesTests = Suite("A type renamed: what its constraints name is the same type", [
    test("a type's list: Task renamed Chore, the chores inside stay unflagged, a chore dragged in is accepted, a plain note refused; undo") {
        let (h, task, backlog, inside, outside, plain) = try board()
        let list = try require(h.writer.constraints(of: .shape(task)))
        expectEqual(list.first?.names, ["Task": task], "bound as it was written")
        expectEqual(h.issues(of: inside), [])
        rename(task, to: "Chore", on: h)
        h.settle()
        expectEqual(h.issues(of: inside), [], "the chores inside are still tasks")
        expectEqual(h.index.breakers(of: .shape(backlog)), [])
        expectEqual(h.writer.constraints(of: .shape(task)), list, "nothing written")
        expectEqual(h.editor.undoHistory.undoName, "Rename", "no step of its own")
        expectEqual(try tabQueries(of: task, on: h), ["only tasks", #":is-a("Chore")"#, ""], "the type's Rules tab shows the new name")
        h.drop(from: CGPoint(x: 600, y: 276), to: CGPoint(x: 300, y: 280))
        expectEqual(h.editor.holder(of: outside), backlog, "a chore dragged in is accepted")
        h.drop(from: CGPoint(x: 600, y: 176), to: CGPoint(x: 400, y: 330))
        expectEqual(h.editor.holder(of: plain), nil, "a plain note is refused")
        expectEqual(h.editor.announcements.last, "Backlog accepts only tasks.", "the words are the person's")
        h.settle()
        expectEqual(h.issues(of: outside), [])
        h.editor.undo()
        h.editor.undo()
        h.editor.undo()
        h.settle()
        expectEqual(h.editor.document[task]?[TitleProperty.self], "Task", "the rename undone")
        expectEqual(try tabQueries(of: task, on: h), ["only tasks", #":is-a("Task")"#, ""], "and the rename undone")
        expectEqual(h.issues(of: inside), [])
    },
    test("a frame's own list and the root's the same: judged by the type, whatever it is called") {
        let h = try typeConstraintHarness()
        let task = h.type("Task", at: CGPoint(x: 40, y: 480))
        let frame = h.frame("Backlog", backlogRect)
        h.writer.add(onlyTasks, to: .shape(frame))
        h.writer.add(onlyTasks, to: .root)
        let inside = h.note("Inside", of: [task], at: CGPoint(x: 150, y: 150), in: frame)
        let top = h.note("Top", of: [task], at: CGPoint(x: 600, y: 250))
        let other = h.note("Other", at: CGPoint(x: 600, y: 350))
        h.settle()
        expectEqual(h.index.breakers(of: .shape(frame)), [])
        let atTop: Set<ShapeID> = [task, frame, other]
        expectEqual(h.index.breakers(of: .root), atTop, "on the board in no frame, the root's reaches: the type, the frame and a plain note break it")
        rename(task, to: "Chore", on: h)
        h.settle()
        expectEqual(h.issues(of: inside), [], "the frame's own list: a chore inside is a task")
        expectEqual(h.issues(of: top), [], "the root's list")
        expectEqual(h.index.breakers(of: .root), atTop, "no one else is flagged: the chore on the board is not")
        expectEqual(h.writer.constraints(of: .shape(frame))?.first?.names, ["Task": task])
        expectEqual(h.file[RootConstraintsProperty.self].constraints.first?.names, ["Task": task])
        // Judged by its titles as written, a list nothing bound is flagged by the rename.
        h.editor.undo()
        let unbound = h.frame("Unbound", CGRect(x: 100, y: 500, width: 300, height: 100), [onlyTasks])
        let there = h.note("There", of: [task], at: CGPoint(x: 120, y: 520), in: unbound)
        h.settle()
        expectEqual(h.issues(of: there), [])
        rename(task, to: "Chore", on: h)
        h.settle()
        expectEqual(h.issues(of: there), ["Unbound accepts only tasks."], "a list with no names is judged by its titles as written")
    },
    test("a supertype's list reaches the frame of a type built on it, and a rename of the supertype changes no verdict") {
        let h = try typeConstraintHarness(facesPlugins())
        let work = h.type("Work", [onlyWork], at: CGPoint(x: 40, y: 480))
        let task = h.type("Task", on: [work], at: CGPoint(x: 300, y: 480))
        let backlog = h.frame("Backlog", backlogRect, of: [task])
        let inside = h.note("Inside", of: [task], at: CGPoint(x: 150, y: 150), in: backlog)
        let deep = h.frame("Sub", CGRect(x: 200, y: 200, width: 100, height: 80), in: backlog)
        let nested = h.note("Nested", of: [work], at: CGPoint(x: 210, y: 210), in: deep)
        h.settle()
        expectEqual(h.issues(of: inside), [])
        rename(work, to: "Job", on: h)
        h.settle()
        expectEqual(h.issues(of: inside), [], "a task is still work")
        expectEqual(h.issues(of: nested), [], "anywhere inside: the nested one too")
        let list = try require(h.index.sources(of: .shape(backlog)).first?.constraints.first)
        expectEqual(list.names, ["Work": work])
        expect(try tabQueries(of: backlog, on: h).contains(#":is-a("Job")"#), "the frame's Rules tab shows the supertype's list as named now")
        // A plain note made inside is flagged by the one that reaches it, the type's own words.
        h.retype(nested, to: [])
        h.settle()
        expectEqual(h.issues(of: nested), ["Backlog accepts only work."], "flagged by the list that reaches it, in the type's own words")
    },
    test("a note a person makes in the frame is made a Chore by the fit, whatever the type was called when its list was written") {
        let (h, task, backlog, _, _, _) = try board()
        rename(task, to: "Chore", on: h)
        h.settle()
        let placement = try require(h.editor.registry.placement(for: Memo.kind))
        h.editor.place(placement, at: CGPoint(x: 300, y: 250))
        let made = try require(h.editor.document.shapes.last)
        expectEqual(h.editor.holder(of: made.id), backlog)
        expectEqual(h.editor.typesOf(made.id), [task], "a Chore")
        h.settle()
        expectEqual(h.issues(of: made.id), [])
    },
    test("a list written as a schema is, as `canvas draw` writes `$constraints`, with no names: judged by its titles as written until the writer writes it again") {
        let h = try typeConstraintHarness(facesPlugins())
        let task = h.type("Task", at: CGPoint(x: 40, y: 480))
        let backlog = h.frame("Backlog", backlogRect, of: [task])
        let inside = h.note("Inside", of: [task], at: CGPoint(x: 150, y: 150), in: backlog)
        let text = try require(h.editor.schema(task))
        let written = try require(TypeConstraintBook.text(text, setting: [onlyTasks]))
        h.editor.transact("Write schema") { $0.update(task) { $0[TypeSchemaProperty.self] = SchemaText(written) } }
        h.settle()
        let list = try require(h.index.sources(of: .shape(backlog)).first?.constraints)
        expectEqual(list.map(\.names), [[:]], "nothing bound it")
        expectEqual(h.issues(of: inside), [])
        rename(task, to: "Chore", on: h)
        h.settle()
        expectEqual(h.issues(of: inside), ["Backlog accepts only tasks."], "judged by the title as written: nothing is called Task")
        expectEqual(try tabQueries(of: task, on: h), ["only tasks", #":is-a("Task")"#, ""], "the tab shows it as written")
        // Written again by the app's writer: bound, by what it names now.
        let again = try require(h.writer.constraints(of: .shape(task))?.first)
        expect(h.writer.setQuery(#":is-a("Chore")"#, of: again, in: .shape(task), rebinding: true))
        h.settle()
        expectEqual(h.writer.constraints(of: .shape(task))?.first?.names, ["Chore": task])
        expectEqual(h.issues(of: inside), [])
    },
    test("a type that a list names is deleted: the list is judged by the title as written; undone, by id again") {
        let h = try typeConstraintHarness()
        let task = h.type("Task", at: CGPoint(x: 40, y: 480))
        let sprint = h.type("Sprint", [Constraint(says: "only tasks", query: #":is-a("Task")"#)], at: CGPoint(x: 300, y: 480))
        let week = h.frame("Week", CGRect(x: 100, y: 100, width: 400, height: 300), of: [sprint])
        h.settle()
        let list = try require(h.writer.constraints(of: .shape(sprint)))
        let bound = try require(list.first)
        expectEqual(bound.names, ["Task": task])
        expectEqual(h.index.text(of: bound), #":is-a(#\#(task.description.uppercased()))"#)
        h.editor.transact("Delete") { $0.delete([task]) }
        h.settle()
        expectEqual(h.index.text(of: bound), #":is-a("Task")"#, "the title as written")
        expectEqual(h.index.constraints(of: .shape(week)).count, 1, "the frame still has the list")
        h.editor.undo()
        h.settle()
        expectEqual(h.index.text(of: bound), #":is-a(#\#(task.description.uppercased()))"#, "by id again")
        expectEqual(h.writer.constraints(of: .shape(sprint)), list)
    },
    test("a type that holds a list and the type it names, copied together: the copy's list names the copy of the type") {
        let h = try typeConstraintHarness()
        let task = h.type("Task", at: CGPoint(x: 40, y: 480))
        let sprint = h.type("Sprint", [Constraint(says: "only tasks", query: #":is-a("Task")"#)], at: CGPoint(x: 300, y: 480))
        let week = h.frame("Week", CGRect(x: 100, y: 100, width: 400, height: 300), of: [sprint])
        let inside = h.note("Inside", of: [task], at: CGPoint(x: 150, y: 150), in: week)
        h.settle()
        expectEqual(h.writer.constraints(of: .shape(sprint))?.first?.names, ["Task": task])
        let all = [task, sprint, week, inside]
        var map: [ShapeID: ShapeID] = [:]
        for id in all { map[id] = ShapeID() }
        let copies = try all.map { id -> AnyShapeRecord in
            try require(try require(h.editor.document[id]).remappingReferences({ map[$0] }, in: h.editor.shapeContext))
        }
        h.editor.transact("Paste") { t in
            for (index, record) in copies.enumerated() {
                t.insert(record.copy(as: map[all[index]] ?? ShapeID(), container: index == 3 ? map[week] : nil))
            }
        }
        h.settle()
        let sprintCopy = try require(map[sprint]), taskCopy = try require(map[task]), insideCopy = try require(map[inside])
        expectEqual(h.editor.typesOf(insideCopy), [taskCopy], "the note's copy is of the task's copy")
        expectEqual(h.writer.constraints(of: .shape(sprintCopy))?.first?.names, ["Task": taskCopy], "the copy's list names the copy")
        expectEqual(h.issues(of: insideCopy), [], "the copied note in the copied frame fits as the original does")
        // A type copied alone keeps naming the original.
        let alone = ShapeID()
        let record = try require(try require(h.editor.document[sprint]).remappingReferences({ $0 == sprint ? alone : nil }, in: h.editor.shapeContext))
        var names: [ShapeID] = []
        SchemaText(try require(record[TypeSchemaProperty.self]).text).forEachNamedShape { names.append($0) }
        expectEqual(names, [task], "the rest are kept")
    },
    test("a type's list as Types writes it reads back as Constraints' codec has it, every member set") {
        let task = ShapeID()
        let full = Constraint(says: "only tasks", query: #":is-a("Task")"#, reach: .descendants, names: ["Task": task])
        let plain = Constraint(says: "any", query: "tile")
        let words = Constraint(says: "no query")
        let written = ConstraintList([full, plain, words]).jsonText
        let read = try JSONDecoder().decode(ConstraintList.self, from: Data(written.utf8))
        expectEqual(read.constraints, [full, plain, words])
        expectEqual(read, ConstraintList([full, plain, words]))
    },
])

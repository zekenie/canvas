@_spi(Host) import Canvas
import CanvasTesting
import Constraints
import CoreGraphics
import Foundation
import TestKit
import Titles
import Types
import Validation

// The whole path, Types, Constraints and the core's admission and placement fit together: a frame of a type, its type's
// constraint "only tasks" (`:is-a("Task")`), a misfit dragged in refused, one made there made a task, and one retyped inside
// flagged. Backlog is a corral 400 × 300 at (100, 100), of the type Task.

private let backlogRect = CGRect(x: 100, y: 100, width: 400, height: 300)

/// A board: the type Task holding "only tasks", Backlog of it, a plain memo and a task memo outside it.
@MainActor private func board() throws -> (h: EditorHarness, task: ShapeID, backlog: ShapeID, plain: ShapeID, chore: ShapeID) {
    let h = try typeConstraintHarness()
    let task = h.type("Task", [onlyTasks], at: CGPoint(x: 40, y: 480))
    let backlog = h.frame("Backlog", backlogRect, of: [task])
    let plain = h.note("Plain", at: CGPoint(x: 540, y: 150)), chore = h.note("Chore", of: [task], at: CGPoint(x: 540, y: 250))
    h.settle()
    return (h, task, backlog, plain, chore)
}

@MainActor let typeConstraintPathTests = Suite("A type's constraints, from the type to the frame", [
    test("a misfit dragged into a frame of the type goes back, no step, the frame says why; a task goes in") {
        let (h, _, backlog, plain, chore) = try board()
        let step = h.editor.undoHistory.undoName
        h.editor.setTool("select")
        h.press(at: CGPoint(x: 660, y: 176))
        h.drag(to: CGPoint(x: 500, y: 200))
        h.drag(to: CGPoint(x: 300, y: 250))
        expectEqual(h.editor.hintedShapeID, nil, "no outline over a place that would refuse it")
        h.release()
        expectEqual(h.origin(of: plain), CGPoint(x: 540, y: 150), "back where it was")
        expectEqual(h.editor.holder(of: plain), nil)
        expectEqual(h.editor.announcements.last, "Backlog accepts only tasks.")
        expectEqual(h.editor.undoHistory.undoName, step, "no step")
        h.drop(from: CGPoint(x: 660, y: 276), to: CGPoint(x: 300, y: 280))
        expectEqual(h.editor.holder(of: chore), backlog, "a task is accepted")
        h.settle()
        expectEqual(h.issues(of: chore), [])
    },
    test("a shape retyped inside is flagged, with the type's words, and fine again when retyped; a list added to the type reaches a full frame") {
        let (h, task, backlog, _, chore) = try board()
        let inside = h.note("Inside", of: [task], at: CGPoint(x: 150, y: 150), in: backlog)
        h.settle()
        expectEqual(h.issues(of: inside), [])
        h.retype(inside, to: [])
        h.settle()
        expectEqual(h.issues(of: inside), ["Backlog accepts only tasks."])
        expectEqual(h.index.breakers(of: .shape(backlog)), [inside])
        let issue = try require(h.editor.validation?.results[inside]?.issues.first)
        expect(issue.severity == .error)
        expectEqual(issue.actions.map(\.title), ["Move Out", "Show Constraint"])
        h.retype(inside, to: [task])
        h.settle()
        expectEqual(h.issues(of: inside), [])
        // A constraint added to the type: a frame that was full of things that break it flags them, none moving.
        let other = h.type("Bug", at: CGPoint(x: 300, y: 480))
        let bugs = h.frame("Bugs", CGRect(x: 100, y: 450, width: 100, height: 100), of: [other])
        let there = h.note("There", at: CGPoint(x: 110, y: 460), in: bugs)
        _ = chore
        h.settle()
        expectEqual(h.issues(of: there), [])
        h.writer.add(Constraint(says: "only tasks", query: ":is-a(\"Task\")"), to: .shape(other))
        h.settle()
        expectEqual(h.issues(of: there), ["Bugs accepts only tasks."], "added to the type: heard by the frame with no commit to it")
        expectEqual(h.origin(of: there), CGPoint(x: 110, y: 460), "nothing moved")
        h.writer.removeAll(from: .shape(other))
        h.settle()
        expectEqual(h.issues(of: there), [])
    },
    test("a note a person makes in a frame of the type is made a task: the tool's kind stays, what the constraint's query says it is is written") {
        let (h, task, backlog, _, _) = try board()
        let placement = try require(h.editor.registry.placement(for: Memo.kind))
        h.editor.place(placement, at: CGPoint(x: 300, y: 250))
        let made = try require(h.editor.document.shapes.last)
        expectEqual(made.kind, Memo.kind)
        expectEqual(h.editor.holder(of: made.id), backlog)
        expectEqual(h.editor.typesOf(made.id), [task], "a task")
        expectEqual(h.editor.undoHistory.undoName, "Add Memo", "in the placement's own step")
        h.settle()
        expectEqual(h.issues(of: made.id), [])
        // Outside it, a note is made as it is.
        h.editor.place(placement, at: CGPoint(x: 650, y: 500))
        let free = try require(h.editor.document.shapes.last)
        expectEqual(h.editor.typesOf(free.id), [])
    },
    test("a type's list reaches a frame of a type built on it, the more general type's first: a task fitted to Work's constraint too") {
        let h = try typeConstraintHarness()
        let work = h.type("Work", [Constraint(says: "only work", query: ":is-a(\"Work\")")], at: CGPoint(x: 40, y: 480))
        let task = h.type("Task", on: [work], [Constraint(says: "only tasks", query: ":is-a(\"Task\")")], at: CGPoint(x: 300, y: 480))
        let backlog = h.frame("Backlog", backlogRect, of: [task])
        h.settle()
        let placement = try require(h.editor.registry.placement(for: Memo.kind))
        h.editor.place(placement, at: CGPoint(x: 300, y: 250))
        let made = try require(h.editor.document.shapes.last)
        expectEqual(h.editor.holder(of: made.id), backlog)
        expectEqual(h.editor.typesOf(made.id), [work, task], "Work's written first, then Task's")
        h.settle()
        expectEqual(h.issues(of: made.id), [], "it fits both")
    },
])

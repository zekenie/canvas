import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import Clipboard
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
import StickyNotes
import Subboards
import TestKit
import Titles
import Types
import Validation

private let pTaskSchema = #"{"type": "object", "properties": {"status": {"type": "string"}}}"#
private let pBugSchema = #"{"type": "object", "properties": {"severity": {"type": "string"}}}"#
private let pOnlyTasks = Constraint(says: "only tasks", query: ":is-a(\"Task\")")
private let pNoBugs = Constraint(says: "no bugs", query: ":not(:is-a(\"Bug\"))")
private let pOnlyBugs = Constraint(says: "only bugs", query: ":is-a(\"Bug\")")

@MainActor private final class Probe {
    let h: EditorHarness
    let model: ScriptedLanguageModel
    let pasteboard: NSPasteboard
    var editor: CanvasEditor { h.editor }
    var task = ShapeID(), bug = ShapeID(), sprint = ShapeID(), tasks = ShapeID(), bugs = ShapeID()
    static let tasksRect = CGRect(x: 40, y: 40, width: 420, height: 420)
    static let bugsRect = CGRect(x: 500, y: 40, width: 420, height: 420)

    init(model: ScriptedLanguageModel = ScriptedLanguageModel(), viewport: CGSize = CGSize(width: 1500, height: 900)) {
        self.model = model
        let pasteboard = NSPasteboard.withUniqueName()
        self.pasteboard = pasteboard
        h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: model) }
        editor.viewportDidResize(to: viewport)
        task = editor.addTypeNote(pTaskSchema, title: "Task", frame: CGRect(x: 500, y: 520, width: 200, height: 200))
        bug = editor.addTypeNote(pBugSchema, title: "Bug", frame: CGRect(x: 720, y: 520, width: 200, height: 200))
        sprint = editor.addTypeNote(TypeConstraintBook.text(#"{"type": "object", "properties": {}}"#, setting: [pOnlyTasks]) ?? "",
                                    title: "Sprint", frame: CGRect(x: 1160, y: 520, width: 200, height: 200))
        tasks = frame("Tasks", Probe.tasksRect)
        editor.addTypeLink(sprint, to: tasks)
        bugs = frame("Bugs", Probe.bugsRect, [pOnlyBugs])
        settle()
    }

    deinit { MainActor.assumeIsolated { pasteboard.releaseGlobally() } }

    @discardableResult
    func frame(_ title: String, _ rect: CGRect, _ constraints: [Constraint] = []) -> ShapeID {
        var record = ShapeRecord(Frame(frame: rect))
        record[TitleProperty.self] = title
        if !constraints.isEmpty { record[ConstraintsProperty.self] = ConstraintList(constraints) }
        editor.transact { $0.insert(record) }
        return record.id
    }

    func note(_ rect: CGRect, types: [ShapeID] = [], title: String? = nil) -> ShapeID {
        var record = AnyShapeRecord(ShapeRecord(StickyNote(frame: rect, text: "n")))
        if !types.isEmpty { record[IsAProperty.self] = types.map(TypeLink.init) }
        if let title { record[TitleProperty.self] = title }
        editor.transact("Add") { $0.insert(record); _ = $0.settle([record.id]) }
        return record.id
    }

    func settle() {
        let index = editor.constraintIndex
        expect(spinRunLoop(until: { index?.isSettled ?? true }, timeout: 5), "the constraints settle")
    }

    func types(of id: ShapeID) -> [ShapeID] { editor.document[id]?[IsAProperty.self]?.map(\.shape) ?? [] }
    func issues(of id: ShapeID) -> [String] {
        _ = editor.validation?.results
        return (editor.validation?.result(for: id)?.issues ?? []).map(\.message)
    }
    func funnel(of id: ShapeID) -> AdornmentFrame? { editor.adornmentFrames(of: id).first { $0.adornment == .of(ConstraintFunnel.self) } }
}


/// The ways in the shipped list reaches that the first suite leaves: /constrain undone and redone, three breakers walked, the root, /bulk-create, a tool drag, a chain.
@MainActor let constraintsFlowsShippedTests = Suite("Constraints flows shipped", [
    test("/constrain undo and redo") {
        let model = ScriptedLanguageModel(answers: [#":is-a("Task")"#])
        let p = Probe(model: model)
        let backlog = p.frame("Backlog", CGRect(x: 40, y: 760, width: 420, height: 300))
        let commands = try require(p.editor.slashCommands)
        let t = try require(commands.answer("constrain", for: .selection([backlog]), with: "only tasks"))
        expectEqual(try awaitResult { await t.value }, .done)
        p.settle()
        expectEqual(p.editor.constraintWriter?.constraints(of: .shape(backlog))?.count, 1)
        expectEqual(p.editor.undoHistory.undoName, "Add Constraint")
        p.editor.undo()
        p.settle()
        expectEqual(p.editor.constraintWriter?.constraints(of: .shape(backlog)) ?? [], [], "undone")
        expectEqual(p.funnel(of: backlog) == nil, true, "no funnel after undo")
        p.editor.redo()
        p.settle()
        expectEqual(p.editor.constraintWriter?.constraints(of: .shape(backlog))?.count, 1, "redone")
        expect(p.funnel(of: backlog) != nil, "funnel back after redo")
    },
    test("three breakers: Issues walk reads 1 of 3; funnel red with 3; tooltip; click opens Rules tab; Show Constraint") {
        let p = Probe()
        let a = p.note(CGRect(x: 60, y: 60, width: 100, height: 100), types: [p.task], title: "A")
        let b = p.note(CGRect(x: 200, y: 60, width: 100, height: 100), types: [p.task], title: "B")
        let c = p.note(CGRect(x: 60, y: 200, width: 100, height: 100), types: [p.task], title: "C")
        p.settle()
        expectEqual([a, b, c].map { p.editor.holder(of: $0) }, [p.tasks, p.tasks, p.tasks])
        p.editor.transact("Is") { t in for id in [a, b, c] { t.update(id) { $0[IsAProperty.self] = [TypeLink(p.bug)] } } }
        p.settle()
        expectEqual([a, b, c].map { p.issues(of: $0) }, Array(repeating: ["Tasks accepts only tasks."], count: 3))
        let panel = try require(p.editor.detailPanel)
        let lines = panel.layout(for: try require(p.editor.document[a])).statuses(in: .of(IssuesTab.self))
        expectEqual(lines.first?.actions.map(\.title), ["Move Out", "Show Constraint", "1 of 3"])
        let funnel = try require(p.funnel(of: p.tasks))
        expectEqual(funnel.label.text, "3")
        p.editor.setTool(.select)
        p.h.move(to: p.h.view(CGPoint(x: funnel.rect.midX, y: funnel.rect.midY)))
        expectEqual(p.editor.pointerHelp, "Accepts: only tasks\n3 not accepted")
        p.editor.selectedShapeIDs = [p.bugs]
        p.h.click()
        p.h.wait(0)
        p.h.wait(16)
        expectEqual(p.editor.selectedShapeIDs, [p.tasks], "the click selects Tasks")
        expectEqual(panel.chosenTab(for: Frame.kind), .of(RulesTab.self))
        let sections = panel.layout(for: try require(p.editor.document[p.tasks])).sections(in: .of(RulesTab.self)).map(\.section)
        expectEqual(sections, ["constraints", "not-accepted"])
        // Show Constraint from the bug's issue.
        p.editor.selectedShapeIDs = [a]
        panel.choose(.of(IssuesTab.self), for: StickyNote.kind)
        try require(p.editor.validation?.result(for: a)?.issues.first?.actions.first { $0.title == "Show Constraint" }).perform()
        p.h.wait(0)
        p.h.wait(16)
        expectEqual(p.editor.selectedShapeIDs, [p.tasks], "Show Constraint selects Tasks")
        expectEqual(panel.chosenTab(for: Frame.kind), .of(RulesTab.self))
    },
    test("a frame of a type built on another: the supertype's list first, both judged") {
        let p = Probe()
        let work = p.editor.addTypeNote(TypeConstraintBook.text(#"{"type": "object", "properties": {}}"#, setting: [pNoBugs]) ?? "",
                                        title: "Work", frame: CGRect(x: 1160, y: 760, width: 200, height: 200))
        p.editor.addTypeLink(work, to: p.sprint)
        p.settle()
        let placed = p.editor.constraintIndex?.constraints(of: .shape(p.tasks)) ?? []
        expectEqual(placed.map(\.constraint), [pNoBugs, pOnlyTasks], "the supertype's first")
        expectEqual(placed.map(\.origin), [.inherited(work), .inherited(p.sprint)])
        // Sprint's Rules tab: holder-constraints with Work's under its pill.
        let sources = p.editor.typeConstraints?.sources(of: p.sprint) ?? []
        expectEqual(sources.map(\.holder), [work])
        let sections = try require(p.editor.detailPanel).layout(for: try require(p.editor.document[p.sprint])).sections(in: .of(RulesTab.self)).map(\.section)
        // A bug in Tasks breaks both: two issues.
        let b = p.note(CGRect(x: 60, y: 60, width: 100, height: 100), types: [p.task])
        p.settle()
        p.editor.transact("Is") { $0.update(b) { $0[IsAProperty.self] = [TypeLink(p.bug)] } }
        p.settle()
        expectEqual(p.issues(of: b), ["Tasks accepts no bugs.", "Tasks accepts only tasks."])
        let funnel = try require(p.funnel(of: p.tasks))
        expectEqual(funnel.label.text, "1", "one shape, not two constraints")
    },
    test("the root: /constrain with nothing selected writes the root's list; no funnel; /unconstrain; undo") {
        let model = ScriptedLanguageModel(answers: [#":is-a("Task")"#])
        let p = Probe(model: model)
        let loose = p.note(CGRect(x: 1400, y: 100, width: 120, height: 120), types: [p.bug], title: "Loose")
        p.settle()
        p.editor.selectedShapeIDs = []
        let commands = try require(p.editor.slashCommands)
        let everything = SlashTarget.everything(p.editor.document.shapes.map(\.id))
        let t = try require(commands.answer("constrain", for: everything, with: "only tasks"))
        expectEqual(try awaitResult { await t.value }, .done)
        p.settle()
        expectEqual(p.editor.constraintWriter?.constraints(of: .root)?.map(\.says), ["only tasks"])
        expectEqual(p.issues(of: loose), ["This board accepts only tasks."])
        expectEqual(p.editor.validation?.result(for: loose)?.issues.first?.actions.map(\.title), ["Show Constraint"], "the root's issue shows its constraint, and has no Move Out")
        p.editor.undo()
        p.settle()
        expectEqual(p.editor.constraintWriter?.constraints(of: .root) ?? [], [])
        expectEqual(p.issues(of: loose), [])
    },
    test("/bulk-create two notes clicked down inside Tasks arrive Tasks, one step") {
        let p = Probe()
        p.editor.selectedShapeIDs = []
        let commands = try require(p.editor.slashCommands)
        let command = try require(commands.command(named: "bulk-create", for: .everything(p.editor.document.shapes.map(\.id))))
        let before = Set(p.editor.document.shapes.map(\.id))
        expect(commands.run(command, with: SlashArguments("Alpha, Beta")))
        p.h.move(to: p.h.view(CGPoint(x: 160, y: 150)))
        p.h.click(at: p.h.view(CGPoint(x: 160, y: 150)))
        p.settle()
        let made = p.editor.document.shapes.filter { !before.contains($0.id) }.map(\.id)
        expectEqual(made.count, 2)
        expectEqual(made.map { p.types(of: $0) }, [[p.task], [p.task]])
        p.editor.undo()
        expectEqual(made.compactMap { p.editor.document[$0] }.count, 0, "one step")
    },
    test("the Note tool pressed outside and dragged into Tasks arrives a Task; undo is one step") {
        let p = Probe()
        let step = p.editor.undoHistory.undoName
        let before = Set(p.editor.document.shapes.map(\.id))
        p.editor.setTool(ToolID(placing: StickyNote.kind))
        p.h.press(at: p.h.view(CGPoint(x: 1450, y: 300)))
        p.h.drag(to: p.h.view(CGPoint(x: 800, y: 300)))
        p.h.drag(to: p.h.view(CGPoint(x: 250, y: 250)))
        p.h.release()
        p.editor.endEditing()
        p.settle()
        let made = try require(p.editor.document.shapes.first { !before.contains($0.id) }?.id)
        expectEqual(p.editor.holder(of: made), p.tasks)
        expectEqual(p.types(of: made), [p.task])
        p.editor.undo()
        expectEqual(p.editor.document[made] == nil, true)
        expectEqual(p.editor.undoHistory.undoName, step)
    },
])

import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Constraints
import CoreGraphics
import DetailPanel
import Foundation
import Frames
import LanguageModels
import Mentions
import Selection
import SlashCommands
import StickyNotes
import Subboards
import TestKit
import Titles
import Transform
import Types
import Validation

// Constraints: the states of one track, added to `galleryStates` (GalleryTypesLook.swift) as `constraintStates`, files `Cons-*`:
// three frames side by side that say what they accept (a type's list, a frame's own), quiet and with a breaker in one; the Rules
// tab on a type and on a frame; a breaker's Issues line; and the cold first minute from each way in (`Cons-minute-*`): an empty
// frame, `/constrain only tasks` typed on it, a note made in it by the Note tool and by a double-click, a plain note dragged over it
// and back, a shape retyped inside, the type's tab, the board zoomed out.

private let taskSchema = #"{"type": "object", "properties": {"status": {"type": "string"}, "owner": {"type": "string"}}}"#
private let bugSchema = #"{"type": "object", "properties": {"severity": {"type": "string"}, "steps": {"type": "string"}}}"#
private let personSchema = #"{"type": "object", "properties": {"name": {"type": "string"}, "email": {"type": "string"}}}"#
private let onlyTasks = Constraint(says: "only tasks", query: ":is-a(\"Task\")")
private let onlyBugs = Constraint(says: "only bugs", query: ":is-a(\"Bug\")")
private let onlyPeople = Constraint(says: "only people", query: ":is-a(\"Person\")")
private let noBugs = Constraint(says: "no bugs", query: ":not(:is-a(\"Bug\"))")
private let big = CGSize(width: 1300, height: 700)
private let panelSize = CGSize(width: 320, height: 640)

/// The ids of a board: the types, and the frames.
private struct Scene {
    var task = ShapeID(), bug = ShapeID(), person = ShapeID(), sprint = ShapeID(), work = ShapeID()
    var tasks = ShapeID(), bugs = ShapeID(), people = ShapeID()
}

extension GalleryStage {
    /// Waits until every standing query of the constraints has answered, and the canvas has seen it.
    func settleConstraints() {
        let index = editor.constraintIndex
        _ = spinRunLoop(until: { index?.isSettled ?? true }, timeout: 5)
        spin(0.1)
    }

    /// A type note at the bottom of the board.
    func typeAt(_ title: String, _ schema: String, x: CGFloat) -> ShapeID {
        editor.addTypeNote(schema, title: title, frame: CGRect(x: x, y: 450, width: 200, height: 200))
    }

    /// A frame titled `title`, holding `constraints` of its own.
    func constrainedFrame(_ title: String, _ rect: CGRect, _ constraints: [Constraint] = [], of types: [ShapeID] = []) -> ShapeID {
        var record = ShapeRecord(Frame(frame: rect))
        record[TitleProperty.self] = title
        if !constraints.isEmpty { record[ConstraintsProperty.self] = ConstraintList(constraints) }
        editor.transact { $0.insert(record) }
        for type in types { editor.addTypeLink(type, to: record.id) }
        return record.id
    }

    /// A click with the Note tool at a view point: the note is made there, then edited no more.
    @discardableResult
    func noteTool(at point: CGPoint, titled title: String? = nil) -> ShapeID? {
        let before = Set(editor.document.shapes.map(\.id))
        editor.setTool(ToolID(placing: StickyNote.kind))
        press(at: point)
        release(at: point)
        let made = editor.document.shapes.first { !before.contains($0.id) }?.id
        editor.endEditing()
        editor.setTool(.select)
        if let made, let title { editor.transact("Title") { $0.update(made) { $0[TitleProperty.self] = title } } }
        settleConstraints()
        return made
    }

    func retype(_ id: ShapeID, to type: ShapeID?) {
        editor.transact("Is") { $0.update(id) { $0[IsAProperty.self] = type.map { [TypeLink($0)] } } }
        settleConstraints()
    }
}

/// Three frames that say what they accept: Tasks of the type Sprint (whose `$constraints` say only tasks), Bugs and People with lists
/// of their own, and the types they name along the bottom.
@MainActor private func threeFrames(_ stage: GalleryStage) throws -> Scene {
    var scene = Scene()
    scene.task = stage.typeAt("Task", taskSchema, x: 40)
    scene.bug = stage.typeAt("Bug", bugSchema, x: 270)
    scene.person = stage.typeAt("Person", personSchema, x: 500)
    scene.sprint = stage.typeAt("Sprint", try require(TypeConstraintBook.text(#"{"type": "object", "properties": {}}"#, setting: [onlyTasks])), x: 730)
    scene.tasks = stage.constrainedFrame("Tasks", CGRect(x: 40, y: 60, width: 400, height: 360), of: [scene.sprint])
    scene.bugs = stage.constrainedFrame("Bugs", CGRect(x: 460, y: 60, width: 400, height: 360), [onlyBugs])
    scene.people = stage.constrainedFrame("People", CGRect(x: 880, y: 60, width: 400, height: 360), [onlyPeople])
    stage.settleConstraints()
    return scene
}

/// The same with a note made in each by the Note tool.
@MainActor private func threeFramesMade(_ stage: GalleryStage) throws -> (scene: Scene, notes: [ShapeID]) {
    let scene = try threeFrames(stage)
    let notes = [stage.noteTool(at: CGPoint(x: 240, y: 240), titled: "Fix login"), stage.noteTool(at: CGPoint(x: 660, y: 240), titled: "Crash on save"),
                 stage.noteTool(at: CGPoint(x: 1080, y: 240), titled: "Ann")]
    return (scene, try notes.map { try require($0, "a note is made") })
}

/// The picture of a shape's panel, selected, on a tab.
@MainActor private func panel(_ stage: GalleryStage, of id: ShapeID, tab: DetailTabID) throws -> GalleryOutput {
    .image(try stage.panelPicture(of: id, tab: tab, size: panelSize))
}

@MainActor private func rulesAndConstraints(_ stage: GalleryStage) throws -> (sprint: ShapeID, backlog: ShapeID, breaker: ShapeID) {
    let work = stage.typeAt("Work", try require(TypeConstraintBook.text(#"{"type": "object", "properties": {}}"#,
                                                                         setting: [Constraint(says: "only work", query: ":is-a(\"Work\")", reach: .descendants)])), x: 40)
    let rules = #"{"type": "object", "properties": {"$rules": {"const": [{"says": "Every sprint has a goal."}]}, "goal": {"type": "string"}}}"#
    let sprint = stage.typeAt("Sprint", try require(TypeConstraintBook.text(rules, setting: [onlyTasks, noBugs])), x: 270)
    stage.editor.addTypeLink(work, to: sprint)
    let backlog = stage.constrainedFrame("Backlog", CGRect(x: 40, y: 60, width: 400, height: 360),
                                         [Constraint(says: "no subboards", query: ":not(subboard)")], of: [sprint])
    let breaker = stage.editor.add(StickyNote(frame: CGRect(x: 80, y: 120, width: 160, height: 120), text: "Fix login"), title: "Fix login")
    stage.editor.put([breaker], in: backlog)
    stage.retype(breaker, to: stage.typeAt("Bug", bugSchema, x: 500))
    let tucked = stage.editor.add(Subboard(frame: CGRect(x: 240, y: 260, width: 180, height: 120)), title: "Archive")
    stage.editor.put([tucked], in: backlog)
    stage.settleConstraints()
    return (sprint, backlog, breaker)
}

/// A frame holding a subboard and a note that break the `list`.
@MainActor private func notAcceptedFrame(_ stage: GalleryStage, _ list: [Constraint]) throws -> ShapeID {
    _ = stage.typeAt("Task", taskSchema, x: 520)
    let backlog = stage.constrainedFrame("Backlog", CGRect(x: 40, y: 60, width: 440, height: 380), list)
    let note = stage.editor.add(StickyNote(frame: CGRect(x: 80, y: 120, width: 160, height: 120), text: "Plan"), title: "Plan")
    stage.editor.put([note], in: backlog)
    let tucked = stage.editor.add(Subboard(frame: CGRect(x: 240, y: 260, width: 180, height: 120)), title: "Archive")
    stage.editor.put([tucked], in: backlog)
    stage.settleConstraints()
    return backlog
}

/// A frame holding nothing, and the types, as a newcomer begins.
@MainActor private func beginning(_ stage: GalleryStage) -> (backlog: ShapeID, task: ShapeID) {
    let task = stage.typeAt("Task", taskSchema, x: 520)
    let backlog = stage.constrainedFrame("Backlog", CGRect(x: 40, y: 60, width: 440, height: 380))
    return (backlog, task)
}

/// `/constrain only tasks` typed on the frame and landed: the model answers `:is-a("Task")`.
@MainActor private func constrained(_ stage: GalleryStage, _ backlog: ShapeID) throws {
    stage.model.queue(#":is-a("Task")"#)
    _ = try stage.openBar(on: [backlog], typing: "constrain only tasks")
    stage.window.pressReturn()
    for _ in 0..<20 where (stage.editor.constraintWriter?.constraints(of: .shape(backlog)) ?? []).isEmpty { stage.spin(0.1) }
    stage.settleConstraints()
    guard !(stage.editor.constraintWriter?.constraints(of: .shape(backlog)) ?? []).isEmpty else { throw GalleryFailure("/constrain landed") }
}

private let minuteSize = CGSize(width: 760, height: 520)

/// A frame that accepts only tasks, holding a note retyped as a bug, turned into a subboard (`Transform`): the note is on its board,
/// and still a breaker there.
@MainActor private func turned(_ stage: GalleryStage) throws -> (backlog: ShapeID, note: ShapeID) {
    let (backlog, _) = beginning(stage)
    let bug = stage.typeAt("Bug", bugSchema, x: 40)
    try constrained(stage, backlog)
    let note = try require(stage.noteTool(at: CGPoint(x: 260, y: 260), titled: "Fix login"))
    stage.retype(note, to: bug)
    guard stage.editor.transforms?.turn([backlog], into: Subboard.kind) == true else { throw GalleryFailure("the frame turns into a subboard") }
    stage.settleConstraints()
    stage.editor.selectedShapeIDs = []
    return (backlog, note)
}

@MainActor
let constraintStates: [GalleryState] = [
    GalleryState("Cons-frames-quiet", "three frames that say what they accept, a note made in each by the Note tool: a Task, a Bug, a Person with their fields; the funnel chip quiet after each title", size: big) { stage in
        _ = try threeFramesMade(stage)
        stage.editor.selectedShapeIDs = []
        return .image(stage.render(at: .zero))
    },
    GalleryState("Cons-frames-red", "the same with the task retyped as a bug: its ring and Tasks' funnel red with the count", size: big) { stage in
        let (scene, notes) = try threeFramesMade(stage)
        stage.retype(notes[0], to: scene.bug)
        stage.editor.selectedShapeIDs = []
        return .image(stage.render(at: .zero))
    },
    GalleryState("Cons-rules-type", "a type's Rules tab: its English rules (Each sprint), then Inside each sprint: Work's list dimmed under its pill, then its own two and the box that adds one", size: panelSize) { stage in
        let (sprint, _, _) = try rulesAndConstraints(stage)
        return try panel(stage, of: sprint, tab: .of(RulesTab.self))
    },
    GalleryState("Cons-rules-frame", "a frame's Rules tab: what its types give it under their pills (Work's, Sprint's), its own row and the box that adds one, then Not accepted: the shapes inside that break one", size: panelSize) { stage in
        let (_, backlog, _) = try rulesAndConstraints(stage)
        return try panel(stage, of: backlog, tab: .of(RulesTab.self))
    },
    GalleryState("Cons-not-accepted-long", "a frame's Not accepted list where the first constraint's words are long: they are cut at the end, and the count (+1) stays whole after them", size: panelSize) { stage in
        let backlog = try notAcceptedFrame(stage, [Constraint(says: "only tasks that are small, owned by one person and due this week", query: ":is-a(\"Task\")"),
                                                     Constraint(says: "no subboards", query: ":not(subboard)")])
        return try panel(stage, of: backlog, tab: .of(RulesTab.self))
    },
    GalleryState("Cons-not-accepted-stop", "the same where the first words end in a full stop: the row says no subboards +1, with no stop before the count", size: panelSize) { stage in
        let backlog = try notAcceptedFrame(stage, [Constraint(says: "no subboards.", query: ":not(subboard)"), Constraint(says: "only tasks", query: ":is-a(\"Task\")")])
        return try panel(stage, of: backlog, tab: .of(RulesTab.self))
    },
    GalleryState("Cons-issue", "a breaker's Issues tab: Backlog accepts only tasks. with Move Out, Show Constraint and the walk's count", size: panelSize) { stage in
        let (_, _, breaker) = try rulesAndConstraints(stage)
        return try panel(stage, of: breaker, tab: .of(IssuesTab.self))
    },
    GalleryState("Cons-minute-1-empty-frame", "the cold first minute, way in 1: an empty board with one frame and the Task type; nothing says it can accept only tasks", size: minuteSize) { stage in
        _ = beginning(stage)
        return .image(stage.render(at: .zero))
    },
    GalleryState("Cons-minute-1-frame-menu", "the same frame's Shape menu: is there a way to constrain it from the menu?", size: minuteSize, isText: true) { stage in
        let (backlog, _) = beginning(stage)
        stage.editor.selectedShapeIDs = [backlog]
        return .text(stage.menuOutline(at: CGPoint(x: 260, y: 260)).joined(separator: "\n"))
    },
    GalleryState("Cons-minute-2-typed", "`/constrain only tasks` typed on the frame, before Return: the bar, its words", size: minuteSize) { stage in
        let (backlog, _) = beginning(stage)
        stage.model.queue(#":is-a("Task")"#)
        _ = try stage.openBar(on: [backlog], typing: "constrain only tasks")
        return .image(stage.render(at: .zero))
    },
    GalleryState("Cons-minute-2-waiting", "Return: the bar waits for the model, Interpreting", size: minuteSize) { stage in
        let (backlog, _) = beginning(stage)
        stage.model.queue(#":is-a("Task")"#)
        stage.model.holdsAnswers = true
        _ = try stage.openBar(on: [backlog], typing: "constrain only tasks")
        stage.window.pressReturn()
        stage.spin(0.2)
        return .image(stage.render(at: .zero))
    },
    GalleryState("Cons-minute-3-after", "the model's answer landed: the frame has its funnel, quiet", size: minuteSize) { stage in
        let (backlog, _) = beginning(stage)
        try constrained(stage, backlog)
        stage.editor.selectedShapeIDs = []
        return .image(stage.render(at: .zero))
    },
    GalleryState("Cons-minute-3-panel", "and the frame's panel: a Rules tab has appeared, with Accepts, the row and its query, and the box that adds one", size: panelSize) { stage in
        let (backlog, _) = beginning(stage)
        try constrained(stage, backlog)
        return try panel(stage, of: backlog, tab: .of(RulesTab.self))
    },
    GalleryState("Cons-minute-4-note-tool", "a note made in it with the Note tool: it arrives a Task, with its fields", size: minuteSize) { stage in
        let (backlog, _) = beginning(stage)
        try constrained(stage, backlog)
        _ = stage.noteTool(at: CGPoint(x: 260, y: 260))
        stage.editor.selectedShapeIDs = []
        return .image(stage.render(at: .zero))
    },
    GalleryState("Cons-minute-5-double-click", "and by a double-click inside it: the same", size: minuteSize) { stage in
        let (backlog, _) = beginning(stage)
        try constrained(stage, backlog)
        stage.hover(at: CGPoint(x: 260, y: 260))
        stage.editor.pointerDown(PointerEvent(location: CGPoint(x: 260, y: 260), timestamp: 4, clickCount: 2))
        stage.editor.pointerUp(PointerEvent(location: CGPoint(x: 260, y: 260), timestamp: 5, clickCount: 2))
        stage.editor.endEditing()
        stage.settleConstraints()
        stage.editor.selectedShapeIDs = []
        return .image(stage.render(at: .zero))
    },
    GalleryState("Cons-minute-6-drag-over", "a plain note dragged over the frame, held there before the drop: no outline on the frame, the note follows the pointer", size: minuteSize) { stage in
        let (backlog, _) = beginning(stage)
        try constrained(stage, backlog)
        _ = stage.editor.add(StickyNote(frame: CGRect(x: 520, y: 260, width: 160, height: 120), text: "Buy milk"), title: "Buy milk")
        stage.settleConstraints()
        stage.editor.setTool(.select)
        stage.press(at: CGPoint(x: 600, y: 320))
        stage.hover(at: CGPoint(x: 450, y: 300))
        stage.editor.pointerDragged(PointerEvent(location: CGPoint(x: 300, y: 260), timestamp: 3, clickCount: 1))
        stage.spin(0.1)
        return .image(stage.render(at: .zero))
    },
    GalleryState("Cons-minute-6-glided-back", "released: the note has glided back where it was, the frame has shaken; nothing says why on the board", size: minuteSize) { stage in
        let (backlog, _) = beginning(stage)
        try constrained(stage, backlog)
        _ = stage.editor.add(StickyNote(frame: CGRect(x: 520, y: 260, width: 160, height: 120), text: "Buy milk"), title: "Buy milk")
        stage.settleConstraints()
        stage.editor.setTool(.select)
        stage.press(at: CGPoint(x: 600, y: 320))
        stage.hover(at: CGPoint(x: 450, y: 300))
        stage.editor.pointerDragged(PointerEvent(location: CGPoint(x: 300, y: 260), timestamp: 3, clickCount: 1))
        stage.release(at: CGPoint(x: 300, y: 260))
        for _ in 0..<20 { stage.spin(0.05); stage.scheduler.advance(by: .milliseconds(50)) }
        stage.editor.selectedShapeIDs = []
        return .image(stage.render(at: .zero))
    },
    GalleryState("Cons-minute-7-retyped", "a Task inside, retyped as a Bug: its ring red, the funnel red with 1", size: minuteSize) { stage in
        let (backlog, _) = beginning(stage)
        let bug = stage.typeAt("Bug", bugSchema, x: 40)
        try constrained(stage, backlog)
        let note = try require(stage.noteTool(at: CGPoint(x: 260, y: 260), titled: "Fix login"))
        stage.retype(note, to: bug)
        stage.editor.selectedShapeIDs = []
        return .image(stage.render(at: .zero))
    },
    GalleryState("Cons-minute-7-issues", "and that note's Issues tab: the line, Move Out and Show Constraint", size: panelSize) { stage in
        let (backlog, _) = beginning(stage)
        let bug = stage.typeAt("Bug", bugSchema, x: 40)
        try constrained(stage, backlog)
        let note = try require(stage.noteTool(at: CGPoint(x: 260, y: 260), titled: "Fix login"))
        stage.retype(note, to: bug)
        return try panel(stage, of: note, tab: .of(IssuesTab.self))
    },
    GalleryState("Cons-turned-board", "the frame that accepts only tasks, holding a note retyped as a bug, turned into a subboard: the subboard on its board, its funnel red with 1", size: minuteSize) { stage in
        _ = try turned(stage)
        return .image(stage.render(at: .zero))
    },
    GalleryState("Cons-turned-inside", "and its board shown: the note, its ring red, as it was flagged in the frame", size: minuteSize) { stage in
        let (backlog, _) = try turned(stage)
        guard stage.editor.showBoard(BoardID(owner: backlog)) else { throw GalleryFailure("the subboard's board can't be shown") }
        stage.settleConstraints()
        return .image(stage.render(at: .zero))
    },
    GalleryState("Cons-minute-8-type-rules", "the Task type's Rules tab: Inside each task, the box that adds one", size: panelSize) { stage in
        let (_, task) = beginning(stage)
        return try panel(stage, of: task, tab: .of(RulesTab.self))
    },
    GalleryState("Cons-minute-9-zoomed-out", "the board zoomed out: the frame and its notes as skeletons, no chip", size: minuteSize) { stage in
        let (backlog, _) = beginning(stage)
        try constrained(stage, backlog)
        _ = stage.noteTool(at: CGPoint(x: 260, y: 260))
        stage.editor.selectedShapeIDs = []
        return .image(stage.render(at: .zero, zoom: 0.2))
    },
]

import AppKit
import Boards
@_spi(Host) import Canvas
import CanvasTesting
import Constraints
import CoreGraphics
import Foundation
import LanguageModels
import Locking
import Mentions
import Frames
import Selection
import SlashCommands
import StickyNotes
import Subboards
import SwiftUI
import TestKit
import Titles
import Types
import Validation

// Constraints' board funnel: the states of the pill at the canvas's top leading corner and its popover, files `Cons-board-*`, and the
// root's first minute from this way in, `Cons-minute-root-*`: a board that accepts only tasks, quiet, with a bug on it (red), the pill
// clicked (the popover over the board, with Not accepted), a narrow window (the words cut, the path kept clear), inside a subboard
// with the path beside it, the lists a subboard of a type has from elsewhere, and a locked subboard. The host's views over the canvas
// (the path, the funnel) are the real ones, hosted over the canvas's picture as a window places them.

private let taskSchema = #"{"type": "object", "properties": {"status": {"type": "string"}, "owner": {"type": "string"}}}"#
private let bugSchema = #"{"type": "object", "properties": {"severity": {"type": "string"}, "steps": {"type": "string"}}}"#
private let onlyTasks = Constraint(says: "only tasks", query: ":is-a(\"Task\")")
private let noBugs = Constraint(says: "no bugs", query: ":not(:is-a(\"Bug\"))")
private let boardSize = CGSize(width: 760, height: 560)
private let narrowSize = CGSize(width: 440, height: 400)
private let popoverStage = CGSize(width: 760, height: 620)

extension GalleryStage {
    /// The canvas at the origin with the host's views over it, as the window places them (the path at the top, the funnel at the
    /// top leading corner and its popover while it's open), drawn over the canvas's picture.
    func pictureWithOverlays() throws -> NSBitmapImageRep {
        let base = render(at: .zero)
        let editor = self.editor
        let overlays = editor.registry.hostOverlays.reduce(AnyView(Color.clear.allowsHitTesting(false))) { area, overlay in
            AnyView(area.overlay(alignment: overlay.alignment) { overlay.view(for: editor, onExit: {}) })
        }
        let hosting = NSHostingView(rootView: overlays.environment(\.locale, Locale(identifier: "en_US")))
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: size)
        let host = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        host.isReleasedWhenClosed = false
        host.appearance = appearance
        host.contentView = hosting
        defer { host.close() }
        for _ in 0..<8 {
            spin(0.05)
            host.settle()
        }
        let rep = try require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds), "the overlays can be drawn")
        rep.size = size
        appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: rep) }
        let graphics = try require(NSGraphicsContext(bitmapImageRep: base), "a context to draw the overlays in")
        let image = try require(rep.cgImage, "the overlays' picture")
        graphics.cgContext.draw(image, in: CGRect(origin: .zero, size: size))
        graphics.flushGraphics()
        return base
    }

    /// A type note far off the board, so a note is alone in view; the type's id (so its color) is fixed by the stage.
    func farType(_ title: String, _ schema: String, y: CGFloat) -> ShapeID {
        editor.addTypeNote(schema, title: title, frame: CGRect(x: 5000, y: y, width: 200, height: 200))
    }

    /// A note, titled and typed, at `origin`, on `board` (the board shown if nil).
    @discardableResult
    func typedNote(_ title: String, _ type: ShapeID, at origin: CGPoint, on board: BoardID? = nil) -> ShapeID {
        var note = ShapeRecord(StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 190, height: 150)), text: ""))
        note[TitleProperty.self] = title
        note[IsAProperty.self] = [TypeLink(type)]
        let record = AnyShapeRecord(note)
        if let board { editor.transact(on: board) { $0.insert(record) } } else { editor.transact { $0.insert(record) } }
        return record.id
    }
}

/// A subboard "Sprint 12" holding the three tasks (and a bug), with `list` of its own and `types` it is of; its board shown.
@MainActor private func sprintInside(_ stage: GalleryStage, bug: Bool = false, list: [Constraint] = [onlyTasks], of types: [ShapeID] = [],
                                     taskType: ShapeID? = nil) throws -> (board: BoardID, sprint: ShapeID) {
    let task = taskType ?? stage.farType("Task", taskSchema, y: 0)
    let bugType = stage.farType("Bug", bugSchema, y: 300)
    var record = ShapeRecord(Subboard(frame: CGRect(x: 40, y: 60, width: 200, height: 140)))
    record[TitleProperty.self] = "Sprint 12"
    if !list.isEmpty { record[ConstraintsProperty.self] = ConstraintList(list) }
    stage.editor.transact { $0.insert(record) }
    for type in types { stage.editor.addTypeLink(type, to: record.id) }
    let board = BoardID(owner: record.id)
    stage.typedNote("Plan demo", task, at: CGPoint(x: 150, y: 110), on: board)
    stage.typedNote("Update docs", task, at: CGPoint(x: 440, y: 110), on: board)
    stage.typedNote("Review PR", task, at: CGPoint(x: 150, y: 340), on: board)
    if bug { stage.typedNote("Crash on save", bugType, at: CGPoint(x: 440, y: 340), on: board) }
    stage.settleConstraints()
    guard stage.editor.showBoard(board) else { throw GalleryFailure("the subboard's board can't be shown") }
    stage.settleConstraints()
    return (board, record.id)
}

/// The popover opened as the pill's click does it, drawn.
@MainActor private func opened(_ stage: GalleryStage) throws -> NSBitmapImageRep {
    guard stage.editor.constraintBoard?.open() == true else { throw GalleryFailure("the pill isn't there to click") }
    return try stage.pictureWithOverlays()
}

/// The first minute's board: a root with the Task type (far off) and two tasks, and nothing on it says it can accept only tasks.
@MainActor private func freshRoot(_ stage: GalleryStage) {
    let task = stage.farType("Task", taskSchema, y: 0)
    stage.typedNote("Plan demo", task, at: CGPoint(x: 150, y: 110))
    stage.typedNote("Update docs", task, at: CGPoint(x: 440, y: 110))
    stage.settleConstraints()
}

/// `/constrain only tasks` typed with nothing selected on the board, and landed: the model answers `:is-a("Task")`.
@MainActor private func constrainRoot(_ stage: GalleryStage) throws {
    stage.model.queue(#":is-a("Task")"#)
    _ = try stage.openBar(on: [], typing: "constrain only tasks")
    stage.window.pressReturn()
    for _ in 0..<20 where (stage.editor.constraintWriter?.constraints(of: .root) ?? []).isEmpty { stage.spin(0.1) }
    stage.settleConstraints()
    guard !(stage.editor.constraintWriter?.constraints(of: .root) ?? []).isEmpty else { throw GalleryFailure("/constrain landed on the root") }
    stage.editor.selectedShapeIDs = []
}

@MainActor
let constraintBoardStates: [GalleryState] = [
    GalleryState("Cons-board-quiet", "inside the subboard Sprint 12, which accepts only tasks (the mockup's first panel): the path at the top, the funnel pill at the top leading corner, quiet, \"Accepts only tasks\"; three tasks on it", size: boardSize) { stage in
        _ = try sprintInside(stage)
        return .image(try stage.pictureWithOverlays())
    },
    GalleryState("Cons-board-red", "a bug on it (the second panel): the pill red with 1 after its words, the bug's ring red", size: boardSize) { stage in
        _ = try sprintInside(stage, bug: true)
        return .image(try stage.pictureWithOverlays())
    },
    GalleryState("Cons-board-open", "the pill clicked (the third panel): the popover under it, its arrow at the pill, the constraint's words, query and reach, the add box, then Not accepted: Crash on save", size: popoverStage) { stage in
        _ = try sprintInside(stage, bug: true)
        return .image(try opened(stage))
    },
    GalleryState("Cons-board-open-several", "several constraints: the pill says \"Accepts only tasks and 1 more\", the popover has a row each", size: popoverStage) { stage in
        _ = try sprintInside(stage, list: [onlyTasks, noBugs])
        return .image(try opened(stage))
    },
    GalleryState("Cons-board-narrow", "a narrow window with a long constraint: the pill's words are cut at the end and the pill stays clear of the path", size: narrowSize) { stage in
        _ = try sprintInside(stage, bug: true, list: [Constraint(says: "only tasks that are small, owned by one person and due this week", query: ":is-a(\"Task\")")])
        return .image(try stage.pictureWithOverlays())
    },
    GalleryState("Cons-board-narrower", "narrower still: no room for words, so the symbol and the count alone", size: CGSize(width: 300, height: 360)) { stage in
        _ = try sprintInside(stage, bug: true, list: [Constraint(says: "only tasks that are small, owned by one person and due this week", query: ":is-a(\"Task\")")])
        return .image(try stage.pictureWithOverlays())
    },
    GalleryState("Cons-board-open-narrow", "the popover in a narrow window: 320 wide, the pill's arrow still at the pill", size: narrowSize) { stage in
        _ = try sprintInside(stage, bug: true)
        return .image(try opened(stage))
    },
    GalleryState("Cons-board-open-type", "a subboard of the type Sprint, seen from inside: Sprint's list under its pill, read-only, then Own: its own and the add box", size: popoverStage) { stage in
        let task = stage.farType("Task", taskSchema, y: 0)
        let sprint = stage.farType("Sprint", try require(TypeConstraintBook.text(#"{"type": "object", "properties": {}}"#, setting: [onlyTasks])), y: 600)
        _ = try sprintInside(stage, list: [noBugs], of: [sprint], taskType: task)
        return .image(try opened(stage))
    },
    GalleryState("Cons-board-open-locked", "a locked subboard seen from inside: its rows are read-only", size: popoverStage) { stage in
        let (_, sprint) = try sprintInside(stage, bug: true)
        stage.editor.showBoard(.root)
        stage.editor.transact("Lock") { $0.update(sprint) { $0[LockedProperty.self] = true } }
        guard stage.editor.showBoard(BoardID(owner: sprint)) else { throw GalleryFailure("the locked subboard's board can't be shown") }
        stage.settleConstraints()
        return .image(try opened(stage))
    },
    GalleryState("Cons-minute-root-1-empty", "the cold first minute from the root: a board with the Task type and two tasks; nothing says the board can accept only tasks (no pill)", size: boardSize) { stage in
        freshRoot(stage)
        return .image(try stage.pictureWithOverlays())
    },
    GalleryState("Cons-minute-root-2-typed", "`/constrain only tasks` typed with nothing selected: the bar, its words", size: boardSize) { stage in
        freshRoot(stage)
        stage.model.queue(#":is-a("Task")"#)
        _ = try stage.openBar(on: [], typing: "constrain only tasks")
        return .image(try stage.pictureWithOverlays())
    },
    GalleryState("Cons-minute-root-3-after", "the model's answer landed: the pill appears at the top leading corner; the Task type note on the board is no task, so it is red with 1", size: boardSize) { stage in
        freshRoot(stage)
        try constrainRoot(stage)
        return .image(try stage.pictureWithOverlays())
    },
    GalleryState("Cons-minute-root-4-popover", "and a click on it: the board's constraint, its query and reach, the box that adds another, Not accepted: Task", size: popoverStage) { stage in
        freshRoot(stage)
        try constrainRoot(stage)
        return .image(try opened(stage))
    },
    GalleryState("Cons-minute-root-5-menu", "the canvas's right-click menu on empty board, now with Show Board Constraints", size: boardSize, isText: true) { stage in
        freshRoot(stage)
        try constrainRoot(stage)
        return .text(stage.menuOutline(at: CGPoint(x: 300, y: 450)).joined(separator: "\n"))
    },
]

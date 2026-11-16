import AppKit
import Boards
@_spi(Host) import Canvas
import CanvasTesting
import Chrome
import Constraints
import CoreGraphics
import Foundation
import JumpTo
import LanguageModels
import Mentions
import Selection
import ShippedTesting
import SlashCommands
import StickyNotes
import Subboards
import SwiftUI
import TestKit
import Titles
import Types
import Validation

// The board's funnel, as shipped: `/constrain only tasks` typed with nothing selected on the root puts the pill at the canvas's
// top leading corner (and the Task type note, which is no task, makes it red: the root judges every shape on its board); a
// subboard of a type seen from inside has the type's list under the type's pill, read-only, and the popover's add box writes
// the subboard's own list; the shipped overlays are the path, the palette and the funnel, and the pill clears the path.

private let taskSchema = #"{"type": "object", "properties": {"status": {"type": "string"}}}"#
private let onlyTasks = Constraint(says: "only tasks", query: ":is-a(\"Task\")")

/// The board these tests share, as shipped: the Task type, a task and a note that isn't one, a type Sprint whose list says only
/// tasks, and a scripted model.
@MainActor private final class RootBoard {
    let h: EditorHarness
    let model: ScriptedLanguageModel
    let pasteboard: NSPasteboard
    var editor: CanvasEditor { h.editor }
    var task = ShapeID(), sprint = ShapeID(), made = ShapeID()

    init(model: ScriptedLanguageModel = ScriptedLanguageModel()) {
        self.model = model
        let pasteboard = NSPasteboard.withUniqueName()
        self.pasteboard = pasteboard
        h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: model) }
        editor.viewportDidResize(to: CGSize(width: 900, height: 600))
        task = editor.addTypeNote(taskSchema, title: "Task", frame: CGRect(x: 600, y: 400, width: 200, height: 200))
        sprint = editor.addTypeNote(TypeConstraintBook.text(#"{"type": "object", "properties": {}}"#, setting: [onlyTasks]) ?? "",
                                    title: "Sprint", frame: CGRect(x: 600, y: 100, width: 200, height: 200))
        var note = ShapeRecord(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 160), text: ""))
        note[TitleProperty.self] = "Plan demo"
        note[IsAProperty.self] = [TypeLink(task)]
        editor.transact { $0.insert(AnyShapeRecord(note)) }
        settle()
    }

    deinit {
        MainActor.assumeIsolated { pasteboard.releaseGlobally() }
    }

    func settle(file: StaticString = #fileID, line: UInt = #line) {
        let index = editor.constraintIndex
        expect(spinRunLoop(until: { index?.isSettled ?? true }, timeout: 5, file: file, line: line), "the constraints settle", file: file, line: line)
    }

    /// The shipped overlays over a stand-in canvas in an unshown window, as `BoardChrome` hosts them.
    func window(size: CGSize = CGSize(width: 900, height: 600)) -> (window: NSWindow, hosting: NSView, canvas: NSView) {
        let editor = self.editor
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(origin: .zero, size: size))
        let canvas = NSView(frame: content.bounds)
        let overlays = editor.registry.hostOverlays.reduce(AnyView(Color.clear.allowsHitTesting(false))) { area, overlay in
            AnyView(area.overlay(alignment: overlay.alignment) { overlay.view(for: editor, onExit: {}) })
        }
        let hosting = NSHostingView(rootView: overlays.environment(\.locale, Locale(identifier: "en_US")))
        hosting.sizingOptions = []
        hosting.frame = content.bounds
        content.addSubview(canvas)
        content.addSubview(hosting)
        window.contentView = content
        window.settle()
        return (window, hosting, canvas)
    }

    /// Lets the editor's waits land, with the run loop between.
    func land(_ window: NSWindow) {
        for _ in 0..<10 {
            h.scheduler.advance(by: .milliseconds(20))
            window.settle()
        }
    }
}

@MainActor let constraintsBoardShippedTests = Suite("Constraints' board funnel, as shipped", [
    test("/constrain only tasks with nothing selected on the root: one step, and the pill appears at the top leading corner, red with the Task type note that is no task") {
        let model = ScriptedLanguageModel(answers: [#":is-a("Task")"#])
        let b = RootBoard(model: model)
        let (window, hosting, _) = b.window()
        defer { window.close() }
        let board = try require(b.editor.constraintBoard)
        expectEqual(board.pill, nil, "nothing says it before")
        expectEqual(hosting.descendants(NSButton.self).count, 0)
        let commands = try require(b.editor.slashCommands)
        let target = SlashTarget.everything(b.editor.document.shapes.map(\.id))
        expect(commands.commands(for: target).map(\.name).contains("constrain"), "offered on the board")
        let task = try require(commands.answer("constrain", for: target, with: "only tasks"))
        expectEqual(try awaitResult { await task.value }, .done)
        b.settle()
        expectEqual(b.editor.constraintWriter?.constraints(of: .root)?.map(\.says), ["only tasks"])
        expectEqual(b.editor.undoHistory.undoName, "Add Constraint")
        expect(model.lastRequest?.system?.contains("this board") == true, "in the board's name: \(model.lastRequest?.system ?? "")")
        let pill = try require(board.pill)
        expectEqual(pill.place, .root)
        expectEqual(pill.words, "Accepts only tasks")
        expectEqual(pill.count, 2, "the two type notes on the board are no tasks: Task and Sprint")
        expectEqual(pill.spoken, "Constraints, only tasks, 2 not accepted")
        window.spin { !hosting.descendants(NSButton.self).isEmpty }
        let button = try require(hosting.descendants(NSButton.self).first)
        expectEqual(button.frame.minX, 12)
        expectEqual(button.frame.midY, BoardPath.rowMidline)
    },
    test("a subboard of Sprint seen from inside: the pill says Sprint's list, the popover shows it under Sprint's pill, read-only, and its add box writes the subboard's own list") {
        let b = RootBoard()
        let sub = b.editor.add(Subboard(frame: CGRect(x: 100, y: 400, width: 240, height: 160)))
        b.editor.transact("Title") { $0.update(sub) { $0[TitleProperty.self] = "Release 2" } }
        b.editor.addTypeLink(b.sprint, to: sub)
        b.settle()
        expect(b.h.enter(sub))
        b.settle()
        let board = try require(b.editor.constraintBoard)
        expectEqual(board.place, .shape(sub))
        expectEqual(board.pill?.words, "Accepts only tasks", "from its type")
        let (window, hosting, _) = b.window()
        defer { window.close() }
        expect(b.editor.perform(.showBoardConstraints))
        window.spin { hosting.descendants(NSTextView.self).filter { !$0.isFieldEditor }.count >= 2 }
        b.land(window)
        let texts = hosting.descendants(NSTextView.self).filter { !$0.isFieldEditor }
        expectEqual(texts.filter(\.isEditable).map(\.string), [""], "only the box that adds one: the type's list is Sprint's to change")
        // A constraint whose words already read as a query is written as the subboard's own, one step.
        let box = try require(texts.first(where: \.isEditable))
        window.makeFirstResponder(box)
        window.type(":not(:is-a(\"Bug\"))")
        window.pressReturn()
        b.land(window)
        expectEqual(b.editor.constraintWriter?.constraints(of: .shape(sub))?.map(\.says), [":not(:is-a(\"Bug\"))"])
        expectEqual(b.editor.undoHistory.undoName, "Add Constraint")
        expectEqual(board.pill?.words, "Accepts only tasks and 1 more", "its own beside Sprint's")
    },
    test("the shipped overlays are the path, the palette and the funnel, in that order, and the pill clears the path on a subboard's board in a narrow window") {
        let b = RootBoard()
        let sub = b.editor.add(Subboard(frame: CGRect(x: 100, y: 400, width: 240, height: 160)))
        b.editor.transact("Title") { $0.update(sub) { $0[TitleProperty.self] = "Sprint 12 with a long name" } }
        b.editor.constraintWriter?.add(Constraint(says: "only tasks that are small, owned by one person and due this week", query: ":is-a(\"Task\")"), to: .shape(sub))
        b.settle()
        expectEqual(b.editor.registry.hostOverlays.map(\.alignment), [.top, .center, .topLeading])
        expect(b.h.enter(sub))
        let (window, hosting, _) = b.window(size: CGSize(width: 420, height: 300))
        defer { window.close() }
        let crumbs = try require(b.editor.boardCrumbs)
        window.spin { crumbs.pillWidth > 0 && hosting.descendants(NSButton.self).count >= 2 }
        b.land(window)
        let pill = try require(hosting.descendants(NSButton.self).min { $0.frame.minX < $1.frame.minX })
        let pathLeading = (420 - crumbs.pillWidth) / 2
        // Beside the path's pill with the full clearance, or, with too little room for that, under it: never over it.
        let pathBottom = BoardPath.coveredHeight(on: b.editor.board) - ChromeStyle.floatShadowReach
        expect(pill.frame.maxX + ConstraintsStyle.pillClearance <= pathLeading + 0.01 || pill.frame.minY >= pathBottom,
               "the pill (\(pill.frame)) clears the path's pill (from \(pathLeading), to \(pathBottom))")
        expectEqual(pill.frame.minX, 12)
    },
    test("Jump To's palette and the pill: the palette has the canvas to itself in a canvas too narrow for both, and opening one closes the other") {
        let b = RootBoard()
        b.editor.constraintWriter?.add(onlyTasks, to: .root)
        b.settle()
        let size = CGSize(width: 700, height: 500)
        let (window, hosting, _) = b.window(size: size)
        defer { window.close() }
        b.editor.viewportDidResize(to: size)
        window.spin { !hosting.descendants(NSButton.self).isEmpty }
        let board = try require(b.editor.constraintBoard)
        let jump = try require(b.editor.jumpTo)
        let pillFrame = try require(hosting.descendants(NSButton.self).min { $0.frame.minX < $1.frame.minX }).frame
        let field = CGRect(x: (size.width - 560) / 2, y: b.editor.hostViewsReach + 12, width: 560, height: 40)
        expect(pillFrame.intersects(field), "in this canvas the pill is where the palette's field is: \(pillFrame), \(field)")
        // The palette opened: the pill leaves its field, and a click there is the palette's.
        expect(b.editor.perform(.jumpTo))
        b.land(window)
        expect(jump.isOpen)
        expectEqual(b.editor.modalOverlay, .jumpTo)
        let hit = hosting.hitTest(hosting.convert(CGPoint(x: field.minX + 10, y: field.midY), from: nil))
        expect((hit as? NSButton).map { $0.bounds.width >= size.width } ?? true, "not the pill's button: \(String(describing: hit))")
        jump.close()
        b.land(window)
        expectEqual(b.editor.modalOverlay, nil)
        expect(hosting.descendants(NSButton.self).contains { $0.frame.minX == 12 }, "the palette closed, the pill is back")
        // The popover open, then ⌘K: the popover goes, the palette has the canvas and the keyboard.
        expect(b.editor.perform(.showBoardConstraints))
        b.land(window)
        expect(board.isOpen)
        expect(b.editor.perform(.jumpTo))
        b.land(window)
        expect(jump.isOpen, "the palette")
        expect(!board.isOpen, "the popover gave way")
        let responder = window.firstResponder as? NSView
        expect(responder.map { $0.isDescendant(of: hosting) && $0 is NSTextView } ?? false, "the keyboard is in the palette's field: \(String(describing: window.firstResponder))")
        let under = hosting.hitTest(hosting.convert(CGPoint(x: 350, y: field.maxY + 30), from: nil))
        expect((under as? NSButton).map { $0.bounds.width >= size.width } ?? true, "a click under the palette's field isn't a card's: \(String(describing: under))")
        // The palette open, then the popover asked for: the palette goes.
        expect(b.editor.perform(.showBoardConstraints))
        b.land(window)
        expect(board.isOpen)
        expect(!jump.isOpen, "the palette gave way")
        expectEqual(b.editor.modalOverlay, ConstraintFacesPlugin.id)
    },
    test("the command bar opened with nothing selected has the row: the pill leaves while it shows, and is back when it closes") {
        let b = RootBoard()
        let size = CGSize(width: 600, height: 500)
        let (window, hosting, _) = b.window(size: size)
        defer { window.close() }
        b.editor.viewportDidResize(to: size)
        b.editor.constraintWriter?.add(onlyTasks, to: .root)
        b.editor.constraintWriter?.add(Constraint(says: "no bugs", query: ":not(:is-a(\"Bug\"))"), to: .root)
        b.settle()
        @MainActor func pill() -> NSButton? { hosting.descendants(NSButton.self).first { $0.frame.minX == ChromeStyle.floatMargin } }
        window.spin { pill() != nil }
        expect(pill() != nil, "the pill shows")
        let bar = try require(b.editor.slashBar)
        bar.open(on: [])
        b.land(window)
        expect(b.editor.showsBoardCard, "a card about no shape shows")
        expect(pill() == nil, "the pill gave the row to the bar")
        bar.close()
        b.land(window)
        expect(!b.editor.showsBoardCard)
        expect(pill() != nil, "the bar closed, the pill is back")
    },
])

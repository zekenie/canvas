import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Frames
import LanguageModels
import Locking
import Mentions
import References
import Selection
import SlashCommands
import StickyNotes
import Subboards
import TestKit
import TextEditing
import Titles
import Types

// The command bar: the states of one track, added to `galleryStates` (GalleryTypesLook.swift) as `slashBarStates`,
// one for each wireframe of its plan (`docs/plans/slash-on-selection/wireframes`): `/` on a selected note, `/color`'s
// choices and the note after the pick, a mixed selection's counted rows, a frame's list and a locked note's, `/move-to @`
// naming a frame for three notes, a note's own `/` while it is edited, and the bar over a selection at the window's
// bottom and among skeletons zoomed out; then `/` with nothing selected, the bar at the top for every shape, and
// `/query`: its list, the bar waiting for the model, what it finds selected, and No matches; and a thing's name typed
// after the `/`, in a note and in the bar: what the commands can do with it.

private let barStage = CGSize(width: 560, height: 460)
private let lowStage = CGSize(width: 560, height: 360)

extension CanvasEditor {
    /// A note of `text`, titled if `title` is given.
    fileprivate func barNote(_ text: String, title: String? = nil, at origin: CGPoint, width: CGFloat = 200, height: CGFloat = 200) -> ShapeID {
        let props = StickyNote(frame: CGRect(origin: origin, size: CGSize(width: width, height: height)), text: MentionText(plain: text))
        return title.map { add(props, title: $0) } ?? add(props)
    }
}

extension GalleryStage {
    /// `/` on the canvas with `shapes` selected, then `typed` in the bar, as a person types it: the bar's field.
    func openBar(on shapes: [ShapeID], typing typed: String = "") throws -> EditingTextView {
        editor.selectedShapeIDs = shapes
        window.makeFirstResponder(canvas)
        window.type("/")
        let field = try require(editor.slashBar?.field, "the bar opened")
        if !typed.isEmpty { window.type(typed) }
        window.settle()
        return field
    }

    /// The canvas with the bar's open list drawn under the character at `location` of its field (its `/`, an `@`).
    func pictureWithBarList(_ field: EditingTextView, under location: Int = 0) throws -> NSBitmapImageRep {
        let screen = field.firstRect(forCharacterRange: NSRange(location: location, length: 1), actualRange: nil)
        return try pictureWithList(listRows(in: field.caretListWindow), below: window.convertFromScreen(screen))
    }
}

@MainActor let slashBarStates: [GalleryState] = [
    GalleryState("Bar1-press-slash", answers: "1", "`/` with a note selected: the bar 4 points under it, left edges together, `Groceries` quiet at its right, the list of what the note takes", size: barStage) { stage in
        let note = stage.editor.barNote("Milk, eggs, bread", title: "Groceries", at: CGPoint(x: 40, y: 40), width: 220, height: 140)
        return .image(try stage.pictureWithBarList(try stage.openBar(on: [note])))
    },
    GalleryState("Bar2-color-choices", answers: "2", "`/color ` in the bar: the colors' chips", size: barStage) { stage in
        let note = stage.editor.barNote("Milk, eggs, bread", title: "Groceries", at: CGPoint(x: 40, y: 40), width: 220, height: 140)
        return .image(try stage.pictureWithBarList(try stage.openBar(on: [note], typing: "color ")))
    },
    GalleryState("Bar2-after-pick", answers: "2", "after `bl` and Return: the note blue, the bar gone, the note still selected", size: lowStage) { stage in
        let note = stage.editor.barNote("Milk, eggs, bread", title: "Groceries", at: CGPoint(x: 40, y: 40), width: 220, height: 140)
        _ = try stage.openBar(on: [note], typing: "color bl")
        stage.window.pressReturn()
        return .image(stage.render(at: .zero))
    },
    GalleryState("Bar3-mixed-selection", answers: "3", "two notes, a frame, an arrow and a reference selected: every command any takes, those fewer than all counted (`color · 4 of 5`), `5 shapes` at the right", size: barStage) { stage in
        let one = stage.editor.barNote("Ann", at: CGPoint(x: 30, y: 30), width: 110, height: 90)
        let two = stage.editor.barNote("Bo", at: CGPoint(x: 160, y: 30), width: 110, height: 90)
        let frame = stage.editor.add(Frame(frame: CGRect(x: 300, y: 20, width: 200, height: 110)), title: "Sprint")
        let arrow = stage.editor.add(Arrow(start: .free(CGPoint(x: 40, y: 150)), end: .free(CGPoint(x: 260, y: 150))))
        let reference = stage.editor.add(Reference(frame: CGRect(x: 300, y: 140, width: 120, height: 32)))
        return .image(try stage.pictureWithBarList(try stage.openBar(on: [one, two, frame, arrow, reference])))
    },
    GalleryState("Bar4-frame", answers: "4", "a frame selected: `turn-into-subboard` first, typeable nowhere before", size: barStage) { stage in
        let frame = stage.editor.add(Frame(frame: CGRect(x: 30, y: 30, width: 320, height: 160)), title: "Sprint")
        let a = stage.editor.barNote("One", at: CGPoint(x: 50, y: 70), width: 120, height: 100)
        let b = stage.editor.barNote("Two", at: CGPoint(x: 200, y: 70), width: 120, height: 100)
        stage.editor.put([a, b], in: frame)
        return .image(try stage.pictureWithBarList(try stage.openBar(on: [frame])))
    },
    GalleryState("Bar4-locked-note", answers: "4", "a locked note selected: `unlock` alone", size: lowStage) { stage in
        let note = stage.editor.barNote("Locked away", title: "Budget", at: CGPoint(x: 40, y: 40), width: 220, height: 140)
        stage.editor.lock([note])
        return .image(try stage.pictureWithBarList(try stage.openBar(on: [note])))
    },
    GalleryState("Bar5-name-a-shape", answers: "5", "three notes selected, `/move-to @roa`: the @ list of the places that take all three, Roadmap", size: barStage) { stage in
        let notes = [stage.editor.barNote("One", at: CGPoint(x: 30, y: 30), width: 110, height: 90),
                     stage.editor.barNote("Two", at: CGPoint(x: 160, y: 30), width: 110, height: 90),
                     stage.editor.barNote("Three", at: CGPoint(x: 30, y: 140), width: 110, height: 90)]
        _ = stage.editor.add(Frame(frame: CGRect(x: 300, y: 20, width: 240, height: 230)), title: "Roadmap")
        _ = stage.editor.add(Subboard(frame: CGRect(x: 300, y: 300, width: 200, height: 120)), title: "Roadshow")
        let field = try stage.openBar(on: notes, typing: "move-to @roa")
        return .image(try stage.pictureWithBarList(field, under: 9))
    },
    GalleryState("Bar6-typing-unchanged", answers: "6", "a note being edited: its own `/` list on a new line, no bar", size: barStage) { stage in
        let note = stage.editor.barNote("Milk, eggs, bread", title: "Groceries", at: CGPoint(x: 40, y: 40), width: 220, height: 140)
        let view = try stage.edit(note)
        stage.typeLine("/")
        stage.window.settle()
        return .image(try stage.pictureWithList(of: view))
    },
    GalleryState("Bar7-bottom", answers: "7", "a note near the window's bottom: the bar over the selection, where there's no room below", size: lowStage) { stage in
        let note = stage.editor.barNote("Milk, eggs, bread", title: "Groceries", at: CGPoint(x: 40, y: 200), width: 220, height: 140)
        _ = try stage.openBar(on: [note])
        return .image(stage.render(at: .zero))
    },
    GalleryState("Bar7-zoomed-out", answers: "7", "zoomed out to 30%: the notes skeletons, the bar the same size under them", size: lowStage) { stage in
        let notes = (0..<6).map { index in
            stage.editor.barNote("Note \(index)", at: CGPoint(x: 60 + CGFloat(index % 3) * 260, y: 60 + CGFloat(index / 3) * 260))
        }
        stage.look(at: .zero, zoom: 0.3)
        _ = try stage.openBar(on: Array(notes.prefix(3)))
        return .image(stage.render(at: .zero, zoom: 0.3))
    },
    GalleryState("Bar8-nothing-selected", answers: "8", "`/` with nothing selected: the bar at the top of the canvas, in the middle, for every shape on the board, `All shapes` at its right, `query` last", size: barStage) { stage in
        _ = stage.shoppingNotes()
        return .image(try stage.pictureWithBarList(try stage.openBar(on: [])))
    },
    GalleryState("Bar9-query-typed", answers: "9", "`/query the shopping` typed, before Return: the line marked as a command it would run, nothing asked yet", size: barStage) { stage in
        _ = stage.shoppingNotes()
        _ = try stage.openBar(on: [], typing: "query the shopping")
        return .image(stage.render(at: .zero))
    },
    GalleryState("Bar9-query-asking", answers: "9", "`/query the shopping` and Return: the bar waits for the model, the line kept, a spinner where `All shapes` was", size: barStage) { stage in
        _ = stage.shoppingNotes()
        stage.model.holdsAnswers = true
        stage.model.queue(#":contains("buy")"#)
        _ = try stage.openBar(on: [], typing: "query the shopping")
        stage.window.pressReturn()
        stage.window.settle()
        _ = try require(stage.editor.slashBar?.isWaiting == true ? true : nil, "the bar waits")
        return .image(stage.render(at: .zero))
    },
    GalleryState("Bar9-query-found", answers: "9", "the answer: the two notes its query found selected, the bar gone", size: barStage) { stage in
        let notes = stage.shoppingNotes()
        stage.model.queue(#":contains("buy")"#)
        _ = try stage.openBar(on: [], typing: "query the shopping")
        stage.window.pressReturn()
        spinRunLoop(until: { stage.editor.slashBar?.isOpen != true })
        _ = try require(stage.editor.selectedShapeIDs == Array(notes.prefix(2)) ? true : nil, "the shopping selected")
        return .image(stage.render(at: .zero))
    },
    GalleryState("Bar9-query-edited", answers: "9", "typing while it asks: the wait stops, the spinner goes and `All shapes` is back; Return asks again with the new words", size: barStage) { stage in
        _ = stage.shoppingNotes()
        stage.model.holdsAnswers = true
        stage.model.queue(#":contains("buy")"#)
        _ = try stage.openBar(on: [], typing: "query the shopping")
        stage.window.pressReturn()
        stage.window.type(" list")
        stage.window.settle()
        _ = try require(stage.editor.slashBar?.isWaiting == false ? true : nil, "the wait stopped")
        return .image(stage.render(at: .zero))
    },
    GalleryState("Bar9-query-failed", answers: "9", "the model's call failed: its words where `All shapes` was, the line still there", size: barStage) { stage in
        _ = stage.shoppingNotes()
        stage.model.queue(.notSignedIn)
        _ = try stage.openBar(on: [], typing: "query the shopping")
        stage.window.pressReturn()
        spinRunLoop(until: { stage.editor.slashBar?.failure != nil })
        _ = try require(stage.editor.slashBar?.failure == "Not signed in" ? true : nil, "Not signed in")
        return .image(stage.render(at: .zero))
    },
    GalleryState("Bar10-query-selection-asking", answers: "10", "two notes selected, `/query the milk one` and Return: the bar under them waits, `2 shapes` a spinner", size: barStage) { stage in
        let notes = stage.shoppingNotes()
        stage.model.holdsAnswers = true
        stage.model.queue(#":contains("milk")"#)
        _ = try stage.openBar(on: Array(notes.prefix(2)), typing: "query the milk one")
        stage.window.pressReturn()
        stage.window.settle()
        _ = try require(stage.editor.slashBar?.isWaiting == true ? true : nil, "the bar waits")
        return .image(stage.render(at: .zero))
    },
    GalleryState("Bar10-query-narrowed", answers: "10", "the answer: of the two, the one it found stays selected", size: barStage) { stage in
        let notes = stage.shoppingNotes()
        stage.model.queue(#":contains("milk")"#)
        _ = try stage.openBar(on: Array(notes.prefix(2)), typing: "query the milk one")
        stage.window.pressReturn()
        spinRunLoop(until: { stage.editor.slashBar?.isOpen != true })
        _ = try require(stage.editor.selectedShapeIDs == [notes[0]] ? true : nil, "narrowed to Buy milk")
        return .image(stage.render(at: .zero))
    },
    GalleryState("Name1-in-a-note", "a note being edited, `/idea` typed on a new line: what can be done with Idea, the type and the note, and with the frame Idea Backlog", size: barStage) { stage in
        stage.ideaBoard()
        let note = stage.editor.barNote("Ship the beta", title: "Launch", at: CGPoint(x: 40, y: 40), width: 220, height: 140)
        let view = try stage.edit(note)
        stage.typeLine("/idea")
        stage.window.settle()
        let slash = try require(view.slashCommands?.picker?.location, "the list")
        let screen = view.firstRect(forCharacterRange: NSRange(location: slash, length: 1), actualRange: nil)
        return .image(try stage.pictureWithList(stage.listRows(of: view), below: stage.window.convertFromScreen(screen)))
    },
    GalleryState("Name2-in-the-bar", "two notes selected, `/idea` in the bar: the same for both, `2 shapes` at the right", size: barStage) { stage in
        stage.ideaBoard()
        let one = stage.editor.barNote("Ship the beta", title: "Launch", at: CGPoint(x: 30, y: 40), width: 120, height: 100)
        let two = stage.editor.barNote("Tell the team", title: "Announce", at: CGPoint(x: 160, y: 40), width: 120, height: 100)
        return .image(try stage.pictureWithBarList(try stage.openBar(on: [one, two], typing: "idea")))
    },
    GalleryState("Bar9-query-no-matches", answers: "9", "a question its query finds nothing for: `No matches` where `All shapes` was, the line still there to change", size: barStage) { stage in
        _ = stage.shoppingNotes()
        stage.model.queue(#":contains("zebra")"#)
        _ = try stage.openBar(on: [], typing: "query anything about zebras")
        stage.window.pressReturn()
        spinRunLoop(until: { stage.editor.slashBar?.failure != nil })
        _ = try require(stage.editor.slashBar?.failure == "No matches" ? true : nil, "No matches")
        return .image(stage.render(at: .zero))
    },
]

extension GalleryStage {
    /// A type called Idea at the right, and below it a frame called Idea Backlog.
    fileprivate func ideaBoard() {
        _ = editor.addTypeNote(TypeSchemaProperty.starter, title: "Idea", frame: CGRect(x: 340, y: 30, width: 180, height: 110))
        _ = editor.add(Frame(frame: CGRect(x: 320, y: 220, width: 220, height: 200)), title: "Idea Backlog")
    }

    /// Three notes in a row: Buy milk, Buy eggs, Call Sam.
    fileprivate func shoppingNotes() -> [ShapeID] {
        ["Buy milk", "Buy eggs", "Call Sam"].enumerated().map { index, text in
            editor.barNote(text, at: CGPoint(x: 30 + CGFloat(index) * 175, y: 150), width: 160, height: 120)
        }
    }
}

import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Frames
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

// The command bar: the states of one track, added to `galleryStates` (GalleryTypesLook.swift) as `slashBarStates`,
// one for each wireframe of its plan (`docs/plans/slash-on-selection/wireframes`): `/` on a selected note, `/color`'s
// choices and the note after the pick, a mixed selection's counted rows, a frame's list and a locked note's, `/move-to @`
// naming a frame for three notes, a note's own `/` while it is edited, and the bar over a selection at the window's
// bottom and among skeletons zoomed out.

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
]

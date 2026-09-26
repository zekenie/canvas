import Arrows
import Canvas
import CoreGraphics
import EllipseTitles
import Ellipses
import Eraser
import Rectangles
import StickyNotes
import Titles
import Validation

/// The static composition point: which plugins ship, in which order (the toolbar's order, and the
/// order overlays draw in). Tests import this, so they check exactly what ships.
@MainActor
public enum ShippedPlugins {
    public static var all: [any CanvasPlugin] {
        [
            ArrowsPlugin(), StickyNotesPlugin(), EllipsesPlugin(), ValidationPlugin(),
            // The examples (Examples/). Each is one line here; delete it to leave it out.
            RectanglesPlugin(), EraserPlugin(), TitlesPlugin(), EllipseTitlesPlugin(),
        ]
    }

    public static func registry() throws(RegistryError) -> Registry {
        try Registry(plugins: all)
    }

    public static func makeEditor(document: CanvasDocument = WelcomeBoard.document(), scheduler: any Scheduler = TaskScheduler()) -> CanvasEditor {
        do {
            return CanvasEditor(registry: try registry(), document: document, scheduler: scheduler)
        } catch {
            fatalError("The shipped plugins don't register: \(error)")   // CompositionTests catches this first
        }
    }
}

public enum WelcomeBoard {
    public static func document() -> CanvasDocument {
        func note(_ x: CGFloat, _ y: CGFloat, _ text: String) -> ShapeRecord<StickyNote> {
            ShapeRecord(StickyNote(frame: CGRect(origin: CGPoint(x: x, y: y), size: StickyNote.defaultSize), text: text))
        }
        let notes = [
            note(80, 80, "Double-click empty space to add a note. Drag a note to move it."),
            note(460, 80, "Double-click a note (or select it and press Return) to edit it."),
            note(840, 80, "Pinch to zoom, scroll with two fingers to pan. Dragging the background pans too."),
            note(80, 420, "Press A for the arrow tool, then drag from one shape to another. Press O to place an ellipse."),
            note(460, 420, "Pause inside a note while drawing to aim at that spot. Hold ⌥ to go all the way in, ⌘ to not attach."),
            note(840, 420, "Select an arrow and drag its middle handle to bend it."),
        ]
        func bound(_ note: ShapeRecord<StickyNote>) -> ArrowTerminal {
            .bound(ArrowBinding(shapeID: note.id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        }
        let arrows = [
            Arrow(start: bound(notes[0]), end: bound(notes[1])),
            Arrow(start: bound(notes[3]), end: bound(notes[4])),
            Arrow(start: bound(notes[4]), end: bound(notes[5]), bend: 70),
        ]
        return CanvasDocument(shapes: notes.map(AnyShapeRecord.init) + arrows.map { AnyShapeRecord(ShapeRecord($0)) })
    }
}

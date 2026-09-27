import Arrows
import Canvas
import Checklists
import CoreGraphics
import DetailPanel
import EllipseTitles
import Ellipses
import Eraser
import Rectangles
import Selection
import StickyNotes
import SwiftUI
import TaskCards
import Titles
import Validation
import ValidationDetails

/// The static composition point: which plugins ship, in which order (the toolbar's order, and the
/// order overlays draw in). Tests import this, so they check exactly what ships.
@MainActor
public enum ShippedPlugins {
    public static var all: [any CanvasPlugin] {
        [
            // First: the others build on it, and its handles draw below their view overlays.
            SelectionPlugin(),
            ArrowsPlugin(), StickyNotesPlugin(), EllipsesPlugin(), TaskCardsPlugin(),
            ValidationPlugin(), DetailPanelPlugin(), ChecklistsPlugin(), ValidationDetailsPlugin(),
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

    /// The detail panel, for the app to place beside the canvas. It follows the editor's selection;
    /// `onExit` must give the keyboard back to the canvas.
    public static func detailPanel(editor: CanvasEditor, onExit: @escaping @MainActor () -> Void) -> some View {
        DetailPanelView(editor: editor, onExit: onExit)
    }
}

public enum WelcomeBoard {
    /// The six notes' text: the top row left to right, then the bottom row.
    public static let texts = [
        "Double-click empty space to add a note. Drag a note to move it.",
        "Double-click a note (or select it and press Return) to edit it.",
        "Pinch to zoom, scroll with two fingers to pan. Press H for the hand tool; drag the background to select.",
        "Press A for the arrow tool, then drag from one shape to another. Press O to place an ellipse.",
        "Pause inside a note while drawing to aim at that spot. Hold ⌥ to go all the way in, ⌘ to not attach.",
        "Select an arrow and drag its middle handle to bend it.",
    ]

    /// The board, its notes saying `texts` in that order.
    public static func document(texts: [String] = WelcomeBoard.texts) -> CanvasDocument {
        precondition(texts.count == 6, "the welcome board has six notes")
        let origins = [CGPoint(x: 80, y: 80), CGPoint(x: 460, y: 80), CGPoint(x: 840, y: 80),
                       CGPoint(x: 80, y: 420), CGPoint(x: 460, y: 420), CGPoint(x: 840, y: 420)]
        let notes = zip(origins, texts).map { origin, text in
            ShapeRecord(StickyNote(frame: CGRect(origin: origin, size: StickyNote.defaultSize), text: text))
        }
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

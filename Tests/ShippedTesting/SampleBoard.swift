import Arrows
import Canvas
import CoreGraphics
import Mentions
import StickyNotes

/// A board for the tests of what ships: six notes in two rows of three, three of them linked by
/// arrows. Its notes sit where the proof of concept's welcome board had its own, so the parity
/// tests draw that board with the POC's texts (`document(texts:)`).
public enum SampleBoard {
    /// The six notes' text: the top row left to right, then the bottom row.
    public static let texts = [
        "Double-click empty space to add a note. Drag a note to move it.",
        "Double-click a note (or select it and press Return) to edit it.",
        "Pinch to zoom, scroll with two fingers to pan. Press H for the hand tool; drag the background to select.",
        "Point at a note, then drag one of its dots to another note to link them.",
        "Pause inside a note while linking to aim at that spot. Hold ⌥ to go all the way in.",
        "Select an arrow and drag its middle handle to bend it.",
    ]

    /// The board, its notes saying `texts` in that order: the first linked to the second, the fourth
    /// to the fifth, and the fifth to the sixth by a bent arrow.
    public static func document(texts: [String] = SampleBoard.texts) -> CanvasDocument {
        precondition(texts.count == 6, "the sample board has six notes")
        let origins = [CGPoint(x: 80, y: 80), CGPoint(x: 460, y: 80), CGPoint(x: 840, y: 80),
                       CGPoint(x: 80, y: 420), CGPoint(x: 460, y: 420), CGPoint(x: 840, y: 420)]
        let notes = zip(origins, texts).map { origin, text in
            ShapeRecord(StickyNote(frame: CGRect(origin: origin, size: StickyNote.defaultSize), text: MentionText(plain: text)))
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

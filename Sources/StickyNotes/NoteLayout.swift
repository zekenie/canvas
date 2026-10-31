import AppKit
import Canvas
import Mentions
import Types

/// Where a note's parts are: its paper, its words, and what goes under them (a type's rows).
@MainActor
struct NoteLayout {
    /// The paper: the laid-out frame.
    let frame: CGRect
    /// Where its words are drawn.
    let words: CGRect
    /// Where the rows go; nil with none.
    let block: CGRect?
    /// What a relationship type is drawn as: a pill, not a note (Types'); nil for every other note. Its frame is the capsule's.
    let pill: TypePill?

    /// With no rows, the stored frame and its words inset by the padding, nothing measured: the note
    /// as it was drawn before it had any. With rows, the frame `size(of:rows:)` says, as wide as the note
    /// stores, its words at that width (a line at least while edited), and the rows right under the words. A relationship type
    /// (`TypeRows.pill`) is a capsule of the size Types says, centered on the middle of its stored frame, with no words
    /// and no rows (those it keeps are not drawn).
    init(_ shape: ShapeRecord<StickyNote>, in context: ShapeContext) {
        let p = NoteStyle.padding
        guard let rows = context.layoutInput(TypeRows.extent, of: shape) else {
            if let pill = NoteLayout.pill(shape, in: context) {
                frame = NoteLayout.pillFrame(pill, in: shape.frame)
                words = .zero
                self.pill = pill
            } else {
                frame = shape.frame
                words = shape.frame.insetBy(dx: p, dy: p)
                pill = nil
            }
            block = nil
            return
        }
        pill = nil
        let size = NoteLayout.size(of: shape.props, rows: rows)
        let inner = size.width - p * 2
        let height = NoteLayout.wordsHeight(of: shape.props.text, width: inner, rows: rows)
        frame = CGRect(origin: shape.frame.origin, size: size)
        words = CGRect(x: frame.minX + p, y: frame.minY + p, width: inner, height: height)
        block = CGRect(x: frame.minX + p, y: frame.minY + NoteLayout.blockTop(of: shape.props.text, width: inner, rows: rows), width: inner, height: rows.height)
    }

    /// What Types says a relationship type is drawn as. A pill has no rows (it is the case of none), so this is asked only
    /// where there are none: a plain note costs one lookup.
    static func pill(_ shape: ShapeRecord<StickyNote>, in context: ShapeContext) -> TypePill? {
        // Only a relationship type is a pill: the mark, one added value, before the layout input, which a frame of type notes
        // zoomed out would otherwise ask of every one.
        guard shape[RelationshipProperty.self] == true else { return nil }
        return context.layoutInput(TypeRows.pill, of: shape)
    }

    /// The capsule's frame about the middle of the box the note stores, so a longer name grows both ways and what is
    /// drawn through it stays put.
    static func pillFrame(_ pill: TypePill, in box: CGRect) -> CGRect {
        CGRect(x: box.midX - pill.size.width / 2, y: box.midY - pill.size.height / 2, width: pill.size.width, height: pill.size.height)
    }

    /// How tall the words over rows are: as measured, and a line at least while the note is edited
    /// (`RowsExtent.wordsLine`), so an empty note's caret sits above its rows rather than under them.
    static func wordsHeight(of text: MentionText, width: CGFloat, rows: RowsExtent) -> CGFloat {
        let measured = NoteWords.height(of: text, width: width)
        return rows.wordsLine ? max(measured, NoteStyle.oneLineHeight) : measured
    }

    /// How far under the paper's top the rows start: the padding, the words and the gap under them if there are any. The one
    /// place that says so, for the layout and for a press made at rest that editing moves the rows from under.
    static func blockTop(of text: MentionText, width: CGFloat, rows: RowsExtent) -> CGFloat {
        let height = wordsHeight(of: text, width: width, rows: rows)
        return NoteStyle.padding + height + (height > 0 ? NoteStyle.blockGap : 0)
    }

    /// The paper's size: the stored one, no rows. With rows, as wide as it stores (rows never widen
    /// a note, so a type given to one moves nothing beside it) and as tall as the padding, the words,
    /// the gap, the rows and the padding, never under its least height (the height it was given, else
    /// a new note's) nor what it stores.
    static func size(of note: StickyNote, rows: RowsExtent?) -> CGSize {
        guard let rows else { return note.frame.size }
        let p = NoteStyle.padding
        let width = note.frame.width
        let words = wordsHeight(of: note.text, width: width - p * 2, rows: rows)
        let needed = max(note.leastHeight, p + words + (words > 0 ? NoteStyle.blockGap : 0) + rows.height + p)
        return CGSize(width: width, height: max(note.frame.height, needed))
    }
}

#if DEBUG
/// How many words have been measured (debug builds), so tests can hold a frame to what changed.
@MainActor
public enum NoteWordsCounts {
    public static var measured = 0
}
#endif

/// How tall a note's words are at a width, kept by what they say and how wide: asked for typed
/// notes only, again whenever a type's rows change, so the same words are never measured twice.
@MainActor
enum NoteWords {
    private struct Key: Hashable {
        let text: String
        let width: CGFloat
    }

    private static var heights: [Key: CGFloat] = [:]
    /// 0 for no text, else the height of its lines at `width` as `NoteStyle.fittedHeight` takes it,
    /// each mention measured as a live pill by the name it holds.
    static func height(of text: MentionText, width: CGFloat) -> CGFloat {
        guard !text.stored.isEmpty, width > 0 else { return 0 }
        let key = Key(text: text.stored, width: width)
        if let kept = heights[key] { return kept }
        if heights.count >= NoteStyle.wordsCacheCapacity { heights.removeAll() }
        #if DEBUG
        NoteWordsCounts.measured += 1
        #endif
        let height = NoteStyle.linesHeight(of: NoteStyle.text.measuredString(text, width: width), inner: width)
        heights[key] = height
        return height
    }
}

#if DEBUG
extension NoteWordsCounts {
    /// Where a note's rows go (debug builds): `NoteLayout.block`, which nothing draws until a type's
    /// rows are, so tests read it here.
    public static func block(of id: ShapeID, in editor: CanvasEditor) -> CGRect? {
        guard let note = editor.document[id]?.typed(as: StickyNote.self) else { return nil }
        return NoteLayout(note, in: editor.shapeContext).block
    }
}
#endif

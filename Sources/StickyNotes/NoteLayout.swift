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

    /// With no rows, the stored frame and its words inset by the padding, nothing measured: the note
    /// as it was drawn before it had any. With rows, the frame `size(of:rows:)` says, its words at the
    /// width the rows leave them, and the rows right under the words.
    init(_ shape: ShapeRecord<StickyNote>, in context: ShapeContext) {
        let p = NoteStyle.padding
        guard let rows = context.layoutInput(TypeRows.extent, of: shape) else {
            frame = shape.frame
            words = shape.frame.insetBy(dx: p, dy: p)
            block = nil
            return
        }
        let size = NoteLayout.size(of: shape.props, rows: rows)
        let inner = size.width - p * 2
        let height = NoteWords.height(of: shape.props.text, width: inner)
        let gap = height > 0 ? NoteStyle.blockGap : 0
        frame = CGRect(origin: shape.frame.origin, size: size)
        words = CGRect(x: frame.minX + p, y: frame.minY + p, width: inner, height: height)
        block = CGRect(x: frame.minX + p, y: frame.minY + p + height + gap, width: inner, height: rows.height)
    }

    /// The paper's size: the stored one, no rows. With rows, as wide as they read at and as tall as
    /// the padding, the words at that width, the gap, the rows and the padding, never under a new
    /// note's height; and no smaller than it stores either way.
    static func size(of note: StickyNote, rows: RowsExtent?) -> CGSize {
        guard let rows else { return note.frame.size }
        let p = NoteStyle.padding
        let width = max(note.frame.width, rows.minimumWidth)
        let words = NoteWords.height(of: note.text, width: width - p * 2)
        let needed = max(NoteStyle.size.height, p + words + (words > 0 ? NoteStyle.blockGap : 0) + rows.height + p)
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

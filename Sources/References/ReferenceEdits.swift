import Canvas
import Chrome
import CoreGraphics

/// How a reference is written: each keeps exactly one mode (so `target`, `words` and `query` never
/// disagree) and refits the pill's width to what it now says, growing rightward from where it is.
/// The editing view, a pick, a translation landing and the panel write through these, so a pill
/// is never the wrong width for its text.
@MainActor
public enum ReferenceEdits {
    /// Stands for `target`: its words and query are let go of.
    ///
    /// `place`: where the shape is, when that isn't where the pill is (the steps of `ReferenceState.placeOfTarget`: the
    /// containers it is inside, the board that leads), which the pill says over the shape's name, so the width has room
    /// for it (its fold at `ReferenceStyle.placeRoomMost`).
    public static func pick(_ props: inout Reference, _ target: ReferenceTarget, place: [PlaceStep] = []) {
        props.target = target
        props.words = ""
        props.query = nil
        fit(&props, place: place)
    }

    /// Stands for what `words` find, by `query` once they've been interpreted (nil: they haven't):
    /// no target. Writing words alone lets go of a query that was for other words.
    public static func find(_ props: inout Reference, words: String, query: String? = nil) {
        props.target = nil
        props.words = words
        props.query = query
        fit(&props)
    }

    /// Stands for nothing: an empty pill, as placed.
    public static func clear(_ props: inout Reference) {
        props.target = nil
        props.words = ""
        props.query = nil
        fit(&props)
    }

    /// Whether text says nothing: empty, or only white space.
    public static func isBlank(_ text: String) -> Bool {
        text.allSatisfy { $0.isWhitespace || $0.isNewline }
    }

    /// The width the pill's text asks for: the leading pad and symbol, the label, what may trail it
    /// (a dynamic pill's count, or a direct one's eye or warning, which come and go with no write, so
    /// their room is always there), and the trailing pad, never under `minWidth` or over `maxWidth`;
    /// an empty pill is the width it was placed at. A direct pill with a place is as wide as the wider of its name (and
    /// what may trail it) and its place's line folded at 234 points (`ReferenceStyle.placeRoomMost`), never padded to the
    /// whole of a long address.
    public static func width(of props: Reference, place: [PlaceStep] = []) -> CGFloat {
        let style = ReferenceStyle.self
        switch props.mode {
        case .empty:
            return style.defaultWidth
        case .direct:
            guard let target = props.target else { return style.defaultWidth }
            return fitted(label: target.label, trailing: style.glyphRoom, place: place)
        case .dynamic:
            return fitted(label: props.text, trailing: style.badgeRoom)
        }
    }

    private static func fitted(label: String, trailing: CGFloat, place: [PlaceStep] = []) -> CGFloat {
        let style = ReferenceStyle.self
        // As wide as it's set either way: a pill that comes to stand for nothing says it in italic.
        let text = max(ReferenceMemo.shared.width(of: label, italic: false), ReferenceMemo.shared.width(of: label, italic: true))
        let line = place.isEmpty ? 0 : style.placeLine(place, room: style.placeRoomMost).width
        return min(style.maxWidth, max(style.minWidth, ceil(style.padding + max(text + trailing, line))))
    }

    /// Pills for rows that moved (`Transaction.moveParts`: a row into another shape, out into one of its own) stand for where
    /// each went, on whichever board they are, in the move's step: another shape's row, or a shape as a whole (the row became
    /// one); and a pill for a shape moved as a whole (a shape that was all its one row, put back into another shape as a row:
    /// an endpoint taken out of its API) stands for that row, named as the row is and refit (a row's pill keeps its width); a read-only pill stays as it was.
    /// Found through the stand-ins that name each moved shape (`standIns(naming:)`), so it costs the moved rows' pills.
    static func follow(_ moves: [PartAddress: PartAddress], in transaction: inout Transaction) {
        var asked: Set<ShapeID> = []
        for from in moves.keys where asked.insert(from.shape).inserted {
            for pill in transaction.standIns(naming: from.shape) where transaction.mayWrite(on: pill.board) && !transaction.isReadOnly(pill.id, on: pill.board) {
                let there = transaction.contents(of: pill.board)
                guard let record = there[pill.id]?.typed(as: Reference.self), let target = record.props.target, target.id == from.shape,
                      let to = moves[PartAddress(from.shape, part: target.row)] else { continue }
                // A pill for the shape as a whole that now stands for its row says the row's name, as it is drawn, at the width that fits it.
                let label = target.row == nil ? transaction.part(at: to).map { $0.standsAlone ? $0.name : target.label + "." + $0.name } ?? target.label : target.label
                transaction.update(pill.id, on: pill.board, as: Reference.self) {
                    $0.props.target = ReferenceTarget(id: to.shape, label: label, row: to.part)
                    if label != target.label { fit(&$0.props) }
                }
            }
        }
    }

    /// Fits the pill to what it says.
    static func fit(_ props: inout Reference, place: [PlaceStep] = []) {
        props.frame.size = CGSize(width: width(of: props, place: place), height: ReferenceStyle.height)
    }
}

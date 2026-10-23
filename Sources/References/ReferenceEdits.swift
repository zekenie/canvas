import CoreGraphics

/// How a reference is written: each keeps exactly one mode (so `target`, `words` and `query` never
/// disagree) and refits the pill's width to what it now says, growing rightward from where it is.
/// The editing view, a pick, a translation landing and the panel write through these, so a pill
/// is never the wrong width for its text.
@MainActor
public enum ReferenceEdits {
    /// Stands for `target`: its words and query are let go of.
    ///
    /// `place`: where the shape is, when that isn't where the pill is (the containers it is inside, else the name
    /// of its board), which the pill says after the shape's name (`ReferenceStyle.boardGap`), so the width has room
    /// for it.
    public static func pick(_ props: inout Reference, _ target: ReferenceTarget, place: String? = nil) {
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
    /// an empty pill is the width it was placed at.
    public static func width(of props: Reference, place: String? = nil) -> CGFloat {
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

    private static func fitted(label: String, trailing: CGFloat, place: String? = nil) -> CGFloat {
        let style = ReferenceStyle.self
        // As wide as it's set either way: a pill that comes to stand for nothing says it in italic.
        let text = max(ReferenceMemo.shared.width(of: label, italic: false), ReferenceMemo.shared.width(of: label, italic: true))
        let named = place.map { style.boardGap + ReferenceMemo.shared.board($0, strength: 1).width } ?? 0
        let width = style.leadingPad + style.symbolBox + style.gap + text + named + trailing + style.trailingPad
        return min(style.maxWidth, max(style.minWidth, ceil(width)))
    }

    /// Fits the pill to what it says.
    static func fit(_ props: inout Reference, place: String? = nil) {
        props.frame.size = CGSize(width: width(of: props, place: place), height: ReferenceStyle.height)
    }
}

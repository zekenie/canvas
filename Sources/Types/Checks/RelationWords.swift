import Canvas

// What the check of a relationship says, as strings: one function a sentence, pure over what it is told.
// The misfit's and the unread end's are two sentences or one and end in a stop, as the drawing has them;
// they name the relationship type and the end by what a person sees, never a pill, and never call a
// relationship an edge type or a link.

/// What an end that does not fit is, in a word a person reads: `is a Layer`, `is a type`, `has no type`.
public enum EndDescription: Equatable, Sendable {
    /// The end is a type's own note.
    case type
    /// The end holds no `is` at all: a shape of this kind (`pocket`, lower case). A typeable kind (a note, a subboard,
    /// a frame) is never named so: with no type it reads as having none.
    case kind(String)
    /// The end's own types, those that are types, in list order (a nil title: untitled).
    case types([String?])
    /// A note with no type.
    case untyped
}

@MainActor
public enum RelationWords {
    /// The longest an end's name is quoted at.
    public static let nameLength = 40

    /// The relationship type's title, or `This arrow` when it has none.
    public static func subject(_ title: String?) -> String { title ?? "This arrow" }

    /// `a Company`, `an Agency`, `an untitled type`.
    public static func withArticle(_ title: String?) -> String {
        let name = title ?? "untitled type"
        let vowel = name.first.map { "aeiouAEIOU".contains($0) } ?? false
        return (vowel ? "an " : "a ") + name
    }

    /// An end's label, cut, in curly quotes: `“foundation”`.
    public static func quoted(_ label: String) -> String {
        label.count > nameLength ? "“" + label.prefix(nameLength) + "…”" : "“" + label + "”"
    }

    /// The types a side allows: `a Company`, `a Company or an Agency`, `a, b or c`; past four, the first four
    /// then `or N more`.
    public static func allowed(_ titles: [String?]) -> String {
        let shown = titles.prefix(4).map(withArticle)
        if titles.count > 4 { return shown.joined(separator: ", ") + " or \(titles.count - 4) more" }
        guard shown.count > 1 else { return shown.first ?? "anything" }
        return shown.dropLast().joined(separator: ", ") + " or " + shown[shown.count - 1]
    }

    private static func describing(_ end: EndDescription) -> String {
        switch end {
        case .type: "is a type"
        case .kind(let name): "is " + withArticle(name)
        case .types(let titles): "is " + titles.map(withArticle).joined(separator: " and ")
        case .untyped: "has no type"
        }
    }

    private static func runs(_ side: RelationshipSide) -> String { side == .to ? "runs to" : "runs from" }

    /// `Employment runs to a Company. “foundation” is a Layer.`
    public static func misfit(relation: String?, side: RelationshipSide, allowed titles: [String?], end label: String, is description: EndDescription) -> String {
        "\(subject(relation)) \(runs(side)) \(allowed(titles)). \(quoted(label)) \(describing(description))."
    }

    /// `layer has 2 notes, and should have at most 1`: a note holds more relationships in a row than the row allows.
    public static func onlyOne(_ name: String, count: Int) -> String { "\(name) has \(count) notes, and should have at most 1" }

    /// `Employment isn’t attached at both ends.`
    public static func free(relation: String?) -> String { "\(subject(relation)) isn’t attached at both ends." }

    /// The words for an end the check cannot read; nil for one that is read, and for one the app cannot show
    /// (nothing is said of that).
    public static func unread(_ reading: EndReading, relation: String?, side: RelationshipSide, label: (ShapeID) -> String) -> String? {
        let start = "\(subject(relation)) \(runs(side))"
        switch reading {
        case .note, .free, .unavailable: return nil
        case .gone(let called):
            return called.map { "\(start) \(quoted($0)), which is gone." } ?? "\(start) a note that is gone."
        case .notAdmitted(let shape, let needs):
            return "\(start) \(quoted(label(shape))), which isn’t \(needs.isEmpty ? "available" : needs)."
        case .query: return "\(start) a pill that stands for several notes."
        case .empty: return "\(start) a pill that stands for nothing."
        }
    }
}

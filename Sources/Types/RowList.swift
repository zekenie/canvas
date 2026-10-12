import Canvas

/// The rows a shape shows for the fields its types give it: one row a field, and past nine fields a fold.
/// Pure: the same list serves every shape with the same types, whichever surface draws or opens it.
///
/// The rule. Nine fields or fewer: every row shows. Ten or more: when two or more rows are inherited
/// (introduced by a type that is not on the shape's own list) they fold into one row, in the place of the
/// first of them: `from Person`, `4 fields`. Of the rows left, nine or fewer all show; ten or more show
/// the first eight and then `+N more`, the last ones folding. A fold shows only when it hides two rows or
/// more, so a note has at most ten rows.
public struct RowList: Equatable, Sendable {
    public enum Item: Equatable, Sendable {
        case field(Resolved.Field)
        case fold(Fold)
    }

    public struct Fold: Equatable, Sendable {
        /// The rows it hides, in row order.
        public var folded: [Resolved.Field]
        /// The types the folded rows came from, in row order: one for `from Person`, several for
        /// `from 2 types`; none for `+N more`.
        public var sources: [ShapeID]
        /// `from Person`: every folded row came from this one type.
        public var from: ShapeID? { sources.count == 1 ? sources[0] : nil }
        /// `+N more`.
        public var isMore: Bool { sources.isEmpty }

        public init(folded: [Resolved.Field], sources: [ShapeID]) {
            self.folded = folded
            self.sources = sources
        }
    }

    public var items: [Item]
    /// Every field, the folded ones too, in row order.
    public var all: [Resolved.Field]

    /// The rows of `resolved` for a shape whose own types are `own`: a type's note passes itself, a note
    /// that is one its `is` list. A field is inherited when the type that introduced it is not in `own`.
    public init(_ resolved: Resolved, own: Set<ShapeID>) {
        let fields = resolved.fields
        all = fields
        guard fields.count > Self.shownInFull else {
            items = fields.map(Item.field)
            return
        }
        let inherited = fields.filter { !own.contains($0.introducedBy) }
        let foldsInherited = inherited.count >= 2
        let rest = foldsInherited ? fields.filter { own.contains($0.introducedBy) } : fields
        // What is left past the first eight folds as `+N more`, the last ones, when that hides two or more.
        let hidden = rest.count > Self.shownInFull ? Array(rest.dropFirst(Self.shownBeforeFold)) : []
        let hiddenNames = Set(hidden.map(\.field.name))
        var items: [Item] = [], placedInherited = false
        for field in fields {
            if foldsInherited, !own.contains(field.introducedBy) {
                if !placedInherited {
                    placedInherited = true
                    var sources: [ShapeID] = []
                    for held in inherited where !sources.contains(held.introducedBy) { sources.append(held.introducedBy) }
                    items.append(.fold(Fold(folded: inherited, sources: sources)))
                }
            } else if !hiddenNames.contains(field.field.name) {
                items.append(.field(field))
            }
        }
        if !hidden.isEmpty { items.append(.fold(Fold(folded: hidden, sources: []))) }
        self.items = items
    }

    /// How many rows that is, without building them: what a layout needs.
    public static func count(of resolved: Resolved, own: Set<ShapeID>) -> Int {
        let total = resolved.fields.count
        guard total > shownInFull else { return total }
        let inherited = resolved.fields.filter { !own.contains($0.introducedBy) }.count
        let folds = inherited >= 2 ? 1 : 0
        let rest = total - (folds == 1 ? inherited : 0)
        return folds + (rest > shownInFull ? shownBeforeFold + 1 : rest)
    }

    /// Up to this many rows show with no fold at all.
    static let shownInFull = 9
    /// Past that, this many show and the rest fold.
    static let shownBeforeFold = 8
}

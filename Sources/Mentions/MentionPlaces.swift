import Boards
import Canvas

/// Where a shape is, as a list of shapes says it beside the shape's name: the names of the containers
/// it is inside, outermost first, "Alpha › Beta" (`ShapePath`'s way of saying them, a container with no
/// title by what its kind is called, set fainter), or, for a shape in none, the name of the board it is
/// on. What tells two shapes of one name apart in the `@` picker, the reference list and a relation
/// row's list. The containers the board shown is inside are left out (`MentionState.place(ofShape:)`),
/// so a shape directly on the board shown has none.
public struct MentionPlace: Hashable, Sendable {
    /// What is said, as the list shows it.
    public let text: String
    /// The characters of `text` set fainter: a container with no title, called by its kind.
    public let dimmed: [Range<Int>]
    /// The characters of `text` the query matched, when it matched this shape by its path.
    public let matched: [Range<Int>]

    public init(text: String, dimmed: [Range<Int>] = [], matched: [Range<Int>] = []) {
        self.text = text
        self.dimmed = dimmed
        self.matched = matched
    }

    /// The containers, outermost first, with the characters of each name the query matched (a range of
    /// `Character` offsets in the name's text, as `PathMatcher.Match` gives them; none for a shape
    /// found by its title).
    public init(names: [ContainerName], matched: [[Range<Int>]] = []) {
        var text = "", dimmed: [Range<Int>] = [], found: [Range<Int>] = [], offset = 0
        for (index, name) in names.enumerated() {
            if index > 0 {
                text += ShapePath.separator
                offset += ShapePath.separator.count
            }
            let length = name.text.count
            if name.isPlaceholder {
                dimmed.append(offset..<offset + length)
            } else if matched.indices.contains(index) {
                found += matched[index].map { offset + $0.lowerBound..<offset + $0.upperBound }
            }
            text += name.text
            offset += length
        }
        self.init(text: text, dimmed: dimmed, matched: found)
    }

    /// A place that is a board's name.
    public init(board: String) {
        self.init(text: board)
    }

    /// How VoiceOver says it, after the kind: "in Alpha › Beta".
    public var spoken: String { "in \(text)" }

    /// The place after `prefix` in a line (the kind and a dot, "Note · "), with the ranges moved over it.
    func detail(after prefix: String) -> (text: String, dimmed: [Range<Int>], matched: [Range<Int>]) {
        let shift = prefix.count
        func moved(_ ranges: [Range<Int>]) -> [Range<Int>] { ranges.map { $0.lowerBound + shift..<$0.upperBound + shift } }
        return (prefix + text, moved(dimmed), moved(matched))
    }
}

extension MentionState {
    /// Where a shape is, from the board shown: the containers it is inside (frames, and the shapes
    /// whose boards hold it; Boards' `ShapePaths`), outermost first, less those the board shown is inside
    /// too when the shape is inside it, so a shape directly on the board shown has none; for a shape in no
    /// container left, the name of the board it is on (`boardName(ofShape:)`), nil on the board shown.
    /// `matched` are the characters of each container's name the query matched, for the containers of the
    /// shape's whole path, outermost first.
    public func place(ofShape id: ShapeID, matched: [[Range<Int>]] = []) -> MentionPlace? {
        let containers = containersShown(of: id)
        if containers.isEmpty { return boardName(ofShape: id).map { MentionPlace(board: $0) } }
        return MentionPlace(names: containers.map(\.name), matched: containers.map { matched.indices.contains($0.index) ? matched[$0.index] : [] })
    }

    /// The containers a place says for a shape, outermost first, each with its place on the shape's whole path.
    func containersShown(of id: ShapeID) -> [(name: ContainerName, index: Int)] {
        var all = paths.containers(of: id)
        var skipped = 0
        if let owner = editor.board.owner {
            let shown = paths.containers(of: owner) + [owner]
            if all.starts(with: shown) {
                all.removeFirst(shown.count)
                skipped = shown.count
            }
        }
        return all.enumerated().map { (paths.node($1).name, skipped + $0) }
    }
}

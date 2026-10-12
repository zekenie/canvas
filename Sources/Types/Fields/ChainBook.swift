import Canvas

/// The file's types as a chain reads them (`ChainCatalog`): each type's schema read once as a level, by
/// the text it was read from. Where the text is half typed, the level is that of the shape's last text
/// that was a JSON object (`SchemaReadings`' `shown`), so a type being edited keeps its rows until the
/// JSON parses again; a type whose text was never an object says nothing. What the chain makes of a
/// list of types is the field book's to keep.
@MainActor
final class ChainBook {
    private let index: TypeIndex
    /// A type's schema read as a level, by the text it was read from.
    private var levels: [ShapeID: (text: String, level: ChainLevel)] = [:]

    init(index: TypeIndex) { self.index = index }

    /// What a type says and what it builds on (later first); nil unless the shape is a type.
    func node(_ id: ShapeID) -> ChainNode? {
        guard let text = index.schemaText(of: id) else { return nil }
        return ChainNode(level: level(of: id, text: text), parents: index.graph.parents(of: id))
    }

    /// The types as values: the same answer anywhere, whichever thread asks of the copy.
    var catalog: some ChainCatalog { Catalog(book: self) }

    /// Forgets the levels of shapes that are no longer types.
    func prune() {
        levels = levels.filter { index.isType($0.key) }
    }

    private func level(of id: ShapeID, text: String) -> ChainLevel {
        if let kept = levels[id], kept.text == text { return kept.level }
        let level = SchemaReadings.reading(of: text, for: id).shownRoot.map { ChainLevel(root: $0) } ?? ChainLevel()
        levels[id] = (text, level)
        return level
    }

    private struct Catalog: ChainCatalog {
        let book: ChainBook
        func node(_ id: ShapeID) -> ChainNode? {
            MainActor.assumeIsolated { book.node(id) }
        }
    }
}

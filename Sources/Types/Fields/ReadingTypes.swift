import Canvas

/// The file's types as a layout under way or a run reads them: through a `LayoutReading`, so a type
/// written in the same transaction (a paste, `/is-a`, a draw's script) is read as it stands and a type
/// it deleted is gone. What `RowBook` sizes a typed note by and `FieldBook` resolves a run's check over.
/// A type's level is the field book's own while the text is the committed one (a type whose JSON is
/// broken mid-edit keeps the rows of its last good JSON, as after the commit), else read from the
/// text, once (`FieldBook.level(readFrom:of:)`).
struct ReadingTypes: ChainCatalog {
    /// The editor's book, which keeps the levels read.
    let book: FieldBook
    let reading: LayoutReading
    /// The shape being laid out or checked: read in place of the file's under its id.
    let record: AnyShapeRecord?

    /// A shape as this reading has it.
    @MainActor
    func shape(_ id: ShapeID) -> AnyShapeRecord? {
        id == record?.id ? record : reading.shape(inFile: id)
    }

    func node(_ id: ShapeID) -> ChainNode? {
        MainActor.assumeIsolated {
            guard let shape = shape(id), let schema = shape[TypeSchemaProperty.self] else { return nil }
            // Its own list as the commit has it: the index's for a type the run left as it was (so none on a board the
            // app can't show, which a transaction reaches), else the record's, read as the index reads one.
            let committed = id != record?.id && !reading.isChanged(id) ? reading.service(TypeIndex.self) : nil
            let links = committed?.links(of: id) ?? TypeIndex.links(of: shape)
            return ChainNode(level: book.level(readFrom: schema.text, of: id), parents: links.reversed().map(\.shape))
        }
    }
}

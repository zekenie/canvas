import Canvas
import Mentions

// The words a kind's shapes say what a type holds in, as Types reads and writes them without knowing
// the kind: a note's text, and later an arrow's label. A kind hands them over once, through
// `typeWords(_:drawnIn:fitting:)` (a key path to its `MentionText`, where it draws them, and what
// writing them changes besides: a note's height), and Types reads, writes and highlights them
// through `TypeWords` alone. Nothing in Types names a note.

/// Each kind's words (`TypeWordsContribution`), one per kind: what the sync writes a type's schema
/// from and back, where its highlights are drawn, and where a popover's words are found.
public enum TypeWords {}

extension TypeWords: KeyedExtensionPoint {
    public typealias Contribution = TypeWordsContribution
    public static var owner: PluginID { .types }
    public static func uniqueKeys(of _: TypeWordsContribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
    public static func summary(of _: TypeWordsContribution, for target: ShapeTarget) -> String { "type words → \(target)" }

    /// A kind that can be a type, or an instance of one, says what it holds in words: `canBeType()`
    /// and `typeable()` need `typeWords`.
    public static func check(_ registry: Registry) throws(RegistryError) {
        for kind in registry.kinds where registry.contributions(to: TypeWords.self, for: kind).isEmpty {
            let properties = registry.properties(for: kind)
            if properties.contains(TypeSchemaProperty.key) { throw .invalid(point: "TypeWords", reason: "\(kind) holds schema but has no typeWords") }
            if properties.contains(IsAProperty.key) { throw .invalid(point: "TypeWords", reason: "\(kind) holds is but has no typeWords") }
        }
    }
}

/// One kind's words, read and written as any shape's: only the sugar makes one.
@MainActor
public struct TypeWordsContribution {
    /// The shape's words; nil for a shape of another kind.
    public let words: @MainActor (AnyShapeRecord) -> MentionText?
    /// Where the shape draws them, as its render draws them (nil: not drawn now). Given the context
    /// the shape is in, for a kind whose words are placed against the shapes around it (an arrow's
    /// label).
    public let placement: @MainActor (AnyShapeRecord, ShapeContext) -> MentionTextPlacement?
    /// Writes the shape's words in a transaction, and fits the shape to them as the kind fits it.
    public let write: @MainActor (inout Transaction, ShapeID, MentionText) -> Void

    init<P: ShapeProps>(_: P.Type, words: WritableKeyPath<P, MentionText>,
                        drawnIn: @escaping @MainActor (ShapeRecord<P>, ShapeContext) -> MentionTextPlacement?,
                        fitting: @escaping @MainActor (inout P) -> Void) {
        self.words = { $0.typed(as: P.self)?.props[keyPath: words] }
        placement = { record, context in record.typed(as: P.self).flatMap { drawnIn($0, context) } }
        write = { transaction, id, text in
            transaction.update(id, as: P.self) { shape in
                shape.props[keyPath: words] = text
                fitting(&shape.props)
            }
        }
    }
}

extension ShapeRegistrar {
    /// This kind's words, where a type's are said: the text at `words`, drawn where `drawnIn` says
    /// (the placement its render draws, so highlights and popovers fall on its words), and what a
    /// write of them changes besides (`fitting`: a note's height, fitted to its text). Types reads
    /// and writes them through this alone.
    ///
    ///     note.typeWords(\.text, drawnIn: { $0.mentionTexts.first }, fitting: { StickyNoteDefinition().derive(&$0) })
    public mutating func typeWords(_ words: WritableKeyPath<Definition.Props, MentionText>,
                                   drawnIn: @escaping @MainActor (ShapeRecord<Definition.Props>) -> MentionTextPlacement?,
                                   fitting: @escaping @MainActor (inout Definition.Props) -> Void = { _ in }) {
        typeWords(words, drawnIn: { shape, _ in drawnIn(shape) }, fitting: fitting)
    }

    /// `typeWords` for a kind that draws its words against the shapes around it (an arrow's label,
    /// on its body): `drawnIn` is given the context to ask for their geometry.
    ///
    ///     arrow.typeWords(\.text, drawnIn: { arrow, shapes in shapes.geometry(of: arrow.id)?.label.map { ArrowLabels.placement(of: arrow.props.text, in: $0) } })
    public mutating func typeWords(_ words: WritableKeyPath<Definition.Props, MentionText>,
                                   drawnIn: @escaping @MainActor (ShapeRecord<Definition.Props>, ShapeContext) -> MentionTextPlacement?,
                                   fitting: @escaping @MainActor (inout Definition.Props) -> Void = { _ in }) {
        contribute(TypeWordsContribution(Definition.Props.self, words: words, drawnIn: drawnIn, fitting: fitting), to: TypeWords.self)
    }

    /// This kind's shapes can be types: each may hold a JSON Schema (`TypeSchemaProperty`), which
    /// `/is-a type` gives it and its words are kept in step with. Needs `typeWords`.
    public mutating func canBeType() {
        optIn(to: TypeSchemaProperty.self)
    }
}

extension Registry {
    /// The words of a kind that has them (`typeWords`); nil for any other.
    public func typeWords(of kind: ShapeKind) -> TypeWordsContribution? {
        contributions(to: TypeWords.self, for: kind).first
    }

    /// Whether the kind's shapes can be types (`canBeType()`).
    public func canBeType(_ kind: ShapeKind) -> Bool {
        properties(for: kind).contains(TypeSchemaProperty.key)
    }
}

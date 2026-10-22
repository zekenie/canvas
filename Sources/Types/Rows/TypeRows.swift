import Canvas
import CoreGraphics

// What a kind that shows a type's rows lays itself out with, and where it draws them. Types provides the
// extent (`RowBook`) and draws the rows; the kind says only where they go, as `typeWords` says where its
// words are, so Types names no kind.

/// The room a shape's rows take: what a kind that shows them lays itself out with.
public struct RowsExtent: Hashable, Sendable {
    /// The least width the rows read at.
    public var minimumWidth: CGFloat
    /// How tall they are, all of them, the fold included.
    public var height: CGFloat
    /// The words over them have a line, however empty they are: the shape is being edited, so its caret sits above the
    /// rows rather than under them.
    public var wordsLine: Bool

    public init(minimumWidth: CGFloat, height: CGFloat, wordsLine: Bool = false) {
        self.minimumWidth = minimumWidth
        self.height = height
        self.wordsLine = wordsLine
    }
}

public enum TypeRows {
    /// The room a shape's rows take, as the shape's layout input (`context.layoutInput`): nil for a
    /// shape with no rows. Types provides it (`RowBook`), for the kinds that say where their rows go
    /// (`typeRows(drawnIn:)`).
    public static let extent = LayoutInputKey<RowsExtent>("type-rows")
}

/// Where each kind draws its rows: one contribution a kind. Owner Types.
public enum TypeRowsPlaces {}

extension TypeRowsPlaces: KeyedExtensionPoint {
    public typealias Contribution = TypeRowsContribution
    public static var owner: PluginID { .types }
    public static func uniqueKeys(of _: TypeRowsContribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
    public static func summary(of _: TypeRowsContribution, for target: ShapeTarget) -> String { "type rows → \(target)" }

    /// A kind that says where rows go has shapes that are types or instances of them: it holds `schema`
    /// or `is`.
    public static func check(_ registry: Registry) throws(RegistryError) {
        for kind in registry.kinds where !registry.contributions(to: TypeRowsPlaces.self, for: kind).isEmpty {
            let properties = registry.properties(for: kind)
            if !properties.contains(TypeSchemaProperty.key) && !properties.contains(IsAProperty.key) {
                throw .invalid(point: "TypeRowsPlaces", reason: "\(kind) says where its rows go but holds neither schema nor is")
            }
        }
    }
}

/// One kind's rows: only the sugar makes one.
@MainActor
public struct TypeRowsContribution {
    /// Where the shape's rows are drawn, world units; nil while it has none. The rect the kind's layout
    /// gives them, as laid out now.
    public let place: @MainActor (AnyShapeRecord, ShapeContext) -> CGRect?

    init<P: ShapeProps>(_: P.Type, drawnIn: @escaping @MainActor (ShapeRecord<P>, ShapeContext) -> CGRect?) {
        place = { record, context in record.typed(as: P.self).flatMap { drawnIn($0, context) } }
    }
}

extension ShapeRegistrar {
    /// This kind draws a type's rows, in the rect `drawnIn` gives (a note: `NoteLayout.block`), as
    /// `typeWords(drawnIn:)` says where its words are. Only such a kind is given `TypeRows.extent`: an
    /// arrow says nothing, so it has no rows. The kind's render calls `context.drawTypeRows`.
    ///
    ///     note.typeRows(drawnIn: { shape, context in NoteLayout(shape, in: context).block })
    public mutating func typeRows(drawnIn: @escaping @MainActor (ShapeRecord<Definition.Props>, ShapeContext) -> CGRect?) {
        contribute(TypeRowsContribution(Definition.Props.self, drawnIn: drawnIn), to: TypeRowsPlaces.self)
    }
}

extension Registry {
    /// Where a kind draws its rows (`typeRows(drawnIn:)`); nil for a kind that says nowhere.
    public func typeRows(of kind: ShapeKind) -> TypeRowsContribution? {
        contributions(to: TypeRowsPlaces.self, for: kind).first
    }
}

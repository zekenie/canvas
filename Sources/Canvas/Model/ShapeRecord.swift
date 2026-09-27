import CoreGraphics
import Foundation

/// A shape kind's own data: a plain value, defined by its list of properties (`SchemaDefined`),
/// which is how boards write it and what its JSON Schema says. The kind is stated here, once, and
/// so is its history: how older boards' props become today's (`migrations`, none by default).
public protocol ShapeProps: SchemaDefined, Equatable {
    static var kind: ShapeKind { get }
    /// Append only; see `PropsMigration`.
    static var migrations: [PropsMigration] { get }
}

/// Props of shapes that occupy a rectangle. The core's defaults (geometry, hit testing, culling,
/// moving, placing, editing) work from it, so a kind without one (a connector) supplies its own.
public protocol BoxShapeProps: ShapeProps {
    /// Position and size in world coordinates.
    var frame: CGRect { get set }
}

/// One shape, with its props typed. What definitions and plugin code work with.
public struct ShapeRecord<Props: ShapeProps>: Identifiable, Equatable, Sendable {
    public let id: ShapeID
    public var props: Props
    /// What plugins add to the kind: `shape[ChecklistProperty.self]`.
    var added = AddedValues()
    public init(id: ShapeID = ShapeID(), _ props: Props) {
        self.id = id
        self.props = props
    }
}

extension ShapeRecord where Props: BoxShapeProps {
    public var frame: CGRect {
        get { props.frame }
        set { props.frame = newValue }
    }
}

/// A shape of any kind, as the document stores it.
public struct AnyShapeRecord: Identifiable, Equatable, Sendable {
    public let id: ShapeID
    /// Stored alongside `props` rather than read off them, so a board can keep a shape whose kind
    /// isn't installed (`isOpaque`).
    public let kind: ShapeKind
    public internal(set) var props: any ShapeProps
    /// Where it sits in the stack. Nil until the shape is in a document, which gives it one; only
    /// the document's order changes it (`bringToFront`, `sendToBack`).
    public internal(set) var stackingKey: StackingKey?
    /// What plugins keep about the shape beside its props, each member typed by its key
    /// (`meta[CopiedFrom.self]`). Kept with the shape in its board. Changed, like the props, in a
    /// transaction: `tx.update(id) { $0.meta[Key.self] = value }`.
    public var meta = ShapeMeta()
    /// The values of the properties plugins add to its kind (`record[ChecklistProperty.self]`).
    var added = AddedValues()

    public init<P: ShapeProps>(_ shape: ShapeRecord<P>) {
        id = shape.id
        kind = P.kind
        props = shape.props
        added = shape.added
    }

    /// The same shape under another id: its kind, props, added properties and meta, with no place
    /// in a stack yet. Props that name other shapes still name them (see `remappingReferences`).
    public func copy(as id: ShapeID = ShapeID()) -> AnyShapeRecord {
        var copy = AnyShapeRecord(id: id, kind: kind, props: props, stackingKey: nil)
        copy.meta = meta
        copy.added = added
        return copy
    }

    public func typed<P: ShapeProps>(as _: P.Type = P.self) -> ShapeRecord<P>? {
        guard let props = props as? P else { return nil }
        var shape = ShapeRecord(id: id, props)
        shape.added = added
        return shape
    }

    /// The shape's rectangle, if its kind has one.
    public var box: CGRect? {
        get { (props as? any BoxShapeProps)?.frame }
        set {
            guard let newValue, var boxed = props as? any BoxShapeProps else { return }
            boxed.frame = newValue
            props = boxed
        }
    }

    mutating func modify<P: ShapeProps>(as _: P.Type, _ body: (inout ShapeRecord<P>) -> Void) {
        guard var shape = typed(as: P.self) else { return }
        body(&shape)
        props = shape.props
        added = shape.added
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.kind == b.kind && a.stackingKey == b.stackingKey && a.meta == b.meta && a.added == b.added
            && a.props.isEqual(to: b.props)
    }
}

extension ShapeProps {
    fileprivate func isEqual(to other: any ShapeProps) -> Bool { (other as? Self) == self }
}

import Canvas

// A connection from a shape to itself: never kept, but a port's drag may end where it starts on a shape some plugin
// says takes one, so that its release makes something else of it (Types: a relationship type from a type to itself).

/// The shapes a port's drag may end on where it starts: each plugin's say, for the shapes of the kinds its scope reaches,
/// asked only of the shape the drag started from, whenever `channel(of:endingAt:)` is (as the pointer moves over it, and
/// on each frame the faint outlines are drawn while it is in view), so it must be cheap; on the channels that shape takes.
/// Such a connection is never kept: the connector hands it to its release, and takes back what the release leaves
/// joining a shape to itself. With none, a port's drag never ends where it starts.
public enum SelfConnections {}

extension SelfConnections: ExtensionPoint {
    public typealias Contribution = @MainActor (AnyShapeRecord, CanvasEditor) -> Bool
    public static var owner: PluginID { .ports }
    public static var scope: PointScope { .scoped }
    public static func summary(of _: Contribution, for target: ShapeTarget) -> String { "connects to itself → \(target)" }
}

extension ScopedRegistrar {
    /// A port's drag from a shape of the kinds the scope reaches may end on that shape, where `when` says so of it: for a
    /// release that makes something else of it, since what the release leaves joining the shape to itself is taken back.
    ///
    ///     registrar.forShapes(holding: TypeSchemaProperty.self) { types in
    ///         types.connectsToItself { shape, editor in shape[TypeSchemaProperty.self] != nil }
    ///     }
    public mutating func connectsToItself(when test: @escaping @MainActor (AnyShapeRecord, CanvasEditor) -> Bool) {
        contribute(test, to: SelfConnections.self)
    }
}

/// The key `Registry.memo` keeps a kind's `SelfConnections` contributions under.
private struct SelfConnectionsKey: Hashable {
    let kind: ShapeKind
}

extension CanvasEditor {
    /// Whether a port's drag from `shape` may end on it: some plugin says so (`SelfConnections`). The kind's
    /// contributions are found once (it's asked on every frame of a drag).
    func connectsToItself(_ shape: AnyShapeRecord) -> Bool {
        let registry = registry
        return registry.memo(SelfConnectionsKey(kind: shape.kind)) { registry.contributions(to: SelfConnections.self, for: shape.kind) }
            .contains { $0(shape, self) }
    }
}

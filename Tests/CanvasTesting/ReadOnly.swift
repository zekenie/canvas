@_spi(Host) import Canvas

/// A flag any shape can have that makes it read-only: what Locking does with its lock, for tests of
/// read-only shapes that can't depend on Locking (the core's, and a horizontal's).
public enum Frozen {}

extension Frozen: ShapeProperty {
    public static let key: PropertyKey = "frozen"
    public static var defaultValue: Bool? { nil }
}

/// Declares `Frozen`, opts every kind into it, and makes frozen shapes read-only
/// (`registrar.readOnlyShapes`). Every refusal services hear goes in `log`, one entry each.
public struct FreezingPlugin: CanvasPlugin {
    let log: RefusalLog
    public init(log: RefusalLog = RefusalLog()) { self.log = log }
    public var id: PluginID { "freezing" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.declare(Frozen.self)
        registrar.optInEveryShape(to: Frozen.self)
        registrar.readOnlyShapes { $0[Frozen.self] == true }
        let log = log
        registrar.service { _ in RefusalListener(log: log) }
    }
}

/// The refusals services heard (`EditorService.didRefuseChanges`), in order.
@MainActor
public final class RefusalLog {
    public var refusals: [Set<ShapeID>] = []
    public nonisolated init() {}
}

@MainActor
final class RefusalListener {
    let log: RefusalLog
    init(log: RefusalLog) { self.log = log }
}

extension RefusalListener: EditorService {
    func didRefuseChanges(to ids: Set<ShapeID>, in editor: CanvasEditor) { log.refusals.append(ids) }
}

extension CanvasEditor {
    /// Freezes shapes (or thaws them, with `false`), in one transaction.
    public func freeze(_ ids: [ShapeID], _ frozen: Bool = true) {
        transact { transaction in
            for id in ids { transaction.update(id) { $0[Frozen.self] = frozen ? true : nil } }
        }
    }
}

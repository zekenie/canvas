import Canvas
import ContextMenus
import Selection

/// Locking, as a plugin: a shape can be locked, and then nothing changes it (not a drag, Delete,
/// the eraser, editing, the panel or a menu item) until it's unlocked. Every try shakes it, and a
/// lock chip sits just above its top-right corner. Shapes are locked from the context menu, and
/// unlocked there or with a click on the chip, which then shows the lock open for a moment (a click
/// on it locks the shape again) before it goes. Whether a shape is locked is something it knows
/// (tldraw's `isLocked`): an added property every kind opts into, `locked`. What makes it hold is
/// the core's: this plugin says locked shapes are read-only (`registrar.readOnlyShapes`), and the
/// core refuses changes to them.
extension PluginID {
    public static let locking: PluginID = "locking"
}

/// Whether a shape is locked: `true` on a locked shape, and nothing on the rest (unlocking takes
/// it away), so a board holds it only for the shapes that are.
public enum LockedProperty {}

extension LockedProperty: ShapeProperty {
    public static let key: PropertyKey = "locked"
    public static var defaultValue: Bool? { nil }
}

extension AnyShapeRecord {
    /// Whether the shape is locked (`LockedProperty`): no change, move or deletion takes until it's
    /// unlocked.
    public var isLocked: Bool { self[LockedProperty.self] == true }
}

extension CanvasEditor {
    /// Whether the shape is there and locked.
    public func isLocked(_ id: ShapeID) -> Bool { document[id]?.isLocked ?? false }

    /// Locks these shapes, in one transaction.
    public func lock(_ ids: [ShapeID]) {
        transact { transaction in
            for id in ids { transaction.update(id) { $0[LockedProperty.self] = true } }
        }
    }

    /// Unlocks these shapes, in one transaction: the one change a locked shape takes.
    public func unlock(_ ids: [ShapeID]) {
        transact { transaction in
            for id in ids { transaction.update(id) { $0[LockedProperty.self] = nil } }
        }
    }
}

/// Lock and Unlock, after every other group in a context menu, as Figma and Keynote have them.
public enum LockMenuGroup {}
extension LockMenuGroup: MenuGroup {
    public static var order: Int { 300 }
}

/// A shape's lock chip, as a button the select tool clicks (`CanvasButtons`): what
/// `editor.hoveredButton` and `editor.pressedButton` are while the pointer's on it.
public struct LockChip: Hashable, Sendable {
    public let shape: ShapeID
    public init(shape: ShapeID) { self.shape = shape }
}

public struct LockingPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .locking }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.declare(LockedProperty.self)
        registrar.optInEveryShape(to: LockedProperty.self)
        registrar.readOnlyShapes { $0.isLocked }
        registrar.service { LockState(editor: $0) }
        registrar.overlay(LockOverlay())
        // A click on a locked shape's chip unlocks it; on the open lock it shows for a moment
        // after, locks it again.
        registrar.canvasButtons(at: { editor, point in editor.service(LockState.self)?.chip(atViewPoint: point) },
                                click: { chip, editor in editor.service(LockState.self)?.click(chip) })
        // One item for the menu's shapes, as tldraw's toggleLock: Unlock when every one is locked,
        // otherwise Lock, which locks the rest. Items for the canvas, so a mix of locked and
        // unlocked shapes still gets one; with no shapes (empty canvas), neither.
        registrar.contextMenuForCanvas {
            MenuItem("Lock", in: LockMenuGroup.self, when: { !$0.shapes.isEmpty && !$0.allLocked }) { ids, editor in
                editor.lock(ids)
            }
            MenuItem("Unlock", in: LockMenuGroup.self, when: { !$0.shapes.isEmpty && $0.allLocked }) { ids, editor in
                editor.unlock(ids)
            }
        }
    }
}

extension MenuSubject {
    fileprivate var allLocked: Bool { shapes.allSatisfy { editor.isLocked($0) } }
}

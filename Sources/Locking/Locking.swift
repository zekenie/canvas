import Adornments
import Canvas
import ContextMenus
import SlashCommands
import SwiftUI
import TableOfContents

/// Locking, as a plugin: a shape can be locked, and then nothing changes it (not a drag, Delete,
/// editing, the panel or a menu item) until it's unlocked. Every try shakes it, a lock
/// chip sits just above its top-right corner, and its row in the table of contents ends in a lock,
/// so the list says which are locked at a glance. Shapes are locked from the context menu, and
/// unlocked there or with a click on the chip, which then shows the lock open for a moment (a click
/// on it locks the shape again) before it goes; a shape's text can lock it too, with `/lock` on a line
/// of its own (slash commands). Whether a shape is locked is something it knows
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

    /// Locks these shapes, in one transaction (an undo step "Lock", unless it's part of another).
    public func lock(_ ids: [ShapeID]) {
        transact("Lock") { transaction in
            for id in ids { transaction.update(id) { $0[LockedProperty.self] = true } }
        }
    }

    /// Unlocks these shapes, in one transaction: the one change a locked shape takes ("Unlock").
    public func unlock(_ ids: [ShapeID]) {
        transact("Unlock") { transaction in
            for id in ids { transaction.update(id) { $0[LockedProperty.self] = nil } }
        }
    }
}

/// Lock and Unlock, after every other group in a context menu, as Figma and Keynote have them.
public enum LockMenuGroup {}
extension LockMenuGroup: MenuGroup {
    public static var order: Int { 300 }
}

/// A shape's lock chip: a lock in a disc at the right end of the row just above a locked shape,
/// where a title's pill starts at the other end, farthest out of what's there, as a state that
/// comes and goes. For a moment after a shape is unlocked it shows the lock open, fading. Zoomed
/// out, on a shape drawn as a skeleton, it's a blank disc, open or not, and a click on it does as
/// ever.
public enum LockChip {}

extension LockChip: Adornment {
    public static var placement: AdornmentPlacement { .aboveTopRight }
    public static var order: Int { 300 }
}

extension LockChip: ClickableAdornment {
    /// A locked shape's chip unlocks it; a just-unlocked one's locks it again.
    public static func click(on shape: ShapeID, in editor: CanvasEditor) { editor.service(LockState.self)?.click(shape) }
}

public struct LockingPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .locking }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.declare(LockedProperty.self)
        registrar.optInEveryShape(to: LockedProperty.self)
        registrar.readOnlyShapes { $0.isLocked }
        registrar.service { LockState(editor: $0) }
        // The chip, on the kinds that can be locked: on every locked shape, and for a moment on one
        // just unlocked (LockState's open lock).
        registrar.adornmentForEveryShape(LockChip.self, where: { $0.holds(LockedProperty.self) }) { shape, context in
            if shape.isLocked { return AdornmentLabel(systemImage: "lock.fill") }
            return context.service(LockState.self)?.openLockOpacity(of: shape.id).map { AdornmentLabel(systemImage: "lock.open.fill").opacity($0) }
        }
        // A lock at the end of a locked shape's row, on the kinds that can be locked, read from the
        // record alone.
        registrar.contentsMarkForEveryShape(where: { $0.holds(LockedProperty.self) }) { shape, _ in
            shape.isLocked ? ContentsMark(symbol: "lock.fill", color: .secondary, help: "Locked") : nil
        }
        // One item for the menu's shapes, as tldraw's toggleLock: Unlock when every one is locked,
        // otherwise Lock, which locks the rest. Items for the canvas, so a mix of locked and
        // unlocked shapes still gets one; with no shapes (empty canvas), neither. Each goes by the
        // shapes' own locks, of those that can take one: a shape in a locked frame is locked with
        // it, and its own lock can't change, so a menu for only such shapes has neither, and one
        // for some leaves them be.
        registrar.contextMenuForCanvas {
            MenuItem("Lock", in: LockMenuGroup.self, when: { !$0.lockable.isEmpty && !$0.allLocked }) { ids, editor in
                editor.lock(ids.filter { !editor.isLockedByContainer($0) })
            }
            MenuItem("Unlock", in: LockMenuGroup.self, when: { !$0.lockable.isEmpty && $0.allLocked }) { ids, editor in
                editor.unlock(ids.filter { !editor.isLockedByContainer($0) })
            }
        }
        // `/lock` typed on a line of a shape's text: the first command that ships. On the kinds that
        // can be locked, while the shape isn't. There is no `/unlock`: a locked shape's text can't
        // be edited, so it couldn't be typed.
        registrar.slashCommandsForEveryShape(where: { $0.holds(LockedProperty.self) }) {
            SlashCommand("lock", when: { !$0.isLocked }) { id, _, editor in editor.lock([id]) }
        }
    }
}

extension CanvasEditor {
    /// Whether the shape is in a container that can't change (a locked frame, at any depth), which
    /// holds it read-only with all it holds, its own lock included: neither Lock nor Unlock is for it.
    /// O(its depth).
    func isLockedByContainer(_ id: ShapeID) -> Bool {
        let document = document
        guard let record = document[id], let container = registry.container(of: record, in: document) else { return false }
        return isReadOnly(container)
    }
}

extension MenuSubject {
    /// The menu's shapes whose own lock can change: all but those in a locked frame.
    fileprivate var lockable: [ShapeID] { shapes.filter { !editor.isLockedByContainer($0) } }

    /// Whether every one of them is locked.
    fileprivate var allLocked: Bool { lockable.allSatisfy { editor.isLocked($0) } }
}

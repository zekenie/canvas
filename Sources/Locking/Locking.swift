import Adornments
import Canvas
import ContextMenus
import Keyboard
import SlashCommands
import SwiftUI
import TableOfContents

/// Locking, as a plugin: a shape can be locked, and then nothing changes it (not a drag, Delete,
/// editing, the panel or a menu item) until it's unlocked. Every try shakes it, a lock
/// chip sits just above its top-right corner, and its row in the table of contents ends in a lock,
/// so the list says which are locked at a glance. Shapes are locked from the context menu or with
/// ⇧L, and unlocked there or with a click on the chip, which then shows the lock open for a moment (a
/// click on it locks the shape again) before it goes; a shape's text can lock it too, with `/lock` on
/// a line of its own (slash commands). Each of them runs one of two commands, Lock or Unlock (⇧L
/// whichever can). Whether a shape is locked is something it knows (tldraw's `isLocked`): an added
/// property every kind opts into, `locked`. What makes it hold is
/// the core's: this plugin says locked shapes are read-only (`registrar.readOnlyShapes`), and the
/// core refuses changes to them.
extension PluginID {
    public static let locking: PluginID = "locking"
}

/// Whether a shape is locked: `true` on a locked shape, and nothing on the rest (unlocking takes
/// it away), so a board holds it only for the shapes that are.
public enum LockedProperty {}

extension CanvasCommand {
    /// Lock: the shapes whose own lock can change locked, while some aren't (the context menu's Lock,
    /// `/lock`, a just-unlocked shape's chip; ⇧L).
    public static let lock: CanvasCommand = "lock"
    /// Unlock: the shapes whose own lock can change unlocked, once every one is locked (the context
    /// menu's Unlock, a locked shape's chip; ⇧L).
    public static let unlock: CanvasCommand = "unlock"
}

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

/// A shape's lock chip: a lock in a disc at the right end of the row just above a locked shape,
/// where a title's pill starts at the other end, farthest out of what's there, as a state that
/// comes and goes. For a moment after a shape is unlocked it shows the lock open, fading. Zoomed
/// out, on a shape drawn as a skeleton, it isn't shown (as no adornment is), and so can't be clicked.
public enum LockChip {}

extension LockChip: Adornment {
    public static var placement: AdornmentPlacement { .aboveTopRight }
    public static var order: Int { 300 }
}

extension LockChip: ClickableAdornment {
    /// A locked shape's chip unlocks it; a just-unlocked one's locks it again.
    public static func click(_ click: AdornmentClick, in editor: CanvasEditor) { editor.service(LockState.self)?.click(click.shape) }
}

public struct LockingPlugin: ListedPlugin {
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
        // Lock and Unlock, as tldraw's toggleLock is one: Unlock when every shape is locked, otherwise
        // Lock, which locks the rest, so a mix of locked and unlocked shapes still gets one; with no
        // shapes (empty canvas), neither. Each goes by the shapes' own locks, of those that can take
        // one: a shape in a locked frame is locked with it, and its own lock can't change, so neither is
        // for only such shapes, and one for some leaves them be. Run as a try on such shapes alone (a
        // chip's click), each tries them, and the refusal shakes them. ⇧L runs whichever can run, while
        // nothing is under way or being edited; both items show it.
        registrar.command(.lock, title: "Lock", runs: .whenIdle, isEnabled: { !$0.locks.allLocked }) { subject in
            subject.editor.lock(subject.locks.tried)
        }
        registrar.command(.unlock, title: "Unlock", runs: .whenIdle, isEnabled: { $0.locks.canUnlock }) { subject in
            subject.editor.unlock(subject.locks.tried)
        }
        registrar.shortcut(KeyChord("l", .shift), "Lock or Unlock", forCommands: [.lock, .unlock])
        // Items for the canvas, in the state group, beside Group and Is a ▸.
        registrar.contextMenuForCanvas {
            MenuItem(command: .lock, in: StateMenuGroup.self)
            MenuItem(command: .unlock, in: StateMenuGroup.self)
        }
        // `/lock` typed on a line of a shape's text (Titles offers `/title`, the other command that
        // ships): on the kinds that can be locked, while the shape can be locked. There is no `/unlock`:
        // a locked shape's text can't be edited, so it couldn't be typed.
        registrar.slashCommandsForEveryShape(where: { $0.holds(LockedProperty.self) }) {
            SlashCommand("lock", command: .lock)
        }
    }
}

extension CanvasEditor {
    /// Whether something around the shape holds it read-only, its own lock included, so neither Lock
    /// nor Unlock is for it: the container it's in, if that can't change (a locked frame, at any
    /// depth), or, in none, its board, if that can't (a locked subboard's, at any depth:
    /// `isBoardReadOnly`). O(its depth).
    func isLockedByContainer(_ id: ShapeID) -> Bool {
        let document = document
        guard let record = document[id] else { return false }
        guard let container = registry.container(of: record, in: document) else { return isBoardReadOnly }
        return isReadOnly(container)
    }
}

extension CommandSubject {
    /// The shapes' locks, read in one pass: what Lock's and Unlock's rules and runs go by.
    fileprivate var locks: Locks {
        let lockable = shapes.filter { !editor.isLockedByContainer($0) }
        return Locks(lockable: lockable, allLocked: lockable.allSatisfy { editor.isLocked($0) }, shapes: shapes)
    }
}

/// The shapes a lock command is given, by their own locks.
private struct Locks {
    /// The shapes whose own lock can change: all but those in a locked frame or on a locked subboard's
    /// board.
    let lockable: [ShapeID]
    /// Whether every one of them is locked (so with none, too: Lock is for some that aren't).
    let allLocked: Bool
    let shapes: [ShapeID]

    /// Unlock is for shapes whose locks can change, every one of them locked.
    var canUnlock: Bool { !lockable.isEmpty && allLocked }

    /// What a run tries: the lockable shapes; with none (a try, as a chip's click, of shapes whose locks
    /// can't change), all of them, which the core refuses, so they shake.
    var tried: [ShapeID] { lockable.isEmpty ? shapes : lockable }
}

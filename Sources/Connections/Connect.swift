import AppKit
import CoreGraphics
import Canvas
import ContextMenus
import Draw
import Keyboard
import Mentions

extension CanvasCommand {
    /// Connect (⌘L): the first of two selected shapes connected to the second, or one connected to itself, as a
    /// port's drag would.
    public static let connect: CanvasCommand = "connect"
}

/// Insert's section of Connect: ⌘L in the menu bar, which is how the key reaches a note being edited (text has the keyboard there,
/// and the canvas's shortcuts wait; the menu bar's keys do not).
public enum ConnectSection {}

extension ConnectSection: MenuBarSection {
    public static var menu: MenuBarMenu { "Insert" }
}

/// Connect's key, ⌘L: the command's, and what a field that answers it before the menu bar (a row's line, which opens the picker on
/// its row) reads, so one key has one meaning.
public enum ConnectKey {
    public static let chord = KeyChord("l", .command)

    /// Whether a key event is the key: its letter, with ⌘ and nothing else held but caps lock.
    @MainActor public static func isPressed(by event: NSEvent) -> Bool {
        event.type == .keyDown && event.charactersIgnoringModifiers?.lowercased() == String(chord.key)
            && event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
    }
}

extension PluginRegistrar {
    /// ⌘L, Connect: for two shapes, a connection from the one selected first to the other; for one, the picker of the shapes it
    /// can be connected to, Itself last (`ConnectPickerPlugin`), and, in a list without it, the loop (the drag from its dot back
    /// onto it, by keys), while something makes connections. Between presses: in a note's words it ends editing, its words
    /// kept, and opens the picker; a list without the picker keeps the key out of a shape being edited and mid-press.
    mutating func connectCommand() {
        command(.connect, title: ConnectionsStyle.connect, in: ConnectSection.self, shortcut: ConnectKey.chord, runs: .betweenPresses,
                isEnabled: { subject in
                    let editor = subject.editor
                    guard (1...2).contains(subject.shapes.count), editor.registry.drawsConnections else { return false }
                    if editor.editingShapeID == nil { return true }
                    // A shape being edited: its edit ends only for a picker that can open on it.
                    return subject.shapes.count == 1 && editor.connectPicker?.canOpen(on: subject.shapes[0]) == true
                }) { subject in
            let editor = subject.editor
            if subject.shapes.count == 1, let picker = editor.connectPicker {
                // ⌘L in the picker's own field, opened on a shape or one of its rows: it stays as it is.
                if picker.isOpen(on: subject.shapes[0]) { return }
                // A row being edited has the picker on the row, as its key does.
                if editor.editingShapeID == subject.shapes[0], picker.connectsEditedRow?(subject.shapes[0]) == true { return }
                editor.endEditing()
                picker.open(on: subject.shapes[0])
            } else {
                editor.connect(subject.shapes)
            }
        }
    }
}

/// What a connection made without a drag (Connect) is told once it is committed, inside the Connect step: the
/// same word a port's drag gives its connection when released, from whoever owns what the connection then is (a
/// relationship type, Types'), so Connections names no kind and the key and the pointer give the same document. A
/// plugin value of its own after the connector; the hook gets the connection and the editor.
public enum ConnectionMade {}

extension ConnectionMade: ExtensionPoint {
    public typealias Contribution = @MainActor (ShapeID, CanvasEditor) -> Void
    public static var owner: PluginID { .ports }
    public static func summary(of _: Contribution, for _: ShapeTarget) -> String { "connection made" }
}

extension PluginRegistrar {
    /// Hears of every connection Connect makes, after its commit and inside its step.
    public mutating func connectionMade(_ hook: @escaping @MainActor (ShapeID, CanvasEditor) -> Void) {
        contribute(hook, to: ConnectionMade.self)
    }
}

extension PluginID {
    public static let connectMenu: PluginID = "connect-menu"
}

/// Connect in a right-click on two shapes, and so in the menu bar's Shape menu: the item that runs
/// Ports' ⌘L. On one shape, with the picker (`ConnectPickerPlugin`) installed, "Connect To…", the picker's item, which is
/// also how ⌘L reaches a note being edited (the menu bar has its key there); without it the loop stays the key's alone.
/// A plugin value of its own after `ContextMenusPlugin` and `PortsPlugin`, so a list with ports and no
/// context menus has the key and no item.
public struct ConnectMenuPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .connectMenu }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.contextMenuForCanvas {
            MenuItem(command: .connect, when: { $0.shapes.count == 2 })
            MenuItem(command: .connect, title: ConnectionsStyle.connectTo, when: { $0.shapes.count == 1 && $0.editor.connectPicker?.canOpen(on: $0.shapes[0]) == true })
        }
    }
}

extension CanvasEditor {
    /// Connects the first of two shapes to the second (from a key, the one selected first to the other), or one
    /// shape to itself: what `.connect` does to its shapes, the connection the connector makes by name, as `canvas draw` makes `edge "A" -> "B"` (on the first
    /// channel the start has a dot on that the end takes; a second between a pair bent apart from the
    /// first; a shape and itself, `edge "A" -> "A"`, a loop on its right side, as a port's drag let go back on it
    /// draws one on the side of its dot), one step, "Connect". A stand-in (a reference pill) is an end as what it stands for, as a
    /// drag from a port reads it (`PortState.ports(of:)`): one that stands for nothing now is no end.
    /// The selection stays. Where the connector refuses the pair (no channel joins them, as a note and
    /// a frame; one holds the other, as a frame and a note in it: `mayConnect`), or the board takes
    /// nothing, nothing changes and both shake. Nothing for any other number of shapes.
    public func connect(_ ids: [ShapeID]) {
        guard let first = ids.first, ids.count <= 2 else { return }
        connect(ConnectEnd(first), to: ConnectEnd(ids.last ?? first))
    }

    /// Connects `source`, a shape of the board shown or a part of one (a row), to `target`, a shape or a part: the one writer under ⌘L (two shapes, one, and the picker's
    /// picks), as `canvas draw` makes `edge "A" -> "B"` (`registry.drawConnection`), in one step named for the plan (`plan.step`,
    /// "Connect" for none) that holds the arrow, what the plan wrote first (`plan.prepare`) and what the `ConnectionMade` hooks do
    /// to the arrow. A stand-in end (a reference pill) is an end as what it stands for. A `target` on another board is reached
    /// through a pill on the board shown that stands for it, as a script's edge is (`StandInRoute.placePill`): the board's pill
    /// for it if there is one, else a new one landed beside `source`, in the same step. A target that must be made what the pill
    /// may stand for first (made public) is connected only with `fulfil`, which a person's pick passes and a script never does.
    ///
    /// Returns the arrow. Nil, with nothing changed and no step, when nothing makes connections, `source` is not on the board
    /// shown, the target cannot be reached, the connector refuses the pair or the board takes nothing, or `plan.prepare`
    /// throws: the shapes shake.
    @discardableResult
    public func connect(_ source: ConnectEnd, to target: ConnectEnd, plan: ConnectPlan? = nil, fulfil: Bool = false) -> ShapeID? {
        let ids: Set<ShapeID> = [source.shape, target.shape]
        let ports = service(PortState.self)
        func standing(_ id: ShapeID) -> [ShapeKind]? { document[id].flatMap { record in ports.map { $0.standingKinds(of: record) } ?? [] } }
        guard let from = standing(source.shape) else {
            refuseChanges(to: ids)
            return nil
        }
        // The far end: a pill on this board that stands for it.
        var to: [ShapeKind] = []
        var pill: PlacedPill?
        if document[target.shape] != nil {
            guard let found = standing(target.shape) else {
                refuseChanges(to: ids)
                return nil
            }
            to = found
        } else {
            let verdicts = FarVerdicts(self)
            switch verdicts.verdict(of: target.shape) {
            case .cannot, .here:
                refuseChanges(to: ids)
                return nil
            case .fulfils where !fulfil:
                refuseChanges(to: ids)
                return nil
            case .reads, .fulfils:
                // A row of a shape on another board is no end until pills stand for rows (K10): the pill would be the whole shape.
                guard target.part == nil else {
                    refuseChanges(to: ids)
                    return nil
                }
                guard let route = verdicts.route, let far = shape(inFile: target.shape),
                      let placed = route.placePill(standingFor: target.shape, label: registry.mentionAppearance(of: far)?.label ?? "",
                                                   beside: source.shape, edgeIs: .from, sharing: .any, verdicts: verdicts, in: self) else {
                    refuseChanges(to: ids)
                    return nil
                }
                pill = placed
                to = placed.standingFor(whenNearIs: .from).to
            }
        }
        let step = plan?.step ?? ConnectionsStyle.connect
        // Whole or not at all (`transactWhole`): a pair the connector refuses, or a board that takes nothing, commits
        // nothing and shakes the shapes.
        // The step is a group around the commit and the hooks (`ConnectionMade`), as a drag's press is: what a hook
        // changes (a relationship type given to the arrow) is the step's, and a menu it pops needs the arrow committed.
        return undoHistory.group(step) {
            let made: ShapeID? = transactWhole(step, shaking: ids) { transaction in
                var ends = (from: source, to: target)
                var standingFor = (from: from, to: to)
                if let prepare = plan?.prepare {
                    ends = try prepare(&transaction)
                    // The ends it returns are the arrow's: what each stands for is read again for an end it changed, and the far
                    // end, reached through a pill, is not one a plan may change.
                    if pill != nil, ends.to != target { throw Transaction.Refused() }
                    if ends.from != source {
                        guard let record = transaction.document[ends.from.shape], let kinds = ports?.standingKinds(of: record) else { throw Transaction.Refused() }
                        standingFor.from = kinds
                    }
                    if ends.to != target {
                        guard let record = transaction.document[ends.to.shape], let kinds = ports?.standingKinds(of: record) else { throw Transaction.Refused() }
                        standingFor.to = kinds
                    }
                }
                if let pill {
                    try pill.claim(in: &transaction, registry: registry)
                    ends.to = ConnectEnd(try pill.put(in: &transaction))
                }
                guard let made = registry.drawConnection(from: ends.from.shape, to: ends.to.shape, in: transaction.shapes, standingFor: standingFor,
                                                         parts: (ends.from.part, ends.to.part))
                else { throw Transaction.Refused() }
                transaction.insert(made)
                guard transaction.document[made.id] != nil else { throw Transaction.Refused() }
                return made.id
            }
            guard let made else { return nil }
            for hook in registry.contributions(to: ConnectionMade.self) { hook.value(made, self) }
            return made
        }
    }
}

@MainActor
enum ConnectionsStyle {
    static let connect = "Connect"
    /// The picker's item in the Shape menu, on one shape.
    static let connectTo = "Connect To…"
    /// A shape's arrows as its parts: "Arrow to Payment".
    static let arrowTo = "Arrow to "
    static let arrowFrom = "Arrow from "
    /// How far a part's ring stands off the arrow's segment, in view points.
    static let partPad: CGFloat = 6
    /// How much of an arrow, from where it leaves a shape, its part takes in, in view points.
    static let partLength: CGFloat = 48
}

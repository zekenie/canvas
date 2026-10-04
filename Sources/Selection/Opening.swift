import Canvas
import CoreGraphics

/// What opening a shape does, for a kind whose shapes open as something other than editing in place
/// (a board-owning kind shows its board). A double-click, Return, Enter, ⌘↓ and the `.openSelection`
/// command open the only selected shape: by its kind's opener, else by editing it if its kind is
/// `Editable`. At most one opener per kind, plus one for every kind (`.any`), which a kind's own
/// overrides.
public enum ShapeOpening: KeyedExtensionPoint {
    public typealias Contribution = ShapeOpener
    public static var owner: PluginID { .selection }
    public static func uniqueKeys(of _: ShapeOpener, for target: ShapeTarget) -> [AnyHashable] { [target] }
}

/// A kind's way of opening its shapes (`ShapeOpening`): what it's called, in a few words ("Open"),
/// for where it's offered, and what it does to a shape of the kind on the board shown.
public struct ShapeOpener {
    public let title: String
    public let open: @MainActor (ShapeID, CanvasEditor) -> Void

    public init(title: String, open: @escaping @MainActor (ShapeID, CanvasEditor) -> Void) {
        self.title = title
        self.open = open
    }
}

// Sugar, so opting in is one line and never names the extension point.
extension ShapeRegistrar {
    /// Opening one of this kind's shapes (a double-click, Return, ⌘↓) does `open` rather than edit
    /// it: `sub.opens("Open") { shape, editor in editor.showBoard(BoardID(owner: shape.id)) }`.
    public mutating func opens(_ title: String, _ open: @escaping @MainActor (ShapeRecord<Definition.Props>, CanvasEditor) -> Void) {
        contribute(ShapeOpener(Definition.Props.self, title: title, open), to: ShapeOpening.self)
    }
}

extension PluginRegistrar {
    /// How a kind another plugin registers opens, as `opens` on a kind's own registrar.
    public mutating func opens<P: ShapeProps>(_: P.Type, _ title: String, _ open: @escaping @MainActor (ShapeRecord<P>, CanvasEditor) -> Void) {
        contribute(ShapeOpener(P.self, title: title, open), to: ShapeOpening.self, for: .kind(P.kind))
    }
}

extension ShapeOpener {
    /// Opens a shape of one kind, found on the board shown.
    init<P: ShapeProps>(_: P.Type, title: String, _ open: @escaping @MainActor (ShapeRecord<P>, CanvasEditor) -> Void) {
        self.init(title: title) { id, editor in
            if let shape = editor.document[id]?.typed(as: P.self) { open(shape, editor) }
        }
    }
}

extension CanvasEditor {
    /// Whether `open` would do something with a shape: it's on the board shown, not kept aside, and
    /// its kind has an opener (`ShapeOpening`) or is `Editable`. A read-only shape of an `Editable`
    /// kind (a locked note) counts: opening it is refused, and the refusal shows (Locking shakes it),
    /// as deleting it is.
    public func canOpen(_ id: ShapeID) -> Bool {
        guard let record = document[id], !record.isOpaque else { return false }
        return selectionState?.openers[record.kind] != nil || registry.definition(for: record.kind) is any Editable
    }

    /// Opens a shape on the board shown: its kind's opener, if it has one (true once it's run), else
    /// edits it (`beginEditing`: false for a kind that isn't `Editable`, or a read-only shape),
    /// from `point` (world units) if a press opened it, and with its `clickCount` (a double-click's
    /// 2), so the editing view puts its selection there; Return gives none.
    @discardableResult
    public func open(_ id: ShapeID, at point: CGPoint? = nil, clickCount: Int = 1) -> Bool {
        guard let record = document[id], !record.isOpaque else { return false }
        guard let opener = selectionState?.openers[record.kind] else { return beginEditing(id, at: point, clickCount: clickCount) }
        opener.open(id, self)
        return true
    }

    /// Return, Enter, ⌘↓ and `.openSelection`: opens the only selected shape (`open`).
    public func openSelection() {
        if let selection { open(selection) }
    }

    /// Shows `board`, as `showBoard` does, and selects `ids` there, as one step back: going back
    /// returns to the board left, with what was selected there, not to the board shown with nothing
    /// selected. On the board shown already, it only selects them (a step, as any selection change).
    /// Returns whether the board is shown.
    @discardableResult
    public func showBoard(_ board: BoardID, selecting ids: [ShapeID]) -> Bool {
        guard board != self.board else {
            selectedShapeIDs = ids
            return true
        }
        guard showBoard(board) else { return false }
        selectionState?.select(ids, recording: false)
        return true
    }
}

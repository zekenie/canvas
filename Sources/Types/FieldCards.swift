import Canvas
import CoreGraphics

// The card a row with more in it opens under itself. K0 holds only the request and the service's shape: a
// card does not open. The core piece the real one stands on is generic and knows no field.

public struct FieldCardRequest {
    public enum Target: Hashable, Sendable {
        /// A row's field.
        case field(FieldPath)
        /// The fold's rows (`folded` says which).
        case fold
    }

    public var shape: ShapeID
    public var target: Target
    public var mode: FieldFormMode
    /// A type's note, a locked note, a read-only board: the card opens to be read.
    public var isReadOnly: Bool
    /// The row, world units, in the laid-out paper.
    public var rowRect: CGRect
    /// The rows a fold hides, in row order: read only for `.fold`. A note can have two folds, `from Person`
    /// and `+N more`, and the target does not say which.
    public var folded: [Resolved.Field]
    /// Where the row is now (world units), asked while the card is open; nil closes it. A nil closure: the
    /// card keeps its offset from the paper's top-left.
    public var rowRectNow: (@MainActor () -> CGRect?)?
    /// Esc from the top level, a click outside: the caller focuses the row again.
    public var closed: @MainActor () -> Void
    /// Tab off the last row: the caller focuses the next row, or ends editing.
    public var tabbedOut: @MainActor (_ forward: Bool) -> Void

    public init(shape: ShapeID, target: Target, mode: FieldFormMode, isReadOnly: Bool, rowRect: CGRect,
                folded: [Resolved.Field] = [], rowRectNow: (@MainActor () -> CGRect?)? = nil,
                closed: @escaping @MainActor () -> Void, tabbedOut: @escaping @MainActor (_ forward: Bool) -> Void) {
        self.shape = shape
        self.target = target
        self.mode = mode
        self.isReadOnly = isReadOnly
        self.rowRect = rowRect
        self.folded = folded
        self.rowRectNow = rowRectNow
        self.closed = closed
        self.tabbedOut = tabbedOut
    }
}

@MainActor
public final class FieldCards {
    private weak var editor: CanvasEditor?

    public init(editor: CanvasEditor) {
        self.editor = editor
    }

    /// Opens the card under the row; false when there is none to open.
    @discardableResult
    public func open(_ request: FieldCardRequest) -> Bool { false }

    /// The row whose card is open: the caller outlines it. Redraws when it changes.
    public var openTarget: (shape: ShapeID, target: FieldCardRequest.Target)? { nil }

    /// The key of the first folded field of the fold whose card is open: tells a note's two folds apart.
    public var openFolded: String? { nil }

    public func close() {}
}

extension FieldCards: EditorService {
    /// It keeps nothing per shape or per board, so a switch needs no change set (the default works one out).
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {}
}

extension CanvasEditor {
    /// The cards rows open (`FieldCards`); nil without TypesPlugin.
    public var fieldCards: FieldCards? { service(FieldCards.self) }
}

import CoreGraphics

/// A board of the file as it is now, shown or not (`editor.reading(of:)`): its shapes, lookups over
/// them, their paint order, and where a window would look at it. What works on a board without
/// showing it reads this in place of the editor's `document`, `shapeContext` and `paintOrder()`
/// (`canvas draw --on`), and changes it with `transact(on:)`. Read it, use it, and let it go: it's
/// the board as it was when read, and a commit leaves it behind.
@MainActor
public struct BoardReading {
    public let board: BoardID
    /// Its shapes, in document order.
    public let document: CanvasDocument
    /// Lookups over its shapes (geometry, hit tests), with the camera it's seen with.
    public let shapes: ShapeContext
    /// The part of the board a window shows (less what the host covers of its top, as every fit
    /// leaves clear), world units: on the board shown, where its camera is headed; on another, where
    /// it would be on showing it (as it was left, else remembered, else a first visit's fit). Nil
    /// while the editor has no view (headless).
    public let view: CGRect?
    /// The corners of `view` the host's own views cover (the minimap, `CanvasEditor.coveredCorners`), world units: a shape
    /// put down for a person, or kept in view, keeps out of them. None headless, or with nothing covered.
    public let covered: [CGRect]
    /// Whether the board can't change (`editor.isReadOnly(board:)`: a locked subboard's, at any
    /// depth): nothing on it changes, and nothing goes on it.
    public let isBoardReadOnly: Bool
    private let index: ShapeIndex

    init(board: BoardID, document: CanvasDocument, shapes: ShapeContext, index: ShapeIndex, view: CGRect?, covered: [CGRect] = [], isBoardReadOnly: Bool) {
        self.board = board
        self.document = document
        self.shapes = shapes
        self.index = index
        self.view = view
        self.covered = covered
        self.isBoardReadOnly = isBoardReadOnly
    }

    /// Whether a shape on the board can't change, as a transaction on it holds it: a plugin's rule says
    /// so of it, or of a container it's in, at any depth, or the board can't (`isBoardReadOnly`).
    /// O(its depth).
    public func isReadOnly(_ record: AnyShapeRecord) -> Bool {
        isBoardReadOnly || shapes.registry.isReadOnly(record, in: document)
    }

    /// Back to front, as `editor.paintOrder()` is for the board shown.
    public func paintOrder() -> [AnyShapeRecord] {
        let list = index.paintList(in: shapes), all = document.shapes
        return list.order.map { all[$0] }
    }
}

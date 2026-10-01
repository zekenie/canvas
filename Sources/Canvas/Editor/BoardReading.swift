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
    private let index: ShapeIndex

    init(board: BoardID, document: CanvasDocument, shapes: ShapeContext, index: ShapeIndex, view: CGRect?) {
        self.board = board
        self.document = document
        self.shapes = shapes
        self.index = index
        self.view = view
    }

    /// Back to front, as `editor.paintOrder()` is for the board shown.
    public func paintOrder() -> [AnyShapeRecord] {
        let list = index.paintList(in: shapes), all = document.shapes
        return list.order.map { all[$0] }
    }
}

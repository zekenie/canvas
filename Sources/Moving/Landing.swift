import Canvas
import CoreGraphics
import Placing

// Where moved shapes land is Placing's (the solver `canvas draw` places shapes with); this is the glue
// that hands it a `Block`.

extension Surroundings {
    /// `board` as it is now, for `block` to land on, as one box: the box around them all. Nil for a board
    /// the editor can't show.
    init?(on board: BoardID, moving block: Block, in editor: CanvasEditor) {
        guard !block.box.isNull else { return nil }
        self.init(on: board, moving: block.box.size, carrying: block.shapes.map(\.id), held: Array(block.carried), in: editor)
    }
}

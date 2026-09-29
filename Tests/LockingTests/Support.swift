import Adornments
import Canvas
import CanvasTesting
import ContextMenus
import Keyboard
import Locking
import Selection
import TableOfContents

// Fixtures only (CanvasTesting's boxes and editable cards), so every test here shows the horizontal
// knows no real kind.

/// What the app has around Locking: the keys, the selection, the context menu, the table of
/// contents and adornments; on `file`.
@MainActor func lockingHarness(_ more: [any CanvasPlugin] = [], file: CanvasFile = CanvasFile()) throws -> EditorHarness {
    try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), TableOfContentsPlugin(), FixturesPlugin(), CardsPlugin(), AdornmentsPlugin(), LockingPlugin()] + more,
                      file: file)
}

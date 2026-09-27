import Adornments
import Canvas
import CanvasTesting
import ContextMenus
import Keyboard
import Locking
import Selection

// Fixtures only (CanvasTesting's boxes and editable cards), so every test here shows the horizontal
// knows no real kind.

/// What the app has around Locking: the keys, the selection, the context menu and adornments.
@MainActor func lockingHarness(_ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), FixturesPlugin(), CardsPlugin(), AdornmentsPlugin(), LockingPlugin()] + more)
}

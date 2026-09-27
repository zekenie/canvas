import Canvas
import CoreGraphics

/// Buttons a plugin draws on the canvas, in an overlay (Locking's lock chip), which the select tool
/// clicks before anything else under the pointer: handles, shapes, the box around several. A press on
/// one and a release on it clicks it, as an NSButton's does; a press dragged off it does nothing. The
/// pointing hand shows over one, and `editor.hoveredButton` and `editor.pressedButton` say which to
/// draw hovered and pressed. In other tools they're only drawn. A list: each plugin's buttons, found
/// with the last plugin's first, since overlays draw in plugin order.
public enum CanvasButtons {}

extension CanvasButtons: ExtensionPoint {
    public typealias Contribution = CanvasButtonSource
    public static var owner: PluginID { .selection }
}

/// One plugin's buttons: where they are, and what a click on one does. Only the sugar makes one.
@MainActor
public struct CanvasButtonSource {
    let button: @MainActor (CanvasEditor, CGPoint) -> AnyHashable?
    let click: @MainActor (AnyHashable, CanvasEditor) -> Void
}

extension PluginRegistrar {
    /// Buttons this plugin draws on the canvas (see `CanvasButtons`). `at` finds the one under a view
    /// point, the front-most if several, as any value the plugin knows it by; `click` does what it's
    /// for. The select tool asks `at` as the pointer moves over the canvas, so keep it cheap.
    public mutating func canvasButtons<Button: Hashable & Sendable>(at find: @escaping @MainActor (CanvasEditor, CGPoint) -> Button?,
                                                                    click: @escaping @MainActor (Button, CanvasEditor) -> Void) {
        contribute(CanvasButtonSource(button: { editor, point in find(editor, point).map(AnyHashable.init) },
                                      click: { button, editor in (button.base as? Button).map { click($0, editor) } }),
                   to: CanvasButtons.self)
    }
}

extension CanvasEditor {
    /// The canvas button under a view point (`CanvasButtons`), as its plugin knows it: what the select
    /// tool clicks there. Nil where there's none, and without the Selection plugin.
    public func button(atViewPoint point: CGPoint) -> AnyHashable? { buttonHit(atViewPoint: point)?.button }

    func buttonHit(atViewPoint point: CGPoint) -> (source: CanvasButtonSource, button: AnyHashable)? {
        guard let sources = selectionState?.buttonSources else { return nil }
        for source in sources.reversed() {
            if let button = source.button(self, point) { return (source, button) }
        }
        return nil
    }

    /// The canvas button the pointer is over in the select tool: draw it hovered.
    public internal(set) var hoveredButton: AnyHashable? {
        get { selectionState?.hoveredButton }
        set { selectionState?.hoveredButton = newValue }
    }

    /// The canvas button pressed, while the pointer is still on it: draw it pressed.
    public internal(set) var pressedButton: AnyHashable? {
        get { selectionState?.pressedButton }
        set { selectionState?.pressedButton = newValue }
    }

    /// A plugin's buttons came, went or moved other than through a change to the document (a chip that
    /// fades away): the select tool looks again under the pointer, for the hover and the cursor.
    /// Commits do this by themselves.
    public func canvasButtonsDidChange() { selectionState?.findHoveredButton() }
}

/// A canvas button was pressed. Released on it, it's clicked; dragged off, it shows as not pressed,
/// and back on, as pressed again, as an NSButton does.
@MainActor
final class PressingButtonSession {
    let source: CanvasButtonSource
    let button: AnyHashable
    init(source: CanvasButtonSource, button: AnyHashable) {
        self.source = source
        self.button = button
    }
}

extension PressingButtonSession: Session {
    func cursor(in editor: CanvasEditor) -> CanvasCursor? { .pointingHand }

    func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        editor.pressedButton = editor.button(atViewPoint: pointer.view) == button ? button : nil
    }

    func end(_ pointer: Pointer, in editor: CanvasEditor) {
        editor.pressedButton = nil
        if editor.button(atViewPoint: pointer.view) == button { source.click(button, editor) }
    }

    /// Escape lets go of the press without clicking.
    func cancel(in editor: CanvasEditor) -> Bool {
        editor.pressedButton = nil
        return true
    }
}

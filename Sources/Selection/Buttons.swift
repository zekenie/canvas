import Canvas
import CoreGraphics
import Geometry

/// Buttons a plugin draws on the canvas, in an overlay (Adornments' clickable ones, the lock chip; a
/// port's dot), which the select tool presses before anything else under the pointer: handles,
/// shapes, the box around several. Most are clicked: a press on one and a release on it clicks it, as an NSButton's does; a
/// press dragged off it does nothing, and the pointing hand shows over one. Some are dragged instead
/// (a port's dot): past the drag threshold, a press on one starts what its plugin says a drag from it
/// does, and released without a drag it does nothing; the open hand shows over one. Either way,
/// `editor.hoveredButton` and `editor.pressedButton` say which to draw hovered and pressed. In other
/// tools they're only drawn. A list: each plugin's buttons, found with the last plugin's first, since
/// overlays draw in plugin order.
public enum CanvasButtons {}

extension CanvasButtons: ExtensionPoint {
    public typealias Contribution = CanvasButtonSource
    public static var owner: PluginID { .selection }
}

/// One plugin's buttons: where they are, and what a click on one does, or a drag from one. Only the
/// sugar makes one.
@MainActor
public struct CanvasButtonSource {
    let button: @MainActor (CanvasEditor, CGPoint) -> AnyHashable?
    let action: Action

    enum Action {
        case click(@MainActor (AnyHashable, CanvasEditor) -> Void)
        /// Given the button, where it was pressed (world units), and the editor.
        case drag(@MainActor (AnyHashable, CGPoint, CanvasEditor) -> (any Session)?)
    }

    /// Over one of these buttons: the pointing hand for a click, the open hand for a drag.
    var cursor: CanvasCursor {
        if case .drag = action { .openHand } else { .pointingHand }
    }
}

extension PluginRegistrar {
    /// Buttons this plugin draws on the canvas (see `CanvasButtons`). `at` finds the one under a view
    /// point, the front-most if several, as any value the plugin knows it by; `click` does what it's
    /// for. The select tool asks `at` as the pointer moves over the canvas, so keep it cheap.
    public mutating func canvasButtons<Button: Hashable & Sendable>(at find: @escaping @MainActor (CanvasEditor, CGPoint) -> Button?,
                                                                    click: @escaping @MainActor (Button, CanvasEditor) -> Void) {
        contribute(CanvasButtonSource(button: { editor, point in find(editor, point).map(AnyHashable.init) },
                                      action: .click { button, editor in (button.base as? Button).map { click($0, editor) } }),
                   to: CanvasButtons.self)
    }

    /// Buttons this plugin draws on the canvas that are dragged rather than clicked (a port's dot).
    /// `at` finds the one under a view point, as `canvasButtons(at:click:)`'s does; past the drag
    /// threshold, `drag` gets the one pressed and where it was pressed (world units), and returns the
    /// session that takes over the drag, or nil to do nothing. A press released without a drag does
    /// nothing.
    public mutating func canvasButtons<Button: Hashable & Sendable>(at find: @escaping @MainActor (CanvasEditor, CGPoint) -> Button?,
                                                                    drag: @escaping @MainActor (Button, CGPoint, CanvasEditor) -> (any Session)?) {
        contribute(CanvasButtonSource(button: { editor, point in find(editor, point).map(AnyHashable.init) },
                                      action: .drag { button, origin, editor in (button.base as? Button).flatMap { drag($0, origin, editor) } }),
                   to: CanvasButtons.self)
    }
}

extension CanvasEditor {
    /// The canvas button under a view point (`CanvasButtons`), as its plugin knows it: what the select
    /// tool presses there. Nil where there's none, and without the Selection plugin.
    public func button(atViewPoint point: CGPoint) -> AnyHashable? { buttonHit(atViewPoint: point)?.button }

    func buttonHit(atViewPoint point: CGPoint) -> ButtonHit? {
        guard let sources = selectionState?.buttonSources else { return nil }
        for source in sources.reversed() {
            if let button = source.button(self, point) { return ButtonHit(source: source, button: button) }
        }
        return nil
    }

    /// The canvas button the pointer is over in the select tool: draw it hovered.
    public var hoveredButton: AnyHashable? { selectionState?.hoveredButton?.button }

    /// The canvas button pressed, while the pointer is still on it (and, for a button that's dragged,
    /// until the drag starts): draw it pressed.
    public internal(set) var pressedButton: AnyHashable? {
        get { selectionState?.pressedButton }
        set { selectionState?.pressedButton = newValue }
    }

    /// Where the pointer is over the canvas in the select tool, in view points, as it last moved with
    /// nothing under way; nil once it's left the canvas (or gone over the minimap), another tool is
    /// current, or Escape let go of a dragged button's press, until it moves again. What a plugin whose buttons show only while the pointer is near them goes by (a
    /// port's dots). Without the Selection plugin, nil.
    public var pointerOverCanvas: CGPoint? { selectionState?.lastPointer }

    /// A plugin's buttons came, went or moved other than through a change to the document (a chip that
    /// fades away): the select tool looks again under the pointer, for the hover and the cursor, once every
    /// service has settled the change being delivered, if one is (`onceSettled`: what a button is asks the
    /// plugins' services, and where it is what they laid out). Commits do this by themselves.
    public func canvasButtonsDidChange() {
        selectionState?.lookForButtonOnceSettled()
    }
}

/// A button under the pointer, and the plugin's buttons it's one of.
@MainActor
struct ButtonHit {
    let source: CanvasButtonSource
    let button: AnyHashable
}

/// A canvas button was pressed. One that's clicked, released on it, is clicked; dragged off, it shows
/// as not pressed, and back on, as pressed again, as an NSButton does. One that's dragged, past the
/// drag threshold, hands the drag to what its plugin starts.
@MainActor
final class PressingButtonSession {
    let source: CanvasButtonSource
    let button: AnyHashable
    /// Where it was pressed, in view points.
    let press: CGPoint
    init(source: CanvasButtonSource, button: AnyHashable, press: CGPoint) {
        self.source = source
        self.button = button
        self.press = press
    }
}

extension PressingButtonSession: Session {
    func cursor(in editor: CanvasEditor) -> CanvasCursor? {
        if case .drag = source.action { .closedHand } else { .pointingHand }
    }

    func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        switch source.action {
        case .click:
            editor.pressedButton = editor.button(atViewPoint: pointer.view) == button ? button : nil
        case .drag(let start):
            guard pointer.view.distance(to: press) > Style.dragThreshold else { return }
            editor.pressedButton = nil
            editor.selectionState?.hoveredButton = nil
            guard let next = start(button, editor.camera.toWorld(press), editor) else {
                editor.session = nil
                return
            }
            editor.session = next
            next.drag(pointer, in: editor)
        }
    }

    func end(_ pointer: Pointer, in editor: CanvasEditor) {
        editor.pressedButton = nil
        if case .click(let click) = source.action, editor.button(atViewPoint: pointer.view) == button { click(button, editor) }
    }

    /// Escape lets go of the press without clicking, or before any drag. A dragged button's plugin
    /// shows it only near the pointer (a port's dots), and the select tool won't see the pointer
    /// again till the button comes up, so until then it's as if the pointer had left the canvas.
    func cancel(in editor: CanvasEditor) -> Bool {
        editor.pressedButton = nil
        if case .drag = source.action { editor.selectionState?.lastPointer = nil }
        return true
    }
}

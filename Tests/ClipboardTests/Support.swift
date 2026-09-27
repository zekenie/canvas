import AppKit
import Canvas
import CanvasTesting
import Clipboard
import ContextMenus
import CoreGraphics
import Keyboard
import Selection
import TestKit

// Fixtures only: the CanvasTesting kinds, plus two local ones, so every test here shows the
// horizontal knows no real kind.

/// A link between two shapes, by id, like a connector: its props name them.
struct Link: ShapeProps {
    static let kind: ShapeKind = "link"
    var from: ShapeID?
    var to: ShapeID?
}

struct LinkDefinition {}

extension LinkDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Link>, in context: RenderContext) {}
    func geometry(of shape: ShapeRecord<Link>, in context: ShapeContext) -> ShapeGeometry {
        ShapeGeometry(outline: [], bounds: .zero, isClosed: false)
    }
}

extension LinkDefinition: ShapeReferencing {
    /// A shape left out is let go of: that end links nothing.
    func remappingReferences(of shape: ShapeRecord<Link>, _ map: (ShapeID) -> ShapeID?, in context: ShapeContext) -> Link {
        Link(from: shape.props.from.flatMap(map), to: shape.props.to.flatMap(map))
    }
}

/// A stamp: a box that's copyable only while it isn't sealed.
struct Stamp: BoxShapeProps {
    static let kind: ShapeKind = "stamp"
    var frame: CGRect
    var isSealed = false
}

struct StampDefinition {}

extension StampDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Stamp>, in context: RenderContext) {}
}

/// A ticket: a box that opts out of copying altogether.
struct Ticket: BoxShapeProps {
    static let kind: ShapeKind = "ticket"
    var frame: CGRect
}

struct TicketDefinition {}

extension TicketDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Ticket>, in context: RenderContext) {}
}

/// Links; stamps, copyable unless sealed; and tickets, never copyable.
struct KindsPlugin: CanvasPlugin {
    var id: PluginID { "clipboard-kinds" }

    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(LinkDefinition())
        registrar.shape(StampDefinition()) { stamp in stamp.copyable(when: { !$0.props.isSealed }) }
        registrar.shape(TicketDefinition()) { ticket in ticket.uncopyable() }
    }
}

/// A pasteboard of the test's own, so the user's clipboard is never touched.
@MainActor func privatePasteboard() -> NSPasteboard {
    let pasteboard = NSPasteboard.withUniqueName()
    pasteboard.clearContents()
    return pasteboard
}

/// Keyboard, Selection, ContextMenus and Clipboard (on `pasteboard`), the CanvasTesting kinds and
/// the local ones, then `more`.
@MainActor func harness(_ pasteboard: NSPasteboard, _ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), ClipboardPlugin(pasteboard: pasteboard),
                                FixturesPlugin(), KindsPlugin()] + more)
}

extension EditorHarness {
    /// ⌘ and a key, on the canvas: whether a shortcut took it.
    @discardableResult
    func command(_ key: String) -> Bool {
        hold(.command)
        defer { hold([]) }
        return self.key(key)
    }
}

extension CanvasEditor {
    /// The shapes added since `before`, back to front.
    func shapes(since before: CanvasDocument) -> [AnyShapeRecord] {
        document.shapes.filter { before[$0.id] == nil }
    }
}

/// Four slots in a row, 100 points square, 100 apart.
func slot(_ index: Int) -> CGRect { CGRect(x: 200 * index, y: 0, width: 100, height: 100) }
func middle(_ index: Int) -> CGPoint { CGPoint(x: 200 * index + 50, y: 50) }

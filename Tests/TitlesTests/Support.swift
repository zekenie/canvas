import AppKit
import Canvas
import CanvasTesting
import CanvasUI
import DetailPanel
import Keyboard
import Selection
import SwiftUI
import TableOfContents
import TestKit
import Titles

// Fixtures only: the CanvasTesting kinds plus a local plaque, so every test here shows the
// horizontal knows no real kind.

/// A box with a name, the title Titles keeps for it (nil until it's named): the Plaque tool, a row
/// of its own (its caption, or "Blank"), and its header renames it.
struct Plaque: BoxShapeProps {
    static let kind: ShapeKind = "plaque"
    static let properties = Properties<Plaque> {
        Property("frame", \.frame).required()
        Property("caption", \.caption)
    }
    var frame: CGRect
    var caption = ""

    init(_ frame: CGRect, caption: String = "") {
        self.frame = frame
        self.caption = caption
    }
}

extension Plaque {
    init() { self.init(.zero) }
}

struct PlaqueDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Plaque>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), .white)
    }
}

struct PlaquesPlugin: CanvasPlugin {
    var id: PluginID { "plaques" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(PlaqueDefinition()) { plaque in
            let place = plaque.placement(size: plaqueFrame.size) { Plaque(.zero) }
            plaque.tool(label: "Plaque", systemImage: "rectangle.portrait", shortcut: "p", placing: place)
            plaque.title()
            plaque.contentsRow { plaque in ContentsLabel(plaque.props.caption, placeholder: "Blank", badge: "B") }
            plaque.details(header: { $plaque in TitleHeader($plaque, subtitle: "A plaque") }) {}
        }
    }
}

/// Gives cards (CanvasTesting's) a title from outside, derived from their text, as a bridge does,
/// and a header that renames them by editing that text: a title that's blank while untitled.
struct CardTitlesPlugin: CanvasPlugin {
    var id: PluginID { "card-titles" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.title(Card.self) { $0.props.text }
        registrar.details(Card.self, header: { $card in TitleHeader($card.text, placeholder: "Untitled Card") }) {}
    }
}

let plaqueFrame = CGRect(x: 60, y: 100, width: 200, height: 120)

/// The keyboard, the selection, the fixtures, plaques, titles, the table of contents and the panel,
/// then `more`.
@MainActor func titleEditor(_ more: [any CanvasPlugin] = [], scheduler: any Scheduler = ManualScheduler()) throws -> CanvasEditor {
    CanvasEditor(registry: try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), PlaquesPlugin(), TitlesPlugin(),
                                                  TableOfContentsPlugin(), DetailPanelPlugin()] + more),
                 scheduler: scheduler)
}

extension CanvasEditor {
    func title(_ id: ShapeID) -> String? { document[id].flatMap(registry.title(of:)) }
    /// A shape's name as it's kept: the title Titles keeps, as typed.
    func name(_ id: ShapeID) -> String? { document[id]?[TitleProperty.self] }

    /// Inserts a plaque named `name`, in a transaction of its own.
    @discardableResult
    func add(_ plaque: Plaque, named name: String?) -> ShapeID {
        var shape = ShapeRecord(plaque)
        shape[TitleProperty.self] = name
        transact { $0.insert(shape) }
        return shape.id
    }

    func rename(_ id: ShapeID, _ name: String?) {
        transact { $0.update(id) { $0[TitleProperty.self] = name } }
    }
}

/// The canvas, 400 by 300 view points.
@MainActor func render(_ editor: CanvasEditor) -> NSBitmapImageRep { renderBitmap(editor, size: CGSize(width: 400, height: 300)) }

/// The panel beside a canvas in an unshown window, as the app places them. The editor keeps real
/// time, so SwiftUI's updates and the panel's hand-back land while the main run loop runs
/// (`window.spin`, from CanvasTesting).
@MainActor
final class HeaderWindow {
    let editor: CanvasEditor
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    let canvas: CanvasView
    private(set) var hosting: NSView!

    init(_ editor: CanvasEditor) {
        self.editor = editor
        canvas = CanvasView(editor: editor)
        canvas.frame = CGRect(x: 0, y: 0, width: 900 - DetailStyle.idealWidth, height: 600)
        hosting = NSHostingView(rootView: DetailPanelView(editor: editor, onExit: { [unowned self] in window.makeFirstResponder(canvas) }))
        hosting.frame = CGRect(x: 900 - DetailStyle.idealWidth, y: 0, width: DetailStyle.idealWidth, height: 600)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        root.addSubview(canvas)
        root.addSubview(hosting)
        window.contentView = root
        window.settle()
    }

    /// The header's title field: in the panel's top 44 points (`DetailStyle.headerHeight`).
    var titleField: NSTextField? {
        hosting.descendants(NSTextField.self).first { $0.isEditable && $0.convert($0.bounds, to: hosting).maxY <= 44 }
    }

    var canvasHasKeyboard: Bool { window.firstResponder === canvas }
}

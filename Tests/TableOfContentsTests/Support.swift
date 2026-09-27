import AppKit
import Canvas
import CanvasTesting
import Keyboard
import Selection
import SwiftUI
import TableOfContents
import TestKit

// Fixtures only: the CanvasTesting kinds plus local ones, so every test here shows the table of
// contents knows no real kind.

/// A box with a name, the Widget tool, and a row: its name (or "Unnamed") and a count. Hidden
/// widgets aren't listed.
struct Widget: BoxShapeProps {
    static let kind: ShapeKind = "widget"
    var frame: CGRect
    var name: String
    var count = 0
    var isHidden = false

    init(_ frame: CGRect = widgetFrame, name: String = "", count: Int = 0, isHidden: Bool = false) {
        self.frame = frame
        self.name = name
        self.count = count
        self.isHidden = isHidden
    }
}

struct WidgetDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Widget>, in context: RenderContext) {}
}

/// A box with the Gizmo tool and no row of its own.
struct Gizmo: BoxShapeProps {
    static let kind: ShapeKind = "gizmo"
    var frame: CGRect
    init(_ frame: CGRect = widgetFrame) { self.frame = frame }
}

struct GizmoDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Gizmo>, in context: RenderContext) {}
}

/// A box pinned to another shape, whose row nests under that shape's.
struct Pin: BoxShapeProps {
    static let kind: ShapeKind = "pin"
    var frame: CGRect
    var name: String
    var target: ShapeID?
    init(_ name: String, on target: ShapeID?) {
        frame = widgetFrame
        self.name = name
        self.target = target
    }
}

struct PinDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Pin>, in context: RenderContext) {}
}

/// A box linked to another shape: it nests under that shape's row, and keeps the Link tool's row.
struct Link: BoxShapeProps {
    static let kind: ShapeKind = "link"
    var frame: CGRect
    var target: ShapeID?
    init(on target: ShapeID?) {
        frame = widgetFrame
        self.target = target
    }
}

struct LinkDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Link>, in context: RenderContext) {}
}

/// How often a widget's row has been made.
@MainActor var widgetRowsMade = 0

/// Widgets, gizmos and pins.
struct WidgetsPlugin: CanvasPlugin {
    var id: PluginID { "widgets" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(WidgetDefinition()) { widget in
            let place = widget.placement(size: widgetFrame.size) { Widget() }
            widget.tool(label: "Widget", systemImage: "gearshape", shortcut: "w", placing: place)
            widget.contentsRow(when: { !$0.props.isHidden }) { widget in
                let _ = (widgetRowsMade += 1)
                ContentsLabel(widget.props.name, placeholder: "Unnamed", badge: widget.props.count > 0 ? "\(widget.props.count)" : nil)
            }
        }
        registrar.shape(GizmoDefinition()) { gizmo in
            gizmo.tool(label: "Gizmo", systemImage: "cube", shortcut: "g", placing: gizmo.placement(size: widgetFrame.size) { Gizmo() })
        }
        registrar.shape(PinDefinition()) { pin in
            pin.contentsRow(nestedUnder: { $0.props.target }) { pin in
                ContentsLabel(pin.props.name, systemImage: "pin")
            }
        }
        registrar.shape(LinkDefinition()) { link in
            link.tool(label: "Link", systemImage: "link", placing: link.placement(size: widgetFrame.size) { Link(on: nil) })
            link.contentsRow(nestedUnder: { $0.props.target })
        }
    }
}

let widgetFrame = CGRect(x: 1000, y: 1000, width: 100, height: 60)

/// The selection, the fixtures, widgets, and the table of contents, then `more`.
@MainActor func contentsEditor(_ more: [any CanvasPlugin] = [], scheduler: any Scheduler = ManualScheduler()) throws -> CanvasEditor {
    CanvasEditor(registry: try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), WidgetsPlugin(), TableOfContentsPlugin()] + more),
                 scheduler: scheduler)
}

extension CanvasEditor {
    var contents: ContentsState { tableOfContents! }
}

extension Array where Element == ContentsEntry {
    /// Each row's text, nested rows indented under theirs, which reads well in a failure.
    @MainActor var outline: [String] {
        flatMap { entry in [entry.label?.text ?? "<view>"] + (entry.children ?? []).outline.map { "  " + $0 } }
    }
}

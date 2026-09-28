import Adornments
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import EllipseTitles
import Ellipses
import Keyboard
import RectangleTitles
import Rectangles
import Selection
import SwiftUI
import TableOfContents
import TestKit
import Titles

// The title bridges' headers, written through as the header's field writes, a `Binding` (SwiftUI's,
// whose own Ellipse and Rectangle are why the kinds are named with their modules here).

@MainActor let titleHeaderTests = Suite("Title bridges' headers", [
    test("EllipseTitles and RectangleTitles: the detail panel's header renames the shape, or clears its name") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), DetailPanelPlugin(), EllipsesPlugin(), RectanglesPlugin(), AdornmentsPlugin(),
                                            TitlesPlugin(), TableOfContentsPlugin(), EllipseTitlesPlugin(), RectangleTitlesPlugin()])
        let editor = h.editor, registry = editor.registry, panel = try require(editor.detailPanel)
        @MainActor func title(_ id: ShapeID) -> String? { editor.document[id].flatMap(registry.title(of:)) }
        @MainActor func header(_ id: ShapeID) throws -> TitleHeader {
            try require(panel.layout(for: try require(editor.document[id])).header(as: TitleHeader.self))
        }

        let ellipse = h.add(Ellipses.Ellipse(frame: CGRect(x: 40, y: 60, width: 200, height: 140)))
        expectEqual(try header(ellipse).title, "", "nobody's named it")
        expectEqual(try header(ellipse).placeholder, "Ellipse, 200 × 140", "the name it has meanwhile")
        // What the header's field writes through, as a person types.
        let named = try require(editor.shapeBinding(ellipse, as: Ellipses.Ellipse.self))[TitleProperty.self]
        named.wrappedValue = "Sun"
        expectEqual(title(ellipse), "Sun")
        expectEqual(try header(ellipse).title, "Sun")
        named.wrappedValue = nil
        expectEqual(title(ellipse), "Ellipse, 200 × 140", "cleared, it's called by its size again")

        let rectangle = h.add(Rectangles.Rectangle(frame: CGRect(x: 300, y: 60, width: 200, height: 140)))
        expectEqual(try header(rectangle).title, "")
        expectEqual(try header(rectangle).placeholder, nil, "the kind's name")
        try require(editor.shapeBinding(rectangle, as: Rectangles.Rectangle.self))[TitleProperty.self].wrappedValue = "Server room"
        expectEqual(title(rectangle), "Server room")
        try require(editor.shapeBinding(rectangle, as: Rectangles.Rectangle.self))[TitleProperty.self].wrappedValue = nil
        expectEqual(title(rectangle), nil)
    },
])

import Adornments
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import Keyboard
import RectangleTitles
import Rectangles
import Selection
import SwiftUI
import TableOfContents
import TestKit
import Titles

// The title bridge's header, written through as the header's field writes, a `Binding` (SwiftUI's,
// whose own Rectangle is why the kind is named with its module here).

@MainActor let titleHeaderTests = Suite("The title bridge's header", [
    test("RectangleTitles: the detail panel's header renames the shape, or clears its name") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), DetailPanelPlugin(), RectanglesPlugin(), AdornmentsPlugin(),
                                            TitlesPlugin(), TableOfContentsPlugin(), RectangleTitlesPlugin()])
        let editor = h.editor, registry = editor.registry, panel = try require(editor.detailPanel)
        @MainActor func title(_ id: ShapeID) -> String? { editor.document[id].flatMap(registry.title(of:)) }
        @MainActor func header(_ id: ShapeID) throws -> TitleHeader {
            try require(panel.layout(for: try require(editor.document[id])).header(as: TitleHeader.self))
        }

        let rectangle = h.add(Rectangles.Rectangle(frame: CGRect(x: 300, y: 60, width: 200, height: 140)))
        expectEqual(try header(rectangle).title, "")
        expectEqual(try header(rectangle).placeholder, nil, "the kind's name")
        // What the header's field writes through, as a person types.
        try require(editor.shapeBinding(rectangle, as: Rectangles.Rectangle.self))[TitleProperty.self].wrappedValue = "Server room"
        expectEqual(title(rectangle), "Server room")
        expectEqual(try header(rectangle).title, "Server room")
        try require(editor.shapeBinding(rectangle, as: Rectangles.Rectangle.self))[TitleProperty.self].wrappedValue = nil
        expectEqual(title(rectangle), nil)
    },
])

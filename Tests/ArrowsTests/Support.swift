@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TableOfContents

// Two boxes where the POC's first two welcome notes are. Fixture shapes only: nothing here can
// import a real vertical, which is the proof that arrows don't know concrete kinds.
let boxA = CGRect(x: 80, y: 80, width: 200, height: 200)
let boxB = CGRect(x: 460, y: 80, width: 200, height: 200)
let fast: CGFloat = 3, slow: CGFloat = 0.1

@MainActor
struct Board {
    let h: EditorHarness
    let a: ShapeID
    let b: ShapeID
    let arrow: ShapeID?
    /// Where B is.
    let second: CGRect

    /// Two boxes, optionally with an arrow between their centers.
    init(arrow bend: CGFloat? = nil, second: CGRect = boxB) throws {
        h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), ArrowsPlugin(), TableOfContentsPlugin()])
        a = h.add(Box(boxA))
        b = h.add(Box(second))
        self.second = second
        if let bend {
            let arrow = Arrow(start: .bound(ArrowBinding(shapeID: a, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)),
                              end: .bound(ArrowBinding(shapeID: b, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)),
                              bend: bend)
            self.arrow = h.add(arrow)
        } else {
            self.arrow = nil
        }
    }

    var arrows: [Arrow] { h.editor.document.shapes.compactMap { $0.typed(as: Arrow.self)?.props } }
    var arrowIDs: [ShapeID] { h.editor.document.shapes.filter { $0.kind == Arrow.kind }.map(\.id) }

    /// Selects the arrow and presses its end's handle, where the end is bound: B's center.
    func pressEnd() {
        h.editor.selection = arrow
        h.move(to: h.view(second.center))
        h.press()
    }

    /// Re-aims the arrow's end, the drag a port's connection is drawn with too: presses the end's
    /// handle (`pressEnd`), drags it off B at `fast` to `via`, empty canvas, where it lets go, then
    /// on to `to` at `speed`. Points are the view's.
    func reaimEnd(via: CGPoint = CGPoint(x: 400, y: 120), to: CGPoint, speed: CGFloat = fast, release: Bool = true) {
        pressEnd()
        h.drag(to: via, speed: fast)
        h.drag(to: to, speed: speed)
        if release { h.release() }
    }
}

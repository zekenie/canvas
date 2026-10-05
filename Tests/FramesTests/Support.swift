import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import DetailPanel
import Frames
import Geometry
import Keyboard
import Mentions
import Selection
import SlashCommands
import TableOfContents
import TestKit
import Titles
import Topology
import Transform

/// Every plugin a frame contributes to (Selection's resizing and marquee; Titles, and through it
/// Adornments and slash commands; Mentions, and through it the panel, the context menu and Topology;
/// Transform, whose container channel it offers; the table of contents; the keys), CanvasTesting's
/// fixtures, for boxes to put in frames, and its freezing, for read-only shapes (a locked frame,
/// without Locking).
@MainActor func framePlugins(_ refusals: RefusalLog = RefusalLog()) -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), FramesPlugin(), DetailPanelPlugin(), ContextMenusPlugin(),
     SlashCommandsPlugin(), TableOfContentsPlugin(), AdornmentsPlugin(), TitlesPlugin(), MentionsPlugin(), TransformPlugin(),
     FreezingPlugin(log: refusals)]
}

/// An empty board of `framePlugins`, its view 1000 × 800 at 100%, where view points are world units.
@MainActor func frameHarness(_ refusals: RefusalLog = RefusalLog()) throws -> EditorHarness {
    let h = try EditorHarness(plugins: framePlugins(refusals))
    h.editor.viewportDidResize(to: CGSize(width: 1000, height: 800))
    return h
}

/// Where most tests put their frame: 400 × 300, 100 in from the top left.
let frameRect = CGRect(x: 100, y: 100, width: 400, height: 300)

extension EditorHarness {
    /// A frame at `rect`, titled `title`, in a transaction of its own.
    @discardableResult
    func addFrame(_ rect: CGRect = frameRect, title: String? = nil) -> ShapeID {
        var frame = ShapeRecord(Frame(frame: rect))
        frame[TitleProperty.self] = title
        editor.transact { $0.insert(frame) }
        return frame.id
    }

    /// A box at `rect`, put in `container` (none: on the board).
    @discardableResult
    func addBox(_ rect: CGRect, in container: ShapeID? = nil) -> ShapeID {
        let id = add(Box(rect))
        if let container { editor.put([id], in: container) }
        return id
    }

    /// The Frame tool, by its key.
    func frameTool() {
        expect(key("f"), "F is the Frame tool's key")
        expectEqual(editor.currentToolID, ToolID(placing: Frame.kind))
    }

    /// The frames on the board, back to front.
    var frames: [AnyShapeRecord] { editor.document.shapes.filter { $0.kind == Frame.kind } }
}

extension CanvasEditor {
    /// A shape's box.
    func box(_ id: ShapeID) -> CGRect? { document[id]?.box }
}

/// The canvas, `size` view points, drawn as `renderBitmap` draws it, in the light appearance or the
/// dark.
@MainActor func render(_ editor: CanvasEditor, size: CGSize = CGSize(width: 600, height: 500), dark: Bool = false) -> NSBitmapImageRep {
    guard dark else { return renderBitmap(editor, size: size) }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)
    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let bounds = CGRect(origin: .zero, size: size)
        editor.draw(in: cg, bounds: bounds, dirtyRect: bounds)
        NSGraphicsContext.restoreGraphicsState()
    }
    return rep
}

@MainActor func expectColor(_ actual: [Int], _ expected: [Int], _ what: String, within tolerance: Int = 3,
                            file: StaticString = #fileID, line: UInt = #line) {
    expect(zip(actual, expected).allSatisfy { abs($0 - $1) <= tolerance }, "\(what): \(actual) is not about \(expected)", file: file, line: line)
}

/// The canvas's own color where no dot is, in the light appearance and the dark: what's under a
/// frame drawn nowhere.
let lightCanvas = [246, 246, 246], darkCanvas = [28, 28, 28]

/// Where a resize handle is on a box.
func point(of handle: ResizeHandle, on box: CGRect) -> CGPoint {
    switch handle {
    case .topLeft: CGPoint(x: box.minX, y: box.minY)
    case .top: CGPoint(x: box.midX, y: box.minY)
    case .topRight: CGPoint(x: box.maxX, y: box.minY)
    case .right: CGPoint(x: box.maxX, y: box.midY)
    case .bottomRight: CGPoint(x: box.maxX, y: box.maxY)
    case .bottom: CGPoint(x: box.midX, y: box.maxY)
    case .bottomLeft: CGPoint(x: box.minX, y: box.maxY)
    case .left: CGPoint(x: box.minX, y: box.midY)
    }
}

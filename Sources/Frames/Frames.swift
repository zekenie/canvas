import Canvas
import CoreGraphics
import Keyboard
import Mentions
import Selection
import Titles

extension PluginID {
    /// Not "frames", which DetailPanelTests' fixture plugin goes by: an id two modules write is
    /// both's, to the audit.
    public static let framing: PluginID = "framing"
}

/// A region of the board that holds shapes: what's in it moves with it, paints above it, takes its
/// lock, and nothing sits across its edge (the core's containment: `ShapeContaining`). Its props are
/// only its frame. What it's called is the title Titles adds to it, and what it holds is each held
/// shape's own `container`, the core's, so nothing about either is here.
public struct Frame: BoxShapeProps {
    public static let kind: ShapeKind = "frame"
    public static let properties = Properties<Frame>(title: "Frame") {
        Property("frame", \.frame).required()
    }
    /// What a click with the Frame tool places, centered on the click.
    public static let defaultSize = CGSize(width: 640, height: 400)
    /// The smallest a frame is drawn or resized to: its pill's row, and a small shape inside it.
    public static let minimumSize = CGSize(width: 96, height: 64)

    public var frame: CGRect

    public init(frame: CGRect) { self.frame = frame }
    public init() { self.init(frame: .zero) }
}

extension Frame {
    /// What a frame is called while it has no title, in its row and its panel's header.
    static let placeholder = "Untitled Frame"
    /// What an untitled frame's pill says, dimmed, so there's something to grab it by.
    static let pillPlaceholder = "Frame"
    /// Its symbol, on its tool, row, header and mentions (never in its pill).
    static let systemImage = "rectangle.dashed"
}

/// Frames: the Frame tool (F), which draws a frame with a drag, or places one with a click, and the
/// frame, a region that holds what's put down in it (the core's containment). Pressed, it's hollow:
/// its border and its title's pill grab it, and its inside is the canvas, unless it holds nothing. It
/// opts into Titles (its name, in a pill above it, dimmed "Frame" while untitled), Mentions (by its
/// name; following a mention goes to it; a Mentioned In tab), Selection's resizing, the table of
/// contents (a row Titles names) and the detail panel (a header that renames it).
public struct FramesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .framing }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(FrameDefinition()) { frame in
            // What a click places, and what `canvas draw` places; a drag draws its own rect.
            let place = frame.placement(size: Frame.defaultSize) { Frame() }
            frame.tool(label: "Frame", systemImage: Frame.systemImage, shortcut: "f", placing: place) { _ in FrameTool(placing: place) }
            frame.title(placeholderInPill: Frame.pillPlaceholder, coverSurface: FrameStyle.fill)  // Titles keeps its name, in a pill above it
            frame.mentionable(tint: { _ in FrameStyle.tint })               // by its name; followed, it's gone to
            frame.resizable(minimumSize: Frame.minimumSize)                 // eight handles, Selection's
            frame.frameRow()                                                // the table of contents, named by Titles
            frame.frameHeader()                                             // renamed in the panel's header
        }
    }
}

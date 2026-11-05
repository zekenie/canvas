import Canvas
import Colors
import Connections
import CoreGraphics
import Keyboard
import Mentions
import Palette
import Selection
import Titles
import Transform
import Types

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
    /// The smallest a frame is drawn or resized to: its title's tab, and a small shape inside it. Said once,
    /// by its placement (`Placement.minimumSize`), which the Frame tool, resizing, Create Frame and
    /// `canvas draw` all read.
    public static let minimumSize = CGSize(width: 96, height: 64)

    public var frame: CGRect

    public init(frame: CGRect) { self.frame = frame }
    public init() { self.init(frame: .zero) }
}

extension Frame {
    /// What a frame is called while it has no title, in its row and its panel's header.
    static let placeholder = "Untitled Frame"
    /// What an untitled frame's tab says, dimmed, so there's something to grab it by.
    static let pillPlaceholder = "Frame"
    /// Its symbol, on its tool, row, header and mentions (never in its tab).
    static let systemImage = "rectangle.dashed"
}

/// Frames: the Frame tool (F), which draws a frame with a drag, or places one with a click, and the
/// frame, a region that holds what's put down in it (the core's containment). Pressed, it's hollow:
/// its border and its title's tab grab it, and its inside is the canvas, unless it holds nothing. It
/// opts into Titles (its name, in a tab on its top edge at every zoom, dimmed "Frame" while untitled), Mentions (by its
/// name; following a mention goes to it), Selection's resizing, the table of
/// contents (a row Titles names), the detail panel (a header that renames it), Transform (it offers
/// the container channel, so it can be turned into whatever takes that: a subboard, in the app), Types
/// (it can be of types: it has no words, so its values are set in the panel, never filled from words) and
/// Ports (on its own channel, `FrameLink`, so an arrow joins two frames, or a frame and a subboard).
/// Create Frame, in the context menu, puts one down around the shapes it's for, holding them.
public struct FramesPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .framing }

    public func register(into registrar: inout PluginRegistrar) {
        // What the Frame tool's drag reads of the keys, for the Keyboard Shortcuts window.
        registrar.keyHint("⇧ Drag a Frame", "Draw It Square", while: .pointer)
        registrar.keyHint("⌥ Drag a Frame", "Draw It From the Center", while: .pointer)
        registrar.shape(FrameDefinition()) { frame in
            // What a click places, and what `canvas draw` places; a drag draws its own rect. Never under
            // its minimum, however it's drawn.
            let place = frame.placement(size: Frame.defaultSize, minimumSize: Frame.minimumSize) { Frame() }
            frame.tool(label: "Frame", systemImage: Frame.systemImage, shortcut: "f", placing: place) { _ in FrameTool(placing: place) }
            frame.colorable()                                               // a color of its own; none, the neutral surface
            frame.tint(FrameStyle.tint)                                     // its gray, wherever it's listed by its kind
            frame.title(placeholderInPill: Frame.pillPlaceholder)          // Titles keeps its name
            frame.titleTab { shape, context in                              // said in a tab on its top edge, at every zoom, in its own colors
                let book = context.service(ColorBook.self)
                return TitleTabLook(surface: book?.color(\.surface, of: shape) ?? FrameStyle.fill,
                                    edge: book?.color(\.solid, of: shape) ?? FrameStyle.border)
            }
            frame.mentionable()                                             // by its name; followed, it's gone to
            frame.resizable(minimumSize: place.minimumSize)                 // eight handles, Selection's
            frame.frameRow()                                                // the table of contents, named by Titles
            frame.frameHeader()                                             // renamed in the panel's header
            frame.turnable(through: ContainerChannel.self)                  // turned through the container channel: into a subboard, where Subboards takes it
            frame.typeable(fillsFromWords: false)                           // of types: chips above it, its values in the panel's Types tab (no words to fill them from)
            frame.accessibility { frame, editor in                          // VoiceOver reads what it holds as its value: "3 shapes"
                editor.document[frame.id] == nil ? nil : AccessibleTraits(value: FrameStyle.accessibleContents(editor.shapeContext.contents(of: frame.id).count))
            }
            frame.frameLinks()                                              // and ports: arrows to and from a frame, on its channel
        }
        registrar.channel(FrameLink.self)                                   // which this plugin declares
        registrar.createFrameItem()                                         // Create Frame, around what the menu's for
    }
}

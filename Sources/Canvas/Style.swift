import AppKit

/// The core's UI constants. Sizes are view points unless noted.
@MainActor
public enum Style {
    static let canvasBackground = NSColor(name: nil) {
        $0.isDark ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.965, alpha: 1)
    }
    static let gridDot = NSColor(name: nil) {
        $0.isDark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.16)
    }
    /// World-space distance between grid dots at 100% zoom.
    static let gridSpacing: CGFloat = 24
    /// Grid dots never get closer than this on screen; the grid coarsens instead.
    static let minGridSpacingOnScreen: CGFloat = 16
    static let gridDotDiameter: CGFloat = 2
    // The grid's tiles (`DotGrid`). Sizes in device pixels.
    /// A copy of a tile lands on a quarter of a pixel: within an eighth of where its dots are.
    nonisolated static let gridSubpixelSteps = 4
    /// A tile holds at most this many dots a side, and is at most `gridLargestTile` pixels a side.
    nonisolated static let gridMostDotsPerSide = 16
    nonisolated static let gridLargestTile: CGFloat = 512
    /// What a frame whose tiles are made afresh spends, in microseconds (measured into an RGBA
    /// bitmap on Retina): on each dot filled into a tile, each pixel of a tile made (its first draw
    /// reads all of it), and each copy drawn. What a tile's size is chosen by: a small one is quick
    /// to make but needs many copies, a big one the other way round, and one of many variants is
    /// made many times.
    nonisolated static let gridDotCost = 1.0
    nonisolated static let gridTilePixelCost = 0.00076
    nonisolated static let gridCopyCost = 2.0

    static let shapeShadow = NSColor(white: 0, alpha: 0.25)
    /// The shadow's blur, which is as far as it reaches past the shape's edge, times the zoom in the
    /// context's base space: on screen view points, so 6 world units; in a 2× bitmap pixels, half that.
    static let shapeShadowBlur: CGFloat = 6
    /// How far past the view, in world units, a shape is still drawn: a shadow (6 units of blur)
    /// of one just out of view shows at the edge.
    static let drawingPad: CGFloat = 40

    // Skeletons: shapes as they show zoomed out (`CustomSkeleton`).
    /// Below this zoom a frame draws shapes as skeletons (`CanvasEditor.skeletonZoom`): a note's
    /// 16-point text, and a schema card's description, set as a note's, are under 6 points on
    /// screen, which reads as texture, not words. No hysteresis: the level is the zoom's.
    static let skeletonZoom: CGFloat = 0.35
    /// The default skeleton's fill (and an open one's line): a muted gray on the light canvas, and
    /// as far from the dark canvas in the dark. A board preview's silhouettes are this gray too
    /// (`boardPreview`), since they're the same thing: shapes with nothing of their own.
    static let skeleton = NSColor(name: nil) {
        $0.isDark ? NSColor(srgbRed: 0.44, green: 0.46, blue: 0.48, alpha: 1) : NSColor(srgbRed: 0.6, green: 0.62, blue: 0.64, alpha: 1)
    }
    /// Greeked text: where a skeleton's text would be, over a shape's light body (a note's yellow,
    /// a card's white), which is the same in both appearances. Translucent, so a bar takes its
    /// surface's hue; a little stronger in the dark, where the default skeleton it may lie on is
    /// darker.
    static let skeletonText = NSColor(name: nil) {
        $0.isDark ? NSColor(white: 0, alpha: 0.26) : NSColor(white: 0, alpha: 0.2)
    }
    /// An open shape's skeleton line, in view points: a line stays this wide however far out, as
    /// the minimap's and a preview's do (an arrow's 3.5 units are a third of a point at 10%), and
    /// it's about as wide as an arrow's own just below `skeletonZoom`, so nothing jumps there.
    static let skeletonLineWidth: CGFloat = 1

    // Interaction and outlines. The values follow tldraw.
    static let accent = NSColor.controlAccentColor
    static let indicatorWidth: CGFloat = 1.5
    /// A faint outline (`Outlines.faintShapes`: a hover) is wider and lighter than the others, so
    /// it's easy to see (over a yellow note too) but doesn't read as selected. Not tldraw's, which
    /// strokes a hover like the selection.
    static let faintIndicatorWidth: CGFloat = 2.5
    static let faintIndicatorOpacity: CGFloat = 0.6
    /// How far a closed shape's outline (the selection's, a hover's, the hint) stands off its edge,
    /// in view points, for every kind alike: the line is drawn this far outside the shape, corners
    /// concentric, a gap of the canvas between the two, so it never lies over a border or a shadow
    /// of the shape's own and reads the same on every kind. Not tldraw's, whose outlines are on the
    /// edge (`CanvasEditor.outlineStandoff`, host API, 0 outlines each shape on its own path, as the
    /// proof of concept did). An open shape (an arrow) has no inside to stand off, so keeps the line
    /// on its own path, and zoomed out, where shapes are skeletons, an outline is a ring on its
    /// frame.
    public static let outlineStandoff: CGFloat = 4
    public static let dragThreshold: CGFloat = 4

    /// Releasing a modifier takes effect this much later, so letting go of it and the mouse
    /// together doesn't undo what it did.
    static let modifierReleaseDelay: Duration = .milliseconds(150)

    // The camera's slide after a flung hand drag (tldraw's slideCamera). Speeds are view points
    // per millisecond.
    /// A release slower than this doesn't slide.
    static let cameraSlideMinSpeed: CGFloat = 0.1
    /// Release speeds are clamped to this (the slide itself starts at no more than 1).
    static let cameraSlideMaxSpeed: CGFloat = 2
    /// The speed lost every frame.
    static let cameraSlideFriction: CGFloat = 0.09
    /// The slide stops once its speed would drop under this.
    static let cameraSlideStopSpeed: CGFloat = 0.01
    /// A slide frame's length.
    static let cameraSlideFrameMilliseconds: CGFloat = 16
    static var cameraSlideFrame: Duration { .milliseconds(Int(cameraSlideFrameMilliseconds)) }

    /// A board shown for the first time fits its shapes with this much margin in all (half on each
    /// side), no closer than 100%; so does Zoom to Fit, as close as the zoom goes.
    static let firstVisitInset: CGFloat = 64
    /// How long the zoom commands ease the camera (tldraw's animationMediumMs).
    static let zoomDuration: Duration = .milliseconds(320)
    /// How long the pointer stays on what a popover is about before it shows (`hoverPopover`), and
    /// how soon after one goes another shows at once.
    static let popoverDelay: Duration = .milliseconds(500)
    static let popoverWarmth: Duration = .milliseconds(500)

    // Containers (`ShapeContaining`: a frame), and what's put down across their edges.
    /// How far inside a container's edge a shape nudged in ends, and how far outside one nudged out,
    /// in world units (`Transaction.settle`): the edge stays clear to grab.
    nonisolated static let containerGap: CGFloat = 16
    /// The glide (`CanvasEditor.glide`): a shape settling nudged in or out, or a refused drop going
    /// back, eases there from where it was drawn over this long, a frame every `glideFrame`...
    static let glideDuration: Duration = .milliseconds(250)
    static let glideFrame: Duration = .milliseconds(16)
    /// ...going a little past where it lands and back (an ease out with this much overshoot, the
    /// usual 1.70158 going a tenth past; this, about a twentieth).
    static let glideOvershoot: CGFloat = 1.2

    // Scrolling at the canvas's edges while a drag that asks for it runs (tldraw's EdgeScrollManager
    // and its options). Milliseconds and view points.
    /// How near an edge (or past it) the pointer scrolls the canvas: at the edge fully, half as fast
    /// halfway in.
    /// How far in from the edges of the view (view points) an editing view's caret is kept
    /// (`EditContext.keepInView`).
    static let keepInViewMargin: CGFloat = 16
    static let edgeScrollDistance: CGFloat = 8
    /// How long the pointer stays there before it scrolls, and then how long the speed eases in.
    static let edgeScrollDelay: CGFloat = 200
    static let edgeScrollEaseDuration: CGFloat = 200
    /// View points a 60 Hz frame at full speed.
    static let edgeScrollSpeed: CGFloat = 25
    /// A view narrower (or shorter) than this scrolls across (or up and down) this much slower.
    static let edgeScrollSmallView: CGFloat = 1000
    static let edgeScrollSmallViewFactor: CGFloat = 0.612

    // Pictures of boards: the minimap's, and boards' previews (`BoardPreviews`). Sizes in pixels.
    /// A shape under this many pixels across is drawn as its bounds (`Silhouettes`).
    static let detailedSilhouette: CGFloat = 4
    /// A preview's silhouettes: the default skeleton's gray (`skeleton`), as the minimap's are on a
    /// light canvas, and darker in the dark, for an owner's dark body.
    static let boardPreview = skeleton
    /// No preview's mask is larger on either side; a board's longest side is drawn this long.
    static let previewSide: CGFloat = 256
    /// An open shape's line in a preview, in the mask's pixels, or the screen's where it's drawn as
    /// paths.
    static let previewLineWidth: CGFloat = 1.5
    /// How many previews are kept, the one drawn longest ago going first: 64 KB of mask each at
    /// most, and their paths, some 80 bytes a shape.
    static let keptPreviews = 64
    /// A preview's paths are in cells of a grid over its board, about this many shapes to a cell
    /// and at most this many cells a side, so a frame draws only those in view.
    static let previewCellShapes = 32
    static let previewCellsAcross = 16
    /// How many shapes a frame draws as paths, over all the previews drawn larger than their masks
    /// (some 2 µs a shape, measured); those in view past it draw their masks.
    static let previewPathShapes = 1_000
    /// A preview's rect narrower or shorter than this on screen, in view points, shows none: there's
    /// nothing to see, and a board zoomed out over many owners asks for no builds.
    static let previewSmallestSide: CGFloat = 16
    /// How long building previews may take in a frame (as the minimap's tiles do); what doesn't fit
    /// waits for the next. Ten cards in view cost a frame 6 to 10 ms on a loaded machine before any
    /// build (most of it the canvas itself, drawn with nothing on it), so this leaves room under 16 ms.
    static let previewFrameBudget: Duration = .milliseconds(2)
    /// A frame builds at least this many shapes' worth, whatever it has left; a step builds at most
    /// the other, so what a shape costs is measured often.
    static let previewChunks: ClosedRange<Int> = 16...512
    /// A guess at what a shape costs a preview, until previews have measured it, and how much each
    /// step moves the guess toward what it took. Seconds.
    static let initialPreviewCost = 2e-6
    static let previewCostLearning = 0.25
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

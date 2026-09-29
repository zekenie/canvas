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

    // Interaction and outlines. The values follow tldraw.
    static let accent = NSColor.controlAccentColor
    static let indicatorWidth: CGFloat = 1.5
    /// A faint outline (`Outlines.faintShapes`: a hover) is wider and lighter than the others, so
    /// it's easy to see (over a yellow note too) but doesn't read as selected. Not tldraw's, which
    /// strokes a hover like the selection.
    static let faintIndicatorWidth: CGFloat = 2.5
    static let faintIndicatorOpacity: CGFloat = 0.6
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
    /// A preview's silhouettes: one muted gray, as the minimap's are on a light canvas, for an
    /// owner's light body.
    static let boardPreview = NSColor(srgbRed: 0.6, green: 0.62, blue: 0.64, alpha: 1)
    /// No preview is larger on either side; a board's longest side is drawn this long.
    static let previewSide: CGFloat = 256
    /// An open shape's line in a preview.
    static let previewLineWidth: CGFloat = 1.5
    /// How many previews are kept, the one drawn longest ago going first: 64 KB each at most.
    static let keptPreviews = 64
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

import AppKit
import Geometry

/// A picture of a board of a file, drawn as the canvas draws it, with nothing selected: what Quick
/// Look shows of a `.canvasboard` file (its preview, space in the Finder, and its thumbnail, its
/// icon, from the app's Quick Look extension), what Edit › Copy as Image puts on the pasteboard, and
/// what `canvas capture` writes. It's the core's: it draws with the editor's host API, and a
/// plugin's command takes one too, which no plugin could if it were the window's.
///
/// Unless told otherwise the whole board is fitted into the picture, centered, with `inset` of
/// margin in all (half on each side), no closer than `maxZoom` (100%, as a board's first visit shows
/// it) and as far out as it takes to show all of it: past the canvas's 10%, down to 1%. Under 35%
/// its shapes are skeletons, as on the canvas. A picture of a part of a board is told what it is
/// about (`focus`) and, if it is to be at a zoom, which one (`zoom`): the view is fitted to those
/// shapes, or centered on them, and everything around them is drawn, as the canvas would show it.
/// A card that shows a preview of the board it owns (a subboard's) shows it built: the canvas builds
/// previews a little each frame, and a picture is one frame, so it builds them all first.
@MainActor
public final class BoardPicture {
    /// View points of margin around what the picture fits, in all (half on each side): a board's
    /// first visit's (`CanvasEditor.firstVisitInset`), unless set.
    public var inset = Style.firstVisitInset
    /// The closest what the picture fits is shown: 1, no bigger than at 100%, unless set (up to the
    /// canvas's closest, 800%). A `zoom` is not held to it.
    public var maxZoom: CGFloat = 1
    /// The shapes the picture is about, nil for those it shows: what the camera is fitted to, or
    /// centered on with a `zoom`. The shapes around them are drawn all the same (`showing` leaves
    /// them out), as a view of the board that comes to rest on those. Shapes of the board with no
    /// bounds are no help; with none that has any, it is about what it shows.
    public var focus: Set<ShapeID>?
    /// The zoom to take the picture at, 1 for 100% (within 1% and 800%), centered on what it is
    /// about, however much of the board that leaves out. Nil fits what it is about into the picture,
    /// no closer than `maxZoom`.
    public var zoom: CGFloat?
    private let editor: CanvasEditor
    /// The shapes drawn, nil for every one of the board.
    private let showing: Set<ShapeID>?

    /// A picture of a file's board (the root, unless `board` says another), its shapes of `registry`'s
    /// kinds: all of them, or, with `showing`, only those, fitted as the board is (Edit › Copy as Image,
    /// of the selection), the board's others there to be read (a type its notes are of, what a mention
    /// names) and not drawn. The file is put in place as the app opens one (`replaceFile`), so the
    /// plugins see what they see there.
    public init(file: CanvasFile, registry: Registry, board: BoardID = .root, showing: Set<ShapeID>? = nil) {
        editor = CanvasEditor(registry: registry)
        editor.boardPreviews.frameBudget = PictureStyle.previewBudget
        editor.replaceFile(with: file, showing: board)
        editor.drawnShapes = showing
        self.showing = showing
    }

    /// What the picture shows, in world units: the board's shapes' bounds, or those of the shapes
    /// it shows; null for none.
    private var bounds: CGRect {
        guard let showing else { return editor.shapeBounds }
        return editor.shapeContext.bounds(of: Array(showing)) ?? .null
    }

    /// What the picture is about, in world units: the bounds of its focus, else what it shows.
    private var aboutBounds: CGRect {
        if let focus, let about = editor.shapeContext.bounds(of: Array(focus)) { return about }
        return bounds
    }

    /// A picture of the board a file holds (a `.canvasboard` file's contents), read as the app reads
    /// one (`BoardCodec`): what it keeps aside isn't drawn. Throws what reading throws, for a file that
    /// isn't a board or that a newer app wrote.
    public convenience init(data: Data, registry: Registry) throws {
        self.init(file: try BoardCodec(registry: registry).decode(data).file, registry: registry)
    }

    /// Whether the board has nothing to show: no shape, or none with bounds.
    public var isEmpty: Bool { bounds.isNull }

    /// The size of a picture of what it is about, in whole view points: its bounds at `maxZoom` with
    /// the margin, or, where that's more than `limit`, as close as fits within it; and no smaller
    /// than `minimum` (the board in its middle, with more room around it). An empty board's is
    /// `minimum`. (A picture at a `zoom` is as big as it is asked to be: this is the size of a fit.)
    public func size(within limit: CGSize, minimum: CGSize = .zero) -> CGSize {
        let bounds = aboutBounds
        guard !bounds.isNull else { return minimum }
        let zoom = fit(bounds, in: limit).zoom
        let width = (bounds.width * zoom + inset).rounded(.up), height = (bounds.height * zoom + inset).rounded(.up)
        return CGSize(width: min(max(width, minimum.width), limit.width), height: min(max(height, minimum.height), limit.height))
    }

    /// How a picture of `size` view points sees the board.
    public struct Framing: Equatable, Sendable {
        /// The zoom it is taken at, 1 for 100%.
        public let zoom: CGFloat
        /// The part of the board in the picture, in world units.
        public let region: CGRect
        /// What the picture is about, in world units: the bounds of its focus, else of what it shows.
        /// Where `region` doesn't hold it, the picture shows only part of it.
        public let about: CGRect
        /// Whether the canvas would draw its shapes as skeletons at this zoom, with no text.
        public let drawsSkeletons: Bool
    }

    /// How a picture of `size` view points sees the board: nil for a board with nothing to show.
    public func framing(in size: CGSize) -> Framing? {
        guard let camera = self.camera(in: size) else { return nil }
        return Framing(zoom: camera.zoom, region: camera.toWorld(CGRect(origin: .zero, size: size)), about: aboutBounds,
                       drawsSkeletons: camera.zoom < editor.skeletonZoom)
    }

    /// Draws the picture, `size` view points, into `context` from its origin, y up (a bitmap's or a
    /// PDF's as made, Quick Look's), in `appearance`'s colors: the canvas's dark ones in `.darkAqua`.
    public func draw(in context: CGContext, size: CGSize, appearance: NSAppearance) {
        editor.viewportDidResize(to: size)
        editor.camera = camera(in: size) ?? Camera()
        let view = CGRect(origin: .zero, size: size)
        context.saveGState()
        defer { context.restoreGState() }
        // The canvas's origin, top-left, y down, as a flipped view's is.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        appearance.performAsCurrentDrawingAppearance {
            editor.draw(in: context, bounds: view, dirtyRect: view)
            // The frame asked for the previews its cards show: built now, as long as they take (up to
            // the budget), at the start of the next, which draws them.
            if editor.boardPreviews.isPending { editor.draw(in: context, bounds: view, dirtyRect: view) }
        }
    }

    /// The picture as an image of `size` view points, `scale` pixels to a point, in sRGB; nil for a
    /// size with no pixels.
    public func image(size: CGSize, scale: CGFloat, appearance: NSAppearance) -> CGImage? {
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        draw(in: context, size: size, appearance: appearance)
        return context.makeImage()
    }

    /// The picture as PNG data, `scale` pixels to a point (the PNG says so by its resolution, so a
    /// 2× picture pastes at its size in points): as big as what it is about at `maxZoom` with its
    /// margin, or as close as fits within `limit` (`size(within:)`), in `appearance`'s colors. Nil
    /// for a board with nothing to show.
    public func pngData(within limit: CGSize, scale: CGFloat, appearance: NSAppearance) -> Data? {
        pngData(size: size(within: limit), scale: scale, appearance: appearance)
    }

    /// The picture as PNG data of `size` view points, `scale` pixels to a point: what the camera
    /// sees of the board in a picture that size (`framing(in:)`). Nil for a board with nothing to
    /// show, or a size with no pixels.
    public func pngData(size: CGSize, scale: CGFloat, appearance: NSAppearance) -> Data? {
        guard !isEmpty, let image = image(size: size, scale: scale, appearance: appearance) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        bitmap.size = size
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Where the camera is for a picture of `size`: what it is about fitted into it, or, at a
    /// `zoom`, centered on it. Nil for a board with nothing to show.
    private func camera(in size: CGSize) -> Camera? {
        let about = aboutBounds
        guard !about.isNull else { return nil }
        guard let asked = zoom else { return fit(about, in: size) }
        let zoom = min(max(asked, PictureStyle.farthestZoom), Camera.zoomRange.upperBound)
        return Camera(origin: CGPoint(x: about.midX - size.width / 2 / zoom, y: about.midY - size.height / 2 / zoom), zoom: zoom)
    }

    private func fit(_ bounds: CGRect, in size: CGSize) -> Camera {
        Camera(fitting: bounds, in: size, inset: inset, minZoom: PictureStyle.farthestZoom, maxZoom: maxZoom)
    }
}

@MainActor
enum PictureStyle {
    /// How far out a picture goes to show all of a board: past the canvas's farthest, 10%. A board
    /// too big to show at this, 160,000 units across in a picture 1,600 points wide, shows its middle.
    static let farthestZoom: CGFloat = 0.01
    /// How long the previews a picture's cards show may take to build, all of them: past it, those
    /// not built show what a card shows without one (their count).
    static let previewBudget: Duration = .seconds(5)
}

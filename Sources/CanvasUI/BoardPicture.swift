import AppKit
@_spi(Host) import Canvas
import Geometry

/// A picture of a board file's root board, drawn as the canvas draws it, with nothing selected and
/// the whole board in view: what Quick Look shows of a `.canvasboard` file, as its preview (space in
/// the Finder) and its thumbnail (its icon), from the app's Quick Look extension (CanvasQuickLook).
///
/// The board is fitted into the picture, centered, with `inset` of margin in all (half on each side),
/// no closer than `maxZoom` (100%, as a board's first visit shows it) and as far out as it takes to
/// show all of it: past the canvas's 10%, down to 1%. Under 35% its shapes are skeletons, as on the
/// canvas. A card that shows a preview of the board it owns (a subboard's) shows it built: the canvas
/// builds previews a little each frame, and a picture is one frame, so it builds them all first.
@MainActor
public final class BoardPicture {
    /// View points of margin around the board, in all (half on each side): a board's first visit's
    /// (`CanvasEditor.firstVisitInset`), unless set.
    public var inset = CanvasEditor.firstVisitInset
    /// The closest the board is shown: 1, no bigger than at 100%, unless set (up to the canvas's
    /// closest, 800%).
    public var maxZoom: CGFloat = 1
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

    /// A picture of the board a file holds (a `.canvasboard` file's contents), read as the app reads
    /// one (`BoardCodec`): what it keeps aside isn't drawn. Throws what reading throws, for a file that
    /// isn't a board or that a newer app wrote.
    public convenience init(data: Data, registry: Registry) throws {
        self.init(file: try BoardCodec(registry: registry).decode(data).file, registry: registry)
    }

    /// Whether the board has nothing to show: no shape, or none with bounds.
    public var isEmpty: Bool { bounds.isNull }

    /// The size of a picture of the whole board, in whole view points: its shapes' bounds at
    /// `maxZoom` with the margin, or, where that's more than `limit`, as close as fits within it; and
    /// no smaller than `minimum` (the board in its middle, with more room around it). An empty
    /// board's is `minimum`.
    public func size(within limit: CGSize, minimum: CGSize = .zero) -> CGSize {
        let bounds = self.bounds
        guard !bounds.isNull else { return minimum }
        let zoom = camera(fitting: bounds, in: limit).zoom
        let width = (bounds.width * zoom + inset).rounded(.up), height = (bounds.height * zoom + inset).rounded(.up)
        return CGSize(width: min(max(width, minimum.width), limit.width), height: min(max(height, minimum.height), limit.height))
    }

    /// Draws the picture, `size` view points, into `context` from its origin, y up (a bitmap's or a
    /// PDF's as made, Quick Look's), in `appearance`'s colors: the canvas's dark ones in `.darkAqua`.
    public func draw(in context: CGContext, size: CGSize, appearance: NSAppearance) {
        editor.viewportDidResize(to: size)
        let bounds = self.bounds
        editor.camera = bounds.isNull ? Camera() : camera(fitting: bounds, in: size)
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
    /// 2× picture pastes at its size in points): as big as the board at `maxZoom` with its margin, or
    /// as close as fits within `limit` (`size(within:)`), in `appearance`'s colors. Nil for a board with
    /// nothing to show.
    public func pngData(within limit: CGSize, scale: CGFloat, appearance: NSAppearance) -> Data? {
        let size = size(within: limit)
        guard !isEmpty, let image = image(size: size, scale: scale, appearance: appearance) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        bitmap.size = size
        return bitmap.representation(using: .png, properties: [:])
    }

    private func camera(fitting bounds: CGRect, in size: CGSize) -> Camera {
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

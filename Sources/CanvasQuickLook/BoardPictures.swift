import AppKit
@_spi(Product) import Canvas
import CanvasUI
import ImageIO
import UniformTypeIdentifiers

/// Pictures of board files for Quick Look (`BoardPicture`), made on the main actor, as the editor's
/// drawing must be, and handed back as images, which Quick Look takes on whatever thread it asked on.
@MainActor
enum BoardPictures {
    /// The shipped plugins, as the app has them (the product's list, in this executable too, each
    /// made by its name), so a board looks as it does there. Nothing a picture draws asks the model,
    /// which in the extension's sandbox could read no key and reach no network, nor reads the
    /// pasteboard (only copying and pasting do).
    static let registry: Registry = {
        do {
            return try Registry(plugins: ShippedList.plugins())
        } catch {
            fatalError("The shipped plugins don't load or don't register: \(error)")   // CompositionTests catches this first
        }
    }()

    /// The preview of the board file at `url`: the whole board, no closer than 100%, in the system's
    /// appearance, at the deepest screen's pixels to a point.
    static func preview(of url: URL) throws -> Picture {
        let picture = try BoardPicture(data: Data(contentsOf: url), registry: registry)
        let size = picture.size(within: QuickLookStyle.previewLimit, minimum: QuickLookStyle.previewMinimum)
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? QuickLookStyle.previewScale
        return try Picture(picture, size: size, scale: scale, appearance: NSApplication.shared.effectiveAppearance)
    }

    /// The thumbnail of the board file at `url`, as big as fits `limit` (view points) and no smaller
    /// than `minimum` either way (a reply's context may not be: the board in its middle), `scale`
    /// pixels to a point: the whole board, as close as fits (to 800%), with a margin in proportion to
    /// the thumbnail, in the light appearance, whatever the system's, since a thumbnail is kept across
    /// a switch of it. An empty board has none.
    static func thumbnail(of url: URL, fitting limit: CGSize, atLeast minimum: CGSize, scale: CGFloat) throws -> Picture {
        let picture = try BoardPicture(data: Data(contentsOf: url), registry: registry)
        guard !picture.isEmpty else { throw QuickLookError.emptyBoard }
        picture.inset = min(limit.width, limit.height) * QuickLookStyle.thumbnailInset
        picture.maxZoom = .infinity
        return try Picture(picture, size: picture.size(within: limit, minimum: minimum), scale: scale, appearance: NSAppearance(named: .aqua)!)
    }
}

/// An image, and the size it's shown at, view points.
struct Picture: Sendable {
    let image: CGImage
    let size: CGSize

    @MainActor
    init(_ picture: BoardPicture, size: CGSize, scale: CGFloat, appearance: NSAppearance) throws {
        guard let image = picture.image(size: size, scale: scale, appearance: appearance) else { throw QuickLookError.noPixels }
        self.image = image
        self.size = size
    }

    /// Draws it filling the context, y up, as Quick Look's are: whatever its pixels to a point.
    func draw(in context: CGContext) {
        context.draw(image, in: context.boundingBoxOfClipPath)
    }

    /// It as a PNG that says how big it's shown (its pixels to an inch, 72 to a point): a preview's,
    /// since a context Quick Look makes for a reply has a pixel to a point.
    func png() throws -> Data {
        let data = NSMutableData()
        guard let png = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw QuickLookError.noPixels }
        let inch = 72 * CGFloat(image.width) / size.width
        CGImageDestinationAddImage(png, image, [kCGImagePropertyDPIWidth: inch, kCGImagePropertyDPIHeight: inch] as CFDictionary)
        guard CGImageDestinationFinalize(png) else { throw QuickLookError.noPixels }
        return data as Data
    }
}

enum QuickLookError: Error {
    /// A board with nothing on it: no thumbnail, so it shows the app's document icon.
    case emptyBoard
    /// A picture of no size, or one that wouldn't encode.
    case noPixels
}

@MainActor
enum QuickLookStyle {
    /// A preview's largest, view points: a board that doesn't fit this at 100% is drawn as close as fits.
    static let previewLimit = CGSize(width: 1600, height: 1200)
    /// A preview's smallest, a small window's worth of canvas: a board smaller than that is in its
    /// middle, rather than the panel shrinking around it.
    static let previewMinimum = CGSize(width: 480, height: 320)
    /// Pixels to a point when no screen says.
    static let previewScale: CGFloat = 2
    /// A thumbnail's margin around the board, in all, as a share of its shorter side.
    static let thumbnailInset: CGFloat = 0.125
}

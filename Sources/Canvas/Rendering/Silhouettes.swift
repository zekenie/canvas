import CoreGraphics

/// Shapes' rough silhouettes, gathered into one path to fill and one to stroke: a closed outline is
/// filled and an open one (an arrow, a line) stroked, a shape only a few pixels across is just its
/// bounds (a line from its first point to its last, if it's open), and every shape under a pixel
/// across is the pixel it's in, once however many share it. What a picture of a board draws, the
/// minimap's and a board's preview (`BoardPreviews`): from shapes' geometry alone, so a silhouette
/// costs the same for every kind, and shows none of what a shape draws (its text, its colors).
@_spi(Host) @MainActor
public final class Silhouettes {
    private struct Pixel: Hashable {
        let x: Int
        let y: Int
    }

    private let fills = CGMutablePath()
    private let lines = CGMutablePath()
    /// World units.
    private let pixel: CGFloat
    private let smallest: CGFloat
    private var pixels: Set<Pixel> = []

    public init(pixelsPerWorldUnit: CGFloat) {
        pixel = 1 / pixelsPerWorldUnit
        smallest = Style.detailedSilhouette / pixelsPerWorldUnit
    }

    public func add(_ geometry: ShapeGeometry) {
        let outline = geometry.outline, bounds = geometry.bounds
        guard let first = outline.first, let last = outline.last else { return }
        if bounds.width < pixel && bounds.height < pixel {
            pixels.insert(Pixel(x: Int((bounds.midX / pixel).rounded(.down)), y: Int((bounds.midY / pixel).rounded(.down))))
        } else if bounds.width < smallest && bounds.height < smallest {
            if geometry.isClosed {
                fills.addRect(bounds)
            } else {
                lines.move(to: first)
                lines.addLine(to: last)
            }
        } else if geometry.isClosed {
            // All one way round, as `addRect`'s are: filled together, outlines wound the other way
            // would cancel where they overlap.
            fills.addLines(between: Self.area(of: outline) < 0 ? outline.reversed() : outline)
            fills.closeSubpath()
        } else {
            lines.addLines(between: outline)
        }
    }

    /// Twice the polygon's signed area: positive when it winds as `addRect` does.
    private static func area(of outline: [CGPoint]) -> CGFloat {
        zip(outline, outline.dropFirst() + outline.prefix(1)).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }
    }

    /// Into a context in world units. `lineWidth` is in world units too.
    public func draw(into context: CGContext, color: CGColor, lineWidth: CGFloat) {
        for spot in pixels {
            fills.addRect(CGRect(x: CGFloat(spot.x) * pixel, y: CGFloat(spot.y) * pixel, width: pixel, height: pixel))
        }
        context.setFillColor(color)
        context.addPath(fills)
        context.fillPath()
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(lines)
        context.strokePath()
    }
}

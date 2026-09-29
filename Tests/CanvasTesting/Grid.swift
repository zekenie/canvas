import AppKit
import Geometry

/// The canvas's background and dot grid as they were drawn before the grid was drawn from tiles,
/// what the tiles are held to (CanvasTests' GridTests) and measured against (BenchmarkTests): the
/// background filled, then one path of an ellipse per dot, 2 points across, 24 world units apart,
/// the spacing doubling until the dots are 16 points apart on screen, filled, in the canvas's colors
/// (Style's, light or dark). `bounds` in view points, the context's current space.
@MainActor
public func drawGridAsEllipses(in context: CGContext, bounds: CGRect, camera: Camera, dark: Bool = false) {
    context.setFillColor((dark ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.965, alpha: 1)).cgColor)
    context.fill(bounds)
    let (start, step) = gridLattice(camera)
    var y = start.y
    while y < bounds.maxY + 2 {
        var x = start.x
        while x < bounds.maxX + 2 {
            context.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
            x += step
        }
        y += step
    }
    context.setFillColor((dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.16)).cgColor)
    context.fillPath()
}

/// Where the grid's first dot is for `camera`, view points, and how far apart its dots are.
public func gridLattice(_ camera: Camera) -> (start: CGPoint, step: CGFloat) {
    var spacing: CGFloat = 24
    while spacing * camera.zoom < 16 { spacing *= 2 }
    return (CGPoint(x: (floor(camera.origin.x / spacing) * spacing - camera.origin.x) * camera.zoom,
                    y: (floor(camera.origin.y / spacing) * spacing - camera.origin.y) * camera.zoom), spacing * camera.zoom)
}

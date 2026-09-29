import AppKit
import Geometry

/// The canvas's dot grid, drawn from tiles: a tile holds a block of dots, filled as ellipses once,
/// and copies of it are drawn at whole device pixels. Into a bitmap each is drawn through a clip of
/// just the pixels the dots touch, since a bitmap composites a copy's clear pixels as dearly as its
/// dots. Filling a path of an ellipse per dot, as the grid was drawn, costs some 2 µs a dot every
/// frame: 7 ms at 1200 × 800 on Retina where the dots are closest (70%, 35%), and more on a bigger
/// screen.
///
/// Into a context that isn't a bitmap (its `bitsPerComponent` is 0: AppKit's for a view's
/// `draw(_:)`, which records a display list, or a PDF's) the copies are drawn unclipped, and the
/// clip isn't made. Core Animation renders that list on the GPU while the window is on screen, and
/// makes a clip of many rects into a region again for every draw through it: the grid's clip, a
/// rect per dot (thousands), kept the main thread waiting some 400 ms a frame. Nothing but the cost
/// changes, since a tile is clear but for its dots and its copies never overlap.
///
/// Where a whole number of dots spans a whole number of pixels (at 100%, and at the zooms whose
/// spacing in pixels has few decimals: 60% on Retina is 57.6 pixels, five of them 288), every copy's
/// dots land exactly where the path's would, and are the path's pixel for pixel, but for a level
/// here and there where Core Graphics rounds a dot far from the context's origin differently from
/// the same dot near it (none at 100%, nor where the POC's goldens are). Elsewhere copies drift from
/// their dots, a little more each copy, so each copy is moved to the nearest `1 / Style.gridSubpixelSteps` of
/// a pixel from where its dots are, from a tile drawn that far over (one per step a frame's copies
/// need): no dot is more than an eighth of a pixel from where it is, and the dots stay put while the
/// camera pans and the same size at every zoom, as the path's did. The tiles are kept while the
/// dots' spacing, size and place within a pixel stay the same, so a frame the camera didn't move
/// makes none, and one it did makes a few (a pan's phase, a pinch's spacing).
@MainActor
final class DotGrid {
    /// One axis of the lattice, in device pixels: the first dot's center (the lowest coordinate),
    /// how far apart the dots are, how many, and a dot's radius.
    private struct Axis: Equatable {
        var first: CGFloat
        var period: CGFloat
        var count: Int
        var radius: CGFloat
    }

    /// A tile along one axis: how many dots it holds, where the first one's center is from its
    /// edge, how far apart and how big they are, and its size, in pixels.
    private struct Side: Equatable {
        var perTile: Int
        var phase: CGFloat
        var period: CGFloat
        var radius: CGFloat
        var length: Int

        /// The tile's `index`th dot's center, from its edge, in the tile drawn `variant` steps over.
        func center(_ index: Int, variant: Int) -> CGFloat {
            phase + CGFloat(index) * period + CGFloat(variant) / CGFloat(Style.gridSubpixelSteps)
        }
    }

    /// How an axis is tiled: `perTile` dots a tile, each copy the tile's size (to the nearest pixel)
    /// from the one before, moved a whole number of pixels more and drawn from the tile a number of
    /// steps over (its variant), so its dots stay within half a step of where they are.
    private struct Tiling {
        struct Copy {
            /// Its lowest pixel.
            var start: Int
            var variant: Int
        }

        let side: Side
        let copies: [Copy]
        let variants: Int

        init(_ axis: Axis, perTile: Int) {
            let steps = Style.gridSubpixelSteps
            let stride = max(1, Int((CGFloat(perTile) * axis.period).rounded()))
            // How far each copy's dots would fall behind where they are.
            let drift = CGFloat(perTile) * axis.period - CGFloat(stride)
            let origin = Int((axis.first - axis.radius).rounded(.down)) - 1
            let phase = axis.first - CGFloat(origin)
            side = Side(perTile: perTile, phase: phase, period: axis.period, radius: axis.radius,
                        length: Int((phase + CGFloat(perTile - 1) * axis.period + axis.radius).rounded(.up)) + 2)
            var variants = Set<Int>()
            copies = (0..<(axis.count + perTile - 1) / perTile).map { index in
                let nudge = Int((CGFloat(index) * drift * CGFloat(steps)).rounded())
                let whole = Int((CGFloat(nudge) / CGFloat(steps)).rounded(.down))
                variants.insert(nudge - whole * steps)
                return Copy(start: origin + index * stride + whole, variant: nudge - whole * steps)
            }
            self.variants = variants.count
        }

        /// The pixels each dot touches, as its copy draws it, those within `low..<high`: the only
        /// pixels of the copies drawn, into a bitmap. `count` of the copies' dots are the grid's, the
        /// rest past it.
        func spans(count: Int, within low: CGFloat, _ high: CGFloat) -> [ClosedRange<CGFloat>] {
            var spans: [ClosedRange<CGFloat>] = []
            for (index, copy) in copies.enumerated() {
                for dot in 0..<min(side.perTile, count - index * side.perTile) {
                    let center = CGFloat(copy.start) + side.center(dot, variant: copy.variant)
                    // A hair more than the dot, for the curves' bulge past the circle.
                    let span = (center - side.radius - 1 / 64).rounded(.down)...(center + side.radius + 1 / 64).rounded(.up)
                    if span.upperBound > low && span.lowerBound < high { spans.append(span) }
                }
            }
            return spans
        }
    }

    /// What the tiles kept are drawn for.
    private struct Key: Equatable {
        var x: Side
        var y: Side
        var color: CGColor
        var space: CGColorSpace
        var layout: CGBitmapInfo
    }

    /// The last frame's axes and how they were tiled: a frame the camera didn't move tiles them alike.
    private var plan: (x: Axis, y: Axis, across: Tiling, down: Tiling)?
    private var key: Key?
    /// By variant: `x * Style.gridSubpixelSteps + y`.
    private var tiles: [Int: CGImage] = [:]
    #if DEBUG
    /// How many tiles have been made (debug builds).
    private(set) var tilesMade = 0
    /// How many frames have drawn their copies through the clip, and how many without it (debug builds).
    private(set) var framesClipped = 0
    private(set) var framesUnclipped = 0
    /// Whether the copies are clipped whatever the context is: nil leaves it to the context (debug
    /// builds).
    var clipOverride: Bool?
    #endif

    /// Draws the grid for `camera` over `bounds`, view points, in `context`'s current space (the
    /// view's).
    func draw(in context: CGContext, bounds: CGRect, camera: Camera) {
        var spacing = Style.gridSpacing
        while spacing * camera.zoom < Style.minGridSpacingOnScreen {
            spacing *= 2
        }
        // Dots are placed in view space so they stay the same size at every zoom level.
        let step = spacing * camera.zoom
        // The first dot, within a step of the view's edge (even for an origin so far out it has no
        // fractions left); none for one that isn't a number.
        func first(_ origin: CGFloat) -> CGFloat {
            let offset = ((floor(origin / spacing) * spacing - origin) * camera.zoom).truncatingRemainder(dividingBy: step)
            return offset > 0 ? offset - step : offset
        }
        let start = CGPoint(x: first(camera.origin.x), y: first(camera.origin.y))
        guard start.x.isFinite, start.y.isFinite else { return }
        let diameter = Style.gridDotDiameter
        let columns = Int(((bounds.maxX + diameter - start.x) / step).rounded(.up))
        let rows = Int(((bounds.maxY + diameter - start.y) / step).rounded(.up))
        guard columns > 0, rows > 0 else { return }
        let color = Style.gridDot.cgColor
        let toDevice = context.userSpaceToDeviceSpaceTransform
        // Turned in the context, the pixels aren't in rows and columns of the grid's.
        guard toDevice.b == 0, toDevice.c == 0, toDevice.a != 0, toDevice.d != 0 else {
            return Self.fillEllipses(in: context, start: start, step: step, columns: columns, rows: rows, color: color)
        }
        func axis(_ start: CGFloat, _ count: Int, scale: CGFloat, offset: CGFloat) -> Axis {
            let ends = [start, start + CGFloat(count - 1) * step].map { $0 * scale + offset }
            return Axis(first: min(ends[0], ends[1]), period: step * abs(scale), count: count, radius: diameter / 2 * abs(scale))
        }
        let x = axis(start.x, columns, scale: toDevice.a, offset: toDevice.tx)
        let y = axis(start.y, rows, scale: toDevice.d, offset: toDevice.ty)
        let (across, down): (Tiling, Tiling)
        if let plan, plan.x == x, plan.y == y {
            (across, down) = (plan.across, plan.down)
        } else {
            (across, down) = Self.tilings(x, y)
            plan = (x, y, across, down)
        }
        // The context's space, unless it's one no 8-bit bitmap can be in (an extended range's).
        let space = context.colorSpace.flatMap { $0.model == .rgb && !CGColorSpaceUsesExtendedRange($0) ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let key = Key(x: across.side, y: down.side, color: color, space: space, layout: Self.layout(for: context))
        if key != self.key {
            self.key = key
            tiles = [:]
        }

        // Device pixels from here on, so a copy lands on whole ones and is drawn as it is, never resampled.
        let shown = context.boundingBoxOfClipPath.intersection(bounds)
        guard !shown.isNull else { return }
        let visible = shown.applying(toDevice)
        var copies: [(rect: CGRect, tile: CGImage)] = []
        for row in down.copies {
            for column in across.copies {
                let rect = CGRect(x: column.start, y: row.start, width: key.x.length, height: key.y.length)
                guard rect.intersects(visible) else { continue }
                let variant = column.variant * Style.gridSubpixelSteps + row.variant
                if let tile = tiles[variant] {
                    copies.append((rect, tile))
                    continue
                }
                guard let tile = Self.tile(column.variant, row.variant, for: key) else {
                    return Self.fillEllipses(in: context, start: start, step: step, columns: columns, rows: rows, color: color)
                }
                #if DEBUG
                tilesMade += 1
                #endif
                tiles[variant] = tile
                copies.append((rect, tile))
            }
        }
        guard !copies.isEmpty else { return }
        // The rects of the pixels the dots touch, only where they're the clip: not into a context that
        // isn't a bitmap, where they'd be made for nothing.
        let clips = clipsCopies(into: context)
        var dots: [CGRect] = []
        if clips {
            let xSpans = across.spans(count: x.count, within: visible.minX, visible.maxX)
            let ySpans = down.spans(count: y.count, within: visible.minY, visible.maxY)
            dots.reserveCapacity(xSpans.count * ySpans.count)
            for row in ySpans {
                for column in xSpans {
                    dots.append(CGRect(x: column.lowerBound, y: row.lowerBound, width: column.upperBound - column.lowerBound,
                                       height: row.upperBound - row.lowerBound))
                }
            }
            guard !dots.isEmpty else { return }
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.concatenate(toDevice.inverted())
        context.interpolationQuality = .none
        if clips { context.clip(to: dots) }
        for copy in copies {
            context.draw(copy.tile, in: copy.rect)
        }
        #if DEBUG
        if clips { framesClipped += 1 } else { framesUnclipped += 1 }
        #endif
    }

    /// Whether the copies are drawn through a clip of the pixels their dots touch: into a bitmap
    /// (whose `bitsPerComponent` is more than 0), not into any other context, unless a debug build
    /// says otherwise (`clipOverride`).
    private func clipsCopies(into context: CGContext) -> Bool {
        #if DEBUG
        if let clipOverride { return clipOverride }
        #endif
        return context.bitsPerComponent > 0
    }

    /// The tilings to draw with: of the sizes a tile may be, the pair whose tiles and copies cost the
    /// least to draw in a frame that makes its tiles afresh. Where a whole number of dots spans a
    /// whole number of pixels, a tile of that many (or a multiple) is the only one its copies need,
    /// so it's what's chosen wherever the copies it saves outweigh its dots.
    private static func tilings(_ x: Axis, _ y: Axis) -> (Tiling, Tiling) {
        func candidates(_ axis: Axis) -> [Tiling] {
            let most = min(Style.gridMostDotsPerSide, axis.count, max(1, Int(Style.gridLargestTile / axis.period)))
            return (1...most).map { Tiling(axis, perTile: $0) }
        }
        let columns = candidates(x), rows = candidates(y)
        var best = (cost: Double.infinity, x: columns[0], y: rows[0])
        for column in columns {
            for row in rows {
                let tile = Style.gridDotCost * Double(column.side.perTile * row.side.perTile)
                    + Style.gridTilePixelCost * Double(column.side.length * row.side.length)
                let cost = Double(column.variants * row.variants) * tile + Style.gridCopyCost * Double(column.copies.count * row.copies.count)
                if cost < best.cost { best = (cost, column, row) }
            }
        }
        return (best.x, best.y)
    }

    /// The tiles' layout: the context's, when it's premultiplied 8-bit color (drawing a tile of
    /// another layout converts every pixel it reads, a copy's and, when it's made, the whole tile's:
    /// twice the work into RGBA), else premultiplied BGRA, Core Graphics' own.
    private static func layout(for context: CGContext) -> CGBitmapInfo {
        let alpha = CGImageAlphaInfo(rawValue: context.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
        guard context.bitsPerComponent == 8, context.bitsPerPixel == 32, alpha == .premultipliedFirst || alpha == .premultipliedLast
        else { return CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) }
        return context.bitmapInfo
    }

    /// The tile of `key`'s dots drawn `x` and `y` steps over, in the space and layout it's drawn
    /// into, so drawing it converts nothing.
    private static func tile(_ x: Int, _ y: Int, for key: Key) -> CGImage? {
        guard let tile = CGContext(data: nil, width: key.x.length, height: key.y.length, bitsPerComponent: 8, bytesPerRow: 0, space: key.space,
                                   bitmapInfo: key.layout.rawValue)
        else { return nil }
        for row in 0..<key.y.perTile {
            for column in 0..<key.x.perTile {
                let center = CGPoint(x: key.x.center(column, variant: x), y: key.y.center(row, variant: y))
                tile.addEllipse(in: CGRect(x: center.x - key.x.radius, y: center.y - key.y.radius,
                                           width: 2 * key.x.radius, height: 2 * key.y.radius))
            }
        }
        tile.setFillColor(key.color)
        tile.fillPath()
        return tile.makeImage()
    }

    /// The grid as one path of an ellipse per dot, in view space.
    private static func fillEllipses(in context: CGContext, start: CGPoint, step: CGFloat, columns: Int, rows: Int, color: CGColor) {
        let radius = Style.gridDotDiameter / 2
        for row in 0..<rows {
            for column in 0..<columns {
                let center = CGPoint(x: start.x + CGFloat(column) * step, y: start.y + CGFloat(row) * step)
                context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            }
        }
        context.setFillColor(color)
        context.fillPath()
    }
}

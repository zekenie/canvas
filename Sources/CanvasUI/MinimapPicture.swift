import AppKit
@_spi(Host) import Canvas

/// The board as the minimap shows it, kept from one frame to the next: every shape as a rough
/// silhouette (its outline filled, or stroked when it's open; its bounds when it's only a few
/// pixels; one pixel for all those under a pixel there), all in one color, in a bitmap of a world
/// rect (`frame`) at `scale` pixels per world unit. Nothing of what a shape draws on the canvas (its
/// text, its colors), so a silhouette costs the same for every kind, and the outlines come from the
/// editor, which keeps them.
///
/// The bitmap is a grid of tiles. Where the board changed (`editor.damage(since:)`), tiles go stale,
/// and each frame draws again the ones stale longest, as many as fit in its budget; the rest wait. So
/// dragging a shape redraws the few tiles around it, a board of any size fills in over a few frames
/// instead of holding one up, and however much changes each frame, what's waiting never outgrows the
/// grid and every tile has its turn.
@MainActor
final class MinimapPicture {
    /// World units. Its corners fall on whole pixels, so a tile drawn again lines up with the rest.
    let frame: CGRect
    /// Pixels per world unit.
    let scale: CGFloat
    /// Pixels per minimap point, with the board filling the minimap: what open shapes' lines are
    /// sized by.
    private let pixelsPerPoint: CGFloat
    /// Pixels, y up, with no transform: each tile sets up its own.
    private let bitmap: CGContext
    /// The editor's damage mark when the picture last took in the board's changes: the board's, while
    /// it's current (`editor.isCurrent`).
    private(set) var mark: DamageMark
    private let columns: Int
    private let rows: Int
    /// For each tile, row by row from the frame's top-left: when it went stale (the catch-up that
    /// found it so), or 0 while it's up to date.
    private var staleSince: [Int]
    private var staleTiles: Int
    private var catchUps = 1

    var isComplete: Bool { staleTiles == 0 }
    var image: CGImage? { bitmap.makeImage() }

    /// A picture of `board` (the editor's `shapeBounds`), all of it still to draw. Until it's drawn,
    /// it shows `seed` (the picture it replaces), so the minimap never goes blank.
    init?(of board: CGRect, scale: CGFloat, pixelsPerPoint: CGFloat, editor: CanvasEditor, seed: MinimapPicture? = nil) {
        guard let bitmap = Self.bitmap(for: Self.frame(covering: board, scale: scale), scale: scale) else { return nil }
        frame = Self.frame(covering: board, scale: scale)
        self.scale = scale
        self.pixelsPerPoint = pixelsPerPoint
        self.bitmap = bitmap
        mark = editor.damageMark
        (columns, rows) = Self.tiles(bitmap)
        staleSince = Array(repeating: 1, count: columns * rows)
        staleTiles = staleSince.count
        if let seed { copy(seed) }
    }

    /// `old`, over a frame that also covers `board`, at `scale` (its own, or smaller): its pixels are
    /// copied (and scaled), not drawn again, and what it had still to draw goes stale here. Nil when
    /// that frame would be too big a bitmap.
    init?(from old: MinimapPicture, covering board: CGRect, scale: CGFloat) {
        let frame = Self.frame(covering: board.union(old.frame), scale: scale)
        guard let bitmap = Self.bitmap(for: frame, scale: scale) else { return nil }
        self.frame = frame
        self.scale = scale
        pixelsPerPoint = old.pixelsPerPoint * scale / old.scale
        self.bitmap = bitmap
        mark = old.mark
        (columns, rows) = Self.tiles(bitmap)
        staleSince = Array(repeating: 0, count: columns * rows)
        staleTiles = 0
        guard copy(old) else {
            invalidate()
            return
        }
        for tile in old.staleSince.indices where old.staleSince[tile] != 0 { makeStale(old.rect(of: tile)) }
    }

    private static func bitmap(for frame: CGRect, scale: CGFloat) -> CGContext? {
        let width = Int((frame.width * scale).rounded()), height = Int((frame.height * scale).rounded())
        guard width > 0, height > 0, width <= MinimapStyle.largestPicture, height <= MinimapStyle.largestPicture else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func tiles(_ bitmap: CGContext) -> (columns: Int, rows: Int) {
        let tile = MinimapStyle.tile
        return ((bitmap.width + tile - 1) / tile, (bitmap.height + tile - 1) / tile)
    }

    /// `board` with room to grow, on a grid of a few pixels, so the frame changes only now and then as
    /// the board grows.
    private static func frame(covering board: CGRect, scale: CGFloat) -> CGRect {
        let cell = MinimapStyle.pictureGrid / scale
        let room = board.insetBy(dx: -board.width * MinimapStyle.pictureRoom - cell, dy: -board.height * MinimapStyle.pictureRoom - cell)
        let minX = (room.minX / cell).rounded(.down) * cell, minY = (room.minY / cell).rounded(.down) * cell
        let maxX = (room.maxX / cell).rounded(.up) * cell, maxY = (room.maxY / cell).rounded(.up) * cell
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Draws `other`'s pixels where its frame is in this one. Returns false if it has none.
    @discardableResult
    private func copy(_ other: MinimapPicture) -> Bool {
        guard let image = other.image else { return false }
        bitmap.interpolationQuality = .high
        bitmap.draw(image, in: pixels(other.frame))
        return true
    }

    /// How far past its shape's extent a silhouette draws, in world units: half an open shape's line,
    /// and a pixel of antialiasing.
    private var reach: CGFloat { (MinimapStyle.lineWidth * pixelsPerPoint / 2 + 1) / scale }

    /// Whether `board`, with the reach of its silhouettes, is all in the frame.
    func covers(_ board: CGRect) -> Bool { frame.contains(board.insetBy(dx: -reach, dy: -reach)) }

    /// Takes in where the board changed since last time: the tiles there go stale.
    func catchUp(with editor: CanvasEditor) {
        let damage = editor.damage(since: mark)
        mark = editor.damageMark
        catchUps += 1
        if damage.isInfinite {
            invalidate()
        } else if !damage.isNull {
            makeStale(damage.insetBy(dx: -reach, dy: -reach))
        }
    }

    /// Every tile goes stale (the appearance changed).
    func invalidate() { makeStale(frame) }

    private func makeStale(_ world: CGRect) {
        let area = world.intersection(frame)
        guard !area.isEmpty else { return }
        let tile = CGFloat(MinimapStyle.tile)
        let left = Int(((area.minX - frame.minX) * scale / tile).rounded(.down)), right = Int(((area.maxX - frame.minX) * scale / tile).rounded(.up))
        let top = Int(((area.minY - frame.minY) * scale / tile).rounded(.down)), bottom = Int(((area.maxY - frame.minY) * scale / tile).rounded(.up))
        for row in max(top, 0)..<min(bottom, rows) {
            for column in max(left, 0)..<min(right, columns) where staleSince[row * columns + column] == 0 {
                staleSince[row * columns + column] = catchUps
                staleTiles += 1
            }
        }
    }

    /// A tile's world rect.
    private func rect(of tile: Int) -> CGRect {
        let side = CGFloat(MinimapStyle.tile) / scale
        let column = CGFloat(tile % columns), row = CGFloat(tile / columns)
        return CGRect(x: frame.minX + column * side, y: frame.minY + row * side, width: side, height: side).intersection(frame)
    }

    /// Draws the stale tiles again, those stale longest first, until `deadline`: each run of stale
    /// tiles side by side in a row at once, halved while its shapes would take longer than what's
    /// left (at `costPerShape` seconds a shape, which each run drawn refines). A frame draws a tile at
    /// least, whatever it costs; the rest wait for the next. `color` is the silhouettes'.
    func draw(_ editor: CanvasEditor, color: CGColor, until deadline: ContinuousClock.Instant, costPerShape: inout Double) {
        guard staleTiles > 0 else { return }
        let clock = ContinuousClock()
        let order = staleSince.indices.filter { staleSince[$0] != 0 }.sorted { (staleSince[$0], $0) < (staleSince[$1], $1) }
        var next = 0, drawn = false
        // Past the deadline, what's left of a frame is known without asking the board for a run's
        // shapes (which goes through every shape): a tile if none is drawn yet, else nothing.
        while next < order.count, !drawn || clock.now < deadline {
            let first = order[next]
            var count = 1
            while next + count < order.count, order[next + count] == first + count, (first + count) % columns != 0,
                  staleSince[first + count] == staleSince[first] {
                count += 1
            }
            var run = rect(of: first).union(rect(of: first + count - 1))
            var shapes = editor.paintOrder(in: run.insetBy(dx: -reach, dy: -reach))
            while count > 1, Double(shapes.count) * costPerShape > (deadline - clock.now).seconds {
                count = clock.now < deadline ? (count + 1) / 2 : 1
                run = rect(of: first).union(rect(of: first + count - 1))
                shapes = editor.paintOrder(in: run.insetBy(dx: -reach, dy: -reach))
            }
            if drawn, Double(shapes.count) * costPerShape > (deadline - clock.now).seconds { break }
            let start = clock.now
            draw(shapes, in: run, color: color, editor: editor)
            if !shapes.isEmpty {
                costPerShape += ((clock.now - start).seconds / Double(shapes.count) - costPerShape) * MinimapStyle.costLearning
            }
            for tile in first..<first + count {
                staleSince[tile] = 0
            }
            staleTiles -= count
            next += count
            drawn = true
        }
    }

    /// Clears `region` and draws the silhouettes of `shapes` (those that reach it) there.
    private func draw(_ shapes: [AnyShapeRecord], in region: CGRect, color: CGColor, editor: CanvasEditor) {
        let silhouettes = Silhouettes(pixelsPerWorldUnit: scale)
        let context = editor.shapeContext
        for record in shapes {
            if let geometry = context.geometry(of: record.id) { silhouettes.add(geometry, hollow: editor.registry.isContainer(record)) }
        }
        bitmap.saveGState()
        defer { bitmap.restoreGState() }
        // World units, y down, as the canvas draws; the frame's top-left is the bitmap's.
        bitmap.translateBy(x: 0, y: CGFloat(bitmap.height))
        bitmap.scaleBy(x: scale, y: -scale)
        bitmap.translateBy(x: -frame.minX, y: -frame.minY)
        bitmap.clip(to: region)
        bitmap.clear(region)
        silhouettes.draw(into: bitmap, color: color, lineWidth: MinimapStyle.lineWidth * pixelsPerPoint / scale)
    }

    /// Where a world rect is in the bitmap's pixels, y up.
    private func pixels(_ world: CGRect) -> CGRect {
        CGRect(x: (world.minX - frame.minX) * scale, y: CGFloat(bitmap.height) - (world.maxY - frame.minY) * scale,
               width: world.width * scale, height: world.height * scale)
    }
}

extension Duration {
    fileprivate var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

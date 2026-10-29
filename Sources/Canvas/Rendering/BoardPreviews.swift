import CoreGraphics

/// Rough pictures of boards not shown, for their owners to draw on the board that is
/// (`RenderContext.drawBoardPreview`): each shape of the board as a silhouette of its geometry
/// (`Silhouettes`), all in one color, fitted into a bitmap at most `Style.previewSide` pixels on a
/// side, and kept as paths too, for an owner shown larger than that. Nothing of what a shape draws
/// (its text, its colors), so a preview costs the same for every kind, and a shape on it that owns
/// a board of its own is just its outline.
///
/// A preview is of a board as one revision of the file had it (`CanvasFile.revision(of:)`): asked
/// for once the board has changed (an edit, an undo), it's dropped, never drawn, and built again.
/// Built ones are kept, up to `capacity`, the one drawn longest ago going first. A board asked for
/// that has none waits its turn: each frame builds, for as long as its budget, those asked for
/// longest ago first, a chunk of shapes at a time (as the minimap's picture draws its tiles), so ten
/// boards of 10,000 shapes in view fill in over a few frames instead of holding one up. The editor
/// keeps one (`editor.boardPreviews`), builds it at the start of each frame, ends the frame once its
/// shapes have drawn (`endFrame()`), and asks for the next while any wait.
///
/// What a frame drew stays: none it drew is evicted for one built in the next. So with more
/// previews in view than are kept, those past the number show without theirs, instead of each
/// frame building one by evicting another, and asking for another frame, forever.
@_spi(Host) @MainActor
public final class BoardPreviews {
    /// Which board, as which revision had it.
    public struct Key: Hashable, Sendable {
        public let board: BoardID
        public let revision: Int
        public init(board: BoardID, revision: Int) {
            self.board = board
            self.revision = revision
        }
    }

    /// A board's picture, built.
    public struct Preview {
        public let key: Key
        /// World units, the board's own: what the mask shows, its shapes' bounds with a little room.
        public let frame: CGRect
        /// An image mask (`CGImage(maskWidth:…)`, drawn in the fill color), its samples 255 where a
        /// silhouette is and 0 elsewhere. Nil when none of the board's shapes has an outline
        /// (nothing to show).
        public let mask: CGImage?
        /// The silhouettes again as paths, every shape its outline, in cells of a grid over the
        /// board: what's drawn where the mask would be enlarged, sharp at any size, the cells in view.
        let cells: [PathCell]

        /// Draws the silhouettes in `color` into `rect` (in the context's units, y down, as a render's),
        /// fitted: the board's proportions kept, centered, at no more than `maxScale` of the context's
        /// units to a world unit of the board. Where the mask would be drawn larger than its pixels,
        /// the shapes in view are drawn as paths instead, their lines `Style.previewLineWidth` device
        /// pixels wide as the mask's are its pixels, as long as they number no more than `pathShapes`
        /// (which is lessened by them); else, or with more, the mask. False, and nothing drawn, with
        /// nothing to show.
        @discardableResult @MainActor
        public func draw(in cg: CGContext, fitting rect: CGRect, maxScale: CGFloat = .infinity, color: CGColor, pathShapes: inout Int) -> Bool {
            guard let mask, frame.width > 0, frame.height > 0, rect.width > 0, rect.height > 0, maxScale > 0 else { return false }
            let scale = min(rect.width / frame.width, rect.height / frame.height, maxScale)
            let width = frame.width * scale, height = frame.height * scale
            let target = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
            let device = cg.userSpaceToDeviceSpaceTransform, pixelsPerUnit = max(hypot(device.a, device.b), hypot(device.c, device.d))
            if width * pixelsPerUnit > CGFloat(mask.width) || height * pixelsPerUnit > CGFloat(mask.height),
               drawPaths(in: cg, target: target, scale: scale, lineWidth: Style.previewLineWidth / pixelsPerUnit, color: color, shapes: &pathShapes) {
                return true
            }
            cg.saveGState()
            defer { cg.restoreGState() }
            // The mask's rows go up; the context's go down.
            cg.translateBy(x: 0, y: target.minY + target.maxY)
            cg.scaleBy(x: 1, y: -1)
            cg.interpolationQuality = .high
            cg.setFillColor(color)
            // A mask is drawn in the fill color: a clip to it would cost a mask the size of the context.
            cg.draw(mask, in: target)
            return true
        }

        /// Draws the silhouettes in `color` into `rect`, as `draw(in:fitting:maxScale:color:pathShapes:)`
        /// does with no limit on the shapes drawn as paths.
        @discardableResult @MainActor
        public func draw(in cg: CGContext, fitting rect: CGRect, maxScale: CGFloat = .infinity, color: CGColor) -> Bool {
            var unlimited = Int.max
            return draw(in: cg, fitting: rect, maxScale: maxScale, color: color, pathShapes: &unlimited)
        }

        /// The cells in view (the context's clip) as paths, the board's `frame` into `target`, `scale`
        /// context units to a world unit; `lineWidth` in context units. False, and nothing drawn, when
        /// they hold more shapes than `shapes`.
        private func drawPaths(in cg: CGContext, target: CGRect, scale: CGFloat, lineWidth: CGFloat, color: CGColor, shapes: inout Int) -> Bool {
            let shown = cg.boundingBoxOfClipPath.intersection(target)
            guard !shown.isNull, !shown.isEmpty else { return true }
            let reach = lineWidth / scale
            let seen = CGRect(x: frame.minX + (shown.minX - target.minX) / scale, y: frame.minY + (shown.minY - target.minY) / scale,
                              width: shown.width / scale, height: shown.height / scale).insetBy(dx: -reach, dy: -reach)
            let inView = cells.filter { $0.bounds.intersects(seen) }
            let count = inView.reduce(0) { $0 + $1.count }
            guard count <= shapes else { return false }
            shapes -= count
            cg.saveGState()
            defer { cg.restoreGState() }
            cg.translateBy(x: target.minX, y: target.minY)
            cg.scaleBy(x: scale, y: scale)
            cg.translateBy(x: -frame.minX, y: -frame.minY)
            // All the cells' fills in one, then their lines: one fill and one stroke, as the mask's are.
            for cell in inView { cg.addPath(cell.fills) }
            cg.setFillColor(color)
            cg.fillPath()
            for cell in inView { cg.addPath(cell.lines) }
            cg.setStrokeColor(color)
            cg.setLineWidth(reach)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.strokePath()
            return true
        }
    }

    /// The paths of the shapes whose middles are in one cell of a preview's grid, in the board's
    /// world units: what's filled and what's stroked (`Silhouettes.paths`), and their bounds.
    struct PathCell {
        let bounds: CGRect
        let fills: CGPath
        let lines: CGPath
        let count: Int
    }

    public let registry: Registry
    /// How many previews are kept.
    public let capacity: Int
    /// How long building may take in a frame (`build(in:until:)`'s deadline, from the editor).
    public var frameBudget: Duration
    /// How many shapes a frame draws as paths (`draw(_:in:fitting:maxScale:color:)`), over all the
    /// previews it draws larger than their masks: 1,000 (`Style.previewPathShapes`), unless set.
    public var pathShapes = Style.previewPathShapes {
        didSet { pathShapesLeft = pathShapes }
    }
    /// What's left of it in the frame being drawn.
    private var pathShapesLeft = Style.previewPathShapes

    /// By board: a board is kept as one revision at most. `used` orders them by when they were last
    /// drawn; `frame` is the frame that was (-1 for none yet).
    private var kept: [BoardID: (preview: Preview, used: Int, frame: Int)] = [:]
    private var uses = 0
    /// Boards asked for with none built, the one asked for longest ago first; by board, and the
    /// frame each was last asked for in.
    private var queue: [Build] = []
    private var queued: [BoardID: Key] = [:]
    private var asked: [BoardID: Int] = [:]
    /// The frame being drawn, and the one before it (none until a frame ends).
    private var frame = 0
    private var lastFrame: Int?
    /// Seconds a shape costs each phase of a build, on average, as builds measure it.
    private var costs = [Style.initialPreviewCost, Style.initialPreviewCost]

    /// `capacity` and `frameBudget` default to the editor's (64 previews, 2 ms).
    public init(registry: Registry, capacity: Int? = nil, frameBudget: Duration? = nil) {
        self.registry = registry
        self.capacity = capacity ?? Style.keptPreviews
        self.frameBudget = frameBudget ?? Style.previewFrameBudget
    }

    /// The board's preview as `file` has it now, if it's built; else nil, and it's asked for (unless
    /// it's empty: an empty board has none). One built of an earlier revision is dropped.
    public func preview(of board: BoardID, in file: CanvasFile) -> Preview? {
        let document = file[board]
        guard !document.shapes.isEmpty else {
            forget(board)
            return nil
        }
        let key = Key(board: board, revision: file.revision(of: board))
        if let entry = kept[board] {
            if entry.preview.key == key {
                uses += 1
                kept[board]?.used = uses
                kept[board]?.frame = frame
                return entry.preview
            }
            kept[board] = nil
        }
        if queued[board] != key {
            queue.removeAll { $0.key.board == board }
            queue.append(Build(key: key, document: document, registry: registry))
            queued[board] = key
        }
        asked[board] = frame
        return nil
    }

    /// Ends the frame being drawn: of the boards waiting, only those asked for in it go on waiting
    /// (a board that's no longer drawn, scrolled away or on a board left, is asked for again if it
    /// comes back), and only as many as there's room kept for beside the previews it drew, the ones
    /// asked for first. The next frame's builds evict none of those it drew.
    public func endFrame() {
        let drawn = kept.values.count { $0.frame == frame }
        var room = max(capacity - drawn, 0)
        var waiting: [Build] = []
        for build in queue {
            let board = build.key.board
            if asked[board] == frame, room > 0 {
                waiting.append(build)
                room -= 1
            } else {
                queued[board] = nil
                asked[board] = nil
            }
        }
        queue = waiting
        lastFrame = frame
        frame += 1
        pathShapesLeft = pathShapes
    }

    /// Draws a preview in the frame being drawn (`Preview.draw(in:fitting:maxScale:color:pathShapes:)`),
    /// its shapes drawn as paths out of what's left of the frame's `pathShapes`.
    @discardableResult
    public func draw(_ preview: Preview, in cg: CGContext, fitting rect: CGRect, maxScale: CGFloat = .infinity, color: CGColor) -> Bool {
        preview.draw(in: cg, fitting: rect, maxScale: maxScale, color: color, pathShapes: &pathShapesLeft)
    }

    /// Stops building what's waiting, as when another board is shown: what's drawn next asks again.
    public func stopWaiting() {
        queue = []
        queued = [:]
        asked = [:]
    }

    /// Whether any board asked for waits for its preview.
    public var isPending: Bool { !queue.isEmpty }
    /// The boards waiting, the one asked for longest ago first.
    public var waiting: [Key] { queue.map(\.key) }
    /// The previews kept, the one drawn longest ago first.
    public var keptKeys: [Key] { kept.values.sorted { $0.used < $1.used }.map(\.preview.key) }

    /// Builds the previews waiting, the one asked for longest ago first, a chunk of shapes at a
    /// time, until `deadline`: at least a chunk (`Style.previewChunks`' smallest) whatever the time,
    /// and then as many shapes as fit what's left, at what shapes have cost so far. One whose board
    /// `file` no longer has as it was asked for is dropped unbuilt. Returns whether any finished.
    @discardableResult
    public func build(in file: CanvasFile, until deadline: ContinuousClock.Instant) -> Bool {
        let clock = ContinuousClock()
        var finished = false, stepped = false
        while let build = queue.first {
            guard file.revision(of: build.key.board) == build.key.revision else {
                dequeue()
                continue
            }
            let left = max((deadline - clock.now).seconds, 0), phase = build.phase
            var count = Int(min(left / costs[phase], Double(Style.previewChunks.upperBound)))
            if !stepped {
                count = max(count, Style.previewChunks.lowerBound)
            } else if count < Style.previewChunks.lowerBound {
                break
            }
            let start = clock.now
            let built = build.step(count)
            if built > 0 {
                costs[phase] += ((clock.now - start).seconds / Double(built) - costs[phase]) * Style.previewCostLearning
            }
            stepped = true
            guard let preview = build.preview else { continue }
            dequeue()
            keep(preview)
            finished = true
        }
        return finished
    }

    private func dequeue() {
        let build = queue.removeFirst()
        queued[build.key.board] = nil
        asked[build.key.board] = nil
    }

    /// Keeps a preview built, making room by evicting the one drawn longest ago, never one the
    /// frame before drew (`endFrame` leaves room for what waits).
    private func keep(_ preview: Preview) {
        uses += 1
        kept[preview.key.board] = (preview, uses, -1)
        if kept.count > capacity,
           let oldest = kept.filter({ $0.value.frame != lastFrame }).min(by: { $0.value.used < $1.value.used })?.key {
            kept[oldest] = nil
        }
    }

    private func forget(_ board: BoardID) {
        kept[board] = nil
        asked[board] = nil
        if queued.removeValue(forKey: board) != nil { queue.removeAll { $0.key.board == board } }
    }
}

/// One preview being built, in two phases: every shape's geometry (and so the board's bounds, which
/// size the bitmap and the grid), then the silhouettes, drawn into the bitmap and gathered into
/// their cells' paths a chunk at a time.
@MainActor
private final class Build {
    let key: BoardPreviews.Key
    private let shapes: ShapeStack
    private let context: ShapeContext
    private var next = 0
    private var geometries: [ShapeGeometry] = []
    /// Which of `geometries` are containers' (a frame's), drawn hollow, so what they hold shows.
    private var hollow: [Bool] = []
    private var bounds = CGRect.null
    private var bitmap: CGContext?
    private var frame = CGRect.null
    /// Pixels per world unit.
    private var scale: CGFloat = 1
    /// The grid's cells a side, and each one's paths, by row and column from the bounds' top-left
    /// (those with shapes in them), with their shapes' bounds and how many.
    private var across = 1
    private var cells: [Int: (paths: Silhouettes, bounds: CGRect, count: Int)] = [:]
    /// Once it's done.
    private(set) var preview: BoardPreviews.Preview?

    init(key: BoardPreviews.Key, document: CanvasDocument, registry: Registry) {
        self.key = key
        shapes = document.shapes
        // No index: a board not shown has none, and its shapes' geometry is worked out once each.
        context = ShapeContext(document: document, registry: registry)
    }

    /// 0 while measuring the shapes, 1 while drawing them.
    var phase: Int { bitmap == nil ? 0 : 1 }

    /// Measures or draws up to `count` shapes, never past the end of the phase. Returns how many.
    func step(_ count: Int) -> Int {
        guard preview == nil else { return 0 }
        let start = next
        if let bitmap {
            let end = min(start + count, geometries.count)
            let silhouettes = Silhouettes(pixelsPerWorldUnit: scale)
            for i in start..<end {
                silhouettes.add(geometries[i], hollow: hollow[i])
                gather(geometries[i], hollow: hollow[i])
            }
            silhouettes.draw(into: bitmap, color: CGColor(gray: 1, alpha: 1), lineWidth: Style.previewLineWidth / scale)
            next = end
            if end == geometries.count { finish(Self.mask(of: bitmap)) }
            return end - start
        }
        let end = min(start + count, shapes.count)
        for record in shapes[start..<end] where !record.isOpaque {
            guard let geometry = context.geometry(of: record.id), !geometry.outline.isEmpty else { continue }
            geometries.append(geometry)
            hollow.append(context.registry.isContainer(record))
            bounds = bounds.union(geometry.bounds)
        }
        next = end
        if end == shapes.count { startDrawing() }
        return end - start
    }

    /// Sizes the bitmap to the bounds: the longest side `Style.previewSide` pixels, less a margin for
    /// open shapes' lines and antialiasing.
    private func startDrawing() {
        guard !geometries.isEmpty, !bounds.isNull else { return finish(nil) }
        let margin = (Style.previewLineWidth / 2 + 1).rounded(.up)
        scale = (Style.previewSide - margin * 2) / max(bounds.width, bounds.height, 1)
        let width = Int((bounds.width * scale + margin * 2).rounded(.up)), height = Int((bounds.height * scale + margin * 2).rounded(.up))
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return finish(nil) }
        frame = CGRect(x: bounds.minX - margin / scale, y: bounds.minY - margin / scale, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        bitmap.setFillColor(gray: 0, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // World units, y down, as the canvas draws; the frame's top-left is the bitmap's.
        bitmap.translateBy(x: 0, y: CGFloat(height))
        bitmap.scaleBy(x: scale, y: -scale)
        bitmap.translateBy(x: -frame.minX, y: -frame.minY)
        self.bitmap = bitmap
        let wanted = (Double(geometries.count) / Double(Style.previewCellShapes)).squareRoot().rounded(.up)
        across = min(max(Int(wanted), 1), Style.previewCellsAcross)
        next = 0
    }

    /// Adds a shape to the paths of the cell its middle is in: its outline, whatever its size.
    private func gather(_ geometry: ShapeGeometry, hollow: Bool) {
        let bounds = geometry.bounds
        let column = cell(bounds.midX, from: self.bounds.minX, across: self.bounds.width)
        let row = cell(bounds.midY, from: self.bounds.minY, across: self.bounds.height)
        let index = row * across + column
        // Outlines at any size: with no pixel to fall under, no shape is its bounds or its pixel.
        let paths = cells[index]?.paths ?? Silhouettes(pixelsPerWorldUnit: .infinity)
        paths.add(geometry, hollow: hollow)
        cells[index] = (paths, bounds.union(cells[index]?.bounds ?? .null), (cells[index]?.count ?? 0) + 1)
    }

    private func cell(_ value: CGFloat, from start: CGFloat, across length: CGFloat) -> Int {
        guard length > 0 else { return 0 }
        return min(max(Int(((value - start) / length * CGFloat(across)).rounded(.down)), 0), across - 1)
    }

    /// The bitmap's pixels as an image mask: painted where they're white.
    private static func mask(of bitmap: CGContext) -> CGImage? {
        guard let image = bitmap.makeImage(), let pixels = image.dataProvider else { return nil }
        return CGImage(maskWidth: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: image.bytesPerRow,
                       provider: pixels, decode: [1, 0], shouldInterpolate: true)
    }

    private func finish(_ mask: CGImage?) {
        let cells: [BoardPreviews.PathCell] = mask == nil ? [] : self.cells.keys.sorted().compactMap { index in
            self.cells[index].map { cell in
                let paths = cell.paths.paths
                return BoardPreviews.PathCell(bounds: cell.bounds, fills: paths.fills, lines: paths.lines, count: cell.count)
            }
        }
        preview = BoardPreviews.Preview(key: key, frame: mask == nil ? .null : frame, mask: mask, cells: cells)
        geometries = []
        hollow = []
        self.cells = [:]
    }
}

extension Duration {
    fileprivate var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

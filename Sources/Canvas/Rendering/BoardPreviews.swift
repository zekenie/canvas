import AppKit
import Palette

/// Rough pictures of boards not shown, for their owners to draw on the board that is
/// (`RenderContext.drawBoardPreview`): each shape of the board as a silhouette of its geometry
/// (`Silhouettes`) in the color it's listed in (`tint`: the editor's `tint(of:)`, its own color, the
/// one it's given, else its kind's), quieted toward the muted gray a shape with none is drawn in
/// (`muting`, `Style.boardPreview`), painted in
/// the board's order a run of one color at a time, so what's in front stays in front; fitted into a
/// picture at most `Style.previewSide` pixels on a side, and kept as paths too, for an owner shown
/// larger than that. Nothing else of what a shape draws (its text, its fills' roles, its shadow), so a
/// preview costs the same for every kind, and a shape on it that owns a board of its own is just its
/// silhouette.
///
/// A preview is of a board as one revision of the file had it (`CanvasFile.revision(of:)`): asked
/// for once the board has changed (an edit, an undo), it's dropped, never drawn, and built again.
/// Its colors are of the appearance it was built in and the tints as they were then (`Look`): asked
/// for in another appearance, or after tints changed with no commit to the board (`tintsDidChange()`:
/// the file's colors, the color a type gives its shapes), it's drawn as it is while it's built again,
/// so its owner never goes back to showing none.
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

    /// What a preview's colors are of: the appearance it was built in (`NSAppearance.currentDrawing()`
    /// as it was asked for), and how many times shapes' tints had changed with no commit to say so
    /// (`tintsDidChange()`).
    public struct Look: Equatable {
        public let appearance: NSAppearance.Name
        public let tints: Int
    }

    /// A board's picture, built.
    public struct Preview {
        public let key: Key
        /// What its colors are of: asked for in another look, it's drawn while it's built again.
        public let look: Look
        /// World units, the board's own: what the picture shows, its shapes' bounds with a little room.
        public let frame: CGRect
        /// The silhouettes in their colors on a clear ground (premultiplied sRGB, its rows going up, as a
        /// bitmap's). Nil when none of the board's shapes has an outline (nothing to show).
        public let image: CGImage?
        /// The colors the shapes are drawn in, each once, as the picture has them: what the paths' runs name.
        let colors: [CGColor]
        /// The silhouettes again as paths, every shape its outline, in cells of a grid over the
        /// board: what's drawn where the picture would be enlarged, sharp at any size, the cells in view.
        let cells: [PathCell]

        /// Draws the silhouettes into `rect` (in the context's units, y down, as a render's), fitted:
        /// the board's proportions kept, centered, at no more than `maxScale` of the context's units to a
        /// world unit of the board. Where the picture would be drawn larger than its pixels, the shapes
        /// in view are drawn as paths instead, their lines `Style.previewLineWidth` device pixels wide
        /// as the picture's are its pixels, as long as they number no more than `pathShapes` (which is
        /// lessened by them); else, or with more, the picture. False, and nothing drawn, with nothing
        /// to show.
        @discardableResult @MainActor
        public func draw(in cg: CGContext, fitting rect: CGRect, maxScale: CGFloat = .infinity, pathShapes: inout Int) -> Bool {
            guard let image, frame.width > 0, frame.height > 0, rect.width > 0, rect.height > 0, maxScale > 0 else { return false }
            let scale = min(rect.width / frame.width, rect.height / frame.height, maxScale)
            let width = frame.width * scale, height = frame.height * scale
            let target = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
            let device = cg.userSpaceToDeviceSpaceTransform, pixelsPerUnit = max(hypot(device.a, device.b), hypot(device.c, device.d))
            if width * pixelsPerUnit > CGFloat(image.width) || height * pixelsPerUnit > CGFloat(image.height),
               drawPaths(in: cg, target: target, scale: scale, lineWidth: Style.previewLineWidth / pixelsPerUnit, shapes: &pathShapes) {
                return true
            }
            cg.saveGState()
            defer { cg.restoreGState() }
            // The picture's rows go up; the context's go down.
            cg.translateBy(x: 0, y: target.minY + target.maxY)
            cg.scaleBy(x: 1, y: -1)
            cg.interpolationQuality = .high
            cg.draw(image, in: target)
            return true
        }

        /// Draws the silhouettes into `rect`, as `draw(in:fitting:maxScale:pathShapes:)` does with no
        /// limit on the shapes drawn as paths.
        @discardableResult @MainActor
        public func draw(in cg: CGContext, fitting rect: CGRect, maxScale: CGFloat = .infinity) -> Bool {
            var unlimited = Int.max
            return draw(in: cg, fitting: rect, maxScale: maxScale, pathShapes: &unlimited)
        }

        /// The cells in view (the context's clip) as paths, the board's `frame` into `target`, `scale`
        /// context units to a world unit; `lineWidth` in context units. False, and nothing drawn, when
        /// they hold more shapes than `shapes`.
        private func drawPaths(in cg: CGContext, target: CGRect, scale: CGFloat, lineWidth: CGFloat, shapes: inout Int) -> Bool {
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
            cg.setLineWidth(reach)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            // Each cell's runs in the board's order, a run's fills and then its lines, as the picture paints
            // them; runs of one color one after another, a cell's last and the next one's first, in one fill
            // and one stroke.
            var shade: Int?, fills: [CGPath] = [], lines: [CGPath] = []
            func paint() {
                guard let shade else { return }
                if !fills.isEmpty {
                    for path in fills { cg.addPath(path) }
                    cg.setFillColor(colors[shade])
                    cg.fillPath()
                }
                if !lines.isEmpty {
                    for path in lines { cg.addPath(path) }
                    cg.setStrokeColor(colors[shade])
                    cg.strokePath()
                }
                fills.removeAll(keepingCapacity: true)
                lines.removeAll(keepingCapacity: true)
            }
            for cell in inView {
                for run in cell.runs {
                    if run.shade != shade {
                        paint()
                        shade = run.shade
                    }
                    if let path = run.fills { fills.append(path) }
                    if let path = run.lines { lines.append(path) }
                }
            }
            paint()
            return true
        }
    }

    /// The paths of the shapes whose middles are in one cell of a preview's grid, in the board's
    /// world units: their runs of one color in the board's order, and their bounds.
    struct PathCell {
        let bounds: CGRect
        let runs: [PathRun]
        let count: Int
    }

    /// Shapes of a cell one after another in the board's order and of one color (`Preview.colors[shade]`):
    /// what's filled and what's stroked (`Silhouettes.paths`), nil for nothing.
    struct PathRun {
        let shade: Int
        let fills: CGPath?
        let lines: CGPath?
    }

    public let registry: Registry
    /// How many previews are kept.
    public let capacity: Int
    /// How long building may take in a frame (`build(in:until:)`'s deadline, from the editor).
    public var frameBudget: Duration
    /// How many shapes a frame draws as paths (`draw(_:in:fitting:maxScale:)`), over all the
    /// previews it draws larger than their pictures: 1,000 (`Style.previewPathShapes`), unless set.
    public var pathShapes = Style.previewPathShapes {
        didSet { pathShapesLeft = pathShapes }
    }
    /// What's left of it in the frame being drawn.
    private var pathShapesLeft = Style.previewPathShapes
    /// The color a shape is drawn in, nil for the muted gray: its kind's tint (`registry.label(of:).tint`),
    /// unless set. The editor's is its `tint(of:)`, a plugin's for the shape first, and asked once a shape
    /// as a preview is built, never as it's drawn.
    public var tint: @MainActor (AnyShapeRecord) -> NSColor?
    /// How far each tint is quieted toward the gray (`RGB.muted(by:toward:)`), 0 for the tint as it
    /// is: `Style.previewTintMuting` unless set (a test sets 0 to read a tint exactly). Set before
    /// previews are built: one built already keeps the colors it was built in.
    public var muting = Style.previewTintMuting
    /// How many times shapes' tints changed with no commit to say so (`tintsDidChange()`).
    private var tintChanges = 0

    /// By board: a board is kept as one revision at most. `used` orders them by when they were last
    /// drawn; `frame` is the frame that was (-1 for none yet).
    private var kept: [BoardID: (preview: Preview, used: Int, frame: Int)] = [:]
    private var uses = 0
    /// Boards asked for with none built, or with one built in another look, the one asked for longest ago
    /// first; by board, and the frame each was last asked for in.
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
        tint = { [registry] record in registry.kindTint(of: record.kind) }
    }

    /// The look a preview asked for now is built in: the appearance being drawn in, the tints as they are.
    private var look: Look { Look(appearance: NSAppearance.currentDrawing().name, tints: tintChanges) }

    /// Shapes' tints changed with no commit to say so (the file's colors, the color a type gives its
    /// shapes: `editor.shapeTintsDidChange()`): each preview kept is built again as it's next asked for,
    /// and drawn as it was until then.
    public func tintsDidChange() {
        tintChanges += 1
    }

    /// The board's preview as `file` has it now, if it's built; else nil, and it's asked for (unless
    /// it's empty: an empty board has none). One built of an earlier revision is dropped; one built in
    /// another look (`Look`) is returned, and asked for again in this one.
    public func preview(of board: BoardID, in file: CanvasFile) -> Preview? {
        let document = file[board]
        guard !document.shapes.isEmpty else {
            forget(board)
            return nil
        }
        let key = Key(board: board, revision: file.revision(of: board))
        let look = self.look
        if let entry = kept[board] {
            if entry.preview.key == key {
                uses += 1
                kept[board]?.used = uses
                kept[board]?.frame = frame
                // In other colors: drawn as it is while it's built again in these.
                if entry.preview.look != look { ask(for: key, in: look, document) }
                return entry.preview
            }
            kept[board] = nil
        }
        ask(for: key, in: look, document)
        return nil
    }

    /// Asks for a board's preview, built in `look`. One already waiting for the same revision goes on
    /// building in the look it was asked for in; built in another, it's asked for again once it's done.
    private func ask(for key: Key, in look: Look, _ document: CanvasDocument) {
        let board = key.board
        if queued[board] != key {
            queue.removeAll { $0.key.board == board }
            queue.append(Build(key: key, look: look, appearance: NSAppearance.currentDrawing(), document: document,
                               registry: registry, tint: tint, muting: muting))
            queued[board] = key
        }
        asked[board] = frame
    }

    /// Ends the frame being drawn: of the boards waiting, only those asked for in it go on waiting
    /// (a board that's no longer drawn, scrolled away or on a board left, is asked for again if it
    /// comes back), and only as many as there's room kept for beside the previews it drew, the ones
    /// asked for first; one built again in another look takes the place of the one kept, and needs no
    /// room. The next frame's builds evict none of those it drew.
    public func endFrame() {
        let drawn = kept.values.count { $0.frame == frame }
        var room = max(capacity - drawn, 0)
        var waiting: [Build] = []
        for build in queue {
            let board = build.key.board
            let replaces = kept[board]?.preview.key == build.key
            if asked[board] == frame, replaces || room > 0 {
                waiting.append(build)
                if !replaces { room -= 1 }
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

    /// Draws a preview in the frame being drawn (`Preview.draw(in:fitting:maxScale:pathShapes:)`),
    /// its shapes drawn as paths out of what's left of the frame's `pathShapes`.
    @discardableResult
    public func draw(_ preview: Preview, in cg: CGContext, fitting rect: CGRect, maxScale: CGFloat = .infinity) -> Bool {
        preview.draw(in: cg, fitting: rect, maxScale: maxScale, pathShapes: &pathShapesLeft)
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
    /// frame before drew (`endFrame` leaves room for what waits). One built again in another look
    /// takes the place of its board's, as drawn as that was.
    private func keep(_ preview: Preview) {
        uses += 1
        kept[preview.key.board] = (preview, uses, kept[preview.key.board]?.frame ?? -1)
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

/// One preview being built, in two phases: every shape's geometry and color (and so the board's
/// bounds, which size the picture and the grid), then the silhouettes, painted into the picture and
/// gathered into their cells' paths a chunk at a time.
@MainActor
private final class Build {
    let key: BoardPreviews.Key
    let look: BoardPreviews.Look
    /// What the colors are worked out in: the appearance it was asked for in.
    private let appearance: NSAppearance
    private let shapes: ShapeStack
    private let context: ShapeContext
    private let tint: @MainActor (AnyShapeRecord) -> NSColor?
    /// How far a tint is quieted toward the gray, and the gray's lightness (OKLCH's).
    private let muting: Double
    private let grayLightness: Double
    private var next = 0
    private var geometries: [ShapeGeometry] = []
    /// Which of `geometries` are containers' (a frame's), drawn hollow, so what they hold shows.
    private var hollow: [Bool] = []
    /// Which of `colors` each of `geometries` is drawn in.
    private var shades: [Int] = []
    /// The colors the shapes are drawn in, each once, in the appearance: the muted gray of a shape with
    /// no tint, then each tint as it's first met, quieted toward the gray, found by the color it was
    /// given (`shadeOfTint`, which holds it, so its identity is no other's while the build lasts).
    private var colors: [CGColor]
    private var shadeOfTint: [ObjectIdentifier: (tint: NSColor, shade: Int)] = [:]
    private var bounds = CGRect.null
    private var bitmap: CGContext?
    private var frame = CGRect.null
    /// Pixels per world unit.
    private var scale: CGFloat = 1
    /// The grid's cells a side, and each one's runs of paths, by row and column from the bounds'
    /// top-left (those with shapes in them), with their shapes' bounds and how many.
    private var across = 1
    private var cells: [Int: GatheredCell] = [:]
    /// Once it's done.
    private(set) var preview: BoardPreviews.Preview?

    init(key: BoardPreviews.Key, look: BoardPreviews.Look, appearance: NSAppearance, document: CanvasDocument, registry: Registry,
         tint: @escaping @MainActor (AnyShapeRecord) -> NSColor?, muting: Double) {
        self.key = key
        self.look = look
        self.appearance = appearance
        shapes = document.shapes
        // No index: a board not shown has none, and its shapes' geometry is worked out once each.
        context = ShapeContext(document: document, registry: registry)
        self.tint = tint
        self.muting = muting
        let gray = Self.resolve(Style.boardPreview, in: appearance)
        colors = [gray]
        grayLightness = RGB(gray).map { OKLCH($0).lightness } ?? 0.5
    }

    /// 0 while measuring the shapes, 1 while drawing them.
    var phase: Int { bitmap == nil ? 0 : 1 }

    /// Measures or draws up to `count` shapes, never past the end of the phase. Returns how many.
    func step(_ count: Int) -> Int {
        guard preview == nil else { return 0 }
        let start = next
        if let bitmap {
            let end = min(start + count, geometries.count)
            guard start < end else { return 0 }
            let lineWidth = Style.previewLineWidth / scale
            // In the board's order, a run of one color at a time: what's in front is painted over what's
            // behind it, and a run is one fill and one stroke.
            var run = (shade: shades[start], silhouettes: Silhouettes(pixelsPerWorldUnit: scale))
            for i in start..<end {
                if shades[i] != run.shade {
                    run.silhouettes.draw(into: bitmap, color: colors[run.shade], lineWidth: lineWidth)
                    run = (shades[i], Silhouettes(pixelsPerWorldUnit: scale))
                }
                run.silhouettes.add(geometries[i], hollow: hollow[i])
                gather(geometries[i], hollow: hollow[i], shade: shades[i])
            }
            run.silhouettes.draw(into: bitmap, color: colors[run.shade], lineWidth: lineWidth)
            next = end
            if end == geometries.count { finish(bitmap.makeImage()) }
            return end - start
        }
        let end = min(start + count, shapes.count)
        for record in shapes[start..<end] where !record.isOpaque {
            guard let geometry = context.geometry(of: record.id), !geometry.outline.isEmpty else { continue }
            geometries.append(geometry)
            hollow.append(context.registry.isContainer(record))
            shades.append(shade(of: record))
            bounds = bounds.union(geometry.bounds)
        }
        next = end
        if end == shapes.count { startDrawing() }
        return end - start
    }

    /// Which of `colors` a shape is drawn in: its tint's, the first time it's met made in the appearance
    /// and quieted toward the gray; with none, the gray's.
    private func shade(of record: AnyShapeRecord) -> Int {
        guard let tint = tint(record) else { return 0 }
        let id = ObjectIdentifier(tint)
        if let known = shadeOfTint[id] { return known.shade }
        let made = Self.resolve(tint, in: appearance)
        colors.append(muting > 0 ? RGB(made).map { $0.muted(by: muting, toward: grayLightness).cgColor } ?? made : made)
        shadeOfTint[id] = (tint, colors.count - 1)
        return colors.count - 1
    }

    /// A color as it is in an appearance (one that follows the appearance resolved there).
    private static func resolve(_ color: NSColor, in appearance: NSAppearance) -> CGColor {
        var resolved: CGColor?
        appearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return resolved ?? color.cgColor
    }

    /// Sizes the picture to the bounds: the longest side `Style.previewSide` pixels, less a margin for
    /// open shapes' lines and antialiasing.
    private func startDrawing() {
        guard !geometries.isEmpty, !bounds.isNull else { return finish(nil) }
        let margin = (Style.previewLineWidth / 2 + 1).rounded(.up)
        scale = (Style.previewSide - margin * 2) / max(bounds.width, bounds.height, 1)
        let width = Int((bounds.width * scale + margin * 2).rounded(.up)), height = Int((bounds.height * scale + margin * 2).rounded(.up))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return finish(nil) }
        frame = CGRect(x: bounds.minX - margin / scale, y: bounds.minY - margin / scale, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        bitmap.clear(CGRect(x: 0, y: 0, width: width, height: height))
        // World units, y down, as the canvas draws; the frame's top-left is the bitmap's.
        bitmap.translateBy(x: 0, y: CGFloat(height))
        bitmap.scaleBy(x: scale, y: -scale)
        bitmap.translateBy(x: -frame.minX, y: -frame.minY)
        self.bitmap = bitmap
        let wanted = (Double(geometries.count) / Double(Style.previewCellShapes)).squareRoot().rounded(.up)
        across = min(max(Int(wanted), 1), Style.previewCellsAcross)
        next = 0
    }

    /// Adds a shape to the paths of the cell its middle is in, after the cell's last: its outline,
    /// whatever its size, in a run of its color.
    private func gather(_ geometry: ShapeGeometry, hollow: Bool, shade: Int) {
        let bounds = geometry.bounds
        let column = cell(bounds.midX, from: self.bounds.minX, across: self.bounds.width)
        let row = cell(bounds.midY, from: self.bounds.minY, across: self.bounds.height)
        let index = row * across + column
        let cell: GatheredCell
        if let found = cells[index] {
            cell = found
        } else {
            cell = GatheredCell()
            cells[index] = cell
        }
        if cell.runs.last?.shade != shade {
            // Outlines at any size: with no pixel to fall under, no shape is its bounds or its pixel.
            cell.runs.append((shade, Silhouettes(pixelsPerWorldUnit: .infinity)))
        }
        cell.runs[cell.runs.count - 1].paths.add(geometry, hollow: hollow)
        cell.bounds = cell.bounds.union(bounds)
        cell.count += 1
    }

    private func cell(_ value: CGFloat, from start: CGFloat, across length: CGFloat) -> Int {
        guard length > 0 else { return 0 }
        return min(max(Int(((value - start) / length * CGFloat(across)).rounded(.down)), 0), across - 1)
    }

    private func finish(_ image: CGImage?) {
        let cells: [BoardPreviews.PathCell] = image == nil ? [] : self.cells.keys.sorted().compactMap { index in
            self.cells[index].map { cell in
                let runs = cell.runs.map { run in
                    let paths = run.paths.paths
                    return BoardPreviews.PathRun(shade: run.shade, fills: paths.fills.isEmpty ? nil : paths.fills,
                                                 lines: paths.lines.isEmpty ? nil : paths.lines)
                }
                return BoardPreviews.PathCell(bounds: cell.bounds, runs: runs, count: cell.count)
            }
        }
        preview = BoardPreviews.Preview(key: key, look: look, frame: image == nil ? .null : frame, image: image, colors: colors, cells: cells)
        geometries = []
        hollow = []
        shades = []
        shadeOfTint = [:]
        self.cells = [:]
    }
}

/// A cell of a preview's grid as its paths are gathered: its runs of one color, in the board's order,
/// its shapes' bounds, and how many.
@MainActor
private final class GatheredCell {
    var runs: [(shade: Int, paths: Silhouettes)] = []
    var bounds = CGRect.null
    var count = 0
}

extension Duration {
    fileprivate var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

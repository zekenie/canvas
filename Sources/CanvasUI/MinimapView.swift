import AppKit
@_spi(Host) import Canvas
import Geometry

/// The minimap: the whole board in miniature, in the canvas's bottom-left corner, with the part the
/// canvas shows outlined. Each shape is a rough silhouette in one color, and the selected ones are in
/// the accent color, as in tldraw's minimap, which it works like: a click beside the part shown moves
/// the canvas there, eased; a drag from that part moves it as grabbed, and a drag from anywhere else
/// centers it on the pointer, never much past the board's edges; ⇧ keeps a drag to one axis; a
/// double-click centers it exactly there. Scrolling and pinching over it pan and zoom the canvas.
///
/// The canvas view hosts it (`CanvasView.showsMinimap`) and redraws it with itself. It keeps its
/// picture of the board (`MinimapPicture`) from frame to frame, and marks the shapes the canvas
/// outlines (`editor.outlines`), so it knows no particular shape or plugin. It shows the board shown
/// (`editor.board`), and keeps the pictures of the boards shown lately for when they're shown again.
public final class MinimapView: NSView {
    public let editor: CanvasEditor

    /// How long drawing the picture may take in a frame; what doesn't fit waits for the next.
    /// (Tests lengthen it, to have a board drawn in one frame.)
    public var frameBudget = MinimapStyle.frameBudget

    private var picture: MinimapPicture?
    /// The board `picture` is of.
    private var pictureBoard: BoardID
    /// Pictures of the boards shown lately, for when they're shown again; the one left longest ago
    /// first. Past `MinimapStyle.keptPictures`, the one left longest ago goes, but those on the path
    /// to the board shown last, as the editor keeps their indexes (`BoardStash`).
    private var keptPictures: [(board: BoardID, picture: MinimapPicture)] = []
    /// Seconds a silhouette takes to draw, on average, as the pictures learn it.
    private var costPerShape = MinimapStyle.initialCostPerShape
    private var nextFrame: ScheduledTask?
    private var press: Press?

    /// A press on the minimap, as tldraw keeps it.
    private struct Press {
        /// Where it was, in the minimap's points.
        let start: CGPoint
        /// World units: the point pressed (tldraw's originPagePoint), what ⇧ keeps a drag in line with.
        let grab: CGPoint
        /// World units: the viewport's center then (tldraw's originPageCenter).
        let center: CGPoint
        /// Pressed inside the viewport: dragging moves the viewport as grabbed, rather than centering
        /// it on the pointer (tldraw's isInViewport).
        let movesViewport: Bool
        /// Moved further than a click's jitter.
        var dragged = false
    }

    public init(editor: CanvasEditor) {
        self.editor = editor
        pictureBoard = editor.board
        super.init(frame: .zero)
        wantsLayer = true
        shadow = MinimapStyle.shadow
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Minimap")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        picture?.invalidate()
        for kept in keptPictures { kept.picture.invalidate() }
        needsDisplay = true
    }

    /// Another board is shown: the picture of the one left is kept, and the one shown gets its own
    /// back if it's still current (the editor kept that board as it was, so the damage since the
    /// picture's mark says what changed), else starts afresh. Never from another board's picture:
    /// until its first tiles are drawn, the minimap shows none of the board. (The canvas calls this
    /// as the editor switches, and drawing checks too.)
    func boardDidChange() {
        guard pictureBoard != editor.board else { return }
        if let picture {
            keptPictures.removeAll { $0.board == pictureBoard }
            keptPictures.append((pictureBoard, picture))
            if keptPictures.count > MinimapStyle.keptPictures {
                let path = Set(editor.boardPath)
                keptPictures.remove(at: keptPictures.firstIndex { !path.contains($0.board) } ?? 0)
            }
        }
        pictureBoard = editor.board
        let kept = keptPictures.firstIndex { $0.board == pictureBoard }.map { keptPictures.remove(at: $0).picture }
        picture = kept.flatMap { editor.isCurrent($0.mark) ? $0 : nil }
        needsDisplay = true
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    public override func layout() {
        super.layout()
        layer?.shadowPath = MinimapStyle.panel(bounds)
    }

    // MARK: Drawing

    /// Where the board goes in the minimap now.
    private var layoutNow: MinimapLayout {
        MinimapLayout(board: editor.shapeBounds, viewport: viewport, area: bounds.insetBy(dx: MinimapStyle.padding, dy: MinimapStyle.padding))
    }

    /// The part of the board the canvas shows, in world units; null before the canvas has a size.
    private var viewport: CGRect {
        let size = editor.viewportSize
        return size.width > 0 && size.height > 0 ? editor.camera.toWorld(CGRect(origin: .zero, size: size)) : .null
    }

    private var pixelsPerPoint: CGFloat { window?.backingScaleFactor ?? MinimapStyle.pixelsPerPointOffscreen }

    public override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        boardDidChange()
        let layout = layoutNow
        let panel = MinimapStyle.panel(bounds)
        cg.addPath(panel)
        cg.setFillColor(MinimapStyle.background.cgColor)
        cg.fillPath()

        cg.saveGState()
        cg.addPath(panel)
        cg.clip()
        if updatePicture(board: editor.shapeBounds, needed: layout.boardZoom * pixelsPerPoint), nextFrame == nil {
            nextFrame = editor.scheduler.schedule(after: .zero) { [weak self] in
                self?.nextFrame = nil
                self?.needsDisplay = true
            }
        }
        if let picture, let image = picture.image {
            // The bitmap's rows go up; the view's go down.
            let rect = layout.toMinimap(picture.frame)
            cg.saveGState()
            cg.translateBy(x: 0, y: rect.minY + rect.maxY)
            cg.scaleBy(x: 1, y: -1)
            cg.interpolationQuality = .high
            cg.draw(image, in: rect)
            cg.restoreGState()
        }
        drawOutlinedShapes(in: cg, layout: layout)
        let viewport = viewport
        if !viewport.isNull {
            // The rest under a veil, and the part the canvas shows outlined.
            let rect = layout.toMinimap(viewport)
            let radius = min(rect.width / 4, rect.height / 4, MinimapStyle.viewportCornerRadius)
            let frame = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            cg.addRect(bounds)
            cg.addPath(frame)
            cg.setFillColor(MinimapStyle.veil.cgColor)
            cg.fillPath(using: .evenOdd)
            cg.addPath(frame)
            cg.setStrokeColor(MinimapStyle.viewportBorder.cgColor)
            cg.setLineWidth(MinimapStyle.viewportBorderWidth)
            cg.strokePath()
        }
        cg.restoreGState()

        let border = MinimapStyle.borderWidth
        cg.addPath(MinimapStyle.panel(bounds.insetBy(dx: border / 2, dy: border / 2)))
        cg.setStrokeColor(MinimapStyle.border.cgColor)
        cg.setLineWidth(border)
        cg.strokePath()
    }

    /// The silhouettes of the shapes the canvas outlines, over the picture: the selected ones (and the
    /// hint) in the accent color, as tldraw's minimap fills them; faint ones (a hover) lighter.
    private func drawOutlinedShapes(in cg: CGContext, layout: MinimapLayout) {
        let outlines = editor.outlines
        guard !outlines.shapes.isEmpty || !outlines.faintShapes.isEmpty else { return }
        let context = editor.shapeContext
        cg.saveGState()
        cg.translateBy(x: layout.area.minX, y: layout.area.minY)
        cg.scaleBy(x: layout.zoom, y: layout.zoom)
        cg.translateBy(x: -layout.shown.minX, y: -layout.shown.minY)
        for (ids, color) in [(outlines.faintShapes, MinimapStyle.faintSelection), (outlines.shapes, MinimapStyle.selection)] {
            let silhouettes = Silhouettes(pixelsPerWorldUnit: layout.zoom * pixelsPerPoint)
            for id in ids {
                if let geometry = context.geometry(of: id) { silhouettes.add(geometry) }
            }
            silhouettes.draw(into: cg, color: color.cgColor, lineWidth: MinimapStyle.lineWidth / layout.zoom)
        }
        cg.restoreGState()
    }

    /// Brings the picture up to date with the board, and draws what it's missing for a frame's worth
    /// of time. `needed` is the pixels per world unit the board is shown at when it fills the
    /// minimap: a picture with fewer would show blurred. Returns whether there's more to draw.
    private func updatePicture(board: CGRect, needed: CGFloat) -> Bool {
        guard !board.isNull, needed.isFinite, needed > 0 else {
            picture = nil
            return false
        }
        let scale = needed * MinimapStyle.oversampling
        if let current = picture, needed <= current.scale {
            if current.scale > needed * MinimapStyle.coarsening {
                // Much finer than the minimap shows it now (the board grew, or the minimap shrank):
                // scaled down, rather than drawn again.
                picture = MinimapPicture(from: current, covering: board, scale: scale) ?? fresh(board, scale: scale, over: current)
            } else if !current.covers(board) {
                picture = MinimapPicture(from: current, covering: board, scale: current.scale) ?? fresh(board, scale: scale, over: current)
            }
        } else {
            // None yet, or one that would show blurred (the board shrank, the minimap grew, or the
            // display is sharper): drawn afresh, showing the old one until it's done.
            picture = fresh(board, scale: scale, over: picture)
        }
        guard let picture else { return false }
        picture.catchUp(with: editor)
        picture.draw(editor, color: MinimapStyle.shape.cgColor, until: .now + frameBudget, costPerShape: &costPerShape)
        return !picture.isComplete
    }

    private func fresh(_ board: CGRect, scale: CGFloat, over old: MinimapPicture?) -> MinimapPicture? {
        MinimapPicture(of: board, scale: scale, pixelsPerPoint: pixelsPerPoint * MinimapStyle.oversampling, editor: editor, seed: old)
    }

    // MARK: The pointer

    public override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    /// A press: beside the viewport (and not far off the board), the canvas moves there, eased;
    /// anywhere else, it waits for a drag. A Control-click is a secondary click, which the minimap
    /// doesn't take. Either way the canvas gets the keyboard, as a click on it would, unless it or
    /// the shape being edited has it.
    public override func mouseDown(with event: NSEvent) {
        press = nil
        takeKeyboard()
        guard !event.modifierFlags.contains(.control) else { return }
        let board = editor.shapeBounds, viewport = viewport
        guard !board.isNull, !viewport.isNull else { return }
        let location = convert(event.locationInWindow, from: nil)
        let layout = layoutNow
        let point = layout.toWorld(location)
        let allowed = layout.content.insetBy(dx: -viewport.width / 2, dy: -viewport.height / 2)
        if allowed.contains(point) && !viewport.contains(point) {
            // tldraw keeps a ⇧-drag from here in line with the point half a viewport down and right
            // of this one, which looks like a slip; this keeps it in line with the point pressed.
            press = Press(start: location, grab: point, center: point, movesViewport: false)
            editor.animateCamera(to: camera(centeredOn: point), duration: MinimapStyle.recenterDuration)
        } else {
            let clamped = MinimapLayout.clamp(point, board: board, viewport: viewport)
            press = Press(start: location, grab: clamped, center: CGPoint(x: viewport.midX, y: viewport.midY),
                          movesViewport: viewport.contains(clamped))
        }
    }

    /// Past a click's jitter, the canvas follows: the viewport as grabbed, or centered on the pointer.
    public override func mouseDragged(with event: NSEvent) {
        guard var press else { return }
        let board = editor.shapeBounds, viewport = viewport
        guard !board.isNull, !viewport.isNull else { return }
        let location = convert(event.locationInWindow, from: nil)
        let dx = location.x - press.start.x, dy = location.y - press.start.y
        // Sub-pixel jitter with a click would recenter at once, cutting off the easing it started.
        guard dx * dx + dy * dy > MinimapStyle.clickJitterSquared else { return }
        press.dragged = true
        self.press = press
        var point = MinimapLayout.clamp(layoutNow.toWorld(location), board: board, viewport: viewport)
        if event.modifierFlags.contains(.shift) {
            if abs(point.x - press.grab.x) > abs(point.y - press.grab.y) { point.y = press.grab.y } else { point.x = press.grab.x }
        }
        let target = press.movesViewport ? CGPoint(x: point.x - (press.grab.x - press.center.x), y: point.y - (press.grab.y - press.center.y)) : point
        editor.camera = camera(centeredOn: target)
    }

    /// A double-click centers the canvas exactly where it was, eased.
    public override func mouseUp(with event: NSEvent) {
        defer { press = nil }
        guard let press, !press.dragged, event.clickCount >= 2, !editor.shapeBounds.isNull, !viewport.isNull else { return }
        editor.animateCamera(to: camera(centeredOn: layoutNow.toWorld(press.start)), duration: MinimapStyle.recenterDuration)
    }

    /// Right-clicks do nothing here: passed on, they'd open the menu of a shape under the minimap.
    public override func rightMouseDown(with event: NSEvent) {}
    public override func otherMouseDown(with event: NSEvent) {}
    public override func menu(for event: NSEvent) -> NSMenu? { nil }

    /// The camera, as it is, but with the viewport's center at `point`.
    private func camera(centeredOn point: CGPoint) -> Camera {
        let camera = editor.camera, size = editor.viewportSize
        return Camera(origin: CGPoint(x: point.x - size.width / camera.zoom / 2, y: point.y - size.height / camera.zoom / 2), zoom: camera.zoom)
    }

    private func takeKeyboard() {
        guard let canvas = superview, let window else { return }
        if let responder = window.firstResponder as? NSView, responder === canvas || responder.isDescendant(of: canvas) { return }
        window.makeFirstResponder(canvas)
    }
}

/// Where the minimap puts the board, as tldraw's does: the board and the part the canvas shows (the
/// viewport) together, fitted to the minimap and centered.
struct MinimapLayout {
    /// The board with the viewport: what the minimap shows (tldraw's content bounds), world units.
    let content: CGRect
    /// `content` grown to the minimap's proportions, about its center.
    let shown: CGRect
    /// Where it's drawn, in the minimap's points.
    let area: CGRect
    /// Points per world unit at which the board alone would fit `area`: what the pictures are drawn
    /// for, so a picture stays sharp whatever the viewport does.
    let boardZoom: CGFloat

    init(board: CGRect, viewport: CGRect, area: CGRect) {
        let content = board.isNull ? viewport : viewport.isNull ? board : board.union(viewport)
        self.content = content.isNull ? CGRect(origin: .zero, size: area.size) : content
        let aspect = area.width / max(area.height, 1)
        var width = max(self.content.width, 1), height = width / aspect
        if height < self.content.height {
            height = self.content.height
            width = height * aspect
        }
        shown = CGRect(x: self.content.midX - width / 2, y: self.content.midY - height / 2, width: width, height: height)
        self.area = area
        let fit = min(board.width > 0 ? area.width / board.width : .infinity, board.height > 0 ? area.height / board.height : .infinity)
        boardZoom = fit.isFinite ? fit : 1
    }

    /// Minimap points per world unit.
    var zoom: CGFloat { area.width / shown.width }

    func toMinimap(_ point: CGPoint) -> CGPoint {
        CGPoint(x: area.minX + (point.x - shown.minX) * zoom, y: area.minY + (point.y - shown.minY) * zoom)
    }

    func toMinimap(_ rect: CGRect) -> CGRect {
        CGRect(origin: toMinimap(rect.origin), size: CGSize(width: rect.width * zoom, height: rect.height * zoom))
    }

    func toWorld(_ point: CGPoint) -> CGPoint {
        CGPoint(x: shown.minX + (point.x - area.minX) / zoom, y: shown.minY + (point.y - area.minY) / zoom)
    }

    /// Where a drag may take the viewport's center (tldraw's clamped minimap point): within the board
    /// grown by half the viewport, easing in as it nears those edges, so the board never leaves the
    /// canvas altogether.
    static func clamp(_ point: CGPoint, board: CGRect, viewport: CGRect) -> CGPoint {
        let minX = board.minX - viewport.width / 2, maxX = board.maxX + viewport.width / 2
        let minY = board.minY - viewport.height / 2, maxY = board.maxY + viewport.height / 2
        let left = max(0, minX + viewport.width - point.x), right = max(0, point.x - (maxX - viewport.width))
        let top = max(0, minY + viewport.height - point.y), bottom = max(0, point.y - (maxY - viewport.height))
        return CGPoint(x: min(max(point.x + (left - right) / 2, minX), maxX), y: min(max(point.y + (top - bottom) / 2, minY), maxY))
    }
}

extension NSAppearance {
    fileprivate var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// The minimap's constants, in view points unless noted. Its behavior follows tldraw's.
@MainActor
enum MinimapStyle {
    /// Its width: a quarter of the canvas's, within these. Its height follows the canvas's
    /// proportions, within these.
    static let widths: ClosedRange<CGFloat> = 120...200
    static let heights: ClosedRange<CGFloat> = 72...150
    static let widthFraction: CGFloat = 0.25
    /// From the canvas's bottom-left corner.
    static let margin: CGFloat = 12
    static let cornerRadius: CGFloat = 8
    /// Between its edge and the board.
    static let padding: CGFloat = 6

    static func size(in canvas: CGSize) -> CGSize {
        let width = min(max(canvas.width * widthFraction, widths.lowerBound), widths.upperBound)
        let height = canvas.width > 0 ? width * canvas.height / canvas.width : heights.lowerBound
        return CGSize(width: width, height: min(max(height, heights.lowerBound), heights.upperBound))
    }

    /// Before the minimap is in a window.
    static let pixelsPerPointOffscreen: CGFloat = 2

    static func panel(_ rect: CGRect) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    }

    /// The canvas's own, so the part the canvas shows looks as it does there, and the rest as it
    /// would under the veil.
    static let background = NSColor(name: nil) {
        $0.isDark ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.965, alpha: 1)
    }
    static let border = NSColor(name: nil) {
        $0.isDark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.12)
    }
    static let borderWidth: CGFloat = 1
    static var shadow: NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.18)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return shadow
    }
    /// Every shape's silhouette (tldraw's minimap shape fill: its third text color).
    static let shape = NSColor(name: nil) {
        $0.isDark ? NSColor(srgbRed: 0.74, green: 0.752, blue: 0.76, alpha: 1) : NSColor(srgbRed: 0.432, green: 0.454, blue: 0.468, alpha: 1)
    }
    /// The silhouettes of the shapes the canvas outlines: selected, and hovered.
    static let selection = NSColor.controlAccentColor
    static var faintSelection: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.5) }
    /// An open shape's line (an arrow's), in the minimap's points.
    static let lineWidth: CGFloat = 1
    /// Over the board but the part the canvas shows. (tldraw shades that part instead.)
    static let veil = NSColor(name: nil) {
        $0.isDark ? NSColor(white: 0, alpha: 0.2) : NSColor(white: 0, alpha: 0.06)
    }
    /// Around the part the canvas shows, with tldraw's corner radius, at most.
    static let viewportBorder = NSColor(name: nil) {
        $0.isDark ? NSColor(white: 1, alpha: 0.55) : NSColor(white: 0, alpha: 0.45)
    }
    static let viewportBorderWidth: CGFloat = 1
    static let viewportCornerRadius: CGFloat = 4

    /// A press moving no further than this (squared) is still a click (tldraw's CLICK_JITTER_THRESHOLD_SQ).
    static let clickJitterSquared: CGFloat = 4
    /// Moving the canvas to a point clicked takes this long (tldraw's animationMediumMs).
    static let recenterDuration: Duration = .milliseconds(320)

    // The pictures (MinimapPicture). Sizes there are in pixels.
    /// A picture is drawn with this many pixels for each one the minimap shows the board at, so
    /// the board can shrink by as much before the picture shows blurred and a sharper one is drawn.
    static let oversampling: CGFloat = 1.5
    /// A picture with this many pixels for each one the board is shown at is scaled down.
    static let coarsening: CGFloat = 3
    /// A picture's frame is the board with this much of its size again on each side, on a grid of
    /// this many pixels, so it seldom needs to grow.
    static let pictureRoom: CGFloat = 0.1
    static let pictureGrid: CGFloat = 16
    /// No picture is larger, on either side.
    static let largestPicture = 4096
    /// The side of a picture's tiles: what goes stale, and is drawn again, as one.
    static let tile = 32
    /// How many pictures of boards not shown are kept, for when they're shown again: as many as the
    /// boards the editor keeps (a picture of one it no longer keeps is drawn afresh anyway).
    static let keptPictures = 8
    /// How long drawing the picture may take in a frame; what doesn't fit waits for the next.
    static let frameBudget: Duration = .milliseconds(4)
    /// A guess at what a silhouette takes to draw, until the pictures have measured it, and how
    /// much each run of tiles drawn moves the guess toward what it took.
    static let initialCostPerShape = 2e-6
    static let costLearning = 0.25
}

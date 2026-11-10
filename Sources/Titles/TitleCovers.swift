import Adornments
import AppKit
import Canvas
import Palette
import Selection

/// A title on its shape, zoomed out: a shape the canvas draws as a skeleton (`editor.drawsSkeleton(of:)`,
/// below the editor's `skeletonZoom`, 35%) shows no adornments, and so no pill, so its title is said
/// on the shape itself (a cover), where it reads from afar. Titles draws it, over every shape, in
/// one overlay, after the shapes and their outlines: on a frame, which holds shapes, it can't be
/// hidden by what the frame holds.
///
/// A cover is plain text on the shape, no plate: in a dark ink on a light surface and a light one on
/// a dark surface, by the surface the kind says its skeleton is drawn on (`coverSurface`: a note's
/// yellow, a frame's gray, which follows the appearance), with a halo of that surface around the
/// glyphs, so it stays clear over what lies under it (the notes a frame holds, a note's greeked
/// lines). Centered on the shape, or at the top left of a container (a frame), where its pill goes
/// in full.
///
/// Its size follows the shape's, not the title's, so equal shapes have equal titles
/// (`sizeFraction` of the shorter side, `minimumFontSize` to `maximumFontSize`, view points): fitted
/// down only as far as the title needs, and never so that a word is broken. A title is wrapped on
/// whole words, the size made smaller until its longest word fits a line (`maximumWordColumns`: a
/// longer one, or text with no spaces, breaks where the line does) and the whole title the room; a
/// word that doesn't fit even at the smallest size puts the title on one line, truncated. A title
/// that doesn't fit the room ends in an ellipsis: its last line truncated as AppKit truncates it,
/// after the string is cut to `maximumCharacters` (ending in an ellipsis of its own), so a title
/// of thousands of characters costs what one of a hundred does. Never drawn outside its shape; a
/// shape too small on screen to say anything in (`smallestShape`) gets none, and neither does an
/// untitled one (a placeholder is for grabbing a shape by, and a skeleton has no pill) nor a kind
/// that shows no pill (`pill: false`: it draws its own title).
@MainActor
enum TitleCoverStyle {
    /// The least a shape is on screen, in view points, to have a cover: below it there's no room
    /// for a word at the smallest size, only for an ellipsis (and a card, wide and short, 15 points
    /// tall is the least that holds a line of it).
    static let smallestShape = CGSize(width: 40, height: 15)
    /// Between a shape's edge and its text, where the shape has room for it: a short shape's gives
    /// way to a line of text.
    static let inset: CGFloat = 4
    static let minimumFontSize: CGFloat = 9
    static let maximumFontSize: CGFloat = 28
    /// The size a cover asks for, before it's fitted: this much of the shape's shorter side.
    static let sizeFraction: CGFloat = 0.22
    /// The title's characters laid out, at most: what's past them is the ellipsis.
    static let maximumCharacters = 120
    /// How much of the room the text fills, at most, whatever its size: a wrapped paragraph never
    /// packs its lines solid.
    static let fill: CGFloat = 0.8
    /// A word longer than this, in columns, breaks where the line does, like text with no spaces.
    static let maximumWordColumns = 16
    /// A word's width is held to this much of the room's, as it's measured at one size and set at
    /// another.
    static let wordRoom: CGFloat = 0.98
    static let weight = NSFont.Weight.semibold
    /// The halo's stroke, as a percent of the font's size (`NSAttributedString.Key.strokeWidth`).
    static let haloWidth: Double = 12
    static let haloOpacity: CGFloat = 0.85
    static let darkInk = NSColor(white: 0.1, alpha: 0.88)
    static let lightInk = NSColor(white: 1, alpha: 0.95)
    /// The surface a kind that doesn't say is taken to draw its skeleton on: the default skeleton's
    /// gray, which dark ink reads on.
    static let defaultSurface = NSColor(white: 0.62, alpha: 1)
    static let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]

    /// What the system font's text measures per point of its size, once: how wide a column is (as
    /// `SkeletonText` counts them, a narrow character's) and how tall a line is.
    private struct Metrics {
        let advance: CGFloat
        let lineHeight: CGFloat
    }

    private static let metrics: Metrics = {
        let font = NSFont.systemFont(ofSize: 100, weight: weight)
        let sample = "Front desk, the quick brown fox jumps over the lazy dog"
        let width = NSAttributedString(string: sample, attributes: [.font: font]).size().width
        let height = NSAttributedString(string: "Xg", attributes: [.font: font]).size().height
        return Metrics(advance: width / 100 / CGFloat(SkeletonText.columns(of: sample)), lineHeight: height / 100)
    }()

    // MARK: What it says

    /// What a cover says of a title: the title, or its first `maximumCharacters` characters and an
    /// ellipsis, so a long one is cut before it's laid out. O(`maximumCharacters`).
    static func shown(_ title: String) -> String {
        guard title.utf8.count > maximumCharacters, !title.dropFirst(maximumCharacters).isEmpty else { return title }
        return String(title.prefix(maximumCharacters)) + "…"
    }

    /// The title's widest word, a word being what whitespace separates, by its columns, among those
    /// that must be kept whole (`maximumWordColumns`); nil if there are none.
    private static func widestWord(of text: String) -> String? {
        var widest: Substring?, columns = 0
        for word in text.split(whereSeparator: \.isWhitespace) {
            let count = SkeletonText.columns(of: word)
            if count <= maximumWordColumns, count > columns {
                widest = word
                columns = count
            }
        }
        return widest.map(String.init)
    }

    /// Whether dark ink reads on a surface: its luminance, as it's drawn in now (a dynamic color
    /// resolves in the appearance being drawn), is over half.
    nonisolated static func isLight(_ surface: NSColor) -> Bool {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let color = surface.cgColor.converted(to: space, intent: .defaultIntent, options: nil),
              let components = color.components, components.count >= 3 else { return true }
        return 0.2126 * components[0] + 0.7152 * components[1] + 0.0722 * components[2] > 0.5
    }

    // MARK: Where

    /// A cover laid out for a shape `shape` view points across: the text and where it is, from the
    /// shape's top-left corner, in view points.
    struct Layout {
        let text: String
        /// The title in its ink, and the same outlined in the surface's color, drawn under it.
        let string: NSAttributedString
        let halo: NSAttributedString
        let fontSize: CGFloat
        /// What the text takes, whole points.
        let rect: CGRect
        /// Where it's drawn: `rect`, a point wider, since a wrapped line may need the width it was
        /// measured at.
        let drawRect: CGRect
    }

    /// `atTop`: a container's, at its top left, where its title's pill goes; else centered.
    ///
    /// The size is the shape's (`sizeFraction` of its shorter side, within the font sizes), made
    /// smaller where the title wouldn't fill the room (`fill` of it, the room being the shape less
    /// its inset, at the font's measured advance and line height, as the title's columns would be
    /// set), where a line would be taller than the room, and until the widest word, as it's
    /// measured, fits a line. A word that can't fit at the smallest size sets the title on one
    /// line, truncated. The text then takes what the room gives it.
    static func layout(of title: String, in shape: CGSize, atTop: Bool, surface: NSColor?) -> Layout? {
        guard shape.width >= smallestShape.width, shape.height >= smallestShape.height else { return nil }
        let metrics = Self.metrics
        // A line of the smallest size, and a little around it: what a shape less than that is has no room for.
        let line = minimumFontSize * metrics.lineHeight
        guard shape.height >= line + 4 else { return nil }
        // The inset gives way where the shape is short.
        let edge = min(inset, (shape.height - line) / 2)
        let room = CGSize(width: shape.width - 2 * edge, height: shape.height - 2 * edge)
        guard room.width > 0, room.height > line - 0.01 else { return nil }
        let text = shown(title)
        let columns = CGFloat(max(1, SkeletonText.columns(of: text)))
        let wanted = min(maximumFontSize, max(minimumFontSize, sizeFraction * min(shape.width, shape.height)))
        let byArea = (fill * room.width * room.height / (columns * metrics.advance * metrics.lineHeight)).squareRoot()
        var size = max(minimumFontSize, min(wanted, byArea, room.height / metrics.lineHeight))
        // Whole words: the widest, measured, is held to a line, or the title is set on one line.
        var oneLine = false
        if let word = widestWord(of: text) {
            let width = NSAttributedString(string: word, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).size().width
            if width > room.width * wordRoom {
                let fitted = size * room.width * wordRoom / width
                if fitted >= minimumFontSize {
                    size = fitted
                } else {
                    size = minimumFontSize
                    oneLine = true
                }
            }
        }
        size = max(minimumFontSize, (size * 2).rounded(.down) / 2)
        let ground = surface ?? defaultSurface
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = atTop ? .left : .center
        paragraph.lineBreakMode = oneLine ? .byTruncatingTail : .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: isLight(ground) ? darkInk : lightInk,
            .paragraphStyle: paragraph,
        ]
        let halo = ground.withAlphaComponent(haloOpacity)
        let haloAttributes = attributes.merging([.foregroundColor: halo, .strokeColor: halo, .strokeWidth: NSNumber(value: haloWidth)]) { $1 }
        let string = NSAttributedString(string: text, attributes: attributes)
        // As large as the text is where the room cuts it, to whole points.
        let limit = CGSize(width: room.width, height: oneLine ? (size * metrics.lineHeight).rounded(.up) : room.height)
        let bound = string.boundingRect(with: limit, options: options)
        let used = CGSize(width: min(room.width, bound.width.rounded(.up)), height: min(limit.height, bound.height.rounded(.up)))
        let origin = atTop ? CGPoint(x: edge, y: edge)
                           : CGPoint(x: ((shape.width - used.width) / 2).rounded(), y: ((shape.height - used.height) / 2).rounded())
        return Layout(text: text, string: string, halo: NSAttributedString(string: text, attributes: haloAttributes), fontSize: size,
                      rect: CGRect(origin: origin, size: used),
                      drawRect: CGRect(origin: origin, size: CGSize(width: used.width + 1, height: used.height)))
    }

    /// A shape's cover and where the shape is (its bounds, world units), if it has one: it's titled
    /// and shows a title, and is big enough on screen. The shape's, not whether it's drawn as a
    /// skeleton, which the caller asks.
    static func cover(of record: AnyShapeRecord, in shapes: ShapeContext, editor: CanvasEditor) -> (layout: Layout, bounds: CGRect)? {
        let registry = editor.registry
        guard !record.isOpaque, let geometry = shapes.geometry(of: record.id), !geometry.outline.isEmpty, !geometry.bounds.isNull else { return nil }
        let bounds = geometry.bounds, zoom = shapes.zoom
        let size = CGSize(width: bounds.width * zoom, height: bounds.height * zoom)
        guard size.width >= smallestShape.width, size.height >= smallestShape.height,
              let title = registry.titleCover(of: record, in: editor),
              let laidOut = layout(of: title.title, in: size, atTop: registry.isContainer(record), surface: title.surface) else { return nil }
        return (laidOut, bounds)
    }
}

/// A shape's cover as the canvas lays it out now, for what asks where it is.
public struct TitleCover: Equatable {
    /// What it says: the shape's title as it reads, or its first `TitleCoverStyle.maximumCharacters`
    /// characters and "…" if it's longer. The text drawn is this, set where its room ends.
    public let text: String
    /// What its text takes, in world units, where the shape is (not where a shake draws it).
    public let rect: CGRect
    /// How large its text is, in view points.
    public let fontSize: CGFloat
}

extension CanvasEditor {
    /// A shape's cover now: nil unless the canvas draws it as a skeleton (`drawsSkeleton(of:)`, zoomed
    /// out; in full it has its pill), it's titled, its kind shows its title, and it's big enough on
    /// screen to say it on.
    public func titleCover(of id: ShapeID) -> TitleCover? {
        let shapes = shapeContext
        guard drawsSkeleton(of: id), let record = document[id],
              let found = TitleCoverStyle.cover(of: record, in: shapes, editor: self) else { return nil }
        let zoom = shapes.zoom, text = found.layout.rect
        return TitleCover(text: found.layout.text,
                          rect: CGRect(x: found.bounds.minX + text.minX / zoom, y: found.bounds.minY + text.minY / zoom,
                                       width: text.width / zoom, height: text.height / zoom),
                          fontSize: found.layout.fontSize)
    }
}

/// Every shape drawn as a skeleton's cover, above the shapes, back to front. Nothing when shapes
/// are drawn in full; a shape too small on screen is passed over by its kept bounds alone, so a board
/// of thousands zoomed out far costs a look at each shape in view. A shape drawn away from where it
/// is (a shake) has its cover there. The shapes waiting to be placed (`editor.placeLater`) have theirs
/// as they're drawn, faint, where they'd land.
struct TitleCoverOverlay: CanvasOverlay {
    var space: OverlaySpace { .world }

    func draw(in context: OverlayContext) {
        guard context.drawsSkeletons else { return }
        let editor = context.editor
        let reach = context.worldDrawingReach + TitleBar.reach / context.zoom
        let visible = context.visibleRect.insetBy(dx: -reach, dy: -reach)
        var bars = TitleBars()
        let selected = editor.selectedShapeIDs
        for record in editor.paintOrder(in: visible) where context.drawsSkeleton(of: record.id) {
            if let bar = TitleBar.bar(of: record, in: context.shapes, offset: context.worldDrawingOffset(of: record.id), selected: selected.contains(record.id),
                                      start: { editor.adornmentRowStart(of: record.id) }, tabs: { editor.adornmentRowTabs(of: record.id) }) {
                bars.add(bar)
                continue
            }
            guard let found = TitleCoverStyle.cover(of: record, in: context.shapes, editor: editor) else { continue }
            draw(found, offset: context.worldDrawingOffset(of: record.id), in: context)
        }
        bars.fill(in: context.cg, zoom: context.zoom)
        guard !context.pendingShapes.isEmpty else { return }
        context.drawingPending {
            for record in context.pendingShapes {
                guard let found = TitleCoverStyle.cover(of: record, in: context.pendingContext, editor: editor) else { continue }
                draw(found, offset: .zero, in: context)
            }
        }
    }

    /// One cover, on its shape's bounds moved by `offset` (world units).
    private func draw(_ found: (layout: TitleCoverStyle.Layout, bounds: CGRect), offset: CGPoint, in context: OverlayContext) {
        let cg = context.cg, scale = 1 / context.zoom
        cg.saveGState()
        cg.translateBy(x: found.bounds.minX + offset.x, y: found.bounds.minY + offset.y)
        // From here in view points, y down, from the shape's top-left corner.
        cg.scaleBy(x: scale, y: scale)
        found.layout.halo.draw(with: found.layout.drawRect, options: TitleCoverStyle.options)
        found.layout.string.draw(with: found.layout.drawRect, options: TitleCoverStyle.options)
        cg.restoreGState()
    }
}

/// A title zoomed out, for a kind that asks (`title(bars: true)`): a bar where its pill is, above the shape's top-left
/// corner, as long as its title reads, in its pill's color, so a board of tables far out reads as cards under their
/// names' bars (E8's 30%) rather than names printed over their rows. No text, no symbol; the shapes' bars are filled a
/// color at a time (`TitleBars`).
@MainActor
enum TitleBar {
    /// The bar's height, as much of the pill's.
    static let heightFraction: CGFloat = 0.4
    /// The narrowest shape that has a bar, view points: a bar needs no room for text, so a table of usual width far out (10%) still
    /// has its bar (a cover's floor, `TitleCoverStyle.smallestShape`, is for words).
    static let narrowest: CGFloat = 8
    /// How far above its shape's top edge a bar's bottom is, view points: close enough to read as its own shape's name and never as
    /// the footer of the one above, where tables a few points apart far out stack in a database (UX walk 3 evolve-8, walk 4
    /// structure-45).
    static let gap: CGFloat = 1.5
    /// The same for a selected shape: clear of its outline (the core's, 4 off its edge and 1.5 wide) and of the corner handles on its
    /// edge (Selection's, 4 across their middle and a 1.5 stroke), with a point to spare, so a selected shape's bar is never under
    /// its outline or a handle (UX walk 4 apis-2, review U12-E1: for every shape, a lower table's bar stood nearer the table above).
    static let selectedGap: CGFloat = 6.5
    /// How far inside its shape's top edge, or below a container's tab there, a bar that goes inside is, view points.
    static let insideGap: CGFloat = 1.5
    /// How far in from a selected shape's left edge a bar that goes inside starts, view points: past its corner handle (review U12-E9).
    static let handleReach: CGFloat = 6
    /// A bar thinner than this, view points, is drawn square: its rounded ends are under a point.
    static let squareBelow: CGFloat = 4
    /// A column of its title, view points: the pill's 11-point text, as `SkeletonText` counts a column.
    static let column: CGFloat = SkeletonTextMetrics.systemFontColumn * 11
    /// What the bar keeps besides its title's columns, view points: the pill's padding at both ends and its symbol.
    static let lead: CGFloat = 26
    /// The farthest a bar reaches above its shape, view points: what the overlay looks past the view's edge for.
    static let reach: CGFloat = AdornmentLayout.rowReach
    /// The pill's gray, which a bar is drawn in where no look tints it: as the pill is in the light appearance, lighter
    /// in the dark, where the pill's dark gray would be lost on the canvas.
    static let fill = NSColor(name: nil) { $0.isDark ? NSColor(white: 0.5, alpha: 0.9) : NSColor(white: 0.25, alpha: 0.9) }

    /// A titled shape's bar, world units, where its shape is drawn (moved by `offset`); nil for a kind that draws a
    /// cover, an untitled shape, and one too small on screen to be seen (`narrowest`).
    /// `start`: how far right of the shape's left edge the bar starts, world units (Adornments' `adornmentRowStart`, clear
    /// of a container's tab, as the pill's row is); `tabs`: where those tabs are (`adornmentRowTabs`), which a bar that goes
    /// inside its shape keeps below. `selected`: the shape is selected, so its bar clears its outline and handles.
    static func bar(of record: AnyShapeRecord, in shapes: ShapeContext, offset: CGPoint, selected: Bool = false, start: () -> CGFloat = { 0 },
                    tabs: () -> CGRect? = { nil }) -> (rect: CGRect, color: NSColor?)? {
        guard !record.isOpaque, let found = shapes.registry.titleBar(of: record), let geometry = shapes.geometry(of: record.id),
              !geometry.bounds.isNull else { return nil }
        let bounds = geometry.bounds.offsetBy(dx: offset.x, dy: offset.y), zoom = shapes.zoom
        guard bounds.width * zoom >= narrowest else { return nil }
        let row = TitleField.pillRow(above: bounds, zoom: zoom), height = row.height * heightFraction
        let points = lead + column * CGFloat(SkeletonText.columns(of: found.title, upTo: 80))
        let wanted = min(bounds.width, points * row.height / AdornmentLayout.rowHeight)
        var width = wanted
        // Just above its own shape's top edge, `gap` clear of it, so it reads as that shape's name and never as the footer of the
        // shape above (UX walk 3 evolve-8): the pill's row is a line of text tall, which zoomed out reaches most of the way to
        // the shape above.
        var top = bounds.minY - (selected ? selectedGap : gap) / zoom - height
        // Past a container's tab it meets, as the pill's row is, over its own shape alone (never past its right edge, over the
        // next shape's bar: review U9-E1), while at least half of it still fits; a shape too narrow for that (a table at a
        // database's top-left far out) has its bar just inside its own top edge, below the tab where the tab reaches over it, as
        // the pill gives way to the tab in full (UX walk 3 structure-3: the tab hid the first tables' bars outright; walk 4
        // structure-3: just inside, the tab still lay over their tops), unless that leaves no room in the shape for it.
        var start = start()
        if start > 0 {
            let room = bounds.width - start
            if room >= max(wanted / 2, narrowest / zoom) {
                width = min(wanted, room)
            } else {
                start = selected && bounds.width * zoom >= handleReach + narrowest ? handleReach / zoom : 0
                width = min(wanted, bounds.width - start)
                top = bounds.minY + insideGap / zoom
                if let tab = tabs()?.offsetBy(dx: offset.x, dy: offset.y), tab.maxY > top, tab.minX < bounds.minX + width {
                    let below = tab.maxY + insideGap / zoom
                    if below + height <= bounds.maxY { top = below }
                }
            }
        }
        return (CGRect(x: row.minX + start, y: top, width: width, height: height), found.color)
    }
}

/// The bars of the shapes in view, by color: each color's filled at once, so a board of hundreds costs a fill a color.
struct TitleBars {
    private var plain: [CGRect] = []
    private var tinted: [NSColor: [CGRect]] = [:]

    mutating func add(_ bar: (rect: CGRect, color: NSColor?)) {
        if let color = bar.color { tinted[color, default: []].append(bar.rect) } else { plain.append(bar.rect) }
    }

    /// `zoom`: a bar thinner than `squareBelow` view points has corners too small to see, so it is filled as a plain rect, all of a
    /// color in one call (a board of thousands far out is a bar a table: a path each cost more than the rest of the frame).
    @MainActor func fill(in cg: CGContext, zoom: CGFloat) {
        func fill(_ rects: [CGRect], _ color: NSColor) {
            guard let first = rects.first else { return }
            cg.setFillColor(color.cgColor)
            if first.height * zoom < TitleBar.squareBelow { return cg.fill(rects) }
            for rect in rects {
                let radius = rect.height / 2
                cg.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            }
            cg.fillPath()
        }
        fill(plain, TitleBar.fill)
        for (color, rects) in tinted { fill(rects, color) }
    }
}

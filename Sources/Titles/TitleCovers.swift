import AppKit
import Canvas

/// A title on its shape, zoomed out: a shape the canvas draws as a skeleton (`editor.drawsSkeleton(of:)`,
/// below the editor's `skeletonZoom`, 35%) shows no adornments, and so no pill, so its title is said
/// on the shape itself, as large as the shape's room allows (a cover), where it reads from afar.
/// Titles draws it, over every shape, in one overlay, after the shapes and their outlines: on a
/// frame, which holds shapes, it can't be hidden by what the frame holds.
///
/// A cover is the title in white on a dark plate, the pill's look made large, so it reads on a
/// note's yellow, a card's white, a frame's surface and a subboard's indigo alike, in either
/// appearance. Its text is as big as fits the shape (`TitleCoverStyle.minimumFontSize` to
/// `maximumFontSize`, view points) wrapped on as many lines as the shape has room for, centered on
/// the shape, or at the top left of a container (a frame), where its pill was. A title that doesn't
/// fit ends in "…": cut to `maximumCharacters` before anything is laid out, so a title of
/// thousands of characters costs what one of a hundred does, and then wherever the shape's room
/// ends, the last line truncated as AppKit truncates it. Never drawn outside its shape; a shape too
/// small on screen to say anything in (`smallestShape`) gets none, and neither does an untitled one
/// (a placeholder is for grabbing a shape by, and a skeleton has no pill) nor a kind that shows no
/// pill (`pill: false`: it draws its own title).
@MainActor
enum TitleCoverStyle {
    /// The least a shape is on screen, in view points, to have a cover: below it there's no room
    /// for a word at the smallest size, only for an ellipsis (and a card, wide and short, 15 points
    /// tall is the least that holds a line of it and its plate).
    static let smallestShape = CGSize(width: 48, height: 15)
    /// Between a shape's edge and its cover's plate, where the shape has room for it: a short
    /// shape's gives way to a line of text.
    static let inset: CGFloat = 3
    /// Between the plate's edge and its text.
    static let padding = CGSize(width: 5, height: 2)
    static let minimumFontSize: CGFloat = 9
    static let maximumFontSize: CGFloat = 30
    /// The title's characters laid out, at most: what's past them is the ellipsis.
    static let maximumCharacters = 120
    /// How much of the room the text fills, at the size it's given: a wrapped paragraph never packs
    /// its lines solid.
    static let fill: CGFloat = 0.7
    /// A word longer than this, in columns, is taken as no longer: it breaks wherever the line does.
    static let longestWord = 16
    static let cornerRadius: CGFloat = 9
    /// A word's measured width may be this much past what its columns say, as the average column
    /// is only the average: its line is made wide enough, so a word isn't broken that needn't be.
    static let wordSlack: CGFloat = 1.15
    /// The plate: the title's pill's dark gray, so the two read as one thing, and white text.
    static let plateColor = NSColor(white: 0.25, alpha: 0.9)
    static let weight = NSFont.Weight.semibold
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

    /// The columns of the title's longest word, a word being what whitespace separates.
    private static func longestWordColumns(of text: String) -> Int {
        var longest = 0, current = 0
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                longest = max(longest, current)
                current = 0
            } else {
                current += SkeletonText.columns(of: scalar)
            }
        }
        return min(longestWord, max(longest, current))
    }

    // MARK: Where

    /// A cover laid out for a shape `shape` view points across: the plate, and the text in it, from
    /// the shape's top-left corner, in view points; nil if the shape is too small for one.
    struct Layout {
        let text: String
        let string: NSAttributedString
        let fontSize: CGFloat
        let plate: CGRect
        let textRect: CGRect
    }

    /// `atTop`: a container's, at its top left, where its title's pill goes; else centered.
    ///
    /// The size is the largest the title fills the room at (`fill` of it, the room being the shape
    /// less the inset and the plate's padding on every side, at the font's measured advance and line height, as
    /// the title's columns would be set), never one that makes its longest word wider than a line
    /// or a line taller than the room, and within the font sizes it's drawn at: a title that's too
    /// long for that is cut where the room ends, by its last line's ellipsis. The plate then
    /// is as large as the text the room gives it.
    static func layout(of title: String, in shape: CGSize, atTop: Bool) -> Layout? {
        guard shape.width >= smallestShape.width, shape.height >= smallestShape.height else { return nil }
        let metrics = Self.metrics
        // A line of the smallest size and its plate: what a shape less than that is has no room for.
        let line = minimumFontSize * metrics.lineHeight
        guard shape.height >= 2 * padding.height + line else { return nil }
        // The inset gives way where the shape is short.
        let edge = max(0, min(inset, (shape.height - 2 * padding.height - line) / 2))
        let room = CGSize(width: shape.width - 2 * (edge + padding.width), height: shape.height - 2 * (edge + padding.height))
        guard room.width > 0, room.height > line - 0.01 else { return nil }
        let text = shown(title)
        let columns = CGFloat(max(1, SkeletonText.columns(of: text)))
        let word = CGFloat(max(1, longestWordColumns(of: text)))
        let byArea = (fill * room.width * room.height / (columns * metrics.advance * metrics.lineHeight)).squareRoot()
        let size = max(minimumFontSize, min(maximumFontSize, byArea, room.width / (word * metrics.advance * wordSlack), room.height / metrics.lineHeight))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ])
        // As large as the text is where the room cuts it, to whole points: a wrapped line may need
        // the width it was measured at, so the text is drawn in a point more.
        let bound = string.boundingRect(with: room, options: options)
        let used = CGSize(width: min(room.width, bound.width.rounded(.up)), height: min(room.height, bound.height.rounded(.up)))
        let plate = CGSize(width: used.width + 2 * padding.width, height: used.height + 2 * padding.height)
        let origin = atTop ? CGPoint(x: edge, y: edge)
                           : CGPoint(x: ((shape.width - plate.width) / 2).rounded(), y: ((shape.height - plate.height) / 2).rounded())
        let plateRect = CGRect(origin: origin, size: plate)
        return Layout(text: text, string: string, fontSize: size, plate: plateRect,
                      textRect: CGRect(x: origin.x + padding.width, y: origin.y + padding.height, width: used.width + 1, height: used.height))
    }

    /// A shape's cover and where the shape is (its bounds, world units), if it has one: it's titled
    /// and shows a title, and is big enough on screen. The shape's, not whether it's drawn as a
    /// skeleton, which the caller asks.
    static func cover(of record: AnyShapeRecord, in shapes: ShapeContext, registry: Registry) -> (layout: Layout, bounds: CGRect)? {
        guard !record.isOpaque, let geometry = shapes.geometry(of: record.id), !geometry.outline.isEmpty, !geometry.bounds.isNull else { return nil }
        let bounds = geometry.bounds, zoom = shapes.zoom
        let size = CGSize(width: bounds.width * zoom, height: bounds.height * zoom)
        guard size.width >= smallestShape.width, size.height >= smallestShape.height,
              let title = registry.titleCover(of: record),
              let laidOut = layout(of: title, in: size, atTop: registry.isContainer(record)) else { return nil }
        return (laidOut, bounds)
    }
}

/// A shape's cover as the canvas lays it out now, for what asks where it is.
public struct TitleCover: Equatable {
    /// What it says: the shape's title as it reads, or its first `TitleCoverStyle.maximumCharacters`
    /// characters and "…" if it's longer. The text drawn is this, set where its room ends.
    public let text: String
    /// Its plate, in world units, where the shape is (not where a shake draws it).
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
              let found = TitleCoverStyle.cover(of: record, in: shapes, registry: registry) else { return nil }
        let zoom = shapes.zoom, plate = found.layout.plate
        return TitleCover(text: found.layout.text,
                          rect: CGRect(x: found.bounds.minX + plate.minX / zoom, y: found.bounds.minY + plate.minY / zoom,
                                       width: plate.width / zoom, height: plate.height / zoom),
                          fontSize: found.layout.fontSize)
    }
}

/// Every shape drawn as a skeleton's cover, above the shapes, back to front. Nothing when shapes
/// are drawn in full; a shape too small on screen is passed over by its kept bounds alone, so a board
/// of thousands zoomed out far costs a look at each shape in view. A shape drawn away from where it
/// is (a shake) has its cover there.
struct TitleCoverOverlay: CanvasOverlay {
    var space: OverlaySpace { .world }

    func draw(in context: OverlayContext) {
        guard context.drawsSkeletons else { return }
        let editor = context.editor, cg = context.cg, scale = 1 / context.zoom
        let reach = context.worldDrawingReach
        let visible = context.visibleRect.insetBy(dx: -reach, dy: -reach)
        for record in editor.paintOrder(in: visible) where context.drawsSkeleton(of: record.id) {
            guard let found = TitleCoverStyle.cover(of: record, in: context.shapes, registry: editor.registry) else { continue }
            let offset = context.worldDrawingOffset(of: record.id)
            let plate = found.layout.plate
            cg.saveGState()
            cg.translateBy(x: found.bounds.minX + offset.x, y: found.bounds.minY + offset.y)
            // From here in view points, y down, from the shape's top-left corner.
            cg.scaleBy(x: scale, y: scale)
            let radius = min(plate.height / 2, TitleCoverStyle.cornerRadius)
            cg.addPath(CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil))
            cg.setFillColor(TitleCoverStyle.plateColor.cgColor)
            cg.fillPath()
            found.layout.string.draw(with: found.layout.textRect, options: TitleCoverStyle.options)
            cg.restoreGState()
        }
    }
}

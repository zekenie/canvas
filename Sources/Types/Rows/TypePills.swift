import AppKit
import Canvas
import Titles

// A relationship type drawn as a pill: a layout input Types provides for every shape that holds a schema and the
// mark, which a kind that draws a type's note reads (StickyNotes lays the note out at the pill's size, centered on
// the box it stores, and paints the capsule from the input alone). Nothing of it is stored: the title and the
// schema are the shape's own, and the pill is what they say.

/// What a relationship type is drawn as: its name (or none), how many fields it gives its relationships, and the size
/// the pill is, which is the text measured. Provided as `TypeRows.pill`.
public struct TypePill: Hashable, Sendable {
    /// The name, as it reads; nil while untitled.
    public var title: String?
    /// How many fields the type has, its chain's: `owner · 2`; none shows nothing.
    public var fields: Int
    /// The capsule's size, world units.
    public var size: CGSize

    public init(title: String?, fields: Int, size: CGSize) {
        self.title = title
        self.fields = fields
        self.size = size
    }

    /// What it says: its name, or the dimmed placeholder an untitled type has.
    @MainActor public var text: String { title ?? TypesStyle.untitledType }
}

extension TypeRows {
    /// How a relationship type is drawn: a pill, in place of a note's paper, words and rows. Types provides it (`RowBook`),
    /// for the kinds that say where their rows go (`typeRows(drawnIn:)`), whether the type has words or fields or not;
    /// absent for every other shape, so a plain empty type stays a full note. A change of the title or the schema is the
    /// shape's own commit; a change that comes from its chain (a type it builds on) is announced with the rest of that
    /// type's layout.
    public static let pill = LayoutInputKey<TypePill>("type-pill")
}

extension TypesStyle {
    /// The pill's height, the room between its ends and its text, and the least and most it is wide (past it, the text
    /// ends in an ellipsis, its count first).
    public static let pillHeight: CGFloat = 24
    public static let pillPadding: CGFloat = 12
    public static let pillMinimumWidth: CGFloat = 40
    public static let pillMaximumWidth: CGFloat = 240
    /// Its text: a name in white semibold at the title pill's family, the count after a middle dot in the same ink, softer.
    public static let pillFontSize: CGFloat = 13
    public static let pillCountStrength: CGFloat = 0.65
    public static let pillSeparator = " · "
    /// A placeholder's ink: the pill's, this strong.
    public static let pillPlaceholderStrength: CGFloat = 0.55
    /// How many pills' widths are kept; past it the lot is let go.
    static let pillWidthsCapacity = 4_096
}

@MainActor
public enum TypePills {
    public static let font = NSFont.systemFont(ofSize: TypesStyle.pillFontSize, weight: .semibold)

    /// The text of a pill as drawn, in `ink`: the name (dimmed while it is a placeholder), then the count after a dot,
    /// softer. `showsTitle: false` keeps the name's room and leaves its ink out, for an editing view that draws it in
    /// its place, so the count stays where it is.
    public static func string(of pill: TypePill, ink: NSColor, showsTitle: Bool = true) -> NSAttributedString {
        let name = pill.title == nil ? ink.withAlphaComponent(ink.alphaComponent * TypesStyle.pillPlaceholderStrength) : ink
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: showsTitle ? name : NSColor.clear]
        let string = NSMutableAttributedString(string: pill.text, attributes: attributes)
        if pill.fields > 0 {
            var count = attributes
            count[.foregroundColor] = ink.withAlphaComponent(ink.alphaComponent * TypesStyle.pillCountStrength)
            string.append(NSAttributedString(string: TypesStyle.pillSeparator + String(pill.fields), attributes: count))
        }
        return string
    }

    private struct Key: Hashable {
        let text: String
        let fields: Int
    }
    private static var widths: [Key: CGFloat] = [:]

    /// The pill for a name and a count: its size is its text measured, one line, never narrower than
    /// `TypesStyle.pillMinimumWidth` or wider than `pillMaximumWidth`. What is measured is kept by what it says.
    public static func pill(title: String?, fields: Int) -> TypePill {
        let probe = TypePill(title: title, fields: fields, size: .zero)
        let key = Key(text: probe.text, fields: fields)
        var width = widths[key]
        if width == nil {
            if widths.count >= TypesStyle.pillWidthsCapacity { widths.removeAll() }
            let line = CTLineCreateWithAttributedString(string(of: probe, ink: .white))
            let measured = ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))) + 2 * TypesStyle.pillPadding
            width = min(TypesStyle.pillMaximumWidth, max(TypesStyle.pillMinimumWidth, measured))
            widths[key] = width
        }
        return TypePill(title: title, fields: fields, size: CGSize(width: width ?? TypesStyle.pillMinimumWidth, height: TypesStyle.pillHeight))
    }

    /// Draws a pill's text in `rect`, the capsule's frame (the context has y down): one line from the padding in, centered
    /// across, ending in an ellipsis where the width gives way, the count going first. The capsule is the caller's.
    public static func draw(_ pill: TypePill, ink: NSColor, in rect: CGRect, showsTitle: Bool = true, to cg: CGContext) {
        let resolved = NSColor(cgColor: ink.cgColor) ?? ink
        let string = string(of: pill, ink: resolved, showsTitle: showsTitle)
        var line = CTLineCreateWithAttributedString(string)
        let room = rect.width - 2 * TypesStyle.pillPadding
        if CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > room {
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [.font: font, .foregroundColor: resolved]))
            line = CTLineCreateTruncatedLine(line, Double(max(0, room)), .end, token) ?? token
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        cg.saveGState()
        cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        cg.textPosition = CGPoint(x: rect.minX + TypesStyle.pillPadding, y: rect.midY + (ascent - descent) / 2)
        CTLineDraw(line, cg)
        cg.textMatrix = .identity
        cg.restoreGState()
    }
}

extension RowBook {
    /// How a relationship type is drawn now, in the file shown: its pill; nil for a shape that is not one. Tests, the
    /// editing view.
    public func pill(of id: ShapeID) -> TypePill? {
        editor?.shapeContext.layoutInput(TypeRows.pill, for: id)
    }

    /// The provider of `TypeRows.pill`, cheapest test first (a board first shown asks it of every note): a relationship
    /// type (the mark on a shape that holds `schema`) of a kind that draws a type's rows, words or fields or not.
    /// Mid-transaction (a draw, a paste, `/is-a` itself) its fields are resolved over the shapes as the transaction
    /// leaves them, as the rows' extent is.
    static func providePill(_ record: AnyShapeRecord, _ reading: LayoutReading) -> TypePill? {
        guard record[RelationshipProperty.self] == true, record[TypeSchemaProperty.self] != nil else { return nil }
        guard let book = reading.service(RowBook.self), book.kinds.contains(record.kind) else { return nil }
        return TypePills.pill(title: TitleProperty.folded(record[TitleProperty.self]), fields: book.fieldCount(of: record, reading: reading))
    }

    /// How many fields a type's note gives its relationships: what its chain resolves to, from what is kept for the
    /// committed file, else resolved over the reading.
    private func fieldCount(of record: AnyShapeRecord, reading: LayoutReading) -> Int {
        guard let book = editor?.fieldBook else { return 0 }
        guard reading.isCommitted else {
            return Chain.resolve(types: [record.id], in: ReadingTypes(book: book, reading: reading, record: record)).fields.count
        }
        return book.fields(types: [record.id]).fields.count
    }
}

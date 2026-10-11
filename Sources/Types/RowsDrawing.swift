import Adornments
import AppKit
import Canvas
import CoreText

// A shape's rows drawn by its kind's render (`drawTypeRows`): what a type's note has under its words
// (a row for each field, its kind at the right; or the reading, the reason it failed), and, on a note that
// is one, the names of its fields. Text is kept as Core Text lines, not typeset each frame; a type's chip
// in a row is Adornments' own, drawn as the chip above a note is.

extension TypesStyle {
    /// Zoomed out, a row is a bar this tall, as wide as its name; a fold is three dots this big, this far apart.
    public static let skeletonRowBarHeight: CGFloat = 8
    public static let skeletonFoldDot: CGFloat = 4
    public static let skeletonFoldDotGap: CGFloat = 4
    /// A name's bar is as wide as its columns, each this wide: the skeleton's, at the rows' font.
    static let skeletonRowColumn = SkeletonTextMetrics.systemFontColumn * rowFontSize
    /// Below this zoom a row is under three pixels tall and its bar is not drawn at all.
    public static let skeletonRowsZoom: CGFloat = 0.14
    /// A note that is one, zoomed out: a filled row's value is a bar this share of the value column (as wide as a
    /// box for a box), never as wide as what it says; a wrong one is red.
    public static let skeletonValueShare: CGFloat = 0.7
    static let skeletonWrong = CGColor(srgbRed: 0.86, green: 0.15, blue: 0.15, alpha: 0.55)
    /// A yes or no's box: this across, with corners this round.
    public static let boxSize: CGFloat = 14
    static let boxCorner: CGFloat = 3
    /// A wrong value's wavy line: this far under the row's middle, 1 point thick, this long a wave, this high.
    static let waveDrop: CGFloat = 8
    static let wavePeriod: CGFloat = 4
    static let waveAmplitude: CGFloat = 1.25
    /// The outline round a row's value that has the caret or whose card is open: this thick, this far out,
    /// at least this wide, with these corners.
    static let fieldFocusWidth: CGFloat = 1.5
    static let fieldFocusOutset: CGFloat = 4
    static let fieldFocusMinimum: CGFloat = 44
    static let fieldFocusCorner: CGFloat = 4

    /// A note's paper is light in both appearances, so the rows' inks are fixed colors, as the highlights
    /// are: the note's ink, and its strengths.
    static let rowInk = NSColor(white: 0.12, alpha: 1)
    static let faintStrength: CGFloat = 0.45
    static let mutedStrength: CGFloat = 0.55
    /// The rule under a type's words, and the reading state's bars: black at these strengths.
    static let rowsRule = CGColor(gray: 0, alpha: 0.12)
    static let spotBar = CGColor(gray: 0, alpha: 0.10)
    /// A needed field's dot: the same amber as a rule's highlight and a warning.
    static let neededInk = NSColor(srgbRed: 0.96, green: 0.62, blue: 0.04, alpha: 1)
    /// Text that says a needed value is missing: the dot's amber, darkened until it reads at 4.5 to 1 on a note's
    /// yellow and on white (the dot itself is a mark, not text).
    static let neededTextInk = NSColor(srgbRed: 0.55, green: 0.32, blue: 0.0, alpha: 1)
    /// A wrong value's red: as dark as it takes to read at 4.5 to 1 on a note's yellow and on white.
    static let wrongInk = NSColor(srgbRed: 0.74, green: 0.10, blue: 0.10, alpha: 1)
    /// An action's words (`Retry`, `Settings…`): the accent blue.
    static let linkInk = NSColor(srgbRed: 0.0, green: 0.38, blue: 0.85, alpha: 1)
    /// A tick for rows more than one type gave.
    static let manyTick = grayChip
}

/// The lines of text rows draw, kept by their text, style and the width they are cut to: Core Text lines,
/// made once and drawn each frame. 8,192 are kept, then the lot is let go.
@MainActor
enum FieldLines {
    enum Style: Int, CaseIterable {
        case name, faint, kind, muted, value, empty, needed, neededInside, wrong, link
    }

    struct Line {
        let line: CTLine
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
    }

    private struct Key: Hashable {
        let text: String
        let style: Style
        let cut: CGFloat
    }

    static let capacity = 8_192
    private static var kept: [Key: Line] = [:]
    private static var attributes: [Style: [NSAttributedString.Key: Any]] = [:]

    #if DEBUG
    /// How many lines have been made (debug builds): a frame that draws what it drew makes none.
    static private(set) var made = 0
    #endif

    /// `text` in `style`, cut to `width` with an ellipsis when it is wider (never cut for nil).
    static func line(_ text: String, _ style: Style, cutTo width: CGFloat? = nil) -> Line {
        let key = Key(text: text, style: style, cut: width ?? -1)
        if let known = kept[key] { return known }
        if kept.count >= capacity { kept.removeAll(keepingCapacity: true) }
        #if DEBUG
        made += 1
        #endif
        let made = make(text, style, cutTo: width)
        kept[key] = made
        return made
    }

    static func width(of text: String, _ style: Style) -> CGFloat { line(text, style).width }

    /// Draws `line` with its left at `x`, centered on `midY` (the context has y down).
    static func draw(_ line: Line, at x: CGFloat, midY: CGFloat, in cg: CGContext) {
        cg.saveGState()
        cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        cg.textPosition = CGPoint(x: x, y: midY + (line.ascent - line.descent) / 2)
        CTLineDraw(line.line, cg)
        cg.textMatrix = .identity
        cg.restoreGState()
    }

    private static func make(_ text: String, _ style: Style, cutTo width: CGFloat?) -> Line {
        let attributes = self.attributes(of: style)
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        if let width, CTLineGetTypographicBounds(line, nil, nil, nil) > width {
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            line = CTLineCreateTruncatedLine(line, Double(max(0, width)), .end, token) ?? token
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let measured = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return Line(line: line, width: CGFloat(measured), ascent: ascent, descent: descent)
    }

    private static func attributes(of style: Style) -> [NSAttributedString.Key: Any] {
        if let known = attributes[style] { return known }
        let regular = NSFont.systemFont(ofSize: TypesStyle.rowFontSize)
        let italic = NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask)
        let font: NSFont, color: NSColor
        switch style {
        case .name, .value: (font, color) = (regular, TypesStyle.rowInk)
        case .faint: (font, color) = (regular, TypesStyle.rowInk.withAlphaComponent(TypesStyle.faintStrength))
        case .kind, .muted: (font, color) = (regular, TypesStyle.rowInk.withAlphaComponent(TypesStyle.mutedStrength))
        case .empty: (font, color) = (italic, TypesStyle.rowInk.withAlphaComponent(TypesStyle.faintStrength))
        case .needed: (font, color) = (italic, TypesStyle.neededTextInk)
        case .neededInside: (font, color) = (regular, TypesStyle.neededTextInk)
        case .wrong: (font, color) = (regular, TypesStyle.wrongInk)
        case .link: (font, color) = (regular, TypesStyle.linkInk)
        }
        let made: [NSAttributedString.Key: Any] = [.font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor]
        attributes[style] = made
        return made
    }
}

/// A failed read's one row: the reason, cut to leave its action room, and the action's words 8 points after it.
/// The render draws it and a click finds the words by it.
@MainActor
struct FailureLayout {
    let reason: FieldLines.Line
    let action: FieldLines.Line?
    /// Where the action's words start.
    let actionX: CGFloat
    private let row: CGRect

    init(_ reason: String, action kind: RowSpot.Action?, in row: CGRect) {
        self.row = row
        if let kind {
            let words = FieldLines.line(kind == .retry ? FieldWords.retry : FieldWords.settings, .link)
            let line = FieldLines.line(reason, .kind, cutTo: max(0, row.width - words.width - TypesStyle.actionGap))
            (self.reason, action, actionX) = (line, words, row.minX + line.width + TypesStyle.actionGap)
        } else {
            (self.reason, action, actionX) = (FieldLines.line(reason, .kind, cutTo: row.width), nil, row.minX)
        }
    }

    /// The action's words, a whole row tall: what a click on them is.
    var actionRect: CGRect? {
        action.map { CGRect(x: actionX, y: row.minY, width: $0.width, height: row.height) }
    }
}

extension RenderContext {
    /// Draws the shape's rows (or what its rows' spot says) in `block`, the rect its kind gives them
    /// (`typeRows(drawnIn:)`). Drawn while the shape is edited too: the editor has no background.
    public func drawTypeRows<P: ShapeProps>(of shape: ShapeRecord<P>, in block: CGRect) {
        guard let book = service(RowBook.self) else { return }
        book.draw(AnyShapeRecord(shape), in: block, isEditing: isEditing, to: cg)
    }
}

extension RenderContext {
    /// Whether rows' bars are drawn at this zoom: a kind's skeleton asks before it works out where its rows are.
    public var showsTypeRowBars: Bool { zoom >= TypesStyle.skeletonRowsZoom }

    /// The shape's rows zoomed out (a kind's skeleton): a bar for each row's name, as wide as its columns (counted, never laid out: a skeleton shows no letters); three dots
    /// for a fold; the reading state's three bars; one bar for `No fields` and for a reason. Nothing below
    /// `TypesStyle.skeletonRowsZoom`. It reads the book's kept template and the spot, nothing that parses or
    /// lays out text.
    public func fillTypeRowBars<P: ShapeProps>(of shape: ShapeRecord<P>, in block: CGRect) {
        guard showsTypeRowBars, let book = service(RowBook.self) else { return }
        let bars = book.bars(of: AnyShapeRecord(shape), in: block)
        fillSkeletonText(bars.plain)
        guard !bars.wrong.isEmpty else { return }
        cg.saveGState()
        for bar in bars.wrong { cg.addRect(bar) }
        cg.setFillColor(TypesStyle.skeletonWrong)
        cg.fillPath()
        cg.restoreGState()
    }
}

/// What a skeleton draws for rows: gray bars, and the red ones of a wrong value.
struct RowBars {
    var plain: [CGRect] = []
    var wrong: [CGRect] = []
}

extension RowBook {
    /// The bars a skeleton draws for a shape's rows in `block`: a note that is one adds a bar for each row that holds
    /// a value, red where the check marks it wrong. Nothing here lays text out.
    func bars(of record: AnyShapeRecord, in block: CGRect) -> RowBars {
        guard let subject = subject(of: record), kinds.contains(record.kind) else { return RowBars() }
        let template = template(subject)
        let spot: RowSpot
        if subject.isType {
            guard let known = self.spot(of: record, template: template) else { return RowBars() }
            spot = known
        } else {
            guard !template.items.isEmpty else { return RowBars() }
            spot = .rows
        }
        let geometry = RowGeometry(block: block, hasLead: hasWords(record), longestName: template.nameColumn)
        func bar(_ row: Int, width: CGFloat) -> CGRect {
            let rect = geometry.rect(row)
            return CGRect(x: rect.minX, y: rect.midY - TypesStyle.skeletonRowBarHeight / 2, width: max(1, width), height: TypesStyle.skeletonRowBarHeight)
        }
        var bars = RowBars()
        switch spot {
        case .reading:
            bars.plain = TypesStyle.spotBarShares.enumerated().map { bar($0.offset, width: block.width * $0.element) }
        case .noFields, .failed:
            bars.plain = [bar(0, width: block.width * TypesStyle.spotBarShares[0])]
        case .rows:
            bars.plain.reserveCapacity(template.items.count * (subject.isType ? 1 : 2))
            let values = subject.isType ? nil : record[FieldValuesProperty.self]
            let check = subject.isType ? FieldCheck.clean : self.check(of: record)
            for (row, item) in template.items.enumerated() {
                switch item {
                case .field(let field):
                    bars.plain.append(bar(row, width: min(field.barWidth, TypesStyle.nameShare * block.width)))
                    guard let values, values.value(at: field.path) != nil else { continue }
                    let value = geometry.valueRect(row)
                    var rect = bar(row, width: field.kind == .plain(.yesNo) ? TypesStyle.boxSize : value.width * TypesStyle.skeletonValueShare)
                    rect.origin.x = value.minX
                    if check.mark(at: field.path) == .wrong { bars.wrong.append(rect) } else { bars.plain.append(rect) }
                case .fold(let fold):
                    let rect = geometry.rect(row)
                    let marked = !check.problems.isEmpty && fold.folded.contains { check.mark(at: FieldPath(field: $0.field.name)) == .wrong }
                    for dot in 0..<3 {
                        let shape = CGRect(x: rect.minX + CGFloat(dot) * (TypesStyle.skeletonFoldDot + TypesStyle.skeletonFoldDotGap),
                                           y: rect.midY - TypesStyle.skeletonFoldDot / 2, width: TypesStyle.skeletonFoldDot, height: TypesStyle.skeletonFoldDot)
                        if marked { bars.wrong.append(shape) } else { bars.plain.append(shape) }
                    }
                }
            }
        }
        return bars
    }
}

extension RowBook {
    /// Draws a shape's rows in `block`, clipped to it widened at the left by the tick's room.
    func draw(_ record: AnyShapeRecord, in block: CGRect, isEditing: Bool, to cg: CGContext) {
        guard let subject = subject(of: record), kinds.contains(record.kind) else { return }
        let template = template(subject)
        let spot: RowSpot?
        if subject.isType {
            spot = self.spot(of: record, template: template)
            guard spot != nil else { return }
        } else {
            spot = .rows
            guard !template.items.isEmpty else { return }
        }
        let hasWords = hasWords(record)
        let geometry = RowGeometry(block: block, hasLead: hasWords, longestName: template.nameColumn)
        let reach = TypesStyle.tickInset + TypesStyle.tickWidth
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.clip(to: CGRect(x: block.minX - reach, y: block.minY, width: block.width + reach, height: block.height))
        if hasWords {
            cg.setFillColor(TypesStyle.rowsRule)
            cg.fill(CGRect(x: block.minX, y: block.minY, width: block.width, height: 1))
        }
        switch spot {
        case .reading?: drawReading(in: geometry, to: cg)
        case .noFields?: FieldLines.draw(FieldLines.line(FieldWords.noFields, .kind), at: block.minX, midY: geometry.rect(0).midY, in: cg)
        case .failed(let reason, let action)?: drawFailure(reason, action: action, in: geometry, to: cg)
        case .rows? where subject.isType: drawRows(of: template, in: geometry, to: cg)
        case .rows?: drawValues(of: record, template: template, subject: subject, in: block, isEditing: isEditing, to: cg)
        case nil: break
        }
    }

    private func drawReading(in geometry: RowGeometry, to cg: CGContext) {
        cg.setFillColor(TypesStyle.spotBar)
        for (row, share) in TypesStyle.spotBarShares.enumerated() {
            let rect = geometry.rect(row)
            let bar = CGRect(x: rect.minX, y: rect.midY - TypesStyle.spotBarHeight / 2, width: geometry.block.width * share, height: TypesStyle.spotBarHeight)
            cg.addPath(CGPath(roundedRect: bar, cornerWidth: TypesStyle.spotBarHeight / 2, cornerHeight: TypesStyle.spotBarHeight / 2, transform: nil))
            cg.fillPath()
        }
    }

    private func drawFailure(_ reason: String, action: RowSpot.Action?, in geometry: RowGeometry, to cg: CGContext) {
        let rect = geometry.rect(0)
        let layout = FailureLayout(reason, action: action, in: rect)
        FieldLines.draw(layout.reason, at: rect.minX, midY: rect.midY, in: cg)
        if let words = layout.action { FieldLines.draw(words, at: layout.actionX, midY: rect.midY, in: cg) }
    }

    private func drawRows(of template: RowTemplate, in geometry: RowGeometry, to cg: CGContext) {
        let types = editor?.types
        for (row, item) in template.items.enumerated() {
            let rect = geometry.rect(row), name = geometry.nameRect(row), value = geometry.valueRect(row)
            switch item {
            case .field(let field):
                if let tick = field.tick { drawTick(TypeColors.base(tick), in: rect, to: cg) }
                let dotRoom = field.isNeeded ? TypesStyle.neededDotGap + TypesStyle.neededDotSize : 0
                let line = FieldLines.line(field.name, field.isFaint ? .faint : .name, cutTo: max(0, name.width - dotRoom))
                FieldLines.draw(line, at: name.minX, midY: rect.midY, in: cg)
                if dotRoom > 0 {
                    let dot = CGRect(x: name.minX + line.width + TypesStyle.neededDotGap, y: rect.midY - TypesStyle.neededDotSize / 2,
                                     width: TypesStyle.neededDotSize, height: TypesStyle.neededDotSize)
                    cg.setFillColor(TypesStyle.neededInk.cgColor)
                    cg.fillEllipse(in: dot)
                }
                drawKind(of: field, in: value, midY: rect.midY, types: types, to: cg)
            case .fold(let fold):
                if fold.isMore {
                    FieldLines.draw(FieldLines.line(fold.name + " ›", .kind), at: rect.minX, midY: rect.midY, in: cg)
                } else {
                    drawTick(fold.sources.count == 1 ? TypeColors.base(fold.sources[0]) : TypesStyle.manyTick, in: rect, to: cg)
                    FieldLines.draw(FieldLines.line(fold.name, .faint, cutTo: name.width), at: name.minX, midY: rect.midY, in: cg)
                    let words = FieldLines.line(fold.value + " ›", .kind, cutTo: value.width)
                    FieldLines.draw(words, at: value.maxX - words.width, midY: rect.midY, in: cg)
                }
            }
        }
    }

    func drawTick(_ color: NSColor, in rect: CGRect, to cg: CGContext) {
        cg.setFillColor(color.cgColor)
        cg.fill(CGRect(x: rect.minX - TypesStyle.tickInset, y: rect.minY + 4, width: TypesStyle.tickWidth, height: rect.height - 8))
    }

    /// A type's row at the right: its kind's label, the chip of the type it names, and `›`, from the right.
    private func drawKind(of field: FieldRowTemplate, in value: CGRect, midY: CGFloat, types: TypeIndex?, to cg: CGContext) {
        var right = value.maxX
        if field.opensOnType {
            let chevron = FieldLines.line("›", .kind)
            FieldLines.draw(chevron, at: right - chevron.width, midY: midY, in: cg)
            right -= chevron.width + TypesStyle.partGap
        }
        if let chip = field.chip, let types {
            let label = TypeChips.label(for: TypeLink(chip), in: types)
            let size = label.contentSize
            label.draw(at: CGPoint(x: right - size.width, y: midY - size.height / 2), in: cg)
            right -= size.width + (field.label.isEmpty ? 0 : TypesStyle.partGap)
        }
        guard !field.label.isEmpty else { return }
        let words = FieldLines.line(field.label, .kind, cutTo: max(0, right - value.minX))
        FieldLines.draw(words, at: right - words.width, midY: midY, in: cg)
    }
}

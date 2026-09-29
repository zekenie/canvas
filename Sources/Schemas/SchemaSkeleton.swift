import AppKit
import Canvas

/// The card zoomed out, where its text no longer reads (`CustomSkeleton`, below the editor's
/// `skeletonZoom`): the card, white, with no shadow but a light gray edge inside its frame, where
/// the shadow's edge showed (`SchemaStyle.skeletonEdge`), so a white card on the light canvas still
/// has one; the `{}` as an accent mark where it sits, and a bar for the name; a chip for each field
/// row, with a bar in it for the field's name; and a bar for `+N more` and for the rules line. Five
/// fills, whatever the schema: the edge, the card inside it, the chips, the mark, and every bar in
/// one (`RenderContext.fillSkeletonText`). The card and its chips are square (their corners are
/// rounded by under 3 points here, and a rounded card costs a third more), so its outline is the
/// default, its frame's, exactly.
extension SchemaCardDefinition: CustomSkeleton {
    func renderSkeleton(_ shape: ShapeRecord<SchemaCard>, in context: RenderContext) {
        let cg = context.cg, frame = shape.frame
        cg.setFillColor(SchemaSkeleton.edgeColor)
        cg.fill(frame)
        let edge = SchemaStyle.skeletonEdgeWidth / context.zoom
        let inside = frame.insetBy(dx: edge, dy: edge)
        guard !inside.isEmpty else { return }
        cg.setFillColor(SchemaSkeleton.cardColor)
        cg.fill(inside)
        guard let skeleton = SchemaSkeleton(shape) else { return }
        if skeleton.fieldRows > 0 {
            for row in 0..<skeleton.fieldRows { cg.addRect(skeleton.chip(row)) }
            cg.setFillColor(SchemaSkeleton.chipColor)
            cg.fillPath()
        }
        cg.setFillColor(SchemaSkeleton.accentColor)
        cg.fill(skeleton.mark)
        context.fillSkeletonText(skeleton.bars)
    }
}

/// Where a card's skeleton puts its mark, chips and bars (world units). A frame draws thousands, so
/// nothing is read or measured: they go by the card's reading if one is kept for its text now
/// (`SchemaReadings.held`, which the sync reads as the text changes; `Counts`, counted once a
/// reading: a bar is as long as the columns of the text it stands for, `SkeletonText`, at
/// `SchemaStyle.barAdvance`), and its rows are those the card shows (the overflow rule). Else (its
/// reading went, past `capacity`, or another window read another text for its id) by the card's
/// height, which its rows set (`SchemaCard.height(for:)`), a row for each it has room for, at most
/// what the card shows (8 or more: 6 and `+N more`), with no rules line, and each bar as long as
/// its id says (the same every frame). A card with no fields (a reading kept says so) has no rows'
/// bars, and nothing says why: "No fields" isn't a field.
@MainActor
struct SchemaSkeleton {
    /// What a reading says of its card's skeleton, counted once (`SchemaReadings.skeleton`): the
    /// columns (`SkeletonText`: a wide character, CJK's or an emoji, two) of its name, of the names
    /// of the fields a card can show (a pattern's without its slashes) and of its rules line (none
    /// without fields, where the card says it has none), and how many fields it has.
    struct Counts {
        let title: Int
        let names: [Int]
        let fields: Int
        let rules: Int?

        init(_ document: SchemaDocument) {
            title = SkeletonText.columns(of: document.title ?? SchemaCard.untitled)
            names = document.fields.prefix(SchemaCardMetrics.maxRows).map { SkeletonText.columns(of: $0.name) }
            fields = document.fields.count
            rules = document.fields.isEmpty || document.rules.isEmpty
                ? nil : SkeletonText.columns(of: "Rules " + document.rules.joined(separator: " · "))
        }
    }

    /// The card's colors, made once (the same in both appearances, as the card's are).
    static let cardColor = SchemaStyle.card.cgColor, edgeColor = SchemaStyle.skeletonEdge.cgColor
    static let chipColor = SchemaStyle.chipFill.cgColor, accentColor = SchemaStyle.accent.cgColor

    /// The `{}`, in the accent.
    let mark: CGRect
    /// The field rows, from the first.
    let fieldRows: Int
    private let inner: CGRect
    private let title: CGRect
    private let more: CGRect?
    private let rules: CGRect?
    private let names: [Int]?
    private let id: ShapeID

    /// Nil for a card too small to hold anything, as its layout has nothing inside the padding.
    init?(_ card: ShapeRecord<SchemaCard>) {
        let frame = card.frame, metrics = SchemaCardMetrics.self, style = SchemaStyle.self
        guard frame.width > metrics.padding * 2, frame.height > metrics.padding * 2 else { return nil }
        let inner = frame.insetBy(dx: metrics.padding, dy: metrics.padding)
        self.inner = inner
        id = card.id
        let counts = SchemaReadings.held(for: card)?.skeleton
        names = counts?.names
        let y = inner.minY + (metrics.titleLineHeight - style.titleBarHeight) / 2
        mark = CGRect(x: inner.minX, y: y, width: min(style.markBarWidth, inner.width), height: style.titleBarHeight)
        let x = inner.minX + style.markBarWidth + style.markBarGap
        let columns = counts?.title ?? 5 + Int(Self.byte(0, of: card.id)) % 10
        title = CGRect(x: x, y: y, width: max(0, min(inner.maxX - x, CGFloat(columns) * style.titleBarAdvance)), height: style.titleBarHeight)
        let fit = metrics.rows(fitting: frame.height)
        // Without a reading, a field for each row there's room for: a fitted card is as tall as its rows.
        let overflow = metrics.overflow(fields: counts?.fields ?? fit, hasRules: counts?.rules != nil, fit: fit)
        fieldRows = overflow.fields
        var next = overflow.fields
        if overflow.more > 0 {
            more = Self.line(Self.row(next, in: inner), columns: 6 + Self.digits(overflow.more))
            next += 1
        } else {
            more = nil
        }
        rules = overflow.rules ? counts?.rules.map { Self.line(Self.row(next, in: inner), columns: $0) } : nil
    }

    /// The field row `row`'s chip, as long as its name.
    func chip(_ row: Int) -> CGRect {
        let style = SchemaStyle.self, rect = Self.row(row, in: inner)
        let columns = names?[row] ?? 3 + Int(Self.byte(1 + row, of: id)) % 10
        return CGRect(x: rect.minX, y: rect.minY, width: min(CGFloat(columns) * style.barAdvance + style.chipInset * 2, rect.width * style.barShare),
                      height: rect.height)
    }

    /// Where the text would be: the name's bar, the bar in each field row's chip, then `+N more`'s
    /// and the rules line's, handed over one at a time.
    var bars: Bars { Bars(skeleton: self) }

    /// Main-actor isolated, as what it reads is: handed to the frame's `fillSkeletonText`, on it.
    @MainActor
    struct Bars: @MainActor Sequence, @MainActor IteratorProtocol {
        let skeleton: SchemaSkeleton
        private var index = 0

        init(skeleton: SchemaSkeleton) { self.skeleton = skeleton }

        mutating func next() -> CGRect? {
            defer { index += 1 }
            return skeleton.bar(index)
        }
    }

    /// The `i`th of `bars`, nil past the last.
    private func bar(_ i: Int) -> CGRect? {
        if i == 0 { return title }
        if i <= fieldRows {
            let style = SchemaStyle.self, chip = chip(i - 1)
            return CGRect(x: chip.minX + style.chipInset, y: chip.midY - style.barHeight / 2, width: max(0, chip.width - style.chipInset * 2),
                          height: style.barHeight)
        }
        switch i - fieldRows {
        case 1: return more ?? rules
        case 2: return more == nil ? nil : rules
        default: return nil
        }
    }

    /// The `i`th row's place, as the layout has it.
    private static func row(_ i: Int, in inner: CGRect) -> CGRect {
        let metrics = SchemaCardMetrics.self
        return CGRect(x: inner.minX, y: inner.minY + metrics.titleLineHeight + metrics.headerGap + CGFloat(i) * metrics.rowHeight,
                      width: inner.width, height: metrics.chipHeight)
    }

    /// A line's bar in `row`, from where its text starts (`+N more`, the rules line).
    private static func line(_ row: CGRect, columns: Int) -> CGRect {
        let style = SchemaStyle.self
        return CGRect(x: row.minX + style.chipInset, y: row.midY - style.barHeight / 2,
                      width: max(0, min(CGFloat(columns) * style.barAdvance, row.width - style.chipInset * 2)), height: style.barHeight)
    }

    private static func digits(_ n: Int) -> Int {
        var n = n, digits = 1
        while n >= 10 { n /= 10; digits += 1 }
        return digits
    }

    /// One of the id's bytes, for a length that stays put.
    private static func byte(_ i: Int, of id: ShapeID) -> UInt8 {
        withUnsafeBytes(of: id.rawValue.uuid) { $0[i % 16] }
    }
}

import AppKit
import Canvas
import CoreGraphics

/// What a card shows, decided without drawing, for a card of `size` (world units, from its top-left
/// corner): its title, the rows that fit and what each says, `+N more`, the rules line, or the one
/// line that says why there are no rows. The renderer draws exactly this, and tests read it. Text is
/// measured here, once per schema text and size (`SchemaReadings` keeps it), never per frame.
@MainActor
public struct SchemaCardLayout {
    public enum State: Equatable, Sendable {
        case fields
        /// An object with no fields.
        case empty
        /// The text isn't JSON, first going wrong at this line and column (from 1).
        case invalid(line: Int, column: Int)
        /// JSON, but its root isn't an object.
        case notObject
    }

    /// A top-level field's row: its name in a chip (a `*` if required), what's inside it or what it
    /// can be (its tray), and what it holds (its type) at the row's end.
    public struct Row {
        /// The name as the chip shows it: a pattern property's between slashes, `/^x-/`.
        public let name: String
        public let isRequired: Bool
        public let isPattern: Bool
        /// `{ name · email }`, `[ sku · quantity · price ]`, `pending | paid | +3`, `{ 4 fields }`.
        public let tray: String?
        /// `string`, `email`, `→ money`, `oneOf`; none where the tray says it: an object's braces,
        /// an enum's values or a choice's options between bars.
        public let type: String?
        /// Where the row is, and its chip.
        public let frame: CGRect
        public let chip: CGRect

        let nameText: NSAttributedString
        let nameRect: CGRect
        /// The `*`, after the name as drawn: a name cut short ends in `…*`, still saying it's required.
        let starText: NSAttributedString?
        let starRect: CGRect
        let trayText: NSAttributedString?
        let trayRect: CGRect
        let typeText: NSAttributedString?
        let typeRect: CGRect

        /// The row as it reads: `customer* { name · email }`, `status* pending | paid | +3`.
        public var text: String {
            ([name + (isRequired ? "*" : "")] + [tray, type].compactMap { $0 }).joined(separator: " ")
        }
    }

    public let size: CGSize
    public let state: State
    /// The schema's `"title"`, or `SchemaCard.untitled`.
    public let title: String
    public let isUntitled: Bool
    /// The field rows that fit, from the first.
    public let rows: [Row]
    /// The top-level fields not shown (`+N more` when above 0).
    public let more: Int
    /// The rules line's keywords (`if/then · allOf`), when it shows.
    public let rules: String?
    /// Where there are no rows, why, in the first row's place: `No fields`, `Invalid JSON`, `Not an
    /// object`. Muted, and never red: Validation's outline says what's wrong.
    public let stateLine: String?

    /// Inside the padding; nil for a card too small to hold anything.
    let inner: CGRect?
    let titleText: NSAttributedString
    let titleRect: CGRect
    let stateRow: (text: NSAttributedString, rect: CGRect)?
    let moreRow: (text: NSAttributedString, rect: CGRect, row: CGRect)?
    let rulesRow: (text: NSAttributedString, rect: CGRect, row: CGRect)?

    /// What `card` shows now, as it's drawn: its reading's layout at its size (its last reading
    /// that was a JSON object while its text isn't one, `SchemaReadings.shown`).
    public init(_ card: ShapeRecord<SchemaCard>) {
        self = SchemaReadings.reading(of: card).layout(size: card.frame.size)
    }

    public init(_ document: SchemaDocument, size: CGSize) {
        self.size = size
        let style = SchemaStyle.self, metrics = SchemaCardMetrics.self
        isUntitled = document.title == nil
        title = document.title ?? SchemaCard.untitled
        if let error = document.error {
            state = .invalid(line: error.line, column: error.column)
        } else if !document.isObject {
            state = .notObject
        } else {
            state = document.fields.isEmpty ? .empty : .fields
        }
        switch state {
        case .fields: stateLine = nil
        case .empty: stateLine = "No fields"
        case .invalid: stateLine = "Invalid JSON"
        case .notObject: stateLine = "Not an object"
        }

        let frame = CGRect(origin: .zero, size: size)
        let inner = frame.width > metrics.padding * 2 && frame.height > metrics.padding * 2
            ? frame.insetBy(dx: metrics.padding, dy: metrics.padding) : nil
        self.inner = inner
        let title = NSMutableAttributedString(attributedString: style.text("{}", style.markFont, style.accent, kern: -0.5))
        title.append(style.text(" " + self.title, style.titleFont, isUntitled ? style.secondaryText : style.text))
        titleText = title
        guard let inner else {
            (titleRect, stateRow, rows, more, rules, moreRow, rulesRow) = (.zero, nil, [], 0, nil, nil, nil)
            return
        }
        titleRect = style.centered(title, in: CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: metrics.titleLineHeight))
        let top = inner.minY + metrics.titleLineHeight + metrics.headerGap
        let fit = metrics.rows(fitting: size.height)
        func row(_ i: Int) -> CGRect {
            CGRect(x: inner.minX, y: top + CGFloat(i) * metrics.rowHeight, width: inner.width, height: metrics.chipHeight)
        }

        if let stateLine {
            // Where the first row's text would start, as `+N more` and the rules line do.
            let text = style.text(stateLine, style.metaFont, style.tertiaryText)
            stateRow = fit > 0 ? (text, style.centered(text, in: row(0).insetBy(dx: style.chipInset, dy: 0))) : nil
            (rows, more, rules, moreRow, rulesRow) = ([], 0, nil, nil, nil)
            return
        }
        stateRow = nil

        let overflow = metrics.overflow(fields: document.fields.count, hasRules: !document.rules.isEmpty, fit: fit)
        let shown = overflow.fields
        more = overflow.more
        // Bounded, so a card of any width (a file edited by hand keeps one of 1e21) makes an Int.
        let columns = Int(min((inner.width * style.typeShare) / style.typeAdvance, CGFloat(Int32.max)))
        rows = document.fields.prefix(shown).enumerated().map { i, field in
            SchemaCardLayout.row(field, in: row(i), columns: columns)
        }
        var next = shown
        if more > 0 {
            let text = style.text("+\(more) more", style.metaFont, style.secondaryText)
            let rect = row(next).insetBy(dx: style.chipInset, dy: 0)
            moreRow = (text, style.centered(text, in: rect), rect)
            next += 1
        } else {
            moreRow = nil
        }
        if overflow.rules {
            let rules = document.rules.joined(separator: " · ")
            let line = NSMutableAttributedString(attributedString: style.text("Rules ", style.noteFont, style.tertiaryText))
            line.append(style.text(rules, style.typeFont, style.secondaryText))
            self.rules = rules
            let rect = row(next).insetBy(dx: style.chipInset, dy: 0)
            rulesRow = (line, style.centered(line, in: rect), rect)
        } else {
            rules = nil
            rulesRow = nil
        }
    }

    /// A row: the type label at the end, the chip from the start, the tray between. The tray goes
    /// in only if the row has room for a chip's least and the tray's least beside the label; then
    /// what its brackets or bars say isn't said again at the end (`object`, `object[]`, `enum`,
    /// `oneOf`). A tray that could say only how many it holds (`{ 4 fields }`) never cuts the name
    /// short: without it, the name has the room, and the label is back.
    private static func row(_ field: SchemaField, in rect: CGRect, columns: Int) -> Row {
        let style = SchemaStyle.self
        let name = field.isPattern ? "/\(field.name)/" : field.name
        let fullName = style.text(name, field.isPattern ? style.patternFont : style.nameFont, style.text)
        // Its own run, so cutting the name short never cuts it.
        let starText = field.isRequired ? style.text("*", style.nameFont, style.secondaryText, truncates: false) : nil
        let starWidth = starText?.size().width ?? 0
        let natural = (fullName.size().width + starWidth + style.chipInset * 2).rounded(.up)
        func labelWidth(_ label: String?) -> CGFloat { label.map { style.width(ofType: $0) + style.typeGap } ?? 0 }

        var tray = Tray(field)
        var label = typeLabel(field, tray: tray, columns: columns)
        if tray != nil, rect.width - labelWidth(label) < style.minChipWidth + style.trayGap + style.minTrayWidth {
            tray = nil
            label = typeLabel(field, tray: nil, columns: columns)
        }
        // The name, cut to leave the tray its least, and the tray then only a count: no tray.
        if let shown = tray, natural > rect.width - labelWidth(label) - style.trayGap - style.minTrayWidth,
           shown.line(width: style.minTrayWidth).isCount {
            tray = nil
            label = typeLabel(field, tray: nil, columns: columns)
        }

        var right = rect.maxX
        var typeText: NSAttributedString?, typeRect = CGRect.zero
        if let label {
            let width = style.width(ofType: label)
            let text = style.text(label, style.typeFont, style.secondaryText)
            typeText = text
            typeRect = style.centered(text, in: CGRect(x: rect.maxX - width, y: rect.minY, width: width, height: rect.height))
            right = rect.maxX - width - style.typeGap
        }
        let room = max(0, right - rect.minX)
        // The name comes first, but leaves the tray its least.
        let most = tray == nil ? room : room - style.trayGap - style.minTrayWidth
        let chip = CGRect(x: rect.minX, y: rect.minY, width: max(0, min(natural, most)), height: rect.height)
        let inChip = chip.insetBy(dx: style.chipInset, dy: 0)
        // The name has what the star leaves, and the star follows it where it ends, whole or cut
        // (here, where it's measured: cut as it's drawn, it would end short of its rect, leaving a
        // gap before the star).
        let nameRoom = max(0, inChip.width - starWidth)
        let nameText = starText == nil ? fullName : style.cut(fullName, to: nameRoom)
        let nameRect = style.centered(nameText, in: CGRect(x: inChip.minX, y: inChip.minY, width: nameRoom, height: inChip.height))
        let starRect = starText.map { star in
            let x = nameRect.minX + min(nameText.size().width, nameRect.width)
            return style.centered(star, in: CGRect(x: x, y: inChip.minY, width: max(0, inChip.maxX - x), height: inChip.height))
        } ?? .zero
        var trayText: NSAttributedString?, trayRect = CGRect.zero
        if let tray {
            let x = chip.maxX + style.trayGap
            let text = tray.line(width: right - x).text
            trayText = text
            trayRect = style.centered(text, in: CGRect(x: x, y: rect.minY, width: max(0, right - x), height: rect.height))
        }
        return Row(name: name, isRequired: field.isRequired, isPattern: field.isPattern, tray: trayText?.string, type: label, frame: rect, chip: chip,
                   nameText: nameText, nameRect: nameRect, starText: starText, starRect: starRect, trayText: trayText, trayRect: trayRect, typeText: typeText, typeRect: typeRect)
    }

    /// The label at a row's end: JSON Schema's own words, at most `columns` characters. None where
    /// the tray says it: an object with fields, or an array of them, in brackets; an enum's values or
    /// a choice's options between bars. Too long, it says the type in a word (`array`, `string`),
    /// and only if even that's too long is it cut (the last character `…`).
    static func typeLabel(_ field: SchemaField, tray: Tray?, columns: Int) -> String? {
        let type = field.type
        if tray != nil {
            switch type {
            case .object, .array(of: .object), .enumeration, .choice: return nil
            default: break
            }
        }
        let label = type.label
        guard label.count > columns else { return label }
        let word = type.baseLabel ?? label
        guard word.count > columns else { return word }
        return String(word.prefix(max(1, columns - 1))) + "…"
    }
}

/// What follows a field's chip: its fields in braces (an array's items' in brackets), one with
/// fields of its own marked `{…}`; or what it can be (an enum's values, a `oneOf`'s options)
/// between bars.
@MainActor
struct Tray {
    var open: String, close: String, separator: String
    var items: [(name: String, hasFields: Bool)]
    /// Said instead when not even the first item fits: `4 fields`, `5 values`, `3 options`.
    var count: String
    /// Braces or brackets around fields (not values or options).
    var isFields: Bool

    init?(_ field: SchemaField) {
        func counted(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        switch field.type {
        case .enumeration(let values):
            guard !values.isEmpty else { return nil }
            (open, close, separator, isFields) = ("", "", " | ", false)
            items = values.map { ($0, false) }
            count = counted(values.count, "value")
        case .choice(let combinator, let options):
            guard !options.isEmpty else { return nil }
            (open, close, separator, isFields) = ("", "", combinator == .allOf ? " & " : " | ", false)
            items = options.map { ($0, false) }
            count = counted(options.count, "option")
        case let type:
            let fields = field.fields
            guard !fields.isEmpty else { return nil }
            var isArray = false
            if case .array = type { isArray = true }
            (open, close, separator, isFields) = (isArray ? "[ " : "{ ", isArray ? " ]" : " }", " · ", true)
            items = fields.map { ($0.isPattern ? "/\($0.name)/" : $0.name, $0.hasFields) }
            count = counted(items.count, "field")
        }
    }

    /// `{ name · email }`, `{ street · city · +2 }`, `dog | cat | +3`: as many items as fit whole in
    /// `width`, then how many more; if not even the first fits whole (with that count and the
    /// closing bracket), how many there are: `{ 4 fields }` (`isCount`). One run.
    func line(width: CGFloat) -> (text: NSAttributedString, isCount: Bool) {
        let style = SchemaStyle.self
        func muted(_ s: String) -> NSAttributedString { style.text(s, style.childFont, style.tertiaryText, truncates: false) }
        func item(_ i: (name: String, hasFields: Bool)) -> NSAttributedString {
            let text = NSMutableAttributedString(attributedString: style.text(i.name, style.childFont, style.secondaryText, truncates: false))
            if i.hasFields { text.append(muted(" {…}")) }
            return text
        }
        func tail(_ rest: Int) -> NSAttributedString {
            let text = NSMutableAttributedString()
            if rest > 0 { text.append(muted(separator + "+\(rest)")) }
            text.append(muted(close))
            return text
        }
        let line = NSMutableAttributedString(attributedString: muted(open))
        var shown = 0
        for (i, it) in items.enumerated() {
            let candidate = NSMutableAttributedString(attributedString: line)
            if i > 0 { candidate.append(muted(separator)) }
            candidate.append(item(it))
            if candidate.size().width + tail(items.count - i - 1).size().width > width { break }
            line.setAttributedString(candidate)
            shown += 1
        }
        guard shown > 0 else {
            let text = NSMutableAttributedString(attributedString: muted(open))
            text.append(style.text(count, style.childFont, style.secondaryText, truncates: false))
            text.append(muted(close))
            return (text, true)
        }
        line.append(tail(items.count - shown))
        return (line, false)
    }
}

import AppKit
import CoreGraphics

/// What a card shows, decided without drawing, for a card of `size` (world units, from its top-left
/// corner): its state, its title, the rows that fit and what each says, `+N more`, the rules line.
/// The renderer draws exactly this, and tests read it. Text is measured here, once per schema text
/// and size (`SchemaReadings` keeps it), never per frame.
@MainActor
public struct SchemaCardLayout {
    public enum State: Equatable, Sendable {
        case fields
        /// An object with no fields: the card invites describing one.
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
        /// `string`, `email`, `→ money`, `one of`; none for an object whose tray has its braces.
        public let type: String?
        /// Where the row is, and its chip.
        public let frame: CGRect
        public let chip: CGRect

        let nameText: NSAttributedString
        let nameRect: CGRect
        let trayText: NSAttributedString?
        let trayRect: CGRect
        let typeText: NSAttributedString?
        let typeRect: CGRect

        /// The row as it reads: `customer* { name · email }`, `status* pending | paid | +3 enum`.
        public var text: String {
            ([name + (isRequired ? "*" : "")] + [tray, type].compactMap { $0 }).joined(separator: " ")
        }
    }

    public let size: CGSize
    public let state: State
    /// The schema's `"title"`, or "Untitled Schema".
    public let title: String
    public let isUntitled: Bool
    /// The field rows that fit, from the first.
    public let rows: [Row]
    /// The top-level fields not shown (`+N more` when above 0).
    public let more: Int
    /// The rules line's keywords (`if/then, allOf`), when it shows.
    public let rules: String?
    /// A state's two lines: `Invalid JSON · line 6, column 35`, `Fix it in the details panel`.
    public let stateLines: [String]

    /// Inside the padding; nil for a card too small to hold anything.
    let inner: CGRect?
    let titleText: NSAttributedString
    let titleRect: CGRect
    let stateBox: CGRect?
    let stateTexts: [(text: NSAttributedString, rect: CGRect)]
    let moreRow: (text: NSAttributedString, rect: CGRect, row: CGRect)?
    let rulesRow: (text: NSAttributedString, rect: CGRect)?

    public init(_ document: SchemaDocument, size: CGSize) {
        self.size = size
        let style = SchemaStyle.self, metrics = SchemaCardMetrics.self
        isUntitled = document.title == nil
        title = document.title ?? "Untitled Schema"
        if let error = document.error {
            state = .invalid(line: error.line, column: error.column)
        } else if !document.isObject {
            state = .notObject
        } else {
            state = document.fields.isEmpty ? .empty : .fields
        }
        switch state {
        case .fields: stateLines = []
        case .empty: stateLines = ["Describe it in the details panel", "“A pet: name, species, birth year…”"]
        case .invalid(let line, let column): stateLines = ["Invalid JSON · line \(line), column \(column)", "Fix it in the details panel"]
        case .notObject: stateLines = ["Not an object schema", "Fix it in the details panel"]
        }

        let frame = CGRect(origin: .zero, size: size)
        let inner = frame.width > metrics.padding * 2 && frame.height > metrics.padding * 2
            ? frame.insetBy(dx: metrics.padding, dy: metrics.padding) : nil
        self.inner = inner
        let title = NSMutableAttributedString(attributedString: style.text("{}", style.markFont, style.accent, kern: -0.5))
        title.append(style.text(" " + self.title, style.titleFont, isUntitled ? style.secondaryText : style.text))
        titleText = title
        guard let inner else {
            (titleRect, stateBox, stateTexts, rows, more, rules, moreRow, rulesRow) = (.zero, nil, [], [], 0, nil, nil, nil)
            return
        }
        titleRect = style.centered(title, in: CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: metrics.titleLineHeight))
        let top = inner.minY + metrics.titleLineHeight + metrics.headerGap
        let body = CGRect(x: inner.minX, y: top, width: inner.width, height: max(0, inner.maxY - top))

        guard state == .fields else {
            let box = CGRect(x: body.minX, y: body.minY, width: body.width, height: min(metrics.stateHeight, body.height))
            stateBox = box.height > 0 ? box : nil
            let x = box.minX + style.stateInset, width = box.width - style.stateInset * 2
            stateTexts = box.height > 0 ? [
                style.line(style.text(stateLines[0], style.nameFont, style.secondaryText), at: CGPoint(x: x, y: box.minY + style.stateTitleTop), width: width),
                style.line(style.text(stateLines[1], style.noteFont, style.tertiaryText), at: CGPoint(x: x, y: box.minY + style.stateNoteTop), width: width),
            ] : []
            (rows, more, rules, moreRow, rulesRow) = ([], 0, nil, nil, nil)
            return
        }
        stateBox = nil
        stateTexts = []

        // The overflow rule: as many rows as fit, at most 7; if the fields don't all fit, the last
        // row says how many more, so it's never "+1 more".
        let fit = max(0, Int((body.height + metrics.rowGap) / metrics.rowHeight))
        let slots = min(metrics.maxRows, fit)
        let count = document.fields.count
        let shown = count <= slots ? count : max(0, slots - 1)
        more = slots > 0 ? count - shown : 0
        func row(_ i: Int) -> CGRect {
            CGRect(x: inner.minX, y: top + CGFloat(i) * metrics.rowHeight, width: inner.width, height: metrics.chipHeight)
        }
        let columns = Int((inner.width * style.typeShare) / style.typeAdvance)
        rows = document.fields.prefix(shown).enumerated().map { i, field in
            SchemaCardLayout.row(field, in: row(i), columns: columns)
        }
        var next = shown
        if more > 0 {
            let text = style.text("+\(more) more", style.nameFont, style.secondaryText)
            let rect = row(next).insetBy(dx: style.chipInset, dy: 0)
            moreRow = (text, style.centered(text, in: rect), rect)
            next += 1
        } else {
            moreRow = nil
        }
        if !document.rules.isEmpty, next < fit {
            let rules = document.rules.joined(separator: ", ")
            let line = NSMutableAttributedString(attributedString: style.text("Rules  ", style.noteFont, style.tertiaryText))
            line.append(style.text(rules, style.typeFont, style.secondaryText))
            self.rules = rules
            rulesRow = (line, style.centered(line, in: row(next).insetBy(dx: style.chipInset, dy: 0)))
        } else {
            rules = nil
            rulesRow = nil
        }
    }

    /// A row: the type label at the end, the chip from the start, the tray between. The tray goes
    /// in only if the row has room for a chip's least and the tray's least beside the label; then
    /// an object or an array of objects, whose brackets would have said it, says `object` or
    /// `object[]` at the end instead.
    private static func row(_ field: SchemaField, in rect: CGRect, columns: Int) -> Row {
        let style = SchemaStyle.self
        var tray = Tray(field)
        var label = typeLabel(field, tray: tray, columns: columns)
        func labelWidth(_ label: String?) -> CGFloat { label.map { style.width(ofType: $0) + style.typeGap } ?? 0 }
        if tray != nil, rect.width - labelWidth(label) < style.minChipWidth + style.trayGap + style.minTrayWidth {
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
        let name = field.isPattern ? "/\(field.name)/" : field.name
        let nameText = NSMutableAttributedString(attributedString: style.text(name, field.isPattern ? style.patternFont : style.nameFont, style.text))
        if field.isRequired { nameText.append(style.text("*", style.nameFont, style.required)) }
        let natural = (nameText.size().width + style.chipInset * 2).rounded(.up)
        let most = tray == nil ? room : room - style.trayGap - style.minTrayWidth
        let chip = CGRect(x: rect.minX, y: rect.minY, width: max(0, min(natural, most)), height: rect.height)
        let nameRect = style.centered(nameText, in: chip.insetBy(dx: style.chipInset, dy: 0))
        var trayText: NSAttributedString?, trayRect = CGRect.zero
        if let tray {
            let x = chip.maxX + style.trayGap
            let text = tray.line(width: right - x)
            trayText = text
            trayRect = style.centered(text, in: CGRect(x: x, y: rect.minY, width: max(0, right - x), height: rect.height))
        }
        return Row(name: name, isRequired: field.isRequired, isPattern: field.isPattern, tray: trayText?.string, type: label, frame: rect, chip: chip,
                   nameText: nameText, nameRect: nameRect, trayText: trayText, trayRect: trayRect, typeText: typeText, typeRect: typeRect)
    }

    /// The label at a row's end: JSON Schema's own words, at most `columns` characters (the last
    /// `…`). None for an object with fields, or an array of them, whose tray's brackets say it.
    static func typeLabel(_ field: SchemaField, tray: Tray?, columns: Int) -> String? {
        let type = field.type
        if tray?.isFields == true {
            if type == .object { return nil }
            if case .array(of: .object) = type { return nil }
        }
        let label = type.label
        guard label.count > columns else { return label }
        return String(label.prefix(max(1, columns - 1))) + "…"
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
    /// closing bracket), how many there are: `{ 4 fields }`. One run.
    func line(width: CGFloat) -> NSAttributedString {
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
            return text
        }
        line.append(tail(items.count - shown))
        return line
    }
}

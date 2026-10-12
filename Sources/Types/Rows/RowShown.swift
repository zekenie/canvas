import Canvas
import CoreGraphics
import Foundation
import Mentions

// The rows of a note that is one, as shown: each field's value as its row says it, and how the check
// marks it. Built from the type's template and the note's values, kept by shape (rects from the block's
// top-left, so a drag lets go of nothing), and let go of for the shapes a commit changed other than by
// moving.

/// How a row's value is drawn: by what it holds and what the check says of it.
public enum RowLook: Equatable, Sendable {
    /// A value, in the note's ink.
    case plain
    /// Nothing yet: `add email`, faint italic.
    case empty
    /// A needed field with no value: the same words in amber. Not an error.
    case needed
    /// A row that has a value with a needed one missing inside it: its summary in amber.
    case neededInside
    /// A value that breaks a rule, or a row with one inside: red with a wavy line under it.
    case wrong

    /// The look of a row that says `content` and the check marks `mark`. A wrong value is red; a needed
    /// field with no value is amber; a row whose type is gone is never marked (its values are not checked);
    /// a box holds a value however it is set, so it is never needed; nothing is wrong about words with no
    /// value.
    public static func of(content: ShownRow.Content, mark: FieldClass?) -> RowLook {
        switch content {
        case .empty, .choice(nil):
            return mark == .needed ? .needed : .empty
        case .gone, .kind:
            return .plain
        case .box, .text, .choice, .summary, .fold, .links:
            switch mark {
            case .wrong?: return .wrong
            case .needed?:
                switch content {
                case .summary, .fold: return .neededInside
                default: return .plain
                }
            case .warning?, nil: return .plain     // a pointer to a note that is gone is its dashed pill, never red
            }
        }
    }
}

extension ShownRow {
    /// This row `by` further along: its rects from a block's top-left to the block where it is.
    func offset(by origin: CGPoint) -> ShownRow {
        var row = self
        row.rect = rect.offsetBy(dx: origin.x, dy: origin.y)
        row.nameRect = nameRect.offsetBy(dx: origin.x, dy: origin.y)
        row.valueRect = valueRect == .zero ? .zero : valueRect.offsetBy(dx: origin.x, dy: origin.y)
        return row
    }
}

/// A note's rows as built for a block of one width: rects from the block's top-left.
struct ShownRows {
    var width: CGFloat
    var hasLead: Bool
    /// The rename count the template had: a fold that says a type's name is made again after one.
    var renames: Int
    var rows: [ShownRow]
    /// The paths whose marks each row carries: its field's, a fold's folded fields'.
    var marks: [[FieldPath]]
}

extension RowBook {
    /// The longest value a row keeps of a text: a longer one is cut when it is drawn, far past any column.
    public static let longestShown = 512

    /// The shape's rows as shown for `block`, kept: built when there are none kept for its width.
    func shownRows(of record: AnyShapeRecord, subject: RowSubject, template: RowTemplate, block: CGRect) -> ShownRows {
        let lead = hasWords(record)
        if let kept = shown[record.id], kept.width == block.width, kept.hasLead == lead, kept.renames == renames { return kept }
        #if DEBUG
        rowsShown += 1
        #endif
        let built = buildShown(of: record, subject: subject, template: template, width: block.width, hasLead: lead)
        if shown.count >= Self.shownCapacity { shown.removeAll(keepingCapacity: true) }
        shown[record.id] = built
        return built
    }

    private func buildShown(of record: AnyShapeRecord, subject: RowSubject, template: RowTemplate, width: CGFloat, hasLead: Bool) -> ShownRows {
        let values = record[FieldValuesProperty.self] ?? FieldValues()
        let geometry = RowGeometry(block: CGRect(x: 0, y: 0, width: width, height: 0), hasLead: hasLead, longestName: template.nameColumn)
        var rows: [ShownRow] = [], marks: [[FieldPath]] = []
        rows.reserveCapacity(template.items.count)
        for (row, item) in template.items.enumerated() {
            let rect = geometry.rect(row), name = geometry.nameRect(row), value = geometry.valueRect(row)
            switch item {
            case .field(let field):
                let content = content(of: field, held: values.value(at: field.path), width: value.width, types: subject.list)
                rows.append(ShownRow(path: field.path, name: field.name, content: content, isNeeded: false, tick: nil, isFaint: false,
                                     rect: rect, nameRect: name, valueRect: value))
                marks.append([field.path])
            case .fold(let fold):
                rows.append(ShownRow(path: nil, name: fold.name, content: .fold(fold.value), isNeeded: false,
                                     tick: fold.sources.count == 1 ? fold.sources[0] : nil, isFaint: !fold.isMore, rect: rect,
                                     nameRect: fold.isMore ? rect : name, valueRect: fold.isMore ? .zero : value))
                marks.append(fold.folded.map { FieldPath(field: $0.field.name) })
            }
        }
        return ShownRows(width: width, hasLead: hasLead, renames: renames, rows: rows, marks: marks)
    }

    /// What a field's row says of the value it holds (nil: none). A link to a note is its pill, or its pills.
    private func content(of field: FieldRowTemplate, held: JSONValue?, width: CGFloat, types: [ShapeID]) -> ShownRow.Content {
        guard let editor, let book = editor.fieldBook else { return .empty(FieldWords.add(field.name)) }
        let value = held.flatMap(FieldValues.pruned)
        let empty = ShownRow.Content.empty(FieldWords.add(field.name))
        switch field.kind {
        case .plain(.yesNo):
            return .box(value == .bool(true))
        case .other:
            return .summary(FieldWords.editedAsJSON)
        case .typeFields(let target), .listOfTypeFields(let target):
            if editor.types?.isType(target) != true { return .gone(target) }
        case .plain(.choice):
            return value.map { .choice(clipped(FieldText.shown($0, as: field.kind.plainKind ?? .text))) } ?? .choice(nil)
        case .pointer(let target), .pointers(let target):
            if editor.types?.isType(target) != true { return .gone(target) }
        default:
            break
        }
        guard let value else { return empty }
        let summary = FieldSummary.of(value, field: field.resolved, in: book, types: types)
        switch field.kind {
        case .pointer, .pointers:
            return links(of: value, in: book, width: width) ?? .text(clipped(summary.text))
        case .plain, .either(.plain(_), .plain(_)):
            return .text(clipped(summary.text))
        default:
            guard case .items(let items) = summary else { return .summary(clipped(summary.text)) }
            return .summary(Self.cut(items, toFit: width - Self.chevronRoom))
        }
    }

    /// The pills a pointer's value shows, laid out in a column `width` wide: each element that is a token, left to
    /// right, as many as fit with room for the `+N` that counts the rest (the first always, cut to the column), and
    /// every element that is not a token counted in the `+N`. Nil when the value holds no token at all.
    private func links(of value: JSONValue, in book: FieldBook, width: CGFloat) -> ShownRow.Content? {
        let elements = value.arrayValue ?? [value]
        let links = elements.compactMap { FieldLink($0) }
        guard !links.isEmpty else { return nil }
        let gap = TypesStyle.linkGap
        let reserve = gap + FieldLines.width(of: "+\(elements.count)", .kind)
        var shown: [ShownLink] = [], x: CGFloat = 0
        for (place, link) in links.enumerated() {
            let resolution = book.resolution(of: link)
            let attachment = MentionAttachment(target: link.target, storedLabel: link.stored, resolution: resolution, style: LinkPills.style, width: width)
            let pill = ceil(attachment.layout.bounds.width)
            let room = place < links.count - 1 || links.count < elements.count ? reserve : 0
            if !shown.isEmpty, x + pill + room > width { break }
            shown.append(ShownLink(link: link, x: x, width: pill, isLive: resolution.isLive))
            x += pill + gap
        }
        return .links(shown, more: elements.count - shown.count)
    }

    private func clipped(_ text: String) -> String {
        text.count > Self.longestShown ? String(text.prefix(Self.longestShown)) : text
    }

    /// What the `›` after a summary takes.
    static var chevronRoom: CGFloat { FieldLines.width(of: "›", .kind) + TypesStyle.partGap }

    /// `gift, mugs`, or as many items as fit with the rest counted: `gift, mugs +2`. The first item alone is
    /// cut when it doesn't fit by itself (the drawer ends it with an ellipsis).
    static func cut(_ items: [String], toFit width: CGFloat) -> String {
        guard !items.isEmpty else { return "" }
        func text(_ count: Int) -> String {
            items.prefix(count).joined(separator: ", ") + (count < items.count ? " +\(items.count - count)" : "")
        }
        if FieldLines.width(of: text(items.count), .value) <= width { return text(items.count) }
        for count in stride(from: items.count - 1, through: 1, by: -1) where FieldLines.width(of: text(count), .value) <= width { return text(count) }
        return text(1)
    }
}

extension FieldKind {
    /// The plain kind a plain row is.
    var plainKind: PlainKind? {
        if case .plain(let kind) = self { return kind }
        return nil
    }
}

extension RowBook {
    /// What the check says of a shape's values (`FieldChecks`, or what a test put in its place), with the
    /// field being typed in left out: the row being typed in is never marked.
    func check(of record: AnyShapeRecord) -> FieldCheck {
        #if DEBUG
        if let checks {
            var answer = checks(record)
            if let typing = editor?.fieldChecks?.typing, typing.shape == record.id { answer = answer.leaving(out: typing.path) }
            return answer
        }
        #endif
        return editor?.fieldChecks?.check(of: record) ?? .clean
    }
}

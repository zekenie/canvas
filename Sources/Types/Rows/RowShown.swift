import Canvas
import CanvasRPC
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
        case .gone, .kind, .relationType:
            return .plain
        case .box, .text, .choice, .summary, .fold, .related:
            switch mark {
            case .wrong?: return .wrong
            case .needed?:
                switch content {
                case .summary, .fold: return .neededInside
                default: return .plain
                }
            case .warning?, nil: return .plain     // a warning draws nothing on a row
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
    /// The paths whose marks each row carries: its field's, a fold's folded fields'; none for a relation row.
    var marks: [[FieldPath]]
    /// The arrows its pills came from: a change to one of them lets the rows go.
    var arrows: Set<ShapeID> = []
    /// Where the dashed line goes, from the block's top; nil with none.
    var ruleY: CGFloat?
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
        // Over capacity the lot goes, and the names the pills were laid out with: nothing is left to compare them by.
        if shown.count >= Self.shownCapacity { letGoOfShown() }
        let built = buildShown(of: record, subject: subject, template: template, width: block.width, hasLead: lead)
        shown[record.id] = built
        return built
    }

    private func buildShown(of record: AnyShapeRecord, subject: RowSubject, template: RowTemplate, width: CGFloat, hasLead: Bool) -> ShownRows {
        let values = record[FieldValuesProperty.self] ?? FieldValues()
        let geometry = RowGeometry(block: CGRect(x: 0, y: 0, width: width, height: 0), hasLead: hasLead, template: template)
        var rows: [ShownRow] = [], marks: [[FieldPath]] = [], arrows: Set<ShapeID> = []
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
            case .relation(let relation):
                let content = relationContent(of: relation, for: record.id, width: value.width, arrows: &arrows)
                rows.append(ShownRow(path: nil, relation: relation.row.key, name: relation.name, content: content, isNeeded: false, tick: nil, isFaint: false,
                                     rect: rect, nameRect: name, valueRect: value))
                marks.append([])
            }
        }
        return ShownRows(width: width, hasLead: hasLead, renames: renames, rows: rows, marks: marks, arrows: arrows, ruleY: geometry.ruleY)
    }

    /// What a note's relation row says: the pills of its relationships in that row (name order, as many as fit, `+N` for the
    /// rest), or, with none, `add layer`. Each pill's note is filed with the name it is laid out with, and the note that
    /// shows it, so a rename of the note finds the rows that show it.
    private func relationContent(of relation: RelationRowTemplate, for note: ShapeID, width: CGFloat, arrows: inout Set<ShapeID>) -> ShownRow.Content {
        guard let relationships else { return .empty(FieldWords.add(relation.name)) }
        let found = relationships.relations(of: note, in: relation.row)
        guard !found.isEmpty else { return .empty(FieldWords.add(relation.name)) }
        let content = pills(of: found, among: found.count, width: width)
        arrows.formUnion(found.map(\.arrow))
        // Every relation the row sorted is filed, the counted ones too: the name of any of them decides which pills are shown.
        for relation in found {
            if let target = relation.far.reading.namedNote {
                pillLabels[target] = pillLabel(of: target)
                holders[target, default: []].insert(note)
            }
            // A pill the far end is read through: a commit that changes it changes what the row says.
            if let via = relation.far.via { viaHolders[via, default: []].insert(note) }
        }
        return content
    }

    /// What a field's row says of the value it holds (nil: none).
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
        default:
            break
        }
        guard let value else { return empty }
        let summary = FieldSummary.of(value, field: field.resolved, in: book, types: types)
        switch field.kind {
        case .plain, .either(.plain(_), .plain(_)):
            return .text(clipped(summary.text))
        default:
            guard case .items(let items) = summary else { return .summary(clipped(summary.text)) }
            return .summary(Self.cut(items, toFit: width - Self.chevronRoom))
        }
    }

    /// What a pill is made of, from how its arrow's far end reads: the note it names, what it is drawn for, the name it
    /// holds and whether it is drawn solid.
    private struct PillFace {
        var target: ShapeID?
        var drawn: ShapeID
        var label: String
        var isLive: Bool
        /// What it is measured as: the live note, or a dashed pill.
        var resolution: MentionResolution
    }

    /// A mention of no shape: what a dashed pill is drawn for, so Mentions draws it dashed from the name it holds.
    static let noShape = ShapeID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))

    private func face(of reading: EndReading) -> PillFace {
        func dashed(_ target: ShapeID?, _ label: String) -> PillFace {
            PillFace(target: target, drawn: Self.noShape, label: label, isLive: false, resolution: .missing)
        }
        switch reading {
        case .note(let id):
            let resolution = editor?.mentions?.resolve(id) ?? .missing
            return PillFace(target: id, drawn: id, label: resolution.appearance?.label ?? "", isLive: resolution.isLive, resolution: resolution)
        case .notAdmitted(let id, _):
            // The note is there and its name is live; its pill may not stand for it yet.
            return dashed(id, editor?.mentions?.resolve(id).appearance?.label ?? FieldWords.noteUnavailable)
        case .gone(let called): return dashed(nil, called.flatMap(nonEmpty) ?? FieldWords.noteGone)
        case .unavailable(let called): return dashed(nil, called.flatMap(nonEmpty) ?? FieldWords.noteUnavailable)
        case .query(let called): return dashed(nil, called.flatMap(nonEmpty) ?? FieldWords.noteQuery)
        case .empty, .free: return dashed(nil, FieldWords.noteBlank)
        }
    }

    private func nonEmpty(_ text: String) -> String? { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text }

    /// Whether the arrow of this relationship breaks its type's rule at the end the row's pill stands for: red, with the
    /// wave, the row of the end that fits listing the note at the end that does not.
    private func isMisfit(_ relation: Relation) -> Bool {
        guard let arrow = editor?.shape(inFile: relation.arrow) else { return false }
        return check(of: arrow).endMark(relation.side.other) == .wrong
    }

    /// The pills of these relationships laid out in a column `width` wide, sorted by the name each shows (case aside,
    /// then the arrow's id), left to right, as many as fit with room for the `+N` that counts the rest (the first always,
    /// cut to the column); `count` is how many elements the row holds, the notes and whatever else is counted in the
    /// `+N`. A pill is solid as its far end reads a note that Mentions shows, dashed in every other state.
    public func pills(of relations: [Relation], among count: Int, width: CGFloat) -> ShownRow.Content {
        let gap = TypesStyle.pillGap
        let reserve = gap + FieldLines.width(of: "+\(count)", .kind)
        // A row that holds a relationship ends in `›`, which opens its card: its room is not the pills'.
        let width = relations.isEmpty ? width : max(0, width - Self.chevronRoom)
        let faces = relations.map { (relation: $0, face: face(of: $0.far.reading)) }.sorted { a, b in
            let (x, y) = (a.face.label.lowercased(), b.face.label.lowercased())
            return x == y ? a.relation.arrow.rawValue.uuidString < b.relation.arrow.rawValue.uuidString : x < y
        }
        var shown: [ShownPill] = [], x: CGFloat = 0
        for (place, found) in faces.enumerated() {
            let face = found.face
            let pill = pillWidth(of: face.drawn, label: face.label, resolution: face.resolution, limit: width)
            let room = place < faces.count - 1 || faces.count < count ? reserve : 0
            if !shown.isEmpty, x + pill + room > width { break }
            shown.append(ShownPill(target: face.target, via: found.relation.far.via, arrow: found.relation.arrow, state: found.relation.far.reading,
                                   label: face.label, drawn: face.drawn, x: x, width: pill, isLive: face.isLive,
                                   isWrong: isMisfit(found.relation)))
            x += pill + gap
        }
        return .related(shown, more: count - shown.count)
    }

    /// What a pill's width is made of: the label it shows, whether it is live (a dashed one is set in italic, a live one
    /// has its slot) and the room the column gives it. Style is the relation pills' alone.
    struct PillWidthKey: Hashable {
        var label: String
        var isLive: Bool
        var limit: CGFloat
    }

    /// The width a pill is laid out at: kept by what it is made of, so the pills of a hub's thousand rows are measured
    /// once and not once a row (a pill is an attachment, its font and its text measured, to read one number).
    private func pillWidth(of drawn: ShapeID, label: String, resolution: MentionResolution, limit: CGFloat) -> CGFloat {
        let key = PillWidthKey(label: resolution.shownLabel(stored: label), isLive: resolution.isLive, limit: limit)
        if let known = pillWidths[key] { return known }
        let attachment = MentionAttachment(target: drawn, storedLabel: label, resolution: resolution, style: RelationPills.style, width: limit)
        let width = ceil(attachment.layout.bounds.width)
        if pillWidths.count >= Self.shownCapacity { pillWidths.removeAll(keepingCapacity: true) }
        pillWidths[key] = width
        return width
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

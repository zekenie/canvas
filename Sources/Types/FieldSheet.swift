import Canvas
import Foundation

// The form a card and the panel hold, as values: what each line says, in which cells, and where the
// keyboard can stop. Pure: it reads the values, the check and the book it is handed and draws and does
// nothing, so a test reads what the person would see without a view. `FieldFormView` draws and keys it.

/// Where the keyboard is: a cell, or a line as a whole. Reading order is left to right, then down.
public struct FieldStop: Hashable, Sendable {
    /// The line; -1 for the branch names above the lines.
    public var line: Int
    /// The cell; -1 for the line itself (a check line, a row with more, a triangle), and, on the branch
    /// names, the branch.
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

/// One value on a line: what it is filled with, what it reads, and how a check marks it.
public struct FieldCell: Equatable {
    public enum Control: Equatable {
        /// Typed: text, a number, a date.
        case text(PlainKind)
        /// Typed, for a field that takes either of two plain kinds (`FieldText.value(from:asOneOf:)`).
        case oneOf([PlainKind])
        case yesNo
        /// A menu of the options, `None` last.
        case choice([FieldOption])
        /// A summary and `›`: it opens.
        case more(FieldSummary)
        /// A line of several choices, ticked or not.
        case check(Bool)
        /// The line that clears several choices.
        case clear
        /// Words only: a kind on a type's note, the text of a pointer, a list that is empty and cannot be filled.
        case label(String)
        /// The panel's box of JSON.
        case json
    }

    /// Where its value is; for a line that is not stored, where the item would go (`isStored`).
    public var path: FieldPath
    public var field: Resolved.Field
    public var control: Control
    /// What is stored, nil for none.
    public var value: JSONValue?
    /// `FieldText.shown` of what is stored; "" for none; for a summary its text.
    public var shown: String
    /// `add city`, `add`, "".
    public var placeholder: String
    public var mark: FieldClass?
    /// False: a write puts an item in at `path`'s index (the whole list is set).
    public var isStored: Bool
    public var isEditable: Bool
    /// A number in a table.
    public var alignsRight: Bool

    public init(path: FieldPath, field: Resolved.Field, control: Control, value: JSONValue? = nil, shown: String = "", placeholder: String = "",
                mark: FieldClass? = nil, isStored: Bool = true, isEditable: Bool = false, alignsRight: Bool = false) {
        self.path = path
        self.field = field
        self.control = control
        self.value = value
        self.shown = shown
        self.placeholder = placeholder
        self.mark = mark
        self.isStored = isStored
        self.isEditable = isEditable
        self.alignsRight = alignsRight
    }
}

public struct FieldLine: Equatable {
    /// Rows: the member's name.
    public var name: String?
    /// A type's note: the amber dot after the name.
    public var isNeeded: Bool
    /// After the name: a member that is another type's fields.
    public var chip: ShapeID?
    public var cells: [FieldCell]
    /// The panel's indent.
    public var depth: Int
    /// The panel: nil none, false closed, true open.
    public var disclosure: Bool?
    /// The list or pairs this is a line of (its path), and which slot of its draft: nil and -1 for a line that is not one.
    public var list: FieldPath?
    public var slot: Int
    /// Whether `list` is pairs, as the sheet drew it: the form's draft for it is made the same way.
    public var isPair: Bool

    public init(name: String? = nil, isNeeded: Bool = false, chip: ShapeID? = nil, cells: [FieldCell], depth: Int = 0, disclosure: Bool? = nil,
                list: FieldPath? = nil, slot: Int = -1, isPair: Bool = false) {
        self.name = name
        self.isNeeded = isNeeded
        self.chip = chip
        self.cells = cells
        self.depth = depth
        self.disclosure = disclosure
        self.list = list
        self.slot = slot
        self.isPair = isPair
    }
}

public struct FieldSheet: Equatable {
    public enum Layout: Equatable {
        case rows, column
        /// The members' names, the columns.
        case table([String])
        case pairs, checks
    }

    /// `‹ shipping address`: the line that goes back one level.
    public var back: String?
    /// The type its rows are under.
    public var chip: ShapeID?
    /// An either's two branch names across the top, and the one picked (empty for none).
    public var branches: [String]
    public var branch: Int
    public var layout: Layout
    public var lines: [FieldLine]
    /// Reading order.
    public var stops: [FieldStop]

    public init(back: String? = nil, chip: ShapeID? = nil, branches: [String] = [], branch: Int = 0, layout: Layout = .rows, lines: [FieldLine] = [],
                stops: [FieldStop] = []) {
        self.back = back
        self.chip = chip
        self.branches = branches
        self.branch = branch
        self.layout = layout
        self.lines = lines
        self.stops = stops
    }
}

/// What the editor keeps for one level that the file does not: its lines, in the order shown, and which
/// are not stored. A list is dense (empties are pruned), so a line's stored index is the count of stored
/// lines before it; a line that has no value yet, or had its text deleted, or is half of a pair, is a
/// slot here and nothing in the file.
public struct FieldDraft: Equatable {
    public enum Slot: Equatable {
        /// A list's item (nil), or a pair by its key.
        case stored(key: String?)
        case blank
        /// Half typed: a half missing, or a name another pair has.
        case pair(name: String, value: String, taken: Bool)
    }

    public var slots: [Slot]
    /// Pairs, not a list.
    public private(set) var isPairs: Bool
    /// Whether a blank line waits at the end (not read-only).
    public let waits: Bool

    /// A list's items in order, or pairs in name order (JSON objects have no order); then one blank unless
    /// read-only. `pairs` says which it is where the value alone does not (nothing stored yet).
    public init(_ stored: JSONValue?, waiting: Bool, pairs: Bool? = nil) {
        isPairs = pairs ?? (stored?.objectValue != nil)
        waits = waiting
        if isPairs {
            slots = (stored?.objectValue ?? [:]).keys.sorted().map { .stored(key: $0) }
        } else {
            slots = (0..<(stored?.arrayValue?.count ?? 0)).map { _ in .stored(key: nil) }
        }
        if waiting { slots.append(.blank) }
    }

    /// The stored slots before it.
    public func storedIndex(ofLine line: Int) -> Int {
        slots.prefix(max(line, 0)).filter(\.isStored).count
    }

    /// What is stored no longer fits the slots (something else wrote it): a list whose count differs is all
    /// stored and one blank waiting; pairs lose the line of a key that is gone and gain a new key's as their
    /// last stored line (before the waiting one). A half-typed pair stays.
    public mutating func reconcile(with stored: JSONValue?) {
        if stored?.objectValue != nil { isPairs = true }
        if stored?.arrayValue != nil { isPairs = false }
        if isPairs {
            let members = stored?.objectValue ?? [:]
            slots.removeAll { slot in
                if case .stored(let key?) = slot { members[key] == nil } else { false }
            }
            let held = Set(slots.compactMap { slot -> String? in
                if case .stored(let key?) = slot { key } else { nil }
            })
            let added = members.keys.filter { !held.contains($0) }.sorted()
            guard !added.isEmpty else { return }
            var cut = slots.count
            while cut > 0, slots[cut - 1] == .blank { cut -= 1 }
            slots.insert(contentsOf: added.map { Slot.stored(key: $0) }, at: cut)
        } else {
            let count = stored?.arrayValue?.count ?? 0
            guard count != slots.filter(\.isStored).count else { return }
            slots = (0..<count).map { _ in .stored(key: nil) } + (waits ? [.blank] : [])
        }
    }

    /// A line that has a value now: stored, and a blank waits after it again.
    public mutating func store(line: Int, key: String? = nil) {
        guard slots.indices.contains(line) else { return }
        slots[line] = .stored(key: key)
        ensureWaiting()
    }

    /// A line whose text was deleted: it stays, empty.
    public mutating func blank(line: Int) {
        guard slots.indices.contains(line) else { return }
        slots[line] = .blank
    }

    public mutating func remove(line: Int) {
        guard slots.indices.contains(line) else { return }
        slots.remove(at: line)
        ensureWaiting()
    }

    public mutating func ensureWaiting() {
        if waits, slots.last != .blank { slots.append(.blank) }
    }
}

extension FieldKind {
    /// A field's line in the panel has a triangle: more in it, and no JSON box or links (slice 14's).
    fileprivate var opensInPanel: Bool {
        switch self {
        case .other, .pointers: false
        default: hasMore
        }
    }
}

extension FieldDraft.Slot {
    var isStored: Bool { if case .stored = self { true } else { false } }
}

/// What a form is made from: a field and what is under it, or the rows a fold hides.
public enum FieldFormRoot {
    case field(path: FieldPath, field: Resolved.Field, kind: FieldKind)
    case fold([Resolved.Field])
}

public enum FieldSheets {
    /// The default draft of a level: what the form keeps for a list or pairs at `path`.
    @MainActor
    public static func draft(at path: FieldPath, kind: FieldKind, values: FieldValues, isReadOnly: Bool, drawnAsPairs: Bool = false) -> FieldDraft {
        var pairs = drawnAsPairs
        if case .pairs = kind { pairs = true }
        return FieldDraft(values.value(at: path), waiting: !isReadOnly, pairs: pairs)
    }

    /// The level of `field` at `path`: rows, a column, a table, pairs, checks, or an either's branch, as its
    /// kind says (on a type's note, its members with their kinds); in the panel, the field's line and, open,
    /// what is under it. `drafts` are what the form keeps of each list and pairs by its path, a fresh one
    /// where it has none; `open` is what the person opened or closed in the panel (a node with a problem at
    /// or under it is open until they say); `branch` picks an either's branch, else the one the value fits.
    @MainActor
    public static func sheet(path: FieldPath, field: Resolved.Field, kind: FieldKind, values: FieldValues, check: FieldCheck, book: FieldBook,
                             types: [ShapeID], mode: FieldFormMode, isReadOnly: Bool, presentation: FieldFormContext.Presentation,
                             drafts: [FieldPath: FieldDraft] = [:], open: [FieldPath: Bool] = [:], back: String? = nil, branch: Int? = nil,
                             locale: Locale = .autoupdatingCurrent) -> FieldSheet {
        let maker = SheetMaker(values: values, check: check, book: book, types: types, mode: mode, isReadOnly: isReadOnly,
                               presentation: presentation, drafts: drafts, open: open, locale: locale)
        var sheet = presentation == .panel && mode == .values
            ? maker.panelSheet(path: path, field: field, kind: kind)
            : maker.level(path: path, field: field, kind: kind, branch: branch)
        sheet.back = back
        sheet.stops = SheetMaker.stops(of: sheet)
        return sheet
    }

    /// The rows a fold hides, as rows; under their type's chip when one type introduced every one.
    @MainActor
    public static func foldSheet(_ folded: [Resolved.Field], values: FieldValues, check: FieldCheck, book: FieldBook, types: [ShapeID],
                                 mode: FieldFormMode, isReadOnly: Bool, locale: Locale = .autoupdatingCurrent) -> FieldSheet {
        let maker = SheetMaker(values: values, check: check, book: book, types: types, mode: mode, isReadOnly: isReadOnly,
                               presentation: .card, drafts: [:], open: [:], locale: locale)
        var sheet = FieldSheet()
        if let first = folded.first, folded.allSatisfy({ $0.introducedBy == first.introducedBy }) { sheet.chip = first.introducedBy }
        sheet.lines = folded.flatMap { maker.memberLines($0, under: FieldPath(), depth: 0) }
        sheet.stops = SheetMaker.stops(of: sheet)
        return sheet
    }
}

@MainActor
private struct SheetMaker {
    let values: FieldValues
    let check: FieldCheck
    let book: FieldBook
    let types: [ShapeID]
    let mode: FieldFormMode
    let isReadOnly: Bool
    let presentation: FieldFormContext.Presentation
    let drafts: [FieldPath: FieldDraft]
    let open: [FieldPath: Bool]
    let locale: Locale

    private func withValues(_ values: FieldValues) -> SheetMaker {
        SheetMaker(values: values, check: check, book: book, types: types, mode: mode, isReadOnly: isReadOnly, presentation: presentation,
                   drafts: drafts, open: open, locale: locale)
    }

    // MARK: A level

    func level(path: FieldPath, field: Resolved.Field, kind: FieldKind, branch: Int?) -> FieldSheet {
        var sheet = FieldSheet()
        sheet.chip = Self.typeChip(of: kind)
        if mode == .kinds {
            kindsLevel(&sheet, path: path, field: field, kind: kind, branch: branch)
            return sheet
        }
        switch kind {
        case .group, .typeFields:
            sheet.lines = book.members(of: field).flatMap { memberLines($0, under: path, depth: 0) }
        case .list(let plain):
            sheet.layout = .column
            sheet.lines = columnLines(path: path, field: field, kind: plain)
        case .choices(let options):
            sheet.layout = .checks
            sheet.lines = checkLines(path: path, field: field, options: options)
        case .listOfGroups, .listOfTypeFields:
            let item = book.item(of: field)
            let members = item.map(book.members(of:)) ?? []
            sheet.layout = .table(members.map { FieldName.words(of: $0.field) })
            sheet.lines = tableLines(path: path, field: field, members: members)
        case .pairs(let plain):
            sheet.layout = .pairs
            sheet.lines = pairLines(path: path, field: field, kind: plain)
        case .either(let first, let second):
            let branches = book.branches(of: field)
            guard kind.hasMore, branches.count == 2 else {
                sheet.lines = [singleLine(path: path, field: field, kind: kind)]
                break
            }
            let kinds = [first, second]
            let picked = min(max(branch ?? branchFitting(values.value(at: path), kinds), 0), 1)
            sheet.branches = zip(branches, kinds).map { label(of: $1, field: $0) }
            sheet.branch = picked
            // A branch the stored value does not fit shows empty: its cells read nothing, and typing replaces the value.
            let shown = branchFitting(values.value(at: path), kinds) == picked ? self : withValues(values.setting(nil, at: path))
            let inner = shown.level(path: path, field: branches[picked], kind: kinds[picked], branch: nil)
            sheet.chip = inner.chip
            sheet.layout = inner.layout
            sheet.lines = inner.lines
        case .plain, .pointer, .pointers, .other:
            sheet.lines = [singleLine(path: path, field: field, kind: kind)]
        }
        return sheet
    }

    /// The type whose chip a level's rows are under: another type's fields, alone or listed.
    private static func typeChip(of kind: FieldKind) -> ShapeID? {
        switch kind {
        case .typeFields(let type), .listOfTypeFields(let type): type
        default: nil
        }
    }

    /// An either's branch picked by what is stored: the first it fits, the first with no value.
    func branchFitting(_ value: JSONValue?, _ kinds: [FieldKind]) -> Int {
        guard let value else { return 0 }
        return kinds.firstIndex { Self.fits(value, $0) } ?? 0
    }

    private static func fits(_ value: JSONValue, _ kind: FieldKind) -> Bool {
        switch (kind, value) {
        case (.choices, .array), (.list, .array), (.listOfGroups, .array), (.listOfTypeFields, .array), (.pointers, .array): true
        case (.group, .object), (.typeFields, .object), (.pairs, .object): true
        case (.plain, .array), (.plain, .object), (.pointer, .array), (.pointer, .object): false
        case (.plain, _), (.pointer, _): true
        case (.either(let a, let b), _): fits(value, a) || fits(value, b)
        default: false
        }
    }

    /// A branch's name across the top.
    private func label(of kind: FieldKind, field: Resolved.Field) -> String {
        kind.typeLabel(memberCount: kind == .group ? book.members(of: field).count : 0)
    }

    /// One cell on a line of its own, for a level whose field holds no more than that.
    private func singleLine(path: FieldPath, field: Resolved.Field, kind: FieldKind) -> FieldLine {
        FieldLine(cells: [memberCell(field, kind: kind, path: path, value: values.value(at: path), stored: true)])
    }

    // MARK: Rows

    /// The line of a member and, in the panel, what is open under it.
    func memberLines(_ field: Resolved.Field, under parent: FieldPath, depth: Int) -> [FieldLine] {
        let path = parent.key(field.field.name)
        let kind = book.kind(of: field)
        let name = FieldName.words(of: field.field)
        if mode == .kinds { return [kindsLine(field, kind: kind, path: path, depth: depth)] }
        let value = values.value(at: path)
        let cell = memberCell(field, kind: kind, path: path, value: value, stored: true)
        guard presentation == .panel, kind.opensInPanel else {
            return [FieldLine(name: name, cells: [cell], depth: depth)]
        }
        let isOpen = isOpen(path)
        let line = FieldLine(name: name, cells: [cell], depth: depth, disclosure: isOpen)
        return isOpen ? [line] + content(of: field, kind: kind, path: path, depth: depth + 1) : [line]
    }

    /// The cell of a field's value: by its kind. A summary and `›` for what has more in it.
    private func memberCell(_ field: Resolved.Field, kind: FieldKind, path: FieldPath, value: JSONValue?, stored: Bool, placeholder: String? = nil,
                            inTable: Bool = false) -> FieldCell {
        let words = placeholder ?? FieldWords.add(FieldName.words(of: field.field))
        let mark = stored ? check.mark(at: path) : nil
        switch kind {
        case .plain(let plain):
            return plainCell(plain, field: field, path: path, value: value, placeholder: words, stored: stored, inTable: inTable)
        case .either(.plain(let first), .plain(let second)):
            let shown = value.map { FieldText.shown($0, asOneOf: [first, second], locale: locale) } ?? ""
            return FieldCell(path: path, field: field, control: .oneOf([first, second]), value: value, shown: shown, placeholder: words, mark: mark,
                             isStored: stored, isEditable: !isReadOnly)
        case .pointer, .pointers:
            let shown = FieldSummary.of(value, field: field, in: book, types: types, locale: locale)
            let text: String
            if case .empty = shown { text = "" } else { text = shown.text }
            return FieldCell(path: path, field: field, control: .label(text), value: value, shown: text, mark: mark, isStored: stored)
        case .other:
            if presentation == .panel {
                let json = value.map(FieldJSON.pretty) ?? ""
                return FieldCell(path: path, field: field, control: .json, value: value, shown: json, mark: mark, isStored: stored, isEditable: !isReadOnly)
            }
            return FieldCell(path: path, field: field, control: .more(.json), value: value, shown: FieldSummary.json.text, mark: mark, isStored: stored)
        default:
            let summary = FieldSummary.of(value, field: field, in: book, types: types, locale: locale)
            return FieldCell(path: path, field: field, control: .more(summary), value: value, shown: summary.text, mark: mark, isStored: stored)
        }
    }

    private func plainCell(_ plain: PlainKind, field: Resolved.Field, path: FieldPath, value: JSONValue?, placeholder: String, stored: Bool,
                           inTable: Bool = false) -> FieldCell {
        let shown = value.map { FieldText.shown($0, as: plain, locale: locale) } ?? ""
        let mark = stored ? check.mark(at: path) : nil
        let control: FieldCell.Control
        switch plain {
        case .text, .number, .date, .dateTime: control = .text(plain)
        case .yesNo: control = .yesNo
        case .choice(let options): control = .choice(options)
        }
        var isNumber = false
        if case .number = plain { isNumber = true }
        // A needed cell with nothing in it says so, even in a table whose empty cells say nothing.
        let hint = value == nil && mark == .needed && placeholder.isEmpty ? FieldWords.addLine : placeholder
        return FieldCell(path: path, field: field, control: control, value: value, shown: shown, placeholder: plain == .yesNo ? "" : hint, mark: mark,
                         isStored: stored, isEditable: !isReadOnly, alignsRight: inTable && isNumber)
    }

    // MARK: Lists, tables, pairs, checks

    private static let textSchema = SchemaValue.object([SchemaMember(key: "type", value: .string("string"))])

    private func draft(at path: FieldPath, kind: FieldKind) -> FieldDraft {
        drafts[path] ?? FieldSheets.draft(at: path, kind: kind, values: values, isReadOnly: isReadOnly)
    }

    /// The faint line a read-only list, table or pair set with nothing in it holds.
    private func noneLine(path: FieldPath, field: Resolved.Field) -> FieldLine {
        FieldLine(cells: [FieldCell(path: path, field: field, control: .label(FieldWords.none), shown: FieldWords.none, isStored: false)])
    }

    /// A list of plain values: a line each, then a blank one waiting.
    private func columnLines(path: FieldPath, field: Resolved.Field, kind plain: PlainKind, depth: Int = 0) -> [FieldLine] {
        let held = draft(at: path, kind: .list(of: plain))
        if held.slots.isEmpty { return [noneLine(path: path, field: field)] }
        let item = book.item(of: field) ?? field
        return held.slots.enumerated().map { place, slot in
            let isStored = slot.isStored
            let itemPath = path.index(held.storedIndex(ofLine: place))
            let waiting = !isStored && place == held.slots.count - 1
            let cell = plainCell(plain, field: item, path: itemPath, value: isStored ? values.value(at: itemPath) : nil,
                                 placeholder: waiting ? FieldWords.addLine : "", stored: isStored)
            return FieldLine(cells: [cell], depth: depth, list: path, slot: place)
        }
    }

    /// A list of groups, or of another type's fields: a line each, a cell a member.
    private func tableLines(path: FieldPath, field: Resolved.Field, members: [Resolved.Field]) -> [FieldLine] {
        let held = draft(at: path, kind: .listOfGroups)
        if held.slots.isEmpty { return [noneLine(path: path, field: field)] }
        let kinds = members.map(book.kind(of:))
        return held.slots.enumerated().map { place, slot in
            let isStored = slot.isStored
            let itemPath = path.index(held.storedIndex(ofLine: place))
            let waiting = !isStored && place == held.slots.count - 1
            let cells = members.enumerated().map { column, member -> FieldCell in
                let memberPath = itemPath.key(member.field.name)
                return memberCell(member, kind: kinds[column], path: memberPath, value: isStored ? values.value(at: memberPath) : nil, stored: isStored,
                                  placeholder: waiting && column == 0 ? FieldWords.addLine : "", inTable: true)
            }
            return FieldLine(cells: cells, list: path, slot: place)
        }
    }

    /// Named pairs: a name and a value a line, then a blank one waiting.
    private func pairLines(path: FieldPath, field: Resolved.Field, kind plain: PlainKind, depth: Int = 0) -> [FieldLine] {
        let held = draft(at: path, kind: .pairs(value: plain))
        if held.slots.isEmpty { return [noneLine(path: path, field: field)] }
        let valueField = book.pairValue(of: field) ?? field
        let nameField = Resolved.Field(field: ChainField(name: "", schema: Self.textSchema), source: field.source, introducedBy: field.introducedBy)
        return held.slots.enumerated().map { place, slot in
            let waiting = place == held.slots.count - 1
            var name = "", typed: String?, key: String?, taken = false, isStored = false
            switch slot {
            case .stored(let slotKey): key = slotKey; name = slotKey ?? ""; isStored = true
            case .blank: break
            case .pair(let half, let text, let isTaken): name = half; typed = text; taken = isTaken; key = half.isEmpty ? nil : half
            }
            let pairPath = key.map { path.key($0) } ?? path
            let kept = isStored ? values.value(at: pairPath) : nil
            let nameCell = FieldCell(path: pairPath, field: nameField, control: .text(.text), value: key.map { .string($0) }, shown: name,
                                     placeholder: !isStored && waiting && name.isEmpty ? FieldWords.addLine : "", mark: taken ? .wrong : nil,
                                     isStored: isStored, isEditable: !isReadOnly)
            var valueCell = plainCell(plain, field: valueField, path: pairPath, value: kept, placeholder: "", stored: isStored)
            if let typed { valueCell.shown = typed }
            return FieldLine(cells: [nameCell, valueCell], depth: depth, list: path, slot: place, isPair: true)
        }
    }

    /// Several choices: a line an option, ticked when picked, then `None`.
    private func checkLines(path: FieldPath, field: Resolved.Field, options: [FieldOption], depth: Int = 0) -> [FieldLine] {
        let picked = mode == .kinds ? [] : values.value(at: path)?.arrayValue ?? []
        var lines = options.map { option in
            FieldLine(cells: [FieldCell(path: path, field: field, control: .check(picked.contains(option.value)), value: option.value, shown: option.label,
                                        isEditable: !isReadOnly)], depth: depth)
        }
        lines.append(FieldLine(cells: [FieldCell(path: path, field: field, control: .clear, shown: FieldWords.none, isEditable: !isReadOnly)], depth: depth))
        return lines
    }

    // MARK: The panel

    private func isOpen(_ path: FieldPath) -> Bool {
        open[path] ?? (check.mark(at: path) != nil)
    }

    /// The field's line and, open, what is under it.
    func panelSheet(path: FieldPath, field: Resolved.Field, kind: FieldKind) -> FieldSheet {
        var sheet = FieldSheet()
        guard kind.opensInPanel else {
            sheet.lines = [singleLine(path: path, field: field, kind: kind)]
            return sheet
        }
        let value = values.value(at: path)
        let summary = FieldSummary.of(value, field: field, in: book, types: types, locale: locale)
        let isOpen = isOpen(path)
        let cell = FieldCell(path: path, field: field, control: .more(summary), value: value, shown: summary.text, mark: check.mark(at: path))
        sheet.lines = [FieldLine(cells: [cell], disclosure: isOpen)]
        if isOpen { sheet.lines += content(of: field, kind: kind, path: path, depth: 1) }
        return sheet
    }

    /// What is under an open node, at `depth`: its members, its lines, its items (each a node of its own).
    private func content(of field: Resolved.Field, kind: FieldKind, path: FieldPath, depth: Int) -> [FieldLine] {
        switch kind {
        case .group, .typeFields:
            return book.members(of: field).flatMap { memberLines($0, under: path, depth: depth) }
        case .list(let plain):
            return columnLines(path: path, field: field, kind: plain, depth: depth)
        case .choices(let options):
            return checkLines(path: path, field: field, options: options, depth: depth)
        case .pairs(let plain):
            return pairLines(path: path, field: field, kind: plain, depth: depth)
        case .listOfGroups, .listOfTypeFields:
            return itemLines(path: path, field: field, depth: depth)
        case .either(let first, let second):
            let branches = book.branches(of: field)
            guard branches.count == 2 else { return [] }
            let picked = branchFitting(values.value(at: path), [first, second])
            let kinds = [first, second]
            guard kinds[picked].hasMore else { return [singleLine(path: path, field: branches[picked], kind: kinds[picked], depth: depth)] }
            return content(of: branches[picked], kind: kinds[picked], path: path, depth: depth)
        default:
            return []
        }
    }

    private func singleLine(path: FieldPath, field: Resolved.Field, kind: FieldKind, depth: Int) -> FieldLine {
        var line = singleLine(path: path, field: field, kind: kind)
        line.depth = depth
        return line
    }

    /// A list of groups in the panel: a line an item, with its summary and a triangle, then the `add` line,
    /// which opens an empty item (stored when one of its cells is filled).
    private func itemLines(path: FieldPath, field: Resolved.Field, depth: Int) -> [FieldLine] {
        let held = draft(at: path, kind: .listOfGroups)
        guard let item = book.item(of: field) else { return [] }
        var lines: [FieldLine] = []
        for (place, slot) in held.slots.enumerated() {
            let isStored = slot.isStored
            let itemPath = path.index(held.storedIndex(ofLine: place))
            let value = isStored ? values.value(at: itemPath) : nil
            let summary: FieldSummary = isStored ? FieldSummary.of(value, field: item, in: book, types: types, locale: locale) : .empty(FieldWords.addLine)
            let isOpen = isOpen(itemPath)
            let cell = FieldCell(path: itemPath, field: item, control: .more(summary), value: value, shown: summary.text,
                                 mark: isStored ? check.mark(at: itemPath) : nil, isStored: isStored)
            lines.append(FieldLine(cells: [cell], depth: depth, disclosure: isOpen, list: path, slot: place))
            if isOpen { lines += book.members(of: item).flatMap { memberLines($0, under: itemPath, depth: depth + 1) } }
        }
        if held.slots.isEmpty { lines.append(noneLine(path: path, field: field)) }
        return lines
    }

    // MARK: A type's note

    private func kindsLine(_ field: Resolved.Field, kind: FieldKind, path: FieldPath, depth: Int) -> FieldLine {
        let words = kind.typeLabel(memberCount: kind == .group ? book.members(of: field).count : 0)
        let control: FieldCell.Control = kind.opensOnType ? .more(.value(words)) : .label(words)
        let cell = FieldCell(path: path, field: field, control: control, shown: words)
        return FieldLine(name: FieldName.words(of: field.field), isNeeded: field.field.isRequired, chip: kind.chip, cells: [cell], depth: depth)
    }

    private func kindsLevel(_ sheet: inout FieldSheet, path: FieldPath, field: Resolved.Field, kind: FieldKind, branch: Int?) {
        switch kind {
        case .group, .typeFields:
            sheet.lines = book.members(of: field).flatMap { memberLines($0, under: path, depth: 0) }
        case .listOfGroups, .listOfTypeFields:
            let item = book.item(of: field)
            sheet.lines = item.map(book.members(of:))?.flatMap { memberLines($0, under: path.index(0), depth: 0) } ?? []
        case .pairs(let plain):
            let valueField = book.pairValue(of: field) ?? field
            let name = Resolved.Field(field: ChainField(name: FieldWords.pairName, schema: Self.textSchema), source: field.source, introducedBy: field.introducedBy)
            let value = Resolved.Field(field: ChainField(name: FieldWords.pairValue, schema: valueField.field.schema), source: field.source, introducedBy: field.introducedBy)
            sheet.lines = [name, value].map { member in
                kindsLine(member, kind: .plain(member.field.name == FieldWords.pairName ? .text : plain), path: path.key(member.field.name), depth: 0)
            }
        case .choices(let options):
            sheet.layout = .checks
            sheet.lines = options.map { option in
                FieldLine(cells: [FieldCell(path: path, field: field, control: .check(false), value: option.value, shown: option.label)])
            }
        case .either(let first, let second):
            let branches = book.branches(of: field)
            guard branches.count == 2 else { break }
            let kinds = [first, second]
            let picked = min(max(branch ?? 0, 0), 1)
            sheet.branches = zip(branches, kinds).map { label(of: $1, field: $0) }
            sheet.branch = picked
            sheet.chip = Self.typeChip(of: kinds[picked])
            kindsLevel(&sheet, path: path, field: branches[picked], kind: kinds[picked], branch: nil)
        default:
            break
        }
    }

    // MARK: Stops

    /// Where the keyboard can stop, in reading order: the branch picked, then each line's cells that take it
    /// (a text cell, a box, a menu, a cell with more) or the line as a whole (a check line, a row with more
    /// that is the line's only cell, a triangle).
    static func stops(of sheet: FieldSheet) -> [FieldStop] {
        var stops: [FieldStop] = []
        if !sheet.branches.isEmpty { stops.append(FieldStop(line: -1, column: sheet.branch)) }
        for (place, line) in sheet.lines.enumerated() {
            if line.disclosure != nil {
                stops.append(FieldStop(line: place, column: -1))
                continue
            }
            for (column, cell) in line.cells.enumerated() {
                switch cell.control {
                case .check, .clear: stops.append(FieldStop(line: place, column: -1))
                case .more: stops.append(FieldStop(line: place, column: line.cells.count == 1 ? -1 : column))
                case .label: break
                case .text, .oneOf, .yesNo, .choice, .json: stops.append(FieldStop(line: place, column: column))
                }
            }
        }
        return stops
    }
}

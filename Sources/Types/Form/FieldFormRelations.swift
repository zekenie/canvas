import AppKit
import Canvas
import Mentions

// A relation row's card, as the form does it: a line for each relationship in the row (the note at the other end, then the
// relationship type's fields, each written to the line's arrow), and a blank line last that picks a note and draws the arrow.
// Everything done in it while it stays open is the card's one step (`Change Friends`): a cell on one arrow, a cell on another,
// a pick on the blank line, a line removed. The sheet is `FieldSheets.relationSheet`'s; what is here is what the form adds to it.

extension FieldWords {
    /// The first column's name where the row's other side is not one type: the note.
    public static let noteColumn = "note"
    /// A type's relation row whose other side has no type drawn: any note.
    public static let anyNote = "any"
    /// What a dashed pill says where its far end holds no name: a note that is gone, a board that cannot be shown, a pill
    /// that finds several notes; a pill that stands for nothing is a blank one.
    public static let noteGone = "Deleted"
    public static let noteUnavailable = "Not available"
    public static let noteQuery = "Notes"
    public static let noteBlank = " "
}

extension FieldFormView {
    /// The row the card is for, as the notes of this note's types have it now; nil once it is gone.
    func row(of relations: RelationCardRoot) -> RelationshipRow? {
        guard let relationships = editor.relationships, let list = editor.document[relations.note]?[IsAProperty.self]?.map(\.shape) else { return nil }
        return relationships.rows(for: list, isType: false).first { $0.key == relations.row.key }
    }

    /// The relationships of the row, one line each, in the order its pills are (by the name each shows, then the arrow's id).
    func relationLines(of relations: RelationCardRoot) -> [RelationLine] {
        guard let relationships = editor.relationships else { return [] }
        let row = self.row(of: relations) ?? relations.row
        var lines: [(line: RelationLine, sort: String)] = []
        for relation in relationships.relations(of: relations.note, in: row) {
            guard let record = editor.shape(inFile: relation.arrow) else { continue }
            let (target, label) = relationFace(of: relation.far.reading)
            let line = RelationLine(arrow: relation.arrow, other: target, label: label,
                                    values: record[FieldValuesProperty.self] ?? FieldValues(), check: effectiveCheck(of: relation.arrow),
                                    isReadOnly: editor.isReadOnly(inFile: relation.arrow))
            lines.append((line, label.lowercased()))
        }
        lines.sort { $0.sort == $1.sort ? $0.line.arrow.rawValue.uuidString < $1.line.arrow.rawValue.uuidString : $0.sort < $1.sort }
        return lines.map(\.line)
    }

    /// The note an end names and the name the line shows it by: its live name; the name a pill that is gone keeps, or a word.
    private func relationFace(of reading: EndReading) -> (target: ShapeID?, label: String) {
        func called(_ name: String?, _ words: String) -> String {
            let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            return name?.isEmpty == false ? name! : words
        }
        switch reading {
        case .note(let id), .notAdmitted(let id, _):
            return (id, editor.mentions?.resolve(id).appearance?.label ?? FieldWords.noteGone)
        case .gone(let name): return (nil, called(name, FieldWords.noteGone))
        case .unavailable(let name): return (nil, called(name, FieldWords.noteUnavailable))
        case .query(let name): return (nil, called(name, FieldWords.noteQuery))
        case .empty, .free: return (nil, FieldWords.noteBlank)
        }
    }

    /// The sheet of a row's card: its lines (the arrows it shows are kept in `owners`), and the blank line unless it is read.
    func relationSheet(_ relations: RelationCardRoot, book: FieldBook) -> FieldSheet {
        let row = self.row(of: relations) ?? relations.row
        let lines = relationLines(of: relations)
        owners = Set(lines.map(\.arrow)).union(lines.compactMap(\.other))
        let types = editor.types
        let name = types.map { row.name(in: $0.graph) } ?? ""
        var column = FieldWords.noteColumn
        if row.others.count == 1, let types, case .live(let title?) = types.name(of: TypeLink(row.others[0])) { column = title }
        return FieldSheets.relationSheet(RelationCardRoot(note: relations.note, row: row), lines: lines, noteColumn: column, rowName: name, book: book,
                                         isReadOnly: isReadOnly)
    }

    // MARK: Writing

    /// A note picked on the blank line: the relationship is drawn, in the card's step. The line it makes takes the blank's place
    /// and the caret goes to its first cell to fill in, else to the new blank line's.
    func relationPicked(_ picked: ShapeID) {
        guard let relations, !isReadOnly, let row = self.row(of: relations) else { return }
        let before = Set(owners)
        guard editor.relate(relations.note, to: picked, in: row, step: step.relationStep) != nil else { return }
        reload()
        // The new line: the one that was not shown. Its first editable cell, else the blank line.
        let fresh = sheet.lines.indices.first { place in
            guard let arrow = sheet.lines[place].owner else { return false }
            return !before.contains(arrow)
        }
        if let place = fresh, let stop = sheet.stops.first(where: { $0.line == place && $0.column > 0 }) {
            focus(stop)
        } else if let blank = sheet.stops.last(where: { $0.line == sheet.lines.count - 1 }) {
            focus(blank)
        }
    }

    /// Backspace or Delete on a stored line's note: the line goes, with its arrow, its values and the pill it empties, in the card's
    /// step. A line whose arrow cannot go shakes the note, as a pill deleted in the row does.
    func removeFocusedRelation(repeating: Bool = HeldKey.isRepeating) -> Bool {
        guard relations != nil, depth == 0, mode == .values, let stop = focus, let held = line(at: stop), let arrow = held.owner,
              let cell = cell(at: stop), case .note = cell.control, cell.isStored else { return false }
        if repeating { return true }
        cellEditor.dropsRepeats = true
        guard !isReadOnly else {
            tryAtReadOnly()
            return true
        }
        let place = stop.line
        guard editor.unrelate([arrow], shaking: relations?.note, step: step.relationStep) else { return true }
        reload()
        // The caret goes to the line that took its place, else the one before it, else the blank line.
        let lines = sheet.lines.indices
        let target = lines.contains(place) ? place : max(place - 1, 0)
        if let stop = sheet.stops.first(where: { $0.line == target }) { focus(stop) }
        return true
    }
}

extension FieldWriteStep {
    /// The same step for the writers of relationships.
    var relationStep: RelationStep {
        switch self {
        case .ownRun: .own
        case .card(let key): .card(key: key)
        }
    }
}

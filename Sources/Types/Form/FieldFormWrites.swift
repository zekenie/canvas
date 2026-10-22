import AppKit
import Canvas
import CanvasRPC

// What the form writes, always through the one writer with the level's step: each keystroke in a cell is a
// commit, a box, a choice and a check line are one, Remove is one. What the file does not hold yet (the
// waiting line, a line whose text was deleted, half a pair) is a slot of the level's `FieldDraft`, which
// changes before the write so the reload that follows finds it in step with what is stored.

extension FieldFormView {
    /// A card's writes join the step it holds (`.card(key:)`), except the fold's own level, where each
    /// row is its field's step; the panel's are a step a field (`.ownRun`).
    var step: FieldWriteStep {
        if isFold, depth == 0 { return .ownRun }
        return cardKey.map { FieldWriteStep.card(key: $0) } ?? .ownRun
    }

    private var writer: FieldWriter? { editor.fieldWriter }

    // MARK: Drafts

    func defaultDraft(_ path: FieldPath) -> FieldDraft? {
        guard let book = editor.fieldBook, let writer, let field = book.field(at: path, types: types) else { return nil }
        // An either's field has no kind of its own to say pairs: the sheet drew them or not, and the draft goes with that.
        let drawn = sheet.lines.contains { $0.list == path && $0.isPair }
        return FieldSheets.draft(at: path, kind: book.kind(of: field), values: writer.values(of: level.owner ?? shape), isReadOnly: isReadOnly, drawnAsPairs: drawn)
    }

    /// What the form keeps of the list or pairs at `path`: made as it is first needed, then followed.
    func draft(at path: FieldPath) -> FieldDraft {
        if let held = drafts[path] { return held }
        let made = defaultDraft(path) ?? FieldDraft(nil, waiting: !isReadOnly)
        drafts[path] = made
        return made
    }

    // MARK: Typing

    /// The text of the cell with the caret changed: a write, and a draft that follows.
    func typedInCell() {
        guard !isReadOnly, mode == .values, let stop = focus, let held = line(at: stop), let cell = cell(at: stop), isTypedControl(cell.control) else { return }
        let text = cellEditor.string
        cellEditor.scrollRangeToVisible(cellEditor.selectedRange())
        conflict = nil
        if let list = held.list, draft(at: list).isPairs {
            typedInPair(text, column: stop.column, line: held, list: list)
        } else {
            put(typedValue(text, for: cell), cell: cell, line: held)
        }
    }

    /// Whose values a line is: its arrow's on a row's card, else the level's, else the form's shape's.
    func owner(of line: FieldLine) -> ShapeID { line.owner ?? level.owner ?? shape }

    /// A value for a cell: in a file's own place, or, for a line of a list that is not stored, as a new item.
    func put(_ value: JSONValue?, cell: FieldCell, line held: FieldLine) {
        guard let writer else { return }
        let target = owner(of: cell)
        guard let list = held.list else {
            writer.set(value, at: cell.path, of: target, step: step)
            return reload()
        }
        var held_ = draft(at: list)
        guard held_.slots.indices.contains(held.slot) else { return }
        if held_.isPairs {
            // A pair's value cell is a plain value of a stored pair; a pair that is not stored has no name to put it under.
            guard held_.slots[held.slot].isStored else { return }
            writer.set(value, at: cell.path, of: target, step: step)
            return reload()
        }
        let before = writer.values(of: target)
        let items = before.value(at: list)?.arrayValue ?? []
        if held_.slots[held.slot].isStored {
            if value == nil {
                // Emptying the last cell of an item takes the item out; the line stays, empty.
                let after = before.setting(nil, at: cell.path).value(at: list)?.arrayValue?.count ?? 0
                if after < items.count { held_.blank(line: held.slot) }
            }
            drafts[list] = held_
            writer.set(value, at: cell.path, of: target, step: step)
        } else {
            guard let value else { return }
            var made = value
            if case .key(let member)? = cell.path.steps.last, cell.path.steps.count > list.steps.count + 1 { made = .object([member: value]) }
            var inserted = items
            inserted.insert(made, at: min(held_.storedIndex(ofLine: held.slot), inserted.count))
            held_.store(line: held.slot)
            drafts[list] = held_
            writer.set(.array(inserted), at: list, of: target, step: step)
        }
        reload()
    }

    // MARK: Pairs

    /// A pair's name or value typed. Both halves, and a name no other pair has, store it; until then it is a slot.
    private func typedInPair(_ text: String, column: Int, line held: FieldLine, list: FieldPath) {
        guard let writer, held.cells.count == 2 else { return }
        let shape = owner(of: held)
        var pairs = draft(at: list)
        guard pairs.slots.indices.contains(held.slot) else { return }
        var valueKind = PlainKind.text
        if case .text(let kind) = held.cells[1].control { valueKind = kind }
        let place = held.slot
        switch pairs.slots[place] {
        case .stored(let key?):
            if column == 0 {
                if text == key { return }
                if text.isEmpty {
                    pairs.slots[place] = .pair(name: "", value: held.cells[1].shown, taken: false)
                    drafts[list] = pairs
                    writer.remove(at: list.key(key), of: shape, step: step)
                } else if Self.isTaken(text, among: pairs.slots, except: place) {
                    conflict = FieldStop(line: held.slot, column: 0)
                } else {
                    pairs.slots[place] = .stored(key: text)
                    drafts[list] = pairs
                    writer.rename(key, to: text, under: list, of: shape, step: step)
                }
            } else if let value = FieldText.value(from: text, as: valueKind) {
                writer.set(value, at: list.key(key), of: shape, step: step)
            } else {
                pairs.slots[place] = .pair(name: key, value: "", taken: false)
                drafts[list] = pairs
                writer.remove(at: list.key(key), of: shape, step: step)
            }
        case .stored(nil):
            return
        case .blank, .pair:
            var name = "", value = ""
            if case .pair(let half, let held, _) = pairs.slots[place] { name = half; value = held }
            if column == 0 { name = text } else { value = text }
            let taken = Self.isTaken(name, among: pairs.slots, except: place)
            if name.isEmpty && value.isEmpty {
                pairs.slots[place] = .blank
            } else if !name.isEmpty, !value.isEmpty, !taken {
                pairs.slots[place] = .stored(key: name)
                pairs.ensureWaiting()
                drafts[list] = pairs
                writer.set(FieldText.value(from: value, as: valueKind), at: list.key(name), of: shape, step: step)
            } else {
                pairs.slots[place] = .pair(name: name, value: value, taken: taken)
                pairs.ensureWaiting()
            }
        }
        drafts[list] = pairs
        reload()
    }

    /// A name another line has: a stored pair's key, or a half-typed pair's name.
    private static func isTaken(_ name: String, among slots: [FieldDraft.Slot], except place: Int) -> Bool {
        guard !name.isEmpty else { return false }
        return slots.enumerated().contains { other, slot in
            guard other != place else { return false }
            switch slot {
            case .stored(let key): return key == name
            case .pair(let half, _, _): return half == name
            case .blank: return false
            }
        }
    }

    // MARK: Boxes, menus, checks

    func toggleBox(_ cell: FieldCell, line held: FieldLine) {
        guard !isReadOnly else { return tryAtReadOnly() }
        put(.bool(cell.value != .bool(true)), cell: cell, line: held)
    }

    /// A menu of the options with a check by the current one, `None` last.
    func showChoices(_ cell: FieldCell, line held: FieldLine, stop: FieldStop) {
        guard !isReadOnly else { return tryAtReadOnly() }
        guard case .choice(let options) = cell.control else { return }
        let menu = NSMenu()
        for (place, option) in options.enumerated() {
            let item = NSMenuItem(title: option.label, action: #selector(choicePicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = place
            item.state = cell.value == option.value ? .on : .off
            menu.addItem(item)
        }
        let none = NSMenuItem(title: FieldWords.none, action: #selector(choicePicked(_:)), keyEquivalent: "")
        none.target = self
        none.tag = -1
        menu.addItem(none)
        choiceStop = stop
        let rect = grid.cellRect(line: stop.line, column: max(stop.column, 0))
        present(menu, at: CGPoint(x: rect.minX, y: rect.maxY), in: grid)
    }

    @objc private func choicePicked(_ item: NSMenuItem) {
        guard let stop = choiceStop, let held = line(at: stop), let cell = cell(at: stop), case .choice(let options) = cell.control else { return }
        put(options.indices.contains(item.tag) ? options[item.tag].value : nil, cell: cell, line: held)
    }

    /// A check line ticks or clears its option; the card stays open.
    func toggleCheck(_ cell: FieldCell) {
        guard !isReadOnly else { return tryAtReadOnly() }
        guard let option = cell.value, let writer else { return }
        let shape = owner(of: cell)
        var picked = writer.values(of: shape).value(at: cell.path)?.arrayValue ?? []
        if let place = picked.firstIndex(of: option) { picked.remove(at: place) } else { picked.append(option) }
        let order = sheet.lines.compactMap { held -> JSONValue? in
            guard let cell = held.cells.first, case .check = cell.control else { return nil }
            return cell.value
        }
        let kept = order.filter(picked.contains) + picked.filter { !order.contains($0) }
        writer.set(kept.isEmpty ? nil : .array(kept), at: cell.path, of: shape, step: step)
        reload()
    }

    /// `None` clears them all.
    func clearChecks(_ cell: FieldCell) {
        guard !isReadOnly else { return tryAtReadOnly() }
        writer?.set(nil, at: cell.path, of: owner(of: cell), step: step)
        reload()
    }

    // MARK: Removing a line

    /// Backspace on an empty line takes the line out (never the waiting one), and the caret goes to the end of the line before.
    func backspaceOnEmptyLine() -> Bool {
        guard cellEditor.string.isEmpty, mode == .values, !isReadOnly, let stop = focus, let held = line(at: stop), let list = held.list else { return false }
        let slots = draft(at: list)
        guard slots.slots.indices.contains(held.slot) else { return false }
        let isPairs = slots.isPairs
        if isPairs, stop.column != 0 { return false }
        if !isPairs, held.cells.count > 1, !held.cells.allSatisfy({ $0.shown.isEmpty }) { return false }
        if held.slot == slots.slots.count - 1, slots.slots[held.slot] == .blank { return true }
        if HeldKey.isRepeating { return true }
        remove(held, column: stop.column)
        return true
    }

    /// Takes a line out of its list: the draft first, then the stored item or pair, if it was one.
    func remove(_ held: FieldLine, column: Int) {
        guard let list = held.list, let writer else { return }
        let shape = owner(of: held)
        var slots = draft(at: list)
        guard slots.slots.indices.contains(held.slot) else { return }
        let slot = slots.slots[held.slot], index = slots.storedIndex(ofLine: held.slot)
        slots.remove(line: held.slot)
        drafts[list] = slots
        switch slot {
        case .stored(let key?): writer.remove(at: list.key(key), of: shape, step: step)
        case .stored(nil): writer.remove(at: list.index(index), of: shape, step: step)
        case .blank, .pair: break
        }
        let removedAt = sheet.lines.firstIndex(of: held)
        reload()
        // The line before it in the same list (a slot is the draft's number; the sheet's lines may start anywhere), else the
        // nearest stop at or above where it was.
        let before = sheet.lines.indices.first { sheet.lines[$0].list == list && sheet.lines[$0].slot == max(held.slot - 1, 0) }
        let target = before ?? max((removedAt ?? 0) - 1, 0)
        if let stop = sheet.stops.last(where: { $0.line == target && $0.column == max(column, 0) }) ?? sheet.stops.last(where: { $0.line <= target }) {
            focus(stop)
            if editorStop != nil { cellEditor.setSelectedRange(NSRange(location: (cellEditor.string as NSString).length, length: 0)) }
        }
    }

    /// The line a stop is on, when a right-click or a key can take it out: a line of a list, a table or pairs, never on rows, the
    /// waiting line, or read-only.
    func removableLine(at stop: FieldStop) -> FieldLine? {
        guard mode == .values, !isReadOnly, let held = line(at: stop), let list = held.list else { return nil }
        let slots = draft(at: list).slots
        guard slots.indices.contains(held.slot), !(held.slot == slots.count - 1 && slots[held.slot] == .blank) else { return nil }
        return held
    }

    /// ⌫, ⌦ or ⌘⌫ on a stop of a line that can go: the line is taken out, in one step. False for a stop on a line that cannot.
    func removeFocusedLine(repeating: Bool = HeldKey.isRepeating) -> Bool {
        guard let stop = focus, let held = removableLine(at: stop) else { return false }
        // A held key is one press: it takes one line out, not the lines the caret moves on to.
        if repeating { return true }
        cellEditor.dropsRepeats = true
        remove(held, column: stop.column)
        return true
    }

    /// The right-click menu of a line of a list, a table or pairs: `Remove` (`removableLine`).
    public func contextMenu(for stop: FieldStop) -> NSMenu? {
        guard removableLine(at: stop) != nil else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: FieldWords.remove, action: #selector(removePicked(_:)), keyEquivalent: "")
        item.target = self
        item.tag = stop.line
        item.representedObject = stop.column as NSNumber
        menu.addItem(item)
        return menu
    }

    @objc private func removePicked(_ item: NSMenuItem) {
        guard sheet.lines.indices.contains(item.tag) else { return }
        remove(sheet.lines[item.tag], column: (item.representedObject as? NSNumber)?.intValue ?? 0)
    }
}

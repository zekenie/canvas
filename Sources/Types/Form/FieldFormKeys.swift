import AppKit
import Canvas
import Mentions
import TextEditing

// Every key of rows-and-cards. A text cell's editor hands the form its commands (`textView(_:doCommandBy:)`:
// Tab, ⇧Tab, Return, Esc, Up, Down, Backspace on an empty line); every other stop has the keyboard itself
// (`keyDown`). Both end in the same few moves: to a stop, into a row with more and back out, or off the form.

extension FieldFormView: NSTextViewDelegate {
    public func textDidChange(_ notification: Notification) {
        guard !isLoadingEditor else { return }
        if (notification.object as AnyObject?) === jsonEditor { return jsonTyped() }
        guard (notification.object as AnyObject?) === cellEditor else { return }
        if picking != nil { return noteQueryChanged() }
        typedInCell()
    }

    public func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if textView === jsonEditor {
            // Tab leaves the box; Esc and everything else are the text's own, and the panel's.
            switch KeyMeaning(command: selector) {
            case .next: tab(forward: true)
            case .previous: tab(forward: false)
            default: return false
            }
            return true
        }
        guard textView === cellEditor else { return false }
        // ⌘⌫ in a cell takes its line out where a line can go; elsewhere it is the text's (to the start of the line).
        if selector == #selector(NSResponder.deleteToBeginningOfLine(_:)) { return removeFocusedLine() }
        guard let reading = KeyMeaning.Reading(command: selector) else { return false }
        switch reading.meaning {
        case .next: tab(forward: true)
        case .previous: tab(forward: false)
        case .activate:
            guard reading.modifiers.isEmpty else { return false }
            returnKey()
        case .up: vertical(-1)
        case .down: vertical(1)
        case .back:
            // The panel's Esc is the panel's: it hands the keyboard back to the canvas.
            guard presentation == .card else { return false }
            escape()
        case .delete:
            guard selector == #selector(NSResponder.deleteBackward(_:)) else { return false }
            return backspaceOnEmptyLine()
        default: return false
        }
        return true
    }

    public override func keyDown(with event: NSEvent) {
        let reading = KeyMeaning.Reading(event: event)
        // ⌘↩ finishes, from a stop that is no text as from a cell (`cellEditor.onCommit`).
        if reading?.meaning == .finish { return finish() }
        // ⌫ and ⌦ on a line that can go, with ⌘ or not.
        if reading?.meaning == .delete, let modifiers = reading?.modifiers, modifiers.subtracting(.command).isEmpty {
            if !removeFocusedRelation(repeating: event.isARepeat), !removeFocusedLine(repeating: event.isARepeat) { super.keyDown(with: event) }
            return
        }
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return super.keyDown(with: event) }
        guard let reading else {
            if !typeToPickNote(event) { super.keyDown(with: event) }
            return
        }
        switch reading.meaning {
        case .next: tab(forward: !reading.modifiers.contains(.shift))
        case .previous: tab(forward: false)
        case .activate: returnKey()
        case .toggle: spaceKey()
        case .back: if presentation == .panel { super.keyDown(with: event) } else { escape() }
        case .up: vertical(-1)
        case .down: vertical(1)
        case .left: horizontal(-1)
        case .right: horizontal(1)
        case .finish, .delete: super.keyDown(with: event)
        }
    }

    // MARK: Moving between stops

    func tab(forward: Bool) {
        let stops = sheet.stops
        guard let current = focus, let place = stops.firstIndex(of: current) else {
            focus(forward ? stops.first : stops.last)
            return
        }
        let next = place + (forward ? 1 : -1)
        if stops.indices.contains(next) { focus(stops[next]) } else { tabOff(forward: forward) }
    }

    /// Off the last stop or the first: out of a level, to the stop after the one it was opened from (or that
    /// one, going back), else out of the form: the card closes (`onClose`), the panel's keyboard goes on to its next
    /// or previous key view, or stays where it is where there is none.
    private func tabOff(forward: Bool) {
        if depth > 0 {
            let from = level.from
            popLevel()
            guard let from else { return }
            if !forward { return focus(from) }
            if let place = sheet.stops.firstIndex(of: from), sheet.stops.indices.contains(place + 1) {
                focus(sheet.stops[place + 1])
            } else {
                tabOff(forward: true)
            }
            return
        }
        guard presentation == .card else {
            if forward { window?.selectKeyView(following: self) } else { window?.selectKeyView(preceding: self) }
            return
        }
        onClose?(.tabbed(forward: forward))
    }

    /// The stop above or below, in the same column where there is one, else the nearest.
    func vertical(_ delta: Int) {
        guard let current = focus else { return }
        let beyond = sheet.stops.filter { delta < 0 ? $0.line < current.line : $0.line > current.line }
        guard let line = delta < 0 ? beyond.map(\.line).max() : beyond.map(\.line).min() else { return }
        let column = max(current.column, 0)
        focus(beyond.filter { $0.line == line }.min { abs(max($0.column, 0) - column) < abs(max($1.column, 0) - column) })
    }

    /// Left and right on a stop that is no text go to the stop before and after it on its line, and stay at the ends. On the branch
    /// names they pick one.
    private func horizontal(_ delta: Int) {
        guard let current = focus else { return }
        if current.line == -1 { return pickBranch(min(max(current.column + delta, 0), sheet.branches.count - 1)) }
        let line = sheet.stops.filter { $0.line == current.line }
        guard let place = line.firstIndex(of: current), line.indices.contains(place + delta) else { return }
        focus(line[place + delta])
    }

    // MARK: Return, Space, Esc

    func returnKey() {
        guard let stop = focus else { return }
        if stop.line == -1 { return tab(forward: true) }
        guard let held = line(at: stop), let cell = cell(at: stop) else { return }
        if held.disclosure != nil { return toggleNode(held) }
        switch cell.control {
        case .more: return activate(stop)
        case .check, .clear: return activate(stop)
        case .choice where isReadOnly: return tryAtReadOnly()
        // A pill goes to its note; the blank line lists the notes it may name.
        case .note(let target?): return editor.mentions?.follow(target) ?? ()
        case .note: return startNotePicking(at: stop)
        default: break
        }
        if sheet.layout == .rows && held.list == nil {
            if let place = sheet.stops.firstIndex(of: stop), sheet.stops.indices.contains(place + 1) { focus(sheet.stops[place + 1]) } else { endOfLevel(.returned) }
            return
        }
        if isBlankLast(held) { return endOfLevel(.returned) }
        switch sheet.layout {
        case .table:
            if let next = sheet.stops.first(where: { $0.line > stop.line }) { focus(next) } else { endOfLevel(.returned) }
        default:
            if let place = sheet.stops.firstIndex(of: stop), sheet.stops.indices.contains(place + 1) { focus(sheet.stops[place + 1]) } else { endOfLevel(.returned) }
        }
    }

    /// The waiting line: the last, with nothing in it.
    private func isBlankLast(_ held: FieldLine) -> Bool {
        guard let list = held.list, let slots = drafts[list]?.slots ?? defaultDraft(list)?.slots, held.slot == slots.count - 1 else { return false }
        return slots[held.slot] == .blank && held.cells.allSatisfy { $0.shown.isEmpty }
    }

    /// Return on the last row or a blank last line, as Esc: a level in goes back, the top closes the card.
    private func endOfLevel(_ closing: Closing) {
        if depth > 0 { return popLevel() }
        if presentation == .card { onClose?(closing) }
    }

    func escape() {
        if depth > 0 { return popLevel() }
        onClose?(.escaped)
    }

    /// ⌘↩: what Esc does at the top level, from any depth. The panel's form has nothing to finish; its text boxes keep the keyboard.
    func finish() {
        guard presentation == .card else { return }
        while depth > 0 { popLevel() }
        onClose?(.escaped)
    }

    func spaceKey() {
        guard let stop = focus, stop.line >= 0, let held = line(at: stop), let cell = cell(at: stop) else { return }
        if held.disclosure != nil { return toggleNode(held) }
        switch cell.control {
        case .yesNo, .check, .clear, .choice: activate(stop)
        case .note: startNotePicking(at: stop)
        default: break
        }
    }

    // MARK: Opening and going back

    /// A click, Return or Space on a stop.
    public func activate(_ stop: FieldStop) {
        if stop.line == -1 { return pickBranch(stop.column) }
        guard let held = line(at: stop), let cell = cell(at: stop) else { return }
        focus(stop)
        if held.disclosure != nil { return toggleNode(held) }
        switch cell.control {
        case .text, .oneOf, .json: break
        case .yesNo: toggleBox(cell, line: held)
        case .choice: showChoices(cell, line: held, stop: stop)
        case .more: open(cell, from: stop)
        case .check: toggleCheck(cell)
        case .clear: clearChecks(cell)
        case .note: startNotePicking(at: stop)
        case .label: break
        }
    }

    /// A row with more opens in the same card, with a line to go back. `Other` goes to the panel.
    private func open(_ cell: FieldCell, from stop: FieldStop) {
        guard let book = editor.fieldBook else { return }
        let kind = book.kind(of: cell.field)
        if kind == .other { return FieldCards.revealInPanel(shape, in: editor, mode: mode) }
        guard presentation == .card, mode == .kinds ? kind.opensOnType : kind.hasMore else { return }
        var title = FieldName.words(of: cell.field.field)
        if title.isEmpty { title = level.title }
        levels.append(FormLevel(path: cell.path, field: cell.field, kind: kind, title: title, from: stop, owner: cell.owner ?? level.owner))
        if isFold, depth == 1, mode == .values, !isReadOnly { editor.setCardStep(FieldName.stepName(of: cell.field.field)) }
        focus = nil
        sheet = FieldSheet()
        rebuild()
        focusFirst()
    }

    /// Back one level, to the stop it was opened from.
    func popLevel() {
        guard depth > 0 else { return }
        let from = level.from
        levels.removeLast()
        if isFold, depth == 0, mode == .values, !isReadOnly { editor.setCardStep(nil) }
        focus = nil
        rebuild()
        focus(from)
    }

    public func goBack() { popLevel() }

    /// Picking the other branch name shows its control, empty; nothing is written.
    func pickBranch(_ branch: Int) {
        guard sheet.branches.indices.contains(branch) else { return }
        levels[levels.count - 1].branch = branch
        drafts[level.path] = nil
        focus = FieldStop(line: -1, column: branch)
        rebuild()
        focus(FieldStop(line: -1, column: branch))
    }

    /// A triangle: opens or closes the node, which the person's choice keeps for the session.
    func toggleNode(_ held: FieldLine) {
        guard let path = held.cells.first?.path else { return }
        var nodes = openNodes
        nodes[path] = !(held.disclosure ?? false)
        openNodes = nodes
        reload()
    }

    /// A try at a read-only shape's box or choice shakes the shape, as its rows do; in the panel nothing does.
    func tryAtReadOnly() {
        guard presentation == .card, mode == .values, isReadOnly else { return }
        editor.refuseChanges(to: [shape])
    }
}

/// Whether the key being handled is a held one repeating. A destructive key (a line, a field, a relationship taken out) is one
/// press however long it is held: the keyboard moves on to the next line, and a repeat would take that out too.
@MainActor
enum HeldKey {
    static var isRepeating: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.isARepeat
    }
}

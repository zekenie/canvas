import AppKit
import Canvas

// Every key of rows-and-cards. A text cell's editor hands the form its commands (`textView(_:doCommandBy:)`:
// Tab, ⇧Tab, Return, Esc, Up, Down, Backspace on an empty line); every other stop has the keyboard itself
// (`keyDown`). Both end in the same few moves: to a stop, into a row with more and back out, or off the form.

extension FieldFormView: NSTextViewDelegate {
    public func textDidChange(_ notification: Notification) {
        guard !isLoadingEditor else { return }
        if (notification.object as AnyObject?) === jsonEditor { return jsonTyped() }
        guard (notification.object as AnyObject?) === cellEditor else { return }
        typedInCell()
    }

    public func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if textView === jsonEditor {
            // Tab leaves the box; Esc and everything else are the text's own, and the panel's.
            switch selector {
            case #selector(NSResponder.insertTab(_:)): tab(forward: true)
            case #selector(NSResponder.insertBacktab(_:)): tab(forward: false)
            default: return false
            }
            return true
        }
        guard textView === cellEditor else { return false }
        switch selector {
        case #selector(NSResponder.insertTab(_:)): tab(forward: true)
        case #selector(NSResponder.insertBacktab(_:)): tab(forward: false)
        case #selector(NSResponder.insertNewline(_:)): returnKey()
        case #selector(NSResponder.moveUp(_:)): vertical(-1)
        case #selector(NSResponder.moveDown(_:)): vertical(1)
        case #selector(NSResponder.cancelOperation(_:)):
            // The panel's Esc is the panel's: it hands the keyboard back to the canvas.
            guard presentation == .card else { return false }
            escape()
        case #selector(NSResponder.deleteBackward(_:)): return backspaceOnEmptyLine()
        default: return false
        }
        return true
    }

    public override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 48: tab(forward: !shift)
        case 36, 76: returnKey()
        case 49: spaceKey()
        case 53:
            if presentation == .panel { super.keyDown(with: event) } else { escape() }
        case 126: vertical(-1)
        case 125: vertical(1)
        case 123: horizontal(-1)
        case 124: horizontal(1)
        default: super.keyDown(with: event)
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

    /// Left and right on the branch names pick one.
    private func horizontal(_ delta: Int) {
        guard let current = focus, current.line == -1 else { return }
        pickBranch(min(max(current.column + delta, 0), sheet.branches.count - 1))
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

    func spaceKey() {
        guard let stop = focus, stop.line >= 0, let held = line(at: stop), let cell = cell(at: stop) else { return }
        if held.disclosure != nil { return toggleNode(held) }
        switch cell.control {
        case .yesNo, .check, .clear, .choice: activate(stop)
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
        levels.append(FormLevel(path: cell.path, field: cell.field, kind: kind, title: title, from: stop))
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

import AppKit
import Canvas
import Mentions
import TextEditing

// A note's cell in the form (a line of a card that names a note): its pill, a click on it going to the note, and the
// list of the notes it may name, which the one cell editor is laid over the cell to find in. Typing on a focused cell,
// Space, Return or a click off the pill opens it; Return or a click on a line picks, and Tab, ⇧Tab and Escape close it
// with nothing stored: the field's text is a query, never a value, so nothing is written (or told to the check) until a
// pick, and a pick closes the list (the cell's owner writes).

extension TypesStyle {
    /// A pill's line in the form: a row less a point above and below.
    static let formNoteLineHeight: CGFloat = formRowHeight - 2
}

extension FieldFormView {
    /// The pills' look in the form: Mentions' outlined pill (white, a hairline, the live name, no symbol: board 5 panel 2), in the
    /// form's font, its name in the rows' dark ink (the pill is white in either appearance); a wrong one in the wrong red.
    func noteStyle(wrong: Bool) -> MentionTextStyle {
        MentionTextStyle(font: font, color: wrong ? TypesStyle.wrongInk : TypesStyle.rowInk, lineHeight: TypesStyle.formNoteLineHeight, surface: .outlined)
    }

    /// The pill a note cell shows: the note's attachment, named as a mention of it is now (the cell's `shown` while the note is gone),
    /// no wider than `width`; nil for a cell that names no note.
    func notePill(of cell: FieldCell, width: CGFloat?) -> (attachment: MentionAttachment, target: ShapeID)? {
        guard case .note(let target?) = cell.control else { return nil }
        let resolution = editor.mentions?.resolve(target) ?? .missing
        let attachment = MentionAttachment(target: PartAddress(target), storedLabel: cell.shown, resolution: resolution, style: noteStyle(wrong: cell.mark == .wrong), width: width)
        return (attachment, target)
    }

    /// Where a note cell's pill is, from the cell's rect: left-aligned, centered on its row.
    func notePillRect(of cell: FieldCell, in rect: CGRect) -> CGRect? {
        guard let pill = notePill(of: cell, width: rect.width) else { return nil }
        let height = TypesStyle.formNoteLineHeight
        return CGRect(x: rect.minX, y: rect.midY - height / 2, width: min(ceil(pill.attachment.layout.bounds.width), rect.width), height: height)
    }

    /// The note a press on a live pill goes to: the pill under a point of the grid; none for a dashed pill (a press there acts as one
    /// on the rest of the cell) and for anything else.
    func pillTarget(atGrid point: CGPoint) -> ShapeID? {
        let place = line(atY: point.y)
        guard point.y >= 0, sheet.lines.indices.contains(place) else { return nil }
        let held = sheet.lines[place]
        for (column, cell) in held.cells.enumerated() {
            guard case .note = cell.control, let pill = notePill(of: cell, width: nil), pill.attachment.layout.isLive else { continue }
            if let rect = notePillRect(of: cell, in: grid.cellRect(line: place, column: column)), rect.contains(point) { return pill.target }
        }
        return nil
    }

    // MARK: The list

    private func isNoteStop(_ stop: FieldStop) -> Bool {
        guard let cell = cell(at: stop), case .note = cell.control else { return false }
        return cell.isEditable && !isReadOnly && mode == .values
    }

    /// Opens the list of the notes the focused cell may name under it, the editor over the cell holding `typed`. Nothing is written.
    func startNotePicking(at stop: FieldStop, typed: String = "") {
        guard picking == nil, isNoteStop(stop), let picker = makePicker?(shape) else { return }
        focus(stop)
        isLoadingEditor = true
        cellEditor.font = font
        cellEditor.textColor = TypesStyle.formValueInk
        cellEditor.typingAttributes = [.font: font, .foregroundColor: TypesStyle.formValueInk]
        cellEditor.string = typed
        cellEditor.setSelectedRange(NSRange(location: (typed as NSString).length, length: 0))
        isLoadingEditor = false
        placeNoteEditor(at: stop)
        cellClip.isHidden = false
        cellEditor.undoManager?.removeAllActions()
        picker.setQuery(typed)
        let listWindow = CaretListWindow(picker.list, accessibilityLabel: TypesStyle.relationPickerAccessibilityLabel, over: cellEditor,
                                         anchorRect: { [weak self] in self?.screenRect(of: stop) },
                                         pick: { [weak self] row in self?.notePicked(row: row) },
                                         close: { [weak self] in self?.endNotePicking() })
        picker.list.onChange = { [weak listWindow] in listWindow?.listDidChange() }
        picking = (picker, listWindow, stop)
        cellEditor.picking = (picker, listWindow)
        if let window, window.firstResponder !== cellEditor { window.makeFirstResponder(cellEditor) }
        grid.needsDisplay = true
        listWindow.listDidChange()
    }

    /// The editor over the note's cell, as over a text cell.
    func placeNoteEditor(at stop: FieldStop) {
        let rect = grid.cellRect(line: stop.line, column: stop.column)
        cellClip.frame = rect
        let inset = max((rect.height - font.boundingRectForFont.height) / 2, 0)
        cellEditor.textContainerInset = NSSize(width: 0, height: inset)
        cellEditor.minSize = rect.size
        cellEditor.frame = NSRect(origin: .zero, size: rect.size)
    }

    private func screenRect(of stop: FieldStop) -> CGRect? {
        guard let window, sheet.lines.indices.contains(stop.line) else { return nil }
        let rect = grid.cellRect(line: stop.line, column: stop.column)
        return window.convertToScreen(grid.convert(rect, to: nil))
    }

    /// The list closed, picked from or not: the editor goes (the keyboard to the form), nothing else changes.
    func endNotePicking() {
        guard let listed = picking else { return }
        picking = nil
        cellEditor.picking = nil
        listed.window.dismiss()
        // The keyboard first: a view hidden while it has it hands it to the window.
        if window?.firstResponder === cellEditor { window?.makeFirstResponder(self) }
        if editorStop == nil { cellClip.isHidden = true }
        grid.needsDisplay = true
    }

    /// What was typed in the cell with the list open is a query.
    func noteQueryChanged() {
        guard let picking = picking else { return }
        picking.picker.setQuery(cellEditor.string)
    }

    /// A line of the list picked (Return, or a click): the list goes and the cell keeps the keyboard. The pick is the
    /// list's (`NotePicking.pickNote(row:)` has told Mentions); this view writes nothing, but for a row's card, where the pick
    /// on the blank line draws the relationship (`relationPicked`), in the card's step.
    func notePicked(row: Int) {
        guard let picking = picking, let note = picking.picker.pickNote(row: row) else { return }
        endNotePicking()
        relationPicked(note)
    }

    // MARK: Keys

    /// A printable key on a focused note cell opens the list with it typed; false for any other key.
    func typeToPickNote(_ event: NSEvent) -> Bool {
        guard let stop = focus, isNoteStop(stop), let typed = event.characters, !typed.isEmpty,
              typed.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value) }) else { return false }
        startNotePicking(at: stop, typed: typed)
        return true
    }
}

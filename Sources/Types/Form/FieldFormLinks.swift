import AppKit
import Canvas
import Mentions
import TextEditing

// A link's cell in the form (a pointer, one line of a list of pointers, a table's member): its pill, a click on
// it going to the note, and the list of the notes it may point at, which the one cell editor is laid over the
// cell to find in. Typing on a focused cell, Space, Return or a click off the pill opens it; Return or a click on a
// line picks, and Tab, ⇧Tab and Escape close it with nothing stored: the field's text is a query, never a value,
// so nothing is written (or told to the check) until a pick. Backspace on the cell clears it (a list's line goes).

extension TypesStyle {
    /// A pill's line in the form: a row less a point above and below.
    static let formLinkLineHeight: CGFloat = formRowHeight - 2
}

extension FieldFormView {
    /// The pills' look in the form: Mentions' outlined pill (white, a hairline, the live name, no symbol: board 5 panel 2), in the
    /// form's font, its name in the rows' dark ink (the pill is white in either appearance); a wrong one in the wrong red.
    func linkStyle(wrong: Bool) -> MentionTextStyle {
        MentionTextStyle(font: font, color: wrong ? TypesStyle.wrongInk : TypesStyle.rowInk, lineHeight: TypesStyle.formLinkLineHeight, surface: .outlined)
    }

    /// The pill a link cell shows: its token's attachment, no wider than `width`; nil for a cell holding no token.
    func linkPill(of cell: FieldCell, width: CGFloat?) -> (attachment: MentionAttachment, link: FieldLink)? {
        guard case .link = cell.control, let value = cell.value, let link = FieldLink(value), let book = editor.fieldBook else { return nil }
        let attachment = MentionAttachment(target: link.target, storedLabel: link.stored, resolution: book.resolution(of: link), style: linkStyle(wrong: cell.mark == .wrong),
                                           width: width)
        return (attachment, link)
    }

    /// Where a link cell's pill is, from the cell's rect: left-aligned, centered on its row.
    func linkPillRect(of cell: FieldCell, in rect: CGRect) -> CGRect? {
        guard let pill = linkPill(of: cell, width: rect.width) else { return nil }
        let height = TypesStyle.formLinkLineHeight
        return CGRect(x: rect.minX, y: rect.midY - height / 2, width: min(ceil(pill.attachment.layout.bounds.width), rect.width), height: height)
    }

    /// The note a press on a live pill goes to: the pill under a point of the grid; none for a dashed pill (a press there acts as one
    /// on the rest of the cell) and for anything else.
    func pillTarget(atGrid point: CGPoint) -> ShapeID? {
        let place = line(atY: point.y)
        guard point.y >= 0, sheet.lines.indices.contains(place) else { return nil }
        let held = sheet.lines[place]
        for (column, cell) in held.cells.enumerated() {
            guard case .link = cell.control, let pill = linkPill(of: cell, width: nil), pill.attachment.layout.isLive else { continue }
            if let rect = linkPillRect(of: cell, in: grid.cellRect(line: place, column: column)), rect.contains(point) { return pill.link.target }
        }
        return nil
    }

    // MARK: The list

    private func isLinkStop(_ stop: FieldStop) -> Bool {
        guard let cell = cell(at: stop), case .link = cell.control else { return false }
        return cell.isEditable && !isReadOnly && mode == .values
    }

    /// Opens the list of the notes the focused cell may point at under it, the editor over the cell holding `typed`. Nothing is written.
    func startLinkPicking(at stop: FieldStop, typed: String = "") {
        guard linkPicking == nil, isLinkStop(stop), let cell = cell(at: stop), case .link(let type) = cell.control else { return }
        focus(stop)
        let picker = LinkPicker(editor: editor, owner: shape, type: type)
        isLoadingEditor = true
        cellEditor.font = font
        cellEditor.textColor = TypesStyle.formValueInk
        cellEditor.typingAttributes = [.font: font, .foregroundColor: TypesStyle.formValueInk]
        cellEditor.string = typed
        cellEditor.setSelectedRange(NSRange(location: (typed as NSString).length, length: 0))
        isLoadingEditor = false
        placeLinkEditor(at: stop)
        cellClip.isHidden = false
        cellEditor.undoManager?.removeAllActions()
        picker.setQuery(typed)
        let listWindow = CaretListWindow(picker.list, accessibilityLabel: TypesStyle.linkPickerAccessibilityLabel, over: cellEditor,
                                         anchorRect: { [weak self] in self?.screenRect(of: stop) },
                                         pick: { [weak self] row in self?.linkPicked(row: row) },
                                         close: { [weak self] in self?.endLinkPicking() })
        picker.list.onChange = { [weak listWindow] in listWindow?.listDidChange() }
        linkPicking = (picker, listWindow, stop)
        cellEditor.linkPicking = (picker, listWindow)
        if let window, window.firstResponder !== cellEditor { window.makeFirstResponder(cellEditor) }
        grid.needsDisplay = true
        listWindow.listDidChange()
    }

    /// The editor over the link's cell, as over a text cell.
    func placeLinkEditor(at stop: FieldStop) {
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
    func endLinkPicking() {
        guard let picking = linkPicking else { return }
        linkPicking = nil
        cellEditor.linkPicking = nil
        picking.window.dismiss()
        // The keyboard first: a view hidden while it has it hands it to the window.
        if window?.firstResponder === cellEditor { window?.makeFirstResponder(self) }
        if editorStop == nil { cellClip.isHidden = true }
        grid.needsDisplay = true
    }

    /// What was typed in the cell with the list open is a query.
    func linkQueryChanged() {
        guard let picking = linkPicking else { return }
        picking.picker.setQuery(cellEditor.string)
    }

    /// A line of the list picked (Return, or a click): the link is written as the cell's value (a waiting line stores a new item), the list
    /// goes and the cell keeps the keyboard.
    func linkPicked(row: Int) {
        guard let picking = linkPicking, let link = picking.picker.pick(row: row), let held = line(at: picking.stop), let cell = cell(at: picking.stop) else { return }
        endLinkPicking()
        put(link.value, cell: cell, line: held)
    }

    // MARK: Keys

    /// A printable key on a focused link cell opens the list with it typed; false for any other key.
    func typeToPickLink(_ event: NSEvent) -> Bool {
        guard let stop = focus, isLinkStop(stop), let typed = event.characters, !typed.isEmpty,
              typed.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value) }) else { return false }
        startLinkPicking(at: stop, typed: typed)
        return true
    }

    /// Backspace or Delete on a focused link cell: it clears a value (one step), and takes a list's line out as Backspace on an empty
    /// line does; false where the key is not the cell's.
    func clearLink(event: NSEvent) -> Bool {
        guard event.keyCode == 51 || event.keyCode == 117, let stop = focus, isLinkStop(stop), let held = line(at: stop), let cell = cell(at: stop) else { return false }
        if cell.value == nil {
            // An empty line of a list (never the waiting one) goes.
            if sheet.layout == .column, let list = held.list, held.slot < draft(at: list).slots.count - 1 { remove(held, column: 0) }
            return true
        }
        if sheet.layout == .column, held.list != nil { remove(held, column: 0) } else { put(nil, cell: cell, line: held) }
        return true
    }
}

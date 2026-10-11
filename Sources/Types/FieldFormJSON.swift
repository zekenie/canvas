import AppKit
import Canvas

// The panel's box of JSON for a field no control suits: the stored value as indented JSON, always open, in
// the monospaced face. The form has one editor for it, over the box of the focused `Other` field, as it has
// one for a text cell. What is typed is kept as a draft until it is done: ⌘↩ or the keyboard leaving. JSON
// that parses is stored (empty clears the field) as one step of the field; JSON that does not stays in the
// box, nothing is written, and a line under it says `Not JSON`.

extension FieldFormView {
    /// Puts the editor over the focused JSON box, or takes it away.
    func syncJSON() {
        guard let stop = focus, let cell = cell(at: stop), case .json = cell.control, cell.isEditable, !isReadOnly else {
            hideJSON()
            return
        }
        hideEditor()
        let rect = grid.cellRect(line: stop.line, column: stop.column)
        jsonClip.frame = rect
        jsonEditor.frame.size.width = rect.width
        if jsonStop != stop || jsonClip.isHidden {
            jsonStop = stop
            jsonPath = cell.path
            setJSONText(jsonDrafts[cell.path] ?? cell.shown, caretAtEnd: true)
            jsonEditor.undoManager?.removeAllActions()
            jsonClip.isHidden = false
            typingPath = cell.path
            editor.fieldChecks?.typing = (shape, cell.path)
            if let window, window.firstResponder !== jsonEditor { window.makeFirstResponder(jsonEditor) }
            if !isRebuilding { refreshMarks() }
        } else if jsonDrafts[cell.path] == nil, jsonEditor.string != cell.shown {
            // Written by something else, and not being typed: the box shows it.
            setJSONText(cell.shown, caretAtEnd: false)
        }
    }

    private func setJSONText(_ text: String, caretAtEnd: Bool) {
        isLoadingEditor = true
        let caret = jsonEditor.selectedRange().location
        jsonEditor.string = text
        jsonEditor.textColor = TypesStyle.formValueInk
        jsonEditor.font = TypesStyle.formJSONFont
        let length = (text as NSString).length
        jsonEditor.setSelectedRange(NSRange(location: caretAtEnd ? length : min(caret, length), length: 0))
        isLoadingEditor = false
    }

    /// The keyboard leaves the box (it commits as it does), and the editor goes.
    func hideJSON() {
        guard !isLeavingJSON else { return }
        let wasEditing = jsonStop != nil
        isLeavingJSON = true
        if window?.firstResponder === jsonEditor { window?.makeFirstResponder(self) }
        isLeavingJSON = false
        jsonStop = nil
        jsonPath = nil
        jsonClip.isHidden = true
        if wasEditing { stopTyping() }
    }

    /// The box's text changed: kept as a draft, with no complaint while it is typed, and the box is as tall as it needs.
    func jsonTyped() {
        guard !isLoadingEditor, let path = jsonPath else { return }
        jsonDrafts[path] = jsonEditor.string
        jsonErrors.remove(path)
        relayout()
    }

    /// The box is done (⌘↩, or the keyboard left it): stored if it parses, kept as it is if it does not.
    func commitJSON() {
        guard let path = jsonPath, !isReadOnly, mode == .values, let text = jsonDrafts[path], editor.document[shape] != nil else { return }
        let value: JSONValue?
        switch FieldJSON.reading(text) {
        case .invalid:
            jsonErrors.insert(path)
            relayout()
            return
        case .empty: value = nil
        case .value(let parsed): value = parsed
        }
        guard editor.fieldWriter?.set(value, at: path, of: shape, step: step) == true else { return }
        jsonDrafts[path] = nil
        jsonErrors.remove(path)
        reload()
        relayout()
    }

    /// The sizes again, after a box grew or shrank or a line under it came or went.
    func relayout() {
        clearSizes()
        metrics = computeMetrics(width: bounds.width > 0 ? bounds.width : preferredWidth())
        needsLayout = true
        layoutSubtreeIfNeeded()
        if let stop = jsonStop, line(at: stop) != nil {
            jsonClip.frame = grid.cellRect(line: stop.line, column: stop.column)
        }
        grid.needsDisplay = true
        header.needsDisplay = true
        onResize?()
    }
}

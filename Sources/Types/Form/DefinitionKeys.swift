import AppKit
import Canvas
import Foundation
import Mentions
import TextEditing
import Titles

// The card's keys and what each writes. A text stop's editor hands the card its commands as the form's does (Tab, ⇧Tab, Return,
// Esc, ↑, ↓, Backspace on an empty line); a stop that is no text has the keyboard itself (`keyDown`). Every write is the one
// writer's, in a step of its own: a field added, renamed, given another kind or taken out, an option the same, a name and a row's
// name coalesced while they are typed, a rule through `setEndRule`. What is typed in a field's name or an option is written when
// the caret leaves it (a rename is one step, not one for each key), and an emptied one is taken out.

extension DefinitionView: NSTextViewDelegate {
    public func textDidChange(_ notification: Notification) {
        guard !isLoadingEditor, (notification.object as AnyObject?) === cellEditor, let stop = editorStop else { return }
        content.needsDisplay = true
        switch stop {
        case .title: writeTitle()
        case .endName(let carrier): writeRowName(of: carrier)
        default: break
        }
    }

    public func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard textView === cellEditor else { return false }
        // ⌘⌫ in a name or an option takes its line out; elsewhere it is the text's (to the start of the line).
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
        case .back: escape()
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
        // ⌫ and ⌦ on a kind take its field out, with ⌘ or not.
        if reading?.meaning == .delete, let modifiers = reading?.modifiers, modifiers.subtracting(.command).isEmpty, !isReadOnly {
            _ = removeFocusedLine(repeating: event.isARepeat)
            return
        }
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return super.keyDown(with: event) }
        guard let reading else {
            // A read-only card has no caret: a try shakes the type.
            if isReadOnly, event.characters?.isEmpty == false { editor.refuseChanges(to: [hub]) }
            return
        }
        switch reading.meaning {
        case .next: tab(forward: !reading.modifiers.contains(.shift))
        case .previous: tab(forward: false)
        case .activate: returnKey()
        case .toggle: spaceKey()
        case .back: escape()
        case .up: vertical(-1)
        case .down: vertical(1)
        case .left: horizontal(-1)
        case .right: horizontal(1)
        case .finish: finish()
        case .delete: if isReadOnly { editor.refuseChanges(to: [hub]) }
        }
    }

    // MARK: Moving

    /// What was typed in the stop with the caret is written, and the keyboard goes to the stop `forward` or back from it. Off
    /// the first stop or the last the card is taken down (the card's owner says where the keyboard goes on to), and so is it by
    /// ⇧Tab at the stop a key brought it in at (`entry`).
    func tab(forward: Bool) {
        isMoving = true
        defer { isMoving = false }
        if listing != nil { closeList() }
        // ⇧Tab where a key brought the keyboard in goes back out, as it came.
        if !forward, let entry, focus == entry {
            self.entry = nil
            if let stop = editorStop, stop == entry, let key = commit(stop) { return added(key) }
            onClose?(.tabbed(forward: false))
            return
        }
        // ⇧Tab at the first line past the name, in a card the walk came into, goes back to the pill's name.
        if !forward, passesTitle, let first = stops.first(where: { $0 != .title }), focus == first {
            if let stop = editorStop, stop == first, let key = commit(stop) { return added(key) }
            onClose?(.tabbed(forward: false))
            return
        }
        let before = stops
        let at = focus.flatMap { before.firstIndex(of: $0) }
        if let stop = editorStop, stop == focus, let key = commit(stop) {
            return added(key)
        }
        let after = stops
        let target: Int
        if let focus, let place = after.firstIndex(of: focus) {
            target = place + (forward ? 1 : -1)
        } else {
            // The stop was taken out (an emptied name): the next one has slid into its place.
            target = (at ?? 0) + (forward ? 0 : -1)
        }
        guard after.indices.contains(target) else {
            onClose?(.tabbed(forward: forward))
            return
        }
        focus(after[target])
    }

    /// A field was added by `add field`: its kind is next, listed with the one it has (Text) taken.
    private func added(_ key: String) {
        fresh = key
        focus(.fieldKind(key))
        openList(for: key)
    }

    func returnKey() {
        guard let stop = focus else { return }
        guard !isReadOnly else { return editor.refuseChanges(to: [hub]) }
        switch stop {
        case .fieldKind(let key):
            if listing == key { pick(DefinedKind.allCases[highlight], for: key) } else { openList(for: key) }
        case .needed, .onlyOne:
            toggle(stop)
        case .newOption:
            if cellEditor.string.isEmpty { tab(forward: true) } else { addOptionTyped(stop) }
        case .addField:
            if cellEditor.string.trimmingCharacters(in: .whitespaces).isEmpty { onClose?(.returned) } else { tab(forward: true) }
        default:
            tab(forward: true)
        }
    }

    private func spaceKey() {
        guard let stop = focus else { return }
        guard !isReadOnly else { return editor.refuseChanges(to: [hub]) }
        switch stop {
        case .fieldKind(let key):
            if listing == key { pick(DefinedKind.allCases[highlight], for: key) } else { openList(for: key) }
        case .needed, .onlyOne: toggle(stop)
        default: break
        }
    }

    /// Esc closes the list of kinds if one is open; else it writes what is typed and takes the card down.
    func escape() {
        if listing != nil {
            let key = listing
            closeList()
            if fresh == key { fresh = nil; focus(.addField) }
            return
        }
        commitPending()
        onClose?(.escaped)
    }

    /// ⌘↩: what Esc does at the top level, whatever else is open: the list is closed, what is typed is written, the card goes down.
    func finish() {
        closeList()
        commitPending()
        onClose?(.escaped)
    }

    /// ← and → on a stop that is no text go to the stop before and after it on its line, and stay at the ends.
    private func horizontal(_ delta: Int) {
        guard let stop = focus, listing == nil, let line = lines.first(where: { $0.stops(in: model).contains(stop) }) else { return }
        let same = line.stops(in: model)
        guard let place = same.firstIndex(of: stop), same.indices.contains(place + delta) else { return }
        focus(same[place + delta])
    }

    func vertical(_ delta: Int) {
        if let key = listing, focus == .fieldKind(key) {
            highlight = min(max(highlight + delta, 0), DefinedKind.allCases.count - 1)
            content.needsDisplay = true
            return
        }
        guard let stop = focus, let line = lines.firstIndex(where: { $0.stops(in: model).contains(stop) }) else { return }
        isMoving = true
        defer { isMoving = false }
        if let editing = editorStop, editing == stop, let key = commit(editing) { return added(key) }
        let current = lines.firstIndex(where: { $0.stops(in: model).contains(stop) }) ?? line
        var next = current + delta
        while lines.indices.contains(next) {
            if let first = lines[next].stops(in: model).first { return focus(first) }
            next += delta
        }
    }

    /// ⌫, ⌦ or ⌘⌫ on a line that can go: a field's name or its kind takes the field out, an option takes itself out; in one step.
    /// False for a stop that is on no such line.
    func removeFocusedLine(repeating: Bool = HeldKey.isRepeating) -> Bool {
        guard !isReadOnly, let stop = focus else { return false }
        switch stop {
        case .fieldName, .fieldKind, .option:
            // A held key is one press: it takes one line out, not the lines the keyboard moves on to, nor what they hold.
            if repeating { return true }
            cellEditor.dropsRepeats = true
        default: break
        }
        switch stop {
        case .fieldName(let field), .fieldKind(let field):
            let line = lines.firstIndex { $0.stops(in: model).contains(stop) }
            editorStop = nil
            cellClip.isHidden = true
            definer?.removeField(field, from: hub)
            reload()
            keepAfterRemoval(near: line)
        case .option(let field, let place):
            let line = lines.firstIndex { $0.stops(in: model).contains(stop) }
            editorStop = nil
            cellClip.isHidden = true
            definer?.removeOption(at: place, of: field, in: hub)
            reload()
            keepAfterRemoval(near: line)
        default:
            return false
        }
        return true
    }

    /// The keyboard goes to the line that took the removed one's place, else the one before it.
    private func keepAfterRemoval(near line: Int?) {
        isMoving = true
        defer { isMoving = false }
        var next = min(line ?? 0, lines.count - 1)
        while lines.indices.contains(next) {
            if let first = lines[next].stops(in: model).first { return focus(first) }
            next -= 1
        }
        focus(fallbackStop())
    }

    private func backspaceOnEmptyLine() -> Bool {
        guard !isReadOnly, cellEditor.string.isEmpty, let stop = editorStop else { return false }
        switch stop {
        case .fieldName, .option:
            // A held ⌫ empties one name; it does not go on to take the lines before it out.
            if HeldKey.isRepeating { return true }
            tab(forward: false)
            return true
        default:
            return false
        }
    }

    // MARK: Kinds and rules

    /// The kind chosen for a field: written as its own step, and the keyboard goes on. A choice goes to its options, the field
    /// just added to `add field`, any other stays on its kind.
    func pick(_ kind: DefinedKind, for key: String) {
        closeList()
        _ = definer?.changeKind(of: key, to: kind, in: hub)
        reload()
        let wasFresh = fresh == key
        fresh = nil
        if kind == .choice, stops.contains(.newOption(key)) {
            focus(.newOption(key))
        } else if wasFresh {
            focus(.addField)
        } else {
            focus(.fieldKind(key))
        }
    }

    func toggle(_ stop: DefinitionStop) {
        switch stop {
        case .needed(let carrier):
            guard let end = model.ends.first(where: { $0.carrier == carrier }) else { return }
            editor.setEndRule([carrier], needed: !end.rule.needed)
        case .onlyOne(let carrier):
            guard let end = model.ends.first(where: { $0.carrier == carrier }) else { return }
            editor.setEndRule([carrier], onlyOne: !end.rule.onlyOne)
        default: return
        }
        reload()
    }

    // MARK: Writing

    var definer: FieldDefiner? { editor.fieldDefiner }

    /// What is typed in the stop with the caret, written (the card closing, or the caret leaving). Answers the key of the field
    /// an `add field` made. The editor stands down first, so what the write changes does not find it still over the stop.
    @discardableResult
    func commit(_ stop: DefinitionStop) -> String? {
        guard editorStop == stop else { return nil }
        let typed = cellEditor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        editorStop = nil
        cellClip.isHidden = true
        guard !isReadOnly else { return nil }
        var key: String?
        switch stop {
        case .fieldName(let field):
            if typed.isEmpty {
                definer?.removeField(field, from: hub)
            } else if typed != model.text(of: stop) {
                definer?.renameField(field, to: typed, in: hub)
            }
        case .option(let field, let place):
            if typed.isEmpty {
                definer?.removeOption(at: place, of: field, in: hub)
            } else if typed != model.text(of: stop) {
                definer?.renameOption(at: place, to: typed, of: field, in: hub)
            }
        case .newOption(let field):
            if !typed.isEmpty { definer?.addOption(typed, to: field, in: hub) }
        case .addField:
            if !typed.isEmpty { key = definer?.addField(named: typed, kind: .text, to: hub) }
        case .title, .endName, .fieldKind, .needed, .onlyOne:
            break
        }
        reload()
        return key
    }

    /// What is typed is written, for a card going down.
    public func commitPending() {
        guard let stop = editorStop else { return }
        commit(stop)
    }

    /// An option typed on the empty line is added, and the line is empty again with the caret in it.
    private func addOptionTyped(_ stop: DefinitionStop) {
        guard commit(stop) == nil else { return }
        focus(stop)
    }

    private func writeTitle() {
        let title = TitleProperty.folded(cellEditor.string)
        guard editor.shape(inFile: hub)?[TitleProperty.self] != title else { return }
        editor.transact(TypesStyle.nameRelationshipType, coalescing: DefinitionStepKey(shape: hub, row: false)) { transaction in
            transaction.update(inFile: hub) { $0[TitleProperty.self] = title }
        }
    }

    /// The row's name: the first line of the end arrow's words, the rest of them kept (words with a mention in them are replaced).
    private func writeRowName(of carrier: ShapeID) {
        guard let record = editor.shape(inFile: carrier), let words = editor.registry.typeWords(of: record.kind) else { return }
        if editor.isReadOnly(inFile: carrier) {
            editor.refuseChanges(to: [carrier])
            if let held = model.text(of: .endName(carrier)) { setEditorText(held) }
            return
        }
        let typed = cellEditor.string.replacingOccurrences(of: "\n", with: " ")
        let old = words.words(record)
        var rest = ""
        if let old, old.runs.allSatisfy({ if case .text = $0 { true } else { false } }) {
            let plain = old.runs.map { run -> String in if case .text(let text) = run { text } else { "" } }.joined()
            if let newline = plain.firstIndex(where: \.isNewline) { rest = String(plain[newline...]) }
        }
        let text = MentionText(plain: typed + rest)
        guard old?.stored != text.stored else { return }
        editor.transact(TypesStyle.nameRow, coalescing: DefinitionStepKey(shape: carrier, row: true)) { transaction in
            words.write(&transaction, carrier, text)
        }
    }

    // MARK: The mouse

    /// A press at a point of the card's lines (the content's coordinates).
    public func click(at point: CGPoint) {
        if let key = listing, let field = model.fields.firstIndex(where: { $0.key == key }) {
            for kind in DefinedKind.allCases.indices where listRect(at: kind, of: field)?.contains(point) == true {
                if isReadOnly { return editor.refuseChanges(to: [hub]) }
                return pick(DefinedKind.allCases[kind], for: key)
            }
        }
        for stop in stops {
            guard let rect = rect(of: stop), rect.contains(point) else { continue }
            if isReadOnly { return editor.refuseChanges(to: [hub]) }
            switch stop {
            case .fieldKind(let key):
                let open = listing == key
                focus(stop)
                if open { closeList() } else { openList(for: key) }
            case .needed, .onlyOne:
                focus(stop)
                toggle(stop)
            default:
                focus(stop)
                cellEditor.placeSelection(at: CGPoint(x: point.x - rect.minX, y: cellEditor.textContainerInset.height + 2))
            }
            return
        }
        closeList()
    }
}

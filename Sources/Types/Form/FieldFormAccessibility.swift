import AppKit
import Canvas
import CanvasRPC
import Titles

// What VoiceOver reads of a form (see CardAccessibility.swift): a group named for the card, whose children are its stops in the
// order Tab walks them.

extension FieldFormView {
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .group }
    public override func accessibilityLabel() -> String? {
        TypesStyle.fieldsAccessibilityLabel(of: editor.document[shape].flatMap { editor.registry.title(of: $0) })
    }

    public override func accessibilityChildren() -> [Any]? {
        // AppKit asks on the main thread; the property is declared without the main actor.
        nonisolated(unsafe) var children: [Any]?
        MainActor.assumeIsolated {
            let stops = sheet.stops
            let present = Set(stops)
            stopElements = stopElements.filter { present.contains($0.key) }
            children = stops.compactMap { accessibleElement(of: $0) }
        }
        return children
    }

    /// The stop with the keyboard: the cell editor while a cell has the caret, else the stop's element. The same objects the
    /// children hold.
    public override var accessibilityFocusedUIElement: Any? {
        nonisolated(unsafe) var focused: Any?
        MainActor.assumeIsolated { focused = focus.flatMap { accessibleElement(of: $0) } }
        return focused
    }

    /// What stands for the stop among the children: the editor over it, while it has the caret, else its element.
    private func accessibleElement(of stop: FieldStop) -> Any? {
        if stop == editorStop { return cellEditor }
        if stop == jsonStop { return jsonEditor }
        return element(of: stop)
    }

    /// What VoiceOver calls a stop: its field's words, else its line's name, else what the form is about.
    func accessibilityLabel(of stop: FieldStop) -> String {
        if stop.line < 0 { return sheet.branches.indices.contains(stop.column) ? sheet.branches[stop.column] : TypesStyle.branchAccessibilityLabel }
        guard let held = line(at: stop) else { return TypesStyle.rowsAccessibilityLabel }
        let words = cell(at: stop).map { FieldName.words(of: $0.field.field) } ?? ""
        if !words.isEmpty { return words }
        if let name = held.name, !name.isEmpty { return name }
        return level.title.isEmpty ? TypesStyle.rowsAccessibilityLabel : level.title
    }

    /// The stop as an element: a role by its control, a label from its field, a value from its cell.
    func element(of stop: FieldStop) -> CardStopElement? {
        let made = makeElement(of: stop, reusing: stopElements[stop])
        stopElements[stop] = made
        return made
    }

    private func makeElement(of stop: FieldStop, reusing old: CardStopElement?) -> CardStopElement? {
        let rect = self.rect(of: stop)
        let label = accessibilityLabel(of: stop)
        if stop.line < 0 {
            return stopElement(reusing: old, role: .radioButton, label: label, value: stop.column == sheet.branch ? 1 : 0, rect: rect) { [weak self] in self?.activate(stop) }
        }
        guard let held = line(at: stop), let cell = cell(at: stop) else { return nil }
        let help: String? = switch cell.mark {
        case .needed?: TypesStyle.neededHelp
        case .wrong?: TypesStyle.wrongHelp
        default: nil
        }
        let press: @MainActor () -> Void = { [weak self] in self?.activate(stop) }
        if let open = held.disclosure {
            return stopElement(reusing: old, role: .disclosureTriangle, label: label, value: open ? 1 : 0, rect: rect, press: press)
        }
        switch cell.control {
        case .text, .oneOf:
            return stopElement(reusing: old, role: .textField, label: label, value: cell.shown, rect: rect, help: help, press: press)
        case .json:
            return stopElement(reusing: old, role: .textArea, label: label, value: cell.shown, rect: rect, help: help, press: press)
        case .yesNo:
            return stopElement(reusing: old, role: .checkBox, label: label, value: cell.value == .bool(true) ? 1 : 0, rect: rect, help: help, press: press)
        case .choice:
            return stopElement(reusing: old, role: .popUpButton, label: label, value: cell.shown, rect: rect, help: help, press: press)
        case .more:
            return stopElement(reusing: old, role: .button, label: label, value: cell.shown, rect: rect, help: help, press: press)
        case .check(let on):
            return stopElement(reusing: old, role: .checkBox, label: cell.shown.isEmpty ? label : cell.shown, value: on ? 1 : 0, rect: rect, press: press)
        case .clear:
            return stopElement(reusing: old, role: .button, label: FieldWords.none, rect: rect, press: press)
        case .note:
            return stopElement(reusing: old, role: .button, label: label, value: cell.shown, rect: rect, help: help, press: press)
        case .label:
            return nil
        }
    }

    /// The editor over the stop with the keyboard is named for it, and VoiceOver is told the keyboard moved.
    func announceFocus(from old: FieldStop?) {
        guard let stop = focus else { return }
        let label = accessibilityLabel(of: stop)
        cellEditor.setAccessibilityLabel(label)
        jsonEditor.setAccessibilityLabel(label)
        if stop != old { NSAccessibility.post(element: self, notification: .focusedUIElementChanged) }
    }
}

import AppKit
import Canvas
import Titles

// What VoiceOver reads of the card that defines a relationship type (see CardAccessibility.swift): a group named for the card
// whose children are its stops in the order Tab walks them.

extension TypesStyle {
    /// What VoiceOver calls the card's stops.
    static let definitionNameLabel = "Name"
    static let definitionFieldLabel = "Field"
    static let definitionNewOptionLabel = "New option"
    static func definitionKindLabel(of field: String) -> String { field.isEmpty ? "Kind" : "Kind of \(field)" }
    static func definitionOptionLabel(of field: String) -> String { field.isEmpty ? "Option" : "Option of \(field)" }
    static func definitionRowLabel(of type: String) -> String { "Row name, \(type)" }
}

extension DefinitionView {
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .group }
    public override func accessibilityLabel() -> String? {
        TypesStyle.fieldsAccessibilityLabel(of: editor.document[hub].flatMap { editor.registry.title(of: $0) })
    }

    public override func accessibilityChildren() -> [Any]? {
        // AppKit asks on the main thread; the property is declared without the main actor.
        nonisolated(unsafe) var children: [Any]?
        MainActor.assumeIsolated {
            let all = stops
            let present = Set(all)
            stopElements = stopElements.filter { present.contains($0.key) }
            children = all.map(accessibleElement(of:))
        }
        return children
    }

    /// The stop with the keyboard: the cell editor while a cell has the caret, else the stop's element. The same objects the
    /// children hold.
    public override var accessibilityFocusedUIElement: Any? {
        nonisolated(unsafe) var focused: Any?
        MainActor.assumeIsolated { focused = focus.map(accessibleElement(of:)) }
        return focused
    }

    /// What stands for the stop among the children: the editor over it, while it has the caret, else its element.
    private func accessibleElement(of stop: DefinitionStop) -> Any { stop == editorStop ? cellEditor : element(of: stop) }

    /// What VoiceOver calls a stop: the field's words, else what the line is.
    func accessibilityLabel(of stop: DefinitionStop) -> String {
        func name(_ key: String) -> String { model.fields.first { $0.key == key }?.name ?? "" }
        switch stop {
        case .title: return TypesStyle.definitionNameLabel
        case .fieldName: return TypesStyle.definitionFieldLabel
        case .fieldKind(let key): return TypesStyle.definitionKindLabel(of: name(key))
        case .option(let key, _): return TypesStyle.definitionOptionLabel(of: name(key))
        case .newOption: return TypesStyle.definitionNewOptionLabel
        case .addField: return TypesStyle.addFieldWords
        case .endName(let carrier): return TypesStyle.definitionRowLabel(of: model.ends.first { $0.carrier == carrier }.map { chipName($0.type).text } ?? "")
        case .needed: return TypesStyle.neededChoice
        case .onlyOne: return TypesStyle.onlyOneChoice
        }
    }

    /// The stop as an element: a role by its control, a label, a value from the card, a frame from where it is drawn.
    func element(of stop: DefinitionStop) -> CardStopElement {
        let made = makeElement(of: stop, reusing: stopElements[stop])
        stopElements[stop] = made
        return made
    }

    private func makeElement(of stop: DefinitionStop, reusing old: CardStopElement?) -> CardStopElement {
        let rect = rect(of: stop).map { convert($0, from: content) } ?? .zero
        let label = accessibilityLabel(of: stop)
        let press: @MainActor () -> Void = { [weak self] in self?.press(stop) }
        switch stop {
        case .fieldKind(let key):
            return stopElement(reusing: old, role: .popUpButton, label: label, value: model.fields.first { $0.key == key }?.kind?.label ?? "", rect: rect, press: press)
        case .needed(let carrier):
            return stopElement(reusing: old, role: .checkBox, label: label, value: model.ends.first { $0.carrier == carrier }?.rule.needed == true ? 1 : 0,
                               rect: rect, help: model.ends.first { $0.carrier == carrier }.map { chipName($0.type).text }, press: press)
        case .onlyOne(let carrier):
            return stopElement(reusing: old, role: .checkBox, label: label, value: model.ends.first { $0.carrier == carrier }?.rule.onlyOne == true ? 1 : 0,
                               rect: rect, help: model.ends.first { $0.carrier == carrier }.map { chipName($0.type).text }, press: press)
        default:
            return stopElement(reusing: old, role: .textField, label: label, value: model.text(of: stop) ?? "", rect: rect, press: press)
        }
    }

    /// Pressing a stop as a click does.
    func press(_ stop: DefinitionStop) {
        guard !isReadOnly else { return editor.refuseChanges(to: [hub]) }
        switch stop {
        case .fieldKind(let key):
            focus(stop)
            if listing == key { closeList() } else { openList(for: key) }
        case .needed, .onlyOne:
            focus(stop)
            toggle(stop)
        default:
            focus(stop)
        }
    }

    /// The editor over the stop with the keyboard is named for it, and VoiceOver is told the keyboard moved.
    func announceFocus(from old: DefinitionStop?) {
        guard let stop = focus else { return }
        cellEditor.setAccessibilityLabel(accessibilityLabel(of: stop))
        if stop != old { NSAccessibility.post(element: self, notification: .focusedUIElementChanged) }
    }
}

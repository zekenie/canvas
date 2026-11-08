import Canvas

// What VoiceOver walks on the canvas, as Selection says it: the order is Tab's (the stops where the
// selection is, in reading order: `StopOrder.reading`), and a shape's parts are ⌥Tab's (`ShapeParts`),
// each pressed as Return presses it, the one with the keyboard VoiceOver's focus. The core's two claims
// (`registrar.accessibleOrder`, `registrar.accessibleParts`); CanvasUI makes the elements.

extension SelectionPlugin {
    /// Claims the order VoiceOver walks the board in and the parts of each shape (see above).
    func registerAccessibility(into registrar: inout PluginRegistrar) {
        registrar.accessibleOrder { $0.selectionState?.readingOrder ?? [] }
        registrar.accessibleParts({ editor, id in
            // Its items first (a table's rows), said selected as they are, then its ⌥Tab parts.
            let selected = editor.selectedItems.flatMap { $0.shape == id ? Set($0.ids) : nil } ?? []
            let actions = editor.document[id].flatMap { editor.itemSource(of: $0.kind)?.actions }
            let leads = editor.document[id].flatMap { record in actions?.leadTitles?(editor, record) } ?? [:]
            let items = editor.shapeItems(of: id).flatMap { item in
                let itemID = item.id
                let row = AccessiblePart(id: ItemKey(id: itemID), title: item.title, role: .row, rect: item.rect,
                                         isSelected: selected.contains(itemID)) { editor in
                    editor.selectItems([itemID], of: id)
                }
                // Its lead, where it does more than select it (an endpoint's method chip): a button after it, pressed as Space on it is.
                guard let title = leads[itemID], let press = actions?.pressLead else { return [row] }
                return [row, AccessiblePart(id: ItemLeadKey(id: itemID), title: title, role: .menuButton, rect: item.rect) { editor in
                    editor.selectItems([itemID], of: id)
                    _ = press(editor, id, itemID)
                }]
            }
            return items + editor.shapeParts(of: id).map { part in
                let partID = part.id
                return AccessiblePart(id: partID, title: part.title, role: part.role.accessible, rect: part.rect) { editor in
                    editor.pressPartForAccessibility(partID, of: id)
                }
            }
        }, focused: { editor in
            // The first item selected has the keyboard, else the focused part.
            if let selection = editor.selectedItems, editor.canStepItems { return AccessiblePartFocus(shape: selection.shape, part: ItemKey(id: selection.ids[0])) }
            guard editor.hasFocusedPart, let focus = editor.selectionState?.partFocus else { return nil }
            return AccessiblePartFocus(shape: focus.shape, part: focus.part)
        })
    }
}

/// An item's key among its shape's accessible parts, apart from every part's.
struct ItemKey: Hashable {
    let id: AnyHashable
}

/// An item's lead's key among its shape's accessible parts (a button after the item).
struct ItemLeadKey: Hashable {
    let id: AnyHashable
}

extension PartRole {
    /// The core's role for it, which the host turns into an accessibility role.
    var accessible: AccessiblePart.Role {
        switch self {
        case .button: .button
        case .menuButton: .menuButton
        case .link: .link
        case .checkbox: .checkbox
        case .handle: .handle
        case .connection: .connection
        }
    }
}

extension CanvasEditor {
    /// VoiceOver's press on a part of a shape: the shape alone selected, the part focused, as ⌥Tab
    /// would leave it, and pressed, as Return presses it. Nothing while a gesture runs, or for a part
    /// the shape no longer lists.
    func pressPartForAccessibility(_ partID: AnyHashable, of shape: ShapeID) {
        guard session == nil, shapeParts(of: shape).contains(where: { $0.id == partID }) else { return }
        if selectedShapeIDs != [shape] { selectedShapeIDs = [shape] }
        // Listed again: selecting may have changed what the shape draws.
        guard let part = shapeParts(of: shape).first(where: { $0.id == partID }) else { return }
        if selection == shape, let state = selectionState { state.focusPart(part, of: shape) }
        part.press(self)
    }
}

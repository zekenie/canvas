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
            editor.shapeParts(of: id).map { part in
                let partID = part.id
                return AccessiblePart(id: partID, title: part.title, role: part.role.accessible, rect: part.rect) { editor in
                    editor.pressPartForAccessibility(partID, of: id)
                }
            }
        }, focused: { editor in
            guard editor.hasFocusedPart, let focus = editor.selectionState?.partFocus else { return nil }
            return AccessiblePartFocus(shape: focus.shape, part: focus.part)
        })
    }
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

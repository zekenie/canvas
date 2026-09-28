import AppKit
import Canvas
import DetailPanel
import SwiftUI

/// Mention text in the panel: a box of the panel's (`DetailTextBox`) over a `MentionTextView`, so a
/// field of mention text edits there as it does on its shape, with pills, the `@` picker, copy and
/// paste, and each pill's click and double-click. Its pills are tinted, as on any neutral surface.
///
///     DetailSection("Text", in: FieldsTab.self) { $jot in
///         MentionTextArea($jot, \.text)
///     }
///
/// It writes the field on every change, as the panel's text does (a run of writes is one undo step,
/// "Change Text"), a pick, Remove Mention and a paste included; it shows what the shape says only
/// when that changed from elsewhere (an undo of the board, a write of another plugin's). A rename
/// of what it mentions redraws its pills and writes nothing. With `onCommit`, Return, ⌘↩ and the
/// keyboard leaving say the text is done, and ⇧↩ is a new line; without, Return is a new line.
/// While the picker is open, its keys are the picker's: Return and Tab pick, and Escape or ⌘.
/// closes it (another leaves the panel). The shape's text never offers itself in its picker.
/// Read-only (a locked shape, `detailUpdating`), it's dimmed, opens no picker and offers no Remove
/// Mention, and its clicks still land: a click selects a pill, and a double-click on one goes to
/// what it names.
public struct MentionTextArea<Props: ShapeProps, Scope: MentionScope>: View {
    let shape: ShapeBinding<Props>
    let field: WritableKeyPath<Props, ScopedMentionText<Scope>>
    let height: CGFloat
    let placeholder: String?
    let onCommit: (@MainActor () -> Void)?

    public init(_ shape: ShapeBinding<Props>, _ field: WritableKeyPath<Props, ScopedMentionText<Scope>>,
                height: CGFloat = DetailStyle.textAreaHeight, placeholder: String? = nil, onCommit: (@MainActor () -> Void)? = nil) {
        self.shape = shape
        self.field = field
        self.height = height
        self.placeholder = placeholder
        self.onCommit = onCommit
    }

    public var body: some View {
        let text = shape.wrappedValue[keyPath: field]
        let owner = shape.shapeID
        let mentions = shape.service(MentionState.self)
        DetailTextBox(shape[dynamicMember: field], height: height, placeholder: placeholder, onCommit: onCommit) {
            let view = MentionTextView<Scope>(frame: .zero, text: text, style: MentionStyle.panelText, owner: owner, mentions: mentions)
            view.usesRuler = false
            view.usesFontPanel = false
            return view
        }
    }
}

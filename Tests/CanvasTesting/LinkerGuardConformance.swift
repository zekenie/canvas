import AppKit
@_spi(Host) import Canvas

extension SealedDefinition: Editable {
    func makeEditingView(for shape: ShapeRecord<Sealed>, context: EditContext<Sealed>) -> EditingView {
        let view = NSView()
        return EditingView(view: view, firstResponder: view)
    }
}

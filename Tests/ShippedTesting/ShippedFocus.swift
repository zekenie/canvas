import AppKit
import Canvas
import CanvasTesting
import Selection
import Titles

// Where the keyboard is in a board's window as the app ships it, for a key walk (`KeyWalk`): the
// canvas's selection, named as the test names its shapes or by their titles, and the panel beside
// the canvas.

extension FocusReader where Self == CanvasFocusReader {
    /// The canvas of a shipped editor: the selection, each shape named by `names`, else by its title,
    /// else by the start of its id; where it is, the selection's bounds in the part of the view the
    /// host leaves clear (`unobscuredViewport`). `part`: the selected shape's focused part, when one is.
    public static func canvas(_ view: NSView, editor: CanvasEditor, names: [ShapeID: String] = [:],
                              part: @escaping @MainActor () -> String? = { nil }) -> CanvasFocusReader {
        .canvas(view, selection: { [weak editor] in
            guard let editor else { return [] }
            return editor.selectedShapeIDs.map { id in
                names[id] ?? editor.document[id].flatMap { editor.registry.title(of: $0) } ?? String(id.description.prefix(8))
            }
        }, part: part, frame: { [weak editor, weak view] in
            guard let editor, let view, let bounds = editor.shapeContext.bounds(of: editor.selectedShapeIDs) else { return nil }
            return editor.shownFrame(ofWorld: bounds, in: view)
        })
    }
}

extension FocusReader where Self == CustomFocusReader {
    /// The panel beside `canvas` (the inspector): what has the keyboard there, as AppKit and
    /// accessibility see it, surface "panel". Nil while the canvas, or a view it hosts or that sits
    /// over it (the path), has the keyboard.
    public static func panel(of canvas: NSView) -> CustomFocusReader {
        .custom("panel") { [weak canvas] window in
            guard let canvas, let view = window.firstResponder as? NSView else { return nil }
            let owner = (view as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSView : nil } ?? view
            guard owner !== canvas, !owner.isDescendant(of: canvas) else { return nil }
            let frame = owner.convert(owner.bounds, to: nil), canvasFrame = canvas.convert(canvas.bounds, to: nil)
            guard !canvasFrame.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
            return AppKitFocusReader(surface: "panel").read(window)
        }
    }
}

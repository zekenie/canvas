import Canvas
import SwiftUI

/// A window's canvas view, for chrome beside it: a panel hands the keyboard back with `take()`, and
/// menu commands reach the canvas through `canvas`, whatever has the keyboard.
@MainActor
public final class CanvasFocus {
    public internal(set) weak var canvas: CanvasView?
    public init() {}

    /// Makes the canvas its window's first responder.
    public func take() {
        if let canvas { canvas.window?.makeFirstResponder(canvas) }
    }
}

public struct CanvasRepresentable: NSViewRepresentable {
    let editor: CanvasEditor
    let focus: CanvasFocus?

    public init(editor: CanvasEditor, focus: CanvasFocus? = nil) {
        self.editor = editor
        self.focus = focus
    }

    public func makeNSView(context: Context) -> CanvasView {
        let canvas = CanvasView(editor: editor)
        focus?.canvas = canvas
        return canvas
    }

    public func updateNSView(_ canvas: CanvasView, context: Context) {}
}

extension ToolDescriptor {
    /// The toolbar tooltip: "Note (N)".
    public var help: String { shortcut.map { "\(label) (\($0.uppercased()))" } ?? label }
}

/// The toolbar, built from the registry. The editor is observable, so this follows tool switches
/// made on the canvas (shortcuts, finishing an arrow) with no callback.
public struct ToolPicker: View {
    let editor: CanvasEditor
    public init(editor: CanvasEditor) { self.editor = editor }
    public var body: some View {
        Picker("Tool", selection: Binding(get: { editor.currentToolID }, set: { editor.setTool($0) })) {
            ForEach(editor.registry.tools) { tool in
                Image(systemName: tool.systemImage).help(tool.help).tag(tool.id)
            }
        }
        .pickerStyle(.segmented)
    }
}

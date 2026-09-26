import Canvas
import SwiftUI

public struct CanvasRepresentable: NSViewRepresentable {
    let editor: CanvasEditor
    public init(editor: CanvasEditor) { self.editor = editor }
    public func makeNSView(context: Context) -> CanvasView { CanvasView(editor: editor) }
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

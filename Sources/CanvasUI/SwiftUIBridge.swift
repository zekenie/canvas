import AppKit
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
    let showsMinimap: Bool

    public init(editor: CanvasEditor, focus: CanvasFocus? = nil, showsMinimap: Bool = false) {
        self.editor = editor
        self.focus = focus
        self.showsMinimap = showsMinimap
    }

    public func makeNSView(context: Context) -> CanvasView {
        let canvas = CanvasView(editor: editor)
        focus?.canvas = canvas
        canvas.showsMinimap = showsMinimap
        return canvas
    }

    public func updateNSView(_ canvas: CanvasView, context: Context) {
        canvas.showsMinimap = showsMinimap
    }
}

/// The toolbar, built from the registry. The editor is observable, so this follows tool switches
/// made on the canvas (shortcuts, finishing an arrow) with no callback, and dims the tools the board
/// shown can't take (`editor.isToolEnabled`: those that place shapes, on a read-only board). Each
/// tool's tooltip is what a plugin says of it (the host's slot for tool tips, `registry.toolTip(for:)`:
/// the plugin that keeps the keys names the tool's, "Note (N)"), its label alone otherwise.
///
/// An AppKit segmented control, since SwiftUI's segmented `Picker` dims none of its segments:
/// `.disabled` on a segment's content changes nothing there.
public struct ToolPicker: View {
    let editor: CanvasEditor

    public init(editor: CanvasEditor) {
        self.editor = editor
    }

    public var body: some View {
        let registry = editor.registry, tools = registry.tools
        ToolSegments(editor: editor, tools: tools, tooltips: tools.map { registry.toolTip(for: $0) }, current: editor.currentToolID,
                     enabled: tools.map { editor.isToolEnabled($0.id) })
            .fixedSize()
    }
}

/// `ToolPicker`'s control: a segment a tool, its symbol and tooltip, dimmed where `enabled` says, the
/// current tool's selected; a click on one picks that tool (`editor.setTool`, which may refuse it, and
/// then the selection goes back to the tool that's current).
struct ToolSegments: NSViewRepresentable {
    let editor: CanvasEditor
    let tools: [ToolDescriptor]
    let tooltips: [String]
    let current: ToolID
    let enabled: [Bool]

    func makeCoordinator() -> Coordinator { Coordinator(editor: editor) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.target = context.coordinator
        control.action = #selector(Coordinator.pick(_:))
        control.setAccessibilityLabel("Tool")
        control.segmentCount = tools.count
        for (index, tool) in tools.enumerated() {
            control.setImage(NSImage(systemSymbolName: tool.systemImage, accessibilityDescription: tool.label), forSegment: index)
            control.setImageScaling(.scaleNone, forSegment: index)
        }
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.tools = tools.map(\.id)
        control.isEnabled = context.environment.isEnabled
        for index in tools.indices {
            if control.toolTip(forSegment: index) != tooltips[index] { control.setToolTip(tooltips[index], forSegment: index) }
            if control.isEnabled(forSegment: index) != enabled[index] { control.setEnabled(enabled[index], forSegment: index) }
        }
        control.selectedSegment = tools.firstIndex { $0.id == current } ?? -1
    }

    @MainActor
    final class Coordinator: NSObject {
        let editor: CanvasEditor
        var tools: [ToolID] = []

        init(editor: CanvasEditor) { self.editor = editor }

        @objc func pick(_ control: NSSegmentedControl) {
            if tools.indices.contains(control.selectedSegment) { editor.setTool(tools[control.selectedSegment]) }
            control.selectedSegment = tools.firstIndex(of: editor.currentToolID) ?? -1
        }
    }
}

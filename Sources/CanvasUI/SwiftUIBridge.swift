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
/// shown can't take (`editor.isToolEnabled`: those that place shapes, on a read-only board). `help` is
/// each tool's tooltip: the host passes one that names the tool's key ("Note (N)"), which only the
/// plugin that keeps the keys knows; the label alone otherwise.
///
/// An AppKit segmented control, since SwiftUI's segmented `Picker` dims none of its segments:
/// `.disabled` on a segment's content changes nothing there.
public struct ToolPicker: View {
    let editor: CanvasEditor
    let help: @MainActor (ToolDescriptor) -> String

    public init(editor: CanvasEditor, help: @escaping @MainActor (ToolDescriptor) -> String = { $0.label }) {
        self.editor = editor
        self.help = help
    }

    public var body: some View {
        let tools = editor.registry.tools
        ToolSegments(editor: editor, tools: tools, tooltips: tools.map(help), current: editor.currentToolID,
                     enabled: tools.map { editor.isToolEnabled($0.id) })
            .fixedSize()
    }
}

/// `ToolPicker`'s control: a segment a tool, its symbol and tooltip, dimmed where `enabled` says, the
/// current tool's selected; a click on one picks that tool (`editor.setTool`, which may refuse it, and
/// then the selection goes back to the tool that's current). A tool with a menu
/// (`registrar.toolMenu`) shows the menu's indicator on its segment, and its menu is made as it opens,
/// from `editor.toolMenu(for:)`: the file as it is then, a line a `ToolMenuItem`, chosen with
/// `editor.choose`. A plain click still picks the tool.
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
            if editor.registry.hasToolMenu(for: tool.id) {
                let menu = NSMenu(title: tool.label)
                menu.delegate = context.coordinator
                context.coordinator.menus[ObjectIdentifier(menu)] = tool.id
                control.setMenu(menu, forSegment: index)
                control.setShowsMenuIndicator(true, forSegment: index)
            }
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
    final class Coordinator: NSObject, NSMenuDelegate {
        let editor: CanvasEditor
        var tools: [ToolID] = []
        /// The tool each segment's menu belongs to.
        var menus: [ObjectIdentifier: ToolID] = [:]

        init(editor: CanvasEditor) { self.editor = editor }

        /// The menu's lines, made as it opens from the file as it is.
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tool = menus[ObjectIdentifier(menu)], let entries = editor.toolMenu(for: tool) else { return }
            for entry in entries {
                switch entry {
                case .separator:
                    menu.addItem(.separator())
                case .item(let item):
                    let line = NSMenuItem(title: item.title, action: #selector(choose(_:)), keyEquivalent: "")
                    line.target = self
                    line.isEnabled = item.isEnabled
                    line.state = item.isChecked ? .on : .off
                    if let symbol = item.systemImage { line.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                    line.representedObject = ChosenItem(item)
                    menu.addItem(line)
                }
            }
        }

        @objc func choose(_ line: NSMenuItem) {
            if let chosen = line.representedObject as? ChosenItem { editor.choose(chosen.item) }
        }

        @objc func pick(_ control: NSSegmentedControl) {
            if tools.indices.contains(control.selectedSegment) { editor.setTool(tools[control.selectedSegment]) }
            control.selectedSegment = tools.firstIndex(of: editor.currentToolID) ?? -1
        }
    }
}

/// A menu line's item, for the line to carry.
@MainActor
private final class ChosenItem {
    let item: ToolMenuItem
    init(_ item: ToolMenuItem) { self.item = item }
}

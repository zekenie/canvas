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
/// the plugin that keeps the keys names the tool's, "Note (N)"), its label alone otherwise. While the
/// tool is locked (`editor.isToolLocked`) the selected segment's symbol carries a small lock, and its
/// tooltip adds ", locked".
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
                     enabled: tools.map { editor.isToolEnabled($0.id) }, isLocked: editor.isToolLocked)
            .fixedSize()
    }
}

/// `ToolPicker`'s control: a segment a tool, its symbol and tooltip, dimmed where `enabled` says, the
/// current tool's selected, with a lock on its symbol while `isLocked`; a click on one picks that tool
/// (`editor.setTool`, which may refuse it, and then the selection goes back to the tool that's current).
struct ToolSegments: NSViewRepresentable {
    let editor: CanvasEditor
    let tools: [ToolDescriptor]
    let tooltips: [String]
    let current: ToolID
    let enabled: [Bool]
    let isLocked: Bool

    func makeCoordinator() -> Coordinator { Coordinator(editor: editor) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.target = context.coordinator
        control.action = #selector(Coordinator.pick(_:))
        control.setAccessibilityLabel("Tool")
        control.segmentCount = tools.count
        for index in tools.indices { control.setImageScaling(.scaleNone, forSegment: index) }
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.tools = tools.map(\.id)
        control.isEnabled = context.environment.isEnabled
        let selected = tools.firstIndex { $0.id == current }
        let locked = isLocked ? selected : nil
        for index in tools.indices {
            let tip = index == locked ? ToolLockStyle.tip(tooltips[index]) : tooltips[index]
            if control.toolTip(forSegment: index) != tip { control.setToolTip(tip, forSegment: index) }
            if control.isEnabled(forSegment: index) != enabled[index] { control.setEnabled(enabled[index], forSegment: index) }
        }
        context.coordinator.show(symbolsOf: tools, lockedAt: locked, in: control)
        control.selectedSegment = selected ?? -1
    }

    @MainActor
    final class Coordinator: NSObject {
        let editor: CanvasEditor
        var tools: [ToolID] = []

        init(editor: CanvasEditor) { self.editor = editor }

        /// What each segment's image was last made as, so one is made again only when it changes:
        /// plain, or with the lock.
        private var shown: [Int: ToolLockStyle.Look] = [:]

        /// Each segment's symbol, plain, the one at `lockedIndex` with a lock on it.
        func show(symbolsOf tools: [ToolDescriptor], lockedAt lockedIndex: Int?, in control: NSSegmentedControl) {
            var widest: CGFloat?
            for (index, tool) in tools.enumerated() {
                let look = ToolLockStyle.Look(symbol: tool.systemImage, isLocked: index == lockedIndex)
                guard shown[index] != look else { continue }
                shown[index] = look
                // The segments are equally wide, as wide as the widest symbol needs: a lock is given that
                // room, so it sits beside a narrow symbol (Select's arrow) rather than over it.
                if look.isLocked, widest == nil { widest = ToolLockStyle.widestSymbol(of: tools.map(\.systemImage)) }
                control.setImage(ToolLockStyle.image(for: look, label: tool.label, width: widest), forSegment: index)
            }
        }

        @objc func pick(_ control: NSSegmentedControl) {
            if tools.indices.contains(control.selectedSegment) { editor.setTool(tools[control.selectedSegment]) }
            control.selectedSegment = tools.firstIndex(of: editor.currentToolID) ?? -1
        }
    }
}

/// The tool lock on the toolbar's selected tool.
@MainActor
enum ToolLockStyle {
    /// A segment's image: a tool's symbol, with the lock or without.
    struct Look: Equatable {
        let symbol: String
        let isLocked: Bool
    }

    /// The lock's size, against the symbol's, and the room it clears around itself in the symbol.
    static let badgeScale: CGFloat = 0.5
    static let haloScale: CGFloat = 1.3
    static let badgeSymbol = "lock.fill"

    /// A locked tool's tooltip: the tool's, and that it's locked.
    static func tip(_ tooltip: String) -> String { tooltip + ", locked" }

    /// The widest of these symbols, in points: the room every segment has.
    static func widestSymbol(of symbols: [String]) -> CGFloat? {
        symbols.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.size.width }.max()
    }

    /// The symbol, a template image the control tints as it does any segment's. Locked, a small lock
    /// sits at its bottom right, on a gap cut out of the symbol around it; a symbol narrower than
    /// `width` (the widest a segment holds) is centered in that width first, so the lock sits beside
    /// it and cuts little or nothing of it, and the segment is as wide as it was.
    static func image(for look: Look, label: String, width: CGFloat? = nil) -> NSImage? {
        let description = look.isLocked ? label + ", locked" : label
        guard let symbol = NSImage(systemSymbolName: look.symbol, accessibilityDescription: description) else { return nil }
        guard look.isLocked, let lock = NSImage(systemSymbolName: badgeSymbol, accessibilityDescription: nil) else { return symbol }
        let size = CGSize(width: max(symbol.size.width, width ?? 0), height: symbol.size.height)
        let image = NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: CGRect(x: (rect.width - symbol.size.width) / 2, y: 0, width: symbol.size.width, height: symbol.size.height))
            let badge = CGSize(width: lock.size.width * size.height * badgeScale / lock.size.height, height: size.height * badgeScale)
            let box = CGRect(x: rect.maxX - badge.width, y: rect.minY, width: badge.width, height: badge.height)
            let halo = box.insetBy(dx: -box.width * (haloScale - 1) / 2, dy: -box.height * (haloScale - 1) / 2)
            lock.draw(in: halo, from: .zero, operation: .destinationOut, fraction: 1)
            lock.draw(in: box)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}

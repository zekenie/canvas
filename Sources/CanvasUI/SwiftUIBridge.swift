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
/// A tool is a segment, but a kit's tools (`registrar.join`) are one segment for the kit while it's on in
/// the file (`editor.kits`) and none while it's off: the segment shows the last of the kit's tools used (its
/// first, until one is), a click takes that tool, and its menu (its arrow, or a long press) lists every tool
/// of the kit, as Insert's submenu for the kit does.
///
/// An AppKit segmented control, since SwiftUI's segmented `Picker` dims none of its segments:
/// `.disabled` on a segment's content changes nothing there.
public struct ToolPicker: View {
    let editor: CanvasEditor

    public init(editor: CanvasEditor) {
        self.editor = editor
    }

    public var body: some View {
        let registry = editor.registry, groups = ToolGroup.groups(in: registry, kitsOn: editor.kits)
        let tools = groups.flatMap(\.tools)
        ToolSegments(editor: editor, groups: groups, tooltips: Dictionary(tools.map { ($0.id, registry.toolTip(for: $0)) }, uniquingKeysWith: { first, _ in first }),
                     current: editor.currentToolID,
                     enabled: Dictionary(tools.map { ($0.id, editor.isToolEnabled($0.id)) }, uniquingKeysWith: { first, _ in first }),
                     isLocked: editor.isToolLocked)
            .fixedSize()
    }
}

/// A segment of the toolbar: one tool, or the tools of a kit that's on (`kit`), which one segment shows.
struct ToolGroup {
    let kit: KitDescriptor?
    let tools: [ToolDescriptor]

    /// The toolbar's segments: each tool in no kit, in the registry's order (`registry.tools`), then a segment
    /// for each kit on in the file, in the order kits are joined, holding its tools in that order.
    @MainActor static func groups(in registry: Registry, kitsOn: Set<KitID>) -> [ToolGroup] {
        let tools = registry.tools
        var groups = tools.filter { registry.kit(ofTool: $0.id) == nil }.map { ToolGroup(kit: nil, tools: [$0]) }
        for kit in registry.kits where kitsOn.contains(kit.id) {
            let held = tools.filter { registry.kit(ofTool: $0.id) == kit.id }
            if !held.isEmpty { groups.append(ToolGroup(kit: kit, tools: held)) }
        }
        return groups
    }

    /// What tells two segments apart: the kit, and the tools.
    var key: [String] { [kit?.id.rawValue ?? ""] + tools.map(\.id.rawValue) }
}

/// `ToolPicker`'s control: a segment a group, the symbol and tooltip of the tool it shows, dimmed where
/// `enabled` says, the current tool's selected, with a lock on its symbol while `isLocked`; a click on one
/// picks the tool it shows (`editor.setTool`, which may refuse it, and then the selection goes back to the
/// tool that's current), and a kit's segment's menu picks any of its tools.
struct ToolSegments: NSViewRepresentable {
    let editor: CanvasEditor
    let groups: [ToolGroup]
    let tooltips: [ToolID: String]
    let current: ToolID
    let enabled: [ToolID: Bool]
    let isLocked: Bool

    func makeCoordinator() -> Coordinator { Coordinator(editor: editor) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.target = context.coordinator
        control.action = #selector(Coordinator.pick(_:))
        control.setAccessibilityLabel("Tool")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        let coordinator = context.coordinator
        coordinator.lay(groups, in: control)
        control.isEnabled = context.environment.isEnabled
        let showing = groups.map { coordinator.tool(showing: $0, current: current) }
        coordinator.showing = showing.map(\.id)
        let selected = groups.firstIndex { $0.tools.contains { $0.id == current } }
        let locked = isLocked ? selected : nil
        for (index, tool) in showing.enumerated() {
            let tooltip = tooltips[tool.id] ?? tool.label
            let tip = index == locked ? ToolLockStyle.tip(tooltip) : tooltip
            if control.toolTip(forSegment: index) != tip { control.setToolTip(tip, forSegment: index) }
            let isEnabled = enabled[tool.id] ?? true
            if control.isEnabled(forSegment: index) != isEnabled { control.setEnabled(isEnabled, forSegment: index) }
            for item in control.menu(forSegment: index)?.items ?? [] {
                item.state = (item.representedObject as? String) == current.rawValue ? .on : .off
            }
        }
        coordinator.show(symbolsOf: showing, kits: groups.map(\.kit), lockedAt: locked, in: control)
        control.selectedSegment = selected ?? -1
    }

    @MainActor
    final class Coordinator: NSObject {
        let editor: CanvasEditor
        /// The segments as laid out, by what tells them apart.
        private var laid: [[String]] = []
        /// The tool each segment shows, as last shown: what a click on it picks.
        var showing: [ToolID] = []
        /// The tool of each kit last used, which its segment shows while none of the kit's is current.
        private var lastUsed: [KitID: ToolID] = [:]

        init(editor: CanvasEditor) { self.editor = editor }

        /// What each segment's image was last made as, so one is made again only when it changes:
        /// plain, or with the lock.
        private var shown: [Int: ToolLockStyle.Look] = [:]

        /// Gives the control a segment a group, if they aren't as they were: a kit's with its menu, a tool's with
        /// none.
        func lay(_ groups: [ToolGroup], in control: NSSegmentedControl) {
            let keys = groups.map(\.key)
            guard keys != laid else { return }
            laid = keys
            shown = [:]
            control.segmentCount = groups.count
            for (index, group) in groups.enumerated() {
                control.setImageScaling(.scaleNone, forSegment: index)
                guard let kit = group.kit else {
                    control.setMenu(nil, forSegment: index)
                    control.setShowsMenuIndicator(false, forSegment: index)
                    continue
                }
                let menu = NSMenu(title: kit.title)
                for tool in group.tools {
                    let item = NSMenuItem(title: tool.label, action: #selector(pickFromMenu(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = tool.id.rawValue
                    item.image = NSImage(systemSymbolName: tool.systemImage, accessibilityDescription: nil)
                    menu.addItem(item)
                }
                control.setMenu(menu, forSegment: index)
                control.setShowsMenuIndicator(true, forSegment: index)
            }
        }

        /// The tool a segment shows: a tool's own; of a kit's, the current tool if it's one of them (which it
        /// remembers), else the one used last, else the first.
        func tool(showing group: ToolGroup, current: ToolID) -> ToolDescriptor {
            guard let kit = group.kit else { return group.tools[0] }
            if let tool = group.tools.first(where: { $0.id == current }) {
                lastUsed[kit.id] = tool.id
                return tool
            }
            return group.tools.first { $0.id == lastUsed[kit.id] } ?? group.tools[0]
        }

        /// Each segment's symbol, plain, the one at `lockedIndex` with a lock on it; a kit's named for the kit
        /// and its tool.
        func show(symbolsOf tools: [ToolDescriptor], kits: [KitDescriptor?], lockedAt lockedIndex: Int?, in control: NSSegmentedControl) {
            var widest: CGFloat?
            for (index, tool) in tools.enumerated() {
                let label = kits[index].map { "\($0.title), \(tool.label)" } ?? tool.label
                let look = ToolLockStyle.Look(symbol: tool.systemImage, label: label, isLocked: index == lockedIndex)
                guard shown[index] != look else { continue }
                shown[index] = look
                // The segments are equally wide, as wide as the widest symbol needs: a lock is given that
                // room, so it sits beside a narrow symbol (Select's arrow) rather than over it.
                if look.isLocked, widest == nil { widest = ToolLockStyle.widestSymbol(of: tools.map(\.systemImage)) }
                control.setImage(ToolLockStyle.image(for: look, label: label, width: widest), forSegment: index)
            }
        }

        @objc func pick(_ control: NSSegmentedControl) {
            if showing.indices.contains(control.selectedSegment) { editor.setTool(showing[control.selectedSegment]) }
            control.selectedSegment = laid.firstIndex { $0.dropFirst().contains(editor.currentToolID.rawValue) } ?? -1
        }

        /// A tool picked from a kit's segment's menu.
        @objc func pickFromMenu(_ item: NSMenuItem) {
            guard let id = item.representedObject as? String else { return }
            editor.setTool(ToolID(id))
        }
    }
}

/// The tool lock on the toolbar's selected tool.
@MainActor
enum ToolLockStyle {
    /// A segment's image: a tool's symbol, with the lock or without, and what VoiceOver calls it.
    struct Look: Equatable {
        let symbol: String
        var label = ""
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

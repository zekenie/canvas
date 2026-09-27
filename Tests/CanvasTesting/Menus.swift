import AppKit
@_spi(Host) import Canvas
import TestKit

// Context menus without putting one on screen: what a secondary click opens is an NSMenu the tests
// read line by line and choose from, which runs the item's action as a click would.

extension EditorHarness {
    /// A right-click (or Control-click) at a point, or where the pointer is: the menu it opens, or
    /// nil when it does nothing.
    public func secondaryClick(at point: CGPoint? = nil, after ms: Int = 16) -> NSMenu? {
        wait(ms)
        if let point { move(to: point, after: 0) }
        return editor.menu(for: PointerEvent(location: location, timestamp: time, modifiers: held))
    }
}

extension NSMenu {
    /// A line per item, as a test reads it: "Check All", "(Check All)" when dimmed, "✓ Done" when
    /// checked and "– Done" when mixed, "Status ▸" then its items indented, "—" for a separator.
    public var outline: [String] {
        items.flatMap { item -> [String] in
            if item.isSeparatorItem { return ["—"] }
            var line = switch item.state {
            case .on: "✓ \(item.title)"
            case .mixed: "– \(item.title)"
            default: item.title
            }
            if !item.isEnabled { line = "(\(line))" }
            guard let submenu = item.submenu else { return [line] }
            return ["\(line) ▸"] + submenu.outline.map { "  \($0)" }
        }
    }

    /// Chooses the item at a path of titles ("Status", "Done"), as a click would. Fails the test
    /// if it isn't there, or is dimmed.
    @MainActor
    public func choose(_ path: String..., file: StaticString = #fileID, line: UInt = #line) throws {
        _ = NSApplication.shared                 // items send their actions through NSApp, which a headless test lacks
        var menu = self
        for (depth, title) in path.enumerated() {
            let index = menu.indexOfItem(withTitle: title)
            let item = try require(index >= 0 ? menu.item(at: index) : nil, "no item \(title) in \(menu.outline)", file: file, line: line)
            guard depth < path.count - 1 else {
                expect(item.isEnabled, "\(title) is dimmed", file: file, line: line)
                if item.isEnabled { menu.performActionForItem(at: index) }
                return
            }
            menu = try require(item.submenu, "\(title) has no submenu", file: file, line: line)
        }
    }
}

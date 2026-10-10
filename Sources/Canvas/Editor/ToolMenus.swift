import Foundation

/// One line of a tool's menu on the toolbar (`registrar.toolMenu(for:_:)`): a value, so a menu is
/// made from the file as it is when it opens and read without AppKit; the host builds the `NSMenu`.
@MainActor
public struct ToolMenuItem {
    public let title: String
    /// An SF Symbol shown beside the title.
    public let systemImage: String?
    /// Whether the item shows a check: what the tool has chosen.
    public let isChecked: Bool
    /// Whether it can be chosen: a dimmed item does nothing (`editor.choose`).
    public let isEnabled: Bool
    let perform: @MainActor (CanvasEditor) -> Void

    public init(_ title: String, systemImage: String? = nil, isChecked: Bool = false, isEnabled: Bool = true,
                perform: @escaping @MainActor (CanvasEditor) -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isChecked = isChecked
        self.isEnabled = isEnabled
        self.perform = perform
    }
}

/// What a tool's menu lists, top to bottom.
@MainActor
public enum ToolMenuEntry {
    case item(ToolMenuItem)
    case separator
}

extension CanvasEditor {
    /// What the menu on a tool's segment lists right now (`registrar.toolMenu`), made as it is asked,
    /// so it lists what the file holds at this moment. Nil for a tool with no menu
    /// (`registry.hasToolMenu(for:)`).
    public func toolMenu(for id: ToolID) -> [ToolMenuEntry]? { registry.toolMenus[id]?(self) }

    /// Chooses an item of a tool's menu: runs what it does, with the editor. A dimmed item does
    /// nothing.
    public func choose(_ item: ToolMenuItem) {
        guard item.isEnabled else { return }
        item.perform(self)
    }
}

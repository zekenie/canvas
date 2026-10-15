import Canvas
import ContextMenus
import Selection
import SwiftUI

// Sugar, so opting in is one line and never names the extension points.
extension ShapeRegistrar where Definition: BoardOwning {
    /// Opening this kind's shapes shows their boards: a double-click, Return, ⌘↓ and Return on their
    /// picked row (Selection's `opens`), and Open first in their context menu. `placeholder` is what
    /// a board is called while its owner has no title (on the path, in the table of contents'
    /// heading), and `systemImage` its symbol.
    ///
    ///     sub.opensBoard(placeholder: "Untitled Subboard", systemImage: "rectangle.stack")
    public mutating func opensBoard(placeholder: String, systemImage: String) {
        contribute(BoardKind(placeholder: placeholder, systemImage: systemImage), to: BoardKinds.self)
        opens("Open") { shape, editor in editor.showBoard(BoardID(owner: shape.id)) }
        contextMenu {
            MenuItem("Open", in: BoardsMenuGroup.self) { ids, editor in
                if let first = ids.first { editor.open(first) }
            }
        }
    }
}

extension PluginRegistrar {
    /// The same for a kind another plugin registers. Its definition must be `BoardOwning`:
    /// the registry refuses the plugin list otherwise (`BoardKinds.check`).
    public mutating func opensBoard<P: ShapeProps>(_: P.Type, placeholder: String, systemImage: String) {
        contribute(BoardKind(placeholder: placeholder, systemImage: systemImage), to: BoardKinds.self, for: .kind(P.kind))
        opens(P.self, "Open") { shape, editor in editor.showBoard(BoardID(owner: shape.id)) }
        contextMenu(P.self) {
            MenuItem("Open", in: BoardsMenuGroup.self) { ids, editor in
                if let first = ids.first { editor.open(first) }
            }
        }
    }
}

import Canvas
import ContextMenus
import Keyboard

/// Arrange, after every other item.
public enum ReorderMenuGroup {}
extension ReorderMenuGroup: MenuGroup {
    public static var order: Int { 200 }
}

/// Bring to Front, Bring Forward, Send Backward and Send to Back: Reordering's commands.
extension CanvasCommand {
    public static let bringToFront: CanvasCommand = "bringToFront"
    public static let bringForward: CanvasCommand = "bringForward"
    public static let sendBackward: CanvasCommand = "sendBackward"
    public static let sendToBack: CanvasCommand = "sendToBack"
}

/// An Arrange submenu in every shape's context menu, as in Keynote and tldraw: Bring to Front,
/// Bring Forward, Send Backward and Send to Back. The smallest plugin that adds items for every
/// kind, and one that picks kinds by capability: a kind painted by anchor (an arrow, just above the
/// shapes it joins) is left out, since document order doesn't decide where it's drawn.
///
/// Each is a command of its own, declared once with its title, its key (`]`, ⌥], ⌥[ and `[`) and its
/// item in the menu bar's Arrange, after Grouping's, which the context menu's items run on the menu's
/// shapes. Keys that type, so text keeps them while it has the keyboard (`runs: .whenIdle`).
public struct ReorderingPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "reordering" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.command(.bringToFront, title: "Bring to Front", menu: "Arrange", order: 100, shortcut: KeyChord("]"), runs: .whenIdle,
                          isEnabled: { $0.restackable }) { subject in
            subject.editor.transact("Bring to Front") { $0.bringToFront(subject.shapes) }
        }
        registrar.command(.bringForward, title: "Bring Forward", menu: "Arrange", order: 110, shortcut: KeyChord("]", .option), runs: .whenIdle,
                          isEnabled: { $0.restackable }) { subject in
            subject.editor.transact("Bring Forward") { $0.bringForward(subject.shapes) }
        }
        registrar.command(.sendBackward, title: "Send Backward", menu: "Arrange", order: 120, shortcut: KeyChord("[", .option), runs: .whenIdle,
                          isEnabled: { $0.restackable }) { subject in
            subject.editor.transact("Send Backward") { $0.sendBackward(subject.shapes) }
        }
        registrar.command(.sendToBack, title: "Send to Back", menu: "Arrange", order: 130, shortcut: KeyChord("["), runs: .whenIdle,
                          isEnabled: { $0.restackable }) { subject in
            subject.editor.transact("Send to Back") { $0.sendToBack(subject.shapes) }
        }
        registrar.contextMenuForEveryShape(where: { !($0 is any PaintOrderAnchored) }) {
            Submenu("Arrange", in: ReorderMenuGroup.self) {
                MenuItem(command: .bringToFront)
                MenuItem(command: .bringForward)
                MenuItem(command: .sendBackward)
                MenuItem(command: .sendToBack)
            }
        }
    }
}

extension CommandSubject {
    /// Whether the commands would restack anything: there are shapes, and none is painted by anchor
    /// (the kinds Arrange leaves out).
    fileprivate var restackable: Bool {
        guard !shapes.isEmpty else { return false }
        let document = editor.document, registry = editor.registry
        return shapes.allSatisfy { id in
            document[id].flatMap { registry.definition(for: $0.kind) }.map { !($0 is any PaintOrderAnchored) } ?? false
        }
    }
}

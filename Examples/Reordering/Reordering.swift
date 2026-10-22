import Canvas
import ContextMenus
import Keyboard

/// Arrange, after every other item but what the shape is made from (Lock, Is a ▸) and Delete.
public enum ReorderMenuGroup {}
extension ReorderMenuGroup: MenuGroup {
    public static var order: Order<Self> { .before(StateMenuGroup.self) }
}

/// Bring to Front, Bring Forward, Send Backward and Send to Back: Reordering's commands.
extension CanvasCommand {
    public static let bringToFront: CanvasCommand = "bringToFront"
    public static let bringForward: CanvasCommand = "bringForward"
    public static let sendBackward: CanvasCommand = "sendBackward"
    public static let sendToBack: CanvasCommand = "sendToBack"
}

/// Arrange's section of Bring to Front, Bring Forward, Send Backward and Send to Back: after Grouping's,
/// which comes first in plugin order.
public enum ReorderSection {}
extension ReorderSection: MenuBarSection {
    public static var menu: MenuBarMenu { "Arrange" }
}

/// An Arrange submenu in every shape's context menu, as in Keynote and tldraw: Bring to Front,
/// Bring Forward, Send Backward and Send to Back. The smallest plugin that adds items for many kinds,
/// and one that picks them by capability (`restackable`): a kind painted by anchor (an arrow, just
/// above the shapes it joins) is left out, since document order doesn't decide where it's drawn.
///
/// Each is a command of its own, declared once with its title, its key (`]`, ⌥], ⌥[ and `[`) and its
/// item in the menu bar's Arrange, after Grouping's, which the context menu's items run on the menu's
/// shapes. Keys that type, so text keeps them while it has the keyboard (`runs: .whenIdle`).
public struct ReorderingPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "reordering" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.command(.bringToFront, title: "Bring to Front", in: ReorderSection.self, shortcut: KeyChord("]"), runs: .whenIdle,
                          isEnabled: { $0.restackable }) { subject in
            subject.editor.transact("Bring to Front") { $0.bringToFront(subject.shapes) }
        }
        registrar.command(.bringForward, title: "Bring Forward", in: ReorderSection.self, shortcut: KeyChord("]", .option), runs: .whenIdle,
                          isEnabled: { $0.restackable }) { subject in
            subject.editor.transact("Bring Forward") { $0.bringForward(subject.shapes) }
        }
        registrar.command(.sendBackward, title: "Send Backward", in: ReorderSection.self, shortcut: KeyChord("[", .option), runs: .whenIdle,
                          isEnabled: { $0.restackable }) { subject in
            subject.editor.transact("Send Backward") { $0.sendBackward(subject.shapes) }
        }
        registrar.command(.sendToBack, title: "Send to Back", in: ReorderSection.self, shortcut: KeyChord("["), runs: .whenIdle,
                          isEnabled: { $0.restackable }) { subject in
            subject.editor.transact("Send to Back") { $0.sendToBack(subject.shapes) }
        }
        registrar.forShapes(adopting: .restackable) { restackable in
            restackable.contextMenu {
                Submenu("Arrange", in: ReorderMenuGroup.self) {
                    MenuItem(command: .bringToFront)
                    MenuItem(command: .bringForward)
                    MenuItem(command: .sendBackward)
                    MenuItem(command: .sendToBack)
                }
            }
        }
    }
}

extension ShapeCapability {
    /// The kinds painted in document order, not by an anchor (`PaintOrderAnchored`): the kinds that
    /// restacking means something for.
    static let restackable = ShapeCapability("painted in document order") { !$0.adopts((any PaintOrderAnchored).self) }
}

extension CommandSubject {
    /// Whether the commands would restack anything: there are shapes, and every one is of a kind painted
    /// in document order (`.restackable`, the kinds Arrange is on).
    fileprivate var restackable: Bool {
        guard !shapes.isEmpty else { return false }
        let document = editor.document, registry = editor.registry
        return shapes.allSatisfy { id in document[id].map { registry.reaches(.adopting(.restackable), $0.kind) } ?? false }
    }
}

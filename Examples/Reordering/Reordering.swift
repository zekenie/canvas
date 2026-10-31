import Canvas
import ContextMenus
import Keyboard
import SlashCommands

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
///
/// And four slash commands on the same kinds, typed in a shape's text or the command bar: `/bring-to-front`
/// and `/send-to-back`, which run those commands, and `/bring-in-front-of @Milk` and `/send-behind @Milk`,
/// which put the shapes just above, or just below, the shape named (in front of a frame is in front of what
/// it holds too), those already there staying.
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
            restackable.slashCommands {
                // Run as the commands, not typed as them (`SlashCommand(_:command:)`): their rule takes a
                // locked shape (Arrange's item shakes it), so the bar would list a row that can only be
                // refused there. Offered as any command is, never on a read-only shape.
                SlashCommand.together("bring-to-front") { ids, _, editor in editor.perform(.bringToFront, on: ids) }
                SlashCommand.together("send-to-back") { ids, _, editor in editor.perform(.sendToBack, on: ids) }
                // Asked of every shape the `@` picker ranks, as the person types.
                SlashCommand.together("bring-in-front-of", kinds: { $0.restackableKinds },
                                      shapes: { target, owners, editor in editor.restacks(owners, inFrontOf: target) },
                                      step: "Bring in Front") { owners, arguments, editor in
                    guard let target = arguments.shapes.first else { return }
                    editor.transact("Bring in Front") { $0.bring(owners, inFrontOf: target) }
                }
                SlashCommand.together("send-behind", kinds: { $0.restackableKinds },
                                      shapes: { target, owners, editor in editor.restacks(owners, behind: target) },
                                      step: "Send Behind") { owners, arguments, editor in
                    guard let target = arguments.shapes.first else { return }
                    editor.transact("Send Behind") { $0.send(owners, behind: target) }
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

extension Registry {
    /// The kinds `.restackable` reaches: the shapes `/bring-in-front-of` and `/send-behind` take.
    fileprivate var restackableKinds: Set<ShapeKind> { Set(kinds.filter { reaches(.adopting(.restackable), $0) }) }
}

extension CanvasEditor {
    /// Whether `/bring-in-front-of` takes `target` for `shapes`: a shape on the board shown that one of them
    /// would go in front of, being below it or below the top of what it holds, not it, not held by it and
    /// not a shape that holds it (`bring(_:inFrontOf:)`). O(the shapes, what the target holds and the
    /// depths).
    fileprivate func restacks(_ shapes: [ShapeID], inFrontOf target: ShapeID) -> Bool {
        guard let place = document.index(of: target) else { return false }
        let kinds = registry.containingKinds, holders = Set(document.containers(of: target, containingKinds: kinds))
        // What a container holds paints above it: in front of it is in front of all of that.
        let top = document.descendants(of: target, containingKinds: kinds).last.flatMap(document.index(of:)) ?? place
        return shapes.contains { id in
            guard id != target, !holders.contains(id), let at = document.index(of: id), at < top else { return false }
            return at < place || !document.containers(of: id, containingKinds: kinds).contains(target)
        }
    }

    /// Whether `/send-behind` takes `target` for `shapes`: a shape on the board shown that one of them would go
    /// behind, being above it, not it, not a shape that holds it, and not in a container the target isn't above
    /// (`send(_:behind:)`). O(the shapes and the target's depth).
    fileprivate func restacks(_ shapes: [ShapeID], behind target: ShapeID) -> Bool {
        guard let place = document.index(of: target) else { return false }
        let kinds = registry.containingKinds, holders = Set(document.containers(of: target, containingKinds: kinds))
        return shapes.contains { id in
            guard id != target, !holders.contains(id), let at = document.index(of: id), at > place else { return false }
            guard let container = document.container(of: id, containingKinds: kinds) else { return true }
            return document.index(of: container).map { $0 < place } ?? true
        }
    }
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

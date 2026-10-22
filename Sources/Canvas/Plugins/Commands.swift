import AppKit

// Commands: each thing to do is declared once, by the plugin it belongs to, with what it's called,
// where its menu bar item is, what it acts on and when it can run; a key, a menu bar item, a context
// menu's item, a line typed in a shape's text, a chip and a panel's button all run that one
// declaration. The core knows what a command is, never which commands exist: it holds them as
// registered data, as it holds kinds and tools, and runs one by name (`editor.perform`).

/// What a command acts on: shapes, where it was asked for, and the editor. From a key or the menu
/// bar, the selection (what `registrar.commandShapes` says), with no point; from a context menu, the
/// menu's shapes and the click; from a line typed in a shape's text or a chip, that shape.
@MainActor
public struct CommandSubject {
    public let editor: CanvasEditor
    /// In selection order, for the selection.
    public let shapes: [ShapeID]
    /// Where it was asked for, in world units: a context menu's click, which a command that puts
    /// something down puts it at (Paste). Nil from a key or the menu bar.
    public let point: CGPoint?

    public init(editor: CanvasEditor, shapes: [ShapeID], point: CGPoint? = nil) {
        self.editor = editor
        self.shapes = shapes
        self.point = point
    }
}

/// When a command may run from a key or the menu bar, besides its rule (`isEnabled`): what a key
/// pressed on the canvas, or an item chosen from the menu bar, would otherwise reach it in the middle
/// of. A surface that brings its own shapes brings its own moment, and is asked the rule alone: a
/// context menu, which ends editing as it opens and is never asked mid-press, a line typed in a
/// shape's own text, a chip's click.
public enum CommandMoment: Sendable, Hashable {
    /// Whenever its rule says: a zoom, Copy, Delete.
    case anytime
    /// With no press under way (`editor.session`): Back, Find…, Cut, Paste.
    case betweenPresses
    /// With no press under way and no shape being edited: what changes shapes, whose text has the
    /// keyboard while one is edited. Its menu bar item is dimmed while text has the keyboard (a note
    /// being edited, a panel's field), so a key it shares with text is the text's: ⌘↓ moves the caret,
    /// `]` types.
    case whenIdle

    /// Whether the editor is at such a moment now.
    @MainActor public func allows(_ editor: CanvasEditor) -> Bool {
        switch self {
        case .anytime: true
        case .betweenPresses: editor.session == nil
        case .whenIdle: editor.session == nil && editor.editingShapeID == nil
        }
    }
}

/// One of AppKit's standard actions, which whatever has the keyboard answers first: the items of the
/// Edit menu that are AppKit's own (a text field's Cut cuts its text, the table of contents' Select All
/// selects its rows), and a trackpad's smart zoom, which the view under the pointer gets. A command that
/// answers one (`registrar.command(… answering: .cut …)`) is what it does on the board, when nothing
/// nearer took it (the canvas, a control in the panel). The window keeps the items, their titles and
/// their keys, so every text field has them whatever is installed; at most one command answers each.
public enum StandardAction: Sendable, Hashable, CaseIterable {
    case undo, redo, cut, copy, paste, delete, selectAll
    /// A two-finger double-tap on a trackpad, on the canvas.
    case smartMagnify
}

/// Where a menu is in the menu bar, written as a path through menus is: `"Arrange"`, `"Edit › Find"`
/// (a section's menu's, `MenuBarMenu.path`, and so a command's item's, `MenuBarCommand.menu`).
public struct MenuPath: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    /// The menu's title, then the submenu's, if it's in one.
    public let titles: [String]

    public init(_ titles: [String]) {
        precondition(!titles.isEmpty && titles.allSatisfy { !$0.isEmpty }, "a menu path names a menu")
        self.titles = titles
    }

    public init(stringLiteral value: String) { self.init(value.components(separatedBy: Self.separator)) }

    public var description: String { titles.joined(separator: Self.separator) }

    static let separator = " › "
}

/// What `CorePoints.Commands` stores. Only the sugar makes one.
struct CommandRegistration {
    let command: CanvasCommand
    /// What it's called, as its menu item is ("Delete", "Zoom to Fit"): the name a context menu's item,
    /// a panel's button and the Keyboard Shortcuts window give it.
    let title: String
    /// The section its item in the menu bar is in, if it has one, and its place among the section's items.
    let section: (any MenuBarSection.Type)?
    let placement: OrderRule
    /// The item of AppKit's Edit menu it is on the board, if it is one.
    let answering: StandardAction?
    let moment: CommandMoment
    /// What its menu item is called now, for a command that is named for the step it would take
    /// (`editor.menuTitle(of:)`); `title` otherwise.
    let menuTitle: (@MainActor (CanvasEditor) -> String)?
    let isEnabled: @MainActor (CommandSubject) -> Bool
    let run: @MainActor (CommandSubject) -> Void
}

extension PluginRegistrar {
    /// A command: something to do, declared once, which every surface runs (`editor.perform`).
    ///
    ///     extension CanvasCommand { public static let group: CanvasCommand = "group" }
    ///
    ///     registrar.command(.group, title: "Group", in: GroupingSection.self, runs: .whenIdle,
    ///                       isEnabled: { $0.editor.canGroup($0.shapes) }) { $0.editor.group($0.shapes) }
    ///
    /// (Keyboard's `command(…shortcut:…)` is this with the command's keys: Grouping's gives ⌥⌘G.)
    ///
    /// - `title`: what it's called, as its menu item is ("Group"), wherever it's listed: its menu bar
    ///   item, a context menu's item that runs it, a panel's button, the Keyboard Shortcuts window.
    /// - `in` and `placed`: its item in the menu bar, if it has one: the section it's in (a
    ///   `MenuBarSection`, which says its menu: Grouping's, in Arrange), a line between two sections,
    ///   and its place among the section's items (`Order`: by default where it first appears, the
    ///   window's own items first, then the commands' in plugin order; `.after(.paste)` right after the
    ///   item that runs `.paste`). The window's own items are in sections too: the core's, where commands
    ///   go beside them (`EditMenu.Undo`, `.CutCopyPaste` and `.FindAndSpelling`; `ViewMenu.Zoom`), and the
    ///   window's alone (File's, View's panels and, last, Enter Full Screen, Window's, Help's).
    /// - `answering`: the item of AppKit's Edit menu it is on the board (`.cut`), for a command that
    ///   has no item of its own: the window's item runs it when nothing with the keyboard takes it.
    /// - `runs`: when a key or the menu bar may run it, besides `isEnabled` (`CommandMoment`).
    /// - `menuTitle`: what its menu bar item is called now, for a command named for the step it would
    ///   take (Go › Enclosing Group, Enclosing Frame, Enclosing Board); `title` stays its name wherever
    ///   it's listed.
    /// - `isEnabled`: its rule, whether it can act on its subject (`CommandSubject`: the selection from
    ///   a key or the menu bar, a context menu's shapes and click): one rule, which dims its items and
    ///   lets its keys pass while it says no. By default, always. A command a context menu runs reads
    ///   the subject's shapes in it and in `run`, never the editor's selection: a right-click asks the
    ///   rule before it selects them.
    /// - `run`: what it does to its subject, in one undo step, named as what it commits names it.
    ///
    /// Its keys are Keyboard's to give: Keyboard's `command(_:title:…shortcut:…)` declares one with them.
    /// At most one plugin may claim each command, and one command each standard action.
    public mutating func command(_ command: CanvasCommand, title: String, in section: (any MenuBarSection.Type)? = nil,
                                 placed placement: Order<CanvasCommand> = .natural,
                                 answering: StandardAction? = nil, runs moment: CommandMoment = .anytime,
                                 menuTitle: (@MainActor (CanvasEditor) -> String)? = nil,
                                 isEnabled: @escaping @MainActor (CommandSubject) -> Bool = { _ in true },
                                 _ run: @escaping @MainActor (CommandSubject) -> Void) {
        contribute(CommandRegistration(command: command, title: title, section: section, placement: placement.rule, answering: answering,
                                       moment: moment, menuTitle: menuTitle, isEnabled: isEnabled, run: run), to: CorePoints.Commands.self)
    }

    /// What a command run from a key or the menu bar acts on: the selection, for the plugin that keeps
    /// it (`registrar.commandShapes { $0.selectedShapeIDs }`, Selection's). At most one plugin may claim
    /// it; otherwise such a command acts on no shapes. `select`: how that plugin selects shapes when
    /// something other than a plugin asks (VoiceOver's press on a shape, `editor.selectForAccessibility`);
    /// nil, and nothing does.
    public mutating func commandShapes(_ shapes: @escaping @MainActor (CanvasEditor) -> [ShapeID],
                                       select: (@MainActor (CanvasEditor, [ShapeID]) -> Void)? = nil) {
        contribute(CommandShapesClaim(shapes: shapes, select: select), to: CorePoints.CommandShapes.self)
    }
}

extension Registry {
    /// Whether a plugin (or the core) claims the command, so `editor.perform` can run it.
    public func claims(_ command: CanvasCommand) -> Bool { self.command(command) != nil }

    /// What the plugin that claims a command calls it ("Delete"); nil for a command none claims.
    public func title(of command: CanvasCommand) -> String? { self.command(command)?.title }

    /// When a key or the menu bar may run a command (`CommandMoment`); nil for one none claims.
    public func moment(of command: CanvasCommand) -> CommandMoment? { self.command(command)?.moment }

    /// The command that is an item of AppKit's Edit menu on the board (the one declared
    /// `answering:` it), which the window runs when nothing with the keyboard takes the item; nil for
    /// none.
    public func command(answering action: StandardAction) -> CanvasCommand? {
        commandTable.answering[action]
    }

    /// A command's registration, found in a table made once.
    func command(_ command: CanvasCommand) -> CommandRegistration? { commandTable.byCommand[command] }

    /// The commands by name, and by the standard action each answers, made the first time asked: keys
    /// and menus ask on every key and every update.
    var commandTable: CommandTable {
        memo(CommandTableMemo()) {
            let registrations = contributions(to: CorePoints.Commands.self).map(\.value)
            return CommandTable(byCommand: Dictionary(registrations.map { ($0.command, $0) }, uniquingKeysWith: { first, _ in first }),
                                answering: Dictionary(registrations.compactMap { r in r.answering.map { ($0, r.command) } },
                                                      uniquingKeysWith: { first, _ in first }),
                                inOrder: registrations,
                                shapes: contributions(to: CorePoints.CommandShapes.self).first?.value.shapes,
                                select: contributions(to: CorePoints.CommandShapes.self).first?.value.select)
        }
    }
}

/// `Registry.commandTable`.
struct CommandTable {
    let byCommand: [CanvasCommand: CommandRegistration]
    let answering: [StandardAction: CanvasCommand]
    /// Every registration, in plugin order.
    let inOrder: [CommandRegistration]
    /// What a command run from a key or the menu bar acts on (`registrar.commandShapes`), if a plugin says.
    let shapes: (@MainActor (CanvasEditor) -> [ShapeID])?
    /// How that plugin selects shapes, if it says.
    let select: (@MainActor (CanvasEditor, [ShapeID]) -> Void)?
}

/// The selection as the core reads it (`registrar.commandShapes`): what commands act on, and how the
/// plugin that keeps it selects shapes.
struct CommandShapesClaim {
    let shapes: @MainActor (CanvasEditor) -> [ShapeID]
    let select: (@MainActor (CanvasEditor, [ShapeID]) -> Void)?
}

private struct CommandTableMemo: Hashable {}

extension CorePoints.Commands: KeyedExtensionPoint {
    typealias Contribution = CommandRegistration
    static var owner: PluginID { .core }
    static func uniqueKeys(of c: CommandRegistration, for _: ShapeTarget) -> [AnyHashable] {
        [AnyHashable(c.command)] + (c.answering.map { [AnyHashable(StandardActionKey(action: $0))] } ?? [])
    }

    /// Refuses a menu bar its items' declarations can't make: an item placed in no section, a submenu
    /// inside itself, a submenu its sections place two ways, sections or items placed beside each other in
    /// a circle, a section placed beside one in another menu, and an item beside a command whose item is
    /// in another section. The
    /// window's own sections and items aren't the registry's to see: one placed beside them goes where it
    /// says as the window makes the menus, or, where what it names isn't, where one that says nothing would.
    static func check(_ registry: Registry) throws(RegistryError) {
        if let stray = registry.commandTable.inOrder.first(where: { $0.section == nil && $0.placement != .natural }) {
            throw .invalid(point: "Commands", reason: "\(stray.command) is placed \(stray.placement) in no section: name its section (in:)")
        }
        let items = registry.commandTable.inOrder.filter { $0.section != nil }
        // Every section an item is in, and those the submenus they're in are in, each once, in the order met.
        var sections: [any MenuBarSection.Type] = []
        var named: [ObjectIdentifier: any MenuBarSection.Type] = [:]
        for item in items {
            var chain: [any MenuBarSection.Type] = []
            var next = item.section
            while let section = next, named[ObjectIdentifier(section)] == nil {
                if chain.contains(where: { ObjectIdentifier($0) == ObjectIdentifier(section) }) {
                    let names = (chain + [section]).map { $0.reportedName }
                    throw .invalid(point: "Commands", reason: "a submenu inside itself: \(names.joined(separator: " in "))")
                }
                chain.append(section)
                if case .submenu(_, let parent, _) = section.menu { next = parent } else { next = nil }
            }
            for section in chain {
                named[ObjectIdentifier(section)] = section
                sections.append(section)
            }
        }
        var submenus: [MenuPath: (section: any MenuBarSection.Type, place: OrderRule)] = [:]
        func said(_ section: any MenuBarSection.Type, _ place: OrderRule) -> String { section.reportedName + (place == .natural ? "" : " \(place)") }
        for case let (section, .submenu(title, parent, placed)) in sections.map({ ($0, $0.menu) }) {
            let path = MenuPath(parent.menu.path.titles + [title])
            if let other = submenus[path], ObjectIdentifier(other.section) != ObjectIdentifier(parent) || other.place != placed.rule {
                throw .invalid(point: "Commands", reason: "\(section.reportedName) puts submenu \(path) in \(said(parent, placed.rule)), "
                               + "where another section puts it in \(said(other.section, other.place))")
            }
            submenus[path] = (parent, placed.rule)
        }
        if let cycle = OrderRule.cycle(from: sections.map { $0.orderAnchor }) {
            throw .invalid(point: "Commands", reason: "menu bar sections placed beside each other in a circle: \(cycle)")
        }
        for section in sections {
            guard case .type(let id)? = section.orderRule.anchor?.id, let other = named[id], other.menu.path != section.menu.path else { continue }
            throw .invalid(point: "Commands", reason: "\(section.reportedName) is placed \(section.orderRule), which is in \(other.menu.path), not \(section.menu.path)")
        }
        let places = Dictionary(items.map { (OrderAnchor($0.command), $0.placement) }, uniquingKeysWith: { first, _ in first })
        if let cycle = OrderRule.cycle(from: items.map { OrderAnchor($0.command) }, rule: { places[$0] ?? $0.rule() }) {
            throw .invalid(point: "Commands", reason: "menu bar items placed beside each other in a circle: \(cycle)")
        }
        for item in items {
            guard let section = item.section, case .command(let other)? = item.placement.anchor?.id,
                  let elsewhere = registry.command(other)?.section, ObjectIdentifier(elsewhere) != ObjectIdentifier(section) else { continue }
            throw .invalid(point: "Commands", reason: "\(item.command) is placed \(item.placement), whose item is in \(elsewhere.reportedName), not \(section.reportedName)")
        }
    }
}

extension CommandRegistration {
    /// Where the registry's report says its item is: its place among its section's items, if it says
    /// one, then its section, with the section's order if it says one (" after paste in EditMenu.CutCopyPaste").
    var reportedPlace: String {
        guard let section else { return "" }
        return (placement == .natural ? "" : " \(placement)") + " in \(section.reportedName)"
            + (section.orderRule == .natural ? "" : " \(section.orderRule)")
    }
}

extension CanvasEditor {
    /// What a command run from a key or the menu bar acts on: the selection (`registrar.commandShapes`),
    /// with no point.
    public var commandSubject: CommandSubject {
        CommandSubject(editor: self, shapes: registry.commandTable.shapes?(self) ?? [])
    }

    /// Runs the command a plugin declared, on what a key or the menu bar acts on (the selection), if it
    /// can run now: at its moment (`CommandMoment`), and its rule says so. What it commits is one undo
    /// step. False if no plugin claims it, or it can't.
    @discardableResult
    public func perform(_ command: CanvasCommand) -> Bool {
        guard let registration = registry.command(command), registration.moment.allows(self) else { return false }
        let subject = commandSubject
        guard registration.isEnabled(subject) else { return false }
        undoHistory.group { registration.run(subject) }
        return true
    }

    /// Whether `perform` would run the command now: what a menu item asks to enable itself, and a key
    /// before it takes the key.
    public func canPerform(_ command: CanvasCommand) -> Bool {
        guard let registration = registry.command(command), registration.moment.allows(self) else { return false }
        return registration.isEnabled(commandSubject)
    }

    /// Runs a command on shapes a surface brings (a context menu's, and where it was opened), if its
    /// rule says it can act on them: the surface brings its own moment (a menu ends editing as it opens),
    /// so `CommandMoment` isn't asked. One undo step. False if no plugin claims it, or it can't.
    @discardableResult
    public func perform(_ command: CanvasCommand, on shapes: [ShapeID], at point: CGPoint? = nil) -> Bool {
        let subject = CommandSubject(editor: self, shapes: shapes, point: point)
        guard let registration = registry.command(command), registration.isEnabled(subject) else { return false }
        undoHistory.group { registration.run(subject) }
        return true
    }

    /// Whether the command can act on shapes a surface brings: its rule alone (see `perform(_:on:at:)`).
    public func canPerform(_ command: CanvasCommand, on shapes: [ShapeID], at point: CGPoint? = nil) -> Bool {
        registry.command(command)?.isEnabled(CommandSubject(editor: self, shapes: shapes, point: point)) ?? false
    }

    /// Runs a command on shapes whatever its rule says: a try, as a chip's click is, or a line typed in a
    /// shape's own text, which a surface offers by what it shows. What the command can't do it refuses
    /// (the core refuses a read-only shape), and what's refused shakes. One undo step. False only if no
    /// plugin claims it.
    @discardableResult
    public func attempt(_ command: CanvasCommand, on shapes: [ShapeID], at point: CGPoint? = nil) -> Bool {
        guard let registration = registry.command(command) else { return false }
        let subject = CommandSubject(editor: self, shapes: shapes, point: point)
        undoHistory.group { registration.run(subject) }
        return true
    }

    /// Runs the command that answers a standard action (`registry.command(answering:)`), as `perform`
    /// does: what the window's Edit › Cut does on the board. False for none, or one that can't run.
    @discardableResult
    public func perform(answering action: StandardAction) -> Bool {
        registry.command(answering: action).map { perform($0) } ?? false
    }

    /// Whether `perform(answering:)` would run a command now: what the window asks to enable Edit › Cut.
    public func canPerform(answering action: StandardAction) -> Bool {
        registry.command(answering: action).map { canPerform($0) } ?? false
    }

    /// What the menu item that runs the command should be called now, for a command whose title
    /// follows the editor (`registrar.command(…menuTitle:…)`: Go › Enclosing Group); nil for one
    /// whose item keeps its own title, or that no plugin claims. The window asks as it validates the
    /// item.
    public func menuTitle(of command: CanvasCommand) -> String? {
        registry.command(command)?.menuTitle?(self)
    }
}

extension MenuKey {
    /// The modifiers as a menu item holds them (`NSMenuItem.keyEquivalentModifierMask`).
    public var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }
}

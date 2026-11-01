import CanvasRPC
import CoreGraphics
import SwiftUI

// Host slots: what a board's window puts around its canvas, and what the app takes from the plugins
// besides, said by the plugins whose views and words they are, and placed by the host, which knows
// no plugin. A plugin can't import the window (CanvasUI) or the app, and neither can import a
// plugin, so what passes between them is declared here, beneath both: views over the canvas, the
// sidebar before it and the inspector after it, the window's subtitle, the panes of the Settings
// window, the toolbar's tool tips, the rows of the Keyboard Shortcuts window, the menu bar's commands
// and the keys menus show, what Copy as Image draws and the commands the app's command server runs.
// Every point is the core's, so it's always installed: a plugin contributes from its own
// `register`, and a list without the plugin is a host without its piece.
//
// A view a plugin gives is made for a window's canvas: it's handed that board's editor and `onExit`,
// which gives the keyboard back to the canvas (a view that takes the keyboard calls it when it's
// done with it), and follows the editor by itself.

// MARK: Views over the canvas

/// The views a window places over its canvas, each over the whole of it, in plugin order (a later
/// one is over an earlier one): the path of crumbs at its top (Boards), a palette (Jump To). Not a
/// `CanvasOverlay`, which the canvas draws into itself, in the world: these are the window's views,
/// and take clicks where they draw.
public enum HostOverlays {}

extension HostOverlays: ExtensionPoint {
    public typealias Contribution = HostOverlay
    public static var owner: PluginID { .core }
    public static func summary(of _: HostOverlay, for _: ShapeTarget) -> String { "host overlay" }
}

/// What `HostOverlays` stores: a view over the canvas, where it sits there, and how much of the
/// canvas's top it covers. Only the sugar makes one.
@MainActor
public struct HostOverlay {
    /// Where the view sits over the canvas (`.overlay(alignment:)`).
    public let alignment: Alignment
    /// How far down over the canvas the view reaches on a board, in view points from the canvas's
    /// top edge: what fitting shapes into view leaves clear (the window tells the editor,
    /// `coveredTop`). Zero for a view that covers nothing a fit should mind.
    public let coveredTop: @MainActor (BoardID) -> CGFloat
    let content: @MainActor (CanvasEditor, @escaping @MainActor () -> Void) -> AnyView

    /// The view, for a window's canvas.
    public func view(for editor: CanvasEditor, onExit: @escaping @MainActor () -> Void) -> AnyView { content(editor, onExit) }
}

// MARK: The sidebar

/// The view a window shows along its canvas's leading edge, in a sidebar the person shows and hides
/// (the table of contents). At most one: two are `RegistryError.conflict` at startup. Without one the
/// window has no sidebar.
public enum HostSidebars {}

extension HostSidebars: KeyedExtensionPoint {
    public typealias Contribution = HostSidebar
    public static var owner: PluginID { .core }
    public static func uniqueKeys(of _: HostSidebar, for _: ShapeTarget) -> [AnyHashable] { ["sidebar"] }
    public static func summary(of _: HostSidebar, for _: ShapeTarget) -> String { "host sidebar" }
}

/// What `HostSidebars` stores: the sidebar's view, how wide it may be, and the view in it that takes the
/// keyboard. Only the sugar makes one.
@MainActor
public struct HostSidebar {
    /// How wide the window makes it: the width it starts at, and the narrowest and widest a drag
    /// of its edge takes it to.
    public let width: PaneWidth
    /// Where the keyboard goes when the window gives the sidebar the keyboard (View ▸ Focus Sidebar,
    /// Focus Next Pane): the view the plugin says takes it now, nil when it names none (the window then
    /// looks for a list, field or control in the sidebar itself).
    public let keyboardEntry: (@MainActor (CanvasEditor) -> NSView?)?
    let content: @MainActor (CanvasEditor, @escaping @MainActor () -> Void) -> AnyView

    /// The view, for a window's sidebar.
    public func view(for editor: CanvasEditor, onExit: @escaping @MainActor () -> Void) -> AnyView { content(editor, onExit) }
}

// MARK: The inspector

/// The view a window shows along its canvas's trailing edge, in its inspector (the detail panel). At
/// most one: two are `RegistryError.conflict` at startup. Without one the window has no inspector.
public enum HostInspectors {}

extension HostInspectors: KeyedExtensionPoint {
    public typealias Contribution = HostInspector
    public static var owner: PluginID { .core }
    public static func uniqueKeys(of _: HostInspector, for _: ShapeTarget) -> [AnyHashable] { ["inspector"] }
    public static func summary(of _: HostInspector, for _: ShapeTarget) -> String { "host inspector" }
}

/// What `HostInspectors` stores: the inspector's view, when it has something to show, when it's
/// wanted whether or not the person has it shown, and what hiding it meanwhile does. Only the sugar
/// makes one.
///
/// The window keeps the rule, for whatever is wanted: it shows the inspector while it's wanted, and
/// otherwise while the person has it shown and it has something to show (`shownWhile`); and hidden by
/// the person while wanted, it's dismissed (`onDismiss`), and the keyboard goes back to the canvas.
@MainActor
public struct HostInspector {
    /// How wide the window makes it, as the sidebar's (`HostSidebar.width`).
    public let width: PaneWidth
    /// Whether the inspector has something to show now (the detail panel: while shapes are selected),
    /// so the person having it shown shows it. Read in a view's body, so it reads observable state.
    public let shownWhile: @MainActor (CanvasEditor) -> Bool
    /// Whether the inspector is wanted now, shown or hidden by the person. Read in a view's body, so it
    /// reads observable state.
    public let isRequested: @MainActor (CanvasEditor) -> Bool
    /// The person hid the inspector while it was wanted: end what wanted it.
    public let onDismiss: @MainActor (CanvasEditor) -> Void
    /// Where the keyboard goes when the window gives the inspector the keyboard (View ▸ Focus Inspector,
    /// Focus Next Pane): the view the panel says takes it now, nil when it names none (the window then
    /// looks for a list, field or control itself, and failing that gives the keyboard to the inspector's
    /// hosting view, where Tab enters the panel's loop).
    public let keyboardEntry: (@MainActor (CanvasEditor) -> NSView?)?
    let content: @MainActor (CanvasEditor, @escaping @MainActor () -> Void) -> AnyView

    /// The view, for a window's inspector.
    public func view(for editor: CanvasEditor, onExit: @escaping @MainActor () -> Void) -> AnyView { content(editor, onExit) }
}

/// How wide a pane the window shows along an edge of its canvas is, in points: the width it starts at
/// (`ideal`), and the narrowest and the widest a drag of its inner edge takes it to.
public struct PaneWidth: Equatable, Sendable {
    public var min: CGFloat
    public var ideal: CGFloat
    public var max: CGFloat

    /// `max` under `min` is taken as `min`: a pane is never narrower than it says.
    public init(min: CGFloat, ideal: CGFloat, max: CGFloat) {
        self.min = min
        self.max = Swift.max(max, min)
        self.ideal = Swift.min(Swift.max(ideal, min), self.max)
    }

    /// A width the person left it at (nil for none: the ideal), kept within the narrowest and the widest.
    public func clamped(_ width: CGFloat?) -> CGFloat { Swift.min(Swift.max(width ?? ideal, min), max) }

    /// What a pane says nothing of starts at.
    public static let standard = PaneWidth(min: 200, ideal: 260, max: 400)
}

// MARK: The window's subtitle

/// What a window's subtitle says of the board shown (what it's called inside a subboard, so windows
/// open on one file's boards can be told apart), nil for none. At most one: two are
/// `RegistryError.conflict` at startup. Read observed, so it reads observable state and the
/// subtitle follows it.
public enum WindowSubtitles {}

extension WindowSubtitles: KeyedExtensionPoint {
    public typealias Contribution = @MainActor (CanvasEditor) -> String?
    public static var owner: PluginID { .core }
    public static func uniqueKeys(of _: Contribution, for _: ShapeTarget) -> [AnyHashable] { ["subtitle"] }
    public static func summary(of _: Contribution, for _: ShapeTarget) -> String { "window subtitle" }
}

// MARK: Settings panes

/// The panes of the app's Settings window, one under another in plugin order. A pane is named, once:
/// two with one title are `RegistryError.conflict` at startup.
public enum SettingsPanes {}

extension SettingsPanes: KeyedExtensionPoint {
    public typealias Contribution = SettingsPane
    public static var owner: PluginID { .core }
    public static func uniqueKeys(of pane: SettingsPane, for _: ShapeTarget) -> [AnyHashable] { [pane.title] }
    public static func summary(of pane: SettingsPane, for _: ShapeTarget) -> String { "settings pane \(pane.title)" }
}

/// What `SettingsPanes` stores: what the pane is called (in the registry's report; the window heads
/// no pane, a pane says what it is itself), and its view, made afresh each time the Settings window
/// opens (it belongs to no board, so it's handed no editor). Only the sugar makes one.
@MainActor
public struct SettingsPane {
    public let title: String
    let content: @MainActor () -> AnyView

    /// The pane's view, made now.
    public func view() -> AnyView { content() }
}

extension EnvironmentValues {
    /// Whether a Settings pane puts the keyboard in its first field as it appears: the window says
    /// true to its first pane and false to the rest, so it opens with the keyboard at its top; a pane
    /// hosted alone takes it.
    public var settingsPaneTakesFocus: Bool {
        get { self[SettingsPaneFocusKey.self] }
        set { self[SettingsPaneFocusKey.self] = newValue }
    }
}

private struct SettingsPaneFocusKey: EnvironmentKey {
    static let defaultValue = true
}

// MARK: Tool tips

/// What the toolbar says of a tool when the pointer rests on it: from the plugin that knows more of
/// a tool than its label (Keyboard: the key that switches to it, "Note (N)"). At most one: two are
/// `RegistryError.conflict` at startup. Without one a tool's tip is its label.
public enum ToolTips {}

extension ToolTips: KeyedExtensionPoint {
    public typealias Contribution = @MainActor (ToolDescriptor, Registry) -> String
    public static var owner: PluginID { .core }
    public static func uniqueKeys(of _: Contribution, for _: ShapeTarget) -> [AnyHashable] { ["tool tips"] }
    public static func summary(of _: Contribution, for _: ShapeTarget) -> String { "tool tips" }
}

// MARK: Keyboard help

/// The rows of the app's Keyboard Shortcuts window that come from what's registered: from the plugin
/// that keeps the keys (Keyboard: every key the canvas answers, each under what it does). At most
/// one: two are `RegistryError.conflict` at startup. Without one the window lists the menu bar's
/// keys and the hints alone.
public enum KeyboardHelp {}

extension KeyboardHelp: KeyedExtensionPoint {
    public typealias Contribution = @MainActor (Registry) -> [KeyboardHelpRow]
    public static var owner: PluginID { .core }
    public static func uniqueKeys(of _: Contribution, for _: ShapeTarget) -> [AnyHashable] { ["keyboard help"] }
    public static func summary(of _: Contribution, for _: ShapeTarget) -> String { "keyboard help" }
}

/// Keys no plugin registers, said beside the code that reads them so the Keyboard Shortcuts window
/// lists them too: a key held through a click or a drag (⌥ drags a copy), or a key text being
/// edited answers (⌘↩ finishes). Any number, in plugin order; the same row twice is listed once.
public enum KeyHints {}

extension KeyHints: ExtensionPoint {
    public typealias Contribution = KeyboardHelpRow
    public static var owner: PluginID { .core }
    public static func summary(of row: KeyboardHelpRow, for _: ShapeTarget) -> String { "key hint \(row.keys.joined(separator: " ")) \(row.title)" }
}

/// A row of the Keyboard Shortcuts window: the keys, as they're written ("⌘A", "←↑→↓"), what they
/// do, and where they do it, which the window files the row under.
public struct KeyboardHelpRow: Hashable, Sendable {
    /// Where the keys do what they do.
    public enum Place: Hashable, Sendable {
        /// They switch to a tool.
        case tool
        /// They run a command, as a menu item may: the window files them under the menu whose
        /// item runs it, else with the canvas's.
        case command(CanvasCommand)
        /// They do something else on the canvas.
        case canvas
        /// Held through a click, a drag or a scroll.
        case pointer
        /// While text is being edited.
        case text
    }

    public let keys: [String]
    public let title: String
    public let place: Place

    public init(keys: [String], title: String, place: Place) {
        self.keys = keys
        self.title = title
        self.place = place
    }
}

/// Where a key hint's keys do what they do (`registrar.keyHint`).
public enum KeyHintPlace: Sendable {
    /// Held through a click, a drag or a scroll.
    case pointer
    /// While text is being edited.
    case text
}

// MARK: The menu bar

/// The keys that run a command, as menu items take them, from the plugin that keeps the keys (Keyboard:
/// each key registered to run it, in the order registered): the first is the one the menu bar's item for
/// a command (`registrar.command(… in: …)`) shows, and a context menu's item that runs one; the menu bar
/// answers the rest too, wherever the first works (Go › Back's ⌃-, beside its ⌘[). At most one: two are
/// `RegistryError.conflict` at startup. Without one, no command's item shows a key.
public enum MenuKeys {}

extension MenuKeys: KeyedExtensionPoint {
    public typealias Contribution = @MainActor (CanvasCommand, Registry) -> [MenuKey]
    public static var owner: PluginID { .core }
    public static func uniqueKeys(of _: Contribution, for _: ShapeTarget) -> [AnyHashable] { ["menu keys"] }
    public static func summary(of _: Contribution, for _: ShapeTarget) -> String { "menu keys" }
}

/// A key as a menu item holds it: its key equivalent, as `NSMenuItem.keyEquivalent` takes it (`"g"`,
/// an arrow's function key, Backspace's `"\u{8}"` for Delete), and the modifiers held with it
/// (`modifierFlags`, as the item takes them).
public struct MenuKey: Hashable, Sendable {
    public let key: String
    public let modifiers: Modifiers

    public init(key: String, modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// A command the menu bar has an item for: what it's called, where (its section, which says its menu,
/// and its place among the section's items) and the key the item shows. The window makes the item;
/// choosing it runs the command (`editor.perform`), and its validation asks the command's moment
/// (`registry.moment(of:)`) and rule.
public struct MenuBarCommand: Sendable {
    public let command: CanvasCommand
    public let title: String
    public let section: any MenuBarSection.Type
    public let placement: OrderRule
    public let key: MenuKey?

    /// The menu its item is in (`"Edit › Find"`): its section's.
    public var menu: MenuPath { section.menu.path }
}

// MARK: Copy as Image

/// What Edit › Copy as Image draws: from the plugin that knows what a copy of shapes takes (Clipboard),
/// the shapes of the board shown a copy of the selection (or of the board, with nothing selected)
/// would take, which the window draws from the board's own file, as the canvas draws them
/// (`BoardPicture(file:registry:board:showing:)`: the file's colors, the types and what mentions name,
/// wherever they are), and puts on the pasteboard as an image. At most one: two are
/// `RegistryError.conflict` at startup. Without one the item is dimmed.
public enum ImageSources {}

extension ImageSources: KeyedExtensionPoint {
    public typealias Contribution = ImageSource
    public static var owner: PluginID { .core }
    public static func uniqueKeys(of _: ImageSource, for _: ShapeTarget) -> [AnyHashable] { ["image source"] }
    public static func summary(of _: ImageSource, for _: ShapeTarget) -> String { "image source" }
}

/// What `ImageSources` stores: whether there is anything to draw now (asked as the menu item is
/// validated, so cheap), and the shapes to draw. Only the sugar makes one.
@MainActor
public struct ImageSource {
    /// Whether `shapes(for:)` would give any now.
    public let isAvailable: @MainActor (CanvasEditor) -> Bool
    let content: @MainActor (CanvasEditor) -> [ShapeID]

    /// The shapes of a board's editor's board shown to draw, back to front: none for nothing to draw.
    public func shapes(for editor: CanvasEditor) -> [ShapeID] { content(editor) }
}

// MARK: The command line

/// The commands the app's command server runs for the command line, beyond its own: from the
/// plugin that is the command line (Automation, whose commands the other plugins register with it).
/// At most one: two are `RegistryError.conflict` at startup. Without one the server runs only its
/// own. The one slot whose types are the wire's (CanvasRPC), which is why Canvas imports it.
public enum HostCommands {}

extension HostCommands: KeyedExtensionPoint {
    public typealias Contribution = HostCommandLine
    public static var owner: PluginID { .core }
    public static func uniqueKeys(of _: HostCommandLine, for _: ShapeTarget) -> [AnyHashable] { ["commands"] }
    public static func summary(of _: HostCommandLine, for _: ShapeTarget) -> String { "host commands" }
}

/// What `HostCommands` stores: what the command line shows of each command, and how to run one, by
/// name, both read off the frozen registry (the commands are every plugin's, so they're known only
/// once it's built). Only the sugar makes one.
@MainActor
public struct HostCommandLine {
    let specs: @MainActor (Registry) -> [CommandSpec]
    let run: @MainActor (Registry, String, JSON, CanvasEditor?) async throws(RPCError) -> JSON
}

// MARK: Contributing

extension PluginRegistrar {
    /// A view over the window's canvas, over the whole of it at `alignment`, later plugins' over
    /// earlier ones'. `coveredTop` says how far down over the canvas it reaches on a board, for a
    /// view a fit should leave clear:
    ///
    ///     registrar.hostOverlay(alignment: .top, coveredTop: { BoardPath.coveredHeight(on: $0) }) { editor, _ in
    ///         BoardPath(editor: editor)
    ///     }
    public mutating func hostOverlay<Content: View>(
        alignment: Alignment = .center, coveredTop: @escaping @MainActor (BoardID) -> CGFloat = { _ in 0 },
        @ViewBuilder _ content: @escaping @MainActor (_ editor: CanvasEditor, _ onExit: @escaping @MainActor () -> Void) -> Content
    ) {
        contribute(HostOverlay(alignment: alignment, coveredTop: coveredTop, content: { AnyView(content($0, $1)) }), to: HostOverlays.self)
    }

    /// The window's sidebar, along its canvas's leading edge, `width` how wide it is, and `keyboardEntry`
    /// the view that takes the keyboard when the window gives the sidebar the keyboard:
    ///
    ///     registrar.hostSidebar(width: PaneWidth(min: 180, ideal: 240, max: 400),
    ///                           keyboardEntry: { $0.tableOfContents?.keyboardEntry }) { editor, onExit in
    ///         TableOfContentsView(editor: editor, onExit: onExit)
    ///     }
    public mutating func hostSidebar<Content: View>(
        width: PaneWidth = .standard, keyboardEntry: (@MainActor (CanvasEditor) -> NSView?)? = nil,
        @ViewBuilder _ content: @escaping @MainActor (_ editor: CanvasEditor, _ onExit: @escaping @MainActor () -> Void) -> Content
    ) {
        contribute(HostSidebar(width: width, keyboardEntry: keyboardEntry, content: { AnyView(content($0, $1)) }), to: HostSidebars.self)
    }

    /// The window's inspector, along its canvas's trailing edge. `width` says how wide it is (as the
    /// sidebar's), `shownWhile` when it has something to show (read in a view's body:
    /// observable state; always, by default), `isRequested` when it's wanted whether or not it's shown,
    /// and `onDismiss` ends what wanted it, when the person hides the inspector meanwhile, and
    /// `keyboardEntry` the view that takes the keyboard when the window gives the inspector the keyboard:
    ///
    ///     registrar.hostInspector(shownWhile: { !$0.selectedShapeIDs.isEmpty },
    ///                             isRequested: { $0.registry.activeDetailTakeover(in: $0) != nil },
    ///                             onDismiss: { $0.registry.activeDetailTakeover(in: $0)?.onEscape($0) }) { editor, onExit in
    ///         DetailPanelView(editor: editor, onExit: onExit)
    ///     }
    public mutating func hostInspector<Content: View>(
        width: PaneWidth = .standard, shownWhile: @escaping @MainActor (CanvasEditor) -> Bool = { _ in true },
        isRequested: @escaping @MainActor (CanvasEditor) -> Bool = { _ in false }, onDismiss: @escaping @MainActor (CanvasEditor) -> Void = { _ in },
        keyboardEntry: (@MainActor (CanvasEditor) -> NSView?)? = nil,
        @ViewBuilder _ content: @escaping @MainActor (_ editor: CanvasEditor, _ onExit: @escaping @MainActor () -> Void) -> Content
    ) {
        contribute(HostInspector(width: width, shownWhile: shownWhile, isRequested: isRequested, onDismiss: onDismiss, keyboardEntry: keyboardEntry,
                                 content: { AnyView(content($0, $1)) }), to: HostInspectors.self)
    }

    /// What the window's subtitle says of the board shown, nil for none:
    ///
    ///     registrar.windowSubtitle { $0.boardCrumbs?.crumbs.last?.title }
    public mutating func windowSubtitle(_ subtitle: @escaping @MainActor (CanvasEditor) -> String?) {
        contribute(subtitle, to: WindowSubtitles.self)
    }

    /// A pane of the app's Settings window, called `title`, its view made each time the window opens:
    ///
    ///     registrar.settingsPane("Anthropic") { AnthropicSettingsView(keys: keys) }
    public mutating func settingsPane<Content: View>(_ title: String, @ViewBuilder _ content: @escaping @MainActor () -> Content) {
        contribute(SettingsPane(title: title, content: { AnyView(content()) }), to: SettingsPanes.self)
    }

    /// What the toolbar says of each tool, given the tool and the registry:
    ///
    ///     registrar.toolTips { tool, registry in registry.help(for: tool) }
    public mutating func toolTips(_ tip: @escaping @MainActor (ToolDescriptor, Registry) -> String) {
        contribute(tip, to: ToolTips.self)
    }

    /// The rows the Keyboard Shortcuts window lists from what's registered, read off the frozen
    /// registry when the window opens:
    ///
    ///     registrar.keyboardHelp { registry in registry.keyboardHelpRows }
    public mutating func keyboardHelp(_ rows: @escaping @MainActor (Registry) -> [KeyboardHelpRow]) {
        contribute(rows, to: KeyboardHelp.self)
    }

    /// A key no plugin registers, for the Keyboard Shortcuts window: said beside the code that reads
    /// it, `keys` as they're written and `title` what they do:
    ///
    ///     registrar.keyHint("⌥ Drag", "Drag a Copy", while: .pointer)
    public mutating func keyHint(_ keys: String, _ title: String, while place: KeyHintPlace) {
        contribute(KeyboardHelpRow(keys: [keys], title: title, place: place == .pointer ? .pointer : .text), to: KeyHints.self)
    }

    /// The keys that run each command, given the command and the registry, the one a menu item shows
    /// first, none for a command with none:
    ///
    ///     registrar.menuKeys { command, registry in
    ///         registry.shortcuts.filter { $0.commands.contains(command) }.map(\.chord.menuKey)
    ///     }
    public mutating func menuKeys(_ keys: @escaping @MainActor (CanvasCommand, Registry) -> [MenuKey]) {
        contribute(keys, to: MenuKeys.self)
    }

    /// What Edit › Copy as Image draws: `shapes`, those of the board shown a picture of the selection
    /// (or of the board, with nothing selected) shows, none for nothing to draw; `isAvailable` says
    /// whether there are any, and is asked as the item is validated:
    ///
    ///     registrar.imageSource(isAvailable: { $0.canCopyAsImage }) { $0.imageShapes() }
    public mutating func imageSource(isAvailable: @escaping @MainActor (CanvasEditor) -> Bool,
                                     _ shapes: @escaping @MainActor (CanvasEditor) -> [ShapeID]) {
        contribute(ImageSource(isAvailable: isAvailable, content: shapes), to: ImageSources.self)
    }

    /// The commands the app's command server runs: `specs`, what the command line shows of each,
    /// and `run`, one by name with its params, on a board's editor (nil for a command about the app
    /// as a whole), answering when it's done. Both are handed the frozen registry:
    ///
    ///     registrar.hostCommands(specs: { $0.automationCommands }) { registry, name, params, editor async throws(RPCError) in
    ///         try await registry.runAutomationCommand(name, params: params, editor: editor)
    ///     }
    public mutating func hostCommands(
        specs: @escaping @MainActor (Registry) -> [CommandSpec],
        run: @escaping @MainActor (_ registry: Registry, _ name: String, _ params: JSON, _ editor: CanvasEditor?) async throws(RPCError) -> JSON
    ) {
        contribute(HostCommandLine(specs: specs, run: run), to: HostCommands.self)
    }
}

// MARK: Reading them (the host's side)

extension Registry {
    /// The views over the canvas, in plugin order: the first under the rest.
    public var hostOverlays: [HostOverlay] { contributions(to: HostOverlays.self).map(\.value) }

    /// How far down over the canvas the views over it reach on a board, in view points: the most
    /// any says. What the window tells the editor a fit leaves clear (`coveredTop`).
    public func hostCoveredTop(on board: BoardID) -> CGFloat {
        hostOverlays.reduce(0) { max($0, $1.coveredTop(board)) }
    }

    /// The sidebar, if a plugin gives one.
    public var hostSidebar: HostSidebar? { contributions(to: HostSidebars.self).first?.value }

    /// The inspector, if a plugin gives one.
    public var hostInspector: HostInspector? { contributions(to: HostInspectors.self).first?.value }

    /// What the window's subtitle says for an editor, nil for none (and where no plugin says one,
    /// reading nothing: whoever reads it observed is never told again).
    public func windowSubtitle(for editor: CanvasEditor) -> String? {
        contributions(to: WindowSubtitles.self).first?.value(editor)
    }

    /// The Settings window's panes, in plugin order.
    public var settingsPanes: [SettingsPane] { contributions(to: SettingsPanes.self).map(\.value) }

    /// A tool's tip in the toolbar: what a plugin says of it, else its label.
    public func toolTip(for tool: ToolDescriptor) -> String {
        contributions(to: ToolTips.self).first?.value(tool, self) ?? tool.label
    }

    /// Every row of the Keyboard Shortcuts window that comes from the plugins: what the plugin that
    /// keeps the keys lists, then the hints, each row once.
    public var keyboardHelp: [KeyboardHelpRow] {
        let registered = contributions(to: KeyboardHelp.self).first?.value(self) ?? []
        var seen = Set<KeyboardHelpRow>()
        return (registered + contributions(to: KeyHints.self).map(\.value)).filter { seen.insert($0).inserted }
    }

    /// The key a menu item shows for a command, if the plugin that keeps the keys gives it one: the first
    /// of `menuKeys(of:)`.
    public func menuKey(of command: CanvasCommand) -> MenuKey? { menuKeys(of: command).first }

    /// Every key that runs a command, as the plugin that keeps the keys gives them, the one its items show
    /// first; none without that plugin.
    public func menuKeys(of command: CanvasCommand) -> [MenuKey] {
        contributions(to: MenuKeys.self).first?.value(command, self) ?? []
    }

    /// Every command with an item in the menu bar (`registrar.command(… in: …)`), in plugin order: the
    /// menu bar's part the plugins make, which the window arranges with its own items, section by section.
    public var menuBarCommands: [MenuBarCommand] {
        commandTable.inOrder.compactMap { registration in
            registration.section.map { section in
                MenuBarCommand(command: registration.command, title: registration.title, section: section, placement: registration.placement,
                               key: menuKey(of: registration.command))
            }
        }
    }

    /// What Copy as Image draws, if a plugin says.
    public var imageSource: ImageSource? { contributions(to: ImageSources.self).first?.value }

    /// The commands a plugin gives the app's command server: what the command line shows of each,
    /// and how to run one, by name, on a board's editor (nil for a command about the app as a
    /// whole), answering when it's done: at once for most, later for one that waits. None, and
    /// every name unknown, where no plugin gives any.
    public var hostCommands: (specs: [CommandSpec], run: @MainActor (_ name: String, _ params: JSON, _ editor: CanvasEditor?) async throws(RPCError) -> JSON) {
        guard let line = contributions(to: HostCommands.self).first?.value else {
            return ([], { name, _, _ async throws(RPCError) in
                throw RPCError(RPCError.methodNotFound, reason: "unknown_command", "There's no command \(name).",
                               hint: "`\(RPC.commandName) help` lists the commands.")
            })
        }
        return (line.specs(self), { name, params, editor async throws(RPCError) in try await line.run(self, name, params, editor) })
    }
}

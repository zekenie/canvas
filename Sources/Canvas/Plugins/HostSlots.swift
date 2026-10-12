import CanvasRPC
import CoreGraphics
import SwiftUI

// Host slots: what a board's window puts around its canvas, and what the app takes from the plugins
// besides, said by the plugins whose views and words they are, and placed by the host, which knows
// no plugin. A plugin can't import the window (CanvasUI) or the app, and neither can import a
// plugin, so what passes between them is declared here, beneath both: views over the canvas, the
// inspector beside it, the window's subtitle, the panes of the Settings window, the toolbar's tool
// tips and the commands the app's command server runs.
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

// MARK: The inspector

/// The view a window shows beside its canvas, in its inspector (the detail panel). At most one: two
/// are `RegistryError.conflict` at startup. Without one the window has no inspector.
public enum HostInspectors {}

extension HostInspectors: KeyedExtensionPoint {
    public typealias Contribution = HostInspector
    public static var owner: PluginID { .core }
    public static func uniqueKeys(of _: HostInspector, for _: ShapeTarget) -> [AnyHashable] { ["inspector"] }
    public static func summary(of _: HostInspector, for _: ShapeTarget) -> String { "host inspector" }
}

/// What `HostInspectors` stores: the inspector's view, when it's wanted whether or not the person
/// has it shown, and what hiding it meanwhile does. Only the sugar makes one.
///
/// The window keeps the rule, for whatever is wanted: wanted while hidden, it's shown; no longer
/// wanted, it's hidden again if that's what showed it; and hidden by the person while wanted, it's
/// dismissed (`onDismiss`), and the keyboard goes back to the canvas.
@MainActor
public struct HostInspector {
    /// Whether the inspector is wanted now. Read in a view's body, so it reads observable state.
    public let isRequested: @MainActor (CanvasEditor) -> Bool
    /// The person hid the inspector while it was wanted: end what wanted it.
    public let onDismiss: @MainActor (CanvasEditor) -> Void
    let content: @MainActor (CanvasEditor, @escaping @MainActor () -> Void) -> AnyView

    /// The view, for a window's inspector.
    public func view(for editor: CanvasEditor, onExit: @escaping @MainActor () -> Void) -> AnyView { content(editor, onExit) }
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

    /// The window's inspector. `isRequested` says when it's wanted whether or not it's shown (read
    /// in a view's body: observable state), and `onDismiss` ends what wanted it, when the person
    /// hides the inspector meanwhile:
    ///
    ///     registrar.hostInspector(isRequested: { $0.registry.activeDetailTakeover(in: $0) != nil },
    ///                             onDismiss: { $0.registry.activeDetailTakeover(in: $0)?.onEscape($0) }) { editor, onExit in
    ///         DetailPanelView(editor: editor, onExit: onExit)
    ///     }
    public mutating func hostInspector<Content: View>(
        isRequested: @escaping @MainActor (CanvasEditor) -> Bool = { _ in false }, onDismiss: @escaping @MainActor (CanvasEditor) -> Void = { _ in },
        @ViewBuilder _ content: @escaping @MainActor (_ editor: CanvasEditor, _ onExit: @escaping @MainActor () -> Void) -> Content
    ) {
        contribute(HostInspector(isRequested: isRequested, onDismiss: onDismiss, content: { AnyView(content($0, $1)) }), to: HostInspectors.self)
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

import Canvas

/// Keyboard shortcuts, as a plugin: every key the canvas answers is registered here, by the plugin
/// that gives it its meaning, one shortcut per chord. A tool's letter switches to the tool, a
/// command's keys run the command (as its menu item does), and any other shortcut does what its
/// plugin says. The core never learns what a key does: it hands each key pressed on the canvas to
/// the plugin that claims key strokes, this one.
extension PluginID {
    public static let keyboard: PluginID = "keyboard"
}

// MARK: The extension point

/// Every keyboard shortcut. Keyed by chord: two shortcuts for one chord (whatever the letter's case)
/// are `RegistryError.conflict` at startup, so plugin order never picks what a key does.
public enum KeyboardShortcuts {}

extension KeyboardShortcuts: KeyedExtensionPoint {
    public typealias Contribution = Shortcut
    public static var owner: PluginID { .keyboard }

    public static func uniqueKeys(of shortcut: Shortcut, for _: ShapeTarget) -> [AnyHashable] { [ChordKey(chord: shortcut.chord)] }

    public static func summary(of shortcut: Shortcut, for _: ShapeTarget) -> String { "shortcut \(shortcut.chord) → \(shortcut.action)" }

    /// A shortcut's tool must be registered, and its command claimed: a key that would do nothing
    /// is a mistake.
    public static func check(_ registry: Registry) throws(RegistryError) {
        let tools = Set(registry.tools.map(\.id))
        for shortcut in registry.shortcuts {
            switch shortcut.action {
            case .tool(let id) where !tools.contains(id):
                throw .invalid(point: "KeyboardShortcuts", reason: "\(shortcut.chord) switches to tool \(id), which no plugin registers")
            case .command(let command) where !registry.claims(command):
                throw .invalid(point: "KeyboardShortcuts", reason: "\(shortcut.chord) runs command \(command), which no plugin claims")
            default:
                break
            }
        }
    }
}

/// A chord, as the key a shortcut claims: "shortcut ⌘A" in a conflict.
struct ChordKey: Hashable, CustomStringConvertible {
    let chord: KeyChord
    var description: String { "shortcut \(chord)" }
}

/// A key and what it does, as `KeyboardShortcuts` stores it. Only the sugar below makes one.
public struct Shortcut {
    public let chord: KeyChord
    let effect: Effect

    enum Effect {
        case tool(ToolID)
        case command(CanvasCommand, repeats: Bool)
        case custom(title: String, when: @MainActor (CanvasEditor) -> Bool, repeats: Bool, perform: @MainActor (CanvasEditor) -> Void)
    }

    /// What it does, by name: for the report, tooltips and tests.
    public var action: Action {
        switch effect {
        case .tool(let id): .tool(id)
        case .command(let command, _): .command(command)
        case .custom(let title, _, _, _): .custom(title)
        }
    }

    public enum Action: Hashable, Sendable, CustomStringConvertible {
        /// Switches to the tool.
        case tool(ToolID)
        /// Runs the command, as the menu item that sends it does.
        case command(CanvasCommand)
        /// Does what its plugin says; the title names it ("Cancel").
        case custom(String)

        public var description: String {
            switch self {
            case .tool(let id): "tool \(id)"
            case .command(let command): "command \(command)"
            case .custom(let title): title
            }
        }
    }
}

extension Shortcut {
    /// Whether it takes the key now: a command's while it can run (`editor.canPerform`, as its menu
    /// item is enabled), a custom shortcut's while its `when` holds, a tool's always.
    @MainActor func applies(in editor: CanvasEditor) -> Bool {
        switch effect {
        case .tool: true
        case .command(let command, _): editor.canPerform(command)
        case .custom(_, let when, _, _): when(editor)
        }
    }

    /// Whether a held key's repeats run it again: only a command's or a custom shortcut's that asks
    /// (⌘Z undoes again and again, as a menu's key does).
    var repeats: Bool {
        switch effect {
        case .tool: false
        case .command(_, let repeats), .custom(_, _, let repeats, _): repeats
        }
    }

    @MainActor func run(in editor: CanvasEditor) {
        switch effect {
        case .tool(let id): editor.setTool(id)
        case .command(let command, _): editor.perform(command)
        case .custom(_, _, _, let perform): perform(editor)
        }
    }
}

// MARK: Sugar (what plugins write)

extension PluginRegistrar {
    /// A key that switches to a tool: any plugin's, the core's Hand included.
    public mutating func shortcut(_ chord: KeyChord, forTool tool: ToolID) {
        contribute(Shortcut(chord: chord, effect: .tool(tool)), to: KeyboardShortcuts.self)
    }

    /// A key that does something. `perform` runs when `chord` is pressed on the canvas and `when`
    /// holds; when it doesn't, the key goes on as if there were no shortcut for it. A held key's
    /// repeats run it again only with `repeats`. `title` names it in a few words ("Cancel").
    public mutating func shortcut(_ chord: KeyChord, _ title: String, when: @escaping @MainActor (CanvasEditor) -> Bool = { _ in true },
                                  repeats: Bool = false, perform: @escaping @MainActor (CanvasEditor) -> Void) {
        contribute(Shortcut(chord: chord, effect: .custom(title: title, when: when, repeats: repeats, perform: perform)), to: KeyboardShortcuts.self)
    }

    /// A key that runs a command another plugin (or the core) claims, as its menu item does: the
    /// core's undo and redo, say. While the command can't run, the key goes on as if there were no
    /// shortcut. A held key's repeats run it again only with `repeats`.
    public mutating func shortcut(_ chord: KeyChord, forCommand command: CanvasCommand, repeats: Bool = false) {
        contribute(Shortcut(chord: chord, effect: .command(command, repeats: repeats)), to: KeyboardShortcuts.self)
    }

    /// A toolbar tool (`tool(_:_:)`), and the key that switches to it.
    public mutating func tool(_ descriptor: ToolDescriptor, shortcut: KeyChord, _ make: @escaping @MainActor (CanvasEditor) -> any Tool) {
        tool(descriptor, make)
        self.shortcut(shortcut, forTool: descriptor.id)
    }

    /// A command (`command(_:isEnabled:_:)`: what a menu item such as Edit › Delete runs) and the
    /// keys that run it on the canvas, so the menu and the keys do one thing. While `isEnabled`
    /// doesn't hold, the menu item is dimmed and its keys go on as if there were no shortcut.
    public mutating func command(_ command: CanvasCommand, shortcuts: [KeyChord], isEnabled: @escaping @MainActor (CanvasEditor) -> Bool = { _ in true },
                                 _ run: @escaping @MainActor (CanvasEditor) -> Void) {
        self.command(command, isEnabled: isEnabled, run)
        for chord in shortcuts {
            contribute(Shortcut(chord: chord, effect: .command(command, repeats: false)), to: KeyboardShortcuts.self)
        }
    }
}

extension ShapeRegistrar {
    /// A toolbar tool that places this shape (`tool(_:label:systemImage:placing:)`), and the key
    /// that switches to it.
    public mutating func tool(_ id: ToolID? = nil, label: String, systemImage: String, shortcut: KeyChord, placing placement: Placement) {
        tool(id, label: label, systemImage: systemImage, placing: placement)
        contribute(Shortcut(chord: shortcut, effect: .tool(id ?? ToolID(placing: kind))), to: KeyboardShortcuts.self)
    }
}

// MARK: Reading them

extension Registry {
    /// Every keyboard shortcut, in plugin order.
    public var shortcuts: [Shortcut] { contributions(to: KeyboardShortcuts.self).map(\.value) }

    /// The shortcut that switches to a tool (the first, if it has several).
    public func shortcut(forTool id: ToolID) -> Shortcut? { shortcuts.first { $0.action == .tool(id) } }

    /// A toolbar tool's tooltip: its label, and the key that switches to it: "Note (N)".
    public func help(for tool: ToolDescriptor) -> String {
        shortcut(forTool: tool.id).map { "\(tool.label) (\($0.chord))" } ?? tool.label
    }
}

/// Per editor: the shortcuts by chord, gathered once (the registry is frozen), and what a key pressed
/// on the canvas does.
@MainActor
final class KeyboardState {
    private unowned let editor: CanvasEditor
    private let shortcuts: [KeyChord: Shortcut]

    init(editor: CanvasEditor) {
        self.editor = editor
        shortcuts = Dictionary(editor.registry.shortcuts.map { ($0.chord, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// A key pressed on the canvas: of the chords it answers to (`KeyChord.answers`), the first
    /// whose shortcut applies runs it, once per press. False if none does, so the key goes on.
    func handle(_ stroke: KeyStroke) -> Bool {
        guard let chord = KeyChord(stroke) else { return false }
        for candidate in chord.answers {
            guard let shortcut = shortcuts[candidate], shortcut.applies(in: editor) else { continue }
            if !stroke.isRepeat || shortcut.repeats { shortcut.run(in: editor) }
            return true
        }
        return false
    }
}

extension KeyboardState: EditorService {}

// MARK: The plugin

/// Claims key strokes, and gives the core's own actions their keys: H for the Hand, Escape (⌘.
/// too, as anywhere on the Mac) to cancel, and ⌘Z and ⇧⌘Z to undo and redo (held, again and again).
public struct KeyboardPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .keyboard }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { KeyboardState(editor: $0) }
        registrar.keyStrokes { editor, stroke in editor.service(KeyboardState.self)?.handle(stroke) ?? false }
        registrar.shortcut("h", forTool: .hand)
        registrar.shortcut(.escape, "Cancel") { $0.cancel() }
        registrar.shortcut(KeyChord(".", .command), "Cancel") { $0.cancel() }
        registrar.shortcut(KeyChord("z", .command), forCommand: .undo, repeats: true)
        registrar.shortcut(KeyChord("z", [.command, .shift]), forCommand: .redo, repeats: true)
    }
}

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
        /// Down, `press`; up (or the canvas losing the keyboard), `release`.
        case held(title: String, press: @MainActor (CanvasEditor) -> Void, release: @MainActor (CanvasEditor) -> Void)
    }

    /// What it does, by name: for the report, tooltips and tests.
    public var action: Action {
        switch effect {
        case .tool(let id): .tool(id)
        case .command(let command, _): .command(command)
        case .custom(let title, _, _, _), .held(let title, _, _): .custom(title)
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
    /// item is enabled), a custom shortcut's while its `when` holds, a tool's while the editor takes
    /// the tool (`editor.isToolEnabled`, as its toolbar segment isn't dimmed), a held key's always.
    @MainActor func applies(in editor: CanvasEditor) -> Bool {
        switch effect {
        case .tool(let id): editor.isToolEnabled(id)
        case .held: true
        case .command(let command, _): editor.canPerform(command)
        case .custom(_, let when, _, _): when(editor)
        }
    }

    /// Whether a held key's repeats run it again: only a command's or a custom shortcut's that asks
    /// (⌘Z undoes again and again, as a menu's key does).
    var repeats: Bool {
        switch effect {
        case .tool, .held: false
        case .command(_, let repeats), .custom(_, _, let repeats, _): repeats
        }
    }

    @MainActor func run(in editor: CanvasEditor) {
        switch effect {
        case .tool(let id): editor.setTool(id)
        case .command(let command, _): editor.perform(command)
        case .custom(_, _, _, let perform), .held(_, let perform, _): perform(editor)
        }
    }
}

// MARK: Sugar (what plugins write)

extension PluginRegistrar {
    /// A key that switches to a tool: any plugin's, the core's Hand included. While the editor doesn't
    /// take the tool (`editor.isToolEnabled`: one that places shapes, on a board that can't take them), the
    /// key goes on as if there were no shortcut.
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

    /// A key that does something while it's held down: `press` runs as it goes down (its repeats are
    /// the shortcut's, and do nothing), `release` as it comes up, or as the canvas loses the keyboard or
    /// its window stops being key, where no release would reach it. `title` names it ("Pan").
    public mutating func shortcut(_ chord: KeyChord, _ title: String, whileHeld press: @escaping @MainActor (CanvasEditor) -> Void,
                                  released release: @escaping @MainActor (CanvasEditor) -> Void) {
        contribute(Shortcut(chord: chord, effect: .held(title: title, press: press, release: release)), to: KeyboardShortcuts.self)
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

    /// A command (`command(_:_:isEnabled:_:)`: what a menu item such as Edit › Delete runs, called
    /// `title`) and the keys that run it on the canvas, so the menu and the keys do one thing. While
    /// `isEnabled` doesn't hold, the menu item is dimmed and its keys go on as if there were no shortcut.
    /// `menuTitle` names the item for the step the command would take now (see the core's `command`).
    public mutating func command(_ command: CanvasCommand, _ title: String, shortcuts: [KeyChord],
                                 menuTitle: (@MainActor (CanvasEditor) -> String)? = nil,
                                 isEnabled: @escaping @MainActor (CanvasEditor) -> Bool = { _ in true },
                                 _ run: @escaping @MainActor (CanvasEditor) -> Void) {
        self.command(command, title, menuTitle: menuTitle, isEnabled: isEnabled, run)
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

    /// A toolbar tool that puts this shape down its own way (`tool(_:label:systemImage:placing:_:)`:
    /// the Frame tool, which draws its rect), and the key that switches to it.
    public mutating func tool(_ id: ToolID? = nil, label: String, systemImage: String, shortcut: KeyChord, placing placement: Placement,
                              _ make: @escaping @MainActor (CanvasEditor) -> any Tool) {
        tool(id, label: label, systemImage: systemImage, placing: placement, make)
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

    /// The shortcut that runs a command (the first, if it has several).
    public func shortcut(forCommand command: CanvasCommand) -> Shortcut? { shortcuts.first { $0.action == .command(command) } }

    /// The tooltip of a button that runs a command, as a tool's is: what it's called, and the key
    /// that runs it: "Next (⌘G)"; just the title for a command with no key.
    public func help(_ title: String, forCommand command: CanvasCommand) -> String {
        shortcut(forCommand: command).map { "\(title) (\($0.chord))" } ?? title
    }
}

// MARK: The Keyboard Shortcuts window's rows

extension Registry {
    /// Every key registered here, as the Keyboard Shortcuts window lists them (the host's slot,
    /// `registrar.keyboardHelp`): a row for each thing the keys do, named as a tool's label, a
    /// command's title (`title(of:)`) or a shortcut's own title says, in the order they were
    /// registered. Keys under one name are one row (⌘↓, Return and Enter all open the selection),
    /// filed with the command if one of them runs it, and the four arrows held with the same
    /// modifiers are written as one ("←↑→↓", "⇧←↑→↓").
    public var keyboardHelpRows: [KeyboardHelpRow] {
        var rows: [(title: String, place: KeyboardHelpRow.Place, chords: [KeyChord])] = []
        for shortcut in shortcuts {
            let title: String, place: KeyboardHelpRow.Place
            switch shortcut.action {
            case .tool(let id): (title, place) = (tools.first { $0.id == id }?.label ?? id.rawValue, .tool)
            case .command(let command): (title, place) = (self.title(of: command) ?? command.rawValue, .command(command))
            case .custom(let name): (title, place) = (name, .canvas)
            }
            if let index = rows.firstIndex(where: { $0.title == title }) {
                rows[index].chords.append(shortcut.chord)
                if case .command = place, rows[index].place == .canvas { rows[index].place = place }
            } else {
                rows.append((title, place, [shortcut.chord]))
            }
        }
        return rows.map { KeyboardHelpRow(keys: KeyChord.written($0.chords), title: $0.title, place: $0.place) }
    }
}

extension KeyChord {
    static let arrows: [KeyChord] = [.leftArrow, .upArrow, .rightArrow, .downArrow]

    /// Chords as a list of keys shows them, in order: each as menus write it, but the four arrows
    /// held with the same modifiers, which are one entry where the first of them was ("←↑→↓").
    static func written(_ chords: [KeyChord]) -> [String] {
        var written: [String] = []
        var folded: [Modifiers] = []
        for chord in chords {
            let arrows = arrows.map { KeyChord($0.key, chord.modifiers) }
            guard arrows.contains(chord), arrows.allSatisfy(chords.contains) else {
                written.append(chord.description)
                continue
            }
            if folded.contains(chord.modifiers) { continue }
            folded.append(chord.modifiers)
            written.append(String(chord.description.dropLast()) + "←↑→↓")
        }
        return written
    }
}

/// Per editor: the shortcuts by chord, gathered once (the registry is frozen), and what a key pressed
/// on the canvas does.
@MainActor
final class KeyboardState {
    private unowned let editor: CanvasEditor
    private let shortcuts: [KeyChord: Shortcut]
    /// The keys held down whose shortcuts do something while they're held, by key.
    private var held: [Character: Shortcut] = [:]
    /// The key the canvas last saw go down, until it's let go: a key's repeats run a shortcut again
    /// only for it, so a key held down elsewhere repeats on the canvas as nothing (↓ held in the
    /// table of contents, whose pick gave the canvas the keyboard, never nudges what it picked).
    private var down: Character?

    init(editor: CanvasEditor) {
        self.editor = editor
        shortcuts = Dictionary(editor.registry.shortcuts.map { ($0.chord, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// A key pressed on the canvas: of the chords it answers to (`KeyChord.answers(to:)`), the first
    /// whose shortcut applies runs it, once per press; one held down runs once until its release. A
    /// repeat runs a shortcut that `repeats` again only when the canvas saw its key go down; one of
    /// a key pressed elsewhere is taken and does nothing. False if none applies, so the key goes on.
    func handle(_ stroke: KeyStroke) -> Bool {
        let key = KeyChord(stroke)?.key
        if !stroke.isRepeat { down = key }
        let wentDownHere = !stroke.isRepeat || (key != nil && key == down)
        for candidate in KeyChord.answers(to: stroke) {
            guard let shortcut = shortcuts[candidate], shortcut.applies(in: editor) else { continue }
            if case .held = shortcut.effect {
                if held[candidate.key] == nil {
                    held[candidate.key] = shortcut
                    shortcut.run(in: editor)
                }
                return true
            }
            if !stroke.isRepeat || (shortcut.repeats && wentDownHere) { shortcut.run(in: editor) }
            return true
        }
        return false
    }

    /// A key let go (nil: every key), which a shortcut done while it's held hears.
    func release(_ stroke: KeyStroke?) {
        if stroke.map({ KeyChord($0)?.key == down }) ?? true { down = nil }
        let keys = stroke.map { stroke in KeyChord(stroke).map { [$0.key] } ?? [] } ?? Array(held.keys)
        for key in keys {
            guard let shortcut = held.removeValue(forKey: key), case .held(_, _, let release) = shortcut.effect else { continue }
            release(editor)
        }
    }
}

extension KeyboardState: EditorService {
    /// Nothing kept per shape, so nothing to follow to another board.
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {}
}

// MARK: The plugin

/// Claims key strokes and their releases, and gives the core's own actions their keys: H for the
/// Hand, and Space held to pan as it does whatever the tool (`editor.isHandHeld`, Figma's and
/// tldraw's), Escape (⌘. too, as anywhere on the Mac) to cancel, Q for the tool lock
/// (`editor.isToolLocked`, tldraw's), ⌘Z and ⇧⌘Z to undo and redo (held, again and again), and the
/// View menu's zoom keys: ⌘= and ⌘- (held, again and again), = and - alone the same, ⌘0 and ⇧0 for
/// Actual Size, and ⇧1 for Zoom to Fit (tldraw's, and again to go back), the number row's digits
/// whatever the layout types with them.
public struct KeyboardPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .keyboard }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { KeyboardState(editor: $0) }
        // The toolbar's tips: a tool's label and the key that switches to it ("Note (N)").
        registrar.toolTips { tool, registry in registry.help(for: tool) }
        // The Keyboard Shortcuts window's rows: every key registered here, under what it does.
        registrar.keyboardHelp { $0.keyboardHelpRows }
        registrar.keyStrokes { editor, stroke in editor.service(KeyboardState.self)?.handle(stroke) ?? false }
        registrar.keyReleases { editor, stroke in editor.service(KeyboardState.self)?.release(stroke) }
        registrar.shortcut("h", forTool: .hand)
        registrar.shortcut(.space, "Pan", whileHeld: { $0.isHandHeld = true }, released: { $0.isHandHeld = false })
        registrar.shortcut(.escape, "Cancel") { $0.cancel() }
        registrar.shortcut(KeyChord(".", .command), "Cancel") { $0.cancel() }
        registrar.shortcut(KeyChord("z", .command), forCommand: .undo, repeats: true)
        registrar.shortcut(KeyChord("z", [.command, .shift]), forCommand: .redo, repeats: true)
        registrar.shortcut("q", "Tool Lock") { $0.isToolLocked.toggle() }
        registrar.shortcut(KeyChord("=", .command), forCommand: .zoomIn, repeats: true)
        registrar.shortcut(KeyChord("-", .command), forCommand: .zoomOut, repeats: true)
        registrar.shortcut("=", forCommand: .zoomIn, repeats: true)
        registrar.shortcut("-", forCommand: .zoomOut, repeats: true)
        registrar.shortcut(KeyChord("0", .command), forCommand: .zoomToActualSize)
        registrar.shortcut(KeyChord("0", .shift), forCommand: .zoomToActualSize)
        registrar.shortcut(KeyChord("1", .shift), forCommand: .zoomToFit)
        // What the core reads of keys held with the pointer, for the Keyboard Shortcuts window: ⇧
        // keeps a drag to one axis (`TranslatingSession`), and ⌘ makes a scroll zoom (`CanvasView`).
        registrar.keyHint("⇧ Drag", "Move Along One Axis", while: .pointer)
        registrar.keyHint("⌘ Scroll", "Zoom", while: .pointer)
    }
}

import AppKit
import Boards
import Canvas
import Keyboard

/// Jump To (⌘K): a palette that goes to a shape by what it's called and where it is, as VS Code's file
/// switcher goes to a file: name a subboard, skip one, name another two levels down, then the shape,
/// and the list narrows. It looks at titles and the containment tree alone, never at contents (Find's
/// job). A feature no kind opts into, and nothing imports (as Examples/Reordering): a shape is listed
/// when it has a title (Titles), and a pick follows it as the path's crumb menus do (Boards).
/// Composition places the palette over the canvas (`JumpToPalette`).
extension PluginID {
    /// Not "jumpTo": that's the command's string.
    public static let jumpTo: PluginID = "jump-to"
}

/// How a row shows a shape beyond its kind's name and symbol: its own symbol, if the kind has one
/// per shape, and the tint it shows in. Nil for either: the kind's label's symbol, untinted.
public struct JumpToAppearance: Sendable {
    public var systemImage: String?
    public var tint: NSColor?

    public init(systemImage: String? = nil, tint: NSColor? = nil) {
        self.systemImage = systemImage
        self.tint = tint
    }
}

/// Says how a shape shows in the list (nil: by its kind's label, untinted), given the registry.
public typealias JumpToAppearanceProvider = @MainActor (AnyShapeRecord, Registry) -> JumpToAppearance?

public struct JumpToPlugin: CanvasPlugin {
    let appearance: JumpToAppearanceProvider?

    /// `appearance` is how the host colors a kind (Composition's is Mentions': one color for a kind,
    /// as the table of contents and the `@` picker show it); none: every row untinted.
    public init(appearance: JumpToAppearanceProvider? = nil) { self.appearance = appearance }
    public var id: PluginID { .jumpTo }

    public func register(into registrar: inout PluginRegistrar) {
        let appearance = appearance
        registrar.service { JumpToState(editor: $0, appearance: appearance) }
        // ⌘K and Go › Jump To…: opens the palette, or, open, asks for its keyboard again; ends editing
        // first (its edit committed), and never mid-press. It changes no document, so it leaves no
        // step of undo.
        registrar.command(.jumpTo, shortcuts: [KeyChord("k", .command)], isEnabled: { $0.session == nil }) { editor in
            editor.endEditing()
            editor.jumpTo?.open()
        }
    }
}

extension JumpToState: EditorService {
    /// Follows the commit, once the catalog is read.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        hear(changes)
    }

    /// Nothing, but for a file put in place with the switch: the catalog is the file's, kept up to
    /// date by every commit, whatever board it was on, so showing another board changes none of it.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        heardBoardChange(change)
    }
}

extension CanvasEditor {
    /// Jump To's state; nil without JumpToPlugin.
    public var jumpTo: JumpToState? { service(JumpToState.self) }
}

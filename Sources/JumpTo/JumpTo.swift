import AppKit
import Canvas
import Keyboard
import SwiftUI

/// Jump To (⌘K): a palette that goes to a shape by what it's called and where it is, as VS Code's file
/// switcher goes to a file: name a subboard, skip one, name another two levels down, then the shape,
/// and the list narrows. It looks at titles and the containment tree alone, never at contents (Find's
/// job). A feature no kind opts into, and nothing imports (as Examples/Reordering): a shape is listed
/// when it has a title (Titles), and a pick follows it as the path's crumb menus do (Boards).
/// The window places the palette over the canvas (`JumpToPalette`, in one of the host's slots).
extension PluginID {
    /// Not "jumpTo": that's the command's string.
    public static let jumpTo: PluginID = "jump-to"
}

public struct JumpToPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .jumpTo }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { JumpToState(editor: $0) }
        // ⌘K and Go › Jump To…: opens the palette, or, open, asks for its keyboard again; ends editing
        // first (its edit committed), and never mid-press. It changes no document, so it leaves no
        // step of undo.
        registrar.command(.jumpTo, "Jump To…", shortcuts: [KeyChord("k", .command)], isEnabled: { $0.session == nil }) { editor in
            editor.endEditing()
            editor.jumpTo?.open()
        }
        // The palette, over the whole canvas and whatever else is over it (the path): nothing until
        // it's open. After Boards in a list, so it's over the path.
        registrar.hostOverlay { editor, onExit in JumpToPalette(editor: editor, onExit: onExit) }
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

    /// The file's colors changed: an open palette's rows are made again, since they read each
    /// shape's tint as they are made and keep none.
    public func shapeTintsDidChange(in editor: CanvasEditor) {
        if isOpen { refreshRows() }
    }
}

extension CanvasEditor {
    /// Jump To's state; nil without JumpToPlugin.
    public var jumpTo: JumpToState? { service(JumpToState.self) }
}

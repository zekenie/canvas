import AppKit
import Canvas
import SwiftUI

/// A board's window: the app's content for it (`BoardConfiguration.content`), hosted with its
/// SwiftUI toolbar. The window's title and edited dot follow the document.
///
/// It answers the menu commands that must reach the canvas whatever has the keyboard (the
/// responder chain from a detail-panel field never passes through the canvas, but always reaches
/// this controller): zooming, showing or hiding the details and the minimap, going back, and going
/// into and out of boards (Go › Open, ⌘↓, and Enclosing Board, ⌘↑, except in text, whose caret
/// those keys move). And
/// Edit › Cut, Copy and Paste, wherever the keyboard is (the canvas, the table of contents' list, a
/// control in the panel), except in text, which takes them first: a note being edited, a field.
/// Edit › Undo and Redo are its window's (`BoardWindow`), which splits them between text and the board.
@MainActor
public final class BoardWindowController: NSWindowController {
    public init(board: BoardDocument) {
        guard let configuration = BoardDocument.configuration else { preconditionFailure("set BoardDocument.configuration before any board opens") }
        let host = NSHostingController(rootView: configuration.content(BoardWindowContent(editor: board.editor, focus: board.focus, view: board.viewState)))
        host.sceneBridgingOptions = [.toolbars]
        let window = BoardWindow(contentViewController: host)
        window.editor = board.editor
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1200, height: 800))
        super.init(window: window)
        shouldCascadeWindows = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("board windows aren't archived") }

    private var board: BoardDocument? { document as? BoardDocument }

    @objc public func zoomIn(_ sender: Any?) { board?.focus.canvas?.zoomIn(sender) }
    @objc public func zoomOut(_ sender: Any?) { board?.focus.canvas?.zoomOut(sender) }
    @objc public func zoomToActualSize(_ sender: Any?) { board?.focus.canvas?.zoomToActualSize(sender) }

    /// View › Show Inspector, or Hide Inspector.
    @objc public func toggleDetails(_ sender: Any?) { board?.viewState.showsDetails.toggle() }

    /// View › Show Minimap, or Hide Minimap.
    @objc public func toggleMinimap(_ sender: Any?) { board?.viewState.showsMinimap.toggle() }

    /// Go › Back: the command a plugin claims (Selection's, back to the previous selection).
    @objc public func goBack(_ sender: Any?) { board?.editor.perform(.goBack) }

    /// Go › Enclosing Board (⌘↑): the command a plugin claims (Boards', up to the board above).
    @objc public func enclosingBoard(_ sender: Any?) { board?.editor.perform(.enclosingBoard) }

    /// Go › Open (⌘↓): the command a plugin claims (Selection's, opening the selected shape: a
    /// subboard shows its board).
    @objc public func openSelection(_ sender: Any?) { board?.editor.perform(.openSelection) }

    // Edit › Cut, Copy and Paste: the commands a plugin claims (Clipboard's, on the selection).
    @objc public func cut(_ sender: Any?) { board?.editor.perform(.cut) }
    @objc public func copy(_ sender: Any?) { board?.editor.perform(.copy) }
    @objc public func paste(_ sender: Any?) { board?.editor.perform(.paste) }

    /// The menu items that run a command, enabled while it can run.
    private static let commands: [Selector: CanvasCommand] = [
        #selector(goBack(_:)): .goBack, #selector(enclosingBoard(_:)): .enclosingBoard, #selector(openSelection(_:)): .openSelection,
        #selector(cut(_:)): .cut, #selector(copy(_:)): .copy, #selector(paste(_:)): .paste,
    ]

    /// The items whose keys text takes (⌘↑ and ⌘↓ move its caret): off while text has the keyboard,
    /// so a disabled item leaves the key to it.
    private static let textKeys: Set<Selector> = [#selector(enclosingBoard(_:)), #selector(openSelection(_:))]

    /// The root's crumb on the path is the file's name, kept as the title is.
    public override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        if let board, board.viewState.fileName != board.displayName { board.viewState.fileName = board.displayName }
    }
}

extension BoardWindowController: NSMenuItemValidation {
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleDetails(_:)) {
            item.title = board?.viewState.showsDetails == true ? "Hide Inspector" : "Show Inspector"
        }
        if item.action == #selector(toggleMinimap(_:)) {
            item.title = board?.viewState.showsMinimap == true ? "Hide Minimap" : "Show Minimap"
        }
        if let action = item.action, Self.textKeys.contains(action), window?.firstResponder is NSText { return false }
        if let command = item.action.flatMap({ Self.commands[$0] }) { return board?.editor.canPerform(command) == true }
        return board != nil
    }
}

import AppKit
import Canvas
import SwiftUI

/// A board's window: the app's content for it (`BoardConfiguration.content`), hosted with its
/// SwiftUI toolbar. The window's title and edited dot follow the document, and its subtitle names
/// the board shown inside a subboard (`BoardConfiguration.boardName`), so windows open on one
/// file's boards can be told apart.
///
/// It answers the menu commands that must reach the canvas whatever has the keyboard (the
/// responder chain from a detail-panel field never passes through the canvas, but always reaches
/// this controller): zooming, showing or hiding the details and the minimap, going back, and going
/// into and out of boards (Go › Open Selection, ⌘↓, and Enclosing Board, ⌘↑, except in text,
/// whose caret those keys move), each dimmed while its command can't run. And
/// Edit › Cut, Copy and Paste, wherever the keyboard is (the canvas, the table of contents' list, a
/// control in the panel), except in text, which takes them first: a note being edited, a field.
/// Edit › Undo and Redo are its window's (`BoardWindow`), which splits them between text and the board.
@MainActor
public final class BoardWindowController: NSWindowController {
    public init(board: BoardDocument) {
        guard let configuration = BoardDocument.configuration else { preconditionFailure("set BoardDocument.configuration before any board opens") }
        editor = board.editor
        let host = NSHostingController(rootView: configuration.content(BoardWindowContent(editor: board.editor, focus: board.focus, view: board.viewState)))
        host.sceneBridgingOptions = [.toolbars]
        let window = BoardWindow(contentViewController: host)
        window.editor = board.editor
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1200, height: 800))
        super.init(window: window)
        shouldCascadeWindows = true
        if let name = configuration.boardName { showBoardName(name) }
    }

    private let editor: CanvasEditor

    /// The subtitle: what `name` calls the board shown, none on the root; read again, the next turn,
    /// each time something it read changes (another board shown, the board renamed), as SwiftUI
    /// would redraw a view that read it.
    private func showBoardName(_ name: @escaping @MainActor (CanvasEditor) -> String?) {
        let subtitle = withObservationTracking { name(editor) ?? "" } onChange: { [weak self] in
            // Told as it's about to change: read it once it has.
            Task { @MainActor in self?.showBoardName(name) }
        }
        if window?.subtitle != subtitle { window?.subtitle = subtitle }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("board windows aren't archived") }

    private var board: BoardDocument? { document as? BoardDocument }

    // View › Zoom In, Zoom Out, Actual Size, Zoom to Fit and Zoom to Selection, and the toolbar's zoom
    // menu: the core's commands, and Selection's (Zoom to Selection).
    @objc public func zoomIn(_ sender: Any?) { board?.editor.perform(.zoomIn) }
    @objc public func zoomOut(_ sender: Any?) { board?.editor.perform(.zoomOut) }
    @objc public func zoomToActualSize(_ sender: Any?) { board?.editor.perform(.zoomToActualSize) }
    @objc public func zoomToFit(_ sender: Any?) { board?.editor.perform(.zoomToFit) }
    @objc public func zoomToSelection(_ sender: Any?) { board?.editor.perform(.zoomToSelection) }

    /// View › Show Inspector, or Hide Inspector.
    @objc public func toggleDetails(_ sender: Any?) { board?.viewState.showsDetails.toggle() }

    /// View › Show Minimap, or Hide Minimap.
    @objc public func toggleMinimap(_ sender: Any?) { board?.viewState.showsMinimap.toggle() }

    /// Go › Back: the command a plugin claims (Selection's, back to the previous selection).
    @objc public func goBack(_ sender: Any?) { board?.editor.perform(.goBack) }

    /// Go › Enclosing Board (⌘↑): the command a plugin claims (Boards', up to the board above).
    @objc public func enclosingBoard(_ sender: Any?) { board?.editor.perform(.enclosingBoard) }

    /// Go › Open Selection (⌘↓): the command a plugin claims (Selection's, opening the selected shape: a
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
        #selector(zoomIn(_:)): .zoomIn, #selector(zoomOut(_:)): .zoomOut, #selector(zoomToActualSize(_:)): .zoomToActualSize,
        #selector(zoomToFit(_:)): .zoomToFit, #selector(zoomToSelection(_:)): .zoomToSelection,
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

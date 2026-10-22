import AppKit
@_spi(Host) import Canvas
import SwiftUI

/// A board's window: the app's content for it (`BoardConfiguration.content`), hosted with its
/// SwiftUI toolbar. The window's title and edited dot follow the document, and its subtitle names
/// the board shown inside a subboard (what a plugin gives the host's slot for it,
/// `registry.windowSubtitle(for:)`), so windows open on one file's boards can be told apart.
///
/// It runs the plugins' commands from their menu bar items, whatever has the keyboard (the responder
/// chain from a detail-panel field never passes through the canvas, but always reaches this
/// controller): one action, `runCommand:`, which reads the command off the item it's sent from and
/// knows none, and one validation, which dims the item while its command can't run, and while text
/// has the keyboard when the command runs `.whenIdle` (Go › Open Selection, ⌘↓, whose key moves the
/// caret; Arrange's items, whose keys type), and names the item for the step its command would take
/// (Go › Enclosing Group). And Edit › Cut, Copy and Paste, AppKit's own, wherever the keyboard is (the
/// canvas, the table of contents' list, a control in the panel), except in text, which takes them
/// first: the commands that answer them. Edit › Undo and Redo are its window's (`BoardWindow`), which
/// splits them between text and the board. Its own, with no command: showing or hiding the details
/// and the minimap, View › Focus Inspector (the keyboard to the inspector's list, field or control) and
/// Focus Next and Previous Pane (F6, ⇧F6: the canvas, the inspector, the toolbar, round),
/// and Edit › Copy as Image (a PNG of what a plugin says to draw, on the pasteboard).
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
        imagePasteboard = configuration.imagePasteboard
        super.init(window: window)
        shouldCascadeWindows = true
        showSubtitle()
        window.escapeToCanvas = { [weak self] in self?.escapeToCanvas() ?? false }
    }

    private let editor: CanvasEditor
    /// Where Copy as Image puts its picture (`BoardConfiguration.imagePasteboard`).
    private let imagePasteboard: NSPasteboard

    /// The subtitle: what a plugin says of the board shown (`registry.windowSubtitle(for:)`: what
    /// it's called, none on the root); read again, the next turn, each time something it read
    /// changes (another board shown, the board renamed), as SwiftUI would redraw a view that read it.
    private func showSubtitle() {
        let subtitle = withObservationTracking { editor.registry.windowSubtitle(for: editor) ?? "" } onChange: { [weak self] in
            // Told as it's about to change: read it once it has.
            Task { @MainActor in self?.showSubtitle() }
        }
        if window?.subtitle != subtitle { window?.subtitle = subtitle }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("board windows aren't archived") }

    private var board: BoardDocument? { document as? BoardDocument }

    /// A command's menu bar item (`BoardMenus`): the command it carries, on the selection, as its key does.
    @objc public func runCommand(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let command = BoardMenus.command(of: item) else { return }
        board?.editor.perform(command)
    }

    /// View › Show Inspector, or Hide Inspector.
    @objc public func toggleDetails(_ sender: Any?) { board?.viewState.showsDetails.toggle() }

    /// View › Focus Inspector (⌥⌘I): shows the inspector if it's hidden and gives it the keyboard: the view
    /// that suits (`inspectorKeyView`), which is the table of contents' list when nothing is selected,
    /// else the panel's first field or control. Escape gives the keyboard back to the canvas, as it does
    /// from anywhere in the inspector (`onExit`).
    @objc public func focusInspector(_ sender: Any?) {
        guard let board, editor.registry.hostInspector != nil else { return }
        // A shape being edited is done with, as Find and Jump To end it before they take the keyboard:
        // its editing view would stay up while the keyboard is elsewhere.
        editor.endEditing()
        if !board.viewState.showsDetails { board.viewState.showsDetails = true }
        giveInspectorTheKeyboard(retries: InspectorFocusStyle.retries)
    }

    /// The keyboard goes to the inspector's view that suits; an inspector just shown has none until
    /// SwiftUI has made its views, a turn or two on, so it tries again a few times. When it finds none
    /// at all, the inspector's hosting view takes the keyboard, where Tab enters the panel's loop:
    /// asking for the inspector never gives up silently.
    private func giveInspectorTheKeyboard(retries: Int) {
        if let view = inspectorKeyView() {
            window?.makeFirstResponder(view)
            return
        }
        guard retries > 0 else {
            if let host = window?.contentView { window?.makeFirstResponder(host) }
            return
        }
        _ = editor.scheduler.schedule(after: InspectorFocusStyle.retryDelay) { [weak self] in
            self?.giveInspectorTheKeyboard(retries: retries - 1)
        }
    }

    /// The view of the inspector that gets the keyboard: the one the panel declares it takes
    /// (`HostInspector.keyboardEntry`: the list when its overview shows, else its header's field), else
    /// by its kind: a list, table or text field if it shows one, else any other control that takes it,
    /// the topmost, left to right (with a shape selected its title field
    /// above whatever lists its tab has; with nothing, the table of contents' list). The
    /// inspector is the window's content beside the canvas, whatever it holds (the window knows no
    /// plugin's view): the views that are shown, outside the canvas and what it hosts, and not over it
    /// (the path of crumbs is a view over the canvas), that accept first responder (the scroll views a
    /// list sits in do, and aren't wanted).
    public func inspectorKeyView() -> NSView? {
        guard let content = window?.contentView, let canvas = board?.focus.canvas else { return nil }
        if let declared = editor.registry.hostInspector?.keyboardEntry?(editor), declared.window === window, !declared.isHiddenOrHasHiddenAncestor,
           declared.acceptsFirstResponder { return declared }
        var found: [(view: NSView, rank: Int, frame: CGRect)] = []
        func walk(_ view: NSView) {
            guard !view.isHidden, view !== canvas else { return }
            let frame = view.convert(view.bounds, to: nil)
            if view.acceptsFirstResponder, !(view is NSScrollView || view is NSClipView), !frame.isEmpty, !isOverCanvas(view, canvas: canvas) {
                found.append((view, view is NSTableView || view is NSTextField || view is NSText ? 0 : 1, frame))
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(content)
        // Top to bottom (a window's y runs up), then left to right.
        return found.min { ($0.rank, -$0.frame.maxY, $0.frame.minX) < ($1.rank, -$1.frame.maxY, $1.frame.minX) }?.view
    }

    // MARK: Panes

    /// The places the keyboard can be in the window, in the order F6 visits them.
    public enum Pane: Equatable { case canvas, inspector, toolbar }

    /// The panes shown now, in order: the canvas, the inspector while it is shown, the toolbar while it has
    /// a view that takes the keyboard.
    public func shownPanes() -> [Pane] {
        var panes: [Pane] = [.canvas]
        if board?.viewState.showsDetails == true, editor.registry.hostInspector != nil { panes.append(.inspector) }
        if toolbarEntry() != nil { panes.append(.toolbar) }
        return panes
    }

    /// The pane the keyboard is in; nil when it is nowhere in one (on the window itself). The canvas's is the canvas
    /// and what lies over it, what it hosts and what the window puts over it (the board path, Jump To's field); the
    /// inspector's is the rest of the window's content, its hosting view too (where Focus Inspector leaves the
    /// keyboard when the panel has nothing to take it), so F6 from there goes on round.
    public func currentPane() -> Pane? {
        guard let responder = window?.firstResponder as? NSView else { return nil }
        if let canvas = board?.focus.canvas, responder === canvas || responder.isDescendant(of: canvas) || isOverCanvas(responder, canvas: canvas) {
            return .canvas
        }
        if toolbarViews().contains(where: { responder === $0 || responder.isDescendant(of: $0) }) { return .toolbar }
        if let content = window?.contentView, responder === content || responder.isDescendant(of: content) { return .inspector }
        return nil
    }

    /// Whether a view of the window's content lies over the canvas (its middle in the canvas's frame): one the window
    /// puts over it (the board path), not the inspector beside it. Never the content view itself, which holds both.
    private func isOverCanvas(_ view: NSView, canvas: NSView) -> Bool {
        guard view !== window?.contentView else { return false }
        let frame = view.convert(view.bounds, to: nil)
        return canvas.convert(canvas.bounds, to: nil).contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// The toolbar's item views, which are in the window's frame, outside its content.
    private func toolbarViews() -> [NSView] {
        guard let toolbar = window?.toolbar, toolbar.isVisible else { return [] }
        return toolbar.items.compactMap(\.view)
    }

    /// The first view of the toolbar that takes the keyboard.
    func toolbarEntry() -> NSView? {
        func entry(in view: NSView) -> NSView? {
            guard !view.isHidden else { return nil }
            if view.acceptsFirstResponder, !(view is NSScrollView || view is NSClipView) { return view }
            for subview in view.subviews { if let found = entry(in: subview) { return found } }
            return nil
        }
        return toolbarViews().lazy.compactMap(entry(in:)).first
    }

    /// View › Focus Next Pane (F6): the keyboard to the next pane shown, round the ends.
    @objc public func focusNextPane(_ sender: Any?) { stepPane(by: 1) }

    /// View › Focus Previous Pane (⇧F6): the exact inverse.
    @objc public func focusPreviousPane(_ sender: Any?) { stepPane(by: -1) }

    private func stepPane(by delta: Int) {
        let panes = shownPanes()
        let from = currentPane().flatMap { panes.firstIndex(of: $0) } ?? (delta > 0 ? 0 : panes.count)
        focus(panes[((from + delta) % panes.count + panes.count) % panes.count])
    }

    public func focusPane(_ pane: Pane) { focus(pane) }

    private func focus(_ pane: Pane) {
        switch pane {
        case .canvas:
            board?.focus.take()
        case .inspector:
            editor.endEditing()
            giveInspectorTheKeyboard(retries: InspectorFocusStyle.retries)
        case .toolbar:
            editor.endEditing()
            if let entry = toolbarEntry() { window?.makeFirstResponder(entry) }
        }
    }

    /// Escape where nothing takes it: in the toolbar, whose controls take no text, or on the inspector's hosting view
    /// itself (Focus Inspector's last resort): the keyboard back to the canvas, the selection kept. Whether it was there.
    func escapeToCanvas() -> Bool {
        guard currentPane() == .toolbar || window?.firstResponder === window?.contentView else { return false }
        board?.focus.take()
        return true
    }

    /// View › Show Minimap, or Hide Minimap.
    @objc public func toggleMinimap(_ sender: Any?) { board?.viewState.showsMinimap.toggle() }

    // Edit › Cut, Copy and Paste, AppKit's own items, where nothing nearer took them: the commands that
    // answer them on the board (Clipboard's, on the selection).
    @objc public func cut(_ sender: Any?) { board?.editor.perform(answering: .cut) }
    @objc public func copy(_ sender: Any?) { board?.editor.perform(answering: .copy) }
    @objc public func paste(_ sender: Any?) { board?.editor.perform(answering: .paste) }

    /// Edit › Copy as Image (⇧⌘C): a PNG of what a plugin says to draw (`registry.imageSource`: the
    /// selection, or the whole board with nothing selected, as a copy would take them), drawn from the
    /// board's own file as the canvas draws it (`BoardPicture`, showing only those shapes: the file's
    /// colors, the types and what mentions name are all there to read) at `ImageCopyStyle.scale` in the
    /// window's appearance, on the pasteboard the configuration names. Dimmed while there is nothing to
    /// draw. The picture's editor reads the whole file, as opening it does.
    @objc public func copyAsImage(_ sender: Any?) {
        guard let source = editor.registry.imageSource, source.isAvailable(editor) else { return }
        let shapes = source.shapes(for: editor)
        guard !shapes.isEmpty else { return }
        let picture = BoardPicture(file: editor.file, registry: editor.registry, board: editor.board, showing: Set(shapes))
        picture.inset = ImageCopyStyle.inset
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        guard let png = picture.pngData(within: ImageCopyStyle.limit, scale: ImageCopyStyle.scale, appearance: appearance) else { return }
        imagePasteboard.clearContents()
        imagePasteboard.setData(png, forType: .png)
    }
    /// The standard actions this controller answers, for the board, by their item's action.
    private static let standard: [Selector: StandardAction] = [
        #selector(cut(_:)): .cut, #selector(copy(_:)): .copy, #selector(paste(_:)): .paste,
    ]

    /// The root board is called what the file is ("Untitled", "Plans"), kept as the title is: the
    /// editor's `rootName`, which whatever names boards reads (the root's crumb on the path).
    public override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        if let board { board.editor.nameRoot(board.displayName) }
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
        if item.action == #selector(focusInspector(_:)) { return board != nil && editor.registry.hostInspector != nil }
        if item.action == #selector(copyAsImage(_:)) { return editor.registry.imageSource?.isAvailable(editor) == true }
        if editor.editingShapeID != nil, !(window?.firstResponder is NSText), CanvasView.editMenuActions.contains(item.action) { return false }
        if let action = item.action.flatMap({ Self.standard[$0] }) { return board?.editor.canPerform(answering: action) == true }
        if item.action == #selector(runCommand(_:)), let command = BoardMenus.command(of: item) {
            // A command that waits for editing to end leaves its key to text with the keyboard (⌘↓ moves the
            // caret, `]` types): its item is off meanwhile, and a disabled item leaves the key to the text.
            if editor.registry.moment(of: command) == .whenIdle, window?.firstResponder is NSText { return false }
            // A command named for the step it would take (Enclosing Group, Enclosing Frame): its item follows.
            if let title = board?.editor.menuTitle(of: command), item.title != title { item.title = title }
            return board?.editor.canPerform(command) == true
        }
        return board != nil
    }
}

/// The window's own constants.
@MainActor
enum InspectorFocusStyle {
    /// How often View › Focus Inspector looks again for a view to give the keyboard to, and how long
    /// it waits between: an inspector it has just shown makes its views within a turn or two.
    static let retries = 30
    static let retryDelay: Duration = .milliseconds(16)
}

/// Edit › Copy as Image's picture.
@MainActor
enum ImageCopyStyle {
    /// Pixels to a point.
    static let scale: CGFloat = 2
    /// The most it covers, in points: a board bigger than this at 100% is drawn as close as fits.
    static let limit = CGSize(width: 2048, height: 2048)
    /// View points of margin around what's drawn, in all (half on each side).
    static let inset: CGFloat = 32
}

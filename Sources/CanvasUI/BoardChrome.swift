import Canvas
import SwiftUI

/// What a board's window puts around its canvas, from what the plugins gave the host's slots:
/// each view over the canvas (`registry.hostOverlays`), in plugin order, a later one over an
/// earlier; the sidebar before it (`registry.hostSidebar`), in SwiftUI's split view, shown while
/// `showsSidebar`, with the toolbar button that shows and hides it (a view in it that has the keyboard
/// as it hides gives it back to the canvas itself, as the inspector's does); and the inspector after
/// it (`registry.hostInspector`), shown by its rule (`HostInspector.isShown`: while `showsInspector`
/// and it has something to show, or while it's wanted), with the toolbar button that shows and hides
/// it. It knows no plugin: a list without the path has no path, one without a sidebar none, and one
/// without an inspector none.
///
/// Apply it to the canvas view (`CanvasRepresentable`), after its frame and toolbar, which stay the
/// app's. `onExit` must give the keyboard back to the canvas (`CanvasFocus.take`): each view is
/// handed it.
public struct BoardChrome: ViewModifier {
    let editor: CanvasEditor
    @Binding var showsSidebar: Bool
    @Binding var showsInspector: Bool
    let onExit: @MainActor () -> Void

    public init(editor: CanvasEditor, showsSidebar: Binding<Bool>, showsInspector: Binding<Bool>,
                onExit: @escaping @MainActor () -> Void) {
        self.editor = editor
        _showsSidebar = showsSidebar
        _showsInspector = showsInspector
        self.onExit = onExit
    }

    public func body(content: Content) -> some View {
        let covered = editor.registry.hostOverlays.reduce(AnyView(content)) { canvas, overlay in
            // Over the whole canvas: a view takes clicks only where it draws, the rest is the canvas's.
            AnyView(canvas.overlay(alignment: overlay.alignment) { overlay.view(for: editor, onExit: onExit) })
        }
        let inspected = inspecting(covered)
        if let sidebar = editor.registry.hostSidebar {
            // The person's column as SwiftUI's split view has it: shown, or the canvas alone (the
            // inspector isn't one of its columns).
            let columns = Binding<NavigationSplitViewVisibility>(
                get: { showsSidebar ? .all : .detailOnly },
                set: { visibility in
                    let shown = visibility != .detailOnly
                    if shown != showsSidebar { showsSidebar = shown }
                })
            NavigationSplitView(columnVisibility: columns) {
                sidebar.view(for: editor, onExit: onExit)
            } detail: {
                inspected
                    .toolbar {
                        // At the toolbar's leading end, where it stays while the sidebar is hidden.
                        ToolbarItem(placement: .navigation) {
                            Button { showsSidebar.toggle() } label: { Label(ChromeStyle.sidebarTitle, systemImage: ChromeStyle.sidebarSymbol) }
                                .help(ChromeStyle.sidebarHelp(shown: showsSidebar))
                        }
                    }
            }
        } else {
            inspected
        }
    }

    /// The canvas with the inspector after it, if a plugin gives one.
    private func inspecting(_ covered: AnyView) -> AnyView {
        guard let inspector = editor.registry.hostInspector else { return covered }
        // Read here, in the body, so the window follows what the rule reads (the selection, a takeover).
        let shown = inspector.isShown(in: editor, chosen: showsInspector)
        let canToggle = inspector.canToggle(in: editor, chosen: showsInspector)
        let presented = Binding<Bool>(
            get: { shown },
            set: { wanted in
                // The person (or AppKit, the column dragged shut) showed or hid it: as the button does.
                // SwiftUI also writes back what it was given, through a binding of an earlier body, once
                // the column has shown or hidden: against the rule as it is now, that's no change.
                guard wanted != inspector.isShown(in: editor, chosen: showsInspector) else { return }
                inspector.toggle(in: editor, chosen: &showsInspector, onExit: onExit)
            })
        return AnyView(covered
            .inspector(isPresented: presented) {
                inspector.view(for: editor, onExit: onExit)
                    .toolbar {
                        ToolbarItem {
                            Button { inspector.toggle(in: editor, chosen: &showsInspector, onExit: onExit) } label: {
                                Label(ChromeStyle.inspectorTitle, systemImage: ChromeStyle.inspectorSymbol)
                            }
                            .help(ChromeStyle.inspectorHelp(shown: shown))
                            .disabled(!canToggle)
                        }
                    }
            })
    }
}

/// The chrome's own words and symbols.
@MainActor
enum ChromeStyle {
    /// The toolbar's buttons for the sidebar and the inspector: each named as View › Show Sidebar and
    /// Show Inspector name it, its symbol, and its tooltip, which says what a click does now.
    static let sidebarTitle = "Sidebar"
    static let sidebarSymbol = "sidebar.leading"
    static func sidebarHelp(shown: Bool) -> String { shown ? "Hide Sidebar" : "Show Sidebar" }
    static let inspectorTitle = "Inspector"
    static let inspectorSymbol = "sidebar.trailing"
    static func inspectorHelp(shown: Bool) -> String { shown ? "Hide Inspector" : "Show Inspector" }
}

/// The inspector's rule, which the window keeps (its toolbar button, and the View menu's items through
/// `BoardWindowController`), for whatever the inspector shows.
extension HostInspector {
    /// Whether the window shows the inspector: while something wants it (Find, over the panel), and
    /// otherwise while the person has it shown (`chosen`, the window's `showsDetails`) and it has
    /// something to show (`shownWhile`: a shape selected). Read in a view's body, so the window follows
    /// what it reads.
    public func isShown(in editor: CanvasEditor, chosen: Bool) -> Bool {
        isRequested(editor) || (chosen && shownWhile(editor))
    }

    /// Whether the person can show or hide it now (its toolbar button, View › Show Inspector, Focus
    /// Inspector): while it shows, or while it has something to show. With nothing to show, showing it
    /// would show nothing.
    public func canToggle(in editor: CanvasEditor, chosen: Bool) -> Bool {
        isShown(in: editor, chosen: chosen) || shownWhile(editor)
    }

    /// Hides it while it shows, and shows it otherwise, as the person asks: hidden, the person's choice
    /// is to hide it, and what wanted it is dismissed (it would go on with nothing shown to end it by),
    /// the keyboard back to the canvas (`onExit`); shown, the person's choice is to show it.
    public func toggle(in editor: CanvasEditor, chosen: inout Bool, onExit: @MainActor () -> Void) {
        guard isShown(in: editor, chosen: chosen) else {
            chosen = true
            return
        }
        chosen = false
        guard isRequested(editor) else { return }
        onDismiss(editor)
        onExit()
    }
}

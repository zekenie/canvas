import Canvas
import HostSlots
import SwiftUI

/// What a board's window puts around its canvas, from what the plugins gave the host's slots
/// (HostSlots): each view over the canvas (`registry.hostOverlays`), in plugin order, a later one
/// over an earlier, and the inspector (`registry.hostInspector`), shown while `showsInspector`,
/// with the toolbar button that hides it. It knows no plugin: a list without the path has no path,
/// and one without an inspector has none.
///
/// Apply it to the canvas view (`CanvasRepresentable`), after its frame and toolbar, which stay the
/// app's. `onExit` must give the keyboard back to the canvas (`CanvasFocus.take`): each view is
/// handed it.
public struct BoardChrome: ViewModifier {
    let editor: CanvasEditor
    @Binding var showsInspector: Bool
    let onExit: @MainActor () -> Void

    public init(editor: CanvasEditor, showsInspector: Binding<Bool>, onExit: @escaping @MainActor () -> Void) {
        self.editor = editor
        _showsInspector = showsInspector
        self.onExit = onExit
    }

    public func body(content: Content) -> some View {
        let covered = editor.registry.hostOverlays.reduce(AnyView(content)) { canvas, overlay in
            // Over the whole canvas: a view takes clicks only where it draws, the rest is the canvas's.
            AnyView(canvas.overlay(alignment: overlay.alignment) { overlay.view(for: editor, onExit: onExit) })
        }
        if let inspector = editor.registry.hostInspector {
            covered
                .inspector(isPresented: $showsInspector) {
                    inspector.view(for: editor, onExit: onExit)
                        .toolbar {
                            ToolbarItem {
                                Button { showsInspector.toggle() } label: { Label(ChromeStyle.inspectorTitle, systemImage: ChromeStyle.inspectorSymbol) }
                                    .help(ChromeStyle.inspectorHelp(shown: showsInspector))
                            }
                        }
                }
                .modifier(InspectorRequests(editor: editor, inspector: inspector, showsInspector: $showsInspector, onExit: onExit))
        } else {
            covered
        }
    }
}

/// The chrome's own words and symbols.
@MainActor
enum ChromeStyle {
    /// The inspector's toolbar button: named as View › Show Inspector names it, its symbol, and its
    /// tooltip, which says what a click does now.
    static let inspectorTitle = "Inspector"
    static let inspectorSymbol = "sidebar.trailing"
    static func inspectorHelp(shown: Bool) -> String { shown ? "Hide Inspector" : "Show Inspector" }
}

/// The inspector follows what wants it (`HostInspector.isRequested`: the detail panel's, while
/// something has taken it over, as Find does while it's open): wanted while hidden, it's shown;
/// no longer wanted, it's hidden again if that's what showed it (`revealed`), and left as the person
/// had it otherwise. What wants it lives in the inspector, so hiding the inspector meanwhile
/// dismisses it (it would go on with nothing shown to end it by), the keyboard back to the canvas.
private struct InspectorRequests: ViewModifier {
    let editor: CanvasEditor
    let inspector: HostInspector
    @Binding var showsInspector: Bool
    let onExit: @MainActor () -> Void
    /// The inspector was hidden when it was last wanted, and shown for that.
    @State private var revealed = false

    func body(content: Content) -> some View {
        content
            .onChange(of: inspector.isRequested(editor)) { _, requested in
                if requested {
                    guard !showsInspector else { return }
                    revealed = true
                    showsInspector = true
                } else if revealed {
                    revealed = false
                    showsInspector = false
                }
            }
            .onChange(of: showsInspector) { _, shown in
                guard !shown, inspector.isRequested(editor) else { return }
                revealed = false
                inspector.onDismiss(editor)
                onExit()
            }
    }
}

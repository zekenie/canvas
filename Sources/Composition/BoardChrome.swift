import Canvas
import Find
import JumpTo
import SwiftUI

/// What the shipped app puts around a board's canvas: the path over its top middle, a palette's
/// overlay, and the inspector (the detail panel, with the button that hides it). Bindings and
/// closures only: Composition can't see CanvasUI, so the app (and CompositionTests' host) hand over
/// the canvas view itself, and the toolbar and frame stay where they place it.
struct BoardChrome: ViewModifier {
    let editor: CanvasEditor
    @Binding var showsDetails: Bool
    let rootName: String
    let onExit: @MainActor () -> Void

    func body(content: Content) -> some View {
        content
            // Only the pill takes clicks: the rest of the canvas is the canvas's.
            .overlay(alignment: .top) { ShippedPlugins.boardPath(editor: editor, rootName: rootName) }
            // Jump To's palette, drawing nothing until it's open.
            .overlay { PaletteOverlay(editor: editor, onExit: onExit) }
            .inspector(isPresented: $showsDetails) {
                ShippedPlugins.detailPanel(editor: editor, onExit: onExit, rootName: rootName)
                    .toolbar {
                        ToolbarItem {
                            // Named as View › Show Inspector names it, and saying what a click does now.
                            Button { showsDetails.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                                .help(showsDetails ? "Hide Inspector" : "Show Inspector")
                        }
                    }
            }
            .modifier(InspectorReveal(editor: editor, showsDetails: $showsDetails, onExit: onExit))
    }
}

/// Jump To's palette, over the canvas: its scrim and capsule once it's open, the keyboard back to the
/// canvas (`onExit`) as the person closes it.
private struct PaletteOverlay: View {
    let editor: CanvasEditor
    let onExit: @MainActor () -> Void
    var body: some View { JumpToPalette(editor: editor, onExit: onExit) }
}

/// Shows the inspector when Find asks (⌘F, with the inspector hidden: each ⌘F bumps its
/// `focusRequest`), and hides it again as Find closes if that's what showed it
/// (`revealedInspector`). Find lives in the inspector, so hiding the inspector closes it (its
/// highlights and ⌘G would go on with no panel to close it by), the keyboard back to the canvas.
private struct InspectorReveal: ViewModifier {
    let editor: CanvasEditor
    @Binding var showsDetails: Bool
    let onExit: @MainActor () -> Void
    func body(content: Content) -> some View {
        content
            .onChange(of: editor.find?.focusRequest ?? 0) {
                guard let find = editor.find, find.isActive, !showsDetails else { return }
                find.revealedInspector = true
                showsDetails = true
            }
            .onChange(of: editor.find?.isActive ?? false) { _, isActive in
                guard !isActive, let find = editor.find, find.revealedInspector else { return }
                find.revealedInspector = false
                showsDetails = false
            }
            .onChange(of: showsDetails) { _, shown in
                guard !shown, let find = editor.find, find.isActive else { return }
                find.revealedInspector = false
                find.close()
                onExit()
            }
    }
}

extension ShippedPlugins {
    /// The board's chrome, for the app to apply to the canvas view (`CanvasRepresentable`) in its
    /// window: the path over the top middle, the palette's overlay, and the inspector shown while
    /// `showsDetails` (the detail panel, with its toolbar button, naming the root `rootName`: the
    /// file's name). `onExit` must give the keyboard back to the canvas. The tool picker, the zoom
    /// menu and the view's frame are the app's.
    public static func boardChrome(editor: CanvasEditor, showsDetails: Binding<Bool>, rootName: String,
                                   onExit: @escaping @MainActor () -> Void) -> some ViewModifier {
        BoardChrome(editor: editor, showsDetails: showsDetails, rootName: rootName, onExit: onExit)
    }
}

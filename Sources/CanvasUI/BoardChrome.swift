import AppKit
@_spi(Host) import Canvas
import Chrome
import SwiftUI

/// What a board's window puts around its canvas, from what the plugins gave the host's slots, over a
/// canvas that fills the window, its title bar's row too, so that nothing on the board moves as any of
/// it comes or goes: the sidebar (`registry.hostSidebar`) along the canvas's leading edge and the
/// inspector (`registry.hostInspector`) along its trailing edge, each a sheet flush to the window's
/// side, top and bottom that comes in over the board and goes back out (`PaneSheet`), with its toolbar
/// button (a view in one that has the keyboard as it goes gives it back to the canvas itself); the
/// sidebar shown while `showsSidebar`, the inspector by its rule (`HostInspector.isShown`: while
/// `showsInspector` and it has something to show, or while it's wanted); and each view over the canvas
/// (`registry.hostOverlays`), in plugin order, a later one over an earlier, in the part the title bar
/// and the sheets leave clear. The editor is told what they cover (`coveredEdges`), so fits and reveals
/// land in that part, and the canvas lays out the minimap in it. It knows no plugin: a list without the
/// path has no path, one without a sidebar none, and one without an inspector none.
///
/// Apply it to the canvas view (`CanvasRepresentable`), after its frame and toolbar, which stay the
/// app's, in a window whose content runs under its title bar (`.fullSizeContentView`). `onExit` must give
/// the keyboard back to the canvas (`CanvasFocus.take`): each view is handed it. `sidebarWidth` and
/// `inspectorWidth` are how wide the person left each (nil: the slot's `PaneWidth.ideal`), which a drag of a
/// sheet's inner edge sets.
public struct BoardChrome: ViewModifier {
    let editor: CanvasEditor
    @Binding var showsSidebar: Bool
    @Binding var showsInspector: Bool
    @Binding var sidebarWidth: CGFloat?
    @Binding var inspectorWidth: CGFloat?
    let onExit: @MainActor () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(editor: CanvasEditor, showsSidebar: Binding<Bool>, showsInspector: Binding<Bool>,
                sidebarWidth: Binding<CGFloat?> = .constant(nil), inspectorWidth: Binding<CGFloat?> = .constant(nil),
                onExit: @escaping @MainActor () -> Void) {
        self.editor = editor
        _showsSidebar = showsSidebar
        _showsInspector = showsInspector
        _sidebarWidth = sidebarWidth
        _inspectorWidth = inspectorWidth
        self.onExit = onExit
    }

    public func body(content: Content) -> some View {
        // Read here, in the body, so the window follows what the inspector's rule reads (the selection, a takeover).
        let sidebar = editor.registry.hostSidebar, inspector = editor.registry.hostInspector
        let sidebarShown = sidebar != nil && showsSidebar
        let inspectorShown = inspector?.isShown(in: editor, chosen: showsInspector) ?? false
        let canToggle = inspector?.canToggle(in: editor, chosen: showsInspector) ?? false
        let left = sidebar?.width.clamped(sidebarWidth) ?? 0, right = inspector?.width.clamped(inspectorWidth) ?? 0
        content
            .ignoresSafeArea()
            .overlay {
                // A reader that keeps to the safe area reads how tall the title bar's row is (one that ignores
                // it reads none); the one in it ignores it, over the whole window: what a view here doesn't
                // draw on is the canvas's, clicks and all.
                GeometryReader { area in
                    let titleBar = area.safeAreaInsets.top
                    GeometryReader { _ in
                        let edges = CoveredEdges(top: titleBar, left: sidebarShown ? left : 0, right: inspectorShown ? right : 0)
                        ZStack {
                            overlays
                                .padding(EdgeInsets(top: edges.top, leading: edges.left, bottom: edges.bottom, trailing: edges.right))
                            // Each sheet the one view that comes and goes in its row, so it slides by its own width.
                            HStack(spacing: 0) {
                                if sidebarShown, let sidebar {
                                    PaneSheet(edge: .leading, titleBar: titleBar, width: left, range: sidebar.width, resize: { sidebarWidth = $0 }) {
                                        sidebar.view(for: editor, onExit: onExit)
                                    }
                                    .transition(reduceMotion ? .opacity : .move(edge: .leading))
                                }
                                Spacer(minLength: 0)
                            }
                            // After the sidebar: in a window too narrow for both, the inspector covers it.
                            HStack(spacing: 0) {
                                Spacer(minLength: 0)
                                if inspectorShown, let inspector {
                                    PaneSheet(edge: .trailing, titleBar: titleBar, width: right, range: inspector.width, resize: { inspectorWidth = $0 }) {
                                        inspector.view(for: editor, onExit: onExit)
                                    }
                                    .transition(reduceMotion ? .opacity : .move(edge: .trailing))
                                }
                            }
                        }
                        .animation(paneAnimation, value: sidebarShown)
                        .animation(paneAnimation, value: inspectorShown)
                        .onChange(of: edges, initial: true) { _, edges in editor.coveredEdges = edges }
                    }
                    .ignoresSafeArea()
                }
            }
            .toolbar {
                if sidebar != nil {
                    // At the toolbar's leading end, over the sidebar while it shows and where it stays while it doesn't.
                    ToolbarItem(placement: .navigation) {
                        Button { showsSidebar.toggle() } label: { Label(BoardChromeStyle.sidebarTitle, systemImage: BoardChromeStyle.sidebarSymbol) }
                            .help(BoardChromeStyle.sidebarHelp(shown: showsSidebar))
                    }
                }
                if let inspector {
                    ToolbarItem(placement: .primaryAction) {
                        Button { inspector.toggle(in: editor, chosen: &showsInspector, onExit: onExit) } label: {
                            Label(BoardChromeStyle.inspectorTitle, systemImage: BoardChromeStyle.inspectorSymbol)
                        }
                        .help(BoardChromeStyle.inspectorHelp(shown: inspectorShown))
                        .disabled(!canToggle)
                    }
                }
            }
    }

    /// Each view the plugins put over the canvas, in plugin order, a later one over an earlier, where its
    /// alignment puts it in the part left clear: each takes clicks only where it draws.
    private var overlays: some View {
        editor.registry.hostOverlays.reduce(AnyView(Color.clear.allowsHitTesting(false))) { area, overlay in
            AnyView(area.overlay(alignment: overlay.alignment) { overlay.view(for: editor, onExit: onExit) })
        }
    }

    /// How a sheet comes in and goes out: sliding from its edge, or with Reduce Motion fading in place.
    private var paneAnimation: Animation {
        reduceMotion ? .easeInOut(duration: ChromeStyle.paneFade) : .easeOut(duration: ChromeStyle.paneIn)
    }
}

/// A pane along an edge of the canvas: a sheet of the chrome's tone flush to the window's side, top and
/// bottom, its top the title bar's row (the window's own buttons are over it, so its content starts
/// under it), a hairline along its inner edge with the shade the board takes beside it, and that edge a
/// grip a drag resizes it by, between its narrowest and its widest (`range`), as `resize` keeps.
struct PaneSheet<Content: View>: View {
    let edge: HorizontalEdge
    let titleBar: CGFloat
    let width: CGFloat
    let range: PaneWidth
    let resize: @MainActor (CGFloat) -> Void
    @ViewBuilder let content: Content
    /// The width a drag of the grip began at, while one is under way.
    @State private var dragStart: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: titleBar)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: ChromeStyle.surface))
        // What tells the window which pane a view of it is in (`BoardWindowController.currentPane`).
        .background(PaneMarker(edge: edge))
        .background(alignment: inner) { shade }
        .overlay(alignment: inner) {
            Rectangle().fill(Color(nsColor: ChromeStyle.hairline)).frame(width: ChromeStyle.hairlineWidth)
                .allowsHitTesting(false)
        }
        .overlay(alignment: inner) { grip }
    }

    /// The edge the sheet meets the board along.
    private var inner: Alignment { edge == .leading ? .trailing : .leading }
    /// Which way is out of the sheet, onto the board.
    private var outward: CGFloat { edge == .leading ? 1 : -1 }

    /// The shade the board takes beside the sheet, fading out from its edge, as though the board went on
    /// under it.
    private var shade: some View {
        LinearGradient(colors: [Color(nsColor: ChromeStyle.shade), .clear],
                       startPoint: edge == .leading ? .leading : .trailing, endPoint: edge == .leading ? .trailing : .leading)
            .frame(width: ChromeStyle.shadeWidth)
            .offset(x: outward * ChromeStyle.shadeWidth)
            .allowsHitTesting(false)
    }

    /// The strip along the inner edge, on the hairline, that a drag resizes the sheet by.
    private var grip: some View {
        Color.clear
            .frame(width: ChromeStyle.resizeGrip)
            .contentShape(Rectangle())
            .offset(x: outward * ChromeStyle.resizeGrip / 2)
            .modifier(ResizeCursor())
            // VoiceOver's way to resize it: increment widens, decrement narrows.
            .accessibilityElement()
            .accessibilityLabel(BoardChromeStyle.edgeLabel(edge))
            .accessibilityValue(BoardChromeStyle.edgeValue(width))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: resize(range.clamped(width + BoardChromeStyle.edgeStep))
                case .decrement: resize(range.clamped(width - BoardChromeStyle.edgeStep))
                @unknown default: break
                }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStart ?? width
                    if dragStart == nil { dragStart = start }
                    resize(range.clamped(start + outward * drag.translation.width))
                }
                .onEnded { _ in dragStart = nil })
    }
}

/// The left-right resize pointer over a sheet's grip.
private struct ResizeCursor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(.columnResize)
        } else {
            content.onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
        }
    }
}

/// Behind a sheet, as large as it is: the window reads which pane a view is in from where these are
/// (`BoardWindowController.currentPane`), since the sheets lie over the canvas, not beside it. It
/// draws nothing and takes no clicks.
struct PaneMarker: NSViewRepresentable {
    let edge: HorizontalEdge
    func makeNSView(context: Context) -> PaneMarkerView { PaneMarkerView(edge: edge) }
    func updateNSView(_ view: PaneMarkerView, context: Context) { view.edge = edge }
}

/// `PaneMarker`'s view: the sidebar's sheet (`.leading`) or the inspector's (`.trailing`). Public, so a
/// test finds a pane as the window does.
public final class PaneMarkerView: NSView {
    public internal(set) var edge: HorizontalEdge
    init(edge: HorizontalEdge) {
        self.edge = edge
        super.init(frame: .zero)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The chrome's own words and symbols.
@MainActor
enum BoardChromeStyle {
    /// The toolbar's buttons for the sidebar and the inspector: each named as View › Show Sidebar and
    /// Show Inspector name it, its symbol, and its tooltip, which says what a click does now.
    static let sidebarTitle = "Sidebar"
    static let sidebarSymbol = "sidebar.leading"
    static func sidebarHelp(shown: Bool) -> String { shown ? "Hide Sidebar" : "Show Sidebar" }
    static let inspectorTitle = "Inspector"
    static let inspectorSymbol = "sidebar.trailing"
    static func inspectorHelp(shown: Bool) -> String { shown ? "Hide Inspector" : "Show Inspector" }
    /// A sheet's edge to assistive apps: named for its pane, its width its value, and how far one step of
    /// VoiceOver's increment or decrement takes it.
    static func edgeLabel(_ edge: HorizontalEdge) -> String { edge == .leading ? "Sidebar width" : "Inspector width" }
    static func edgeValue(_ width: CGFloat) -> String { "\(Int(width.rounded())) points" }
    static let edgeStep: CGFloat = 20
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

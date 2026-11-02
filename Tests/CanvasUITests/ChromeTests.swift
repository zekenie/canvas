import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Chrome
import Observation
import SwiftUI
import TestKit

// What a window puts around its canvas (`BoardChrome`), from the host's slots, with contributors of
// the tests' own: no plugin's view is here, as CanvasUI knows none. The canvas is a real one, in an
// unshown window, the chrome applied to it as the app applies it.

/// What the fixture inspector and sidebar read and are told: whether the inspector has something to
/// show, whether it's wanted, how often it was dismissed, and whether the person has it shown (the
/// app's `BoardViewState.showsDetails`); whether the sidebar shows (`showsSidebar`).
@Observable @MainActor private final class ChromeModel {
    var content = true
    var wanted = false
    var shown = true
    var sidebar = true
    var sidebarWidth: CGFloat?
    @ObservationIgnored var dismissed = 0
    @ObservationIgnored var exits = 0
    /// The title bar's row each pane's view was handed last (`PaneTitleRow`), by its marker's name.
    @ObservationIgnored var rows: [String: PaneTitleRow?] = [:]
}

/// The canvas with the chrome around it, its sidebar's and inspector's bindings the model's.
private struct ChromeHost: View {
    let editor: CanvasEditor
    @Bindable var model: ChromeModel

    var body: some View {
        CanvasRepresentable(editor: editor)
            .modifier(BoardChrome(editor: editor, showsSidebar: $model.sidebar, showsInspector: $model.shown,
                                  sidebarWidth: $model.sidebarWidth, onExit: { model.exits += 1 }))
            .transaction { $0.disablesAnimations = true }
    }
}

/// A small view a test finds in the window by its name, which tells `record` the title bar's row it's handed.
private struct Marker: NSViewRepresentable {
    let name: String
    var record: (@MainActor (PaneTitleRow?) -> Void)?
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(name)
        record?(context.environment.paneTitleRow)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { record?(context.environment.paneTitleRow) }
}

/// A marker over the canvas, 40 by 20, where it's told.
@MainActor private func overlay(_ name: String, alignment: Alignment = .center) -> Contributor {
    Contributor(id: PluginID(name.lowercased())) { $0.hostOverlay(alignment: alignment) { _, _ in Marker(name: name).frame(width: 40, height: 20) } }
}

/// An inspector with something to show while the model says, wanted while it says, which tells it
/// when it's dismissed (no longer wanted then, as a takeover escaped is).
@MainActor private func inspector(_ model: ChromeModel) -> Contributor {
    Contributor(id: "inspector") { registrar in
        registrar.hostInspector(shownWhile: { _ in model.content }, isRequested: { _ in model.wanted }, onDismiss: { _ in
            model.dismissed += 1
            model.wanted = false
        }) { _, _ in Marker(name: "Inspector") { model.rows["Inspector"] = $0 } }
    }
}

/// A sidebar, a marker filling it, which tells `model` the row it's handed.
@MainActor private func sidebar(_ model: ChromeModel? = nil) -> Contributor {
    Contributor(id: "sidebar") {
        $0.hostSidebar { _, _ in Marker(name: "Sidebar") { model?.rows["Sidebar"] = $0 }.frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
}

@MainActor private final class ChromeWindow {
    let window: NSWindow
    let model = ChromeModel()
    let editor: CanvasEditor
    private(set) var hosting: NSView!

    /// `plugins` are made for the window's model, which an inspector reads. `underTitleBar`: the window's content
    /// runs under its title bar and toolbar, as the app's does.
    init(shown: Bool = true, sidebarWidth: CGFloat? = nil, underTitleBar: Bool = false, _ plugins: (ChromeModel) -> [any CanvasPlugin]) throws {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 500), styleMask: underTitleBar ? [.titled, .fullSizeContentView] : [.titled],
                          backing: .buffered, defer: !underTitleBar)
        if underTitleBar {
            window.titlebarAppearsTransparent = true
            window.toolbar = NSToolbar(identifier: "chrome")
            window.toolbarStyle = .unified
        }
        model.shown = shown
        model.sidebarWidth = sidebarWidth
        editor = CanvasEditor(registry: try Registry(plugins: plugins(model)), file: CanvasFile(), scheduler: TaskScheduler())
        hosting = NSHostingView(rootView: ChromeHost(editor: editor, model: model))
        hosting.frame = CGRect(x: 0, y: 0, width: 1000, height: 500)
        window.contentView = hosting
        window.settle()
    }

    func marker(_ name: String) -> NSView? { hosting.descendants(NSView.self).first { $0.identifier?.rawValue == name } }
    /// Whether the window shows a marker: in it, and not hidden.
    func shows(_ name: String) -> Bool { marker(name).map { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor } ?? false }
    var canvas: CanvasView? { hosting.descendants(CanvasView.self).first }

    /// Where a view's middle is in the window's content, from its top left.
    func middle(of view: NSView) -> CGPoint {
        let frame = hosting.convert(view.bounds, from: view)
        return CGPoint(x: frame.midX, y: hosting.isFlipped ? frame.midY : hosting.bounds.height - frame.midY)
    }

    /// The person's click on the inspector's toolbar button (or View › Show Inspector).
    func toggleInspector() throws {
        try require(editor.registry.hostInspector).toggle(in: editor, chosen: &model.shown, onExit: { [model] in model.exits += 1 })
    }
}

@MainActor let chromeTests = Suite("The window's chrome", [
    test("each view a plugin gives is over the canvas where it says") {
        let w = try ChromeWindow { _ in [overlay("Top", alignment: .top), overlay("Middle")] }
        w.window.spin { w.marker("Top") != nil && w.marker("Middle") != nil }
        expectEqual(w.hosting.descendants(CanvasView.self).count, 1)
        let canvas = try require(w.canvas)
        let top = w.middle(of: try require(w.marker("Top"))), middle = w.middle(of: try require(w.marker("Middle"))), whole = w.middle(of: canvas)
        expect(abs(top.x - whole.x) < 1 && abs(top.y - 10) < 1, "at the top middle of the canvas: \(top), the canvas's middle \(whole)")
        expect(abs(middle.x - whole.x) < 1 && abs(middle.y - whole.y) < 1, "at its middle: \(middle)")
    },
    test("a list that gives no view puts nothing over the canvas, and one that gives no sidebar or inspector has neither") {
        let w = try ChromeWindow { _ in [] }
        w.window.settle()
        expectEqual(w.hosting.descendants(CanvasView.self).count, 1)
        expect(w.marker("Inspector") == nil && w.marker("Sidebar") == nil)
        expectEqual(w.hosting.descendants(NSSplitView.self).count, 0, "no split view without a sidebar or an inspector")
        w.model.wanted = true
        w.model.shown = false
        w.window.settle()
        expectEqual(w.model.dismissed, 0)
        expectEqual(w.model.exits, 0, "with no inspector, showing or hiding one is nothing")
    },
    test("a sidebar a plugin gives comes in over the canvas's leading edge at its width, and the canvas never moves") {
        let w = try ChromeWindow { _ in [sidebar()] }
        w.window.spin { w.shows("Sidebar") }
        let canvas = try require(w.canvas)
        let side = try require(w.marker("Sidebar")).convert(try require(w.marker("Sidebar")).bounds, to: nil)
        let shown = canvas.convert(canvas.bounds, to: nil)
        expectEqual(shown, w.hosting.convert(w.hosting.bounds, to: nil), "the canvas fills the window")
        expect(abs(side.minX - shown.minX) < 1 && abs(side.width - PaneWidth.standard.ideal) < 1, "over its leading edge: \(side)")
        expectEqual(w.editor.coveredEdges, CoveredEdges(left: PaneWidth.standard.ideal), "the editor told what it covers")
        w.model.sidebar = false
        w.window.spin { !w.shows("Sidebar") }
        expectEqual(canvas.convert(canvas.bounds, to: nil), shown, "hidden, the canvas is where it was")
        expectEqual(w.editor.coveredEdges, CoveredEdges())
        w.model.sidebar = true
        w.window.spin { w.shows("Sidebar") }
        expectEqual(canvas.convert(canvas.bounds, to: nil), shown)
    },
    test("a pane is as wide as the person left it, within what its slot says, and what floats centers in the part left clear") {
        let w = try ChromeWindow(sidebarWidth: 1000) { _ in [sidebar(), overlay("Top", alignment: .top)] }
        w.window.spin { w.shows("Sidebar") && w.marker("Top") != nil }
        let side = try require(w.marker("Sidebar"))
        expect(abs(side.convert(side.bounds, to: nil).width - PaneWidth.standard.max) < 1, "no wider than its widest")
        let top = w.middle(of: try require(w.marker("Top")))
        let clear = (PaneWidth.standard.max + 1000) / 2
        expect(abs(top.x - clear) < 1, "the view over the canvas in the middle of the part left clear: \(top)")
        expectEqual(PaneWidth.standard.clamped(nil), PaneWidth.standard.ideal)
        expectEqual(PaneWidth.standard.clamped(10), PaneWidth.standard.min)
    },
    test("the inspector shows while the person has it shown and it has something to show") {
        let w = try ChromeWindow { [inspector($0)] }
        w.window.spin { w.shows("Inspector") }
        w.model.content = false
        w.window.spin { !w.shows("Inspector") }
        expect(w.model.shown, "the person's choice stays")
        w.model.content = true
        w.window.spin { w.shows("Inspector") }
        w.model.shown = false
        w.window.spin { !w.shows("Inspector") }
        w.model.content = false
        w.model.content = true
        w.window.settle()
        expect(!w.shows("Inspector"), "hidden by the person, it stays hidden for something to show")
    },
    test("an inspector wanted shows whatever the person chose and whatever it has, and goes back to what they chose once it isn't") {
        let w = try ChromeWindow(shown: false) { [inspector($0)] }
        w.model.content = false
        w.window.settle()
        expect(!w.shows("Inspector"))
        w.model.wanted = true
        w.window.spin { w.shows("Inspector") }
        expect(!w.model.shown, "wanting it doesn't change the person's choice")
        w.model.wanted = false
        w.window.spin { !w.shows("Inspector") }
        expectEqual(w.model.dismissed, 0, "what wanted it ended by itself: nothing to dismiss")
        // Shown by the person, it stays as what wanted it ends.
        w.model.shown = true
        w.model.content = true
        w.window.spin { w.shows("Inspector") }
        w.model.wanted = true
        w.window.settle()
        w.model.wanted = false
        w.window.settle()
        expect(w.shows("Inspector"))
        expectEqual(w.model.exits, 0)
    },
    test("the person's toggle hides what shows, dismissing what wanted it and giving the canvas the keyboard; shows what doesn't; and has nothing to show it for with nothing to show") {
        let w = try ChromeWindow(shown: false) { [inspector($0)] }
        let rule = try require(w.editor.registry.hostInspector)
        w.model.wanted = true
        w.window.spin { w.shows("Inspector") }
        expect(rule.canToggle(in: w.editor, chosen: w.model.shown))
        try w.toggleInspector()
        expectEqual(w.model.dismissed, 1)
        expectEqual(w.model.exits, 1)
        expect(!w.model.wanted && !w.model.shown)
        w.window.spin { !w.shows("Inspector") }
        try w.toggleInspector()
        expect(w.model.shown)
        w.window.spin { w.shows("Inspector") }
        try w.toggleInspector()
        expect(!w.model.shown)
        w.window.spin { !w.shows("Inspector") }
        expectEqual(w.model.dismissed, 1, "nothing wanted it: nothing dismissed")
        w.model.content = false
        expect(!rule.canToggle(in: w.editor, chosen: w.model.shown), "nothing to show, and nothing showing")
        expect(!rule.canToggle(in: w.editor, chosen: true))
        w.model.wanted = true
        expect(rule.canToggle(in: w.editor, chosen: false), "wanted, it shows: it can be hidden")
    },
    test("a sidebar and an inspector together: over the canvas's leading and trailing edges, the canvas the whole window between and under them") {
        let w = try ChromeWindow { [sidebar($0), inspector($0)] }
        w.window.spin { w.shows("Sidebar") && w.shows("Inspector") }
        expect(w.model.rows["Sidebar"] == .some(nil) && w.model.rows["Inspector"] == .some(nil), "no title bar, no row: \(w.model.rows)")
        let canvas = try require(w.canvas).convert(try require(w.canvas).bounds, to: nil)
        let side = try require(w.marker("Sidebar")).convert(try require(w.marker("Sidebar")).bounds, to: nil)
        let panel = try require(w.marker("Inspector")).convert(try require(w.marker("Inspector")).bounds, to: nil)
        expect(abs(side.minX - canvas.minX) < 1, "the sidebar over the canvas's leading edge: \(side), the canvas \(canvas)")
        expect(abs(panel.maxX - canvas.maxX) < 1 && panel.minX > side.maxX, "the inspector over its trailing edge: \(panel)")
        expectEqual(w.editor.coveredEdges, CoveredEdges(left: side.width, right: panel.width))
        w.model.content = false
        w.window.spin { !w.shows("Inspector") }
        expectEqual(w.editor.coveredEdges, CoveredEdges(left: side.width), "the inspector gone, it covers nothing")
        expectEqual(try require(w.canvas).convert(try require(w.canvas).bounds, to: nil), canvas, "and the canvas is where it was")
    },
    test("in a window whose content runs under its title bar, the canvas and the sheets do too, each sheet handing its content the row, what floats starts under it, and the editor is told how tall it is") {
        let w = try ChromeWindow(underTitleBar: true) { [sidebar($0), inspector($0), overlay("Top", alignment: .top)] }
        w.window.spin { w.shows("Sidebar") && w.shows("Inspector") && w.marker("Top") != nil }
        let titleBar = w.hosting.safeAreaInsets.top
        expect(titleBar > 0, "the window's content runs under its title bar: \(titleBar)")
        let canvas = try require(w.canvas)
        expectEqual(canvas.convert(canvas.bounds, to: nil), w.hosting.convert(w.hosting.bounds, to: nil), "the canvas fills the window, its title bar's row too")
        expectEqual(w.editor.coveredEdges.top, titleBar, "the editor told what the title bar's row covers")
        for name in ["Sidebar", "Inspector"] {
            let marker = try require(w.marker(name)), frame = w.hosting.convert(marker.bounds, from: marker)
            let top = w.hosting.isFlipped ? frame.minY : w.hosting.bounds.height - frame.maxY
            expect(abs(top) < 1, "\(name)'s content from the window's top, its header in the title bar's row: \(top)")
        }
        // The sidebar's line starts past the traffic lights and the Sidebar button, where the window's title starts; the
        // inspector's ends before the Inspector button.
        expectEqual(w.model.rows["Sidebar"], PaneTitleRow(height: titleBar, leading: 148, trailing: 16))
        expectEqual(w.model.rows["Inspector"], PaneTitleRow(height: titleBar, leading: 16, trailing: 60))
        let top = w.middle(of: try require(w.marker("Top")))
        expect(abs(top.y - (titleBar + 10)) < 1, "what floats under it: \(top), the row \(titleBar)")
    },
])

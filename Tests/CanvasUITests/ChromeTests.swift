import AppKit
import Canvas
import CanvasTesting
import CanvasUI
import Observation
import SwiftUI
import TestKit

// What a window puts around its canvas (`BoardChrome`), from the host's slots, with contributors of
// the tests' own: no plugin's view is here, as CanvasUI knows none. The canvas is a real one, in an
// unshown window, the chrome applied to it as the app applies it.

/// What the fixture inspector reads and is told: whether it's wanted, how often it was dismissed,
/// and whether the window shows it (the app's `BoardViewState.showsDetails`).
@Observable @MainActor private final class ChromeModel {
    var wanted = false
    var shown = true
    @ObservationIgnored var dismissed = 0
    @ObservationIgnored var exits = 0
}

/// The canvas with the chrome around it, its inspector's binding the model's.
private struct ChromeHost: View {
    let editor: CanvasEditor
    @Bindable var model: ChromeModel

    var body: some View {
        CanvasRepresentable(editor: editor)
            .modifier(BoardChrome(editor: editor, showsInspector: $model.shown, onExit: { model.exits += 1 }))
            .transaction { $0.disablesAnimations = true }
    }
}

/// A small view a test finds in the window by its name.
private struct Marker: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(name)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// A marker over the canvas, 40 by 20, where it's told.
@MainActor private func overlay(_ name: String, alignment: Alignment = .center) -> Contributor {
    Contributor(id: PluginID(name.lowercased())) { $0.hostOverlay(alignment: alignment) { _, _ in Marker(name: name).frame(width: 40, height: 20) } }
}

/// An inspector that's wanted while the model says, and tells it when it's dismissed (no longer
/// wanted then, as a takeover escaped is).
@MainActor private func inspector(_ model: ChromeModel) -> Contributor {
    Contributor(id: "inspector") { registrar in
        registrar.hostInspector(isRequested: { _ in model.wanted }, onDismiss: { _ in
            model.dismissed += 1
            model.wanted = false
        }) { _, _ in Marker(name: "Inspector") }
    }
}

@MainActor private final class ChromeWindow {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
    let model = ChromeModel()
    private(set) var hosting: NSView!

    /// `plugins` are made for the window's model, which an inspector reads.
    init(shown: Bool = true, _ plugins: (ChromeModel) -> [any CanvasPlugin]) throws {
        model.shown = shown
        let editor = CanvasEditor(registry: try Registry(plugins: plugins(model)), file: CanvasFile(), scheduler: TaskScheduler())
        hosting = NSHostingView(rootView: ChromeHost(editor: editor, model: model))
        hosting.frame = CGRect(x: 0, y: 0, width: 800, height: 500)
        window.contentView = hosting
        window.settle()
    }

    func marker(_ name: String) -> NSView? { hosting.descendants(NSView.self).first { $0.identifier?.rawValue == name } }

    /// Where a view's middle is in the window's content, from its top left.
    func middle(of view: NSView) -> CGPoint {
        let frame = hosting.convert(view.bounds, from: view)
        return CGPoint(x: frame.midX, y: hosting.isFlipped ? frame.midY : hosting.bounds.height - frame.midY)
    }
}

@MainActor let chromeTests = Suite("The window's chrome", [
    test("each view a plugin gives is over the canvas where it says") {
        let w = try ChromeWindow { _ in [overlay("Top", alignment: .top), overlay("Middle")] }
        w.window.spin { w.marker("Top") != nil && w.marker("Middle") != nil }
        expectEqual(w.hosting.descendants(CanvasView.self).count, 1)
        let top = w.middle(of: try require(w.marker("Top"))), middle = w.middle(of: try require(w.marker("Middle")))
        expect(abs(top.x - 400) < 1 && abs(top.y - 10) < 1, "at the top middle of the canvas: \(top)")
        expect(abs(middle.x - 400) < 1 && abs(middle.y - 250) < 1, "at its middle: \(middle)")
    },
    test("a list that gives no view puts nothing over the canvas, and one that gives no inspector has none") {
        let w = try ChromeWindow { _ in [] }
        w.window.settle()
        expectEqual(w.hosting.descendants(CanvasView.self).count, 1)
        expect(w.marker("Inspector") == nil)
        w.model.wanted = true
        w.model.shown = false
        w.window.settle()
        expectEqual(w.model.dismissed, 0)
        expectEqual(w.model.exits, 0, "with no inspector, showing or hiding one is nothing")
    },
    test("an inspector wanted while it's hidden is shown, and hidden again once it isn't; one the person had shown stays") {
        let w = try ChromeWindow(shown: false) { [inspector($0)] }
        w.model.wanted = true
        w.window.spin { w.model.shown }
        w.model.wanted = false
        w.window.spin { !w.model.shown }
        expectEqual(w.model.dismissed, 0, "what wanted it ended by itself: nothing to dismiss")
        // Shown by the person, it stays as what wanted it ends.
        w.model.shown = true
        w.window.settle()
        w.model.wanted = true
        w.window.settle()
        w.model.wanted = false
        w.window.settle()
        expect(w.model.shown)
        expectEqual(w.model.exits, 0)
    },
    test("hiding the inspector while it's wanted dismisses what wanted it, and gives the canvas the keyboard") {
        let w = try ChromeWindow { [inspector($0)] }
        w.model.wanted = true
        w.window.settle()
        expect(w.model.shown)
        w.model.shown = false
        w.window.spin { w.model.dismissed == 1 }
        expect(!w.model.wanted)
        expectEqual(w.model.exits, 1)
        w.window.settle()
        expect(!w.model.shown, "it stays hidden")
        // Hidden with nothing wanting it, nothing is dismissed.
        w.model.shown = true
        w.window.settle()
        w.model.shown = false
        w.window.settle()
        expectEqual(w.model.dismissed, 1)
        expectEqual(w.model.exits, 1)
    },
])

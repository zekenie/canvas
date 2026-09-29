import AppKit
import Canvas
import CanvasTesting
import DetailPanel
import Selection
import SwiftUI
import TestKit

// Sections shown by what a service keeps about a shape (`shownWhile`), not by its value alone: a
// tab of the shape's state that comes and goes.

/// What a plugin keeps about shapes, beside them: which are watched, and how often it was asked.
@MainActor
final class Watchers: EditorService {
    var watched: Set<ShapeID> = []
    private(set) var asked = 0

    func isWatched(_ id: ShapeID) -> Bool {
        asked += 1
        return watched.contains(id)
    }
}

enum WatchTab {}
extension WatchTab: DetailTab {
    static var title: String { "Watch" }
    static var order: Int { 300 }
}

/// The gadget's Watch tab, shown while the gadget is watched: a field over its name.
let watchingPlugin = Contributor(id: "watching") { r in
    r.service { _ in Watchers() }
    r.details(Gadget.self) {
        DetailSection("Watching", in: WatchTab.self) { $gadget in
            TextField("Watch note", text: $gadget.name)
        }
        .shownWhile { shape, context in context.service(Watchers.self)?.isWatched(shape.id) == true }
    }
}

extension CanvasEditor {
    var watchers: Watchers? { service(Watchers.self) }
}

@MainActor let shownWhileTests = Suite("Sections shown while a service says", [
    test("shownWhile hides a section, and a tab it leaves empty, by what a service keeps; only such sections are asked") {
        let editor = try gadgetEditor([watchingPlugin])
        let watchers = try require(editor.watchers)
        let id = editor.add(Gadget(gadgetFrame))
        expect(try !editor.layout(id).tabs.contains(.of(WatchTab.self)))
        expectEqual(watchers.asked, 1)
        watchers.watched.insert(id)
        let layout = try editor.layout(id)
        expectEqual(layout.tabs.last, .of(WatchTab.self))
        expectEqual(layout.sections(in: .of(WatchTab.self)).map(\.section), ["Watching"])
        expectEqual(watchers.asked, 2)
        _ = try editor.layout(editor.add(Box(gadgetFrame)))
        expectEqual(watchers.asked, 2, "a kind without such a section asks nothing")
        watchers.watched = []
        expect(try !editor.layout(id).tabs.contains(.of(WatchTab.self)))
    },
    test("with `when` too, a section shows only while both say so") {
        let editor = try gadgetEditor([Contributor(id: "both") { r in
            r.service { _ in Watchers() }
            r.details(Gadget.self) {
                DetailSection("Watched parts", in: WatchTab.self, when: { !$0.parts.isEmpty }) { _ in Text("Parts") }
                    .shownWhile { shape, context in context.service(Watchers.self)?.isWatched(shape.id) == true }
            }
        }])
        let id = editor.add(Gadget(gadgetFrame))
        let watchers = try require(editor.watchers)
        watchers.watched.insert(id)
        expect(try !editor.layout(id).tabs.contains(.of(WatchTab.self)), "no parts")
        editor.transact { $0.update(id, as: Gadget.self) { $0.props.parts = [Gadget.Part()] } }
        expect(try editor.layout(id).tabs.contains(.of(WatchTab.self)))
        watchers.watched = []
        expect(try !editor.layout(id).tabs.contains(.of(WatchTab.self)), "not watched")
    },
    test("in a window, a commit on another shape shows and hides it, with its tab, building nothing else; a field in it hands the keyboard back as it goes") {
        let editor = try gadgetEditor([CountingPlugin(), watchingPlugin], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let watchers = try require(editor.watchers)
        let id = editor.add(Gadget(gadgetFrame, name: "cog")), other = editor.add(Box(gadgetFrame))
        let state = try require(editor.detailPanel)
        state.choose(.of(FrameTab.self), for: Gadget.kind)
        editor.selection = id
        panel.window.spin { (try? panel.field("240 pt")) != nil }
        panel.window.settle()
        countedBuilds = 0
        for x in 1...5 {
            editor.transact { $0.update(other) { $0.box?.origin.x = CGFloat(x) } }
            panel.window.settle()
        }
        expectEqual(countedBuilds, 0, "commits that don't change what it says build nothing")
        watchers.watched.insert(id)
        editor.transact { $0.update(other) { $0.box?.origin.x = 10 } }
        panel.window.settle()
        expectEqual(countedBuilds, 0, "a tab coming builds none of the current tab's sections again")
        state.choose(.of(WatchTab.self), for: Gadget.kind)
        panel.window.spin { panel.fields.contains { $0.placeholderString == "Watch note" } }
        panel.window.focus(try panel.field("cog"))
        panel.window.type("s")
        expectEqual(editor.props(id, as: Gadget.self)?.name, "s")
        watchers.watched = []
        editor.transact { $0.update(other) { $0.box?.origin.x = 11 } }
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(panel.exits, 1)
        expect(!panel.fields.contains { $0.placeholderString == "Watch note" }, "the Watch tab is gone")
        panel.window.type("g")                                  // a tool shortcut, on the canvas
        expectEqual(editor.currentToolID, ToolID(placing: Gadget.kind))
    },
    test("a status line whose text has the keyboard (selected, to copy it) hands it back to the canvas as it goes: one of a tab's lines, or a section's line swapped for another") {
        final class Lines { var count = 2 }
        let lines = Lines()
        let editor = try gadgetEditor([Contributor(id: "lines") { r in
            r.detailStatusForEveryShape(in: AlertsTab.self) { _, _ in
                (0..<lines.count).map { DetailStatus($0 == 0 ? "First line." : "Second line.", tone: .warning) }
            }
            r.details(Gadget.self) {
                DetailSection("Sync", in: AlertsTab.self) { $gadget in
                    if $gadget.name.wrappedValue == "busy" {
                        DetailStatusLine(DetailStatus("Updating"), isBusy: true)
                    } else {
                        DetailStatusLine(DetailStatus("Unusable answer", tone: .warning), actions: [DetailStatusAction("Retry") {}])
                    }
                }
            }
        }], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = editor.add(Gadget(gadgetFrame)), other = editor.add(Box(gadgetFrame))
        try require(editor.detailPanel).choose(.of(AlertsTab.self), for: Gadget.kind)
        editor.selection = id
        @MainActor func line(_ text: String) -> NSTextField? { panel.hosting.descendants(NSTextField.self).first { $0.stringValue == text } }
        /// A click in a line's text, as the window sends it: its release waits in the queue.
        @MainActor func select(_ text: String) throws {
            let field = try require(line(text), "a line saying \(text)")
            let location = field.convert(CGPoint(x: 4, y: field.bounds.midY), to: nil)
            @MainActor func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 1, windowNumber: panel.window.windowNumber,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            NSApp.postEvent(try event(.leftMouseUp), atStart: true)
            field.mouseDown(with: try event(.leftMouseDown))
            expect(panel.window.firstResponder is NSText, "its text has the keyboard")
        }
        panel.window.spin { line("Second line.") != nil }
        try select("Second line.")
        lines.count = 1
        editor.transact { $0.update(other) { $0.box?.origin.x = 1 } }
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(panel.exits, 1)
        expect(line("First line.") != nil, "the tab stays, with its other line")
        try select("Unusable answer")
        editor.transact { $0.update(id, as: Gadget.self) { $0.props.name = "busy" } }
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(panel.exits, 2)
        panel.window.type("g")                                  // a tool shortcut, on the canvas
        expectEqual(editor.currentToolID, ToolID(placing: Gadget.kind))
    },
])

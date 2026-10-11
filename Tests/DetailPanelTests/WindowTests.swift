import AppKit
import Canvas
import CanvasTesting
import CanvasUI
import DetailPanel
import Selection
import SwiftUI
import TestKit
import TextEditing

/// The panel in an NSHostingView next to a canvas view, in an unshown window (CanvasTesting drives
/// it: `spin`, `focus`, `type`). The editor keeps real time, so SwiftUI's updates and the panel's
/// hand-back land while the main run loop runs. The window is deferred, never given a place in the
/// window server, so each turn lays its views out without drawing their layers, which nothing here
/// looks at (`render()` draws the panel itself) and which took a quarter of these tests' time.
@MainActor
final class PanelWindow {
    let editor: CanvasEditor
    let window: NSWindow
    let canvas: CanvasView
    private(set) var hosting: NSView!
    /// How often the panel handed the keyboard back.
    private(set) var exits = 0

    /// `inBoardWindow`: the window is a board's, as the app's is, which splits Edit › Undo between
    /// text and the board. The panel's overview and takeovers are the editor's plugins'
    /// (`OverviewPlugin`, TakeoverTests' `TakeoverPlugin`).
    init(_ editor: CanvasEditor, panelWidth: CGFloat = DetailStyle.idealWidth, locale: Locale = Locale(identifier: "en_US"),
         inBoardWindow: Bool = false) {
        self.editor = editor
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        if inBoardWindow {
            let board = BoardWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: true)
            board.editor = editor
            window = board
        } else {
            window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: true)
        }
        canvas = CanvasView(editor: editor)
        canvas.frame = CGRect(x: 0, y: 0, width: 1000 - panelWidth, height: 700)
        // Weak: the panel may hand the keyboard back a turn after the test let this go.
        let exit: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            exits += 1
            window.makeFirstResponder(canvas)
        }
        hosting = NSHostingView(rootView: DetailPanelView(editor: editor, onExit: exit).environment(\.locale, locale))
        hosting.frame = CGRect(x: 1000 - panelWidth, y: 0, width: panelWidth, height: 700)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        root.addSubview(canvas)
        root.addSubview(hosting)
        window.contentView = root
        window.settle()
    }

    /// The panel's editable text fields, in view order.
    var fields: [NSTextField] { hosting.descendants(NSTextField.self).filter(\.isEditable) }
    var tables: [NSTableView] { hosting.descendants(NSTableView.self) }
    var textViews: [NSTextView] { hosting.descendants(NSTextView.self) }
    var steppers: [NSStepper] { hosting.descendants(NSStepper.self) }
    /// SwiftUI's toggles are untitled buttons, under the header (which has the back button).
    var checkboxes: [NSButton] { hosting.descendants(NSButton.self).filter { !($0 is NSPopUpButton) && !isInHeader($0) } }
    /// The header's back button, while there's a selection to go back to.
    var backButton: NSButton? { hosting.descendants(NSButton.self).first(where: isInHeader) }
    /// A header field (`DetailHeaderField`), in a header that renames its shape.
    var headerField: NSTextField? { hosting.descendants(NSTextField.self).first { $0.isEditable && isInHeader($0) } }
    /// In the header, the panel's top 44 points (`DetailStyle.headerHeight`).
    func isInHeader(_ view: NSView) -> Bool { view.convert(view.bounds, to: hosting).maxY <= 44 }

    func field(_ text: String) throws -> NSTextField {
        try require(fields.first { $0.stringValue == text || $0.placeholderString == text }, "no field showing \(text): \(fields.map(\.stringValue))")
    }

    var canvasHasKeyboard: Bool { window.firstResponder === canvas }

    /// The view a click at a point in `view` lands on, as the window finds it: its hit test from
    /// the top, where SwiftUI takes the clicks over what it's disabled.
    func hit(_ point: CGPoint, in view: NSView) -> NSView? {
        guard let top = window.contentView?.superview else { return nil }
        return top.hitTest(view.convert(point, to: nil))
    }

    /// A press and its release where a click at a point in `view` lands, as the window sends them
    /// (`sendEvent`'s mouse-downs don't reach views in an unshown window, so they're handed over):
    /// the keyboard first, to a view that takes it, then the press. The release waits in the queue,
    /// for a view that tracks the press until it comes (a text view's); one that doesn't is handed
    /// it after.
    func clickThroughWindow(at point: CGPoint, in view: NSView, clicks: Int = 1) throws {
        let target = try require(hit(point, in: view))
        if target.acceptsFirstResponder { window.makeFirstResponder(target) }
        time += 0.5
        let location = view.convert(point, to: nil)
        func event(_ type: NSEvent.EventType, at time: TimeInterval) throws -> NSEvent {
            try require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
        }
        NSApplication.shared.postEvent(try event(.leftMouseUp, at: time + 0.05), atStart: true)
        target.mouseDown(with: try event(.leftMouseDown, at: time))
        if let up = NSApplication.shared.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .eventTracking, dequeue: true) {
            target.mouseUp(with: up)
        }
    }

    /// The panel as the window draws it.
    func render() throws -> NSBitmapImageRep {
        let image = try require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        return image
    }

    /// A press on the canvas, at a view point: AppKit gives the canvas the keyboard first, as
    /// `NSWindow.sendEvent` does (which doesn't reach views in an unshown window).
    func click(_ point: CGPoint) {
        window.makeFirstResponder(canvas)
        time += 0.1
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: point, time: time))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: point, time: time + 0.05))
        window.settle()
    }

    private var time: TimeInterval = 1
}

/// How often a panel handed the keyboard back.
@MainActor final class HandBacks {
    var count = 0
}

/// A panel in an unshown window that has the keyboard itself, just hidden: the panel hands the
/// keyboard back on the scheduler's next turn, through `onExit`.
@MainActor func panelHandingBack(_ handBacks: HandBacks) throws -> NSWindow {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let hosting = NSHostingView(rootView: DetailPanelView(editor: try gadgetEditor(scheduler: TaskScheduler()), onExit: { handBacks.count += 1 }))
    window.contentView = hosting
    window.settle()
    window.makeFirstResponder(nil)
    hosting.isHidden = true
    return window
}

/// Counts its section's builds.
@MainActor var countedBuilds = 0

/// An every-box section that counts how often its content is built.
struct CountingPlugin: CanvasPlugin {
    var id: PluginID { "counting" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.detailsForEveryBox {
            DetailSection("Counted", in: FrameTab.self) { frame in
                let _ = (countedBuilds += 1)
                Text(DetailNumberText.format(frame.wrappedValue.minX, unit: "pt"))
            }
        }
    }
}

/// A fifth tab for the gadget, to fill the strip.
enum ListTab {}
extension ListTab: DetailTab { static var title: String { "List" } }

/// Gives the panel its overview, as a plugin does: a text field whose placeholder is "Overview"
/// (or `name`).
struct OverviewPlugin: CanvasPlugin {
    var name = "Overview"
    var id: PluginID { PluginID(name.lowercased()) }
    func register(into registrar: inout PluginRegistrar) {
        let name = name
        registrar.detailOverview { _, _ in TextField(name, text: .constant("")) }
    }
}

@MainActor let windowTests = Suite("Panel in a window", [
    test("an overview stands in for No Selection and goes under the header of several; one shape shows its own panel") {
        let editor = try gadgetEditor([OverviewPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let a = editor.add(Box(gadgetFrame)), b = editor.add(Box(gadgetFrame.offsetBy(dx: 300, dy: 0)))
        panel.window.spin { panel.fields.map(\.placeholderString) == ["Overview"] }
        editor.selection = a
        panel.window.spin { panel.fields.map(\.stringValue) == ["240 pt", "160 pt", "80 pt", "40 pt"] }
        editor.selectedShapeIDs = [a, b]
        panel.window.spin { panel.fields.map(\.placeholderString) == ["Overview"] }
    },
    test("nothing selected shows no fields; selecting a box shows its size and position") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let box = editor.add(Box(gadgetFrame))
        panel.window.settle()
        expectEqual(panel.fields.map(\.stringValue), [])
        editor.selection = box
        panel.window.spin { !panel.fields.isEmpty }
        expectEqual(panel.fields.map(\.stringValue), ["240 pt", "160 pt", "80 pt", "40 pt"])
    },
    test("typing into a panel field edits the shape and never switches tools") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = editor.add(Gadget(gadgetFrame))
        editor.selection = id
        panel.window.spin { !panel.fields.isEmpty }
        panel.window.focus(try panel.field("Name"))
        panel.window.type("gv")      // G is the gadget tool's shortcut, on the canvas
        expectEqual(editor.props(id, as: Gadget.self)?.name, "gv")
        expectEqual(editor.currentToolID, .select)
    },
    test("a section is rebuilt when its own shape changes, never when another does") {
        let editor = try gadgetEditor([CountingPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let shown = editor.add(Box(gadgetFrame)), other = editor.add(Box(gadgetFrame))
        editor.selection = shown
        panel.window.spin { !panel.fields.isEmpty }
        panel.window.settle()
        countedBuilds = 0
        for x in 1...20 {
            editor.transact { $0.update(other) { $0.box?.origin.x = CGFloat(x) } }
            panel.window.settle()
        }
        expectEqual(countedBuilds, 0)
        for x in 1...20 {
            editor.transact { $0.update(shown) { $0.box?.origin.x = CGFloat(x) } }
            panel.window.spin { countedBuilds >= x }
        }
        panel.window.settle()
        expectEqual(countedBuilds, 20)
    },
    test("a number field keeps a draft: typing writes nothing, Return commits it in one transaction") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = editor.add(Box(gadgetFrame))
        editor.selection = id
        panel.window.spin { !panel.fields.isEmpty }
        panel.window.focus(try panel.field("240 pt"))
        let revision = editor.revision
        panel.window.type("300")
        expectEqual(editor.document[id]?.box?.width, 240)
        expectEqual(editor.revision, revision)
        panel.window.pressReturn()
        panel.window.settle()
        expectEqual(editor.document[id]?.box?.width, 300)
        expectEqual(editor.revision, revision + 1)
        expectEqual(panel.fields.first?.stringValue, "300 pt")
    },
    test("a draft commits to its own shape when the canvas is clicked") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = editor.add(Box(gadgetFrame))
        editor.selection = id
        panel.window.spin { !panel.fields.isEmpty }
        panel.window.focus(try panel.field("240 pt"))
        panel.window.type("250")
        panel.click(CGPoint(x: 600, y: 600))
        expectEqual(editor.document[id]?.box?.width, 250)
        expectEqual(editor.selection, nil)
        expect(panel.canvasHasKeyboard)
    },
    test("a draft commits to its own shape when another panel field takes the keyboard") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = editor.add(Box(gadgetFrame))
        editor.selection = id
        panel.window.spin { !panel.fields.isEmpty }
        panel.window.focus(try panel.field("240 pt"))
        let revision = editor.revision
        panel.window.type("300")
        panel.window.focus(try panel.field("80 pt"))
        expectEqual(editor.document[id]?.box?.width, 300)
        expectEqual(editor.revision, revision + 1)
        expectEqual(editor.selection, id)
    },
    test("stepping a number with a draft steps from the draft, in one write") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = editor.add(Box(gadgetFrame))
        editor.selection = id
        panel.window.spin { !panel.fields.isEmpty }
        let width = try panel.field("240 pt")
        panel.window.focus(width)
        let revision = editor.revision
        panel.window.type("300")
        try require(panel.steppers.first).performClick(nil)
        panel.window.settle()
        let stepped = try require(editor.document[id]?.box?.width)
        expect(abs(stepped - 300) == 1, "stepped from the draft: \(stepped)")
        expectEqual(editor.revision, revision + 1)
        expectEqual(width.stringValue, "\(Int(stepped)) pt", "the field shows the step, not the draft")
        expect((panel.window.firstResponder as? NSTextView)?.delegate === width, "and keeps the keyboard")
        panel.window.focus(try panel.field("80 pt"))
        expectEqual(editor.document[id]?.box?.width, stepped, "the draft is gone")
        expectEqual(editor.revision, revision + 1)
    },
    test("a number field reads and writes numbers in the panel's locale") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let panel = PanelWindow(editor, locale: Locale(identifier: "de_DE"))
        let id = editor.add(Gadget(gadgetFrame))
        editor.transact { $0.update(id, as: Gadget.self) { $0.props.count = 2.5 } }
        editor.selection = id
        panel.window.spin { !panel.fields.isEmpty }
        panel.window.focus(try panel.field("2,5 x"))
        panel.window.type("3,5")
        panel.window.pressReturn()
        panel.window.settle()
        expectEqual(editor.props(id, as: Gadget.self)?.count, 3.5)
        expect(panel.fields.contains { $0.stringValue == "3,5 x" }, "\(panel.fields.map(\.stringValue))")
    },
    test("hiding the panel while one of its fields has the keyboard hands it to the canvas") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = editor.add(Box(gadgetFrame))
        editor.selection = id
        panel.window.spin { !panel.fields.isEmpty }
        panel.window.focus(try panel.field("240 pt"))
        panel.window.type("250")
        panel.hosting.isHidden = true
        panel.window.spin { panel.canvasHasKeyboard }
        panel.window.settle()
        expect(panel.canvasHasKeyboard)
        expectEqual(panel.exits, 1)
        expectEqual(editor.document[id]?.box?.width, 250)
    },
    test("a panel let go by its test goes with it, and so does the keyboard it would hand back a turn later") {
        // Kept past its test, its window still has the keyboard when the turn comes: handed back.
        let handBacks = HandBacks()
        var kept: NSWindow?
        expectEqual(runAsTest { kept = try panelHandingBack(handBacks) }, [])
        spinRunLoop { handBacks.count == 1 }
        // Let go, it's gone as its test ends (TestKit drains each test's autorelease pool, as the app
        // drains each event's), so the turn finds no window: nothing it was handed is called.
        weak var window: NSWindow?
        expectEqual(runAsTest { window = try panelHandingBack(handBacks) }, [])
        expect(window == nil, "the window went with its test")
        // Another kept past its test: once its hand-back lands, the one scheduled before it has had
        // its turn (the main actor runs them in order), so the count says whether it handed back too.
        expectEqual(runAsTest { kept = try panelHandingBack(handBacks) }, [])
        spinRunLoop { handBacks.count >= 2 }
        expectEqual(handBacks.count, 2)
        kept = nil
    },

    test("dividers go between sections, not under the last") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        editor.selection = editor.add(Box(gadgetFrame))
        panel.window.spin { !panel.fields.isEmpty }
        expectEqual(try editor.layout(try require(editor.selection)).outline, ["Frame: Size, Position"])
        expectEqual(hairlines(try panel.render()), 2, "one under the header, one between Size and Position")
    },
    test("a footer line tints its symbol, not its text") {
        let editor = try gadgetEditor([Contributor(id: "alarm") { r in
            r.detailStatusForEveryShape { _, _ in [DetailStatus("Something is badly wrong with this box", tone: .error)] }
        }], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        editor.selection = editor.add(Box(gadgetFrame))
        panel.window.spin { !panel.fields.isEmpty }
        // The red area of the footer, the bottom 40 points: the symbol is about 11 points square,
        // the text much longer.
        let area = redArea(try panel.render(), in: panel, rows: 660..<700)
        expect((25..<144).contains(area), "\(area) square points of red")
    },
    test("a tab's status lines lead it, each its tone's symbol, and none shows in the footer") {
        let editor = try gadgetEditor([Contributor(id: "alerts") { r in
            r.detailStatusForEveryShape(in: AlertsTab.self) { _, _ in [DetailStatus("Something is badly wrong with this box", tone: .error)] }
        }], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        editor.selection = editor.add(Box(gadgetFrame))
        panel.window.spin { !panel.fields.isEmpty }
        try require(editor.detailPanel).choose(.of(AlertsTab.self), for: Box.kind)
        panel.window.spin { panel.fields.isEmpty }
        let image = try panel.render()
        // Under the header and the tab strip, the first line's symbol, about 11 points square; the
        // footer, the bottom 40 points, has nothing red.
        expect((25..<144).contains(redArea(image, in: panel, rows: 60..<120)), "the line's symbol")
        expectEqual(redArea(image, in: panel, rows: 660..<700), 0, "the footer")
    },
    test("a tab whose lines warn or err shows its worst tone's symbol before its title, from another tab; a tab of other lines, none") {
        final class Lines { var tone = DetailStatus.Tone.error }
        let lines = Lines()
        let editor = try gadgetEditor([Contributor(id: "alerts") { r in
            r.detailStatusForEveryShape(in: AlertsTab.self) { _, _ in [DetailStatus("Something is badly wrong with this box", tone: lines.tone)] }
        }], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let box = editor.add(Box(gadgetFrame))
        editor.selection = box
        panel.window.spin { !panel.fields.isEmpty }
        expectEqual(try editor.layout(box).tabs.map(\.title), ["Frame", "Alerts"])
        // The strip, under the 44-point header: a 9-point symbol, some 40 square points of color.
        let strip = 44..<72
        expect((15..<90).contains(redArea(try panel.render(), in: panel, rows: strip)), "an error's octagon, while Frame is shown")
        lines.tone = .warning
        editor.transact { $0.update(box, as: Box.self) { $0.frame.size.width += 1 } }
        panel.window.settle()
        expect((15..<90).contains(redArea(try panel.render(), in: panel, rows: strip)), "a warning's triangle (orange counts)")
        lines.tone = .info
        editor.transact { $0.update(box, as: Box.self) { $0.frame.size.width += 1 } }
        panel.window.settle()
        expectEqual(redArea(try panel.render(), in: panel, rows: strip), 0, "an info line's tab has none")
    },
    test("a tab's status lines come before its sections") {
        let editor = try gadgetEditor([Contributor(id: "alerts") { r in
            r.detailStatusForEveryShape(in: RemarksTab.self) { _, _ in [DetailStatus("Something is badly wrong with this gadget", tone: .error)] }
        }], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        try require(editor.detailPanel).choose(.of(RemarksTab.self), for: Gadget.kind)
        editor.selection = editor.add(Gadget(gadgetFrame))
        panel.window.spin { !panel.textViews.isEmpty }
        let area = try require(panel.textViews.first)
        let top = Int(area.convert(area.bounds, to: panel.hosting).minY)
        let image = try panel.render()
        expect((25..<144).contains(redArea(image, in: panel, rows: 72..<top)), "the line's symbol, under the strip (whose Remarks tab has its own) and above the remark's text area at \(top)")
        expectEqual(redArea(image, in: panel, rows: top..<700), 0, "nothing red from the text area down")
    },
    test("a draft commits to its own shape when the selection moves under it, and the canvas gets the keyboard") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let a = editor.add(Box(gadgetFrame)), b = editor.add(Box(gadgetFrame))
        editor.selection = a
        panel.window.spin { !panel.fields.isEmpty }
        panel.window.focus(try panel.field("240 pt"))
        panel.window.type("260")
        editor.selection = b
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(editor.document[a]?.box?.width, 260)
        expectEqual(editor.document[b]?.box?.width, 240)
        expect(panel.canvasHasKeyboard)
        expectEqual(panel.fields.first?.stringValue, "240 pt")
    },
    test("several selected show a summary header over a placeholder, not a shape's fields or No Selection") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let a = editor.add(Box(gadgetFrame)), b = editor.add(Box(gadgetFrame))
        panel.window.settle()
        let none = try panel.render()
        expectEqual(hairlines(none), 0, "No Selection")
        editor.selectedShapeIDs = [a, b]
        panel.window.settle()
        let several = try panel.render()
        expectEqual(panel.fields.map(\.stringValue), [])
        expectEqual(hairlines(several), 1, "one under the header")
        expect(several.tiffRepresentation != none.tiffRepresentation)
    },
    test("the panel follows the set: 2 → 3 updates the count, back to one shows its panel, none shows No Selection") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let a = editor.add(Box(gadgetFrame)), b = editor.add(Box(gadgetFrame)), c = editor.add(Box(gadgetFrame))
        panel.window.settle()
        let none = try panel.render()
        editor.selectedShapeIDs = [a, b]
        panel.window.settle()
        let two = try panel.render()
        editor.selectedShapeIDs = [a, b, c]
        panel.window.spin { (try? panel.render().tiffRepresentation) != two.tiffRepresentation }
        editor.selectedShapeIDs = [b]
        panel.window.spin { !panel.fields.isEmpty }
        expectEqual(panel.fields.map(\.stringValue), ["240 pt", "160 pt", "80 pt", "40 pt"])
        editor.selectedShapeIDs = []
        panel.window.spin { panel.fields.isEmpty }
        panel.window.settle()
        expectEqual(try panel.render().tiffRepresentation, none.tiffRepresentation)
    },
    test("a draft commits to its own shape when the selection grows to several, and the canvas gets the keyboard") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let a = editor.add(Box(gadgetFrame)), b = editor.add(Box(gadgetFrame))
        editor.selection = a
        panel.window.spin { !panel.fields.isEmpty }
        panel.window.focus(try panel.field("240 pt"))
        panel.window.type("260")
        editor.selectedShapeIDs = [a, b]
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(editor.document[a]?.box?.width, 260)
        expectEqual(editor.document[b]?.box?.width, 240)
        expectEqual(panel.exits, 1)
    },
    test("a focused panel control removed by a multi-select hands the keyboard to the canvas") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let gadget = editor.add(Gadget(gadgetFrame)), box = editor.add(Box(gadgetFrame))
        editor.selection = gadget
        panel.window.spin { !panel.fields.isEmpty }
        panel.window.focus(try panel.field("Name"))
        panel.window.type("x")
        editor.selectedShapeIDs = [gadget, box]
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(editor.props(gadget, as: Gadget.self)?.name, "x")
        expectEqual(panel.exits, 1)
        panel.window.type("g")                                  // a tool shortcut, on the canvas
        expectEqual(editor.currentToolID, ToolID(placing: Gadget.kind))
    },
    test("Escape drops the draft, leaves the value, and hands the keyboard to the canvas") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = editor.add(Box(gadgetFrame))
        editor.selection = id
        panel.window.spin { !panel.fields.isEmpty }
        panel.window.focus(try panel.field("240 pt"))
        let revision = editor.revision
        panel.window.type("9")
        panel.window.pressEscape()
        panel.window.spin { panel.canvasHasKeyboard }
        panel.window.settle()
        expectEqual(editor.revision, revision)
        expectEqual(panel.exits, 1)
        expect(panel.canvasHasKeyboard)
        expectEqual(panel.fields.first?.stringValue, "240 pt")
        expectEqual(editor.selection, id, "Escape in the panel isn't Escape on the canvas")
    },
    test("switching tabs away from the focused field hands the keyboard to the canvas; collapsing another section doesn't") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = editor.add(Gadget(gadgetFrame))
        editor.selection = id
        panel.window.spin { !panel.fields.isEmpty }
        let state = try require(editor.detailPanel)
        panel.window.focus(try panel.field("Name"))
        let count = try require(editor.layout(id).sections(in: .of(GadgetTab.self)).last)
        state.setCollapsed(count, true)
        panel.window.settle()
        expect(panel.window.firstResponder is NSTextView, "the name field keeps the keyboard")
        expectEqual(panel.exits, 0)
        state.choose(.of(StyleTab.self), for: Gadget.kind)
        panel.window.spin { panel.canvasHasKeyboard }
        panel.window.settle()
        expect(panel.canvasHasKeyboard)
        expectEqual(panel.exits, 1)
    },
    test("a list shows one row per item, and edits the item in its row") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = editor.add(Gadget(gadgetFrame, parts: ["wheel", "axle", "bolt"].map { Gadget.Part(text: $0) }))
        editor.selection = id
        try require(editor.detailPanel).choose(.of(PartsTab.self), for: Gadget.kind)
        panel.window.spin { !panel.tables.isEmpty }
        expectEqual(panel.tables.map(\.numberOfRows), [3])
        panel.window.focus(try panel.field("axle"))
        panel.window.type("gear")
        expectEqual(editor.props(id, as: Gadget.self)?.parts.map(\.text), ["wheel", "gear", "bolt"])
    },
    test("an empty list says No Items in its box") {
        /// Dark pixels across the middle of the list's box, drawn in an unshown window.
        @MainActor func ink(_ parts: [Gadget.Part]) throws -> Int {
            let list = DetailList(.constant(parts), add: { Gadget.Part() }) { _ in EmptyView() }
            let hosting = NSHostingView(rootView: list.frame(width: DetailStyle.idealWidth))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: DetailStyle.idealWidth, height: 200), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = hosting
            window.spin { !hosting.descendants(NSTableView.self).isEmpty }
            let table = try require(hosting.descendants(NSTableView.self).first?.enclosingScrollView)
            let box = table.convert(table.bounds, to: hosting).insetBy(dx: 4, dy: 4)
            let image = try require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: image)
            let scale = CGFloat(image.pixelsWide) / hosting.bounds.width
            let pixels = DeviceRGBPixels(image)
            return stride(from: box.minY, to: box.maxY, by: 1).flatMap { y in
                stride(from: box.minX, to: box.maxX, by: 1).map { CGPoint(x: $0, y: y) }
            }.filter { point in
                (pixels[Int(point.x * scale), Int(point.y * scale)]?.gray ?? 1) < 0.7
            }.count
        }
        expect(try ink([]) > 20, "No Items")
        expectEqual(try ink([Gadget.Part()]), 0, "an empty row, and no No Items")
    },
    test("a horizontal's tab edits the opted-in kind's own field, on every keystroke") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = editor.add(Gadget(gadgetFrame))
        editor.selection = id
        try require(editor.detailPanel).choose(.of(RemarksTab.self), for: Gadget.kind)
        panel.window.spin { !panel.textViews.isEmpty }
        let area = try require(panel.textViews.first)
        panel.window.makeFirstResponder(area)
        panel.window.settle()
        let revision = editor.revision
        panel.window.type("ok")
        expectEqual(editor.revision, revision + 2)
        panel.window.settle()
        expectEqual(editor.props(id, as: Gadget.self)?.remark, "ok")
        expectEqual(area.string, "ok")
        editor.transact { $0.update(id, as: Gadget.self) { $0.props.remark = "changed elsewhere" } }
        panel.window.spin { area.string == "changed elsewhere" }
        expectEqual(area.string, "changed elsewhere")
    },
    test("a standalone toggle is a checkbox then its label; in a row, or with its label hidden, a bare box") {
        let editor = try gadgetEditor([Contributor(id: "toggles") { r in
            r.details(Gadget.self) {
                DetailSection(in: ListTab.self) { _ in
                    Toggle("Standalone", isOn: .constant(true))
                    LabeledContent("Row") { Toggle("In a row", isOn: .constant(true)) }
                    Toggle("Hidden", isOn: .constant(true)).labelsHidden()
                }
            }
        }], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        editor.selection = editor.add(Gadget(gadgetFrame))
        try require(editor.detailPanel).choose(.of(ListTab.self), for: Gadget.kind)
        panel.window.spin { panel.checkboxes.count == 3 }
        let boxes = panel.checkboxes.map { $0.convert($0.bounds, to: panel.hosting) }
        // At the inset, in the control column, at the inset.
        expectEqual(boxes.map(\.minX), [16, 96, 16])
        // Ink just after the box: the standalone toggle's label, and nothing else.
        let image = try require(panel.hosting.bitmapImageRepForCachingDisplay(in: panel.hosting.bounds))
        panel.hosting.cacheDisplay(in: panel.hosting.bounds, to: image)
        let scale = CGFloat(image.pixelsWide) / panel.hosting.bounds.width
        let labeled = boxes.map { box in
            stride(from: box.maxX + 4, to: box.maxX + 40, by: 1).contains { x in
                stride(from: box.minY, to: box.maxY, by: 1).contains { y in
                    pixel(image, at: CGPoint(x: x, y: y), scale: scale)[3] > 128     // on the panel's clear background
                }
            }
        }
        expectEqual(labeled, [true, false, false])
    },
    test("swatches mark the preset equal to the color with a white dot") {
        let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        let swatches = DetailSwatches(.constant(blue), presets: [("Red", red), ("Blue", blue)])
        let renderer = ImageRenderer(content: swatches.frame(width: 200, height: 20).background(.white).environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = NSBitmapImageRep(cgImage: try require(renderer.cgImage))
        // 14-point swatches, 4 apart, centered in the row.
        let centers = [0, 1].map { (index: CGFloat) in pixel(image, at: CGPoint(x: index * 18 + 7, y: 10), scale: 2).prefix(3).map { $0 } }
        expectEqual(centers.map { $0.map { $0 > 200 } }, [[true, false, false], [true, true, true]])
    },
    test("the tab strip fits five short titles in the ideal width") {
        // A long title doesn't fit a fifth of the strip, so the tabs are sized to their titles: each
        // title is drawn as wide as in a panel with room to spare.
        @MainActor func titleWidths(panelWidth: CGFloat) throws -> [Int] {
            let editor = try gadgetEditor([Contributor(id: "more") { r in
                r.details(Gadget.self) { DetailSection(in: ListTab.self) { _ in Text("List") } }
            }])
            editor.selection = editor.add(Gadget(gadgetFrame))
            expectEqual(try editor.layout(try require(editor.selection)).tabs.map(\.title), ["Gadget", "List", "Remarks", "Style", "Frame"])
            return try inkRuns(DetailPanelView(editor: editor), width: panelWidth, rows: 48...62)
        }
        let roomy = try titleWidths(panelWidth: 600)
        expectEqual(roomy.count, 5)
        expectEqual(try titleWidths(panelWidth: DetailStyle.idealWidth), roomy)
    },
    test("a header field renames its shape as you type, shows the kind's name while empty, and Return hands the keyboard to the canvas") {
        let editor = try gadgetEditor([CardsPlugin(), RenamingCards()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let card = editor.add(Card(gadgetFrame))
        editor.selection = card
        panel.window.spin { panel.headerField != nil }
        let field = try require(panel.headerField)
        expectEqual(field.placeholderString, "Card")
        panel.window.focus(field)
        panel.window.type("cog")                   // g is the gadget tool's shortcut, on the canvas
        expectEqual(editor.props(card, as: Card.self)?.text, "cog")
        expectEqual(editor.currentToolID, .select)
        panel.window.pressReturn()                 // at once, before the panel draws "cog"
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(panel.exits, 1)
        expectEqual(editor.props(card, as: Card.self)?.text, "cog", "Return keeps what was typed")
    },
    test("a header field is set as SwiftUI's plain one is, and its editor is its own, which checks the title's spelling as the app does") {
        let editor = try gadgetEditor([CardsPlugin(), RenamingCards()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        editor.selection = editor.add(Card(gadgetFrame, text: "Hi"))
        panel.window.spin { panel.headerField != nil }
        let field = try require(panel.headerField)
        expectEqual(field.font, NSFont.systemFont(ofSize: 12, weight: .semibold), "the header's title")
        expect(!field.isBordered && !field.isBezeled && !field.drawsBackground && field.focusRingType == .none, "borderless")
        expect(field.usesSingleLineMode && field.cell?.isScrollable == true && field.cell?.wraps == false && field.lineBreakMode == .byClipping,
               "one line, clipped, scrolling sideways while it's typed in")
        panel.window.focus(field)
        let text = try require(panel.window.firstResponder as? EditingTextView)
        expect(text.isFieldEditor && field.currentEditor() === text, "the field's own editor")
        expect(text.spelling === Spelling.app)
        expectEqual(text.isContinuousSpellCheckingEnabled, Spelling.app.checksWhileTyping)
        expect(!text.isRichText && text.allowsUndo, "plain text, undone as it's typed")
        expect(!text.isAutomaticQuoteSubstitutionEnabled && !text.isAutomaticDashSubstitutionEnabled, "as SwiftUI's fields' editors")
    },
    test("a header field shown a title written elsewhere while it's typed in drops typing's undo, whose ranges were the old text's") {
        let editor = try gadgetEditor([CardsPlugin(), RenamingCards()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let card = editor.add(Card(gadgetFrame))
        editor.selection = card
        panel.window.spin { panel.headerField != nil }
        panel.window.focus(try require(panel.headerField))
        panel.window.type("Lobby hall")
        panel.window.settle()
        let text = try require(panel.window.firstResponder as? NSTextView)
        expect(text.undoManager?.canUndo == true, "the typing")
        editor.transact { $0.update(card, as: Card.self) { $0.props.text = "X" } }
        panel.window.spin { text.string == "X" }
        expect(text.undoManager?.canUndo == false, "an undo would run past the text shown")
        expect(panel.window.firstResponder === text, "and it's still typed in")
    },
    test("a header field draws as SwiftUI's plain field did, pixel for pixel: a title, one too long for it, and its placeholder") {
        @MainActor func drawn(_ title: some View) -> NSBitmapImageRep {
            let header = HStack(spacing: 0) {
                DetailHeaderLabel(systemImage: "note.text") { title }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DetailStyle.inset)
            .frame(width: DetailStyle.idealWidth, height: DetailStyle.headerHeight)
            .controlSize(.small)
            .background(Color.white)
            .environment(\.colorScheme, .light)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: DetailStyle.idealWidth, height: DetailStyle.headerHeight),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            let host = NSHostingView(rootView: header)
            window.contentView = host
            window.settle()
            return snapshot(host)
        }
        for text in ["Groceries", "A title far too long for the header, which runs on past its edge", ""] {
            let field = drawn(DetailHeaderField(.constant(text), placeholder: "Note"))
            let swiftUIs = drawn(TextField("Note", text: .constant(text)).textFieldStyle(.plain))
            expectEqual(field.pixelsWide, swiftUIs.pixelsWide)
            let differing = (0..<field.pixelsHigh).reduce(0) { count, y in
                count + (0..<field.pixelsWide).count { x in field.colorAt(x: x, y: y) != swiftUIs.colorAt(x: x, y: y) }
            }
            expectEqual(differing, 0, "\"\(text)\"")
        }
    },
    test("Escape in a section's text field right after typing keeps what was typed") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = editor.add(Gadget(gadgetFrame, name: "Old"))
        editor.selection = id
        panel.window.spin { (try? panel.field("Old")) != nil }
        panel.window.focus(try panel.field("Old"))
        panel.window.type("New")
        panel.window.pressEscape()                 // at once, before the panel draws "New"
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(editor.props(id, as: Gadget.self)?.name, "New")
    },
])

/// The widths, in pixels at 2x, of the runs of dark ink across `rows` (points) of `view` drawn
/// `width` wide in light mode. Runs closer than 3 points are one run (a word, not its letters).
@MainActor func inkRuns(_ view: some View, width: CGFloat, rows: ClosedRange<Int>) throws -> [Int] {
    let renderer = ImageRenderer(content: view.frame(width: width, height: 120).background(.white).environment(\.colorScheme, .light))
    renderer.scale = 2
    let image = NSBitmapImageRep(cgImage: try require(renderer.cgImage))
    let pixels = DeviceRGBPixels(image)
    let inked = (0..<image.pixelsWide).map { x in
        (rows.lowerBound * 2...rows.upperBound * 2).contains { y in (pixels[x, y]?.gray ?? 1) < 0.5 }
    }
    var runs: [Int] = [], start: Int?, gap = 0
    for (x, isInked) in inked.enumerated() {
        if isInked {
            if start == nil { start = x }
            gap = 0
        } else if let first = start {
            gap += 1
            if gap == 6 { runs.append(x - gap + 1 - first); start = nil }
        }
    }
    if let first = start { runs.append(inked.count - gap - first) }
    return runs
}

/// How many full-width hairlines (dividers) `image` has: runs of rows whose pixels, nearly all the
/// way across, differ from the rows two pixels above and below.
@MainActor func hairlines(_ image: NSBitmapImageRep) -> Int {
    let pixels = DeviceRGBPixels(image)
    func gray(_ x: Int, _ y: Int) -> CGFloat { pixels[x, y]?.gray ?? 1 }
    let columns = Array(stride(from: 0, to: image.pixelsWide, by: 2))
    let lines = (2..<image.pixelsHigh - 2).filter { y in
        columns.filter { x in abs(gray(x, y) - gray(x, y - 2)) > 0.02 && abs(gray(x, y) - gray(x, y + 2)) > 0.02 }.count > columns.count * 9 / 10
    }
    return lines.indices.filter { $0 == 0 || lines[$0] > lines[$0 - 1] + 1 }.count
}

/// How many square points of `panel`'s render are red, across `rows` (points from its top).
@MainActor func redArea(_ image: NSBitmapImageRep, in panel: PanelWindow, rows: Range<Int>) -> CGFloat {
    let scale = CGFloat(image.pixelsWide) / panel.hosting.bounds.width
    let pixels = DeviceRGBPixels(image)
    var red = 0
    for y in Int(CGFloat(rows.lowerBound) * scale)..<min(image.pixelsHigh, Int(CGFloat(rows.upperBound) * scale)) {
        for x in 0..<image.pixelsWide {
            guard let pixel = pixels[x, y] else { continue }
            if pixel.red - max(pixel.green, pixel.blue) > 0.3 { red += 1 }
        }
    }
    return CGFloat(red) / (scale * scale)
}

import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Selection
import TestKit
import TextEditing

// View › Focus Inspector (⌥⌘I) and Focus Sidebar (⌥⌘S), pressed as the app routes them, in the app's window, over the nested file
// (two notes and an arrow on the root, a subboard): the pane shown if it's hidden, and given the keyboard.

extension NestedWindow {
    /// The table of contents' list, while the sidebar shows it.
    var list: NSTableView? { window.contentView?.descendants(NSTableView.self).first { $0.isTableOfContents && !$0.isHiddenOrHasHiddenAncestor } }

    /// Whether the keyboard is in the inspector: a view in the panel (not the canvas or what it hosts, nor the sidebar).
    var inspectorHasKeyboard: Bool {
        guard let view = window.firstResponder as? NSView else { return false }
        return !isCanvas(view) && view.isDescendant(of: window.contentView!) && view.isInInspector
    }

    /// ⌥⌘I pressed, as the app routes it: the window's key equivalents, then the app's menus (View's
    /// items sent to this window's controller: an unshown window isn't the key window), then the
    /// first responder. Whether View › Focus Inspector took it.
    @discardableResult
    func pressFocusInspector() -> Bool {
        press(.focusInspector) == "Focus Inspector"
    }

    /// `chord` pressed as the app routes it (see `pressFocusInspector`): the title of the View item it ran.
    @discardableResult
    func press(_ chord: Chord) -> String? {
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: editor.registry)
        for item in menus.main.item(withTitle: "View")?.submenu?.items ?? [] { item.target = controller }
        return KeyDriver(window, menu: menus.main).send(chord).menuItem?.title
    }

    /// The pane the keyboard is in, by the window's own reckoning.
    var pane: BoardWindowController.Pane? { controller.currentPane() }

    /// F6 and ⇧F6 pressed, and the pane the keyboard is in once the panes have settled.
    @discardableResult
    func cycle(_ chord: Chord) -> BoardWindowController.Pane? {
        let start = pane
        press(chord)
        // The inspector takes the keyboard a turn or two on, once it has views.
        window.spin { self.pane != start && self.pane != nil }
        window.settle()
        return pane
    }

    /// The first responder is the list's, or a view in it (a field editor is a view in the field).
    func firstResponder(isIn view: NSView?) -> Bool {
        guard let view, let responder = window.firstResponder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: view)
    }
}

extension Chord {
    /// View › Focus Next Pane's, and Focus Previous Pane's.
    static let nextPane = Chord(Key.f6)
    static let previousPane = Chord(Key.f6, .shift)
}

@MainActor let inspectorFocusShippedTests = Suite("Focus Inspector and Focus Sidebar, shipped", [
    test("with nothing selected Focus Inspector is dimmed, the inspector hidden with nothing to show; Focus Sidebar gives the keyboard to the table of contents' list, and Escape gives it back to the canvas") {
        let w = try NestedWindow(sidebar: true)
        w.window.spin { w.list != nil }
        expect(w.canvasHasKeyboard)
        expect(!w.pressFocusInspector(), "nothing to inspect")
        expect(w.canvasHasKeyboard)
        expect(!w.controller.shownPanes().contains(.inspector))
        expectEqual(w.press(.focusSidebar), "Focus Sidebar")
        w.window.spin { w.firstResponder(isIn: w.list) }
        expect(w.firstResponder(isIn: w.list), "the list has the keyboard: \(String(describing: w.window.firstResponder))")
        expectEqual(w.pane, .sidebar)
        w.window.pressEscape()
        w.window.spin { w.canvasHasKeyboard }
        expect(w.canvasHasKeyboard, "Escape in the list: \(String(describing: w.window.firstResponder))")
        expectEqual(w.editor.selectedShapeIDs, [], "and isn't Escape on the canvas")
    },
    test("with a shape selected it gives the keyboard to the panel's first field, its title, not the back button above it; Escape gives it back with the shape still selected") {
        let w = try NestedWindow()
        let note = w.nest.notes(on: 1).0
        w.editor.selection = note
        w.window.spin { w.titleField != nil }
        w.pressFocusInspector()
        expect(w.firstResponder(isIn: w.titleField), "the title field has the keyboard: \(String(describing: w.window.firstResponder))")
        w.window.pressEscape()
        w.window.spin { w.canvasHasKeyboard }
        expect(w.canvasHasKeyboard, "Escape in the field: \(String(describing: w.window.firstResponder))")
        expectEqual(w.editor.selectedShapeIDs, [note])
    },
    test("from a note being edited it ends the editing first, as Find does, and gives the note's title field the keyboard") {
        let w = try NestedWindow()
        let note = w.nest.notes(on: 1).0
        w.editor.selection = note
        expect(w.editor.beginEditing(note))
        w.window.spin { w.window.firstResponder is EditingTextView }
        w.pressFocusInspector()
        expectEqual(w.editor.editingShapeID, nil, "no editing view left up while the keyboard is in the panel")
        w.window.spin { w.firstResponder(isIn: w.titleField) }
        expect(w.firstResponder(isIn: w.titleField))
        expectEqual(w.editor.selectedShapeIDs, [note])
    },
    test("with the inspector hidden it shows it first, and gives it the keyboard once it has views") {
        let w = try NestedWindow()
        w.editor.selection = w.nest.notes(on: 1).0
        w.window.spin { w.titleField != nil }
        w.board.viewState.showsDetails = false
        w.window.spin { w.titleField == nil }
        expect(!w.inspectorHasKeyboard)
        w.pressFocusInspector()
        expect(w.board.viewState.showsDetails)
        w.window.spin { w.firstResponder(isIn: w.titleField) }
        expect(w.firstResponder(isIn: w.titleField), "\(String(describing: w.window.firstResponder))")
        w.window.pressEscape()
        w.window.spin { w.canvasHasKeyboard }
        expect(w.canvasHasKeyboard)
    },
    test("it's in the View menu after Show Inspector, on ⌥⌘I, enabled while the inspector has a shape to show; from a panel field it still runs") {
        let w = try NestedWindow()
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: w.editor.registry)
        let view = try require(menus.main.item(withTitle: "View")?.submenu)
        let titles = view.items.map(\.title)
        let show = try require(titles.firstIndex(of: "Show Inspector")), focus = try require(view.items.first { $0.title == "Focus Inspector" })
        expectEqual(titles[show + 1], "Focus Inspector")
        expectEqual(KeyboardShortcutSection.key(of: focus), "⌥⌘I")
        expectEqual(focus.action, #selector(BoardWindowController.focusInspector(_:)))
        expect(!w.controller.validateMenuItem(focus), "nothing selected, nothing to show")
        w.editor.selection = w.nest.notes(on: 1).0
        w.window.spin { w.titleField != nil }
        expect(w.controller.validateMenuItem(focus))
        w.window.focus(try require(w.titleField))
        expect(!w.canvasHasKeyboard)
        w.window.settle()
        let responder = try require(w.window.firstResponder)
        expect(responder.tryToPerform(try require(focus.action), with: nil), "the chain from a field reaches the controller")
        expect(w.firstResponder(isIn: w.titleField))
    },
    test("F6 walks the panes shown once each and comes round; Shift-F6 is its exact inverse, and says so in the View menu") {
        let w = try NestedWindow(sidebar: true)
        w.window.spin { w.list != nil }
        w.editor.selection = w.nest.notes(on: 1).0
        w.window.spin { w.titleField != nil }
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: w.editor.registry)
        let view = try require(menus.main.item(withTitle: "View")?.submenu)
        let next = try require(view.items.first { $0.title == "Focus Next Pane" }), previous = try require(view.items.first { $0.title == "Focus Previous Pane" })
        expectEqual(KeyboardShortcutSection.key(of: next), "F6")
        expectEqual(KeyboardShortcutSection.key(of: previous), "⇧F6")
        let panes = w.controller.shownPanes()
        expectEqual(panes, [.canvas, .inspector, .sidebar], "the canvas, then round as the window reads: the toolbar has no views in an unshown window")
        expectEqual(w.pane, .canvas)
        var forward: [BoardWindowController.Pane?] = []
        for _ in panes { forward.append(w.cycle(.nextPane)) }
        expectEqual(forward, Array(panes.dropFirst()) + [.canvas], "each pane once, then back to the canvas")
        expect(w.canvasHasKeyboard)
        var backward: [BoardWindowController.Pane?] = []
        for _ in panes { backward.append(w.cycle(.previousPane)) }
        expectEqual(backward, panes.dropFirst().reversed().map { Optional($0) } + [.canvas], "the exact inverse")
        // Next then previous lands where it began, from every pane.
        for pane in panes {
            w.controller.focusPane(pane)
            w.window.settle()
            let start = w.window.firstResponder
            w.cycle(.nextPane)
            w.cycle(.previousPane)
            expectEqual(w.pane, pane)
            if pane == .canvas { expect(start === w.window.firstResponder, "the canvas has the keyboard again") }
        }
    },
    test("hiding the inspector, or having nothing to show in it, takes it out of the cycle; hiding the sidebar takes it out too") {
        let w = try NestedWindow(sidebar: true)
        w.window.spin { w.list != nil }
        expect(!w.controller.shownPanes().contains(.inspector), "nothing selected")
        w.editor.selection = w.nest.notes(on: 1).0
        w.window.spin { w.titleField != nil }
        expect(w.controller.shownPanes().contains(.inspector))
        w.board.viewState.showsDetails = false
        w.window.settle()
        expect(!w.controller.shownPanes().contains(.inspector))
        w.press(.nextPane)
        w.window.spin { w.pane == .sidebar }
        expect(w.pane != .inspector, "never the inspector")
        w.board.viewState.showsDetails = true
        w.window.settle()
        expect(w.controller.shownPanes().contains(.inspector))
        w.window.makeFirstResponder(w.canvas)
        w.board.viewState.showsSidebar = false
        w.window.spin { w.list == nil }
        expectEqual(w.controller.shownPanes(), [.canvas, .inspector])
    },
    test("Escape from any pane returns to the canvas with the selection kept") {
        let w = try NestedWindow(sidebar: true)
        let note = w.nest.notes(on: 1).0
        w.editor.selection = note
        w.window.spin { w.titleField != nil }
        for pane in w.controller.shownPanes() where pane != .canvas {
            w.controller.focusPane(pane)
            w.window.spin { w.pane == pane }
            expectEqual(w.pane, pane)
            w.window.pressEscape()
            w.window.spin { w.canvasHasKeyboard }
            expect(w.canvasHasKeyboard, "Escape in \(pane): \(String(describing: w.window.firstResponder))")
            expectEqual(w.editor.selectedShapeIDs, [note], "the selection is kept")
        }
    },
    test("Focus Inspector with nothing in the panel that takes the keyboard makes the hosting view first responder") {
        let w = try NestedWindow()
        w.editor.selection = w.nest.notes(on: 1).0
        w.window.spin { w.titleField != nil }
        // Every control on a sheet is hidden, again until the inspector that just slid in has made all of
        // its own: the panel has nothing to give the keyboard to.
        @MainActor func hideControls() -> Bool {
            var hid = false
            for view in (w.window.contentView?.descendants(NSView.self) ?? []) where !w.isCanvas(view) && view !== w.window.contentView {
                if view.acceptsFirstResponder, view.isOnASheet {
                    view.isHidden = true
                    hid = true
                }
            }
            return hid
        }
        let slidIn = Date(timeIntervalSinceNow: 0.5)
        repeat { w.window.settle() } while hideControls() || Date() < slidIn
        w.pressFocusInspector()
        w.window.spin { w.window.firstResponder === w.window.contentView }
        expect(w.window.firstResponder === w.window.contentView, "the hosting view: \(String(describing: w.window.firstResponder))")
        // There it is the inspector's pane, so F6 goes on round rather than back to it; and Escape gives the canvas the keyboard.
        expectEqual(w.pane, .inspector)
        expectEqual(w.cycle(.nextPane), .canvas)
        w.pressFocusInspector()
        w.window.spin { w.window.firstResponder === w.window.contentView }
        expectEqual(w.cycle(.previousPane), .canvas)
        w.pressFocusInspector()
        w.window.spin { w.window.firstResponder === w.window.contentView }
        w.window.pressEscape()
        expect(w.canvasHasKeyboard, "Escape on the hosting view: \(String(describing: w.window.firstResponder))")
    },
    test("a field the window puts over the canvas (the board path, Jump To's) is the canvas's pane: F6 goes to the inspector, Shift-F6 round the other way") {
        let w = try NestedWindow(sidebar: true)
        w.editor.selection = w.nest.notes(on: 1).0
        w.window.spin { w.titleField != nil && w.list != nil }
        let content = try require(w.window.contentView)
        let canvasFrame = content.convert(w.canvas.convert(w.canvas.bounds, to: nil), from: nil)
        let field = NSTextField(frame: CGRect(x: canvasFrame.midX - 100, y: canvasFrame.midY - 12, width: 200, height: 24))
        content.addSubview(field)
        defer { field.removeFromSuperview() }
        w.window.makeFirstResponder(field)
        expectEqual(w.pane, .canvas)
        expectEqual(w.cycle(.nextPane), .inspector)
        w.window.makeFirstResponder(field)
        expectEqual(w.cycle(.previousPane), w.controller.shownPanes().last)
    },
    test("the panel's declared entry is the header's field, and the sidebar's the list: what Focus Inspector and Focus Sidebar give the keyboard to") {
        let w = try NestedWindow(sidebar: true)
        w.window.spin { w.list != nil }
        let sidebarEntry = try require(w.editor.registry.hostSidebar?.keyboardEntry)
        expect(sidebarEntry(w.editor) === w.list, "the list: \(String(describing: sidebarEntry(w.editor)))")
        expect(w.controller.sidebarKeyView() === w.list)
        expect(w.controller.inspectorKeyView() !== w.list, "never the sidebar's list")
        let entry = try require(w.editor.registry.hostInspector?.keyboardEntry)
        w.editor.selection = w.nest.notes(on: 1).0
        w.window.spin { w.titleField != nil }
        expect(entry(w.editor) === w.titleField, "the header's field")
        expect(w.controller.inspectorKeyView() === w.titleField)
    },
    test("with a toolbar view that takes the keyboard F6 visits canvas, inspector and toolbar once each, Shift-F6 is the inverse, and Escape from the toolbar goes back with the selection kept") {
        let w = try NestedWindow()
        let note = w.nest.notes(on: 1).0
        w.editor.selection = note
        w.window.spin { w.titleField != nil }
        // The window's own toolbar has views only once it is on screen: a segmented control (the tool picker's) goes into an item's view.
        let control = NSSegmentedControl(labels: ["A", "B"], trackingMode: .selectOne, target: nil, action: nil)
        let toolbar = try require(w.window.toolbar)
        try require(toolbar.items.compactMap(\.view).first).addSubview(control)
        expectEqual(w.controller.shownPanes(), [.canvas, .inspector, .toolbar])
        expectEqual(w.cycle(.nextPane), .inspector)
        expectEqual(w.cycle(.nextPane), .toolbar)
        expect(w.window.firstResponder === control, "the toolbar's control: \(String(describing: w.window.firstResponder))")
        expectEqual(w.cycle(.nextPane), .canvas)
        expect(w.canvasHasKeyboard)
        expectEqual(w.cycle(.previousPane), .toolbar)
        expectEqual(w.cycle(.previousPane), .inspector)
        expectEqual(w.cycle(.previousPane), .canvas)
        w.cycle(.previousPane)
        expectEqual(w.pane, .toolbar)
        w.window.pressEscape()
        expect(w.canvasHasKeyboard, "Escape in the toolbar: \(String(describing: w.window.firstResponder))")
        expectEqual(w.editor.selectedShapeIDs, [note])
        // With Caps Lock on too: it changes no key.
        w.cycle(.previousPane)
        expectEqual(w.pane, .toolbar)
        w.window.sendEvent(w.window.keyEvent("\u{1b}", code: 53, modifiers: .capsLock))
        expect(w.canvasHasKeyboard, "Escape with Caps Lock: \(String(describing: w.window.firstResponder))")
        // A hidden toolbar is out of the cycle.
        toolbar.isVisible = false
        expectEqual(w.controller.shownPanes(), [.canvas, .inspector])
    },
])

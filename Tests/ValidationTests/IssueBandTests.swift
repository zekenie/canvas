import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import CoreGraphics
import DetailPanel
import Foundation
import Geometry
import Keyboard
import Palette
import Selection
import SwiftUI
import TestKit
import Topology
import Validation

// The issue walk's views: the band over the panel, the light, and the line's "9 of 63". The band is hosted over the panel in
// an unshown window beside a canvas (as DetailPanelTests' panel windows are), over this suite's cards, pockets and links
// (`walkBandEditor`: rules of "bad", "meh" with an Ignore, "late" and "need"; "meh" is a rule that knows the shapes it may
// flag, as a rule's count does). SwiftUI gives an unshown window's buttons no accessibility element unless Keyboard navigation
// is on (System Settings › Keyboard), so the band's controls are found by where they are, and what VoiceOver hears of them is
// read off the focused control only when it is; what the window does without it, the tests hold the menus to.

private let shapes = walkShapes

/// What the panel's `onExit` does: gives the canvas the keyboard. Weak, the panel may call it a turn after the test let go.
@MainActor private final class HandBack {
    weak var window: NSWindow?
    weak var canvas: CanvasView?
    var count = 0

    func give() {
        count += 1
        if let canvas { window?.makeFirstResponder(canvas) }
    }
}

/// A gesture under way on the canvas, which turns the walk's steps off.
@MainActor final class IdleGesture: Session {
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {}
}

/// A panel and a canvas in one unshown window, a walk over the editor's file, and a key walk over them.
@MainActor
final class BandScene {
    let editor: CanvasEditor
    let window: NSWindow
    let canvas: CanvasView
    let hosting: NSView
    let walk: IssueWalk
    let keys: KeyWalk
    private let handBack = HandBack()

    /// How often the panel handed the keyboard back to the canvas.
    var exits: Int { handBack.count }

    init(before: [any CanvasPlugin] = [], more: [any CanvasPlugin] = [], file: CanvasFile? = nil) throws {
        let editor = try walkBandEditor(before: before, more: [Contributor(id: "band-field") { r in
            // A text field in the Issues tab, which every stop shows: somewhere in the panel's content the keyboard can be.
            r.detailsForEveryBox { DetailSection("Notes", in: IssuesTab.self) { _ in TextField("Notes", text: .constant("")) } }
        }] + more, file: file)
        self.editor = editor
        walk = try require(editor.issueWalk)
        let panelWidth = DetailStyle.idealWidth
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        canvas = CanvasView(editor: editor)
        canvas.frame = CGRect(x: 0, y: 0, width: 1000 - panelWidth, height: 700)
        let handBack = handBack
        hosting = NSHostingView(rootView: DetailPanelView(editor: editor, onExit: { handBack.give() }).environment(\.locale, Locale(identifier: "en_US")))
        hosting.frame = CGRect(x: 1000 - panelWidth, y: 0, width: panelWidth, height: 700)
        let root = NSView(frame: frame)
        root.addSubview(canvas)
        root.addSubview(hosting)
        window.contentView = root
        keys = KeyWalk(window, editor: editor, menu: nil, readers: [.canvas(canvas, selection: { editor.selectedShapeIDs.map { _ in "shape" } })])
        keys.standardControls = ["Previous Issue", "1 of 6", "Next Issue", "Done"]
        handBack.window = window
        handBack.canvas = canvas
        window.makeFirstResponder(canvas)
        window.settle()
    }

    deinit { MainActor.assumeIsolated { window.close() } }

    /// Begins a walk and waits for its first answer and the band.
    func begin(_ scope: IssueScope = .all, at entry: IssueEntry = .first) {
        walk.begin(scope, at: entry)
        window.spin { !walk.isGathering && !self.bandButtons.isEmpty }
    }

    /// The band's buttons in reading order: ‹, the count, › and Done, in the panel's top strip and not at its leading edge,
    /// where the header's back button is (it goes up into the strip as the band goes).
    var bandButtons: [NSButton] {
        hosting.descendants(NSButton.self).filter { $0.convert($0.bounds, to: hosting).maxY <= 36 && $0.convert($0.bounds, to: hosting).minX > 60 }
            .sorted { $0.convert($0.bounds, to: hosting).minX < $1.convert($1.bounds, to: hosting).minX }
    }

    var hasBand: Bool { !bandButtons.isEmpty }
    var previous: NSButton? { bandButtons.count == 4 ? bandButtons[0] : nil }
    var count: NSButton? { bandButtons.count == 4 ? bandButtons[1] : nil }
    var next: NSButton? { bandButtons.count == 4 ? bandButtons[2] : nil }
    var done: NSButton? { bandButtons.count == 4 ? bandButtons[3] : nil }

    /// The keyboard in a control of the band, as a click or Tab would put it (AppKit's: a standard control takes it from Tab
    /// only with Keyboard navigation on).
    @discardableResult
    func focus(_ button: NSButton?) -> Bool {
        guard let button, window.makeFirstResponder(button) else { return false }
        window.settle()
        return true
    }

    var canvasHasKeyboard: Bool { window.firstResponder === canvas }

    /// The panel's text field in the Issues tab, which the walk chose for the stop.
    var notes: NSTextField? { hosting.descendants(NSTextField.self).first { $0.isEditable && $0.placeholderString == "Notes" } }

    func click(_ button: NSButton?) {
        button?.performClick(nil)
        window.settle()
    }

    /// How strongly the text in a control is drawn, 0 to 1: the most opaque pixel in it (the panel draws on clear in a bitmap, its
    /// text in a color and an opacity of its own, and a dimmed count is a secondary label color, which is fainter).
    func ink(of button: NSButton) -> CGFloat {
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return 1 }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / hosting.bounds.width
        let area = button.convert(button.bounds, to: hosting)
        var strongest: CGFloat = 0
        for y in Int(area.minY * scale)..<Int(area.maxY * scale) {
            for x in Int(area.minX * scale)..<Int(area.maxX * scale) {
                strongest = max(strongest, rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
            }
        }
        return strongest
    }

    /// How many pixels of the band's strip are of a green hue: a chip drawn in its color.
    func green() -> Int {
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return 0 }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        var green = 0
        for y in 0..<36 {
            for x in 0..<Int(hosting.bounds.width) {
                let p = pixel(rep, at: CGPoint(x: x, y: y))
                if p[1] > p[0] + 10, p[1] > p[2] + 10 { green += 1 }
            }
        }
        return green
    }
}

/// Whether a cyan pixel stands near a point of a bitmap of the board: the light is #0B7BB5 (light) or #64D2FF (dark). The
/// selection's accent is blue like it, so a selected shape's outline is read from the model, never from here.
@MainActor private func lit(_ rep: NSBitmapImageRep, around point: CGPoint, reach: Int = 6) -> Bool {
    for dy in -reach...reach {
        for dx in -reach...reach {
            let p = pixel(rep, at: CGPoint(x: point.x + CGFloat(dx), y: point.y + CGFloat(dy)))
            if p[2] > 140, p[1] > p[0] + 40, p[2] > p[1], p[0] < 130 { return true }
        }
    }
    return false
}

/// Cards of the fixture set apart on the root so each outline is its own: A at 40, B at 240, Q at 440, X below A.
@MainActor private func setApart(_ editor: CanvasEditor) {
    let places: [(ShapeID, CGRect)] = [(shapes.a, CGRect(x: 40, y: 40, width: 100, height: 60)), (shapes.b, CGRect(x: 240, y: 40, width: 100, height: 60)),
                                       (shapes.q, CGRect(x: 440, y: 40, width: 100, height: 60)), (shapes.x, CGRect(x: 40, y: 240, width: 100, height: 60))]
    editor.transact("Apart") { t in
        for (id, frame) in places { t.update(id, as: Card.self) { $0.props.frame = frame } }
    }
    editor.outlineStandoff = 0
    editor.camera = Camera(origin: .zero, zoom: 1)
}

/// The lines of a shape's Issues tab, by words: each with the titles of its buttons.
@MainActor private func issueLines(_ h: EditorHarness, of id: ShapeID) throws -> [(says: String, buttons: [String])] {
    let panel = try require(h.editor.detailPanel)
    return panel.layout(for: try require(h.editor.document[id])).statuses(in: .of(IssuesTab.self)).map { ($0.text, $0.actions.map(\.title)) }
}

@MainActor private func action(_ h: EditorHarness, of id: ShapeID, line: Int, button: Int) throws -> DetailStatusAction {
    let panel = try require(h.editor.detailPanel)
    let statuses = panel.layout(for: try require(h.editor.document[id])).statuses(in: .of(IssuesTab.self))
    return try require(statuses[line].actions[button])
}

@MainActor let issueBandTests = Suite("The issue walk's band", [
    test("the band shows while a walk runs and goes with it; it holds ‹, the count, › and Done in reading order, and each is a command") {
        let s = try BandScene()
        expect(!s.hasBand, "no walk, no band")
        s.begin()
        expectEqual(s.bandButtons.count, 4, "‹ 1 of 6 › Done")
        expect(s.previous != nil && s.count != nil && s.next != nil && s.done != nil)
        for command in [CanvasCommand.previousIssue, .nextIssue, .endIssueWalk] {
            expect(s.editor.canPerform(command), "\(command.rawValue) is a menu item for the buttons, so they are out of the ring without a loss")
        }
        s.walk.end()
        s.window.spin { !s.hasBand }
        expect(!s.hasBand, "ending the walk takes the band away")
    },
    test("the buttons step and end the walk: › and ‹ step, Done ends it and the kinds have their tabs back") {
        let s = try BandScene()
        let panel = try require(s.editor.detailPanel)
        panel.choose(.of(CardTab.self), for: Card.kind)
        s.begin()
        expectEqual(s.walk.number, 1)
        expectEqual(panel.chosenTab(for: Card.kind), .of(IssuesTab.self), "the walk chose Issues for the card")
        s.click(s.next)
        expectEqual(s.walk.number, 2, "› steps on")
        s.click(s.next)
        expectEqual(s.walk.number, 3)
        s.click(s.previous)
        expectEqual(s.walk.number, 2, "‹ undoes it")
        s.click(s.done)
        s.window.spin { !s.walk.isRunning }
        expect(!s.walk.isRunning, "Done ends the walk")
        s.window.spin { !s.hasBand }
        expect(!s.hasBand)
        expectEqual(panel.chosenTab(for: Card.kind), .of(CardTab.self), "and gives the tabs back")
    },
    test("the count reads the number of the stop among the stops; after an Ignore the number is kept, the total drops, and the count is drawn dimmed until the next stop takes it") {
        let s = try BandScene()
        s.begin(walkScope("meh"))
        expectEqual(s.walk.currentRow?.shape, shapes.b)
        expectEqual([s.walk.number, s.walk.total], [1, 2])
        let strong = s.ink(of: try require(s.count))
        expect(s.walk.ignoreCurrent())
        s.window.spin { s.walk.currentRow?.state == .ignored }
        expectEqual([s.walk.number, s.walk.total], [1, 1], "12 of 62: the number kept, the total dropped")
        s.window.settle()
        let dimmed = s.ink(of: try require(s.count))
        expect(dimmed < strong - 0.1, "the kept number is drawn dimmed: \(dimmed) against \(strong)")
        s.walk.step(forward: true)
        s.window.spin { s.walk.currentRow?.state == .open }
        expectEqual(s.walk.currentRow?.shape, shapes.d, "› brings the next stop into the number")
        expectEqual([s.walk.number, s.walk.total], [1, 1])
        s.window.settle()
        let again = s.ink(of: try require(s.count))
        expect(abs(again - strong) < 0.05, "and it is drawn strong again: \(again) against \(strong)")
    },
    test("Done pressed with the keyboard on it ends the walk and the canvas has the keyboard, never the window") {
        let s = try BandScene()
        s.begin()
        expect(s.focus(s.done), "the keyboard on Done")
        expect(!s.canvasHasKeyboard)
        let output = standardError(during: {
            s.click(s.done)
            s.window.spin { !s.walk.isRunning && !s.hasBand }
            s.window.spin { s.canvasHasKeyboard }
        })
        expect(s.canvasHasKeyboard, "the band went with the keyboard in it: the canvas has it, not the window (\(String(describing: s.window.firstResponder)))")
        expect(s.exits > 0, "the panel gave it back")
        expect(!output.contains("AttributeGraph"), "Done turned its own command off with the keyboard on it: \(output)")
    },
    test("‹ with the keyboard on it while a gesture begins on the canvas: it keeps the keyboard, does nothing, and is dimmed once the keyboard leaves") {
        let s = try BandScene()
        s.begin()
        let previous = try require(s.previous)
        expect(s.focus(previous), "the keyboard on ‹")
        let place = s.walk.number
        let output = standardError(during: {
            s.editor.session = IdleGesture()
            s.window.settle()
            s.window.settle()
        })
        expect(!s.walk.canStep && !s.editor.canPerform(.previousIssue), "the gesture turns the step off")
        expect(s.window.firstResponder === previous, "the keyboard stays on ‹, not the window (\(String(describing: s.window.firstResponder)))")
        expect(previous.isEnabled, "‹ is not dimmed under the keyboard")
        s.click(previous)
        expectEqual(s.walk.number, place, "and its press does nothing")
        expect(!output.contains("AttributeGraph"), "no cycle while the keyboard is on a button whose command turned off: \(output)")
        // The keyboard leaves it: it is dimmed as its command is.
        expect(s.window.makeFirstResponder(s.canvas))
        s.window.settle()
        s.window.settle()
        expect(!previous.isEnabled, "‹ is dimmed once the keyboard is gone")
        s.editor.session = nil
        s.window.settle()
        expect(previous.isEnabled, "and enabled again with the command")
    },
    test("the count is a button: a click toggles the walk's list state") {
        let s = try BandScene()
        s.begin()
        expect(!s.walk.isListOpen)
        s.click(s.count)
        expect(s.walk.isListOpen, "a click opens the list")
        s.click(s.count)
        expect(!s.walk.isListOpen, "and a click closes it")
        // Return with the count focused toggles it once a press (`onKeyPress`: a button answers Space, and Return only as the default).
        // SwiftUI focus, which the key press needs, reaches the band's buttons only with Keyboard navigation on; with it off the
        // key is unverified here, and the click holds the toggle.
        if s.keys.keyboardNavigation {
            expect(s.focus(s.count), "the keyboard on the count")
            s.window.press(.return)
            s.window.settle()
            expect(s.walk.isListOpen, "Return opens it")
            s.window.press(.return)
            s.window.settle()
            expect(!s.walk.isListOpen, "and Return closes it")
        } else {
            FileHandle.standardError.write(Data("skipped: Return on the band's count (Keyboard navigation is off; the click holds the toggle)\n".utf8))
        }
    },
    test("the count runs Issue List as the band's other buttons run their commands: it does nothing while the command is disabled") {
        let s = try BandScene()
        s.begin()
        let count = try require(s.count)
        expect(count.isEnabled && s.editor.canPerform(.issueList))
        // Shapes waiting to be placed turn Issue List and the steps off.
        let slab = AnyShapeRecord(ShapeRecord(Card(CGRect(x: 0, y: 0, width: 40, height: 30), text: "fine")))
        expect(s.editor.placeLater(PendingPlacement([slab], stepName: "Add") { _ in [.zero] }))
        expect(!s.editor.canPerform(.issueList) && !s.editor.canPerform(.nextIssue), "the commands are off")
        s.window.settle()
        // (Whether the band is drawn dimmed follows observed state, which waiting shapes are not, for ‹ and › as for the count: the
        // other takeover's test holds the dimming.)
        s.click(s.count)
        expect(!s.walk.isListOpen, "a click opens nothing")
        if s.keys.keyboardNavigation {
            expect(s.focus(s.count), "the keyboard on the count")
            s.window.press(.return)
            s.window.settle()
            expect(!s.walk.isListOpen, "and Return opens nothing")
        }
    },
    test("the list open while shapes wait to be placed: Issue List and the count close it, and opening it stays refused while they wait") {
        let s = try BandScene()
        s.openList()
        expect(s.walk.isListOpen)
        let slab = AnyShapeRecord(ShapeRecord(Card(CGRect(x: 0, y: 0, width: 40, height: 30), text: "fine")))
        expect(s.editor.placeLater(PendingPlacement([slab], stepName: "Add") { _ in [.zero] }))
        expect(s.walk.isListOpen, "the shapes waiting do not close the list")
        expect(!s.walk.canStep, "no step now")
        expect(s.walk.canToggleList && s.editor.canPerform(.issueList), "closing is not refused")
        expect(s.editor.perform(.issueList))
        expect(!s.walk.isListOpen, "the command closes the list")
        expect(s.editor.isPlacingLater, "they wait still")
        expect(!s.walk.canToggleList && !s.editor.canPerform(.issueList), "and opening it is refused")
        expect(!s.editor.perform(.issueList) && !s.walk.isListOpen, "the key opens nothing")
    },
    test("the band while the first answer comes has no count, and the count is named by its place for VoiceOver") {
        let s = try BandScene()
        // A scope that gives no candidates is gathered by the query: asked of the engine off the main actor, so the band is up first.
        s.walk.begin(.all, at: .first)
        expect(s.walk.isGathering, "the first answer is on its way")
        expectEqual(s.walk.number, nil, "no number yet")
        s.window.spin { !s.walk.isGathering && !s.bandButtons.isEmpty }
        expectEqual(s.bandButtons.count, 4, "and the count comes with the answer")
        // SwiftUI gives an unshown window's buttons an accessibility element only with Keyboard navigation on.
        if s.keys.keyboardNavigation {
            let label = try require(s.count).accessibilityLabel()
            expectEqual(label, "\(s.walk.number ?? 0) of \(s.walk.total)", "named for VoiceOver by its place")
        }
    },
    test("a scope's chip is drawn in its color beside the title; a scope without one draws the title alone") {
        let s = try BandScene()
        s.begin()
        s.window.settle()
        expectEqual(s.green(), 0, "All Issues has no chip")
        expectEqual(s.walk.scope?.label(s.editor), IssueScopeLabel("All Issues"))
        let chip = IssueScopeChip("Vote", swatch: Swatch(RGB(hex: 0x2E7D32)))
        let ruled = IssueScope(id: "ruled", includes: { $0.source?.key == "meh" },
                               label: { _ in IssueScopeLabel("Rule 1", owner: shapes.q, spoken: "Rule 1 of Vote", chip: chip) },
                               candidates: { _ in [shapes.b, shapes.d] })
        s.begin(ruled)
        s.window.settle()
        expect(s.green() > 20, "the chip is drawn in its color: \(s.green()) green pixels")
        expectEqual(s.walk.scope?.label(s.editor)?.spoken, "Rule 1 of Vote")
        s.begin()
        s.window.settle()
        expectEqual(s.green(), 0, "and back to none")
    },
    test("Escape goes one level out of the panel's content: to the band with Keyboard navigation on, which has a control the keys reach, else to the canvas; from the band to the canvas, the walk going on; ⌘. there ends it") {
        let s = try BandScene()
        s.begin()
        s.window.spin { s.notes != nil }
        s.window.focus(try require(s.notes))
        expect(s.editor.detailPanel?.keyboardPlace == .content)
        s.keys.press(.escape)
        if s.keys.keyboardNavigation {
            s.window.spin { s.editor.detailPanel?.keyboardPlace == .band }
            expect(s.editor.detailPanel?.keyboardPlace == .band, "the band has the keyboard first: \(s.keys.traceText)")
            expect(!s.canvasHasKeyboard)
            expect(s.walk.isRunning && s.hasBand, "the walk goes on, the band stays")
            s.keys.press(.escape)
            s.window.spin { s.canvasHasKeyboard }
            expect(s.canvasHasKeyboard, "Escape from the band goes to the canvas: \(s.keys.traceText)")
            expect(s.walk.isRunning && s.hasBand, "the walk goes on, the band stays")
            s.focus(s.next)
            s.keys.press(.commandPeriod)
            s.window.spin { !s.walk.isRunning }
            expect(!s.walk.isRunning, "⌘. in the band ends the walk: \(s.keys.traceText)")
            expect(s.canvasHasKeyboard, "and gives the canvas the keyboard")
        } else {
            // The band's buttons take no key: the key is never dead, it goes on to the canvas, the walk going on.
            s.window.spin { s.canvasHasKeyboard }
            expect(s.canvasHasKeyboard, "the band has no control the keys reach, so Escape goes on to the canvas: \(s.keys.traceText)")
            expect(s.walk.isRunning && s.hasBand, "the walk goes on, the band stays")
            expect(s.exits > 0)
            // Where the keyboard is in the band (by a click, say), it is the band's place.
            expect(s.focus(s.next))
            expect(s.editor.detailPanel?.keyboardPlace == .band)
        }
    },
    test("⌘. in the panel's content ends the walk too, as hiding the inspector does: the host runs the band's cancel") {
        let s = try BandScene()
        s.begin()
        s.window.spin { s.notes != nil }
        s.window.focus(try require(s.notes))
        s.keys.press(.commandPeriod)
        s.window.spin { !s.walk.isRunning }
        expect(!s.walk.isRunning, "⌘. ends it: \(s.keys.traceText)")
        s.begin()
        let inspector = try require(s.editor.registry.hostInspector)
        expect(inspector.isRequested(s.editor), "a band keeps the inspector requested")
        inspector.onDismiss(s.editor)
        expect(!s.walk.isRunning, "hiding the inspector ends the walk")
        expect(!inspector.isRequested(s.editor))
    },
    test("with Keyboard navigation on the band's stops are walked by Tab and ⇧Tab in reading order, the exact way back, named for VoiceOver; with it off they leave the ring") {
        let s = try BandScene()
        s.begin()
        s.window.spin { s.notes != nil }
        if s.keys.keyboardNavigation {
            s.focus(s.previous)
            let cycle = s.keys.expectCycle(inOrder: ["window/Previous Issue", "window/1 of 6", "window/Next Issue", "window/Done"], wraps: .closed)
            s.keys.expectShows(Array(cycle.stops))
        } else {
            // A standard control is out of Tab: it leaves the ring.
            s.window.focus(try require(s.notes))
            for _ in 0..<12 {
                let id = s.keys.press(.tab).id
                expect(!(s.window.firstResponder is NSButton), "Tab never lands on a band button without Keyboard navigation: \(id)")
            }
        }
    },
    test("the light: the walk's other stops on the board shown, cyan, while the keyboard is in the band; none on the current stop, none once the keyboard leaves, none on another board") {
        let s = try BandScene()
        setApart(s.editor)
        s.begin()
        expectEqual(s.walk.currentRow?.shape, shapes.a)
        expectEqual(s.editor.outlines.tinted, [], "the keyboard is on the canvas: no light")
        let size = CGSize(width: 700, height: 500)
        let bTop = CGPoint(x: 290, y: 40)
        expect(!lit(renderBitmap(s.editor, size: size), around: bTop), "B is not lit")
        expect(s.focus(s.next), "the keyboard in the band")
        s.window.spin { s.editor.issueLights?.isLit == true }
        let tinted = s.editor.outlines.tinted
        expectEqual(tinted.count, 1)
        expectEqual(tinted.first?.shapes, [shapes.b, shapes.link], "the other open stops of the board shown: B and the link; A is current, C and D are on the pocket's board")
        expectEqual(tinted.first?.color, IssueWalkStyle.light)
        let rep = renderBitmap(s.editor, size: size)
        expect(lit(rep, around: bTop), "B's outline is cyan: \(pixel(rep, at: bTop))")
        expect(!lit(rep, around: CGPoint(x: 490, y: 40)), "Q is no stop: not lit")
        expect(!lit(rep, around: CGPoint(x: 90, y: 240)), "nor X, which has no issue")
        // The walk moves: B is current now and A is lit.
        s.walk.step(forward: true)
        s.window.spin { s.editor.outlines.tinted.first?.shapes == [shapes.a, shapes.link] }
        expectEqual(s.editor.outlines.tinted.first?.shapes, [shapes.a, shapes.link])
        expect(!lit(renderBitmap(s.editor, size: size), around: bTop), "B is the current stop now: not lit")
        // The keyboard leaves for the canvas: the light goes.
        s.window.makeFirstResponder(s.canvas)
        s.window.spin { s.editor.issueLights?.isLit == false }
        expectEqual(s.editor.outlines.tinted, [])
        expect(!lit(renderBitmap(s.editor, size: size), around: CGPoint(x: 90, y: 40)), "none once the keyboard leaves")
        // Another board: with the pocket's board shown the stops there are lit, and the root's are not.
        s.focus(s.next)
        s.walk.step(forward: true)
        s.walk.step(forward: true)
        expectEqual(s.walk.currentRow?.shape, shapes.c)
        expectEqual(s.editor.board, BoardID(owner: shapes.pocket))
        s.window.spin { s.editor.outlines.tinted.first?.shapes == [shapes.d] }
        expectEqual(s.editor.outlines.tinted.first?.shapes, [shapes.d], "the board shown's other stop, and none from the root")
        // The walk ends: no light.
        s.walk.end()
        s.window.spin { s.editor.issueLights?.isLit == false }
        expectEqual(s.editor.outlines.tinted, [])
    },
    test("the light is off while the keyboard is in the panel's content, the list state open or not") {
        let s = try BandScene()
        setApart(s.editor)
        s.begin()
        expect(s.focus(s.next), "the keyboard in the band")
        s.window.spin { s.editor.issueLights?.isLit == true }
        s.window.spin { s.notes != nil }
        s.window.focus(try require(s.notes))
        expect(s.editor.detailPanel?.keyboardPlace == .content)
        s.window.spin { s.editor.issueLights?.isLit == false }
        expectEqual(s.editor.outlines.tinted, [], "the content has the keyboard: no light, the list state or not")
        s.walk.isListOpen = true
        s.window.settle()
        expectEqual(s.editor.outlines.tinted, [], "an open list state alone lights nothing: the light goes with a takeover holding the keyboard")
    },
    test("an ignored row is never lit, and an undo lights it again; a stop whose shape goes leaves the light") {
        let s = try BandScene()
        setApart(s.editor)
        s.begin(.all, at: .shape(shapes.b))
        expect(s.focus(s.next))
        s.window.spin { s.editor.issueLights?.isLit == true }
        expectEqual(s.editor.outlines.tinted.first?.shapes, [shapes.a, shapes.link])
        // Ignore B (the current stop), then go on to the link: B is a row that is no stop.
        expect(s.walk.ignoreCurrent())
        s.walk.step(forward: true)
        s.window.spin { s.editor.outlines.tinted.first?.shapes == [shapes.a] }
        expectEqual(s.editor.outlines.tinted.first?.shapes, [shapes.a], "B reads ignored: not lit")
        s.editor.undo()
        s.window.spin { s.editor.outlines.tinted.first?.shapes == [shapes.a, shapes.b] }
        expectEqual(s.editor.outlines.tinted.first?.shapes, [shapes.a, shapes.b], "an undo brings the stop back, and its light")
        s.editor.transact("Delete") { $0.delete([shapes.a]) }
        s.window.spin { s.editor.outlines.tinted.first?.shapes == [shapes.b] }
        expectEqual(s.editor.outlines.tinted.first?.shapes, [shapes.b], "a deleted shape's stop goes")
    },
    test("one tinted group in the one light, and no lights at all without the band's plugin") {
        let s = try BandScene()
        setApart(s.editor)
        s.begin()
        expect(s.focus(s.next))
        s.window.spin { s.editor.issueLights?.isLit == true }
        expectEqual(s.editor.outlines.tinted.map(\.color), [IssueWalkStyle.light], "one tinted group, in the one light")
        // The same plugins without the walk's panel have no lights.
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), ValidationPlugin(), IssueWalkPlugin()])
        expect(h.editor.issueLights == nil)
    },
    test("the walk's views are a plugin of their own: the report names the band and the light, and a list without the panel refuses it") {
        let registry = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), ValidationPlugin(),
                                              DetailPanelPlugin(), IssueWalkPlugin(), IssueWalkPanelPlugin()])
        let line = registry.report.split(separator: "\n").first { $0.hasPrefix("issue-walk-panel") }
        expect(line?.contains("detail band") == true && line?.contains("service IssueLights") == true && line?.contains("outlines") == true, "\(line ?? "no line")")
        expectThrows(RegistryError.ownerNotInstalled(point: "DetailBands", owner: .detailPanel, contributor: "issue-walk-panel")) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), ValidationPlugin(), IssueWalkPlugin(),
                                       IssueWalkPanelPlugin()])
        }
    },
    test("a warning line of a rule that knows its shapes says where its walk would begin, after its own buttons: \"1 of 2\", the shape's place in board order") {
        let h = try walkTestHarness()
        expectEqual(try issueLines(h, of: shapes.b).map(\.says), ["It's so-so."])
        expectEqual(try issueLines(h, of: shapes.b).first?.buttons, ["Ignore", "1 of 2"], "B is first among the shapes the rule flags")
        h.enter(shapes.pocket)
        let d = try issueLines(h, of: shapes.d)
        expectEqual(d.map(\.says), ["It's bad.", "It's so-so."])
        expectEqual(d[0].buttons, [], "a rule that does not know its shapes gives no place")
        expectEqual(d[1].buttons, ["Ignore", "2 of 2"], "D comes after B, on the board under the root")
        h.editor.showBoard(.root)
        expectEqual(try issueLines(h, of: shapes.link).first?.buttons, [], "an issue with no source has none")
    },
    test("a click on the line begins the rule's walk at its shape; with that walk running it goes to the shape's stop, and the walk's current stop has no such button") {
        let h = try walkTestHarness()
        let walk = try require(h.editor.issueWalk)
        h.enter(shapes.pocket)
        try action(h, of: shapes.d, line: 1, button: 1).perform()
        expect(walk.isRunning)
        expectEqual(walk.scope?.id, "meh")
        expectEqual(walk.currentRow?.shape, shapes.d, "begun at D")
        expectEqual(walk.number, 2)
        expectEqual(try issueLines(h, of: shapes.d)[1].buttons, ["Ignore"], "the band says it: no button on the current stop's line")
        h.editor.showBoard(.root)
        expectEqual(try issueLines(h, of: shapes.b).first?.buttons, ["Ignore", "1 of 2"], "the walk's own place")
        try action(h, of: shapes.b, line: 0, button: 1).perform()
        expectEqual(walk.currentRow?.shape, shapes.b, "the click goes to B's stop")
        expectEqual(walk.number, 1)
        expectEqual(h.editor.selectedShapeIDs, [shapes.b])
        expectEqual(try issueLines(h, of: shapes.b).first?.buttons, ["Ignore"], "now it is the current stop")
        h.enter(shapes.pocket)
        expectEqual(try issueLines(h, of: shapes.d)[1].buttons, ["Ignore", "2 of 2"], "and D has it again")
        walk.end()
        expectEqual(try issueLines(h, of: shapes.d)[1].buttons, ["Ignore", "2 of 2"], "the walk ended: the place among the shapes")
    },
    test("with a walk of another scope running, the line's button begins its own scope's walk") {
        let h = try walkTestHarness()
        let walk = try require(h.editor.issueWalk)
        walk.begin(.all, at: .first)
        spinRunLoop(until: { !walk.isGathering })
        expectEqual(walk.scope?.id, "all")
        try action(h, of: shapes.b, line: 0, button: 1).perform()
        expectEqual(walk.scope?.id, "meh", "the rule's walk replaces the walk of everything")
        expectEqual(walk.currentRow?.shape, shapes.b)
    },
    test("the current stop's line has no place button whichever walk runs: an All Issues walk's stop would be replaced by the rule's walk") {
        let h = try walkTestHarness()
        let walk = try require(h.editor.issueWalk)
        walk.begin(.all, at: .shape(shapes.b))
        spinRunLoop(until: { !walk.isGathering })
        expectEqual(walk.scope?.id, "all")
        expectEqual(walk.currentRow?.shape, shapes.b)
        expectEqual(try issueLines(h, of: shapes.b).first?.buttons, ["Ignore"], "the band says where it is")
        h.enter(shapes.pocket)
        expectEqual(try issueLines(h, of: shapes.d)[1].buttons, ["Ignore", "2 of 2"], "another stop's line still has its place")
        walk.end()
    },
    test("a line's button decides when it is clicked: one drawn before the walk began goes to the stop, one drawn while it ran begins the walk again once it has ended") {
        let h = try walkTestHarness()
        let walk = try require(h.editor.issueWalk)
        // Drawn with no walk running: its title is the same as the walk's will be ("1 of 2"), so the line keeps this closure.
        let before = try action(h, of: shapes.b, line: 0, button: 1)
        expectEqual(before.title, "1 of 2")
        h.enter(shapes.pocket)
        try action(h, of: shapes.d, line: 1, button: 1).perform()
        expectEqual(walk.currentRow?.shape, shapes.d, "the walk is begun at D")
        let runs = walk.number
        // The old closure goes to B's stop of the walk running, not beginning another.
        before.perform()
        expectEqual(walk.currentRow?.shape, shapes.b, "it goes to B's stop")
        expectEqual(walk.scope?.id, "meh")
        expectEqual([runs, walk.number], [2, 1])
        // Drawn while the walk ran and B was not its current stop: after the walk ends it begins it.
        h.enter(shapes.pocket)
        let during = try action(h, of: shapes.d, line: 1, button: 1)
        walk.end()
        expect(!walk.isRunning)
        during.perform()
        expect(walk.isRunning, "a click on a line drawn during a walk that has ended begins the rule's walk")
        expectEqual(walk.currentRow?.shape, shapes.d)
    },
    test("a walk of the rule under an id of its own (a rule reworded keeps the id it began with) is still that rule's walk to the line") {
        let h = try walkTestHarness()
        let walk = try require(h.editor.issueWalk)
        let reworded = IssueScope(id: "meh as it began", includes: { $0.source?.key == "meh" }, label: { _ in IssueScopeLabel("Rule 1") },
                                  candidates: { _ in [shapes.b, shapes.d] })
        walk.begin(reworded, at: .first)
        expectEqual(walk.currentRow?.shape, shapes.b)
        h.enter(shapes.pocket)
        let d = try issueLines(h, of: shapes.d)[1]
        expectEqual(d.buttons, ["Ignore", "2 of 2"], "the walk's place")
        try action(h, of: shapes.d, line: 1, button: 1).perform()
        expectEqual(walk.scope?.id, "meh as it began", "the walk goes on, not begun anew")
        expectEqual(walk.currentRow?.shape, shapes.d)
        expectEqual(walk.number, 2)
    },
    test("the place follows the shapes the rule flags: a new one, one ignored and one deleted change it, an undo brings it back, a move keeps it") {
        let h = try walkTestHarness()
        @MainActor func buttons(_ id: ShapeID) throws -> [String]? {
            let all = try issueLines(h, of: id)
            return all.first(where: { $0.says == "It's so-so." })?.buttons
        }
        expectEqual(try buttons(shapes.b), ["Ignore", "1 of 2"])
        // A new shape that says meh: on the root, so before the pocket's board.
        let frame = CGRect(x: 300, y: 300, width: 100, height: 60)
        let n = h.add(Card(frame, text: "meh"))
        expectEqual(try buttons(shapes.b), ["Ignore", "1 of 3"], "a new candidate: the total follows")
        expectEqual(try buttons(n), ["Ignore", "2 of 3"], "in board order")
        // Not a candidate's change: another card edited keeps every place.
        h.editor.transact("Edit") { $0.update(shapes.q, as: Card.self) { $0.props.text = "fine!" } }
        expectEqual(try buttons(n), ["Ignore", "2 of 3"])
        // The first is ignored (by its Ignore): it is no candidate, the others' places close up.
        try action(h, of: shapes.b, line: 0, button: 0).perform()
        expectEqual(try buttons(n), ["Ignore", "1 of 2"], "ignored, B leaves the set")
        h.editor.undo()
        expectEqual(try buttons(n), ["Ignore", "2 of 3"], "and an undo brings it back")
        h.editor.transact("Delete") { $0.delete([shapes.b]) }
        expectEqual(try buttons(n), ["Ignore", "1 of 2"], "a deleted candidate leaves")
        h.editor.undo()
        h.editor.transact("Move") { $0.update(n, as: Card.self) { $0.props.frame = frame.offsetBy(dx: 10, dy: 0) } }
        expectEqual(try buttons(n), ["Ignore", "2 of 3"], "a move changes no order")
        // A restack changes the order and not the set: the place is made again.
        h.editor.transact("Front") { $0.bringToFront(shapes.b) }
        expectEqual(try buttons(shapes.b), ["Ignore", "2 of 3"], "a restack puts B after N")
        expectEqual(try buttons(n), ["Ignore", "1 of 3"])
        h.editor.undo()
        expectEqual(try buttons(shapes.b), ["Ignore", "1 of 3"], "and its undo puts it back")
        // A file put in place lets go of the kept lists: the places are the new file's.
        let other = try require(h.editor.issueWalk)
        h.editor.replaceFile(with: h.editor.file)
        expectEqual(try buttons(n), ["Ignore", "2 of 3"], "a file put in place is read again")
        _ = other
    },
    test("a frame put in a frame changes the places of the flagged shapes inside it, though no flagged shape was changed and nothing was restacked") {
        let (g, x, f, y) = (walkID(21), walkID(23), walkID(24), walkID(25))
        let h = try walkTestHarness(file: walkRootFile([(21, nil), (22, "fine"), (23, "meh"), (24, nil), (25, "meh")]), more: [CorralsPlugin()])
        @MainActor func buttons(_ id: ShapeID) throws -> [String]? {
            let all = try issueLines(h, of: id)
            return all.first(where: { $0.says == "It's so-so." })?.buttons
        }
        h.editor.put([y], in: f)
        expectEqual(try buttons(x), ["Ignore", "1 of 2"], "X is on the board directly, before the frame that holds Y")
        expectEqual(try buttons(y), ["Ignore", "2 of 2"])
        // F is above G already, so nothing is restacked; F is not flagged, and neither is G. Y's place is G, F, Y now.
        h.editor.put([f], in: g)
        expectEqual(try buttons(y), ["Ignore", "1 of 2"], "Y is inside G now, which comes before X")
        expectEqual(try buttons(x), ["Ignore", "2 of 2"])
        h.editor.undo()
        expectEqual(try buttons(x), ["Ignore", "1 of 2"])
        expectEqual(try buttons(y), ["Ignore", "2 of 2"])
    },
])

import AppKit

// What a user does, and how it's fed to a canvas view and captured. This file is compiled twice:
// into CompositionTests, and by scripts/record-poc-fixtures.sh against the untouched POC (804db97),
// which records Fixtures/ with it. So the goldens and the replay see exactly the same events and
// captures. Keep it to AppKit: it can't name either canvas's types.

enum Step {
    case tool(Character)             // a tool's key
    case move(CGFloat, CGFloat)
    case down(CGFloat, CGFloat, clicks: Int)
    case drag(CGFloat, CGFloat)
    case dragPath(CGFloat, CGFloat, speed: CGFloat)
    case up
    case wait(Int)                   // ms
    case flags(NSEvent.ModifierFlags)
    case delete                      // the Delete key
    case escape                      // the Escape key
    // Not events: each canvas does these itself.
    case selectArrow(Int)
    case selectShape(Int)
    case zoom(CGFloat, around: CGPoint)
}

let A = CGRect(x: 80, y: 80, width: 200, height: 200)
let B = CGRect(x: 460, y: 80, width: 200, height: 200)
let fast: CGFloat = 3, slow: CGFloat = 0.1

/// The arrow's end handle pressed: the arrow selected, the pointer at B's center, where the end is
/// bound.
let pressEnd: [Step] = [.selectArrow(0), .move(560, 180), .down(560, 180, clicks: 1)]

/// Replayed on two empty notes (plus an arrow between their centers, with this bend, if given);
/// Fixtures/arrow-transcript.txt says where every arrow ended up.
let scenarios: [(String, withArrow: CGFloat?, [Step])] = [
    ("bend", 0, [.selectArrow(0), .move(364.125, 180), .down(364.125, 180, clicks: 1), .drag(364.125, 250), .drag(360, 260), .up]),
    ("toggle head", 0, [.selectArrow(0), .move(560, 180), .down(560, 180, clicks: 2), .up]),
    ("re-aim end slowly", 0, [.selectArrow(0), .move(560, 180), .down(560, 180, clicks: 1), .dragPath(600, 150, speed: slow), .up]),
    ("re-aim end off shape", 0, [.selectArrow(0), .move(560, 180), .down(560, 180, clicks: 1), .dragPath(760, 400, speed: fast), .up]),
    ("translate arrow", 0, [.move(364, 180), .down(364, 180, clicks: 1), .drag(364, 200), .drag(364, 230), .up]),
    ("translate arrow off", 0, [.move(364, 180), .down(364, 180, clicks: 1), .drag(364, 200), .drag(364, 520), .up]),
    ("delete bent", 70, [.selectShape(1), .delete]),
    ("move shape", 0, [.move(100, 100), .down(100, 100, clicks: 1), .drag(140, 150), .drag(150, 170), .up]),
    // Appended later (scenarios are only ever appended, and recorded from the POC), to hold arrow
    // translation and pressing to the POC before the select tool learned multi-selection.
    ("translate arrow off and back", 0, [.move(364, 180), .down(364, 180, clicks: 1), .drag(364, 200), .drag(364, 520), .drag(364, 210), .up]),
    ("translate arrow, fractional", 0, [.move(364.5, 180.25), .down(364.5, 180.25, clicks: 1), .drag(366.75, 203.5), .drag(371.125, 229.875), .up]),
    // View (338.4, 188) is world (364, 180) at this zoom.
    ("translate arrow, zoomed", 0, [.zoom(0.6, around: CGPoint(x: 300, y: 200)), .move(338.4, 188), .down(338.4, 188, clicks: 1), .drag(338.4, 200.5), .drag(341.2, 221.7), .up]),
    ("click arrow body", 0, [.move(364, 180), .down(364, 180, clicks: 1), .up]),
    ("arrow drag under threshold", 0, [.move(364, 180), .down(364, 180, clicks: 1), .drag(366, 181), .up]),
    ("move bound shape", 0, [.move(600, 250), .down(600, 250, clicks: 1), .drag(640, 300), .drag(650, 320), .up]),
    // The end re-aimed off B, then the arrow moved by a press on its body: (500, 301.4) is on the
    // new line, 32 points from its middle handle.
    ("translate arrow with a free end", 0, [.selectArrow(0), .move(560, 180), .down(560, 180, clicks: 1), .dragPath(760, 400, speed: fast), .up,
                                            .move(500, 301.4), .down(500, 301.4, clicks: 1), .drag(500, 321.4), .drag(520, 341.4), .up]),
    // Appended when the arrow tool was retired, which took the scenarios that drew with it: its
    // drag, the one a port's connection is drawn with now, is held to the POC by re-aiming the end
    // the same ways, out of B over empty canvas and back. What only the tool did (aiming by hovering
    // before the press, or holding still after it) went with it.
    ("re-aim: fast into B", 0, pressEnd + [.dragPath(400, 120, speed: fast), .dragPath(500, 120, speed: fast), .up]),
    ("re-aim: slow into B", 0, pressEnd + [.dragPath(400, 120, speed: fast), .dragPath(500, 120, speed: slow), .up]),
    ("re-aim: dwell in B", 0, pressEnd + [.dragPath(440, 120, speed: fast), .drag(500, 120), .wait(400), .up]),
    // Released 208 ms after slowing into B: precise by pointer speed alone, before the 320 ms timer
    // could make it so (in "re-aim: slow into B" the timer fires too).
    ("re-aim: slow into B, quick release", 0, pressEnd + [.dragPath(400, 120, speed: fast), .dragPath(480, 120, speed: slow), .up]),
    ("re-aim: option", 0, pressEnd + [.flags(.option), .dragPath(500, 120, speed: fast), .up, .flags([])]),
    ("re-aim: command", 0, pressEnd + [.flags(.command), .dragPath(500, 120, speed: fast), .up, .flags([])]),
    ("re-aim: shift", 0, pressEnd + [.flags(.shift), .dragPath(380, 210, speed: fast), .up, .flags([])]),
    ("re-aim: release option with mouse", 0, pressEnd + [.flags(.option), .dragPath(500, 120, speed: fast), .flags([]), .wait(20), .up]),
    // Out of B and back with ⌥ held, so the end came to B aiming precisely: let go of ⌥, it stays
    // precise. (Kept on B, only the 320 ms timer from the press would make it so, and the POC's
    // timers run on real time.)
    ("re-aim: release option alone", 0, pressEnd + [.flags(.option), .dragPath(400, 120, speed: fast), .dragPath(500, 120, speed: fast), .flags([]),
                                                    .wait(300), .up]),
    ("re-aim: center snap", 0, pressEnd + [.dragPath(400, 170, speed: fast), .dragPath(570, 170, speed: slow), .up]),
    ("re-aim: escape mid-drag", 0, pressEnd + [.dragPath(300, 180, speed: fast), .escape, .up]),
    // The start made precise in A by holding still there, then the end brought into A: precise
    // too, and nudged off the start's anchor.
    ("re-aim: back into the start's shape", 0, [.selectArrow(0), .move(180, 180), .down(180, 180, clicks: 1), .dragPath(330, 300, speed: fast),
                                                .dragPath(130, 130, speed: fast), .wait(400), .up,
                                                .move(560, 180), .down(560, 180, clicks: 1), .dragPath(380, 130, speed: fast), .dragPath(130, 130, speed: fast), .up]),
    // The app pans with the Hand tool (H); the POC's select tool panned on empty canvas, and its
    // insertText ignores "h". Holding still for 100 ms lets the app's pointer velocity decay to 0
    // (about (0.94, 0.63) pt/ms × 0.5^7.25 < 0.01 per axis), so no slide moves the camera off the
    // golden. The POC runs no timer while panning: the wait changes nothing there. V is Select in
    // both. Panned by (40, 30), the end's handle is at (600, 210) in the view, and (800, 430) is
    // (760, 400) on the board.
    ("pan, then re-aim", 0, [.tool("h"), .move(380, 500), .down(380, 500, clicks: 1), .drag(400, 520), .drag(420, 530), .wait(100), .up,
                             .tool("v"), .selectArrow(0), .move(600, 210), .down(600, 210, clicks: 1), .dragPath(800, 430, speed: fast), .up]),
]

/// The notes' text in `interactions`, which the POC's fixtures were recorded with (the render
/// script, scripts/poc-fixtures/render, uses it too), so it never changes.
let noteTexts = ("Start here", "End here")

/// Arrow hints, outlines and handles mid-interaction, each captured to Fixtures/poc-<name>.png
/// where the steps leave off (the button still down, where it's still down). The POC's timers run
/// on real time, so no state depends on whether one has fired yet.
let interactions: [(String, withArrow: CGFloat?, [Step])] = [
    ("hovered-handle", 0, [.selectArrow(0), .move(560, 180)]),
    // Pressed without hovering first: the halo is the press's, and B is outlined as the end's shape.
    ("pressed-handle", 0, [.selectArrow(0), .down(560, 180, clicks: 1)]),
    // Appended when the arrow tool was retired, in place of the states it drew in: the same
    // hints, reached by re-aiming the end.
    // The end re-aimed, having slowed down inside B (precise at once): B's outline, a dot and
    // dashed stub at the start, a cross and dashed stub at the end.
    ("re-aiming-into-b", 0, pressEnd + [.dragPath(400, 120, speed: fast), .dragPath(500, 120, speed: slow)]),
    // Re-aimed with ⌥ held: the end exact, so the arrow runs into B and it gets no hint.
    ("re-aiming-exact", 0, pressEnd + [.flags(.option), .dragPath(500, 120, speed: fast)]),
    // "re-aim: release option alone", zoomed out past 20% and 25%: an imprecise start (a dot and
    // an undashed stub), a precise end (a cross and an undashed stub), and shrunken handles.
    ("re-aimed-zoomed-out", 0, pressEnd + [.flags(.option), .dragPath(400, 120, speed: fast), .dragPath(500, 120, speed: fast), .flags([]),
                                            .wait(300), .up, .move(900, 700), .zoom(0.15, around: CGPoint(x: 370, y: 180))]),
]

/// Feeds steps to a canvas view in an unshown 1000×800 window as real NSEvents, with timestamps
/// that advance with every wait, so pointer speed is what a user's would be. `wait` runs timers
/// for that long (real time for the POC, a manual clock in tests); `direct` does the steps that
/// aren't events.
@MainActor
final class Player {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
    let view: NSView
    private let wait: @MainActor (Int) -> Void
    private let direct: @MainActor (Step) -> Void
    private var time: TimeInterval = 100
    private var flags: NSEvent.ModifierFlags = []
    private var pointer = CGPoint.zero

    init(_ view: NSView, wait: @escaping @MainActor (Int) -> Void, direct: @escaping @MainActor (Step) -> Void) {
        self.view = view
        self.wait = wait
        self.direct = direct
        window.contentView = view
    }

    func play(_ steps: [Step]) {
        for step in steps { play(step) }
    }

    func sleep(_ ms: Int) {
        time += Double(ms) / 1000
        wait(ms)
    }

    private func mouse(_ type: NSEvent.EventType, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: pointer.x, y: 800 - pointer.y), modifierFlags: flags, timestamp: time,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    /// A key pressed, with the modifiers held: the POC's canvas hands it to AppKit's key bindings,
    /// today's to its shortcuts.
    private func key(_ characters: String, code: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: time, windowNumber: window.windowNumber, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func drag(to point: CGPoint) {
        sleep(16)
        pointer = point
        view.mouseDragged(with: mouse(.leftMouseDragged))
    }

    func play(_ step: Step) {
        switch step {
        case .tool(let character): view.keyDown(with: key(String(character)))
        case .move(let x, let y): sleep(16); pointer = CGPoint(x: x, y: y); view.mouseMoved(with: mouse(.mouseMoved, clicks: 0))
        case .down(let x, let y, let clicks): sleep(16); pointer = CGPoint(x: x, y: y); view.mouseDown(with: mouse(.leftMouseDown, clicks: clicks))
        case .drag(let x, let y): drag(to: CGPoint(x: x, y: y))
        case .dragPath(let x, let y, let speed):
            // In 16 ms steps at `speed` view points per millisecond.
            let target = CGPoint(x: x, y: y), start = pointer
            let n = max(1, Int((hypot(x - start.x, y - start.y) / (speed * 16)).rounded(.up)))
            for i in 1...n {
                let t = CGFloat(i) / CGFloat(n)
                drag(to: CGPoint(x: start.x + (target.x - start.x) * t, y: start.y + (target.y - start.y) * t))
            }
        case .up: sleep(16); view.mouseUp(with: mouse(.leftMouseUp))
        case .wait(let ms): sleep(ms)
        case .flags(let new):
            flags = new
            view.flagsChanged(with: NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: new, timestamp: time, windowNumber: window.windowNumber,
                                                     context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!)
        case .delete: view.keyDown(with: key("\u{7f}", code: 51))
        case .escape: view.keyDown(with: key("\u{1b}", code: 53))
        case .selectArrow, .selectShape, .zoom: direct(step)
        }
    }
}

/// Selection outlines and handles use the system accent color: pin it to blue (4), what the goldens
/// were recorded with, whatever this Mac's setting. Call it first thing: once AppKit has read the
/// accent (making a window does), changing it has no effect.
@MainActor func pinAccentColor() {
    UserDefaults.standard.setVolatileDomain(["AppleAccentColor": 4], forName: UserDefaults.argumentDomain)
}

/// The view as its window would draw it at 2× in the light appearance, whatever the screen.
@MainActor func snapshot(_ view: NSView) -> NSBitmapImageRep {
    view.appearance = NSAppearance(named: .aqua)
    // Calibrated RGB, as AppKit's own caching rep is: device RGB changes every pixel.
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import CoreGraphics
import LanguageModels
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import TestKit

// A plain sticky note's loop through the app's own canvas view: mouse events handed to a CanvasView in an unshown window,
// as the app's window hands them on (PortsShippedTests drive the editor itself), on the shipped plugins. The dots are where
// they're drawn: 12 points out from the middle of a side, at zoom 1.

/// The app's canvas view over shipped notes, driven by the mouse: one clock for the events' times and the editor's timers.
@MainActor private final class LoopWindow {
    let editor: CanvasEditor
    let window: NSWindow
    let canvas: CanvasView
    private let scheduler: ManualScheduler
    private var time: TimeInterval = 1
    private var location = CGPoint.zero

    init(_ shapes: [AnyShapeRecord], pasteboard: NSPasteboard) {
        let scheduler = ManualScheduler()
        self.scheduler = scheduler
        editor = ShippedPlugins.makeEditor(document: CanvasDocument(shapes: shapes), scheduler: scheduler, pasteboard: pasteboard,
                                           model: ScriptedLanguageModel())
        (window, canvas) = windowed(editor)
    }

    var arrows: [ShapeRecord<Arrow>] { editor.document.shapes.compactMap { $0.typed(as: Arrow.self) } }

    /// The pointer held still for `ms`, the editor's timers running meanwhile.
    func wait(_ ms: Int) {
        time += Double(ms) / 1000
        scheduler.advance(by: .milliseconds(ms))
    }

    func move(to point: CGPoint) {
        wait(16)
        location = point
        canvas.mouseMoved(with: window.mouse(.mouseMoved, at: point, clicks: 0, time: time))
    }

    func press(clickCount: Int = 1) {
        wait(16)
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: location, clicks: clickCount, time: time))
    }

    /// In 16 ms steps at `speed` view points a millisecond.
    func drag(to point: CGPoint, speed: CGFloat) {
        let start = location
        let steps = max(1, Int((hypot(point.x - start.x, point.y - start.y) / (speed * 16)).rounded(.up)))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            wait(16)
            location = CGPoint(x: start.x + (point.x - start.x) * t, y: start.y + (point.y - start.y) * t)
            canvas.mouseDragged(with: window.mouse(.leftMouseDragged, at: location, time: time))
        }
    }

    func release(clickCount: Int = 1) {
        wait(16)
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: location, clicks: clickCount, time: time))
    }

    /// Hovers the note, then its dot on `side`, and presses it, as a person reaches a dot.
    func pressDot(_ side: LoopSide, of frame: CGRect) {
        move(to: CGPoint(x: frame.midX, y: frame.midY))
        move(to: side.dot(of: frame))
        press()
    }
}

/// A side of a shape, and where its dot is drawn.
private enum LoopSide: CaseIterable {
    case top, right, bottom, left

    func dot(of frame: CGRect) -> CGPoint {
        switch self {
        case .top: CGPoint(x: frame.midX, y: frame.minY - 12)
        case .right: CGPoint(x: frame.maxX + 12, y: frame.midY)
        case .bottom: CGPoint(x: frame.midX, y: frame.maxY + 12)
        case .left: CGPoint(x: frame.minX - 12, y: frame.midY)
        }
    }

    /// A point inside `frame`, 30 points in from this side's middle: where a drag from the dot straight in comes to rest.
    func inside(_ frame: CGRect) -> CGPoint {
        switch self {
        case .top: CGPoint(x: frame.midX, y: frame.minY + 30)
        case .right: CGPoint(x: frame.maxX - 30, y: frame.midY)
        case .bottom: CGPoint(x: frame.midX, y: frame.maxY - 30)
        case .left: CGPoint(x: frame.minX + 30, y: frame.midY)
        }
    }
}

@MainActor private func sticky(_ frame: CGRect, text: String = "Hi") -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(StickyNote(frame: frame, text: MentionText(plain: text))))
}

/// The board holds one arrow, from `note` to itself, bowed out of its side: a loop.
@MainActor private func expectLoop(on note: ShapeID, in board: LoopWindow, _ what: String) {
    expectEqual(board.arrows.count, 1, "\(what): one arrow")
    guard let arrow = board.arrows.first else { return }
    expectEqual(arrow.props.start.binding?.shapeID, note, "\(what): from the note")
    expectEqual(arrow.props.end.binding?.shapeID, note, "\(what): to the note")
    expect(arrow.props.bend != 0, "\(what): bowed out of its side, not across the note (bend \(arrow.props.bend))")
}

private let aFrame = CGRect(x: 120, y: 140, width: 200, height: 200)
private let bFrame = CGRect(x: 520, y: 140, width: 200, height: 200)

@MainActor let loopWindowTests = Suite("A plain note's loop, through the app's canvas view", [
    test("from each dot, out past the note and back onto it, fast, the release is a loop on the note; one Undo takes it back") {
        for side in LoopSide.allCases {
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let a = sticky(aFrame), b = sticky(bFrame)
            let board = LoopWindow([a, b], pasteboard: pasteboard)
            board.pressDot(side, of: aFrame)
            let dot = side.dot(of: aFrame)
            board.drag(to: CGPoint(x: dot.x + (dot.x - aFrame.midX) * 0.4, y: dot.y + (dot.y - aFrame.midY) * 0.4), speed: 1)
            board.drag(to: CGPoint(x: aFrame.midX, y: aFrame.midY), speed: 1.5)
            expectEqual(board.editor.hintedShapeID, a.id, "\(side): back over the note, it is the target")
            board.release()
            expectLoop(on: a.id, in: board, "\(side)")
            expectEqual(board.editor.undoHistory.undoName, "Add Arrow", "\(side)")
            board.editor.undo()
            expect(board.arrows.isEmpty, "\(side): undone")
        }
    },
    test("from each dot straight into the note, slowly, or held there past the precise timer, the release is a loop") {
        for side in LoopSide.allCases {
            for (speed, held) in [(0.08, 0), (1.0, 400)] as [(CGFloat, Int)] {
                let pasteboard = NSPasteboard.withUniqueName()
                defer { pasteboard.releaseGlobally() }
                let a = sticky(aFrame)
                let board = LoopWindow([a], pasteboard: pasteboard)
                board.pressDot(side, of: aFrame)
                board.drag(to: side.inside(aFrame), speed: speed)
                if held > 0 { board.wait(held) }
                board.release()
                expectLoop(on: a.id, in: board, "\(side) at \(speed), held \(held) ms")
            }
        }
    },
    test("a note with a title and several lines, selected first: its dots' drags let go on it are loops too") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let a = sticky(aFrame, text: "Groceries\nmilk\neggs\nbread and butter")
        let board = LoopWindow([a], pasteboard: pasteboard)
        board.move(to: CGPoint(x: aFrame.midX, y: aFrame.maxY - 20))
        board.press()
        board.release()
        expectEqual(board.editor.selectedShapeIDs, [a.id], "a click selects it")
        board.wait(600)
        board.pressDot(.right, of: aFrame)
        board.drag(to: CGPoint(x: aFrame.maxX + 70, y: aFrame.midY + 40), speed: 1)
        board.drag(to: CGPoint(x: aFrame.maxX - 50, y: aFrame.maxY - 40), speed: 1)
        board.release()
        expectLoop(on: a.id, in: board, "selected, from its right dot")
    },
    test("let go back on the dot it started from, off the note, nothing is drawn: the release is on no shape") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let board = LoopWindow([sticky(aFrame)], pasteboard: pasteboard)
        let before = board.editor.document
        board.pressDot(.right, of: aFrame)
        board.drag(to: CGPoint(x: aFrame.maxX + 80, y: aFrame.midY), speed: 1)
        board.drag(to: LoopSide.right.dot(of: aFrame), speed: 1)
        board.release()
        expectEqual(board.editor.document, before)
    },
])

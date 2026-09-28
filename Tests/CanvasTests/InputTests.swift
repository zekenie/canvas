@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit

final class ModifierLog: Tool {
    var seen: [Modifiers] = []
    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) {}
    func modifiersChanged(_ modifiers: Modifiers, in editor: CanvasEditor) { seen.append(modifiers) }
}

/// A tool that ignores every press with a click count of 2 or more (`ignoresPress`), and logs the
/// click counts of the presses it's given, each of which starts a session that logs its drags.
final class PressLog {
    var presses: [Int] = []
    var drags = 0
}

extension PressLog: Tool {
    func ignoresPress(_ pointer: Pointer, in editor: CanvasEditor) -> Bool { pointer.clickCount >= 2 }
    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) {
        presses.append(pointer.clickCount)
        editor.session = DragLog(log: self)
    }
}

final class DragLog {
    let log: PressLog
    init(log: PressLog) { self.log = log }
}

extension DragLog: Session {
    func drag(_ pointer: Pointer, in editor: CanvasEditor) { log.drags += 1 }
}

@MainActor let inputTests = Suite("Input", [
    test("pointer speed: the first sample reads 0, then smoothing halves the old weight every 16 ms") {
        let h = try EditorHarness(plugins: [])
        h.move(to: CGPoint(x: 0, y: 0))
        expectEqual(h.editor.pointerSpeed, 0)
        h.move(to: CGPoint(x: 16, y: 0), after: 16)          // 1 pt/ms for 16 ms
        expectClose(h.editor.pointerSpeed, 0.5)
        h.move(to: CGPoint(x: 32, y: 0), after: 16)
        expectClose(h.editor.pointerSpeed, 0.75)
        h.move(to: CGPoint(x: 32, y: 0), after: 96)
        expectClose(h.editor.pointerSpeed, 0.75 / 64)         // just over 0.01: kept
        h.move(to: CGPoint(x: 32, y: 0), after: 16)
        expectEqual(h.editor.pointerSpeed, 0)                 // below 0.01 reads as 0
    },
    test("pointer velocity smooths per axis like speed, zeroes components under 0.01, and resets on press") {
        let h = try EditorHarness(plugins: [])
        h.move(to: CGPoint(x: 0, y: 0))
        expectEqual(h.editor.pointerVelocity, .zero)
        h.move(to: CGPoint(x: 16, y: -32), after: 16)        // (1, -2) pt/ms for 16 ms
        expectClose(h.editor.pointerVelocity, CGPoint(x: 0.5, y: -1))
        h.move(to: CGPoint(x: 32, y: -32), after: 16)        // (1, 0)
        expectClose(h.editor.pointerVelocity, CGPoint(x: 0.75, y: -0.5))
        h.move(to: CGPoint(x: 32, y: -64), after: 160)       // (0, -0.2): x decays under 0.01, y doesn't
        expectEqual(h.editor.pointerVelocity.x, 0)
        expectClose(h.editor.pointerVelocity.y, -0.2 - 0.3 * 0.5 * 0.5 * 0.5 * 0.5 * 0.5 * 0.5 * 0.5 * 0.5 * 0.5 * 0.5)
        h.press(at: CGPoint(x: 64, y: -64))                  // moving, but a press starts from rest
        expectEqual(h.editor.pointerVelocity, .zero)
        h.drag(to: CGPoint(x: 80, y: -64))
        expectClose(h.editor.pointerVelocity, CGPoint(x: 0.5, y: 0))
        h.release(after: 80)
        expectClose(h.editor.pointerVelocity, CGPoint(x: 0.5 / 32, y: 0))   // just over 0.01: kept
        h.move(to: CGPoint(x: 80, y: -64), after: 16)
        expectEqual(h.editor.pointerVelocity, .zero)
    },
    test("a press the tool ignores passes as though it never came: the camera goes on moving, editing goes on, and nothing is pressed or dragged") {
        var log: PressLog?
        let h = try EditorHarness(plugins: [CardsPlugin(), Contributor(id: "log") {
            $0.tool(ToolDescriptor(id: "log", label: "Log", systemImage: "list.bullet")) { _ in let t = PressLog(); log = t; return t }
        }])
        h.editor.setTool("log")
        let card = h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60)))
        expect(h.editor.beginEditing(card))
        let target = Camera(origin: CGPoint(x: 500, y: 0))
        h.editor.animateCamera(to: target, duration: .milliseconds(200))
        h.wait(48)
        h.press(at: CGPoint(x: 10, y: 10), clickCount: 2, after: 0)
        h.drag(to: CGPoint(x: 60, y: 10))
        h.release()
        expectEqual(log?.presses, [])
        expectEqual(log?.drags, 0)
        expectEqual(h.editor.editingShapeID, card)
        h.wait(200)
        expectEqual(h.editor.camera, target, "it went on")
        h.editor.animateCamera(to: Camera(), duration: .milliseconds(200))
        h.wait(48)
        h.press(at: CGPoint(x: 10, y: 10), after: 0)
        let pressed = h.editor.camera
        h.drag(to: CGPoint(x: 60, y: 10))
        h.release()
        expectEqual(log?.presses, [1])
        expectEqual(log?.drags, 1)
        expectEqual(h.editor.editingShapeID, nil, "a press it takes ends editing")
        h.wait(300)
        expectEqual(h.editor.camera, pressed, "and stops the camera")
    },
    test("a released modifier stays held for 150 ms, then the release is dispatched") {
        var log: ModifierLog?
        let h = try EditorHarness(plugins: [Contributor(id: "log") {
            $0.tool(ToolDescriptor(id: "log", label: "Log", systemImage: "list.bullet")) { _ in let t = ModifierLog(); log = t; return t }
        }])
        h.editor.setTool("log")
        h.hold(.option)
        h.hold([])
        expectEqual(h.editor.effectiveModifiers, .option)
        h.wait(149)
        expectEqual(h.editor.effectiveModifiers, .option)
        h.wait(1)
        expectEqual(h.editor.effectiveModifiers, [])
        expectEqual(log?.seen, [.option, .option, []])
    },
    test("the manual scheduler fires in deadline order, ties in the order scheduled, and honors cancellation") {
        let scheduler = ManualScheduler()
        var fired: [String] = []
        _ = scheduler.schedule(after: .milliseconds(20)) { fired.append("late") }
        let cancelled = scheduler.schedule(after: .milliseconds(5)) { fired.append("cancelled") }
        _ = scheduler.schedule(after: .milliseconds(10)) { fired.append("a") }
        _ = scheduler.schedule(after: .milliseconds(10)) { fired.append("b") }
        cancelled.cancel()
        scheduler.advance(by: .milliseconds(19))
        expectEqual(fired, ["a", "b"])
        scheduler.advance(by: .milliseconds(1))
        expectEqual(fired, ["a", "b", "late"])
    },
    test("a delay scheduled by a firing action counts from when it fired") {
        // As when the modifier-release timer re-aims an arrow, which starts the 320 ms drag timer.
        let scheduler = ManualScheduler()
        var fired: [String] = []
        _ = scheduler.schedule(after: .milliseconds(10)) {
            fired.append("a")
            _ = scheduler.schedule(after: .milliseconds(5)) { fired.append("nested") }
        }
        _ = scheduler.schedule(after: .milliseconds(10)) { fired.append("b") }
        scheduler.advance(by: .milliseconds(14))
        expectEqual(fired, ["a", "b"])
        scheduler.advance(by: .milliseconds(1))
        expectEqual(fired, ["a", "b", "nested"])
    },
])

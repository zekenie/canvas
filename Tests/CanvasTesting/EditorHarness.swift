@_spi(Host) import Canvas
import CoreGraphics
import Foundation
import Geometry

/// Drives a `CanvasEditor` with no view, like a user would: one clock for event timestamps and
/// timers, so pointer speed and the 600/320/150 ms timers agree. Points are view points.
@MainActor
public final class EditorHarness {
    public let editor: CanvasEditor
    public let scheduler: ManualScheduler
    /// Event time in seconds (`NSEvent.timestamp`).
    public private(set) var time: TimeInterval = 100
    /// The keys held now: sent with every event, and what `liveModifiers` reports.
    public private(set) var held: Modifiers = []
    public private(set) var location: CGPoint = .zero

    public init(editor makeEditor: (ManualScheduler) throws -> CanvasEditor) rethrows {
        scheduler = ManualScheduler()
        editor = try makeEditor(scheduler)
        editor.liveModifiers = { [unowned self] in held }
    }

    public convenience init(plugins: [any CanvasPlugin], document: CanvasDocument = CanvasDocument()) throws {
        let registry = try Registry(plugins: plugins)
        self.init { CanvasEditor(registry: registry, document: document, scheduler: $0) }
    }

    @discardableResult
    public func add<P: ShapeProps>(_ props: P, id: ShapeID = ShapeID()) -> ShapeID { editor.add(props, id: id) }

    /// Advances event time and fires due timers. Every event waits first, so a timer due at the
    /// same instant as an event fires before that event (the 599/600 ms boundary tests rely on it).
    public func wait(_ ms: Int) {
        time += Double(ms) / 1000
        scheduler.advance(by: .milliseconds(ms))
    }

    private func event(clickCount: Int = 1) -> PointerEvent {
        PointerEvent(location: location, timestamp: time, modifiers: held, clickCount: clickCount)
    }

    public func move(to point: CGPoint, after ms: Int = 16) {
        wait(ms)
        location = point
        editor.pointerMoved(event(clickCount: 0))
    }

    public func press(at point: CGPoint? = nil, clickCount: Int = 1, after ms: Int = 16) {
        wait(ms)
        if let point { location = point }
        editor.pointerDown(event(clickCount: clickCount))
    }

    public func drag(to point: CGPoint, after ms: Int = 16) {
        wait(ms)
        location = point
        editor.pointerDragged(event())
    }

    /// In 16 ms steps at `speed` view points per millisecond.
    public func drag(to point: CGPoint, speed: CGFloat) {
        let start = location
        let steps = max(1, Int((start.distance(to: point) / (speed * 16)).rounded(.up)))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            drag(to: start + (point - start) * t)
        }
    }

    public func release(after ms: Int = 16) {
        wait(ms)
        editor.pointerUp(event())
    }

    /// The keys held from now on (a flagsChanged event).
    public func hold(_ modifiers: Modifiers) {
        held = modifiers
        editor.modifiersChanged(held: modifiers)
    }

    @discardableResult
    public func key(_ text: String) -> Bool { editor.handleShortcut(text) }

    public func escape() { editor.cancel() }

    /// A world point in view points, through the current camera.
    public func view(_ world: CGPoint) -> CGPoint { editor.camera.toView(world) }
}

extension CanvasEditor {
    /// Inserts a shape, in a transaction of its own.
    @discardableResult
    public func add<P: ShapeProps>(_ props: P, id: ShapeID = ShapeID()) -> ShapeID {
        transact { $0.insert(ShapeRecord(id: id, props)) }
        return id
    }
}

/// Every timer goes through one of these, so tests can run time by hand.
@MainActor
public protocol Scheduler: AnyObject {
    /// How long it has run, on the clock its timers keep: what a moment that needs no timer of its own
    /// is measured by (the camera keeping a view while the view settles).
    var now: Duration { get }
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> ScheduledTask
}

@MainActor
public struct ScheduledTask {
    private let onCancel: @MainActor () -> Void
    public init(cancel: @escaping @MainActor () -> Void) { onCancel = cancel }
    public func cancel() { onCancel() }
}

/// Real time, on the main actor.
@MainActor
public final class TaskScheduler: Scheduler {
    private let start = ContinuousClock.now
    public init() {}
    public var now: Duration { ContinuousClock.now - start }
    public func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> ScheduledTask {
        let task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
        return ScheduledTask { task.cancel() }
    }
}

/// A clock that stands still and fires nothing: what an editor runs on when nothing it would do later may ever
/// happen (a copy a change is rehearsed on, `rehearsal()`, whose services would otherwise ask a model once its file
/// is quiet).
@MainActor
public final class StoppedScheduler: Scheduler {
    public init() {}
    public var now: Duration { .zero }
    public func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> ScheduledTask { ScheduledTask {} }
}

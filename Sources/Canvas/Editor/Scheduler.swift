/// Every timer goes through one of these, so tests can run time by hand.
@MainActor
public protocol Scheduler: AnyObject {
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
    public init() {}
    public func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> ScheduledTask {
        let task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
        return ScheduledTask { task.cancel() }
    }
}

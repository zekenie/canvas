@_spi(Host) import Canvas

/// Time that only moves when a test says so. Due actions fire in deadline order (ties in the
/// order they were scheduled), and may schedule more.
@MainActor
public final class ManualScheduler: Scheduler {
    public private(set) var now: Duration = .zero
    private var pending: [(id: Int, due: Duration, action: @MainActor () -> Void)] = []
    private var nextID = 0

    public init() {}

    public func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> ScheduledTask {
        let id = nextID
        nextID += 1
        pending.append((id, now + delay, action))
        return ScheduledTask { [weak self] in self?.pending.removeAll { $0.id == id } }
    }

    public func advance(by delta: Duration) {
        let end = now + delta
        while let next = pending.filter({ $0.due <= end }).min(by: { ($0.due, $0.id) < ($1.due, $1.id) }) {
            pending.removeAll { $0.id == next.id }
            now = next.due
            next.action()
        }
        now = end
    }

    public var pendingCount: Int { pending.count }
}

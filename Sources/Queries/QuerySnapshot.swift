import Canvas
import Foundation
import os
import Topology

/// The file as a query takes it up, in one main-actor turn, to be answered anywhere: every board
/// (`editor.file`, read without observing it), Topology's edges and containment as they were then
/// (`topology.snapshot()`), the board shown and the path to it, the editor's revision, the shape
/// being typed into, and what each word and text format the query uses took on the main actor
/// (`prepare`). All of it is shared with the editor, not copied (O(1)), until a commit changes a
/// table, which then copies it once; so it's held for one query, never past it, and handed to the
/// evaluation whole (`Handover`), which frees it where it ends, off the main actor.
struct QuerySnapshot: Sendable {
    let file: CanvasFile
    let topology: TopologySnapshot
    let shown: BoardID
    /// The boards from the top down to the one shown.
    let shownPath: [BoardID]
    let revision: Int
    let editing: ShapeID?
    /// What each word the query uses took as it was taken up, by word.
    let words: [String: any Sendable]
    /// What each text format took, by media type.
    let formats: [String: any Sendable]
    /// Counts it among the snapshots alive (`QueryState.liveSnapshots`, debug builds).
    let token: LiveToken
}

/// A value handed from one task to another whole: taken out once, so the taker is its last holder
/// and it's freed where the taker lets go of it.
final class Handover<Value: Sendable>: Sendable {
    private let value: OSAllocatedUnfairLock<Value?>

    init(_ value: Value) {
        self.value = OSAllocatedUnfairLock(initialState: value)
    }

    /// The value, leaving nothing behind; nil once taken.
    func take() -> Value? {
        value.withLock { held in
            let taken = held
            held = nil
            return taken
        }
    }
}

/// The time this thread has run, in nanoseconds: what slices and timings measure (never the wall
/// clock, which counts whatever else the machine runs).
func threadCPU() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
}

extension Duration {
    /// Nanoseconds of thread CPU as a duration.
    static func cpu(_ nanoseconds: UInt64) -> Duration { .nanoseconds(Int64(clamping: nanoseconds)) }

    /// As whole nanoseconds, for comparing with the thread's clock.
    var nanoseconds: UInt64 {
        let (seconds, attoseconds) = components
        return UInt64(max(seconds, 0)) * 1_000_000_000 + UInt64(max(attoseconds, 0) / 1_000_000_000)
    }
}

/// How many snapshots are alive: each holds a token, and the count drops as the last holder of one
/// lets it go, on whatever thread that is. What debug builds tell (`QueryState.liveSnapshots`).
final class LiveCount: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    var value: Int { count.withLock { $0 } }

    func token() -> LiveToken {
        count.withLock { $0 += 1 }
        return LiveToken(count: self)
    }

    fileprivate func drop() { count.withLock { $0 -= 1 } }
}

/// One snapshot's place in `LiveCount`.
final class LiveToken: Sendable {
    private let count: LiveCount

    fileprivate init(count: LiveCount) { self.count = count }

    deinit { count.drop() }
}

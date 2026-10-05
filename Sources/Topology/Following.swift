import Canvas
import Foundation

// Hearing changes to the edges, and knowing when they've settled. The edges change two ways: a
// commit (undo and redo among them, and a board or file put in place) and an answer provided for a
// stand-in that stands for whatever is provided (`TopologyIndex.provide`), which is no commit. A
// follower hears both alike, once each (`follow`). Whoever provides answers says while it still has
// work (`keepsSettling`), so a reader that must see the edges settled can wait (`settled`).

/// An answer for a stand-in that stands for what's provided (`Forwarding.provided`): the shapes it
/// stands for, for the key its record held when the answer was asked (`key`), and how recent the
/// answer is (`revision`, which only grows for one stand-in and key). Never saved, never undone.
public struct ProvidedForwarding: Sendable, Equatable {
    public var key: ForwardingKey
    public var shapes: [ShapeID]
    public var revision: Int

    public init(key: ForwardingKey, shapes: [ShapeID], revision: Int) {
        self.key = key
        self.shapes = shapes
        self.revision = revision
    }
}

/// One change to the file's edges, as followers hear it (`TopologyIndex.follow`): the ends of the
/// edges it added, removed or changed, all of them and by type, and what caused it.
public struct TopologyChange: Sendable {
    /// What made the edges change.
    public enum Cause: Hashable, Sendable {
        /// A commit (undo and redo too).
        case commit
        /// Answers provided for stand-ins (`TopologyIndex.provide`): no commit.
        case provide
        /// The file read afresh: a board or file put in place.
        case rebuild
    }

    /// Every end, and literal end, of every edge the change added, removed or changed.
    public var touched: Set<ShapeID>
    /// `touched`, by the type of each edge that changed.
    public var touchedByType: [EdgeTypeID: Set<ShapeID>]
    public var cause: Cause

    public init(touched: Set<ShapeID>, touchedByType: [EdgeTypeID: Set<ShapeID>], cause: Cause) {
        self.touched = touched
        self.touchedByType = touchedByType
        self.cause = cause
    }

    /// The ends of the changed edges of the types `filter` admits in the tree `types` (the index's
    /// `types`). O(the types the change touched).
    public func touched(types filter: EdgeTypeFilter, in types: EdgeTypeTree) -> Set<ShapeID> {
        guard !filter.isAll else { return touched }
        var found: Set<ShapeID> = []
        for (type, ends) in touchedByType where filter.admits(type, in: types) { found.formUnion(ends) }
        return found
    }
}

/// A follower of the index's changes (`TopologyIndex.follow`): it lasts until it's cancelled, or let
/// go of.
@MainActor
public final class TopologyFollowing {
    private weak var index: TopologyIndex?
    private let key: Int

    init(index: TopologyIndex, key: Int) {
        self.index = index
        self.key = key
    }

    /// Stops it: its closure isn't called again.
    public func cancel() {
        index?.stopFollowing(key)
        index = nil
    }

    /// Let go of, it stops as cancelled, so the index keeps no closure of a follower that's gone.
    deinit {
        guard let index else { return }
        let key = key
        if Thread.isMainThread {
            MainActor.assumeIsolated { index.stopFollowing(key) }
        } else {
            Task { @MainActor in index.stopFollowing(key) }
        }
    }
}

/// Something that provides answers for stand-ins, and says while it still has work
/// (`TopologyIndex.keepsSettling(while:)`): it lasts until it's cancelled, or let go of.
@MainActor
public final class SettleSource {
    private weak var index: TopologyIndex?
    private let key: Int

    init(index: TopologyIndex, key: Int) {
        self.index = index
        self.key = key
    }

    /// Stops it: it no longer keeps the index settling.
    public func cancel() {
        index?.stopSettling(key)
        index = nil
    }

    /// Let go of, it stops as cancelled.
    deinit {
        guard let index else { return }
        let key = key
        if Thread.isMainThread {
            MainActor.assumeIsolated { index.stopSettling(key) }
        } else {
            Task { @MainActor in index.stopSettling(key) }
        }
    }
}

/// Those waiting for the index to settle (`settled(timeout:)`): kept apart from the index, so a
/// waiter's timeout ends its wait even when the index has gone.
@MainActor
final class SettleWaiters {
    private var waiting: [Int: (continuation: CheckedContinuation<Bool, Never>, timeout: ScheduledTask?)] = [:]
    private var next = 0

    var isEmpty: Bool { waiting.isEmpty }

    /// A key for a waiter about to wait.
    func reserve() -> Int {
        defer { next += 1 }
        return next
    }

    func wait(_ key: Int, _ continuation: CheckedContinuation<Bool, Never>, timeout: ScheduledTask?) {
        waiting[key] = (continuation, timeout)
    }

    /// Ends one wait, saying whether it settled: nothing for one that's ended.
    func finish(_ key: Int, settled: Bool) {
        guard let waiter = waiting.removeValue(forKey: key) else { return }
        waiter.timeout?.cancel()
        waiter.continuation.resume(returning: settled)
    }

    /// Ends every wait, settled.
    func finishAll() {
        for key in waiting.keys.sorted() { finish(key, settled: true) }
    }
}

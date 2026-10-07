import AppKit
import Canvas
import Observation
import Queries
import Selection
import Topology

/// What's lit for the shape hovered, one per editor. The shape hovered is the subject: what the
/// pointer is over on the canvas (`editor.hovered`, which the select tool and any plugin that shows
/// shapes set), else the shape whose row it's on when the canvas doesn't show it
/// (`editor.hoveredElsewhere`, a row of a board nested under its owner's). Both are watched, so a
/// change of either asks again; it never writes the document, and keeps nothing a commit must
/// follow but what it matched and where that is drawn.
///
/// **Asking.** When the subject changes to a shape, any ask still running is let go of and the
/// engine is asked once, in one batch, for each light's query in the edge view `.resolved` and,
/// where some shape stands in for others, in `.literal` too: a reference's own arrows count, and so
/// does what it stands for, since the resolved view reads an arrow into a pill as one into the shape
/// and the literal view as drawn (with no stand-in the views are the same edges, so one is asked).
/// Each light keeps the union of its views. The answer lands a turn or so later (the engine answers
/// off the main actor); until it does, the lights of the shape before stay, and when the subject
/// goes the lights go at once. A request the engine refuses (a shape gone, say) lights nothing.
///
/// **Asking again.** When a change to the edges touches the subject or a shape the answer matched (a
/// commit's or a provide's: `topology.follow`; an arrow hovered is an edge, which a change lists by
/// its ends, never by the arrow), and when a commit names the subject itself (an arrow whose record
/// changed: an end it had none at is bound) or adds a shape the answer didn't match (a name outlives
/// its shape, so a mention of one deleted before the hover lights it when it comes back, and no edge
/// changed). It lets go of everything when another board is shown.
///
/// **What shows.** Worked out when an answer lands, and again by a commit that names a shape matched
/// or one a match is drawn as (other than by moving it), reaches another board or replaces the
/// document, never per frame: a matched shape on the board shown is outlined itself; one on another
/// board is outlined as the shape on the board shown that holds it (`file.shape(on:holding:)`: a
/// subboard's card, at any depth), and one on a board above is left out. The subject is never lit,
/// nor, where the subject isn't on the board shown, its own card, which Selection outlines faintly
/// instead (it's where the subject is). A shape matched by several lights is in each, in a ring of
/// its own for each: its first light's is the first ring, the next light's the next. A frame costs
/// handing the core what's kept, and a redraw is asked for only when what's kept changed.
@MainActor
public final class NeighborState {
    private unowned let editor: CanvasEditor
    /// The lights, in order.
    private let lights: [NeighborLight]

    /// The shape hovered, as the last look found it, which what's lit is being asked for (or is).
    public private(set) var subject: ShapeID?
    /// What the lights matched for the shape before the subject, until the answer for it lands: every
    /// match, on whatever board, each light's in the engine's order.
    private var lit: Lit?
    /// The shapes on the board shown that matches are drawn as, where they aren't on it: the card of
    /// each board they were found on, and the subject's.
    private var cards: Set<ShapeID> = []
    /// What the canvas outlines for `lit`.
    private var shown = Outlines()
    /// The ask that's out: the batch, and what lands it.
    private var asking: Task<Void, Never>?
    /// `editor.revision` as the last ask began: a commit's own ask, begun as its edges were followed,
    /// is that one.
    private var askedAt = -1
    /// The look at what's hovered that waits for a turn of the scheduler, after its change.
    private var turn: ScheduledTask?
    private var following: TopologyFollowing?

    #if DEBUG
    /// How many times the engine was asked (debug builds): a hover that changes nothing of the
    /// subject's edges asks nothing more.
    public private(set) var asked = 0
    /// How many queries the asks have batched (debug builds): each light, in each edge view that can
    /// differ, so one for each with no stand-in in the file and two with one.
    public private(set) var requested = 0
    /// How many times what shows was worked out (debug builds): a drag's every event, which only
    /// moves shapes, works out nothing.
    public private(set) var placed = 0
    #endif

    /// What the lights matched for a shape: each light's ids, in light order, and every id, whichever
    /// light matched it.
    private struct Lit {
        let subject: ShapeID
        let ids: [[ShapeID]]
        let matched: Set<ShapeID>

        init(subject: ShapeID, ids: [[ShapeID]]) {
            self.subject = subject
            self.ids = ids
            var matched: Set<ShapeID> = []
            matched.reserveCapacity(ids.reduce(0) { $0 + $1.count })
            for light in ids { matched.formUnion(light) }
            self.matched = matched
        }
    }

    /// How many lights a shape has been in, and the last: the ring it's in next.
    private struct Visit {
        var light = -1
        var count = 0

        /// The ring the shape takes in `light`, none if it's in it already.
        mutating func enter(_ light: Int) -> Int? {
            guard self.light != light else { return nil }
            self.light = light
            count += 1
            return count - 1
        }
    }

    init(editor: CanvasEditor, lights: [NeighborLight]) {
        self.editor = editor
        self.lights = lights
        following = editor.topology?.follow { [weak self] change in self?.edgesChanged(change) }
        subject = watch()
    }

    /// Whether an answer is on its way, or a look at the hover is due: what a test waits out.
    public var isAsking: Bool { asking != nil || turn != nil }

    /// Returns once no answer is on its way: what's lit is the answer for what's hovered, or none.
    /// A change of the hover is looked at a turn of the scheduler later, so a caller that has just
    /// hovered lets that turn run first. For a test or a benchmark that waits for the lights without
    /// polling, or turning the run loop for them: the main thread is idle while the engine answers.
    public func landed() async {
        while let asking { await asking.value }
    }

    // MARK: The subject

    /// The shape hovered now, read so its next change is told: Observation tells once, so every look
    /// arms the next.
    private func watch() -> ShapeID? {
        withObservationTracking {
            let onCanvas = editor.hovered, elsewhere = editor.hoveredElsewhere
            return onCanvas ?? elsewhere
        } onChange: { [weak self] in
            // Told as it's about to change (in its `willSet`): looked at once it has, a turn later.
            MainActor.assumeIsolated { self?.hoverWillChange() }
        }
    }

    private func hoverWillChange() {
        guard turn == nil else { return }
        turn = editor.scheduler.schedule(after: .zero) { [weak self] in
            guard let self else { return }
            turn = nil
            look()
        }
    }

    /// The hover changed, or may have: a shape asks, and none lets go of what's lit.
    private func look() {
        let next = watch()
        guard next != subject else { return }
        subject = next
        guard let next else { return stop() }
        ask(about: next)
    }

    // MARK: Asking

    /// A change to the edges (a commit's, a provide's, a file read afresh) may change what's
    /// connected to the subject, or, for an arrow, where it starts and ends: its edge is listed by
    /// its ends, which a shape the last answer matched may be. The carrier isn't listed.
    private func edgesChanged(_ change: TopologyChange) {
        guard let subject else { return }
        guard change.touched.contains(subject) || !change.touched.isDisjoint(with: lit?.matched ?? []) else { return }
        ask(about: subject)
    }

    /// Whether a commit calls for a new answer: it names the subject other than by moving it (an
    /// arrow whose own record changed, say, which no change to its edges names), or adds a shape the
    /// answer didn't match, which an edge may go to that wasn't a shape when it was asked (a mention
    /// of one deleted). A shape that came to another board is `elsewhere`, which names those that
    /// left or changed too.
    private func needsAnswer(_ changes: ChangeSet, about subject: ShapeID) -> Bool {
        if changes.added.contains(subject) || changes.elsewhere.contains(subject) { return true }
        if changes.changed.contains(subject) && !changes.moved.contains(subject) { return true }
        let matched = lit?.matched ?? [], file = editor.file
        return changes.added.contains { !matched.contains($0) }
            || changes.elsewhere.contains { !matched.contains($0) && file.board(containing: $0) != nil }
    }

    /// Asks which shapes each light matches for `subject`, in one batch, in each edge view that can
    /// differ (what's lit stays as it is until the answer lands). Without the engine or Topology, or
    /// any light, nothing is asked and nothing is lit.
    private func ask(about subject: ShapeID) {
        guard let queries = editor.queries, let topology = editor.topology, !lights.isEmpty else { return stop() }
        asking?.cancel()
        askedAt = editor.revision
        // The literal view reads other edges than the resolved one only where a shape stands in.
        let views: [EdgeView] = topology.hasStandIns ? [.resolved, .literal] : [.resolved]
        let selector = "#\(subject)"
        var requests: [QueryMatchRequest] = []
        requests.reserveCapacity(lights.count * views.count)
        for light in lights {
            let text = light.query(selector)
            for view in views { requests.append(QueryMatchRequest(text, edges: view, limit: QueryBudget.maxRows)) }
        }
        #if DEBUG
        asked += 1
        requested += requests.count
        #endif
        asking = Task { [weak self, queries] in
            let answers = await queries.matches(requests)
            // One let go of lands nothing: whoever did that has taken its place or cleared it, as
            // every change of the subject does.
            guard !Task.isCancelled, let self else { return }
            asking = nil
            let answer = Lit(subject: subject, ids: lights.indices.map { merged(answers[$0 * views.count ..< ($0 + 1) * views.count]) })
            lit = answer
            place(answer)
        }
    }

    /// What a light matched, from its views' answers: each shape once, the first view's first. A
    /// request the engine refused matched nothing.
    private func merged<Refusal: Error>(_ answers: ArraySlice<Result<QueryMatches, Refusal>>) -> [ShapeID] {
        var ids: [ShapeID] = []
        for case .success(let answer) in answers where !answer.ids.isEmpty {
            // The views differ only where a stand-in stands (a pill and what it stands for).
            if ids.isEmpty {
                ids = answer.ids
            } else if answer.ids != ids {
                var seen = Set(ids)
                ids += answer.ids.filter { seen.insert($0).inserted }
            }
        }
        return ids
    }

    // MARK: What shows

    /// Works out what the canvas outlines from what the lights matched, as the file is now: each
    /// match where it's drawn (itself, on the board shown, else the shape on it that holds it: its
    /// card, none for a shape on a board above), the subject and its card out of it, and each shape
    /// in a ring of its own for each light it's in. O(what's lit), and a walk up the boards from each
    /// board that isn't the one shown, once.
    private func place(_ lit: Lit) {
        #if DEBUG
        placed += 1
        #endif
        let file = editor.file, board = editor.board
        var holders: [BoardID: ShapeID?] = [:]
        func drawn(_ id: ShapeID) -> ShapeID? {
            guard let on = file.board(containing: id) else { return nil }
            if on == board { return id }
            if let known = holders[on] { return known }
            let holder = file.shape(on: board, holding: id)
            holders[on] = holder
            return holder
        }
        // Where the subject is, when the canvas doesn't show it: that card is never lit.
        let card = drawn(lit.subject).flatMap { $0 == lit.subject ? nil : $0 }
        var visits: [ShapeID: Visit] = [:]
        visits.reserveCapacity(lit.ids.reduce(0) { $0 + $1.count })
        var groups: [TintedOutlines] = []
        for (light, ids) in lit.ids.enumerated() {
            var rings: [[ShapeID]] = []
            for id in ids {
                guard let shape = drawn(id), shape != lit.subject, shape != card,
                      let ring = visits[shape, default: Visit()].enter(light) else { continue }
                while rings.count <= ring { rings.append([]) }
                rings[ring].append(shape)
            }
            for (ring, shapes) in rings.enumerated() where !shapes.isEmpty {
                groups.append(TintedOutlines(color: lights[light].color, shapes: shapes, ring: ring))
            }
        }
        cards = Set(holders.values.compactMap { $0 })
        show(Outlines(tinted: groups))
    }

    /// Whether the commit names any of the shapes other than by only moving them: added, removed,
    /// changed (edited, restacked) or on another board. Each costs a lookup of the smaller set's
    /// members in the larger.
    private func names(_ changes: ChangeSet, in shapes: Set<ShapeID>) -> Bool {
        !changes.added.isDisjoint(with: shapes) || !changes.removed.isDisjoint(with: shapes) || !changes.elsewhere.isDisjoint(with: shapes)
            || !changes.changed.intersection(shapes).isSubset(of: changes.moved)
    }

    /// What the canvas outlines now, and a frame for it only if that changed.
    private func show(_ next: Outlines) {
        guard next != shown else { return }
        shown = next
        editor.setNeedsDisplay()
    }

    /// Lets go of what's asked, and of what's lit: nothing is, until a shape asks again.
    private func stop() {
        asking?.cancel()
        asking = nil
        lit = nil
        cards = []
        show(Outlines())
    }

    /// What the core outlines for the lights: one tinted group for each light and ring that has
    /// shapes, in light order. None while a session runs (a drag). Hands over what's kept: nothing
    /// is made.
    var outlines: Outlines { editor.session == nil ? shown : Outlines() }
}

extension NeighborState: EditorService {
    /// A commit may call for a new answer (`needsAnswer`), unless its change to the subject's edges
    /// asked already, and may change what shows: where a shape is drawn follows what it's on, and
    /// what the boards hang from, so it works out what shows again for a commit that names a shape
    /// matched or one a match is drawn as, reaches another board or replaces the document, asking
    /// nothing more: the edges are Topology's to say (`edgesChanged`). Any other commit, a drag's
    /// every event and a keystroke in a note among them, costs a look at its change set.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard let subject else { return }
        if askedAt != editor.revision, needsAnswer(changes, about: subject) { ask(about: subject) }
        guard let lit else { return }
        if changes.replacedDocument || !changes.boardsReached.isEmpty || names(changes, in: lit.matched) || names(changes, in: cards) { place(lit) }
    }

    /// Another board: what was lit was for the board left. The hover is let go of with the switch, and
    /// the look it brings finds nothing. Keeps nothing per board, so the switch's change set is never
    /// worked out.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        subject = nil
        stop()
    }
}

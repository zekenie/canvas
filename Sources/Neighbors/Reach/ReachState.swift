import AppKit
import Canvas
import Observation
import Queries
import Selection
import Topology

/// What's lit for the shape hovered while View › Show Whole Reach is on, one per editor, in
/// `NeighborState`'s place: everything a light's step leads to from the shape, and on from there, each
/// shape fading with its distance and how the reach divides, and the rest of the board dimmed.
///
/// **The subject and the keys** are `NeighborState`'s: `editor.hovered`, else `hoveredElsewhere`,
/// watched with the keys held of those some light names, a look a turn after either changes.
///
/// **Asking.** A new subject asks twice at once, each in one batch: the lights' one hop as
/// `NeighborState` asks it (`light.lit`, in each view that can differ), which shows as hop 1 as soon as
/// it lands, and each light's reach (`queries.reaches`, its step and between given `:scope`, the
/// resolved view, which the engine reads both views through), whose walk takes longer and is what the
/// rest and the pulse show. Either answer is landed off the main actor (`ReachLanding`) from the file
/// as it is, and the main actor swaps the landing in.
///
/// **The timing.** Each new subject shows its hop 1 at once; once the pointer has rested on it
/// (`ReachStyle.rest`) the board dims and the rest of its reach comes in a hop at a time (the pulse,
/// settled at once with Reduce Motion), and the dim stays as the pointer goes from shape to shape, each
/// showing its hop 1 until it rests. ⌥ held or let go shows the other pole's hop 1 at once and its
/// pulse after the rest. With nothing hovered the dim and the lights stay `ReachStyle.release`, then
/// go; the shape left, hovered again meanwhile, keeps what it showed. A drag hides it all.
///
/// **Asking again.** A change to the edges that touches the shape or a shape a light matched, a
/// commit that names the shape (other than by moving it), adds a shape, or names a shape matched or
/// drawn as a card, reaches another board or replaces the document, asks again once commits have
/// stopped for `ReachStyle.settle`, keeping the pulse where it is. Another board shown lets go.
@MainActor
public final class ReachState {
    private unowned let editor: CanvasEditor
    private let lights: [NeighborLight]
    private let lightKeys: [Modifiers]
    private let choosing: Modifiers
    private let settings: ReachSettings
    /// Each light's color at each ring step, made once, so a group made again compares equal.
    private var colors: [[NSColor?]]

    /// The shape hovered, as the last look found it.
    public private(set) var subject: ShapeID?
    /// The shape whose reach shows: the subject, or the one left while the release waits.
    public private(set) var showing: ShapeID?
    /// The keys held of `choosing`, as the last look found them.
    private var keys: Modifiers = []
    /// The one-hop answer for `showing`, landed.
    private var oneHop: ReachLanding?
    /// The reach for `showing`, landed.
    private var reach: ReachLanding?
    /// Whether the pointer has rested on the subject with these keys.
    private var rested = false
    /// Whether the board is dimmed: a hover rested, and nothing has been let go of since.
    public private(set) var dims = false
    /// Whether this subject's pulse has begun, and the step it's at (`ReachStyle.pulseTiers` settled).
    private var pulseBegun = false
    public private(set) var pulseStep = 0
    private var shown = Outlines()
    /// What `shown` was made from, so the same isn't made twice.
    private var composedFrom: Composed?
    private var landings = 0

    private var asking: Task<Void, Never>?
    private var reaching: Task<Void, Never>?
    private var turn: ScheduledTask?
    private var resting: ScheduledTask?
    private var releasing: ScheduledTask?
    private var pulsing: ScheduledTask?
    private var settling: ScheduledTask?
    private var following: TopologyFollowing?
    /// The one-hop answer of the ask under way, by light, once it is worked out: what a light whose reach failed shows in its place.
    private var oneHopFound: (subject: ShapeID, found: [ReachFound])?
    /// Whether the edges changed while an ask was out: the answer may be older than the edges, so it is asked again once it lands.
    private var changedWhileAsking = false

    #if DEBUG
    /// How many times the engine was asked (debug builds): each ask is a one-hop batch and a reach batch.
    public private(set) var asked = 0
    /// How many reach requests the asks batched (debug builds): one a light.
    public private(set) var reachRequested = 0
    /// How many answers were landed (debug builds), each off the main actor.
    public private(set) var landed = 0
    /// How many of them were worked out on the main thread (debug builds): none should be.
    public private(set) var landedOnMain = 0
    #endif

    private struct Composed: Equatable {
        var landing: Int
        var keys: Modifiers
        var step: Int
        var dims: Bool
    }

    init(editor: CanvasEditor, lights: [NeighborLight], settings: ReachSettings) {
        self.editor = editor
        self.lights = lights
        self.settings = settings
        lightKeys = lights.map(\.keys)
        choosing = lights.reduce([]) { $0.union($1.keys) }
        colors = lights.map { _ in Array(repeating: nil, count: ReachStyle.ringSteps + 1) }
        following = editor.topology?.follow { [weak self] change in self?.edgesChanged(change) }
        let (now, held) = watch()
        keys = held
        // A shape hovered as the state is made is its subject, so it rests, dims and is let go of as any is.
        subject = now
        if let now { begin(now) }
    }

    /// Whether an answer is on its way, a look at the hover or an ask after commits is due: what a test waits out.
    public var isAsking: Bool { asking != nil || reaching != nil || turn != nil }

    /// Whether the reach for the shape shown has landed.
    public var hasReach: Bool { reach != nil && reach?.subject == showing }

    /// Returns once no answer is on its way.
    public func landed() async {
        while asking != nil || reaching != nil {
            if let asking { await asking.value }
            if let reaching { await reaching.value }
        }
    }

    // MARK: The subject

    private func watch() -> (ShapeID?, Modifiers) {
        withObservationTracking {
            let onCanvas = editor.hovered, elsewhere = editor.hoveredElsewhere
            return (onCanvas ?? elsewhere, editor.modifiersHeld.intersection(choosing))
        } onChange: { [weak self] in
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

    private func look() {
        let (next, held) = watch()
        let rekeyed = held != keys
        keys = held
        if next == subject {
            if rekeyed { restart() }
            return
        }
        subject = next
        guard let next else {
            // Let go of: what shows stays a moment, then goes.
            resting?.cancel()
            resting = nil
            releasing?.cancel()
            releasing = editor.scheduler.schedule(after: ReachStyle.release) { [weak self] in
                self?.releasing = nil
                self?.stop()
            }
            return
        }
        releasing?.cancel()
        releasing = nil
        if next == showing {
            // Back on the shape left before it went: as it was, resting again if it hadn't.
            if rekeyed { restart() } else if !rested { rest() }
            return
        }
        begin(next)
    }

    /// A new shape: its hop 1 as soon as it lands, the rest after the rest.
    private func begin(_ shape: ShapeID) {
        showing = shape
        rested = false
        pulseBegun = false
        pulseStep = 0
        pulsing?.cancel()
        pulsing = nil
        rest()
        ask(about: shape)
    }

    /// Other keys on the same shape: the other pole's hop 1 at once, its pulse after the rest.
    private func restart() {
        rested = false
        pulseBegun = false
        pulseStep = 0
        pulsing?.cancel()
        pulsing = nil
        if subject != nil { rest() }
        compose()
    }

    private func rest() {
        resting?.cancel()
        resting = editor.scheduler.schedule(after: ReachStyle.rest) { [weak self] in
            guard let self else { return }
            resting = nil
            guard subject != nil else { return }
            rested = true
            dims = true
            beginPulse()
            compose()
        }
    }

    // MARK: The pulse

    /// Once rested with the reach landed: a hop at a time, or settled at once with no pulse or less motion.
    private func beginPulse() {
        guard rested, !pulseBegun, hasReach else { return }
        pulseBegun = true
        if !ReachStyle.pulses || settings.reducesMotion() {
            pulseStep = ReachStyle.pulseTiers
            return
        }
        pulseStep = 0
        stepPulse()
    }

    private func stepPulse() {
        pulsing = editor.scheduler.schedule(after: ReachStyle.pulseStep) { [weak self] in
            guard let self else { return }
            pulsing = nil
            pulseStep += 1
            compose()
            if pulseStep < ReachStyle.pulseTiers { stepPulse() }
        }
    }

    // MARK: Asking

    private func edgesChanged(_ change: TopologyChange) {
        guard let showing else { return }
        if asking != nil || reaching != nil { changedWhileAsking = true }
        guard change.touched.contains(showing) || !change.touched.isDisjoint(with: reach?.matched ?? [])
            || !change.touched.isDisjoint(with: oneHop?.matched ?? []) else { return }
        askSoon()
    }

    /// Asks again once commits have stopped for a moment: one ask for a run of them.
    private func askSoon() {
        settling?.cancel()
        settling = editor.scheduler.schedule(after: ReachStyle.settle) { [weak self] in
            guard let self else { return }
            settling = nil
            if let showing { ask(about: showing) }
        }
    }

    /// Asks the one hop and the reach of every light for `shape`, each in one batch, and lands each
    /// off the main actor. What shows stays until they land.
    private func ask(about shape: ShapeID) {
        guard let queries = editor.queries, let topology = editor.topology, !lights.isEmpty else { return stop() }
        asking?.cancel()
        reaching?.cancel()
        changedWhileAsking = false
        oneHopFound = nil
        let views: [EdgeView] = topology.hasStandIns ? [.resolved, .literal] : [.resolved]
        let selector = "#\(shape)"
        var hops: [QueryMatchRequest] = []
        hops.reserveCapacity(lights.count * views.count)
        for light in lights {
            let text = light.lit(selector)
            for view in views { hops.append(QueryMatchRequest(text, edges: view, limit: QueryMatchRequest.every)) }
        }
        let reaches = lights.map {
            QueryReachRequest(step: $0.query(":scope"), between: $0.between?(":scope"), start: shape,
                              strength: { hop, share in ReachStyle.strength(hop: hop, share: share) })
        }
        #if DEBUG
        asked += 1
        reachRequested += reaches.count
        #endif
        let count = views.count, keys = lightKeys
        // Neither task holds the state across an `await`: each takes it again (`self?`) when it resumes, so a window closed
        // while an answer is on its way lets the editor and its services go, and what resumes finds nothing to land on.
        asking = Task { [weak self, queries] in
            let answers = await queries.matches(hops)
            guard !Task.isCancelled else { return }
            let found = keys.indices.map { ReachFound(oneHop: Self.merged(answers[$0 * count ..< ($0 + 1) * count])) }
            guard let ground = self?.answered(oneHop: found, for: shape) else { return }
            let landing = await Self.land(found, keys: keys, subject: shape, file: ground.file, board: ground.board)
            guard !Task.isCancelled else { return }
            self?.tookOneHop(landing)
        }
        reaching = Task { [weak self, queries] in
            let answers = await queries.reaches(reaches)
            guard !Task.isCancelled else { return }
            var found = answers.map { answer -> ReachFound? in
                guard case .success(let reach) = answer else { return nil }
                return ReachFound(reach)
            }
            // A reach that failed (too slow, a refusal) shows what the one hop did: every light's when all failed (and no pulse), a
            // failed light's alone otherwise.
            if found.contains(where: { $0 == nil }) {
                if let asking = self?.asking { await asking.value }
                guard !Task.isCancelled else { return }
                let failed = found.indices.filter { found[$0] == nil }
                if failed.count == found.count {
                    self?.reachFailed()
                    return
                }
                if let hop = self?.oneHopFound, hop.subject == shape {
                    for index in failed { found[index] = hop.found[index] }
                }
            }
            guard let ground = self?.ground else { return }
            let landing = await Self.land(found, keys: keys, subject: shape, file: ground.file, board: ground.board)
            guard !Task.isCancelled else { return }
            self?.tookReach(landing)
        }
    }

    /// The file and the board shown, as a landing reads them: values, taken on the main actor.
    private var ground: (file: CanvasFile, board: BoardID) { (editor.file, editor.board) }

    /// The one-hop answer is in: kept, so a light whose reach fails can show it, and the file to land it on.
    private func answered(oneHop found: [ReachFound], for shape: ShapeID) -> (file: CanvasFile, board: BoardID) {
        oneHopFound = (shape, found)
        return ground
    }

    private func tookOneHop(_ landing: ReachLanding) {
        asking = nil
        oneHop = landing
        took(landing)
        askAgainIfEdgesChanged()
    }

    private func tookReach(_ landing: ReachLanding) {
        reaching = nil
        reach = landing
        took(landing)
        beginPulse()
        compose()
        askAgainIfEdgesChanged()
    }

    /// Every light's reach failed: the one hop stays, and no pulse runs.
    private func reachFailed() {
        reaching = nil
        askAgainIfEdgesChanged()
    }

    /// Once both answers are in: if the edges changed while they were out, they may be older than the edges, so ask again soon.
    private func askAgainIfEdgesChanged() {
        guard changedWhileAsking, asking == nil, reaching == nil else { return }
        changedWhileAsking = false
        askSoon()
    }

    private func took(_ landing: ReachLanding) {
        landings += 1
        #if DEBUG
        landed += 1
        if landing.madeOnMainThread { landedOnMain += 1 }
        #endif
        compose()
    }

    /// What a light matched in its views: each shape once, the first view's first.
    private static func merged<Refusal: Error>(_ answers: ArraySlice<Result<QueryMatches, Refusal>>) -> [ShapeID] {
        var ids: [ShapeID] = []
        for case .success(let answer) in answers where !answer.ids.isEmpty {
            if ids.isEmpty {
                ids = answer.ids
            } else if answer.ids != ids {
                var seen = Set(ids)
                ids += answer.ids.filter { seen.insert($0).inserted }
            }
        }
        return ids
    }

    @concurrent
    nonisolated private static func land(_ found: [ReachFound?], keys: [Modifiers], subject: ShapeID, file: CanvasFile,
                                         board: BoardID) async -> ReachLanding {
        ReachLanding.land(found, keys: keys, subject: subject, file: file, board: board)
    }

    // MARK: What shows

    /// What the canvas draws for the shape shown, from the best answer landed for it: its reach once
    /// rested at the pulse's step, else hop 1; the dim while the board dims.
    private func compose() {
        guard showing != nil else { return }
        let whole = hasReach ? reach : nil, hop = oneHop?.subject == showing ? oneHop : nil
        // Rested, the reach at the pulse's step; before, hop 1 of whichever answer landed.
        let (landing, step) = rested && whole != nil ? (whole, pulseStep) : (hop ?? whole, 0)
        guard let landing else { return }
        let from = Composed(landing: landings, keys: keys, step: step, dims: dims)
        guard from != composedFrom else { return }
        composedFrom = from
        let lit = landing.shown[keys]
        var tinted: [TintedOutlines] = []
        let last = ReachLanding.lastTier(atStep: step), arriving = ReachLanding.arriving(atStep: step)
        for group in lit?.groups ?? [] where group.tier <= last {
            let ringStep = group.tier == arriving ? ReachStyle.ringSteps : group.step
            tinted.append(TintedOutlines(color: color(group.light, ringStep), shapes: group.shapes, ring: group.ring,
                                         width: ReachStyle.width(ReachStyle.strength(ofStep: ringStep))))
        }
        // A shape that reaches nothing leaves the board as it is: there is nothing to pick out.
        var dim: Dimming?
        if dims, !tinted.isEmpty {
            dim = Dimming(focus: lit?.focus[step] ?? landing.subjectFocus)
        }
        show(Outlines(tinted: tinted, dim: dim))
    }

    private func color(_ light: Int, _ step: Int) -> NSColor {
        if let made = colors[light][step] { return made }
        let made = ReachStyle.color(lights[light].color, step: step)
        colors[light][step] = made
        return made
    }

    private func show(_ next: Outlines) {
        shown = next
        editor.setNeedsDisplay()
    }

    /// Lets go of everything: nothing shows until a shape is hovered again.
    func stop() {
        for task in [asking, reaching] { task?.cancel() }
        for task in [resting, releasing, pulsing, settling] { task?.cancel() }
        asking = nil
        reaching = nil
        resting = nil
        releasing = nil
        pulsing = nil
        settling = nil
        showing = nil
        oneHop = nil
        oneHopFound = nil
        changedWhileAsking = false
        reach = nil
        rested = false
        dims = false
        pulseBegun = false
        pulseStep = 0
        composedFrom = nil
        if shown != Outlines() { show(Outlines()) }
    }

    /// What the core draws: none while a session runs (a drag).
    var outlines: Outlines { editor.session == nil ? shown : Outlines() }

    // MARK: Commits

    /// Whether a commit calls for the reach again: it names the shape other than by moving it, adds a
    /// shape, names a shape matched or drawn as a card, reaches another board or replaces the document.
    private func needsAnswer(_ changes: ChangeSet, about shape: ShapeID) -> Bool {
        if changes.replacedDocument || !changes.boardsReached.isEmpty || !changes.added.isEmpty { return true }
        if changes.elsewhere.contains(shape) || (changes.changed.contains(shape) && !changes.moved.contains(shape)) { return true }
        for landing in [oneHop, reach].compactMap({ $0 }) {
            if names(changes, in: landing.matched) || names(changes, in: landing.cards) { return true }
        }
        return false
    }

    private func names(_ changes: ChangeSet, in shapes: Set<ShapeID>) -> Bool {
        !changes.removed.isDisjoint(with: shapes) || !changes.elsewhere.isDisjoint(with: shapes)
            || !changes.changed.intersection(shapes).isSubset(of: changes.moved)
    }

    func documentDidChange(_ changes: ChangeSet) {
        guard let showing, needsAnswer(changes, about: showing) else { return }
        askSoon()
    }

    func boardDidChange() {
        subject = nil
        stop()
    }
}

extension ReachLanding {
    /// The dim's focus with nothing lit: the shape hovered, as it's drawn on the board shown.
    var subjectFocus: [ShapeID: CGFloat] { subjectDrawn.map { [$0: 1] } ?? [:] }
}

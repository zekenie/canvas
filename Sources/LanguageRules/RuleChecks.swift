import Canvas
import CanvasRPC
import DecisionModels
import Foundation
import Mentions
import Queries
import Topology
import Types
import Validation

/// What a decision model answered of a shape's rules, and what it was shown.
public struct RuleVerdict: Equatable, Sendable {
    /// The rules asked, in the order asked (most general type's first).
    public var rules: [ChainedRule]
    /// How likely it is that the rules read together flag the shape; nil if the model left it unanswered.
    public var together: Double?
    /// How likely it is that each rule, read with the others, flags the shape, in the rules' order.
    public var each: [Double?]
    /// Which model answered ("jev-1.14.0").
    public var model: String
    /// What it was asked: the state it was shown and the questions.
    public var sent: DecisionRequest
    /// The state's groups, by the shapes in them (`RuleShownGroup`): what the panel lists as Shown.
    public var shown: [RuleShownGroup]
}

/// A rule as its count is kept: the type that carries it, and its sentence.
public struct RuleKey: Hashable, Sendable {
    public let type: ShapeID
    public let says: String

    public init(type: ShapeID, says: String) {
        self.type = type
        self.says = says
    }

    /// The rule as an issue's source: the type's id and the sentence, which the warnings and `refreshFlags` both build.
    public var source: IssueSource { IssueSource(plugin: RuleValidationPlugin.id, key: "\(type.description)|\(says)") }

    /// The rule a source is for, nil for another plugin's or a key that is no rule's: the way back from a warning to
    /// `flagged(by:)`.
    public init?(source: IssueSource) {
        guard source.plugin == RuleValidationPlugin.id, let bar = source.key.firstIndex(of: "|"),
              let uuid = UUID(uuidString: String(source.key[..<bar])) else { return nil }
        self.init(type: ShapeID(uuid), says: String(source.key[source.key.index(after: bar)...]))
    }
}

/// What a shape's check says of one of its rules, as the panel lists it.
public enum RuleState: Equatable, Sendable {
    /// The rule flags the shape: its warning shows.
    case flags
    /// It holds, or read with the others it does.
    case holds
    /// The answer was between the model's cutoffs.
    case unsure
    /// The shape ignores it.
    case ignored
    /// Being asked again, or not asked yet.
    case checking
}

/// A rule of a shape's chain, with what its check says of it.
public struct RuleStanding: Equatable, Sendable {
    public let rule: ChainedRule
    public let state: RuleState
}

/// Where a shape's check stands.
public enum RuleCheck: Equatable, Sendable {
    /// Being checked: the last answer, kept until the new one lands, if there was one.
    case checking(RuleVerdict?)
    case checked(RuleVerdict)
    /// The model didn't answer: why, and the last answer, if there was one, which still counts.
    case failed(DecisionModelError, RuleVerdict?)

    /// The answer that counts now.
    public var verdict: RuleVerdict? {
        switch self {
        case .checking(let verdict), .failed(_, let verdict): verdict
        case .checked(let verdict): verdict
        }
    }
}

/// Checks every shape whose types carry rules against them, file-wide, the board shown first, and keeps what the
/// decision model answered (`editor.ruleChecks`). It hears every commit and marks the shapes whose check it may change:
/// a shape the commit wrote, the shapes whose state read one, those of a type whose rules or words changed, those
/// beside a shape put down, put in its container or taken out of it; never for a commit that only moved shapes where
/// they were. It waits for quiet (editing ends, or `quiet` with no commit; an agent's commit, the next turn), builds
/// what each rule sees off the main actor from one snapshot (`RuleContext`), and asks through `editor.decisions`
/// (which answers what it asked today from memory), at most `inFlight` at a time. As answers land, Validation checks
/// the shape again; its warnings are `issues(of:)`. While anything is still to check, Topology settles, though no
/// edge does (`keepsSettling(edges: false)`), so a query that holds a word that waits for answers waits for these,
/// and one that reads only edges doesn't.
@MainActor
@Observable
public final class RuleChecks {
    /// How long a file is quiet before what changed is checked.
    public static let quiet: Duration = .seconds(3)
    /// The most calls out at once.
    public static let inFlight = 8

    @ObservationIgnored private weak var editor: CanvasEditor?
    /// The questions' words; with none, nothing is asked.
    @ObservationIgnored let prompts: RulePrompts?
    /// Today, as a state says it: the system's, unless a test says.
    @ObservationIgnored public var today: @MainActor () -> String = { DecisionMemory.systemToday() }

    @ObservationIgnored private var checks: [ShapeID: RuleCheck] = [:]
    /// Shapes to check at the next pass.
    @ObservationIgnored private var dirty: Set<ShapeID> = []
    /// A shape's checks so far: an answer to an older one is dropped.
    @ObservationIgnored private var generation: [ShapeID: Int] = [:]
    /// What each shape's state read, and the other way: which states read a shape.
    @ObservationIgnored private var footprints: [ShapeID: Set<ShapeID>] = [:]
    @ObservationIgnored private var readers: [ShapeID: Set<ShapeID>] = [:]
    /// Each checked shape's container (`nil` key: the top level), and the shapes whose states list a container's.
    @ObservationIgnored private var places: [ShapeID: ShapeID?] = [:]
    @ObservationIgnored private var placeReaders: [ShapeID?: Set<ShapeID>] = [:]
    /// The container of each shape a state read, as it was then: a shape moved out of or into another isn't beside
    /// the same shapes, and what it holds isn't where it was.
    @ObservationIgnored private var readPlaces: [ShapeID: ShapeID?] = [:]
    /// Shapes whose edges changed since the last commit was heard (Topology's follow).
    @ObservationIgnored private var edgesTouched: Set<ShapeID> = []
    @ObservationIgnored private var pass: ScheduledTask?
    /// The contexts being built, by the pass that builds them: an older build that finishes says nothing.
    @ObservationIgnored private var building: (pass: Int, task: Task<Void, Never>)?
    @ObservationIgnored private var passes = 0
    @ObservationIgnored private var queue: [Ask] = []
    /// The call out for each shape, by the ask that made it: an older one that lands frees no slot of a newer.
    @ObservationIgnored private var asking: [ShapeID: (ask: Int, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var asks = 0
    /// The day the last pass was for: a pass on another day asks every shape again, the day being in each state.
    @ObservationIgnored private var dayAsked: String?
    @ObservationIgnored private var settling: SettleSource?
    @ObservationIgnored private var following: TopologyFollowing?
    @ObservationIgnored nonisolated(unsafe) private var keyObserver: (any NSObjectProtocol)?
    @ObservationIgnored nonisolated(unsafe) private var dayObserver: (any NSObjectProtocol)?
    /// Whether each kind is checked: it holds `ignoredRules`.
    @ObservationIgnored private var checkedKinds: [ShapeKind: Bool] = [:]
    /// Each type's rules, by the schema's text they were read from, so a schema is read once a change; and the types
    /// that have any, so a file with none marks nothing.
    @ObservationIgnored private var typeRules: [ShapeID: (text: String, rules: [Rule])] = [:]
    @ObservationIgnored private var typesWithRules: Set<ShapeID> = []
    /// The types whose rules have a chip with a query, and what each checked shape's chips found as its state was last
    /// built: what a pass compares, after a commit that wrote anything, to ask again only those whose finds changed.
    @ObservationIgnored private var typesWithChips: Set<ShapeID> = []
    @ObservationIgnored private var chipFinds: [ShapeID: [ChipFind]] = [:]
    /// The types whose rules have a chip with a query, as last read.
    var chipTypes: Set<ShapeID> { typesWithChips }
    /// A commit wrote something since the chips were last asked: what they find may have changed, however far away.
    @ObservationIgnored private var chipsStale = false
    /// The rules each shape's warnings are for, and the other way: the shapes a rule flags (`flagged(by:)`).
    @ObservationIgnored private var flagging: [ShapeID: Set<RuleKey>] = [:]
    @ObservationIgnored private var flaggedBy: [RuleKey: Set<ShapeID>] = [:]
    /// The checks that failed, and why.
    @ObservationIgnored private var failures: [ShapeID: DecisionModelError] = [:]
    /// Moves when a count or a failure does: what a type's Rules tab observes.
    @ObservationIgnored private var flagsTold = 0

    private struct Ask {
        let id: ShapeID
        let generation: Int
        let rules: [ChainedRule]
        let request: DecisionRequest
        let shown: [RuleShownGroup]
    }

    init(editor: CanvasEditor, prompts: RulePrompts?) {
        self.editor = editor
        self.prompts = prompts
        // What settles here is no edge: only a query that waits for verdicts waits for it.
        settling = editor.topology?.keepsSettling(edges: false) { [weak self] in self?.isBusy ?? false }
        following = editor.topology?.follow { [weak self] change in
            guard let self else { return }
            edgesTouched.formUnion(change.touched)
            // A stand-in answered with no commit: what reads through it is marked a turn later, out of the delivery.
            if change.cause == .provide {
                _ = self.editor?.scheduler.schedule(after: .zero) { [weak self] in self?.heardEdges() }
            }
        }
        keyObserver = NotificationCenter.default.addObserver(forName: .decisionModelKeyDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyDidChange() }
        }
        dayObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dayChanged() }
        }
        _ = editor.scheduler.schedule(after: .zero) { [weak self] in self?.markEveryShape() }
    }

    isolated deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        if let dayObserver { NotificationCenter.default.removeObserver(dayObserver) }
        pass?.cancel()
        building?.task.cancel()
        for call in asking.values { call.task.cancel() }
        following?.cancel()
        settling?.cancel()
    }

    // MARK: What's known

    /// Where a shape's check stands; nil for a shape no rule checks. Observed by the shape (a view that reads it draws
    /// again as it changes, and as the shape is marked to be checked again).
    public func check(of id: ShapeID) -> RuleCheck? {
        access(keyPath: \.[observed: id])
        return checks[id]
    }

    /// Whether rules check a shape: it has a check, or is marked for its first. O(1), and observed by the shape, so the
    /// Issues tab's Rules section comes as the shape is first marked, with no commit to it.
    public func hasCheck(_ id: ShapeID) -> Bool {
        access(keyPath: \.[observed: id])
        return checks[id] != nil || dirty.contains(id)
    }

    /// A type's rules as the file has them now.
    public func rules(ofType type: ShapeID) -> [Rule] { rules(of: type) }

    /// The rules a shape is checked against now (`RuleBook.chain`).
    public func currentChain(for shape: ShapeID) -> [ChainedRule] { chain(for: shape) }

    /// Whether a shape is marked to be checked again, or being checked: what the panel says is checking.
    public func isChecking(_ id: ShapeID) -> Bool {
        access(keyPath: \.[observed: id])
        if dirty.contains(id) { return true }
        if case .checking? = checks[id] { return true }
        return false
    }

    private subscript(observed id: ShapeID) -> RuleCheck? { checks[id] }

    /// A shape's check, set: what observes it is told, and the rules it flags are counted again.
    private func setCheck(_ check: RuleCheck?, of id: ShapeID) {
        withMutation(keyPath: \.[observed: id]) { checks[id] = check }
        let failed: DecisionModelError? = if case .failed(let error, _)? = check { error } else { nil }
        if failures[id] != failed {
            failures[id] = failed
            withMutation(keyPath: \.flagsCount) { flagsTold &+= 1 }
        }
        refreshFlags(of: id)
    }

    // MARK: Counts

    private var flagsCount: Int { flagsTold }

    /// The shapes `rule` flags now: those its warning shows on.
    public func flagged(by rule: RuleKey) -> Set<ShapeID> {
        access(keyPath: \.flagsCount)
        return flaggedBy[rule] ?? []
    }

    /// Why shapes aren't checked, while some failed: the want of a key first, which fails every call, else the first
    /// failure; nil while none failed.
    public var failure: DecisionModelError? {
        access(keyPath: \.flagsCount)
        return failures.values.first(where: \.needsKey) ?? failures.values.min { $0.message < $1.message }
    }

    /// Counts the rules a shape's answer flags again: its check landed or went, or what it ignores changed.
    private func refreshFlags(of id: ShapeID) {
        var now: Set<RuleKey> = []
        if let editor, let verdict = checks[id]?.verdict, let record = editor.withoutObservingDocument({ editor.file.record(id) }) {
            now = Set(flaggingRules(of: record, in: verdict).map { RuleKey(type: verdict.rules[$0].type, says: verdict.rules[$0].rule.says) })
        }
        let before = flagging[id] ?? []
        guard now != before else { return }
        for key in before.subtracting(now) {
            flaggedBy[key]?.remove(id)
            if flaggedBy[key]?.isEmpty == true { flaggedBy[key] = nil }
        }
        for key in now.subtracting(before) { flaggedBy[key, default: []].insert(id) }
        flagging[id] = now.isEmpty ? nil : now
        withMutation(keyPath: \.flagsCount) { flagsTold &+= 1 }
    }

    /// Every shape a rule checks, with where its check stands.
    public var allChecks: [ShapeID: RuleCheck] { checks }

    /// Whether a check is still to land: shapes marked and a pass coming, contexts being built, or calls out.
    public var isBusy: Bool { (pass != nil && !dirty.isEmpty) || building != nil || !queue.isEmpty || !asking.isEmpty }

    /// The cutoffs the editor's model answers by.
    var cutoffs: DecisionCutoffs { editor?.decisionModel?.cutoffs ?? .standard }

    /// The warnings a shape's answer gives, less the rules it ignores: one for each rule whose own answer flags it,
    /// highest first, once the rules read together flag it; where none flags alone, the rule answered highest, unless
    /// a rule the shape ignores flags it (that was the one). Nothing while the rules read together don't flag it, or
    /// it's unsure. Each offers Ignore and Show Rule.
    public func issues(of shape: AnyShapeRecord) -> [ValidationIssue] {
        guard let verdict = checks[shape.id]?.verdict else { return [] }
        let editor = editor, id = shape.id
        return flaggingRules(of: shape, in: verdict).map { i in
            let rule = verdict.rules[i]
            return .warning(rule.rule.says, actions: [
                IssueAction(RulesStyle.ignore, role: .ignore) { [weak editor] in _ = editor?.ruleWriter?.ignore(rule.rule.says, on: id) },
                IssueAction(RulesStyle.showRule) { [weak editor] in editor?.showRule(rule) },
            ], source: RuleKey(type: rule.type, says: rule.rule.says).source)
        }
    }

    /// The rules a shape's answer flags it by, as places in the answer's rules: those `issues(of:)` warns of.
    func flaggingRules(of shape: AnyShapeRecord, in verdict: RuleVerdict) -> [Int] {
        guard let together = verdict.together, cutoffs.verdict(together) == .yes else { return [] }
        let ignored = Set(shape[IgnoredRulesProperty.self] ?? [])
        let ranked = verdict.rules.indices.sorted { (verdict.each[$0] ?? 0) > (verdict.each[$1] ?? 0) }
        let flagging = ranked.filter { (verdict.each[$0]).map { cutoffs.verdict($0) == .yes } ?? false }
        let kept = flagging.filter { !ignored.contains(verdict.rules[$0].rule.says) }
        if !kept.isEmpty { return kept }
        guard flagging.isEmpty, let top = ranked.first(where: { !ignored.contains(verdict.rules[$0].rule.says) }) else { return [] }
        return [top]
    }

    /// Each rule of a shape's chain as it is now, with what its check says of it: checking while the shape is marked
    /// or asked again (its last answer still counts on the board) and for a rule its last answer didn't ask; else
    /// ignored where the shape ignores it, flags where it warns, holds where its own answer says so (or says it flags
    /// while the rules read together hold), unsure where its answer is between the cutoffs. Observed by the shape.
    public func verdicts(of shape: AnyShapeRecord) -> [RuleStanding] {
        let rules = chain(for: shape.id)
        let checking = isChecking(shape.id)
        guard !checking, let verdict = checks[shape.id]?.verdict else {
            return rules.map { RuleStanding(rule: $0, state: .checking) }
        }
        let ignored = Set(shape[IgnoredRulesProperty.self] ?? [])
        let flags = Set(flaggingRules(of: shape, in: verdict))
        let together = verdict.together.map(cutoffs.verdict)
        return rules.map { rule in
            guard let i = verdict.rules.firstIndex(where: { $0.type == rule.type && $0.rule.says == rule.rule.says }) else {
                return RuleStanding(rule: rule, state: .checking)
            }
            if ignored.contains(rule.rule.says) { return RuleStanding(rule: rule, state: .ignored) }
            if flags.contains(i) { return RuleStanding(rule: rule, state: .flags) }
            // A rule that flags alone holds when the rules read together hold: another qualified it.
            switch verdict.each[i].map(cutoffs.verdict) {
            case .no?: return RuleStanding(rule: rule, state: .holds)
            case .unsure?: return RuleStanding(rule: rule, state: .unsure)
            case .yes?, nil: return RuleStanding(rule: rule, state: together == .no ? .holds : .unsure)
            }
        }
    }

    /// What a shape's answer was shown: the state sent, and its groups by the shapes in them; nil before an answer.
    public func sent(for id: ShapeID) -> (state: JSONValue, groups: [RuleShownGroup])? {
        access(keyPath: \.[observed: id])
        guard let verdict = checks[id]?.verdict else { return nil }
        return (verdict.sent.state, verdict.shown)
    }

    // MARK: Hearing commits

    /// What a commit may have changed of the checks, read once every service has it (the types, Topology).
    func heard(_ changes: ChangeSet) {
        guard let editor else { return }
        if changes.replacedDocument { return markEveryShape() }
        var touched = changes.added.union(changes.removed).union(changes.changed.subtracting(changes.moved)).union(changes.elsewhere)
        touched.formUnion(edgesTouched)
        edgesTouched = []
        let snapshot = editor.topology?.snapshot()
        var marked: Set<ShapeID> = []
        // A shape moved or written into or out of a container is beside other shapes now, and those beside it before
        // and after see it come or go; one that only moved where it was changes no state.
        for id in changes.moved.union(touched).subtracting(changes.removed) {
            let now = snapshot?.parent(of: id)
            if let before = places[id] ?? readPlaces[id], before != now {
                touched.insert(id)
                marked.formUnion(placeReaders[before] ?? [])
                marked.formUnion(placeReaders[now] ?? [])
            }
        }
        for id in touched {
            if checks[id] != nil { refreshFlags(of: id) }
            marked.formUnion(readers[id] ?? [])
            marked.insert(id)
            // A type changed: its rules, its words or what it builds on may have; each of its shapes is asked again.
            if let types = editor.types, types.isType(id) || typeRules[id] != nil {
                let had = typesWithRules.contains(id)
                if !rules(of: id).isEmpty || had { marked.formUnion(types.allInstances(of: id)) }
            }
        }
        // A shape put down, on this board or another, is beside those in its container.
        for id in changes.added.union(changes.elsewhere) {
            marked.formUnion(placeReaders[snapshot?.parent(of: id)] ?? [])
        }
        // What a chip finds may change with any write, wherever it is: the next pass asks the chips again, and checks
        // again the shapes whose chips find something else. A commit that only moved shapes asks nothing.
        if !touched.isEmpty, !typesWithChips.isEmpty { chipsStale = true }
        // What an agent draws is checked at once: it may ask straight after, and no one is typing.
        mark(marked, soon: changes.byAgent)
    }

    /// What a stand-in's answer changed of the edges, with no commit to say so: the shapes whose edges moved, and the
    /// states that read them.
    private func heardEdges() {
        var marked = edgesTouched
        edgesTouched = []
        // What a chip finds through the edges may have changed too (a stand-in's answer).
        if !marked.isEmpty, !typesWithChips.isEmpty { chipsStale = true }
        for id in marked { marked.formUnion(readers[id] ?? []) }
        mark(marked)
    }

    /// Every shape of the file a rule may check, marked: as the file opens, and when another is put in its place.
    private func markEveryShape() {
        guard let editor, let types = editor.types else { return }
        typeRules = [:]
        typesWithRules = []
        typesWithChips = []
        var marked: Set<ShapeID> = []
        for type in types.graph.types where !rules(of: type).isEmpty {
            marked.formUnion(types.allInstances(of: type))
        }
        marked.formUnion(checks.keys)
        mark(marked)
    }

    /// A type's rules as the file has them now, read again only when its schema's text changed.
    private func rules(of type: ShapeID) -> [Rule] {
        guard let editor, let text = editor.withoutObservingDocument({ editor.file.record(type) })?[TypeSchemaProperty.self]?.text else {
            typeRules[type] = nil
            typesWithRules.remove(type)
            typesWithChips.remove(type)
            return []
        }
        if let kept = typeRules[type], kept.text == text { return kept.rules }
        let rules = RuleBook.rules(inSchema: text)
        typeRules[type] = (text, rules)
        if rules.isEmpty { typesWithRules.remove(type) } else { typesWithRules.insert(type) }
        if rules.contains(where: { $0.find.contains { $0.query != nil } }) { typesWithChips.insert(type) } else { typesWithChips.remove(type) }
        return rules
    }

    /// The rules `shape` is checked against (`RuleBook.chain`), each type's read as `rules(of:)` keeps it.
    private func chain(for shape: ShapeID) -> [ChainedRule] {
        guard let types = editor?.types else { return [] }
        return RuleBook.chain(for: shape, types: types) { rules(of: $0) }
    }

    /// Marks shapes to check at the next pass, `quiet` from now (`soon`: the next turn); a shape no rule checks is
    /// forgotten.
    private func mark(_ ids: Set<ShapeID>, soon: Bool = false) {
        guard let editor, prompts != nil else { return }
        var any = false
        for id in ids {
            guard isChecked(id) else {
                if checks[id] != nil { forget(id) }
                continue
            }
            generation[id, default: 0] += 1
            if dirty.insert(id).inserted { withMutation(keyPath: \.[observed: id]) {} }
            any = true
        }
        guard any || chipsStale else { return }
        pass?.cancel()
        pass = editor.scheduler.schedule(after: soon ? .zero : Self.quiet) { [weak self] in self?.runPass() }
    }

    /// The day turned over: every shape's state says another day, so each is asked again.
    private func dayChanged() {
        guard dayAsked != nil, dayAsked != today() else { return }
        markEveryShape()
    }

    /// Whether a rule checks `id`: a shape of a kind that holds `ignoredRules`, of a type, no type itself, whose chain
    /// has rules.
    private func isChecked(_ id: ShapeID) -> Bool {
        guard !typesWithRules.isEmpty, let editor, let types = editor.types,
              let record = editor.withoutObservingDocument({ editor.file.record(id) }), !record.isOpaque else { return false }
        let kindChecked = checkedKinds[record.kind] ?? {
            let held = editor.registry.properties(for: record.kind).contains(IgnoredRulesProperty.key)
            checkedKinds[record.kind] = held
            return held
        }()
        guard kindChecked, !(record[IsAProperty.self] ?? []).isEmpty, record[TypeSchemaProperty.self] == nil else { return false }
        return types.lineage(of: id).contains { typesWithRules.contains($0) && !rules(of: $0).isEmpty }
    }

    /// A shape no rule checks now: its answer goes, and Validation checks it again.
    private func forget(_ id: ShapeID) {
        setCheck(nil, of: id)
        dirty.remove(id)
        chipFinds[id] = nil
        asking.removeValue(forKey: id)?.task.cancel()
        queue.removeAll { $0.id == id }
        setFootprint(of: id, to: nil, place: nil)
        editor?.validation?.recheck([id])
    }

    func editingEnded() {
        guard !dirty.isEmpty, let editor else { return }
        pass?.cancel()
        pass = editor.scheduler.schedule(after: .zero) { [weak self] in self?.runPass() }
    }

    private func keyDidChange() {
        let waiting = checks.compactMap { id, check -> ShapeID? in
            guard case let .failed(error, _) = check, error.needsKey else { return nil }
            return id
        }
        guard !waiting.isEmpty, let editor else { return }
        for id in waiting { generation[id, default: 0] += 1 }
        for id in waiting where dirty.insert(id).inserted { withMutation(keyPath: \.[observed: id]) {} }
        pass?.cancel()
        pass = editor.scheduler.schedule(after: .zero) { [weak self] in self?.runPass() }
    }

    /// Checks again what failed for a reason trying again may mend, at once.
    public func retry() {
        let failed = checks.compactMap { id, check -> ShapeID? in if case .failed = check { id } else { nil } }
        guard !failed.isEmpty, let editor else { return }
        for id in failed { generation[id, default: 0] += 1 }
        for id in failed where dirty.insert(id).inserted { withMutation(keyPath: \.[observed: id]) {} }
        pass?.cancel()
        pass = editor.scheduler.schedule(after: .zero) { [weak self] in self?.runPass() }
    }

    // MARK: A pass

    /// Builds what each marked shape's rules see, off the main actor from one snapshot, the board shown first, with what
    /// their chips find (one batch); then asks. After a commit that wrote anything, the chips of every other checked shape
    /// are asked again in the same batch, and those that find something else are checked too. A shape being edited waits
    /// for its editing to end.
    private func runPass() {
        pass = nil
        guard let editor, let prompts, let topology = editor.topology, let types = editor.types, editor.decisions != nil else {
            dirty.removeAll()
            chipsStale = false
            return tellSettled()
        }
        let editing = editor.editingShapeID
        let file = editor.withoutObservingDocument { editor.file }
        let shown = editor.board
        let ids = dirty.filter { $0 != editing }.sorted { a, b in
            let aShown = file.board(containing: a) == shown, bShown = file.board(containing: b) == shown
            return aShown != bShown ? aShown : a.description < b.description
        }
        dirty.subtract(ids)
        var jobs: [Job] = []
        for id in ids {
            let rules = chain(for: id)
            guard !rules.isEmpty else {
                if checks[id] != nil { forget(id) }
                continue
            }
            jobs.append(Job(id: id, generation: generation[id] ?? 0, rules: rules, noun: RuleBook.noun(for: id, in: editor) ?? "shape"))
            setCheck(.checking(checks[id]?.verdict), of: id)
        }
        var others: [ShapeID] = []
        if chipsStale {
            chipsStale = false
            let asked = Set(jobs.map(\.id))
            others = chipShapes().filter { !asked.contains($0) }.sorted { $0.description < $1.description }
        }
        guard !jobs.isEmpty || !others.isEmpty else { return tellSettled() }
        let day = today()
        dayAsked = day
        let world = RuleWorld(snapshot: topology.snapshot(.resolved), graph: types.graph, labels: editor.mentions?.labels ?? MentionLabels(),
                              kinds: Self.readings(of: editor.registry), today: day)
        let bound = (jobs.map(\.id) + others).map { ($0, self.chips(of: $0)) }
        passes += 1
        let number = passes
        building = (number, Task { [weak self] in
            guard let finds = await self?.find(bound, in: world), !Task.isCancelled, let self else { return }
            var built = jobs
            // A shape whose chips find what they found before is as it was.
            for id in others where (finds[id] ?? []) != (self.chipFinds[id] ?? []) && self.isChecked(id) {
                if id == self.editor?.editingShapeID {
                    self.dirty.insert(id)
                    continue
                }
                self.generation[id, default: 0] += 1
                built.append(Job(id: id, generation: self.generation[id] ?? 0, rules: self.chain(for: id),
                                 noun: self.editor.flatMap { RuleBook.noun(for: id, in: $0) } ?? "shape"))
                self.setCheck(.checking(self.checks[id]?.verdict), of: id)
            }
            guard !built.isEmpty else {
                if self.building?.pass == number { self.building = nil }
                return self.tellSettled()
            }
            let asked = built
            let contexts = await Task.detached(priority: .utility) {
                asked.map { RuleContext.build(for: $0.id, in: world, finds: finds[$0.id] ?? []) }
            }.value
            guard !Task.isCancelled else { return }
            if self.building?.pass == number { self.building = nil }
            for (job, context) in zip(asked, contexts) {
                guard self.generation[job.id] == job.generation, let context else { continue }
                self.setFootprint(of: job.id, to: context.footprint, place: context.place)
                self.readPlaces.merge(context.places) { _, new in new }
                self.chipFinds[job.id] = finds[job.id] ?? []
                let request = prompts.request(state: context.state, rules: job.rules, noun: job.noun)
                // An older ask for the shape still waiting is let go: this one is about it now.
                self.queue.removeAll { $0.id == job.id }
                self.queue.append(Ask(id: job.id, generation: job.generation, rules: job.rules, request: request, shown: context.shown))
            }
            self.askNext()
        })
    }

    /// A shape a pass checks: its rules as they are now, and what the questions call it.
    private struct Job: Sendable {
        let id: ShapeID
        let generation: Int
        let rules: [ChainedRule]
        let noun: String
    }

    /// The checked shapes whose rules have a chip with a query.
    private func chipShapes() -> [ShapeID] {
        guard !typesWithChips.isEmpty, let types = editor?.types else { return [] }
        var shapes: Set<ShapeID> = []
        for type in typesWithChips { shapes.formUnion(types.allInstances(of: type)) }
        return shapes.filter(isChecked)
    }

    /// The chips of a shape's rules that have a query, in the chain's order, each phrase and query once.
    private func chips(of id: ShapeID) -> [RuleChip] {
        var seen: Set<RuleChip> = []
        return chain(for: id).flatMap { $0.rule.chipRanges.map(\.chip) }.filter { $0.query != nil && seen.insert($0).inserted }
    }

    /// What each shape's chips find for it: one batch, each request bound to its shape (`:scope`), at most the budget a
    /// state lists; each container found followed by its own shapes, as `world` has them. A refused query finds nothing
    /// to say (the type warns of it).
    private func find(_ chips: [(ShapeID, [RuleChip])], in world: RuleWorld) async -> [ShapeID: [ChipFind]] {
        guard let queries = editor?.queries, chips.contains(where: { !$0.1.isEmpty }) else { return [:] }
        var asked: [(id: ShapeID, phrase: String)] = []
        var requests: [QueryMatchRequest] = []
        for (id, list) in chips {
            for chip in list {
                guard let query = chip.query else { continue }
                asked.append((id, chip.phrase))
                requests.append(QueryMatchRequest(query, scope: id, limit: RuleContext.budget))
            }
        }
        let results = await queries.matches(requests)
        var finds: [ShapeID: [ChipFind]] = [:]
        for ((id, phrase), result) in zip(asked, results) {
            guard case .success(let matches) = result else { continue }
            // Two rules' chips of one phrase are one find, what both found.
            let index = finds[id]?.firstIndex { $0.phrase == phrase }
            var listed = index.map { finds[id]![$0].listed } ?? []
            var seen = Set(listed)
            for found in matches.ids where seen.insert(found).inserted {
                listed.append(found)
                for held in world.snapshot.children(of: found) where seen.insert(held).inserted { listed.append(held) }
            }
            let more = matches.count - matches.ids.count + (index.map { finds[id]![$0].more } ?? 0)
            if let index { finds[id]![index] = ChipFind(phrase: phrase, listed: listed, more: more) }
            else { finds[id, default: []].append(ChipFind(phrase: phrase, listed: listed, more: more)) }
        }
        return finds
    }

    /// What each of `ids` is and what is around it, as a rule sees it (its free context: no chip's finds), keyed by id: the
    /// state a question about a shape is asked with (`canvas decide`'s). Built off the main actor from one snapshot, as a
    /// check's is; a shape that isn't there has none.
    public func states(of ids: [ShapeID]) async -> [ShapeID: JSONValue] {
        guard let editor, let topology = editor.topology else { return [:] }
        let world = RuleWorld(snapshot: topology.snapshot(.resolved), graph: editor.types?.graph ?? TypeGraph(),
                              labels: editor.mentions?.labels ?? MentionLabels(), kinds: Self.readings(of: editor.registry), today: today())
        return await Task.detached(priority: .userInitiated) {
            var states: [ShapeID: JSONValue] = [:]
            for id in ids {
                if let context = RuleContext.build(for: id, in: world) { states[id] = context.state }
            }
            return states
        }.value
    }

    /// Asks the next in line while fewer than `inFlight` calls are out.
    private func askNext() {
        guard let decisions = editor?.decisions else { return tellSettled() }
        while asking.count < Self.inFlight, !queue.isEmpty {
            let ask = queue.removeFirst()
            asking[ask.id]?.task.cancel()
            asks += 1
            let number = asks
            asking[ask.id] = (number, Task { [weak self] in
                let result: Result<DecisionAnswers, DecisionModelError>
                do throws(DecisionModelError) {
                    result = .success(try await decisions.decide(ask.request))
                } catch {
                    result = .failure(error)
                }
                self?.land(ask, number: number, result)
            })
        }
        if asking.isEmpty, queue.isEmpty { tellSettled() }
    }

    private func land(_ ask: Ask, number: Int, _ result: Result<DecisionAnswers, DecisionModelError>) {
        if asking[ask.id]?.ask == number { asking[ask.id] = nil }
        defer { askNext() }
        guard generation[ask.id] == ask.generation, checks[ask.id] != nil else { return }
        switch result {
        case .success(let answers):
            guard let prompts else { return }
            let flag = { (id: String) in answers.yes[id].map { prompts.flagging(id, yes: $0) } }
            setCheck(.checked(RuleVerdict(rules: ask.rules, together: flag(RulePrompts.togetherID),
                                          each: ask.rules.indices.map { flag(RulePrompts.id(ofRule: $0)) },
                                          model: answers.model, sent: ask.request, shown: ask.shown)), of: ask.id)
        case .failure(let error) where error.failure == .cancelled:
            setCheck(checks[ask.id]?.verdict.map { .checked($0) } ?? nil, of: ask.id)
        case .failure(let error):
            setCheck(.failed(error, checks[ask.id]?.verdict), of: ask.id)
            // Every call waiting would fail the same way for want of a key: none is made.
            if error.needsKey {
                for waiting in queue { setCheck(.failed(error, checks[waiting.id]?.verdict), of: waiting.id) }
                editor?.validation?.recheck(Set(queue.map(\.id)))
                queue.removeAll()
            }
        }
        editor?.validation?.recheck([ask.id])
    }

    /// Topology settles once nothing is left to check.
    private func tellSettled() {
        guard !isBusy else { return }
        editor?.topology?.settleSourceChanged()
    }

    private func setFootprint(of id: ShapeID, to footprint: Set<ShapeID>?, place: ShapeID?) {
        for read in footprints[id] ?? [] { readers[read]?.remove(id) }
        if let old = places[id] { placeReaders[old]?.remove(id) }
        footprints[id] = footprint
        places[id] = footprint == nil ? nil : .some(place)
        guard let footprint else { return }
        for read in footprint { readers[read, default: []].insert(id) }
        placeReaders[place, default: []].insert(id)
    }

    /// How each kind's shapes are read in a state: kept once a registry.
    static func readings(of registry: Registry) -> [ShapeKind: RuleKindReading] {
        registry.memo("LanguageRules.readings") {
            var readings: [ShapeKind: RuleKindReading] = [:]
            for kind in registry.kinds {
                let label = registry.label(of: kind).name
                var words: String?
                if let schema = registry.schema(for: kind) {
                    let kindSchema = KindSchema(schema)
                    let texts = kindSchema.properties.keys.sorted().filter { name in
                        kindSchema.properties[name].map { kindSchema.resolved($0)["contentMediaType"]?.stringValue == MentionTextFormat.mediaType } ?? false
                    }
                    words = texts.first { $0 == "text" } ?? texts.first
                }
                readings[kind] = RuleKindReading(noun: label.lowercased(), label: label, words: words,
                                                 isLine: registry.definition(for: kind) is any StrokedShape)
            }
            return readings
        }
    }
}

extension RuleChecks: EditorService {
    public func documentDidSettle(_ changes: ChangeSet, in _: CanvasEditor) { heard(changes) }

    public func editingDidEnd(_: ShapeID, in _: CanvasEditor) { editingEnded() }

    public func boardDidChange(_ change: BoardChange, in _: CanvasEditor) {
        if change.isFileReplaced { markEveryShape() }
    }
}

extension CanvasEditor {
    /// What rules found of the file's shapes: nil without LanguageRulesPlugin.
    public var ruleChecks: RuleChecks? { service(RuleChecks.self) }
}

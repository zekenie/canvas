import Boards
import Canvas
import CoreGraphics
import DetailPanel
import Draw
import Foundation
import Selection
import Topology
import Validation

// Shapes already inside that break a constraint (retyped, a constraint added to a full frame, a shape made there that
// couldn't be made to fit, an undo that put a misfit back) are errors: Validation's rule on every shape with a box,
// from the index. Nothing moves by itself; each issue offers Move Out and Show Constraint, and the issue walk walks a
// constraint's breakers as a scope of its own.

extension PlacedConstraint {
    /// The issue source of the constraint's issues: its place, where it comes from and its value, as a key.
    public var source: IssueSource { IssueSource(plugin: ConstraintValidationPlugin.id, key: key) }

    /// The constraint an issue source names, if it's one of Constraints'.
    public init?(source: IssueSource) {
        guard source.plugin == ConstraintValidationPlugin.id, let data = source.key.data(using: .utf8),
              let key = try? JSONDecoder().decode(Key.self, from: data), let made = key.placed else { return nil }
        self = made
    }

    /// The key, as JSON with its keys sorted: the same constraint is always the same key.
    var key: String {
        let key = Key(place: place.shape?.description, root: place == .root ? true : nil, from: {
            if case .inherited(let id) = origin { return id.description }
            return nil
        }(), constraint: constraint)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(key)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private struct Key: Codable {
        let place: String?
        let root: Bool?
        let from: String?
        let constraint: Constraint

        var placed: PlacedConstraint? {
            let target: ConstraintTarget
            if root == true {
                target = .root
            } else if let place, let uuid = UUID(uuidString: place) {
                target = .shape(ShapeID(uuid))
            } else {
                return nil
            }
            var origin = ConstraintOrigin.own
            if let from {
                guard let uuid = UUID(uuidString: from) else { return nil }
                origin = .inherited(ShapeID(uuid))
            }
            return PlacedConstraint(place: target, origin: origin, constraint: constraint)
        }
    }
}

/// Constraints' issues, a plugin value of its own after Constraints and Validation, so a list without Validation
/// leaves them out: an error on every shape with a box that breaks a constraint whose reach it is in ("Backlog accepts
/// only tasks."), with Move Out and Show Constraint, and the issue walk's scope of each constraint's breakers.
///
/// The rule is on every kind with a box (`forShapes(adopting: .box)`): a constraint is a place's, and every shape with
/// a box can be in a place, whatever the kind, so this is what being a box means, not a feature kinds opt into, as
/// Moving's commands are on every shape a drag moves. Arrows (no box) are in no place and never judged.
public struct ConstraintValidationPlugin: ListedPlugin {
    public init() {}
    public nonisolated static let id: PluginID = "constraint-validation"
    public var id: PluginID { Self.id }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.forShapes(adopting: .box) { boxes in
            boxes.validate(ignoringMoves: true, affected: { changes, editor in
                editor.constraintIndex?.changed(by: changes) ?? []
            }, touches: { changes, shapes in
                shapes.service(ConstraintIndex.self)?.touched(by: changes, in: shapes) ?? []
            }) { shape, context in
                guard let index = context.service(ConstraintIndex.self) ?? context.committedService(ConstraintIndex.self) else { return [] }
                if let reading = context.reading, !reading.isCommitted { return index.issues(of: shape, in: reading) }
                return index.issues(of: shape.id)
            }
        }
        registrar.issueScopes { source, editor in
            PlacedConstraint(source: source).flatMap { editor.constraintIndex?.walkScope(of: $0) }
        }
    }
}

extension ConstraintIndex {
    /// A shape's issues as the file is committed: one error for each constraint it breaks, in the order `breaches`
    /// gives.
    func issues(of id: ShapeID) -> [ValidationIssue] {
        breaches(of: id).map { issue(for: $0, on: id, place: name(of: $0.place)) }
    }

    /// A shape's issues as a transaction leaves the file (a run's check before it commits): the constraints whose
    /// reach it is in there, each broken by an answer of no for a shape the transaction left as it was beyond where it
    /// is; what it wrote has no answer yet.
    func issues(of record: AnyShapeRecord, in reading: LayoutReading) -> [ValidationIssue] {
        guard hasPlaces, record.box != nil, !record.isOpaque, let editor, !reading.isChanged(record.id),
              let committed = editor.withoutObservingDocument({ editor.file.record(record.id) }), committed.isSame(asIgnoringPlace: record) else {
            return []
        }
        let places = ReadingPlaces(reading: reading, registry: editor.registry)
        guard let place = places.place(of: record) else { return [] }
        var issues: [ValidationIssue] = []
        for (depth, holder) in places.chain(from: place).enumerated() {
            for key in constraints(at: holder, in: places) where key.reaches(depth: depth) {
                guard answer(record.id, for: key.constraint) == false else { continue }
                issues.append(issue(for: key, on: record.id, place: name(of: holder, in: places)))
            }
        }
        return issues
    }

    private func issue(for key: PlacedConstraint, on id: ShapeID, place: String) -> ValidationIssue {
        var actions: [IssueAction] = []
        // Nowhere out of the root to move a shape to; every place can show its constraint.
        if key.place != .root {
            actions.append(IssueAction(ConstraintsStyle.moveOut) { [weak self] in _ = self?.moveOut(id, of: key.place) })
        }
        actions.append(IssueAction(ConstraintsStyle.showConstraint) { [weak self] in self?.show(key) })
        return .error(ConstraintsStyle.accepts(place, key.constraint.says), actions: actions, source: key.source)
    }

    /// The shapes whose issues writes not yet committed may change though they don't change them: those within reach
    /// of a list they wrote (a place's own, the root's: its top level, or the file when it reaches anywhere inside, as
    /// it did or does), and what a container they put in another place, or on another board, carries (a subboard's
    /// board goes with it unwritten; what a frame holds on its board moves with it, written).
    func touched(by changes: ChangeSet, in shapes: ShapeContext) -> Set<ShapeID> {
        guard let editor, let topology = editor.topology, let reading = shapes.reading else { return [] }
        var found: Set<ShapeID> = []
        editor.withoutObservingDocument {
            let file = editor.file
            for id in changes.edited.union(changes.elsewhere).union(changes.removed) {
                guard let now = reading.shape(inFile: id), let before = file.record(id) else { continue }
                let elsewhere = now.container != before.container || reading.board(containing: id) != file.board(containing: id)
                if now.ownConstraints != before.ownConstraints || (elsewhere && editor.registry.containerKinds.contains(now.kind)) {
                    found.formUnion(topology.descendants(of: id))
                }
            }
            // A holder written (a type's schema, which keeps its list): the members of every place that reads through it, as
            // far as its list or the place's reaches, though the places themselves are not written. One whose list is as it was
            // reaches no one. A shape that is given lists from elsewhere (a frame's type) and is written beyond where it is
            // has its members looked at too, since what it is given may be what changed (it was retyped), and a holder so
            // written (a type made a subtype) the places that read through it.
            for id in changes.edited.union(changes.elsewhere).union(changes.removed) {
                let now = reading.shape(inFile: id), before = file.record(id)
                guard let kind = (now ?? before)?.kind else { continue }
                let holder = editor.registry.contributions(to: ConstraintHolders.self, for: kind).first
                let listed = [now, before].map { record in record.flatMap { holder?.read($0, editor) } ?? [] }
                let listChanged = holder != nil && (now == nil || listed[0] != listed[1])
                let lists = listed.flatMap { $0 }
                let given = now.map { now in
                    before.map { !now.isSame(asIgnoringPlace: $0) } ?? false
                        && !editor.registry.contributions(to: InheritedConstraints.self, for: kind).isEmpty
                } ?? false
                if listChanged || (given && holder != nil) {
                    found.formUnion(membersReading(through: id, deeper: lists.contains { $0.reach == .descendants }, topology: topology))
                }
                if given { found.formUnion(topology.descendants(of: id)) }
            }
            if changes.fileValues.contains(RootConstraintsProperty.key) {
                let lists = file[RootConstraintsProperty.self].constraints + reading.fileValue(RootConstraintsProperty.self).constraints
                if lists.contains(where: { $0.reach == .descendants }) {
                    for board in file.showableBoards(boardOwningKinds: editor.registry.boardOwningKinds) { found.formUnion(file[board].shapes.map(\.id)) }
                } else {
                    for record in file.root.shapes where topology.parent(of: record.id) == nil { found.insert(record.id) }
                }
            }
        }
        return found.subtracting(changes.edited)
    }

    // MARK: Actions

    /// Moves a shape out of the place whose constraint it breaks, to the level that place is on, beside it: out of a
    /// frame into what holds the frame, off a subboard's board onto the board the subboard is on. One step, "Move Out",
    /// refused like any move where the level it lands on refuses it too (nothing changes, what refused shakes).
    /// Whether it moved.
    @discardableResult
    public func moveOut(_ id: ShapeID, of place: ConstraintTarget) -> Bool {
        guard let editor, case .shape(let holder) = place else { return false }
        let file = editor.file
        guard let target = file.board(containing: holder), let source = file.board(containing: id), let holding = file.record(holder),
              let record = file.record(id), let box = record.box else { return false }
        let containingKinds = editor.registry.containingKinds
        let carried = containingKinds.isEmpty ? [] : file[source].descendants(of: id, containingKinds: containingKinds)
        let frame = editor.frame(inFile: id) ?? box
        let within = file[target].container(of: holding, containingKinds: containingKinds)
        guard let surroundings = Surroundings(on: target, moving: frame.size, carrying: source == target ? [id] : [], held: carried, in: editor),
              let landing = surroundings.near(holder, within: within) else { return false }
        let delta = CGPoint(x: landing.rect.minX - frame.minX, y: landing.rect.minY - frame.minY)
        let shown = editor.board, revision = editor.revision
        let moved = editor.transactWhole(ConstraintsStyle.moveOut) { transaction -> Bool in
            if source != target {
                let went = source == shown ? transaction.move([id], to: target) : transaction.move([id], from: source, to: target)
                guard went else { throw Transaction.Refused() }
            }
            transaction.translate(Set([id]).union(transaction.rodeAlong), by: delta, on: target)
            guard transaction.refusedShapes.isEmpty else { throw Transaction.Refused() }
            guard case .settled = transaction.settle([id], on: target) else { throw Transaction.Refused() }
            return true
        }
        return moved == true && editor.revision != revision
    }

    /// Shows a constraint where it's held: for a place the board shown is (the root, on the root; a subboard, from inside it),
    /// the board's funnel clicked, its popover open, rather than going out to the board above where the owner is; the root's, from
    /// another board, shown first; any other place's frame or subboard selected (one step back) and its Rules tab chosen.
    public func show(_ constraint: PlacedConstraint) {
        guard let editor else { return }
        let shown: ConstraintTarget = editor.board.owner.map(ConstraintTarget.shape) ?? .root
        if constraint.place == shown {
            editor.constraintBoard?.open()
            return
        }
        if constraint.place == .root {
            // The root's list is the root board's: shown, on the next turn once the board has changed (which closes a popover).
            guard editor.goUp(to: .root) else { return }
            _ = editor.scheduler.schedule(after: .zero) { [weak editor] in editor?.constraintBoard?.open() }
            return
        }
        guard case .shape(let holder) = constraint.place, let record = editor.shape(inFile: holder) else { return }
        editor.detailPanel?.choose(.of(RulesTab.self), for: record.kind)
        // On the next turn: the line's button goes with the panel it's in.
        _ = editor.scheduler.schedule(after: .zero) { [weak editor] in editor?.goTo([holder]) }
    }

    // MARK: The walk

    /// The scope of one constraint's issues: its breakers, labeled by the place and the words ("Backlog: only tasks"),
    /// gone with the constraint. Named by its place, where it comes from and its words, so a walk follows it through a
    /// change of its reach or its query (`isChanged`): the issues it then includes are the constraint's as it is now.
    func walkScope(of constraint: PlacedConstraint) -> IssueScope? {
        guard has(constraint) else { return nil }
        let follow = ConstraintFollow(constraint)
        return IssueScope(id: follow.id, includes: { $0.source == follow.current.source }, label: { editor in
            guard let index = editor.constraintIndex, let now = follow.now(in: index) else { return nil }
            let title = ConstraintsStyle.walkLabel(index.name(of: now.place), now.constraint.says)
            return IssueScopeLabel(title, owner: now.place.shape, spoken: title)
        }, candidates: { editor in
            guard let index = editor.constraintIndex, let now = follow.now(in: index) else { return [] }
            return index.breakers(of: now)
        }, isChanged: { _, editor in
            editor.constraintIndex.map { follow.follow(in: $0) } ?? false
        })
    }

    /// The constraint of a place that comes from `origin` and says `says`, as the place has it now.
    func constraint(of place: ConstraintTarget, from origin: ConstraintOrigin, saying says: String) -> PlacedConstraint? {
        judged(of: place).first { $0.origin == origin && $0.constraint.says == says }
    }
}

/// What names a constraint's walk: its place, where it comes from and its words as it began.
struct ConstraintScopeID: Hashable {
    let place: ConstraintTarget
    let origin: ConstraintOrigin
    let says: String
}

/// A constraint as a walk follows it: by its place, where it comes from and its words, whatever its reach or query
/// becomes.
@MainActor
final class ConstraintFollow {
    let id: ConstraintScopeID
    /// The constraint as last found.
    private(set) var current: PlacedConstraint

    init(_ constraint: PlacedConstraint) {
        id = ConstraintScopeID(place: constraint.place, origin: constraint.origin, says: constraint.constraint.says)
        current = constraint
    }

    /// The constraint as its place has it now; nil once it's gone.
    func now(in index: ConstraintIndex) -> PlacedConstraint? {
        index.constraint(of: id.place, from: id.origin, saying: id.says)
    }

    /// Whether it changed since last found (and is still there): followed.
    func follow(in index: ConstraintIndex) -> Bool {
        guard let found = now(in: index), found != current else { return false }
        current = found
        return true
    }
}

import Canvas
import Queries
import Titles

/// The list of constraints a write is to: a shape's (a container's own property, or what a holder keeps its own way,
/// a type's) or the root board's (a file value).
public enum ConstraintTarget: Hashable, Sendable {
    case shape(ShapeID)
    case root

    /// The shape, for a shape's list.
    public var shape: ShapeID? {
        if case .shape(let id) = self { return id }
        return nil
    }
}

/// What a write to a list came to.
public enum ConstraintEdit: Equatable, Sendable {
    /// The list changed.
    case written
    /// Nothing changed: the change was nothing, there is no list, or (through `attempt`, in a transaction handed in) the shape
    /// is read-only, which its caller refuses.
    case unchanged
    /// The list should have changed and couldn't: its holder wouldn't take it (a type whose schema isn't JSON yet), or the
    /// shape is read-only (a lock set while words were being interpreted). The shape has shaken, and said why if it had a
    /// reason; the caller that holds words (`ConstraintBoxes`) keeps them.
    case refused
}

/// The one way any list of constraints changes: a container's own (`ConstraintsProperty`), a holder's (through the
/// holders' point: a type's), the root's (`RootConstraintsProperty`). A constraint is named by its value, never its
/// place, so a write that comes after the list changed finds the one it was for, or nothing. Each write is one step,
/// named for what it does; one that changes nothing is false and makes none; a shape that can't change is refused
/// (it shakes) before any transaction. For several lists in one step (`/constrain` on a selection), the same writes
/// take a transaction they're handed (`edit(_:in:_:)`).
@MainActor
public final class ConstraintWriter {
    private weak var editor: CanvasEditor?
    /// What a query's titles named, for the file as of a revision: a step that writes the same query to many lists
    /// (`/constrain` on a selection) reads the file's names once.
    private var read: (revision: Int, names: [String: [String: ShapeID]]) = (-1, [:])

    init(editor: CanvasEditor) { self.editor = editor }

    // MARK: Reading

    /// The list as the file holds it; nil for a shape whose list there is none to write (a kind with no constraints
    /// and no holder, or a holder's shape that holds no list now: a note that isn't a type).
    public func constraints(of target: ConstraintTarget) -> [Constraint]? {
        guard let editor else { return nil }
        switch target {
        case .root:
            return editor.file[RootConstraintsProperty.self].constraints
        case .shape(let id):
            guard let record = editor.shape(inFile: id) else { return nil }
            return Self.list(of: record, in: editor)
        }
    }

    /// A shape's list: its holder's, else its own where its kind holds one.
    static func list(of record: AnyShapeRecord, in editor: CanvasEditor) -> [Constraint]? {
        if let holder = editor.registry.contributions(to: ConstraintHolders.self, for: record.kind).first, let read = holder.read(record, editor) {
            return read
        }
        guard editor.registry.isConstrainable(record.kind) else { return nil }
        return record.ownConstraints
    }

    // MARK: Writing

    /// Adds `constraint` at the end: "Add Constraint". False when one equal to it is there already.
    @discardableResult
    public func add(_ constraint: Constraint, to target: ConstraintTarget) -> Bool {
        tryAdd(constraint, to: target) == .written
    }

    /// `add`, and what it came to: a holder that won't take the list shakes and says so, a read-only shape shakes (`refused`).
    public func tryAdd(_ constraint: Constraint, to target: ConstraintTarget) -> ConstraintEdit {
        write(target, step: ConstraintsStyle.addConstraint) { Self.adding(constraint, to: &$0) }
    }

    /// Takes `constraint` away: "Remove Constraint". False when it isn't there.
    @discardableResult
    public func remove(_ constraint: Constraint, from target: ConstraintTarget) -> Bool {
        write(target, step: ConstraintsStyle.removeConstraint) { Self.removing(constraint, from: &$0) } == .written
    }

    /// Takes every constraint away: "Remove Constraints". False when there are none.
    @discardableResult
    public func removeAll(from target: ConstraintTarget) -> Bool {
        write(target, step: ConstraintsStyle.removeConstraints) { list in
            guard !list.isEmpty else { return false }
            list = []
            return true
        } == .written
    }

    /// Puts `new` where `old` is, its words, query and reach at once (what an interpretation lands): "Change
    /// Constraint". False when `old` isn't there, or is `new`; one equal to `new` elsewhere in the list goes, as the
    /// list holds each once.
    @discardableResult
    public func replace(_ old: Constraint, with new: Constraint, in target: ConstraintTarget) -> Bool {
        tryReplace(old, with: new, in: target) == .written
    }

    /// `replace`, and what it came to (`ConstraintEdit`).
    public func tryReplace(_ old: Constraint, with new: Constraint, in target: ConstraintTarget) -> ConstraintEdit {
        write(target, step: ConstraintsStyle.changeConstraint) { Self.replacing(old, with: new, in: &$0) }
    }

    /// Gives `constraint` another reach: "Change Constraint".
    @discardableResult
    public func setReach(_ reach: ConstraintReach, of constraint: Constraint, in target: ConstraintTarget) -> Bool {
        replace(constraint, with: Constraint(says: constraint.says, query: constraint.query, reach: reach, names: constraint.names), in: target)
    }

    /// Gives `constraint` another query (nil: its words not interpreted): "Change Constraint". The query is bound to the
    /// shapes its titles name now, as any new query is; the same query keeps the names it has, unless `rebinding`: what a
    /// person wrote is bound again, as they wrote it (a title a shape has been renamed from names what it names now).
    @discardableResult
    public func setQuery(_ query: String?, of constraint: Constraint, in target: ConstraintTarget, rebinding: Bool = false) -> Bool {
        let names = rebinding ? rebound(query, of: constraint) : query == constraint.query ? constraint.names : [:]
        return write(target, step: ConstraintsStyle.changeConstraint) {
            Self.replacing(constraint, with: Constraint(says: constraint.says, query: query, reach: constraint.reach, names: names), in: &$0,
                           keepingNames: !rebinding)
        } == .written
    }

    /// What a query a person wrote names: the shapes its titles name now, except that a title the box showed for a shape the
    /// constraint already named, and the person left alone, is still that shape (it may be shared with another now).
    private func rebound(_ query: String?, of constraint: Constraint) -> [String: ShapeID] {
        guard let query, let queries = editor?.queries else { return [:] }
        var kept: [String: ShapeID] = [:]
        if !constraint.names.isEmpty, let old = constraint.query {
            let shown = queries.shownKeys(in: old, by: constraint.names)
            for (key, id) in constraint.names { if let now = shown[key] { kept[now] = id } }
        }
        return queries.bindNames(in: query, keeping: kept)
    }

    /// Changes a list inside a transaction it's handed, so several lists change in one step: `change` is given the
    /// list as the transaction has it and says whether it changed it. False when it didn't, when the target has no
    /// list to write, or when it can't change (read-only: nothing is written or heard; the caller refuses it, as it
    /// says what shakes).
    @discardableResult
    public func edit(_ target: ConstraintTarget, in transaction: inout Transaction, _ change: (inout [Constraint]) -> Bool) -> Bool {
        attempt(target, in: &transaction, change) == .written
    }

    /// `edit`, and what it came to: `refused` for a holder that wouldn't take a list that should have changed (its caller
    /// shakes it and says so), `unchanged` for the rest of what `edit` calls false.
    public func attempt(_ target: ConstraintTarget, in transaction: inout Transaction, _ change: (inout [Constraint]) -> Bool) -> ConstraintEdit {
        guard let editor else { return .unchanged }
        switch target {
        case .root:
            let before = transaction.fileValue(RootConstraintsProperty.self).constraints
            var list = before
            guard change(&list) else { return .unchanged }
            let written = ConstraintList(binding(list, against: before))
            guard written != transaction.fileValue(RootConstraintsProperty.self) else { return .unchanged }
            transaction.setFileValue(RootConstraintsProperty.self, to: written)
            return .written
        case .shape(let id):
            guard !editor.isReadOnly(inFile: id), let board = transaction.board(containing: id),
                  let record = transaction.contents(of: board)[id], let before = Self.list(of: record, in: editor) else { return .unchanged }
            var list = before
            guard change(&list) else { return .unchanged }
            let written = ConstraintList(binding(list, against: before)).constraints
            guard written != before else { return .unchanged }
            if let holder = editor.registry.contributions(to: ConstraintHolders.self, for: record.kind).first, holder.read(record, editor) != nil {
                return holder.write(written, id, &transaction) ? .written : .refused
            }
            transaction.update(id, on: board) { $0[ConstraintsProperty.self] = written.isEmpty ? nil : ConstraintList(written) }
            return .written
        }
    }

    /// A holder that won't take a list: it shakes, and what can't be done is said (heard by VoiceOver), once.
    func refuse(_ id: ShapeID, adding: Bool = true) {
        guard let editor else { return }
        editor.refuseChanges(to: [id])
        editor.announce(refusal(of: id, adding: adding))
    }

    /// Whether a refusal of a list is still true of the shape: while it is read-only; for a holder with a `reason`, also while
    /// the reason has words (false once it can take a list); a holder with no `reason` can't say, and still refuses; any other
    /// shape (a frame) doesn't once it can change.
    func stillRefuses(_ id: ShapeID) -> Bool {
        guard let editor, let record = editor.shape(inFile: id) else { return true }
        if editor.isReadOnly(inFile: id) { return true }
        guard let holder = editor.registry.contributions(to: ConstraintHolders.self, for: record.kind).first else { return false }
        guard let reason = holder.reason else { return true }
        return reason(record, editor) != nil
    }

    /// What is said of a holder that won't take a list: the holder's own reason (a type's schema isn't JSON yet), else that a
    /// constraint can't be added to it (or changed, for a change that isn't an add).
    public func refusal(of id: ShapeID, adding: Bool = true) -> String {
        guard let editor else { return "" }
        if let record = editor.shape(inFile: id), let reason = editor.registry.contributions(to: ConstraintHolders.self, for: record.kind).first?.reason?(record, editor) {
            return reason
        }
        let name = Self.name(of: id, in: editor)
        return adding ? ConstraintsStyle.cantAdd(to: name) : ConstraintsStyle.cantChange(name)
    }

    /// What a shape is called where a refusal says it: its title, else its kind.
    static func name(of id: ShapeID, in editor: CanvasEditor) -> String {
        guard let record = editor.shape(inFile: id) else { return ConstraintsStyle.thisBoard.lowercased() }
        return editor.registry.title(of: record) ?? editor.registry.label(of: record.kind).name.lowercased()
    }

    /// `list`, the constraints with a query the list didn't have (a value `before` doesn't hold, its query not one it has) and
    /// that come with no names bound to the shapes
    /// their queries' titles name as the file is now (`QueryState.bindNames(in:)`). One that comes with names keeps them,
    /// and one left as it was keeps its own, so a write that touches another never binds it again. (A change that keeps a
    /// query, `setReach` or `replace` with the query as it was, carries the names across itself: `replacing`.)
    private func binding(_ list: [Constraint], against before: [Constraint]) -> [Constraint] {
        guard let queries = editor?.queries else { return list }
        return list.map { constraint in
            guard constraint.names.isEmpty, let query = constraint.query, !before.contains(constraint) else { return constraint }
            var bound = constraint
            // A query the list already holds is bound as its sibling is (its names copied), so a rename leaves the two alike;
            // a sibling with no names is as unbound as this one.
            if let sibling = before.first(where: { $0.query == query }) {
                guard !sibling.names.isEmpty else { return constraint }
                bound.names = sibling.names
            } else {
                bound.names = names(for: query, by: queries)
            }
            return bound
        }
    }

    /// What `queries.bindNames(in:)` says of a query, once for the file as it is (a revision).
    private func names(for query: String, by queries: QueryState) -> [String: ShapeID] {
        let revision = editor?.revision ?? -1
        if read.revision != revision { read = (revision, [:]) }
        if let known = read.names[query] { return known }
        let found = queries.bindNames(in: query)
        read.names[query] = found
        return found
    }

    /// `edit` in a step of its own, the shape refused first if it can't change (it shakes, and the write is `refused`: nothing is
    /// said beyond the shake's own), and a holder that won't take the list shaking and saying so (nothing is written then, and no
    /// step made).
    private func write(_ target: ConstraintTarget, step: String, _ change: (inout [Constraint]) -> Bool) -> ConstraintEdit {
        guard let editor, var list = constraints(of: target) else { return .unchanged }
        guard change(&list), ConstraintList(list).constraints != constraints(of: target) else { return .unchanged }
        if let id = target.shape, editor.isReadOnly(inFile: id) {
            editor.refuseChanges(to: [id])
            return .refused
        }
        var outcome = ConstraintEdit.unchanged
        editor.transact(step) { transaction in
            outcome = attempt(target, in: &transaction) { $0 = list; return true }
            return outcome == .written
        }
        if outcome == .refused, let id = target.shape { refuse(id, adding: step == ConstraintsStyle.addConstraint) }
        return outcome
    }

    // MARK: The changes, by value

    /// Where a constraint is: the one equal to it, else the one that says the same but for the shapes its titles name
    /// (`names`: a caller that built the value by its words, its query and its reach finds the constraint the writer bound).
    private static func index(of constraint: Constraint, in list: [Constraint]) -> Int? {
        list.firstIndex(of: constraint) ?? list.firstIndex { $0.says == constraint.says && $0.query == constraint.query && $0.reach == constraint.reach }
    }

    /// `constraint` added at the end, unless one equal to it is there.
    public static func adding(_ constraint: Constraint, to list: inout [Constraint]) -> Bool {
        guard let made = constraint.normalized, !list.contains(where: { $0.says == made.says }) else { return false }
        list.append(made)
        return true
    }

    /// `constraint` taken away, if it's there.
    public static func removing(_ constraint: Constraint, from list: inout [Constraint]) -> Bool {
        guard let made = constraint.normalized, let index = index(of: made, in: list) else { return false }
        list.remove(at: index)
        return true
    }

    /// `old` replaced by `new` where it is, if it's there and isn't `new`. A `new` with no names and the query `old` has
    /// takes `old`'s (`keepingNames`: the query is the same, so what its titles named is), else it is bound by the writer
    /// that writes it.
    public static func replacing(_ old: Constraint, with new: Constraint, in list: inout [Constraint], keepingNames: Bool = true) -> Bool {
        guard let old = old.normalized, var new = new.normalized, let index = index(of: old, in: list) else { return false }
        if keepingNames, new.names.isEmpty, new.query == list[index].query { new.names = list[index].names }
        guard list[index] != new else { return false }
        list[index] = new
        list = ConstraintList(list).constraints
        return true
    }
}

extension ConstraintWriter: EditorService {}

extension CanvasEditor {
    /// The one writer of constraints: nil without `ConstraintsPlugin`.
    public var constraintWriter: ConstraintWriter? { service(ConstraintWriter.self) }
}

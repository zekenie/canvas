import Canvas

// Answers worked out before they're provided. A stand-in for what's provided may stand for
// thousands of shapes, and an answer comes again after every commit (a query asked again): working
// out what it stands for reads each of those shapes, so a provider works it out on another thread
// (`TopologyIndex.preparer()`, `ForwardingPreparer.prepare`) and hands the result with the answers to
// `provide(_:prepared:)`, which takes in only what came and went, unless a change since read again a
// shape the answer names (then that answer is worked out on the main actor, as with no preparing).

/// The index as it was when taken (`TopologyIndex.preparer()`), for working out answers on any
/// thread as `provide` would take them. Hold it for one preparing, never past it: kept, it makes every
/// later commit's first change to a table copy it.
public struct ForwardingPreparer: Sendable {
    let generation: Int
    let tables: EdgeTables
    let containment: Containment
    let standing: [ShapeID: Declared]
    let provided: [ShapeID: ProvidedForwarding]
    let admissions: [ShapeKind: ForwardAdmission]

    /// What `provide` would make of `answers` on the index as it was: which it drops (another key, an
    /// older revision, what's held already), which only say again what the one held names, and, for
    /// the rest, what each stand-in will stand for and what comes and goes. Pure, and reads each shape
    /// an answer names once (each board's showing asked once).
    public func prepare(_ answers: [ShapeID: ProvidedForwarding]) -> PreparedForwarding {
        var showable = ShowableBoards()
        func shape(_ id: ShapeID) -> AnyShapeRecord? {
            let file = containment.file
            guard let board = file.board(containing: id) else { return nil }
            return showable.canShow(board, in: file, boardOwningKinds: containment.boardOwningKinds) ? file[board][id] : nil
        }
        var prepared: [ShapeID: PreparedAnswer] = [:]
        for (id, answer) in answers {
            guard let declared = standing[id], case .provided(let key)? = declared.forwarding, key == answer.key,
                  let admits = admissions[declared.kind] else {
                prepared[id] = PreparedAnswer(answer: answer, outcome: .dropped)
                continue
            }
            // Cancelled (the batch it's for was let go of): what's left is dropped with it.
            if Task.isCancelled { break }
            let held = provided[id]
            switch answer.taken(over: held) {
            case .dropped:
                prepared[id] = PreparedAnswer(answer: answer, outcome: .dropped)
                continue
            case .newer:
                prepared[id] = PreparedAnswer(answer: answer, outcome: .newer)
                continue
            case .anew:
                break
            }
            let taken = Effective.taking(answer.shapes, for: id, isStandIn: { admissions[$0] != nil }, admits: admits, shape: shape)
            let before = Set(held?.shapes ?? [])
            let change = ForwardsChange.between(tables.forwards(of: id), taken.targets, kinds: taken.kinds)
            prepared[id] = PreparedAnswer(answer: answer, named: taken.named,
                                          outcome: .stands(taken.targets, change, came: Array(taken.named.subtracting(before)),
                                                           went: Array(before.subtracting(taken.named))))
        }
        return PreparedForwarding(generation: generation, answers: prepared)
    }
}

/// The one rule of what a stand-in stands for of what it names, which the index (`effective`) and a
/// preparer both go by: the shapes named, in order, each once, that are there (`shape`: on a board the
/// editor can show), not kept aside, not of a stand-in kind (one hop), not the stand-in itself, and
/// that its kind admits; with their kinds, and every shape named, each once.
enum Effective {
    static func taking(_ named: [ShapeID], for standIn: ShapeID, isStandIn: (ShapeKind) -> Bool, admits: ForwardAdmission,
                       shape: (ShapeID) -> AnyShapeRecord?) -> (targets: [ShapeID], kinds: [ShapeKind], named: Set<ShapeID>) {
        var targets: [ShapeID] = [], kinds: [ShapeKind] = [], met: Set<ShapeID> = []
        for target in named where met.insert(target).inserted && target != standIn {
            guard let record = shape(target), !record.isOpaque, !isStandIn(record.kind), admits(record) else { continue }
            targets.append(target)
            kinds.append(record.kind)
        }
        return (targets, kinds, met)
    }
}

/// What `provide` makes of an answer against the one held for its stand-in (whose key it shares): the
/// one rule, for the index and a preparer.
enum AnswerTaking {
    /// Older than the one held, or the same: nothing changes.
    case dropped
    /// Newer, naming what the one held names: only the revision moves.
    case newer
    /// What it stands for is worked out from it.
    case anew
}

extension ProvidedForwarding {
    func taken(over held: ProvidedForwarding?) -> AnswerTaking {
        guard let held else { return .anew }
        guard revision >= held.revision else { return .dropped }
        // The shapes compared once: an answer of thousands is no cheaper to compare twice.
        guard shapes == held.shapes else { return .anew }
        return revision == held.revision && key == held.key ? .dropped : .newer
    }
}

/// Answers worked out by a preparer (`ForwardingPreparer.prepare`), for `provide(_:prepared:)`.
public struct PreparedForwarding: Sendable {
    let generation: Int
    let answers: [ShapeID: PreparedAnswer]
}

/// One answer as a preparer worked it out.
struct PreparedAnswer: Sendable {
    enum Outcome: Sendable {
        /// `provide` drops it.
        case dropped
        /// It names what the answer held names: only its revision is new.
        case newer
        /// What the stand-in will stand for, what that changes, and what the answer names that the
        /// one held didn't and no longer names.
        case stands([ShapeID], ForwardsChange, came: [ShapeID], went: [ShapeID])
    }

    let answer: ProvidedForwarding
    /// The shapes the answer names, each once: those whose change since makes it worked out again.
    var named: Set<ShapeID> = []
    let outcome: Outcome

    /// Whether what was worked out still holds after a change to `changed`: none of the shapes it
    /// names is among them.
    func holds(_ changed: Set<ShapeID>) -> Bool {
        guard !changed.isEmpty else { return true }
        return changed.count < named.count ? !changed.contains(where: named.contains) : named.isDisjoint(with: changed)
    }
}

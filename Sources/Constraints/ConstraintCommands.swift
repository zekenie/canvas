import Canvas
import Foundation
import Queries
import QueryTranslation
import Selection
import SlashCommands

// `/constrain` and `/unconstrain`, typed in the command bar: `/constrain <words>` adds a constraint, never replacing one, to
// every container selected (or holder, a type), or, with nothing selected, to the board shown (the subboard that owns it, or the
// root's list); `/unconstrain` takes one of the target's own constraints away, or all of them, from a list of them. Neither is
// ever typed on a line of a shape's text.

/// The two commands, as the bar offers them.
@MainActor
enum ConstraintCommands {
    static let constrain = ConstraintsStyle.constrainCommand
    static let unconstrain = ConstraintsStyle.unconstrainCommand

    /// The lists a bar target is about: each shape selected, every one of which keeps a list (a container or a holder); with
    /// nothing selected the board shown's (a subboard's owner, else the root). Nil where it's about no list: a line of text, a
    /// selection with a shape that keeps none.
    static func lists(of target: SlashTarget, in editor: CanvasEditor) -> [ConstraintTarget]? {
        guard let writer = editor.constraintWriter else { return nil }
        switch target {
        case .text:
            return nil
        case .selection(let ids):
            guard !ids.isEmpty, ids.allSatisfy({ writer.constraints(of: .shape($0)) != nil }) else { return nil }
            return ids.map(ConstraintTarget.shape)
        case .everything:
            guard let owner = editor.board.owner else { return .some([.root]) }
            return writer.constraints(of: .shape(owner)) == nil ? nil : [.shape(owner)]
        }
    }

    /// What the bar calls its target with nothing selected: the board whose list it is about, by its name as a refusal names it
    /// (the root by the file's name, a subboard by its title).
    static func boardName(in editor: CanvasEditor) -> String {
        guard let list = lists(of: .everything([]), in: editor)?.first, let index = editor.constraintIndex else { return ConstraintsStyle.thisBoard }
        return index.name(of: list)
    }

    /// Whether a list can't change just now: a shape that is read-only, or the root of a board that is.
    static func isFrozen(_ list: ConstraintTarget, in editor: CanvasEditor) -> Bool { list.isFrozen(in: editor) }

    // MARK: /constrain

    /// Offered where some list it is about can change.
    static func offersConstrain(_ target: SlashTarget, in editor: CanvasEditor) -> Bool {
        guard let lists = lists(of: target, in: editor) else { return false }
        return lists.contains { !isFrozen($0, in: editor) }
    }

    /// The words as typed: a pill as the name it shows in quotes, on one line.
    static func words(_ arguments: SlashArguments) -> String {
        Constraint.folded(arguments.runs.map { run -> String in
            switch run {
            case .text(let text): text
            case .shape(_, let label): "\"" + label.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            }
        }.joined())
    }

    /// What the bar says when every list the words would go to (those that can change) has them already, folded as a list
    /// compares them: "Backlog already accepts only tasks.", the first list's place for several. Nil where some list lacks them
    /// (it takes them as now), and where no list can change.
    static func alreadyHeld(_ says: String, in lists: [ConstraintTarget], in editor: CanvasEditor) -> String? {
        guard let writer = editor.constraintWriter, let index = editor.constraintIndex else { return nil }
        let changeable = lists.filter { !isFrozen($0, in: editor) }
        guard let first = changeable.first, changeable.allSatisfy({ list in (writer.constraints(of: list) ?? []).contains { $0.says == says } }) else { return nil }
        return ConstraintsStyle.alreadyAccepts(index.name(of: first), says)
    }

    /// The task the bar waits for: words some list lacks, as a query (words that already check as a stored query skip the model;
    /// else they are translated once, in the accepts context of the target's name, or of "each of these" for several), then one
    /// constraint added to every list in one step; words every list has already fail at once, with no model asked and nothing
    /// written. A failure is said in the words every host says, and writes nothing.
    /// Cancelled (the bar closed, the line changed), it says nothing more. It holds what it needs and the editor weakly.
    static func answer(_ target: SlashTarget, _ arguments: SlashArguments, in editor: CanvasEditor) -> Task<SlashAnswer, Never> {
        let says = words(arguments)
        let lists = lists(of: target, in: editor) ?? []
        let translator = editor.queryTranslator, queries = editor.queries
        let holder = lists.count == 1 ? (editor.constraintIndex?.holderName(of: lists[0]) ?? ConstraintsStyle.thisBoard) : ConstraintsStyle.eachOfThese
        return Task { @MainActor [weak editor] in
            guard !says.isEmpty, !lists.isEmpty, let queries else { return .failed(InterpretationStatus.unavailable.words) }
            if let editor, let held = alreadyHeld(says, in: lists, in: editor) { return .failed(held) }
            let query: String
            if let plan = try? queries.checkStored(says) {
                query = plan.canonical
            } else {
                guard let translator else { return .failed(InterpretationStatus.unavailable.words) }
                do throws(QueryTranslationError) {
                    query = try await translator.translate(says, about: .accepting(holder: holder)).query
                } catch {
                    return InterpretationStatus(error).map { .failed($0.words) } ?? .done
                }
            }
            // Stopped, or the file closed, while the model answered: nothing to write.
            guard !Task.isCancelled, let editor else { return .done }
            // A holder that won't take a list (a type whose schema isn't JSON yet): the rest are written, and the bar says why (its
            // own reason, if it has one).
            let refused = add(Constraint(says: says, query: query), to: lists, in: editor)
            switch refused.count {
            case 0: return .done
            case 1: return .failed(editor.constraintWriter?.refusal(of: refused[0]) ?? ConstraintsStyle.cantAdd(to: ConstraintWriter.name(of: refused[0], in: editor)))
            default: return .failed(ConstraintsStyle.cantAdd(toEach: refused.count))
            }
        }
    }

    /// One constraint added to each list in one step ("Add Constraint"); a list that can't change shakes, as any refused change
    /// does, and is passed over. A holder that won't take the list (`ConstraintEdit.refused`) shakes too and is returned.
    @discardableResult
    static func add(_ constraint: Constraint, to lists: [ConstraintTarget], in editor: CanvasEditor) -> [ShapeID] {
        guard let writer = editor.constraintWriter else { return [] }
        let frozen = Set(lists.compactMap { isFrozen($0, in: editor) ? $0.shape : nil })
        var refused: [ShapeID] = []
        editor.transact(ConstraintsStyle.addConstraint) { transaction in
            for list in lists {
                if writer.attempt(list, in: &transaction, { ConstraintWriter.adding(constraint, to: &$0) }) == .refused, let id = list.shape { refused.append(id) }
            }
        }
        if !frozen.isEmpty || !refused.isEmpty { editor.refuseChanges(to: frozen.union(refused)) }
        return refused
    }

    // MARK: /unconstrain

    /// Offered where some list it is about has constraints of its own, and can change.
    static func offersUnconstrain(_ target: SlashTarget, in editor: CanvasEditor) -> Bool {
        guard let lists = lists(of: target, in: editor), let writer = editor.constraintWriter else { return false }
        return lists.contains { !isFrozen($0, in: editor) && !(writer.constraints(of: $0) ?? []).isEmpty }
    }

    /// The row for a constraint, by its value.
    private static func rowID(of constraint: Constraint) -> String {
        ["constraint", constraint.says, constraint.query ?? "", constraint.reach.rawValue].joined(separator: "\u{1F}")
    }
    private static let allID = "all"

    /// The target's own constraints, each once, in the order they are found: a row each, its reach beside it (and in how many of
    /// the lists, for several), then "all" with how many it takes away, when there are two or more to tell apart (with one, its row
    /// does the same).
    static func choices(_ target: SlashTarget, in editor: CanvasEditor) -> [SlashChoice] {
        guard let lists = lists(of: target, in: editor), let writer = editor.constraintWriter else { return [] }
        let changeable = lists.filter { !isFrozen($0, in: editor) }
        // By its words, query and reach: two lists' constraints bound at different times are one, whatever shapes they name.
        var order: [Constraint] = [], found: [String: Int] = [:], total = 0
        for list in changeable {
            for constraint in writer.constraints(of: list) ?? [] {
                if found[rowID(of: constraint)] == nil { order.append(constraint) }
                found[rowID(of: constraint), default: 0] += 1
                total += 1
            }
        }
        guard !order.isEmpty else { return [] }
        var rows = order.map { constraint in
            SlashChoice(rowID(of: constraint), title: ConstraintsStyle.cut(constraint.says), symbol: ConstraintsStyle.funnelSymbol,
                        detail: changeable.count > 1 ? ConstraintsStyle.inLists(found[rowID(of: constraint)] ?? 0, of: changeable.count) : constraint.reach.schemaTitle,
                        step: ConstraintsStyle.removeConstraint)
        }
        if order.count > 1 {
            rows.append(SlashChoice(allID, title: ConstraintsStyle.all, symbol: ConstraintsStyle.funnelSymbol, detail: ConstraintsStyle.constraintCount(total),
                                    group: 1, step: ConstraintsStyle.removeConstraints))
        }
        return rows
    }

    /// A pick: the constraint taken away from every list that has it, or every constraint from every list, in one step.
    static func remove(_ choice: SlashChoice, _ target: SlashTarget, in editor: CanvasEditor) {
        guard let lists = lists(of: target, in: editor), let writer = editor.constraintWriter else { return }
        // A frozen list shakes only if the pick would have changed it: it has the constraint (any, for "all").
        let frozen = Set(lists.compactMap { list -> ShapeID? in
            guard isFrozen(list, in: editor) else { return nil }
            let held = writer.constraints(of: list) ?? []
            return (choice.id == allID ? !held.isEmpty : held.contains { rowID(of: $0) == choice.id }) ? list.shape : nil
        })
        let name = choice.id == allID ? ConstraintsStyle.removeConstraints : ConstraintsStyle.removeConstraint
        editor.transact(name) { transaction in
            for list in lists {
                if choice.id == allID {
                    writer.edit(list, in: &transaction) { constraints in
                        guard !constraints.isEmpty else { return false }
                        constraints = []
                        return true
                    }
                } else {
                    writer.edit(list, in: &transaction) { constraints in
                        guard let match = constraints.first(where: { rowID(of: $0) == choice.id }) else { return false }
                        return ConstraintWriter.removing(match, from: &constraints)
                    }
                }
            }
        }
        if !frozen.isEmpty { editor.refuseChanges(to: frozen) }
    }
}

/// `/constrain` and `/unconstrain`, in the command bar.
@MainActor
func registerConstraintCommands(into registrar: inout PluginRegistrar) {
    registrar.selectionSlashCommand(SelectionSlashCommand(ConstraintCommands.constrain, argument: ConstraintsStyle.constrainArgument,
                                                          waiting: InterpretationWords.interpreting,
                                                          when: { target, editor in ConstraintCommands.offersConstrain(target, in: editor) },
                                                          answer: { target, arguments, editor in ConstraintCommands.answer(target, arguments, in: editor) })
        .naming(everything: { editor in ConstraintCommands.boardName(in: editor) }))
    registrar.selectionSlashCommand(SelectionSlashCommand.choosing(ConstraintCommands.unconstrain, argument: ConstraintsStyle.unconstrainArgument,
                                                                   when: { target, editor in ConstraintCommands.offersUnconstrain(target, in: editor) },
                                                                   choices: { target, editor in ConstraintCommands.choices(target, in: editor) },
                                                                   perform: { target, choice, editor in ConstraintCommands.remove(choice, target, in: editor) })
        .naming(everything: { editor in ConstraintCommands.boardName(in: editor) }))
}

import Canvas

/// A command a target offers just now, as the list shows it and `SlashCommandState` runs it. It's
/// found for a target (`SlashCommandState.commands(for:)`): one shape's text, the shape the line is on,
/// or the command bar's shapes (those selected, or every shape on the board with none), of which it acts
/// on those that offer it (`shapes`, its reach). A command that takes a shape asks its rule about the
/// shapes it's given with those shapes and the editor; one about the bar's target as a whole answers later
/// (`answersLater`), on every shape of it.
@MainActor
public struct OfferedSlashCommand {
    /// As typed after the `/`: `set-title`.
    public let name: String
    /// The hint for what it takes ("title", "@shape"); nil for a command that takes none.
    public let argument: String?
    /// The most kinds of shape it takes, for a command that takes one and names them (`SlashCommand`'s
    /// `kinds:`), as the registry says: no shape of another kind is admitted, whatever the rule says.
    /// Nil for a command that takes no shape, or names no kinds (any kind).
    public let admittedKinds: Set<ShapeKind>?
    /// The shapes of the target it acts on, in target order: for a text's line, the shape.
    public let shapes: [ShapeID]
    /// How many shapes the target has to act on: a list says "3 of 5" where `shapes` is fewer.
    public let targetCount: Int
    /// How it acts on several shapes (`SlashReach`).
    public let reach: SlashReach
    /// What it runs, each on its own shapes: one command, but where two kinds' own commands share the
    /// name in one target (a lamp's `turn-on` and a card's), one row runs each kind's on its shapes.
    let parts: [Part]
    /// The command, for one that is one: the first of its parts.
    var command: ErasedSlashCommand { parts[0].command }
    /// The command's rule for which shape it takes, alone: bound to the shapes it was found for and to
    /// the editor, held weakly, since the state holds its editor unowned and a command outlives the
    /// call that found it (a list and a text view keep it), and asked once a shape while the file
    /// stands (`RuleAnswers`). Nil for a command that takes no shape.
    fileprivate let rule: (@MainActor (ShapeID) -> Bool)?
    /// The same with the kinds: a shape of a kind it names, and the rule says yes.
    fileprivate let admitsShape: (@MainActor (ShapeID) -> Bool)?
    /// A choice command's rows and its row for nothing matching, bound as `rule` is; nil for the
    /// other forms.
    fileprivate let choiceRows: (@MainActor () -> [SlashChoice])?
    fileprivate let choiceOtherwise: (@MainActor (String) -> SlashChoice?)?
    /// For a command about the target as a whole (`SelectionSlashCommand`): the task it starts with what
    /// was typed, bound to the target and the editor (held weakly, as `rule` is; nil once it's gone). Nil
    /// for a shape's command.
    fileprivate let answering: (@MainActor (SlashArguments) -> Task<SlashAnswer, Never>?)?
    /// What VoiceOver hears while the bar waits for a command that answers later ("Asking"), if it says.
    public let waiting: String?

    /// One command, on the shapes of the target that offer it.
    struct Part {
        let command: ErasedSlashCommand
        let shapes: [ShapeID]
    }

    /// Found for a target: `parts` (one, unless two kinds' own commands share the name; none of
    /// several takes a shape or a choice) on their shapes, which are `shapes` in target order, and
    /// `targetCount` the shapes the target has.
    init(_ parts: [Part], shapes: [ShapeID], targetCount: Int, target: SlashTarget, editor: CanvasEditor) {
        precondition(!parts.isEmpty, "a command is offered on some shapes")
        self.parts = parts
        self.targetCount = targetCount
        let command = parts[0].command
        name = command.name
        argument = command.argument
        reach = command.reach
        self.shapes = shapes
        declaredTitle = command.command.flatMap { editor.registry.title(of: $0) }
        waiting = command.waiting
        if let answer = command.answer {
            answering = { [weak editor] arguments in editor.map { answer(target, arguments, $0) } }
        } else {
            answering = nil
        }
        if parts.count == 1, let choices = command.choices {
            choiceRows = { [weak editor] in editor.map { choices(shapes, $0) } ?? [] }
            let otherwise = command.otherwise
            choiceOtherwise = { [weak editor] typed in editor.flatMap { otherwise?(typed, shapes, $0) } }
        } else {
            choiceRows = nil
            choiceOtherwise = nil
        }
        let kinds = parts.count == 1 ? command.kinds(in: editor.registry) : nil
        admittedKinds = kinds
        guard parts.count == 1, let rule = command.shapes else {
            self.rule = nil
            admitsShape = nil
            return
        }
        let answers = RuleAnswers()
        let admits: @MainActor (ShapeID) -> Bool = { [weak editor] target in
            guard let editor else { return false }
            return answers.answer(for: target, in: editor) { rule(target, shapes, editor) }
        }
        self.rule = admits
        if let kinds {
            admitsShape = { [weak editor] target in
                guard let editor, let kind = editor.shape(inFile: target)?.kind, kinds.contains(kind) else { return false }
                return admits(target)
            }
        } else {
            admitsShape = admits
        }
    }

    /// Whether the target has shapes it doesn't act on: a list says how many it does ("3 of 5").
    public var isPartial: Bool { shapes.count < targetCount }

    /// The name in words, in title case as a macOS menu has it: every word capitalized but the
    /// articles, coordinating conjunctions and short prepositions (`minorWords`), which stay lowercase
    /// unless first or last: "Set Title", "Move to Back", "Turn into Subboard". The undo step the
    /// command makes is named for it, so it reads as the menu item that does the same does, unless the
    /// command names its step otherwise (`stepName`).
    public var title: String {
        let words = name.split(separator: "-")
        return words.enumerated().map { index, word in
            let isMinor = index > 0 && index < words.count - 1 && Self.minorWords.contains(String(word))
            return isMinor ? String(word) : word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    /// The words a title keeps lowercase in the middle: articles, coordinating conjunctions and
    /// prepositions of four letters or fewer.
    private static let minorWords: Set<String> = [
        "a", "an", "and", "as", "at", "but", "by", "for", "from", "in", "into", "nor", "of", "on", "onto", "or", "the", "to", "with"
    ]

    /// What the undo step it makes is called: the title, unless the command says otherwise (`SlashCommand`'s `step:`), or it
    /// was typed for a command a plugin declared, which names it (`registry.title(of:)`).
    public var stepName: String { declaredTitle ?? command.step ?? title }

    /// What the command a plugin declared is called, for one typed for it.
    private let declaredTitle: String?

    /// Whether it takes one shape (`SlashCommand`'s `shapes:` form): what's typed after its name must
    /// be exactly one, which `admits(_:)` says yes to.
    public var takesShape: Bool { admitsShape != nil }

    /// Whether the shape it takes may be `shape`, for the shapes it was found for: of a kind it names,
    /// if it names any (`admittedKinds`: its kind is read from its record anywhere in the file, so a
    /// shape that isn't there is of none), and its rule says yes. False for a command that takes no
    /// shape.
    public func admits(_ shape: ShapeID) -> Bool { admitsShape?(shape) ?? false }

    /// Whether it takes one choice from a list (`SlashCommand`'s `choices:` form): it never runs
    /// with `SlashArguments`, only with a pick (`SlashCommandState.run(_:choosing:)`).
    public var takesChoice: Bool { choiceRows != nil }

    /// The rows it lists now, in its order, for the shapes it acts on; none for a command that takes no
    /// choice. Asked each time: a list asks once when it opens.
    public func choices() -> [SlashChoice] { choiceRows?() ?? [] }

    /// The one row it offers for what was typed (trimmed), if it offers one: the list puts it last,
    /// unless a row is titled so.
    public func choice(otherwise typed: String) -> SlashChoice? { choiceOtherwise?(typed) }

    /// Whether it answers later (`SelectionSlashCommand`): it is never run as the others are, but started,
    /// and the command bar waits for its answer (`SlashCommandState.answer(_:with:)`).
    public var answersLater: Bool { answering != nil }

    /// What a text view that lists shapes asks, for the line it's on: the kinds and the rule of the
    /// command it's a line of, if it takes a shape.
    var shapeRule: SlashShapeRule? {
        guard let rule, let admitsShape else { return nil }
        return SlashShapeRule(kinds: admittedKinds, rule: rule, admits: admitsShape)
    }

    /// Whether it can run with what was typed after its name (`SlashCommand`'s `accepts`, each part's):
    /// for a command that takes a shape, that's exactly one shape, which it admits, and nothing else.
    public func accepts(_ arguments: SlashArguments) -> Bool {
        guard parts.allSatisfy({ $0.command.accepts(arguments) }) else { return false }
        guard let admitsShape else { return true }
        guard case .shape(let target, _)? = arguments.runs.first else { return false }
        return admitsShape(target)
    }
}

/// What a command's rule said of each shape it was asked of, for the shapes it was found for, kept while
/// the file, its layout and the board shown stand: a list asks the rule of the same shapes at every
/// keystroke (Mentions' `@` picker ranks them again), and a rule may cost what the shapes it acts on are
/// (`/move-to`'s asks whether a block of all of them can be dropped there).
@MainActor
private final class RuleAnswers {
    private struct Stamp: Equatable {
        let revision: Int
        let layoutRevision: Int
        let board: BoardID
    }
    private var stamp: Stamp?
    private var answers: [ShapeID: Bool] = [:]

    func answer(for shape: ShapeID, in editor: CanvasEditor, _ ask: () -> Bool) -> Bool {
        let now = Stamp(revision: editor.revision, layoutRevision: editor.layoutRevision, board: editor.board)
        if now != stamp {
            answers = [:]
            stamp = now
        }
        if let known = answers[shape] { return known }
        let answer = ask()
        answers[shape] = answer
        return answer
    }
}

/// Which shapes the command on a line takes, as a host that lists shapes asks it
/// (`SlashCommandTyping.admittedShapes(at:)`; Mentions' `@` picker): the kinds it takes at most, and
/// its rule, for the shapes the command acts on. A list that ranks only the shapes of `kinds` asks
/// `rule` of each; anything else asks `admits(_:)`.
@MainActor
public struct SlashShapeRule {
    /// The most kinds of shape the command takes, if it names any: a shape of another kind is never
    /// admitted, whatever the rule says. A list that ranks only shapes of these kinds costs what they
    /// are, not what the board holds. Nil: any kind.
    public let kinds: Set<ShapeKind>?
    /// The command's rule alone, for a shape already known to be of `kinds`: what a list that ranks
    /// only those asks of each shape. It doesn't ask the shape's kind.
    public let rule: @MainActor (ShapeID) -> Bool
    private let admitsShape: @MainActor (ShapeID) -> Bool

    fileprivate init(kinds: Set<ShapeKind>?, rule: @escaping @MainActor (ShapeID) -> Bool, admits: @escaping @MainActor (ShapeID) -> Bool) {
        self.kinds = kinds
        self.rule = rule
        admitsShape = admits
    }

    /// Whether the command takes a shape: it's of one of `kinds`, if there are any (its kind is read
    /// from its record anywhere in the file, so a shape that isn't there is of none), and the rule
    /// says yes.
    public func admits(_ shape: ShapeID) -> Bool { admitsShape(shape) }
}

/// What slash commands know of an editor: which commands a target offers, and running one. Per editor
/// (so per window). Each kind's commands are gathered once (the registry is frozen), and what a shape
/// offers is asked of its record each time, so a command offered `when` a property holds follows it
/// with no upkeep; what the shapes selected offer is kept while the file and its layout stand, since the
/// bar asks at every keystroke (`commands(for:)`).
@MainActor
public final class SlashCommandState {
    private unowned let editor: CanvasEditor
    private var candidates: [ShapeKind: [ErasedSlashCommand]] = [:]
    /// The commands about the command bar's target as a whole, in plugin order, gathered once.
    private lazy var aboutTargets: [ErasedSlashCommand] = editor.registry.contributions(to: SelectionSlashCommands.self).map(\.value.command)
    /// What the command bar's target listed last, and the revisions it was found at.
    private var kept: Kept?

    private struct Kept {
        let target: SlashTarget
        let revision: Int
        let layoutRevision: Int
        let commands: [OfferedSlashCommand]
    }

    #if DEBUG
    /// How many records the listing has read (debug builds), so tests can hold a selection's to being
    /// read once while the file stands.
    public private(set) var recordsRead = 0
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
    }

    /// What a target offers now, in the order the first of its shapes lists them, then what only later
    /// shapes offer, as they list it. A shape offers its kind's own commands, then those of the scopes
    /// that reach its kind (a kind's own taking the place of one of the same name, offered or not), each
    /// in plugin and builder order, those whose `when` holds for the shape as it is; a declared command
    /// while its rule can act on the shapes that offer it (or by `when` alone, with `tries`). A command
    /// is its name: the shapes that offer it are its reach (`OfferedSlashCommand.shapes`), and it's
    /// listed when some do (any of them: the owner's call), a command on one shape (`SlashReach.one`)
    /// only where the target has one. Two kinds' own commands of one name are one row, each run on its
    /// own shapes, unless either takes a shape or a choice (two rules, two lists of rows: left out) or
    /// they take different arguments.
    ///
    /// None for a shape that isn't on the board shown or is kept aside. A shape's text (`.text`) that is
    /// read-only offers nothing (its text can't be edited, and a command would change it); in the
    /// command bar (`.selection`, `.everything`) a read-only shape is offered only the commands a plugin
    /// declared, whose rule decides (Unlock acts on a locked shape; nothing else does). After them, in the
    /// bar alone, come the commands about its target as a whole (`SelectionSlashCommand`) whose rule says
    /// the target offers them, each on every shape of it there to act on. The bar's list is kept until the
    /// file or its layout changes.
    public func commands(for target: SlashTarget) -> [OfferedSlashCommand] {
        if !target.isText, let kept, kept.target == target, kept.revision == editor.revision,
           kept.layoutRevision == editor.layoutRevision {
            return kept.commands
        }
        let found = find(for: target)
        if !target.isText {
            kept = Kept(target: target, revision: editor.revision, layoutRevision: editor.layoutRevision, commands: found)
        }
        return found
    }

    /// What a shape's text offers: `commands(for: .text(id))`.
    public func commands(for id: ShapeID) -> [OfferedSlashCommand] { commands(for: .text(id)) }

    private func find(for target: SlashTarget) -> [OfferedSlashCommand] {
        let isText = target.isText
        // The shapes there to act on, each once, in target order, with what each offers by `when`.
        var shapes: [ShapeID] = []
        var seen = Set<ShapeID>()
        // A name's commands, by the order names first come: each command with the shapes that offer it.
        var order: [String] = []
        var byName: [String: [(command: ErasedSlashCommand, shapes: [ShapeID])]] = [:]
        for id in target.shapes where seen.insert(id).inserted {
            guard let record = editor.document[id], !record.isOpaque else { continue }
            #if DEBUG
            recordsRead += 1
            #endif
            let readOnly = editor.isReadOnly(id)
            if isText, readOnly { continue }
            shapes.append(id)
            for command in candidates(for: record.kind) where command.isOffered(record) {
                // A read-only shape is reached only by a command a plugin declared, where its rule can act on
                // the shape alone (Unlock on a locked one), a try's too: no row in the bar can only be refused.
                if readOnly {
                    guard let declared = command.command, editor.canPerform(declared, on: [id]) else { continue }
                }
                if byName[command.name] == nil { order.append(command.name) }
                if let at = byName[command.name, default: []].firstIndex(where: { $0.command === command }) {
                    byName[command.name]![at].shapes.append(id)
                } else {
                    byName[command.name, default: []].append((command, [id]))
                }
            }
        }
        let count = shapes.count
        let offered: [OfferedSlashCommand] = order.compactMap { name in
            var parts = byName[name] ?? []
            if count > 1 { parts.removeAll { $0.command.reach == .one } }
            parts.removeAll { !offersCommand($0.command, on: $0.shapes) }
            guard let first = parts.first else { return nil }
            var reached = first.shapes
            if parts.count > 1 {
                guard !parts.contains(where: { $0.command.takesShapeOrChoice || $0.command.argument != first.command.argument }) else { return nil }
                // Each part's shapes are in target order; two parts never share a shape.
                let offering = Set(parts.flatMap(\.shapes))
                reached = shapes.filter(offering.contains)
            }
            return OfferedSlashCommand(parts.map { OfferedSlashCommand.Part(command: $0.command, shapes: $0.shapes) }, shapes: reached,
                                       targetCount: count, target: target, editor: editor)
        }
        guard !isText else { return offered }
        // The commands about the bar's target as a whole, on all of it there to act on, read-only shapes too.
        return offered + aboutTargets.compactMap { command in
            guard let isOffered = command.isOfferedFor, isOffered(target, editor) else { return nil }
            return OfferedSlashCommand([OfferedSlashCommand.Part(command: command, shapes: shapes)], shapes: shapes, targetCount: count,
                                       target: target, editor: editor)
        }
    }

    /// For one typed for a command a plugin declared: a plugin claims it, and it can act on the shapes
    /// (its rule), unless it's offered by its `when` alone (a try). Any other, yes.
    private func offersCommand(_ command: ErasedSlashCommand, on ids: [ShapeID]) -> Bool {
        guard let declared = command.command else { return true }
        return command.tries ? editor.registry.claims(declared) : editor.canPerform(declared, on: ids)
    }

    /// The command of a name (folded to lowercase) that a target offers now.
    public func command(named name: String, for target: SlashTarget) -> OfferedSlashCommand? {
        let name = name.lowercased()
        return commands(for: target).first { $0.name == name }
    }

    /// The command of a name that a shape's text offers now.
    public func command(named name: String, for id: ShapeID) -> OfferedSlashCommand? { command(named: name, for: .text(id)) }

    /// Runs a command on the shapes it acts on with what was typed after its name: one undo step, named
    /// for the command (`stepName`), whatever it commits, each of its parts on its own shapes. The command
    /// is the one `commands(for:)` or `command(named:for:)` just gave, so `when` isn't asked again (a
    /// caller that took text out first, as a text view takes the command's line, would find a command
    /// that reads the text gone), and it runs on the shapes of it still there and not kept aside. False,
    /// doing nothing, with none left, for arguments the command doesn't accept, and for a command that
    /// answers later, which is started (`answer(_:with:)`), not run.
    @discardableResult
    public func run(_ command: OfferedSlashCommand, with arguments: SlashArguments) -> Bool {
        let parts = live(command)
        guard !command.answersLater, !parts.isEmpty, command.accepts(arguments) else { return false }
        editor.undoHistory.group(command.stepName) {
            for part in parts { part.command.run(part.shapes, arguments, editor) }
        }
        return true
    }

    /// Starts a command that answers later (`SelectionSlashCommand`) with what was typed after its name:
    /// the task whose answer the command bar waits for, which the caller cancels when it stops waiting. It
    /// is started as it was found, for the target it was found for, `when` not asked again. Nil, starting
    /// nothing, for any other command, for arguments it doesn't accept, and once the editor is gone.
    public func answer(_ command: OfferedSlashCommand, with arguments: SlashArguments) -> Task<SlashAnswer, Never>? {
        guard let answering = command.answering, command.accepts(arguments) else { return nil }
        return answering(arguments)
    }

    /// Runs a choice command with a pick on the shapes it acts on: one undo step, named for the row
    /// (`SlashChoice.step`), else for the command. False, doing nothing, with none of its shapes left and
    /// for a command that takes no choice.
    @discardableResult
    public func run(_ command: OfferedSlashCommand, choosing choice: SlashChoice) -> Bool {
        let parts = live(command)
        guard let part = parts.first, parts.count == 1, let runChoice = part.command.runChoice else { return false }
        editor.undoHistory.group(choice.step ?? command.stepName) { runChoice(part.shapes, choice, editor) }
        return true
    }

    /// Runs a command found for a shape's text on that shape (`run(_:with:)`): false, doing nothing, for
    /// one found for other shapes.
    @discardableResult
    public func run(_ command: OfferedSlashCommand, on id: ShapeID, with arguments: SlashArguments) -> Bool {
        guard command.shapes == [id] else { return false }
        return run(command, with: arguments)
    }

    /// Runs a pick of a command found for a shape's text on that shape (`run(_:choosing:)`): false,
    /// doing nothing, for one found for other shapes.
    @discardableResult
    public func run(_ command: OfferedSlashCommand, on id: ShapeID, choosing choice: SlashChoice) -> Bool {
        guard command.shapes == [id] else { return false }
        return run(command, choosing: choice)
    }

    /// The same, by name: the command is resolved now, so false for one the target doesn't offer now
    /// (`when` asked).
    @discardableResult
    public func run(_ name: String, for target: SlashTarget, with arguments: SlashArguments) -> Bool {
        guard let command = command(named: name, for: target) else { return false }
        return run(command, with: arguments)
    }

    /// `answer(_:with:)` by name, resolved now: nil for a command the target doesn't offer now.
    public func answer(_ name: String, for target: SlashTarget, with arguments: SlashArguments) -> Task<SlashAnswer, Never>? {
        guard let command = command(named: name, for: target) else { return nil }
        return answer(command, with: arguments)
    }

    /// The same, by name, with a pick.
    @discardableResult
    public func run(_ name: String, for target: SlashTarget, choosing choice: SlashChoice) -> Bool {
        guard let command = command(named: name, for: target) else { return false }
        return run(command, choosing: choice)
    }

    /// The same, by name, on a shape's text.
    @discardableResult
    public func run(_ name: String, on id: ShapeID, choosing choice: SlashChoice) -> Bool {
        run(name, for: .text(id), choosing: choice)
    }

    /// The same, by name, on a shape's text.
    @discardableResult
    public func run(_ name: String, on id: ShapeID, with arguments: SlashArguments) -> Bool {
        run(name, for: .text(id), with: arguments)
    }

    /// A command's parts on the shapes of each still on the board shown and not kept aside; a part with
    /// none left is gone.
    private func live(_ command: OfferedSlashCommand) -> [OfferedSlashCommand.Part] {
        command.parts.compactMap { part in
            let shapes = part.shapes.filter { editor.document[$0].map { !$0.isOpaque } ?? false }
            return shapes.isEmpty ? nil : OfferedSlashCommand.Part(command: part.command, shapes: shapes)
        }
    }

    /// The kind's own commands, then those of the scopes that reach it, one of each name, each in
    /// plugin and builder order.
    private func candidates(for kind: ShapeKind) -> [ErasedSlashCommand] {
        if let known = candidates[kind] { return known }
        var names = Set<String>()
        let found = editor.registry.contributions(to: ShapeSlashCommands.self, for: kind)
            .flatMap(\.commands).filter { names.insert($0.name).inserted }
        candidates[kind] = found
        return found
    }
}

extension SlashCommandState: EditorService {
    /// Another board shown: the selection's list kept was the board left's.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) { kept = nil }
}

extension CanvasEditor {
    /// What this editor's shapes offer as slash commands; nil without `SlashCommandsPlugin`.
    public var slashCommands: SlashCommandState? { service(SlashCommandState.self) }
}

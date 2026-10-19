import Canvas

/// A command a shape offers just now, as the list shows it and `SlashCommandState` runs it. It's
/// found for one shape (`SlashCommandState.commands(for:)`), the one the line is on, and a command
/// that takes a shape asks its rule about the shapes it's given with that shape and the editor.
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
    let command: ErasedSlashCommand
    /// The command's rule for which shape it takes, alone: bound to the shape it was found for and to
    /// the editor, held weakly, since the state holds its editor unowned and a command outlives the
    /// call that found it (a list and a text view keep it). Nil for a command that takes no shape.
    fileprivate let rule: (@MainActor (ShapeID) -> Bool)?
    /// The same with the kinds: a shape of a kind it names, and the rule says yes.
    fileprivate let admitsShape: (@MainActor (ShapeID) -> Bool)?
    /// A choice command's rows and its row for nothing matching, bound as `rule` is; nil for the
    /// other forms.
    fileprivate let choiceRows: (@MainActor () -> [SlashChoice])?
    fileprivate let choiceOtherwise: (@MainActor (String) -> SlashChoice?)?

    init(_ command: ErasedSlashCommand, owner: ShapeID, editor: CanvasEditor) {
        self.command = command
        name = command.name
        argument = command.argument
        if let choices = command.choices {
            choiceRows = { [weak editor] in editor.map { choices(owner, $0) } ?? [] }
            let otherwise = command.otherwise
            choiceOtherwise = { [weak editor] typed in editor.flatMap { otherwise?(typed, owner, $0) } }
        } else {
            choiceRows = nil
            choiceOtherwise = nil
        }
        let kinds = command.kinds(in: editor.registry)
        admittedKinds = kinds
        guard let shapes = command.shapes else {
            rule = nil
            admitsShape = nil
            return
        }
        let admits: @MainActor (ShapeID) -> Bool = { [weak editor] target in
            guard let editor else { return false }
            return shapes(target, owner, editor)
        }
        rule = admits
        if let kinds {
            admitsShape = { [weak editor] target in
                guard let editor, let kind = editor.shape(inFile: target)?.kind, kinds.contains(kind) else { return false }
                return shapes(target, owner, editor)
            }
        } else {
            admitsShape = admits
        }
    }

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

    /// What the undo step it makes is called: the title, unless the command says otherwise (`SlashCommand`'s `step:`).
    public var stepName: String { command.step ?? title }

    /// Whether it takes one shape (`SlashCommand`'s `shapes:` form): what's typed after its name must
    /// be exactly one, which `admits(_:)` says yes to.
    public var takesShape: Bool { admitsShape != nil }

    /// Whether the shape it takes may be `shape`, for the shape it was found for: of a kind it names,
    /// if it names any (`admittedKinds`: its kind is read from its record anywhere in the file, so a
    /// shape that isn't there is of none), and its rule says yes. False for a command that takes no
    /// shape.
    public func admits(_ shape: ShapeID) -> Bool { admitsShape?(shape) ?? false }

    /// Whether it takes one choice from a list (`SlashCommand`'s `choices:` form): it never runs
    /// with `SlashArguments`, only with a pick (`SlashCommandState.run(_:on:choosing:)`).
    public var takesChoice: Bool { choiceRows != nil }

    /// The rows it lists now, in its order; none for a command that takes no choice. Asked each
    /// time: a list asks once when it opens.
    public func choices() -> [SlashChoice] { choiceRows?() ?? [] }

    /// The one row it offers for what was typed (trimmed), if it offers one: the list puts it last,
    /// unless a row is titled so.
    public func choice(otherwise typed: String) -> SlashChoice? { choiceOtherwise?(typed) }

    /// What a text view that lists shapes asks, for the line it's on: the kinds and the rule of the
    /// command it's a line of, if it takes a shape.
    var shapeRule: SlashShapeRule? {
        guard let rule, let admitsShape else { return nil }
        return SlashShapeRule(kinds: admittedKinds, rule: rule, admits: admitsShape)
    }

    /// Whether it can run with what was typed after its name (`SlashCommand`'s `accepts`): for a
    /// command that takes a shape, that's exactly one shape, which it admits, and nothing else.
    public func accepts(_ arguments: SlashArguments) -> Bool {
        guard command.accepts(arguments) else { return false }
        guard let admitsShape else { return true }
        guard case .shape(let target, _)? = arguments.runs.first else { return false }
        return admitsShape(target)
    }
}

/// Which shapes the command on a line takes, as a host that lists shapes asks it
/// (`SlashCommandTyping.admittedShapes(at:)`; Mentions' `@` picker): the kinds it takes at most, and
/// its rule, for the shape the line is on. A list that ranks only the shapes of `kinds` asks `rule`
/// of each; anything else asks `admits(_:)`.
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

/// What slash commands know of an editor: which commands a shape offers, and running one. Per
/// editor (so per window), and it keeps nothing per shape: each kind's commands are gathered once
/// (the registry is frozen), and what a shape offers is asked of its record each time, so a command
/// offered `when` a property holds follows it with no upkeep.
@MainActor
public final class SlashCommandState {
    private unowned let editor: CanvasEditor
    private var candidates: [ShapeKind: [ErasedSlashCommand]] = [:]

    init(editor: CanvasEditor) {
        self.editor = editor
    }

    /// What a shape offers now: its kind's own commands, then every shape's that its kind lets in (a
    /// kind's own taking the place of one of the same name, offered or not), each in plugin and
    /// builder order, those whose `when` holds for the shape as it is. None for a shape that isn't on
    /// the board shown, or is kept aside, or is read-only (its text can't be edited, and a command
    /// would change it).
    public func commands(for id: ShapeID) -> [OfferedSlashCommand] {
        guard let record = editor.document[id], !record.isOpaque, !editor.isReadOnly(id) else { return [] }
        return candidates(for: record.kind).filter { $0.isOffered(record) }.map { OfferedSlashCommand($0, owner: id, editor: editor) }
    }

    /// The command of a name (folded to lowercase) that a shape offers now.
    public func command(named name: String, for id: ShapeID) -> OfferedSlashCommand? {
        let name = name.lowercased()
        return commands(for: id).first { $0.name == name }
    }

    /// Runs a command on a shape with what was typed after its name: one undo step, named for the
    /// command (`title`), whatever it commits. The command is the one `commands(for:)` or
    /// `command(named:for:)` just gave, so `when` isn't asked again (a caller that took text out
    /// first, as a text view takes the command's line, would find a command that reads the text
    /// gone). False, doing nothing, for a shape that's gone or kept aside, and for arguments the
    /// command doesn't accept.
    @discardableResult
    public func run(_ command: OfferedSlashCommand, on id: ShapeID, with arguments: SlashArguments) -> Bool {
        guard let record = editor.document[id], !record.isOpaque, command.accepts(arguments) else { return false }
        editor.undoHistory.group(command.stepName) { command.command.run(id, arguments, editor) }
        return true
    }

    /// Runs a choice command with a pick: one undo step, named for the row (`SlashChoice.step`),
    /// else for the command. False, doing nothing, for a shape that's gone or kept aside and for a
    /// command that takes no choice.
    @discardableResult
    public func run(_ command: OfferedSlashCommand, on id: ShapeID, choosing choice: SlashChoice) -> Bool {
        guard let record = editor.document[id], !record.isOpaque, let runChoice = command.command.runChoice else { return false }
        editor.undoHistory.group(choice.step ?? command.stepName) { runChoice(id, choice, editor) }
        return true
    }

    /// The same, by name.
    @discardableResult
    public func run(_ name: String, on id: ShapeID, choosing choice: SlashChoice) -> Bool {
        guard let command = command(named: name, for: id) else { return false }
        return run(command, on: id, choosing: choice)
    }

    /// The same, by name: the command is resolved now, so false for one the shape doesn't offer
    /// now (`when` asked).
    @discardableResult
    public func run(_ name: String, on id: ShapeID, with arguments: SlashArguments) -> Bool {
        guard let command = command(named: name, for: id) else { return false }
        return run(command, on: id, with: arguments)
    }

    /// The kind's own commands, then every shape's that apply to it, one of each name, each in
    /// plugin and builder order.
    private func candidates(for kind: ShapeKind) -> [ErasedSlashCommand] {
        if let known = candidates[kind] { return known }
        guard let definition = editor.registry.definition(for: kind) else { return [] }
        let ofKind = SlashCommandKind(kind: kind, definition: definition, registry: editor.registry)
        var names = Set<String>()
        let found = editor.registry.contributions(to: ShapeSlashCommands.self, for: kind)
            .filter { $0.appliesTo(ofKind) }.flatMap(\.commands).filter { names.insert($0.name).inserted }
        candidates[kind] = found
        return found
    }
}

extension SlashCommandState: EditorService {}

extension CanvasEditor {
    /// What this editor's shapes offer as slash commands; nil without `SlashCommandsPlugin`.
    public var slashCommands: SlashCommandState? { service(SlashCommandState.self) }
}

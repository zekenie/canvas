import Canvas

/// A command a shape offers just now, as the list shows it and `SlashCommandState` runs it.
@MainActor
public struct OfferedSlashCommand {
    /// As typed after the `/`: `set-title`.
    public let name: String
    /// The hint for what it takes ("title", "@shape"); nil for a command that takes none.
    public let argument: String?
    let command: ErasedSlashCommand

    init(_ command: ErasedSlashCommand) {
        self.command = command
        name = command.name
        argument = command.argument
    }

    /// The name in words, in title case as a macOS menu has it: every word capitalized but the
    /// articles, coordinating conjunctions and short prepositions (`minorWords`), which stay lowercase
    /// unless first or last: "Set Title", "Move to Back", "Turn into Subboard". The undo step the
    /// command makes is named for it, so it reads as the menu item that does the same does.
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

    /// Whether it can run with what was typed after its name (`SlashCommand`'s `accepts`).
    public func accepts(_ arguments: SlashArguments) -> Bool { command.accepts(arguments) }
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
    /// the board shown, or is kept aside.
    public func commands(for id: ShapeID) -> [OfferedSlashCommand] {
        guard let record = editor.document[id], !record.isOpaque else { return [] }
        return candidates(for: record.kind).filter { $0.isOffered(record) }.map(OfferedSlashCommand.init)
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
        editor.undoHistory.group(command.title) { command.command.run(id, arguments, editor) }
        return true
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

extension SlashCommandState: EditorService {
    /// Nothing kept per shape, so nothing to follow to another board.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {}
}

extension CanvasEditor {
    /// What this editor's shapes offer as slash commands; nil without `SlashCommandsPlugin`.
    public var slashCommands: SlashCommandState? { service(SlashCommandState.self) }
}

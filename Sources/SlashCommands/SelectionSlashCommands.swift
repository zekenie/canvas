import Canvas

/// What a command that answers later came to (`SelectionSlashCommand`).
public enum SlashAnswer: Sendable, Equatable {
    /// Done: the bar closes, if what the command did hasn't closed it already (a selection changed).
    case done
    /// Not done, and why, in a few words ("No matches", "Not signed in"): the bar says it, its line still in
    /// its field to change and run again.
    case failed(String)
}

/// A command about the target as a whole rather than about each of its shapes, typed in the command bar
/// (`SlashTarget.selection`, or `.everything` with nothing selected) and never on a line of a shape's
/// text: `/query`, which selects what a question finds among them. Its own rule says which targets offer
/// it (`when`, asked with the target and the editor: `/query` is on several shapes or everything, never one
/// shape), and it's listed after what the shapes offer. It reaches every shape of the target, a read-only
/// one too, since being offered changes none of them; it is never partial.
///
/// It takes time, and answers later: run, it hands back a task (`answer`, asked with the target, what was
/// typed and the editor) whose answer says whether it's done (`SlashAnswer`), and the bar waits for it with
/// its line kept in the field, saying it waits, and stops it (cancels the task) as it closes, or when the
/// line is changed or run again. The task holds nothing that keeps the editor alive (take what it needs at
/// once, as `QueryTranslator` does, and the editor weakly), so a file closed while it waits goes; the bar
/// cancels it then too. `waiting` is what VoiceOver hears while it waits ("Asking").
///
///     SelectionSlashCommand("query", argument: "question", waiting: "Asking", when: { target, _ in target.shapes.count != 1 }) { target, arguments, editor in
///         let translator = editor.queryTranslator
///         return Task { @MainActor [weak editor] in … }
///     }
///
/// A name is lowercase letters and digits, words joined by hyphens, as a shape's command's, and no shape's
/// command may have it (the registry refuses either).
public struct SelectionSlashCommand {
    let name: String
    let argument: String?
    let waiting: String?
    let isOffered: @MainActor (SlashTarget, CanvasEditor) -> Bool
    let accepts: @MainActor (SlashArguments) -> Bool
    let answer: @MainActor (SlashTarget, SlashArguments, CanvasEditor) -> Task<SlashAnswer, Never>

    /// `argument` is the hint beside the name in the list, and says it takes one; `accepts` which arguments
    /// it runs with (by default none without an `argument`, anything but nothing with one).
    public init(_ name: String, argument: String? = nil, waiting: String? = nil,
                when isOffered: @escaping @MainActor (SlashTarget, CanvasEditor) -> Bool = { _, _ in true },
                accepts: (@MainActor (SlashArguments) -> Bool)? = nil,
                answer: @escaping @MainActor (SlashTarget, SlashArguments, CanvasEditor) -> Task<SlashAnswer, Never>) {
        self.name = name
        self.argument = argument
        self.waiting = waiting
        self.isOffered = isOffered
        let takesArgument = argument != nil
        self.accepts = accepts ?? { takesArgument ? !$0.isEmpty : $0.isEmpty }
        self.answer = answer
    }
}

// MARK: The extension point

/// The commands about the command bar's target as a whole (`SelectionSlashCommand`), keyed by name: two
/// plugins offering one name are `RegistryError.conflict` at startup, and a name a shape's command also has
/// (`ShapeSlashCommands`), or that can't be typed as one, refuses the plugin list.
public enum SelectionSlashCommands {}

extension SelectionSlashCommands: KeyedExtensionPoint {
    public typealias Contribution = SelectionSlashCommandContribution
    public static var owner: PluginID { .slashCommands }

    public static func uniqueKeys(of contribution: SelectionSlashCommandContribution, for _: ShapeTarget) -> [AnyHashable] {
        ["/" + contribution.command.name]
    }

    /// "/query → the command bar's target".
    public static func summary(of contribution: SelectionSlashCommandContribution, for _: ShapeTarget) -> String {
        "/\(contribution.command.name) → the command bar's target"
    }

    public static func check(_ registry: Registry) throws(RegistryError) {
        let shapes = Set(registry.contributions(to: ShapeSlashCommands.self).flatMap { $0.value.commands.map(\.name) })
        for contributed in registry.contributions(to: SelectionSlashCommands.self) {
            let name = contributed.value.command.name
            guard SlashCommandLine.isName(name) else {
                throw .invalid(point: "SelectionSlashCommands", reason: "\(contributed.pluginID) offers /\(name), which can't be typed as a command's name: "
                               + "lowercase letters and digits, words joined by hyphens")
            }
            guard !shapes.contains(name) else {
                throw .invalid(point: "SelectionSlashCommands", reason: "\(contributed.pluginID) offers /\(name) for the command bar's target, "
                               + "which a shape's command is called too")
            }
        }
    }
}

/// What `SelectionSlashCommands` stores: one command, erased. Only the sugar below makes one.
@MainActor
public struct SelectionSlashCommandContribution {
    let command: ErasedSlashCommand
}

extension PluginRegistrar {
    /// A command about the command bar's target as a whole (`SelectionSlashCommand`): `/query`.
    public mutating func selectionSlashCommand(_ command: SelectionSlashCommand) {
        contribute(SelectionSlashCommandContribution(command: ErasedSlashCommand(command)), to: SelectionSlashCommands.self)
    }
}

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
/// (`SlashTarget.selection`, or `.everything` with nothing selected, an empty board too) and never on a
/// line of a shape's text: `/query`, which selects what a question finds among them, and StickyNotes'
/// `/bulk-create`, which makes notes to put down. Its own rule says which targets offer it (`when`, asked
/// with the target and the editor: `/query` is on several shapes or everything, never one shape), and it's
/// listed after what the shapes offer. It reaches every shape of the target, a read-only one too, since
/// being offered changes none of them; it is never partial.
///
/// It answers later, or runs at once. One that answers later takes time: run, it hands back a task
/// (`answer`, asked with the target, what was typed and the editor) whose answer says whether it's done
/// (`SlashAnswer`), and the bar waits for it with its line kept in the field, saying it waits, and stops it
/// (cancels the task) as it closes, or when the line is changed or run again. The task holds nothing that
/// keeps the editor alive (take what it needs at once, as `QueryTranslator` does, and the editor weakly), so
/// a file closed while it waits goes; the bar cancels it then too. `waiting` is what VoiceOver hears while
/// it waits ("Interpreting…").
///
///     SelectionSlashCommand("query", argument: "question", waiting: "Interpreting…", when: { target, _ in target.shapes.count != 1 }) { target, arguments, editor in
///         let translator = editor.queryTranslator
///         return Task { @MainActor [weak editor] in … }
///     }
///
/// One that runs at once (`SelectionSlashCommand.atOnce`) is run as a shape's command is, the bar closed
/// first, in one undo step named for it (none if it commits nothing), on an empty board too.
///
/// One that acts on the board shown as such, not on each shape of it (`/constrain` adds to the board's list), names its
/// target for the bar with nothing selected (`naming(everything:)`: the board's name), so the bar doesn't say it acts on
/// "All shapes"; every other command keeps that.
///
/// A name is lowercase letters and digits, words joined by hyphens, as a shape's command's, and no shape's
/// command may have it (the registry refuses either).
public struct SelectionSlashCommand {
    let name: String
    let argument: String?
    let waiting: String?
    let isOffered: @MainActor (SlashTarget, CanvasEditor) -> Bool
    let accepts: @MainActor (SlashArguments) -> Bool
    let action: Action
    /// What it calls the target when nothing is selected, in the bar's label ("Plans"); nil: the bar's own, "All shapes".
    private(set) var everythingName: (@MainActor (CanvasEditor) -> String)?

    /// What it does with what was typed: start a task the bar waits for, act at once, or act on a pick of a list.
    enum Action {
        case answer(@MainActor (SlashTarget, SlashArguments, CanvasEditor) -> Task<SlashAnswer, Never>)
        case run(@MainActor (SlashTarget, SlashArguments, CanvasEditor) -> Void)
        case choose(choices: @MainActor (SlashTarget, CanvasEditor) -> [SlashChoice],
                    perform: @MainActor (SlashTarget, SlashChoice, CanvasEditor) -> Void)
    }

    /// A command that answers later. `argument` is the hint beside the name in the list, and says it takes
    /// one; `accepts` which arguments it runs with (by default none without an `argument`, anything but
    /// nothing with one).
    public init(_ name: String, argument: String? = nil, waiting: String? = nil,
                when isOffered: @escaping @MainActor (SlashTarget, CanvasEditor) -> Bool = { _, _ in true },
                accepts: (@MainActor (SlashArguments) -> Bool)? = nil,
                answer: @escaping @MainActor (SlashTarget, SlashArguments, CanvasEditor) -> Task<SlashAnswer, Never>) {
        self.init(name, argument: argument, waiting: waiting, when: isOffered, accepts: accepts, action: .answer(answer))
    }

    private init(_ name: String, argument: String?, waiting: String?, when isOffered: @escaping @MainActor (SlashTarget, CanvasEditor) -> Bool,
                 accepts: (@MainActor (SlashArguments) -> Bool)?, action: Action) {
        self.name = name
        self.argument = argument
        self.waiting = waiting
        self.isOffered = isOffered
        let takesArgument = argument != nil
        self.accepts = accepts ?? { takesArgument ? !$0.isEmpty : $0.isEmpty }
        self.action = action
    }

    /// A command that runs at once, with the target, what was typed and the editor, as a shape's command
    /// runs: the bar closes first, and what it commits is one undo step named for it. `argument` and
    /// `accepts` as for one that answers later. Static, so its closure never collides with the other form's
    /// in a trailing closure.
    public static func atOnce(_ name: String, argument: String? = nil,
                              when isOffered: @escaping @MainActor (SlashTarget, CanvasEditor) -> Bool = { _, _ in true },
                              accepts: (@MainActor (SlashArguments) -> Bool)? = nil,
                              run: @escaping @MainActor (SlashTarget, SlashArguments, CanvasEditor) -> Void) -> SelectionSlashCommand {
        SelectionSlashCommand(name, argument: argument, waiting: nil, when: isOffered, accepts: accepts, action: .run(run))
    }

    /// The same, with the name the bar's label gives the target while this command is the one typed, with nothing selected
    /// (`.everything`), in place of "All shapes": VoiceOver hears "Command for <name>". Asked each time the line is edited.
    public func naming(everything name: @escaping @MainActor (CanvasEditor) -> String) -> SelectionSlashCommand {
        var named = self
        named.everythingName = name
        return named
    }

    /// A command that takes one choice from a list, as a shape's `SlashCommand` of the `choices:` form does, about the
    /// target as a whole: the list opens when its name is done (Tab, or a space typed after it), narrows as text is typed, and
    /// a pick runs `perform` at once, in one undo step named for the row (`SlashChoice.step`), else for the command. `choices`
    /// is asked with the target and the editor once, when the list opens; its rows are about what the target is (nothing selected
    /// is the board shown). It takes no arguments as such (`accepts` is never true: the names' list's Return completes it).
    /// Static, so its closures never collide with the other forms' in a trailing closure.
    ///
    ///     SelectionSlashCommand.choosing("unconstrain", argument: "constraint", when: { target, editor in … },
    ///                                    choices: { target, editor in … }) { target, choice, editor in … }
    public static func choosing(_ name: String, argument: String,
                                when isOffered: @escaping @MainActor (SlashTarget, CanvasEditor) -> Bool = { _, _ in true },
                                choices: @escaping @MainActor (SlashTarget, CanvasEditor) -> [SlashChoice],
                                perform: @escaping @MainActor (SlashTarget, SlashChoice, CanvasEditor) -> Void) -> SelectionSlashCommand {
        SelectionSlashCommand(name, argument: argument, waiting: nil, when: isOffered, accepts: { _ in false },
                              action: .choose(choices: choices, perform: perform))
    }
}

// MARK: The extension point

/// The commands about the command bar's target as a whole (`SelectionSlashCommand`), keyed by name: two
/// plugins offering one name are `RegistryError.conflict` at startup, and a name a shape's command also has
/// (`ShapeSlashCommands`), or that can't be typed as one, refuses the plugin list.
public enum SelectionSlashCommands {}

/// A kit switches its plugins' commands about the bar's target, as it does their commands for shapes.
extension SelectionSlashCommands: KitSwitched {}

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
    /// A command about the command bar's target as a whole (`SelectionSlashCommand`): `/query`, `/bulk-create`.
    public mutating func selectionSlashCommand(_ command: SelectionSlashCommand) {
        contribute(SelectionSlashCommandContribution(command: ErasedSlashCommand(command)), to: SelectionSlashCommands.self)
    }
}

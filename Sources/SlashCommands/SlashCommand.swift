import Canvas

/// One command a shape offers, typed as `/name` on a line of its text, over `Value`: the kind's
/// props for a kind's own commands (`x.slashCommands { }`), an added property's value for its
/// commands (`x.slashCommands(of: P.self) { }`), or `AnyShapeRecord` for a scope's
/// (`registrar.forShapes(holding: P.self) { $0.slashCommands { } }`).
///
///     SlashCommand("rename", argument: "name") { lamp, arguments in lamp.name = arguments.text }
///     SlashCommand("turn-on", when: { !$0.isOn }) { lamp, _ in lamp.isOn = true }
///     SlashCommand("pin", argument: "@shape") { id, arguments, editor in pin(id, to: arguments.shapes, in: editor) }
///
/// A name is lowercase letters and digits, words joined by hyphens (the registry refuses any other:
/// it's what can be typed and completed). It's offered for a shape when `when` says so (always, by
/// default); `argument` is the hint shown beside the name in the list ("title", "@shape") and says
/// the command takes one. `accepts` says which arguments the command can run with: by default none
/// for a command without an `argument`, and anything for one with, as long as something was typed;
/// given, it replaces that rule entirely. Arguments it doesn't accept leave the line as text: the
/// command never runs, and Return is a new line.
///
/// A command that takes one shape (`init(_:argument:when:kinds:shapes:step:perform:)`) has a rule for
/// which, as `accepts` can't: it sees only what was typed, and a mention's pill is a shape whatever
/// kind it names. What's typed must be exactly one shape the rule admits (asked with the shape, the
/// shape the line is on and the editor), of the kinds it names, if it names any; a text view that
/// lets shapes be picked (Mentions') lists only those when an `@` is typed on the command's line,
/// and ranks only the shapes of those kinds, so a command that takes few of a big board's shapes
/// costs what they are.
///
/// A command's undo step is named for it in words (`/set-title`: "Set Title"); `step:` names it
/// otherwise, as a person would call what it did (`/public`: "Make Public", as the menu's item).
///
/// A name is the command's identity: two plugins offering one name to the same shapes are a
/// `conflict`, and a kind's own command takes the place of a scope's of the same name.
public struct SlashCommand<Value> {
    let name: String
    let argument: String?
    let isOffered: @MainActor (Value) -> Bool
    let accepts: @MainActor (SlashArguments) -> Bool
    /// For a command that takes one shape: which shapes it admits, given the shape and the one the
    /// line is on; nil for one that takes none.
    let shapes: (@MainActor (_ target: ShapeID, _ owner: ShapeID, CanvasEditor) -> Bool)?
    /// For a command that takes one shape: the most kinds of shape it takes, given the registry; nil
    /// for one that names none (any kind) or takes no shape.
    let kinds: (@MainActor (Registry) -> Set<ShapeKind>)?
    /// For a command that takes one choice: the rows, made when asked, and the one row to offer for
    /// what was typed, last unless a row is titled so; nil for the other forms.
    let choices: (@MainActor (_ owner: ShapeID, CanvasEditor) -> [SlashChoice])?
    let otherwise: (@MainActor (_ typed: String, _ owner: ShapeID, CanvasEditor) -> SlashChoice?)?
    let step: String?
    let action: Action
    /// The command a plugin declared that it runs, for one typed for a command (`init(_:command:when:tries:)`);
    /// nil for the other forms, which set neither of these.
    private(set) var command: CanvasCommand?
    /// Whether it's offered by `when` alone, and run as a try where the command can't act.
    private(set) var tries = false

    enum Action {
        case edit(@MainActor (inout Value, SlashArguments) -> Void)
        case perform(@MainActor (ShapeID, SlashArguments, CanvasEditor) -> Void)
        case choose(@MainActor (ShapeID, SlashChoice, CanvasEditor) -> Void)
    }

    /// Edits the shape the line is on: `edit` runs on its live value in one transaction. Setting what
    /// a shape already has commits nothing.
    public init(_ name: String, argument: String? = nil,
                when isOffered: @escaping @MainActor (Value) -> Bool = { _ in true },
                accepts: (@MainActor (SlashArguments) -> Bool)? = nil,
                step: String? = nil,
                edit: @escaping @MainActor (inout Value, SlashArguments) -> Void) {
        self.name = name
        self.argument = argument
        self.isOffered = isOffered
        self.accepts = accepts ?? Self.defaultAccepts(takesArgument: argument != nil)
        shapes = nil
        kinds = nil
        choices = nil
        otherwise = nil
        self.step = step
        action = .edit(edit)
    }

    /// For what editing the shape can't do (locking it, moving it, putting it somewhere): `perform`
    /// gets the shape, what was typed and the editor, and changes the document only through
    /// `editor.transact`.
    public init(_ name: String, argument: String? = nil,
                when isOffered: @escaping @MainActor (Value) -> Bool = { _ in true },
                accepts: (@MainActor (SlashArguments) -> Bool)? = nil,
                step: String? = nil,
                perform: @escaping @MainActor (ShapeID, SlashArguments, CanvasEditor) -> Void) {
        self.name = name
        self.argument = argument
        self.isOffered = isOffered
        self.accepts = accepts ?? Self.defaultAccepts(takesArgument: argument != nil)
        shapes = nil
        kinds = nil
        choices = nil
        otherwise = nil
        self.step = step
        action = .perform(perform)
    }

    /// A command that takes one shape (`@shape`, a mention's pill) which a rule admits: what's typed
    /// after its name must be exactly that one shape, no text, and `shapes` must say yes to it, asked
    /// with the shape, the shape the line is on (`owner`) and the editor. Anything else isn't
    /// accepted, so the line stays text and Return is a new line, as for any arguments a command
    /// doesn't accept. `accepts` couldn't say it: it sees only what was typed, and a pill is a shape
    /// of whatever kind. Mentions' `@` picker lists only the shapes the rule admits when it's opened
    /// on this command's line (`SlashCommandTyping.admittedShapes(at:)`).
    ///
    /// `kinds` names the most kinds of shape the command takes, given the registry (which says which
    /// kinds hold shapes, own boards, and so on; asked once, the registry being frozen): a shape of
    /// another kind is never admitted, even where `shapes` would say yes, and `shapes` is still asked
    /// of each shape of those kinds. A command that takes few of a big board's shapes names them, so a
    /// list that ranks the shapes it takes (the `@` picker) ranks only those, and costs what they are,
    /// not what the board holds; with none, the rule alone is asked of every shape the list looks at.
    ///
    ///     SlashCommand("pin", kinds: { $0.containingKinds }, shapes: { target, owner, editor in target != owner }) { id, arguments, editor in
    ///         pin(id, to: arguments.shapes[0], in: editor)
    ///     }
    ///
    /// `perform` is the form's only action: it gets the shape the line is on, what was typed (its
    /// `shapes` is the one shape) and the editor, and changes the document only through
    /// `editor.transact`. `argument` is the hint in the list, `@shape` unless a command says more.
    public init(_ name: String, argument: String = "@shape",
                when isOffered: @escaping @MainActor (Value) -> Bool = { _ in true },
                kinds: (@MainActor (Registry) -> Set<ShapeKind>)? = nil,
                shapes admits: @escaping @MainActor (_ target: ShapeID, _ owner: ShapeID, CanvasEditor) -> Bool,
                step: String? = nil,
                perform: @escaping @MainActor (ShapeID, SlashArguments, CanvasEditor) -> Void) {
        self.name = name
        self.argument = argument
        self.isOffered = isOffered
        accepts = { $0.isOneShape }
        shapes = admits
        self.kinds = kinds
        choices = nil
        otherwise = nil
        self.step = step
        action = .perform(perform)
    }

    /// A command that takes one choice from a list made when the line asks for it (`SlashChoice`):
    /// the list opens when its name is done (Tab or a click on it in the names' list, or a space typed
    /// after it), narrows as text is typed, and a pick runs `perform` at once, the whole line taken
    /// out of the text. `choices` is asked once, when the list opens (and once more at a Return on a
    /// closed line typed whole); `otherwise` is asked with what was typed, and returns the one row to
    /// offer for it, or nil: that row goes last, after the matches (the only row where nothing
    /// matches), unless a row is titled what was typed, and is not asked for with nothing typed. A
    /// pick's undo step is its row's `step`, else this command's. `argument` is the hint beside the
    /// name. The command takes no arguments as such (`accepts` is never true): the names' list's
    /// Return completes it rather than running it.
    ///
    ///     SlashCommand("is-a", argument: "type", choices: { owner, editor in rows(for: owner, in: editor) }) { owner, choice, editor in
    ///         editor.makeIt(owner, as: choice.id)
    ///     }
    public init(_ name: String, argument: String,
                when isOffered: @escaping @MainActor (Value) -> Bool = { _ in true },
                choices: @escaping @MainActor (_ owner: ShapeID, CanvasEditor) -> [SlashChoice],
                otherwise: (@MainActor (_ typed: String, _ owner: ShapeID, CanvasEditor) -> SlashChoice?)? = nil,
                step: String? = nil,
                perform: @escaping @MainActor (ShapeID, SlashChoice, CanvasEditor) -> Void) {
        self.name = name
        self.argument = argument
        self.isOffered = isOffered
        accepts = { _ in false }
        shapes = nil
        kinds = nil
        self.choices = choices
        self.otherwise = otherwise
        self.step = step
        action = .choose(perform)
    }

    /// A command a plugin declared (`registrar.command`), typed on a line of the shape's text: offered
    /// while it can act on the shape (its rule, asked with the shape alone, `editor.canPerform(_:on:)`)
    /// and `when` holds of its value, and run on it, as a try (`editor.attempt`: the line is gone by then,
    /// and what was offered isn't asked again), in one undo step named as the command is
    /// (`registry.title(of:)`: `/public` is "Make Public"). It takes no arguments. `tries: true` offers it
    /// by `when` alone, so where the command can't act it runs all the same, which refuses, and the shape
    /// shakes, as a chip's click does (`/private` on a shape something stands for).
    ///
    ///     SlashCommand("lock", command: .lock)
    ///     SlashCommand("private", command: .makePrivate, when: { $0[PublicProperty.self] == true }, tries: true)
    public init(_ name: String, command: CanvasCommand, when isOffered: @escaping @MainActor (Value) -> Bool = { _ in true }, tries: Bool = false) {
        self.name = name
        argument = nil
        self.isOffered = isOffered
        accepts = Self.defaultAccepts(takesArgument: false)
        shapes = nil
        kinds = nil
        choices = nil
        otherwise = nil
        step = nil
        action = .perform { id, _, editor in editor.attempt(command, on: [id]) }
        self.command = command
        self.tries = tries
    }

    private static func defaultAccepts(takesArgument: Bool) -> @MainActor (SlashArguments) -> Bool {
        if takesArgument { return { !$0.isEmpty } }
        return { $0.isEmpty }
    }
}

@resultBuilder
public enum SlashCommandBuilder<Value> {
    public static func buildExpression(_ command: SlashCommand<Value>) -> [SlashCommand<Value>] { [command] }
    public static func buildBlock(_ parts: [SlashCommand<Value>]...) -> [SlashCommand<Value>] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [SlashCommand<Value>]?) -> [SlashCommand<Value>] { part ?? [] }
    public static func buildEither(first part: [SlashCommand<Value>]) -> [SlashCommand<Value>] { part }
    public static func buildEither(second part: [SlashCommand<Value>]) -> [SlashCommand<Value>] { part }
    public static func buildArray(_ parts: [[SlashCommand<Value>]]) -> [SlashCommand<Value>] { parts.flatMap { $0 } }
}

/// A command over any record: hidden for a record it can't read. A class, so a command is the same
/// object wherever it's found.
@MainActor
final class ErasedSlashCommand {
    let name: String
    let argument: String?
    let isOffered: @MainActor (AnyShapeRecord) -> Bool
    let accepts: @MainActor (SlashArguments) -> Bool
    /// Which shapes it takes, for a command that takes one (`SlashCommand`'s `shapes`).
    let shapes: (@MainActor (_ target: ShapeID, _ owner: ShapeID, CanvasEditor) -> Bool)?
    /// What its undo step is called, if not its name in words.
    let step: String?
    /// The most kinds it takes, for a command that names them (`SlashCommand`'s `kinds`), and what the
    /// registry said they were, kept by the first ask: the registry is frozen, and one command
    /// belongs to one registry.
    private let kindsOf: (@MainActor (Registry) -> Set<ShapeKind>)?
    private var kindsFound: Set<ShapeKind>?
    /// Runs it on a shape: the edit in one transaction, or the command's own `perform`.
    let run: @MainActor (ShapeID, SlashArguments, CanvasEditor) -> Void
    /// For a command that takes a choice: its rows, the row for nothing matching, and running a pick.
    let choices: (@MainActor (_ owner: ShapeID, CanvasEditor) -> [SlashChoice])?
    let otherwise: (@MainActor (_ typed: String, _ owner: ShapeID, CanvasEditor) -> SlashChoice?)?
    let runChoice: (@MainActor (ShapeID, SlashChoice, CanvasEditor) -> Void)?
    /// The command a plugin declared that it runs, if it was typed for one, and whether it's offered by
    /// its `when` alone (a try).
    let command: CanvasCommand?
    let tries: Bool

    /// `read` gets the command's value from a record; `write` runs an edit on one shape's live
    /// value, in a transaction.
    init<Value>(_ command: SlashCommand<Value>, read: @escaping @MainActor (AnyShapeRecord) -> Value?,
                write: @escaping @MainActor (ShapeID, inout Transaction, (inout Value) -> Void) -> Void) {
        name = command.name
        argument = command.argument
        let offered = command.isOffered
        isOffered = { read($0).map(offered) ?? false }
        accepts = command.accepts
        shapes = command.shapes
        kindsOf = command.kinds
        step = command.step
        self.command = command.command
        tries = command.tries
        choices = command.choices
        otherwise = command.otherwise
        switch command.action {
        case .edit(let edit):
            run = { id, arguments, editor in
                editor.transact { transaction in write(id, &transaction) { edit(&$0, arguments) } }
            }
            runChoice = nil
        case .perform(let perform):
            run = perform
            runChoice = nil
        case .choose(let choose):
            run = { _, _, _ in }
            runChoice = choose
        }
    }

    /// The most kinds of shape it takes, as the registry (which every editor of this command shares)
    /// says; nil for a command that names none. Asked of the registry once.
    func kinds(in registry: Registry) -> Set<ShapeKind>? {
        guard let kindsOf else { return nil }
        if let kindsFound { return kindsFound }
        let found = kindsOf(registry)
        kindsFound = found
        return found
    }
}

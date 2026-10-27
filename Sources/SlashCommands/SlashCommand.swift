import Canvas

/// How a command acts on a target of several shapes (`SlashTarget.selection`), said where it is
/// registered: nothing becomes plural without its author saying so.
public enum SlashReach: Sendable, Hashable {
    /// On one shape: listed only where the target is one (a text's line, a selection of one). What a
    /// `perform:`, `shapes:` or `choices:` command written for one shape is, so it never runs on
    /// several by accident: `/move-near` run on each of five shapes would land them one by one.
    case one
    /// On each shape it reaches, one by one, in one transaction and one undo step: an `edit:` command,
    /// whose edit is over one shape's value by nature.
    case each
    /// On the shapes it reaches, handed together, once: a command a plugin declared, whose rule and run
    /// take a subject of many, and the plural forms (`SlashCommand.together`), for what must be done as
    /// one: a block moved, nested frames turned innermost first, one type given to many.
    case together
}

/// One command a shape offers, typed as `/name` on a line of its text or in the command bar for the
/// shapes selected, over `Value`: the kind's props for a kind's own commands (`x.slashCommands { }`),
/// an added property's value for its commands (`x.slashCommands(of: P.self) { }`), or `AnyShapeRecord`
/// for a scope's (`registrar.forShapes(holding: P.self) { $0.slashCommands { } }`).
///
///     SlashCommand("rename", argument: "name") { lamp, arguments in lamp.name = arguments.text }
///     SlashCommand("turn-on", when: { !$0.isOn }) { lamp, _ in lamp.isOn = true }
///     SlashCommand("pin", argument: "@shape") { id, arguments, editor in pin(id, to: arguments.shapes, in: editor) }
///     SlashCommand.together("heap") { ids, _, editor in heap(ids, in: editor) }
///
/// A name is lowercase letters and digits, words joined by hyphens (the registry refuses any other:
/// it's what can be typed and completed). It's offered for a shape when `when` says so (always, by
/// default); `argument` is the hint shown beside the name in the list ("title", "@shape") and says
/// the command takes one. `accepts` says which arguments the command can run with: by default none
/// for a command without an `argument`, and anything for one with, as long as something was typed;
/// given, it replaces that rule entirely. Arguments it doesn't accept leave the line as text: the
/// command never runs, and Return is a new line.
///
/// A command says how it acts on several shapes (its `SlashReach`): an edit on each, by default; a
/// command written for one shape (`perform:`, `shapes:`, `choices:`) on one alone, so it's offered only
/// where the target is one shape; a declared command on all together, as its rule and run take many;
/// and the plural forms, `SlashCommand.together(…)`, on all together, handed every shape at once.
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
    let reach: SlashReach
    let isOffered: @MainActor (Value) -> Bool
    let accepts: @MainActor (SlashArguments) -> Bool
    /// For a command that takes one shape: which shapes it admits, given the shape and the shapes the
    /// command acts on (the one the line is on, for a form written for one); nil for one that takes none.
    let shapes: (@MainActor (_ target: ShapeID, _ owners: [ShapeID], CanvasEditor) -> Bool)?
    /// For a command that takes one shape: the most kinds of shape it takes, given the registry; nil
    /// for one that names none (any kind) or takes no shape.
    let kinds: (@MainActor (Registry) -> Set<ShapeKind>)?
    /// For a command that takes one choice: the rows, made when asked for the shapes it acts on, and
    /// the one row to offer for what was typed, last unless a row is titled so; nil for the other forms.
    let choices: (@MainActor (_ owners: [ShapeID], CanvasEditor) -> [SlashChoice])?
    let otherwise: (@MainActor (_ typed: String, _ owners: [ShapeID], CanvasEditor) -> SlashChoice?)?
    let step: String?
    let action: Action
    /// The command a plugin declared that it runs, for one typed for a command (`init(_:command:when:tries:)`);
    /// nil for the other forms, which set neither of these.
    private(set) var command: CanvasCommand?
    /// Whether it's offered by `when` alone, and run as a try where the command can't act.
    private(set) var tries = false

    /// What it does, over the shapes it acts on, in target order: an edit runs on each one's value; a
    /// form written for one shape is handed a list of one.
    enum Action {
        case edit(@MainActor (inout Value, SlashArguments) -> Void)
        case perform(@MainActor ([ShapeID], SlashArguments, CanvasEditor) -> Void)
        case choose(@MainActor ([ShapeID], SlashChoice, CanvasEditor) -> Void)
    }

    /// Every field, as a form gives them.
    private init(name: String, argument: String?, reach: SlashReach, isOffered: @escaping @MainActor (Value) -> Bool,
                 accepts: @escaping @MainActor (SlashArguments) -> Bool,
                 shapes: (@MainActor (_ target: ShapeID, _ owners: [ShapeID], CanvasEditor) -> Bool)? = nil,
                 kinds: (@MainActor (Registry) -> Set<ShapeKind>)? = nil,
                 choices: (@MainActor (_ owners: [ShapeID], CanvasEditor) -> [SlashChoice])? = nil,
                 otherwise: (@MainActor (_ typed: String, _ owners: [ShapeID], CanvasEditor) -> SlashChoice?)? = nil,
                 step: String?, action: Action) {
        self.name = name
        self.argument = argument
        self.reach = reach
        self.isOffered = isOffered
        self.accepts = accepts
        self.shapes = shapes
        self.kinds = kinds
        self.choices = choices
        self.otherwise = otherwise
        self.step = step
        self.action = action
    }

    /// Edits the shape the line is on: `edit` runs on its live value in one transaction. Setting what
    /// a shape already has commits nothing. On several shapes it edits each (`reach` `.each`, the
    /// default: an edit is over one shape's value), in one transaction; `.one` keeps it to one shape
    /// (Titles' `/title`: ten shapes of one title would be ten paths alike).
    public init(_ name: String, argument: String? = nil, reach: SlashReach = .each,
                when isOffered: @escaping @MainActor (Value) -> Bool = { _ in true },
                accepts: (@MainActor (SlashArguments) -> Bool)? = nil,
                step: String? = nil,
                edit: @escaping @MainActor (inout Value, SlashArguments) -> Void) {
        precondition(reach != .together, "an edit is over one shape's value: on several it edits each")
        self.init(name: name, argument: argument, reach: reach, isOffered: isOffered,
                  accepts: accepts ?? Self.defaultAccepts(takesArgument: argument != nil), step: step, action: .edit(edit))
    }

    /// For what editing the shape can't do (locking it, moving it, putting it somewhere): `perform`
    /// gets the shape, what was typed and the editor, and changes the document only through
    /// `editor.transact`. On one shape alone (`reach` `.one`, the default), or on each of several, one
    /// after another in one undo step (`.each`), for an action that means the same done one by one.
    public init(_ name: String, argument: String? = nil, reach: SlashReach = .one,
                when isOffered: @escaping @MainActor (Value) -> Bool = { _ in true },
                accepts: (@MainActor (SlashArguments) -> Bool)? = nil,
                step: String? = nil,
                perform: @escaping @MainActor (ShapeID, SlashArguments, CanvasEditor) -> Void) {
        precondition(reach != .together, "a command handed every shape at once is SlashCommand.together")
        self.init(name: name, argument: argument, reach: reach, isOffered: isOffered,
                  accepts: accepts ?? Self.defaultAccepts(takesArgument: argument != nil), step: step,
                  action: .perform { ids, arguments, editor in
                      for id in reach == .one ? Array(ids.prefix(1)) : ids { perform(id, arguments, editor) }
                  })
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
    /// `editor.transact`. `argument` is the hint in the list, `@shape` unless a command says more. On
    /// one shape alone (`.one`): `SlashCommand.together` is the form for several.
    public init(_ name: String, argument: String = "@shape",
                when isOffered: @escaping @MainActor (Value) -> Bool = { _ in true },
                kinds: (@MainActor (Registry) -> Set<ShapeKind>)? = nil,
                shapes admits: @escaping @MainActor (_ target: ShapeID, _ owner: ShapeID, CanvasEditor) -> Bool,
                step: String? = nil,
                perform: @escaping @MainActor (ShapeID, SlashArguments, CanvasEditor) -> Void) {
        self.init(name: name, argument: argument, reach: .one, isOffered: isOffered, accepts: { $0.isOneShape },
                  shapes: { target, owners, editor in owners.count == 1 && admits(target, owners[0], editor) }, kinds: kinds,
                  step: step, action: .perform { ids, arguments, editor in ids.first.map { perform($0, arguments, editor) } })
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
    /// Return completes it rather than running it. On one shape alone (`.one`):
    /// `SlashCommand.together` is the form for several.
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
        let rows: @MainActor ([ShapeID], CanvasEditor) -> [SlashChoice] = { owners, editor in
            guard let owner = owners.first else { return [] }
            return choices(owner, editor)
        }
        var row: (@MainActor (String, [ShapeID], CanvasEditor) -> SlashChoice?)?
        if let otherwise {
            row = { typed, owners, editor in
                guard let owner = owners.first else { return nil }
                return otherwise(typed, owner, editor)
            }
        }
        let pick: @MainActor ([ShapeID], SlashChoice, CanvasEditor) -> Void = { ids, choice, editor in
            guard let id = ids.first else { return }
            perform(id, choice, editor)
        }
        self.init(name: name, argument: argument, reach: .one, isOffered: isOffered, accepts: { _ in false },
                  choices: rows, otherwise: row, step: step, action: .choose(pick))
    }

    /// A command a plugin declared (`registrar.command`), typed on a line of the shape's text or in the
    /// command bar: offered while it can act on the shapes it reaches (its rule, asked with them alone,
    /// `editor.canPerform(_:on:)`) and `when` holds of each one's value, and run on them, together, as a
    /// try (`editor.attempt`: the line is gone by then, and what was offered isn't asked again), in one
    /// undo step named as the command is (`registry.title(of:)`: `/public` is "Make Public"). It takes
    /// no arguments. `tries: true` offers it by `when` alone, so where the command can't act it runs all
    /// the same, which refuses, and the shape shakes, as a chip's click does (`/private` on a shape
    /// something stands for). The one form a read-only shape is offered, in the bar: its rule says
    /// whether it can act there (Unlock).
    ///
    ///     SlashCommand("lock", command: .lock)
    ///     SlashCommand("private", command: .makePrivate, when: { $0[PublicProperty.self] == true }, tries: true)
    public init(_ name: String, command: CanvasCommand, when isOffered: @escaping @MainActor (Value) -> Bool = { _ in true }, tries: Bool = false) {
        let run: @MainActor ([ShapeID], SlashArguments, CanvasEditor) -> Void = { ids, _, editor in editor.attempt(command, on: ids) }
        self.init(name: name, argument: nil, reach: .together, isOffered: isOffered, accepts: Self.defaultAccepts(takesArgument: false),
                  step: nil, action: .perform(run))
        self.command = command
        self.tries = tries
    }

    private static func defaultAccepts(takesArgument: Bool) -> @MainActor (SlashArguments) -> Bool {
        if takesArgument { return { !$0.isEmpty } }
        return { $0.isEmpty }
    }
}

// MARK: The plural forms

extension SlashCommand {
    /// For what must be done to several shapes as one: `perform` gets every shape the command acts on,
    /// in target order (a text's line, the one shape), what was typed and the editor, once, and changes
    /// the document only through `editor.transact`. A block moved together keeps where its shapes are
    /// to each other; nested frames turned together turn innermost first.
    ///
    ///     SlashCommand.together("turn-into-subboard") { ids, _, editor in editor.transforms?.turn(ids, into: kind) }
    public static func together(_ name: String, argument: String? = nil,
                                when isOffered: @escaping @MainActor (Value) -> Bool = { _ in true },
                                accepts: (@MainActor (SlashArguments) -> Bool)? = nil,
                                step: String? = nil,
                                perform: @escaping @MainActor ([ShapeID], SlashArguments, CanvasEditor) -> Void) -> SlashCommand {
        SlashCommand(name: name, argument: argument, reach: .together, isOffered: isOffered,
                     accepts: accepts ?? defaultAccepts(takesArgument: argument != nil), step: step, action: .perform(perform))
    }

    /// A command that takes one shape, as `init(_:argument:when:kinds:shapes:step:perform:)` is, for
    /// every shape it acts on at once: its rule is asked with the shape and all of them (`owners`), and
    /// `perform` gets them all, with what was typed (its `shapes` the one shape).
    ///
    ///     SlashCommand.together("move-to", kinds: { $0.containingKinds }, shapes: { target, owners, editor in … }) { owners, arguments, editor in … }
    public static func together(_ name: String, argument: String = "@shape",
                                when isOffered: @escaping @MainActor (Value) -> Bool = { _ in true },
                                kinds: (@MainActor (Registry) -> Set<ShapeKind>)? = nil,
                                shapes admits: @escaping @MainActor (_ target: ShapeID, _ owners: [ShapeID], CanvasEditor) -> Bool,
                                step: String? = nil,
                                perform: @escaping @MainActor ([ShapeID], SlashArguments, CanvasEditor) -> Void) -> SlashCommand {
        SlashCommand(name: name, argument: argument, reach: .together, isOffered: isOffered, accepts: { $0.isOneShape },
                     shapes: admits, kinds: kinds, step: step, action: .perform(perform))
    }

    /// A command that takes one choice, as `init(_:argument:when:choices:otherwise:step:perform:)` is,
    /// for every shape it acts on at once: its rows and its row for what was typed are made for all of
    /// them (`owners`), and a pick runs `perform` with them all.
    ///
    ///     SlashCommand.together("color", argument: "color", choices: { owners, editor in … }) { owners, choice, editor in … }
    public static func together(_ name: String, argument: String,
                                when isOffered: @escaping @MainActor (Value) -> Bool = { _ in true },
                                choices: @escaping @MainActor (_ owners: [ShapeID], CanvasEditor) -> [SlashChoice],
                                otherwise: (@MainActor (_ typed: String, _ owners: [ShapeID], CanvasEditor) -> SlashChoice?)? = nil,
                                step: String? = nil,
                                perform: @escaping @MainActor ([ShapeID], SlashChoice, CanvasEditor) -> Void) -> SlashCommand {
        SlashCommand(name: name, argument: argument, reach: .together, isOffered: isOffered, accepts: { _ in false },
                     choices: choices, otherwise: otherwise, step: step, action: .choose(perform))
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
/// object wherever it's found (a scope's, on every kind it reaches). Below this, nothing knows how many
/// shapes a form was written for: every closure takes the shapes the command acts on.
@MainActor
final class ErasedSlashCommand {
    let name: String
    let argument: String?
    /// How it acts on several shapes.
    let reach: SlashReach
    let isOffered: @MainActor (AnyShapeRecord) -> Bool
    let accepts: @MainActor (SlashArguments) -> Bool
    /// Which shapes it takes, for a command that takes one (`SlashCommand`'s `shapes`), given the shapes
    /// it acts on.
    let shapes: (@MainActor (_ target: ShapeID, _ owners: [ShapeID], CanvasEditor) -> Bool)?
    /// What its undo step is called, if not its name in words.
    let step: String?
    /// The most kinds it takes, for a command that names them (`SlashCommand`'s `kinds`), and what the
    /// registry said they were, kept by the first ask: the registry is frozen, and one command
    /// belongs to one registry.
    private let kindsOf: (@MainActor (Registry) -> Set<ShapeKind>)?
    private var kindsFound: Set<ShapeKind>?
    /// Runs it on the shapes it acts on, in target order: an edit on each one's value, in one
    /// transaction, or the command's own `perform`.
    let run: @MainActor ([ShapeID], SlashArguments, CanvasEditor) -> Void
    /// For a command that takes a choice: its rows, the row for nothing matching, and running a pick,
    /// each for the shapes it acts on.
    let choices: (@MainActor (_ owners: [ShapeID], CanvasEditor) -> [SlashChoice])?
    let otherwise: (@MainActor (_ typed: String, _ owners: [ShapeID], CanvasEditor) -> SlashChoice?)?
    let runChoice: (@MainActor ([ShapeID], SlashChoice, CanvasEditor) -> Void)?
    /// The command a plugin declared that it runs, if it was typed for one, and whether it's offered by
    /// its `when` alone (a try).
    let command: CanvasCommand?
    let tries: Bool
    /// For a command about the command bar's target as a whole (`SelectionSlashCommand`): which targets
    /// offer it, what it starts (a task the bar waits for) and what VoiceOver hears meanwhile, or what it
    /// runs at once; nil for a shape's command.
    let isOfferedFor: (@MainActor (SlashTarget, CanvasEditor) -> Bool)?
    let answer: (@MainActor (SlashTarget, SlashArguments, CanvasEditor) -> Task<SlashAnswer, Never>)?
    let waiting: String?
    let runAbout: (@MainActor (SlashTarget, SlashArguments, CanvasEditor) -> Void)?

    /// `read` gets the command's value from a record; `write` runs an edit on one shape's live
    /// value, in a transaction.
    init<Value>(_ command: SlashCommand<Value>, read: @escaping @MainActor (AnyShapeRecord) -> Value?,
                write: @escaping @MainActor (ShapeID, inout Transaction, (inout Value) -> Void) -> Void) {
        name = command.name
        argument = command.argument
        reach = command.reach
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
        isOfferedFor = nil
        answer = nil
        waiting = nil
        runAbout = nil
        switch command.action {
        case .edit(let edit):
            run = { ids, arguments, editor in
                editor.transact { transaction in
                    for id in ids { write(id, &transaction) { edit(&$0, arguments) } }
                }
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

    /// A command about the command bar's target as a whole: on every shape of it at once (`.together`),
    /// whatever each shape is, running nothing on them itself (the bar asks it for its task, `answer`, or
    /// runs it with the target, `runAbout`).
    init(_ command: SelectionSlashCommand) {
        name = command.name
        argument = command.argument
        reach = .together
        isOffered = { _ in true }
        accepts = command.accepts
        shapes = nil
        kindsOf = nil
        step = nil
        self.command = nil
        tries = false
        choices = nil
        otherwise = nil
        run = { _, _, _ in }
        runChoice = nil
        isOfferedFor = command.isOffered
        waiting = command.waiting
        switch command.action {
        case .answer(let answer):
            self.answer = answer
            runAbout = nil
        case .run(let run):
            answer = nil
            runAbout = run
        }
    }

    /// Whether it takes a shape or a choice: what a row merged from two kinds' own commands of one name
    /// can't (two rules, two lists of rows).
    var takesShapeOrChoice: Bool { shapes != nil || choices != nil }

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

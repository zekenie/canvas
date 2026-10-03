import Canvas

/// One command a shape offers, typed as `/name` on a line of its text, over `Value`: the kind's
/// props for a kind's own commands (`x.slashCommands { }`), an added property's value for its
/// commands (`x.slashCommands(of: P.self) { }`), or `AnyShapeRecord` for every shape's
/// (`slashCommandsForEveryShape { }`).
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
/// A name is the command's identity: two plugins offering one name to the same shapes are a
/// `conflict`, and a kind's own command takes the place of an every-shape one of the same name.
public struct SlashCommand<Value> {
    let name: String
    let argument: String?
    let isOffered: @MainActor (Value) -> Bool
    let accepts: @MainActor (SlashArguments) -> Bool
    let action: Action

    enum Action {
        case edit(@MainActor (inout Value, SlashArguments) -> Void)
        case perform(@MainActor (ShapeID, SlashArguments, CanvasEditor) -> Void)
    }

    /// Edits the shape the line is on: `edit` runs on its live value in one transaction. Setting what
    /// a shape already has commits nothing.
    public init(_ name: String, argument: String? = nil,
                when isOffered: @escaping @MainActor (Value) -> Bool = { _ in true },
                accepts: (@MainActor (SlashArguments) -> Bool)? = nil,
                edit: @escaping @MainActor (inout Value, SlashArguments) -> Void) {
        self.name = name
        self.argument = argument
        self.isOffered = isOffered
        self.accepts = accepts ?? Self.defaultAccepts(takesArgument: argument != nil)
        action = .edit(edit)
    }

    /// For what editing the shape can't do (locking it, moving it, putting it somewhere): `perform`
    /// gets the shape, what was typed and the editor, and changes the document only through
    /// `editor.transact`.
    public init(_ name: String, argument: String? = nil,
                when isOffered: @escaping @MainActor (Value) -> Bool = { _ in true },
                accepts: (@MainActor (SlashArguments) -> Bool)? = nil,
                perform: @escaping @MainActor (ShapeID, SlashArguments, CanvasEditor) -> Void) {
        self.name = name
        self.argument = argument
        self.isOffered = isOffered
        self.accepts = accepts ?? Self.defaultAccepts(takesArgument: argument != nil)
        action = .perform(perform)
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
    /// Runs it on a shape: the edit in one transaction, or the command's own `perform`.
    let run: @MainActor (ShapeID, SlashArguments, CanvasEditor) -> Void

    /// `read` gets the command's value from a record; `write` runs an edit on one shape's live
    /// value, in a transaction.
    init<Value>(_ command: SlashCommand<Value>, read: @escaping @MainActor (AnyShapeRecord) -> Value?,
                write: @escaping @MainActor (ShapeID, inout Transaction, (inout Value) -> Void) -> Void) {
        name = command.name
        argument = command.argument
        let offered = command.isOffered
        isOffered = { read($0).map(offered) ?? false }
        accepts = command.accepts
        switch command.action {
        case .edit(let edit):
            run = { id, arguments, editor in
                editor.transact { transaction in write(id, &transaction) { edit(&$0, arguments) } }
            }
        case .perform(let perform):
            run = perform
        }
    }
}

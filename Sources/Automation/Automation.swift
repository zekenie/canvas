import Canvas
import CanvasRPC
import Foundation

/// The command line, as a plugin: every command `canvas` runs on the app is registered here, by the
/// plugin that gives it its meaning, one plugin per name. A command is a name, what help says about
/// it, its params (a list of properties, `SchemaDefined`, whose schema `canvas` reads its arguments
/// by), and what it does, on the main actor, through transactions, as anything else changes a
/// board: at once (`run:`, as `draw` and `kinds` do) or, for one that waits on something (a
/// language model), later (`runAsync:`), its output then written off the main actor. The app's
/// command server takes them from the host's slot for them (HostSlots' `registry.hostCommands`,
/// which this plugin fills with `automationCommands` and `runAutomationCommand`), and does the
/// talking: this plugin never sees a socket, and the core never sees a command. Its own are `draw`, `show`, `kinds` and `measure` (Commands.swift, Measure.swift);
/// `draw` takes what it doesn't own (names, edges, checks) from the points in DrawPoints.swift,
/// which DrawLexicon fills (and AutomationTests with fixtures of their own).
extension PluginID {
    public static let automation: PluginID = "automation"
}

// MARK: The extension point

/// Every command the command line runs, keyed by name: two commands of one name are
/// `RegistryError.conflict` at startup.
public enum AutomationCommands {}

extension AutomationCommands: KeyedExtensionPoint {
    public typealias Contribution = AutomationCommand
    public static var owner: PluginID { .automation }

    public static func uniqueKeys(of command: AutomationCommand, for _: ShapeTarget) -> [AnyHashable] { [CommandKey(name: command.name)] }

    public static func summary(of command: AutomationCommand, for _: ShapeTarget) -> String { "command line \(command.name)" }

    /// Names the command line can type, params it can spell, and none it keeps for itself.
    public static func check(_ registry: Registry) throws(RegistryError) {
        for command in registry.contributions(to: AutomationCommands.self).map(\.value) {
            func refuse(_ reason: String) -> RegistryError { .invalid(point: "AutomationCommands", reason: "command \(command.name): \(reason)") }
            guard RPC.isValidCommandName(command.name) else {
                throw refuse("a name is words of lowercase letters, digits and hyphens, one space apart")
            }
            guard !RPC.reservedCommandNames.contains(command.name) else {
                throw refuse("the app answers that one itself, or \(RPC.commandName) does (\(RPC.reservedCommandNames.sorted().joined(separator: ", ")))")
            }
            let spec = command.spec
            let names = Set(spec.params["properties"]?.objectValue?.keys.map { $0 } ?? [])
            if let taken = names.intersection(RPC.globalOptions.union([RPC.boardParam])).sorted().first {
                throw refuse("a param can't be named \(taken), which \(RPC.commandName) keeps for itself")
            }
            if let missing = spec.positionals.first(where: { !names.contains($0) }) {
                throw refuse("positional \(missing) isn't one of its params")
            }
        }
    }
}

/// A name, as the key a command claims: "command draw" in a conflict.
struct CommandKey: Hashable, CustomStringConvertible {
    let name: String
    var description: String { "command \(name)" }
}

/// A command, as `AutomationCommands` stores it. Only the sugar below makes one.
public struct AutomationCommand {
    /// What the command line shows for it, and reads its arguments by: its name and scope too.
    public let spec: CommandSpec
    /// A command made with `run:` never suspends, so it answers in the turn it's asked in.
    let run: @MainActor (JSON, AutomationContext) async throws(AutomationError) -> JSON

    public var name: String { spec.name }

    /// A command's output as the wire's JSON, written off the main actor, where the output, handed
    /// over whole, is freed too: a large one costs the main actor neither its writing nor its
    /// freeing. A `JSON` output, written already, passes through as it is.
    @concurrent
    nonisolated static func encoded<Output: Encodable & Sendable>(_ output: consuming Output, command name: String) async throws(AutomationError) -> JSON {
        if let json = (copy output) as? JSON { return json }
        do {
            return try JSON(encoding: output)
        } catch {
            throw AutomationError("\(name)'s result couldn't be written as JSON: \(error)", reason: "internal")
        }
    }
}

/// What a command runs with: the app's registry, and the board it works on.
@MainActor
public struct AutomationContext {
    public let registry: Registry
    /// The board's editor: a board command's always, an app command's never.
    public let editor: CanvasEditor?

    public init(registry: Registry, editor: CanvasEditor?) {
        self.registry = registry
        self.editor = editor
    }

    /// The board's editor, for a board command.
    public func board() throws(AutomationError) -> CanvasEditor {
        guard let editor else { throw AutomationError("This command works on a board, and none was given.", reason: "no_board") }
        return editor
    }
}

/// Why a command didn't do what it was asked: said for a person, with a reason an agent can branch
/// on (`unknown_kind`) and a hint, often the command to run instead. A command that reads a script
/// or a query says where in it: the `line` (from 1), the `column` (from 1, in characters) and
/// `length` of what's wrong on it, and the `statement` as written there; and one that finds several
/// problems at once gives the first as itself and every one, the first too, in `errors`. Anything
/// else an agent can use (the query a model wrote) goes in `details`. The command line gets them
/// all in the error's data (`line`, `column`, `length`, `statement`, `details`' members beside them,
/// never under their names, and `errors`, each `{line, column, length, statement, reason, message,
/// hint}` and its details).
public struct AutomationError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public let reason: String
    public let hint: String?
    /// Whether the params were what's wrong, rather than what they asked for.
    public let isInvalidParams: Bool
    /// The line of the script it's about, from 1.
    public let line: Int?
    /// Where on that line what's wrong starts, from 1, in characters.
    public let column: Int?
    /// How many characters what's wrong takes from `column`.
    public let length: Int?
    /// That line as it's written (its comment left out, trimmed).
    public let statement: String?
    /// Every problem found, this one first; empty when it's the only one.
    public let errors: [AutomationError]
    /// More for the error's data, under names of the command's own: a detail under one of the
    /// error's (`hint`, `line`, `errors`, …) is left out, whether the error has that member or not.
    public let details: [String: JSON]

    public init(_ message: String, reason: String, hint: String? = nil, invalidParams: Bool = false,
                line: Int? = nil, column: Int? = nil, length: Int? = nil, statement: String? = nil, errors: [AutomationError] = [],
                details: [String: JSON] = [:]) {
        self.message = message
        self.reason = reason
        self.hint = hint
        isInvalidParams = invalidParams
        self.line = line
        self.column = column
        self.length = length
        self.statement = statement
        self.errors = errors
        self.details = details
    }

    public var description: String { message }

    var rpcError: RPCError {
        var data = located.merging(extra) { own, _ in own }
        if !errors.isEmpty {
            data["errors"] = .array(errors.map { error in
                var entry = error.located.merging(error.extra) { own, _ in own }
                entry["reason"] = .string(error.reason)
                entry["message"] = .string(error.message)
                if let hint = error.hint { entry["hint"] = .string(hint) }
                return .object(entry)
            })
        }
        return RPCError(isInvalidParams ? RPCError.invalidParams : RPCError.failed, reason: reason, message, hint: hint, details: data)
    }

    /// The names of its own members in the error's data, which are its own whether it has them or
    /// not: no detail stands in for a hint or a place it hasn't.
    private static let ownMembers: Set<String> = ["reason", "message", "hint", "line", "column", "length", "statement", "errors"]

    /// Its details, less any that would take one of its own members' names.
    private var extra: [String: JSON] { details.filter { !Self.ownMembers.contains($0.key) } }

    /// Where it is, as the error's data says it.
    private var located: [String: JSON] {
        var data: [String: JSON] = [:]
        if let line { data["line"] = .number(Double(line)) }
        if let column { data["column"] = .number(Double(column)) }
        if let length { data["length"] = .number(Double(length)) }
        if let statement { data["statement"] = .string(statement) }
        return data
    }
}

// MARK: Sugar (what plugins write)

extension PluginRegistrar {
    /// A command the command line runs: `canvas <name> …`. Its params are a list of properties
    /// (`Params.properties`), each an option (`Property("at", \.at)` is `--at`); those in
    /// `positionals` are also taken in order, without their names. The schema says what help says:
    /// each property's `description`, its default, what its value's called (`x-value-name`), and
    /// how long `canvas` waits for an answer when it's given (`x-timeout`, seconds). `run` gets them
    /// read and checked against their schema, and its output goes back as JSON, all in the turn
    /// it's asked in. A board command (the default) runs on the board `--board` names, or the one
    /// in front.
    public mutating func automationCommand<Params: SchemaDefined, Output: Encodable>(
        _ name: String, _ summary: String, discussion: String? = nil, scope: CommandScope = .board, params _: Params.Type = Params.self,
        positionals: [String] = [], examples: [CommandExample] = [],
        run: @escaping @MainActor (Params, AutomationContext) throws(AutomationError) -> Output
    ) {
        let reading = ParamsReading<Params>(command: name)
        contribute(AutomationCommand(
            spec: CommandSpec(name: name, summary: summary, discussion: discussion, scope: scope, params: reading.schema, positionals: positionals,
                              examples: examples),
            run: { json, context throws(AutomationError) in
                let output = try run(reading.params(from: json), context)
                do {
                    return try JSON(encoding: output)
                } catch {
                    throw AutomationError("\(name)'s result couldn't be written as JSON: \(error)", reason: "internal")
                }
            }), to: AutomationCommands.self)
    }

    /// A command that answers later: one that waits on something (a language model's answer)
    /// without holding the main actor meanwhile, so the app goes on, and other commands run. As
    /// `run:`'s, but `runAsync` may suspend, and its output is written as JSON off the main actor,
    /// where it's freed too, so a large one costs the main actor nothing; a `JSON` output (built
    /// off the main actor already) goes back as it is. If the request is cancelled (its client
    /// hung up, its board closed), the task running it is: a long wait should check
    /// (`Task.isCancelled`), and stop.
    public mutating func automationCommand<Params: SchemaDefined, Output: Encodable & Sendable>(
        _ name: String, _ summary: String, discussion: String? = nil, scope: CommandScope = .board, params _: Params.Type = Params.self,
        positionals: [String] = [], examples: [CommandExample] = [],
        runAsync: @escaping @MainActor (Params, AutomationContext) async throws(AutomationError) -> Output
    ) {
        let reading = ParamsReading<Params>(command: name)
        contribute(AutomationCommand(
            spec: CommandSpec(name: name, summary: summary, discussion: discussion, scope: scope, params: reading.schema, positionals: positionals,
                              examples: examples),
            run: { json, context async throws(AutomationError) in
                let output = try await runAsync(reading.params(from: json), context)
                return try await AutomationCommand.encoded(consume output, command: name)
            }), to: AutomationCommands.self)
    }
}

/// A command's params as the request sends them, checked against their schema and decoded.
private struct ParamsReading<Params: SchemaDefined> {
    let command: String
    let schema = JSON(Params.jsonSchema.json)
    let validator = SchemaValidator(Params.jsonSchema)

    init(command: String) {
        self.command = command
    }

    func params(from json: JSON) throws(AutomationError) -> Params {
        if let violation = validator.violations(of: JSONValue(json)).first {
            throw AutomationError("\(RPC.commandName) \(command): \(violation.message)", reason: "invalid_params",
                                  hint: "`\(RPC.commandName) help \(command)` says what it takes.", invalidParams: true)
        }
        do {
            return try json.decode(Params.self)
        } catch {
            throw AutomationError("\(RPC.commandName) \(command): \(error)", reason: "invalid_params", invalidParams: true)
        }
    }
}

// MARK: Reading them (what the plugin hands the app's command server)

extension Registry {
    /// Every command the command line runs, in plugin order, as the command line reads them.
    public var automationCommands: [CommandSpec] {
        contributions(to: AutomationCommands.self).map(\.value.spec)
    }

    /// Runs a command, by name, with its params as the command line sent them (a board command's
    /// `board` already taken out, and its board's editor in `editor`). A command made with `run:`
    /// answers without suspending; one made with `runAsync:` when it's done, the main actor free
    /// meanwhile.
    public func runAutomationCommand(_ name: String, params: JSON, editor: CanvasEditor?) async throws(RPCError) -> JSON {
        guard let command = contributions(to: AutomationCommands.self).first(where: { $0.value.name == name })?.value else {
            throw RPCError(RPCError.methodNotFound, reason: "unknown_command", "There's no command \(name).",
                           hint: "`\(RPC.commandName) help` lists the commands.")
        }
        do {
            return try await command.run(params, AutomationContext(registry: self, editor: editor))
        } catch {
            throw error.rpcError
        }
    }
}

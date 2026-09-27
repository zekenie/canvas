import Canvas
import CanvasRPC
import Foundation

/// The command line, as a plugin: every command `canvas` runs on the app is registered here, by the
/// plugin that gives it its meaning, one plugin per name. A command is a name, what help says about
/// it, its params (a list of properties, `SchemaDefined`, whose schema `canvas` reads its arguments
/// by), and what it does, on the main actor, through transactions, as anything else changes a
/// board. The app hands them to its command server (Composition's `commandSpecs(in:)` and
/// `runCommand`), which does the talking: this plugin never sees a socket, and the core never sees
/// a command.
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

/// A name, as the key a command claims: "command create" in a conflict.
struct CommandKey: Hashable, CustomStringConvertible {
    let name: String
    var description: String { "command \(name)" }
}

/// A command, as `AutomationCommands` stores it. Only the sugar below makes one.
public struct AutomationCommand {
    /// What the command line shows for it, and reads its arguments by: its name and scope too.
    public let spec: CommandSpec
    let run: @MainActor (JSON, AutomationContext) throws(AutomationError) -> JSON

    public var name: String { spec.name }
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
/// on (`unknown_kind`) and a hint, often the command to run instead.
public struct AutomationError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public let reason: String
    public let hint: String?
    /// Whether the params were what's wrong, rather than what they asked for.
    public let isInvalidParams: Bool

    public init(_ message: String, reason: String, hint: String? = nil, invalidParams: Bool = false) {
        self.message = message
        self.reason = reason
        self.hint = hint
        isInvalidParams = invalidParams
    }

    public var description: String { message }

    var rpcError: RPCError {
        isInvalidParams ? .invalidParams(message, reason: reason, hint: hint) : .failed(message, reason: reason, hint: hint)
    }
}

// MARK: Sugar (what plugins write)

extension PluginRegistrar {
    /// A command the command line runs: `canvas <name> …`. Its params are a list of properties
    /// (`Params.properties`), each an option (`Property("at", \.at)` is `--at`); those in
    /// `positionals` are also taken in order, without their names. The schema says what help says:
    /// each property's `description`, its default, and what its value's called (`x-value-name`).
    /// `run` gets them read and checked against their schema, and its output goes back as JSON.
    /// A board command (the default) runs on the board `--board` names, or the one in front.
    public mutating func automationCommand<Params: SchemaDefined, Output: Encodable>(
        _ name: String, _ summary: String, discussion: String? = nil, scope: CommandScope = .board, params _: Params.Type = Params.self,
        positionals: [String] = [], examples: [CommandExample] = [],
        run: @escaping @MainActor (Params, AutomationContext) throws(AutomationError) -> Output
    ) {
        let schema = JSON(Params.jsonSchema.json)
        let validator = SchemaValidator(Params.jsonSchema)
        contribute(AutomationCommand(
            spec: CommandSpec(name: name, summary: summary, discussion: discussion, scope: scope, params: schema, positionals: positionals,
                              examples: examples),
            run: { json, context throws(AutomationError) in
                let value = JSONValue(json)
                if let violation = validator.violations(of: value).first {
                    throw AutomationError("\(RPC.commandName) \(name): \(violation.message)", reason: "invalid_params",
                                          hint: "`\(RPC.commandName) help \(name)` says what it takes.", invalidParams: true)
                }
                let params: Params
                do {
                    params = try json.decode(Params.self)
                } catch {
                    throw AutomationError("\(RPC.commandName) \(name): \(error)", reason: "invalid_params", invalidParams: true)
                }
                let output = try run(params, context)
                do {
                    return try JSON(encoding: output)
                } catch {
                    throw AutomationError("\(name)'s result couldn't be written as JSON: \(error)", reason: "internal")
                }
            }), to: AutomationCommands.self)
    }
}

// MARK: Reading them (what the app's command server uses)

extension Registry {
    /// Every command the command line runs, in plugin order, as the command line reads them.
    public var automationCommands: [CommandSpec] {
        contributions(to: AutomationCommands.self).map(\.value.spec)
    }

    /// Runs a command, by name, with its params as the command line sent them (a board command's
    /// `board` already taken out, and its board's editor in `editor`).
    public func runAutomationCommand(_ name: String, params: JSON, editor: CanvasEditor?) throws(RPCError) -> JSON {
        guard let command = contributions(to: AutomationCommands.self).first(where: { $0.value.name == name })?.value else {
            throw RPCError(RPCError.methodNotFound, reason: "unknown_command", "There's no command \(name).",
                           hint: "`\(RPC.commandName) help` lists the commands.")
        }
        do {
            return try command.run(params, AutomationContext(registry: self, editor: editor))
        } catch {
            throw error.rpcError
        }
    }
}

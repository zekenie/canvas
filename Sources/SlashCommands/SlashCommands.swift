import Canvas

/// Slash commands, as a plugin: a `/` typed at the start of a new line of a shape's text lists the
/// commands that shape offers; a line that is `/name` and what the command takes, entered with
/// Return, runs the command and goes, leaving only what the command did. Contributed the way
/// context menu items are: by a kind, by horizontals it opts into, by other plugins for that kind,
/// and by any plugin for the kinds a scope reaches (`registrar.forShapes(holding:)`), each command
/// offered when its `when` says so. The core never
/// learns what a command is. A text view takes part by hosting `SlashCommandTyping` (Mentions' does,
/// for every text where mentions are typed). Where a shape offers no command, a slash is a slash.
extension PluginID {
    public static let slashCommands: PluginID = "slash-commands"
}

// MARK: The extension point

/// Slash commands: what each kind's shapes offer, and what the shapes of the kinds a scope reaches
/// offer (`registrar.forShapes(holding:)`, `forShapes(adopting:)`, `forEveryShape`: a command for
/// every kind with no scope is refused). Keyed by name: each command claims its target and name, so
/// two plugins offering one name to a kind, or two scopes that reach one kind, are
/// `RegistryError.conflict` at startup. A kind's own command replaces a scope's of the same name. A
/// name that can't be typed as one (`SlashCommandLine.isName`) refuses the plugin list.
public enum ShapeSlashCommands {}

/// A kit switches its plugins' commands: while a plugin's kit is off in a file, `/` lists none of its commands
/// there, in a shape's text or the command bar, and none runs.
extension ShapeSlashCommands: KitSwitched {}

extension ShapeSlashCommands: KeyedExtensionPoint {
    public typealias Contribution = SlashCommandContribution
    public static var owner: PluginID { .slashCommands }
    public static var scope: PointScope { .scoped }

    public static func uniqueKeys(of contribution: SlashCommandContribution, for target: ShapeTarget) -> [AnyHashable] {
        contribution.commands.map { SlashCommandKey(target: target, name: $0.name) }
    }

    /// "/flip /grow → box", "/lock → every shape holding locked".
    public static func summary(of contribution: SlashCommandContribution, for target: ShapeTarget) -> String {
        contribution.commands.map { "/\($0.name)" }.joined(separator: " ") + " → \(target)"
    }

    public static func check(_ registry: Registry) throws(RegistryError) {
        for contributed in registry.contributions(to: ShapeSlashCommands.self) {
            for command in contributed.value.commands where !SlashCommandLine.isName(command.name) {
                throw .invalid(point: "ShapeSlashCommands", reason: "\(contributed.pluginID) offers /\(command.name), which can't be typed as a command's name: "
                               + "lowercase letters and digits, words joined by hyphens")
            }
        }
    }
}

/// What a contribution claims: "box /flip", "every shape holding locked /lock".
struct SlashCommandKey: Hashable, CustomStringConvertible {
    let target: ShapeTarget
    let name: String
    var description: String { "\(target) /\(name)" }
}

/// What `ShapeSlashCommands` stores: one plugin's commands for one target, erased. Only the sugar
/// below makes one.
@MainActor
public struct SlashCommandContribution {
    let commands: [ErasedSlashCommand]
}

extension SlashCommandContribution {
    /// A kind's commands, typed as its props.
    init<P: ShapeProps>(_: P.Type, _ commands: [SlashCommand<P>]) {
        self.commands = commands.map {
            ErasedSlashCommand($0, read: { $0.typed(as: P.self)?.props }, write: { id, transaction, edit in
                transaction.update(id, as: P.self) { edit(&$0.props) }
            })
        }
    }

    /// An added property's commands, over its value, on the shapes that have one.
    init<P: ShapeProperty>(property _: P.Type, _ commands: [SlashCommand<P.Value>]) {
        self.commands = commands.map {
            ErasedSlashCommand($0, read: { $0[P.self] }, write: { id, transaction, edit in
                transaction.update(id) { record in
                    guard var value = record[P.self] else { return }
                    edit(&value)
                    record[P.self] = value
                }
            })
        }
    }

    /// Commands over the record, for the kinds a scope reaches.
    init(everyShape commands: [SlashCommand<AnyShapeRecord>]) {
        self.commands = commands.map {
            ErasedSlashCommand($0, read: { $0 }, write: { id, transaction, edit in transaction.update(id) { edit(&$0) } })
        }
    }
}

// MARK: Sugar (what verticals and horizontals write)

extension ShapeRegistrar {
    /// This kind's commands, in one call (one contribution, one report line):
    ///
    ///     lamp.slashCommands {
    ///         SlashCommand("turn-on", when: { !$0.isOn }) { lamp, _ in lamp.isOn = true }
    ///         SlashCommand("level", argument: "1-3") { lamp, arguments in lamp.level = Int(arguments.text) ?? lamp.level }
    ///     }
    ///
    /// A horizontal's opt-in sugar may call this too, so opting into its feature brings its commands.
    public mutating func slashCommands(@SlashCommandBuilder<Definition.Props> _ commands: () -> [SlashCommand<Definition.Props>]) {
        contribute(SlashCommandContribution(Definition.Props.self, commands()), to: ShapeSlashCommands.self)
    }

    /// Commands over an added property's value, on this kind's shapes that have one: what a
    /// horizontal's opt-in sugar contributes for the property it opts the kind into.
    public mutating func slashCommands<P: ShapeProperty>(of _: P.Type, @SlashCommandBuilder<P.Value> _ commands: () -> [SlashCommand<P.Value>]) {
        contribute(SlashCommandContribution(property: P.self, commands()), to: ShapeSlashCommands.self)
    }
}

extension PluginRegistrar {
    /// Commands for a kind another plugin registers. Typed as the kind's own.
    public mutating func slashCommands<P: ShapeProps>(_: P.Type, @SlashCommandBuilder<P> _ commands: () -> [SlashCommand<P>]) {
        contribute(SlashCommandContribution(P.self, commands()), to: ShapeSlashCommands.self, for: .kind(P.kind))
    }

    /// Commands over an added property's value, on the shapes of every kind that holds it, whatever
    /// its kind: the report says "every shape holding <key>".
    public mutating func slashCommands<P: ShapeProperty>(of _: P.Type, @SlashCommandBuilder<P.Value> _ commands: () -> [SlashCommand<P.Value>]) {
        contribute(SlashCommandContribution(property: P.self, commands()), to: ShapeSlashCommands.self, for: .holding(P.key))
    }
}

extension ScopedRegistrar {
    /// Commands over the record, on the shapes of the kinds the scope reaches; `when` picks shapes.
    /// They come after a kind's own, in plugin order:
    ///
    ///     registrar.forShapes(holding: LockedProperty.self) { lock in
    ///         lock.slashCommands { SlashCommand("lock", command: .lock) }
    ///     }
    public mutating func slashCommands(@SlashCommandBuilder<AnyShapeRecord> _ commands: () -> [SlashCommand<AnyShapeRecord>]) {
        contribute(SlashCommandContribution(everyShape: commands()), to: ShapeSlashCommands.self)
    }
}

// MARK: The plugin

/// Makes the service that says what a shape offers and runs it. It contributes no command and
/// claims no key: the plugins that offer commands (Titles' `/title`, Locking's `/lock`) are the
/// ones that give a text view a list to open at a slash.
public struct SlashCommandsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .slashCommands }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { SlashCommandState(editor: $0) }
        registrar.keyHint("/ at a Line's Start", "Run a Command", while: .text)
    }
}

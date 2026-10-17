import Foundation

/// What the app and its command line (`canvas`) agree on, beyond JSON-RPC.
public enum RPC {
    /// Bumped when a message changes shape in a way the other side would misread. The command line
    /// refuses an app that speaks another version. 2: a text param may be read from standard input
    /// (`x-stdin`), and an error's data may say where in a script it is (`line`, `statement`,
    /// `errors`). What an older reader passes over keeps the version: a param's `x-timeout` (an
    /// older `canvas` waits its usual time, and says `timed_out`), a param's `x-path` (an older
    /// `canvas` sends a file as typed, which the app refuses unless it's whole), an error's `column`
    /// and `length`, a command's `boardOptional`, the app's `build` (`AppInfo.build`).
    public static let protocolVersion = 2
    /// What the command line is called: in help, and in the examples commands give.
    public static let commandName = "canvas"
    /// The method that describes the app and every command it runs (`AppDescription`). Not a
    /// command: `canvas` asks it before running any.
    public static let describeMethod = "describe"
    /// The commands every app that speaks this protocol answers itself, about the app as a whole:
    /// whether it's running, which boards it has open, and a new board's file, made and opened.
    public static let statusCommand = "status"
    public static let boardsCommand = "boards"
    public static let newCommand = "new"
    /// The command line's own, which never asks the app: it puts the skills the app carries where agents
    /// read them (`canvas install`).
    public static let installCommand = "install"
    /// Names no plugin's command may take: the protocol's own, the app's own, and the command line's
    /// `help`.
    public static let reservedCommandNames: Set<String> = [describeMethod, statusCommand, boardsCommand, newCommand, installCommand, "help"]
    /// The param a board command's board is named by (`--board`); the app takes it out before the
    /// command sees its params. No command may declare a param of this name.
    public static let boardParam = "board"
    /// The command line's own options, which it reads wherever they are; no command may declare a
    /// param of these names either.
    public static let globalOptions: Set<String> = ["socket", "format", "timeout", "help", "version"]

    /// Whether `name` can name a command: words of lowercase letters, digits and hyphens, each
    /// starting with a letter, one space between them ("draw", "board list").
    public static func isValidCommandName(_ name: String) -> Bool {
        let words = name.split(separator: " ", omittingEmptySubsequences: false)
        return !words.isEmpty && words.allSatisfy { word in
            guard let first = word.first, first.isASCII, first.isLowercase else { return false }
            return word.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
        }
    }
}

/// Where a command runs: on the app as a whole (`canvas boards`), or on one board, which the
/// request names with `board` (`--board`), and is otherwise the one in front.
public enum CommandScope: String, Codable, Sendable {
    case app
    case board
}

/// A command, as the app describes it to the command line, which makes its arguments and help from
/// this: its params are a JSON Schema object (draft 2020-12), each property an option
/// (`--name value`, `fooBar` spelled `--foo-bar`), those in `positionals` also taken in that order
/// without their names. Help calls a value what its property's `x-value-name` says, if anything.
public struct CommandSpec: Codable, Equatable, Sendable {
    /// Its words, one space apart: what's typed after `canvas`, and the request's method.
    public var name: String
    /// One line.
    public var summary: String
    /// What else help says: paragraphs, a blank line between them.
    public var discussion: String?
    public var scope: CommandScope
    /// For a board command that works with no board too (`measure`): `--board` is optional, and with none named and
    /// none in front, the command runs on none. Present only when true: an older reader passes over it.
    public var boardOptional: Bool?
    /// A JSON Schema object: `properties`, `required`, and the `$defs` they refer to.
    public var params: JSON
    public var positionals: [String]
    public var examples: [CommandExample]

    public init(name: String, summary: String, discussion: String? = nil, scope: CommandScope, boardOptional: Bool = false,
                params: JSON = ["type": "object"], positionals: [String] = [], examples: [CommandExample] = []) {
        self.name = name
        self.summary = summary
        self.discussion = discussion
        self.scope = scope
        self.boardOptional = boardOptional ? true : nil
        self.params = params
        self.positionals = positionals
        self.examples = examples
    }
}

/// A command line that uses a command, and what it does.
public struct CommandExample: Codable, Equatable, Sendable {
    /// As typed: `canvas draw --dry-run -`.
    public var command: String
    public var summary: String

    public init(_ command: String, _ summary: String) {
        self.command = command
        self.summary = summary
    }
}

/// What `describe` returns: which app this is, the protocol it speaks, and every command it runs.
public struct AppDescription: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var app: AppInfo
    public var commands: [CommandSpec]

    public init(protocolVersion: Int = RPC.protocolVersion, app: AppInfo, commands: [CommandSpec]) {
        self.protocolVersion = protocolVersion
        self.app = app
        self.commands = commands
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case app, commands
    }

    /// The command `words` name, and its arguments: the words around its name. The name comes first,
    /// or after options only (`--board 2 draw -`: an option, or a word after one); of names
    /// that start at one word, the longest (`board list` over `board`).
    public func command(in words: [String]) -> (command: CommandSpec, rest: [String])? {
        for start in words.indices {
            if start > 0 {
                let word = words[start - 1], before = start > 1 ? words[start - 2] : ""
                // Only options, and their values, before the name.
                guard word.hasPrefix("-") || (before.hasPrefix("--") && !before.contains("=")) else { return nil }
            }
            var best: (command: CommandSpec, length: Int)?
            for command in commands {
                let name = command.name.split(separator: " ").map(String.init)
                guard start + name.count <= words.count, Array(words[start..<(start + name.count)]) == name,
                      name.count > (best?.length ?? 0) else { continue }
                best = (command, name.count)
            }
            if let best { return (best.command, Array(words[..<start]) + Array(words[(start + best.length)...])) }
        }
        return nil
    }
}

public struct AppInfo: Codable, Equatable, Sendable {
    public var name: String
    public var version: String
    public var pid: Int
    /// The app's bundle, whose `canvas` speaks its protocol.
    public var path: String?
    /// Which build the app is (the commit it was built from, and whether the tree had changes): the
    /// skills the app carries for agents say the same, so a copy of them left behind by an update is told
    /// from the app's. Nil for an app that doesn't say (an older one, or one that isn't built as an app).
    public var build: String?

    public init(name: String, version: String, pid: Int, path: String? = nil, build: String? = nil) {
        self.name = name
        self.version = version
        self.pid = pid
        self.path = path
        self.build = build
    }
}

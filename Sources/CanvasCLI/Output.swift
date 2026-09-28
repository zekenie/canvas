import CanvasRPC
import Foundation

extension Invocation {
    /// What `canvas` and `canvas help` print: how it works, the app's commands (when it can reach
    /// the app), the options every command takes, and what its exit status says.
    func generalHelp(app: AppDescription?, problem: String?) -> String {
        let name = RPC.commandName
        var sections = [Help.wrap("\(name) works on the boards open in Infinite Canvas: it asks the app, which must be running, to run a "
            + "command, and prints what the app says. The commands are the app's, so they're always the ones the app has.", width: Help.width)]
        sections.append("Usage: \(name) <command> [<arguments>] [<options>]\n       \(name) help [<command>]")
        if let app {
            sections.append("Commands:\n" + app.commandList)
        } else {
            sections.append(Help.wrap("Its commands can't be listed: \(problem ?? "the app can't be reached"). Open the app, and run `\(name) help` again.",
                                      width: Help.width))
        }
        sections.append("Options for every command:\n" + Help.table([
            ("--format <json|text>", "How results are printed: JSON (the default when the output isn't a terminal) or text. CANVAS_FORMAT sets it too. "
                + "Help is text, unless --format json asks for what the app says about its commands, their params' JSON Schema too."),
            ("--socket <path>", "Where the app listens. Default: \(SocketPath.environmentKey) if set, else \(SocketPath.defaultPath(home: "~"))."),
            ("--timeout <seconds>", "How long to wait for the app to answer. Default: 10."),
            ("-h, --help", "This help, or a command's (`\(name) help <command>`)."),
            ("--version", "\(name)'s version: the protocol it speaks."),
        ]))
        sections.append(Help.wrap("A command that works on a board takes --board, its id (`\(name) boards`), file or name, and "
            + "otherwise works on the board in front.", width: Help.width))
        sections.append(Help.wrap("Results go to standard output, and errors to standard error, with a hint when there is one.", width: Help.width))
        sections.append("Exit status:\n" + Help.table([
            ("0", "Done."),
            ("1", "The app couldn't do it: the error says why."),
            ("2", "The command line is wrong: no such command or option, or a value that isn't one."),
            ("3", "The app couldn't be reached: it isn't running, didn't answer, or speaks another protocol."),
        ]))
        return sections.joined(separator: "\n\n")
    }
}

/// A result, as text for people: an object's members as `name: value` lines, a list of objects as a
/// table (what a row has that isn't a value, a kind's attributes, indented under it), and anything
/// nested indented under its name. JSON (`--format json`) has it all, as it's sent.
enum TextOutput {
    /// Members that lead, in this order; the rest follow by name. A script's changes lead with
    /// where each was written and what it did (no other result has `line` or `did`).
    static let leading = ["line", "did", "id", "name", "kind"]
    /// Members that are sentences, which a table never cuts (a warning's message ends with what to
    /// do about it, and a kind's `why` says why a script can't draw it): its last columns.
    static let sentences = ["message", "hint", "why"]
    /// The most characters a table's cell shows, but for sentences.
    static let cellLimit = 60

    static func render(_ json: JSON) -> String {
        render(json, indent: 0)
    }

    private static func render(_ json: JSON, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        switch json {
        case .object(let object):
            let keys = ordered(object.keys)
            let width = keys.filter { isInline(object[$0]!) }.map(\.count).max() ?? 0
            return keys.map { key in
                let value = object[key]!
                if isInline(value) { return pad + "\(key):".padding(toLength: width + 2, withPad: " ", startingAt: 0) + cell(value, limit: nil) }
                return pad + "\(key):\n" + render(value, indent: indent + 2)
            }.joined(separator: "\n")
        case .array(let items) where !items.isEmpty && items.allSatisfy({ $0.objectValue != nil }):
            return table(items.compactMap(\.objectValue), indent: indent)
        case .array(let items):
            return items.map { pad + (isInline($0) ? cell($0, limit: nil) : render($0, indent: indent + 2)) }.joined(separator: "\n")
        default:
            return pad + cell(json, limit: nil)
        }
    }

    /// Rows of objects, a column for each member that's a value or a list of values, sentences last
    /// and whole; members that are more (a kind's attributes, a schema) go under their row,
    /// indented, as an object's members do.
    private static func table(_ rows: [[String: JSON]], indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        var columns: [String] = []
        for key in ordered(Set(rows.flatMap(\.keys))) where rows.allSatisfy({ $0[key].map(isInline) ?? true }) { columns.append(key) }
        columns = columns.filter { !sentences.contains($0) } + sentences.filter(columns.contains)
        let cells = rows.map { row in
            columns.map { key in row[key].map { cell($0, limit: sentences.contains(key) ? nil : cellLimit) } ?? "" }
        }
        let widths = columns.indices.map { column in max(columns[column].count, cells.map { $0[column].count }.max() ?? 0) }
        func line(_ values: [String]) -> String {
            pad + zip(values, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }.joined(separator: "  ")
                .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        var lines = [line(columns)]
        for (row, values) in zip(rows, cells) {
            lines.append(line(values))
            let more = row.filter { !columns.contains($0.key) }
            if !more.isEmpty { lines.append(render(.object(more), indent: indent + 2)) }
        }
        return lines.joined(separator: "\n")
    }

    private static func ordered(_ keys: some Collection<String>) -> [String] {
        leading.filter(keys.contains) + keys.filter { !leading.contains($0) }.sorted()
    }

    /// Whether a value fits on its line: anything but an object, or a list with an object in it.
    private static func isInline(_ json: JSON) -> Bool {
        switch json {
        case .object: false
        case .array(let items): items.allSatisfy { $0.objectValue == nil && $0.arrayValue?.contains { $0.objectValue != nil } != true }
        default: true
        }
    }

    private static func cell(_ json: JSON, limit: Int?) -> String {
        let text: String = switch json {
        case .null: "-"
        case .bool(let bool): bool ? "yes" : "no"
        case .number(let number): format(number)
        case .string(let string): string
        case .array(let items): items.map { $0.arrayValue == nil ? cell($0, limit: nil) : "[\(cell($0, limit: nil))]" }.joined(separator: ", ")
        case .object: json.compactText
        }
        guard let limit, text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    /// A whole number without a decimal point.
    static func format(_ number: Double) -> String {
        if number.rounded() == number, abs(number) < 1e15 { return String(Int(number)) }
        return String(number)
    }
}

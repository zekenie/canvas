import Foundation

// Help, made from what the app says about each command, so it's always this app's.

extension CommandSpec {
    /// One line: `canvas create <kind> [--at <x,y>] … [--board <board>]`.
    public func usage(program: String = RPC.commandName) -> String {
        let parts = arguments.map { argument -> String in
            let value = argument.value == .flag ? "" : " <\(argument.valueName)>"
            let text = argument.isPositional ? "<\(argument.valueName)>" : "\(argument.option)\(value)"
            let repeated = argument.value.isRepeatable ? "..." : ""
            return argument.isRequired ? text + repeated : "[\(text)]\(repeated)"
        }
        return ([program, name] + parts).joined(separator: " ")
    }

    /// Everything the command line says about a command: what it does, its usage, its arguments and
    /// options, and examples.
    public func help(program: String = RPC.commandName) -> String {
        var sections = ["\(summary)\n\nUsage: \(usage(program: program))"]
        if let discussion, !discussion.isEmpty { sections.append(Help.wrap(discussion, width: Help.width)) }
        let all = arguments
        let positional = all.filter(\.isPositional), options = all.filter { !$0.isPositional }
        func rows(_ arguments: [CommandArgument], positional: Bool) -> [(String, String)] {
            arguments.map { argument in
                let value = argument.value == .flag ? "" : " <\(argument.valueName)>"
                let label = positional ? "<\(argument.valueName)>" : "\(argument.option)\(value)"
                var text = argument.summary ?? ""
                if case .text(let choices?) = argument.value, choices.count > 4 { text += " One of: \(choices.joined(separator: ", "))." }
                if argument.value.isRepeatable { text += " Repeatable." }
                if argument.isRequired, !positional { text += " Required." }
                if let value = argument.defaultValue, value != .null, value != .array([]) { text += " Default: \(value.compactText)." }
                return (label, text.trimmingCharacters(in: .whitespaces))
            }
        }
        if !positional.isEmpty { sections.append("Arguments:\n" + Help.table(rows(positional, positional: true))) }
        if !options.isEmpty { sections.append("Options:\n" + Help.table(rows(options, positional: false))) }
        if !examples.isEmpty {
            sections.append("Examples:\n" + examples.map { "  \($0.command)\n" + Help.wrap($0.summary, width: Help.width, indent: 6) }
                .joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }
}

extension AppDescription {
    /// A line for each command: its name and summary.
    public var commandList: String {
        Help.table(commands.map { ($0.name, $0.summary) })
    }
}

/// Laying out help text.
public enum Help {
    /// Where help wraps its lines.
    public static let width = 100

    /// Two columns, the second wrapped under itself.
    public static func table(_ rows: [(String, String)], indent: Int = 2) -> String {
        let column = min(max(rows.map(\.0.count).max() ?? 0, 8) + 2, 32)
        return rows.map { label, text in
            let lead = String(repeating: " ", count: indent) + label
            let wrapped = wrap(text, width: width, indent: indent + column)
            guard !text.isEmpty else { return lead }
            if lead.count + 1 < indent + column {
                return lead.padding(toLength: indent + column, withPad: " ", startingAt: 0) + wrapped.dropFirst(indent + column)
            }
            return lead + "\n" + wrapped
        }.joined(separator: "\n")
    }

    /// Words wrapped to `width` columns, each line indented; blank lines between paragraphs kept.
    public static func wrap(_ text: String, width: Int, indent: Int = 0) -> String {
        let pad = String(repeating: " ", count: indent)
        return text.components(separatedBy: "\n\n").map { paragraph in
            var lines: [String] = [], line = ""
            for word in paragraph.split(whereSeparator: \.isWhitespace) {
                if !line.isEmpty, indent + line.count + 1 + word.count > width {
                    lines.append(pad + line)
                    line = ""
                }
                line += (line.isEmpty ? "" : " ") + word
            }
            if !line.isEmpty { lines.append(pad + line) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

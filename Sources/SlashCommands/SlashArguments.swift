import Canvas

/// What's typed on a command's line after its name: text, and the shapes it names (a mention
/// text's pills), in order. A command gets it whole and reads what it needs, so one that takes a
/// title reads `text` and one that takes a shape reads `shapes`. It's kept as it's normalized:
/// adjacent text runs merged, empty ones gone, and whitespace trimmed at both ends. Whitespace
/// between runs stays ("near @Groceries" is `.text("near ")` and a shape).
public struct SlashArguments: Equatable, Sendable, ExpressibleByStringLiteral {
    public enum Run: Equatable, Sendable {
        case text(String)
        /// A shape the text names, and the name it shows.
        case shape(ShapeID, label: String)
    }

    public let runs: [Run]

    public init(_ runs: [Run]) {
        self.runs = Self.normalized(runs)
    }

    /// Plain text.
    public init(_ text: String) {
        self.init([.text(text)])
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    /// Nothing was typed: no runs once trimmed.
    public var isEmpty: Bool { runs.isEmpty }

    /// As text, each shape "@" and the name it shows: "near @Groceries".
    public var text: String {
        runs.map { run in
            switch run {
            case .text(let text): text
            case .shape(_, let label): "@" + label
            }
        }.joined()
    }

    /// Exactly one shape and nothing else, not even text: what a command that takes one shape is given.
    var isOneShape: Bool {
        if runs.count == 1, case .shape = runs[0] { true } else { false }
    }

    /// The shapes named, in order, each once.
    public var shapes: [ShapeID] {
        var seen = Set<ShapeID>()
        return runs.compactMap { run in
            guard case .shape(let id, _) = run, seen.insert(id).inserted else { return nil }
            return id
        }
    }

    private static func normalized(_ runs: [Run]) -> [Run] {
        var merged: [Run] = []
        for run in runs {
            if case .text(let text) = run {
                guard !text.isEmpty else { continue }
                if case .text(let before)? = merged.last { merged[merged.count - 1] = .text(before + text) } else { merged.append(run) }
            } else {
                merged.append(run)
            }
        }
        if case .text(let text)? = merged.first {
            let trimmed = String(text.drop { $0.isWhitespace })
            if trimmed.isEmpty { merged.removeFirst() } else { merged[0] = .text(trimmed) }
        }
        if case .text(let text)? = merged.last {
            var trimmed = Substring(text)
            while trimmed.last?.isWhitespace == true { trimmed.removeLast() }
            if trimmed.isEmpty { merged.removeLast() } else { merged[merged.count - 1] = .text(String(trimmed)) }
        }
        return merged
    }
}

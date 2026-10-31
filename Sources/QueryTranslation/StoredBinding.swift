import Foundation

/// What a stored query is bound to: the shapes it is run for, one at a time, each as `:scope` (a rule's chip: the shapes
/// of the type the rule is on, `:scope-start` and `:scope-end` an arrow's ends). What the model is told of them, so it
/// writes the query from the shape checked.
public struct StoredBinding: Hashable, Sendable {
    /// The type whose shapes the query is run for, by its title.
    public var type: String
    /// What those shapes are, plural, as a person says it: "notes", "arrows".
    public var shapes: String
    /// Whether they are connections with ends (arrows): `:scope-start` and `:scope-end` are theirs.
    public var connections: Bool

    public init(type: String, shapes: String, connections: Bool) {
        self.type = type
        self.shapes = shapes
        self.connections = connections
    }
}

/// The words a bound request adds (the product's `Shipped/ask-bound.txt`, in sections after `## <name>` lines): one
/// line after the stored query's rule (`line`, with `{type}`, `{shapes}`, `{ends}` and `{sentence}` filled in, `ends`
/// what `{ends}` is for connections) and the `:scope` words' lines added to the vocabulary (`words`, then `end words`
/// for connections). The prototype's words, as its live check sent them.
public struct BoundWords: Sendable, Equatable {
    let line: String
    let ends: String
    let words: String
    let endWords: String

    /// None: a bound request says nothing more than a stored one (an executable that isn't the product, a test that
    /// doesn't ask about binding).
    public static let none = BoundWords(line: "", ends: "", words: "", endWords: "")

    init(line: String, ends: String, words: String, endWords: String) {
        self.line = line
        self.ends = ends
        self.words = words
        self.endWords = endWords
    }

    /// The words a file of sections says; nil for text missing one of them.
    public init?(text: String) {
        var sections: [String: [String]] = [:]
        var current: String?
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                current = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                sections[current!] = []
            } else if let current, !line.isEmpty {
                sections[current]?.append(line)
            }
        }
        guard let line = sections["line"], let ends = sections["ends"], let words = sections["words"], let endWords = sections["end words"] else { return nil }
        self.init(line: line.joined(separator: " "), ends: ends.joined(), words: words.joined(separator: "\n"), endWords: endWords.joined(separator: "\n"))
    }

    /// The line the system prompt gains for a query bound so, about words in `sentence` (the sentence as the host says
    /// it, the words in brackets): empty with no words.
    public func line(for binding: StoredBinding, sentence: String?) -> String {
        guard !line.isEmpty else { return "" }
        return line.replacingOccurrences(of: "{type}", with: Self.quoted(binding.type))
            .replacingOccurrences(of: "{shapes}", with: binding.shapes)
            .replacingOccurrences(of: "{ends}", with: binding.connections ? ends : "")
            .replacingOccurrences(of: "{sentence}", with: sentence ?? "")
    }

    /// The `:scope` words' lines the vocabulary gains for a query bound so.
    public func vocabulary(for binding: StoredBinding) -> String {
        [words, binding.connections ? endWords : ""].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// A name in double quotes, as a query writes a title.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}

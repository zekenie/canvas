import Canvas
import CanvasRPC
import Foundation
import DecisionModels

/// The words a shape's rules are asked in (`Shipped/rule-prompt.txt`, the product's, which `LanguageRulesPlugin()`
/// reads): one question for the rules read together, which decides whether the shape is flagged, and one for each
/// rule read with the others, which says which rule a flag is about. The preface lists the rules, the most general
/// type's first, and each question says what its yes and its no mean. The file is in sections, each after a line
/// `## <name>`: `preface` (`{noun}`, then the rules' lines after it), `rule` (`{number}`, `{type}`, `{says}`),
/// `together` and `each` (`{noun}`, and `{number}` in `each`), each question's text followed by `true: …`, `false: …`
/// and `flags when: true|false`.
public struct RulePrompts: Equatable, Sendable {
    /// A question as asked, with what its answers mean.
    public struct Question: Equatable, Sendable {
        public var text: String
        /// What a yes means, and a no, word for word.
        public var yes: String
        public var no: String
        /// Whether a yes is the one that flags the shape.
        public var flagsWhenYes: Bool
    }

    public var preface: String
    public var rule: String
    public var together: Question
    public var each: Question

    /// The product's file this is read from (`Shipped/<name>.txt`).
    public static let file = "rule-prompt"

    public enum ReadError: Error, Equatable {
        case missing(String)
    }

    /// The prompts a file of sections says.
    public init(text: String) throws(ReadError) {
        var sections: [String: [String]] = [:]
        var current: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("## ") {
                current = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                sections[current!] = []
            } else if let current {
                sections[current]?.append(line)
            }
        }
        func lines(_ name: String) throws(ReadError) -> [String] {
            guard let found = sections[name] else { throw .missing(name) }
            var lines = found
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            return lines
        }
        func question(_ name: String) throws(ReadError) -> Question {
            var text: [String] = [], yes: String?, no: String?, flags: Bool?
            for line in try lines(name) {
                if line.hasPrefix("true: ") { yes = String(line.dropFirst(6)) }
                else if line.hasPrefix("false: ") { no = String(line.dropFirst(7)) }
                else if line.hasPrefix("flags when: ") { flags = line.hasSuffix("true") }
                else { text.append(line) }
            }
            guard let yes else { throw .missing("\(name) true") }
            guard let no else { throw .missing("\(name) false") }
            guard let flags else { throw .missing("\(name) flags when") }
            return Question(text: text.joined(separator: "\n"), yes: yes, no: no, flagsWhenYes: flags)
        }
        preface = try lines("preface").joined(separator: "\n")
        rule = try lines("rule").joined(separator: "\n")
        together = try question("together")
        each = try question("each")
    }

    /// The id of the question about the rules read together; each rule's is `r` and its place, from 0.
    public static let togetherID = "all"

    public static func id(ofRule index: Int) -> String { "r\(index)" }

    /// What's asked of `state` about `rules`, a shape called `noun`: the preface and its rules' lines, the question for
    /// all of them read together, then one for each.
    public func request(state: JSONValue, rules: [ChainedRule], noun: String) -> DecisionRequest {
        let lines = rules.enumerated().map { index, chained in
            Self.filled(rule, ["number": String(index + 1), "type": chained.typeName, "says": chained.rule.says])
        }
        let preface = ([Self.filled(self.preface, ["noun": noun])] + lines).joined(separator: "\n")
        var questions = [DecisionQuestion(id: Self.togetherID, asks: Self.filled(together.text, ["noun": noun]), yes: together.yes, no: together.no)]
        for index in rules.indices {
            questions.append(DecisionQuestion(id: Self.id(ofRule: index), asks: Self.filled(each.text, ["noun": noun, "number": String(index + 1)]),
                                              yes: each.yes, no: each.no))
        }
        return DecisionRequest(state: state, preface: preface, questions: questions)
    }

    /// How likely a question's answer says the shape is flagged: its probability of yes, or of no where a no flags.
    public func flagging(_ id: String, yes: Double) -> Double {
        let question = id == Self.togetherID ? together : each
        return question.flagsWhenYes ? yes : 1 - yes
    }

    /// `template` with each `{name}` in it replaced.
    static func filled(_ template: String, _ values: [String: String]) -> String {
        values.reduce(template) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }
}

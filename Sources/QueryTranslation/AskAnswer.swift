import Foundation
import LanguageModels
import QueryLanguage

/// What the model's answer to a question is, as `--ask` reads it.
public enum AskAnswer: Equatable, Sendable {
    /// A query to run.
    case query(String)
    /// `UNANSWERABLE`, and why (empty when it doesn't say).
    case unanswerable(String)
    /// It declined to answer (a refusal).
    case declined
    /// No query: what's wrong with it, in a fragment, and what to tell the model for a second try;
    /// nil when a second try won't help.
    case unusable(String, repair: String?)

    /// Reads an answer. A stop other than the end of its turn is unusable (cut off, or stopped
    /// early), or it declined. The text is trimmed and unwrapped (`ModelAnswer.unwrapped`: fence
    /// lines, lone tag lines, `<query>` tags), and of one pair of backticks, or a fence, around it on
    /// one line. A first word `UNANSWERABLE`, in any case, with or without a colon, is unanswerable,
    /// with what follows; nothing is unusable; one line is the query.
    ///
    /// More than one line with anything on them is most often reasoning, then the query on the last
    /// line (a line in one pair of backticks read without them): a last line that starts
    /// `UNANSWERABLE` is unanswerable; the lines joined by spaces, when they read as a query and some
    /// line alone doesn't, are one query written over several; else the last line, when it reads as
    /// a query (`SelectorList(parsing:)`: the words and titles in it aren't looked up). A query with
    /// more written after it is never taken: it's as often one the model went on to take back
    /// ("Wait, let me reconsider…"). Else a second try is told to put the query on one line.
    public static func parse(_ response: ModelResponse) -> AskAnswer {
        switch response.stopReason {
        case .endTurn: break
        case .refusal: return .declined
        case .maxTokens: return .unusable("its answer was cut off", repair: nil)
        default: return .unusable("it stopped before its answer was done", repair: nil)
        }
        let text = read(response.text)
        if let why = unanswerableWhy(text) { return .unanswerable(why) }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let only = lines.last else { return .unusable("it answered nothing", repair: nil) }
        guard lines.count > 1 else { return .query(only) }
        let unticked = lines.map(unticked)
        let last = unticked[unticked.count - 1]
        if let why = unanswerableWhy(last) { return .unanswerable(why) }
        let whole = unticked.joined(separator: " ")
        if readsAsQuery(whole), !unticked.allSatisfy(readsAsQuery) { return .query(whole) }
        if readsAsQuery(last) { return .query(last) }
        return .unusable("it wrote several lines, and the last isn't a query", repair: AskRequest.oneLine)
    }

    /// Whether text reads as a query, whatever it names.
    static func readsAsQuery(_ text: String) -> Bool {
        (try? SelectorList(parsing: text)) != nil
    }

    /// A line of one pair of backticks around it, as a model quotes a query in its reasoning.
    static func unticked(_ line: String) -> String {
        guard line.count > 2, line.hasPrefix("`"), line.hasSuffix("`"), !line.hasPrefix("``") else { return line }
        return String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    /// The text trimmed and unwrapped, and of one pair of backticks, or a fence, around it on one
    /// line. Over several lines, a backtick first and one last are most often two pairs, the first
    /// line's and the last's, which `unticked` takes off line by line.
    static func read(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fence = "```"
        if !text.contains(where: \.isNewline), text.count > 2 * fence.count, text.hasPrefix(fence), text.hasSuffix(fence) {
            text = String(text.dropFirst(fence.count).dropLast(fence.count))
        }
        text = ModelAnswer.unwrapped(text, tag: "query")
        if !text.contains(where: \.isNewline), text.count >= 2, text.hasPrefix("`"), text.hasSuffix("`") {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// What follows a first word `UNANSWERABLE` (any case, bold or not, a colon or a dash after it),
    /// on one line; nil when the first word is anything else.
    static func unanswerableWhy(_ text: String) -> String? {
        let marks: Set<Character> = ["*", "_"]
        let start = text.drop { marks.contains($0) }
        let word = start.prefix { $0.isLetter }
        guard word.uppercased() == "UNANSWERABLE" else { return nil }
        let after: Set<Character> = ["*", "_", ":", "-", "–", "—", "."]
        let rest = start.dropFirst(word.count).drop { after.contains($0) || $0.isWhitespace }
        return rest.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Ends with a period, unless it ends a sentence already.
    static func sentence(_ text: String) -> String {
        guard let last = text.last, !".!?".contains(last) else { return text }
        return text + "."
    }
}

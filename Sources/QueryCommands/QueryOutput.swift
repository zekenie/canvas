import Automation
import Canvas
import CanvasRPC
import Foundation
import os
import Queries
import QueryLanguage

// What `canvas query` answers, and how it says it can't: the result as the wire's JSON, built from
// the rows member for member (never written as text and read back), off the main actor, where the
// result is let go of too; a refusal as the command line reports it, with where in the query it is;
// and `query-vocabulary`'s answer.

/// A query's answer as the command line gets it:
/// `{board, query, count, rows, warnings?}`, with `asked` for a question (`--ask`), and without
/// `rows` for `--count`. `board` is where the query ran, `{shows, showsPath}`, the board shown as it
/// took up the file, which the command server completes with the file's id and name. Each row is
/// an object of its members, as `QueryRow` writes itself (what's absent left out), its `properties`
/// the shape's own JSON mapped member for member.
public enum QueryOutput {
    /// The most of a query's line a refusal quotes, in characters (`QueryError.located`): a line
    /// longer is quoted around what's wrong.
    public static let quoted = 200

    /// A query's answer, built off the main actor, where `result`, handed over whole, is let go of
    /// too: however many rows, the main actor neither builds nor frees them.
    @concurrent
    public nonisolated static func json(_ result: consuming QueryResult, countOnly: Bool) async -> JSON {
        build(result, countOnly: countOnly, asked: nil)
    }

    /// `--ask`'s answer: its query's, and the question asked.
    @concurrent
    public nonisolated static func json(_ outcome: consuming AskOutcome, countOnly: Bool) async -> JSON {
        build(outcome.result, countOnly: countOnly, asked: outcome.question)
    }

    private nonisolated static func build(_ result: borrowing QueryResult, countOnly: Bool, asked: String?) -> JSON {
        #if DEBUG
        builtOnMain.withLock { $0 = pthread_main_np() != 0 }
        #endif
        var answer: [String: JSON] = ["query": .string(result.query), "count": .number(Double(result.count))]
        answer[RPC.boardParam] = .object(["shows": .string(result.shown.description),
                                          "showsPath": .array(result.shownPath.map { .string($0.description) })])
        if let asked { answer["asked"] = .string(asked) }
        if !countOnly { answer["rows"] = .array(result.rows.map(row)) }
        if !result.warnings.isEmpty {
            answer["warnings"] = .array(result.warnings.map { .object(["reason": .string($0.reason.rawValue), "message": .string($0.message)]) })
        }
        return .object(answer)
    }

    /// A row, as `QueryRow` encodes itself: an untitled shape has no `title`, one on the top board no
    /// `inside`, and one with nothing to say no `properties`, `cut`, `connection` or `editing`.
    public nonisolated static func row(_ row: QueryRow) -> JSON {
        var object: [String: JSON] = ["id": .string(row.id.description), "kind": .string(row.kind.rawValue), "board": .string(row.board.description)]
        if let title = row.title { object["title"] = .string(title) }
        if !row.inside.isEmpty { object["inside"] = .array(row.inside.map(JSON.string)) }
        if let properties = row.properties { object["properties"] = .object(properties.mapValues { JSON($0) }) }
        if let cut = row.cut { object["cut"] = .array(cut.map(JSON.string)) }
        if let connection = row.connection {
            // An edge type is written as its id, as it encodes itself.
            object["connection"] = .object(["type": .string("\(connection.type)"), "from": end(connection.from), "to": end(connection.to)])
        }
        if let editing = row.editing { object["editing"] = .bool(editing) }
        return .object(object)
    }

    private nonisolated static func end(_ end: QueryEnd) -> JSON {
        var object: [String: JSON] = ["id": .string(end.id.description)]
        if let title = end.title { object["title"] = .string(title) }
        return .object(object)
    }

    #if DEBUG
    /// Whether the last answer was built on the main thread (debug builds): never, since it's built
    /// off the main actor. Nil before the first.
    public nonisolated static var lastBuiltOnMainThread: Bool? { builtOnMain.withLock { $0 } }
    private nonisolated static let builtOnMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    #endif
}

extension QueryWarning.Reason {
    /// `--ask`'s: the model's first query was refused, or wasn't one, and the answer is its second's.
    public static let repaired = QueryWarning.Reason(rawValue: "repaired")
}

// MARK: Refusals

extension AutomationError {
    /// A query's refusal as the command line reports it: its reason, message and hint, and where in
    /// `text` (the query as sent) it is, the line as written there (at most `QueryOutput.quoted`
    /// characters of it, around what's wrong, the column in what's quoted), so the caret `canvas`
    /// draws under it by `column` lands on what's wrong; and every problem found, each where it is.
    /// Nil `text`: a refusal of no part of a query (a deadline, a closed file).
    init(_ error: QueryError, in text: String?, details: [String: JSON] = [:]) {
        let place = text.flatMap { error.located(in: $0, quoting: QueryOutput.quoted) }
        self.init(error.message, reason: error.reason.rawValue, hint: error.hint, line: place?.line, column: place?.column, length: place?.length,
                  statement: place?.statement, errors: error.errors.map { AutomationError($0, in: text) }, details: details)
    }
}

// MARK: query-vocabulary

/// What `canvas query-vocabulary` answers: the `<vocabulary>` block `--ask` sends, and the same as
/// lists: each kind (`naming`, how its shapes are named: `named`, `derived` or `none`; `holdsShapes`,
/// whether shapes can be inside its shapes, and `holdsBoard`, whether by a board of their own; each
/// attribute and what it takes), each edge type (`under` the one it's a kind of), and each word
/// (`from` the plugin whose it is: the language's own are `queries`'). Not `titles`, Titles' plugin
/// id, which the id audit keeps a module that doesn't depend on Titles from writing, as a reader of
/// this would.
struct VocabularyAnswer: Encodable {
    struct KindLine: Encodable {
        let kind: String
        let label: String
        let naming: String
        let holdsShapes: Bool
        let holdsBoard: Bool
        let attributes: [String: String]
    }

    struct EdgeTypeLine: Encodable {
        let type: String
        let under: String?
        let summary: String?
    }

    struct WordLine: Encodable {
        let word: String
        let takes: String
        let summary: String
        let example: String
        let from: String
    }

    let vocabulary: String
    let kinds: [KindLine]
    let edgeTypes: [EdgeTypeLine]
    let words: [WordLine]

    init(_ vocabulary: QueryVocabulary) {
        self.vocabulary = vocabulary.text
        kinds = vocabulary.kinds.map { entry in
            let naming = switch entry.names {
            case .none: "none"
            case .named: "named"
            case .derived: "derived"
            }
            var attributes: [String: String] = [:]
            for attribute in entry.attributes { attributes[attribute.name] = attribute.compactType + (attribute.reads.map { " (\($0))" } ?? "") }
            return KindLine(kind: entry.kind.rawValue, label: entry.label, naming: naming, holdsShapes: entry.holdsShapes,
                            holdsBoard: entry.holdsBoard, attributes: attributes)
        }
        // Edge types are written as their ids, as they encode themselves.
        edgeTypes = vocabulary.edgeTypes.map { EdgeTypeLine(type: "\($0.type)", under: $0.parent.map { "\($0)" }, summary: $0.summary) }
        words = vocabulary.words.map { WordLine(word: $0.word, takes: $0.takes, summary: $0.summary, example: $0.example, from: $0.from.rawValue) }
    }
}

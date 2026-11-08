import AppKit
import Canvas
import CanvasTesting
import Foundation
import LanguageModels
import Queries
import QueryLanguage
import QueryTranslation
import ShippedTesting
import TestKit
import Topology

// `--ask`'s prompt (the product's `Shipped/ask-prompt.txt`, read as `QueryPrompt.system`) held to
// the language: each of its examples written in it as
// listed, each runnable one answered on the story file (the worked ones with what their questions
// ask), each illustrative one refused there with its reason; nothing it writes as a query left out
// of the lists; every word it writes accounted for; what its examples assume the shipped app's;
// and the canvas skill's copy of it the prompt, byte for byte.

/// The skill's copy of the prompt, and the lines its fence sits between.
let queryPromptCopy = "\(skillFolder)/query-prompt.md"
let queryPromptBegin = "<!-- QueryPrompt.system: begin -->"
let queryPromptEnd = "<!-- QueryPrompt.system: end -->"

/// A query's answer on the story file, or its refusal.
@MainActor
private func answer(_ query: String, in queries: QueryState) throws -> Result<QueryResult, QueryError> {
    do {
        return .success(try awaitResult { try await queries.run(QueryRequest(query, limit: QueryRequest.every, properties: .none)) })
    } catch let error as QueryError {
        return .failure(error)
    }
}

/// The story file's queries, in an editor of the shipped plugins, and the pasteboard to let go of.
@MainActor
private func storyQueries() throws -> (queries: QueryState, pasteboard: NSPasteboard, harness: EditorHarness) {
    let pasteboard = NSPasteboard.withUniqueName()
    let h = try QueryStory.harness(pasteboard: pasteboard)
    return (try require(h.editor.queries), pasteboard, h)
}

/// Every example, runnable or not.
@MainActor
private var everyExample: [String] { QueryPrompt.runnableExamples + QueryPrompt.illustrativeExamples.map(\.query) }

/// Whether `text` holds `example` as written, standing on its own: after the start, a space or a
/// line break, and before the end, a space, a line break, or `.`, `,` or `)` ending the sentence
/// or the list it's in.
private func holds(_ text: String, _ example: String) -> Bool {
    var from = text.startIndex
    while let found = text.range(of: example, range: from..<text.endIndex) {
        let before = found.lowerBound == text.startIndex ? nil : text[text.index(before: found.lowerBound)]
        let after = found.upperBound == text.endIndex ? nil : text[found.upperBound]
        if before.map(\.isWhitespace) ?? true, after.map({ $0.isWhitespace || ".,)".contains($0) }) ?? true { return true }
        from = text.index(after: found.lowerBound)
    }
    return false
}

/// What follows each "→" in the prompt: to the next "→", the end of its line, or the end of its
/// sentence (". "), less a period that ends it.
private func afterArrows(in text: String) -> [String] {
    text.split(separator: "\n").flatMap { line in
        line.components(separatedBy: "→ ").dropFirst().map { part in
            var said = part.components(separatedBy: ". ").first ?? part
            said = said.trimmingCharacters(in: .whitespaces)
            if said.hasSuffix(".") { said.removeLast() }
            return said
        }
    }
}

/// The matches of `pattern` in `text`: each match's first group, else the whole match.
private func matches(of pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let whole = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: whole).compactMap { match in
        let range = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range
        return Range(range, in: text).map { String(text[$0]) }
    }
}

/// The first match of `pattern` in `text`: its groups, in order.
private func groups(of pattern: String, in text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    return (1..<match.numberOfRanges).map { index in Range(match.range(at: index), in: text).map { String(text[$0]) } ?? "" }
}

@MainActor let queryPromptTests = Suite("Query prompt", [
    test("each example is in the prompt as written, standing on its own, and in one list only") {
        expect(!QueryPrompt.runnableExamples.isEmpty && !QueryPrompt.illustrativeExamples.isEmpty)
        for example in everyExample {
            expect(holds(QueryPrompt.system, example), "not in the prompt as written: \(example)")
        }
        var seen: Set<String> = []
        for example in everyExample {
            expect(seen.insert(example).inserted, "listed twice: \(example)")
        }
    },

    test("each runnable example is answered on the story file") {
        let story = try storyQueries()
        defer { story.pasteboard.releaseGlobally() }
        for example in QueryPrompt.runnableExamples {
            if case .failure(let error) = try answer(example, in: story.queries) {
                expect(false, "\(example) is refused: \(error.reason.rawValue): \(error.message) \(error.hint ?? "")")
            }
        }
    },

    test("each illustrative example is refused on the story file, with its reason") {
        let story = try storyQueries()
        defer { story.pasteboard.releaseGlobally() }
        for (example, reason) in QueryPrompt.illustrativeExamples {
            switch try answer(example, in: story.queries) {
            case .success(let result):
                expect(false, "\(example) is answered (\(result.count)), not refused \(reason.rawValue)")
            case .failure(let error):
                expectEqual(error.reason, reason, "\(example): \(error.message) \(error.hint ?? "")")
            }
        }
    },

    test("the worked examples answer their questions on the story file") {
        let story = try storyQueries()
        defer { story.pasteboard.releaseGlobally() }
        // Each query after "→" that names the story's shapes, and what its question asks for.
        let answers: [(query: String, letters: String)] = [
            (#""Refund policy":inside("Payments")"#, "Y"),               // is Refund policy inside Payments? yes
            (#"sticky-note"Checkout""#, "C"),                            // the notes titled Checkout
            (#"sticky-note[title=""]"#, "N2, N1, V"),                    // the notes with no title
            ("sticky-note:not([title])", "N2, N1, V"),                   // the same
            (#"arrow[channel=""]"#, "R2"),                               // a plain arrow, on no channel
            (#":contains("tokens")"#, "C"),                              // anything about tokens: Checkout's text
            (#":contains("retry")"#, "N2"),                              // where is retry written? "Retry on 502"
            (#":edge-to("Auth", arrow)"#, "A"),                          // what links to Auth?
            (#":edge-from("API gateway", arrow)"#, "U"),                 // what does API gateway link to?
            (#":edge-from("Warehouse")"#, "P"),                          // what does Warehouse point to?
            (#"sticky-note:mentions("Checkout")"#, "A"),                 // which notes mention Checkout?
            (#":mentioned-by("Checkout")"#, "A"),                        // what does Checkout mention?
            (#""Checkout":mentioned-by("API gateway")"#, "C"),           // is Checkout mentioned by API gateway? yes
            (#":connected-to("Checkout")"#, "A"),                        // what's connected to Checkout? directly
            (#":component-of("Warehouse")"#, "P"),                       // everything connected to Warehouse, however far
            (#":upstream-of("Auth")"#, "C, A"),                          // everything that leads to Auth, however far
            (":edge-from(:selected, arrow)", ""),                        // what do the selected shapes (Auth) link to? nothing
            (#"arrow:between("Auth", "API gateway")"#, "R1"),            // the arrows between Auth and API gateway
            (":start-of(arrow[channel=note-link])", "A"),                // where does the note-link arrow start? API gateway
            (":end-of(arrow[channel=note-link])", "U"),                  // where does the note-link arrow end? Auth
            (#""Payments" sticky-note[locked]:mentions("Checkout")"#, ""), // locked notes in Payments that mention Checkout: none
            (#":is-a("Person"):incomplete"#, "I"),                        // which people still need something? Ann: her required name
            (":selected", "U"),                                          // these, the selected ones
        ]
        for (query, letters) in answers {
            expect(QueryPrompt.runnableExamples.contains(query), "a runnable example: \(query)")
            guard case .success(let result) = try answer(query, in: story.queries) else {
                expect(false, "\(query) is refused")
                continue
            }
            expectEqual(result.rows.map(\.id), letters.isEmpty ? [] : QueryStory.ids(letters), query)
        }
    },

    test("every query after → is one of its examples, or the step before one") {
        let said = afterArrows(in: QueryPrompt.system)
        expect(said.count > 10, "the prompt's → examples: \(said.count)")
        for query in said where !query.hasPrefix("the results have") {
            expect(everyExample.contains(query), "not listed: \(query)")
        }
    },

    test("nothing it writes as a query is left out of the lists") {
        // Without its examples, each taken out only where it stands on its own (longest first, so a
        // longer one goes whole; a listed `sticky-note` leaves an unlisted `sticky-note:top-level`
        // whole), the prompt holds nothing that reads as a query: no brackets, ids, words with
        // parentheses, a kind or * written with what follows one in a query, a word on its own where
        // a query would stand, or a title in quotes followed by what a query writes after one. The
        // sentence naming what the examples assume names kinds and words, and is held by a test of
        // its own.
        var rest = QueryPrompt.system.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("The examples assume") }.joined(separator: "\n")
        for example in everyExample.sorted(by: { $0.count > $1.count }) {
            let alone = #"(?<!\S)"# + NSRegularExpression.escapedPattern(for: example) + #"(?![^\s.,)])"#
            rest = rest.replacingOccurrences(of: alone, with: " ", options: .regularExpression)
        }
        let story = try storyQueries()
        defer { story.pasteboard.releaseGlobally() }
        let kinds = story.queries.vocabulary.kinds.map { NSRegularExpression.escapedPattern(for: $0.kind.rawValue) }.joined(separator: "|")
        // (A bracket on its own is a character the prompt names: "add i before ] for any case"; a
        // word in parentheses is named, not written as a query: "a mention (:mentions)".)
        let patterns = [#"\[\S|\S\]"#, #"#[0-9A-Za-z]"#, #":[A-Za-z][A-Za-z0-9-]*\("#, #"(?<![\w-])(\#(kinds)|\*)[:\["]"#,
                        #"(?<!\S):[A-Za-z][A-Za-z0-9-]*"#, #""[^"\n]+"(:[A-Za-z]|\[| >| \*| (\#(kinds))\b)"#]
        for pattern in patterns {
            let left = matches(of: pattern, in: rest)
            expect(left.isEmpty, "written as a query, and in neither list (\(pattern)): \(left)")
        }
    },

    test("every word it writes is the language's, a shipped plugin's, or one it says not to invent") {
        let story = try storyQueries()
        defer { story.pasteboard.releaseGlobally() }
        let language = Set(Word.allCases.map(\.rawValue))
        let plugins = Set(story.queries.vocabulary.words.filter { $0.from != .queries }.map(\.word))
        expectEqual(plugins, ["mentions", "mentioned-by", "invalid", "warned", "incomplete", "is-a", "misfit", "grouped-with", "selected", "drawn-by", "changed", "route"], "the shipped plugins' words")
        // Those it says not to invent are illustrative examples on their own, each refused with its reason.
        let invented = Set(QueryPrompt.illustrativeExamples.map(\.query).filter { $0.hasPrefix(":") && !$0.contains("(") }.map { String($0.dropFirst()) })
            .subtracting(language)
        expectEqual(invented, ["parent-of", "child-of", "root", "empty", "first-child"])
        for word in invented {
            expect(KnownInventions.invention(for: word) != nil, ":\(word) is a known invention, refused with what to write")
        }
        let written = matches(of: #":([A-Za-z][A-Za-z0-9-]*)"#, in: QueryPrompt.system)
        expect(written.count > 40, "the prompt's words: \(written.count)")
        for word in written {
            let lowered = word.lowercased()
            expect(language.contains(lowered) || plugins.contains(word) || invented.contains(lowered), "not accounted for: :\(word)")
        }
    },

    test("the kinds, edge types and words its examples assume are the shipped ones, in the vocabulary's order") {
        let story = try storyQueries()
        defer { story.pasteboard.releaseGlobally() }
        let vocabulary = story.queries.vocabulary
        let line = try require(QueryPrompt.system.split(separator: "\n").first { $0.hasPrefix("The examples assume") }.map(String.init))
        let parts = try require(groups(of: #"the kinds (.+); the edge types (.+); and the pseudo-classes (.+?)\. "#, in: line), line)
        /// The names a list says, without what's in parentheses.
        func names(_ list: String) -> [String] {
            list.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: " and ", with: ", ").components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        @MainActor func inOrder(_ said: [String], _ shipped: [String], _ what: String) {
            for name in said { expect(shipped.contains(name), "\(what): \(name) isn't the shipped app's") }
            expectEqual(said, shipped.filter(said.contains), "\(what) in the vocabulary's order")
        }
        inOrder(names(parts[0]), vocabulary.kinds.map(\.kind.rawValue), "kinds")
        inOrder(names(parts[1]), vocabulary.edgeTypes.map(\.type.rawValue), "edge types")
        // The prompt keeps `:incomplete` with the words of types, which its example uses together (`:is-a("Person"):incomplete`); the app
        // has it with Validation's (`:invalid`, `:warned`, `:incomplete`). Every other word is said in the vocabulary's order.
        let said = names(parts[2]).map { String($0.drop { $0 == ":" }) }, shipped = vocabulary.words.filter { $0.from != .queries }.map(\.word)
        expect(said.contains("incomplete") && shipped.contains("incomplete"), "the prompt names :incomplete, which the app has")
        inOrder(said.filter { $0 != "incomplete" }, shipped.filter { $0 != "incomplete" }, "words")
        // What's under the one it names.
        let under = try require(matches(of: #"with ([a-z-]+) under it"#, in: parts[1]).first)
        let arrow = vocabulary.edgeTypes.first { $0.type.rawValue == under }
        expect(arrow?.parent != nil && parts[1].contains("\(arrow?.parent?.rawValue ?? "?") (with \(under)"), "\(under) is under the type it's said under")
    },

    test("the canvas skill's query-prompt.md holds the prompt, byte for byte") {
        let lines = try String(contentsOfFile: queryPromptCopy, encoding: .utf8).components(separatedBy: "\n")
        let begin = try require(lines.firstIndex(of: queryPromptBegin), "\(queryPromptCopy) marks where the prompt begins")
        let end = try require(lines.firstIndex(of: queryPromptEnd), "and where it ends")
        guard begin + 2 < end - 1 else { return expect(false, "a fence between the marks") }
        expectEqual(lines[begin + 1], "````text", "a four-backtick text fence opens after the first mark")
        expectEqual(lines[end - 1], "````", "and closes before the second")
        let fenced = lines[(begin + 2)..<(end - 1)].joined(separator: "\n") + "\n"
        expect(fenced == QueryPrompt.system, "the fenced text is Shipped/ask-prompt.txt: python3 scripts/query-prompts/copy_prompt.py copies it")
        // Its paragraphs before the prompt say how to write a query without --ask: with its inputs.
        let before = lines[..<begin].joined(separator: "\n")
        for input in ["query-vocabulary", "--brief --limit 200 '[title]'", "--brief ':selected'", "<vocabulary>", "<titles>", "<board>", "<fields>", "--fields schema"] {
            expect(before.contains(input), "query-prompt.md says how to get \(input)")
        }
    },
    test("the prompt and its rule line are text files of the product's, in this executable as they're written") {
        let prompt = try String(contentsOfFile: "Shipped/\(QueryTranslationPlugin.promptFile).txt", encoding: .utf8)
        let rule = try String(contentsOfFile: "Shipped/\(QueryTranslationPlugin.ruleFile).txt", encoding: .utf8)
        expect(ShippedText.named(QueryTranslationPlugin.promptFile) == prompt, "the build puts the prompt in the binary, byte for byte")
        expect(ShippedText.named(QueryTranslationPlugin.ruleFile) == rule, "and the rule line")
        expect(prompt.hasSuffix("Nothing else.\n") && !prompt.hasSuffix("\n\n"), "the prompt ends with its last line and one line break")
        expect(rule.hasSuffix(".\n") && !rule.dropLast().contains("\n"), "the rule is one line, with its line break")
        expectEqual(QueryPrompt.referenceRule + "\n", rule, "which the translator takes without the break")
        expectEqual(QueryPrompt.system, prompt)
        expectEqual(ShippedText.named("no-such-text"), nil, "a name the folder has no file of")
    },
    test("the request built by the shipped list carries <fields> after <titles>, then <instances> and <connections> last, the file's types, their fields, which shapes are of each and how arrows join them, and no types' blocks for a file with none") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let model = ScriptedLanguageModel(answers: ["sticky-note", "sticky-note"])
        let h = try QueryStory.harness(pasteboard: pasteboard, model: model)
        let translator = try require(h.editor.queryTranslator)
        _ = try awaitResult { try await translator.translate("which employees started?", about: .person) }
        _ = try awaitResult { try await translator.translate("notes", about: .stored()) }
        for request in model.requests {
            let text = try require(request.messages.first?.text)
            let titles = try require(text.range(of: "</titles>\n\n<fields>\n"), "after the titles: " + text)
            let end = try require(text.range(of: "\n</fields>"))
            expect(end.lowerBound > titles.upperBound, "the fields after the titles")
            let instances = try require(text.range(of: "</fields>\n\n<instances>\n"), "the instances after the fields: " + text)
            let connections = try require(text.range(of: "</instances>\n\n<connections>\n"), "the connections after the instances: " + text)
            expect(text.hasSuffix("</connections>"), "and last")
            // Ann is an Employee card, and so a Person too, by title; the types with no shape of them have no line; and the
            // titled shapes of no type last, subboards and frames included, in the boards' order (the untitled ones aren't named):
            // Payments and Checkout on the top board, Refunds on Payments' (a subboard, so titled), Refund policy on Refunds'.
            expectEqual(text[instances.upperBound..<connections.lowerBound].split(separator: "\n").map(String.init),
                        [#"Employee card: "Ann""#, #"Person: "Ann""#, #"Of no type: "Payments", "API gateway", "Auth", "Ledger", "Checkout", "Refunds", "Refund policy""#])
            // The story's one arrow bound at both ends joins two notes of no type: by their kind, and no title.
            expectEqual(text[connections.upperBound...].split(separator: "\n").dropLast().map(String.init), ["sticky-note → sticky-note: 1 arrow"])
            let fields = String(text[titles.upperBound..<end.lowerBound]).split(separator: "\n").map(String.init)
            for line in ["Person: name (text)", "Employee card builds on Person: desk (text), started (date), teams (list) {name (text)}"] {
                expect(fields.contains(line), "the story's \(line): \(fields)")
            }
            expect(fields.contains { $0.hasPrefix("Order: id (text)") } && fields.contains { $0.hasPrefix("Warehouse: id (text)") }, "Order and Warehouse: \(fields)")
            expect(!text.contains("2024-05-01") && !text.contains("platform"), "no value leaves the machine")
        }
        // The question's words rank the types: employees' first for a question that names them.
        expect(try require(model.requests.first?.messages.first?.text).contains("<fields>\nEmployee card builds on Person"), "ranked by the question")
        // A file with no types sends no block, nor its tags.
        let bare = ScriptedLanguageModel(answers: ["sticky-note"])
        let registry = try ShippedPlugins.registry(pasteboard: pasteboard, model: bare)
        let untyped = QueryStory.ids("W, S, V, T1, T2")
        let whole = QueryStory.file(in: registry)
        let file = CanvasFile(root: CanvasDocument(shapes: whole.root.shapes.filter { !untyped.contains($0.id) }), children: whole.children)
        let plain = EditorHarness { CanvasEditor(registry: registry, file: file, scheduler: $0) }
        _ = try awaitResult { try await plain.editor.queryTranslator?.translate("notes") }
        let bareText = try require(bare.requests.first?.messages.first?.text)
        expect(!bareText.contains("<fields>") && !bareText.contains("<instances>"), "no types, no blocks")
    },
    test("a stored query's request carries the rule line and a vocabulary without the words that read the editor, and a person's carries neither") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let model = ScriptedLanguageModel(answers: ["sticky-note", "sticky-note"])
        let h = try QueryStory.harness(pasteboard: pasteboard, model: model)
        let translator = try require(h.editor.queryTranslator)
        _ = try awaitResult { try await translator.translate("notes", about: .stored()) }
        _ = try awaitResult { try await translator.translate("notes", about: .person) }
        let stored = try require(model.requests.first), person = try require(model.requests.last)
        let words = try require(h.editor.queries).vocabulary.words
        let editorWords = words.filter { $0.readsEditor && $0.from != .queries }.map(\.word)
        expect(words.contains { $0.word == "current-board" && $0.readsEditor }, "the language's :current-board reads it too (taught by the prompt, not listed in the vocabulary)")
        expect(editorWords.contains("selected") && editorWords.contains("invalid"), "the shipped words that read the editor: \(editorWords)")
        func vocabulary(_ request: ModelRequest) -> String {
            let text = request.messages.first?.text ?? ""
            guard let start = text.range(of: "<vocabulary>"), let end = text.range(of: "</vocabulary>") else { return "" }
            return String(text[start.upperBound..<end.lowerBound])
        }
        expect(stored.system?.hasSuffix(QueryPrompt.referenceRule) == true, "the rule line closes the system prompt")
        expect(stored.system?.hasPrefix(QueryPrompt.system) == true, "and the prompt itself is unchanged")
        expectEqual(person.system, QueryPrompt.system, "a person's has no rule line")
        for word in editorWords {
            expect(!vocabulary(stored).contains(":\(word)"), "a stored query's vocabulary leaves out :\(word)")
            expect(vocabulary(person).contains(":\(word)"), "a person's has :\(word)")
        }
        expect(vocabulary(stored).contains(":mentions(S)"), "and keeps the words that read only the file")
        expect(!(stored.messages.first?.text ?? "").contains("Selected:"), "no selection in <board>")
        expect((person.messages.first?.text ?? "").contains("Selected:"), "a person's has it")
        expect(QueryPrompt.referenceRule.contains(":selected"), "the line names the word the examples teach")
    },
    test("a bound query's request carries the product's bound line after the rule line, its type, shapes and sentence filled in, and the :scope words; arrows' ends too") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let model = ScriptedLanguageModel(answers: [":scope", ":scope"])
        let h = try QueryStory.harness(pasteboard: pasteboard, model: model)
        let translator = try require(h.editor.queryTranslator)
        let notes = StoredBinding(type: "Order", shapes: "sticky-notes", connections: false)
        let arrows = StoredBinding(type: "Employment", shapes: "arrows", connections: true)
        _ = try awaitResult { try await translator.translate("the other orders", about: .stored(binding: notes, sentence: "Priced unlike [the other orders].")) }
        _ = try awaitResult { try await translator.translate("the company", about: .stored(binding: arrows, sentence: "Unusual for [the company].")) }
        let bound = try require(ShippedText.named(QueryTranslationPlugin.boundFile).flatMap(BoundWords.init(text:)), "the product's bound words")
        let note = try require(model.requests.first), arrow = try require(model.requests.last)
        expectEqual(note.system, QueryPrompt.system + "\n" + QueryPrompt.referenceRule + "\n" + bound.line(for: notes, sentence: "Priced unlike [the other orders]."))
        expect(note.system?.contains(#"a rule on the type "Order", whose shapes are sticky-notes"#) == true)
        expect(note.system?.contains("“Priced unlike [the other orders].”") == true)
        expect(!(note.system ?? "").contains(":scope-start") && (arrow.system ?? "").contains(":scope-start the shape it starts at"), "the ends, for arrows")
        func vocabulary(_ request: ModelRequest) -> String {
            let text = request.messages.first?.text ?? ""
            guard let start = text.range(of: "<vocabulary>"), let end = text.range(of: "</vocabulary>") else { return "" }
            return String(text[start.upperBound..<end.lowerBound])
        }
        expect(vocabulary(note).hasSuffix("- :scope — the shape the rule is checking. Example: :scope\n"), vocabulary(note))
        expect(!vocabulary(note).contains(":scope-start") && vocabulary(arrow).contains("- :scope-end — the shape the arrow being checked ends at."))
        expect((note.messages.first?.text ?? "").hasPrefix("<question>\nthe other orders\n</question>"), "the phrase is the question")
    },
])

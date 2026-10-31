import Canvas
import Foundation
import QueryLanguage
import QueryTranslation

// `canvas query --ask`'s system prompt, as these tests read it, and the query-like examples it
// writes. The prompt is a text file of the product's, `Shipped/ask-prompt.txt` (what the app tells
// its model when it asks it to write a query for a question in English: QueryTranslation's
// `QueryTranslator` sends it, with the question, this app's vocabulary, where the person is and the
// file's titles, each a tagged block of the user message). It's the product's, not
// QueryTranslation's, since its examples name the shipped kinds, edge types and words, which no
// module knows all of; the build puts it in this executable (`ShippedText`), as it does the app's.
//
// To change the prompt, edit the file (`Shipped/README.md` says what holds it to what), and list
// each query-like example it writes in one of the two lists below.

/// What `--ask` tells the model, and the query-like examples it writes, each held to the language
/// on the story file (`QueryStory`) by QueryPromptTests.
enum QueryPrompt {
    /// The system prompt, as the shipped translator is made with it: the file, byte for byte.
    static let system = ShippedText.named(QueryTranslationPlugin.promptFile) ?? ""

    /// The one line added to the system prompt when the query is stored and run later, by a reference
    /// that stands for what it finds (`TranslationContext.stored()`): the prompt itself, whose
    /// examples still teach `:selected` and `:current-board`, is `--ask`'s byte for byte, so this line
    /// (and the vocabulary leaving those words out, and the check that refuses them) keeps the model
    /// off every word that reads the person. Not an example, so not in the skill's copy. The file's
    /// one line, without its line break, as the shipped translator takes it.
    static let referenceRule = (ShippedText.named(QueryTranslationPlugin.ruleFile) ?? "").trimmingCharacters(in: .newlines)

    /// Every query the prompt writes that runs on the story file, each verbatim in `system`: the
    /// answers after "→", and the examples that name the story's shapes and real attributes, in the
    /// prompt's order. Each is answered there (a count of 0 is an answer: `[text*="retry"]` finds
    /// none, since text compares exactly and the story's note says "Retry").
    static let runnableExamples: [String] = [
        // The answer, and yes/no questions.
        #""Refund policy":inside("Payments")"#,
        // Shapes.
        "sticky-note", "*", #""Checkout""#, #"sticky-note"Checkout""#,
        // Attributes.
        "[locked]", "[locked=false]", #"[title=""]"#, #"sticky-note[title=""]"#, "sticky-note:not([title])", #"arrow[channel=""]"#,
        "[channel=note-link]", #"[title="api gateway" i]"#, #"[text*="retry"]"#, #"[text^="TODO"]"#,
        #"[text$="?"]"#, #"[title^="API"]"#, #"[text*="rate limit"]"#, #"[text*="@Checkout"]"#,
        #"[fieldValues.started<"2025-01-01"]"#, #"[fieldValues.teams.name="search"]"#,
        // Text.
        #":contains("retry")"#, #":contains("tokens")"#,
        // Inside.
        #""Payments" sticky-note"#, #""Payments" > sticky-note"#, #"subboard:has("Refund policy")"#, #":has(> "Refund policy")"#,
        ":top-level", ":current-board", "sticky-note:selected",
        // Edges.
        ":dangling", ":invalid", ":edge-to(sticky-note[locked])", ":edge-to(*)", #":edge-to(:is("Auth", "Checkout"))"#,
        #":edge-to("Auth", arrow)"#, #":edge-from("API gateway", note-link|mention)"#, #":edge-to("Payments", only arrow)"#,
        #":edge-from("API gateway", arrow)"#, #":edge-from("Warehouse")"#, #"sticky-note:mentions("Checkout")"#, #":mentioned-by("Checkout")"#, #"sticky-note:is-a("Person")"#,
        "sticky-note[schema]", #":is-a("Person")"#, #"sticky-note:is-a("Employee card")"#, #":edge-from("Ann", is-a)"#,
        #":contains("volunteer"):connected-to(:contains("bake sale"))"#,
        ":incomplete", #":is-a("Person"):incomplete"#, "arrow:misfit",
        // The relationship types a type has, and the types at their far ends (the story has none: both answer nothing).
        #"sticky-note[relationship]:connected-to("Order", arrow)"#,
        #":end-of(arrow:starts-at(sticky-note[relationship]:connected-to("Order", arrow)))"#,
        #""Checkout":mentioned-by("API gateway")"#, #":connected-to("Checkout")"#, #":component-of("Warehouse")"#, #":upstream-of("Auth")"#,
        ":edge-from(:selected, arrow)", #"arrow:between("Auth", "API gateway")"#, ":start-of(arrow[channel=note-link])",
        ":end-of(arrow[channel=note-link])",
        // Combining.
        #"sticky-note[locked]:mentions("Checkout")"#, "sticky-note, subboard", "sticky-note:not(:mentions(*))",
        #""Payments" sticky-note[locked]:mentions("Checkout")"#,
        // Rules.
        #":edge-to("Auth", note-link)"#, #"[title="…" i]"#, #":contains("X")"#, ":selected",
    ]

    /// Every query-like example the prompt writes that's refused on the story file, each verbatim in
    /// `system`, with the reason it's refused there: its made-up attributes (`[rank>3]`: no shipped
    /// kind has rank, status, tags or due), its placeholders (`:edge-to(ANCHOR)` and `:not(S)`, read
    /// as kinds; `"A":has(> "B")`, as titles), the words a step of its direction procedure names
    /// without an anchor, and the forms it says not to write (`note`, `#Checkout`,
    /// `sticky-note :selected`, the words not to invent), in the prompt's order.
    static let illustrativeExamples: [(query: String, refused: QueryError.Reason)] = [
        // Shapes.
        ("#7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11", .unknownID), ("note", .unknownKind), ("#Checkout", .notAnID),
        // Attributes.
        ("[rank=3]", .unknownAttribute), ("[status!=done]", .unknownAttribute), ("[tags~=backend]", .unknownAttribute),
        ("[rank>3]", .unknownAttribute), ("[rank<=3]", .unknownAttribute), (#"[due<"2026-10-01"]"#, .unknownAttribute),
        // Inside.
        (#""Sprint 3" sticky-note"#, .unknownTitle), (#""A":has(> "B")"#, .unknownTitle), (#""A":has("B")"#, .unknownTitle), (#""A" > "B""#, .unknownTitle), (#""B" > *"#, .unknownTitle),
        ("sticky-note :selected", .straySpace),
        // Edges.
        (":edge-to(ANCHOR)", .unknownKind), (":edge-from(ANCHOR)", .unknownKind), (":connected-to(ANCHOR)", .unknownKind),
        (":downstream-of(ANCHOR)", .unknownKind), (":upstream-of(ANCHOR)", .unknownKind), (":component-of(ANCHOR)", .unknownKind),
        ("arrow:starts-at(ANCHOR)", .unknownKind), ("arrow:ends-at(ANCHOR)", .unknownKind), ("arrow:between(ANCHOR, ANCHOR)", .unknownKind),
        (":start-of(ANCHOR)", .unknownKind), (":end-of(ANCHOR)", .unknownKind),
        (":edge-to", .badArgument), (":edge-from", .badArgument),
        // Types: a relationship type is not in the story, so what names one is refused for its title; a title after a comma
        // is not an edge type.
        (#":edge-to("Bo", "Friendship")"#, .badArgument), (#"arrow:is-a("Friendship")"#, .unknownTitle),
        (#":end-of(arrow:is-a("Friendship"):starts-at("Ann"))"#, .unknownTitle), (#":start-of(arrow:is-a("Friendship"):ends-at("Ann"))"#, .unknownTitle),
        (#":end-of(arrow:is-a("Placed by"):starts-at("Order 12"))"#, .unknownTitle),
        (#"arrow:is-a("Friendship")[fieldValues.since<"2020-01-01"]"#, .unknownTitle),
        (#"sticky-note:is-a("Order"):not([schema]):not(:start-of(arrow:is-a("Placed by")))"#, .unknownTitle),
        // Combining.
        (":not(S)", .unknownKind), (":is(S1, S2)", .unknownKind),
        // Rules: the words not to invent.
        (":parent-of", .unknownPseudoClass), (":child-of", .unknownPseudoClass), (":root", .unsupported), (":empty", .unsupported),
        (":first-child", .unsupported),
    ]
}

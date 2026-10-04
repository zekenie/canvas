import Canvas
import CanvasTesting
import Mentions
import Queries
import QueryLanguage
import QueryLexicon
import TestKit

// Mentions in queries: mention text read as a person reads it (each mention "@" and the name its
// target has now), and `:mentions(S)` and `:mentioned-by(S)` over Topology's mention edges, across
// the file's boards, a shape's mention of itself included, and no other edge.

@MainActor let mentionQueriesTests = Suite("Mentions in queries", [
    test("mention text reads as a person reads it: each mention @ and its target's name now, a gone one's by the name it holds") {
        let h = try mentionHarness()
        let texts = try texts(on: h)
        expectEqual(texts[id(1)], "Owns auth. See @Checkout", "the name Checkout has now, not the one the mention holds")
        expectEqual(texts[id(11)], "Calls @Gateway for tokens")
        expectEqual(texts[id(4)], "Back to @Loop")
        expectEqual(texts[id(5)], "Moved to @Old ledger", "its target is gone: the name the mention holds")
        expectEqual(texts[id(12)], "Retry, see @Payments")
        expectMatches([
            #"[text*="@Checkout"]"#: [1],
            #"[text*="Checkout page"]"#: [],
            #"[text="Calls @Gateway for tokens"]"#: [11],
            #"[text*="shape:"]"#: [],
            #":contains("@payments")"#: [12],
        ], on: h)
        let text = try require(h.editor.queries?.vocabulary.kind(Scribble.kind)?.attribute("text"))
        expectEqual(text.mediaType, MentionTextFormat.mediaType)
        expectEqual(text.reads, "mentions read as @Name")
    },
    test("a rename reads in the next query, on the board shown or another, and its undo puts the name back") {
        let h = try mentionHarness()
        h.editor.rename(id(1), "API gateway")
        expectEqual(try texts(on: h)[id(11)], "Calls @API gateway for tokens", "renamed on the board shown; mentioned from a pocket's")
        expectMatches([#"[text*="@API gateway"]"#: [11]], on: h)
        h.editor.undo()
        expectEqual(try texts(on: h)[id(11)], "Calls @Gateway for tokens")

        h.editor.rename(id(11), "Cart")
        expectEqual(try texts(on: h)[id(1)], "Owns auth. See @Cart", "renamed on a board that isn't shown")
        expectMatches([#"[text*="@Cart"]"#: [1], #"[text*="@Checkout"]"#: []], on: h)
        h.editor.undo()
        expectEqual(try texts(on: h)[id(1)], "Owns auth. See @Checkout")
        expectMatches([#"[text*="@Cart"]"#: [], #"[text*="@Checkout"]"#: [1]], on: h)
    },
    test(":mentions and :mentioned-by follow mentions across the file's boards") {
        let h = try mentionHarness()
        expectMatches([
            #":mentions("Checkout")"#: [1],
            ":mentions(#\(uuid(11)))": [1],
            #":mentioned-by("Checkout")"#: [1],
            #":mentions("Gateway")"#: [11],
            #""Payments" scribble:mentions("Gateway")"#: [11],
            #":mentions("Payments")"#: [12],
            #":mentions(pocket)"#: [12],
            #":mentioned-by(:inside("Payments"))"#: [1, 3],
            ":mentions(*)": [1, 11, 12, 4],
            ":mentioned-by(*)": [1, 3, 11, 4],
            #"scribble:not(:mentions(*))"#: [2, 5],
        ], on: h)
    },
    test("they follow mentions alone, no other edge") {
        let h = try mentionHarness()
        expectMatches([
            #":edge-to("Gateway")"#: [2, 11],
            #":mentions("Gateway")"#: [11],
            #":mentioned-by("Auth")"#: [],
            #":edge-from("Auth")"#: [1],
        ], on: h)
    },
    test("a shape's mention of itself counts") {
        let h = try mentionHarness()
        expectMatches([
            #":mentions("Loop")"#: [4],
            #":mentioned-by("Loop")"#: [4],
            #""Loop":mentions("Loop")"#: [4],
        ], on: h)
    },
    test("a shape that's gone has no title to name it by: the refusal says :dangling finds its mentioners; a title unquoted is hinted in quotes") {
        let h = try mentionHarness()
        let gone = try require(try refusal(#":mentions("Old ledger")"#, on: h))
        expectEqual(gone.reason, .unknownTitle)
        expectEqual(gone.hint, #"Did you mean "Ledger"? Some mention edges point at shapes that aren't there: :dangling(mention) finds what carries them."#)
        expectMatches([":dangling(mention)": [5]], on: h)
        expectEqual(try refusal(#":mentioned-by("Old ledger")"#, on: h)?.hint, #"Did you mean "Ledger"?"#, "what's gone mentions nothing")

        let unquoted = try require(try refusal(":mentions(Checkout)", on: h))
        expectEqual(unquoted.reason, .unknownKind)
        expectEqual(unquoted.message, "Checkout isn't a kind.")
        expectEqual(unquoted.hint, #""Checkout" is the shape titled so."#)
        expectMatches([#":mentions("Checkout")"#: [1]], on: h)
        expectEqual(try refusal(":mentions(Nobody)", on: h)?.hint.map { $0.hasPrefix("The kinds: ") }, true, "no shape's title: the kinds")
    },
    test("the vocabulary lists the words, from MentionQueriesPlugin") {
        let vocabulary = try require(try mentionHarness().editor.queries).vocabulary
        let words = vocabulary.words.filter { $0.from == MentionQueriesPlugin().id }
        expectEqual(words.map(\.form), [":mentions(S)", ":mentioned-by(S)"])
        expectEqual(words.map(\.takes), ["shapes", "shapes"])
        expect(vocabulary.text.contains(#"- :mentions(S) — its text mentions a shape S matches. Example: :mentions("Checkout")"#), vocabulary.text)
        expect(vocabulary.text.contains("text text (mentions read as @Name)"), vocabulary.text)
    },
    test("without MentionQueriesPlugin, no word follows mentions, and text reads as it's stored") {
        let h = try mentionHarness(withPlugin: false)
        expectEqual(try refusal(":mentions(*)", on: h)?.reason, .unknownPseudoClass)
        expectEqual(try refusal(":mentioned-by(*)", on: h)?.reason, .unknownPseudoClass)
        expect(try texts(on: h)[id(1)]?.contains("(shape:\(uuid(11)))") == true, "the stored form")
    },
])

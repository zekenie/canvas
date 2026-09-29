import LanguageModels
import QueryCommands
import TestKit

// How `--ask` reads the model's answer: a stop other than the end of its turn, fences, backticks and
// tags taken off, UNANSWERABLE however it's written, more than one line (reasoning, then the query,
// or a query written over lines; never a query with more written after it), and nothing.

private let oneLine = AskRequest.oneLine

@MainActor let parseTests = Suite("--ask's answer", [
    test("a query, however it's wrapped") {
        let cases: KeyValuePairs<String, String> = [
            "chore": "chore",
            "  chore:picked \n": "chore:picked",
            "```\nchore\n```": "chore",
            "```css\nchore:top-level\n```\n": "chore:top-level",
            "`chore`": "chore",
            "```chore```": "chore",
            "<query>chore</query>": "chore",
            "<query>\n\"Pantry\" > chore\n</query>": "\"Pantry\" > chore",
            "chore\n</output>": "chore",
            "<answer>\nchore\n</answer>": "chore",
            "\n\n\"Pantry\" chore[status=done]\n\n": "\"Pantry\" chore[status=done]",
            "`\"Alpha\"`": "\"Alpha\"",
            "The query is: chore": "The query is: chore",
            "UNANSWERABLES are fine": "UNANSWERABLES are fine",
        ]
        for (text, query) in cases {
            expectEqual(QueryAsking.parse(ModelResponse(text: text)), .query(query), text)
        }
    },
    test("UNANSWERABLE, first, in any case, with or without a colon, bold or fenced: what follows, on one line") {
        let cases: KeyValuePairs<String, String> = [
            "UNANSWERABLE: where shapes sit isn't in the language": "where shapes sit isn't in the language",
            "Unanswerable: sums": "sums",
            "unanswerable - no positions": "no positions",
            "UNANSWERABLE — how shapes look": "how shapes look",
            "UNANSWERABLE": "",
            "UNANSWERABLE.": "",
            "UNANSWERABLE sums of values": "sums of values",
            "**UNANSWERABLE**: positions": "positions",
            "UNANSWERABLE:\nThe language has no\npositions.": "The language has no positions.",
            "```\nUNANSWERABLE: sums\n```": "sums",
            "<query>UNANSWERABLE: a change to the board</query>": "a change to the board",
        ]
        for (text, why) in cases {
            expectEqual(QueryAsking.parse(ModelResponse(text: text)), .unanswerable(why), text)
        }
    },
    test("more than one line: UNANSWERABLE last, one query over several lines, else the last line when it reads as a query") {
        let cases: KeyValuePairs<String, QueryAsking.Answer> = [
            // Reasoning, then the query.
            "Here is the query:\nchore": .query("chore"),
            "\"Linked to\" reads either way, so I use an edge either way.\n\nchore:connected-to(\"Pantry\", wire)":
                .query("chore:connected-to(\"Pantry\", wire)"),
            "It's a chore.\n```\nchore:top-level\n```": .query("chore:top-level"),
            // The last line in backticks, as reasoning quotes a query.
            "The chores on top.\n\n`chore:top-level`": .query("chore:top-level"),
            "Every chore.\n` chore `": .query("chore"),
            // Reasoning that starts with a backtick: the pair around the whole isn't one (the first
            // line's opens, the last line's closes).
            "`chore` is the kind.\n`chore:top-level`": .query("chore:top-level"),
            "`[status]` has a value, so the open ones are:\n\n`chore:not([status=done])`": .query("chore:not([status=done])"),
            // A query taken back, then the one meant, last.
            "chore\n\nWait, that's every chore. The ones on top:\n\nchore:top-level": .query("chore:top-level"),
            // Each line reads as a query: the last is the answer.
            "```\nchore\npocket\n```": .query("pocket"),
            "Chores in the pantry\n\"Pantry\" chore": .query("\"Pantry\" chore"),
            // A query written over lines reads whole where a line of it doesn't.
            "chore,\npocket": .query("chore, pocket"),
            ":is(\n  \"Alpha\",\n  \"Beta\"\n)": .query(":is( \"Alpha\", \"Beta\" )"),
            "chore[\nstatus=done]": .query("chore[ status=done]"),
            // Words that aren't the language's still read: a refusal of the run says what's wrong.
            "The pantry's chores:\nchore:nope": .query("chore:nope"),
            // UNANSWERABLE on the last line, after reasoning.
            "Where shapes are isn't asked.\nUNANSWERABLE: positions": .unanswerable("positions"),
            "chore\nUNANSWERABLE": .unanswerable(""),
            "chore\n`UNANSWERABLE: sums`": .unanswerable("sums"),
        ]
        for (text, answer) in cases {
            expectEqual(QueryAsking.parse(ModelResponse(text: text)), answer, text)
        }
    },
    test("more than one line and the last no query: sent back to be put on one, whatever came before; nothing is unusable") {
        let several = QueryAsking.Answer.unusable("it wrote several lines, and the last isn't a query", repair: oneLine)
        let cases: KeyValuePairs<String, QueryAsking.Answer> = [
            "Here is the query:\nIt's every chore.": several,
            "I can't tell.\nWhich pantry?": several,
            "Sorry,\nI can't.": several,
            // A query with more written after it: an explanation, or a query taken back (the first
            // eval round's s20, whose first line asked the wrong question).
            "chore\n\nEvery chore on every board.": several,
            "\"Pantry\":has(> *)\n\nWait, let me reconsider. What's asked is its parent.\n\nThe query should be: :has(> \"Pantry\")": several,
            "": .unusable("it answered nothing", repair: nil),
            "   \n\t  ": .unusable("it answered nothing", repair: nil),
            "```\n```": .unusable("it answered nothing", repair: nil),
            "<query></query>": .unusable("it answered nothing", repair: nil),
        ]
        for (text, answer) in cases {
            expectEqual(QueryAsking.parse(ModelResponse(text: text)), answer, text)
        }
    },
    test("a stop other than its turn's end: cut off, stopped early, or declined, whatever it wrote") {
        let cases: [(StopReason, QueryAsking.Answer)] = [
            (.maxTokens, .unusable("its answer was cut off", repair: nil)),
            (.stopSequence, .unusable("it stopped before its answer was done", repair: nil)),
            (StopReason(rawValue: "pause_turn"), .unusable("it stopped before its answer was done", repair: nil)),
            (.refusal, .declined),
        ]
        for (stop, answer) in cases {
            expectEqual(QueryAsking.parse(ModelResponse(text: "chore", stopReason: stop)), answer, stop.rawValue)
            expectEqual(QueryAsking.parse(ModelResponse(text: "", stopReason: stop)), answer, stop.rawValue)
        }
        expectEqual(QueryAsking.parse(ModelResponse(text: "chore", stopReason: .endTurn)), .query("chore"))
    },
])

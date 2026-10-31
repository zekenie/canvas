import Canvas
import CanvasRPC
import DecisionModels
import LanguageRules
import TestKit
import Types

@MainActor let ruleBookTests = Suite("The rule book", [
    test("a type's rules are its schema's $rules: each sentence and its chips, in order; a rule with no words, and what isn't a list of them, is none") {
        let text = #"""
        {"type": "object", "properties": {"$rules": {"const": [
          {"says": "The description agrees with the car's year, model and mileage."},
          {"says": "  "},
          {"says": "Unusual for someone representing [the member's district].", "find": [{"phrase": "the member's district", "query": "card"}, {"phrase": ""}]},
          {"says": "Priced unlike the other listings.", "find": [{"phrase": "the other listings"}, {"phrase": "Priced", "query": "  "}]},
          "not a rule"
        ]}, "year": {"type": "number"}}}
        """#
        expectEqual(RuleBook.rules(inSchema: text), [
            Rule(says: "The description agrees with the car's year, model and mileage."),
            Rule(says: "Unusual for someone representing [the member's district].", find: [RuleChip(phrase: "the member's district", query: "card")]),
            Rule(says: "Priced unlike the other listings.", find: [RuleChip(phrase: "the other listings", query: nil), RuleChip(phrase: "Priced", query: nil)]),
        ], "a chip with no query is words not interpreted yet")
        expectEqual(RuleBook.rules(inSchema: #"{"properties": {"$rules": {"const": "one"}}}"#), [])
        expectEqual(RuleBook.rules(inSchema: #"{"properties": {"$rules": "#), [], "a text being typed")
        expectEqual(RuleBook.rules(inSchema: #"{"properties": {}}"#), [])
    },
    test("rules written as a schema's member read back as they were") {
        let rules = [Rule(says: "It's in stock."), Rule(says: "Unusual for [its district].", find: [RuleChip(phrase: "its district", query: "card")])]
        let schema: JSONValue = ["properties": ["$rules": RuleBook.member(rules)]]
        expectEqual(RuleBook.rules(inSchema: schema), rules)
        expectEqual(RuleBook.member([Rule(says: "A")]), ["const": [["says": "A"]]], "no find without chips")
        let words = [Rule(says: "Unlike the other listings.", find: [RuleChip(phrase: "the other listings", query: nil)])]
        expectEqual(RuleBook.member(words), ["const": [["says": "Unlike the other listings.", "find": [["phrase": "the other listings"]]]]], "words with no query")
        expectEqual(RuleBook.rules(inSchema: ["properties": ["$rules": RuleBook.member(words)]]), words)
        expectEqual(RuleBook.literal(words), #"[{"says": "Unlike the other listings.", "find": [{"phrase": "the other listings"}]}]"#)
    },
    test("a rule's chips are where their phrases are, in the order written; words that change keep the chips still in them") {
        let rule = Rule(says: "Unusual given the votes and the votes of the district.",
                        find: [RuleChip(phrase: "the votes", query: "a"), RuleChip(phrase: "the votes", query: "b"), RuleChip(phrase: "the district", query: nil),
                               RuleChip(phrase: "a party", query: "c")])
        let says = rule.says
        expectEqual(rule.chipRanges.map { String(says[$0.range]) }, ["the votes", "the votes", "the district"], "each after the one before; none for a phrase not there")
        expectEqual(rule.chipRanges.map { says.distance(from: says.startIndex, to: $0.range.lowerBound) }, [14, 28, 41])
        expectEqual(rule.bracketed, "Unusual given [the votes] and [the votes] of [the district].")
        let edited = rule.saying("Unusual given the votes of the district.")
        expectEqual(edited.find.map(\.phrase), ["the votes", "the votes", "the district"], "a chip whose phrase went goes")
        expectEqual(edited.says, "Unusual given the votes of the district.")
        expectEqual(Rule(says: "Plain.").bracketed, "Plain.")
        let rest = Rule(says: "Priced unlike the rest.", find: [RuleChip(phrase: "rest", query: "card")])
        expectEqual(rest.saying("Priced with no interest.").find, [], "a phrase is words of its own, never part of a longer word")
        expectEqual(Rule(says: "The interest and the rest.", find: rest.find).chipRanges.map { $0.range.lowerBound.utf16Offset(in: "The interest and the rest.") }, [21])
    },
    test("the rules a shape is checked against are its chain's, the most general type's first, a later type in its list the more specific") {
        let car = ShapeID(), listing = ShapeID(), vintage = ShapeID(), mustang = ShapeID()
        let scene = try RuleScene([
            typeCard("Car", rules: ["The mileage is plausible for its age."], id: car),
            typeCard("Listing", rules: ["The description agrees with the car's year, model and mileage.", "The description mentions no damage or wear."],
                     builds: [car], id: listing),
            typeCard("Vintage", rules: ["Wear and patina are expected on a vintage car."], builds: [car], id: vintage),
            card("1967 Ford Mustang Coupe", of: [listing, vintage], id: mustang),
        ])
        let chain = RuleBook.chain(for: mustang, in: scene.editor)
        expectEqual(chain.map(\.typeName), ["Car", "Listing", "Listing", "Vintage"])
        expectEqual(chain.map(\.rule.says).last, "Wear and patina are expected on a vintage car.")
        expectEqual(chain.first?.type, car)
        expectEqual(RuleBook.chain(for: listing, in: scene.editor), [], "a type is checked by none")
        expectEqual(RuleBook.noun(for: mustang, in: scene.editor), "car")
    },
    test("a type's name as a noun: its first letter lower-case, unless it reads as written") {
        expectEqual(["Car", "Vote", "Pull request", "PR", "iPhone", "X"].map(RuleBook.noun(of:)), ["car", "vote", "pull request", "PR", "iPhone", "x"])
    },
])

@MainActor let promptTests = Suite("The rules' words", [
    test("the product's file reads as a question for the rules read together and one for each, saying which answer flags") {
        let prompts = shippedPrompts
        expectEqual(prompts.together.text, "Read together, does this {noun} meet them?")
        expectEqual([prompts.together.yes, prompts.together.no], ["It meets them", "It breaks one"])
        expect(!prompts.together.flagsWhenYes)
        expectEqual(prompts.each.text, "Read with the others, does this {noun} fail rule {number}?")
        expect(prompts.each.flagsWhenYes)
        expectEqual(prompts.flagging("all", yes: 0.11), 0.89)
        expectEqual(prompts.flagging("r0", yes: 0.93), 0.93)
    },
    test("a request is the prototype's: the preface names the noun and lists the rules most general first, each on its type, then the questions") {
        let rules = [ChainedRule(rule: Rule(says: "The description agrees with the car's year, model and mileage."), type: ShapeID(), typeName: "Listing"),
                     ChainedRule(rule: Rule(says: "The description mentions no damage or wear."), type: ShapeID(), typeName: "Listing")]
        let request = shippedPrompts.request(state: ["today": "2026-10-27"], rules: rules, noun: "car")
        expectEqual(request.preface, """
        These rules come from the car's types, the most general type first. Read them together: where two disagree, the more specific type's rule wins. Each rule says something that should be true of the car.
        1. (on Listing) "The description agrees with the car's year, model and mileage."
        2. (on Listing) "The description mentions no damage or wear."
        """)
        expectEqual(request.questions, [
            DecisionQuestion(id: "all", asks: "Read together, does this car meet them?", yes: "It meets them", no: "It breaks one"),
            DecisionQuestion(id: "r0", asks: "Read with the others, does this car fail rule 1?", yes: "Yes", no: "No"),
            DecisionQuestion(id: "r1", asks: "Read with the others, does this car fail rule 2?", yes: "Yes", no: "No"),
        ])
        expect(request.text(of: request.questions[0]).hasSuffix("wear.\"\nRead together, does this car meet them?"), "as Jev was asked: the preface, a line, the question")
    },
    test("a file without a section, or a question without its answers, is refused") {
        expectThrows(RulePrompts.ReadError.missing("each")) {
            _ = try RulePrompts(text: "## preface\nP\n## rule\nR\n## together\nT?\ntrue: Y\nfalse: N\nflags when: false\n")
        }
        expectThrows(RulePrompts.ReadError.missing("together flags when")) {
            _ = try RulePrompts(text: "## preface\nP\n## rule\nR\n## together\nT?\ntrue: Y\nfalse: N\n## each\nE?\ntrue: Y\nfalse: N\nflags when: true\n")
        }
    },
])

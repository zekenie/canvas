import Foundation
import ProseMaps
import TestKit

/// Where an offset in `text` is, in characters.
private func offset(_ index: String.Index, in text: String) -> Int { text.distance(from: text.startIndex, to: index) }

@MainActor let placingTests = Suite("Prose maps: placing", [
    test("words are found in order, whole words first, as written first, never overlapping: words written twice go to their places in turn") {
        let text = "the customer's name and email, and each product's name, keystone and key"
        @MainActor func found(_ words: [String], in text: String = text) -> [Int?] {
            ProseMapText.anchor(words, in: text).map { $0.map { offset($0.lowerBound, in: text) } }
        }
        expectEqual(found(["customer", "name", "email", "product", "name", "key"]), [4, 15, 24, 40, 50, 69], "the second name after the first; key, not keystone's")
        expectEqual(found(["email", "customer"]), [24, 4], "listed out of order: from the start once nothing's after")
        expectEqual(found(["Customer", "EMAIL"]), [4, 24], "as written first, then ignoring case")
        expectEqual(found(["customer's name", "name"]), [4, 50], "never inside one found")
        expectEqual(found(["phone", "", "name"]), [nil, nil, 15])
        expectEqual(found(["keystone"]), [56])
        expectEqual(found(["key"], in: "keystone"), [0], "inside a word only when it's nowhere else")
        expectEqual(found(["タイトル", "必須"], in: "書籍：タイトル（必須）"), [3, 8])
    },
    test("a quote of the target is found where it's written once, any run of whitespace in it matching any run there; written twice, absent or blank, nowhere") {
        @MainActor func found(_ quote: String, in text: String = menuCode) -> String? { ProseMapText.find(quote, in: text).map { String(text[$0]) } }
        expectEqual(found("$0.price > 10"), "$0.price > 10")
        expectEqual(found("$0.price   >\n 10"), "$0.price > 10", "the quote's whitespace any run")
        expectEqual(found("Double {\nitems.filter"), "Double {\n    items.filter", "across a line, indented anew")
        expectEqual(found("price"), nil, "written twice: which one isn't said")
        expectEqual(found("x + x", in: "x + x + x"), nil, "written again, overlapping itself")
        expectEqual(found("tax"), nil)
        expectEqual(found(" \n "), nil)
        expectEqual(found("[Item]"), "[Item]", "what a pattern would read as its own, read as written")
    },
    test("a map holds the links found on both sides, in the prose's order, each with what it says; a quote of the target written twice leads nowhere") {
        var links = [ProseLink(quote: "over ten dollars", address: "$0.price > 10"), ProseLink(quote: "sum", address: "reduce(0) { $0 + $1.price }"),
                     ProseLink(quote: "prices", address: "price"), ProseLink(quote: "tax", address: "$0.tax")]
        links.append(ProseLink(quote: "every item", address: "items.filter { $0.price > 10 }"))
        let map = ProseMap<Snippet>(placing: links, prose: menuProse, target: menuCode)
        expectEqual(map.links.map(\.quote), ["sum", "every item", "over ten dollars"], "the prose's order; prices to a stretch written twice, tax to none")
        expectEqual(map.links.map { String(menuProse[$0.inProse]) }, map.links.map(\.quote))
        expectEqual(map.links.map { String(menuCode[$0.inTarget]) }, ["reduce(0) { $0 + $1.price }", "items.filter { $0.price > 10 }", "$0.price > 10"])
        expectEqual(map.links.map(\.role), [.element, .element, .element], "a quote says nothing of what it is")
        let at = try require(menuProse.range(of: "item")).lowerBound
        expectEqual(map.link(at: at)?.quote, "every item")
        expectEqual(map.link(at: menuProse.startIndex)?.quote, "sum")
        expect(map.link(at: try require(menuProse.range(of: "the prices")).lowerBound) == nil, "words linked to nothing")
        let ten = try require(menuCode.range(of: "10")).lowerBound
        expectEqual(map.links(atTarget: ten).map(\.quote), ["over ten dollars", "every item"], "the innermost part first")
        expectEqual(map.excerpt(of: map.links[1]), "items.filter { $0.price > 10 }")
    },
    test("a target with an address of its own finds it, and says what each one leads to") {
        let links = [ProseLink(quote: "boil", address: try require(Step("1"))), ProseLink(quote: "stir if it sticks", address: try require(Step("3!"))),
                     ProseLink(quote: "drain", address: try require(Step("9")))]
        let map = ProseMap<Steps>(placing: links, prose: pastaProse + ", then drain", target: pastaRecipe)
        expectEqual(map.links.map(\.quote), ["boil", "stir if it sticks"], "step 9 isn't there")
        expectEqual(map.links.map { String(pastaRecipe[$0.inTarget]) }, ["boil water", "if it sticks, stir"])
        expectEqual(map.links.map(\.role), [.element, .rule])
        expectEqual(map.links.map(\.address.description), ["1", "3!"])
    },
    test("a part as a person reads it: as written, each line after the first less the indent of the line it starts on") {
        let text = "{\n  \"summary\": {\n    \"type\": \"string\",\n    \"maxLength\": 255\n  }\n}"
        let part = try require(text.range(of: "\"summary\": {\n    \"type\": \"string\",\n    \"maxLength\": 255\n  }"))
        expectEqual(ProseMapText.excerpt(part, of: text), "\"summary\": {\n  \"type\": \"string\",\n  \"maxLength\": 255\n}")
        let flush = try require(text.range(of: "{\n  \"summary\""))
        expectEqual(ProseMapText.excerpt(flush, of: text), "{\n  \"summary\"", "a part at the margin as it is")
    },
])

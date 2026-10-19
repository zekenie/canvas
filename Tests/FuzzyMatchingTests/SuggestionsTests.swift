import FuzzyMatching
import TestKit

// "Did you mean": what `canvas draw`'s and `canvas query`'s refusals offer for a word that isn't one.

@MainActor let suggestionsTests = Suite("Did you mean", [
    test("did you mean: case, spacing and × first, then containing, sharing a word, a few letters off") {
        expectEqual(Suggestions.closest(to: "deploy", among: ["Deploy", "Deploy now", "Depot", "Other"]), ["Deploy", "Deploy now", "Depot"])
        expectEqual(Suggestions.closest(to: "Tile, 120 x 80", among: ["Tile, 120 × 80", "Box"]), ["Tile, 120 × 80"])
        expectEqual(Suggestions.closest(to: "rigth", among: ["above", "below", "left", "right"], limit: 1), ["right"])
        expectEqual(Suggestions.closest(to: "Web tier", among: ["Tier two", "API"]), ["Tier two"])
        expectEqual(Suggestions.closest(to: "zzz", among: ["right", "left"]), [])
    },
    test("did you mean: the fewest edits first within each; one further off in length than a slip allows is passed over, uncounted") {
        // One inside the other: as many edits as the letters left over.
        expectEqual(Suggestions.closest(to: "deploy", among: ["Deploy the plan now", "Deploy now", "Redeploy"]),
                    ["Redeploy", "Deploy now", "Deploy the plan now"])
        // Sharing a word: the edits, not the lengths (both are 9 letters).
        expectEqual(Suggestions.closest(to: "red cache", among: ["cache red", "rod cache"]), ["rod cache", "cache red"])
        // A slip: 3 edits in 10 letters, so a length 4 off is too far however it's spelled.
        expectEqual(Suggestions.closest(to: "Deploymnet", among: ["Deploymentplan", "Deployment"]), ["Deployment"])
        // Titles far longer than the word, none near: they're folded, and none is given an edit
        // table (60 × 600 each, seconds for them all in debug).
        let wanted = String(repeating: "q", count: 60)
        let titles = (0..<300).map { "Title \($0) " + String(repeating: "x", count: 600) }
        var found = ["not asked"]
        let took = threadCPUTime { found = Suggestions.closest(to: wanted, among: titles) }
        expectEqual(found, [])
        expect(took < .milliseconds(500), "300 titles of 600 letters took \(took)")
    },
    test("a near miss: the same title but for case, spacing and ×, or a letter off (two in a long one), never itself") {
        expect(Suggestions.isNearMiss("deploy", "Deploy"))
        expect(Suggestions.isNearMiss("Tile, 120 x 80", "Tile,  120 × 80"))
        expect(Suggestions.isNearMiss("Ship it", "Shop it"))
        expect(Suggestions.isNearMiss("Checkout flow", "Chekout flwo"))
        expect(!Suggestions.isNearMiss("Deploy", "Deploy"), "the same title is no miss")
        expect(!Suggestions.isNearMiss("A", "B"), "short titles only by case")
        expect(!Suggestions.isNearMiss("API", "APP"))
        expect(!Suggestions.isNearMiss("Ship", "Shape"))
        expect(!Suggestions.isNearMiss("Deploy", "Deploy now"))
    },
])

import Foundation
import SkillTesting
import TestKit

// The canvas-digest skill's tool (.claude/skills/canvas-digest/tool) under the system jsc, the runtime it is built for: its own unit
// tests, which need no app, no socket and no pasteboard. The tests of `digest` as an agent runs it, against the app, are
// CompositionTests' DigestTests.

/// The tool's unit tests (`tool/test/run.js`) run in parts, each its own suite, so that a run can deal them to processes side by side: part K of
/// N runs every Nth test from the Kth (the script says how many of how many it ran), and the parts together are all of them.
private let toolTestParts = 8

@MainActor let digestToolTests: [Suite] = (0..<toolTestParts).map { part in
    Suite("canvas-digest: the tool's unit tests under jsc, part \(part + 1) of \(toolTestParts)", [
        test("the tool's unit tests pass under jsc") {
            let result = try run(URL(fileURLWithPath: jsc), [digestSkill("tool/test/run.js").path, "--", "\(part)/\(toolTestParts)"], timeout: 280)
            expectEqual(result.status, 0, result.output + result.error)
            let failures = result.output.split(separator: "\n").filter { $0.hasPrefix("FAIL") || $0.hasPrefix("ERROR") }
            expectEqual(failures.map(String.init), [], "no test failed")
            let tally = result.output.split(separator: "\n").last { $0.contains(" passed, ") }.map(String.init) ?? ""
            expect(tally.hasSuffix(" passed, 0 failed"), "the tally: \(tally)")
            // the part ran every Nth of the tests the script defines, and there are at least as many as before the parts were made
            let said = result.output.split(separator: "\n").last { $0.hasPrefix("part ") }.map(String.init) ?? ""
            let numbers = said.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }       // K, N, ran, defined
            expectEqual(numbers.count, 4, "the part's own line: \(said)")
            if numbers.count == 4 {
                expectEqual(numbers[0], part)
                expectEqual(numbers[1], toolTestParts)
                expectEqual(numbers[2], (numbers[3] - part + toolTestParts - 1) / toolTestParts, "every Nth test: \(said)")
                expectEqual(Int(tally.split(separator: " ").first ?? ""), numbers[2], "and each passed: \(tally)")
                expect(numbers[3] >= 30, "the tests ran: \(said)")
            }
        },
    ])
}
